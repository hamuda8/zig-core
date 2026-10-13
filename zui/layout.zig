//! The layout engine: computes the frame of every node, on every platform, so the hosts only
//! place views where they are told. A flexbox subset: row/column, justify, align, gap, padding,
//! fixed/auto/fill sizes, grow and shrink, min/max, absolute positioning, rows that wrap,
//! equal-column grids, and right-to-left mirroring. Text size is the only thing asked of the
//! host.

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
/// The same for text with runs drawn differently (bold words, links).
pub const MeasureRich = *const fn (text: []const u8, spans: []const tree_mod.Span, font: st.Font, max_width: f32) Size;

const Cache = struct { max_w: f32 = -1, max_h: f32 = -1, size: Size = .{} };

pub const Engine = struct {
    tree: *Tree,
    measure_text: MeasureText,
    measure_rich: ?MeasureRich = null,
    rtl: bool,
    cache: []Cache,

    /// Lays out the whole tree with the root at `frame`.
    pub fn run(tree: *Tree, measure_text: MeasureText, rtl: bool, frame: Rect) !void {
        return runRich(tree, measure_text, null, rtl, frame);
    }

    pub fn runRich(tree: *Tree, measure_text: MeasureText, measure_rich: ?MeasureRich, rtl: bool, frame: Rect) !void {
        if (tree.nodes.items.len == 0) return;
        const cache = try tree.allocator().alloc(Cache, tree.nodes.items.len);
        @memset(cache, .{});
        var e: Engine = .{ .tree = tree, .measure_text = measure_text, .measure_rich = measure_rich, .rtl = rtl, .cache = cache };
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
            .text, .text_select => content = if (n.spans.len > 0 and e.measure_rich != null)
                e.measure_rich.?(n.text, n.spans, st.Font.of(s), inner_max_w)
            else
                e.measure_text(n.text, st.Font.of(s), inner_max_w),
            .input => {
                const sample = if (n.text.len > 0) n.text else n.placeholder;
                const font = st.Font.of(s);
                content = .{ .w = e.measure_text(sample, font, inf).w, .h = font.line_height };
            },
            // As many lines as the text wraps to, at least one; a newline at the end starts one
            // more (measured with a zero-width space after it, so every platform counts it).
            .text_area => {
                const font = st.Font.of(s);
                const sample = if (n.text.len > 0) n.text else n.placeholder;
                if (sample.len == 0) {
                    content = .{ .h = font.line_height };
                } else {
                    const ends_open = sample[sample.len - 1] == '\n';
                    const text = if (ends_open) std.mem.concat(e.tree.allocator(), u8, &.{ sample, "\u{200B}" }) catch sample else sample;
                    content = e.measure_text(text, font, inner_max_w);
                    content.h = @max(content.h, font.line_height);
                }
            },
            // Pictures and lines take the size their style gives them.
            .image, .path, .video => {},
            .view, .scroll, .scroll_x => {
                const row = s.direction == .row;
                const scrolls = n.kind != .view;
                if (s.grid) |g| {
                    content = e.grid(i, g, inner_max_w, null);
                } else if (row and s.wrap and std.math.isFinite(inner_max_w)) {
                    content = e.wrapLines(i, inner_max_w, null);
                } else if (row and !scrolls and std.math.isFinite(inner_max_w)) {
                    // As the row will lay them out: flexible children share what the fixed
                    // ones leave, and wrapped text is as tall as at its final width.
                    const kids = e.items(i, inner_max_w, inf, inner_max_w);
                    for (kids) |k| {
                        content.w += k.main;
                        content.h = @max(content.h, k.cross);
                    }
                    if (kids.len > 1) content.w += s.gap * @as(f32, @floatFromInt(kids.len - 1));
                } else {
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
                }
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
        // This node was placed by its parent; its children follow its own direction.
        const parent_rtl = e.rtl;
        defer e.rtl = parent_rtl;
        if (s.no_mirror) e.rtl = false;
        if (n.kind == .text or n.kind == .text_select or n.kind == .input or n.kind == .text_area or n.kind == .image) return;

        const pad_left = if (e.rtl) s.padding.end else s.padding.start;
        const inner_w = @max(0, frame.w - s.padding.start - s.padding.end);
        var inner_h = @max(0, frame.h - s.padding.top - s.padding.bottom);

        if (n.kind == .scroll or n.kind == .scroll_x) {
            // The content scrolls along the main axis, so it is not limited there.
            if (s.direction == .row and s.grid == null and !s.wrap) {
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

    /// The flow children of `i` with their sizes along and across `i`'s direction, in a box of
    /// `box_w` x `box_h` where the main axis may use `main_avail` (infinite inside a scroll).
    /// `box_h` is infinite while a row is being measured: its children then take their own
    /// height. Lives in the tree's arena, which is reset with the tree.
    fn items(e: *Engine, i: u32, box_w: f32, box_h: f32, main_avail: f32) []Item {
        const s = e.node(i).style;
        const row = s.direction == .row;
        const cross_avail = if (row) box_h else box_w;
        const cross_known = std.math.isFinite(cross_avail);

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
                else => if (stretched and cross_known) cross_avail else if (row)
                    e.measure(c, main_avail, cross_avail).h
                else
                    e.measure(c, cross_avail, inf).w,
            };
            cross = if (row) clampH(cross, cs) else clampW(cross, cs);

            const base: f32 = switch (main_dim) {
                .px => |v| v,
                // Like CSS `flex: 1`: start from nothing and take a share of the free space.
                .fill => 0,
                .auto => if (row) e.measure(c, @min(main_avail, box_w), cross).w else e.measure(c, cross, inf).h,
            };
            const grow = if (main_dim == .fill) @max(cs.grow, 1) else cs.grow;
            list.append(e.tree.allocator(), .{ .index = c, .main = base, .cross = cross, .grow = grow, .shrink = main_dim == .auto, .stretched = stretched and cross_known, .align_ = a }) catch return &.{};
        }
        const kids = list.items;
        if (kids.len == 0) return kids;

        var used: f32 = s.gap * @as(f32, @floatFromInt(kids.len - 1));
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
        return kids;
    }

    /// Lays out the flow children of `i` in a box of `box_w` x `box_h` at (`ox`, `oy`). Along
    /// the main axis the children may use `limit_w` / `limit_h` (infinite inside a scroll).
    /// Returns the length the children use along the main axis (down, for wrapped rows and grids).
    fn flow(e: *Engine, i: u32, box_w: f32, box_h: f32, limit_w: f32, limit_h: f32, ox: f32, oy: f32) f32 {
        const s = e.node(i).style;
        if (s.grid) |g| return e.grid(i, g, box_w, .{ ox, oy }).h;
        const row = s.direction == .row;
        if (row and s.wrap) return e.wrapLines(i, box_w, .{ ox, oy }).h;
        const main_avail = if (row) limit_w else limit_h;
        const cross_avail = if (row) box_h else box_w;

        const kids = e.items(i, box_w, box_h, main_avail);
        if (kids.len == 0) return 0;

        var used: f32 = s.gap * @as(f32, @floatFromInt(kids.len - 1));
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

    /// A row that wraps: children at their own width, on as many lines of `box_w` as they need.
    /// Places them when `at` is given (the box's origin); returns the size they take.
    fn wrapLines(e: *Engine, i: u32, box_w: f32, at: ?[2]f32) Size {
        const s = e.node(i).style;
        const line_gap = s.line_gap orelse s.gap;
        const a = e.tree.allocator();
        // Each child's size, then the lines as ranges of them.
        var sizes: std.ArrayList(struct { index: u32, w: f32, h: f32 }) = .empty;
        var it = e.tree.children(i);
        while (it.next()) |c| {
            const cs = e.node(c).style;
            if (cs.position == .absolute) continue;
            const w = clampW(switch (cs.width) {
                .px => |v| v,
                .fill => box_w,
                .auto => @min(box_w, e.measure(c, box_w, inf).w),
            }, cs);
            const h = clampH(switch (cs.height) {
                .px => |v| v,
                else => e.measure(c, w, inf).h,
            }, cs);
            sizes.append(a, .{ .index = c, .w = w, .h = h }) catch return .{};
        }
        var total: Size = .{};
        var start: usize = 0;
        var y: f32 = 0;
        while (start < sizes.items.len) {
            // As many as fit, at least one.
            var end = start + 1;
            var line_w = sizes.items[start].w;
            var line_h = sizes.items[start].h;
            while (end < sizes.items.len and line_w + s.gap + sizes.items[end].w <= box_w + 0.01) : (end += 1) {
                line_w += s.gap + sizes.items[end].w;
                line_h = @max(line_h, sizes.items[end].h);
            }
            if (at) |origin| {
                const line = sizes.items[start..end];
                const free = @max(0, box_w - line_w);
                var x: f32 = 0;
                var between = s.gap;
                switch (s.justify) {
                    .start => {},
                    .center => x = free / 2,
                    .end => x = free,
                    .space_between => if (line.len > 1) {
                        between += free / @as(f32, @floatFromInt(line.len - 1));
                    },
                }
                for (line) |k| {
                    const cs = e.node(k.index).style;
                    const al = cs.align_self orelse s.align_items;
                    const h = if (al == .stretch and cs.height == .auto) clampH(line_h, cs) else k.h;
                    const dy: f32 = switch (al) {
                        .start, .stretch => 0,
                        .center => (line_h - h) / 2,
                        .end => line_h - h,
                    };
                    var r: Rect = .{ .x = x, .y = y + dy, .w = k.w, .h = h };
                    if (e.rtl) r.x = box_w - r.x - r.w;
                    r.x += origin[0];
                    r.y += origin[1];
                    e.arrange(k.index, r);
                    x += k.w + between;
                }
            }
            total.w = @max(total.w, line_w);
            y += line_h + line_gap;
            start = end;
        }
        total.h = if (sizes.items.len > 0) y - line_gap else 0;
        return total;
    }

    /// Equal columns across `box_w`, rows as tall as their tallest cell. Places the children when
    /// `at` is given (the box's origin); returns the size they take.
    fn grid(e: *Engine, i: u32, g: st.Grid, box_w: f32, at: ?[2]f32) Size {
        const s = e.node(i).style;
        const line_gap = s.line_gap orelse s.gap;
        const a = e.tree.allocator();
        var kids: std.ArrayList(u32) = .empty;
        var it = e.tree.children(i);
        while (it.next()) |c| {
            if (e.node(c).style.position == .absolute) continue;
            kids.append(a, c) catch return .{};
        }
        if (kids.items.len == 0) return .{};
        const cols = g.count(box_w, s.gap);
        const gaps = s.gap * @as(f32, @floatFromInt(cols - 1));
        const col_w = if (std.math.isFinite(box_w)) @max(0, (box_w - gaps) / @as(f32, @floatFromInt(cols))) else blk: {
            // Unbounded (being measured in a row): as wide as the widest child.
            var widest: f32 = g.min_width;
            for (kids.items) |c| widest = @max(widest, e.measure(c, inf, inf).w);
            break :blk widest;
        };

        var y: f32 = 0;
        var start: usize = 0;
        while (start < kids.items.len) : (start += cols) {
            const row = kids.items[start..@min(kids.items.len, start + cols)];
            var row_h: f32 = 0;
            for (row) |c| {
                const cs = e.node(c).style;
                const w = cellWidth(cs, col_w);
                row_h = @max(row_h, clampH(switch (cs.height) {
                    .px => |v| v,
                    else => e.measure(c, w, inf).h,
                }, cs));
            }
            if (at) |origin| for (row, 0..) |c, col| {
                const cs = e.node(c).style;
                const al = cs.align_self orelse s.align_items;
                const w = cellWidth(cs, col_w);
                const h = clampH(switch (cs.height) {
                    .px => |v| v,
                    .fill => row_h,
                    .auto => if (al == .stretch) row_h else e.measure(c, w, inf).h,
                }, cs);
                const dy: f32 = switch (al) {
                    .start, .stretch => 0,
                    .center => (row_h - h) / 2,
                    .end => row_h - h,
                };
                var r: Rect = .{ .x = @as(f32, @floatFromInt(col)) * (col_w + s.gap), .y = y + dy, .w = w, .h = h };
                if (e.rtl) r.x = box_w - r.x - r.w;
                r.x += origin[0];
                r.y += origin[1];
                e.arrange(c, r);
            };
            y += row_h + line_gap;
        }
        const width = if (std.math.isFinite(box_w)) box_w else col_w * @as(f32, @floatFromInt(cols)) + gaps;
        return .{ .w = width, .h = y - line_gap };
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

/// A grid cell's child: the column's width unless it has its own.
fn cellWidth(s: st.Style, col_w: f32) f32 {
    return clampW(switch (s.width) {
        .px => |v| @min(v, col_w),
        else => col_w,
    }, s);
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

test "no_mirror keeps a subtree left to right" {
    var t = testTree();
    defer t.deinit();
    _ = try t.open(.{ .kind = .view, .style = .{ .direction = .row } });
    _ = try t.open(.{ .kind = .view, .style = .{ .width = .{ .px = 100 }, .direction = .row, .no_mirror = true } });
    _ = try t.add(.{ .kind = .view, .style = .{ .width = .{ .px = 10 } } });
    t.close();
    t.close();
    try Engine.run(&t, fakeMeasure, true, .{ .w = 200, .h = 50 });
    // The map box itself is mirrored to the right; what is inside it is not.
    try testing.expectEqual(@as(f32, 100), t.nodes.items[1].frame.x);
    try testing.expectEqual(@as(f32, 0), t.nodes.items[2].frame.x);
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

test "a text area grows with its lines" {
    var t = testTree();
    defer t.deinit();
    _ = try t.open(.{ .kind = .view, .style = .{} });
    _ = try t.add(.{ .kind = .text_area, .style = .{ .line_height = 1 }, .text = "" });
    _ = try t.add(.{ .kind = .text_area, .style = .{ .line_height = 1 }, .text = "a long line that wraps" });
    _ = try t.add(.{ .kind = .text_area, .style = .{ .line_height = 1 }, .text = "ab\n" });
    t.close();
    try Engine.run(&t, fakeMeasure, false, .{ .w = 80, .h = 400 });
    try testing.expectEqual(@as(f32, 15), t.nodes.items[1].frame.h);
    try testing.expectEqual(@as(f32, 45), t.nodes.items[2].frame.h); // 22 characters, 10 a line
    try testing.expectEqual(@as(f32, 15), t.nodes.items[3].frame.h); // fake measure counts characters
}

test "a row in a column is as tall as its wrapped text next to a fixed value" {
    var t = testTree();
    defer t.deinit();
    _ = try t.open(.{ .kind = .view, .style = .{} });
    _ = try t.open(.{ .kind = .view, .style = .{ .direction = .row, .gap = 10 } });
    // 20 characters (160 points) beside a 50-point value, in 140: the text gets 80, two lines.
    _ = try t.add(.{ .kind = .text, .style = .{ .width = .fill, .line_height = 1 }, .text = "aaaaaaaaaaaaaaaaaaaa" });
    _ = try t.add(.{ .kind = .view, .style = .{ .width = .{ .px = 50 }, .height = .{ .px = 10 } } });
    t.close();
    _ = try t.add(.{ .kind = .view, .style = .{ .height = .{ .px = 5 } } });
    t.close();
    try Engine.run(&t, fakeMeasure, false, .{ .w = 140, .h = 300 });
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 80, .h = 30 }, t.nodes.items[2].frame);
    try testing.expectEqual(@as(f32, 30), t.nodes.items[1].frame.h);
    // What follows the row starts below the text, not over it.
    try testing.expectEqual(@as(f32, 30), t.nodes.items[4].frame.y);

    // The same with auto-sized text: it shrinks to what the value leaves.
    t.nodes.items[2].style.width = .auto;
    try Engine.run(&t, fakeMeasure, false, .{ .w = 140, .h = 300 });
    try testing.expectEqual(@as(f32, 80), t.nodes.items[2].frame.w);
    try testing.expectEqual(@as(f32, 30), t.nodes.items[4].frame.y);
}

test "a wrapping row puts what does not fit on the next line" {
    var t = testTree();
    defer t.deinit();
    _ = try t.open(.{ .kind = .view, .style = .{} });
    _ = try t.open(.{ .kind = .view, .style = .{ .direction = .row, .wrap = true, .gap = 10, .line_gap = 4, .align_items = .start } });
    for (0..5) |_| _ = try t.add(.{ .kind = .view, .style = .{ .width = .{ .px = 30 }, .height = .{ .px = 20 } } });
    t.close();
    _ = try t.add(.{ .kind = .view, .style = .{ .height = .{ .px = 5 } } });
    t.close();
    // 100 wide: three of 30 with gaps of 10 (110) do not fit; two per line, three lines.
    try Engine.run(&t, fakeMeasure, false, .{ .w = 100, .h = 300 });
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 30, .h = 20 }, t.nodes.items[2].frame);
    try testing.expectEqual(Rect{ .x = 40, .y = 0, .w = 30, .h = 20 }, t.nodes.items[3].frame);
    try testing.expectEqual(Rect{ .x = 0, .y = 24, .w = 30, .h = 20 }, t.nodes.items[4].frame);
    try testing.expectEqual(Rect{ .x = 0, .y = 48, .w = 30, .h = 20 }, t.nodes.items[6].frame);
    try testing.expectEqual(@as(f32, 68), t.nodes.items[1].frame.h);
    try testing.expectEqual(@as(f32, 68), t.nodes.items[7].frame.y);
    // Right to left: lines start at the right edge.
    try Engine.run(&t, fakeMeasure, true, .{ .w = 100, .h = 300 });
    try testing.expectEqual(@as(f32, 70), t.nodes.items[2].frame.x);
    try testing.expectEqual(@as(f32, 30), t.nodes.items[3].frame.x);
}

test "a grid: fixed columns, or as many as fit a minimum width" {
    var t = testTree();
    defer t.deinit();
    _ = try t.open(.{ .kind = .view, .style = .{} });
    _ = try t.open(.{ .kind = .view, .style = .{ .grid = .{ .columns = 3 }, .gap = 10 } });
    _ = try t.add(.{ .kind = .view, .style = .{ .height = .{ .px = 20 } } });
    _ = try t.add(.{ .kind = .view, .style = .{ .height = .{ .px = 40 } } });
    _ = try t.add(.{ .kind = .view, .style = .{} });
    _ = try t.add(.{ .kind = .view, .style = .{ .height = .{ .px = 10 } } });
    t.close();
    t.close();
    try Engine.run(&t, fakeMeasure, false, .{ .w = 320, .h = 400 });
    // (320 - 20) / 3 = 100 a column; the first row is as tall as its tallest cell.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 20 }, t.nodes.items[2].frame);
    try testing.expectEqual(Rect{ .x = 110, .y = 0, .w = 100, .h = 40 }, t.nodes.items[3].frame);
    try testing.expectEqual(Rect{ .x = 220, .y = 0, .w = 100, .h = 40 }, t.nodes.items[4].frame); // stretched
    try testing.expectEqual(Rect{ .x = 0, .y = 50, .w = 100, .h = 10 }, t.nodes.items[5].frame);
    try testing.expectEqual(@as(f32, 60), t.nodes.items[1].frame.h);

    t.nodes.items[1].style.grid = .{ .min_width = 140 };
    try Engine.run(&t, fakeMeasure, false, .{ .w = 320, .h = 400 });
    // Two columns of 140 or more fit in 320: each 155.
    try testing.expectEqual(Rect{ .x = 165, .y = 0, .w = 155, .h = 40 }, t.nodes.items[3].frame);
    try testing.expectEqual(@as(f32, 50), t.nodes.items[4].frame.y);
}
