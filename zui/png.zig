//! PNG pictures in Zig, the same on every platform: read the 8- and 16-bit pictures a gallery,
//! a canvas or a phone gives (grey, RGB, palette, with or without alpha; not interlaced), scale
//! one, place it in a square of a colour (an app icon), and write it as PNG.
//!
//!   const logo = try png.decode(a, file.data);          // fx.pickPhoto(.{ .format = .png })
//!   const icon = try png.square(a, logo, 192, 0xffffffff, 0.08);
//!   const bytes = try png.encode(a, icon);

const std = @import("std");
const flate = std.compress.flate;

pub const Image = struct {
    width: u32,
    height: u32,
    /// Straight (not premultiplied) RGBA, row after row.
    rgba: []u8,

    pub fn deinit(img: Image, a: std.mem.Allocator) void {
        a.free(img.rgba);
    }
};

pub const Error = error{ NotPng, Unsupported, Corrupt, OutOfMemory };

const signature = "\x89PNG\r\n\x1a\n";

/// Reads a PNG picture into RGBA.
pub fn decode(a: std.mem.Allocator, bytes: []const u8) Error!Image {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], signature)) return error.NotPng;
    var w: u32 = 0;
    var h: u32 = 0;
    var depth: u8 = 0;
    var color: u8 = 0;
    var palette: [256][4]u8 = @splat(.{ 0, 0, 0, 255 });
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(a);
    var at: usize = 8;
    while (at + 8 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[at..][0..4], .big);
        const kind = bytes[at + 4 ..][0..4];
        if (at + 12 + @as(usize, len) > bytes.len) return error.Corrupt;
        const data = bytes[at + 8 ..][0..len];
        at += 12 + @as(usize, len);
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len < 13) return error.Corrupt;
            w = std.mem.readInt(u32, data[0..4], .big);
            h = std.mem.readInt(u32, data[4..8], .big);
            depth = data[8];
            color = data[9];
            if (data[12] != 0) return error.Unsupported; // interlaced
            if (w == 0 or h == 0 or w > 8192 or h > 8192) return error.Unsupported;
            const ok = switch (color) {
                0 => depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16,
                3 => depth == 1 or depth == 2 or depth == 4 or depth == 8,
                2, 4, 6 => depth == 8 or depth == 16,
                else => false,
            };
            if (!ok) return error.Unsupported;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            var k: usize = 0;
            while (k < 256 and k * 3 + 2 < len) : (k += 1) palette[k] = .{ data[k * 3], data[k * 3 + 1], data[k * 3 + 2], 255 };
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            if (color == 3) for (data, 0..) |alpha, k| {
                if (k < 256) palette[k][3] = alpha;
            };
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(a, data);
        } else if (std.mem.eql(u8, kind, "IEND")) break;
    }
    if (w == 0) return error.Corrupt;

    const channels: u32 = switch (color) {
        0, 3 => 1,
        4 => 2,
        2 => 3,
        else => 4,
    };
    const bits_per_pixel = channels * depth;
    const stride: usize = (@as(usize, w) * bits_per_pixel + 7) / 8;
    const bpp: usize = @max(1, bits_per_pixel / 8);
    const raw = try a.alloc(u8, (stride + 1) * h);
    defer a.free(raw);
    {
        const window = try a.alloc(u8, flate.max_window_len);
        defer a.free(window);
        var in: std.Io.Reader = .fixed(idat.items);
        var z: flate.Decompress = .init(&in, .zlib, window);
        z.reader.readSliceAll(raw) catch return error.Corrupt;
    }

    // Undo the filters, row by row, into `raw` itself (each row after its filter byte).
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const row = raw[y * (stride + 1) + 1 ..][0..stride];
        const prev: ?[]const u8 = if (y > 0) raw[(y - 1) * (stride + 1) + 1 ..][0..stride] else null;
        const filter = raw[y * (stride + 1)];
        for (row, 0..) |*px, i| {
            const left: u8 = if (i >= bpp) row[i - bpp] else 0;
            const up: u8 = if (prev) |p| p[i] else 0;
            const up_left: u8 = if (prev != null and i >= bpp) prev.?[i - bpp] else 0;
            px.* +%= switch (filter) {
                0 => 0,
                1 => left,
                2 => up,
                3 => @intCast((@as(u16, left) + up) / 2),
                4 => paeth(left, up, up_left),
                else => return error.Corrupt,
            };
        }
    }

    const out = try a.alloc(u8, @as(usize, w) * h * 4);
    errdefer a.free(out);
    y = 0;
    while (y < h) : (y += 1) {
        const row = raw[y * (stride + 1) + 1 ..][0..stride];
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const o = out[(y * w + x) * 4 ..][0..4];
            switch (color) {
                0 => {
                    const g = sample(row, x, depth);
                    o.* = .{ g, g, g, 255 };
                },
                3 => o.* = palette[indexAt(row, x, depth)],
                4 => {
                    const g = sample(row, x * 2, depth);
                    o.* = .{ g, g, g, sample(row, x * 2 + 1, depth) };
                },
                2 => o.* = .{ sample(row, x * 3, depth), sample(row, x * 3 + 1, depth), sample(row, x * 3 + 2, depth), 255 },
                else => o.* = .{ sample(row, x * 4, depth), sample(row, x * 4 + 1, depth), sample(row, x * 4 + 2, depth), sample(row, x * 4 + 3, depth) },
            }
        }
    }
    return .{ .width = w, .height = h, .rgba = out };
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// The `k`th sample of a row as 8 bits (16-bit samples keep their high byte; 1, 2 and 4-bit
/// grey is spread over 0..255).
fn sample(row: []const u8, k: usize, depth: u8) u8 {
    return switch (depth) {
        16 => row[k * 2],
        8 => row[k],
        else => @intCast(@as(u16, indexAt(row, k, depth)) * 255 / ((@as(u16, 1) << @intCast(depth)) - 1)),
    };
}

/// The `k`th value of a row of 1, 2, 4 or 8-bit values.
fn indexAt(row: []const u8, k: usize, depth: u8) u8 {
    if (depth == 8) return row[k];
    const per_byte = 8 / depth;
    const byte = row[k / per_byte];
    const shift: u3 = @intCast(8 - depth * (k % per_byte + 1));
    return (byte >> shift) & @as(u8, @intCast((@as(u16, 1) << @intCast(depth)) - 1));
}

/// Writes RGBA as a PNG (8-bit, each row with the filter that suits it best).
pub fn encode(a: std.mem.Allocator, img: Image) Error![]u8 {
    const stride: usize = @as(usize, img.width) * 4;
    const raw = try a.alloc(u8, (stride + 1) * img.height);
    defer a.free(raw);
    const trial = try a.alloc(u8, stride);
    defer a.free(trial);
    var y: usize = 0;
    while (y < img.height) : (y += 1) {
        const row = img.rgba[y * stride ..][0..stride];
        const prev: ?[]const u8 = if (y > 0) img.rgba[(y - 1) * stride ..][0..stride] else null;
        const out = raw[y * (stride + 1) ..][0 .. stride + 1];
        // The filter whose bytes are smallest as signed numbers (the usual heuristic).
        var best: u8 = 0;
        var best_sum: u64 = std.math.maxInt(u64);
        for (0..5) |f| {
            var sum: u64 = 0;
            for (row, 0..) |v, i| {
                const left: u8 = if (i >= 4) row[i - 4] else 0;
                const up: u8 = if (prev) |p| p[i] else 0;
                const up_left: u8 = if (prev != null and i >= 4) prev.?[i - 4] else 0;
                const pred: u8 = switch (f) {
                    0 => 0,
                    1 => left,
                    2 => up,
                    3 => @intCast((@as(u16, left) + up) / 2),
                    else => paeth(left, up, up_left),
                };
                trial[i] = v -% pred;
                sum += @abs(@as(i8, @bitCast(trial[i])));
            }
            if (sum < best_sum) {
                best_sum = sum;
                best = @intCast(f);
                @memcpy(out[1..], trial);
            }
        }
        out[0] = best;
    }

    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll(signature) catch return error.OutOfMemory;
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], img.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], img.height, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    try chunk(w, "IHDR", &ihdr);

    var zbuf = std.Io.Writer.Allocating.initCapacity(a, raw.len / 4 + 64) catch return error.OutOfMemory;
    defer zbuf.deinit();
    {
        const window = try a.alloc(u8, flate.max_window_len);
        defer a.free(window);
        const z = try a.create(flate.Compress);
        defer a.destroy(z);
        z.* = flate.Compress.init(&zbuf.writer, window, .zlib, .default) catch return error.OutOfMemory;
        z.writer.writeAll(raw) catch return error.OutOfMemory;
        z.finish() catch return error.OutOfMemory;
    }
    try chunk(w, "IDAT", zbuf.written());
    try chunk(w, "IEND", "");
    return aw.toOwnedSlice() catch error.OutOfMemory;
}

fn chunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) Error!void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var sum: [4]u8 = undefined;
    std.mem.writeInt(u32, &sum, crc.final(), .big);
    w.writeAll(&len) catch return error.OutOfMemory;
    w.writeAll(kind) catch return error.OutOfMemory;
    w.writeAll(data) catch return error.OutOfMemory;
    w.writeAll(&sum) catch return error.OutOfMemory;
}

/// The picture scaled to `width` x `height`: each pixel the average of the source area it
/// covers (sharp when shrinking), or blended from its four neighbours when growing; colours are
/// averaged weighted by their opacity, as a canvas does.
pub fn resize(a: std.mem.Allocator, src: Image, width: u32, height: u32) Error!Image {
    const out = try a.alloc(u8, @as(usize, width) * height * 4);
    const sx = @as(f64, @floatFromInt(src.width)) / @as(f64, @floatFromInt(width));
    const sy = @as(f64, @floatFromInt(src.height)) / @as(f64, @floatFromInt(height));
    for (0..height) |y| for (0..width) |x| {
        var acc: [4]f64 = .{ 0, 0, 0, 0 };
        var total: f64 = 0;
        if (sx >= 1 and sy >= 1) {
            // Area average over [x0, x1) x [y0, y1).
            const x0 = @as(f64, @floatFromInt(x)) * sx;
            const x1 = x0 + sx;
            const y0 = @as(f64, @floatFromInt(y)) * sy;
            const y1 = y0 + sy;
            var py: usize = @intFromFloat(@floor(y0));
            while (@as(f64, @floatFromInt(py)) < y1 and py < src.height) : (py += 1) {
                const wy = @min(y1, @as(f64, @floatFromInt(py + 1))) - @max(y0, @as(f64, @floatFromInt(py)));
                var px: usize = @intFromFloat(@floor(x0));
                while (@as(f64, @floatFromInt(px)) < x1 and px < src.width) : (px += 1) {
                    const wx = @min(x1, @as(f64, @floatFromInt(px + 1))) - @max(x0, @as(f64, @floatFromInt(px)));
                    add(&acc, &total, src, px, py, wx * wy);
                }
            }
        } else {
            // Bilinear, pixel centres aligned.
            const fx = @max(0, (@as(f64, @floatFromInt(x)) + 0.5) * sx - 0.5);
            const fy = @max(0, (@as(f64, @floatFromInt(y)) + 0.5) * sy - 0.5);
            const ix: usize = @min(src.width - 1, @as(usize, @intFromFloat(@floor(fx))));
            const iy: usize = @min(src.height - 1, @as(usize, @intFromFloat(@floor(fy))));
            const tx = fx - @as(f64, @floatFromInt(ix));
            const ty = fy - @as(f64, @floatFromInt(iy));
            const nx = @min(src.width - 1, ix + 1);
            const ny = @min(src.height - 1, iy + 1);
            add(&acc, &total, src, ix, iy, (1 - tx) * (1 - ty));
            add(&acc, &total, src, nx, iy, tx * (1 - ty));
            add(&acc, &total, src, ix, ny, (1 - tx) * ty);
            add(&acc, &total, src, nx, ny, tx * ty);
        }
        const o = out[(y * width + x) * 4 ..][0..4];
        const alpha = if (total > 0) acc[3] / total else 0;
        for (0..3) |c| o[c] = if (acc[3] > 0) clamp8(acc[c] / acc[3]) else 0;
        o[3] = clamp8(alpha);
    };
    return .{ .width = width, .height = height, .rgba = out };
}

/// Adds a source pixel with weight `k`: colours premultiplied by their alpha.
fn add(acc: *[4]f64, total: *f64, src: Image, x: usize, y: usize, k: f64) void {
    const p = src.rgba[(y * src.width + x) * 4 ..][0..4];
    const alpha = @as(f64, @floatFromInt(p[3]));
    for (0..3) |c| acc[c] += @as(f64, @floatFromInt(p[c])) * alpha * k;
    acc[3] += alpha * k;
    total.* += k;
}

fn clamp8(v: f64) u8 {
    return @intFromFloat(@min(255, @max(0, @round(v))));
}

/// The picture scaled down (never up) so its longest side is at most `max_side`.
pub fn fit(a: std.mem.Allocator, src: Image, max_side: u32) Error!Image {
    const k = @min(1.0, @as(f64, @floatFromInt(max_side)) / @as(f64, @floatFromInt(@max(src.width, src.height))));
    const w: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(src.width)) * k))));
    const h: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(src.height)) * k))));
    return resize(a, src, w, h);
}

/// A `size` x `size` square of `background` (ARGB; 0: transparent) with the picture centred in
/// it, as large as fits inside `padding` (a fraction of the side) on each side. Home-screen
/// icons: padding 0.08; maskable icons, which are cut to a circle: 0.2.
pub fn square(a: std.mem.Allocator, src: Image, size: u32, background: u32, padding: f32) Error!Image {
    const box = @as(f64, @floatFromInt(size)) * (1 - 2 * @as(f64, padding));
    const k = @min(box / @as(f64, @floatFromInt(src.width)), box / @as(f64, @floatFromInt(src.height)));
    const dw: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(src.width)) * k))));
    const dh: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(src.height)) * k))));
    const pic = try resize(a, src, dw, dh);
    defer pic.deinit(a);
    const out = try a.alloc(u8, @as(usize, size) * size * 4);
    const bg = [4]u8{ @truncate(background >> 16), @truncate(background >> 8), @truncate(background), @truncate(background >> 24) };
    var i: usize = 0;
    while (i < out.len) : (i += 4) out[i..][0..4].* = bg;
    const ox = (size - @min(size, dw)) / 2;
    const oy = (size - @min(size, dh)) / 2;
    for (0..@min(dh, size)) |y| for (0..@min(dw, size)) |x| {
        const s = pic.rgba[(y * dw + x) * 4 ..][0..4];
        const d = out[((oy + y) * size + ox + x) * 4 ..][0..4];
        // "Source over": the picture on the background.
        const sa = @as(f64, @floatFromInt(s[3])) / 255;
        const da = @as(f64, @floatFromInt(d[3])) / 255;
        const oa = sa + da * (1 - sa);
        for (0..3) |c| {
            const v = if (oa > 0) (@as(f64, @floatFromInt(s[c])) * sa + @as(f64, @floatFromInt(d[c])) * da * (1 - sa)) / oa else 0;
            d[c] = clamp8(v);
        }
        d[3] = clamp8(oa * 255);
    };
    return .{ .width = size, .height = size, .rgba = out };
}

test "png: write and read back, scale, place in a square" {
    const a = std.testing.allocator;
    // A 4x2 picture: red, green, blue, transparent; then grey.
    var px: [4 * 2 * 4]u8 = undefined;
    const colours = [_][4]u8{ .{ 255, 0, 0, 255 }, .{ 0, 255, 0, 255 }, .{ 0, 0, 255, 255 }, .{ 0, 0, 0, 0 } };
    for (0..4) |x| px[x * 4 ..][0..4].* = colours[x];
    for (4..8) |x| px[x * 4 ..][0..4].* = .{ 128, 128, 128, 255 };
    const img: Image = .{ .width = 4, .height = 2, .rgba = &px };
    const bytes = try encode(a, img);
    defer a.free(bytes);
    try std.testing.expectEqualStrings(signature, bytes[0..8]);
    const back = try decode(a, bytes);
    defer back.deinit(a);
    try std.testing.expectEqual(@as(u32, 4), back.width);
    try std.testing.expectEqualSlices(u8, &px, back.rgba);

    // Halved: each pixel the average of the two it covers; the transparent one does not darken
    // its neighbour.
    const half = try resize(a, back, 2, 1);
    defer half.deinit(a);
    try std.testing.expectEqualSlices(u8, &.{ 128, 128, 64, 255 }, half.rgba[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 85, 85, 170, 191 }, half.rgba[4..8]);

    // A 10x10 icon on white with 20% padding: the corners are white, the middle the picture.
    const icon = try square(a, back, 10, 0xffffffff, 0.2);
    defer icon.deinit(a);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, icon.rgba[0..4]);
    try std.testing.expectEqual(@as(u8, 255), icon.rgba[(4 * 10 + 2) * 4 + 3]);

    try std.testing.expectError(error.NotPng, decode(a, "GIF89a"));
}
