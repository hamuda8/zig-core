//! Command-line access to the geo index, for building and trying regions by hand:
//!   geo refresh <regions-dir>                   build missing or outdated indexes
//!   geo search <regions-dir> <text> [lat lng]   search, optionally near a point
//!   geo reverse <regions-dir> <lat> <lng>       the place at a point
//! GEO_LANG=en (or ar, ...) shows names in that language.

const std = @import("std");
const geo = @import("geo");

fn log(line: []const u8) void {
    std.debug.print("{s}\n", .{line});
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: geo refresh|search|reverse <regions-dir> ...\n", .{});
        return;
    }
    var regions = geo.Regions.init(init.io, init.gpa, args[2]);
    defer regions.deinit();
    regions.log = log;
    try regions.refresh();

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    const w = &out.interface;
    const arena = init.arena.allocator();
    const lang = init.environ_map.get("GEO_LANG");
    if (std.mem.eql(u8, args[1], "search") and args.len >= 4) {
        const near: ?[2]f64 = if (args.len >= 6) .{ try std.fmt.parseFloat(f64, args[4]), try std.fmt.parseFloat(f64, args[5]) } else null;
        const started = std.Io.Timestamp.now(init.io, .awake);
        const results = try regions.search(arena, args[3], near, lang, 6);
        const us = started.untilNow(init.io, .awake).toMicroseconds();
        for (results) |p| try w.print("{s}  ({d:.5}, {d:.5})  [{s}]\n", .{ p.label, p.lat, p.lng, p.country orelse "" });
        try w.print("{d} results in {d} µs\n", .{ results.len, us });
    } else if (std.mem.eql(u8, args[1], "reverse") and args.len >= 5) {
        const p = try regions.reverse(arena, try std.fmt.parseFloat(f64, args[3]), try std.fmt.parseFloat(f64, args[4]), lang);
        if (p) |pl| try w.print("{s}  ({d:.5}, {d:.5}) street={s} area={s} city={s} state={s} [{s}]\n", .{ pl.label, pl.lat, pl.lng, pl.street orelse "-", pl.area orelse "-", pl.city orelse "-", pl.state orelse "-", pl.country orelse "" }) else try w.print("nothing near\n", .{});
    }
    try w.flush();
}
