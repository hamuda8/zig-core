//! Pushes to the phone apps: Firebase Cloud Messaging (Android) and APNs (iOS alerts and VoIP),
//! behind one `Sender` the app servers keep for their lifetime. Web Push stays in push.zig.
//!
//! Configured from the environment by the servers:
//!   FCM_SERVICE_ACCOUNT_FILE   the service account JSON (project_id, client_email, private_key)
//!   APNS_KEY_FILE, APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID   the .p8 key and its ids
//!   APNS_SANDBOX=1             development builds' tokens
//! Unset means that service is off (`send` answers `.disabled`).
//!
//! A `Message` is the same for every kind: string fields the app receives as JSON (`data`:
//! Android's data map, the custom keys of an iOS payload) and, for pushes the system may show
//! by itself, a title and body. `urgent` ones (incoming calls, dispatch alarms) are
//! high-priority data messages that wake the phone and start the app if it is not running; the
//! app decides what to show (zui's pushMessage). Others carry an FCM/APNs notification the
//! system shows when the app is in the background.

const std = @import("std");
const Io = std.Io;
const push = @import("push.zig");
const apns = @import("apns.zig");

pub const Kind = enum {
    fcm,
    apns,
    voip,

    pub fn parse(s: []const u8) ?Kind {
        return std.meta.stringToEnum(Kind, s);
    }
};

pub const Message = struct {
    /// Field names and string values for the app.
    data: []const [2][]const u8 = &.{},
    /// Shown by the system for non-urgent pushes while the app is not in front.
    title: []const u8 = "",
    body: []const u8 = "",
    urgent: bool = false,
    ttl_s: u32 = 3600,
    /// Same key: a newer push replaces an undelivered older one (and the shown notification).
    collapse: []const u8 = "",
};

pub const Result = enum { sent, gone, failed, disabled };

pub const Config = struct {
    fcm_service_account_file: ?[]const u8 = null,
    apns_key_file: ?[]const u8 = null,
    apns_key_id: ?[]const u8 = null,
    apns_team_id: ?[]const u8 = null,
    apns_bundle_id: ?[]const u8 = null,
    apns_sandbox: bool = false,
};

pub const Sender = struct {
    gpa: std.mem.Allocator,
    io: Io,
    lock: Io.Mutex = .init,
    // FCM
    sa: ?push.ServiceAccount = null,
    sa_json: ?std.json.Parsed(push.ServiceAccount) = null,
    http: std.http.Client,
    access_token: ?[]u8 = null,
    access_expires_s: i64 = 0,
    // APNs
    creds: ?apns.Credentials = null,
    apns_client: ?apns.Client = null,
    apns_env: apns.Environment = .production,
    key_pem: ?[]u8 = null,

    /// Reads the key files now; a missing or bad file turns that service off (logged, values
    /// never printed).
    pub fn init(gpa: std.mem.Allocator, io: Io, cfg: Config) Sender {
        var s: Sender = .{ .gpa = gpa, .io = io, .http = .{ .allocator = gpa, .io = io } };
        if (cfg.fcm_service_account_file) |path| if (path.len > 0) {
            if (loadServiceAccount(gpa, io, path)) |parsed| {
                s.sa_json = parsed;
                s.sa = parsed.value;
            } else |e| std.log.warn("push: FCM off: {s}: {t}", .{ path, e });
        };
        if (cfg.apns_key_file) |path| if (path.len > 0) {
            const ok = cfg.apns_key_id != null and cfg.apns_team_id != null and cfg.apns_bundle_id != null;
            if (!ok) {
                std.log.warn("push: APNs off: APNS_KEY_ID, APNS_TEAM_ID and APNS_BUNDLE_ID are needed", .{});
            } else if (Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024))) |pem| {
                s.key_pem = pem;
                s.creds = .{ .team_id = cfg.apns_team_id.?, .key_id = cfg.apns_key_id.?, .private_key = pem, .bundle_id = cfg.apns_bundle_id.? };
                s.apns_env = if (cfg.apns_sandbox) .sandbox else .production;
            } else |e| std.log.warn("push: APNs off: {s}: {t}", .{ path, e });
        };
        return s;
    }

    pub fn deinit(s: *Sender) void {
        if (s.apns_client) |*c| c.deinit();
        if (s.key_pem) |p| {
            std.crypto.secureZero(u8, p);
            s.gpa.free(p);
        }
        if (s.access_token) |t| s.gpa.free(t);
        if (s.sa_json) |*p| p.deinit();
        s.http.deinit();
    }

    pub fn enabled(s: *const Sender, kind: Kind) bool {
        return switch (kind) {
            .fcm => s.sa != null,
            .apns, .voip => s.creds != null,
        };
    }

    /// Sends one push; `.gone` means the token is dead (remove it). Safe from several tasks.
    pub fn send(s: *Sender, kind: Kind, token: []const u8, m: Message) Result {
        if (!s.enabled(kind)) return .disabled;
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        return switch (kind) {
            .fcm => s.sendFcm(token, m),
            .apns, .voip => s.sendApns(kind, token, m),
        } catch |e| {
            std.log.warn("push: {t} send failed: {t}", .{ kind, e });
            return .failed;
        };
    }

    fn sendFcm(s: *Sender, token: []const u8, m: Message) !Result {
        const sa = s.sa.?;
        const now_s = Io.Timestamp.now(s.io, .real).toSeconds();
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const body = try fcmBody(a, token, m);
        const url = try std.fmt.allocPrint(a, "https://fcm.googleapis.com/v1/projects/{s}/messages:send", .{sa.project_id});
        var attempt: usize = 0;
        while (attempt < 2) : (attempt += 1) {
            if (s.access_token == null or now_s >= s.access_expires_s or attempt > 0) {
                if (s.access_token) |t| s.gpa.free(t);
                s.access_token = null;
                s.access_token = try push.fcmAccessToken(&s.http, s.gpa, sa, now_s);
                s.access_expires_s = now_s + 55 * 60;
            }
            const auth = try std.fmt.allocPrint(a, "Bearer {s}", .{s.access_token.?});
            var out: std.ArrayList(u8) = .empty; // grown with the HTTP client's allocator
            defer out.deinit(s.gpa);
            const status = try push.postRaw(&s.http, url, body, &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "authorization", .value = auth },
            }, &out);
            switch (@intFromEnum(status)) {
                200...299 => return .sent,
                401 => continue, // the access token: a new one, once
                404 => return .gone, // UNREGISTERED
                400 => return if (std.mem.indexOf(u8, out.items, "registration token") != null or std.mem.indexOf(u8, out.items, "INVALID_ARGUMENT") != null) .gone else .failed,
                else => {
                    std.log.warn("push: FCM HTTP {d}", .{@intFromEnum(status)});
                    return .failed;
                },
            }
        }
        return .failed;
    }

    fn sendApns(s: *Sender, kind: Kind, token: []const u8, m: Message) !Result {
        if (s.apns_client == null) s.apns_client = try apns.Client.init(s.gpa, s.io, s.creds.?);
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const payload = try apnsPayload(a, kind, m);
        const now_s = Io.Timestamp.now(s.io, .real).toSeconds();
        const res = try s.apns_client.?.send(token, payload, .{
            .environment = s.apns_env,
            .push_type = if (kind == .voip) .voip else if (m.title.len == 0 and m.body.len == 0) .background else .alert,
            .priority = if (m.urgent or kind == .voip) 10 else 5,
            .expiration = now_s + m.ttl_s,
            .collapse_id = if (m.collapse.len > 0 and m.collapse.len <= 64) m.collapse else null,
        });
        if (res.status >= 200 and res.status < 300) return .sent;
        if (res.tokenGone()) return .gone;
        std.log.warn("push: APNs {d} {s}", .{ res.status, res.reason() });
        return .failed;
    }
};

fn loadServiceAccount(gpa: std.mem.Allocator, io: Io, path: []const u8) !std.json.Parsed(push.ServiceAccount) {
    const text = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024));
    defer {
        std.crypto.secureZero(u8, text);
        gpa.free(text);
    }
    return std.json.parseFromSlice(push.ServiceAccount, gpa, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

fn writeData(w: *std.Io.Writer, m: Message) !void {
    try w.writeByte('{');
    for (m.data, 0..) |kv, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{f}:{f}", .{ std.json.fmt(kv[0], .{}), std.json.fmt(kv[1], .{}) });
    }
    try w.writeByte('}');
}

/// The FCM HTTP v1 request body.
pub fn fcmBody(a: std.mem.Allocator, token: []const u8, m: Message) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print("{{\"message\":{{\"token\":{f},\"data\":", .{std.json.fmt(token, .{})});
    try writeData(w, m);
    try w.print(",\"android\":{{\"priority\":\"{s}\",\"ttl\":\"{d}s\"", .{ if (m.urgent) "high" else "normal", m.ttl_s });
    if (m.collapse.len > 0) try w.print(",\"collapse_key\":{f}", .{std.json.fmt(m.collapse, .{})});
    if (!m.urgent and (m.title.len > 0 or m.body.len > 0)) {
        try w.writeAll(",\"notification\":{");
        if (m.collapse.len > 0) try w.print("\"tag\":{f},", .{std.json.fmt(m.collapse, .{})});
        try w.writeAll("\"channel_id\":\"zui-normal\",\"default_sound\":true}");
    }
    try w.writeByte('}');
    if (!m.urgent and (m.title.len > 0 or m.body.len > 0))
        try w.print(",\"notification\":{{\"title\":{f},\"body\":{f}}}", .{ std.json.fmt(m.title, .{}), std.json.fmt(m.body, .{}) });
    try w.writeAll("}}");
    return out.written();
}

/// The APNs payload: "aps" plus the data fields at the top level.
pub fn apnsPayload(a: std.mem.Allocator, kind: Kind, m: Message) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll("{\"aps\":{");
    if (kind == .voip) {
        // PushKit: the app reports the call to CallKit itself.
    } else if (m.title.len == 0 and m.body.len == 0) {
        try w.writeAll("\"content-available\":1");
    } else {
        try w.print("\"alert\":{{\"title\":{f},\"body\":{f}}},\"sound\":\"default\"", .{ std.json.fmt(m.title, .{}), std.json.fmt(m.body, .{}) });
        if (m.urgent) try w.writeAll(",\"interruption-level\":\"time-sensitive\"");
        if (m.collapse.len > 0) try w.print(",\"thread-id\":{f}", .{std.json.fmt(m.collapse, .{})});
    }
    try w.writeByte('}');
    for (m.data) |kv| {
        if (std.mem.eql(u8, kv[0], "aps")) continue;
        try w.print(",{f}:{f}", .{ std.json.fmt(kv[0], .{}), std.json.fmt(kv[1], .{}) });
    }
    try w.writeByte('}');
    return out.written();
}

const testing = std.testing;

test "FCM bodies: urgent data, normal with a notification" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = [_][2][]const u8{ .{ "type", "call" }, .{ "callId", "c\"1" } };
    const urgent = try fcmBody(a, "tok", .{ .data = &data, .urgent = true, .ttl_s = 45, .title = "Hala" });
    try testing.expectEqualStrings("{\"message\":{\"token\":\"tok\",\"data\":{\"type\":\"call\",\"callId\":\"c\\\"1\"},\"android\":{\"priority\":\"high\",\"ttl\":\"45s\"}}}", urgent);
    _ = try std.json.parseFromSliceLeaky(std.json.Value, a, urgent, .{});
    const normal = try fcmBody(a, "tok", .{ .data = &data, .title = "T", .body = "B", .collapse = "chat-1" });
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, normal, .{});
    const msg = v.object.get("message").?.object;
    try testing.expectEqualStrings("normal", msg.get("android").?.object.get("priority").?.string);
    try testing.expectEqualStrings("chat-1", msg.get("android").?.object.get("collapse_key").?.string);
    try testing.expectEqualStrings("T", msg.get("notification").?.object.get("title").?.string);
}

test "APNs payloads: alert, VoIP, background" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = [_][2][]const u8{.{ "callId", "c1" }};
    const voip = try apnsPayload(a, .voip, .{ .data = &data, .urgent = true, .title = "x" });
    try testing.expectEqualStrings("{\"aps\":{},\"callId\":\"c1\"}", voip);
    const alert = try apnsPayload(a, .apns, .{ .data = &data, .title = "T", .body = "B", .urgent = true });
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, alert, .{});
    try testing.expectEqualStrings("time-sensitive", v.object.get("aps").?.object.get("interruption-level").?.string);
    try testing.expectEqualStrings("c1", v.object.get("callId").?.string);
    const bg = try apnsPayload(a, .apns, .{ .data = &data });
    try testing.expect(std.mem.indexOf(u8, bg, "content-available") != null);
}

test "a sender without configuration is off" {
    var s = Sender.init(testing.allocator, testing.io, .{});
    defer s.deinit();
    try testing.expectEqual(Result.disabled, s.send(.fcm, "t", .{}));
    try testing.expectEqual(Result.disabled, s.send(.voip, "ab", .{}));
}
