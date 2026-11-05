//! C ABI declarations for native/bridge.h. Keep signatures and cs_clip layout in sync.
//! Zig 0.17 removed @cImport; the native adapters still compile as C/Objective-C.
pub const cs_clip = extern struct {
    kind: c_int,
    len: usize,
    data: [*c]u8,
    name: [256]u8,
};

pub extern fn cs_init() c_int;
pub extern fn cs_pump() void;
pub extern fn cs_shutdown() void;
pub extern fn cs_refresh() void;
pub extern fn cs_startup_status() c_int;
pub extern fn cs_startup_toggle() void;
pub extern fn cs_notice(title: [*:0]const u8, text: [*:0]const u8) void;
pub extern fn cs_prompt(title: [*:0]const u8, text: [*:0]const u8, out: [*c]u8, cap: usize) c_int;
pub extern fn cs_clip_read(out: *cs_clip) c_int;
pub extern fn cs_clip_write(kind: c_int, data: [*]const u8, len: usize, name: [*:0]const u8) c_int;
pub extern fn cs_clip_free(clip: *cs_clip) void;
pub extern fn cs_read_file(path: [*:0]const u8, out: *cs_clip) c_int;
pub extern fn cs_save_file(data: [*]const u8, len: usize, name: [*:0]const u8) ?[*:0]const u8;
pub extern fn cs_storage_init() c_int;
pub extern fn cs_load(data: *anyopaque, cap: usize) c_int;
pub extern fn cs_save(data: *const anyopaque, len: usize) c_int;
pub extern fn cs_random(data: [*]u8, len: usize) c_int;
pub extern fn cs_millis() u64;
pub extern fn cs_log_init(version: [*:0]const u8) void;
pub extern fn cs_log_event(stage: [*:0]const u8, event: ?[*]const u8, wire: ?[*]const u8, peer: [*:0]const u8, kind: c_int, bytes: usize, elapsed_ms: u64) void;
pub extern fn cs_hostname(out: [*c]u8, cap: usize) void;
pub extern fn cs_net_init() c_int;
pub extern fn cs_announce(data: *const anyopaque, len: usize) void;
pub extern fn cs_discover(out: *anyopaque, cap: usize, ip: [*c]u8) c_int;
pub extern fn cs_receive(out: *anyopaque, cap: usize, ip: [*c]u8) c_int;
pub extern fn cs_send(ip: [*:0]const u8, data: [*]const u8, len: usize) c_int;
pub extern fn cs_send_control(ip: [*:0]const u8, data: [*]const u8, len: usize) c_int;
pub extern fn cs_pair_send(ip: [*:0]const u8, data: [*]const u8, len: usize) c_int;
pub extern fn cs_pair_close() void;
pub extern fn cs_pair_status() c_int;
pub extern fn cs_peer_authorized(ip: [*:0]const u8) void;
pub extern fn cs_peer_connected(ip: [*:0]const u8) c_int;
pub extern fn cs_peer_forget(ip: [*:0]const u8) void;
pub extern fn cs_net_error() [*:0]const u8;
pub extern fn cs_pairing_show(code: [*:0]const u8) void;
pub extern fn cs_pairing_hide() void;
pub extern fn cs_net_close() void;

extern fn cs_test_clip_size() usize;
extern fn cs_test_clip_alignment() usize;
extern fn cs_test_clip_offset(field: c_int) usize;

test "clipboard ABI matches the native C structure" {
    const testing = @import("std").testing;
    try testing.expectEqual(cs_test_clip_size(), @sizeOf(cs_clip));
    try testing.expectEqual(cs_test_clip_alignment(), @alignOf(cs_clip));
    inline for (.{ "kind", "len", "data", "name" }, 0..) |field, index| {
        try testing.expectEqual(cs_test_clip_offset(index), @offsetOf(cs_clip, field));
    }
}
