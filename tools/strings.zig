//! Collects every translatable string of an app: the literal first argument of each `t(...)`
//! and `tf(...)` call in its .zig files. Writes a sorted JSON array, so Lassan can translate the
//! whole app ahead of time instead of string by string.
//!
//! strings <source dir> <out.json>

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) return error.Usage;

    var found: std.StringArrayHashMapUnmanaged(void) = .empty;
    var dir = try Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const source = try dir.readFileAllocOptions(io, entry.path, arena, .limited(16 * 1024 * 1024), .of(u8), 0);
        try collect(arena, source, &found);
    }

    const keys = found.keys();
    std.mem.sort([]const u8, keys, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(keys, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = out.written() });
}

/// Adds the literal of every `t("...")` / `tf("...", ...)` in `source`.
pub fn collect(arena: std.mem.Allocator, source: [:0]const u8, found: *std.StringArrayHashMapUnmanaged(void)) !void {
    var tokens: std.zig.Tokenizer = .init(source);
    var window: [3]std.zig.Token = undefined;
    var n: usize = 0;
    while (true) {
        const tok = tokens.next();
        if (tok.tag == .eof) break;
        window[0] = window[1];
        window[1] = window[2];
        window[2] = tok;
        n += 1;
        if (n < 3) continue;
        const name = source[window[0].loc.start..window[0].loc.end];
        if (window[0].tag == .identifier and (std.mem.eql(u8, name, "t") or std.mem.eql(u8, name, "tf")) and
            window[1].tag == .l_paren and window[2].tag == .string_literal)
        {
            const literal = source[window[2].loc.start..window[2].loc.end];
            const text = std.zig.string_literal.parseAlloc(arena, literal) catch continue;
            try found.put(arena, std.mem.trim(u8, text, " \t\r\n"), {});
        }
    }
}

test collect {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var found: std.StringArrayHashMapUnmanaged(void) = .empty;
    try collect(arena.allocator(),
        \\ui.text(ui.t("Sign in"), .{});
        \\const s = zui.i18n.t("Search");
        \\ui.tf("{n} new messages", .{ .n = 3 });
        \\ui.text("not translated", .{});
        \\ui.t(variable);
    , &found);
    try std.testing.expectEqual(3, found.count());
    try std.testing.expect(found.contains("Sign in"));
    try std.testing.expect(found.contains("{n} new messages"));
}
