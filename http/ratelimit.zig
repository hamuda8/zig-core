//! A fixed-window rate limiter kept in memory (one process), with express-rate-limit's
//! response headers. Declare one per limit as a plain variable:
//!
//!     var search_limit: http.RateLimiter = .{};
//!     if (!search_limit.allow(io, gpa, ctx.clientIp(), 60, 60_000, now_ms)) return ctx.fail(.too_many_requests, "Slow down");

const std = @import("std");
const Io = std.Io;
const Context = @import("http.zig").Context;

pub const RateLimiter = struct {
    lock: Io.Mutex = .init,
    /// key (owned by the gpa passed to `hit`) -> its window
    hits: std.StringHashMapUnmanaged(Window) = .empty,
    /// Past this many keys, finished windows are dropped (and if that is not enough, all).
    max_keys: usize = 50_000,

    pub const Window = struct { count: u32, reset_at: i64 };

    /// Counts one request for `key`; returns its window after counting it.
    pub fn hit(rl: *RateLimiter, io: Io, gpa: std.mem.Allocator, key: []const u8, window_ms: i64, now_ms: i64) Window {
        rl.lock.lockUncancelable(io);
        defer rl.lock.unlock(io);
        if (rl.hits.getPtr(key)) |w| {
            if (w.reset_at <= now_ms) w.* = .{ .count = 0, .reset_at = now_ms + window_ms };
            w.count +|= 1;
            return w.*;
        }
        const w: Window = .{ .count = 1, .reset_at = now_ms + window_ms };
        if (rl.hits.count() >= rl.max_keys) rl.prune(gpa, now_ms);
        const k = gpa.dupe(u8, key) catch return w;
        rl.hits.put(gpa, k, w) catch gpa.free(k);
        return w;
    }

    /// Counts one request; false when `key` is over `max` in the current window.
    pub fn allow(rl: *RateLimiter, io: Io, gpa: std.mem.Allocator, key: []const u8, max: u32, window_ms: i64, now_ms: i64) bool {
        return rl.hit(io, gpa, key, window_ms, now_ms).count <= max;
    }

    /// Counts one request and sets the RateLimit-Limit / -Remaining / -Reset headers (and
    /// Retry-After when over); true when the request is over the limit (answer 429).
    pub fn check(rl: *RateLimiter, ctx: *Context, gpa: std.mem.Allocator, key: []const u8, max: u32, window_ms: i64, now_ms: i64) !bool {
        const w = rl.hit(ctx.io, gpa, key, window_ms, now_ms);
        const reset_s = @divFloor(w.reset_at - now_ms + 999, 1000);
        try ctx.setHeader("ratelimit-limit", try std.fmt.allocPrint(ctx.arena, "{d}", .{max}));
        try ctx.setHeader("ratelimit-remaining", try std.fmt.allocPrint(ctx.arena, "{d}", .{if (w.count >= max) 0 else max - w.count}));
        try ctx.setHeader("ratelimit-reset", try std.fmt.allocPrint(ctx.arena, "{d}", .{reset_s}));
        if (w.count <= max) return false;
        try ctx.setHeader("retry-after", try std.fmt.allocPrint(ctx.arena, "{d}", .{reset_s}));
        return true;
    }

    fn prune(rl: *RateLimiter, gpa: std.mem.Allocator, now_ms: i64) void {
        var dead: std.ArrayList([]const u8) = .empty;
        defer dead.deinit(gpa);
        var it = rl.hits.iterator();
        while (it.next()) |e| if (e.value_ptr.reset_at <= now_ms) dead.append(gpa, e.key_ptr.*) catch break;
        for (dead.items) |k| {
            _ = rl.hits.remove(k);
            gpa.free(k);
        }
        if (rl.hits.count() >= rl.max_keys) rl.clear(gpa);
    }

    fn clear(rl: *RateLimiter, gpa: std.mem.Allocator) void {
        var it = rl.hits.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        rl.hits.clearRetainingCapacity();
    }

    pub fn deinit(rl: *RateLimiter, gpa: std.mem.Allocator) void {
        rl.clear(gpa);
        rl.hits.deinit(gpa);
    }
};

test "fixed windows per key" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var rl: RateLimiter = .{ .max_keys = 2 };
    defer rl.deinit(gpa);
    try std.testing.expect(rl.allow(io, gpa, "a", 2, 1000, 0));
    try std.testing.expect(rl.allow(io, gpa, "a", 2, 1000, 10));
    try std.testing.expect(!rl.allow(io, gpa, "a", 2, 1000, 20));
    try std.testing.expect(rl.allow(io, gpa, "b", 2, 1000, 20));
    // The window ends: counting starts over.
    try std.testing.expect(rl.allow(io, gpa, "a", 2, 1000, 1000));
    // A third key past max_keys drops finished windows ("b" is done by 5000).
    try std.testing.expect(rl.allow(io, gpa, "c", 2, 1000, 5000));
    try std.testing.expectEqual(@as(usize, 1), rl.hits.count());
}
