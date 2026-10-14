//! Wufour sign-in for zui apps on the phones, as the wufour-auth library does it for the web:
//! the user is sent to `<auth host>/auth?returnTo=<callback>`, signs in on Wufour's own page,
//! and Wufour sends them to `<callback>?token=<session token>`. On the phones that page is
//! shown inside the app (`fx.webAuth`) and the callback is never loaded: the token is taken
//! from its address, kept in secure storage and sent to the app's server as
//! `Authorization: Bearer`. A 401 from the app's server means the session ended: forget the
//! token and show sign-in again. The web keeps its cookie flow (the server's /auth/callback).
//!
//!     // the button
//!     zui.wufour.signIn(Msg, fx, .{ .auth_host = "https://www.wreseal.com",
//!         .callback = "https://app.example.com/auth/callback" }, onSignIn);
//!     // the answer
//!     fn onSignIn(r: zui.WebAuthResult) Msg { return .{ .signed_in = r }; }
//!     ...  .signed_in => |r| if (zui.wufour.tokenOfResult(a, r)) |tok| { zui.wufour.save(tok); ... }
//!     // sign out
//!     if (zui.wufour.logoutRequest(a, auth_host, tok)) |req| fx.fetch(req, onAnything);
//!     zui.wufour.forget();

const std = @import("std");
const runtime = @import("runtime.zig");
const storage = @import("storage.zig");

/// Where the token is kept (secure storage: the Keychain, the AndroidKeyStore-backed store).
pub const storage_key = "token";

/// The sign-in address: `<auth_host>/auth?returnTo=<callback, percent-encoded>`.
pub fn signInUrl(a: std.mem.Allocator, auth_host: []const u8, callback: []const u8) ![]u8 {
    const host = std.mem.trimEnd(u8, auth_host, "/");
    const enc = try encode(a, callback);
    defer a.free(enc);
    return std.fmt.allocPrint(a, "{s}/auth?returnTo={s}", .{ host, enc });
}

/// What ends the sign-in: the callback without its query, so `?token=` / `&token=` match.
pub fn callbackPrefix(callback: []const u8) []const u8 {
    return callback[0 .. std.mem.indexOfAny(u8, callback, "?#") orelse callback.len];
}

pub const SignIn = struct {
    /// Wufour (AUTH_HOST), e.g. "https://www.wreseal.com".
    auth_host: []const u8,
    /// The app server's callback, a host Wufour accepts (its ALLOWED_SSO_DOMAINS), e.g.
    /// "https://app.example.com/auth/callback?next=%2F". On the phones it is never loaded.
    callback: []const u8,
};

/// Opens Wufour's sign-in inside the app (`fx.webAuth`); `done` gets the callback address
/// (`tokenOfResult` reads the token from it) or `.cancelled`.
pub fn signIn(comptime Msg: type, fx: runtime.Fx(Msg), o: SignIn, done: *const fn (runtime.WebAuthResult) Msg) void {
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const url = signInUrl(fba.allocator(), o.auth_host, o.callback) catch return;
    fx.webAuth(.{ .url = url, .callback_prefix = callbackPrefix(o.callback) }, done);
}

/// The `token` query parameter of a callback address, percent-decoded (in `a`), or null.
pub fn tokenOf(a: std.mem.Allocator, callback_url: []const u8) ?[]u8 {
    const q_at = std.mem.indexOfScalar(u8, callback_url, '?') orelse return null;
    const end = std.mem.indexOfScalarPos(u8, callback_url, q_at, '#') orelse callback_url.len;
    var it = std.mem.splitScalar(u8, callback_url[q_at + 1 .. end], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], "token")) continue;
        const v = decode(a, pair[eq + 1 ..]) catch return null;
        if (v.len == 0) return null;
        return v;
    }
    return null;
}

/// The token of a finished `fx.webAuth`, or null (cancelled, or no token in the address).
pub fn tokenOfResult(a: std.mem.Allocator, r: runtime.WebAuthResult) ?[]u8 {
    return switch (r) {
        .ok => |u| tokenOf(a, u),
        .cancelled => null,
    };
}

/// The token kept on this device (in `a`), or null when signed out.
pub fn saved(a: std.mem.Allocator) ?[]u8 {
    const t = storage.get(a, storage_key, .{ .secure = true }) orelse return null;
    if (t.len == 0) return null;
    return t;
}

pub fn save(token: []const u8) void {
    storage.set(storage_key, token, .{ .secure = true });
}

pub fn forget() void {
    storage.remove(storage_key, .{ .secure = true });
}

/// Ends the session at Wufour: `POST <auth_host>/api/auth/logout {"token": ...}` (the body in
/// `a`). Send it with fx.fetch, then `forget()`.
pub fn logoutRequest(a: std.mem.Allocator, auth_host: []const u8, token: []const u8) ?runtime.Request {
    var body: std.Io.Writer.Allocating = .init(a);
    std.json.Stringify.value(.{ .token = token }, .{}, &body.writer) catch return null;
    const url = std.fmt.allocPrint(a, "{s}/api/auth/logout", .{std.mem.trimEnd(u8, auth_host, "/")}) catch return null;
    return .{ .url = url, .method = .POST, .body = body.written() };
}

/// The app's server refused the token: the session ended (sign in again).
pub fn signedOut(status: u16) bool {
    return status == 401;
}

/// encodeURIComponent.
pub fn encode(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-_.!~*'()", c) != null) {
            try out.append(a, c);
        } else {
            try out.print(a, "%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice(a);
}

/// Percent-decoding of a query value ('+' is a space, as URLSearchParams reads it).
pub fn decode(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                try out.append(a, b);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(a, if (c == '+') ' ' else c);
    }
    return out.toOwnedSlice(a);
}

const testing = std.testing;

test "the sign-in address and the callback prefix" {
    const a = testing.allocator;
    const u = try signInUrl(a, "https://www.wreseal.com/", "https://turf.wreseal.com/auth/callback?next=/");
    defer a.free(u);
    try testing.expectEqualStrings("https://www.wreseal.com/auth?returnTo=https%3A%2F%2Fturf.wreseal.com%2Fauth%2Fcallback%3Fnext%3D%2F", u);
    try testing.expectEqualStrings("https://turf.wreseal.com/auth/callback", callbackPrefix("https://turf.wreseal.com/auth/callback?next=%2F"));
}

test "the token from the callback" {
    const a = testing.allocator;
    const t1 = tokenOf(a, "https://turf.wreseal.com/auth/callback?next=%2F&token=eyJ.a-b_c.d%3D").?;
    defer a.free(t1);
    try testing.expectEqualStrings("eyJ.a-b_c.d=", t1);
    const t2 = tokenOf(a, "https://reseal.wreseal.com/auth/callback?token=abc#x").?;
    defer a.free(t2);
    try testing.expectEqualStrings("abc", t2);
    try testing.expect(tokenOf(a, "https://reseal.wreseal.com/auth/callback?next=%2F") == null);
    try testing.expect(tokenOf(a, "https://reseal.wreseal.com/auth/callback?token=") == null);
    try testing.expect(tokenOfResult(a, .cancelled) == null);
}

test "logout request" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = logoutRequest(arena.allocator(), "https://www.wreseal.com", "T\"1").?;
    try testing.expectEqualStrings("https://www.wreseal.com/api/auth/logout", r.url);
    try testing.expectEqual(runtime.Method.POST, r.method);
    try testing.expectEqualStrings("{\"token\":\"T\\\"1\"}", r.body);
}
