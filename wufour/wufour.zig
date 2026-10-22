//! Wufour sign-in for the app servers, as the wufour-auth library does it: the session token
//! comes from the `wufour_token` / `auth_token` cookies (the web) or `Authorization: Bearer`
//! (the native apps, which have no cookies), and is checked with Wufour's /api/auth/verify.
//! Answers are cached briefly, so polling and GPS pings do not each ask Wufour.
//!
//!     var wu: wufour.Verifier = .{ .fetch = &fetch_client, .host = config.auth_host };
//!     const t = wufour.token(ctx, .cookie_first) orelse return ctx.fail(.unauthorized, "Please sign in");
//!     const user = wu.verify(ctx.arena, t.value, now_ms) orelse return ctx.fail(.unauthorized, "Please sign in");
//!     // user is Wufour's user object: { userId, email, username, role, ... }
//!
//! The account menu every app shows (zui.account) reads Wufour's data through the app's server:
//!
//!     const json = wu.accountMenu(ctx.arena, token_or_null) orelse return ctx.fail(...);
//!     // serve it unchanged, with Cache-Control: no-store

const std = @import("std");
const Io = std.Io;
const http = @import("http");
const fetch = @import("fetch");
const val = @import("mongo").val;
const Val = val.Val;
const Allocator = std.mem.Allocator;

pub const Token = struct {
    value: []const u8,
    /// From an Authorization header (a native app): answer 401 JSON rather than redirecting to
    /// the sign-in page, set no cookies, skip CSRF checks (they protect cookies).
    bearer: bool,
};

pub const Order = enum { cookie_first, bearer_first };

/// The cookie names wufour-auth reads, in order.
pub const cookie_names = [_][]const u8{ "wufour_token", "auth_token" };

/// The session token of a request, or null.
pub fn token(ctx: *http.Context, order: Order) ?Token {
    switch (order) {
        .cookie_first => {
            if (cookieToken(ctx)) |t| return .{ .value = t, .bearer = false };
            if (bearerToken(ctx)) |t| return .{ .value = t, .bearer = true };
        },
        .bearer_first => {
            if (bearerToken(ctx)) |t| return .{ .value = t, .bearer = true };
            if (cookieToken(ctx)) |t| return .{ .value = t, .bearer = false };
        },
    }
    return null;
}

/// The token of the wufour_token or auth_token cookie (percent-decoded).
pub fn cookieToken(ctx: *http.Context) ?[]const u8 {
    for (cookie_names) |n| if (ctx.cookie(n)) |t| if (t.len > 0) return t;
    return null;
}

/// `Authorization: Bearer <token>` (the scheme in any case).
pub fn bearerToken(ctx: *http.Context) ?[]const u8 {
    return bearerOf(ctx.header("authorization") orelse return null);
}

pub fn bearerOf(header: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, header, " \t");
    if (t.len < 7 or !std.ascii.eqlIgnoreCase(t[0..7], "bearer ")) return null;
    const tok = std.mem.trim(u8, t[7..], " \t");
    return if (tok.len > 0) tok else null;
}

/// wufour-auth calls 127.0.0.1 where the configured address says localhost.
pub fn backendHost(a: Allocator, host: []const u8) []const u8 {
    if (std.mem.indexOf(u8, host, "localhost") == null) return host;
    return std.mem.replaceOwned(u8, a, host, "localhost", "127.0.0.1") catch host;
}

pub const Verifier = struct {
    fetch: *fetch.Client,
    /// Wufour's address (AUTH_HOST), e.g. "https://wufour.example.com".
    host: []const u8,
    /// How long a verified token is trusted without asking again; 0 = always ask.
    ttl_ms: i64 = 30_000,
    /// How long a refused token stays refused without asking again; 0 = always ask.
    refused_ttl_ms: i64 = 0,
    max_entries: usize = 20_000,
    timeout_ms: i64 = 15_000,

    lock: Io.Mutex = .init,
    /// sha256(token) as hex (owned) -> the answer
    cache: std.StringHashMapUnmanaged(Entry) = .empty,

    const Entry = struct {
        until: i64,
        /// The user as JSON (owned), or null for a refused token.
        user_json: ?[]u8,
    };

    pub fn deinit(v: *Verifier) void {
        const gpa = v.fetch.gpa;
        var it = v.cache.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.user_json) |j| gpa.free(j);
            gpa.free(e.key_ptr.*);
        }
        v.cache.deinit(gpa);
    }

    /// Wufour's user object for `token` (in `a`), or null when the token is not valid or Wufour
    /// cannot be reached. Answers are cached (see `ttl_ms`).
    pub fn verify(v: *Verifier, a: Allocator, tok: []const u8, now_ms: i64) ?Val {
        if (tok.len == 0 or tok.len > 4096) return null;
        const key = keyOf(tok);
        const io = v.fetch.io;
        if (v.ttl_ms > 0 or v.refused_ttl_ms > 0) {
            v.lock.lockUncancelable(io);
            defer v.lock.unlock(io);
            if (v.cache.get(&key)) |hit| if (hit.until > now_ms) {
                const j = hit.user_json orelse return null;
                return val.parseJson(a, j) catch null;
            };
        }
        const user = v.verifyUncached(a, tok);
        const ttl = if (user != null) v.ttl_ms else v.refused_ttl_ms;
        if (ttl > 0) v.store(&key, if (user) |u| (val.toJson(a, u) catch return user) else null, now_ms + ttl, now_ms) else v.forget(tok);
        return user;
    }

    /// POST /api/auth/verify without the cache.
    pub fn verifyUncached(v: *Verifier, a: Allocator, tok: []const u8) ?Val {
        const body = val.toJson(a, val.from(a, .{ .token = tok }) catch return null) catch return null;
        const url = std.fmt.allocPrint(a, "{s}/api/auth/verify", .{backendHost(a, v.host)}) catch return null;
        const res = v.fetch.fetch(a, url, .{ .method = .POST, .body = body, .content_type = "application/json", .timeout_ms = v.timeout_ms }) catch return null;
        const data = val.parseJson(a, res.body) catch return null;
        if (!data.get("success").truthy()) return null;
        const u = data.get("user");
        return if (u.isObj()) u else null;
    }

    /// Drops the cached answer for `token` (sign-out).
    pub fn forget(v: *Verifier, tok: []const u8) void {
        const key = keyOf(tok);
        const gpa = v.fetch.gpa;
        v.lock.lockUncancelable(v.fetch.io);
        defer v.lock.unlock(v.fetch.io);
        if (v.cache.fetchRemove(&key)) |kv| {
            if (kv.value.user_json) |j| gpa.free(j);
            gpa.free(kv.key);
        }
    }

    /// Ends the session at Wufour (POST /api/auth/logout) and forgets it here.
    pub fn logout(v: *Verifier, a: Allocator, tok: []const u8) void {
        v.forget(tok);
        const body = val.toJson(a, val.from(a, .{ .token = tok }) catch return) catch return;
        const url = std.fmt.allocPrint(a, "{s}/api/auth/logout", .{backendHost(a, v.host)}) catch return;
        _ = v.fetch.fetch(a, url, .{ .method = .POST, .body = body, .content_type = "application/json", .timeout_ms = v.timeout_ms }) catch {};
    }

    /// What the Wufour account menu shows for `tok` (null: signed out): Wufour's answer to
    /// POST /api/account/menu, as JSON (in `a`), or null when Wufour cannot be reached. Serve it
    /// to the app's client unchanged (`no-store`); `zui.account` reads it. Not cached: it changes
    /// when the person renames or reorders their apps, and it is asked once per screen.
    pub fn accountMenu(v: *Verifier, a: Allocator, tok: ?[]const u8) ?[]const u8 {
        const body = val.toJson(a, val.from(a, .{ .token = tok orelse "" }) catch return null) catch return null;
        const url = std.fmt.allocPrint(a, "{s}/api/account/menu", .{backendHost(a, v.host)}) catch return null;
        const res = v.fetch.fetch(a, url, .{ .method = .POST, .body = body, .content_type = "application/json", .timeout_ms = v.timeout_ms }) catch return null;
        if (res.status != 200 or res.body.len == 0 or res.body[0] != '{') return null;
        return res.body;
    }

    fn store(v: *Verifier, key: *const [64]u8, json: ?[]const u8, until: i64, now_ms: i64) void {
        const gpa = v.fetch.gpa;
        v.lock.lockUncancelable(v.fetch.io);
        defer v.lock.unlock(v.fetch.io);
        if (v.cache.count() >= v.max_entries) v.prune(now_ms);
        const owned: ?[]u8 = if (json) |j| (gpa.dupe(u8, j) catch return) else null;
        const gop = v.cache.getOrPut(gpa, key) catch {
            if (owned) |j| gpa.free(j);
            return;
        };
        if (gop.found_existing) {
            if (gop.value_ptr.user_json) |j| gpa.free(j);
        } else {
            gop.key_ptr.* = gpa.dupe(u8, key) catch {
                v.cache.removeByPtr(gop.key_ptr);
                if (owned) |j| gpa.free(j);
                return;
            };
        }
        gop.value_ptr.* = .{ .until = until, .user_json = owned };
    }

    fn prune(v: *Verifier, now_ms: i64) void {
        const gpa = v.fetch.gpa;
        var dead: std.ArrayList([]const u8) = .empty;
        defer dead.deinit(gpa);
        var it = v.cache.iterator();
        while (it.next()) |e| if (e.value_ptr.until <= now_ms) dead.append(gpa, e.key_ptr.*) catch break;
        for (dead.items) |k| if (v.cache.fetchRemove(k)) |kv| {
            if (kv.value.user_json) |j| gpa.free(j);
            gpa.free(kv.key);
        };
        if (v.cache.count() < v.max_entries) return;
        var all = v.cache.iterator();
        while (all.next()) |e| {
            if (e.value_ptr.user_json) |j| gpa.free(j);
            gpa.free(e.key_ptr.*);
        }
        v.cache.clearRetainingCapacity();
    }
};

/// Tokens are kept as their SHA-256, not as they are.
fn keyOf(tok: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(tok, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

const testing = std.testing;

var verify_calls: std.atomic.Value(u32) = .init(0);

fn fakeWufour(ctx: *http.Context) !void {
    _ = verify_calls.fetchAdd(1, .monotonic);
    const body = try ctx.body();
    if (std.mem.indexOf(u8, body, "\"good\"") != null) return ctx.sendJson(.ok, .{ .success = true, .user = .{ .userId = "u1", .email = "A@B.C" } });
    return ctx.sendJson(.unauthorized, .{ .success = false });
}

var port: std.atomic.Value(u16) = .init(0);

fn onListen(addr: Io.net.IpAddress) void {
    port.store(addr.getPort(), .release);
}

fn runFake(router: *const http.Router) anyerror!void {
    try http.serve(testing.io, testing.allocator, .{ .address = try .parse("127.0.0.1", 0), .router = router, .on_listen = onListen });
}

test "verify against Wufour, cached, and forgotten" {
    const io = testing.io;
    var router: http.Router = .init(testing.allocator);
    defer router.deinit();
    try router.post("/api/auth/verify", fakeWufour);
    var server = try io.concurrent(runFake, .{&router});
    defer _ = server.cancel(io) catch {};
    while (port.load(.acquire) == 0) try io.sleep(.fromMilliseconds(5), .awake);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fc: fetch.Client = .init(io, testing.allocator);
    defer fc.deinit();
    var v: Verifier = .{ .fetch = &fc, .host = try std.fmt.allocPrint(a, "http://localhost:{d}", .{port.load(.acquire)}) };
    defer v.deinit();

    const u = v.verify(a, "good", 0).?;
    try testing.expectEqualStrings("u1", u.s("userId").?);
    _ = v.verify(a, "good", 1000).?;
    try testing.expectEqual(@as(u32, 1), verify_calls.load(.monotonic));
    try testing.expect(v.verify(a, "bad", 0) == null);
    try testing.expect(v.verify(a, "bad", 0) == null);
    try testing.expectEqual(@as(u32, 3), verify_calls.load(.monotonic));
    // Expired, then forgotten: asked again.
    _ = v.verify(a, "good", 40_000).?;
    v.forget("good");
    _ = v.verify(a, "good", 40_001).?;
    try testing.expectEqual(@as(u32, 5), verify_calls.load(.monotonic));
}

fn fakeMenu(ctx: *http.Context) !void {
    const body = try ctx.body();
    if (std.mem.indexOf(u8, body, "\"good\"") != null) return ctx.sendJson(.ok, .{ .signedIn = true, .user = .{ .username = "Sara" } });
    return ctx.sendJson(.ok, .{ .signedIn = false });
}

var menu_port: std.atomic.Value(u16) = .init(0);

fn onMenuListen(addr: Io.net.IpAddress) void {
    menu_port.store(addr.getPort(), .release);
}

fn runMenu(router: *const http.Router) anyerror!void {
    try http.serve(testing.io, testing.allocator, .{ .address = try .parse("127.0.0.1", 0), .router = router, .on_listen = onMenuListen });
}

test "the account menu from Wufour, with or without a token" {
    const io = testing.io;
    var router: http.Router = .init(testing.allocator);
    defer router.deinit();
    try router.post("/api/account/menu", fakeMenu);
    var server = try io.concurrent(runMenu, .{&router});
    defer _ = server.cancel(io) catch {};
    while (menu_port.load(.acquire) == 0) try io.sleep(.fromMilliseconds(5), .awake);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fc: fetch.Client = .init(io, testing.allocator);
    defer fc.deinit();
    var v: Verifier = .{ .fetch = &fc, .host = try std.fmt.allocPrint(a, "http://localhost:{d}", .{menu_port.load(.acquire)}) };
    defer v.deinit();

    try testing.expect(std.mem.indexOf(u8, v.accountMenu(a, "good").?, "\"Sara\"") != null);
    try testing.expect(std.mem.indexOf(u8, v.accountMenu(a, null).?, "\"signedIn\":false") != null);
    // Wufour not there: null.
    var gone: Verifier = .{ .fetch = &fc, .host = "http://127.0.0.1:9", .timeout_ms = 2000 };
    defer gone.deinit();
    try testing.expect(gone.accountMenu(a, "good") == null);
}

test "tokens" {
    try testing.expectEqualStrings("abc", bearerOf("bearer  abc ").?);
    try testing.expect(bearerOf("Basic abc") == null);
    try testing.expectEqualStrings("http://127.0.0.1:3000", backendHost(testing.allocator, "http://127.0.0.1:3000"));
}
