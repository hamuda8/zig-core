//! Translation, compatible with Lassan: the English text is the key, and a string is looked up
//! in `global.json` (every language), then `<lang>.json` (hand-written), then `temp/<lang>.json`
//! (machine translations). The files are the flat `{"English": "translation"}` objects Lassan
//! uses, so the same files serve web pages and the native apps.

const std = @import("std");

const Map = std.array_hash_map.String([]const u8);

pub const Locale = struct {
    lang: []const u8,
    /// Contents of `<lang>.json`.
    json: []const u8 = "{}",
    /// Contents of `temp/<lang>.json`.
    machine: []const u8 = "{}",
};

const Loaded = struct {
    lang: []const u8,
    hand: Map,
    machine: Map,
};

var arena_state: std.heap.ArenaAllocator = undefined;
var initialized = false;
var global: Map = .empty;
var locales: std.ArrayList(Loaded) = .empty;
var active: ?*const Loaded = null;
var lang_buf: [16]u8 = "en".* ++ @as([14]u8, @splat(0));
var lang_len: usize = 2;

/// Loads the bundles. Call once at startup; the app's built-in bundles come from @embedFile.
pub fn init(backing: std.mem.Allocator, global_json: []const u8, all: []const Locale) !void {
    if (initialized) arena_state.deinit();
    arena_state = .init(backing);
    initialized = true;
    const a = arena_state.allocator();
    global = try parse(a, global_json);
    locales = .empty;
    for (all) |l| try locales.append(a, .{ .lang = try a.dupe(u8, l.lang), .hand = try parse(a, l.json), .machine = try parse(a, l.machine) });
    selectActive();
}

pub fn deinit() void {
    if (initialized) arena_state.deinit();
    initialized = false;
    global = .empty;
    locales = .empty;
    active = null;
}

fn parse(a: std.mem.Allocator, json: []const u8) !Map {
    const parsed = try std.json.parseFromSliceLeaky(std.json.ArrayHashMap([]const u8), a, json, .{});
    var out: Map = .empty;
    var it = parsed.map.iterator();
    while (it.next()) |e| try out.put(a, std.mem.trim(u8, e.key_ptr.*, " \t\r\n"), e.value_ptr.*);
    return out;
}

/// Switches language ("en", "ar", ...). Languages without a bundle show the English text.
pub fn setLanguage(lang: []const u8) void {
    const n = @min(lang.len, lang_buf.len);
    @memcpy(lang_buf[0..n], lang[0..n]);
    lang_len = n;
    selectActive();
}

fn selectActive() void {
    active = null;
    for (locales.items) |*l| {
        if (std.mem.eql(u8, l.lang, language())) active = l;
    }
}

pub fn language() []const u8 {
    return lang_buf[0..lang_len];
}

const rtl_languages = [_][]const u8{ "ar", "fa", "he", "ur", "ps", "sd", "ug", "yi", "dv", "ckb" };

pub fn isRtl() bool {
    for (rtl_languages) |l| if (std.mem.eql(u8, l, language())) return true;
    return false;
}

/// The translation of `text` in the current language, or the English text itself.
///
/// The same English text can need different translations in different places ("Open" a task,
/// "Open" as a state). Such a text carries its context after a bar: `t("Open|task")` shows
/// "Open" in English and looks up the key "Open|task" first, then "Open". The bundles stay flat
/// `{"English": "translation"}` objects; a contextual key is a key with a bar in it. A bar
/// counts as a context only when what follows it is non-empty and has no spaces.
pub fn t(text: []const u8) []const u8 {
    if (splitContext(text)) |c| return tc(c.context, c.text);
    if (std.mem.eql(u8, language(), "en")) return text;
    return lookup(std.mem.trim(u8, text, " \t\r\n")) orelse text;
}

/// `text` translated in `context`: the key "text|context" first, then "text" alone. English
/// shows `text`.
pub fn tc(context: []const u8, text: []const u8) []const u8 {
    if (std.mem.eql(u8, language(), "en")) return text;
    const key = std.mem.trim(u8, text, " \t\r\n");
    var buf: [512]u8 = undefined;
    if (key.len + 1 + context.len <= buf.len) {
        @memcpy(buf[0..key.len], key);
        buf[key.len] = '|';
        @memcpy(buf[key.len + 1 ..][0..context.len], context);
        if (lookup(buf[0 .. key.len + 1 + context.len])) |v| return v;
    }
    return lookup(key) orelse text;
}

const Split = struct { text: []const u8, context: []const u8 };

fn splitContext(s: []const u8) ?Split {
    const bar = std.mem.lastIndexOfScalar(u8, s, '|') orelse return null;
    const context = s[bar + 1 ..];
    if (bar == 0 or context.len == 0 or std.mem.indexOfAny(u8, context, " \t\r\n") != null) return null;
    return .{ .text = s[0..bar], .context = context };
}

/// The English text of `s` without its context ("Open|task" -> "Open").
pub fn english(s: []const u8) []const u8 {
    return if (splitContext(s)) |c| c.text else s;
}

fn lookup(key: []const u8) ?[]const u8 {
    if (global.get(key)) |v| return v;
    if (active) |l| {
        if (l.hand.get(key)) |v| return v;
        if (l.machine.get(key)) |v| return v;
    }
    return null;
}

/// Translates `template`, then fills `{name}` with the field `name` of `args`.
/// `tf(arena, "{n} new messages", .{ .n = 3 })`
pub fn tf(arena: std.mem.Allocator, template: []const u8, args: anytype) []const u8 {
    var s: []const u8 = t(template);
    inline for (comptime std.meta.fieldNames(@TypeOf(args))) |name| {
        const value = @field(args, name);
        const text = switch (@typeInfo(@TypeOf(value))) {
            .int, .comptime_int, .float, .comptime_float => std.fmt.allocPrint(arena, "{d}", .{value}) catch return s,
            else => std.fmt.allocPrint(arena, "{s}", .{value}) catch return s,
        };
        s = std.mem.replaceOwned(u8, arena, s, "{" ++ name ++ "}", text) catch return s;
    }
    return s;
}

const testing = std.testing;

test "lookup order is global, then hand-written, then machine" {
    try init(testing.allocator,
        \\{"Wufour": "وفور"}
    , &.{.{
        .lang = "ar",
        .json =
        \\{"Sign in": "تسجيل الدخول"}
        ,
        .machine =
        \\{"Sign in": "machine", "Search": "بحث"}
        ,
    }});
    defer deinit();

    setLanguage("ar");
    try testing.expect(isRtl());
    try testing.expectEqualStrings("وفور", t("Wufour"));
    try testing.expectEqualStrings("تسجيل الدخول", t("Sign in"));
    try testing.expectEqualStrings("بحث", t(" Search "));
    try testing.expectEqualStrings("Missing", t("Missing"));

    setLanguage("en");
    try testing.expect(!isRtl());
    try testing.expectEqualStrings("Sign in", t("Sign in"));
}

test "tf fills named fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    setLanguage("en");
    try testing.expectEqualStrings("3 new messages from Sara", tf(arena.allocator(), "{n} new messages from {who}", .{ .n = 3, .who = "Sara" }));
}

test "a context tells apart the same English text" {
    try init(testing.allocator, "{}", &.{.{
        .lang = "ar",
        .json =
        \\{"Open": "فتح", "Open|state": "مفتوح", "a | b": "أ | ب"}
        ,
    }});
    defer deinit();
    setLanguage("en");
    try testing.expectEqualStrings("Open", t("Open|state"));
    try testing.expectEqualStrings("Open", tc("state", "Open"));
    try testing.expectEqualStrings("Open", english("Open|state"));
    setLanguage("ar");
    try testing.expectEqualStrings("مفتوح", t("Open|state"));
    try testing.expectEqualStrings("مفتوح", tc("state", "Open"));
    // No contextual key: the plain one.
    try testing.expectEqualStrings("فتح", t("Open|task"));
    try testing.expectEqualStrings("فتح", t("Open"));
    // A bar followed by a space is text, not a context.
    try testing.expectEqualStrings("أ | ب", t("a | b"));
    setLanguage("en");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("3 open", tf(arena.allocator(), "{n} open|count", .{ .n = 3 }));
}
