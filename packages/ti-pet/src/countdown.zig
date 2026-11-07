//! Hover countdown, native side.
//!
//! Port of `formatCountdown`, `nextSession` and `countdownText` from
//! desktop/src/pets/schedule.mjs in the tif1ai repo. The two must produce
//! the same bytes: tests/fixtures/countdown-cases.json is emitted by the
//! desktop side (desktop/src/pets/test-fixtures/emit-native-fixtures.mjs)
//! and checked here. Change both files together.
//!
//!   "Qualifying in 2 h 14 min · São Paulo GP"
//!   "Race is live · São Paulo GP"

const std = @import("std");

/// One upcoming session from the timeline's `sessions[]`. `label` and `gp`
/// are already the display strings ("Qualifying", "São Paulo GP"); `end_ms`
/// is the nominal end (start + the kind's duration in the desktop contract).
pub const Session = struct {
    key: []const u8 = "",
    kind: []const u8 = "",
    label: []const u8,
    gp: []const u8,
    start_ms: i64,
    end_ms: i64,
};

/// Longest text `hoverText` writes for sane labels; pass a buffer at least
/// this big (longer labels just return null).
pub const max_text_bytes: usize = 256;

const minute_ms: i64 = 60_000;

/// "2 h 14 min", "45 min", "3 d 4 h" (minutes rounded up, at least 1).
/// Returns null only when `buf` is too small (32 bytes always fits).
pub fn formatCountdown(buf: []u8, ms: i64) ?[]const u8 {
    // Math.max(1, Math.ceil(ms / 60_000))
    const minutes = @max(1, -@divFloor(-ms, minute_ms));
    if (minutes < 60) return std.fmt.bufPrint(buf, "{d} min", .{minutes}) catch null;
    const hours = @divFloor(minutes, 60);
    if (hours < 24) {
        const rest = @mod(minutes, 60);
        return if (rest == 0)
            std.fmt.bufPrint(buf, "{d} h", .{hours}) catch null
        else
            std.fmt.bufPrint(buf, "{d} h {d} min", .{ hours, rest }) catch null;
    }
    const days = @divFloor(hours, 24);
    const rest_hours = @mod(hours, 24);
    return if (rest_hours == 0)
        std.fmt.bufPrint(buf, "{d} d", .{days}) catch null
    else
        std.fmt.bufPrint(buf, "{d} d {d} h", .{ days, rest_hours }) catch null;
}

/// The session the hover talks about: the first live one (in array order),
/// else the next to start. Null when nothing is live or ahead.
pub fn nextSession(sessions: []const Session, now_ms: i64) ?*const Session {
    var best: ?*const Session = null;
    for (sessions) |*session| {
        if (session.end_ms <= session.start_ms) continue;
        if (session.start_ms <= now_ms and now_ms < session.end_ms) return session;
        if (session.start_ms > now_ms and (best == null or session.start_ms < best.?.start_ms)) {
            best = session;
        }
    }
    return best;
}

/// The hover line for `now_ms`, written into `buf`, or null when nothing
/// is scheduled (or the line does not fit).
pub fn hoverText(buf: []u8, sessions: []const Session, now_ms: i64) ?[]const u8 {
    const session = nextSession(sessions, now_ms) orelse return null;
    if (session.label.len == 0) return null;
    if (session.start_ms <= now_ms) {
        return std.fmt.bufPrint(buf, "{s} is live \u{00B7} {s}", .{ session.label, session.gp }) catch null;
    }
    var countdown_buf: [32]u8 = undefined;
    const countdown = formatCountdown(&countdown_buf, session.start_ms - now_ms) orelse return null;
    return std.fmt.bufPrint(buf, "{s} in {s} \u{00B7} {s}", .{ session.label, countdown, session.gp }) catch null;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const min = minute_ms;

test "formatCountdown: schedule.test.mjs table" {
    const cases = [_]struct { ms: i64, text: []const u8 }{
        .{ .ms = 1, .text = "1 min" },
        .{ .ms = 14 * min, .text = "14 min" },
        .{ .ms = 59 * min + 1, .text = "1 h" },
        .{ .ms = 134 * min, .text = "2 h 14 min" },
        .{ .ms = 120 * min, .text = "2 h" },
        .{ .ms = 24 * 60 * min, .text = "1 d" },
        .{ .ms = (3 * 24 + 4) * 60 * min, .text = "3 d 4 h" },
        // Below one minute and non-positive still say "1 min" (Math.max).
        .{ .ms = 0, .text = "1 min" },
        .{ .ms = -5, .text = "1 min" },
    };
    for (cases) |c| {
        var buf: [32]u8 = undefined;
        try testing.expectEqualStrings(c.text, formatCountdown(&buf, c.ms).?);
    }
}

const las_vegas = [_]Session{
    // parseSchedule sorts by start; the JS test feeds RACE then QUALI.
    .{ .label = "Qualifying", .gp = "Las Vegas GP", .start_ms = 1795233600000, .end_ms = 1795233600000 + 60 * min },
    .{ .label = "Race", .gp = "Las Vegas GP", .start_ms = 1795320000000, .end_ms = 1795320000000 + 120 * min },
};

test "hoverText: schedule.test.mjs countdownText table" {
    // 2026-11-21T04:00:00Z = 1795233600000
    const q = las_vegas[0].start_ms;
    const cases = [_]struct { now: i64, text: ?[]const u8 }{
        .{ .now = q - (2 * 60 + 14) * min, .text = "Qualifying in 2 h 14 min \u{00B7} Las Vegas GP" },
        .{ .now = q + 10 * min, .text = "Qualifying is live \u{00B7} Las Vegas GP" },
        .{ .now = q + 60 * min, .text = "Race in 23 h \u{00B7} Las Vegas GP" },
        .{ .now = q + 25 * 60 * min, .text = "Race is live \u{00B7} Las Vegas GP" },
        .{ .now = q + 26 * 60 * min, .text = null },
    };
    for (cases) |c| {
        var buf: [max_text_bytes]u8 = undefined;
        const got = hoverText(&buf, &las_vegas, c.now);
        if (c.text) |want| {
            try testing.expectEqualStrings(want, got.?);
        } else {
            try testing.expect(got == null);
        }
    }
    var buf: [max_text_bytes]u8 = undefined;
    try testing.expect(hoverText(&buf, &.{}, 0) == null);
}

test "nextSession: the live one first, else the next to start" {
    const q = las_vegas[0].start_ms;
    try testing.expectEqual(&las_vegas[0], nextSession(&las_vegas, q - 4 * 60 * min).?);
    try testing.expectEqual(&las_vegas[0], nextSession(&las_vegas, q + 30 * min).?);
    try testing.expectEqual(&las_vegas[1], nextSession(&las_vegas, q + 60 * min).?);
    try testing.expect(nextSession(&las_vegas, q + 27 * 60 * min) == null);
}

test "countdown-cases.json: byte-for-byte with schedule.mjs" {
    const timeline = @import("timeline.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try timeline.readFixture(arena.allocator(), "countdown-cases.json");
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), bytes, .{});

    for (root.object.get("format").?.array.items) |item| {
        const ms = item.object.get("ms").?.integer;
        var buf: [32]u8 = undefined;
        try testing.expectEqualStrings(item.object.get("text").?.string, formatCountdown(&buf, ms).?);
    }

    // The sessions the hover cases ran over are the weekend timeline's.
    const weekend = try timeline.readFixture(arena.allocator(), "timeline-weekend.json");
    var tl = try timeline.parse(testing.allocator, weekend, timeline.fixture_user_data);
    defer tl.deinit();
    var checked: usize = 0;
    for (root.object.get("hover").?.array.items) |item| {
        const now = try timeline.parseIso(item.object.get("now").?.string);
        var buf: [max_text_bytes]u8 = undefined;
        const got = hoverText(&buf, tl.sessions, now);
        switch (item.object.get("text").?) {
            .string => |want| try testing.expectEqualStrings(want, got.?),
            else => try testing.expect(got == null),
        }
        checked += 1;
    }
    try testing.expect(checked > 200);
}
