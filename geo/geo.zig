//! Place search and reverse geocoding from OpenStreetMap data, for any number of regions.
//!
//! A region is one .osm.pbf file in the regions folder (a country from download.geofabrik.de,
//! a continent, or the planet). `Regions.refresh` finds new or changed files, builds their index
//! next to them (<name>.wgeo) and loads it; a removed file's region is dropped. Adding a country
//! is copying its file into the folder.

const std = @import("std");
const Io = std.Io;
pub const pbf = @import("pbf.zig");
pub const normalize = @import("normalize.zig");
pub const index = @import("index.zig");
pub const builder = @import("builder.zig");

pub const Place = index.Place;

pub const Region = struct {
    name: []u8,
    file: Io.File,
    map: Io.File.MemoryMap,
    index: index.Index,
    refs: std.atomic.Value(u32) = .init(1),

    fn release(r: *Region, io: Io, gpa: std.mem.Allocator) void {
        if (r.refs.fetchSub(1, .acq_rel) != 1) return;
        r.map.destroy(io);
        r.file.close(io);
        gpa.free(r.name);
        gpa.destroy(r);
    }
};

const pbf_suffix = ".osm.pbf";
const index_suffix = ".wgeo";

pub const Regions = struct {
    io: Io,
    gpa: std.mem.Allocator,
    dir: []const u8,
    lock: Io.Mutex = .init,
    list: std.ArrayList(*Region) = .empty,
    /// Progress and problems, one line each.
    log: *const fn ([]const u8) void = noLog,

    pub fn init(io: Io, gpa: std.mem.Allocator, dir: []const u8) Regions {
        return .{ .io = io, .gpa = gpa, .dir = dir };
    }

    pub fn deinit(rs: *Regions) void {
        for (rs.list.items) |r| r.release(rs.io, rs.gpa);
        rs.list.deinit(rs.gpa);
    }

    fn logf(rs: *Regions, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        rs.log(std.fmt.bufPrint(&buf, fmt, args) catch fmt);
    }

    /// Brings the loaded regions in line with the folder. Building an index takes from seconds
    /// (a country) to hours (the planet), so call this from a background task; searches keep
    /// working on the regions already loaded meanwhile.
    pub fn refresh(rs: *Regions) !void {
        var arena_state = std.heap.ArenaAllocator.init(rs.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const io = rs.io;

        var dir = Io.Dir.cwd().openDir(io, rs.dir, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer dir.close(io);

        const Found = struct { base: []const u8, size: u64, mtime: i64 };
        var found: std.ArrayList(Found) = .empty;
        var it = dir.iterate();
        while (try it.next(io)) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, pbf_suffix)) continue;
            const st = try dir.statFile(io, e.name, .{});
            try found.append(arena, .{ .base = try arena.dupe(u8, e.name[0 .. e.name.len - pbf_suffix.len]), .size = st.size, .mtime = mtimeOf(st) });
        }

        for (found.items) |f| {
            if (rs.loadedMatches(f.base, f.size, f.mtime)) continue;
            const index_name = try std.fmt.allocPrint(arena, "{s}{s}", .{ f.base, index_suffix });
            const region = rs.open(dir, f.base, index_name, f.size, f.mtime) catch |e| blk: {
                if (e != error.Stale and e != error.FileNotFound) rs.logf("geo: {s}: index unreadable ({t}), rebuilding", .{ f.base, e });
                rs.buildIndex(dir, f.base, index_name, f.size, f.mtime) catch |be| {
                    rs.logf("geo: {s}: index build failed: {t}", .{ f.base, be });
                    continue;
                };
                break :blk rs.open(dir, f.base, index_name, f.size, f.mtime) catch |oe| {
                    rs.logf("geo: {s}: cannot open the new index: {t}", .{ f.base, oe });
                    continue;
                };
            };
            rs.swapIn(region);
            rs.logf("geo: {s}: {d} places", .{ f.base, region.index.features.len });
        }

        // Regions whose file is gone.
        rs.lock.lockUncancelable(io);
        var i: usize = 0;
        while (i < rs.list.items.len) {
            const r = rs.list.items[i];
            const still = for (found.items) |f| {
                if (std.mem.eql(u8, f.base, r.name)) break true;
            } else false;
            if (still) {
                i += 1;
                continue;
            }
            _ = rs.list.orderedRemove(i);
            rs.logf("geo: {s}: removed", .{r.name});
            r.release(io, rs.gpa);
        }
        rs.lock.unlock(io);
    }

    fn loadedMatches(rs: *Regions, base: []const u8, size: u64, mtime: i64) bool {
        rs.lock.lockUncancelable(rs.io);
        defer rs.lock.unlock(rs.io);
        for (rs.list.items) |r| {
            if (!std.mem.eql(u8, r.name, base)) continue;
            return r.index.header.source_size == size and r.index.header.source_mtime == mtime;
        }
        return false;
    }

    fn open(rs: *Regions, dir: Io.Dir, base: []const u8, index_name: []const u8, size: u64, mtime: i64) !*Region {
        const io = rs.io;
        const file = try dir.openFile(io, index_name, .{});
        errdefer file.close(io);
        const len = try file.length(io);
        if (len < @sizeOf(index.Header)) return error.BadIndex;
        var map = try Io.File.MemoryMap.create(io, file, .{ .len = @intCast(len), .protection = .{ .read = true }, .populate = false });
        errdefer map.destroy(io);
        const ixd = try index.Index.open(map.memory);
        if (ixd.header.source_size != size or ixd.header.source_mtime != mtime) return error.Stale;
        const r = try rs.gpa.create(Region);
        r.* = .{ .name = try rs.gpa.dupe(u8, base), .file = file, .map = map, .index = ixd };
        return r;
    }

    fn buildIndex(rs: *Regions, dir: Io.Dir, base: []const u8, index_name: []const u8, size: u64, mtime: i64) !void {
        const io = rs.io;
        rs.logf("geo: {s}: building the search index", .{base});
        const started = Io.Timestamp.now(io, .awake);
        var name_buf: [512]u8 = undefined;
        const pbf_name = try std.fmt.bufPrint(&name_buf, "{s}{s}", .{ base, pbf_suffix });
        const src = try dir.openFile(io, pbf_name, .{});
        defer src.close(io);
        var src_map = try Io.File.MemoryMap.create(io, src, .{ .len = @intCast(size), .protection = .{ .read = true }, .populate = false });
        defer src_map.destroy(io);

        var tmp_buf: [512]u8 = undefined;
        const tmp_name = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{index_name});
        const out = try dir.createFile(io, tmp_name, .{});
        var ok = false;
        defer if (!ok) dir.deleteFile(io, tmp_name) catch {};
        {
            defer out.close(io);
            var buf: [64 * 1024]u8 = undefined;
            var w = out.writer(io, &buf);
            const stats = try builder.build(rs.gpa, src_map.memory, .{ .size = size, .mtime = mtime }, &w.interface);
            const secs = @as(f64, @floatFromInt(started.untilNow(io, .awake).toMilliseconds())) / 1000;
            rs.logf("geo: {s}: {d} places, {d} words, {d} MB, {d:.1} s", .{ base, stats.features, stats.tokens, stats.bytes / (1024 * 1024), secs });
        }
        try dir.rename(tmp_name, dir, index_name, io);
        ok = true;
    }

    /// Adds a region, or replaces the one of the same name.
    fn swapIn(rs: *Regions, region: *Region) void {
        rs.lock.lockUncancelable(rs.io);
        defer rs.lock.unlock(rs.io);
        for (rs.list.items) |*slot| {
            if (!std.mem.eql(u8, slot.*.name, region.name)) continue;
            const old = slot.*;
            slot.* = region;
            old.release(rs.io, rs.gpa);
            return;
        }
        rs.list.append(rs.gpa, region) catch region.release(rs.io, rs.gpa);
    }

    /// The loaded regions, each held until `releaseAll`.
    fn acquire(rs: *Regions, arena: std.mem.Allocator) ![]*Region {
        rs.lock.lockUncancelable(rs.io);
        defer rs.lock.unlock(rs.io);
        const out = try arena.dupe(*Region, rs.list.items);
        for (out) |r| _ = r.refs.fetchAdd(1, .acq_rel);
        return out;
    }

    fn releaseAll(rs: *Regions, regions: []*Region) void {
        for (regions) |r| r.release(rs.io, rs.gpa);
    }

    pub fn count(rs: *Regions) usize {
        rs.lock.lockUncancelable(rs.io);
        defer rs.lock.unlock(rs.io);
        return rs.list.items.len;
    }

    /// Whether some region's area includes the point.
    pub fn covers(rs: *Regions, lat: f64, lon: f64) bool {
        rs.lock.lockUncancelable(rs.io);
        defer rs.lock.unlock(rs.io);
        for (rs.list.items) |r| if (r.index.contains(lat, lon)) return true;
        return false;
    }

    /// Places matching `text` in every region, best first; nearer `near` ranks higher.
    /// `lang` picks the language of names that have one ("en", "ar", ...).
    pub fn search(rs: *Regions, arena: std.mem.Allocator, text: []const u8, near: ?[2]f64, lang: ?[]const u8, limit: usize) ![]Place {
        const regions = try rs.acquire(arena);
        defer rs.releaseAll(regions);
        const q = try index.parseQuery(arena, text, near, lang);
        var hits: std.ArrayList(index.Hit) = .empty;
        for (regions) |r| try index.searchRegion(&r.index, arena, q, &hits);
        return index.finish(arena, hits.items, limit, lang);
    }

    /// The named place nearest to a point, or null when no region has one close by.
    pub fn reverse(rs: *Regions, arena: std.mem.Allocator, lat: f64, lon: f64, lang: ?[]const u8) !?Place {
        const regions = try rs.acquire(arena);
        defer rs.releaseAll(regions);
        var best: ?struct { r: *Region, id: u32, cost: f64 } = null;
        for (regions) |r| {
            if (r.index.boundsDistance(lat, lon) > 0.05) continue;
            const hit = index.reverseRegion(&r.index, lat, lon) orelse continue;
            if (best == null or hit.cost < best.?.cost) best = .{ .r = r, .id = hit.id, .cost = hit.cost };
        }
        const b = best orelse return null;
        return try b.r.index.place(arena, b.id, lang);
    }
};

fn mtimeOf(st: Io.File.Stat) i64 {
    return @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_ms));
}

fn noLog(_: []const u8) void {}

test {
    _ = pbf;
    _ = normalize;
    _ = index;
    _ = builder;
}
