//! Just enough ZIP to assemble an APK: read the entries of an existing archive (raw, without
//! inflating them) and write a new archive where stored entries are aligned. Alignment uses the
//! same extra field as Android's zipalign (0xD935), which apksigner and the package installer
//! understand.

const std = @import("std");

pub const Entry = struct {
    name: []const u8,
    /// 0 = stored, 8 = deflated. `data` is the raw (possibly compressed) bytes.
    method: u16,
    crc32: u32,
    uncompressed_size: u32,
    data: []const u8,
    /// Byte alignment of `data` in the output, for stored entries.
    alignment: u32 = 4,
};

const local_sig = 0x04034b50;
const central_sig = 0x02014b50;
const end_sig = 0x06054b50;
const align_extra_id = 0xD935;
/// 1980-01-01 00:00, so output does not depend on the clock.
const dos_date: u16 = (0 << 9) | (1 << 5) | 1;

/// A stored entry for `data`.
pub fn stored(name: []const u8, data: []const u8, alignment: u32) Entry {
    return .{
        .name = name,
        .method = 0,
        .crc32 = std.hash.Crc32.hash(data),
        .uncompressed_size = @intCast(data.len),
        .data = data,
        .alignment = alignment,
    };
}

/// Lists the entries of `archive`. Entry names and data point into `archive`.
pub fn read(arena: std.mem.Allocator, archive: []const u8) ![]Entry {
    if (archive.len < 22) return error.NotZip;
    var end = archive.len - 22;
    while (std.mem.readInt(u32, archive[end..][0..4], .little) != end_sig) {
        if (end == 0) return error.NotZip;
        end -= 1;
    }
    const count = std.mem.readInt(u16, archive[end + 10 ..][0..2], .little);
    var pos: usize = std.mem.readInt(u32, archive[end + 16 ..][0..4], .little);

    const entries = try arena.alloc(Entry, count);
    for (entries) |*e| {
        if (std.mem.readInt(u32, archive[pos..][0..4], .little) != central_sig) return error.BadCentralDirectory;
        const method = std.mem.readInt(u16, archive[pos + 10 ..][0..2], .little);
        const crc = std.mem.readInt(u32, archive[pos + 16 ..][0..4], .little);
        const csize = std.mem.readInt(u32, archive[pos + 20 ..][0..4], .little);
        const usize_ = std.mem.readInt(u32, archive[pos + 24 ..][0..4], .little);
        const name_len = std.mem.readInt(u16, archive[pos + 28 ..][0..2], .little);
        const extra_len = std.mem.readInt(u16, archive[pos + 30 ..][0..2], .little);
        const comment_len = std.mem.readInt(u16, archive[pos + 32 ..][0..2], .little);
        const local = std.mem.readInt(u32, archive[pos + 42 ..][0..4], .little);
        const name = archive[pos + 46 ..][0..name_len];

        if (std.mem.readInt(u32, archive[local..][0..4], .little) != local_sig) return error.BadLocalHeader;
        const l_name = std.mem.readInt(u16, archive[local + 26 ..][0..2], .little);
        const l_extra = std.mem.readInt(u16, archive[local + 28 ..][0..2], .little);
        const start = local + 30 + l_name + l_extra;

        e.* = .{ .name = name, .method = method, .crc32 = crc, .uncompressed_size = usize_, .data = archive[start..][0..csize] };
        pos += 46 + name_len + extra_len + comment_len;
    }
    return entries;
}

/// Writes `entries` as a new archive.
pub fn write(arena: std.mem.Allocator, entries: []const Entry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const offsets = try arena.alloc(u32, entries.len);

    for (entries, offsets) |e, *offset| {
        offset.* = @intCast(out.items.len);
        const extra = if (e.method == 0) padding(out.items.len + 30 + e.name.len, e.alignment) else 0;
        try int(&out, arena, u32, local_sig);
        try int(&out, arena, u16, 20); // version needed
        try int(&out, arena, u16, 0); // flags
        try int(&out, arena, u16, e.method);
        try int(&out, arena, u16, 0); // time
        try int(&out, arena, u16, dos_date);
        try int(&out, arena, u32, e.crc32);
        try int(&out, arena, u32, @intCast(e.data.len));
        try int(&out, arena, u32, e.uncompressed_size);
        try int(&out, arena, u16, @intCast(e.name.len));
        try int(&out, arena, u16, @intCast(extra));
        try out.appendSlice(arena, e.name);
        if (extra > 0) {
            try int(&out, arena, u16, align_extra_id);
            try int(&out, arena, u16, @intCast(extra - 4));
            try int(&out, arena, u16, @intCast(e.alignment));
            try out.appendNTimes(arena, 0, extra - 6);
        }
        try out.appendSlice(arena, e.data);
    }

    const cd_start = out.items.len;
    for (entries, offsets) |e, offset| {
        try int(&out, arena, u32, central_sig);
        try int(&out, arena, u16, 20); // version made by
        try int(&out, arena, u16, 20); // version needed
        try int(&out, arena, u16, 0);
        try int(&out, arena, u16, e.method);
        try int(&out, arena, u16, 0);
        try int(&out, arena, u16, dos_date);
        try int(&out, arena, u32, e.crc32);
        try int(&out, arena, u32, @intCast(e.data.len));
        try int(&out, arena, u32, e.uncompressed_size);
        try int(&out, arena, u16, @intCast(e.name.len));
        try int(&out, arena, u16, 0); // extra
        try int(&out, arena, u16, 0); // comment
        try int(&out, arena, u16, 0); // disk
        try int(&out, arena, u16, 0); // internal attributes
        try int(&out, arena, u32, 0); // external attributes
        try int(&out, arena, u32, offset);
        try out.appendSlice(arena, e.name);
    }
    const cd_size = out.items.len - cd_start;

    try int(&out, arena, u32, end_sig);
    try int(&out, arena, u16, 0);
    try int(&out, arena, u16, 0);
    try int(&out, arena, u16, @intCast(entries.len));
    try int(&out, arena, u16, @intCast(entries.len));
    try int(&out, arena, u32, @intCast(cd_size));
    try int(&out, arena, u32, @intCast(cd_start));
    try int(&out, arena, u16, 0);
    return out.items;
}

/// Extra-field length that puts the data at a multiple of `alignment`. A padding field needs
/// at least 6 bytes (id, size, alignment), so small gaps grow by whole alignment steps.
fn padding(data_start: usize, alignment: u32) usize {
    if (alignment <= 1 or data_start % alignment == 0) return 0;
    var pad = alignment - data_start % alignment;
    while (pad < 6) pad += alignment;
    return pad;
}

fn int(out: *std.ArrayList(u8), arena: std.mem.Allocator, comptime T: type, value: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try out.appendSlice(arena, &buf);
}

test "round trip keeps entries and aligns stored data" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const so = "\x7fELF fake library";
    const archive = try write(arena, &.{
        stored("AndroidManifest.xml", "<manifest/>", 4),
        stored("lib/arm64-v8a/libapp.so", so, 16384),
    });
    const entries = try read(arena, archive);
    try std.testing.expectEqual(2, entries.len);
    try std.testing.expectEqualStrings("lib/arm64-v8a/libapp.so", entries[1].name);
    try std.testing.expectEqualStrings(so, entries[1].data);
    try std.testing.expectEqual(std.hash.Crc32.hash(so), entries[1].crc32);
    const data_offset = @intFromPtr(entries[1].data.ptr) - @intFromPtr(archive.ptr);
    try std.testing.expectEqual(0, data_offset % 16384);
}

test padding {
    try std.testing.expectEqual(0, padding(16, 4));
    try std.testing.expectEqual(6, padding(14, 4)); // gap of 2 grows to 2 + 4
    try std.testing.expectEqual(16384 - 100, padding(100, 16384));
}
