//! zig-core: code shared by Reseal, Maps and Turf, plus `addApp`, which gives every app the same build
//! steps for web, Android, iOS and its server.

const std = @import("std");

const toolchain: struct {
    android_sdk: []const u8,
    jdk: []const u8,
    android_ndk: []const u8,
    android_build_tools: []const u8,
    android_platform: []const u8,
    debug_keystore: []const u8,
} = @import("toolchain.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("zui", .{ .root_source_file = b.path("zui/zui.zig") });
    _ = b.addModule("http", .{ .root_source_file = b.path("http/http.zig") });
    _ = b.addModule("mongo", .{ .root_source_file = b.path("mongo/mongo.zig") });

    // Host tool that packages APKs; apps reach it through `addApp`.
    b.installArtifact(b.addExecutable(.{
        .name = "apk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/apk.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    }));

    // Host tool that lists an app's translatable strings; apps reach it through `addApp`.
    b.installArtifact(b.addExecutable(.{
        .name = "strings",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/strings.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    }));

    const test_step = b.step("test", "Run zig-core tests");
    for ([_][]const u8{ "zui/zui.zig", "http/http.zig", "mongo/mongo.zig", "tools/zip.zig", "tools/strings.zig" }) |root| {
        const tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
        }) });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}

pub const AppOptions = struct {
    /// Short lowercase name: "maps", "turf", "reseal". Used for file names.
    name: []const u8,
    /// Client root; it calls `zui.exportApp`.
    client: std.Build.LazyPath,
    /// Server entry point.
    server: std.Build.LazyPath,
    /// The app's web shell folder (index.html and static files).
    web: std.Build.LazyPath,
    android_manifest: std.Build.LazyPath,
    /// The iOS bundle's Info.plist (bundle id, name, scene manifest naming ZuiSceneDelegate).
    ios_info_plist: std.Build.LazyPath,
    android_min_sdk: u32 = 26,
    optimize: std.builtin.OptimizeMode,
};

const android_abis = [_]struct { abi: []const u8, arch: std.Target.Cpu.Arch }{
    .{ .abi = "arm64-v8a", .arch = .aarch64 },
    .{ .abi = "x86_64", .arch = .x86_64 },
};

/// The NDK's prebuilt folder for the machine running the build.
const ndk_host = switch (@import("builtin").os.tag) {
    .windows => "windows-x86_64",
    .macos => "darwin-x86_64",
    else => "linux-x86_64",
};

const ios_targets = [_]struct { dir: []const u8, query: std.Target.Query }{
    .{ .dir = "device", .query = .{ .cpu_arch = .aarch64, .os_tag = .ios } },
    .{ .dir = "simulator", .query = .{ .cpu_arch = .aarch64, .os_tag = .ios, .abi = .simulator } },
};

var server_core: *std.Build.Dependency = undefined;

/// Adds the steps `web`, `android`, `ios`, `ios-sim-app`, `server`, `server-linux`, `serve`,
/// `strings` and `test`.
pub fn addApp(b: *std.Build, core: *std.Build.Dependency, opts: AppOptions) void {
    const zui = core.module("zui");
    const client = struct {
        fn module(bb: *std.Build, o: AppOptions, z: *std.Build.Module, target: std.Build.ResolvedTarget) *std.Build.Module {
            return bb.createModule(.{
                .root_source_file = o.client,
                .target = target,
                .optimize = o.optimize,
                .imports = &.{.{ .name = "zui", .module = z }},
            });
        }
    }.module;

    // Web: app.wasm + the fixed JS shim + the app's web shell, in zig-out/web.
    {
        const wasm = b.addExecutable(.{
            .name = "app",
            .root_module = client(b, opts, zui, b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding })),
        });
        wasm.entry = .disabled;
        wasm.rdynamic = true;
        const step = b.step("web", "Build the web app into zig-out/web");
        step.dependOn(&b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .{ .custom = "web" } } }).step);
        step.dependOn(&b.addInstallFileWithDir(core.path("shells/web/zui.js"), .{ .custom = "web" }, "zui.js").step);
        step.dependOn(&b.addInstallDirectory(.{ .source_dir = opts.web, .install_dir = .{ .custom = "web" }, .install_subdir = "" }).step);
    }

    // Android: libapp.so per ABI, packaged with the fixed Java shim into a signed APK.
    {
        const step = b.step("android", "Build the Android APK into zig-out/android");
        // Defaults come from toolchain.zon, not the environment: zig 0.17 caches the configure
        // step without tracking environment variables, so they would silently go stale.
        const sdk = b.option([]const u8, "android-sdk", "Android SDK folder") orelse toolchain.android_sdk;
        const jdk = b.option([]const u8, "jdk", "JDK folder") orelse toolchain.jdk;
        const ndk_version = b.option([]const u8, "android-ndk", "NDK version under <sdk>/ndk") orelse toolchain.android_ndk;
        const build_tools = b.option([]const u8, "android-build-tools", "build-tools version") orelse toolchain.android_build_tools;
        const platform = b.option([]const u8, "android-platform", "SDK platform") orelse toolchain.android_platform;
        const keystore = b.option([]const u8, "android-keystore", "Debug keystore") orelse toolchain.debug_keystore;

        {
            const run = b.addRunArtifact(core.artifact("apk"));
            run.addArgs(&.{ "--sdk", sdk, "--build-tools", build_tools, "--platform", platform, "--jdk", jdk });
            run.addArgs(&.{ "--min-sdk", b.fmt("{d}", .{opts.android_min_sdk}), "--keystore", keystore });
            run.addArg("--manifest");
            run.addFileArg(opts.android_manifest);
            run.addArg("--java");
            run.addDirectoryArg(core.path("shells/android/java"));
            const sysroot = b.pathJoin(&.{ sdk, "ndk", ndk_version, "toolchains", "llvm", "prebuilt", ndk_host, "sysroot" });
            for (android_abis) |a| {
                const triple = b.fmt("{t}-linux-android", .{a.arch});
                const crt_dir = b.pathJoin(&.{ sysroot, "usr", "lib", triple, b.fmt("{d}", .{opts.android_min_sdk}) });
                // Bionic comes from the NDK; zig links against its stubs (libc, liblog, ...).
                const libc_file = b.addWriteFiles().add(b.fmt("libc-{s}.txt", .{a.abi}), b.fmt(
                    \\include_dir={s}
                    \\sys_include_dir={s}
                    \\crt_dir={s}
                    \\msvc_lib_dir=
                    \\kernel32_lib_dir=
                    \\cc_dir={s}
                    \\darwin_sdk_dir=
                    \\
                , .{
                    b.pathJoin(&.{ sysroot, "usr", "include" }),
                    b.pathJoin(&.{ sysroot, "usr", "include", triple }),
                    crt_dir,
                    crt_dir, // the NDK keeps crtbegin/crtend next to the libc stubs
                }));
                const lib = b.addLibrary(.{
                    .linkage = .dynamic,
                    .name = "app",
                    .root_module = client(b, opts, zui, b.resolveTargetQuery(.{
                        .cpu_arch = a.arch,
                        .os_tag = .linux,
                        .abi = .android,
                        .android_api_level = opts.android_min_sdk,
                    })),
                });
                lib.link_z_max_page_size = 16 * 1024;
                lib.setLibCFile(libc_file);
                lib.root_module.link_libc = true;
                // NDK system libraries (liblog now; libandroid, libaaudio, libmediandk later),
                // passed by path: zig 0.17 on Windows hands lld a broken -l: for them otherwise.
                for ([_][]const u8{"liblog.so"}) |name| lib.root_module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ crt_dir, name }) });
                run.addArg("--lib");
                run.addPrefixedFileArg(b.fmt("{s}=", .{a.abi}), lib.getEmittedBin());
            }
            run.addArg("--out");
            const apk = run.addOutputFileArg(b.fmt("{s}.apk", .{opts.name}));
            step.dependOn(&b.addInstallFileWithDir(apk, .{ .custom = "android" }, b.fmt("{s}.apk", .{opts.name})).step);
        }
    }

    // iOS: static libapp.a for device and simulator (the library exports `main`). On macOS,
    // `ios-sim-app` links the simulator one into a runnable .app without an Xcode project.
    {
        const step = b.step("ios", "Build the iOS static libraries into zig-out/ios");
        const sim_app = b.step("ios-sim-app", "Link the simulator .app into zig-out/ios (macOS only)");
        for (ios_targets) |t| {
            const lib = b.addLibrary(.{
                .linkage = .static,
                .name = "app",
                .root_module = client(b, opts, zui, b.resolveTargetQuery(t.query)),
            });
            // Apple's linker links this archive on its own, so it carries Zig's runtime helpers.
            lib.bundle_compiler_rt = true;
            step.dependOn(&b.addInstallArtifact(lib, .{ .dest_dir = .{ .override = .{ .custom = b.fmt("ios/{s}", .{t.dir}) } } }).step);

            if (!std.mem.eql(u8, t.dir, "simulator")) continue;
            if (b.graph.host.result.os.tag != .macos) {
                sim_app.dependOn(&b.addFail("ios-sim-app needs macOS (Xcode command-line tools)").step);
                continue;
            }
            // The system linker turns libapp.a into the app binary; the bundle is that binary
            // plus Info.plist.
            const bundle = b.addSystemCommand(&.{
                "sh",     "-c",
                \\set -e
                \\mkdir -p "$3"
                \\xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=18.0 \
                \\  "$1" -framework UIKit -framework Foundation -lobjc -o "$3/App"
                \\cp "$2" "$3/Info.plist"
                ,
                "bundle",
            });
            bundle.addFileArg(lib.getEmittedBin());
            bundle.addFileArg(opts.ios_info_plist);
            const app_dir = bundle.addOutputDirectoryArg(b.fmt("{s}.app", .{opts.name}));
            sim_app.dependOn(&b.addInstallDirectory(.{
                .source_dir = app_dir,
                .install_dir = .{ .custom = "ios" },
                .install_subdir = b.fmt("{s}.app", .{opts.name}),
            }).step);
        }
    }

    // Server: a native build for development, and the Linux build for the Proxmox host.
    const server_name = b.fmt("{s}-server", .{opts.name});
    server_core = core;
    const server_module = struct {
        fn module(bb: *std.Build, o: AppOptions, target: std.Build.ResolvedTarget) *std.Build.Module {
            return bb.createModule(.{ .root_source_file = o.server, .target = target, .optimize = o.optimize, .imports = &.{
                .{ .name = "http", .module = server_core.module("http") },
                .{ .name = "mongo", .module = server_core.module("mongo") },
            } });
        }
    }.module;
    {
        const exe = b.addExecutable(.{ .name = server_name, .root_module = server_module(b, opts, b.graph.host) });
        const install = b.addInstallArtifact(exe, .{});
        b.step("server", "Build the server for this machine").dependOn(&install.step);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(&install.step);
        run.addPassthruArgs();
        b.step("serve", "Run the server on this machine").dependOn(&run.step);
    }
    {
        const exe = b.addExecutable(.{
            .name = server_name,
            .root_module = server_module(b, opts, b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux })),
        });
        b.step("server-linux", "Build the Linux server into zig-out/linux").dependOn(
            &b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "linux" } } }).step,
        );
    }

    // Translatable strings, for Lassan.
    {
        const run = b.addRunArtifact(core.artifact("strings"));
        run.addDirectoryArg(opts.client.dirname());
        const out = run.addOutputFileArg("strings.json");
        b.step("strings", "List translatable strings into zig-out/strings.json").dependOn(&b.addInstallFile(out, "strings.json").step);
    }

    // Tests run on this machine: the client against the headless host, and the server.
    {
        const step = b.step("test", "Run client and server tests");
        step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = client(b, opts, zui, b.graph.host) })).step);
        step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = server_module(b, opts, b.graph.host) })).step);
    }
}
