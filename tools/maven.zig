//! Resolves Maven artifacts (AARs and JARs) and their transitive dependencies from Google's
//! Maven repository and Maven Central into a local cache, without Gradle. Used by `apk.zig`
//! for `addApp(.android_deps)`.
//!
//! Resolution reads POMs (parents, properties, dependencyManagement and imported BOMs,
//! exclusions); compile and runtime scopes are followed, test/provided/system and optional
//! dependencies are not. When two paths ask for different versions of one artifact the highest
//! wins, as in Gradle. The result for a set of roots is remembered in the cache
//! (`resolved-<hash>.txt`), so later builds neither resolve again nor touch the network.

const std = @import("std");
const Io = std.Io;
const xml = @import("xml.zig");

pub const repositories = [_][]const u8{
    "https://dl.google.com/android/maven2",
    "https://repo1.maven.org/maven2",
};

pub const Artifact = struct {
    group: []const u8,
    name: []const u8,
    version: []const u8,
    /// "aar" or "jar"; "" for a POM-only artifact (no file).
    ext: []const u8,
    /// The downloaded file, when there is one.
    path: []const u8,
};

const Ga = struct { group: []const u8, name: []const u8 };

const Dep = struct {
    group: []const u8,
    name: []const u8,
    version: []const u8,
    scope: []const u8,
    optional: bool,
    exclusions: []const Ga,
};

const Pom = struct {
    group: []const u8,
    name: []const u8,
    version: []const u8,
    packaging: []const u8,
    deps: []const Dep,
};

pub const Resolver = struct {
    arena: std.mem.Allocator,
    io: Io,
    cache: []const u8,
    client: std.http.Client,
    poms: std.StringHashMapUnmanaged(*const Pom) = .empty,
    /// Raw POM models (before inheritance), by "g:a:v".
    raw: std.StringHashMapUnmanaged(*RawPom) = .empty,

    pub fn init(arena: std.mem.Allocator, io: Io, cache: []const u8) Resolver {
        return .{ .arena = arena, .io = io, .cache = cache, .client = .{ .allocator = std.heap.page_allocator, .io = io } };
    }

    pub fn deinit(r: *Resolver) void {
        r.client.deinit();
    }

    /// `roots` are "group:artifact:version". Returns every artifact needed, roots first, in a
    /// stable order (depth-first from the roots).
    pub fn resolve(r: *Resolver, roots: []const []const u8) ![]Artifact {
        const key = blk: {
            var h = std.crypto.hash.sha2.Sha256.init(.{});
            for (roots) |root| {
                h.update(root);
                h.update("\n");
            }
            var d: [32]u8 = undefined;
            h.final(&d);
            break :blk std.fmt.bytesToHex(d[0..8], .lower);
        };
        const list_path = try std.fs.path.join(r.arena, &.{ r.cache, "resolved-" ++ key ++ ".txt" });
        if (try r.readList(list_path)) |list| return list;

        // Versions chosen so far; passes repeat until no version rises.
        var selected: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        for (roots) |root| {
            const c = try parseCoord(root);
            try selected.put(r.arena, try gaKey(r.arena, c.group, c.name), c.version);
        }
        var order: std.ArrayList([]const u8) = .empty;
        var pass: usize = 0;
        while (true) : (pass += 1) {
            if (pass > 20) return error.ResolutionDoesNotSettle;
            order.clearRetainingCapacity();
            var visited: std.StringHashMapUnmanaged(void) = .empty;
            var changed = false;
            for (roots) |root| {
                const c = try parseCoord(root);
                try r.walk(c.group, c.name, &selected, &visited, &order, &.{}, &changed);
            }
            if (!changed) break;
        }

        var out: std.ArrayList(Artifact) = .empty;
        for (order.items) |ga| {
            const colon = std.mem.indexOfScalar(u8, ga, ':').?;
            const group = ga[0..colon];
            const name = ga[colon + 1 ..];
            const version = selected.get(ga).?;
            const pom = try r.effective(group, name, version);
            try out.append(r.arena, try r.download(group, name, version, pom.packaging));
        }
        try r.writeList(list_path, out.items);
        return out.items;
    }

    fn walk(
        r: *Resolver,
        group: []const u8,
        name: []const u8,
        selected: *std.StringArrayHashMapUnmanaged([]const u8),
        visited: *std.StringHashMapUnmanaged(void),
        order: *std.ArrayList([]const u8),
        exclusions: []const Ga,
        changed: *bool,
    ) !void {
        const ga = try gaKey(r.arena, group, name);
        if (visited.contains(ga)) return;
        try visited.put(r.arena, ga, {});
        try order.append(r.arena, ga);
        const pom = try r.effective(group, name, selected.get(ga).?);
        for (pom.deps) |d| {
            if (d.optional) continue;
            if (!(d.scope.len == 0 or eql(d.scope, "compile") or eql(d.scope, "runtime"))) continue;
            if (excluded(exclusions, d.group, d.name)) continue;
            const dga = try gaKey(r.arena, d.group, d.name);
            const v = pickVersion(d.version);
            if (v.len == 0) {
                std.debug.print("maven: no version for {s} (from {s}:{s})\n", .{ dga, group, name });
                return error.MissingVersion;
            }
            if (selected.get(dga)) |have| {
                if (compareVersions(v, have) == .gt) {
                    try selected.put(r.arena, dga, v);
                    changed.* = true;
                }
            } else try selected.put(r.arena, dga, v);
            var ex: std.ArrayList(Ga) = .empty;
            try ex.appendSlice(r.arena, exclusions);
            try ex.appendSlice(r.arena, d.exclusions);
            try r.walk(d.group, d.name, selected, visited, order, ex.items, changed);
        }
    }

    // ---- POMs ----

    const RawPom = struct {
        node: *xml.Node,
        parent: ?struct { group: []const u8, name: []const u8, version: []const u8 },
    };

    fn rawPom(r: *Resolver, group: []const u8, name: []const u8, version: []const u8) !*RawPom {
        const k = try std.fmt.allocPrint(r.arena, "{s}:{s}:{s}", .{ group, name, version });
        if (r.raw.get(k)) |p| return p;
        const path = try r.fetchFile(group, name, version, "pom") orelse {
            std.debug.print("maven: {s} not found\n", .{k});
            return error.ArtifactNotFound;
        };
        const text = try Io.Dir.cwd().readFileAlloc(r.io, path, r.arena, .limited(16 * 1024 * 1024));
        const node = xml.parse(r.arena, text) catch {
            std.debug.print("maven: bad POM {s}\n", .{path});
            return error.BadPom;
        };
        const p = try r.arena.create(RawPom);
        p.* = .{ .node = node, .parent = null };
        if (node.child("parent")) |par| p.parent = .{
            .group = par.childText("groupId") orelse "",
            .name = par.childText("artifactId") orelse "",
            .version = par.childText("version") orelse "",
        };
        try r.raw.put(r.arena, k, p);
        return p;
    }

    const Model = struct {
        props: std.StringHashMapUnmanaged([]const u8) = .empty,
        managed: std.StringHashMapUnmanaged(Dep) = .empty,
        deps: std.ArrayList(Dep) = .empty,
        group: []const u8 = "",
        version: []const u8 = "",
    };

    /// Builds the model of a POM with its parents (parents first; children override).
    fn model(r: *Resolver, group: []const u8, name: []const u8, version: []const u8, depth: usize) !Model {
        if (depth > 16) return error.ParentLoop;
        const raw = try r.rawPom(group, name, version);
        var m: Model = if (raw.parent) |par| try r.model(par.group, par.name, par.version, depth + 1) else .{};
        const n = raw.node;
        m.group = n.childText("groupId") orelse if (raw.parent) |par| par.group else group;
        m.version = n.childText("version") orelse if (raw.parent) |par| par.version else version;
        try m.props.put(r.arena, "project.groupId", m.group);
        try m.props.put(r.arena, "project.version", m.version);
        try m.props.put(r.arena, "pom.version", m.version);
        try m.props.put(r.arena, "version", m.version);
        try m.props.put(r.arena, "project.artifactId", name);
        if (raw.parent) |par| {
            try m.props.put(r.arena, "project.parent.version", par.version);
            try m.props.put(r.arena, "project.parent.groupId", par.group);
        }
        if (n.child("properties")) |props| for (props.children.items) |c| {
            try m.props.put(r.arena, c.name, std.mem.trim(u8, c.text.items, " \t\r\n"));
        };
        if (n.child("dependencyManagement")) |dm| if (dm.child("dependencies")) |ds| for (ds.children.items) |c| {
            const d = try r.dep(&m, c);
            if (eql(d.scope, "import")) {
                // A BOM: its managed versions join ours.
                const bom = try r.model(d.group, d.name, pickVersion(d.version), depth + 1);
                var it = bom.managed.iterator();
                while (it.next()) |e| if (!m.managed.contains(e.key_ptr.*)) try m.managed.put(r.arena, e.key_ptr.*, e.value_ptr.*);
            } else try m.managed.put(r.arena, try gaKey(r.arena, d.group, d.name), d);
        };
        if (n.child("dependencies")) |ds| for (ds.children.items) |c| {
            try m.deps.append(r.arena, try r.dep(&m, c));
        };
        return m;
    }

    fn dep(r: *Resolver, m: *const Model, c: *const xml.Node) !Dep {
        var ex: std.ArrayList(Ga) = .empty;
        if (c.child("exclusions")) |exs| for (exs.children.items) |e| try ex.append(r.arena, .{
            .group = try r.interpolate(m, e.childText("groupId") orelse "*"),
            .name = try r.interpolate(m, e.childText("artifactId") orelse "*"),
        });
        return .{
            .group = try r.interpolate(m, c.childText("groupId") orelse ""),
            .name = try r.interpolate(m, c.childText("artifactId") orelse ""),
            .version = try r.interpolate(m, c.childText("version") orelse ""),
            .scope = try r.interpolate(m, c.childText("scope") orelse ""),
            .optional = eql(c.childText("optional") orelse "", "true"),
            .exclusions = ex.items,
        };
    }

    fn interpolate(r: *Resolver, m: *const Model, s: []const u8) ![]const u8 {
        var cur = s;
        var rounds: usize = 0;
        while (std.mem.indexOf(u8, cur, "${")) |start| : (rounds += 1) {
            if (rounds > 16) break;
            const end = std.mem.indexOfScalarPos(u8, cur, start, '}') orelse break;
            const value = m.props.get(cur[start + 2 .. end]) orelse break;
            cur = try std.mem.concat(r.arena, u8, &.{ cur[0..start], value, cur[end + 1 ..] });
        }
        return cur;
    }

    /// The POM with inheritance applied and managed versions filled in.
    fn effective(r: *Resolver, group: []const u8, name: []const u8, version: []const u8) !*const Pom {
        const k = try std.fmt.allocPrint(r.arena, "{s}:{s}:{s}", .{ group, name, version });
        if (r.poms.get(k)) |p| return p;
        var m = try r.model(group, name, version, 0);
        const raw = try r.rawPom(group, name, version);
        for (m.deps.items) |*d| {
            const managed = m.managed.get(try gaKey(r.arena, d.group, d.name));
            if (d.version.len == 0) if (managed) |md| {
                d.version = md.version;
            };
            if (d.scope.len == 0) if (managed) |md| {
                d.scope = md.scope;
            };
        }
        const p = try r.arena.create(Pom);
        p.* = .{
            .group = group,
            .name = name,
            .version = version,
            .packaging = raw.node.childText("packaging") orelse "jar",
            .deps = m.deps.items,
        };
        try r.poms.put(r.arena, k, p);
        return p;
    }

    // ---- Files ----

    fn download(r: *Resolver, group: []const u8, name: []const u8, version: []const u8, packaging: []const u8) !Artifact {
        const first: []const u8 = if (eql(packaging, "aar")) "aar" else if (eql(packaging, "pom")) "" else "jar";
        if (first.len == 0) return .{ .group = group, .name = name, .version = version, .ext = "", .path = "" };
        const second: []const u8 = if (eql(first, "aar")) "jar" else "aar";
        for ([_][]const u8{ first, second }) |ext| {
            if (try r.fetchFile(group, name, version, ext)) |path|
                return .{ .group = group, .name = name, .version = version, .ext = ext, .path = path };
        }
        // Kotlin multiplatform roots publish their JVM code as "<name>-jvm" or "-android", which
        // the POM already lists as a dependency; the root itself has no file.
        return .{ .group = group, .name = name, .version = version, .ext = "", .path = "" };
    }

    /// The cached file for this artifact and extension, downloaded if needed; null when no
    /// repository has it.
    fn fetchFile(r: *Resolver, group: []const u8, name: []const u8, version: []const u8, ext: []const u8) !?[]const u8 {
        const rel = try std.fmt.allocPrint(r.arena, "{s}/{s}/{s}/{s}-{s}.{s}", .{ try std.mem.replaceOwned(u8, r.arena, group, ".", "/"), name, version, name, version, ext });
        const path = try std.fs.path.join(r.arena, &.{ r.cache, rel });
        const cwd = Io.Dir.cwd();
        if (cwd.access(r.io, path, .{})) |_| return path else |_| {}
        const missing = try std.mem.concat(r.arena, u8, &.{ path, ".missing" });
        if (cwd.access(r.io, missing, .{})) |_| return null else |_| {}

        for (repositories) |repo| {
            const url = try std.fmt.allocPrint(r.arena, "{s}/{s}", .{ repo, rel });
            var body: Io.Writer.Allocating = .init(r.arena);
            const res = r.client.fetch(.{ .location = .{ .url = url }, .response_writer = &body.writer }) catch |e| {
                std.debug.print("maven: {s}: {t}\n", .{ url, e });
                return error.DownloadFailed;
            };
            if (res.status == .not_found or res.status == .forbidden) continue;
            if (res.status != .ok) {
                std.debug.print("maven: {s}: HTTP {d}\n", .{ url, @intFromEnum(res.status) });
                return error.DownloadFailed;
            }
            if (std.fs.path.dirname(path)) |dir| try cwd.createDirPath(r.io, dir);
            const tmp = try std.mem.concat(r.arena, u8, &.{ path, ".part" });
            try cwd.writeFile(r.io, .{ .sub_path = tmp, .data = body.written() });
            try cwd.rename(tmp, cwd, path, r.io);
            return path;
        }
        // Remembered, so the next resolution does not ask again.
        if (std.fs.path.dirname(missing)) |dir| try cwd.createDirPath(r.io, dir);
        try cwd.writeFile(r.io, .{ .sub_path = missing, .data = "" });
        return null;
    }

    fn readList(r: *Resolver, path: []const u8) !?[]Artifact {
        const text = Io.Dir.cwd().readFileAlloc(r.io, path, r.arena, .limited(1024 * 1024)) catch return null;
        var out: std.ArrayList(Artifact) = .empty;
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |line| {
            var parts = std.mem.splitScalar(u8, line, '|');
            const coord = try parseCoord(parts.next() orelse return null);
            const ext = parts.next() orelse return null;
            const file = parts.next() orelse return null;
            if (file.len > 0) Io.Dir.cwd().access(r.io, file, .{}) catch return null;
            try out.append(r.arena, .{ .group = coord.group, .name = coord.name, .version = coord.version, .ext = ext, .path = file });
        }
        return out.items;
    }

    fn writeList(r: *Resolver, path: []const u8, list: []const Artifact) !void {
        var text: std.ArrayList(u8) = .empty;
        for (list) |a| try text.print(r.arena, "{s}:{s}:{s}|{s}|{s}\n", .{ a.group, a.name, a.version, a.ext, a.path });
        try Io.Dir.cwd().createDirPath(r.io, r.cache);
        try Io.Dir.cwd().writeFile(r.io, .{ .sub_path = path, .data = text.items });
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn gaKey(arena: std.mem.Allocator, group: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}:{s}", .{ group, name });
}

fn excluded(list: []const Ga, group: []const u8, name: []const u8) bool {
    for (list) |e| {
        if ((eql(e.group, "*") or eql(e.group, group)) and (eql(e.name, "*") or eql(e.name, name))) return true;
    }
    return false;
}

pub fn parseCoord(s: []const u8) !struct { group: []const u8, name: []const u8, version: []const u8 } {
    var it = std.mem.splitScalar(u8, s, ':');
    const g = it.next() orelse return error.BadCoordinate;
    const a = it.next() orelse return error.BadCoordinate;
    const v = it.next() orelse return error.BadCoordinate;
    if (g.len == 0 or a.len == 0 or v.len == 0 or it.next() != null) return error.BadCoordinate;
    return .{ .group = g, .name = a, .version = v };
}

/// A concrete version from a POM version spec: "1.2", "[1.2]", "[1.2,2.0)" (the lower bound),
/// "(,1.2]" (the upper bound).
pub fn pickVersion(spec: []const u8) []const u8 {
    const s = std.mem.trim(u8, spec, " ");
    if (s.len == 0 or (s[0] != '[' and s[0] != '(')) return s;
    const inner = std.mem.trim(u8, s[1 .. s.len - 1], " ");
    // Several ranges ("[1,2),[3,4)"): the first.
    const first = inner[0 .. std.mem.indexOf(u8, inner, "),") orelse std.mem.indexOf(u8, inner, "],") orelse inner.len];
    const comma = std.mem.indexOfScalar(u8, first, ',') orelse return first;
    const lower = std.mem.trim(u8, first[0..comma], " [(");
    return if (lower.len > 0) lower else std.mem.trim(u8, first[comma + 1 ..], " ])");
}

/// Maven-like ordering: numeric parts compare as numbers; a qualifier ("alpha", "rc1") sorts
/// before the release it precedes.
pub fn compareVersions(a: []const u8, b: []const u8) std.math.Order {
    var ia = std.mem.tokenizeAny(u8, a, ".-");
    var ib = std.mem.tokenizeAny(u8, b, ".-");
    while (true) {
        const pa = ia.next();
        const pb = ib.next();
        if (pa == null and pb == null) return .eq;
        if (pa == null) return if (isNumber(pb.?)) .lt else .gt;
        if (pb == null) return if (isNumber(pa.?)) .gt else .lt;
        const na = isNumber(pa.?);
        const nb = isNumber(pb.?);
        if (na and nb) {
            const x = std.fmt.parseInt(u64, pa.?, 10) catch 0;
            const y = std.fmt.parseInt(u64, pb.?, 10) catch 0;
            if (x != y) return std.math.order(x, y);
        } else if (na != nb) {
            return if (na) .gt else .lt;
        } else {
            const o = std.mem.order(u8, pa.?, pb.?);
            if (o != .eq) return o;
        }
    }
}

fn isNumber(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return s.len > 0;
}

test pickVersion {
    try std.testing.expectEqualStrings("1.2.3", pickVersion("1.2.3"));
    try std.testing.expectEqualStrings("1.2.3", pickVersion("[1.2.3]"));
    try std.testing.expectEqualStrings("1.0", pickVersion("[1.0,2.0)"));
    try std.testing.expectEqualStrings("1.2", pickVersion("(,1.2]"));
}

test compareVersions {
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("1.10", "1.9"));
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("1.0-alpha01", "1.0"));
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("1.0.1", "1.0"));
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("2.1.0", "2.1.0"));
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("1.8.22", "1.9.0"));
}

test excluded {
    const list = [_]Ga{ .{ .group = "a", .name = "*" }, .{ .group = "b", .name = "c" } };
    try std.testing.expect(excluded(&list, "a", "x"));
    try std.testing.expect(excluded(&list, "b", "c"));
    try std.testing.expect(!excluded(&list, "b", "d"));
}
