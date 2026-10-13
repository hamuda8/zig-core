//! A minimal SMTP client: one email per connection, encrypted, with std only. Port 465 is TLS
//! from the start (`secure`), other ports upgrade with STARTTLS; a server that offers no
//! encryption is refused unless `allow_insecure` is set. AUTH PLAIN or LOGIN, whichever the
//! server offers. The whole conversation has a time limit.
//!
//!     try smtp.send(io, arena, &http_client, .{ .host = "smtp.example.com", .port = 587,
//!         .user = u, .pass = p, .from = "Turf <no-reply@example.com>" }, .{
//!         .to = "a@example.com", .subject = "Hello", .text = "Hi", .html = "<p>Hi</p>" }, now_ms);

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Config = struct {
    host: []const u8,
    port: u16 = 587,
    /// TLS from the first byte (port 465).
    secure: bool = false,
    user: []const u8 = "",
    pass: []const u8 = "",
    /// "Name <address>" or a bare address.
    from: []const u8,
    /// Send over plain text when the server has no STARTTLS (local test servers only).
    allow_insecure: bool = false,
    timeout_ms: i64 = 60_000,
    /// The name sent with EHLO.
    hello: []const u8 = "localhost",
};

pub const Mail = struct { to: []const u8, subject: []const u8, text: []const u8, html: ?[]const u8 = null };

pub const Error = error{ InvalidRecipient, SmtpTimeout, SmtpGreeting, SmtpCommandFailed, SmtpNoEncryption, SmtpConnectionClosed, SmtpBadReply };

/// Sends one email. `client` lends its certificate bundle (scanned from the system once).
pub fn send(io: Io, a: Allocator, client: *std.http.Client, config: Config, mail: Mail, now_ms: i64) !void {
    const m: Mail = .{ .to = try oneLine(a, mail.to), .subject = try oneLine(a, mail.subject), .text = mail.text, .html = mail.html };
    if (!validRecipient(m.to)) return error.InvalidRecipient;
    const message = try buildMessage(io, a, config.from, m, now_ms);
    const U = union(enum) { done: anyerror!void, slept: void };
    var buf: [2]U = undefined;
    var sel = Io.Select(U).init(io, &buf);
    const Run = struct {
        fn talk(io_: Io, al: Allocator, cl: *std.http.Client, c: Config, to: []const u8, msg: []const u8) anyerror!void {
            return converse(io_, al, cl, c, to, msg);
        }
        fn sleep(io_: Io, ms: i64) void {
            io_.sleep(.fromMilliseconds(ms), .awake) catch {};
        }
    };
    sel.concurrent(.done, Run.talk, .{ io, a, client, config, m.to, message }) catch return converse(io, a, client, config, m.to, message);
    sel.concurrent(.slept, Run.sleep, .{ io, config.timeout_ms }) catch {};
    const first = sel.await() catch |e| {
        sel.cancelDiscard();
        return e;
    };
    sel.cancelDiscard();
    return switch (first) {
        .done => |r| r,
        .slept => error.SmtpTimeout,
    };
}

/// A header value on one line: CR and LF runs become one space, then trimmed.
pub fn oneLine(a: Allocator, v: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_break = false;
    for (v) |c| {
        if (c == '\r' or c == '\n') {
            if (!in_break) try out.append(a, ' ');
            in_break = true;
        } else {
            try out.append(a, c);
            in_break = false;
        }
    }
    return std.mem.trim(u8, out.items, " \t");
}

/// "Name <a@b>" -> "a@b"
pub fn addressOf(from: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, from, '<')) |i| if (std.mem.indexOfScalarPos(u8, from, i, '>')) |j| return std.mem.trim(u8, from[i + 1 .. j], " ");
    return std.mem.trim(u8, from, " ");
}

pub fn validRecipient(to: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, to, '@') orelse return false;
    if (at == 0 or at == to.len - 1) return false;
    if (std.mem.lastIndexOfScalar(u8, to, '@') != at) return false;
    for (to) |c| if (std.ascii.isWhitespace(c) or c == '<' or c == '>') return false;
    return true;
}

/// RFC 2047 for non-ASCII header text.
fn encodeHeader(a: Allocator, v: []const u8) ![]const u8 {
    for (v) |c| if (c < 0x20 or c > 0x7e) {
        const b = try a.alloc(u8, std.base64.standard.Encoder.calcSize(v.len));
        return std.fmt.allocPrint(a, "=?UTF-8?B?{s}?=", .{std.base64.standard.Encoder.encode(b, v)});
    };
    return v;
}

fn formatFrom(a: Allocator, from: []const u8) ![]const u8 {
    const lt = std.mem.lastIndexOfScalar(u8, from, '<') orelse return from;
    const rest = std.mem.trimEnd(u8, from[lt..], " ");
    if (!std.mem.endsWith(u8, rest, ">")) return from;
    var name = std.mem.trim(u8, from[0..lt], " ");
    if (name.len >= 1 and name[0] == '"') name = name[1..];
    if (name.len >= 1 and name[name.len - 1] == '"') name = name[0 .. name.len - 1];
    return std.fmt.allocPrint(a, "{s} <{s}>", .{ try encodeHeader(a, name), std.mem.trim(u8, rest[1 .. rest.len - 1], " ") });
}

fn base64Lines(a: Allocator, s: []const u8) ![]const u8 {
    const b = try a.alloc(u8, std.base64.standard.Encoder.calcSize(s.len));
    const enc = std.base64.standard.Encoder.encode(b, s);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < enc.len) : (i += 76) {
        try out.appendSlice(a, enc[i..@min(i + 76, enc.len)]);
        try out.appendSlice(a, "\r\n");
    }
    return out.items;
}

fn randomHex(io: Io, a: Allocator, comptime n: usize) ![]const u8 {
    var b: [n]u8 = undefined;
    io.random(&b);
    return a.dupe(u8, &std.fmt.bytesToHex(b, .lower));
}

/// "Tue, 13 Oct 2026 09:30:00 GMT" (RFC 7231 / 5322 date).
pub fn httpDate(a: Allocator, ms: i64) ![]const u8 {
    const days_ = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divFloor(@max(ms, 0), 1000)) };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(a, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        days_[@intCast(day.day % 7)], md.day_index + 1, months[md.month.numeric() - 1], yd.year, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}

/// The MIME message: text and HTML alternatives, base64, UTF-8.
pub fn buildMessage(io: Io, a: Allocator, from: []const u8, m: Mail, now_ms: i64) ![]const u8 {
    const boundary = try std.fmt.allocPrint(a, "part-{s}", .{try randomHex(io, a, 12)});
    const addr = addressOf(from);
    const domain = if (std.mem.indexOfScalar(u8, addr, '@')) |i| addr[i + 1 ..] else "localhost";
    const part = struct {
        fn f(al: Allocator, bnd: []const u8, ty: []const u8, body: []const u8) ![]const u8 {
            return std.fmt.allocPrint(al, "--{s}\r\nContent-Type: {s}; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n{s}", .{ bnd, ty, try base64Lines(al, body) });
        }
    }.f;
    return std.fmt.allocPrint(a, "From: {s}\r\nTo: {s}\r\nSubject: {s}\r\nDate: {s}\r\nMessage-ID: <{s}@{s}>\r\nMIME-Version: 1.0\r\nContent-Type: multipart/alternative; boundary=\"{s}\"\r\n\r\n{s}\r\n{s}\r\n--{s}--\r\n", .{
        try formatFrom(a, from),                     m.to, try encodeHeader(a, m.subject), try httpDate(a, now_ms), try randomHex(io, a, 16), domain, boundary,
        try part(a, boundary, "text/plain", m.text), try part(a, boundary, "text/html", m.html orelse m.text), boundary,
    });
}

const Line = struct {
    in: *Io.Reader,
    out: *Io.Writer,
    /// Flushed after writes (the TLS layer's ciphertext writer under it).
    under: ?*Io.Writer = null,

    const Reply = struct { code: u16, text: []const u8 };

    fn read(l: Line, a: Allocator) !Reply {
        var all: std.ArrayList(u8) = .empty;
        while (true) {
            const line = l.in.takeDelimiterInclusive('\n') catch return error.SmtpConnectionClosed;
            const t = std.mem.trimEnd(u8, line, "\r\n");
            if (all.items.len > 0) try all.appendSlice(a, " | ");
            try all.appendSlice(a, t);
            // The last line of a reply has a space after the code ("250 OK"), others a dash.
            if (t.len == 3 or (t.len > 3 and t[3] == ' ')) {
                const code = std.fmt.parseInt(u16, t[0..3], 10) catch return error.SmtpBadReply;
                return .{ .code = code, .text = all.items };
            }
        }
    }

    fn cmd(l: Line, a: Allocator, line: []const u8, expect: []const u16) !Reply {
        try l.out.writeAll(line);
        try l.out.writeAll("\r\n");
        try l.out.flush();
        if (l.under) |u| try u.flush();
        const r = try l.read(a);
        for (expect) |e| if (e == r.code) return r;
        const verb = line[0 .. std.mem.indexOfScalar(u8, line, ' ') orelse line.len];
        std.log.err("SMTP {s} failed: {s}", .{ if (verb.len > 20) "DATA" else verb, r.text });
        return error.SmtpCommandFailed;
    }
};

fn converse(io: Io, a: Allocator, client: *std.http.Client, c: Config, to: []const u8, message: []const u8) !void {
    const host = try Io.net.HostName.init(c.host);
    var stream = try host.connect(io, c.port, .{ .mode = .stream });
    defer stream.close(io);
    var rbuf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var wbuf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    var sw = stream.writer(io, &wbuf);

    var tls_rbuf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var tls_wbuf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var tls_client: std.crypto.tls.Client = undefined;
    var l: Line = .{ .in = &sr.interface, .out = &sw.interface };

    if (c.secure) {
        tls_client = try startTls(io, client, c.host, &sr.interface, &sw.interface, &tls_rbuf, &tls_wbuf);
        l = .{ .in = &tls_client.reader, .out = &tls_client.writer, .under = &sw.interface };
    }
    const greeting = try l.read(a);
    if (greeting.code != 220) return error.SmtpGreeting;
    const hello = try std.fmt.allocPrint(a, "EHLO {s}", .{c.hello});
    var ehlo = try l.cmd(a, hello, &.{250});
    if (!c.secure) {
        if (std.ascii.findIgnoreCase(ehlo.text, "STARTTLS") != null) {
            _ = try l.cmd(a, "STARTTLS", &.{220});
            tls_client = try startTls(io, client, c.host, &sr.interface, &sw.interface, &tls_rbuf, &tls_wbuf);
            l = .{ .in = &tls_client.reader, .out = &tls_client.writer, .under = &sw.interface };
            ehlo = try l.cmd(a, hello, &.{250});
        } else if (!c.allow_insecure) {
            std.log.err("The mail server does not offer encryption (STARTTLS); refusing to send the password over plain text", .{});
            return error.SmtpNoEncryption;
        }
    }
    if (c.user.len > 0) {
        const auth_line = ehlo.text[(std.ascii.findIgnoreCase(ehlo.text, "AUTH") orelse ehlo.text.len)..];
        const has_plain = std.ascii.findIgnoreCase(auth_line, "PLAIN") != null;
        const has_login = std.ascii.findIgnoreCase(auth_line, "LOGIN") != null;
        const E = std.base64.standard.Encoder;
        if (has_plain or !has_login) {
            const raw = try std.fmt.allocPrint(a, "\x00{s}\x00{s}", .{ c.user, c.pass });
            const b = try a.alloc(u8, E.calcSize(raw.len));
            _ = try l.cmd(a, try std.fmt.allocPrint(a, "AUTH PLAIN {s}", .{E.encode(b, raw)}), &.{235});
        } else {
            _ = try l.cmd(a, "AUTH LOGIN", &.{334});
            const u = try a.alloc(u8, E.calcSize(c.user.len));
            _ = try l.cmd(a, E.encode(u, c.user), &.{334});
            const p = try a.alloc(u8, E.calcSize(c.pass.len));
            _ = try l.cmd(a, E.encode(p, c.pass), &.{235});
        }
    }
    _ = try l.cmd(a, try std.fmt.allocPrint(a, "MAIL FROM:<{s}>", .{addressOf(c.from)}), &.{250});
    _ = try l.cmd(a, try std.fmt.allocPrint(a, "RCPT TO:<{s}>", .{to}), &.{ 250, 251 });
    _ = try l.cmd(a, "DATA", &.{354});
    _ = try l.cmd(a, try dotStuff(a, message), &.{250});
    _ = l.cmd(a, "QUIT", &.{221}) catch {};
}

/// RFC 5321 4.5.2: a line starting with "." gets another; the message ends with "\r\n.".
pub fn dotStuff(a: Allocator, msg: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitSequence(u8, msg, "\r\n");
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.appendSlice(a, "\r\n");
        first = false;
        if (line.len > 0 and line[0] == '.') try out.append(a, '.');
        try out.appendSlice(a, line);
    }
    try out.appendSlice(a, "\r\n.");
    return out.items;
}

fn startTls(io: Io, client: *std.http.Client, host: []const u8, in: *Io.Reader, out: *Io.Writer, rbuf: []u8, wbuf: []u8) !std.crypto.tls.Client {
    // The certificate bundle std.http's client keeps (scanned once from the system).
    {
        client.ca_bundle_lock.lockSharedUncancelable(io);
        const scanned = client.now != null;
        client.ca_bundle_lock.unlockShared(io);
        if (!scanned) {
            var bundle: std.crypto.Certificate.Bundle = .empty;
            defer bundle.deinit(client.allocator);
            const now = Io.Clock.real.now(io);
            try bundle.rescan(client.allocator, io, now);
            client.ca_bundle_lock.lockUncancelable(io);
            defer client.ca_bundle_lock.unlock(io);
            if (client.now == null) {
                client.now = now;
                std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
            }
        }
    }
    var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
    io.random(&entropy);
    return std.crypto.tls.Client.init(in, out, .{
        .host = .{ .explicit = host },
        .ca = .{ .bundle = .{ .gpa = client.allocator, .io = io, .lock = &client.ca_bundle_lock, .bundle = &client.ca_bundle } },
        .read_buffer = rbuf,
        .write_buffer = wbuf,
        .entropy = &entropy,
        .realtime_now = Io.Clock.real.now(io),
    });
}

const testing = std.testing;

/// A plain-text SMTP server for the test: records what it is sent.
fn fakeServer(listener: *Io.net.Server, got: *std.ArrayList(u8)) void {
    const io = testing.io;
    const stream = listener.accept(io) catch return;
    defer stream.close(io);
    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var wbuf: [512]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    const say = struct {
        fn f(wr: *Io.Writer, line: []const u8) void {
            wr.writeAll(line) catch {};
            wr.flush() catch {};
        }
    }.f;
    say(&w.interface, "220 test ESMTP\r\n");
    var in_data = false;
    while (true) {
        const line = r.interface.takeDelimiterInclusive('\n') catch return;
        got.appendSlice(testing.allocator, line) catch return;
        if (in_data) {
            if (std.mem.eql(u8, line, ".\r\n")) {
                in_data = false;
                say(&w.interface, "250 queued\r\n");
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "EHLO")) say(&w.interface, "250-test\r\n250 AUTH LOGIN\r\n") else if (std.mem.startsWith(u8, line, "AUTH LOGIN")) say(&w.interface, "334 VXNlcm5hbWU6\r\n") else if (std.mem.startsWith(u8, line, "dQ==")) say(&w.interface, "334 UGFzc3dvcmQ6\r\n") else if (std.mem.startsWith(u8, line, "cA==")) say(&w.interface, "235 ok\r\n") else if (std.mem.startsWith(u8, line, "DATA")) {
            in_data = true;
            say(&w.interface, "354 go\r\n");
        } else if (std.mem.startsWith(u8, line, "QUIT")) {
            say(&w.interface, "221 bye\r\n");
            return;
        } else say(&w.interface, "250 ok\r\n");
    }
}

test "a conversation: AUTH LOGIN, envelope, dot-stuffed MIME message" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    var server = try io.concurrent(fakeServer, .{ &listener, &got });
    var client: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();
    try send(io, a, &client, .{
        .host = "127.0.0.1",
        .port = listener.socket.address.getPort(),
        .user = "u",
        .pass = "p",
        .from = "Türf <no-reply@example.com>",
        .allow_insecure = true,
        .timeout_ms = 5000,
    }, .{ .to = "a@example.com\r\n", .subject = "Hi\nthere", .text = ".dot line" }, 0);
    server.await(io);
    try testing.expect(std.mem.indexOf(u8, got.items, "MAIL FROM:<no-reply@example.com>\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, got.items, "RCPT TO:<a@example.com>\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, got.items, "Subject: Hi there\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, got.items, "From: =?UTF-8?B?") != null);
    try testing.expect(std.mem.indexOf(u8, got.items, "Date: Thu, 01 Jan 1970 00:00:00 GMT\r\n") != null);
    try testing.expectError(error.InvalidRecipient, send(io, a, &client, .{ .host = "x", .from = "f@x" }, .{ .to = "nope", .subject = "", .text = "" }, 0));
}

test "dot stuffing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("a\r\n..b\r\n.", try dotStuff(arena.allocator(), "a\r\n.b"));
}
