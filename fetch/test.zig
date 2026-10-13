const std = @import("std");
const fetch = @import("fetch.zig");
const Io = std.Io;
const testing = std.testing;
const io = testing.io;

/// A keep-alive server: "ok" to every request, on any number of connections.
fn okServer(listener: *Io.net.Server) void {
    var conns: Io.Group = .init;
    defer conns.cancel(io);
    while (true) {
        const stream = listener.accept(io) catch return;
        conns.concurrent(io, okConnection, .{stream}) catch stream.close(io);
    }
}

fn okConnection(stream: Io.net.Stream) void {
    defer stream.close(io);
    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    while (true) {
        // The request head (the tests send no bodies).
        var last: [4]u8 = .{ 0, 0, 0, 0 };
        while (!std.mem.eql(u8, &last, "\r\n\r\n")) {
            const b = r.interface.takeByte() catch return;
            last = .{ last[1], last[2], last[3], b };
        }
        w.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok") catch return;
        w.interface.flush() catch return;
    }
}

/// Accepts connections and never answers.
fn silentServer(listener: *Io.net.Server) void {
    const stream = listener.accept(io) catch return;
    defer stream.close(io);
    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    _ = r.interface.discardRemaining() catch {};
}

fn listen() !Io.net.Server {
    const addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
    return addr.listen(io, .{ .reuse_address = true });
}

/// The idle pooled connection breaks the way a reset from the other side breaks it: writes to it
/// fail from now on (reads would see the end of the stream).
fn breakIdleConnection(client: *std.http.Client) void {
    const node = client.connection_pool.free.last.?;
    const conn: *std.http.Client.Connection = @alignCast(@fieldParentPtr("pool_node", node));
    conn.stream_writer.stream.shutdown(io, .send) catch {};
}

/// What Maps did before: std.http.Client with keep-alive and one retry.
fn naive(client: *std.http.Client, url: []const u8) !void {
    return naiveOnce(client, url) catch naiveOnce(client, url);
}

fn naiveOnce(client: *std.http.Client, url: []const u8) !void {
    var req = try client.request(.GET, try std.Uri.parse(url), .{ .keep_alive = true });
    defer req.deinit();
    try req.sendBodiless();
    var res = try req.receiveHead(&.{});
    var transfer: [64]u8 = undefined;
    _ = try res.reader(&transfer).discardRemaining();
}

test "a broken pooled connection is not handed out again (Maps' 502s)" {
    const a = testing.allocator;
    var listener = try listen();
    defer listener.deinit(io);
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/tile", .{listener.socket.address.getPort()});
    defer a.free(url);
    var server = try io.concurrent(okServer, .{&listener});
    defer server.cancel(io);

    // std.http.Client alone: a failed send leaves the connection marked reusable, so it goes
    // back to the pool, and the pool hands out its newest idle connection first: that one.
    // Every later request to the host fails at once, the retry too, until a restart. If this
    // starts failing, std fixed it.
    {
        var client: std.http.Client = .{ .allocator = a, .io = io };
        defer client.deinit();
        try naive(&client, url);
        breakIdleConnection(&client);
        for (0..3) |_| try testing.expect(std.meta.isError(naive(&client, url)));
    }

    // fetch: the request after the breakage succeeds, and so do the following ones.
    {
        var client: fetch.Client = .init(io, a);
        defer client.deinit();
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        _ = try client.fetch(arena.allocator(), url, .{});
        breakIdleConnection(&client.http);
        for (0..3) |_| {
            const res = try client.fetch(arena.allocator(), url, .{ .timeout_ms = 2000 });
            try testing.expectEqual(@as(u16, 200), res.status);
            try testing.expectEqualStrings("ok", res.body);
        }
        // Without a retry the request itself fails, but the broken connection is gone after it.
        breakIdleConnection(&client.http);
        try testing.expectError(error.FetchFailed, client.fetch(arena.allocator(), url, .{ .retry = false }));
        _ = try client.fetch(arena.allocator(), url, .{ .retry = false });
    }
}

test "time limit: a server that never answers" {
    const a = testing.allocator;
    var listener = try listen();
    defer listener.deinit(io);
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/", .{listener.socket.address.getPort()});
    defer a.free(url);
    var server = try io.concurrent(silentServer, .{&listener});
    defer server.cancel(io);
    var client: fetch.Client = .init(io, a);
    defer client.deinit(); // returns: the request's socket was shut down at the deadline
    try testing.expectError(error.Timeout, client.fetch(a, url, .{ .timeout_ms = 200 }));
}

test "private addresses" {
    var client: fetch.Client = .init(io, testing.allocator);
    defer client.deinit();
    try testing.expectError(error.Unreachable, client.assertPublicUrl("http://127.0.0.1:8080/"));
    try testing.expectError(error.Unreachable, client.assertPublicUrl("http://[::1]/"));
    try testing.expectError(error.Unreachable, client.assertPublicUrl("http://192.168.1.4/"));
    try testing.expectError(error.NotHttp, client.assertPublicUrl("file:///etc/passwd"));
    try client.assertPublicUrl("https://1.1.1.1/");
    client.allow_private = true;
    try client.assertPublicUrl("http://127.0.0.1:8080/");
}
