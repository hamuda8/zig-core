//! HPACK (RFC 7541), the header compression of HTTP/2.
//!
//! Encoding is deliberately simple: exact static-table matches are indexed, everything else is a
//! literal that is never added to the dynamic table, so the peer's table never needs tracking.
//! Strings are Huffman-coded when that is shorter. Decoding is complete: static and dynamic
//! tables, table size updates, and Huffman strings.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Error = error{ CompressionError, OutOfMemory };

/// Appendix A.
pub const static_table = [61]Header{
    .{ .name = ":authority", .value = "" },
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":method", .value = "POST" },
    .{ .name = ":path", .value = "/" },
    .{ .name = ":path", .value = "/index.html" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":status", .value = "200" },
    .{ .name = ":status", .value = "204" },
    .{ .name = ":status", .value = "206" },
    .{ .name = ":status", .value = "304" },
    .{ .name = ":status", .value = "400" },
    .{ .name = ":status", .value = "404" },
    .{ .name = ":status", .value = "500" },
    .{ .name = "accept-charset", .value = "" },
    .{ .name = "accept-encoding", .value = "gzip, deflate" },
    .{ .name = "accept-language", .value = "" },
    .{ .name = "accept-ranges", .value = "" },
    .{ .name = "accept", .value = "" },
    .{ .name = "access-control-allow-origin", .value = "" },
    .{ .name = "age", .value = "" },
    .{ .name = "allow", .value = "" },
    .{ .name = "authorization", .value = "" },
    .{ .name = "cache-control", .value = "" },
    .{ .name = "content-disposition", .value = "" },
    .{ .name = "content-encoding", .value = "" },
    .{ .name = "content-language", .value = "" },
    .{ .name = "content-length", .value = "" },
    .{ .name = "content-location", .value = "" },
    .{ .name = "content-range", .value = "" },
    .{ .name = "content-type", .value = "" },
    .{ .name = "cookie", .value = "" },
    .{ .name = "date", .value = "" },
    .{ .name = "etag", .value = "" },
    .{ .name = "expect", .value = "" },
    .{ .name = "expires", .value = "" },
    .{ .name = "from", .value = "" },
    .{ .name = "host", .value = "" },
    .{ .name = "if-match", .value = "" },
    .{ .name = "if-modified-since", .value = "" },
    .{ .name = "if-none-match", .value = "" },
    .{ .name = "if-range", .value = "" },
    .{ .name = "if-unmodified-since", .value = "" },
    .{ .name = "last-modified", .value = "" },
    .{ .name = "link", .value = "" },
    .{ .name = "location", .value = "" },
    .{ .name = "max-forwards", .value = "" },
    .{ .name = "proxy-authenticate", .value = "" },
    .{ .name = "proxy-authorization", .value = "" },
    .{ .name = "range", .value = "" },
    .{ .name = "referer", .value = "" },
    .{ .name = "refresh", .value = "" },
    .{ .name = "retry-after", .value = "" },
    .{ .name = "server", .value = "" },
    .{ .name = "set-cookie", .value = "" },
    .{ .name = "strict-transport-security", .value = "" },
    .{ .name = "transfer-encoding", .value = "" },
    .{ .name = "user-agent", .value = "" },
    .{ .name = "vary", .value = "" },
    .{ .name = "via", .value = "" },
    .{ .name = "www-authenticate", .value = "" },
};

// ---- Integers (5.1) ------------------------------------------------------------------------

/// Writes `value` with an N-bit prefix; `first` carries the representation's flag bits above it.
pub fn writeInt(w: *Writer, first: u8, comptime prefix_bits: u4, value: u64) Writer.Error!void {
    const max: u8 = (1 << prefix_bits) - 1;
    if (value < max) return w.writeByte(first | @as(u8, @intCast(value)));
    try w.writeByte(first | max);
    var rest = value - max;
    while (rest >= 128) : (rest >>= 7) try w.writeByte(@as(u8, @truncate(rest)) | 0x80);
    try w.writeByte(@intCast(rest));
}

/// Reads an N-bit-prefix integer at `pos.*`, advancing it.
pub fn readInt(buf: []const u8, pos: *usize, comptime prefix_bits: u4) error{CompressionError}!u64 {
    if (pos.* >= buf.len) return error.CompressionError;
    const max: u8 = (1 << prefix_bits) - 1;
    const first = buf[pos.*] & max;
    pos.* += 1;
    if (first < max) return first;
    var value: u64 = max;
    var shift: u6 = 0;
    while (true) {
        if (pos.* >= buf.len) return error.CompressionError;
        const b = buf[pos.*];
        pos.* += 1;
        // Seven bits at a time; anything past 2^56 is not a sane length or index.
        if (shift > 49) return error.CompressionError;
        value += @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) return value;
        shift += 7;
    }
}

// ---- Huffman code (5.2, Appendix B) --------------------------------------------------------

/// Code (aligned to the least significant bit) and bit length per symbol; 256 is EOS.
const huffman_codes = [257]struct { u32, u5 }{
    .{ 0x1ff8, 13 },     .{ 0x7fffd8, 23 },   .{ 0xfffffe2, 28 },  .{ 0xfffffe3, 28 },
    .{ 0xfffffe4, 28 },  .{ 0xfffffe5, 28 },  .{ 0xfffffe6, 28 },  .{ 0xfffffe7, 28 },
    .{ 0xfffffe8, 28 },  .{ 0xffffea, 24 },   .{ 0x3ffffffc, 30 }, .{ 0xfffffe9, 28 },
    .{ 0xfffffea, 28 },  .{ 0x3ffffffd, 30 }, .{ 0xfffffeb, 28 },  .{ 0xfffffec, 28 },
    .{ 0xfffffed, 28 },  .{ 0xfffffee, 28 },  .{ 0xfffffef, 28 },  .{ 0xffffff0, 28 },
    .{ 0xffffff1, 28 },  .{ 0xffffff2, 28 },  .{ 0x3ffffffe, 30 }, .{ 0xffffff3, 28 },
    .{ 0xffffff4, 28 },  .{ 0xffffff5, 28 },  .{ 0xffffff6, 28 },  .{ 0xffffff7, 28 },
    .{ 0xffffff8, 28 },  .{ 0xffffff9, 28 },  .{ 0xffffffa, 28 },  .{ 0xffffffb, 28 },
    .{ 0x14, 6 },        .{ 0x3f8, 10 },      .{ 0x3f9, 10 },      .{ 0xffa, 12 },
    .{ 0x1ff9, 13 },     .{ 0x15, 6 },        .{ 0xf8, 8 },        .{ 0x7fa, 11 },
    .{ 0x3fa, 10 },      .{ 0x3fb, 10 },      .{ 0xf9, 8 },        .{ 0x7fb, 11 },
    .{ 0xfa, 8 },        .{ 0x16, 6 },        .{ 0x17, 6 },        .{ 0x18, 6 },
    .{ 0x0, 5 },         .{ 0x1, 5 },         .{ 0x2, 5 },         .{ 0x19, 6 },
    .{ 0x1a, 6 },        .{ 0x1b, 6 },        .{ 0x1c, 6 },        .{ 0x1d, 6 },
    .{ 0x1e, 6 },        .{ 0x1f, 6 },        .{ 0x5c, 7 },        .{ 0xfb, 8 },
    .{ 0x7ffc, 15 },     .{ 0x20, 6 },        .{ 0xffb, 12 },      .{ 0x3fc, 10 },
    .{ 0x1ffa, 13 },     .{ 0x21, 6 },        .{ 0x5d, 7 },        .{ 0x5e, 7 },
    .{ 0x5f, 7 },        .{ 0x60, 7 },        .{ 0x61, 7 },        .{ 0x62, 7 },
    .{ 0x63, 7 },        .{ 0x64, 7 },        .{ 0x65, 7 },        .{ 0x66, 7 },
    .{ 0x67, 7 },        .{ 0x68, 7 },        .{ 0x69, 7 },        .{ 0x6a, 7 },
    .{ 0x6b, 7 },        .{ 0x6c, 7 },        .{ 0x6d, 7 },        .{ 0x6e, 7 },
    .{ 0x6f, 7 },        .{ 0x70, 7 },        .{ 0x71, 7 },        .{ 0x72, 7 },
    .{ 0xfc, 8 },        .{ 0x73, 7 },        .{ 0xfd, 8 },        .{ 0x1ffb, 13 },
    .{ 0x7fff0, 19 },    .{ 0x1ffc, 13 },     .{ 0x3ffc, 14 },     .{ 0x22, 6 },
    .{ 0x7ffd, 15 },     .{ 0x3, 5 },         .{ 0x23, 6 },        .{ 0x4, 5 },
    .{ 0x24, 6 },        .{ 0x5, 5 },         .{ 0x25, 6 },        .{ 0x26, 6 },
    .{ 0x27, 6 },        .{ 0x6, 5 },         .{ 0x74, 7 },        .{ 0x75, 7 },
    .{ 0x28, 6 },        .{ 0x29, 6 },        .{ 0x2a, 6 },        .{ 0x7, 5 },
    .{ 0x2b, 6 },        .{ 0x76, 7 },        .{ 0x2c, 6 },        .{ 0x8, 5 },
    .{ 0x9, 5 },         .{ 0x2d, 6 },        .{ 0x77, 7 },        .{ 0x78, 7 },
    .{ 0x79, 7 },        .{ 0x7a, 7 },        .{ 0x7b, 7 },        .{ 0x7ffe, 15 },
    .{ 0x7fc, 11 },      .{ 0x3ffd, 14 },     .{ 0x1ffd, 13 },     .{ 0xffffffc, 28 },
    .{ 0xfffe6, 20 },    .{ 0x3fffd2, 22 },   .{ 0xfffe7, 20 },    .{ 0xfffe8, 20 },
    .{ 0x3fffd3, 22 },   .{ 0x3fffd4, 22 },   .{ 0x3fffd5, 22 },   .{ 0x7fffd9, 23 },
    .{ 0x3fffd6, 22 },   .{ 0x7fffda, 23 },   .{ 0x7fffdb, 23 },   .{ 0x7fffdc, 23 },
    .{ 0x7fffdd, 23 },   .{ 0x7fffde, 23 },   .{ 0xffffeb, 24 },   .{ 0x7fffdf, 23 },
    .{ 0xffffec, 24 },   .{ 0xffffed, 24 },   .{ 0x3fffd7, 22 },   .{ 0x7fffe0, 23 },
    .{ 0xffffee, 24 },   .{ 0x7fffe1, 23 },   .{ 0x7fffe2, 23 },   .{ 0x7fffe3, 23 },
    .{ 0x7fffe4, 23 },   .{ 0x1fffdc, 21 },   .{ 0x3fffd8, 22 },   .{ 0x7fffe5, 23 },
    .{ 0x3fffd9, 22 },   .{ 0x7fffe6, 23 },   .{ 0x7fffe7, 23 },   .{ 0xffffef, 24 },
    .{ 0x3fffda, 22 },   .{ 0x1fffdd, 21 },   .{ 0xfffe9, 20 },    .{ 0x3fffdb, 22 },
    .{ 0x3fffdc, 22 },   .{ 0x7fffe8, 23 },   .{ 0x7fffe9, 23 },   .{ 0x1fffde, 21 },
    .{ 0x7fffea, 23 },   .{ 0x3fffdd, 22 },   .{ 0x3fffde, 22 },   .{ 0xfffff0, 24 },
    .{ 0x1fffdf, 21 },   .{ 0x3fffdf, 22 },   .{ 0x7fffeb, 23 },   .{ 0x7fffec, 23 },
    .{ 0x1fffe0, 21 },   .{ 0x1fffe1, 21 },   .{ 0x3fffe0, 22 },   .{ 0x1fffe2, 21 },
    .{ 0x7fffed, 23 },   .{ 0x3fffe1, 22 },   .{ 0x7fffee, 23 },   .{ 0x7fffef, 23 },
    .{ 0xfffea, 20 },    .{ 0x3fffe2, 22 },   .{ 0x3fffe3, 22 },   .{ 0x3fffe4, 22 },
    .{ 0x7ffff0, 23 },   .{ 0x3fffe5, 22 },   .{ 0x3fffe6, 22 },   .{ 0x7ffff1, 23 },
    .{ 0x3ffffe0, 26 },  .{ 0x3ffffe1, 26 },  .{ 0xfffeb, 20 },    .{ 0x7fff1, 19 },
    .{ 0x3fffe7, 22 },   .{ 0x7ffff2, 23 },   .{ 0x3fffe8, 22 },   .{ 0x1ffffec, 25 },
    .{ 0x3ffffe2, 26 },  .{ 0x3ffffe3, 26 },  .{ 0x3ffffe4, 26 },  .{ 0x7ffffde, 27 },
    .{ 0x7ffffdf, 27 },  .{ 0x3ffffe5, 26 },  .{ 0xfffff1, 24 },   .{ 0x1ffffed, 25 },
    .{ 0x7fff2, 19 },    .{ 0x1fffe3, 21 },   .{ 0x3ffffe6, 26 },  .{ 0x7ffffe0, 27 },
    .{ 0x7ffffe1, 27 },  .{ 0x3ffffe7, 26 },  .{ 0x7ffffe2, 27 },  .{ 0xfffff2, 24 },
    .{ 0x1fffe4, 21 },   .{ 0x1fffe5, 21 },   .{ 0x3ffffe8, 26 },  .{ 0x3ffffe9, 26 },
    .{ 0xffffffd, 28 },  .{ 0x7ffffe3, 27 },  .{ 0x7ffffe4, 27 },  .{ 0x7ffffe5, 27 },
    .{ 0xfffec, 20 },    .{ 0xfffff3, 24 },   .{ 0xfffed, 20 },    .{ 0x1fffe6, 21 },
    .{ 0x3fffe9, 22 },   .{ 0x1fffe7, 21 },   .{ 0x1fffe8, 21 },   .{ 0x7ffff3, 23 },
    .{ 0x3fffea, 22 },   .{ 0x3fffeb, 22 },   .{ 0x1ffffee, 25 },  .{ 0x1ffffef, 25 },
    .{ 0xfffff4, 24 },   .{ 0xfffff5, 24 },   .{ 0x3ffffea, 26 },  .{ 0x7ffff4, 23 },
    .{ 0x3ffffeb, 26 },  .{ 0x7ffffe6, 27 },  .{ 0x3ffffec, 26 },  .{ 0x3ffffed, 26 },
    .{ 0x7ffffe7, 27 },  .{ 0x7ffffe8, 27 },  .{ 0x7ffffe9, 27 },  .{ 0x7ffffea, 27 },
    .{ 0x7ffffeb, 27 },  .{ 0xffffffe, 28 },  .{ 0x7ffffec, 27 },  .{ 0x7ffffed, 27 },
    .{ 0x7ffffee, 27 },  .{ 0x7ffffef, 27 },  .{ 0x7fffff0, 27 },  .{ 0x3ffffee, 26 },
    .{ 0x3fffffff, 30 },
};

/// The code as a binary tree: entry [node][bit] is another node, or a symbol when 0x8000 is set.
const huffman_tree = tree: {
    @setEvalBranchQuota(200_000);
    var nodes: [256][2]u16 = @splat(.{ 0, 0 });
    var count: u16 = 1;
    for (huffman_codes, 0..) |c, sym| {
        const code, const len = c;
        var node: u16 = 0;
        var i: u5 = len - 1;
        while (i > 0) : (i -= 1) {
            const bit = (code >> i) & 1;
            if (nodes[node][bit] == 0) {
                nodes[node][bit] = count;
                count += 1;
            }
            node = nodes[node][bit];
        }
        nodes[node][code & 1] = 0x8000 | sym;
    }
    break :tree nodes;
};

pub fn huffmanLen(s: []const u8) usize {
    var bits: usize = 0;
    for (s) |c| bits += huffman_codes[c][1];
    return (bits + 7) / 8;
}

pub fn huffmanEncode(w: *Writer, s: []const u8) Writer.Error!void {
    var acc: u64 = 0;
    var n: u6 = 0;
    for (s) |c| {
        const code, const len = huffman_codes[c];
        acc = (acc << len) | code;
        n += len;
        while (n >= 8) {
            n -= 8;
            try w.writeByte(@truncate(acc >> n));
        }
    }
    // Pad with the most significant bits of EOS (all ones).
    if (n > 0) try w.writeByte(@truncate((acc << (8 - n)) | (@as(u64, 0xff) >> n)));
}

/// Appends the decoded string to `out`. Rejects EOS in the data, padding longer than 7 bits and
/// padding that is not the prefix of EOS (5.2).
pub fn huffmanDecode(gpa: Allocator, src: []const u8, out: *std.ArrayList(u8)) Error!void {
    var node: u16 = 0;
    var depth: u8 = 0; // bits read since the last symbol
    var ones = true; // were they all ones
    for (src) |byte| {
        var i: u4 = 8;
        while (i > 0) {
            i -= 1;
            const bit: u1 = @truncate(byte >> @intCast(i));
            depth += 1;
            if (bit == 0) ones = false;
            const next = huffman_tree[node][bit];
            if (next & 0x8000 != 0) {
                const sym = next & 0x7fff;
                if (sym == 256) return error.CompressionError;
                try out.append(gpa, @intCast(sym));
                node = 0;
                depth = 0;
                ones = true;
            } else node = next;
        }
    }
    if (depth > 7 or !ones) return error.CompressionError;
}

// ---- Strings (5.2) -------------------------------------------------------------------------

pub fn writeString(w: *Writer, s: []const u8) Writer.Error!void {
    const h = huffmanLen(s);
    if (h < s.len) {
        try writeInt(w, 0x80, 7, h);
        try huffmanEncode(w, s);
    } else {
        try writeInt(w, 0, 7, s.len);
        try w.writeAll(s);
    }
}

fn readString(arena: Allocator, buf: []const u8, pos: *usize) Error![]const u8 {
    if (pos.* >= buf.len) return error.CompressionError;
    const huffman = buf[pos.*] & 0x80 != 0;
    const len = try readInt(buf, pos, 7);
    if (len > buf.len - pos.*) return error.CompressionError;
    const raw = buf[pos.*..][0..@intCast(len)];
    pos.* += raw.len;
    if (!huffman) return arena.dupe(u8, raw);
    var out: std.ArrayList(u8) = try .initCapacity(arena, raw.len * 8 / 5 + 1);
    try huffmanDecode(arena, raw, &out);
    return out.items;
}

// ---- Encoder -------------------------------------------------------------------------------

/// Header names that are sent "never indexed" (6.2.3), so no intermediary caches them.
const sensitive = [_][]const u8{ "authorization", "proxy-authorization", "cookie", "set-cookie" };

pub const Encoder = struct {
    /// Set when the peer's SETTINGS_HEADER_TABLE_SIZE changes (and at the start): the next block
    /// begins with a size update to 0, which is always allowed and matches our empty table.
    size_update: bool = true,

    /// Appends the header block for `headers`. Names must be lowercase (HTTP/2 requires it).
    pub fn encode(e: *Encoder, w: *Writer, headers: []const Header) Writer.Error!void {
        if (e.size_update) {
            try writeInt(w, 0x20, 5, 0);
            e.size_update = false;
        }
        for (headers) |h| {
            var exact: usize = 0;
            var name_index: usize = 0;
            for (static_table, 1..) |s, i| {
                if (!std.mem.eql(u8, s.name, h.name)) continue;
                if (std.mem.eql(u8, s.value, h.value)) {
                    exact = i;
                    break;
                }
                if (name_index == 0) name_index = i;
            }
            if (exact != 0) {
                // Indexed field (1xxxxxxx).
                try writeInt(w, 0x80, 7, exact);
                continue;
            }
            // Literal without indexing (0000) or never indexed (0001), 4-bit name index.
            const never = for (sensitive) |s| {
                if (std.mem.eql(u8, s, h.name)) break true;
            } else false;
            const flag: u8 = if (never) 0x10 else 0x00;
            if (name_index != 0) {
                try writeInt(w, flag, 4, name_index);
            } else {
                try w.writeByte(flag);
                try writeString(w, h.name);
            }
            try writeString(w, h.value);
        }
    }
};

// ---- Decoder -------------------------------------------------------------------------------

pub const Decoder = struct {
    gpa: Allocator,
    /// Oldest first; the newest entry is index 62.
    entries: std.ArrayList(Entry) = .empty,
    /// Sum of entry sizes (name + value + 32 each).
    size: usize = 0,
    /// Current maximum, changed by size updates in the blocks.
    max_size: usize,
    /// What we advertised in SETTINGS_HEADER_TABLE_SIZE: size updates may not exceed it.
    limit: usize,

    const Entry = struct { bytes: []u8, name_len: usize };

    pub fn init(gpa: Allocator, limit: usize) Decoder {
        return .{ .gpa = gpa, .max_size = limit, .limit = limit };
    }

    pub fn deinit(d: *Decoder) void {
        for (d.entries.items) |e| d.gpa.free(e.bytes);
        d.entries.deinit(d.gpa);
    }

    fn get(d: *const Decoder, index: u64) Error!Header {
        if (index == 0) return error.CompressionError;
        if (index <= static_table.len) return static_table[@intCast(index - 1)];
        const dyn = index - static_table.len - 1;
        if (dyn >= d.entries.items.len) return error.CompressionError;
        const e = d.entries.items[d.entries.items.len - 1 - @as(usize, @intCast(dyn))];
        return .{ .name = e.bytes[0..e.name_len], .value = e.bytes[e.name_len..] };
    }

    fn evictTo(d: *Decoder, max: usize) void {
        var n: usize = 0;
        while (d.size > max) : (n += 1) {
            const e = d.entries.items[n];
            d.size -= e.bytes.len + 32;
            d.gpa.free(e.bytes);
        }
        const items = d.entries.items;
        std.mem.copyForwards(Entry, items[0 .. items.len - n], items[n..]);
        d.entries.shrinkRetainingCapacity(items.len - n);
    }

    fn add(d: *Decoder, h: Header) Error!void {
        const size = h.name.len + h.value.len + 32;
        if (size > d.max_size) {
            // Too big for the table: it just empties it (4.4).
            d.evictTo(0);
            return;
        }
        // Copy first: `h` may point into an entry that is about to be evicted.
        const bytes = try d.gpa.alloc(u8, h.name.len + h.value.len);
        errdefer d.gpa.free(bytes);
        @memcpy(bytes[0..h.name.len], h.name);
        @memcpy(bytes[h.name.len..], h.value);
        try d.entries.ensureUnusedCapacity(d.gpa, 1);
        d.evictTo(d.max_size - size);
        d.entries.appendAssumeCapacity(.{ .bytes = bytes, .name_len = h.name.len });
        d.size += size;
    }

    /// Decodes one complete header block, appending the fields to `out`. Names and values are
    /// allocated with `arena`. Any error leaves the connection unusable (COMPRESSION_ERROR).
    pub fn decode(d: *Decoder, arena: Allocator, block: []const u8, out: *std.ArrayList(Header)) Error!void {
        var pos: usize = 0;
        var fields: usize = 0;
        while (pos < block.len) {
            const b = block[pos];
            if (b & 0x80 != 0) {
                // Indexed field (6.1).
                const h = try d.get(try readInt(block, &pos, 7));
                try out.append(arena, .{ .name = try arena.dupe(u8, h.name), .value = try arena.dupe(u8, h.value) });
            } else if (b & 0xe0 == 0x20) {
                // Dynamic table size update (6.3): only before the first field.
                if (fields > 0) return error.CompressionError;
                const max = try readInt(block, &pos, 5);
                if (max > d.limit) return error.CompressionError;
                d.max_size = @intCast(max);
                d.evictTo(d.max_size);
                continue;
            } else {
                // Literal: with incremental indexing (01, 6-bit index), without indexing (0000)
                // or never indexed (0001), both 4-bit.
                const indexing = b & 0xc0 == 0x40;
                const index = if (indexing) try readInt(block, &pos, 6) else try readInt(block, &pos, 4);
                const name = if (index == 0)
                    try readString(arena, block, &pos)
                else
                    try arena.dupe(u8, (try d.get(index)).name);
                const value = try readString(arena, block, &pos);
                try out.append(arena, .{ .name = name, .value = value });
                if (indexing) try d.add(.{ .name = name, .value = value });
            }
            fields += 1;
        }
    }
};

// ---- Tests ---------------------------------------------------------------------------------

const testing = std.testing;

test "integers (C.1)" {
    var buf: [16]u8 = undefined;
    inline for (.{ .{ 10, 5, "\x0a" }, .{ 1337, 5, "\x1f\x9a\x0a" }, .{ 42, 8, "\x2a" } }) |c| {
        var w: Writer = .fixed(&buf);
        try writeInt(&w, 0, c[1], c[0]);
        try testing.expectEqualSlices(u8, c[2], w.buffered());
        var pos: usize = 0;
        try testing.expectEqual(@as(u64, c[0]), try readInt(w.buffered(), &pos, c[1]));
        try testing.expectEqual(w.buffered().len, pos);
    }
    var pos: usize = 0;
    try testing.expectError(error.CompressionError, readInt("\x1f\x9a", &pos, 5));
    pos = 0;
    try testing.expectError(error.CompressionError, readInt("\x1f\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01", &pos, 5));
}

const Vector = struct { id: []const u8, hex: []const u8, size: usize, headers: []const [2][]const u8 };

/// Appendix C.2 to C.6. Each group of three shares one decoder (one connection).
const vectors = [_]Vector{
    .{ .id = "C.2.1", .hex = "400a637573746f6d2d6b65790d637573746f6d2d686561646572", .size = 55, .headers = &.{
        .{ "custom-key", "custom-header" },
    } },
    .{ .id = "C.2.2", .hex = "040c2f73616d706c652f70617468", .size = 0, .headers = &.{
        .{ ":path", "/sample/path" },
    } },
    .{ .id = "C.2.3", .hex = "100870617373776f726406736563726574", .size = 0, .headers = &.{
        .{ "password", "secret" },
    } },
    .{ .id = "C.2.4", .hex = "82", .size = 0, .headers = &.{
        .{ ":method", "GET" },
    } },
    .{ .id = "C.3.1", .hex = "828684410f7777772e6578616d706c652e636f6d", .size = 57, .headers = &.{
        .{ ":method", "GET" },
        .{ ":scheme", "http" },
        .{ ":path", "/" },
        .{ ":authority", "www.example.com" },
    } },
    .{ .id = "C.3.2", .hex = "828684be58086e6f2d6361636865", .size = 110, .headers = &.{
        .{ ":method", "GET" },
        .{ ":scheme", "http" },
        .{ ":path", "/" },
        .{ ":authority", "www.example.com" },
        .{ "cache-control", "no-cache" },
    } },
    .{ .id = "C.3.3", .hex = "828785bf400a637573746f6d2d6b65790c637573746f6d2d76616c7565", .size = 164, .headers = &.{
        .{ ":method", "GET" },
        .{ ":scheme", "https" },
        .{ ":path", "/index.html" },
        .{ ":authority", "www.example.com" },
        .{ "custom-key", "custom-value" },
    } },
    .{ .id = "C.4.1", .hex = "828684418cf1e3c2e5f23a6ba0ab90f4ff", .size = 57, .headers = &.{
        .{ ":method", "GET" },
        .{ ":scheme", "http" },
        .{ ":path", "/" },
        .{ ":authority", "www.example.com" },
    } },
    .{ .id = "C.4.2", .hex = "828684be5886a8eb10649cbf", .size = 110, .headers = &.{
        .{ ":method", "GET" },
        .{ ":scheme", "http" },
        .{ ":path", "/" },
        .{ ":authority", "www.example.com" },
        .{ "cache-control", "no-cache" },
    } },
    .{ .id = "C.4.3", .hex = "828785bf408825a849e95ba97d7f8925a849e95bb8e8b4bf", .size = 164, .headers = &.{
        .{ ":method", "GET" },
        .{ ":scheme", "https" },
        .{ ":path", "/index.html" },
        .{ ":authority", "www.example.com" },
        .{ "custom-key", "custom-value" },
    } },
    .{ .id = "C.5.1", .hex = "4803333032580770726976617465611d4d6f6e2c203231204f637420323031332032303a31333a323120474d546e1768747470733a2f2f7777772e6578616d706c652e636f6d", .size = 222, .headers = &.{
        .{ ":status", "302" },
        .{ "cache-control", "private" },
        .{ "date", "Mon, 21 Oct 2013 20:13:21 GMT" },
        .{ "location", "https://www.example.com" },
    } },
    .{ .id = "C.5.2", .hex = "4803333037c1c0bf", .size = 222, .headers = &.{
        .{ ":status", "307" },
        .{ "cache-control", "private" },
        .{ "date", "Mon, 21 Oct 2013 20:13:21 GMT" },
        .{ "location", "https://www.example.com" },
    } },
    .{ .id = "C.5.3", .hex = "88c1611d4d6f6e2c203231204f637420323031332032303a31333a323220474d54c05a04677a69707738666f6f3d4153444a4b48514b425a584f5157454f50495541585157454f49553b206d61782d6167653d333630303b2076657273696f6e3d31", .size = 215, .headers = &.{
        .{ ":status", "200" },
        .{ "cache-control", "private" },
        .{ "date", "Mon, 21 Oct 2013 20:13:22 GMT" },
        .{ "location", "https://www.example.com" },
        .{ "content-encoding", "gzip" },
        .{ "set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1" },
    } },
    .{ .id = "C.6.1", .hex = "488264025885aec3771a4b6196d07abe941054d444a8200595040b8166e082a62d1bff6e919d29ad171863c78f0b97c8e9ae82ae43d3", .size = 222, .headers = &.{
        .{ ":status", "302" },
        .{ "cache-control", "private" },
        .{ "date", "Mon, 21 Oct 2013 20:13:21 GMT" },
        .{ "location", "https://www.example.com" },
    } },
    .{ .id = "C.6.2", .hex = "4883640effc1c0bf", .size = 222, .headers = &.{
        .{ ":status", "307" },
        .{ "cache-control", "private" },
        .{ "date", "Mon, 21 Oct 2013 20:13:21 GMT" },
        .{ "location", "https://www.example.com" },
    } },
    .{ .id = "C.6.3", .hex = "88c16196d07abe941054d444a8200595040b8166e084a62d1bffc05a839bd9ab77ad94e7821dd7f2e6c7b335dfdfcd5b3960d5af27087f3672c1ab270fb5291f9587316065c003ed4ee5b1063d5007", .size = 215, .headers = &.{
        .{ ":status", "200" },
        .{ "cache-control", "private" },
        .{ "date", "Mon, 21 Oct 2013 20:13:22 GMT" },
        .{ "location", "https://www.example.com" },
        .{ "content-encoding", "gzip" },
        .{ "set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1" },
    } },
};

fn checkVector(d: *Decoder, v: Vector) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const block = try a.alloc(u8, v.hex.len / 2);
    _ = try std.fmt.hexToBytes(block, v.hex);
    var out: std.ArrayList(Header) = .empty;
    try d.decode(a, block, &out);
    errdefer std.debug.print("vector {s}\n", .{v.id});
    try testing.expectEqual(v.headers.len, out.items.len);
    for (v.headers, out.items) |want, got| {
        try testing.expectEqualStrings(want[0], got.name);
        try testing.expectEqualStrings(want[1], got.value);
    }
    try testing.expectEqual(v.size, d.size);
}

test "RFC 7541 Appendix C decoding" {
    // C.2.x are independent; C.3 to C.6 are three blocks each on one connection. The response
    // examples run with a 256-byte table, so they evict.
    var i: usize = 0;
    while (i < vectors.len) {
        const v = vectors[i];
        const group = std.mem.startsWith(u8, v.id, "C.2") == false;
        const limit: usize = if (std.mem.startsWith(u8, v.id, "C.5") or std.mem.startsWith(u8, v.id, "C.6")) 256 else 4096;
        var d = Decoder.init(testing.allocator, limit);
        defer d.deinit();
        const n: usize = if (group) 3 else 1;
        for (vectors[i..][0..n]) |vv| try checkVector(&d, vv);
        i += n;
    }
}

test "Huffman strings from Appendix C encode to the same bytes" {
    const cases = [_][2][]const u8{
        .{ "www.example.com", "f1e3c2e5f23a6ba0ab90f4ff" },
        .{ "no-cache", "a8eb10649cbf" },
        .{ "custom-key", "25a849e95ba97d7f" },
        .{ "custom-value", "25a849e95bb8e8b4bf" },
        .{ "302", "6402" },
        .{ "Mon, 21 Oct 2013 20:13:21 GMT", "d07abe941054d444a8200595040b8166e082a62d1bff" },
        .{ "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1", "94e7821dd7f2e6c7b335dfdfcd5b3960d5af27087f3672c1ab270fb5291f9587316065c003ed4ee5b1063d5007" },
    };
    for (cases) |c| {
        var buf: [128]u8 = undefined;
        var w: Writer = .fixed(&buf);
        try huffmanEncode(&w, c[0]);
        var want: [64]u8 = undefined;
        try testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&want, c[1]), w.buffered());
        try testing.expectEqual(w.buffered().len, huffmanLen(c[0]));
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try huffmanDecode(testing.allocator, w.buffered(), &out);
        try testing.expectEqualStrings(c[0], out.items);
    }
}

test "Huffman round trip over every byte, and bad padding" {
    var all: [256]u8 = undefined;
    for (&all, 0..) |*b, i| b.* = @intCast(i);
    var buf: [1024]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try huffmanEncode(&w, &all);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try huffmanDecode(testing.allocator, w.buffered(), &out);
    try testing.expectEqualSlices(u8, &all, out.items);
    out.clearRetainingCapacity();
    // "0" is 00000 (5 bits): zero padding is not EOS's prefix.
    try testing.expectError(error.CompressionError, huffmanDecode(testing.allocator, "\x00", &out));
    // A whole byte of ones is padding longer than 7 bits.
    try testing.expectError(error.CompressionError, huffmanDecode(testing.allocator, "\x07\xff", &out));
    // EOS itself (30 ones) must not appear.
    try testing.expectError(error.CompressionError, huffmanDecode(testing.allocator, "\xff\xff\xff\xff", &out));
}

test "encoder output decodes back; sensitive names are never indexed" {
    var e: Encoder = .{};
    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const headers = [_]Header{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/3/device/abcdef" },
        .{ .name = ":authority", .value = "api.push.apple.com" },
        .{ .name = "authorization", .value = "bearer eyJ.x.y" },
        .{ .name = "apns-topic", .value = "com.wufour.reseal" },
    };
    try e.encode(&w, &headers);
    const block = w.buffered();
    try testing.expectEqual(@as(u8, 0x20), block[0]); // size update to 0 first
    try testing.expectEqual(@as(u8, 0x83), block[1]); // :method POST is static index 3
    var d = Decoder.init(testing.allocator, 4096);
    defer d.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(Header) = .empty;
    try d.decode(arena.allocator(), block, &out);
    try testing.expectEqual(headers.len, out.items.len);
    for (headers, out.items) |want, got| {
        try testing.expectEqualStrings(want.name, got.name);
        try testing.expectEqualStrings(want.value, got.value);
    }
    try testing.expectEqual(@as(usize, 0), d.entries.items.len);
    try testing.expect(std.mem.indexOfScalar(u8, block, 0x1f) != null); // authorization: 0001 + index 23 (15 + 8)
    // The next block carries no size update.
    w = .fixed(&buf);
    try e.encode(&w, headers[0..1]);
    try testing.expectEqualSlices(u8, "\x83", w.buffered());
}

test "size update above the advertised limit, or after a field, is an error" {
    var d = Decoder.init(testing.allocator, 4096);
    defer d.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(Header) = .empty;
    try testing.expectError(error.CompressionError, d.decode(arena.allocator(), "\x3f\xe2\x1f", &out)); // 4097
    try testing.expectError(error.CompressionError, d.decode(arena.allocator(), "\x82\x20", &out));
    try testing.expectError(error.CompressionError, d.decode(arena.allocator(), "\xbe", &out)); // index 62, table empty
}
