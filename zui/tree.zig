//! The tree one render produces. Nodes live in one array; every string in it is copied into the
//! tree's arena, so a tree stays valid after the app state it came from changes.

const std = @import("std");
const style = @import("style.zig");

pub const none: u32 = std.math.maxInt(u32);

/// `scroll` scrolls vertically, `scroll_x` horizontally (Android needs a different view for each).
/// `image` shows a picture from a URL; `path` draws a line (routes on a map); `video` shows a
/// call's camera stream; `text_area` is an input of several lines that grows with its text.
pub const Kind = enum(u8) { view = 0, text = 1, input = 2, scroll = 3, scroll_x = 4, image = 5, path = 6, video = 7, text_area = 8 };

/// The keyboard an input asks for.
pub const Keyboard = enum(u8) { text = 0, email = 1, number = 2, phone = 3, url = 4, decimal = 5 };
/// The label of the keyboard's enter key.
pub const ReturnKey = enum(u8) { default = 0, done = 1, go = 2, next = 3, search = 4, send = 5 };

/// How an input takes its text.
pub const InputType = struct {
    keyboard: Keyboard = .text,
    return_key: ReturnKey = .default,
    /// A password: the text is hidden.
    secure: bool = false,
};

pub const Video = struct {
    /// A stream id from fx.openMedia or a peer's .track event; 0 shows nothing.
    stream: u32,
    mirror: bool = false,
    /// Fill the box and crop, or fit inside it.
    cover: bool = true,
};

/// A polyline in the node's own coordinates.
/// Lines through points. A point with a NaN x starts a new sub-path (an icon is several).
pub const Path = struct {
    points: []const [2]f32,
    /// Stroke color; a width of 0 draws no stroke.
    color: u32,
    width: f32,
    /// Fill color (each sub-path closed), or 0 for none.
    fill: u32 = 0,
    /// Dash and gap lengths; 0 for a solid line.
    dash: [2]f32 = .{ 0, 0 },
    round: bool = true,

    pub fn eql(a: Path, b: Path) bool {
        return a.color == b.color and a.width == b.width and a.fill == b.fill and a.dash[0] == b.dash[0] and a.dash[1] == b.dash[1] and
            a.round == b.round and std.mem.eql(u8, std.mem.sliceAsBytes(a.points), std.mem.sliceAsBytes(b.points));
    }
};

pub const Node = struct {
    kind: Kind,
    style: style.Style,
    /// Stable identity among siblings; 0 means "match by position".
    key: u64 = 0,
    /// Text content, or the value of an input.
    text: []const u8 = "",
    placeholder: []const u8 = "",
    pressable: bool = false,
    /// Receives pointer events (gestures).
    pointer: bool = false,
    path: ?Path = null,
    video: ?Video = null,
    /// Inputs and text areas.
    input_type: InputType = .{},

    parent: u32 = none,
    first_child: u32 = none,
    last_child: u32 = none,
    next: u32 = none,

    /// Set by layout: position relative to the parent node, and for scroll nodes the size of
    /// their content.
    frame: style.Rect = .{},
    content: style.Size = .{},

    /// Set by reconcile: the host's id for this node's native view.
    host: u32 = 0,
};

pub const Tree = struct {
    arena: std.heap.ArenaAllocator,
    nodes: std.ArrayList(Node) = .empty,
    /// Parents still open while building.
    stack: std.ArrayList(u32) = .empty,

    pub fn init(backing: std.mem.Allocator) Tree {
        return .{ .arena = .init(backing) };
    }

    pub fn deinit(t: *Tree) void {
        t.arena.deinit();
    }

    /// Drops all nodes, keeping the memory for the next render.
    pub fn reset(t: *Tree) void {
        _ = t.arena.reset(.retain_capacity);
        t.nodes = .empty;
        t.stack = .empty;
    }

    pub fn allocator(t: *Tree) std.mem.Allocator {
        return t.arena.allocator();
    }

    pub fn root(t: *const Tree) u32 {
        return if (t.nodes.items.len == 0) none else 0;
    }

    /// Adds a node as the last child of the innermost open parent.
    pub fn add(t: *Tree, node: Node) !u32 {
        const a = t.allocator();
        const index: u32 = @intCast(t.nodes.items.len);
        var n = node;
        n.text = try a.dupe(u8, node.text);
        n.placeholder = try a.dupe(u8, node.placeholder);
        if (node.path) |p| {
            // Every field as given; only the points are copied into the tree's memory.
            var copy = p;
            copy.points = try a.dupe([2]f32, p.points);
            n.path = copy;
        }
        if (t.stack.items.len > 0) {
            const p = t.stack.items[t.stack.items.len - 1];
            n.parent = p;
            const parent = &t.nodes.items[p];
            if (parent.last_child == none) parent.first_child = index else t.nodes.items[parent.last_child].next = index;
            parent.last_child = index;
        } else if (t.nodes.items.len > 0) {
            return error.MultipleRoots;
        }
        try t.nodes.append(a, n);
        return index;
    }

    pub fn open(t: *Tree, node: Node) !u32 {
        const index = try t.add(node);
        try t.stack.append(t.allocator(), index);
        return index;
    }

    pub fn close(t: *Tree) void {
        _ = t.stack.pop();
    }

    pub fn children(t: *const Tree, parent: u32) Children {
        return .{ .tree = t, .next_index = t.nodes.items[parent].first_child };
    }

    pub const Children = struct {
        tree: *const Tree,
        next_index: u32,

        pub fn next(it: *Children) ?u32 {
            if (it.next_index == none) return null;
            const i = it.next_index;
            it.next_index = it.tree.nodes.items[i].next;
            return i;
        }
    };
};

test "building links parents and children" {
    var t = Tree.init(std.testing.allocator);
    defer t.deinit();
    _ = try t.open(.{ .kind = .view, .style = .{} });
    _ = try t.add(.{ .kind = .text, .style = .{}, .text = "a" });
    _ = try t.add(.{ .kind = .text, .style = .{}, .text = "b" });
    t.close();
    var it = t.children(0);
    try std.testing.expectEqualStrings("a", t.nodes.items[it.next().?].text);
    try std.testing.expectEqualStrings("b", t.nodes.items[it.next().?].text);
    try std.testing.expectEqual(@as(?u32, null), it.next());
    try std.testing.expectError(error.MultipleRoots, t.add(.{ .kind = .view, .style = .{} }));
}
