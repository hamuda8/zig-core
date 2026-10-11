//! OpenStreetMap .osm.pbf reader: the file's blocks, protobuf decoding, and the nodes, ways and
//! relations in each block. Streams block by block, so a file of any size (a country or the whole
//! planet) is read without holding it in memory.
//!
//! Format: https://wiki.openstreetmap.org/wiki/PBF_Format

const std = @import("std");

// ---- Protobuf ------------------------------------------------------------------------------

pub const Wire = enum(u3) { varint = 0, i64 = 1, len = 2, i32 = 5, _ };

pub const Field = struct {
    num: u32,
    wire: Wire,
    /// varint, i64 and i32 values.
    int: u64 = 0,
    /// length-delimited values.
    bytes: []const u8 = &.{},
};

/// Reads the fields of one protobuf message.
pub const Message = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Message {
        return .{ .buf = buf };
    }

    pub fn next(m: *Message) !?Field {
        if (m.pos >= m.buf.len) return null;
        const key = try varint(m.buf, &m.pos);
        var f: Field = .{ .num = @intCast(key >> 3), .wire = @enumFromInt(@as(u3, @truncate(key))) };
        switch (f.wire) {
            .varint => f.int = try varint(m.buf, &m.pos),
            .i64 => {
                if (m.pos + 8 > m.buf.len) return error.Truncated;
                f.int = std.mem.readInt(u64, m.buf[m.pos..][0..8], .little);
                m.pos += 8;
            },
            .i32 => {
                if (m.pos + 4 > m.buf.len) return error.Truncated;
                f.int = std.mem.readInt(u32, m.buf[m.pos..][0..4], .little);
                m.pos += 4;
            },
            .len => {
                const n = try varint(m.buf, &m.pos);
                if (n > m.buf.len - m.pos) return error.Truncated;
                f.bytes = m.buf[m.pos..][0..@intCast(n)];
                m.pos += @intCast(n);
            },
            else => return error.BadWireType,
        }
        return f;
    }
};

pub fn varint(buf: []const u8, pos: *usize) !u64 {
    var v: u64 = 0;
    var shift: u7 = 0;
    while (true) {
        if (pos.* >= buf.len) return error.Truncated;
        const b = buf[pos.*];
        pos.* += 1;
        if (shift < 64) v |= @as(u64, b & 0x7f) << @intCast(shift);
        if (b & 0x80 == 0) return v;
        shift += 7;
        if (shift > 70) return error.BadVarint;
    }
}

pub fn zigzag(v: u64) i64 {
    return @bitCast((v >> 1) ^ (0 -% (v & 1)));
}

/// The values of a packed repeated varint field.
pub const Packed = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn next(p: *Packed) ?u64 {
        if (p.pos >= p.buf.len) return null;
        return varint(p.buf, &p.pos) catch null;
    }

    /// For delta-coded sint64 fields: each value is added to the one before.
    pub fn nextDelta(p: *Packed, acc: *i64) ?i64 {
        const v = p.next() orelse return null;
        acc.* +%= zigzag(v);
        return acc.*;
    }
};

// ---- File blocks ---------------------------------------------------------------------------

pub const BlockKind = enum { header, data, other };

/// The blocks of a .pbf file held in memory (usually a memory map): kind and compressed body.
pub const Blocks = struct {
    data: []const u8,
    pos: usize = 0,

    pub const Block = struct { kind: BlockKind, blob: []const u8 };

    pub fn next(b: *Blocks) !?Block {
        if (b.pos >= b.data.len) return null;
        if (b.data.len - b.pos < 4) return error.Truncated;
        const header_len = std.mem.readInt(u32, b.data[b.pos..][0..4], .big);
        b.pos += 4;
        if (header_len > b.data.len - b.pos or header_len > 64 * 1024) return error.Truncated;
        var header = Message.init(b.data[b.pos..][0..header_len]);
        b.pos += header_len;
        var kind: BlockKind = .other;
        var size: u64 = 0;
        while (try header.next()) |f| switch (f.num) {
            1 => kind = if (std.mem.eql(u8, f.bytes, "OSMData")) .data else if (std.mem.eql(u8, f.bytes, "OSMHeader")) .header else .other,
            3 => size = f.int,
            else => {},
        };
        if (size > b.data.len - b.pos or size > 64 * 1024 * 1024) return error.Truncated;
        const blob = b.data[b.pos..][0..@intCast(size)];
        b.pos += @intCast(size);
        return .{ .kind = kind, .blob = blob };
    }
};

/// The uncompressed contents of a Blob message, in `out` (grown as needed).
pub fn inflate(gpa: std.mem.Allocator, blob: []const u8, out: *std.ArrayList(u8)) ![]const u8 {
    var m = Message.init(blob);
    var raw_size: usize = 0;
    var raw: ?[]const u8 = null;
    var zlib: ?[]const u8 = null;
    var zstd: ?[]const u8 = null;
    while (try m.next()) |f| switch (f.num) {
        1 => raw = f.bytes,
        2 => raw_size = @intCast(f.int),
        3 => zlib = f.bytes,
        7 => zstd = f.bytes,
        else => {},
    };
    if (raw) |r| return r;
    if (raw_size > 64 * 1024 * 1024) return error.BlockTooLarge;
    out.clearRetainingCapacity();
    try out.ensureTotalCapacity(gpa, raw_size);
    out.items.len = raw_size;
    var in: std.Io.Reader = .fixed(zlib orelse zstd orelse return error.UnsupportedCompression);
    var w: std.Io.Writer = .fixed(out.items);
    if (zlib != null) {
        var d: std.compress.flate.Decompress = .init(&in, .zlib, &.{});
        _ = d.reader.streamRemaining(&w) catch return error.BadBlock;
    } else {
        var d: std.compress.zstd.Decompress = .init(&in, &.{}, .{});
        _ = d.reader.streamRemaining(&w) catch return error.BadBlock;
    }
    if (w.end != raw_size) return error.BadBlock;
    return out.items;
}

// ---- Primitive blocks ----------------------------------------------------------------------

pub const Tags = struct {
    strings: []const []const u8,
    keys: []const u32,
    vals: []const u32,

    pub fn get(t: Tags, wanted: []const u8) ?[]const u8 {
        for (t.keys, t.vals) |k, v| {
            if (k < t.strings.len and std.mem.eql(u8, t.strings[k], wanted)) return if (v < t.strings.len) t.strings[v] else null;
        }
        return null;
    }

    pub fn len(t: Tags) usize {
        return t.keys.len;
    }

    pub fn key(t: Tags, i: usize) []const u8 {
        return if (t.keys[i] < t.strings.len) t.strings[t.keys[i]] else "";
    }

    pub fn value(t: Tags, i: usize) []const u8 {
        return if (t.vals[i] < t.strings.len) t.strings[t.vals[i]] else "";
    }
};

pub const Node = struct { id: i64, lat: f64, lon: f64, tags: Tags };
pub const Way = struct { id: i64, tags: Tags, refs: []const i64 };
pub const MemberType = enum(u2) { node = 0, way = 1, relation = 2, _ };
pub const Member = struct { id: i64, type: MemberType, role: []const u8 };
pub const Relation = struct { id: i64, tags: Tags, members: []const Member };

/// What the caller wants from each block. Unset callbacks skip that kind of element cheaply.
pub fn Visitor(comptime Ctx: type) type {
    return struct {
        node: ?*const fn (Ctx, Node) anyerror!void = null,
        way: ?*const fn (Ctx, Way) anyerror!void = null,
        relation: ?*const fn (Ctx, Relation) anyerror!void = null,
    };
}

/// Decodes one uncompressed PrimitiveBlock, calling `v` for its elements. An element (its tags,
/// refs, members) is only valid during its callback. `scratch` holds the per-element arrays; it
/// is reset per block.
pub fn decodeBlock(comptime Ctx: type, ctx: Ctx, v: Visitor(Ctx), scratch: *std.heap.ArenaAllocator, data: []const u8) !void {
    _ = scratch.reset(.retain_capacity);
    const a = scratch.allocator();
    var strings: std.ArrayList([]const u8) = .empty;
    var groups: std.ArrayList([]const u8) = .empty;
    var granularity: i64 = 100;
    var lat_offset: i64 = 0;
    var lon_offset: i64 = 0;
    var m = Message.init(data);
    while (try m.next()) |f| switch (f.num) {
        1 => {
            var st = Message.init(f.bytes);
            while (try st.next()) |s| if (s.num == 1) try strings.append(a, s.bytes);
        },
        2 => try groups.append(a, f.bytes),
        17 => granularity = @intCast(f.int),
        19 => lat_offset = @bitCast(f.int),
        20 => lon_offset = @bitCast(f.int),
        else => {},
    };
    const g: Geo = .{ .granularity = granularity, .lat_offset = lat_offset, .lon_offset = lon_offset };

    for (groups.items) |group| {
        var gm = Message.init(group);
        while (try gm.next()) |f| switch (f.num) {
            1 => if (v.node) |cb| try cb(ctx, try plainNode(a, strings.items, g, f.bytes)),
            2 => if (v.node) |cb| try denseNodes(Ctx, ctx, cb, a, strings.items, g, f.bytes),
            3 => if (v.way) |cb| try cb(ctx, try way(a, strings.items, f.bytes)),
            4 => if (v.relation) |cb| try cb(ctx, try relation(a, strings.items, f.bytes)),
            else => {},
        };
    }
}

const Geo = struct {
    granularity: i64,
    lat_offset: i64,
    lon_offset: i64,

    fn lat(g: Geo, v: i64) f64 {
        return @as(f64, @floatFromInt(g.lat_offset + g.granularity * v)) * 1e-9;
    }
    fn lon(g: Geo, v: i64) f64 {
        return @as(f64, @floatFromInt(g.lon_offset + g.granularity * v)) * 1e-9;
    }
};

fn unpackU32(a: std.mem.Allocator, bytes: []const u8) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    var p: Packed = .{ .buf = bytes };
    while (p.next()) |x| try out.append(a, @truncate(x));
    return out.items;
}

fn plainNode(a: std.mem.Allocator, strings: []const []const u8, g: Geo, bytes: []const u8) !Node {
    var n: Node = .{ .id = 0, .lat = 0, .lon = 0, .tags = .{ .strings = strings, .keys = &.{}, .vals = &.{} } };
    var m = Message.init(bytes);
    while (try m.next()) |f| switch (f.num) {
        1 => n.id = zigzag(f.int),
        2 => n.tags.keys = try unpackU32(a, f.bytes),
        3 => n.tags.vals = try unpackU32(a, f.bytes),
        8 => n.lat = g.lat(zigzag(f.int)),
        9 => n.lon = g.lon(zigzag(f.int)),
        else => {},
    };
    if (n.tags.keys.len != n.tags.vals.len) return error.BadBlock;
    return n;
}

fn denseNodes(comptime Ctx: type, ctx: Ctx, cb: *const fn (Ctx, Node) anyerror!void, a: std.mem.Allocator, strings: []const []const u8, g: Geo, bytes: []const u8) !void {
    var ids: Packed = .{ .buf = &.{} };
    var lats: Packed = .{ .buf = &.{} };
    var lons: Packed = .{ .buf = &.{} };
    var kv: Packed = .{ .buf = &.{} };
    var m = Message.init(bytes);
    while (try m.next()) |f| switch (f.num) {
        1 => ids.buf = f.bytes,
        8 => lats.buf = f.bytes,
        9 => lons.buf = f.bytes,
        10 => kv.buf = f.bytes,
        else => {},
    };
    var id: i64 = 0;
    var lat: i64 = 0;
    var lon: i64 = 0;
    var keys: std.ArrayList(u32) = .empty;
    var vals: std.ArrayList(u32) = .empty;
    while (ids.nextDelta(&id)) |nid| {
        const la = lats.nextDelta(&lat) orelse return error.BadBlock;
        const lo = lons.nextDelta(&lon) orelse return error.BadBlock;
        // keys_vals: k, v, k, v, ..., 0 for each node (absent when no node has tags).
        keys.clearRetainingCapacity();
        vals.clearRetainingCapacity();
        if (kv.buf.len > 0) while (kv.next()) |k| {
            if (k == 0) break;
            const val = kv.next() orelse return error.BadBlock;
            try keys.append(a, @truncate(k));
            try vals.append(a, @truncate(val));
        };
        try cb(ctx, .{ .id = nid, .lat = g.lat(la), .lon = g.lon(lo), .tags = .{ .strings = strings, .keys = keys.items, .vals = vals.items } });
    }
}

fn way(a: std.mem.Allocator, strings: []const []const u8, bytes: []const u8) !Way {
    var w: Way = .{ .id = 0, .tags = .{ .strings = strings, .keys = &.{}, .vals = &.{} }, .refs = &.{} };
    var m = Message.init(bytes);
    while (try m.next()) |f| switch (f.num) {
        1 => w.id = @bitCast(f.int),
        2 => w.tags.keys = try unpackU32(a, f.bytes),
        3 => w.tags.vals = try unpackU32(a, f.bytes),
        8 => {
            var refs: std.ArrayList(i64) = .empty;
            var p: Packed = .{ .buf = f.bytes };
            var acc: i64 = 0;
            while (p.nextDelta(&acc)) |r| try refs.append(a, r);
            w.refs = refs.items;
        },
        else => {},
    };
    if (w.tags.keys.len != w.tags.vals.len) return error.BadBlock;
    return w;
}

fn relation(a: std.mem.Allocator, strings: []const []const u8, bytes: []const u8) !Relation {
    var r: Relation = .{ .id = 0, .tags = .{ .strings = strings, .keys = &.{}, .vals = &.{} }, .members = &.{} };
    var roles: Packed = .{ .buf = &.{} };
    var ids: Packed = .{ .buf = &.{} };
    var types: Packed = .{ .buf = &.{} };
    var m = Message.init(bytes);
    while (try m.next()) |f| switch (f.num) {
        1 => r.id = @bitCast(f.int),
        2 => r.tags.keys = try unpackU32(a, f.bytes),
        3 => r.tags.vals = try unpackU32(a, f.bytes),
        8 => roles.buf = f.bytes,
        9 => ids.buf = f.bytes,
        10 => types.buf = f.bytes,
        else => {},
    };
    if (r.tags.keys.len != r.tags.vals.len) return error.BadBlock;
    var members: std.ArrayList(Member) = .empty;
    var acc: i64 = 0;
    while (ids.nextDelta(&acc)) |id| {
        const role = roles.next() orelse return error.BadBlock;
        const t = types.next() orelse return error.BadBlock;
        try members.append(a, .{ .id = id, .type = @enumFromInt(@as(u2, @truncate(t))), .role = if (role < strings.len) strings[@intCast(role)] else "" });
    }
    r.members = members.items;
    return r;
}

/// Calls `v` for every element of a whole .pbf file held in memory.
pub fn each(comptime Ctx: type, gpa: std.mem.Allocator, data: []const u8, ctx: Ctx, v: Visitor(Ctx)) !void {
    var blocks: Blocks = .{ .data = data };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    while (try blocks.next()) |b| {
        if (b.kind != .data) continue;
        try decodeBlock(Ctx, ctx, v, &scratch, try inflate(gpa, b.blob, &out));
    }
}

const testing = std.testing;

test "varint and zigzag" {
    var pos: usize = 0;
    try testing.expectEqual(@as(u64, 300), try varint(&.{ 0xac, 0x02 }, &pos));
    try testing.expectEqual(@as(i64, -1), zigzag(1));
    try testing.expectEqual(@as(i64, 1), zigzag(2));
    try testing.expectEqual(@as(i64, -2), zigzag(3));
}

test "decodes a hand-built block with dense nodes, a way and a relation" {
    // A protobuf writer just for the test.
    const W = struct {
        fn vint(out: *std.ArrayList(u8), v: u64) !void {
            var x = v;
            while (x >= 0x80) : (x >>= 7) try out.append(testing.allocator, @as(u8, @truncate(x)) | 0x80);
            try out.append(testing.allocator, @truncate(x));
        }
        fn zz(v: i64) u64 {
            return @bitCast((v << 1) ^ (v >> 63));
        }
        fn bytesField(out: *std.ArrayList(u8), num: u32, b: []const u8) !void {
            try vint(out, @as(u64, num) << 3 | 2);
            try vint(out, b.len);
            try out.appendSlice(testing.allocator, b);
        }
        fn packed_(num: u32, vals: []const u64) !std.ArrayList(u8) {
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(testing.allocator);
            for (vals) |x| try vint(&body, x);
            var out: std.ArrayList(u8) = .empty;
            try bytesField(&out, num, body.items);
            return out;
        }
    };
    const al = testing.allocator;
    var st: std.ArrayList(u8) = .empty;
    defer st.deinit(al);
    for ([_][]const u8{ "", "name", "Damascus", "place", "city", "highway", "outer" }) |s| try W.bytesField(&st, 1, s);

    // Dense: ids 10, 11; lat 33.5, 33.6; lon 36.3, 36.2 (granularity 100 → units of 1e-7).
    var dense: std.ArrayList(u8) = .empty;
    defer dense.deinit(al);
    inline for (.{
        .{ 1, &[_]u64{ W.zz(10), W.zz(1) } },
        .{ 8, &[_]u64{ W.zz(335_000_000), W.zz(1_000_000) } },
        .{ 9, &[_]u64{ W.zz(363_000_000), W.zz(-1_000_000) } },
        .{ 10, &[_]u64{ 1, 2, 3, 4, 0, 0 } },
    }) |fld| {
        var p = try W.packed_(fld[0], fld[1]);
        defer p.deinit(al);
        try dense.appendSlice(al, p.items);
    }
    var way_msg: std.ArrayList(u8) = .empty;
    defer way_msg.deinit(al);
    try W.vint(&way_msg, 1 << 3);
    try W.vint(&way_msg, 77);
    inline for (.{ .{ 2, &[_]u64{5} }, .{ 3, &[_]u64{2} }, .{ 8, &[_]u64{ W.zz(10), W.zz(1) } } }) |fld| {
        var p = try W.packed_(fld[0], fld[1]);
        defer p.deinit(al);
        try way_msg.appendSlice(al, p.items);
    }
    var rel: std.ArrayList(u8) = .empty;
    defer rel.deinit(al);
    try W.vint(&rel, 1 << 3);
    try W.vint(&rel, 5);
    inline for (.{ .{ 8, &[_]u64{6} }, .{ 9, &[_]u64{W.zz(77)} }, .{ 10, &[_]u64{1} } }) |fld| {
        var p = try W.packed_(fld[0], fld[1]);
        defer p.deinit(al);
        try rel.appendSlice(al, p.items);
    }
    var group: std.ArrayList(u8) = .empty;
    defer group.deinit(al);
    try W.bytesField(&group, 2, dense.items);
    try W.bytesField(&group, 3, way_msg.items);
    try W.bytesField(&group, 4, rel.items);
    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(al);
    try W.bytesField(&block, 1, st.items);
    try W.bytesField(&block, 2, group.items);

    const Seen = struct {
        nodes: [2]Node = undefined,
        /// Tags are only valid during the callback.
        places: [2]?[]const u8 = .{ null, null },
        n: usize = 0,
        way_refs: [2]i64 = undefined,
        way_tag: []const u8 = "",
        rel_member: Member = undefined,
        fn node(s: *@This(), n: Node) !void {
            s.nodes[s.n] = n;
            s.places[s.n] = n.tags.get("place");
            s.n += 1;
        }
        fn way_(s: *@This(), w: Way) !void {
            @memcpy(&s.way_refs, w.refs);
            s.way_tag = w.tags.get("highway") orelse "";
        }
        fn rel_(s: *@This(), r: Relation) !void {
            s.rel_member = r.members[0];
        }
    };
    var seen: Seen = .{};
    var scratch = std.heap.ArenaAllocator.init(al);
    defer scratch.deinit();
    try decodeBlock(*Seen, &seen, .{ .node = Seen.node, .way = Seen.way_, .relation = Seen.rel_ }, &scratch, block.items);
    try testing.expectEqual(@as(usize, 2), seen.n);
    try testing.expectEqual(@as(i64, 11), seen.nodes[1].id);
    try testing.expectApproxEqAbs(@as(f64, 33.6), seen.nodes[1].lat, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 36.2), seen.nodes[1].lon, 1e-9);
    try testing.expectEqualStrings("city", seen.places[0].?);
    try testing.expect(seen.places[1] == null);
    try testing.expectEqual([2]i64{ 10, 11 }, seen.way_refs);
    try testing.expectEqualStrings("Damascus", seen.way_tag);
    try testing.expectEqual(@as(i64, 77), seen.rel_member.id);
    try testing.expectEqual(MemberType.way, seen.rel_member.type);
    try testing.expectEqualStrings("outer", seen.rel_member.role);
}
