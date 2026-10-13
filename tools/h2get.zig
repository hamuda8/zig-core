//! Tries the HTTP/2 client by hand against a real server:
//!   h2get [--self-signed] [--post <body> | --post-bytes <n>] [--repeat <n>] [--ping] https://host[:port]/path
//! Prints the status, response fields and body of each request (all on one connection).
//! --ping only connects (TLS + ALPN h2) and exchanges a PING: no request is sent.

const std = @import("std");
const h2 = @import("push").h2;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var ca: h2.Ca = .system;
    var body: ?[]const u8 = null;
    var repeat: usize = 1;
    var url: ?[]const u8 = null;
    var ping_only = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--ping")) {
            ping_only = true;
        } else if (std.mem.eql(u8, args[i], "--self-signed")) {
            ca = .self_signed;
        } else if (std.mem.eql(u8, args[i], "--post") and i + 1 < args.len) {
            i += 1;
            body = args[i];
        } else if (std.mem.eql(u8, args[i], "--post-bytes") and i + 1 < args.len) {
            // A body of n 'x' bytes, for bodies bigger than the flow-control windows.
            i += 1;
            const big = try arena.alloc(u8, try std.fmt.parseInt(usize, args[i], 10));
            @memset(big, 'x');
            body = big;
        } else if (std.mem.eql(u8, args[i], "--repeat") and i + 1 < args.len) {
            i += 1;
            repeat = try std.fmt.parseInt(usize, args[i], 10);
        } else url = args[i];
    }
    const uri = std.Uri.parse(url orelse {
        std.debug.print("usage: h2get [--self-signed] [--post <body> | --post-bytes <n>] [--repeat <n>] [--ping] https://host[:port]/path\n", .{});
        return;
    }) catch return error.BadUrl;
    const host = (uri.host orelse return error.BadUrl).percent_encoded;
    const port = uri.port orelse 443;
    const path = if (uri.path.percent_encoded.len == 0) "/" else uri.path.percent_encoded;
    const full_path = if (uri.query) |q| try std.fmt.allocPrint(arena, "{s}?{s}", .{ path, q.percent_encoded }) else path;

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    const w = &out.interface;

    const conn = try h2.Connection.open(init.gpa, init.io, host, port, ca);
    defer conn.close();
    if (ping_only) {
        try conn.ping();
        try w.print("connected over {t}, ALPN h2, PING acknowledged; peer max frame {d}, initial window {d}\n", .{ conn.tls.tls_version, conn.h2.peer_max_frame, conn.h2.peer_initial_window });
        try w.flush();
        return;
    }
    for (0..repeat) |n| {
        var res = try conn.request(.{
            .method = if (body != null) "POST" else "GET",
            .authority = host,
            .path = full_path,
            .headers = &.{ .{ .name = "user-agent", .value = "zig-core-h2get" }, .{ .name = "content-type", .value = "application/json" } },
            .body = body orelse "",
        });
        defer res.deinit();
        try w.print("#{d} stream {d}: status {d}\n", .{ n + 1, conn.h2.next_stream - 2, res.status });
        for (res.headers) |h| try w.print("  {s}: {s}\n", .{ h.name, h.value });
        const shown = res.body[0..@min(res.body.len, 600)];
        try w.print("  body ({d} bytes): {s}{s}\n", .{ res.body.len, shown, if (shown.len < res.body.len) "..." else "" });
        try w.flush();
    }
}
