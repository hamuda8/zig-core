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
    if (Messages.bindView(i, view(i), v)) return;
    if (calls_enabled) Media.bindView(i, view(i), v);
}

/// Voice and video messages: recording and playback (AVAudioRecorder, AVCaptureMovieFileOutput,
/// AVPlayer). A video view showing a recorder or a player is handled there.
const Messages = @import("../media/ios_messages.zig");
pub const startRecording = Messages.startRecording;
pub const stopRecording = Messages.stopRecording;
pub const play = Messages.play;
pub const controlPlayback = Messages.controlPlayback;

/// The runtime's entry points, for callbacks that arrive from C (GCD, NSURLSession, ...).
var rt: struct {
    fetch_done: *const fn (u32, u16, []const u8) void,
    timer_done: *const fn (u32) void,
    location: *const fn (zui.Location) void,
    socket: *const fn (u32, zui.SocketEvent.Kind, []const u8) void,
    call: *const fn (zui.CallEvent.Kind, []const u8) void,
    device: *const fn (zui.DeviceEvent) void,
    pick: *const fn ([]const u8) void,
    file: *const fn ([]const u8, []const u8, []const u8, u32, u32) void,
    stream_status: *const fn (u32, u16) void,
    stream_data: *const fn (u32, []const u8) void,
    stream_end: *const fn (u32) void,
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
        .text_select => styleSelectable(),
        .text => blk: {
            const l = objc.new("ZuiLabel");
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
    styleCreated(i, kind, v);
}

pub fn destroy(i: u32) void {
    Messages.unbindView(i);
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
    if (styleFrame(i, r)) return;
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
    const old_alpha = alphaOf(v);
    defer styleBox(i, b, old_alpha);
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
    if (f.letter_spacing != 0) return richText(i, s, &.{}, f, argb, a);
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
    if (f.letter_spacing != 0) return measureRich(s, &.{}, f, max_width);
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
            rt = .{ .fetch_done = fetchDone, .timer_done = timerDone, .location = locationEvent, .socket = socketEvent, .call = callEvent, .device = deviceEvent, .pick = pickDone, .file = fileDone, .stream_status = streamStatus, .stream_data = streamData, .stream_end = streamEnd };
            Messages.init(&R.recordEvent, &R.playEvent);
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
            objc.defineClass("ZuiStreamDelegate", "NSObject", &.{"NSURLSessionDataDelegate"}, &.{
                .{ "URLSession:dataTask:didReceiveResponse:completionHandler:", @ptrCast(&streamResponse), "v@:@@@@?" },
                .{ "URLSession:dataTask:didReceiveData:", @ptrCast(&streamReceived), "v@:@@@" },
                .{ "URLSession:task:didCompleteWithError:", @ptrCast(&streamCompleted), "v@:@@@" },
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
            objc.defineClass("ZuiTarget", "NSObject", &.{ "UITextViewDelegate", "UIImagePickerControllerDelegate", "UINavigationControllerDelegate", "UIDocumentPickerDelegate" }, &.{
                .{ "imagePickerController:didFinishPickingMediaWithInfo:", @ptrCast(&photoPicked), "v@:@@" },
                .{ "imagePickerControllerDidCancel:", @ptrCast(&photoCancelled), "v@:@" },
                .{ "documentPicker:didPickDocumentsAtURLs:", @ptrCast(&documentsPicked), "v@:@@" },
                .{ "documentPickerWasCancelled:", @ptrCast(&documentsCancelled), "v@:@" },
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
            styleInit(R);
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
        fn streamStatus(conn: u32, status: u16) void {
            R.streamStatus(conn, status);
        }
        fn streamData(conn: u32, bytes: []const u8) void {
            R.streamData(conn, bytes);
        }
        fn streamEnd(conn: u32) void {
            R.streamEnd(conn);
        }
        fn fileDone(data: []const u8, name: []const u8, mime: []const u8, w: u32, h: u32) void {
            R.fileDone(data, name, mime, w, h);
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

const ImageJob = struct { id: u32, url: []u8, headers: []u8 = &.{}, image: id = null, filter: zui.ImageFilter = .{} };

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
pub fn image(i: u32, url: []const u8, headers: []const u8) void {
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
    job.* = .{ .id = i, .url = owned_url, .headers = zui.allocator.dupe(u8, headers) catch &.{}, .filter = f };
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
        // Headers (a Bearer token) need a request of their own.
        const owned = if (job.headers.len > 0) getWithHeaders(job.url, job.headers) else null;
        defer if (owned != null) objc.release(owned);
        const data = if (job.headers.len > 0) owned else objc.send1(objc.class("NSData"), "dataWithContentsOfURL:", url);
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
        zui.allocator.free(job.headers);
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
    if (S.play) |play_sound| play_sound(sound);
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

// ---- Photos and files: UIImagePickerController, UIDocumentPickerViewController, the share sheet ----

extern "UIKit" var UIImagePickerControllerOriginalImage: id;
extern "UIKit" fn UIGraphicsBeginImageContextWithOptions(size: objc.CGSize, is_opaque: bool, scale: CGFloat) void;
extern "UIKit" fn UIGraphicsGetImageFromCurrentImageContext() id;
extern "UIKit" fn UIGraphicsEndImageContext() void;
extern "UIKit" fn UIImageJPEGRepresentation(image: id, quality: CGFloat) id;
extern "Foundation" fn NSTemporaryDirectory() id;

var photo_max: u32 = 1600;
var photo_quality: u8 = 85;

fn stringOf(s: id) []const u8 {
    if (s == null) return "";
    const p = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) ?[*:0]const u8)(s, objc.sel("UTF8String")) orelse return "";
    return std.mem.span(p);
}

fn dataBytes(data: id) []const u8 {
    if (data == null) return "";
    const n: usize = @intCast(objc.sendInt(data, "length"));
    const bytes = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) ?[*]const u8)(data, objc.sel("bytes")) orelse return "";
    return bytes[0..n];
}

/// Points an iPad popover at the last touch (phones show the controller as a sheet).
fn anchorPopover(controller: id) void {
    const popover = objc.send(controller, "popoverPresentationController");
    if (popover == null) return;
    objc.sendVoid1(popover, "setSourceView:", root);
    objc.msgSend(*const fn (id, objc.SEL, objc.CGRect) callconv(.c) void)(popover, objc.sel("setSourceRect:"), .{ .x = last_touch.x, .y = last_touch.y, .w = 1, .h = 1 });
}

pub fn pickPhoto(camera: bool, max_size: u32, quality: u8) void {
    if (root_controller == null) return;
    photo_max = max_size;
    photo_quality = quality;
    const cls = objc.class("UIImagePickerController");
    const available = objc.msgSend(*const fn (id, objc.SEL, isize) callconv(.c) bool)(cls, objc.sel("isSourceTypeAvailable:"), 1);
    const picker = objc.new("UIImagePickerController");
    defer objc.release(picker);
    objc.sendVoidInt(picker, "setSourceType:", if (camera and available) 1 else 0); // camera / photo library
    objc.sendVoid1(picker, "setDelegate:", target);
    anchorPopover(picker);
    present(picker);
}

fn dismissPicker(picker: id) void {
    objc.msgSend(*const fn (id, objc.SEL, bool, ?*anyopaque) callconv(.c) void)(picker, objc.sel("dismissViewControllerAnimated:completion:"), true, null);
}

/// The photo, drawn upright at the size wanted, as JPEG.
fn photoPicked(_: id, _: objc.SEL, picker: id, info: id) callconv(.c) void {
    dismissPicker(picker);
    const img = objc.send1(info, "objectForKey:", UIImagePickerControllerOriginalImage);
    if (img == null) return;
    const size = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) objc.CGSize)(img, objc.sel("size"));
    if (size.w <= 0 or size.h <= 0) return;
    const k = @min(1.0, @as(CGFloat, @floatFromInt(photo_max)) / @max(size.w, size.h));
    const w = @max(1, @round(size.w * k));
    const h = @max(1, @round(size.h * k));
    UIGraphicsBeginImageContextWithOptions(.{ .w = w, .h = h }, true, 1);
    objc.msgSend(*const fn (id, objc.SEL, objc.CGRect) callconv(.c) void)(img, objc.sel("drawInRect:"), .{ .w = w, .h = h });
    const scaled = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (scaled == null) return;
    const jpeg = UIImageJPEGRepresentation(scaled, @as(CGFloat, @floatFromInt(photo_quality)) / 100);
    rt.file(dataBytes(jpeg), "photo.jpg", "image/jpeg", @intFromFloat(w), @intFromFloat(h));
}

fn photoCancelled(_: id, _: objc.SEL, picker: id) callconv(.c) void {
    dismissPicker(picker);
}

fn utType(identifier: []const u8) id {
    const s = objc.nsString(identifier);
    defer objc.release(s);
    return objc.send1(objc.class("UTType"), "typeWithIdentifier:", s);
}

pub fn pickFile(accept: []const u8) void {
    if (root_controller == null) return;
    _ = dlopen("/System/Library/Frameworks/UniformTypeIdentifiers.framework/UniformTypeIdentifiers", 1);
    const types = objc.send(objc.class("NSMutableArray"), "array");
    var parts = std.mem.tokenizeScalar(u8, accept, ',');
    while (parts.next()) |raw| {
        const t = std.mem.trim(u8, raw, " ");
        var ty: id = null;
        if (std.mem.endsWith(u8, t, "/*")) {
            const family = t[0 .. t.len - 2];
            ty = utType(if (std.mem.eql(u8, family, "image")) "public.image" else if (std.mem.eql(u8, family, "video")) "public.movie" else if (std.mem.eql(u8, family, "audio")) "public.audio" else if (std.mem.eql(u8, family, "text")) "public.text" else "public.item");
        } else if (std.mem.startsWith(u8, t, ".")) {
            const ext = objc.nsString(t[1..]);
            defer objc.release(ext);
            ty = objc.send1(objc.class("UTType"), "typeWithFilenameExtension:", ext);
        } else if (std.mem.indexOfScalar(u8, t, '/') != null) {
            const m = objc.nsString(t);
            defer objc.release(m);
            ty = objc.send1(objc.class("UTType"), "typeWithMIMEType:", m);
        }
        if (ty != null) objc.sendVoid1(types, "addObject:", ty);
    }
    if (objc.sendInt(types, "count") == 0) objc.sendVoid1(types, "addObject:", utType("public.item"));
    const make = objc.msgSend(*const fn (id, objc.SEL, id, bool) callconv(.c) id);
    const picker = make(objc.send(objc.class("UIDocumentPickerViewController"), "alloc"), objc.sel("initForOpeningContentTypes:asCopy:"), types, true);
    defer objc.release(picker);
    objc.sendVoid1(picker, "setDelegate:", target);
    present(picker);
}

fn documentsPicked(_: id, _: objc.SEL, _: id, urls: id) callconv(.c) void {
    const url = objc.send(urls, "firstObject");
    if (url == null) return;
    const data = objc.send1(objc.class("NSData"), "dataWithContentsOfURL:", url);
    if (data == null) return;
    const ty = objc.send1(objc.class("UTType"), "typeWithFilenameExtension:", objc.send(url, "pathExtension"));
    const mime = if (ty != null) stringOf(objc.send(ty, "preferredMIMEType")) else "";
    rt.file(dataBytes(data), stringOf(objc.send(url, "lastPathComponent")), if (mime.len > 0) mime else "application/octet-stream", 0, 0);
}

fn documentsCancelled(_: id, _: objc.SEL, _: id) callconv(.c) void {}

/// A file in the temporary folder, offered by the share sheet (which also saves to Files).
pub fn saveFile(name: []const u8, _: []const u8, data: []const u8, _: bool) void {
    if (root_controller == null) return;
    const n = objc.nsString(if (name.len > 0) name else "file");
    defer objc.release(n);
    const file_path = objc.send1(NSTemporaryDirectory(), "stringByAppendingPathComponent:", n);
    if (!objc.msgSend(*const fn (id, objc.SEL, id, bool) callconv(.c) bool)(nsData(data), objc.sel("writeToFile:atomically:"), file_path, true)) return;
    const url = objc.send1(objc.class("NSURL"), "fileURLWithPath:", file_path);
    const items = objc.send1(objc.class("NSArray"), "arrayWithObject:", url);
    const make = objc.msgSend(*const fn (id, objc.SEL, id, id) callconv(.c) id);
    const sheet = make(objc.send(objc.class("UIActivityViewController"), "alloc"), objc.sel("initWithActivityItems:applicationActivities:"), items, null);
    defer objc.release(sheet);
    anchorPopover(sheet);
    present(sheet);
}

// ---- Requests with headers, for images; event streams (NSURLSession's data delegate) ----

extern "c" fn dispatch_semaphore_create(value: isize) ?*anyopaque;
extern "c" fn dispatch_semaphore_wait(sem: ?*anyopaque, timeout: u64) isize;
extern "c" fn dispatch_semaphore_signal(sem: ?*anyopaque) isize;
extern "c" fn dispatch_release(object: ?*anyopaque) void;

/// An NSMutableURLRequest for `url` with "name: value\n" header lines, or null.
fn requestWith(url: []const u8, headers: []const u8) id {
    const s = objc.nsString(url);
    defer objc.release(s);
    const nsurl = objc.send1(objc.class("NSURL"), "URLWithString:", s);
    if (nsurl == null) return null;
    const req = objc.send1(objc.class("NSMutableURLRequest"), "requestWithURL:", nsurl);
    var lines = std.mem.tokenizeScalar(u8, headers, '\n');
    while (lines.next()) |line| {
        const at = std.mem.indexOf(u8, line, ": ") orelse continue;
        const name = objc.nsString(line[0..at]);
        defer objc.release(name);
        const value = objc.nsString(line[at + 2 ..]);
        defer objc.release(value);
        objc.msgSend(*const fn (id, objc.SEL, id, id) callconv(.c) void)(req, objc.sel("setValue:forHTTPHeaderField:"), value, name);
    }
    return req;
}

const WaitBlock = extern struct { header: objc.BlockHeader, sem: ?*anyopaque, data: *id };
const wait_descriptor: objc.BlockDescriptor = .{ .size = @sizeOf(WaitBlock) };

fn waitDone(block: *WaitBlock, data: id, response: id, err: id) callconv(.c) void {
    const ok = err == null and response != null and objc.sendInt(response, "statusCode") < 400;
    if (ok and data != null) block.data.* = objc.send(data, "retain");
    _ = dispatch_semaphore_signal(block.sem);
}

/// On a background queue: the body of a GET with headers (+1 retained), or null.
fn getWithHeaders(url: []const u8, headers: []const u8) id {
    const req = requestWith(url, headers);
    if (req == null) return null;
    var data: id = null;
    const sem = dispatch_semaphore_create(0);
    defer dispatch_release(sem);
    var block: WaitBlock = .{ .header = .{ .isa = &objc._NSConcreteGlobalBlock, .invoke = @ptrCast(&waitDone), .descriptor = &wait_descriptor }, .sem = sem, .data = &data };
    const session = objc.send(objc.class("NSURLSession"), "sharedSession");
    const task = objc.msgSend(*const fn (id, objc.SEL, id, *WaitBlock) callconv(.c) id)(session, objc.sel("dataTaskWithRequest:completionHandler:"), req, &block);
    objc.sendVoid(task, "resume");
    _ = dispatch_semaphore_wait(sem, std.math.maxInt(u64)); // DISPATCH_TIME_FOREVER
    return data;
}

var stream_session: id = null;
/// zui connection id -> data task (retained).
var stream_tasks: std.AutoHashMapUnmanaged(u32, id) = .empty;

fn streamIdOf(task: id) ?u32 {
    var it = stream_tasks.iterator();
    while (it.next()) |e| if (e.value_ptr.* == task) return e.key_ptr.*;
    return null;
}

pub fn streamOpen(conn: u32, url: []const u8, headers: []const u8) void {
    if (stream_session == null) {
        const config = objc.send(objc.class("NSURLSessionConfiguration"), "defaultSessionConfiguration");
        // Events may be minutes apart: no idle timeout to speak of.
        objc.sendVoidFloat(config, "setTimeoutIntervalForRequest:", 86400);
        objc.sendVoidFloat(config, "setTimeoutIntervalForResource:", 7 * 86400);
        const make = objc.msgSend(*const fn (id, objc.SEL, id, id, id) callconv(.c) id);
        stream_session = objc.send(make(objc.class("NSURLSession"), objc.sel("sessionWithConfiguration:delegate:delegateQueue:"), config, objc.new("ZuiStreamDelegate"), objc.send(objc.class("NSOperationQueue"), "mainQueue")), "retain");
    }
    const req = requestWith(url, headers);
    if (req == null) return rt.stream_end(conn);
    const task = objc.send(objc.send1(stream_session, "dataTaskWithRequest:", req), "retain");
    stream_tasks.put(zui.allocator, conn, task) catch return;
    objc.sendVoid(task, "resume");
}

pub fn streamClose(conn: u32) void {
    const kv = stream_tasks.fetchRemove(conn) orelse return;
    objc.sendVoid(kv.value, "cancel");
    objc.release(kv.value);
}

fn streamResponse(_: id, _: objc.SEL, _: id, task: id, response: id, handler: *objc.BlockHeader) callconv(.c) void {
    const invoke: *const fn (*objc.BlockHeader, isize) callconv(.c) void = @ptrCast(@alignCast(handler.invoke));
    invoke(handler, 1); // NSURLSessionResponseAllow
    const conn = streamIdOf(task) orelse return;
    rt.stream_status(conn, @intCast(@max(0, @min(objc.sendInt(response, "statusCode"), 999))));
}

fn streamReceived(_: id, _: objc.SEL, _: id, task: id, data: id) callconv(.c) void {
    const conn = streamIdOf(task) orelse return;
    rt.stream_data(conn, dataBytes(data));
}

fn streamCompleted(_: id, _: objc.SEL, _: id, task: id, _: id) callconv(.c) void {
    const conn = streamIdOf(task) orelse return;
    _ = stream_tasks.remove(conn);
    objc.release(task);
    rt.stream_end(conn);
}

extern "c" fn arc4random_buf(buf: [*]u8, len: usize) void;

/// The system's CSPRNG (the key store's randomness).
pub fn randomBytes(buf: []u8) void {
    arc4random_buf(buf.ptr, buf.len);
}

// ---- Secure keys: SecKey in the Keychain (zui/keys.zig's hardware hook) ----
// Imported P-256 keys become Keychain keys used through SecKey (signing, key agreement);
// generated ones are made in the Secure Enclave where there is one.

extern "Security" fn SecKeyCreateWithData(data: id, attributes: id, err: ?*id) id;
extern "Security" fn SecKeyCreateRandomKey(parameters: id, err: ?*id) id;
extern "Security" fn SecKeyCopyPublicKey(key: id) id;
extern "Security" fn SecKeyCopyExternalRepresentation(key: id, err: ?*id) id;
extern "Security" fn SecKeyCreateSignature(key: id, algorithm: id, data: id, err: ?*id) id;
extern "Security" fn SecKeyCopyKeyExchangeResult(key: id, algorithm: id, public_key: id, parameters: id, err: ?*id) id;
extern "Security" var kSecClassKey: id;
extern "Security" var kSecValueRef: id;
extern "Security" var kSecReturnRef: id;
extern "Security" var kSecAttrApplicationTag: id;
extern "Security" var kSecAttrKeyType: id;
extern "Security" var kSecAttrKeyTypeECSECPrimeRandom: id;
extern "Security" var kSecAttrKeyClass: id;
extern "Security" var kSecAttrKeyClassPrivate: id;
extern "Security" var kSecAttrKeyClassPublic: id;
extern "Security" var kSecAttrKeySizeInBits: id;
extern "Security" var kSecPrivateKeyAttrs: id;
extern "Security" var kSecAttrIsPermanent: id;
extern "Security" var kSecAttrTokenID: id;
extern "Security" var kSecAttrTokenIDSecureEnclave: id;
extern "Security" var kSecKeyAlgorithmECDSASignatureMessageX962SHA256: id;
extern "Security" var kSecKeyAlgorithmECDHKeyExchangeStandard: id;

pub const KeyHw = struct {
    fn tag(name: []const u8) id {
        var buf: [300]u8 = undefined;
        return nsData(std.fmt.bufPrint(&buf, "zui:{s}", .{name}) catch name);
    }

    fn bits256() id {
        return objc.msgSend(*const fn (id, objc.SEL, isize) callconv(.c) id)(objc.class("NSNumber"), objc.sel("numberWithInteger:"), 256);
    }

    /// The private key `name`, or null (+1 retained).
    fn find(name: []const u8) id {
        const q = nsDict(&.{ kSecClass, kSecAttrApplicationTag, kSecAttrKeyType, kSecReturnRef }, &.{ kSecClassKey, tag(name), kSecAttrKeyTypeECSECPrimeRandom, kCFBooleanTrue });
        var key: id = null;
        if (SecItemCopyMatching(q, &key) != 0) return null;
        return key;
    }

    fn publicRaw(key: id) ?[65]u8 {
        const p = SecKeyCopyPublicKey(key);
        if (p == null) return null;
        defer objc.release(p);
        const d = SecKeyCopyExternalRepresentation(p, null);
        if (d == null) return null;
        defer objc.release(d);
        const b = dataBytes(d);
        if (b.len != 65) return null;
        return b[0..65].*;
    }

    pub fn import(_: std.mem.Allocator, name: []const u8, _: zui.keys.Kind, secret: [32]u8, public: [65]u8) bool {
        // ANSI X9.63: the public point, then the private scalar.
        var x963: [97]u8 = undefined;
        @memcpy(x963[0..65], &public);
        @memcpy(x963[65..97], &secret);
        defer std.crypto.secureZero(u8, &x963);
        const attrs = nsDict(&.{ kSecAttrKeyType, kSecAttrKeyClass, kSecAttrKeySizeInBits }, &.{ kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClassPrivate, bits256() });
        const key = SecKeyCreateWithData(nsData(&x963), attrs, null);
        if (key == null) return false;
        defer objc.release(key);
        delete(name);
        const add = nsDict(&.{ kSecClass, kSecValueRef, kSecAttrApplicationTag, kSecAttrAccessible }, &.{ kSecClassKey, key, tag(name), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly });
        return SecItemAdd(add, null) == 0;
    }

    pub fn generate(_: std.mem.Allocator, name: []const u8, _: zui.keys.Kind) ?[65]u8 {
        delete(name);
        const private = nsDict(&.{ kSecAttrIsPermanent, kSecAttrApplicationTag, kSecAttrAccessible }, &.{ kCFBooleanTrue, tag(name), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly });
        // The Secure Enclave first; the Keychain where there is none (the simulator).
        var key = SecKeyCreateRandomKey(nsDict(&.{ kSecAttrKeyType, kSecAttrKeySizeInBits, kSecAttrTokenID, kSecPrivateKeyAttrs }, &.{ kSecAttrKeyTypeECSECPrimeRandom, bits256(), kSecAttrTokenIDSecureEnclave, private }), null);
        if (key == null) key = SecKeyCreateRandomKey(nsDict(&.{ kSecAttrKeyType, kSecAttrKeySizeInBits, kSecPrivateKeyAttrs }, &.{ kSecAttrKeyTypeECSECPrimeRandom, bits256(), private }), null);
        if (key == null) return null;
        defer objc.release(key);
        return publicRaw(key);
    }

    pub fn sign(_: std.mem.Allocator, name: []const u8, data: []const u8) ?[64]u8 {
        const key = find(name);
        if (key == null) return null;
        defer objc.release(key);
        const sig = SecKeyCreateSignature(key, kSecKeyAlgorithmECDSASignatureMessageX962SHA256, nsData(data), null);
        if (sig == null) return null;
        defer objc.release(sig);
        return derToRaw(dataBytes(sig));
    }

    pub fn ecdh(_: std.mem.Allocator, name: []const u8, peer: []const u8) ?[32]u8 {
        const key = find(name);
        if (key == null) return null;
        defer objc.release(key);
        const attrs = nsDict(&.{ kSecAttrKeyType, kSecAttrKeyClass, kSecAttrKeySizeInBits }, &.{ kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClassPublic, bits256() });
        const other = SecKeyCreateWithData(nsData(peer), attrs, null);
        if (other == null) return null;
        defer objc.release(other);
        const secret = SecKeyCopyKeyExchangeResult(key, kSecKeyAlgorithmECDHKeyExchangeStandard, other, objc.send(objc.class("NSDictionary"), "dictionary"), null);
        if (secret == null) return null;
        defer objc.release(secret);
        const b = dataBytes(secret);
        if (b.len != 32) return null;
        return b[0..32].*;
    }

    pub fn delete(name: []const u8) void {
        _ = SecItemDelete(nsDict(&.{ kSecClass, kSecAttrApplicationTag }, &.{ kSecClassKey, tag(name) }));
    }
};

/// A DER ECDSA signature (SEQUENCE { INTEGER r, INTEGER s }) as r||s.
fn derToRaw(der: []const u8) ?[64]u8 {
    var out: [64]u8 = @splat(0);
    if (der.len < 8 or der[0] != 0x30) return null;
    var i: usize = 2;
    for (0..2) |k| {
        if (i + 2 > der.len or der[i] != 0x02) return null;
        const len = der[i + 1];
        if (i + 2 + len > der.len) return null;
        var v = der[i + 2 .. i + 2 + len];
        while (v.len > 32 and v[0] == 0) v = v[1..];
        if (v.len > 32) return null;
        @memcpy(out[k * 32 + 32 - v.len .. k * 32 + 32], v);
        i += 2 + len;
    }
    return out;
}

test derToRaw {
    const der = [_]u8{ 0x30, 0x08, 0x02, 0x02, 0x00, 0x81, 0x02, 0x02, 0x01, 0x02 };
    const raw = derToRaw(&der).?;
    try std.testing.expectEqual(@as(u8, 0x81), raw[31]);
    try std.testing.expectEqual(@as(u8, 0x02), raw[63]);
    try std.testing.expectEqual(@as(u8, 0x01), raw[62]);
}

// ---- Styling and interaction: rich text with links, selectable text, letter spacing,
// pictures from memory and how they fit, decorations (per-corner radii, per-side borders, a
// shadow, a gradient) in a layer under the subviews, transitions, spinners, scroll control, the
// haptic tick of a long press ----

extern "UIKit" var NSKernAttributeName: id;
extern "UIKit" var NSUnderlineStyleAttributeName: id;
extern "UIKit" var NSStrikethroughStyleAttributeName: id;
extern "QuartzCore" var kCAFillRuleEvenOdd: id;
extern "CoreGraphics" fn CGPathAddArcToPoint(path: CGPath, m: ?*const anyopaque, x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat, r: CGFloat) void;
extern "CoreGraphics" fn CGPathAddPath(path: CGPath, m: ?*const anyopaque, other: CGPath) void;

const NSRange = extern struct { location: usize, length: usize };

var style_rt: struct {
    span: *const fn (u32, u32) void,
    scroll: *const fn (u32, f32) void,
} = undefined;

fn styleInit(comptime R: type) void {
    const Cb = struct {
        fn span(i: u32, index: u32) void {
            R.spanPress(i, index);
        }
        fn scroll(i: u32, offset: f32) void {
            R.scrollEvent(i, offset);
        }
    };
    style_rt = .{ .span = Cb.span, .scroll = Cb.scroll };
    objc.defineClass("ZuiLabel", "UILabel", &.{}, &.{
        .{ "touchesBegan:withEvent:", @ptrCast(&labelBegan), "v@:@@" },
        .{ "touchesEnded:withEvent:", @ptrCast(&labelEnded), "v@:@@" },
        .{ "touchesCancelled:withEvent:", @ptrCast(&labelCancelled), "v@:@@" },
    });
    objc.defineClass("ZuiScrollDelegate", "NSObject", &.{"UIScrollViewDelegate"}, &.{
        .{ "scrollViewDidScroll:", @ptrCast(&didScroll), "v@:@" },
    });
}

/// Per view: whether it scrolls sideways, its transition, its decoration.
var horizontal: std.AutoHashMapUnmanaged(u32, void) = .empty;
var transitions: std.AutoHashMapUnmanaged(u32, zui.Transition) = .empty;
const DecorEntry = struct { background: u32, decor: zui.Decor, layer: id = null };
var decors: std.AutoHashMapUnmanaged(u32, DecorEntry) = .empty;
var scroll_delegate: id = null;

fn styleSelectable() id {
    const tv = objc.new("UITextView");
    objc.sendVoidBool(tv, "setEditable:", false);
    objc.sendVoidBool(tv, "setSelectable:", true);
    objc.sendVoidBool(tv, "setScrollEnabled:", false);
    objc.sendVoid1(tv, "setBackgroundColor:", objc.send(objc.class("UIColor"), "clearColor"));
    objc.msgSend(*const fn (id, objc.SEL, objc.UIEdgeInsets) callconv(.c) void)(tv, objc.sel("setTextContainerInset:"), .{ .top = 0, .left = 0, .bottom = 0, .right = 0 });
    objc.sendVoidFloat(objc.send(tv, "textContainer"), "setLineFragmentPadding:", 0);
    return tv;
}

fn styleCreated(i: u32, kind: zui.tree.Kind, v: id) void {
    _ = horizontal.remove(i);
    _ = transitions.remove(i);
    if (decors.fetchRemove(i)) |e| if (e.value.layer != null) objc.release(e.value.layer);
    if (kind == .scroll or kind == .scroll_x) {
        if (kind == .scroll_x) horizontal.put(zui.allocator, i, {}) catch {};
        if (scroll_delegate == null) scroll_delegate = objc.new("ZuiScrollDelegate");
        objc.sendVoid1(v, "setDelegate:", scroll_delegate);
    }
}

// ---- Rich text ----

fn nsNumberInt(v: isize) id {
    return objc.msgSend(*const fn (id, objc.SEL, isize) callconv(.c) id)(objc.class("NSNumber"), objc.sel("numberWithInteger:"), v);
}

fn utf16Len(s: []const u8) usize {
    return std.unicode.calcUtf16LeLen(s) catch s.len;
}

/// The text with its spans' looks and links (+1 retained).
fn richAttributed(s: []const u8, spans: []const zui.Span, f: zui.Font, argb: u32, a: zui.PhysicalAlign) id {
    const base = attributes(f, argb, a);
    const attrs = objc.send(base, "mutableCopy");
    defer objc.release(attrs);
    const set = objc.msgSend(*const fn (id, objc.SEL, id, id) callconv(.c) void);
    if (f.letter_spacing != 0) set(attrs, objc.sel("setObject:forKey:"), objc.msgSend(*const fn (id, objc.SEL, CGFloat) callconv(.c) id)(objc.class("NSNumber"), objc.sel("numberWithDouble:"), f.letter_spacing), NSKernAttributeName);
    const str = objc.nsString(s);
    defer objc.release(str);
    const m = objc.msgSend(*const fn (id, objc.SEL, id, id) callconv(.c) id)(objc.send(objc.class("NSMutableAttributedString"), "alloc"), objc.sel("initWithString:attributes:"), str, attrs);
    const add = objc.msgSend(*const fn (id, objc.SEL, id, id, NSRange) callconv(.c) void);
    for (spans) |sp| {
        const lo = @min(s.len, sp.start);
        const hi = @min(s.len, sp.start + sp.len);
        const r: NSRange = .{ .location = utf16Len(s[0..lo]), .length = utf16Len(s[lo..hi]) };
        if (r.length == 0) continue;
        if (sp.bold or sp.italic or sp.mono) {
            var ff = f;
            if (sp.bold) ff.weight = @max(f.weight, 700);
            if (sp.mono) ff.mono = true;
            var uf = font(ff);
            if (sp.italic) {
                const desc = objc.send(uf, "fontDescriptor");
                const traits: u32 = @intCast(objc.msgSend(*const fn (id, objc.SEL) callconv(.c) u32)(desc, objc.sel("symbolicTraits")));
                const it = objc.msgSend(*const fn (id, objc.SEL, u32) callconv(.c) id)(desc, objc.sel("fontDescriptorWithSymbolicTraits:"), traits | 1);
                if (it != null) uf = objc.msgSend(*const fn (id, objc.SEL, id, CGFloat) callconv(.c) id)(objc.class("UIFont"), objc.sel("fontWithDescriptor:size:"), it, 0);
            }
            add(m, objc.sel("addAttribute:value:range:"), NSFontAttributeName, uf, r);
        }
        if (sp.color >> 24 != 0) add(m, objc.sel("addAttribute:value:range:"), NSForegroundColorAttributeName, color(sp.color), r);
        if (sp.underline) add(m, objc.sel("addAttribute:value:range:"), NSUnderlineStyleAttributeName, nsNumberInt(1), r);
        if (sp.strike) add(m, objc.sel("addAttribute:value:range:"), NSStrikethroughStyleAttributeName, nsNumberInt(1), r);
        if (sp.link >= 0) {
            const key = objc.nsString("ZuiLink");
            defer objc.release(key);
            add(m, objc.sel("addAttribute:value:range:"), key, nsNumberInt(sp.link), r);
        }
    }
    return m;
}

pub fn richText(i: u32, s: []const u8, spans: []const zui.Span, f: zui.Font, argb: u32, a: zui.PhysicalAlign) void {
    const v = view(i);
    const str = richAttributed(s, spans, f, argb, a);
    defer objc.release(str);
    objc.sendVoid1(v, "setAttributedText:", str);
    const is_label = objc.msgSend(*const fn (id, objc.SEL, id) callconv(.c) bool)(v, objc.sel("isKindOfClass:"), objc.class("UILabel"));
    if (is_label) {
        objc.sendVoidInt(v, "setNumberOfLines:", f.max_lines);
        var links = false;
        for (spans) |sp| links = links or sp.link >= 0;
        // Taps reach a label only when it has links; the rest go on to the views around.
        objc.sendVoidBool(v, "setUserInteractionEnabled:", links);
    } else {
        objc.sendVoidInt(objc.send(v, "textContainer"), "setMaximumNumberOfLines:", f.max_lines);
    }
}

pub fn measureRich(s: []const u8, spans: []const zui.Span, f: zui.Font, max_width: f32) zui.Size {
    if (s.len == 0) return .{ .w = 0, .h = f.line_height };
    const str = richAttributed(s, spans, f, 0xff000000, .left);
    defer objc.release(str);
    const bound = objc.msgSend(*const fn (id, objc.SEL, objc.CGSize, isize, id) callconv(.c) objc.CGRect);
    const width: CGFloat = if (std.math.isFinite(max_width)) max_width else 1e7;
    const r = bound(str, objc.sel("boundingRectWithSize:options:context:"), .{ .w = width, .h = 1e7 }, uses_line_fragment_origin, null);
    var h: f32 = @floatCast(@ceil(r.h));
    if (f.max_lines > 0) h = @min(h, @as(f32, @floatFromInt(f.max_lines)) * f.line_height);
    return .{ .w = @floatCast(@ceil(r.w)), .h = h };
}

/// The link under `p` in a label, or -1: the label's text laid out again with TextKit.
fn linkAt(label: id, p: objc.CGPoint) isize {
    const text_ = objc.send(label, "attributedText");
    if (text_ == null) return -1;
    const b = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) objc.CGRect)(label, objc.sel("bounds"));
    const storage = objc.send1(objc.send(objc.class("NSTextStorage"), "alloc"), "initWithAttributedString:", text_);
    defer objc.release(storage);
    const lm = objc.new("NSLayoutManager");
    defer objc.release(lm);
    const text_box = objc.msgSend(*const fn (id, objc.SEL, objc.CGSize) callconv(.c) id)(objc.send(objc.class("NSTextContainer"), "alloc"), objc.sel("initWithSize:"), .{ .w = b.w, .h = 1e7 });
    defer objc.release(text_box);
    objc.sendVoidFloat(text_box, "setLineFragmentPadding:", 0);
    objc.sendVoidInt(text_box, "setMaximumNumberOfLines:", objc.sendInt(label, "numberOfLines"));
    objc.sendVoid1(lm, "addTextContainer:", text_box);
    objc.sendVoid1(storage, "addLayoutManager:", lm);
    const glyph = objc.msgSend(*const fn (id, objc.SEL, objc.CGPoint, id, ?*CGFloat) callconv(.c) usize)(lm, objc.sel("glyphIndexForPoint:inTextContainer:fractionOfDistanceThroughGlyph:"), p, text_box, null);
    const rect = objc.msgSend(*const fn (id, objc.SEL, NSRange, id) callconv(.c) objc.CGRect)(lm, objc.sel("boundingRectForGlyphRange:inTextContainer:"), .{ .location = glyph, .length = 1 }, text_box);
    if (p.x < rect.x or p.x > rect.x + rect.w or p.y < rect.y or p.y > rect.y + rect.h) return -1;
    const ci = objc.msgSend(*const fn (id, objc.SEL, usize) callconv(.c) usize)(lm, objc.sel("characterIndexForGlyphAtIndex:"), glyph);
    const key = objc.nsString("ZuiLink");
    defer objc.release(key);
    const v = objc.msgSend(*const fn (id, objc.SEL, id, usize, ?*NSRange) callconv(.c) id)(text_, objc.sel("attribute:atIndex:effectiveRange:"), key, ci, null);
    return if (v != null) objc.sendInt(v, "integerValue") else -1;
}

var pending_link: struct { id: u32 = 0, index: isize = -1 } = .{};

fn labelBegan(self: id, _: objc.SEL, touches: id, ev: id) callconv(.c) void {
    const p = objc.msgSend(*const fn (id, objc.SEL, id) callconv(.c) objc.CGPoint)(objc.send(touches, "anyObject"), objc.sel("locationInView:"), self);
    const link = linkAt(self, p);
    if (link < 0) {
        pending_link = .{};
        return objc.sendSuper2(self, "ZuiLabel", "touchesBegan:withEvent:", touches, ev);
    }
    pending_link = .{ .id = @intCast(objc.sendInt(self, "tag")), .index = link };
}

fn labelEnded(self: id, _: objc.SEL, touches: id, ev: id) callconv(.c) void {
    const i: u32 = @intCast(objc.sendInt(self, "tag"));
    if (pending_link.index < 0 or pending_link.id != i) return objc.sendSuper2(self, "ZuiLabel", "touchesEnded:withEvent:", touches, ev);
    const link = pending_link.index;
    pending_link = .{};
    style_rt.span(i, @intCast(link));
}

fn labelCancelled(self: id, _: objc.SEL, touches: id, ev: id) callconv(.c) void {
    if (pending_link.index >= 0) {
        pending_link = .{};
        return;
    }
    objc.sendSuper2(self, "ZuiLabel", "touchesCancelled:withEvent:", touches, ev);
}

// ---- Pictures from memory ----

pub fn imageBytes(i: u32, key: []const u8, bytes: []const u8) void {
    var kb: [600]u8 = undefined;
    const tag = std.fmt.bufPrint(&kb, "\nmem:{s}", .{key}) catch return;
    if (image_urls.items[i]) |old| {
        if (std.mem.eql(u8, old, tag)) return;
        zui.allocator.free(old);
    }
    image_urls.items[i] = zui.allocator.dupe(u8, tag) catch null;
    if (image_cache == null) image_cache = objc.new("NSCache");
    const k = objc.nsString(tag);
    defer objc.release(k);
    var img = objc.send1(image_cache, "objectForKey:", k);
    if (img == null) {
        img = objc.send1(objc.class("UIImage"), "imageWithData:", nsData(bytes));
        if (img != null) objc.msgSend(*const fn (id, objc.SEL, id, id) callconv(.c) void)(image_cache, objc.sel("setObject:forKey:"), img, k);
    }
    objc.sendVoid1(view(i), "setImage:", img);
}

pub fn imageFit(i: u32, fit: zui.Fit) void {
    const v = view(i);
    // UIViewContentModeScaleToFill, ScaleAspectFill, ScaleAspectFit.
    objc.sendVoidInt(v, "setContentMode:", switch (fit) {
        .fill => 0,
        .cover => 2,
        .contain => 1,
    });
    if (fit == .cover) objc.sendVoidBool(v, "setClipsToBounds:", true);
}

// ---- Long press, hover ----

pub fn gestures(_: u32, _: zui.Gestures) void {}

pub fn haptic() void {
    const g = objc.msgSend(*const fn (id, objc.SEL, isize) callconv(.c) id)(objc.send(objc.class("UIImpactFeedbackGenerator"), "alloc"), objc.sel("initWithStyle:"), 1);
    defer objc.release(g);
    objc.sendVoid(g, "impactOccurred");
}

// ---- Scroll views ----

fn didScroll(_: id, _: objc.SEL, sv: id) callconv(.c) void {
    const i: u32 = @intCast(objc.sendInt(sv, "tag"));
    const o = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) objc.CGPoint)(sv, objc.sel("contentOffset"));
    style_rt.scroll(i, @floatCast(if (horizontal.contains(i)) o.x else o.y));
}

pub fn scrollTo(i: u32, offset: f32, animated: bool) void {
    const p: objc.CGPoint = if (horizontal.contains(i)) .{ .x = offset, .y = 0 } else .{ .x = 0, .y = offset };
    objc.msgSend(*const fn (id, objc.SEL, objc.CGPoint, bool) callconv(.c) void)(view(i), objc.sel("setContentOffset:animated:"), p, animated);
}

// ---- Transitions and spinners ----

pub fn transition(i: u32, t: ?zui.Transition) void {
    if (t) |tr| transitions.put(zui.allocator, i, tr) catch {} else _ = transitions.remove(i);
}

const AnimBlock = extern struct { header: objc.BlockHeader };
const anim_descriptor: objc.BlockDescriptor = .{ .size = @sizeOf(AnimBlock) };
var anim_work: ?*const fn () void = null;
fn animInvoke(_: *const AnimBlock) callconv(.c) void {
    if (anim_work) |w| w();
}
const anim_block: AnimBlock = .{ .header = .{ .isa = &objc._NSConcreteGlobalBlock, .invoke = @ptrCast(&animInvoke), .descriptor = &anim_descriptor } };

/// Runs `work` inside a UIView animation with the transition's duration and curve (the four
/// curves UIKit, CSS and Android share).
fn animate(tr: zui.Transition, work: *const fn () void) void {
    const curve: usize = switch (tr.easing) {
        .ease_in_out => 0,
        .ease_in => 1,
        .ease_out => 2,
        .linear => 3,
    };
    anim_work = work;
    defer anim_work = null;
    const f = objc.msgSend(*const fn (id, objc.SEL, f64, f64, usize, *const AnimBlock, ?*anyopaque) callconv(.c) void);
    f(objc.class("UIView"), objc.sel("animateWithDuration:delay:options:animations:completion:"), @as(f64, @floatFromInt(tr.duration_ms)) / 1000, 0, (curve << 16) | 2, &anim_block, null);
}

var anim_view: u32 = 0;
var anim_rect: zui.Rect = .{};
var anim_alpha: CGFloat = 1;

fn placeWork() void {
    place(anim_view, anim_rect);
}

fn alphaWork() void {
    objc.sendVoidFloat(view(anim_view), "setAlpha:", anim_alpha);
}

fn styleFrame(i: u32, r: zui.Rect) bool {
    defer if (decors.contains(i)) applyDecor(i, r);
    const tr = transitions.get(i) orelse return false;
    if (i >= frames.items.len or frames.items[i].w <= 0 and frames.items[i].h <= 0) return false;
    frames.items[i] = r;
    anim_view = i;
    anim_rect = r;
    animate(tr, placeWork);
    return true;
}

fn alphaOf(v: id) CGFloat {
    return objc.msgSend(*const fn (id, objc.SEL) callconv(.c) CGFloat)(v, objc.sel("alpha"));
}

fn styleBox(i: u32, b: zui.Box, old_alpha: CGFloat) void {
    // A rounded picture is cut round, as CSS cuts it.
    if (b.radius > 0 and objc.msgSend(*const fn (id, objc.SEL, id) callconv(.c) bool)(view(i), objc.sel("isKindOfClass:"), objc.class("UIImageView"))) objc.sendVoidBool(view(i), "setClipsToBounds:", true);
    if (b.isSimple()) {
        if (decors.fetchRemove(i)) |e| if (e.value.layer != null) {
            objc.sendVoid(e.value.layer, "removeFromSuperlayer");
            objc.release(e.value.layer);
        };
    } else {
        const gop = decors.getOrPut(zui.allocator, i) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{ .background = 0, .decor = .{} };
        gop.value_ptr.background = b.background;
        gop.value_ptr.decor = b.decor;
        // Drawn by the decoration layer instead.
        const v = view(i);
        objc.sendVoid1(v, "setBackgroundColor:", objc.send(objc.class("UIColor"), "clearColor"));
        const layer = objc.send(v, "layer");
        objc.sendVoidFloat(layer, "setBorderWidth:", 0);
        objc.sendVoidFloat(layer, "setCornerRadius:", if (b.decor.uniformCorners()) b.decor.radii[0] else 0);
        if (i < frames.items.len) applyDecor(i, frames.items[i]);
    }
    if (transitions.get(i)) |tr| if (old_alpha != b.opacity) {
        objc.sendVoidFloat(view(i), "setAlpha:", old_alpha);
        anim_view = i;
        anim_alpha = b.opacity;
        animate(tr, alphaWork);
    };
}

pub fn spin(i: u32, period_ms: u16) void {
    const layer = objc.send(view(i), "layer");
    const key = objc.nsString("zuiSpin");
    defer objc.release(key);
    objc.sendVoid1(layer, "removeAnimationForKey:", key);
    if (period_ms == 0) return;
    const path_ = objc.nsString("transform.rotation.z");
    defer objc.release(path_);
    const a = objc.send1(objc.class("CABasicAnimation"), "animationWithKeyPath:", path_);
    const num = objc.msgSend(*const fn (id, objc.SEL, CGFloat) callconv(.c) id);
    objc.sendVoid1(a, "setFromValue:", num(objc.class("NSNumber"), objc.sel("numberWithDouble:"), 0));
    objc.sendVoid1(a, "setToValue:", num(objc.class("NSNumber"), objc.sel("numberWithDouble:"), 2 * std.math.pi));
    objc.sendVoidFloat(a, "setDuration:", @as(f64, @floatFromInt(period_ms)) / 1000);
    objc.msgSend(*const fn (id, objc.SEL, f32) callconv(.c) void)(a, objc.sel("setRepeatCount:"), std.math.inf(f32));
    objc.sendVoidBool(a, "setRemovedOnCompletion:", false);
    objc.msgSend(*const fn (id, objc.SEL, id, id) callconv(.c) void)(layer, objc.sel("addAnimation:forKey:"), a, key);
}

// ---- Decorations: a layer under the subviews, drawn as CSS draws a box ----

/// A rectangle with corners top-left, top-right, bottom-right, bottom-left, the radii scaled
/// down as CSS does when they do not fit (+1 retained).
fn roundedPath(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, radii: [4]CGFloat) CGPath {
    var k: CGFloat = 1;
    const sums = [4]CGFloat{ radii[0] + radii[1], radii[3] + radii[2], radii[0] + radii[3], radii[1] + radii[2] };
    const lens = [4]CGFloat{ w, w, h, h };
    for (sums, lens) |s, l| if (s > 0 and l < s) {
        k = @min(k, l / s);
    };
    var r: [4]CGFloat = undefined;
    for (radii, &r) |a, *o| o.* = @max(0, a * k);
    const p = CGPathCreateMutable();
    CGPathMoveToPoint(p, null, x + r[0], y);
    CGPathAddArcToPoint(p, null, x + w, y, x + w, y + h, r[1]);
    CGPathAddArcToPoint(p, null, x + w, y + h, x, y + h, r[2]);
    CGPathAddArcToPoint(p, null, x, y + h, x, y, r[3]);
    CGPathAddArcToPoint(p, null, x, y, x + w, y, r[0]);
    CGPathCloseSubpath(p);
    return p;
}

fn shapeLayer(path_: CGPath, fill: u32) id {
    const l = objc.new("CAShapeLayer");
    const set_ptr = objc.msgSend(*const fn (id, objc.SEL, ?*anyopaque) callconv(.c) void);
    set_ptr(l, objc.sel("setPath:"), path_);
    set_ptr(l, objc.sel("setFillColor:"), @ptrCast(objc.send(color(fill), "CGColor")));
    return l;
}

fn applyDecor(i: u32, r: zui.Rect) void {
    const e = decors.getPtr(i) orelse return;
    const d = e.decor;
    const v = view(i);
    // Text draws in its own layer: sublayers would cover it, so its box is its background.
    if (isText(v)) return decorText(v, e.*, r);
    const set_rect = objc.msgSend(*const fn (id, objc.SEL, objc.CGRect) callconv(.c) void);
    const set_ptr = objc.msgSend(*const fn (id, objc.SEL, ?*anyopaque) callconv(.c) void);
    if (e.layer == null) {
        e.layer = objc.new("CALayer");
        objc.msgSend(*const fn (id, objc.SEL, id, u32) callconv(.c) void)(objc.send(v, "layer"), objc.sel("insertSublayer:atIndex:"), e.layer, 0);
    }
    const root_layer = e.layer;
    objc.sendVoid1(root_layer, "setSublayers:", null);
    const w: CGFloat = r.w;
    const h: CGFloat = r.h;
    set_rect(root_layer, objc.sel("setFrame:"), .{ .w = w, .h = h });
    const radii = [4]CGFloat{ d.radii[0], d.radii[1], d.radii[2], d.radii[3] };
    const outer = roundedPath(0, 0, w, h, radii);
    defer CGPathRelease(outer);

    // Shadow and background.
    const bg = shapeLayer(outer, e.background);
    defer objc.release(bg);
    if (d.shadow_color >> 24 != 0) {
        set_ptr(bg, objc.sel("setShadowPath:"), outer);
        set_ptr(bg, objc.sel("setShadowColor:"), @ptrCast(objc.send(color(d.shadow_color | 0xff000000), "CGColor")));
        objc.msgSend(*const fn (id, objc.SEL, f32) callconv(.c) void)(bg, objc.sel("setShadowOpacity:"), @as(f32, @floatFromInt(d.shadow_color >> 24)) / 255);
        objc.msgSend(*const fn (id, objc.SEL, objc.CGSize) callconv(.c) void)(bg, objc.sel("setShadowOffset:"), .{ .w = d.shadow[0], .h = d.shadow[1] });
        // CSS blur B is a Gaussian of sigma B/2, which is what shadowRadius is.
        objc.sendVoidFloat(bg, "setShadowRadius:", d.shadow[2] / 2);
    }
    objc.sendVoid1(root_layer, "addSublayer:", bg);

    // Gradient, cut to the shape.
    if (d.gradient_count > 0) {
        const g = objc.new("CAGradientLayer");
        defer objc.release(g);
        set_rect(g, objc.sel("setFrame:"), .{ .w = w, .h = h });
        var cols: [64]id = undefined;
        var locs: [64]id = undefined;
        var stop_colors: [64]u32 = undefined;
        var stop_at: [64]f32 = undefined;
        const n = d.blendedStops(&stop_colors, &stop_at);
        const num = objc.msgSend(*const fn (id, objc.SEL, CGFloat) callconv(.c) id);
        for (0..n) |k| {
            cols[k] = objc.send(color(stop_colors[k]), "CGColor");
            locs[k] = num(objc.class("NSNumber"), objc.sel("numberWithDouble:"), stop_at[k]);
        }
        const array = objc.msgSend(*const fn (id, objc.SEL, [*]id, usize) callconv(.c) id);
        objc.sendVoid1(g, "setColors:", array(objc.class("NSArray"), objc.sel("arrayWithObjects:count:"), &cols, n));
        objc.sendVoid1(g, "setLocations:", array(objc.class("NSArray"), objc.sel("arrayWithObjects:count:"), &locs, n));
        // The CSS gradient line, in unit coordinates of the box.
        const ang = std.math.degreesToRadians(@as(f64, d.gradient_angle));
        const dx = @sin(ang);
        const dy = -@cos(ang);
        const len = @abs(w * dx) + @abs(h * dy);
        const set_point = objc.msgSend(*const fn (id, objc.SEL, objc.CGPoint) callconv(.c) void);
        if (w > 0 and h > 0) {
            set_point(g, objc.sel("setStartPoint:"), .{ .x = 0.5 - dx * len / 2 / w, .y = 0.5 - dy * len / 2 / h });
            set_point(g, objc.sel("setEndPoint:"), .{ .x = 0.5 + dx * len / 2 / w, .y = 0.5 + dy * len / 2 / h });
        }
        const mask = shapeLayer(outer, 0xff000000);
        defer objc.release(mask);
        objc.sendVoid1(g, "setMask:", mask);
        objc.sendVoid1(root_layer, "addSublayer:", g);
    }

    // Borders: each side is the ring between the box and its inside, cut along the diagonals
    // between its outer and inner corners.
    const bw = d.border_widths;
    const t: CGFloat = bw[0];
    const rw: CGFloat = bw[1];
    const bt: CGFloat = bw[2];
    const l: CGFloat = bw[3];
    if (t > 0 or rw > 0 or bt > 0 or l > 0) {
        const inner_r = [4]CGFloat{ @max(0, radii[0] - @max(l, t)), @max(0, radii[1] - @max(rw, t)), @max(0, radii[2] - @max(rw, bt)), @max(0, radii[3] - @max(l, bt)) };
        const ring = CGPathCreateMutable();
        defer CGPathRelease(ring);
        CGPathAddPath(ring, null, outer);
        if (w - l - rw > 0 and h - t - bt > 0) {
            const inner = roundedPath(l, t, w - l - rw, h - t - bt, inner_r);
            defer CGPathRelease(inner);
            CGPathAddPath(ring, null, inner);
        }
        const outer_c = [4][2]CGFloat{ .{ 0, 0 }, .{ w, 0 }, .{ w, h }, .{ 0, h } };
        const inner_c = [4][2]CGFloat{ .{ l, t }, .{ w - rw, t }, .{ w - rw, h - bt }, .{ l, h - bt } };
        for (0..4) |s| {
            if (bw[s] <= 0 or d.border_colors[s] >> 24 == 0) continue;
            const side = shapeLayer(ring, d.border_colors[s]);
            defer objc.release(side);
            objc.sendVoid1(side, "setFillRule:", kCAFillRuleEvenOdd);
            const q = CGPathCreateMutable();
            defer CGPathRelease(q);
            // Side s runs from corner s to corner s+1: its outer corners pushed far out along
            // the diagonals, then its inner corners.
            const a = s;
            const b2 = (s + 1) % 4;
            CGPathMoveToPoint(q, null, outer_c[a][0] + (outer_c[a][0] - inner_c[a][0]) * 100, outer_c[a][1] + (outer_c[a][1] - inner_c[a][1]) * 100);
            CGPathAddLineToPoint(q, null, outer_c[b2][0] + (outer_c[b2][0] - inner_c[b2][0]) * 100, outer_c[b2][1] + (outer_c[b2][1] - inner_c[b2][1]) * 100);
            CGPathAddLineToPoint(q, null, inner_c[b2][0], inner_c[b2][1]);
            CGPathAddLineToPoint(q, null, inner_c[a][0], inner_c[a][1]);
            CGPathCloseSubpath(q);
            const mask = shapeLayer(q, 0xff000000);
            defer objc.release(mask);
            objc.sendVoid1(side, "setMask:", mask);
            objc.sendVoid1(root_layer, "addSublayer:", side);
        }
    }
}

// ---- A text view's box: drawn with Core Graphics into an image that is its background (under
// its text), with the shadow on its own layer ----

const CGContext = ?*anyopaque;
extern "UIKit" fn UIGraphicsGetCurrentContext() CGContext;
extern "CoreGraphics" fn CGContextSaveGState(c: CGContext) void;
extern "CoreGraphics" fn CGContextRestoreGState(c: CGContext) void;
extern "CoreGraphics" fn CGContextAddPath(c: CGContext, p: CGPath) void;
extern "CoreGraphics" fn CGContextFillPath(c: CGContext) void;
extern "CoreGraphics" fn CGContextClip(c: CGContext) void;
extern "CoreGraphics" fn CGContextEOClip(c: CGContext) void;
extern "CoreGraphics" fn CGContextSetFillColorWithColor(c: CGContext, color: ?*anyopaque) void;
extern "CoreGraphics" fn CGContextFillRect(c: CGContext, r: objc.CGRect) void;
extern "CoreGraphics" fn CGContextDrawLinearGradient(c: CGContext, g: ?*anyopaque, start: objc.CGPoint, end: objc.CGPoint, options: u32) void;
extern "CoreGraphics" fn CGColorSpaceCreateDeviceRGB() ?*anyopaque;
extern "CoreGraphics" fn CGColorSpaceRelease(s: ?*anyopaque) void;
extern "CoreGraphics" fn CGGradientCreateWithColors(space: ?*anyopaque, colors: id, locations: [*]const CGFloat) ?*anyopaque;
extern "CoreGraphics" fn CGGradientRelease(g: ?*anyopaque) void;

fn isText(v: id) bool {
    const kind = objc.msgSend(*const fn (id, objc.SEL, id) callconv(.c) bool);
    return kind(v, objc.sel("isKindOfClass:"), objc.class("UILabel")) or kind(v, objc.sel("isKindOfClass:"), objc.class("UITextView"));
}

fn cgColor(argb: u32) ?*anyopaque {
    return @ptrCast(objc.send(color(argb), "CGColor"));
}

fn decorText(v: id, e: DecorEntry, r: zui.Rect) void {
    const d = e.decor;
    const w: CGFloat = r.w;
    const h: CGFloat = r.h;
    const layer = objc.send(v, "layer");
    objc.sendVoidFloat(layer, "setCornerRadius:", 0);
    if (w <= 0 or h <= 0) return;
    const radii = [4]CGFloat{ d.radii[0], d.radii[1], d.radii[2], d.radii[3] };
    const outer = roundedPath(0, 0, w, h, radii);
    defer CGPathRelease(outer);

    UIGraphicsBeginImageContextWithOptions(.{ .w = w, .h = h }, false, 0);
    const c = UIGraphicsGetCurrentContext();
    if (e.background >> 24 != 0) {
        CGContextSetFillColorWithColor(c, cgColor(e.background));
        CGContextAddPath(c, outer);
        CGContextFillPath(c);
    }
    if (d.gradient_count > 0) {
        var stop_colors: [64]u32 = undefined;
        var stop_at: [64]f32 = undefined;
        const n = d.blendedStops(&stop_colors, &stop_at);
        var cols: [64]id = undefined;
        var locs: [64]CGFloat = undefined;
        for (0..n) |k| {
            cols[k] = objc.send(color(stop_colors[k]), "CGColor");
            locs[k] = stop_at[k];
        }
        const array = objc.msgSend(*const fn (id, objc.SEL, [*]id, usize) callconv(.c) id)(objc.class("NSArray"), objc.sel("arrayWithObjects:count:"), &cols, n);
        const space = CGColorSpaceCreateDeviceRGB();
        defer CGColorSpaceRelease(space);
        const g = CGGradientCreateWithColors(space, array, &locs);
        defer CGGradientRelease(g);
        // The CSS gradient line through the centre.
        const ang = std.math.degreesToRadians(@as(f64, d.gradient_angle));
        const dx = @sin(ang);
        const dy = -@cos(ang);
        const len = @abs(w * dx) + @abs(h * dy);
        CGContextSaveGState(c);
        CGContextAddPath(c, outer);
        CGContextClip(c);
        CGContextDrawLinearGradient(c, g, .{ .x = w / 2 - dx * len / 2, .y = h / 2 - dy * len / 2 }, .{ .x = w / 2 + dx * len / 2, .y = h / 2 + dy * len / 2 }, 3);
        CGContextRestoreGState(c);
    }
    const bw = d.border_widths;
    const t: CGFloat = bw[0];
    const rw: CGFloat = bw[1];
    const bt: CGFloat = bw[2];
    const l: CGFloat = bw[3];
    if (t > 0 or rw > 0 or bt > 0 or l > 0) {
        const inner_r = [4]CGFloat{ @max(0, radii[0] - @max(l, t)), @max(0, radii[1] - @max(rw, t)), @max(0, radii[2] - @max(rw, bt)), @max(0, radii[3] - @max(l, bt)) };
        const outer_c = [4][2]CGFloat{ .{ 0, 0 }, .{ w, 0 }, .{ w, h }, .{ 0, h } };
        const inner_c = [4][2]CGFloat{ .{ l, t }, .{ w - rw, t }, .{ w - rw, h - bt }, .{ l, h - bt } };
        const inner = if (w - l - rw > 0 and h - t - bt > 0) roundedPath(l, t, w - l - rw, h - t - bt, inner_r) else null;
        defer if (inner != null) CGPathRelease(inner);
        for (0..4) |s| {
            if (bw[s] <= 0 or d.border_colors[s] >> 24 == 0) continue;
            const a = s;
            const b2 = (s + 1) % 4;
            CGContextSaveGState(c);
            // The side's part, cut along the diagonals between its outer and inner corners.
            const q = CGPathCreateMutable();
            defer CGPathRelease(q);
            CGPathMoveToPoint(q, null, outer_c[a][0] + (outer_c[a][0] - inner_c[a][0]) * 100, outer_c[a][1] + (outer_c[a][1] - inner_c[a][1]) * 100);
            CGPathAddLineToPoint(q, null, outer_c[b2][0] + (outer_c[b2][0] - inner_c[b2][0]) * 100, outer_c[b2][1] + (outer_c[b2][1] - inner_c[b2][1]) * 100);
            CGPathAddLineToPoint(q, null, inner_c[b2][0], inner_c[b2][1]);
            CGPathAddLineToPoint(q, null, inner_c[a][0], inner_c[a][1]);
            CGPathCloseSubpath(q);
            CGContextAddPath(c, q);
            CGContextClip(c);
            // The ring between the box and its inside.
            CGContextAddPath(c, outer);
            if (inner != null) CGContextAddPath(c, inner);
            CGContextEOClip(c);
            CGContextSetFillColorWithColor(c, cgColor(d.border_colors[s]));
            CGContextFillRect(c, .{ .w = w, .h = h });
            CGContextRestoreGState(c);
        }
    }
    const img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (img != null) objc.sendVoid1(v, "setBackgroundColor:", objc.send1(objc.class("UIColor"), "colorWithPatternImage:", img));

    const set_ptr = objc.msgSend(*const fn (id, objc.SEL, ?*anyopaque) callconv(.c) void);
    if (d.shadow_color >> 24 != 0) {
        // With a shadow path the text casts no shadow; only the box does.
        set_ptr(layer, objc.sel("setShadowPath:"), outer);
        set_ptr(layer, objc.sel("setShadowColor:"), cgColor(d.shadow_color | 0xff000000));
        objc.msgSend(*const fn (id, objc.SEL, f32) callconv(.c) void)(layer, objc.sel("setShadowOpacity:"), @as(f32, @floatFromInt(d.shadow_color >> 24)) / 255);
        objc.msgSend(*const fn (id, objc.SEL, objc.CGSize) callconv(.c) void)(layer, objc.sel("setShadowOffset:"), .{ .w = d.shadow[0], .h = d.shadow[1] });
        objc.sendVoidFloat(layer, "setShadowRadius:", d.shadow[2] / 2);
    } else {
        objc.msgSend(*const fn (id, objc.SEL, f32) callconv(.c) void)(layer, objc.sel("setShadowOpacity:"), 0);
    }
}
