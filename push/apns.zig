//! Apple Push Notification service: token-based (.p8 key) sends over HTTP/2.
//!
//! `Client` keeps one long-lived connection per environment, as Apple asks, and reconnects when
//! APNs closes it. The provider token (an ES256 JWT) is cached for 50 minutes: APNs refuses
//! tokens older than an hour and answers TooManyProviderTokenUpdates when they change more
//! often than every 20 minutes. `send` is the one-shot form; it shares the token cache.

const std = @import("std");
const h2 = @import("h2.zig");
const jwt = @import("jwt.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Environment = enum {
    production,
    /// Development builds (Xcode, or the aps-environment "development" entitlement).
    sandbox,

    pub fn host(e: Environment) []const u8 {
        return switch (e) {
            .production => "api.push.apple.com",
            .sandbox => "api.sandbox.push.apple.com",
        };
    }
};

pub const PushType = enum { alert, background, voip };

pub const Credentials = struct {
    /// The 10-character Team ID.
    team_id: []const u8,
    /// The 10-character id of the .p8 key.
    key_id: []const u8,
    /// The .p8 file's contents (PEM, "-----BEGIN PRIVATE KEY-----", P-256).
    private_key: []const u8,
    /// The app's bundle id; the topic (VoIP pushes add ".voip").
    bundle_id: []const u8,
};

pub const Options = struct {
    environment: Environment = .production,
    push_type: PushType = .alert,
    /// 10 = now, 5 = when convenient for the device's power. Default: 10, but 5 for
    /// background pushes (Apple requires it).
    priority: ?u8 = null,
    /// Unix seconds after which APNs stops trying; 0 = deliver now or never. Default: APNs
    /// stores the push for a while.
    expiration: ?i64 = null,
    /// Later pushes with the same id replace this one on the device (64 bytes at most).
    collapse_id: ?[]const u8 = null,
};

pub const Result = struct {
    /// 200 = accepted. 400 BadDeviceToken / 410 Unregistered: drop the token (see `tokenGone`).
    status: u16,
    apns_id_buf: [36]u8 = undefined,
    apns_id_len: u8 = 0,
    reason_buf: [64]u8 = undefined,
    reason_len: u8 = 0,
    /// For 410: when APNs last knew the token was valid, milliseconds since the epoch.
    timestamp_ms: ?i64 = null,

    /// The id APNs gave the push (a UUID), "" if none.
    pub fn apnsId(r: *const Result) []const u8 {
        return r.apns_id_buf[0..r.apns_id_len];
    }

    /// The error reason from the body ("BadDeviceToken", "Unregistered"...), "" on success.
    pub fn reason(r: *const Result) []const u8 {
        return r.reason_buf[0..r.reason_len];
    }

    /// Whether the device token is no longer any good and should be deleted.
    pub fn tokenGone(r: *const Result) bool {
        return r.status == 410 or (r.status == 400 and std.mem.eql(u8, r.reason(), "BadDeviceToken"));
    }
};

// ---- Provider token cache ------------------------------------------------------------------

/// Refresh well before APNs' one-hour limit, and never sooner than its 20-minute minimum.
pub const token_lifetime_s = 50 * 60;

/// One token per process (a server has one key); keyed by team and key id.
const TokenCache = struct {
    mutex: Io.Mutex = .init,
    buf: [512]u8 = undefined,
    len: usize = 0,
    iat: i64 = 0,
    owner_buf: [64]u8 = undefined,
    owner_len: usize = 0,
};
var token_cache: TokenCache = .{};

/// Copies the current provider token into `out`, making a new one when it is missing, older
/// than `token_lifetime_s`, or `stale` (APNs said it expired).
fn providerToken(gpa: Allocator, io: Io, creds: Credentials, key: [32]u8, now_s: i64, stale: ?[]const u8, out: []u8) ![]const u8 {
    const t = &token_cache;
    t.mutex.lockUncancelable(io);
    defer t.mutex.unlock(io);
    var owner_buf: [64]u8 = undefined;
    const owner = std.fmt.bufPrint(&owner_buf, "{s}.{s}", .{ creds.team_id, creds.key_id }) catch return error.BadCredentials;
    const cached = t.buf[0..t.len];
    const fresh = t.len > 0 and std.mem.eql(u8, t.owner_buf[0..t.owner_len], owner) and
        now_s - t.iat < token_lifetime_s and now_s >= t.iat and
        !(if (stale) |s| std.mem.eql(u8, s, cached) else false);
    if (!fresh) {
        const claims = try std.fmt.allocPrint(gpa, "{{\"iss\":{f},\"iat\":{d}}}", .{ std.json.fmt(creds.team_id, .{}), now_s });
        defer gpa.free(claims);
        const token = try jwt.es256WithKid(gpa, claims, key, creds.key_id);
        defer gpa.free(token);
        if (token.len > t.buf.len) return error.BadCredentials;
        @memcpy(t.buf[0..token.len], token);
        t.len = token.len;
        t.iat = now_s;
        @memcpy(t.owner_buf[0..owner.len], owner);
        t.owner_len = owner.len;
    }
    if (t.len > out.len) return error.BadCredentials;
    @memcpy(out[0..t.len], t.buf[0..t.len]);
    return out[0..t.len];
}

// ---- Client --------------------------------------------------------------------------------

/// Sends pushes on long-lived connections. One sender at a time: guard it with a mutex if it
/// is shared between tasks.
pub const Client = struct {
    gpa: Allocator,
    io: Io,
    creds: Credentials,
    key: [32]u8,
    conns: [2]?*h2.Connection = .{ null, null },
    /// For tests against a local server: the host, port and trust used instead of Apple's.
    host_override: ?[]const u8 = null,
    port: u16 = 443,
    ca: h2.Ca = .system,
    /// The token APNs last rejected as expired: the next send makes a new one.
    stale_token_buf: [512]u8 = undefined,
    stale_token_len: usize = 0,

    /// `creds` is borrowed: it must outlive the client.
    pub fn init(gpa: Allocator, io: Io, creds: Credentials) !Client {
        return .{ .gpa = gpa, .io = io, .creds = creds, .key = try jwt.p8PrivateKey(gpa, creds.private_key) };
    }

    pub fn deinit(c: *Client) void {
        for (&c.conns) |*slot| if (slot.*) |conn| {
            conn.close();
            slot.* = null;
        };
        std.crypto.secureZero(u8, &c.key);
    }

    fn connection(c: *Client, env: Environment) !struct { *h2.Connection, bool } {
        const slot = &c.conns[@backingInt(env)];
        if (slot.*) |conn| {
            if (conn.usable()) return .{ conn, true };
            conn.close();
            slot.* = null;
        }
        const conn = try h2.Connection.open(c.gpa, c.io, c.host_override orelse env.host(), c.port, c.ca);
        slot.* = conn;
        return .{ conn, false };
    }

    fn dropConnection(c: *Client, env: Environment) void {
        const slot = &c.conns[@backingInt(env)];
        if (slot.*) |conn| conn.close();
        slot.* = null;
    }

    /// Sends `payload` (the JSON with "aps") to one device. `device_token` is the hex token the
    /// app registered. Errors are transport failures; APNs' answers, refusals included, come
    /// back in the Result.
    pub fn send(c: *Client, device_token: []const u8, payload: []const u8, options: Options) !Result {
        if (device_token.len == 0 or device_token.len > 200) return error.InvalidDeviceToken;
        for (device_token) |ch| if (!std.ascii.isHex(ch)) return error.InvalidDeviceToken;
        if (options.collapse_id) |id| if (id.len > 64) return error.CollapseIdTooLong;

        const now_s = Io.Timestamp.now(c.io, .real).toSeconds();
        var token_buf: [512]u8 = undefined;
        const stale: ?[]const u8 = if (c.stale_token_len > 0) c.stale_token_buf[0..c.stale_token_len] else null;
        const token = try providerToken(c.gpa, c.io, c.creds, c.key, now_s, stale, &token_buf);

        var path_buf: [16 + 200]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/3/device/{s}", .{device_token});
        var auth_buf: [7 + 512]u8 = undefined;
        const auth = try std.fmt.bufPrint(&auth_buf, "bearer {s}", .{token});
        var topic_buf: [256]u8 = undefined;
        const topic = if (options.push_type == .voip)
            try std.fmt.bufPrint(&topic_buf, "{s}.voip", .{c.creds.bundle_id})
        else
            c.creds.bundle_id;
        const priority: u8 = options.priority orelse if (options.push_type == .background) 5 else 10;
        var priority_buf: [4]u8 = undefined;
        var expiration_buf: [24]u8 = undefined;

        var headers: [7]h2.Header = undefined;
        var n: usize = 0;
        headers[n] = .{ .name = "authorization", .value = auth };
        n += 1;
        headers[n] = .{ .name = "apns-topic", .value = topic };
        n += 1;
        headers[n] = .{ .name = "apns-push-type", .value = @tagName(options.push_type) };
        n += 1;
        headers[n] = .{ .name = "apns-priority", .value = try std.fmt.bufPrint(&priority_buf, "{d}", .{priority}) };
        n += 1;
        if (options.expiration) |e| {
            headers[n] = .{ .name = "apns-expiration", .value = try std.fmt.bufPrint(&expiration_buf, "{d}", .{e}) };
            n += 1;
        }
        if (options.collapse_id) |id| {
            headers[n] = .{ .name = "apns-collapse-id", .value = id };
            n += 1;
        }
        headers[n] = .{ .name = "content-type", .value = "application/json" };
        n += 1;

        const env = options.environment;
        var attempt: u8 = 0;
        var res = while (true) : (attempt += 1) {
            const conn, const reused = try c.connection(env);
            const req: h2.Request = .{
                .method = "POST",
                .authority = c.host_override orelse env.host(),
                .path = path,
                .headers = headers[0..n],
                .body = payload,
            };
            break conn.request(req) catch |err| {
                c.dropConnection(env);
                // A connection that sat idle may have been closed by APNs: retry once on a
                // fresh one. A fresh connection failing is a real failure.
                if (attempt == 0 and reused) switch (err) {
                    error.GoAway, error.ConnectionClosed, error.ReadFailed, error.WriteFailed, error.StreamReset => continue,
                    else => {},
                };
                return err;
            };
        };
        defer res.deinit();

        var result: Result = .{ .status = res.status };
        if (res.header("apns-id")) |id| {
            result.apns_id_len = @intCast(@min(id.len, result.apns_id_buf.len));
            @memcpy(result.apns_id_buf[0..result.apns_id_len], id[0..result.apns_id_len]);
        }
        if (res.status != 200 and res.body.len > 0) {
            const Body = struct { reason: ?[]const u8 = null, timestamp: ?i64 = null };
            if (std.json.parseFromSlice(Body, c.gpa, res.body, .{ .ignore_unknown_fields = true })) |parsed| {
                defer parsed.deinit();
                if (parsed.value.reason) |r| {
                    result.reason_len = @intCast(@min(r.len, result.reason_buf.len));
                    @memcpy(result.reason_buf[0..result.reason_len], r[0..result.reason_len]);
                }
                result.timestamp_ms = parsed.value.timestamp;
            } else |_| {}
        }
        if (res.status == 403 and std.mem.eql(u8, result.reason(), "ExpiredProviderToken")) {
            @memcpy(c.stale_token_buf[0..token.len], token);
            c.stale_token_len = token.len;
        }
        return result;
    }
};

/// One-shot send: connects, sends, closes. Prefer a long-lived `Client` for more than the odd
/// push; the provider token is cached either way.
pub fn send(gpa: Allocator, io: Io, creds: Credentials, device_token: []const u8, payload: []const u8, options: Options) !Result {
    var c = try Client.init(gpa, io, creds);
    defer c.deinit();
    return c.send(device_token, payload, options);
}

// ---- Tests ---------------------------------------------------------------------------------

const testing = std.testing;
const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

test "provider token is cached, and renewed when old or rejected" {
    const kp = try EcdsaP256.KeyPair.generateDeterministic(@splat(9));
    const key = kp.secret_key.toBytes();
    const creds: Credentials = .{ .team_id = "TEAM123456", .key_id = "KEY1234567", .private_key = "", .bundle_id = "com.example" };
    const io = testing.io;
    var b1: [512]u8 = undefined;
    var b2: [512]u8 = undefined;
    const t1 = try providerToken(testing.allocator, io, creds, key, 1_800_000_000, null, &b1);
    try jwt.verifyEs256(t1, kp.public_key);
    // 49 minutes later: the same token.
    try testing.expectEqualStrings(t1, try providerToken(testing.allocator, io, creds, key, 1_800_000_000 + 49 * 60, null, &b2));
    // 50 minutes: a new one.
    const t3 = try providerToken(testing.allocator, io, creds, key, 1_800_000_000 + 50 * 60, null, &b2);
    try testing.expect(!std.mem.eql(u8, t1, t3));
    // APNs called it expired: a new one at once.
    @memcpy(b1[0..t3.len], t3);
    const t4 = try providerToken(testing.allocator, io, creds, key, 1_800_000_000 + 51 * 60, b1[0..t3.len], &b2);
    try testing.expect(!std.mem.eql(u8, b1[0..t3.len], t4));
    // Another key: its own token.
    var other = creds;
    other.key_id = "KEY7654321";
    const t5 = try providerToken(testing.allocator, io, other, key, 1_800_000_000 + 51 * 60, null, &b1);
    try testing.expect(std.mem.indexOf(u8, t5, "eyJ") == 0);
    token_cache = .{};
}

test "results: token gone" {
    var r: Result = .{ .status = 400 };
    @memcpy(r.reason_buf[0..14], "BadDeviceToken");
    r.reason_len = 14;
    try testing.expect(r.tokenGone());
    try testing.expect((Result{ .status = 410 }).tokenGone());
    try testing.expect(!(Result{ .status = 200 }).tokenGone());
}
