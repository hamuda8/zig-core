//! Compares the previous tree with the new one and tells the host only what changed: views to
//! create, move or destroy, and the frames, boxes and text that differ.
//!
//! A host is a type with these functions (all ids are host view ids; parent 0 is the root):
//!   create(id, Kind)                 destroy(id)              insert(parent, id, index)
//!   frame(id, Rect)                  box(id, Box)             pressable(id, bool)
//!   text(id, []const u8, Font, color: u32, PhysicalAlign)
//!   input(id, value, placeholder, Font, color: u32, PhysicalAlign)   — inputs and text areas
//!   inputType(id, tree.InputType)    — before `input`, when it changes
//!   content(id, Size)                — scroll nodes: size of what scrolls
//!   transform(id, Transform)         clip(id, bool)           pointer(id, bool)
//!   image(id, url, headers)          path(id, tree.Path)
//! and, where the host has them:
//!   richText(id, text, []const Span, Font, color, PhysicalAlign)   — text with spans
//!   gestures(id, tree.Gestures)      — long press, secondary click, hover
//!   imageBytes(id, cache_key, bytes) — a picture from memory
//!   imageFit(id, Fit)                transition(id, ?Transition) — before frame, box, transform
//!   spin(id, period_ms)              — turning round natively (0 stops)

const std = @import("std");
const st = @import("style.zig");
const tree_mod = @import("tree.zig");

const Tree = tree_mod.Tree;
const Node = tree_mod.Node;
const none = tree_mod.none;

pub const IdPool = struct {
    next: u32 = 1,
    free: std.ArrayList(u32) = .empty,

    pub fn take(p: *IdPool) u32 {
        if (p.free.pop()) |id| return id;
        p.next += 1;
        return p.next - 1;
    }

    pub fn give(p: *IdPool, gpa: std.mem.Allocator, id: u32) void {
        p.free.append(gpa, id) catch {}; // a lost id is only never reused
    }
};

/// What the reconciler needs to know about the frame being drawn, besides the trees.
pub const State = struct {
    rtl: bool = false,
    /// Host id of the view being pressed, 0 for none.
    pressed: u32 = 0,
    /// Host id of the view under the mouse, 0 for none.
    hovered: u32 = 0,
    /// Transitions are off (the app's "animations" switch: fx.reduceMotion).
    reduce_motion: bool = false,
};

fn spansEql(a: []const tree_mod.Span, b: []const tree_mod.Span) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.meta.eql(x, y)) return false;
    return true;
}

pub fn Reconciler(comptime H: type) type {
    return struct {
        gpa: std.mem.Allocator,
        ids: IdPool = .{},
        prev: State = .{},
        now: State = .{},

        const Self = @This();

        /// Brings the host from `old` (null on the first render) to `new`, and stores host ids
        /// in `new`'s nodes.
        pub fn run(r: *Self, old: ?*const Tree, new: *Tree, now: State) void {
            r.now = now;
            defer r.prev = now;
            const old_root = if (old) |o| o.root() else none;
            const new_root = new.root();
            if (new_root == none) {
                if (old_root != none) r.destroy(old.?, old_root);
                return;
            }
            if (old_root != none and old.?.nodes.items[old_root].kind == new.nodes.items[new_root].kind) {
                r.sync(old.?, old_root, new, new_root);
            } else {
                if (old_root != none) r.destroy(old.?, old_root);
                r.create(new, new_root);
                H.insert(0, new.nodes.items[new_root].host, 0);
            }
        }

        fn create(r: *Self, t: *Tree, i: u32) void {
            const n = &t.nodes.items[i];
            n.host = r.ids.take();
            H.create(n.host, n.kind);
            r.props(null, n);
            var it = t.children(i);
            var index: u32 = 0;
            while (it.next()) |c| : (index += 1) {
                r.create(t, c);
                H.insert(n.host, t.nodes.items[c].host, index);
            }
        }

        fn destroy(r: *Self, t: *const Tree, i: u32) void {
            var it = t.children(i);
            while (it.next()) |c| r.destroy(t, c);
            const id = t.nodes.items[i].host;
            H.destroy(id);
            r.ids.give(r.gpa, id);
        }

        /// `new[ni]` takes over the host view of `old[oi]`.
        fn sync(r: *Self, old: *const Tree, oi: u32, new: *Tree, ni: u32) void {
            const o = &old.nodes.items[oi];
            const n = &new.nodes.items[ni];
            n.host = o.host;
            r.props(o, n);
            r.children(old, oi, new, ni);
        }

        fn children(r: *Self, old: *const Tree, oi: u32, new: *Tree, ni: u32) void {
            const a = new.allocator();
            const parent = new.nodes.items[ni].host;

            var old_kids: std.ArrayList(u32) = .empty;
            var it = old.children(oi);
            while (it.next()) |c| old_kids.append(a, c) catch return;
            const used = a.alloc(bool, old_kids.items.len) catch return;
            @memset(used, false);

            // Match each new child: by key when it has one; otherwise with the next old child of
            // the same kind, in order. So a node appearing before others (a list opening above a
            // search field) does not rebuild them, and an input keeps its focus. Siblings of the
            // same kind that come and go need keys.
            var new_kids: std.ArrayList(u32) = .empty;
            var match: std.ArrayList(u32) = .empty;
            it = new.children(ni);
            var next_unkeyed: usize = 0;
            while (it.next()) |c| {
                new_kids.append(a, c) catch return;
                const n = new.nodes.items[c];
                var found: u32 = none;
                const from: usize = if (n.key == 0) next_unkeyed else 0;
                for (old_kids.items[from..], from..) |oc, k| {
                    if (used[k]) continue;
                    const o = old.nodes.items[oc];
                    if (o.kind != n.kind or o.key != n.key) continue;
                    found = @intCast(k);
                    break;
                }
                if (found != none) {
                    used[found] = true;
                    if (n.key == 0) next_unkeyed = found + 1;
                }
                match.append(a, found) catch return;
            }

            // Destroy what is gone first, so the host's order holds only survivors.
            var order: std.ArrayList(u32) = .empty;
            for (old_kids.items, used) |oc, u| {
                if (u) order.append(a, old.nodes.items[oc].host) catch return else r.destroy(old, oc);
            }

            for (new_kids.items, match.items, 0..) |c, m, k| {
                if (m == none) {
                    r.create(new, c);
                } else {
                    r.sync(old, old_kids.items[m], new, c);
                }
                const id = new.nodes.items[c].host;
                if (k < order.items.len and order.items[k] == id) continue;
                // Move (or insert) to position k, keeping our copy of the host's order in step.
                if (std.mem.indexOfScalar(u32, order.items, id)) |at| _ = order.orderedRemove(at);
                order.insert(a, @min(k, order.items.len), id) catch return;
                H.insert(parent, id, @intCast(k));
            }
        }

        fn props(r: *Self, o: ?*const Node, n: *Node) void {
            const id = n.host;
            const s = n.style;
            const was_pressed = o != null and o.?.host == r.prev.pressed and r.prev.pressed != 0;
            const is_pressed = n.pressable and id == r.now.pressed and id != 0;
            const was_hovered = o != null and o.?.host == r.prev.hovered and r.prev.hovered != 0;
            const is_hovered = n.gestures.hover and id == r.now.hovered and id != 0;

            // Set first: the changes below animate with it.
            if (@hasDecl(H, "transition")) {
                const was: ?st.Transition = if (o == null or r.prev.reduce_motion) null else o.?.style.transition;
                const now: ?st.Transition = if (r.now.reduce_motion) null else s.transition;
                if (!std.meta.eql(was, now)) H.transition(id, now);
            }

            if (o == null or !o.?.frame.eql(n.frame)) H.frame(id, n.frame);

            const box = st.Box.of(s, .{ .pressed = is_pressed, .hovered = is_hovered, .rtl = r.now.rtl });
            if (o == null or !std.meta.eql(st.Box.of(o.?.style, .{ .pressed = was_pressed, .hovered = was_hovered, .rtl = r.prev.rtl }), box)) H.box(id, box);

            if (o == null or o.?.pressable != n.pressable) {
                if (n.pressable or o != null) H.pressable(id, n.pressable);
            }
            if (@hasDecl(H, "gestures")) {
                const was: tree_mod.Gestures = if (o) |old| old.gestures else .{};
                if (!std.meta.eql(was, n.gestures)) H.gestures(id, n.gestures);
            }
            if (@hasDecl(H, "spin")) {
                const was: u16 = if (o) |old| old.style.spin_ms else 0;
                if (was != s.spin_ms) H.spin(id, s.spin_ms);
            }
            if (o == null or o.?.pointer != n.pointer) {
                if (n.pointer or o != null) H.pointer(id, n.pointer);
            }
            if (@hasDecl(H, "boxLabel")) {
                const was: []const u8 = if (o) |old| old.label else "";
                if (!std.mem.eql(u8, was, n.label)) H.boxLabel(id, n.label);
            }

            const tr = st.Transform.of(s);
            const old_tr: st.Transform = if (o) |old| st.Transform.of(old.style) else .{};
            if (!std.meta.eql(old_tr, tr)) H.transform(id, tr);
            if ((if (o) |old| old.style.clip else false) != s.clip) H.clip(id, s.clip);

            const font = st.Font.of(s);
            const color = s.color.argb();
            const al = st.physicalAlign(s.text_align, r.now.rtl);
            const text_changed = o == null or !std.mem.eql(u8, o.?.text, n.text) or
                !std.meta.eql(st.Font.of(o.?.style), font) or o.?.style.color.argb() != color or
                st.physicalAlign(o.?.style.text_align, r.prev.rtl) != al or !spansEql(o.?.spans, n.spans);
            switch (n.kind) {
                .text, .text_select => if (text_changed) {
                    if (@hasDecl(H, "richText") and (n.spans.len > 0 or n.kind == .text_select))
                        H.richText(id, n.text, n.spans, font, color, al)
                    else
                        H.text(id, n.text, font, color, al);
                },
                .input, .text_area => {
                    if (o == null or !std.meta.eql(o.?.input_type, n.input_type)) H.inputType(id, n.input_type);
                    if (text_changed or !std.mem.eql(u8, o.?.placeholder, n.placeholder))
                        H.input(id, n.text, n.placeholder, font, color, al);
                },
                .scroll, .scroll_x => if (o == null or !std.meta.eql(o.?.content, n.content)) H.content(id, n.content),
                .image => {
                    if (@hasDecl(H, "imageFit")) {
                        const was: st.Fit = if (o) |old| old.style.fit else .fill;
                        if (was != s.fit) H.imageFit(id, s.fit);
                    }
                    const from_memory = n.bytes != null and @hasDecl(H, "imageBytes");
                    const was_memory = if (o) |old| old.bytes != null else false;
                    if (o == null or !std.mem.eql(u8, o.?.text, n.text) or !std.mem.eql(u8, o.?.headers, n.headers) or was_memory != from_memory) {
                        // A picture from memory is known by its key: the bytes go only when it changes.
                        if (from_memory) H.imageBytes(id, n.text, n.bytes.?) else H.image(id, n.text, n.headers);
                    }
                    const f = n.style.image_filter;
                    const was: st.ImageFilter = if (o) |old| old.style.image_filter else .{};
                    if (!std.meta.eql(f, was) or (o == null and !f.isIdentity())) H.imageFilter(id, f);
                },
                .path => if (n.path) |p| {
                    const same = if (o) |old| (if (old.path) |op| op.eql(p) else false) else false;
                    if (!same) H.path(id, p);
                },
                .video => if (n.video) |v| {
                    const same = if (o) |old| std.meta.eql(old.video, n.video) else false;
                    if (!same and @hasDecl(H, "video")) H.video(id, v);
                },
                .view => {},
            }
        }
    };
}

// ---------------------------------------------------------------------------------------------

/// Host that records operations as text, for tests.
pub const RecordingHost = struct {
    pub var log: std.ArrayList(u8) = .empty;
    const gpa = std.testing.allocator;

    fn write(comptime fmt: []const u8, args: anytype) void {
        log.print(gpa, fmt ++ "\n", args) catch {};
    }

    pub fn reset() void {
        log.clearRetainingCapacity();
    }

    pub fn deinit() void {
        log.deinit(gpa);
        log = .empty;
    }

    pub fn create(id: u32, kind: tree_mod.Kind) void {
        write("create {d} {t}", .{ id, kind });
    }
    pub fn destroy(id: u32) void {
        write("destroy {d}", .{id});
    }
    pub fn insert(parent: u32, id: u32, index: u32) void {
        write("insert {d} {d} {d}", .{ parent, id, index });
    }
    pub fn frame(id: u32, r: st.Rect) void {
        write("frame {d} {d} {d} {d} {d}", .{ id, r.x, r.y, r.w, r.h });
    }
    pub fn box(id: u32, b: st.Box) void {
        write("box {d} {x}", .{ id, b.background });
    }
    pub fn pressable(id: u32, on: bool) void {
        write("pressable {d} {}", .{ id, on });
    }
    pub fn text(id: u32, s: []const u8, _: st.Font, _: u32, a: st.PhysicalAlign) void {
        write("text {d} {s} {t}", .{ id, s, a });
    }
    pub fn input(id: u32, value: []const u8, placeholder: []const u8, _: st.Font, _: u32, _: st.PhysicalAlign) void {
        write("input {d} {s} {s}", .{ id, value, placeholder });
    }
    pub fn inputType(id: u32, t: tree_mod.InputType) void {
        write("input type {d} {t} {}", .{ id, t.keyboard, t.secure });
    }
    pub fn content(id: u32, s: st.Size) void {
        write("content {d} {d} {d}", .{ id, s.w, s.h });
    }
    pub fn transform(id: u32, t: st.Transform) void {
        write("transform {d} {d} {d}", .{ id, t.rotate, t.tilt });
    }
    pub fn clip(id: u32, on: bool) void {
        write("clip {d} {}", .{ id, on });
    }
    pub fn pointer(id: u32, on: bool) void {
        write("pointer {d} {}", .{ id, on });
    }
    pub fn image(id: u32, url: []const u8, _: []const u8) void {
        write("image {d} {s}", .{ id, url });
    }
    pub fn imageFilter(_: u32, _: st.ImageFilter) void {}
    pub fn path(id: u32, p: tree_mod.Path) void {
        write("path {d} {d}", .{ id, p.points.len });
    }
    pub fn video(id: u32, v: tree_mod.Video) void {
        write("video {d} {d}", .{ id, v.stream });
    }
    pub fn transition(id: u32, t: ?st.Transition) void {
        write("transition {d} {d}", .{ id, if (t) |x| x.duration_ms else 0 });
    }
};

const testing = std.testing;

fn build(t: *Tree, labels: []const []const u8, keyed: bool) !void {
    t.reset();
    _ = try t.open(.{ .kind = .view, .style = .{} });
    for (labels) |l| _ = try t.add(.{ .kind = .text, .style = .{}, .text = l, .key = if (keyed) std.hash.Wyhash.hash(0, l) else 0 });
    t.close();
}

test "first render creates everything, an identical render sends nothing" {
    defer RecordingHost.deinit();
    var a = Tree.init(testing.allocator);
    defer a.deinit();
    var b = Tree.init(testing.allocator);
    defer b.deinit();
    var r: Reconciler(RecordingHost) = .{ .gpa = testing.allocator };
    defer r.ids.free.deinit(testing.allocator);

    try build(&a, &.{"hi"}, false);
    r.run(null, &a, .{});
    try testing.expect(std.mem.indexOf(u8, RecordingHost.log.items, "create 2 text") != null);
    try testing.expect(std.mem.indexOf(u8, RecordingHost.log.items, "insert 0 1 0") != null);

    RecordingHost.reset();
    try build(&b, &.{"hi"}, false);
    r.run(&a, &b, .{});
    try testing.expectEqualStrings("", RecordingHost.log.items);
}

test "changed text is updated in place; keyed children move instead of being recreated" {
    defer RecordingHost.deinit();
    var a = Tree.init(testing.allocator);
    defer a.deinit();
    var b = Tree.init(testing.allocator);
    defer b.deinit();
    var r: Reconciler(RecordingHost) = .{ .gpa = testing.allocator };
    defer r.ids.free.deinit(testing.allocator);

    try build(&a, &.{ "one", "two" }, true);
    r.run(null, &a, .{});
    RecordingHost.reset();
    try build(&b, &.{ "two", "one" }, true);
    r.run(&a, &b, .{});
    try testing.expectEqualStrings("insert 1 3 0\n", RecordingHost.log.items);

    RecordingHost.reset();
    try build(&a, &.{"two"}, true);
    r.run(&b, &a, .{});
    try testing.expectEqualStrings("destroy 2\n", RecordingHost.log.items);
}

test "a node opening above unkeyed siblings does not rebuild them (an input keeps its focus)" {
    defer RecordingHost.deinit();
    var a = Tree.init(testing.allocator);
    defer a.deinit();
    var b = Tree.init(testing.allocator);
    defer b.deinit();
    var r: Reconciler(RecordingHost) = .{ .gpa = testing.allocator };
    defer r.ids.free.deinit(testing.allocator);

    // [title, row[input]]  →  [title, list, row[input]]
    _ = try a.open(.{ .kind = .view, .style = .{} });
    _ = try a.add(.{ .kind = .text, .style = .{}, .text = "Maps" });
    _ = try a.open(.{ .kind = .view, .style = .{} });
    _ = try a.add(.{ .kind = .input, .style = .{} });
    a.close();
    a.close();
    r.run(null, &a, .{});

    RecordingHost.reset();
    _ = try b.open(.{ .kind = .view, .style = .{} });
    _ = try b.add(.{ .kind = .text, .style = .{}, .text = "Maps" });
    _ = try b.open(.{ .kind = .scroll, .style = .{} });
    b.close();
    _ = try b.open(.{ .kind = .view, .style = .{} });
    _ = try b.add(.{ .kind = .input, .style = .{} });
    b.close();
    b.close();
    r.run(&a, &b, .{});
    try testing.expect(std.mem.indexOf(u8, RecordingHost.log.items, "destroy") == null);
    try testing.expect(std.mem.indexOf(u8, RecordingHost.log.items, "create") != null); // only the list
    try testing.expect(std.mem.indexOf(u8, RecordingHost.log.items, "create 5 view") == null);
}

test "reduce motion turns transitions off and back on" {
    defer RecordingHost.deinit();
    var a = Tree.init(testing.allocator);
    defer a.deinit();
    var b = Tree.init(testing.allocator);
    defer b.deinit();
    var r: Reconciler(RecordingHost) = .{ .gpa = testing.allocator };
    defer r.ids.free.deinit(testing.allocator);
    const one = struct {
        fn f(t: *Tree) !void {
            t.reset();
            _ = try t.open(.{ .kind = .view, .style = .{ .transition = .{ .duration_ms = 250 } } });
            t.close();
        }
    }.f;
    try one(&a);
    r.run(null, &a, .{});
    try testing.expect(std.mem.indexOf(u8, RecordingHost.log.items, "transition 1 250") != null);
    RecordingHost.reset();
    try one(&b);
    r.run(&a, &b, .{ .reduce_motion = true });
    try testing.expectEqualStrings("transition 1 0\n", RecordingHost.log.items);
    RecordingHost.reset();
    try one(&a);
    r.run(&b, &a, .{});
    try testing.expectEqualStrings("transition 1 250\n", RecordingHost.log.items);
}

test "right-to-left flips text alignment" {
    defer RecordingHost.deinit();
    var a = Tree.init(testing.allocator);
    defer a.deinit();
    var b = Tree.init(testing.allocator);
    defer b.deinit();
    var r: Reconciler(RecordingHost) = .{ .gpa = testing.allocator };
    defer r.ids.free.deinit(testing.allocator);

    try build(&a, &.{"x"}, false);
    r.run(null, &a, .{});
    RecordingHost.reset();
    try build(&b, &.{"x"}, false);
    r.run(&a, &b, .{ .rtl = true });
    try testing.expectEqualStrings("text 2 x right\n", RecordingHost.log.items);
}
