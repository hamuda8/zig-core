//! Vector icons from SVG path data ("M12 2 L22 20 Z", curves and arcs too), drawn by each
//! platform's own path drawing: the same shapes everywhere, crisp at any size, no image files.

const std = @import("std");

pub const Icon = struct {
    /// SVG path data, in a `box`-sized square (24 like most icon sets).
    paths: []const []const u8,
    /// Filled shapes rather than lines.
    fill: bool = false,
    /// Line width, in the box's units.
    stroke: f32 = 2,
    box: f32 = 24,
    /// Top-left corner of the box (Material Symbols use "0 -960 960 960").
    origin: [2]f32 = .{ 0, 0 },
};

/// Marks the start of a new sub-path in a point list.
pub const gap: [2]f32 = .{ std.math.nan(f32), 0 };

/// The icon's outline as points scaled to `size`, sub-paths separated by `gap`.
pub fn points(arena: std.mem.Allocator, icon: Icon, size: f32) ![]const [2]f32 {
    var out: std.ArrayList([2]f32) = .empty;
    const k = size / icon.box;
    for (icon.paths) |d| {
        if (out.items.len > 0) try out.append(arena, gap);
        try flatten(arena, d, k, icon.origin, &out);
    }
    return out.items;
}

const Parser = struct {
    s: []const u8,
    i: usize = 0,

    fn skip(p: *Parser) void {
        while (p.i < p.s.len and (std.ascii.isWhitespace(p.s[p.i]) or p.s[p.i] == ',')) p.i += 1;
    }

    fn command(p: *Parser) ?u8 {
        p.skip();
        if (p.i < p.s.len and std.ascii.isAlphabetic(p.s[p.i])) {
            p.i += 1;
            return p.s[p.i - 1];
        }
        return null;
    }

    fn hasNumber(p: *Parser) bool {
        p.skip();
        if (p.i >= p.s.len) return false;
        const c = p.s[p.i];
        return std.ascii.isDigit(c) or c == '-' or c == '.' or c == '+';
    }

    fn number(p: *Parser) !f32 {
        p.skip();
        const start = p.i;
        if (p.i < p.s.len and (p.s[p.i] == '-' or p.s[p.i] == '+')) p.i += 1;
        var dot = false;
        while (p.i < p.s.len) : (p.i += 1) {
            const c = p.s[p.i];
            if (std.ascii.isDigit(c)) continue;
            if (c == '.' and !dot) {
                dot = true;
                continue;
            }
            if ((c == 'e' or c == 'E') and p.i + 1 < p.s.len) {
                p.i += 1;
                if (p.s[p.i] == '-' or p.s[p.i] == '+') p.i += 1;
                continue;
            }
            break;
        }
        return std.fmt.parseFloat(f32, p.s[start..p.i]) catch error.BadPath;
    }

    /// Arc flags may be written without separators ("a1 1 0 01 2 2").
    fn flag(p: *Parser) !bool {
        p.skip();
        if (p.i >= p.s.len) return error.BadPath;
        const c = p.s[p.i];
        p.i += 1;
        return switch (c) {
            '0' => false,
            '1' => true,
            else => error.BadPath,
        };
    }
};

const segments = 10;

fn flatten(arena: std.mem.Allocator, d: []const u8, k: f32, origin: [2]f32, out: *std.ArrayList([2]f32)) !void {
    var p: Parser = .{ .s = d };
    var cur: [2]f32 = .{ 0, 0 };
    var start: [2]f32 = .{ 0, 0 };
    var ctrl: ?[2]f32 = null; // last control point, for S and T
    var cmd: u8 = 'M';
    var first_sub = true;
    const Put = struct {
        origin: [2]f32,
        fn f(self: @This(), o: *std.ArrayList([2]f32), a: std.mem.Allocator, pt: [2]f32, kk: f32) !void {
            try o.append(a, .{ (pt[0] - self.origin[0]) * kk, (pt[1] - self.origin[1]) * kk });
        }
    };
    const putter: Put = .{ .origin = origin };
    while (true) {
        if (p.command()) |c| {
            cmd = c;
        } else if (!p.hasNumber()) break;
        const rel = std.ascii.isLower(cmd);
        const base: [2]f32 = if (rel) cur else .{ 0, 0 };
        switch (std.ascii.toUpper(cmd)) {
            'M' => {
                const x = try p.number() + base[0];
                const y = try p.number() + base[1];
                if (!first_sub) try out.append(arena, gap);
                first_sub = false;
                cur = .{ x, y };
                start = cur;
                try putter.f(out, arena, cur, k);
                // More pairs after M are lines.
                cmd = if (rel) 'l' else 'L';
                ctrl = null;
            },
            'L' => {
                cur = .{ try p.number() + base[0], try p.number() + base[1] };
                try putter.f(out, arena, cur, k);
                ctrl = null;
            },
            'H' => {
                cur[0] = try p.number() + base[0];
                try putter.f(out, arena, cur, k);
                ctrl = null;
            },
            'V' => {
                cur[1] = try p.number() + base[1];
                try putter.f(out, arena, cur, k);
                ctrl = null;
            },
            'C', 'S' => {
                const c1: [2]f32 = if (std.ascii.toUpper(cmd) == 'C')
                    .{ try p.number() + base[0], try p.number() + base[1] }
                else if (ctrl) |c| .{ 2 * cur[0] - c[0], 2 * cur[1] - c[1] } else cur;
                const c2: [2]f32 = .{ try p.number() + base[0], try p.number() + base[1] };
                const end: [2]f32 = .{ try p.number() + base[0], try p.number() + base[1] };
                for (1..segments + 1) |n| {
                    const t: f32 = @as(f32, @floatFromInt(n)) / segments;
                    const u = 1 - t;
                    try putter.f(out, arena, .{
                        u * u * u * cur[0] + 3 * u * u * t * c1[0] + 3 * u * t * t * c2[0] + t * t * t * end[0],
                        u * u * u * cur[1] + 3 * u * u * t * c1[1] + 3 * u * t * t * c2[1] + t * t * t * end[1],
                    }, k);
                }
                ctrl = c2;
                cur = end;
            },
            'Q', 'T' => {
                const c1: [2]f32 = if (std.ascii.toUpper(cmd) == 'Q')
                    .{ try p.number() + base[0], try p.number() + base[1] }
                else if (ctrl) |c| .{ 2 * cur[0] - c[0], 2 * cur[1] - c[1] } else cur;
                const end: [2]f32 = .{ try p.number() + base[0], try p.number() + base[1] };
                for (1..segments + 1) |n| {
                    const t: f32 = @as(f32, @floatFromInt(n)) / segments;
                    const u = 1 - t;
                    try putter.f(out, arena, .{ u * u * cur[0] + 2 * u * t * c1[0] + t * t * end[0], u * u * cur[1] + 2 * u * t * c1[1] + t * t * end[1] }, k);
                }
                ctrl = c1;
                cur = end;
            },
            'A' => {
                const rx = @abs(try p.number());
                const ry = @abs(try p.number());
                const rot = try p.number();
                const large = try p.flag();
                const sweep = try p.flag();
                const end: [2]f32 = .{ try p.number() + base[0], try p.number() + base[1] };
                try arc(arena, out, cur, end, rx, ry, rot, large, sweep, k, origin);
                cur = end;
                ctrl = null;
            },
            'Z' => {
                cur = start;
                try putter.f(out, arena, cur, k);
                ctrl = null;
                // A path may continue after Z without a new M.
                if (!p.hasNumber()) continue;
                cmd = 'L';
            },
            else => return error.BadPath,
        }
    }
}

/// An SVG elliptical arc as line segments (endpoint to centre parameterization, SVG spec F.6).
fn arc(arena: std.mem.Allocator, out: *std.ArrayList([2]f32), from: [2]f32, to: [2]f32, rx_in: f32, ry_in: f32, rot_deg: f32, large: bool, sweep: bool, k: f32, origin: [2]f32) !void {
    if (rx_in == 0 or ry_in == 0 or (from[0] == to[0] and from[1] == to[1])) {
        try out.append(arena, .{ (to[0] - origin[0]) * k, (to[1] - origin[1]) * k });
        return;
    }
    const phi = std.math.degreesToRadians(rot_deg);
    const cos_p = @cos(phi);
    const sin_p = @sin(phi);
    const dx = (from[0] - to[0]) / 2;
    const dy = (from[1] - to[1]) / 2;
    const x1 = cos_p * dx + sin_p * dy;
    const y1 = -sin_p * dx + cos_p * dy;
    var rx = rx_in;
    var ry = ry_in;
    const lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry);
    if (lambda > 1) {
        rx *= @sqrt(lambda);
        ry *= @sqrt(lambda);
    }
    const num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1;
    const den = rx * rx * y1 * y1 + ry * ry * x1 * x1;
    var co = @sqrt(@max(0, num / den));
    if (large == sweep) co = -co;
    const cx1 = co * rx * y1 / ry;
    const cy1 = -co * ry * x1 / rx;
    const cx = cos_p * cx1 - sin_p * cy1 + (from[0] + to[0]) / 2;
    const cy = sin_p * cx1 + cos_p * cy1 + (from[1] + to[1]) / 2;
    const angle = struct {
        fn f(ux: f32, uy: f32, vx: f32, vy: f32) f32 {
            const a = std.math.atan2(uy, ux);
            const b = std.math.atan2(vy, vx);
            return b - a;
        }
    }.f;
    const theta1 = std.math.atan2((y1 - cy1) / ry, (x1 - cx1) / rx);
    var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry);
    const tau: f32 = 2 * std.math.pi;
    if (!sweep and delta > 0) delta -= tau;
    if (sweep and delta < 0) delta += tau;
    const n: usize = @max(4, @as(usize, @intFromFloat(@ceil(@abs(delta) / (std.math.pi / 12.0)))));
    for (1..n + 1) |i| {
        const t = theta1 + delta * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        const ex = rx * @cos(t);
        const ey = ry * @sin(t);
        try out.append(arena, .{ (cos_p * ex - sin_p * ey + cx - origin[0]) * k, (sin_p * ex + cos_p * ey + cy - origin[1]) * k });
    }
}

/// SVG path data for a circle, for icons built from shapes.
pub fn circle(comptime cx: f32, comptime cy: f32, comptime r: f32) []const u8 {
    return std.fmt.comptimePrint("M{d} {d}A{d} {d} 0 1 1 {d} {d}A{d} {d} 0 1 1 {d} {d}Z", .{ cx - r, cy, r, r, cx + r, cy, r, r, cx - r, cy });
}

test "lines, relative moves and sub-paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const pts = try points(arena.allocator(), .{ .paths = &.{"M2 2 h20 v20 H2 z m4 4 l4 0"} }, 48);
    // Scaled by 2: (4,4) (44,4) (44,44) (4,44) (4,4) | (12,12) (20,12)
    try std.testing.expectEqual([2]f32{ 4, 4 }, pts[0]);
    try std.testing.expectEqual([2]f32{ 44, 44 }, pts[2]);
    try std.testing.expectEqual([2]f32{ 4, 4 }, pts[4]);
    try std.testing.expect(std.math.isNan(pts[5][0]));
    try std.testing.expectEqual([2]f32{ 12, 12 }, pts[6]);
    try std.testing.expectEqual([2]f32{ 20, 12 }, pts[7]);
}

test "a circle from two arcs stays on its radius" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const pts = try points(arena.allocator(), .{ .paths = &.{circle(12, 12, 10)} }, 24);
    for (pts) |pt| try std.testing.expectApproxEqAbs(@as(f32, 10), std.math.hypot(pt[0] - 12, pt[1] - 12), 1e-3);
}

test "curves end where they say" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const pts = try points(arena.allocator(), .{ .paths = &.{"M0 0C0 10 10 10 10 0s10-10 10 0q5 5 10 0t10 0"} }, 24);
    try std.testing.expectEqual([2]f32{ 40, 0 }, pts[pts.len - 1]);
}
