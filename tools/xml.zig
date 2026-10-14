//! Just enough XML for the APK builder: Maven POMs and Android manifests. A small DOM (elements,
//! attributes, text), entities decoded, comments and processing instructions dropped, and a
//! writer for the merged manifest. Not a validating parser: it trusts well-formed input.

const std = @import("std");

pub const Attr = struct { name: []const u8, value: []const u8 };

pub const Node = struct {
    name: []const u8,
    attrs: std.ArrayList(Attr) = .empty,
    children: std.ArrayList(*Node) = .empty,
    /// Text directly inside the element (concatenated, entities decoded).
    text: std.ArrayList(u8) = .empty,

    pub fn attr(n: *const Node, name: []const u8) ?[]const u8 {
        for (n.attrs.items) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
        return null;
    }

    /// The first child element called `name`.
    pub fn child(n: *const Node, name: []const u8) ?*Node {
        for (n.children.items) |c| if (std.mem.eql(u8, c.name, name)) return c;
        return null;
    }

    /// The trimmed text of the child `name`, or null.
    pub fn childText(n: *const Node, name: []const u8) ?[]const u8 {
        const c = n.child(name) orelse return null;
        return std.mem.trim(u8, c.text.items, " \t\r\n");
    }

    pub fn setAttr(n: *Node, arena: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        for (n.attrs.items) |*a| if (std.mem.eql(u8, a.name, name)) {
            a.value = value;
            return;
        };
        try n.attrs.append(arena, .{ .name = name, .value = value });
    }
};

pub const Error = error{ BadXml, OutOfMemory };

/// Parses `src` and returns the root element. Everything lives in `arena`.
pub fn parse(arena: std.mem.Allocator, src: []const u8) Error!*Node {
    var p: Parser = .{ .arena = arena, .src = src };
    return p.document();
}

const Parser = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,

    fn document(p: *Parser) Error!*Node {
        while (true) {
            p.skipSpace();
            if (p.startsWith("<?")) {
                try p.skipPast("?>");
            } else if (p.startsWith("<!--")) {
                try p.skipPast("-->");
            } else if (p.startsWith("<!")) {
                try p.skipPast(">");
            } else if (p.startsWith("<")) {
                return p.element();
            } else return error.BadXml;
        }
    }

    fn element(p: *Parser) Error!*Node {
        p.pos += 1; // '<'
        const node = try p.arena.create(Node);
        node.* = .{ .name = p.name() };
        if (node.name.len == 0) return error.BadXml;
        while (true) {
            p.skipSpace();
            if (p.pos >= p.src.len) return error.BadXml;
            if (p.startsWith("/>")) {
                p.pos += 2;
                return node;
            }
            if (p.src[p.pos] == '>') {
                p.pos += 1;
                break;
            }
            const an = p.name();
            if (an.len == 0) return error.BadXml;
            p.skipSpace();
            if (!p.startsWith("=")) return error.BadXml;
            p.pos += 1;
            p.skipSpace();
            if (p.pos >= p.src.len) return error.BadXml;
            const quote = p.src[p.pos];
            if (quote != '"' and quote != '\'') return error.BadXml;
            p.pos += 1;
            const end = std.mem.indexOfScalarPos(u8, p.src, p.pos, quote) orelse return error.BadXml;
            const raw = p.src[p.pos..end];
            p.pos = end + 1;
            var v: std.ArrayList(u8) = .empty;
            try decode(p.arena, raw, &v);
            try node.attrs.append(p.arena, .{ .name = an, .value = v.items });
        }
        // Content.
        while (true) {
            if (p.pos >= p.src.len) return error.BadXml;
            if (p.startsWith("</")) {
                p.pos += 2;
                const close = p.name();
                if (!std.mem.eql(u8, close, node.name)) return error.BadXml;
                try p.skipPast(">");
                return node;
            } else if (p.startsWith("<!--")) {
                try p.skipPast("-->");
            } else if (p.startsWith("<![CDATA[")) {
                p.pos += 9;
                const end = std.mem.indexOfPos(u8, p.src, p.pos, "]]>") orelse return error.BadXml;
                try node.text.appendSlice(p.arena, p.src[p.pos..end]);
                p.pos = end + 3;
            } else if (p.startsWith("<?")) {
                try p.skipPast("?>");
            } else if (p.src[p.pos] == '<') {
                try node.children.append(p.arena, try p.element());
            } else {
                const end = std.mem.indexOfScalarPos(u8, p.src, p.pos, '<') orelse return error.BadXml;
                try decode(p.arena, p.src[p.pos..end], &node.text);
                p.pos = end;
            }
        }
    }

    fn name(p: *Parser) []const u8 {
        const start = p.pos;
        while (p.pos < p.src.len) : (p.pos += 1) {
            switch (p.src[p.pos]) {
                ' ', '\t', '\r', '\n', '>', '/', '=' => break,
                else => {},
            }
        }
        return p.src[start..p.pos];
    }

    fn skipSpace(p: *Parser) void {
        while (p.pos < p.src.len and std.ascii.isWhitespace(p.src[p.pos])) p.pos += 1;
    }

    fn startsWith(p: *Parser, s: []const u8) bool {
        return std.mem.startsWith(u8, p.src[p.pos..], s);
    }

    fn skipPast(p: *Parser, s: []const u8) Error!void {
        const end = std.mem.indexOfPos(u8, p.src, p.pos, s) orelse return error.BadXml;
        p.pos = end + s.len;
    }
};

fn decode(arena: std.mem.Allocator, raw: []const u8, out: *std.ArrayList(u8)) Error!void {
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '&') {
            try out.append(arena, raw[i]);
            i += 1;
            continue;
        }
        const semi = std.mem.indexOfScalarPos(u8, raw, i, ';') orelse return error.BadXml;
        const ent = raw[i + 1 .. semi];
        if (std.mem.eql(u8, ent, "lt")) try out.append(arena, '<') else if (std.mem.eql(u8, ent, "gt")) try out.append(arena, '>') else if (std.mem.eql(u8, ent, "amp")) try out.append(arena, '&') else if (std.mem.eql(u8, ent, "quot")) try out.append(arena, '"') else if (std.mem.eql(u8, ent, "apos")) try out.append(arena, '\'') else if (ent.len > 1 and ent[0] == '#') {
            const cp = (if (ent[1] == 'x') std.fmt.parseInt(u21, ent[2..], 16) else std.fmt.parseInt(u21, ent[1..], 10)) catch return error.BadXml;
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch return error.BadXml;
            try out.appendSlice(arena, buf[0..n]);
        } else return error.BadXml;
        i = semi + 1;
    }
}

fn escape(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
}

/// Writes `n` and its children, indented. Text is written only for elements without children
/// (manifests carry none; this is not a general round trip).
pub fn write(w: *std.Io.Writer, n: *const Node, depth: usize) std.Io.Writer.Error!void {
    try w.splatByteAll(' ', depth * 4);
    try w.print("<{s}", .{n.name});
    for (n.attrs.items) |a| {
        try w.print(" {s}=\"", .{a.name});
        try escape(w, a.value);
        try w.writeByte('"');
    }
    const text = std.mem.trim(u8, n.text.items, " \t\r\n");
    if (n.children.items.len == 0 and text.len == 0) return w.writeAll(" />\n");
    try w.writeByte('>');
    if (n.children.items.len == 0) {
        try escape(w, text);
    } else {
        try w.writeByte('\n');
        for (n.children.items) |c| try write(w, c, depth + 1);
        try w.splatByteAll(' ', depth * 4);
    }
    try w.print("</{s}>\n", .{n.name});
}

test "parse and write" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try parse(arena,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!-- c -->
        \\<project a='1' b="x &amp; y"><dependencies>
        \\  <dependency><groupId>g</groupId><version>[1.2.3]</version></dependency>
        \\  <!-- skipped --><x/>
        \\</dependencies><name><![CDATA[a<b]]> &#65;</name></project>
    );
    try std.testing.expectEqualStrings("project", root.name);
    try std.testing.expectEqualStrings("x & y", root.attr("b").?);
    const dep = root.child("dependencies").?.child("dependency").?;
    try std.testing.expectEqualStrings("[1.2.3]", dep.childText("version").?);
    try std.testing.expectEqual(@as(usize, 2), root.child("dependencies").?.children.items.len);
    try std.testing.expectEqualStrings("a<b A", root.childText("name").?);

    var out: std.Io.Writer.Allocating = .init(arena);
    try write(&out.writer, root.child("dependencies").?.child("x").?, 0);
    try std.testing.expectEqualStrings("<x />\n", out.written());
}
