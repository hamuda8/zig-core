//! Android host: drives the generic view primitives in `shells/android/.../Zui.java` through
//! JNI. Every view is a real android.view.View; zui decides which views exist, where they are
//! and what they show.

const std = @import("std");
const zui = @import("../zui.zig");
const jni = @import("../platform/jni.zig");

/// Calls: camera, codecs, sound and video views (NDK MediaCodec, AAudio; Camera2 in Java).
/// Used when the app supplies a call engine (`pub const rtc`, see zui/calls.zig).
pub const Media = @import("../media/android.zig");

/// The UI thread's JNI environment, refreshed on every call from Java.
var env: *jni.Env = undefined;
var class: jni.jclass = null;
var methods: struct {
    create: jni.jmethodID,
    destroy: jni.jmethodID,
    insert: jni.jmethodID,
    frame: jni.jmethodID,
    box: jni.jmethodID,
    pressable: jni.jmethodID,
    text: jni.jmethodID,
    input: jni.jmethodID,
    content: jni.jmethodID,
    root_background: jni.jmethodID,
    commit: jni.jmethodID,
    measure: jni.jmethodID,
    transform: jni.jmethodID,
    clip: jni.jmethodID,
    pointer: jni.jmethodID,
    image: jni.jmethodID,
    path: jni.jmethodID,
    request_frame: jni.jmethodID,
    fetch: jni.jmethodID,
    timer: jni.jmethodID,
    location: jni.jmethodID,
    speak: jni.jmethodID,
    set_link: jni.jmethodID,
    focus: jni.jmethodID,
    image_filter: jni.jmethodID,
    copy: jni.jmethodID,
    open_url: jni.jmethodID,
    storage_get: jni.jmethodID,
    storage_set: jni.jmethodID,
    storage_remove: jni.jmethodID,
    open_socket: jni.jmethodID,
    background_location: jni.jmethodID,
    widget_update: jni.jmethodID,
    ring_call: jni.jmethodID,
    start_call: jni.jmethodID,
    call_connected: jni.jmethodID,
    end_call: jni.jmethodID,
    notify: jni.jmethodID,
    cancel_notify: jni.jmethodID,
    send_socket: jni.jmethodID,
    close_socket: jni.jmethodID,
    video: jni.jmethodID,
} = undefined;

/// ZuiDevice.java: Back, the screen kept on, vibration, sound, pickers, files.
var device_class: jni.jclass = null;
var device: struct {
    back_state: jni.jmethodID,
    keep_awake: jni.jmethodID,
    vibrate: jni.jmethodID,
    beep: jni.jmethodID,
    key_import: jni.jmethodID,
    key_generate: jni.jmethodID,
    key_sign: jni.jmethodID,
    key_ecdh: jni.jmethodID,
    key_delete: jni.jmethodID,
    input_type: jni.jmethodID,
    pick: jni.jmethodID,
    pick_photo: jni.jmethodID,
    pick_file: jni.jmethodID,
    save_file: jni.jmethodID,
    stream_open: jni.jmethodID,
    stream_close: jni.jmethodID,
} = undefined;

fn bindDevice(e: *jni.Env) void {
    const f = e.functions;
    const local = f.FindClass(e, "com/wufour/zui/ZuiDevice");
    device_class = f.NewGlobalRef(e, local);
    f.DeleteLocalRef(e, local);
    inline for (.{
        .{ "back_state", "backState", "(ZZZ)V" },
        .{ "keep_awake", "keepAwake", "(Z)V" },
        .{ "vibrate", "vibrate", "(I)V" },
        .{ "beep", "beep", "()V" },
        .{ "key_import", "keyImport", "(Ljava/lang/String;I[B[B)[B" },
        .{ "key_generate", "keyGenerate", "(Ljava/lang/String;I)[B" },
        .{ "key_sign", "keySign", "(Ljava/lang/String;[B)[B" },
        .{ "key_ecdh", "keyEcdh", "(Ljava/lang/String;[B)[B" },
        .{ "key_delete", "keyDelete", "(Ljava/lang/String;)V" },
        .{ "input_type", "inputType", "(IIIZ)V" },
        .{ "pick_photo", "pickPhoto", "(ZII)V" },
        .{ "pick_file", "pickFile", "(Ljava/lang/String;)V" },
        .{ "save_file", "saveFile", "(Ljava/lang/String;Ljava/lang/String;[BZ)V" },
        .{ "stream_open", "streamOpen", "(ILjava/lang/String;Ljava/lang/String;)V" },
        .{ "stream_close", "streamClose", "(I)V" },
        .{ "pick", "pick", "(ILjava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;I)V" },
    }) |m| @field(device, m[0]) = f.GetStaticMethodID(e, device_class, m[1], m[2]);
}

fn callDevice(method: jni.jmethodID, args: []const jni.jvalue) void {
    env.functions.CallStaticVoidMethodA(env, device_class, method, args.ptr);
    check();
}

/// ZuiRecorder.java and ZuiPlayer.java: voice and video messages (MediaRecorder, MediaPlayer).
var messages: struct {
    recorder: jni.jclass,
    player: jni.jclass,
    start: jni.jmethodID,
    stop: jni.jmethodID,
    play: jni.jmethodID,
    control: jni.jmethodID,
} = undefined;

fn bindMessages(e: *jni.Env) void {
    const f = e.functions;
    const r = f.FindClass(e, "com/wufour/zui/ZuiRecorder");
    messages.recorder = f.NewGlobalRef(e, r);
    f.DeleteLocalRef(e, r);
    const p = f.FindClass(e, "com/wufour/zui/ZuiPlayer");
    messages.player = f.NewGlobalRef(e, p);
    f.DeleteLocalRef(e, p);
    messages.start = f.GetStaticMethodID(e, messages.recorder, "start", "(IZZI)V");
    messages.stop = f.GetStaticMethodID(e, messages.recorder, "stop", "(IZ)V");
    messages.play = f.GetStaticMethodID(e, messages.player, "play", "(ILjava/lang/String;[BLjava/lang/String;ZZZ)V");
    messages.control = f.GetStaticMethodID(e, messages.player, "control", "(III)V");
}

pub fn startRecording(id: u32, r: zui.Recording) void {
    env.functions.CallStaticVoidMethodA(env, messages.recorder, messages.start, &[_]jni.jvalue{ int(id), boolean(r.video), boolean(r.back_camera), int(@min(r.max_ms, std.math.maxInt(i32))) });
    check();
}
pub fn stopRecording(id: u32, cancel: bool) void {
    env.functions.CallStaticVoidMethodA(env, messages.recorder, messages.stop, &[_]jni.jvalue{ int(id), boolean(cancel) });
    check();
}
pub fn play(id: u32, p: zui.Playback) void {
    const f = env.functions;
    const ju = newString(p.url);
    defer f.DeleteLocalRef(env, ju);
    const jm = newString(p.mime);
    defer f.DeleteLocalRef(env, jm);
    const jd = f.NewByteArray(env, @intCast(p.data.len));
    defer f.DeleteLocalRef(env, jd);
    if (p.data.len > 0) f.SetByteArrayRegion(env, jd, 0, @intCast(p.data.len), p.data.ptr);
    f.CallStaticVoidMethodA(env, messages.player, messages.play, &[_]jni.jvalue{ int(id), object(ju), object(jd), object(jm), boolean(p.video), boolean(p.autoplay), boolean(p.loop) });
    check();
}
pub fn controlPlayback(id: u32, c: zui.PlaybackControl) void {
    const op: u32, const value: u32 = switch (c) {
        .pause => .{ 1, 0 },
        .play => .{ 2, 0 },
        .seek => |ms| .{ 3, @min(ms, std.math.maxInt(i32)) },
        .stop => .{ 4, 0 },
    };
    env.functions.CallStaticVoidMethodA(env, messages.player, messages.control, &[_]jni.jvalue{ int(id), int(op), int(value) });
    check();
}

const clock = @import("../platform/clock.zig");
pub const now = clock.now;
pub const tzOffset = clock.tzOffset;

pub fn backState(handler: bool, has_history: bool, rtl: bool) void {
    callDevice(device.back_state, &.{ boolean(handler), boolean(has_history), boolean(rtl) });
}
pub fn keepAwake(on: bool) void {
    callDevice(device.keep_awake, &.{boolean(on)});
}
pub fn vibrate(ms: u32) void {
    callDevice(device.vibrate, &.{int(ms)});
}
pub fn beep() void {
    callDevice(device.beep, &.{});
}
pub fn pickPhoto(camera: bool, max_size: u32, quality: u8) void {
    callDevice(device.pick_photo, &.{ boolean(camera), int(max_size), int(quality) });
}
pub fn pickFile(accept: []const u8) void {
    const ja = newString(accept);
    defer env.functions.DeleteLocalRef(env, ja);
    callDevice(device.pick_file, &.{object(ja)});
}
pub fn saveFile(name: []const u8, mime: []const u8, data: []const u8, share: bool) void {
    const f = env.functions;
    const jn = newString(name);
    defer f.DeleteLocalRef(env, jn);
    const jm = newString(mime);
    defer f.DeleteLocalRef(env, jm);
    const jd = f.NewByteArray(env, @intCast(data.len));
    defer f.DeleteLocalRef(env, jd);
    if (data.len > 0) f.SetByteArrayRegion(env, jd, 0, @intCast(data.len), data.ptr);
    callDevice(device.save_file, &.{ object(jn), object(jm), object(jd), boolean(share) });
}
pub fn streamOpen(id: u32, url: []const u8, headers: []const u8) void {
    const ju = newString(url);
    defer env.functions.DeleteLocalRef(env, ju);
    const jh = newString(headers);
    defer env.functions.DeleteLocalRef(env, jh);
    callDevice(device.stream_open, &.{ int(id), object(ju), object(jh) });
}
pub fn streamClose(id: u32) void {
    callDevice(device.stream_close, &.{int(id)});
}
pub fn inputType(id: u32, t: zui.InputType) void {
    callDevice(device.input_type, &.{ int(id), int(@intFromEnum(t.keyboard)), int(@intFromEnum(t.return_key)), boolean(t.secure) });
}
pub fn pick(kind: zui.PickKind, value: []const u8, min: []const u8, max: []const u8, title: []const u8, options: []const u8, selected: i32) void {
    const f = env.functions;
    var refs: [5]jni.jstring = undefined;
    for ([_][]const u8{ value, min, max, title, options }, &refs) |str, *r| r.* = newString(str);
    defer for (refs) |r| f.DeleteLocalRef(env, r);
    callDevice(device.pick, &.{ int(@intFromEnum(kind)), object(refs[0]), object(refs[1]), object(refs[2]), object(refs[3]), object(refs[4]), .{ .i = selected } });
}

/// The UI thread's JNI environment (for the media backend's calls into Java).
pub fn uiEnv() *jni.Env {
    return env;
}

fn bind(e: *jni.Env) void {
    env = e;
    if (class != null) return;
    const f = e.functions;
    const local = f.FindClass(e, "com/wufour/zui/Zui");
    class = f.NewGlobalRef(e, local);
    f.DeleteLocalRef(e, local);
    inline for (.{
        .{ "create", "create", "(II)V" },
        .{ "destroy", "destroy", "(I)V" },
        .{ "insert", "insert", "(III)V" },
        .{ "frame", "frame", "(IFFFF)V" },
        .{ "box", "box", "(IIFFIF)V" },
        .{ "pressable", "pressable", "(IZ)V" },
        .{ "text", "text", "(ILjava/lang/String;FIFZIII)V" },
        .{ "input", "input", "(ILjava/lang/String;Ljava/lang/String;FIFZII)V" },
        .{ "content", "content", "(IFF)V" },
        .{ "root_background", "rootBackground", "(I)V" },
        .{ "commit", "commit", "()V" },
        .{ "measure", "measure", "(Ljava/lang/String;FIFZIF)J" },
        .{ "transform", "transform", "(IFFFZFF)V" },
        .{ "clip", "clip", "(IZ)V" },
        .{ "pointer", "pointer", "(IZ)V" },
        .{ "image", "image", "(ILjava/lang/String;Ljava/lang/String;)V" },
        .{ "path", "path", "(I[FIFFFZI)V" },
        .{ "request_frame", "requestFrame", "()V" },
        .{ "fetch", "fetch", "(ILjava/lang/String;Ljava/lang/String;[BLjava/lang/String;Ljava/lang/String;)V" },
        .{ "storage_get", "storageGet", "(Ljava/lang/String;Z)Ljava/lang/String;" },
        .{ "storage_set", "storageSet", "(Ljava/lang/String;Ljava/lang/String;Z)V" },
        .{ "storage_remove", "storageRemove", "(Ljava/lang/String;Z)V" },
        .{ "open_socket", "openSocket", "(ILjava/lang/String;)V" },
        .{ "background_location", "backgroundLocation", "(ZLjava/lang/String;Ljava/lang/String;)V" },
        .{ "widget_update", "widgetUpdate", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V" },
        .{ "ring_call", "ringCall", "(Ljava/lang/String;Ljava/lang/String;Z)V" },
        .{ "start_call", "startCall", "(Ljava/lang/String;Ljava/lang/String;Z)V" },
        .{ "call_connected", "callConnected", "(Ljava/lang/String;)V" },
        .{ "end_call", "endCall", "(Ljava/lang/String;)V" },
        .{ "notify", "notify", "(ILjava/lang/String;Ljava/lang/String;Z)V" },
        .{ "cancel_notify", "cancelNotify", "(I)V" },
        .{ "send_socket", "sendSocket", "(ILjava/lang/String;)V" },
        .{ "close_socket", "closeSocket", "(I)V" },
        .{ "video", "video", "(IIZZ)V" },
        .{ "timer", "timer", "(II)V" },
        .{ "location", "location", "(Z)V" },
        .{ "speak", "speak", "(Ljava/lang/String;Ljava/lang/String;)V" },
        .{ "set_link", "setLink", "(Ljava/lang/String;)V" },
        .{ "focus", "focus", "(I)V" },
        .{ "image_filter", "imageFilter", "(I[F)V" },
        .{ "copy", "copy", "(Ljava/lang/String;)V" },
        .{ "open_url", "openUrl", "(Ljava/lang/String;)V" },
    }) |m| @field(methods, m[0]) = f.GetStaticMethodID(e, class, m[1], m[2]);
    bindDevice(e);
    bindMessages(e);
}

fn call(method: jni.jmethodID, args: []const jni.jvalue) void {
    env.functions.CallStaticVoidMethodA(env, class, method, args.ptr);
    check();
}

fn check() void {
    const f = env.functions;
    if (f.ExceptionCheck(env) == jni.JNI_TRUE) {
        f.ExceptionDescribe(env);
        f.ExceptionClear(env);
    }
}

fn int(v: anytype) jni.jvalue {
    return .{ .i = @bitCast(@as(u32, @intCast(v))) };
}
fn float(v: f32) jni.jvalue {
    return .{ .f = v };
}
fn boolean(v: bool) jni.jvalue {
    return .{ .z = @intFromBool(v) };
}
fn object(v: jni.jobject) jni.jvalue {
    return .{ .l = v };
}

/// Java strings are UTF-16; going through `NewString` keeps emoji and other characters outside
/// the BMP intact, which `NewStringUTF`'s modified UTF-8 would not.
fn newString(s: []const u8) jni.jstring {
    const f = env.functions;
    var stack: [512]u16 = undefined;
    const len = std.unicode.calcUtf16LeLen(s) catch return f.NewString(env, &stack, 0);
    if (len <= stack.len) {
        const n = std.unicode.utf8ToUtf16Le(&stack, s) catch 0;
        return f.NewString(env, &stack, @intCast(n));
    }
    const heap = zui.allocator.alloc(u16, len) catch return f.NewString(env, &stack, 0);
    defer zui.allocator.free(heap);
    const n = std.unicode.utf8ToUtf16Le(heap, s) catch 0;
    return f.NewString(env, heap.ptr, @intCast(n));
}

pub fn create(id: u32, kind: zui.tree.Kind) void {
    call(methods.create, &.{ int(id), int(@backingInt(kind)) });
    styleCreated(id, kind);
}
pub fn destroy(id: u32) void {
    call(methods.destroy, &.{int(id)});
}
pub fn insert(parent: u32, id: u32, index: u32) void {
    call(methods.insert, &.{ int(parent), int(id), int(index) });
}
pub fn frame(id: u32, r: zui.Rect) void {
    if (animatedFrame(id, r)) return;
    call(methods.frame, &.{ int(id), float(r.x), float(r.y), float(r.w), float(r.h) });
}
pub fn box(id: u32, b: zui.Box) void {
    call(methods.box, &.{ int(id), int(b.background), float(b.radius), float(b.border_width), int(b.border_color), float(b.opacity) });
    styleBox(id, b);
}
pub fn pressable(id: u32, on: bool) void {
    call(methods.pressable, &.{ int(id), boolean(on) });
}
pub fn text(id: u32, s: []const u8, f: zui.Font, color: u32, a: zui.PhysicalAlign) void {
    if (f.letter_spacing != 0 or isSelectable(id)) return richText(id, s, &.{}, f, color, a);
    const js = newString(s);
    defer env.functions.DeleteLocalRef(env, js);
    call(methods.text, &.{ int(id), object(js), float(f.size), int(f.weight), float(f.line_height), boolean(f.mono), int(f.max_lines), int(color), int(@backingInt(a)) });
}
pub fn input(id: u32, value: []const u8, placeholder: []const u8, f: zui.Font, color: u32, a: zui.PhysicalAlign) void {
    const jv = newString(value);
    defer env.functions.DeleteLocalRef(env, jv);
    const jp = newString(placeholder);
    defer env.functions.DeleteLocalRef(env, jp);
    call(methods.input, &.{ int(id), object(jv), object(jp), float(f.size), int(f.weight), float(f.line_height), boolean(f.mono), int(color), int(@backingInt(a)) });
}
pub fn content(id: u32, s: zui.Size) void {
    call(methods.content, &.{ int(id), float(s.w), float(s.h) });
}
pub fn commit() void {
    call(methods.commit, &.{});
}
pub fn rootBackground(argb: u32) void {
    call(methods.root_background, &.{int(argb)});
}
pub fn measure(s: []const u8, f: zui.Font, max_width: f32) zui.Size {
    if (f.letter_spacing != 0) return measureRich(s, &.{}, f, max_width);
    const js = newString(s);
    defer env.functions.DeleteLocalRef(env, js);
    const args = [_]jni.jvalue{ object(js), float(f.size), int(f.weight), float(f.line_height), boolean(f.mono), int(f.max_lines), float(max_width) };
    const bits: u64 = @bitCast(env.functions.CallStaticLongMethodA(env, class, methods.measure, &args));
    check();
    return .{ .w = @bitCast(@as(u32, @truncate(bits >> 32))), .h = @bitCast(@as(u32, @truncate(bits))) };
}

/// A Java string of any length as UTF-8, in `buf` (3 bytes per UTF-16 unit is always enough).
fn javaStringLong(s: jni.jstring, buf: []u8) []const u8 {
    const f = env.functions;
    const len: usize = @intCast(f.GetStringLength(env, s));
    const units = zui.allocator.alloc(u16, len) catch return "";
    defer zui.allocator.free(units);
    f.GetStringRegion(env, s, 0, @intCast(len), units.ptr);
    var out: usize = 0;
    var it = std.unicode.Utf16LeIterator.init(units);
    while (it.nextCodepoint() catch null) |cp| {
        const k = std.unicode.utf8CodepointSequenceLength(cp) catch break;
        if (out + k > buf.len) break;
        _ = std.unicode.utf8Encode(cp, buf[out..][0..k]) catch break;
        out += k;
    }
    return buf[0..out];
}

/// A Java string as UTF-8, in `buf` (cut at whole characters when it does not fit).
fn javaString(s: jni.jstring, buf: []u8) []const u8 {
    const f = env.functions;
    const len: usize = @intCast(f.GetStringLength(env, s));
    var units: [1024]u16 = undefined;
    const n = @min(len, units.len);
    f.GetStringRegion(env, s, 0, @intCast(n), &units);
    var out: usize = 0;
    var it = std.unicode.Utf16LeIterator.init(units[0..n]);
    while (it.nextCodepoint() catch null) |cp| {
        const k = std.unicode.utf8CodepointSequenceLength(cp) catch break;
        if (out + k > buf.len) break;
        _ = std.unicode.utf8Encode(cp, buf[out..][0..k]) catch break;
        out += k;
    }
    return buf[0..out];
}

pub fn exportEntry(comptime App: type) void {
    const R = zui.runtime.Runtime(App, @This());
    const Entry = struct {
        fn start(e: *jni.Env, _: jni.jclass, w: f32, h: f32, is_dark: jni.jboolean, top: f32, right: f32, bottom: f32, left: f32, lang: jni.jstring, link: jni.jstring) callconv(.c) void {
            bind(e);
            var buf: [32]u8 = undefined;
            var link_buf: [2048]u8 = undefined;
            const owned = zui.allocator.dupe(u8, if (link != null) javaString(link, &link_buf) else "") catch "";
            R.start(zui.allocator, .{ .width = w, .height = h, .dark = is_dark != 0, .safe = .{ .top = top, .right = right, .bottom = bottom, .left = left }, .link = owned }, javaString(lang, &buf));
        }
        fn resize(e: *jni.Env, _: jni.jclass, w: f32, h: f32) callconv(.c) void {
            bind(e);
            R.resize(w, h);
        }
        fn insets(e: *jni.Env, _: jni.jclass, top: f32, right: f32, bottom: f32, left: f32) callconv(.c) void {
            bind(e);
            R.setInsets(.{ .top = top, .right = right, .bottom = bottom, .left = left });
        }
        fn dark(e: *jni.Env, _: jni.jclass, on: jni.jboolean) callconv(.c) void {
            bind(e);
            R.setDark(on != 0);
        }
        fn event(e: *jni.Env, _: jni.jclass, id: jni.jint, kind: jni.jint) callconv(.c) void {
            bind(e);
            R.event(@intCast(id), std.enums.fromInt(zui.Event, kind) orelse return);
        }
        fn pointerEvent(e: *jni.Env, _: jni.jclass, id: jni.jint, kind: jni.jint, pid: jni.jint, x: f32, y: f32, time_ms: jni.jlong) callconv(.c) void {
            bind(e);
            R.pointerEvent(@intCast(id), .{ .kind = std.enums.fromInt(zui.Pointer.Kind, @as(u8, @intCast(kind))) orelse return, .id = @bitCast(pid), .x = x, .y = y, .time_ms = time_ms });
        }
        fn frame(e: *jni.Env, _: jni.jclass, time_ns: jni.jlong) callconv(.c) void {
            bind(e);
            R.frame(@as(f64, @floatFromInt(time_ns)) / 1e6);
        }
        fn fetchDone(e: *jni.Env, _: jni.jclass, id: jni.jint, status: jni.jint, body: jni.jobject) callconv(.c) void {
            bind(e);
            const f = e.functions;
            const n: usize = if (body != null) @intCast(f.GetArrayLength(e, body)) else 0;
            const buf = zui.allocator.alloc(u8, n) catch return R.fetchDone(@bitCast(id), 0, "");
            defer zui.allocator.free(buf);
            if (n > 0) f.GetByteArrayRegion(e, body, 0, @intCast(n), buf.ptr);
            R.fetchDone(@bitCast(id), @intCast(@max(0, @min(status, 999))), buf);
        }
        fn timerDone(e: *jni.Env, _: jni.jclass, id: jni.jint) callconv(.c) void {
            bind(e);
            R.timerDone(@bitCast(id));
        }
        fn locationFix(e: *jni.Env, _: jni.jclass, lat: f64, lng: f64, accuracy: f32, heading: f32, speed: f32) callconv(.c) void {
            bind(e);
            R.locationEvent(.{ .fix = .{
                .lat = lat,
                .lng = lng,
                .accuracy = accuracy,
                .heading = if (std.math.isNan(heading)) null else heading,
                .speed = if (std.math.isNan(speed)) null else speed,
            } });
        }
        fn locationError(e: *jni.Env, _: jni.jclass, denied: jni.jboolean) callconv(.c) void {
            bind(e);
            R.locationEvent(if (denied != 0) .denied else .unavailable);
        }
        fn socketEvent(e: *jni.Env, _: jni.jclass, id: jni.jint, kind: jni.jint, data: jni.jstring) callconv(.c) void {
            bind(e);
            const k = std.enums.fromInt(zui.SocketEvent.Kind, @as(u8, @intCast(kind))) orelse return;
            if (data == null) return R.socketEvent(@bitCast(id), k, "");
            // Messages can be long: the whole text, not a fixed buffer.
            const f = e.functions;
            const units: usize = @intCast(f.GetStringLength(e, data));
            const buf = zui.allocator.alloc(u8, units * 3 + 1) catch return;
            defer zui.allocator.free(buf);
            R.socketEvent(@bitCast(id), k, javaStringLong(data, buf));
        }
        fn callEvent(e: *jni.Env, _: jni.jclass, kind: jni.jint, id: jni.jstring) callconv(.c) void {
            bind(e);
            var buf: [512]u8 = undefined;
            R.callEvent(std.enums.fromInt(zui.CallEvent.Kind, @as(u8, @intCast(kind))) orelse return, javaString(id, &buf));
        }
        fn inputEvent(e: *jni.Env, _: jni.jclass, id: jni.jint, kind: jni.jint) callconv(.c) void {
            bind(e);
            R.inputEvent(@bitCast(id), std.enums.fromInt(zui.InputEvent, @as(u8, @intCast(kind))) orelse return);
        }
        fn callsPump(e: *jni.Env, _: jni.jclass) callconv(.c) void {
            bind(e);
            R.callsPump();
        }
        fn streamStatus(e: *jni.Env, _: jni.jclass, id: jni.jint, status: jni.jint) callconv(.c) void {
            bind(e);
            R.streamStatus(@bitCast(id), @intCast(@max(0, @min(status, 999))));
        }
        fn streamData(e: *jni.Env, _: jni.jclass, id: jni.jint, data: jni.jobject) callconv(.c) void {
            bind(e);
            const f = e.functions;
            const n: usize = @intCast(f.GetArrayLength(e, data));
            const buf = zui.allocator.alloc(u8, n) catch return;
            defer zui.allocator.free(buf);
            if (n > 0) f.GetByteArrayRegion(e, data, 0, @intCast(n), buf.ptr);
            R.streamData(@bitCast(id), buf);
        }
        fn streamEnd(e: *jni.Env, _: jni.jclass, id: jni.jint) callconv(.c) void {
            bind(e);
            R.streamEnd(@bitCast(id));
        }
        fn fileDone(e: *jni.Env, _: jni.jclass, data: jni.jobject, name: jni.jstring, mime: jni.jstring, w: jni.jint, h: jni.jint) callconv(.c) void {
            bind(e);
            const f = e.functions;
            const n: usize = @intCast(f.GetArrayLength(e, data));
            const buf = zui.allocator.alloc(u8, n) catch return;
            defer zui.allocator.free(buf);
            if (n > 0) f.GetByteArrayRegion(e, data, 0, @intCast(n), buf.ptr);
            var name_buf: [512]u8 = undefined;
            var mime_buf: [128]u8 = undefined;
            R.fileDone(buf, javaString(name, &name_buf), javaString(mime, &mime_buf), @intCast(@max(0, w)), @intCast(@max(0, h)));
        }
        fn recordEvent(e: *jni.Env, _: jni.jclass, id: jni.jint, kind: jni.jint, level_permille: jni.jint, duration_ms: jni.jint, data: jni.jobject, mime: jni.jstring) callconv(.c) void {
            bind(e);
            const f = e.functions;
            const k = std.enums.fromInt(zui.RecordEvent.Kind, @as(u8, @intCast(kind))) orelse return;
            const n: usize = if (data != null) @intCast(f.GetArrayLength(e, data)) else 0;
            const buf = zui.allocator.alloc(u8, n) catch return R.recordEvent(@bitCast(id), .failed, 0, 0, "unavailable", "");
            defer zui.allocator.free(buf);
            if (n > 0) f.GetByteArrayRegion(e, data, 0, @intCast(n), buf.ptr);
            var mime_buf: [64]u8 = undefined;
            R.recordEvent(@bitCast(id), k, @as(f32, @floatFromInt(@max(0, level_permille))) / 1000, @intCast(@max(0, duration_ms)), buf, if (mime != null) javaString(mime, &mime_buf) else "");
        }
        fn playEvent(e: *jni.Env, _: jni.jclass, id: jni.jint, kind: jni.jint, position_ms: jni.jint, duration_ms: jni.jint, reason: jni.jstring) callconv(.c) void {
            bind(e);
            const k = std.enums.fromInt(zui.PlayEvent.Kind, @as(u8, @intCast(kind))) orelse return;
            var buf: [128]u8 = undefined;
            R.playEvent(@bitCast(id), k, @intCast(@max(0, position_ms)), @intCast(@max(0, duration_ms)), if (reason != null) javaString(reason, &buf) else "");
        }
        fn pickDone(e: *jni.Env, _: jni.jclass, value: jni.jstring) callconv(.c) void {
            bind(e);
            var buf: [64]u8 = undefined;
            R.pickDone(javaString(value, &buf));
        }
        fn back(e: *jni.Env, _: jni.jclass) callconv(.c) jni.jboolean {
            bind(e);
            return @intFromBool(R.back());
        }
        fn linkEvent(e: *jni.Env, _: jni.jclass, link: jni.jstring) callconv(.c) void {
            bind(e);
            var buf: [2048]u8 = undefined;
            R.linkEvent(javaString(link, &buf));
        }
        fn deviceEvent(e: *jni.Env, _: jni.jclass, kind: jni.jint) callconv(.c) void {
            bind(e);
            R.deviceEvent(std.enums.fromInt(zui.DeviceEvent, @as(u8, @intCast(kind))) orelse return);
        }
        fn textEvent(e: *jni.Env, _: jni.jclass, id: jni.jint, s: jni.jstring) callconv(.c) void {
            bind(e);
            var buf: [4096]u8 = undefined;
            R.textEvent(@intCast(id), javaString(s, &buf));
        }
    };
    @export(&Entry.start, .{ .name = "Java_com_wufour_zui_Zui_nativeStart" });
    @export(&Entry.resize, .{ .name = "Java_com_wufour_zui_Zui_nativeResize" });
    @export(&Entry.insets, .{ .name = "Java_com_wufour_zui_Zui_nativeInsets" });
    @export(&Entry.dark, .{ .name = "Java_com_wufour_zui_Zui_nativeDark" });
    @export(&Entry.event, .{ .name = "Java_com_wufour_zui_Zui_nativeEvent" });
    @export(&Entry.textEvent, .{ .name = "Java_com_wufour_zui_Zui_nativeText" });
    @export(&Entry.pointerEvent, .{ .name = "Java_com_wufour_zui_Zui_nativePointer" });
    @export(&Entry.frame, .{ .name = "Java_com_wufour_zui_Zui_nativeFrame" });
    @export(&Entry.fetchDone, .{ .name = "Java_com_wufour_zui_Zui_nativeFetchDone" });
    @export(&Entry.timerDone, .{ .name = "Java_com_wufour_zui_Zui_nativeTimer" });
    @export(&Entry.locationFix, .{ .name = "Java_com_wufour_zui_Zui_nativeLocation" });
    @export(&Entry.locationError, .{ .name = "Java_com_wufour_zui_Zui_nativeLocationError" });
    @export(&Entry.inputEvent, .{ .name = "Java_com_wufour_zui_Zui_nativeInput" });
    @export(&Entry.socketEvent, .{ .name = "Java_com_wufour_zui_Zui_nativeSocket" });
    @export(&Entry.callEvent, .{ .name = "Java_com_wufour_zui_Zui_nativeCall" });
    @export(&Entry.callsPump, .{ .name = "Java_com_wufour_zui_Zui_nativeCallsPump" });
    @export(&Entry.back, .{ .name = "Java_com_wufour_zui_ZuiDevice_nativeBack" });
    @export(&Entry.recordEvent, .{ .name = "Java_com_wufour_zui_ZuiRecorder_nativeRecordEvent" });
    @export(&Entry.playEvent, .{ .name = "Java_com_wufour_zui_ZuiPlayer_nativePlayEvent" });
    @export(&Entry.pickDone, .{ .name = "Java_com_wufour_zui_ZuiDevice_nativePickDone" });
    @export(&Entry.fileDone, .{ .name = "Java_com_wufour_zui_ZuiDevice_nativeFileDone" });
    @export(&Entry.streamStatus, .{ .name = "Java_com_wufour_zui_ZuiDevice_nativeStreamStatus" });
    @export(&Entry.streamData, .{ .name = "Java_com_wufour_zui_ZuiDevice_nativeStreamData" });
    @export(&Entry.streamEnd, .{ .name = "Java_com_wufour_zui_ZuiDevice_nativeStreamEnd" });
    @export(&Entry.linkEvent, .{ .name = "Java_com_wufour_zui_ZuiDevice_nativeLink" });
    @export(&Entry.deviceEvent, .{ .name = "Java_com_wufour_zui_ZuiDevice_nativeDevice" });
    exportStyle(R);
    exportScanner(R);
}

extern "log" fn __android_log_write(priority: c_int, tag: [*:0]const u8, text: [*:0]const u8) c_int;

/// To logcat, tag "zui", priority ERROR (6) so it shows with default filters.
pub fn log(line: []const u8) void {
    var buf: [1024]u8 = undefined;
    const n = @min(line.len, buf.len - 1);
    @memcpy(buf[0..n], line[0..n]);
    buf[n] = 0;
    _ = __android_log_write(6, "zui", buf[0..n :0]);
}

pub fn transform(id: u32, t: zui.Transform) void {
    const o = t.origin orelse [2]f32{ 0, 0 };
    call(methods.transform, &.{ int(id), float(t.rotate), float(t.tilt), float(t.perspective), boolean(t.origin != null), float(o[0]), float(o[1]) });
    styleTransformed(id, t.rotate);
}
pub fn clip(id: u32, on: bool) void {
    call(methods.clip, &.{ int(id), boolean(on) });
}
pub fn pointer(id: u32, on: bool) void {
    call(methods.pointer, &.{ int(id), boolean(on) });
}
pub fn image(id: u32, url: []const u8, headers: []const u8) void {
    const js = newString(url);
    defer env.functions.DeleteLocalRef(env, js);
    const jh = newString(headers);
    defer env.functions.DeleteLocalRef(env, jh);
    call(methods.image, &.{ int(id), object(js), object(jh) });
}
pub fn path(id: u32, p: zui.Path) void {
    const f = env.functions;
    const n: jni.jsize = @intCast(p.points.len * 2);
    const arr = f.NewFloatArray(env, n);
    defer f.DeleteLocalRef(env, arr);
    f.SetFloatArrayRegion(env, arr, 0, n, @ptrCast(p.points.ptr));
    call(methods.path, &.{ int(id), object(arr), int(p.color), float(p.width), float(p.dash[0]), float(p.dash[1]), boolean(p.round), int(p.fill) });
}
pub fn fetch(id: u32, method: []const u8, url: []const u8, body: []const u8, content_type: []const u8, headers: []const u8) void {
    const f = env.functions;
    const jh = newString(headers);
    defer f.DeleteLocalRef(env, jh);
    const jm = newString(method);
    defer f.DeleteLocalRef(env, jm);
    const ju = newString(url);
    defer f.DeleteLocalRef(env, ju);
    const jc = newString(content_type);
    defer f.DeleteLocalRef(env, jc);
    const jb = f.NewByteArray(env, @intCast(body.len));
    defer f.DeleteLocalRef(env, jb);
    if (body.len > 0) f.SetByteArrayRegion(env, jb, 0, @intCast(body.len), body.ptr);
    call(methods.fetch, &.{ int(id), object(jm), object(ju), object(jb), object(jc), object(jh) });
}
pub fn storageGet(a: std.mem.Allocator, key: []const u8, secure: bool) ?[]u8 {
    const f = env.functions;
    const jk = newString(key);
    defer f.DeleteLocalRef(env, jk);
    const args = [_]jni.jvalue{ object(jk), boolean(secure) };
    const v = f.CallStaticObjectMethodA(env, class, methods.storage_get, &args);
    check();
    if (v == null) return null;
    defer f.DeleteLocalRef(env, v);
    const buf = a.alloc(u8, 4096) catch return null;
    const s = javaString(v, buf);
    return a.realloc(buf, s.len) catch buf[0..s.len];
}
pub fn storageSet(key: []const u8, value: []const u8, secure: bool) void {
    const jk = newString(key);
    defer env.functions.DeleteLocalRef(env, jk);
    const jv = newString(value);
    defer env.functions.DeleteLocalRef(env, jv);
    call(methods.storage_set, &.{ object(jk), object(jv), boolean(secure) });
}
pub fn storageRemove(key: []const u8, secure: bool) void {
    const jk = newString(key);
    defer env.functions.DeleteLocalRef(env, jk);
    call(methods.storage_remove, &.{ object(jk), boolean(secure) });
}
pub fn timer(id: u32, ms: u32) void {
    call(methods.timer, &.{ int(id), int(ms) });
}
pub fn location(on: bool) void {
    call(methods.location, &.{boolean(on)});
}
pub fn speak(s: []const u8, lang: []const u8) void {
    const js = newString(s);
    defer env.functions.DeleteLocalRef(env, js);
    const jl = newString(lang);
    defer env.functions.DeleteLocalRef(env, jl);
    call(methods.speak, &.{ object(js), object(jl) });
}
pub fn setLink(s: []const u8) void {
    const js = newString(s);
    defer env.functions.DeleteLocalRef(env, js);
    call(methods.set_link, &.{object(js)});
}
pub fn imageFilter(id: u32, f: zui.ImageFilter) void {
    var m = f.matrix();
    for ([_]usize{ 4, 9, 14 }) |i| m[i] *= 255;
    const e = env.functions;
    const arr = e.NewFloatArray(env, 20);
    defer e.DeleteLocalRef(env, arr);
    e.SetFloatArrayRegion(env, arr, 0, 20, &m);
    call(methods.image_filter, &.{ int(id), object(arr) });
}
pub fn copy(s: []const u8) void {
    const js = newString(s);
    defer env.functions.DeleteLocalRef(env, js);
    call(methods.copy, &.{object(js)});
}
pub fn openUrl(url: []const u8, _: bool) void {
    const js = newString(url);
    defer env.functions.DeleteLocalRef(env, js);
    call(methods.open_url, &.{object(js)});
}
pub fn focus(id: u32) void {
    call(methods.focus, &.{int(id)});
}
pub fn requestFrame() void {
    call(methods.request_frame, &.{});
}

/// There is no embedding page on a phone.
pub fn post(_: []const u8) void {}

pub fn notify(n: zui.Notification) void {
    const jt = newString(n.title);
    defer env.functions.DeleteLocalRef(env, jt);
    const jb = newString(n.body);
    defer env.functions.DeleteLocalRef(env, jb);
    call(methods.notify, &.{ int(n.id), object(jt), object(jb), boolean(n.urgent) });
}
pub fn cancelNotify(id: u32) void {
    call(methods.cancel_notify, &.{int(id)});
}
pub fn ringCall(c: zui.Call) void {
    callWith(methods.ring_call, c);
}
pub fn startCall(c: zui.Call) void {
    callWith(methods.start_call, c);
}
fn callWith(m: jni.jmethodID, c: zui.Call) void {
    const ji = newString(c.id);
    defer env.functions.DeleteLocalRef(env, ji);
    const jn = newString(c.name);
    defer env.functions.DeleteLocalRef(env, jn);
    call(m, &.{ object(ji), object(jn), boolean(c.video) });
}
pub fn callConnected(id: []const u8) void {
    const ji = newString(id);
    defer env.functions.DeleteLocalRef(env, ji);
    call(methods.call_connected, &.{object(ji)});
}
pub fn endCall(id: []const u8) void {
    const ji = newString(id);
    defer env.functions.DeleteLocalRef(env, ji);
    call(methods.end_call, &.{object(ji)});
}
pub fn widgetUpdate(title: []const u8, l1: []const u8, l2: []const u8, l3: []const u8) void {
    const f = env.functions;
    var refs: [4]jni.jstring = undefined;
    for ([_][]const u8{ title, l1, l2, l3 }, &refs) |s, *r| r.* = newString(s);
    defer for (refs) |r| f.DeleteLocalRef(env, r);
    call(methods.widget_update, &.{ object(refs[0]), object(refs[1]), object(refs[2]), object(refs[3]) });
}
pub fn backgroundLocation(on: bool, title: []const u8, text_: []const u8) void {
    const jt = newString(title);
    defer env.functions.DeleteLocalRef(env, jt);
    const jx = newString(text_);
    defer env.functions.DeleteLocalRef(env, jx);
    call(methods.background_location, &.{ boolean(on), object(jt), object(jx) });
}

/// WebSockets: ZuiSocket.java (RFC 6455 over the platform's sockets and TLS).
pub fn openSocket(id: u32, url: []const u8) void {
    const js = newString(url);
    defer env.functions.DeleteLocalRef(env, js);
    call(methods.open_socket, &.{ int(id), object(js) });
}
pub fn sendSocket(id: u32, message: []const u8) void {
    const js = newString(message);
    defer env.functions.DeleteLocalRef(env, js);
    call(methods.send_socket, &.{ int(id), object(js) });
}
/// A video view shows a stream: the camera's preview, or a remote decoder's output.
pub fn video(id: u32, v: zui.Video) void {
    if (scannerShown(id, v.stream)) return;
    call(methods.video, &.{ int(id), int(v.stream), boolean(v.mirror), boolean(v.cover) });
}

pub fn closeSocket(id: u32) void {
    call(methods.close_socket, &.{int(id)});
}

extern "c" fn arc4random_buf(buf: [*]u8, len: usize) void;

/// The system's CSPRNG (the key store's randomness).
pub fn randomBytes(buf: []u8) void {
    arc4random_buf(buf.ptr, buf.len);
}

// ---- Styling and interaction (ZuiStyle.java): rich text, pictures from memory, decorations,
// transitions, spinners, scroll control, the haptic tick of a long press ----

var style_class: jni.jclass = null;
var style_m: struct {
    rich_text: jni.jmethodID,
    measure_rich: jni.jmethodID,
    image_bytes: jni.jmethodID,
    image_fit: jni.jmethodID,
    decor: jni.jmethodID,
    transition: jni.jmethodID,
    frame: jni.jmethodID,
    alpha_to: jni.jmethodID,
    rotate_from: jni.jmethodID,
    spin: jni.jmethodID,
    haptic: jni.jmethodID,
    watch_scroll: jni.jmethodID,
    radius: jni.jmethodID,
    scroll_to: jni.jmethodID,
} = undefined;

fn styleBind() void {
    if (style_class != null) return;
    const f = env.functions;
    const local = f.FindClass(env, "com/wufour/zui/ZuiStyle");
    style_class = f.NewGlobalRef(env, local);
    f.DeleteLocalRef(env, local);
    inline for (.{
        .{ "rich_text", "richText", "(ILjava/lang/String;[IFIFZIIIFZ)V" },
        .{ "measure_rich", "measureRich", "(Ljava/lang/String;[IFIFZIFF)J" },
        .{ "image_bytes", "imageBytes", "(ILjava/lang/String;[B)V" },
        .{ "image_fit", "imageFit", "(II)V" },
        .{ "decor", "decor", "(II[F[I)V" },
        .{ "transition", "transition", "(IIFFFF)V" },
        .{ "frame", "frame", "(IFFFF)Z" },
        .{ "alpha_to", "alphaTo", "(IF)V" },
        .{ "rotate_from", "rotateFrom", "(IF)V" },
        .{ "spin", "spin", "(II)V" },
        .{ "haptic", "haptic", "()V" },
        .{ "watch_scroll", "watchScroll", "(I)V" },
        .{ "scroll_to", "scrollTo", "(IFZ)V" },
        .{ "radius", "radius", "(IF)V" },
    }) |m| @field(style_m, m[0]) = f.GetStaticMethodID(env, style_class, m[1], m[2]);
}

fn callStyle(method: jni.jmethodID, args: []const jni.jvalue) void {
    env.functions.CallStaticVoidMethodA(env, style_class, method, args.ptr);
    check();
}

/// Per view: 1 selectable text, 2 animated (a transition); and the last rotation of animated views.
var style_flags: std.ArrayList(u8) = .empty;
var style_rotation: std.AutoHashMapUnmanaged(u32, f32) = .empty;
var dummy_flag: u8 = 0;

fn flagsOf(id: u32) *u8 {
    while (style_flags.items.len <= id) style_flags.append(zui.allocator, 0) catch return &dummy_flag;
    return &style_flags.items[id];
}

fn isSelectable(id: u32) bool {
    return flagsOf(id).* & 1 != 0;
}

fn styleCreated(id: u32, kind: zui.tree.Kind) void {
    styleBind();
    flagsOf(id).* = if (kind == .text_select) 1 else 0;
    _ = style_rotation.remove(id);
    if (kind == .scroll or kind == .scroll_x) callStyle(style_m.watch_scroll, &.{int(id)});
}

fn animatedFrame(id: u32, r: zui.Rect) bool {
    if (flagsOf(id).* & 2 == 0) return false;
    const args = [_]jni.jvalue{ int(id), float(r.x), float(r.y), float(r.w), float(r.h) };
    const done = env.functions.CallStaticBooleanMethodA(env, style_class, style_m.frame, &args);
    check();
    return done != 0;
}

fn styleBox(id: u32, b: zui.Box) void {
    if (!b.isSimple()) {
        const d = b.decor;
        var stop_colors: [64]u32 = undefined;
        var stop_at: [64]f32 = undefined;
        const n = d.blendedStops(&stop_colors, &stop_at);
        var fl: [12 + 64]f32 = undefined;
        @memcpy(fl[0..4], &d.radii);
        @memcpy(fl[4..8], &d.border_widths);
        @memcpy(fl[8..11], &d.shadow);
        fl[11] = d.gradient_angle;
        @memcpy(fl[12..][0..n], stop_at[0..n]);
        var cs: [5 + 64]u32 = undefined;
        @memcpy(cs[0..4], &d.border_colors);
        cs[4] = d.shadow_color;
        @memcpy(cs[5..][0..n], stop_colors[0..n]);
        const f = env.functions;
        const jf = f.NewFloatArray(env, @intCast(12 + n));
        defer f.DeleteLocalRef(env, jf);
        f.SetFloatArrayRegion(env, jf, 0, @intCast(12 + n), &fl);
        const jc = f.NewIntArray(env, @intCast(5 + n));
        defer f.DeleteLocalRef(env, jc);
        f.SetIntArrayRegion(env, jc, 0, @intCast(5 + n), @ptrCast(&cs));
        callStyle(style_m.decor, &.{ int(id), int(b.background), object(jf), object(jc) });
    }
    callStyle(style_m.radius, &.{ int(id), float(b.radius) });
    if (flagsOf(id).* & 2 != 0) callStyle(style_m.alpha_to, &.{ int(id), float(b.opacity) });
}

fn styleTransformed(id: u32, rotate: f32) void {
    if (flagsOf(id).* & 2 == 0) return;
    const was = style_rotation.get(id) orelse rotate;
    style_rotation.put(zui.allocator, id, rotate) catch {};
    if (was != rotate) callStyle(style_m.rotate_from, &.{ int(id), float(was) });
}

/// Spans as Java wants them: 5 ints each, offsets in UTF-16 units.
fn spanInts(s: []const u8, spans: []const zui.Span) jni.jobject {
    const f = env.functions;
    const ints = zui.allocator.alloc(i32, spans.len * 5) catch return f.NewIntArray(env, 0);
    defer zui.allocator.free(ints);
    for (spans, 0..) |sp, k| {
        const a = @min(s.len, sp.start);
        const b = @min(s.len, sp.start + sp.len);
        const flags: i32 = @as(i32, @intFromBool(sp.bold)) | @as(i32, @intFromBool(sp.italic)) << 1 | @as(i32, @intFromBool(sp.mono)) << 2 | @as(i32, @intFromBool(sp.underline)) << 3 | @as(i32, @intFromBool(sp.strike)) << 4;
        ints[k * 5 ..][0..5].* = .{ utf16Len(s[0..a]), utf16Len(s[0..b]), flags, @bitCast(sp.color), sp.link };
    }
    const arr = f.NewIntArray(env, @intCast(ints.len));
    if (ints.len > 0) f.SetIntArrayRegion(env, arr, 0, @intCast(ints.len), ints.ptr);
    return arr;
}

fn utf16Len(s: []const u8) i32 {
    return @intCast(std.unicode.calcUtf16LeLen(s) catch s.len);
}

pub fn richText(id: u32, s: []const u8, spans: []const zui.Span, f: zui.Font, color: u32, a: zui.PhysicalAlign) void {
    const js = newString(s);
    defer env.functions.DeleteLocalRef(env, js);
    const arr = spanInts(s, spans);
    defer env.functions.DeleteLocalRef(env, arr);
    callStyle(style_m.rich_text, &.{ int(id), object(js), object(arr), float(f.size), int(f.weight), float(f.line_height), boolean(f.mono), int(f.max_lines), int(color), int(@backingInt(a)), float(f.letter_spacing), boolean(isSelectable(id)) });
}

pub fn measureRich(s: []const u8, spans: []const zui.Span, f: zui.Font, max_width: f32) zui.Size {
    styleBind();
    const js = newString(s);
    defer env.functions.DeleteLocalRef(env, js);
    const arr = spanInts(s, spans);
    defer env.functions.DeleteLocalRef(env, arr);
    const args = [_]jni.jvalue{ object(js), object(arr), float(f.size), int(f.weight), float(f.line_height), boolean(f.mono), int(f.max_lines), float(max_width), float(f.letter_spacing) };
    const bits: u64 = @bitCast(env.functions.CallStaticLongMethodA(env, style_class, style_m.measure_rich, &args));
    check();
    return .{ .w = @bitCast(@as(u32, @truncate(bits >> 32))), .h = @bitCast(@as(u32, @truncate(bits))) };
}

/// Long press and the context menu are timed in zui; a phone has no mouse to hover.
pub fn gestures(_: u32, _: zui.Gestures) void {}

pub fn imageBytes(id: u32, key: []const u8, bytes: []const u8) void {
    const f = env.functions;
    const jk = newString(key);
    defer f.DeleteLocalRef(env, jk);
    const jb = f.NewByteArray(env, @intCast(bytes.len));
    defer f.DeleteLocalRef(env, jb);
    if (bytes.len > 0) f.SetByteArrayRegion(env, jb, 0, @intCast(bytes.len), bytes.ptr);
    callStyle(style_m.image_bytes, &.{ int(id), object(jk), object(jb) });
}
pub fn imageFit(id: u32, fit: zui.Fit) void {
    callStyle(style_m.image_fit, &.{ int(id), int(@intFromEnum(fit)) });
}
pub fn transition(id: u32, t: ?zui.Transition) void {
    const fl = flagsOf(id);
    if (t) |tr| {
        fl.* |= 2;
        const p = tr.easing.controlPoints();
        callStyle(style_m.transition, &.{ int(id), int(tr.duration_ms), float(p[0]), float(p[1]), float(p[2]), float(p[3]) });
    } else {
        fl.* &= ~@as(u8, 2);
        callStyle(style_m.transition, &.{ int(id), int(0), float(0), float(0), float(1), float(1) });
    }
}
pub fn spin(id: u32, period_ms: u16) void {
    callStyle(style_m.spin, &.{ int(id), int(period_ms) });
}
pub fn haptic() void {
    callStyle(style_m.haptic, &.{});
}
pub fn scrollTo(id: u32, offset: f32, animated: bool) void {
    callStyle(style_m.scroll_to, &.{ int(id), float(offset), boolean(animated) });
}

fn exportStyle(comptime R: type) void {
    const Entry = struct {
        fn spanPress(e: *jni.Env, _: jni.jclass, id: jni.jint, index: jni.jint) callconv(.c) void {
            bind(e);
            R.spanPress(@bitCast(id), @bitCast(index));
        }
        fn scroll(e: *jni.Env, _: jni.jclass, id: jni.jint, offset: f32) callconv(.c) void {
            bind(e);
            R.scrollEvent(@bitCast(id), offset);
        }
    };
    @export(&Entry.spanPress, .{ .name = "Java_com_wufour_zui_ZuiStyle_nativeSpan" });
    @export(&Entry.scroll, .{ .name = "Java_com_wufour_zui_ZuiStyle_nativeScroll" });
}
// ---- Secure keys: the AndroidKeyStore (zui/keys.zig's hardware hook) ----
// EC keys go into the Keystore: signing everywhere, key agreement from Android 12. Where it says
// no, zui's engine keeps the key (encrypted at rest with a Keystore AES key).

fn byteArray(bytes: []const u8) jni.jobject {
    const f = env.functions;
    const arr = f.NewByteArray(env, @intCast(bytes.len));
    if (bytes.len > 0) f.SetByteArrayRegion(env, arr, 0, @intCast(bytes.len), bytes.ptr);
    return arr;
}

/// A byte[] answer of exactly N bytes, or null.
fn callBytes(comptime N: usize, method: jni.jmethodID, args: []const jni.jvalue) ?[N]u8 {
    const f = env.functions;
    const r = f.CallStaticObjectMethodA(env, device_class, method, args.ptr);
    check();
    if (r == null) return null;
    defer f.DeleteLocalRef(env, r);
    if (f.GetArrayLength(env, r) != N) return null;
    var out: [N]u8 = undefined;
    f.GetByteArrayRegion(env, r, 0, N, &out);
    return out;
}

fn alias(name: []const u8) jni.jstring {
    var buf: [300]u8 = undefined;
    return newString(std.fmt.bufPrint(&buf, "zui:{s}", .{name}) catch name);
}

pub const KeyHw = struct {
    const pkcs8_head = [_]u8{ 0x30, 0x81, 0x87, 0x02, 0x01, 0x00, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x04, 0x6d, 0x30, 0x6b, 0x02, 0x01, 0x01, 0x04, 0x20 };
    const pkcs8_mid = [_]u8{ 0xa1, 0x44, 0x03, 0x42, 0x00 };

    pub fn import(_: std.mem.Allocator, name: []const u8, kind: zui.keys.Kind, secret: [32]u8, public: [65]u8) bool {
        var der: [138]u8 = undefined;
        @memcpy(der[0..36], &pkcs8_head);
        @memcpy(der[36..68], &secret);
        @memcpy(der[68..73], &pkcs8_mid);
        @memcpy(der[73..138], &public);
        defer std.crypto.secureZero(u8, &der);
        const f = env.functions;
        const ja = alias(name);
        defer f.DeleteLocalRef(env, ja);
        const jd = byteArray(&der);
        defer f.DeleteLocalRef(env, jd);
        const jp = byteArray(&public);
        defer f.DeleteLocalRef(env, jp);
        return callBytes(65, device.key_import, &.{ object(ja), int(@intFromEnum(kind)), object(jd), object(jp) }) != null;
    }

    pub fn generate(_: std.mem.Allocator, name: []const u8, kind: zui.keys.Kind) ?[65]u8 {
        const ja = alias(name);
        defer env.functions.DeleteLocalRef(env, ja);
        return callBytes(65, device.key_generate, &.{ object(ja), int(@intFromEnum(kind)) });
    }

    pub fn sign(_: std.mem.Allocator, name: []const u8, data: []const u8) ?[64]u8 {
        const f = env.functions;
        const ja = alias(name);
        defer f.DeleteLocalRef(env, ja);
        const jd = byteArray(data);
        defer f.DeleteLocalRef(env, jd);
        return callBytes(64, device.key_sign, &.{ object(ja), object(jd) });
    }

    pub fn ecdh(_: std.mem.Allocator, name: []const u8, peer: []const u8) ?[32]u8 {
        const f = env.functions;
        const ja = alias(name);
        defer f.DeleteLocalRef(env, ja);
        const jp = byteArray(peer);
        defer f.DeleteLocalRef(env, jp);
        return callBytes(32, device.key_ecdh, &.{ object(ja), object(jp) });
    }

    pub fn delete(name: []const u8) void {
        const ja = alias(name);
        defer env.functions.DeleteLocalRef(env, ja);
        callDevice(device.key_delete, &.{object(ja)});
    }
};

// ---- Barcode scanners (ZuiScanner.java): Camera2 frames decoded by zui.barcode on the camera
// thread ----

var scanner_class: jni.jclass = null;
var scanner_m: struct { open: jni.jmethodID, close: jni.jmethodID, attach: jni.jmethodID } = undefined;
var scanner_ids: std.AutoHashMapUnmanaged(u32, void) = .empty;

fn scannerBind() void {
    if (scanner_class != null) return;
    const f = env.functions;
    const local = f.FindClass(env, "com/wufour/zui/ZuiScanner");
    scanner_class = f.NewGlobalRef(env, local);
    f.DeleteLocalRef(env, local);
    scanner_m = .{
        .open = f.GetStaticMethodID(env, scanner_class, "open", "(IIZ)V"),
        .close = f.GetStaticMethodID(env, scanner_class, "close", "(I)V"),
        .attach = f.GetStaticMethodID(env, scanner_class, "attach", "(II)V"),
    };
}

fn callScanner(method: jni.jmethodID, args: []const jni.jvalue) void {
    env.functions.CallStaticVoidMethodA(env, scanner_class, method, args.ptr);
    check();
}

pub fn scanOpen(id: u32, formats: zui.barcode.Formats, back: bool) void {
    scannerBind();
    scanner_ids.put(zui.allocator, id, {}) catch {};
    callScanner(scanner_m.open, &.{ int(id), int(@as(u8, @bitCast(formats))), boolean(back) });
}

pub fn scanClose(id: u32) void {
    scannerBind();
    _ = scanner_ids.remove(id);
    callScanner(scanner_m.close, &.{int(id)});
}

/// A video view showing a scanner gets its camera picture.
fn scannerShown(view_id: u32, stream: u32) bool {
    if (!scanner_ids.contains(stream)) return false;
    callScanner(scanner_m.attach, &.{ int(view_id), int(stream) });
    return true;
}

fn exportScanner(comptime R: type) void {
    const Entry = struct {
        /// On the camera thread: only its own JNI environment, and zui.barcode, are used.
        fn decode(e: *jni.Env, _: jni.jclass, y: jni.jobject, w: jni.jint, h: jni.jint, formats: jni.jint) callconv(.c) jni.jstring {
            const f = e.functions;
            const n: usize = @intCast(f.GetArrayLength(e, y));
            const width: usize = @intCast(w);
            const height: usize = @intCast(h);
            if (n < width * height or width == 0) return null;
            const px = zui.allocator.alloc(u8, n) catch return null;
            defer zui.allocator.free(px);
            f.GetByteArrayRegion(e, y, 0, @intCast(n), px.ptr);
            const r = (zui.barcode.decode(zui.allocator, .{ .width = width, .height = height, .pixels = px }, @bitCast(@as(u8, @truncate(@as(u32, @bitCast(formats)))))) catch return null) orelse return null;
            defer zui.allocator.free(r.text);
            const out = std.fmt.allocPrintSentinel(zui.allocator, "{d}\t{s}", .{ @intFromEnum(r.format), r.text }, 0) catch return null;
            defer zui.allocator.free(out);
            return f.NewStringUTF(e, out.ptr);
        }
        fn scan(e: *jni.Env, _: jni.jclass, id: jni.jint, kind: jni.jint, format: jni.jint, jtext: jni.jstring) callconv(.c) void {
            bind(e);
            const sid: u32 = @bitCast(id);
            const k = std.enums.fromInt(zui.ScanEvent.Kind, @as(u8, @intCast(kind))) orelse return;
            const f = e.functions;
            const units: usize = if (jtext != null) @intCast(f.GetStringLength(e, jtext)) else 0;
            const buf = zui.allocator.alloc(u8, units * 3 + 1) catch return;
            defer zui.allocator.free(buf);
            const t = if (jtext != null) javaStringLong(jtext, buf) else "";
            if (k == .failed) _ = scanner_ids.remove(sid);
            if (k == .found) {
                R.scanFound(sid, std.enums.fromInt(zui.barcode.Format, @as(u8, @intCast(format))) orelse return, t);
            } else R.scanState(sid, k, t);
        }
    };
    @export(&Entry.decode, .{ .name = "Java_com_wufour_zui_ZuiScanner_nativeDecode" });
    @export(&Entry.scan, .{ .name = "Java_com_wufour_zui_ZuiScanner_nativeScan" });
}
