//! iOS host: creates UIKit views through the Objective-C runtime. The app's `main`, its app
//! delegate and its scene delegate are all defined here in Zig.

const zui = @import("../zui.zig");
const objc = @import("../platform/objc.zig");

pub const Context = struct {
    label: objc.id,
};

extern "UIKit" fn UIApplicationMain(argc: c_int, argv: [*]?[*:0]u8, principal: objc.id, delegate: objc.id) c_int;

/// NSTextAlignmentCenter on iOS.
const text_alignment_center: isize = 1;

pub fn showText(ctx: *Context, s: []const u8) void {
    const str = objc.nsString(s);
    defer objc.release(str);
    objc.sendVoid1(ctx.label, "setText:", str);
}

pub fn exportEntry(comptime app: zui.App) void {
    const Entry = struct {
        var ctx: Context = .{ .label = null };
        /// Kept for the life of the app (a +1 reference that is never released).
        var window: objc.id = null;

        fn main(argc: c_int, argv: [*]?[*:0]u8) callconv(.c) c_int {
            objc.defineClass("ZuiAppDelegate", "UIResponder", &.{"UIApplicationDelegate"}, &.{});
            objc.defineClass("ZuiSceneDelegate", "UIResponder", &.{"UIWindowSceneDelegate"}, &.{
                .{ "scene:willConnectToSession:options:", @ptrCast(&sceneWillConnect), "v@:@@@" },
            });
            return UIApplicationMain(argc, argv, null, objc.nsString("ZuiAppDelegate"));
        }

        fn sceneWillConnect(_: objc.id, _: objc.SEL, scene: objc.id, _: objc.id, _: objc.id) callconv(.c) void {
            window = objc.send1(objc.send(objc.class("UIWindow"), "alloc"), "initWithWindowScene:", scene);

            const label = objc.new("UILabel");
            objc.sendVoidInt(label, "setTextAlignment:", text_alignment_center);
            const font = objc.msgSend(*const fn (objc.id, objc.SEL, f64) callconv(.c) objc.id);
            objc.sendVoid1(label, "setFont:", font(objc.class("UIFont"), objc.sel("systemFontOfSize:"), 24));
            objc.sendVoid1(label, "setTextColor:", objc.send(objc.class("UIColor"), "labelColor"));
            objc.sendVoid1(label, "setBackgroundColor:", objc.send(objc.class("UIColor"), "systemBackgroundColor"));

            const controller = objc.new("UIViewController");
            objc.sendVoid1(controller, "setView:", label);
            objc.sendVoid1(window, "setRootViewController:", controller);
            objc.sendVoid(window, "makeKeyAndVisible");

            ctx.label = label;
            var ui: zui.Ui = .{ .ctx = &ctx };
            app.start(&ui);
        }
    };
    @export(&Entry.main, .{ .name = "main" });
}
