//! The map widget: raster tiles in Web Mercator, a camera (centre, zoom, bearing, pitch), the
//! gestures that move it, route lines and markers. Built only from zui primitives (image, path,
//! view transforms), so it behaves the same on the web, Android and iOS, with no map library.
//!
//! The tiles lie on one square "layer" view, centred on the screen, which the hosts rotate
//! (bearing) and tilt (pitch) natively. Markers stay upright: their screen position comes from
//! the same projection the layer uses, computed here.

const std = @import("std");
const zui = @import("zui");

pub const tile_size: f64 = 256;
pub const max_zoom: f64 = 20;
/// Tiles exist up to this zoom; beyond it they are scaled up.
pub const max_tile_zoom: u5 = 19;
pub const max_pitch: f64 = 60;

pub const LatLng = struct {
    lat: f64,
    lng: f64,
};

/// World position in pixels at zoom 0 (multiply by 2^zoom for any other zoom).
pub const World = struct { x: f64, y: f64 };

pub fn project(p: LatLng) World {
    const lat = std.math.clamp(p.lat, -85.05112878, 85.05112878);
    const s = @sin(std.math.degreesToRadians(lat));
    return .{
        .x = (p.lng + 180) / 360 * tile_size,
        .y = (0.5 - @log((1 + s) / (1 - s)) / (4 * std.math.pi)) * tile_size,
    };
}

pub fn unproject(w: World) LatLng {
    const n = std.math.pi - 2 * std.math.pi * w.y / tile_size;
    return .{
        .lat = std.math.radiansToDegrees(std.math.atan(std.math.sinh(n))),
        .lng = w.x / tile_size * 360 - 180,
    };
}

pub const Camera = struct {
    center: LatLng,
    zoom: f64 = 12,
    /// Degrees clockwise from north.
    bearing: f64 = 0,
    /// Degrees from looking straight down.
    pitch: f64 = 0,

    pub fn scale(c: Camera) f64 {
        return std.math.pow(f64, 2, c.zoom);
    }
};

/// Screen ↔ map for one camera and viewport. Screen coordinates are the map view's own points.
pub const View = struct {
    camera: Camera,
    width: f64,
    height: f64,

    /// Distance of the eye from the screen, as maps commonly use it (a 36.87° field of view).
    pub fn perspective(v: View) f64 {
        return 1.5 * v.height;
    }

    /// Where `p` appears on screen, or null when it is behind the horizon.
    pub fn toScreen(v: View, p: LatLng) ?[2]f64 {
        const c = v.camera;
        const w = project(p);
        const cw = project(c.center);
        const k = c.scale();
        var dx = (w.x - cw.x) * k;
        var dy = (w.y - cw.y) * k;
        // Map north turns with the bearing: the layer is rotated by -bearing.
        const b = std.math.degreesToRadians(-c.bearing);
        const rx = dx * @cos(b) - dy * @sin(b);
        const ry = dx * @sin(b) + dy * @cos(b);
        dx = rx;
        dy = ry;
        // Tilt: the top of the layer leans away from the eye.
        const t = std.math.degreesToRadians(c.pitch);
        const z = -dy * @sin(t);
        const p_dist = v.perspective();
        if (p_dist + z <= 1) return null;
        const s = p_dist / (p_dist + z);
        return .{ v.width / 2 + dx * s, v.height / 2 + dy * @cos(t) * s };
    }

    /// The map position under screen point (sx, sy), or null above the horizon.
    pub fn toMap(v: View, sx: f64, sy: f64) ?LatLng {
        return unproject(v.toWorld(sx, sy) orelse return null);
    }

    /// Like toMap, in world pixels at zoom 0 and not clamped to the world: beyond the poles too.
    /// Gestures work in these, since latitude clamps at ±85° and would make them drift.
    pub fn toWorld(v: View, sx: f64, sy: f64) ?World {
        const c = v.camera;
        const x = sx - v.width / 2;
        const y = sy - v.height / 2;
        const t = std.math.degreesToRadians(c.pitch);
        const p_dist = v.perspective();
        // Invert y' = y cos t * P / (P - y sin t)
        const den = p_dist * @cos(t) + y * @sin(t);
        if (den <= 1e-6) return null;
        const ly = y * p_dist / den;
        const lx = x * (p_dist - ly * @sin(t)) / p_dist;
        const b = std.math.degreesToRadians(c.bearing);
        const ux = lx * @cos(b) - ly * @sin(b);
        const uy = lx * @sin(b) + ly * @cos(b);
        const cw = project(c.center);
        const k = c.scale();
        return .{ .x = cw.x + ux / k, .y = cw.y + uy / k };
    }
};

// ---- Gestures ---------------------------------------------------------------------------

/// Camera plus what the fingers are doing. Feed it pointer events; it moves the camera.
pub const State = struct {
    camera: Camera,
    width: f64 = 0,
    height: f64 = 0,
    fingers: [2]?Finger = .{ null, null },
    /// When two fingers start: what they hold, to keep it under them.
    pinch: ?Pinch = null,
    /// Last single-finger position, for panning.
    last: ?[2]f64 = null,
    /// Panning speed (points per ms) when the finger lifts, for the glide after it.
    velocity: [2]f64 = .{ 0, 0 },
    last_ms: i64 = 0,
    gliding: bool = false,

    const Finger = struct { id: u32, x: f64, y: f64 };
    const Pinch = struct {
        anchor: World,
        distance: f64,
        angle: f64,
        mid_y: f64,
        zoom: f64,
        bearing: f64,
        pitch: f64,
        /// Two fingers moving up or down together tilt the map instead.
        tilting: ?bool = null,
    };

    pub fn view(s: *const State) View {
        return .{ .camera = s.camera, .width = s.width, .height = s.height };
    }

    pub fn setViewport(s: *State, width: f64, height: f64) void {
        s.width = width;
        s.height = height;
    }

    /// Zoomed out no further than the world filling the screen at any bearing: past that there
    /// is nothing to see, and a flick would fling the map across continents.
    pub fn minZoom(s: *const State) f64 {
        const diagonal = @sqrt(s.width * s.width + s.height * s.height);
        return @max(0, std.math.log2(@max(1, diagonal) / tile_size));
    }

    fn count(s: *const State) usize {
        return @as(usize, @intFromBool(s.fingers[0] != null)) + @intFromBool(s.fingers[1] != null);
    }

    /// Updates the camera from one pointer event. Returns true when a glide should start (ask for
    /// frames and call `glide` on each).
    pub fn handle(s: *State, p: zui.Pointer) bool {
        const x: f64 = p.x;
        const y: f64 = p.y;
        switch (p.kind) {
            .wheel => {
                s.zoomAround(x, y, s.camera.zoom - p.wheel / 300);
                return false;
            },
            .down => {
                s.gliding = false;
                for (&s.fingers) |*f| if (f.* == null) {
                    f.* = .{ .id = p.id, .x = x, .y = y };
                    break;
                };
                s.velocity = .{ 0, 0 };
                s.last_ms = p.time_ms;
                if (s.count() == 2) s.startPinch() else s.last = .{ x, y };
            },
            .move => {
                for (&s.fingers) |*f| if (f.*) |*fp| if (fp.id == p.id) {
                    fp.x = x;
                    fp.y = y;
                };
                if (s.count() == 2) {
                    s.movePinch();
                } else if (s.last) |l| {
                    const dt: f64 = @floatFromInt(@max(1, p.time_ms - s.last_ms));
                    s.velocity = .{ (x - l[0]) / dt, (y - l[1]) / dt };
                    s.last_ms = p.time_ms;
                    // The map point under the finger stays under it (exact when tilted too).
                    if (s.view().toWorld(l[0], l[1])) |held| s.keepUnder(held, x, y);
                    s.last = .{ x, y };
                }
            },
            .up, .cancel => {
                const was = s.count();
                const known = for (&s.fingers) |*f| {
                    if (f.*) |fp| if (fp.id == p.id) {
                        f.* = null;
                        break true;
                    };
                } else false;
                // A third finger, which the gesture ignores, lifting.
                if (!known) return false;
                s.pinch = null;
                if (was == 2) {
                    // Keep panning with the finger that is left.
                    s.last = for (s.fingers) |f| {
                        if (f) |fp| break .{ fp.x, fp.y };
                    } else null;
                    s.velocity = .{ 0, 0 };
                } else {
                    s.last = null;
                    var speed = @sqrt(s.velocity[0] * s.velocity[0] + s.velocity[1] * s.velocity[1]);
                    // A flick glides at most a few screens.
                    const max_speed = 3.0;
                    if (speed > max_speed) {
                        s.velocity = .{ s.velocity[0] / speed * max_speed, s.velocity[1] / speed * max_speed };
                        speed = max_speed;
                    }
                    if (p.kind == .up and speed > 0.1 and p.time_ms - s.last_ms < 80) {
                        s.gliding = true;
                        return true;
                    }
                }
            },
        }
        return false;
    }

    /// One frame of the glide after a quick pan (16 ms). Returns whether to keep gliding.
    pub fn glide(s: *State) bool {
        if (!s.gliding) return false;
        const dt = 16.0;
        s.panBy(s.velocity[0] * dt, s.velocity[1] * dt);
        s.velocity[0] *= 0.92;
        s.velocity[1] *= 0.92;
        if (@abs(s.velocity[0]) + @abs(s.velocity[1]) < 0.02) s.gliding = false;
        return s.gliding;
    }

    /// Moves the map with the finger by (dx, dy) screen points.
    pub fn panBy(s: *State, dx: f64, dy: f64) void {
        const v = s.view();
        const from = v.toWorld(v.width / 2, v.height / 2) orelse return;
        const to = v.toWorld(v.width / 2 - dx, v.height / 2 - dy) orelse return;
        s.moveCenter(to.x - from.x, to.y - from.y);
    }

    /// Zooms keeping the map point under (x, y) under it.
    pub fn zoomAround(s: *State, x: f64, y: f64, zoom: f64) void {
        const anchor = s.view().toWorld(x, y) orelse return;
        s.camera.zoom = std.math.clamp(zoom, s.minZoom(), max_zoom);
        s.keepUnder(anchor, x, y);
    }

    /// Moves the centre so that `anchor` is at screen (x, y).
    fn keepUnder(s: *State, anchor: World, x: f64, y: f64) void {
        const now_at = s.view().toWorld(x, y) orelse return;
        s.moveCenter(anchor.x - now_at.x, anchor.y - now_at.y);
    }

    /// Shifts the centre by world pixels, wrapping east-west and stopping at the poles.
    fn moveCenter(s: *State, dx: f64, dy: f64) void {
        if (!std.math.isFinite(dx) or !std.math.isFinite(dy)) return;
        const cw = project(s.camera.center);
        s.camera.center = unproject(.{ .x = @mod(cw.x + dx, tile_size), .y = std.math.clamp(cw.y + dy, 0, tile_size) });
    }

    fn fingerPair(s: *const State) ?[2]Finger {
        const a = s.fingers[0] orelse return null;
        const b = s.fingers[1] orelse return null;
        return .{ a, b };
    }

    fn startPinch(s: *State) void {
        const f = s.fingerPair() orelse return;
        const mx = (f[0].x + f[1].x) / 2;
        const my = (f[0].y + f[1].y) / 2;
        s.pinch = .{
            .anchor = s.view().toWorld(mx, my) orelse project(s.camera.center),
            .distance = @max(1, std.math.hypot(f[1].x - f[0].x, f[1].y - f[0].y)),
            .angle = std.math.atan2(f[1].y - f[0].y, f[1].x - f[0].x),
            .mid_y = my,
            .zoom = s.camera.zoom,
            .bearing = s.camera.bearing,
            .pitch = s.camera.pitch,
        };
        s.last = null;
    }

    fn movePinch(s: *State) void {
        const p = &(s.pinch orelse return);
        const f = s.fingerPair() orelse return;
        const mx = (f[0].x + f[1].x) / 2;
        const my = (f[0].y + f[1].y) / 2;
        const dist = std.math.hypot(f[1].x - f[0].x, f[1].y - f[0].y);
        const angle = std.math.atan2(f[1].y - f[0].y, f[1].x - f[0].x);

        // Decide once per gesture: two fingers sliding up/down together tilt; anything else
        // zooms and rotates.
        if (p.tilting == null) {
            const moved = @abs(my - p.mid_y);
            const stretched = @abs(dist - p.distance);
            const turned = @abs(std.math.radiansToDegrees(angleDiff(angle, p.angle)));
            if (moved > 12 or stretched > 12 or turned > 6) {
                const flat = @abs(f[1].y - f[0].y) < 0.6 * @abs(f[1].x - f[0].x);
                p.tilting = flat and moved > stretched and turned < 8;
            }
        }
        if (p.tilting == true) {
            s.camera.pitch = std.math.clamp(p.pitch - (my - p.mid_y) * 0.4, 0, max_pitch);
            return;
        }
        s.camera.zoom = std.math.clamp(p.zoom + std.math.log2(@max(1, dist) / p.distance), s.minZoom(), max_zoom);
        s.camera.bearing = @mod(p.bearing + std.math.radiansToDegrees(angleDiff(angle, p.angle)), 360);
        s.keepUnder(p.anchor, mx, my);
    }
};

fn angleDiff(a: f64, b: f64) f64 {
    var d = a - b;
    while (d > std.math.pi) d -= 2 * std.math.pi;
    while (d < -std.math.pi) d += 2 * std.math.pi;
    return d;
}

// ---- Drawing ----------------------------------------------------------------------------

pub const Marker = struct {
    at: LatLng,
    /// Image URL; null draws a dot.
    icon: ?[]const u8 = null,
    size: f32 = 18,
    color: zui.Color = zui.Color.hex("#2563eb"),
    /// Heading in degrees (driver arrows); turns with the map.
    heading: ?f64 = null,
    key: u64 = 0,
};

pub const Route = struct {
    points: []const LatLng,
    color: zui.Color = zui.Color.hex("#2563eb"),
    width: f32 = 6,
    dash: [2]f32 = .{ 0, 0 },
    opacity: f32 = 0.8,
};

pub fn Options(comptime Msg: type) type {
    return struct {
        /// Tile URL with {z}, {x} and {y}.
        tile_url: []const u8,
        on_pointer: *const fn (zui.Pointer) Msg,
        routes: []const Route = &.{},
        markers: []const Marker = &.{},
        attribution: []const u8 = "© OpenStreetMap",
        background: zui.Color = zui.Color.hex("#e5e3df"),
    };
}

/// Draws the map filling its parent. `state` must have the viewport size (`setViewport`).
pub fn draw(comptime Msg: type, ui: *zui.Ui(Msg), state: *const State, o: Options(Msg)) void {
    const v = state.view();
    const c = state.camera;
    if (v.width <= 0 or v.height <= 0) return;

    ui.begin(.{ .width = .fill, .height = .fill, .clip = true, .no_mirror = true, .background = o.background }, .{ .on_pointer = o.on_pointer });
    defer ui.end();

    // The layer: a square big enough to cover the screen at any bearing, taller when tilted.
    const diagonal = @sqrt(v.width * v.width + v.height * v.height);
    const side = @ceil(diagonal * (1 + 2.2 * @sin(std.math.degreesToRadians(c.pitch))));
    ui.begin(.{
        .position = .absolute,
        .inset = .{ .start = @floatCast((v.width - side) / 2), .top = @floatCast((v.height - side) / 2) },
        .width = .{ .px = @floatCast(side) },
        .height = .{ .px = @floatCast(side) },
        .rotate = @floatCast(-c.bearing),
        .tilt = @floatCast(c.pitch),
        .perspective = @floatCast(v.perspective()),
    }, .{ .key = zui.key("layer") });
    // Two coarser levels underneath: usually already loaded (they were on screen moments ago,
    // or cover a wide area with few tiles), so a new level appears over a picture, never gray.
    const level = tileLevel(c.zoom);
    if (level >= 3) drawTiles(Msg, ui, c, side, level - 3, o.tile_url);
    if (level >= 1) drawTiles(Msg, ui, c, side, level - 1, o.tile_url);
    drawTiles(Msg, ui, c, side, level, o.tile_url);
    drawRoutes(Msg, ui, c, side, o.routes);
    ui.end();

    for (o.markers, 0..) |m, i| {
        const p = v.toScreen(m.at) orelse continue;
        const half = m.size / 2;
        if (p[0] < -m.size or p[1] < -m.size or p[0] > v.width + m.size or p[1] > v.height + m.size) continue;
        const style: zui.Style = .{
            .position = .absolute,
            .inset = .{ .start = @as(f32, @floatCast(p[0])) - half, .top = @as(f32, @floatCast(p[1])) - half },
            .width = .{ .px = m.size },
            .height = .{ .px = m.size },
            .rotate = if (m.heading) |h| @floatCast(h - c.bearing) else 0,
        };
        const k = if (m.key != 0) m.key else zui.key(i + 1_000_000);
        if (m.icon) |url| {
            ui.image(url, style, k);
        } else {
            var dot = style;
            dot.background = m.color;
            dot.radius = half;
            dot.border_width = 2;
            dot.border_color = zui.Color.white;
            ui.begin(dot, .{ .key = k });
            ui.end();
        }
    }

    ui.text(o.attribution, .{
        .position = .absolute,
        .inset = .{ .end = 4, .bottom = ui.env.safe.bottom + 2 },
        .font_size = 10,
        .color = zui.Color.hex("#334155"),
        .background = zui.Color.hex("#ffffffb3"),
        .padding = .xy(4, 1),
    });
}

fn tileLevel(zoom: f64) u5 {
    return @intFromFloat(std.math.clamp(@floor(zoom), 0, @as(f64, max_tile_zoom)));
}

/// The tiles of level `z` covering the layer, scaled to the camera's zoom.
fn drawTiles(comptime Msg: type, ui: *zui.Ui(Msg), c: Camera, side: f64, z: u5, url_template: []const u8) void {
    const n: i64 = @as(i64, 1) << z;
    const k = std.math.pow(f64, 2, c.zoom - @as(f64, @floatFromInt(z))); // on-screen size of a tile pixel
    const center = project(c.center);
    const cx = center.x * @as(f64, @floatFromInt(n)); // world pixels at zoom z
    const cy = center.y * @as(f64, @floatFromInt(n));
    const half = side / 2 / k;

    const x0: i64 = @intFromFloat(@floor((cx - half) / tile_size));
    const x1: i64 = @intFromFloat(@floor((cx + half) / tile_size));
    const y0: i64 = @max(0, @as(i64, @intFromFloat(@floor((cy - half) / tile_size))));
    const y1: i64 = @min(n - 1, @as(i64, @intFromFloat(@floor((cy + half) / tile_size))));
    if (x1 - x0 > 64 or y1 - y0 > 64) return;

    var ty = y0;
    while (ty <= y1) : (ty += 1) {
        var tx = x0;
        while (tx <= x1) : (tx += 1) {
            // Edges are rounded, so neighbouring tiles meet without hairline gaps.
            const left = @round((@as(f64, @floatFromInt(tx)) * tile_size - cx) * k + side / 2);
            const right = @round((@as(f64, @floatFromInt(tx + 1)) * tile_size - cx) * k + side / 2);
            const top = @round((@as(f64, @floatFromInt(ty)) * tile_size - cy) * k + side / 2);
            const bottom = @round((@as(f64, @floatFromInt(ty + 1)) * tile_size - cy) * k + side / 2);
            const wx = @mod(tx, n);
            const url = tileUrl(ui.arena(), url_template, z, wx, ty) catch continue;
            ui.image(url, .{
                .position = .absolute,
                .inset = .{ .start = @floatCast(left), .top = @floatCast(top) },
                .width = .{ .px = @floatCast(right - left) },
                .height = .{ .px = @floatCast(bottom - top) },
            }, zui.key(@as(u64, z) << 58 | @as(u64, @bitCast(tx & 0x1fffffff)) << 29 | @as(u64, @intCast(ty))));
        }
    }
}

fn drawRoutes(comptime Msg: type, ui: *zui.Ui(Msg), c: Camera, side: f64, routes: []const Route) void {
    const center = project(c.center);
    const k = c.scale();
    for (routes, 0..) |r, i| {
        const pts = ui.arena().alloc([2]f32, r.points.len) catch return;
        for (r.points, pts) |p, *out| {
            const w = project(p);
            out.* = .{ @floatCast((w.x - center.x) * k + side / 2), @floatCast((w.y - center.y) * k + side / 2) };
        }
        ui.path(pts, .{ .color = r.color.withAlpha(r.opacity), .width = r.width, .dash = r.dash }, .{
            .position = .absolute,
            .inset = .{ .start = 0, .top = 0 },
            .width = .{ .px = @floatCast(side) },
            .height = .{ .px = @floatCast(side) },
        }, zui.key(i + 2_000_000));
    }
}

pub fn tileUrl(arena: std.mem.Allocator, template: []const u8, z: u5, x: i64, y: i64) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        if (std.mem.startsWith(u8, template[i..], "{z}")) {
            try out.print(arena, "{d}", .{z});
            i += 3;
        } else if (std.mem.startsWith(u8, template[i..], "{x}")) {
            try out.print(arena, "{d}", .{x});
            i += 3;
        } else if (std.mem.startsWith(u8, template[i..], "{y}")) {
            try out.print(arena, "{d}", .{y});
            i += 3;
        } else {
            try out.append(arena, template[i]);
            i += 1;
        }
    }
    return out.items;
}

const testing = std.testing;

test "project and unproject round trip" {
    const p: LatLng = .{ .lat = 33.5138, .lng = 36.2765 };
    const back = unproject(project(p));
    try testing.expectApproxEqAbs(p.lat, back.lat, 1e-9);
    try testing.expectApproxEqAbs(p.lng, back.lng, 1e-9);
    // The equator and the antimeridian land on known pixels.
    try testing.expectApproxEqAbs(@as(f64, 128), project(.{ .lat = 0, .lng = 0 }).y, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), project(.{ .lat = 0, .lng = -180 }).x, 1e-9);
}

test "screen and map conversions invert each other, flat, rotated and tilted" {
    for ([_][2]f64{ .{ 0, 0 }, .{ 37, 0 }, .{ 200, 45 }, .{ 315, 60 } }) |bp| {
        const v: View = .{ .camera = .{ .center = .{ .lat = 33.51, .lng = 36.28 }, .zoom = 14, .bearing = bp[0], .pitch = bp[1] }, .width = 400, .height = 800 };
        for ([_][2]f64{ .{ 200, 400 }, .{ 30, 700 }, .{ 390, 450 }, .{ 120, 300 } }) |s| {
            const m = v.toMap(s[0], s[1]).?;
            const back = v.toScreen(m).?;
            try testing.expectApproxEqAbs(s[0], back[0], 1e-6);
            try testing.expectApproxEqAbs(s[1], back[1], 1e-6);
        }
    }
}

test "pinch zoom keeps the point between the fingers in place" {
    var s: State = .{ .camera = .{ .center = .{ .lat = 33.51, .lng = 36.28 }, .zoom = 14, .bearing = 30 } };
    s.setViewport(400, 800);
    const held = s.view().toMap(100, 200).?;
    _ = s.handle(.{ .kind = .down, .id = 1, .x = 50, .y = 200 });
    _ = s.handle(.{ .kind = .down, .id = 2, .x = 150, .y = 200 });
    _ = s.handle(.{ .kind = .move, .id = 1, .x = 0, .y = 200 });
    _ = s.handle(.{ .kind = .move, .id = 2, .x = 200, .y = 200 });
    try testing.expectApproxEqAbs(@as(f64, 15), s.camera.zoom, 1e-9); // fingers twice as far apart
    const now = s.view().toScreen(held).?;
    try testing.expectApproxEqAbs(@as(f64, 100), now[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 200), now[1], 1e-6);
}

test "fast pinching far out and back in does not drift" {
    var s: State = .{ .camera = .{ .center = .{ .lat = 33.51, .lng = 36.28 }, .zoom = 6, .pitch = 50 } };
    s.setViewport(411, 914);
    var t: i64 = 0;
    for (0..40) |_| {
        // In and out around a point above the centre, down to zoom 1 where the poles show.
        _ = s.handle(.{ .kind = .down, .id = 0, .x = 10, .y = 300, .time_ms = t });
        _ = s.handle(.{ .kind = .down, .id = 1, .x = 401, .y = 300, .time_ms = t });
        var d: f32 = 391;
        while (d > 0.02) : (d /= 1.5) {
            t += 8;
            _ = s.handle(.{ .kind = .move, .id = 0, .x = 205.5 - d / 2, .y = 300, .time_ms = t });
            _ = s.handle(.{ .kind = .move, .id = 1, .x = 205.5 + d / 2, .y = 300, .time_ms = t });
        }
        while (d < 391) : (d *= 1.5) {
            t += 8;
            _ = s.handle(.{ .kind = .move, .id = 0, .x = 205.5 - d / 2, .y = 300, .time_ms = t });
            _ = s.handle(.{ .kind = .move, .id = 1, .x = 205.5 + d / 2, .y = 300, .time_ms = t });
        }
        _ = s.handle(.{ .kind = .up, .id = 0, .x = 10, .y = 300, .time_ms = t });
        _ = s.handle(.{ .kind = .up, .id = 1, .x = 401, .y = 300, .time_ms = t });
    }
    const v = s.view();
    const under = v.toMap(205.5, 300).?;
    const start = (View{ .camera = .{ .center = .{ .lat = 33.51, .lng = 36.28 }, .zoom = s.camera.zoom, .pitch = 50 }, .width = 411, .height = 914 }).toMap(205.5, 300).?;
    try testing.expectApproxEqAbs(start.lat, under.lat, 0.05);
    try testing.expectApproxEqAbs(start.lng, under.lng, 0.05);
}

test "dragging moves the map with the finger" {
    var s: State = .{ .camera = .{ .center = .{ .lat = 33.51, .lng = 36.28 }, .zoom = 15, .bearing = 90, .pitch = 40 } };
    s.setViewport(400, 800);
    const held = s.view().toMap(200, 500).?;
    _ = s.handle(.{ .kind = .down, .id = 1, .x = 200, .y = 500 });
    _ = s.handle(.{ .kind = .move, .id = 1, .x = 260, .y = 450, .time_ms = 16 });
    const now = s.view().toScreen(held).?;
    try testing.expectApproxEqAbs(@as(f64, 260), now[0], 0.5);
    try testing.expectApproxEqAbs(@as(f64, 450), now[1], 0.5);
}

test tileUrl {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("/tiles/3/4/2.png", try tileUrl(arena.allocator(), "/tiles/{z}/{x}/{y}.png", 3, 4, 2));
}
