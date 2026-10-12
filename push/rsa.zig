//! RSA signatures (PKCS#1 v1.5 with SHA-256, "RS256"): what Google service accounts sign their
//! token requests with. std.crypto verifies RSA but does not sign; the private-key operation
//! here uses std.crypto.ff's constant-time modular exponentiation.

const std = @import("std");

const Modulus = std.crypto.ff.Modulus(4096);

pub const PrivateKey = struct {
    /// Big-endian, without leading zeros.
    n: []u8,
    d: []u8,

    pub fn deinit(k: PrivateKey, gpa: std.mem.Allocator) void {
        std.crypto.secureZero(u8, k.d);
        gpa.free(k.n);
        gpa.free(k.d);
    }

    /// "-----BEGIN PRIVATE KEY-----" (PKCS#8) or "-----BEGIN RSA PRIVATE KEY-----" (PKCS#1).
    pub fn fromPem(gpa: std.mem.Allocator, pem: []const u8) !PrivateKey {
        const der = try pemBody(gpa, pem);
        defer {
            std.crypto.secureZero(u8, der);
            gpa.free(der);
        }
        var r: Der = .{ .data = der };
        var top = try r.enter(0x30);
        // PKCS#8 starts INTEGER 0, then the algorithm SEQUENCE, then the key in an OCTET STRING.
        _ = try top.read(0x02);
        var rsa_key: Der = undefined;
        if (top.peek() == 0x30) {
            _ = try top.read(0x30); // AlgorithmIdentifier (rsaEncryption)
            var octets: Der = .{ .data = try top.read(0x04) };
            rsa_key = try octets.enter(0x30);
            _ = try rsa_key.read(0x02); // version
        } else rsa_key = top; // PKCS#1: version was the INTEGER just read
        const n = try rsa_key.read(0x02);
        _ = try rsa_key.read(0x02); // e
        const d = try rsa_key.read(0x02);
        return .{ .n = try gpa.dupe(u8, trimZeros(n)), .d = try gpa.dupe(u8, trimZeros(d)) };
    }

    /// The signature of `message`: as many bytes as the modulus.
    pub fn signSha256(k: PrivateKey, gpa: std.mem.Allocator, message: []const u8) ![]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(message, &digest, .{});
        // EM = 00 01 FF..FF 00 || DigestInfo(SHA-256) || digest (RFC 8017, 9.2)
        const prefix = [_]u8{ 0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20 };
        const len = k.n.len;
        if (len < prefix.len + digest.len + 11) return error.KeyTooSmall;
        const em = try gpa.alloc(u8, len);
        defer gpa.free(em);
        @memset(em, 0xff);
        em[0] = 0x00;
        em[1] = 0x01;
        em[len - digest.len - prefix.len - 1] = 0x00;
        @memcpy(em[len - digest.len - prefix.len ..][0..prefix.len], &prefix);
        @memcpy(em[len - digest.len ..], &digest);

        const m = try Modulus.fromBytes(k.n, .big);
        const x = try Modulus.Fe.fromBytes(m, em, .big);
        const s = try m.powWithEncodedExponent(x, k.d, .big);
        const out = try gpa.alloc(u8, len);
        try s.toBytes(out, .big);
        return out;
    }
};

fn trimZeros(b: []const u8) []const u8 {
    var i: usize = 0;
    while (i + 1 < b.len and b[i] == 0) i += 1;
    return b[i..];
}

/// The DER inside a PEM block. Caller frees.
pub fn pemBody(gpa: std.mem.Allocator, pem: []const u8) ![]u8 {
    const begin = std.mem.indexOf(u8, pem, "-----BEGIN") orelse return error.BadPem;
    const body_start = (std.mem.indexOfPos(u8, pem, begin + 10, "-----") orelse return error.BadPem) + 5;
    const end = std.mem.indexOfPos(u8, pem, body_start, "-----END") orelse return error.BadPem;
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(gpa);
    // JSON files carry the PEM with literal "\n" sequences; both are skipped.
    var i: usize = body_start;
    while (i < end) : (i += 1) {
        const c = pem[i];
        if (c == '\\' and i + 1 < end and pem[i + 1] == 'n') {
            i += 1;
            continue;
        }
        if (std.ascii.isWhitespace(c)) continue;
        try clean.append(gpa, c);
    }
    const out = try gpa.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(clean.items));
    try std.base64.standard.Decoder.decode(out, clean.items);
    return out;
}

/// Just enough DER to walk an RSA private key.
const Der = struct {
    data: []const u8,
    pos: usize = 0,

    fn peek(r: *const Der) u8 {
        return if (r.pos < r.data.len) r.data[r.pos] else 0;
    }

    fn read(r: *Der, tag: u8) ![]const u8 {
        if (r.pos + 2 > r.data.len or r.data[r.pos] != tag) return error.BadDer;
        r.pos += 1;
        var len: usize = r.data[r.pos];
        r.pos += 1;
        if (len & 0x80 != 0) {
            const n = len & 0x7f;
            if (n == 0 or n > 4 or r.pos + n > r.data.len) return error.BadDer;
            len = 0;
            for (r.data[r.pos..][0..n]) |b| len = (len << 8) | b;
            r.pos += n;
        }
        if (len > r.data.len - r.pos) return error.BadDer;
        const v = r.data[r.pos..][0..len];
        r.pos += len;
        return v;
    }

    fn enter(r: *Der, tag: u8) !Der {
        return .{ .data = try r.read(tag) };
    }
};

// A throwaway 2048-bit key and the signature Node (OpenSSL) made with it.
const test_key_pem =
    \\-----BEGIN PRIVATE KEY-----
    \\MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQCnXooSX1pXN828
    \\tQixZEDCx6zh4ym8WzMQPgddNf4rzIJTRgC5WRDZbmM2Xbpvx+oeHljaRRt71Fev
    \\GMPYo/kh6O/Nzos+oyu14pZRTVmr5dJdjDcPJhXlVyLgq99EMS2vcv/C2ImvFiWE
    \\USPdVV8v2kIX7Vbw5TzX2tskulvP720R7FUjsIRlSh3Q9UohevCusUlinE+rKwND
    \\ETa1D36Do/HuNjiXS/mYTWmtpt9oTqmBO3Gmhv84k4p1phEwfau7RcBbVkp4TMkN
    \\FtJMuLs4/5Mb6h44Mdpo7G1U24BIjJMYbLgRMEnybMckLbVxae+o3mCVfCpL0TgT
    \\foB7kcxpAgMBAAECggEAUaSTU60B46PMD2575BSUZq+CjNoEBOaz/QtVCkoJR5JG
    \\TJrMRZ3F01q+uMl15YsukCybiTXG11vYvgglmOs73yfCurEzSYXND7eNPfGueWTt
    \\fkakoRYh/jLIR7JvgdM/huNhEcoRN8Bk4qu2BATeHvin3wYer/oS+PTAi6UAnmhR
    \\50rr3gSVEUdoCTPTyO/Gp4zpIzn+6DmTWfzHCIQ69fZblnZjxOwynFDE7XIDp7GZ
    \\E/i4ITN3X1AWBxTi9aeHq2Vg8bJehHo0QDtbs+Q2b7iKS3Zdqn84+sk/a+QvcoUR
    \\UJNPTmw8j3ZoqdC8PC5sYwNye0PLoXtlcMY7eiCixQKBgQDQmjbCnbbaWErqUz9t
    \\1eSteYlNelNPLkVftFwANYRWkm2v3VvEhKQy6+sbBRotnzWMnKsbhZ+ljg6qCpbE
    \\vHHvvAgLHoDwlp9Wyv+wKoBzjEhehsh3h0RoGIMsuyiFmaQITeFxMruH6uC6H6zP
    \\7PAKoBKbDYKiA6VhNZWFkwzqMwKBgQDNZerc2hGx4irnqzIPmlSsnHOk0Fte4a3F
    \\rIsyLf+b6LaR6aGrJdF1zpL37LZLQa1IQBHw8XHpcngV5IWpNflKNySPlaUaRvQw
    \\ZA/5lJRNcNeCMZb4xZB9GblurxU/aorBsfqwkMS7RfnN3drY5+tR65vpzPOLGz9c
    \\5Cy9X7CK8wKBgHGK/zN/VQAT/vL8zRGj0wz5klqxspbuwKQPL+SNPLNCkKGhA0o8
    \\SIPPFfFnHZCnkCYxQJGCchtS73huuxHq4Ll0x4wF1nkeAyzi4bmp6LD8MogBJSyq
    \\W/mtHflDBhNyRW6ftY4/5wNcPWYRx6aFeULPTlFHUUuOYH5BBFnoaKcxAoGAJLc6
    \\M35buWOHbeAhU76vsidJWMXR/3Tx/irouvCUB4ei0xRjTNe2yItDpEPRFkTIN+kU
    \\C/Ds/uDybF9sMSIvzL9srqn+WGMklV3dqSyREgLA00oQBaozONmXVxy+/JYL9bHd
    \\8R//usY4cD9fNnTGkN9AAJwdUNlvCyjSgouPYFcCgYA+/S9Ij3J6BHazJKW4PsaH
    \\e5kFco0PSH8tvzhrEKszBpVY5UHzpwOEllX4j8SIVmy5cMwnvE/A6RBgY/nm7CGB
    \\B2pyh/bKaTFFtYAAJ1Q/I219Y+FCbhN9+3TNvcocU1iX8UhIp8CCuemEHHkMlasd
    \\9VHhqdnUb+9O82SMgRORSQ==
    \\-----END PRIVATE KEY-----
;
const test_message = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJ0ZXN0In0";
const test_signature = "fEBwr2YKXmSJGCmKtWnQRMLppIWqDpCdQ-cCGEV5YSmF75_kbG7eHsS41wQFuBTobqfRA0WOCgjIXRz0wUaw2a8NvEUBVm814uGAGzcp0yYzVJl7HWrwvR6jvS5SRpF9mu0-pG5GHkgcKFYer96T5GVuMe624qZiI_G_5b2txkBu0xggtMtWfP_OZ3aX4JMNJzsffZE1WeKKv1DgV-LlGYrTG1kljzZ7VGWJqQ3iTvbhk5QN5-jsBkODr7f5MOhMCD4AkRhembPoXQcMPX-osO5Tcx3RNGtKTaqyJ153sPIq9JIIJB8rZm7NLnuuFT04DWfWtQyl53zxgpJQWEShtw";

test "signs exactly as OpenSSL does" {
    const gpa = std.testing.allocator;
    const key = try PrivateKey.fromPem(gpa, test_key_pem);
    defer key.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 256), key.n.len);
    const sig = try key.signSha256(gpa, test_message);
    defer gpa.free(sig);
    var expected: [256]u8 = undefined;
    try std.base64.url_safe_no_pad.Decoder.decode(&expected, test_signature);
    try std.testing.expectEqualSlices(u8, &expected, sig);
}
