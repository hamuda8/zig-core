//! Text helpers done in Zig, so they come out the same on every platform.

const std = @import("std");

/// `s` in capitals: ASCII, Latin-1, Latin Extended-A, Greek and Cyrillic (as CSS's
/// `text-transform: uppercase` does them; ß becomes SS). Other characters (Arabic has no case)
/// stay as they are.
pub fn upper(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, s.len);
    const view = std.unicode.Utf8View.init(s) catch return a.dupe(u8, s);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == 0xDF) {
            try out.appendSlice(a, "SS");
            continue;
        }
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(upperCodepoint(cp), &buf) catch unreachable;
        try out.appendSlice(a, buf[0..n]);
    }
    return out.items;
}

fn upperCodepoint(c: u21) u21 {
    return switch (c) {
        'a'...'z' => c - 32,
        0xB5 => 0x39C, // micro sign
        0xE0...0xF6, 0xF8...0xFE => c - 32,
        0xFF => 0x178,
        0x131 => 'I',
        0x17F => 'S',
        // Pairs: upper case even, lower case odd...
        0x100...0x12F, 0x132...0x137, 0x14A...0x177 => if (c & 1 == 1) c - 1 else c,
        // ...or upper case odd, lower case even.
        0x139...0x148, 0x179...0x17E => if (c & 1 == 0) c - 1 else c,
        0x3AC => 0x386,
        0x3AD...0x3AF => c - 37,
        0x3B1...0x3C1, 0x3C3...0x3CB => c - 32,
        0x3C2 => 0x3A3, // final sigma
        0x3CC => 0x38C,
        0x3CD, 0x3CE => c - 63,
        0x430...0x44F => c - 32,
        0x450...0x45F => c - 80,
        0x460...0x481, 0x48A...0x4BF, 0x4D0...0x52F => if (c & 1 == 1) c - 1 else c,
        else => c,
    };
}

test upper {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("HELLO, WORLD 1", try upper(a, "Hello, world 1"));
    try std.testing.expectEqualStrings("ÉTÉ STRASSE ŁÓDŹ", try upper(a, "été straße łódź"));
    try std.testing.expectEqualStrings("ΣΟΦΊΑ ПРИВЕТ", try upper(a, "σοφία привет"));
    try std.testing.expectEqualStrings("مرحبا", try upper(a, "مرحبا"));
}
