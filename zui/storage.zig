//! Small values kept on the device across launches: settings, and (secure) sign-in tokens.
//! Web: localStorage (the web apps sign in with cookies). Android: SharedPreferences, secure
//! values encrypted with a key in the Android Keystore. iOS: NSUserDefaults, secure values in
//! the Keychain. Synchronous; for small strings only.

const std = @import("std");
const zui = @import("zui.zig");

pub const Options = struct {
    /// A secret (a session token): kept where the platform protects it.
    secure: bool = false,
};

/// The value of `key`, or null. Owned by `gpa`.
pub fn get(gpa: std.mem.Allocator, key: []const u8, o: Options) ?[]u8 {
    return zui.host.storageGet(gpa, key, o.secure);
}

pub fn set(key: []const u8, value: []const u8, o: Options) void {
    zui.host.storageSet(key, value, o.secure);
}

pub fn remove(key: []const u8, o: Options) void {
    zui.host.storageRemove(key, o.secure);
}
