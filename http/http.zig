//! HTTP server for the Zig app servers: router, request context, JSON, static files, WebSocket
//! and server-sent events, on top of std.http.Server and std.Io. TLS 1.3 (`tls/`) wraps the
//! connection stream; without it the server speaks plain HTTP.
//!
//!     var router: http.Router = .init(gpa);
//!     try router.get("/healthz", healthz);
//!     try router.get("/api/v1/route/:id", route);
//!     try http.serve(io, gpa, .{ .address = addr, .router = &router });
//!
//! Handlers run concurrently (one task per connection); state they share needs a lock.

const std = @import("std");
const Io = std.Io;

pub const Method = std.http.Method;
pub const Status = std.http.Status;
pub const Header = std.http.Header;
pub const ws = @import("ws.zig");
/// Server-Sent Events fan-out to named channels.
pub const sse = @import("sse.zig");
pub const RateLimiter = @import("ratelimit.zig").RateLimiter;

pub const Handler = *const fn (ctx: *Context) anyerror!void;

pub const Param = struct { name: []const u8, value: []const u8 };

/// One request. Everything allocated from `arena` lives until the response is sent.
pub const Context = struct {
    io: Io,
    arena: std.mem.Allocator,
    /// For memory that outlives a request's arena use (WebSocket message buffers).
    gpa: std.mem.Allocator,
    request: *std.http.Server.Request,
    method: Method,
    /// Path without the query string, still percent-encoded.
    path: []const u8,
    /// The part after `?`, without it.
    query: []const u8,
    headers: []const Header,
    params: std.ArrayList(Param) = .empty,
    /// Headers added to whatever response is sent (CORS, security headers, cookies).
    response_headers: std.ArrayList(Header) = .empty,
    responded: bool = false,
    /// Set when the response took over the connection (event streams, WebSockets), or when
    /// the request left bytes on it: it is closed when the handler returns instead of waiting
    /// for another request.
    close_connection: bool = false,
    max_body: usize,
    /// The body once read: `body()` reads it once. Bodies of methods without body semantics
    /// (DELETE, GET, ...) are read before the handler runs; std.http would leave them on the
    /// connection, where they would be taken for the next request.
    raw_body: ?[]const u8 = null,
    body_error: ?Error = null,
    /// Free for middleware to pass data to handlers (the signed-in user, for example).
    user_data: ?*anyopaque = null,
    /// The TCP connection: its peer address, and a handle WebSocket rooms use to close it.
    stream: Io.net.Stream,
    /// Whether to take the client address from the proxy headers (Cloudflare Tunnel).
    trust_proxy: bool,

    pub const Error = error{ BadRequest, PayloadTooLarge };

    /// The visitor's IP address. Behind a trusted proxy, from CF-Connecting-IP or the first
    /// X-Forwarded-For entry; otherwise the TCP peer.
    pub fn clientIp(ctx: *Context) []const u8 {
        if (ctx.trust_proxy) {
            if (ctx.header("cf-connecting-ip")) |v| return std.mem.trim(u8, v, " ");
            if (ctx.header("x-forwarded-for")) |v| return std.mem.trim(u8, v[0 .. std.mem.indexOfScalar(u8, v, ',') orelse v.len], " ");
        }
        return formatIp(ctx.arena, ctx.stream.socket.address) catch "";
    }

    /// The value of cookie `name`, percent-decoded, the last one when it is sent twice (as
    /// wufour-auth's parseCookies reads it). A value that does not decode is returned as sent.
    pub fn cookie(ctx: *const Context, name: []const u8) ?[]const u8 {
        const raw = ctx.cookieRaw(name) orelse return null;
        return decodeComponent(ctx.arena, raw) catch raw;
    }

    /// The value of cookie `name` exactly as sent (the last one).
    pub fn cookieRaw(ctx: *const Context, name: []const u8) ?[]const u8 {
        var found: ?[]const u8 = null;
        for (ctx.headers) |h| {
            if (!std.ascii.eqlIgnoreCase(h.name, "cookie")) continue;
            var it = std.mem.splitScalar(u8, h.value, ';');
            while (it.next()) |part| {
                const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
                if (std.mem.eql(u8, std.mem.trim(u8, part[0..eq], " "), name)) found = std.mem.trim(u8, part[eq + 1 ..], " ");
            }
        }
        return found;
    }

    /// Adds a Set-Cookie header. `max_age` 0 deletes the cookie.
    pub fn setCookie(ctx: *Context, name: []const u8, value: []const u8, max_age: u32) !void {
        try ctx.addHeader("set-cookie", try std.fmt.allocPrint(ctx.arena, "{s}={s}; Path=/; Max-Age={d}; HttpOnly; SameSite=Lax", .{ name, value, max_age }));
    }

    pub fn redirect(ctx: *Context, location: []const u8) !void {
        try ctx.setHeader("location", location);
        return ctx.send(.found, "text/plain; charset=utf-8", "");
    }

    pub fn header(ctx: *const Context, name: []const u8) ?[]const u8 {
        for (ctx.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }

    /// A `:name` segment of the matched route.
    pub fn param(ctx: *const Context, name: []const u8) ?[]const u8 {
        for (ctx.params.items) |p| if (std.mem.eql(u8, p.name, name)) return p.value;
        return null;
    }

    /// A query parameter, percent-decoded (`+` is a space).
    pub fn queryParam(ctx: *Context, name: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, ctx.query, '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
            const k = decode(ctx.arena, pair[0..eq]) catch continue;
            if (!std.mem.eql(u8, k, name)) continue;
            return decode(ctx.arena, if (eq < pair.len) pair[eq + 1 ..] else "") catch null;
        }
        return null;
    }

    /// Whether the request says it carries a body (a length above zero, or chunked).
    pub fn hasBody(ctx: *const Context) bool {
        const h = &ctx.request.head;
        return h.transfer_encoding != .none or (h.content_length orelse 0) > 0;
    }

    /// The whole request body, up to `max_body` bytes, on any method. A body over the limit is
    /// read away (up to 64 MiB, so the client sees the answer instead of a reset) or the
    /// connection is closed after the response.
    pub fn body(ctx: *Context) Error![]const u8 {
        if (ctx.raw_body) |b| return b;
        if (ctx.body_error) |e| return e;
        const req = ctx.request;
        var buf: [4096]u8 = undefined;
        var r: *std.Io.Reader = undefined;
        if (req.head.method.requestHasBody()) {
            r = req.readerExpectContinue(&buf) catch return ctx.bodyFailed(error.BadRequest);
        } else {
            if (!ctx.hasBody()) {
                ctx.raw_body = "";
                return "";
            }
            req.writeExpectContinue() catch return ctx.bodyFailed(error.BadRequest);
            r = req.server.reader.bodyReader(&buf, req.head.transfer_encoding, req.head.content_length);
        }
        const data = r.allocRemaining(ctx.arena, .limited(ctx.max_body)) catch |err| switch (err) {
            error.StreamTooLong => {
                const total = req.head.content_length orelse std.math.maxInt(u64);
                if (total > 64 * 1024 * 1024) {
                    ctx.close_connection = true;
                } else {
                    _ = r.discardRemaining() catch {
                        ctx.close_connection = true;
                    };
                }
                return ctx.bodyFailed(error.PayloadTooLarge);
            },
            else => return ctx.bodyFailed(error.BadRequest),
        };
        ctx.raw_body = data;
        return data;
    }

    fn bodyFailed(ctx: *Context, e: Error) Error {
        if (e == error.BadRequest) ctx.close_connection = true;
        ctx.body_error = e;
        return e;
    }

    /// The body parsed as JSON into `T`. Unknown fields are ignored.
    pub fn json(ctx: *Context, comptime T: type) !T {
        const b = try ctx.body();
        return std.json.parseFromSliceLeaky(T, ctx.arena, b, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch error.BadRequest;
    }

    /// Sets a response header (replacing one of the same name). CR and LF in the value are
    /// replaced by spaces: std.http asserts on them, and values often come from the request.
    pub fn setHeader(ctx: *Context, name: []const u8, value: []const u8) !void {
        const v = try headerSafe(ctx.arena, value);
        for (ctx.response_headers.items) |*h| if (std.ascii.eqlIgnoreCase(h.name, name)) {
            h.value = v;
            return;
        };
        try ctx.response_headers.append(ctx.arena, .{ .name = name, .value = v });
    }

    /// Adds a response header even when one of the same name is already set (Set-Cookie).
    pub fn addHeader(ctx: *Context, name: []const u8, value: []const u8) !void {
        try ctx.response_headers.append(ctx.arena, .{ .name = name, .value = try headerSafe(ctx.arena, value) });
    }

    pub fn send(ctx: *Context, status: Status, content_type: []const u8, data: []const u8) !void {
        try ctx.setHeader("content-type", content_type);
        ctx.responded = true;
        try ctx.request.respond(data, .{ .status = status, .extra_headers = ctx.response_headers.items });
    }

    /// A response without a body or a content type (304, 416, a bare 404).
    pub fn end(ctx: *Context, status: Status) !void {
        ctx.responded = true;
        try ctx.request.respond("", .{ .status = status, .extra_headers = ctx.response_headers.items });
    }

    pub fn text(ctx: *Context, status: Status, s: []const u8) !void {
        return ctx.send(status, "text/plain; charset=utf-8", s);
    }

    /// `value` as JSON (structs, slices, numbers, strings, `std.json.Value`, ...).
    pub fn sendJson(ctx: *Context, status: Status, value: anytype) !void {
        var out: std.Io.Writer.Allocating = .init(ctx.arena);
        try std.json.Stringify.value(value, .{}, &out.writer);
        return ctx.send(status, "application/json", out.written());
    }

    /// `{"error": message}` with `status`, the shape the Node servers use.
    pub fn fail(ctx: *Context, status: Status, message: []const u8) !void {
        return ctx.sendJson(status, .{ .@"error" = message });
    }

    /// The `Range: bytes=…` of the request against a body of `total` bytes (one range, as
    /// Express's send serves it).
    pub fn range(ctx: *const Context, total: u64) Range {
        return parseRange(ctx.header("range") orelse return .full, total);
    }

    /// Starts a response of exactly `length` bytes, written with `BodyStream.write`. HEAD
    /// requests get the headers only. With a `range` from `Context.range`, the status is 206
    /// with Content-Range; an unsatisfiable range is answered here with 416 (and null returned).
    pub fn startBody(ctx: *Context, buffer: []u8, status: Status, content_type: ?[]const u8, length: u64) !BodyStream {
        if (content_type) |t| try ctx.setHeader("content-type", t);
        ctx.responded = true;
        if (ctx.request.head.method == .HEAD) {
            // std's streaming writer expects every promised byte; a HEAD answer has none, so the
            // length goes out as a plain header on an otherwise empty response.
            try ctx.setHeader("content-length", try std.fmt.allocPrint(ctx.arena, "{d}", .{length}));
            const w = try ctx.request.respondStreaming(buffer, .{ .respond_options = .{ .status = status, .extra_headers = ctx.response_headers.items, .transfer_encoding = .none } });
            return .{ .ctx = ctx, .body = w, .remaining = 0, .elide = true };
        }
        const w = try ctx.request.respondStreaming(buffer, .{ .content_length = length, .respond_options = .{ .status = status, .extra_headers = ctx.response_headers.items } });
        return .{ .ctx = ctx, .body = w, .remaining = length, .elide = false };
    }

    /// Answers a range that does not fit the body: 416 with `Content-Range: bytes */total`.
    pub fn unsatisfiable(ctx: *Context, total: u64) !void {
        try ctx.setHeader("content-range", try std.fmt.allocPrint(ctx.arena, "bytes */{d}", .{total}));
        return ctx.end(.range_not_satisfiable);
    }

    /// Sets 206 headers for a partial body and returns its length.
    pub fn partial(ctx: *Context, start: u64, last: u64, total: u64) !u64 {
        try ctx.setHeader("content-range", try std.fmt.allocPrint(ctx.arena, "bytes {d}-{d}/{d}", .{ start, last, total }));
        return last - start + 1;
    }

    /// Whether the client asked to upgrade to a WebSocket.
    pub fn wantsWebSocket(ctx: *const Context) bool {
        return ctx.request.upgradeRequested() == .websocket;
    }

    /// Completes the WebSocket handshake. The connection is closed when the handler returns.
    pub fn webSocket(ctx: *Context) !ws.Socket {
        const k = switch (ctx.request.upgradeRequested()) {
            .websocket => |k| k orelse return error.NotWebSocket,
            else => return error.NotWebSocket,
        };
        ctx.responded = true;
        ctx.close_connection = true;
        var std_ws = try ctx.request.respondWebSocket(.{ .key = k, .extra_headers = ctx.response_headers.items });
        try std_ws.flush();
        return .{ .io = ctx.io, .gpa = ctx.gpa, .in = std_ws.input, .out = std_ws.output, .stream = ctx.stream };
    }

    /// Starts a `text/event-stream` response.
    pub fn eventStream(ctx: *Context, buffer: []u8) !EventStream {
        try ctx.setHeader("content-type", "text/event-stream");
        try ctx.setHeader("cache-control", "no-cache");
        ctx.responded = true;
        ctx.close_connection = true;
        var w = try ctx.request.respondStreaming(buffer, .{ .respond_options = .{ .extra_headers = ctx.response_headers.items, .keep_alive = false } });
        try w.flush();
        return .{ .body = w };
    }
};

/// A response body of a promised length (`Context.startBody`). Writing more than promised is
/// cut off; finishing with less closes the connection instead of tripping std's assertion,
/// so a short file never takes the server down.
pub const BodyStream = struct {
    ctx: *Context,
    body: std.http.BodyWriter,
    remaining: u64,
    elide: bool,

    pub fn write(s: *BodyStream, data: []const u8) !void {
        if (s.elide) return;
        const n: usize = @intCast(@min(data.len, s.remaining));
        try s.body.writer.writeAll(data[0..n]);
        s.remaining -= n;
    }

    pub fn finish(s: *BodyStream) !void {
        if (s.remaining != 0) {
            s.body.writer.flush() catch {};
            s.body.http_protocol_output.flush() catch {};
            s.ctx.close_connection = true;
            return;
        }
        try s.body.end();
    }
};

pub const Range = union(enum) {
    /// No (usable) Range header: the whole body.
    full,
    /// Inclusive byte offsets.
    partial: struct { start: u64, last: u64 },
    unsatisfiable,
};

/// `bytes=a-b`, `bytes=a-`, `bytes=-n`. Anything else is the whole body.
pub fn parseRange(h: []const u8, total: u64) Range {
    if (!std.mem.startsWith(u8, h, "bytes=")) return .full;
    const spec = h[6..];
    if (std.mem.indexOfScalar(u8, spec, ',') != null) return .full;
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return .full;
    const a = spec[0..dash];
    const b = spec[dash + 1 ..];
    for (a) |c| if (!std.ascii.isDigit(c)) return .full;
    for (b) |c| if (!std.ascii.isDigit(c)) return .full;
    if (a.len == 0 and b.len == 0) return .full;
    if (total == 0) return .unsatisfiable;
    if (a.len == 0) {
        const n = std.fmt.parseInt(u64, b, 10) catch return .full;
        if (n == 0) return .unsatisfiable;
        return .{ .partial = .{ .start = total - @min(n, total), .last = total - 1 } };
    }
    const start = std.fmt.parseInt(u64, a, 10) catch return .unsatisfiable;
    var last = total - 1;
    if (b.len > 0) last = @min(std.fmt.parseInt(u64, b, 10) catch total - 1, total - 1);
    if (start > last or start >= total) return .unsatisfiable;
    return .{ .partial = .{ .start = start, .last = last } };
}

/// A header value without CR or LF.
pub fn headerSafe(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, value, "\r\n") == null) return value;
    const out = try arena.dupe(u8, value);
    for (out) |*c| if (c.* == '\r' or c.* == '\n') {
        c.* = ' ';
    };
    return out;
}

/// decodeURIComponent: `%XX` only (`+` stays), and the result must be UTF-8.
pub fn decodeComponent(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null) return s;
    var out = try arena.alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) {
        if (s[i] == '%') {
            if (i + 3 > s.len) return error.BadEncoding;
            out[n] = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return error.BadEncoding;
            i += 3;
        } else {
            out[n] = s[i];
            i += 1;
        }
    }
    if (!std.unicode.utf8ValidateSlice(out[0..n])) return error.BadEncoding;
    return out[0..n];
}

pub const EventStream = struct {
    body: std.http.BodyWriter,

    /// Sends one event. `data` may contain newlines; each line becomes a `data:` line.
    pub fn send(s: *EventStream, event: ?[]const u8, data: []const u8) !void {
        const w = &s.body.writer;
        if (event) |e| try w.print("event: {s}\n", .{e});
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| try w.print("data: {s}\n", .{line});
        try w.writeAll("\n");
        // The body writer has its own buffer in front of the connection's: empty both.
        try s.body.writer.flush();
        try s.body.flush();
    }

    /// A comment line, to keep idle connections open through proxies.
    pub fn ping(s: *EventStream) !void {
        try s.body.writer.writeAll(": ping\n\n");
        // The body writer has its own buffer in front of the connection's: empty both.
        try s.body.writer.flush();
        try s.body.flush();
    }

    pub fn end(s: *EventStream) !void {
        try s.body.end();
    }
};

/// An IP address without its port ("192.0.2.1", "2001:db8::1").
pub fn formatIp(arena: std.mem.Allocator, addr: Io.net.IpAddress) ![]const u8 {
    return switch (addr) {
        .ip4 => |a| std.fmt.allocPrint(arena, "{d}.{d}.{d}.{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] }),
        .ip6 => |a| blk: {
            var out: std.ArrayList(u8) = .empty;
            var i: usize = 0;
            while (i < 16) : (i += 2) {
                if (i > 0) try out.append(arena, ':');
                try out.print(arena, "{x}", .{std.mem.readInt(u16, a.bytes[i..][0..2], .big)});
            }
            break :blk out.items;
        },
    };
}

/// Percent-encodes everything except unreserved characters (for query values).
pub fn encode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') try out.append(arena, c) else try out.print(arena, "%{X:0>2}", .{c});
    }
    return out.items;
}

/// Percent-decodes a query string part (`+` is a space, as in forms) into new memory. Paths and
/// cookies use `decodeComponent`, where `+` stays a plus.
pub fn decode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, s, "%+") == null) return s;
    var out = try arena.alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) {
        if (s[i] == '+') {
            out[n] = ' ';
            i += 1;
        } else if (s[i] == '%' and i + 3 <= s.len) {
            out[n] = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return error.BadEncoding;
            i += 3;
        } else {
            out[n] = s[i];
            i += 1;
        }
    }
    return out[0..n];
}

pub const Router = struct {
    gpa: std.mem.Allocator,
    routes: std.ArrayList(Route) = .empty,
    middleware: std.ArrayList(Handler) = .empty,
    /// Runs when no route matches (static files, for example). Default: 404 JSON.
    fallback: ?Handler = null,

    const Route = struct { method: ?Method, pattern: []const u8, handler: Handler };

    pub fn init(gpa: std.mem.Allocator) Router {
        return .{ .gpa = gpa };
    }

    pub fn deinit(r: *Router) void {
        r.routes.deinit(r.gpa);
        r.middleware.deinit(r.gpa);
    }

    /// Runs before every route, in order. A middleware that responds stops the request there.
    pub fn use(r: *Router, h: Handler) !void {
        try r.middleware.append(r.gpa, h);
    }

    /// `pattern` segments: literal, `:name` (one segment), or a final `*name` (the rest).
    /// A null method matches any method.
    pub fn add(r: *Router, method: ?Method, pattern: []const u8, h: Handler) !void {
        try r.routes.append(r.gpa, .{ .method = method, .pattern = pattern, .handler = h });
    }

    pub fn get(r: *Router, p: []const u8, h: Handler) !void {
        return r.add(.GET, p, h);
    }
    pub fn post(r: *Router, p: []const u8, h: Handler) !void {
        return r.add(.POST, p, h);
    }
    pub fn put(r: *Router, p: []const u8, h: Handler) !void {
        return r.add(.PUT, p, h);
    }
    pub fn patch(r: *Router, p: []const u8, h: Handler) !void {
        return r.add(.PATCH, p, h);
    }
    pub fn delete(r: *Router, p: []const u8, h: Handler) !void {
        return r.add(.DELETE, p, h);
    }

    pub fn dispatch(r: *const Router, ctx: *Context) !void {
        for (r.middleware.items) |m| {
            try m(ctx);
            if (ctx.responded) return;
        }
        var path_matched = false;
        for (r.routes.items) |route| {
            ctx.params.clearRetainingCapacity();
            if (!try match(ctx, route.pattern, ctx.path)) continue;
            path_matched = true;
            // HEAD is answered by the GET route; std.http leaves the body out.
            if (route.method) |m| if (m != ctx.method and !(m == .GET and ctx.method == .HEAD)) continue;
            return route.handler(ctx);
        }
        if (path_matched) return ctx.fail(.method_not_allowed, "Method not allowed");
        if (r.fallback) |f| return f(ctx);
        return ctx.fail(.not_found, "Not found");
    }

    fn match(ctx: *Context, pattern: []const u8, path: []const u8) !bool {
        var pi = std.mem.splitScalar(u8, std.mem.trim(u8, pattern, "/"), '/');
        var si = std.mem.splitScalar(u8, std.mem.trim(u8, path, "/"), '/');
        while (pi.next()) |p| {
            if (p.len > 0 and p[0] == '*') {
                try ctx.params.append(ctx.arena, .{ .name = p[1..], .value = try decodeComponent(ctx.arena, si.rest()) });
                return true;
            }
            const s = si.next() orelse return p.len == 0;
            if (p.len > 0 and p[0] == ':') {
                if (s.len == 0) return false;
                try ctx.params.append(ctx.arena, .{ .name = p[1..], .value = try decodeComponent(ctx.arena, s) });
            } else if (!std.mem.eql(u8, p, s)) return false;
        }
        return si.next() == null;
    }
};

pub const Options = struct {
    address: Io.net.IpAddress,
    router: *const Router,
    max_body: usize = 1024 * 1024,
    /// Set once listening, with the bound address (useful with port 0).
    on_listen: ?*const fn (Io.net.IpAddress) void = null,
    /// HTTPS: every connection does a TLS 1.3 handshake with these certificates first.
    tls: ?*CertStore = null,
    /// Read the client address from proxy headers (set when behind Cloudflare Tunnel).
    trust_proxy: bool = false,
    /// Answers a request whose handler failed before responding (default: {"error": ...}).
    on_error: ?*const fn (ctx: *Context, status: Status, err: anyerror) anyerror!void = null,
};

pub const tls = struct {
    pub const Server = @import("tls/Server.zig");
    pub const cert = @import("tls/cert.zig");
    pub const acme = @import("tls/acme.zig");
};

/// The certificates HTTPS connections use (see `tls.cert.CertStore`).
pub const CertStore = tls.cert.CertStore;

/// Accepts connections until canceled; each connection runs as its own task.
pub fn serve(io: Io, gpa: std.mem.Allocator, options: Options) !void {
    var listener = try options.address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    if (options.on_listen) |f| f(listener.socket.address);

    var group: Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.Canceled => return,
            error.ConnectionAborted => continue,
            else => {
                std.log.warn("accept: {t}", .{err});
                continue;
            },
        };
        group.concurrent(io, connection, .{ io, gpa, stream, &options }) catch {
            // No task available: answer on this one, so the client is not left hanging.
            connection(io, gpa, stream, &options);
        };
    }
}

fn connection(io: Io, gpa: std.mem.Allocator, stream: Io.net.Stream, options: *const Options) void {
    defer stream.close(io);
    // Socket buffers hold at least one full TLS record.
    var read_buf: [tls.Server.min_buffer_len]u8 = undefined;
    var write_buf: [tls.Server.min_buffer_len]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);

    if (options.tls) |store| {
        var clear_read: [tls.Server.min_buffer_len]u8 = undefined;
        var clear_write: [16 * 1024]u8 = undefined;
        var session = tls.Server.init(&reader.interface, &writer.interface, .{
            .io = io,
            .certificates = store.get(io),
            .read_buffer = &clear_read,
            .write_buffer = &clear_write,
        }) catch return;
        exchange(io, gpa, stream, &session.reader, &session.writer, options);
        session.end() catch {};
        return;
    }
    exchange(io, gpa, stream, &reader.interface, &writer.interface, options);
}

/// Requests and responses on one connection, until either side ends it.
fn exchange(io: Io, gpa: std.mem.Allocator, stream: Io.net.Stream, in: *std.Io.Reader, out: *std.Io.Writer, options: *const Options) void {
    var server = std.http.Server.init(in, out);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    while (true) {
        _ = arena_state.reset(.retain_capacity);
        var request = server.receiveHead() catch return;
        const keep = handle(io, gpa, arena_state.allocator(), stream, &request, options) catch return;
        if (!keep or !request.head.keep_alive) return;
    }
}

/// Returns whether the connection can take another request.
fn handle(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, stream: Io.net.Stream, request: *std.http.Server.Request, options: *const Options) !bool {
    // A request with neither Content-Length nor Transfer-Encoding has an empty body (RFC 9112
    // 6.3). std.http asserts otherwise, so one bodiless POST would crash the server.
    if (request.head.method.requestHasBody() and request.head.transfer_encoding == .none and request.head.content_length == null)
        request.head.content_length = 0;

    // Copy the head now: reading the body invalidates it.
    const target = try arena.dupe(u8, request.head.target);
    const q = std.mem.indexOfScalar(u8, target, '?');
    var headers: std.ArrayList(Header) = .empty;
    var it = request.iterateHeaders();
    while (it.next()) |h| try headers.append(arena, .{ .name = try arena.dupe(u8, h.name), .value = try arena.dupe(u8, h.value) });

    var ctx: Context = .{
        .io = io,
        .arena = arena,
        .gpa = gpa,
        .request = request,
        .method = request.head.method,
        .path = target[0 .. q orelse target.len],
        .query = if (q) |i| target[i + 1 ..] else "",
        .headers = headers.items,
        .max_body = options.max_body,
        .stream = stream,
        .trust_proxy = options.trust_proxy,
    };
    // std.http reads no body for DELETE, GET, OPTIONS...; left unread, it would be parsed as the
    // next request on this connection. Read it now, whatever the handler does with it.
    if (!request.head.method.requestHasBody() and ctx.hasBody() and !ctx.wantsWebSocket()) _ = ctx.body() catch {};
    options.router.dispatch(&ctx) catch |err| {
        if (ctx.responded) return err;
        const status: Status = switch (err) {
            error.BadRequest, error.BadEncoding => .bad_request,
            error.PayloadTooLarge => .payload_too_large,
            else => .internal_server_error,
        };
        if (status == .internal_server_error) std.log.err("{s} {s}: {t}", .{ @tagName(ctx.method), ctx.path, err });
        if (options.on_error) |f| {
            f(&ctx, status, err) catch return false;
        } else try ctx.fail(status, status.phrase() orelse "Error");
    };
    if (!ctx.responded) try ctx.fail(.internal_server_error, "No response");
    return !ctx.close_connection;
}

/// Challenge answers for `redirectToHttps` (set when ACME is in use).
pub var acme_challenges: ?*tls.acme.Challenges = null;

/// For the port-80 server: answers ACME HTTP-01 challenges, and sends everything else to the
/// same address over HTTPS (301).
pub fn redirectToHttps(ctx: *Context) !void {
    const prefix = "/.well-known/acme-challenge/";
    if (std.mem.startsWith(u8, ctx.path, prefix)) {
        var buf: [512]u8 = undefined;
        const answer = if (acme_challenges) |c| c.get(ctx.io, ctx.path[prefix.len..], &buf) else null;
        if (answer) |a| return ctx.send(.ok, "application/octet-stream", a);
        return ctx.fail(.not_found, "Not found");
    }
    const host_header = ctx.header("host") orelse return ctx.fail(.bad_request, "Missing host");
    // Drop a port (":80"), keep IPv6 brackets intact.
    const host = if (std.mem.lastIndexOfScalar(u8, host_header, ':')) |i| (if (std.mem.indexOfScalar(u8, host_header[i..], ']') == null) host_header[0..i] else host_header) else host_header;
    const query = if (ctx.query.len > 0) "?" else "";
    try ctx.setHeader("location", try std.fmt.allocPrint(ctx.arena, "https://{s}{s}{s}{s}", .{ host, ctx.path, query, ctx.query }));
    return ctx.send(.moved_permanently, "text/plain; charset=utf-8", "");
}

/// Serves files under `root` for the request path (or `ctx.param("path")` if the route has a
/// `*path`). Directories serve `index.html`. With `spa_fallback`, unknown paths without a file
/// extension serve `index.html` too (client-side routing).
pub fn serveDir(ctx: *Context, root: []const u8, spa_fallback: bool) !void {
    var rel = ctx.param("path") orelse (decodeComponent(ctx.arena, ctx.path) catch return ctx.fail(.bad_request, "Bad path"));
    rel = std.mem.trimStart(u8, rel, "/");
    if (rel.len == 0) rel = "index.html";
    var parts = std.mem.splitAny(u8, rel, "/\\");
    while (parts.next()) |p| if (std.mem.eql(u8, p, "..") or std.mem.indexOfScalar(u8, p, 0) != null) return ctx.fail(.bad_request, "Bad path");

    const full = try std.fs.path.join(ctx.arena, &.{ root, rel });
    const data = Io.Dir.cwd().readFileAlloc(ctx.io, full, ctx.arena, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.IsDir => return serveFile(ctx, try std.fs.path.join(ctx.arena, &.{ full, "index.html" })),
        error.FileNotFound => {
            if (spa_fallback and std.fs.path.extension(rel).len == 0) return serveFile(ctx, try std.fs.path.join(ctx.arena, &.{ root, "index.html" }));
            return ctx.fail(.not_found, "Not found");
        },
        else => return err,
    };
    try ctx.setHeader("cache-control", "no-cache");
    return ctx.send(.ok, contentType(rel), data);
}

fn serveFile(ctx: *Context, path: []const u8) !void {
    const data = Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(64 * 1024 * 1024)) catch return ctx.fail(.not_found, "Not found");
    try ctx.setHeader("cache-control", "no-cache");
    return ctx.send(.ok, contentType(path), data);
}

pub fn contentType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const types = [_]struct { []const u8, []const u8 }{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".mjs", "text/javascript; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".json", "application/json" },
        .{ ".webmanifest", "application/manifest+json" },
        .{ ".wasm", "application/wasm" },
        .{ ".svg", "image/svg+xml" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".webp", "image/webp" },
        .{ ".gif", "image/gif" },
        .{ ".ico", "image/x-icon" },
        .{ ".woff2", "font/woff2" },
        .{ ".txt", "text/plain; charset=utf-8" },
        .{ ".pbf", "application/x-protobuf" },
    };
    for (types) |t| if (std.ascii.eqlIgnoreCase(ext, t[0])) return t[1];
    return "application/octet-stream";
}

test {
    _ = @import("test.zig");
    _ = tls.Server;
    _ = tls.acme;
    _ = ws;
    _ = sse;
    _ = @import("ratelimit.zig");
}
