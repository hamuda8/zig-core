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
pub const WebSocket = std.http.Server.WebSocket;

pub const Handler = *const fn (ctx: *Context) anyerror!void;

pub const Param = struct { name: []const u8, value: []const u8 };

/// One request. Everything allocated from `arena` lives until the response is sent.
pub const Context = struct {
    io: Io,
    arena: std.mem.Allocator,
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
    /// Set when the response took over the connection (event streams, WebSockets): it is
    /// closed when the handler returns instead of waiting for another request.
    close_connection: bool = false,
    max_body: usize,
    /// Free for middleware to pass data to handlers (the signed-in user, for example).
    user_data: ?*anyopaque = null,

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

    /// The whole request body, up to `max_body` bytes.
    pub fn body(ctx: *Context) ![]const u8 {
        var buf: [4096]u8 = undefined;
        const r = ctx.request.readerExpectContinue(&buf) catch return error.BadRequest;
        return r.allocRemaining(ctx.arena, .limited(ctx.max_body)) catch |err| switch (err) {
            error.StreamTooLong => error.PayloadTooLarge,
            else => error.BadRequest,
        };
    }

    /// The body parsed as JSON into `T`. Unknown fields are ignored.
    pub fn json(ctx: *Context, comptime T: type) !T {
        const b = try ctx.body();
        return std.json.parseFromSliceLeaky(T, ctx.arena, b, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch error.BadRequest;
    }

    pub fn setHeader(ctx: *Context, name: []const u8, value: []const u8) !void {
        for (ctx.response_headers.items) |*h| if (std.ascii.eqlIgnoreCase(h.name, name)) {
            h.value = value;
            return;
        };
        try ctx.response_headers.append(ctx.arena, .{ .name = name, .value = value });
    }

    pub fn send(ctx: *Context, status: Status, content_type: []const u8, data: []const u8) !void {
        try ctx.setHeader("content-type", content_type);
        ctx.responded = true;
        try ctx.request.respond(data, .{ .status = status, .extra_headers = ctx.response_headers.items });
    }

    pub fn text(ctx: *Context, status: Status, s: []const u8) !void {
        return ctx.send(status, "text/plain; charset=utf-8", s);
    }

    /// `value` as JSON (structs, slices, numbers, strings, `std.json.Value`, ...).
    pub fn sendJson(ctx: *Context, status: Status, value: anytype) !void {
        var out: std.Io.Writer.Allocating = .init(ctx.arena);
        try std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &out.writer);
        return ctx.send(status, "application/json", out.written());
    }

    /// `{"error": message}` with `status`, the shape the Node servers use.
    pub fn fail(ctx: *Context, status: Status, message: []const u8) !void {
        return ctx.sendJson(status, .{ .@"error" = message });
    }

    /// Upgrades to a WebSocket if the client asked for one; null otherwise.
    pub fn webSocket(ctx: *Context) !?WebSocket {
        const k = switch (ctx.request.upgradeRequested()) {
            .websocket => |k| k orelse return null,
            else => return null,
        };
        ctx.responded = true;
        ctx.close_connection = true;
        var ws = try ctx.request.respondWebSocket(.{ .key = k, .extra_headers = ctx.response_headers.items });
        try ws.flush();
        return ws;
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

pub const EventStream = struct {
    body: std.http.BodyWriter,

    /// Sends one event. `data` may contain newlines; each line becomes a `data:` line.
    pub fn send(s: *EventStream, event: ?[]const u8, data: []const u8) !void {
        const w = &s.body.writer;
        if (event) |e| try w.print("event: {s}\n", .{e});
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| try w.print("data: {s}\n", .{line});
        try w.writeAll("\n");
        try s.body.flush();
    }

    /// A comment line, to keep idle connections open through proxies.
    pub fn ping(s: *EventStream) !void {
        try s.body.writer.writeAll(": ping\n\n");
        try s.body.flush();
    }

    pub fn end(s: *EventStream) !void {
        try s.body.end();
    }
};

/// Percent-decodes `s` (and `+` as space) into new memory.
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
            if (route.method) |m| if (m != ctx.method) continue;
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
                try ctx.params.append(ctx.arena, .{ .name = p[1..], .value = try decode(ctx.arena, si.rest()) });
                return true;
            }
            const s = si.next() orelse return p.len == 0;
            if (p.len > 0 and p[0] == ':') {
                if (s.len == 0) return false;
                try ctx.params.append(ctx.arena, .{ .name = p[1..], .value = try decode(ctx.arena, s) });
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
        exchange(io, gpa, &session.reader, &session.writer, options);
        session.end() catch {};
        return;
    }
    exchange(io, gpa, &reader.interface, &writer.interface, options);
}

/// Requests and responses on one connection, until either side ends it.
fn exchange(io: Io, gpa: std.mem.Allocator, in: *std.Io.Reader, out: *std.Io.Writer, options: *const Options) void {
    var server = std.http.Server.init(in, out);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    while (true) {
        _ = arena_state.reset(.retain_capacity);
        var request = server.receiveHead() catch return;
        const keep = handle(io, arena_state.allocator(), &request, options) catch return;
        if (!keep or !request.head.keep_alive) return;
    }
}

/// Returns whether the connection can take another request.
fn handle(io: Io, arena: std.mem.Allocator, request: *std.http.Server.Request, options: *const Options) !bool {
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
        .request = request,
        .method = request.head.method,
        .path = target[0 .. q orelse target.len],
        .query = if (q) |i| target[i + 1 ..] else "",
        .headers = headers.items,
        .max_body = options.max_body,
    };
    options.router.dispatch(&ctx) catch |err| {
        if (ctx.responded) return err;
        const status: Status = switch (err) {
            error.BadRequest, error.BadEncoding => .bad_request,
            error.PayloadTooLarge => .payload_too_large,
            else => .internal_server_error,
        };
        if (status == .internal_server_error) std.log.err("{s} {s}: {t}", .{ @tagName(ctx.method), ctx.path, err });
        try ctx.fail(status, status.phrase() orelse "Error");
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
    var rel = ctx.param("path") orelse (decode(ctx.arena, ctx.path) catch return ctx.fail(.bad_request, "Bad path"));
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
}
