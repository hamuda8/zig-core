//! Wufour's own fonts on the phones: which face carries which script and weight.
//!
//! The web shells load Wufour Sans (English) and Wufour Arabic (Arabic, no Latin letters) as
//! woff2 through CSS. On Android and iOS the hosts draw with the same pair, from the `.ttf`
//! files in `shells/fonts/` that `addApp` packages (Android: `assets/fonts/`; iOS: the bundle,
//! listed in each app's Info.plist `UIAppFonts` and registered again at start). This file is the
//! one rule both hosts follow, so the two phones agree with each other and with the web:
//!
//! - **Weight:** the faces come in 400, 500 and 700 (design system: body, labels, headings).
//!   Any other weight an app asks for is snapped to the nearest of the three (`weight`).
//! - **Script:** text with an Arabic letter in it is set in Wufour Arabic with Wufour Sans as
//!   the fallback (Latin words inside Arabic keep the Sans), everything else in Wufour Sans with
//!   Wufour Arabic as the fallback. The primary face sets the line metrics; the fallback only
//!   fills in glyphs. Both hosts chain the system font after the pair, so symbols, CJK and the
//!   like still draw. Monospace stays the system monospace (code, keys, IDs).
//! - **Missing files** are never an error: a host that cannot load a face uses the system font
//!   for that text, as before.
//!
//! To refresh the fonts, copy `WufourType/dist/golden/*.ttf` over `shells/fonts/` (the names
//! below must stay the same) and rebuild the apps.

const std = @import("std");

/// Which family draws a run of text. The values travel to Java as ints.
pub const Face = enum(u8) {
    sans = 0,
    arabic = 1,
    /// The system monospace; never one of our files.
    mono = 2,

    /// The other Wufour face, which fills in the glyphs this one lacks.
    pub fn fallback(self: Face) Face {
        return switch (self) {
            .sans => .arabic,
            .arabic => .sans,
            .mono => .mono,
        };
    }
};

/// The three weights the files come in.
pub const weights = [_]u16{ 400, 500, 700 };

/// Where the files live in zig-core, and under `assets/` in an APK.
pub const dir = "fonts";
pub const sans_family = "WufourSansGolden";
pub const arabic_family = "WufourArabicGolden";

/// The nearest weight we have a file for.
pub fn weight(w: u16) u16 {
    if (w < 450) return 400;
    if (w < 600) return 500;
    return 700;
}

/// The weight a host should ask for: snapped for our faces, as given for the system monospace
/// (whose weights are the system's business).
pub fn hostWeight(mono: bool, w: u16) u16 {
    return if (mono) w else weight(w);
}

/// "Regular", "Medium" or "Bold": the style part of the file and PostScript names.
pub fn styleName(w: u16) []const u8 {
    return switch (weight(w)) {
        400 => "Regular",
        500 => "Medium",
        else => "Bold",
    };
}

/// The PostScript name (`fontWithName:` on iOS) of a face at a weight, which is also the file
/// name without `.ttf`. Monospace has none.
pub fn postscriptName(face: Face, w: u16) ?[]const u8 {
    return switch (face) {
        .sans => switch (weight(w)) {
            400 => sans_family ++ "-Regular",
            500 => sans_family ++ "-Medium",
            else => sans_family ++ "-Bold",
        },
        .arabic => switch (weight(w)) {
            400 => arabic_family ++ "-Regular",
            500 => arabic_family ++ "-Medium",
            else => arabic_family ++ "-Bold",
        },
        .mono => null,
    };
}

/// The file in `shells/fonts/` (and `assets/fonts/`) for a face at a weight.
pub fn fileName(face: Face, w: u16) ?[]const u8 {
    return switch (face) {
        .sans => switch (weight(w)) {
            400 => sans_family ++ "-Regular.ttf",
            500 => sans_family ++ "-Medium.ttf",
            else => sans_family ++ "-Bold.ttf",
        },
        .arabic => switch (weight(w)) {
            400 => arabic_family ++ "-Regular.ttf",
            500 => arabic_family ++ "-Medium.ttf",
            else => arabic_family ++ "-Bold.ttf",
        },
        .mono => null,
    };
}

/// Every file the packaging ships, in a fixed order (sans then arabic, 400, 500, 700).
pub const files = [_][]const u8{
    sans_family ++ "-Regular.ttf",   sans_family ++ "-Medium.ttf",   sans_family ++ "-Bold.ttf",
    arabic_family ++ "-Regular.ttf", arabic_family ++ "-Medium.ttf", arabic_family ++ "-Bold.ttf",
};

/// The face that draws `s`: the system monospace for `mono`, Wufour Arabic when the text has an
/// Arabic letter, Wufour Sans otherwise.
pub fn faceFor(mono: bool, s: []const u8) Face {
    if (mono) return .mono;
    return if (hasArabic(s)) .arabic else .sans;
}

/// Whether a code point is Arabic-script: the Arabic block and its supplements, presentation
/// forms included. Digits and punctuation of the block count too (they are drawn by the Arabic
/// face when they stand alone, as in a price written in Arabic-Indic digits).
pub fn isArabic(cp: u21) bool {
    return (cp >= 0x0600 and cp <= 0x06FF) or (cp >= 0x0750 and cp <= 0x077F) or
        (cp >= 0x0870 and cp <= 0x089F) or (cp >= 0x08A0 and cp <= 0x08FF) or
        (cp >= 0xFB50 and cp <= 0xFDFF) or (cp >= 0xFE70 and cp <= 0xFEFF);
}

/// Whether any character of `s` is Arabic-script. Bad UTF-8 is skipped byte by byte.
pub fn hasArabic(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x80) {
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(b) catch {
            i += 1;
            continue;
        };
        if (i + n > s.len) return false;
        const cp = std.unicode.utf8Decode(s[i .. i + n]) catch {
            i += 1;
            continue;
        };
        if (isArabic(cp)) return true;
        i += n;
    }
    return false;
}

const testing = std.testing;

test "weights snap to the three files" {
    try testing.expectEqual(@as(u16, 400), weight(100));
    try testing.expectEqual(@as(u16, 400), weight(400));
    try testing.expectEqual(@as(u16, 400), weight(449));
    try testing.expectEqual(@as(u16, 500), weight(450));
    try testing.expectEqual(@as(u16, 500), weight(500));
    try testing.expectEqual(@as(u16, 500), weight(599));
    try testing.expectEqual(@as(u16, 700), weight(600));
    try testing.expectEqual(@as(u16, 700), weight(700));
    try testing.expectEqual(@as(u16, 700), weight(900));
    try testing.expectEqual(@as(u16, 600), hostWeight(true, 600));
    try testing.expectEqual(@as(u16, 700), hostWeight(false, 600));
}

test "faces by script" {
    try testing.expectEqual(Face.sans, faceFor(false, "Hello"));
    try testing.expectEqual(Face.sans, faceFor(false, ""));
    try testing.expectEqual(Face.sans, faceFor(false, "Price 12,000 SYP"));
    try testing.expectEqual(Face.arabic, faceFor(false, "مرحبا"));
    try testing.expectEqual(Face.arabic, faceFor(false, "Order #12 جاهز"));
    try testing.expectEqual(Face.arabic, faceFor(false, "\u{FEF5}"));
    try testing.expectEqual(Face.mono, faceFor(true, "مرحبا"));
    try testing.expectEqual(Face.arabic, Face.sans.fallback());
    try testing.expectEqual(Face.sans, Face.arabic.fallback());
    // Hebrew and Persian: Persian letters are in the Arabic block, Hebrew is not.
    try testing.expectEqual(Face.arabic, faceFor(false, "پ"));
    try testing.expectEqual(Face.sans, faceFor(false, "שלום"));
    // Truncated UTF-8 does not crash.
    try testing.expect(!hasArabic("\xd9"));
}

test "names" {
    try testing.expectEqualStrings("WufourSansGolden-Regular", postscriptName(.sans, 400).?);
    try testing.expectEqualStrings("WufourSansGolden-Medium", postscriptName(.sans, 500).?);
    try testing.expectEqualStrings("WufourArabicGolden-Bold", postscriptName(.arabic, 800).?);
    try testing.expectEqualStrings("WufourArabicGolden-Medium.ttf", fileName(.arabic, 500).?);
    try testing.expect(postscriptName(.mono, 400) == null);
    try testing.expectEqual(@as(usize, 6), files.len);
    for (files) |f| try testing.expect(std.mem.endsWith(u8, f, ".ttf"));
    inline for (weights) |w| {
        try testing.expectEqualStrings(fileName(.sans, w).?, comptime (postscriptName(.sans, w).? ++ ".ttf"));
        try testing.expectEqualStrings(fileName(.arabic, w).?, comptime (postscriptName(.arabic, w).? ++ ".ttf"));
    }
}
