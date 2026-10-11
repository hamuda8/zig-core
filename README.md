# zig-core

Zig code shared by Reseal, Maps and Turf, and the build steps every app gets through `addApp`.

| Folder | What it is |
|---|---|
| `zui/` | UI framework. One app source shows real native views: DOM on the web, `android.view.View` through JNI, `UIView` through the Objective-C runtime |
| `zui/platform/` | Hand-written bindings: `jni.zig` (generated once from the NDK's `jni.h` by `tools/gen_jni.js`), `objc.zig` |
| `shells/` | The fixed per-platform entry points: `web/zui.js` and `android/.../ZuiActivity.java`. They never change per screen |
| `tools/` | `apk.zig` packages and signs APKs without Gradle; `zip.zig` writes the archive with page-aligned native libraries |
| `toolchain.zon` | Where the Android SDK, NDK and JDK live on this machine |

## Toolchain

- Zig **0.17.0**, pinned through `minimum_zig_version` in every `build.zig.zon`.
- Android SDK command-line tools, platform `android-36`, build-tools `37.0.0`, NDK `30.0.16248370`, and JDK 21. Paths are in `toolchain.zon`; override any of them with `-Dandroid-sdk=`, `-Djdk=`, `-Dandroid-ndk=`.
- iOS builds compile on any machine; the IPA is linked and signed on macOS (CI).

## App build steps

Run from an app folder (`Maps`, `Turf`, `Reseal`):

| Command | Output |
|---|---|
| `zig build web` | `zig-out/web/`: `app.wasm`, `zui.js`, the app's `index.html` |
| `zig build android` | `zig-out/android/<app>.apk`: signed, arm64-v8a and x86_64 |
| `zig build ios` | `zig-out/ios/{device,simulator}/libapp.a`; the library exports `main` |
| `zig build server` / `serve` | The server for this machine / build and run it |
| `zig build server-linux` | `zig-out/linux/<app>-server`: static x86-64 Linux binary for Proxmox |
| `zig build test` | Client tests (headless host) and server tests |

Add `-Doptimize=ReleaseSmall` for release-size builds. `zig build test` here runs the zig-core tests.
