//! ACME client (RFC 8555) for Let's Encrypt: account, order, HTTP-01 challenge, CSR, chain
//! download. `Manager` keeps a certificate on disk, renews it when it gets within 30 days of
//! expiring, and swaps it into the running server.
//!
//! HTTP-01 means Let's Encrypt fetches http://<name>/.well-known/acme-challenge/<token>, so the
//! app also serves port 80 with `challengeHandler` (which redirects everything else to HTTPS).

const std = @import("std");
const Io = std.Io;
const certs = @import("cert.zig");

pub const lets_encrypt = "https://acme-v02.api.letsencrypt.org/directory";
pub const lets_encrypt_staging = "https://acme-staging-v02.api.letsencrypt.org/directory";

const b64 = std.base64.url_safe_no_pad;

/// Key authorizations Let's Encrypt will ask for, by token. Shared with the port-80 handler.
pub const Challenges = struct {
    mutex: Io.Mutex = .init,
    gpa: std.mem.Allocator,
    map: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn put(c: *Challenges, io: Io, token: []const u8, key_auth: []const u8) !void {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        try c.map.put(c.gpa, try c.gpa.dupe(u8, token), try c.gpa.dupe(u8, key_auth));
    }

    pub fn remove(c: *Challenges, io: Io, token: []const u8) void {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        if (c.map.fetchRemove(token)) |kv| {
            c.gpa.free(kv.key);
            c.gpa.free(kv.value);
        }
    }

    /// Copies the key authorization for `token` into `buf`.
    pub fn get(c: *Challenges, io: Io, token: []const u8, buf: []u8) ?[]const u8 {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        const v = c.map.get(token) orelse return null;
        if (v.len > buf.len) return null;
        @memcpy(buf[0..v.len], v);
        return buf[0..v.len];
    }
};

/// JWK of a P-256 public key, in the member order RFC 7638 requires for the thumbprint.
fn jwk(buf: []u8, key: certs.Ecdsa.PublicKey) ![]const u8 {
    const sec1 = key.toUncompressedSec1();
    var x: [43]u8 = undefined;
    var y: [43]u8 = undefined;
    return std.fmt.bufPrint(buf, "{{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"{s}\",\"y\":\"{s}\"}}", .{ b64.Encoder.encode(&x, sec1[1..33]), b64.Encoder.encode(&y, sec1[33..65]) });
}

/// The account key's JWK thumbprint (RFC 7638), part of every key authorization.
pub fn thumbprint(key: certs.Ecdsa.PublicKey) [43]u8 {
    var buf: [160]u8 = undefined;
    const j = jwk(&buf, key) catch unreachable;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(j, &digest, .{});
    var out: [43]u8 = undefined;
    _ = b64.Encoder.encode(&out, &digest);
    return out;
}

/// A flattened JWS (RFC 7515) signed with ES256, identifying the account by `kid` or, before the
/// account exists, by its JWK.
pub fn jws(a: std.mem.Allocator, key: certs.KeyPair, kid: ?[]const u8, nonce: []const u8, url: []const u8, payload: []const u8) ![]const u8 {
    var jwk_buf: [160]u8 = undefined;
    const protected = if (kid) |k|
        try std.fmt.allocPrint(a, "{{\"alg\":\"ES256\",\"kid\":\"{s}\",\"nonce\":\"{s}\",\"url\":\"{s}\"}}", .{ k, nonce, url })
    else
        try std.fmt.allocPrint(a, "{{\"alg\":\"ES256\",\"jwk\":{s},\"nonce\":\"{s}\",\"url\":\"{s}\"}}", .{ try jwk(&jwk_buf, key.public_key), nonce, url });
    const p64 = try a.alloc(u8, b64.Encoder.calcSize(protected.len));
    _ = b64.Encoder.encode(p64, protected);
    const body64 = try a.alloc(u8, b64.Encoder.calcSize(payload.len));
    _ = b64.Encoder.encode(body64, payload);
    const signing_input = try std.fmt.allocPrint(a, "{s}.{s}", .{ p64, body64 });
    // JWS wants the raw 64-byte r||s, not DER.
    const sig = try key.sign(signing_input, null);
    var sig64: [86]u8 = undefined;
    return std.fmt.allocPrint(a, "{{\"protected\":\"{s}\",\"payload\":\"{s}\",\"signature\":\"{s}\"}}", .{ p64, body64, b64.Encoder.encode(&sig64, &sig.toBytes()) });
}

const Reply = struct {
    status: std.http.Status,
    location: ?[]const u8,
    body: []const u8,
};

pub const Client = struct {
    io: Io,
    gpa: std.mem.Allocator,
    http: std.http.Client,
    directory_url: []const u8,
    account_key: certs.KeyPair,
    contact_email: ?[]const u8,
    challenges: *Challenges,
    kid: ?[]const u8 = null,
    nonce: ?[]const u8 = null,
    new_nonce: []const u8 = "",
    new_account: []const u8 = "",
    new_order: []const u8 = "",

    pub fn init(io: Io, gpa: std.mem.Allocator, directory_url: []const u8, account_key: certs.KeyPair, contact_email: ?[]const u8, challenges: *Challenges) Client {
        return .{ .io = io, .gpa = gpa, .http = .{ .allocator = gpa, .io = io }, .directory_url = directory_url, .account_key = account_key, .contact_email = contact_email, .challenges = challenges };
    }

    pub fn deinit(c: *Client) void {
        c.http.deinit();
        if (c.kid) |k| c.gpa.free(k);
        for ([_][]const u8{ c.new_nonce, c.new_account, c.new_order }) |u| if (u.len > 0) c.gpa.free(u);
    }

    fn send(c: *Client, a: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?[]const u8) !Reply {
        var req = try c.http.request(method, try std.Uri.parse(url), .{
            .extra_headers = &.{.{ .name = "content-type", .value = "application/jose+json" }},
            .redirect_behavior = .unhandled,
            .keep_alive = true,
        });
        defer req.deinit();
        if (body) |b| {
            req.transfer_encoding = .{ .content_length = b.len };
            var w = try req.sendBodyUnflushed(&.{});
            try w.writer.writeAll(b);
            try w.end();
            try req.connection.?.flush();
        } else try req.sendBodiless();

        var response = try req.receiveHead(&.{});
        var location: ?[]const u8 = null;
        var it = response.head.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "replay-nonce")) c.nonce = try a.dupe(u8, h.value);
            if (std.ascii.eqlIgnoreCase(h.name, "location")) location = try a.dupe(u8, h.value);
        }
        const status = response.head.status;
        var transfer: [64]u8 = undefined;
        const out = try response.reader(&transfer).allocRemaining(a, .limited(1 << 20));
        return .{ .status = status, .location = location, .body = out };
    }

    /// A signed POST. `payload` "" is a POST-as-GET. Retries once on a stale nonce.
    pub fn post(c: *Client, a: std.mem.Allocator, url: []const u8, payload: []const u8) !Reply {
        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            if (c.nonce == null) _ = try c.send(a, .HEAD, c.new_nonce, null);
            const body = try jws(a, c.account_key, c.kid, c.nonce.?, url, payload);
            c.nonce = null;
            const r = try c.send(a, .POST, url, body);
            if (r.status == .bad_request and attempt == 0 and std.mem.indexOf(u8, r.body, "badNonce") != null) continue;
            if (@backingInt(r.status) >= 400) {
                std.log.err("acme {s}: {d} {s}", .{ url, @backingInt(r.status), r.body });
                return error.AcmeRequestFailed;
            }
            return r;
        }
    }

    pub fn setUp(c: *Client, a: std.mem.Allocator) !void {
        if (c.new_order.len > 0) return;
        const r = try c.send(a, .GET, c.directory_url, null);
        const Dir = struct { newNonce: []const u8, newAccount: []const u8, newOrder: []const u8 };
        const d = try std.json.parseFromSliceLeaky(Dir, a, r.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        c.new_nonce = try c.gpa.dupe(u8, d.newNonce);
        c.new_account = try c.gpa.dupe(u8, d.newAccount);
        c.new_order = try c.gpa.dupe(u8, d.newOrder);

        const payload = if (c.contact_email) |e|
            try std.fmt.allocPrint(a, "{{\"termsOfServiceAgreed\":true,\"contact\":[\"mailto:{s}\"]}}", .{e})
        else
            "{\"termsOfServiceAgreed\":true}";
        const acc = try c.post(a, c.new_account, payload);
        c.kid = try c.gpa.dupe(u8, acc.location orelse return error.AcmeNoAccountUrl);
    }

    /// Gets a certificate for `names` (first one is the subject) for `cert_key`. Returns the PEM
    /// chain. The HTTP-01 answers must be reachable on port 80 for every name while this runs.
    pub fn obtain(c: *Client, a: std.mem.Allocator, names: []const []const u8, cert_key: certs.KeyPair) ![]const u8 {
        try c.setUp(a);

        var ids: std.ArrayList(u8) = .empty;
        for (names, 0..) |n, i| try ids.print(a, "{s}{{\"type\":\"dns\",\"value\":\"{s}\"}}", .{ if (i > 0) "," else "", n });
        const order_reply = try c.post(a, c.new_order, try std.fmt.allocPrint(a, "{{\"identifiers\":[{s}]}}", .{ids.items}));
        const order_url = order_reply.location orelse return error.AcmeNoOrderUrl;
        const Order = struct { status: []const u8, authorizations: []const []const u8 = &.{}, finalize: []const u8 = "", certificate: ?[]const u8 = null };
        var order = try std.json.parseFromSliceLeaky(Order, a, order_reply.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });

        const thumb = thumbprint(c.account_key.public_key);
        var tokens: std.ArrayList([]const u8) = .empty;
        defer for (tokens.items) |t| c.challenges.remove(c.io, t);

        for (order.authorizations) |authz_url| {
            const Authz = struct { status: []const u8, challenges: []const struct { type: []const u8, url: []const u8, token: []const u8 = "" } = &.{} };
            const az = try std.json.parseFromSliceLeaky(Authz, a, (try c.post(a, authz_url, "")).body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
            if (std.mem.eql(u8, az.status, "valid")) continue;
            const ch = for (az.challenges) |ch| {
                if (std.mem.eql(u8, ch.type, "http-01")) break ch;
            } else return error.AcmeNoHttpChallenge;
            try c.challenges.put(c.io, ch.token, try std.fmt.allocPrint(a, "{s}.{s}", .{ ch.token, thumb }));
            try tokens.append(a, ch.token);
            _ = try c.post(a, ch.url, "{}");
            try c.waitFor(a, authz_url, "valid");
        }

        const der = try certs.csr(a, cert_key, names);
        const csr64 = try a.alloc(u8, b64.Encoder.calcSize(der.len));
        _ = b64.Encoder.encode(csr64, der);
        _ = try c.post(a, order.finalize, try std.fmt.allocPrint(a, "{{\"csr\":\"{s}\"}}", .{csr64}));

        var tries: u32 = 0;
        while (order.certificate == null) : (tries += 1) {
            if (tries > 30) return error.AcmeTimeout;
            try c.io.sleep(.fromSeconds(2), .awake);
            order = try std.json.parseFromSliceLeaky(Order, a, (try c.post(a, order_url, "")).body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
            if (std.mem.eql(u8, order.status, "invalid")) return error.AcmeOrderInvalid;
        }
        return (try c.post(a, order.certificate.?, "")).body;
    }

    /// Polls a resource (POST-as-GET) until its status is `want`.
    fn waitFor(c: *Client, a: std.mem.Allocator, url: []const u8, want: []const u8) !void {
        const S = struct { status: []const u8 };
        for (0..30) |_| {
            const s = try std.json.parseFromSliceLeaky(S, a, (try c.post(a, url, "")).body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
            if (std.mem.eql(u8, s.status, want)) return;
            if (std.mem.eql(u8, s.status, "invalid")) return error.AcmeChallengeFailed;
            try c.io.sleep(.fromSeconds(2), .awake);
        }
        return error.AcmeTimeout;
    }
};

/// Keeps `<dir>/chain.pem` and `<dir>/key.pem` valid for `names`, renewing within 30 days of
/// expiry, and publishes each new certificate to `store`.
pub const Manager = struct {
    io: Io,
    gpa: std.mem.Allocator,
    dir: []const u8,
    names: []const []const u8,
    directory_url: []const u8 = lets_encrypt,
    contact_email: ?[]const u8 = null,
    challenges: *Challenges,
    store: *certs.CertStore,

    const renew_before: i64 = 30 * 86400;

    /// The certificate on disk, if there is one, otherwise a new one from ACME. Call before
    /// serving HTTPS (port 80 must already be answering challenges).
    pub fn ensure(m: *Manager) !void {
        const arena = std.heap.ArenaAllocator.init(m.gpa);
        // Certificates stay alive for open connections; the arena is never freed (see CertStore).
        var keep = arena;
        const a = keep.allocator();
        if (m.load(a)) |cert| {
            const now = Io.Timestamp.now(m.io, .real).toSeconds();
            if (@as(i64, @intCast(cert.notAfter())) - now > renew_before) {
                m.store.set(m.io, try a.dupe(certs.Certificate, &.{cert}));
                return;
            }
        } else |_| {}
        try m.renew(a);
    }

    fn load(m: *Manager, a: std.mem.Allocator) !certs.Certificate {
        const cwd = Io.Dir.cwd();
        const chain = try cwd.readFileAlloc(m.io, try std.fs.path.join(a, &.{ m.dir, "chain.pem" }), a, .limited(1 << 20));
        const key = try cwd.readFileAlloc(m.io, try std.fs.path.join(a, &.{ m.dir, "key.pem" }), a, .limited(1 << 20));
        return certs.loadPem(a, chain, key);
    }

    fn renew(m: *Manager, a: std.mem.Allocator) !void {
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(m.io, m.dir);
        const account_path = try std.fs.path.join(a, &.{ m.dir, "account.pem" });
        const account_key = if (cwd.readFileAlloc(m.io, account_path, a, .limited(1 << 16))) |pem|
            try certs.loadKeyPem(a, pem)
        else |_| blk: {
            const k = certs.KeyPair.generate(m.io);
            try writeKey(m.io, a, account_path, k);
            break :blk k;
        };

        var client = Client.init(m.io, m.gpa, m.directory_url, account_key, m.contact_email, m.challenges);
        defer client.deinit();
        const cert_key = certs.KeyPair.generate(m.io);
        const chain = try client.obtain(a, m.names, cert_key);

        // Key first, then chain: a crash in between leaves a key that matches nothing, which
        // `load` rejects, rather than a chain without its key.
        try writeKey(m.io, a, try std.fs.path.join(a, &.{ m.dir, "key.pem" }), cert_key);
        try cwd.writeFile(m.io, .{ .sub_path = try std.fs.path.join(a, &.{ m.dir, "chain.pem" }), .data = chain });
        const cert = try certs.loadPem(a, chain, (try cwd.readFileAlloc(m.io, try std.fs.path.join(a, &.{ m.dir, "key.pem" }), a, .limited(1 << 16))));
        m.store.set(m.io, try a.dupe(certs.Certificate, &.{cert}));
        std.log.info("certificate for {s} renewed, valid until {d}", .{ m.names[0], cert.notAfter() });
    }

    fn writeKey(io: Io, a: std.mem.Allocator, path: []const u8, key: certs.KeyPair) !void {
        var out: std.Io.Writer.Allocating = .init(a);
        try certs.writeKeyPem(&out.writer, a, key);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
    }

    /// Checks twice a day and renews when due. Run as its own task.
    pub fn renewLoop(m: *Manager) void {
        while (true) {
            m.io.sleep(.fromSeconds(12 * 3600), .awake) catch return;
            m.ensure() catch |err| std.log.err("certificate renewal for {s}: {t}", .{ m.names[0], err });
        }
    }
};

const testing = std.testing;

test "JWS is ES256 over protected.payload and verifies with the account key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = certs.KeyPair.generate(testing.io);
    const out = try jws(a, key, null, "nonce-1", "https://acme.test/new-account", "{\"termsOfServiceAgreed\":true}");
    const J = struct { protected: []const u8, payload: []const u8, signature: []const u8 };
    const j = try std.json.parseFromSliceLeaky(J, a, out, .{});

    var protected_buf: [512]u8 = undefined;
    const protected = protected_buf[0..try b64.Decoder.calcSizeForSlice(j.protected)];
    try b64.Decoder.decode(protected, j.protected);
    try testing.expect(std.mem.indexOf(u8, protected, "\"alg\":\"ES256\"") != null);
    try testing.expect(std.mem.indexOf(u8, protected, "\"jwk\":{\"crv\":\"P-256\",\"kty\":\"EC\"") != null);

    var sig: [64]u8 = undefined;
    try b64.Decoder.decode(&sig, j.signature);
    const signing_input = try std.fmt.allocPrint(a, "{s}.{s}", .{ j.protected, j.payload });
    try certs.Ecdsa.Signature.fromBytes(sig).verify(signing_input, key.public_key);
}

test "thumbprint is the base64url SHA-256 of the canonical JWK" {
    const key = certs.KeyPair.generate(testing.io);
    var buf: [160]u8 = undefined;
    const j = try jwk(&buf, key.public_key);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(j, &digest, .{});
    var expected: [43]u8 = undefined;
    _ = b64.Encoder.encode(&expected, &digest);
    try testing.expectEqual(expected, thumbprint(key.public_key));
    // Members in lexicographic order, no whitespace (RFC 7638 section 3).
    try testing.expect(std.mem.startsWith(u8, j, "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\""));
}
