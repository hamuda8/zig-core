//! BSON (https://bsonspec.org): reading documents, building them, and converting Zig values to
//! and from them by reflection, so a filter can be written as a struct literal:
//!
//!     const filter = try bson.encode(arena, .{ .status = "active", .age = .{ .@"$gte" = 18 } });

const std = @import("std");

pub const ObjectId = struct {
    bytes: [12]u8,

    var counter: std.atomic.Value(u32) = .init(0);
    var process_unique: [5]u8 = undefined;
    /// 0 = not set up, 1 = being set up, 2 = ready.
    var state: std.atomic.Value(u8) = .init(0);

    fn setUp(io: std.Io) void {
        while (state.load(.acquire) != 2) {
            if (state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) {
                var seed: [9]u8 = undefined;
                io.random(&seed);
                process_unique = seed[0..5].*;
                counter.store(std.mem.readInt(u32, seed[5..9], .little), .monotonic);
                state.store(2, .release);
            } else std.atomic.spinLoopHint();
        }
    }

    /// A new id: 4-byte seconds timestamp, 5 random bytes per process, 3-byte counter.
    pub fn generate(io: std.Io) ObjectId {
        return generateAt(io, std.Io.Timestamp.now(io, .real).toSeconds());
    }

    pub fn generateAt(io: std.Io, unix_seconds: i64) ObjectId {
        setUp(io);
        var b: [12]u8 = undefined;
        std.mem.writeInt(u32, b[0..4], @truncate(@as(u64, @bitCast(unix_seconds))), .big);
        b[4..9].* = process_unique;
        const c = counter.fetchAdd(1, .monotonic);
        b[9] = @truncate(c >> 16);
        b[10] = @truncate(c >> 8);
        b[11] = @truncate(c);
        return .{ .bytes = b };
    }

    pub fn parse(hex: []const u8) !ObjectId {
        if (hex.len != 24) return error.InvalidObjectId;
        var b: [12]u8 = undefined;
        _ = std.fmt.hexToBytes(&b, hex) catch return error.InvalidObjectId;
        return .{ .bytes = b };
    }

    pub fn toHex(id: ObjectId) [24]u8 {
        return std.fmt.bytesToHex(id.bytes, .lower);
    }

    pub fn timestamp(id: ObjectId) i64 {
        return std.mem.readInt(u32, id.bytes[0..4], .big);
    }

    /// As JSON, the 24-character hex string (what the Node servers send to clients).
    pub fn jsonStringify(id: ObjectId, w: anytype) !void {
        try w.write(&id.toHex());
    }
};

/// Milliseconds since the Unix epoch (BSON UTC datetime, JavaScript `Date`).
pub const DateTime = struct {
    ms: i64,

    pub fn jsonStringify(d: DateTime, w: anytype) !void {
        try w.write(d.ms);
    }
};

pub const Binary = struct {
    subtype: u8 = 0,
    data: []const u8,
};

pub const Type = enum(u8) {
    double = 0x01,
    string = 0x02,
    document = 0x03,
    array = 0x04,
    binary = 0x05,
    undefined = 0x06,
    object_id = 0x07,
    boolean = 0x08,
    datetime = 0x09,
    null = 0x0A,
    regex = 0x0B,
    javascript = 0x0D,
    int32 = 0x10,
    timestamp = 0x11,
    int64 = 0x12,
    decimal128 = 0x13,
    min_key = 0xFF,
    max_key = 0x7F,
    _,
};

pub const Value = union(enum) {
    double: f64,
    string: []const u8,
    document: Doc,
    array: Doc,
    binary: Binary,
    object_id: ObjectId,
    boolean: bool,
    datetime: DateTime,
    null,
    regex: struct { pattern: []const u8, options: []const u8 },
    int32: i32,
    timestamp: u64,
    int64: i64,
    decimal128: [16]u8,
    other: Type,

    /// Any numeric value as f64.
    pub fn asFloat(v: Value) ?f64 {
        return switch (v) {
            .double => |d| d,
            .int32 => |i| @floatFromInt(i),
            .int64 => |i| @floatFromInt(i),
            else => null,
        };
    }

    /// Any integral value as i64 (doubles only when they are whole).
    pub fn asInt(v: Value) ?i64 {
        return switch (v) {
            .int32 => |i| i,
            .int64 => |i| i,
            .double => |d| if (@floor(d) == d and @abs(d) < 9.0e15) @intFromFloat(d) else null,
            else => null,
        };
    }
};

pub const Element = struct { key: []const u8, value: Value };

/// A BSON document in its encoded form. Reading does not copy: strings point into `bytes`.
pub const Doc = struct {
    bytes: []const u8,

    pub const empty: Doc = .{ .bytes = &.{ 5, 0, 0, 0, 0 } };

    /// Checks the length prefix and terminator.
    pub fn init(bytes: []const u8) !Doc {
        if (bytes.len < 5) return error.InvalidBson;
        const len = std.mem.readInt(i32, bytes[0..4], .little);
        if (len < 5 or len > bytes.len or bytes[@intCast(len - 1)] != 0) return error.InvalidBson;
        return .{ .bytes = bytes[0..@intCast(len)] };
    }

    pub fn iterator(d: Doc) Iterator {
        return .{ .bytes = d.bytes, .pos = 4 };
    }

    pub fn get(d: Doc, key: []const u8) ?Value {
        var it = d.iterator();
        while (it.next() catch return null) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
        return null;
    }

    /// `a.b.c` through nested documents (and arrays by index).
    pub fn getPath(d: Doc, path: []const u8) ?Value {
        var cur = d;
        var parts = std.mem.splitScalar(u8, path, '.');
        while (parts.next()) |p| {
            const v = cur.get(p) orelse return null;
            if (parts.peek() == null) return v;
            cur = switch (v) {
                .document, .array => |sub| sub,
                else => return null,
            };
        }
        return null;
    }

    pub fn getString(d: Doc, key: []const u8) ?[]const u8 {
        return switch (d.get(key) orelse return null) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn getDoc(d: Doc, key: []const u8) ?Doc {
        return switch (d.get(key) orelse return null) {
            .document, .array => |s| s,
            else => null,
        };
    }

    pub fn count(d: Doc) usize {
        var n: usize = 0;
        var it = d.iterator();
        while (it.next() catch null) |_| n += 1;
        return n;
    }
};

pub const Iterator = struct {
    bytes: []const u8,
    pos: usize,

    pub fn next(it: *Iterator) !?Element {
        if (it.pos >= it.bytes.len - 1) return null;
        const t: Type = @fromBackingInt(@intCast(it.bytes[it.pos]));
        it.pos += 1;
        const key = try it.cstring();
        const value: Value = switch (t) {
            .double => .{ .double = @bitCast(try it.fixed(u64)) },
            .string, .javascript => blk: {
                const len: usize = @intCast(try it.fixed(i32));
                if (len < 1 or it.pos + len > it.bytes.len) return error.InvalidBson;
                const s = it.bytes[it.pos .. it.pos + len - 1];
                it.pos += len;
                break :blk if (t == .string) .{ .string = s } else .{ .other = t };
            },
            .document, .array => blk: {
                const sub = try Doc.init(it.bytes[it.pos..]);
                it.pos += sub.bytes.len;
                break :blk if (t == .document) .{ .document = sub } else .{ .array = sub };
            },
            .binary => blk: {
                const len: usize = @intCast(try it.fixed(i32));
                if (it.pos + 1 + len > it.bytes.len) return error.InvalidBson;
                const sub = it.bytes[it.pos];
                const data = it.bytes[it.pos + 1 .. it.pos + 1 + len];
                it.pos += 1 + len;
                break :blk .{ .binary = .{ .subtype = sub, .data = data } };
            },
            .object_id => blk: {
                if (it.pos + 12 > it.bytes.len) return error.InvalidBson;
                const id: ObjectId = .{ .bytes = it.bytes[it.pos..][0..12].* };
                it.pos += 12;
                break :blk .{ .object_id = id };
            },
            .boolean => blk: {
                if (it.pos >= it.bytes.len) return error.InvalidBson;
                it.pos += 1;
                break :blk .{ .boolean = it.bytes[it.pos - 1] != 0 };
            },
            .datetime => .{ .datetime = .{ .ms = try it.fixed(i64) } },
            .null, .undefined, .min_key, .max_key => if (t == .null) .null else .{ .other = t },
            .regex => .{ .regex = .{ .pattern = try it.cstring(), .options = try it.cstring() } },
            .int32 => .{ .int32 = try it.fixed(i32) },
            .timestamp => .{ .timestamp = try it.fixed(u64) },
            .int64 => .{ .int64 = try it.fixed(i64) },
            .decimal128 => blk: {
                if (it.pos + 16 > it.bytes.len) return error.InvalidBson;
                it.pos += 16;
                break :blk .{ .decimal128 = it.bytes[it.pos - 16 ..][0..16].* };
            },
            _ => return error.UnsupportedBsonType,
        };
        return .{ .key = key, .value = value };
    }

    fn cstring(it: *Iterator) ![]const u8 {
        const end = std.mem.indexOfScalarPos(u8, it.bytes, it.pos, 0) orelse return error.InvalidBson;
        const s = it.bytes[it.pos..end];
        it.pos = end + 1;
        return s;
    }

    fn fixed(it: *Iterator, comptime T: type) !T {
        if (it.pos + @sizeOf(T) > it.bytes.len) return error.InvalidBson;
        const v = std.mem.readInt(T, it.bytes[it.pos..][0..@sizeOf(T)], .little);
        it.pos += @sizeOf(T);
        return v;
    }
};

/// Writes a document field by field. Nested documents and arrays are opened and closed.
pub const Builder = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// Start offsets of the open documents; arrays also keep their next index.
    open: std.ArrayList(Open) = .empty,

    const Open = struct { start: usize, array_index: ?u32 };

    pub fn init(gpa: std.mem.Allocator) !Builder {
        var b: Builder = .{ .gpa = gpa };
        try b.startDoc(null);
        return b;
    }

    pub fn deinit(b: *Builder) void {
        b.buf.deinit(b.gpa);
        b.open.deinit(b.gpa);
    }

    /// Closes the top document and returns it. The builder's memory now belongs to the caller.
    pub fn finish(b: *Builder) !Doc {
        try b.endDoc();
        if (b.open.items.len != 0) return error.UnclosedDocument;
        b.open.deinit(b.gpa);
        return .{ .bytes = try b.buf.toOwnedSlice(b.gpa) };
    }

    fn startDoc(b: *Builder, first_index: ?u32) !void {
        try b.open.append(b.gpa, .{ .start = b.buf.items.len, .array_index = first_index });
        try b.buf.appendNTimes(b.gpa, 0, 4);
    }

    fn endDoc(b: *Builder) !void {
        const o = b.open.pop() orelse return error.NothingOpen;
        try b.buf.append(b.gpa, 0);
        const len: i32 = @intCast(b.buf.items.len - o.start);
        std.mem.writeInt(i32, b.buf.items[o.start..][0..4], len, .little);
    }

    /// Writes the type byte and the key; inside an array the key is the next index.
    fn head(b: *Builder, t: Type, key: []const u8) !void {
        try b.buf.append(b.gpa, @backingInt(t));
        const top = &b.open.items[b.open.items.len - 1];
        if (top.array_index) |*i| {
            try b.buf.print(b.gpa, "{d}", .{i.*});
            i.* += 1;
        } else {
            if (std.mem.indexOfScalar(u8, key, 0) != null) return error.KeyHasNul;
            try b.buf.appendSlice(b.gpa, key);
        }
        try b.buf.append(b.gpa, 0);
    }

    fn int(b: *Builder, comptime T: type, v: T) !void {
        var tmp: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &tmp, v, .little);
        try b.buf.appendSlice(b.gpa, &tmp);
    }

    pub fn double(b: *Builder, key: []const u8, v: f64) !void {
        try b.head(.double, key);
        try b.int(u64, @bitCast(v));
    }
    pub fn string(b: *Builder, key: []const u8, v: []const u8) !void {
        try b.head(.string, key);
        try b.int(i32, @intCast(v.len + 1));
        try b.buf.appendSlice(b.gpa, v);
        try b.buf.append(b.gpa, 0);
    }
    pub fn int32(b: *Builder, key: []const u8, v: i32) !void {
        try b.head(.int32, key);
        try b.int(i32, v);
    }
    pub fn int64(b: *Builder, key: []const u8, v: i64) !void {
        try b.head(.int64, key);
        try b.int(i64, v);
    }
    pub fn boolean(b: *Builder, key: []const u8, v: bool) !void {
        try b.head(.boolean, key);
        try b.buf.append(b.gpa, @intFromBool(v));
    }
    pub fn null_(b: *Builder, key: []const u8) !void {
        try b.head(.null, key);
    }
    pub fn objectId(b: *Builder, key: []const u8, v: ObjectId) !void {
        try b.head(.object_id, key);
        try b.buf.appendSlice(b.gpa, &v.bytes);
    }
    pub fn datetime(b: *Builder, key: []const u8, v: DateTime) !void {
        try b.head(.datetime, key);
        try b.int(i64, v.ms);
    }
    pub fn binary(b: *Builder, key: []const u8, v: Binary) !void {
        try b.head(.binary, key);
        try b.int(i32, @intCast(v.data.len));
        try b.buf.append(b.gpa, v.subtype);
        try b.buf.appendSlice(b.gpa, v.data);
    }
    /// Copies an existing document (or array) in as a field.
    pub fn doc(b: *Builder, key: []const u8, v: Doc) !void {
        try b.head(.document, key);
        try b.buf.appendSlice(b.gpa, v.bytes);
    }
    pub fn array(b: *Builder, key: []const u8, v: Doc) !void {
        try b.head(.array, key);
        try b.buf.appendSlice(b.gpa, v.bytes);
    }
    pub fn value(b: *Builder, key: []const u8, v: Value) !void {
        switch (v) {
            .double => |x| try b.double(key, x),
            .string => |x| try b.string(key, x),
            .document => |x| try b.doc(key, x),
            .array => |x| try b.array(key, x),
            .binary => |x| try b.binary(key, x),
            .object_id => |x| try b.objectId(key, x),
            .boolean => |x| try b.boolean(key, x),
            .datetime => |x| try b.datetime(key, x),
            .null => try b.null_(key),
            .regex => |x| {
                try b.head(.regex, key);
                inline for (.{ x.pattern, x.options }) |s| {
                    try b.buf.appendSlice(b.gpa, s);
                    try b.buf.append(b.gpa, 0);
                }
            },
            .int32 => |x| try b.int32(key, x),
            .timestamp => |x| {
                try b.head(.timestamp, key);
                try b.int(u64, x);
            },
            .int64 => |x| try b.int64(key, x),
            .decimal128 => |x| {
                try b.head(.decimal128, key);
                try b.buf.appendSlice(b.gpa, &x);
            },
            .other => return error.UnsupportedBsonType,
        }
    }

    pub fn beginDoc(b: *Builder, key: []const u8) !void {
        try b.head(.document, key);
        try b.startDoc(null);
    }
    pub fn beginArray(b: *Builder, key: []const u8) !void {
        try b.head(.array, key);
        try b.startDoc(0);
    }
    pub fn end(b: *Builder) !void {
        try b.endDoc();
    }

    /// Any Zig value as a field: see `encode` for the mapping.
    pub fn any(b: *Builder, key: []const u8, v: anytype) !void {
        const T = @TypeOf(v);
        switch (T) {
            Doc => return b.doc(key, v),
            Value => return b.value(key, v),
            ObjectId => return b.objectId(key, v),
            DateTime => return b.datetime(key, v),
            Binary => return b.binary(key, v),
            std.json.Value => return b.json(key, v),
            else => {},
        }
        switch (@typeInfo(T)) {
            .bool => try b.boolean(key, v),
            .int, .comptime_int => {
                if (std.math.cast(i32, v)) |x| try b.int32(key, x) else try b.int64(key, @intCast(v));
            },
            .float, .comptime_float => try b.double(key, v),
            .null => try b.null_(key),
            .optional => if (v) |x| try b.any(key, x) else try b.null_(key),
            .@"enum", .enum_literal => try b.string(key, @tagName(v)),
            .pointer => |p| {
                if (p.size == .one) switch (@typeInfo(p.child)) {
                    .array => |a| if (a.child == u8) return b.string(key, v) else {
                        try b.beginArray(key);
                        for (v) |x| try b.any("", x);
                        return b.end();
                    },
                    else => return b.any(key, v.*),
                };
                if (p.child == u8) return b.string(key, v);
                try b.beginArray(key);
                for (v) |x| try b.any("", x);
                try b.end();
            },
            .array => |a| {
                if (a.child == u8) return b.string(key, &v);
                try b.beginArray(key);
                for (v) |x| try b.any("", x);
                try b.end();
            },
            .@"struct" => |s| {
                if (s.is_tuple) {
                    try b.beginArray(key);
                    inline for (v) |x| try b.any("", x);
                    return b.end();
                }
                try b.beginDoc(key);
                try b.fields(v);
                try b.end();
            },
            else => @compileError("cannot encode " ++ @typeName(T) ++ " as BSON"),
        }
    }

    /// The fields of struct `v` into the open document. Null optionals are left out.
    pub fn fields(b: *Builder, v: anytype) !void {
        inline for (comptime std.meta.fieldNames(@TypeOf(v))) |name| {
            const f = @field(v, name);
            if (@typeInfo(@TypeOf(f)) == .optional) {
                if (f) |x| try b.any(name, x);
            } else try b.any(name, f);
        }
    }

    fn json(b: *Builder, key: []const u8, v: std.json.Value) !void {
        switch (v) {
            .null => try b.null_(key),
            .bool => |x| try b.boolean(key, x),
            .integer => |x| try b.any(key, x),
            .float => |x| try b.double(key, x),
            .number_string, .string => |x| try b.string(key, x),
            .array => |a| {
                try b.beginArray(key);
                for (a.items) |x| try b.json("", x);
                try b.end();
            },
            .object => |o| {
                try b.beginDoc(key);
                var it = o.iterator();
                while (it.next()) |e| try b.json(e.key_ptr.*, e.value_ptr.*);
                try b.end();
            },
        }
    }
};

/// A Zig struct (or `std.json.Value` object) as a BSON document:
/// bool → boolean, integers → int32 (int64 when they do not fit), floats → double,
/// strings → string, slices/arrays/tuples → array, structs → document, enums → their name,
/// null optionals are left out, ObjectId/DateTime/Binary/Doc as themselves.
pub fn encode(gpa: std.mem.Allocator, v: anytype) !Doc {
    var b = try Builder.init(gpa);
    errdefer b.deinit();
    if (@TypeOf(v) == std.json.Value) {
        if (v != .object) return error.NotAnObject;
        var it = v.object.iterator();
        while (it.next()) |e| try b.json(e.key_ptr.*, e.value_ptr.*);
    } else if (@TypeOf(v) == Doc) {
        return .{ .bytes = try gpa.dupe(u8, v.bytes) };
    } else {
        try b.fields(v);
    }
    return b.finish();
}

/// A document as a Zig struct. Fields missing from the document take their default (or null for
/// optionals); unknown fields are ignored. Strings point into `doc` unless `T` is decoded with an
/// arena and the caller copies.
pub fn decode(comptime T: type, gpa: std.mem.Allocator, doc: Doc) !T {
    return decodeValue(T, gpa, .{ .document = doc });
}

fn decodeValue(comptime T: type, gpa: std.mem.Allocator, v: Value) !T {
    switch (T) {
        Value => return v,
        Doc => return switch (v) {
            .document, .array => |d| d,
            else => error.TypeMismatch,
        },
        ObjectId => return switch (v) {
            .object_id => |id| id,
            .string => |s| ObjectId.parse(s),
            else => error.TypeMismatch,
        },
        DateTime => return switch (v) {
            .datetime => |d| d,
            else => error.TypeMismatch,
        },
        Binary => return switch (v) {
            .binary => |x| x,
            else => error.TypeMismatch,
        },
        else => {},
    }
    switch (@typeInfo(T)) {
        .bool => return switch (v) {
            .boolean => |x| x,
            else => error.TypeMismatch,
        },
        .int => return std.math.cast(T, v.asInt() orelse return error.TypeMismatch) orelse error.Overflow,
        .float => return @floatCast(v.asFloat() orelse return error.TypeMismatch),
        .optional => |o| return if (v == .null) null else try decodeValue(o.child, gpa, v),
        .@"enum" => return switch (v) {
            .string => |s| std.meta.stringToEnum(T, s) orelse error.UnknownEnumValue,
            else => error.TypeMismatch,
        },
        .pointer => |p| {
            if (p.size != .slice) @compileError("cannot decode into " ++ @typeName(T));
            if (p.child == u8) return switch (v) {
                .string => |s| s,
                else => error.TypeMismatch,
            };
            const arr = switch (v) {
                .array => |d| d,
                else => return error.TypeMismatch,
            };
            const out = try gpa.alloc(p.child, arr.count());
            var it = arr.iterator();
            var i: usize = 0;
            while (try it.next()) |e| : (i += 1) out[i] = try decodeValue(p.child, gpa, e.value);
            return out;
        },
        .@"struct" => {
            const d = switch (v) {
                .document => |d| d,
                else => return error.TypeMismatch,
            };
            var out: T = undefined;
            inline for (comptime std.meta.fieldNames(T), @typeInfo(T).@"struct".field_types, @typeInfo(T).@"struct".field_attrs) |name, FT, attrs| {
                if (d.get(name)) |fv| {
                    @field(out, name) = try decodeValue(FT, gpa, fv);
                } else if (comptime attrs.defaultValue(FT)) |def| {
                    @field(out, name) = def;
                } else if (@typeInfo(FT) == .optional) {
                    @field(out, name) = null;
                } else return error.MissingField;
            }
            return out;
        },
        else => @compileError("cannot decode into " ++ @typeName(T)),
    }
}

/// The document as relaxed JSON (ObjectId as hex, dates as milliseconds), for API responses.
pub fn writeJson(w: *std.Io.Writer, doc: Doc, is_array: bool) !void {
    try w.writeByte(if (is_array) '[' else '{');
    var it = doc.iterator();
    var first = true;
    while (try it.next()) |e| {
        if (!first) try w.writeByte(',');
        first = false;
        if (!is_array) {
            try std.json.Stringify.encodeJsonString(e.key, .{}, w);
            try w.writeByte(':');
        }
        switch (e.value) {
            .double => |x| if (std.math.isFinite(x)) try w.print("{d}", .{x}) else try w.writeAll("null"),
            .string => |s| try std.json.Stringify.encodeJsonString(s, .{}, w),
            .document => |d| try writeJson(w, d, false),
            .array => |d| try writeJson(w, d, true),
            .object_id => |id| try w.print("\"{s}\"", .{&id.toHex()}),
            .boolean => |x| try w.writeAll(if (x) "true" else "false"),
            .datetime => |d| try w.print("{d}", .{d.ms}),
            .int32 => |x| try w.print("{d}", .{x}),
            .int64 => |x| try w.print("{d}", .{x}),
            .timestamp => |x| try w.print("{d}", .{x}),
            .binary => |x| {
                try w.writeByte('"');
                try std.base64.standard.Encoder.encodeWriter(w, x.data);
                try w.writeByte('"');
            },
            else => try w.writeAll("null"),
        }
    }
    try w.writeByte(if (is_array) ']' else '}');
}

const testing = std.testing;

test "builder output matches the BSON spec example" {
    // {"hello": "world"} from bsonspec.org
    var b = try Builder.init(testing.allocator);
    try b.string("hello", "world");
    const d = try b.finish();
    defer testing.allocator.free(d.bytes);
    try testing.expectEqualSlices(u8, "\x16\x00\x00\x00\x02hello\x00\x06\x00\x00\x00world\x00\x00", d.bytes);
}

test "encode a struct literal and read it back" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = ObjectId.generateAt(testing.io, 1_700_000_000);
    const d = try encode(a, .{
        ._id = id,
        .name = "Sara",
        .age = .{ .@"$gte" = 18 },
        .tags = &[_][]const u8{ "a", "b" },
        .big = @as(i64, 1) << 40,
        .score = 2.5,
        .active = true,
        .nothing = @as(?u8, null),
        .at = DateTime{ .ms = 1234 },
    });
    try testing.expectEqualStrings("Sara", d.getString("name").?);
    try testing.expectEqual(@as(i32, 18), d.getPath("age.$gte").?.int32);
    try testing.expectEqualStrings("b", d.getPath("tags.1").?.string);
    try testing.expectEqual(@as(i64, 1) << 40, d.get("big").?.int64);
    try testing.expectEqual(null, d.get("nothing"));
    try testing.expectEqual(id.bytes, d.get("_id").?.object_id.bytes);
    try testing.expectEqual(@as(i64, 1_700_000_000), id.timestamp());

    const Person = struct {
        _id: ObjectId,
        name: []const u8,
        tags: []const []const u8,
        big: i64,
        score: f32,
        active: bool,
        nothing: ?u8,
        missing: u8 = 7,
        at: DateTime,
    };
    const p = try decode(Person, a, d);
    try testing.expectEqualStrings("Sara", p.name);
    try testing.expectEqual(@as(usize, 2), p.tags.len);
    try testing.expectEqual(@as(u8, 7), p.missing);
    try testing.expectEqual(@as(i64, 1234), p.at.ms);

    var out: std.Io.Writer.Allocating = .init(a);
    try writeJson(&out.writer, try encode(a, .{ .id = id, .n = 1, .s = "x\"y" }), false);
    var expected: std.Io.Writer.Allocating = .init(a);
    try expected.writer.print("{{\"id\":\"{s}\",\"n\":1,\"s\":\"x\\\"y\"}}", .{&id.toHex()});
    try testing.expectEqualStrings(expected.written(), out.written());
}

test "object ids are unique and parse from hex" {
    const a = ObjectId.generateAt(testing.io, 1);
    const b = ObjectId.generateAt(testing.io, 1);
    try testing.expect(!std.mem.eql(u8, &a.bytes, &b.bytes));
    const hex = a.toHex();
    try testing.expectEqual(a.bytes, (try ObjectId.parse(&hex)).bytes);
    try testing.expectError(error.InvalidObjectId, ObjectId.parse("xyz"));
}

test "malformed input is rejected, not read past" {
    try testing.expectError(error.InvalidBson, Doc.init("\x05\x00\x00"));
    const d = try Doc.init("\x0d\x00\x00\x00\x02a\x00\xff\x00\x00\x00\x00\x00");
    var it = d.iterator();
    try testing.expectError(error.InvalidBson, it.next());
}
