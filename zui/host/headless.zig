//! Headless host: keeps the "native views" as plain records, with a fake font (8 points per
//! character). Used by the tests on the build machine: `Driver` runs an app without a device and
//! lets a test press buttons, type text and read what is on screen.

const std = @import("std");
const zui = @import("../zui.zig");
const layout = @import("../layout.zig");

const Self = @This();

pub const View = struct {
    kind: zui.tree.Kind,
    parent: u32 = 0,
    frame: zui.Rect = .{},
    box: zui.Box = .{},
    text: std.ArrayList(u8) = .empty,
    placeholder: std.ArrayList(u8) = .empty,
    pressable: bool = false,
    pointer: bool = false,
    transform: zui.Transform = .{},
    clip: bool = false,
    path_points: usize = 0,
    input_type: zui.InputType = .{},
    headers: std.ArrayList(u8) = .empty,
    gestures: zui.Gestures = .{},
    /// Rich text: how many spans; images from memory: how many bytes came.
    spans: usize = 0,
    bytes: usize = 0,
    fit: zui.Fit = .fill,
    transition: ?zui.Transition = null,
    spin_ms: u16 = 0,
    /// Scroll views: where zui last put it, and whether that was animated.
    scrolled_to: ?f32 = null,
    scroll_animated: bool = false,
};

// The additions of zui's styling work: rich text, gestures, pictures from memory, animation,
// scrolling. Measuring rich text uses the fake font too.
pub fn richText(id: u32, s: []const u8, spans: []const zui.Span, _: zui.Font, _: u32, _: zui.PhysicalAlign) void {
    const v = views.getPtr(id) orelse return;
    v.text.clearRetainingCapacity();
    v.text.appendSlice(gpa, s) catch {};
    v.spans = spans.len;
}
pub fn measureRich(s: []const u8, _: []const zui.Span, font: zui.Font, max_width: f32) zui.Size {
    return layout.fakeMeasure(s, font, max_width);
}
pub fn gestures(id: u32, g: zui.Gestures) void {
    if (views.getPtr(id)) |v| v.gestures = g;
}
pub fn imageBytes(id: u32, key: []const u8, bytes: []const u8) void {
    const v = views.getPtr(id) orelse return;
    v.text.clearRetainingCapacity();
    v.text.appendSlice(gpa, key) catch {};
    v.bytes = bytes.len;
}
pub fn imageFit(id: u32, f: zui.Fit) void {
    if (views.getPtr(id)) |v| v.fit = f;
}
pub fn transition(id: u32, t: ?zui.Transition) void {
    if (views.getPtr(id)) |v| v.transition = t;
}
pub fn spin(id: u32, ms: u16) void {
    if (views.getPtr(id)) |v| v.spin_ms = ms;
}
pub fn scrollTo(id: u32, offset: f32, animated: bool) void {
    const v = views.getPtr(id) orelse return;
    v.scrolled_to = offset;
    v.scroll_animated = animated;
}
/// Barcode scanners the app opened, and whether they look with the back camera.
pub var scan_open: u32 = 0;
pub var scan_back = false;
pub fn scanOpen(id: u32, _: zui.barcode.Formats, back: bool) void {
    scan_open = id;
    scan_back = back;
}
pub fn scanClose(id: u32) void {
    if (scan_open == id) scan_open = 0;
}
pub var haptics: u32 = 0;
pub fn haptic() void {
    haptics += 1;
}

/// Set when the app asked for a frame; `Driver.frame` delivers it.
pub var frame_requested = false;
/// The test clock for frames, in milliseconds.
pub var clock_ms: f64 = 0;

/// Requests the app made and the test has not answered yet.
pub const PendingFetch = struct { id: u32, method: []const u8, url: []u8, body: []u8, headers: []u8 = &.{} };
/// The device storage.
pub var stored: std.StringHashMapUnmanaged([]u8) = .empty;
pub var fetches: std.ArrayList(PendingFetch) = .empty;
pub var timers: std.ArrayList(struct { id: u32, ms: u32 }) = .empty;
pub var location_on = false;
pub var spoken: std.ArrayList(u8) = .empty;
pub var link: std.ArrayList(u8) = .empty;
pub var focused: u32 = 0;
pub var posted: std.ArrayList(u8) = .empty;
pub var clipboard: std.ArrayList(u8) = .empty;
pub var opened: std.ArrayList(u8) = .empty;
pub var socket_url: std.ArrayList(u8) = .empty;
pub var socket_id: u32 = 0;

const gpa = std.heap.page_allocator;
pub var views: std.AutoArrayHashMapUnmanaged(u32, View) = .empty;
pub var root_background: u32 = 0;

pub fn create(id: u32, kind: zui.tree.Kind) void {
    views.put(gpa, id, .{ .kind = kind }) catch {};
}
pub fn destroy(id: u32) void {
    if (views.getPtr(id)) |v| {
        v.text.deinit(gpa);
        v.placeholder.deinit(gpa);
    }
    _ = views.swapRemove(id);
}
pub fn insert(parent: u32, id: u32, _: u32) void {
    if (views.getPtr(id)) |v| v.parent = parent;
}
pub fn frame(id: u32, r: zui.Rect) void {
    if (views.getPtr(id)) |v| v.frame = r;
}
pub fn box(id: u32, b: zui.Box) void {
    if (views.getPtr(id)) |v| v.box = b;
}
pub fn pressable(id: u32, on: bool) void {
    if (views.getPtr(id)) |v| v.pressable = on;
}
pub fn text(id: u32, s: []const u8, _: zui.Font, _: u32, _: zui.PhysicalAlign) void {
    const v = views.getPtr(id) orelse return;
    v.text.clearRetainingCapacity();
    v.text.appendSlice(gpa, s) catch {};
}
pub fn input(id: u32, value: []const u8, placeholder: []const u8, _: zui.Font, _: u32, _: zui.PhysicalAlign) void {
    const v = views.getPtr(id) orelse return;
    v.text.clearRetainingCapacity();
    v.text.appendSlice(gpa, value) catch {};
    v.placeholder.clearRetainingCapacity();
    v.placeholder.appendSlice(gpa, placeholder) catch {};
}
pub fn content(_: u32, _: zui.Size) void {}
pub fn inputType(id: u32, t: zui.InputType) void {
    if (views.getPtr(id)) |v| v.input_type = t;
}
/// What the app asked for: a photo (camera or not, its size), a file (what it accepts), and the
/// last file it saved.
pub var photo_asked: ?struct { camera: bool, max_size: u32, quality: u8 } = null;
pub var file_accept: ?[]const u8 = null;
pub var saved_name: std.ArrayList(u8) = .empty;
pub var saved_data: std.ArrayList(u8) = .empty;
pub var saved_share = false;
pub fn pickPhoto(camera: bool, max_size: u32, quality: u8) void {
    photo_asked = .{ .camera = camera, .max_size = max_size, .quality = quality };
}
pub fn pickFile(accept: []const u8) void {
    file_accept = gpa.dupe(u8, accept) catch "";
}
pub fn saveFile(name: []const u8, _: []const u8, data: []const u8, share: bool) void {
    saved_name.clearRetainingCapacity();
    saved_name.appendSlice(gpa, name) catch {};
    saved_data.clearRetainingCapacity();
    saved_data.appendSlice(gpa, data) catch {};
    saved_share = share;
}
/// The picker the app opened and what it was given (options one a line).
pub var picker: ?zui.PickKind = null;
pub var picker_value: std.ArrayList(u8) = .empty;
pub var picker_options: std.ArrayList(u8) = .empty;
pub var picker_selected: i32 = -1;
pub fn pick(kind: zui.PickKind, value: []const u8, _: []const u8, _: []const u8, _: []const u8, options: []const u8, selected: i32) void {
    picker = kind;
    picker_value.clearRetainingCapacity();
    picker_value.appendSlice(gpa, value) catch {};
    picker_options.clearRetainingCapacity();
    picker_options.appendSlice(gpa, options) catch {};
    picker_selected = selected;
}
pub fn transform(id: u32, t: zui.Transform) void {
    if (views.getPtr(id)) |v| v.transform = t;
}
pub fn clip(id: u32, on: bool) void {
    if (views.getPtr(id)) |v| v.clip = on;
}
pub fn pointer(id: u32, on: bool) void {
    if (views.getPtr(id)) |v| v.pointer = on;
}
pub fn image(id: u32, url: []const u8, headers: []const u8) void {
    const v = views.getPtr(id) orelse return;
    v.text.clearRetainingCapacity();
    v.text.appendSlice(gpa, url) catch {};
    v.headers.clearRetainingCapacity();
    v.headers.appendSlice(gpa, headers) catch {};
}
/// The event stream connection open now (0: none), its URL and headers.
pub var stream_conn: u32 = 0;
pub var stream_url: std.ArrayList(u8) = .empty;
pub var stream_headers: std.ArrayList(u8) = .empty;
pub fn streamOpen(conn: u32, url: []const u8, headers: []const u8) void {
    stream_conn = conn;
    stream_url.clearRetainingCapacity();
    stream_url.appendSlice(gpa, url) catch {};
    stream_headers.clearRetainingCapacity();
    stream_headers.appendSlice(gpa, headers) catch {};
}
pub fn streamClose(conn: u32) void {
    if (stream_conn == conn) stream_conn = 0;
}
pub fn imageFilter(_: u32, _: zui.ImageFilter) void {}
pub fn path(id: u32, p: zui.Path) void {
    if (views.getPtr(id)) |v| v.path_points = p.points.len;
}
pub fn requestFrame() void {
    frame_requested = true;
}
pub fn fetch(id: u32, method: []const u8, url: []const u8, body: []const u8, _: []const u8, headers: []const u8) void {
    fetches.append(gpa, .{ .id = id, .method = method, .url = gpa.dupe(u8, url) catch return, .body = gpa.dupe(u8, body) catch return, .headers = gpa.dupe(u8, headers) catch return }) catch {};
}
pub fn storageGet(a: std.mem.Allocator, key: []const u8, _: bool) ?[]u8 {
    const v = stored.get(key) orelse return null;
    return a.dupe(u8, v) catch null;
}
pub fn storageSet(key: []const u8, value: []const u8, _: bool) void {
    const gop = stored.getOrPut(gpa, key) catch return;
    if (gop.found_existing) gpa.free(gop.value_ptr.*) else gop.key_ptr.* = gpa.dupe(u8, key) catch return;
    gop.value_ptr.* = gpa.dupe(u8, value) catch return;
}
pub fn storageRemove(key: []const u8, _: bool) void {
    if (stored.fetchRemove(key)) |kv| {
        gpa.free(kv.key);
        gpa.free(kv.value);
    }
}
pub fn timer(id: u32, ms: u32) void {
    timers.append(gpa, .{ .id = id, .ms = ms }) catch {};
}
pub fn location(on: bool) void {
    location_on = on;
}
pub fn speak(s: []const u8, _: []const u8) void {
    spoken.clearRetainingCapacity();
    spoken.appendSlice(gpa, s) catch {};
}
pub fn setLink(s: []const u8) void {
    link.clearRetainingCapacity();
    link.appendSlice(gpa, s) catch {};
}
pub fn focus(id: u32) void {
    focused = id;
}
/// Every message the app posted, one per line.
pub fn post(json: []const u8) void {
    posted.appendSlice(gpa, json) catch {};
    posted.append(gpa, 10) catch {}; // newline
}
pub fn openSocket(id: u32, url: []const u8) void {
    socket_id = id;
    socket_url.clearRetainingCapacity();
    socket_url.appendSlice(gpa, url) catch {};
}
pub fn sendSocket(_: u32, _: []const u8) void {}
pub var widget_title: std.ArrayList(u8) = .empty;
pub fn widgetUpdate(title: []const u8, _: []const u8, _: []const u8, _: []const u8) void {
    widget_title.clearRetainingCapacity();
    widget_title.appendSlice(gpa, title) catch {};
}
/// Calls: what the app asked for, for tests (a test answers with R.mediaEvent / R.peerEvent).
pub var media_open: u32 = 0;
pub var peer_open: u32 = 0;
pub var peer_polite = false;
pub var signals: std.ArrayList(u8) = .empty;
pub fn openMedia(id: u32, _: zui.Media) void {
    media_open = id;
}
pub fn mediaEnable(_: u32, _: bool, _: bool) void {}
pub fn switchCamera(_: u32) void {}
pub fn closeMedia(_: u32) void {
    media_open = 0;
}
pub fn openPeer(id: u32, p: zui.Peer) void {
    peer_open = id;
    peer_polite = p.polite;
}
pub fn peerSignal(_: u32, json: []const u8) void {
    signals.appendSlice(gpa, json) catch {};
    signals.append(gpa, 10) catch {};
}
pub fn peerStream(_: u32, _: u32) void {}
pub fn closePeer(_: u32) void {
    peer_open = 0;
}
pub fn video(_: u32, _: zui.Video) void {}
/// Recording and playback: what the app asked for, for tests (a test answers with
/// R.recordEvent / R.playEvent).
pub var recording: u32 = 0;
pub var recording_video = false;
pub var recording_stopped = false;
pub var playing: u32 = 0;
pub var playing_url: std.ArrayList(u8) = .empty;
pub var playing_bytes: usize = 0;
pub var playback_controls: std.ArrayList(zui.PlaybackControl) = .empty;
pub fn startRecording(id: u32, r: zui.Recording) void {
    recording = id;
    recording_video = r.video;
    recording_stopped = false;
}
pub fn stopRecording(_: u32, cancel: bool) void {
    recording_stopped = true;
    if (cancel) recording = 0;
}
pub fn play(id: u32, p: zui.Playback) void {
    playing = id;
    playing_url.clearRetainingCapacity();
    playing_url.appendSlice(gpa, p.url) catch {};
    playing_bytes = p.data.len;
}
pub fn controlPlayback(_: u32, c: zui.PlaybackControl) void {
    playback_controls.append(gpa, c) catch {};
}
pub var ringing: std.ArrayList(u8) = .empty;
pub fn ringCall(c: zui.Call) void {
    ringing.clearRetainingCapacity();
    ringing.appendSlice(gpa, c.id) catch {};
}
pub fn startCall(_: zui.Call) void {}
pub fn callConnected(_: []const u8) void {}
pub fn endCall(_: []const u8) void {
    ringing.clearRetainingCapacity();
}
/// fx.registerPush: how many times, and the Web Push key it was given (a test answers with
/// R.pushToken).
pub var push_registered: u32 = 0;
pub var push_web_key: std.ArrayList(u8) = .empty;
pub fn registerPush(o: zui.PushOptions) void {
    push_registered += 1;
    push_web_key.clearRetainingCapacity();
    push_web_key.appendSlice(gpa, o.web_key) catch {};
}
pub var notified: std.ArrayList(u8) = .empty;
pub fn notify(n: zui.Notification) void {
    notified.clearRetainingCapacity();
    notified.appendSlice(gpa, n.title) catch {};
}
pub fn cancelNotify(_: u32) void {
    notified.clearRetainingCapacity();
}
pub var background_location = false;
pub fn backgroundLocation(on: bool, _: []const u8, _: []const u8) void {
    background_location = on;
}
pub fn copy(value: []const u8) void {
    clipboard.clearRetainingCapacity();
    clipboard.appendSlice(gpa, value) catch {};
}
pub fn openUrl(url: []const u8, _: bool) void {
    opened.clearRetainingCapacity();
    opened.appendSlice(gpa, url) catch {};
}
pub fn closeSocket(_: u32) void {
    socket_id = 0;
}
/// The wall clock tests see (2025-10-12T12:00:00Z unless a test sets it) and the time zone.
pub var wall_ms: i64 = 1_760_270_400_000;
pub var tz_minutes: i32 = 0;
pub fn now() i64 {
    return wall_ms;
}
pub fn tzOffset() i32 {
    return tz_minutes;
}
pub var vibrated_ms: u32 = 0;
pub var beeps: u32 = 0;
pub var awake = false;
pub fn vibrate(ms: u32) void {
    vibrated_ms = ms;
}
pub fn beep() void {
    beeps += 1;
}
pub fn keepAwake(on: bool) void {
    awake = on;
}
/// Whether the app handles Back, and whether there are links to go back to.
pub var back_handler = false;
pub var back_history = false;
pub fn backState(handler: bool, has_history: bool, _: bool) void {
    back_handler = handler;
    back_history = has_history;
}
/// Test randomness (the key store's): fixed seed, so runs repeat.
var test_prng = std.Random.DefaultPrng.init(0x5eed);
pub fn randomBytes(buf: []u8) void {
    test_prng.random().bytes(buf);
}
pub fn rootBackground(argb: u32) void {
    root_background = argb;
}
pub fn measure(s: []const u8, font: zui.Font, max_width: f32) zui.Size {
    return layout.fakeMeasure(s, font, max_width);
}

pub fn exportEntry(comptime App: type) void {
    _ = App;
}

/// Runs `App` on the headless host, for tests.
pub fn Driver(comptime App: type) type {
    return struct {
        pub const R = zui.runtime.Runtime(App, Self);

        pub fn start(width: f32, height: f32) void {
            startWith(width, height, "");
        }

        /// Starts as if opened with `link_` (web: path and query).
        pub fn startWith(width: f32, height: f32, link_: []const u8) void {
            reset();
            R.start(std.heap.page_allocator, .{ .width = width, .height = height, .link = link_ }, "en");
        }

        /// Starts as a push would when the app is not running: no screen yet.
        pub fn startHeadless() void {
            reset();
            R.startHeadless(std.heap.page_allocator, "en");
        }

        pub fn reset() void {
            for (views.values()) |*v| {
                v.text.deinit(gpa);
                v.placeholder.deinit(gpa);
            }
            views.clearRetainingCapacity();
            for (fetches.items) |f| {
                gpa.free(f.url);
                gpa.free(f.body);
            }
            fetches.clearRetainingCapacity();
            timers.clearRetainingCapacity();
            location_on = false;
            spoken.clearRetainingCapacity();
            link.clearRetainingCapacity();
            posted.clearRetainingCapacity();
            clipboard.clearRetainingCapacity();
            opened.clearRetainingCapacity();
            socket_url.clearRetainingCapacity();
            socket_id = 0;
            frame_requested = false;
            vibrated_ms = 0;
            beeps = 0;
            awake = false;
            picker = null;
            photo_asked = null;
            file_accept = null;
            stream_conn = 0;
            haptics = 0;
            scan_open = 0;
            push_registered = 0;
        }

        /// Back (Android's button, the iOS swipe). Returns whether the app took it.
        pub fn back() bool {
            return R.back();
        }

        /// The address changed from outside (the browser's forward button, a deep link).
        pub fn openLink(l: []const u8) void {
            R.linkEvent(l);
        }

        pub fn device(e: zui.DeviceEvent) void {
            R.deviceEvent(e);
        }

        /// Answers the oldest pending request whose URL contains `part`. Returns false if none.
        pub fn respond(part: []const u8, status: u16, body: []const u8) bool {
            for (fetches.items, 0..) |f, i| {
                if (std.mem.indexOf(u8, f.url, part) == null) continue;
                const done = fetches.orderedRemove(i);
                defer {
                    gpa.free(done.url);
                    gpa.free(done.body);
                }
                R.fetchDone(done.id, status, body);
                return true;
            }
            return false;
        }

        /// URL of the oldest pending request containing `part`, if any.
        pub fn pending(part: []const u8) ?[]const u8 {
            for (fetches.items) |f| if (std.mem.indexOf(u8, f.url, part) != null) return f.url;
            return null;
        }

        /// Fires every pending timer.
        pub fn runTimers() void {
            while (timers.items.len > 0) {
                const t = timers.orderedRemove(0);
                R.timerDone(t.id);
            }
        }

        /// A position fix from the "device".
        pub fn locate(lat: f64, lng: f64) void {
            R.locationEvent(.{ .fix = .{ .lat = lat, .lng = lng, .accuracy = 5 } });
        }

        /// The server of the open event stream answers with `status`.
        pub fn serverStatus(status: u16) void {
            R.streamStatus(stream_conn, status);
        }

        /// The server sends bytes on the open event stream.
        pub fn serverSend(bytes: []const u8) void {
            R.streamData(stream_conn, bytes);
        }

        /// The open event stream's connection ends.
        pub fn serverEnd() void {
            const c = stream_conn;
            stream_conn = 0;
            R.streamEnd(c);
        }

        /// The user chose a photo or a file.
        pub fn giveFile(f: zui.File) void {
            photo_asked = null;
            file_accept = null;
            R.fileDone(f.data, f.name, f.mime, f.width, f.height);
        }

        /// The user chooses in the open picker: a date, a time, or an option's index ("2").
        pub fn choose(value: []const u8) !void {
            if (picker == null) return error.NoPicker;
            picker = null;
            R.pickDone(value);
        }

        /// The input or text area whose placeholder is `placeholder`.
        pub fn inputView(placeholder: []const u8) ?*View {
            var it = views.iterator();
            while (it.next()) |e| {
                if ((e.value_ptr.kind == .input or e.value_ptr.kind == .text_area) and std.mem.eql(u8, e.value_ptr.placeholder.items, placeholder)) return e.value_ptr;
            }
            return null;
        }

        /// Focus, blur or enter on the input whose placeholder is `placeholder`.
        pub fn inputEvent(placeholder: []const u8, kind: zui.InputEvent) !void {
            var it = views.iterator();
            while (it.next()) |e| {
                if ((e.value_ptr.kind == .input or e.value_ptr.kind == .text_area) and std.mem.eql(u8, e.value_ptr.placeholder.items, placeholder)) {
                    return R.inputEvent(e.key_ptr.*, kind);
                }
            }
            return error.NoSuchInput;
        }

        /// Id of the text view showing exactly `s`, or 0.
        pub fn findText(s: []const u8) u32 {
            var it = views.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.kind == .text and std.mem.eql(u8, e.value_ptr.text.items, s)) return e.key_ptr.*;
            }
            return 0;
        }

        /// Presses the nearest pressable view around the text `label`.
        pub fn press(label: []const u8) !void {
            var id = findText(label);
            while (id != 0) : (id = views.get(id).?.parent) {
                if (views.get(id).?.pressable) {
                    R.event(id, .press_in);
                    R.event(id, .press_out);
                    R.event(id, .press);
                    return;
                }
            }
            return error.NothingToPress;
        }

        /// The nearest pressable view around the text `label`, or 0.
        pub fn pressableOf(label: []const u8) u32 {
            var id = findText(label);
            while (id != 0) : (id = views.get(id).?.parent) {
                if (views.get(id).?.pressable) return id;
            }
            return 0;
        }

        /// Holds the view around `label` down past the long press, then lets go.
        pub fn longPress(label: []const u8) !void {
            const id = pressableOf(label);
            if (id == 0) return error.NothingToPress;
            R.event(id, .press_in);
            runTimers();
            R.event(id, .press_out);
            R.event(id, .press);
        }

        /// A secondary click (the context menu) on the view around `label`.
        pub fn context(label: []const u8) !void {
            const id = pressableOf(label);
            if (id == 0) return error.NothingToPress;
            R.event(id, .context);
        }

        /// The mouse comes onto (or leaves) the view with id `id`.
        pub fn hover(id: u32, on: bool) void {
            R.event(id, if (on) .hover_in else .hover_out);
        }

        /// Presses link `index` of the text view whose text contains `part`.
        pub fn pressLink(part: []const u8, index: u32) !void {
            var it = views.iterator();
            while (it.next()) |e| {
                const v = e.value_ptr;
                if ((v.kind == .text or v.kind == .text_select) and std.mem.indexOf(u8, v.text.items, part) != null) {
                    return R.spanPress(e.key_ptr.*, index);
                }
            }
            return error.NoSuchText;
        }

        /// The first scroll view (in creation order of the views kept), or 0.
        pub fn scrollView() u32 {
            var it = views.iterator();
            while (it.next()) |e| if (e.value_ptr.kind == .scroll or e.value_ptr.kind == .scroll_x) return e.key_ptr.*;
            return 0;
        }

        /// The open scanner's camera starts, and sees `img`.
        pub fn scanStarted() void {
            R.scanState(scan_open, .started, "");
        }
        pub fn scanFrame(img: zui.barcode.Image) void {
            R.scanFrame(scan_open, img);
        }

        /// The user scrolled view `id` to `offset`.
        pub fn scroll(id: u32, offset: f32) void {
            R.scrollEvent(id, offset);
        }

        /// Types `s` into the input whose placeholder is `placeholder`.
        pub fn typeInto(placeholder: []const u8, s: []const u8) !void {
            var it = views.iterator();
            while (it.next()) |e| {
                if ((e.value_ptr.kind == .input or e.value_ptr.kind == .text_area) and std.mem.eql(u8, e.value_ptr.placeholder.items, placeholder)) {
                    return R.textEvent(e.key_ptr.*, s);
                }
            }
            return error.NoSuchInput;
        }

        /// Frame relative to the parent view.
        /// The first view that listens for pointers.
        pub fn pointerView() u32 {
            var it = views.iterator();
            while (it.next()) |e| if (e.value_ptr.pointer) return e.key_ptr.*;
            return 0;
        }

        pub fn pointer(p: zui.Pointer) void {
            R.pointerEvent(pointerView(), p);
        }

        /// Delivers a requested frame, if any. Returns whether there was one.
        pub fn frame() bool {
            if (!frame_requested) return false;
            frame_requested = false;
            clock_ms += 16;
            R.frame(clock_ms);
            return true;
        }

        /// Views showing `url`.
        pub fn countImages() usize {
            var n: usize = 0;
            var it = views.iterator();
            while (it.next()) |e| if (e.value_ptr.kind == .image) {
                n += 1;
            };
            return n;
        }

        pub fn frameOf(id: u32) zui.Rect {
            return views.get(id).?.frame;
        }

        /// Frame relative to the screen (scroll offsets are not applied).
        pub fn absoluteFrame(id: u32) zui.Rect {
            var r = frameOf(id);
            var p = views.get(id).?.parent;
            while (p != 0) : (p = views.get(p).?.parent) {
                const f = views.get(p).?.frame;
                r.x += f.x;
                r.y += f.y;
            }
            return r;
        }
    };
}

// A small counter app, to test the whole loop.
const Counter = struct {
    pub const Msg = union(enum) { add, name: []const u8 };
    pub const State = struct { n: u32 = 0, name_buf: [32]u8 = undefined, name_len: usize = 0 };
    pub fn init() State {
        return .{};
    }
    pub fn update(s: *State, m: Msg) void {
        switch (m) {
            .add => s.n += 1,
            .name => |v| {
                s.name_len = @min(v.len, s.name_buf.len);
                @memcpy(s.name_buf[0..s.name_len], v[0..s.name_len]);
            },
        }
    }
    fn onName(v: []const u8) Msg {
        return .{ .name = v };
    }
    pub fn view(s: *const State, ui: *zui.Ui(Msg)) void {
        ui.begin(.{ .padding = .all(10), .gap = 8 }, .{});
        ui.text(ui.tf("Count {n}", .{ .n = s.n }), .{});
        ui.begin(.{ .padding = .all(4) }, .{ .on_press = .add });
        ui.text("Add", .{});
        ui.end();
        ui.input(.{ .value = s.name_buf[0..s.name_len], .placeholder = "Name", .on_change = onName });
        ui.text(s.name_buf[0..s.name_len], .{});
        ui.end();
    }
};

test "the loop: press, type, re-render" {
    const D = Driver(Counter);
    D.start(200, 400);
    defer D.reset();
    try std.testing.expect(D.findText("Count 0") != 0);
    try D.press("Add");
    try D.press("Add");
    try std.testing.expect(D.findText("Count 2") != 0);
    try D.typeInto("Name", "Sara");
    try std.testing.expect(D.findText("Sara") != 0);
    try std.testing.expectEqual(@as(f32, 10), D.frameOf(D.findText("Count 2")).x);
}

pub fn log(line: []const u8) void {
    std.debug.print("{s}\n", .{line});
}

const Caller = struct {
    pub const Msg = union(enum) { call, media: zui.MediaEvent, peer: zui.PeerEvent };
    pub const State = struct { stream: u32 = 0, peer: u32 = 0, remote: u32 = 0, state: [16]u8 = undefined, state_len: usize = 0 };
    pub fn init() State {
        return .{};
    }
    fn onMedia(e: zui.MediaEvent) Msg {
        return .{ .media = e };
    }
    fn onPeer(e: zui.PeerEvent) Msg {
        return .{ .peer = e };
    }
    pub fn update(s: *State, msg: Msg, _: zui.Env, fx: zui.runtime.Fx(Msg)) void {
        switch (msg) {
            .call => s.stream = fx.openMedia(.{ .video = true }, onMedia),
            .media => |e| if (e.kind == .ready) {
                s.peer = fx.openPeer(.{ .polite = true, .stream = e.stream }, onPeer);
            },
            .peer => |e| switch (e.kind) {
                .signal => fx.peerSignal(s.peer, e.data), // echoes back, for the test
                .state => {
                    s.state_len = @min(e.data.len, s.state.len);
                    @memcpy(s.state[0..s.state_len], e.data[0..s.state_len]);
                },
                .track => s.remote = e.stream,
            },
        }
    }
    pub fn view(s: *const State, ui: *zui.Ui(Msg)) void {
        ui.begin(.{}, .{ .on_press = .call });
        ui.text("Call", .{});
        if (s.remote != 0) ui.video(s.remote, .{}, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, 0);
        ui.text(s.state[0..s.state_len], .{});
        ui.end();
    }
};

test "a call: media, a peer, its signals, state and the other side's video" {
    const D = Driver(Caller);
    D.start(200, 400);
    defer D.reset();
    defer signals.clearRetainingCapacity();
    try D.press("Call");
    try std.testing.expect(media_open != 0);
    D.R.mediaEvent(media_open, .ready, "");
    try std.testing.expect(peer_open != 0 and peer_polite);
    D.R.peerEvent(peer_open, .signal, "{\"candidate\":{}}", 0);
    try std.testing.expectEqualStrings("{\"candidate\":{}}\n", signals.items);
    D.R.peerEvent(peer_open, .state, "connected", 0);
    try std.testing.expect(D.findText("connected") != 0);
    D.R.peerEvent(peer_open, .track, "", 0x80000000);
    var videos: usize = 0;
    for (views.values()) |v| videos += @intFromBool(v.kind == .video);
    try std.testing.expectEqual(@as(usize, 1), videos);
}

// Navigation: links with history, Back, and the app's own Back handler.
const Nav = struct {
    pub const Msg = union(enum) { open: []const u8, close_sheet, open_sheet, link: []const u8, device: zui.DeviceEvent };
    pub const State = struct { sheet: bool = false, page: [32]u8 = undefined, page_len: usize = 0, events: u32 = 0, offline: bool = false, now: i64 = 0 };
    pub fn init() State {
        return .{};
    }
    pub fn linkEvent(l: []const u8) ?Msg {
        return .{ .link = l };
    }
    pub fn deviceEvent(e: zui.DeviceEvent) ?Msg {
        return .{ .device = e };
    }
    fn setPage(s: *State, l: []const u8) void {
        s.page_len = @min(l.len, s.page.len);
        @memcpy(s.page[0..s.page_len], l[0..s.page_len]);
    }
    pub fn update(s: *State, msg: Msg, env: zui.Env, fx: zui.runtime.Fx(Msg)) void {
        s.now = env.now_ms;
        switch (msg) {
            .open => |l| {
                fx.pushLink(l);
                setPage(s, l);
            },
            .link => |l| setPage(s, l),
            .open_sheet => s.sheet = true,
            .close_sheet => s.sheet = false,
            .device => |e| {
                s.events += 1;
                s.offline = !env.online;
                if (e == .hidden) fx.keepAwake(false);
            },
        }
    }
    pub fn view(s: *const State, ui: *zui.Ui(Msg)) void {
        ui.begin(.{}, .{});
        ui.text(if (s.page_len == 0) "/" else s.page[0..s.page_len], .{});
        ui.begin(.{}, .{ .on_press = .{ .open = "/a" } });
        ui.text("A", .{});
        ui.end();
        ui.begin(.{}, .{ .on_press = .{ .open = "/b" } });
        ui.text("B", .{});
        ui.end();
        ui.begin(.{}, .{ .on_press = .open_sheet });
        ui.text("Sheet", .{});
        ui.end();
        if (s.sheet) {
            ui.text("Sheet open", .{});
            ui.onBack(.close_sheet);
        }
        if (!ui.env.online) ui.text("Offline", .{});
        ui.end();
    }
};

test "links: pushLink makes history, Back walks it, the app's onBack comes first" {
    const D = Driver(Nav);
    D.start(200, 400);
    defer D.reset();
    try std.testing.expect(!D.back()); // nothing to go back to: the platform's default
    try std.testing.expect(!back_history);
    try D.press("A");
    try D.press("B");
    try std.testing.expectEqualStrings("/b", link.items);
    try std.testing.expect(back_history);
    try D.press("Sheet");
    try std.testing.expect(back_handler);
    try std.testing.expect(D.back()); // closes the sheet, stays on /b
    try std.testing.expect(D.findText("Sheet open") == 0);
    try std.testing.expect(D.findText("/b") != 0);
    try std.testing.expect(!back_handler);
    try std.testing.expect(D.back()); // to /a
    try std.testing.expect(D.findText("/a") != 0);
    try std.testing.expectEqualStrings("/a", link.items);
    try std.testing.expectEqualStrings("/a", D.R.appState().page[0..2]);
    try std.testing.expect(D.back()); // to the start
    try std.testing.expect(!D.back());
    try std.testing.expect(!back_history);
    D.openLink("/deep");
    try std.testing.expect(D.findText("/deep") != 0);
}

test "device events, the wall clock" {
    const D = Driver(Nav);
    wall_ms = 1_700_000_000_000;
    defer wall_ms = 1_760_270_400_000;
    D.start(200, 400);
    defer D.reset();
    D.device(.offline);
    try std.testing.expect(D.findText("Offline") != 0);
    try std.testing.expect(D.R.appState().offline);
    D.device(.online);
    try std.testing.expect(D.findText("Offline") == 0);
    try std.testing.expectEqual(@as(u32, 2), D.R.appState().events);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), D.R.appState().now);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), zui.now());
}

// Inputs of every kind, and the platform's pickers.
const Form = struct {
    pub const Msg = union(enum) { date, time, city, picked_date: []const u8, picked_time: []const u8, picked_city: u32, note: []const u8 };
    pub const State = struct { date: [10]u8 = "2026-01-01".*, time: [5]u8 = "09:00".*, city: u32 = 0, note: [64]u8 = undefined, note_len: usize = 0 };
    const cities = [_][]const u8{ "Damascus", "Aleppo", "Homs" };
    pub fn init() State {
        return .{};
    }
    fn onDate(v: []const u8) Msg {
        return .{ .picked_date = v };
    }
    fn onTime(v: []const u8) Msg {
        return .{ .picked_time = v };
    }
    fn onCity(i: u32) Msg {
        return .{ .picked_city = i };
    }
    fn onNote(v: []const u8) Msg {
        return .{ .note = v };
    }
    pub fn update(s: *State, msg: Msg, _: zui.Env, fx: zui.runtime.Fx(Msg)) void {
        switch (msg) {
            .date => fx.pickDate(.{ .value = &s.date, .min = "2026-01-01" }, onDate),
            .time => fx.pickTime(.{ .value = &s.time }, onTime),
            .city => fx.pickOption(.{ .title = "City", .options = &cities, .selected = s.city }, onCity),
            .picked_date => |v| if (v.len == 10) @memcpy(&s.date, v),
            .picked_time => |v| if (v.len == 5) @memcpy(&s.time, v),
            .picked_city => |i| if (i < cities.len) {
                s.city = i;
            },
            .note => |v| {
                s.note_len = @min(v.len, s.note.len);
                @memcpy(s.note[0..s.note_len], v[0..s.note_len]);
            },
        }
    }
    pub fn view(s: *const State, ui: *zui.Ui(Msg)) void {
        ui.begin(.{ .width = .{ .px = 80 } }, .{});
        ui.input(.{ .placeholder = "Password", .secure = true, .return_key = .go });
        ui.input(.{ .placeholder = "Email", .keyboard = .email });
        ui.input(.{ .placeholder = "Note", .multiline = true, .value = s.note[0..s.note_len], .on_change = onNote, .style = .{ .line_height = 1 } });
        ui.begin(.{}, .{ .on_press = .date });
        ui.text(&s.date, .{});
        ui.end();
        ui.begin(.{}, .{ .on_press = .time });
        ui.text(&s.time, .{});
        ui.end();
        ui.begin(.{}, .{ .on_press = .city });
        ui.text(cities[s.city], .{});
        ui.end();
        ui.end();
    }
};

test "inputs: password, keyboards, a text area that grows; date, time and option pickers" {
    const D = Driver(Form);
    D.start(200, 400);
    defer D.reset();
    try std.testing.expect(D.inputView("Password").?.input_type.secure);
    try std.testing.expectEqual(zui.ReturnKey.go, D.inputView("Password").?.input_type.return_key);
    try std.testing.expectEqual(zui.Keyboard.email, D.inputView("Email").?.input_type.keyboard);
    try std.testing.expectEqual(zui.tree.Kind.text_area, D.inputView("Note").?.kind);
    try std.testing.expectEqual(@as(f32, 15), D.inputView("Note").?.frame.h);
    try D.typeInto("Note", "one line\nand more text here, and then some more, and more"); // 58 characters, 25 a line
    try std.testing.expectEqual(@as(f32, 45), D.inputView("Note").?.frame.h);

    try D.press("2026-01-01");
    try std.testing.expectEqual(zui.PickKind.date, picker.?);
    try std.testing.expectEqualStrings("2026-01-01", picker_value.items);
    try D.choose("2026-03-04");
    try std.testing.expect(D.findText("2026-03-04") != 0);

    try D.press("09:00");
    try std.testing.expectEqual(zui.PickKind.time, picker.?);
    try D.choose("17:30");
    try std.testing.expect(D.findText("17:30") != 0);

    try D.press("Damascus");
    try std.testing.expectEqualStrings("Damascus\nAleppo\nHoms", picker_options.items);
    try std.testing.expectEqual(@as(i32, 0), picker_selected);
    try D.choose("2");
    try std.testing.expect(D.findText("Homs") != 0);
    try std.testing.expectError(error.NoPicker, D.choose("1"));
}

const Files = struct {
    pub const Msg = union(enum) { photo, file, save, got: zui.File };
    pub const State = struct { got: [64]u8 = undefined, got_len: usize = 0 };
    pub fn init() State {
        return .{};
    }
    fn onFile(f: zui.File) Msg {
        return .{ .got = f };
    }
    pub fn update(s: *State, msg: Msg, _: zui.Env, fx: zui.runtime.Fx(Msg)) void {
        switch (msg) {
            .photo => fx.pickPhoto(.{ .camera = true, .max_size = 1024 }, onFile),
            .file => fx.pickFile(.{ .accept = "text/csv" }, onFile),
            .save => fx.saveFile(.{ .name = "report.csv", .mime = "text/csv", .data = "a,b\n1,2\n", .share = true }),
            .got => |f| s.got_len = if (std.fmt.bufPrint(&s.got, "{s} {s} {d} {d}x{d}", .{ f.name, f.mime, f.data.len, f.width, f.height })) |w| w.len else |_| 0,
        }
    }
    pub fn view(s: *const State, ui: *zui.Ui(Msg)) void {
        ui.begin(.{}, .{});
        ui.begin(.{}, .{ .on_press = .photo });
        ui.text("Photo", .{});
        ui.end();
        ui.begin(.{}, .{ .on_press = .file });
        ui.text("File", .{});
        ui.end();
        ui.begin(.{}, .{ .on_press = .save });
        ui.text("Save", .{});
        ui.end();
        ui.text(s.got[0..s.got_len], .{});
        ui.end();
    }
};

test "photos, files, saving" {
    const D = Driver(Files);
    D.start(200, 400);
    defer D.reset();
    try D.press("Photo");
    try std.testing.expect(photo_asked.?.camera and photo_asked.?.max_size == 1024 and photo_asked.?.quality == 85);
    D.giveFile(.{ .data = "\xff\xd8jpeg", .name = "photo.jpg", .mime = "image/jpeg", .width = 1024, .height = 768 });
    try std.testing.expect(D.findText("photo.jpg image/jpeg 6 1024x768") != 0);
    try D.press("File");
    try std.testing.expectEqualStrings("text/csv", file_accept.?);
    D.giveFile(.{ .data = "x,y", .name = "a.csv", .mime = "text/csv" });
    try std.testing.expect(D.findText("a.csv text/csv 3 0x0") != 0);
    try D.press("Save");
    try std.testing.expectEqualStrings("report.csv", saved_name.items);
    try std.testing.expectEqualStrings("a,b\n1,2\n", saved_data.items);
    try std.testing.expect(saved_share);
}

const Live = struct {
    pub const Msg = union(enum) { start, stop, ev: zui.ServerEvent };
    pub const State = struct { stream: u32 = 0, log: [256]u8 = undefined, len: usize = 0 };
    pub fn init() State {
        return .{};
    }
    fn onEvent(e: zui.ServerEvent) Msg {
        return .{ .ev = e };
    }
    pub fn update(s: *State, msg: Msg, _: zui.Env, fx: zui.runtime.Fx(Msg)) void {
        switch (msg) {
            .start => s.stream = fx.openEvents(.{ .url = "/events", .headers = &.{.{ "authorization", "Bearer t" }} }, onEvent),
            .stop => fx.closeEvents(s.stream),
            .ev => |e| {
                const w = std.fmt.bufPrint(s.log[s.len..], "{t}:{s}:{s}:{s}:{d};", .{ e.kind, e.event, e.data, e.id, e.status }) catch return;
                s.len += w.len;
                if (std.mem.eql(u8, e.data, "stop")) fx.closeEvents(e.stream);
            },
        }
    }
    pub fn view(s: *const State, ui: *zui.Ui(Msg)) void {
        ui.begin(.{}, .{});
        ui.begin(.{}, .{ .on_press = .start });
        ui.text("Start", .{});
        ui.end();
        ui.imageWith("/photo.jpg", .{ .headers = &.{.{ "authorization", "Bearer t" }} }, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, 0);
        ui.text(s.log[0..s.len], .{});
        ui.end();
    }
};

test "server-sent events: parsed, reconnected with Last-Event-ID, closed for good on 401" {
    const D = Driver(Live);
    D.start(200, 400);
    defer D.reset();
    var it = views.iterator();
    while (it.next()) |e| if (e.value_ptr.kind == .image) try std.testing.expectEqualStrings("authorization: Bearer t\n", e.value_ptr.headers.items);

    try D.press("Start");
    try std.testing.expectEqualStrings("/events", stream_url.items);
    try std.testing.expect(std.mem.indexOf(u8, stream_headers.items, "authorization: Bearer t\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, stream_headers.items, "Accept: text/event-stream") != null);
    D.serverStatus(200);
    D.serverSend("retry: 500\nid: 7\nevent: tick\nda");
    D.serverSend("ta: a\n\n");
    const s = D.R.appState();
    try std.testing.expectEqualStrings("open::::0;message:tick:a:7:0;", s.log[0..s.len]);

    // Lost: .failed, a timer of the server's retry time, then a new connection.
    D.serverEnd();
    try std.testing.expectEqual(@as(u32, 500), timers.items[timers.items.len - 1].ms);
    D.runTimers();
    try std.testing.expect(stream_conn != 0);
    try std.testing.expect(std.mem.indexOf(u8, stream_headers.items, "Last-Event-ID: 7\n") != null);

    // Refused: closed for good, no new connection.
    D.serverStatus(401);
    D.serverSend("data: not events\n\n");
    D.serverEnd();
    D.runTimers();
    try std.testing.expectEqual(@as(u32, 0), stream_conn);
    try std.testing.expectEqualStrings("open::::0;message:tick:a:7:0;failed::::200;closed::::401;", s.log[0..s.len]);
}

test "an app closing its stream while an event is handled" {
    const D = Driver(Live);
    D.start(200, 400);
    defer D.reset();
    try D.press("Start");
    const conn = stream_conn;
    D.serverStatus(200);
    D.serverSend("data: stop\n\ndata: after\n\n");
    try std.testing.expectEqual(@as(u32, 0), stream_conn);
    const s = D.R.appState();
    try std.testing.expect(std.mem.indexOf(u8, s.log[0..s.len], "after") == null);
    D.R.streamData(conn, "data: late\n\n"); // an old connection's late bytes are dropped
    try std.testing.expect(std.mem.indexOf(u8, s.log[0..s.len], "late") == null);
}

const Voice = struct {
    pub const Msg = union(enum) { record, stop, rec: zui.RecordEvent, play, seek, ev: zui.PlayEvent };
    pub const State = struct {
        recorder: u32 = 0,
        player: u32 = 0,
        level: f32 = 0,
        bytes: usize = 0,
        position: u32 = 0,
        duration: u32 = 0,
        ended: bool = false,
    };
    pub fn init() State {
        return .{};
    }
    fn onRec(e: zui.RecordEvent) Msg {
        return .{ .rec = e };
    }
    fn onPlay(e: zui.PlayEvent) Msg {
        return .{ .ev = e };
    }
    pub fn update(s: *State, msg: Msg, _: zui.Env, fx: zui.runtime.Fx(Msg)) void {
        switch (msg) {
            .record => s.recorder = fx.startRecording(.{}, onRec),
            .stop => fx.stopRecording(s.recorder),
            .rec => |e| switch (e.kind) {
                .level => s.level = e.level,
                .done => s.bytes = e.data.len,
                else => {},
            },
            .play => s.player = fx.play(.{ .url = "https://example.com/voice.m4a" }, onPlay),
            .seek => fx.seekPlayback(s.player, 1500),
            .ev => |e| switch (e.kind) {
                .ready => s.duration = e.duration_ms,
                .progress => s.position = e.position_ms,
                .ended => s.ended = true,
                .failed => {},
            },
        }
    }
    pub fn view(s: *const State, ui: *zui.Ui(Msg)) void {
        ui.begin(.{}, .{});
        ui.begin(.{}, .{ .on_press = .record });
        ui.text("Record", .{});
        ui.end();
        ui.begin(.{}, .{ .on_press = .stop });
        ui.text("Stop", .{});
        ui.end();
        ui.begin(.{}, .{ .on_press = .play });
        ui.text("Play", .{});
        ui.end();
        ui.begin(.{}, .{ .on_press = .seek });
        ui.text("Seek", .{});
        ui.end();
        ui.text(ui.tf("{b} bytes, {p} of {d} ms", .{ .b = s.bytes, .p = s.position, .d = s.duration }), .{});
        ui.end();
    }
};

test "recording a voice message and playing it" {
    const D = Driver(Voice);
    D.start(200, 400);
    defer D.reset();
    try D.press("Record");
    try std.testing.expect(recording != 0 and !recording_video);
    D.R.recordEvent(recording, .level, 0.4, 500, "", "");
    try D.press("Stop");
    try std.testing.expect(recording_stopped);
    D.R.recordEvent(recording, .done, 0, 2000, "m4a bytes", "audio/mp4");
    try D.press("Play");
    try std.testing.expectEqualStrings("https://example.com/voice.m4a", playing_url.items);
    D.R.playEvent(playing, .ready, 0, 2000, "");
    D.R.playEvent(playing, .progress, 750, 2000, "");
    try std.testing.expect(D.findText("9 bytes, 750 of 2000 ms") != 0);
    try D.press("Seek");
    try std.testing.expectEqual(@as(u32, 1500), playback_controls.items[playback_controls.items.len - 1].seek);
}

const Keys = struct {
    pub const Msg = union(enum) { go, got: zui.keys.Result };
    pub const State = struct { log: [512]u8 = undefined, len: usize = 0, step: u8 = 0, public: [65]u8 = undefined };
    pub fn init() State {
        return .{};
    }
    fn onKey(r: zui.keys.Result) Msg {
        return .{ .got = r };
    }
    pub fn update(s: *State, msg: Msg, _: zui.Env, fx: zui.runtime.Fx(Msg)) void {
        switch (msg) {
            .go => _ = fx.key(.{ .op = .generate, .name = "sig", .kind = .ecdsa }, onKey),
            .got => |r| {
                const w = std.fmt.bufPrint(s.log[s.len..], "{t}:{d};", .{ r.status, r.data.len }) catch return;
                s.len += w.len;
                s.step += 1;
                switch (s.step) {
                    1 => {
                        @memcpy(&s.public, r.data[0..65]);
                        _ = fx.key(.{ .op = .sign, .name = "sig", .data = "hi" }, onKey);
                    },
                    2 => {
                        const pk = std.crypto.sign.ecdsa.EcdsaP256Sha256.PublicKey.fromSec1(&s.public) catch return;
                        std.crypto.sign.ecdsa.EcdsaP256Sha256.Signature.fromBytes(r.data[0..64].*).verify("hi", pk) catch return;
                        _ = fx.key(.{ .op = .public, .name = "nope" }, onKey);
                    },
                    else => {},
                }
            },
        }
    }
    pub fn view(s: *const State, ui: *zui.Ui(Msg)) void {
        ui.begin(.{}, .{ .on_press = .go });
        ui.text("Go", .{});
        ui.text(s.log[0..s.len], .{});
        ui.end();
    }
};

test "secure keys through fx.key: answers arrive as messages" {
    const D = Driver(Keys);
    D.start(200, 400);
    defer D.reset();
    try D.press("Go");
    try std.testing.expectEqual(@as(usize, 0), D.R.appState().len); // not during the update
    D.runTimers();
    try std.testing.expectEqualStrings("ok:65;ok:64;missing:0;", D.R.appState().log[0..D.R.appState().len]);
}
