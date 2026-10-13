//! Outgoing HTTP for app servers (webhooks, tile and search backends, sign-in services, push
//! endpoints, link previews), on std.http.Client with what it lacks:
//!
//!  - A time limit. Each request runs as its own task and the caller stops waiting at the
//!    deadline; the request's socket is then shut down, so the task ends too.
//!  - Recovery from dead pooled connections. std.http.Client returns a connection to its pool
//!    when a request fails before the response head arrives (a keep-alive connection the other
//!    side closed while idle), and the pool hands out that same connection next, so every later
//!    request to that host fails at once. Here a failed request's connection is always closed,
//!    the idle pool is emptied, and the request is tried once more on a new connection.
//!  - The SSRF guard (`assertPublicUrl`) for URLs that users supply.
//!
//!     var client: fetch.Client = .init(io, gpa);
//!     defer client.deinit();
//!     const res = try client.fetch(arena, "https://example.com/", .{ .timeout_ms = 5000 });

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Response = struct {
    status: u16,
    content_type: []const u8,
    location: ?[]const u8,
    body: []const u8,
};

pub const Options = struct {
    method: std.http.Method = .GET,
    headers: []const std.http.Header = &.{},
    body: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    user_agent: ?[]const u8 = null,
    timeout_ms: i64 = 10_000,
    max_bytes: usize = 16 << 20,
    /// Follow up to 3 redirects (GET only).
    follow: bool = false,
    /// Try once more on a new connection when the first attempt fails (not after a timeout).
    retry: bool = true,
};

pub const Error = error{ Timeout, InvalidUrl, ResponseTooLarge, OutOfMemory, Canceled, FetchFailed };

pub const Client = struct {
    io: Io,
    gpa: Allocator,
    http: std.http.Client,
    /// Requests still running (also those whose caller gave up waiting).
    jobs: Io.Group = .init,
    /// Lets `assertPublicUrl` accept loopback and private addresses (development, tests).
    allow_private: bool = false,
    /// The error of the last failed attempt, for logs.
    last_error: std.atomic.Value(u16) = .init(0),

    pub fn init(io: Io, gpa: Allocator) Client {
        return .{ .io = io, .gpa = gpa, .http = .{ .allocator = gpa, .io = io } };
    }

    /// Waits for running requests (each ends within its time limit) and closes all connections.
    pub fn deinit(c: *Client) void {
        c.jobs.await(c.io) catch {};
        c.http.deinit();
    }

    /// Sends a request and reads the whole answer into `a`. Errors when the other side cannot be
    /// reached (error.FetchFailed, with the cause in `lastError`), or does not answer within
    /// `timeout_ms` (error.Timeout).
    pub fn fetch(c: *Client, a: Allocator, url: []const u8, opts: Options) Error!Response {
        const job = try c.gpa.create(Job);
        job.* = .{ .client = c, .arena = .init(c.gpa), .url = undefined, .opts = opts };
        job.copyArgs(url, opts) catch {
            job.arena.deinit();
            c.gpa.destroy(job);
            return error.OutOfMemory;
        };
        c.jobs.concurrent(c.io, Job.run, .{job}) catch job.run();
        defer job.release();

        const deadline: Io.Timeout = .{ .deadline = .fromNow(c.io, .{ .raw = .fromMilliseconds(opts.timeout_ms), .clock = .awake }) };
        while (!job.done.isSet()) {
            job.done.waitTimeout(c.io, deadline) catch |e| switch (e) {
                error.Timeout => {
                    if (job.done.isSet()) break;
                    const left = deadline.toDurationFromNow(c.io) orelse break;
                    if (left.raw.toMilliseconds() <= 0) {
                        job.abort();
                        return error.Timeout;
                    }
                },
                error.Canceled => {
                    job.abort();
                    return error.Canceled;
                },
            };
        }
        if (!job.done.isSet()) {
            job.abort();
            return error.Timeout;
        }
        const res = try job.result;
        return .{
            .status = res.status,
            .content_type = try a.dupe(u8, res.content_type),
            .location = if (res.location) |l| try a.dupe(u8, l) else null,
            .body = try a.dupe(u8, res.body),
        };
    }

    /// The cause of the last error.FetchFailed (for logs).
    pub fn lastError(c: *const Client) anyerror {
        const v = c.last_error.load(.monotonic);
        return if (v == 0) error.Unknown else @errorFromInt(v);
    }

    /// Closes idle pooled connections (any of them may be the dead one).
    fn dropIdle(c: *Client) void {
        const pool = &c.http.connection_pool;
        const size = pool.free_size;
        pool.resize(c.io, 0) catch return;
        pool.resize(c.io, size) catch {};
    }

    pub const UrlError = error{ InvalidUrl, NotHttp, Unreachable };

    /// Refuses URLs that are not http(s), and (unless `allow_private`) any whose host resolves
    /// to a loopback, private, link-local, CGNAT or multicast address.
    pub fn assertPublicUrl(c: *Client, url: []const u8) UrlError!void {
        const uri = std.Uri.parse(url) catch return error.InvalidUrl;
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.NotHttp;
        const host_c = uri.host orelse return error.InvalidUrl;
        if (c.allow_private) return;
        var hbuf: [256]u8 = undefined;
        const host_raw = host_c.toRaw(&hbuf) catch return error.InvalidUrl;
        const host = std.mem.trim(u8, host_raw, "[]");
        if (Io.net.IpAddress.parse(host, 0)) |ip| {
            if (isPrivate(ip)) return error.Unreachable;
            return;
        } else |_| {}
        const name = Io.net.HostName.init(host) catch return error.InvalidUrl;
        var buf: [16]Io.net.HostName.LookupResult = undefined;
        var queue: Io.Queue(Io.net.HostName.LookupResult) = .init(&buf);
        name.lookup(c.io, &queue, .{ .port = 80 }) catch return error.Unreachable;
        var any = false;
        while (queue.getOne(c.io)) |r| switch (r) {
            .address => |ad| {
                any = true;
                if (isPrivate(ad)) return error.Unreachable;
            },
            .canonical_name => {},
        } else |_| {}
        if (!any) return error.Unreachable;
    }
};

const Job = struct {
    client: *Client,
    arena: std.heap.ArenaAllocator,
    /// The caller and the task; the last one frees the job.
    refs: std.atomic.Value(u8) = .init(2),
    done: Io.Event = .unset,
    url: []const u8,
    opts: Options,
    result: Error!Response = error.FetchFailed,
    /// The connection of the request in flight, so a caller that gives up can shut it down.
    lock: Io.Mutex = .init,
    connection: ?*std.http.Client.Connection = null,
    aborted: bool = false,

    fn copyArgs(job: *Job, url: []const u8, opts: Options) !void {
        const ja = job.arena.allocator();
        job.url = try ja.dupe(u8, url);
        const hs = try ja.alloc(std.http.Header, opts.headers.len);
        for (opts.headers, 0..) |h, i| hs[i] = .{ .name = try ja.dupe(u8, h.name), .value = try ja.dupe(u8, h.value) };
        job.opts.headers = hs;
        if (opts.body) |b| job.opts.body = try ja.dupe(u8, b);
        if (opts.content_type) |v| job.opts.content_type = try ja.dupe(u8, v);
        if (opts.user_agent) |v| job.opts.user_agent = try ja.dupe(u8, v);
    }

    fn release(job: *Job) void {
        if (job.refs.fetchSub(1, .acq_rel) == 1) {
            const gpa = job.client.gpa;
            job.arena.deinit();
            gpa.destroy(job);
        }
    }

    /// The caller stopped waiting: end the request in flight.
    fn abort(job: *Job) void {
        const io = job.client.io;
        job.lock.lockUncancelable(io);
        defer job.lock.unlock(io);
        job.aborted = true;
        if (job.connection) |conn| {
            conn.closing = true;
            conn.stream_reader.stream.shutdown(io, .both) catch {};
        }
    }

    fn run(job: *Job) void {
        defer job.release();
        const c = job.client;
        job.result = job.once();
        if (job.result) |_| {} else |e| if (e == error.FetchFailed) {
            // Other idle connections to that host may be just as dead.
            c.dropIdle();
            if (job.opts.retry and !job.isAborted()) job.result = job.once();
        }
        job.done.set(c.io);
    }

    fn once(job: *Job) Error!Response {
        return job.attempt() catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.ResponseTooLarge => error.ResponseTooLarge,
            error.InvalidUrl => error.InvalidUrl,
            else => {
                job.client.last_error.store(@intFromError(e), .monotonic);
                return error.FetchFailed;
            },
        };
    }

    fn isAborted(job: *Job) bool {
        const io = job.client.io;
        job.lock.lockUncancelable(io);
        defer job.lock.unlock(io);
        return job.aborted;
    }

    fn setConnection(job: *Job, conn: ?*std.http.Client.Connection) void {
        const io = job.client.io;
        job.lock.lockUncancelable(io);
        defer job.lock.unlock(io);
        job.connection = conn;
        if (conn) |cn| if (job.aborted) {
            cn.closing = true;
            cn.stream_reader.stream.shutdown(io, .both) catch {};
        };
    }

    fn attempt(job: *Job) !Response {
        const a = job.arena.allocator();
        const opts = job.opts;
        const uri = std.Uri.parse(job.url) catch return error.InvalidUrl;
        var req = try job.client.http.request(opts.method, uri, .{
            .extra_headers = opts.headers,
            .redirect_behavior = if (opts.follow) @fromBackingInt(@intCast(3)) else .unhandled,
            .keep_alive = true,
            .headers = .{
                // Bodies are passed on or parsed as they are, so ask for them uncompressed.
                .accept_encoding = .omit,
                .user_agent = if (opts.user_agent) |u| .{ .override = u } else .default,
                .content_type = if (opts.content_type) |v| .{ .override = v } else .default,
            },
        });
        defer req.deinit();
        job.setConnection(req.connection);
        defer job.setConnection(null);
        // The fix for dead pooled connections: std.http would put this one back in the pool.
        errdefer if (req.connection) |conn| {
            conn.closing = true;
        };

        if (opts.body) |b| {
            req.transfer_encoding = .{ .content_length = b.len };
            var w = try req.sendBodyUnflushed(&.{});
            try w.writer.writeAll(b);
            try w.end();
            try req.connection.?.flush();
        } else try req.sendBodiless();
        var redirect_buf: [2048]u8 = undefined;
        var res = try req.receiveHead(if (opts.follow) &redirect_buf else &.{});
        // A redirect moves the request to another connection.
        job.setConnection(req.connection);
        const status: u16 = @backingInt(res.head.status);
        const content_type = try a.dupe(u8, res.head.content_type orelse "");
        var location: ?[]const u8 = null;
        var it = res.head.iterateHeaders();
        while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "location")) {
            location = try a.dupe(u8, h.value);
        };
        var transfer: [64]u8 = undefined;
        const body = res.reader(&transfer).allocRemaining(a, .limited(opts.max_bytes)) catch |e| switch (e) {
            error.StreamTooLong => return error.ResponseTooLarge,
            else => return e,
        };
        return .{ .status = status, .content_type = content_type, .location = location, .body = body };
    }
};

// ---------------------------------------------------------------------------------------------
// Address checks
// ---------------------------------------------------------------------------------------------

/// Loopback, private, link-local, CGNAT, unspecified and multicast addresses (v4, v6 and
/// v4-mapped v6).
pub fn isPrivate(addr: Io.net.IpAddress) bool {
    switch (addr) {
        .ip4 => |x| return private4(x.bytes),
        .ip6 => |x| {
            const b = x.bytes;
            // ::ffff:a.b.c.d
            if (std.mem.allEqual(u8, b[0..10], 0) and b[10] == 0xff and b[11] == 0xff) return private4(b[12..16].*);
            if (std.mem.allEqual(u8, b[0..15], 0) and (b[15] == 1 or b[15] == 0)) return true;
            if (b[0] == 0xfc or b[0] == 0xfd) return true;
            if (b[0] == 0xfe and (b[1] & 0xc0) == 0x80) return true;
            if (b[0] == 0xff) return true;
            return false;
        },
    }
}

fn private4(b: [4]u8) bool {
    return b[0] == 10 or b[0] == 127 or b[0] == 0 or (b[0] == 169 and b[1] == 254) or (b[0] == 172 and b[1] >= 16 and b[1] <= 31) or
        (b[0] == 192 and b[1] == 168) or (b[0] == 100 and b[1] >= 64 and b[1] <= 127) or b[0] >= 224;
}

/// A user-facing message for the errors of `assertPublicUrl` and `fetch`.
pub fn urlErrorMessage(e: anyerror) []const u8 {
    return switch (e) {
        error.InvalidUrl => "Invalid URL",
        error.NotHttp => "Only http and https URLs are allowed",
        error.Unreachable => "That address is not reachable",
        error.Timeout => "The operation was aborted due to timeout",
        else => "fetch failed",
    };
}

test {
    _ = @import("test.zig");
}
