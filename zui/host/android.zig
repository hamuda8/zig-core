//! Android host: drives the generic view primitives in `shells/android/.../Zui.java` through
//! JNI. Every view is a real android.view.View; zui decides which views exist, where they are
//! and what they show.

const std = @import("std");
const zui = @import("../zui.zig");
const jni = @import("../platform/jni.zig");

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
} = undefined;

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
        .{ "image", "image", "(ILjava/lang/String;)V" },
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
        .{ "timer", "timer", "(II)V" },
        .{ "location", "location", "(Z)V" },
        .{ "speak", "speak", "(Ljava/lang/String;Ljava/lang/String;)V" },
        .{ "set_link", "setLink", "(Ljava/lang/String;)V" },
        .{ "focus", "focus", "(I)V" },
        .{ "image_filter", "imageFilter", "(I[F)V" },
        .{ "copy", "copy", "(Ljava/lang/String;)V" },
        .{ "open_url", "openUrl", "(Ljava/lang/String;)V" },
    }) |m| @field(methods, m[0]) = f.GetStaticMethodID(e, class, m[1], m[2]);
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
}
pub fn destroy(id: u32) void {
    call(methods.destroy, &.{int(id)});
}
pub fn insert(parent: u32, id: u32, index: u32) void {
    call(methods.insert, &.{ int(parent), int(id), int(index) });
}
pub fn frame(id: u32, r: zui.Rect) void {
    call(methods.frame, &.{ int(id), float(r.x), float(r.y), float(r.w), float(r.h) });
}
pub fn box(id: u32, b: zui.Box) void {
    call(methods.box, &.{ int(id), int(b.background), float(b.radius), float(b.border_width), int(b.border_color), float(b.opacity) });
}
pub fn pressable(id: u32, on: bool) void {
    call(methods.pressable, &.{ int(id), boolean(on) });
}
pub fn text(id: u32, s: []const u8, f: zui.Font, color: u32, a: zui.PhysicalAlign) void {
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
}
pub fn clip(id: u32, on: bool) void {
    call(methods.clip, &.{ int(id), boolean(on) });
}
pub fn pointer(id: u32, on: bool) void {
    call(methods.pointer, &.{ int(id), boolean(on) });
}
pub fn image(id: u32, url: []const u8) void {
    const js = newString(url);
    defer env.functions.DeleteLocalRef(env, js);
    call(methods.image, &.{ int(id), object(js) });
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
pub fn closeSocket(id: u32) void {
    call(methods.close_socket, &.{int(id)});
}
