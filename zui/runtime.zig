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
const calls = @import("calls.zig");

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
    /// The address the app was opened with (web: path and query; phones: a deep link), else "".
    link: []const u8 = "",
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

    pub fn ok(r: Response) bool {
        return r.status >= 200 and r.status < 300;
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
            focus: *const fn (u64) void,
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
            close_media: *const fn (u32) void,
            open_peer: *const fn (Peer, *const fn (PeerEvent) Msg) u32,
            peer_signal: *const fn (u32, []const u8) void,
            peer_stream: *const fn (u32, u32) void,
            close_peer: *const fn (u32) void,
            ring_call: *const fn (Call) void,
            start_call: *const fn (Call) void,
            call_connected: *const fn ([]const u8) void,
            end_call: *const fn ([]const u8) void,
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

        /// The address to reopen this state with (the web page's URL); other platforms keep it
        /// for sharing.
        pub fn setLink(fx: Self, link: []const u8) void {
            fx.vt.set_link(link);
        }

        /// Puts the cursor in the input with this key (after the next draw).
        pub fn focus(fx: Self, input_key: u64) void {
            fx.vt.focus(input_key);
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

pub const Event = enum(u8) { press_in = 1, press_out = 2, press = 3 };

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
        pointers: std.ArrayList(Binding(*const fn (Pointer) Msg)) = .empty,
        /// Sent once at the next display frame (animation), if set.
        frame_msg: ?Msg = null,
        changes: std.ArrayList(Binding(*const fn ([]const u8) Msg)) = .empty,
        inputs: std.ArrayList(Binding(InputHandlers(Msg))) = .empty,
        background: ?Color = null,
        /// Set if memory ran out while building; the frame is then dropped.
        failed: bool = false,

        const Self = @This();

        pub const BoxOptions = struct {
            key: u64 = 0,
            on_press: ?Msg = null,
            /// Raw pointer events (gestures): pan, pinch, rotate, wheel.
            on_pointer: ?*const fn (Pointer) Msg = null,
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
            /// The keyboard's enter / search key.
            on_submit: ?Msg = null,
            style: st.Style = .{},
        };

        /// Memory that lives until this frame's tree is dropped.
        pub fn arena(ui: *Self) std.mem.Allocator {
            return ui.tree.allocator();
        }

        /// Opens a box; everything until `end` goes inside it.
        pub fn begin(ui: *Self, style: st.Style, o: BoxOptions) void {
            const i = ui.tree.open(.{ .kind = .view, .style = style, .key = o.key, .pressable = o.on_press != null, .pointer = o.on_pointer != null }) catch return ui.fail();
            if (o.on_press) |m| ui.presses.append(ui.arena(), .{ .node = i, .value = m }) catch ui.fail();
            if (o.on_pointer) |f| ui.pointers.append(ui.arena(), .{ .node = i, .value = f }) catch ui.fail();
        }

        /// Opens a box whose content scrolls along `style.direction`.
        pub fn beginScroll(ui: *Self, style: st.Style, k: u64) void {
            const kind: tree_mod.Kind = if (style.direction == .row) .scroll_x else .scroll;
            _ = ui.tree.open(.{ .kind = kind, .style = style, .key = k }) catch return ui.fail();
        }

        pub fn end(ui: *Self) void {
            ui.tree.close();
        }

        /// Shows `s` as it is. Use `t` for text that should be translated.
        pub fn text(ui: *Self, s: []const u8, style: st.Style) void {
            _ = ui.tree.add(.{ .kind = .text, .style = style, .text = s }) catch ui.fail();
        }

        pub fn textKeyed(ui: *Self, s: []const u8, style: st.Style, k: u64) void {
            _ = ui.tree.add(.{ .kind = .text, .style = style, .text = s, .key = k }) catch ui.fail();
        }

        pub fn input(ui: *Self, o: InputOptions) void {
            const i = ui.tree.add(.{ .kind = .input, .style = o.style, .key = o.key, .text = o.value, .placeholder = o.placeholder }) catch return ui.fail();
            if (o.on_change) |f| ui.changes.append(ui.arena(), .{ .node = i, .value = f }) catch ui.fail();
            if (o.on_focus != null or o.on_blur != null or o.on_submit != null)
                ui.inputs.append(ui.arena(), .{ .node = i, .value = .{ .focus = o.on_focus, .blur = o.on_blur, .submit = o.on_submit } }) catch ui.fail();
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
        pub fn icon(ui: *Self, ic: icon_mod.Icon, size: f32, color: Color, style: st.Style, k: u64) void {
            const pts = icon_mod.points(ui.arena(), ic, size) catch return ui.fail();
            var s = style;
            s.width = .{ .px = size };
            s.height = .{ .px = size };
            ui.path(pts, if (ic.fill) .{ .color = color, .width = 0, .fill = color } else .{ .color = color, .width = ic.stroke * size / ic.box }, s, k);
        }

        /// A filled icon with an outline in `outline` (a pin, a vehicle arrow).
        pub fn iconOutlined(ui: *Self, ic: icon_mod.Icon, size: f32, fill: Color, outline: Color, outline_width: f32, style: st.Style, k: u64) void {
            const pts = icon_mod.points(ui.arena(), ic, size) catch return ui.fail();
            var s = style;
            s.width = .{ .px = size };
            s.height = .{ .px = size };
            ui.path(pts, .{ .color = outline, .width = outline_width, .fill = fill }, s, k);
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
    return struct { focus: ?Msg, blur: ?Msg, submit: ?Msg };
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
        var background: u32 = 0;
        /// Handlers of the frame on screen, by host id.
        var presses: []const Binding(Msg) = &.{};
        var pointers: []const Binding(*const fn (Pointer) Msg) = &.{};
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

        const vtable: Fx(Msg).VTable = .{
            .fetch = fxFetch,
            .after = fxAfter,
            .location = fxLocation,
            .speak = fxSpeak,
            .set_link = fxSetLink,
            .focus = fxFocus,
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
            .close_media = fxCloseMedia,
            .open_peer = fxOpenPeer,
            .peer_signal = fxPeerSignal,
            .peer_stream = fxPeerStream,
            .close_peer = fxClosePeer,
            .ring_call = fxRingCall,
            .start_call = fxStartCall,
            .call_connected = fxCallConnected,
            .end_call = fxEndCall,
        };

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

        fn fxSetLink(link: []const u8) void {
            H.setLink(link);
        }

        fn fxFocus(k: u64) void {
            focus_key = k;
        }

        /// `lang` is the system language ("ar", "en-US", ...); the app starts in it when it has a
        /// bundle for it, otherwise in English.
        pub fn start(allocator: std.mem.Allocator, e: Env, lang: []const u8) void {
            gpa = allocator;
            trees = .{ Tree.init(gpa), Tree.init(gpa) };
            rec = .{ .gpa = gpa };
            env = e;
            if (@hasDecl(App, "locales")) {
                const global = if (@hasDecl(App, "global_locale")) App.global_locale else "{}";
                i18n.init(gpa, global, App.locales) catch {};
                const base = lang[0 .. std.mem.indexOfAny(u8, lang, "-_") orelse lang.len];
                for (App.locales) |l| {
                    if (std.ascii.eqlIgnoreCase(l.lang, base)) i18n.setLanguage(l.lang);
                }
            }
            state = App.init();
            started = true;
            render();
            // An app that needs effects at startup (location, reading its link) declares
            // `pub const boot: Msg`.
            if (@hasDecl(App, "boot")) dispatch(App.boot);
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
                    render();
                },
                .press_out => if (pressed == id) {
                    pressed = 0;
                    render();
                },
                .press => for (presses) |b| {
                    if (b.node == id) return dispatch(b.value);
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
                // Moves arrive faster than the screen refreshes (and once per finger): the state
                // follows every one, the screen once per display frame.
                if (p.kind != .move or rendering) return dispatch(b.value(p));
                apply(b.value(p));
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
                if (b.node == id) return dispatch(b.value(text));
            }
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
            const f = (fetches.fetchRemove(id) orelse return).value;
            if (started) dispatch(f.done(.{ .status = status, .body = body, .tag = f.tag }));
        }

        pub fn timerDone(id: u32) void {
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

        pub fn callEvent(kind: CallEvent.Kind, id: []const u8) void {
            if (!started or !@hasDecl(App, "callEvent")) return;
            if (App.callEvent(.{ .kind = kind, .id = id })) |m| dispatch(m);
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
            switch (@typeInfo(@TypeOf(App.update)).@"fn".param_types.len) {
                2 => App.update(&state, msg),
                3 => App.update(&state, msg, env),
                else => App.update(&state, msg, env, fx),
            }
        }

        fn render() void {
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
            layout.Engine.run(tree, &H.measure, env.rtl, root_frame) catch return;
            rec.run(if (has_old) &trees[current] else null, tree, .{ .rtl = env.rtl, .pressed = pressed });

            // Handlers now point at host ids, which is what events carry.
            for (ui.presses.items) |*b| b.node = tree.nodes.items[b.node].host;
            for (ui.changes.items) |*b| b.node = tree.nodes.items[b.node].host;
            for (ui.pointers.items) |*b| b.node = tree.nodes.items[b.node].host;
            for (ui.inputs.items) |*b| b.node = tree.nodes.items[b.node].host;
            presses = ui.presses.items;
            changes = ui.changes.items;
            pointers = ui.pointers.items;
            inputs = ui.inputs.items;
            if (focus_key) |k| {
                focus_key = null;
                for (tree.nodes.items) |n| if (n.key == k and n.kind == .input) H.focus(n.host);
            }
            frame_msg = ui.frame_msg;
            if (frame_msg != null) H.requestFrame();

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
