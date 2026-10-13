//! WebSocket framing (RFC 6455) after std.http's handshake. Unlike std's reader it reports pong
//! and close frames, so servers can tell live connections from dead ones; it reassembles
//! fragmented messages and reads messages larger than the connection's buffer (up to
//! `max_payload`); and other tasks can send to the socket (a room relaying to its viewers).
//!
//! Sending is direct by default (each `send` writes under a lock). With `queued` set and
//! `writerLoop` running as its own task, `send` only queues the frame, so fan-out to many
//! sockets under a lock stays cheap, and a client that stops reading is dropped once
//! `max_queued` bytes wait for it instead of stalling the sender.

const std = @import("std");
const Io = std.Io;

pub const Op = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,
};

pub const Frame = struct {
    op: Op,
    /// Unmasked payload (a whole message for text and binary); valid until the next `read`.
    data: []u8,
};

const Out = struct { op: Op, data: []u8 };

pub const Socket = struct {
    io: Io,
    /// Holds messages that are fragmented or larger than the read buffer, and queued frames.
    gpa: std.mem.Allocator,
    in: *Io.Reader,
    out: *Io.Writer,
    stream: Io.net.Stream,
    write_lock: Io.Mutex = .init,
    /// Messages longer than this end the connection (close code 1009).
    max_payload: usize = 16 * 1024,
    closed: std.atomic.Value(bool) = .init(false),

    /// Queued sending (see the file comment): set before `writerLoop` starts.
    queued: bool = false,
    max_queued: usize = 16 * 1024 * 1024,
    queue_lock: Io.Mutex = .init,
    queue_cond: Io.Condition = .init,
    queue: std.ArrayList(Out) = .empty,
    queued_bytes: usize = 0,
    closing: bool = false,

    /// A message being assembled from fragments (or one larger than the read buffer).
    message: std.ArrayList(u8) = .empty,
    message_op: ?Op = null,
    control: [125]u8 = undefined,

    pub const ReadError = error{ MessageTooBig, ProtocolError, Closed, OutOfMemory };

    /// The next frame: a whole text or binary message, or a ping or pong (pings are answered
    /// here). A close frame is answered with the same code and reported as `error.Closed`.
    pub fn read(s: *Socket) ReadError!Frame {
        const in = s.in;
        while (true) {
            const h = in.takeArray(2) catch return error.Closed;
            const fin = h[0] & 0x80 != 0;
            const op: Op = @fromBackingInt(@intCast(@as(u4, @truncate(h[0]))));
            if (h[0] & 0x70 != 0) return s.protocolError(1002); // no extensions negotiated
            if (h[1] & 0x80 == 0) return s.protocolError(1002); // clients must mask
            var len: u64 = h[1] & 0x7f;
            if (len == 126) len = in.takeInt(u16, .big) catch return error.Closed;
            if (len == 127) len = in.takeInt(u64, .big) catch return error.Closed;
            if (len > s.max_payload) {
                s.close(1009);
                return error.MessageTooBig;
            }
            const mask = (in.takeArray(4) catch return error.Closed).*;
            const n: usize = @intCast(len);

            if (@backingInt(op) >= 8) {
                if (!fin or n > 125) return s.protocolError(1002);
                const data = s.control[0..n];
                in.readSliceAll(data) catch return error.Closed;
                unmask(data, mask);
                switch (op) {
                    .close => {
                        s.close(if (n >= 2) std.mem.readInt(u16, data[0..2], .big) else 1000);
                        return error.Closed;
                    },
                    .ping => s.send(.pong, data) catch return error.Closed,
                    .pong => {},
                    else => return s.protocolError(1002),
                }
                return .{ .op = op, .data = data };
            }

            switch (op) {
                .continuation => if (s.message_op == null) return s.protocolError(1002),
                .text, .binary => if (s.message_op != null) return s.protocolError(1002),
                else => return s.protocolError(1002),
            }
            // The common case, one frame that fits the read buffer: no copy.
            if (fin and op != .continuation and n <= in.buffer.len) {
                const data = in.take(n) catch return error.Closed;
                unmask(data, mask);
                if (op == .text and !std.unicode.utf8ValidateSlice(data)) return s.protocolError(1007);
                return .{ .op = op, .data = data };
            }
            if (op != .continuation) {
                s.message.clearRetainingCapacity();
                s.message_op = op;
            }
            const start = s.message.items.len;
            if (start + n > s.max_payload) {
                s.close(1009);
                return error.MessageTooBig;
            }
            try s.message.resize(s.gpa, start + n);
            const data = s.message.items[start..];
            in.readSliceAll(data) catch return error.Closed;
            unmask(data, mask);
            if (!fin) continue;
            const kind = s.message_op.?;
            s.message_op = null;
            if (kind == .text and !std.unicode.utf8ValidateSlice(s.message.items)) return s.protocolError(1007);
            return .{ .op = kind, .data = s.message.items };
        }
    }

    fn unmask(data: []u8, mask: [4]u8) void {
        for (data, 0..) |*b, i| b.* ^= mask[i % 4];
    }

    fn protocolError(s: *Socket, code: u16) error{ProtocolError} {
        s.close(code);
        return error.ProtocolError;
    }

    /// Sends one unfragmented frame (or queues it, see `queued`). Safe to call from any task.
    pub fn send(s: *Socket, op: Op, data: []const u8) !void {
        if (s.closed.load(.acquire)) return error.Closed;
        if (s.queued) return s.enqueue(op, data);
        s.write_lock.lockUncancelable(s.io);
        defer s.write_lock.unlock(s.io);
        writeFrame(s.out, op, data) catch return error.Closed;
        s.out.flush() catch return error.Closed;
    }

    pub fn sendText(s: *Socket, data: []const u8) !void {
        return s.send(.text, data);
    }

    fn enqueue(s: *Socket, op: Op, data: []const u8) !void {
        s.queue_lock.lockUncancelable(s.io);
        defer s.queue_lock.unlock(s.io);
        if (s.closing) return error.Closed;
        if (s.queued_bytes > s.max_queued) {
            // The client stopped reading: drop it rather than buffer without bound.
            s.terminateLocked();
            return error.Closed;
        }
        const copy = try s.gpa.dupe(u8, data);
        s.queue.append(s.gpa, .{ .op = op, .data = copy }) catch |e| {
            s.gpa.free(copy);
            return e;
        };
        s.queued_bytes += copy.len;
        s.queue_cond.signal(s.io);
    }

    /// The writer task of a queued socket: writes frames until the socket closes. Run it with
    /// `Io.Group.concurrent` after setting `queued`, and await it after `close`.
    pub fn writerLoop(s: *Socket) void {
        var batch: std.ArrayList(Out) = .empty;
        defer batch.deinit(s.gpa);
        while (true) {
            s.queue_lock.lockUncancelable(s.io);
            while (s.queue.items.len == 0 and !s.closing) s.queue_cond.waitUncancelable(s.io, &s.queue_lock);
            const done = s.closing;
            std.mem.swap(std.ArrayList(Out), &batch, &s.queue);
            s.queued_bytes = 0;
            s.queue_lock.unlock(s.io);
            var failed = s.closed.load(.acquire);
            for (batch.items) |f| {
                if (!failed) writeFrame(s.out, f.op, f.data) catch {
                    failed = true;
                };
                s.gpa.free(f.data);
            }
            batch.clearRetainingCapacity();
            if (!failed) s.out.flush() catch {
                failed = true;
            };
            if (failed or done) {
                s.queue_lock.lockUncancelable(s.io);
                s.closing = true;
                s.queue_lock.unlock(s.io);
                s.closed.store(true, .release);
                s.stream.shutdown(s.io, .both) catch {};
                return;
            }
        }
    }

    /// Sends a close frame with `code` and shuts the connection down, which also ends a `read`
    /// waiting in another task. Safe to call more than once and from any task. A queued socket
    /// sends what is already queued first.
    pub fn close(s: *Socket, code: u16) void {
        var payload: [2]u8 = undefined;
        std.mem.writeInt(u16, &payload, code, .big);
        if (s.queued) {
            s.enqueue(.close, &payload) catch {};
            s.queue_lock.lockUncancelable(s.io);
            defer s.queue_lock.unlock(s.io);
            s.closing = true;
            s.queue_cond.signal(s.io);
            return;
        }
        s.send(.close, &payload) catch {};
        s.closed.store(true, .release);
        s.stream.shutdown(s.io, .both) catch {};
    }

    /// Drops the connection at once (dead or flooding peers).
    pub fn terminate(s: *Socket) void {
        s.queue_lock.lockUncancelable(s.io);
        defer s.queue_lock.unlock(s.io);
        s.terminateLocked();
    }

    fn terminateLocked(s: *Socket) void {
        s.closing = true;
        s.closed.store(true, .release);
        s.stream.shutdown(s.io, .both) catch {};
        s.queue_cond.signal(s.io);
    }

    /// Frees the message buffer and anything still queued (after `writerLoop` has returned).
    pub fn deinit(s: *Socket) void {
        for (s.queue.items) |f| s.gpa.free(f.data);
        s.queue.deinit(s.gpa);
        s.message.deinit(s.gpa);
    }
};

fn writeFrame(w: *Io.Writer, op: Op, data: []const u8) !void {
    var hdr: [10]u8 = undefined;
    hdr[0] = 0x80 | @as(u8, @backingInt(op));
    var n: usize = 2;
    if (data.len < 126) {
        hdr[1] = @intCast(data.len);
    } else if (data.len <= 0xffff) {
        hdr[1] = 126;
        std.mem.writeInt(u16, hdr[2..4], @intCast(data.len), .big);
        n = 4;
    } else {
        hdr[1] = 127;
        std.mem.writeInt(u64, hdr[2..10], data.len, .big);
        n = 10;
    }
    try w.writeAll(hdr[0..n]);
    try w.writeAll(data);
}

test "frame header encoding" {
    // The masking and length rules are exercised by the HTTP tests over a real socket; here only
    // the opcode values, which the wire format fixes.
    try std.testing.expectEqual(@as(u4, 9), @backingInt(Op.ping));
    try std.testing.expectEqual(@as(u4, 10), @backingInt(Op.pong));
}
