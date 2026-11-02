//! SPAKE2-P256-SHA256-HKDF-HMAC (RFC 9382), with application-specific PIN mapping.
//! PINs authorize a fresh key exchange; they are never used directly as encryption keys.
const std = @import("std");
const Curve = std.crypto.ecc.P256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha512 = std.crypto.hash.sha2.Sha512;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
pub const Code = [6]u8;
pub const Role = enum { initiator, responder };
const m_hex = "02886e2f97ace46e55ba9dd7242579f2993b64e16ef3dcab95afd497333d8fa12f";
const n_hex = "03d8bbd6c639c62937b04d997f38c3770719c629d7014d49a24b4f98baa1292b49";
fn hex(comptime value: []const u8) [value.len / 2]u8 {
    var out: [value.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, value) catch unreachable;
    return out;
}
fn mask(role: Role) Curve {
    return Curve.fromSec1(if (role == .initiator) &hex(m_hex) else &hex(n_hex)) catch unreachable;
}
pub fn parseCode(text: []const u8) !Code {
    if (text.len != 6) return error.InvalidCode;
    for (text) |ch| if (ch < '0' or ch > '9') return error.InvalidCode;
    return text[0..6].*;
}
/// Reject the biased tail of a uniform u32, preserving all 1,000,000 possible PINs.
pub fn codeFromRandom(value: u32) ?Code {
    if (value >= 4_294_000_000) return null;
    var number = value % 1_000_000;
    var code: Code = undefined;
    var i: usize = code.len;
    while (i > 0) {
        i -= 1;
        code[i] = @intCast('0' + number % 10);
        number /= 10;
    }
    return code;
}
pub fn validSecret(secret: [32]u8) bool {
    Curve.scalar.rejectNonCanonical(secret, .big) catch return false;
    return !std.mem.eql(u8, &secret, &@as([32]u8, @splat(0)));
}
pub const State = struct {
    role: Role,
    secret: [32]u8,
    w: [32]u8,
    public: [65]u8,
    pub fn init(role: Role, code: Code, secret: [32]u8) !State {
        _ = try parseCode(&code);
        var hash = Sha512.init(.{});
        hash.update("ClipboardSync PIN v2\x00");
        hash.update(&code);
        const w = Curve.scalar.reduce64(hash.finalResult(), .big);
        return initScalar(role, w, secret);
    }
    fn initScalar(role: Role, w: [32]u8, secret: [32]u8) !State {
        if (!validSecret(secret)) return error.InvalidSecret;
        const public = (try Curve.basePoint.mul(secret, .big)).add(try mask(role).mul(w, .big));
        try public.rejectIdentity();
        return .{ .role = role, .secret = secret, .w = w, .public = public.toUncompressedSec1() };
    }
    pub fn finish(self: State, other: [65]u8, a: []const u8, b: []const u8) !Keys {
        const received = try Curve.fromSec1(&other);
        try received.rejectIdentity();
        const other_role: Role = if (self.role == .initiator) .responder else .initiator;
        const shared = try received.sub(try mask(other_role).mul(self.w, .big)).mul(self.secret, .big);
        const p_a = if (self.role == .initiator) self.public else other;
        const p_b = if (self.role == .responder) self.public else other;
        return derive(a, b, p_a, p_b, shared.toUncompressedSec1(), self.w);
    }
};
pub const Keys = struct {
    encryption: [32]u8,
    confirm_a: [32]u8,
    confirm_b: [32]u8,
    pub fn verify(self: Keys, role: Role, proof: [32]u8) bool {
        const expected = if (role == .initiator) self.confirm_a else self.confirm_b;
        return std.crypto.timing_safe.eql([32]u8, expected, proof);
    }
};
fn derive(a: []const u8, b: []const u8, p_a: [65]u8, p_b: [65]u8, shared: [65]u8, w: [32]u8) Keys {
    // Both identities are bounded by the application (IDs, names, and session nonce).
    var transcript: [512]u8 = undefined;
    var used: usize = 0;
    for ([_][]const u8{ a, b, &p_a, &p_b, &shared, &w }) |part| {
        std.mem.writeInt(u64, transcript[used..][0..8], part.len, .little);
        used += 8;
        @memcpy(transcript[used..][0..part.len], part);
        used += part.len;
    }
    var digest: [32]u8 = undefined;
    Sha256.hash(transcript[0..used], &digest, .{});
    var confirmations: [32]u8 = undefined;
    Hkdf.expand(&confirmations, "ConfirmationKeys", Hkdf.extract("", digest[16..]));
    var keys: Keys = undefined;
    Hmac.create(&keys.confirm_a, transcript[0..used], confirmations[0..16]);
    Hmac.create(&keys.confirm_b, transcript[0..used], confirmations[16..]);
    Hkdf.expand(&keys.encryption, "ClipboardSync encryption v2", Hkdf.extract("", digest[0..16]));
    return keys;
}
test "RFC 9382 Appendix B first P256 vector and key confirmations" {
    const w = hex("2ee57912099d31560b3a44b1184b9b4866e904c49d12ac5042c97dca461b1a5f");
    const a = try State.initScalar(.initiator, w, hex("43dd0fd7215bdcb482879fca3220c6a968e66d70b1356cac18bb26c84a78d729"));
    const b = try State.initScalar(.responder, w, hex("dcb60106f276b02606d8ef0a328c02e4b629f84f89786af5befb0bc75b6e66be"));
    try std.testing.expectEqualSlices(u8, &hex("04a56fa807caaa53a4d28dbb9853b9815c61a411118a6fe516a8798434751470f9010153ac33d0d5f2047ffdb1a3e42c9b4e6be662766e1eeb4116988ede5f912c"), &a.public);
    const ka = try a.finish(b.public, "server", "client");
    const kb = try b.finish(a.public, "server", "client");
    try std.testing.expectEqualSlices(u8, &ka.encryption, &kb.encryption);
    try std.testing.expectEqualSlices(u8, &hex("58ad4aa88e0b60d5061eb6b5dd93e80d9c4f00d127c65b3b35b1b5281fee38f0"), &ka.confirm_a);
    try std.testing.expectEqualSlices(u8, &hex("d3e2e547f1ae04f2dbdbf0fc4b79f8ecff2dff314b5d32fe9fcef2fb26dc459b"), &ka.confirm_b);
}
test "six digits, leading zeros, wrong PIN, altered identity, and malformed point" {
    try std.testing.expectEqualStrings("000042", &(codeFromRandom(42).?));
    try std.testing.expect(codeFromRandom(4_294_000_000) == null);
    try std.testing.expectError(error.InvalidCode, parseCode("12345"));
    try std.testing.expectError(error.InvalidCode, parseCode("12345a"));
    const a = try State.init(.initiator, "000042".*, @splat(1));
    const b = try State.init(.responder, "000043".*, @splat(2));
    const ka = try a.finish(b.public, "a", "b");
    const kb = try b.finish(a.public, "a", "b");
    try std.testing.expect(!kb.verify(.initiator, ka.confirm_a));
    const correct = try State.init(.responder, "000042".*, @splat(2));
    const correct_keys = try a.finish(correct.public, "a", "b");
    const altered = try correct.finish(a.public, "attacker", "b");
    try std.testing.expect(!altered.verify(.initiator, correct_keys.confirm_a));
    _ = a.finish(@splat(0), "a", "b") catch return;
    return error.ExpectedInvalidPoint;
}
