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

    const zui = b.addModule("zui", .{ .root_source_file = b.path("zui/zui.zig") });
    _ = b.addModule("map", .{ .root_source_file = b.path("map/map.zig"), .imports = &.{.{ .name = "zui", .module = zui }} });
    const http_mod = b.addModule("http", .{ .root_source_file = b.path("http/http.zig") });
    const mongo_mod = b.addModule("mongo", .{ .root_source_file = b.path("mongo/mongo.zig") });
    _ = b.addModule("env", .{ .root_source_file = b.path("env/env.zig") });
    // Outgoing HTTP with time limits, recovery from dead pooled connections, and the SSRF guard.
    const fetch_mod = b.addModule("fetch", .{ .root_source_file = b.path("fetch/fetch.zig") });
    _ = b.addModule("smtp", .{ .root_source_file = b.path("smtp/smtp.zig") });
    _ = b.addModule("ec", .{ .root_source_file = b.path("ec/ec.zig") });
    // Wufour sign-in (tokens from cookies or Bearer, verified and cached).
    const wufour_imports: []const std.Build.Module.Import = &.{
        .{ .name = "http", .module = http_mod },
        .{ .name = "fetch", .module = fetch_mod },
        .{ .name = "mongo", .module = mongo_mod },
    };
    _ = b.addModule("wufour", .{ .root_source_file = b.path("wufour/wufour.zig"), .imports = wufour_imports });
    const push = b.addModule("push", .{ .root_source_file = b.path("push/push.zig") });
    const geo = b.addModule("geo", .{ .root_source_file = b.path("geo/geo.zig") });

    // Builds and queries region search indexes by hand: zig-out/bin/geo search <dir> <text>
    const geo_tool = b.addExecutable(.{
        .name = "geo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/geo.zig"),
            .target = target,
            .optimize = if (optimize == .debug) .safe else optimize,
            .imports = &.{.{ .name = "geo", .module = geo }},
        }),
    });
    b.installArtifact(geo_tool);

    // Tries the HTTP/2 client against a server by hand: zig-out/bin/h2get https://host/path
    b.installArtifact(b.addExecutable(.{
        .name = "h2get",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/h2get.zig"),
            .target = target,
            .optimize = if (optimize == .debug) .safe else optimize,
            .imports = &.{.{ .name = "push", .module = push }},
        }),
    }));

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
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("map/map.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zui", .module = b.createModule(.{ .root_source_file = b.path("zui/zui.zig"), .target = target, .optimize = optimize }) }},
    }) })).step);
    // HTTP/2 + ALPN end to end: the push client against our TLS server.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("push/e2e_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "http", .module = b.createModule(.{ .root_source_file = b.path("http/http.zig"), .target = target, .optimize = optimize }) }},
    }) })).step);
    // Wufour sign-in against a stand-in Wufour.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("wufour/wufour.zig"),
        .target = target,
        .optimize = optimize,
        .imports = wufour_imports,
    }) })).step);
    for ([_][]const u8{ "zui/zui.zig", "http/http.zig", "mongo/mongo.zig", "env/env.zig", "geo/geo.zig", "push/push.zig", "fetch/fetch.zig", "smtp/smtp.zig", "ec/ec.zig", "tools/zip.zig", "tools/strings.zig" }) |root| {
        const tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
        }) });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}

pub const WebExtra = struct { name: []const u8, root: std.Build.LazyPath };

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
    /// Build-time settings for the client, imported as "app_config" (server address, ...).
    client_config: ?*std.Build.Module = null,
    /// More modules for the client, e.g. a call engine for the phones:
    /// `.{ .name = "reseal_rtc", .module = b.dependency("reseal_rtc", .{}).module("reseal_rtc") }`.
    /// They should not fix a target: they build for each platform the client does.
    client_imports: []const std.Build.Module.Import = &.{},
    /// More wasm modules for the web build (zig-out/web/<name>.wasm), with the client's imports:
    /// e.g. a library that other sites load.
    web_extra: []const WebExtra = &.{},
    /// The app's Android res/ folder (launcher icon...), and its files (so a change rebuilds).
    android_res: ?std.Build.LazyPath = null,
    android_res_files: []const []const u8 = &.{},
    /// Adds the home-screen widget to the iOS app (a fixed SwiftUI extension, shells/ios/widget).
    /// Its data travels through the app group "group.<bundle id>": a device build needs that
    /// group in the app's provisioning profile.
    ios_widget: bool = false,
    optimize: std.builtin.OptimizeMode,
};

/// The fixed Android shim (shells/android/java/com/wufour/zui). Listed so the APK rebuilds when one changes.
const android_java = [_][]const u8{ "Zui.java", "ZuiActivity.java", "ZuiLayout.java", "ZuiPath.java", "ZuiSocket.java", "ZuiLocationService.java", "ZuiWidget.java", "ZuiCallService.java", "ZuiCallReceiver.java", "ZuiMedia.java", "ZuiDevice.java", "ZuiStreamRenderer.java", "ZuiRecorder.java", "ZuiPlayer.java", "ZuiStyle.java", "ZuiScanner.java" };
/// zui's Android resources (the widget), listed for the same reason.
const android_res = [_][]const u8{ "layout/zui_widget.xml", "xml/zui_widget_info.xml", "drawable/zui_widget_bg.xml" };

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
    server_core = core;
    const client = struct {
        fn module(bb: *std.Build, o: AppOptions, z: *std.Build.Module, target: std.Build.ResolvedTarget) *std.Build.Module {
            const m = bb.createModule(.{
                .root_source_file = o.client,
                .target = target,
                .optimize = o.optimize,
                .imports = &.{ .{ .name = "zui", .module = z }, .{ .name = "map", .module = server_core.module("map") } },
            });
            if (o.client_config) |cfg| m.addImport("app_config", cfg);
            for (o.client_imports) |imp| m.addImport(imp.name, imp.module);
            return m;
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
        for (opts.web_extra) |extra| {
            var o = opts;
            o.client = extra.root;
            const lib = b.addExecutable(.{
                .name = extra.name,
                .root_module = client(b, o, zui, b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding })),
            });
            lib.entry = .disabled;
            lib.rdynamic = true;
            step.dependOn(&b.addInstallArtifact(lib, .{ .dest_dir = .{ .override = .{ .custom = "web" } } }).step);
        }
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
            // The cache does not look inside a directory argument, so each source is also an input:
            // without this, a Java-only change leaves the old APK in place.
            for (android_java) |f| run.addFileInput(core.path(b.fmt("shells/android/java/com/wufour/zui/{s}", .{f})));
            run.addArg("--res");
            run.addDirectoryArg(core.path("shells/android/res"));
            for (android_res) |f| run.addFileInput(core.path(b.fmt("shells/android/res/{s}", .{f})));
            // The app's own resources: its launcher icon (mipmap/ic_launcher), strings...
            if (opts.android_res) |res| {
                run.addArg("--res");
                run.addDirectoryArg(res);
                for (opts.android_res_files) |f| run.addFileInput(res.path(b, f));
            }
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
                // NDK system libraries (logging; calls: codecs, audio, surfaces, dlsym), passed by
                // path: zig 0.17 on Windows hands lld a broken -l: for them otherwise.
                for ([_][]const u8{ "liblog.so", "libmediandk.so", "libaaudio.so", "libandroid.so", "libdl.so" }) |name| lib.root_module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ crt_dir, name }) });
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
            // With the widget, swiftc links the app (for the small reload function) and builds
            // the extension into PlugIns/Widget.appex; both are signed with the app group.
            const bundle = b.addSystemCommand(&.{
                "sh",     "-c",
                \\set -e
                \\mkdir -p "$3"
                \\frameworks="-framework UIKit -framework QuartzCore -framework CoreGraphics -framework CoreLocation -framework AVFoundation -framework CoreImage -framework Security -framework UserNotifications -framework CallKit -framework VideoToolbox -framework AudioToolbox -framework CoreMedia -framework CoreVideo -framework Foundation -lobjc"
                \\cp "$2" "$3/Info.plist"
                \\if [ "$4" = "none" ]; then
                \\  xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=18.0 "$1" $frameworks -Wl,-U,_zui_widget_reload -o "$3/App"
                \\  exit 0
                \\fi
                \\swift="xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios18.0-simulator -parse-as-library"
                \\$swift "$5" "$1" $frameworks -framework WidgetKit -o "$3/App"
                \\id=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$2")
                \\get() { /usr/libexec/PlistBuddy -c "Print $1" "$2" 2>/dev/null || echo "$3"; }
                \\ext="$3/PlugIns/Widget.appex"
                \\mkdir -p "$ext"
                \\$swift -application-extension "$4" -framework WidgetKit -framework SwiftUI -o "$ext/Widget"
                \\p() { /usr/libexec/PlistBuddy -c "$1" "$ext/Info.plist" >/dev/null; }
                \\p "Add :CFBundleIdentifier string $id.widget"
                \\p "Add :CFBundleExecutable string Widget"
                \\p "Add :CFBundlePackageType string XPC!"
                \\p "Add :CFBundleName string Widget"
                \\p "Add :CFBundleDisplayName string $(get CFBundleDisplayName "$2" "$(get CFBundleName "$2" App)")"
                \\p "Add :CFBundleShortVersionString string $(get CFBundleShortVersionString "$2" 1.0)"
                \\p "Add :CFBundleVersion string $(get CFBundleVersion "$2" 1)"
                \\p "Add :MinimumOSVersion string 18.0"
                \\p "Add :CFBundleSupportedPlatforms array"
                \\p "Add :CFBundleSupportedPlatforms:0 string iPhoneSimulator"
                \\p "Add :NSExtension dict"
                \\p "Add :NSExtension:NSExtensionPointIdentifier string com.apple.widgetkit-extension"
                \\ent="$(mktemp -d)/entitlements.plist"
                \\/usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups array" -c "Add :com.apple.security.application-groups:0 string group.$id" "$ent" >/dev/null
                \\codesign -f -s - --entitlements "$ent" "$ext"
                \\codesign -f -s - --entitlements "$ent" "$3"
                ,
                "bundle",
            });
            bundle.addFileArg(lib.getEmittedBin());
            bundle.addFileArg(opts.ios_info_plist);
            const app_dir = bundle.addOutputDirectoryArg(b.fmt("{s}.app", .{opts.name}));
            if (opts.ios_widget) {
                bundle.addFileArg(core.path("shells/ios/widget/ZuiWidget.swift"));
                bundle.addFileArg(core.path("shells/ios/widget/ZuiWidgetReload.swift"));
            } else bundle.addArg("none");
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
                .{ .name = "env", .module = server_core.module("env") },
                .{ .name = "geo", .module = server_core.module("geo") },
                .{ .name = "push", .module = server_core.module("push") },
                .{ .name = "fetch", .module = server_core.module("fetch") },
                .{ .name = "smtp", .module = server_core.module("smtp") },
                .{ .name = "ec", .module = server_core.module("ec") },
                .{ .name = "wufour", .module = server_core.module("wufour") },
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
        for (opts.web_extra) |extra| {
            var o = opts;
            o.client = extra.root;
            step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = client(b, o, zui, b.graph.host) })).step);
        }
        step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = server_module(b, opts, b.graph.host) })).step);
    }
}
