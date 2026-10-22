//! The Wufour account menu, drawn by zui: the same profile picture and menu as the web's
//! <wufour-account> element (Wufour's public/widgets/account.js, see its docs/account-menu.md),
//! so one Wufour account looks the same in every app, on the web and on the phones.
//!
//! The panel, from top to bottom: the person ("Hi, name!", Manage your Wufour account, signed-in
//! devices, Control for administrators, sign out), the app's own items, then the person's four
//! apps from the Wufour start page, in the order they chose there, and the red All apps button.
//!
//! The data is Wufour's POST /api/account/menu answer. The app's server asks for it with the
//! session token (`wufour.Verifier.accountMenu` in zig-core's server helpers) and serves it to its
//! client, which passes the body to `Menu.load`.
//!
//!     // state
//!     menu: zui.account.Menu = .{},
//!     // Msg
//!     account: zui.account.Action,
//!     fn onAccount(a: zui.account.Action) Msg { return .{ .account = a }; }
//!     // view: the picture where it belongs, the panel last (above everything)
//!     zui.account.picture(Msg, ui, &s.menu, o, 40);
//!     ...
//!     zui.account.panel(Msg, ui, &s.menu, o);
//!     // update
//!     .account => |act| if (s.menu.update(Msg, act, fx)) |left| switch (left) {
//!         .sign_in => ..., .sign_out => ..., .item => |i| ...,
//!         else => {},
//!     },

const std = @import("std");
const runtime = @import("runtime.zig");
const col = @import("color.zig");
const st = @import("style.zig");
const Icon = @import("icon.zig").Icon;
const Color = col.Color;

// ---------------------------------------------------------------------------------------------
// Data: Wufour's answer
// ---------------------------------------------------------------------------------------------

pub const Kind = struct { en: []const u8 = "", ar: []const u8 = "" };

pub const App = struct {
    slug: []const u8 = "",
    name: []const u8 = "",
    ar: []const u8 = "",
    kind: Kind = .{},
    url: []const u8 = "",
    /// The phones cannot draw SVG; this is Wufour's PNG copy of the logo. Null: the initial.
    logoPng: ?[]const u8 = null,
    color: []const u8 = "#888888",
};

pub const User = struct { username: []const u8 = "", email: []const u8 = "" };

pub const Links = struct {
    home: []const u8 = "",
    about: []const u8 = "",
    account: ?[]const u8 = null,
    devices: ?[]const u8 = null,
    control: ?[]const u8 = null,
    signIn: []const u8 = "",
    signUp: []const u8 = "",
    signOut: []const u8 = "",
};

pub const Data = struct {
    signedIn: bool = false,
    user: ?User = null,
    links: Links = .{},
    dock: []const []const u8 = &.{},
    apps: []const App = &.{},
};

/// Which of Wufour's pages a press opens.
pub const Page = enum { home, about, account, devices, control };

/// What the menu asks for. `Menu.update` does the menu's own (open, close, All apps, Wufour's
/// pages, the apps) and hands back what is the app's: sign in, sign out and its items.
pub const Action = union(enum) {
    /// Nothing (a press on the panel's own background, so it does not reach what is behind).
    none,
    toggle,
    close,
    all,
    page: Page,
    /// An app of the row or of All apps, by its index in `Data.apps`.
    app: u16,
    sign_in,
    sign_out,
    /// One of the app's own items, by its index in `Options.items`.
    item: u16,
};

/// The menu's state, kept in the app's state.
pub const Menu = struct {
    open: bool = false,
    all: bool = false,
    data: ?Data = null,
    arena: ?std.heap.ArenaAllocator = null,

    /// Takes Wufour's answer (the body of the app server's account-menu route). A body that is
    /// not the menu keeps what was there.
    pub fn load(m: *Menu, json: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(@import("zui.zig").allocator);
        const d = std.json.parseFromSliceLeaky(Data, arena.allocator(), json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            arena.deinit();
            return;
        };
        m.deinit();
        m.arena = arena;
        m.data = d;
    }

    pub fn deinit(m: *Menu) void {
        if (m.arena) |*a| a.deinit();
        m.arena = null;
        m.data = null;
    }

    /// Does the menu's own actions (opening a page or an app with `fx.openUrl`) and returns the
    /// rest for the app: `.sign_in`, `.sign_out` and `.item`. Null: nothing left to do.
    pub fn update(m: *Menu, comptime Msg: type, act: Action, fx: runtime.Fx(Msg)) ?Action {
        switch (act) {
            .none => {},
            .toggle => {
                m.open = !m.open;
                m.all = false;
            },
            .close => {
                m.open = false;
                m.all = false;
            },
            .all => m.all = !m.all,
            .page => |p| {
                m.open = false;
                if (m.pageUrl(p)) |u| fx.openUrl(u, false);
            },
            .app => |i| {
                m.open = false;
                const d = m.data orelse return null;
                if (i < d.apps.len and d.apps[i].url.len > 0) fx.openUrl(d.apps[i].url, false);
            },
            .sign_in, .sign_out, .item => {
                m.open = false;
                m.all = false;
                return act;
            },
        }
        return null;
    }

    /// Escape (the app's `keyEvent`): closes the menu when it is open.
    pub fn escape(m: *const Menu) ?Action {
        return if (m.open) .close else null;
    }

    pub fn pageUrl(m: *const Menu, p: Page) ?[]const u8 {
        const l = (m.data orelse return null).links;
        const u = switch (p) {
            .home => l.home,
            .about => l.about,
            .account => l.account orelse return null,
            .devices => l.devices orelse return null,
            .control => l.control orelse return null,
        };
        return if (u.len > 0) u else null;
    }
};

/// One of the app's own items, between the account part and the apps.
pub const Item = struct {
    label: []const u8,
    icon: Icon,
    /// Shown at the end (0: none).
    count: u32 = 0,
    /// The page the app is on.
    current: bool = false,
};

pub fn Options(comptime Msg: type) type {
    return struct {
        /// The app's message for a menu action.
        msg: *const fn (Action) Msg,
        /// Arabic (right to left) rather than English.
        ar: bool = false,
        /// This app's slug ("turf"): marked in the row.
        app: []const u8 = "",
        /// The person as the app knows them: drawn before Wufour answers, and when it cannot.
        name: []const u8 = "",
        email: []const u8 = "",
        /// The person's photo in this app, if it has one (Reseal's profile picture): shown over the
        /// initial, in the picture and in the panel.
        photo: []const u8 = "",
        /// The app is signed out: the menu offers sign-in, even when Wufour answers for someone.
        signed_out: bool = false,
        items: []const Item = &.{},
        /// Where the panel opens, from the screen's edges (the panel is placed on the view's root).
        anchor: st.Inset = .{ .top = 64, .end = 12 },
    };
}

// ---------------------------------------------------------------------------------------------
// Words
// ---------------------------------------------------------------------------------------------

const Words = struct {
    account: []const u8,
    hi: []const u8,
    manage: []const u8,
    close: []const u8,
    devices: []const u8,
    control: []const u8,
    sign_out: []const u8,
    sign_in: []const u8,
    sign_up: []const u8,
    signed_out: []const u8,
    signed_out_body: []const u8,
    apps: []const u8,
    all_apps: []const u8,
    arrange: []const u8,
    about: []const u8,
    wufour: []const u8,
};

const en: Words = .{
    .account = "Wufour account",
    .hi = "Hi, {s}!",
    .manage = "Manage your Wufour account",
    .close = "Close",
    .devices = "Signed-in devices",
    .control = "Control",
    .sign_out = "Sign out",
    .sign_in = "Sign in",
    .sign_up = "Create an account",
    .signed_out = "Not signed in",
    .signed_out_body = "One Wufour account opens every app.",
    .apps = "Your apps",
    .all_apps = "All apps",
    .arrange = "Arrange your apps on Wufour",
    .about = "About",
    .wufour = "Wufour",
};

const ar: Words = .{
    .account = "حساب وفور",
    .hi = "أهلاً، {s}!",
    .manage = "إدارة حسابك في وفور",
    .close = "إغلاق",
    .devices = "الأجهزة المسجّلة",
    .control = "لوحة تحكم وفور",
    .sign_out = "تسجيل الخروج",
    .sign_in = "تسجيل الدخول",
    .sign_up = "أنشئ حساباً",
    .signed_out = "لم تسجّل الدخول",
    .signed_out_body = "حساب وفور واحد يفتح كل التطبيقات.",
    .apps = "تطبيقاتك",
    .all_apps = "كل التطبيقات",
    .arrange = "رتّب تطبيقاتك على وفور",
    .about = "عن وفور",
    .wufour = "وفور",
};

// ---------------------------------------------------------------------------------------------
// Colours: Wufour's TwOP scheme and its dark-mode transforms (Wufour's public/styles/style.css)
// ---------------------------------------------------------------------------------------------

const base = Color.hex("#f9f9f9");
const core = Color.hex("#090909");
const accent = Color.hex("#d5a454");
const variant = Color.hex("#005454");
const surface = Color.hex("#eef5f4");
const depth = Color.hex("#054540");
const fatal = Color.hex("#F05454");
const prime = Color.hex("#540540");

/// `oklch(from C clamp(lo, 1 - l*l, hi) c*k h)`, with k = max(floor, 1 - l*slope).
fn darkOf(c: Color, lo: f32, hi: f32, floor: f32, slope: f32) Color {
    var o = c.toOklch();
    const k = @max(floor, 1 - o.l * slope);
    o.l = std.math.clamp(1 - o.l * o.l, lo, hi);
    o.c *= k;
    return o.toColor();
}

pub const Colors = struct {
    b: Color,
    c: Color,
    a: Color,
    v: Color,
    f: Color,
    ink: Color,
    ink_2: Color,
    ink_3: Color,
    sheet: Color,
    card: Color,
    line: Color,
    line_strong: Color,
    gold_soft: Color,
    teal_soft: Color,
    brand_ink: Color,
    deep: Color,
    plum: Color,
    dark: bool,

    pub fn of(dark: bool) Colors {
        // canvas and surface: clamp(.10, .25) c*.5; text: (.85, .95) c*.6; border: (.25, .40) c*.4;
        // brand: (.25, .55) c*max(.6, 1-l*.4); action: (.45, .75) c*max(.7, 1-l*.3); signal: (.45, .80) c*max(.75, 1-l*.25)
        const b = if (dark) darkOf(base, 0.10, 0.25, 0.5, 0) else base;
        const c = if (dark) darkOf(core, 0.85, 0.95, 0.6, 0) else core;
        const s = if (dark) darkOf(surface, 0.10, 0.25, 0.5, 0) else surface;
        const d = if (dark) darkOf(depth, 0.25, 0.40, 0.4, 0) else depth;
        const p = if (dark) darkOf(prime, 0.25, 0.55, 0.6, 0.4) else prime;
        const a = if (dark) darkOf(accent, 0.45, 0.75, 0.7, 0.3) else accent;
        const v = if (dark) darkOf(variant, 0.45, 0.75, 0.7, 0.3) else variant;
        const f = if (dark) darkOf(fatal, 0.45, 0.80, 0.75, 0.25) else fatal;
        return .{
            .b = b,
            .c = c,
            .a = a,
            .v = v,
            .f = f,
            .ink = c,
            .ink_2 = c.withAlpha(0.72),
            .ink_3 = c.withAlpha(0.5),
            // The panel is the tinted surface with lighter cards; in dark mode the cards are lifted.
            .sheet = if (dark) b.mix(0.97, c) else s,
            .card = if (dark) b.mix(0.90, c) else b,
            .line = d.withAlpha(0.18),
            .line_strong = d.withAlpha(0.36),
            .gold_soft = a.withAlpha(0.16),
            .teal_soft = v.withAlpha(0.12),
            .brand_ink = if (dark) p.mix(0.45, c) else p,
            .deep = d,
            .plum = p,
            .dark = dark,
        };
    }
};

// ---------------------------------------------------------------------------------------------
// Icons (Wufour's line icons, in path data)
// ---------------------------------------------------------------------------------------------

fn line(comptime paths: []const []const u8) Icon {
    return .{ .paths = paths, .stroke = 1.8 };
}

pub const icons = struct {
    pub const devices = line(&.{ "M5 5h9a2 2 0 0 1 2 2v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2Z", "M7 19h5M9.5 15v4", "M18.5 9h1a1.5 1.5 0 0 1 1.5 1.5v7a1.5 1.5 0 0 1-1.5 1.5h-1a1.5 1.5 0 0 1-1.5-1.5v-7A1.5 1.5 0 0 1 18.5 9Z" });
    pub const shield = line(&.{ "M12 3 5 6v6c0 4.5 3 7.5 7 9 4-1.5 7-4.5 7-9V6l-7-3Z", "m9 12 2 2 4-4" });
    pub const logout = line(&.{"M10 4H6a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h4M14 8l4 4-4 4M18 12H9"});
    pub const login = line(&.{"M14 4h4a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-4M10 8l4 4-4 4M14 12H4"});
    pub const user = line(&.{ "M16 8a4 4 0 1 1-8 0a4 4 0 1 1 8 0Z", "M4 21c0-4 3.6-6.5 8-6.5s8 2.5 8 6.5" });
    pub const close = line(&.{"M6 6l12 12M18 6 6 18"});
    pub const arrow: Icon = .{ .paths = &.{"M5 12h14M13 6l6 6-6 6"}, .stroke = 1.8, .rtl_mirror = true };
    // For the apps' own items:
    pub const box = line(&.{ "m12 3 8 4.5v9L12 21l-8-4.5v-9L12 3Z", "M4 7.5 12 12l8-4.5M12 12v9" });
    pub const truck = line(&.{ "M3 7h11v9H3zM14 10h4l3 3v3h-7z", "M9 18a2 2 0 1 1-4 0a2 2 0 1 1 4 0Z", "M19 18a2 2 0 1 1-4 0a2 2 0 1 1 4 0Z" });
    pub const pin = line(&.{ "M12 21s-7-6.2-7-11a7 7 0 0 1 14 0c0 4.8-7 11-7 11Z", "M14.5 10a2.5 2.5 0 1 1-5 0a2.5 2.5 0 1 1 5 0Z" });
    pub const chat = line(&.{"M4 6a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H9l-5 4V6Z"});
    pub const globe = line(&.{ "M21 12a9 9 0 1 1-18 0a9 9 0 1 1 18 0Z", "M3 12h18M12 3c3 3.5 3 14.5 0 18M12 3c-3 3.5-3 14.5 0 18" });
    pub const settings = line(&.{ "M15 12a3 3 0 1 1-6 0a3 3 0 1 1 6 0Z", "M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1Z" });
    pub const users = line(&.{ "M12.5 8a3.5 3.5 0 1 1-7 0a3.5 3.5 0 1 1 7 0Z", "M2.5 20c0-3.5 3-6 6.5-6s6.5 2.5 6.5 6", "M19.5 9a2.5 2.5 0 1 1-5 0a2.5 2.5 0 1 1 5 0Z", "M15.5 14.5c3 0 6 2 6 5.5" });
    pub const code = line(&.{"m8 8-5 4 5 4M16 8l5 4-5 4M14 4l-4 16"});
    pub const grid = line(&.{ "M5.5 4h4A1.5 1.5 0 0 1 11 5.5v4A1.5 1.5 0 0 1 9.5 11h-4A1.5 1.5 0 0 1 4 9.5v-4A1.5 1.5 0 0 1 5.5 4Z", "M14.5 4h4A1.5 1.5 0 0 1 20 5.5v4a1.5 1.5 0 0 1-1.5 1.5h-4A1.5 1.5 0 0 1 13 9.5v-4A1.5 1.5 0 0 1 14.5 4Z", "M5.5 13h4a1.5 1.5 0 0 1 1.5 1.5v4A1.5 1.5 0 0 1 9.5 20h-4A1.5 1.5 0 0 1 4 18.5v-4A1.5 1.5 0 0 1 5.5 13Z", "M14.5 13h4a1.5 1.5 0 0 1 1.5 1.5v4a1.5 1.5 0 0 1-1.5 1.5h-4a1.5 1.5 0 0 1-1.5-1.5v-4a1.5 1.5 0 0 1 1.5-1.5Z" });
    pub const bell = line(&.{"M6 16V11a6 6 0 0 1 12 0v5l2 2H4l2-2ZM10 20a2 2 0 0 0 4 0"});
    pub const user_circle = line(&.{ "M21 12a9 9 0 1 1-18 0a9 9 0 1 1 18 0Z", "M15 10a3 3 0 1 1-6 0a3 3 0 1 1 6 0Z", "M6.2 18.4c1.2-1.9 3.3-3 5.8-3s4.6 1.1 5.8 3" });
};

/// Wufour's mark: four diamonds (gold, teal, plum, depth) forming one.
const mark_parts = [_][]const u8{ "M32 3 47 18 32 33 17 18Z", "M47 18 61 32 47 46 33 32Z", "M32 33 47 46 32 61 17 46Z", "M17 18 31 32 17 46 3 32Z" };

// ---------------------------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------------------------

/// What is shown: Wufour's answer, with the app's own state first (it knows best whether it is
/// signed in; Wufour's answer may be for a session the app does not use).
const View = struct {
    user: ?User,
    dock: []const u16,
    data: Data,
};

fn viewOf(comptime Msg: type, a: std.mem.Allocator, m: *const Menu, o: Options(Msg)) View {
    const d = m.data orelse Data{};
    var user: ?User = if (d.signedIn) d.user else null;
    if (o.signed_out) user = null else if (o.name.len > 0) user = .{ .username = o.name, .email = if (o.email.len > 0) o.email else if (user) |u| u.email else "" };
    var dock: std.ArrayList(u16) = .empty;
    for (d.dock) |slug| for (d.apps, 0..) |app, i| {
        if (std.mem.eql(u8, app.slug, slug)) dock.append(a, @intCast(i)) catch {};
    };
    return .{ .user = user, .dock = dock.items, .data = d };
}

/// `template` with its {s} replaced by `value` (in `a`).
fn fill(a: std.mem.Allocator, template: []const u8, value: []const u8) []const u8 {
    return std.mem.replaceOwned(u8, a, template, "{s}", value) catch template;
}

fn initialOf(name: []const u8) []const u8 {
    const t = std.mem.trim(u8, name, " \t");
    if (t.len == 0) return "";
    const n = std.unicode.utf8ByteSequenceLength(t[0]) catch 1;
    return t[0..@min(n, t.len)];
}

fn avatar(comptime Msg: type, ui: *runtime.Ui(Msg), k: Colors, user: ?User, photo: []const u8, waiting: bool, size: f32, key: u64) void {
    const style: st.Style = .{ .width = .{ .px = size }, .height = .{ .px = size }, .radius = size / 2, .align_items = .center, .justify = .center, .clip = true };
    if (user) |u| {
        var s = style;
        s.background = k.a;
        s.gradient = st.Gradient.linear(135, &.{ .{ .color = k.a, .at = 0 }, .{ .color = k.plum, .at = 1 } });
        ui.begin(s, .{ .key = key });
        const initial = initialOf(if (u.username.len > 0) u.username else u.email);
        const upper = std.ascii.allocUpperString(ui.arena(), initial) catch initial;
        ui.text(upper, .{ .font_size = size * 0.42, .weight = 800, .color = base, .line_height = 1 });
        if (photo.len > 0) ui.image(photo, .{ .position = .absolute, .inset = .{ .top = 0, .start = 0 }, .width = .{ .px = size }, .height = .{ .px = size }, .fit = .cover }, runtime.key(photo) +% key);
        ui.end();
        return;
    }
    var s = style;
    s.background = k.sheet;
    s.border_width = 1;
    s.border_color = if (waiting) k.line else k.line_strong;
    ui.begin(s, .{ .key = key });
    if (!waiting) ui.icon(icons.user, size * 0.56, k.ink_2, .{}, 0);
    ui.end();
}

/// The round profile picture that opens the menu. `size` in points (40 in most bars).
pub fn picture(comptime Msg: type, ui: *runtime.Ui(Msg), m: *const Menu, o: Options(Msg), size: f32) void {
    const k = Colors.of(ui.env.dark);
    const v = viewOf(Msg, ui.arena(), m, o);
    const w = if (o.ar) ar else en;
    const label = if (v.user) |u| std.fmt.allocPrint(ui.arena(), "{s}: {s}", .{ w.account, if (u.username.len > 0) u.username else u.email }) catch w.account else w.account;
    // The ring: gold while the menu is open, the variant's tint on hover.
    ui.begin(.{
        .padding = .all(3),
        .radius = size / 2 + 3,
        .border_width = 2.5,
        .border_color = if (m.open) k.a else Color.transparent,
        .hover_background = k.teal_soft,
        .pressed_opacity = 0.85,
        .transition = .{ .duration_ms = 200 },
    }, .{ .on_press = o.msg(.toggle), .label = label, .key = runtime.key("wufour-account") });
    avatar(Msg, ui, k, v.user, o.photo, m.data == null and o.name.len == 0 and !o.signed_out, size, runtime.key("wufour-account-pic"));
    ui.end();
}

/// The menu, when it is open: draw it last in the view's root, so it sits above everything.
pub fn panel(comptime Msg: type, ui: *runtime.Ui(Msg), m: *const Menu, o: Options(Msg)) void {
    if (!m.open) return;
    const k = Colors.of(ui.env.dark);
    const v = viewOf(Msg, ui.arena(), m, o);
    const w = if (o.ar) ar else en;
    const env = ui.env;
    ui.onBack(o.msg(.close));

    // A press anywhere else closes it.
    ui.begin(.{ .position = .absolute, .inset = .{ .top = 0, .bottom = 0, .start = 0, .end = 0 }, .background = Color.transparent }, .{ .on_press = o.msg(.close), .key = runtime.key("wufour-account-scrim") });
    ui.end();

    // Phones: the screen's width less a margin; elsewhere 380 points at the anchor.
    const phone = env.width <= 520;
    const width = @min(380, env.width - 16);
    var inset = o.anchor;
    if (phone) {
        inset.start = 8;
        inset.end = null;
    }
    const top = inset.top orelse 64;
    const room = if (inset.bottom) |b| env.height - b - 8 else env.height - top - 8;
    ui.begin(.{
        .position = .absolute,
        .inset = inset,
        .width = .{ .px = width },
        .max_height = @max(200, room),
        .radius = 30,
        .background = k.sheet,
        .border_width = 1,
        .border_color = k.line,
        .shadow = .{ .y = 24, .blur = 60, .color = k.deep.withAlpha(if (k.dark) 0.55 else 0.35) },
        .clip = true,
    }, .{ .key = runtime.key("wufour-account-panel"), .on_press = o.msg(.none) });
    ui.beginScroll(.{ .padding = .all(10), .max_height = @max(200, room) }, runtime.key("wufour-account-scroll"));
    head(Msg, ui, k, w, v, o);
    if (v.user != null) accountCard(Msg, ui, k, w, v, o);
    ownItems(Msg, ui, k, o);
    appsCard(Msg, ui, k, w, v, m, o);
    foot(Msg, ui, k, w, o);
    ui.end();
    ui.end();
}

fn head(comptime Msg: type, ui: *runtime.Ui(Msg), k: Colors, w: Words, v: View, o: Options(Msg)) void {
    // The email in the middle, the close button at the end.
    ui.begin(.{ .direction = .row, .align_items = .center, .min_height = 40, .padding = .{ .start = 40 } }, .{});
    ui.text(if (v.user) |u| u.email else "", .{ .grow = 1, .text_align = .center, .font_size = 13.5, .weight = 600, .color = k.ink_2, .max_lines = 1 });
    ui.begin(.{ .width = .{ .px = 40 }, .height = .{ .px = 40 }, .radius = 20, .align_items = .center, .justify = .center, .hover_background = k.teal_soft, .pressed_background = k.teal_soft }, .{ .on_press = o.msg(.close), .label = w.close, .key = runtime.key("wufour-account-close") });
    ui.icon(icons.close, 18, k.ink_2, .{}, 0);
    ui.end();
    ui.end();

    ui.begin(.{ .align_items = .center, .gap = 10, .padding = .{ .top = 12, .bottom = 20, .start = 16, .end = 16 } }, .{});
    if (v.user) |u| {
        ui.begin(.{ .padding = .all(4), .radius = 42, .background = k.card, .border_width = 1, .border_color = k.line }, .{});
        avatar(Msg, ui, k, u, o.photo, false, 72, runtime.key("wufour-account-big"));
        ui.end();
        const name = if (u.username.len > 0) u.username else u.email;
        ui.text(fill(ui.arena(), w.hi, name), .{ .font_size = 21, .weight = 700, .color = k.brand_ink, .text_align = .center, .line_height = 1.25 });
        if (v.data.links.account != null) {
            ui.begin(.{ .direction = .row, .align_items = .center, .height = .{ .px = 40 }, .padding = .xy(22, 0), .radius = 999, .border_width = 1, .border_color = k.line_strong, .background = k.card, .hover_background = k.teal_soft, .pressed_background = k.teal_soft }, .{ .on_press = o.msg(.{ .page = .account }), .key = runtime.key("wufour-account-manage") });
            ui.text(w.manage, .{ .font_size = 14, .weight = 700, .color = k.ink });
            ui.end();
        }
        return ui.end();
    }
    avatar(Msg, ui, k, null, "", false, 76, 0);
    ui.text(w.signed_out, .{ .font_size = 21, .weight = 700, .color = k.brand_ink, .text_align = .center });
    ui.text(w.signed_out_body, .{ .font_size = 14, .color = k.ink_2, .text_align = .center });
    ui.begin(.{ .direction = .row, .wrap = true, .justify = .center, .gap = 8, .padding = .{ .top = 6 } }, .{});
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 8, .height = .{ .px = 42 }, .padding = .xy(20, 0), .radius = 999, .background = k.a, .pressed_opacity = 0.85, .hover_background = k.v }, .{ .on_press = o.msg(.sign_in), .key = runtime.key("wufour-account-signin") });
    ui.icon(icons.login, 18, core, .{}, 0);
    ui.text(w.sign_in, .{ .font_size = 14.4, .weight = 700, .color = core });
    ui.end();
    ui.begin(.{ .direction = .row, .align_items = .center, .height = .{ .px = 42 }, .padding = .xy(20, 0), .radius = 999, .border_width = 1, .border_color = k.line_strong, .background = k.card, .hover_background = k.teal_soft, .pressed_background = k.teal_soft }, .{ .on_press = o.msg(.sign_in), .key = runtime.key("wufour-account-signup") });
    ui.text(w.sign_up, .{ .font_size = 14.4, .weight = 700, .color = k.ink });
    ui.end();
    ui.end();
    ui.end();
}

fn row(comptime Msg: type, ui: *runtime.Ui(Msg), k: Colors, ic: Icon, label: []const u8, count: u32, current: bool, msg: Msg, key: u64) void {
    ui.begin(.{
        .direction = .row,
        .align_items = .center,
        .gap = 14,
        .min_height = 50,
        .padding = .xy(16, 8),
        .radius = 18,
        .background = if (current) k.gold_soft else null,
        .hover_background = k.teal_soft,
        .pressed_background = k.teal_soft,
    }, .{ .on_press = msg, .key = key });
    ui.icon(ic, 20, k.ink_2, .{}, 0);
    ui.text(label, .{ .grow = 1, .font_size = 14.7, .weight = 600, .color = k.ink, .max_lines = 1 });
    if (count > 0) {
        const s = std.fmt.allocPrint(ui.arena(), "{d}", .{count}) catch "";
        ui.text(s, .{ .font_size = 13, .weight = 700, .color = k.ink_3 });
    }
    ui.end();
}

fn cardBegin(comptime Msg: type, ui: *runtime.Ui(Msg), k: Colors) void {
    ui.begin(.{ .background = k.card, .radius = 24, .padding = .all(6), .gap = 0 }, .{});
}

fn accountCard(comptime Msg: type, ui: *runtime.Ui(Msg), k: Colors, w: Words, v: View, o: Options(Msg)) void {
    cardBegin(Msg, ui, k);
    if (v.data.links.devices != null) row(Msg, ui, k, icons.devices, w.devices, 0, false, o.msg(.{ .page = .devices }), runtime.key("wufour-account-devices"));
    if (v.data.links.control != null and !std.mem.eql(u8, o.app, "control")) row(Msg, ui, k, icons.shield, w.control, 0, false, o.msg(.{ .page = .control }), runtime.key("wufour-account-control"));
    row(Msg, ui, k, icons.logout, w.sign_out, 0, false, o.msg(.sign_out), runtime.key("wufour-account-signout"));
    ui.end();
    gapAfter(Msg, ui);
}

fn gapAfter(comptime Msg: type, ui: *runtime.Ui(Msg)) void {
    ui.begin(.{ .height = .{ .px = 4 } }, .{});
    ui.end();
}

fn ownItems(comptime Msg: type, ui: *runtime.Ui(Msg), k: Colors, o: Options(Msg)) void {
    if (o.items.len == 0) return;
    cardBegin(Msg, ui, k);
    for (o.items, 0..) |it, i| row(Msg, ui, k, it.icon, it.label, it.count, it.current, o.msg(.{ .item = @intCast(i) }), runtime.key(@as(u64, 7000 + i)));
    ui.end();
    gapAfter(Msg, ui);
}

fn emblem(comptime Msg: type, ui: *runtime.Ui(Msg), k: Colors, app: App, size: f32, current: bool) void {
    const tint = Color.parseHex(app.color) catch k.v;
    ui.begin(.{
        .width = .{ .px = size },
        .height = .{ .px = size },
        .radius = size / 2,
        .align_items = .center,
        .justify = .center,
        .background = if (k.dark) k.b.mix(0.84, k.c) else k.b,
        .border_width = if (current) 2 else 3,
        .border_color = if (current) k.a else tint.withAlpha(0.24),
        .shadow = .{ .y = 4, .blur = 12, .color = k.deep.withAlpha(0.12) },
    }, .{});
    if (app.logoPng) |png| {
        ui.image(png, .{ .width = .{ .px = size * 0.54 }, .height = .{ .px = size * 0.54 }, .fit = .contain }, runtime.key(png));
    } else {
        const letter = if (app.name.len > 0) app.name[0..1] else "?";
        ui.text(letter, .{ .font_size = size * 0.4, .weight = 800, .line_height = 1, .color = if (k.dark) tint.mix(0.5, k.c) else tint });
    }
    ui.end();
}

fn appButton(comptime Msg: type, ui: *runtime.Ui(Msg), k: Colors, d: Data, i: u16, o: Options(Msg), wide: bool) void {
    const app = d.apps[i];
    const current = std.mem.eql(u8, app.slug, o.app);
    ui.begin(.{
        .width = .fill,
        .align_items = .center,
        .gap = 7,
        .padding = if (wide) .{ .top = 10, .bottom = 8, .start = 4, .end = 4 } else .{ .top = 8, .bottom = 6, .start = 2, .end = 2 },
        .radius = 18,
        .hover_background = if (wide) k.teal_soft else null,
        .pressed_background = k.teal_soft,
    }, .{ .on_press = o.msg(.{ .app = i }), .key = runtime.key(@as(u64, if (wide) 8000 else 8500) + i) });
    emblem(Msg, ui, k, app, 48, current);
    ui.text(if (o.ar and app.ar.len > 0) app.ar else app.name, .{ .font_size = 12, .weight = 700, .color = if (current) k.ink else k.ink_2, .max_lines = 1, .text_align = .center });
    if (wide) ui.text(if (o.ar) app.kind.ar else app.kind.en, .{ .font_size = 11, .weight = 600, .color = k.ink_3, .max_lines = 1, .text_align = .center });
    ui.end();
}

fn appsCard(comptime Msg: type, ui: *runtime.Ui(Msg), k: Colors, w: Words, v: View, m: *const Menu, o: Options(Msg)) void {
    if (v.dock.len == 0) return;
    ui.begin(.{ .background = k.card, .radius = 24, .padding = .{ .top = 12, .bottom = 8, .start = 6, .end = 6 } }, .{});
    ui.text(w.apps, .{ .font_size = 13.5, .weight = 700, .color = k.ink_2, .padding = .{ .start = 10, .end = 10, .bottom = 10 } });
    ui.begin(.{ .direction = .row, .gap = 2 }, .{});
    for (v.dock) |i| appButton(Msg, ui, k, v.data, i, o, false);
    // The red "All apps" button (fatal), as on the start page.
    ui.begin(.{ .width = .fill, .align_items = .center, .gap = 7, .padding = .{ .top = 8, .bottom = 6 }, .radius = 18, .pressed_opacity = 0.85 }, .{ .on_press = o.msg(.all), .label = w.all_apps, .key = runtime.key("wufour-account-all") });
    ui.begin(.{
        .width = .{ .px = 48 },
        .height = .{ .px = 48 },
        .radius = 24,
        .direction = if (m.all) .column else .row,
        .gap = 3.5,
        .align_items = .center,
        .justify = .center,
        .background = k.f,
        .shadow = .{ .y = 10, .blur = 20, .color = k.f.withAlpha(0.45) },
    }, .{});
    for (0..3) |_| {
        ui.begin(.{ .width = .{ .px = 5 }, .height = .{ .px = 5 }, .radius = 2.5, .background = k.b }, .{});
        ui.end();
    }
    ui.end();
    ui.text(w.all_apps, .{ .font_size = if (o.ar) 11 else 12, .weight = 700, .color = k.ink_2, .max_lines = 1, .text_align = .center });
    ui.end();
    ui.end();

    if (m.all) {
        ui.begin(.{ .height = .{ .px = 1 }, .background = k.line, .padding = .{ .top = 0 } }, .{});
        ui.end();
        ui.begin(.{ .grid = .{ .columns = 3 }, .gap = 2, .padding = .{ .top = 10 } }, .{});
        for (v.data.apps, 0..) |_, i| appButton(Msg, ui, k, v.data, @intCast(i), o, true);
        ui.end();
        ui.begin(.{ .direction = .row, .align_items = .center, .justify = .center, .gap = 8, .padding = .all(10), .radius = 16, .hover_background = k.teal_soft, .pressed_background = k.teal_soft }, .{ .on_press = o.msg(.{ .page = .home }), .key = runtime.key("wufour-account-arrange") });
        ui.text(w.arrange, .{ .font_size = 13.5, .weight = 700, .color = k.v });
        ui.icon(icons.arrow, 16, k.v, .{}, 0);
        ui.end();
    }
    ui.end();
}

fn foot(comptime Msg: type, ui: *runtime.Ui(Msg), k: Colors, w: Words, o: Options(Msg)) void {
    ui.begin(.{ .direction = .row, .align_items = .center, .justify = .center, .gap = 6, .padding = .{ .top = 12, .bottom = 4 } }, .{});
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 6, .padding = .xy(8, 4), .radius = 999, .hover_background = k.teal_soft, .pressed_background = k.teal_soft }, .{ .on_press = o.msg(.{ .page = .home }), .key = runtime.key("wufour-account-home") });
    ui.begin(.{ .width = .{ .px = 18 }, .height = .{ .px = 18 } }, .{});
    const tints = [_]Color{ k.a, k.v, k.plum, k.deep };
    for (mark_parts, tints) |d, c| {
        ui.icon(.{ .paths = &.{d}, .fill = true, .box = 64 }, 18, c, .{ .position = .absolute, .inset = .{ .top = 0, .start = 0 }, .no_mirror = true }, 0);
    }
    ui.end();
    ui.text(w.wufour, .{ .font_size = 12.5, .weight = 800, .color = k.brand_ink });
    ui.end();
    ui.text("·", .{ .font_size = 12.5, .color = k.ink_3 });
    ui.begin(.{ .padding = .xy(8, 4), .radius = 999, .hover_background = k.teal_soft, .pressed_background = k.teal_soft }, .{ .on_press = o.msg(.{ .page = .about }), .key = runtime.key("wufour-account-about") });
    ui.text(w.about, .{ .font_size = 12.5, .weight = 600, .color = k.ink_3 });
    ui.end();
    ui.end();
}

// ---------------------------------------------------------------------------------------------
// Tests (headless host)
// ---------------------------------------------------------------------------------------------

const testing = std.testing;

test "Wufour's answer is read, unknown fields and nulls included" {
    var m: Menu = .{};
    defer m.deinit();
    m.load(sample);
    const d = m.data.?;
    try testing.expect(d.signedIn);
    try testing.expectEqualStrings("Sara", d.user.?.username);
    try testing.expectEqual(@as(usize, 2), d.dock.len);
    try testing.expectEqualStrings("https://www.example.com/account", m.pageUrl(.account).?);
    try testing.expect(m.pageUrl(.control) == null);
    try testing.expectEqualStrings("https://www.example.com/assets/logos/png/taazur.png", d.apps[0].logoPng.?);
    // Not the menu: what was there stays.
    m.load("<html>");
    try testing.expect(m.data.?.signedIn);
}

test "dark colours follow Wufour's formulas" {
    const light = Colors.of(false);
    const dark = Colors.of(true);
    try testing.expectEqual(base.argb(), light.b.argb());
    // The dark canvas is very dark, the dark text very light.
    try testing.expect(dark.b.toOklch().l <= 0.26);
    try testing.expect(dark.c.toOklch().l >= 0.84);
}

const TestApp = struct {
    pub const Msg = union(enum) { account: Action };
    pub const State = struct {
        menu: Menu = .{},
        signed_out: bool = false,
        left: ?Action = null,
        opened: [128]u8 = undefined,
        opened_len: usize = 0,
    };
    pub fn init() State {
        var s: State = .{};
        s.menu.load(sample);
        return s;
    }
    fn onAccount(a: Action) Msg {
        return .{ .account = a };
    }
    fn options(s: *const State) Options(Msg) {
        return .{ .msg = onAccount, .app = "maps", .signed_out = s.signed_out, .items = &.{.{ .label = "My trips", .icon = icons.pin, .count = 3 }} };
    }
    pub fn update(s: *State, m: Msg, _: runtime.Env, fx: runtime.Fx(Msg)) void {
        switch (m) {
            .account => |act| s.left = s.menu.update(Msg, act, fx),
        }
    }
    pub fn view(s: *const State, ui: *runtime.Ui(Msg)) void {
        ui.begin(.{ .width = .fill, .height = .fill }, .{});
        ui.begin(.{ .direction = .row, .justify = .end, .padding = .all(12) }, .{});
        picture(Msg, ui, &s.menu, options(s), 40);
        ui.end();
        panel(Msg, ui, &s.menu, options(s));
        ui.end();
    }
};

test "the menu opens from the picture, shows the account, the app's items and the apps" {
    if (@import("zui.zig").platform != .headless) return;
    const D = @import("host/headless.zig").Driver(TestApp);
    D.start(1280, 800);
    defer D.reset();
    defer @constCast(D.R.appState()).menu.deinit();
    try testing.expect(D.findText("Hi, Sara!") == 0);
    try D.press("S");
    try testing.expect(D.R.appState().menu.open);
    try testing.expect(D.findText("Hi, Sara!") != 0);
    try testing.expect(D.findText("sara@example.com") != 0);
    try testing.expect(D.findText("Manage your Wufour account") != 0);
    try testing.expect(D.findText("Signed-in devices") != 0);
    try testing.expect(D.findText("Control") == 0);
    try testing.expect(D.findText("My trips") != 0);
    try testing.expect(D.findText("3") != 0);
    // The row: Maps then Taazur, as the person arranged them; All apps closed.
    try testing.expect(D.findText("Marketplace") == 0);
    try D.press("All apps");
    try testing.expect(D.findText("Marketplace") != 0);
    try testing.expect(D.findText("Arrange your apps on Wufour") != 0);
    // The app's item goes back to the app; the menu closes.
    try D.press("My trips");
    try testing.expectEqual(@as(u16, 0), D.R.appState().left.?.item);
    try testing.expect(!D.R.appState().menu.open);
    // Sign out too.
    try D.press("S");
    try D.press("Sign out");
    try testing.expect(D.R.appState().left.? == .sign_out);
}

test "signed out in the app: sign-in, even when Wufour answers for someone" {
    if (@import("zui.zig").platform != .headless) return;
    const D = @import("host/headless.zig").Driver(TestApp);
    D.start(390, 800);
    defer D.reset();
    defer @constCast(D.R.appState()).menu.deinit();
    @constCast(D.R.appState()).signed_out = true;
    D.R.dispatch(.{ .account = .toggle });
    try testing.expect(D.findText("Not signed in") != 0);
    try testing.expect(D.findText("Hi, Sara!") == 0);
    try D.press("Sign in");
    try testing.expect(D.R.appState().left.? == .sign_in);
}

const sample =
    \\{"signedIn":true,"user":{"username":"Sara","email":"sara@example.com"},
    \\ "links":{"home":"https://www.example.com/","about":"https://www.example.com/about","account":"https://www.example.com/account",
    \\  "devices":"https://www.example.com/account/devices","control":null,"signIn":"https://www.example.com/auth",
    \\  "signUp":"https://www.example.com/auth?mode=signup","signOut":"https://www.example.com/auth/signout"},
    \\ "dock":["maps","taazur"],
    \\ "apps":[{"slug":"taazur","name":"Taazur","ar":"تآزر","kind":{"en":"Marketplace","ar":"سوق"},"url":"https://taazur.example.com","logo":"x.svg","logoPng":"https://www.example.com/assets/logos/png/taazur.png","color":"#1AF1FA"},
    \\  {"slug":"maps","name":"Maps","ar":"خرائط","kind":{"en":"Maps","ar":"خرائط"},"url":"https://maps.example.com","logo":null,"logoPng":null,"color":"#2563eb"}]}
;
