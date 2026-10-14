//! Our apps that share one Wufour sign-in on a phone (zui.wufour; Android: ZuiAuthProvider at
//! `<package>.wufourauth`, which tools/apk.zig adds to each app's manifest with the queries for
//! the others). A new app is added here; all must be signed with the same key.

pub const packages = [_][]const u8{ "com.wufour.turf", "com.wufour.reseal", "com.wufour.maps" };

/// The packages, comma-separated (what the Android host and tools/apk.zig take).
pub const csv = blk: {
    var s: []const u8 = "";
    for (packages, 0..) |p, i| s = s ++ (if (i == 0) "" else ",") ++ p;
    break :blk s;
};
