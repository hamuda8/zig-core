//! The app's home-screen widget: a title and up to three lines, kept on the device so the
//! widget shows them while the app is closed (today's tasks, unread chats...). Android: the
//! generic com.wufour.zui.ZuiWidget (the app declares it in its manifest). iOS widgets must be
//! written in SwiftUI (WidgetKit), which zui does not do yet; the web has none.

const zui = @import("zui.zig");

pub fn update(title: []const u8, lines: []const []const u8) void {
    const l = struct {
        fn at(ls: []const []const u8, i: usize) []const u8 {
            return if (i < ls.len) ls[i] else "";
        }
    }.at;
    zui.host.widgetUpdate(title, l(lines, 0), l(lines, 1), l(lines, 2));
}
