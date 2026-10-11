//! The layout engine: computes the frame of every node, on every platform, so the hosts only
//! place views where they are told. A flexbox subset: row/column, justify, align, gap, padding,
//! fixed/auto/fill sizes, grow and shrink, min/max, absolute positioning, and right-to-left
//! mirroring. Text size is the only thing asked of the host.

const std = @import("std");
const st = @import("style.zig");
const tree_mod = @import("tree.zig");

const Tree = tree_mod.Tree;
const Node = tree_mod.Node;
const none = tree_mod.none;
const Size = st.Size;
const Rect = st.Rect;
const inf = st.inf;

/// Size of `text` drawn with `font`, wrapping at `max_width` (may be infinite).
pub const MeasureText = *const fn (text: []const u8, font: st.Font, max_width: f32) Size;

const Cache = struct { max_w: f32 = -1, max_h: f32 = -1, size: Size = .{} };

pub const Engine = struct {
    tree: *Tree,
    measure_text: MeasureText,
    rtl: bool,
    cache: []Cache,

    /// Lays out the whole tree with the root at `frame`.
    pub fn run(tree: *Tree, measure_text: MeasureText, rtl: bool, frame: Rect) !void {
        if (tree.nodes.items.len == 0) return;
        const cache = try tree.allocator().alloc(Cache, tree.nodes.items.len);
        @memset(cache, .{});
        var e: Engine = .{ .tree = tree, .measure_text = measure_text, .rtl = rtl, .cache = cache };
        e.arrange(0, frame);
    }

    fn node(e: *Engine, i: u32) *Node {
        return &e.tree.nodes.items[i];
    }

    /// Border-box size of node `i` when it may use up to `max_w` x `max_h`.
    fn measure(e: *Engine, i: u32, max_w: f32, max_h: f32) Size {
        const c = &e.cache[i];
        if (c.max_w == max_w and c.max_h == max_h) return c.size;
        const size = e.measureUncached(i, max_w, max_h);
        c.* = .{ .max_w = max_w, .max_h = max_h, .size = size };
        return size;
    }

    fn measureUncached(e: *Engine, i: u32, max_w: f32, max_h: f32) Size {
        const n = e.node(i);
        const s = n.style;
        const pad_w = s.padding.start + s.padding.end;
        const pad_h = s.padding.top + s.padding.bottom;
        const avail_w = clampMax(switch (s.width) {
            .px => |v| v,
            else => max_w,
        }, s);
        const inner_max_w = @max(0, avail_w - pad_w);

        var content: Size = .{};
        switch (n.kind) {
            .text => content = e.measure_text(n.text, st.Font.of(s), inner_max_w),
            .input => {
                const sample = if (n.text.len > 0) n.text else n.placeholder;
                const font = st.Font.of(s);
                content = .{ .w = e.measure_text(sample, font, inf).w, .h = font.line_height };
            },
            .view, .scroll, .scroll_x => {
                const row = s.direction == .row;
                var count: usize = 0;
                var it = e.tree.children(i);
                while (it.next()) |c| {
                    if (e.node(c).style.position == .absolute) continue;
                    const cs = e.measure(c, inner_max_w, inf);
                    if (row) {
                        content.w += cs.w;
                        content.h = @max(content.h, cs.h);
                    } else {
                        content.w = @max(content.w, cs.w);
                        content.h += cs.h;
                    }
                    count += 1;
                }
                const gaps = if (count > 1) s.gap * @as(f32, @floatFromInt(count - 1)) else 0;
                if (row) content.w += gaps else content.h += gaps;
            },
        }

        const w = switch (s.width) {
            .px => |v| v,
            .fill => if (std.math.isFinite(max_w)) max_w else content.w + pad_w,
            .auto => content.w + pad_w,
        };
        const h = switch (s.height) {
            .px => |v| v,
            .fill => if (std.math.isFinite(max_h)) max_h else content.h + pad_h,
            .auto => content.h + pad_h,
        };
        return .{ .w = clampW(w, s), .h = clampH(h, s) };
    }

    /// Sets node `i`'s frame (relative to its parent) and lays out its children.
    fn arrange(e: *Engine, i: u32, frame: Rect) void {
        const n = e.node(i);
        n.frame = frame;
        const s = n.style;
        if (n.kind == .text or n.kind == .input) return;

        const pad_left = if (e.rtl) s.padding.end else s.padding.start;
        const inner_w = @max(0, frame.w - s.padding.start - s.padding.end);
        var inner_h = @max(0, frame.h - s.padding.top - s.padding.bottom);

        if (n.kind == .scroll or n.kind == .scroll_x) {
            // The content scrolls along the main axis, so it is not limited there.
            if (s.direction == .row) {
                const content_w = e.flow(i, inner_w, inner_h, inf, inner_h, pad_left, s.padding.top);
                n.content = .{ .w = @max(frame.w, content_w + s.padding.start + s.padding.end), .h = frame.h };
            } else {
                const content_h = e.flow(i, inner_w, inner_h, inner_w, inf, pad_left, s.padding.top);
                inner_h = @max(inner_h, content_h);
                n.content = .{ .w = frame.w, .h = @max(frame.h, content_h + s.padding.top + s.padding.bottom) };
            }
        } else {
            _ = e.flow(i, inner_w, inner_h, inner_w, inner_h, pad_left, s.padding.top);
        }
        e.absolutes(i, frame.w, frame.h);
    }

    /// Lays out the flow children of `i` in a box of `box_w` x `box_h` at (`ox`, `oy`). Along
    /// the main axis the children may use `main_limit` (infinite inside a scroll). Returns the
    /// length the children use along the main axis.
    fn flow(e: *Engine, i: u32, box_w: f32, box_h: f32, limit_w: f32, limit_h: f32, ox: f32, oy: f32) f32 {
        const s = e.node(i).style;
        const row = s.direction == .row;
        const main_avail = if (row) limit_w else limit_h;
        const cross_avail = if (row) box_h else box_w;

        // Lives in the tree's arena, which is reset with the tree.
        var list: std.ArrayList(Item) = .empty;
        var it = e.tree.children(i);
        while (it.next()) |c| {
            const cs = e.node(c).style;
            if (cs.position == .absolute) continue;
            const a = cs.align_self orelse s.align_items;
            const cross_dim = if (row) cs.height else cs.width;
            const main_dim = if (row) cs.width else cs.height;

            // Cross size first: in a column the width decides how text wraps.
            const stretched = cross_dim == .fill or (a == .stretch and cross_dim == .auto);
            var cross: f32 = switch (cross_dim) {
                .px => |v| v,
                else => if (stretched) cross_avail else if (row)
                    e.measure(c, limit_w, cross_avail).h
                else
                    e.measure(c, cross_avail, inf).w,
            };
            cross = if (row) clampH(cross, cs) else clampW(cross, cs);

            const base: f32 = switch (main_dim) {
                .px => |v| v,
                // Like CSS `flex: 1`: start from nothing and take a share of the free space.
                .fill => 0,
                .auto => if (row) e.measure(c, @min(limit_w, box_w), cross).w else e.measure(c, cross, inf).h,
            };
            const grow = if (main_dim == .fill) @max(cs.grow, 1) else cs.grow;
            list.append(e.tree.allocator(), .{ .index = c, .main = base, .cross = cross, .grow = grow, .shrink = main_dim == .auto, .stretched = stretched, .align_ = a }) catch return 0;
        }
        const kids = list.items;
        if (kids.len == 0) return 0;

        const gaps = s.gap * @as(f32, @floatFromInt(kids.len - 1));
        var used: f32 = gaps;
        for (kids) |k| used += k.main;

        if (std.math.isFinite(main_avail)) {
            const free = main_avail - used;
            if (free > 0) {
                var total_grow: f32 = 0;
                for (kids) |k| total_grow += k.grow;
                if (total_grow > 0) for (kids) |*k| {
                    k.main += free * k.grow / total_grow;
                };
            } else if (free < 0) {
                var total_shrink: f32 = 0;
                for (kids) |k| if (k.shrink) {
                    total_shrink += k.main;
                };
                if (total_shrink > 0) for (kids) |*k| if (k.shrink) {
                    k.main = @max(0, k.main + free * k.main / total_shrink);
                };
            }
            for (kids) |*k| {
                const cs = e.node(k.index).style;
                k.main = if (row) clampW(k.main, cs) else clampH(k.main, cs);
            }
        }

        // A row child's height can depend on its final width (wrapping text).
        if (row) for (kids) |*k| {
            const cs = e.node(k.index).style;
            if (!k.stretched and cs.height != .px) k.cross = clampH(e.measure(k.index, k.main, cross_avail).h, cs);
        };

        used = gaps;
        for (kids) |k| used += k.main;
        const box_main = if (row) box_w else box_h;
        const free = if (std.math.isFinite(main_avail)) @max(0, box_main - used) else 0;
        var pos: f32 = 0;
        var between: f32 = s.gap;
        switch (s.justify) {
            .start => {},
            .center => pos = free / 2,
            .end => pos = free,
            .space_between => if (kids.len > 1) {
                between += free / @as(f32, @floatFromInt(kids.len - 1));
            },
        }

        for (kids) |k| {
            const cross_off: f32 = switch (k.align_) {
                .start, .stretch => 0,
                .center => (cross_avail - k.cross) / 2,
                .end => cross_avail - k.cross,
            };
            // Logical position (x from the start edge), then mirrored for right-to-left.
            var r: Rect = if (row)
                .{ .x = pos, .y = cross_off, .w = k.main, .h = k.cross }
            else
                .{ .x = cross_off, .y = pos, .w = k.cross, .h = k.main };
            if (e.rtl) r.x = box_w - r.x - r.w;
            r.x += ox;
            r.y += oy;
            e.arrange(k.index, r);
            pos += k.main + between;
        }
        return pos - between;
    }

    fn absolutes(e: *Engine, i: u32, w: f32, h: f32) void {
        var it = e.tree.children(i);
        while (it.next()) |c| {
            const cs = e.node(c).style;
            if (cs.position != .absolute) continue;
            const in = cs.inset;
            var size = e.measure(c, w, h);
            if (cs.width == .fill) size.w = w;
            if (cs.height == .fill) size.h = h;
            if (in.start != null and in.end != null and cs.width != .px) size.w = clampW(w - in.start.? - in.end.?, cs);
            if (in.top != null and in.bottom != null and cs.height != .px) size.h = clampH(h - in.top.? - in.bottom.?, cs);
            const x = if (in.start) |v| v else if (in.end) |v| w - v - size.w else 0;
            const y = if (in.top) |v| v else if (in.bottom) |v| h - v - size.h else 0;
            e.arrange(c, .{ .x = if (e.rtl) w - x - size.w else x, .y = y, .w = size.w, .h = size.h });
        }
    }
};

const Item = struct {
    index: u32,
    main: f32,
    cross: f32,
    grow: f32,
    shrink: bool,
    stretched: bool,
    align_: st.Align,
};

fn clampMax(v: f32, s: st.Style) f32 {
    return @min(v, s.max_width);
}

fn clampW(v: f32, s: st.Style) f32 {
    return @max(s.min_width, @min(v, s.max_width));
}

fn clampH(v: f32, s: st.Style) f32 {
    return @max(s.min_height, @min(v, s.max_height));
}

// ---------------------------------------------------------------------------------------------
// Tests use a fake font: every character is 8 points wide, lines wrap at whole characters.

pub fn fakeMeasure(text: []const u8, font: st.Font, max_width: f32) Size {
    const len: f32 = @floatFromInt(std.unicode.utf8CountCodepoints(text) catch text.len);
    const per_line = if (std.math.isFinite(max_width)) @max(1, @floor(max_width / 8)) else len;
    const lines = @max(1, @ceil(len / per_line));
    return .{ .w = @min(len, per_line) * 8, .h = lines * font.line_height };
}

const testing = std.testing;

fn testTree() Tree {
    return Tree.init(testing.allocator);
}

test "column stacks children with gap and padding" {
    var t = testTree();
    defer t.deinit();
    _ = try t.open(.{ .kind = .view, .style = .{ .padding = .all(10), .gap = 5 } });
    _ = try t.add(.{ .kind = .view, .style = .{ .height = .{ .px = 20 } } });
    _ = try t.add(.{ .kind = .view, .style = .{ .height = .{ .px = 30 } } });
    t.close();
    try Engine.run(&t, fakeMeasure, false, .{ .w = 100, .h = 200 });
    try testing.expectEqual(Rect{ .x = 10, .y = 10, .w = 80, .h = 20 }, t.nodes.items[1].frame);
    try testing.expectEqual(Rect{ .x = 10, .y = 35, .w = 80, .h = 30 }, t.nodes.items[2].frame);
}

test "row grows fill children and mirrors in right-to-left" {
    var t = testTree();
    defer t.deinit();
    _ = try t.open(.{ .kind = .view, .style = .{ .direction = .row } });
    _ = try t.add(.{ .kind = .view, .style = .{ .width = .{ .px = 30 } } });
    _ = try t.add(.{ .kind = .view, .style = .{ .width = .fill } });
    t.close();
    try Engine.run(&t, fakeMeasure, false, .{ .w = 100, .h = 40 });
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 30, .h = 40 }, t.nodes.items[1].frame);
    try testing.expectEqual(Rect{ .x = 30, .y = 0, .w = 70, .h = 40 }, t.nodes.items[2].frame);

    try Engine.run(&t, fakeMeasure, true, .{ .w = 100, .h = 40 });
    try testing.expectEqual(Rect{ .x = 70, .y = 0, .w = 30, .h = 40 }, t.nodes.items[1].frame);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 70, .h = 40 }, t.nodes.items[2].frame);
}

test "text wraps to the column width" {
    var t = testTree();
    defer t.deinit();
    _ = try t.open(.{ .kind = .view, .style = .{} });
    // 20 characters at 8 points in an 80-point column: 2 lines.
    _ = try t.add(.{ .kind = .text, .style = .{ .font_size = 10, .line_height = 2 }, .text = "abcdefghijklmnopqrst" });
    t.close();
    try Engine.run(&t, fakeMeasure, false, .{ .w = 80, .h = 300 });
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 80, .h = 40 }, t.nodes.items[1].frame);
}

test "justify center and align center" {
    var t = testTree();
    defer t.deinit();
    _ = try t.open(.{ .kind = .view, .style = .{ .justify = .center, .align_items = .center } });
    _ = try t.add(.{ .kind = .view, .style = .{ .width = .{ .px = 20 }, .height = .{ .px = 10 } } });
    t.close();
    try Engine.run(&t, fakeMeasure, false, .{ .w = 100, .h = 50 });
    try testing.expectEqual(Rect{ .x = 40, .y = 20, .w = 20, .h = 10 }, t.nodes.items[1].frame);
}

test "space between" {
    var t = testTree();
    defer t.deinit();
    _ = try t.open(.{ .kind = .view, .style = .{ .direction = .row, .justify = .space_between, .align_items = .start } });
    _ = try t.add(.{ .kind = .view, .style = .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } } });
    _ = try t.add(.{ .kind = .view, .style = .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } } });
    t.close();
    try Engine.run(&t, fakeMeasure, false, .{ .w = 100, .h = 10 });
    try testing.expectEqual(@as(f32, 90), t.nodes.items[2].frame.x);
}

test "row shrinks text so it wraps instead of overflowing" {
    var t = testTree();
    defer t.deinit();
    _ = try t.open(.{ .kind = .view, .style = .{ .direction = .row, .align_items = .start } });
    _ = try t.add(.{ .kind = .view, .style = .{ .width = .{ .px = 40 }, .height = .{ .px = 10 } } });
    _ = try t.add(.{ .kind = .text, .style = .{ .font_size = 10, .line_height = 1 }, .text = "aaaaaaaaaaaaaaaaaaaa" });
    t.close();
    try Engine.run(&t, fakeMeasure, false, .{ .w = 120, .h = 100 });
    const txt = t.nodes.items[2].frame;
    try testing.expectEqual(@as(f32, 40), txt.x);
    try testing.expectEqual(@as(f32, 80), txt.w);
    try testing.expectEqual(@as(f32, 20), txt.h); // 160 points of text in 80: two lines
}

test "scroll content is measured beyond the viewport" {
    var t = testTree();
    defer t.deinit();
    _ = try t.open(.{ .kind = .scroll, .style = .{ .gap = 10 } });
    for (0..5) |_| _ = try t.add(.{ .kind = .view, .style = .{ .height = .{ .px = 50 } } });
    t.close();
    try Engine.run(&t, fakeMeasure, false, .{ .w = 100, .h = 100 });
    try testing.expectEqual(Size{ .w = 100, .h = 290 }, t.nodes.items[0].content);
    try testing.expectEqual(@as(f32, 240), t.nodes.items[5].frame.y);
}

test "absolute child pinned to the end and bottom" {
    var t = testTree();
    defer t.deinit();
    _ = try t.open(.{ .kind = .view, .style = .{} });
    _ = try t.add(.{ .kind = .view, .style = .{ .position = .absolute, .inset = .{ .end = 10, .bottom = 10 }, .width = .{ .px = 20 }, .height = .{ .px = 20 } } });
    t.close();
    try Engine.run(&t, fakeMeasure, false, .{ .w = 100, .h = 100 });
    try testing.expectEqual(Rect{ .x = 70, .y = 70, .w = 20, .h = 20 }, t.nodes.items[1].frame);
    try Engine.run(&t, fakeMeasure, true, .{ .w = 100, .h = 100 });
    try testing.expectEqual(Rect{ .x = 10, .y = 70, .w = 20, .h = 20 }, t.nodes.items[1].frame);
}
