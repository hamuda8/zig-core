//! P-256 key pairs as Node's crypto exports them: the public key as an uncompressed point, the
//! private key as PKCS#8 DER (what the browser's Web Crypto imports when it restores keys a server
//! provisioned).

const std = @import("std");
const P256 = std.crypto.ecc.P256;

pub const KeyPair = struct { secret: [32]u8, public: [65]u8 };

pub fn generate(io: std.Io) KeyPair {
    while (true) {
        var d: [32]u8 = undefined;
        io.random(&d);
        const scalar = P256.scalar.Scalar.fromBytes(d, .big) catch continue;
        if (scalar.isZero()) continue;
        const point = P256.basePoint.mul(scalar.toBytes(.big), .big) catch continue;
        return .{ .secret = scalar.toBytes(.big), .public = point.toUncompressedSec1() };
    }
}

/// PKCS#8 PrivateKeyInfo with an ECPrivateKey that includes the public key (Node's layout).
pub fn pkcs8(a: std.mem.Allocator, kp: KeyPair) ![]u8 {
    const head = [_]u8{
        0x30, 0x81, 0x87, 0x02, 0x01, 0x00, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
        0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x04, 0x6d, 0x30, 0x6b, 0x02, 0x01, 0x01, 0x04, 0x20,
    };
    const mid = [_]u8{ 0xa1, 0x44, 0x03, 0x42, 0x00 };
    const out = try a.alloc(u8, head.len + 32 + mid.len + 65);
    @memcpy(out[0..head.len], &head);
    @memcpy(out[head.len..][0..32], &kp.secret);
    @memcpy(out[head.len + 32 ..][0..mid.len], &mid);
    @memcpy(out[head.len + 32 + mid.len ..], &kp.public);
    return out;
}

test "pkcs8 layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const kp = generate(std.testing.io);
    const der = try pkcs8(arena.allocator(), kp);
    try std.testing.expectEqual(@as(usize, 138), der.len);
    try std.testing.expectEqual(@as(u8, 0x04), kp.public[0]);
}
