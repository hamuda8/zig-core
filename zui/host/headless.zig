//! Headless host for the build machine: records what would be shown, for tests and tools.

const std = @import("std");
const zui = @import("../zui.zig");

pub const Context = struct {
    buf: [256]u8 = undefined,
    shown: []const u8 = "",
};

pub fn showText(ctx: *Context, s: []const u8) void {
    const n = @min(s.len, ctx.buf.len);
    @memcpy(ctx.buf[0..n], s[0..n]);
    ctx.shown = ctx.buf[0..n];
}

pub fn exportEntry(comptime app: zui.App) void {
    _ = app;
}

test "headless host records the text" {
    var ctx: Context = .{};
    var ui: zui.Ui = .{ .ctx = &ctx };
    ui.text("Wufour");
    try std.testing.expectEqualStrings("Wufour", ctx.shown);
}
