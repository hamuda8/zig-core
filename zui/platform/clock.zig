//! The wall clock and the local time zone from the C library (Android's bionic, iOS's
//! libSystem): both keep the system's time zone, so localtime_r answers with the phone's.

const std = @import("std");

pub fn now() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Minutes east of UTC.
pub fn tzOffset() i32 {
    var t: std.c.time_t = @intCast(@divTrunc(now(), 1000));
    var tm: Tm = undefined;
    if (localtime_r(&t, &tm) == null) return 0;
    return @intCast(@divTrunc(tm.tm_gmtoff, 60));
}

/// `struct tm` as bionic and Darwin lay it out.
const Tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};

extern "c" fn localtime_r(t: *const std.c.time_t, tm: *Tm) ?*Tm;
