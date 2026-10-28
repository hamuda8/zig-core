# zig-core

Zig code shared by Reseal, Maps and Turf, and the build steps every app gets through `addApp`.

| Folder | What it is |
|---|---|
| `zui/` | UI framework. One app source shows real native views: DOM on the web, `android.view.View` through JNI, `UIView` through the Objective-C runtime |
| `zui/platform/` | Hand-written bindings: `jni.zig` (generated once from the NDK's `jni.h` by `tools/gen_jni.js`), `objc.zig` |
| `http/` | HTTP server for the app servers: router, JSON, static files, WebSocket, server-sent events. `http/tls/`: our TLS 1.3 server, certificates, and the ACME (Let's Encrypt) client |
| `mongo/` | MongoDB driver: BSON, OP_MSG, connection pool, SCRAM-SHA-256, collections and cursors; `mongo.val` (a JSON/BSON value like Node's) and `mongo.db` (the Node driver's options: findOneAndUpdate, distinct, arrayFilters, any index) |
| `map/` | Map engine (no MapLibre): Web Mercator raster tiles, pan/pinch/rotate/tilt, fly-to, route lines, markers (pressable, draggable) |
| `geo/` | `.osm.pbf` parser and the memory-mapped search / reverse-geocoding index (Arabic and Latin folding, any number of regions) |
| `push/` | Web Push (RFC 8291/8292), FCM HTTP v1 (RS256), APNs over our HTTP/2 client (TLS with ALPN, HPACK) |
| `fetch/`, `smtp/`, `wufour/`, `env/` | Server helpers: outgoing HTTP with time limits and a self-healing connection pool, SMTP, Wufour sign-in (cookie or Bearer), `.env` loading (`<APP>_ENV_FILE`, `.env.local`, `.env.production`, `.env`) |
| `shells/` | The fixed per-platform entry points: `web/zui.js` and `android/.../ZuiActivity.java`. They never change per screen. `fonts/`: Wufour Sans and Wufour Arabic as `.ttf`, packaged into every app (see Fonts) |
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

## Fonts

The phones draw text with Wufour's own pair, like the web: Wufour Sans for English and Wufour
Arabic for Arabic, in the weights 400, 500 and 700 (`shells/fonts/*.ttf`, six files). `addApp`
packages them into every app:

- Android: `assets/fonts/` in the APK (`tools/apk.zig --assets fonts=`). `Zui.java` builds one
  Typeface per face and weight from them, with the other Wufour face as a fallback and the system's
  fonts after that (before API 29 a typeface holds one file and the system fills in the rest).
- iOS: `zig build ios` puts them in `zig-out/ios/fonts/`; the bundle needs those six files next to
  `Info.plist`, which lists them under `UIAppFonts` (`ios-sim-app` copies them). The app registers
  them again at start through CoreText, so the app binary links the `CoreText` framework.

`zui/font.zig` is the one rule both hosts follow: a weight is snapped to the nearest of the three;
text with an Arabic letter is set in Wufour Arabic with Wufour Sans filling in the glyphs it lacks
(Latin words inside Arabic keep the Sans), everything else in Wufour Sans with Wufour Arabic
filling in. Monospace stays the system monospace. A missing file falls back to the system font
without an error.

To refresh the fonts, copy `C:\MProjects\WufourType\dist\golden\*.ttf` over `shells/fonts/`
(the names must stay), rebuild, and point each app's `build.zig.zon` at the new zig-core commit.

## Tests

`zig build test` runs everything. The MongoDB tests use a local server on 127.0.0.1:27017 when one is
running (throwaway database `zigcore_test`) and are skipped otherwise. The TLS tests connect std's
verifying TLS client to our server; the key schedule is checked against RFC 8448.

## zui at a glance

An app is `Msg`, `State`, `init`, `update(state, msg, env, fx)` and `view(state, ui)`, plus
`comptime { zui.exportApp(@This()); }`. The Zig layout engine places every view; hosts only draw.

- **Views:** boxes (flex rows/columns, wrap, grid, shadows, gradients, per-side borders, per-corner
  radius, transitions, labels), text and rich text, inputs (secure, keyboards, multi-line,
  max length), images (URL with headers, or bytes), scroll views (anchored to the end,
  `fx.scrollTo`), paths and icons, video, spinner, map.
- **Events:** press, long press, context menu, hover, pointers, keys (`pub fn keyEvent`), Back
  (`ui.onBack`), links (`fx.setLink` / `fx.pushLink`, `pub fn linkEvent`), online/visible
  (`pub fn deviceEvent`).
- **Effects (`fx`):** fetch, timers, WebSockets, server-sent events, location (and background
  location), notifications, the system call screen (`ringCall`, `startCall`, `endCall`), push,
  pickers (date, time, option, photo, file), save/share files, clipboard, speech, vibrate,
  keep awake, recording and playback, barcode scanning (Code 128 and QR, decoded in Zig),
  calls (below), secure keys (`fx.key`: WebCrypto / AndroidKeyStore / Keychain), an in-app
  sign-in page (`fx.webAuth`: a WebView / WKWebView with no browser around it; `zui.wufour`
  builds Wufour's sign-in address and reads the token from its callback; the web keeps cookies;
  one sign-in for all our apps on a phone: zui/wufour_apps.zig, Android ZuiAuthProvider behind a
  signature permission, iOS a shared Keychain group named by Info.plist `WufourKeychainGroup`).
- **The Wufour account menu:** `zui.account` draws the profile picture and the menu every Wufour
  app shows (the same as Wufour's web element `<wufour-account>`): the account, the app's own items,
  the person's four apps from the Wufour start page and All apps. The app's server serves Wufour's
  data from `wufour.Verifier.accountMenu`; the client passes it to `Menu.load`. See the top of
  zui/account.zig, and Wufour's docs/account-menu.md.
- **Also:** `zui.storage` (plain and secure), `zui.widget` (Android widget; iOS through the fixed
  SwiftUI extension in `shells/ios/widget`, opt-in with `ios_widget`), `t("English")`
  translation bundles in Lassan's format with `t("Text|context")` for clashing keys.

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

## Push notifications

`fx.registerPush(.{ .web_key = vapid_public_key })` after sign-in; tokens arrive at the app's
`pub fn pushToken(token: []const u8, kind: zui.PushKind) ?Msg` (`.fcm` Android, `.apns` and
`.voip` iOS, `.web`: the Web Push subscription's JSON) and pushes at
`pub fn pushMessage(json: []const u8) ?Msg` (the data map / payload as JSON). The update a
push returns runs before `pushMessage` returns, so a VoIP push can ring CallKit (`fx.ringCall`)
in time.

When the app is not running, a high-priority FCM data message or a VoIP push starts it
without a screen (`Runtime.startHeadless`): `init` runs, the push is handled (notify, ring,
fetch), nothing is drawn; `boot` and the first frame come when the user opens it, with that
state. A force-stopped Android app gets no pushes until it is opened again (Android's rule).

- Android: `addApp(.android_push = .{ .google_services = "../secrets/<app>-google-services.json" })`
  (kept outside the repository; `-Dgoogle-services=` overrides; missing: built without push)
  adds `com.google.firebase:firebase-messaging` (the one third-party library, through
  `ZuiPush.java`) and its dependencies, resolved without Gradle by `tools/maven.zig` into
  `%LOCALAPPDATA%/zig-core/maven` (`-Dmaven-cache=`). Firebase is initialised by hand from the
  json's project id, app id, API key and sender id. The manifest declares
  `com.wufour.zui.ZuiPush` with the `com.google.firebase.MESSAGING_EVENT` filter.
  `addApp(.android_deps = &.{"group:artifact:version"})` takes other Maven artifacts the same way.
- iOS: the push entitlement (`aps-environment`), `UIBackgroundModes` `voip` and
  `remote-notification`; links PushKit and UserNotifications.
- Web: the app's `sw.js` shows pushes (`push` event); it may post `{type:'zui-push', data}`
  to the page.
- Servers: `push.native.Sender` (FCM HTTP v1 and APNs) from `FCM_SERVICE_ACCOUNT_FILE`,
  `APNS_KEY_FILE`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_SANDBOX`; urgent
  messages are high-priority data messages, others carry a notification the system shows.
