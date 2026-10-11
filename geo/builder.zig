//! Builds a region's search index from its .osm.pbf, in three passes over the file:
//!   1. relations: state and country boundaries (for each place's state and country)
//!   2. ways: named streets and named areas (malls, parks, campuses), and the boundary ways
//!   3. nodes: named places and points of interest, addresses, and the coordinates the ways need
//! Then every feature gets its address (street, area, city, state, country), from its own
//! addr:* tags where present, else from the places and boundaries around it.

const std = @import("std");
const pbf = @import("pbf.zig");
const norm = @import("normalize.zig");
const ix = @import("index.zig");

pub const Stats = struct { features: usize, tokens: usize, grid: usize, bytes: usize };

pub const Source = struct { size: u64, mtime: i64 };

/// Builds the index for the .pbf contents `data` and writes it to `out` (a new file).
pub fn build(gpa: std.mem.Allocator, data: []const u8, source: Source, out: *std.Io.Writer) !Stats {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var b: Builder = .{ .gpa = gpa, .a = arena_state.allocator() };
    defer b.deinit();

    try pbf.each(*Builder, gpa, data, &b, .{ .relation = Builder.relation });
    try pbf.each(*Builder, gpa, data, &b, .{ .way = Builder.way });
    std.mem.sort(i64, b.needed.items, {}, std.sort.asc(i64));
    b.needed.items.len = uniq(b.needed.items);
    b.coords = try b.a.alloc([2]i32, b.needed.items.len);
    @memset(b.coords, .{ std.math.minInt(i32), 0 });
    try pbf.each(*Builder, gpa, data, &b, .{ .node = Builder.node });

    try b.finishWays();
    try b.prepareAdmins();
    try b.assignAddresses();
    return b.write(source, out);
}

fn uniq(items: []i64) usize {
    if (items.len == 0) return 0;
    var n: usize = 1;
    for (items[1..]) |x| {
        if (x != items[n - 1]) {
            items[n] = x;
            n += 1;
        }
    }
    return n;
}

const Settlement = enum(u8) { none, city, town, village, suburb, quarter, neighbourhood, hamlet };

/// A feature before its address is filled in. Strings live in the builder's arena.
const Pre = struct {
    name: []const u8,
    alt: []const u8 = "",
    street: []const u8 = "",
    housenumber: []const u8 = "",
    area: []const u8 = "",
    city: []const u8 = "",
    state: []const u8 = "",
    country: [2]u8 = .{ 0, 0 },
    lat: f64,
    lon: f64,
    kind: ix.Kind,
    rank: u8,
    settlement: Settlement = .none,
    /// The place the area, city and state come from, when not given as text: stored as a
    /// reference so the label can be shown in the reader's language.
    area_f: ?u32 = null,
    city_f: ?u32 = null,
    state_f: ?u32 = null,
};

const Admin = struct {
    level: u8,
    name: []const u8,
    alt: []const u8,
    iso: [2]u8,
    ways: []const i64,
    /// Its own feature (a searchable state or country), once the boundary is known complete.
    feature: ?u32 = null,
    // Filled by prepareAdmins: boundary segments, bucketed into latitude bands.
    segs: []const [4]f64 = &.{},
    min_lat: f64 = 0,
    max_lat: f64 = 0,
    min_lon: f64 = 0,
    max_lon: f64 = 0,
    band_start: []const u32 = &.{},
    band_segs: []const u32 = &.{},

    const bandRange = adminBandRange;
    const inside = adminInside;
};

const band_deg = 0.05;

const NamedWay = struct { info: Info, refs: []const i64 };

const Builder = struct {
    gpa: std.mem.Allocator,
    a: std.mem.Allocator,
    admins: std.ArrayList(Admin) = .empty,
    boundary_ways: std.AutoHashMapUnmanaged(i64, []const i64) = .empty,
    ways: std.ArrayList(NamedWay) = .empty,
    needed: std.ArrayList(i64) = .empty,
    coords: [][2]i32 = &.{},
    /// Cursor for matching nodes (sorted by id in the file) with `needed`.
    cursor: usize = 0,
    features: std.ArrayList(Pre) = .empty,
    /// Grid points (feature index, lat, lon) of streets: their nodes.
    street_points: std.ArrayList(struct { feature: u32, lat: f64, lon: f64 }) = .empty,

    fn deinit(b: *Builder) void {
        b.admins.deinit(b.gpa);
        b.boundary_ways.deinit(b.gpa);
        b.ways.deinit(b.gpa);
        b.needed.deinit(b.gpa);
        b.features.deinit(b.gpa);
        b.street_points.deinit(b.gpa);
    }

    fn relation(b: *Builder, r: pbf.Relation) !void {
        const t = r.tags;
        const boundary = t.get("boundary") orelse return;
        if (!std.mem.eql(u8, boundary, "administrative")) return;
        const level_s = t.get("admin_level") orelse return;
        const level = std.fmt.parseInt(u8, level_s, 10) catch return;
        if (level != 2 and level != 4) return;
        var iso: [2]u8 = .{ 0, 0 };
        if (t.get("ISO3166-1:alpha2") orelse t.get("ISO3166-1")) |code| if (code.len == 2) {
            iso = .{ std.ascii.toUpper(code[0]), std.ascii.toUpper(code[1]) };
        };
        // A state's code starts with its country's ("MY-10").
        if (iso[0] == 0) if (t.get("ISO3166-2")) |code| if (code.len > 3 and code[2] == '-') {
            iso = .{ std.ascii.toUpper(code[0]), std.ascii.toUpper(code[1]) };
        };
        var ways: std.ArrayList(i64) = .empty;
        for (r.members) |m| {
            if (m.type != .way) continue;
            if (!(m.role.len == 0 or std.mem.eql(u8, m.role, "outer") or std.mem.eql(u8, m.role, "inner"))) continue;
            try ways.append(b.a, m.id);
            try b.boundary_ways.put(b.gpa, m.id, &.{});
        }
        if (ways.items.len == 0) return;
        const name = try b.a.dupe(u8, t.get("name") orelse "");
        try b.admins.append(b.gpa, .{
            .level = level,
            .name = name,
            .alt = try altNames(b.a, t, name),
            .iso = iso,
            .ways = ways.items,
        });
    }

    fn way(b: *Builder, w: pbf.Way) !void {
        if (b.boundary_ways.getPtr(w.id)) |slot| {
            slot.* = try b.a.dupe(i64, w.refs);
            try b.needed.appendSlice(b.gpa, w.refs);
        }
        const info = (try extract(b.a, w.tags, true)) orelse return;
        if (w.refs.len == 0) return;
        try b.ways.append(b.gpa, .{ .info = info, .refs = try b.a.dupe(i64, w.refs) });
        try b.needed.appendSlice(b.gpa, w.refs);
    }

    fn node(b: *Builder, n: pbf.Node) !void {
        const ids = b.needed.items;
        // Nodes come sorted by id: walk forward; fall back to a search if they do not.
        if (b.cursor > 0 and b.cursor <= ids.len and ids[b.cursor - 1] > n.id) {
            b.cursor = std.sort.lowerBound(i64, ids, n.id, struct {
                fn cmp(x: i64, y: i64) std.math.Order {
                    return std.math.order(x, y);
                }
            }.cmp);
        }
        while (b.cursor < ids.len and ids[b.cursor] < n.id) b.cursor += 1;
        if (b.cursor < ids.len and ids[b.cursor] == n.id) b.coords[b.cursor] = .{ ix.fixed(n.lat), ix.fixed(n.lon) };

        if (n.tags.len() == 0) return;
        const info = (try extract(b.a, n.tags, false)) orelse return;
        try b.features.append(b.gpa, info.pre(n.lat, n.lon));
    }

    fn coordOf(b: *const Builder, id: i64) ?[2]f64 {
        const i = std.sort.binarySearch(i64, b.needed.items, id, struct {
            fn cmp(x: i64, y: i64) std.math.Order {
                return std.math.order(x, y);
            }
        }.cmp) orelse return null;
        const c = b.coords[i];
        if (c[0] == std.math.minInt(i32)) return null;
        return .{ ix.degrees(c[0]), ix.degrees(c[1]) };
    }

    /// Streets become one feature per name and ~5 km cell (a street is many ways), with all
    /// their nodes as reverse-geocoding points; named areas become a point at their centre.
    fn finishWays(b: *Builder) !void {
        var streets: std.StringHashMapUnmanaged(u32) = .empty;
        defer streets.deinit(b.gpa);
        var key: std.ArrayList(u8) = .empty;
        defer key.deinit(b.gpa);
        for (b.ways.items) |w| {
            if (w.info.kind == .street) {
                const mid = b.coordOf(w.refs[w.refs.len / 2]) orelse continue;
                key.clearRetainingCapacity();
                try norm.normalize(b.gpa, w.info.name, &key);
                try key.print(b.gpa, "|{d}|{d}", .{ @floor(mid[0] / band_deg), @floor(mid[1] / band_deg) });
                const gop = try streets.getOrPut(b.gpa, key.items);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try b.a.dupe(u8, key.items);
                    gop.value_ptr.* = @intCast(b.features.items.len);
                    try b.features.append(b.gpa, w.info.pre(mid[0], mid[1]));
                } else {
                    const f = &b.features.items[gop.value_ptr.*];
                    f.rank = @max(f.rank, w.info.rank);
                }
                const fid = gop.value_ptr.*;
                var last: ?[2]f64 = null;
                for (w.refs) |r| {
                    const c = b.coordOf(r) orelse continue;
                    if (last) |l| if (ix.distance(l[0], l[1], c[0], c[1]) < 40) continue;
                    last = c;
                    try b.street_points.append(b.gpa, .{ .feature = fid, .lat = c[0], .lon = c[1] });
                }
            } else {
                var min: [2]f64 = .{ 90, 180 };
                var max: [2]f64 = .{ -90, -180 };
                var any = false;
                for (w.refs) |r| {
                    const c = b.coordOf(r) orelse continue;
                    any = true;
                    min = .{ @min(min[0], c[0]), @min(min[1], c[1]) };
                    max = .{ @max(max[0], c[0]), @max(max[1], c[1]) };
                }
                if (!any) continue;
                try b.features.append(b.gpa, w.info.pre((min[0] + max[0]) / 2, (min[1] + max[1]) / 2));
            }
        }
    }

    /// Boundaries become segments for point-in-area tests, and searchable features. One that
    /// is not closed (the extract holds only part of a neighbouring country) is left out: it
    /// would put places on the wrong side.
    fn prepareAdmins(b: *Builder) !void {
        var ends: std.AutoHashMapUnmanaged(i64, u32) = .empty;
        defer ends.deinit(b.gpa);
        for (b.admins.items) |*ad| {
            ends.clearRetainingCapacity();
            const closed = for (ad.ways) |wid| {
                const refs = b.boundary_ways.get(wid) orelse break false;
                if (refs.len < 2) break false;
                for ([_]i64{ refs[0], refs[refs.len - 1] }) |e| (try ends.getOrPutValue(b.gpa, e, 0)).value_ptr.* += 1;
            } else true;
            const even = closed and blk: {
                var it = ends.valueIterator();
                while (it.next()) |n| if (n.* % 2 != 0) break :blk false;
                break :blk true;
            };
            if (!even) {
                ad.segs = &.{};
                continue;
            }
            var segs: std.ArrayList([4]f64) = .empty;
            ad.min_lat = 90;
            ad.max_lat = -90;
            ad.min_lon = 180;
            ad.max_lon = -180;
            for (ad.ways) |wid| {
                const refs = b.boundary_ways.get(wid) orelse continue;
                var prev: ?[2]f64 = null;
                for (refs) |r| {
                    const c = b.coordOf(r) orelse {
                        prev = null;
                        continue;
                    };
                    if (prev) |p| try segs.append(b.a, .{ p[0], p[1], c[0], c[1] });
                    prev = c;
                    ad.min_lat = @min(ad.min_lat, c[0]);
                    ad.max_lat = @max(ad.max_lat, c[0]);
                    ad.min_lon = @min(ad.min_lon, c[1]);
                    ad.max_lon = @max(ad.max_lon, c[1]);
                }
            }
            ad.segs = segs.items;
            if (segs.items.len == 0) continue;
            const bands: usize = @intFromFloat(@floor((ad.max_lat - ad.min_lat) / band_deg) + 1);
            var counts = try b.a.alloc(u32, bands + 1);
            @memset(counts, 0);
            for (segs.items) |s| {
                const lo, const hi = ad.bandRange(s);
                for (lo..hi + 1) |k| counts[k + 1] += 1;
            }
            for (1..counts.len) |k| counts[k] += counts[k - 1];
            const list = try b.a.alloc(u32, counts[bands]);
            const fill = try b.a.dupe(u32, counts[0..bands]);
            for (segs.items, 0..) |s, si| {
                const lo, const hi = ad.bandRange(s);
                for (lo..hi + 1) |k| {
                    list[fill[k]] = @intCast(si);
                    fill[k] += 1;
                }
            }
            ad.band_start = counts;
            ad.band_segs = list;
            if (ad.name.len > 0) {
                ad.feature = @intCast(b.features.items.len);
                try b.features.append(b.gpa, .{
                    .name = ad.name,
                    .alt = ad.alt,
                    .lat = (ad.min_lat + ad.max_lat) / 2,
                    .lon = (ad.min_lon + ad.max_lon) / 2,
                    .kind = .place,
                    .rank = if (ad.level == 2) 30 else 27,
                    .country = ad.iso,
                });
            }
        }
    }

    /// Fills in each feature's address and country.
    fn assignAddresses(b: *Builder) !void {
        // Settlements by 0.1° cell, for "nearest city" and "nearest neighbourhood".
        var places: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty;
        defer {
            var it = places.valueIterator();
            while (it.next()) |l| l.deinit(b.gpa);
            places.deinit(b.gpa);
        }
        for (b.features.items, 0..) |f, i| {
            if (f.settlement == .none) continue;
            const gop = try places.getOrPut(b.gpa, coarseCell(f.lat, f.lon));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(b.gpa, @intCast(i));
        }
        var admin_cache: std.AutoHashMapUnmanaged(u32, [2]?u32) = .empty;
        defer admin_cache.deinit(b.gpa);
        var countries: std.AutoHashMapUnmanaged([2]u8, usize) = .empty;
        defer countries.deinit(b.gpa);

        for (b.features.items) |*f| {
            // State and country from the boundaries (looked up per ~5 km cell).
            const cell = ix.cellOf(f.lat, f.lon) / 5; // coarse key; exactness is not needed here
            const gop = try admin_cache.getOrPut(b.gpa, cell);
            if (!gop.found_existing) gop.value_ptr.* = .{ b.adminAt(f.lat, f.lon, 4), b.adminAt(f.lat, f.lon, 2) };
            const state, const country = gop.value_ptr.*;
            if (f.country[0] == 0) if (country) |c| {
                f.country = b.admins.items[c].iso;
            };
            if (f.country[0] == 0) if (state) |s| {
                f.country = b.admins.items[s].iso;
            };
            if (f.country[0] != 0) (try countries.getOrPutValue(b.gpa, f.country, 0)).value_ptr.* += 1;
            if (f.state.len == 0 and f.rank < 27) if (state) |s| {
                if (!std.mem.eql(u8, b.admins.items[s].name, f.name)) f.state_f = b.admins.items[s].feature;
            };

            const big = f.settlement == .city or f.settlement == .town or f.settlement == .village or f.rank >= 26;
            // A city or area given as text (addr:city) that names a place nearby becomes a
            // reference to it, so it too can be shown in the reader's language.
            if (f.city.len > 0) if (b.nearestPlace(&places, f.lat, f.lon, &.{ .city, .town, .village }, 25)) |p| {
                if (sameName(b.features.items[p], f.city)) {
                    f.city = "";
                    f.city_f = p;
                }
            };
            if (f.area.len > 0) if (b.nearestPlace(&places, f.lat, f.lon, &.{ .suburb, .quarter, .neighbourhood }, 2.5)) |p| {
                if (sameName(b.features.items[p], f.area)) {
                    f.area = "";
                    f.area_f = p;
                }
            };
            if (f.city.len == 0 and !big) {
                if (b.nearestPlace(&places, f.lat, f.lon, &.{ .city, .town, .village }, 25)) |p| f.city_f = p;
            }
            if (f.area.len == 0 and !big and f.settlement == .none) {
                if (b.nearestPlace(&places, f.lat, f.lon, &.{ .suburb, .quarter, .neighbourhood }, 2.5)) |p| f.area_f = p;
            }
        }
        // Features outside every country boundary (the extract cuts them off) take the
        // region's main country.
        var main: [2]u8 = .{ 0, 0 };
        var most: usize = 0;
        var it = countries.iterator();
        while (it.next()) |e| if (e.value_ptr.* > most) {
            most = e.value_ptr.*;
            main = e.key_ptr.*;
        };
        for (b.features.items) |*f| if (f.country[0] == 0) {
            f.country = main;
        };
    }

    fn adminAt(b: *const Builder, lat: f64, lon: f64, level: u8) ?u32 {
        var best: ?u32 = null;
        for (b.admins.items, 0..) |*ad, i| {
            if (ad.level != level or ad.segs.len == 0) continue;
            if (lat < ad.min_lat or lat > ad.max_lat or lon < ad.min_lon or lon > ad.max_lon) continue;
            if (ad.inside(lat, lon)) best = @intCast(i);
        }
        return best;
    }

    /// The nearest settlement of the given types, by distance relative to how far each type
    /// reaches (a city 20 km away counts as near; a village 20 km away does not).
    fn nearestPlace(b: *const Builder, places: anytype, lat: f64, lon: f64, types: []const Settlement, max_km: f64) ?u32 {
        const c = coarseCell(lat, lon);
        const reach = @as(i64, @intFromFloat(@ceil(max_km / 11))) + 1;
        var best: ?u32 = null;
        var best_score: f64 = std.math.inf(f64);
        var dr: i64 = -reach;
        while (dr <= reach) : (dr += 1) {
            var dc: i64 = -reach;
            while (dc <= reach) : (dc += 1) {
                const key = @as(i64, c) + dr * 3600 + dc;
                if (key < 0) continue;
                const list = places.get(@intCast(key)) orelse continue;
                for (list.items) |pi| {
                    const p = b.features.items[pi];
                    if (std.mem.indexOfScalar(Settlement, types, p.settlement) == null) continue;
                    const radius: f64 = switch (p.settlement) {
                        .city => max_km,
                        .town => max_km * 0.45,
                        .village => max_km * 0.2,
                        .suburb => max_km,
                        .quarter => max_km * 0.7,
                        else => max_km * 0.5,
                    };
                    const km = ix.distance(lat, lon, p.lat, p.lon) / 1000;
                    if (km > radius) continue;
                    const score = km / radius;
                    if (score < best_score) {
                        best_score = score;
                        best = pi;
                    }
                }
            }
        }
        return best;
    }

    fn write(b: *Builder, source: Source, out: *std.Io.Writer) !Stats {
        const gpa = b.gpa;
        var strings: Strings = .{};
        defer strings.deinit(gpa);
        var h: ix.Header = .{ .source_size = source.size, .source_mtime = source.mtime };

        const features = try gpa.alloc(ix.Feature, b.features.items.len);
        defer gpa.free(features);
        var postings_by_word: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty;
        defer {
            var it = postings_by_word.valueIterator();
            while (it.next()) |l| l.deinit(gpa);
            postings_by_word.deinit(gpa);
        }
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        var seen_words: std.StringHashMapUnmanaged(void) = .empty;
        defer seen_words.deinit(gpa);

        for (b.features.items, features, 0..) |f, *out_f, id| {
            out_f.* = .{
                .name = try strings.add(gpa, f.name),
                .alt = try strings.add(gpa, f.alt),
                .street = try strings.add(gpa, f.street),
                .housenumber = try strings.add(gpa, f.housenumber),
                .area = try strings.ref(gpa, f.area, f.area_f),
                .city = try strings.ref(gpa, f.city, f.city_f),
                .state = try strings.ref(gpa, f.state, f.state_f),
                .lat = ix.fixed(f.lat),
                .lon = ix.fixed(f.lon),
                .kind = f.kind,
                .rank = f.rank,
                .country = f.country,
            };
            h.min_lat = @min(h.min_lat, out_f.lat);
            h.max_lat = @max(h.max_lat, out_f.lat);
            h.min_lon = @min(h.min_lon, out_f.lon);
            h.max_lon = @max(h.max_lon, out_f.lon);

            text.clearRetainingCapacity();
            try norm.normalize(gpa, f.name, &text);
            var alts = ix.altNames(f.alt);
            while (alts.next()) |n| try norm.normalize(gpa, n.value, &text);
            seen_words.clearRetainingCapacity();
            var it = norm.words(text.items);
            while (it.next()) |w| {
                for ([_]?[]const u8{ w, norm.arabicStem(w) }) |maybe| {
                    const word = maybe orelse continue;
                    if (word.len > 60) continue;
                    if ((try seen_words.getOrPut(gpa, word)).found_existing) continue;
                    const gop = try postings_by_word.getOrPut(gpa, word);
                    if (!gop.found_existing) {
                        gop.key_ptr.* = try b.a.dupe(u8, word);
                        gop.value_ptr.* = .empty;
                    }
                    try gop.value_ptr.append(gpa, @intCast(id));
                }
            }
        }

        // Tokens sorted by text; each posting list most important first.
        const words = try gpa.alloc([]const u8, postings_by_word.count());
        defer gpa.free(words);
        {
            var it = postings_by_word.keyIterator();
            var i: usize = 0;
            while (it.next()) |k| : (i += 1) words[i] = k.*;
        }
        std.mem.sort([]const u8, words, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.lt);
        const tokens = try gpa.alloc(ix.Token, words.len);
        defer gpa.free(tokens);
        var postings: std.ArrayList(u32) = .empty;
        defer postings.deinit(gpa);
        for (words, tokens) |w, *t| {
            const list = postings_by_word.getPtr(w).?.items;
            std.mem.sort(u32, list, features, struct {
                fn lt(fs: []ix.Feature, x: u32, y: u32) bool {
                    return fs[x].rank > fs[y].rank;
                }
            }.lt);
            t.* = .{ .text = try strings.add(gpa, w), .first = @intCast(postings.items.len), .count = @intCast(list.len) };
            try postings.appendSlice(gpa, list);
        }

        // Reverse-geocoding grid: every feature's point, and the points along streets.
        var grid: std.ArrayList(ix.Cell) = .empty;
        defer grid.deinit(gpa);
        for (features, 0..) |f, id| {
            if (f.kind == .street) continue;
            try grid.append(gpa, .{ .cell = ix.cellOf(ix.degrees(f.lat), ix.degrees(f.lon)), .feature = @intCast(id), .lat = f.lat, .lon = f.lon });
        }
        for (b.street_points.items) |p| {
            try grid.append(gpa, .{ .cell = ix.cellOf(p.lat, p.lon), .feature = p.feature, .lat = ix.fixed(p.lat), .lon = ix.fixed(p.lon) });
        }
        std.mem.sort(ix.Cell, grid.items, {}, struct {
            fn lt(_: void, x: ix.Cell, y: ix.Cell) bool {
                return x.cell < y.cell;
            }
        }.lt);

        // Layout.
        var offset: u64 = std.mem.alignForward(u64, @sizeOf(ix.Header), 8);
        h.strings = .{ .offset = offset, .count = strings.bytes.items.len };
        offset = std.mem.alignForward(u64, offset + strings.bytes.items.len, 8);
        h.features = .{ .offset = offset, .count = features.len };
        offset = std.mem.alignForward(u64, offset + features.len * @sizeOf(ix.Feature), 8);
        h.tokens = .{ .offset = offset, .count = tokens.len };
        offset = std.mem.alignForward(u64, offset + tokens.len * @sizeOf(ix.Token), 8);
        h.postings = .{ .offset = offset, .count = postings.items.len };
        offset = std.mem.alignForward(u64, offset + postings.items.len * 4, 8);
        h.grid = .{ .offset = offset, .count = grid.items.len };
        const total = offset + grid.items.len * @sizeOf(ix.Cell);

        var pos: u64 = 0;
        try put(out, &pos, std.mem.asBytes(&h), 0);
        try put(out, &pos, strings.bytes.items, h.strings.offset);
        try put(out, &pos, std.mem.sliceAsBytes(features), h.features.offset);
        try put(out, &pos, std.mem.sliceAsBytes(tokens), h.tokens.offset);
        try put(out, &pos, std.mem.sliceAsBytes(postings.items), h.postings.offset);
        try put(out, &pos, std.mem.sliceAsBytes(grid.items), h.grid.offset);
        try out.flush();
        return .{ .features = features.len, .tokens = tokens.len, .grid = grid.items.len, .bytes = @intCast(total) };
    }
};

/// Whether `text` is one of the place's names.
fn sameName(p: Pre, text: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(p.name, text)) return true;
    var it = ix.altNames(p.alt);
    while (it.next()) |e| if (std.ascii.eqlIgnoreCase(e.value, text)) return true;
    return false;
}

fn put(out: *std.Io.Writer, pos: *u64, bytes: []const u8, at: u64) !void {
    while (pos.* < at) : (pos.* += 1) try out.writeByte(0);
    try out.writeAll(bytes);
    pos.* += bytes.len;
}

fn coarseCell(lat: f64, lon: f64) u32 {
    const r: u32 = @intFromFloat(std.math.clamp(@floor((lat + 90) * 10), 0, 1799));
    const c: u32 = @intFromFloat(std.math.clamp(@floor((lon + 180) * 10), 0, 3599));
    return r * 3600 + c;
}

fn adminBandRange(ad: *const Admin, s: [4]f64) [2]usize {
    const lo = @min(s[0], s[2]);
    const hi = @max(s[0], s[2]);
    return .{ @intFromFloat(@floor((lo - ad.min_lat) / band_deg)), @intFromFloat(@floor((hi - ad.min_lat) / band_deg)) };
}

/// Even-odd ray cast towards the east over the boundary's segments in the point's band. The
/// segments need not be joined into rings: the crossings come out the same.
fn adminInside(ad: *const Admin, lat: f64, lon: f64) bool {
    const band: usize = @intFromFloat(@floor((lat - ad.min_lat) / band_deg));
    if (band + 1 >= ad.band_start.len) return false;
    var in = false;
    for (ad.band_segs[ad.band_start[band]..ad.band_start[band + 1]]) |si| {
        const s = ad.segs[si];
        if ((s[0] > lat) == (s[2] > lat)) continue;
        const x = s[1] + (lat - s[0]) / (s[2] - s[0]) * (s[3] - s[1]);
        if (x > lon) in = !in;
    }
    return in;
}


const Strings = struct {
    bytes: std.ArrayList(u8) = .empty,
    map: std.StringHashMapUnmanaged(u32) = .empty,

    fn deinit(s: *Strings, gpa: std.mem.Allocator) void {
        var it = s.map.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        s.bytes.deinit(gpa);
        s.map.deinit(gpa);
    }

    /// `text` when given, else a reference to feature `feature`.
    fn ref(s: *Strings, gpa: std.mem.Allocator, text: []const u8, feature: ?u32) !u32 {
        if (text.len > 0) return s.add(gpa, text);
        return if (feature) |f| f | ix.feature_ref else 0;
    }

    /// Reference to `text` (0 for empty), stored once however often it is used.
    fn add(s: *Strings, gpa: std.mem.Allocator, text_in: []const u8) !u32 {
        if (text_in.len == 0) return 0;
        if (s.bytes.items.len == 0) try s.bytes.append(gpa, 0); // offset 0 means "none"
        const text = text_in[0..utf8Prefix(text_in, 1000)];
        if (s.map.get(text)) |existing| return existing;
        const at: u32 = @intCast(s.bytes.items.len);
        var len: [2]u8 = undefined;
        std.mem.writeInt(u16, &len, @intCast(text.len), .little);
        try s.bytes.appendSlice(gpa, &len);
        try s.bytes.appendSlice(gpa, text);
        // The map keys point into `bytes`, which moves as it grows: keep a stable copy.
        try s.map.put(gpa, try gpa.dupe(u8, text), at);
        return at;
    }
};

/// Length of the longest prefix of `s` that is at most `max` bytes and ends on a character.
fn utf8Prefix(s: []const u8, max: usize) usize {
    if (s.len <= max) return s.len;
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return n;
}

// ---- What becomes a feature ----------------------------------------------------------------

const Info = struct {
    name: []const u8,
    alt: []const u8,
    kind: ix.Kind,
    rank: u8,
    settlement: Settlement = .none,
    street: []const u8 = "",
    housenumber: []const u8 = "",
    area: []const u8 = "",
    city: []const u8 = "",
    state: []const u8 = "",
    country: [2]u8 = .{ 0, 0 },

    fn pre(i: Info, lat: f64, lon: f64) Pre {
        return .{
            .name = i.name,
            .alt = i.alt,
            .street = i.street,
            .housenumber = i.housenumber,
            .area = i.area,
            .city = i.city,
            .state = i.state,
            .country = i.country,
            .lat = lat,
            .lon = lon,
            .kind = i.kind,
            .rank = i.rank,
            .settlement = i.settlement,
        };
    }
};

const street_types = [_][]const u8{
    "motorway",  "trunk",       "primary",       "secondary",    "tertiary", "unclassified", "residential",
    "living_street", "pedestrian", "service", "road", "motorway_link", "trunk_link", "primary_link",
    "secondary_link", "tertiary_link", "track", "footway", "cycleway", "path", "steps",
};

const poi_keys = [_][]const u8{ "amenity", "shop", "tourism", "leisure", "historic", "office", "craft", "healthcare", "aeroway", "railway", "public_transport", "natural", "man_made", "building", "club", "sport", "emergency", "military", "landuse", "waterway", "water" };

const alt_keys = [_][]const u8{ "name:en", "name:ar", "int_name", "alt_name", "old_name", "official_name", "short_name", "loc_name", "name:ms", "name:zh", "name:ta", "name:fr", "name:tr", "name:ku" };

/// Other names as "key=value|key=value": the key is the language for name:xx, else the tag
/// (int_name, alt_name, ...).
fn altNames(a: std.mem.Allocator, t: pbf.Tags, name: []const u8) ![]const u8 {
    var alt: std.ArrayList(u8) = .empty;
    for (alt_keys) |k| if (t.get(k)) |v| if (v.len > 0 and !std.mem.eql(u8, v, name)) {
        if (std.mem.indexOfAny(u8, v, "|=") != null) continue;
        if (alt.items.len > 0) try alt.append(a, '|');
        try alt.print(a, "{s}={s}", .{ if (std.mem.startsWith(u8, k, "name:")) k[5..] else k, v });
    };
    return alt.items;
}

fn eqlAny(v: []const u8, list: []const []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, v, x)) return true;
    return false;
}

/// Whether a node or way is searchable, and as what.
fn extract(a: std.mem.Allocator, t: pbf.Tags, is_way: bool) !?Info {
    const name = t.get("name") orelse t.get("name:en") orelse "";
    var info: Info = .{ .name = "", .alt = "", .kind = .poi, .rank = 10 };
    if (name.len > 0) {
        if (t.get("place")) |place| {
            info.kind = .place;
            const s: Settlement = std.meta.stringToEnum(Settlement, place) orelse .none;
            info.settlement = s;
            info.rank = if (std.mem.eql(u8, place, "country")) 30 else if (eqlAny(place, &.{ "state", "province", "region" })) 27 else switch (s) {
                .city => 25,
                .town => 21,
                .village => 17,
                .suburb => 16,
                .quarter => 15,
                .neighbourhood => 13,
                .hamlet => 12,
                .none => if (std.mem.eql(u8, place, "island")) 14 else 9,
            };
            if (t.get("population")) |pop| if (std.fmt.parseInt(u64, pop, 10)) |p| {
                if (p > 1000) info.rank +|= @intFromFloat(@min(4, std.math.log10(@as(f64, @floatFromInt(p))) - 3));
            } else |_| {};
            if (t.get("capital")) |cap| if (eqlAny(cap, &.{ "yes", "2", "4" })) {
                info.rank +|= 2;
            };
        } else if (is_way and t.get("highway") != null and eqlAny(t.get("highway").?, &street_types)) {
            info.kind = .street;
            const hw = t.get("highway").?;
            info.rank = if (eqlAny(hw, &.{ "motorway", "trunk", "primary" })) 12 else if (std.mem.eql(u8, hw, "secondary")) 11 else if (std.mem.eql(u8, hw, "tertiary")) 10 else if (eqlAny(hw, &.{ "residential", "unclassified", "living_street", "pedestrian" })) 8 else 6;
        } else {
            const has_poi = for (poi_keys) |k| {
                if (t.get(k) != null) break true;
            } else false;
            if (!has_poi) return null;
            // Natural features and land use only when they are places people look for.
            if (t.get("amenity") == null and t.get("shop") == null and t.get("tourism") == null) {
                if (t.get("natural")) |n| if (!eqlAny(n, &.{ "peak", "volcano", "beach", "bay", "cape", "spring", "water", "valley" })) return null;
                if (t.get("landuse")) |l| if (!eqlAny(l, &.{ "retail", "commercial", "industrial", "cemetery", "religious" })) return null;
                if (t.get("waterway")) |w| if (!eqlAny(w, &.{ "river", "dam", "waterfall" })) return null;
            }
            info.kind = .poi;
            info.rank = blk: {
                if (t.get("aeroway")) |v| if (std.mem.eql(u8, v, "aerodrome")) break :blk 20;
                if (t.get("railway")) |v| if (std.mem.eql(u8, v, "station")) break :blk 15;
                if (t.get("amenity")) |v| if (eqlAny(v, &.{ "university", "hospital", "college" })) break :blk 14;
                if (t.get("shop")) |v| if (std.mem.eql(u8, v, "mall")) break :blk 14;
                if (t.get("tourism")) |v| if (eqlAny(v, &.{ "attraction", "museum", "theme_park", "zoo" })) break :blk 13;
                if (t.get("historic") != null) break :blk 12;
                if (t.get("natural")) |v| if (std.mem.eql(u8, v, "peak")) break :blk 12;
                if (t.get("waterway") != null) break :blk 12;
                break :blk 10;
            };
        }
        if (t.get("wikidata") != null) info.rank +|= 2;
        info.rank = @min(info.rank, 31);
        info.name = try a.dupe(u8, name);
        info.alt = try altNames(a, t, name);
    } else {
        // A house number with no name: an address.
        const number = t.get("addr:housenumber") orelse return null;
        const street = t.get("addr:street") orelse t.get("addr:place") orelse return null;
        info.kind = .address;
        info.rank = 5;
        info.name = try std.fmt.allocPrint(a, "{s} {s}", .{ street, number });
        info.alt = "";
    }
    if (info.kind != .street) {
        if (t.get("addr:street")) |s| info.street = try a.dupe(u8, s);
        if (t.get("addr:housenumber")) |n| info.housenumber = try a.dupe(u8, n);
    }
    if (t.get("addr:suburb") orelse t.get("addr:district") orelse t.get("addr:quarter") orelse t.get("addr:neighbourhood")) |s| info.area = try a.dupe(u8, s);
    if (t.get("addr:city")) |s| info.city = try a.dupe(u8, s);
    if (t.get("addr:state") orelse t.get("addr:province")) |s| info.state = try a.dupe(u8, s);
    if (t.get("addr:country")) |c| if (c.len == 2) {
        info.country = .{ std.ascii.toUpper(c[0]), std.ascii.toUpper(c[1]) };
    };
    return info;
}
