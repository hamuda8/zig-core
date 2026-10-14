//! Gestures from pointer events (`BoxOptions.on_pointer`), the same on every platform: tap,
//! double tap, pan, pinch, swipe and the mouse wheel. Feed each Pointer to a Recognizer kept in
//! the app's state; act on what it returns. Coordinates are the view's, as the pointer's.
//!
//!     .finger => |p| switch (s.gestures.feed(p)) {
//!         .pinch => |g| s.zoom *= g.scale,
//!         .pan => |g| { s.x += g.dx; s.y += g.dy; },
//!         .double_tap => s.zoom = if (s.zoom > 1) 1 else 2.5,
//!         .swipe => |dir| ...,
//!         else => {},
//!     },

const std = @import("std");
const runtime = @import("runtime.zig");
const Pointer = runtime.Pointer;

pub const Dir = enum { left, right, up, down };

pub const Gesture = union(enum) {
    none,
    /// One finger (or click) down and up without moving.
    tap: struct { x: f32, y: f32 },
    /// A second tap soon after the first, near it.
    double_tap: struct { x: f32, y: f32 },
    /// One finger moved this much since the last event (after it moved enough to be a pan).
    pan: struct { dx: f32, dy: f32 },
    /// Two fingers: the distance between them changed by this factor since the last event,
    /// around their middle; their middle also moved by dx, dy.
    pinch: struct { scale: f32, x: f32, y: f32, dx: f32, dy: f32 },
    /// A quick one-finger flick, when it lifts.
    swipe: Dir,
    /// The mouse wheel (or a trackpad's two-finger scroll) at a point: positive scrolls down.
    wheel: struct { delta: f32, x: f32, y: f32 },
    /// The fingers lifted after a pan or a pinch.
    end,
};

const Finger = struct { id: u32, x: f32, y: f32, x0: f32, y0: f32, t0: i64 };

pub const Recognizer = struct {
    fingers: [2]?Finger = .{ null, null },
    /// Moved beyond the slop: not a tap.
    moved: bool = false,
    /// Two fingers were down during this touch.
    pinched: bool = false,
    last_tap: ?struct { x: f32, y: f32, t: i64 } = null,

    /// How far a finger may move and still tap, in points.
    pub const slop: f32 = 8;
    /// The second tap of a double tap comes within this many milliseconds, this near the first.
    pub const double_ms: i64 = 300;
    pub const double_dist: f32 = 30;
    /// A swipe covers this many points at this many points per millisecond.
    pub const swipe_dist: f32 = 60;
    pub const swipe_speed: f32 = 0.35;

    fn count(r: *const Recognizer) usize {
        var n: usize = 0;
        for (r.fingers) |f| if (f != null) {
            n += 1;
        };
        return n;
    }

    fn find(r: *Recognizer, id: u32) ?*Finger {
        for (&r.fingers) |*f| if (f.*) |*x| if (x.id == id) return x;
        return null;
    }

    fn pair(r: *const Recognizer) ?[2]Finger {
        if (r.fingers[0] == null or r.fingers[1] == null) return null;
        return .{ r.fingers[0].?, r.fingers[1].? };
    }

    pub fn feed(r: *Recognizer, p: Pointer) Gesture {
        switch (p.kind) {
            .wheel => return .{ .wheel = .{ .delta = p.wheel, .x = p.x, .y = p.y } },
            .down => {
                if (r.count() == 0) {
                    r.moved = false;
                    r.pinched = false;
                }
                for (&r.fingers) |*f| if (f.* == null) {
                    f.* = .{ .id = p.id, .x = p.x, .y = p.y, .x0 = p.x, .y0 = p.y, .t0 = p.time_ms };
                    break;
                };
                if (r.count() == 2) {
                    r.pinched = true;
                    r.moved = true;
                }
                return .none;
            },
            .move => {
                const f = r.find(p.id) orelse return .none;
                if (r.pair()) |two| {
                    const other = if (two[0].id == p.id) two[1] else two[0];
                    const before = dist(f.x, f.y, other.x, other.y);
                    const after = dist(p.x, p.y, other.x, other.y);
                    const mx0 = (f.x + other.x) / 2;
                    const my0 = (f.y + other.y) / 2;
                    const mx1 = (p.x + other.x) / 2;
                    const my1 = (p.y + other.y) / 2;
                    f.x = p.x;
                    f.y = p.y;
                    if (before < 1) return .none;
                    return .{ .pinch = .{ .scale = after / before, .x = mx1, .y = my1, .dx = mx1 - mx0, .dy = my1 - my0 } };
                }
                const dx = p.x - f.x;
                const dy = p.y - f.y;
                f.x = p.x;
                f.y = p.y;
                if (!r.moved and dist(p.x, p.y, f.x0, f.y0) <= slop) return .none;
                if (!r.moved) {
                    r.moved = true;
                    // The whole way from the start, at once.
                    return .{ .pan = .{ .dx = p.x - f.x0, .dy = p.y - f.y0 } };
                }
                return .{ .pan = .{ .dx = dx, .dy = dy } };
            },
            .up, .cancel => {
                const f = r.find(p.id) orelse return .none;
                const done = f.*;
                for (&r.fingers) |*x| if (x.* != null and x.*.?.id == p.id) {
                    x.* = null;
                };
                if (r.count() > 0) return .none;
                if (p.kind == .cancel) return if (r.moved) .end else .none;
                if (r.pinched) return .end;
                if (!r.moved) {
                    if (r.last_tap) |lt| if (p.time_ms - lt.t <= double_ms and dist(p.x, p.y, lt.x, lt.y) <= double_dist) {
                        r.last_tap = null;
                        return .{ .double_tap = .{ .x = p.x, .y = p.y } };
                    };
                    r.last_tap = .{ .x = p.x, .y = p.y, .t = p.time_ms };
                    return .{ .tap = .{ .x = p.x, .y = p.y } };
                }
                const dx = p.x - done.x0;
                const dy = p.y - done.y0;
                const ms: f32 = @floatFromInt(@max(1, p.time_ms - done.t0));
                const far = @max(@abs(dx), @abs(dy));
                if (far >= swipe_dist and far / ms >= swipe_speed) {
                    return .{ .swipe = if (@abs(dx) >= @abs(dy)) (if (dx < 0) .left else .right) else (if (dy < 0) .up else .down) };
                }
                return .end;
            },
        }
    }
};

fn dist(ax: f32, ay: f32, bx: f32, by: f32) f32 {
    return @sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by));
}

const testing = std.testing;

fn ev(kind: Pointer.Kind, id: u32, x: f32, y: f32, t: i64) Pointer {
    return .{ .kind = kind, .id = id, .x = x, .y = y, .time_ms = t };
}

test "tap and double tap" {
    var r: Recognizer = .{};
    _ = r.feed(ev(.down, 1, 10, 10, 0));
    try testing.expect(r.feed(ev(.up, 1, 11, 10, 80)) == .tap);
    _ = r.feed(ev(.down, 1, 12, 11, 200));
    try testing.expect(r.feed(ev(.up, 1, 12, 11, 260)) == .double_tap);
    // A third tap starts over.
    _ = r.feed(ev(.down, 1, 12, 11, 330));
    try testing.expect(r.feed(ev(.up, 1, 12, 11, 360)) == .tap);
}

test "pan, then a swipe" {
    var r: Recognizer = .{};
    _ = r.feed(ev(.down, 1, 100, 100, 0));
    try testing.expect(r.feed(ev(.move, 1, 103, 100, 10)) == .none);
    const g = r.feed(ev(.move, 1, 120, 100, 20));
    try testing.expectEqual(@as(f32, 20), g.pan.dx);
    try testing.expectEqual(@as(f32, 5), r.feed(ev(.move, 1, 125, 100, 30)).pan.dx);
    try testing.expectEqual(Dir.right, r.feed(ev(.up, 1, 190, 105, 120)).swipe);
    // A slow drag is not a swipe.
    _ = r.feed(ev(.down, 1, 100, 100, 1000));
    _ = r.feed(ev(.move, 1, 200, 100, 1500));
    try testing.expect(r.feed(ev(.up, 1, 200, 100, 2000)) == .end);
}

test "pinch" {
    var r: Recognizer = .{};
    _ = r.feed(ev(.down, 1, 100, 100, 0));
    _ = r.feed(ev(.down, 2, 200, 100, 5));
    const g = r.feed(ev(.move, 2, 300, 100, 20));
    try testing.expectApproxEqAbs(@as(f32, 2), g.pinch.scale, 0.001);
    try testing.expectEqual(@as(f32, 200), g.pinch.x);
    _ = r.feed(ev(.up, 1, 100, 100, 40));
    try testing.expect(r.feed(ev(.up, 2, 300, 100, 50)) == .end);
}

test "wheel" {
    var r: Recognizer = .{};
    try testing.expectEqual(@as(f32, -3), r.feed(.{ .kind = .wheel, .id = 0, .x = 5, .y = 6, .wheel = -3 }).wheel.delta);
}
