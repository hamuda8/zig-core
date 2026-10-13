//! A minimal HTTP/2 client (RFC 9113): one request at a time on one connection, streams 1, 3,
//! 5... in turn, so a long-lived connection (what APNs wants) serves many requests.
//!
//! `Client` speaks frames over any reader/writer pair; `Connection` opens TCP + TLS with ALPN
//! "h2" (tls_client.zig) and puts a `Client` on top. No server push, no priorities, no
//! concurrent streams.

const std = @import("std");
const hpack = @import("hpack.zig");
const TlsClient = @import("tls_client.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;

pub const Header = hpack.Header;

pub const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

// ---- Frames (4.1, 6) -----------------------------------------------------------------------

pub const FrameType = enum(u8) {
    data = 0,
    headers = 1,
    priority = 2,
    rst_stream = 3,
    settings = 4,
    push_promise = 5,
    ping = 6,
    goaway = 7,
    window_update = 8,
    continuation = 9,
    _,
};

pub const flag = struct {
    pub const end_stream: u8 = 0x1;
    pub const ack: u8 = 0x1;
    pub const end_headers: u8 = 0x4;
    pub const padded: u8 = 0x8;
    pub const priority: u8 = 0x20;
};

pub const ErrorCode = enum(u32) {
    no_error = 0,
    protocol_error = 1,
    internal_error = 2,
    flow_control_error = 3,
    settings_timeout = 4,
    stream_closed = 5,
    frame_size_error = 6,
    refused_stream = 7,
    cancel = 8,
    compression_error = 9,
    connect_error = 10,
    enhance_your_calm = 11,
    inadequate_security = 12,
    http_1_1_required = 13,
    _,
};

pub const Setting = enum(u16) {
    header_table_size = 1,
    enable_push = 2,
    max_concurrent_streams = 3,
    initial_window_size = 4,
    max_frame_size = 5,
    max_header_list_size = 6,
    _,
};

pub const FrameHeader = struct {
    len: u24,
    type: FrameType,
    flags: u8 = 0,
    stream: u31 = 0,

    pub fn encode(h: FrameHeader) [9]u8 {
        var b: [9]u8 = undefined;
        std.mem.writeInt(u24, b[0..3], h.len, .big);
        b[3] = @backingInt(h.type);
        b[4] = h.flags;
        std.mem.writeInt(u32, b[5..9], h.stream, .big);
        return b;
    }

    pub fn decode(b: [9]u8) FrameHeader {
        return .{
            .len = std.mem.readInt(u24, b[0..3], .big),
            .type = @fromBackingInt(@intCast(b[3])),
            .flags = b[4],
            // The reserved bit is ignored on receipt.
            .stream = @truncate(std.mem.readInt(u32, b[5..9], .big)),
        };
    }
};

pub fn writeFrame(w: *Writer, h: FrameHeader, payload: []const u8) Writer.Error!void {
    var hh = h;
    hh.len = @intCast(payload.len);
    try w.writeAll(&hh.encode());
    try w.writeAll(payload);
}

pub fn settingsPayload(comptime n: usize, s: [n]struct { Setting, u32 }) [n * 6]u8 {
    var out: [n * 6]u8 = undefined;
    for (s, 0..) |kv, i| {
        std.mem.writeInt(u16, out[i * 6 ..][0..2], @backingInt(kv[0]), .big);
        std.mem.writeInt(u32, out[i * 6 ..][2..6], kv[1], .big);
    }
    return out;
}

/// The payload of a WINDOW_UPDATE frame.
pub fn windowUpdatePayload(increment: u31) [4]u8 {
    var out: [4]u8 = undefined;
    std.mem.writeInt(u32, &out, increment, .big);
    return out;
}

/// The payload of a GOAWAY frame without debug data.
pub fn goawayPayload(last_stream: u31, code: ErrorCode) [8]u8 {
    var out: [8]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], last_stream, .big);
    std.mem.writeInt(u32, out[4..8], @backingInt(code), .big);
    return out;
}

/// The part of a DATA or HEADERS payload left after padding (and HEADERS priority fields).
pub fn unpad(payload: []const u8, flags: u8, has_priority: bool) error{ProtocolError}![]const u8 {
    var p = payload;
    var pad: usize = 0;
    if (flags & flag.padded != 0) {
        if (p.len < 1) return error.ProtocolError;
        pad = p[0];
        p = p[1..];
    }
    if (has_priority and flags & flag.priority != 0) {
        if (p.len < 5) return error.ProtocolError;
        p = p[5..];
    }
    if (pad > p.len) return error.ProtocolError;
    return p[0 .. p.len - pad];
}

// ---- Client --------------------------------------------------------------------------------

pub const Request = struct {
    method: []const u8 = "GET",
    scheme: []const u8 = "https",
    authority: []const u8,
    path: []const u8 = "/",
    /// Regular fields, lowercase names. No connection-specific ones (connection, keep-alive...).
    headers: []const Header = &.{},
    body: []const u8 = "",
};

pub const Response = struct {
    status: u16,
    /// Response fields and trailers, without pseudo-headers.
    headers: []const Header,
    body: []const u8,
    arena: std.heap.ArenaAllocator,

    pub fn header(r: *const Response, name: []const u8) ?[]const u8 {
        for (r.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }

    pub fn deinit(r: *Response) void {
        r.arena.deinit();
    }
};

pub const Error = error{
    /// The server sent GOAWAY before taking this request (or earlier); retry on a new connection.
    GoAway,
    /// The server reset the stream; `Client.reset_code` says why (REFUSED_STREAM: safe to retry).
    StreamReset,
    ConnectionClosed,
    /// The server broke the protocol; the connection was closed with GOAWAY.
    ProtocolError,
    ResponseTooLarge,
    StreamIdsExhausted,
    BadHeader,
    ReadFailed,
    WriteFailed,
    OutOfMemory,
};

/// Our receive windows: big enough that responses rarely wait for a WINDOW_UPDATE.
const recv_window: u31 = 1 << 20;
/// Our SETTINGS_HEADER_TABLE_SIZE (the default).
const header_table_size = 4096;
/// We never raise SETTINGS_MAX_FRAME_SIZE, so the peer's frames fit here.
const max_frame = 16384;
const max_window = std.math.maxInt(u31);

pub const Client = struct {
    gpa: Allocator,
    reader: *Reader,
    writer: *Writer,
    /// Flushed after `writer` when set: the socket writer under a TLS writer.
    lower: ?*Writer,
    encoder: hpack.Encoder = .{},
    decoder: hpack.Decoder,
    next_stream: u32 = 1,
    /// Peer settings that matter to us.
    peer_max_frame: u32 = 16384,
    peer_initial_window: i64 = 65535,
    /// Connection-level windows: what we may still send, and what the peer may still send us.
    send_window: i64 = 65535,
    conn_recv: i64 = recv_window,
    /// Set once the peer sends GOAWAY: the last stream it will process.
    goaway_last: ?u31 = null,
    goaway_code: ErrorCode = .no_error,
    /// Why the last StreamReset happened.
    reset_code: ErrorCode = .no_error,
    /// Set after a protocol error or a lost connection: every later request fails.
    broken: bool = false,
    /// Set when our PING comes back.
    ping_acked: bool = false,
    /// Response size limit (body bytes).
    max_body: usize = 4 << 20,
    /// The stream being served, if any.
    active: ?Stream = null,
    /// A header block split over HEADERS + CONTINUATION frames.
    block: std.ArrayList(u8) = .empty,
    block_stream: u31 = 0,
    block_flags: u8 = 0,
    frame: [max_frame]u8 = undefined,

    const Stream = struct {
        id: u31,
        send_window: i64,
        recv: i64 = recv_window,
        arena: std.heap.ArenaAllocator,
        status: u16 = 0,
        headers: std.ArrayList(Header) = .empty,
        body: std.ArrayList(u8) = .empty,
        done: bool = false,
        reset: bool = false,
    };

    /// Sends the connection preface and our SETTINGS. The server's SETTINGS are handled as they
    /// arrive, during the first request.
    pub fn init(gpa: Allocator, reader: *Reader, writer: *Writer, lower: ?*Writer) Error!Client {
        var c: Client = .{
            .gpa = gpa,
            .reader = reader,
            .writer = writer,
            .lower = lower,
            .decoder = .init(gpa, header_table_size),
        };
        errdefer c.decoder.deinit();
        try c.writer.writeAll(preface);
        try writeFrame(c.writer, .{ .len = 0, .type = .settings }, &settingsPayload(3, .{
            .{ .enable_push, 0 },
            .{ .initial_window_size, recv_window },
            .{ .header_table_size, header_table_size },
        }));
        // The connection window starts at 65535 whatever SETTINGS say; raise it to ours.
        try writeFrame(c.writer, .{ .len = 0, .type = .window_update }, &windowUpdatePayload(recv_window - 65535));
        try c.flush();
        return c;
    }

    pub fn deinit(c: *Client) void {
        c.dropActive();
        c.decoder.deinit();
        c.block.deinit(c.gpa);
    }

    /// Sends GOAWAY (best effort); the caller then closes the transport.
    pub fn close(c: *Client) void {
        if (c.broken) return;
        const last: u31 = 0; // we accept no streams from the server
        writeFrame(c.writer, .{ .len = 0, .type = .goaway }, &goawayPayload(last, .no_error)) catch {};
        c.flush() catch {};
        c.broken = true;
    }

    fn flush(c: *Client) Error!void {
        try c.writer.flush();
        if (c.lower) |l| try l.flush();
    }

    fn dropActive(c: *Client) void {
        if (c.active) |*s| s.arena.deinit();
        c.active = null;
    }

    const ping_data = "zig-core";

    /// Sends a PING and waits for its ACK: checks that an idle connection still works, and
    /// keeps it from timing out.
    pub fn ping(c: *Client) Error!void {
        if (c.broken) return error.ConnectionClosed;
        if (c.goaway_last != null) return error.GoAway;
        c.ping_acked = false;
        writeFrame(c.writer, .{ .len = 0, .type = .ping }, ping_data) catch |err| return c.fail(err);
        c.flush() catch |err| return c.fail(err);
        while (!c.ping_acked) c.readFrame() catch |err| return c.fail(err);
    }

    /// Sends one request and waits for its whole response. Free it with `Response.deinit`.
    pub fn request(c: *Client, req: Request) Error!Response {
        if (c.broken) return error.ConnectionClosed;
        if (c.goaway_last != null) return error.GoAway;
        if (c.next_stream > max_window) return error.StreamIdsExhausted;
        for (req.headers) |h| {
            for (h.name) |ch| if (std.ascii.isUpper(ch) or ch == ':') return error.BadHeader;
        }
        const id: u31 = @intCast(c.next_stream);
        c.next_stream += 2;
        c.active = .{ .id = id, .send_window = c.peer_initial_window, .arena = .init(c.gpa) };
        errdefer c.dropActive();

        c.sendRequest(id, req) catch |err| return c.fail(err);
        while (true) {
            const s = &c.active.?;
            if (s.reset) return error.StreamReset;
            if (s.done) break;
            c.readFrame() catch |err| return c.fail(err);
        }

        const s = &c.active.?;
        const result: Response = .{
            .status = s.status,
            .headers = s.headers.items,
            .body = s.body.items,
            .arena = s.arena,
        };
        c.active = null;
        return result;
    }

    /// Marks the connection unusable after `err` (a GOAWAY for protocol errors) and returns it.
    fn fail(c: *Client, err: Error) Error {
        switch (err) {
            error.ProtocolError => {
                writeFrame(c.writer, .{ .len = 0, .type = .goaway }, &goawayPayload(0, .protocol_error)) catch {};
                c.flush() catch {};
                c.broken = true;
            },
            error.ResponseTooLarge => {
                // Only this stream is abandoned.
                if (c.active) |s| {
                    writeFrame(c.writer, .{ .len = 0, .type = .rst_stream, .stream = s.id }, &std.mem.toBytes(std.mem.nativeToBig(u32, @backingInt(ErrorCode.cancel)))) catch {};
                    c.flush() catch {};
                }
            },
            error.GoAway, error.StreamReset => {},
            else => c.broken = true,
        }
        return err;
    }

    fn sendRequest(c: *Client, id: u31, req: Request) Error!void {
        // Header block.
        var block: Writer.Allocating = .init(c.gpa);
        defer block.deinit();
        const pseudo = [_]Header{
            .{ .name = ":method", .value = req.method },
            .{ .name = ":scheme", .value = req.scheme },
            .{ .name = ":authority", .value = req.authority },
            .{ .name = ":path", .value = req.path },
        };
        c.encoder.encode(&block.writer, &pseudo) catch return error.OutOfMemory;
        c.encoder.encode(&block.writer, req.headers) catch return error.OutOfMemory;
        const bytes = block.written();

        // HEADERS, then CONTINUATION frames if the block is bigger than one frame.
        var rest = bytes;
        var first = true;
        while (true) {
            const n = @min(rest.len, c.peer_max_frame);
            var flags: u8 = 0;
            if (n == rest.len) flags |= flag.end_headers;
            if (first and req.body.len == 0) flags |= flag.end_stream;
            try writeFrame(c.writer, .{ .len = 0, .type = if (first) .headers else .continuation, .flags = flags, .stream = id }, rest[0..n]);
            rest = rest[n..];
            first = false;
            if (rest.len == 0) break;
        }

        // DATA, as the flow-control windows allow.
        var body = req.body;
        while (body.len > 0) {
            const s = &c.active.?;
            if (s.done or s.reset) return; // the server answered (or refused) early
            const allowed = @min(c.send_window, s.send_window);
            if (allowed <= 0) {
                try c.flush();
                try c.readFrame();
                continue;
            }
            const n: usize = @min(body.len, c.peer_max_frame, @as(usize, @intCast(allowed)));
            const flags: u8 = if (n == body.len) flag.end_stream else 0;
            try writeFrame(c.writer, .{ .len = 0, .type = .data, .flags = flags, .stream = id }, body[0..n]);
            c.send_window -= @intCast(n);
            s.send_window -= @intCast(n);
            body = body[n..];
        }
        try c.flush();
    }

    /// Reads and handles one frame (a whole header block counts as one).
    fn readFrame(c: *Client) Error!void {
        const head = c.reader.takeArray(9) catch |err| return switch (err) {
            error.EndOfStream => error.ConnectionClosed,
            error.ReadFailed => error.ReadFailed,
        };
        const h: FrameHeader = .decode(head.*);
        if (h.len > max_frame) return error.ProtocolError; // FRAME_SIZE_ERROR
        const payload = c.frame[0..h.len];
        c.reader.readSliceAll(payload) catch |err| return switch (err) {
            error.EndOfStream => error.ConnectionClosed,
            error.ReadFailed => error.ReadFailed,
        };

        // Nothing may come between HEADERS and its CONTINUATION frames.
        if (c.block_stream != 0 and (h.type != .continuation or h.stream != c.block_stream)) return error.ProtocolError;

        switch (h.type) {
            .data => {
                if (h.stream == 0) return error.ProtocolError;
                // Flow control counts the whole payload, padding included.
                c.conn_recv -= h.len;
                if (c.conn_recv < recv_window / 2) {
                    try writeFrame(c.writer, .{ .len = 0, .type = .window_update }, &windowUpdatePayload(@intCast(recv_window - c.conn_recv)));
                    c.conn_recv = recv_window;
                    try c.flush();
                }
                const data = try unpad(payload, h.flags, false);
                const s = c.streamFor(h.stream) orelse return;
                if (s.status == 0) return error.ProtocolError; // DATA before HEADERS
                if (s.body.items.len + data.len > c.max_body) return error.ResponseTooLarge;
                try s.body.appendSlice(s.arena.allocator(), data);
                if (h.flags & flag.end_stream != 0) {
                    s.done = true;
                    return;
                }
                s.recv -= h.len;
                if (s.recv < recv_window / 2) {
                    try writeFrame(c.writer, .{ .len = 0, .type = .window_update, .stream = s.id }, &windowUpdatePayload(@intCast(recv_window - s.recv)));
                    s.recv = recv_window;
                    try c.flush();
                }
            },
            .headers => {
                if (h.stream == 0) return error.ProtocolError;
                try c.block.appendSlice(c.gpa, try unpad(payload, h.flags, true));
                c.block_flags = h.flags;
                if (h.flags & flag.end_headers != 0) return c.headerBlock(h.stream);
                c.block_stream = h.stream;
            },
            .continuation => {
                if (c.block_stream == 0) return error.ProtocolError;
                try c.block.appendSlice(c.gpa, payload);
                if (h.flags & flag.end_headers != 0) return c.headerBlock(c.block_stream);
            },
            .rst_stream => {
                if (h.stream == 0 or h.len != 4) return error.ProtocolError;
                if (c.streamFor(h.stream)) |s| {
                    s.reset = true;
                    c.reset_code = @fromBackingInt(@intCast(std.mem.readInt(u32, payload[0..4], .big)));
                }
            },
            .settings => {
                if (h.stream != 0) return error.ProtocolError;
                if (h.flags & flag.ack != 0) {
                    if (h.len != 0) return error.ProtocolError;
                    return;
                }
                if (h.len % 6 != 0) return error.ProtocolError;
                var i: usize = 0;
                while (i < payload.len) : (i += 6) {
                    const id: Setting = @fromBackingInt(@intCast(std.mem.readInt(u16, payload[i..][0..2], .big)));
                    const value = std.mem.readInt(u32, payload[i..][2..6], .big);
                    switch (id) {
                        .header_table_size => c.encoder.size_update = true,
                        .initial_window_size => {
                            if (value > max_window) return error.ProtocolError; // FLOW_CONTROL_ERROR
                            // Open streams' windows move by the change (6.9.2).
                            if (c.active) |*s| s.send_window += @as(i64, value) - c.peer_initial_window;
                            c.peer_initial_window = value;
                        },
                        .max_frame_size => {
                            if (value < 16384 or value > 16777215) return error.ProtocolError;
                            c.peer_max_frame = value;
                        },
                        else => {},
                    }
                }
                try writeFrame(c.writer, .{ .len = 0, .type = .settings, .flags = flag.ack }, "");
                try c.flush();
            },
            .push_promise => return error.ProtocolError, // we said ENABLE_PUSH = 0
            .ping => {
                if (h.stream != 0 or h.len != 8) return error.ProtocolError;
                if (h.flags & flag.ack != 0) {
                    if (std.mem.eql(u8, payload, ping_data)) c.ping_acked = true;
                    return;
                }
                try writeFrame(c.writer, .{ .len = 0, .type = .ping, .flags = flag.ack }, payload);
                try c.flush();
            },
            .goaway => {
                if (h.stream != 0 or h.len < 8) return error.ProtocolError;
                const last: u31 = @truncate(std.mem.readInt(u32, payload[0..4], .big));
                c.goaway_last = last;
                c.goaway_code = @fromBackingInt(@intCast(std.mem.readInt(u32, payload[4..8], .big)));
                // Streams above `last` were never processed: safe to retry elsewhere.
                if (c.active) |s| if (s.id > last) return error.GoAway;
            },
            .window_update => {
                if (h.len != 4) return error.ProtocolError;
                const inc: u31 = @truncate(std.mem.readInt(u32, payload[0..4], .big));
                if (inc == 0) return error.ProtocolError;
                if (h.stream == 0) {
                    c.send_window += inc;
                    if (c.send_window > max_window) return error.ProtocolError;
                } else if (c.streamFor(h.stream)) |s| {
                    s.send_window += inc;
                    if (s.send_window > max_window) return error.ProtocolError;
                }
            },
            .priority => {},
            _ => {}, // unknown frame types are ignored (5.5)
        }
    }

    fn streamFor(c: *Client, id: u31) ?*Stream {
        if (c.active) |*s| if (s.id == id and !s.done and !s.reset) return s;
        return null;
    }

    /// Decodes a complete header block (always, to keep the HPACK table in step) and applies it.
    fn headerBlock(c: *Client, stream: u31) Error!void {
        defer {
            c.block.clearRetainingCapacity();
            c.block_stream = 0;
        }
        const end_stream = c.block_flags & flag.end_stream != 0;
        const s = c.streamFor(stream) orelse {
            // A stream we no longer track: decode and drop.
            var scratch = std.heap.ArenaAllocator.init(c.gpa);
            defer scratch.deinit();
            var fields: std.ArrayList(Header) = .empty;
            c.decoder.decode(scratch.allocator(), c.block.items, &fields) catch return error.ProtocolError;
            return;
        };
        const a = s.arena.allocator();
        var fields: std.ArrayList(Header) = .empty;
        c.decoder.decode(a, c.block.items, &fields) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.CompressionError => error.ProtocolError,
        };
        if (s.status == 0) {
            // Response head: :status first, then regular fields. 1xx heads are skipped.
            if (fields.items.len == 0 or !std.mem.eql(u8, fields.items[0].name, ":status")) return error.ProtocolError;
            const status = std.fmt.parseInt(u16, fields.items[0].value, 10) catch return error.ProtocolError;
            if (status < 100 or status > 999) return error.ProtocolError;
            if (status >= 200) s.status = status;
            if (status < 200 and end_stream) return error.ProtocolError;
            if (status >= 200) for (fields.items[1..]) |f| {
                if (f.name.len > 0 and f.name[0] == ':') return error.ProtocolError;
                try s.headers.append(a, f);
            };
        } else {
            // Trailers end the stream.
            if (!end_stream) return error.ProtocolError;
            for (fields.items) |f| {
                if (f.name.len > 0 and f.name[0] == ':') return error.ProtocolError;
                try s.headers.append(a, f);
            }
        }
        if (end_stream and s.status != 0) s.done = true;
    }
};

// ---- Connection over TLS -------------------------------------------------------------------

pub const Ca = union(enum) {
    /// The operating system's root certificates (loaded per connection).
    system,
    /// Tests against a local server: the certificate must be self-signed and name the host.
    self_signed,
};

/// TCP + TLS (ALPN "h2") + HTTP/2 to `host:port`. Heap-allocated: its parts point at each other.
pub const Connection = struct {
    gpa: Allocator,
    io: Io,
    stream: Io.net.Stream,
    socket_reader: Io.net.Stream.Reader,
    socket_writer: Io.net.Stream.Writer,
    tls: TlsClient,
    h2: Client,
    host: []u8,
    bundle: std.crypto.Certificate.Bundle = .empty,
    bundle_lock: Io.RwLock = .init,
    socket_read_buf: [TlsClient.min_buffer_len]u8 = undefined,
    socket_write_buf: [TlsClient.min_buffer_len]u8 = undefined,
    tls_read_buf: [TlsClient.min_buffer_len]u8 = undefined,
    tls_write_buf: [max_frame + 9]u8 = undefined,

    pub fn open(gpa: Allocator, io: Io, host: []const u8, port: u16, ca: Ca) !*Connection {
        const c = try gpa.create(Connection);
        errdefer gpa.destroy(c);
        c.* = .{
            .gpa = gpa,
            .io = io,
            .stream = undefined,
            .socket_reader = undefined,
            .socket_writer = undefined,
            .tls = undefined,
            .h2 = undefined,
            .host = try gpa.dupe(u8, host),
        };
        errdefer gpa.free(c.host);
        errdefer c.bundle.deinit(gpa);
        const now = Io.Timestamp.now(io, .real);
        if (ca == .system) try c.bundle.rescan(gpa, io, now);

        const name = try Io.net.HostName.init(c.host);
        c.stream = try name.connect(io, port, .{ .mode = .stream });
        errdefer c.stream.close(io);
        c.socket_reader = c.stream.reader(io, &c.socket_read_buf);
        c.socket_writer = c.stream.writer(io, &c.socket_write_buf);

        var entropy: [TlsClient.Options.entropy_len]u8 = undefined;
        io.random(&entropy);
        c.tls = TlsClient.init(&c.socket_reader.interface, &c.socket_writer.interface, .{
            .host = .{ .explicit = c.host },
            .ca = switch (ca) {
                .system => .{ .bundle = .{ .gpa = gpa, .io = io, .lock = &c.bundle_lock, .bundle = &c.bundle } },
                .self_signed => .self_signed,
            },
            .read_buffer = &c.tls_read_buf,
            .write_buffer = &c.tls_write_buf,
            .entropy = &entropy,
            .realtime_now = now,
            .alpn = "h2",
            // HTTP/2 frames carry their lengths, so a cut connection is still noticed.
            .allow_truncation_attacks = true,
        }) catch |err| switch (err) {
            error.WriteFailed => return c.socket_writer.err orelse error.WriteFailed,
            error.ReadFailed => return c.socket_reader.err orelse error.ReadFailed,
            else => |e| return e,
        };
        c.h2 = try Client.init(gpa, &c.tls.reader, &c.tls.writer, &c.socket_writer.interface);
        return c;
    }

    pub fn request(c: *Connection, req: Request) Error!Response {
        return c.h2.request(req);
    }

    pub fn ping(c: *Connection) Error!void {
        return c.h2.ping();
    }

    /// Whether new requests can still go on this connection.
    pub fn usable(c: *const Connection) bool {
        return !c.h2.broken and c.h2.goaway_last == null and c.h2.next_stream <= max_window;
    }

    pub fn close(c: *Connection) void {
        // A connection already lost (or that the server said goodbye on) gets no more writes.
        if (!c.h2.broken and c.h2.goaway_last == null) {
            c.h2.close();
            c.tls.end() catch {};
            c.socket_writer.interface.flush() catch {};
        }
        c.h2.deinit();
        c.stream.close(c.io);
        c.bundle.deinit(c.gpa);
        c.gpa.free(c.host);
        c.gpa.destroy(c);
    }
};

// ---- Tests ---------------------------------------------------------------------------------

const testing = std.testing;

test "frame header round trip" {
    const h: FrameHeader = .{ .len = 0x123456, .type = .headers, .flags = flag.end_headers | flag.end_stream, .stream = 0x7fff_fff1 };
    const b = h.encode();
    try testing.expectEqualSlices(u8, "\x12\x34\x56\x01\x05\x7f\xff\xff\xf1", &b);
    try testing.expectEqual(h, FrameHeader.decode(b));
    // The reserved bit is dropped.
    var r = b;
    r[5] |= 0x80;
    try testing.expectEqual(h.stream, FrameHeader.decode(r).stream);
    try testing.expectEqual(FrameType.continuation, FrameHeader.decode(.{ 0, 0, 0, 9, 0, 0, 0, 0, 1 }).type);
    try testing.expectEqual(@as(u8, 0xfa), @backingInt(FrameHeader.decode(.{ 0, 0, 0, 0xfa, 0, 0, 0, 0, 1 }).type));
}

test "frames written and read back" {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeFrame(&w, .{ .len = 0, .type = .settings }, &settingsPayload(2, .{ .{ .enable_push, 0 }, .{ .initial_window_size, 1 << 20 } }));
    try writeFrame(&w, .{ .len = 0, .type = .window_update, .stream = 3 }, &windowUpdatePayload(1000));
    try writeFrame(&w, .{ .len = 0, .type = .goaway }, &goawayPayload(5, .enhance_your_calm));
    try writeFrame(&w, .{ .len = 0, .type = .data, .flags = flag.padded | flag.end_stream, .stream = 1 }, "\x03hi\x00\x00\x00");
    var r: Reader = .fixed(w.buffered());

    var h: FrameHeader = .decode((try r.takeArray(9)).*);
    try testing.expectEqual(FrameType.settings, h.type);
    try testing.expectEqual(@as(u24, 12), h.len);
    const s = try r.take(h.len);
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, s[0..2], .big));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, s[2..6], .big));
    try testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, s[6..8], .big));
    try testing.expectEqual(@as(u32, 1 << 20), std.mem.readInt(u32, s[8..12], .big));

    h = .decode((try r.takeArray(9)).*);
    try testing.expectEqual(FrameHeader{ .len = 4, .type = .window_update, .stream = 3 }, h);
    try testing.expectEqual(@as(u32, 1000), std.mem.readInt(u32, (try r.takeArray(4)), .big));

    h = .decode((try r.takeArray(9)).*);
    try testing.expectEqual(FrameType.goaway, h.type);
    const g = try r.takeArray(8);
    try testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, g[0..4], .big));
    try testing.expectEqual(ErrorCode.enhance_your_calm, @as(ErrorCode, @fromBackingInt(@intCast(std.mem.readInt(u32, g[4..8], .big)))));

    h = .decode((try r.takeArray(9)).*);
    try testing.expectEqualStrings("hi", try unpad(try r.take(h.len), h.flags, false));
    try testing.expectError(error.ProtocolError, unpad("\x09hi", flag.padded, false));
    try testing.expectEqualStrings("x", try unpad("\x00\x00\x00\x01\x10x", flag.priority, true));
}

/// The server half of the tests: frames go through a pipe-like pair of buffers in memory.
const TestServer = struct {
    /// What the client wrote (the server reads it).
    from_client: *Writer.Allocating,
    /// What the server answers (the client reads it).
    to_client: Writer.Allocating,
    decoder: hpack.Decoder,
    encoder: hpack.Encoder = .{},

    fn expectRequest(s: *TestServer, a: Allocator, want_body: []const u8) !std.ArrayList(Header) {
        var r: Reader = .fixed(s.from_client.written());
        var fields: std.ArrayList(Header) = .empty;
        var body: std.ArrayList(u8) = .empty;
        var block: std.ArrayList(u8) = .empty;
        if (std.mem.startsWith(u8, r.buffered(), preface)) r.toss(preface.len);
        while (r.bufferedLen() > 0) {
            const h: FrameHeader = .decode((try r.takeArray(9)).*);
            const p = try r.take(h.len);
            switch (h.type) {
                .headers, .continuation => {
                    try block.appendSlice(a, p);
                    if (h.flags & flag.end_headers != 0) try s.decoder.decode(a, block.items, &fields);
                },
                .data => try body.appendSlice(a, p),
                else => {},
            }
        }
        s.from_client.clearRetainingCapacity();
        try testing.expectEqualStrings(want_body, body.items);
        return fields;
    }

    fn respond(s: *TestServer, a: Allocator, stream: u31, status: []const u8, extra: []const Header, body: []const u8) !void {
        var block: Writer.Allocating = .init(a);
        try s.encoder.encode(&block.writer, &.{.{ .name = ":status", .value = status }});
        try s.encoder.encode(&block.writer, extra);
        const w = &s.to_client.writer;
        // The block split in two to exercise CONTINUATION.
        const bytes = block.written();
        const half = bytes.len / 2;
        try writeFrame(w, .{ .len = 0, .type = .headers, .stream = stream }, bytes[0..half]);
        try writeFrame(w, .{ .len = 0, .type = .continuation, .flags = flag.end_headers, .stream = stream }, bytes[half..]);
        try writeFrame(w, .{ .len = 0, .type = .data, .flags = flag.end_stream, .stream = stream }, body);
    }
};

test "client: request, response, PING and SETTINGS in between, second stream, GOAWAY" {
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: Writer.Allocating = .init(a);
    defer out.deinit();
    var srv: TestServer = .{ .from_client = &out, .to_client = .init(a), .decoder = .init(a, 4096) };
    defer srv.to_client.deinit();
    defer srv.decoder.deinit();

    // The server's frames are queued before the client reads them: SETTINGS, a PING, then the
    // response to stream 1.
    const sw = &srv.to_client.writer;
    try writeFrame(sw, .{ .len = 0, .type = .settings }, &settingsPayload(1, .{.{ .max_frame_size, 20000 }}));
    try writeFrame(sw, .{ .len = 0, .type = .ping }, "12345678");
    try srv.respond(arena, 1, "200", &.{.{ .name = "apns-id", .value = "abc" }}, "ok");

    var in: Reader = .fixed(srv.to_client.written());
    var c = try Client.init(a, &in, &out.writer, null);
    defer c.deinit();
    var res = try c.request(.{ .method = "POST", .authority = "example.test", .path = "/3/device/aa", .headers = &.{.{ .name = "apns-topic", .value = "t" }}, .body = "{\"aps\":{}}" });
    defer res.deinit();
    try testing.expectEqual(@as(u16, 200), res.status);
    try testing.expectEqualStrings("abc", res.header("apns-id").?);
    try testing.expectEqualStrings("ok", res.body);
    try testing.expectEqual(@as(u32, 20000), c.peer_max_frame);

    // What the client sent: preface, SETTINGS, WINDOW_UPDATE, HEADERS, DATA, SETTINGS ack, PING ack.
    const sent = out.written();
    try testing.expect(std.mem.startsWith(u8, sent, preface));
    try testing.expect(std.mem.indexOf(u8, sent, "\x00\x00\x08\x06\x01\x00\x00\x00\x0012345678") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "\x00\x00\x00\x04\x01\x00\x00\x00\x00") != null);
    const fields = try srv.expectRequest(arena, "{\"aps\":{}}");
    try testing.expectEqualStrings(":method", fields.items[0].name);
    try testing.expectEqualStrings("POST", fields.items[0].value);
    try testing.expectEqualStrings("/3/device/aa", fields.items[3].value);
    try testing.expectEqualStrings("t", fields.items[4].value);

    // Stream 3 on the same connection: a 400 with a JSON reason.
    srv.to_client.clearRetainingCapacity();
    try srv.respond(arena, 3, "400", &.{}, "{\"reason\":\"BadDeviceToken\"}");
    in = .fixed(srv.to_client.written());
    var res2 = try c.request(.{ .authority = "example.test", .path = "/x" });
    defer res2.deinit();
    try testing.expectEqual(@as(u16, 400), res2.status);
    try testing.expectEqualStrings("{\"reason\":\"BadDeviceToken\"}", res2.body);
    _ = try srv.expectRequest(arena, "");

    // GOAWAY naming stream 3 as the last: stream 5 is refused without being processed.
    srv.to_client.clearRetainingCapacity();
    try writeFrame(sw, .{ .len = 0, .type = .goaway }, &goawayPayload(3, .no_error));
    in = .fixed(srv.to_client.written());
    try testing.expectError(error.GoAway, c.request(.{ .authority = "example.test" }));
    try testing.expectError(error.GoAway, c.request(.{ .authority = "example.test" }));
}

test "client: RST_STREAM, a cut connection, and flow control waits for WINDOW_UPDATE" {
    const a = testing.allocator;
    var out: Writer.Allocating = .init(a);
    defer out.deinit();
    var server: Writer.Allocating = .init(a);
    defer server.deinit();
    const sw = &server.writer;

    // A body bigger than the initial 65535 window: the client must wait for WINDOW_UPDATE.
    const big = try a.alloc(u8, 100_000);
    defer a.free(big);
    @memset(big, 'x');
    try writeFrame(sw, .{ .len = 0, .type = .window_update }, &windowUpdatePayload(50_000));
    try writeFrame(sw, .{ .len = 0, .type = .window_update, .stream = 1 }, &windowUpdatePayload(50_000));
    try writeFrame(sw, .{ .len = 0, .type = .rst_stream, .stream = 1 }, &.{ 0, 0, 0, 7 });
    var in: Reader = .fixed(server.written());
    var c = try Client.init(a, &in, &out.writer, null);
    defer c.deinit();
    try testing.expectError(error.StreamReset, c.request(.{ .method = "POST", .authority = "h", .body = big }));
    try testing.expectEqual(ErrorCode.refused_stream, c.reset_code);
    // All of the body went out once the windows opened: count DATA bytes.
    var r: Reader = .fixed(out.written()[preface.len..]);
    var data: usize = 0;
    while (r.bufferedLen() > 0) {
        const h: FrameHeader = .decode((try r.takeArray(9)).*);
        r.toss(h.len);
        if (h.type == .data) data += h.len;
    }
    try testing.expectEqual(big.len, data);

    // The server goes away mid-response.
    server.clearRetainingCapacity();
    try writeFrame(sw, .{ .len = 0, .type = .settings }, "");
    in = .fixed(server.written());
    try testing.expectError(error.ConnectionClosed, c.request(.{ .authority = "h" }));
    try testing.expectError(error.ConnectionClosed, c.request(.{ .authority = "h" }));
}
