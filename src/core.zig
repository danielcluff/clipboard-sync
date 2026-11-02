const std = @import("std");
const version = @import("version.zig");
pub const max_payload = 5 * 1024 * 1024;
pub const overhead = 56;
pub const max_packet = max_payload + overhead + 34 + 255;
pub const Key = [32]u8;
pub const Id = [16]u8;
const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
pub const Item = struct {
    kind: u8,
    event: Id = @splat(0),
    app_version: version.Wire = version.wire,
    name: []const u8,
    data: []const u8,
};
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |c| if (c < 32 or c == '/' or c == '\\' or c == ':' or c == '*' or c == '?' or c == '"' or c == '<' or c == '>' or c == '|' or c == 127) return false;
    // Avoid Windows special files, alternate streams, and trailing-dot aliases.
    if (name[name.len - 1] == '.' or name[name.len - 1] == ' ') return false;
    const stem = name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9" }) |reserved| {
        if (std.ascii.eqlIgnoreCase(stem, reserved)) return false;
    }
    return std.unicode.utf8ValidateSlice(name);
}
pub fn encode(out: []u8, sender: Id, nonce: [12]u8, key: Key, item: Item) ![]u8 {
    if (item.kind != 1 and item.kind != 2) return error.InvalidKind;
    if (item.data.len > max_payload or item.name.len > 255) return error.TooLarge;
    if (item.kind == 2 and !validName(item.name)) return error.InvalidName;
    if (item.kind == 1 and (!std.unicode.utf8ValidateSlice(item.data) or std.mem.indexOfScalar(u8, item.data, 0) != null)) return error.InvalidText;
    const n = 34 + item.name.len + item.data.len;
    if (out.len < overhead + n) return error.TooSmall;
    @memcpy(out[0..8], "CLIPSY02");
    @memcpy(out[8..24], &sender);
    @memcpy(out[24..36], &nonce);
    std.mem.writeInt(u32, out[52..56], @intCast(n), .big);
    const plain = out[overhead .. overhead + n];
    plain[0] = item.kind;
    plain[1] = @intCast(item.name.len);
    @memcpy(plain[2..18], &item.event);
    @memcpy(plain[18..34], &item.app_version);
    @memcpy(plain[34 .. 34 + item.name.len], item.name);
    @memcpy(plain[34 + item.name.len ..], item.data);
    var tag: [16]u8 = undefined;
    Aead.encrypt(plain, &tag, plain, out[0..36], nonce, key);
    @memcpy(out[36..52], &tag);
    return out[0 .. overhead + n];
}
pub fn decode(packet: []u8, key: Key) !Item {
    if (packet.len < overhead + 34 or packet.len > max_packet or !std.mem.eql(u8, packet[0..8], "CLIPSY02")) return error.InvalidPacket;
    const n = std.mem.readInt(u32, packet[52..56], .big);
    if (n != packet.len - overhead) return error.InvalidPacket;
    const plain = packet[overhead..];
    try Aead.decrypt(plain, plain, packet[36..52].*, packet[0..36], packet[24..36].*, key);
    if (plain.len < 34) return error.InvalidPacket;
    if (!version.matches(plain[18..34].*)) return error.IncompatibleVersion;
    if (plain[0] != 1 and plain[0] != 2) return error.InvalidKind;
    const name_len: usize = plain[1];
    if (name_len + 34 > plain.len or plain.len - name_len - 34 > max_payload) return error.InvalidPacket;
    const item = Item{ .kind = plain[0], .event = plain[2..18].*, .app_version = plain[18..34].*, .name = plain[34 .. 34 + name_len], .data = plain[34 + name_len ..] };
    if (item.kind == 2 and !validName(item.name)) return error.InvalidName;
    if (item.kind == 1 and (!std.unicode.utf8ValidateSlice(item.data) or std.mem.indexOfScalar(u8, item.data, 0) != null)) return error.InvalidText;
    return item;
}
pub fn fingerprint(item: Item) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(&.{item.kind});
    hash.update(item.name);
    hash.update(&.{0});
    hash.update(item.data);
    return hash.finalResult();
}
pub const History = struct {
    const Entry = struct { kind: u8, name: []u8, data: []u8, hash: [32]u8 };
    entries: [10]?Entry = @splat(null),
    allocator: std.mem.Allocator,
    pub fn deinit(self: *History) void {
        for (&self.entries) |*slot| if (slot.*) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.data);
            slot.* = null;
        };
    }
    pub fn push(self: *History, item: Item) !void {
        const hash = fingerprint(item);
        const name = try self.allocator.dupe(u8, item.name);
        errdefer self.allocator.free(name);
        const data = try self.allocator.dupe(u8, item.data);
        // Move an existing entry to the front; do not fill history with sync echoes.
        var remove: usize = 9;
        for (self.entries, 0..) |slot, i| if (slot) |entry| {
            if (std.mem.eql(u8, &entry.hash, &hash)) {
                remove = i;
                break;
            }
        };
        if (self.entries[remove]) |old| {
            self.allocator.free(old.name);
            self.allocator.free(old.data);
        }
        var i = remove;
        while (i > 0) : (i -= 1) self.entries[i] = self.entries[i - 1];
        self.entries[0] = .{ .kind = item.kind, .name = name, .data = data, .hash = hash };
    }
};
test "authenticated round trip, wrong key, tamper and truncated frame" {
    var packet: [1024]u8 = undefined;
    const key: Key = @splat(7);
    const original = Item{ .kind = 2, .name = "archive.zip", .data = "PK\x00\xff" };
    var encoded = try encode(&packet, @splat(1), @splat(2), key, original);
    var copy: [1024]u8 = undefined;
    @memcpy(copy[0..encoded.len], encoded);
    try std.testing.expectError(error.AuthenticationFailed, decode(copy[0..encoded.len], @splat(8)));
    @memcpy(copy[0..encoded.len], encoded);
    copy[encoded.len - 1] ^= 1;
    try std.testing.expectError(error.AuthenticationFailed, decode(copy[0..encoded.len], key));
    try std.testing.expectError(error.InvalidPacket, decode(encoded[0 .. encoded.len - 1], key));
    const decoded = try decode(encoded, key);
    try std.testing.expectEqualStrings(original.name, decoded.name);
    try std.testing.expectEqualStrings(original.data, decoded.data);
}
test "portable file names and text validation" {
    for ([_][]const u8{ "../bad", "..", "C:\\bad", "NUL.zip", "trailing.", "a/b", "a\x00b" }) |name| try std.testing.expect(!validName(name));
    try std.testing.expect(validName("small archive.zip"));
    var packet: [100]u8 = undefined;
    try std.testing.expectError(error.InvalidText, encode(&packet, @splat(0), @splat(0), @splat(0), .{ .kind = 1, .name = "", .data = "a\x00b" }));
}
test "history holds ten copies and restores existing entry to front" {
    var h = History{ .allocator = std.testing.allocator };
    defer h.deinit();
    for (0..12) |i| {
        const byte = [_]u8{@intCast(65 + i)};
        try h.push(.{ .kind = 1, .name = "", .data = &byte });
    }
    try std.testing.expectEqualStrings("L", h.entries[0].?.data);
    try std.testing.expectEqualStrings("C", h.entries[9].?.data);
    try h.push(.{ .kind = 1, .name = "", .data = "F" });
    try std.testing.expectEqualStrings("F", h.entries[0].?.data);
    try std.testing.expectEqualStrings("C", h.entries[9].?.data);
}
test "file size boundary and event identity survive encryption" {
    const data = try std.testing.allocator.alloc(u8, max_payload + 1);
    defer std.testing.allocator.free(data);
    @memset(data, 0xa5);
    const packet = try std.testing.allocator.alloc(u8, max_packet);
    defer std.testing.allocator.free(packet);
    var name: [255]u8 = @splat('a');
    @memcpy(name[251..], ".zip");
    const item = Item{ .kind = 2, .event = @splat(42), .name = &name, .data = data[0..max_payload] };
    const encoded = try encode(packet, @splat(1), @splat(2), @splat(3), item);
    const decoded = try decode(encoded, @splat(3));
    try std.testing.expectEqualSlices(u8, &item.event, &decoded.event);
    try std.testing.expectEqualSlices(u8, item.data, decoded.data);
    try std.testing.expectError(error.TooLarge, encode(packet, @splat(1), @splat(2), @splat(3), .{ .kind = 2, .name = "too-large.zip", .data = data }));
}

test "authenticated clipboard messages require the exact app version" {
    var buffer: [256]u8 = undefined;
    var other = version.wire;
    other[0] = '9';
    const packet = try encode(&buffer, @splat(1), @splat(2), @splat(3), .{
        .kind = 1,
        .name = "",
        .data = "Must not reach the clipboard",
        .app_version = other,
    });
    try std.testing.expectError(error.IncompatibleVersion, decode(packet, @splat(3)));
    const current = try encode(&buffer, @splat(1), @splat(2), @splat(3), .{ .kind = 1, .name = "", .data = "Current" });
    @memcpy(current[0..8], "CLIPSY01");
    try std.testing.expectError(error.InvalidPacket, decode(current, @splat(3)));
}
