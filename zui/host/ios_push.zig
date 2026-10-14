//! iOS push: APNs alert pushes (UIApplication registerForRemoteNotifications, token "apns")
//! and PushKit VoIP pushes for incoming calls (PKPushRegistry, token "voip").
//!
//! Tokens are the device tokens in lowercase hex, as APNs takes them. A push's payload (its
//! userInfo / dictionaryPayload) reaches the app's `pushMessage` as JSON:
//!   - a VoIP push: iOS launches the app in the background if it is not running. Apple requires
//!     the call to be reported to CallKit before the handler returns, or it stops delivering
//!     VoIP pushes to the app: the runtime starts without a screen if needed (startHeadless),
//!     runs `pushMessage` and the update it returns at once, so the app's `fx.ringCall` reaches
//!     CXProvider reportNewIncomingCall inside the handler. The registry is created again at
//!     every launch once the app has registered (iOS delivers to the registry of that launch).
//!   - an alert push the user taps (UNUserNotificationCenter didReceiveNotificationResponse) and
//!     a background push (content-available, didReceiveRemoteNotification): the same.
//! The app needs the push entitlement (aps-environment) and the "voip" and
//! "remote-notification" UIBackgroundModes in its Info.plist; it links PushKit and
//! UserNotifications (PushKit is also opened at run time, so a build without it still runs).

const std = @import("std");
const zui = @import("../zui.zig");
const objc = @import("../platform/objc.zig");

const id = objc.id;

pub const Callbacks = struct {
    token: *const fn ([]const u8, zui.PushKind) void,
    message: *const fn ([]const u8) void,
    /// Starts the runtime without a screen when nothing started it yet.
    wake: *const fn () void,
};

var cb: ?Callbacks = null;
var registry: id = null;
const voip_flag = "zui.push.voip";

extern "c" fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;

pub fn init(c: Callbacks) void {
    cb = c;
    objc.defineClass("ZuiPushKit", "NSObject", &.{"PKPushRegistryDelegate"}, &.{
        .{ "pushRegistry:didUpdatePushCredentials:forType:", @ptrCast(&credentials), "v@:@@@" },
        .{ "pushRegistry:didReceiveIncomingPushWithPayload:forType:withCompletionHandler:", @ptrCast(&incoming), "v@:@@@@?" },
        .{ "pushRegistry:didInvalidatePushTokenForType:", @ptrCast(&invalidated), "v@:@@" },
    });
}

/// UIApplicationDelegate methods for ZuiAppDelegate.
pub const app_delegate_methods = [_]struct { [*:0]const u8, *const anyopaque, [*:0]const u8 }{
    .{ "application:didFinishLaunchingWithOptions:", @ptrCast(&launched), "B@:@@" },
    .{ "application:didRegisterForRemoteNotificationsWithDeviceToken:", @ptrCast(&registered), "v@:@@" },
    .{ "application:didFailToRegisterForRemoteNotificationsWithError:", @ptrCast(&failed), "v@:@@" },
    .{ "application:didReceiveRemoteNotification:fetchCompletionHandler:", @ptrCast(&remote), "v@:@@@?" },
};

/// For ZuiNotifications (UNUserNotificationCenterDelegate): a notification was tapped.
pub const response_method = .{ "userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:", @as(*const anyopaque, @ptrCast(&responded)), "v@:@@@?" };

fn defaults() id {
    return objc.send(objc.class("NSUserDefaults"), "standardUserDefaults");
}

/// fx.registerPush: alert permission is asked by the notification center (the host's
/// notificationCenter), then APNs and PushKit.
pub fn register() void {
    const app = objc.send(objc.class("UIApplication"), "sharedApplication");
    objc.sendVoid(app, "registerForRemoteNotifications");
    const key = objc.nsString(voip_flag);
    defer objc.release(key);
    objc.msgSend(*const fn (id, objc.SEL, bool, id) callconv(.c) void)(defaults(), objc.sel("setBool:forKey:"), true, key);
    voip();
}

fn voip() void {
    if (registry != null) return;
    _ = dlopen("/System/Library/Frameworks/PushKit.framework/PushKit", 1);
    const cls = objc.class("PKPushRegistry");
    if (cls == null) return;
    registry = objc.send1(objc.send(cls, "alloc"), "initWithQueue:", null);
    objc.sendVoid1(registry, "setDelegate:", objc.new("ZuiPushKit"));
    const t = objc.nsString("PKPushTypeVoIP");
    defer objc.release(t);
    objc.sendVoid1(registry, "setDesiredPushTypes:", objc.send1(objc.class("NSSet"), "setWithObject:", t));
}

fn hex(data: id, buf: []u8) []const u8 {
    const len: usize = @intCast(objc.sendInt(data, "length"));
    const bytes = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) ?[*]const u8)(data, objc.sel("bytes")) orelse return "";
    const n = @min(len, buf.len / 2);
    const digits = "0123456789abcdef";
    for (bytes[0..n], 0..) |b, i| {
        buf[2 * i] = digits[b >> 4];
        buf[2 * i + 1] = digits[b & 15];
    }
    return buf[0 .. 2 * n];
}

/// A payload dictionary as JSON, handed to the app.
fn deliver(dict: id) void {
    const c = cb orelse return;
    c.wake();
    const json_cls = objc.class("NSJSONSerialization");
    const valid = objc.msgSend(*const fn (id, objc.SEL, id) callconv(.c) bool)(json_cls, objc.sel("isValidJSONObject:"), dict);
    if (dict == null or !valid) return c.message("{}");
    const data = objc.msgSend(*const fn (id, objc.SEL, id, usize, ?*id) callconv(.c) id)(json_cls, objc.sel("dataWithJSONObject:options:error:"), dict, 0, null);
    if (data == null) return c.message("{}");
    const len: usize = @intCast(objc.sendInt(data, "length"));
    const bytes = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) ?[*]const u8)(data, objc.sel("bytes")) orelse return c.message("{}");
    c.message(bytes[0..len]);
}

fn launched(_: id, _: objc.SEL, _: id, _: id) callconv(.c) bool {
    // A VoIP push may be what launched the app: its registry must exist now.
    const key = objc.nsString(voip_flag);
    defer objc.release(key);
    if (objc.msgSend(*const fn (id, objc.SEL, id) callconv(.c) bool)(defaults(), objc.sel("boolForKey:"), key)) voip();
    // Taps on notifications are reported to the center's delegate: it must be there at launch.
    const center = objc.send(objc.class("UNUserNotificationCenter"), "currentNotificationCenter");
    if (objc.send(center, "delegate") == null) objc.sendVoid1(center, "setDelegate:", objc.new("ZuiNotifications"));
    return true;
}

fn registered(_: id, _: objc.SEL, _: id, token: id) callconv(.c) void {
    var buf: [512]u8 = undefined;
    if (cb) |c| c.token(hex(token, &buf), .apns);
}

fn failed(_: id, _: objc.SEL, _: id, err: id) callconv(.c) void {
    const desc = objc.send(err, "localizedDescription");
    const utf8 = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) ?[*:0]const u8)(desc, objc.sel("UTF8String"));
    zui.log("push: APNs registration failed: {s}", .{if (utf8) |p| std.mem.span(p) else "?"});
}

fn remote(_: id, _: objc.SEL, _: id, info: id, handler: *objc.BlockHeader) callconv(.c) void {
    deliver(info);
    const invoke: *const fn (*objc.BlockHeader, usize) callconv(.c) void = @ptrCast(@alignCast(handler.invoke));
    invoke(handler, 0); // UIBackgroundFetchResultNewData
}

fn responded(_: id, _: objc.SEL, _: id, response: id, handler: *objc.BlockHeader) callconv(.c) void {
    const info = objc.send(objc.send(objc.send(objc.send(response, "notification"), "request"), "content"), "userInfo");
    if (info != null and objc.sendInt(info, "count") > 0) deliver(info);
    const invoke: *const fn (*objc.BlockHeader) callconv(.c) void = @ptrCast(@alignCast(handler.invoke));
    invoke(handler);
}

fn credentials(_: id, _: objc.SEL, _: id, creds: id, _: id) callconv(.c) void {
    var buf: [512]u8 = undefined;
    if (cb) |c| c.token(hex(objc.send(creds, "token"), &buf), .voip);
}

fn incoming(_: id, _: objc.SEL, _: id, payload: id, _: id, handler: *objc.BlockHeader) callconv(.c) void {
    // The app reports the call to CallKit while this runs (fx.ringCall in its update).
    deliver(objc.send(payload, "dictionaryPayload"));
    const invoke: *const fn (*objc.BlockHeader) callconv(.c) void = @ptrCast(@alignCast(handler.invoke));
    invoke(handler);
}

fn invalidated(_: id, _: objc.SEL, _: id, _: id) callconv(.c) void {}
