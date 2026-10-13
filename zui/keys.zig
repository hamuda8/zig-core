//! Secure keys: P-256 ECDH and ECDSA private keys and AES-256-GCM keys the app can use but never
//! read. Each key has a name the app chooses ("identity:<user>:enc"); requests go through
//! `fx.key(request, done)` and the result comes back as a message (the web's WebCrypto is
//! asynchronous, so every platform answers the same way).
//!
//! Where the keys live:
//!   web       WebCrypto CryptoKeys made with `extractable: false`, kept in IndexedDB
//!             ("zui-keys"): page scripts can use them, nobody can read them.
//!   Android   EC keys in the AndroidKeyStore (sign, and ECDH on Android 12+); AES keys, and EC
//!             keys where the Keystore cannot agree keys, in this file's engine, encrypted at rest
//!             with a Keystore AES key (zui.storage .secure).
//!   iOS       this file's engine, kept in the Keychain (zui.storage .secure).
//!   headless  this file's engine, in memory (tests).
//!
//! Formats are WebCrypto's: public keys the uncompressed SEC1 point (65 bytes, "raw"), private
//! keys imported as PKCS#8 (as `exportKey("pkcs8")` makes them), signatures r||s (64 bytes,
//! IEEE P1363), AES-GCM with a 16-byte tag after the ciphertext.

const std = @import("std");
const crypto = std.crypto;
const P256 = crypto.ecc.P256;
const Ecdsa = crypto.sign.ecdsa.EcdsaP256Sha256;
const Aes = crypto.aead.aes_gcm.Aes256Gcm;
const Hkdf = crypto.kdf.hkdf.HkdfSha256;

pub const Kind = enum(u8) {
    /// P-256 key agreement.
    ecdh = 1,
    /// P-256 signatures with SHA-256.
    ecdsa = 2,
    /// AES-256-GCM.
    aes = 3,
};

pub const Op = enum(u8) {
    /// A new key `name` of `kind`; the result is its public key (EC) or empty (AES).
    generate = 1,
    /// `data` becomes key `name`: PKCS#8 for EC keys, 32 raw bytes for AES. The app should
    /// forget its copy; the key can never be read again. The result is the public key.
    import = 2,
    /// The public key of `name`.
    public = 3,
    delete = 4,
    /// The signature of `data` (ECDSA P-256 SHA-256, r||s).
    sign = 5,
    /// ECDH of `name` with `peer` (a public key): the shared secret (the x coordinate, as
    /// WebCrypto's deriveBits 256). With `into`, the secret is never returned: HKDF-SHA256 of it
    /// with `salt` and `info` becomes the AES key `into`, and the result is empty.
    ecdh = 6,
    /// AES-GCM of `data` with `iv` and `aad`: the ciphertext and its tag.
    encrypt = 7,
    /// The plaintext, or a failure when the tag does not match.
    decrypt = 8,
};

pub const Request = struct {
    op: Op,
    name: []const u8,
    kind: Kind = .ecdh,
    data: []const u8 = "",
    peer: []const u8 = "",
    iv: []const u8 = "",
    aad: []const u8 = "",
    salt: []const u8 = "",
    info: []const u8 = "",
    into: []const u8 = "",
};

/// The answer to a request. `data` is only valid during `update`.
pub const Result = struct {
    /// The request, as `fx.key` returned it.
    id: u32,
    status: Status,
    data: []const u8 = "",

    pub fn ok(r: Result) bool {
        return r.status == .ok;
    }
};

/// `.missing`: no key of that name (or of another kind). `.failed`: bad input, or a
/// ciphertext that does not open.
pub const Status = enum(u8) { ok = 0, missing = 1, failed = 2, unsupported = 3 };

// ---- The software engine --------------------------------------------------------------------

/// A stored key: its kind, secret and (EC) public key. Kept base64 in secure storage.
pub const Stored = struct {
    kind: Kind,
    secret: [32]u8,
    public: [65]u8 = @splat(0),
    /// The secret lives in the platform's keystore (Android), not here: `secret` is unused.
    hardware: bool = false,

    pub fn encode(k: Stored, out: *[100]u8) []const u8 {
        out[0] = @intFromEnum(k.kind) | (if (k.hardware) @as(u8, 0x80) else 0);
        @memcpy(out[1..33], &k.secret);
        @memcpy(out[33..98], &k.public);
        return out[0..98];
    }

    pub fn decode(bytes: []const u8) ?Stored {
        if (bytes.len != 98) return null;
        const kind = std.enums.fromInt(Kind, bytes[0] & 0x7f) orelse return null;
        return .{ .kind = kind, .secret = bytes[1..33].*, .public = bytes[33..98].*, .hardware = bytes[0] & 0x80 != 0 };
    }
};

/// Where the engine keeps keys and gets randomness (the host), and what the platform's own
/// keystore can do (`Hw`: `generate`, `import`, `sign`, `ecdh`, `delete`, each optional).
pub fn Engine(comptime Store: type) type {
    return struct {
        const prefix = "zui.key.";

        fn load(a: std.mem.Allocator, name: []const u8) ?Stored {
            const key = std.mem.concat(a, u8, &.{ prefix, name }) catch return null;
            const text = Store.get(a, key) orelse return null;
            const n = std.base64.standard.Decoder.calcSizeForSlice(text) catch return null;
            const buf = a.alloc(u8, n) catch return null;
            std.base64.standard.Decoder.decode(buf, text) catch return null;
            return Stored.decode(buf);
        }

        fn save(a: std.mem.Allocator, name: []const u8, k: Stored) bool {
            var raw: [100]u8 = undefined;
            const bytes = k.encode(&raw);
            var b64: [136]u8 = undefined;
            const text = std.base64.standard.Encoder.encode(&b64, bytes);
            const key = std.mem.concat(a, u8, &.{ prefix, name }) catch return false;
            Store.set(key, text);
            std.crypto.secureZero(u8, &raw);
            return true;
        }

        fn remove(a: std.mem.Allocator, name: []const u8) void {
            const key = std.mem.concat(a, u8, &.{ prefix, name }) catch return;
            Store.remove(key);
        }

        const hw = if (@hasDecl(Store, "Hw")) Store.Hw else struct {};

        /// Runs a request; the result's data is in `a`.
        pub fn run(a: std.mem.Allocator, req: Request) struct { Status, []const u8 } {
            return runInner(a, req) catch .{ .failed, "" };
        }

        fn runInner(a: std.mem.Allocator, req: Request) !struct { Status, []const u8 } {
            switch (req.op) {
                .generate => {
                    if (req.kind != .aes and @hasDecl(hw, "generate")) {
                        if (hw.generate(a, req.name, req.kind)) |public| {
                            _ = save(a, req.name, .{ .kind = req.kind, .secret = @splat(0), .public = public, .hardware = true });
                            return .{ .ok, try a.dupe(u8, &public) };
                        }
                    }
                    var secret: [32]u8 = undefined;
                    if (req.kind == .aes) Store.random(&secret) else secret = randomScalar();
                    defer std.crypto.secureZero(u8, &secret);
                    return store(a, req.name, req.kind, secret);
                },
                .import => {
                    if (req.kind == .aes) {
                        if (req.data.len != 32) return .{ .failed, "" };
                        return store(a, req.name, .aes, req.data[0..32].*);
                    }
                    var secret = pkcs8Secret(req.data) orelse return .{ .failed, "" };
                    defer std.crypto.secureZero(u8, &secret);
                    return store(a, req.name, req.kind, secret);
                },
                .public => {
                    const k = load(a, req.name) orelse return .{ .missing, "" };
                    if (k.kind == .aes) return .{ .failed, "" };
                    return .{ .ok, try a.dupe(u8, &k.public) };
                },
                .delete => {
                    if (load(a, req.name)) |k| if (k.hardware and @hasDecl(hw, "delete")) hw.delete(req.name);
                    remove(a, req.name);
                    return .{ .ok, "" };
                },
                .sign => {
                    const k = load(a, req.name) orelse return .{ .missing, "" };
                    if (k.kind != .ecdsa) return .{ .missing, "" };
                    if (k.hardware) {
                        if (@hasDecl(hw, "sign")) if (hw.sign(a, req.name, req.data)) |sig| return .{ .ok, try a.dupe(u8, &sig) };
                        return .{ .failed, "" };
                    }
                    const kp = try Ecdsa.KeyPair.fromSecretKey(try Ecdsa.SecretKey.fromBytes(k.secret));
                    var noise: [32]u8 = undefined;
                    Store.random(&noise);
                    const sig = try kp.sign(req.data, noise);
                    return .{ .ok, try a.dupe(u8, &sig.toBytes()) };
                },
                .ecdh => {
                    const k = load(a, req.name) orelse return .{ .missing, "" };
                    if (k.kind != .ecdh) return .{ .missing, "" };
                    var shared: [32]u8 = undefined;
                    defer std.crypto.secureZero(u8, &shared);
                    if (k.hardware) {
                        if (!@hasDecl(hw, "ecdh")) return .{ .failed, "" };
                        shared = hw.ecdh(a, req.name, req.peer) orelse return .{ .failed, "" };
                    } else {
                        const p = P256.fromSec1(req.peer) catch return .{ .failed, "" };
                        const q = p.mul(k.secret, .big) catch return .{ .failed, "" };
                        shared = q.affineCoordinates().x.toBytes(.big);
                    }
                    if (req.into.len == 0) return .{ .ok, try a.dupe(u8, &shared) };
                    var derived: [32]u8 = undefined;
                    defer std.crypto.secureZero(u8, &derived);
                    const prk = Hkdf.extract(req.salt, &shared);
                    Hkdf.expand(&derived, req.info, prk);
                    const r = try store(a, req.into, .aes, derived);
                    return .{ r[0], "" };
                },
                .encrypt, .decrypt => {
                    const k = load(a, req.name) orelse return .{ .missing, "" };
                    if (k.kind != .aes or req.iv.len != 12) return .{ .missing, "" };
                    const iv = req.iv[0..12].*;
                    if (req.op == .encrypt) {
                        const out = try a.alloc(u8, req.data.len + 16);
                        var tag: [16]u8 = undefined;
                        Aes.encrypt(out[0..req.data.len], &tag, req.data, req.aad, iv, k.secret);
                        @memcpy(out[req.data.len..], &tag);
                        return .{ .ok, out };
                    }
                    if (req.data.len < 16) return .{ .failed, "" };
                    const n = req.data.len - 16;
                    const out = try a.alloc(u8, n);
                    Aes.decrypt(out, req.data[0..n], req.data[n..][0..16].*, req.aad, iv, k.secret) catch return .{ .failed, "" };
                    return .{ .ok, out };
                },
            }
        }

        fn store(a: std.mem.Allocator, name: []const u8, kind: Kind, secret: [32]u8) !struct { Status, []const u8 } {
            if (kind == .aes) {
                if (!save(a, name, .{ .kind = .aes, .secret = secret })) return .{ .failed, "" };
                return .{ .ok, "" };
            }
            const public = (P256.basePoint.mul(secret, .big) catch return .{ .failed, "" }).toUncompressedSec1();
            if (@hasDecl(hw, "import")) {
                if (hw.import(a, name, kind, secret, public)) {
                    if (!save(a, name, .{ .kind = kind, .secret = @splat(0), .public = public, .hardware = true })) return .{ .failed, "" };
                    return .{ .ok, try a.dupe(u8, &public) };
                }
            }
            if (!save(a, name, .{ .kind = kind, .secret = secret, .public = public })) return .{ .failed, "" };
            return .{ .ok, try a.dupe(u8, &public) };
        }

        fn randomScalar() [32]u8 {
            while (true) {
                var s: [32]u8 = undefined;
                Store.random(&s);
                P256.scalar.rejectNonCanonical(s, .big) catch continue;
                if (std.mem.allEqual(u8, &s, 0)) continue;
                return s;
            }
        }
    };
}

/// The private scalar of a P-256 PKCS#8 key (WebCrypto's export, with or without the public key).
pub fn pkcs8Secret(der: []const u8) ?[32]u8 {
    // The ECPrivateKey's "INTEGER 1, OCTET STRING (32)" inside the PKCS#8 wrapper.
    const marker = [_]u8{ 0x02, 0x01, 0x01, 0x04, 0x20 };
    const at = std.mem.indexOf(u8, der, &marker) orelse return null;
    if (at + marker.len + 32 > der.len) return null;
    // The algorithm must be EC on prime256v1.
    const curve = [_]u8{ 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07 };
    if (std.mem.indexOf(u8, der[0..at], &curve) == null) return null;
    return der[at + marker.len ..][0..32].*;
}

// ---- Tests ------------------------------------------------------------------------------------

const testing = std.testing;

const MemStore = struct {
    var map: std.StringHashMapUnmanaged([]u8) = .empty;
    var prng = std.Random.DefaultPrng.init(42);
    const gpa = testing.allocator;

    pub fn get(a: std.mem.Allocator, key: []const u8) ?[]u8 {
        const v = map.get(key) orelse return null;
        return a.dupe(u8, v) catch null;
    }
    pub fn set(key: []const u8, value: []const u8) void {
        const gop = map.getOrPut(gpa, key) catch return;
        if (gop.found_existing) gpa.free(gop.value_ptr.*) else gop.key_ptr.* = gpa.dupe(u8, key) catch return;
        gop.value_ptr.* = gpa.dupe(u8, value) catch return;
    }
    pub fn remove(key: []const u8) void {
        if (map.fetchRemove(key)) |kv| {
            gpa.free(kv.key);
            gpa.free(kv.value);
        }
    }
    pub fn random(buf: []u8) void {
        prng.random().bytes(buf);
    }
    fn deinit() void {
        var it = map.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        map.deinit(gpa);
        map = .empty;
    }
};

test "keys: generate, sign and verify, ECDH both ways into AES keys, encrypt and decrypt" {
    defer MemStore.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const E = Engine(MemStore);

    const sig = E.run(a, .{ .op = .generate, .name = "sig", .kind = .ecdsa });
    try testing.expectEqual(Status.ok, sig[0]);
    const signed = E.run(a, .{ .op = .sign, .name = "sig", .data = "hello" });
    try testing.expectEqual(@as(usize, 64), signed[1].len);
    const pk = try Ecdsa.PublicKey.fromSec1(sig[1]);
    try Ecdsa.Signature.fromBytes(signed[1][0..64].*).verify("hello", pk);

    const alice = E.run(a, .{ .op = .generate, .name = "alice", .kind = .ecdh });
    const bob = E.run(a, .{ .op = .generate, .name = "bob", .kind = .ecdh });
    const s1 = E.run(a, .{ .op = .ecdh, .name = "alice", .peer = bob[1] });
    const s2 = E.run(a, .{ .op = .ecdh, .name = "bob", .peer = alice[1] });
    try testing.expectEqualSlices(u8, s1[1], s2[1]);

    try testing.expectEqual(Status.ok, E.run(a, .{ .op = .ecdh, .name = "alice", .peer = bob[1], .salt = "s", .info = "i", .into = "k1" })[0]);
    try testing.expectEqual(Status.ok, E.run(a, .{ .op = .ecdh, .name = "bob", .peer = alice[1], .salt = "s", .info = "i", .into = "k2" })[0]);
    const iv = "123456789012";
    const ct = E.run(a, .{ .op = .encrypt, .name = "k1", .iv = iv, .aad = "ad", .data = "secret" });
    try testing.expectEqual(@as(usize, 6 + 16), ct[1].len);
    const pt = E.run(a, .{ .op = .decrypt, .name = "k2", .iv = iv, .aad = "ad", .data = ct[1] });
    try testing.expectEqualStrings("secret", pt[1]);
    try testing.expectEqual(Status.failed, E.run(a, .{ .op = .decrypt, .name = "k2", .iv = iv, .aad = "other", .data = ct[1] })[0]);

    try testing.expectEqual(Status.missing, E.run(a, .{ .op = .sign, .name = "alice", .data = "x" })[0]);
    _ = E.run(a, .{ .op = .delete, .name = "sig" });
    try testing.expectEqual(Status.missing, E.run(a, .{ .op = .sign, .name = "sig", .data = "x" })[0]);
}

test "keys: a WebCrypto PKCS#8 key imports to the same public key" {
    defer MemStore.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const E = Engine(MemStore);
    // A key made by WebCrypto (exportKey("pkcs8")) and its public key (exportKey("raw")).
    const der_b64 = "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQghv837Kyo86YPsVsOAhMFaP0SnKxA8P5IQmWYq48nWb+hRANCAASx1PfjXJHZ58lRkFdX9+BDc0mujrhm5TM/d2+nFm+CX1nOkpQlokgjYxYORGSPePIXgDwpJR26hkjzY80B3vj6";
    const pub_b64 = "BLHU9+NckdnnyVGQV1f34ENzSa6OuGblMz93b6cWb4JfWc6SlCWiSCNjFg5EZI948heAPCklHbqGSPNjzQHe+Po=";
    var der: [138]u8 = undefined;
    try std.base64.standard.Decoder.decode(&der, der_b64);
    var public: [65]u8 = undefined;
    try std.base64.standard.Decoder.decode(&public, pub_b64);
    const r = E.run(a, .{ .op = .import, .name = "k", .kind = .ecdsa, .data = &der });
    try testing.expectEqual(Status.ok, r[0]);
    try testing.expectEqualSlices(u8, &public, r[1]);
}
