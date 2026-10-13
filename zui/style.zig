//! Style of one node: layout (a flexbox subset), box and text. Lengths are logical points:
//! CSS px on the web, dp on Android, pt on iOS.

const Color = @import("color.zig").Color;

pub const inf = std.math.inf(f32);
const std = @import("std");

pub const Direction = enum(u8) { column, row };
pub const Justify = enum(u8) { start, center, end, space_between };
pub const Align = enum(u8) { start, center, end, stretch };
pub const Position = enum(u8) { flow, absolute };
pub const TextAlign = enum(u8) { start, center, end };

/// A length along one axis.
pub const Dim = union(enum) {
    /// Size of the content.
    auto,
    /// Fixed size.
    px: f32,
    /// All the space the parent gives: grows along the parent's main axis, stretches across it.
    fill,
};

/// Edges in writing order: `start` is the left side in left-to-right languages and the right
/// side in right-to-left ones.
pub const Edges = struct {
    top: f32 = 0,
    bottom: f32 = 0,
    start: f32 = 0,
    end: f32 = 0,

    pub fn all(v: f32) Edges {
        return .{ .top = v, .bottom = v, .start = v, .end = v };
    }

    pub fn xy(x: f32, y: f32) Edges {
        return .{ .top = y, .bottom = y, .start = x, .end = x };
    }
};

/// Offsets of an absolutely positioned node from its parent's padding box.
pub const Inset = struct {
    top: ?f32 = null,
    bottom: ?f32 = null,
    start: ?f32 = null,
    end: ?f32 = null,
};

pub const Style = struct {
    // Layout
    direction: Direction = .column,
    justify: Justify = .start,
    align_items: Align = .stretch,
    align_self: ?Align = null,
    gap: f32 = 0,
    padding: Edges = .{},
    width: Dim = .auto,
    height: Dim = .auto,
    min_width: f32 = 0,
    max_width: f32 = inf,
    min_height: f32 = 0,
    max_height: f32 = inf,
    grow: f32 = 0,
    position: Position = .flow,
    inset: Inset = .{},

    // Box
    background: ?Color = null,
    radius: f32 = 0,
    border_width: f32 = 0,
    border_color: Color = Color.transparent,
    opacity: f32 = 1,

    // Text (text and input nodes)
    font_size: f32 = 15,
    weight: u16 = 400,
    /// Line height as a multiple of `font_size`.
    line_height: f32 = 1.4,
    color: Color = Color.black,
    text_align: TextAlign = .start,
    mono: bool = false,
    /// 0 = no limit.
    max_lines: u16 = 0,

    // While pressed (pressable views)
    pressed_background: ?Color = null,
    pressed_opacity: ?f32 = null,

    // Transform, around the centre of the view (map bearing and pitch)
    /// Clockwise rotation in degrees.
    rotate: f32 = 0,
    /// Tilt away from the viewer around the horizontal axis, in degrees.
    tilt: f32 = 0,
    /// Distance of the eye for `tilt`, in points; 0 for none.
    perspective: f32 = 0,
    /// The point rotate and tilt turn around, in points from the view's top-left (the eye
    /// looks at it too); null is the centre.
    origin: ?[2]f32 = null,
    /// Hide what children draw outside this view.
    clip: bool = false,
    /// Colour adjustment of an image (the map tiles' look), the same on every platform.
    image_filter: ImageFilter = .{},
    /// Lay the children out left to right even in right-to-left languages (a map, a chart).
    no_mirror: bool = false,

    // Flow over several lines, or a grid
    /// Children that do not fit on the line go on to the next one (a row of chips): `gap` apart
    /// along a line, `line_gap` (default `gap`) between lines.
    wrap: bool = false,
    /// Lays the children out in equal columns, `gap` apart, rows `line_gap` (default `gap`) apart.
    grid: ?Grid = null,
    line_gap: ?f32 = null,

    // More box
    /// One shadow under the box (CSS box-shadow), drawn the same on every platform.
    shadow: ?Shadow = null,
    /// Painted instead of `background`.
    gradient: ?Gradient = null,
    /// Per-side borders (logical sides); replaces `border_width` and `border_color`.
    borders: ?Borders = null,
    /// Per-corner radii (logical corners); replaces `radius`.
    corners: ?Corners = null,
    /// While the mouse is over the view (desktop web), like `pressed_background`.
    hover_background: ?Color = null,
    hover_opacity: ?f32 = null,

    // More text
    /// Extra space after each character, in points.
    letter_spacing: f32 = 0,
    /// Shown in capitals (done in Zig, so it is the same everywhere).
    uppercase: bool = false,

    /// How a picture fills its box.
    fit: Fit = .fill,
    /// Changes of opacity, transform and frame animate, natively (CSS transitions,
    /// Android animators, UIView animations).
    transition: ?Transition = null,
    /// Turns round continuously, once in this many milliseconds (a spinner), natively: no frames
    /// from Zig. 0 for none.
    spin_ms: u16 = 0,
};

/// Equal columns: `columns` of them, or as many as fit `min_width` wide.
pub const Grid = struct {
    columns: u16 = 0,
    min_width: f32 = 0,

    /// How many columns fit in `width`.
    pub fn count(g: Grid, width: f32, gap: f32) usize {
        if (g.columns > 0) return g.columns;
        if (g.min_width <= 0 or !std.math.isFinite(width)) return 1;
        return @max(1, @as(usize, @intFromFloat(@floor((width + gap) / (g.min_width + gap)))));
    }
};

pub const Shadow = struct {
    x: f32 = 0,
    y: f32 = 2,
    /// CSS blur radius.
    blur: f32 = 8,
    color: Color = Color.rgba8(0, 0, 0, 40),
};

pub const Stop = struct { color: Color, at: f32 };

/// A linear gradient of up to 6 stops along `angle` (CSS degrees: 0 towards the top, 90 towards
/// the right, 180 towards the bottom).
pub const Gradient = struct {
    angle: f32 = 180,
    stops: [max_stops]Stop = undefined,
    count: u8 = 0,

    pub const max_stops = 6;

    pub fn linear(angle: f32, stops: []const Stop) Gradient {
        var g: Gradient = .{ .angle = angle };
        for (stops[0..@min(stops.len, max_stops)]) |s| {
            g.stops[g.count] = s;
            g.count += 1;
        }
        return g;
    }

    /// From `a` to `b`.
    pub fn two(angle: f32, a: Color, b: Color) Gradient {
        return linear(angle, &.{ .{ .color = a, .at = 0 }, .{ .color = b, .at = 1 } });
    }
};

pub const Side = struct { width: f32 = 0, color: Color = Color.transparent };

pub const Borders = struct {
    top: Side = .{},
    bottom: Side = .{},
    start: Side = .{},
    end: Side = .{},
};

pub const Corners = struct {
    top_start: f32 = 0,
    top_end: f32 = 0,
    bottom_start: f32 = 0,
    bottom_end: f32 = 0,
};

pub const Fit = enum(u8) {
    /// Stretched to the box.
    fill = 0,
    /// Fills the box, cropped.
    cover = 1,
    /// Whole, inside the box.
    contain = 2,
};

/// The curves CSS, Android and iOS all have exactly (cubic Béziers).
pub const Easing = enum(u8) {
    linear = 0,
    ease_in = 1,
    ease_out = 2,
    ease_in_out = 3,

    pub fn controlPoints(e: Easing) [4]f32 {
        return switch (e) {
            .linear => .{ 0, 0, 1, 1 },
            .ease_in => .{ 0.42, 0, 1, 1 },
            .ease_out => .{ 0, 0, 0.58, 1 },
            .ease_in_out => .{ 0.42, 0, 0.58, 1 },
        };
    }
};

pub const Transition = struct {
    duration_ms: u16 = 200,
    easing: Easing = .ease_out,
};

/// CSS's saturate(), contrast() and brightness(), in that order. The web uses CSS itself;
/// Android and iOS apply `matrix()`, the same arithmetic as one colour matrix.
pub const ImageFilter = struct {
    saturate: f32 = 1,
    contrast: f32 = 1,
    brightness: f32 = 1,

    pub fn isIdentity(f: ImageFilter) bool {
        return f.saturate == 1 and f.contrast == 1 and f.brightness == 1;
    }

    /// Rows R, G, B, A; columns R, G, B, A, offset (offset on a 0-1 scale).
    pub fn matrix(f: ImageFilter) [20]f32 {
        const s = f.saturate;
        // saturate() (Filter Effects spec), then contrast (c·x + (1-c)/2), then brightness (b·x).
        const sat = [3][3]f32{
            .{ 0.213 + 0.787 * s, 0.715 - 0.715 * s, 0.072 - 0.072 * s },
            .{ 0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s },
            .{ 0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s },
        };
        const k = f.brightness * f.contrast;
        const offset = f.brightness * (0.5 - 0.5 * f.contrast);
        var m: [20]f32 = @splat(0);
        for (0..3) |r| {
            for (0..3) |c| m[r * 5 + c] = sat[r][c] * k;
            m[r * 5 + 4] = offset;
        }
        m[18] = 1; // alpha unchanged
        return m;
    }
};

pub const Transform = struct {
    rotate: f32 = 0,
    tilt: f32 = 0,
    perspective: f32 = 0,
    origin: ?[2]f32 = null,

    pub fn of(s: Style) Transform {
        return .{ .rotate = s.rotate, .tilt = s.tilt, .perspective = s.perspective, .origin = s.origin };
    }
};

/// What the box looks like, as sent to a host: physical sides and corners. Hosts draw `radius`,
/// `border_width` and `border_color` the simple way when `isSimple`, else the decoration
/// (`decor`) as well.
pub const Box = struct {
    background: u32 = 0,
    /// The radius when all corners are alike, else the largest.
    radius: f32 = 0,
    /// The border when all four sides are alike, else none.
    border_width: f32 = 0,
    border_color: u32 = 0,
    opacity: f32 = 1,
    decor: Decor = .{},

    pub const Look = struct { pressed: bool = false, hovered: bool = false, rtl: bool = false };

    pub fn of(s: Style, look: Look) Box {
        var bg = s.background;
        var opacity = s.opacity;
        if (look.hovered) {
            bg = s.hover_background orelse bg;
            opacity = s.hover_opacity orelse opacity;
        }
        if (look.pressed) {
            bg = s.pressed_background orelse bg;
            opacity = s.pressed_opacity orelse opacity;
        }
        var b: Box = .{ .background = if (bg) |c| c.argb() else 0, .opacity = opacity };
        const d = &b.decor;
        if (s.corners) |c| {
            d.radii = if (look.rtl) .{ c.top_end, c.top_start, c.bottom_start, c.bottom_end } else .{ c.top_start, c.top_end, c.bottom_end, c.bottom_start };
            b.radius = @max(@max(d.radii[0], d.radii[1]), @max(d.radii[2], d.radii[3]));
        } else {
            d.radii = @splat(s.radius);
            b.radius = s.radius;
        }
        if (s.borders) |br| {
            const sides = [4]Side{ br.top, if (look.rtl) br.start else br.end, br.bottom, if (look.rtl) br.end else br.start };
            for (sides, 0..) |sd, k| {
                d.border_widths[k] = sd.width;
                d.border_colors[k] = if (sd.width > 0) sd.color.argb() else 0;
            }
            if (d.uniformBorder()) {
                b.border_width = d.border_widths[0];
                b.border_color = d.border_colors[0];
            }
        } else {
            b.border_width = s.border_width;
            b.border_color = s.border_color.argb();
            d.border_widths = @splat(s.border_width);
            d.border_colors = @splat(b.border_color);
        }
        if (s.shadow) |sh| {
            d.shadow_color = sh.color.argb();
            d.shadow = .{ sh.x, sh.y, sh.blur };
        }
        if (s.gradient) |g| if (g.count > 0) {
            d.gradient_angle = g.angle;
            d.gradient_count = g.count;
            for (g.stops[0..g.count], 0..) |stop, k| {
                d.gradient_colors[k] = stop.color.argb();
                d.gradient_at[k] = stop.at;
            }
        };
        return b;
    }

    /// One background, one radius, one border: what every host draws the simple way.
    pub fn isSimple(b: Box) bool {
        return b.decor.shadow_color >> 24 == 0 and b.decor.gradient_count == 0 and b.decor.uniformCorners() and b.decor.uniformBorder();
    }
};

/// The rest of a box, in physical directions.
pub const Decor = struct {
    /// Top-left, top-right, bottom-right, bottom-left.
    radii: [4]f32 = .{ 0, 0, 0, 0 },
    /// Top, right, bottom, left.
    border_widths: [4]f32 = .{ 0, 0, 0, 0 },
    border_colors: [4]u32 = .{ 0, 0, 0, 0 },
    /// Shadow colour (0: none), and its x, y and blur.
    shadow_color: u32 = 0,
    shadow: [3]f32 = .{ 0, 0, 0 },
    /// CSS angle and up to 6 stops (count 0: no gradient).
    gradient_angle: f32 = 0,
    gradient_count: u8 = 0,
    gradient_colors: [Gradient.max_stops]u32 = @splat(0),
    gradient_at: [Gradient.max_stops]f32 = @splat(0),

    pub fn uniformCorners(d: Decor) bool {
        return d.radii[0] == d.radii[1] and d.radii[1] == d.radii[2] and d.radii[2] == d.radii[3];
    }

    pub fn uniformBorder(d: Decor) bool {
        for (1..4) |k| if (d.border_widths[k] != d.border_widths[0] or d.border_colors[k] != d.border_colors[0]) return false;
        return true;
    }
};

/// How text is drawn and measured, as sent to a host. `text_align` is already resolved to a
/// physical side.
pub const Font = struct {
    size: f32 = 15,
    weight: u16 = 400,
    /// Line box height in points.
    line_height: f32 = 21,
    mono: bool = false,
    max_lines: u16 = 0,
    /// Extra space after each character, in points.
    letter_spacing: f32 = 0,

    pub fn of(s: Style) Font {
        return .{ .size = s.font_size, .weight = s.weight, .line_height = @round(s.font_size * s.line_height), .mono = s.mono, .max_lines = s.max_lines, .letter_spacing = s.letter_spacing };
    }
};

pub const PhysicalAlign = enum(u8) { left = 0, center = 1, right = 2 };

pub fn physicalAlign(a: TextAlign, rtl: bool) PhysicalAlign {
    return switch (a) {
        .center => .center,
        .start => if (rtl) .right else .left,
        .end => if (rtl) .left else .right,
    };
}

pub const Size = struct { w: f32 = 0, h: f32 = 0 };
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn eql(a: Rect, b: Rect) bool {
        return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
    }
};
