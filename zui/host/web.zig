//! Web host: the wasm module calls into `shells/web/zui.js`, which creates the DOM elements.

const zui = @import("../zui.zig");

extern "zui" fn zui_show_text(ptr: [*]const u8, len: usize) void;

pub const Context = struct {};

pub fn showText(_: *Context, s: []const u8) void {
    zui_show_text(s.ptr, s.len);
}

pub fn exportEntry(comptime app: zui.App) void {
    const Entry = struct {
        var ctx: Context = .{};

        fn start() callconv(.c) void {
            var ui: zui.Ui = .{ .ctx = &ctx };
            app.start(&ui);
        }
    };
    @export(&Entry.start, .{ .name = "zui_start" });
}
