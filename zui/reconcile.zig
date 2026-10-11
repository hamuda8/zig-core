//! Compares the previous tree with the new one and tells the host only what changed: views to
//! create, move or destroy, and the frames, boxes and text that differ.
//!
//! A host is a type with these functions (all ids are host view ids; parent 0 is the root):
//!   create(id, Kind)                 destroy(id)              insert(parent, id, index)
//!   frame(id, Rect)                  box(id, Box)             pressable(id, bool)
//!   text(id, []const u8, Font, color: u32, PhysicalAlign)
//!   input(id, value, placeholder, Font, color: u32, PhysicalAlign)
//!   content(id, Size)                — scroll nodes: size of what scrolls

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
};

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

            // Match each new child: by key when it has one, otherwise by position and kind.
            var new_kids: std.ArrayList(u32) = .empty;
            var match: std.ArrayList(u32) = .empty;
            it = new.children(ni);
            var pos: usize = 0;
            while (it.next()) |c| : (pos += 1) {
                new_kids.append(a, c) catch return;
                const n = new.nodes.items[c];
                var found: u32 = none;
                for (old_kids.items, 0..) |oc, k| {
                    if (used[k]) continue;
                    const o = old.nodes.items[oc];
                    if (o.kind != n.kind or o.key != n.key) continue;
                    if (n.key == 0 and k != pos) continue;
                    found = @intCast(k);
                    break;
                }
                if (found != none) used[found] = true;
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

            if (o == null or !o.?.frame.eql(n.frame)) H.frame(id, n.frame);

            const box = st.Box.of(s, is_pressed);
            if (o == null or !std.meta.eql(st.Box.of(o.?.style, was_pressed), box)) H.box(id, box);

            if (o == null or o.?.pressable != n.pressable) {
                if (n.pressable or o != null) H.pressable(id, n.pressable);
            }

            const font = st.Font.of(s);
            const color = s.color.argb();
            const al = st.physicalAlign(s.text_align, r.now.rtl);
            const text_changed = o == null or !std.mem.eql(u8, o.?.text, n.text) or
                !std.meta.eql(st.Font.of(o.?.style), font) or o.?.style.color.argb() != color or
                st.physicalAlign(o.?.style.text_align, r.prev.rtl) != al;
            switch (n.kind) {
                .text => if (text_changed) H.text(id, n.text, font, color, al),
                .input => if (text_changed or !std.mem.eql(u8, o.?.placeholder, n.placeholder))
                    H.input(id, n.text, n.placeholder, font, color, al),
                .scroll, .scroll_x => if (o == null or !std.meta.eql(o.?.content, n.content)) H.content(id, n.content),
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
    pub fn content(id: u32, s: st.Size) void {
        write("content {d} {d} {d}", .{ id, s.w, s.h });
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
