//! zui: one UI codebase that shows real native views on the web (DOM), Android (android.view.View)
//! and iOS (UIView).
//!
//! Step 0 (toolchain spike): an app can show one line of text on every platform. Step 1 replaces
//! `Ui` with the view tree, the layout engine and the widgets.

const std = @import("std");
const builtin = @import("builtin");

pub const Platform = enum { web, android, ios, headless };

pub const platform: Platform = if (builtin.target.cpu.arch.isWasm())
    .web
else if (builtin.target.abi.isAndroid())
    .android
else if (builtin.target.os.tag == .ios)
    .ios
else
    .headless;

/// The host that turns zui calls into native views for the target being compiled.
pub const host = switch (platform) {
    .web => @import("host/web.zig"),
    .android => @import("host/android.zig"),
    .ios => @import("host/ios.zig"),
    .headless => @import("host/headless.zig"),
};

/// What an app hands to zui.
pub const App = struct {
    /// Display name, also used as the window title on the web.
    name: [:0]const u8,
    /// Called once the host is ready to show views.
    start: *const fn (ui: *Ui) void,
};

/// The surface an app draws into.
pub const Ui = struct {
    ctx: *host.Context,

    pub fn text(ui: *Ui, s: []const u8) void {
        host.showText(ui.ctx, s);
    }
};

/// Exports the platform entry points for `app`. Call it once from the app's client root:
/// `comptime { zui.exportApp(app); }`
pub fn exportApp(comptime app: App) void {
    host.exportEntry(app);
}

test "platform is headless when testing on the build machine" {
    try std.testing.expectEqual(Platform.headless, platform);
}

test {
    _ = host;
}
