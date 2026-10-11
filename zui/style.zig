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

/// What the box looks like, as sent to a host.
pub const Box = struct {
    background: u32 = 0,
    radius: f32 = 0,
    border_width: f32 = 0,
    border_color: u32 = 0,
    opacity: f32 = 1,

    pub fn of(s: Style, pressed: bool) Box {
        const bg = if (pressed) s.pressed_background orelse s.background else s.background;
        return .{
            .background = if (bg) |c| c.argb() else 0,
            .radius = s.radius,
            .border_width = s.border_width,
            .border_color = s.border_color.argb(),
            .opacity = if (pressed) s.pressed_opacity orelse s.opacity else s.opacity,
        };
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

    pub fn of(s: Style) Font {
        return .{ .size = s.font_size, .weight = s.weight, .line_height = @round(s.font_size * s.line_height), .mono = s.mono, .max_lines = s.max_lines };
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
