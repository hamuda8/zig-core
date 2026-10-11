//! The app loop, the same on every platform: an event becomes a message, `update` changes the
//! state, `view` builds a new tree, the layout engine places it, and the reconciler sends the
//! host only what changed.
//!
//! An app is a namespace with:
//!   pub const Msg = union(enum) { ... };          // what can happen
//!   pub const State = struct { ... };
//!   pub fn init() State
//!   pub fn update(state: *State, msg: Msg) void   (or with a third `env: zui.Env` parameter)
//!   pub fn view(state: *const State, ui: *zui.Ui(Msg)) void
//! and optionally `global_locale: []const u8` and `locales: []const zui.i18n.Locale`.

const std = @import("std");
const st = @import("style.zig");
const tree_mod = @import("tree.zig");
const layout = @import("layout.zig");
const reconcile = @import("reconcile.zig");
const i18n = @import("i18n.zig");
const Color = @import("color.zig").Color;

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
};

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
        };

        pub const InputOptions = struct {
            key: u64 = 0,
            value: []const u8 = "",
            placeholder: []const u8 = "",
            /// Gets the new text; it is only valid during `update`, so copy what you keep.
            on_change: ?*const fn ([]const u8) Msg = null,
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
        }

        /// A picture loaded from `url` (the host caches it), sized by `style`.
        pub fn image(ui: *Self, url: []const u8, style: st.Style, k: u64) void {
            _ = ui.tree.add(.{ .kind = .image, .style = style, .text = url, .key = k }) catch ui.fail();
        }

        /// A line through `points` (in this node's coordinates), sized by `style`.
        pub fn path(ui: *Self, points: []const [2]f32, p: PathStyle, style: st.Style, k: u64) void {
            _ = ui.tree.add(.{ .kind = .path, .style = style, .key = k, .path = .{
                .points = points,
                .color = p.color.argb(),
                .width = p.width,
                .dash = p.dash,
                .round = p.round,
            } }) catch ui.fail();
        }

        /// Asks for `msg` at the next display frame (animations); ask again each frame to continue.
        pub fn requestFrame(ui: *Self, msg: Msg) void {
            ui.frame_msg = msg;
        }

        /// The translation of `english` (Lassan bundles).
        pub fn t(ui: *Self, english: []const u8) []const u8 {
            _ = ui;
            return i18n.t(english);
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
        var changes: []const Binding(*const fn ([]const u8) Msg) = &.{};

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
                if (b.node == id) return dispatch(b.value(p));
            }
        }

        /// The host's display frame, after `requestFrame`.
        pub fn frame() void {
            if (!started) return;
            const m = frame_msg orelse return;
            frame_msg = null;
            dispatch(m);
        }

        pub fn textEvent(id: u32, text: []const u8) void {
            if (!started) return;
            for (changes) |b| {
                if (b.node == id) return dispatch(b.value(text));
            }
        }

        pub fn dispatch(msg: Msg) void {
            // `update(state, msg)`, or `update(state, msg, env)` when it needs the screen size.
            if (@typeInfo(@TypeOf(App.update)).@"fn".param_types.len == 3) App.update(&state, msg, env) else App.update(&state, msg);
            render();
        }

        fn render() void {
            const next: u1 = if (has_old) current ^ 1 else current;
            const tree = &trees[next];
            tree.reset();
            env.rtl = i18n.isRtl();

            var ui: U = .{ .tree = tree, .env = env };
            App.view(&state, &ui);
            if (ui.failed) return;

            const s = env.safe;
            const root_frame: st.Rect = .{ .x = s.left, .y = s.top, .w = @max(0, env.width - s.left - s.right), .h = @max(0, env.height - s.top - s.bottom) };
            layout.Engine.run(tree, &H.measure, env.rtl, root_frame) catch return;
            rec.run(if (has_old) &trees[current] else null, tree, .{ .rtl = env.rtl, .pressed = pressed });

            // Handlers now point at host ids, which is what events carry.
            for (ui.presses.items) |*b| b.node = tree.nodes.items[b.node].host;
            for (ui.changes.items) |*b| b.node = tree.nodes.items[b.node].host;
            for (ui.pointers.items) |*b| b.node = tree.nodes.items[b.node].host;
            presses = ui.presses.items;
            changes = ui.changes.items;
            pointers = ui.pointers.items;
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
