//! Builds a signed APK from a manifest, the fixed Java shim and the app's Zig `.so` files,
//! using the Android SDK build-tools only to compile the manifest (aapt2), dex the shim (d8)
//! and sign (apksigner). The archive itself is written by `zip.zig`.
//!
//! apk --sdk DIR --build-tools VER --platform android-NN --min-sdk N --jdk DIR
//!     --manifest FILE --java DIR --lib ABI=FILE [--lib ABI=FILE ...]
//!     --keystore FILE --out FILE

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const zip = @import("zip.zig");

const exe_ext = if (builtin.os.tag == .windows) ".exe" else "";
const bat_ext = if (builtin.os.tag == .windows) ".bat" else "";

const Lib = struct { abi: []const u8, path: []const u8 };

const Options = struct {
    sdk: []const u8 = "",
    build_tools: []const u8 = "",
    platform: []const u8 = "",
    min_sdk: []const u8 = "",
    jdk: []const u8 = "",
    manifest: []const u8 = "",
    java: []const u8 = "",
    keystore: []const u8 = "",
    out: []const u8 = "",
    libs: std.ArrayList(Lib) = .empty,
    /// Android resource folders (res/), compiled and linked in order.
    res: std.ArrayList([]const u8) = .empty,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const opts = try parseArgs(arena, try init.minimal.args.toSlice(arena));

    // Child processes (the .bat wrappers in particular) need the JDK.
    try init.environ_map.put("JAVA_HOME", opts.jdk);
    const path_var = init.environ_map.get("PATH") orelse "";
    const path_sep = if (builtin.os.tag == .windows) ";" else ":";
    try init.environ_map.put("PATH", try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ try join(arena, &.{ opts.jdk, "bin" }), path_sep, path_var }));
    const env = init.environ_map;

    const bt = try join(arena, &.{ opts.sdk, "build-tools", opts.build_tools });
    const android_jar = try join(arena, &.{ opts.sdk, "platforms", opts.platform, "android.jar" });
    const tool = struct {
        fn path(a: std.mem.Allocator, dir: []const u8, name: []const u8, ext: []const u8) ![]const u8 {
            return join(a, &.{ dir, try std.mem.concat(a, u8, &.{ name, ext }) });
        }
    }.path;

    const cwd = Io.Dir.cwd();
    // Absolute, because `aapt add` below runs from inside the staging folder.
    const work_rel = try join(arena, &.{ std.fs.path.dirname(opts.out) orelse ".", "apk-work" });
    cwd.deleteTree(io, work_rel) catch {};
    try cwd.createDirPath(io, work_rel);
    const work = try cwd.realPathFileAlloc(io, work_rel, arena);
    const stage = try join(arena, &.{ work, "stage" });
    const classes = try join(arena, &.{ work, "classes" });
    try cwd.createDirPath(io, stage);
    try cwd.createDirPath(io, classes);

    // 1. Resources (zui's widget layouts, the app's icon...) and the manifest -> base.apk
    const base_apk = try join(arena, &.{ work, "base.apk" });
    var link: std.ArrayList([]const u8) = .empty;
    try link.appendSlice(arena, &.{ try tool(arena, bt, "aapt2", exe_ext), "link", "-o", base_apk, "--manifest", opts.manifest, "-I", android_jar, "--auto-add-overlay" });
    for (opts.res.items, 0..) |dir, i| {
        const flat = try join(arena, &.{ work, try std.fmt.allocPrint(arena, "res-{d}.zip", .{i}) });
        try run(arena, io, env, null, &.{ try tool(arena, bt, "aapt2", exe_ext), "compile", "--dir", dir, "-o", flat });
        try link.appendSlice(arena, &.{ "-R", flat });
    }
    try run(arena, io, env, null, link.items);

    // 2. Java shim -> .class -> classes.dex
    var javac: std.ArrayList([]const u8) = .empty;
    try javac.appendSlice(arena, &.{ try join(arena, &.{ opts.jdk, "bin", "javac" ++ exe_ext }), "--release", "17", "-nowarn", "-classpath", android_jar, "-d", classes });
    try collect(arena, io, opts.java, ".java", &javac);
    try run(arena, io, env, null, javac.items);

    var d8: std.ArrayList([]const u8) = .empty;
    try d8.appendSlice(arena, &.{ try tool(arena, bt, "d8", bat_ext), "--release", "--min-api", opts.min_sdk, "--lib", android_jar, "--output", stage });
    // The classes go in an argument file: listed on the command line they pass Windows's
    // 8191-character limit as soon as the shim grows or the build directory is deep.
    var class_files: std.ArrayList([]const u8) = .empty;
    try collect(arena, io, classes, ".class", &class_files);
    var arg_text: std.ArrayList(u8) = .empty;
    for (class_files.items) |f| try arg_text.print(arena, "{s}\n", .{f});
    const arg_file = try join(arena, &.{ work, "d8-classes.txt" });
    try cwd.writeFile(io, .{ .sub_path = arg_file, .data = arg_text.items });
    try d8.append(arena, try std.fmt.allocPrint(arena, "@{s}", .{arg_file}));
    try run(arena, io, env, null, d8.items);

    // 3. Assemble: aapt2's entries as they are, then classes.dex and the native libraries,
    //    stored uncompressed (extractNativeLibs=false) with each .so on a 16 KB page boundary,
    //    which Android 15+ devices require.
    const max_file = std.Io.Limit.limited(256 * 1024 * 1024);
    var entries: std.ArrayList(zip.Entry) = .empty;
    try entries.appendSlice(arena, try zip.read(arena, try cwd.readFileAlloc(io, base_apk, arena, max_file)));
    const dex = try cwd.readFileAlloc(io, try join(arena, &.{ stage, "classes.dex" }), arena, max_file);
    try entries.append(arena, zip.stored("classes.dex", dex, 4));
    for (opts.libs.items) |lib| {
        const so = try cwd.readFileAlloc(io, lib.path, arena, max_file);
        try entries.append(arena, zip.stored(try std.fmt.allocPrint(arena, "lib/{s}/libapp.so", .{lib.abi}), so, 16 * 1024));
    }
    const aligned = try join(arena, &.{ work, "aligned.apk" });
    try cwd.writeFile(io, .{ .sub_path = aligned, .data = try zip.write(arena, entries.items) });

    // 4. Sign.
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

fn parseArgs(arena: std.mem.Allocator, args: []const [:0]const u8) !Options {
    var o: Options = .{};
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        const key = args[i];
        const val: []const u8 = args[i + 1];
        if (std.mem.eql(u8, key, "--sdk")) o.sdk = val else if (std.mem.eql(u8, key, "--build-tools")) o.build_tools = val else if (std.mem.eql(u8, key, "--platform")) o.platform = val else if (std.mem.eql(u8, key, "--min-sdk")) o.min_sdk = val else if (std.mem.eql(u8, key, "--jdk")) o.jdk = val else if (std.mem.eql(u8, key, "--manifest")) o.manifest = val else if (std.mem.eql(u8, key, "--java")) o.java = val else if (std.mem.eql(u8, key, "--keystore")) o.keystore = val else if (std.mem.eql(u8, key, "--out")) o.out = val else if (std.mem.eql(u8, key, "--res")) try o.res.append(arena, val) else if (std.mem.eql(u8, key, "--lib")) {
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
