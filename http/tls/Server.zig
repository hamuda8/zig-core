//! TLS 1.3 server (RFC 8446): full handshake with X25519 or P-256 key exchange, an ECDSA P-256
//! certificate chosen by SNI, AES-128-GCM / ChaCha20-Poly1305 / AES-256-GCM, ALPN,
//! HelloRetryRequest and KeyUpdate. Deliberately absent: TLS 1.2 and older, session resumption,
//! 0-RTT, client certificates.
//!
//! After `init` returns, `reader` and `writer` carry the decrypted application data, so
//! std.http.Server runs on top unchanged.

const std = @import("std");
const tls = std.crypto.tls;
const keys = @import("keys.zig");
const certs = @import("cert.zig");

const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Server = @This();

input: *Reader,
output: *Writer,
reader: Reader,
writer: Writer,
cipher: Cipher,
read_seq: u64 = 0,
write_seq: u64 = 0,
received_close_notify: bool = false,
read_err: ?ReadError = null,
/// SNI the client asked for ("" if none).
server_name_buf: [255]u8 = undefined,
server_name_len: u8 = 0,
/// Negotiated application protocol, one of `Options.alpn` (null if the client sent none).
alpn: ?[]const u8 = null,

pub const ReadError = error{
    TlsBadRecordMac,
    TlsRecordOverflow,
    TlsDecodeError,
    TlsUnexpectedMessage,
    TlsAlert,
    TlsConnectionTruncated,
    TlsSequenceOverflow,
};

/// Buffers handed to `init` (and the connection's own reader/writer buffers) must hold at
/// least one full record.
pub const min_buffer_len = tls.max_ciphertext_record_len;

pub const Options = struct {
    io: std.Io,
    /// The first certificate is used when SNI matches none (or is absent).
    certificates: []const certs.Certificate,
    alpn: []const []const u8 = &.{"http/1.1"},
    /// Holds decrypted application data. At least `min_buffer_len`.
    read_buffer: []u8,
    write_buffer: []u8,
};

fn Traffic(comptime A: type, comptime H: type) type {
    return struct {
        pub const Aead = A;
        pub const Hash = H;
        pub const S = keys.Schedule(H);
        client_secret: S.Secret,
        server_secret: S.Secret,
        client: S.Keys(A),
        server: S.Keys(A),
    };
}

pub const Cipher = union(enum) {
    AES_128_GCM_SHA256: Traffic(std.crypto.aead.aes_gcm.Aes128Gcm, std.crypto.hash.sha2.Sha256),
    CHACHA20_POLY1305_SHA256: Traffic(std.crypto.aead.chacha_poly.ChaCha20Poly1305, std.crypto.hash.sha2.Sha256),
    AES_256_GCM_SHA384: Traffic(std.crypto.aead.aes_gcm.Aes256Gcm, std.crypto.hash.sha2.Sha384),
};

/// Server preference: AES-128-GCM (hardware AES), ChaCha20 (phones without it), AES-256-GCM.
const suite_preference = [_]tls.CipherSuite{ .AES_128_GCM_SHA256, .CHACHA20_POLY1305_SHA256, .AES_256_GCM_SHA384 };
const group_preference = [_]tls.NamedGroup{ .x25519, .secp256r1 };

pub fn serverName(s: *const Server) []const u8 {
    return s.server_name_buf[0..s.server_name_len];
}

// ---- Parsing --------------------------------------------------------------------------

const Cursor = struct {
    b: []const u8,
    i: usize = 0,

    fn need(c: *Cursor, n: usize) !void {
        if (c.b.len - c.i < n) return error.TlsDecodeError;
    }
    fn int(c: *Cursor, comptime T: type) !T {
        const n = @divExact(@bitSizeOf(T), 8);
        try c.need(n);
        defer c.i += n;
        return std.mem.readInt(T, c.b[c.i..][0..n], .big);
    }
    fn bytes(c: *Cursor, n: usize) ![]const u8 {
        try c.need(n);
        defer c.i += n;
        return c.b[c.i..][0..n];
    }
    /// A vector with a length prefix of type `L`.
    fn vec(c: *Cursor, comptime L: type) ![]const u8 {
        return c.bytes(try c.int(L));
    }
    fn done(c: Cursor) bool {
        return c.i == c.b.len;
    }
};

const Hello = struct {
    /// The whole handshake message, header included (for the transcript).
    raw: []const u8,
    session_id: []const u8,
    suites: []const u8 = "",
    groups: []const u8 = "",
    shares: []const u8 = "",
    sig_algs: []const u8 = "",
    versions: []const u8 = "",
    server_name: ?[]const u8 = null,
    alpn: ?[]const u8 = null,
};

fn parseHello(msg: []const u8) !Hello {
    var c: Cursor = .{ .b = msg };
    if (try c.int(u8) != @backingInt(tls.HandshakeType.client_hello)) return error.TlsUnexpectedMessage;
    const len = try c.int(u24);
    if (len != msg.len - 4) return error.TlsDecodeError;
    _ = try c.int(u16); // legacy_version
    _ = try c.bytes(32); // random
    var h: Hello = .{ .raw = msg, .session_id = try c.vec(u8) };
    if (h.session_id.len > 32) return error.TlsDecodeError;
    h.suites = try c.vec(u16);
    const compression = try c.vec(u8);
    if (compression.len != 1 or compression[0] != 0) return error.TlsIllegalParameter;
    var ext: Cursor = .{ .b = try c.vec(u16) };
    if (!c.done()) return error.TlsDecodeError;
    while (!ext.done()) {
        const t = try ext.int(u16);
        var body: Cursor = .{ .b = try ext.vec(u16) };
        switch (@as(tls.ExtensionType, @fromBackingInt(t))) {
            .supported_versions => h.versions = try body.vec(u8),
            .supported_groups => h.groups = try body.vec(u16),
            .key_share => h.shares = try body.vec(u16),
            .signature_algorithms => h.sig_algs = try body.vec(u16),
            .server_name => {
                var list: Cursor = .{ .b = try body.vec(u16) };
                while (!list.done()) {
                    const kind = try list.int(u8);
                    const name = try list.vec(u16);
                    if (kind == 0 and name.len > 0 and name.len <= 255) h.server_name = name;
                }
            },
            .application_layer_protocol_negotiation => h.alpn = try body.vec(u16),
            else => {},
        }
    }
    return h;
}

fn contains16(list: []const u8, v: u16) bool {
    var i: usize = 0;
    while (i + 2 <= list.len) : (i += 2) if (std.mem.readInt(u16, list[i..][0..2], .big) == v) return true;
    return false;
}

/// The client's key share for `group`, if it sent one.
fn shareFor(shares: []const u8, group: tls.NamedGroup) ?[]const u8 {
    var c: Cursor = .{ .b = shares };
    while (!c.done()) {
        const g = c.int(u16) catch return null;
        const key = c.vec(u16) catch return null;
        if (g == @backingInt(group)) return key;
    }
    return null;
}

// ---- Records ----------------------------------------------------------------------------

fn writePlain(out: *Writer, ct: tls.ContentType, data: []const u8) !void {
    var i: usize = 0;
    while (true) {
        const n = @min(data.len - i, tls.max_ciphertext_inner_record_len);
        try out.writeByte(@backingInt(ct));
        try out.writeInt(u16, 0x0303, .big);
        try out.writeInt(u16, @intCast(n), .big);
        try out.writeAll(data[i..][0..n]);
        i += n;
        if (i >= data.len) return;
    }
}

/// Encrypts `data` as records of inner type `ct` with `k`, starting at sequence `seq.*`.
fn writeSealed(comptime T: type, out: *Writer, k: T.S.Keys(T.Aead), seq: *u64, ct: tls.ContentType, data: []const u8) !void {
    var i: usize = 0;
    while (true) {
        const n = @min(data.len - i, tls.max_ciphertext_inner_record_len);
        var plain: [tls.max_ciphertext_inner_record_len + 1]u8 = undefined;
        @memcpy(plain[0..n], data[i..][0..n]);
        plain[n] = @backingInt(ct);
        const record_len = n + 1 + T.Aead.tag_length;
        const buf = try out.writableSlice(5 + record_len);
        buf[0..5].* = .{ @backingInt(tls.ContentType.application_data), 0x03, 0x03, @intCast(record_len >> 8), @truncate(record_len) };
        T.Aead.encrypt(buf[5..][0 .. n + 1], buf[5 + n + 1 ..][0..T.Aead.tag_length], plain[0 .. n + 1], buf[0..5], keys.nonce(T.Aead.nonce_length, k.iv, seq.*), k.key);
        seq.* += 1;
        i += n;
        if (i >= data.len) return;
    }
}

const Opened = struct { ct: tls.ContentType, data: []u8 };

/// Reads one record and decrypts it into `dest`. Plaintext ChangeCipherSpec records (sent for
/// middlebox compatibility) are skipped.
fn readSealed(comptime T: type, in: *Reader, k: T.S.Keys(T.Aead), seq: *u64, dest: []u8) !Opened {
    while (true) {
        const hdr = in.takeArray(5) catch return error.TlsConnectionTruncated;
        const len = std.mem.readInt(u16, hdr[3..5], .big);
        if (len > tls.max_ciphertext_len) return error.TlsRecordOverflow;
        const body = in.take(len) catch return error.TlsConnectionTruncated;
        if (hdr[0] == @backingInt(tls.ContentType.change_cipher_spec)) {
            if (len != 1 or body[0] != 1) return error.TlsUnexpectedMessage;
            continue;
        }
        if (hdr[0] != @backingInt(tls.ContentType.application_data)) return error.TlsUnexpectedMessage;
        if (len < T.Aead.tag_length + 1) return error.TlsDecodeError;
        const clen = len - T.Aead.tag_length;
        if (clen > dest.len) return error.TlsRecordOverflow;
        T.Aead.decrypt(dest[0..clen], body[0..clen], body[clen..][0..T.Aead.tag_length].*, hdr, keys.nonce(T.Aead.nonce_length, k.iv, seq.*), k.key) catch return error.TlsBadRecordMac;
        seq.* += 1;
        // Strip the zero padding; the last non-zero byte is the real content type.
        var last = clen;
        while (last > 0 and dest[last - 1] == 0) last -= 1;
        if (last == 0) return error.TlsUnexpectedMessage;
        return .{ .ct = @fromBackingInt(dest[last - 1]), .data = dest[0 .. last - 1] };
    }
}

/// Reads one plaintext handshake message (the ClientHello), possibly spread over records.
fn readPlainHandshake(in: *Reader, buf: []u8, allow_ccs: bool) ![]const u8 {
    var have: usize = 0;
    while (true) {
        if (have >= 4) {
            const want = 4 + @as(usize, std.mem.readInt(u24, buf[1..4], .big));
            if (want > buf.len) return error.TlsRecordOverflow;
            if (have >= want) {
                if (have != want) return error.TlsUnexpectedMessage; // nothing may follow the hello
                return buf[0..want];
            }
        }
        const hdr = in.takeArray(5) catch return error.TlsConnectionTruncated;
        const len = std.mem.readInt(u16, hdr[3..5], .big);
        if (len > tls.max_ciphertext_inner_record_len) return error.TlsRecordOverflow;
        const body = in.take(len) catch return error.TlsConnectionTruncated;
        if (allow_ccs and hdr[0] == @backingInt(tls.ContentType.change_cipher_spec)) continue;
        if (hdr[0] != @backingInt(tls.ContentType.handshake) or len == 0) return error.TlsUnexpectedMessage;
        if (have + len > buf.len) return error.TlsRecordOverflow;
        @memcpy(buf[have..][0..len], body);
        have += len;
    }
}

fn alertPlain(out: *Writer, d: tls.Alert.Description) void {
    writePlain(out, .alert, &.{ 2, @backingInt(d) }) catch return;
    out.flush() catch {};
}

fn alertFor(err: anyerror) tls.Alert.Description {
    return switch (err) {
        error.TlsDecodeError => .decode_error,
        error.TlsIllegalParameter => .illegal_parameter,
        error.TlsProtocolVersion => .protocol_version,
        error.TlsNoApplicationProtocol => .no_application_protocol,
        error.TlsBadRecordMac => .bad_record_mac,
        error.TlsDecryptError => .decrypt_error,
        error.TlsUnexpectedMessage => .unexpected_message,
        error.TlsRecordOverflow => .record_overflow,
        else => .handshake_failure,
    };
}

// ---- Handshake --------------------------------------------------------------------------

/// Runs the handshake on `input`/`output` (the raw connection).
pub fn init(input: *Reader, output: *Writer, options: Options) !Server {
    std.debug.assert(options.read_buffer.len >= min_buffer_len);
    var hello_buf: [32 * 1024]u8 = undefined;
    return handshake(input, output, options, &hello_buf) catch |err| {
        switch (err) {
            error.TlsConnectionTruncated, error.WriteFailed => {},
            else => alertPlain(output, alertFor(err)),
        }
        return err;
    };
}

fn handshake(input: *Reader, output: *Writer, options: Options, hello_buf: []u8) !Server {
    var hello = try parseHello(try readPlainHandshake(input, hello_buf, false));
    if (!contains16(hello.versions, 0x0304)) return error.TlsProtocolVersion;
    if (!contains16(hello.sig_algs, @backingInt(tls.SignatureScheme.ecdsa_secp256r1_sha256))) return error.TlsHandshakeFailure;

    const suite = for (suite_preference) |s| {
        if (contains16(hello.suites, @backingInt(s))) break s;
    } else return error.TlsHandshakeFailure;

    switch (suite) {
        inline .AES_128_GCM_SHA256, .CHACHA20_POLY1305_SHA256, .AES_256_GCM_SHA384 => |tag| {
            const T = @FieldType(Cipher, @tagName(tag));
            return handshakeWith(T, tag, input, output, options, &hello, hello_buf);
        },
        else => unreachable,
    }
}

fn handshakeWith(comptime T: type, comptime tag: tls.CipherSuite, input: *Reader, output: *Writer, options: Options, hello: *Hello, hello_buf: []u8) !Server {
    const S = T.S;
    var transcript = T.Hash.init(.{});
    var sent_ccs = false;

    // Key exchange group: a share the client sent, in our order of preference; otherwise ask
    // for one with a HelloRetryRequest.
    var group: ?tls.NamedGroup = null;
    for (group_preference) |g| if (shareFor(hello.shares, g) != null) {
        group = g;
        break;
    };
    if (group == null) {
        const g = for (group_preference) |g| {
            if (contains16(hello.groups, @backingInt(g))) break g;
        } else return error.TlsHandshakeFailure;

        // The transcript starts over with a hash of the first ClientHello (RFC 8446 4.4.1).
        var first: [T.Hash.digest_length]u8 = undefined;
        T.Hash.hash(hello.raw, &first, .{});
        transcript.update(&.{ @backingInt(tls.HandshakeType.message_hash), 0, 0, T.Hash.digest_length });
        transcript.update(&first);

        var hrr_buf: [128]u8 = undefined;
        const hrr = try serverHello(&hrr_buf, tls.hello_retry_request_sequence, hello.session_id, tag, &.{
            .{ .supported_versions = {} },
            .{ .key_share_group = g },
        });
        transcript.update(hrr);
        try writePlain(output, .handshake, hrr);
        if (hello.session_id.len > 0) {
            try writePlain(output, .change_cipher_spec, &.{1});
            sent_ccs = true;
        }
        try output.flush();

        const session_id = hello.session_id;
        hello.* = try parseHello(try readPlainHandshake(input, hello_buf, true));
        if (!std.mem.eql(u8, session_id, hello.session_id) or !contains16(hello.suites, @backingInt(tag))) return error.TlsIllegalParameter;
        if (shareFor(hello.shares, g) == null) return error.TlsIllegalParameter;
        group = g;
    }
    transcript.update(hello.raw);

    // Our key share and the shared secret.
    var shared_buf: [32]u8 = undefined;
    var share_buf: [65]u8 = undefined;
    var our_share: []const u8 = undefined;
    const client_share = shareFor(hello.shares, group.?).?;
    switch (group.?) {
        .x25519 => {
            if (client_share.len != 32) return error.TlsIllegalParameter;
            const kp = std.crypto.dh.X25519.KeyPair.generate(options.io);
            shared_buf = std.crypto.dh.X25519.scalarmult(kp.secret_key, client_share[0..32].*) catch return error.TlsIllegalParameter;
            share_buf[0..32].* = kp.public_key;
            our_share = share_buf[0..32];
        },
        .secp256r1 => {
            const P256 = std.crypto.ecc.P256;
            const peer = P256.fromSec1(client_share) catch return error.TlsIllegalParameter;
            var sk: [32]u8 = undefined;
            while (true) {
                options.io.random(&sk);
                const pub_point = P256.basePoint.mul(sk, .big) catch continue;
                share_buf = pub_point.toUncompressedSec1();
                break;
            }
            const point = peer.mul(sk, .big) catch return error.TlsIllegalParameter;
            shared_buf = point.affineCoordinates().x.toBytes(.big);
            our_share = &share_buf;
        },
        else => unreachable,
    }

    var random: [32]u8 = undefined;
    options.io.random(&random);
    var sh_buf: [256]u8 = undefined;
    const sh = try serverHello(&sh_buf, random, hello.session_id, tag, &.{
        .{ .supported_versions = {} },
        .{ .key_share = .{ .group = group.?, .key = our_share } },
    });
    transcript.update(sh);
    try writePlain(output, .handshake, sh);
    if (hello.session_id.len > 0 and !sent_ccs) try writePlain(output, .change_cipher_spec, &.{1});

    const hs_secret = S.handshakeSecret(&shared_buf);
    const th_hello = transcript.peek();
    const c_hs = S.derive(hs_secret, "c hs traffic", th_hello);
    const s_hs = S.derive(hs_secret, "s hs traffic", th_hello);
    const c_keys = S.trafficKeys(T.Aead, c_hs);
    const s_keys = S.trafficKeys(T.Aead, s_hs);

    // Certificate by SNI, application protocol by ALPN.
    const cert = for (options.certificates) |c| {
        if (hello.server_name) |n| if (c.matches(n)) break c;
    } else options.certificates[0];
    var alpn: ?[]const u8 = null;
    if (hello.alpn) |theirs| {
        alpn = for (options.alpn) |ours| {
            var lc: Cursor = .{ .b = theirs };
            const found = while (!lc.done()) {
                if (std.mem.eql(u8, try lc.vec(u8), ours)) break true;
            } else false;
            if (found) break ours;
        } else return error.TlsNoApplicationProtocol;
    }

    // The server's encrypted flight: EncryptedExtensions, Certificate, CertificateVerify, Finished.
    var flight_buf: [16 * 1024]u8 = undefined;
    var flight: Writer = .fixed(&flight_buf);
    {
        const start = flight.end;
        try flight.writeByte(@backingInt(tls.HandshakeType.encrypted_extensions));
        try flight.writeInt(u24, 0, .big);
        if (alpn) |p| {
            try flight.writeInt(u16, @intCast(2 + 2 + 2 + 1 + p.len), .big);
            try flight.writeInt(u16, @backingInt(tls.ExtensionType.application_layer_protocol_negotiation), .big);
            try flight.writeInt(u16, @intCast(2 + 1 + p.len), .big);
            try flight.writeInt(u16, @intCast(1 + p.len), .big);
            try flight.writeByte(@intCast(p.len));
            try flight.writeAll(p);
        } else try flight.writeInt(u16, 0, .big);
        finishMessage(&flight_buf, start, flight.end);
        transcript.update(flight_buf[start..flight.end]);
    }
    {
        const start = flight.end;
        try flight.writeByte(@backingInt(tls.HandshakeType.certificate));
        try flight.writeInt(u24, 0, .big);
        try flight.writeByte(0); // certificate_request_context
        var list_len: usize = 0;
        for (cert.chain) |der| list_len += 3 + der.len + 2;
        try flight.writeInt(u24, @intCast(list_len), .big);
        for (cert.chain) |der| {
            try flight.writeInt(u24, @intCast(der.len), .big);
            try flight.writeAll(der);
            try flight.writeInt(u16, 0, .big);
        }
        finishMessage(&flight_buf, start, flight.end);
        transcript.update(flight_buf[start..flight.end]);
    }
    {
        const start = flight.end;
        var content: [64 + 34 + T.Hash.digest_length]u8 = undefined;
        @memset(content[0..64], 0x20);
        content[64..][0..34].* = "TLS 1.3, server CertificateVerify\x00".*;
        content[98..].* = transcript.peek();
        var noise: [certs.Ecdsa.noise_length]u8 = undefined;
        options.io.random(&noise);
        const sig = cert.key.sign(&content, noise) catch return error.TlsHandshakeFailure;
        var der_buf: [certs.Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
        const der = sig.toDer(&der_buf);
        try flight.writeByte(@backingInt(tls.HandshakeType.certificate_verify));
        try flight.writeInt(u24, 0, .big);
        try flight.writeInt(u16, @backingInt(tls.SignatureScheme.ecdsa_secp256r1_sha256), .big);
        try flight.writeInt(u16, @intCast(der.len), .big);
        try flight.writeAll(der);
        finishMessage(&flight_buf, start, flight.end);
        transcript.update(flight_buf[start..flight.end]);
    }
    {
        const start = flight.end;
        try flight.writeByte(@backingInt(tls.HandshakeType.finished));
        try flight.writeInt(u24, T.Hash.digest_length, .big);
        try flight.writeAll(&S.verifyData(s_hs, transcript.peek()));
        transcript.update(flight_buf[start..flight.end]);
    }
    var write_seq: u64 = 0;
    try writeSealed(T, output, s_keys, &write_seq, .handshake, flight.buffered());
    try output.flush();

    // Application secrets cover the transcript through the server Finished.
    const master = S.masterSecret(hs_secret);
    const th_server_finished = transcript.peek();
    const c_ap = S.derive(master, "c ap traffic", th_server_finished);
    const s_ap = S.derive(master, "s ap traffic", th_server_finished);

    // The client's Finished proves it derived the same keys.
    var read_seq: u64 = 0;
    var fin_buf: [256]u8 = undefined;
    const fin = readSealed(T, input, c_keys, &read_seq, &fin_buf) catch |err| {
        alertSealed(T, output, s_keys, &write_seq, alertFor(err));
        return err;
    };
    const expected = S.verifyData(c_hs, th_server_finished);
    const ok = fin.ct == .handshake and fin.data.len == 4 + expected.len and
        fin.data[0] == @backingInt(tls.HandshakeType.finished) and
        std.crypto.timing_safe.eql([expected.len]u8, fin.data[4..][0..expected.len].*, expected);
    if (!ok) {
        alertSealed(T, output, s_keys, &write_seq, .decrypt_error);
        return error.TlsDecryptError;
    }

    var s: Server = .{
        .input = input,
        .output = output,
        .reader = .{ .buffer = options.read_buffer, .vtable = &.{ .stream = stream, .readVec = readVec }, .seek = 0, .end = 0 },
        .writer = .{ .buffer = options.write_buffer, .vtable = &.{ .drain = drain, .flush = flush } },
        .cipher = @unionInit(Cipher, @tagName(tag), .{
            .client_secret = c_ap,
            .server_secret = s_ap,
            .client = S.trafficKeys(T.Aead, c_ap),
            .server = S.trafficKeys(T.Aead, s_ap),
        }),
        .alpn = alpn,
    };
    if (hello.server_name) |n| {
        @memcpy(s.server_name_buf[0..n.len], n);
        s.server_name_len = @intCast(n.len);
    }
    return s;
}

fn alertSealed(comptime T: type, out: *Writer, k: T.S.Keys(T.Aead), seq: *u64, d: tls.Alert.Description) void {
    writeSealed(T, out, k, seq, .alert, &.{ 2, @backingInt(d) }) catch return;
    out.flush() catch {};
}

/// Fills in the 24-bit length of the handshake message at `buf[start..end]`.
fn finishMessage(buf: []u8, start: usize, stop: usize) void {
    std.mem.writeInt(u24, buf[start + 1 ..][0..3], @intCast(stop - start - 4), .big);
}

const HelloExtension = union(enum) {
    supported_versions,
    key_share: struct { group: tls.NamedGroup, key: []const u8 },
    key_share_group: tls.NamedGroup,
};

fn serverHello(buf: []u8, random: [32]u8, session_id: []const u8, suite: tls.CipherSuite, exts: []const HelloExtension) ![]const u8 {
    var w: Writer = .fixed(buf);
    try w.writeByte(@backingInt(tls.HandshakeType.server_hello));
    try w.writeInt(u24, 0, .big);
    try w.writeInt(u16, 0x0303, .big);
    try w.writeAll(&random);
    try w.writeByte(@intCast(session_id.len));
    try w.writeAll(session_id);
    try w.writeInt(u16, @backingInt(suite), .big);
    try w.writeByte(0);
    const ext_len_at = w.end;
    try w.writeInt(u16, 0, .big);
    for (exts) |e| switch (e) {
        .supported_versions => try w.writeAll(&.{ 0x00, 0x2b, 0x00, 0x02, 0x03, 0x04 }),
        .key_share => |ks| {
            try w.writeInt(u16, @backingInt(tls.ExtensionType.key_share), .big);
            try w.writeInt(u16, @intCast(4 + ks.key.len), .big);
            try w.writeInt(u16, @backingInt(ks.group), .big);
            try w.writeInt(u16, @intCast(ks.key.len), .big);
            try w.writeAll(ks.key);
        },
        .key_share_group => |g| {
            try w.writeInt(u16, @backingInt(tls.ExtensionType.key_share), .big);
            try w.writeInt(u16, 2, .big);
            try w.writeInt(u16, @backingInt(g), .big);
        },
    };
    std.mem.writeInt(u16, buf[ext_len_at..][0..2], @intCast(w.end - ext_len_at - 2), .big);
    finishMessage(buf, 0, w.end);
    return w.buffered();
}

// ---- Application data -----------------------------------------------------------------------

pub fn eof(s: *const Server) bool {
    return s.received_close_notify;
}

fn stream(r: *Reader, w: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
    _ = w;
    _ = limit;
    const s: *Server = @alignCast(@fieldParentPtr("reader", r));
    return readRecord(s);
}

fn readVec(r: *Reader, data: [][]u8) Reader.Error!usize {
    _ = data;
    const s: *Server = @alignCast(@fieldParentPtr("reader", r));
    return readRecord(s);
}

fn failRead(s: *Server, err: ReadError) error{ReadFailed} {
    s.read_err = err;
    return error.ReadFailed;
}

/// Decrypts the next record into the reader's buffer. Returns 0 after handling records that
/// carry no application data (KeyUpdate, close_notify).
fn readRecord(s: *Server) Reader.Error!usize {
    if (s.received_close_notify) return error.EndOfStream;
    const r = &s.reader;
    // Make room for a full record at the end of the buffer.
    if (r.buffer.len - r.end < tls.max_ciphertext_len) {
        const data = r.buffer[r.seek..r.end];
        @memmove(r.buffer[0..data.len], data);
        r.seek = 0;
        r.end = data.len;
    }
    switch (s.cipher) {
        inline else => |*p| {
            const T = @TypeOf(p.*);
            const dest = r.buffer[r.end..];
            const opened = readSealed(T, s.input, p.client, &s.read_seq, dest) catch |err| return switch (err) {
                error.TlsConnectionTruncated => if (s.input.bufferedLen() == 0) error.EndOfStream else s.failRead(error.TlsConnectionTruncated),
                error.TlsBadRecordMac => s.failRead(error.TlsBadRecordMac),
                error.TlsRecordOverflow => s.failRead(error.TlsRecordOverflow),
                error.TlsDecodeError => s.failRead(error.TlsDecodeError),
                else => s.failRead(error.TlsUnexpectedMessage),
            };
            switch (opened.ct) {
                .application_data => {
                    r.end += opened.data.len;
                    return 0;
                },
                .alert => {
                    if (opened.data.len != 2) return s.failRead(error.TlsDecodeError);
                    if (opened.data[1] == @backingInt(tls.Alert.Description.close_notify)) {
                        s.received_close_notify = true;
                        return error.EndOfStream;
                    }
                    return s.failRead(error.TlsAlert);
                },
                .handshake => {
                    // Only KeyUpdate may follow the handshake (no tickets or client auth here).
                    var c: Cursor = .{ .b = opened.data };
                    while (!c.done()) {
                        const ht = c.int(u8) catch return s.failRead(error.TlsDecodeError);
                        const body = c.vec(u24) catch return s.failRead(error.TlsDecodeError);
                        if (ht != @backingInt(tls.HandshakeType.key_update) or body.len != 1) return s.failRead(error.TlsUnexpectedMessage);
                        p.client_secret = T.S.nextSecret(p.client_secret);
                        p.client = T.S.trafficKeys(T.Aead, p.client_secret);
                        s.read_seq = 0;
                        switch (body[0]) {
                            0 => {},
                            1 => {
                                // Answer with our own update, then switch our sending keys.
                                writeSealed(T, s.output, p.server, &s.write_seq, .handshake, &.{ @backingInt(tls.HandshakeType.key_update), 0, 0, 1, 0 }) catch return error.ReadFailed;
                                s.output.flush() catch return error.ReadFailed;
                                p.server_secret = T.S.nextSecret(p.server_secret);
                                p.server = T.S.trafficKeys(T.Aead, p.server_secret);
                                s.write_seq = 0;
                            },
                            else => return s.failRead(error.TlsDecodeError),
                        }
                    }
                    return 0;
                },
                else => return s.failRead(error.TlsUnexpectedMessage),
            }
        },
    }
}

fn seal(s: *Server, data: []const u8, ct: tls.ContentType) Writer.Error!void {
    if (data.len == 0) return;
    switch (s.cipher) {
        inline else => |*p| writeSealed(@TypeOf(p.*), s.output, p.server, &s.write_seq, ct, data) catch return error.WriteFailed,
    }
}

fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
    const s: *Server = @alignCast(@fieldParentPtr("writer", w));
    try s.seal(w.buffered(), .application_data);
    w.end = 0;
    var n: usize = 0;
    for (data[0 .. data.len - 1]) |d| {
        try s.seal(d, .application_data);
        n += d.len;
    }
    const last = data[data.len - 1];
    for (0..splat) |_| {
        try s.seal(last, .application_data);
        n += last.len;
    }
    return n;
}

/// Encrypts what is buffered and pushes it all the way to the socket.
fn flush(w: *Writer) Writer.Error!void {
    const s: *Server = @alignCast(@fieldParentPtr("writer", w));
    if (w.end > 0) {
        try s.seal(w.buffered(), .application_data);
        w.end = 0;
    }
    try s.output.flush();
}

/// Flushes and sends close_notify.
pub fn end(s: *Server) Writer.Error!void {
    try flush(&s.writer);
    try s.seal(&.{ 1, @backingInt(tls.Alert.Description.close_notify) }, .alert);
    try s.output.flush();
}

test {
    _ = keys;
    _ = certs;
    _ = @import("test.zig");
}
