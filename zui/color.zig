//! Colors, with the same math as the CSS the apps use today: hex, OKLab/OKLCH and
//! `color-mix(in oklab, ...)`, so palettes computed from a few base colors (Turf's white-label
//! scheme) come out the same on every platform.

const std = @import("std");

/// Non-premultiplied sRGB, channels 0..1.
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1,

    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    pub const white: Color = .{ .r = 1, .g = 1, .b = 1 };

    /// "#rgb", "#rgba", "#rrggbb" or "#rrggbbaa". Invalid input is a compile error when used at
    /// comptime, which is how app themes use it.
    pub fn hex(comptime text: []const u8) Color {
        return comptime blk: {
            // Each color costs some comptime branches; a theme has dozens.
            @setEvalBranchQuota(100_000);
            break :blk parseHex(text) catch @compileError("bad hex color: " ++ text);
        };
    }

    pub fn parseHex(text: []const u8) !Color {
        const s = if (text.len > 0 and text[0] == '#') text[1..] else text;
        var v: [4]u8 = .{ 0, 0, 0, 255 };
        switch (s.len) {
            3, 4 => for (s, 0..) |c, i| {
                const n = try std.fmt.charToDigit(c, 16);
                v[i] = n * 17;
            },
            6, 8 => for (0..s.len / 2) |i| {
                v[i] = try std.fmt.parseInt(u8, s[i * 2 ..][0..2], 16);
            },
            else => return error.InvalidColor,
        }
        return rgba8(v[0], v[1], v[2], v[3]);
    }

    pub fn rgba8(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = @as(f32, @floatFromInt(r)) / 255, .g = @as(f32, @floatFromInt(g)) / 255, .b = @as(f32, @floatFromInt(b)) / 255, .a = @as(f32, @floatFromInt(a)) / 255 };
    }

    pub fn withAlpha(c: Color, a: f32) Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
    }

    /// 0xAARRGGBB, what the hosts take.
    pub fn argb(c: Color) u32 {
        return @as(u32, to8(c.a)) << 24 | @as(u32, to8(c.r)) << 16 | @as(u32, to8(c.g)) << 8 | to8(c.b);
    }

    pub fn eql(a: Color, b: Color) bool {
        return a.argb() == b.argb();
    }

    pub fn toOklab(c: Color) Oklab {
        const r = toLinear(c.r);
        const g = toLinear(c.g);
        const b = toLinear(c.b);
        const l = std.math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
        const m = std.math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
        const s = std.math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
        return .{
            .l = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            .a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            .b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
            .alpha = c.a,
        };
    }

    pub fn toOklch(c: Color) Oklch {
        return c.toOklab().toOklch();
    }

    /// `color-mix(in oklab, a p, b)`: `p` is a's share (0..1). Interpolates premultiplied, as CSS
    /// does, so mixing with `transparent` keeps the color and only lowers its alpha.
    pub fn mix(a: Color, p: f32, b: Color) Color {
        const x = a.toOklab();
        const y = b.toOklab();
        const alpha = x.alpha * p + y.alpha * (1 - p);
        if (alpha == 0) return transparent;
        const pre = struct {
            fn f(u: f32, ua: f32, v: f32, va: f32, share: f32) f32 {
                return u * ua * share + v * va * (1 - share);
            }
        }.f;
        return (Oklab{
            .l = pre(x.l, x.alpha, y.l, y.alpha, p) / alpha,
            .a = pre(x.a, x.alpha, y.a, y.alpha, p) / alpha,
            .b = pre(x.b, x.alpha, y.b, y.alpha, p) / alpha,
            .alpha = alpha,
        }).toColor();
    }
};

pub const Oklab = struct {
    l: f32,
    a: f32,
    b: f32,
    alpha: f32 = 1,

    pub fn toColor(o: Oklab) Color {
        const l_ = o.l + 0.3963377774 * o.a + 0.2158037573 * o.b;
        const m_ = o.l - 0.1055613458 * o.a - 0.0638541728 * o.b;
        const s_ = o.l - 0.0894841775 * o.a - 1.2914855480 * o.b;
        const l = l_ * l_ * l_;
        const m = m_ * m_ * m_;
        const s = s_ * s_ * s_;
        // Out-of-gamut channels are clipped, like the current browsers' sRGB conversion.
        return .{
            .r = toGamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            .g = toGamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            .b = toGamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
            .a = o.alpha,
        };
    }

    pub fn toOklch(o: Oklab) Oklch {
        var h = std.math.radiansToDegrees(std.math.atan2(o.b, o.a));
        if (h < 0) h += 360;
        return .{ .l = o.l, .c = @sqrt(o.a * o.a + o.b * o.b), .h = h, .alpha = o.alpha };
    }
};

/// `oklch(l c h / alpha)`. Relative colors such as `oklch(from X calc(l - 0.025) c h)` are
/// written by changing the fields of `X.toOklch()`.
pub const Oklch = struct {
    l: f32,
    c: f32,
    h: f32,
    alpha: f32 = 1,

    pub fn toColor(o: Oklch) Color {
        const h = std.math.degreesToRadians(o.h);
        return (Oklab{ .l = o.l, .a = o.c * @cos(h), .b = o.c * @sin(h), .alpha = o.alpha }).toColor();
    }
};

/// A color that differs between light and dark appearance (CSS `light-dark()`).
pub const Adaptive = struct {
    light: Color,
    dark: Color,

    pub fn of(self: Adaptive, dark: bool) Color {
        return if (dark) self.dark else self.light;
    }
};

fn toLinear(c: f32) f32 {
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

fn toGamma(c: f32) f32 {
    const v = if (c <= 0.0031308) 12.92 * c else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
    return std.math.clamp(v, 0, 1);
}

fn to8(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

const expectApprox = std.testing.expectApproxEqAbs;

test "hex parsing" {
    try std.testing.expectEqual(@as(u32, 0xFF6C5CFF), Color.hex("#6c5cff").argb());
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), Color.hex("#fff").argb());
    try std.testing.expectEqual(@as(u32, 0x80000000), Color.hex("#00000080").argb());
    try std.testing.expectError(error.InvalidColor, Color.parseHex("#12345"));
}

test "oklch of reference colors matches CSS Color 4" {
    const red = Color.hex("#ff0000").toOklch();
    try expectApprox(@as(f32, 0.62796), red.l, 0.0005);
    try expectApprox(@as(f32, 0.25768), red.c, 0.0005);
    try expectApprox(@as(f32, 29.23), red.h, 0.05);
    const white = Color.white.toOklch();
    try expectApprox(@as(f32, 1), white.l, 0.0005);
    try expectApprox(@as(f32, 0), white.c, 0.0005);
}

test "oklch round trip keeps the color" {
    for ([_]Color{ Color.hex("#8A3324"), Color.hex("#D3DDE3"), Color.hex("#6c5cff"), Color.hex("#030200") }) |c| {
        try std.testing.expectEqual(c.argb(), c.toOklch().toColor().argb());
    }
}

test "mix with transparent only changes alpha" {
    const accent = Color.hex("#8A3324");
    const soft = accent.mix(0.16, Color.transparent);
    try expectApprox(@as(f32, 0.16), soft.a, 0.0001);
    try std.testing.expectEqual(accent.withAlpha(0.16).argb(), soft.argb());
}

test "mix of two opaque colors in oklab" {
    // color-mix(in oklab, white 50%, black) is oklab(0.5 0 0) = rgb(99 99 99) in browsers.
    const mid = Color.white.mix(0.5, Color.black);
    try std.testing.expectEqual(@as(u32, 0xFF636363), mid.argb());
}
