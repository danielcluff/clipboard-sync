const std = @import("std");
const core = @import("core.zig");
const version = @import("version.zig");
const pairing = @import("pairing.zig");
const c = @import("bridge.zig");
const allocator = std.heap.page_allocator;
// recv_counter is the highest authenticated counter accepted from this peer; bit k of
// recv_window records counter (recv_counter - k). Both persist so restarts keep rejecting replays.
const Peer = extern struct { id: core.Id = @splat(0), key: core.Key = @splat(0), ip: [16]u8 = @splat(0), name: [64]u8 = @splat(0), recv_counter: u64 = 0, recv_window: u64 = 0 };
// send_reserved is persisted ahead of use so outgoing counters never repeat after a restart.
const Config = extern struct { magic: [8]u8 = "CLIPCF02".*, id: core.Id = @splat(0), count: u32 = 0, send_reserved: u64 = 0, peers: [16]Peer = @splat(Peer{}) };
const LegacyPeer = extern struct { id: core.Id, key: core.Key, ip: [16]u8, name: [64]u8 };
const LegacyConfig = extern struct { magic: [8]u8, id: core.Id, count: u32, peers: [16]LegacyPeer };
const Nearby = struct { id: core.Id, ip: [16]u8, name: [64]u8, seen: u64 };
var config: Config = .{};
var peer_compatible: [16]bool = @splat(false);
// Keys survive app upgrades, so an authenticated frame from another version may be a
// recording replayed from before the upgrade. Such a frame only makes the peer suspect:
// it is probed, and demoted only if no fresh, counter-checked frame arrives in time.
const suspect_timeout = 15000;
var suspect_until: [16]u64 = @splat(0);
var suspect_counter: [16]u64 = @splat(0);
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
var send_next: u64 = 1;
const counter_reservation = 1024;
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
// Replay state is saved for every accepted frame, so report a failure once, not per frame.
var save_failure_reported = false;
fn save() void {
    if (c.cs_save(&config, @sizeOf(Config)) == 1) {
        save_failure_reported = false;
    } else if (!save_failure_reported) {
        save_failure_reported = true;
        c.cs_notice("Could not save devices", "Check permissions on the Clipboard Sync data directory.");
    }
}
fn loadConfig(bytes: []const u8) ?Config {
    var result: Config = .{};
    if (bytes.len == @sizeOf(Config) and std.mem.eql(u8, bytes[0..8], "CLIPCF02")) {
        result = std.mem.bytesToValue(Config, bytes[0..@sizeOf(Config)]);
    } else if (bytes.len == @sizeOf(LegacyConfig) and std.mem.eql(u8, bytes[0..8], "CLIPCF01")) {
        // Older files kept no replay state; peers start with an empty window.
        const legacy = std.mem.bytesToValue(LegacyConfig, bytes[0..@sizeOf(LegacyConfig)]);
        result.id = legacy.id;
        result.count = legacy.count;
        for (legacy.peers, &result.peers) |old, *peer| peer.* = .{ .id = old.id, .key = old.key, .ip = old.ip, .name = old.name };
    } else return null;
    if (result.count > 16) return null;
    for (&result.peers) |*peer| {
        peer.ip[15] = 0;
        peer.name[63] = 0;
    }
    return result;
}
fn nextCounter() u64 {
    if (send_next >= config.send_reserved) {
        config.send_reserved = send_next + counter_reservation;
        save();
    }
    defer send_next += 1;
    return send_next;
}
// Sliding-window replay check (as in IPsec): accept each counter once, tolerating
// reordering of up to 64 frames across reconnects and alternate channels.
fn acceptCounter(peer: *Peer, counter: u64) bool {
    if (counter == 0) return false;
    if (counter > peer.recv_counter) {
        const shift = counter - peer.recv_counter;
        peer.recv_window = if (shift >= 64) 1 else (peer.recv_window << @intCast(shift)) | 1;
        peer.recv_counter = counter;
        return true;
    }
    const offset = peer.recv_counter - counter;
    if (offset >= 64) return false;
    const bit = @as(u64, 1) << @intCast(offset);
    if (peer.recv_window & bit != 0) return false;
    peer.recv_window |= bit;
    return true;
}
// Control messages are text items with reserved names, so files may use any valid name.
fn isControl(item: core.Item, name: []const u8) bool {
    return item.kind == 1 and std.mem.eql(u8, item.name, name);
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
            // A newer local copy supersedes any remote update still waiting to be written.
            cancelWriteRetry();
            remember(item);
            propagateLocal(item);
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
    // Every saved device stays listed so it can be revoked while offline or unverified.
    for (&peer_labels, 0..) |*label, i| {
        @memset(label, 0);
        if (i < config.count) {
            const state = if (peer_compatible[i]) "" else " · offline";
            _ = std.mem.printSentinel(label, "{s} ({s}){s} — Forget", .{ slice(&config.peers[i].name), slice(&config.peers[i].ip), state }, 0) catch unreachable;
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
    var framed = item;
    framed.counter = nextCounter();
    const packet = core.encode(&send_buffer, config.id, nonce, peer.key, framed) catch return false;
    if (isControl(item, "@probe") or isControl(item, "@pair"))
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
fn propagateLocal(original: core.Item) void {
    var item = original;
    if (!random(&item.event)) return;
    recordEvent(item.event);
    c.cs_log_event("copy_detected", &item.event, null, "local", item.kind, item.data.len, 0);
    forward(item, null);
}
// Relays an item with its existing event ID to every verified peer except its origin.
fn forward(item: core.Item, except: ?usize) void {
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
// A remote update whose clipboard write failed (for example, another app briefly holds
// the Windows clipboard). Only the newest is kept; later copies supersede it.
const WriteRetry = struct { from: core.Id, ip: [16]u8, kind: u8, event: core.Id, name: []u8, data: []u8, received_at: u64, attempts: u8, next: u64 };
var write_retry: ?WriteRetry = null;
const retry_interval = 250;
const retry_attempts = 10;
fn cancelWriteRetry() void {
    if (write_retry) |r| {
        allocator.free(r.name);
        allocator.free(r.data);
        write_retry = null;
    }
}
fn scheduleWriteRetry(item: core.Item, from: core.Id, ip: [16]u8, received_at: u64) void {
    cancelWriteRetry();
    const name = allocator.dupe(u8, item.name) catch return;
    const data = allocator.dupe(u8, item.data) catch {
        allocator.free(name);
        return;
    };
    write_retry = .{ .from = from, .ip = ip, .kind = item.kind, .event = item.event, .name = name, .data = data, .received_at = received_at, .attempts = 0, .next = c.cs_millis() + retry_interval };
}
fn delivered(item: core.Item, from: ?usize) void {
    recordEvent(item.event);
    remember(item);
    forward(item, from);
}
fn retryWrite(now: u64) void {
    const r = write_retry orelse return;
    if (now < r.next) return;
    const item = core.Item{ .kind = r.kind, .event = r.event, .name = r.name, .data = r.data };
    const hash = core.fingerprint(item);
    if (paused or seenEvent(r.event) or (last_hash != null and std.mem.eql(u8, &last_hash.?, &hash))) {
        cancelWriteRetry();
        return;
    }
    if (writeClip(item)) {
        c.cs_log_event("clipboard_written", &r.event, null, @ptrCast(&r.ip), item.kind, item.data.len, now - r.received_at);
        delivered(item, peerIndex(r.from));
        cancelWriteRetry();
    } else if (r.attempts + 1 >= retry_attempts) {
        c.cs_log_event("clipboard_write_abandoned", &r.event, null, @ptrCast(&r.ip), item.kind, item.data.len, now - r.received_at);
        cancelWriteRetry();
    } else {
        write_retry.?.attempts += 1;
        write_retry.?.next = now + retry_interval;
    }
}
export fn cs_action(action: c_int, index: c_int) void {
    switch (action) {
        1 => { // Restore a history entry and sync it like a new copy.
            if (index < 0 or index >= 10) return;
            if (history.entries[@intCast(index)]) |entry| {
                const item = core.Item{ .kind = entry.kind, .name = entry.name, .data = entry.data };
                if (writeClip(item)) {
                    cancelWriteRetry();
                    last_hash = entry.hash;
                    if (!paused) propagateLocal(item);
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
            if (paused) cancelWriteRetry();
            refresh();
        },
        6 => {
            if (index < 0 or index >= config.count) return;
            const i: usize = @intCast(index);
            c.cs_peer_forget(@ptrCast(&config.peers[i].ip));
            var j = i;
            while (j + 1 < config.count) : (j += 1) {
                config.peers[j] = config.peers[j + 1];
                peer_compatible[j] = peer_compatible[j + 1];
                suspect_until[j] = suspect_until[j + 1];
                suspect_counter[j] = suspect_counter[j + 1];
            }
            config.count -= 1;
            config.peers[config.count] = .{};
            peer_compatible[config.count] = false;
            suspect_until[config.count] = 0;
            save();
            refresh();
        },
        7 => running = false,
        8 => {
            c.cs_startup_toggle();
            refresh();
        },
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
        // Unauthenticated: anyone can claim a saved peer's ID, so only hide the nearby entry.
        hideNearby(id);
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
    suspect_until[i] = 0;
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
    const item = core.decode(packet, key) catch |err| {
        c.cs_log_event("receive_rejected", null, &nonce, @ptrCast(&ip), 0, packet.len, c.cs_millis() - received_at);
        if (err == error.IncompatibleVersion) suspectIncompatible(i);
        return;
    };
    if (!acceptCounter(&config.peers[i], item.counter)) {
        c.cs_log_event("receive_replayed", null, &nonce, @ptrCast(&ip), 0, packet.len, c.cs_millis() - received_at);
        return;
    }
    // A counter newer than any seen before the mismatch proves the peer runs this version now.
    if (suspect_until[i] != 0 and item.counter > suspect_counter[i]) suspect_until[i] = 0;
    c.cs_peer_authorized(@ptrCast(&ip));
    if (!peer_compatible[i]) {
        peer_compatible[i] = true;
        refresh();
    }
    if (!std.mem.eql(u8, slice(&config.peers[i].ip), slice(&ip))) config.peers[i].ip = ip;
    // Persist the replay window before acting, so a restart cannot accept this frame again.
    save();
    if (isControl(item, "@probe")) {
        var reply = config.peers[i];
        reply.ip = ip;
        _ = sendItem(.{ .kind = 1, .name = "@pair", .data = slice(&host) }, reply);
        return;
    }
    if (isControl(item, "@pair")) return;
    c.cs_log_event("receive_authenticated", &item.event, &nonce, @ptrCast(&ip), item.kind, item.data.len, c.cs_millis() - received_at);
    if (paused) {
        c.cs_log_event("skipped_paused", &item.event, &nonce, @ptrCast(&ip), item.kind, item.data.len, 0);
        return;
    }
    if (seenEvent(item.event)) {
        c.cs_log_event("skipped_duplicate", &item.event, &nonce, @ptrCast(&ip), item.kind, item.data.len, 0);
        return;
    }
    const hash = core.fingerprint(item);
    if (last_hash) |last| {
        if (std.mem.eql(u8, &last, &hash)) {
            recordEvent(item.event);
            c.cs_log_event("clipboard_already_current", &item.event, &nonce, @ptrCast(&ip), item.kind, item.data.len, c.cs_millis() - received_at);
            return;
        }
    }
    // The event is recorded only once written, so a retry or relayed copy can still apply it.
    if (writeClip(item)) {
        c.cs_log_event("clipboard_written", &item.event, &nonce, @ptrCast(&ip), item.kind, item.data.len, c.cs_millis() - received_at);
        cancelWriteRetry();
        delivered(item, i);
    } else {
        c.cs_log_event("clipboard_write_failed", &item.event, &nonce, @ptrCast(&ip), item.kind, item.data.len, c.cs_millis() - received_at);
        scheduleWriteRetry(item, id, ip, received_at);
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
fn hideNearby(id: core.Id) void {
    for (&nearby) |*device| {
        if (device.*) |d| {
            if (std.mem.eql(u8, &d.id, &id)) device.* = null;
        }
    }
    refresh();
}
fn suspectIncompatible(i: usize) void {
    // Repeated mismatches never extend the deadline, so a peer that really changed
    // version is still demoted on time.
    if (!peer_compatible[i] or suspect_until[i] != 0) return;
    suspect_until[i] = c.cs_millis() + suspect_timeout;
    suspect_counter[i] = config.peers[i].recv_counter;
    _ = sendItem(.{ .kind = 1, .name = "@probe", .data = slice(&host) }, config.peers[i]);
}
fn expireSuspects(now: u64) void {
    for (0..config.count) |i| {
        if (suspect_until[i] != 0 and now > suspect_until[i]) {
            suspect_until[i] = 0;
            c.cs_log_event("peer_version_mismatch", null, null, @ptrCast(&config.peers[i].ip), 0, 0, 0);
            hideIncompatible(config.peers[i].id);
        }
    }
}
// Only after a mismatch the peer could not refute with a fresh frame (see suspectIncompatible).
fn hideIncompatible(id: core.Id) void {
    hideNearby(id);
    if (peerIndex(id)) |i| {
        peer_compatible[i] = false;
        suspect_until[i] = 0;
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
        // Discovery is unauthenticated; never let it demote or disconnect a saved peer.
        hideNearby(id);
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
    var raw: [@sizeOf(Config)]u8 = undefined;
    const n = c.cs_load(&raw, raw.len);
    if (n > 0 and loadConfig(raw[0..@intCast(n)]) != null) {
        config = loadConfig(raw[0..@intCast(n)]).?;
        send_next = @max(1, config.send_reserved);
        // Rewrite a migrated legacy file in the current format immediately.
        if (n != @sizeOf(Config)) save();
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
    retryWrite(now);
    expireSuspects(now);
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
    suspect_until = @splat(0);
    suspect_counter = @splat(0);
    last_hash = null;
    paused = false;
    pairing_code = null;
    pairing_attempts = 0;
    pending = null;
    cancelWriteRetry();
    send_next = 1;
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
    var framed = item;
    if (framed.counter == 0) framed.counter = nonce;
    const packet = try core.encode(&send_buffer, id, @splat(nonce), key, framed);
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
    try std.testing.expectEqualStrings("Saved Windows (192.168.1.20) · offline — Forget", std.mem.span(cs_peer_label(0)));
    propagateLocal(.{ .kind = 1, .name = "", .data = "Do not send yet" });
    try std.testing.expectEqual(@as(c_int, 0), cs_test_sends());
    var announcement = discoveryPacket();
    @memcpy(announcement[8..24], &id);
    updateNearby(&announcement, ip);
    try std.testing.expectEqual(@as(c_int, 1), cs_test_sends()); // Versioned challenge only.
    try std.testing.expect(!peer_compatible[0]);
    try queueTest(id, key, 1, .{ .kind = 1, .name = "@pair", .data = "Saved Windows" });
    receive();
    try std.testing.expect(peer_compatible[0]);
    try std.testing.expectEqualStrings("Saved Windows (192.168.1.20) — Forget", std.mem.span(cs_peer_label(0)));
    var other = version.wire;
    other[0] = '9';
    const bad = try core.encode(&send_buffer, id, @splat(2), key, .{ .kind = 1, .name = "", .data = "Wrong version", .app_version = other });
    var mismatch: [256]u8 = undefined;
    const mismatch_len = bad.len;
    @memcpy(mismatch[0..mismatch_len], bad);
    const probes = cs_test_sends();
    cs_test_queue(&mismatch, mismatch_len, "192.168.1.20");
    receive();
    // The mismatch could be a recording, so the peer is probed before it is demoted.
    try std.testing.expect(peer_compatible[0]);
    try std.testing.expectEqual(probes + 1, cs_test_sends());
    try std.testing.expectEqual(@as(c_int, 0), cs_test_writes());
    // Further mismatches neither send more probes nor extend the deadline.
    cs_test_time(1000 + 10000);
    cs_test_queue(&mismatch, mismatch_len, "192.168.1.20");
    receive();
    try std.testing.expectEqual(probes + 1, cs_test_sends());
    cs_test_time(1000 + suspect_timeout + 1);
    cs_tick();
    try std.testing.expect(!peer_compatible[0]);
    try std.testing.expectEqual(@as(c_int, 0), cs_test_writes());
    try std.testing.expectEqualStrings("Saved Windows (192.168.1.20) · offline — Forget", std.mem.span(cs_peer_label(0)));
    const sent = cs_test_sends();
    propagateLocal(.{ .kind = 1, .name = "", .data = "Still blocked" });
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

extern fn cs_test_fail_writes(count: c_int) void;
test "replayed frames stay rejected after a restart and cannot redirect a peer" {
    resetTest();
    defer history.deinit();
    const id: core.Id = @splat(2);
    const key: core.Key = @splat(9);
    var home: [16]u8 = @splat(0);
    set(&home, "192.168.1.20");
    _ = addPeer(id, key, home, "Windows");
    var captured: [256]u8 = undefined;
    const original = try core.encode(&captured, id, @splat(1), key, .{ .kind = 1, .name = "", .data = "old secret", .event = @splat(4), .counter = 100 });
    const captured_len = original.len;
    var replay: [256]u8 = undefined;
    @memcpy(replay[0..captured_len], captured[0..captured_len]);
    cs_test_queue(&replay, captured_len, "192.168.1.20");
    receive();
    try std.testing.expectEqual(@as(c_int, 1), cs_test_writes());
    // Out-of-order delivery inside the window is accepted once; far older counters are not.
    try queueTest(id, key, 2, .{ .kind = 1, .name = "", .data = "late", .event = @splat(5), .counter = 40 });
    receive();
    try std.testing.expectEqual(@as(c_int, 2), cs_test_writes());
    try queueTest(id, key, 3, .{ .kind = 1, .name = "", .data = "late again", .event = @splat(6), .counter = 40 });
    receive();
    try queueTest(id, key, 4, .{ .kind = 1, .name = "", .data = "too old", .event = @splat(7), .counter = 30 });
    receive();
    try std.testing.expectEqual(@as(c_int, 2), cs_test_writes());
    // Restart: only persisted state survives; event and history caches are empty.
    const restored = loadConfig(std.mem.asBytes(&config)).?;
    resetTest();
    config = restored;
    @memcpy(replay[0..captured_len], captured[0..captured_len]);
    cs_test_queue(&replay, captured_len, "10.0.0.66");
    receive();
    try std.testing.expectEqual(@as(c_int, 0), cs_test_writes());
    try std.testing.expectEqualStrings("192.168.1.20", slice(&config.peers[0].ip));
    try std.testing.expect(!peer_compatible[0]);
}
test "outgoing counters are reserved on disk before use and never restart lower" {
    resetTest();
    defer history.deinit();
    const key: core.Key = @splat(9);
    _ = addPeer(@splat(2), key, @splat(0), "Windows");
    const saves = cs_test_saves();
    cs_test_copy("first");
    cs_poll_clipboard();
    try std.testing.expectEqual(saves + 1, cs_test_saves());
    try std.testing.expectEqual(@as(u64, 1 + counter_reservation), config.send_reserved);
    var packet: [256]u8 = undefined;
    var item = try core.decode(packet[0..cs_test_sent(&packet)], key);
    try std.testing.expectEqual(@as(u64, 1), item.counter);
    cs_test_copy("second");
    cs_poll_clipboard();
    try std.testing.expectEqual(saves + 1, cs_test_saves());
    item = try core.decode(packet[0..cs_test_sent(&packet)], key);
    try std.testing.expectEqual(@as(u64, 2), item.counter);
    // After a restart, sending resumes from the persisted reservation.
    send_next = @max(1, loadConfig(std.mem.asBytes(&config)).?.send_reserved);
    cs_test_copy("after restart");
    cs_poll_clipboard();
    item = try core.decode(packet[0..cs_test_sent(&packet)], key);
    try std.testing.expectEqual(@as(u64, 1 + counter_reservation), item.counter);
}
test "legacy device files migrate with keys intact and an empty replay window" {
    var legacy = std.mem.zeroes(LegacyConfig);
    legacy.magic = "CLIPCF01".*;
    legacy.id = @splat(1);
    legacy.count = 1;
    legacy.peers[0].id = @splat(2);
    legacy.peers[0].key = @splat(9);
    set(&legacy.peers[0].ip, "192.168.1.20");
    set(&legacy.peers[0].name, "Windows");
    const migrated = loadConfig(std.mem.asBytes(&legacy)).?;
    try std.testing.expectEqualSlices(u8, "CLIPCF02", &migrated.magic);
    try std.testing.expectEqual(@as(u32, 1), migrated.count);
    try std.testing.expectEqualSlices(u8, &legacy.peers[0].key, &migrated.peers[0].key);
    try std.testing.expectEqualStrings("Windows", slice(&migrated.peers[0].name));
    try std.testing.expectEqual(@as(u64, 0), migrated.peers[0].recv_counter);
    try std.testing.expect(loadConfig(std.mem.asBytes(&migrated)) != null);
    try std.testing.expect(loadConfig(std.mem.asBytes(&migrated)[0..100]) == null);
    legacy.count = 17;
    try std.testing.expect(loadConfig(std.mem.asBytes(&legacy)) == null);
}
test "unauthenticated version claims cannot disconnect a verified peer" {
    resetTest();
    defer history.deinit();
    const id: core.Id = @splat(2);
    var ip: [16]u8 = @splat(0);
    set(&ip, "192.168.1.20");
    _ = addPeer(id, @splat(9), ip, "Windows");
    try std.testing.expect(peer_compatible[0]);
    var announcement = discoveryPacket();
    announcement[8..24].* = id;
    announcement[88] = '9';
    updateNearby(&announcement, ip);
    @memcpy(announcement[0..8], "CLIPDS01");
    updateNearby(announcement[0..88], ip);
    var other = version.wire;
    other[0] = '9';
    const client = try pairing.State.init(.initiator, "123456".*, @splat(1));
    queuePairVersionTest(1, id, @splat(7), &pairHelloTest("Spoofed", client.public), other);
    receive();
    try std.testing.expect(peer_compatible[0]);
    try std.testing.expectEqual(@as(u32, 1), config.count);
}
test "a failed clipboard write is retried, then forwarded once" {
    resetTest();
    defer history.deinit();
    _ = addPeer(@splat(2), @splat(9), @splat(0), "Windows");
    _ = addPeer(@splat(3), @splat(8), @splat(0), "Linux");
    const item = core.Item{ .kind = 1, .name = "", .data = "clipboard was busy", .event = @splat(4) };
    cs_test_fail_writes(2);
    try queueTest(@splat(2), @splat(9), 1, item);
    receive();
    try std.testing.expectEqual(@as(c_int, 0), cs_test_writes());
    try std.testing.expectEqual(@as(c_int, 0), cs_test_sends());
    try std.testing.expect(history.entries[0] == null);
    cs_test_time(1250);
    cs_tick();
    try std.testing.expectEqual(@as(c_int, 0), cs_test_writes());
    cs_test_time(1500);
    cs_tick();
    try std.testing.expectEqual(@as(c_int, 1), cs_test_writes());
    try std.testing.expectEqual(@as(c_int, 1), cs_test_sends()); // Relayed to Linux only.
    try std.testing.expectEqualStrings(item.data, history.entries[0].?.data);
    try std.testing.expect(write_retry == null);
    try queueTest(@splat(3), @splat(8), 1, item);
    receive();
    try std.testing.expectEqual(@as(c_int, 1), cs_test_writes());
}
test "a relayed copy or newer local copy resolves a pending write retry" {
    resetTest();
    defer history.deinit();
    _ = addPeer(@splat(2), @splat(9), @splat(0), "Windows");
    _ = addPeer(@splat(3), @splat(8), @splat(0), "Linux");
    const item = core.Item{ .kind = 1, .name = "", .data = "via two routes", .event = @splat(4) };
    cs_test_fail_writes(1);
    try queueTest(@splat(2), @splat(9), 1, item);
    receive();
    // The event was not marked as seen, so the same update relayed by Linux still applies.
    try queueTest(@splat(3), @splat(8), 1, item);
    receive();
    try std.testing.expectEqual(@as(c_int, 1), cs_test_writes());
    try std.testing.expect(write_retry == null);
    cs_test_fail_writes(1);
    try queueTest(@splat(2), @splat(9), 2, .{ .kind = 1, .name = "", .data = "stale remote", .event = @splat(5) });
    receive();
    cs_test_copy("newer local copy");
    cs_poll_clipboard();
    cs_test_time(2000);
    cs_tick();
    try std.testing.expectEqual(@as(c_int, 1), cs_test_writes());
    try std.testing.expectEqualStrings("newer local copy", history.entries[0].?.data);
}
test "offline saved devices remain listed and can be forgotten" {
    resetTest();
    defer history.deinit();
    var ip: [16]u8 = @splat(0);
    set(&ip, "192.168.1.20");
    _ = addPeer(@splat(2), @splat(9), ip, "Lost laptop");
    peer_compatible[0] = false;
    refresh();
    try std.testing.expectEqualStrings("Lost laptop (192.168.1.20) · offline — Forget", std.mem.span(cs_peer_label(0)));
    cs_action(6, 0);
    try std.testing.expectEqual(@as(u32, 0), config.count);
    try std.testing.expectEqualStrings("", std.mem.span(cs_peer_label(0)));
}
test "files named like control messages sync as ordinary files" {
    resetTest();
    defer history.deinit();
    _ = addPeer(@splat(2), @splat(9), @splat(0), "Windows");
    try queueTest(@splat(2), @splat(9), 1, .{ .kind = 2, .name = "@probe", .data = "file bytes", .event = @splat(4) });
    receive();
    try std.testing.expectEqual(@as(c_int, 1), cs_test_writes());
    try std.testing.expectEqual(@as(c_int, 0), cs_test_sends()); // No @pair control reply.
    try std.testing.expectEqualStrings("@probe", history.entries[0].?.name);
    try history.push(.{ .kind = 2, .name = "@pair", .data = "other bytes" });
    cs_action(1, 0);
    const last = cs_test_log_count() - 1;
    try std.testing.expectEqualStrings("send_queued", std.mem.span(cs_test_log_stage(last)));
}
test "a replayed old-version frame cannot demote a peer that answers its probe" {
    resetTest();
    defer history.deinit();
    const id: core.Id = @splat(2);
    const key: core.Key = @splat(9);
    _ = addPeer(id, key, @splat(0), "Windows");
    try queueTest(id, key, 5, .{ .kind = 1, .name = "", .data = "current", .event = @splat(1) });
    receive();
    var older = version.wire;
    @memcpy(older[0..5], "0.2.6");
    // Recorded before both devices upgraded; the key is unchanged.
    const recorded = try core.encode(&send_buffer, id, @splat(1), key, .{ .kind = 1, .name = "", .data = "old", .app_version = older });
    cs_test_queue(recorded.ptr, recorded.len, "10.0.0.66");
    receive();
    try std.testing.expect(suspect_until[0] != 0);
    // A frame the window already accepted cannot clear the suspicion; a fresh reply does.
    try queueTest(id, key, 5, .{ .kind = 1, .name = "@pair", .data = "Windows" });
    receive();
    try std.testing.expect(suspect_until[0] != 0);
    try queueTest(id, key, 6, .{ .kind = 1, .name = "@pair", .data = "Windows" });
    receive();
    try std.testing.expect(suspect_until[0] == 0);
    cs_test_time(1000 + suspect_timeout + 1);
    cs_tick();
    try std.testing.expect(peer_compatible[0]);
    try std.testing.expectEqual(@as(u32, 1), config.count);
}

test "launch at login is an independent native setting and does not sync or save peer state" {
    resetTest();
    defer history.deinit();
    try std.testing.expectEqual(@as(c_int, 0), c.cs_startup_status());
    cs_action(8, 0);
    try std.testing.expectEqual(@as(c_int, 1), c.cs_startup_status());
    cs_action(8, 0);
    try std.testing.expectEqual(@as(c_int, 0), c.cs_startup_status());
    try std.testing.expectEqual(@as(c_int, 0), cs_test_sends());
    try std.testing.expectEqual(@as(c_int, 0), cs_test_saves());
    try std.testing.expect(!paused);
    try std.testing.expect(running);
}
