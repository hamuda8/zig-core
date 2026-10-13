//! Pieces both phone media backends share: a lock-free audio ring between a real-time audio
//! callback and a worker thread, the Opus identification header decoders want, and H.264
//! parameter-set bookkeeping (encoders emit SPS/PPS once; every keyframe sent needs them).

const std = @import("std");

/// Single-producer single-consumer ring of 16-bit samples (48 kHz mono: one second).
pub const Ring = struct {
    pub const capacity = 48000;

    buf: [capacity]i16 = undefined,
    /// Total samples written / read; the difference is what is waiting.
    written: std.atomic.Value(usize) = .init(0),
    read_count: std.atomic.Value(usize) = .init(0),

    pub fn available(r: *const Ring) usize {
        return r.written.load(.acquire) - r.read_count.load(.acquire);
    }

    /// Producer side. What does not fit is dropped.
    pub fn write(r: *Ring, samples: []const i16) void {
        const w = r.written.load(.monotonic);
        const free = capacity - (w - r.read_count.load(.acquire));
        const n = @min(free, samples.len);
        for (samples[0..n], 0..) |s, i| r.buf[(w + i) % capacity] = s;
        r.written.store(w + n, .release);
    }

    /// Consumer side: up to `out.len` samples; returns how many.
    pub fn read(r: *Ring, out: []i16) usize {
        const rd = r.read_count.load(.monotonic);
        const n = @min(r.written.load(.acquire) - rd, out.len);
        for (out[0..n], 0..) |*s, i| s.* = r.buf[(rd + i) % capacity];
        r.read_count.store(rd + n, .release);
        return n;
    }

    /// Consumer side: drops the oldest samples so at most `keep` wait (bounds the latency).
    pub fn trim(r: *Ring, keep: usize) void {
        const rd = r.read_count.load(.monotonic);
        const waiting = r.written.load(.acquire) - rd;
        if (waiting > keep) r.read_count.store(rd + (waiting - keep), .release);
    }

    /// Only while neither side runs.
    pub fn reset(r: *Ring) void {
        r.written.store(0, .release);
        r.read_count.store(0, .release);
    }
};

/// "OpusHead" (RFC 7845 5.1) for a 48 kHz stream: what Android's and Apple's Opus decoders want
/// as their first configuration data.
pub fn opusHead(channels: u8) [19]u8 {
    var h: [19]u8 = undefined;
    @memcpy(h[0..8], "OpusHead");
    h[8] = 1; // version
    h[9] = channels;
    std.mem.writeInt(u16, h[10..12], 312, .little); // pre-skip (libopus default)
    std.mem.writeInt(u32, h[12..16], 48000, .little);
    std.mem.writeInt(i16, h[16..18], 0, .little); // output gain
    h[18] = 0; // channel mapping family 0 (mono/stereo)
    return h;
}

/// Remembers the encoder's SPS/PPS and puts them in front of keyframes that lack them.
pub const ParamSets = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    /// Codec configuration output (Annex-B SPS + PPS).
    pub fn set(p: *ParamSets, annexb: []const u8) void {
        p.len = @min(annexb.len, p.buf.len);
        @memcpy(p.buf[0..p.len], annexb[0..p.len]);
    }

    /// `au` with the parameter sets in front when it is a keyframe without them, written into
    /// `out` (which must hold both); otherwise `au` itself.
    pub fn complete(p: *const ParamSets, au: []const u8, keyframe: bool, out: []u8) []const u8 {
        if (!keyframe or p.len == 0 or hasNal(au, 7) or p.len + au.len > out.len) return au;
        @memcpy(out[0..p.len], p.buf[0..p.len]);
        @memcpy(out[p.len..][0..au.len], au);
        return out[0 .. p.len + au.len];
    }
};

/// True if the Annex-B data holds a NAL unit of `nal_type`.
pub fn hasNal(annexb: []const u8, nal_type: u5) bool {
    var i: usize = 0;
    while (i + 3 < annexb.len) : (i += 1) {
        if (annexb[i] == 0 and annexb[i + 1] == 0 and annexb[i + 2] == 1) {
            if (@as(u5, @truncate(annexb[i + 3])) == nal_type) return true;
            i += 2;
        }
    }
    return false;
}

test "ring wraps and trims" {
    var r: Ring = .{};
    var big: [Ring.capacity - 10]i16 = @splat(1);
    r.write(&big);
    var out: [Ring.capacity]i16 = undefined;
    try std.testing.expectEqual(big.len, r.read(&out));
    const s = [_]i16{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    r.write(&s); // across the end
    r.trim(4);
    try std.testing.expectEqual(@as(usize, 4), r.read(&out));
    try std.testing.expectEqualSlices(i16, &.{ 9, 10, 11, 12 }, out[0..4]);
}

test "param sets go in front of keyframes" {
    var p: ParamSets = .{};
    p.set(&.{ 0, 0, 0, 1, 0x67, 1, 0, 0, 0, 1, 0x68, 2 });
    var out: [64]u8 = undefined;
    const idr = [_]u8{ 0, 0, 0, 1, 0x65, 9 };
    const full = p.complete(&idr, true, &out);
    try std.testing.expect(hasNal(full, 7) and hasNal(full, 5));
    try std.testing.expectEqual(@as(usize, 6), p.complete(&idr, false, &out).len);
}
