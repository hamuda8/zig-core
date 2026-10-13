//! iOS voice and video messages (fx.startRecording, fx.play): AVAudioRecorder for audio (AAC in
//! M4A, with metering), AVCaptureSession + AVCaptureMovieFileOutput for video, exported without
//! re-encoding to MP4 (H.264 + AAC), and AVPlayer for playback. Main thread only: delegate and
//! block callbacks hop to it. Video views showing a recorder or a player get a subview whose
//! layer is an AVCaptureVideoPreviewLayer or an AVPlayerLayer.

const std = @import("std");
const zui = @import("../zui.zig");
const objc = @import("../platform/objc.zig");

const id = objc.id;
const SEL = objc.SEL;
const gpa = zui.allocator;
const send = objc.send;
const send1 = objc.send1;
const msgSend = objc.msgSend;

const Queue = ?*anyopaque;
extern "c" var _dispatch_main_q: u8;
extern "c" fn dispatch_async_f(queue: Queue, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;
extern "c" fn dispatch_time(when: u64, delta: i64) u64;
extern "c" fn dispatch_after_f(when: u64, queue: Queue, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;
extern "c" fn NSTemporaryDirectory() id;
extern "c" fn CACurrentMediaTime() f64;

extern "c" const AVMediaTypeVideo: id;
extern "c" const AVMediaTypeAudio: id;
extern "c" const AVFormatIDKey: id;
extern "c" const AVSampleRateKey: id;
extern "c" const AVNumberOfChannelsKey: id;
extern "c" const AVEncoderBitRateKey: id;
extern "c" const AVAudioSessionCategoryPlayAndRecord: id;
extern "c" const AVCaptureSessionPreset640x480: id;
extern "c" const AVCaptureDeviceTypeBuiltInWideAngleCamera: id;
extern "c" const AVFileTypeMPEG4: id;
extern "c" const AVAssetExportPresetPassthrough: id;
extern "c" const AVLayerVideoGravityResizeAspect: id;
extern "c" const AVLayerVideoGravityResizeAspectFill: id;

const CMTime = extern struct { value: i64, timescale: i32, flags: u32, epoch: i64 };
extern "c" fn CMTimeGetSeconds(t: CMTime) f64;
extern "c" fn CMTimeMakeWithSeconds(seconds: f64, timescale: i32) CMTime;
extern "c" const kCMTimeZero: CMTime;

/// kAudioFormatMPEG4AAC ('aac ').
const format_aac: u32 = 0x61616320;
/// AVAudioSessionCategoryOptionDefaultToSpeaker
const option_speaker: usize = 8;
/// AVAuthorizationStatus
const auth_not_determined: isize = 0;
const auth_authorized: isize = 3;
/// UIViewAutoresizingFlexibleWidth | FlexibleHeight
const flexible_size: usize = 2 | 16;

fn mainQueue() Queue {
    return @ptrCast(&_dispatch_main_q);
}

fn after(ms: i64, ctx: u32, work: *const fn (?*anyopaque) callconv(.c) void) void {
    dispatch_after_f(dispatch_time(0, ms * std.time.ns_per_ms), mainQueue(), @ptrFromInt(@as(usize, ctx)), work);
}

fn ctxId(ctx: ?*anyopaque) u32 {
    return @intCast(@intFromPtr(ctx));
}

// ---- the runtime ------------------------------------------------------------------------------

const RecordFn = *const fn (u32, zui.RecordEvent.Kind, f32, u32, []const u8, []const u8) void;
const PlayFn = *const fn (u32, zui.PlayEvent.Kind, u32, u32, []const u8) void;
var on_record: RecordFn = undefined;
var on_play: PlayFn = undefined;

/// The host calls this once at start with the runtime's entry points.
pub fn init(record: RecordFn, play_event: PlayFn) void {
    on_record = record;
    on_play = play_event;
    objc.defineClass("ZuiMovieDelegate", "NSObject", &.{"AVCaptureFileOutputRecordingDelegate"}, &.{
        .{ "captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:", @ptrCast(&movieFinished), "v@:@@@@" },
    });
    objc.defineClass("ZuiPlayerView", "UIView", &.{}, &.{});
    objc.addClassMethod("ZuiPlayerView", "layerClass", @ptrCast(&playerLayerClass), "#@:");
    objc.defineClass("ZuiPreviewView", "UIView", &.{}, &.{});
    objc.addClassMethod("ZuiPreviewView", "layerClass", @ptrCast(&previewLayerClass), "#@:");
}

fn playerLayerClass(_: id, _: SEL) callconv(.c) id {
    return objc.class("AVPlayerLayer");
}

fn previewLayerClass(_: id, _: SEL) callconv(.c) id {
    return objc.class("AVCaptureVideoPreviewLayer");
}

// ---- files ------------------------------------------------------------------------------------

var file_counter: u32 = 0;

/// A new path in the temporary directory (owned, null-terminated).
fn tempPath(ext: []const u8) ?[:0]u8 {
    const dir = msgSend(*const fn (id, SEL) callconv(.c) ?[*:0]const u8)(NSTemporaryDirectory(), objc.sel("UTF8String")) orelse return null;
    file_counter += 1;
    return std.fmt.allocPrintSentinel(gpa, "{s}zui-{d}-{d}.{s}", .{ std.mem.span(dir), @as(u64, @intFromFloat(CACurrentMediaTime() * 1000)), file_counter, ext }, 0) catch null;
}

fn fileUrl(path: []const u8) id {
    const s = objc.nsString(path);
    defer objc.release(s);
    return send1(objc.class("NSURL"), "fileURLWithPath:", s);
}

fn removeFile(path: []const u8) void {
    const s = objc.nsString(path);
    defer objc.release(s);
    _ = msgSend(*const fn (id, SEL, id, ?*id) callconv(.c) bool)(send(objc.class("NSFileManager"), "defaultManager"), objc.sel("removeItemAtPath:error:"), s, null);
}

/// The file's bytes (autoreleased NSData; valid until the run loop turns).
fn readFile(path: []const u8) ?[]const u8 {
    const s = objc.nsString(path);
    defer objc.release(s);
    const data = send1(objc.class("NSData"), "dataWithContentsOfFile:", s);
    if (data == null) return null;
    const len: usize = @intCast(objc.sendInt(data, "length"));
    const bytes = msgSend(*const fn (id, SEL) callconv(.c) ?[*]const u8)(data, objc.sel("bytes")) orelse return if (len == 0) "" else null;
    return bytes[0..len];
}

fn writeFile(path: []const u8, bytes: []const u8) bool {
    const data = msgSend(*const fn (id, SEL, [*]const u8, usize) callconv(.c) id)(objc.class("NSData"), objc.sel("dataWithBytes:length:"), bytes.ptr, bytes.len);
    const s = objc.nsString(path);
    defer objc.release(s);
    return msgSend(*const fn (id, SEL, id, bool) callconv(.c) bool)(data, objc.sel("writeToFile:atomically:"), s, true);
}

fn audioSession() void {
    const session = send(objc.class("AVAudioSession"), "sharedInstance");
    _ = msgSend(*const fn (id, SEL, id, usize, ?*id) callconv(.c) bool)(session, objc.sel("setCategory:withOptions:error:"), AVAudioSessionCategoryPlayAndRecord, option_speaker, null);
    _ = msgSend(*const fn (id, SEL, bool, ?*id) callconv(.c) bool)(session, objc.sel("setActive:error:"), true, null);
}

fn number(comptime T: type, sel_name: [*:0]const u8, v: T) id {
    return msgSend(*const fn (id, SEL, T) callconv(.c) id)(objc.class("NSNumber"), objc.sel(sel_name), v);
}

// ---- recording --------------------------------------------------------------------------------

const Rec = struct {
    id: u32,
    video: bool,
    back: bool,
    max_ms: u32,
    started: bool = false,
    stopping: bool = false,
    cancel: bool = false,
    started_at: f64 = 0,
    duration_ms: u32 = 0,
    path: ?[:0]u8 = null,
    mp4: ?[:0]u8 = null,
    recorder: id = null,
    session: id = null,
    output: id = null,
    export_session: id = null,
};

var recs: std.AutoHashMapUnmanaged(u32, *Rec) = .empty;
var movie_delegate: id = null;

pub fn startRecording(rec_id: u32, r: zui.Recording) void {
    const rec = gpa.create(Rec) catch return on_record(rec_id, .failed, 0, 0, "unavailable", "");
    rec.* = .{ .id = rec_id, .video = r.video, .back = r.back_camera, .max_ms = r.max_ms };
    recs.put(gpa, rec_id, rec) catch {
        gpa.destroy(rec);
        return on_record(rec_id, .failed, 0, 0, "unavailable", "");
    };
    askPermissions(rec_id);
}

fn authorization(media_type: id) isize {
    return msgSend(*const fn (id, SEL, id) callconv(.c) isize)(objc.class("AVCaptureDevice"), objc.sel("authorizationStatusForMediaType:"), media_type);
}

const AccessBlock = extern struct { header: objc.BlockHeader, rec: u32 };
const access_descriptor: objc.BlockDescriptor = .{ .size = @sizeOf(AccessBlock) };

/// Asks for what is not decided yet, one at a time, then begins.
fn askPermissions(rec_id: u32) void {
    const rec = recs.get(rec_id) orelse return;
    const pending: ?id = if (authorization(AVMediaTypeAudio) == auth_not_determined)
        AVMediaTypeAudio
    else if (rec.video and authorization(AVMediaTypeVideo) == auth_not_determined)
        AVMediaTypeVideo
    else
        null;
    if (pending) |media_type| {
        const b = gpa.create(AccessBlock) catch return fail(rec, "unavailable");
        b.* = .{ .header = .{ .isa = &objc._NSConcreteGlobalBlock, .invoke = @ptrCast(&accessDone), .descriptor = &access_descriptor }, .rec = rec_id };
        msgSend(*const fn (id, SEL, id, *AccessBlock) callconv(.c) void)(objc.class("AVCaptureDevice"), objc.sel("requestAccessForMediaType:completionHandler:"), media_type, b);
        return;
    }
    if (authorization(AVMediaTypeAudio) != auth_authorized or (rec.video and authorization(AVMediaTypeVideo) != auth_authorized)) return fail(rec, "denied");
    if (rec.video) beginVideo(rec) else beginAudio(rec);
}

fn accessDone(b: *AccessBlock, _: bool) callconv(.c) void {
    const rec_id = b.rec;
    gpa.destroy(b);
    dispatch_async_f(mainQueue(), @ptrFromInt(@as(usize, rec_id)), accessOnMain);
}

fn accessOnMain(ctx: ?*anyopaque) callconv(.c) void {
    askPermissions(ctxId(ctx));
}

fn beginAudio(rec: *Rec) void {
    audioSession();
    rec.path = tempPath("m4a") orelse return fail(rec, "unavailable");
    var keys = [_]id{ AVFormatIDKey, AVSampleRateKey, AVNumberOfChannelsKey, AVEncoderBitRateKey };
    var values = [_]id{ number(u32, "numberWithUnsignedInt:", format_aac), number(f64, "numberWithDouble:", 44100), number(i32, "numberWithInt:", 1), number(i32, "numberWithInt:", 64000) };
    const settings = msgSend(*const fn (id, SEL, [*]id, [*]id, usize) callconv(.c) id)(objc.class("NSDictionary"), objc.sel("dictionaryWithObjects:forKeys:count:"), &values, &keys, keys.len);
    const url = fileUrl(rec.path.?[0..rec.path.?.len]);
    const recorder = msgSend(*const fn (id, SEL, id, id, ?*id) callconv(.c) id)(send(objc.class("AVAudioRecorder"), "alloc"), objc.sel("initWithURL:settings:error:"), url, settings, null);
    if (recorder == null) return fail(rec, "unavailable");
    rec.recorder = recorder;
    objc.sendVoidBool(recorder, "setMeteringEnabled:", true);
    if (!msgSend(*const fn (id, SEL) callconv(.c) bool)(recorder, objc.sel("record"))) return fail(rec, "unavailable");
    started(rec);
}

fn deviceInput(device: id) id {
    if (device == null) return null;
    return msgSend(*const fn (id, SEL, id, ?*id) callconv(.c) id)(objc.class("AVCaptureDeviceInput"), objc.sel("deviceInputWithDevice:error:"), device, null);
}

fn addInput(session: id, input: id) bool {
    if (input == null) return false;
    if (!msgSend(*const fn (id, SEL, id) callconv(.c) bool)(session, objc.sel("canAddInput:"), input)) return false;
    objc.sendVoid1(session, "addInput:", input);
    return true;
}

fn beginVideo(rec: *Rec) void {
    audioSession();
    rec.path = tempPath("mov") orelse return fail(rec, "unavailable");
    const session = objc.new("AVCaptureSession");
    rec.session = session;
    objc.sendVoid1(session, "setSessionPreset:", AVCaptureSessionPreset640x480);
    const camera = msgSend(*const fn (id, SEL, id, id, isize) callconv(.c) id)(
        objc.class("AVCaptureDevice"),
        objc.sel("defaultDeviceWithDeviceType:mediaType:position:"),
        AVCaptureDeviceTypeBuiltInWideAngleCamera,
        AVMediaTypeVideo,
        if (rec.back) 1 else 2,
    );
    if (!addInput(session, deviceInput(camera))) return fail(rec, "unavailable");
    _ = addInput(session, deviceInput(send1(objc.class("AVCaptureDevice"), "defaultDeviceWithMediaType:", AVMediaTypeAudio)));
    const output = objc.new("AVCaptureMovieFileOutput");
    rec.output = output;
    if (!msgSend(*const fn (id, SEL, id) callconv(.c) bool)(session, objc.sel("canAddOutput:"), output)) return fail(rec, "unavailable");
    objc.sendVoid1(session, "addOutput:", output);
    const conn = send1(output, "connectionWithMediaType:", AVMediaTypeVideo);
    // Portrait, like the screen: the file plays upright everywhere.
    if (conn != null and msgSend(*const fn (id, SEL) callconv(.c) bool)(conn, objc.sel("isVideoOrientationSupported"))) objc.sendVoidInt(conn, "setVideoOrientation:", 1);
    objc.sendVoid(session, "startRunning");
    if (movie_delegate == null) movie_delegate = objc.new("ZuiMovieDelegate");
    msgSend(*const fn (id, SEL, id, id) callconv(.c) void)(output, objc.sel("startRecordingToOutputFileURL:recordingDelegate:"), fileUrl(rec.path.?[0..rec.path.?.len]), movie_delegate);
    refreshViews(rec.id);
    started(rec);
}

fn started(rec: *Rec) void {
    rec.started = true;
    rec.started_at = CACurrentMediaTime();
    on_record(rec.id, .started, 0, 0, "", "");
    after(100, rec.id, levelTick);
}

fn elapsedMs(rec: *const Rec) u32 {
    return @intFromFloat(@max(0, (CACurrentMediaTime() - rec.started_at) * 1000));
}

/// Ten times a second: the microphone's level, and the time limit.
fn levelTick(ctx: ?*anyopaque) callconv(.c) void {
    const rec = recs.get(ctxId(ctx)) orelse return;
    if (rec.stopping) return;
    var db: f32 = -160;
    if (rec.recorder) |r| {
        objc.sendVoid(r, "updateMeters");
        db = msgSend(*const fn (id, SEL, usize) callconv(.c) f32)(r, objc.sel("averagePowerForChannel:"), 0);
    } else if (rec.output) |o| {
        const conn = send1(o, "connectionWithMediaType:", AVMediaTypeAudio);
        const channel = if (conn != null) send(send(conn, "audioChannels"), "firstObject") else null;
        if (channel != null) db = msgSend(*const fn (id, SEL) callconv(.c) f32)(channel, objc.sel("averagePowerLevel"));
    }
    // Decibels to 0..1, with a square root so speech reads like loudness (as on Android).
    const level: f32 = @sqrt(std.math.clamp(std.math.pow(f32, 10, db / 20), 0, 1));
    const ms = elapsedMs(rec);
    on_record(rec.id, .level, level, ms, "", "");
    if (ms >= rec.max_ms) return stopRecording(rec.id, false);
    after(100, rec.id, levelTick);
}

pub fn stopRecording(rec_id: u32, cancel: bool) void {
    const rec = recs.get(rec_id) orelse return;
    if (rec.stopping) return;
    rec.stopping = true;
    rec.cancel = cancel;
    if (!rec.started) return if (cancel) finish(rec) else fail(rec, "unavailable");
    rec.duration_ms = elapsedMs(rec);
    if (rec.recorder) |r| {
        objc.sendVoid(r, "stop");
        if (cancel) return finish(rec);
        const data = readFile(rec.path.?[0..rec.path.?.len]) orelse return fail(rec, "unavailable");
        on_record(rec.id, .done, 0, rec.duration_ms, data, "audio/mp4");
        return finish(rec);
    }
    // Video: the delegate hears when the file is complete.
    objc.sendVoid(rec.output, "stopRecording");
}

fn findByOutput(output: id) ?*Rec {
    var it = recs.valueIterator();
    while (it.next()) |r| if (r.*.output == output) return r.*;
    return null;
}

/// From AVFoundation's queue: the movie file is complete.
fn movieFinished(_: id, _: SEL, output: id, _: id, _: id, _: id) callconv(.c) void {
    dispatch_async_f(mainQueue(), output, movieOnMain);
}

fn movieOnMain(ctx: ?*anyopaque) callconv(.c) void {
    const rec = findByOutput(@ptrCast(ctx)) orelse return;
    if (rec.session) |s| objc.sendVoid(s, "stopRunning");
    if (rec.cancel) return finish(rec);
    // QuickTime to MP4 without re-encoding.
    rec.mp4 = tempPath("mp4") orelse return fail(rec, "unavailable");
    const asset = msgSend(*const fn (id, SEL, id, id) callconv(.c) id)(objc.class("AVURLAsset"), objc.sel("URLAssetWithURL:options:"), fileUrl(rec.path.?[0..rec.path.?.len]), null);
    const ex = msgSend(*const fn (id, SEL, id, id) callconv(.c) id)(send(objc.class("AVAssetExportSession"), "alloc"), objc.sel("initWithAsset:presetName:"), asset, AVAssetExportPresetPassthrough);
    if (ex == null) return fail(rec, "unavailable");
    rec.export_session = ex;
    objc.sendVoid1(ex, "setOutputURL:", fileUrl(rec.mp4.?[0..rec.mp4.?.len]));
    objc.sendVoid1(ex, "setOutputFileType:", AVFileTypeMPEG4);
    const b = gpa.create(AccessBlock) catch return fail(rec, "unavailable");
    b.* = .{ .header = .{ .isa = &objc._NSConcreteGlobalBlock, .invoke = @ptrCast(&exportDone), .descriptor = &access_descriptor }, .rec = rec.id };
    msgSend(*const fn (id, SEL, *AccessBlock) callconv(.c) void)(ex, objc.sel("exportAsynchronouslyWithCompletionHandler:"), b);
}

fn exportDone(b: *AccessBlock) callconv(.c) void {
    const rec_id = b.rec;
    gpa.destroy(b);
    dispatch_async_f(mainQueue(), @ptrFromInt(@as(usize, rec_id)), exportOnMain);
}

fn exportOnMain(ctx: ?*anyopaque) callconv(.c) void {
    const rec = recs.get(ctxId(ctx)) orelse return;
    // AVAssetExportSessionStatusCompleted
    if (objc.sendInt(rec.export_session, "status") != 3) return fail(rec, "unavailable");
    const data = readFile(rec.mp4.?[0..rec.mp4.?.len]) orelse return fail(rec, "unavailable");
    on_record(rec.id, .done, 0, rec.duration_ms, data, "video/mp4");
    finish(rec);
}

fn fail(rec: *Rec, reason: []const u8) void {
    const rec_id = rec.id;
    finish(rec);
    on_record(rec_id, .failed, 0, 0, reason, "");
}

/// Releases everything a recorder holds and forgets it.
fn finish(rec: *Rec) void {
    _ = recs.remove(rec.id);
    if (rec.recorder) |r| objc.release(r);
    if (rec.session) |s| {
        objc.sendVoid(s, "stopRunning");
        objc.release(s);
    }
    if (rec.output) |o| objc.release(o);
    if (rec.export_session) |e| objc.release(e);
    inline for (.{ rec.path, rec.mp4 }) |p| if (p) |path| {
        removeFile(path[0..path.len]);
        gpa.free(path);
    };
    rec.session = null;
    refreshViews(rec.id);
    gpa.destroy(rec);
}

// ---- playback ---------------------------------------------------------------------------------

const Player = struct {
    id: u32,
    player: id,
    path: ?[:0]u8 = null,
    ready: bool = false,
    want_play: bool,
    loop: bool,
    ended: bool = false,
};

var players: std.AutoHashMapUnmanaged(u32, *Player) = .empty;

fn extension(mime: []const u8) []const u8 {
    if (std.mem.indexOf(u8, mime, "webm") != null) return "webm";
    if (std.mem.indexOf(u8, mime, "mpeg") != null) return "mp3";
    if (std.mem.indexOf(u8, mime, "wav") != null) return "wav";
    if (std.mem.indexOf(u8, mime, "quicktime") != null) return "mov";
    return if (std.mem.startsWith(u8, mime, "video")) "mp4" else "m4a";
}

pub fn play(player_id: u32, p: zui.Playback) void {
    audioSession();
    var path: ?[:0]u8 = null;
    const url = if (p.data.len > 0) blk: {
        path = tempPath(extension(p.mime)) orelse return on_play(player_id, .failed, 0, 0, "unavailable");
        if (!writeFile(path.?[0..path.?.len], p.data)) {
            gpa.free(path.?);
            return on_play(player_id, .failed, 0, 0, "unavailable");
        }
        break :blk fileUrl(path.?[0..path.?.len]);
    } else blk: {
        const s = objc.nsString(p.url);
        defer objc.release(s);
        break :blk send1(objc.class("NSURL"), "URLWithString:", s);
    };
    if (url == null) return on_play(player_id, .failed, 0, 0, "unavailable");
    const player = send(send1(objc.class("AVPlayer"), "playerWithURL:", url), "retain");
    const pl = gpa.create(Player) catch return on_play(player_id, .failed, 0, 0, "unavailable");
    pl.* = .{ .id = player_id, .player = player, .path = path, .want_play = p.autoplay, .loop = p.loop };
    players.put(gpa, player_id, pl) catch {
        release(pl);
        return on_play(player_id, .failed, 0, 0, "unavailable");
    };
    refreshViews(player_id);
    after(50, player_id, playTick);
}

fn seconds(t: CMTime) f64 {
    const s = CMTimeGetSeconds(t);
    return if (std.math.isNan(s) or std.math.isInf(s)) 0 else s;
}

fn positionMs(pl: *const Player) u32 {
    const t = msgSend(*const fn (id, SEL) callconv(.c) CMTime)(pl.player, objc.sel("currentTime"));
    return @intFromFloat(@max(0, seconds(t) * 1000));
}

fn durationMs(pl: *const Player) u32 {
    const item = send(pl.player, "currentItem");
    if (item == null) return 0;
    const t = msgSend(*const fn (id, SEL) callconv(.c) CMTime)(item, objc.sel("duration"));
    return @intFromFloat(@max(0, seconds(t) * 1000));
}

fn rate(pl: *const Player) f32 {
    return msgSend(*const fn (id, SEL) callconv(.c) f32)(pl.player, objc.sel("rate"));
}

/// Four times a second: readiness, progress and the end.
fn playTick(ctx: ?*anyopaque) callconv(.c) void {
    const pl = players.get(ctxId(ctx)) orelse return;
    const item = send(pl.player, "currentItem");
    // AVPlayerItemStatusReadyToPlay = 1, Failed = 2
    const status = if (item != null) objc.sendInt(item, "status") else 2;
    if (status == 2) {
        const player_id = pl.id;
        _ = players.remove(player_id);
        release(pl);
        refreshViews(player_id);
        return on_play(player_id, .failed, 0, 0, "unavailable");
    }
    if (!pl.ready and status == 1) {
        pl.ready = true;
        on_play(pl.id, .ready, 0, durationMs(pl), "");
        if (pl.want_play) objc.sendVoid(pl.player, "play");
    } else if (pl.ready and !pl.ended) {
        const pos = positionMs(pl);
        const dur = durationMs(pl);
        if (pl.want_play and rate(pl) == 0 and dur > 0 and pos + 60 >= dur) {
            if (pl.loop) {
                seekTo(pl, 0);
                objc.sendVoid(pl.player, "play");
            } else {
                pl.ended = true;
                on_play(pl.id, .ended, dur, dur, "");
            }
        } else if (rate(pl) > 0) {
            on_play(pl.id, .progress, pos, dur, "");
        }
    }
    if (players.get(ctxId(ctx)) == pl) after(250, pl.id, playTick);
}

fn seekTo(pl: *Player, ms: u32) void {
    const t = CMTimeMakeWithSeconds(@as(f64, @floatFromInt(ms)) / 1000, 600);
    msgSend(*const fn (id, SEL, CMTime, CMTime, CMTime) callconv(.c) void)(pl.player, objc.sel("seekToTime:toleranceBefore:toleranceAfter:"), t, kCMTimeZero, kCMTimeZero);
}

pub fn controlPlayback(player_id: u32, c: zui.PlaybackControl) void {
    const pl = players.get(player_id) orelse return;
    switch (c) {
        .pause => {
            pl.want_play = false;
            objc.sendVoid(pl.player, "pause");
            if (pl.ready) on_play(pl.id, .progress, positionMs(pl), durationMs(pl), "");
        },
        .play => {
            pl.want_play = true;
            if (pl.ended) seekTo(pl, 0);
            pl.ended = false;
            if (pl.ready) objc.sendVoid(pl.player, "play");
        },
        .seek => |ms| {
            pl.ended = false;
            seekTo(pl, ms);
            if (pl.ready) on_play(pl.id, .progress, ms, durationMs(pl), "");
        },
        .stop => {
            _ = players.remove(player_id);
            release(pl);
            refreshViews(player_id);
        },
    }
}

fn release(pl: *Player) void {
    objc.sendVoid(pl.player, "pause");
    objc.release(pl.player);
    if (pl.path) |path| {
        removeFile(path[0..path.len]);
        gpa.free(path);
    }
    gpa.destroy(pl);
}

// ---- video views --------------------------------------------------------------------------------

const View = struct { view: id, stream: u32, mirror: bool, cover: bool, sub: id = null };
var views: std.AutoHashMapUnmanaged(u32, View) = .empty;

/// The host's `ui.video`: true when `v.stream` is a recorder or a player (shown here).
pub fn bindView(view_id: u32, view: id, v: zui.Video) bool {
    const ours = recs.contains(v.stream) or players.contains(v.stream);
    if (!ours) {
        unbindView(view_id);
        return false;
    }
    const gop = views.getOrPut(gpa, view_id) catch return true;
    if (!gop.found_existing) gop.value_ptr.* = .{ .view = view, .stream = 0, .mirror = false, .cover = false };
    gop.value_ptr.stream = v.stream;
    gop.value_ptr.mirror = v.mirror;
    gop.value_ptr.cover = v.cover;
    show(gop.value_ptr);
    return true;
}

pub fn unbindView(view_id: u32) void {
    const kv = views.fetchRemove(view_id) orelse return;
    if (kv.value.sub) |s| {
        objc.sendVoid(s, "removeFromSuperview");
        objc.release(s);
    }
}

fn refreshViews(stream: u32) void {
    var it = views.valueIterator();
    while (it.next()) |v| if (v.stream == stream) show(v);
}

/// Puts the right subview (camera preview or player) into a view, or removes it.
fn show(v: *View) void {
    if (v.sub) |s| {
        objc.sendVoid(s, "removeFromSuperview");
        objc.release(s);
        v.sub = null;
    }
    const gravity = if (v.cover) AVLayerVideoGravityResizeAspectFill else AVLayerVideoGravityResizeAspect;
    var sub: id = null;
    if (recs.get(v.stream)) |rec| {
        const session = rec.session orelse return;
        sub = objc.new("ZuiPreviewView");
        const layer = send(sub, "layer");
        objc.sendVoid1(layer, "setSession:", session);
        objc.sendVoid1(layer, "setVideoGravity:", gravity);
        const conn = send(layer, "connection");
        if (conn != null) {
            objc.sendVoidBool(conn, "setAutomaticallyAdjustsVideoMirroring:", false);
            objc.sendVoidBool(conn, "setVideoMirrored:", v.mirror);
        }
    } else if (players.get(v.stream)) |pl| {
        sub = objc.new("ZuiPlayerView");
        const layer = send(sub, "layer");
        objc.sendVoid1(layer, "setPlayer:", pl.player);
        objc.sendVoid1(layer, "setVideoGravity:", gravity);
    } else return;
    const bounds = msgSend(*const fn (id, SEL) callconv(.c) objc.CGRect)(v.view, objc.sel("bounds"));
    msgSend(*const fn (id, SEL, objc.CGRect) callconv(.c) void)(sub, objc.sel("setFrame:"), bounds);
    msgSend(*const fn (id, SEL, usize) callconv(.c) void)(sub, objc.sel("setAutoresizingMask:"), flexible_size);
    objc.sendVoidBool(sub, "setUserInteractionEnabled:", false);
    objc.sendVoid1(v.view, "addSubview:", sub);
    v.sub = sub;
}
