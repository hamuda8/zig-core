//! Android media backend for calls (see zui/calls.zig): NDK MediaCodec for H.264 and Opus in
//! both directions, AAudio for the microphone (voice-communication preset: echo cancellation)
//! and the loudspeaker, and the camera through ZuiMedia.java (Camera2 writing straight into the
//! H.264 encoder's input surface). Decoded video goes straight to the surface of the
//! TextureView showing the stream.
//!
//! Threads: calls come from the UI thread (open, close, surfaces), the engine's threads
//! (received packets) and AAudio's real-time callbacks. A worker thread owns the codecs; it
//! runs while there is something to do.

const std = @import("std");
const jni = @import("../platform/jni.zig");
const zui = @import("../zui.zig");
const calls = @import("../calls.zig");
const common = @import("common.zig");
const host = @import("../host/android.zig");

// ---- NDK (libmediandk, libaaudio, libandroid, libdl) -------------------------------------------

const AMediaCodec = opaque {};
const AMediaFormat = opaque {};
const ANativeWindow = opaque {};
const AAudioStreamBuilder = opaque {};
const AAudioStream = opaque {};

const BufferInfo = extern struct { offset: i32, size: i32, presentation_us: i64, flags: u32 };
const flag_key_frame = 1;
const flag_codec_config = 2;
const info_format_changed = -2;
const color_format_surface: i32 = 0x7F000789;

extern "mediandk" fn AMediaCodec_createEncoderByType(mime: [*:0]const u8) ?*AMediaCodec;
extern "mediandk" fn AMediaCodec_createDecoderByType(mime: [*:0]const u8) ?*AMediaCodec;
extern "mediandk" fn AMediaCodec_configure(c: *AMediaCodec, f: *const AMediaFormat, surface: ?*ANativeWindow, crypto: ?*anyopaque, flags: u32) c_int;
extern "mediandk" fn AMediaCodec_start(c: *AMediaCodec) c_int;
extern "mediandk" fn AMediaCodec_stop(c: *AMediaCodec) c_int;
extern "mediandk" fn AMediaCodec_delete(c: *AMediaCodec) c_int;
extern "mediandk" fn AMediaCodec_dequeueInputBuffer(c: *AMediaCodec, timeout_us: i64) isize;
extern "mediandk" fn AMediaCodec_getInputBuffer(c: *AMediaCodec, idx: usize, size: *usize) ?[*]u8;
extern "mediandk" fn AMediaCodec_queueInputBuffer(c: *AMediaCodec, idx: usize, offset: i64, size: usize, time_us: u64, flags: u32) c_int;
extern "mediandk" fn AMediaCodec_dequeueOutputBuffer(c: *AMediaCodec, info: *BufferInfo, timeout_us: i64) isize;
extern "mediandk" fn AMediaCodec_getOutputBuffer(c: *AMediaCodec, idx: usize, size: *usize) ?[*]u8;
extern "mediandk" fn AMediaCodec_releaseOutputBuffer(c: *AMediaCodec, idx: usize, render: bool) c_int;
extern "mediandk" fn AMediaCodec_getOutputFormat(c: *AMediaCodec) ?*AMediaFormat;
extern "mediandk" fn AMediaCodec_createInputSurface(c: *AMediaCodec, surface: *?*ANativeWindow) c_int;
extern "mediandk" fn AMediaCodec_setParameters(c: *AMediaCodec, params: *const AMediaFormat) c_int;
extern "mediandk" fn AMediaFormat_new() ?*AMediaFormat;
extern "mediandk" fn AMediaFormat_delete(f: *AMediaFormat) c_int;
extern "mediandk" fn AMediaFormat_setInt32(f: *AMediaFormat, name: [*:0]const u8, v: i32) void;
extern "mediandk" fn AMediaFormat_setInt64(f: *AMediaFormat, name: [*:0]const u8, v: i64) void;
extern "mediandk" fn AMediaFormat_setString(f: *AMediaFormat, name: [*:0]const u8, v: [*:0]const u8) void;
extern "mediandk" fn AMediaFormat_setBuffer(f: *AMediaFormat, name: [*:0]const u8, data: *const anyopaque, size: usize) void;
extern "mediandk" fn AMediaFormat_getInt32(f: *AMediaFormat, name: [*:0]const u8, out: *i32) bool;

extern "android" fn ANativeWindow_fromSurface(env: *jni.Env, surface: jni.jobject) ?*ANativeWindow;
extern "android" fn ANativeWindow_toSurface(env: *jni.Env, window: *ANativeWindow) jni.jobject;
extern "android" fn ANativeWindow_release(window: *ANativeWindow) void;

const DataCallback = *const fn (s: *AAudioStream, user: ?*anyopaque, audio: ?*anyopaque, frames: i32) callconv(.c) i32;
extern "aaudio" fn AAudio_createStreamBuilder(b: *?*AAudioStreamBuilder) i32;
extern "aaudio" fn AAudioStreamBuilder_setDirection(b: *AAudioStreamBuilder, d: i32) void;
extern "aaudio" fn AAudioStreamBuilder_setSampleRate(b: *AAudioStreamBuilder, r: i32) void;
extern "aaudio" fn AAudioStreamBuilder_setChannelCount(b: *AAudioStreamBuilder, c: i32) void;
extern "aaudio" fn AAudioStreamBuilder_setFormat(b: *AAudioStreamBuilder, f: i32) void;
extern "aaudio" fn AAudioStreamBuilder_setSharingMode(b: *AAudioStreamBuilder, m: i32) void;
extern "aaudio" fn AAudioStreamBuilder_setPerformanceMode(b: *AAudioStreamBuilder, m: i32) void;
extern "aaudio" fn AAudioStreamBuilder_setDataCallback(b: *AAudioStreamBuilder, cb: DataCallback, user: ?*anyopaque) void;
extern "aaudio" fn AAudioStreamBuilder_openStream(b: *AAudioStreamBuilder, s: *?*AAudioStream) i32;
extern "aaudio" fn AAudioStreamBuilder_delete(b: *AAudioStreamBuilder) i32;
extern "aaudio" fn AAudioStream_requestStart(s: *AAudioStream) i32;
extern "aaudio" fn AAudioStream_requestStop(s: *AAudioStream) i32;
extern "aaudio" fn AAudioStream_close(s: *AAudioStream) i32;
extern "aaudio" fn AAudioStream_getSampleRate(s: *AAudioStream) i32;

extern "dl" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
extern "c" fn usleep(us: c_uint) c_int;

const aaudio_output = 0;
const aaudio_input = 1;
const aaudio_i16 = 1;
const aaudio_shared = 1;
const aaudio_low_latency = 12;
const aaudio_usage_voice = 2;
const aaudio_content_speech = 1;
const aaudio_preset_voice = 7;

/// API 28 builder settings, looked up at run time (the app may target API 26).
fn setOptional(b: *AAudioStreamBuilder, name: [*:0]const u8, v: i32) void {
    const f = dlsym(null, name) orelse return;
    const set: *const fn (*AAudioStreamBuilder, i32) callconv(.c) void = @ptrCast(@alignCast(f));
    set(b, v);
}

// ---- Java side (ZuiMedia.java) -------------------------------------------------------------

var vm: *jni.VM = undefined;
var media_class: jni.jclass = null;
var j: struct {
    open: jni.jmethodID,
    close: jni.jmethodID,
    enable: jni.jmethodID,
    switch_camera: jni.jmethodID,
    audio_mode: jni.jmethodID,
    remote_size: jni.jmethodID,
    wake: jni.jmethodID,
    pick_size: jni.jmethodID,
    swap_encoder: jni.jmethodID,
    remote_closed: jni.jmethodID,
} = undefined;

/// JNI for this thread: the UI thread's, or an attachment (as a daemon, never detached).
fn threadEnv() ?*jni.Env {
    var e: *jni.Env = undefined;
    if (vm.functions.GetEnv(vm, &e, jni.JNI_VERSION_1_6) == 0) return e;
    if (vm.functions.AttachCurrentThreadAsDaemon(vm, &e, null) != 0) return null;
    return e;
}

fn callJava(e: *jni.Env, m: jni.jmethodID, args: []const jni.jvalue) void {
    e.functions.CallStaticVoidMethodA(e, media_class, m, args.ptr);
    if (e.functions.ExceptionCheck(e) == jni.JNI_TRUE) {
        e.functions.ExceptionDescribe(e);
        e.functions.ExceptionClear(e);
    }
}

fn int(v: anytype) jni.jvalue {
    return .{ .i = @bitCast(@as(u32, @intCast(v))) };
}

fn boolean(v: bool) jni.jvalue {
    return .{ .z = @intFromBool(v) };
}

// ---- state ----------------------------------------------------------------------------------

const Mutex = struct {
    m: std.c.pthread_mutex_t = .{},
    fn lock(x: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&x.m);
    }
    fn unlock(x: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&x.m);
    }
};

const gpa = zui.allocator;
const frame_samples = 960; // 20 ms at 48 kHz
const width = 640;
const height = 480;

const Local = struct {
    id: u32,
    want_audio: bool,
    want_video: bool,
    ready: bool = false,
    audio_on: std.atomic.Value(bool) = .init(true),
    rotation: std.atomic.Value(u16) = .init(0),
    want_key: std.atomic.Value(bool) = .init(false),
    venc: ?*AMediaCodec = null,
    venc_window: ?*ANativeWindow = null,
    params: common.ParamSets = .{},
    aenc: ?*AMediaCodec = null,
    mic: ?*AAudioStream = null,
    mic_ring: common.Ring = .{},
    audio_us: u64 = 0,
    // Bitrate adaptation: the engine's target per connection sending this stream, the rate
    // the encoder runs at, and the resolution/framerate step (see `ladder`).
    rates: [8]Rate = undefined,
    rate_count: usize = 0,
    applied_bps: u32 = 0,
    level: usize = 0,
    level_changed_at: i64 = 0,
    clean_since: i64 = 0,
    adapted_at: i64 = 0,
    /// The encoder being replaced while the camera moves to the new one.
    old_venc: ?*AMediaCodec = null,
    old_window: ?*ANativeWindow = null,
    swap_done: std.atomic.Value(bool) = .init(false),
};

const Rate = struct { peer: u32, bps: u32, loss: f32 };

/// Resolution and framerate steps for our camera video. Step down when the target falls under
/// `down_lossy` with loss, or under `down` regardless; step up (after a quiet spell) once it
/// is back over `up` (the previous step's need).
const Step = struct { w: i32, h: i32, fps: i32, down_lossy: u32, down: u32, up: u32 };
const ladder = [_]Step{
    .{ .w = 640, .h = 480, .fps = 30, .down_lossy = 450_000, .down = 200_000, .up = 0 },
    .{ .w = 480, .h = 360, .fps = 30, .down_lossy = 250_000, .down = 120_000, .up = 550_000 },
    .{ .w = 320, .h = 240, .fps = 20, .down_lossy = 140_000, .down = 80_000, .up = 300_000 },
    .{ .w = 320, .h = 240, .fps = 15, .down_lossy = 0, .down = 0, .up = 170_000 },
};

const Remote = struct {
    id: u32,
    vdec: ?*AMediaCodec = null,
    window: ?*ANativeWindow = null,
    /// Set by the UI thread, applied by the worker (it owns the decoder).
    new_window: ?*ANativeWindow = null,
    window_changed: bool = false,
    has_key: bool = false,
    last_key_request: i64 = 0,
    width: i32 = 0,
    height: i32 = 0,
    rotation: u16 = 0,
    reported_rotation: u16 = 0xffff,
    adec: ?*AMediaCodec = null,
    slot: usize,
    video_us: u64 = 0,
    audio_us: u64 = 0,
};

const Inbound = struct { stream: u32, video: bool, data: []u8, key: bool, rotation: u16 };

var hooks: calls.MediaHooks = undefined;

/// What the worker produced during a pass, delivered after it lets go of `mutex`: the hooks
/// reach the call engine, whose threads may be waiting for `mutex` themselves.
const Out = union(enum) {
    audio: struct { id: u32, data: []u8 },
    video: struct { id: u32, data: []u8, ts: u32, rotation: u16 },
    keyframe: u32,
};
var outgoing: std.ArrayList(Out) = .empty;

fn emit(o: Out) void {
    outgoing.append(gpa, o) catch switch (o) {
        .audio => |a| gpa.free(a.data),
        .video => |v| gpa.free(v.data),
        .keyframe => {},
    };
}

fn deliver() void {
    const items = outgoing.toOwnedSlice(gpa) catch return;
    defer gpa.free(items);
    for (items) |o| switch (o) {
        .audio => |a| {
            hooks.audio(a.id, a.data);
            gpa.free(a.data);
        },
        .video => |v| {
            hooks.video(v.id, v.data, v.ts, v.rotation);
            gpa.free(v.data);
        },
        .keyframe => |id| hooks.need_keyframe(id),
    };
}
/// Guards the lists; the worker holds it while it services codecs.
var mutex: Mutex = .{};
var locals: std.ArrayList(*Local) = .empty;
var remotes: std.ArrayList(*Remote) = .empty;
var worker_running = false;

var inbound_lock: calls.SpinLock = .{};
var inbound: std.ArrayList(Inbound) = .empty;

/// Playback: one ring per remote stream, mixed by the output callback.
const max_remotes = 8;
var playback: [max_remotes]common.Ring = @splat(.{});
var slot_used: [max_remotes]std.atomic.Value(bool) = @splat(.init(false));
var speaker: ?*AAudioStream = null;
var audio_users: u32 = 0;

// ---- the backend interface (zui/calls.zig) --------------------------------------------------

pub fn init(h: calls.MediaHooks) void {
    hooks = h;
    const e = host.uiEnv();
    const f = e.functions;
    _ = f.GetJavaVM(e, &vm);
    const local = f.FindClass(e, "com/wufour/zui/ZuiMedia");
    media_class = f.NewGlobalRef(e, local);
    f.DeleteLocalRef(e, local);
    j = .{
        .open = f.GetStaticMethodID(e, media_class, "open", "(IZZZLandroid/view/Surface;)V"),
        .close = f.GetStaticMethodID(e, media_class, "close", "(I)V"),
        .enable = f.GetStaticMethodID(e, media_class, "enable", "(IZZ)V"),
        .switch_camera = f.GetStaticMethodID(e, media_class, "switchCamera", "(I)V"),
        .audio_mode = f.GetStaticMethodID(e, media_class, "audioMode", "(Z)V"),
        .remote_size = f.GetStaticMethodID(e, media_class, "remoteSize", "(IIII)V"),
        .wake = f.GetStaticMethodID(e, media_class, "wake", "()V"),
        .pick_size = f.GetStaticMethodID(e, media_class, "pickSize", "(III)J"),
        .swap_encoder = f.GetStaticMethodID(e, media_class, "swapEncoder", "(ILandroid/view/Surface;I)V"),
        .remote_closed = f.GetStaticMethodID(e, media_class, "remoteClosed", "(I)V"),
    };
}

/// Any thread: ask the UI thread to deliver queued call events.
pub fn wake() void {
    const e = threadEnv() orelse return;
    callJava(e, j.wake, &.{});
}

pub fn open(id: u32, m: zui.Media) void {
    if (m.screen) return hooks.event(id, .failed, "unsupported");
    const l = gpa.create(Local) catch return hooks.event(id, .failed, "unavailable");
    l.* = .{ .id = id, .want_audio = m.audio, .want_video = m.video };
    const e = host.uiEnv();
    var surface: jni.jobject = null;
    if (m.video) {
        if (!createVideoEncoder(l)) {
            gpa.destroy(l);
            return hooks.event(id, .failed, "unavailable");
        }
        surface = ANativeWindow_toSurface(e, l.venc_window.?);
    }
    mutex.lock();
    locals.append(gpa, l) catch {};
    mutex.unlock();
    callJava(e, j.open, &.{ int(id), boolean(m.audio), boolean(m.video), boolean(m.back_camera), .{ .l = surface } });
    if (surface != null) e.functions.DeleteLocalRef(e, surface);
}

pub fn enable(id: u32, audio: bool, video: bool) void {
    mutex.lock();
    if (findLocal(id)) |l| l.audio_on.store(audio, .release);
    mutex.unlock();
    callJava(host.uiEnv(), j.enable, &.{ int(id), boolean(audio), boolean(video) });
}

pub fn switchCamera(id: u32) void {
    callJava(host.uiEnv(), j.switch_camera, &.{int(id)});
    // The other side should see the new camera at once.
    requestKeyframe(id);
}

pub fn close(id: u32) void {
    callJava(host.uiEnv(), j.close, &.{int(id)});
    mutex.lock();
    var found: ?*Local = null;
    for (locals.items, 0..) |l, i| if (l.id == id) {
        found = l;
        _ = locals.swapRemove(i);
        break;
    };
    mutex.unlock();
    const l = found orelse return;
    if (l.mic) |s| {
        _ = AAudioStream_requestStop(s);
        _ = AAudioStream_close(s);
    }
    if (l.aenc) |c| deleteCodec(c);
    if (l.venc) |c| deleteCodec(c);
    if (l.venc_window) |w| ANativeWindow_release(w);
    if (l.old_venc) |c| deleteCodec(c);
    if (l.old_window) |w| ANativeWindow_release(w);
    if (l.ready and l.want_audio) audioUsers(false);
    gpa.destroy(l);
}

pub fn openRemote(id: u32) void {
    const slot = for (&slot_used, 0..) |*u, i| {
        if (u.cmpxchgStrong(false, true, .acq_rel, .monotonic) == null) break i;
    } else return;
    playback[slot].reset();
    const r = gpa.create(Remote) catch return;
    r.* = .{ .id = id, .slot = slot };
    r.adec = createOpusDecoder();
    mutex.lock();
    remotes.append(gpa, r) catch {};
    mutex.unlock();
    // The engine thread opens remotes; the speaker belongs to the UI thread's bookkeeping, but
    // AAudio does not mind which thread starts it.
    audioUsers(true);
    startWorker();
}

pub fn closeRemote(id: u32) void {
    mutex.lock();
    var found: ?*Remote = null;
    for (remotes.items, 0..) |r, i| if (r.id == id) {
        found = r;
        _ = remotes.swapRemove(i);
        break;
    };
    mutex.unlock();
    const r = found orelse return;
    slot_used[r.slot].store(false, .release);
    if (r.vdec) |c| deleteCodec(c);
    if (threadEnv()) |e| callJava(e, j.remote_closed, &.{int(id)});
    if (r.adec) |c| deleteCodec(c);
    if (r.window) |w| ANativeWindow_release(w);
    if (r.new_window) |w| ANativeWindow_release(w);
    gpa.destroy(r);
    audioUsers(false);
}

/// Engine threads: a received Opus packet / H.264 access unit for remote stream `id`.
pub fn remoteAudio(id: u32, packet: []const u8) void {
    push(.{ .stream = id, .video = false, .data = gpa.dupe(u8, packet) catch return, .key = false, .rotation = 0 });
}

pub fn remoteVideo(id: u32, annexb: []const u8, keyframe: bool, rotation: u16) void {
    push(.{ .stream = id, .video = true, .data = gpa.dupe(u8, annexb) catch return, .key = keyframe, .rotation = rotation });
}

fn push(item: Inbound) void {
    inbound_lock.lock();
    defer inbound_lock.unlock();
    // A stalled decoder must not hoard memory: keep at most a second or so.
    if (inbound.items.len > 200) {
        gpa.free(item.data);
        return;
    }
    inbound.append(gpa, item) catch gpa.free(item.data);
}

/// The other side (or a new viewer) wants a keyframe from local stream `id`'s encoder.
pub fn requestKeyframe(id: u32) void {
    mutex.lock();
    defer mutex.unlock();
    if (findLocal(id)) |l| l.want_key.store(true, .release);
}

/// The engine's target for what connection `peer` sends of local stream `id` (0 bps: the
/// connection is gone). The encoder follows the lowest.
pub fn setBitrate(id: u32, peer: u32, bps: u32, loss: f32) void {
    mutex.lock();
    defer mutex.unlock();
    const l = findLocal(id) orelse return;
    for (l.rates[0..l.rate_count], 0..) |*r, i| if (r.peer == peer) {
        if (bps == 0) {
            l.rates[i] = l.rates[l.rate_count - 1];
            l.rate_count -= 1;
        } else r.* = .{ .peer = peer, .bps = bps, .loss = loss };
        return;
    };
    if (bps == 0 or l.rate_count == l.rates.len) return;
    l.rates[l.rate_count] = .{ .peer = peer, .bps = bps, .loss = loss };
    l.rate_count += 1;
}

fn findLocal(id: u32) ?*Local {
    for (locals.items) |l| if (l.id == id) return l;
    return null;
}

fn findRemote(id: u32) ?*Remote {
    for (remotes.items) |r| if (r.id == id) return r;
    return null;
}

// ---- from Java ---------------------------------------------------------------------------------

/// The camera and microphone permissions came back, the camera started (or failed).
fn nativeResult(e: *jni.Env, _: jni.jclass, id: jni.jint, kind: jni.jint, reason: jni.jstring) callconv(.c) void {
    const stream: u32 = @bitCast(id);
    var buf: [64]u8 = undefined;
    var text: []const u8 = "";
    if (reason != null) {
        if (e.functions.GetStringUTFChars(e, reason, null)) |chars| {
            const s = std.mem.span(chars);
            const n = @min(s.len, buf.len);
            @memcpy(buf[0..n], s[0..n]);
            text = buf[0..n];
            e.functions.ReleaseStringUTFChars(e, reason, chars);
        }
    }
    if (kind == 1) {
        mutex.lock();
        const l = findLocal(stream);
        if (l) |x| x.ready = true;
        mutex.unlock();
        if (l) |x| if (x.want_audio) {
            if (!startMicrophone(x)) {
                hooks.event(stream, .failed, "unavailable");
                return;
            }
            audioUsers(true);
        };
        startWorker();
        hooks.event(stream, .ready, "");
    } else {
        hooks.event(stream, if (kind == 3) .ended else .failed, text);
    }
}

fn nativeRotation(_: *jni.Env, _: jni.jclass, id: jni.jint, degrees: jni.jint) callconv(.c) void {
    mutex.lock();
    defer mutex.unlock();
    if (findLocal(@bitCast(id))) |l| l.rotation.store(@intCast(@mod(degrees, 360)), .release);
}

/// A video view for remote stream `stream` has (or lost) its surface.
fn nativeRemoteSurface(e: *jni.Env, _: jni.jclass, stream: jni.jint, surface: jni.jobject) callconv(.c) void {
    const window = if (surface != null) ANativeWindow_fromSurface(e, surface) else null;
    mutex.lock();
    defer mutex.unlock();
    const r = findRemote(@bitCast(stream)) orelse {
        if (window) |w| ANativeWindow_release(w);
        return;
    };
    if (r.new_window) |old| ANativeWindow_release(old);
    r.new_window = window;
    r.window_changed = true;
}

/// The camera now writes into the encoder `swapEncoder` handed over.
fn nativeEncoderSwapped(_: *jni.Env, _: jni.jclass, id: jni.jint) callconv(.c) void {
    mutex.lock();
    defer mutex.unlock();
    if (findLocal(@bitCast(id))) |l| l.swap_done.store(true, .release);
}

comptime {
    @export(&nativeEncoderSwapped, .{ .name = "Java_com_wufour_zui_ZuiMedia_nativeEncoderSwapped" });
    @export(&nativeResult, .{ .name = "Java_com_wufour_zui_ZuiMedia_nativeResult" });
    @export(&nativeRotation, .{ .name = "Java_com_wufour_zui_ZuiMedia_nativeRotation" });
    @export(&nativeRemoteSurface, .{ .name = "Java_com_wufour_zui_ZuiMedia_nativeRemoteSurface" });
}

// ---- codecs ---------------------------------------------------------------------------------

fn deleteCodec(c: *AMediaCodec) void {
    _ = AMediaCodec_stop(c);
    _ = AMediaCodec_delete(c);
}

fn createVideoEncoder(l: *Local) bool {
    const e = newVideoEncoder(width, height, 30, 900_000) orelse return false;
    l.venc = e.codec;
    l.venc_window = e.window;
    return true;
}

/// An H.264 encoder fed by a surface (the camera writes into it).
fn newVideoEncoder(w: i32, h: i32, fps: i32, bps: u32) ?struct { codec: *AMediaCodec, window: *ANativeWindow } {
    const c = AMediaCodec_createEncoderByType("video/avc") orelse return null;
    const f = AMediaFormat_new() orelse {
        _ = AMediaCodec_delete(c);
        return null;
    };
    defer _ = AMediaFormat_delete(f);
    AMediaFormat_setString(f, "mime", "video/avc");
    AMediaFormat_setInt32(f, "width", w);
    AMediaFormat_setInt32(f, "height", h);
    AMediaFormat_setInt32(f, "color-format", color_format_surface);
    AMediaFormat_setInt32(f, "bitrate", @intCast(bps));
    AMediaFormat_setInt32(f, "frame-rate", fps);
    AMediaFormat_setInt32(f, "i-frame-interval", 3);
    // Baseline profile, level 3.1: what browsers decode everywhere (profile-level-id 42e01f).
    AMediaFormat_setInt32(f, "profile", 1);
    AMediaFormat_setInt32(f, "level", 0x200);
    if (AMediaCodec_configure(c, f, null, null, 1) != 0) {
        // Some encoders refuse an explicit profile/level: their default is baseline anyway.
        const g = AMediaFormat_new() orelse return null;
        defer _ = AMediaFormat_delete(g);
        AMediaFormat_setString(g, "mime", "video/avc");
        AMediaFormat_setInt32(g, "width", w);
        AMediaFormat_setInt32(g, "height", h);
        AMediaFormat_setInt32(g, "color-format", color_format_surface);
        AMediaFormat_setInt32(g, "bitrate", @intCast(bps));
        AMediaFormat_setInt32(g, "frame-rate", fps);
        AMediaFormat_setInt32(g, "i-frame-interval", 3);
        if (AMediaCodec_configure(c, g, null, null, 1) != 0) {
            _ = AMediaCodec_delete(c);
            return null;
        }
    }
    var window: ?*ANativeWindow = null;
    if (AMediaCodec_createInputSurface(c, &window) != 0 or AMediaCodec_start(c) != 0) {
        _ = AMediaCodec_delete(c);
        return null;
    }
    return .{ .codec = c, .window = window.? };
}

/// Follows the engine's target: the encoder's bitrate at once, and the resolution/framerate
/// step with hysteresis (down on loss or a very low target, up after 10 quiet seconds).
fn adapt(l: *Local, now: i64) void {
    if (l.rate_count == 0 or now < l.adapted_at + 500) return;
    l.adapted_at = now;
    var bps: u32 = std.math.maxInt(u32);
    var loss: f32 = 0;
    for (l.rates[0..l.rate_count]) |r| {
        bps = @min(bps, r.bps);
        loss = @max(loss, r.loss);
    }
    const c = l.venc orelse return;
    if (l.applied_bps == 0 or bps * 20 < l.applied_bps * 19 or bps * 20 > l.applied_bps * 21) {
        const f = AMediaFormat_new() orelse return;
        defer _ = AMediaFormat_delete(f);
        AMediaFormat_setInt32(f, "video-bitrate", @intCast(bps));
        _ = AMediaCodec_setParameters(c, f);
        l.applied_bps = bps;
    }
    if (loss >= 0.02) l.clean_since = now;
    if (l.old_venc != null or now < l.level_changed_at + 3000) return;
    const step = ladder[l.level];
    var next = l.level;
    if (l.level + 1 < ladder.len and ((loss >= 0.05 and bps < step.down_lossy) or bps < step.down)) {
        next = l.level + 1;
    } else if (l.level > 0 and bps >= step.up and now >= l.clean_since + 10_000) {
        next = l.level - 1;
    }
    if (next != l.level) changeLevel(l, next, bps, now);
}

/// A new encoder at the step's size (the nearest the camera offers) and the camera moved to it.
fn changeLevel(l: *Local, level: usize, bps: u32, now: i64) void {
    const e = threadEnv() orelse return;
    const step = ladder[level];
    const args = [_]jni.jvalue{ int(l.id), int(step.w), int(step.h) };
    const size: u64 = @bitCast(e.functions.CallStaticLongMethodA(e, media_class, j.pick_size, &args));
    if (e.functions.ExceptionCheck(e) == jni.JNI_TRUE) {
        e.functions.ExceptionClear(e);
        return;
    }
    const w: i32 = @intCast(size >> 32);
    const h: i32 = @intCast(size & 0xffff_ffff);
    if (w <= 0 or h <= 0) return;
    const fresh = newVideoEncoder(w, h, step.fps, bps) orelse return;
    l.old_venc = l.venc;
    l.old_window = l.venc_window;
    l.venc = fresh.codec;
    l.venc_window = fresh.window;
    l.params = .{};
    l.applied_bps = bps;
    l.level = level;
    l.level_changed_at = now;
    l.clean_since = now;
    zui.log("calls: video now {d}x{d} at {d} fps, {d} kbps", .{ w, h, step.fps, bps / 1000 });
    const surface = ANativeWindow_toSurface(e, fresh.window);
    defer e.functions.DeleteLocalRef(e, surface);
    callJava(e, j.swap_encoder, &.{ int(l.id), .{ .l = surface }, int(step.fps) });
}

fn createOpusEncoder() ?*AMediaCodec {
    const c = AMediaCodec_createEncoderByType("audio/opus") orelse return null;
    const f = AMediaFormat_new() orelse return null;
    defer _ = AMediaFormat_delete(f);
    AMediaFormat_setString(f, "mime", "audio/opus");
    AMediaFormat_setInt32(f, "sample-rate", 48000);
    AMediaFormat_setInt32(f, "channel-count", 1);
    AMediaFormat_setInt32(f, "bitrate", 32_000);
    if (AMediaCodec_configure(c, f, null, null, 1) != 0 or AMediaCodec_start(c) != 0) {
        _ = AMediaCodec_delete(c);
        return null;
    }
    return c;
}

fn createOpusDecoder() ?*AMediaCodec {
    const c = AMediaCodec_createDecoderByType("audio/opus") orelse return null;
    const f = AMediaFormat_new() orelse return null;
    defer _ = AMediaFormat_delete(f);
    AMediaFormat_setString(f, "mime", "audio/opus");
    AMediaFormat_setInt32(f, "sample-rate", 48000);
    AMediaFormat_setInt32(f, "channel-count", 1);
    // Android's Opus decoder wants the identification header, pre-skip and seek pre-roll (ns).
    const head = common.opusHead(1);
    AMediaFormat_setBuffer(f, "csd-0", &head, head.len);
    var pre_skip: [8]u8 = undefined;
    std.mem.writeInt(i64, &pre_skip, 312 * std.time.ns_per_s / 48000, .little);
    AMediaFormat_setBuffer(f, "csd-1", &pre_skip, 8);
    var pre_roll: [8]u8 = undefined;
    std.mem.writeInt(i64, &pre_roll, 80 * std.time.ns_per_ms, .little);
    AMediaFormat_setBuffer(f, "csd-2", &pre_roll, 8);
    if (AMediaCodec_configure(c, f, null, null, 0) != 0 or AMediaCodec_start(c) != 0) {
        _ = AMediaCodec_delete(c);
        return null;
    }
    return c;
}

fn createVideoDecoder(window: *ANativeWindow) ?*AMediaCodec {
    const c = AMediaCodec_createDecoderByType("video/avc") orelse return null;
    const f = AMediaFormat_new() orelse return null;
    defer _ = AMediaFormat_delete(f);
    AMediaFormat_setString(f, "mime", "video/avc");
    AMediaFormat_setInt32(f, "width", 1280);
    AMediaFormat_setInt32(f, "height", 720);
    if (AMediaCodec_configure(c, f, window, null, 0) != 0 or AMediaCodec_start(c) != 0) {
        _ = AMediaCodec_delete(c);
        return null;
    }
    return c;
}

/// Copies `data` into a free input buffer; false if the codec had none ready.
fn feed(c: *AMediaCodec, data: []const u8, time_us: u64) bool {
    const idx = AMediaCodec_dequeueInputBuffer(c, 2000);
    if (idx < 0) return false;
    var size: usize = 0;
    const buf = AMediaCodec_getInputBuffer(c, @intCast(idx), &size) orelse return false;
    const n = @min(size, data.len);
    @memcpy(buf[0..n], data[0..n]);
    _ = AMediaCodec_queueInputBuffer(c, @intCast(idx), 0, n, time_us, 0);
    return true;
}

// ---- audio ------------------------------------------------------------------------------------

fn openStream(direction: i32, callback: DataCallback, user: ?*anyopaque) ?*AAudioStream {
    var b: ?*AAudioStreamBuilder = null;
    if (AAudio_createStreamBuilder(&b) != 0) return null;
    const builder = b.?;
    defer _ = AAudioStreamBuilder_delete(builder);
    AAudioStreamBuilder_setDirection(builder, direction);
    AAudioStreamBuilder_setSampleRate(builder, 48000);
    AAudioStreamBuilder_setChannelCount(builder, 1);
    AAudioStreamBuilder_setFormat(builder, aaudio_i16);
    AAudioStreamBuilder_setSharingMode(builder, aaudio_shared);
    AAudioStreamBuilder_setPerformanceMode(builder, aaudio_low_latency);
    if (direction == aaudio_input) {
        // The voice-communication preset turns on the platform's echo canceller.
        setOptional(builder, "AAudioStreamBuilder_setInputPreset", aaudio_preset_voice);
    } else {
        setOptional(builder, "AAudioStreamBuilder_setUsage", aaudio_usage_voice);
        setOptional(builder, "AAudioStreamBuilder_setContentType", aaudio_content_speech);
    }
    AAudioStreamBuilder_setDataCallback(builder, callback, user);
    var s: ?*AAudioStream = null;
    if (AAudioStreamBuilder_openStream(builder, &s) != 0) return null;
    if (AAudioStream_getSampleRate(s.?) != 48000) zui.log("calls: audio stream runs at {d} Hz, not 48000", .{AAudioStream_getSampleRate(s.?)});
    if (AAudioStream_requestStart(s.?) != 0) {
        _ = AAudioStream_close(s.?);
        return null;
    }
    return s;
}

fn micCallback(_: *AAudioStream, user: ?*anyopaque, audio: ?*anyopaque, frames: i32) callconv(.c) i32 {
    const l: *Local = @ptrCast(@alignCast(user.?));
    const samples: [*]const i16 = @ptrCast(@alignCast(audio.?));
    l.mic_ring.write(samples[0..@intCast(frames)]);
    return 0;
}

fn speakerCallback(_: *AAudioStream, _: ?*anyopaque, audio: ?*anyopaque, frames: i32) callconv(.c) i32 {
    const out: [*]i16 = @ptrCast(@alignCast(audio.?));
    const n: usize = @intCast(frames);
    @memset(out[0..n], 0);
    var tmp: [1024]i16 = undefined;
    for (&playback, &slot_used) |*ring, *used| {
        if (!used.load(.acquire)) continue;
        // Keep the delay bounded: never more than ~120 ms waiting.
        ring.trim(5760 + n);
        var done: usize = 0;
        while (done < n) {
            const got = ring.read(tmp[0..@min(tmp.len, n - done)]);
            if (got == 0) break;
            for (tmp[0..got], out[done..][0..got]) |s, *o| o.* = std.math.lossyCast(i16, @as(i32, o.*) + s);
            done += got;
        }
    }
    return 0;
}

fn startMicrophone(l: *Local) bool {
    l.aenc = createOpusEncoder() orelse return false;
    l.mic = openStream(aaudio_input, micCallback, l) orelse return false;
    return true;
}

/// Counts what needs the call audio mode and the speaker stream.
fn audioUsers(on: bool) void {
    mutex.lock();
    const before = audio_users;
    audio_users = if (on) audio_users + 1 else audio_users -| 1;
    const after = audio_users;
    mutex.unlock();
    if (before == 0 and after > 0) {
        speaker = openStream(aaudio_output, speakerCallback, null);
    } else if (before > 0 and after == 0) {
        if (speaker) |s| {
            _ = AAudioStream_requestStop(s);
            _ = AAudioStream_close(s);
        }
        speaker = null;
    }
}

// ---- the worker ---------------------------------------------------------------------------------

fn startWorker() void {
    mutex.lock();
    defer mutex.unlock();
    if (worker_running) return;
    const t = std.Thread.spawn(.{}, worker, .{}) catch return;
    t.detach();
    worker_running = true;
}

fn worker() void {
    _ = threadEnv(); // for remoteSize calls into Java
    while (true) {
        mutex.lock();
        if (locals.items.len == 0 and remotes.items.len == 0) {
            worker_running = false;
            mutex.unlock();
            return;
        }
        service();
        mutex.unlock();
        deliver();
        _ = usleep(4000);
    }
}

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, std.time.ns_per_ms);
}

/// One pass over every codec. Called with `mutex` held.
fn service() void {
    // Received packets into the decoders.
    inbound_lock.lock();
    const items = inbound.toOwnedSlice(gpa) catch &.{};
    inbound_lock.unlock();
    defer gpa.free(items);
    for (items) |item| {
        defer gpa.free(item.data);
        const r = findRemote(item.stream) orelse continue;
        if (item.video) decodeVideo(r, item) else if (r.adec) |c| {
            if (feed(c, item.data, r.audio_us)) r.audio_us += 20_000;
        }
    }

    for (remotes.items) |r| {
        if (r.window_changed) applyWindow(r);
        if (r.vdec) |c| drainVideoDecoder(r, c);
        if (r.adec) |c| drainAudioDecoder(r, c);
    }

    const now = nowMs();
    for (locals.items) |l| {
        if (l.swap_done.swap(false, .acq_rel)) {
            // The camera writes into the new encoder now: the old one can go.
            if (l.old_venc) |c| deleteCodec(c);
            if (l.old_window) |w| ANativeWindow_release(w);
            l.old_venc = null;
            l.old_window = null;
        }
        if (l.venc) |c| {
            adapt(l, now);
            if (l.want_key.swap(false, .acq_rel)) requestSync(c);
            drainVideoEncoder(l, c);
        }
        if (l.aenc) |c| encodeAudio(l, c);
    }
}

fn applyWindow(r: *Remote) void {
    r.window_changed = false;
    if (r.vdec) |c| deleteCodec(c);
    r.vdec = null;
    if (r.window) |w| ANativeWindow_release(w);
    r.window = r.new_window;
    r.new_window = null;
    r.has_key = false;
    r.reported_rotation = 0xffff;
    if (r.window) |w| r.vdec = createVideoDecoder(w);
    // A fresh decoder starts at a keyframe.
    emit(.{ .keyframe = r.id });
    r.last_key_request = nowMs();
}

fn decodeVideo(r: *Remote, item: Inbound) void {
    const c = r.vdec orelse return; // nobody is looking
    r.rotation = item.rotation;
    if (!r.has_key) {
        if (!item.key) {
            if (nowMs() - r.last_key_request > 500) {
                r.last_key_request = nowMs();
                emit(.{ .keyframe = r.id });
            }
            return;
        }
        r.has_key = true;
    }
    if (feed(c, item.data, r.video_us)) r.video_us += 33_333 else {
        // The decoder is behind: what follows depends on this frame, so start over.
        r.has_key = false;
    }
    if (r.rotation != r.reported_rotation and r.width > 0) reportSize(r);
}

fn reportSize(r: *Remote) void {
    r.reported_rotation = r.rotation;
    const e = threadEnv() orelse return;
    callJava(e, j.remote_size, &.{ int(r.id), int(r.width), int(r.height), int(r.rotation) });
}

fn drainVideoDecoder(r: *Remote, c: *AMediaCodec) void {
    var info: BufferInfo = undefined;
    while (true) {
        const idx = AMediaCodec_dequeueOutputBuffer(c, &info, 0);
        if (idx == info_format_changed) {
            const f = AMediaCodec_getOutputFormat(c) orelse continue;
            defer _ = AMediaFormat_delete(f);
            var w: i32 = 0;
            var h: i32 = 0;
            _ = AMediaFormat_getInt32(f, "width", &w);
            _ = AMediaFormat_getInt32(f, "height", &h);
            var left: i32 = 0;
            var right: i32 = -1;
            var top: i32 = 0;
            var bottom: i32 = -1;
            if (AMediaFormat_getInt32(f, "crop-right", &right) and AMediaFormat_getInt32(f, "crop-left", &left)) w = right - left + 1;
            if (AMediaFormat_getInt32(f, "crop-bottom", &bottom) and AMediaFormat_getInt32(f, "crop-top", &top)) h = bottom - top + 1;
            r.width = w;
            r.height = h;
            reportSize(r);
            continue;
        }
        if (idx < 0) return;
        _ = AMediaCodec_releaseOutputBuffer(c, @intCast(idx), true);
    }
}

fn drainAudioDecoder(r: *Remote, c: *AMediaCodec) void {
    var info: BufferInfo = undefined;
    while (true) {
        const idx = AMediaCodec_dequeueOutputBuffer(c, &info, 0);
        if (idx == info_format_changed) continue;
        if (idx < 0) return;
        var size: usize = 0;
        if (AMediaCodec_getOutputBuffer(c, @intCast(idx), &size)) |buf| {
            const start: usize = @intCast(info.offset);
            const len: usize = @intCast(info.size);
            if (start + len <= size and len >= 2) {
                const pcm: [*]const i16 = @ptrCast(@alignCast(buf + start));
                playback[r.slot].write(pcm[0 .. len / 2]);
            }
        }
        _ = AMediaCodec_releaseOutputBuffer(c, @intCast(idx), false);
    }
}

fn requestSync(c: *AMediaCodec) void {
    const f = AMediaFormat_new() orelse return;
    defer _ = AMediaFormat_delete(f);
    AMediaFormat_setInt32(f, "request-sync", 0);
    _ = AMediaCodec_setParameters(c, f);
}

fn drainVideoEncoder(l: *Local, c: *AMediaCodec) void {
    var info: BufferInfo = undefined;
    var out: [256 * 1024]u8 = undefined;
    while (true) {
        const idx = AMediaCodec_dequeueOutputBuffer(c, &info, 0);
        if (idx == info_format_changed) continue;
        if (idx < 0) return;
        var size: usize = 0;
        if (AMediaCodec_getOutputBuffer(c, @intCast(idx), &size)) |buf| {
            const start: usize = @intCast(info.offset);
            const len: usize = @intCast(info.size);
            if (start + len <= size and len > 0) {
                const data = buf[start..][0..len];
                if (info.flags & flag_codec_config != 0) {
                    l.params.set(data);
                } else {
                    const key = info.flags & flag_key_frame != 0 or common.hasNal(data, 5);
                    const au = l.params.complete(data, key, &out);
                    const ts: u32 = @truncate(@as(u64, @intCast(@max(info.presentation_us, 0))) * 9 / 100);
                    if (gpa.dupe(u8, au)) |copy| emit(.{ .video = .{ .id = l.id, .data = copy, .ts = ts, .rotation = l.rotation.load(.acquire) } }) else |_| {}
                }
            }
        }
        _ = AMediaCodec_releaseOutputBuffer(c, @intCast(idx), false);
    }
}

fn encodeAudio(l: *Local, c: *AMediaCodec) void {
    // Microphone samples into the encoder, 20 ms at a time (silence while muted).
    var pcm: [frame_samples]i16 = undefined;
    while (l.mic_ring.available() >= frame_samples) {
        const idx = AMediaCodec_dequeueInputBuffer(c, 0);
        if (idx < 0) break;
        _ = l.mic_ring.read(&pcm);
        if (!l.audio_on.load(.acquire)) @memset(&pcm, 0);
        var size: usize = 0;
        const buf = AMediaCodec_getInputBuffer(c, @intCast(idx), &size) orelse break;
        const bytes = std.mem.sliceAsBytes(&pcm);
        const n = @min(size, bytes.len);
        @memcpy(buf[0..n], bytes[0..n]);
        _ = AMediaCodec_queueInputBuffer(c, @intCast(idx), 0, n, l.audio_us, 0);
        l.audio_us += 20_000;
    }
    // A backlog means the encoder is slow: drop old audio rather than drift behind.
    l.mic_ring.trim(frame_samples * 10);
    var info: BufferInfo = undefined;
    while (true) {
        const idx = AMediaCodec_dequeueOutputBuffer(c, &info, 0);
        if (idx == info_format_changed) continue;
        if (idx < 0) return;
        var size: usize = 0;
        if (info.flags & flag_codec_config == 0) if (AMediaCodec_getOutputBuffer(c, @intCast(idx), &size)) |buf| {
            const start: usize = @intCast(info.offset);
            const len: usize = @intCast(info.size);
            if (start + len <= size and len > 0) {
                if (gpa.dupe(u8, buf[start..][0..len])) |copy| emit(.{ .audio = .{ .id = l.id, .data = copy } }) else |_| {}
            }
        };
        _ = AMediaCodec_releaseOutputBuffer(c, @intCast(idx), false);
    }
}
