//! iOS media backend for calls (see zui/calls.zig), on Apple frameworks only:
//! AVCaptureSession for the camera, VideoToolbox for H.264 encoding, AVSampleBufferDisplayLayer
//! to decode and draw received H.264, AudioUnit VoiceProcessingIO for echo-cancelled capture and
//! playback, and AudioConverter for Opus in both directions.
//!
//! Threads: calls arrive on the main thread (open, close, views), from the engine's threads
//! (received packets) and from Core Audio's real-time thread. Capture runs on a serial dispatch
//! queue, the encoder's output on VideoToolbox's thread, Opus work on a worker thread, and
//! layer updates on the main thread.

const std = @import("std");
const objc = @import("../platform/objc.zig");
const zui = @import("../zui.zig");
const calls = @import("../calls.zig");
const common = @import("common.zig");

const id = objc.id;

// ---- C frameworks -----------------------------------------------------------------------------

const CFTypeRef = ?*anyopaque;
const OSStatus = i32;
const CMTime = extern struct { value: i64, timescale: i32, flags: u32, epoch: i64 };
const CMVideoDimensions = extern struct { width: i32, height: i32 };
const CGAffineTransform = extern struct { a: f64, b: f64, c: f64, d: f64, tx: f64, ty: f64 };

const Queue = *anyopaque;
extern "c" fn dispatch_async_f(queue: Queue, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;
extern "c" fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) Queue;
extern "c" var _dispatch_main_q: u8;
fn mainQueue() Queue {
    return @ptrCast(&_dispatch_main_q);
}

extern "c" fn CFRelease(cf: CFTypeRef) void;
extern "c" fn CFRetain(cf: CFTypeRef) CFTypeRef;
extern "c" fn CFNumberCreate(alloc: ?*anyopaque, the_type: isize, value: *const anyopaque) CFTypeRef;
extern "c" fn CFDictionaryCreate(alloc: ?*anyopaque, keys: [*]const CFTypeRef, values: [*]const CFTypeRef, n: isize, key_cb: *const anyopaque, value_cb: *const anyopaque) CFTypeRef;
extern "c" fn CFDictionarySetValue(dict: CFTypeRef, key: CFTypeRef, value: CFTypeRef) void;
extern "c" fn CFDictionaryContainsKey(dict: CFTypeRef, key: CFTypeRef) u8;
extern "c" fn CFArrayGetValueAtIndex(array: CFTypeRef, index: isize) CFTypeRef;
extern "c" fn CFArrayGetCount(array: CFTypeRef) isize;
extern "c" const kCFTypeDictionaryKeyCallBacks: anyopaque;
extern "c" const kCFTypeDictionaryValueCallBacks: anyopaque;
extern "c" const kCFBooleanTrue: CFTypeRef;
extern "c" const kCFBooleanFalse: CFTypeRef;
const cf_number_sint32: isize = 3;

extern "c" fn CMSampleBufferGetImageBuffer(sb: CFTypeRef) CFTypeRef;
extern "c" fn CMSampleBufferGetPresentationTimeStamp(sb: CFTypeRef) CMTime;
extern "c" fn CMSampleBufferGetDataBuffer(sb: CFTypeRef) CFTypeRef;
extern "c" fn CMSampleBufferGetFormatDescription(sb: CFTypeRef) CFTypeRef;
extern "c" fn CMSampleBufferGetSampleAttachmentsArray(sb: CFTypeRef, create: u8) CFTypeRef;
extern "c" fn CMSampleBufferCreateReady(alloc: ?*anyopaque, data: CFTypeRef, desc: CFTypeRef, num_samples: isize, num_timing: isize, timing: ?*const anyopaque, num_sizes: isize, sizes: ?*const usize, out: *CFTypeRef) OSStatus;
extern "c" fn CMBlockBufferGetDataPointer(bb: CFTypeRef, offset: usize, length_at_offset: ?*usize, total: ?*usize, data: *?[*]u8) OSStatus;
extern "c" fn CMBlockBufferCreateWithMemoryBlock(alloc: ?*anyopaque, memory: ?*anyopaque, length: usize, block_alloc: ?*anyopaque, custom: ?*const anyopaque, offset: usize, data_length: usize, flags: u32, out: *CFTypeRef) OSStatus;
extern "c" fn CMBlockBufferReplaceDataBytes(src: *const anyopaque, dest: CFTypeRef, offset: usize, length: usize) OSStatus;
extern "c" fn CMVideoFormatDescriptionGetH264ParameterSetAtIndex(desc: CFTypeRef, index: usize, ptr: *?[*]const u8, size: *usize, count: ?*usize, nal_header_len: ?*i32) OSStatus;
extern "c" fn CMVideoFormatDescriptionCreateFromH264ParameterSets(alloc: ?*anyopaque, count: usize, ptrs: [*]const [*]const u8, sizes: [*]const usize, nal_header_len: i32, out: *CFTypeRef) OSStatus;
extern "c" fn CMVideoFormatDescriptionGetDimensions(desc: CFTypeRef) CMVideoDimensions;
extern "c" const kCMSampleAttachmentKey_NotSync: CFTypeRef;
extern "c" const kCMSampleAttachmentKey_DisplayImmediately: CFTypeRef;

const VTOutputCallback = *const fn (refcon: ?*anyopaque, frame_refcon: ?*anyopaque, status: OSStatus, flags: u32, sb: CFTypeRef) callconv(.c) void;
extern "c" fn VTCompressionSessionCreate(alloc: ?*anyopaque, w: i32, h: i32, codec: u32, spec: CFTypeRef, source_attrs: CFTypeRef, compressed_alloc: ?*anyopaque, callback: VTOutputCallback, refcon: ?*anyopaque, out: *CFTypeRef) OSStatus;
extern "c" fn VTSessionSetProperty(session: CFTypeRef, key: CFTypeRef, value: CFTypeRef) OSStatus;
extern "c" fn VTCompressionSessionPrepareToEncodeFrames(session: CFTypeRef) OSStatus;
extern "c" fn VTCompressionSessionEncodeFrame(session: CFTypeRef, image: CFTypeRef, pts: CMTime, duration: CMTime, props: CFTypeRef, frame_refcon: ?*anyopaque, flags: ?*u32) OSStatus;
extern "c" fn VTCompressionSessionInvalidate(session: CFTypeRef) void;
extern "c" const kVTCompressionPropertyKey_RealTime: CFTypeRef;
extern "c" const kVTCompressionPropertyKey_ProfileLevel: CFTypeRef;
extern "c" const kVTProfileLevel_H264_Baseline_AutoLevel: CFTypeRef;
extern "c" const kVTCompressionPropertyKey_AverageBitRate: CFTypeRef;
extern "c" const kVTCompressionPropertyKey_MaxKeyFrameInterval: CFTypeRef;
extern "c" const kVTCompressionPropertyKey_AllowFrameReordering: CFTypeRef;
extern "c" const kVTEncodeFrameOptionKey_ForceKeyFrame: CFTypeRef;
const codec_h264: u32 = 0x61766331; // 'avc1'

const AudioStreamBasicDescription = extern struct {
    sample_rate: f64,
    format_id: u32,
    format_flags: u32 = 0,
    bytes_per_packet: u32 = 0,
    frames_per_packet: u32 = 0,
    bytes_per_frame: u32 = 0,
    channels_per_frame: u32,
    bits_per_channel: u32 = 0,
    reserved: u32 = 0,
};
const AudioBuffer = extern struct { channels: u32, size: u32, data: ?*anyopaque };
const AudioBufferList = extern struct { count: u32, buffers: [1]AudioBuffer };
const AudioStreamPacketDescription = extern struct { start: i64, variable_frames: u32, size: u32 };
const AudioComponentDescription = extern struct { type: u32, subtype: u32, manufacturer: u32, flags: u32 = 0, mask: u32 = 0 };
const RenderCallback = *const fn (refcon: ?*anyopaque, flags: *u32, ts: *const anyopaque, bus: u32, frames: u32, data: ?*AudioBufferList) callconv(.c) OSStatus;
const AURenderCallbackStruct = extern struct { proc: RenderCallback, refcon: ?*anyopaque };
const ConverterInput = *const fn (conv: ?*anyopaque, packets: *u32, data: *AudioBufferList, descs: ?*?*AudioStreamPacketDescription, user: ?*anyopaque) callconv(.c) OSStatus;

extern "c" fn AudioComponentFindNext(after: ?*anyopaque, desc: *const AudioComponentDescription) ?*anyopaque;
extern "c" fn AudioComponentInstanceNew(comp: *anyopaque, out: *?*anyopaque) OSStatus;
extern "c" fn AudioComponentInstanceDispose(unit: *anyopaque) OSStatus;
extern "c" fn AudioUnitSetProperty(unit: *anyopaque, prop: u32, scope: u32, element: u32, data: *const anyopaque, size: u32) OSStatus;
extern "c" fn AudioUnitInitialize(unit: *anyopaque) OSStatus;
extern "c" fn AudioOutputUnitStart(unit: *anyopaque) OSStatus;
extern "c" fn AudioOutputUnitStop(unit: *anyopaque) OSStatus;
extern "c" fn AudioUnitRender(unit: *anyopaque, flags: *u32, ts: *const anyopaque, bus: u32, frames: u32, data: *AudioBufferList) OSStatus;
extern "c" fn AudioConverterNew(src: *const AudioStreamBasicDescription, dst: *const AudioStreamBasicDescription, out: *?*anyopaque) OSStatus;
extern "c" fn AudioConverterDispose(conv: *anyopaque) OSStatus;
extern "c" fn AudioConverterFillComplexBuffer(conv: *anyopaque, input: ConverterInput, user: ?*anyopaque, packets: *u32, out: *AudioBufferList, descs: ?*AudioStreamPacketDescription) OSStatus;
extern "c" fn usleep(us: c_uint) c_int;

fn fourcc(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}
const pcm_format: AudioStreamBasicDescription = .{
    .sample_rate = 48000,
    .format_id = fourcc("lpcm"),
    .format_flags = 4 | 8, // signed integer, packed
    .bytes_per_packet = 2,
    .frames_per_packet = 1,
    .bytes_per_frame = 2,
    .channels_per_frame = 1,
    .bits_per_channel = 16,
};
const opus_format: AudioStreamBasicDescription = .{ .sample_rate = 48000, .format_id = fourcc("opus"), .frames_per_packet = 960, .channels_per_frame = 1 };

// AVFoundation string constants.
extern "c" const AVMediaTypeVideo: id;
extern "c" const AVMediaTypeAudio: id;
extern "c" const AVCaptureSessionPreset640x480: id;
extern "c" const AVCaptureSessionPreset352x288: id;
extern "c" fn CVPixelBufferGetWidth(buf: CFTypeRef) usize;
extern "c" fn CVPixelBufferGetHeight(buf: CFTypeRef) usize;
extern "c" const AVCaptureDeviceTypeBuiltInWideAngleCamera: id;
extern "c" const AVLayerVideoGravityResizeAspectFill: id;
extern "c" const AVLayerVideoGravityResizeAspect: id;
extern "c" const AVAudioSessionCategoryPlayAndRecord: id;
extern "c" const AVAudioSessionModeVideoChat: id;
extern "c" const kCVPixelBufferPixelFormatTypeKey: id;

// ---- state ----------------------------------------------------------------------------------

const gpa = zui.allocator;
const width = 640;
const height = 480;
const frame_samples = 960;

const Mutex = struct {
    m: std.c.pthread_mutex_t = .{},
    fn lock(x: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&x.m);
    }
    fn unlock(x: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&x.m);
    }
};

const Local = struct {
    id: u32,
    want_audio: bool,
    want_video: bool,
    back: bool,
    ready: bool = false,
    audio_on: std.atomic.Value(bool) = .init(true),
    video_on: std.atomic.Value(bool) = .init(true),
    want_key: std.atomic.Value(bool) = .init(true),
    session: id = null,
    output: id = null,
    encoder: CFTypeRef = null,
    opus: ?*anyopaque = null,
    mic_ring: common.Ring = .{},
    pending_permissions: u8 = 0,
    // Bitrate adaptation (see `adapt`).
    rates: [8]Rate = undefined,
    rate_count: usize = 0,
    bps: u32 = 900_000,
    applied_bps: u32 = 0,
    level: usize = 0,
    level_changed_at: i64 = 0,
    clean_since: i64 = 0,
    adapted_at: i64 = 0,
    enc_w: i32 = width,
    enc_h: i32 = height,
};

const Rate = struct { peer: u32, bps: u32, loss: f32 };

const Remote = struct {
    id: u32,
    format: CFTypeRef = null,
    rotation: u16 = 0,
    width: i32 = 0,
    height: i32 = 0,
    slot: usize,
    opus: ?*anyopaque = null,
    last_key_request: i64 = 0,
};

const VideoView = struct {
    view: id,
    stream: u32 = 0,
    mirror: bool = false,
    cover: bool = true,
    layer: id = null,
};

var hooks: calls.MediaHooks = undefined;
var pump_fn: ?*const fn () void = null;
var mutex: Mutex = .{};
var locals: std.ArrayList(*Local) = .empty;
var remotes: std.ArrayList(*Remote) = .empty;
/// By host view id; main thread only.
var video_views: std.AutoHashMapUnmanaged(u32, VideoView) = .empty;
var capture_queue: ?Queue = null;
var capture_delegate: id = null;

var inbound_lock: calls.SpinLock = .{};
var inbound_audio: std.ArrayList(struct { stream: u32, data: []u8 }) = .empty;

const max_remotes = 8;
var playback: [max_remotes]common.Ring = @splat(.{});
var slot_used: [max_remotes]std.atomic.Value(bool) = @splat(.init(false));
var voice_unit: ?*anyopaque = null;
var audio_users: u32 = 0;
/// The local stream whose microphone the voice unit feeds (one at a time).
var mic_target: std.atomic.Value(?*Local) = .init(null);
var worker_running = false;

// ---- set up by the host --------------------------------------------------------------------

/// Classes this backend needs; the host calls it once at start, before views exist.
pub fn defineClasses() void {
    objc.defineClass("ZuiCaptureDelegate", "NSObject", &.{"AVCaptureVideoDataOutputSampleBufferDelegate"}, &.{
        .{ "captureOutput:didOutputSampleBuffer:fromConnection:", @ptrCast(&captured), "v@:@@@" },
    });
    objc.defineClass("ZuiVideoView", "UIView", &.{}, &.{
        .{ "layoutSubviews", @ptrCast(&videoLayout), "v@:" },
    });
}

/// The runtime's pump (R.callsPump), called on the main thread after `wake`.
pub fn setPump(f: *const fn () void) void {
    pump_fn = f;
}

// ---- the backend interface (zui/calls.zig) --------------------------------------------------

pub fn init(h: calls.MediaHooks) void {
    hooks = h;
    capture_queue = dispatch_queue_create("zui.capture", null);
    capture_delegate = objc.new("ZuiCaptureDelegate");
}

fn pumpOnMain(_: ?*anyopaque) callconv(.c) void {
    if (pump_fn) |f| f();
}

pub fn wake() void {
    dispatch_async_f(mainQueue(), null, pumpOnMain);
}

pub fn open(stream: u32, m: zui.Media) void {
    if (m.screen) return hooks.event(stream, .failed, "unsupported");
    const l = gpa.create(Local) catch return hooks.event(stream, .failed, "unavailable");
    l.* = .{ .id = stream, .want_audio = m.audio, .want_video = m.video, .back = m.back_camera };
    mutex.lock();
    locals.append(gpa, l) catch {};
    mutex.unlock();
    askPermissions(l);
}

pub fn enable(stream: u32, audio: bool, video: bool) void {
    mutex.lock();
    defer mutex.unlock();
    const l = findLocal(stream) orelse return;
    l.audio_on.store(audio, .release);
    l.video_on.store(video, .release);
}

pub fn switchCamera(stream: u32) void {
    mutex.lock();
    const l = findLocal(stream);
    mutex.unlock();
    const x = l orelse return;
    if (!x.want_video or x.session == null) return;
    x.back = !x.back;
    objc.sendVoid(x.session, "beginConfiguration");
    const inputs = objc.send(x.session, "inputs");
    const count: usize = @intCast(objc.sendInt(inputs, "count"));
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const input = objc.msgSend(*const fn (id, objc.SEL, usize) callconv(.c) id)(inputs, objc.sel("objectAtIndex:"), i);
        if (objc.msgSend(*const fn (id, objc.SEL, id) callconv(.c) bool)(input, objc.sel("hasMediaType:"), AVMediaTypeVideo)) {
            objc.sendVoid1(x.session, "removeInput:", input);
            break;
        }
    }
    if (cameraInput(x.back)) |input| objc.sendVoid1(x.session, "addInput:", input);
    objc.sendVoid(x.session, "commitConfiguration");
    x.want_key.store(true, .release);
}

pub fn close(stream: u32) void {
    mutex.lock();
    var found: ?*Local = null;
    for (locals.items, 0..) |l, i| if (l.id == stream) {
        found = l;
        _ = locals.swapRemove(i);
        break;
    };
    mutex.unlock();
    const l = found orelse return;
    if (mic_target.load(.acquire) == l) mic_target.store(null, .release);
    if (l.session) |s| {
        objc.sendVoid(s, "stopRunning");
        objc.release(s);
    }
    if (l.encoder) |e| {
        VTCompressionSessionInvalidate(e);
        CFRelease(e);
    }
    if (l.opus) |c| _ = AudioConverterDispose(c);
    if (l.ready and l.want_audio) audioUsers(false);
    // The capture queue may still hold a frame for this stream: let it drain first.
    if (capture_queue) |q| dispatch_async_f(q, l, freeLocal) else gpa.destroy(l);
}

fn freeLocal(ctx: ?*anyopaque) callconv(.c) void {
    gpa.destroy(@as(*Local, @ptrCast(@alignCast(ctx.?))));
}

pub fn openRemote(stream: u32) void {
    const slot = for (&slot_used, 0..) |*u, i| {
        if (u.cmpxchgStrong(false, true, .acq_rel, .monotonic) == null) break i;
    } else return;
    playback[slot].reset();
    const r = gpa.create(Remote) catch return;
    r.* = .{ .id = stream, .slot = slot };
    var conv: ?*anyopaque = null;
    if (AudioConverterNew(&opus_format, &pcm_format, &conv) == 0) r.opus = conv;
    mutex.lock();
    remotes.append(gpa, r) catch {};
    mutex.unlock();
    audioUsers(true);
    startWorker();
}

pub fn closeRemote(stream: u32) void {
    mutex.lock();
    var found: ?*Remote = null;
    for (remotes.items, 0..) |r, i| if (r.id == stream) {
        found = r;
        _ = remotes.swapRemove(i);
        break;
    };
    mutex.unlock();
    const r = found orelse return;
    slot_used[r.slot].store(false, .release);
    if (r.opus) |c| _ = AudioConverterDispose(c);
    if (r.format) |f| CFRelease(f);
    gpa.destroy(r);
    audioUsers(false);
}

pub fn remoteAudio(stream: u32, packet: []const u8) void {
    const copy = gpa.dupe(u8, packet) catch return;
    inbound_lock.lock();
    defer inbound_lock.unlock();
    if (inbound_audio.items.len > 100) return gpa.free(copy);
    inbound_audio.append(gpa, .{ .stream = stream, .data = copy }) catch gpa.free(copy);
}

/// Engine threads: an H.264 access unit becomes a sample buffer for the display layers.
pub fn remoteVideo(stream: u32, annexb: []const u8, keyframe: bool, rotation: u16) void {
    mutex.lock();
    defer mutex.unlock();
    const r = findRemote(stream) orelse return;
    r.rotation = rotation;
    if (keyframe) updateFormat(r, annexb);
    const format = r.format orelse {
        const now = nowMs();
        if (now - r.last_key_request > 500) {
            r.last_key_request = now;
            hooks.need_keyframe(stream);
        }
        return;
    };
    const sb = sampleBuffer(format, annexb) orelse return;
    const job = gpa.create(Enqueue) catch {
        CFRelease(sb);
        return;
    };
    job.* = .{ .stream = stream, .sample = sb, .rotation = rotation, .width = r.width, .height = r.height };
    dispatch_async_f(mainQueue(), job, enqueueOnMain);
}

/// The engine's target for what connection `peer` sends of local stream `stream` (0: gone).
/// The encoder follows the lowest.
pub fn setBitrate(stream: u32, peer: u32, bps: u32, loss: f32) void {
    mutex.lock();
    defer mutex.unlock();
    const l = findLocal(stream) orelse return;
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

pub fn requestKeyframe(stream: u32) void {
    mutex.lock();
    defer mutex.unlock();
    if (findLocal(stream)) |l| l.want_key.store(true, .release);
}

fn findLocal(stream: u32) ?*Local {
    for (locals.items) |l| if (l.id == stream) return l;
    return null;
}

fn findRemote(stream: u32) ?*Remote {
    for (remotes.items) |r| if (r.id == stream) return r;
    return null;
}

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, std.time.ns_per_ms);
}

// ---- permissions ----------------------------------------------------------------------------

/// AVAuthorizationStatusNotDetermined / Authorized
const auth_not_determined: isize = 0;
const auth_authorized: isize = 3;

const AccessBlock = extern struct { header: objc.BlockHeader, stream: u32 };
const access_descriptor: objc.BlockDescriptor = .{ .size = @sizeOf(AccessBlock) };

fn authorization(media_type: id) isize {
    return objc.msgSend(*const fn (id, objc.SEL, id) callconv(.c) isize)(objc.class("AVCaptureDevice"), objc.sel("authorizationStatusForMediaType:"), media_type);
}

/// Asks for what is not decided yet, one at a time; `permissionsSettled` then starts the media.
fn askPermissions(l: *Local) void {
    const pending: ?id = if (l.want_video and authorization(AVMediaTypeVideo) == auth_not_determined)
        AVMediaTypeVideo
    else if (l.want_audio and authorization(AVMediaTypeAudio) == auth_not_determined)
        AVMediaTypeAudio
    else
        null;
    const media_type = pending orelse return permissionsSettled(l.id);
    // A heap block (freed after its call) carrying the stream: iOS calls it on any thread.
    const b = gpa.create(AccessBlock) catch return hooks.event(l.id, .failed, "unavailable");
    b.* = .{ .header = .{ .isa = &objc._NSConcreteGlobalBlock, .invoke = @ptrCast(&accessDone), .descriptor = &access_descriptor }, .stream = l.id };
    objc.msgSend(*const fn (id, objc.SEL, id, *AccessBlock) callconv(.c) void)(objc.class("AVCaptureDevice"), objc.sel("requestAccessForMediaType:completionHandler:"), media_type, b);
}

fn accessDone(b: *AccessBlock, _: bool) callconv(.c) void {
    dispatch_async_f(mainQueue(), b, accessOnMain);
}

fn accessOnMain(ctx: ?*anyopaque) callconv(.c) void {
    const b: *AccessBlock = @ptrCast(@alignCast(ctx.?));
    const stream = b.stream;
    gpa.destroy(b);
    mutex.lock();
    const l = findLocal(stream);
    mutex.unlock();
    if (l) |x| askPermissions(x);
}

fn permissionsSettled(stream: u32) void {
    mutex.lock();
    const found = findLocal(stream);
    mutex.unlock();
    const l = found orelse return;
    if ((l.want_video and authorization(AVMediaTypeVideo) != auth_authorized) or
        (l.want_audio and authorization(AVMediaTypeAudio) != auth_authorized))
        return hooks.event(stream, .failed, "denied");
    if (l.want_video and !startCamera(l)) return hooks.event(stream, .failed, "unavailable");
    if (l.want_audio) {
        var conv: ?*anyopaque = null;
        if (AudioConverterNew(&pcm_format, &opus_format, &conv) != 0) return hooks.event(stream, .failed, "unavailable");
        l.opus = conv;
        mic_target.store(l, .release);
        audioUsers(true);
    }
    l.ready = true;
    startWorker();
    hooks.event(stream, .ready, "");
}

// ---- camera and encoder -----------------------------------------------------------------------

fn cameraInput(back: bool) ?id {
    const position: isize = if (back) 1 else 2;
    const device = objc.msgSend(*const fn (id, objc.SEL, id, id, isize) callconv(.c) id)(
        objc.class("AVCaptureDevice"),
        objc.sel("defaultDeviceWithDeviceType:mediaType:position:"),
        AVCaptureDeviceTypeBuiltInWideAngleCamera,
        AVMediaTypeVideo,
        position,
    ) orelse return null;
    var err: id = null;
    return objc.msgSend(*const fn (id, objc.SEL, id, *id) callconv(.c) id)(objc.class("AVCaptureDeviceInput"), objc.sel("deviceInputWithDevice:error:"), device, &err);
}

fn startCamera(l: *Local) bool {
    const session = objc.new("AVCaptureSession");
    objc.sendVoid1(session, "setSessionPreset:", AVCaptureSessionPreset640x480);
    const input = cameraInput(l.back) orelse {
        objc.release(session);
        return false;
    };
    objc.sendVoid1(session, "addInput:", input);
    const output = objc.new("AVCaptureVideoDataOutput");
    // NV12, what VideoToolbox's encoder takes without converting.
    const format = objc.msgSend(*const fn (id, objc.SEL, u32) callconv(.c) id)(objc.class("NSNumber"), objc.sel("numberWithUnsignedInt:"), fourcc("420v"));
    const settings = objc.msgSend(*const fn (id, objc.SEL, id, id) callconv(.c) id)(objc.class("NSDictionary"), objc.sel("dictionaryWithObject:forKey:"), format, kCVPixelBufferPixelFormatTypeKey);
    objc.sendVoid1(output, "setVideoSettings:", settings);
    objc.sendVoidBool(output, "setAlwaysDiscardsLateVideoFrames:", true);
    objc.msgSend(*const fn (id, objc.SEL, id, Queue) callconv(.c) void)(output, objc.sel("setSampleBufferDelegate:queue:"), capture_delegate, capture_queue.?);
    objc.sendVoid1(session, "addOutput:", output);
    l.session = session;
    l.output = output;

    l.encoder = newEncoder(l, width, height) orelse return false;
    // startRunning blocks: off the main thread.
    dispatch_async_f(capture_queue.?, session, startRunning);
    return true;
}

fn newEncoder(l: *Local, w: i32, h: i32) CFTypeRef {
    var encoder: CFTypeRef = null;
    if (VTCompressionSessionCreate(null, w, h, codec_h264, null, null, null, encoded, l, &encoder) != 0) return null;
    _ = VTSessionSetProperty(encoder, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    _ = VTSessionSetProperty(encoder, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
    _ = VTSessionSetProperty(encoder, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    setInt(encoder, kVTCompressionPropertyKey_AverageBitRate, @intCast(l.bps));
    setInt(encoder, kVTCompressionPropertyKey_MaxKeyFrameInterval, 90);
    _ = VTCompressionSessionPrepareToEncodeFrames(encoder);
    l.enc_w = w;
    l.enc_h = h;
    return encoder;
}

/// Follows the engine's target: the encoder's bitrate at once, and the capture size with
/// hysteresis (640x480 down to 352x288 on loss or a very low target, back after 10 quiet
/// seconds). Runs on the capture queue.
fn adapt(l: *Local, now: i64) void {
    if (now < l.adapted_at + 500) return;
    l.adapted_at = now;
    mutex.lock();
    var bps: u32 = std.math.maxInt(u32);
    var loss: f32 = 0;
    for (l.rates[0..l.rate_count]) |r| {
        bps = @min(bps, r.bps);
        loss = @max(loss, r.loss);
    }
    const count = l.rate_count;
    mutex.unlock();
    if (count == 0) return;
    l.bps = bps;
    if (l.encoder != null and (l.applied_bps == 0 or bps * 20 < l.applied_bps * 19 or bps * 20 > l.applied_bps * 21)) {
        setInt(l.encoder, kVTCompressionPropertyKey_AverageBitRate, @intCast(bps));
        l.applied_bps = bps;
    }
    if (loss >= 0.02) l.clean_since = now;
    if (now < l.level_changed_at + 3000 or l.session == null) return;
    var next = l.level;
    if (l.level == 0 and ((loss >= 0.05 and bps < 450_000) or bps < 200_000)) next = 1;
    if (l.level == 1 and bps >= 550_000 and now >= l.clean_since + 10_000) next = 0;
    if (next == l.level) return;
    l.level = next;
    l.level_changed_at = now;
    objc.sendVoid(l.session, "beginConfiguration");
    objc.sendVoid1(l.session, "setSessionPreset:", if (next == 0) AVCaptureSessionPreset640x480 else AVCaptureSessionPreset352x288);
    objc.sendVoid(l.session, "commitConfiguration");
    // The next frame has the new size: `captured` makes a new encoder for it.
}

fn setInt(session: CFTypeRef, key: CFTypeRef, v: i32) void {
    const n = CFNumberCreate(null, cf_number_sint32, &v);
    defer CFRelease(n);
    _ = VTSessionSetProperty(session, key, n);
}

fn startRunning(ctx: ?*anyopaque) callconv(.c) void {
    objc.sendVoid(@ptrCast(ctx), "startRunning");
}

/// AVCaptureVideoDataOutput delegate, on the capture queue: a camera frame into the encoder.
fn captured(_: id, _: objc.SEL, output: id, sample: CFTypeRef, _: id) callconv(.c) void {
    mutex.lock();
    var target: ?*Local = null;
    for (locals.items) |l| if (l.output == output) {
        target = l;
    };
    mutex.unlock();
    const l = target orelse return;
    if (!l.video_on.load(.acquire)) return;
    const image = CMSampleBufferGetImageBuffer(sample) orelse return;
    adapt(l, nowMs());
    const w: i32 = @intCast(CVPixelBufferGetWidth(image));
    const h: i32 = @intCast(CVPixelBufferGetHeight(image));
    if (w != l.enc_w or h != l.enc_h) {
        // Another capture size: a new encoder for it (it starts with a keyframe).
        if (l.encoder) |e| {
            VTCompressionSessionInvalidate(e);
            CFRelease(e);
        }
        l.encoder = newEncoder(l, w, h);
        l.applied_bps = l.bps;
        if (l.encoder == null) return;
    }
    var props: CFTypeRef = null;
    if (l.want_key.swap(false, .acq_rel)) {
        const keys = [_]CFTypeRef{kVTEncodeFrameOptionKey_ForceKeyFrame};
        const values = [_]CFTypeRef{kCFBooleanTrue};
        props = CFDictionaryCreate(null, &keys, &values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
    defer if (props) |p| CFRelease(p);
    const invalid: CMTime = .{ .value = 0, .timescale = 0, .flags = 0, .epoch = 0 };
    _ = VTCompressionSessionEncodeFrame(l.encoder, image, CMSampleBufferGetPresentationTimeStamp(sample), invalid, props, null, null);
}

/// VideoToolbox output: AVCC (length-prefixed) into Annex-B, SPS/PPS in front of keyframes.
fn encoded(refcon: ?*anyopaque, _: ?*anyopaque, status: OSStatus, _: u32, sample: CFTypeRef) callconv(.c) void {
    if (status != 0 or sample == null) return;
    const l: *Local = @ptrCast(@alignCast(refcon.?));
    const attachments = CMSampleBufferGetSampleAttachmentsArray(sample, 0);
    const key = attachments == null or CFArrayGetCount(attachments) == 0 or
        CFDictionaryContainsKey(CFArrayGetValueAtIndex(attachments, 0), kCMSampleAttachmentKey_NotSync) == 0;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const start_code = [_]u8{ 0, 0, 0, 1 };
    if (key) {
        const desc = CMSampleBufferGetFormatDescription(sample);
        var i: usize = 0;
        while (i < 2) : (i += 1) {
            var ptr: ?[*]const u8 = null;
            var size: usize = 0;
            if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(desc, i, &ptr, &size, null, null) != 0) break;
            out.appendSlice(gpa, &start_code) catch return;
            out.appendSlice(gpa, ptr.?[0..size]) catch return;
        }
    }
    const block = CMSampleBufferGetDataBuffer(sample) orelse return;
    var total: usize = 0;
    var data: ?[*]u8 = null;
    if (CMBlockBufferGetDataPointer(block, 0, null, &total, &data) != 0) return;
    var pos: usize = 0;
    while (pos + 4 <= total) {
        const n = std.mem.readInt(u32, data.?[pos..][0..4], .big);
        pos += 4;
        if (pos + n > total) break;
        out.appendSlice(gpa, &start_code) catch return;
        out.appendSlice(gpa, data.?[pos..][0..n]) catch return;
        pos += n;
    }
    const pts = CMSampleBufferGetPresentationTimeStamp(sample);
    const ts: u32 = if (pts.timescale > 0) @truncate(@as(u64, @bitCast(@divTrunc(pts.value * 90000, pts.timescale)))) else 0;
    // Portrait use: the camera delivers landscape pictures; the receiver turns them upright.
    hooks.video(l.id, out.items, ts, 90);
}

// ---- remote video: AVSampleBufferDisplayLayer -------------------------------------------------

const Enqueue = struct { stream: u32, sample: CFTypeRef, rotation: u16, width: i32, height: i32 };

/// New SPS/PPS: a new format description (and the picture size).
fn updateFormat(r: *Remote, annexb: []const u8) void {
    var sps: ?[]const u8 = null;
    var pps: ?[]const u8 = null;
    var it = Nals{ .data = annexb };
    while (it.next()) |nal| switch (nal[0] & 0x1f) {
        7 => sps = nal,
        8 => pps = nal,
        else => {},
    };
    const s = sps orelse return;
    const p = pps orelse return;
    const ptrs = [_][*]const u8{ s.ptr, p.ptr };
    const sizes = [_]usize{ s.len, p.len };
    var desc: CFTypeRef = null;
    if (CMVideoFormatDescriptionCreateFromH264ParameterSets(null, 2, &ptrs, &sizes, 4, &desc) != 0) return;
    if (r.format) |old| CFRelease(old);
    r.format = desc;
    const dims = CMVideoFormatDescriptionGetDimensions(desc);
    r.width = dims.width;
    r.height = dims.height;
}

const Nals = struct {
    data: []const u8,
    pos: usize = 0,

    fn next(it: *Nals) ?[]const u8 {
        var i = it.pos;
        while (i + 3 <= it.data.len and !(it.data[i] == 0 and it.data[i + 1] == 0 and it.data[i + 2] == 1)) i += 1;
        if (i + 3 > it.data.len) return null;
        const start = i + 3;
        var j = start;
        while (j + 3 <= it.data.len and !(it.data[j] == 0 and it.data[j + 1] == 0 and (it.data[j + 2] == 1 or (it.data[j + 2] == 0 and j + 3 < it.data.len and it.data[j + 3] == 1)))) j += 1;
        const end = if (j + 3 <= it.data.len) j else it.data.len;
        it.pos = end;
        if (end <= start) return it.next();
        return it.data[start..end];
    }
};

/// The access unit's slices as AVCC in a sample buffer, flagged to show at once.
fn sampleBuffer(format: CFTypeRef, annexb: []const u8) CFTypeRef {
    var avcc: std.ArrayList(u8) = .empty;
    defer avcc.deinit(gpa);
    var it = Nals{ .data = annexb };
    while (it.next()) |nal| {
        const t = nal[0] & 0x1f;
        if (t == 7 or t == 8 or t == 9) continue; // parameter sets live in the format
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(nal.len), .big);
        avcc.appendSlice(gpa, &len) catch return null;
        avcc.appendSlice(gpa, nal) catch return null;
    }
    if (avcc.items.len == 0) return null;
    var block: CFTypeRef = null;
    if (CMBlockBufferCreateWithMemoryBlock(null, null, avcc.items.len, null, null, 0, avcc.items.len, 0, &block) != 0) return null;
    defer CFRelease(block);
    if (CMBlockBufferReplaceDataBytes(avcc.items.ptr, block, 0, avcc.items.len) != 0) return null;
    var sample: CFTypeRef = null;
    const size: usize = avcc.items.len;
    if (CMSampleBufferCreateReady(null, block, format, 1, 0, null, 1, &size, &sample) != 0) return null;
    const attachments = CMSampleBufferGetSampleAttachmentsArray(sample, 1);
    if (attachments != null and CFArrayGetCount(attachments) > 0)
        CFDictionarySetValue(CFArrayGetValueAtIndex(attachments, 0), kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    return sample;
}

fn enqueueOnMain(ctx: ?*anyopaque) callconv(.c) void {
    const job: *Enqueue = @ptrCast(@alignCast(ctx.?));
    defer {
        CFRelease(job.sample);
        gpa.destroy(job);
    }
    var it = video_views.iterator();
    while (it.next()) |e| {
        const v = e.value_ptr;
        if (v.stream != job.stream or v.layer == null) continue;
        // A layer that failed (decoder reset) is flushed and needs a keyframe.
        if (objc.sendInt(v.layer, "status") == 2) {
            objc.sendVoid(v.layer, "flush");
            hooks.need_keyframe(job.stream);
        }
        objc.sendVoid1(v.layer, "enqueueSampleBuffer:", @ptrCast(job.sample));
        if (rotations.get(job.stream) != job.rotation) {
            rotations.put(gpa, job.stream, job.rotation) catch {};
            objc.sendVoid(v.view, "setNeedsLayout");
        }
    }
}

/// Last rotation seen per remote stream (main thread).
var rotations: std.AutoHashMapUnmanaged(u32, u16) = .empty;

// ---- video views (the host calls these on the main thread) ------------------------------------

/// The view the host creates for `ui.video`.
pub fn createView() id {
    return objc.new("ZuiVideoView");
}

pub fn bindView(view_id: u32, view: id, v: zui.Video) void {
    const gop = video_views.getOrPut(gpa, view_id) catch return;
    if (!gop.found_existing) gop.value_ptr.* = .{ .view = view };
    const vv = gop.value_ptr;
    if (vv.stream != v.stream) {
        if (vv.layer) |l| {
            objc.sendVoid(l, "removeFromSuperlayer");
            objc.release(l);
        }
        vv.layer = null;
        vv.stream = v.stream;
        if (v.stream >= calls.remote_stream_base) {
            vv.layer = objc.new("AVSampleBufferDisplayLayer");
            hooks.need_keyframe(v.stream); // a new viewer starts at a keyframe
        } else {
            mutex.lock();
            const session = if (findLocal(v.stream)) |l| l.session else null;
            mutex.unlock();
            if (session) |s| {
                const preview = objc.send1(objc.class("AVCaptureVideoPreviewLayer"), "layerWithSession:", s);
                vv.layer = objc.send(preview, "retain");
            }
        }
        if (vv.layer) |l| objc.sendVoid1(objc.send(view, "layer"), "addSublayer:", l);
    }
    vv.mirror = v.mirror;
    vv.cover = v.cover;
    if (vv.layer) |l| {
        objc.sendVoid1(l, "setVideoGravity:", if (v.cover) AVLayerVideoGravityResizeAspectFill else AVLayerVideoGravityResizeAspect);
        if (v.stream < calls.remote_stream_base) {
            // The preview mirrors exactly when asked, like the web.
            const conn = objc.send(l, "connection");
            if (conn != null) {
                objc.sendVoidBool(conn, "setAutomaticallyAdjustsVideoMirroring:", false);
                objc.sendVoidBool(conn, "setVideoMirrored:", v.mirror);
            }
        }
    }
    objc.sendVoid(view, "setNeedsLayout");
}

pub fn unbindView(view_id: u32) void {
    const kv = video_views.fetchRemove(view_id) orelse return;
    if (kv.value.layer) |l| {
        objc.sendVoid(l, "removeFromSuperlayer");
        objc.release(l);
    }
}

/// ZuiVideoView -layoutSubviews: the video layer fills the view, turned (and mirrored) for
/// remote pictures.
fn videoLayout(self: id, _: objc.SEL) callconv(.c) void {
    objc.sendSuper(self, "ZuiVideoView", "layoutSubviews");
    var it = video_views.iterator();
    while (it.next()) |e| {
        const v = e.value_ptr;
        if (v.view != self) continue;
        const layer = v.layer orelse return;
        const bounds = objc.msgSend(*const fn (id, objc.SEL) callconv(.c) objc.CGRect)(self, objc.sel("bounds"));
        const remote = v.stream >= calls.remote_stream_base;
        const rotation: u16 = if (remote) rotations.get(v.stream) orelse 0 else 0;
        const sideways = rotation % 180 != 0;
        const set_rect = objc.msgSend(*const fn (id, objc.SEL, objc.CGRect) callconv(.c) void);
        set_rect(layer, objc.sel("setBounds:"), .{ .w = if (sideways) bounds.h else bounds.w, .h = if (sideways) bounds.w else bounds.h });
        objc.msgSend(*const fn (id, objc.SEL, objc.CGPoint) callconv(.c) void)(layer, objc.sel("setPosition:"), .{ .x = bounds.w / 2, .y = bounds.h / 2 });
        const angle = @as(f64, @floatFromInt(rotation)) * std.math.pi / 180.0;
        const sx: f64 = if (remote and v.mirror) -1 else 1;
        const t: CGAffineTransform = .{ .a = @cos(angle) * sx, .b = @sin(angle) * sx, .c = -@sin(angle), .d = @cos(angle), .tx = 0, .ty = 0 };
        objc.msgSend(*const fn (id, objc.SEL, CGAffineTransform) callconv(.c) void)(layer, objc.sel("setAffineTransform:"), t);
        return;
    }
}

// ---- audio: VoiceProcessingIO + AudioConverter (Opus) -----------------------------------------

const scope_global = 0;
const scope_input = 1;
const scope_output = 2;
const prop_stream_format = 8;
const prop_render_callback = 23;
const prop_enable_io = 2003;
const prop_input_callback = 2005;

fn audioUsers(on: bool) void {
    mutex.lock();
    const before = audio_users;
    audio_users = if (on) audio_users + 1 else audio_users -| 1;
    const after = audio_users;
    mutex.unlock();
    if (before == 0 and after > 0) {
        startVoiceUnit();
    } else if (before > 0 and after == 0) {
        if (voice_unit) |u| {
            _ = AudioOutputUnitStop(u);
            _ = AudioComponentInstanceDispose(u);
        }
        voice_unit = null;
    }
}

fn startVoiceUnit() void {
    // The call audio session: play and record, voice/video chat processing, the loudspeaker.
    const session = objc.send(objc.class("AVAudioSession"), "sharedInstance");
    var err: id = null;
    _ = objc.msgSend(*const fn (id, objc.SEL, id, id, usize, *id) callconv(.c) bool)(session, objc.sel("setCategory:mode:options:error:"), AVAudioSessionCategoryPlayAndRecord, AVAudioSessionModeVideoChat, 8, &err); // AllowBluetooth
    _ = objc.msgSend(*const fn (id, objc.SEL, bool, *id) callconv(.c) bool)(session, objc.sel("setActive:error:"), true, &err);

    const desc: AudioComponentDescription = .{ .type = fourcc("auou"), .subtype = fourcc("vpio"), .manufacturer = fourcc("appl") };
    const comp = AudioComponentFindNext(null, &desc) orelse return;
    var unit: ?*anyopaque = null;
    if (AudioComponentInstanceNew(comp, &unit) != 0) return;
    const u = unit.?;
    const one: u32 = 1;
    _ = AudioUnitSetProperty(u, prop_enable_io, scope_input, 1, &one, 4); // microphone on bus 1
    _ = AudioUnitSetProperty(u, prop_enable_io, scope_output, 0, &one, 4); // speaker on bus 0
    _ = AudioUnitSetProperty(u, prop_stream_format, scope_output, 1, &pcm_format, @sizeOf(AudioStreamBasicDescription));
    _ = AudioUnitSetProperty(u, prop_stream_format, scope_input, 0, &pcm_format, @sizeOf(AudioStreamBasicDescription));
    const input_cb: AURenderCallbackStruct = .{ .proc = micCallback, .refcon = null };
    _ = AudioUnitSetProperty(u, prop_input_callback, scope_global, 1, &input_cb, @sizeOf(AURenderCallbackStruct));
    const render_cb: AURenderCallbackStruct = .{ .proc = speakerCallback, .refcon = null };
    _ = AudioUnitSetProperty(u, prop_render_callback, scope_input, 0, &render_cb, @sizeOf(AURenderCallbackStruct));
    if (AudioUnitInitialize(u) != 0 or AudioOutputUnitStart(u) != 0) {
        _ = AudioComponentInstanceDispose(u);
        return;
    }
    voice_unit = u;
}

var mic_buf: [4096]i16 = undefined;

fn micCallback(_: ?*anyopaque, flags: *u32, ts: *const anyopaque, bus: u32, frames: u32, _: ?*AudioBufferList) callconv(.c) OSStatus {
    const u = voice_unit orelse return 0;
    const n = @min(frames, mic_buf.len);
    var list: AudioBufferList = .{ .count = 1, .buffers = .{.{ .channels = 1, .size = n * 2, .data = &mic_buf }} };
    if (AudioUnitRender(u, flags, ts, bus, n, &list) != 0) return 0;
    if (mic_target.load(.acquire)) |l| l.mic_ring.write(mic_buf[0..n]);
    return 0;
}

fn speakerCallback(_: ?*anyopaque, _: *u32, _: *const anyopaque, _: u32, frames: u32, data: ?*AudioBufferList) callconv(.c) OSStatus {
    const list = data orelse return 0;
    const out: [*]i16 = @ptrCast(@alignCast(list.buffers[0].data orelse return 0));
    const n: usize = frames;
    @memset(out[0..n], 0);
    var tmp: [1024]i16 = undefined;
    for (&playback, &slot_used) |*ring, *used| {
        if (!used.load(.acquire)) continue;
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

/// Input for one AudioConverterFillComplexBuffer call: a PCM frame or an Opus packet.
const ConvInput = struct {
    data: []const u8,
    packet_desc: AudioStreamPacketDescription = .{ .start = 0, .variable_frames = 0, .size = 0 },
    used: bool = false,
    is_packet: bool,
};

fn converterInput(_: ?*anyopaque, packets: *u32, data: *AudioBufferList, descs: ?*?*AudioStreamPacketDescription, user: ?*anyopaque) callconv(.c) OSStatus {
    const in: *ConvInput = @ptrCast(@alignCast(user.?));
    if (in.used) {
        packets.* = 0;
        return 1; // no more input for now
    }
    in.used = true;
    data.count = 1;
    data.buffers[0] = .{ .channels = 1, .size = @intCast(in.data.len), .data = @constCast(in.data.ptr) };
    if (in.is_packet) {
        packets.* = 1;
        in.packet_desc.size = @intCast(in.data.len);
        if (descs) |d| d.* = &in.packet_desc;
    } else {
        packets.* = @intCast(in.data.len / 2);
    }
    return 0;
}

fn startWorker() void {
    mutex.lock();
    defer mutex.unlock();
    if (worker_running) return;
    // pthreads directly: std.Thread's error path reaches std.debug, whose default Io does not
    // compile for iOS.
    var t: std.c.pthread_t = undefined;
    if (std.c.pthread_create(&t, null, workerEntry, null) != .SUCCESS) return;
    _ = std.c.pthread_detach(t);
    worker_running = true;
}

fn workerEntry(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    worker();
    return null;
}

/// Opus encoding of the microphone and decoding of received packets.
fn worker() void {
    while (true) {
        mutex.lock();
        if (locals.items.len == 0 and remotes.items.len == 0) {
            worker_running = false;
            mutex.unlock();
            return;
        }
        mutex.unlock();
        encodeMicrophone();
        decodeReceived();
        _ = usleep(5000);
    }
}

fn encodeMicrophone() void {
    const l = mic_target.load(.acquire) orelse return;
    const conv = l.opus orelse return;
    var pcm: [frame_samples]i16 = undefined;
    while (l.mic_ring.available() >= frame_samples) {
        _ = l.mic_ring.read(&pcm);
        if (!l.audio_on.load(.acquire)) @memset(&pcm, 0);
        var in: ConvInput = .{ .data = std.mem.sliceAsBytes(&pcm), .is_packet = false };
        var out_bytes: [1500]u8 = undefined;
        var list: AudioBufferList = .{ .count = 1, .buffers = .{.{ .channels = 1, .size = out_bytes.len, .data = &out_bytes }} };
        var desc: AudioStreamPacketDescription = undefined;
        var packets: u32 = 1;
        _ = AudioConverterFillComplexBuffer(conv, converterInput, &in, &packets, &list, &desc);
        if (packets == 1 and desc.size > 0) hooks.audio(l.id, out_bytes[@intCast(desc.start)..][0..desc.size]);
    }
    l.mic_ring.trim(frame_samples * 10);
}

fn decodeReceived() void {
    inbound_lock.lock();
    const items = inbound_audio.toOwnedSlice(gpa) catch &.{};
    inbound_lock.unlock();
    defer gpa.free(items);
    for (items) |item| {
        defer gpa.free(item.data);
        mutex.lock();
        const r = findRemote(item.stream);
        const conv = if (r) |x| x.opus else null;
        const slot = if (r) |x| x.slot else 0;
        mutex.unlock();
        const c = conv orelse continue;
        var in: ConvInput = .{ .data = item.data, .is_packet = true };
        var pcm: [5760]i16 = undefined;
        var list: AudioBufferList = .{ .count = 1, .buffers = .{.{ .channels = 1, .size = pcm.len * 2, .data = &pcm }} };
        var frames: u32 = pcm.len;
        _ = AudioConverterFillComplexBuffer(c, converterInput, &in, &frames, &list, null);
        if (frames > 0) playback[slot].write(pcm[0..@min(frames, pcm.len)]);
    }
}
