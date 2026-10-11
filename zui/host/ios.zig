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
/// Views that report raw pointer events (gestures).
var pointers: std.ArrayList(bool) = .empty;
/// The URL each image view should show (allocator-owned), so a late download for an old URL is
/// dropped.
var image_urls: std.ArrayList(?[]u8) = .empty;
var image_cache: id = null;
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
    const f = objc.msgSend(*const fn (id, objc.SEL, id, isize) callconv(.c) void);
    f(container(parent), objc.sel("insertSubview:atIndex:"), view(i), @intCast(index));
}

/// Bounds and centre rather than frame: a view with a 3D transform (the map layer) has no
/// well-defined frame.
pub fn frame(i: u32, r: zui.Rect) void {
    const v = view(i);
    const set_bounds = objc.msgSend(*const fn (id, objc.SEL, objc.CGRect) callconv(.c) void);
    set_bounds(v, objc.sel("setBounds:"), .{ .w = r.w, .h = r.h });
    const set_center = objc.msgSend(*const fn (id, objc.SEL, objc.CGPoint) callconv(.c) void);
    set_center(v, objc.sel("setCenter:"), .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 });
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
            R.frame();
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
            const location = objc.msgSend(*const fn (id, objc.SEL, id) callconv(.c) objc.CGPoint);
            const timestamp = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) f64);
            for (0..n) |k| {
                const touch = at(all, objc.sel("objectAtIndex:"), k);
                const p = location(touch, objc.sel("locationInView:"), self);
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

const ImageJob = struct { id: u32, url: []u8, image: id = null };

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
    const key = objc.nsString(url);
    defer objc.release(key);
    const cached = objc.send1(image_cache, "objectForKey:", key);
    objc.sendVoid1(view(i), "setImage:", cached);
    if (cached != null) return;

    const job = zui.allocator.create(ImageJob) catch return;
    const copy = zui.allocator.dupe(u8, url) catch return zui.allocator.destroy(job);
    job.* = .{ .id = i, .url = copy };
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
            if (img != null) job.image = objc.send(img, "retain");
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
    const key = objc.nsString(job.url);
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
extern "QuartzCore" var kCALineCapRound: id;
extern "QuartzCore" var kCALineCapButt: id;
extern "QuartzCore" var kCALineJoinRound: id;
extern "QuartzCore" var kCALineJoinMiter: id;

pub fn path(i: u32, p: zui.Path) void {
    const layer = objc.send(view(i), "layer");
    const cg = CGPathCreateMutable();
    defer CGPathRelease(cg);
    for (p.points, 0..) |pt, k| {
        if (k == 0) CGPathMoveToPoint(cg, null, pt[0], pt[1]) else CGPathAddLineToPoint(cg, null, pt[0], pt[1]);
    }
    const set_ptr = objc.msgSend(*const fn (id, objc.SEL, ?*anyopaque) callconv(.c) void);
    set_ptr(layer, objc.sel("setPath:"), cg);
    set_ptr(layer, objc.sel("setStrokeColor:"), @ptrCast(objc.send(color(p.color), "CGColor")));
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
