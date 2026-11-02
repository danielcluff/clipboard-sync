const std = @import("std");
const core = @import("core.zig");
const version = @import("version.zig");
const pairing = @import("pairing.zig");
const c = @import("bridge.zig");
const allocator = std.heap.page_allocator;
const Peer = extern struct { id: core.Id = @splat(0), key: core.Key = @splat(0), ip: [16]u8 = @splat(0), name: [64]u8 = @splat(0) };
const Config = extern struct { magic: [8]u8 = "CLIPCF01".*, id: core.Id = @splat(0), count: u32 = 0, peers: [16]Peer = @splat(Peer{}) };
const Nearby = struct { id: core.Id, ip: [16]u8, name: [64]u8, seen: u64 };
var config: Config = .{};
var peer_compatible: [16]bool = @splat(false);
var nearby: [16]?Nearby = @splat(null);
var history = core.History{ .allocator = allocator };
var last_hash: ?[32]u8 = null;
var host: [64]u8 = @splat(0);
var running = true;
var paused = false;
var pairing_code: ?pairing.Code = null;
var pairing_attempts: u8 = 0;
var pairing_until: u64 = 0;
var labels: [10][272:0]u8 = @splat(@splat(0));
var peer_labels: [16][160:0]u8 = @splat(@splat(0));
var nearby_labels: [16][160:0]u8 = @splat(@splat(0));
var status: [160:0]u8 = @splat(0);
var receive_buffer: [core.max_packet]u8 = undefined;
var send_buffer: [core.max_packet]u8 = undefined;
// Nonces are remembered per peer to reject recently replayed authenticated frames.
var nonces: [16][64][12]u8 = @splat(@splat(@splat(0)));
var nonce_next: [16]usize = @splat(0);
fn slice(buf: []const u8) []const u8 {
    return buf[0 .. std.mem.indexOfScalar(u8, buf, 0) orelse buf.len];
}
fn set(dest: []u8, value: []const u8) void {
    @memset(dest, 0);
    @memcpy(dest[0..@min(value.len, dest.len - 1)], value[0..@min(value.len, dest.len - 1)]);
}
fn random(bytes: []u8) bool {
    return c.cs_random(bytes.ptr, bytes.len) == 1;
}
fn save() void {
    if (c.cs_save(&config, @sizeOf(Config)) != 1) c.cs_notice("Could not save devices", "Check permissions on the Clipboard Sync data directory.");
}
fn peerIndex(id: core.Id) ?usize {
    for (config.peers[0..config.count], 0..) |peer, i| if (std.mem.eql(u8, &peer.id, &id)) return i;
    return null;
}
// Keep UTF-8 characters intact and reserve room for an explicit truncation marker.
fn historyPreview(buffer: *[243]u8, content: []const u8) []const u8 {
    const view = std.unicode.Utf8View.init(content) catch return "[Invalid text]";
    var it = view.iterator();
    var length: usize = 0;
    var characters: usize = 0;
    while (it.nextCodepointSlice()) |character| {
        if (characters == 60) {
            @memcpy(buffer[length..][0..3], "…");
            return buffer[0 .. length + 3];
        }
        if (character.len == 1 and (character[0] < 32 or character[0] == 127)) {
            buffer[length] = ' ';
        } else {
            @memcpy(buffer[length..][0..character.len], character);
        }
        length += character.len;
        characters += 1;
    }
    return buffer[0..length];
}
export fn cs_is_paused() c_int {
    return if (paused) 1 else 0;
}
export fn cs_sync_action_label() [*:0]const u8 {
    return if (paused) "Resume syncing" else "Pause syncing";
}
var clipboard_poll_running = false;
export fn cs_poll_clipboard() void {
    if (paused or clipboard_poll_running) return;
    clipboard_poll_running = true;
    defer clipboard_poll_running = false;
    var clip: c.cs_clip = std.mem.zeroes(c.cs_clip);
    if (c.cs_clip_read(&clip) == 1) {
        defer c.cs_clip_free(&clip);
        const item = core.Item{ .kind = @intCast(clip.kind), .name = slice(&clip.name), .data = clip.data[0..clip.len] };
        const hash = core.fingerprint(item);
        if (last_hash == null or !std.mem.eql(u8, &last_hash.?, &hash)) {
            remember(item);
            propagate(item, null);
        }
    }
}
fn refresh() void {
    var compatible_count: usize = 0;
    for (peer_compatible[0..config.count]) |compatible| {
        if (compatible) compatible_count += 1;
    }
    _ = std.mem.printSentinel(&status, "{s} · v{s} · {d} paired", .{ if (paused) "Sync paused" else "Sync active", version.text, compatible_count }, 0) catch unreachable;
    for (&labels, 0..) |*label, i| {
        @memset(label, 0);
        if (history.entries[i]) |entry| {
            const content = if (entry.kind == 2) entry.name else entry.data;
            var preview: [243]u8 = undefined;
            const text = historyPreview(&preview, content);
            _ = std.mem.printSentinel(label, "{d}. {s}{s}", .{ i + 1, if (entry.kind == 2) "File: " else "", text }, 0) catch unreachable;
        }
    }
    for (&peer_labels, 0..) |*label, i| {
        @memset(label, 0);
        if (i < config.count and peer_compatible[i]) {
            _ = std.mem.printSentinel(label, "{s} ({s}) — Forget", .{ slice(&config.peers[i].name), slice(&config.peers[i].ip) }, 0) catch unreachable;
        }
    }
    for (&nearby_labels, 0..) |*label, i| {
        @memset(label, 0);
        if (nearby[i]) |device| {
            if (peerIndex(device.id) == null and c.cs_millis() - device.seen < 15000) {
                _ = std.mem.printSentinel(label, "{s} ({s})", .{ slice(&device.name), slice(&device.ip) }, 0) catch unreachable;
            }
        }
    }
    c.cs_refresh();
}
export fn cs_history_label(index: c_int) [*:0]const u8 {
    if (index < 0 or index >= 10) return "";
    return &labels[@intCast(index)];
}
export fn cs_history_id(index: c_int, out: [*]u8) c_int {
    if (index < 0 or index >= 10) return 0;
    const entry = history.entries[@intCast(index)] orelse return 0;
    @memcpy(out[0..32], &entry.hash);
    return 1;
}
export fn cs_restore_history(hash: [*]const u8) void {
    for (history.entries, 0..) |slot, i| {
        if (slot) |entry| {
            if (std.mem.eql(u8, &entry.hash, hash[0..32])) {
                cs_action(1, @intCast(i));
                return;
            }
        }
    }
}
export fn cs_peer_label(index: c_int) [*:0]const u8 {
    if (index < 0 or index >= 16) return "";
    return &peer_labels[@intCast(index)];
}
export fn cs_nearby_label(index: c_int) [*:0]const u8 {
    if (index < 0 or index >= 16) return "";
    return &nearby_labels[@intCast(index)];
}
export fn cs_status() [*:0]const u8 {
    return &status;
}
fn sendItem(item: core.Item, peer: Peer) bool {
    var nonce: [12]u8 = undefined;
    if (!random(&nonce)) return false;
    const packet = core.encode(&send_buffer, config.id, nonce, peer.key, item) catch return false;
    if (std.mem.eql(u8, item.name, "@probe") or std.mem.eql(u8, item.name, "@pair"))
        return c.cs_send_control(@ptrCast(&peer.ip), packet.ptr, packet.len) == 1;
    const accepted = c.cs_send(@ptrCast(&peer.ip), packet.ptr, packet.len) == 1;
    c.cs_log_event(if (accepted) "send_queued" else "send_failed", &item.event, &nonce, @ptrCast(&peer.ip), item.kind, item.data.len, 0);
    return accepted;
}
var recent_events: [256]core.Id = @splat(@splat(0));
var recent_next: usize = 0;
fn seenEvent(id: core.Id) bool {
    for (recent_events) |event| if (std.mem.eql(u8, &event, &id)) return true;
    return false;
}
fn recordEvent(id: core.Id) void {
    recent_events[recent_next % recent_events.len] = id;
    recent_next +%= 1;
}
fn propagate(original: core.Item, except: ?usize) void {
    var item = original;
    if (except == null) {
        if (!random(&item.event)) return;
        recordEvent(item.event);
        c.cs_log_event("copy_detected", &item.event, null, "local", item.kind, item.data.len, 0);
    }
    for (config.peers[0..config.count], 0..) |peer, i| {
        if (except != null and except.? == i) continue;
        if (!peer_compatible[i]) continue;
        _ = sendItem(item, peer);
    }
}
fn writeClip(item: core.Item) bool {
    var name: [256]u8 = @splat(0);
    set(&name, item.name);
    return c.cs_clip_write(item.kind, item.data.ptr, item.data.len, @ptrCast(&name)) == 1;
}
fn remember(item: core.Item) void {
    history.push(item) catch return;
    last_hash = core.fingerprint(item);
    refresh();
}
export fn cs_action(action: c_int, index: c_int) void {
    switch (action) {
        1 => { // Restore a history entry and sync it like a new copy.
            if (index < 0 or index >= 10) return;
            if (history.entries[@intCast(index)]) |entry| {
                const item = core.Item{ .kind = entry.kind, .name = entry.name, .data = entry.data };
                if (writeClip(item)) {
                    last_hash = entry.hash;
                    if (!paused) propagate(item, null);
                    history.push(item) catch {};
                    refresh();
                }
            }
        },
        2 => { // Open an explicit, time-limited pairing window.
            var code: ?pairing.Code = null;
            while (code == null) {
                var bytes: [4]u8 = undefined;
                if (!random(&bytes)) return;
                code = pairing.codeFromRandom(std.mem.readInt(u32, &bytes, .little));
            }
            pairing_code = code;
            pairing_attempts = 0;
            pending = null;
            pairing_until = c.cs_millis() + 120000;
            c.cs_pair_close();
            var display: [7]u8 = @splat(0);
            @memcpy(display[0..6], &code.?);
            c.cs_pairing_show(@ptrCast(&display));
        },
        3, 4 => {
            if (config.count == 16) {
                c.cs_notice("Device limit", "Forget a device before pairing another.");
                return;
            }
            var ip: [16]u8 = @splat(0);
            var name: [64]u8 = @splat(0);
            var id: ?core.Id = null;
            if (action == 3) {
                if (index < 0 or index >= 16) return;
                const device = nearby[@intCast(index)] orelse return;
                ip = device.ip;
                name = device.name;
                id = device.id;
            } else {
                if (c.cs_prompt("Connect by address", "Enter the other device's IPv4 address:", &ip, ip.len) != 1) return;
                set(&name, slice(&ip));
            }
            var input: [32]u8 = @splat(0);
            if (c.cs_prompt("Pair device", "On the other computer choose Allow a new device, then enter its six-digit code:", &input, input.len) != 1) return;
            const token = std.mem.trim(u8, slice(&input), " \r\n\t");
            const code = pairing.parseCode(token) catch {
                c.cs_notice("Invalid code", "Enter exactly six digits, including any leading zeros.");
                return;
            };
            const state = newPairState(.initiator, code) catch return;
            var session: [12]u8 = undefined;
            if (!random(&session)) return;
            c.cs_pairing_hide();
            pairing_code = null;
            c.cs_pair_close();
            pending = .{ .id = id, .ip = ip, .name = name, .session = session, .until = c.cs_millis() + 10000, .exchange = .{ .initiator = state } };
            if (!sendPairHello(1, ip, session, state.public)) {
                pending = null;
                c.cs_pair_close();
                connectionFailed(ip);
            }
        },
        5 => {
            paused = !paused;
            refresh();
        },
        6 => {
            if (index < 0 or index >= config.count) return;
            const i: usize = @intCast(index);
            c.cs_peer_forget(@ptrCast(&config.peers[i].ip));
            var j = i;
            while (j + 1 < config.count) : (j += 1) {
                config.peers[j] = config.peers[j + 1];
                nonces[j] = nonces[j + 1];
                peer_compatible[j] = peer_compatible[j + 1];
                nonce_next[j] = nonce_next[j + 1];
            }
            config.count -= 1;
            config.peers[config.count] = .{};
            peer_compatible[config.count] = false;
            nonces[config.count] = @splat(@splat(0));
            nonce_next[config.count] = 0;
            save();
            refresh();
        },
        7 => running = false,
        else => {},
    }
}
const Pending = struct {
    id: ?core.Id,
    ip: [16]u8,
    name: [64]u8,
    session: [12]u8,
    until: u64,
    exchange: union(enum) { initiator: pairing.State, responder: pairing.Keys, confirming: pairing.Keys },
};
var pending: ?Pending = null;
fn connectionFailed(ip: [16]u8) void {
    var message: [768:0]u8 = undefined;
    _ = std.mem.printSentinel(&message, "The connection to {s} on TCP port 45832 failed.\n\n{s}\n\nNearby discovery uses UDP, so a visible device can still have TCP blocked. On Windows, allow Clipboard Sync through Windows Firewall on your private network. You can also start pairing from Windows to the Mac.", .{ slice(&ip), std.mem.span(c.cs_net_error()) }, 0) catch unreachable;
    c.cs_notice("Pairing connection failed", &message);
}
fn newPairState(role: pairing.Role, code: pairing.Code) !pairing.State {
    var secret: [32]u8 = undefined;
    while (true) {
        if (!random(&secret)) return error.RandomFailed;
        if (pairing.validSecret(secret)) break;
    }
    return pairing.State.init(role, code, secret);
}
fn identity(id: core.Id, name: [64]u8, session: [12]u8) [108]u8 {
    var value: [108]u8 = undefined;
    @memcpy(value[0..16], &id);
    @memcpy(value[16..80], &name);
    @memcpy(value[80..92], &session);
    @memcpy(value[92..108], &version.wire);
    return value;
}
fn sendPair(kind: u8, ip: [16]u8, session: [12]u8, body: []const u8) bool {
    if (body.len > 129) return false;
    var packet: [186]u8 = @splat(0);
    @memcpy(packet[0..8], "CLIPPR03");
    @memcpy(packet[8..24], &config.id);
    @memcpy(packet[24..36], &session);
    @memcpy(packet[36..52], &version.wire);
    std.mem.writeInt(u32, packet[52..56], @intCast(body.len + 1), .big);
    packet[56] = kind;
    @memcpy(packet[57..][0..body.len], body);
    return c.cs_pair_send(@ptrCast(&ip), &packet, 57 + body.len) == 1;
}
fn sendPairHello(kind: u8, ip: [16]u8, session: [12]u8, public: [65]u8) bool {
    var body: [129]u8 = undefined;
    @memcpy(body[0..64], &host);
    @memcpy(body[64..129], &public);
    return sendPair(kind, ip, session, &body);
}
fn receivePair(packet: []const u8, ip: [16]u8, id: core.Id) void {
    if (packet.len < 57 or packet.len > 186) return;
    if (std.mem.readInt(u32, packet[52..56], .big) != packet.len - 56) return;
    const kind = packet[56];
    const session: [12]u8 = packet[24..36].*;
    const now = c.cs_millis();
    if (!version.matches(packet[36..52].*)) {
        hideIncompatible(id);
        if (pending) |p| {
            if (std.mem.eql(u8, &p.session, &session) and std.mem.eql(u8, slice(&p.ip), slice(&ip))) {
                pending = null;
                var message: [256:0]u8 = undefined;
                var remote: [17]u8 = @splat(0);
                @memcpy(remote[0..16], packet[36..52]);
                for (&remote) |*ch| {
                    if (ch.* != 0 and (ch.* < 32 or ch.* > 126)) ch.* = '?';
                }
                _ = std.mem.printSentinel(&message, "This app is v{s}. The other device reports {s}. Both devices must run the same version.", .{ version.text, if (remote[0] == 0) "an older, unversioned build" else slice(&remote) }, 0) catch unreachable;
                c.cs_notice("Incompatible app version", &message);
            }
        } else if (kind == 1) {
            _ = sendPair(5, ip, session, "");
        }
        return;
    }
    if (kind == 1) {
        if (packet.len != 186 or (config.count == 16 and peerIndex(id) == null) or pending != null) return;
        const code = pairing_code orelse return;
        if (now > pairing_until or pairing_attempts >= 5) return;
        // Every fresh exchange spends an online guess, even if the caller disappears.
        pairing_attempts += 1;
        const name: [64]u8 = packet[57..121].*;
        if (name[63] != 0 or !std.unicode.utf8ValidateSlice(slice(&name))) return;
        const state = newPairState(.responder, code) catch return;
        const a = identity(id, name, session);
        const b = identity(config.id, host, session);
        const keys = state.finish(packet[121..186].*, &a, &b) catch return;
        pending = .{ .id = id, .ip = ip, .name = name, .session = session, .until = @min(now + 10000, pairing_until), .exchange = .{ .responder = keys } };
        if (!sendPairHello(2, ip, session, state.public)) pending = null;
        return;
    }
    const p = pending orelse return;
    if (now > p.until or !std.mem.eql(u8, &p.session, &session) or !std.mem.eql(u8, slice(&ip), slice(&p.ip))) return;
    if (p.id) |expected| {
        if (!std.mem.eql(u8, &expected, &id)) return;
    }
    switch (p.exchange) {
        .initiator => |state| {
            if (kind != 2 or packet.len != 186) return;
            const name: [64]u8 = packet[57..121].*;
            if (name[63] != 0 or !std.unicode.utf8ValidateSlice(slice(&name))) return;
            const a = identity(config.id, host, session);
            const b = identity(id, name, session);
            const keys = state.finish(packet[121..186].*, &a, &b) catch {
                pending = null;
                return;
            };
            pending.?.id = id;
            pending.?.name = name;
            pending.?.exchange = .{ .confirming = keys };
            if (!sendPair(3, ip, session, &keys.confirm_a)) {
                pending = null;
                c.cs_pair_close();
                connectionFailed(ip);
            }
        },
        .responder => |keys| {
            if (kind != 3 or packet.len != 89) return;
            pending = null;
            if (!keys.verify(.initiator, packet[57..89].*)) return;
            if (!sendPair(4, ip, session, &keys.confirm_b)) return;
            if (addPeer(id, keys.encryption, ip, slice(&p.name))) |i| {
                // Keep the durable key for retry/recovery, but do not report success until
                // the other app proves it received the final confirmation and saved the key.
                peer_compatible[i] = false;
                refresh();
            }
            pairing_code = null;
            c.cs_pairing_hide();
        },
        .confirming => |keys| {
            if (kind != 4 or packet.len != 89) return;
            pending = null;
            if (!keys.verify(.responder, packet[57..89].*)) {
                c.cs_notice("Pairing failed", "The code was incorrect or the exchange could not be verified. Try a new code.");
                return;
            }
            if (addPeer(id, keys.encryption, ip, slice(&p.name))) |i| {
                _ = sendItem(.{ .kind = 1, .name = "@probe", .data = slice(&host) }, config.peers[i]);
            }
        },
    }
}
fn addPeer(id: core.Id, key: core.Key, ip: [16]u8, name: []const u8) ?usize {
    const i = peerIndex(id) orelse config.count;
    if (i == 16) return null;
    if (i == config.count) config.count += 1;
    config.peers[i] = .{ .id = id, .key = key, .ip = ip };
    peer_compatible[i] = true;
    c.cs_peer_authorized(@ptrCast(&ip));
    set(&config.peers[i].name, name);
    save();
    refresh();
    return i;
}
fn receive() void {
    var ip: [16]u8 = @splat(0);
    const n = c.cs_receive(&receive_buffer, receive_buffer.len, @ptrCast(&ip));
    if (n < core.overhead + 2) return;
    const packet = receive_buffer[0..@intCast(n)];
    const id: core.Id = packet[8..24].*;
    if (std.mem.eql(u8, &id, &config.id)) {
        if (std.mem.eql(u8, packet[0..8], "CLIPPR03")) c.cs_pair_close();
        return;
    }
    if (std.mem.eql(u8, packet[0..8], "CLIPPR03")) {
        receivePair(packet, ip, id);
        if (pending == null) c.cs_pair_close();
        return;
    }
    const i = peerIndex(id) orelse return;
    const received_at = c.cs_millis();
    const key = config.peers[i].key;
    const nonce: [12]u8 = packet[24..36].*;
    for (nonces[i]) |seen| if (std.mem.eql(u8, &seen, &nonce)) return;
    const item = core.decode(packet, key) catch |err| {
        c.cs_log_event("receive_rejected", null, &nonce, @ptrCast(&ip), 0, packet.len, c.cs_millis() - received_at);
        if (err == error.IncompatibleVersion) hideIncompatible(id);
        return;
    };
    c.cs_peer_authorized(@ptrCast(&ip));
    if (!peer_compatible[i]) {
        peer_compatible[i] = true;
        refresh();
    }
    nonces[i][nonce_next[i] % 64] = nonce;
    nonce_next[i] +%= 1;
    if (!std.mem.eql(u8, slice(&config.peers[i].ip), slice(&ip))) {
        config.peers[i].ip = ip;
        save();
    }
    if (std.mem.eql(u8, item.name, "@probe")) {
        var reply = config.peers[i];
        reply.ip = ip;
        _ = sendItem(.{ .kind = 1, .name = "@pair", .data = slice(&host) }, reply);
        return;
    }
    if (std.mem.eql(u8, item.name, "@pair")) return;
    c.cs_log_event("receive_authenticated", &item.event, &nonce, @ptrCast(&ip), item.kind, item.data.len, c.cs_millis() - received_at);
    if (paused) {
        c.cs_log_event("skipped_paused", &item.event, &nonce, @ptrCast(&ip), item.kind, item.data.len, 0);
        return;
    }
    if (seenEvent(item.event)) {
        c.cs_log_event("skipped_duplicate", &item.event, &nonce, @ptrCast(&ip), item.kind, item.data.len, 0);
        return;
    }
    recordEvent(item.event);
    const hash = core.fingerprint(item);
    if (last_hash) |last| {
        if (std.mem.eql(u8, &last, &hash)) {
            c.cs_log_event("clipboard_already_current", &item.event, &nonce, @ptrCast(&ip), item.kind, item.data.len, c.cs_millis() - received_at);
            return;
        }
    }
    if (writeClip(item)) {
        c.cs_log_event("clipboard_written", &item.event, &nonce, @ptrCast(&ip), item.kind, item.data.len, c.cs_millis() - received_at);
        remember(item);
        propagate(item, i);
    } else {
        c.cs_log_event("clipboard_write_failed", &item.event, &nonce, @ptrCast(&ip), item.kind, item.data.len, c.cs_millis() - received_at);
    }
}
fn discoveryPacket() [104]u8 {
    var buffer: [104]u8 = undefined;
    @memcpy(buffer[0..8], "CLIPDS02");
    @memcpy(buffer[8..24], &config.id);
    @memcpy(buffer[24..88], &host);
    @memcpy(buffer[88..104], &version.wire);
    return buffer;
}
fn discovery() void {
    const buffer = discoveryPacket();
    c.cs_announce(&buffer, buffer.len);
}
fn hideIncompatible(id: core.Id) void {
    for (&nearby) |*device| {
        if (device.*) |d| {
            if (std.mem.eql(u8, &d.id, &id)) device.* = null;
        }
    }
    if (peerIndex(id)) |i| {
        peer_compatible[i] = false;
        c.cs_peer_forget(@ptrCast(&config.peers[i].ip));
    }
    refresh();
}
fn updateNearby(packet: []const u8, ip: [16]u8) void {
    const legacy = packet.len == 88 and std.mem.eql(u8, packet[0..8], "CLIPDS01");
    if (!legacy and (packet.len != 104 or !std.mem.eql(u8, packet[0..8], "CLIPDS02"))) return;
    const id: core.Id = packet[8..24].*;
    if (std.mem.eql(u8, &id, &config.id)) return;
    if (legacy or !version.matches(packet[88..104].*)) {
        hideIncompatible(id);
        return;
    }
    var slot: ?usize = null;
    for (nearby, 0..) |device, i| {
        if (device) |d| {
            if (std.mem.eql(u8, &d.id, &id)) {
                slot = i;
                break;
            }
        }
    }
    if (slot == null) {
        for (nearby, 0..) |device, i| {
            if (device == null or c.cs_millis() - device.?.seen > 15000) {
                slot = i;
                break;
            }
        }
    }
    if (slot) |i| {
        var name: [64]u8 = packet[24..88].*;
        name[63] = 0;
        for (&name) |*ch| if (ch.* < 32 or ch.* > 126) {
            ch.* = ' ';
        };
        nearby[i] = .{ .id = id, .ip = ip, .name = name, .seen = c.cs_millis() };
    }
    // The version in discovery is only a hint. Saved peers must authenticate a
    // versioned response before they appear in the menu or receive clipboard content.
    if (peerIndex(id)) |i| {
        // Discovery may arrive from several network interfaces. Keep using a healthy
        // authenticated endpoint instead of probing every alternate advertised address.
        if (peer_compatible[i] and c.cs_peer_connected(@ptrCast(&config.peers[i].ip)) == 1) return;
        if (!peer_compatible[i] or c.cs_peer_connected(@ptrCast(&ip)) == 0 or !std.mem.eql(u8, slice(&config.peers[i].ip), slice(&ip))) {
            var candidate = config.peers[i];
            candidate.ip = ip;
            _ = sendItem(.{ .kind = 1, .name = "@probe", .data = slice(&host) }, candidate);
        }
    }
}
fn scan() void {
    var buffer: [256]u8 = undefined;
    var ip: [16]u8 = @splat(0);
    for (0..32) |_| {
        const n = c.cs_discover(&buffer, buffer.len, @ptrCast(&ip));
        if (n <= 0) break;
        updateNearby(buffer[0..@intCast(n)], ip);
    }
}
pub fn main() void {
    if (c.cs_storage_init() != 1) {
        std.debug.print("Cannot open private app storage, or Clipboard Sync is already running.\n", .{});
        return;
    }
    c.cs_log_init(version.text);
    c.cs_log_event("app_started_v" ++ version.text, null, null, "local", 0, 0, 0);
    var loaded: Config = .{};
    const n = c.cs_load(&loaded, @sizeOf(Config));
    if (n == @sizeOf(Config) and std.mem.eql(u8, &loaded.magic, "CLIPCF01") and loaded.count <= 16) {
        config = loaded;
        for (&config.peers) |*peer| {
            peer.ip[15] = 0;
            peer.name[63] = 0;
        }
    } else {
        if (!random(&config.id)) return;
        save();
    }
    if (c.cs_net_init() != 1) {
        std.debug.print("Cannot listen on TCP/UDP port 45832. Is another instance running?\n", .{});
        return;
    }
    defer c.cs_net_close();
    defer history.deinit();
    c.cs_hostname(&host, host.len);
    if (c.cs_init() != 1) {
        std.debug.print("Cannot initialize the native tray/clipboard backend. Linux requires an X11 session.\n", .{});
        return;
    }
    defer c.cs_shutdown();
    refresh();
    while (running) {
        c.cs_pump();
        cs_tick();
    }
}
var next_clip: u64 = 0;
var next_discovery: u64 = 0;
var tick_running = false;
// Keep notification-driven reads inside the same reentrancy guard as timer ticks.
export fn cs_clipboard_changed() void {
    next_clip = 0;
    cs_tick();
}
export fn cs_tick() void {
    if (tick_running or !running) return;
    tick_running = true;
    defer tick_running = false;
    const now = c.cs_millis();
    if (pending) |p| {
        if (now > p.until) {
            const initiated_here = p.exchange != .responder;
            pending = null;
            c.cs_pair_close();
            if (initiated_here) c.cs_notice("Pairing timed out", "Connected, but pairing did not finish. The code may be incorrect or expired. Generate a new code and make sure both computers are running this updated app.");
        }
    }
    if (pairing_code != null and (now > pairing_until or pairing_attempts >= 5)) {
        pairing_code = null;
        c.cs_pairing_hide();
    }
    for (0..8) |_| receive();
    if (pending) |p| {
        if (c.cs_pair_status() == 0) {
            pending = null;
            if (p.exchange != .responder) connectionFailed(p.ip);
        }
    }
    scan();
    if (now >= next_discovery) {
        discovery();
        refresh();
        next_discovery = now + 3000;
    }
    if (now >= next_clip and !paused) {
        next_clip = now + 200;
        cs_poll_clipboard();
    }
}

extern fn cs_test_reset() void;
extern fn cs_test_queue(data: [*]const u8, len: usize, ip: [*:0]const u8) void;
extern fn cs_test_writes() c_int;
extern fn cs_test_sends() c_int;
extern fn cs_test_saves() c_int;
extern fn cs_test_sent(data: [*]u8) usize;
extern fn cs_test_time(time: u64) void;
fn resetTest() void {
    history.deinit();
    config = .{ .id = @splat(1) };
    nearby = @splat(null);
    peer_compatible = @splat(false);
    last_hash = null;
    paused = false;
    pairing_code = null;
    pairing_attempts = 0;
    pending = null;
    nonces = @splat(@splat(@splat(0)));
    nonce_next = @splat(0);
    recent_events = @splat(@splat(0));
    recent_next = 0;
    c.cs_hostname(&host, host.len);
    running = true;
    tick_running = false;
    next_clip = 0;
    next_discovery = 0;
    cs_test_reset();
}
fn queueTest(id: core.Id, key: core.Key, nonce: u8, item: core.Item) !void {
    const packet = try core.encode(&send_buffer, id, @splat(nonce), key, item);
    cs_test_queue(packet.ptr, packet.len, "192.168.1.20");
}
fn queuePairTest(kind: u8, id: core.Id, session: [12]u8, body: []const u8) void {
    queuePairVersionTest(kind, id, session, body, version.wire);
}
fn queuePairVersionTest(kind: u8, id: core.Id, session: [12]u8, body: []const u8, remote: version.Wire) void {
    var packet: [186]u8 = @splat(0);
    @memcpy(packet[0..8], "CLIPPR03");
    @memcpy(packet[8..24], &id);
    @memcpy(packet[24..36], &session);
    @memcpy(packet[36..52], &remote);
    std.mem.writeInt(u32, packet[52..56], @intCast(body.len + 1), .big);
    packet[56] = kind;
    @memcpy(packet[57..][0..body.len], body);
    cs_test_queue(&packet, 57 + body.len, "192.168.1.20");
}
fn pairHelloTest(name: []const u8, public: [65]u8) [129]u8 {
    var body: [129]u8 = @splat(0);
    set(body[0..64], name);
    @memcpy(body[64..129], &public);
    return body;
}
test "unpaired devices cannot write or gain trust through the old long-key handshake" {
    resetTest();
    defer history.deinit();
    pairing_code = "123456".*;
    pairing_until = 10000;
    try queueTest(@splat(2), @splat(8), 1, .{ .kind = 1, .name = "@pair", .data = "Attacker" });
    receive();
    try std.testing.expectEqual(@as(u32, 0), config.count);
    try std.testing.expectEqual(@as(c_int, 0), cs_test_writes());
    try std.testing.expectEqual(@as(c_int, 0), cs_test_saves());
}
test "six-digit pairing requires mutual confirmation before saving either endpoint" {
    resetTest();
    defer history.deinit();
    cs_action(2, 0);
    const code = pairing_code.?;
    try std.testing.expectEqual(@as(c_int, 1), cs_test_pairing_visible());
    try std.testing.expectEqual(@as(c_int, 0), cs_test_notices());
    const client_id: core.Id = @splat(2);
    const session: [12]u8 = @splat(7);
    const client = try pairing.State.init(.initiator, code, @splat(1));
    const hello = pairHelloTest("Windows", client.public);
    queuePairTest(1, client_id, session, &hello);
    receive();
    try std.testing.expectEqual(@as(c_int, 1), cs_test_pairing_visible());
    try std.testing.expectEqual(@as(u32, 0), config.count);
    try std.testing.expectEqual(@as(c_int, 0), cs_test_saves());
    var reply: [186]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 186), cs_test_sent(&reply));
    const a = identity(client_id, hello[0..64].*, session);
    const b = identity(config.id, host, session);
    const keys = try client.finish(reply[121..186].*, &a, &b);
    queuePairTest(3, client_id, session, &keys.confirm_a);
    receive();
    try std.testing.expectEqual(@as(u32, 1), config.count);
    try std.testing.expectEqualStrings("Windows", slice(&config.peers[0].name));
    try std.testing.expectEqualSlices(u8, &keys.encryption, &config.peers[0].key);
    try std.testing.expectEqual(@as(c_int, 1), cs_test_saves());
    try std.testing.expectEqual(@as(c_int, 0), cs_test_writes());
    try std.testing.expect(pairing_code == null);
    try std.testing.expectEqual(@as(c_int, 0), cs_test_pairing_visible());
    try std.testing.expectEqual(@as(usize, 89), cs_test_sent(&reply));
    try std.testing.expect(keys.verify(.responder, reply[57..89].*));
    try std.testing.expect(!peer_compatible[0]);
    try queueTest(client_id, keys.encryption, 9, .{ .kind = 1, .name = "@probe", .data = "Windows" });
    receive();
    try std.testing.expect(peer_compatible[0]);
    // The receiver's authenticated reply is required before the initiating device trusts it.
    const server_id = config.id;
    const server_name = host;
    resetTest();
    config.id = client_id;
    host = hello[0..64].*;
    pending = .{ .id = server_id, .ip = @splat(0), .name = server_name, .session = session, .until = 10000, .exchange = .{ .initiator = client } };
    set(&pending.?.ip, "192.168.1.20");
    const server = try pairing.State.init(.responder, code, @splat(3));
    queuePairTest(2, server_id, session, &pairHelloTest(slice(&server_name), server.public));
    receive();
    try std.testing.expectEqual(@as(u32, 0), config.count);
    const server_keys = try server.finish(client.public, &a, &b);
    queuePairTest(4, server_id, session, &server_keys.confirm_b);
    receive();
    try std.testing.expectEqual(@as(u32, 1), config.count);
    try std.testing.expectEqualSlices(u8, &server_keys.encryption, &config.peers[0].key);
}
test "wrong code, expired window, replayed proof, and five-attempt limit never grant trust" {
    resetTest();
    defer history.deinit();
    pairing_code = "123456".*;
    pairing_until = 10000;
    const client_id: core.Id = @splat(2);
    const session: [12]u8 = @splat(7);
    const wrong = try pairing.State.init(.initiator, "654321".*, @splat(1));
    const hello = pairHelloTest("Windows", wrong.public);
    queuePairTest(1, client_id, session, &hello);
    receive();
    var reply: [186]u8 = undefined;
    _ = cs_test_sent(&reply);
    const a = identity(client_id, hello[0..64].*, session);
    const b = identity(config.id, host, session);
    const wrong_keys = try wrong.finish(reply[121..186].*, &a, &b);
    queuePairTest(3, client_id, session, &wrong_keys.confirm_a);
    receive();
    try std.testing.expectEqual(@as(u32, 0), config.count);
    try std.testing.expect(pending == null);
    // A captured confirmation cannot be used against a new exchange/session.
    queuePairTest(3, client_id, session, &wrong_keys.confirm_a);
    receive();
    try std.testing.expectEqual(@as(c_int, 0), cs_test_saves());
    for (0..4) |_| {
        queuePairTest(1, client_id, session, &hello);
        receive();
        pending = null;
    }
    try std.testing.expectEqual(@as(u8, 5), pairing_attempts);
    const sends = cs_test_sends();
    queuePairTest(1, client_id, session, &hello);
    receive();
    try std.testing.expectEqual(sends, cs_test_sends());
    pairing_attempts = 0;
    pairing_until = 999;
    queuePairTest(1, client_id, session, &hello);
    receive();
    try std.testing.expectEqual(@as(u8, 0), pairing_attempts);
    try std.testing.expectEqual(@as(u32, 0), config.count);
}
test "incoming content writes automatically, forwards once, and ignores replay and cycle" {
    resetTest();
    defer history.deinit();
    _ = addPeer(@splat(2), @splat(9), @splat(0), "Windows");
    _ = addPeer(@splat(3), @splat(8), @splat(0), "Linux");
    const item = core.Item{ .kind = 1, .name = "", .data = "copy once, paste anywhere", .event = @splat(4) };
    try queueTest(@splat(2), @splat(9), 1, item);
    receive();
    try std.testing.expectEqual(@as(c_int, 1), cs_test_writes());
    try std.testing.expectEqual(@as(c_int, 1), cs_test_sends());
    try std.testing.expectEqualStrings(item.data, history.entries[0].?.data);
    try queueTest(@splat(2), @splat(9), 1, item);
    receive();
    // A copy arriving back through a different peer has a new transport nonce
    // but retains its original event ID.
    try queueTest(@splat(3), @splat(8), 2, item);
    receive();
    try std.testing.expectEqual(@as(c_int, 1), cs_test_writes());
    try std.testing.expectEqual(@as(c_int, 1), cs_test_sends());
    paused = true;
    try queueTest(@splat(2), @splat(9), 3, .{ .kind = 1, .name = "", .data = "paused", .event = @splat(5) });
    receive();
    try std.testing.expectEqual(@as(c_int, 1), cs_test_writes());
}
test "history click restores and shares a file; forgetting rejects future traffic" {
    resetTest();
    defer history.deinit();
    _ = addPeer(@splat(2), @splat(9), @splat(0), "Windows");
    try history.push(.{ .kind = 2, .name = "archive.zip", .data = "PK\x00\xff" });
    cs_action(1, 0);
    try std.testing.expectEqual(@as(c_int, 1), cs_test_writes());
    try std.testing.expectEqual(@as(c_int, 1), cs_test_sends());
    cs_action(6, 0);
    try std.testing.expectEqual(@as(u32, 0), config.count);
    try queueTest(@splat(2), @splat(9), 4, .{ .kind = 1, .name = "", .data = "forgotten", .event = @splat(6) });
    receive();
    try std.testing.expectEqual(@as(c_int, 1), cs_test_writes());
}

extern fn cs_test_copy(text: [*:0]const u8) void;
extern fn cs_test_pairing_visible() c_int;
extern fn cs_test_notices() c_int;
test "history preview limits characters, preserves Unicode, and marks truncation" {
    var preview: [243]u8 = undefined;
    const exact: [60]u8 = @splat('a');
    try std.testing.expectEqualStrings(&exact, historyPreview(&preview, &exact));
    const long: [61]u8 = @splat('b');
    const shortened = historyPreview(&preview, &long);
    try std.testing.expectEqual(@as(usize, 63), shortened.len);
    try std.testing.expect(std.mem.endsWith(u8, shortened, "…"));
    var unicode: [244]u8 = undefined;
    for (0..61) |i| @memcpy(unicode[i * 4 ..][0..4], "🙂");
    const shortened_unicode = historyPreview(&preview, &unicode);
    try std.testing.expectEqual(@as(usize, 243), shortened_unicode.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(shortened_unicode));
    try std.testing.expectEqualStrings("first second", historyPreview(&preview, "first\nsecond"));
}
test "pause action reflects the state in the menu" {
    resetTest();
    defer history.deinit();
    try std.testing.expectEqualStrings("Pause syncing", std.mem.span(cs_sync_action_label()));
    try std.testing.expectEqual(@as(c_int, 0), cs_is_paused());
    cs_action(5, 0);
    try std.testing.expectEqualStrings("Resume syncing", std.mem.span(cs_sync_action_label()));
    try std.testing.expectEqual(@as(c_int, 1), cs_is_paused());
    cs_action(5, 0);
    try std.testing.expectEqualStrings("Pause syncing", std.mem.span(cs_sync_action_label()));
}
test "menu refresh captures newest clipboard first and history selections update recency" {
    resetTest();
    defer history.deinit();
    for ([_][*:0]const u8{ "First copy", "Second copy", "Third copy" }) |text| {
        cs_test_copy(text);
        cs_poll_clipboard();
    }
    try std.testing.expectEqualStrings("1. Third copy", std.mem.span(cs_history_label(0)));
    try std.testing.expectEqualStrings("2. Second copy", std.mem.span(cs_history_label(1)));
    try std.testing.expectEqualStrings("3. First copy", std.mem.span(cs_history_label(2)));
    cs_action(1, 2);
    try std.testing.expectEqualStrings("1. First copy", std.mem.span(cs_history_label(0)));
    try std.testing.expectEqualStrings("2. Third copy", std.mem.span(cs_history_label(1)));
    try std.testing.expectEqualStrings("3. Second copy", std.mem.span(cs_history_label(2)));
    cs_test_copy("Second copy");
    cs_poll_clipboard();
    try std.testing.expectEqualStrings("1. Second copy", std.mem.span(cs_history_label(0)));
    try std.testing.expectEqualStrings("2. First copy", std.mem.span(cs_history_label(1)));
    try std.testing.expectEqualStrings("3. Third copy", std.mem.span(cs_history_label(2)));
}

test "discovery shows only matching versions and removes peers that change version" {
    resetTest();
    defer history.deinit();
    var packet = discoveryPacket();
    @memcpy(packet[8..24], &@as(core.Id, @splat(2)));
    var ip: [16]u8 = @splat(0);
    set(&ip, "192.168.1.20");
    updateNearby(&packet, ip);
    refresh();
    try std.testing.expect(slice(cs_nearby_label(0)[0..160]).len > 0);
    packet[88] = '9';
    updateNearby(&packet, ip);
    try std.testing.expectEqualStrings("", std.mem.span(cs_nearby_label(0)));
    packet[88..104].* = version.wire;
    updateNearby(&packet, ip);
    refresh();
    try std.testing.expect(nearby[0] != null);
    @memcpy(packet[0..8], "CLIPDS01");
    updateNearby(packet[0..88], ip);
    try std.testing.expect(nearby[0] == null);
}
test "manual IP pairing rejects foreign or missing versions without consuming PIN attempts" {
    resetTest();
    defer history.deinit();
    cs_action(2, 0);
    const client = try pairing.State.init(.initiator, pairing_code.?, @splat(1));
    const body = pairHelloTest("Other version", client.public);
    var other = version.wire;
    other[0] = '9';
    queuePairVersionTest(1, @splat(2), @splat(7), &body, other);
    receive();
    try std.testing.expectEqual(@as(u32, 0), config.count);
    try std.testing.expectEqual(@as(u8, 0), pairing_attempts);
    try std.testing.expect(pending == null);
    var rejection: [186]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 57), cs_test_sent(&rejection));
    try std.testing.expectEqual(@as(u8, 5), rejection[56]);
    try std.testing.expectEqualSlices(u8, &version.wire, rejection[36..52]);
    queuePairVersionTest(1, @splat(2), @splat(7), &body, @splat(0));
    receive();
    try std.testing.expectEqual(@as(u8, 0), pairing_attempts);
    // A manually entered IP has no expected device ID, so version checks must stand alone.
    var ip: [16]u8 = @splat(0);
    set(&ip, "192.168.1.20");
    pending = .{ .id = null, .ip = ip, .name = @splat(0), .session = @splat(7), .until = 10000, .exchange = .{ .initiator = client } };
    queuePairVersionTest(2, @splat(2), @splat(7), &body, other);
    receive();
    try std.testing.expect(pending == null);
    try std.testing.expectEqual(@as(u32, 0), config.count);
    try std.testing.expectEqual(@as(c_int, 1), cs_test_notices());
}
test "saved peers need authenticated matching versions before appearing or syncing" {
    resetTest();
    defer history.deinit();
    const id: core.Id = @splat(2);
    const key: core.Key = @splat(9);
    var ip: [16]u8 = @splat(0);
    set(&ip, "192.168.1.20");
    _ = addPeer(id, key, ip, "Saved Windows");
    // Startup retains trust keys but has not verified the running peer's app version.
    peer_compatible[0] = false;
    refresh();
    try std.testing.expectEqualStrings("", std.mem.span(cs_peer_label(0)));
    propagate(.{ .kind = 1, .name = "", .data = "Do not send yet" }, null);
    try std.testing.expectEqual(@as(c_int, 0), cs_test_sends());
    var announcement = discoveryPacket();
    @memcpy(announcement[8..24], &id);
    updateNearby(&announcement, ip);
    try std.testing.expectEqual(@as(c_int, 1), cs_test_sends()); // Versioned challenge only.
    try std.testing.expect(!peer_compatible[0]);
    try queueTest(id, key, 1, .{ .kind = 1, .name = "@pair", .data = "Saved Windows" });
    receive();
    try std.testing.expect(peer_compatible[0]);
    try std.testing.expect(std.mem.span(cs_peer_label(0)).len > 0);
    var other = version.wire;
    other[0] = '9';
    const bad = try core.encode(&send_buffer, id, @splat(2), key, .{ .kind = 1, .name = "", .data = "Wrong version", .app_version = other });
    cs_test_queue(bad.ptr, bad.len, "192.168.1.20");
    receive();
    try std.testing.expect(!peer_compatible[0]);
    try std.testing.expectEqual(@as(c_int, 0), cs_test_writes());
    try std.testing.expectEqualStrings("", std.mem.span(cs_peer_label(0)));
    const sent = cs_test_sends();
    propagate(.{ .kind = 1, .name = "", .data = "Still blocked" }, null);
    try std.testing.expectEqual(sent, cs_test_sends());
}

test "fresh PIN pairing repairs a peer record left by an incomplete handshake" {
    resetTest();
    defer history.deinit();
    const id: core.Id = @splat(2);
    const old_key: core.Key = @splat(8);
    var ip: [16]u8 = @splat(0);
    set(&ip, "192.168.1.20");
    _ = addPeer(id, old_key, ip, "Incomplete Windows");
    cs_action(2, 0);
    const client = try pairing.State.init(.initiator, pairing_code.?, @splat(1));
    const hello = pairHelloTest("Windows", client.public);
    const session: [12]u8 = @splat(7);
    queuePairTest(1, id, session, &hello);
    receive();
    try std.testing.expect(pending != null);
    var reply: [186]u8 = undefined;
    _ = cs_test_sent(&reply);
    const a = identity(id, hello[0..64].*, session);
    const b = identity(config.id, host, session);
    const keys = try client.finish(reply[121..186].*, &a, &b);
    queuePairTest(3, id, session, &keys.confirm_a);
    receive();
    try std.testing.expectEqual(@as(u32, 1), config.count);
    try std.testing.expectEqualSlices(u8, &keys.encryption, &config.peers[0].key);
    try std.testing.expect(!peer_compatible[0]);
    try queueTest(id, keys.encryption, 10, .{ .kind = 1, .name = "@probe", .data = "Windows" });
    receive();
    try std.testing.expect(peer_compatible[0]);
    try queueTest(id, old_key, 11, .{ .kind = 1, .name = "", .data = "Stale session", .event = @splat(1) });
    receive();
    try std.testing.expectEqual(@as(c_int, 0), cs_test_writes());
    try queueTest(id, keys.encryption, 12, .{ .kind = 1, .name = "", .data = "Recovered sync", .event = @splat(2) });
    receive();
    try std.testing.expectEqual(@as(c_int, 1), cs_test_writes());
}
test "sync during a menu session preserves the clicked history item's identity" {
    resetTest();
    defer history.deinit();
    _ = addPeer(@splat(2), @splat(9), @splat(0), "Windows");
    remember(.{ .kind = 1, .name = "", .data = "Item displayed when the menu opened" });
    var snapshot: [32]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 1), cs_history_id(0, &snapshot));
    try queueTest(@splat(2), @splat(9), 1, .{ .kind = 1, .name = "", .data = "Arrived while menu was open", .event = @splat(1) });
    cs_tick();
    try std.testing.expectEqualStrings("Arrived while menu was open", history.entries[0].?.data);
    cs_restore_history(&snapshot);
    try std.testing.expectEqualStrings("Item displayed when the menu opened", history.entries[0].?.data);
    try std.testing.expectEqual(@as(c_int, 2), cs_test_writes());
}

test "a local copy on either endpoint is encrypted and applied to the other endpoint's clipboard and history" {
    resetTest();
    defer history.deinit();
    const key: core.Key = @splat(9);
    _ = addPeer(@splat(2), key, @splat(0), "Windows");
    cs_test_copy("Copied on the Mac");
    cs_poll_clipboard();
    const packet = try allocator.alloc(u8, core.max_packet);
    defer allocator.free(packet);
    const mac_len = cs_test_sent(packet.ptr);
    resetTest();
    config.id = @splat(2);
    _ = addPeer(@splat(1), key, @splat(0), "Mac");
    cs_test_queue(packet.ptr, mac_len, "192.168.1.20");
    cs_tick();
    try std.testing.expectEqual(@as(c_int, 1), cs_test_writes());
    try std.testing.expectEqualStrings("Copied on the Mac", history.entries[0].?.data);
    cs_test_copy("Copied on Windows");
    cs_poll_clipboard();
    const windows_len = cs_test_sent(packet.ptr);
    resetTest();
    _ = addPeer(@splat(2), key, @splat(0), "Windows");
    cs_test_queue(packet.ptr, windows_len, "192.168.1.20");
    cs_tick();
    try std.testing.expectEqual(@as(c_int, 1), cs_test_writes());
    try std.testing.expectEqualStrings("Copied on Windows", history.entries[0].?.data);
}

extern fn cs_test_log_count() c_int;
extern fn cs_test_log_stage(i: c_int) [*:0]const u8;
extern fn cs_test_log_event(i: c_int) [*]const u8;
test "sync log correlates send, authenticated receipt, clipboard write and paused skip" {
    resetTest();
    defer history.deinit();
    _ = addPeer(@splat(2), @splat(9), @splat(0), "Windows");
    cs_test_copy("private speech text");
    cs_poll_clipboard();
    try std.testing.expectEqual(@as(c_int, 2), cs_test_log_count());
    try std.testing.expectEqualStrings("copy_detected", std.mem.span(cs_test_log_stage(0)));
    try std.testing.expectEqualStrings("send_queued", std.mem.span(cs_test_log_stage(1)));
    try std.testing.expectEqualSlices(u8, cs_test_log_event(0)[0..16], cs_test_log_event(1)[0..16]);
    const item = core.Item{ .kind = 1, .name = "", .data = "remote secret", .event = @splat(4) };
    try queueTest(@splat(2), @splat(9), 1, item);
    receive();
    try std.testing.expectEqualStrings("receive_authenticated", std.mem.span(cs_test_log_stage(2)));
    try std.testing.expectEqualStrings("clipboard_written", std.mem.span(cs_test_log_stage(3)));
    try std.testing.expectEqualSlices(u8, &item.event, cs_test_log_event(3)[0..16]);
    paused = true;
    try queueTest(@splat(2), @splat(9), 2, .{ .kind = 1, .name = "", .data = "ignored", .event = @splat(5) });
    receive();
    try std.testing.expectEqualStrings("skipped_paused", std.mem.span(cs_test_log_stage(5)));
    try std.testing.expectEqual(@as(c_int, 1), cs_test_writes());
}

test "clipboard notification bypasses the polling interval and respects pause" {
    resetTest();
    defer history.deinit();
    cs_test_copy("first");
    cs_tick();
    cs_test_time(1001);
    cs_test_copy("second");
    cs_clipboard_changed();
    try std.testing.expectEqualStrings("second", history.entries[0].?.data);
    paused = true;
    cs_test_copy("paused");
    cs_clipboard_changed();
    try std.testing.expectEqualStrings("second", history.entries[0].?.data);
    paused = false;
    cs_clipboard_changed();
    try std.testing.expectEqualStrings("paused", history.entries[0].?.data);
}

test "discovery preserves a healthy peer endpoint and control probes do not clutter the log" {
    resetTest();
    defer history.deinit();
    var active_ip: [16]u8 = @splat(0);
    set(&active_ip, "192.168.1.41");
    _ = addPeer(@splat(2), @splat(9), active_ip, "Windows");
    var alternate_ip: [16]u8 = @splat(0);
    set(&alternate_ip, "192.168.1.178");
    var announcement = discoveryPacket();
    announcement[8..24].* = @splat(2);
    updateNearby(&announcement, alternate_ip);
    try std.testing.expectEqual(@as(c_int, 0), cs_test_sends());
    try std.testing.expectEqualSlices(u8, &active_ip, &config.peers[0].ip);
    // A saved peer not yet authenticated must still receive a probe.
    peer_compatible[0] = false;
    updateNearby(&announcement, alternate_ip);
    try std.testing.expectEqual(@as(c_int, 1), cs_test_sends());
    try std.testing.expectEqual(@as(c_int, 0), cs_test_log_count());
}
