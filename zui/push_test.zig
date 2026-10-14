//! Push on the headless host: registering, the token, and a push that wakes the app before it
//! has a screen.

const std = @import("std");
const zui = @import("zui.zig");
const headless = @import("host/headless.zig");

const testing = std.testing;

const PushApp = struct {
    pub const Msg = union(enum) {
        boot,
        register,
        token: struct { kind: zui.PushKind, len: usize },
        call: [16]u8,
    };
    pub const boot: Msg = .boot;
    pub const State = struct {
        booted: bool = false,
        token_kind: ?zui.PushKind = null,
        token_len: usize = 0,
        rendered: u32 = 0,
    };
    pub fn init() State {
        return .{};
    }
    pub fn pushToken(token: []const u8, kind: zui.PushKind) ?Msg {
        return .{ .token = .{ .kind = kind, .len = token.len } };
    }
    /// {"type":"call","callId":"..."} rings at once; anything else is ignored.
    pub fn pushMessage(json: []const u8) ?Msg {
        if (std.mem.indexOf(u8, json, "\"type\":\"call\"") == null) return null;
        var id: [16]u8 = @splat(' ');
        const at = std.mem.indexOf(u8, json, "\"callId\":\"") orelse return null;
        const rest = json[at + 10 ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
        const n = @min(end, id.len);
        @memcpy(id[0..n], rest[0..n]);
        return .{ .call = id };
    }
    pub fn update(s: *State, m: Msg, _: zui.Env, fx: zui.Fx(Msg)) void {
        switch (m) {
            .boot => s.booted = true,
            .register => fx.registerPush(.{ .web_key = "BKEY" }),
            .token => |t| {
                s.token_kind = t.kind;
                s.token_len = t.len;
            },
            .call => |id| fx.ringCall(.{ .id = std.mem.trimEnd(u8, &id, " "), .name = "Hala", .label = "مكالمة صوتية" }),
        }
    }
    pub fn view(s: *const State, ui: *zui.Ui(Msg)) void {
        @constCast(s).rendered += 1;
        ui.begin(.{}, .{});
        ui.text("push", .{});
        ui.end();
    }
};

test "push: a call push wakes the app without a screen; the screen comes later with the state" {
    const D = headless.Driver(PushApp);
    D.startHeadless();
    defer D.reset();
    try testing.expect(!D.R.appState().booted);
    D.R.pushMessage("{\"type\":\"call\",\"callId\":\"c42\",\"title\":\"Hala\"}");
    try testing.expectEqualStrings("c42", headless.ringing.items);
    try testing.expectEqualStrings("مكالمة صوتية", headless.ringing_label.items);
    try testing.expectEqual(@as(u32, 0), D.R.appState().rendered);
    try testing.expectEqual(@as(usize, 0), headless.views.count());

    // The user opens the app: drawn now, booted now, the state kept.
    D.R.start(std.heap.page_allocator, .{ .width = 300, .height = 400 }, "en");
    try testing.expect(D.R.appState().booted);
    try testing.expect(D.R.appState().rendered > 0);
    try testing.expect(headless.views.count() > 0);

    D.R.dispatch(.register);
    try testing.expectEqual(@as(u32, 1), headless.push_registered);
    try testing.expectEqualStrings("BKEY", headless.push_web_key.items);
    D.R.pushToken("fcm-token-123", .fcm);
    try testing.expectEqual(@as(?zui.PushKind, .fcm), D.R.appState().token_kind);
    try testing.expectEqual(@as(usize, 13), D.R.appState().token_len);
    D.R.pushMessage("{\"type\":\"message\"}");
}
