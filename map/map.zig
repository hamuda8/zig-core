//! The map widget: raster tiles in Web Mercator, a camera (centre, zoom, bearing, pitch), the
//! gestures that move it, route lines and markers. Built only from zui primitives (image, path,
//! view transforms), so it behaves the same on the web, Android and iOS, with no map library.
//!
//! The tiles lie on a square "layer" view turned by the bearing, inside a "tilt" view that the
//! hosts tilt (pitch) natively around the screen centre. The tilt view is cut to the ground the
//! screen can show: far up towards the horizon, just past the bottom edge. (A square centred on
//! the screen would swing its lower half right up to the eye when tilted, which browsers fail to
//! draw.) Markers stay upright: their screen position comes from the same projection, computed
//! here.

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

    /// The ground the screen shows, in the tilted plane around the screen centre (before the
    /// bearing turns it): how far it reaches sideways, up (negative) and down.
    pub fn footprint(v: View) struct { half_width: f64, top: f64, bottom: f64 } {
        const t = std.math.degreesToRadians(v.camera.pitch);
        const p_dist = v.perspective();
        const ground = struct {
            fn y(sy: f64, tt: f64, pd: f64) f64 {
                // Near the horizon the ground runs off to infinity: stop at 8 screen heights.
                const den = pd * @cos(tt) + sy * @sin(tt);
                if (den <= 1e-6) return -8 * pd;
                return @max(sy * pd / den, -8 * pd);
            }
        }.y;
        const top = ground(-v.height / 2, t, p_dist);
        const bottom = ground(v.height / 2, t, p_dist);
        // Width grows with distance: the far (top) edge is the widest.
        const half_width = v.width / 2 * (p_dist - top * @sin(t)) / p_dist;
        return .{ .half_width = @max(half_width, v.width / 2), .top = top, .bottom = bottom };
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

/// What a pointer event did besides moving the camera.
pub const Gesture = struct {
    /// A tap at this screen point (no drag, one finger, short).
    tap: ?[2]f64 = null,
    /// The second tap of a double tap (or double click), here: the map zooms in one level around
    /// it, as MapLibre's. Both taps are reported in `tap` too.
    double_tap: ?[2]f64 = null,
    /// A pressable marker was tapped (its key; see `handleMarkers`).
    marker_press: ?u64 = null,
    /// A draggable marker was let go at a new place.
    marker_drop: ?struct { key: u64, at: LatLng } = null,
};

/// A camera move over time (flyTo, easeTo, fitBounds).
const Animation = struct {
    from: Camera,
    to: Camera,
    duration_ms: f64,
    /// Set at the first frame.
    start_ms: ?f64 = null,
    /// How far to zoom out in the middle of a long flight (0 for an ease).
    arc: f64 = 0,
};

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
    animation: ?Animation = null,
    /// Time of the last frame that moved the camera, for frame-rate independent motion.
    frame_ms: ?f64 = null,
    /// What the fingers and wheel may do (a library map is flat and north-up; a preview is still).
    can_pan: bool = true,
    can_zoom: bool = true,
    can_rotate: bool = true,
    can_tilt: bool = true,
    /// Where and when the current single-finger touch began, for taps.
    touch_start: ?struct { x: f64, y: f64, ms: i64, moved: bool, many: bool } = null,
    /// The last tap, to tell a double tap.
    last_tap: ?struct { x: f64, y: f64, ms: i64 } = null,
    /// A marker being dragged: its key, where it is now, and where the finger holds it.
    drag: ?struct { key: u64, at: LatLng, dx: f64, dy: f64, x0: f64, y0: f64, moved: bool = false } = null,

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

    /// Whether the camera is still moving on its own: ask for display frames and call `step`.
    pub fn moving(s: *const State) bool {
        return s.gliding or s.animation != null;
    }

    /// Advances a glide or an animation to frame time `now_ms`. Returns whether to keep going.
    pub fn step(s: *State, now_ms: f64) bool {
        const dt = if (s.frame_ms) |f| std.math.clamp(now_ms - f, 0, 50) else 16;
        s.frame_ms = now_ms;
        if (s.animation) |*a| {
            const start = a.start_ms orelse blk: {
                a.start_ms = now_ms;
                break :blk now_ms;
            };
            const t = std.math.clamp((now_ms - start) / a.duration_ms, 0, 1);
            s.camera = interpolate(a.*, ease(t));
            if (t >= 1) {
                s.camera = a.to;
                s.animation = null;
            }
        } else if (s.gliding) {
            s.panBy(s.velocity[0] * dt, s.velocity[1] * dt);
            const decay = std.math.pow(f64, 0.92, dt / 16);
            s.velocity[0] *= decay;
            s.velocity[1] *= decay;
            if (@abs(s.velocity[0]) + @abs(s.velocity[1]) < 0.02) s.gliding = false;
        }
        const more = s.moving();
        if (!more) s.frame_ms = null;
        return more;
    }

    /// Moves smoothly to `to` (fields left null keep their value) over `ms`. A long way away it
    /// zooms out and back in, as a flight would.
    pub fn flyTo(s: *State, to: CameraTarget, ms: f64) void {
        const target = to.apply(s.camera);
        s.gliding = false;
        const from_w = project(s.camera.center);
        const to_w = project(target.center);
        var dx = to_w.x - from_w.x;
        if (dx > tile_size / 2) dx -= tile_size;
        if (dx < -tile_size / 2) dx += tile_size;
        // The distance in screens at the lower zoom: more than ~1.5 screens is a flight.
        const k = std.math.pow(f64, 2, @min(s.camera.zoom, target.zoom));
        const screens = std.math.hypot(dx, to_w.y - from_w.y) * k / @max(1, @max(s.width, s.height));
        s.animation = .{ .from = s.camera, .to = target, .duration_ms = ms, .arc = if (screens > 1.5) std.math.log2(screens) else 0 };
    }

    /// Like flyTo, without zooming out on the way.
    pub fn easeTo(s: *State, to: CameraTarget, ms: f64) void {
        s.gliding = false;
        s.animation = .{ .from = s.camera, .to = to.apply(s.camera), .duration_ms = ms };
    }

    /// Shows all of `points` with `padding` points of margin (flat, north up), animated.
    pub fn fitBounds(s: *State, points: []const LatLng, padding: zui.Insets, ms: f64) void {
        if (points.len == 0 or s.width <= 0) return;
        var min: World = .{ .x = std.math.inf(f64), .y = std.math.inf(f64) };
        var max: World = .{ .x = -std.math.inf(f64), .y = -std.math.inf(f64) };
        for (points) |pt| {
            const w = project(pt);
            min = .{ .x = @min(min.x, w.x), .y = @min(min.y, w.y) };
            max = .{ .x = @max(max.x, w.x), .y = @max(max.y, w.y) };
        }
        const room_w = @max(40, s.width - padding.left - padding.right);
        const room_h = @max(40, s.height - padding.top - padding.bottom);
        const span_x = @max(max.x - min.x, 1e-9);
        const span_y = @max(max.y - min.y, 1e-9);
        const zoom = std.math.clamp(std.math.log2(@min(room_w / span_x, room_h / span_y)), s.minZoom(), 17);
        // The centre of the free area, which the padding may shift off the screen's centre.
        const k = std.math.pow(f64, 2, zoom);
        const shift_x = (padding.left - padding.right) / 2 / k;
        const shift_y = (padding.top - padding.bottom) / 2 / k;
        const center = unproject(.{ .x = (min.x + max.x) / 2 - shift_x, .y = (min.y + max.y) / 2 - shift_y });
        s.flyTo(.{ .center = center, .zoom = zoom, .bearing = 0, .pitch = 0 }, ms);
    }

    /// Updates the camera from one pointer event.
    pub fn handle(s: *State, p: zui.Pointer) Gesture {
        const x: f64 = p.x;
        const y: f64 = p.y;
        switch (p.kind) {
            .wheel => {
                if (!s.can_zoom) return .{};
                s.animation = null;
                s.zoomAround(x, y, s.camera.zoom - p.wheel / 300);
                return .{};
            },
            .down => {
                s.gliding = false;
                s.animation = null;
                if (s.count() == 0) {
                    s.touch_start = .{ .x = x, .y = y, .ms = p.time_ms, .moved = false, .many = false };
                } else if (s.touch_start) |*t| t.many = true;
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
                if (s.touch_start) |*t| if (std.math.hypot(x - t.x, y - t.y) > 8) {
                    t.moved = true;
                };
                if (s.count() == 2) {
                    s.movePinch();
                } else if (s.last) |l| if (s.can_pan) {
                    const dt: f64 = @floatFromInt(@max(1, p.time_ms - s.last_ms));
                    s.velocity = .{ (x - l[0]) / dt, (y - l[1]) / dt };
                    s.last_ms = p.time_ms;
                    // The map point under the finger stays under it (exact when tilted too).
                    if (s.view().toWorld(l[0], l[1])) |held| s.keepUnder(held, x, y);
                    s.last = .{ x, y };
                };
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
                if (!known) return .{};
                var gesture: Gesture = .{};
                if (s.count() == 0) if (s.touch_start) |t| {
                    if (p.kind == .up and !t.moved and !t.many and p.time_ms - t.ms < 500) gesture.tap = .{ x, y };
                    s.touch_start = null;
                };
                if (gesture.tap != null) {
                    const lt = s.last_tap;
                    if (lt != null and p.time_ms - lt.?.ms < 350 and std.math.hypot(x - lt.?.x, y - lt.?.y) < 30) {
                        s.last_tap = null;
                        gesture.double_tap = .{ x, y };
                        if (s.can_zoom) {
                            // Where zooming in around the point ends, reached with a short ease.
                            var target = s.*;
                            target.animation = null;
                            target.zoomAround(x, y, @round(s.camera.zoom) + 1);
                            s.easeTo(.{ .center = target.camera.center, .zoom = target.camera.zoom }, 250);
                        }
                    } else s.last_tap = .{ .x = x, .y = y, .ms = p.time_ms };
                }
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
                    if (p.kind == .up and speed > 0.1 and p.time_ms - s.last_ms < 80) s.gliding = true;
                }
                return gesture;
            },
        }
        return .{};
    }

    /// `handle`, with markers that can be pressed or dragged (`Marker.pressable`,
    /// `Marker.draggable`). A finger that comes down on a draggable marker moves the marker,
    /// not the map; `draw` shows it under the finger, and letting go gives `marker_drop`. A tap
    /// on a pressable marker gives `marker_press` instead of `tap`.
    pub fn handleMarkers(s: *State, p: zui.Pointer, markers: []const Marker) Gesture {
        const x: f64 = p.x;
        const y: f64 = p.y;
        if (s.drag) |*d| switch (p.kind) {
            .move => {
                if (std.math.hypot(x - d.x0, y - d.y0) > 4) d.moved = true;
                if (d.moved) if (s.view().toMap(x - d.dx, y - d.dy)) |at| {
                    d.at = at;
                };
                return .{};
            },
            .up, .cancel => {
                const done = d.*;
                s.drag = null;
                if (p.kind == .cancel) return .{};
                if (done.moved) return .{ .marker_drop = .{ .key = done.key, .at = done.at } };
                for (markers, 0..) |m, i| if (markerKey(m, i) == done.key and m.pressable) return .{ .marker_press = done.key };
                return .{};
            },
            else => return .{},
        };
        if (p.kind == .down and s.count() == 0) {
            if (s.markerAt(x, y, markers, true)) |hit| {
                const at = s.view().toScreen(hit.m.at).?;
                s.drag = .{ .key = hit.key, .at = hit.m.at, .dx = x - at[0], .dy = y - at[1], .x0 = x, .y0 = y };
                s.gliding = false;
                s.animation = null;
                return .{};
            }
        }
        var g = s.handle(p);
        if (g.tap) |t| if (s.markerAt(t[0], t[1], markers, false)) |hit| {
            g.tap = null;
            g.marker_press = hit.key;
        };
        return g;
    }

    /// The topmost marker drawn around screen point (x, y) that is draggable (or pressable).
    fn markerAt(s: *const State, x: f64, y: f64, markers: []const Marker, draggable: bool) ?struct { m: Marker, key: u64 } {
        const v = s.view();
        var i = markers.len;
        while (i > 0) {
            i -= 1;
            const m = markers[i];
            if (if (draggable) !m.draggable else !m.pressable) continue;
            const at = v.toScreen(m.at) orelse continue;
            const half: f64 = @max(m.size / 2, 12);
            const cy = if (m.anchor == .bottom) at[1] - m.size / 2 else at[1];
            if (@abs(x - at[0]) <= half and @abs(y - cy) <= half) return .{ .m = m, .key = markerKey(m, i) };
        }
        return null;
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
                p.tilting = s.can_tilt and flat and moved > stretched and turned < 8;
            }
        }
        if (p.tilting == true) {
            s.camera.pitch = std.math.clamp(p.pitch - (my - p.mid_y) * 0.4, 0, max_pitch);
            return;
        }
        if (s.can_zoom) s.camera.zoom = std.math.clamp(p.zoom + std.math.log2(@max(1, dist) / p.distance), s.minZoom(), max_zoom);
        if (s.can_rotate) s.camera.bearing = @mod(p.bearing + std.math.radiansToDegrees(angleDiff(angle, p.angle)), 360);
        if (s.can_pan or s.can_zoom) s.keepUnder(p.anchor, mx, my);
    }
};

/// Camera fields to change; null keeps the current value.
pub const CameraTarget = struct {
    center: ?LatLng = null,
    zoom: ?f64 = null,
    bearing: ?f64 = null,
    pitch: ?f64 = null,

    fn apply(t: CameraTarget, c: Camera) Camera {
        return .{
            .center = t.center orelse c.center,
            .zoom = std.math.clamp(t.zoom orelse c.zoom, 0, max_zoom),
            .bearing = t.bearing orelse c.bearing,
            .pitch = std.math.clamp(t.pitch orelse c.pitch, 0, max_pitch),
        };
    }
};

fn ease(t: f64) f64 {
    return if (t < 0.5) 4 * t * t * t else 1 - std.math.pow(f64, -2 * t + 2, 3) / 2;
}

fn interpolate(a: Animation, t: f64) Camera {
    const f = project(a.from.center);
    const to = project(a.to.center);
    var dx = to.x - f.x;
    if (dx > tile_size / 2) dx -= tile_size;
    if (dx < -tile_size / 2) dx += tile_size;
    // Zoom moves linearly, minus a bump in the middle of a flight.
    const zoom = a.from.zoom + (a.to.zoom - a.from.zoom) * t - a.arc * 4 * t * (1 - t);
    var db = a.to.bearing - a.from.bearing;
    db = @mod(db + 540, 360) - 180;
    return .{
        .center = unproject(.{ .x = @mod(f.x + dx * t, tile_size), .y = f.y + (to.y - f.y) * t }),
        .zoom = @max(0, zoom),
        .bearing = @mod(a.from.bearing + db * t, 360),
        .pitch = a.from.pitch + (a.to.pitch - a.from.pitch) * t,
    };
}

fn angleDiff(a: f64, b: f64) f64 {
    var d = a - b;
    while (d > std.math.pi) d -= 2 * std.math.pi;
    while (d < -std.math.pi) d += 2 * std.math.pi;
    return d;
}

// ---- Drawing ----------------------------------------------------------------------------

pub const Marker = struct {
    at: LatLng,
    /// Image URL; else `icon`; else a dot.
    image: ?[]const u8 = null,
    icon: ?zui.Icon = null,
    size: f32 = 18,
    color: zui.Color = zui.Color.hex("#2563eb"),
    /// Heading in degrees (driver arrows); turns with the map.
    heading: ?f64 = null,
    /// Which point of the marker sits on `at`: its centre, or its bottom (a pin's tip).
    anchor: enum { center, bottom } = .center,
    /// A soft ring around a dot (the live position).
    halo: bool = false,
    /// A dot's ring; an icon's outline when `outline` is set.
    border_color: zui.Color = zui.Color.white,
    border_width: f32 = 2,
    outline: ?zui.Color = null,
    /// A disc of this colour behind the icon (a tracked vehicle): the icon is drawn at
    /// `icon_size` in its middle.
    badge: ?zui.Color = null,
    icon_size: f32 = 24,
    key: u64 = 0,
    /// Tapping it reports its key (`Gesture.marker_press`, through `State.handleMarkers`).
    pressable: bool = false,
    /// It can be dragged; letting it go reports its key and new place (`Gesture.marker_drop`).
    draggable: bool = false,
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
        /// The tiles' look: Maps-js's "Wufour Official MapLibre Adjustments"
        /// (`filter: saturate(0.5) contrast(0.9) brightness(1.2)` on the map canvas).
        tile_filter: zui.ImageFilter = .{ .saturate = 0.5, .contrast = 0.9, .brightness = 1.2 },
        /// The map view's key: pointer events carry it (`Pointer.key`), so two maps on a page can
        /// be told apart.
        key: u64 = 0,
    };
}

/// Draws the map filling its parent. `state` must have the viewport size (`setViewport`).
pub fn draw(comptime Msg: type, ui: *zui.Ui(Msg), state: *const State, o: Options(Msg)) void {
    const v = state.view();
    const c = state.camera;
    if (v.width <= 0 or v.height <= 0) return;

    ui.begin(.{ .width = .fill, .height = .fill, .clip = true, .no_mirror = true, .background = o.background }, .{ .key = o.key, .on_pointer = o.on_pointer });
    defer ui.end();

    // The tilt view: the ground the screen shows, turning around the screen centre.
    const fp = v.footprint();
    const margin = 48.0;
    const half_w = @ceil(fp.half_width + margin);
    const top_y = @floor(fp.top - margin);
    const bottom_y = @ceil(fp.bottom + margin);
    ui.begin(.{
        .position = .absolute,
        .inset = .{ .start = @floatCast(v.width / 2 - half_w), .top = @floatCast(v.height / 2 + top_y) },
        .width = .{ .px = @floatCast(2 * half_w) },
        .height = .{ .px = @floatCast(bottom_y - top_y) },
        .tilt = @floatCast(c.pitch),
        .perspective = @floatCast(v.perspective()),
        .origin = .{ @floatCast(half_w), @floatCast(-top_y) },
        .clip = true,
    }, .{ .key = zui.key("tilt") });
    // The layer: a square around that centre, big enough to fill the tilt view at any bearing.
    const r = @ceil(@sqrt(half_w * half_w + @max(top_y * top_y, bottom_y * bottom_y)));
    const side = 2 * r;
    ui.begin(.{
        .position = .absolute,
        .inset = .{ .start = @floatCast(half_w - r), .top = @floatCast(-top_y - r) },
        .width = .{ .px = @floatCast(side) },
        .height = .{ .px = @floatCast(side) },
        .rotate = @floatCast(-c.bearing),
    }, .{ .key = zui.key("layer") });
    // What of the layer can be seen: the tilt view turned by the bearing (its bounding box).
    const area = visibleArea(half_w, top_y, bottom_y, c.bearing);
    // Two coarser levels underneath: usually already loaded (they were on screen moments ago,
    // or cover a wide area with few tiles), so a new level appears over a picture, never gray.
    const level = tileLevel(c.zoom);
    if (level >= 3) drawTiles(Msg, ui, c, side, area, level - 3, o.tile_url, o.tile_filter);
    if (level >= 1) drawTiles(Msg, ui, c, side, area, level - 1, o.tile_url, o.tile_filter);
    drawTiles(Msg, ui, c, side, area, level, o.tile_url, o.tile_filter);
    drawRoutes(Msg, ui, c, side, area, o.routes);
    ui.end();
    ui.end();

    for (o.markers, 0..) |m, i| {
        const shown_at = if (state.drag) |d| (if (d.key == markerKey(m, i)) d.at else m.at) else m.at;
        const p = v.toScreen(shown_at) orelse continue;
        const half = m.size / 2;
        if (p[0] < -m.size or p[1] < -m.size or p[0] > v.width + m.size or p[1] > v.height + m.size) continue;
        const top: f32 = @as(f32, @floatCast(p[1])) - if (m.anchor == .bottom) m.size else half;
        const style: zui.Style = .{
            .position = .absolute,
            .inset = .{ .start = @as(f32, @floatCast(p[0])) - half, .top = top },
            .width = .{ .px = m.size },
            .height = .{ .px = m.size },
            .rotate = if (m.heading) |h| @floatCast(h - c.bearing) else 0,
        };
        const k = markerKey(m, i);
        if (m.halo) {
            const ring = m.size * 2.6;
            ui.begin(.{
                .position = .absolute,
                .inset = .{ .start = @as(f32, @floatCast(p[0])) - ring / 2, .top = @as(f32, @floatCast(p[1])) - ring / 2 },
                .width = .{ .px = ring },
                .height = .{ .px = ring },
                .radius = ring / 2,
                .background = m.color.withAlpha(0.18),
            }, .{ .key = k +% 1 });
            ui.end();
        }
        if (m.badge) |disc| {
            var b = style;
            b.background = disc;
            b.radius = half;
            b.border_width = 1;
            b.border_color = zui.Color.hex("#0000001f");
            b.align_items = .center;
            b.justify = .center;
            ui.begin(b, .{ .key = k });
            if (m.icon) |ic| ui.icon(ic, m.icon_size, m.color, .{}, 0);
            ui.end();
        } else if (m.image) |url| {
            ui.image(url, style, k);
        } else if (m.icon) |ic| {
            if (m.outline) |ring| ui.iconOutlined(ic, m.size, m.color, ring, m.border_width, style, k) else ui.icon(ic, m.size, m.color, style, k);
        } else {
            var dot = style;
            dot.background = m.color;
            dot.radius = half;
            dot.border_width = m.border_width;
            dot.border_color = m.border_color;
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

/// The part of the layer the screen can show, around its centre: [min x, min y, max x, max y].
fn visibleArea(half_w: f64, top: f64, bottom: f64, bearing: f64) [4]f64 {
    const b = std.math.degreesToRadians(bearing);
    var area: [4]f64 = .{ std.math.inf(f64), std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
    for ([_][2]f64{ .{ -half_w, top }, .{ half_w, top }, .{ -half_w, bottom }, .{ half_w, bottom } }) |p| {
        // The layer is turned by -bearing: what shows at p is the layer's point turned by +bearing.
        const x = p[0] * @cos(b) - p[1] * @sin(b);
        const y = p[0] * @sin(b) + p[1] * @cos(b);
        area = .{ @min(area[0], x), @min(area[1], y), @max(area[2], x), @max(area[3], y) };
    }
    return area;
}

/// The tiles of level `z` covering `area` of the layer, scaled to the camera's zoom.
fn drawTiles(comptime Msg: type, ui: *zui.Ui(Msg), c: Camera, side: f64, area: [4]f64, z: u5, url_template: []const u8, filter: zui.ImageFilter) void {
    const n: i64 = @as(i64, 1) << z;
    const k = std.math.pow(f64, 2, c.zoom - @as(f64, @floatFromInt(z))); // on-screen size of a tile pixel
    const center = project(c.center);
    const cx = center.x * @as(f64, @floatFromInt(n)); // world pixels at zoom z
    const cy = center.y * @as(f64, @floatFromInt(n));

    const x0: i64 = @intFromFloat(@floor((cx + area[0] / k) / tile_size));
    const x1: i64 = @intFromFloat(@floor((cx + area[2] / k) / tile_size));
    const y0: i64 = @max(0, @as(i64, @intFromFloat(@floor((cy + area[1] / k) / tile_size))));
    const y1: i64 = @min(n - 1, @as(i64, @intFromFloat(@floor((cy + area[3] / k) / tile_size))));
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
                .image_filter = filter,
            }, zui.key(@as(u64, z) << 58 | @as(u64, @bitCast(tx & 0x1fffffff)) << 29 | @as(u64, @intCast(ty))));
        }
    }
}

fn drawRoutes(comptime Msg: type, ui: *zui.Ui(Msg), c: Camera, side: f64, area: [4]f64, routes: []const Route) void {
    const center = project(c.center);
    const k = c.scale();
    // Lines are cut to the layer (plus a margin for their width): zoomed in, a route can reach
    // a hundred thousand points beyond it, and drawing that costs every platform dearly.
    const margin = 64.0;
    const box: [4]f64 = .{ side / 2 + area[0] - margin, side / 2 + area[1] - margin, side / 2 + area[2] + margin, side / 2 + area[3] + margin };
    for (routes, 0..) |r, i| {
        var pts: std.ArrayList([2]f32) = .empty;
        var prev: ?[2]f64 = null;
        var open = false; // the last point written ends a visible piece
        for (r.points) |p| {
            const w = project(p);
            const cur: [2]f64 = .{ (w.x - center.x) * k + side / 2, (w.y - center.y) * k + side / 2 };
            defer prev = cur;
            const from = prev orelse {
                if (inBox(cur, box)) {
                    pts.append(ui.arena(), f32x2(cur)) catch return;
                    open = true;
                }
                continue;
            };
            const seg = clipSegment(from, cur, box) orelse {
                open = false;
                continue;
            };
            if (!open) {
                if (pts.items.len > 0) pts.append(ui.arena(), zui.icon.gap) catch return;
                pts.append(ui.arena(), f32x2(seg[0])) catch return;
            }
            pts.append(ui.arena(), f32x2(seg[1])) catch return;
            // Leaving the box: the next visible piece starts a new sub-path.
            open = seg[1][0] == cur[0] and seg[1][1] == cur[1];
        }
        if (pts.items.len < 2) continue;
        ui.path(pts.items, .{ .color = r.color.withAlpha(r.opacity), .width = r.width, .dash = r.dash }, .{
            .position = .absolute,
            .inset = .{ .start = 0, .top = 0 },
            .width = .{ .px = @floatCast(side) },
            .height = .{ .px = @floatCast(side) },
        }, zui.key(i + 2_000_000));
    }
}

fn f32x2(p: [2]f64) [2]f32 {
    return .{ @floatCast(p[0]), @floatCast(p[1]) };
}

fn inBox(p: [2]f64, b: [4]f64) bool {
    return p[0] >= b[0] and p[0] <= b[2] and p[1] >= b[1] and p[1] <= b[3];
}

/// The part of segment a-b inside box b (Liang-Barsky), or null.
fn clipSegment(a: [2]f64, b: [2]f64, box: [4]f64) ?[2][2]f64 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    var t0: f64 = 0;
    var t1: f64 = 1;
    const tests = [_][2]f64{ .{ -dx, a[0] - box[0] }, .{ dx, box[2] - a[0] }, .{ -dy, a[1] - box[1] }, .{ dy, box[3] - a[1] } };
    for (tests) |pq| {
        const p = pq[0];
        const q = pq[1];
        if (p == 0) {
            if (q < 0) return null;
            continue;
        }
        const r = q / p;
        if (p < 0) {
            if (r > t1) return null;
            t0 = @max(t0, r);
        } else {
            if (r < t0) return null;
            t1 = @min(t1, r);
        }
    }
    return .{ .{ a[0] + t0 * dx, a[1] + t0 * dy }, .{ a[0] + t1 * dx, a[1] + t1 * dy } };
}

test clipSegment {
    const box: [4]f64 = .{ 0, 0, 100, 100 };
    try testing.expectEqual([2][2]f64{ .{ 0, 50 }, .{ 100, 50 } }, clipSegment(.{ -50, 50 }, .{ 150, 50 }, box).?);
    try testing.expect(clipSegment(.{ -50, -50 }, .{ -10, 150 }, box) == null);
    try testing.expectEqual([2][2]f64{ .{ 10, 10 }, .{ 20, 20 } }, clipSegment(.{ 10, 10 }, .{ 20, 20 }, box).?);
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

test "the footprint reaches exactly the screen's edges" {
    for ([_]f64{ 0, 30, 60 }) |pitch| {
        const v: View = .{ .camera = .{ .center = .{ .lat = 33.51, .lng = 36.28 }, .zoom = 15, .pitch = pitch }, .width = 412, .height = 915 };
        const fp = v.footprint();
        const t = std.math.degreesToRadians(pitch);
        // Project the footprint's top and bottom edge centres back to the screen.
        for ([_][2]f64{ .{ fp.top, 0 }, .{ fp.bottom, 915 } }) |edge| {
            const ly = edge[0];
            const s = v.perspective() / (v.perspective() - ly * @sin(t));
            try testing.expectApproxEqAbs(edge[1], 457.5 + ly * @cos(t) * s, 1e-6);
        }
        // Sideways at the top: the screen's corner.
        const s_top = v.perspective() / (v.perspective() - fp.top * @sin(t));
        try testing.expectApproxEqAbs(@as(f64, 206), fp.half_width * s_top, 1e-6);
        // The near edge never comes close to the eye.
        try testing.expect(fp.bottom * @sin(t) < 0.5 * v.perspective());
    }
}

test "a tap is reported; a drag is not" {
    var s: State = .{ .camera = .{ .center = .{ .lat = 33.51, .lng = 36.28 }, .zoom = 15 } };
    s.setViewport(400, 800);
    _ = s.handle(.{ .kind = .down, .id = 1, .x = 100, .y = 200, .time_ms = 0 });
    const tap = s.handle(.{ .kind = .up, .id = 1, .x = 102, .y = 201, .time_ms = 120 });
    try testing.expectEqual([2]f64{ 102, 201 }, tap.tap.?);
    _ = s.handle(.{ .kind = .down, .id = 1, .x = 100, .y = 200, .time_ms = 1000 });
    _ = s.handle(.{ .kind = .move, .id = 1, .x = 160, .y = 200, .time_ms = 1050 });
    try testing.expect(s.handle(.{ .kind = .up, .id = 1, .x = 160, .y = 200, .time_ms = 1300 }).tap == null);
}

test "a double tap zooms in one level around the tapped point" {
    var s: State = .{ .camera = .{ .center = .{ .lat = 33.51, .lng = 36.28 }, .zoom = 15 } };
    s.setViewport(400, 800);
    const held = s.view().toMap(100, 200).?;
    _ = s.handle(.{ .kind = .down, .id = 1, .x = 100, .y = 200, .time_ms = 0 });
    try testing.expect(s.handle(.{ .kind = .up, .id = 1, .x = 100, .y = 200, .time_ms = 80 }).double_tap == null);
    _ = s.handle(.{ .kind = .down, .id = 1, .x = 104, .y = 202, .time_ms = 200 });
    const g = s.handle(.{ .kind = .up, .id = 1, .x = 104, .y = 202, .time_ms = 260 });
    try testing.expect(g.double_tap != null and g.tap != null);
    var now: f64 = 0;
    while (s.step(now)) now += 16;
    try testing.expectApproxEqAbs(@as(f64, 16), s.camera.zoom, 1e-9);
    const after = s.view().toScreen(held).?;
    try testing.expectApproxEqAbs(@as(f64, 100), after[0], 8);
    try testing.expectApproxEqAbs(@as(f64, 200), after[1], 8);
    // Two taps far apart in time are two single taps.
    _ = s.handle(.{ .kind = .down, .id = 1, .x = 100, .y = 200, .time_ms = 2000 });
    _ = s.handle(.{ .kind = .up, .id = 1, .x = 100, .y = 200, .time_ms = 2050 });
    _ = s.handle(.{ .kind = .down, .id = 1, .x = 100, .y = 200, .time_ms = 3000 });
    try testing.expect(s.handle(.{ .kind = .up, .id = 1, .x = 100, .y = 200, .time_ms = 3050 }).double_tap == null);
}

test "flyTo arrives exactly, whatever the frame rate" {
    for ([_]f64{ 16.6, 8.3 }) |frame| {
        var s: State = .{ .camera = .{ .center = .{ .lat = 33.51, .lng = 36.28 }, .zoom = 14 } };
        s.setViewport(400, 800);
        s.flyTo(.{ .center = .{ .lat = 3.15, .lng = 101.7 }, .zoom = 15, .pitch = 30 }, 1000);
        var now: f64 = 0;
        var frames: usize = 0;
        var lowest: f64 = 99;
        while (s.step(now)) : (now += frame) {
            frames += 1;
            lowest = @min(lowest, s.camera.zoom);
        }
        try testing.expectApproxEqAbs(@as(f64, 3.15), s.camera.center.lat, 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 15), s.camera.zoom, 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 30), s.camera.pitch, 1e-9);
        try testing.expect(lowest < 10); // flew high between the two cities
        try testing.expectApproxEqAbs(1000 / frame, @as(f64, @floatFromInt(frames)), 2);
    }
}

test "fitBounds shows every point inside the padding" {
    var s: State = .{ .camera = .{ .center = .{ .lat = 0, .lng = 0 }, .zoom = 3 } };
    s.setViewport(400, 800);
    const pts = [_]LatLng{ .{ .lat = 33.50, .lng = 36.27 }, .{ .lat = 33.52, .lng = 36.31 } };
    s.fitBounds(&pts, .{ .top = 100, .bottom = 300, .left = 20, .right = 20 }, 300);
    var now: f64 = 0;
    while (s.step(now)) now += 16;
    for (pts) |pt| {
        const p = s.view().toScreen(pt).?;
        try testing.expect(p[0] >= 19 and p[0] <= 381);
        try testing.expect(p[1] >= 99 and p[1] <= 501);
    }
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

/// A marker's key: its own, or one from its place in the list.
pub fn markerKey(m: Marker, index: usize) u64 {
    return if (m.key != 0) m.key else zui.key(index + 1_000_000);
}

test "markers: a tap presses one, a drag moves one and reports where it was let go" {
    var s: State = .{ .camera = .{ .center = .{ .lat = 33.5, .lng = 36.3 }, .zoom = 14 } };
    s.setViewport(400, 400);
    const markers = [_]Marker{
        .{ .at = .{ .lat = 33.5, .lng = 36.3 }, .pressable = true, .key = 7 },
        .{ .at = s.view().toMap(300, 200).?, .draggable = true, .key = 9 },
    };
    _ = s.handleMarkers(.{ .kind = .down, .id = 1, .x = 201, .y = 199, .time_ms = 0 }, &markers);
    const g = s.handleMarkers(.{ .kind = .up, .id = 1, .x = 201, .y = 199, .time_ms = 100 }, &markers);
    try testing.expectEqual(@as(?u64, 7), g.marker_press);
    try testing.expect(g.tap == null);

    const before = s.camera.center;
    _ = s.handleMarkers(.{ .kind = .down, .id = 1, .x = 302, .y = 200, .time_ms = 1000 }, &markers);
    _ = s.handleMarkers(.{ .kind = .move, .id = 1, .x = 332, .y = 250, .time_ms = 1050 }, &markers);
    try testing.expectEqual(@as(u64, 9), s.drag.?.key);
    const d = s.handleMarkers(.{ .kind = .up, .id = 1, .x = 332, .y = 250, .time_ms = 1100 }, &markers);
    const at = s.view().toScreen(d.marker_drop.?.at).?;
    try testing.expectApproxEqAbs(@as(f64, 330), at[0], 0.01);
    try testing.expectApproxEqAbs(@as(f64, 250), at[1], 0.01);
    // The map stayed where it was.
    try testing.expectEqual(before, s.camera.center);
}
