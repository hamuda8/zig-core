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

/// UIControlEventEditingChanged, ...DidBegin, ...DidEnd, ...DidEndOnExit (return key).
const editing_changed: usize = 1 << 17;
const editing_began: usize = 1 << 16;
const editing_ended: usize = 1 << 18;
const editing_return: usize = 1 << 19;

/// The runtime's entry points, for callbacks that arrive from C (GCD, NSURLSession, ...).
var rt: struct {
    fetch_done: *const fn (u32, u16, []const u8) void,
    timer_done: *const fn (u32) void,
    location: *const fn (zui.Location) void,
} = undefined;
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
/// Each view's frame and transform origin: on iOS the origin (anchor point) also decides where
/// `center` puts the view, so both are applied together.
var frames: std.ArrayList(zui.Rect) = .empty;
var origins: std.ArrayList(?[2]f32) = .empty;
/// Views that report raw pointer events (gestures).
var pointers: std.ArrayList(bool) = .empty;
/// The URL each image view should show (allocator-owned), so a late download for an old URL is
/// dropped.
var image_urls: std.ArrayList(?[]u8) = .empty;
var image_cache: id = null;
/// Each image view's colour filter (map tiles), applied to its pictures as they load.
var filters: std.ArrayList(zui.ImageFilter) = .empty;
var ci_context: id = null;
var display_link: id = null;
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
    slot(&pointers, i);
    slot(&image_urls, i);
    slot(&frames, i);
    slot(&origins, i);
    slot(&filters, i);
    filters.items[i] = .{};
    origins.items[i] = null;
    const v: id = switch (kind) {
        .image => blk: {
            const iv = objc.new("UIImageView");
            objc.sendVoidInt(iv, "setContentMode:", 0); // UIViewContentModeScaleToFill
            break :blk iv;
        },
        .path => blk: {
            const pv = objc.new("ZuiPathView");
            objc.sendVoidBool(pv, "setUserInteractionEnabled:", false);
            objc.sendVoid1(objc.send(pv, "layer"), "setFillColor:", null);
            break :blk pv;
        },
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
            add(t, objc.sel("addTarget:action:forControlEvents:"), target, objc.sel("began:"), editing_began);
            add(t, objc.sel("addTarget:action:forControlEvents:"), target, objc.sel("ended:"), editing_ended);
            add(t, objc.sel("addTarget:action:forControlEvents:"), target, objc.sel("submitted:"), editing_return);
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
    pointers.items[i] = false;
}

pub fn destroy(i: u32) void {
    const v = view(i);
    objc.sendVoid(v, "removeFromSuperview");
    objc.release(v);
    views.items[i] = null;
    if (image_urls.items[i]) |u| zui.allocator.free(u);
    image_urls.items[i] = null;
    if (contents.items[i] != null) objc.release(contents.items[i]);
    contents.items[i] = null;
}

pub fn insert(parent: u32, i: u32, index: u32) void {
    const p = container(parent);
    const v = view(i);
    // Already there: moving it could take the focus from a text field inside it.
    const subviews = objc.send(p, "subviews");
    if (index < objc.sendInt(subviews, "count")) {
        const at = objc.msgSend(*const fn (id, objc.SEL, usize) callconv(.c) id)(subviews, objc.sel("objectAtIndex:"), index);
        if (at == v) return;
    }
    const f = objc.msgSend(*const fn (id, objc.SEL, id, isize) callconv(.c) void);
    f(p, objc.sel("insertSubview:atIndex:"), v, @intCast(index));
}

/// Bounds and centre rather than frame: a view with a 3D transform (the map layer) has no
/// well-defined frame.
pub fn frame(i: u32, r: zui.Rect) void {
    if (i < frames.items.len) frames.items[i] = r;
    place(i, r);
}

fn place(i: u32, r: zui.Rect) void {
    const v = view(i);
    const o: ?[2]f32 = if (i < origins.items.len) origins.items[i] else null;
    const ox = if (o) |p| p[0] else r.w / 2;
    const oy = if (o) |p| p[1] else r.h / 2;
    const set_point = objc.msgSend(*const fn (id, objc.SEL, objc.CGPoint) callconv(.c) void);
    set_point(objc.send(v, "layer"), objc.sel("setAnchorPoint:"), .{ .x = if (r.w > 0) ox / r.w else 0.5, .y = if (r.h > 0) oy / r.h else 0.5 });
    const set_bounds = objc.msgSend(*const fn (id, objc.SEL, objc.CGRect) callconv(.c) void);
    set_bounds(v, objc.sel("setBounds:"), .{ .w = r.w, .h = r.h });
    set_point(v, objc.sel("setCenter:"), .{ .x = r.x + ox, .y = r.y + oy });
}

pub fn box(i: u32, b: zui.Box) void {
    const v = view(i);
    // A transparent color, never nil: opaque views such as UILabel fill a nil background black.
    objc.sendVoid1(v, "setBackgroundColor:", if (b.background >> 24 == 0) objc.send(objc.class("UIColor"), "clearColor") else color(b.background));
    objc.sendVoidBool(v, "setOpaque:", false);
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
            rt = .{ .fetch_done = fetchDone, .timer_done = timerDone, .location = locationEvent };
            objc.defineClass("ZuiLocation", "NSObject", &.{"CLLocationManagerDelegate"}, &.{
                .{ "locationManager:didUpdateLocations:", @ptrCast(&locationUpdated), "v@:@@" },
                .{ "locationManager:didFailWithError:", @ptrCast(&locationFailed), "v@:@@" },
                .{ "locationManagerDidChangeAuthorization:", @ptrCast(&locationAuthorization), "v@:@" },
            });
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
                .{ "touchesMoved:withEvent:", @ptrCast(&touchesMoved), "v@:@@" },
                .{ "touchesEnded:withEvent:", @ptrCast(&touchesEnded), "v@:@@" },
                .{ "touchesCancelled:withEvent:", @ptrCast(&touchesCancelled), "v@:@@" },
            });
            // A view backed by a CAShapeLayer, for route lines.
            objc.defineClass("ZuiPathView", "UIView", &.{}, &.{});
            objc.addClassMethod("ZuiPathView", "layerClass", @ptrCast(&shapeLayerClass), "#@:");
            objc.defineClass("ZuiTarget", "NSObject", &.{}, &.{
                .{ "changed:", @ptrCast(&textChanged), "v@:@" },
                .{ "began:", @ptrCast(&inputBegan), "v@:@" },
                .{ "ended:", @ptrCast(&inputEnded), "v@:@" },
                .{ "submitted:", @ptrCast(&inputSubmitted), "v@:@" },
                .{ "frame:", @ptrCast(&displayFrame), "v@:@" },
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

        fn shapeLayerClass(_: id, _: objc.SEL) callconv(.c) id {
            return objc.class("CAShapeLayer");
        }

        fn displayFrame(_: id, _: objc.SEL, link: id) callconv(.c) void {
            // Paused until the app asks for the next frame.
            objc.sendVoidBool(link, "setPaused:", true);
            const seconds = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) f64)(link, objc.sel("timestamp"));
            R.frame(seconds * 1000);
        }

        fn inputBegan(_: id, _: objc.SEL, field: id) callconv(.c) void {
            R.inputEvent(tagOf(field), .focus);
        }
        fn inputEnded(_: id, _: objc.SEL, field: id) callconv(.c) void {
            R.inputEvent(tagOf(field), .blur);
        }
        fn inputSubmitted(_: id, _: objc.SEL, field: id) callconv(.c) void {
            R.inputEvent(tagOf(field), .submit);
        }

        fn fetchDone(i: u32, status: u16, body: []const u8) void {
            R.fetchDone(i, status, body);
        }
        fn timerDone(i: u32) void {
            R.timerDone(i);
        }
        fn locationEvent(l: zui.Location) void {
            R.locationEvent(l);
        }

        fn wantsPointers(i: u32) bool {
            return i < pointers.items.len and pointers.items[i];
        }

        /// Each touch in the set as a zui.Pointer in the view's own points.
        fn sendPointers(self: id, touches: id, kind: zui.Pointer.Kind) void {
            const i = tagOf(self);
            const all = objc.send(touches, "allObjects");
            const n: usize = @intCast(objc.sendInt(all, "count"));
            const at = objc.msgSend(*const fn (id, objc.SEL, usize) callconv(.c) id);
            const location_in = objc.msgSend(*const fn (id, objc.SEL, id) callconv(.c) objc.CGPoint);
            const timestamp = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) f64);
            for (0..n) |k| {
                const touch = at(all, objc.sel("objectAtIndex:"), k);
                const p = location_in(touch, objc.sel("locationInView:"), self);
                R.pointerEvent(i, .{
                    .kind = kind,
                    .id = touchId(touch, kind),
                    .x = @floatCast(p.x),
                    .y = @floatCast(p.y),
                    .time_ms = @intFromFloat(timestamp(touch, objc.sel("timestamp")) * 1000),
                });
            }
        }

        /// Small stable ids for the fingers down (UITouch objects live as long as the finger).
        var fingers: [16]usize = @splat(0);

        fn touchId(touch: id, kind: zui.Pointer.Kind) u32 {
            const key = @intFromPtr(touch);
            var free: ?usize = null;
            for (&fingers, 0..) |*f, n| {
                if (f.* == key) {
                    if (kind == .up or kind == .cancel) f.* = 0;
                    return @intCast(n + 1);
                }
                if (f.* == 0 and free == null) free = n;
            }
            const n = free orelse return 0;
            if (kind == .down) fingers[n] = key;
            return @intCast(n + 1);
        }

        fn touchesMoved(self: id, _: objc.SEL, touches: id, ev: id) callconv(.c) void {
            if (!wantsPointers(tagOf(self))) return objc.sendSuper2(self, "ZuiView", "touchesMoved:withEvent:", touches, ev);
            sendPointers(self, touches, .move);
        }

        fn touchesBegan(self: id, _: objc.SEL, touches: id, ev: id) callconv(.c) void {
            const i = tagOf(self);
            if (wantsPointers(i)) return sendPointers(self, touches, .down);
            if (!isPressable(i)) return objc.sendSuper2(self, "ZuiView", "touchesBegan:withEvent:", touches, ev);
            R.event(i, .press_in);
        }

        fn touchesEnded(self: id, _: objc.SEL, touches: id, ev: id) callconv(.c) void {
            const i = tagOf(self);
            if (wantsPointers(i)) return sendPointers(self, touches, .up);
            if (!isPressable(i)) return objc.sendSuper2(self, "ZuiView", "touchesEnded:withEvent:", touches, ev);
            R.event(i, .press_out);
            const touch = objc.send(touches, "anyObject");
            const p = objc.msgSend(*const fn (id, objc.SEL, id) callconv(.c) objc.CGPoint)(touch, objc.sel("locationInView:"), self);
            const b = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) objc.CGRect)(self, objc.sel("bounds"));
            if (p.x >= 0 and p.y >= 0 and p.x <= b.w and p.y <= b.h) R.event(i, .press);
        }

        fn touchesCancelled(self: id, _: objc.SEL, touches: id, ev: id) callconv(.c) void {
            const i = tagOf(self);
            if (wantsPointers(i)) return sendPointers(self, touches, .cancel);
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

// ---- Map primitives ------------------------------------------------------------------------

const CATransform3D = extern struct { m: [16]CGFloat };

/// Rotate (clockwise, degrees), then tilt (top edge away), then perspective: the same projection
/// as CSS `perspective() rotateX() rotate()` and map.View.toScreen. Core Animation multiplies row
/// vectors, with z towards the viewer, so the matrices compose left to right.
fn transformMatrix(t: zui.Transform) CATransform3D {
    const a = std.math.degreesToRadians(@as(f64, t.rotate));
    const b = std.math.degreesToRadians(@as(f64, t.tilt));
    const rz = [16]f64{ @cos(a), @sin(a), 0, 0, -@sin(a), @cos(a), 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    const rx = [16]f64{ 1, 0, 0, 0, 0, @cos(b), @sin(b), 0, 0, -@sin(b), @cos(b), 0, 0, 0, 0, 1 };
    var p = [16]f64{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    if (t.perspective > 0) p[11] = -1 / @as(f64, t.perspective); // m34
    return .{ .m = mul(mul(rz, rx), p) };
}

fn mul(x: [16]f64, y: [16]f64) [16]f64 {
    var out: [16]f64 = undefined;
    for (0..4) |r| for (0..4) |c| {
        var sum: f64 = 0;
        for (0..4) |k| sum += x[r * 4 + k] * y[k * 4 + c];
        out[r * 4 + c] = sum;
    };
    return out;
}

pub fn transform(i: u32, t: zui.Transform) void {
    if (i < origins.items.len and !std.meta.eql(origins.items[i], t.origin)) {
        origins.items[i] = t.origin;
        place(i, frames.items[i]);
    }
    const set = objc.msgSend(*const fn (id, objc.SEL, CATransform3D) callconv(.c) void);
    set(objc.send(view(i), "layer"), objc.sel("setTransform:"), transformMatrix(t));
}

pub fn clip(i: u32, on: bool) void {
    objc.sendVoidBool(view(i), "setClipsToBounds:", on);
}

pub fn pointer(i: u32, on: bool) void {
    if (i < pointers.items.len) pointers.items[i] = on;
    objc.sendVoidBool(view(i), "setMultipleTouchEnabled:", on);
}

const Queue = ?*anyopaque;
extern "c" fn dispatch_get_global_queue(identifier: isize, flags: usize) Queue;
extern "c" fn dispatch_async_f(queue: Queue, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;
/// What `dispatch_get_main_queue()` returns (a macro in the C headers).
extern "c" var _dispatch_main_q: u8;

const ImageJob = struct { id: u32, url: []u8, image: id = null, filter: zui.ImageFilter = .{} };

pub fn imageFilter(i: u32, f: zui.ImageFilter) void {
    if (i < filters.items.len) filters.items[i] = f;
}

/// The cache key: the URL, plus the filter when there is one.
fn cacheKey(url: []const u8, f: zui.ImageFilter, buf: []u8) []const u8 {
    if (f.isIdentity()) return url;
    return std.fmt.bufPrint(buf, "{s}#{d}/{d}/{d}", .{ url, f.saturate, f.contrast, f.brightness }) catch url;
}

/// `img` through CIColorMatrix (+1 retained), on any thread.
fn filtered(img: id, f: zui.ImageFilter) id {
    const m = f.matrix();
    const cg = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) ?*anyopaque)(img, objc.sel("CGImage")) orelse return objc.send(img, "retain");
    const ci = objc.msgSend(*const fn (id, objc.SEL, ?*anyopaque) callconv(.c) id)(objc.class("CIImage"), objc.sel("imageWithCGImage:"), cg);
    const name = objc.nsString("CIColorMatrix");
    defer objc.release(name);
    const filter = objc.send1(objc.class("CIFilter"), "filterWithName:", name);
    const set = objc.msgSend(*const fn (id, objc.SEL, id, id) callconv(.c) void);
    const vec = objc.msgSend(*const fn (id, objc.SEL, CGFloat, CGFloat, CGFloat, CGFloat) callconv(.c) id);
    const keys = [_][]const u8{ "inputRVector", "inputGVector", "inputBVector", "inputAVector" };
    const image_key = objc.nsString("inputImage");
    defer objc.release(image_key);
    set(filter, objc.sel("setValue:forKey:"), ci, image_key);
    for (keys, 0..) |k, r| {
        const key = objc.nsString(k);
        defer objc.release(key);
        set(filter, objc.sel("setValue:forKey:"), vec(objc.class("CIVector"), objc.sel("vectorWithX:Y:Z:W:"), m[r * 5], m[r * 5 + 1], m[r * 5 + 2], m[r * 5 + 3]), key);
    }
    const bias = objc.nsString("inputBiasVector");
    defer objc.release(bias);
    set(filter, objc.sel("setValue:forKey:"), vec(objc.class("CIVector"), objc.sel("vectorWithX:Y:Z:W:"), m[4], m[9], m[14], 0), bias);
    const out = objc.send(filter, "outputImage");
    if (ci_context == null) ci_context = objc.send(objc.send(objc.class("CIContext"), "context"), "retain");
    const extent = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) objc.CGRect)(ci, objc.sel("extent"));
    const made = objc.msgSend(*const fn (id, objc.SEL, id, objc.CGRect) callconv(.c) ?*anyopaque)(ci_context, objc.sel("createCGImage:fromRect:"), out, extent) orelse return objc.send(img, "retain");
    defer CGImageRelease(made);
    const result = objc.msgSend(*const fn (id, objc.SEL, ?*anyopaque) callconv(.c) id)(objc.class("UIImage"), objc.sel("imageWithCGImage:"), made);
    return objc.send(result, "retain");
}

extern "CoreGraphics" fn CGImageRelease(image: ?*anyopaque) void;

/// Shows the picture at `url`: from memory if seen before, else downloaded on a background
/// queue and applied on the main queue if the view still wants that URL. Downloads go through
/// the shared URL cache, so tiles also persist on disk.
pub fn image(i: u32, url: []const u8) void {
    if (image_urls.items[i]) |old| {
        if (std.mem.eql(u8, old, url)) return;
        zui.allocator.free(old);
    }
    image_urls.items[i] = zui.allocator.dupe(u8, url) catch null;
    if (image_cache == null) image_cache = objc.new("NSCache");
    const f = filters.items[i];
    var kb: [600]u8 = undefined;
    const key = objc.nsString(cacheKey(url, f, &kb));
    defer objc.release(key);
    const cached = objc.send1(image_cache, "objectForKey:", key);
    objc.sendVoid1(view(i), "setImage:", cached);
    if (cached != null) return;

    const job = zui.allocator.create(ImageJob) catch return;
    const copy = zui.allocator.dupe(u8, url) catch return zui.allocator.destroy(job);
    job.* = .{ .id = i, .url = copy, .filter = f };
    dispatch_async_f(dispatch_get_global_queue(0, 0), job, download);
}

/// On a background queue: no zui state is touched here.
fn download(ctx: ?*anyopaque) callconv(.c) void {
    const job: *ImageJob = @ptrCast(@alignCast(ctx));
    const pool = objc.new("NSAutoreleasePool");
    const s = objc.nsString(job.url);
    const url = objc.send1(objc.class("NSURL"), "URLWithString:", s);
    objc.release(s);
    if (url != null) {
        const data = objc.send1(objc.class("NSData"), "dataWithContentsOfURL:", url);
        if (data != null) {
            const img = objc.send1(objc.class("UIImage"), "imageWithData:", data);
            if (img != null) job.image = if (job.filter.isIdentity()) objc.send(img, "retain") else filtered(img, job.filter);
        }
    }
    objc.release(pool);
    dispatch_async_f(@ptrCast(&_dispatch_main_q), job, applyImage);
}

fn applyImage(ctx: ?*anyopaque) callconv(.c) void {
    const job: *ImageJob = @ptrCast(@alignCast(ctx));
    defer {
        if (job.image != null) objc.release(job.image);
        zui.allocator.free(job.url);
        zui.allocator.destroy(job);
    }
    const img = job.image orelse return;
    var kb: [600]u8 = undefined;
    const key = objc.nsString(cacheKey(job.url, job.filter, &kb));
    defer objc.release(key);
    const set = objc.msgSend(*const fn (id, objc.SEL, id, id) callconv(.c) void);
    set(image_cache, objc.sel("setObject:forKey:"), img, key);
    if (job.id >= image_urls.items.len) return;
    const want = image_urls.items[job.id] orelse return;
    if (std.mem.eql(u8, want, job.url)) objc.sendVoid1(view(job.id), "setImage:", img);
}

const CGPath = ?*anyopaque;
extern "CoreGraphics" fn CGPathCreateMutable() CGPath;
extern "CoreGraphics" fn CGPathMoveToPoint(path: CGPath, m: ?*const anyopaque, x: CGFloat, y: CGFloat) void;
extern "CoreGraphics" fn CGPathAddLineToPoint(path: CGPath, m: ?*const anyopaque, x: CGFloat, y: CGFloat) void;
extern "CoreGraphics" fn CGPathRelease(path: CGPath) void;
extern "CoreGraphics" fn CGPathCloseSubpath(path: CGPath) void;
extern "QuartzCore" var kCALineCapRound: id;
extern "QuartzCore" var kCALineCapButt: id;
extern "QuartzCore" var kCALineJoinRound: id;
extern "QuartzCore" var kCALineJoinMiter: id;

pub fn path(i: u32, p: zui.Path) void {
    const layer = objc.send(view(i), "layer");
    const cg = CGPathCreateMutable();
    defer CGPathRelease(cg);
    const filled = p.fill >> 24 != 0;
    // A NaN x starts a new sub-path; filled shapes are closed.
    var move = true;
    for (p.points) |pt| {
        if (std.math.isNan(pt[0])) {
            if (filled and !move) CGPathCloseSubpath(cg);
            move = true;
            continue;
        }
        if (move) CGPathMoveToPoint(cg, null, pt[0], pt[1]) else CGPathAddLineToPoint(cg, null, pt[0], pt[1]);
        move = false;
    }
    if (filled and !move) CGPathCloseSubpath(cg);
    const set_ptr = objc.msgSend(*const fn (id, objc.SEL, ?*anyopaque) callconv(.c) void);
    set_ptr(layer, objc.sel("setPath:"), cg);
    set_ptr(layer, objc.sel("setFillColor:"), if (filled) @ptrCast(objc.send(color(p.fill), "CGColor")) else null);
    set_ptr(layer, objc.sel("setStrokeColor:"), if (p.width > 0) @ptrCast(objc.send(color(p.color), "CGColor")) else null);
    objc.sendVoidFloat(layer, "setLineWidth:", p.width);
    objc.sendVoid1(layer, "setLineCap:", if (p.round) kCALineCapRound else kCALineCapButt);
    objc.sendVoid1(layer, "setLineJoin:", if (p.round) kCALineJoinRound else kCALineJoinMiter);
    if (p.dash[0] > 0) {
        const num = objc.msgSend(*const fn (id, objc.SEL, CGFloat) callconv(.c) id);
        const number = objc.class("NSNumber");
        var items = [_]id{ num(number, objc.sel("numberWithDouble:"), p.dash[0]), num(number, objc.sel("numberWithDouble:"), p.dash[1]) };
        const array = objc.msgSend(*const fn (id, objc.SEL, [*]id, usize) callconv(.c) id);
        objc.sendVoid1(layer, "setLineDashPattern:", array(objc.class("NSArray"), objc.sel("arrayWithObjects:count:"), &items, items.len));
    } else objc.sendVoid1(layer, "setLineDashPattern:", null);
}

extern "Foundation" var NSRunLoopCommonModes: id;

/// One display-synchronised frame (CADisplayLink), then paused again.
pub fn requestFrame() void {
    if (display_link == null) {
        const make = objc.msgSend(*const fn (id, objc.SEL, id, objc.SEL) callconv(.c) id);
        display_link = objc.send(make(objc.class("CADisplayLink"), objc.sel("displayLinkWithTarget:selector:"), target, objc.sel("frame:")), "retain");
        const add = objc.msgSend(*const fn (id, objc.SEL, id, id) callconv(.c) void);
        add(display_link, objc.sel("addToRunLoop:forMode:"), objc.send(objc.class("NSRunLoop"), "mainRunLoop"), NSRunLoopCommonModes);
    }
    objc.sendVoidBool(display_link, "setPaused:", false);
}

// ---- Effects: network, timers, location, speech ---------------------------------------------

/// The completion handler NSURLSession calls: a block whose capture is the request id.
const FetchBlock = extern struct {
    header: objc.BlockHeader,
    request: u32,
};
const fetch_descriptor: objc.BlockDescriptor = .{ .size = @sizeOf(FetchBlock) };

const FetchResult = struct { request: u32, status: u16, body: []u8 };

pub fn fetch(i: u32, method: []const u8, url: []const u8, body: []const u8, content_type: []const u8) void {
    const s = objc.nsString(url);
    defer objc.release(s);
    const nsurl = objc.send1(objc.class("NSURL"), "URLWithString:", s);
    if (nsurl == null) return rt.fetch_done(i, 0, "");
    const req = objc.send1(objc.class("NSMutableURLRequest"), "requestWithURL:", nsurl);
    const m = objc.nsString(method);
    defer objc.release(m);
    objc.sendVoid1(req, "setHTTPMethod:", m);
    if (body.len > 0) {
        const data = objc.msgSend(*const fn (id, objc.SEL, [*]const u8, usize) callconv(.c) id)(objc.class("NSData"), objc.sel("dataWithBytes:length:"), body.ptr, body.len);
        objc.sendVoid1(req, "setHTTPBody:", data);
        const ct = objc.nsString(content_type);
        defer objc.release(ct);
        const field = objc.nsString("Content-Type");
        defer objc.release(field);
        objc.msgSend(*const fn (id, objc.SEL, id, id) callconv(.c) void)(req, objc.sel("setValue:forHTTPHeaderField:"), ct, field);
    }
    const block = zui.allocator.create(FetchBlock) catch return rt.fetch_done(i, 0, "");
    block.* = .{ .header = .{ .isa = &objc._NSConcreteGlobalBlock, .invoke = @ptrCast(&fetchCompleted), .descriptor = &fetch_descriptor }, .request = i };
    const session = objc.send(objc.class("NSURLSession"), "sharedSession");
    const task = objc.msgSend(*const fn (id, objc.SEL, id, *FetchBlock) callconv(.c) id)(session, objc.sel("dataTaskWithRequest:completionHandler:"), req, block);
    objc.sendVoid(task, "resume");
}

/// On NSURLSession's queue: copies the answer and hands it to the main thread.
fn fetchCompleted(block: *FetchBlock, data: id, response: id, err: id) callconv(.c) void {
    defer zui.allocator.destroy(block);
    var status: u16 = 0;
    if (err == null and response != null) status = @intCast(@max(0, @min(objc.sendInt(response, "statusCode"), 999)));
    var body: []u8 = &.{};
    if (data != null) {
        const n: usize = @intCast(objc.sendInt(data, "length"));
        const bytes = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) ?[*]const u8)(data, objc.sel("bytes"));
        if (bytes) |b| body = zui.allocator.dupe(u8, b[0..n]) catch &.{};
    }
    const result = zui.allocator.create(FetchResult) catch return;
    result.* = .{ .request = block.request, .status = status, .body = body };
    dispatch_async_f(@ptrCast(&_dispatch_main_q), result, fetchDelivered);
}

fn fetchDelivered(ctx: ?*anyopaque) callconv(.c) void {
    const r: *FetchResult = @ptrCast(@alignCast(ctx));
    defer {
        zui.allocator.free(r.body);
        zui.allocator.destroy(r);
    }
    rt.fetch_done(r.request, r.status, r.body);
}

extern "c" fn dispatch_time(when: u64, delta: i64) u64;
extern "c" fn dispatch_after_f(when: u64, queue: Queue, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;

pub fn timer(i: u32, ms: u32) void {
    dispatch_after_f(dispatch_time(0, @as(i64, ms) * std.time.ns_per_ms), @ptrCast(&_dispatch_main_q), @ptrFromInt(@as(usize, i) + 1), timerFired);
}

fn timerFired(ctx: ?*anyopaque) callconv(.c) void {
    rt.timer_done(@intCast(@intFromPtr(ctx) - 1));
}

var location_manager: id = null;
var location_delegate: id = null;
var location_on = false;

const CLLocationCoordinate2D = extern struct { lat: f64, lng: f64 };

pub fn location(on: bool) void {
    location_on = on;
    if (location_manager == null) {
        location_manager = objc.new("CLLocationManager");
        location_delegate = objc.new("ZuiLocation");
        objc.sendVoid1(location_manager, "setDelegate:", location_delegate);
        objc.sendVoidFloat(location_manager, "setDesiredAccuracy:", -1); // kCLLocationAccuracyBest
    }
    if (!on) return objc.sendVoid(location_manager, "stopUpdatingLocation");
    // Not determined yet: ask; the answer arrives in locationManagerDidChangeAuthorization.
    if (objc.sendInt(location_manager, "authorizationStatus") == 0) return objc.sendVoid(location_manager, "requestWhenInUseAuthorization");
    locationAuthorization(location_delegate, null, location_manager);
}

fn locationAuthorization(_: id, _: objc.SEL, manager: id) callconv(.c) void {
    if (!location_on) return;
    switch (objc.sendInt(manager, "authorizationStatus")) {
        0 => {},
        1, 2 => rt.location(.denied), // restricted, denied
        else => objc.sendVoid(manager, "startUpdatingLocation"),
    }
}

fn locationUpdated(_: id, _: objc.SEL, _: id, locations: id) callconv(.c) void {
    const l = objc.send(locations, "lastObject");
    if (l == null) return;
    const c = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) CLLocationCoordinate2D)(l, objc.sel("coordinate"));
    const double = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) f64);
    const course = double(l, objc.sel("course"));
    const speed = double(l, objc.sel("speed"));
    rt.location(.{ .fix = .{
        .lat = c.lat,
        .lng = c.lng,
        .accuracy = @floatCast(double(l, objc.sel("horizontalAccuracy"))),
        .heading = if (course >= 0) @floatCast(course) else null,
        .speed = if (speed >= 0) @floatCast(speed) else null,
    } });
}

fn locationFailed(_: id, _: objc.SEL, _: id, err: id) callconv(.c) void {
    // kCLErrorLocationUnknown (0) is temporary: updates keep coming.
    switch (objc.sendInt(err, "code")) {
        0 => {},
        1 => rt.location(.denied),
        else => rt.location(.unavailable),
    }
}

var synthesizer: id = null;

pub fn speak(text_: []const u8, lang: []const u8) void {
    if (synthesizer == null) synthesizer = objc.new("AVSpeechSynthesizer");
    _ = objc.msgSend(*const fn (id, objc.SEL, isize) callconv(.c) bool)(synthesizer, objc.sel("stopSpeakingAtBoundary:"), 0);
    const s = objc.nsString(text_);
    defer objc.release(s);
    const utterance = objc.send1(objc.class("AVSpeechUtterance"), "speechUtteranceWithString:", s);
    const l = objc.nsString(lang);
    defer objc.release(l);
    const voice = objc.send1(objc.class("AVSpeechSynthesisVoice"), "voiceWithLanguage:", l);
    if (voice != null) objc.sendVoid1(utterance, "setVoice:", voice);
    objc.sendVoid1(synthesizer, "speakUtterance:", utterance);
}

/// Kept for sharing; iOS apps have no address bar.
pub fn setLink(_: []const u8) void {}

pub fn focus(i: u32) void {
    _ = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) bool)(view(i), objc.sel("becomeFirstResponder"));
}

test transformMatrix {
    // Rotation alone: (1, 0) turns clockwise to (cos, sin) in y-down coordinates.
    const m = transformMatrix(.{ .rotate = 90 }).m;
    try std.testing.expectApproxEqAbs(@as(f64, 0), m[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1), m[1], 1e-12);
    // Tilt: the top edge (y < 0) moves away from the viewer (z < 0).
    const t = transformMatrix(.{ .tilt = 30 }).m;
    try std.testing.expect(-1 * t[6] < 0);
    // Perspective: m34 = -1/d.
    try std.testing.expectApproxEqAbs(@as(f64, -0.001), transformMatrix(.{ .perspective = 1000 }).m[11], 1e-12);
}

// Web-only for now: there is no embedding page, and WebSockets on the phones come with Reseal's
// chat (a client written for each platform); until then a socket reports itself closed.
pub fn post(_: []const u8) void {}
pub fn openSocket(_: u32, _: []const u8) void {}
pub fn sendSocket(_: u32, _: []const u8) void {}
pub fn closeSocket(_: u32) void {}
