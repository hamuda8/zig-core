//! Configuration from the environment and an optional `.env` file, the way the Node servers
//! read it (`node --env-file-if-exists=.env.production`): real environment variables win over
//! the file, so a deployment can override one value without editing it.

const std = @import("std");

pub const Env = struct {
    environ: *const std.process.Environ.Map,
    file: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// Reads the first of `files` that exists (none is fine).
    pub fn load(arena: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, files: []const []const u8) !Env {
        var e: Env = .{ .environ = environ };
        for (files) |path| {
            const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch continue;
            try e.parse(arena, text);
            break;
        }
        return e;
    }

    /// `KEY=value` lines; `#` comments, blank lines, `export ` prefixes and quotes allowed.
    pub fn parse(e: *Env, arena: std.mem.Allocator, text: []const u8) !void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            var line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trimStart(u8, line["export ".len..], " ");
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            var value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[value.len - 1] == value[0]) {
                value = value[1 .. value.len - 1];
            } else if (std.mem.indexOf(u8, value, " #")) |hash| {
                value = std.mem.trimEnd(u8, value[0..hash], " \t");
            }
            try e.file.put(arena, key, value);
        }
    }

    pub fn get(e: *const Env, name: []const u8) ?[]const u8 {
        if (e.environ.get(name)) |v| return v;
        return e.file.get(name);
    }

    /// The value, or `default` when unset or empty.
    pub fn str(e: *const Env, name: []const u8, default: []const u8) []const u8 {
        const v = e.get(name) orelse return default;
        return if (v.len == 0) default else v;
    }

    pub fn int(e: *const Env, comptime T: type, name: []const u8, default: T) T {
        const v = e.get(name) orelse return default;
        return std.fmt.parseInt(T, v, 10) catch default;
    }

    /// "true" is true, "false" is false, anything else is `default`.
    pub fn flag(e: *const Env, name: []const u8, default: bool) bool {
        const v = e.get(name) orelse return default;
        if (std.mem.eql(u8, v, "true")) return true;
        if (std.mem.eql(u8, v, "false")) return false;
        return default;
    }
};

test "file values, quotes, comments, and the environment winning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map = std.process.Environ.Map.init(arena.allocator());
    try map.put("PORT", "6000");
    var e: Env = .{ .environ = &map };
    try e.parse(arena.allocator(),
        \\# Maps
        \\PORT=5005
        \\export MONGO_URI="mongodb://127.0.0.1:27017/Maps"
        \\VALHALLA_URL=http://127.0.0.1:8002/route # local Valhalla
        \\EMPTY=
        \\TRUST_PROXY=true
    );
    try std.testing.expectEqual(@as(u16, 6000), e.int(u16, "PORT", 1));
    try std.testing.expectEqualStrings("mongodb://127.0.0.1:27017/Maps", e.str("MONGO_URI", ""));
    try std.testing.expectEqualStrings("http://127.0.0.1:8002/route", e.str("VALHALLA_URL", ""));
    try std.testing.expectEqualStrings("fallback", e.str("EMPTY", "fallback"));
    try std.testing.expect(e.flag("TRUST_PROXY", false));
}
