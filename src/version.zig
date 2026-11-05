const std = @import("std");
// Bump for every app release; all devices must run this exact version.
pub const text = "0.2.9";
pub const build_number = "11";
pub const Wire = [16]u8;
pub const wire: Wire = value: {
    if (text.len >= 16) @compileError("App version must fit in 15 bytes plus a terminator");
    var bytes: Wire = @splat(0);
    @memcpy(bytes[0..text.len], text);
    break :value bytes;
};
pub fn matches(other: Wire) bool {
    return std.mem.eql(u8, &wire, &other);
}
