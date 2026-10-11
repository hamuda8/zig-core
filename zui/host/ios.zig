//! iOS host: real UIKit views (UIView, UILabel, UITextField, UIScrollView) created and placed
//! through the Objective-C runtime. The app's `main`, its delegates and the few UIView
//! subclasses zui needs are all defined here in Zig, at runtime.

const std = @import("std");
const zui = @import("../zui.zig");
const objc = @import("../platform/objc.zig");

const id = objc.id;
const CGFloat = objc.CGFloat;

extern "UIKit" fn UIApplicationMain(argc: c_int, argv: [*]?[*:0]u8, principal: id, delegate: id) c_int;
extern "UIKit" var NSFontAttributeName: id;
extern "UIKit" var NSForegroundColorAttributeName: id;
extern "UIKit" var NSParagraphStyleAttributeName: id;
extern "UIKit" var NSBaselineOffsetAttributeName: id;

/// UIControlEventEditingChanged
const editing_changed: usize = 1 << 17;
/// NSStringDrawingUsesLineFragmentOrigin
const uses_line_fragment_origin: isize = 1;
/// UIUserInterfaceStyleDark
const style_dark: isize = 2;
/// NSLineBreakByWordWrapping, NSLineBreakByTruncatingTail
const break_word: isize = 0;
const break_tail: isize = 4;

var views: std.ArrayList(id) = .empty;
/// Scroll views put their children in a content view.
var contents: std.ArrayList(id) = .empty;
var pressables: std.ArrayList(bool) = .empty;
var root: id = null;
var target: id = null;

fn slot(list: anytype, i: u32) void {
    while (list.items.len <= i) list.append(zui.allocator, std.mem.zeroes(@TypeOf(list.items[0]))) catch return;
}

fn view(i: u32) id {
    if (i == 0) return root;
    return if (i < views.items.len) views.items[i] else null;
}

fn container(i: u32) id {
    if (i < contents.items.len and contents.items[i] != null) return contents.items[i];
    return view(i);
}

fn color(argb: u32) id {
    const f = objc.msgSend(*const fn (id, objc.SEL, CGFloat, CGFloat, CGFloat, CGFloat) callconv(.c) id);
    const c = struct {
        fn ch(v: u32, shift: u5) CGFloat {
            return @as(CGFloat, @floatFromInt((v >> shift) & 0xff)) / 255;
        }
    }.ch;
    return f(objc.class("UIColor"), objc.sel("colorWithRed:green:blue:alpha:"), c(argb, 16), c(argb, 8), c(argb, 0), c(argb, 24));
}

fn faded(argb: u32) u32 {
    const a: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(argb >> 24)) * 0.45));
    return (a << 24) | (argb & 0xffffff);
}

fn font(f: zui.Font) id {
    const w: CGFloat = switch (f.weight) {
        0...149 => -0.8,
        150...249 => -0.6,
        250...349 => -0.4,
        350...449 => 0,
        450...549 => 0.23,
        550...649 => 0.3,
        650...749 => 0.4,
        750...849 => 0.56,
        else => 0.62,
    };
    const make = objc.msgSend(*const fn (id, objc.SEL, CGFloat, CGFloat) callconv(.c) id);
    const name = if (f.mono) "monospacedSystemFontOfSize:weight:" else "systemFontOfSize:weight:";
    return make(objc.class("UIFont"), objc.sel(name), f.size, w);
}

/// Attributes shared by drawing and measuring, so they always agree: the font, a fixed line
/// height with the text centred in it (as CSS does), alignment and wrapping.
fn attributes(f: zui.Font, argb: u32, a: zui.PhysicalAlign) id {
    const ui_font = font(f);
    const para = objc.new("NSMutableParagraphStyle");
    defer objc.release(para);
    objc.sendVoidFloat(para, "setMinimumLineHeight:", f.line_height);
    objc.sendVoidFloat(para, "setMaximumLineHeight:", f.line_height);
    // NSTextAlignment on iOS: 0 left, 1 center, 2 right.
    objc.sendVoidInt(para, "setAlignment:", @backingInt(a));
    objc.sendVoidInt(para, "setLineBreakMode:", if (f.max_lines > 0) break_tail else break_word);

    const font_line: CGFloat = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) CGFloat)(ui_font, objc.sel("lineHeight"));
    const offset = objc.msgSend(*const fn (id, objc.SEL, CGFloat) callconv(.c) id)(objc.class("NSNumber"), objc.sel("numberWithDouble:"), (f.line_height - font_line) / 4);

    var keys = [_]id{ NSFontAttributeName, NSForegroundColorAttributeName, NSParagraphStyleAttributeName, NSBaselineOffsetAttributeName };
    var values = [_]id{ ui_font, color(argb), para, offset };
    const dict = objc.msgSend(*const fn (id, objc.SEL, [*]id, [*]id, usize) callconv(.c) id);
    return dict(objc.class("NSDictionary"), objc.sel("dictionaryWithObjects:forKeys:count:"), &values, &keys, keys.len);
}

fn attributed(s: []const u8, attrs: id) id {
    const str = objc.nsString(s);
    defer objc.release(str);
    const init = objc.msgSend(*const fn (id, objc.SEL, id, id) callconv(.c) id);
    return init(objc.send(objc.class("NSAttributedString"), "alloc"), objc.sel("initWithString:attributes:"), str, attrs);
}

pub fn create(i: u32, kind: zui.tree.Kind) void {
    slot(&views, i);
    slot(&contents, i);
    slot(&pressables, i);
    const v: id = switch (kind) {
        .view => objc.new("ZuiView"),
        .text => blk: {
            const l = objc.new("UILabel");
            objc.sendVoidInt(l, "setNumberOfLines:", 0);
            break :blk l;
        },
        .input => blk: {
            const t = objc.new("UITextField");
            const add = objc.msgSend(*const fn (id, objc.SEL, id, objc.SEL, usize) callconv(.c) void);
            add(t, objc.sel("addTarget:action:forControlEvents:"), target, objc.sel("changed:"), editing_changed);
            break :blk t;
        },
        .scroll, .scroll_x => blk: {
            const s = objc.new("UIScrollView");
            const c = objc.new("ZuiView");
            objc.sendVoid1(s, "addSubview:", c);
            contents.items[i] = c;
            break :blk s;
        },
    };
    objc.sendVoidInt(v, "setTag:", @intCast(i));
    views.items[i] = v;
    pressables.items[i] = false;
}

pub fn destroy(i: u32) void {
    const v = view(i);
    objc.sendVoid(v, "removeFromSuperview");
    objc.release(v);
    views.items[i] = null;
    if (contents.items[i] != null) objc.release(contents.items[i]);
    contents.items[i] = null;
}

pub fn insert(parent: u32, i: u32, index: u32) void {
    const f = objc.msgSend(*const fn (id, objc.SEL, id, isize) callconv(.c) void);
    f(container(parent), objc.sel("insertSubview:atIndex:"), view(i), @intCast(index));
}

pub fn frame(i: u32, r: zui.Rect) void {
    const f = objc.msgSend(*const fn (id, objc.SEL, objc.CGRect) callconv(.c) void);
    f(view(i), objc.sel("setFrame:"), .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });
}

pub fn box(i: u32, b: zui.Box) void {
    const v = view(i);
    objc.sendVoid1(v, "setBackgroundColor:", if (b.background >> 24 == 0) null else color(b.background));
    const layer = objc.send(v, "layer");
    objc.sendVoidFloat(layer, "setCornerRadius:", b.radius);
    objc.sendVoidFloat(layer, "setBorderWidth:", b.border_width);
    objc.sendVoid1(layer, "setBorderColor:", objc.send(color(b.border_color), "CGColor"));
    objc.sendVoidFloat(v, "setAlpha:", b.opacity);
}

pub fn pressable(i: u32, on: bool) void {
    if (i < pressables.items.len) pressables.items[i] = on;
}

pub fn text(i: u32, s: []const u8, f: zui.Font, argb: u32, a: zui.PhysicalAlign) void {
    const l = view(i);
    const str = attributed(s, attributes(f, argb, a));
    defer objc.release(str);
    objc.sendVoid1(l, "setAttributedText:", str);
    objc.sendVoidInt(l, "setNumberOfLines:", f.max_lines);
}

pub fn input(i: u32, value: []const u8, placeholder: []const u8, f: zui.Font, argb: u32, a: zui.PhysicalAlign) void {
    const t = view(i);
    const current = objc.send(t, "text");
    const utf8 = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) ?[*:0]const u8)(current, objc.sel("UTF8String"));
    const same = if (utf8) |p| std.mem.eql(u8, std.mem.span(p), value) else value.len == 0;
    if (!same) {
        const v = objc.nsString(value);
        defer objc.release(v);
        objc.sendVoid1(t, "setText:", v);
    }
    objc.sendVoid1(t, "setFont:", font(f));
    objc.sendVoid1(t, "setTextColor:", color(argb));
    objc.sendVoidInt(t, "setTextAlignment:", @backingInt(a));
    const ph = attributed(placeholder, attributes(f, faded(argb), a));
    defer objc.release(ph);
    objc.sendVoid1(t, "setAttributedPlaceholder:", ph);
}

pub fn content(i: u32, s: zui.Size) void {
    const c = container(i);
    const set_frame = objc.msgSend(*const fn (id, objc.SEL, objc.CGRect) callconv(.c) void);
    set_frame(c, objc.sel("setFrame:"), .{ .w = s.w, .h = s.h });
    const set_size = objc.msgSend(*const fn (id, objc.SEL, objc.CGSize) callconv(.c) void);
    set_size(view(i), objc.sel("setContentSize:"), .{ .w = s.w, .h = s.h });
}

pub fn rootBackground(argb: u32) void {
    objc.sendVoid1(root, "setBackgroundColor:", color(argb));
}

pub fn measure(s: []const u8, f: zui.Font, max_width: f32) zui.Size {
    if (s.len == 0) return .{ .w = 0, .h = f.line_height };
    const str = attributed(s, attributes(f, 0xff000000, .left));
    defer objc.release(str);
    const bound = objc.msgSend(*const fn (id, objc.SEL, objc.CGSize, isize, id) callconv(.c) objc.CGRect);
    const width: CGFloat = if (std.math.isFinite(max_width)) max_width else 1e7;
    const r = bound(str, objc.sel("boundingRectWithSize:options:context:"), .{ .w = width, .h = 1e7 }, uses_line_fragment_origin, null);
    var h: f32 = @floatCast(@ceil(r.h));
    if (f.max_lines > 0) h = @min(h, @as(f32, @floatFromInt(f.max_lines)) * f.line_height);
    return .{ .w = @floatCast(@ceil(r.w)), .h = h };
}

pub fn exportEntry(comptime App: type) void {
    const R = zui.runtime.Runtime(App, @This());
    const Entry = struct {
        var window: id = null;
        var started = false;

        fn main(argc: c_int, argv: [*]?[*:0]u8) callconv(.c) c_int {
            objc.defineClass("ZuiAppDelegate", "UIResponder", &.{"UIApplicationDelegate"}, &.{});
            objc.defineClass("ZuiSceneDelegate", "UIResponder", &.{"UIWindowSceneDelegate"}, &.{
                .{ "scene:willConnectToSession:options:", @ptrCast(&sceneWillConnect), "v@:@@@" },
            });
            objc.defineClass("ZuiRootView", "UIView", &.{}, &.{
                .{ "layoutSubviews", @ptrCast(&rootLayout), "v@:" },
                .{ "traitCollectionDidChange:", @ptrCast(&rootTraits), "v@:@" },
            });
            objc.defineClass("ZuiView", "UIView", &.{}, &.{
                .{ "touchesBegan:withEvent:", @ptrCast(&touchesBegan), "v@:@@" },
                .{ "touchesEnded:withEvent:", @ptrCast(&touchesEnded), "v@:@@" },
                .{ "touchesCancelled:withEvent:", @ptrCast(&touchesCancelled), "v@:@@" },
            });
            objc.defineClass("ZuiTarget", "NSObject", &.{}, &.{
                .{ "changed:", @ptrCast(&textChanged), "v@:@" },
            });
            return UIApplicationMain(argc, argv, null, objc.nsString("ZuiAppDelegate"));
        }

        fn sceneWillConnect(_: id, _: objc.SEL, scene: id, _: id, _: id) callconv(.c) void {
            target = objc.new("ZuiTarget");
            window = objc.send1(objc.send(objc.class("UIWindow"), "alloc"), "initWithWindowScene:", scene);
            root = objc.new("ZuiRootView");
            const controller = objc.new("UIViewController");
            objc.sendVoid1(controller, "setView:", root);
            objc.sendVoid1(window, "setRootViewController:", controller);
            objc.sendVoid(window, "makeKeyAndVisible");
        }

        fn isDark(self: id) bool {
            return objc.sendInt(objc.send(self, "traitCollection"), "userInterfaceStyle") == style_dark;
        }

        fn rootLayout(self: id, _: objc.SEL) callconv(.c) void {
            objc.sendSuper(self, "ZuiRootView", "layoutSubviews");
            const bounds = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) objc.CGRect)(self, objc.sel("bounds"));
            const safe = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) objc.UIEdgeInsets)(self, objc.sel("safeAreaInsets"));
            if (bounds.w <= 0 or bounds.h <= 0) return;
            const insets: zui.Insets = .{ .top = @floatCast(safe.top), .right = @floatCast(safe.right), .bottom = @floatCast(safe.bottom), .left = @floatCast(safe.left) };
            if (!started) {
                started = true;
                const langs = objc.send(objc.class("NSLocale"), "preferredLanguages");
                const first = objc.send(langs, "firstObject");
                const utf8 = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) ?[*:0]const u8)(first, objc.sel("UTF8String"));
                R.start(zui.allocator, .{ .width = @floatCast(bounds.w), .height = @floatCast(bounds.h), .dark = isDark(self), .safe = insets }, if (utf8) |p| std.mem.span(p) else "en");
            } else {
                R.setInsets(insets);
                R.resize(@floatCast(bounds.w), @floatCast(bounds.h));
            }
        }

        fn rootTraits(self: id, _: objc.SEL, _: id) callconv(.c) void {
            if (started) R.setDark(isDark(self));
        }

        fn tagOf(v: id) u32 {
            return @intCast(objc.sendInt(v, "tag"));
        }

        fn isPressable(i: u32) bool {
            return i < pressables.items.len and pressables.items[i];
        }

        fn touchesBegan(self: id, _: objc.SEL, touches: id, ev: id) callconv(.c) void {
            const i = tagOf(self);
            if (!isPressable(i)) return objc.sendSuper2(self, "ZuiView", "touchesBegan:withEvent:", touches, ev);
            R.event(i, .press_in);
        }

        fn touchesEnded(self: id, _: objc.SEL, touches: id, ev: id) callconv(.c) void {
            const i = tagOf(self);
            if (!isPressable(i)) return objc.sendSuper2(self, "ZuiView", "touchesEnded:withEvent:", touches, ev);
            R.event(i, .press_out);
            const touch = objc.send(touches, "anyObject");
            const p = objc.msgSend(*const fn (id, objc.SEL, id) callconv(.c) objc.CGPoint)(touch, objc.sel("locationInView:"), self);
            const b = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) objc.CGRect)(self, objc.sel("bounds"));
            if (p.x >= 0 and p.y >= 0 and p.x <= b.w and p.y <= b.h) R.event(i, .press);
        }

        fn touchesCancelled(self: id, _: objc.SEL, touches: id, ev: id) callconv(.c) void {
            const i = tagOf(self);
            if (!isPressable(i)) return objc.sendSuper2(self, "ZuiView", "touchesCancelled:withEvent:", touches, ev);
            R.event(i, .press_out);
        }

        fn textChanged(_: id, _: objc.SEL, field: id) callconv(.c) void {
            const s = objc.send(field, "text");
            const utf8 = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) ?[*:0]const u8)(s, objc.sel("UTF8String"));
            R.textEvent(tagOf(field), if (utf8) |p| std.mem.span(p) else "");
        }
    };
    @export(&Entry.main, .{ .name = "main" });
}

extern "c" fn write(fd: c_int, buf: [*]const u8, len: usize) isize;

/// To stderr, which the device log and `simctl launch --console` show.
pub fn log(line: []const u8) void {
    _ = write(2, line.ptr, line.len);
    _ = write(2, "\n", 1);
}
