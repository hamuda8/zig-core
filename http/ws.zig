//! WebSocket framing (RFC 6455) after std.http's handshake. Unlike std's reader it reports pong
//! and close frames, so servers can tell live connections from dead ones, and its writes are
//! locked, so other tasks can send to this socket (a room relaying to its viewers).

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
    /// Unmasked payload; valid until the next `read`.
    data: []u8,
};

pub const Socket = struct {
    io: Io,
    in: *Io.Reader,
    out: *Io.Writer,
    stream: Io.net.Stream,
    write_lock: Io.Mutex = .init,
    /// Frames longer than this end the connection (close code 1009).
    max_payload: usize = 16 * 1024,
    closed: std.atomic.Value(bool) = .init(false),

    pub const ReadError = error{ MessageTooBig, ProtocolError, Closed };

    /// The next frame. Pings are answered here and also returned; a close frame is answered and
    /// reported as `error.Closed`.
    pub fn read(s: *Socket) ReadError!Frame {
        const in = s.in;
        const h = in.takeArray(2) catch return error.Closed;
        const fin = h[0] & 0x80 != 0;
        const op: Op = @fromBackingInt(@intCast(@as(u4, @truncate(h[0]))));
        if (h[0] & 0x70 != 0) return error.ProtocolError; // no extensions negotiated
        if (h[1] & 0x80 == 0) return error.ProtocolError; // clients must mask
        var len: u64 = h[1] & 0x7f;
        if (len == 126) len = in.takeInt(u16, .big) catch return error.Closed;
        if (len == 127) len = in.takeInt(u64, .big) catch return error.Closed;
        if (len > s.max_payload or len > in.buffer.len) {
            s.close(1009);
            return error.MessageTooBig;
        }
        if (!fin or op == .continuation) return error.ProtocolError; // fragmented messages unsupported
        const mask = (in.takeArray(4) catch return error.Closed).*;
        const data = in.take(@intCast(len)) catch return error.Closed;
        for (data, 0..) |*b, i| b.* ^= mask[i % 4];
        switch (op) {
            .close => {
                s.close(1000);
                return error.Closed;
            },
            .ping => s.send(.pong, data) catch return error.Closed,
            .text, .binary, .pong => {},
            else => return error.ProtocolError,
        }
        return .{ .op = op, .data = data };
    }

    /// Sends one unfragmented frame. Safe to call from any task.
    pub fn send(s: *Socket, op: Op, data: []const u8) !void {
        if (s.closed.load(.acquire)) return error.Closed;
        s.write_lock.lockUncancelable(s.io);
        defer s.write_lock.unlock(s.io);
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
        s.out.writeAll(hdr[0..n]) catch return error.Closed;
        s.out.writeAll(data) catch return error.Closed;
        s.out.flush() catch return error.Closed;
    }

    pub fn sendText(s: *Socket, data: []const u8) !void {
        return s.send(.text, data);
    }

    /// Sends a close frame with `code` and shuts the connection down, which also ends a `read`
    /// waiting in another task. Safe to call more than once and from any task.
    pub fn close(s: *Socket, code: u16) void {
        var payload: [2]u8 = undefined;
        std.mem.writeInt(u16, &payload, code, .big);
        s.send(.close, &payload) catch {};
        s.closed.store(true, .release);
        s.stream.shutdown(s.io, .both) catch {};
    }
};

test "frame header encoding" {
    // The masking and length rules are exercised by the HTTP tests over a real socket; here only
    // the opcode values, which the wire format fixes.
    try std.testing.expectEqual(@as(u4, 9), @backingInt(Op.ping));
    try std.testing.expectEqual(@as(u4, 10), @backingInt(Op.pong));
}
