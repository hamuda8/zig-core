//! Server-Sent Events fan-out: named channels, each with any number of open streams. Every
//! stream is served by its own connection task; `publish` only queues the encoded event for it
//! and wakes it, so a slow client never holds up the publisher. A heartbeat comment keeps idle
//! streams open through proxies, and a stream ends as soon as its client goes away.
//!
//!     var hub: http.sse.Hub = .init(io, gpa);
//!     // in a handler:
//!     hub.serve(ctx, ip, &.{"carrier:42"}, .{}) catch |e| switch (e) {
//!         error.TooManyStreams => return ctx.fail(.too_many_requests, "Too many open streams"),
//!         else => return e,
//!     };
//!     // anywhere:
//!     hub.publish("carrier:42", "shipment", "{\"id\":1}");

const std = @import("std");
const Io = std.Io;
const Context = @import("http.zig").Context;

pub const Options = struct {
    /// Sent first as `retry:` (the client's reconnect delay); null sends none.
    retry_ms: ?u32 = 5000,
    /// Encoded bytes sent right after (an initial event, see `encode`).
    first: ?[]const u8 = null,
};

const Stream = struct {
    lock: Io.Mutex = .init,
    cond: Io.Condition = .init,
    /// Encoded events waiting to be written (owned by the hub's gpa).
    pending: std.ArrayList([]u8) = .empty,
    /// The client went away (seen by the watcher task).
    closed: bool = false,
};

pub const Hub = struct {
    io: Io,
    gpa: std.mem.Allocator,
    heartbeat_ms: i64 = 25_000,
    /// Open streams allowed per client address.
    max_per_ip: u32 = 30,
    lock: Io.Mutex = .init,
    /// channel (owned) -> streams
    channels: std.StringHashMapUnmanaged(std.ArrayList(*Stream)) = .empty,
    /// ip (owned) -> open streams
    per_ip: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn init(io: Io, gpa: std.mem.Allocator) Hub {
        return .{ .io = io, .gpa = gpa };
    }

    /// After every stream has ended.
    pub fn deinit(hub: *Hub) void {
        var it = hub.channels.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(hub.gpa);
            hub.gpa.free(e.key_ptr.*);
        }
        hub.channels.deinit(hub.gpa);
        var ips = hub.per_ip.keyIterator();
        while (ips.next()) |k| hub.gpa.free(k.*);
        hub.per_ip.deinit(hub.gpa);
    }

    /// Opens an event stream on `channels` and serves it until the client leaves. Fails with
    /// error.TooManyStreams, before anything is sent, when `ip` has `max_per_ip` open.
    pub fn serve(hub: *Hub, ctx: *Context, ip: []const u8, channels: []const []const u8, options: Options) !void {
        const io = hub.io;
        const gpa = hub.gpa;
        if (!hub.reserve(ip)) return error.TooManyStreams;
        defer hub.release(ip);
        var stream: Stream = .{};

        try ctx.setHeader("content-type", "text/event-stream; charset=utf-8");
        try ctx.setHeader("cache-control", "no-cache, no-transform");
        try ctx.setHeader("x-accel-buffering", "no");
        ctx.responded = true;
        ctx.close_connection = true;
        var buf: [4096]u8 = undefined;
        var w = try ctx.request.respondStreaming(&buf, .{ .respond_options = .{ .extra_headers = ctx.response_headers.items, .keep_alive = false } });
        if (options.retry_ms) |ms| try w.writer.print("retry: {d}\n\n", .{ms});
        if (options.first) |f| try w.writer.writeAll(f);
        try w.writer.flush();
        try w.flush();

        try hub.join(channels, &stream);
        defer hub.leave(channels, &stream);
        var watcher = io.concurrent(watchClose, .{ io, ctx.stream, &stream }) catch null;
        defer if (watcher) |*f| f.cancel(io);

        while (true) {
            stream.lock.lockUncancelable(io);
            if (stream.pending.items.len == 0 and !stream.closed) {
                stream.cond.waitTimeout(io, &stream.lock, .{ .duration = .{ .raw = .fromMilliseconds(hub.heartbeat_ms), .clock = .awake } }) catch |e| switch (e) {
                    error.Timeout => {},
                    error.Canceled => {
                        stream.lock.unlock(io);
                        return;
                    },
                };
            }
            if (stream.closed) {
                stream.lock.unlock(io);
                return;
            }
            const batch = stream.pending.toOwnedSlice(gpa) catch &.{};
            stream.lock.unlock(io);
            defer {
                for (batch) |m| gpa.free(m);
                gpa.free(batch);
            }
            if (batch.len == 0) {
                w.writer.writeAll(": ping\n\n") catch return;
            } else for (batch) |m| w.writer.writeAll(m) catch return;
            // The body writer's buffer, then the connection's.
            w.writer.flush() catch return;
            w.flush() catch return;
        }
    }

    /// Sends an event to every stream on `channel`. `data` may span lines.
    pub fn publish(hub: *Hub, channel: []const u8, event: ?[]const u8, data: []const u8) void {
        if (!hub.hasSubscribers(channel)) return;
        var scratch = std.heap.ArenaAllocator.init(hub.gpa);
        defer scratch.deinit();
        const msg = encode(scratch.allocator(), event, data) catch return;
        hub.publishEncoded(channel, msg);
    }

    /// Queues already encoded bytes (see `encode`) for every stream on `channel`.
    pub fn publishEncoded(hub: *Hub, channel: []const u8, msg: []const u8) void {
        const io = hub.io;
        hub.lock.lockUncancelable(io);
        defer hub.lock.unlock(io);
        const list = hub.channels.get(channel) orelse return;
        for (list.items) |s| {
            const copy = hub.gpa.dupe(u8, msg) catch continue;
            s.lock.lockUncancelable(io);
            s.pending.append(hub.gpa, copy) catch hub.gpa.free(copy);
            s.lock.unlock(io);
            s.cond.signal(io);
        }
    }

    pub fn hasSubscribers(hub: *Hub, channel: []const u8) bool {
        hub.lock.lockUncancelable(hub.io);
        defer hub.lock.unlock(hub.io);
        return hub.channels.contains(channel);
    }

    fn reserve(hub: *Hub, ip: []const u8) bool {
        hub.lock.lockUncancelable(hub.io);
        defer hub.lock.unlock(hub.io);
        if (hub.per_ip.getPtr(ip)) |n| {
            if (n.* >= hub.max_per_ip) return false;
            n.* += 1;
            return true;
        }
        if (hub.max_per_ip == 0) return false;
        const k = hub.gpa.dupe(u8, ip) catch return true;
        hub.per_ip.put(hub.gpa, k, 1) catch hub.gpa.free(k);
        return true;
    }

    fn release(hub: *Hub, ip: []const u8) void {
        hub.lock.lockUncancelable(hub.io);
        defer hub.lock.unlock(hub.io);
        const n = hub.per_ip.getPtr(ip) orelse return;
        if (n.* <= 1) {
            const kv = hub.per_ip.fetchRemove(ip).?;
            hub.gpa.free(kv.key);
        } else n.* -= 1;
    }

    fn join(hub: *Hub, names: []const []const u8, s: *Stream) !void {
        hub.lock.lockUncancelable(hub.io);
        defer hub.lock.unlock(hub.io);
        for (names) |name| {
            const gop = try hub.channels.getOrPut(hub.gpa, name);
            if (!gop.found_existing) {
                gop.key_ptr.* = hub.gpa.dupe(u8, name) catch |e| {
                    hub.channels.removeByPtr(gop.key_ptr);
                    return e;
                };
                gop.value_ptr.* = .empty;
            }
            try gop.value_ptr.append(hub.gpa, s);
        }
    }

    fn leave(hub: *Hub, names: []const []const u8, s: *Stream) void {
        const io = hub.io;
        hub.lock.lockUncancelable(io);
        defer hub.lock.unlock(io);
        for (names) |name| {
            const list = hub.channels.getPtr(name) orelse continue;
            for (list.items, 0..) |x, i| if (x == s) {
                _ = list.swapRemove(i);
                break;
            };
            if (list.items.len == 0) {
                list.deinit(hub.gpa);
                const kv = hub.channels.fetchRemove(name).?;
                hub.gpa.free(kv.key);
            }
        }
        // Messages queued after the last write.
        s.lock.lockUncancelable(io);
        defer s.lock.unlock(io);
        for (s.pending.items) |m| hub.gpa.free(m);
        s.pending.deinit(hub.gpa);
    }
};

/// Waits for the client to close the connection (a stream client sends nothing else), so its
/// place is freed at once, not only at the next heartbeat.
fn watchClose(io: Io, net_stream: Io.net.Stream, s: *Stream) void {
    var buf: [256]u8 = undefined;
    var reader = net_stream.reader(io, &buf);
    while (true) _ = reader.interface.takeByte() catch break;
    s.lock.lockUncancelable(io);
    s.closed = true;
    s.lock.unlock(io);
    s.cond.signal(io);
}

/// "event: <event>\ndata: <line>\n...\n\n" (no event line when `event` is null).
pub fn encode(a: std.mem.Allocator, event: ?[]const u8, data: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (event) |e| try out.print(a, "event: {s}\n", .{e});
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| try out.print(a, "data: {s}\n", .{line});
    try out.append(a, '\n');
    return out.items;
}
