//! Server certificates: an ECDSA P-256 key with its DER certificate chain. Loads PEM (from
//! ACME or openssl), matches SNI host names with std's own checks, and makes self-signed
//! certificates for development and tests. Also holds the small DER writer ACME's CSRs use.

const std = @import("std");

pub const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
pub const KeyPair = Ecdsa.KeyPair;

pub const Certificate = struct {
    /// DER certificates, leaf first.
    chain: []const []const u8,
    key: KeyPair,
    leaf: std.crypto.Certificate.Parsed,

    pub fn init(chain: []const []const u8, key: KeyPair) !Certificate {
        if (chain.len == 0) return error.EmptyChain;
        const leaf = try (std.crypto.Certificate{ .buffer = chain[0], .index = 0 }).parse();
        // The certificate must be for this key.
        if (!std.mem.eql(u8, leaf.pubKey(), &key.public_key.toUncompressedSec1())) return error.KeyDoesNotMatchCertificate;
        return .{ .chain = chain, .key = key, .leaf = leaf };
    }

    /// Whether the certificate covers `host` (SAN or CN, wildcards as browsers apply them).
    pub fn matches(c: Certificate, host: []const u8) bool {
        c.leaf.verifyHostName(host) catch return false;
        return true;
    }

    /// Seconds since the epoch after which the certificate is no longer valid.
    pub fn notAfter(c: Certificate) u64 {
        return c.leaf.validity.not_after;
    }
};

/// A certificate chain and key from PEM text. The key may be SEC1 ("EC PRIVATE KEY") or PKCS#8
/// ("PRIVATE KEY"), P-256 only.
pub fn loadPem(arena: std.mem.Allocator, chain_pem: []const u8, key_pem: []const u8) !Certificate {
    var chain: std.ArrayList([]const u8) = .empty;
    var it = PemIterator{ .text = chain_pem };
    while (try it.next(arena)) |block| {
        if (std.mem.eql(u8, block.label, "CERTIFICATE")) try chain.append(arena, block.der);
    }
    var kit = PemIterator{ .text = key_pem };
    while (try kit.next(arena)) |block| {
        const secret = if (std.mem.eql(u8, block.label, "EC PRIVATE KEY"))
            try sec1Secret(block.der)
        else if (std.mem.eql(u8, block.label, "PRIVATE KEY"))
            try pkcs8Secret(block.der)
        else
            continue;
        const key = try KeyPair.fromSecretKey(try Ecdsa.SecretKey.fromBytes(secret));
        return Certificate.init(chain.items, key);
    }
    return error.NoPrivateKey;
}

pub const PemBlock = struct { label: []const u8, der: []const u8 };

pub const PemIterator = struct {
    text: []const u8,
    pos: usize = 0,

    pub fn next(it: *PemIterator, arena: std.mem.Allocator) !?PemBlock {
        const begin = "-----BEGIN ";
        const start = std.mem.indexOfPos(u8, it.text, it.pos, begin) orelse return null;
        const label_end = std.mem.indexOfPos(u8, it.text, start, "-----\n") orelse std.mem.indexOfPos(u8, it.text, start, "-----\r\n") orelse return error.BadPem;
        const label = it.text[start + begin.len .. label_end];
        const body_start = std.mem.indexOfScalarPos(u8, it.text, label_end, '\n').? + 1;
        const end_marker = try std.fmt.allocPrint(arena, "-----END {s}-----", .{label});
        const body_end = std.mem.indexOfPos(u8, it.text, body_start, end_marker) orelse return error.BadPem;
        it.pos = body_end + end_marker.len;

        var b64: std.ArrayList(u8) = .empty;
        for (it.text[body_start..body_end]) |ch| {
            if (!std.ascii.isWhitespace(ch)) try b64.append(arena, ch);
        }
        const der = try arena.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(b64.items));
        try std.base64.standard.Decoder.decode(der, b64.items);
        return .{ .label = label, .der = der };
    }
};

/// Writes PEM text for `der` under `label`.
pub fn writePem(w: *std.Io.Writer, label: []const u8, der: []const u8) !void {
    try w.print("-----BEGIN {s}-----\n", .{label});
    var i: usize = 0;
    while (i < der.len) : (i += 48) {
        const chunk = der[i..@min(i + 48, der.len)];
        var buf: [64]u8 = undefined;
        try w.print("{s}\n", .{std.base64.standard.Encoder.encode(&buf, chunk)});
    }
    try w.print("-----END {s}-----\n", .{label});
}

// ---- DER reading: just enough for private keys ------------------------------------------

const Tlv = struct { tag: u8, value: []const u8, end: usize };

fn readTlv(bytes: []const u8, pos: usize) !Tlv {
    if (pos + 2 > bytes.len) return error.BadDer;
    const tag = bytes[pos];
    var len: usize = bytes[pos + 1];
    var p = pos + 2;
    if (len & 0x80 != 0) {
        const n = len & 0x7f;
        if (n == 0 or n > 3 or p + n > bytes.len) return error.BadDer;
        len = 0;
        for (bytes[p .. p + n]) |b| len = len << 8 | b;
        p += n;
    }
    if (p + len > bytes.len) return error.BadDer;
    return .{ .tag = tag, .value = bytes[p .. p + len], .end = p + len };
}

/// ECPrivateKey ::= SEQUENCE { version 1, privateKey OCTET STRING, [0] params, [1] publicKey }
fn sec1Secret(der: []const u8) ![32]u8 {
    const seq = try readTlv(der, 0);
    if (seq.tag != 0x30) return error.BadKey;
    const version = try readTlv(seq.value, 0);
    const key = try readTlv(seq.value, version.end);
    if (key.tag != 0x04 or key.value.len != 32) return error.UnsupportedKey;
    return key.value[0..32].*;
}

/// PrivateKeyInfo ::= SEQUENCE { version, AlgorithmIdentifier, privateKey OCTET STRING (SEC1) }
fn pkcs8Secret(der: []const u8) ![32]u8 {
    const seq = try readTlv(der, 0);
    if (seq.tag != 0x30) return error.BadKey;
    const version = try readTlv(seq.value, 0);
    const algo = try readTlv(seq.value, version.end);
    // id-ecPublicKey with the prime256v1 curve
    if (std.mem.indexOf(u8, algo.value, &oid_prime256v1) == null) return error.UnsupportedKey;
    const inner = try readTlv(seq.value, algo.end);
    if (inner.tag != 0x04) return error.BadKey;
    return sec1Secret(inner.value);
}

// ---- DER writing ---------------------------------------------------------------------

pub const oid_ec_public_key = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01 };
pub const oid_prime256v1 = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07 };
pub const oid_ecdsa_sha256 = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02 };
pub const oid_common_name = [_]u8{ 0x55, 0x04, 0x03 };
pub const oid_subject_alt_name = [_]u8{ 0x55, 0x1D, 0x11 };
pub const oid_extension_request = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x0E };

/// Builds DER by nesting: `begin` a constructed value, write its contents, `end` it.
pub const Der = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    open: std.ArrayList(usize) = .empty,

    pub fn begin(d: *Der, tag: u8) !void {
        try d.buf.append(d.gpa, tag);
        try d.open.append(d.gpa, d.buf.items.len);
    }

    /// Closes the innermost value, inserting its length before the contents.
    pub fn end(d: *Der) !void {
        const start = d.open.pop() orelse return error.NothingOpen;
        const len = d.buf.items.len - start;
        var hdr: [4]u8 = undefined;
        const h = lengthBytes(len, &hdr);
        try d.buf.insertSlice(d.gpa, start, h);
    }

    pub fn value(d: *Der, tag: u8, bytes: []const u8) !void {
        try d.buf.append(d.gpa, tag);
        var hdr: [4]u8 = undefined;
        try d.buf.appendSlice(d.gpa, lengthBytes(bytes.len, &hdr));
        try d.buf.appendSlice(d.gpa, bytes);
    }

    pub fn oid(d: *Der, bytes: []const u8) !void {
        return d.value(0x06, bytes);
    }

    /// A non-negative INTEGER from big-endian bytes.
    pub fn uint(d: *Der, be: []const u8) !void {
        var b = be;
        while (b.len > 1 and b[0] == 0) b = b[1..];
        if (b[0] & 0x80 != 0) {
            try d.buf.append(d.gpa, 0x02);
            var hdr: [4]u8 = undefined;
            try d.buf.appendSlice(d.gpa, lengthBytes(b.len + 1, &hdr));
            try d.buf.append(d.gpa, 0);
            try d.buf.appendSlice(d.gpa, b);
        } else try d.value(0x02, b);
    }

    pub fn bitString(d: *Der, bytes: []const u8) !void {
        try d.begin(0x03);
        try d.buf.append(d.gpa, 0);
        try d.buf.appendSlice(d.gpa, bytes);
        try d.end();
    }

    /// Name ::= SEQUENCE { SET { SEQUENCE { commonName, UTF8String } } }
    pub fn commonName(d: *Der, cn: []const u8) !void {
        try d.begin(0x30);
        try d.begin(0x31);
        try d.begin(0x30);
        try d.oid(&oid_common_name);
        try d.value(0x0C, cn);
        try d.end();
        try d.end();
        try d.end();
    }

    /// SubjectPublicKeyInfo for a P-256 key.
    pub fn publicKey(d: *Der, pk: Ecdsa.PublicKey) !void {
        try d.begin(0x30);
        try d.begin(0x30);
        try d.oid(&oid_ec_public_key);
        try d.oid(&oid_prime256v1);
        try d.end();
        try d.bitString(&pk.toUncompressedSec1());
        try d.end();
    }

    /// Extension { subjectAltName, OCTET STRING { SEQUENCE { dNSName... } } }
    pub fn subjectAltNames(d: *Der, names: []const []const u8) !void {
        try d.begin(0x30);
        try d.oid(&oid_subject_alt_name);
        try d.begin(0x04);
        try d.begin(0x30);
        for (names) |n| try d.value(0x82, n);
        try d.end();
        try d.end();
        try d.end();
    }

    pub fn ecdsaAlgorithm(d: *Der) !void {
        try d.begin(0x30);
        try d.oid(&oid_ecdsa_sha256);
        try d.end();
    }

    /// Signs `tbs` (already DER) and wraps it: SEQUENCE { tbs, algorithm, BIT STRING signature }.
    pub fn signed(d: *Der, tbs: []const u8, key: KeyPair) !void {
        const sig = try key.sign(tbs, null);
        var sig_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
        try d.begin(0x30);
        try d.buf.appendSlice(d.gpa, tbs);
        try d.ecdsaAlgorithm();
        try d.bitString(sig.toDer(&sig_buf));
        try d.end();
    }

    pub fn written(d: *Der) []const u8 {
        return d.buf.items;
    }
};

fn lengthBytes(len: usize, buf: *[4]u8) []const u8 {
    if (len < 0x80) {
        buf[0] = @intCast(len);
        return buf[0..1];
    }
    if (len <= 0xff) {
        buf[0..2].* = .{ 0x81, @intCast(len) };
        return buf[0..2];
    }
    if (len <= 0xffff) {
        buf[0..3].* = .{ 0x82, @intCast(len >> 8), @truncate(len) };
        return buf[0..3];
    }
    buf.* = .{ 0x83, @intCast(len >> 16), @truncate(len >> 8), @truncate(len) };
    return buf;
}

/// UTCTime ("YYMMDDHHMMSSZ") or, from 2050 on, GeneralizedTime.
fn writeTime(d: *Der, unix: i64) !void {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(unix) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    var buf: [16]u8 = undefined;
    const year: u32 = yd.year;
    if (year < 2050) {
        try d.value(0x17, try std.fmt.bufPrint(&buf, "{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}Z", .{ year % 100, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() }));
    } else {
        try d.value(0x18, try std.fmt.bufPrint(&buf, "{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}Z", .{ year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() }));
    }
}

/// A self-signed certificate (DER) for `names`, valid from `not_before` to `not_after`
/// (Unix seconds). For development and tests; production certificates come from ACME.
pub fn selfSigned(io: std.Io, gpa: std.mem.Allocator, key: KeyPair, names: []const []const u8, not_before: i64, not_after: i64) ![]u8 {
    var tbs: Der = .{ .gpa = gpa };
    defer tbs.buf.deinit(gpa);
    defer tbs.open.deinit(gpa);
    try tbs.begin(0x30);
    {
        try tbs.begin(0xA0); // [0] version
        try tbs.uint(&.{2}); // v3
        try tbs.end();
        var serial: [16]u8 = undefined;
        io.random(&serial);
        serial[0] &= 0x7f;
        try tbs.uint(&serial);
        try tbs.ecdsaAlgorithm();
        try tbs.commonName(names[0]);
        try tbs.begin(0x30);
        try writeTime(&tbs, not_before);
        try writeTime(&tbs, not_after);
        try tbs.end();
        try tbs.commonName(names[0]);
        try tbs.publicKey(key.public_key);
        try tbs.begin(0xA3); // [3] extensions
        try tbs.begin(0x30);
        try tbs.subjectAltNames(names);
        try tbs.end();
        try tbs.end();
    }
    try tbs.end();

    var cert: Der = .{ .gpa = gpa };
    defer cert.open.deinit(gpa);
    errdefer cert.buf.deinit(gpa);
    try cert.signed(tbs.written(), key);
    return cert.buf.toOwnedSlice(gpa);
}

const testing = std.testing;

test "self-signed certificate parses, verifies its own signature and matches its names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = KeyPair.generate(testing.io);
    const der = try selfSigned(testing.io, a, key, &.{ "maps.wufour.com", "*.wufour.dev" }, 1_700_000_000, 1_900_000_000);
    const c = try Certificate.init(&.{der}, key);
    try testing.expect(c.matches("maps.wufour.com"));
    try testing.expect(c.matches("reseal.wufour.dev"));
    try testing.expect(!c.matches("wufour.com"));
    try testing.expectEqual(@as(u64, 1_900_000_000), c.notAfter());
    // Its signature checks out under its own key, as a client checks a self-signed root.
    try c.leaf.verify(c.leaf, 1_800_000_000);

    // PEM round trip, PKCS#8 key from openssl-style text included.
    var out: std.Io.Writer.Allocating = .init(a);
    try writePem(&out.writer, "CERTIFICATE", der);
    const pkcs8_prefix = [_]u8{ 0x30, 0x41, 0x02, 0x01, 0x00, 0x30, 0x13, 0x06, 0x07 } ++ oid_ec_public_key ++ [_]u8{ 0x06, 0x08 } ++ oid_prime256v1 ++ [_]u8{ 0x04, 0x27, 0x30, 0x25, 0x02, 0x01, 0x01, 0x04, 0x20 };
    const pkcs8 = pkcs8_prefix ++ key.secret_key.toBytes();
    var key_pem: std.Io.Writer.Allocating = .init(a);
    try writePem(&key_pem.writer, "PRIVATE KEY", &pkcs8);
    const loaded = try loadPem(a, out.written(), key_pem.written());
    try testing.expect(loaded.matches("maps.wufour.com"));
}
