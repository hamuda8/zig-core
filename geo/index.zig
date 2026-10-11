//! The search index of one region: a single file, memory-mapped, so it costs little RAM however
//! large the region is (the OS keeps the parts in use in its page cache).
//!
//! Layout (little-endian; sections 8-byte aligned):
//!   Header
//!   strings   u16 length + UTF-8 bytes each; offset 0 is "none"
//!   features  [Feature], ids are indexes
//!   tokens    [Token] sorted by their normalized text: the words of feature names
//!   postings  [u32] feature ids, per token from most to least important
//!   grid      [Cell] sorted by cell: points for reverse geocoding (POIs, addresses, street
//!             nodes, places)

const std = @import("std");
const norm = @import("normalize.zig");

/// The format and the builder's version: change it whenever either changes, so every region's
/// index is rebuilt.
pub const magic = "WUFGEO04".*;

/// In area, city and state: the value is a feature id (this bit cleared), not a string.
pub const feature_ref: u32 = 1 << 31;

/// The entries of a feature's other names ("en=Damascus|ar=دمشق|alt_name=...").
pub fn altNames(alt: []const u8) AltIterator {
    return .{ .it = std.mem.tokenizeScalar(u8, alt, '|') };
}

pub const AltIterator = struct {
    it: std.mem.TokenIterator(u8, .scalar),

    pub fn next(a: *AltIterator) ?struct { key: []const u8, value: []const u8 } {
        while (a.it.next()) |e| {
            const eq = std.mem.indexOfScalar(u8, e, '=') orelse continue;
            return .{ .key = e[0..eq], .value = e[eq + 1 ..] };
        }
        return null;
    }
};

pub const Header = extern struct {
    magic: [8]u8 = magic,
    /// The .osm.pbf this was built from: a different size or time means rebuild.
    source_size: u64 = 0,
    source_mtime: i64 = 0,
    /// Bounds of the features, in 1e-7 degrees.
    min_lat: i32 = std.math.maxInt(i32),
    min_lon: i32 = std.math.maxInt(i32),
    max_lat: i32 = std.math.minInt(i32),
    max_lon: i32 = std.math.minInt(i32),
    strings: Section = .{},
    features: Section = .{},
    tokens: Section = .{},
    postings: Section = .{},
    grid: Section = .{},
};

pub const Section = extern struct { offset: u64 = 0, count: u64 = 0 };

pub const Kind = enum(u8) { place = 1, poi = 2, street = 3, address = 4, _ };

pub const Feature = extern struct {
    name: u32,
    /// Other names, "key=value|..." (see altNames): searchable, and shown in their language.
    alt: u32 = 0,
    street: u32 = 0,
    housenumber: u32 = 0,
    area: u32 = 0,
    city: u32 = 0,
    state: u32 = 0,
    lat: i32,
    lon: i32,
    kind: Kind,
    /// Importance, 0-31: countries and cities high, house numbers low.
    rank: u8,
    country: [2]u8 = .{ 0, 0 },
};

pub const Token = extern struct { text: u32, first: u32, count: u32 };

pub const Cell = extern struct { cell: u32, feature: u32, lat: i32, lon: i32 };

/// Grid cells for reverse geocoding: 0.01° (about 1 km).
pub const cell_deg: f64 = 0.01;
const cols: u32 = 36000;

pub fn cellOf(lat: f64, lon: f64) u32 {
    const r: u32 = @intFromFloat(std.math.clamp(@floor((lat + 90) / cell_deg), 0, 17999));
    const c: u32 = @intFromFloat(std.math.clamp(@floor((lon + 180) / cell_deg), 0, cols - 1));
    return r * cols + c;
}

pub fn fixed(deg: f64) i32 {
    return @intFromFloat(@round(deg * 1e7));
}

pub fn degrees(v: i32) f64 {
    return @as(f64, @floatFromInt(v)) * 1e-7;
}

/// Metres between two points (equirectangular; exact enough within a city).
pub fn distance(lat1: f64, lon1: f64, lat2: f64, lon2: f64) f64 {
    const r = 6_371_000.0;
    const x = std.math.degreesToRadians(lon2 - lon1) * @cos(std.math.degreesToRadians((lat1 + lat2) / 2));
    const y = std.math.degreesToRadians(lat2 - lat1);
    return r * @sqrt(x * x + y * y);
}

/// A place in the Maps API's shape.
pub const Place = struct {
    name: []const u8,
    street: ?[]const u8,
    area: ?[]const u8,
    city: ?[]const u8,
    state: ?[]const u8,
    country: ?[]const u8,
    lat: f64,
    lng: f64,
    label: []const u8,
};

pub const Index = struct {
    data: []const u8,
    header: Header,
    features: []align(1) const Feature,
    tokens: []align(1) const Token,
    postings: []align(1) const u32,
    grid: []align(1) const Cell,

    pub fn open(data: []const u8) !Index {
        if (data.len < @sizeOf(Header)) return error.BadIndex;
        const h = std.mem.bytesToValue(Header, data[0..@sizeOf(Header)]);
        if (!std.mem.eql(u8, &h.magic, &magic)) return error.BadIndex;
        return .{
            .data = data,
            .header = h,
            .features = try section(Feature, data, h.features),
            .tokens = try section(Token, data, h.tokens),
            .postings = try section(u32, data, h.postings),
            .grid = try section(Cell, data, h.grid),
        };
    }

    fn section(comptime T: type, data: []const u8, s: Section) ![]align(1) const T {
        const bytes = std.math.mul(u64, s.count, @sizeOf(T)) catch return error.BadIndex;
        if (s.offset > data.len or bytes > data.len - s.offset) return error.BadIndex;
        return std.mem.bytesAsSlice(T, data[@intCast(s.offset)..][0..@intCast(bytes)]);
    }

    pub fn string(ix: *const Index, ref: u32) ?[]const u8 {
        if (ref == 0) return null;
        const strings = ix.header.strings;
        if (ref + 2 > strings.count) return null;
        const at: usize = @intCast(strings.offset + ref);
        const n = std.mem.readInt(u16, ix.data[at..][0..2], .little);
        if (ref + 2 + n > strings.count) return null;
        return ix.data[at + 2 ..][0..n];
    }

    pub fn contains(ix: *const Index, lat: f64, lon: f64) bool {
        const h = ix.header;
        const la = fixed(lat);
        const lo = fixed(lon);
        return la >= h.min_lat and la <= h.max_lat and lo >= h.min_lon and lo <= h.max_lon;
    }

    /// Distance in degrees from the region's bounds to a point (0 inside).
    pub fn boundsDistance(ix: *const Index, lat: f64, lon: f64) f64 {
        const h = ix.header;
        const dy = @max(0, @max(degrees(h.min_lat) - lat, lat - degrees(h.max_lat)));
        const dx = @max(0, @max(degrees(h.min_lon) - lon, lon - degrees(h.max_lon)));
        return @sqrt(dx * dx + dy * dy);
    }

    /// A feature's name in `lang` ("en", "ar", ...) when it has one, else its own name.
    pub fn localName(ix: *const Index, id: u32, lang: ?[]const u8) []const u8 {
        if (id >= ix.features.len) return "";
        const f = ix.features[id];
        if (lang) |l| if (ix.string(f.alt)) |alt| {
            var it = altNames(alt);
            while (it.next()) |e| if (std.mem.eql(u8, e.key, l)) return e.value;
            // An international (Latin) name, for languages written in Latin letters.
            if (!std.mem.eql(u8, l, "ar")) {
                it = altNames(alt);
                while (it.next()) |e| if (std.mem.eql(u8, e.key, "int_name")) return e.value;
            }
        };
        return ix.string(f.name) orelse "";
    }

    /// An area, city or state: text, or a place shown in `lang`.
    pub fn refName(ix: *const Index, ref: u32, lang: ?[]const u8) ?[]const u8 {
        if (ref == 0) return null;
        if (ref & feature_ref != 0) return ix.localName(ref & ~feature_ref, lang);
        return ix.string(ref);
    }

    pub fn place(ix: *const Index, arena: std.mem.Allocator, id: u32, lang: ?[]const u8) !Place {
        const f = ix.features[id];
        const name = ix.localName(id, lang);
        const street_name = ix.string(f.street);
        const number = ix.string(f.housenumber);
        const street: ?[]const u8 = if (street_name) |s| (if (number) |n| try std.fmt.allocPrint(arena, "{s} {s}", .{ s, n }) else s) else null;
        const city = ix.refName(f.city, lang);
        const area = ix.refName(f.area, lang);
        const state = ix.refName(f.state, lang);
        var parts: std.ArrayList([]const u8) = .empty;
        // An address is named "street number": the street alone would repeat it.
        const street_part = if (street_name) |s| (if (std.mem.startsWith(u8, name, s)) null else s) else null;
        for ([_]?[]const u8{ name, street_part, area, city }) |part| {
            const s = part orelse continue;
            if (s.len == 0) continue;
            const dup = for (parts.items) |x| {
                if (std.mem.eql(u8, x, s)) break true;
            } else false;
            if (!dup) try parts.append(arena, s);
        }
        if (parts.items.len <= 1) if (state) |st| if (!std.mem.eql(u8, st, name)) try parts.append(arena, st);
        return .{
            .name = name,
            .street = street,
            .area = area,
            .city = city,
            .state = state,
            .country = if (f.country[0] != 0) try arena.dupe(u8, &f.country) else null,
            .lat = degrees(f.lat),
            .lng = degrees(f.lon),
            .label = try std.mem.join(arena, ", ", parts.items),
        };
    }

    /// A feature's names in every language, normalized, appended to `out`.
    fn searchText(ix: *const Index, arena: std.mem.Allocator, id: u32, out: *std.ArrayList(u8)) !void {
        if (id >= ix.features.len) return;
        const f = ix.features[id];
        try norm.normalize(arena, ix.string(f.name) orelse "", out);
        if (ix.string(f.alt)) |alt| {
            var it = altNames(alt);
            while (it.next()) |e| try norm.normalize(arena, e.value, out);
        }
    }

    /// Index of the first token not less than `text`.
    fn lowerBound(ix: *const Index, text: []const u8) usize {
        var lo: usize = 0;
        var hi: usize = ix.tokens.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (std.mem.order(u8, ix.string(ix.tokens[mid].text) orelse "", text) == .lt) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// Features whose name has a word equal to `word`, or starting with it when `prefix`.
    /// At most `max` ids. Without `near`, the most important; with it, a mix of important and
    /// close, so a common word ("masjid", "starbucks") still finds the ones around the reader.
    pub fn lookup(ix: *const Index, arena: std.mem.Allocator, word: []const u8, prefix: bool, max: usize, near: ?[2]f64) ![]u32 {
        var out: std.ArrayList(u32) = .empty;
        const scan_max: usize = if (near != null) 300_000 else max;
        var i = ix.lowerBound(word);
        // The exact word first, then longer words that start with it.
        var words: usize = 0;
        while (i < ix.tokens.len and out.items.len < scan_max and words < 200) : (i += 1) {
            const t = ix.tokens[i];
            const text = ix.string(t.text) orelse break;
            const exact = std.mem.eql(u8, text, word);
            if (!exact and !(prefix and std.mem.startsWith(u8, text, word))) break;
            if (t.first > ix.postings.len or t.count > ix.postings.len - t.first) break;
            // Without a position, each longer word contributes its most important features only.
            const take = if (exact or near != null) t.count else @min(t.count, 64);
            const ids = ix.postings[t.first..][0..@min(take, scan_max - out.items.len)];
            for (ids) |id| try out.append(arena, id);
            words += 1;
        }
        const p = near orelse return out.items;
        if (out.items.len <= max) return out.items;
        const Scored = struct { id: u32, score: f32 };
        const scored = try arena.alloc(Scored, out.items.len);
        for (out.items, scored) |id, *s| {
            const f = ix.features[id];
            const km = distance(p[0], p[1], degrees(f.lat), degrees(f.lon)) / 1000;
            s.* = .{ .id = id, .score = @floatCast(@as(f64, @floatFromInt(f.rank)) * 1.5 - 12 * std.math.log10(1 + km)) };
        }
        std.mem.sort(Scored, scored, {}, struct {
            fn gt(_: void, a: Scored, b: Scored) bool {
                return a.score > b.score;
            }
        }.gt);
        for (scored[0..max], 0..) |s, k| out.items[k] = s.id;
        return out.items[0..max];
    }

    /// A city, town or larger place named exactly `word` (the most important one).
    fn placeNamed(ix: *const Index, word: []const u8) ?u32 {
        const i = ix.lowerBound(word);
        if (i >= ix.tokens.len) return null;
        const t = ix.tokens[i];
        if (!std.mem.eql(u8, ix.string(t.text) orelse "", word)) return null;
        if (t.first > ix.postings.len or t.count > ix.postings.len - t.first) return null;
        for (ix.postings[t.first..][0..@min(t.count, 32)]) |id| {
            const f = ix.features[id];
            if (f.kind == .place and f.rank >= 17) return id;
        }
        return null;
    }

    /// Sum of posting list sizes for `word`, to pick the most selective query word.
    pub fn frequency(ix: *const Index, word: []const u8, prefix: bool) usize {
        var i = ix.lowerBound(word);
        var n: usize = 0;
        var words: usize = 0;
        while (i < ix.tokens.len and words < 200) : (i += 1) {
            const text = ix.string(ix.tokens[i].text) orelse break;
            const exact = std.mem.eql(u8, text, word);
            if (!exact and !(prefix and std.mem.startsWith(u8, text, word))) break;
            n += if (exact) ix.tokens[i].count else @min(ix.tokens[i].count, 64);
            words += 1;
        }
        return n;
    }

    /// Grid points in `cell`.
    pub fn cellPoints(ix: *const Index, cell: u32) []align(1) const Cell {
        var lo: usize = 0;
        var hi: usize = ix.grid.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (ix.grid[mid].cell < cell) lo = mid + 1 else hi = mid;
        }
        var end = lo;
        while (end < ix.grid.len and ix.grid[end].cell == cell) end += 1;
        return ix.grid[lo..end];
    }
};

// ---- Queries over several regions ----------------------------------------------------------

pub const Hit = struct { index: *const Index, id: u32, score: f64 };

pub const Query = struct {
    words: []const []const u8,
    /// Ranking bias: results near here first.
    near: ?[2]f64 = null,
    /// The language results are shown in.
    lang: ?[]const u8 = null,
};

/// Splits and normalizes query text.
pub fn parseQuery(arena: std.mem.Allocator, text: []const u8, near: ?[2]f64, lang: ?[]const u8) !Query {
    var n: std.ArrayList(u8) = .empty;
    try norm.normalize(arena, text, &n);
    var list: std.ArrayList([]const u8) = .empty;
    var it = norm.words(n.items);
    while (it.next()) |w| if (list.items.len < 8) try list.append(arena, w);
    return .{ .words = list.items, .near = near, .lang = lang };
}

/// Scores the candidates of one region and appends the matches to `hits`.
pub fn searchRegion(ix: *const Index, arena: std.mem.Allocator, q: Query, hits: *std.ArrayList(Hit)) !void {
    if (q.words.len == 0) return;
    // Candidates come from the query word that names the fewest features (any word may instead
    // be part of the address, e.g. the city, so others are checked afterwards).
    var best: ?usize = null;
    var best_n: usize = std.math.maxInt(usize);
    for (q.words, 0..) |w, i| {
        const last = i == q.words.len - 1;
        const n = ix.frequency(lookupWord(w), last);
        if (n > 0 and n < best_n) {
            best = i;
            best_n = n;
        }
    }
    // A city or state among several words ("masjid hasaka", "starbucks kuala lumpur") is
    // where to look when the reader's position is not known.
    var near = q.near;
    if (near == null and q.words.len > 1) for (q.words) |w| if (ix.placeNamed(w)) |pid| {
        near = .{ degrees(ix.features[pid].lat), degrees(ix.features[pid].lon) };
        break;
    };
    var candidates: []u32 = &.{};
    var bi: usize = 0;
    if (best) |i| {
        bi = i;
        candidates = try ix.lookup(arena, lookupWord(q.words[i]), i == q.words.len - 1, 4000, near);
    } else {
        // No word is in the index as typed: a misspelling. Candidates start like the longest
        // word; the one-letter-off match then decides.
        for (q.words, 0..) |w, i| if (w.len > q.words[bi].len) {
            bi = i;
        };
        const w = q.words[bi];
        if (w.len < 5) return;
        candidates = try ix.lookup(arena, w[0..3], true, 4000, near);
    }
    if (norm.arabicStem(q.words[bi])) |stem| {
        const more = try ix.lookup(arena, stem, bi == q.words.len - 1, 1000, near);
        const all = try arena.alloc(u32, candidates.len + more.len);
        @memcpy(all[0..candidates.len], candidates);
        @memcpy(all[candidates.len..], more);
        candidates = all;
    }

    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var name_text: std.ArrayList(u8) = .empty;
    var addr_text: std.ArrayList(u8) = .empty;
    for (candidates) |id| {
        if (id >= ix.features.len) continue;
        if ((try seen.getOrPut(arena, id)).found_existing) continue;
        const f = ix.features[id];
        name_text.clearRetainingCapacity();
        addr_text.clearRetainingCapacity();
        try ix.searchText(arena, id, &name_text);
        for ([_]u32{ f.street, f.housenumber }) |ref| if (ix.string(ref)) |s| try norm.normalize(arena, s, &addr_text);
        // "Starbucks Damascus" and "ستاربكس دمشق" both find a Starbucks in دمشق.
        for ([_]u32{ f.area, f.city, f.state }) |ref| {
            if (ref & feature_ref != 0) try ix.searchText(arena, ref & ~feature_ref, &addr_text) else if (ix.string(ref)) |s| try norm.normalize(arena, s, &addr_text);
        }

        var total: f64 = 0;
        var in_name: usize = 0;
        const ok = for (q.words, 0..) |w, i| {
            const last = i == q.words.len - 1;
            const in_n = wordMatch(name_text.items, w, last);
            const s = if (in_n > 0) in_n else 0.6 * wordMatch(addr_text.items, w, last);
            if (s == 0) break false;
            if (in_n > 0) in_name += 1;
            total += s;
        } else true;
        if (!ok or in_name == 0) continue;

        var score = total / @as(f64, @floatFromInt(q.words.len)) * 100 + @as(f64, @floatFromInt(f.rank)) * 1.5;
        // The whole name typed: "Damascus" beats "Damascus Gate Hotel".
        if (in_name == q.words.len and wordCount(name_text.items) == q.words.len) score += 12;
        if (q.near) |p| {
            const km = distance(p[0], p[1], degrees(f.lat), degrees(f.lon)) / 1000;
            score -= 12 * std.math.log10(1 + km);
        }
        try hits.append(arena, .{ .index = ix, .id = id, .score = score });
    }
}

/// Index words are stored as normalized text; query words are too.
fn lookupWord(w: []const u8) []const u8 {
    return w;
}

fn wordCount(text: []const u8) usize {
    var n: usize = 0;
    var it = norm.words(text);
    while (it.next()) |_| n += 1;
    return n;
}

/// 1 for a whole word, 0.8 for a word starting with `w` (the word being typed, or 3+ letters),
/// 0.9 for the Arabic article left off ("ميدان" for "الميدان"), 0.65 for one letter off in a
/// longer word ("hasakah" for "hasaka": names are spelled many ways in Latin letters), else 0.
fn wordMatch(text: []const u8, w: []const u8, typing: bool) f64 {
    var best: f64 = 0;
    var it = norm.words(text);
    while (it.next()) |t| {
        if (std.mem.eql(u8, t, w)) return 1;
        if (w.len >= 5 and t.len >= 5 and oneEditApart(t, w)) best = @max(best, 0.65);
        if (norm.arabicStem(t)) |stem| {
            if (std.mem.eql(u8, stem, w)) best = @max(best, 0.9);
            if ((typing or w.len >= 6) and std.mem.startsWith(u8, stem, w)) best = @max(best, 0.75);
        }
        if ((typing or w.len >= 3) and std.mem.startsWith(u8, t, w)) best = @max(best, 0.8);
    }
    return best;
}

/// Whether one insertion, deletion, substitution or swap of neighbours turns `a` into `b`
/// (bytes: enough for Latin spellings; Arabic letters are two bytes and rarely need it).
fn oneEditApart(a: []const u8, b: []const u8) bool {
    if (a.len > b.len) return oneEditApart(b, a);
    if (b.len - a.len > 1) return false;
    var i: usize = 0;
    while (i < a.len and a[i] == b[i]) i += 1;
    if (i == a.len) return true; // b is a with one more letter at the end
    if (a.len == b.len) {
        // Substitution, or two neighbours swapped.
        if (std.mem.eql(u8, a[i + 1 ..], b[i + 1 ..])) return true;
        return i + 1 < a.len and a[i] == b[i + 1] and a[i + 1] == b[i] and std.mem.eql(u8, a[i + 2 ..], b[i + 2 ..]);
    }
    return std.mem.eql(u8, a[i..], b[i + 1 ..]); // one letter inserted in b
}

test oneEditApart {
    try std.testing.expect(oneEditApart("hasaka", "hasakah"));
    try std.testing.expect(oneEditApart("hasakah", "hasaka"));
    try std.testing.expect(oneEditApart("damascus", "damaskus"));
    try std.testing.expect(oneEditApart("damascus", "dmaascus"));
    try std.testing.expect(oneEditApart("damascus", "damscus"));
    try std.testing.expect(!oneEditApart("damascus", "damsacs"));
    try std.testing.expect(!oneEditApart("aleppo", "halab"));
}

/// Orders hits best first and removes repeats: the same label, or the same name within 2 km
/// (a long street is several features).
pub fn finish(arena: std.mem.Allocator, hits: []Hit, limit: usize, lang: ?[]const u8) ![]Place {
    std.mem.sort(Hit, hits, {}, struct {
        fn lt(_: void, a: Hit, b: Hit) bool {
            return a.score > b.score;
        }
    }.lt);
    var out: std.ArrayList(Place) = .empty;
    for (hits) |h| {
        if (out.items.len >= limit) break;
        const p = try h.index.place(arena, h.id, lang);
        const dup = for (out.items) |o| {
            if (std.mem.eql(u8, o.label, p.label)) break true;
            if (std.mem.eql(u8, o.name, p.name) and distance(o.lat, o.lng, p.lat, p.lng) < 2000) break true;
        } else false;
        if (!dup) try out.append(arena, p);
    }
    return out.items;
}

/// The nearest named thing to a point in one region, or null when nothing is within ~1 km.
/// Points of interest and addresses win over a street a little nearer; places only when
/// nothing else is near.
pub fn reverseRegion(ix: *const Index, lat: f64, lon: f64) ?struct { id: u32, cost: f64 } {
    const center = cellOf(lat, lon);
    var best: ?u32 = null;
    var best_cost: f64 = std.math.inf(f64);
    var dr: i64 = -1;
    while (dr <= 1) : (dr += 1) {
        var dc: i64 = -1;
        while (dc <= 1) : (dc += 1) {
            const cell_i = @as(i64, center) + dr * cols + dc;
            if (cell_i < 0) continue;
            for (ix.cellPoints(@intCast(cell_i))) |p| {
                if (p.feature >= ix.features.len) continue;
                const d = distance(lat, lon, degrees(p.lat), degrees(p.lon));
                const cost = switch (ix.features[p.feature].kind) {
                    .poi, .address => d,
                    .street => d * 1.5 + 15,
                    else => d * 3 + 100,
                };
                if (cost < best_cost) {
                    best_cost = cost;
                    best = p.feature;
                }
            }
        }
    }
    if (best_cost > 1500) return null;
    return .{ .id = best orelse return null, .cost = best_cost };
}
