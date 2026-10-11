//! The TLS 1.3 key schedule (RFC 8446 section 7.1), generic over the cipher suite's hash.

const std = @import("std");
const tls = std.crypto.tls;

pub fn Schedule(comptime Hash: type) type {
    return struct {
        pub const Hmac = std.crypto.auth.hmac.Hmac(Hash);
        pub const Hkdf = std.crypto.kdf.hkdf.Hkdf(Hmac);
        pub const len = Hash.digest_length;
        pub const Secret = [len]u8;

        const zeros: Secret = @splat(0);

        /// Handshake Secret from the (EC)DHE shared secret, with no pre-shared key.
        pub fn handshakeSecret(shared: []const u8) Secret {
            const early = Hkdf.extract(&zeros, &zeros);
            const derived = tls.hkdfExpandLabel(Hkdf, early, "derived", &tls.emptyHash(Hash), len);
            return Hkdf.extract(&derived, shared);
        }

        pub fn masterSecret(handshake_secret: Secret) Secret {
            const derived = tls.hkdfExpandLabel(Hkdf, handshake_secret, "derived", &tls.emptyHash(Hash), len);
            return Hkdf.extract(&derived, &zeros);
        }

        /// Derive-Secret(secret, label, transcript): "c hs traffic", "s ap traffic", ...
        pub fn derive(secret: Secret, label: []const u8, transcript: Secret) Secret {
            return tls.hkdfExpandLabel(Hkdf, secret, label, &transcript, len);
        }

        pub fn Keys(comptime Aead: type) type {
            return struct { key: [Aead.key_length]u8, iv: [Aead.nonce_length]u8 };
        }

        pub fn trafficKeys(comptime Aead: type, secret: Secret) Keys(Aead) {
            return .{
                .key = tls.hkdfExpandLabel(Hkdf, secret, "key", "", Aead.key_length),
                .iv = tls.hkdfExpandLabel(Hkdf, secret, "iv", "", Aead.nonce_length),
            };
        }

        /// The next generation of a traffic secret (KeyUpdate).
        pub fn nextSecret(secret: Secret) Secret {
            return tls.hkdfExpandLabel(Hkdf, secret, "traffic upd", "", len);
        }

        /// The contents of a Finished message for `transcript`.
        pub fn verifyData(traffic_secret: Secret, transcript: Secret) [Hmac.mac_length]u8 {
            const key = tls.hkdfExpandLabel(Hkdf, traffic_secret, "finished", "", Hmac.key_length);
            return tls.hmac(Hmac, &transcript, key);
        }
    };
}

/// Nonce for record number `seq`: the IV with the big-endian sequence number XORed into its end.
pub fn nonce(comptime n: usize, iv: [n]u8, seq: u64) [n]u8 {
    var out = iv;
    var s: [8]u8 = undefined;
    std.mem.writeInt(u64, &s, seq, .big);
    for (out[n - 8 ..], s) |*o, b| o.* ^= b;
    return out;
}

test "key schedule matches RFC 8448 (Simple 1-RTT Handshake)" {
    const v = @import("rfc8448.zig");
    const S = Schedule(std.crypto.hash.sha2.Sha256);
    const Aes = std.crypto.aead.aes_gcm.Aes128Gcm;
    const hex = struct {
        fn b(comptime s: []const u8) [s.len / 2]u8 {
            var out: [s.len / 2]u8 = undefined;
            _ = std.fmt.hexToBytes(&out, s) catch unreachable;
            return out;
        }
    }.b;

    const shared = try std.crypto.dh.X25519.scalarmult(hex(v.server_private), hex(v.client_public));
    const hs = S.handshakeSecret(&shared);
    try std.testing.expectEqual(hex(v.handshake_secret), hs);

    var t = std.crypto.hash.sha2.Sha256.init(.{});
    t.update(&hex(v.client_hello));
    t.update(&hex(v.server_hello));
    const th = t.peek();
    try std.testing.expectEqual(hex(v.client_hs_traffic), S.derive(hs, "c hs traffic", th));
    const s_hs = S.derive(hs, "s hs traffic", th);
    try std.testing.expectEqual(hex(v.server_hs_traffic), s_hs);

    const keys = S.trafficKeys(Aes, s_hs);
    try std.testing.expectEqual(hex(v.server_hs_key), keys.key);
    try std.testing.expectEqual(hex(v.server_hs_iv), keys.iv);

    // Finished covers everything up to CertificateVerify: the flight minus its last 36 bytes.
    const flight = hex(v.server_flight);
    var t2 = t;
    t2.update(flight[0 .. flight.len - 36]);
    try std.testing.expectEqual(hex(v.server_finished), S.verifyData(s_hs, t2.peek()));

    const master = S.masterSecret(hs);
    try std.testing.expectEqual(hex(v.master_secret), master);
    t.update(&flight);
    try std.testing.expectEqual(hex(v.client_ap_traffic), S.derive(master, "c ap traffic", t.peek()));
    try std.testing.expectEqual(hex(v.server_ap_traffic), S.derive(master, "s ap traffic", t.peek()));
}

test nonce {
    const iv: [12]u8 = .{ 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    try std.testing.expectEqual([12]u8{ 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe }, nonce(12, iv, 1));
}
