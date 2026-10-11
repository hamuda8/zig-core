//! Tests against a real MongoDB on 127.0.0.1:27017 (skipped when none is running). They use a
//! throwaway database that is dropped afterwards.

const std = @import("std");
const mongo = @import("mongo.zig");
const bson = mongo.bson;

const testing = std.testing;
const io = testing.io;

const uri = "mongodb://127.0.0.1:27017/zigcore_test";

fn connectOrSkip() !*mongo.Client {
    const c = try mongo.Client.init(io, testing.allocator, uri);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = c.command(arena.allocator(), "admin", .{ .ping = 1 }) catch {
        c.deinit();
        return error.SkipZigTest;
    };
    return c;
}

test "uri parsing" {
    const c = try mongo.Client.init(io, testing.allocator, "mongodb://ma%40ps:p%3Ass@db.local:27018/Maps?authSource=admin");
    defer c.deinit();
    try testing.expectEqualStrings("db.local", c.host);
    try testing.expectEqual(@as(u16, 27018), c.port);
    try testing.expectEqualStrings("Maps", c.default_db);
    try testing.expectEqualStrings("ma@ps", c.credentials.?.user);
    try testing.expectEqualStrings("p:ss", c.credentials.?.password);
    try testing.expectEqualStrings("admin", c.credentials.?.source);
}

test "insert, find, update, count, aggregate, delete, cursors" {
    const c = try connectOrSkip();
    defer c.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    defer c.database("zigcore_test").drop(a) catch {};

    const places = c.collection("places");
    try places.drop(a);

    const id = try places.insertOne(a, .{ .name = "Damascus", .country = "SY", .pop = 2_500_000 });
    try testing.expect(id == .object_id);

    // 250 more, enough to need several batches.
    var docs: [250]bson.Doc = undefined;
    for (&docs, 0..) |*d, i| d.* = try bson.encode(a, .{ .name = try std.fmt.allocPrint(a, "Place {d}", .{i}), .country = "MY", .pop = i });
    _ = try places.insertMany(a, &docs);

    const found = (try places.findOne(a, .{ .name = "Damascus" }, .{})).?;
    try testing.expectEqualStrings("SY", found.getString("country").?);
    try testing.expectEqual(id.object_id.bytes, found.get("_id").?.object_id.bytes);

    try testing.expectEqual(@as(i64, 250), try places.countDocuments(a, .{ .country = "MY" }));
    try testing.expectEqual(@as(i64, 50), try places.countDocuments(a, .{ .country = "MY", .pop = .{ .@"$gte" = 200 } }));

    var cursor = try places.find(a, .{ .country = "MY" }, .{ .batch_size = 40, .sort = try bson.encode(a, .{ .pop = -1 }) });
    const all = try cursor.all();
    try testing.expectEqual(@as(usize, 250), all.len);
    try testing.expectEqual(@as(i64, 249), all[0].get("pop").?.asInt().?);

    const up = try places.updateMany(a, .{ .country = "MY" }, .{ .@"$set" = .{ .region = "Asia" } }, .{});
    try testing.expectEqual(@as(i64, 250), up.matched);
    const ups = try places.updateOne(a, .{ .name = "Amman" }, .{ .@"$set" = .{ .country = "JO" } }, .{ .upsert = true });
    try testing.expect(ups.upserted_id != null);

    const after = (try places.findOneAndUpdate(a, .{ .name = "Damascus" }, .{ .@"$inc" = .{ .visits = 1 } }, .{})).?;
    try testing.expectEqual(@as(i64, 1), after.get("visits").?.asInt().?);

    var agg = try places.aggregate(a, .{
        .{ .@"$group" = .{ ._id = "$country", .n = .{ .@"$sum" = 1 } } },
        .{ .@"$sort" = .{ ._id = 1 } },
    });
    const groups = try agg.all();
    try testing.expectEqual(@as(usize, 3), groups.len);
    try testing.expectEqualStrings("JO", groups[0].getString("_id").?);

    try places.createIndex(a, .{ .name = 1 }, .{ .unique = true });
    try testing.expectError(error.DuplicateKey, places.insertOne(a, .{ .name = "Damascus" }));
    try testing.expect(std.mem.indexOf(u8, c.lastError(), "duplicate key") != null);

    try testing.expectEqual(@as(i64, 250), try places.deleteMany(a, .{ .country = "MY" }));
    try testing.expectEqual(@as(i64, 2), try places.countDocuments(a, .{}));
}

test "SCRAM-SHA-256 sign-in against the server" {
    const c = try connectOrSkip();
    defer c.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = c.database("zigcore_test");
    defer db.drop(a) catch {};
    _ = db.command(a, .{ .dropUser = "zigcore" }) catch {};
    _ = try db.command(a, .{ .createUser = "zigcore", .pwd = "s3cret pass", .roles = .{.{ .role = "readWrite", .db = "zigcore_test" }}, .mechanisms = .{"SCRAM-SHA-256"} });
    defer _ = db.command(a, .{ .dropUser = "zigcore" }) catch {};

    const good = try mongo.Client.init(io, testing.allocator, "mongodb://zigcore:s3cret%20pass@127.0.0.1:27017/zigcore_test");
    defer good.deinit();
    _ = try good.command(a, "zigcore_test", .{ .ping = 1 });

    const bad = try mongo.Client.init(io, testing.allocator, "mongodb://zigcore:wrong@127.0.0.1:27017/zigcore_test");
    defer bad.deinit();
    try testing.expectError(error.AuthenticationFailed, bad.command(a, "zigcore_test", .{ .ping = 1 }));
}

test "concurrent requests share the pool" {
    const c = try connectOrSkip();
    defer c.deinit();
    var group: std.Io.Group = .init;
    var failures: std.atomic.Value(u32) = .init(0);
    for (0..16) |_| try group.concurrent(io, ping, .{ c, &failures });
    try group.await(io);
    try testing.expectEqual(@as(u32, 0), failures.load(.monotonic));
}

fn ping(c: *mongo.Client, failures: *std.atomic.Value(u32)) void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for (0..20) |_| {
        _ = c.command(arena.allocator(), "admin", .{ .ping = 1 }) catch {
            _ = failures.fetchAdd(1, .monotonic);
        };
    }
}
