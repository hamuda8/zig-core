//! Web host: the wasm module calls into the fixed shim `shells/web/zui.js`, which keeps one DOM
//! element per view, places it at the frame zui computed, and measures text.

const std = @import("std");
const zui = @import("../zui.zig");

const js = struct {
    extern "zui" fn zui_create(id: u32, kind: u32) void;
    extern "zui" fn zui_destroy(id: u32) void;
    extern "zui" fn zui_insert(parent: u32, id: u32, index: u32) void;
    extern "zui" fn zui_frame(id: u32, x: f32, y: f32, w: f32, h: f32) void;
    extern "zui" fn zui_box(id: u32, background: u32, radius: f32, border_width: f32, border_color: u32, opacity: f32) void;
    extern "zui" fn zui_pressable(id: u32, on: u32) void;
    extern "zui" fn zui_text(id: u32, ptr: [*]const u8, len: usize, size: f32, weight: u32, line_height: f32, mono: u32, max_lines: u32, color: u32, text_align: u32) void;
    extern "zui" fn zui_input(id: u32, value: [*]const u8, value_len: usize, placeholder: [*]const u8, placeholder_len: usize, size: f32, weight: u32, line_height: f32, mono: u32, color: u32, text_align: u32) void;
    extern "zui" fn zui_content(id: u32, w: f32, h: f32) void;
    extern "zui" fn zui_root_background(argb: u32) void;
    extern "zui" fn zui_transform(id: u32, rotate: f32, tilt: f32, perspective: f32, has_origin: u32, ox: f32, oy: f32) void;
    extern "zui" fn zui_clip(id: u32, on: u32) void;
    extern "zui" fn zui_pointer_listen(id: u32, on: u32) void;
    extern "zui" fn zui_image(id: u32, ptr: [*]const u8, len: usize) void;
    extern "zui" fn zui_path(id: u32, points: [*]const [2]f32, count: usize, color: u32, width: f32, dash_on: f32, dash_off: f32, round: u32, fill: u32) void;
    extern "zui" fn zui_fetch(id: u32, method: [*]const u8, method_len: usize, url: [*]const u8, url_len: usize, body: [*]const u8, body_len: usize, ctype: [*]const u8, ctype_len: usize, headers: [*]const u8, headers_len: usize) void;
    extern "zui" fn zui_storage_get(key: [*]const u8, key_len: usize, out_len: *usize) ?[*]u8;
    extern "zui" fn zui_storage_set(key: [*]const u8, key_len: usize, value: [*]const u8, value_len: usize) void;
    extern "zui" fn zui_storage_remove(key: [*]const u8, key_len: usize) void;
    extern "zui" fn zui_timer(id: u32, ms: u32) void;
    extern "zui" fn zui_location(on: u32) void;
    extern "zui" fn zui_speak(text: [*]const u8, text_len: usize, lang: [*]const u8, lang_len: usize) void;
    extern "zui" fn zui_set_link(ptr: [*]const u8, len: usize) void;
    extern "zui" fn zui_focus(id: u32) void;
    extern "zui" fn zui_image_filter(id: u32, saturate: f32, contrast: f32, brightness: f32) void;
    extern "zui" fn zui_post(ptr: [*]const u8, len: usize) void;
    extern "zui" fn zui_copy(ptr: [*]const u8, len: usize) void;
    extern "zui" fn zui_notify(id: u32, title: [*]const u8, title_len: usize, body: [*]const u8, body_len: usize, urgent: u32) void;
    extern "zui" fn zui_cancel_notify(id: u32) void;
    extern "zui" fn zui_open_url(ptr: [*]const u8, len: usize, new_window: u32) void;
    extern "zui" fn zui_socket_open(id: u32, ptr: [*]const u8, len: usize) void;
    extern "zui" fn zui_socket_send(id: u32, ptr: [*]const u8, len: usize) void;
    extern "zui" fn zui_socket_close(id: u32) void;
    extern "zui" fn zui_request_frame() void;
    extern "zui" fn zui_media_open(id: u32, audio: u32, video: u32, screen: u32, back: u32) void;
    extern "zui" fn zui_media_enable(id: u32, audio: u32, video: u32) void;
    extern "zui" fn zui_media_switch(id: u32) void;
    extern "zui" fn zui_media_close(id: u32) void;
    extern "zui" fn zui_peer_open(id: u32, ice: [*]const u8, ice_len: usize, polite: u32, stream: u32) void;
    extern "zui" fn zui_peer_signal(id: u32, ptr: [*]const u8, len: usize) void;
    extern "zui" fn zui_peer_stream(id: u32, stream: u32) void;
    extern "zui" fn zui_peer_close(id: u32) void;
    extern "zui" fn zui_video(id: u32, stream: u32, mirror: u32, cover: u32) void;
    extern "zui" fn zui_measure(ptr: [*]const u8, len: usize, size: f32, weight: u32, line_height: f32, mono: u32, max_lines: u32, max_width: f32, out: *[2]f32) void;
};

pub fn create(id: u32, kind: zui.tree.Kind) void {
    js.zui_create(id, @backingInt(kind));
}
pub fn destroy(id: u32) void {
    js.zui_destroy(id);
}
pub fn insert(parent: u32, id: u32, index: u32) void {
    js.zui_insert(parent, id, index);
}
pub fn frame(id: u32, r: zui.Rect) void {
    js.zui_frame(id, r.x, r.y, r.w, r.h);
}
pub fn box(id: u32, b: zui.Box) void {
    js.zui_box(id, b.background, b.radius, b.border_width, b.border_color, b.opacity);
}
pub fn pressable(id: u32, on: bool) void {
    js.zui_pressable(id, @intFromBool(on));
}
pub fn text(id: u32, s: []const u8, f: zui.Font, color: u32, a: zui.PhysicalAlign) void {
    js.zui_text(id, s.ptr, s.len, f.size, f.weight, f.line_height, @intFromBool(f.mono), f.max_lines, color, @backingInt(a));
}
pub fn input(id: u32, value: []const u8, placeholder: []const u8, f: zui.Font, color: u32, a: zui.PhysicalAlign) void {
    js.zui_input(id, value.ptr, value.len, placeholder.ptr, placeholder.len, f.size, f.weight, f.line_height, @intFromBool(f.mono), color, @backingInt(a));
}
pub fn content(id: u32, s: zui.Size) void {
    js.zui_content(id, s.w, s.h);
}
pub fn transform(id: u32, t: zui.Transform) void {
    const o = t.origin orelse [2]f32{ 0, 0 };
    js.zui_transform(id, t.rotate, t.tilt, t.perspective, @intFromBool(t.origin != null), o[0], o[1]);
}
pub fn clip(id: u32, on: bool) void {
    js.zui_clip(id, @intFromBool(on));
}
pub fn pointer(id: u32, on: bool) void {
    js.zui_pointer_listen(id, @intFromBool(on));
}
pub fn image(id: u32, url: []const u8) void {
    js.zui_image(id, url.ptr, url.len);
}
pub fn path(id: u32, p: zui.Path) void {
    js.zui_path(id, p.points.ptr, p.points.len, p.color, p.width, p.dash[0], p.dash[1], @intFromBool(p.round), p.fill);
}
pub fn fetch(id: u32, method: []const u8, url: []const u8, body: []const u8, content_type: []const u8, headers: []const u8) void {
    js.zui_fetch(id, method.ptr, method.len, url.ptr, url.len, body.ptr, body.len, content_type.ptr, content_type.len, headers.ptr, headers.len);
}
/// The value comes back in memory the shim got from zui_alloc.
pub fn storageGet(a: std.mem.Allocator, key: []const u8, _: bool) ?[]u8 {
    var len: usize = 0;
    const p = js.zui_storage_get(key.ptr, key.len, &len) orelse return null;
    defer zui.allocator.free(p[0..@max(len, 1)]);
    return a.dupe(u8, p[0..len]) catch null;
}
pub fn storageSet(key: []const u8, value: []const u8, _: bool) void {
    js.zui_storage_set(key.ptr, key.len, value.ptr, value.len);
}
pub fn storageRemove(key: []const u8, _: bool) void {
    js.zui_storage_remove(key.ptr, key.len);
}
pub fn timer(id: u32, ms: u32) void {
    js.zui_timer(id, ms);
}
pub fn location(on: bool) void {
    js.zui_location(@intFromBool(on));
}
pub fn speak(s: []const u8, lang: []const u8) void {
    js.zui_speak(s.ptr, s.len, lang.ptr, lang.len);
}
pub fn setLink(s: []const u8) void {
    js.zui_set_link(s.ptr, s.len);
}
pub fn imageFilter(id: u32, f: zui.ImageFilter) void {
    js.zui_image_filter(id, f.saturate, f.contrast, f.brightness);
}
pub fn focus(id: u32) void {
    js.zui_focus(id);
}
pub fn notify(n: zui.Notification) void {
    js.zui_notify(n.id, n.title.ptr, n.title.len, n.body.ptr, n.body.len, @intFromBool(n.urgent));
}
pub fn cancelNotify(id: u32) void {
    js.zui_cancel_notify(id);
}
/// A web page has no home-screen widget.
pub fn widgetUpdate(_: []const u8, _: []const u8, _: []const u8, _: []const u8) void {}
/// A web page cannot follow the position with the screen off.
pub fn backgroundLocation(_: bool, _: []const u8, _: []const u8) void {}
pub fn copy(text_: []const u8) void {
    js.zui_copy(text_.ptr, text_.len);
}
pub fn openUrl(url: []const u8, new_window: bool) void {
    js.zui_open_url(url.ptr, url.len, @intFromBool(new_window));
}
pub fn post(json: []const u8) void {
    js.zui_post(json.ptr, json.len);
}
pub fn openSocket(id: u32, url: []const u8) void {
    js.zui_socket_open(id, url.ptr, url.len);
}
pub fn sendSocket(id: u32, message: []const u8) void {
    js.zui_socket_send(id, message.ptr, message.len);
}
pub fn closeSocket(id: u32) void {
    js.zui_socket_close(id);
}
pub fn openMedia(id: u32, m: zui.Media) void {
    js.zui_media_open(id, @intFromBool(m.audio), @intFromBool(m.video), @intFromBool(m.screen), @intFromBool(m.back_camera));
}
pub fn mediaEnable(id: u32, audio: bool, video_: bool) void {
    js.zui_media_enable(id, @intFromBool(audio), @intFromBool(video_));
}
pub fn switchCamera(id: u32) void {
    js.zui_media_switch(id);
}
pub fn closeMedia(id: u32) void {
    js.zui_media_close(id);
}
pub fn openPeer(id: u32, p: zui.Peer) void {
    js.zui_peer_open(id, p.ice_servers.ptr, p.ice_servers.len, @intFromBool(p.polite), p.stream);
}
pub fn peerSignal(id: u32, json: []const u8) void {
    js.zui_peer_signal(id, json.ptr, json.len);
}
pub fn peerStream(id: u32, stream: u32) void {
    js.zui_peer_stream(id, stream);
}
pub fn closePeer(id: u32) void {
    js.zui_peer_close(id);
}
pub fn video(id: u32, v: zui.Video) void {
    js.zui_video(id, v.stream, @intFromBool(v.mirror), @intFromBool(v.cover));
}
pub fn requestFrame() void {
    js.zui_request_frame();
}
pub fn rootBackground(argb: u32) void {
    js.zui_root_background(argb);
}
pub fn measure(s: []const u8, f: zui.Font, max_width: f32) zui.Size {
    var out: [2]f32 = .{ 0, 0 };
    js.zui_measure(s.ptr, s.len, f.size, f.weight, f.line_height, @intFromBool(f.mono), f.max_lines, max_width, &out);
    return .{ .w = out[0], .h = out[1] };
}

pub fn exportEntry(comptime App: type) void {
    const R = zui.runtime.Runtime(App, @This());
    const Entry = struct {
        fn start(w: f32, h: f32, is_dark: u32, top: f32, right: f32, bottom: f32, left: f32, lang: [*]const u8, lang_len: usize, link: [*]const u8, link_len: usize) callconv(.c) void {
            // The link outlives this call (the app may keep slices of it).
            const owned = zui.allocator.dupe(u8, link[0..link_len]) catch "";
            R.start(zui.allocator, .{ .width = w, .height = h, .dark = is_dark != 0, .safe = .{ .top = top, .right = right, .bottom = bottom, .left = left }, .link = owned }, lang[0..lang_len]);
        }
        fn resize(w: f32, h: f32) callconv(.c) void {
            R.resize(w, h);
        }
        fn insets(top: f32, right: f32, bottom: f32, left: f32) callconv(.c) void {
            R.setInsets(.{ .top = top, .right = right, .bottom = bottom, .left = left });
        }
        fn dark(on: u32) callconv(.c) void {
            R.setDark(on != 0);
        }
        fn event(id: u32, kind: u32) callconv(.c) void {
            R.event(id, std.enums.fromInt(zui.Event, kind) orelse return);
        }
        fn textEvent(id: u32, ptr: [*]const u8, len: usize) callconv(.c) void {
            R.textEvent(id, ptr[0..len]);
        }
        fn pointerEvent(id: u32, kind: u32, pid: u32, x: f32, y: f32, wheel: f32, time_ms: f64) callconv(.c) void {
            R.pointerEvent(id, .{ .kind = std.enums.fromInt(zui.Pointer.Kind, kind) orelse return, .id = pid, .x = x, .y = y, .wheel = wheel, .time_ms = @intFromFloat(time_ms) });
        }
        fn frame(time_ms: f64) callconv(.c) void {
            R.frame(time_ms);
        }
        fn fetchDone(id: u32, status: u32, ptr: [*]const u8, len: usize) callconv(.c) void {
            R.fetchDone(id, @intCast(@min(status, 999)), ptr[0..len]);
        }
        fn timerDone(id: u32) callconv(.c) void {
            R.timerDone(id);
        }
        fn locationFix(lat: f64, lng: f64, accuracy: f32, heading: f32, speed: f32) callconv(.c) void {
            R.locationEvent(.{ .fix = .{
                .lat = lat,
                .lng = lng,
                .accuracy = accuracy,
                .heading = if (std.math.isNan(heading)) null else heading,
                .speed = if (std.math.isNan(speed)) null else speed,
            } });
        }
        fn locationError(denied: u32) callconv(.c) void {
            R.locationEvent(if (denied != 0) .denied else .unavailable);
        }
        fn socketEvent(id: u32, kind: u32, ptr: [*]const u8, len: usize) callconv(.c) void {
            R.socketEvent(id, std.enums.fromInt(zui.SocketEvent.Kind, kind) orelse return, ptr[0..len]);
        }
        fn mediaEvent(id: u32, kind: u32, ptr: [*]const u8, len: usize) callconv(.c) void {
            R.mediaEvent(id, std.enums.fromInt(zui.MediaEvent.Kind, kind) orelse return, ptr[0..len]);
        }
        fn peerEvent(id: u32, kind: u32, ptr: [*]const u8, len: usize, stream: u32) callconv(.c) void {
            R.peerEvent(id, std.enums.fromInt(zui.PeerEvent.Kind, kind) orelse return, ptr[0..len], stream);
        }
        fn hostMessage(ptr: [*]const u8, len: usize) callconv(.c) void {
            R.hostMessage(ptr[0..len]);
        }
        fn inputEvent(id: u32, kind: u32) callconv(.c) void {
            R.inputEvent(id, std.enums.fromInt(zui.InputEvent, kind) orelse return);
        }
        fn alloc(len: usize) callconv(.c) ?[*]u8 {
            const buf = zui.allocator.alloc(u8, len) catch return null;
            return buf.ptr;
        }
        fn free(ptr: [*]u8, len: usize) callconv(.c) void {
            zui.allocator.free(ptr[0..len]);
        }
    };
    @export(&Entry.start, .{ .name = "zui_start" });
    @export(&Entry.resize, .{ .name = "zui_resize" });
    @export(&Entry.insets, .{ .name = "zui_insets" });
    @export(&Entry.dark, .{ .name = "zui_dark" });
    @export(&Entry.event, .{ .name = "zui_event" });
    @export(&Entry.textEvent, .{ .name = "zui_text_event" });
    @export(&Entry.pointerEvent, .{ .name = "zui_pointer" });
    @export(&Entry.frame, .{ .name = "zui_frame" });
    @export(&Entry.fetchDone, .{ .name = "zui_fetch_done" });
    @export(&Entry.timerDone, .{ .name = "zui_timer_done" });
    @export(&Entry.locationFix, .{ .name = "zui_location_fix" });
    @export(&Entry.locationError, .{ .name = "zui_location_error" });
    @export(&Entry.inputEvent, .{ .name = "zui_input_event" });
    @export(&Entry.socketEvent, .{ .name = "zui_socket_event" });
    @export(&Entry.hostMessage, .{ .name = "zui_host_message" });
    @export(&Entry.mediaEvent, .{ .name = "zui_media_event" });
    @export(&Entry.peerEvent, .{ .name = "zui_peer_event" });
    @export(&Entry.alloc, .{ .name = "zui_alloc" });
    @export(&Entry.free, .{ .name = "zui_free" });
}

extern "zui" fn zui_log(ptr: [*]const u8, len: usize) void;

pub fn log(line: []const u8) void {
    zui_log(line.ptr, line.len);
}
