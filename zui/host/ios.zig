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
extern "UIKit" var UIApplicationWillEnterForegroundNotification: id;
extern "UIKit" var UIApplicationDidEnterBackgroundNotification: id;

/// UIControlEventEditingChanged, ...DidBegin, ...DidEnd, ...DidEndOnExit (return key).
const editing_changed: usize = 1 << 17;
const editing_began: usize = 1 << 16;
const editing_ended: usize = 1 << 18;
const editing_return: usize = 1 << 19;

/// Calls: camera, VideoToolbox, AVSampleBufferDisplayLayer, VoiceProcessingIO, Opus through
/// AudioConverter. Used when the app supplies a call engine (`pub const rtc`, zui/calls.zig).
pub const Media = @import("../media/ios.zig");
var calls_enabled = false;

/// A video view shows a stream: the camera preview, or a remote picture.
pub fn video(i: u32, v: zui.Video) void {
    if (calls_enabled) Media.bindView(i, view(i), v);
}

/// The runtime's entry points, for callbacks that arrive from C (GCD, NSURLSession, ...).
var rt: struct {
    fetch_done: *const fn (u32, u16, []const u8) void,
    timer_done: *const fn (u32) void,
    location: *const fn (zui.Location) void,
    socket: *const fn (u32, zui.SocketEvent.Kind, []const u8) void,
    call: *const fn (zui.CallEvent.Kind, []const u8) void,
    device: *const fn (zui.DeviceEvent) void,
    pick: *const fn ([]const u8) void,
} = undefined;
/// NSStringDrawingUsesLineFragmentOrigin
const uses_line_fragment_origin: isize = 1;
/// UIUserInterfaceStyleDark
const style_dark: isize = 2;
/// NSLineBreakByWordWrapping, NSLineBreakByTruncatingTail
const break_word: isize = 0;
const break_tail: isize = 4;

var views: std.ArrayList(id) = .empty;
/// Text areas (UITextView) show their placeholder in a label of their own.
var placeholders: std.ArrayList(id) = .empty;
/// The view controller of the window, which presents pickers.
var root_controller: id = null;
/// Where the last touch went down, in the root view (an iPad popover points there).
var last_touch: objc.CGPoint = .{ .x = 0, .y = 0 };
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
    slot(&placeholders, i);
    placeholders.items[i] = null;
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
        // With a call engine (App.rtc) a video view hosts the camera preview or a remote
        // picture; without one it is an empty box.
        .video => if (calls_enabled) Media.createView() else objc.new("ZuiView"),
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
        .text_area => blk: {
            const tv = objc.new("UITextView");
            objc.sendVoid1(tv, "setDelegate:", target);
            objc.sendVoid1(tv, "setBackgroundColor:", objc.send(objc.class("UIColor"), "clearColor"));
            // Text from the very edge, as zui measured it.
            objc.msgSend(*const fn (id, objc.SEL, objc.UIEdgeInsets) callconv(.c) void)(tv, objc.sel("setTextContainerInset:"), .{ .top = 0, .left = 0, .bottom = 0, .right = 0 });
            objc.sendVoidFloat(objc.send(tv, "textContainer"), "setLineFragmentPadding:", 0);
            const ph = objc.new("UILabel");
            objc.sendVoidInt(ph, "setNumberOfLines:", 0);
            objc.sendVoidBool(ph, "setUserInteractionEnabled:", false);
            objc.sendVoid1(tv, "addSubview:", ph);
            placeholders.items[i] = ph;
            break :blk tv;
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
    if (calls_enabled) Media.unbindView(i);
    const v = view(i);
    objc.sendVoid(v, "removeFromSuperview");
    objc.release(v);
    views.items[i] = null;
    if (image_urls.items[i]) |u| zui.allocator.free(u);
    image_urls.items[i] = null;
    if (contents.items[i] != null) objc.release(contents.items[i]);
    contents.items[i] = null;
    if (placeholders.items[i] != null) objc.release(placeholders.items[i]);
    placeholders.items[i] = null;
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
    placePlaceholder(i);
}

/// A text area's placeholder: at the top, as high as its lines.
fn placePlaceholder(i: u32) void {
    if (i >= placeholders.items.len) return;
    const ph = placeholders.items[i] orelse return;
    const w = frames.items[i].w;
    const fits = objc.msgSend(*const fn (id, objc.SEL, objc.CGSize) callconv(.c) objc.CGSize)(ph, objc.sel("sizeThatFits:"), .{ .w = w, .h = 1e7 });
    const set_frame = objc.msgSend(*const fn (id, objc.SEL, objc.CGRect) callconv(.c) void);
    set_frame(ph, objc.sel("setFrame:"), .{ .w = w, .h = @min(fits.h, frames.items[i].h) });
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
    if (i < placeholders.items.len and placeholders.items[i] != null) return textArea(i, value, placeholder, f, argb, a);
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

/// A UITextView: the same attributes as text views, for what is there and what is typed.
fn textArea(i: u32, value: []const u8, placeholder: []const u8, f: zui.Font, argb: u32, a: zui.PhysicalAlign) void {
    const tv = view(i);
    const attrs = attributes(f, argb, a);
    const current = objc.send(tv, "text");
    const utf8 = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) ?[*:0]const u8)(current, objc.sel("UTF8String"));
    const same = if (utf8) |p| std.mem.eql(u8, std.mem.span(p), value) else value.len == 0;
    if (!same) {
        const str = attributed(value, attrs);
        defer objc.release(str);
        objc.sendVoid1(tv, "setAttributedText:", str);
    }
    objc.sendVoid1(tv, "setTypingAttributes:", attrs);
    objc.sendVoid1(tv, "setTintColor:", color(argb));
    const ph = placeholders.items[i];
    const str = attributed(placeholder, attributes(f, faded(argb), a));
    defer objc.release(str);
    objc.sendVoid1(ph, "setAttributedText:", str);
    objc.sendVoidBool(ph, "setHidden:", value.len > 0);
    placePlaceholder(i);
}

/// Keyboards (tree.Keyboard) and enter keys (tree.ReturnKey) as UIKeyboardType / UIReturnKeyType.
pub fn inputType(i: u32, t: zui.InputType) void {
    const v = view(i);
    const keyboards = [_]isize{ 0, 7, 4, 5, 3, 8 }; // default, email, number pad, phone pad, URL, decimal pad
    const returns = [_]isize{ 0, 9, 1, 4, 6, 7 }; // default, done, go, next, search, send
    objc.sendVoidInt(v, "setKeyboardType:", keyboards[@intFromEnum(t.keyboard)]);
    objc.sendVoidInt(v, "setReturnKeyType:", returns[@intFromEnum(t.return_key)]);
    const plain = t.secure or t.keyboard == .email or t.keyboard == .url;
    objc.sendVoidInt(v, "setAutocapitalizationType:", if (plain) 0 else 2);
    objc.sendVoidInt(v, "setAutocorrectionType:", if (plain) 1 else 0);
    const area = i < placeholders.items.len and placeholders.items[i] != null;
    if (!area) objc.sendVoidBool(v, "setSecureTextEntry:", t.secure);
    objc.sendVoid(v, "reloadInputViews");
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
            rt = .{ .fetch_done = fetchDone, .timer_done = timerDone, .location = locationEvent, .socket = socketEvent, .call = callEvent, .device = deviceEvent, .pick = pickDone };
            if (@hasDecl(App, "rtc")) {
                Media.defineClasses();
                Media.setPump(&R.callsPump);
                calls_enabled = true;
            }
            objc.defineClass("ZuiNotifications", "NSObject", &.{"UNUserNotificationCenterDelegate"}, &.{
                .{ "userNotificationCenter:willPresentNotification:withCompletionHandler:", @ptrCast(&willPresent), "v@:@@@?" },
            });
            objc.defineClass("ZuiCalls", "NSObject", &.{"CXProviderDelegate"}, &.{
                .{ "providerDidReset:", @ptrCast(&providerReset), "v@:@" },
                .{ "provider:performAnswerCallAction:", @ptrCast(&performAnswer), "v@:@@" },
                .{ "provider:performEndCallAction:", @ptrCast(&performEnd), "v@:@@" },
                .{ "provider:performStartCallAction:", @ptrCast(&performStart), "v@:@@" },
            });
            objc.defineClass("ZuiSocketDelegate", "NSObject", &.{"NSURLSessionWebSocketDelegate"}, &.{
                .{ "URLSession:webSocketTask:didOpenWithProtocol:", @ptrCast(&socketOpened), "v@:@@@" },
                .{ "URLSession:webSocketTask:didCloseWithCode:reason:", @ptrCast(&socketClosed), "v@:@@q@" },
                .{ "URLSession:task:didCompleteWithError:", @ptrCast(&taskCompleted), "v@:@@@" },
            });
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
            objc.defineClass("ZuiTarget", "NSObject", &.{"UITextViewDelegate"}, &.{
                .{ "textViewDidChange:", @ptrCast(&textViewChanged), "v@:@" },
                .{ "textViewDidBeginEditing:", @ptrCast(&inputBegan), "v@:@" },
                .{ "textViewDidEndEditing:", @ptrCast(&inputEnded), "v@:@" },
                .{ "pickerDone:", @ptrCast(&pickerDone), "v@:@" },
                .{ "pickerCancel:", @ptrCast(&pickerCancel), "v@:@" },
                .{ "changed:", @ptrCast(&textChanged), "v@:@" },
                .{ "began:", @ptrCast(&inputBegan), "v@:@" },
                .{ "ended:", @ptrCast(&inputEnded), "v@:@" },
                .{ "submitted:", @ptrCast(&inputSubmitted), "v@:@" },
                .{ "frame:", @ptrCast(&displayFrame), "v@:@" },
                .{ "edgeSwipe:", @ptrCast(&edgeSwipe), "v@:@" },
                .{ "appVisible:", @ptrCast(&appVisible), "v@:@" },
                .{ "appHidden:", @ptrCast(&appHidden), "v@:@" },
            });
            return UIApplicationMain(argc, argv, null, objc.nsString("ZuiAppDelegate"));
        }

        fn sceneWillConnect(_: id, _: objc.SEL, scene: id, _: id, _: id) callconv(.c) void {
            target = objc.new("ZuiTarget");
            window = objc.send1(objc.send(objc.class("UIWindow"), "alloc"), "initWithWindowScene:", scene);
            root = objc.new("ZuiRootView");
            const controller = objc.new("UIViewController");
            root_controller = controller;
            objc.sendVoid1(controller, "setView:", root);
            objc.sendVoid1(window, "setRootViewController:", controller);
            objc.sendVoid(window, "makeKeyAndVisible");
            const center = objc.send(objc.class("NSNotificationCenter"), "defaultCenter");
            const observe = objc.msgSend(*const fn (id, objc.SEL, id, objc.SEL, id, id) callconv(.c) void);
            observe(center, objc.sel("addObserver:selector:name:object:"), target, objc.sel("appVisible:"), UIApplicationWillEnterForegroundNotification, null);
            observe(center, objc.sel("addObserver:selector:name:object:"), target, objc.sel("appHidden:"), UIApplicationDidEnterBackgroundNotification, null);
        }

        /// The edge swipe (UIScreenEdgePanGestureRecognizer), once the finger lifts.
        fn edgeSwipe(_: id, _: objc.SEL, gesture: id) callconv(.c) void {
            if (objc.sendInt(gesture, "state") == 3) _ = R.back(); // UIGestureRecognizerStateEnded
        }
        fn appVisible(_: id, _: objc.SEL, _: id) callconv(.c) void {
            R.deviceEvent(.visible);
        }
        fn appHidden(_: id, _: objc.SEL, _: id) callconv(.c) void {
            R.deviceEvent(.hidden);
        }
        fn deviceEvent(e: zui.DeviceEvent) void {
            R.deviceEvent(e);
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
                watchNetwork();
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
        fn socketEvent(i: u32, kind: zui.SocketEvent.Kind, data: []const u8) void {
            R.socketEvent(i, kind, data);
        }
        fn callEvent(kind: zui.CallEvent.Kind, call_id: []const u8) void {
            R.callEvent(kind, call_id);
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
            last_touch = objc.msgSend(*const fn (id, objc.SEL, id) callconv(.c) objc.CGPoint)(objc.send(touches, "anyObject"), objc.sel("locationInView:"), root);
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

        fn textViewChanged(_: id, _: objc.SEL, tv: id) callconv(.c) void {
            const i = tagOf(tv);
            const s = objc.send(tv, "text");
            const utf8 = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) ?[*:0]const u8)(s, objc.sel("UTF8String"));
            const value = if (utf8) |p| std.mem.span(p) else "";
            if (i < placeholders.items.len and placeholders.items[i] != null) objc.sendVoidBool(placeholders.items[i], "setHidden:", value.len > 0);
            R.textEvent(i, value);
        }
        fn pickDone(value: []const u8) void {
            R.pickDone(value);
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
    const owned_url = zui.allocator.dupe(u8, url) catch return zui.allocator.destroy(job);
    job.* = .{ .id = i, .url = owned_url, .filter = f };
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

pub fn fetch(i: u32, method: []const u8, url: []const u8, body: []const u8, content_type: []const u8, headers: []const u8) void {
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
    var lines = std.mem.tokenizeScalar(u8, headers, '\n');
    while (lines.next()) |line| {
        const at = std.mem.indexOf(u8, line, ": ") orelse continue;
        const name = objc.nsString(line[0..at]);
        defer objc.release(name);
        const value = objc.nsString(line[at + 2 ..]);
        defer objc.release(value);
        objc.msgSend(*const fn (id, objc.SEL, id, id) callconv(.c) void)(req, objc.sel("setValue:forHTTPHeaderField:"), value, name);
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

/// There is no embedding page on a phone.
pub fn post(_: []const u8) void {}

/// Location updates go on with the app in the background (the app lists "location" in
/// UIBackgroundModes); iOS shows its blue indicator. Title and text are Android's notification.
pub fn backgroundLocation(on: bool, _: []const u8, _: []const u8) void {
    if (location_manager == null) {
        location_manager = objc.new("CLLocationManager");
        location_delegate = objc.new("ZuiLocation");
        objc.sendVoid1(location_manager, "setDelegate:", location_delegate);
    }
    objc.sendVoidBool(location_manager, "setAllowsBackgroundLocationUpdates:", on);
    objc.sendVoidBool(location_manager, "setShowsBackgroundLocationIndicator:", on);
    objc.sendVoidBool(location_manager, "setPausesLocationUpdatesAutomatically:", !on);
}

// ---- WebSockets: NSURLSessionWebSocketTask, its delegate on the main queue ----

var socket_session: id = null;
/// zui socket id → task (retained).
var socket_tasks: std.AutoHashMapUnmanaged(u32, id) = .empty;

fn socketIdOf(task: id) ?u32 {
    var it = socket_tasks.iterator();
    while (it.next()) |e| if (e.value_ptr.* == task) return e.key_ptr.*;
    return null;
}

/// The handler of receiveMessageWithCompletionHandler: a block capturing the socket id.
const ReceiveBlock = extern struct { header: objc.BlockHeader, socket: u32 };
const receive_descriptor: objc.BlockDescriptor = .{ .size = @sizeOf(ReceiveBlock) };
/// sendMessage:completionHandler: needs a handler; nothing to do in it.
const SendBlock = extern struct { header: objc.BlockHeader };
const send_descriptor: objc.BlockDescriptor = .{ .size = @sizeOf(SendBlock) };
fn sendDone(_: *SendBlock, _: id) callconv(.c) void {}
const send_block: SendBlock = .{ .header = .{ .isa = &objc._NSConcreteGlobalBlock, .invoke = @ptrCast(&sendDone), .descriptor = &send_descriptor } };

pub fn openSocket(i: u32, url: []const u8) void {
    if (socket_session == null) {
        const config = objc.send(objc.class("NSURLSessionConfiguration"), "defaultSessionConfiguration");
        const delegate = objc.new("ZuiSocketDelegate");
        const make = objc.msgSend(*const fn (id, objc.SEL, id, id, id) callconv(.c) id);
        socket_session = objc.send(make(objc.class("NSURLSession"), objc.sel("sessionWithConfiguration:delegate:delegateQueue:"), config, delegate, objc.send(objc.class("NSOperationQueue"), "mainQueue")), "retain");
    }
    const s = objc.nsString(url);
    defer objc.release(s);
    const u = objc.send1(objc.class("NSURL"), "URLWithString:", s);
    if (u == null) return rt.socket(i, .closed, "");
    const task = objc.send(objc.send1(socket_session, "webSocketTaskWithURL:", u), "retain");
    socket_tasks.put(zui.allocator, i, task) catch return;
    objc.sendVoid(task, "resume");
    receiveNext(i, task);
}

fn receiveNext(i: u32, task: id) void {
    const block = zui.allocator.create(ReceiveBlock) catch return;
    block.* = .{ .header = .{ .isa = &objc._NSConcreteGlobalBlock, .invoke = @ptrCast(&received), .descriptor = &receive_descriptor }, .socket = i };
    objc.msgSend(*const fn (id, objc.SEL, *ReceiveBlock) callconv(.c) void)(task, objc.sel("receiveMessageWithCompletionHandler:"), block);
}

/// On the main queue (the session's delegate queue).
fn received(block: *ReceiveBlock, message: id, err: id) callconv(.c) void {
    const i = block.socket;
    zui.allocator.destroy(block);
    const task = socket_tasks.get(i) orelse return;
    if (err != null or message == null) return; // didClose / didComplete report the end
    // NSURLSessionWebSocketMessageTypeString = 1; data messages are taken as UTF-8 text.
    const string = if (objc.sendInt(message, "type") == 1) objc.send(message, "string") else null;
    if (string != null) {
        const p = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) ?[*:0]const u8)(string, objc.sel("UTF8String"));
        rt.socket(i, .message, if (p) |z| std.mem.span(z) else "");
    } else {
        const data = objc.send(message, "data");
        const n: usize = @intCast(objc.sendInt(data, "length"));
        const bytes = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) ?[*]const u8)(data, objc.sel("bytes"));
        rt.socket(i, .message, if (bytes) |b| b[0..n] else "");
    }
    if (socket_tasks.get(i) == task) receiveNext(i, task);
}

fn socketOpened(_: id, _: objc.SEL, _: id, task: id, _: id) callconv(.c) void {
    if (socketIdOf(task)) |i| rt.socket(i, .open, "");
}

fn socketClosed(_: id, _: objc.SEL, _: id, task: id, _: isize, _: id) callconv(.c) void {
    socketEnded(task);
}

fn taskCompleted(_: id, _: objc.SEL, _: id, task: id, _: id) callconv(.c) void {
    socketEnded(task);
}

fn socketEnded(task: id) void {
    const i = socketIdOf(task) orelse return;
    _ = socket_tasks.remove(i);
    objc.release(task);
    rt.socket(i, .closed, "");
}

pub fn sendSocket(i: u32, message: []const u8) void {
    const task = socket_tasks.get(i) orelse return;
    const s = objc.nsString(message);
    defer objc.release(s);
    const msg = objc.send1(objc.send(objc.class("NSURLSessionWebSocketMessage"), "alloc"), "initWithString:", s);
    defer objc.release(msg);
    objc.msgSend(*const fn (id, objc.SEL, id, *const SendBlock) callconv(.c) void)(task, objc.sel("sendMessage:completionHandler:"), msg, &send_block);
}

pub fn closeSocket(i: u32) void {
    const task = socket_tasks.get(i) orelse return;
    _ = socket_tasks.remove(i);
    objc.msgSend(*const fn (id, objc.SEL, isize, id) callconv(.c) void)(task, objc.sel("cancelWithCloseCode:reason:"), 1000, null);
    objc.release(task);
}

pub fn copy(s: []const u8) void {
    const str = objc.nsString(s);
    defer objc.release(str);
    objc.sendVoid1(objc.send(objc.class("UIPasteboard"), "generalPasteboard"), "setString:", str);
}

pub fn openUrl(url: []const u8, _: bool) void {
    const s = objc.nsString(url);
    defer objc.release(s);
    const u = objc.send1(objc.class("NSURL"), "URLWithString:", s);
    if (u == null) return;
    const app = objc.send(objc.class("UIApplication"), "sharedApplication");
    const empty = objc.send(objc.class("NSDictionary"), "dictionary");
    objc.msgSend(*const fn (id, objc.SEL, id, id, ?*anyopaque) callconv(.c) void)(app, objc.sel("openURL:options:completionHandler:"), u, empty, null);
}

// ---- Storage: NSUserDefaults; secure values in the Keychain ----

extern "Security" fn SecItemCopyMatching(query: id, result: *id) i32;
extern "Security" fn SecItemAdd(attributes: id, result: ?*id) i32;
extern "Security" fn SecItemDelete(query: id) i32;
extern "Security" var kSecClass: id;
extern "Security" var kSecClassGenericPassword: id;
extern "Security" var kSecAttrService: id;
extern "Security" var kSecAttrAccount: id;
extern "Security" var kSecValueData: id;
extern "Security" var kSecReturnData: id;
extern "Security" var kSecAttrAccessible: id;
extern "Security" var kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly: id;
extern "CoreFoundation" var kCFBooleanTrue: id;

fn nsDict(keys: []const id, values: []const id) id {
    const make = objc.msgSend(*const fn (id, objc.SEL, [*]const id, [*]const id, usize) callconv(.c) id);
    return make(objc.class("NSDictionary"), objc.sel("dictionaryWithObjects:forKeys:count:"), values.ptr, keys.ptr, keys.len);
}

fn keychainQuery(account: id) [3][2]id {
    const service = objc.send1(objc.class("NSString"), "stringWithUTF8String:", @ptrCast(@constCast("zui")));
    return .{ .{ kSecClass, kSecClassGenericPassword }, .{ kSecAttrService, service }, .{ kSecAttrAccount, account } };
}

fn nsData(bytes: []const u8) id {
    return objc.msgSend(*const fn (id, objc.SEL, [*]const u8, usize) callconv(.c) id)(objc.class("NSData"), objc.sel("dataWithBytes:length:"), bytes.ptr, bytes.len);
}

fn utf8Of(s: id, a: std.mem.Allocator) ?[]u8 {
    const p = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) ?[*:0]const u8)(s, objc.sel("UTF8String")) orelse return null;
    return a.dupe(u8, std.mem.span(p)) catch null;
}

pub fn storageGet(a: std.mem.Allocator, key: []const u8, secure: bool) ?[]u8 {
    const k = objc.nsString(key);
    defer objc.release(k);
    if (!secure) {
        const v = objc.send1(objc.send(objc.class("NSUserDefaults"), "standardUserDefaults"), "stringForKey:", k);
        return if (v != null) utf8Of(v, a) else null;
    }
    const q = keychainQuery(k);
    const query = nsDict(&.{ q[0][0], q[1][0], q[2][0], kSecReturnData }, &.{ q[0][1], q[1][1], q[2][1], kCFBooleanTrue });
    var data: id = null;
    if (SecItemCopyMatching(query, &data) != 0 or data == null) return null;
    defer objc.release(data);
    const n: usize = @intCast(objc.sendInt(data, "length"));
    const bytes = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) ?[*]const u8)(data, objc.sel("bytes")) orelse return null;
    return a.dupe(u8, bytes[0..n]) catch null;
}

pub fn storageSet(key: []const u8, value: []const u8, secure: bool) void {
    const k = objc.nsString(key);
    defer objc.release(k);
    if (!secure) {
        const v = objc.nsString(value);
        defer objc.release(v);
        objc.msgSend(*const fn (id, objc.SEL, id, id) callconv(.c) void)(objc.send(objc.class("NSUserDefaults"), "standardUserDefaults"), objc.sel("setObject:forKey:"), v, k);
        return;
    }
    const q = keychainQuery(k);
    _ = SecItemDelete(nsDict(&.{ q[0][0], q[1][0], q[2][0] }, &.{ q[0][1], q[1][1], q[2][1] }));
    _ = SecItemAdd(nsDict(&.{ q[0][0], q[1][0], q[2][0], kSecValueData, kSecAttrAccessible }, &.{ q[0][1], q[1][1], q[2][1], nsData(value), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }), null);
}

pub fn storageRemove(key: []const u8, secure: bool) void {
    const k = objc.nsString(key);
    defer objc.release(k);
    if (!secure) return objc.sendVoid1(objc.send(objc.class("NSUserDefaults"), "standardUserDefaults"), "removeObjectForKey:", k);
    const q = keychainQuery(k);
    _ = SecItemDelete(nsDict(&.{ q[0][0], q[1][0], q[2][0] }, &.{ q[0][1], q[1][1], q[2][1] }));
}

/// The widget (shells/ios/widget, in apps built with ios_widget) reads these from the app group
/// "group.<bundle id>". Without the widget the lines are kept but nothing shows them.
pub fn widgetUpdate(title: []const u8, l1: []const u8, l2: []const u8, l3: []const u8) void {
    const bundle_id = objc.send(objc.send(objc.class("NSBundle"), "mainBundle"), "bundleIdentifier");
    if (bundle_id == null) return;
    const prefix = objc.nsString("group.");
    defer objc.release(prefix);
    const group = objc.send1(prefix, "stringByAppendingString:", bundle_id);
    const defaults = objc.send1(objc.send(objc.class("NSUserDefaults"), "alloc"), "initWithSuiteName:", group);
    if (defaults == null) return;
    defer objc.release(defaults);
    const keys = [_][]const u8{ "zui_widget_title", "zui_widget_line1", "zui_widget_line2", "zui_widget_line3" };
    for (keys, [_][]const u8{ title, l1, l2, l3 }) |k, v| {
        const key = objc.nsString(k);
        defer objc.release(key);
        const value = objc.nsString(v);
        defer objc.release(value);
        objc.msgSend(*const fn (id, objc.SEL, id, id) callconv(.c) void)(defaults, objc.sel("setObject:forKey:"), value, key);
    }
    // Linked in (shells/ios/widget/ZuiWidgetReload.swift) only when the app has the widget.
    if (widget_reload) |reload| reload();
}
const widget_reload = @extern(?*const fn () callconv(.c) void, .{ .name = "zui_widget_reload", .linkage = .weak });

// ---- Notifications: UNUserNotificationCenter ----

var notify_asked = false;
const AuthBlock = extern struct { header: objc.BlockHeader };
const auth_descriptor: objc.BlockDescriptor = .{ .size = @sizeOf(AuthBlock) };
fn authDone(_: *AuthBlock, _: bool, _: id) callconv(.c) void {}
const auth_block: AuthBlock = .{ .header = .{ .isa = &objc._NSConcreteGlobalBlock, .invoke = @ptrCast(&authDone), .descriptor = &auth_descriptor } };

fn notificationCenter() id {
    const center = objc.send(objc.class("UNUserNotificationCenter"), "currentNotificationCenter");
    if (!notify_asked) {
        notify_asked = true;
        objc.sendVoid1(center, "setDelegate:", objc.new("ZuiNotifications"));
        // UNAuthorizationOptionBadge | Sound | Alert
        objc.msgSend(*const fn (id, objc.SEL, usize, *const AuthBlock) callconv(.c) void)(center, objc.sel("requestAuthorizationWithOptions:completionHandler:"), 1 | 2 | 4, &auth_block);
    }
    return center;
}

/// UNUserNotificationCenterDelegate: show banners while the app is open too. The handler is a
/// block iOS gives us; calling it is calling its invoke function with itself first.
pub fn willPresent(_: id, _: objc.SEL, _: id, _: id, handler: *objc.BlockHeader) callconv(.c) void {
    const invoke: *const fn (*objc.BlockHeader, usize) callconv(.c) void = @ptrCast(@alignCast(handler.invoke));
    invoke(handler, (1 << 1) | (1 << 4) | (1 << 3)); // sound, banner, list
}

pub fn notify(n: zui.Notification) void {
    const center = notificationCenter();
    const note_content = objc.new("UNMutableNotificationContent");
    defer objc.release(note_content);
    const t = objc.nsString(n.title);
    defer objc.release(t);
    const b = objc.nsString(n.body);
    defer objc.release(b);
    objc.sendVoid1(note_content, "setTitle:", t);
    objc.sendVoid1(note_content, "setBody:", b);
    objc.sendVoid1(note_content, "setSound:", objc.send(objc.class("UNNotificationSound"), "defaultSound"));
    // UNNotificationInterruptionLevelTimeSensitive (2) for urgent alerts.
    if (n.urgent) objc.sendVoidInt(note_content, "setInterruptionLevel:", 2);
    var idbuf: [24]u8 = undefined;
    const ident = objc.nsString(std.fmt.bufPrint(&idbuf, "zui-{d}", .{n.id}) catch "zui");
    defer objc.release(ident);
    const make = objc.msgSend(*const fn (id, objc.SEL, id, id, id) callconv(.c) id);
    const request = make(objc.class("UNNotificationRequest"), objc.sel("requestWithIdentifier:content:trigger:"), ident, note_content, null);
    objc.msgSend(*const fn (id, objc.SEL, id, ?*anyopaque) callconv(.c) void)(center, objc.sel("addNotificationRequest:withCompletionHandler:"), request, null);
}

pub fn cancelNotify(i: u32) void {
    const center = notificationCenter();
    var idbuf: [24]u8 = undefined;
    const ident = objc.nsString(std.fmt.bufPrint(&idbuf, "zui-{d}", .{i}) catch "zui");
    defer objc.release(ident);
    const arr = objc.send1(objc.class("NSArray"), "arrayWithObject:", ident);
    objc.sendVoid1(center, "removeDeliveredNotificationsWithIdentifiers:", arr);
    objc.sendVoid1(center, "removePendingNotificationRequestsWithIdentifiers:", arr);
}

// ---- Calls: CallKit ----
// The system's call screen (also on the lock screen), Bluetooth and CarPlay. Each call is an
// NSUUID for CallKit and the app's own id for zui.

const CallEntry = struct { uuid: id, app_id: []u8, incoming: bool, answered: bool = false };
var calls: std.ArrayList(CallEntry) = .empty;
var call_provider: id = null;
var call_controller: id = null;

const CallDoneBlock = extern struct { header: objc.BlockHeader };
const call_done_descriptor: objc.BlockDescriptor = .{ .size = @sizeOf(CallDoneBlock) };
fn callDone(_: *CallDoneBlock, _: id) callconv(.c) void {}
const call_done_block: CallDoneBlock = .{ .header = .{ .isa = &objc._NSConcreteGlobalBlock, .invoke = @ptrCast(&callDone), .descriptor = &call_done_descriptor } };

fn provider() id {
    if (call_provider != null) return call_provider;
    const config = objc.new("CXProviderConfiguration");
    defer objc.release(config);
    objc.sendVoidBool(config, "setSupportsVideo:", true);
    objc.sendVoidInt(config, "setMaximumCallGroups:", 1);
    objc.sendVoidInt(config, "setMaximumCallsPerCallGroup:", 1);
    objc.sendVoidBool(config, "setIncludesCallsInRecents:", false);
    // CXHandleTypeGeneric
    const generic = objc.msgSend(*const fn (id, objc.SEL, isize) callconv(.c) id)(objc.class("NSNumber"), objc.sel("numberWithInteger:"), 1);
    objc.sendVoid1(config, "setSupportedHandleTypes:", objc.send1(objc.class("NSSet"), "setWithObject:", generic));
    call_provider = objc.send1(objc.send(objc.class("CXProvider"), "alloc"), "initWithConfiguration:", config);
    objc.msgSend(*const fn (id, objc.SEL, id, id) callconv(.c) void)(call_provider, objc.sel("setDelegate:queue:"), objc.new("ZuiCalls"), null);
    call_controller = objc.new("CXCallController");
    return call_provider;
}

fn callIndexByUuid(uuid: id) ?usize {
    for (calls.items, 0..) |c, i| {
        if (objc.msgSend(*const fn (id, objc.SEL, id) callconv(.c) bool)(c.uuid, objc.sel("isEqual:"), uuid)) return i;
    }
    return null;
}

fn callIndexById(app_id: []const u8) ?usize {
    for (calls.items, 0..) |c, i| if (std.mem.eql(u8, c.app_id, app_id)) return i;
    return null;
}

fn addCall(app_id: []const u8, incoming: bool) ?id {
    if (callIndexById(app_id) != null) return null;
    const owned = zui.allocator.dupe(u8, app_id) catch return null;
    const uuid = objc.new("NSUUID");
    calls.append(zui.allocator, .{ .uuid = uuid, .app_id = owned, .incoming = incoming }) catch {
        zui.allocator.free(owned);
        objc.release(uuid);
        return null;
    };
    return uuid;
}

fn removeCall(i: usize) void {
    freeCall(calls.orderedRemove(i));
}

fn freeCall(c: CallEntry) void {
    objc.release(c.uuid);
    zui.allocator.free(c.app_id);
}

/// Taken out before the app hears of it, since the app may end calls while handling the event.
fn emitAndRemove(i: usize, kind: zui.CallEvent.Kind) void {
    const c = calls.orderedRemove(i);
    defer freeCall(c);
    rt.call(kind, c.app_id);
}

fn callHandle(app_id: []const u8) id {
    const value = objc.nsString(app_id);
    defer objc.release(value);
    const init = objc.msgSend(*const fn (id, objc.SEL, isize, id) callconv(.c) id);
    return init(objc.send(objc.class("CXHandle"), "alloc"), objc.sel("initWithType:value:"), 1, value);
}

pub fn ringCall(c: zui.Call) void {
    const p = provider();
    const uuid = addCall(c.id, true) orelse return;
    const update = objc.new("CXCallUpdate");
    defer objc.release(update);
    const handle = callHandle(c.id);
    defer objc.release(handle);
    const name = objc.nsString(c.name);
    defer objc.release(name);
    objc.sendVoid1(update, "setRemoteHandle:", handle);
    objc.sendVoid1(update, "setLocalizedCallerName:", name);
    objc.sendVoidBool(update, "setHasVideo:", c.video);
    const report = objc.msgSend(*const fn (id, objc.SEL, id, id, *const CallDoneBlock) callconv(.c) void);
    report(p, objc.sel("reportNewIncomingCallWithUUID:update:completion:"), uuid, update, &call_done_block);
}

pub fn startCall(c: zui.Call) void {
    _ = provider();
    const uuid = addCall(c.id, false) orelse return;
    const handle = callHandle(c.id);
    defer objc.release(handle);
    const action = objc.msgSend(*const fn (id, objc.SEL, id, id) callconv(.c) id)(objc.send(objc.class("CXStartCallAction"), "alloc"), objc.sel("initWithCallUUID:handle:"), uuid, handle);
    defer objc.release(action);
    objc.sendVoidBool(action, "setVideo:", c.video);
    const name = objc.nsString(c.name);
    defer objc.release(name);
    objc.sendVoid1(action, "setContactIdentifier:", name);
    const transaction = objc.send1(objc.send(objc.class("CXTransaction"), "alloc"), "initWithAction:", action);
    defer objc.release(transaction);
    objc.msgSend(*const fn (id, objc.SEL, id, *const CallDoneBlock) callconv(.c) void)(call_controller, objc.sel("requestTransaction:completion:"), transaction, &call_done_block);
}

pub fn callConnected(app_id: []const u8) void {
    const i = callIndexById(app_id) orelse return;
    if (calls.items[i].incoming) return;
    objc.msgSend(*const fn (id, objc.SEL, id, id) callconv(.c) void)(provider(), objc.sel("reportOutgoingCallWithUUID:connectedAtDate:"), calls.items[i].uuid, null);
}

/// The app ended it: CallKit is told, no event comes back.
pub fn endCall(app_id: []const u8) void {
    const i = callIndexById(app_id) orelse return;
    // CXCallEndedReasonRemoteEnded
    objc.msgSend(*const fn (id, objc.SEL, id, id, isize) callconv(.c) void)(provider(), objc.sel("reportCallWithUUID:endedAtDate:reason:"), calls.items[i].uuid, null, 2);
    removeCall(i);
}

fn providerReset(_: id, _: objc.SEL, _: id) callconv(.c) void {
    while (calls.items.len > 0) {
        emitAndRemove(calls.items.len - 1, .end);
    }
}

fn performAnswer(_: id, _: objc.SEL, _: id, action: id) callconv(.c) void {
    if (callIndexByUuid(objc.send(action, "callUUID"))) |i| {
        calls.items[i].answered = true;
        // A copy: the app may end the call while handling the event.
        var buf: [256]u8 = undefined;
        const n = @min(buf.len, calls.items[i].app_id.len);
        @memcpy(buf[0..n], calls.items[i].app_id[0..n]);
        rt.call(.answer, buf[0..n]);
    }
    objc.sendVoid(action, "fulfill");
}

fn performEnd(_: id, _: objc.SEL, _: id, action: id) callconv(.c) void {
    if (callIndexByUuid(objc.send(action, "callUUID"))) |i| {
        const c = calls.items[i];
        emitAndRemove(i, if (c.incoming and !c.answered) .decline else .end);
    }
    objc.sendVoid(action, "fulfill");
}

fn performStart(_: id, _: objc.SEL, p: id, action: id) callconv(.c) void {
    objc.msgSend(*const fn (id, objc.SEL, id, id) callconv(.c) void)(p, objc.sel("reportOutgoingCallWithUUID:startedConnectingAtDate:"), objc.send(action, "callUUID"), null);
    objc.sendVoid(action, "fulfill");
}

// ---- The device: clock, Back, screen, vibration and sound, the network ----

const clock = @import("../platform/clock.zig");
pub const now = clock.now;
pub const tzOffset = clock.tzOffset;

extern "c" fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
/// RTLD_DEFAULT on Darwin.
const rtld_default: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));

/// A function of a system framework zui does not link (AudioToolbox, Network), or null.
fn systemFunction(comptime F: type, framework: [*:0]const u8, name: [*:0]const u8) ?F {
    _ = dlopen(framework, 1); // RTLD_LAZY; already loaded is fine
    const f = dlsym(rtld_default, name) orelse return null;
    return @ptrCast(@alignCast(f));
}

fn systemSound(sound: u32) void {
    const S = struct {
        var play: ?*const fn (u32) callconv(.c) void = null;
        var looked = false;
    };
    if (!S.looked) {
        S.looked = true;
        S.play = systemFunction(*const fn (u32) callconv(.c) void, "/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", "AudioServicesPlaySystemSound");
    }
    if (S.play) |play| play(sound);
}

/// iPhones have one vibration (kSystemSoundID_Vibrate); its length is fixed.
pub fn vibrate(_: u32) void {
    systemSound(4095);
}

/// The system's short "tink".
pub fn beep() void {
    systemSound(1057);
}

pub fn keepAwake(on: bool) void {
    objc.sendVoidBool(objc.send(objc.class("UIApplication"), "sharedApplication"), "setIdleTimerDisabled:", on);
}

var edge_swipe: id = null;

/// Back on iOS is the swipe in from the leading edge, enabled while the app handles it.
pub fn backState(handler: bool, has_history: bool, rtl: bool) void {
    if (edge_swipe == null) {
        const make = objc.msgSend(*const fn (id, objc.SEL, id, objc.SEL) callconv(.c) id);
        edge_swipe = make(objc.send(objc.class("UIScreenEdgePanGestureRecognizer"), "alloc"), objc.sel("initWithTarget:action:"), target, objc.sel("edgeSwipe:"));
        objc.sendVoid1(root, "addGestureRecognizer:", edge_swipe);
    }
    objc.sendVoidInt(edge_swipe, "setEdges:", if (rtl) 8 else 2); // UIRectEdgeRight / UIRectEdgeLeft
    objc.sendVoidBool(edge_swipe, "setEnabled:", handler or has_history);
}

// The network through Network.framework's path monitor, on the main queue.
const PathBlock = extern struct { header: objc.BlockHeader };
const path_descriptor: objc.BlockDescriptor = .{ .size = @sizeOf(PathBlock) };
const path_block: PathBlock = .{ .header = .{ .isa = &objc._NSConcreteGlobalBlock, .invoke = @ptrCast(&pathChanged), .descriptor = &path_descriptor } };
var path_status: ?*const fn (?*anyopaque) callconv(.c) c_int = null;
var was_online = true;

fn watchNetwork() void {
    const lib = "/System/Library/Frameworks/Network.framework/Network";
    const make = systemFunction(*const fn () callconv(.c) ?*anyopaque, lib, "nw_path_monitor_create") orelse return;
    const set_queue = systemFunction(*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void, lib, "nw_path_monitor_set_queue") orelse return;
    const set_handler = systemFunction(*const fn (?*anyopaque, *const PathBlock) callconv(.c) void, lib, "nw_path_monitor_set_update_handler") orelse return;
    const start = systemFunction(*const fn (?*anyopaque) callconv(.c) void, lib, "nw_path_monitor_start") orelse return;
    path_status = systemFunction(*const fn (?*anyopaque) callconv(.c) c_int, lib, "nw_path_get_status") orelse return;
    const monitor = make() orelse return;
    set_queue(monitor, @ptrCast(&_dispatch_main_q));
    set_handler(monitor, &path_block);
    start(monitor);
}

fn pathChanged(_: *const PathBlock, nw_path: ?*anyopaque) callconv(.c) void {
    const status = path_status orelse return;
    const online = status(nw_path) == 1; // nw_path_status_satisfied
    if (online == was_online) return;
    was_online = online;
    rt.device(if (online) .online else .offline);
}

// ---- Pickers: UIDatePicker in a sheet, an action sheet of options ----

var picker_sheet: id = null;
var date_picker: id = null;
var picking_date = true;

/// An NSDateFormatter for fixed formats ("yyyy-MM-dd"), +1 retained.
fn posixFormatter(format: []const u8) id {
    const f = objc.new("NSDateFormatter");
    const ident = objc.nsString("en_US_POSIX");
    defer objc.release(ident);
    objc.sendVoid1(f, "setLocale:", objc.send1(objc.class("NSLocale"), "localeWithLocaleIdentifier:", ident));
    const fmt = objc.nsString(format);
    defer objc.release(fmt);
    objc.sendVoid1(f, "setDateFormat:", fmt);
    return f;
}

fn parseDate(formatter: id, s: []const u8) id {
    if (s.len == 0) return null;
    const str = objc.nsString(s);
    defer objc.release(str);
    return objc.send1(formatter, "dateFromString:", str);
}

fn barButton(system_item: isize, action: ?[*:0]const u8) id {
    const make = objc.msgSend(*const fn (id, objc.SEL, isize, id, objc.SEL) callconv(.c) id);
    return make(objc.send(objc.class("UIBarButtonItem"), "alloc"), objc.sel("initWithBarButtonSystemItem:target:action:"), system_item, if (action != null) target else null, if (action) |a| objc.sel(a) else null);
}

pub fn pick(kind: zui.PickKind, value: []const u8, min: []const u8, max: []const u8, title: []const u8, options: []const u8, selected: i32) void {
    if (root_controller == null) return;
    if (kind == .option) return pickOption(title, options, selected);
    if (picker_sheet != null) return;
    picking_date = kind == .date;
    const vc = objc.new("UIViewController");
    const v = objc.send(vc, "view");
    objc.sendVoid1(v, "setBackgroundColor:", objc.send(objc.class("UIColor"), "systemBackgroundColor"));

    const dp = objc.new("UIDatePicker");
    objc.sendVoidInt(dp, "setDatePickerMode:", if (picking_date) 1 else 0); // date / time
    objc.sendVoidInt(dp, "setPreferredDatePickerStyle:", if (picking_date) 3 else 1); // inline / wheels
    const formatter = posixFormatter(if (picking_date) "yyyy-MM-dd" else "HH:mm");
    defer objc.release(formatter);
    if (parseDate(formatter, value)) |d| objc.sendVoid1(dp, "setDate:", d);
    if (parseDate(formatter, min)) |d| objc.sendVoid1(dp, "setMinimumDate:", d);
    if (parseDate(formatter, max)) |d| objc.sendVoid1(dp, "setMaximumDate:", d);

    // Cancel and Done from the system, in the system's language.
    const bar = objc.new("UIToolbar");
    const cancel = barButton(1, "pickerCancel:");
    defer objc.release(cancel);
    const space = barButton(5, null);
    defer objc.release(space);
    const done = barButton(0, "pickerDone:");
    defer objc.release(done);
    var items = [_]id{ cancel, space, done };
    const array = objc.msgSend(*const fn (id, objc.SEL, [*]id, usize) callconv(.c) id)(objc.class("NSArray"), objc.sel("arrayWithObjects:count:"), &items, items.len);
    objc.sendVoid1(bar, "setItems:", array);

    const bounds = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) objc.CGRect)(root, objc.sel("bounds"));
    const set_frame = objc.msgSend(*const fn (id, objc.SEL, objc.CGRect) callconv(.c) void);
    set_frame(bar, objc.sel("setFrame:"), .{ .w = bounds.w, .h = 44 });
    set_frame(dp, objc.sel("setFrame:"), .{ .y = 44, .w = bounds.w, .h = if (picking_date) 380 else 216 });
    objc.sendVoidInt(bar, "setAutoresizingMask:", 2); // flexible width
    objc.sendVoidInt(dp, "setAutoresizingMask:", 2);
    objc.sendVoid1(v, "addSubview:", bar);
    objc.sendVoid1(v, "addSubview:", dp);
    objc.release(bar);

    const sheet = objc.send(vc, "sheetPresentationController");
    if (sheet != null) {
        const detent = objc.class("UISheetPresentationControllerDetent");
        var detents = [_]id{ objc.send(detent, "mediumDetent"), objc.send(detent, "largeDetent") };
        objc.sendVoid1(sheet, "setDetents:", objc.msgSend(*const fn (id, objc.SEL, [*]id, usize) callconv(.c) id)(objc.class("NSArray"), objc.sel("arrayWithObjects:count:"), &detents, if (picking_date) 2 else 1));
        objc.sendVoidBool(sheet, "setPrefersGrabberVisible:", true);
    }
    picker_sheet = vc;
    date_picker = dp;
    present(vc);
}

fn present(vc: id) void {
    objc.msgSend(*const fn (id, objc.SEL, id, bool, ?*anyopaque) callconv(.c) void)(root_controller, objc.sel("presentViewController:animated:completion:"), vc, true, null);
}

fn closePicker() void {
    objc.msgSend(*const fn (id, objc.SEL, bool, ?*anyopaque) callconv(.c) void)(root_controller, objc.sel("dismissViewControllerAnimated:completion:"), true, null);
    if (date_picker != null) objc.release(date_picker);
    if (picker_sheet != null) objc.release(picker_sheet);
    date_picker = null;
    picker_sheet = null;
}

fn pickerDone(_: id, _: objc.SEL, _: id) callconv(.c) void {
    if (date_picker == null) return;
    const formatter = posixFormatter(if (picking_date) "yyyy-MM-dd" else "HH:mm");
    defer objc.release(formatter);
    const str = objc.send1(formatter, "stringFromDate:", objc.send(date_picker, "date"));
    var buf: [32]u8 = undefined;
    const utf8 = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) ?[*:0]const u8)(str, objc.sel("UTF8String"));
    const value = if (utf8) |p| std.mem.span(p) else "";
    const n = @min(value.len, buf.len);
    @memcpy(buf[0..n], value[0..n]);
    closePicker();
    rt.pick(buf[0..n]);
}

fn pickerCancel(_: id, _: objc.SEL, _: id) callconv(.c) void {
    closePicker();
}

/// The handler of each option's UIAlertAction: a block capturing the option's index.
const OptionBlock = extern struct { header: objc.BlockHeader, index: i32 };
const option_descriptor: objc.BlockDescriptor = .{ .size = @sizeOf(OptionBlock) };
var option_blocks: std.ArrayList(*OptionBlock) = .empty;

fn optionChosen(block: *OptionBlock, _: id) callconv(.c) void {
    if (block.index < 0) return;
    var buf: [12]u8 = undefined;
    rt.pick(std.fmt.bufPrint(&buf, "{d}", .{block.index}) catch return);
}

fn optionBlock(index: i32) ?*OptionBlock {
    const b = zui.allocator.create(OptionBlock) catch return null;
    b.* = .{ .header = .{ .isa = &objc._NSConcreteGlobalBlock, .invoke = @ptrCast(&optionChosen), .descriptor = &option_descriptor }, .index = index };
    option_blocks.append(zui.allocator, b) catch {
        zui.allocator.destroy(b);
        return null;
    };
    return b;
}

fn pickOption(title: []const u8, options: []const u8, selected: i32) void {
    // The blocks of the last list are no longer called.
    for (option_blocks.items) |b| zui.allocator.destroy(b);
    option_blocks.clearRetainingCapacity();
    const t = if (title.len > 0) objc.nsString(title) else null;
    defer if (t != null) objc.release(t);
    const make = objc.msgSend(*const fn (id, objc.SEL, id, id, isize) callconv(.c) id);
    const sheet = make(objc.class("UIAlertController"), objc.sel("alertControllerWithTitle:message:preferredStyle:"), t, null, 0); // action sheet
    const action = objc.msgSend(*const fn (id, objc.SEL, id, isize, ?*OptionBlock) callconv(.c) id);
    var lines = std.mem.splitScalar(u8, options, '\n');
    var index: i32 = 0;
    while (lines.next()) |line| : (index += 1) {
        const label = objc.nsString(line);
        defer objc.release(label);
        const a = action(objc.class("UIAlertAction"), objc.sel("actionWithTitle:style:handler:"), label, 0, optionBlock(index));
        objc.sendVoid1(sheet, "addAction:", a);
        if (index == selected) objc.sendVoid1(sheet, "setPreferredAction:", a);
    }
    // "Cancel" in the system's language, from UIKit's own strings.
    const uikit = objc.send1(objc.class("NSBundle"), "bundleForClass:", objc.class("UIApplication"));
    const key = objc.nsString("Cancel");
    defer objc.release(key);
    const cancel = objc.msgSend(*const fn (id, objc.SEL, id, id, id) callconv(.c) id)(uikit, objc.sel("localizedStringForKey:value:table:"), key, key, null);
    objc.sendVoid1(sheet, "addAction:", action(objc.class("UIAlertAction"), objc.sel("actionWithTitle:style:handler:"), cancel, 1, null));
    // iPad: a popover pointing at the last touch.
    const popover = objc.send(sheet, "popoverPresentationController");
    if (popover != null) {
        objc.sendVoid1(popover, "setSourceView:", root);
        objc.msgSend(*const fn (id, objc.SEL, objc.CGRect) callconv(.c) void)(popover, objc.sel("setSourceRect:"), .{ .x = last_touch.x, .y = last_touch.y, .w = 1, .h = 1 });
    }
    present(sheet);
}
