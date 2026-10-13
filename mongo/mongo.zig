//! MongoDB driver: OP_MSG wire protocol, connection pool, SCRAM-SHA-256 authentication, and the
//! collection operations the app servers use. Documents keep exactly the shape the Node servers
//! wrote, so Control and the other apps that share these databases see no difference.
//!
//!     var client = try mongo.Client.init(io, gpa, "mongodb://127.0.0.1:27017/Maps");
//!     defer client.deinit();
//!     const keys = client.collection("apiKeys");
//!     const doc = try keys.findOne(arena, .{ .key = k }, .{});

const std = @import("std");
const Io = std.Io;
pub const bson = @import("bson.zig");
/// JavaScript-like values (JSON, BSON, Extended JSON), for servers ported from Node.
pub const val = @import("val.zig");
/// Collections that take and return `val.Val`s, with the Node driver's option names.
pub const db = @import("db.zig");

const Doc = bson.Doc;

pub const Error = error{
    /// The server answered `ok: 0`; `Client.last_error` holds its message.
    CommandFailed,
    DuplicateKey,
    Unauthorized,
    AuthenticationFailed,
    BadReply,
    ConnectionClosed,
};

pub const Credentials = struct {
    user: []const u8,
    password: []const u8,
    source: []const u8,
};

pub const Client = struct {
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    host: []const u8,
    port: u16,
    /// Database named in the URI path (`mongodb://host/Maps` → "Maps").
    default_db: []const u8,
    credentials: ?Credentials,
    mutex: Io.Mutex = .init,
    idle: std.ArrayList(*Conn) = .empty,
    max_idle: usize = 16,
    /// Message of the most recent failed command (for logs).
    last_error: [256]u8 = undefined,
    last_error_len: usize = 0,

    /// `mongodb://[user:password@]host[:port][/db][?authSource=admin]`
    pub fn init(io: Io, gpa: std.mem.Allocator, uri: []const u8) !*Client {
        const c = try gpa.create(Client);
        errdefer gpa.destroy(c);
        c.* = .{ .io = io, .gpa = gpa, .arena = .init(gpa), .host = "", .port = 27017, .default_db = "test", .credentials = null };
        errdefer c.arena.deinit();
        try c.parseUri(uri);
        return c;
    }

    pub fn deinit(c: *Client) void {
        for (c.idle.items) |conn| conn.destroy(c.gpa, c.io);
        c.idle.deinit(c.gpa);
        c.arena.deinit();
        c.gpa.destroy(c);
    }

    fn parseUri(c: *Client, uri: []const u8) !void {
        const a = c.arena.allocator();
        const prefix = "mongodb://";
        if (!std.mem.startsWith(u8, uri, prefix)) return error.InvalidUri;
        var rest = uri[prefix.len..];
        var query: []const u8 = "";
        if (std.mem.indexOfScalar(u8, rest, '?')) |q| {
            query = rest[q + 1 ..];
            rest = rest[0..q];
        }
        var user: ?[]const u8 = null;
        var password: []const u8 = "";
        if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| {
            const info = rest[0..at];
            rest = rest[at + 1 ..];
            const colon = std.mem.indexOfScalar(u8, info, ':') orelse info.len;
            user = try percentDecode(a, info[0..colon]);
            if (colon < info.len) password = try percentDecode(a, info[colon + 1 ..]);
        }
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const hostport = rest[0..slash];
        if (slash + 1 < rest.len) c.default_db = try a.dupe(u8, rest[slash + 1 ..]);
        if (std.mem.indexOfScalar(u8, hostport, ',') != null) return error.ReplicaSetsNotSupported;
        if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |colon| {
            c.host = try a.dupe(u8, hostport[0..colon]);
            c.port = try std.fmt.parseUnsigned(u16, hostport[colon + 1 ..], 10);
        } else c.host = try a.dupe(u8, hostport);

        var source: []const u8 = c.default_db;
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |kv| {
            if (std.mem.startsWith(u8, kv, "authSource=")) source = try a.dupe(u8, kv["authSource=".len..]);
        }
        if (user) |u| c.credentials = .{ .user = u, .password = password, .source = if (query.len > 0 or slash + 1 < rest.len) source else "admin" };
    }

    pub fn database(c: *Client, name: []const u8) Database {
        return .{ .client = c, .name = name };
    }

    /// A collection in the URI's database.
    pub fn collection(c: *Client, name: []const u8) Collection {
        return .{ .client = c, .db = c.default_db, .name = name };
    }

    pub fn lastError(c: *const Client) []const u8 {
        return c.last_error[0..c.last_error_len];
    }

    /// Runs `cmd` against the database `db_name` and returns the reply (in `arena`). `cmd` is a document or a
    /// struct literal whose first field is the command name.
    pub fn command(c: *Client, arena: std.mem.Allocator, db_name: []const u8, cmd: anytype) !Doc {
        const conn = try c.acquire();
        var healthy = false;
        defer c.release(conn, healthy);
        const reply = try conn.run(arena, c.io, db_name, cmd);
        healthy = true;
        try c.check(reply);
        return reply;
    }

    fn check(c: *Client, reply: Doc) !void {
        const ok = (reply.get("ok") orelse return error.BadReply).asFloat() orelse 0;
        // Write errors come back with ok: 1 and a writeErrors array.
        const write_error = if (reply.getDoc("writeErrors")) |we| we.getDoc("0") else null;
        if (ok == 1 and write_error == null) return;
        const src = write_error orelse reply;
        const msg = src.getString("errmsg") orelse "unknown error";
        const n = @min(msg.len, c.last_error.len);
        @memcpy(c.last_error[0..n], msg[0..n]);
        c.last_error_len = n;
        const code = if (src.get("code")) |v| v.asInt() orelse 0 else 0;
        return switch (code) {
            11000 => error.DuplicateKey,
            13 => error.Unauthorized,
            18 => error.AuthenticationFailed,
            else => error.CommandFailed,
        };
    }

    fn acquire(c: *Client) !*Conn {
        c.mutex.lockUncancelable(c.io);
        const pooled = c.idle.pop();
        c.mutex.unlock(c.io);
        if (pooled) |conn| return conn;
        return c.connect();
    }

    fn release(c: *Client, conn: *Conn, healthy: bool) void {
        if (healthy) {
            c.mutex.lockUncancelable(c.io);
            defer c.mutex.unlock(c.io);
            if (c.idle.items.len < c.max_idle) {
                c.idle.append(c.gpa, conn) catch {};
                if (c.idle.items[c.idle.items.len - 1] == conn) return;
            }
        }
        conn.destroy(c.gpa, c.io);
    }

    fn connect(c: *Client) !*Conn {
        const addresses = try Io.net.HostName.init(c.host);
        var stream = try addresses.connect(c.io, c.port, .{ .mode = .stream });
        errdefer stream.close(c.io);
        const conn = try c.gpa.create(Conn);
        errdefer c.gpa.destroy(conn);
        conn.* = .{ .stream = stream };
        conn.reader = stream.reader(c.io, &conn.read_buf);
        conn.writer = stream.writer(c.io, &conn.write_buf);

        var scratch = std.heap.ArenaAllocator.init(c.gpa);
        defer scratch.deinit();
        const hello = try conn.run(scratch.allocator(), c.io, "admin", .{
            .hello = 1,
            .client = .{ .driver = .{ .name = "zig-core", .version = "0.1" }, .os = .{ .type = @tagName(@import("builtin").os.tag) } },
        });
        try c.check(hello);
        if (c.credentials) |cred| try scram(c, conn, scratch.allocator(), cred);
        return conn;
    }
};

const Conn = struct {
    stream: Io.net.Stream,
    reader: Io.net.Stream.Reader = undefined,
    writer: Io.net.Stream.Writer = undefined,
    read_buf: [16 * 1024]u8 = undefined,
    write_buf: [16 * 1024]u8 = undefined,
    next_id: i32 = 1,

    fn destroy(conn: *Conn, gpa: std.mem.Allocator, io: Io) void {
        conn.stream.close(io);
        gpa.destroy(conn);
    }

    /// Sends one OP_MSG and reads its reply.
    fn run(conn: *Conn, arena: std.mem.Allocator, io: Io, db_name: []const u8, cmd: anytype) !Doc {
        _ = io;
        // The command document with `$db` appended (the command name stays first).
        var b = try bson.Builder.init(arena);
        if (@TypeOf(cmd) == Doc) {
            var it = cmd.iterator();
            while (try it.next()) |e| try b.value(e.key, e.value);
        } else try b.fields(cmd);
        try b.string("$db", db_name);
        const body = try b.finish();

        const id = conn.next_id;
        conn.next_id +%= 1;
        const w = &conn.writer.interface;
        const len: i32 = @intCast(16 + 4 + 1 + body.bytes.len);
        try w.writeInt(i32, len, .little);
        try w.writeInt(i32, id, .little);
        try w.writeInt(i32, 0, .little);
        try w.writeInt(i32, 2013, .little); // OP_MSG
        try w.writeInt(u32, 0, .little); // flags
        try w.writeByte(0); // section kind 0: body
        try w.writeAll(body.bytes);
        try w.flush();

        const r = &conn.reader.interface;
        const reply_len = r.takeInt(i32, .little) catch return error.ConnectionClosed;
        if (reply_len < 21 or reply_len > 48 * 1024 * 1024) return error.BadReply;
        const rest = try arena.alloc(u8, @intCast(reply_len - 4));
        r.readSliceAll(rest) catch return error.ConnectionClosed;
        const response_to = std.mem.readInt(i32, rest[4..8], .little);
        const opcode = std.mem.readInt(i32, rest[8..12], .little);
        if (response_to != id or opcode != 2013) return error.BadReply;
        // rest[12..16] flags, then sections; the reply body is the kind-0 section.
        var pos: usize = 16;
        while (pos < rest.len) {
            const kind = rest[pos];
            pos += 1;
            if (kind == 0) return Doc.init(rest[pos..]);
            if (kind != 1) return error.BadReply;
            pos += @intCast(std.mem.readInt(i32, rest[pos..][0..4], .little));
        }
        return error.BadReply;
    }
};

const ScramStep = struct { final: []const u8, server_signature: []const u8 };

/// The client-final message and the server signature to expect, from the server-first message.
fn scramFinal(a: std.mem.Allocator, password: []const u8, salt: []const u8, iterations: u32, first_bare: []const u8, server_first: []const u8, server_nonce: []const u8) !ScramStep {
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    const Sha256 = std.crypto.hash.sha2.Sha256;
    const b64 = std.base64.standard;

    var salted: [32]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(&salted, password, salt, iterations, Hmac);
    var client_key: [32]u8 = undefined;
    Hmac.create(&client_key, "Client Key", &salted);
    var stored_key: [32]u8 = undefined;
    Sha256.hash(&client_key, &stored_key, .{});

    const final_no_proof = try std.fmt.allocPrint(a, "c=biws,r={s}", .{server_nonce});
    const auth_message = try std.fmt.allocPrint(a, "{s},{s},{s}", .{ first_bare, server_first, final_no_proof });
    var signature: [32]u8 = undefined;
    Hmac.create(&signature, auth_message, &stored_key);
    var proof: [32]u8 = undefined;
    for (&proof, client_key, signature) |*p, k, s| p.* = k ^ s;
    var proof_b64: [44]u8 = undefined;

    var server_key: [32]u8 = undefined;
    Hmac.create(&server_key, "Server Key", &salted);
    var server_sig: [32]u8 = undefined;
    Hmac.create(&server_sig, auth_message, &server_key);
    var server_b64: [44]u8 = undefined;
    return .{
        .final = try std.fmt.allocPrint(a, "{s},p={s}", .{ final_no_proof, b64.Encoder.encode(&proof_b64, &proof) }),
        .server_signature = try a.dupe(u8, b64.Encoder.encode(&server_b64, &server_sig)),
    };
}

test "SCRAM-SHA-256 matches the RFC 7677 example" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const server_first = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096";
    const salt = try a.alloc(u8, 16);
    try std.base64.standard.Decoder.decode(salt, "W22ZaJ0SNY7soEsUEjb6gQ==");
    const step = try scramFinal(a, "pencil", salt, 4096, "n=user,r=rOprNGfwEbeRWgbNEkqO", server_first, "rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0");
    try std.testing.expectEqualStrings("c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=", step.final);
    try std.testing.expectEqualStrings("6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=", step.server_signature);
}

/// SCRAM-SHA-256 (RFC 5802 / 7677), as MongoDB does it with saslStart / saslContinue.
fn scram(c: *Client, conn: *Conn, a: std.mem.Allocator, cred: Credentials) !void {
    const b64 = std.base64.standard;

    var nonce_raw: [24]u8 = undefined;
    c.io.random(&nonce_raw);
    var nonce_buf: [32]u8 = undefined;
    const nonce = b64.Encoder.encode(&nonce_buf, &nonce_raw);

    const user = try std.mem.replaceOwned(u8, a, try std.mem.replaceOwned(u8, a, cred.user, "=", "=3D"), ",", "=2C");
    const first_bare = try std.fmt.allocPrint(a, "n={s},r={s}", .{ user, nonce });
    const first = try std.fmt.allocPrint(a, "n,,{s}", .{first_bare});

    var reply = try conn.run(a, c.io, cred.source, .{
        .saslStart = 1,
        .mechanism = "SCRAM-SHA-256",
        .payload = bson.Binary{ .data = first },
        .autoAuthorize = 1,
        .options = .{ .skipEmptyExchange = true },
    });
    c.check(reply) catch return error.AuthenticationFailed;
    const conversation = reply.get("conversationId") orelse return error.BadReply;
    const server_first = switch (reply.get("payload") orelse return error.BadReply) {
        .binary => |p| p.data,
        else => return error.BadReply,
    };

    var server_nonce: []const u8 = "";
    var salt_b64: []const u8 = "";
    var iterations: u32 = 0;
    var fields = std.mem.splitScalar(u8, server_first, ',');
    while (fields.next()) |f| {
        if (f.len < 2) continue;
        switch (f[0]) {
            'r' => server_nonce = f[2..],
            's' => salt_b64 = f[2..],
            'i' => iterations = try std.fmt.parseUnsigned(u32, f[2..], 10),
            else => {},
        }
    }
    if (!std.mem.startsWith(u8, server_nonce, nonce) or iterations < 4096) return error.AuthenticationFailed;
    const salt = try a.alloc(u8, try b64.Decoder.calcSizeForSlice(salt_b64));
    try b64.Decoder.decode(salt, salt_b64);

    const step = try scramFinal(a, cred.password, salt, iterations, first_bare, server_first, server_nonce);

    reply = try conn.run(a, c.io, cred.source, .{ .saslContinue = 1, .conversationId = conversation, .payload = bson.Binary{ .data = step.final } });
    c.check(reply) catch return error.AuthenticationFailed;

    // The server proves it knows the password too.
    const expected = step.server_signature;
    const server_final = switch (reply.get("payload") orelse return error.BadReply) {
        .binary => |p| p.data,
        else => return error.BadReply,
    };
    if (!std.mem.startsWith(u8, server_final, "v=") or !std.mem.eql(u8, server_final[2..], expected)) return error.AuthenticationFailed;

    while (!(if (reply.get("done")) |d| d == .boolean and d.boolean else false)) {
        reply = try conn.run(a, c.io, cred.source, .{ .saslContinue = 1, .conversationId = conversation, .payload = bson.Binary{ .data = "" } });
        c.check(reply) catch return error.AuthenticationFailed;
    }
}

fn percentDecode(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = try a.alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) {
        if (s[i] == '%' and i + 3 <= s.len) {
            out[n] = try std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16);
            i += 3;
        } else {
            out[n] = s[i];
            i += 1;
        }
    }
    return out[0..n];
}

pub const Database = struct {
    client: *Client,
    name: []const u8,

    pub fn collection(d: Database, name: []const u8) Collection {
        return .{ .client = d.client, .db = d.name, .name = name };
    }

    pub fn command(d: Database, arena: std.mem.Allocator, cmd: anytype) !Doc {
        return d.client.command(arena, d.name, cmd);
    }

    pub fn drop(d: Database, arena: std.mem.Allocator) !void {
        _ = try d.command(arena, .{ .dropDatabase = 1 });
    }
};

pub const FindOptions = struct {
    projection: ?Doc = null,
    sort: ?Doc = null,
    limit: ?i64 = null,
    skip: ?i64 = null,
    batch_size: ?i32 = null,
};

pub const UpdateOptions = struct {
    upsert: bool = false,
};

pub const UpdateResult = struct {
    matched: i64,
    modified: i64,
    upserted_id: ?bson.Value,
};

pub const FindAndModifyOptions = struct {
    sort: ?Doc = null,
    projection: ?Doc = null,
    upsert: bool = false,
    /// Return the document after the update (MongoDB's `new: true`).
    return_new: bool = true,
};

pub const IndexOptions = struct {
    name: ?[]const u8 = null,
    unique: bool = false,
    sparse: bool = false,
    expire_after_seconds: ?i64 = null,
};

/// `v` as a document: documents pass through, anything else is encoded.
fn asDoc(arena: std.mem.Allocator, v: anytype) !Doc {
    return if (@TypeOf(v) == Doc) v else bson.encode(arena, v);
}

pub const Collection = struct {
    client: *Client,
    db: []const u8,
    name: []const u8,

    fn run(c: Collection, arena: std.mem.Allocator, cmd: Doc) !Doc {
        return c.client.command(arena, c.db, cmd);
    }

    pub fn find(c: Collection, arena: std.mem.Allocator, filter: anytype, o: FindOptions) !Cursor {
        var b = try bson.Builder.init(arena);
        try b.string("find", c.name);
        try b.doc("filter", try asDoc(arena, filter));
        if (o.projection) |p| try b.doc("projection", p);
        if (o.sort) |s| try b.doc("sort", s);
        if (o.limit) |l| try b.int64("limit", l);
        if (o.skip) |s| try b.int64("skip", s);
        if (o.batch_size) |s| try b.int32("batchSize", s);
        return Cursor.fromReply(c, arena, try c.run(arena, try b.finish()), "firstBatch");
    }

    pub fn findOne(c: Collection, arena: std.mem.Allocator, filter: anytype, o: FindOptions) !?Doc {
        var opts = o;
        opts.limit = 1;
        opts.batch_size = 1;
        var cursor = try c.find(arena, filter, opts);
        defer cursor.close();
        return cursor.next();
    }

    /// Inserts `doc`, adding an ObjectId `_id` if it has none, and returns the `_id`.
    pub fn insertOne(c: Collection, arena: std.mem.Allocator, doc: anytype) !bson.Value {
        const ids = try c.insertMany(arena, &.{try asDoc(arena, doc)});
        return ids[0];
    }

    pub fn insertMany(c: Collection, arena: std.mem.Allocator, docs: []const Doc) ![]bson.Value {
        const ids = try arena.alloc(bson.Value, docs.len);
        var b = try bson.Builder.init(arena);
        try b.string("insert", c.name);
        try b.beginArray("documents");
        for (docs, ids) |d, *id| {
            if (d.get("_id")) |existing| {
                id.* = existing;
                try b.doc("", d);
            } else {
                id.* = .{ .object_id = bson.ObjectId.generate(c.client.io) };
                try b.beginDoc("");
                try b.objectId("_id", id.object_id);
                var it = d.iterator();
                while (try it.next()) |e| try b.value(e.key, e.value);
                try b.end();
            }
        }
        try b.end();
        _ = try c.run(arena, try b.finish());
        return ids;
    }

    pub fn updateOne(c: Collection, arena: std.mem.Allocator, filter: anytype, update: anytype, o: UpdateOptions) !UpdateResult {
        return c.updateImpl(arena, try asDoc(arena, filter), try asDoc(arena, update), o, false);
    }

    pub fn updateMany(c: Collection, arena: std.mem.Allocator, filter: anytype, update: anytype, o: UpdateOptions) !UpdateResult {
        return c.updateImpl(arena, try asDoc(arena, filter), try asDoc(arena, update), o, true);
    }

    fn updateImpl(c: Collection, arena: std.mem.Allocator, filter: Doc, update: Doc, o: UpdateOptions, multi: bool) !UpdateResult {
        var b = try bson.Builder.init(arena);
        try b.string("update", c.name);
        try b.beginArray("updates");
        try b.beginDoc("");
        try b.doc("q", filter);
        // An update document starts with an operator ($set, ...); an array is a pipeline.
        try b.doc("u", update);
        try b.boolean("upsert", o.upsert);
        try b.boolean("multi", multi);
        try b.end();
        try b.end();
        const reply = try c.run(arena, try b.finish());
        const upserted = if (reply.getDoc("upserted")) |u| (if (u.getDoc("0")) |first| first.get("_id") else null) else null;
        return .{
            .matched = (reply.get("n") orelse bson.Value{ .int32 = 0 }).asInt() orelse 0,
            .modified = (reply.get("nModified") orelse bson.Value{ .int32 = 0 }).asInt() orelse 0,
            .upserted_id = upserted,
        };
    }

    pub const UpdateStatement = struct { filter: Doc, update: Doc, upsert: bool = false, multi: bool = false };

    /// Several updates in one round trip, unordered (one failing does not stop the others).
    pub fn bulkUpdate(c: Collection, arena: std.mem.Allocator, stmts: []const UpdateStatement) !void {
        if (stmts.len == 0) return;
        var b = try bson.Builder.init(arena);
        try b.string("update", c.name);
        try b.beginArray("updates");
        for (stmts) |st| {
            try b.beginDoc("");
            try b.doc("q", st.filter);
            try b.doc("u", st.update);
            try b.boolean("upsert", st.upsert);
            try b.boolean("multi", st.multi);
            try b.end();
        }
        try b.end();
        try b.boolean("ordered", false);
        _ = try c.run(arena, try b.finish());
    }

    /// Deletes the first match; returns how many were deleted (0 or 1).
    pub fn deleteOne(c: Collection, arena: std.mem.Allocator, filter: anytype) !i64 {
        return c.deleteImpl(arena, try asDoc(arena, filter), 1);
    }

    pub fn deleteMany(c: Collection, arena: std.mem.Allocator, filter: anytype) !i64 {
        return c.deleteImpl(arena, try asDoc(arena, filter), 0);
    }

    fn deleteImpl(c: Collection, arena: std.mem.Allocator, filter: Doc, limit: i32) !i64 {
        var b = try bson.Builder.init(arena);
        try b.string("delete", c.name);
        try b.beginArray("deletes");
        try b.beginDoc("");
        try b.doc("q", filter);
        try b.int32("limit", limit);
        try b.end();
        try b.end();
        const reply = try c.run(arena, try b.finish());
        return (reply.get("n") orelse bson.Value{ .int32 = 0 }).asInt() orelse 0;
    }

    pub fn countDocuments(c: Collection, arena: std.mem.Allocator, filter: anytype) !i64 {
        var cursor = try c.aggregate(arena, .{
            .{ .@"$match" = try asDoc(arena, filter) },
            .{ .@"$group" = .{ ._id = 1, .n = .{ .@"$sum" = 1 } } },
        });
        defer cursor.close();
        const d = (try cursor.next()) orelse return 0;
        return (d.get("n") orelse return 0).asInt() orelse 0;
    }

    /// `pipeline` is a tuple of stages (struct literals or documents).
    pub fn aggregate(c: Collection, arena: std.mem.Allocator, pipeline: anytype) !Cursor {
        var b = try bson.Builder.init(arena);
        try b.string("aggregate", c.name);
        try b.any("pipeline", pipeline);
        try b.beginDoc("cursor");
        try b.end();
        return Cursor.fromReply(c, arena, try c.run(arena, try b.finish()), "firstBatch");
    }

    /// Atomically updates one document and returns it (after the update by default), or null
    /// when nothing matched and `upsert` is off.
    pub fn findOneAndUpdate(c: Collection, arena: std.mem.Allocator, filter: anytype, update: anytype, o: FindAndModifyOptions) !?Doc {
        var b = try bson.Builder.init(arena);
        try b.string("findAndModify", c.name);
        try b.doc("query", try asDoc(arena, filter));
        try b.doc("update", try asDoc(arena, update));
        try b.boolean("new", o.return_new);
        try b.boolean("upsert", o.upsert);
        if (o.sort) |s| try b.doc("sort", s);
        if (o.projection) |p| try b.doc("fields", p);
        const reply = try c.run(arena, try b.finish());
        return switch (reply.get("value") orelse return null) {
            .document => |d| d,
            else => null,
        };
    }

    pub fn createIndex(c: Collection, arena: std.mem.Allocator, keys: anytype, o: IndexOptions) !void {
        const key_doc = try asDoc(arena, keys);
        var name_buf: std.ArrayList(u8) = .empty;
        if (o.name == null) {
            var it = key_doc.iterator();
            while (try it.next()) |e| {
                if (name_buf.items.len > 0) try name_buf.append(arena, '_');
                try name_buf.print(arena, "{s}_{d}", .{ e.key, e.value.asInt() orelse 1 });
            }
        }
        var b = try bson.Builder.init(arena);
        try b.string("createIndexes", c.name);
        try b.beginArray("indexes");
        try b.beginDoc("");
        try b.doc("key", key_doc);
        try b.string("name", o.name orelse name_buf.items);
        if (o.unique) try b.boolean("unique", true);
        if (o.sparse) try b.boolean("sparse", true);
        if (o.expire_after_seconds) |s| try b.int64("expireAfterSeconds", s);
        try b.end();
        try b.end();
        _ = try c.run(arena, try b.finish());
    }

    pub fn drop(c: Collection, arena: std.mem.Allocator) !void {
        _ = c.run(arena, try bson.encode(arena, .{ .drop = c.name })) catch |err| switch (err) {
            error.CommandFailed => {}, // already gone
            else => return err,
        };
    }
};

/// Results of `find` / `aggregate`, fetched from the server in batches as they are read.
pub const Cursor = struct {
    coll: Collection,
    arena: std.mem.Allocator,
    id: i64,
    batch: bson.Iterator,

    fn fromReply(c: Collection, arena: std.mem.Allocator, reply: Doc, batch_key: []const u8) !Cursor {
        const cur = reply.getDoc("cursor") orelse return error.BadReply;
        const batch = cur.getDoc(batch_key) orelse return error.BadReply;
        return .{ .coll = c, .arena = arena, .id = (cur.get("id") orelse return error.BadReply).asInt() orelse 0, .batch = batch.iterator() };
    }

    pub fn next(cur: *Cursor) !?Doc {
        while (true) {
            if (try cur.batch.next()) |e| return switch (e.value) {
                .document => |d| d,
                else => error.BadReply,
            };
            if (cur.id == 0) return null;
            const reply = try cur.coll.run(cur.arena, try bson.encode(cur.arena, .{ .getMore = cur.id, .collection = cur.coll.name }));
            const c = reply.getDoc("cursor") orelse return error.BadReply;
            cur.id = (c.get("id") orelse return error.BadReply).asInt() orelse 0;
            cur.batch = (c.getDoc("nextBatch") orelse return error.BadReply).iterator();
        }
    }

    /// Every remaining document.
    pub fn all(cur: *Cursor) ![]Doc {
        var out: std.ArrayList(Doc) = .empty;
        while (try cur.next()) |d| try out.append(cur.arena, d);
        return out.items;
    }

    /// Tells the server to drop the cursor if it still has results left.
    pub fn close(cur: *Cursor) void {
        if (cur.id == 0) return;
        _ = cur.coll.run(cur.arena, bson.encode(cur.arena, .{ .killCursors = cur.coll.name, .cursors = &[_]i64{cur.id} }) catch return) catch {};
        cur.id = 0;
    }
};

test {
    _ = bson;
    _ = val;
    _ = db;
    _ = @import("test.zig");
}
