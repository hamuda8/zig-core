//! Barcodes from a grayscale picture (a camera frame), in plain Zig: Code 128 (code sets A, B
//! and C, shifts, FNC1 and FNC4, the checksum) and QR (versions 1 to 40, every error correction
//! level, Reed-Solomon over GF(256), the eight masks, numeric, alphanumeric, byte and kanji
//! segments; ECI is read past). The picture is made black and white with a threshold that
//! follows the light across it; QR codes are found by their three finder patterns, Code 128 on
//! lines across the picture. `encodeQr` and `encodeCode128` draw codes, for tests.

const std = @import("std");
/// Prints what the QR finder sees (tests, by hand).
var debug = false;

pub const Format = enum(u8) { code_128 = 1, qr = 2 };

/// What to look for.
pub const Formats = packed struct(u8) {
    code_128: bool = true,
    qr: bool = true,
    _: u6 = 0,
};

/// One byte per pixel, 0 black to 255 white (a camera's Y plane), `stride` bytes a row.
pub const Image = struct {
    width: usize,
    height: usize,
    pixels: []const u8,
    /// 0: `width`.
    stride: usize = 0,

    fn at(img: Image, x: usize, y: usize) u8 {
        return img.pixels[y * (if (img.stride == 0) img.width else img.stride) + x];
    }
};

pub const Result = struct {
    format: Format,
    /// The text (owned by the caller's allocator). QR byte segments are as they are (usually
    /// UTF-8); kanji segments come as their Shift JIS bytes.
    text: []u8,
};

/// The first code found in `img`, or null.
pub fn decode(a: std.mem.Allocator, img: Image, formats: Formats) !?Result {
    if (img.width < 8 or img.height < 8) return null;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bits = try binarize(arena, img);
    if (formats.qr) {
        if (try findQr(arena, bits)) |text| return .{ .format = .qr, .text = try a.dupe(u8, text) };
    }
    if (formats.code_128) {
        if (try findCode128(arena, img, bits)) |text| return .{ .format = .code_128, .text = try a.dupe(u8, text) };
    }
    return null;
}

// ---- Black and white ----------------------------------------------------------------------

const Bits = struct {
    w: usize,
    h: usize,
    /// 1: dark.
    data: []u8,

    fn get(b: Bits, x: usize, y: usize) bool {
        return b.data[y * b.w + x] != 0;
    }

    fn getI(b: Bits, x: i64, y: i64) bool {
        if (x < 0 or y < 0 or x >= b.w or y >= b.h) return false;
        return b.get(@intCast(x), @intCast(y));
    }
};

/// A threshold per 8x8 block from the blocks around it: dark where the picture is darker than
/// its surroundings, so shade and uneven light do not matter. Flat blocks take their
/// neighbours' level, so the middle of a large dark area stays dark.
fn binarize(a: std.mem.Allocator, img: Image) !Bits {
    const bs = 8;
    const w = img.width;
    const h = img.height;
    const bw = (w + bs - 1) / bs;
    const bh = (h + bs - 1) / bs;
    const levels = try a.alloc(u32, bw * bh);
    for (0..bh) |by| for (0..bw) |bx| {
        var sum: u32 = 0;
        var n: u32 = 0;
        var lo: u32 = 255;
        var hi: u32 = 0;
        for (by * bs..@min(h, by * bs + bs)) |y| for (bx * bs..@min(w, bx * bs + bs)) |x| {
            const p = img.at(x, y);
            sum += p;
            n += 1;
            lo = @min(lo, p);
            hi = @max(hi, p);
        };
        var avg = sum / n;
        if (hi - lo <= 24) {
            avg = lo / 2;
            if (by > 0 and bx > 0) {
                const around = (levels[(by - 1) * bw + bx] + 2 * levels[by * bw + bx - 1] + levels[(by - 1) * bw + bx - 1]) / 4;
                if (lo < around) avg = around;
            }
        }
        levels[by * bw + bx] = avg;
    };
    const data = try a.alloc(u8, w * h);
    for (0..bh) |by| for (0..bw) |bx| {
        var sum: u32 = 0;
        var n: u32 = 0;
        const y0 = @max(@as(i64, @intCast(by)) - 2, 0);
        const x0 = @max(@as(i64, @intCast(bx)) - 2, 0);
        var yy: i64 = y0;
        while (yy <= @min(@as(i64, @intCast(by)) + 2, @as(i64, @intCast(bh)) - 1)) : (yy += 1) {
            var xx: i64 = x0;
            while (xx <= @min(@as(i64, @intCast(bx)) + 2, @as(i64, @intCast(bw)) - 1)) : (xx += 1) {
                sum += levels[@as(usize, @intCast(yy)) * bw + @as(usize, @intCast(xx))];
                n += 1;
            }
        }
        const threshold = sum / n;
        for (by * bs..@min(h, by * bs + bs)) |y| for (bx * bs..@min(w, bx * bs + bs)) |x| {
            data[y * w + x] = @intFromBool(img.at(x, y) <= threshold);
        };
    };
    return .{ .w = w, .h = h, .data = data };
}

// ---- Code 128 -----------------------------------------------------------------------------

/// Bar and space widths of symbols 0 to 105; 106 is the stop (seven elements).
pub const code128_patterns = [107][]const u8{
    "212222", "222122", "222221", "121223", "121322", "131222", "122213", "122312", "132212", "221213",
    "221312", "231212", "112232", "122132", "122231", "113222", "123122", "123221", "223211", "221132",
    "221231", "213212", "223112", "312131", "311222", "321122", "321221", "312212", "322112", "322211",
    "212123", "212321", "232121", "111323", "131123", "131321", "112313", "132113", "132311", "211313",
    "231113", "231311", "112133", "112331", "132131", "113123", "113321", "133121", "313121", "211331",
    "231131", "213113", "213311", "213131", "311123", "311321", "331121", "312113", "312311", "332111",
    "314111", "221411", "431111", "111224", "111422", "121124", "121421", "141122", "141221", "112214",
    "112412", "122114", "122411", "142112", "142211", "241211", "221114", "413111", "241112", "134111",
    "111242", "121142", "121241", "114212", "124112", "124211", "411212", "421112", "421211", "212141",
    "214121", "412121", "111143", "111341", "131141", "114113", "114311", "411113", "411311", "113141",
    "114131", "311141", "411131", "211412", "211214", "211232", "2331112",
};

const start_a = 103;
const start_b = 104;
const start_c = 105;
const stop_symbol = 106;

/// Rows across the picture, each read left to right and right to left.
fn findCode128(a: std.mem.Allocator, img: Image, bits: Bits) !?[]const u8 {
    const rows = 25;
    var runs: std.ArrayList(u32) = .empty;
    var k: usize = 0;
    while (k < rows) : (k += 1) {
        // From the middle outwards.
        const off = (k + 1) / 2;
        const sign: i64 = if (k % 2 == 0) 1 else -1;
        const y_i = @as(i64, @intCast(img.height / 2)) + sign * @as(i64, @intCast(off * img.height / (rows + 1)));
        if (y_i < 0 or y_i >= img.height) continue;
        const y: usize = @intCast(y_i);
        // Runs of this row: first light, then dark, light...
        runs.clearRetainingCapacity();
        var dark = false;
        var n: u32 = 0;
        for (0..bits.w) |x| {
            const d = bits.get(x, y);
            if (d == dark) {
                n += 1;
            } else {
                try runs.append(a, n);
                dark = d;
                n = 1;
            }
        }
        try runs.append(a, n);
        if (try readCode128(a, runs.items)) |t| return t;
        std.mem.reverse(u32, runs.items);
        // Reversed, the row must still start with a light run.
        if (runs.items.len % 2 == 0) {
            if (try readCode128(a, runs.items[0..])) |t| return t;
        } else {
            if (try readCode128(a, runs.items)) |t| return t;
        }
    }
    return null;
}

/// How far `widths` (bars and spaces in pixels) are from a pattern, in modules.
fn mismatch(widths: []const u32, pattern: []const u8) f32 {
    var total: u32 = 0;
    for (widths) |w| total += w;
    var modules: u32 = 0;
    for (pattern) |c| modules += c - '0';
    const unit = @as(f32, @floatFromInt(total)) / @as(f32, @floatFromInt(modules));
    if (unit <= 0) return 99;
    var err: f32 = 0;
    for (widths, pattern) |w, c| err += @abs(@as(f32, @floatFromInt(w)) / unit - @as(f32, @floatFromInt(c - '0')));
    return err;
}

fn bestSymbol(widths: []const u32) ?u8 {
    var best: ?u8 = null;
    var best_err: f32 = 2.2;
    for (code128_patterns[0..106], 0..) |p, v| {
        const e = mismatch(widths, p);
        if (e < best_err) {
            best_err = e;
            best = @intCast(v);
        }
    }
    return best;
}

/// `runs` alternate light, dark, light...: index 1, 3, 5 are bars.
fn readCode128(a: std.mem.Allocator, runs: []const u32) !?[]const u8 {
    var i: usize = 1;
    while (i + 6 < runs.len) : (i += 2) {
        const sym = runs[i .. i + 6];
        var width: u32 = 0;
        for (sym) |w| width += w;
        // A start symbol with a quiet zone of several modules before it.
        if (runs[i - 1] * 11 < width * 4) continue;
        var start: ?u8 = null;
        for ([_]u8{ start_a, start_b, start_c }) |s| if (mismatch(sym, code128_patterns[s]) < 1.6) {
            start = s;
        };
        const s = start orelse continue;
        if (try readSymbols(a, runs[i..], s)) |t| return t;
    }
    return null;
}

fn readSymbols(a: std.mem.Allocator, runs: []const u32, start: u8) !?[]const u8 {
    var values: std.ArrayList(u8) = .empty;
    try values.append(a, start);
    var at: usize = 6;
    while (true) {
        if (at + 7 <= runs.len and mismatch(runs[at .. at + 7], code128_patterns[stop_symbol]) < 2.0) break;
        if (at + 6 > runs.len) return null;
        const v = bestSymbol(runs[at .. at + 6]) orelse return null;
        if (v >= start_a) return null;
        try values.append(a, v);
        at += 6;
    }
    // Start, at least one character, and the check symbol.
    if (values.items.len < 3) return null;
    const check = values.pop().?;
    var sum: u32 = values.items[0];
    for (values.items[1..], 1..) |v, k| sum += @as(u32, v) * @as(u32, @intCast(k));
    if (sum % 103 != check) return null;
    return try code128Text(a, values.items);
}

fn code128Text(a: std.mem.Allocator, values: []const u8) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var set: u8 = switch (values[0]) {
        start_a => 'A',
        start_b => 'B',
        else => 'C',
    };
    var shift = false;
    var high = false;
    for (values[1..], 0..) |v, k| {
        const current: u8 = if (shift) (if (set == 'A') 'B' else 'A') else set;
        shift = false;
        if (current == 'C') {
            switch (v) {
                0...99 => {
                    try out.append(a, '0' + v / 10);
                    try out.append(a, '0' + v % 10);
                },
                100 => set = 'B',
                101 => set = 'A',
                102 => if (k > 0) try out.append(a, 29), // FNC1 (GS1): a separator
                else => return null,
            }
            continue;
        }
        switch (v) {
            0...95 => {
                var c: u8 = if (current == 'A') (if (v < 64) v + 32 else v - 64) else v + 32;
                if (high) {
                    c +%= 128;
                    high = false;
                }
                try out.append(a, c);
            },
            96, 97 => {}, // FNC3, FNC2
            98 => shift = true,
            99 => set = 'C',
            100 => if (current == 'A') {
                set = 'B';
            } else {
                high = true; // FNC4: the next character is above 127
            },
            101 => if (current == 'B') {
                set = 'A';
            } else {
                high = true;
            },
            102 => if (k > 0) try out.append(a, 29),
            else => return null,
        }
    }
    return out.items;
}

// ---- QR: finding it -----------------------------------------------------------------------

const Point = struct { x: f64, y: f64 };

const Finder = struct { x: f64, y: f64, module: f64, count: u32 };

fn crossOk(c: [5]u32) bool {
    var total: u32 = 0;
    for (c) |v| {
        if (v == 0) return false;
        total += v;
    }
    if (total < 7) return false;
    const m = @as(f64, @floatFromInt(total)) / 7;
    const tol = m / 2;
    const f = struct {
        fn v(x: u32) f64 {
            return @floatFromInt(x);
        }
    }.v;
    return @abs(m - f(c[0])) < tol and @abs(m - f(c[1])) < tol and @abs(3 * m - f(c[2])) < 3 * tol and @abs(m - f(c[3])) < tol and @abs(m - f(c[4])) < tol;
}

fn crossTotal(c: [5]u32) u32 {
    return c[0] + c[1] + c[2] + c[3] + c[4];
}

/// Along a line through (x, y) in direction (dx, dy): the 1:1:3:1:1 runs around the dark
/// centre, and the centre's offset along the line; null when they are not there.
fn crossCheck(b: Bits, x: i64, y: i64, dx: i64, dy: i64, max_count: u32, original: u32) ?f64 {
    var c: [5]u32 = @splat(0);
    var i: i64 = 0;
    while (b.getI(x + i * dx, y + i * dy)) : (i -= 1) c[2] += 1;
    if (c[2] == 0) return null;
    while (!b.getI(x + i * dx, y + i * dy) and c[1] <= max_count and inside(b, x + i * dx, y + i * dy)) : (i -= 1) c[1] += 1;
    if (c[1] > max_count or !inside(b, x + i * dx, y + i * dy)) return null;
    while (b.getI(x + i * dx, y + i * dy) and c[0] <= max_count) : (i -= 1) c[0] += 1;
    if (c[0] > max_count) return null;
    i = 1;
    while (b.getI(x + i * dx, y + i * dy)) : (i += 1) c[2] += 1;
    while (!b.getI(x + i * dx, y + i * dy) and c[3] <= max_count and inside(b, x + i * dx, y + i * dy)) : (i += 1) c[3] += 1;
    if (c[3] > max_count or !inside(b, x + i * dx, y + i * dy)) return null;
    while (b.getI(x + i * dx, y + i * dy) and c[4] <= max_count) : (i += 1) c[4] += 1;
    if (c[4] > max_count) return null;
    const total = crossTotal(c);
    if (5 * @abs(@as(i64, total) - @as(i64, original)) >= 2 * @as(i64, original)) return null;
    if (!crossOk(c)) return null;
    // i is one past the last dark run.
    return @as(f64, @floatFromInt(i)) - @as(f64, @floatFromInt(c[4] + c[3])) - @as(f64, @floatFromInt(c[2])) / 2;
}

fn inside(b: Bits, x: i64, y: i64) bool {
    return x >= 0 and y >= 0 and x < b.w and y < b.h;
}

fn findFinders(a: std.mem.Allocator, b: Bits) ![]Finder {
    var found: std.ArrayList(Finder) = .empty;
    const skip: usize = @max(1, b.h / 300);
    var y: usize = 0;
    while (y < b.h) : (y += skip) {
        var c: [5]u32 = @splat(0);
        var state: usize = 0;
        var x: usize = 0;
        while (x <= b.w) : (x += 1) {
            const dark = x < b.w and b.get(x, y);
            if (dark) {
                if (state & 1 == 1) state += 1;
                c[state] += 1;
                continue;
            }
            if (state & 1 == 1) {
                c[state] += 1;
                continue;
            }
            if (state < 4) {
                if (state > 0 or c[0] > 0) {
                    state += 1;
                    c[state] += 1;
                }
                continue;
            }
            // Five runs ending here.
            if (crossOk(c)) try candidate(a, b, &found, c, @intCast(x), @intCast(y));
            c = .{ c[2], c[3], c[4], 1, 0 };
            state = 3;
        }
    }
    return found.items;
}

fn candidate(a: std.mem.Allocator, b: Bits, found: *std.ArrayList(Finder), c: [5]u32, end_x: i64, y: i64) !void {
    const total = crossTotal(c);
    const cx: i64 = end_x - @as(i64, c[4] + c[3]) - @as(i64, c[2] / 2);
    const vy = crossCheck(b, cx, y, 0, 1, c[2] * 2, total) orelse return;
    const cy: i64 = y + @as(i64, @intFromFloat(@floor(vy)));
    const hx = crossCheck(b, cx, cy, 1, 0, c[2] * 2, total) orelse return;
    const fx = @as(f64, @floatFromInt(cx)) + hx;
    const fy = @as(f64, @floatFromInt(y)) + vy;
    // A diagonal check keeps text and stripes out.
    const module = @as(f64, @floatFromInt(total)) / 7;
    for (found.items) |*f| {
        if (@abs(f.x - fx) <= module and @abs(f.y - fy) <= module and @abs(f.module - module) <= @max(1, f.module / 2)) {
            const n: f64 = @floatFromInt(f.count);
            f.x = (f.x * n + fx) / (n + 1);
            f.y = (f.y * n + fy) / (n + 1);
            f.module = (f.module * n + module) / (n + 1);
            f.count += 1;
            return;
        }
    }
    try found.append(a, .{ .x = fx, .y = fy, .module = module, .count = 1 });
}

fn dist(p: anytype, q: anytype) f64 {
    return std.math.hypot(p.x - q.x, p.y - q.y);
}

const Triple = struct { tl: Finder, tr: Finder, bl: Finder };

/// Three finders that make the corners of a square: the right angle at top left.
fn arrange(f: [3]Finder) ?Triple {
    const d01 = dist(f[0], f[1]);
    const d12 = dist(f[1], f[2]);
    const d02 = dist(f[0], f[2]);
    var tl: Finder = undefined;
    var p: Finder = undefined;
    var q: Finder = undefined;
    if (d12 >= d01 and d12 >= d02) {
        tl = f[0];
        p = f[1];
        q = f[2];
    } else if (d02 >= d01 and d02 >= d12) {
        tl = f[1];
        p = f[0];
        q = f[2];
    } else {
        tl = f[2];
        p = f[0];
        q = f[1];
    }
    const s1 = dist(tl, p);
    const s2 = dist(tl, q);
    const hyp = dist(p, q);
    if (s1 < 1 or s2 < 1) return null;
    if (@max(s1, s2) / @min(s1, s2) > 1.6) return null;
    const ideal = @sqrt(s1 * s1 + s2 * s2);
    if (@abs(hyp - ideal) > 0.2 * ideal) return null;
    // bottom left = a, top right = c, clockwise in picture coordinates (y down).
    var bl = p;
    var tr = q;
    if ((tr.x - tl.x) * (bl.y - tl.y) - (tr.y - tl.y) * (bl.x - tl.x) < 0) {
        bl = q;
        tr = p;
    }
    return .{ .tl = tl, .tr = tr, .bl = bl };
}

fn findQr(a: std.mem.Allocator, b: Bits) !?[]const u8 {
    const finders = try findFinders(a, b);
    if (debug) for (finders) |f| std.debug.print("finder {d:.1} {d:.1} m={d:.2} n={d}\n", .{ f.x, f.y, f.module, f.count });
    if (finders.len < 3) return null;
    // The most often seen first; try triples among the best few.
    std.mem.sort(Finder, finders, {}, struct {
        fn gt(_: void, x: Finder, y: Finder) bool {
            return x.count > y.count;
        }
    }.gt);
    const n = @min(finders.len, 8);
    for (0..n) |i| for (i + 1..n) |j| for (j + 1..n) |k| {
        const f = [3]Finder{ finders[i], finders[j], finders[k] };
        const lo = @min(@min(f[0].module, f[1].module), f[2].module);
        const hi = @max(@max(f[0].module, f[1].module), f[2].module);
        if (hi > lo * 1.5) continue;
        const t = arrange(f) orelse continue;
        if (try readQrAt(a, b, t)) |text| return text;
    };
    return null;
}

fn readQrAt(a: std.mem.Allocator, b: Bits, t: Triple) !?[]const u8 {
    const module = (t.tl.module + t.tr.module + t.bl.module) / 3;
    const across = (dist(t.tl, t.tr) + dist(t.tl, t.bl)) / 2 / module;
    const estimate: i64 = @as(i64, @intFromFloat(@round(across))) + 7;
    // The nearest size of the form 4v + 17, then its neighbours.
    const base = @divFloor(estimate - 17 + 2, 4);
    for ([_]i64{ 0, 1, -1 }) |d| {
        const version = base + d;
        if (version < 1 or version > 40) continue;
        var dim: usize = @intCast(17 + 4 * version);
        // Large codes say their version: sample, read it, and sample again if it differs.
        var tries: usize = 0;
        while (tries < 2) : (tries += 1) {
            const grid = (try sample(a, b, t, dim, module)) orelse break;
            if (debug) std.debug.print("try dim {d} tl {d:.0},{d:.0} tr {d:.0},{d:.0} bl {d:.0},{d:.0} fmt {any}\n", .{ dim, t.tl.x, t.tl.y, t.tr.x, t.tr.y, t.bl.x, t.bl.y, readFormat(grid, dim) });
            if (dim >= 45) {
                if (readVersion(grid, dim)) |v| {
                    const real: usize = 17 + 4 * @as(usize, v);
                    if (real != dim) {
                        dim = real;
                        continue;
                    }
                }
            }
            if (try decodeGrid(a, grid, dim)) |text| return text;
            // Seen in a mirror (a selfie camera): the same grid transposed.
            const flipped = try a.alloc(bool, dim * dim);
            for (0..dim) |r| for (0..dim) |c| {
                flipped[r * dim + c] = grid[c * dim + r];
            };
            if (try decodeGrid(a, flipped, dim)) |text| return text;
            break;
        }
    }
    return null;
}

/// The dark centre of an alignment pattern near `around`: a dark module in a light ring in a
/// dark ring, about `module` wide.
fn findAlignment(b: Bits, around: Point, module: f64, radius: f64) ?Point {
    var best: ?Point = null;
    var best_d: f64 = std.math.inf(f64);
    const r: i64 = @intFromFloat(@ceil(radius));
    const cx: i64 = @intFromFloat(@round(around.x));
    const cy: i64 = @intFromFloat(@round(around.y));
    var y = cy - r;
    while (y <= cy + r) : (y += 1) {
        var x = cx - r;
        while (x <= cx + r) : (x += 1) {
            if (!b.getI(x, y)) continue;
            const hx = ringCheck(b, x, y, 1, 0, module) orelse continue;
            const vy = ringCheck(b, x, y, 0, 1, module) orelse continue;
            const p: Point = .{ .x = @as(f64, @floatFromInt(x)) + hx, .y = @as(f64, @floatFromInt(y)) + vy };
            const d = dist(p, around);
            if (d < best_d) {
                best_d = d;
                best = p;
            }
        }
    }
    return best;
}

/// dark ring, light, DARK, light, dark ring along a line, each about a module: the offset of
/// the centre of the middle run from (x, y).
fn ringCheck(b: Bits, x: i64, y: i64, dx: i64, dy: i64, module: f64) ?f64 {
    var c: [5]f64 = @splat(0);
    var i: i64 = 0;
    while (b.getI(x + i * dx, y + i * dy)) : (i -= 1) c[2] += 1;
    const lo = i;
    while (!b.getI(x + i * dx, y + i * dy) and inside(b, x + i * dx, y + i * dy) and c[1] < 3 * module) : (i -= 1) c[1] += 1;
    while (b.getI(x + i * dx, y + i * dy) and c[0] < 3 * module) : (i -= 1) c[0] += 1;
    i = 1;
    while (b.getI(x + i * dx, y + i * dy)) : (i += 1) c[2] += 1;
    const hi = i;
    while (!b.getI(x + i * dx, y + i * dy) and inside(b, x + i * dx, y + i * dy) and c[3] < 3 * module) : (i += 1) c[3] += 1;
    while (b.getI(x + i * dx, y + i * dy) and c[4] < 3 * module) : (i += 1) c[4] += 1;
    // The outer ring may run into dark modules around it: only its start is checked.
    for (c[1..4]) |v| if (@abs(v - module) > module * 0.6) return null;
    if (c[0] < module * 0.5 or c[4] < module * 0.5) return null;
    return (@as(f64, @floatFromInt(lo + 1)) + @as(f64, @floatFromInt(hi))) / 2 - 0.0;
}

/// The code's modules, read through the perspective the three finders (and the alignment
/// pattern, from version 2) give.
fn sample(a: std.mem.Allocator, b: Bits, t: Triple, dim: usize, module: f64) !?[]bool {
    const d: f64 = @floatFromInt(dim);
    var src = [4]Point{ .{ .x = 3.5, .y = 3.5 }, .{ .x = d - 3.5, .y = 3.5 }, .{ .x = 3.5, .y = d - 3.5 }, .{ .x = d - 3.5, .y = d - 3.5 } };
    const br: Point = .{ .x = t.tr.x - t.tl.x + t.bl.x, .y = t.tr.y - t.tl.y + t.bl.y };
    var dst = [4]Point{ .{ .x = t.tl.x, .y = t.tl.y }, .{ .x = t.tr.x, .y = t.tr.y }, .{ .x = t.bl.x, .y = t.bl.y }, br };
    if (dim > 21) {
        // The bottom-right alignment pattern, 3 modules in from the corner finders' line.
        const k = 1 - 3 / (d - 7);
        const est: Point = .{ .x = t.tl.x + k * (br.x - t.tl.x), .y = t.tl.y + k * (br.y - t.tl.y) };
        for ([_]f64{ 4, 8, 16 }) |reach| {
            if (findAlignment(b, est, module, reach * module)) |p| {
                if (debug) std.debug.print("align est {d:.1},{d:.1} at {d:.1},{d:.1}\n", .{ est.x, est.y, p.x, p.y });
                src[3] = .{ .x = d - 6.5, .y = d - 6.5 };
                dst[3] = p;
                break;
            }
        }
    }
    const hm = homography(src, dst) orelse return null;
    const grid = try a.alloc(bool, dim * dim);
    for (0..dim) |r| for (0..dim) |c| {
        const p = apply(hm, @as(f64, @floatFromInt(c)) + 0.5, @as(f64, @floatFromInt(r)) + 0.5);
        const x: i64 = @intFromFloat(@floor(p.x));
        const y: i64 = @intFromFloat(@floor(p.y));
        if (x < -1 or y < -1 or x > b.w or y > b.h) return null;
        grid[r * dim + c] = b.getI(x, y);
    };
    return grid;
}

/// The projective map taking `src[i]` to `dst[i]`.
fn homography(src: [4]Point, dst: [4]Point) ?[9]f64 {
    // h0 x + h1 y + h2 - h6 x X - h7 y X = X, and the same for Y; h8 = 1.
    var m: [8][9]f64 = undefined;
    for (0..4) |i| {
        const x = src[i].x;
        const y = src[i].y;
        const X = dst[i].x;
        const Y = dst[i].y;
        m[2 * i] = .{ x, y, 1, 0, 0, 0, -x * X, -y * X, X };
        m[2 * i + 1] = .{ 0, 0, 0, x, y, 1, -x * Y, -y * Y, Y };
    }
    for (0..8) |col| {
        var piv = col;
        for (col + 1..8) |r| if (@abs(m[r][col]) > @abs(m[piv][col])) {
            piv = r;
        };
        if (@abs(m[piv][col]) < 1e-12) return null;
        const tmp = m[col];
        m[col] = m[piv];
        m[piv] = tmp;
        for (0..8) |r| {
            if (r == col) continue;
            const f = m[r][col] / m[col][col];
            for (col..9) |k| m[r][k] -= f * m[col][k];
        }
    }
    var h: [9]f64 = undefined;
    for (0..8) |i| h[i] = m[i][8] / m[i][i];
    h[8] = 1;
    return h;
}

fn apply(h: [9]f64, x: f64, y: f64) Point {
    const w = h[6] * x + h[7] * y + h[8];
    return .{ .x = (h[0] * x + h[1] * y + h[2]) / w, .y = (h[3] * x + h[4] * y + h[5]) / w };
}

// ---- QR: reading the modules --------------------------------------------------------------

pub const Ecl = enum(u2) { L, M, Q, H };

/// The error correction level's two bits in the format information.
fn eclBits(e: Ecl) u32 {
    return switch (e) {
        .L => 1,
        .M => 0,
        .Q => 3,
        .H => 2,
    };
}

const ecc_per_block = [4][41]i8{
    .{ -1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
    .{ -1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28 },
    .{ -1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
    .{ -1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
};

const blocks_count = [4][41]i8{
    .{ -1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25 },
    .{ -1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49 },
    .{ -1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68 },
    .{ -1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81 },
};

/// Modules that carry data (and error correction), all versions.
fn rawModules(version: usize) usize {
    var r = (16 * version + 128) * version + 64;
    if (version >= 2) {
        const n = version / 7 + 2;
        r -= (25 * n - 10) * n - 55;
        if (version >= 7) r -= 36;
    }
    return r;
}

fn alignmentPositions(version: usize, out: *[7]usize) []usize {
    if (version == 1) return out[0..0];
    const n = version / 7 + 2;
    const size = version * 4 + 17;
    const step: usize = if (version == 32) 26 else (version * 4 + n * 2 + 1) / (n * 2 - 2) * 2;
    out[0] = 6;
    var pos = size - 7;
    var i = n - 1;
    while (i >= 1) : (i -= 1) {
        out[i] = pos;
        pos -%= step;
    }
    return out[0..n];
}

fn formatBits(ecl: Ecl, mask: u32) u32 {
    const data = eclBits(ecl) << 3 | mask;
    var rem = data;
    for (0..10) |_| rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    return (data << 10 | rem) ^ 0x5412;
}

fn versionBits(version: u32) u32 {
    var rem = version;
    for (0..12) |_| rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
    return version << 12 | rem;
}

fn maskBit(mask: u32, x: usize, y: usize) bool {
    return switch (mask) {
        0 => (x + y) % 2 == 0,
        1 => y % 2 == 0,
        2 => x % 3 == 0,
        3 => (x + y) % 3 == 0,
        4 => (x / 3 + y / 2) % 2 == 0,
        5 => x * y % 2 + x * y % 3 == 0,
        6 => (x * y % 2 + x * y % 3) % 2 == 0,
        else => ((x + y) % 2 + x * y % 3) % 2 == 0,
    };
}

/// Modules that are not data: finders, separators, timing, alignment, format and version.
fn functionModules(a: std.mem.Allocator, version: usize) ![]bool {
    const size = version * 4 + 17;
    const f = try a.alloc(bool, size * size);
    @memset(f, false);
    const mark = struct {
        fn m(g: []bool, s: usize, x0: usize, y0: usize, w: usize, h: usize) void {
            for (y0..@min(s, y0 + h)) |y| for (x0..@min(s, x0 + w)) |x| {
                g[y * s + x] = true;
            };
        }
    }.m;
    mark(f, size, 0, 0, 9, 9);
    mark(f, size, size - 8, 0, 8, 9);
    mark(f, size, 0, size - 8, 9, 8);
    mark(f, size, 6, 0, 1, size);
    mark(f, size, 0, 6, size, 1);
    var buf: [7]usize = undefined;
    const pos = alignmentPositions(version, &buf);
    for (pos, 0..) |py, i| for (pos, 0..) |px, j| {
        if ((i == 0 and j == 0) or (i == 0 and j == pos.len - 1) or (i == pos.len - 1 and j == 0)) continue;
        mark(f, size, px - 2, py - 2, 5, 5);
    };
    if (version >= 7) {
        mark(f, size, size - 11, 0, 3, 6);
        mark(f, size, 0, size - 11, 6, 3);
    }
    return f;
}

const FormatInfo = struct { ecl: Ecl, mask: u32 };

fn readFormat(grid: []const bool, size: usize) ?FormatInfo {
    const g = struct {
        fn at(gr: []const bool, s: usize, x: usize, y: usize) u32 {
            return @intFromBool(gr[y * s + x]);
        }
    }.at;
    var first: u32 = 0;
    for (0..6) |i| first |= g(grid, size, 8, i) << @intCast(i);
    first |= g(grid, size, 8, 7) << 6;
    first |= g(grid, size, 8, 8) << 7;
    first |= g(grid, size, 7, 8) << 8;
    for (9..15) |i| first |= g(grid, size, 14 - i, 8) << @intCast(i);
    var second: u32 = 0;
    for (0..8) |i| second |= g(grid, size, size - 1 - i, 8) << @intCast(i);
    for (8..15) |i| second |= g(grid, size, 8, size - 15 + i) << @intCast(i);
    var best: ?FormatInfo = null;
    var best_d: u32 = 4;
    for ([_]Ecl{ .L, .M, .Q, .H }) |e| for (0..8) |m| {
        const want = formatBits(e, @intCast(m));
        const d = @min(@popCount(want ^ first), @popCount(want ^ second));
        if (d < best_d) {
            best_d = d;
            best = .{ .ecl = e, .mask = @intCast(m) };
        }
    };
    return best;
}

fn readVersion(grid: []const bool, size: usize) ?u32 {
    var one: u32 = 0;
    var two: u32 = 0;
    for (0..18) |i| {
        const p = size - 11 + i % 3;
        const q = i / 3;
        one |= @as(u32, @intFromBool(grid[q * size + p])) << @intCast(i);
        two |= @as(u32, @intFromBool(grid[p * size + q])) << @intCast(i);
    }
    var v: u32 = 7;
    while (v <= 40) : (v += 1) {
        const want = versionBits(v);
        if (@popCount(want ^ one) <= 3 or @popCount(want ^ two) <= 3) return v;
    }
    return null;
}

fn decodeGrid(a: std.mem.Allocator, grid: []const bool, size: usize) !?[]const u8 {
    if (size < 21 or (size - 17) % 4 != 0) return null;
    const version = (size - 17) / 4;
    const fmt = readFormat(grid, size) orelse return null;
    const func = try functionModules(a, version);
    const raw = rawModules(version) / 8;
    const codewords = try a.alloc(u8, raw);
    @memset(codewords, 0);
    var bit: usize = 0;
    var right: usize = size - 1;
    while (right >= 1) {
        if (right == 6) right = 5;
        for (0..size) |vert| for (0..2) |j| {
            const x = right - j;
            const upward = ((right + 1) & 2) == 0;
            const y = if (upward) size - 1 - vert else vert;
            if (func[y * size + x] or bit >= raw * 8) continue;
            const dark = grid[y * size + x] != maskBit(fmt.mask, x, y);
            if (dark) codewords[bit / 8] |= @as(u8, 0x80) >> @intCast(bit % 8);
            bit += 1;
        };
        if (right < 2) break;
        right -= 2;
    }
    const data = (try correct(a, codewords, version, fmt.ecl)) orelse return null;
    return parseSegments(a, data, version);
}

/// The data codewords, the blocks taken apart and each corrected; null when too damaged.
fn correct(a: std.mem.Allocator, codewords: []const u8, version: usize, ecl: Ecl) !?[]u8 {
    const e = @intFromEnum(ecl);
    const nblocks: usize = @intCast(blocks_count[e][version]);
    const ecc: usize = @intCast(ecc_per_block[e][version]);
    const raw = codewords.len;
    const short_count = nblocks - raw % nblocks;
    const short_len = raw / nblocks;
    // Each block as long as a long block; short ones have a hole where their last data byte
    // would be.
    const blocks = try a.alloc(u8, nblocks * (short_len + 1));
    var k: usize = 0;
    for (0..short_len + 1) |i| for (0..nblocks) |j| {
        if (i == short_len - ecc and j < short_count) continue;
        blocks[j * (short_len + 1) + i] = codewords[k];
        k += 1;
    };
    var out: std.ArrayList(u8) = .empty;
    for (0..nblocks) |j| {
        const full = blocks[j * (short_len + 1) ..][0 .. short_len + 1];
        var block: std.ArrayList(u8) = .empty;
        if (j < short_count) {
            try block.appendSlice(a, full[0 .. short_len - ecc]);
            try block.appendSlice(a, full[short_len - ecc + 1 ..]);
        } else {
            try block.appendSlice(a, full);
        }
        if (!(try rsCorrect(a, block.items, ecc))) return null;
        try out.appendSlice(a, block.items[0 .. block.items.len - ecc]);
    }
    return out.items;
}

// ---- Reed-Solomon over GF(256), x^8 + x^4 + x^3 + x^2 + 1 ---------------------------------

const gf = struct {
    const tables = blk: {
        var exp: [512]u8 = undefined;
        var log: [256]u8 = @splat(0);
        var x: u32 = 1;
        for (0..255) |i| {
            exp[i] = @intCast(x);
            log[x] = @intCast(i);
            x <<= 1;
            if (x & 0x100 != 0) x ^= 0x11D;
        }
        for (255..512) |i| exp[i] = exp[i - 255];
        break :blk .{ .exp = exp, .log = log };
    };

    fn mul(x: u8, y: u8) u8 {
        if (x == 0 or y == 0) return 0;
        return tables.exp[@as(usize, tables.log[x]) + tables.log[y]];
    }

    fn div(x: u8, y: u8) u8 {
        if (x == 0) return 0;
        return tables.exp[(@as(usize, tables.log[x]) + 255 - tables.log[y]) % 255];
    }

    fn pow2(e: usize) u8 {
        return tables.exp[e % 255];
    }

    fn inv(x: u8) u8 {
        return tables.exp[255 - @as(usize, tables.log[x])];
    }
};

/// Corrects `block` (data then `ecc` check bytes) in place; false when it cannot.
fn rsCorrect(a: std.mem.Allocator, block: []u8, ecc: usize) !bool {
    const n = block.len;
    const syn = try a.alloc(u8, ecc);
    var clean = true;
    for (0..ecc) |j| {
        var s: u8 = 0;
        for (block) |c| s = gf.mul(s, gf.pow2(j)) ^ c;
        syn[j] = s;
        if (s != 0) clean = false;
    }
    if (clean) return true;
    // Berlekamp-Massey: the error locator.
    var C = try a.alloc(u8, ecc + 1);
    var B = try a.alloc(u8, ecc + 1);
    const T = try a.alloc(u8, ecc + 1);
    @memset(C, 0);
    @memset(B, 0);
    C[0] = 1;
    B[0] = 1;
    var L: usize = 0;
    var m: usize = 1;
    var bb: u8 = 1;
    for (0..ecc) |i| {
        var d = syn[i];
        for (1..L + 1) |j| d ^= gf.mul(C[j], syn[i - j]);
        if (d == 0) {
            m += 1;
            continue;
        }
        const coef = gf.div(d, bb);
        @memcpy(T, C);
        for (0..ecc + 1 - m) |j| C[j + m] ^= gf.mul(coef, B[j]);
        if (2 * L <= i) {
            L = i + 1 - L;
            @memcpy(B, T);
            bb = d;
            m = 1;
        } else m += 1;
    }
    if (L == 0 or 2 * L > ecc) return false;
    // Chien search: position p (power n-1-k) is wrong when C(alpha^-p) = 0.
    var positions: std.ArrayList(usize) = .empty;
    for (0..n) |p| {
        const xinv = gf.inv(gf.pow2(p));
        var v: u8 = 0;
        var xp: u8 = 1;
        for (0..L + 1) |j| {
            v ^= gf.mul(C[j], xp);
            xp = gf.mul(xp, xinv);
        }
        if (v == 0) try positions.append(a, p);
    }
    if (positions.items.len != L) return false;
    // Forney: Omega = S * C mod x^ecc; e = X * Omega(X^-1) / C'(X^-1).
    const omega = try a.alloc(u8, ecc);
    @memset(omega, 0);
    for (0..ecc) |i| for (0..L + 1) |j| {
        if (i + j < ecc) omega[i + j] ^= gf.mul(syn[i], C[j]);
    };
    for (positions.items) |p| {
        const X = gf.pow2(p);
        const xinv = gf.inv(X);
        var num: u8 = 0;
        var xp: u8 = 1;
        for (omega) |o| {
            num ^= gf.mul(o, xp);
            xp = gf.mul(xp, xinv);
        }
        var den: u8 = 0;
        xp = 1;
        var j: usize = 1;
        while (j <= L) : (j += 2) {
            den ^= gf.mul(C[j], xp);
            xp = gf.mul(xp, gf.mul(xinv, xinv));
        }
        if (den == 0) return false;
        block[n - 1 - p] ^= gf.mul(X, gf.div(num, den));
    }
    for (0..ecc) |j| {
        var s: u8 = 0;
        for (block) |c| s = gf.mul(s, gf.pow2(j)) ^ c;
        if (s != 0) return false;
    }
    return true;
}

// ---- QR: the data -------------------------------------------------------------------------

const BitReader = struct {
    data: []const u8,
    pos: usize = 0,

    fn left(r: BitReader) usize {
        return r.data.len * 8 - r.pos;
    }

    fn read(r: *BitReader, n: usize) ?u32 {
        if (n > r.left()) return null;
        var v: u32 = 0;
        for (0..n) |_| {
            v = v << 1 | ((r.data[r.pos / 8] >> @intCast(7 - r.pos % 8)) & 1);
            r.pos += 1;
        }
        return v;
    }
};

const alnum_chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:";

fn countBits(mode: u32, version: usize) usize {
    const g: usize = if (version <= 9) 0 else if (version <= 26) 1 else 2;
    return switch (mode) {
        1 => ([_]usize{ 10, 12, 14 })[g],
        2 => ([_]usize{ 9, 11, 13 })[g],
        4 => ([_]usize{ 8, 16, 16 })[g],
        else => ([_]usize{ 8, 10, 12 })[g],
    };
}

fn parseSegments(a: std.mem.Allocator, data: []const u8, version: usize) !?[]const u8 {
    var r: BitReader = .{ .data = data };
    var out: std.ArrayList(u8) = .empty;
    while (r.left() >= 4) {
        const mode = r.read(4).?;
        switch (mode) {
            0 => break,
            1 => {
                var count = r.read(countBits(1, version)) orelse return null;
                while (count >= 3) : (count -= 3) {
                    const v = r.read(10) orelse return null;
                    if (v > 999) return null;
                    try out.print(a, "{d:0>3}", .{v});
                }
                if (count == 2) {
                    const v = r.read(7) orelse return null;
                    if (v > 99) return null;
                    try out.print(a, "{d:0>2}", .{v});
                } else if (count == 1) {
                    const v = r.read(4) orelse return null;
                    if (v > 9) return null;
                    try out.print(a, "{d}", .{v});
                }
            },
            2 => {
                var count = r.read(countBits(2, version)) orelse return null;
                while (count >= 2) : (count -= 2) {
                    const v = r.read(11) orelse return null;
                    if (v >= 45 * 45) return null;
                    try out.append(a, alnum_chars[v / 45]);
                    try out.append(a, alnum_chars[v % 45]);
                }
                if (count == 1) {
                    const v = r.read(6) orelse return null;
                    if (v >= 45) return null;
                    try out.append(a, alnum_chars[v]);
                }
            },
            4 => {
                const count = r.read(countBits(4, version)) orelse return null;
                for (0..count) |_| try out.append(a, @intCast(r.read(8) orelse return null));
            },
            8 => {
                const count = r.read(countBits(8, version)) orelse return null;
                for (0..count) |_| {
                    const v = r.read(13) orelse return null;
                    var c = (v / 0xC0) << 8 | (v % 0xC0);
                    c += if (c < 0x1F00) 0x8140 else 0xC140;
                    try out.append(a, @intCast(c >> 8));
                    try out.append(a, @intCast(c & 0xff));
                }
            },
            7 => {
                // ECI: an 8, 16 or 24 bit designator, read past.
                const first = r.read(8) orelse return null;
                if (first & 0x80 == 0) {} else if (first & 0xC0 == 0x80) {
                    _ = r.read(8) orelse return null;
                } else {
                    _ = r.read(16) orelse return null;
                }
            },
            3 => _ = r.read(16) orelse return null, // structured append
            5 => {}, // FNC1 first position
            9 => _ = r.read(8) orelse return null, // FNC1 second position
            else => return null,
        }
    }
    return out.items;
}

// ---- Drawing codes, for tests -------------------------------------------------------------

/// A QR code of `text` as byte data (or numeric / alphanumeric when it fits them): its modules,
/// `size` a side, row by row. The smallest version from `min_version` that holds it.
pub fn encodeQr(a: std.mem.Allocator, text: []const u8, ecl: Ecl, min_version: usize, mask: u32) !struct { modules: []bool, size: usize } {
    const numeric = for (text) |c| {
        if (c < '0' or c > '9') break false;
    } else true;
    const alnum = for (text) |c| {
        if (std.mem.indexOfScalar(u8, alnum_chars, c) == null) break false;
    } else true;
    const mode: u32 = if (numeric) 1 else if (alnum) 2 else 4;
    var version = min_version;
    while (version <= 40) : (version += 1) {
        const e = @intFromEnum(ecl);
        const raw = rawModules(version) / 8;
        const cap = raw - @as(usize, @intCast(ecc_per_block[e][version])) * @as(usize, @intCast(blocks_count[e][version]));
        var bits: std.ArrayList(u1) = .empty;
        const put = struct {
            fn p(al: std.mem.Allocator, l: *std.ArrayList(u1), v: u32, n: usize) !void {
                var i = n;
                while (i > 0) {
                    i -= 1;
                    try l.append(al, @intCast((v >> @intCast(i)) & 1));
                }
            }
        }.p;
        try put(a, &bits, mode, 4);
        try put(a, &bits, @intCast(text.len), countBits(mode, version));
        switch (mode) {
            1 => {
                var i: usize = 0;
                while (i < text.len) {
                    const n: usize = @min(3, text.len - i);
                    const v = try std.fmt.parseInt(u32, text[i .. i + n], 10);
                    try put(a, &bits, v, n * 3 + 1);
                    i += n;
                }
            },
            2 => {
                var i: usize = 0;
                while (i < text.len) {
                    const c0: u32 = @intCast(std.mem.indexOfScalar(u8, alnum_chars, text[i]).?);
                    if (i + 1 < text.len) {
                        const c1: u32 = @intCast(std.mem.indexOfScalar(u8, alnum_chars, text[i + 1]).?);
                        try put(a, &bits, c0 * 45 + c1, 11);
                        i += 2;
                    } else {
                        try put(a, &bits, c0, 6);
                        i += 1;
                    }
                }
            },
            else => for (text) |c| try put(a, &bits, c, 8),
        }
        if (bits.items.len > cap * 8) continue;
        try put(a, &bits, 0, @min(4, cap * 8 - bits.items.len));
        while (bits.items.len % 8 != 0) try bits.append(a, 0);
        var data: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < bits.items.len) : (i += 8) {
            var byte: u8 = 0;
            for (0..8) |j| byte = byte << 1 | bits.items[i + j];
            try data.append(a, byte);
        }
        var pad: u8 = 0xEC;
        while (data.items.len < cap) {
            try data.append(a, pad);
            pad ^= 0xEC ^ 0x11;
        }
        return .{ .modules = try drawQr(a, data.items, version, ecl, mask), .size = version * 4 + 17 };
    }
    return error.TooLong;
}

fn rsDivisor(a: std.mem.Allocator, degree: usize) ![]u8 {
    const r = try a.alloc(u8, degree);
    @memset(r, 0);
    r[degree - 1] = 1;
    var root: u8 = 1;
    for (0..degree) |_| {
        for (0..degree) |j| {
            r[j] = gf.mul(r[j], root);
            if (j + 1 < degree) r[j] ^= r[j + 1];
        }
        root = gf.mul(root, 2);
    }
    return r;
}

fn rsRemainder(a: std.mem.Allocator, data: []const u8, divisor: []const u8) ![]u8 {
    const r = try a.alloc(u8, divisor.len);
    @memset(r, 0);
    for (data) |b| {
        const factor = b ^ r[0];
        std.mem.copyForwards(u8, r[0 .. r.len - 1], r[1..]);
        r[r.len - 1] = 0;
        for (r, divisor) |*x, d| x.* ^= gf.mul(d, factor);
    }
    return r;
}

fn drawQr(a: std.mem.Allocator, data: []const u8, version: usize, ecl: Ecl, mask: u32) ![]bool {
    const size = version * 4 + 17;
    const e = @intFromEnum(ecl);
    const nblocks: usize = @intCast(blocks_count[e][version]);
    const ecc: usize = @intCast(ecc_per_block[e][version]);
    const raw = rawModules(version) / 8;
    const short_count = nblocks - raw % nblocks;
    const short_len = raw / nblocks;
    const divisor = try rsDivisor(a, ecc);
    // Blocks with their check bytes, short ones padded at the data's end; then interleaved.
    const blocks = try a.alloc([]u8, nblocks);
    var k: usize = 0;
    for (0..nblocks) |i| {
        const dlen = short_len - ecc + @intFromBool(i >= short_count);
        const d = data[k .. k + dlen];
        k += dlen;
        const rem = try rsRemainder(a, d, divisor);
        var b: std.ArrayList(u8) = .empty;
        try b.appendSlice(a, d);
        if (i < short_count) try b.append(a, 0);
        try b.appendSlice(a, rem);
        blocks[i] = b.items;
    }
    var all: std.ArrayList(u8) = .empty;
    for (0..short_len + 1) |i| for (0..nblocks) |j| {
        if (i != short_len - ecc or j >= short_count) try all.append(a, blocks[j][i]);
    };

    const g = try a.alloc(bool, size * size);
    @memset(g, false);
    const set = struct {
        fn s(gr: []bool, sz: usize, x: i64, y: i64, v: bool) void {
            if (x < 0 or y < 0 or x >= sz or y >= sz) return;
            gr[@as(usize, @intCast(y)) * sz + @as(usize, @intCast(x))] = v;
        }
    }.s;
    const isz: i64 = @intCast(size);
    for (0..size) |i| {
        set(g, size, 6, @intCast(i), i % 2 == 0);
        set(g, size, @intCast(i), 6, i % 2 == 0);
    }
    for ([_][2]i64{ .{ 3, 3 }, .{ isz - 4, 3 }, .{ 3, isz - 4 } }) |c| {
        var dy: i64 = -4;
        while (dy <= 4) : (dy += 1) {
            var dx: i64 = -4;
            while (dx <= 4) : (dx += 1) {
                const d = @max(@abs(dx), @abs(dy));
                set(g, size, c[0] + dx, c[1] + dy, d != 2 and d != 4);
            }
        }
    }
    var buf: [7]usize = undefined;
    const pos = alignmentPositions(version, &buf);
    for (pos, 0..) |py, i| for (pos, 0..) |px, j| {
        if ((i == 0 and j == 0) or (i == 0 and j == pos.len - 1) or (i == pos.len - 1 and j == 0)) continue;
        var dy: i64 = -2;
        while (dy <= 2) : (dy += 1) {
            var dx: i64 = -2;
            while (dx <= 2) : (dx += 1) set(g, size, @as(i64, @intCast(px)) + dx, @as(i64, @intCast(py)) + dy, @max(@abs(dx), @abs(dy)) != 1);
        }
    };
    const func = try functionModules(a, version);
    var bit: usize = 0;
    var right: usize = size - 1;
    while (right >= 1) {
        if (right == 6) right = 5;
        for (0..size) |vert| for (0..2) |j| {
            const x = right - j;
            const upward = ((right + 1) & 2) == 0;
            const y = if (upward) size - 1 - vert else vert;
            if (func[y * size + x]) continue;
            var dark = false;
            if (bit < all.items.len * 8) dark = (all.items[bit / 8] >> @intCast(7 - bit % 8)) & 1 == 1;
            bit += 1;
            g[y * size + x] = dark != maskBit(mask, x, y);
        };
        if (right < 2) break;
        right -= 2;
    }
    const fb = formatBits(ecl, mask);
    const fbit = struct {
        fn b(v: u32, i: usize) bool {
            return (v >> @intCast(i)) & 1 == 1;
        }
    }.b;
    for (0..6) |i| set(g, size, 8, @intCast(i), fbit(fb, i));
    set(g, size, 8, 7, fbit(fb, 6));
    set(g, size, 8, 8, fbit(fb, 7));
    set(g, size, 7, 8, fbit(fb, 8));
    for (9..15) |i| set(g, size, @intCast(14 - i), 8, fbit(fb, i));
    for (0..8) |i| set(g, size, @intCast(size - 1 - i), 8, fbit(fb, i));
    for (8..15) |i| set(g, size, 8, @intCast(size - 15 + i), fbit(fb, i));
    set(g, size, 8, isz - 8, true);
    if (version >= 7) {
        const vb = versionBits(@intCast(version));
        for (0..18) |i| {
            const p: i64 = @intCast(size - 11 + i % 3);
            const q: i64 = @intCast(i / 3);
            set(g, size, p, q, fbit(vb, i));
            set(g, size, q, p, fbit(vb, i));
        }
    }
    return g;
}

/// Code 128 symbols for `text`: code set C for runs of digits, B for the rest; with the
/// start, the check symbol and the stop.
pub fn encodeCode128(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var v: std.ArrayList(u8) = .empty;
    const all_digits = text.len >= 2 and text.len % 2 == 0 and for (text) |c| {
        if (c < '0' or c > '9') break false;
    } else true;
    if (all_digits) {
        try v.append(a, start_c);
        var i: usize = 0;
        while (i < text.len) : (i += 2) try v.append(a, (text[i] - '0') * 10 + text[i + 1] - '0');
    } else {
        try v.append(a, start_b);
        for (text) |c| try v.append(a, c - 32);
    }
    var sum: u32 = v.items[0];
    for (v.items[1..], 1..) |x, k| sum += @as(u32, x) * @as(u32, @intCast(k));
    try v.append(a, @intCast(sum % 103));
    try v.append(a, stop_symbol);
    return v.items;
}

// ---- Tests --------------------------------------------------------------------------------

const testing = std.testing;

/// A grayscale picture of `modules` (size x size) at `scale` pixels a module with a quiet zone,
/// turned by `angle` degrees and slightly in perspective, on a light background with a gradient
/// of light across it.
fn renderQr(a: std.mem.Allocator, modules: []const bool, size: usize, scale: f64, angle: f64, tilt: f64, w: usize, h: usize) !Image {
    const px = try a.alloc(u8, w * h);
    const ang = std.math.degreesToRadians(angle);
    const half = @as(f64, @floatFromInt(size)) * scale / 2;
    for (0..h) |y| for (0..w) |x| {
        // Into the code's frame: centre, unturn, untilt.
        const fx = @as(f64, @floatFromInt(x)) - @as(f64, @floatFromInt(w)) / 2;
        const fy = @as(f64, @floatFromInt(y)) - @as(f64, @floatFromInt(h)) / 2;
        var u = fx * @cos(ang) + fy * @sin(ang);
        var v = -fx * @sin(ang) + fy * @cos(ang);
        const k = 1 + tilt * v / half;
        u *= k;
        v *= k;
        const mx = (u + half) / scale;
        const my = (v + half) / scale;
        var dark = false;
        if (mx >= 0 and my >= 0 and mx < @as(f64, @floatFromInt(size)) and my < @as(f64, @floatFromInt(size))) {
            dark = modules[@as(usize, @intFromFloat(my)) * size + @as(usize, @intFromFloat(mx))];
        }
        // Light from 150 to 240 across the picture; dark at 40 to 90.
        const light: f64 = 150 + 90 * @as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(w));
        const noise: f64 = @floatFromInt((x * 7919 + y * 104729) % 17);
        px[y * w + x] = @intFromFloat(if (dark) 40 + light / 5 + noise else light - noise);
    };
    return .{ .width = w, .height = h, .pixels = px };
}

fn renderCode128(a: std.mem.Allocator, values: []const u8, unit: usize, w: usize, h: usize, reversed: bool) ![]u8 {
    const px = try a.alloc(u8, w * h);
    @memset(px, 220);
    var x: usize = 30;
    var widths: std.ArrayList(u8) = .empty;
    for (values) |v| for (code128_patterns[v]) |c| try widths.append(a, c - '0');
    if (reversed) std.mem.reverse(u8, widths.items);
    for (widths.items, 0..) |wd, i| {
        const len = wd * unit;
        if (i % 2 == 0) for (h / 4..h * 3 / 4) |y| for (x..x + len) |xx| {
            px[y * w + xx] = 30;
        };
        x += len;
    }
    return px;
}

test "the Code 128 table: 11 modules a symbol, an even number of bar modules" {
    for (code128_patterns[0..106]) |p| {
        var sum: u32 = 0;
        var bars: u32 = 0;
        for (p, 0..) |c, i| {
            sum += c - '0';
            if (i % 2 == 0) bars += c - '0';
        }
        try testing.expectEqual(@as(u32, 11), sum);
        try testing.expect(bars % 2 == 0);
    }
}

test "Code 128: sets B and C, upside down, wrong checksums refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "TRF-2026-00417", "1234567890", "a b/c+D" }) |text| {
        for ([_]bool{ false, true }) |rev| {
            const values = try encodeCode128(a, text);
            const px = try renderCode128(a, values, 2, 600, 120, rev);
            const r = (try decode(testing.allocator, .{ .width = 600, .height = 120, .pixels = px }, .{ .qr = false })).?;
            defer testing.allocator.free(r.text);
            try testing.expectEqual(Format.code_128, r.format);
            try testing.expectEqualStrings(text, r.text);
        }
    }
    const values = try encodeCode128(a, "ABC");
    values[values.len - 2] +%= 1;
    const px = try renderCode128(a, values, 2, 400, 80, false);
    try testing.expect((try decode(testing.allocator, .{ .width = 400, .height = 80, .pixels = px }, .{})) == null);
}

test "Code 128: set A, shifts and FNC1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Start A, "A", Shift, "b" (from B), Code C, "12", FNC1, "34".
    try testing.expectEqualStrings("Ab12\x1d34", (try code128Text(a, &.{ start_a, 33, 98, 66, 99, 12, 102, 34 })).?);
}

test "Reed-Solomon corrects up to half the check bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = "Reed-Solomon over GF(256)";
    const div = try rsDivisor(a, 10);
    const rem = try rsRemainder(a, data, div);
    var block = try std.mem.concat(a, u8, &.{ data, rem });
    try testing.expect(try rsCorrect(a, block, 10));
    for ([_]usize{ 0, 7, 20, 30, 34 }) |i| block[i] ^= 0x5A;
    try testing.expect(try rsCorrect(a, block, 10));
    try testing.expectEqualStrings(data, block[0..data.len]);
    for ([_]usize{ 1, 3, 5, 9, 11, 13 }) |i| block[i] ^= 0x33;
    try testing.expect(!(try rsCorrect(a, block, 10)));
}

test "QR grids: every level, every mask, numeric, alphanumeric and byte data, versions 1 to 40" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const texts = [_][]const u8{ "https://turf.wufour.com/t/TRF-2026-00417", "0123456789012345", "HELLO WORLD 42 $%*+-./:", "مرحبا بالعالم" };
    for ([_]Ecl{ .L, .M, .Q, .H }) |ecl| for (0..8) |mask| for (texts) |text| {
        const q = try encodeQr(a, text, ecl, 1, @intCast(mask));
        try testing.expectEqualStrings(text, (try decodeGrid(a, q.modules, q.size)).?);
    };
    var v: usize = 1;
    while (v <= 40) : (v += 1) {
        const q = try encodeQr(a, "v check", .M, v, @intCast(v % 8));
        try testing.expectEqual(v * 4 + 17, q.size);
        try testing.expectEqualStrings("v check", (try decodeGrid(a, q.modules, q.size)).?);
        try testing.expectEqual(if (v >= 7) @as(?u32, @intCast(v)) else null, if (v >= 7) readVersion(q.modules, q.size) else null);
    }
    // Damaged modules are corrected.
    const q = try encodeQr(a, "damaged but readable", .H, 3, 2);
    for ([_]usize{ 200, 300, 310, 400, 500, 600 }) |i| q.modules[i] = !q.modules[i];
    try testing.expectEqualStrings("damaged but readable", (try decodeGrid(a, q.modules, q.size)).?);
}

test "QR in a picture: found, turned, tilted, mirrored, large versions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { text: []const u8, version: usize, scale: f64, angle: f64, tilt: f64, mirror: bool = false };
    for ([_]Case{
        .{ .text = "TRF-2026-00417", .version = 1, .scale = 6, .angle = 0, .tilt = 0 },
        .{ .text = "https://turf.wufour.com/t/TRF-2026-00417", .version = 3, .scale = 5, .angle = 17, .tilt = 0 },
        .{ .text = "turned upside down", .version = 2, .scale = 5, .angle = 180, .tilt = 0.08 },
        .{ .text = "tilted", .version = 4, .scale = 4.5, .angle = -30, .tilt = 0.12 },
        .{ .text = "seen in a mirror", .version = 2, .scale = 5, .angle = 8, .tilt = 0, .mirror = true },
        .{ .text = "a bigger code with its version written in it", .version = 10, .scale = 4, .angle = 5, .tilt = 0.05 },
    }) |c| {
        const q = try encodeQr(a, c.text, .M, c.version, 3);
        if (c.mirror) {
            const m = try a.dupe(bool, q.modules);
            for (0..q.size) |r| for (0..q.size) |col| {
                m[r * q.size + col] = q.modules[col * q.size + r];
            };
            @memcpy(q.modules, m);
        }
        const img = try renderQr(a, q.modules, q.size, c.scale, c.angle, c.tilt, 640, 480);
        const r = (try decode(testing.allocator, img, .{})) orelse {
            std.debug.print("not found: {s}\n", .{c.text});
            return error.NotFound;
        };
        defer testing.allocator.free(r.text);
        try testing.expectEqual(Format.qr, r.format);
        try testing.expectEqualStrings(c.text, r.text);
    }
    // Nothing in a plain picture.
    const blank = try a.alloc(u8, 320 * 240);
    for (blank, 0..) |*p, i| p.* = @intCast(100 + i % 97);
    try testing.expect((try decode(testing.allocator, .{ .width = 320, .height = 240, .pixels = blank }, .{})) == null);
}
