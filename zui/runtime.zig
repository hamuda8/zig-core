//! The app loop, the same on every platform: an event becomes a message, `update` changes the
//! state, `view` builds a new tree, the layout engine places it, and the reconciler sends the
//! host only what changed.
//!
//! An app is a namespace with:
//!   pub const Msg = union(enum) { ... };          // what can happen
//!   pub const State = struct { ... };
//!   pub fn init() State
//!   pub fn update(state: *State, msg: Msg) void
//!     (or with `env: zui.Env`, or with `env` and `fx: zui.Fx(Msg)` to reach the network,
//!     timers, location and speech; their results come back as messages)
//!   pub fn view(state: *const State, ui: *zui.Ui(Msg)) void
//! and optionally `global_locale: []const u8`, `locales: []const zui.i18n.Locale`, and
//! `boot: Msg` (sent once after start, e.g. to read env.link or start location).

const std = @import("std");
const st = @import("style.zig");
const tree_mod = @import("tree.zig");
const layout = @import("layout.zig");
const reconcile = @import("reconcile.zig");
const i18n = @import("i18n.zig");
const Color = @import("color.zig").Color;
const icon_mod = @import("icon.zig");
const text_mod = @import("text.zig");
const barcode = @import("barcode.zig");
const calls = @import("calls.zig");
const sse = @import("sse.zig");
const keys = @import("keys.zig");

const Tree = tree_mod.Tree;

/// Safe-area insets in physical directions (status bar, notch, home indicator).
pub const Insets = struct { top: f32 = 0, right: f32 = 0, bottom: f32 = 0, left: f32 = 0 };

/// What the app's view can see about where it is drawn.
pub const Env = struct {
    width: f32 = 0,
    height: f32 = 0,
    safe: Insets = .{},
    dark: bool = false,
    rtl: bool = false,
    /// Time of the current display frame, in milliseconds on a monotonic clock: animations
    /// move by the time passed, so they run at the same speed at 60 and 120 frames a second.
    time_ms: f64 = 0,
    /// The address the app was opened with (web: path and query; phones: a deep link), else "";
    /// later the one set by `fx.setLink` / `fx.pushLink` or reached by going back.
    link: []const u8 = "",
    /// Wall-clock time in milliseconds since 1970-01-01 UTC, read when the message or frame
    /// arrived (`zui.now()` reads it at any moment).
    now_ms: i64 = 0,
    /// The device's local time zone at `now_ms`: minutes east of UTC (Damascus: +180).
    tz_offset_min: i32 = 0,
    /// The device has a network connection (as far as the platform knows).
    online: bool = true,
    /// The app is on screen (not in the background, not a hidden browser tab).
    visible: bool = true,
};

/// The app's `pub fn deviceEvent(e: zui.DeviceEvent) ?Msg` hears these (env.online and
/// env.visible change with them too).
pub const DeviceEvent = enum(u8) { online = 1, offline = 2, visible = 3, hidden = 4 };

/// A key pressed on a keyboard (the web, and hardware keyboards on phones). The app's
/// `pub fn keyEvent(e: zui.KeyEvent) ?Msg` hears these; returning a message takes the key (the
/// browser or the text field does not act on it as well), null leaves it to them.
pub const KeyEvent = struct {
    key: Key,
    shift: bool = false,
    /// Control, or Command on Apple keyboards.
    ctrl: bool = false,
    alt: bool = false,
    /// A text field has the keyboard.
    in_input: bool = false,
    /// `.letter`: which ('a' to 'z'). Letters reach the app only with Ctrl or Command held
    /// (shortcuts such as Ctrl+B); iOS offers Command with B, I, U, K and F, and Command+Shift with
    /// X, M, P and F (the others stay the system's: copy, paste, undo...).
    letter: u8 = 0,

    pub const Key = enum(u8) { escape = 1, enter = 2, up = 3, down = 4, left = 5, right = 6, tab = 7, letter = 8 };

    /// As hosts send it: the key's code, and modifiers as bits (shift 1, ctrl 2, alt 4, in a
    /// text field 8).
    pub fn of(code: u32, mods: u32) ?KeyEvent {
        if (code >= 'A' and code <= 'Z') return .{ .key = .letter, .letter = @intCast(code + 32), .shift = mods & 1 != 0, .ctrl = mods & 2 != 0, .alt = mods & 4 != 0, .in_input = mods & 8 != 0 };
        const k = std.enums.fromInt(Key, @as(u8, @intCast(@min(code, 255)))) orelse return null;
        return .{ .key = k, .shift = mods & 1 != 0, .ctrl = mods & 2 != 0, .alt = mods & 4 != 0, .in_input = mods & 8 != 0 };
    }
};

/// Where the cursor is in a text field, or what is selected there: byte offsets into its text
/// (start == end: just the cursor).
pub const Selection = struct { start: u32, end: u32 };

/// A microphone, camera or loudspeaker a call can use (`fx.mediaDevices`).
pub const MediaDevice = struct {
    kind: Kind,
    /// What `fx.useMediaDevice` takes.
    id: []const u8,
    /// The platform's name for it (a headset's name; may be empty).
    label: []const u8 = "",
    /// What it is, for the app's own words: "earpiece", "speaker", "bluetooth", "wired", "usb",
    /// "builtin", "front", "back", or "" (the web names its devices itself).
    type: []const u8 = "",
    /// In use now.
    current: bool = false,

    pub const Kind = enum(u8) { microphone = 1, camera = 2, speaker = 3 };
};

pub const Method = enum { GET, POST, PUT, PATCH, DELETE };

pub const Request = struct {
    url: []const u8,
    method: Method = .GET,
    body: []const u8 = "",
    content_type: []const u8 = "application/json",
    /// Extra headers, e.g. .{ "authorization", "Bearer ..." }.
    headers: []const [2][]const u8 = &.{},
    /// Comes back in the response: which request this answers (e.g. to ignore an older,
    /// slower answer once a newer request was made).
    tag: u32 = 0,
};

/// A finished request. `status` is 0 when the server could not be reached. `body` is only
/// valid during `update`: parse or copy what you keep.
pub const Response = struct {
    status: u16,
    body: []const u8,
    tag: u32 = 0,
    /// The response's headers, one "name: value\n" line each, names in lower case (the web;
    /// the phones give "" for now).
    headers: []const u8 = "",

    pub fn ok(r: Response) bool {
        return r.status >= 200 and r.status < 300;
    }

    /// A header's value (the name in any case), or null.
    pub fn header(r: Response, name: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, r.headers, '\n');
        while (it.next()) |line| {
            const at = std.mem.indexOf(u8, line, ": ") orelse continue;
            if (std.ascii.eqlIgnoreCase(line[0..at], name)) return line[at + 2 ..];
        }
        return null;
    }
};

pub const Location = union(enum) {
    fix: Fix,
    /// The user said no to location access.
    denied,
    /// No position (location off, no signal).
    unavailable,

    pub const Fix = struct {
        lat: f64,
        lng: f64,
        /// Metres.
        accuracy: f32 = 0,
        /// Degrees clockwise from north, when moving.
        heading: ?f32 = null,
        /// Metres per second.
        speed: ?f32 = null,
    };
};

pub const InputEvent = enum(u8) { focus = 1, blur = 2, submit = 3 };

pub const Notification = struct {
    /// Same id replaces; also what cancelNotify takes.
    id: u32,
    title: []const u8,
    body: []const u8 = "",
    /// Wakes the phone over the lock screen and keeps sounding until seen (a dispatch alarm,
    /// an incoming call): Android full-screen intent + insistent alarm sound; iOS a
    /// time-sensitive alert; the web a notification that stays until clicked.
    urgent: bool = false,
};

/// Something that happened on a WebSocket opened with `fx.openSocket`.
pub const SocketEvent = struct {
    kind: Kind,
    /// The socket (as `openSocket` returned it).
    socket: u32,
    /// A text message (`.message`), only valid during `update`.
    data: []const u8 = "",

    pub const Kind = enum(u8) { open = 1, message = 2, closed = 3 };
};

/// Microphone and camera (or the screen) for a call, opened with `fx.openMedia`.
pub const Media = struct {
    audio: bool = true,
    video: bool = false,
    /// The screen instead of the camera (desktop web only).
    screen: bool = false,
    /// The rear camera instead of the front one.
    back_camera: bool = false,
};

pub const MediaEvent = struct {
    kind: Kind,
    /// The stream (as `openMedia` returned it); show it with `ui.video`.
    stream: u32,
    /// `.failed`: "denied", "unavailable" or "unsupported".
    data: []const u8 = "",

    /// `.ended`: the user stopped sharing the screen, or the camera went away.
    pub const Kind = enum(u8) { ready = 1, failed = 2, ended = 3 };
};

/// A call connection to one other device, opened with `fx.openPeer`. Both sides open one and pass
/// each other's `.signal` messages through the app's own server; offers, answers, glare
/// ("perfect negotiation") and ICE restarts are handled inside.
pub const Peer = struct {
    /// ICE servers in RTCPeerConnection's JSON form: [{"urls":[...],"username":"","credential":""}].
    ice_servers: []const u8 = "[]",
    /// When both sides offer at once, the polite one gives way. Exactly one side is polite.
    polite: bool,
    /// The local stream to send (from `openMedia`), or 0 to only receive.
    stream: u32 = 0,
};

pub const PeerEvent = struct {
    kind: Kind,
    peer: u32,
    /// `.signal`: JSON for the other side's `fx.peerSignal` ({"description":{...}} or
    /// {"candidate":{...}}). `.state`: "connecting", "connected", "disconnected", "failed" or
    /// "closed". Only valid during `update`.
    data: []const u8 = "",
    /// `.track`: the other side's stream, for `ui.video` (its sound plays by itself).
    stream: u32 = 0,

    pub const Kind = enum(u8) { signal = 1, state = 2, track = 3 };
};

/// A voice message or a short video message, recorded with `fx.startRecording`. Audio is AAC
/// in MP4 ("audio/mp4", .m4a) and video H.264 + AAC in MP4 ("video/mp4"): what every host can
/// record and play back without libraries. A browser without MP4 recording falls back to WebM
/// (`RecordEvent.mime` says which). Show a video recording's camera with `ui.video(recorder)`.
pub const Recording = struct {
    /// Video with the camera (front unless `back_camera`); otherwise the microphone only.
    video: bool = false,
    back_camera: bool = false,
    /// Stops by itself (with `.done`) after this long.
    max_ms: u32 = 120_000,
};

pub const RecordEvent = struct {
    kind: Kind,
    recorder: u32,
    /// `.level`: the microphone's loudness, 0 to 1, about ten times a second.
    level: f32 = 0,
    /// `.level` and `.done`: how long it has recorded.
    duration_ms: u32 = 0,
    /// `.done`: the file; `.failed`: "denied", "unavailable" or "unsupported". Only valid
    /// during `update`.
    data: []const u8 = "",
    /// `.done`: "audio/mp4", "video/mp4" (or "audio/webm", "video/webm" on some browsers).
    mime: []const u8 = "",

    pub const Kind = enum(u8) { started = 1, level = 2, done = 3, failed = 4 };
};

/// Audio or video to play with `fx.play`: from a URL, or from bytes (copied). Show a video
/// with `ui.video(player)`.
pub const Playback = struct {
    url: []const u8 = "",
    data: []const u8 = "",
    /// For `data`: "audio/mp4", "video/mp4", "audio/webm"...
    mime: []const u8 = "",
    video: bool = false,
    autoplay: bool = true,
    loop: bool = false,
    /// Which sound it is, for the phone's volume and routing: a message or video (media), a
    /// ringtone (the ringer's volume), or a sound inside a call (ringback, connect, hang-up:
    /// the call's volume and earpiece or speaker). The web plays them all alike.
    stream: Stream = .media,

    pub const Stream = enum(u8) { media = 0, ringtone = 1, call = 2 };
};

pub const PlayEvent = struct {
    kind: Kind,
    player: u32,
    /// `.ready` and `.progress` (about four times a second while playing).
    position_ms: u32 = 0,
    duration_ms: u32 = 0,
    /// `.failed`: why.
    data: []const u8 = "",

    pub const Kind = enum(u8) { ready = 1, progress = 2, ended = 3, failed = 4 };
};

/// What `fx.pausePlayback`, `resumePlayback`, `seekPlayback` and `stopPlayback` ask a host.
pub const PlaybackControl = union(enum) {
    pause,
    play,
    seek: u32,
    stop,
    /// Speed in percent (100 normal, 150, 200), pitch kept.
    rate: u16,
};

/// A call the phone itself shows: the ringing screen over the lock screen, and the call in
/// Bluetooth, the car and the system's "in call" state. Android: a self-managed ConnectionService
/// and a full-screen call notification (the app declares com.wufour.zui.ZuiCallService and
/// ZuiCallReceiver in its manifest); iOS: CallKit. The web has no such screen: the app draws its own.
pub const Call = struct {
    /// The app's id for the call; events carry it back.
    id: []const u8,
    /// Who is calling, or being called.
    name: []const u8,
    video: bool = false,
    /// What kind of call, in the app's language ("Voice call", "مكالمة فيديو"), under the name
    /// on Android's ringing notification. Empty: "Voice call" / "Video call". iOS's CallKit
    /// names the kind itself, in the phone's language.
    label: []const u8 = "",
};

/// What the user did on the system's call screen. The app receives these through
/// `pub fn callEvent(e: zui.CallEvent) ?Msg`, also after being opened by answering a call it was
/// not running for. `id` is only valid during the call.
pub const CallEvent = struct {
    kind: Kind,
    id: []const u8,

    /// `.end`: hung up from outside the app (Bluetooth, the car, the notification).
    pub const Kind = enum(u8) { answer = 1, decline = 2, end = 3 };
};

/// Where a push token comes from. The app sends it to its server, which pushes through the
/// matching service: `.fcm` Firebase Cloud Messaging (Android), `.apns` Apple's alert pushes,
/// `.voip` Apple's VoIP pushes (PushKit: incoming calls), `.web` Web Push (the token is the
/// subscription's JSON: endpoint and keys).
pub const PushKind = enum(u8) { fcm = 1, apns = 2, voip = 3, web = 4 };

/// `fx.registerPush`: asks for permission where the platform needs it and delivers the token(s)
/// to the app's `pub fn pushToken(token: []const u8, kind: zui.PushKind) ?Msg` (again whenever
/// the platform changes them). Pushes arrive at `pub fn pushMessage(json: []const u8) ?Msg`:
/// the data map on Android, the payload on iOS. On the web the service worker shows them.
pub const PushOptions = struct {
    /// Web Push: the server's VAPID public key (base64url). Ignored on phones.
    web_key: []const u8 = "",
};

/// The platform's own pickers (`fx.pickDate`, `fx.pickTime`, `fx.pickOption`).
pub const PickKind = enum(u8) { date = 1, time = 2, option = 3 };

pub const DatePick = struct {
    /// "YYYY-MM-DD" to start on; "" for today.
    value: []const u8 = "",
    /// The first and last days that can be chosen ("YYYY-MM-DD"), or "".
    min: []const u8 = "",
    max: []const u8 = "",
};

pub const TimePick = struct {
    /// "HH:MM" (24 hours) to start on; "" for now.
    value: []const u8 = "",
};

pub const OptionPick = struct {
    /// Shown above the list where the platform has a place for it (Android, iOS).
    title: []const u8 = "",
    options: []const []const u8,
    /// The option marked as chosen.
    selected: ?u32 = null,
};

/// A photo from the camera or the gallery (`fx.pickPhoto`), as JPEG or PNG.
pub const PhotoPick = struct {
    /// Take one with the camera (else choose one from the gallery). Where there is no camera
    /// (a desktop browser) the browser asks for a file.
    camera: bool = false,
    /// The longest side, in pixels, after scaling down (a phone's photo is 4000 or more).
    max_size: u32 = 1600,
    /// JPEG quality, 1 to 100.
    quality: u8 = 85,
    /// PNG keeps transparency (a logo); JPEG is smaller (a photo).
    format: enum { jpeg, png } = .jpeg,
};

pub const FilePick = struct {
    /// What can be chosen: MIME types and patterns, comma-separated ("image/*,application/pdf",
    /// "text/csv"); "" for anything.
    accept: []const u8 = "",
};

/// A file the user chose. Only valid during `update`: copy what you keep.
pub const File = struct {
    data: []const u8,
    name: []const u8 = "",
    mime: []const u8 = "",
    /// Photos: the size after scaling.
    width: u32 = 0,
    height: u32 = 0,
};

/// A file the app made, for `fx.saveFile`.
pub const SaveFile = struct {
    name: []const u8,
    mime: []const u8 = "application/octet-stream",
    data: []const u8,
    /// Offer it to other apps (the share sheet) rather than only saving it. The web downloads
    /// it unless the browser can share files; iOS always shows its share sheet (which saves to
    /// Files too); Android saves it to Downloads, and with `share` also opens the share sheet.
    share: bool = false,
};

/// A stream of Server-Sent Events (`fx.openEvents`): a GET request whose answer never ends.
pub const EventStream = struct {
    url: []const u8,
    /// Extra headers, e.g. .{ "authorization", "Bearer ..." } (EventSource cannot send these).
    headers: []const [2][]const u8 = &.{},
};

/// Something that happened on an event stream. Slices are only valid during `update`.
pub const ServerEvent = struct {
    kind: Kind,
    /// The stream (as `openEvents` returned it).
    stream: u32,
    /// `.message`: the event's name ("message" unless the server named it), its data (the
    /// `data:` lines joined by newlines) and the last event id the server gave.
    event: []const u8 = "",
    data: []const u8 = "",
    id: []const u8 = "",
    /// `.failed` and `.closed`: the HTTP status of the connection that ended (200 when an open
    /// stream dropped), 0 when the server could not be reached.
    status: u16 = 0,

    /// `.open`: connected (again). `.failed`: the connection was lost or refused; zui
    /// connects again after the server's `retry` time (3 s by default), sending
    /// Last-Event-ID. `.closed`: the server said no for good (a 4xx status other than 408
    /// and 429, or 204): no more events.
    pub const Kind = enum(u8) { open = 1, message = 2, failed = 3, closed = 4 };
};

/// `fx.webAuth`: a sign-in page shown inside the app (Wufour's, `zui.wufour`).
pub const WebAuth = struct {
    /// The page to open.
    url: []const u8,
    /// The address that ends it: a navigation to anything starting with this is not loaded,
    /// and its full address comes back as `.ok`.
    callback_prefix: []const u8,
    /// The page is one of the app's own: its top bar shows this title and a back arrow (which
    /// cancels), in the app's colours; it is mirrored for right-to-left languages.
    title: []const u8 = "",
    /// The top bar, its title and arrow, and the page behind the spinner while Wufour loads.
    /// Null: white / near-black (dark mode: the reverse).
    bar: ?Color = null,
    ink: ?Color = null,
    background: ?Color = null,
};

pub const WebAuthResult = union(enum) {
    /// The callback address, with its query (e.g. `...?token=...`). Only valid during `update`.
    ok: []const u8,
    /// The user closed the page (or went Back from its first page).
    cancelled,
};

/// What a host draws around `fx.webAuth`'s page (colours as 0xAARRGGBB).
pub const WebAuthLook = struct { title: []const u8 = "", bar: u32 = 0xffffffff, ink: u32 = 0xff1c1c20, background: u32 = 0xffffffff, rtl: bool = false };

/// What `update` may ask of the platform. Each result arrives later as a message.
pub fn Fx(comptime Msg: type) type {
    return struct {
        vt: *const VTable,

        const Self = @This();

        pub const VTable = struct {
            fetch: *const fn (Request, *const fn (Response) Msg) void,
            after: *const fn (u32, Msg) void,
            location: *const fn (?*const fn (Location) Msg) void,
            speak: *const fn ([]const u8) void,
            set_link: *const fn ([]const u8) void,
            reduce_motion: *const fn (bool) void,
            focus: *const fn (u64) void,
            selection: *const fn (u64) ?Selection,
            select_text: *const fn (u64, Selection) void,
            scroll_to: *const fn (u64, ScrollTarget, bool) void,
            scan_barcode: *const fn (Scan, *const fn (ScanEvent) Msg) u32,
            stop_scan: *const fn (u32) void,
            post: *const fn ([]const u8) void,
            open_socket: *const fn ([]const u8, *const fn (SocketEvent) Msg) u32,
            send_socket: *const fn (u32, []const u8) void,
            close_socket: *const fn (u32) void,
            copy: *const fn ([]const u8) void,
            open_url: *const fn ([]const u8, bool) void,
            background_location: *const fn (bool, []const u8, []const u8) void,
            notify: *const fn (Notification) void,
            cancel_notify: *const fn (u32) void,
            open_media: *const fn (Media, *const fn (MediaEvent) Msg) u32,
            media_enable: *const fn (u32, bool, bool) void,
            switch_camera: *const fn (u32) void,
            media_devices: *const fn (u32, *const fn ([]const MediaDevice) Msg) void,
            use_media_device: *const fn (u32, MediaDevice.Kind, []const u8) void,
            close_media: *const fn (u32) void,
            open_peer: *const fn (Peer, *const fn (PeerEvent) Msg) u32,
            peer_signal: *const fn (u32, []const u8) void,
            peer_stream: *const fn (u32, u32) void,
            close_peer: *const fn (u32) void,
            start_recording: *const fn (Recording, *const fn (RecordEvent) Msg) u32,
            stop_recording: *const fn (u32, bool) void,
            play: *const fn (Playback, *const fn (PlayEvent) Msg) u32,
            control_playback: *const fn (u32, PlaybackControl) void,
            ring_call: *const fn (Call) void,
            start_call: *const fn (Call) void,
            call_connected: *const fn ([]const u8) void,
            end_call: *const fn ([]const u8) void,
            push_link: *const fn ([]const u8) void,
            vibrate: *const fn (u32) void,
            beep: *const fn () void,
            keep_awake: *const fn (bool) void,
            pick_date: *const fn (DatePick, *const fn ([]const u8) Msg) void,
            pick_time: *const fn (TimePick, *const fn ([]const u8) Msg) void,
            pick_option: *const fn (OptionPick, *const fn (u32) Msg) void,
            pick_photo: *const fn (PhotoPick, *const fn (File) Msg) void,
            pick_file: *const fn (FilePick, *const fn (File) Msg) void,
            save_file: *const fn (SaveFile) void,
            open_events: *const fn (EventStream, *const fn (ServerEvent) Msg) u32,
            close_events: *const fn (u32) void,
            key: *const fn (keys.Request, *const fn (keys.Result) Msg) u32,
            register_push: *const fn (PushOptions) void,
            web_auth: *const fn (WebAuth, *const fn (WebAuthResult) Msg) void,
        };

        /// An HTTP request; `done` turns the response into a message. Relative URLs are
        /// relative to the page on the web.
        pub fn fetch(fx: Self, req: Request, done: *const fn (Response) Msg) void {
            fx.vt.fetch(req, done);
        }

        /// `msg` after `ms` milliseconds.
        pub fn after(fx: Self, ms: u32, msg: Msg) void {
            fx.vt.after(ms, msg);
        }

        /// Follows the device position (asking permission the first time); null stops.
        pub fn watchLocation(fx: Self, on: ?*const fn (Location) Msg) void {
            fx.vt.location(on);
        }

        /// Says `text` aloud in the app's language, interrupting what was being said.
        pub fn speak(fx: Self, text: []const u8) void {
            fx.vt.speak(text);
        }

        /// The address to reopen this state with (the web page's URL), in place of the current
        /// one: no new history entry. Other platforms keep it for sharing.
        pub fn setLink(fx: Self, link: []const u8) void {
            fx.vt.set_link(link);
        }

        /// Turns every Style.transition off (true) or back on: the app's "animations" switch.
        /// Spinners keep turning (they say something is happening).
        pub fn reduceMotion(fx: Self, on: bool) void {
            fx.vt.reduce_motion(on);
        }

        /// Goes to a new address with a history entry behind it: Back (the browser's, Android's,
        /// the iOS edge swipe) returns to the current one, and the app hears it through
        /// `pub fn linkEvent(link: []const u8) ?Msg` (env.link changes too). The web uses the
        /// browser's history; the phones keep the same history in zui.
        pub fn pushLink(fx: Self, link: []const u8) void {
            fx.vt.push_link(link);
        }

        /// Vibrates for about `ms` milliseconds (iOS has one fixed vibration).
        pub fn vibrate(fx: Self, ms: u32) void {
            fx.vt.vibrate(ms);
        }

        /// A short beep (a scan was read, a new job arrived).
        pub fn beep(fx: Self) void {
            fx.vt.beep();
        }

        /// The platform's date picker (web <input type=date>, Android DatePickerDialog, iOS
        /// UIDatePicker); `done` gets the day as "YYYY-MM-DD". The app draws the field itself and
        /// calls this when it is pressed. Nothing comes back when the picker is dismissed.
        pub fn pickDate(fx: Self, o: DatePick, done: *const fn ([]const u8) Msg) void {
            fx.vt.pick_date(o, done);
        }

        /// The platform's time picker; `done` gets "HH:MM" (24 hours).
        pub fn pickTime(fx: Self, o: TimePick, done: *const fn ([]const u8) Msg) void {
            fx.vt.pick_time(o, done);
        }

        /// The platform's list of options (web <select>, an Android dialog, an iOS action
        /// sheet); `done` gets the index of the one chosen.
        pub fn pickOption(fx: Self, o: OptionPick, done: *const fn (u32) Msg) void {
            fx.vt.pick_option(o, done);
        }

        /// A photo, taken with the camera or chosen from the gallery, scaled down to
        /// `max_size` and sent to `done` as JPEG (web <input type=file capture>, Android's
        /// camera and photo picker, iOS UIImagePickerController). Nothing comes back when the
        /// user cancels. iOS apps need NSCameraUsageDescription in their Info.plist.
        pub fn pickPhoto(fx: Self, o: PhotoPick, done: *const fn (File) Msg) void {
            fx.vt.pick_photo(o, done);
        }

        /// Any file: its bytes, name and MIME type.
        pub fn pickFile(fx: Self, o: FilePick, done: *const fn (File) Msg) void {
            fx.vt.pick_file(o, done);
        }

        /// Saves or shares a file the app made (a report, a label): see `SaveFile.share`.
        pub fn saveFile(fx: Self, f: SaveFile) void {
            fx.vt.save_file(f);
        }

        /// Follows a stream of Server-Sent Events (text/event-stream) with any headers; each
        /// event arrives through `on`, and lost connections are made again. Returns its id.
        pub fn openEvents(fx: Self, src: EventStream, on: *const fn (ServerEvent) Msg) u32 {
            return fx.vt.open_events(src, on);
        }

        pub fn closeEvents(fx: Self, stream: u32) void {
            fx.vt.close_events(stream);
        }

        /// A request to the secure key store (zui/keys.zig): keys the app uses by name and can
        /// never read. The answer arrives through `done`; returns the request's id.
        pub fn key(fx: Self, req: keys.Request, done: *const fn (keys.Result) Msg) u32 {
            return fx.vt.key(req, done);
        }

        /// Keeps the screen on while `on` (a courier's navigation, a scanner).
        pub fn keepAwake(fx: Self, on: bool) void {
            fx.vt.keep_awake(on);
        }

        /// Looks for barcodes with the camera (Code 128, QR): `.started` once it runs, `.found` with
        /// each code read (the same code again only after 1.5 s), `.failed` (denied, no camera,
        /// unsupported). `ui.video(id, ...)` shows what the camera sees. Returns its id.
        pub fn scanBarcode(fx: Self, o: Scan, on: *const fn (ScanEvent) Msg) u32 {
            return fx.vt.scan_barcode(o, on);
        }

        pub fn stopScan(fx: Self, scanner: u32) void {
            fx.vt.stop_scan(scanner);
        }

        /// Scrolls the scroll view with key `scroll_key` (`beginScrollWith`) to `target`, after the
        /// next draw, smoothly when `animated`.
        pub fn scrollTo(fx: Self, scroll_key: u64, target: ScrollTarget, animated: bool) void {
            fx.vt.scroll_to(scroll_key, target, animated);
        }

        /// Puts the cursor in the input with this key (after the next draw).
        pub fn focus(fx: Self, input_key: u64) void {
            fx.vt.focus(input_key);
        }

        /// The cursor or the selection in the text field with `input_key` now (null when it is not
        /// on screen, or the platform cannot tell).
        pub fn selection(fx: Self, input_key: u64) ?Selection {
            return fx.vt.selection(input_key);
        }

        /// Puts the cursor (start == end) or a selection into the text field, which gets the
        /// keyboard; after this update's text is on screen (so a changed text can be selected).
        pub fn selectText(fx: Self, input_key: u64, s: Selection) void {
            fx.vt.select_text(input_key, s);
        }

        /// A JSON message to the page that embeds this one (web: postMessage to the parent).
        /// Its answers arrive through the app's `hostMessage`.
        pub fn post(fx: Self, json: []const u8) void {
            fx.vt.post(json);
        }

        /// Opens a WebSocket; its events come back through `on`. Returns its id.
        pub fn openSocket(fx: Self, url: []const u8, on: *const fn (SocketEvent) Msg) u32 {
            return fx.vt.open_socket(url, on);
        }

        pub fn sendSocket(fx: Self, socket: u32, text: []const u8) void {
            fx.vt.send_socket(socket, text);
        }

        pub fn closeSocket(fx: Self, socket: u32) void {
            fx.vt.close_socket(socket);
        }

        /// Keeps following the position with the screen off (a courier's shift), together with
        /// watchLocation. Android shows an ongoing notification with `title` and `text` (the
        /// app declares com.wufour.zui.ZuiLocationService in its manifest); iOS shows its blue
        /// location indicator (the app lists "location" in UIBackgroundModes). The web cannot.
        pub fn backgroundLocation(fx: Self, on: bool, title: []const u8, text: []const u8) void {
            fx.vt.background_location(on, title, text);
        }

        /// Shows a notification now (asking permission the first time). Tapping it opens the app.
        pub fn notify(fx: Self, n: Notification) void {
            fx.vt.notify(n);
        }

        pub fn cancelNotify(fx: Self, id: u32) void {
            fx.vt.cancel_notify(id);
        }

        /// Asks for the microphone and camera (or the screen); `.ready` arrives once they are on.
        /// Returns the stream's id.
        pub fn openMedia(fx: Self, m: Media, on: *const fn (MediaEvent) Msg) u32 {
            return fx.vt.open_media(m, on);
        }

        /// Mutes or unmutes the stream's sound and picture (the other side sees silence/black).
        pub fn mediaEnable(fx: Self, stream: u32, audio: bool, video: bool) void {
            fx.vt.media_enable(stream, audio, video);
        }

        /// Front camera to back camera and back, also on every connection sending this stream.
        pub fn switchCamera(fx: Self, stream: u32) void {
            fx.vt.switch_camera(stream);
        }

        /// The microphones, cameras and loudspeakers (or earpiece, Bluetooth...) a call on
        /// `stream` can use, marked where in use. The list is only valid during `update`.
        pub fn mediaDevices(fx: Self, stream: u32, on: *const fn ([]const MediaDevice) Msg) void {
            fx.vt.media_devices(stream, on);
        }

        /// Uses that device for the call on `stream` (the connections get the new track; a
        /// loudspeaker is where every call sound plays).
        pub fn useMediaDevice(fx: Self, stream: u32, kind: MediaDevice.Kind, id: []const u8) void {
            fx.vt.use_media_device(stream, kind, id);
        }

        /// Turns the microphone and camera off.
        pub fn closeMedia(fx: Self, stream: u32) void {
            fx.vt.close_media(stream);
        }

        /// Starts a call connection; its signals, state and the other side's stream arrive
        /// through `on`. Returns its id.
        pub fn openPeer(fx: Self, p: Peer, on: *const fn (PeerEvent) Msg) u32 {
            return fx.vt.open_peer(p, on);
        }

        /// A `.signal` the other side sent.
        pub fn peerSignal(fx: Self, peer: u32, json: []const u8) void {
            fx.vt.peer_signal(peer, json);
        }

        /// Sends another local stream instead (the screen instead of the camera, and back).
        pub fn peerStream(fx: Self, peer: u32, stream: u32) void {
            fx.vt.peer_stream(peer, stream);
        }

        pub fn closePeer(fx: Self, peer: u32) void {
            fx.vt.close_peer(peer);
        }

        /// Starts recording a voice or video message; events (level, done with the file) go to
        /// `on`. Returns the recorder (for `stopRecording`, and `ui.video` for video).
        pub fn startRecording(fx: Self, r: Recording, on: *const fn (RecordEvent) Msg) u32 {
            return fx.vt.start_recording(r, on);
        }

        /// Finishes: `.done` follows with the file.
        pub fn stopRecording(fx: Self, recorder: u32) void {
            fx.vt.stop_recording(recorder, false);
        }

        /// Stops and throws the recording away (no `.done`).
        pub fn cancelRecording(fx: Self, recorder: u32) void {
            fx.vt.stop_recording(recorder, true);
        }

        /// Plays audio or video; `.ready` (with the duration), `.progress` and `.ended` go to
        /// `on`. Returns the player (for the controls, and `ui.video` for video).
        pub fn play(fx: Self, p: Playback, on: *const fn (PlayEvent) Msg) u32 {
            return fx.vt.play(p, on);
        }

        pub fn pausePlayback(fx: Self, player: u32) void {
            fx.vt.control_playback(player, .pause);
        }

        pub fn resumePlayback(fx: Self, player: u32) void {
            fx.vt.control_playback(player, .play);
        }

        pub fn seekPlayback(fx: Self, player: u32, position_ms: u32) void {
            fx.vt.control_playback(player, .{ .seek = position_ms });
        }

        /// Stops and releases the player (no more events).
        pub fn stopPlayback(fx: Self, player: u32) void {
            fx.vt.control_playback(player, .stop);
        }

        /// Plays faster or slower: `percent` of normal speed (voice messages at 150, 200).
        pub fn playbackRate(fx: Self, player: u32, percent: u16) void {
            fx.vt.control_playback(player, .{ .rate = percent });
        }

        /// An incoming call: the phone rings and shows its call screen, even when locked.
        pub fn ringCall(fx: Self, c: Call) void {
            fx.vt.ring_call(c);
        }

        /// An outgoing call, so the system knows the phone is in a call (audio, Bluetooth).
        pub fn startCall(fx: Self, c: Call) void {
            fx.vt.start_call(c);
        }

        /// The other side is connected (the call's timer starts).
        pub fn callConnected(fx: Self, id: []const u8) void {
            fx.vt.call_connected(id);
        }

        /// Stops ringing / ends the call on the system's side.
        pub fn endCall(fx: Self, id: []const u8) void {
            fx.vt.end_call(id);
        }

        /// Push notifications: see `PushOptions`. Call it after sign-in; the token arrives at the
        /// app's `pushToken`.
        pub fn registerPush(fx: Self, o: PushOptions) void {
            fx.vt.register_push(o);
        }

        /// Opens a sign-in page inside the app, with no address bar or other browser around it
        /// (Android: a full-screen WebView over the app; iOS: a WKWebView presented over it),
        /// with JavaScript, storage and cookies, so the site's own session is remembered. When
        /// the page goes to an address starting with `o.callback_prefix`, that address is not
        /// loaded: `done` gets it as `.ok` and the page closes. Closing it gives `.cancelled`.
        /// One at a time: a new one replaces the last (which then answers nothing).
        /// The web navigates this page to `o.url` and never calls `done`: the app's server
        /// receives the callback, sets its cookies as before, and the app starts again.
        pub fn webAuth(fx: Self, o: WebAuth, done: *const fn (WebAuthResult) Msg) void {
            fx.vt.web_auth(o, done);
        }

        /// Puts `text` on the clipboard.
        pub fn copy(fx: Self, text: []const u8) void {
            fx.vt.copy(text);
        }

        /// Opens an address: in place of this page (web) or in the browser / the app that
        /// handles it; `new_window` opens a new tab on the web.
        pub fn openUrl(fx: Self, url: []const u8, new_window: bool) void {
            fx.vt.open_url(url, new_window);
        }
    };
}

/// What a host reports about a pressable view. `context` is a secondary click (the web's
/// context menu); `hover_in` / `hover_out` the mouse coming and going (desktop web).
pub const Event = enum(u8) { press_in = 1, press_out = 2, press = 3, context = 4, hover_in = 5, hover_out = 6 };

/// Where a scroll view is (`ScrollOptions.on_scroll`), along the way it scrolls, in points.
pub const ScrollEvent = struct {
    offset: f32,
    /// Length of what scrolls, and of the view showing it.
    content: f32,
    viewport: f32,
    at_start: bool,
    at_end: bool,
    /// It got to the start / the end with this move (load older messages, the next page).
    reached_start: bool = false,
    reached_end: bool = false,
};

/// Where `fx.scrollTo` goes.
/// What `fx.scanBarcode` looks for.
pub const Scan = struct {
    formats: barcode.Formats = .{},
    back_camera: bool = true,
};

/// What a barcode scanner saw. `text` and `data` are only valid during `update`.
pub const ScanEvent = struct {
    kind: Kind,
    scanner: u32,
    format: barcode.Format = .qr,
    text: []const u8 = "",
    /// `.failed`: "denied", "unavailable" or "unsupported".
    data: []const u8 = "",

    pub const Kind = enum(u8) { started = 1, found = 2, failed = 3 };
};

pub const ScrollTarget = union(enum) {
    start,
    end,
    /// Points from the start.
    offset: f32,
    /// The child (at any depth) with this key, at the start of the view.
    child: u64,
};

/// A finger, pen or mouse on a view that listens for pointers (`on_pointer`). Coordinates are in
/// the view's own points.
pub const Pointer = struct {
    kind: Kind,
    /// Stable while the finger is down; mouse is 0.
    id: u32,
    x: f32,
    y: f32,
    /// Mouse wheel: positive scrolls down (zooms out on a map).
    wheel: f32 = 0,
    time_ms: i64 = 0,
    /// The key of the view that heard it (`BoxOptions.key`): which of two maps on a page.
    key: u64 = 0,

    pub const Kind = enum(u8) { down = 1, move = 2, up = 3, cancel = 4, wheel = 5 };
};

/// Stable identity for a child among its siblings, from a string or an integer.
pub fn key(v: anytype) u64 {
    return switch (@typeInfo(@TypeOf(v))) {
        .int, .comptime_int => std.hash.Wyhash.hash(1, std.mem.asBytes(&@as(u64, @intCast(v)))),
        else => std.hash.Wyhash.hash(0, v),
    };
}

/// The builder an app's `view` writes into.
pub fn Ui(comptime Msg: type) type {
    return struct {
        tree: *Tree,
        env: Env,
        presses: std.ArrayList(Binding(Msg)) = .empty,
        pointers: std.ArrayList(Binding(PointerHandler(Msg))) = .empty,
        /// Long presses, secondary clicks, hovers, links in text, scroll views.
        holds: std.ArrayList(Binding(Msg)) = .empty,
        contexts: std.ArrayList(Binding(Msg)) = .empty,
        hovers: std.ArrayList(Binding(*const fn (bool) Msg)) = .empty,
        links: std.ArrayList(Binding(LinkHandler(Msg))) = .empty,
        scrolls: std.ArrayList(Binding(*const fn (ScrollEvent) Msg)) = .empty,
        /// Sent once at the next display frame (animation), if set.
        frame_msg: ?Msg = null,
        changes: std.ArrayList(Binding(*const fn ([]const u8) Msg)) = .empty,
        inputs: std.ArrayList(Binding(InputHandlers(Msg))) = .empty,
        background: ?Color = null,
        /// What Back sends while this frame is on screen (`onBack`).
        back_msg: ?Msg = null,
        /// Set if memory ran out while building; the frame is then dropped.
        failed: bool = false,

        const Self = @This();

        pub const BoxOptions = struct {
            key: u64 = 0,
            on_press: ?Msg = null,
            /// Held for half a second (the phones give a haptic tick). Takes the place of the
            /// press that would follow.
            on_long_press: ?Msg = null,
            /// A secondary click (right click, the web's context menu). On touch screens a long
            /// press sends it when there is no `on_long_press`.
            on_context: ?Msg = null,
            /// The mouse comes (true) and goes (false), on desktop web. `hover_background` and
            /// `hover_opacity` need no message.
            on_hover: ?*const fn (bool) Msg = null,
            /// Raw pointer events (gestures): pan, pinch, rotate, wheel. They carry `key`.
            on_pointer: ?*const fn (Pointer) Msg = null,
            /// What the box does, in words, for a button with only an icon: read by screen
            /// readers, the web's tooltip (title), and shown for a moment on a long press on the
            /// phones (when there is no `on_long_press`).
            label: []const u8 = "",
        };

        /// A run of text in `richText`.
        pub const Span = struct {
            text: []const u8,
            bold: bool = false,
            italic: bool = false,
            mono: bool = false,
            underline: bool = false,
            strike: bool = false,
            /// null: the text's colour.
            color: ?Color = null,
            /// Pressing this run sends it (a link). Taps beside links reach the views around.
            link: ?Msg = null,
        };

        pub const TextOptions = struct {
            key: u64 = 0,
            /// The user can select the text and copy it.
            selectable: bool = false,
        };

        pub const ScrollOptions = struct {
            key: u64 = 0,
            /// Starts at the end, and stays there while content is added at the end, as long as
            /// the user is at the end (a chat).
            anchor_end: bool = false,
            /// Content added before what is on screen (older messages) does not move it. Needs
            /// keyed children.
            keep_position: bool = false,
            /// Where it is, as it scrolls (once a display frame), and when it reaches an end.
            on_scroll: ?*const fn (ScrollEvent) Msg = null,
        };

        pub const PathStyle = struct {
            color: Color,
            width: f32 = 4,
            dash: [2]f32 = .{ 0, 0 },
            round: bool = true,
            fill: ?Color = null,
        };

        pub const VideoOptions = struct { mirror: bool = false, cover: bool = true };

        pub const InputOptions = struct {
            key: u64 = 0,
            value: []const u8 = "",
            placeholder: []const u8 = "",
            /// Gets the new text; it is only valid during `update`, so copy what you keep.
            on_change: ?*const fn ([]const u8) Msg = null,
            on_focus: ?Msg = null,
            on_blur: ?Msg = null,
            /// The keyboard's enter / search key (not in a multi-line input, where enter is a
            /// new line).
            on_submit: ?Msg = null,
            /// The cursor moved or the selection changed (a format bar over a selection).
            on_select: ?*const fn (Selection) Msg = null,
            style: st.Style = .{},
            /// A password: the text is hidden.
            secure: bool = false,
            keyboard: tree_mod.Keyboard = .text,
            /// The label of the enter key.
            return_key: tree_mod.ReturnKey = .default,
            /// Several lines that wrap; the input grows with its text (up to `style.max_height`,
            /// then it scrolls).
            multiline: bool = false,
            /// At most this many characters can be typed (HTML maxlength); 0: no limit.
            max_length: u32 = 0,
        };

        /// Memory that lives until this frame's tree is dropped.
        pub fn arena(ui: *Self) std.mem.Allocator {
            return ui.tree.allocator();
        }

        /// Opens a box; everything until `end` goes inside it.
        pub fn begin(ui: *Self, style: st.Style, o: BoxOptions) void {
            const hover = o.on_hover != null or style.hover_background != null or style.hover_opacity != null;
            const i = ui.tree.open(.{
                .kind = .view,
                .style = style,
                .key = o.key,
                .label = o.label,
                .pressable = o.on_press != null or o.on_long_press != null or o.on_context != null,
                .pointer = o.on_pointer != null,
                .gestures = .{ .long_press = o.on_long_press != null, .context = o.on_context != null, .hover = hover },
            }) catch return ui.fail();
            const a = ui.arena();
            if (o.on_press) |m| ui.presses.append(a, .{ .node = i, .value = m }) catch ui.fail();
            if (o.on_long_press) |m| ui.holds.append(a, .{ .node = i, .value = m }) catch ui.fail();
            if (o.on_context) |m| ui.contexts.append(a, .{ .node = i, .value = m }) catch ui.fail();
            if (o.on_hover) |f| ui.hovers.append(a, .{ .node = i, .value = f }) catch ui.fail();
            if (o.on_pointer) |f| ui.pointers.append(a, .{ .node = i, .value = .{ .f = f, .key = o.key } }) catch ui.fail();
        }

        /// Opens a box whose content scrolls along `style.direction`.
        pub fn beginScroll(ui: *Self, style: st.Style, k: u64) void {
            const kind: tree_mod.Kind = if (style.direction == .row) .scroll_x else .scroll;
            _ = ui.tree.open(.{ .kind = kind, .style = style, .key = k }) catch return ui.fail();
        }

        /// `beginScroll` that starts at the end, keeps its place, or reports where it is. Move
        /// it with `fx.scrollTo(o.key, ...)`.
        pub fn beginScrollWith(ui: *Self, style: st.Style, o: ScrollOptions) void {
            const kind: tree_mod.Kind = if (style.direction == .row) .scroll_x else .scroll;
            const i = ui.tree.open(.{ .kind = kind, .style = style, .key = o.key, .scroll_mode = .{
                .anchor_end = o.anchor_end,
                .keep_position = o.keep_position,
                .report = o.on_scroll != null,
            } }) catch return ui.fail();
            if (o.on_scroll) |f| ui.scrolls.append(ui.arena(), .{ .node = i, .value = f }) catch ui.fail();
        }

        pub fn end(ui: *Self) void {
            ui.tree.close();
        }

        /// Shows `s` as it is. Use `t` for text that should be translated.
        pub fn text(ui: *Self, s: []const u8, style: st.Style) void {
            ui.textWith(s, style, .{});
        }

        pub fn textKeyed(ui: *Self, s: []const u8, style: st.Style, k: u64) void {
            ui.textWith(s, style, .{ .key = k });
        }

        /// `text` with a key, or selectable.
        pub fn textWith(ui: *Self, s: []const u8, style: st.Style, o: TextOptions) void {
            const shown = if (style.uppercase) text_mod.upper(ui.arena(), s) catch return ui.fail() else s;
            _ = ui.tree.add(.{ .kind = if (o.selectable) .text_select else .text, .style = style, .text = shown, .key = o.key }) catch ui.fail();
        }

        /// One text of runs drawn differently: bold, italic, monospaced, coloured, underlined,
        /// struck through, and links that send their own message. It wraps and is measured as
        /// one text.
        pub fn richText(ui: *Self, spans: []const Span, style: st.Style, o: TextOptions) void {
            const a = ui.arena();
            var all: std.ArrayList(u8) = .empty;
            const runs = a.alloc(tree_mod.Span, spans.len) catch return ui.fail();
            var links: i32 = 0;
            for (spans, runs) |sp, *run| {
                const shown = if (style.uppercase) text_mod.upper(a, sp.text) catch return ui.fail() else sp.text;
                run.* = .{
                    .start = @intCast(all.items.len),
                    .len = @intCast(shown.len),
                    .bold = sp.bold,
                    .italic = sp.italic,
                    .mono = sp.mono,
                    .underline = sp.underline,
                    .strike = sp.strike,
                    .color = if (sp.color) |c| c.argb() else 0,
                    .link = if (sp.link != null) links else -1,
                };
                if (sp.link != null) links += 1;
                all.appendSlice(a, shown) catch return ui.fail();
            }
            const i = ui.tree.add(.{ .kind = if (o.selectable) .text_select else .text, .style = style, .text = all.items, .key = o.key, .spans = runs }) catch return ui.fail();
            for (spans, runs) |sp, run| if (sp.link) |m| {
                ui.links.append(a, .{ .node = i, .value = .{ .index = @intCast(run.link), .msg = m } }) catch ui.fail();
            };
        }

        pub fn input(ui: *Self, o: InputOptions) void {
            const i = ui.tree.add(.{
                .kind = if (o.multiline) .text_area else .input,
                .style = o.style,
                .key = o.key,
                .text = o.value,
                .placeholder = o.placeholder,
                .input_type = .{ .keyboard = o.keyboard, .return_key = o.return_key, .secure = o.secure and !o.multiline, .max_length = o.max_length },
            }) catch return ui.fail();
            if (o.on_change) |f| ui.changes.append(ui.arena(), .{ .node = i, .value = f }) catch ui.fail();
            if (o.on_focus != null or o.on_blur != null or o.on_submit != null or o.on_select != null)
                ui.inputs.append(ui.arena(), .{ .node = i, .value = .{ .focus = o.on_focus, .blur = o.on_blur, .submit = o.on_submit, .select = o.on_select } }) catch ui.fail();
        }

        /// A stream's moving picture (from `fx.openMedia` or a peer's `.track`), sized by `style`.
        /// `mirror` flips it (your own front camera); `cover` fills the box, cropping.
        pub fn video(ui: *Self, stream: u32, o: VideoOptions, style: st.Style, k: u64) void {
            _ = ui.tree.add(.{ .kind = .video, .style = style, .key = k, .video = .{ .stream = stream, .mirror = o.mirror, .cover = o.cover } }) catch ui.fail();
        }

        /// A picture loaded from `url` (the host caches it), sized by `style`.
        pub fn image(ui: *Self, url: []const u8, style: st.Style, k: u64) void {
            _ = ui.tree.add(.{ .kind = .image, .style = style, .text = url, .key = k }) catch ui.fail();
        }

        pub const ImageOptions = struct {
            /// Request headers, e.g. .{ "authorization", "Bearer ..." } for a picture only its
            /// owner may see.
            headers: []const [2][]const u8 = &.{},
        };

        /// `image` with request headers.
        pub fn imageWith(ui: *Self, url: []const u8, o: ImageOptions, style: st.Style, k: u64) void {
            var block: std.ArrayList(u8) = .empty;
            for (o.headers) |h| block.print(ui.arena(), "{s}: {s}\n", .{ h[0], h[1] }) catch return ui.fail();
            _ = ui.tree.add(.{ .kind = .image, .style = style, .text = url, .key = k, .headers = block.items }) catch ui.fail();
        }

        /// A picture from memory (PNG, JPEG, GIF or WebP bytes: a decrypted photo), known by
        /// `cache_key`: the bytes reach the platform only when the key changes, and a picture
        /// already decoded under that key is shown at once. The bytes are only read while this
        /// frame is drawn.
        pub fn imageBytes(ui: *Self, bytes: []const u8, cache_key: []const u8, style: st.Style, k: u64) void {
            _ = ui.tree.add(.{ .kind = .image, .style = style, .text = cache_key, .key = k, .bytes = bytes }) catch ui.fail();
        }

        /// A spinner `size` points square: three quarters of a ring turning once in 0.8 s, by the
        /// platform's own animation (nothing is redrawn from Zig).
        pub fn spinner(ui: *Self, size: f32, color: Color, style: st.Style, k: u64) void {
            const w = @max(1.5, size / 10);
            const r = size / 2 - w / 2;
            const n = 40;
            const pts = ui.arena().alloc([2]f32, n + 1) catch return ui.fail();
            for (pts, 0..) |*p, j| {
                const ang = -std.math.pi / 2.0 + @as(f32, @floatFromInt(j)) / n * 1.5 * std.math.pi;
                p.* = .{ size / 2 + r * @cos(ang), size / 2 + r * @sin(ang) };
            }
            var s = style;
            s.width = .{ .px = size };
            s.height = .{ .px = size };
            s.spin_ms = 800;
            ui.path(pts, .{ .color = color, .width = w }, s, k);
        }

        /// A line through `points` (in this node's coordinates), sized by `style`. A point with a
        /// NaN x starts a new sub-path.
        pub fn path(ui: *Self, points: []const [2]f32, p: PathStyle, style: st.Style, k: u64) void {
            _ = ui.tree.add(.{ .kind = .path, .style = style, .key = k, .path = .{
                .points = points,
                .color = p.color.argb(),
                .width = p.width,
                .dash = p.dash,
                .round = p.round,
                .fill = if (p.fill) |f| f.argb() else 0,
            } }) catch ui.fail();
        }

        /// An icon `size` points square in `color`; `style` places it (its size is set here).
        /// Icons marked `rtl_mirror` (arrows, chevrons) are drawn mirrored in right-to-left
        /// languages.
        pub fn icon(ui: *Self, ic: icon_mod.Icon, size: f32, color: Color, style: st.Style, k: u64) void {
            const pts = ui.iconPoints(ic, size) orelse return;
            var s = style;
            s.width = .{ .px = size };
            s.height = .{ .px = size };
            ui.path(pts, if (ic.fill) .{ .color = color, .width = 0, .fill = color } else .{ .color = color, .width = ic.stroke * size / ic.box }, s, k);
        }

        /// A filled icon with an outline in `outline` (a pin, a vehicle arrow).
        pub fn iconOutlined(ui: *Self, ic: icon_mod.Icon, size: f32, fill: Color, outline: Color, outline_width: f32, style: st.Style, k: u64) void {
            const pts = ui.iconPoints(ic, size) orelse return;
            var s = style;
            s.width = .{ .px = size };
            s.height = .{ .px = size };
            ui.path(pts, .{ .color = outline, .width = outline_width, .fill = fill }, s, k);
        }

        fn iconPoints(ui: *Self, ic: icon_mod.Icon, size: f32) ?[]const [2]f32 {
            const pts = icon_mod.points(ui.arena(), ic, size) catch {
                ui.fail();
                return null;
            };
            if (!(ic.rtl_mirror and ui.env.rtl)) return pts;
            const flipped = ui.arena().dupe([2]f32, pts) catch {
                ui.fail();
                return null;
            };
            for (flipped) |*p| if (!std.math.isNan(p[0])) {
                p[0] = size - p[0];
            };
            return flipped;
        }

        /// Asks for `msg` at the next display frame (animations); ask again each frame to continue.
        pub fn requestFrame(ui: *Self, msg: Msg) void {
            ui.frame_msg = msg;
        }

        /// The translation of `english` (Lassan bundles). "Open|task" shows "Open" and is looked
        /// up as "Open|task" first (see i18n.t).
        pub fn t(ui: *Self, english: []const u8) []const u8 {
            _ = ui;
            return i18n.t(english);
        }

        /// `english` translated in `context` ("Open" a task vs "Open" as a state): the bundle key
        /// "english|context" first, then "english".
        pub fn tc(ui: *Self, context: []const u8, english: []const u8) []const u8 {
            _ = ui;
            return i18n.tc(context, english);
        }

        /// Translates `template` and fills `{name}` from `args`.
        pub fn tf(ui: *Self, template: []const u8, args: anytype) []const u8 {
            return i18n.tf(ui.arena(), template, args);
        }

        /// While this frame is on screen, Back (Android's button or gesture, the browser's back
        /// button, the iOS edge swipe) sends `msg` instead of going back through the history:
        /// close a sheet, leave a form. Call it in every frame where it applies.
        pub fn onBack(ui: *Self, msg: Msg) void {
            ui.back_msg = msg;
        }

        /// Color behind everything, including the status bar area.
        pub fn setBackground(ui: *Self, c: Color) void {
            ui.background = c;
        }

        fn fail(ui: *Self) void {
            ui.failed = true;
        }
    };
}

fn Binding(comptime T: type) type {
    return struct { node: u32, value: T };
}

fn InputHandlers(comptime Msg: type) type {
    return struct { focus: ?Msg, blur: ?Msg, submit: ?Msg, select: ?*const fn (Selection) Msg = null };
}

fn PointerHandler(comptime Msg: type) type {
    return struct { f: *const fn (Pointer) Msg, key: u64 };
}

fn LinkHandler(comptime Msg: type) type {
    return struct { index: u32, msg: Msg };
}

/// The loop for `App` drawn by host `H`. One per process; hosts call these from the UI thread.
pub fn Runtime(comptime App: type, comptime H: type) type {
    return struct {
        const Msg = App.Msg;
        const U = Ui(Msg);

        var gpa: std.mem.Allocator = undefined;
        var state: App.State = undefined;
        var trees: [2]Tree = undefined;
        var current: u1 = 0;
        var has_old = false;
        var rec: reconcile.Reconciler(H) = undefined;
        var env: Env = .{};
        var pressed: u32 = 0;
        var started = false;
        /// Started without a screen (a push woke the app: `startHeadless`); nothing is drawn
        /// until `start` brings the screen.
        var headless = false;
        var background: u32 = 0;
        /// Handlers of the frame on screen, by host id.
        var presses: []const Binding(Msg) = &.{};
        var pointers: []const Binding(PointerHandler(Msg)) = &.{};
        var frame_msg: ?Msg = null;
        /// The state changed since the screen was last drawn (coalesced pointer moves).
        var dirty = false;
        /// Inside render: a platform may report events while views change (a focused input
        /// that is removed reports "blur" at once). Those wait in `queued` until it is done.
        var rendering = false;
        var queued: std.ArrayList(Msg) = .empty;
        var changes: []const Binding(*const fn ([]const u8) Msg) = &.{};
        var inputs: []const Binding(InputHandlers(Msg)) = &.{};

        // Effects in flight: requests and timers by id, the location listener, a pending focus.
        var next_id: u32 = 1;
        var fetches: std.AutoHashMapUnmanaged(u32, struct { done: *const fn (Response) Msg, tag: u32 }) = .empty;
        var timers: std.AutoHashMapUnmanaged(u32, Msg) = .empty;
        var location_cb: ?*const fn (Location) Msg = null;
        var focus_key: ?u64 = null;

        // ---- Long press, secondary click, hover, links in text ----
        var holds: []const Binding(Msg) = &.{};
        var contexts: []const Binding(Msg) = &.{};
        var hovers: []const Binding(*const fn (bool) Msg) = &.{};
        var link_spans: []const Binding(LinkHandler(Msg)) = &.{};
        var hovered: u32 = 0;
        /// The timer of the press being held, and the view whose long press (or context menu)
        /// already went: the press that ends it is not a press.
        var hold_timer: u32 = 0;
        var held: u32 = 0;
        const hold_ms = 500;

        fn find(list: anytype, id: u32) ?@TypeOf(list[0].value) {
            for (list) |b| if (b.node == id) return b.value;
            return null;
        }

        /// The long press (or, without one, the context menu) of the view held down.
        fn holdFired() void {
            hold_timer = 0;
            const id = pressed;
            if (id == 0) return;
            const msg = find(holds, id) orelse find(contexts, id) orelse {
                // An icon button's label, shown for a moment instead of pressing it.
                const label = labelOf(id);
                if (label.len == 0) return;
                held = id;
                if (@hasDecl(H, "haptic")) H.haptic();
                if (@hasDecl(H, "showLabel")) H.showLabel(id, label);
                pressed = 0;
                render();
                return;
            };
            held = id;
            if (@hasDecl(H, "haptic")) H.haptic();
            dispatch(msg);
        }

        /// The `label` of the view on screen with this host id ("" if none).
        fn labelOf(id: u32) []const u8 {
            if (!has_old) return "";
            for (trees[current].nodes.items) |n| if (n.host == id) return n.label;
            return "";
        }

        /// A link in a text view was pressed: the `index`th link span.
        pub fn spanPress(id: u32, index: u32) void {
            if (!started) return;
            for (link_spans) |b| if (b.node == id and b.value.index == index) return dispatch(b.value.msg);
        }

        // ---- Scroll views: where each is (as the host reports it), what the app wants ----
        const ScrollPlace = struct { offset: f32 = 0, at_start: bool = true, at_end: bool = false };
        /// By host id, for the scroll views on screen.
        var scroll_places: std.AutoHashMapUnmanaged(u32, ScrollPlace) = .empty;
        var scroll_handlers: []const Binding(*const fn (ScrollEvent) Msg) = &.{};
        var scroll_requests: std.ArrayList(struct { key: u64, target: ScrollTarget, animated: bool }) = .empty;

        // ---- Barcode scanners: the host runs the camera and hands over frames (decoded here
        // with zui.barcode) or codes it read itself ----
        const Scanner = struct {
            on: *const fn (ScanEvent) Msg,
            formats: barcode.Formats,
            last: [256]u8 = undefined,
            last_len: usize = 0,
            last_ms: i64 = 0,
        };
        var scanners: std.AutoHashMapUnmanaged(u32, Scanner) = .empty;

        fn fxScanBarcode(o: Scan, on: *const fn (ScanEvent) Msg) u32 {
            const id = newId();
            if (!@hasDecl(H, "scanOpen")) {
                fxAfter(0, on(.{ .kind = .failed, .scanner = id, .data = "unsupported" }));
                return id;
            }
            scanners.put(gpa, id, .{ .on = on, .formats = o.formats }) catch return 0;
            H.scanOpen(id, o.formats, o.back_camera);
            return id;
        }

        fn fxStopScan(id: u32) void {
            if (scanners.remove(id) and @hasDecl(H, "scanClose")) H.scanClose(id);
        }

        /// Whether `id` is a scanner (hosts show its camera in `ui.video`).
        pub fn isScanner(id: u32) bool {
            return scanners.contains(id);
        }

        /// The formats scanner `id` looks for.
        pub fn scanFormats(id: u32) barcode.Formats {
            return if (scanners.get(id)) |s| s.formats else .{};
        }

        /// A camera frame (its luminance) for scanner `id`, decoded here.
        pub fn scanFrame(id: u32, img: barcode.Image) void {
            const s = scanners.get(id) orelse return;
            const r = (barcode.decode(gpa, img, s.formats) catch return) orelse return;
            defer gpa.free(r.text);
            scanFound(id, r.format, r.text);
        }

        /// A code the host read itself (or `scanFrame` found).
        pub fn scanFound(id: u32, format: barcode.Format, text: []const u8) void {
            const s = scanners.getPtr(id) orelse return;
            if (!started) return;
            const now_ms = H.now();
            // The same code held in front of the camera is one scan.
            if (std.mem.eql(u8, s.last[0..s.last_len], text) and now_ms - s.last_ms < 1500) {
                s.last_ms = now_ms;
                return;
            }
            s.last_len = @min(text.len, s.last.len);
            @memcpy(s.last[0..s.last_len], text[0..s.last_len]);
            s.last_ms = now_ms;
            dispatch(s.on(.{ .kind = .found, .scanner = id, .format = format, .text = text }));
        }

        /// The camera runs (`.started`), or could not (`.failed`, with why).
        pub fn scanState(id: u32, kind: ScanEvent.Kind, why: []const u8) void {
            const s = scanners.get(id) orelse return;
            if (kind == .failed) _ = scanners.remove(id);
            if (started) dispatch(s.on(.{ .kind = kind, .scanner = id, .data = why }));
        }

        fn fxScrollTo(k: u64, target: ScrollTarget, animated: bool) void {
            scroll_requests.append(gpa, .{ .key = k, .target = target, .animated = animated }) catch {};
            // Done after the next draw; ask for one if nothing else will.
            if (!rendering and !dirty) {
                dirty = true;
                H.requestFrame();
            }
        }

        /// Length of what scrolls and of the view, along the way node `n` scrolls.
        fn scrollLengths(n: *const tree_mod.Node) [2]f32 {
            return if (n.kind == .scroll_x) .{ n.content.w, n.frame.w } else .{ n.content.h, n.frame.h };
        }

        fn maxOffset(n: *const tree_mod.Node) f32 {
            const l = scrollLengths(n);
            return @max(0, l[0] - l[1]);
        }

        /// The host's scroll view `id` is at `offset` along the way it scrolls (the user scrolled,
        /// or zui moved it).
        pub fn scrollEvent(id: u32, offset: f32) void {
            if (!started) return;
            const tree = &trees[current];
            const n = for (tree.nodes.items) |*node| {
                if (node.host == id and (node.kind == .scroll or node.kind == .scroll_x)) break node;
            } else return;
            const l = scrollLengths(n);
            const gop = scroll_places.getOrPut(gpa, id) catch return;
            if (!gop.found_existing) gop.value_ptr.* = .{};
            const was = gop.value_ptr.*;
            const now: ScrollPlace = .{ .offset = offset, .at_start = offset <= 1, .at_end = offset >= l[0] - l[1] - 1 };
            gop.value_ptr.* = now;
            const on = find(scroll_handlers, id) orelse return;
            const e: ScrollEvent = .{
                .offset = offset,
                .content = l[0],
                .viewport = l[1],
                .at_start = now.at_start,
                .at_end = now.at_end,
                .reached_start = now.at_start and !was.at_start,
                .reached_end = now.at_end and !was.at_end,
            };
            // Reaching an end is news now; the way there is drawn once a display frame.
            if (e.reached_start or e.reached_end or rendering) return dispatch(on(e));
            apply(on(e));
            if (!dirty) {
                dirty = true;
                H.requestFrame();
            }
        }

        fn scrollHost(id: u32, offset: f32, animated: bool) void {
            if (@hasDecl(H, "scrollTo")) H.scrollTo(id, offset, animated);
        }

        /// After a draw: scroll views that start at the end, stay at the end, keep their place,
        /// and what `fx.scrollTo` asked for.
        fn placeScrolls(old: ?*const Tree, tree: *const Tree) void {
            for (tree.nodes.items) |*n| {
                if (n.kind != .scroll and n.kind != .scroll_x) continue;
                const mode = n.scroll_mode;
                const gop = scroll_places.getOrPut(gpa, n.host) catch continue;
                const old_node: ?*const tree_mod.Node = if (old) |o| for (o.nodes.items) |*on| {
                    if (on.host == n.host and on.kind == n.kind and on.key == n.key) break on;
                } else null else null;
                if (!gop.found_existing or old_node == null) {
                    gop.value_ptr.* = .{};
                    if (mode.anchor_end) {
                        const end_at = maxOffset(n);
                        gop.value_ptr.* = .{ .offset = end_at, .at_start = end_at <= 1, .at_end = true };
                        if (end_at > 0) scrollHost(n.host, end_at, false);
                    }
                    continue;
                }
                const place = gop.value_ptr;
                const was = old_node.?;
                if (std.meta.eql(was.content, n.content) and std.meta.eql(was.frame, n.frame)) continue;
                if (mode.anchor_end and place.at_end) {
                    const end_at = maxOffset(n);
                    if (end_at != place.offset) {
                        place.offset = end_at;
                        scrollHost(n.host, end_at, false);
                    }
                    continue;
                }
                if (mode.keep_position and old != null) {
                    if (keptOffset(old.?, was, tree, n, place.offset)) |to| if (to != place.offset) {
                        place.offset = to;
                        scrollHost(n.host, to, false);
                    };
                }
            }
            // Drop places of scroll views that are gone.
            var it = scroll_places.iterator();
            var gone: std.ArrayList(u32) = .empty;
            defer gone.deinit(gpa);
            while (it.next()) |e| {
                const there = for (tree.nodes.items) |n| {
                    if (n.host == e.key_ptr.* and (n.kind == .scroll or n.kind == .scroll_x)) break true;
                } else false;
                if (!there) gone.append(gpa, e.key_ptr.*) catch {};
            }
            for (gone.items) |id| _ = scroll_places.remove(id);

            for (scroll_requests.items) |rq| {
                const n = for (tree.nodes.items) |*n| {
                    if (n.key == rq.key and (n.kind == .scroll or n.kind == .scroll_x)) break n;
                } else continue;
                const index: u32 = @intCast(n - tree.nodes.items.ptr);
                const to: f32 = switch (rq.target) {
                    .start => 0,
                    .end => maxOffset(n),
                    .offset => |v| v,
                    .child => |k| childOffset(tree, index, k) orelse continue,
                };
                const clamped = std.math.clamp(to, 0, maxOffset(n));
                if (scroll_places.getPtr(n.host)) |p| if (!rq.animated) {
                    p.offset = clamped;
                };
                scrollHost(n.host, clamped, rq.animated);
            }
            scroll_requests.clearRetainingCapacity();
        }

        /// Where node `k` (a descendant of scroll node `scroll`) starts in its content.
        fn childOffset(tree: *const Tree, scroll: u32, k: u64) ?f32 {
            const horizontal = tree.nodes.items[scroll].kind == .scroll_x;
            for (tree.nodes.items, 0..) |n, i| {
                if (n.key != k) continue;
                var pos: f32 = 0;
                var at: u32 = @intCast(i);
                while (at != scroll and at != tree_mod.none) : (at = tree.nodes.items[at].parent) {
                    const f = tree.nodes.items[at].frame;
                    pos += if (horizontal) f.x else f.y;
                }
                if (at == scroll) return pos;
            }
            return null;
        }

        /// The offset that keeps the first keyed child on screen where it was, after content
        /// came or went before it.
        fn keptOffset(old: *const Tree, was: *const tree_mod.Node, tree: *const Tree, n: *const tree_mod.Node, offset: f32) ?f32 {
            const horizontal = n.kind == .scroll_x;
            var it = old.children(@intCast(was - old.nodes.items.ptr));
            while (it.next()) |c| {
                const oc = old.nodes.items[c];
                const begin_at = if (horizontal) oc.frame.x else oc.frame.y;
                const len = if (horizontal) oc.frame.w else oc.frame.h;
                if (oc.key == 0 or begin_at + len <= offset) continue;
                var nit = tree.children(@intCast(n - tree.nodes.items.ptr));
                while (nit.next()) |d| {
                    const nc = tree.nodes.items[d];
                    if (nc.key != oc.key) continue;
                    const moved = (if (horizontal) nc.frame.x else nc.frame.y) - begin_at;
                    return std.math.clamp(offset + moved, 0, maxOffset(n));
                }
                return null;
            }
            return null;
        }

        const vtable: Fx(Msg).VTable = .{
            .fetch = fxFetch,
            .after = fxAfter,
            .location = fxLocation,
            .speak = fxSpeak,
            .set_link = fxSetLink,
            .reduce_motion = fxReduceMotion,
            .focus = fxFocus,
            .selection = fxSelection,
            .select_text = fxSelectText,
            .scroll_to = fxScrollTo,
            .scan_barcode = fxScanBarcode,
            .stop_scan = fxStopScan,
            .post = fxPost,
            .open_socket = fxOpenSocket,
            .send_socket = fxSendSocket,
            .close_socket = fxCloseSocket,
            .copy = fxCopy,
            .open_url = fxOpenUrl,
            .background_location = fxBackgroundLocation,
            .notify = fxNotify,
            .cancel_notify = fxCancelNotify,
            .open_media = fxOpenMedia,
            .media_enable = fxMediaEnable,
            .switch_camera = fxSwitchCamera,
            .media_devices = fxMediaDevices,
            .use_media_device = fxUseMediaDevice,
            .close_media = fxCloseMedia,
            .open_peer = fxOpenPeer,
            .peer_signal = fxPeerSignal,
            .peer_stream = fxPeerStream,
            .close_peer = fxClosePeer,
            .start_recording = fxStartRecording,
            .stop_recording = fxStopRecording,
            .play = fxPlay,
            .control_playback = fxControlPlayback,
            .ring_call = fxRingCall,
            .start_call = fxStartCall,
            .call_connected = fxCallConnected,
            .end_call = fxEndCall,
            .push_link = fxPushLink,
            .vibrate = fxVibrate,
            .beep = fxBeep,
            .keep_awake = fxKeepAwake,
            .pick_date = fxPickDate,
            .pick_time = fxPickTime,
            .pick_option = fxPickOption,
            .pick_photo = fxPickPhoto,
            .pick_file = fxPickFile,
            .save_file = fxSaveFile,
            .open_events = fxOpenEvents,
            .close_events = fxCloseEvents,
            .key = fxKey,
            .register_push = fxRegisterPush,
            .web_auth = fxWebAuth,
        };

        // ---- Secure keys: the web's WebCrypto answers later (H.keyRequest); elsewhere zui's
        // engine runs on the host's secure storage (and its keystore, H.KeyHw). Every answer is
        // delivered as a message after the current update.
        const KeyStore = struct {
            pub const Hw = if (@hasDecl(H, "KeyHw")) H.KeyHw else struct {};
            pub fn get(a: std.mem.Allocator, k: []const u8) ?[]u8 {
                return H.storageGet(a, k, true);
            }
            pub fn set(k: []const u8, v: []const u8) void {
                H.storageSet(k, v, true);
            }
            pub fn remove(k: []const u8) void {
                H.storageRemove(k, true);
            }
            pub fn random(buf: []u8) void {
                H.randomBytes(buf);
            }
        };
        var key_done: std.AutoHashMapUnmanaged(u32, *const fn (keys.Result) Msg) = .empty;
        var key_ready: std.AutoHashMapUnmanaged(u32, struct { id: u32, status: keys.Status, data: []u8 }) = .empty;

        fn fxKey(req: keys.Request, done: *const fn (keys.Result) Msg) u32 {
            const id = newId();
            key_done.put(gpa, id, done) catch return 0;
            if (@hasDecl(H, "keyRequest")) {
                H.keyRequest(id, req);
            } else {
                var arena = std.heap.ArenaAllocator.init(gpa);
                defer arena.deinit();
                const r = keys.Engine(KeyStore).run(arena.allocator(), req);
                keyDone(id, r[0], r[1]);
            }
            return id;
        }

        /// The answer to key request `id` (`data` is copied).
        pub fn keyDone(id: u32, status: keys.Status, data: []const u8) void {
            const t = newId();
            key_ready.put(gpa, t, .{ .id = id, .status = status, .data = gpa.dupe(u8, data) catch return }) catch return;
            H.timer(t, 0);
        }

        // ---- Server-Sent Events: the host streams the bytes of a GET, zui parses them (sse.zig)
        // and connects again. Each connection has its own id, so a late chunk of an old one is
        // dropped.
        const Stream = struct {
            id: u32,
            on: *const fn (ServerEvent) Msg,
            url: []u8,
            headers: []u8,
            parser: sse.Parser,
            /// The current connection (0 while waiting to connect again).
            conn: u32 = 0,
            status: u16 = 0,
            /// Inside `streamData`: freed after it.
            busy: bool = false,
            closing: bool = false,
        };
        var streams: std.AutoHashMapUnmanaged(u32, *Stream) = .empty;
        /// Connection id -> stream id.
        var connections: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        /// Timer id -> stream id, for connecting again.
        var stream_timers: std.AutoHashMapUnmanaged(u32, u32) = .empty;

        fn fxOpenEvents(src: EventStream, on: *const fn (ServerEvent) Msg) u32 {
            const id = newId();
            const st_ = gpa.create(Stream) catch return 0;
            var block: std.ArrayList(u8) = .empty;
            for (src.headers) |h| block.print(gpa, "{s}: {s}\n", .{ h[0], h[1] }) catch {};
            st_.* = .{ .id = id, .on = on, .url = gpa.dupe(u8, src.url) catch "", .headers = block.toOwnedSlice(gpa) catch "", .parser = .{ .gpa = gpa } };
            streams.put(gpa, id, st_) catch return 0;
            connect(st_);
            return id;
        }

        fn connect(st_: *Stream) void {
            const conn = newId();
            st_.conn = conn;
            st_.status = 0;
            st_.parser.reset();
            connections.put(gpa, conn, st_.id) catch return;
            var block: std.ArrayList(u8) = .empty;
            defer block.deinit(gpa);
            block.appendSlice(gpa, st_.headers) catch {};
            block.appendSlice(gpa, "Accept: text/event-stream\nCache-Control: no-cache\n") catch {};
            if (st_.parser.last_id.items.len > 0) block.print(gpa, "Last-Event-ID: {s}\n", .{st_.parser.last_id.items}) catch {};
            H.streamOpen(conn, st_.url, block.items);
        }

        fn freeStream(st_: *Stream) void {
            st_.parser.deinit();
            gpa.free(st_.url);
            gpa.free(st_.headers);
            gpa.destroy(st_);
        }

        fn fxCloseEvents(id: u32) void {
            const st_ = (streams.fetchRemove(id) orelse return).value;
            if (st_.conn != 0) {
                _ = connections.remove(st_.conn);
                H.streamClose(st_.conn);
            }
            if (st_.busy) st_.closing = true else freeStream(st_);
        }

        fn streamOf(conn: u32) ?*Stream {
            const id = connections.get(conn) orelse return null;
            return streams.get(id);
        }

        /// The answer's status arrived.
        pub fn streamStatus(conn: u32, status: u16) void {
            const st_ = streamOf(conn) orelse return;
            st_.status = status;
            if (status == 200 and started) dispatch(st_.on(.{ .kind = .open, .stream = st_.id }));
        }

        /// Bytes of the answer (only read during this call).
        pub fn streamData(conn: u32, bytes: []const u8) void {
            const st_ = streamOf(conn) orelse return;
            if (st_.status != 200) return; // an error page, not events
            st_.busy = true;
            defer {
                st_.busy = false;
                if (st_.closing) freeStream(st_);
            }
            const Ctx = struct {
                s: *Stream,
                fn on(c: @This(), e: sse.Event) bool {
                    if (started) dispatch(c.s.on(.{ .kind = .message, .stream = c.s.id, .event = e.event, .data = e.data, .id = e.id }));
                    return !c.s.closing;
                }
            };
            st_.parser.feed(bytes, Ctx{ .s = st_ }, Ctx.on) catch {};
        }

        /// The connection ended (or never opened).
        pub fn streamEnd(conn: u32) void {
            const st_ = streamOf(conn) orelse return;
            _ = connections.remove(conn);
            st_.conn = 0;
            const status = st_.status;
            const final = status == 204 or (status >= 400 and status < 500 and status != 408 and status != 429);
            if (final) {
                _ = streams.remove(st_.id);
                defer freeStream(st_);
                if (started) dispatch(st_.on(.{ .kind = .closed, .stream = st_.id, .status = status }));
                return;
            }
            const t = newId();
            stream_timers.put(gpa, t, st_.id) catch return;
            H.timer(t, st_.parser.retry_ms orelse 3000);
            if (started) dispatch(st_.on(.{ .kind = .failed, .stream = st_.id, .status = status }));
        }

        // ---- Files: one pick at a time ----
        var file_cb: ?*const fn (File) Msg = null;

        fn fxPickPhoto(o: PhotoPick, done: *const fn (File) Msg) void {
            file_cb = done;
            // Quality 0 asks the host for PNG.
            H.pickPhoto(o.camera, @max(16, o.max_size), if (o.format == .png) 0 else @max(1, @min(100, o.quality)));
        }

        fn fxPickFile(o: FilePick, done: *const fn (File) Msg) void {
            file_cb = done;
            H.pickFile(o.accept);
        }

        fn fxSaveFile(f: SaveFile) void {
            H.saveFile(f.name, f.mime, f.data, f.share);
        }

        /// The file the user chose (only read during this call).
        pub fn fileDone(data: []const u8, name: []const u8, mime: []const u8, width: u32, height: u32) void {
            const cb = file_cb orelse return;
            file_cb = null;
            if (started) dispatch(cb(.{ .data = data, .name = name, .mime = mime, .width = width, .height = height }));
        }

        // ---- In-app sign-in pages (fx.webAuth): one at a time ----
        var web_auth_cb: ?*const fn (WebAuthResult) Msg = null;

        fn fxWebAuth(o: WebAuth, done: *const fn (WebAuthResult) Msg) void {
            web_auth_cb = done;
            const bar = if (o.bar) |c| c.argb() else @as(u32, if (env.dark) 0xff121214 else 0xffffffff);
            const ink = if (o.ink) |c| c.argb() else (if (env.dark) @as(u32, 0xffececf0) else 0xff1c1c20);
            const bg = if (o.background) |c| c.argb() else bar;
            H.webAuth(o.url, o.callback_prefix, .{ .title = o.title, .bar = bar, .ink = ink, .background = bg, .rtl = env.rtl or i18n.isRtl() });
        }

        /// The sign-in page ended: at the callback address (only read during this call), or
        /// null when the user closed it.
        pub fn webAuthDone(url: ?[]const u8) void {
            const cb = web_auth_cb orelse return;
            web_auth_cb = null;
            if (started) dispatch(cb(if (url) |u| .{ .ok = u } else .cancelled));
        }

        // ---- Pickers: one at a time; a new one replaces the callback of the last ----
        var picking: union(enum) { none, text: *const fn ([]const u8) Msg, index: *const fn (u32) Msg } = .none;

        fn fxPickDate(o: DatePick, done: *const fn ([]const u8) Msg) void {
            picking = .{ .text = done };
            H.pick(.date, o.value, o.min, o.max, "", "", 0);
        }

        fn fxPickTime(o: TimePick, done: *const fn ([]const u8) Msg) void {
            picking = .{ .text = done };
            H.pick(.time, o.value, "", "", "", "", 0);
        }

        fn fxPickOption(o: OptionPick, done: *const fn (u32) Msg) void {
            picking = .{ .index = done };
            // The options travel as one block, a line each (the same on every host).
            var block: std.ArrayList(u8) = .empty;
            defer block.deinit(gpa);
            for (o.options, 0..) |opt, i| {
                if (i > 0) block.append(gpa, '\n') catch {};
                for (opt) |c| block.append(gpa, if (c == '\n') ' ' else c) catch {};
            }
            H.pick(.option, "", "", "", o.title, block.items, if (o.selected) |i| @as(i32, @intCast(i)) else -1);
        }

        /// The user chose: a date, a time, or the index of an option (as decimal text).
        pub fn pickDone(value: []const u8) void {
            const p = picking;
            picking = .none;
            if (!started) return;
            switch (p) {
                .none => {},
                .text => |f| dispatch(f(value)),
                .index => |f| dispatch(f(std.fmt.parseInt(u32, value, 10) catch return)),
            }
        }

        fn fxVibrate(ms: u32) void {
            H.vibrate(ms);
        }

        fn fxBeep() void {
            H.beep();
        }

        fn fxKeepAwake(on: bool) void {
            H.keepAwake(on);
        }

        // ---- Navigation: links, their history and Back ----
        // The web has the browser's history (H.pushLink); elsewhere zui keeps the links behind
        // the current one. Links are kept for the life of the app (the app may hold slices of
        // env.link), each distinct one once.
        const native_history = @hasDecl(H, "pushLink");
        var links: std.StringHashMapUnmanaged(void) = .empty;
        var history: std.ArrayList([]const u8) = .empty;
        var back_msg: ?Msg = null;
        /// What the host was last told: the app handles Back / there is history to go back to.
        var back_told: ?[3]bool = null;

        fn intern(link: []const u8) []const u8 {
            if (links.getKey(link)) |k| return k;
            const owned = gpa.dupe(u8, link) catch return "";
            links.put(gpa, owned, {}) catch {};
            return owned;
        }

        var reduce_motion = false;

        fn fxReduceMotion(on: bool) void {
            reduce_motion = on;
        }

        fn fxSetLink(link: []const u8) void {
            env.link = intern(link);
            H.setLink(link);
        }

        fn fxPushLink(link: []const u8) void {
            if (native_history) {
                env.link = intern(link);
                return H.pushLink(link);
            }
            history.append(gpa, env.link) catch {};
            fxSetLink(link);
        }

        /// Back was pressed (Android), swiped (iOS) or the browser left the entry zui keeps while
        /// the app handles Back (web). Returns whether the app took it; if not, the platform does
        /// what it does by default (Android leaves the app).
        pub fn back() bool {
            if (!started) return false;
            if (back_msg) |m| {
                dispatch(m);
                return true;
            }
            if (native_history) return false;
            const prev = history.pop() orelse return false;
            env.link = prev;
            H.setLink(prev);
            linkChanged();
            return true;
        }

        /// The address changed from outside: the browser went back or forward, or the phone was
        /// opened with a new deep link.
        pub fn linkEvent(link: []const u8) void {
            if (!started) return;
            env.link = intern(link);
            linkChanged();
        }

        fn linkChanged() void {
            if (@hasDecl(App, "linkEvent")) {
                if (App.linkEvent(env.link)) |m| return dispatch(m);
            }
            render();
        }

        pub fn deviceEvent(kind: DeviceEvent) void {
            // Platforms repeat the current state (Android's network callback on registering).
            const same = switch (kind) {
                .online => env.online,
                .offline => !env.online,
                .visible => env.visible,
                .hidden => !env.visible,
            };
            if (same) return;
            switch (kind) {
                .online => env.online = true,
                .offline => env.online = false,
                .visible => env.visible = true,
                .hidden => env.visible = false,
            }
            if (!started) return;
            if (@hasDecl(App, "deviceEvent")) {
                if (App.deviceEvent(kind)) |m| return dispatch(m);
            }
            render();
        }

        /// A key from the keyboard; true when the app took it (the host then stops it).
        pub fn keyEvent(e: KeyEvent) bool {
            if (!started) return false;
            if (@hasDecl(App, "keyEvent")) {
                if (App.keyEvent(e)) |m| {
                    dispatch(m);
                    return true;
                }
            }
            return false;
        }

        /// The host is told when Back starts or stops being the app's (Android registers its
        /// back callback, the web keeps a history entry to catch the browser's back button,
        /// iOS enables its edge swipe).
        fn syncBack() void {
            const now = [3]bool{ back_msg != null, !native_history and history.items.len > 0, env.rtl };
            if (back_told) |was| if (std.mem.eql(bool, &was, &now)) return;
            back_told = now;
            H.backState(now[0], now[1], now[2]);
        }

        // The system's call screens; a host without them (the web) leaves it to the app.
        const has_system_calls = @hasDecl(H, "ringCall");

        fn fxRingCall(c: Call) void {
            if (has_system_calls) H.ringCall(c);
        }

        fn fxStartCall(c: Call) void {
            if (has_system_calls) H.startCall(c);
        }

        fn fxCallConnected(id: []const u8) void {
            if (has_system_calls) H.callConnected(id);
        }

        fn fxEndCall(id: []const u8) void {
            if (has_system_calls) H.endCall(id);
        }

        fn fxRegisterPush(o: PushOptions) void {
            if (@hasDecl(H, "registerPush")) H.registerPush(o);
        }

        // Calls. The web host has them built in (H.openMedia...). The phones have a media
        // backend (H.Media) and need a call engine from the app (App.rtc, see zui/calls.zig).
        // Without either, media answers "unsupported" and peers "failed".
        const native_calls = !@hasDecl(H, "openMedia") and @hasDecl(H, "Media") and @hasDecl(App, "rtc");
        const NativeCalls = if (native_calls) calls.Native(H.Media, App.rtc, @This()) else void;
        const has_calls = @hasDecl(H, "openMedia") or native_calls;
        const C = if (native_calls) NativeCalls else H;

        /// Hands the call events other threads queued to the app (phones; on the UI thread).
        pub fn callsPump() void {
            if (native_calls) NativeCalls.pump();
        }
        var medias: std.AutoHashMapUnmanaged(u32, *const fn (MediaEvent) Msg) = .empty;
        var peers: std.AutoHashMapUnmanaged(u32, *const fn (PeerEvent) Msg) = .empty;

        fn fxOpenMedia(m: Media, on: *const fn (MediaEvent) Msg) u32 {
            const id = newId();
            if (!has_calls) {
                fxAfter(0, on(.{ .kind = .failed, .stream = id, .data = "unsupported" }));
                return id;
            }
            medias.put(gpa, id, on) catch return 0;
            C.openMedia(id, m);
            return id;
        }

        fn fxMediaEnable(id: u32, audio: bool, video: bool) void {
            if (has_calls) C.mediaEnable(id, audio, video);
        }

        fn fxSwitchCamera(id: u32) void {
            if (has_calls) C.switchCamera(id);
        }

        // Devices: the web and headless hosts have them; the phones' media backends too.
        const Dev = if (@hasDecl(H, "listMediaDevices") or @hasDecl(H, "mediaDevicesJson")) H else if (@hasDecl(H, "Media") and @hasDecl(H.Media, "mediaDevicesJson")) H.Media else void;
        var devices_cb: ?*const fn ([]const MediaDevice) Msg = null;
        var devices: std.ArrayList(MediaDevice) = .empty;
        var devices_text: std.ArrayList(u8) = .empty;

        fn fxMediaDevices(stream: u32, on: *const fn ([]const MediaDevice) Msg) void {
            devices_cb = on;
            if (Dev == void) return mediaDevicesDone("[]");
            // Hosts that know at once answer here; the web asks the browser and answers later.
            if (@hasDecl(Dev, "mediaDevicesJson")) return mediaDevicesDone(Dev.mediaDevicesJson(stream));
            Dev.listMediaDevices(stream);
        }

        fn fxUseMediaDevice(stream: u32, kind: MediaDevice.Kind, id_: []const u8) void {
            if (Dev != void) Dev.useMediaDevice(stream, kind, id_);
        }

        /// The host's list, as JSON: [{"k":1,"id":"...","l":"label","t":"type","c":true}]. The app
        /// hears it at the next turn (hosts may answer during the update that asked).
        pub fn mediaDevicesDone(json: []const u8) void {
            for (devices.items) |*d| {
                gpa.free(d.id);
                gpa.free(d.label);
                gpa.free(d.type);
            }
            devices.clearRetainingCapacity();
            const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return;
            defer parsed.deinit();
            if (parsed.value == .array) for (parsed.value.array.items) |v| {
                if (v != .object) continue;
                const k = v.object.get("k") orelse continue;
                if (k != .integer) continue;
                const kind = std.enums.fromInt(MediaDevice.Kind, @as(u8, @intCast(@max(0, @min(255, k.integer))))) orelse continue;
                const s = struct {
                    fn of(o: std.json.ObjectMap, name: []const u8) []const u8 {
                        const x = o.get(name) orelse return "";
                        return if (x == .string) x.string else "";
                    }
                };
                const cur = v.object.get("c");
                devices.append(gpa, .{
                    .kind = kind,
                    .id = gpa.dupe(u8, s.of(v.object, "id")) catch continue,
                    .label = gpa.dupe(u8, s.of(v.object, "l")) catch continue,
                    .type = gpa.dupe(u8, s.of(v.object, "t")) catch continue,
                    .current = cur != null and cur.? == .bool and cur.?.bool,
                }) catch {};
            };
            const cb = devices_cb orelse return;
            devices_cb = null;
            fxAfter(0, cb(devices.items));
        }

        fn fxCloseMedia(id: u32) void {
            if (medias.remove(id) and has_calls) C.closeMedia(id);
        }

        fn fxOpenPeer(p: Peer, on: *const fn (PeerEvent) Msg) u32 {
            const id = newId();
            if (!has_calls) {
                fxAfter(0, on(.{ .kind = .state, .peer = id, .data = "failed" }));
                return id;
            }
            peers.put(gpa, id, on) catch return 0;
            C.openPeer(id, p);
            return id;
        }

        fn fxPeerSignal(id: u32, json: []const u8) void {
            if (has_calls and peers.contains(id)) C.peerSignal(id, json);
        }

        fn fxPeerStream(id: u32, stream: u32) void {
            if (has_calls and peers.contains(id)) C.peerStream(id, stream);
        }

        fn fxClosePeer(id: u32) void {
            if (peers.remove(id) and has_calls) C.closePeer(id);
        }

        // Recording and playback (voice and video messages). A host without them answers
        // "unsupported".
        const has_recording = @hasDecl(H, "startRecording");
        const has_playback = @hasDecl(H, "play");
        var recorders: std.AutoHashMapUnmanaged(u32, *const fn (RecordEvent) Msg) = .empty;
        var players: std.AutoHashMapUnmanaged(u32, *const fn (PlayEvent) Msg) = .empty;

        fn fxStartRecording(r: Recording, on: *const fn (RecordEvent) Msg) u32 {
            const id = newId();
            if (!has_recording) {
                fxAfter(0, on(.{ .kind = .failed, .recorder = id, .data = "unsupported" }));
                return id;
            }
            recorders.put(gpa, id, on) catch return 0;
            H.startRecording(id, r);
            return id;
        }

        fn fxStopRecording(id: u32, cancel: bool) void {
            if (!has_recording or !recorders.contains(id)) return;
            if (cancel) _ = recorders.remove(id);
            H.stopRecording(id, cancel);
        }

        fn fxPlay(p: Playback, on: *const fn (PlayEvent) Msg) u32 {
            const id = newId();
            if (!has_playback) {
                fxAfter(0, on(.{ .kind = .failed, .player = id, .data = "unsupported" }));
                return id;
            }
            players.put(gpa, id, on) catch return 0;
            H.play(id, p);
            return id;
        }

        fn fxControlPlayback(id: u32, c: PlaybackControl) void {
            if (!has_playback or !players.contains(id)) return;
            if (c == .stop) _ = players.remove(id);
            H.controlPlayback(id, c);
        }

        fn fxNotify(n: Notification) void {
            H.notify(n);
        }

        fn fxCancelNotify(id: u32) void {
            H.cancelNotify(id);
        }

        fn fxBackgroundLocation(on: bool, title: []const u8, text: []const u8) void {
            H.backgroundLocation(on, title, text);
        }

        fn fxCopy(text: []const u8) void {
            H.copy(text);
        }

        fn fxOpenUrl(url: []const u8, new_window: bool) void {
            H.openUrl(url, new_window);
        }
        var sockets: std.AutoHashMapUnmanaged(u32, *const fn (SocketEvent) Msg) = .empty;

        fn fxPost(json: []const u8) void {
            H.post(json);
        }

        fn fxOpenSocket(url: []const u8, on: *const fn (SocketEvent) Msg) u32 {
            const id = newId();
            sockets.put(gpa, id, on) catch return 0;
            H.openSocket(id, url);
            return id;
        }

        fn fxSendSocket(id: u32, text: []const u8) void {
            H.sendSocket(id, text);
        }

        fn fxCloseSocket(id: u32) void {
            if (sockets.remove(id)) H.closeSocket(id);
        }
        const fx: Fx(Msg) = .{ .vt = &vtable };

        fn newId() u32 {
            const id = next_id;
            next_id +%= 1;
            if (next_id == 0) next_id = 1;
            return id;
        }

        fn fxFetch(req: Request, done: *const fn (Response) Msg) void {
            const id = newId();
            fetches.put(gpa, id, .{ .done = done, .tag = req.tag }) catch return;
            // Headers travel as one "name: value\n" block (the same on every host).
            var block: std.ArrayList(u8) = .empty;
            defer block.deinit(gpa);
            for (req.headers) |h| block.print(gpa, "{s}: {s}\n", .{ h[0], h[1] }) catch {};
            H.fetch(id, @tagName(req.method), req.url, req.body, req.content_type, block.items);
        }

        fn fxAfter(ms: u32, msg: Msg) void {
            const id = newId();
            timers.put(gpa, id, msg) catch return;
            H.timer(id, ms);
        }

        fn fxLocation(on: ?*const fn (Location) Msg) void {
            const was = location_cb != null;
            location_cb = on;
            if (was != (on != null)) H.location(on != null);
        }

        fn fxSpeak(text: []const u8) void {
            H.speak(text, i18n.language());
        }

        fn fxFocus(k: u64) void {
            focus_key = k;
        }

        var select_key: ?u64 = null;
        var select_range: Selection = .{ .start = 0, .end = 0 };

        fn fxSelectText(k: u64, s: Selection) void {
            select_key = k;
            select_range = s;
        }

        fn inputHost(k: u64) ?u32 {
            if (!has_old) return null;
            for (trees[current].nodes.items) |n| if (n.key == k and (n.kind == .input or n.kind == .text_area)) return n.host;
            return null;
        }

        fn fxSelection(k: u64) ?Selection {
            if (!@hasDecl(H, "selection")) return null;
            const host = inputHost(k) orelse return null;
            return H.selection(host);
        }

        /// The cursor moved or the selection changed in an input.
        pub fn selectEvent(id: u32, from: u32, to: u32) void {
            if (!started) return;
            for (inputs) |b| {
                if (b.node != id) continue;
                if (b.value.select) |f| dispatch(f(.{ .start = @min(from, to), .end = @max(from, to) }));
                return;
            }
        }

        /// `lang` is the system language ("ar", "en-US", ...); the app starts in it when it has a
        /// bundle for it, otherwise in English.
        pub fn start(allocator: std.mem.Allocator, e: Env, lang: []const u8) void {
            if (started and headless) {
                // Woken by a push earlier: the state stays, the screen arrives now.
                headless = false;
                const visible = env.visible;
                env = e;
                env.visible = e.visible or visible;
                env.link = intern(e.link);
                render();
                if (@hasDecl(App, "boot")) dispatch(App.boot);
                return;
            }
            begin(allocator, lang);
            env = e;
            env.link = intern(e.link);
            state = App.init();
            started = true;
            render();
            // An app that needs effects at startup (location, reading its link) declares
            // `pub const boot: Msg`.
            if (@hasDecl(App, "boot")) dispatch(App.boot);
        }

        /// Starts the app without a screen: a push arrived while it was not running (Android:
        /// FirebaseMessagingService started the process; iOS: PushKit launched it in the
        /// background). `init` runs and messages are handled (`pushMessage` can ring a call or
        /// notify, fetch, store); nothing is drawn and `boot` waits until `start` brings the
        /// screen, which keeps the state.
        pub fn startHeadless(allocator: std.mem.Allocator, lang: []const u8) void {
            if (started) return;
            begin(allocator, lang);
            env = .{ .visible = false };
            state = App.init();
            headless = true;
            started = true;
        }

        fn begin(allocator: std.mem.Allocator, lang: []const u8) void {
            gpa = allocator;
            trees = .{ Tree.init(gpa), Tree.init(gpa) };
            rec = .{ .gpa = gpa };
            if (@hasDecl(App, "locales")) {
                const global = if (@hasDecl(App, "global_locale")) App.global_locale else "{}";
                i18n.init(gpa, global, App.locales) catch {};
                const base = lang[0 .. std.mem.indexOfAny(u8, lang, "-_") orelse lang.len];
                for (App.locales) |l| {
                    if (std.ascii.eqlIgnoreCase(l.lang, base)) i18n.setLanguage(l.lang);
                }
            }
        }

        pub fn resize(width: f32, height: f32) void {
            if (env.width == width and env.height == height) return;
            env.width = width;
            env.height = height;
            if (started) render();
        }

        pub fn setInsets(safe: Insets) void {
            if (std.meta.eql(env.safe, safe)) return;
            env.safe = safe;
            if (started) render();
        }

        pub fn setDark(dark: bool) void {
            if (env.dark == dark) return;
            env.dark = dark;
            if (started) render();
        }

        pub fn event(id: u32, kind: Event) void {
            if (!started) return;
            switch (kind) {
                .press_in => {
                    pressed = id;
                    held = 0;
                    hold_timer = 0;
                    if (find(holds, id) != null or find(contexts, id) != null or (@hasDecl(H, "showLabel") and labelOf(id).len > 0)) {
                        hold_timer = newId();
                        H.timer(hold_timer, hold_ms);
                    }
                    render();
                },
                .press_out => if (pressed == id) {
                    pressed = 0;
                    hold_timer = 0;
                    render();
                },
                .press => {
                    // The long press (or context menu) already answered this touch.
                    if (held == id) {
                        held = 0;
                        return;
                    }
                    if (find(presses, id)) |m| dispatch(m);
                },
                .context => {
                    if (held == id) return; // the long press went first
                    const msg = find(contexts, id) orelse find(holds, id) orelse return;
                    hold_timer = 0;
                    held = id;
                    dispatch(msg);
                },
                .hover_in => {
                    hovered = id;
                    if (find(hovers, id)) |f| dispatch(f(true)) else render();
                },
                .hover_out => if (hovered == id) {
                    hovered = 0;
                    if (find(hovers, id)) |f| dispatch(f(false)) else render();
                },
            }
        }

        /// The app state, for tests.
        pub fn appState() *const App.State {
            return &state;
        }

        pub fn pointerEvent(id: u32, p: Pointer) void {
            if (!started) return;
            for (pointers) |b| {
                if (b.node != id) continue;
                var q = p;
                q.key = b.value.key;
                // Moves arrive faster than the screen refreshes (and once per finger): the state
                // follows every one, the screen once per display frame.
                if (p.kind != .move or rendering) return dispatch(b.value.f(q));
                apply(b.value.f(q));
                if (!dirty) {
                    dirty = true;
                    H.requestFrame();
                }
                return;
            }
        }

        /// The host's display frame, after `requestFrame`, at `time_ms` (monotonic).
        pub fn frame(time_ms: f64) void {
            if (!started) return;
            env.time_ms = time_ms;
            const m = frame_msg;
            frame_msg = null;
            if (rendering) return;
            if (m) |msg| apply(msg) else if (!dirty) return;
            render();
        }

        pub fn textEvent(id: u32, text: []const u8) void {
            if (!started) return;
            for (changes) |b| {
                if (b.node == id) return dispatch(b.value(clipText(id, text)));
            }
        }

        /// The input's `max_length`, kept here too (hosts limit typing; a paste or a host
        /// without it still cannot pass it).
        fn clipText(id: u32, text: []const u8) []const u8 {
            if (!has_old) return text;
            for (trees[current].nodes.items) |n| {
                if (n.host != id) continue;
                const max = n.input_type.max_length;
                if (max == 0) return text;
                var it = std.unicode.Utf8View.initUnchecked(text).iterator();
                var count: u32 = 0;
                while (it.nextCodepointSlice()) |_| {
                    count += 1;
                    if (count == max) return text[0..it.i];
                }
                return text;
            }
            return text;
        }

        pub fn inputEvent(id: u32, kind: InputEvent) void {
            if (!started) return;
            for (inputs) |b| {
                if (b.node != id) continue;
                const m = switch (kind) {
                    .focus => b.value.focus,
                    .blur => b.value.blur,
                    .submit => b.value.submit,
                };
                if (m) |msg| dispatch(msg);
                return;
            }
        }

        /// A request finished (status 0: no connection). `body` is only read during this call.
        pub fn fetchDone(id: u32, status: u16, body: []const u8) void {
            fetchDoneWithHeaders(id, status, body, "");
        }

        /// As `fetchDone`, with the response's headers ("name: value\n" lines).
        pub fn fetchDoneWithHeaders(id: u32, status: u16, body: []const u8, headers: []const u8) void {
            const f = (fetches.fetchRemove(id) orelse return).value;
            if (started) dispatch(f.done(.{ .status = status, .body = body, .tag = f.tag, .headers = headers }));
        }

        pub fn timerDone(id: u32) void {
            if (key_ready.fetchRemove(id)) |kv| {
                const r = kv.value;
                defer {
                    std.crypto.secureZero(u8, r.data);
                    gpa.free(r.data);
                }
                const done = (key_done.fetchRemove(r.id) orelse return).value;
                if (started) dispatch(done(.{ .id = r.id, .status = r.status, .data = r.data }));
                return;
            }
            if (id != 0 and id == hold_timer) return if (started) holdFired();
            if (stream_timers.fetchRemove(id)) |kv| {
                // Connect again, unless the app closed the stream meanwhile.
                if (streams.get(kv.value)) |st_| connect(st_);
                return;
            }
            const msg = (timers.fetchRemove(id) orelse return).value;
            if (started) dispatch(msg);
        }

        pub fn socketEvent(id: u32, kind: SocketEvent.Kind, data: []const u8) void {
            const on = sockets.get(id) orelse return;
            if (kind == .closed) _ = sockets.remove(id);
            if (started) dispatch(on(.{ .kind = kind, .socket = id, .data = data }));
        }

        pub fn mediaEvent(id: u32, kind: MediaEvent.Kind, data: []const u8) void {
            const on = medias.get(id) orelse return;
            if (kind != .ready) _ = medias.remove(id);
            if (started) dispatch(on(.{ .kind = kind, .stream = id, .data = data }));
        }

        pub fn peerEvent(id: u32, kind: PeerEvent.Kind, data: []const u8, stream: u32) void {
            const on = peers.get(id) orelse return;
            if (started) dispatch(on(.{ .kind = kind, .peer = id, .data = data, .stream = stream }));
        }

        pub fn recordEvent(id: u32, kind: RecordEvent.Kind, level: f32, duration_ms: u32, data: []const u8, mime: []const u8) void {
            const on = recorders.get(id) orelse return;
            if (kind == .done or kind == .failed) _ = recorders.remove(id);
            if (started) dispatch(on(.{ .kind = kind, .recorder = id, .level = level, .duration_ms = duration_ms, .data = data, .mime = mime }));
        }

        pub fn playEvent(id: u32, kind: PlayEvent.Kind, position_ms: u32, duration_ms: u32, data: []const u8) void {
            const on = players.get(id) orelse return;
            if (kind == .failed) _ = players.remove(id);
            if (started) dispatch(on(.{ .kind = kind, .player = id, .position_ms = position_ms, .duration_ms = duration_ms, .data = data }));
        }

        pub fn callEvent(kind: CallEvent.Kind, id: []const u8) void {
            if (!started or !@hasDecl(App, "callEvent")) return;
            if (App.callEvent(.{ .kind = kind, .id = id })) |m| dispatch(m);
        }

        /// A push token from the platform (see `PushOptions`): the app's
        /// `pub fn pushToken(token: []const u8, kind: PushKind) ?Msg`.
        pub fn pushToken(token: []const u8, kind: PushKind) void {
            if (!started or !@hasDecl(App, "pushToken")) return;
            if (App.pushToken(token, kind)) |m| dispatch(m);
        }

        /// A push's data (JSON) for the app's `pub fn pushMessage(json: []const u8) ?Msg`,
        /// handled before this returns: a VoIP push on iOS must report the call to CallKit
        /// (`fx.ringCall`) right there, and Android may stop the process soon after.
        pub fn pushMessage(json: []const u8) void {
            if (!started or !@hasDecl(App, "pushMessage")) return;
            if (App.pushMessage(json)) |m| dispatch(m);
        }

        /// A message from the embedding page; the app turns it into a Msg with
        /// `pub fn hostMessage(json: []const u8) ?Msg`.
        pub fn hostMessage(json: []const u8) void {
            if (!started or !@hasDecl(App, "hostMessage")) return;
            if (App.hostMessage(json)) |m| dispatch(m);
        }

        pub fn locationEvent(l: Location) void {
            const cb = location_cb orelse return;
            if (started) dispatch(cb(l));
        }

        pub fn dispatch(msg: Msg) void {
            if (rendering) {
                queued.append(gpa, msg) catch {};
                return;
            }
            apply(msg);
            render();
            // Events that arrived during the render, in order.
            while (queued.items.len > 0) {
                const next = queued.orderedRemove(0);
                apply(next);
                render();
            }
        }

        /// `update` without drawing: `update(state, msg)`, `update(state, msg, env)` or
        /// `update(state, msg, env, fx)`.
        fn apply(msg: Msg) void {
            readClock();
            switch (@typeInfo(@TypeOf(App.update)).@"fn".param_types.len) {
                2 => App.update(&state, msg),
                3 => App.update(&state, msg, env),
                else => App.update(&state, msg, env, fx),
            }
        }

        fn readClock() void {
            env.now_ms = H.now();
            env.tz_offset_min = H.tzOffset();
        }

        fn render() void {
            if (headless) return;
            readClock();
            rendering = true;
            defer rendering = false;
            dirty = false;
            const next: u1 = if (has_old) current ^ 1 else current;
            const tree = &trees[next];
            tree.reset();
            env.rtl = i18n.isRtl();

            var ui: U = .{ .tree = tree, .env = env };
            App.view(&state, &ui);
            if (ui.failed) return;

            // Inside the safe area, unless the app draws under the system bars itself (a map does)
            // and keeps its controls clear of them with `env.safe`.
            const s: Insets = if (@hasDecl(App, "edge_to_edge") and App.edge_to_edge) .{} else env.safe;
            const root_frame: st.Rect = .{ .x = s.left, .y = s.top, .w = @max(0, env.width - s.left - s.right), .h = @max(0, env.height - s.top - s.bottom) };
            layout.Engine.runRich(tree, &H.measure, if (@hasDecl(H, "measureRich")) &H.measureRich else null, env.rtl, root_frame) catch return;
            const old: ?*const Tree = if (has_old) &trees[current] else null;
            rec.run(old, tree, .{ .rtl = env.rtl, .pressed = pressed, .hovered = hovered, .reduce_motion = reduce_motion });

            // Handlers now point at host ids, which is what events carry.
            for (ui.presses.items) |*b| b.node = tree.nodes.items[b.node].host;
            for (ui.changes.items) |*b| b.node = tree.nodes.items[b.node].host;
            for (ui.pointers.items) |*b| b.node = tree.nodes.items[b.node].host;
            for (ui.inputs.items) |*b| b.node = tree.nodes.items[b.node].host;
            for (ui.holds.items) |*b| b.node = tree.nodes.items[b.node].host;
            for (ui.contexts.items) |*b| b.node = tree.nodes.items[b.node].host;
            for (ui.hovers.items) |*b| b.node = tree.nodes.items[b.node].host;
            for (ui.links.items) |*b| b.node = tree.nodes.items[b.node].host;
            for (ui.scrolls.items) |*b| b.node = tree.nodes.items[b.node].host;
            presses = ui.presses.items;
            changes = ui.changes.items;
            pointers = ui.pointers.items;
            inputs = ui.inputs.items;
            holds = ui.holds.items;
            contexts = ui.contexts.items;
            hovers = ui.hovers.items;
            link_spans = ui.links.items;
            scroll_handlers = ui.scrolls.items;
            placeScrolls(old, tree);
            if (focus_key) |k| {
                focus_key = null;
                for (tree.nodes.items) |n| if (n.key == k and (n.kind == .input or n.kind == .text_area)) H.focus(n.host);
            }
            if (select_key) |k| {
                select_key = null;
                if (@hasDecl(H, "select")) for (tree.nodes.items) |n| if (n.key == k and (n.kind == .input or n.kind == .text_area)) H.select(n.host, select_range);
            }
            frame_msg = ui.frame_msg;
            if (frame_msg != null) H.requestFrame();
            back_msg = ui.back_msg;
            syncBack();

            // One layout pass for all of this frame's changes, on hosts that need to be told.
            if (@hasDecl(H, "commit")) H.commit();

            const bg = if (ui.background) |c| c.argb() else 0;
            if (bg != background or !has_old) {
                background = bg;
                H.rootBackground(bg);
            }

            current = next;
            has_old = true;
        }
    };
}

test "a response's headers" {
    const r: Response = .{ .status = 200, .body = "", .headers = "content-type: application/json\nx-turf-offline: 1\n" };
    try std.testing.expectEqualStrings("1", r.header("X-Turf-Offline").?);
    try std.testing.expect(r.header("etag") == null);
}
