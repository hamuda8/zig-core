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
//!     // start: this app's token, else one another of our apps keeps (single sign-on)
//!     if (zui.wufour.saved(a)) |tok| ...
//!     // a 401 from the app's server
//!     zui.wufour.refused(tok);
//!     // back on screen: signed in or out in another app meanwhile?
//!     switch (zui.wufour.recheck(a, current_token)) { ... }
//!     // sign out (here and in our other apps)
//!     if (zui.wufour.logoutRequest(a, auth_host, tok)) |req| fx.fetch(req, onAnything);
//!     zui.wufour.signOutEverywhere();

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
    /// The page's top bar (`WebAuth`): its title ("Sign in with Wufour") and the app's colours.
    title: []const u8 = "",
    bar: ?Color = null,
    ink: ?Color = null,
    background: ?Color = null,
};

const Color = @import("color.zig").Color;

/// Opens Wufour's sign-in inside the app (`fx.webAuth`); `done` gets the callback address
/// (`tokenOfResult` reads the token from it) or `.cancelled`.
pub fn signIn(comptime Msg: type, fx: runtime.Fx(Msg), o: SignIn, done: *const fn (runtime.WebAuthResult) Msg) void {
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const url = signInUrl(fba.allocator(), o.auth_host, o.callback) catch return;
    fx.webAuth(.{ .url = url, .callback_prefix = callbackPrefix(o.callback), .title = o.title, .bar = o.bar, .ink = o.ink, .background = o.background }, done);
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

// ---- Keeping the token, shared by our apps on the phone (single sign-on) ----
//
// Like Google's apps: signed in once in any of our apps (zui/wufour_apps.zig), the others start
// signed in; signed out in one, all are. Android: each app serves its token to the others
// (ZuiAuthProvider, readable only by apps signed with our key); iOS: a Keychain item in a
// shared access group (WufourKeychainGroup in Info.plist, keychain-access-groups entitlement);
// the web: Wufour's own session cookie already does it.

const zui = @import("zui.zig");
pub const apps = @import("wufour_apps.zig");
const refused_key = "token_refused";

/// The token kept by this app (in `a`), or null.
pub fn local(a: std.mem.Allocator) ?[]u8 {
    const t = storage.get(a, storage_key, .{ .secure = true }) orelse return null;
    if (t.len == 0) return null;
    return t;
}

/// The token to start with (in `a`): this app's, else the one another of our apps keeps (it is
/// adopted and kept here; the app's first request checks it with its server, which asks Wufour
/// (/api/auth/verify), and a 401 goes to `refused`). Null: signed out.
pub fn saved(a: std.mem.Allocator) ?[]u8 {
    if (local(a)) |t| return t;
    const t = zui.host.sharedAuthGet(a, apps.csv) orelse return null;
    if (t.len == 0 or isRefused(t)) {
        a.free(t);
        return null;
    }
    storage.set(storage_key, t, .{ .secure = true });
    return t;
}

/// Signed in here: kept for this app and offered to the others.
pub fn save(token: []const u8) void {
    storage.set(storage_key, token, .{ .secure = true });
    storage.remove(refused_key, .{});
    zui.host.sharedAuthSet(token);
}

/// Forgets this app's token only.
pub fn forget() void {
    storage.remove(storage_key, .{ .secure = true });
}

/// The app's server answered 401 for `token`: forget it here, and do not take the same token
/// from another app again (that one is signed out on its own 401).
pub fn refused(token: []const u8) void {
    forget();
    var hex: [64]u8 = undefined;
    storage.set(refused_key, hashOf(token, &hex), .{});
}

/// Sign out on this phone: this app and every other of ours (send `logoutRequest` too, which
/// ends the session at Wufour).
pub fn signOutEverywhere() void {
    forget();
    zui.host.sharedAuthClear(apps.csv);
}

pub const Recheck = union(enum) {
    /// Nothing changed.
    same,
    /// Signed out in another app meanwhile: show sign-in.
    signed_out,
    /// Signed in in another app meanwhile (or as someone else): start with this token (in `a`).
    signed_in: []u8,
};

/// When the app comes back to the screen: has another app signed in or out meanwhile?
/// `current` is the token the app is using (null: it shows sign-in).
pub fn recheck(a: std.mem.Allocator, current: ?[]const u8) Recheck {
    const cur = current orelse return if (saved(a)) |t| .{ .signed_in = t } else .same;
    const t = local(a) orelse return .signed_out;
    if (std.mem.eql(u8, t, cur)) {
        a.free(t);
        return .same;
    }
    return .{ .signed_in = t };
}

fn hashOf(token: []const u8, out: *[64]u8) []const u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &d, .{});
    return std.fmt.bufPrint(out, "{x}", .{&d}) catch "";
}

fn isRefused(token: []const u8) bool {
    var buf: [128]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const r = storage.get(fba.allocator(), refused_key, .{}) orelse return false;
    var hex: [64]u8 = undefined;
    return std.mem.eql(u8, r, hashOf(token, &hex));
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

test "single sign-on: another app's token is adopted, a refused one is not, sign-out reaches all" {
    if (zui.platform != .headless) return;
    const h = zui.host;
    const a = testing.allocator;
    forget();
    storage.remove(refused_key, .{});
    h.shared_token.clearRetainingCapacity();
    defer h.shared_token.clearRetainingCapacity();
    try testing.expect(saved(a) == null);
    try testing.expect(recheck(a, null) == .same);

    // Signed in in another app: adopted and kept here.
    try h.shared_token.appendSlice(std.heap.page_allocator, "T1");
    const t1 = saved(a).?;
    defer a.free(t1);
    try testing.expectEqualStrings("T1", t1);
    const l1 = local(a).?;
    defer a.free(l1);
    try testing.expectEqualStrings("T1", l1);
    try testing.expect(recheck(a, "T1") == .same);

    // Our server refused it: not taken from the other app again.
    refused("T1");
    try testing.expect(saved(a) == null);
    // A new sign-in there is.
    h.shared_token.clearRetainingCapacity();
    try h.shared_token.appendSlice(std.heap.page_allocator, "T2");
    const r = recheck(a, null);
    try testing.expectEqualStrings("T2", r.signed_in);
    a.free(r.signed_in);

    // Signed out in another app (its provider cleared ours): this one notices.
    forget();
    try testing.expect(recheck(a, "T2") == .signed_out);

    // Signing out here signs the others out.
    save("T3");
    const before = h.shared_cleared;
    signOutEverywhere();
    try testing.expectEqual(before + 1, h.shared_cleared);
    try testing.expect(local(a) == null);
    try testing.expect(saved(a) == null);
}
