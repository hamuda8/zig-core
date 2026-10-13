//! A JavaScript-like dynamic value, for servers ported from Node that must keep the old
//! document and response shapes exactly: objects keep key order, numbers are f64, `undef` is
//! JavaScript's `undefined` (left out of JSON objects, stored as null the way the Node MongoDB
//! driver stores it), dates are milliseconds and ObjectIds stay typed.
//!
//! Converts to and from JSON (as `JSON.stringify` / `JSON.parse` do), BSON (as the Node driver
//! writes it: whole numbers that fit in 32 bits as int32, everything else as double) and relaxed
//! Extended JSON (as BSON's `EJSON.serialize` / `deserialize`).
//!
//! Objects and arrays are pointers that carry their allocator, so like in JavaScript a change
//! through one reference is seen through every other, and `set`/`push` need no allocator.
//! Everything is meant to live in an arena (a request's, a job's).

const std = @import("std");
const bson = @import("bson.zig");

pub const ObjectId = bson.ObjectId;
pub const Allocator = std.mem.Allocator;

/// A JavaScript `Date` (milliseconds since the epoch). Wrapped so `from` can tell it from a number.
pub const Date = struct { ms: i64 };

pub const Val = union(enum) {
    undef,
    null,
    bool: bool,
    num: f64,
    str: []const u8,
    id: ObjectId,
    /// Milliseconds since the epoch.
    date: i64,
    arr: *Arr,
    obj: *Obj,
    bin: []const u8,
    regex: struct { pattern: []const u8, options: []const u8 },
    /// Other BSON values, kept as they are (decimal128, timestamps, ...).
    raw: bson.Value,

    pub const empty_str: Val = .{ .str = "" };
    pub const True: Val = .{ .bool = true };
    pub const False: Val = .{ .bool = false };

    // ---- Making ---------------------------------------------------------------------------

    pub fn string(x: []const u8) Val {
        return .{ .str = x };
    }

    pub fn number(x: anytype) Val {
        return numVal(x);
    }

    pub fn object(a: Allocator) !Val {
        return newObj(a);
    }

    pub fn array(a: Allocator) !Val {
        return newArr(a);
    }

    pub fn arrayOf(a: Allocator, list: []const Val) !Val {
        return arrOf(a, list);
    }

    // ---- Reading --------------------------------------------------------------------------

    /// `v[key]`: object fields, array indexes and `length`; undefined otherwise.
    pub fn get(v: Val, key: []const u8) Val {
        return switch (v) {
            .obj => |o| o.get(key) orelse .undef,
            .arr => |l| if (std.fmt.parseUnsigned(usize, key, 10)) |i|
                (if (i < l.items.items.len) l.items.items[i] else .undef)
            else |_|
                (if (std.mem.eql(u8, key, "length")) numVal(l.items.items.len) else .undef),
            else => .undef,
        };
    }

    /// `v?.a?.b?.c`: undefined as soon as a step is missing.
    pub fn path(v: Val, p: []const u8) Val {
        var cur = v;
        var it = std.mem.splitScalar(u8, p, '.');
        while (it.next()) |k| {
            if (cur.isNullish()) return .undef;
            cur = cur.get(k);
        }
        return cur;
    }

    pub fn at(v: Val, i: usize) Val {
        return switch (v) {
            .arr => |l| if (i < l.items.items.len) l.items.items[i] else .undef,
            else => .undef,
        };
    }

    pub fn has(v: Val, key: []const u8) bool {
        return if (v.asObj()) |o| o.has(key) else false;
    }

    /// The elements of an array (empty for anything else).
    pub fn items(v: Val) []Val {
        return if (v == .arr) v.arr.items.items else &.{};
    }

    /// The keys of an object, in order (empty for anything else).
    pub fn keys(v: Val) []const []const u8 {
        return if (v == .obj) v.obj.keys.items else &.{};
    }

    /// The values of an object, in key order (empty for anything else).
    pub fn vals(v: Val) []Val {
        return if (v == .obj) v.obj.vals.items else &.{};
    }

    /// Elements of an array, fields of an object, bytes of a string.
    pub fn len(v: Val) usize {
        return switch (v) {
            .arr => |l| l.items.items.len,
            .obj => |o| o.count(),
            .str => |x| x.len,
            else => 0,
        };
    }

    pub fn asStr(v: Val) ?[]const u8 {
        return if (v == .str) v.str else null;
    }

    pub fn asNum(v: Val) ?f64 {
        return if (v == .num) v.num else null;
    }

    /// Whole numbers only.
    pub fn asInt(v: Val) ?i64 {
        if (v != .num) return null;
        const x = v.num;
        if (!std.math.isFinite(x) or @floor(x) != x or @abs(x) > 9.007199254740991e15) return null;
        return @intFromFloat(x);
    }

    pub fn asBool(v: Val) ?bool {
        return if (v == .bool) v.bool else null;
    }

    /// An ObjectId, or a string that is one (24 hex digits).
    pub fn asId(v: Val) ?ObjectId {
        return switch (v) {
            .id => |x| x,
            .str => |x| if (x.len == 24) (ObjectId.parse(x) catch null) else null,
            else => null,
        };
    }

    /// An ObjectId only.
    pub fn objectId(v: Val) ?ObjectId {
        return if (v == .id) v.id else null;
    }

    pub fn dateMs(v: Val) ?i64 {
        return if (v == .date) v.date else null;
    }

    pub fn asObj(v: Val) ?*Obj {
        return if (v == .obj) v.obj else null;
    }

    /// Field shortcuts: `v.s("name")` is `v.name` when it is a string.
    pub fn s(v: Val, key: []const u8) ?[]const u8 {
        return v.get(key).asStr();
    }

    pub fn n(v: Val, key: []const u8) ?f64 {
        return v.get(key).asNum();
    }

    /// `Boolean(v[key])`
    pub fn t(v: Val, key: []const u8) bool {
        return v.get(key).truthy();
    }

    pub fn isUndef(v: Val) bool {
        return v == .undef;
    }

    /// `v === null || v === undefined`
    pub fn isNullish(v: Val) bool {
        return v == .undef or v == .null;
    }

    /// `v === undefined || v === null || v === ''`
    pub fn isMissing(v: Val) bool {
        return switch (v) {
            .undef, .null => true,
            .str => |x| x.len == 0,
            else => false,
        };
    }

    pub fn isObj(v: Val) bool {
        return v == .obj;
    }

    pub fn isArr(v: Val) bool {
        return v == .arr;
    }

    /// `v === true`
    pub fn isTrue(v: Val) bool {
        return v == .bool and v.bool;
    }

    /// JavaScript truthiness.
    pub fn truthy(v: Val) bool {
        return switch (v) {
            .undef, .null => false,
            .bool => |b| b,
            .num => |x| x != 0 and !std.math.isNan(x),
            .str => |x| x.len > 0,
            else => true,
        };
    }

    /// `===` for primitives, by value for ObjectIds, dates and binaries, same reference for
    /// objects and arrays.
    pub fn eql(x: Val, y: Val) bool {
        if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
        return switch (x) {
            .undef, .null => true,
            .bool => |b| b == y.bool,
            .num => |b| b == y.num,
            .str => |b| std.mem.eql(u8, b, y.str),
            .id => |b| std.mem.eql(u8, &b.bytes, &y.id.bytes),
            .date => |b| b == y.date,
            .arr => |b| b == y.arr,
            .obj => |b| b == y.obj,
            .bin => |b| std.mem.eql(u8, b, y.bin),
            .regex, .raw => false,
        };
    }

    /// Same id: ObjectIds by value, strings by text (`String(a) === String(b)` on ids).
    pub fn sameId(x: Val, y: Val) bool {
        if (x == .id and y == .id) return std.mem.eql(u8, &x.id.bytes, &y.id.bytes);
        if (x == .str and y == .str) return std.mem.eql(u8, x.str, y.str);
        if (x == .id and y == .str) return std.mem.eql(u8, &x.id.toHex(), y.str);
        if (x == .str and y == .id) return std.mem.eql(u8, x.str, &y.id.toHex());
        return false;
    }

    // ---- Writing --------------------------------------------------------------------------

    /// `v[key] = x` (v must be an object); `x` is anything `from` accepts. An existing key keeps
    /// its position, as in JavaScript.
    pub fn set(v: Val, key: []const u8, x: anytype) !void {
        const o = v.asObj() orelse return error.NotAnObject;
        try o.put(key, try from(o.a, x));
    }

    /// `v.push(x)` (v must be an array); `x` is anything `from` accepts.
    pub fn push(v: Val, x: anytype) !void {
        if (v != .arr) return error.NotAnArray;
        const l = v.arr;
        try l.items.append(l.a, try from(l.a, x));
    }

    /// `delete v[key]`
    pub fn del(v: Val, key: []const u8) void {
        if (v.asObj()) |o| o.remove(key);
    }

    /// A shallow copy (`{ ...v }` or `[...v]`).
    pub fn copy(v: Val, a: Allocator) !Val {
        return switch (v) {
            .obj => |o| .{ .obj = try o.clone(a) },
            .arr => |x| blk: {
                const out = try newArr(a);
                try out.arr.items.appendSlice(a, x.items.items);
                break :blk out;
            },
            else => v,
        };
    }

    /// A deep copy (`structuredClone`), every string included.
    pub fn deepCopy(v: Val, a: Allocator) !Val {
        return switch (v) {
            .obj => |o| blk: {
                const out = try newObj(a);
                try out.obj.keys.ensureTotalCapacity(a, o.count());
                try out.obj.vals.ensureTotalCapacity(a, o.count());
                for (o.keys.items, o.vals.items) |k, x| {
                    out.obj.keys.appendAssumeCapacity(try a.dupe(u8, k));
                    out.obj.vals.appendAssumeCapacity(try x.deepCopy(a));
                }
                break :blk out;
            },
            .arr => |x| blk: {
                const out = try newArr(a);
                try out.arr.items.ensureTotalCapacity(a, x.items.items.len);
                for (x.items.items) |e| out.arr.items.appendAssumeCapacity(try e.deepCopy(a));
                break :blk out;
            },
            .str => |x| .{ .str = try a.dupe(u8, x) },
            .bin => |x| .{ .bin = try a.dupe(u8, x) },
            .regex => |x| .{ .regex = .{ .pattern = try a.dupe(u8, x.pattern), .options = try a.dupe(u8, x.options) } },
            .raw => |x| switch (x) {
                .string => |q| .{ .raw = .{ .string = try a.dupe(u8, q) } },
                .document, .array, .binary, .regex => .null,
                else => v,
            },
            else => v,
        };
    }

    /// For `std.json.Stringify` (`JSON.stringify` output).
    pub fn jsonStringify(v: Val, w: *std.json.Stringify) !void {
        try w.beginWriteRaw();
        try writeJson(w.writer, v);
        w.endWriteRaw();
    }
};

pub const Obj = struct {
    a: Allocator,
    keys: std.ArrayList([]const u8) = .empty,
    vals: std.ArrayList(Val) = .empty,

    pub fn get(o: *const Obj, key: []const u8) ?Val {
        for (o.keys.items, 0..) |k, i| if (std.mem.eql(u8, k, key)) return o.vals.items[i];
        return null;
    }

    pub fn has(o: *const Obj, key: []const u8) bool {
        return o.get(key) != null;
    }

    /// Sets `key`, keeping its position when it exists (JavaScript property order).
    pub fn put(o: *Obj, key: []const u8, v: Val) !void {
        for (o.keys.items, 0..) |k, i| if (std.mem.eql(u8, k, key)) {
            o.vals.items[i] = v;
            return;
        };
        try o.keys.append(o.a, key);
        try o.vals.append(o.a, v);
    }

    /// Adds `key` as the first field (or moves it there).
    pub fn putFirst(o: *Obj, key: []const u8, v: Val) !void {
        o.remove(key);
        try o.keys.insert(o.a, 0, key);
        try o.vals.insert(o.a, 0, v);
    }

    pub fn remove(o: *Obj, key: []const u8) void {
        for (o.keys.items, 0..) |k, i| if (std.mem.eql(u8, k, key)) {
            _ = o.keys.orderedRemove(i);
            _ = o.vals.orderedRemove(i);
            return;
        };
    }

    pub fn count(o: *const Obj) usize {
        return o.keys.items.len;
    }

    pub fn clone(o: *const Obj, a: Allocator) !*Obj {
        const out = try a.create(Obj);
        out.* = .{ .a = a };
        try out.keys.appendSlice(a, o.keys.items);
        try out.vals.appendSlice(a, o.vals.items);
        return out;
    }
};

pub const Arr = struct {
    a: Allocator,
    items: std.ArrayList(Val) = .empty,
};

pub fn newObj(a: Allocator) !Val {
    const o = try a.create(Obj);
    o.* = .{ .a = a };
    return .{ .obj = o };
}

pub fn newArr(a: Allocator) !Val {
    const x = try a.create(Arr);
    x.* = .{ .a = a };
    return .{ .arr = x };
}

/// An array of the given values.
pub fn arrOf(a: Allocator, list: []const Val) !Val {
    const out = try newArr(a);
    try out.arr.items.appendSlice(a, list);
    return out;
}

pub fn strVal(x: []const u8) Val {
    return .{ .str = x };
}

pub fn numVal(x: anytype) Val {
    return .{ .num = switch (@typeInfo(@TypeOf(x))) {
        .int, .comptime_int => @floatFromInt(x),
        else => @floatCast(x),
    } };
}

/// A number as a Val, NaN included (JSON prints it as null, like JavaScript).
pub fn numV(x: f64) Val {
    return .{ .num = x };
}

/// A shallow copy (`{ ...v }`), with the allocator first.
pub fn clone(a: Allocator, v: Val) !Val {
    return v.copy(a);
}

/// A deep copy (`structuredClone`), with the allocator first.
pub fn deepClone(a: Allocator, v: Val) !Val {
    return v.deepCopy(a);
}

/// `{ ...base, ...extra }`
pub fn merge(a: Allocator, base: Val, extra: Val) !Val {
    const out = if (base == .obj) try base.copy(a) else try newObj(a);
    for (extra.keys(), extra.vals()) |k, x| try out.obj.put(k, x);
    return out;
}

/// `{ ...a, ...b, ... }`: a new object with the fields of each part (anything `from` accepts).
pub fn spread(a: Allocator, parts: anytype) !Val {
    const out = try newObj(a);
    inline for (parts) |p| {
        const v = try from(a, p);
        if (v.asObj()) |o| for (o.keys.items, o.vals.items) |k, x| try out.obj.put(k, x);
    }
    return out;
}

/// An empty, mutable list (where an `if` needs a `[]Val` on its other branch).
pub var none: [0]Val = .{};

// ---- From Zig values ----------------------------------------------------------------------

/// Converts a Zig value to a Val: Val as is; strings; numbers; bools; null; optionals (null
/// becomes `undefined`, so a missing optional field is left out of JSON and stored as null, like
/// a JavaScript `undefined`); ObjectId; Date and bson.DateTime; documents; enums as their names;
/// struct literals become objects (in field order); tuples, arrays and slices become arrays.
pub fn from(a: Allocator, x: anytype) error{OutOfMemory}!Val {
    const T = @TypeOf(x);
    switch (T) {
        Val => return x,
        // `Val.undef` / `Val.null` on their own (in a struct literal) are tags, not Vals.
        std.meta.Tag(Val) => return switch (x) {
            .undef => .undef,
            .null => .null,
            else => .{ .str = @tagName(x) },
        },
        ObjectId => return .{ .id = x },
        Date => return .{ .date = x.ms },
        bson.DateTime => return .{ .date = x.ms },
        bson.Doc => return fromDoc(a, x) catch .null,
        *Obj => return .{ .obj = x },
        *Arr => return .{ .arr = x },
        else => {},
    }
    switch (@typeInfo(T)) {
        .bool => return .{ .bool = x },
        .int, .comptime_int => return .{ .num = @floatFromInt(x) },
        .float, .comptime_float => return .{ .num = @floatCast(x) },
        .null => return .null,
        .optional => return if (x) |y| from(a, y) else .undef,
        // `.null` and `.undef` mean the values (`v.set("k", .null)`), other literals their names.
        .enum_literal => return if (comptime std.mem.eql(u8, @tagName(x), "null")) .null else if (comptime std.mem.eql(u8, @tagName(x), "undef")) .undef else .{ .str = @tagName(x) },
        .@"enum" => return .{ .str = @tagName(x) },
        .pointer => |p| {
            if (p.size == .one) switch (@typeInfo(p.child)) {
                .array => |info| {
                    if (info.child == u8) return .{ .str = x };
                    return listFrom(a, x);
                },
                else => return from(a, x.*),
            };
            if (p.child == u8) return .{ .str = x };
            return listFrom(a, x);
        },
        .array => |info| {
            if (info.child == u8) return .{ .str = try a.dupe(u8, &x) };
            return listFrom(a, x);
        },
        .@"struct" => |st| {
            if (st.is_tuple) {
                const out = try newArr(a);
                inline for (x) |e| try out.arr.items.append(a, try from(a, e));
                return out;
            }
            const out = try newObj(a);
            const fields = comptime std.meta.fieldNames(T);
            try out.obj.keys.ensureTotalCapacity(a, fields.len);
            try out.obj.vals.ensureTotalCapacity(a, fields.len);
            inline for (fields) |name| {
                out.obj.keys.appendAssumeCapacity(name);
                out.obj.vals.appendAssumeCapacity(try from(a, @field(x, name)));
            }
            return out;
        },
        else => @compileError("cannot convert " ++ @typeName(T) ++ " to Val"),
    }
}

fn listFrom(a: Allocator, x: anytype) !Val {
    const out = try newArr(a);
    try out.arr.items.ensureTotalCapacity(a, x.len);
    for (x) |e| out.arr.items.appendAssumeCapacity(try from(a, e));
    return out;
}

// ---- Strings, as JavaScript makes them ------------------------------------------------------

/// `String(v)`.
pub fn toStr(a: Allocator, v: Val) ![]const u8 {
    return switch (v) {
        .str => |x| x,
        .num => |x| fmtNum(a, x),
        .id => |x| a.dupe(u8, &x.toHex()),
        .bool => |b| if (b) "true" else "false",
        .null => "null",
        .undef => "undefined",
        .date => |ms| isoAlloc(a, ms),
        .arr => |x| blk: {
            var out: std.ArrayList(u8) = .empty;
            for (x.items.items, 0..) |e, i| {
                if (i > 0) try out.append(a, ',');
                if (!e.isNullish()) try out.appendSlice(a, try toStr(a, e));
            }
            break :blk out.items;
        },
        .bin => |x| x,
        .obj, .regex, .raw => "[object Object]",
    };
}

/// String(x) === String(y) for ids, strings, numbers, booleans, null and undefined.
pub fn same(x: Val, y: Val) bool {
    var b1: [40]u8 = undefined;
    var b2: [40]u8 = undefined;
    const sx = keyOf(x, &b1) orelse return false;
    const sy = keyOf(y, &b2) orelse return false;
    return std.mem.eql(u8, sx, sy);
}

/// `String(v)` without allocating, for ids, strings, numbers, booleans, null and undefined.
pub fn keyOf(v: Val, buf: *[40]u8) ?[]const u8 {
    return switch (v) {
        .id => |x| blk: {
            buf[0..24].* = x.toHex();
            break :blk buf[0..24];
        },
        .str => |x| x,
        .num => |x| fmtNumBuf(buf, x),
        .null => "null",
        .undef => "undefined",
        .bool => |b| if (b) "true" else "false",
        else => null,
    };
}

/// The id as a 24-character hex string (strings as they are); null for anything else.
pub fn hex(a: Allocator, v: Val) !?[]const u8 {
    return switch (v) {
        .id => |x| try a.dupe(u8, &x.toHex()),
        .str => |x| x,
        else => null,
    };
}

/// null and undefined stay null, anything else becomes its string.
pub fn sOrNull(a: Allocator, v: Val) !Val {
    if (v.isNullish()) return .null;
    return .{ .str = try toStr(a, v) };
}

/// A number the way JavaScript prints it (`String(x)`).
pub fn fmtNumBuf(buf: *[40]u8, x: f64) []const u8 {
    if (std.math.isNan(x)) return "NaN";
    if (std.math.isInf(x)) return if (x > 0) "Infinity" else "-Infinity";
    if (@floor(x) == x and @abs(x) < 1e21) {
        if (x == 0) return "0";
        return std.fmt.bufPrint(buf, "{d}", .{@as(i128, @intFromFloat(x))}) catch "0";
    }
    const abs = @abs(x);
    if (abs >= 1e21 or abs < 1e-6) {
        // JS: 1e+21, 1.5e-7
        var tmp: [40]u8 = undefined;
        const e = std.fmt.bufPrint(&tmp, "{e}", .{x}) catch return "0";
        const epos = std.mem.indexOfScalar(u8, e, 'e') orelse return e;
        const mant = e[0..epos];
        const exp = e[epos + 1 ..];
        const sign: []const u8 = if (exp.len > 0 and exp[0] == '-') "-" else "+";
        const digits = std.mem.trimStart(u8, std.mem.trimStart(u8, exp, "+-"), "0");
        return std.fmt.bufPrint(buf, "{s}e{s}{s}", .{ mant, sign, if (digits.len == 0) "0" else digits }) catch "0";
    }
    return std.fmt.bufPrint(buf, "{d}", .{x}) catch "0";
}

/// `String(x)` for a number.
pub fn fmtNum(a: Allocator, x: f64) ![]const u8 {
    var buf: [40]u8 = undefined;
    return a.dupe(u8, fmtNumBuf(&buf, x));
}

pub const numStr = fmtNum;

/// A number as JSON: like `String(x)`, with NaN and the infinities as `null`.
pub fn writeNumber(w: *std.Io.Writer, x: f64) !void {
    if (!std.math.isFinite(x)) return w.writeAll("null");
    var buf: [40]u8 = undefined;
    try w.writeAll(fmtNumBuf(&buf, x));
}

// ---- Dates ------------------------------------------------------------------------------------

/// `new Date(ms).toISOString()` into `buf` (at least 27 bytes).
pub fn isoTime(buf: []u8, ms: i64) []const u8 {
    const secs = @divFloor(ms, 1000);
    const milli: u64 = @intCast(ms - secs * 1000);
    const days = @divFloor(secs, 86400);
    const sod: u64 = @intCast(secs - days * 86400);
    const c = civilFromDays(days);
    if (c.y < 0 or c.y > 9999) {
        return std.fmt.bufPrint(buf, "{s}{d:0>6}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{ if (c.y < 0) "-" else "+", @abs(c.y), c.m, c.d, sod / 3600, sod / 60 % 60, sod % 60, milli }) catch "";
    }
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{ @as(u64, @intCast(c.y)), c.m, c.d, sod / 3600, sod / 60 % 60, sod % 60, milli }) catch "";
}

pub fn isoDateBuf(buf: *[32]u8, ms: i64) []const u8 {
    return isoTime(buf, ms);
}

/// `new Date(ms).toISOString()`
pub fn isoAlloc(a: Allocator, ms: i64) ![]const u8 {
    var buf: [32]u8 = undefined;
    return a.dupe(u8, isoTime(&buf, ms));
}

pub const isoDate = isoAlloc;

const Ymd = struct { y: i64, m: u32, d: u32 };

/// Howard Hinnant's days-to-civil algorithm.
fn civilFromDays(z0: i64) Ymd {
    const z = z0 + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .y = if (m <= 2) y + 1 else y, .m = m, .d = d };
}

/// `new Date(text).getTime()` for ISO dates ("2026-10-11", "2026-10-11T12:30",
/// "2026-10-11T12:30:00.000Z", "+03:00" offsets). A date-only string is UTC; a date-time
/// without a zone is local time, taken as UTC here (servers run in UTC). Null for anything else
/// (an Invalid Date).
pub fn parseDate(text: []const u8) ?i64 {
    const str = std.mem.trim(u8, text, " ");
    if (str.len < 4) return null;
    var i: usize = 0;
    const digits = struct {
        fn take(src: []const u8, pos: *usize, count_: usize) ?i64 {
            if (pos.* + count_ > src.len) return null;
            for (src[pos.* .. pos.* + count_]) |c| if (!std.ascii.isDigit(c)) return null;
            const v = std.fmt.parseInt(i64, src[pos.* .. pos.* + count_], 10) catch return null;
            pos.* += count_;
            return v;
        }
    };
    const year = digits.take(str, &i, 4) orelse return null;
    var month: i64 = 1;
    var day: i64 = 1;
    var hh: i64 = 0;
    var mm: i64 = 0;
    var ss: i64 = 0;
    var frac: i64 = 0;
    var offset_min: i64 = 0;
    if (i < str.len and str[i] == '-') {
        i += 1;
        month = digits.take(str, &i, 2) orelse return null;
        if (i < str.len and str[i] == '-') {
            i += 1;
            day = digits.take(str, &i, 2) orelse return null;
        }
    }
    if (i < str.len and (str[i] == 'T' or str[i] == ' ')) {
        i += 1;
        hh = digits.take(str, &i, 2) orelse return null;
        if (i >= str.len or str[i] != ':') return null;
        i += 1;
        mm = digits.take(str, &i, 2) orelse return null;
        if (i < str.len and str[i] == ':') {
            i += 1;
            ss = digits.take(str, &i, 2) orelse return null;
            if (i < str.len and str[i] == '.') {
                i += 1;
                const start = i;
                while (i < str.len and std.ascii.isDigit(str[i])) i += 1;
                if (i == start) return null;
                const f = str[start..@min(i, start + 3)];
                frac = std.fmt.parseInt(i64, f, 10) catch return null;
                var k = f.len;
                while (k < 3) : (k += 1) frac *= 10;
            }
        }
        if (i < str.len and str[i] == 'Z') {
            i += 1;
        } else if (i < str.len and (str[i] == '+' or str[i] == '-')) {
            const sign: i64 = if (str[i] == '-') -1 else 1;
            i += 1;
            const oh = digits.take(str, &i, 2) orelse return null;
            if (i < str.len and str[i] == ':') i += 1;
            const om = digits.take(str, &i, 2) orelse return null;
            offset_min = sign * (oh * 60 + om);
        }
    }
    if (i != str.len) return null;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hh > 24 or mm > 59 or ss > 59) return null;
    if (day > daysInMonth(year, month)) return null;
    const days = daysFromCivil(year, month, day);
    return ((days * 86400 + hh * 3600 + mm * 60 + ss) - offset_min * 60) * 1000 + frac;
}

/// `new Date(v).getTime()`: numbers are milliseconds, strings are parsed, null is the epoch;
/// null for an Invalid Date.
pub fn newDate(v: Val) ?i64 {
    return switch (v) {
        .num => |x| if (std.math.isFinite(x) and @abs(x) <= 8.64e15) @as(i64, @intFromFloat(@trunc(x))) else null,
        .str => |q| parseDate(q),
        .date => |ms| ms,
        .null => 0,
        .bool => |b| if (b) 1 else 0,
        else => null,
    };
}

pub fn daysInMonth(year: i64, month: i64) i64 {
    const leap = (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
    return switch (month) {
        2 => if (leap) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

/// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
pub fn daysFromCivil(y_: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_ - 1 else y_;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub const Civil = struct { year: i64, month: i64, day: i64, hour: i64, minute: i64, second: i64, weekday: i64 };

/// UTC calendar fields of a time (weekday 0 = Sunday, like getUTCDay).
pub fn civil(ms: i64) Civil {
    const secs = @divFloor(ms, 1000);
    const days = @divFloor(secs, 86400);
    const rem = secs - days * 86400;
    const c = civilFromDays(days);
    return .{ .year = c.y, .month = c.m, .day = c.d, .hour = @divFloor(rem, 3600), .minute = @divFloor(@mod(rem, 3600), 60), .second = @mod(rem, 60), .weekday = @mod(days + 4, 7) };
}

// ---- JSON ---------------------------------------------------------------------------------------

pub const ParseError = error{ InvalidJson, OutOfMemory };

/// `JSON.parse`: any value at the top, duplicate keys keep the last value, numbers become f64.
pub fn parseJson(a: Allocator, text: []const u8) ParseError!Val {
    var scanner = std.json.Scanner.initCompleteInput(a, text);
    defer scanner.deinit();
    const v = parseValue(a, &scanner, 0) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJson,
    };
    const end = scanner.next() catch return error.InvalidJson;
    if (end != .end_of_document) return error.InvalidJson;
    return v;
}

fn parseValue(a: Allocator, sc: *std.json.Scanner, depth: usize) !Val {
    if (depth > 512) return error.InvalidJson;
    const tok = try sc.nextAlloc(a, .alloc_always);
    return switch (tok) {
        .object_begin => blk: {
            const out = try newObj(a);
            while (true) {
                const k = try sc.nextAlloc(a, .alloc_always);
                switch (k) {
                    .object_end => break,
                    .allocated_string => |key| try out.obj.put(key, try parseValue(a, sc, depth + 1)),
                    else => return error.InvalidJson,
                }
            }
            break :blk out;
        },
        .array_begin => blk: {
            const out = try newArr(a);
            while (true) {
                if (try sc.peekNextTokenType() == .array_end) {
                    _ = try sc.next();
                    break;
                }
                try out.arr.items.append(a, try parseValue(a, sc, depth + 1));
            }
            break :blk out;
        },
        .allocated_string => |x| .{ .str = x },
        .allocated_number => |x| .{ .num = std.fmt.parseFloat(f64, x) catch return error.InvalidJson },
        .true => .{ .bool = true },
        .false => .{ .bool = false },
        .null => .null,
        else => error.InvalidJson,
    };
}

/// `JSON.stringify(v)`
pub fn toJson(a: Allocator, v: Val) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try writeJson(&out.writer, v);
    return out.written();
}

pub const stringify = toJson;

/// `JSON.stringify(v)` into a writer.
pub fn writeJson(w: *std.Io.Writer, v: Val) std.Io.Writer.Error!void {
    switch (v) {
        .undef, .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .num => |x| try writeNumber(w, x),
        .str => |x| try writeString(w, x),
        .id => |x| try w.print("\"{s}\"", .{&x.toHex()}),
        .date => |ms| {
            var buf: [32]u8 = undefined;
            try w.print("\"{s}\"", .{isoTime(&buf, ms)});
        },
        .arr => |l| {
            try w.writeByte('[');
            for (l.items.items, 0..) |e, i| {
                if (i > 0) try w.writeByte(',');
                try writeJson(w, e);
            }
            try w.writeByte(']');
        },
        .obj => |o| {
            try w.writeByte('{');
            var first = true;
            for (o.keys.items, o.vals.items) |k, e| {
                if (e == .undef) continue;
                if (!first) try w.writeByte(',');
                first = false;
                try writeString(w, k);
                try w.writeByte(':');
                try writeJson(w, e);
            }
            try w.writeByte('}');
        },
        // A BSON Binary serializes as its base64 text (bson's Binary.toJSON).
        .bin => |x| {
            try w.writeByte('"');
            try std.base64.standard.Encoder.encodeWriter(w, x);
            try w.writeByte('"');
        },
        .regex => try w.writeAll("{}"),
        .raw => |x| switch (x) {
            .timestamp => |q| try w.print("{d}", .{q}),
            else => try w.writeAll("null"),
        },
    }
}

/// A JSON string as JSON.stringify writes it (non-ASCII left as is).
pub fn writeString(w: *std.Io.Writer, x: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    var start: usize = 0;
    for (x, 0..) |c, i| {
        const esc: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x08 => "\\b",
            0x0c => "\\f",
            else => null,
        };
        if (esc == null and c >= 0x20) continue;
        try w.writeAll(x[start..i]);
        if (esc) |e| try w.writeAll(e) else try w.print("\\u{x:0>4}", .{c});
        start = i + 1;
    }
    try w.writeAll(x[start..]);
    try w.writeByte('"');
}

/// JSON that keeps types ({"$date": ms}, {"$oid": hex}, {"$bin": base64}, {"$undef": 1}), for
/// keeping a value outside an arena (caches) and reading it back with `parseJsonDates`.
pub fn toJsonTyped(a: Allocator, v: Val) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try writeTyped(&out.writer, v);
    return out.written();
}

fn writeTyped(w: *std.Io.Writer, v: Val) std.Io.Writer.Error!void {
    switch (v) {
        .undef => try w.writeAll("{\"$undef\":1}"),
        .id => |x| try w.print("{{\"$oid\":\"{s}\"}}", .{&x.toHex()}),
        .date => |ms| try w.print("{{\"$date\":{d}}}", .{ms}),
        .bin => |x| {
            try w.writeAll("{\"$bin\":\"");
            try std.base64.standard.Encoder.encodeWriter(w, x);
            try w.writeAll("\"}");
        },
        .arr => |x| {
            try w.writeByte('[');
            for (x.items.items, 0..) |e, i| {
                if (i > 0) try w.writeByte(',');
                try writeTyped(w, e);
            }
            try w.writeByte(']');
        },
        .obj => |o| {
            try w.writeByte('{');
            for (o.keys.items, o.vals.items, 0..) |k, e, i| {
                if (i > 0) try w.writeByte(',');
                try writeString(w, k);
                try w.writeByte(':');
                try writeTyped(w, e);
            }
            try w.writeByte('}');
        },
        else => try writeJson(w, v),
    }
}

/// Reads `toJsonTyped` output back.
pub fn parseJsonDates(a: Allocator, text: []const u8) !Val {
    return revive(a, try parseJson(a, text));
}

fn revive(a: Allocator, v: Val) !Val {
    switch (v) {
        .obj => |o| {
            if (o.count() == 1) {
                const k = o.keys.items[0];
                const x = o.vals.items[0];
                if (std.mem.eql(u8, k, "$date")) if (x.asNum()) |ms| return .{ .date = @intFromFloat(ms) };
                if (std.mem.eql(u8, k, "$oid")) if (x.asStr()) |h| return .{ .id = ObjectId.parse(h) catch return v };
                if (std.mem.eql(u8, k, "$undef")) return .undef;
                if (std.mem.eql(u8, k, "$bin")) if (x.asStr()) |b| {
                    const out = try a.alloc(u8, std.base64.standard.Decoder.calcSizeForSlice(b) catch return v);
                    std.base64.standard.Decoder.decode(out, b) catch return v;
                    return .{ .bin = out };
                };
            }
            for (o.vals.items) |*e| e.* = try revive(a, e.*);
            return v;
        },
        .arr => |x| {
            for (x.items.items) |*e| e.* = try revive(a, e.*);
            return v;
        },
        else => return v,
    }
}

// ---- BSON -------------------------------------------------------------------------------------

pub const BsonError = error{ OutOfMemory, InvalidBson, UnsupportedBsonType };

/// A BSON document or value as a Val, the way the Node driver reads it (int32, int64 and
/// doubles become numbers; dates, ids, binaries as themselves). Strings are copied into `a`,
/// so the Val outlives the reply it came from.
pub fn fromBson(a: Allocator, x: anytype) BsonError!Val {
    return switch (@TypeOf(x)) {
        bson.Doc => fromDoc(a, x),
        bson.Value => fromBsonValue(a, x),
        else => @compileError("fromBson takes a bson.Doc or a bson.Value"),
    };
}

pub fn fromDoc(a: Allocator, d: bson.Doc) BsonError!Val {
    const out = try newObj(a);
    var it = d.iterator();
    while (try it.next()) |e| try out.obj.put(try a.dupe(u8, e.key), try fromBsonValue(a, e.value));
    return out;
}

pub fn fromBsonValue(a: Allocator, v: bson.Value) BsonError!Val {
    return switch (v) {
        .double => |x| .{ .num = x },
        .int32 => |x| .{ .num = @floatFromInt(x) },
        .int64 => |x| .{ .num = @floatFromInt(x) },
        .string => |x| .{ .str = try a.dupe(u8, x) },
        .boolean => |x| .{ .bool = x },
        .null => .null,
        .object_id => |x| .{ .id = x },
        .datetime => |x| .{ .date = x.ms },
        .document => |x| try fromDoc(a, x),
        .array => |x| blk: {
            const out = try newArr(a);
            var it = x.iterator();
            while (try it.next()) |e| try out.arr.items.append(a, try fromBsonValue(a, e.value));
            break :blk out;
        },
        .binary => |x| .{ .bin = try a.dupe(u8, x.data) },
        .regex => |x| .{ .regex = .{ .pattern = try a.dupe(u8, x.pattern), .options = try a.dupe(u8, x.options) } },
        .other => |q| if (q == .undefined) .undef else .{ .raw = v },
        else => .{ .raw = v },
    };
}

/// An object (or anything `from` makes one of) as a BSON document, the way the Node driver
/// serializes it (`undefined` as null). An array becomes a document keyed "0", "1", ...
pub fn toBson(a: Allocator, x: anytype) !bson.Doc {
    const v = try from(a, x);
    var b = try bson.Builder.init(a);
    switch (v) {
        .obj => |o| for (o.keys.items, o.vals.items) |k, e| try writeBson(&b, k, e),
        .arr => |l| for (l.items.items, 0..) |e, i| {
            var buf: [20]u8 = undefined;
            try writeBson(&b, std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable, e);
        },
        else => {},
    }
    return b.finish();
}

pub fn toDoc(a: Allocator, v: Val) !bson.Doc {
    return toBson(a, v);
}

pub fn writeBson(b: *bson.Builder, key: []const u8, v: Val) !void {
    switch (v) {
        .undef, .null => try b.null_(key),
        .bool => |x| try b.boolean(key, x),
        .num => |x| {
            // js-bson: whole numbers within int32 range are int32, -0 and the rest are doubles.
            if (x == @trunc(x) and x >= -2147483648.0 and x <= 2147483647.0 and !(x == 0 and std.math.signbit(x)))
                try b.int32(key, @intFromFloat(x))
            else
                try b.double(key, x);
        },
        .str => |x| try b.string(key, x),
        .id => |x| try b.objectId(key, x),
        .date => |x| try b.datetime(key, .{ .ms = x }),
        .bin => |x| try b.binary(key, .{ .data = x }),
        .arr => |l| {
            try b.beginArray(key);
            for (l.items.items) |e| try writeBson(b, "", e);
            try b.end();
        },
        .obj => |o| {
            try b.beginDoc(key);
            for (o.keys.items, o.vals.items) |k, e| try writeBson(b, k, e);
            try b.end();
        },
        .regex => |x| try b.value(key, .{ .regex = .{ .pattern = x.pattern, .options = x.options } }),
        .raw => |x| try b.value(key, x),
    }
}

pub const putBson = writeBson;

// ---- Extended JSON (relaxed), as BSON's EJSON.serialize / deserialize ----------------------

/// EJSON.serialize(doc, { relaxed: true })
pub fn toEjson(a: Allocator, v: Val) !Val {
    return switch (v) {
        .id => |x| try from(a, .{ .@"$oid" = try a.dupe(u8, &x.toHex()) }),
        .date => |ms| if (ms >= 0 and ms <= 253402300799999)
            try from(a, .{ .@"$date" = try isoAlloc(a, ms) })
        else
            try from(a, .{ .@"$date" = .{ .@"$numberLong" = try std.fmt.allocPrint(a, "{d}", .{ms}) } }),
        .num => |x| if (std.math.isFinite(x)) v else try from(a, .{ .@"$numberDouble" = if (std.math.isNan(x)) "NaN" else if (x > 0) "Infinity" else "-Infinity" }),
        .bin => |x| blk: {
            const enc = try a.alloc(u8, std.base64.standard.Encoder.calcSize(x.len));
            _ = std.base64.standard.Encoder.encode(enc, x);
            break :blk try from(a, .{ .@"$binary" = .{ .base64 = enc, .subType = "00" } });
        },
        .regex => |x| try from(a, .{ .@"$regularExpression" = .{ .pattern = x.pattern, .options = x.options } }),
        .arr => |l| blk: {
            const out = try newArr(a);
            for (l.items.items) |e| try out.arr.items.append(a, if (e == .undef) .null else try toEjson(a, e));
            break :blk out;
        },
        // EJSON's serializeValue turns undefined into null (in objects too).
        .obj => |o| blk: {
            const out = try newObj(a);
            for (o.keys.items, o.vals.items) |k, e| try out.obj.put(k, if (e == .undef) .null else try toEjson(a, e));
            break :blk out;
        },
        .raw => .null,
        else => v,
    };
}

/// EJSON.deserialize(value, { relaxed: true })
pub fn fromEjson(a: Allocator, v: Val) !Val {
    switch (v) {
        .arr => |l| {
            const out = try newArr(a);
            for (l.items.items) |e| try out.arr.items.append(a, try fromEjson(a, e));
            return out;
        },
        .obj => |o| {
            if (o.count() >= 1 and o.keys.items[0].len > 0 and o.keys.items[0][0] == '$') {
                if (ejsonScalar(a, v)) |x| return x;
            }
            const out = try newObj(a);
            for (o.keys.items, o.vals.items) |k, e| try out.obj.put(k, try fromEjson(a, e));
            return out;
        },
        else => return v,
    }
}

fn ejsonScalar(a: Allocator, v: Val) ?Val {
    if (v.get("$oid").asStr()) |h| if (v.len() == 1) return if (ObjectId.parse(h)) |x| Val{ .id = x } else |_| null;
    const d = v.get("$date");
    if (d != .undef and v.len() == 1) {
        return switch (d) {
            .str => |q| if (parseDate(q)) |ms| Val{ .date = ms } else null,
            .num => |x| if (std.math.isFinite(x) and @abs(x) < 8.64e15) Val{ .date = @intFromFloat(x) } else null,
            .obj => if (d.get("$numberLong").asStr()) |q| (if (std.fmt.parseInt(i64, q, 10)) |ms| Val{ .date = ms } else |_| null) else null,
            else => null,
        };
    }
    inline for (.{ "$numberInt", "$numberLong", "$numberDouble" }) |k| {
        if (v.get(k).asStr()) |q| if (v.len() == 1) {
            if (std.mem.eql(u8, q, "NaN")) return Val{ .num = std.math.nan(f64) };
            if (std.mem.eql(u8, q, "Infinity")) return Val{ .num = std.math.inf(f64) };
            if (std.mem.eql(u8, q, "-Infinity")) return Val{ .num = -std.math.inf(f64) };
            return Val{ .num = std.fmt.parseFloat(f64, q) catch return null };
        };
    }
    const b = v.get("$binary");
    if (b == .obj and v.len() == 1) {
        const text = b.get("base64").asStr() orelse return null;
        const out = a.alloc(u8, std.base64.standard.Decoder.calcSizeForSlice(text) catch return null) catch return null;
        std.base64.standard.Decoder.decode(out, text) catch return null;
        return Val{ .bin = out };
    }
    const re = v.get("$regularExpression");
    if (re == .obj and v.len() == 1) return Val{ .regex = .{ .pattern = re.get("pattern").asStr() orelse "", .options = re.get("options").asStr() orelse "" } };
    return null;
}

// ---- JavaScript helpers ---------------------------------------------------------------------

/// `s.length` in JavaScript: UTF-16 code units.
pub fn jsLength(str: []const u8) usize {
    var count_: usize = 0;
    var i: usize = 0;
    while (i < str.len) {
        const l = std.unicode.utf8ByteSequenceLength(str[i]) catch 1;
        count_ += if (l == 4) 2 else 1;
        i += l;
    }
    return count_;
}

/// `s.slice(0, n)` in UTF-16 code units (never splits a character).
pub fn jsSlice(str: []const u8, max_units: usize) []const u8 {
    var units: usize = 0;
    var i: usize = 0;
    while (i < str.len) {
        const l = std.unicode.utf8ByteSequenceLength(str[i]) catch 1;
        const u: usize = if (l == 4) 2 else 1;
        if (units + u > max_units) break;
        units += u;
        i += @min(l, str.len - i);
    }
    return str[0..i];
}

/// Whitespace that `String.prototype.trim` removes (ASCII and the Unicode spaces).
pub fn jsTrim(str: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = str.len;
    while (start < end) {
        const l = spaceLen(str[start..]);
        if (l == 0) break;
        start += l;
    }
    while (end > start) {
        var k: usize = 1;
        var found = false;
        while (k <= 3 and k <= end - start) : (k += 1) {
            if (spaceLen(str[end - k .. end]) == k) {
                end -= k;
                found = true;
                break;
            }
        }
        if (!found) break;
    }
    return str[start..end];
}

fn spaceLen(str: []const u8) usize {
    if (str.len == 0) return 0;
    switch (str[0]) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c => return 1,
        else => {},
    }
    const seqs = [_][]const u8{ "\u{00A0}", "\u{FEFF}", "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}", "\u{1680}", "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}", "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}" };
    for (seqs) |q| if (std.mem.startsWith(u8, str, q)) return q.len;
    return 0;
}

/// `s.toLowerCase()` for ASCII letters (other characters are kept).
pub fn lower(a: Allocator, str: []const u8) ![]const u8 {
    const out = try a.dupe(u8, str);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

pub fn upper(a: Allocator, str: []const u8) ![]const u8 {
    const out = try a.dupe(u8, str);
    for (out) |*c| c.* = std.ascii.toUpper(c.*);
    return out;
}

/// `Number(v)` (NaN when not a number).
pub fn toNum(v: Val) f64 {
    return switch (v) {
        .num => |x| x,
        .bool => |b| if (b) 1 else 0,
        .null => 0,
        .str => |x| strToNum(x),
        .date => |ms| @floatFromInt(ms),
        else => std.math.nan(f64),
    };
}

/// `Number("...")`: empty or blank is 0, anything else must be a number literal.
pub fn strToNum(text: []const u8) f64 {
    const str = jsTrim(text);
    if (str.len == 0) return 0;
    if (std.mem.eql(u8, str, "Infinity") or std.mem.eql(u8, str, "+Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, str, "-Infinity")) return -std.math.inf(f64);
    if (str.len > 2 and str[0] == '0' and (str[1] == 'x' or str[1] == 'X')) {
        return @floatFromInt(std.fmt.parseInt(u64, str[2..], 16) catch return std.math.nan(f64));
    }
    for (str) |c| if (!(std.ascii.isDigit(c) or c == '.' or c == 'e' or c == 'E' or c == '+' or c == '-')) return std.math.nan(f64);
    return std.fmt.parseFloat(f64, str) catch std.math.nan(f64);
}

/// `Math.max(a, b)`: NaN when either is NaN.
pub fn jsMax(x: f64, y: f64) f64 {
    if (std.math.isNan(x) or std.math.isNan(y)) return std.math.nan(f64);
    return @max(x, y);
}

pub fn jsMin(x: f64, y: f64) f64 {
    if (std.math.isNan(x) or std.math.isNan(y)) return std.math.nan(f64);
    return @min(x, y);
}

/// `(v || 0)` for a number field.
pub fn or0(v: Val) f64 {
    return if (v.truthy()) toNum(v) else 0;
}

/// `(v ?? d)` for a number field.
pub fn numOr(v: Val, d: f64) f64 {
    return if (v.isNullish()) d else toNum(v);
}

/// `Math.round`: halves go up (towards +Infinity).
pub fn jsRound(x: f64) f64 {
    return @floor(x + 0.5);
}

/// `Math.round(x * 10^d) / 10^d`
pub fn round(x: f64, comptime d: u32) f64 {
    const f = std.math.pow(f64, 10, d);
    return jsRound(x * f) / f;
}

/// `parseInt(s, 10)`: leading whitespace, optional sign, then digits; NaN without digits.
pub fn parseIntJs(s_: []const u8) f64 {
    const str = jsTrim(s_);
    var i: usize = 0;
    var neg = false;
    if (i < str.len and (str[i] == '+' or str[i] == '-')) {
        neg = str[i] == '-';
        i += 1;
    }
    const start = i;
    var v: f64 = 0;
    while (i < str.len and std.ascii.isDigit(str[i])) : (i += 1) v = v * 10 + @as(f64, @floatFromInt(str[i] - '0'));
    if (i == start) return std.math.nan(f64);
    return if (neg) -v else v;
}

/// `parseFloat(s)`
pub fn parseFloatJs(s_: []const u8) f64 {
    const str = jsTrim(s_);
    var i: usize = 0;
    if (i < str.len and (str[i] == '+' or str[i] == '-')) i += 1;
    while (i < str.len and std.ascii.isDigit(str[i])) i += 1;
    if (i < str.len and str[i] == '.') {
        i += 1;
        while (i < str.len and std.ascii.isDigit(str[i])) i += 1;
    }
    if (i < str.len and (str[i] == 'e' or str[i] == 'E')) {
        var j = i + 1;
        if (j < str.len and (str[j] == '+' or str[j] == '-')) j += 1;
        const ds = j;
        while (j < str.len and std.ascii.isDigit(str[j])) j += 1;
        if (j > ds) i = j;
    }
    return std.fmt.parseFloat(f64, str[0..i]) catch std.math.nan(f64);
}

/// Whether `list` (an array of strings) contains `str`.
pub fn includesStr(list: Val, str: []const u8) bool {
    for (list.items()) |e| if (e == .str and std.mem.eql(u8, e.str, str)) return true;
    return false;
}

/// Whether `list` contains an id equal to `x` (ObjectIds by value, strings by text).
pub fn includesId(list: Val, x: Val) bool {
    for (list.items()) |e| if (e.sameId(x)) return true;
    return false;
}

pub fn contains(comptime T: type, list: []const T, x: T) bool {
    for (list) |e| {
        if (T == []const u8) {
            if (std.mem.eql(u8, e, x)) return true;
        } else if (e == x) return true;
    }
    return false;
}

pub fn eqlStr(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

const testing = std.testing;

test "JSON round trip keeps key order, numbers and leaves undefined out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try parseJson(a, "{\"b\":1,\"a\":[1.5,\"x\\n\",null,true],\"c\":{\"d\":1e21}}");
    try v.set("e", @as(?u8, null));
    try v.set("u", Val.undef);
    try v.set("n", .null);
    try testing.expect(v.get("n") == .null);
    v.del("n");
    try v.set("b", 2);
    try v.set("f", Date{ .ms = 0 });
    try testing.expectEqualStrings("{\"b\":2,\"a\":[1.5,\"x\\n\",null,true],\"c\":{\"d\":1e+21},\"f\":\"1970-01-01T00:00:00.000Z\"}", try toJson(a, v));
    try testing.expectEqual(@as(f64, 1e21), v.path("c.d").asNum().?);
    try testing.expect(v.path("x.y.z") == .undef);
    try testing.expectEqual(@as(f64, 4), v.get("a").get("length").num);
    try testing.expectError(error.InvalidJson, parseJson(a, "{\"a\":1} x"));
}

test "numbers print like JavaScript" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("5", try numStr(a, 5.0));
    try testing.expectEqualStrings("0.1", try numStr(a, 0.1));
    try testing.expectEqualStrings("-3", try numStr(a, -3.0));
    try testing.expectEqualStrings("1.5e-7", try numStr(a, 1.5e-7));
    var x: f64 = 0.1;
    x += 0.2;
    try testing.expectEqualStrings("0.30000000000000004", try numStr(a, x));
}

test "BSON round trip, Node driver number rules" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = ObjectId.generateAt(testing.io, 1);
    const d = try toBson(a, .{ ._id = id, .n = 3, .f = 2.5, .big = 1e12, .z = -0.0, .s = "x", .u = @as(?u8, null), .at = Date{ .ms = 5 }, .l = .{ 1, "a" } });
    try testing.expectEqual(@as(i32, 3), d.get("n").?.int32);
    try testing.expectEqual(@as(f64, 1e12), d.get("big").?.double);
    try testing.expect(d.get("z").? == .double);
    try testing.expect(d.get("u").? == .null);
    const v = try fromBson(a, d);
    try testing.expect(v.get("_id").sameId(.{ .id = id }));
    try testing.expectEqual(@as(i64, 5), v.get("at").date);
    try testing.expectEqualStrings("a", v.get("l").at(1).str);
}

test "extended JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = ObjectId.generateAt(testing.io, 1_700_000_000);
    const v = try from(a, .{ ._id = id, .at = Val{ .date = 1234 }, .u = Val.undef });
    const e = try toEjson(a, v);
    try testing.expectEqualStrings("1970-01-01T00:00:01.234Z", e.path("at.$date").asStr().?);
    try testing.expect(e.get("u") == .null);
    const r = try fromEjson(a, try parseJson(a, try toJson(a, e)));
    try testing.expectEqual(@as(i64, 1234), r.get("at").date);
    try testing.expect(same(r.get("_id"), .{ .id = id }));
    const typed = try parseJsonDates(a, try toJsonTyped(a, v));
    try testing.expect(typed.get("u") == .undef);
    try testing.expectEqual(@as(i64, 1234), typed.get("at").date);
}

test "dates" {
    try testing.expectEqual(@as(?i64, 0), parseDate("1970-01-01"));
    try testing.expectEqual(@as(?i64, 1_791_720_000_000), parseDate("2026-10-11T12:00:00.000Z"));
    try testing.expectEqual(@as(?i64, 1_791_720_000_000), parseDate("2026-10-11T15:00:00+03:00"));
    try testing.expectEqual(@as(?i64, null), parseDate("nope"));
    try testing.expectEqual(@as(?i64, null), parseDate("2026-02-30"));
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1969-12-31T23:59:59.999Z", isoTime(&buf, -1));
    const c = civil(1_791_720_000_000);
    try testing.expectEqual(@as(i64, 2026), c.year);
    try testing.expectEqual(@as(i64, 10), c.month);
    try testing.expectEqual(@as(i64, 11), c.day);
    try testing.expectEqual(@as(i64, 12), c.hour);
    try testing.expectEqual(@as(i64, 0), c.weekday);
}

test "string helpers" {
    try testing.expectEqual(@as(usize, 3), jsLength("دمش"));
    try testing.expectEqualStrings("ab", jsTrim("\u{00A0} ab \n"));
    try testing.expectEqualStrings("دم", jsSlice("دمشق", 2));
    try testing.expectEqual(@as(f64, 12), parseIntJs(" 12px"));
    try testing.expect(std.math.isNan(strToNum("12px")));
    try testing.expectEqual(@as(f64, 0), strToNum(""));
}
