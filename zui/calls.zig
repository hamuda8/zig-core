//! Calls on the phones. The web host has the browser's WebRTC; Android and iOS get it from two
//! pieces joined here:
//!
//! * a media backend from the host (`H.Media`: zui/media/android.zig, zui/media/ios.zig) that
//!   captures the camera and microphone, encodes (H.264, Opus), decodes, plays sound and draws
//!   video into `ui.video` views;
//! * a call engine from the app (`App.rtc`), which runs the connection: ICE, DTLS-SRTP, RTP
//!   and the signalling. zig-core does not depend on any engine; Reseal uses reseal-rtc:
//!
//!       pub const rtc = @import("reseal_rtc").zui_engine;
//!
//! The engine must provide (duck-typed, checked at compile time):
//!
//!     pub const Sink = struct { ctx: *anyopaque, signal, state, tracks, audio, video, keyframe };
//!         signal(ctx, json)                     JSON for the other side's peerSignal
//!         state(ctx, text)                      "connecting" | "connected" | "disconnected" | "failed" | "closed"
//!         tracks(ctx, audio: bool, video: bool) what the other side sends
//!         audio(ctx, opus_packet)               one received Opus packet
//!         video(ctx, annexb, keyframe, rotation) one received H.264 access unit
//!         keyframe(ctx)                         the other side asks our encoder for a keyframe
//!     pub const Options = struct { ice_servers: []const u8, polite: bool, ... };
//!     pub const Peer;
//!     pub fn open(gpa, Options, Sink) !*Peer      sends its first offer through sink.signal
//!     pub fn signal(*Peer, json) void
//!     pub fn sendAudio(*Peer, opus_packet) void
//!     pub fn sendVideo(*Peer, annexb, timestamp_90khz: u32, rotation: u16) void
//!     pub fn requestKeyframe(*Peer) void
//!     pub fn close(*Peer) void
//!
//! Signals use the web host's JSON ({"description":{...}}, {"candidate":{...}}) so phones and
//! browsers call each other. Sink functions run on the engine's threads; the media backend calls
//! back from its own threads; everything the app sees is handed to the UI thread (`pump`).

const std = @import("std");
const rt = @import("runtime.zig");

/// Remote streams get ids from here up, as on the web host.
pub const remote_stream_base: u32 = 0x8000_0000;

/// What a media backend calls, from any thread.
pub const MediaHooks = struct {
    /// An encoded Opus packet from local stream `stream`.
    audio: *const fn (stream: u32, packet: []const u8) void,
    /// An encoded H.264 access unit (Annex-B, SPS/PPS before keyframes) from `stream`, with the
    /// rotation (degrees clockwise) the receiver must apply.
    video: *const fn (stream: u32, annexb: []const u8, timestamp_90k: u32, rotation: u16) void,
    /// openMedia's outcome, or the camera going away.
    event: *const fn (stream: u32, kind: rt.MediaEvent.Kind, reason: []const u8) void,
    /// A remote stream's decoder needs a keyframe (new view, decoder error).
    need_keyframe: *const fn (remote_stream: u32) void,
};

/// A short critical section shared with real-time threads; never held across blocking calls.
pub const SpinLock = struct {
    m: std.atomic.Mutex = .unlocked,

    pub fn lock(s: *SpinLock) void {
        while (!s.m.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlock(s: *SpinLock) void {
        s.m.unlock();
    }
};

fn checkEngine(comptime E: type) void {
    inline for (.{ "Sink", "Options", "Peer", "open", "signal", "sendAudio", "sendVideo", "requestKeyframe", "close" }) |name| {
        if (!@hasDecl(E, name)) @compileError("App.rtc (the call engine) lacks `" ++ name ++ "`: see zui/calls.zig");
    }
}

fn checkMedia(comptime M: type) void {
    inline for (.{ "init", "wake", "open", "enable", "switchCamera", "close", "openRemote", "remoteAudio", "remoteVideo", "closeRemote", "requestKeyframe" }) |name| {
        if (!@hasDecl(M, name)) @compileError("the host's Media backend lacks `" ++ name ++ "`");
    }
}

/// The calls for one process: media backend `M`, engine `E`, runtime `R` (for the events).
pub fn Native(comptime M: type, comptime E: type, comptime R: type) type {
    comptime checkEngine(E);
    comptime checkMedia(M);
    return struct {
        const gpa = std.heap.smp_allocator;

        const PeerCtx = struct {
            id: u32,
            engine: ?*E.Peer = null,
            /// Local stream sent on this connection (atomic: read by media threads).
            stream: u32 = 0,
            /// The other side's stream id once it sends something (atomic).
            remote: u32 = 0,
        };

        const Queued = union(enum) {
            media: struct { id: u32, kind: rt.MediaEvent.Kind, data: []u8 },
            peer: struct { id: u32, kind: rt.PeerEvent.Kind, data: []u8, stream: u32 },
        };

        var inited = false;
        /// Guards `peers` (changed on the UI thread, read by media threads).
        var lock: SpinLock = .{};
        var peers: std.AutoHashMapUnmanaged(u32, *PeerCtx) = .empty;
        var qlock: SpinLock = .{};
        var queue: std.ArrayList(Queued) = .empty;
        var next_remote: u32 = remote_stream_base;

        fn init() void {
            if (inited) return;
            inited = true;
            M.init(.{ .audio = localAudio, .video = localVideo, .event = mediaHook, .need_keyframe = needKeyframe });
        }

        // ---- from the runtime (UI thread) -------------------------------------------------

        pub fn openMedia(id: u32, m: rt.Media) void {
            init();
            M.open(id, m);
        }

        pub fn mediaEnable(id: u32, audio: bool, video: bool) void {
            M.enable(id, audio, video);
        }

        pub fn switchCamera(id: u32) void {
            M.switchCamera(id);
        }

        pub fn closeMedia(id: u32) void {
            M.close(id);
        }

        pub fn openPeer(id: u32, p: rt.Peer) void {
            init();
            const ctx = gpa.create(PeerCtx) catch return enqueuePeer(id, .state, "failed", 0);
            ctx.* = .{ .id = id, .stream = p.stream };
            lock.lock();
            peers.put(gpa, id, ctx) catch {
                lock.unlock();
                gpa.destroy(ctx);
                return enqueuePeer(id, .state, "failed", 0);
            };
            lock.unlock();
            const sink: E.Sink = .{ .ctx = ctx, .signal = sinkSignal, .state = sinkState, .tracks = sinkTracks, .audio = sinkAudio, .video = sinkVideo, .keyframe = sinkKeyframe };
            const engine = E.open(gpa, .{ .ice_servers = p.ice_servers, .polite = p.polite }, sink) catch {
                enqueuePeer(id, .state, "failed", 0);
                return;
            };
            lock.lock();
            ctx.engine = engine;
            lock.unlock();
            // The other side should see our picture at once.
            if (p.stream != 0) M.requestKeyframe(p.stream);
        }

        pub fn peerSignal(id: u32, json: []const u8) void {
            lock.lock();
            const ctx = peers.get(id);
            const engine = if (ctx) |c| c.engine else null;
            lock.unlock();
            if (engine) |e| E.signal(e, json);
        }

        pub fn peerStream(id: u32, stream: u32) void {
            lock.lock();
            defer lock.unlock();
            const ctx = peers.get(id) orelse return;
            @atomicStore(u32, &ctx.stream, stream, .release);
            if (stream != 0) M.requestKeyframe(stream);
        }

        pub fn closePeer(id: u32) void {
            lock.lock();
            const kv = peers.fetchRemove(id);
            lock.unlock();
            const ctx = (kv orelse return).value;
            // Closing waits for the engine's threads, which never take `lock`.
            if (ctx.engine) |e| E.close(e);
            const remote = @atomicLoad(u32, &ctx.remote, .acquire);
            if (remote != 0) M.closeRemote(remote);
            gpa.destroy(ctx);
        }

        /// Delivers what the other threads queued. The host calls it on the UI thread after
        /// `M.wake()`.
        pub fn pump() void {
            qlock.lock();
            const items = queue.toOwnedSlice(gpa) catch {
                qlock.unlock();
                return;
            };
            qlock.unlock();
            defer gpa.free(items);
            for (items) |q| switch (q) {
                .media => |m| {
                    R.mediaEvent(m.id, m.kind, m.data);
                    gpa.free(m.data);
                },
                .peer => |p| {
                    R.peerEvent(p.id, p.kind, p.data, p.stream);
                    gpa.free(p.data);
                },
            };
        }

        fn enqueue(q: Queued) void {
            qlock.lock();
            queue.append(gpa, q) catch {};
            qlock.unlock();
            M.wake();
        }

        fn enqueuePeer(id: u32, kind: rt.PeerEvent.Kind, data: []const u8, stream: u32) void {
            const copy = gpa.dupe(u8, data) catch return;
            enqueue(.{ .peer = .{ .id = id, .kind = kind, .data = copy, .stream = stream } });
        }

        // ---- media backend hooks (media threads) -----------------------------------------

        fn localAudio(stream: u32, packet: []const u8) void {
            lock.lock();
            defer lock.unlock();
            var it = peers.valueIterator();
            while (it.next()) |c| if (@atomicLoad(u32, &c.*.stream, .acquire) == stream) {
                if (c.*.engine) |e| E.sendAudio(e, packet);
            };
        }

        fn localVideo(stream: u32, annexb: []const u8, ts: u32, rotation: u16) void {
            lock.lock();
            defer lock.unlock();
            var it = peers.valueIterator();
            while (it.next()) |c| if (@atomicLoad(u32, &c.*.stream, .acquire) == stream) {
                if (c.*.engine) |e| E.sendVideo(e, annexb, ts, rotation);
            };
        }

        fn mediaHook(stream: u32, kind: rt.MediaEvent.Kind, reason: []const u8) void {
            const copy = gpa.dupe(u8, reason) catch return;
            enqueue(.{ .media = .{ .id = stream, .kind = kind, .data = copy } });
        }

        fn needKeyframe(remote: u32) void {
            lock.lock();
            defer lock.unlock();
            var it = peers.valueIterator();
            while (it.next()) |c| if (@atomicLoad(u32, &c.*.remote, .acquire) == remote) {
                if (c.*.engine) |e| E.requestKeyframe(e);
            };
        }

        // ---- engine sink (engine threads; must not take `lock`) ---------------------------

        fn ctxOf(p: *anyopaque) *PeerCtx {
            return @ptrCast(@alignCast(p));
        }

        fn sinkSignal(p: *anyopaque, json: []const u8) void {
            enqueuePeer(ctxOf(p).id, .signal, json, 0);
        }

        fn sinkState(p: *anyopaque, text: []const u8) void {
            enqueuePeer(ctxOf(p).id, .state, text, 0);
        }

        fn sinkTracks(p: *anyopaque, audio: bool, video: bool) void {
            const c = ctxOf(p);
            if (!audio and !video) return;
            var remote = @atomicLoad(u32, &c.remote, .acquire);
            if (remote == 0) {
                remote = @atomicRmw(u32, &next_remote, .Add, 1, .monotonic);
                M.openRemote(remote);
                @atomicStore(u32, &c.remote, remote, .release);
            }
            enqueuePeer(c.id, .track, "", remote);
        }

        fn sinkAudio(p: *anyopaque, packet: []const u8) void {
            const remote = @atomicLoad(u32, &ctxOf(p).remote, .acquire);
            if (remote != 0) M.remoteAudio(remote, packet);
        }

        fn sinkVideo(p: *anyopaque, annexb: []const u8, keyframe: bool, rotation: u16) void {
            const remote = @atomicLoad(u32, &ctxOf(p).remote, .acquire);
            if (remote != 0) M.remoteVideo(remote, annexb, keyframe, rotation);
        }

        fn sinkKeyframe(p: *anyopaque) void {
            const stream = @atomicLoad(u32, &ctxOf(p).stream, .acquire);
            if (stream != 0) M.requestKeyframe(stream);
        }
    };
}

// ---- tests: the plumbing with a fake engine and a fake media backend ------------------------

const testing = std.testing;

const FakeMedia = struct {
    pub var hooks: MediaHooks = undefined;
    pub var opened_remote: u32 = 0;
    pub var remote_audio: u32 = 0;
    pub var keyframes: u32 = 0;
    pub var wakes: u32 = 0;
    pub fn init(h: MediaHooks) void {
        hooks = h;
    }
    pub fn wake() void {
        wakes += 1;
    }
    pub fn open(id: u32, _: rt.Media) void {
        hooks.event(id, .ready, "");
    }
    pub fn enable(_: u32, _: bool, _: bool) void {}
    pub fn switchCamera(_: u32) void {}
    pub fn close(_: u32) void {}
    pub fn openRemote(id: u32) void {
        opened_remote = id;
    }
    pub fn remoteAudio(_: u32, _: []const u8) void {
        remote_audio += 1;
    }
    pub fn remoteVideo(_: u32, _: []const u8, _: bool, _: u16) void {}
    pub fn closeRemote(_: u32) void {
        opened_remote = 0;
    }
    pub fn requestKeyframe(_: u32) void {
        keyframes += 1;
    }
};

const FakeEngine = struct {
    pub const Sink = struct {
        ctx: *anyopaque,
        signal: *const fn (*anyopaque, []const u8) void,
        state: *const fn (*anyopaque, []const u8) void,
        tracks: *const fn (*anyopaque, bool, bool) void,
        audio: *const fn (*anyopaque, []const u8) void,
        video: *const fn (*anyopaque, []const u8, bool, u16) void,
        keyframe: *const fn (*anyopaque) void,
    };
    pub const Options = struct { ice_servers: []const u8, polite: bool };
    pub const Peer = struct { sink: Sink, sent: u32 = 0, signals: u32 = 0 };
    var last: ?*Peer = null;
    pub fn open(gpa: std.mem.Allocator, _: Options, sink: Sink) !*Peer {
        const p = try gpa.create(Peer);
        p.* = .{ .sink = sink };
        last = p;
        sink.signal(sink.ctx, "{\"description\":{\"type\":\"offer\",\"sdp\":\"v=0\"}}");
        return p;
    }
    pub fn signal(p: *Peer, _: []const u8) void {
        p.signals += 1;
        p.sink.tracks(p.sink.ctx, true, true);
        p.sink.state(p.sink.ctx, "connected");
        p.sink.audio(p.sink.ctx, "opus");
    }
    pub fn sendAudio(p: *Peer, _: []const u8) void {
        p.sent += 1;
    }
    pub fn sendVideo(p: *Peer, _: []const u8, _: u32, _: u16) void {
        p.sent += 1;
    }
    pub fn requestKeyframe(_: *Peer) void {}
    pub fn close(p: *Peer) void {
        std.heap.smp_allocator.destroy(p);
        last = null;
    }
};

const FakeRuntime = struct {
    var media_ready: u32 = 0;
    var signals: u32 = 0;
    var connected = false;
    var track: u32 = 0;
    pub fn mediaEvent(_: u32, kind: rt.MediaEvent.Kind, _: []const u8) void {
        if (kind == .ready) media_ready += 1;
    }
    pub fn peerEvent(_: u32, kind: rt.PeerEvent.Kind, data: []const u8, stream: u32) void {
        switch (kind) {
            .signal => signals += 1,
            .state => connected = std.mem.eql(u8, data, "connected"),
            .track => track = stream,
        }
    }
};

test "native calls: media, peer, signals, remote stream, fan-out of local frames" {
    const N = Native(FakeMedia, FakeEngine, FakeRuntime);
    N.openMedia(5, .{ .video = true });
    N.openPeer(7, .{ .polite = true, .stream = 5 });
    N.pump();
    try testing.expectEqual(@as(u32, 1), FakeRuntime.media_ready);
    try testing.expectEqual(@as(u32, 1), FakeRuntime.signals); // the first offer
    try testing.expectEqual(@as(u32, 1), FakeMedia.keyframes);

    N.peerSignal(7, "{\"description\":{\"type\":\"answer\",\"sdp\":\"v=0\"}}");
    N.pump();
    try testing.expect(FakeRuntime.connected);
    try testing.expectEqual(remote_stream_base, FakeRuntime.track);
    try testing.expectEqual(remote_stream_base, FakeMedia.opened_remote);
    try testing.expectEqual(@as(u32, 1), FakeMedia.remote_audio);

    // Encoded local frames reach the connection sending that stream, and only it.
    FakeMedia.hooks.audio(5, "pkt");
    FakeMedia.hooks.video(5, "au", 0, 0);
    FakeMedia.hooks.audio(6, "other");
    try testing.expectEqual(@as(u32, 2), FakeEngine.last.?.sent);

    N.closePeer(7);
    try testing.expectEqual(@as(u32, 0), FakeMedia.opened_remote);
    try testing.expect(FakeEngine.last == null);
}
