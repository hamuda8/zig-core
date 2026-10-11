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
    measure: jni.jmethodID,
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
        .{ "measure", "measure", "(Ljava/lang/String;FIFZIF)J" },
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
        fn start(e: *jni.Env, _: jni.jclass, w: f32, h: f32, is_dark: jni.jboolean, top: f32, right: f32, bottom: f32, left: f32, lang: jni.jstring) callconv(.c) void {
            bind(e);
            var buf: [32]u8 = undefined;
            R.start(zui.allocator, .{ .width = w, .height = h, .dark = is_dark != 0, .safe = .{ .top = top, .right = right, .bottom = bottom, .left = left } }, javaString(lang, &buf));
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
