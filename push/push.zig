//! Sending push notifications from a server, with std only:
//! - Web Push (RFC 8030) with message encryption (RFC 8291, aes128gcm) and VAPID (RFC 8292),
//!   for the web apps;
//! - Firebase Cloud Messaging HTTP v1 for Android: a service account's RS256-signed JWT is
//!   exchanged for an access token (RSA signing is here, since std only verifies RSA);
//! - APNs for iOS: an ES256 provider token, sent over HTTP/2 (apns.zig on h2.zig, hpack.zig and
//!   tls_client.zig, which is std's TLS client with ALPN added).
//!
//! Each send returns the push service's status so callers can drop subscriptions that are gone
//! (404 / 410).

const std = @import("std");
pub const rsa = @import("rsa.zig");
pub const jwt = @import("jwt.zig");
pub const hpack = @import("hpack.zig");
pub const h2 = @import("h2.zig");
pub const tls_client = @import("tls_client.zig");
pub const apns = @import("apns.zig");

const P256 = std.crypto.ecc.P256;
const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
const b64url = std.base64.url_safe_no_pad;

// ---- Web Push message encryption (RFC 8291) ------------------------------------------------

pub const Subscription = struct {
    endpoint: []const u8,
    /// The browser's P-256 public key, base64url (65 bytes uncompressed).
    p256dh: []const u8,
    /// base64url, 16 bytes.
    auth: []const u8,
};

/// Fixed inputs for tests; real sends draw them at random.
pub const Ephemeral = struct { private_key: [32]u8, salt: [16]u8 };

/// The aes128gcm body for `plaintext` (a single record): salt, record size, the sender's
/// public key, then the ciphertext.
pub fn encrypt(gpa: std.mem.Allocator, io: std.Io, sub: Subscription, plaintext: []const u8, fixed: ?Ephemeral) ![]u8 {
    var ua_public: [65]u8 = undefined;
    if ((b64url.Decoder.calcSizeForSlice(sub.p256dh) catch return error.BadKey) != 65) return error.BadKey;
    try b64url.Decoder.decode(&ua_public, sub.p256dh);
    var auth: [16]u8 = undefined;
    if ((b64url.Decoder.calcSizeForSlice(sub.auth) catch return error.BadKey) != 16) return error.BadKey;
    try b64url.Decoder.decode(&auth, sub.auth);

    // A fresh key pair and salt per message.
    var as_private: [32]u8 = undefined;
    var salt: [16]u8 = undefined;
    if (fixed) |f| {
        as_private = f.private_key;
        salt = f.salt;
    } else {
        io.random(&as_private);
        io.random(&salt);
    }
    const as_scalar = try P256.scalar.Scalar.fromBytes(as_private, .big);
    const as_public = (try P256.basePoint.mul(as_scalar.toBytes(.big), .big)).toUncompressedSec1();
    const ua_point = try P256.fromSec1(&ua_public);
    const shared = (try ua_point.mul(as_scalar.toBytes(.big), .big)).affineCoordinates().x.toBytes(.big);

    // IKM = HKDF(auth, ecdh, "WebPush: info" || 0 || ua_public || as_public)
    const prk_key = HkdfSha256.extract(&auth, &shared);
    var key_info: [14 + 65 + 65]u8 = undefined;
    @memcpy(key_info[0..14], "WebPush: info\x00");
    @memcpy(key_info[14..79], &ua_public);
    @memcpy(key_info[79..144], &as_public);
    var ikm: [32]u8 = undefined;
    HkdfSha256.expand(&ikm, &key_info, prk_key);

    const prk = HkdfSha256.extract(&salt, &ikm);
    var cek: [16]u8 = undefined;
    HkdfSha256.expand(&cek, "Content-Encoding: aes128gcm\x00", prk);
    var nonce: [12]u8 = undefined;
    HkdfSha256.expand(&nonce, "Content-Encoding: nonce\x00", prk);

    // Header (salt, rs = 4096, idlen, keyid) + ciphertext of plaintext || 0x02 + tag.
    const header_len = 16 + 4 + 1 + 65;
    const out = try gpa.alloc(u8, header_len + plaintext.len + 1 + 16);
    errdefer gpa.free(out);
    @memcpy(out[0..16], &salt);
    std.mem.writeInt(u32, out[16..20], 4096, .big);
    out[20] = 65;
    @memcpy(out[21..86], &as_public);
    const padded = try gpa.alloc(u8, plaintext.len + 1);
    defer gpa.free(padded);
    @memcpy(padded[0..plaintext.len], plaintext);
    padded[plaintext.len] = 0x02; // the last (and only) record
    const ct = out[header_len..][0..padded.len];
    var tag: [16]u8 = undefined;
    Aes128Gcm.encrypt(ct, &tag, padded, "", nonce, cek);
    @memcpy(out[header_len + padded.len ..], &tag);
    return out;
}

// ---- VAPID (RFC 8292) ----------------------------------------------------------------------

pub const Vapid = struct {
    /// The server's P-256 key pair, base64url (as the VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY
    /// variables of the Node apps hold them).
    public_key: []const u8,
    private_key: []const u8,
    /// "mailto:..." or "https://...".
    subject: []const u8,
};

/// The `aud` claim for `endpoint`: its origin (`new URL(endpoint).origin`), which keeps a port
/// other than the scheme's default.
pub fn audience(gpa: std.mem.Allocator, endpoint: []const u8) ![]u8 {
    const uri = try std.Uri.parse(endpoint);
    const host = (uri.host orelse return error.BadEndpoint).percent_encoded;
    const default_port: u16 = if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) 80 else 443;
    const out = if (uri.port) |p| (if (p != default_port)
        try std.fmt.allocPrint(gpa, "{s}://{s}:{d}", .{ uri.scheme, host, p })
    else
        null) else null;
    const origin = out orelse try std.fmt.allocPrint(gpa, "{s}://{s}", .{ uri.scheme, host });
    _ = std.ascii.lowerString(origin, origin);
    return origin;
}

/// The Authorization header value for a push to `endpoint`: "vapid t=<jwt>, k=<public key>".
pub fn vapidHeader(gpa: std.mem.Allocator, v: Vapid, endpoint: []const u8, now_s: i64) ![]u8 {
    const aud = try audience(gpa, endpoint);
    defer gpa.free(aud);
    const claims = try std.fmt.allocPrint(gpa, "{{\"aud\":{f},\"exp\":{d},\"sub\":{f}}}", .{ std.json.fmt(aud, .{}), now_s + 12 * 3600, std.json.fmt(v.subject, .{}) });
    defer gpa.free(claims);
    var key: [32]u8 = undefined;
    try b64url.Decoder.decode(&key, v.private_key);
    const token = try jwt.es256(gpa, claims, key);
    defer gpa.free(token);
    return std.fmt.allocPrint(gpa, "vapid t={s}, k={s}", .{ token, v.public_key });
}

/// Sends one Web Push message. Returns the push service's HTTP status (201 = accepted;
/// 404/410 = the subscription is gone).
pub fn sendWebPush(client: *std.http.Client, gpa: std.mem.Allocator, v: Vapid, sub: Subscription, payload: []const u8, ttl_s: u32, now_s: i64) !std.http.Status {
    const body = try encrypt(gpa, client.io, sub, payload, null);
    defer gpa.free(body);
    const auth = try vapidHeader(gpa, v, sub.endpoint, now_s);
    defer gpa.free(auth);
    var ttl_buf: [16]u8 = undefined;
    return post(client, sub.endpoint, body, &.{
        .{ .name = "content-encoding", .value = "aes128gcm" },
        .{ .name = "content-type", .value = "application/octet-stream" },
        .{ .name = "ttl", .value = try std.fmt.bufPrint(&ttl_buf, "{d}", .{ttl_s}) },
        .{ .name = "urgency", .value = "high" },
        .{ .name = "authorization", .value = auth },
    }, null);
}

fn post(client: *std.http.Client, url: []const u8, body: []const u8, headers: []const std.http.Header, response: ?*std.ArrayList(u8)) !std.http.Status {
    var req = try client.request(.POST, try std.Uri.parse(url), .{ .extra_headers = headers, .keep_alive = true, .headers = .{ .accept_encoding = .omit } });
    defer req.deinit();
    req.transfer_encoding = .{ .content_length = body.len };
    var w = try req.sendBodyUnflushed(&.{});
    try w.writer.writeAll(body);
    try w.end();
    try req.connection.?.flush();
    var res = try req.receiveHead(&.{});
    var transfer: [64]u8 = undefined;
    const r = res.reader(&transfer);
    if (response) |out| {
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = r.readSliceShort(&tmp) catch break;
            if (n == 0) break;
            try out.appendSlice(client.allocator, tmp[0..n]);
            if (n < tmp.len) break;
        }
    } else _ = r.discardRemaining() catch {};
    return res.head.status;
}

// ---- Firebase Cloud Messaging HTTP v1 ------------------------------------------------------

pub const ServiceAccount = struct {
    project_id: []const u8,
    client_email: []const u8,
    /// PEM, "-----BEGIN PRIVATE KEY-----" (PKCS#8 RSA), as in the downloaded JSON file.
    private_key: []const u8,
    token_uri: []const u8 = "https://oauth2.googleapis.com/token",
};

/// The signed assertion exchanged at Google's token endpoint for an access token (valid one
/// hour; cache it).
pub fn fcmAssertion(gpa: std.mem.Allocator, sa: ServiceAccount, now_s: i64) ![]u8 {
    const claims = try std.fmt.allocPrint(gpa, "{{\"iss\":{f},\"scope\":\"https://www.googleapis.com/auth/firebase.messaging\",\"aud\":{f},\"iat\":{d},\"exp\":{d}}}", .{
        std.json.fmt(sa.client_email, .{}), std.json.fmt(sa.token_uri, .{}), now_s, now_s + 3600,
    });
    defer gpa.free(claims);
    const key = try rsa.PrivateKey.fromPem(gpa, sa.private_key);
    defer key.deinit(gpa);
    return jwt.rs256(gpa, claims, key);
}

/// An access token for FCM, from the service account. Caller frees.
pub fn fcmAccessToken(client: *std.http.Client, gpa: std.mem.Allocator, sa: ServiceAccount, now_s: i64) ![]u8 {
    const assertion = try fcmAssertion(gpa, sa, now_s);
    defer gpa.free(assertion);
    const body = try std.fmt.allocPrint(gpa, "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion={s}", .{assertion});
    defer gpa.free(body);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const status = try post(client, sa.token_uri, body, &.{.{ .name = "content-type", .value = "application/x-www-form-urlencoded" }}, &out);
    if (status != .ok) return error.TokenRefused;
    const parsed = try std.json.parseFromSlice(struct { access_token: []const u8 }, gpa, out.items, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return gpa.dupe(u8, parsed.value.access_token);
}

/// Sends a data message (the app decides what to show: a call rings, a dispatch alarm…) to
/// one device. `data_json` is a JSON object of string values. High priority wakes the phone.
pub fn sendFcm(client: *std.http.Client, gpa: std.mem.Allocator, project_id: []const u8, access_token: []const u8, device_token: []const u8, data_json: []const u8) !std.http.Status {
    const url = try std.fmt.allocPrint(gpa, "https://fcm.googleapis.com/v1/projects/{s}/messages:send", .{project_id});
    defer gpa.free(url);
    const body = try std.fmt.allocPrint(gpa, "{{\"message\":{{\"token\":{f},\"data\":{s},\"android\":{{\"priority\":\"high\"}}}}}}", .{ std.json.fmt(device_token, .{}), data_json });
    defer gpa.free(body);
    const auth = try std.fmt.allocPrint(gpa, "Bearer {s}", .{access_token});
    defer gpa.free(auth);
    return post(client, url, body, &.{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "authorization", .value = auth },
    }, null);
}

// ---- APNs provider token -------------------------------------------------------------------

/// The ES256 provider token APNs takes in "authorization: bearer <token>" (renew hourly).
/// `key` is the raw 32-byte P-256 private key from the .p8 file (see jwt.p8PrivateKey).
pub fn apnsToken(gpa: std.mem.Allocator, team_id: []const u8, key_id: []const u8, key: [32]u8, now_s: i64) ![]u8 {
    const claims = try std.fmt.allocPrint(gpa, "{{\"iss\":{f},\"iat\":{d}}}", .{ std.json.fmt(team_id, .{}), now_s });
    defer gpa.free(claims);
    return jwt.es256WithKid(gpa, claims, key, key_id);
}

const testing = std.testing;

test "RFC 8291 example: the same bytes" {
    const b = struct {
        fn dec(comptime n: usize, s: []const u8) [n]u8 {
            var out: [n]u8 = undefined;
            b64url.Decoder.decode(&out, s) catch unreachable;
            return out;
        }
    };
    const body = try encrypt(testing.allocator, undefined, .{
        .endpoint = "https://push.example.net/push/JzLQ3raZJfFBR0aqvOMsLrt54w4rJUsV",
        .p256dh = "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
        .auth = "BTBZMqHH6r4Tts7J_aSIgg",
    }, "When I grow up, I want to be a watermelon", .{
        .private_key = b.dec(32, "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"),
        .salt = b.dec(16, "DGv6ra1nlYgDCS1FRnbzlw"),
    });
    defer testing.allocator.free(body);
    // 144 bytes (the RFC's "Content-Length: 145" is one too many; its base64 is 144).
    var expected: [144]u8 = undefined;
    try b64url.Decoder.decode(&expected, "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN");
    try testing.expectEqualSlices(u8, &expected, body);
}

test "VAPID header verifies with the public key" {
    // A key pair made here; the token's signature must check out against its public half.
    const kp = try EcdsaP256.KeyPair.generateDeterministic(@splat(7));
    var pub_buf: [65]u8 = kp.public_key.toUncompressedSec1();
    var pub_b64: [87]u8 = undefined;
    _ = b64url.Encoder.encode(&pub_b64, &pub_buf);
    var priv_b64: [43]u8 = undefined;
    _ = b64url.Encoder.encode(&priv_b64, &kp.secret_key.toBytes());
    const header = try vapidHeader(testing.allocator, .{ .public_key = &pub_b64, .private_key = &priv_b64, .subject = "mailto:ops@wufour.com" }, "https://fcm.googleapis.com/fcm/send/abc", 1_800_000_000);
    defer testing.allocator.free(header);
    try testing.expect(std.mem.startsWith(u8, header, "vapid t=ey"));
    const t_end = std.mem.indexOf(u8, header, ", k=").?;
    try jwt.verifyEs256(header["vapid t=".len..t_end], kp.public_key);
    try testing.expect(std.mem.endsWith(u8, header, &pub_b64));
}

test "VAPID audience is the endpoint's origin, port included" {
    const cases = [_][2][]const u8{
        .{ "https://fcm.googleapis.com/fcm/send/abc", "https://fcm.googleapis.com" },
        .{ "https://Push.Example:8443/x?y", "https://push.example:8443" },
        .{ "https://push.example:443/x", "https://push.example" },
        .{ "http://127.0.0.1:5005/push", "http://127.0.0.1:5005" },
    };
    for (cases) |c| {
        const aud = try audience(testing.allocator, c[0]);
        defer testing.allocator.free(aud);
        try testing.expectEqualStrings(c[1], aud);
    }
}

test {
    _ = rsa;
    _ = jwt;
    _ = hpack;
    _ = h2;
    _ = apns;
}
