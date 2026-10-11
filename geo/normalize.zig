//! Search text normalization, the same for the index and for queries, so that the ways people
//! type a name match the way it is written in the map data:
//! - Latin: lower case, accents removed (é → e, ß → ss, ø → o, ...).
//! - Arabic: diacritics and tatweel removed; أ إ آ ٱ → ا, ى → ي, ة → ه, ؤ → و, ئ → ي; Persian
//!   and Urdu letter forms → Arabic ones.
//! - Arabic-Indic and Persian digits → 0-9.
//! - Everything else that is not a letter or digit separates words.

const std = @import("std");

/// Appends the normalized words of `text` to `out`, separated by single spaces.
pub fn normalize(gpa: std.mem.Allocator, text: []const u8, out: *std.ArrayList(u8)) !void {
    var space = out.items.len > 0;
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (true) {
        const cp = nextCodepoint(&it) orelse break;
        const mapped = fold(cp);
        switch (mapped) {
            .skip => {},
            .sep => space = true,
            .text => |s| {
                if (space and out.items.len > 0) try out.append(gpa, ' ');
                space = false;
                try out.appendSlice(gpa, s.slice());
            },
        }
    }
}

/// Invalid UTF-8 is skipped byte by byte rather than failing.
fn nextCodepoint(it: *std.unicode.Utf8Iterator) ?u21 {
    while (it.i < it.bytes.len) {
        const n = std.unicode.utf8ByteSequenceLength(it.bytes[it.i]) catch {
            it.i += 1;
            continue;
        };
        if (it.i + n > it.bytes.len) return null;
        const cp = std.unicode.utf8Decode(it.bytes[it.i..][0..n]) catch {
            it.i += 1;
            continue;
        };
        it.i += n;
        return cp;
    }
    return null;
}

const Small = struct {
    buf: [4]u8 = undefined,
    len: u8 = 0,

    fn of(s: []const u8) Small {
        var r: Small = .{ .len = @intCast(s.len) };
        @memcpy(r.buf[0..s.len], s);
        return r;
    }
    fn cp(c: u21) Small {
        var r: Small = .{};
        r.len = std.unicode.utf8Encode(c, &r.buf) catch 0;
        return r;
    }
    pub fn slice(s: *const Small) []const u8 {
        return s.buf[0..s.len];
    }
};

const Folded = union(enum) { skip, sep, text: Small };

fn fold(c: u21) Folded {
    if (c < 0x80) {
        const b: u8 = @intCast(c);
        if (std.ascii.isAlphanumeric(b)) return .{ .text = Small.of(&.{std.ascii.toLower(b)}) };
        if (b == '\'') return .skip; // O'Brien, Ma'arrat
        return .sep;
    }
    // Latin-1 and Latin Extended-A.
    if (c >= 0xC0 and c <= 0x17F) {
        if (latin(c)) |s| return .{ .text = Small.of(s) };
        if (c == 0xD7 or c == 0xF7) return .sep;
    }
    // Combining diacritical marks.
    if (c >= 0x300 and c <= 0x36F) return .skip;
    // Arabic.
    if (c >= 0x600 and c <= 0x6FF) return arabic(c);
    // Arabic presentation forms are rare in data; keep them as letters.
    // General punctuation, CJK punctuation, spaces.
    if ((c >= 0x2000 and c <= 0x206F) or (c >= 0x3000 and c <= 0x303F) or c == 0xA0 or c == 0xAB or c == 0xBB or c == 0xB7) {
        if (c == 0x200C or c == 0x200D) return .skip; // zero-width (non-)joiners inside words
        return .sep;
    }
    if (c >= 0x80 and c < 0xC0) return .sep; // Latin-1 punctuation and symbols
    // Greek and Cyrillic capitals → small.
    if (c >= 0x391 and c <= 0x3A9) return .{ .text = Small.cp(c + 0x20) };
    if (c >= 0x410 and c <= 0x42F) return .{ .text = Small.cp(c + 0x20) };
    if (c >= 0x400 and c <= 0x40F) return .{ .text = Small.cp(c + 0x50) };
    return .{ .text = Small.cp(c) };
}

fn arabic(c: u21) Folded {
    return switch (c) {
        // Tashkeel, Quranic marks, superscript alef, tatweel.
        0x610...0x61A, 0x64B...0x65F, 0x670, 0x6D6...0x6ED, 0x640 => .skip,
        // Punctuation: comma, semicolon, question mark, full stop, percent and separators.
        0x60C, 0x60D, 0x61B, 0x61F, 0x66A...0x66D, 0x6D4 => .sep,
        // Digits.
        0x660...0x669 => .{ .text = Small.of(&.{@as(u8, @intCast(c - 0x660)) + '0'}) },
        0x6F0...0x6F9 => .{ .text = Small.of(&.{@as(u8, @intCast(c - 0x6F0)) + '0'}) },
        // Alef forms.
        0x622, 0x623, 0x625, 0x671, 0x672, 0x673 => .{ .text = Small.cp(0x627) },
        0x649, 0x6CC, 0x6D0, 0x626 => .{ .text = Small.cp(0x64A) }, // alef maqsura, Farsi yeh, yeh with hamza → yeh
        0x629, 0x6C0, 0x6C1, 0x6C3, 0x6D5 => .{ .text = Small.cp(0x647) }, // teh marbuta, heh forms → heh
        0x624 => .{ .text = Small.cp(0x648) }, // waw with hamza → waw
        0x6A9, 0x6AA => .{ .text = Small.cp(0x643) }, // keheh → kaf
        0x621 => .skip, // lone hamza: often dropped in spelling
        else => .{ .text = Small.cp(c) },
    };
}

fn latin(c: u21) ?[]const u8 {
    return switch (c) {
        0xC0...0xC5, 0xE0...0xE5, 0x100...0x105 => "a",
        0xC6, 0xE6 => "ae",
        0xC7, 0xE7, 0x106...0x10D => "c",
        0xD0, 0xF0, 0x10E...0x111 => "d",
        0xC8...0xCB, 0xE8...0xEB, 0x112...0x11B => "e",
        0x11C...0x123 => "g",
        0x124...0x127 => "h",
        0xCC...0xCF, 0xEC...0xEF, 0x128...0x131 => "i",
        0x132, 0x133 => "ij",
        0x134, 0x135 => "j",
        0x136...0x138 => "k",
        0x139...0x142 => "l",
        0xD1, 0xF1, 0x143...0x14B => "n",
        0xD2...0xD6, 0xD8, 0xF2...0xF6, 0xF8, 0x14C...0x151 => "o",
        0x152, 0x153 => "oe",
        0x154...0x159 => "r",
        0x15A...0x161 => "s",
        0xDF => "ss",
        0x162...0x167 => "t",
        0xDE, 0xFE => "th",
        0xD9...0xDC, 0xF9...0xFC, 0x168...0x173 => "u",
        0x174, 0x175 => "w",
        0xDD, 0xFD, 0xFF, 0x176...0x178 => "y",
        0x179...0x17E => "z",
        0x17F => "s",
        else => null,
    };
}

/// The words of normalized text.
pub fn words(normalized: []const u8) std.mem.TokenIterator(u8, .scalar) {
    return std.mem.tokenizeScalar(u8, normalized, ' ');
}

/// "ال" (the Arabic article) at the start of a word that is long enough to keep a stem.
pub fn arabicStem(word: []const u8) ?[]const u8 {
    const al = "\u{627}\u{644}";
    if (word.len > al.len + 4 and std.mem.startsWith(u8, word, al)) return word[al.len..];
    return null;
}

fn expectNorm(want: []const u8, text: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try normalize(std.testing.allocator, text, &out);
    try std.testing.expectEqualStrings(want, out.items);
}

test normalize {
    try expectNorm("cafe de flore", "  Café de  Flore! ");
    try expectNorm("strasse 12", "Straße 12");
    try expectNorm("o brien", "O\u{2019}Brien");
    try expectNorm("obrien", "O'Brien");
    try expectNorm("kuala lumpur", "KUALA-LUMPUR");
    // Hamza forms, teh marbuta, alef maqsura, diacritics, tatweel, digits.
    try expectNorm("\u{627}\u{644}\u{645}\u{632}\u{647}", "المِزّة");
    try expectNorm("\u{627}\u{62d}\u{645}\u{62f}", "أحمد");
    try expectNorm("\u{645}\u{635}\u{637}\u{641}\u{64a}", "مصطفى");
    try expectNorm("\u{634}\u{627}\u{631}\u{639} 29", "شـارع ٢٩");
    try expectNorm("\u{62f}\u{645}\u{634}\u{642} damascus", "دمشق، Damascus");
}

test arabicStem {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try normalize(std.testing.allocator, "الميدان", &out);
    try std.testing.expectEqualStrings("\u{645}\u{64a}\u{62f}\u{627}\u{646}", arabicStem(out.items).?);
    try std.testing.expect(arabicStem("\u{627}\u{644}\u{645}") == null);
}
