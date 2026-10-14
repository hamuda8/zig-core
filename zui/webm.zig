//! WebM (Matroska) audio demuxing: the Opus packets of a voice message recorded by a browser's
//! MediaRecorder, for platforms that cannot play WebM themselves (iOS decodes the Opus with
//! AudioConverter). Handles what MediaRecorder writes: an EBML header, a Segment and Clusters of
//! unknown size, SimpleBlocks (and BlockGroups) of one audio track, without lacing.

const std = @import("std");

pub const Audio = struct {
    codec: []const u8 = "",
    channels: u8 = 1,
    sample_rate: u32 = 48000,
    /// Samples to drop at the start (OpusHead's pre-skip).
    pre_skip: u16 = 0,
    /// Each frame of the audio track, in order (slices of the input).
    packets: std.ArrayList([]const u8) = .empty,

    pub fn deinit(a: *Audio, gpa: std.mem.Allocator) void {
        a.packets.deinit(gpa);
    }
};

pub const Error = error{ NotWebm, Truncated, OutOfMemory };

const ids = struct {
    const ebml = 0x1A45DFA3;
    const segment = 0x18538067;
    const cluster = 0x1F43B675;
    const tracks = 0x1654AE6B;
    const track_entry = 0xAE;
    const track_number = 0xD7;
    const track_type = 0x83;
    const codec_id = 0x86;
    const codec_private = 0x63A2;
    const audio = 0xE1;
    const sampling_frequency = 0xB5;
    const channels = 0x9F;
    const simple_block = 0xA3;
    const block_group = 0xA0;
    const block = 0xA1;
};

/// Top-level-ish elements whose children are read in place (their size may be unknown).
fn isContainer(id: u32) bool {
    return id == ids.segment or id == ids.cluster or id == ids.tracks or id == ids.track_entry or id == ids.audio or id == ids.block_group;
}

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    /// An element ID (its marker bits kept, as in the spec).
    fn id(r: *Reader) Error!u32 {
        if (r.pos >= r.data.len) return error.Truncated;
        const first = r.data[r.pos];
        const len: usize = if (first & 0x80 != 0) 1 else if (first & 0x40 != 0) 2 else if (first & 0x20 != 0) 3 else if (first & 0x10 != 0) 4 else return error.NotWebm;
        if (r.pos + len > r.data.len) return error.Truncated;
        var v: u32 = 0;
        for (r.data[r.pos..][0..len]) |b| v = (v << 8) | b;
        r.pos += len;
        return v;
    }

    /// A size; null when unknown (all value bits set).
    fn size(r: *Reader) Error!?u64 {
        if (r.pos >= r.data.len) return error.Truncated;
        const first = r.data[r.pos];
        var len: usize = 1;
        while (len <= 8 and first & (@as(u8, 0x80) >> @intCast(len - 1)) == 0) len += 1;
        if (len > 8) return error.NotWebm;
        if (r.pos + len > r.data.len) return error.Truncated;
        const mask: u8 = @truncate(@as(u16, 0xFF) >> @intCast(len));
        var v: u64 = first & mask;
        var all_ones = v == mask;
        for (r.data[r.pos + 1 ..][0 .. len - 1]) |b| {
            v = (v << 8) | b;
            if (b != 0xFF) all_ones = false;
        }
        r.pos += len;
        return if (all_ones) null else v;
    }
};

fn uint(b: []const u8) u64 {
    var v: u64 = 0;
    for (b[0..@min(b.len, 8)]) |x| v = (v << 8) | x;
    return v;
}

fn float(b: []const u8) f64 {
    return switch (b.len) {
        4 => @as(f32, @bitCast(@as(u32, @truncate(uint(b))))),
        8 => @bitCast(uint(b)),
        else => 0,
    };
}

/// The audio track's packets. `data` must stay alive while they are used.
pub fn demux(gpa: std.mem.Allocator, data: []const u8) Error!Audio {
    if (data.len < 4 or std.mem.readInt(u32, data[0..4], .big) != ids.ebml) return error.NotWebm;
    var out: Audio = .{};
    errdefer out.deinit(gpa);
    var audio_track: ?u64 = null;
    var current: struct { number: u64 = 0, kind: u64 = 0, codec: []const u8 = "", private: []const u8 = "", channels: u8 = 1, rate: u32 = 48000 } = .{};
    var r: Reader = .{ .data = data };
    while (r.pos < data.len) {
        const start = r.pos;
        const el = r.id() catch break;
        const sz = r.size() catch break;
        if (isContainer(el)) {
            if (el == ids.track_entry) current = .{};
            // Read the children in place; a TrackEntry ends where its size says.
            if (el == ids.track_entry or el == ids.audio) {
                const end = if (sz) |s| @min(data.len, r.pos + s) else data.len;
                try trackFields(&r, end, &current);
                if (el == ids.track_entry and current.kind == 2 and audio_track == null) {
                    audio_track = current.number;
                    out.codec = current.codec;
                    out.channels = current.channels;
                    out.sample_rate = current.rate;
                    if (current.private.len >= 12 and std.mem.eql(u8, current.private[0..8], "OpusHead")) {
                        out.pre_skip = std.mem.readInt(u16, current.private[10..12], .little);
                        out.channels = current.private[9];
                    }
                }
            }
            continue;
        }
        const len: usize = @intCast(sz orelse return error.NotWebm);
        if (r.pos + len > data.len) break;
        const body = data[r.pos..][0..len];
        r.pos += len;
        _ = start;
        if (el == ids.simple_block or el == ids.block) {
            var b: Reader = .{ .data = body };
            const track = (b.size() catch continue) orelse continue;
            if (b.pos + 3 > body.len) continue;
            const flags = body[b.pos + 2];
            b.pos += 3;
            // Lacing (several frames in one block) is not used by MediaRecorder.
            if (flags & 0x06 != 0) continue;
            if (audio_track) |t| if (t == track) try out.packets.append(gpa, body[b.pos..]);
        }
    }
    if (audio_track == null) return error.NotWebm;
    return out;
}

fn trackFields(r: *Reader, end: usize, t: anytype) Error!void {
    while (r.pos < end) {
        const el = try r.id();
        const sz = (try r.size()) orelse return error.NotWebm;
        if (el == ids.audio) {
            try trackFields(r, @min(end, r.pos + @as(usize, @intCast(sz))), t);
            continue;
        }
        const len: usize = @intCast(sz);
        if (r.pos + len > r.data.len) return error.Truncated;
        const body = r.data[r.pos..][0..len];
        r.pos += len;
        switch (el) {
            ids.track_number => t.number = uint(body),
            ids.track_type => t.kind = uint(body),
            ids.codec_id => t.codec = body,
            ids.codec_private => t.private = body,
            ids.channels => t.channels = @intCast(@min(255, uint(body))),
            ids.sampling_frequency => t.rate = @intFromFloat(@max(0, float(body))),
            else => {},
        }
    }
}

/// 16-bit PCM as a WAV file (for players that read WAV, after decoding).
pub fn wav(gpa: std.mem.Allocator, pcm: []const i16, channels: u16, rate: u32) ![]u8 {
    const data_len: u32 = @intCast(pcm.len * 2);
    const out = try gpa.alloc(u8, 44 + data_len);
    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], 36 + data_len, .little);
    @memcpy(out[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little);
    std.mem.writeInt(u16, out[20..22], 1, .little);
    std.mem.writeInt(u16, out[22..24], channels, .little);
    std.mem.writeInt(u32, out[24..28], rate, .little);
    std.mem.writeInt(u32, out[28..32], rate * channels * 2, .little);
    std.mem.writeInt(u16, out[32..34], channels * 2, .little);
    std.mem.writeInt(u16, out[34..36], 16, .little);
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..44], data_len, .little);
    @memcpy(out[44..], std.mem.sliceAsBytes(pcm));
    return out;
}

// ---- tests ------------------------------------------------------------------------------------

fn put(list: *std.ArrayList(u8), gpa: std.mem.Allocator, id: u32, body: []const u8) !void {
    var idb: [4]u8 = undefined;
    std.mem.writeInt(u32, &idb, id, .big);
    var k: usize = 0;
    while (idb[k] == 0) k += 1;
    try list.appendSlice(gpa, idb[k..]);
    // An 8-byte size, as some muxers write.
    try list.append(gpa, 0x01);
    var sz: [7]u8 = undefined;
    std.mem.writeInt(u56, &sz, @intCast(body.len), .big);
    try list.appendSlice(gpa, &sz);
    try list.appendSlice(gpa, body);
}

test "demux MediaRecorder-style WebM: unknown sizes, OpusHead, SimpleBlocks" {
    const gpa = std.testing.allocator;
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    try put(&file, gpa, ids.ebml, &.{ 0x42, 0x82, 0x84, 'w', 'e', 'b', 'm' });
    // Segment of unknown size.
    try file.appendSlice(gpa, &.{ 0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
    var entry: std.ArrayList(u8) = .empty;
    defer entry.deinit(gpa);
    try put(&entry, gpa, ids.track_number, &.{1});
    try put(&entry, gpa, ids.track_type, &.{2});
    try put(&entry, gpa, ids.codec_id, "A_OPUS");
    try put(&entry, gpa, ids.codec_private, &.{ 'O', 'p', 'u', 's', 'H', 'e', 'a', 'd', 1, 1, 0x38, 0x01, 0x80, 0xBB, 0, 0, 0, 0, 0 });
    var audio: std.ArrayList(u8) = .empty;
    defer audio.deinit(gpa);
    try put(&audio, gpa, ids.channels, &.{1});
    try put(&entry, gpa, ids.audio, audio.items);
    var tracks: std.ArrayList(u8) = .empty;
    defer tracks.deinit(gpa);
    try put(&tracks, gpa, ids.track_entry, entry.items);
    try put(&file, gpa, ids.tracks, tracks.items);
    // Cluster of unknown size with two SimpleBlocks.
    try file.appendSlice(gpa, &.{ 0x1F, 0x43, 0xB6, 0x75, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
    try put(&file, gpa, 0xE7, &.{0}); // Timecode
    try put(&file, gpa, ids.simple_block, &.{ 0x81, 0, 0, 0x80, 0xAA, 0xBB });
    try put(&file, gpa, ids.simple_block, &.{ 0x81, 0, 20, 0x80, 0xCC });
    var a = try demux(gpa, file.items);
    defer a.deinit(gpa);
    try std.testing.expectEqualStrings("A_OPUS", a.codec);
    try std.testing.expectEqual(@as(u16, 312), a.pre_skip);
    try std.testing.expectEqual(@as(usize, 2), a.packets.items.len);
    try std.testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB }, a.packets.items[0]);
    try std.testing.expectEqualSlices(u8, &.{0xCC}, a.packets.items[1]);
    try std.testing.expectError(error.NotWebm, demux(gpa, "RIFF...."));
}

test "wav" {
    const gpa = std.testing.allocator;
    const w = try wav(gpa, &.{ 1, -1 }, 1, 48000);
    defer gpa.free(w);
    try std.testing.expectEqual(@as(usize, 48), w.len);
    try std.testing.expectEqualStrings("WAVE", w[8..12]);
}
