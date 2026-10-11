//! zui: one UI codebase that shows real native views on the web (DOM), Android
//! (android.view.View) and iOS (UIView). zui computes every frame itself; the platforms only
//! measure text and draw what they are told, so the layout is the same everywhere.
//!
//! See `runtime.zig` for the shape of an app.

const std = @import("std");
const builtin = @import("builtin");

pub const color = @import("color.zig");
pub const i18n = @import("i18n.zig");
pub const layout = @import("layout.zig");
pub const tree = @import("tree.zig");
pub const reconcile = @import("reconcile.zig");
pub const runtime = @import("runtime.zig");
const style = @import("style.zig");

pub const Color = color.Color;
pub const Oklch = color.Oklch;
pub const Adaptive = color.Adaptive;
pub const Style = style.Style;
pub const Edges = style.Edges;
pub const Inset = style.Inset;
pub const Dim = style.Dim;
pub const Rect = style.Rect;
pub const Size = style.Size;
pub const Font = style.Font;
pub const Box = style.Box;
pub const PhysicalAlign = style.PhysicalAlign;
pub const Env = runtime.Env;
pub const Insets = runtime.Insets;
pub const Event = runtime.Event;
pub const Pointer = runtime.Pointer;
pub const Fx = runtime.Fx;
pub const storage = @import("storage.zig");
pub const icon = @import("icon.zig");
pub const Icon = icon.Icon;
pub const Request = runtime.Request;
pub const Response = runtime.Response;
pub const Location = runtime.Location;
pub const Method = runtime.Method;
pub const InputEvent = runtime.InputEvent;
pub const SocketEvent = runtime.SocketEvent;
pub const Transform = style.Transform;
pub const ImageFilter = style.ImageFilter;
pub const Path = tree.Path;
pub const Ui = runtime.Ui;
pub const key = runtime.key;

pub const Platform = enum { web, android, ios, headless };

pub const platform: Platform = if (builtin.target.cpu.arch.isWasm())
    .web
else if (builtin.target.abi.isAndroid())
    .android
else if (builtin.target.os.tag == .ios)
    .ios
else
    .headless;

/// The host that turns zui operations into native views for the target being compiled.
pub const host = switch (platform) {
    .web => @import("host/web.zig"),
    .android => @import("host/android.zig"),
    .ios => @import("host/ios.zig"),
    .headless => @import("host/headless.zig"),
};

/// General-purpose memory for the platform.
pub const allocator: std.mem.Allocator = if (builtin.target.cpu.arch.isWasm())
    std.heap.wasm_allocator
else if (builtin.link_libc)
    std.heap.c_allocator
else
    std.heap.page_allocator;

/// Exports the platform entry points for `App`. Call it once from the app's client root:
/// `comptime { zui.exportApp(@This()); }`
pub fn exportApp(comptime App: type) void {
    host.exportEntry(App);
}

test {
    _ = color;
    _ = i18n;
    _ = layout;
    _ = tree;
    _ = reconcile;
    _ = host;
    _ = icon;
}

/// Writes a line to the platform's log: logcat on Android, stderr (the device log) on iOS,
/// the browser console on the web, stderr on the build machine.
pub fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    host.log(line);
}

/// Panic handler that reaches the platform log. Apps declare `pub const panic = zui.panic;` in
/// their client root. (On iOS this also avoids zig 0.17's default handler, which does not
/// compile for that target.)
pub const panic = if (platform == .headless) std.debug.FullPanic(std.debug.defaultPanic) else std.debug.FullPanic(panicToLog);

fn panicToLog(msg: []const u8, _: ?usize) noreturn {
    @branchHint(.cold);
    host.log("zui panic:");
    host.log(msg);
    @trap();
}
