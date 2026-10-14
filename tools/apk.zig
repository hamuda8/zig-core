//! Builds a signed APK from a manifest, the fixed Java shim and the app's Zig `.so` files,
//! using the Android SDK build-tools only to compile resources and the manifest (aapt2), dex
//! (d8) and sign (apksigner). The archive itself is written by `zip.zig`.
//!
//! apk --sdk DIR --build-tools VER --platform android-NN --min-sdk N --jdk DIR
//!     --manifest FILE --java DIR [--java DIR ...] --lib ABI=FILE [--lib ABI=FILE ...]
//!     [--res DIR ...] [--dep GROUP:ARTIFACT:VERSION ... --maven-cache DIR]
//!     [--firebase google-services.json] --keystore FILE --out FILE
//!
//! Maven dependencies (`--dep`, from `addApp(.android_deps)`) are resolved with their
//! transitive dependencies by `maven.zig` into the cache. Then, without Gradle:
//!   - each AAR is unpacked once into the cache (`<file>.x-<build-tools>/`) and its res/
//!     compiled there with aapt2;
//!   - the libraries' resources are linked under the app's (the app wins), with an R class for
//!     each library package (`--extra-packages`) compiled with the shim;
//!   - the libraries' manifests are merged into the app's: permissions, components and
//!     `<queries>`, same-named components merged (Firebase's ComponentDiscoveryService gathers
//!     the registrars of every library this way), `${applicationId}` replaced, `tools:`
//!     attributes dropped;
//!   - classes.jar and libs/*.jar of every library are dexed with the shim; a class that two
//!     jars define is kept from the first (there is no ProGuard/R8 step); their Java resources
//!     (META-INF/services, ...) go into the APK; their jni/<abi>/*.so for the ABIs built too.
//!
//! `--firebase` reads the app's google-services.json (kept outside the repository) and puts
//! the values ZuiPush needs (`zui.fcm.*` meta-data) into the merged manifest. Values are never
//! printed.
//!
//! `--wufour-apps com.a,com.b` (zui/wufour_apps.zig) adds the shared Wufour sign-in: the
//! signature permission com.wufour.permission.SHARED_AUTH (declared and used), the exported
//! ZuiAuthProvider at `<package>.wufourauth` behind it, and `<queries>` for the other apps.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const zip = @import("zip.zig");
const xml = @import("xml.zig");
const maven = @import("maven.zig");

const exe_ext = if (builtin.os.tag == .windows) ".exe" else "";
const bat_ext = if (builtin.os.tag == .windows) ".bat" else "";
const path_sep = if (builtin.os.tag == .windows) ";" else ":";

const Lib = struct { abi: []const u8, path: []const u8 };

const Options = struct {
    sdk: []const u8 = "",
    build_tools: []const u8 = "",
    platform: []const u8 = "",
    min_sdk: []const u8 = "",
    jdk: []const u8 = "",
    manifest: []const u8 = "",
    java: std.ArrayList([]const u8) = .empty,
    keystore: []const u8 = "",
    out: []const u8 = "",
    libs: std.ArrayList(Lib) = .empty,
    /// Android resource folders (res/), compiled and linked in order.
    res: std.ArrayList([]const u8) = .empty,
    deps: std.ArrayList([]const u8) = .empty,
    maven_cache: []const u8 = "",
    firebase: []const u8 = "",
    /// Our apps sharing one Wufour sign-in, comma-separated (empty: none).
    wufour_apps: []const u8 = "",
};

/// An unpacked AAR or a plain JAR.
const Library = struct {
    name: []const u8,
    /// classes.jar and libs/*.jar (or the JAR itself).
    jars: std.ArrayList([]const u8) = .empty,
    manifest: ?[]const u8 = null,
    /// The AAR's compiled resources (aapt2 compile), if it has any.
    res_flat: ?[]const u8 = null,
    package: []const u8 = "",
    /// The unpacked folder (jni/, assets/).
    dir: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const opts = try parseArgs(arena, try init.minimal.args.toSlice(arena));

    // Child processes (the .bat wrappers in particular) need the JDK.
    try init.environ_map.put("JAVA_HOME", opts.jdk);
    const path_var = init.environ_map.get("PATH") orelse "";
    try init.environ_map.put("PATH", try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ try join(arena, &.{ opts.jdk, "bin" }), path_sep, path_var }));
    const env = init.environ_map;

    const bt = try join(arena, &.{ opts.sdk, "build-tools", opts.build_tools });
    const android_jar = try join(arena, &.{ opts.sdk, "platforms", opts.platform, "android.jar" });
    const aapt2 = try tool(arena, bt, "aapt2", exe_ext);

    const cwd = Io.Dir.cwd();
    // Absolute, because `aapt add` below runs from inside the staging folder.
    const work_rel = try join(arena, &.{ std.fs.path.dirname(opts.out) orelse ".", "apk-work" });
    cwd.deleteTree(io, work_rel) catch {};
    try cwd.createDirPath(io, work_rel);
    const work = try cwd.realPathFileAlloc(io, work_rel, arena);
    const stage = try join(arena, &.{ work, "stage" });
    const classes = try join(arena, &.{ work, "classes" });
    const gen = try join(arena, &.{ work, "gen" });
    try cwd.createDirPath(io, stage);
    try cwd.createDirPath(io, classes);
    try cwd.createDirPath(io, gen);

    // 0. Maven dependencies: resolved, downloaded and unpacked into the cache.
    var libraries: std.ArrayList(Library) = .empty;
    if (opts.deps.items.len > 0) {
        if (opts.maven_cache.len == 0) return error.MissingMavenCache;
        var resolver = maven.Resolver.init(arena, io, opts.maven_cache);
        defer resolver.deinit();
        const artifacts = try resolver.resolve(opts.deps.items);
        for (artifacts) |a| {
            if (a.path.len == 0) continue;
            const name = try std.fmt.allocPrint(arena, "{s}:{s}:{s}", .{ a.group, a.name, a.version });
            if (std.mem.eql(u8, a.ext, "jar")) {
                var l: Library = .{ .name = name };
                try l.jars.append(arena, a.path);
                try libraries.append(arena, l);
            } else {
                try libraries.append(arena, try unpackAar(arena, io, env, aapt2, opts.build_tools, name, a.path));
            }
        }
    }

    // 1. The manifest: the app's, with the libraries' merged in and the Firebase values.
    var manifest = opts.manifest;
    if (libraries.items.len > 0 or opts.firebase.len > 0 or opts.wufour_apps.len > 0) {
        manifest = try join(arena, &.{ work, "AndroidManifest.xml" });
        try cwd.writeFile(io, .{ .sub_path = manifest, .data = try mergeManifests(arena, io, opts, libraries.items) });
    }

    // 2. Resources (the libraries', zui's widget layouts, the app's icon...) and the manifest
    //    -> base.apk, plus the libraries' R classes.
    const base_apk = try join(arena, &.{ work, "base.apk" });
    var link: std.ArrayList([]const u8) = .empty;
    try link.appendSlice(arena, &.{ aapt2, "link", "-o", base_apk, "--manifest", manifest, "-I", android_jar, "--auto-add-overlay" });
    // Deeper dependencies first, so the libraries that use them (and then the app) override.
    var packages: std.ArrayList(u8) = .empty;
    var i_lib = libraries.items.len;
    while (i_lib > 0) {
        i_lib -= 1;
        const l = libraries.items[i_lib];
        const flat = l.res_flat orelse continue;
        try link.appendSlice(arena, &.{ "-R", flat });
        if (l.package.len > 0 and !listed(packages.items, l.package)) {
            if (packages.items.len > 0) try packages.append(arena, ':');
            try packages.appendSlice(arena, l.package);
        }
    }
    for (opts.res.items, 0..) |dir, i| {
        const flat = try join(arena, &.{ work, try std.fmt.allocPrint(arena, "res-{d}.zip", .{i}) });
        try run(arena, io, env, null, &.{ aapt2, "compile", "--dir", dir, "-o", flat });
        try link.appendSlice(arena, &.{ "-R", flat });
    }
    if (packages.items.len > 0) try link.appendSlice(arena, &.{ "--java", gen, "--extra-packages", packages.items });
    try run(arena, io, env, null, link.items);

    // 3. Java shim (and R classes) -> .class -> classes*.dex with the libraries' jars.
    //    Arguments go in files: on the command line they pass Windows's 8191-character limit
    //    as soon as the shim grows, the build directory is deep, or libraries come in.
    var lib_jars: std.ArrayList([]const u8) = .empty;
    for (libraries.items) |l| try lib_jars.appendSlice(arena, l.jars.items);
    {
        var args: std.ArrayList(u8) = .empty;
        try args.print(arena, "--release 17 -nowarn -encoding UTF-8 -d \"{s}\"\n-classpath \"{s}", .{ slashes(arena, classes), slashes(arena, android_jar) });
        for (lib_jars.items) |j| try args.print(arena, "{s}{s}", .{ path_sep, slashes(arena, j) });
        try args.appendSlice(arena, "\"\n");
        var sources: std.ArrayList([]const u8) = .empty;
        for (opts.java.items) |dir| try collect(arena, io, dir, ".java", &sources);
        try collect(arena, io, gen, ".java", &sources);
        for (sources.items) |s| try args.print(arena, "\"{s}\"\n", .{slashes(arena, s)});
        const arg_file = try join(arena, &.{ work, "javac-args.txt" });
        try cwd.writeFile(io, .{ .sub_path = arg_file, .data = args.items });
        try run(arena, io, env, null, &.{ try join(arena, &.{ opts.jdk, "bin", "javac" ++ exe_ext }), try std.fmt.allocPrint(arena, "@{s}", .{arg_file}) });
    }

    // A class that two jars define is kept from the first; the libraries' Java resources are
    // gathered for the APK.
    var java_resources: std.ArrayList(zip.Entry) = .empty;
    var dex_inputs: std.ArrayList([]const u8) = .empty;
    {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var class_files: std.ArrayList([]const u8) = .empty;
        try collect(arena, io, classes, ".class", &class_files);
        for (class_files.items) |f| {
            try dex_inputs.append(arena, f);
            try seen.put(arena, try std.mem.replaceOwned(u8, arena, f[classes.len + 1 ..], "\\", "/"), {});
        }
        var resource_names: std.StringHashMapUnmanaged(void) = .empty;
        for (lib_jars.items, 0..) |jar, n| {
            const bytes = try cwd.readFileAlloc(io, jar, arena, .limited(256 * 1024 * 1024));
            const entries = try zip.read(arena, bytes);
            var keep: std.ArrayList(zip.Entry) = .empty;
            var dropped: usize = 0;
            for (entries) |e| {
                if (std.mem.endsWith(u8, e.name, "/")) continue;
                if (isClass(e.name)) {
                    if (seen.contains(e.name)) {
                        dropped += 1;
                        continue;
                    }
                    try seen.put(arena, e.name, {});
                    try keep.append(arena, e);
                } else if (!std.mem.endsWith(u8, e.name, ".class") and isJavaResource(e.name) and !resource_names.contains(e.name)) {
                    try resource_names.put(arena, e.name, {});
                    try java_resources.append(arena, e);
                }
            }
            if (keep.items.len == 0) continue;
            if (dropped == 0 and keep.items.len == countClasses(entries)) {
                try dex_inputs.append(arena, jar);
            } else {
                // Only the classes d8 should see, in a jar of our own.
                const filtered = try join(arena, &.{ work, try std.fmt.allocPrint(arena, "jar-{d}.jar", .{n}) });
                try cwd.writeFile(io, .{ .sub_path = filtered, .data = try zip.write(arena, keep.items) });
                try dex_inputs.append(arena, filtered);
            }
        }
    }
    {
        var arg_text: std.ArrayList(u8) = .empty;
        for (dex_inputs.items) |f| try arg_text.print(arena, "{s}\n", .{f});
        const arg_file = try join(arena, &.{ work, "d8-inputs.txt" });
        try cwd.writeFile(io, .{ .sub_path = arg_file, .data = arg_text.items });
        try run(arena, io, env, null, &.{
            try tool(arena, bt, "d8", bat_ext), "--release", "--min-api", opts.min_sdk, "--lib", android_jar, "--output", stage,
            try std.fmt.allocPrint(arena, "@{s}", .{arg_file}),
        });
    }

    // 4. Assemble: aapt2's entries as they are, then classes*.dex and the native libraries,
    //    stored uncompressed (extractNativeLibs=false) with each .so on a 16 KB page boundary,
    //    which Android 15+ devices require.
    const max_file = std.Io.Limit.limited(256 * 1024 * 1024);
    var entries: std.ArrayList(zip.Entry) = .empty;
    try entries.appendSlice(arena, try zip.read(arena, try cwd.readFileAlloc(io, base_apk, arena, max_file)));
    {
        var n: usize = 1;
        while (true) : (n += 1) {
            const name = if (n == 1) "classes.dex" else try std.fmt.allocPrint(arena, "classes{d}.dex", .{n});
            const dex = cwd.readFileAlloc(io, try join(arena, &.{ stage, name }), arena, max_file) catch |e| switch (e) {
                error.FileNotFound => break,
                else => return e,
            };
            try entries.append(arena, zip.stored(name, dex, 4));
        }
    }
    for (opts.libs.items) |lib| {
        const so = try cwd.readFileAlloc(io, lib.path, arena, max_file);
        try entries.append(arena, zip.stored(try std.fmt.allocPrint(arena, "lib/{s}/libapp.so", .{lib.abi}), so, 16 * 1024));
    }
    for (libraries.items) |l| {
        const dir = l.dir orelse continue;
        for (opts.libs.items) |lib| {
            var sos: std.ArrayList([]const u8) = .empty;
            collect(arena, io, try join(arena, &.{ dir, "jni", lib.abi }), ".so", &sos) catch continue;
            for (sos.items) |f| {
                const name = try std.fmt.allocPrint(arena, "lib/{s}/{s}", .{ lib.abi, std.fs.path.basename(f) });
                if (hasEntry(entries.items, name)) continue;
                try entries.append(arena, zip.stored(name, try cwd.readFileAlloc(io, f, arena, max_file), 16 * 1024));
            }
        }
        var assets: std.ArrayList([]const u8) = .empty;
        const assets_dir = try join(arena, &.{ dir, "assets" });
        collect(arena, io, assets_dir, "", &assets) catch {};
        for (assets.items) |f| {
            const name = try std.mem.replaceOwned(u8, arena, try std.fmt.allocPrint(arena, "assets/{s}", .{f[assets_dir.len + 1 ..]}), "\\", "/");
            if (hasEntry(entries.items, name)) continue;
            try entries.append(arena, zip.stored(name, try cwd.readFileAlloc(io, f, arena, max_file), 4));
        }
    }
    for (java_resources.items) |e| {
        if (hasEntry(entries.items, e.name)) continue;
        var copy = e;
        copy.alignment = 4;
        try entries.append(arena, copy);
    }
    const aligned = try join(arena, &.{ work, "aligned.apk" });
    try cwd.writeFile(io, .{ .sub_path = aligned, .data = try zip.write(arena, entries.items) });

    // 5. Sign.
    cwd.access(io, opts.keystore, .{}) catch {
        if (std.fs.path.dirname(opts.keystore)) |dir| try cwd.createDirPath(io, dir);
        try run(arena, io, env, null, &.{
            try join(arena, &.{ opts.jdk, "bin", "keytool" ++ exe_ext }), "-genkeypair",                     "-keystore", opts.keystore,
            "-storepass",                                                 "android",                         "-keypass",  "android",
            "-alias",                                                     "androiddebugkey",                 "-keyalg",   "RSA",
            "-keysize",                                                   "2048",                            "-validity", "10000",
            "-dname",                                                     "CN=Android Debug,O=Android,C=US",
        });
    };
    try run(arena, io, env, null, &.{
        try tool(arena, bt, "apksigner", bat_ext), "sign",         "--ks",       opts.keystore,
        "--ks-pass",                               "pass:android", "--key-pass", "pass:android",
        "--out",                                   opts.out,       aligned,
    });
}

fn tool(a: std.mem.Allocator, dir: []const u8, name: []const u8, ext: []const u8) ![]const u8 {
    return join(a, &.{ dir, try std.mem.concat(a, u8, &.{ name, ext }) });
}

fn listed(list: []const u8, item: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ':');
    while (it.next()) |p| if (std.mem.eql(u8, p, item)) return true;
    return false;
}

fn hasEntry(entries: []const zip.Entry, name: []const u8) bool {
    for (entries) |e| if (std.mem.eql(u8, e.name, name)) return true;
    return false;
}

/// A class d8 should dex (not a multi-release or module descriptor).
fn isClass(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".class") and !std.mem.endsWith(u8, name, "module-info.class") and !std.mem.startsWith(u8, name, "META-INF/");
}

fn countClasses(entries: []const zip.Entry) usize {
    var n: usize = 0;
    for (entries) |e| {
        if (isClass(e.name)) n += 1;
    }
    return n;
}

/// A file from a jar that belongs in the APK as a Java resource (what Gradle packages too),
/// minus the jar's own bookkeeping and Kotlin's compile-time metadata.
fn isJavaResource(name: []const u8) bool {
    const skip_prefix = [_][]const u8{ "META-INF/MANIFEST.MF", "META-INF/versions/", "META-INF/maven/", "META-INF/proguard/", "META-INF/com.android.tools/", "AndroidManifest.xml", "res/", "resources.arsc", "lib/", "assets/" };
    for (skip_prefix) |p| if (std.mem.startsWith(u8, name, p)) return false;
    // Kotlin multiplatform metadata (commonMain/default/linkdata/...): compile-time only.
    if (std.mem.indexOf(u8, name, "/default/linkdata/") != null or std.mem.endsWith(u8, name, "/default/manifest") or std.mem.endsWith(u8, name, ".knm") or std.mem.eql(u8, name, "META-INF/kotlin-project-structure-metadata.json")) return false;
    const skip_suffix = [_][]const u8{ ".SF", ".RSA", ".DSA", ".EC", ".kotlin_metadata", ".kotlin_builtins", ".java", ".proto", "LICENSE", "LICENSE.txt", "NOTICE", "NOTICE.txt", ".dex" };
    for (skip_suffix) |s| if (std.mem.endsWith(u8, name, s)) return false;
    return true;
}

/// Path with forward slashes, for javac's argument file (where a backslash escapes).
fn slashes(arena: std.mem.Allocator, p: []const u8) []const u8 {
    return std.mem.replaceOwned(u8, arena, p, "\\", "/") catch p;
}

/// Unpacks an AAR next to it in the cache (once per build-tools version) and compiles its
/// resources.
fn unpackAar(arena: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, aapt2: []const u8, build_tools: []const u8, name: []const u8, aar: []const u8) !Library {
    const cwd = Io.Dir.cwd();
    const dir = try std.fmt.allocPrint(arena, "{s}.x-{s}", .{ aar, build_tools });
    const done = try join(arena, &.{ dir, ".done" });
    const flat = try join(arena, &.{ dir, "res.zip" });
    if (cwd.access(io, done, .{})) |_| {} else |_| {
        cwd.deleteTree(io, dir) catch {};
        try cwd.createDirPath(io, dir);
        const bytes = try cwd.readFileAlloc(io, aar, arena, .limited(256 * 1024 * 1024));
        var has_res = false;
        for (try zip.read(arena, bytes)) |e| {
            if (std.mem.endsWith(u8, e.name, "/")) continue;
            const wanted = std.mem.eql(u8, e.name, "classes.jar") or std.mem.eql(u8, e.name, "AndroidManifest.xml") or
                std.mem.startsWith(u8, e.name, "res/") or std.mem.startsWith(u8, e.name, "libs/") or
                std.mem.startsWith(u8, e.name, "jni/") or std.mem.startsWith(u8, e.name, "assets/");
            if (!wanted) continue;
            if (std.mem.indexOf(u8, e.name, "..") != null or std.fs.path.isAbsolute(e.name)) return error.BadAarEntry;
            if (std.mem.startsWith(u8, e.name, "res/")) has_res = true;
            const out = try join(arena, &.{ dir, e.name });
            if (std.fs.path.dirname(out)) |d| try cwd.createDirPath(io, d);
            try cwd.writeFile(io, .{ .sub_path = out, .data = try zip.inflate(arena, e) });
        }
        if (has_res) try run(arena, io, env, null, &.{ aapt2, "compile", "--dir", try join(arena, &.{ dir, "res" }), "-o", flat });
        try cwd.writeFile(io, .{ .sub_path = done, .data = "" });
    }

    var l: Library = .{ .name = name, .dir = dir };
    const classes_jar = try join(arena, &.{ dir, "classes.jar" });
    if (cwd.access(io, classes_jar, .{})) |_| try l.jars.append(arena, classes_jar) else |_| {}
    collect(arena, io, try join(arena, &.{ dir, "libs" }), ".jar", &l.jars) catch {};
    if (cwd.access(io, flat, .{})) |_| {
        l.res_flat = flat;
    } else |_| {}
    const manifest = try join(arena, &.{ dir, "AndroidManifest.xml" });
    if (cwd.access(io, manifest, .{})) |_| {
        l.manifest = manifest;
        const root = try xml.parse(arena, try cwd.readFileAlloc(io, manifest, arena, .limited(4 * 1024 * 1024)));
        l.package = root.attr("package") orelse "";
    } else |_| {}
    return l;
}

// ---- Manifest merging ----

fn mergeManifests(arena: std.mem.Allocator, io: Io, opts: Options, libraries: []const Library) ![]u8 {
    const cwd = Io.Dir.cwd();
    const app = try xml.parse(arena, try cwd.readFileAlloc(io, opts.manifest, arena, .limited(4 * 1024 * 1024)));
    const package = app.attr("package") orelse return error.ManifestWithoutPackage;
    const application = app.child("application") orelse blk: {
        const a = try arena.create(xml.Node);
        a.* = .{ .name = "application" };
        try app.children.append(arena, a);
        break :blk a;
    };

    for (libraries) |l| {
        const path = l.manifest orelse continue;
        const lib = try xml.parse(arena, try cwd.readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)));
        try prepare(arena, lib, package);
        try mergeLibrary(arena, app, application, lib);
    }

    if (opts.firebase.len > 0) {
        const values = try firebaseValues(arena, io, opts.firebase, package);
        for ([_][2][]const u8{
            .{ "zui.fcm.project_id", values.project_id },
            .{ "zui.fcm.app_id", values.app_id },
            .{ "zui.fcm.api_key", values.api_key },
            .{ "zui.fcm.sender_id", values.sender_id },
        }) |kv| {
            const m = try arena.create(xml.Node);
            // "zui:" keeps the value a string: aapt2 would store a number (the sender id) as one.
            m.* = .{ .name = "meta-data" };
            try m.attrs.append(arena, .{ .name = "android:name", .value = kv[0] });
            try m.attrs.append(arena, .{ .name = "android:value", .value = try std.mem.concat(arena, u8, &.{ "zui:", kv[1] }) });
            try mergeInto(arena, application, m);
        }
    }

    if (opts.wufour_apps.len > 0) try addSharedAuth(arena, app, application, package, opts.wufour_apps);

    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");
    try xml.write(&out.writer, app, 0);
    return out.written();
}

fn mergeLibrary(arena: std.mem.Allocator, app: *xml.Node, application: *xml.Node, lib: *const xml.Node) !void {
    const top_level = [_][]const u8{ "uses-permission", "uses-permission-sdk-23", "permission", "permission-group", "permission-tree", "uses-feature", "queries" };
    for (lib.children.items) |c| {
        if (removed(c)) continue;
        if (eql(c.name, "application")) {
            for (c.children.items) |comp| if (!removed(comp)) try mergeInto(arena, application, comp);
        } else for (top_level) |t| {
            if (eql(c.name, t)) try mergeBefore(arena, app, application, c);
        }
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn removed(n: *const xml.Node) bool {
    const node = n.attr("tools:node") orelse return false;
    return eql(node, "remove") or eql(node, "removeAll");
}

/// Drops `tools:` attributes and the tools namespace, and fills in `${applicationId}`.
fn prepare(arena: std.mem.Allocator, n: *xml.Node, package: []const u8) !void {
    var i: usize = 0;
    while (i < n.attrs.items.len) {
        const a = &n.attrs.items[i];
        if ((std.mem.startsWith(u8, a.name, "tools:") and !eql(a.name, "tools:node")) or eql(a.name, "xmlns:tools")) {
            _ = n.attrs.orderedRemove(i);
            continue;
        }
        a.value = try std.mem.replaceOwned(u8, arena, a.value, "${applicationId}", package);
        i += 1;
    }
    for (n.children.items) |c| try prepare(arena, c, package);
}

/// Same element: the same tag and android:name (or, without a name, the same content).
fn same(arena: std.mem.Allocator, a: *const xml.Node, b: *const xml.Node) !bool {
    if (!eql(a.name, b.name)) return false;
    const an = a.attr("android:name");
    const bn = b.attr("android:name");
    if (an != null or bn != null) return an != null and bn != null and eql(an.?, bn.?);
    return eql(try serialize(arena, a), try serialize(arena, b));
}

fn serialize(arena: std.mem.Allocator, n: *const xml.Node) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try xml.write(&out.writer, n, 0);
    return out.written();
}

/// Adds `c` under `parent`, or merges it into the element already there (missing attributes
/// added, children merged the same way). What the app says wins.
fn mergeInto(arena: std.mem.Allocator, parent: *xml.Node, c: *xml.Node) !void {
    if (removed(c)) return;
    for (parent.children.items) |have| {
        if (!try same(arena, have, c)) continue;
        for (c.attrs.items) |a| if (have.attr(a.name) == null and !eql(a.name, "tools:node")) try have.attrs.append(arena, a);
        for (c.children.items) |cc| try mergeInto(arena, have, cc);
        return;
    }
    try parent.children.append(arena, c);
}

fn mergeBefore(arena: std.mem.Allocator, root: *xml.Node, application: *const xml.Node, c: *xml.Node) !void {
    for (root.children.items) |have| {
        if (!try same(arena, have, c)) continue;
        if (eql(c.name, "queries")) for (c.children.items) |cc| try mergeInto(arena, have, cc);
        return;
    }
    const at = for (root.children.items, 0..) |have, i| {
        if (have == application) break i;
    } else root.children.items.len;
    try root.children.insert(arena, at, c);
}

const FirebaseValues = struct { project_id: []const u8, app_id: []const u8, api_key: []const u8, sender_id: []const u8 };

/// The values of the app's entry in google-services.json (the client whose package is the
/// manifest's).
fn firebaseValues(arena: std.mem.Allocator, io: Io, path: []const u8, package: []const u8) !FirebaseValues {
    const text = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024));
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return error.BadGoogleServices;
    const info = try field(root, "project_info");
    for ((try field(root, "client")).array.items) |c| {
        const ci = try field(c, "client_info");
        const pkg = try field(try field(ci, "android_client_info"), "package_name");
        if (!eql(pkg.string, package)) continue;
        const keys = try field(c, "api_key");
        if (keys.array.items.len == 0) return error.BadGoogleServices;
        return .{
            .project_id = (try field(info, "project_id")).string,
            .sender_id = (try field(info, "project_number")).string,
            .app_id = (try field(ci, "mobilesdk_app_id")).string,
            .api_key = (try field(keys.array.items[0], "current_key")).string,
        };
    }
    std.debug.print("apk: google-services.json has no client for {s}\n", .{package});
    return error.NoFirebaseClient;
}

fn field(v: std.json.Value, name: []const u8) !std.json.Value {
    if (v != .object) return error.BadGoogleServices;
    return v.object.get(name) orelse error.BadGoogleServices;
}

fn parseArgs(arena: std.mem.Allocator, args: []const [:0]const u8) !Options {
    var o: Options = .{};
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        const key = args[i];
        const val: []const u8 = args[i + 1];
        if (eql(key, "--sdk")) o.sdk = val else if (eql(key, "--build-tools")) o.build_tools = val else if (eql(key, "--platform")) o.platform = val else if (eql(key, "--min-sdk")) o.min_sdk = val else if (eql(key, "--jdk")) o.jdk = val else if (eql(key, "--manifest")) o.manifest = val else if (eql(key, "--java")) try o.java.append(arena, val) else if (eql(key, "--keystore")) o.keystore = val else if (eql(key, "--out")) o.out = val else if (eql(key, "--res")) try o.res.append(arena, val) else if (eql(key, "--dep")) try o.deps.append(arena, val) else if (eql(key, "--maven-cache")) o.maven_cache = val else if (eql(key, "--firebase")) o.firebase = val else if (eql(key, "--wufour-apps")) o.wufour_apps = val else if (eql(key, "--lib")) {
            const eq = std.mem.indexOfScalar(u8, val, '=') orelse return error.BadLibArg;
            try o.libs.append(arena, .{ .abi = val[0..eq], .path = val[eq + 1 ..] });
        } else {
            std.debug.print("apk: unknown option {s}\n", .{key});
            return error.BadArgs;
        }
    }
    return o;
}

fn join(arena: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    return std.fs.path.join(arena, parts);
}

/// Appends the full path of every file under `root` ending in `ext`, in sorted order so the
/// output is reproducible.
fn collect(arena: std.mem.Allocator, io: Io, root: []const u8, ext: []const u8, list: *std.ArrayList([]const u8)) !void {
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    const start = list.items.len;
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.path, ext))
            try list.append(arena, try join(arena, &.{ root, entry.path }));
    }
    std.mem.sort([]const u8, list.items[start..], {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
}

fn run(arena: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, cwd: ?[]const u8, argv: []const []const u8) !void {
    const result = try std.process.run(arena, io, .{
        .argv = argv,
        .cwd = if (cwd) |p| .{ .path = p } else .inherit,
        .environ_map = env,
    });
    if (!result.term.success()) {
        std.debug.print("apk: {s} failed\n{s}{s}\n", .{ std.fs.path.basename(argv[0]), result.stdout, result.stderr });
        return error.ToolFailed;
    }
}

test "manifest merge" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const app = try xml.parse(arena,
        \\<manifest xmlns:android="a" package="com.x">
        \\  <uses-permission android:name="android.permission.INTERNET" />
        \\  <application android:label="X">
        \\    <service android:name="S"><meta-data android:name="m1" android:value="v" /></service>
        \\  </application>
        \\</manifest>
    );
    const lib = try xml.parse(arena,
        \\<manifest xmlns:android="a" xmlns:tools="t" package="com.lib">
        \\  <uses-sdk android:minSdkVersion="21" />
        \\  <uses-permission android:name="android.permission.INTERNET" />
        \\  <permission android:name="${applicationId}.P" />
        \\  <application>
        \\    <service android:name="S" android:exported="false" tools:targetApi="n"><meta-data android:name="m2" android:value="v" /></service>
        \\    <provider android:name="P" android:authorities="${applicationId}.init" />
        \\    <activity android:name="Gone" tools:node="remove" />
        \\  </application>
        \\</manifest>
    );
    try prepare(arena, lib, "com.x");
    try mergeLibrary(arena, app, app.child("application").?, lib);
    const out = try serialize(arena, app);
    try std.testing.expect(std.mem.indexOf(u8, out, "<permission android:name=\"com.x.P\" />") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "android:authorities=\"com.x.init\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "m1") != null and std.mem.indexOf(u8, out, "m2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Gone") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "tools:") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "uses-sdk") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "INTERNET"));
    // Permissions stay ahead of <application>.
    try std.testing.expect(std.mem.indexOf(u8, out, "com.x.P").? < std.mem.indexOf(u8, out, "<application").?);
}

test isJavaResource {
    try std.testing.expect(isJavaResource("META-INF/services/kotlinx.coroutines.internal.MainDispatcherFactory"));
    try std.testing.expect(!isJavaResource("META-INF/MANIFEST.MF"));
    try std.testing.expect(!isJavaResource("kotlin/collections/collections.kotlin_builtins"));
    try std.testing.expect(!isJavaResource("commonMain/default/linkdata/root_package/0_.knm"));
    try std.testing.expect(!isJavaResource("nonJvmMain/default/manifest"));
}

fn element(arena: std.mem.Allocator, name: []const u8, attrs: []const [2][]const u8) !*xml.Node {
    const n = try arena.create(xml.Node);
    n.* = .{ .name = name };
    for (attrs) |a| try n.attrs.append(arena, .{ .name = a[0], .value = a[1] });
    return n;
}

pub const shared_auth_permission = "com.wufour.permission.SHARED_AUTH";

/// The shared Wufour sign-in between our apps (ZuiAuthProvider; see the top of this file).
fn addSharedAuth(arena: std.mem.Allocator, app: *xml.Node, application: *xml.Node, package: []const u8, apps: []const u8) !void {
    try mergeBefore(arena, app, application, try element(arena, "permission", &.{ .{ "android:name", shared_auth_permission }, .{ "android:protectionLevel", "signature" } }));
    try mergeBefore(arena, app, application, try element(arena, "uses-permission", &.{.{ "android:name", shared_auth_permission }}));
    const queries = try element(arena, "queries", &.{});
    var it = std.mem.splitScalar(u8, apps, ',');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " ");
        if (p.len == 0 or eql(p, package)) continue;
        try queries.children.append(arena, try element(arena, "package", &.{.{ "android:name", p }}));
    }
    if (queries.children.items.len > 0) try mergeBefore(arena, app, application, queries);
    try mergeInto(arena, application, try element(arena, "provider", &.{
        .{ "android:name", "com.wufour.zui.ZuiAuthProvider" },
        .{ "android:authorities", try std.mem.concat(arena, u8, &.{ package, ".wufourauth" }) },
        .{ "android:exported", "true" },
        .{ "android:permission", shared_auth_permission },
    }));
}

test "shared Wufour sign-in in the manifest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const app = try xml.parse(arena,
        \\<manifest xmlns:android="a" package="com.wufour.turf">
        \\  <uses-permission android:name="android.permission.INTERNET" />
        \\  <application android:label="Turf"><activity android:name="A" /></application>
        \\</manifest>
    );
    try addSharedAuth(arena, app, app.child("application").?, "com.wufour.turf", "com.wufour.turf,com.wufour.reseal,com.wufour.maps");
    const s = try serialize(arena, app);
    try std.testing.expect(std.mem.indexOf(u8, s, "android:protectionLevel=\"signature\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "<package android:name=\"com.wufour.reseal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "<package android:name=\"com.wufour.turf\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "android:authorities=\"com.wufour.turf.wufourauth\"") != null);
    // Before <application>, as Android wants.
    try std.testing.expect(std.mem.indexOf(u8, s, "<queries>").? < std.mem.indexOf(u8, s, "<application").?);
}
