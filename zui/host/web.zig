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
    extern "zui" fn zui_text(id: u32, ptr: [*]const u8, len: usize, size: f32, weight: u32, line_height: f32, mono: u32, max_lines: u32, color: u32, text_align: u32, letter_spacing: f32) void;
    extern "zui" fn zui_input(id: u32, value: [*]const u8, value_len: usize, placeholder: [*]const u8, placeholder_len: usize, size: f32, weight: u32, line_height: f32, mono: u32, color: u32, text_align: u32) void;
    extern "zui" fn zui_content(id: u32, w: f32, h: f32) void;
    extern "zui" fn zui_root_background(argb: u32) void;
    extern "zui" fn zui_transform(id: u32, rotate: f32, tilt: f32, perspective: f32, has_origin: u32, ox: f32, oy: f32) void;
    extern "zui" fn zui_clip(id: u32, on: u32) void;
    extern "zui" fn zui_pointer_listen(id: u32, on: u32) void;
    extern "zui" fn zui_image(id: u32, ptr: [*]const u8, len: usize, headers: [*]const u8, headers_len: usize) void;
    extern "zui" fn zui_stream_open(id: u32, url: [*]const u8, url_len: usize, headers: [*]const u8, headers_len: usize) void;
    extern "zui" fn zui_stream_close(id: u32) void;
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
    extern "zui" fn zui_selection(id: u32, end: u32) i32;
    extern "zui" fn zui_select(id: u32, start: u32, end: u32) void;
    extern "zui" fn zui_image_filter(id: u32, saturate: f32, contrast: f32, brightness: f32) void;
    extern "zui" fn zui_post(ptr: [*]const u8, len: usize) void;
    extern "zui" fn zui_copy(ptr: [*]const u8, len: usize) void;
    extern "zui" fn zui_notify(id: u32, title: [*]const u8, title_len: usize, body: [*]const u8, body_len: usize, urgent: u32) void;
    extern "zui" fn zui_cancel_notify(id: u32) void;
    extern "zui" fn zui_register_push(key: [*]const u8, key_len: usize) void;
    extern "zui" fn zui_open_url(ptr: [*]const u8, len: usize, new_window: u32) void;
    extern "zui" fn zui_socket_open(id: u32, ptr: [*]const u8, len: usize) void;
    extern "zui" fn zui_socket_send(id: u32, ptr: [*]const u8, len: usize) void;
    extern "zui" fn zui_socket_close(id: u32) void;
    extern "zui" fn zui_request_frame() void;
    extern "zui" fn zui_media_open(id: u32, audio: u32, video: u32, screen: u32, back: u32) void;
    extern "zui" fn zui_media_enable(id: u32, audio: u32, video: u32) void;
    extern "zui" fn zui_media_switch(id: u32) void;
    extern "zui" fn zui_media_devices(id: u32) void;
    extern "zui" fn zui_media_use(id: u32, kind: u32, ptr: [*]const u8, len: usize) void;
    extern "zui" fn zui_media_close(id: u32) void;
    extern "zui" fn zui_peer_open(id: u32, ice: [*]const u8, ice_len: usize, polite: u32, stream: u32) void;
    extern "zui" fn zui_peer_signal(id: u32, ptr: [*]const u8, len: usize) void;
    extern "zui" fn zui_peer_stream(id: u32, stream: u32) void;
    extern "zui" fn zui_peer_close(id: u32) void;
    extern "zui" fn zui_video(id: u32, stream: u32, mirror: u32, cover: u32) void;
    extern "zui" fn zui_record_start(id: u32, video: u32, back: u32, max_ms: u32) void;
    extern "zui" fn zui_record_stop(id: u32, cancel: u32) void;
    extern "zui" fn zui_play(id: u32, url: [*]const u8, url_len: usize, data: [*]const u8, data_len: usize, mime: [*]const u8, mime_len: usize, video: u32, autoplay: u32, loop: u32) void;
    extern "zui" fn zui_playback(id: u32, op: u32, value: u32) void;
    extern "zui" fn zui_input_type(id: u32, keyboard: u32, return_key: u32, secure: u32, max_length: u32) void;
    extern "zui" fn zui_pick(kind: u32, value: [*]const u8, value_len: usize, min: [*]const u8, min_len: usize, max: [*]const u8, max_len: usize, title: [*]const u8, title_len: usize, options: [*]const u8, options_len: usize, selected: i32) void;
    extern "zui" fn zui_pick_photo(camera: u32, max_size: u32, quality: u32) void;
    extern "zui" fn zui_pick_file(accept: [*]const u8, accept_len: usize) void;
    extern "zui" fn zui_save_file(name: [*]const u8, name_len: usize, mime: [*]const u8, mime_len: usize, data: [*]const u8, data_len: usize, share: u32) void;
    extern "zui" fn zui_key(id: u32, op: u32, kind: u32, name: [*]const u8, name_len: usize, data: [*]const u8, data_len: usize, peer: [*]const u8, peer_len: usize, iv: [*]const u8, iv_len: usize, aad: [*]const u8, aad_len: usize, salt: [*]const u8, salt_len: usize, info: [*]const u8, info_len: usize, into: [*]const u8, into_len: usize) void;
    extern "zui" fn zui_now() f64;
    extern "zui" fn zui_tz_offset() i32;
    extern "zui" fn zui_vibrate(ms: u32) void;
    extern "zui" fn zui_beep() void;
    extern "zui" fn zui_keep_awake(on: u32) void;
    extern "zui" fn zui_push_link(ptr: [*]const u8, len: usize) void;
    extern "zui" fn zui_back_state(handler: u32, has_history: u32, rtl: u32) void;
    extern "zui" fn zui_measure(ptr: [*]const u8, len: usize, size: f32, weight: u32, line_height: f32, mono: u32, max_lines: u32, max_width: f32, out: *[2]f32, letter_spacing: f32) void;
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
    if (!b.isSimple()) {
        const w = Wire.of(b.decor);
        js_style.zui_decor(id, &w);
    }
}
pub fn pressable(id: u32, on: bool) void {
    js.zui_pressable(id, @intFromBool(on));
}
pub fn text(id: u32, s: []const u8, f: zui.Font, color: u32, a: zui.PhysicalAlign) void {
    js.zui_text(id, s.ptr, s.len, f.size, f.weight, f.line_height, @intFromBool(f.mono), f.max_lines, color, @backingInt(a), f.letter_spacing);
}
pub fn input(id: u32, value: []const u8, placeholder: []const u8, f: zui.Font, color: u32, a: zui.PhysicalAlign) void {
    js.zui_input(id, value.ptr, value.len, placeholder.ptr, placeholder.len, f.size, f.weight, f.line_height, @intFromBool(f.mono), color, @backingInt(a));
}
pub fn inputType(id: u32, t: zui.InputType) void {
    js.zui_input_type(id, @backingInt(t.keyboard), @backingInt(t.return_key), @intFromBool(t.secure), t.max_length);
}
pub fn pick(kind: zui.PickKind, value: []const u8, min: []const u8, max: []const u8, title: []const u8, options: []const u8, selected: i32) void {
    js.zui_pick(@backingInt(kind), value.ptr, value.len, min.ptr, min.len, max.ptr, max.len, title.ptr, title.len, options.ptr, options.len, selected);
}
pub fn pickPhoto(camera: bool, max_size: u32, quality: u8) void {
    js.zui_pick_photo(@intFromBool(camera), max_size, quality);
}
pub fn pickFile(accept: []const u8) void {
    js.zui_pick_file(accept.ptr, accept.len);
}
pub fn saveFile(name: []const u8, mime: []const u8, data: []const u8, share: bool) void {
    js.zui_save_file(name.ptr, name.len, mime.ptr, mime.len, data.ptr, data.len, @intFromBool(share));
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
pub fn image(id: u32, url: []const u8, headers: []const u8) void {
    js.zui_image(id, url.ptr, url.len, headers.ptr, headers.len);
}
pub fn streamOpen(id: u32, url: []const u8, headers: []const u8) void {
    js.zui_stream_open(id, url.ptr, url.len, headers.ptr, headers.len);
}
pub fn streamClose(id: u32) void {
    js.zui_stream_close(id);
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
pub fn selection(id: u32) ?zui.Selection {
    const s = js.zui_selection(id, 0);
    const e = js.zui_selection(id, 1);
    if (s < 0 or e < 0) return null;
    return .{ .start = @intCast(s), .end = @intCast(e) };
}
pub fn select(id: u32, s: zui.Selection) void {
    js.zui_select(id, s.start, s.end);
}
pub fn notify(n: zui.Notification) void {
    js.zui_notify(n.id, n.title.ptr, n.title.len, n.body.ptr, n.body.len, @intFromBool(n.urgent));
}
pub fn cancelNotify(id: u32) void {
    js.zui_cancel_notify(id);
}
/// fx.registerPush: a Web Push subscription by the page's service worker (zui.js).
pub fn registerPush(o: zui.PushOptions) void {
    js.zui_register_push(o.web_key.ptr, o.web_key.len);
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
/// fx.webAuth: the web keeps its cookie flow. The page goes to the sign-in address; the app's
/// server receives the callback and sets its cookies, and the app comes back on that address
/// (no answer reaches `done`).
pub fn webAuth(url: []const u8, _: []const u8, _: zui.WebAuthLook) void {
    js.zui_open_url(url.ptr, url.len, 0);
}
/// The web shares the sign-in through Wufour's own session cookie: nothing here.
pub fn sharedAuthGet(_: std.mem.Allocator, _: []const u8) ?[]u8 {
    return null;
}
pub fn sharedAuthSet(_: []const u8) void {}
pub fn sharedAuthClear(_: []const u8) void {}
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
/// enumerateDevices: microphones, cameras and (where setSinkId exists) loudspeakers; the answer
/// comes back through zui_devices_event.
pub fn listMediaDevices(stream: u32) void {
    js.zui_media_devices(stream);
}
pub fn useMediaDevice(stream: u32, kind: zui.MediaDevice.Kind, id: []const u8) void {
    js.zui_media_use(stream, @intFromEnum(kind), id.ptr, id.len);
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
pub fn startRecording(id: u32, r: zui.Recording) void {
    js.zui_record_start(id, @intFromBool(r.video), @intFromBool(r.back_camera), r.max_ms);
}
pub fn stopRecording(id: u32, cancel: bool) void {
    js.zui_record_stop(id, @intFromBool(cancel));
}
pub fn play(id: u32, p: zui.Playback) void {
    js.zui_play(id, p.url.ptr, p.url.len, p.data.ptr, p.data.len, p.mime.ptr, p.mime.len, @intFromBool(p.video), @intFromBool(p.autoplay), @intFromBool(p.loop));
}
pub fn controlPlayback(id: u32, c: zui.PlaybackControl) void {
    switch (c) {
        .pause => js.zui_playback(id, 1, 0),
        .play => js.zui_playback(id, 2, 0),
        .seek => |ms| js.zui_playback(id, 3, ms),
        .stop => js.zui_playback(id, 4, 0),
        .rate => |pct| js.zui_playback(id, 5, pct),
    }
}
pub fn video(id: u32, v: zui.Video) void {
    js.zui_video(id, v.stream, @intFromBool(v.mirror), @intFromBool(v.cover));
}
/// The key store is WebCrypto's (shells/web/zui.js): non-extractable keys in IndexedDB.
pub fn keyRequest(id: u32, r: zui.keys.Request) void {
    js.zui_key(id, @intFromEnum(r.op), @intFromEnum(r.kind), r.name.ptr, r.name.len, r.data.ptr, r.data.len, r.peer.ptr, r.peer.len, r.iv.ptr, r.iv.len, r.aad.ptr, r.aad.len, r.salt.ptr, r.salt.len, r.info.ptr, r.info.len, r.into.ptr, r.into.len);
}
pub fn now() i64 {
    return @intFromFloat(js.zui_now());
}
pub fn tzOffset() i32 {
    return js.zui_tz_offset();
}
pub fn vibrate(ms: u32) void {
    js.zui_vibrate(ms);
}
pub fn beep() void {
    js.zui_beep();
}
pub fn keepAwake(on: bool) void {
    js.zui_keep_awake(@intFromBool(on));
}
/// The browser keeps the history: a new entry (history.pushState).
pub fn pushLink(s: []const u8) void {
    js.zui_push_link(s.ptr, s.len);
}
pub fn backState(handler: bool, has_history: bool, rtl: bool) void {
    js.zui_back_state(@intFromBool(handler), @intFromBool(has_history), @intFromBool(rtl));
}
pub fn requestFrame() void {
    js.zui_request_frame();
}
pub fn rootBackground(argb: u32) void {
    js.zui_root_background(argb);
}
pub fn measure(s: []const u8, f: zui.Font, max_width: f32) zui.Size {
    var out: [2]f32 = .{ 0, 0 };
    js.zui_measure(s.ptr, s.len, f.size, f.weight, f.line_height, @intFromBool(f.mono), f.max_lines, max_width, &out, f.letter_spacing);
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
        fn selectEvent(id: u32, from: u32, to: u32) callconv(.c) void {
            R.selectEvent(id, from, to);
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
        fn fetchDoneHeaders(id: u32, status: u32, ptr: [*]const u8, len: usize, hptr: [*]const u8, hlen: usize) callconv(.c) void {
            R.fetchDoneWithHeaders(id, @intCast(@min(status, 999)), ptr[0..len], hptr[0..hlen]);
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
        fn devicesEvent(ptr: [*]const u8, len: usize) callconv(.c) void {
            R.mediaDevicesDone(ptr[0..len]);
        }
        fn mediaEvent(id: u32, kind: u32, ptr: [*]const u8, len: usize) callconv(.c) void {
            R.mediaEvent(id, std.enums.fromInt(zui.MediaEvent.Kind, kind) orelse return, ptr[0..len]);
        }
        fn recordEvent(id: u32, kind: u32, level: f32, duration_ms: u32, ptr: [*]const u8, len: usize, mime: [*]const u8, mime_len: usize) callconv(.c) void {
            R.recordEvent(id, std.enums.fromInt(zui.RecordEvent.Kind, kind) orelse return, level, duration_ms, ptr[0..len], mime[0..mime_len]);
        }
        fn playEvent(id: u32, kind: u32, position_ms: u32, duration_ms: u32, ptr: [*]const u8, len: usize) callconv(.c) void {
            R.playEvent(id, std.enums.fromInt(zui.PlayEvent.Kind, kind) orelse return, position_ms, duration_ms, ptr[0..len]);
        }
        fn peerEvent(id: u32, kind: u32, ptr: [*]const u8, len: usize, stream: u32) callconv(.c) void {
            R.peerEvent(id, std.enums.fromInt(zui.PeerEvent.Kind, kind) orelse return, ptr[0..len], stream);
        }
        fn hostMessage(ptr: [*]const u8, len: usize) callconv(.c) void {
            R.hostMessage(ptr[0..len]);
        }
        fn pushToken(ptr: [*]const u8, len: usize, kind: u32) callconv(.c) void {
            R.pushToken(ptr[0..len], std.enums.fromInt(zui.PushKind, @as(u8, @intCast(kind))) orelse return);
        }
        fn pushMessage(ptr: [*]const u8, len: usize) callconv(.c) void {
            R.pushMessage(ptr[0..len]);
        }
        fn inputEvent(id: u32, kind: u32) callconv(.c) void {
            R.inputEvent(id, std.enums.fromInt(zui.InputEvent, kind) orelse return);
        }
        fn streamStatus(id: u32, status: u32) callconv(.c) void {
            R.streamStatus(id, @intCast(@min(status, 999)));
        }
        fn streamData(id: u32, ptr: [*]const u8, len: usize) callconv(.c) void {
            R.streamData(id, ptr[0..len]);
        }
        fn streamEnd(id: u32) callconv(.c) void {
            R.streamEnd(id);
        }
        fn fileDone(data: [*]const u8, data_len: usize, name: [*]const u8, name_len: usize, mime: [*]const u8, mime_len: usize, w: u32, h: u32) callconv(.c) void {
            R.fileDone(data[0..data_len], name[0..name_len], mime[0..mime_len], w, h);
        }
        fn pickDone(ptr: [*]const u8, len: usize) callconv(.c) void {
            R.pickDone(ptr[0..len]);
        }
        fn keyDone(id: u32, status: u32, ptr: [*]const u8, len: usize) callconv(.c) void {
            R.keyDone(id, std.enums.fromInt(zui.keys.Status, status) orelse .failed, ptr[0..len]);
        }
        fn back() callconv(.c) u32 {
            return @intFromBool(R.back());
        }
        fn linkEvent(ptr: [*]const u8, len: usize) callconv(.c) void {
            R.linkEvent(ptr[0..len]);
        }
        fn keyEvent(code: u32, mods: u32) callconv(.c) u32 {
            return @intFromBool(R.keyEvent(zui.KeyEvent.of(code, mods) orelse return 0));
        }
        fn deviceEvent(kind: u32) callconv(.c) void {
            R.deviceEvent(std.enums.fromInt(zui.DeviceEvent, kind) orelse return);
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
    @export(&Entry.fetchDoneHeaders, .{ .name = "zui_fetch_done_headers" });
    @export(&Entry.timerDone, .{ .name = "zui_timer_done" });
    @export(&Entry.locationFix, .{ .name = "zui_location_fix" });
    @export(&Entry.locationError, .{ .name = "zui_location_error" });
    @export(&Entry.inputEvent, .{ .name = "zui_input_event" });
    @export(&Entry.socketEvent, .{ .name = "zui_socket_event" });
    @export(&Entry.hostMessage, .{ .name = "zui_host_message" });
    @export(&Entry.pushToken, .{ .name = "zui_push_token" });
    @export(&Entry.pushMessage, .{ .name = "zui_push_message" });
    @export(&Entry.mediaEvent, .{ .name = "zui_media_event" });
    @export(&Entry.devicesEvent, .{ .name = "zui_devices_event" });
    @export(&Entry.peerEvent, .{ .name = "zui_peer_event" });
    @export(&Entry.recordEvent, .{ .name = "zui_record_event" });
    @export(&Entry.playEvent, .{ .name = "zui_play_event" });
    @export(&Entry.back, .{ .name = "zui_back" });
    @export(&Entry.keyDone, .{ .name = "zui_key_done" });
    @export(&Entry.pickDone, .{ .name = "zui_pick_done" });
    @export(&Entry.fileDone, .{ .name = "zui_file_done" });
    @export(&Entry.streamStatus, .{ .name = "zui_stream_status" });
    @export(&Entry.streamData, .{ .name = "zui_stream_data" });
    @export(&Entry.streamEnd, .{ .name = "zui_stream_end" });
    @export(&Entry.linkEvent, .{ .name = "zui_link_event" });
    @export(&Entry.deviceEvent, .{ .name = "zui_device_event" });
    @export(&Entry.keyEvent, .{ .name = "zui_key_event" });
    @export(&Entry.selectEvent, .{ .name = "zui_select_event" });
    @export(&Entry.alloc, .{ .name = "zui_alloc" });
    @export(&Entry.free, .{ .name = "zui_free" });
    exportStyle(R);
}

extern "zui" fn zui_log(ptr: [*]const u8, len: usize) void;

pub fn log(line: []const u8) void {
    zui_log(line.ptr, line.len);
}

// ---- Styling and interaction: decorations, rich text, gestures, pictures from memory,
// transitions, spinners, scroll control ----

const js_style = struct {
    extern "zui" fn zui_decor(id: u32, wire: *const Wire) void;
    extern "zui" fn zui_rich_text(id: u32, ptr: [*]const u8, len: usize, spans: [*]const SpanWire, count: usize, size: f32, weight: u32, line_height: f32, mono: u32, max_lines: u32, color: u32, text_align: u32, letter_spacing: f32) void;
    extern "zui" fn zui_measure_rich(ptr: [*]const u8, len: usize, spans: [*]const SpanWire, count: usize, size: f32, weight: u32, line_height: f32, mono: u32, max_lines: u32, max_width: f32, out: *[2]f32, letter_spacing: f32) void;
    extern "zui" fn zui_gestures(id: u32, flags: u32) void;
    extern "zui" fn zui_image_bytes(id: u32, key: [*]const u8, key_len: usize, bytes: [*]const u8, len: usize) void;
    extern "zui" fn zui_image_fit(id: u32, fit: u32) void;
    extern "zui" fn zui_transition(id: u32, duration_ms: u32, x1: f32, y1: f32, x2: f32, y2: f32) void;
    extern "zui" fn zui_spin(id: u32, period_ms: u32) void;
    extern "zui" fn zui_scroll_to(id: u32, offset: f32, animated: u32) void;
    extern "zui" fn zui_label(id: u32, ptr: [*]const u8, len: usize) void;
};

/// A box's decoration as the shim reads it: 31 words.
const Wire = extern struct {
    radii: [4]f32,
    widths: [4]f32,
    colors: [4]u32,
    shadow_color: u32,
    shadow: [3]f32,
    angle: f32,
    count: u32,
    stop_colors: [6]u32,
    stop_at: [6]f32,
    dashed: u32,

    fn of(d: zui.Decor) Wire {
        return .{
            .radii = d.radii,
            .widths = d.border_widths,
            .colors = d.border_colors,
            .shadow_color = d.shadow_color,
            .shadow = d.shadow,
            .angle = d.gradient_angle,
            .count = d.gradient_count,
            .stop_colors = d.gradient_colors,
            .stop_at = d.gradient_at,
            .dashed = @intFromBool(d.dashed),
        };
    }
};

/// A span as the shim reads it: start, length (bytes), flags (bold 1, italic 2, mono 4,
/// underline 8, strike 16), colour, link (-1: none).
const SpanWire = extern struct { start: u32, len: u32, flags: u32, color: u32, link: i32 };

fn spanWires(spans: []const zui.Span, buf: []SpanWire) []SpanWire {
    const n = @min(spans.len, buf.len);
    for (spans[0..n], buf[0..n]) |s, *w| w.* = .{
        .start = s.start,
        .len = s.len,
        .flags = @as(u32, @intFromBool(s.bold)) | @as(u32, @intFromBool(s.italic)) << 1 | @as(u32, @intFromBool(s.mono)) << 2 | @as(u32, @intFromBool(s.underline)) << 3 | @as(u32, @intFromBool(s.strike)) << 4,
        .color = s.color,
        .link = s.link,
    };
    return buf[0..n];
}

pub fn richText(id: u32, s: []const u8, spans: []const zui.Span, f: zui.Font, color: u32, a: zui.PhysicalAlign) void {
    var buf: [256]SpanWire = undefined;
    const w = spanWires(spans, &buf);
    js_style.zui_rich_text(id, s.ptr, s.len, w.ptr, w.len, f.size, f.weight, f.line_height, @intFromBool(f.mono), f.max_lines, color, @backingInt(a), f.letter_spacing);
}
pub fn measureRich(s: []const u8, spans: []const zui.Span, f: zui.Font, max_width: f32) zui.Size {
    var buf: [256]SpanWire = undefined;
    const w = spanWires(spans, &buf);
    var out: [2]f32 = .{ 0, 0 };
    js_style.zui_measure_rich(s.ptr, s.len, w.ptr, w.len, f.size, f.weight, f.line_height, @intFromBool(f.mono), f.max_lines, max_width, &out, f.letter_spacing);
    return .{ .w = out[0], .h = out[1] };
}
pub fn gestures(id: u32, g: zui.Gestures) void {
    js_style.zui_gestures(id, @as(u8, @bitCast(g)));
}
pub fn imageBytes(id: u32, key: []const u8, bytes: []const u8) void {
    js_style.zui_image_bytes(id, key.ptr, key.len, bytes.ptr, bytes.len);
}
pub fn imageFit(id: u32, f: zui.Fit) void {
    js_style.zui_image_fit(id, @intFromEnum(f));
}
pub fn transition(id: u32, t: ?zui.Transition) void {
    const tr = t orelse return js_style.zui_transition(id, 0, 0, 0, 1, 1);
    const p = tr.easing.controlPoints();
    js_style.zui_transition(id, tr.duration_ms, p[0], p[1], p[2], p[3]);
}
pub fn spin(id: u32, period_ms: u16) void {
    js_style.zui_spin(id, period_ms);
}
pub fn scrollTo(id: u32, offset: f32, animated: bool) void {
    js_style.zui_scroll_to(id, offset, @intFromBool(animated));
}
/// A box's label: its tooltip (title) and what screen readers say (aria-label).
pub fn boxLabel(id: u32, s: []const u8) void {
    js_style.zui_label(id, s.ptr, s.len);
}

fn exportStyle(comptime R: type) void {
    const Entry = struct {
        fn spanPress(id: u32, index: u32) callconv(.c) void {
            R.spanPress(id, index);
        }
        fn scroll(id: u32, offset: f32) callconv(.c) void {
            R.scrollEvent(id, offset);
        }
    };
    @export(&Entry.spanPress, .{ .name = "zui_span_press" });
    @export(&Entry.scroll, .{ .name = "zui_scroll" });
    exportScan(R);
}

// ---- Barcode scanners: the camera through getUserMedia, frames to zui.barcode (or the
// browser's own BarcodeDetector where there is one) ----

const js_scan = struct {
    extern "zui" fn zui_scan_open(id: u32, formats: u32, back: u32) void;
    extern "zui" fn zui_scan_close(id: u32) void;
};

pub fn scanOpen(id: u32, formats: zui.barcode.Formats, back: bool) void {
    js_scan.zui_scan_open(id, @as(u8, @bitCast(formats)), @intFromBool(back));
}
pub fn scanClose(id: u32) void {
    js_scan.zui_scan_close(id);
}

fn exportScan(comptime R: type) void {
    const Entry = struct {
        fn frame(id: u32, ptr: [*]const u8, w: u32, h: u32) callconv(.c) void {
            R.scanFrame(id, .{ .width = w, .height = h, .pixels = ptr[0 .. @as(usize, w) * h] });
        }
        fn found(id: u32, format: u32, ptr: [*]const u8, len: usize) callconv(.c) void {
            R.scanFound(id, std.enums.fromInt(zui.barcode.Format, format) orelse return, ptr[0..len]);
        }
        fn state(id: u32, kind: u32, ptr: [*]const u8, len: usize) callconv(.c) void {
            R.scanState(id, std.enums.fromInt(zui.ScanEvent.Kind, kind) orelse return, ptr[0..len]);
        }
    };
    @export(&Entry.frame, .{ .name = "zui_scan_frame" });
    @export(&Entry.found, .{ .name = "zui_scan_found" });
    @export(&Entry.state, .{ .name = "zui_scan_state" });
}
