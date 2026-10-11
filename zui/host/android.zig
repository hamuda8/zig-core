//! Android host: creates android.view.View objects directly through JNI.
//! The only Java is the fixed shim `shells/android/java/com/wufour/zui/ZuiActivity.java`.

const std = @import("std");
const zui = @import("../zui.zig");
const jni = @import("../platform/jni.zig");

pub const Context = struct {
    env: *jni.Env,
    activity: jni.jobject,
};

/// Gravity.CENTER
const gravity_center: jni.jint = 17;

pub fn showText(ctx: *Context, s: []const u8) void {
    const env = ctx.env;
    const f = env.functions;

    const text_view_class = f.FindClass(env, "android/widget/TextView");
    defer f.DeleteLocalRef(env, text_view_class);
    const init = f.GetMethodID(env, text_view_class, "<init>", "(Landroid/content/Context;)V");
    const view = f.NewObjectA(env, text_view_class, init, &[_]jni.jvalue{.{ .l = ctx.activity }});
    defer f.DeleteLocalRef(env, view);

    const str = newString(env, s);
    defer f.DeleteLocalRef(env, str);
    callVoid(env, view, text_view_class, "setText", "(Ljava/lang/CharSequence;)V", &.{.{ .l = str }});
    callVoid(env, view, text_view_class, "setTextSize", "(F)V", &.{.{ .f = 24 }});
    callVoid(env, view, text_view_class, "setGravity", "(I)V", &.{.{ .i = gravity_center }});

    const activity_class = f.GetObjectClass(env, ctx.activity);
    defer f.DeleteLocalRef(env, activity_class);
    callVoid(env, ctx.activity, activity_class, "setContentView", "(Landroid/view/View;)V", &.{.{ .l = view }});
}

fn callVoid(env: *jni.Env, obj: jni.jobject, class: jni.jclass, name: [*:0]const u8, sig: [*:0]const u8, args: []const jni.jvalue) void {
    const f = env.functions;
    const method = f.GetMethodID(env, class, name, sig);
    if (method == null) return clearException(env);
    f.CallVoidMethodA(env, obj, method, args.ptr);
    clearException(env);
}

fn clearException(env: *jni.Env) void {
    const f = env.functions;
    if (f.ExceptionCheck(env) == jni.JNI_TRUE) {
        f.ExceptionDescribe(env);
        f.ExceptionClear(env);
    }
}

/// Java strings are UTF-16. Going through `NewString` keeps characters outside the BMP (emoji)
/// intact, which `NewStringUTF`'s modified UTF-8 would not.
fn newString(env: *jni.Env, s: []const u8) jni.jstring {
    const f = env.functions;
    var stack: [512]u16 = undefined;
    const len = std.unicode.calcUtf16LeLen(s) catch return f.NewString(env, &stack, 0);
    if (len <= stack.len) {
        const n = std.unicode.utf8ToUtf16Le(&stack, s) catch 0;
        return f.NewString(env, &stack, @intCast(n));
    }
    const heap = std.heap.page_allocator.alloc(u16, len) catch return f.NewString(env, &stack, 0);
    defer std.heap.page_allocator.free(heap);
    const n = std.unicode.utf8ToUtf16Le(heap, s) catch 0;
    return f.NewString(env, heap.ptr, @intCast(n));
}

pub fn exportEntry(comptime app: zui.App) void {
    const Entry = struct {
        fn nativeStart(env: *jni.Env, _: jni.jclass, activity: jni.jobject) callconv(.c) void {
            var ctx: Context = .{ .env = env, .activity = activity };
            var ui: zui.Ui = .{ .ctx = &ctx };
            app.start(&ui);
        }
    };
    @export(&Entry.nativeStart, .{ .name = "Java_com_wufour_zui_ZuiActivity_nativeStart" });
}
