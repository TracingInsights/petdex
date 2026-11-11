//! What the native pet changed while Electron was gone.
//!
//! Writer of `userData/pet-native-state.json` (v1); the reader is
//! desktop/src/pets/native-state.mjs in the tif1ai repo, which merges every
//! valid field into Electron's settings on its next start and deletes the
//! file (from then on Electron is the writer again). Change both together.
//!
//!   {
//!     "v": 1, "updatedAt": ISO,
//!     "enabled"?: bool,                 Show / Hide pet
//!     "size"?: "s"|"m"|"l",
//!     "quietUntil"?: ISO|null,          null = Quiet off
//!     "launchAtLogin"?: bool,
//!     "position"?: { "x", "y" },        last drop point
//!     "shownMoments"?: [{ "name", "value" }]   the last 32, oldest first
//!     "mutes"?: ["fact", …]             bubble kinds switched off with a
//!                                       bubble's `mute` button (round 3)
//!   }
//!
//! `mutes` holds BUBBLE_KINDS names; Electron turns each into its setting
//! (fact → dailyFacts, rate → rateNudges, result → resultReactions,
//! greeting → greetings, calendar → sessionReactions 'off') and an older
//! Electron simply ignores the key. `shownMoments` may now carry
//! `lastGreetingKey`.
//!
//! Always go through `update`: it re-reads the file before applying one
//! change, so a field Electron already merged (and deleted with the file)
//! is never written back from a stale copy in memory. Writes are atomic
//! (temporary file + rename) and the file is 0600.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const timeline = @import("timeline.zig");

pub const state_version: i64 = 1;
pub const file_name = "pet-native-state.json";
/// native-state.mjs MAX_BYTES / MAX_MOMENTS.
pub const max_file_bytes: usize = 64 * 1024;
pub const max_moments: usize = 32;
/// Distinct bubble kinds `mutes` keeps (there are six).
pub const max_mutes: usize = 8;
pub const max_mute_bytes: usize = timeline.max_bubble_kind_bytes;
pub const max_moment_value_bytes: usize = timeline.max_moment_value_bytes;
/// native-state.mjs ignores positions at or beyond this.
const max_coord: f64 = 1e6;

pub const MomentName = timeline.MomentName;

pub const Quiet = union(enum) {
    /// Not changed natively: the field is left out.
    unset,
    /// Quiet switched off (written as null).
    off,
    until: i64,
};

pub const Position = struct { x: i64, y: i64 };

pub const Moment = struct {
    name: MomentName,
    len: u8,
    buf: [max_moment_value_bytes]u8,

    pub fn value(self: *const Moment) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Mute = struct {
    len: u8,
    buf: [max_mute_bytes]u8,

    pub fn kind(self: *const Mute) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const NativeState = struct {
    enabled: ?bool = null,
    size: ?protocol.Size = null,
    quiet: Quiet = .unset,
    launch_at_login: ?bool = null,
    position: ?Position = null,
    moments: [max_moments]Moment = undefined,
    moments_len: usize = 0,
    mutes: [max_mutes]Mute = undefined,
    mutes_len: usize = 0,

    pub fn muted(self: *const NativeState) []const Mute {
        return self.mutes[0..self.mutes_len];
    }

    /// Record a bubble kind the user muted. A repeat is skipped; false
    /// when the name is not a bubble kind or the list is full.
    pub fn addMute(self: *NativeState, kind: []const u8) bool {
        if (!timeline.bubbleKindOk(kind)) return false;
        for (self.muted()) |*m| if (std.mem.eql(u8, m.kind(), kind)) return true;
        if (self.mutes_len == max_mutes) return false;
        var m: Mute = .{ .len = @intCast(kind.len), .buf = undefined };
        @memcpy(m.buf[0..kind.len], kind);
        self.mutes[self.mutes_len] = m;
        self.mutes_len += 1;
        return true;
    }

    pub fn shownMoments(self: *const NativeState) []const Moment {
        return self.moments[0..self.moments_len];
    }

    /// For Timeline.setQuietUntil: null when Quiet was not changed natively.
    pub fn quietOverride(self: *const NativeState) ?timeline.QuietOverride {
        return switch (self.quiet) {
            .unset => null,
            .off => .off,
            .until => |ms| .{ .until = ms },
        };
    }

    /// Record a moment the pet really showed. A repeat of the same marker
    /// is skipped; the oldest is dropped past `max_moments` (the reader
    /// keeps the last 32). False when the value is empty or too long.
    pub fn addShownMoment(self: *NativeState, name: MomentName, value: []const u8) bool {
        if (value.len == 0 or value.len > max_moment_value_bytes) return false;
        for (self.shownMoments()) |*m| {
            if (m.name == name and std.mem.eql(u8, m.value(), value)) return true;
        }
        if (self.moments_len == max_moments) {
            std.mem.copyForwards(Moment, self.moments[0 .. max_moments - 1], self.moments[1..max_moments]);
            self.moments_len -= 1;
        }
        var m: Moment = .{ .name = name, .len = @intCast(value.len), .buf = undefined };
        @memcpy(m.buf[0..value.len], value);
        self.moments[self.moments_len] = m;
        self.moments_len += 1;
        return true;
    }

    pub fn apply(self: *NativeState, change: Change) void {
        switch (change) {
            .enabled => |v| self.enabled = v,
            .size => |v| self.size = v,
            .quiet_until => |v| self.quiet = if (v) |ms| .{ .until = ms } else .off,
            .launch_at_login => |v| self.launch_at_login = v,
            .position => |p| {
                if (std.math.isFinite(p.x) and std.math.isFinite(p.y) and @abs(p.x) < max_coord and @abs(p.y) < max_coord) {
                    self.position = .{ .x = @intFromFloat(@round(p.x)), .y = @intFromFloat(@round(p.y)) };
                }
            },
            .shown_moment => |m| _ = self.addShownMoment(m.name, m.value),
            .mute => |kind| _ = self.addMute(kind),
        }
    }

    /// The document as one JSON object (with a trailing newline), or null
    /// when `buf` is too small (`max_file_bytes` always fits).
    pub fn encode(self: *const NativeState, buf: []u8, now_ms: i64) ?[]const u8 {
        var w: std.Io.Writer = .fixed(buf);
        self.write(&w, now_ms) catch return null;
        return w.buffered();
    }

    fn write(self: *const NativeState, w: *std.Io.Writer, now_ms: i64) std.Io.Writer.Error!void {
        var iso: [24]u8 = undefined;
        var s: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
        try s.beginObject();
        try s.objectField("v");
        try s.write(state_version);
        try s.objectField("updatedAt");
        try s.write(timeline.formatIso(&iso, now_ms));
        if (self.enabled) |v| {
            try s.objectField("enabled");
            try s.write(v);
        }
        if (self.size) |v| {
            try s.objectField("size");
            try s.write(@tagName(v));
        }
        switch (self.quiet) {
            .unset => {},
            .off => {
                try s.objectField("quietUntil");
                try s.write(null);
            },
            .until => |ms| {
                try s.objectField("quietUntil");
                try s.write(timeline.formatIso(&iso, ms));
            },
        }
        if (self.launch_at_login) |v| {
            try s.objectField("launchAtLogin");
            try s.write(v);
        }
        if (self.position) |p| {
            try s.objectField("position");
            try s.write(p);
        }
        if (self.moments_len > 0) {
            try s.objectField("shownMoments");
            try s.beginArray();
            for (self.shownMoments()) |*m| {
                try s.write(.{ .name = @tagName(m.name), .value = m.value() });
            }
            try s.endArray();
        }
        if (self.mutes_len > 0) {
            try s.objectField("mutes");
            try s.beginArray();
            for (self.muted()) |*m| try s.write(m.kind());
            try s.endArray();
        }
        try s.endObject();
        try w.writeByte('\n');
    }
};

/// One native change (tray / pet menu choice, drop, shown moment).
pub const Change = union(enum) {
    enabled: bool,
    size: protocol.Size,
    /// null = Quiet off.
    quiet_until: ?i64,
    launch_at_login: bool,
    position: struct { x: f64, y: f64 },
    shown_moment: struct { name: MomentName, value: []const u8 },
    /// A bubble kind switched off offline (bubble `mute` button).
    mute: []const u8,
};

/// Field by field, like parseNativeState: an invalid field is skipped,
/// never the whole document; a wrong `v` or broken JSON gives an empty
/// state.
pub fn parse(scratch: std.mem.Allocator, bytes: []const u8) NativeState {
    var st: NativeState = .{};
    if (bytes.len > max_file_bytes) return st;
    const root = std.json.parseFromSliceLeaky(std.json.Value, scratch, bytes, .{}) catch return st;
    const o = switch (root) {
        .object => |o| o,
        else => return st,
    };
    const v = o.get("v") orelse return st;
    if (v != .integer or v.integer != state_version) return st;
    if (o.get("enabled")) |x| if (x == .bool) {
        st.enabled = x.bool;
    };
    if (o.get("size")) |x| if (x == .string) {
        st.size = std.meta.stringToEnum(protocol.Size, x.string);
    };
    if (o.get("quietUntil")) |x| switch (x) {
        .null => st.quiet = .off,
        .string => |s| if (timeline.parseIso(s)) |ms| {
            st.quiet = .{ .until = ms };
        } else |_| {},
        else => {},
    };
    if (o.get("launchAtLogin")) |x| if (x == .bool) {
        st.launch_at_login = x.bool;
    };
    if (o.get("position")) |x| if (x == .object) {
        const px = number(x.object.get("x"));
        const py = number(x.object.get("y"));
        if (px != null and py != null) st.apply(.{ .position = .{ .x = px.?, .y = py.? } });
    };
    if (o.get("shownMoments")) |x| if (x == .array) {
        const items = x.array.items;
        for (items[items.len -| max_moments..]) |item| {
            if (item != .object) continue;
            const name = item.object.get("name") orelse continue;
            const value = item.object.get("value") orelse continue;
            if (name != .string or value != .string) continue;
            const n = std.meta.stringToEnum(MomentName, name.string) orelse continue;
            _ = st.addShownMoment(n, value.string);
        }
    };
    if (o.get("mutes")) |x| if (x == .array) {
        for (x.array.items) |item| {
            if (item == .string) _ = st.addMute(item.string);
        }
    };
    return st;
}

fn number(v: ?std.json.Value) ?f64 {
    return switch (v orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

pub const SaveError = error{ OpenFailed, WriteFailed, TooLarge };

/// The state on disk (empty when there is no file or it is unreadable).
pub fn read(io: std.Io, user_data_dir: []const u8) NativeState {
    var dir = std.Io.Dir.openDirAbsolute(io, user_data_dir, .{}) catch return .{};
    defer dir.close(io);
    var buf: [max_file_bytes + 1]u8 = undefined;
    const bytes = dir.readFile(io, file_name, &buf) catch return .{};
    if (bytes.len > max_file_bytes) return .{};
    var scratch_buf: [4 * max_file_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch_buf);
    return parse(fba.allocator(), bytes);
}

/// Atomically replace the file with `st` (0600).
pub fn save(io: std.Io, user_data_dir: []const u8, st: *const NativeState, now_ms: i64) SaveError!void {
    var out: [max_file_bytes]u8 = undefined;
    const bytes = st.encode(&out, now_ms) orelse return error.TooLarge;
    var dir = std.Io.Dir.openDirAbsolute(io, user_data_dir, .{}) catch return error.OpenFailed;
    defer dir.close(io);
    const permissions: std.Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else @enumFromInt(0o600);
    var atomic = dir.createFileAtomic(io, file_name, .{ .permissions = permissions, .replace = true }) catch
        return error.OpenFailed;
    defer atomic.deinit(io);
    atomic.file.writeStreamingAll(io, bytes) catch return error.WriteFailed;
    atomic.file.sync(io) catch return error.WriteFailed;
    atomic.replace(io) catch return error.WriteFailed;
}

/// Re-read the file, apply one change, write it back. Returns the state
/// now on disk.
pub fn update(io: std.Io, user_data_dir: []const u8, now_ms: i64, change: Change) SaveError!NativeState {
    var st = read(io, user_data_dir);
    st.apply(change);
    try save(io, user_data_dir, &st, now_ms);
    return st;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn tmpPath(a: std.mem.Allocator, tmp: *testing.TmpDir) ![]u8 {
    return tmp.dir.realPathFileAlloc(testing.io, ".", a);
}

test "encode: only the fields that changed, in the reader's shape" {
    var st: NativeState = .{};
    var buf: [max_file_bytes]u8 = undefined;
    const now = try timeline.parseIso("2026-11-07T12:00:00Z");
    try testing.expectEqualStrings(
        \\{
        \\  "v": 1,
        \\  "updatedAt": "2026-11-07T12:00:00.000Z"
        \\}
        \\
    , st.encode(&buf, now).?);

    st.apply(.{ .enabled = false });
    st.apply(.{ .size = .l });
    st.apply(.{ .quiet_until = try timeline.parseIso("2026-11-07T13:00:00Z") });
    st.apply(.{ .launch_at_login = true });
    st.apply(.{ .position = .{ .x = 40.4, .y = -60.6 } });
    st.apply(.{ .shown_moment = .{ .name = .lastFactDay, .value = "2026-11-07" } });
    st.apply(.{ .shown_moment = .{ .name = .lastFactDay, .value = "2026-11-07" } });
    st.apply(.{ .shown_moment = .{ .name = .lastRateKey, .value = "2026_20_\"race\"" } });
    try testing.expectEqualStrings(
        \\{
        \\  "v": 1,
        \\  "updatedAt": "2026-11-07T12:00:00.000Z",
        \\  "enabled": false,
        \\  "size": "l",
        \\  "quietUntil": "2026-11-07T13:00:00.000Z",
        \\  "launchAtLogin": true,
        \\  "position": {
        \\    "x": 40,
        \\    "y": -61
        \\  },
        \\  "shownMoments": [
        \\    {
        \\      "name": "lastFactDay",
        \\      "value": "2026-11-07"
        \\    },
        \\    {
        \\      "name": "lastRateKey",
        \\      "value": "2026_20_\"race\""
        \\    }
        \\  ]
        \\}
        \\
    , st.encode(&buf, now).?);

    st.apply(.{ .quiet_until = null });
    try testing.expect(std.mem.indexOf(u8, st.encode(&buf, now).?, "\"quietUntil\": null") != null);
    try testing.expectEqual(timeline.QuietOverride.off, st.quietOverride().?);
}

test "mutes: deduplicated, bubble kinds only, round-tripped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var st: NativeState = .{};
    st.apply(.{ .mute = "fact" });
    st.apply(.{ .mute = "fact" });
    st.apply(.{ .mute = "calendar" });
    try testing.expect(!st.addMute("Fact!"));
    try testing.expect(!st.addMute(""));
    try testing.expectEqual(@as(usize, 2), st.muted().len);
    st.apply(.{ .shown_moment = .{ .name = .lastGreetingKey, .value = "2026-11-07:evening" } });
    var buf: [max_file_bytes]u8 = undefined;
    const now = try timeline.parseIso("2026-11-07T12:00:00Z");
    const text = st.encode(&buf, now).?;
    try testing.expect(std.mem.indexOf(u8, text,
        \\  "mutes": [
        \\    "fact",
        \\    "calendar"
        \\  ]
    ) != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"name\": \"lastGreetingKey\"") != null);
    const back = parse(arena.allocator(), text);
    try testing.expectEqual(@as(usize, 2), back.muted().len);
    try testing.expectEqualStrings("calendar", back.muted()[1].kind());
    try testing.expectEqual(MomentName.lastGreetingKey, back.shownMoments()[0].name);
    // Bad entries are skipped one by one; a full list refuses more.
    const mixed = parse(arena.allocator(), "{\"v\":1,\"mutes\":[\"rate\",7,\"NOPE\",\"rate\",\"greeting\"]}");
    try testing.expectEqual(@as(usize, 2), mixed.muted().len);
    var full: NativeState = .{};
    for ([_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h" }) |k| try testing.expect(full.addMute(k));
    try testing.expect(!full.addMute("i"));
    try testing.expect(full.addMute("a"));
}

test "moments: capped at 32, oldest dropped; bad values refused" {
    var st: NativeState = .{};
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        var b: [16]u8 = undefined;
        try testing.expect(st.addShownMoment(.lastFactDay, try std.fmt.bufPrint(&b, "day-{d}", .{i})));
    }
    try testing.expectEqual(max_moments, st.shownMoments().len);
    try testing.expectEqualStrings("day-8", st.shownMoments()[0].value());
    try testing.expectEqualStrings("day-39", st.shownMoments()[31].value());
    try testing.expect(!st.addShownMoment(.lastFactDay, ""));
    try testing.expect(!st.addShownMoment(.lastFactDay, "x" ** (max_moment_value_bytes + 1)));
    // Off-screen positions are ignored (the reader would skip them too).
    st.apply(.{ .position = .{ .x = 2e6, .y = 0 } });
    try testing.expect(st.position == null);
}

test "parse: field by field, like parseNativeState" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const st = parse(a,
        \\{"v":1,"enabled":"yes","size":"xl","quietUntil":"2026-11-07T13:00:00.000Z",
        \\ "launchAtLogin":true,"position":{"x":1.6,"y":"2"},
        \\ "shownMoments":[{"name":"lastFactDay","value":"2026-11-07"},{"name":"nope","value":"x"},7]}
    );
    try testing.expect(st.enabled == null and st.size == null and st.position == null);
    try testing.expectEqual(true, st.launch_at_login.?);
    try testing.expectEqual(try timeline.parseIso("2026-11-07T13:00:00Z"), st.quiet.until);
    try testing.expectEqual(@as(usize, 1), st.shownMoments().len);
    try testing.expect(parse(a, "{\"v\":2,\"enabled\":true}").enabled == null);
    try testing.expect(parse(a, "not json").enabled == null);
}

test "update: atomic, 0600, re-reads the file each time" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const dir = try tmpPath(arena.allocator(), &tmp);
    const now = try timeline.parseIso("2026-11-07T12:00:00Z");

    _ = try update(io, dir, now, .{ .size = .s });
    var st = try update(io, dir, now + 1000, .{ .shown_moment = .{ .name = .lastFactDay, .value = "2026-11-07" } });
    try testing.expectEqual(protocol.Size.s, st.size.?);
    try testing.expectEqual(@as(usize, 1), st.shownMoments().len);

    if (builtin.os.tag != .windows) {
        const stat = try tmp.dir.statFile(io, file_name, .{});
        try testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(@intFromEnum(stat.permissions))) & 0o777);
    }
    // Only the state file is left (no temporaries).
    var listing = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer listing.close(io);
    var it = listing.iterate();
    var count: usize = 0;
    while (try it.next(io)) |_| count += 1;
    try testing.expectEqual(@as(usize, 1), count);

    // Electron merged and deleted the file: the next change starts fresh.
    try tmp.dir.deleteFile(io, file_name);
    st = try update(io, dir, now + 2000, .{ .enabled = true });
    try testing.expect(st.size == null and st.shownMoments().len == 0);
    try testing.expectEqual(true, read(io, dir).enabled.?);
}
