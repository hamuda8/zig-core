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
};

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
pub fn transform(id: u32, t: zui.Transform) void {
    if (views.getPtr(id)) |v| v.transform = t;
}
pub fn clip(id: u32, on: bool) void {
    if (views.getPtr(id)) |v| v.clip = on;
}
pub fn pointer(id: u32, on: bool) void {
    if (views.getPtr(id)) |v| v.pointer = on;
}
pub fn image(id: u32, url: []const u8) void {
    const v = views.getPtr(id) orelse return;
    v.text.clearRetainingCapacity();
    v.text.appendSlice(gpa, url) catch {};
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

        /// Focus, blur or enter on the input whose placeholder is `placeholder`.
        pub fn inputEvent(placeholder: []const u8, kind: zui.InputEvent) !void {
            var it = views.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.kind == .input and std.mem.eql(u8, e.value_ptr.placeholder.items, placeholder)) {
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

        /// Types `s` into the input whose placeholder is `placeholder`.
        pub fn typeInto(placeholder: []const u8, s: []const u8) !void {
            var it = views.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.kind == .input and std.mem.eql(u8, e.value_ptr.placeholder.items, placeholder)) {
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
