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
    if (!ctx.wantsWebSocket()) return ctx.fail(.bad_request, "WebSocket only");
    var sock = try ctx.webSocket();
    const msg = try sock.read();
    try sock.sendText(msg.data);
    sock.close(1000);
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

fn echoBody(ctx: *http.Context) !void {
    const b = try ctx.body();
    try ctx.text(.ok, b);
}

fn headerEcho(ctx: *http.Context) !void {
    try ctx.setHeader("x-next", ctx.queryParam("next") orelse "");
    try ctx.addHeader("set-cookie", "a=1");
    try ctx.addHeader("set-cookie", "b=2");
    try ctx.text(.ok, ctx.cookie("tok") orelse "none");
}

fn file(ctx: *http.Context) !void {
    const data = "0123456789";
    const short = ctx.queryParam("short") != null;
    var buf: [64]u8 = undefined;
    switch (ctx.range(data.len)) {
        .unsatisfiable => return ctx.unsatisfiable(data.len),
        .partial => |p| {
            const len = try ctx.partial(p.start, p.last, data.len);
            var s = try ctx.startBody(&buf, .partial_content, "text/plain", len);
            try s.write(data[@intCast(p.start)..@intCast(p.last + 1)]);
            return s.finish();
        },
        .full => {
            var s = try ctx.startBody(&buf, .ok, "text/plain", data.len);
            // A file that turns out shorter than promised must not crash the server.
            try s.write(if (short) data[0..4] else data);
            return s.finish();
        },
    }
}

test "bodies on any method, oversized bodies, header values, cookies" {
    var router: http.Router = .init(testing.allocator);
    defer router.deinit();
    try router.add(null, "/echo", echoBody);
    try router.get("/headers", headerEcho);
    var server = try startServer(&router);
    defer _ = server.cancel(io) catch {};
    const a = testing.allocator;

    // A DELETE body is read (std.http ignores it) and the next request on the connection works.
    var res = try roundTrip(a, "DELETE /echo HTTP/1.1\r\ncontent-length: 5\r\n\r\nhelloGET /headers HTTP/1.1\r\nconnection: close\r\n\r\n");
    try expectContains(res, "\r\n\r\nhello");
    try expectContains(res, "none");
    a.free(res);
    // A GET body the handler never reads must not become the next request either.
    res = try roundTrip(a, "GET /headers HTTP/1.1\r\ncontent-length: 4\r\n\r\nxxxxGET /headers HTTP/1.1\r\nconnection: close\r\n\r\n");
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, res, "HTTP/1.1 200 OK"));
    a.free(res);

    // Over the limit: 413, the rest of the body is read away, the connection keeps working.
    const big = try a.alloc(u8, 2 * 1024 * 1024);
    defer a.free(big);
    @memset(big, 'x');
    const head = try std.fmt.allocPrint(a, "POST /echo HTTP/1.1\r\ncontent-length: {d}\r\n\r\n", .{big.len});
    defer a.free(head);
    const req = try std.mem.concat(a, u8, &.{ head, big, "GET /headers HTTP/1.1\r\nconnection: close\r\n\r\n" });
    defer a.free(req);
    res = try roundTrip(a, req);
    try expectContains(res, "413 Payload Too Large");
    try expectContains(res, "none");
    a.free(res);

    // CR/LF in a header value (from the query here) is neutralized, not an assertion failure.
    res = try roundTrip(a, "GET /headers?next=%0D%0Aset-cookie:%20evil=1 HTTP/1.1\r\ncookie: tok=a%20b; tok=c%2Fd\r\nconnection: close\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, res, "\r\nset-cookie: evil") == null);
    try expectContains(res, "set-cookie: a=1\r\nset-cookie: b=2\r\n");
    // Cookies are percent-decoded, and a repeated one gives its last value.
    try expectContains(res, "\r\n\r\nc/d");
    a.free(res);
}

test "ranges, HEAD and short bodies" {
    var router: http.Router = .init(testing.allocator);
    defer router.deinit();
    try router.get("/file", file);
    var server = try startServer(&router);
    defer _ = server.cancel(io) catch {};
    const a = testing.allocator;

    var res = try roundTrip(a, "GET /file HTTP/1.1\r\nrange: bytes=2-4\r\nconnection: close\r\n\r\n");
    try expectContains(res, "206 Partial Content");
    try expectContains(res, "content-range: bytes 2-4/10");
    try expectContains(res, "\r\n\r\n234");
    a.free(res);
    res = try roundTrip(a, "GET /file HTTP/1.1\r\nrange: bytes=-3\r\nconnection: close\r\n\r\n");
    try expectContains(res, "\r\n\r\n789");
    a.free(res);
    res = try roundTrip(a, "GET /file HTTP/1.1\r\nrange: bytes=20-30\r\nconnection: close\r\n\r\n");
    try expectContains(res, "416 Range Not Satisfiable");
    try expectContains(res, "content-range: bytes */10");
    a.free(res);
    // HEAD: the length, no body, and the connection still answers.
    res = try roundTrip(a, "HEAD /file HTTP/1.1\r\n\r\nGET /file HTTP/1.1\r\nrange: bytes=0-0\r\nconnection: close\r\n\r\n");
    try expectContains(res, "content-length: 10");
    try expectContains(res, "\r\n\r\nHTTP/1.1 206");
    a.free(res);
    // Short: the connection is closed after what there is, and the server lives on.
    res = try roundTrip(a, "GET /file?short=1 HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, res, "\r\n\r\n0123"));
    a.free(res);
    res = try roundTrip(a, "GET /file HTTP/1.1\r\nconnection: close\r\n\r\n");
    try expectContains(res, "0123456789");
    a.free(res);
    try testing.expectEqual(http.Range.full, http.parseRange("bytes=1-2,4-5", 10));
}

fn echoSocketLarge(ctx: *http.Context) !void {
    var sock = try ctx.webSocket();
    defer sock.deinit();
    sock.max_payload = 512 * 1024;
    sock.queued = true;
    var writer: Io.Group = .init;
    try writer.concurrent(io, http.ws.Socket.writerLoop, .{&sock});
    defer {
        sock.close(1000);
        writer.await(io) catch {};
    }
    while (true) {
        const f = sock.read() catch return;
        if (f.op != .text) continue;
        try sock.sendText(f.data);
        if (std.mem.eql(u8, f.data, "bye")) return;
    }
}

fn maskedFrame(a: std.mem.Allocator, out: *std.ArrayList(u8), fin: bool, op: u8, payload: []const u8) !void {
    try out.append(a, (if (fin) @as(u8, 0x80) else 0) | op);
    if (payload.len < 126) {
        try out.append(a, 0x80 | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= 0xffff) {
        try out.append(a, 0x80 | 126);
        var n: [2]u8 = undefined;
        std.mem.writeInt(u16, &n, @intCast(payload.len), .big);
        try out.appendSlice(a, &n);
    } else {
        try out.append(a, 0x80 | 127);
        var n: [8]u8 = undefined;
        std.mem.writeInt(u64, &n, payload.len, .big);
        try out.appendSlice(a, &n);
    }
    const mask = [4]u8{ 9, 8, 7, 6 };
    try out.appendSlice(a, &mask);
    for (payload, 0..) |b, i| try out.append(a, b ^ mask[i % 4]);
}

test "websocket: fragmented and large messages, queued sending" {
    var router: http.Router = .init(testing.allocator);
    defer router.deinit();
    try router.get("/ws", echoSocketLarge);
    var server = try startServer(&router);
    defer _ = server.cancel(io) catch {};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var req: std.ArrayList(u8) = .empty;
    try req.appendSlice(a, "GET /ws HTTP/1.1\r\nhost: x\r\nconnection: upgrade\r\nupgrade: websocket\r\nsec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\nsec-websocket-version: 13\r\n\r\n");
    // "hel" + a ping + "lo" in two fragments, then a 100 KB message (bigger than the read buffer).
    try maskedFrame(a, &req, false, 1, "hel");
    try maskedFrame(a, &req, true, 9, "p");
    try maskedFrame(a, &req, true, 0, "lo");
    const large = try a.alloc(u8, 100 * 1024);
    @memset(large, 'z');
    try maskedFrame(a, &req, true, 1, large);
    try maskedFrame(a, &req, true, 1, "bye");
    const res = try roundTrip(testing.allocator, req.items);
    defer testing.allocator.free(res);
    try expectContains(res, "101 Switching Protocols");
    try expectContains(res, &.{ 0x8a, 0x01, 'p' }); // the pong
    try expectContains(res, &.{ 0x81, 0x05, 'h', 'e', 'l', 'l', 'o' });
    try expectContains(res, &.{ 0x81, 127, 0, 0, 0, 0, 0, 1, 0x90, 0 }); // 102400 bytes echoed
    try expectContains(res, &.{ 0x81, 0x03, 'b', 'y', 'e' });
    try expectContains(res, &.{ 0x88, 0x02, 0x03, 0xe8 }); // close 1000
}

var test_hub: http.sse.Hub = undefined;

fn live(ctx: *http.Context) !void {
    test_hub.serve(ctx, "1.2.3.4", &.{ "a", "b" }, .{ .first = "event: hello\ndata: {}\n\n" }) catch |e| switch (e) {
        error.TooManyStreams => return ctx.fail(.too_many_requests, "Too many open streams"),
        else => return e,
    };
}

/// Reads from `r` until `needle` has arrived (the stream stays open).
fn readUntil(r: *Io.Reader, got: *std.ArrayList(u8), needle: []const u8) !void {
    while (std.mem.indexOf(u8, got.items, needle) == null) {
        const b = try r.takeByte();
        try got.append(testing.allocator, b);
    }
}

test "server-sent events: fan-out arrives while the stream stays open, one stream per address" {
    test_hub = .init(io, testing.allocator);
    defer test_hub.deinit();
    test_hub.max_per_ip = 1;
    var router: http.Router = .init(testing.allocator);
    defer router.deinit();
    try router.get("/live", live);
    var server = try startServer(&router);
    defer _ = server.cancel(io) catch {};

    const addr = try Io.net.IpAddress.parse("127.0.0.1", bound.load(.acquire));
    var stream = try addr.connect(io, .{ .mode = .stream });
    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll("GET /live HTTP/1.1\r\n\r\n");
    try w.interface.flush();
    var rbuf: [1024]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    try readUntil(&r.interface, &got, "event: hello\ndata: {}\n\n");
    try expectContains(got.items, "content-type: text/event-stream; charset=utf-8");
    try expectContains(got.items, "retry: 5000\n\n");

    while (!test_hub.hasSubscribers("b")) try io.sleep(.fromMilliseconds(5), .awake);
    test_hub.publish("b", "shipment", "{\"id\":1}");
    try readUntil(&r.interface, &got, "event: shipment\ndata: {\"id\":1}\n\n");

    // A second stream from the same address is refused.
    const res = try roundTrip(testing.allocator, "GET /live HTTP/1.1\r\nconnection: close\r\n\r\n");
    defer testing.allocator.free(res);
    try expectContains(res, "429");

    // The client leaves: its place is freed.
    stream.close(io);
    while (test_hub.hasSubscribers("a")) try io.sleep(.fromMilliseconds(5), .awake);
}

fn slowEvents(ctx: *http.Context) !void {
    var buf: [256]u8 = undefined;
    var s = try ctx.eventStream(&buf);
    try s.send("first", "now");
    try io.sleep(.fromSeconds(3), .awake);
    try s.end();
}

test "event stream: each event goes out when sent" {
    var router: http.Router = .init(testing.allocator);
    defer router.deinit();
    try router.get("/slow", slowEvents);
    var server = try startServer(&router);
    defer _ = server.cancel(io) catch {};
    const addr = try Io.net.IpAddress.parse("127.0.0.1", bound.load(.acquire));
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll("GET /slow HTTP/1.1\r\n\r\n");
    try w.interface.flush();
    var rbuf: [1024]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    const start = Io.Clock.awake.now(io);
    try readUntil(&r.interface, &got, "event: first\ndata: now\n\n");
    try testing.expect(start.durationTo(Io.Clock.awake.now(io)).toMilliseconds() < 2000);
}
