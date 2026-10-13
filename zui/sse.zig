//! Server-Sent Events: the parser of the text/event-stream format (the HTML standard's
//! "event stream interpretation"), fed with bytes as they arrive. Shared by every host: each
//! only streams the bytes of a GET request.

const std = @import("std");

pub const Event = struct {
    /// "message" unless the server named it (`event:`).
    event: []const u8,
    data: []const u8,
    /// The last id the server gave (`id:`), also for events without one.
    id: []const u8,
};

pub const Parser = struct {
    gpa: std.mem.Allocator,
    /// Bytes of a line not finished yet.
    line: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    event: std.ArrayList(u8) = .empty,
    last_id: std.ArrayList(u8) = .empty,
    /// The reconnection time the server asked for (`retry:`), in milliseconds.
    retry_ms: ?u32 = null,
    /// A '\r' ended the last chunk: a '\n' starting the next one belongs to it.
    after_cr: bool = false,
    /// Before the first line: a byte order mark there is skipped.
    started: bool = false,

    pub fn deinit(p: *Parser) void {
        p.line.deinit(p.gpa);
        p.data.deinit(p.gpa);
        p.event.deinit(p.gpa);
        p.last_id.deinit(p.gpa);
    }

    /// Forgets a half-received event (the connection was lost); the last id and retry stay.
    pub fn reset(p: *Parser) void {
        p.line.clearRetainingCapacity();
        p.data.clearRetainingCapacity();
        p.event.clearRetainingCapacity();
        p.after_cr = false;
        p.started = false;
    }

    /// Feeds bytes; `on(ctx, event)` gets each complete event (its slices live until the next
    /// call). Stops early when `on` returns false.
    pub fn feed(p: *Parser, bytes: []const u8, ctx: anytype, comptime on: fn (@TypeOf(ctx), Event) bool) !void {
        for (bytes) |c| {
            if (p.after_cr) {
                p.after_cr = false;
                if (c == '\n') continue;
            }
            if (c == '\r' or c == '\n') {
                p.after_cr = c == '\r';
                if (try p.endLine()) |e| {
                    if (!on(ctx, e)) return;
                }
                continue;
            }
            try p.line.append(p.gpa, c);
        }
    }

    /// Handles the finished line; an empty line completes an event.
    fn endLine(p: *Parser) !?Event {
        defer p.line.clearRetainingCapacity();
        var line = p.line.items;
        if (!p.started) {
            p.started = true;
            if (std.mem.startsWith(u8, line, "\xEF\xBB\xBF")) line = line[3..];
        }
        if (line.len == 0) {
            if (p.data.items.len == 0) {
                p.event.clearRetainingCapacity();
                return null;
            }
            // The data without its last newline; the event is dispatched, then forgotten.
            const data = p.data.items[0 .. p.data.items.len - 1];
            const e: Event = .{ .event = if (p.event.items.len > 0) p.event.items else "message", .data = data, .id = p.last_id.items };
            p.data.items.len = 0;
            p.event.items.len = 0;
            return e;
        }
        if (line[0] == ':') return null;
        const colon = std.mem.indexOfScalar(u8, line, ':');
        const field = if (colon) |c| line[0..c] else line;
        var value: []const u8 = if (colon) |c| line[c + 1 ..] else "";
        if (value.len > 0 and value[0] == ' ') value = value[1..];
        if (std.mem.eql(u8, field, "data")) {
            try p.data.appendSlice(p.gpa, value);
            try p.data.append(p.gpa, '\n');
        } else if (std.mem.eql(u8, field, "event")) {
            p.event.clearRetainingCapacity();
            try p.event.appendSlice(p.gpa, value);
        } else if (std.mem.eql(u8, field, "id")) {
            if (std.mem.indexOfScalar(u8, value, 0) == null) {
                p.last_id.clearRetainingCapacity();
                try p.last_id.appendSlice(p.gpa, value);
            }
        } else if (std.mem.eql(u8, field, "retry")) {
            if (value.len > 0) p.retry_ms = std.fmt.parseInt(u32, value, 10) catch p.retry_ms;
        }
        return null;
    }
};

const testing = std.testing;

const Collect = struct {
    out: std.ArrayList(u8) = .empty,

    fn on(c: *Collect, e: Event) bool {
        c.out.print(testing.allocator, "[{s}|{s}|{s}]", .{ e.event, e.data, e.id }) catch {};
        return true;
    }
};

test "events, fields, comments, line endings and chunks split anywhere" {
    const stream = "\xEF\xBB\xBF: hello\r\nretry: 1500\nid: 1\nevent: tick\ndata: {\"n\":1}\ndata:two\n\ndata: plain\r\rdata\n\nid\ndata: x\n\ndata: unfinished";
    // Fed whole, then one byte at a time: the same events.
    for ([_]usize{ stream.len, 1, 7 }) |step| {
        var p: Parser = .{ .gpa = testing.allocator };
        defer p.deinit();
        var c: Collect = .{};
        defer c.out.deinit(testing.allocator);
        var i: usize = 0;
        while (i < stream.len) : (i += step) try p.feed(stream[i..@min(stream.len, i + step)], &c, Collect.on);
        try testing.expectEqualStrings("[tick|{\"n\":1}\ntwo|1][message|plain|1][message||1][message|x|]", c.out.items);
        try testing.expectEqual(@as(?u32, 1500), p.retry_ms);
    }
}
