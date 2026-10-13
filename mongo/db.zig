//! Collections the way Node servers use them through the MongoDB driver
//! (`db.collection('x').findOne(filter, { sort })`): filters, updates, pipelines and options are
//! written as Zig literals or Vals and sent as they are, so MongoDB evaluates the same queries
//! the Node server sent. Results come back as Vals. Commands go through the mongo Client, which
//! owns the connection pool and authentication.
//!
//!     const users: db.Coll = .{ .client = client, .db = "Reseal", .name = "users" };
//!     const u = try users.findOne(arena, .{ .email = email }, .{ .projection = .{ .password = 0 } });
//!
//! Options are anonymous structs with the driver's names: `projection`, `sort`, `limit`, `skip`,
//! `maxTimeMS`, `upsert`, `arrayFilters`, `returnDocument` (`.before`, the driver's default, or
//! `.after`). Document-valued options take a literal, a Val, or an optional of either.

const std = @import("std");
const mongo = @import("mongo.zig");
const val = @import("val.zig");
const bson = @import("bson.zig");
const Val = val.Val;
const Allocator = std.mem.Allocator;

pub const Error = mongo.Error || error{ OutOfMemory, InvalidBson, UnsupportedBsonType, BadReply };

/// The options of `find`, for building them up in a variable.
pub const FindOpts = struct {
    sort: ?Val = null,
    projection: ?Val = null,
    limit: ?i64 = null,
    skip: ?i64 = null,
};

pub const ReturnDoc = enum { before, after };

pub const UpdateResult = struct { matched: i64, modified: i64, upserted_id: ?Val };

/// `x` as a document (bson.Doc as it is; Vals and other values through val.toBson).
pub fn docOf(a: Allocator, x: anytype) !bson.Doc {
    if (@TypeOf(x) == bson.Doc) return x;
    return val.toBson(a, x);
}

fn optDoc(a: Allocator, opts: anytype, comptime name: []const u8) !?bson.Doc {
    if (!@hasField(@TypeOf(opts), name)) return null;
    const x = @field(opts, name);
    if (@TypeOf(x) == @TypeOf(null)) return null;
    if (@typeInfo(@TypeOf(x)) == .optional) {
        const y = x orelse return null;
        if (@TypeOf(y) == Val and y.isNullish()) return null;
        return try docOf(a, y);
    }
    if (@TypeOf(x) == Val and x.isNullish()) return null;
    return try docOf(a, x);
}

fn optInt(opts: anytype, comptime name: []const u8) ?i64 {
    if (!@hasField(@TypeOf(opts), name)) return null;
    const x = @field(opts, name);
    if (@TypeOf(x) == @TypeOf(null)) return null;
    if (@typeInfo(@TypeOf(x)) == .optional) return if (x) |y| @intCast(y) else null;
    return @intCast(x);
}

fn optBool(opts: anytype, comptime name: []const u8) bool {
    if (!@hasField(@TypeOf(opts), name)) return false;
    return @field(opts, name);
}

fn returnsAfter(opts: anytype) bool {
    if (@hasField(@TypeOf(opts), "returnDocument")) return opts.returnDocument == .after;
    return false;
}

pub const Coll = struct {
    client: *mongo.Client,
    db: []const u8,
    name: []const u8,

    fn run(c: Coll, a: Allocator, cmd: bson.Doc) !bson.Doc {
        return c.client.command(a, c.db, cmd);
    }

    fn begin(c: Coll, a: Allocator, command: []const u8) !bson.Builder {
        var b = try bson.Builder.init(a);
        try b.string(command, c.name);
        return b;
    }

    /// find(filter, { projection, sort, limit, skip, maxTimeMS }).toArray()
    pub fn find(c: Coll, a: Allocator, filter: anytype, opts: anytype) ![]Val {
        var b = try c.begin(a, "find");
        try b.doc("filter", try docOf(a, filter));
        if (try optDoc(a, opts, "projection")) |p| try b.doc("projection", p);
        if (try optDoc(a, opts, "sort")) |p| try b.doc("sort", p);
        if (optInt(opts, "skip")) |x| if (x > 0) try b.int64("skip", x);
        if (optInt(opts, "limit")) |x| if (x != 0) {
            // A negative limit in the Node driver means "one batch of |n|": the same documents.
            const l = if (x < 0) -x else x;
            try b.int64("limit", l);
            if (l < 101) try b.int32("batchSize", @intCast(l));
        };
        if (optInt(opts, "maxTimeMS")) |x| try b.int64("maxTimeMS", x);
        return c.drain(a, try c.run(a, try b.finish()));
    }

    pub fn findOne(c: Coll, a: Allocator, filter: anytype, opts: anytype) !?Val {
        var b = try c.begin(a, "find");
        try b.doc("filter", try docOf(a, filter));
        if (try optDoc(a, opts, "projection")) |p| try b.doc("projection", p);
        if (try optDoc(a, opts, "sort")) |p| try b.doc("sort", p);
        if (optInt(opts, "skip")) |x| if (x > 0) try b.int64("skip", x);
        if (optInt(opts, "maxTimeMS")) |x| try b.int64("maxTimeMS", x);
        try b.int64("limit", 1);
        try b.boolean("singleBatch", true);
        const reply = try c.run(a, try b.finish());
        const cur = reply.getDoc("cursor") orelse return error.BadReply;
        const batch = cur.getDoc("firstBatch") orelse return error.BadReply;
        return switch (batch.get("0") orelse return null) {
            .document => |d| try val.fromDoc(a, d),
            else => null,
        };
    }

    /// Every document of a cursor reply, fetching the remaining batches.
    fn drain(c: Coll, a: Allocator, reply: bson.Doc) ![]Val {
        var out: std.ArrayList(Val) = .empty;
        var cur = reply.getDoc("cursor") orelse return error.BadReply;
        var batch = cur.getDoc("firstBatch") orelse return error.BadReply;
        while (true) {
            var it = batch.iterator();
            while (try it.next()) |e| switch (e.value) {
                .document => |d| try out.append(a, try val.fromDoc(a, d)),
                else => return error.BadReply,
            };
            const id = (cur.get("id") orelse return error.BadReply).asInt() orelse 0;
            if (id == 0) break;
            var b = try bson.Builder.init(a);
            try b.int64("getMore", id);
            try b.string("collection", c.name);
            const more = try c.run(a, try b.finish());
            cur = more.getDoc("cursor") orelse return error.BadReply;
            batch = cur.getDoc("nextBatch") orelse return error.BadReply;
        }
        return out.items;
    }

    pub fn aggregate(c: Coll, a: Allocator, pipeline: anytype) ![]Val {
        var b = try c.begin(a, "aggregate");
        try b.beginArray("pipeline");
        for ((try val.from(a, pipeline)).items()) |stage| try val.writeBson(&b, "", stage);
        try b.end();
        try b.beginDoc("cursor");
        try b.end();
        return c.drain(a, try c.run(a, try b.finish()));
    }

    /// Inserts `doc` (a Val object or anything `val.from` makes one of) and returns its `_id`.
    /// Like the Node driver, an object without `_id` (or with a null one) gets one added to it.
    pub fn insertOne(c: Coll, a: Allocator, doc: anytype) !Val {
        const v = try val.from(a, doc);
        const ids = try c.insertMany(a, &.{v});
        return ids[0];
    }

    /// Inserts in order, stopping at the first failure (the driver's default); returns the ids.
    pub fn insertMany(c: Coll, a: Allocator, docs: []const Val) ![]Val {
        const ids = try a.alloc(Val, docs.len);
        if (docs.len == 0) return ids;
        var b = try c.begin(a, "insert");
        try b.beginArray("documents");
        for (docs, ids) |d, *idv| {
            idv.* = try ensureId(c.client.io, d);
            // _id first, the way the server stores it.
            const o = d.obj;
            try b.beginDoc("");
            try val.writeBson(&b, "_id", idv.*);
            for (o.keys.items, o.vals.items) |k, x| if (!std.mem.eql(u8, k, "_id")) try val.writeBson(&b, k, x);
            try b.end();
        }
        try b.end();
        _ = try c.run(a, try b.finish());
        return ids;
    }

    /// updateOne(filter, update, { upsert, arrayFilters }). `update` may be a pipeline (array).
    pub fn updateOne(c: Coll, a: Allocator, filter: anytype, update: anytype, opts: anytype) !UpdateResult {
        return c.updateImpl(a, filter, update, opts, false);
    }

    pub fn updateMany(c: Coll, a: Allocator, filter: anytype, update: anytype, opts: anytype) !UpdateResult {
        return c.updateImpl(a, filter, update, opts, true);
    }

    fn updateImpl(c: Coll, a: Allocator, filter: anytype, update: anytype, opts: anytype, multi: bool) !UpdateResult {
        var b = try c.begin(a, "update");
        try b.beginArray("updates");
        try b.beginDoc("");
        try b.doc("q", try docOf(a, filter));
        try writeUpdate(a, &b, "u", update);
        try b.boolean("upsert", optBool(opts, "upsert"));
        try b.boolean("multi", multi);
        if (@hasField(@TypeOf(opts), "arrayFilters")) try val.writeBson(&b, "arrayFilters", try val.from(a, opts.arrayFilters));
        try b.end();
        try b.end();
        const reply = try c.run(a, try b.finish());
        const upserted = if (reply.getDoc("upserted")) |up| (if (up.getDoc("0")) |first| first.get("_id") else null) else null;
        return .{
            .matched = (reply.get("n") orelse bson.Value{ .int32 = 0 }).asInt() orelse 0,
            .modified = (reply.get("nModified") orelse bson.Value{ .int32 = 0 }).asInt() orelse 0,
            .upserted_id = if (upserted) |x| try val.fromBsonValue(a, x) else null,
        };
    }

    pub fn deleteOne(c: Coll, a: Allocator, filter: anytype) !i64 {
        return c.deleteImpl(a, filter, 1);
    }

    pub fn deleteMany(c: Coll, a: Allocator, filter: anytype) !i64 {
        return c.deleteImpl(a, filter, 0);
    }

    fn deleteImpl(c: Coll, a: Allocator, filter: anytype, limit: i32) !i64 {
        var b = try c.begin(a, "delete");
        try b.beginArray("deletes");
        try b.beginDoc("");
        try b.doc("q", try docOf(a, filter));
        try b.int32("limit", limit);
        try b.end();
        try b.end();
        const reply = try c.run(a, try b.finish());
        return (reply.get("n") orelse bson.Value{ .int32 = 0 }).asInt() orelse 0;
    }

    /// countDocuments(filter, { skip, limit, maxTimeMS })
    pub fn count(c: Coll, a: Allocator, filter: anytype, opts: anytype) !i64 {
        var b = try c.begin(a, "aggregate");
        try b.beginArray("pipeline");
        try b.beginDoc("");
        try b.doc("$match", try docOf(a, filter));
        try b.end();
        if (optInt(opts, "skip")) |x| {
            try b.beginDoc("");
            try b.int64("$skip", x);
            try b.end();
        }
        if (optInt(opts, "limit")) |x| {
            try b.beginDoc("");
            try b.int64("$limit", x);
            try b.end();
        }
        try b.beginDoc("");
        try b.beginDoc("$group");
        try b.int32("_id", 1);
        try b.beginDoc("n");
        try b.int32("$sum", 1);
        try b.end();
        try b.end();
        try b.end();
        try b.end();
        try b.beginDoc("cursor");
        try b.end();
        if (optInt(opts, "maxTimeMS")) |x| try b.int64("maxTimeMS", x);
        const rows = try c.drain(a, try c.run(a, try b.finish()));
        if (rows.len == 0) return 0;
        return rows[0].get("n").asInt() orelse 0;
    }

    pub fn distinct(c: Coll, a: Allocator, key: []const u8, filter: anytype) ![]Val {
        var b = try c.begin(a, "distinct");
        try b.string("key", key);
        try b.doc("query", try docOf(a, filter));
        const reply = try c.run(a, try b.finish());
        var out: std.ArrayList(Val) = .empty;
        if (reply.getDoc("values")) |values| {
            var it = values.iterator();
            while (try it.next()) |e| try out.append(a, try val.fromBsonValue(a, e.value));
        }
        return out.items;
    }

    /// findOneAndUpdate(filter, update, { returnDocument, projection, sort, upsert }): the
    /// document before (the default) or after the update, or null.
    pub fn findOneAndUpdate(c: Coll, a: Allocator, filter: anytype, update: anytype, opts: anytype) !?Val {
        var b = try c.begin(a, "findAndModify");
        try b.doc("query", try docOf(a, filter));
        try writeUpdate(a, &b, "update", update);
        try b.boolean("new", returnsAfter(opts));
        try b.boolean("upsert", optBool(opts, "upsert"));
        if (try optDoc(a, opts, "sort")) |x| try b.doc("sort", x);
        if (try optDoc(a, opts, "projection")) |x| try b.doc("fields", x);
        if (@hasField(@TypeOf(opts), "arrayFilters")) try val.writeBson(&b, "arrayFilters", try val.from(a, opts.arrayFilters));
        const reply = try c.run(a, try b.finish());
        return switch (reply.get("value") orelse return null) {
            .document => |d| try val.fromDoc(a, d),
            else => null,
        };
    }

    /// createIndex(keys, { name, unique, sparse, partialFilterExpression, expireAfterSeconds })
    pub fn createIndex(c: Coll, a: Allocator, keys: anytype, opts: anytype) !void {
        const k = try val.from(a, keys);
        const o = try val.from(a, opts);
        var name: std.ArrayList(u8) = .empty;
        for (k.keys(), k.vals()) |field, x| {
            if (name.items.len > 0) try name.append(a, '_');
            try name.print(a, "{s}_{s}", .{ field, try val.toStr(a, x) });
        }
        var b = try c.begin(a, "createIndexes");
        try b.beginArray("indexes");
        try b.beginDoc("");
        try val.writeBson(&b, "key", k);
        try b.string("name", o.s("name") orelse name.items);
        for (o.keys(), o.vals()) |field, x| if (!std.mem.eql(u8, field, "name")) try val.writeBson(&b, field, x);
        try b.end();
        try b.end();
        _ = try c.run(a, try b.finish());
    }
};

/// An update document, or a pipeline update (an array of stages).
fn writeUpdate(a: Allocator, b: *bson.Builder, key: []const u8, update: anytype) !void {
    if (@TypeOf(update) == bson.Doc) return b.doc(key, update);
    const u = try val.from(a, update);
    if (u == .arr) return val.writeBson(b, key, u);
    try b.doc(key, try val.toBson(a, u));
}

/// Gives `doc` an ObjectId `_id` when it has none (or a null one), the way the driver's insert
/// does (a new key goes last, an existing one keeps its place); returns the `_id`.
pub fn ensureId(io: std.Io, doc: Val) !Val {
    const o = doc.asObj() orelse return error.NotAnObject;
    if (o.get("_id")) |existing| if (!existing.isNullish()) return existing;
    const id: Val = .{ .id = bson.ObjectId.generate(io) };
    try o.put("_id", id);
    return id;
}
