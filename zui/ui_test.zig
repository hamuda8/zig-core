//! Tests of the runtime's styling and interaction features on the headless host: long press,
//! secondary click, hover, nested presses, links in rich text, pictures from memory, scroll
//! control, pointer keys, transitions and spinners.

const std = @import("std");
const zui = @import("zui.zig");
const headless = @import("host/headless.zig");

const testing = std.testing;

const App = struct {
    pub const Msg = union(enum) {
        outer,
        inner,
        hold,
        menu,
        hover: bool,
        link: u32,
        scrolled: zui.ScrollEvent,
        pointer: zui.Pointer,
        more,
        go: zui.ScrollTarget,
    };
    pub const State = struct {
        log: [64]u8 = undefined,
        len: usize = 0,
        items: u32 = 5,
        /// Rows added before the first one.
        before: u32 = 0,
        last_scroll: ?zui.ScrollEvent = null,
        reached_end: u32 = 0,
        pointer_key: u64 = 0,
        hovering: bool = false,

        fn note(s: *State, c: u8) void {
            if (s.len < s.log.len) {
                s.log[s.len] = c;
                s.len += 1;
            }
        }
    };
    pub fn init() State {
        return .{};
    }
    pub fn update(s: *State, m: Msg, _: zui.Env, fx: zui.Fx(Msg)) void {
        switch (m) {
            .outer => s.note('O'),
            .inner => s.note('I'),
            .hold => s.note('H'),
            .menu => s.note('M'),
            .hover => |on| s.hovering = on,
            .link => |i| s.note('0' + @as(u8, @intCast(i))),
            .scrolled => |e| {
                s.last_scroll = e;
                if (e.reached_end) s.reached_end += 1;
            },
            .pointer => |p| s.pointer_key = p.key,
            .more => {
                s.before += 3;
                s.items += 3;
            },
            .go => |t| fx.scrollTo(zui.key("list"), t, true),
        }
    }
    fn onHover(on: bool) Msg {
        return .{ .hover = on };
    }
    fn onScroll(e: zui.ScrollEvent) Msg {
        return .{ .scrolled = e };
    }
    fn onPointer(p: zui.Pointer) Msg {
        return .{ .pointer = p };
    }
    pub fn view(s: *const State, ui: *zui.Ui(Msg)) void {
        ui.begin(.{}, .{});
        ui.begin(.{ .padding = .all(4) }, .{ .on_press = .outer });
        ui.text("Outer", .{});
        ui.begin(.{ .padding = .all(4), .hover_background = zui.Color.white }, .{ .on_press = .inner, .on_long_press = .hold, .on_hover = onHover });
        ui.text("Inner", .{});
        ui.end();
        ui.begin(.{}, .{ .on_press = .inner, .on_context = .menu });
        ui.text("Menu", .{ .uppercase = true });
        ui.end();
        ui.end();
        ui.richText(&.{
            .{ .text = "Read the " },
            .{ .text = "terms", .link = .{ .link = 0 }, .underline = true },
            .{ .text = " and " },
            .{ .text = "privacy", .link = .{ .link = 1 }, .bold = true },
        }, .{}, .{ .selectable = true });
        ui.imageBytes("\x89PNG....", "photo-1", .{ .width = .{ .px = 40 }, .height = .{ .px = 40 }, .fit = .cover }, 0);
        ui.spinner(24, zui.Color.black, .{ .transition = .{ .duration_ms = 300 } }, zui.key("spin"));
        ui.begin(.{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{ .key = zui.key("map-a"), .on_pointer = onPointer });
        ui.end();
        ui.beginScrollWith(.{ .height = .{ .px = 100 } }, .{ .key = zui.key("list"), .anchor_end = true, .keep_position = true, .on_scroll = onScroll });
        var i: u32 = 0;
        while (i < s.items) : (i += 1) {
            // Row numbers stay with their rows: rows added before the first get new numbers.
            const n = @as(i64, i) - s.before;
            ui.textKeyed("row", .{ .height = .{ .px = 30 } }, zui.key(@as(u64, @bitCast(n))));
        }
        ui.end();
        ui.end();
    }
};

const D = headless.Driver(App);

fn log() []const u8 {
    const s = D.R.appState();
    return s.log[0..s.len];
}

test "nested presses, long press with a haptic tick, the context menu, hover" {
    D.start(300, 800);
    defer D.reset();
    try D.press("Inner");
    try D.press("Outer");
    try testing.expectEqualStrings("IO", log());

    // A long press takes the place of the press that follows it.
    try D.longPress("Inner");
    try testing.expectEqualStrings("IOH", log());
    try testing.expectEqual(@as(u32, 1), headless.haptics);
    // A press that is let go early is a press.
    try D.press("Inner");
    try testing.expectEqualStrings("IOHI", log());

    // Uppercase is done in Zig.
    try testing.expect(D.findText("MENU") != 0);
    try D.context("MENU");
    try testing.expectEqualStrings("IOHIM", log());
    // Held on a phone, a view with only a context menu opens it.
    try D.longPress("MENU");
    try testing.expectEqualStrings("IOHIMM", log());

    const inner = D.pressableOf("Inner");
    try testing.expect(headless.views.get(inner).?.gestures.long_press);
    try testing.expect(headless.views.get(inner).?.gestures.hover);
    D.hover(inner, true);
    try testing.expect(D.R.appState().hovering);
    try testing.expectEqual(zui.Color.white.argb(), headless.views.get(inner).?.box.background);
    D.hover(inner, false);
    try testing.expect(!D.R.appState().hovering);
    try testing.expectEqual(@as(u32, 0), headless.views.get(inner).?.box.background);
}

test "links in rich text, pictures from memory, spinners, pointer keys" {
    D.start(300, 800);
    defer D.reset();
    try D.pressLink("privacy", 1);
    try D.pressLink("terms", 0);
    try testing.expectEqualStrings("10", log());
    var it = headless.views.iterator();
    var found_text = false;
    var found_image = false;
    var found_spinner = false;
    while (it.next()) |e| {
        const v = e.value_ptr;
        if (v.kind == .text_select) {
            found_text = true;
            try testing.expectEqual(@as(usize, 4), v.spans);
            try testing.expectEqualStrings("Read the terms and privacy", v.text.items);
        }
        if (v.kind == .image) {
            found_image = true;
            try testing.expectEqualStrings("photo-1", v.text.items);
            try testing.expectEqual(@as(usize, 8), v.bytes);
            try testing.expectEqual(zui.Fit.cover, v.fit);
        }
        if (v.kind == .path and v.spin_ms > 0) {
            found_spinner = true;
            try testing.expectEqual(@as(u16, 800), v.spin_ms);
            try testing.expectEqual(@as(u16, 300), v.transition.?.duration_ms);
        }
    }
    try testing.expect(found_text and found_image and found_spinner);

    D.pointer(.{ .kind = .down, .id = 1, .x = 5, .y = 5 });
    try testing.expectEqual(zui.key("map-a"), D.R.appState().pointer_key);
}

test "scroll views: start at the end, keep their place, report, scroll to" {
    D.start(300, 800);
    defer D.reset();
    const list = D.scrollView();
    // Five rows of 30 in 100: it starts at the end, 50.
    try testing.expectEqual(@as(?f32, 50), headless.views.get(list).?.scrolled_to);

    // The user scrolls to the top; the app hears where it is.
    D.scroll(list, 0);
    try testing.expectEqual(@as(f32, 0), D.R.appState().last_scroll.?.offset);
    try testing.expectEqual(@as(f32, 150), D.R.appState().last_scroll.?.content);
    try testing.expect(D.R.appState().last_scroll.?.reached_start);

    // Three rows come before the first: the rows on screen stay where they were.
    D.R.dispatch(.more);
    try testing.expectEqual(@as(?f32, 90), headless.views.get(list).?.scrolled_to);
    D.scroll(list, 90);

    // To the end, smoothly; reaching it is reported once.
    D.R.dispatch(.{ .go = .end });
    try testing.expectEqual(@as(?f32, 140), headless.views.get(list).?.scrolled_to);
    try testing.expect(headless.views.get(list).?.scroll_animated);
    D.scroll(list, 140);
    D.scroll(list, 140);
    try testing.expectEqual(@as(u32, 1), D.R.appState().reached_end);

    // To a row by its key.
    D.R.dispatch(.{ .go = .{ .child = zui.key(@as(u64, @bitCast(@as(i64, 2)))) } });
    try testing.expectEqual(@as(?f32, 140), headless.views.get(list).?.scrolled_to); // (3 + 2) * 30 = 150, clamped
    D.R.dispatch(.{ .go = .{ .child = zui.key(@as(u64, @bitCast(@as(i64, -2)))) } });
    try testing.expectEqual(@as(?f32, 30), headless.views.get(list).?.scrolled_to);
}

const ScanApp = struct {
    pub const Msg = union(enum) { start, stop, scan: zui.ScanEvent };
    pub const State = struct {
        scanner: u32 = 0,
        running: bool = false,
        found: [64]u8 = undefined,
        found_len: usize = 0,
        format: ?zui.barcode.Format = null,
        count: u32 = 0,
    };
    pub fn init() State {
        return .{};
    }
    fn onScan(e: zui.ScanEvent) Msg {
        return .{ .scan = e };
    }
    pub fn update(s: *State, m: Msg, _: zui.Env, fx: zui.Fx(Msg)) void {
        switch (m) {
            .start => s.scanner = fx.scanBarcode(.{}, onScan),
            .stop => fx.stopScan(s.scanner),
            .scan => |e| switch (e.kind) {
                .started => s.running = true,
                .found => {
                    s.found_len = @min(e.text.len, s.found.len);
                    @memcpy(s.found[0..s.found_len], e.text[0..s.found_len]);
                    s.format = e.format;
                    s.count += 1;
                },
                .failed => s.running = false,
            },
        }
    }
    pub fn view(s: *const State, ui: *zui.Ui(Msg)) void {
        ui.begin(.{}, .{});
        if (s.scanner != 0) ui.video(s.scanner, .{}, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, 0);
        ui.end();
    }
};

test "a barcode scanner: the camera starts, a frame with a QR code is read once" {
    const S = headless.Driver(ScanApp);
    S.start(300, 400);
    defer S.reset();
    S.R.dispatch(.start);
    try testing.expect(headless.scan_open != 0);
    try testing.expect(headless.scan_back);
    S.scanStarted();
    try testing.expect(S.R.appState().running);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const q = try zui.barcode.encodeQr(a, "TRF-2026-00417", .M, 1, 2);
    const scale = 4;
    const side = (q.size + 8) * scale;
    const px = try a.alloc(u8, side * side);
    for (0..side) |y| for (0..side) |x| {
        const mx = @as(i64, @intCast(x / scale)) - 4;
        const my = @as(i64, @intCast(y / scale)) - 4;
        const dark = mx >= 0 and my >= 0 and mx < q.size and my < q.size and q.modules[@as(usize, @intCast(my)) * q.size + @as(usize, @intCast(mx))];
        px[y * side + x] = if (dark) 30 else 220;
    };
    const img: zui.barcode.Image = .{ .width = side, .height = side, .pixels = px };
    S.scanFrame(img);
    S.scanFrame(img); // the same code again at once: not news
    try testing.expectEqualStrings("TRF-2026-00417", S.R.appState().found[0..S.R.appState().found_len]);
    try testing.expectEqual(@as(?zui.barcode.Format, .qr), S.R.appState().format);
    try testing.expectEqual(@as(u32, 1), S.R.appState().count);
    S.R.dispatch(.stop);
    try testing.expectEqual(@as(u32, 0), headless.scan_open);
}
