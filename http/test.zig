//! Tests that run a real server on a random local port and talk to it over TCP.

const std = @import("std");
const http = @import("http.zig");
const Io = std.Io;

const testing = std.testing;
const io = testing.io;

var bound: std.atomic.Value(u16) = .init(0);

fn onListen(addr: Io.net.IpAddress) void {
    bound.store(addr.getPort(), .release);
}

fn healthz(ctx: *http.Context) !void {
    try ctx.sendJson(.ok, .{ .ok = true });
}

fn item(ctx: *http.Context) !void {
    try ctx.sendJson(.ok, .{ .id = ctx.param("id").?, .q = ctx.queryParam("q") orelse "" });
}

fn sum(ctx: *http.Context) !void {
    const in = try ctx.json(struct { a: i64, b: i64 });
    try ctx.sendJson(.ok, .{ .sum = in.a + in.b });
}

fn rest(ctx: *http.Context) !void {
    try ctx.text(.ok, ctx.param("path").?);
}

fn guard(ctx: *http.Context) !void {
    if (std.mem.startsWith(u8, ctx.path, "/private") and ctx.header("authorization") == null) {
        try ctx.fail(.unauthorized, "Sign in");
    }
}

fn events(ctx: *http.Context) !void {
    var buf: [256]u8 = undefined;
    var s = try ctx.eventStream(&buf);
    try s.send("hello", "one");
    try s.send(null, "two\nlines");
    try s.end();
}

fn echoSocket(ctx: *http.Context) !void {
    var ws = (try ctx.webSocket()) orelse return ctx.fail(.bad_request, "WebSocket only");
    const msg = try ws.readSmallMessage();
    try ws.writeMessage(msg.data, .text);
}

fn startServer(router: *const http.Router) !Io.Future(anyerror!void) {
    bound.store(0, .release);
    const f = try io.concurrent(runServer, .{router});
    while (bound.load(.acquire) == 0) try io.sleep(.fromMilliseconds(5), .awake);
    return f;
}

fn runServer(router: *const http.Router) anyerror!void {
    try http.serve(io, testing.allocator, .{
        .address = try .parse("127.0.0.1", 0),
        .router = router,
        .on_listen = onListen,
    });
}

/// Sends `raw` and returns everything the server writes until it closes.
fn roundTrip(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    const addr = try Io.net.IpAddress.parse("127.0.0.1", bound.load(.acquire));
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [1024]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll(raw);
    try w.interface.flush();
    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    return r.interface.allocRemaining(gpa, .limited(1 << 20));
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedContains;
    }
}

test "routes, params, query, JSON body, errors, middleware, keep-alive" {
    var router: http.Router = .init(testing.allocator);
    defer router.deinit();
    try router.use(guard);
    try router.get("/healthz", healthz);
    try router.get("/items/:id", item);
    try router.post("/sum", sum);
    try router.get("/files/*path", rest);
    try router.get("/private/data", healthz);

    var server = try startServer(&router);
    defer _ = server.cancel(io) catch {};

    const a = testing.allocator;
    var res = try roundTrip(a, "GET /healthz HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n");
    try expectContains(res, "HTTP/1.1 200 OK");
    try expectContains(res, "{\"ok\":true}");
    a.free(res);

    res = try roundTrip(a, "GET /items/42?q=hello%20world&x=1 HTTP/1.1\r\nconnection: close\r\n\r\n");
    try expectContains(res, "{\"id\":\"42\",\"q\":\"hello world\"}");
    a.free(res);

    res = try roundTrip(a, "POST /sum HTTP/1.1\r\ncontent-type: application/json\r\ncontent-length: 15\r\nconnection: close\r\n\r\n{\"a\":2,\"b\":40}\n");
    try expectContains(res, "{\"sum\":42}");
    a.free(res);

    res = try roundTrip(a, "POST /sum HTTP/1.1\r\ncontent-length: 3\r\nconnection: close\r\n\r\nxyz");
    try expectContains(res, "400 Bad Request");
    a.free(res);

    // No Content-Length on a POST: an empty body, not a crash.
    res = try roundTrip(a, "POST /healthz HTTP/1.1\r\nconnection: close\r\n\r\n");
    try expectContains(res, "405 Method Not Allowed");
    a.free(res);
    res = try roundTrip(a, "POST /sum HTTP/1.1\r\nconnection: close\r\n\r\n");
    try expectContains(res, "400 Bad Request");
    a.free(res);

    res = try roundTrip(a, "GET /files/a/b%20c.txt HTTP/1.1\r\nconnection: close\r\n\r\n");
    try expectContains(res, "a/b c.txt");
    a.free(res);

    res = try roundTrip(a, "GET /nope HTTP/1.1\r\nconnection: close\r\n\r\n");
    try expectContains(res, "404 Not Found");
    a.free(res);

    res = try roundTrip(a, "DELETE /healthz HTTP/1.1\r\nconnection: close\r\n\r\n");
    try expectContains(res, "405 Method Not Allowed");
    a.free(res);

    res = try roundTrip(a, "GET /private/data HTTP/1.1\r\nconnection: close\r\n\r\n");
    try expectContains(res, "401 Unauthorized");
    a.free(res);

    // Two requests on one connection.
    res = try roundTrip(a, "GET /healthz HTTP/1.1\r\n\r\nGET /items/7 HTTP/1.1\r\nconnection: close\r\n\r\n");
    try expectContains(res, "{\"ok\":true}");
    try expectContains(res, "{\"id\":\"7\",\"q\":\"\"}");
    a.free(res);
}

test "server-sent events" {
    var router: http.Router = .init(testing.allocator);
    defer router.deinit();
    try router.get("/events", events);
    var server = try startServer(&router);
    defer _ = server.cancel(io) catch {};

    const res = try roundTrip(testing.allocator, "GET /events HTTP/1.1\r\n\r\n");
    defer testing.allocator.free(res);
    try expectContains(res, "content-type: text/event-stream");
    try expectContains(res, "event: hello\ndata: one\n\n");
    try expectContains(res, "data: two\ndata: lines\n\n");
}

test "websocket echo" {
    var router: http.Router = .init(testing.allocator);
    defer router.deinit();
    try router.get("/ws", echoSocket);
    var server = try startServer(&router);
    defer _ = server.cancel(io) catch {};

    // Handshake plus one masked text frame "hi" (mask 1,2,3,4), then the server echoes it.
    const frame = [_]u8{ 0x81, 0x82, 1, 2, 3, 4, 'h' ^ 1, 'i' ^ 2 };
    const res = try roundTrip(testing.allocator, "GET /ws HTTP/1.1\r\nhost: x\r\nconnection: upgrade\r\nupgrade: websocket\r\n" ++
        "sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\nsec-websocket-version: 13\r\n\r\n" ++ frame);
    defer testing.allocator.free(res);
    try expectContains(res, "101 Switching Protocols");
    // The RFC 6455 example key gives this accept value.
    try expectContains(res, "sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
    try expectContains(res, &.{ 0x81, 0x02, 'h', 'i' });
}

test "content types and decoding" {
    try testing.expectEqualStrings("application/wasm", http.contentType("app.wasm"));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("a b/c", try http.decode(arena.allocator(), "a+b%2Fc"));
}

test "HTTPS: the router behind the TLS 1.3 server, checked by std's verifying client" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = http.tls.cert.KeyPair.generate(io);
    const now = Io.Timestamp.now(io, .real).toSeconds();
    const der = try http.tls.cert.selfSigned(io, a, key, &.{"localhost"}, now - 60, now + 3600);
    var store: http.CertStore = .{ .certificates = &.{try http.tls.cert.Certificate.init(try a.dupe([]const u8, &.{der}), key)} };

    var router: http.Router = .init(testing.allocator);
    defer router.deinit();
    try router.get("/healthz", healthz);
    bound.store(0, .release);
    var server = try io.concurrent(runTlsServer, .{ &router, &store });
    defer _ = server.cancel(io) catch {};
    while (bound.load(.acquire) == 0) try io.sleep(.fromMilliseconds(5), .awake);

    const addr = try Io.net.IpAddress.parse("127.0.0.1", bound.load(.acquire));
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    const Client = std.crypto.tls.Client;
    var in_buf: [Client.min_buffer_len]u8 = undefined;
    var out_buf: [Client.min_buffer_len]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    var writer = stream.writer(io, &out_buf);
    var entropy: [Client.Options.entropy_len]u8 = undefined;
    io.random(&entropy);
    var read_buf: [Client.min_buffer_len]u8 = undefined;
    var write_buf: [1024]u8 = undefined;
    var client = try Client.init(&reader.interface, &writer.interface, .{
        .host = .{ .explicit = "localhost" },
        .ca = .self_signed,
        .read_buffer = &read_buf,
        .write_buffer = &write_buf,
        .entropy = &entropy,
        .realtime_now = Io.Timestamp.now(io, .real),
    });
    try client.writer.writeAll("GET /healthz HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n");
    try client.writer.flush();
    try writer.interface.flush();
    var body: std.ArrayList(u8) = .empty;
    while (true) {
        const chunk = client.reader.peekGreedy(1) catch break;
        try body.appendSlice(a, chunk);
        client.reader.toss(chunk.len);
    }
    try expectContains(body.items, "HTTP/1.1 200 OK");
    try expectContains(body.items, "{\"ok\":true}");
}

fn runTlsServer(router: *const http.Router, store: *http.CertStore) anyerror!void {
    try http.serve(io, testing.allocator, .{
        .address = try .parse("127.0.0.1", 0),
        .router = router,
        .on_listen = onListen,
        .tls = store,
    });
}

test "port 80: ACME challenges are answered, everything else redirects to HTTPS" {
    var challenges: http.tls.acme.Challenges = .{ .gpa = testing.allocator };
    defer {
        var it = challenges.map.iterator();
        while (it.next()) |e| {
            testing.allocator.free(e.key_ptr.*);
            testing.allocator.free(e.value_ptr.*);
        }
        challenges.map.deinit(testing.allocator);
    }
    try challenges.put(io, "tok123", "tok123.thumb");
    http.acme_challenges = &challenges;
    defer http.acme_challenges = null;

    var router: http.Router = .init(testing.allocator);
    defer router.deinit();
    router.fallback = http.redirectToHttps;
    var server = try startServer(&router);
    defer _ = server.cancel(io) catch {};

    const a = testing.allocator;
    var res = try roundTrip(a, "GET /.well-known/acme-challenge/tok123 HTTP/1.1\r\nhost: maps.wufour.com\r\nconnection: close\r\n\r\n");
    try expectContains(res, "200 OK");
    try expectContains(res, "tok123.thumb");
    a.free(res);
    res = try roundTrip(a, "GET /.well-known/acme-challenge/nope HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n");
    try expectContains(res, "404 Not Found");
    a.free(res);
    res = try roundTrip(a, "GET /map?lat=1 HTTP/1.1\r\nhost: maps.wufour.com:80\r\nconnection: close\r\n\r\n");
    try expectContains(res, "301 Moved Permanently");
    try expectContains(res, "location: https://maps.wufour.com/map?lat=1");
    a.free(res);
}
