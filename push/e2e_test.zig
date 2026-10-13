//! End to end on this machine: apns.Client -> h2.Connection -> tls_client (ALPN h2) -> our
//! TLS 1.3 server (http/tls) running a small HTTP/2 responder that plays APNs. Covers the
//! handshake with ALPN, HPACK both ways, a 200 and a 400 with a reason, the bearer token, and
//! the reconnect after APNs sends GOAWAY.

const std = @import("std");
const http = @import("http");
const h2 = @import("h2.zig");
const hpack = @import("hpack.zig");
const apns = @import("apns.zig");
const jwt = @import("jwt.zig");

const TlsServer = http.tls.Server;
const certs = http.tls.cert;
const testing = std.testing;
const io = testing.io;
const Io = std.Io;
const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

var port: std.atomic.Value(u16) = .init(0);
/// What the fake APNs saw, per request.
const Seen = struct { path: [128]u8 = undefined, path_len: usize = 0, auth: [512]u8 = undefined, auth_len: usize = 0, topic: [64]u8 = undefined, topic_len: usize = 0, push_type: [16]u8 = undefined, push_type_len: usize = 0, priority: u8 = 0, body_len: usize = 0, stream: u31 = 0 };
var seen: [8]Seen = @splat(.{});
var seen_count: usize = 0;
var connections: usize = 0;

fn copy(dst: []u8, len: *usize, src: []const u8) void {
    len.* = @min(dst.len, src.len);
    @memcpy(dst[0..len.*], src[0..len.*]);
}

/// Serves two connections. The first gets GOAWAY after two requests.
fn fakeApns(cert_list: []const certs.Certificate) !void {
    const addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    port.store(listener.socket.address.getPort(), .release);
    for (0..2) |n| {
        const stream = try listener.accept(io);
        defer stream.close(io);
        connections += 1;
        try serveConnection(stream, cert_list, if (n == 0) 2 else 100);
    }
}

fn serveConnection(stream: Io.net.Stream, cert_list: []const certs.Certificate, limit: usize) !void {
    var in_buf: [TlsServer.min_buffer_len]u8 = undefined;
    var out_buf: [TlsServer.min_buffer_len]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    var writer = stream.writer(io, &out_buf);
    var read_buf: [TlsServer.min_buffer_len]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var tls = try TlsServer.init(&reader.interface, &writer.interface, .{
        .io = io,
        .certificates = cert_list,
        .alpn = &.{ "h2", "http/1.1" },
        .read_buffer = &read_buf,
        .write_buffer = &write_buf,
    });
    try testing.expectEqualStrings("h2", tls.alpn.?);
    const r = &tls.reader;
    const w = &tls.writer;
    const flush = struct {
        fn f(t: *TlsServer, sw: *Io.Writer) !void {
            try t.writer.flush();
            try sw.flush();
        }
    }.f;

    try testing.expectEqualStrings(h2.preface, try r.take(h2.preface.len));
    try h2.writeFrame(w, .{ .len = 0, .type = .settings }, &h2.settingsPayload(1, .{.{ .max_concurrent_streams, 100 }}));
    try flush(&tls, &writer.interface);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var decoder = hpack.Decoder.init(testing.allocator, 4096);
    defer decoder.deinit();
    var encoder: hpack.Encoder = .{};
    var block: std.ArrayList(u8) = .empty;
    var fields: std.ArrayList(hpack.Header) = .empty;
    var body_len: usize = 0;
    var served: usize = 0;
    while (true) {
        const head = r.takeArray(9) catch return; // the client closed
        const h: h2.FrameHeader = .decode(head.*);
        const payload = try r.take(h.len);
        var end_stream = false;
        switch (h.type) {
            .settings => if (h.flags & h2.flag.ack == 0) {
                try h2.writeFrame(w, .{ .len = 0, .type = .settings, .flags = h2.flag.ack }, "");
                try flush(&tls, &writer.interface);
            },
            .headers, .continuation => {
                try block.appendSlice(arena, payload);
                if (h.flags & h2.flag.end_headers != 0) {
                    fields.clearRetainingCapacity();
                    try decoder.decode(arena, block.items, &fields);
                    block.clearRetainingCapacity();
                    body_len = 0;
                }
                end_stream = h.flags & h2.flag.end_stream != 0;
            },
            .data => {
                body_len += h.len;
                end_stream = h.flags & h2.flag.end_stream != 0;
            },
            .goaway => return,
            else => {},
        }
        if (!end_stream) continue;

        // A whole request: note it, answer like APNs.
        const s = &seen[seen_count];
        seen_count += 1;
        s.stream = h.stream;
        s.body_len = body_len;
        for (fields.items) |f| {
            if (std.mem.eql(u8, f.name, ":path")) copy(&s.path, &s.path_len, f.value);
            if (std.mem.eql(u8, f.name, "authorization")) copy(&s.auth, &s.auth_len, f.value);
            if (std.mem.eql(u8, f.name, "apns-topic")) copy(&s.topic, &s.topic_len, f.value);
            if (std.mem.eql(u8, f.name, "apns-push-type")) copy(&s.push_type, &s.push_type_len, f.value);
            if (std.mem.eql(u8, f.name, "apns-priority")) s.priority = try std.fmt.parseInt(u8, f.value, 10);
        }
        const bad = std.mem.endsWith(u8, s.path[0..s.path_len], "bad0");
        var out: Io.Writer.Allocating = .init(arena);
        try encoder.encode(&out.writer, &.{
            .{ .name = ":status", .value = if (bad) "400" else "200" },
            .{ .name = "apns-id", .value = "A1B2C3D4-0000-1111-2222-333344445555" },
        });
        if (bad) {
            try h2.writeFrame(w, .{ .len = 0, .type = .headers, .flags = h2.flag.end_headers, .stream = h.stream }, out.written());
            try h2.writeFrame(w, .{ .len = 0, .type = .data, .flags = h2.flag.end_stream, .stream = h.stream }, "{\"reason\":\"BadDeviceToken\"}");
        } else {
            try h2.writeFrame(w, .{ .len = 0, .type = .headers, .flags = h2.flag.end_headers | h2.flag.end_stream, .stream = h.stream }, out.written());
        }
        served += 1;
        if (served == limit) {
            // Like APNs closing an idle connection: GOAWAY naming the last stream, then close.
            try h2.writeFrame(w, .{ .len = 0, .type = .goaway }, &h2.goawayPayload(h.stream, .no_error));
            try flush(&tls, &writer.interface);
            try tls.end();
            return;
        }
        try flush(&tls, &writer.interface);
    }
}

/// A .p8 file for `secret`: PKCS#8 around an EC P-256 private key.
fn p8(a: std.mem.Allocator, secret: [32]u8) ![]u8 {
    const der = [_]u8{ 0x30, 0x41, 0x02, 0x01, 0x00, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x04, 0x27, 0x30, 0x25, 0x02, 0x01, 0x01, 0x04, 0x20 } ++ secret;
    var b64: [std.base64.standard.Encoder.calcSize(der.len)]u8 = undefined;
    return std.fmt.allocPrint(a, "-----BEGIN PRIVATE KEY-----\n{s}\n-----END PRIVATE KEY-----\n", .{std.base64.standard.Encoder.encode(&b64, &der)});
}

test "APNs client against a local TLS + HTTP/2 server" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const server_key = certs.KeyPair.generate(io);
    const now = Io.Timestamp.now(io, .real).toSeconds();
    const der = try certs.selfSigned(io, a, server_key, &.{"localhost"}, now - 3600, now + 86400);
    const cert_list = [_]certs.Certificate{try certs.Certificate.init(try a.dupe([]const u8, &.{der}), server_key)};

    port.store(0, .release);
    var server = try io.concurrent(fakeApns, .{&cert_list});
    var awaited = false;
    defer if (!awaited) server.cancel(io) catch {};
    while (port.load(.acquire) == 0) try io.sleep(.fromMilliseconds(2), .awake);

    const kp = try EcdsaP256.KeyPair.generateDeterministic(@splat(5));
    var c = try apns.Client.init(testing.allocator, io, .{
        .team_id = "TEAM000001",
        .key_id = "KEY0000001",
        .private_key = try p8(a, kp.secret_key.toBytes()),
        .bundle_id = "com.wufour.test",
    });
    defer c.deinit();
    c.host_override = "localhost";
    c.port = port.load(.acquire);
    c.ca = .self_signed;

    // 1: an alert, accepted.
    const r1 = try c.send("00aa11bb", "{\"aps\":{\"alert\":\"hi\"}}", .{ .environment = .sandbox });
    try testing.expectEqual(@as(u16, 200), r1.status);
    try testing.expectEqualStrings("A1B2C3D4-0000-1111-2222-333344445555", r1.apnsId());
    try testing.expectEqualStrings("", r1.reason());

    // 2: a VoIP push to a bad token, on the same connection (stream 3).
    const r2 = try c.send("bad0", "{\"aps\":{}}", .{ .environment = .sandbox, .push_type = .voip });
    try testing.expectEqual(@as(u16, 400), r2.status);
    try testing.expectEqualStrings("BadDeviceToken", r2.reason());
    try testing.expect(r2.tokenGone());

    // The server sent GOAWAY after that one and closed. 3 goes on a new connection.
    const r3 = c.send("00aa11bb", "{\"aps\":{\"content-available\":1}}", .{ .environment = .sandbox, .push_type = .background }) catch |err| {
        std.debug.print("third send failed: {t} (server saw {d} requests on {d} connections)\n", .{ err, seen_count, connections });
        return err;
    };
    try testing.expectEqual(@as(u16, 200), r3.status);
    c.deinit(); // closes the connection, so the server finishes
    awaited = true;
    try server.await(io);

    try testing.expectEqual(@as(usize, 3), seen_count);
    try testing.expectEqual(@as(usize, 2), connections);
    try testing.expectEqualStrings("/3/device/00aa11bb", seen[0].path[0..seen[0].path_len]);
    try testing.expectEqual(@as(u31, 1), seen[0].stream);
    try testing.expectEqual(@as(u31, 3), seen[1].stream);
    try testing.expectEqual(@as(u31, 1), seen[2].stream); // new connection
    try testing.expectEqualStrings("com.wufour.test", seen[0].topic[0..seen[0].topic_len]);
    try testing.expectEqualStrings("com.wufour.test.voip", seen[1].topic[0..seen[1].topic_len]);
    try testing.expectEqualStrings("voip", seen[1].push_type[0..seen[1].push_type_len]);
    try testing.expectEqual(@as(u8, 10), seen[0].priority);
    try testing.expectEqual(@as(u8, 5), seen[2].priority);
    try testing.expectEqual(@as(usize, 22), seen[0].body_len);
    // One provider token for all three, signed with the key.
    const auth = seen[0].auth[0..seen[0].auth_len];
    try testing.expect(std.mem.startsWith(u8, auth, "bearer "));
    try jwt.verifyEs256(auth["bearer ".len..], kp.public_key);
    try testing.expectEqualStrings(auth, seen[2].auth[0..seen[2].auth_len]);
}
