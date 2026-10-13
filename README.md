# zig-core

Zig code shared by Reseal, Maps and Turf, and the build steps every app gets through `addApp`.

| Folder | What it is |
|---|---|
| `zui/` | UI framework. One app source shows real native views: DOM on the web, `android.view.View` through JNI, `UIView` through the Objective-C runtime |
| `zui/platform/` | Hand-written bindings: `jni.zig` (generated once from the NDK's `jni.h` by `tools/gen_jni.js`), `objc.zig` |
| `http/` | HTTP server for the app servers: router, JSON, static files, WebSocket, server-sent events. `http/tls/`: our TLS 1.3 server, certificates, and the ACME (Let's Encrypt) client |
| `mongo/` | MongoDB driver: BSON, OP_MSG, connection pool, SCRAM-SHA-256, collections and cursors |
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

## Tests

`zig build test` runs everything. The MongoDB tests use a local server on 127.0.0.1:27017 when one is
running (throwaway database `zigcore_test`) and are skipped otherwise. The TLS tests connect std's
verifying TLS client to our server; the key schedule is checked against RFC 8448.

## Calls

zui's calls API (`fx.openMedia`, `fx.openPeer`, `fx.peerSignal`, `ui.video`) runs on the browser's
WebRTC on the web. On Android and iOS zui captures, encodes, decodes and draws itself
(`zui/media/android.zig`: NDK MediaCodec, AAudio, Camera2 through `ZuiMedia.java`;
`zui/media/ios.zig`: AVCaptureSession, VideoToolbox, AVSampleBufferDisplayLayer, VoiceProcessingIO,
AudioConverter) and takes the connection from a call engine the app declares in its client root;
zig-core depends on no engine (`zui/calls.zig` lists what one provides). With reseal-rtc:

```zig
pub const rtc = @import("reseal_rtc").zui_engine;
pub const panic = zui.panic; // required on iOS
```

and `.client_imports = &.{.{ .name = "reseal_rtc", .module = ... }}` in `addApp`. Signals are the
web host's JSON, so phones and browsers call each other. The app's Android manifest needs
`INTERNET`, `CAMERA`, `RECORD_AUDIO` and `MODIFY_AUDIO_SETTINGS`; its iOS Info.plist needs
`NSCameraUsageDescription` and `NSMicrophoneUsageDescription`.
