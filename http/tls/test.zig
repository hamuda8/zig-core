//! Interop: std.crypto.tls.Client (which verifies the certificate, the host name, the
//! CertificateVerify signature and the Finished messages) talking to this server over TCP.

const std = @import("std");
const Server = @import("Server.zig");
const certs = @import("cert.zig");

const testing = std.testing;
const io = testing.io;
const Io = std.Io;

var port: std.atomic.Value(u16) = .init(0);
/// When non-zero, the server reads exactly this many bytes instead of one line.
var expect_bytes: usize = 0;

fn makeCert(a: std.mem.Allocator, names: []const []const u8) !certs.Certificate {
    const key = certs.KeyPair.generate(io);
    const now = Io.Timestamp.now(io, .real).toSeconds();
    const der = try certs.selfSigned(io, a, key, names, now - 3600, now + 86400);
    return certs.Certificate.init(try a.dupe([]const u8, &.{der}), key);
}

/// Accepts one connection, answers "pong <sni> <alpn> <what was sent>", closes properly.
fn serveOne(cert_list: []const certs.Certificate) !void {
    const addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    port.store(listener.socket.address.getPort(), .release);
    const stream = try listener.accept(io);
    defer stream.close(io);

    var in_buf: [Server.min_buffer_len]u8 = undefined;
    var out_buf: [Server.min_buffer_len]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    var writer = stream.writer(io, &out_buf);
    var read_buf: [Server.min_buffer_len]u8 = undefined;
    var write_buf: [1024]u8 = undefined;
    var tls = try Server.init(&reader.interface, &writer.interface, .{
        .io = io,
        .certificates = cert_list,
        .read_buffer = &read_buf,
        .write_buffer = &write_buf,
    });
    if (expect_bytes > 0) {
        var total: usize = 0;
        var sum: u64 = 0;
        while (total < expect_bytes) {
            const chunk = try tls.reader.peekGreedy(1);
            for (chunk) |b| sum += b;
            total += chunk.len;
            tls.reader.toss(chunk.len);
        }
        try tls.writer.print("got {d} {d}\n", .{ total, sum });
    } else {
        const line = try tls.reader.takeDelimiterExclusive('\n');
        try tls.writer.print("pong {s} {s} {s}\n", .{ tls.serverName(), tls.alpn orelse "-", line });
    }
    try tls.end();
}

fn exchange(host: []const u8, cert_list: []const certs.Certificate, message: []const u8, a: std.mem.Allocator) ![]u8 {
    port.store(0, .release);
    var server = try io.concurrent(serveOne, .{cert_list});
    defer server.await(io) catch {};
    while (port.load(.acquire) == 0) try io.sleep(.fromMilliseconds(2), .awake);

    const addr = try Io.net.IpAddress.parse("127.0.0.1", port.load(.acquire));
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var in_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var out_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    var writer = stream.writer(io, &out_buf);
    var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
    io.random(&entropy);
    var read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var write_buf: [1024]u8 = undefined;
    var client = try std.crypto.tls.Client.init(&reader.interface, &writer.interface, .{
        .host = .{ .explicit = host },
        .ca = .self_signed,
        .read_buffer = &read_buf,
        .write_buffer = &write_buf,
        .entropy = &entropy,
        .realtime_now = Io.Timestamp.now(io, .real),
    });
    try client.writer.print("{s}\n", .{message});
    try client.writer.flush();
    try writer.interface.flush();
    return a.dupe(u8, try client.reader.takeDelimiterExclusive('\n'));
}

test "std's TLS client completes a verified TLS 1.3 handshake and exchanges data" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = [_]certs.Certificate{try makeCert(a, &.{"localhost"})};
    const reply = try exchange("localhost", &list, "ping", a);
    // std's client sends SNI but no ALPN.
    try testing.expectEqualStrings("pong localhost - ping", reply);
}

test "SNI picks the matching certificate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = [_]certs.Certificate{ try makeCert(a, &.{"maps.wufour.test"}), try makeCert(a, &.{"reseal.wufour.test"}) };
    // The client verifies the certificate is for this host, so the second one must be chosen.
    const reply = try exchange("reseal.wufour.test", &list, "hi", a);
    try testing.expectEqualStrings("pong reseal.wufour.test - hi", reply);
}

test "large application data spans many records" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = [_]certs.Certificate{try makeCert(a, &.{"localhost"})};
    const big = try a.alloc(u8, 100_000);
    @memset(big, 'x');
    expect_bytes = big.len + 1; // the message and its newline
    defer expect_bytes = 0;
    const reply = try exchange("localhost", &list, big, a);
    var expected_sum: u64 = '\n';
    for (big) |b| expected_sum += b;
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "got {d} {d}", .{ big.len + 1, expected_sum }), reply);
}
