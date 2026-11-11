//! Timeline playback, native side.
//!
//! While the TracingInsights desktop app is gone, the pet plays the
//! timeline Electron compiled before it quit: desktop/src/pets/timeline.mjs
//! in the tif1ai repo runs the real controller on a virtual clock for the
//! next 7 days and writes every render it would have made to
//! `userData/pet-timeline.json` (v1 or v2). Nothing here decides behaviour;
//! this file only validates the document and answers "what shows at `now`".
//!
//! v2 (round 3; Electron writes it only to a pet whose `ready.caps` has
//! `timeline-v2`) adds, all optional with the v1 meaning when missing:
//!   entries[]: motion ('roam'|'dash'|null), sleeping (bool),
//!              bubbleActions ({ id, label }[] | null, at most 3),
//!              bubbleKind (string | null: 'fact', 'rate', 'result',
//!              'greeting', 'calendar', 'celebrate' — what `mute` silences),
//!              secondAnim ({ state, row, frames, durationMs, once, still,
//!              playKey, delayMs? } | null), states 'look-a' / 'look-b'
//!   panel:     { lines?: string[], countdown?: bool, actions: { id, label,
//!              target: string|null, from?: ISO|null, until?: ISO|null }[] }
//!              | null — the click panel while Electron is gone; the
//!              countdown line on top is computed here like the hover text
//!   moment.name 'lastGreetingKey' (race-weekend greetings)
//! A v1 reader rejects v2 (UnsupportedVersion), so Electron must keep
//! writing v1 for an older pet.
//!
//! On top of the compiled entries it applies the one thing the user can
//! change natively: Quiet. A quiet window (from pet-native-state.json, set
//! from the tray or pet menu) wins over the file: visible entries become the
//! idle pose with no bubble and no moment until it ends.
//!
//! Validation is strict, because a timeline that disagrees with this file
//! is a version skew to fix, not data to guess at: an unknown `v`, a time
//! that is not ISO-8601, entries out of order, a sprite path outside
//! `--user-data`, an unknown pose or a file over `max_file_bytes` rejects the
//! whole document. Unknown keys are ignored (a newer desktop may add some).
//! Change timeline.mjs and this file together and bump the version.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const sprite = @import("sprite.zig");
const countdown = @import("countdown.zig");

pub const timeline_version: i64 = 2;
/// Oldest document version still played (v1 = no round-3 fields).
pub const min_timeline_version: i64 = 1;
pub const max_bubble_kind_bytes: usize = 24;
pub const file_name = "pet-timeline.json";
pub const max_file_bytes: usize = 1024 * 1024;
pub const max_play_key_bytes: usize = 128;
pub const max_moment_value_bytes: usize = 128;
pub const max_session_text_bytes: usize = 200;

/// The idle pose (desktop contract PET_STATES[0]) shown while quiet.
const idle_row: u8 = 0;
const idle_frames: u8 = 6;
const idle_duration_ms: u32 = 1100;

/// "Quiet until this session ends" also covers the lead-in before a
/// session (desktop contract SESSION_LEAD_MS, controller.currentSessionEndMs).
pub const session_lead_ms: i64 = 30 * 60 * 1000;
/// How long a hover bubble stays (desktop behaviour.mjs HOVER_BUBBLE_MS).
pub const hover_bubble_ms: i64 = 6000;

pub const Error = error{
    InvalidTimeline,
    UnsupportedVersion,
    TooLarge,
    PathOutsideUserData,
    ReadFailed,
    OutOfMemory,
};

/// A once-only marker (settings MARKER_SETTINGS) an entry's bubble stands
/// for. Report it (state.zig `addShownMoment`) only when the entry was
/// really on screen, so Electron neither repeats nor loses it.
pub const MomentName = enum { lastResultKey, lastRateKey, lastFactDay, lastGreetingKey };

pub const Moment = struct {
    name: MomentName,
    value: []const u8,
};

pub const SessionReactions = enum { calm, lively, off };

/// One timeline entry; holds from `at_ms` until the next one. Hidden
/// entries (`visible == false`) carry only `at_ms`.
pub const Entry = struct {
    at_ms: i64,
    visible: bool,
    state: protocol.State = .idle,
    row: u8 = idle_row,
    frames: u8 = idle_frames,
    duration_ms: u32 = idle_duration_ms,
    once: bool = false,
    still: bool = false,
    /// Restart the animation when this changes (as the live renderer does).
    play_key: []const u8 = "idle",
    bubble: ?[]const u8 = null,
    /// App path a bubble click opens (`--pets-open=<path>`); null = calendar.
    bubble_target: ?[]const u8 = null,
    /// Both pets on screen.
    duo: bool = false,
    moment: ?Moment = null,
    // --- v2 ---
    motion: ?protocol.Motion = null,
    sleeping: bool = false,
    bubble_actions: []const protocol.Action = &.{},
    /// The bubble's kind (BUBBLE_KINDS), for the offline `mute` button.
    bubble_kind: ?[]const u8 = null,
    second_anim: ?protocol.Anim = null,

    /// The same shape as a live `render` message, so playback and live mode
    /// can share one drawing path. Null for hidden entries.
    pub fn render(self: Entry, tl: *const Timeline) ?protocol.Render {
        if (!self.visible) return null;
        const first = tl.pets.first orelse return null;
        return .{
            .state = self.state,
            .row = self.row,
            .frames = self.frames,
            .duration_ms = self.duration_ms,
            .once = self.once,
            .still = self.still,
            .play_key = self.play_key,
            .bubble = self.bubble,
            .size = tl.size,
            .atlas = first,
            .second = if (self.duo) tl.pets.second else null,
            .motion = self.motion,
            .sleeping = self.sleeping,
            .bubble_actions = self.bubble_actions,
            .second_anim = if (self.duo) self.second_anim else null,
        };
    }
};

/// One click-panel button while Electron is gone: `target` opens the app
/// on that path (`--pets-open=`), null = no offline action. Shown only
/// inside [from, until) when those are set (the rate nudge's window).
pub const PanelAction = struct {
    id: []const u8,
    label: []const u8,
    target: ?[]const u8 = null,
    from_ms: ?i64 = null,
    until_ms: ?i64 = null,

    pub fn shownAt(self: PanelAction, now_ms: i64) bool {
        if (self.from_ms) |from| if (now_ms < from) return false;
        if (self.until_ms) |until| if (now_ms >= until) return false;
        return true;
    }
};

/// The click panel as compiled at hand-off (v2 `panel`).
pub const Panel = struct {
    /// Static lines (the latest result), shown under the countdown.
    lines: []const []const u8 = &.{},
    /// Put the hover countdown line on top.
    countdown: bool = true,
    actions: []const PanelAction = &.{},
};

pub const Pets = struct {
    first: ?protocol.Sprite = null,
    second: ?protocol.Sprite = null,
};

pub const Duo = struct {
    text: []const u8,
    target: []const u8,
};

pub const Hover = struct {
    text: []const u8,
    target: []const u8,
};

/// Quiet as the native pet knows it: `none` = whatever the file says,
/// `off` = the user switched Quiet off natively, `until` = quiet until then.
pub const QuietOverride = union(enum) {
    none,
    off,
    until: i64,
};

pub const Timeline = struct {
    arena: std.heap.ArenaAllocator,
    generated_at_ms: i64,
    until_ms: i64,
    /// Start Electron with `--pets-refresh` at or after this (launch.zig).
    refresh_at_ms: i64,
    pets: Pets,
    size: protocol.Size,
    /// Quiet compiled into the file (already applied to its entries).
    quiet_until_ms: ?i64,
    session_reactions: SessionReactions,
    entries: []const Entry,
    sessions: []const countdown.Session,
    duo: ?Duo,
    calendar_target: []const u8,
    /// False when the file names a countdown format this pet does not know:
    /// no hover countdown then (the duo line still works).
    countdown_v1: bool,
    /// v2: the click panel (null = clicks only jump, as in v1).
    panel: ?Panel = null,
    quiet: QuietOverride = .none,

    pub fn deinit(self: *Timeline) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Apply the native state's quietUntil (null = Quiet off).
    pub fn setQuietUntil(self: *Timeline, until_ms: ?i64) void {
        self.quiet = if (until_ms) |ms| .{ .until = ms } else .off;
    }

    /// When quiet ends, if it is on at `now_ms`.
    pub fn quietUntilAt(self: *const Timeline, now_ms: i64) ?i64 {
        const until: ?i64 = switch (self.quiet) {
            .none => self.quiet_until_ms,
            .off => null,
            .until => |ms| ms,
        };
        const ms = until orelse return null;
        return if (ms > now_ms) ms else null;
    }

    pub fn isQuiet(self: *const Timeline, now_ms: i64) bool {
        return self.quietUntilAt(now_ms) != null;
    }

    /// The compiled entry in effect at `now_ms`, without the quiet overlay.
    /// Before the first entry (clock moved back) the first one; past the
    /// end the last one keeps holding until a refresh replaces the file.
    /// Null when the timeline has no entries (show nothing).
    pub fn rawEntryAt(self: *const Timeline, now_ms: i64) ?Entry {
        return self.entries[self.indexAt(now_ms) orelse return null];
    }

    /// Index of the entry `rawEntryAt` returns (changes exactly when a new
    /// entry takes over: apply bubbles and moments once per index).
    pub fn indexAt(self: *const Timeline, now_ms: i64) ?usize {
        if (self.entries.len == 0) return null;
        // Last entry with at <= now (binary search, entries ascend).
        var lo: usize = 0;
        var hi: usize = self.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.entries[mid].at_ms <= now_ms) lo = mid + 1 else hi = mid;
        }
        return if (lo == 0) 0 else lo - 1;
    }

    /// What shows at `now_ms`: the compiled entry with Quiet applied.
    /// Null = nothing to show (hide the pet).
    pub fn entryAt(self: *const Timeline, now_ms: i64) ?Entry {
        var entry = self.rawEntryAt(now_ms) orelse return null;
        if (entry.visible and self.isQuiet(now_ms)) {
            // behaviour.mjs: quiet → idle, no bubbles. Reduce motion and a
            // locked screen are compiled into `still`, which stays.
            entry.state = .idle;
            entry.row = idle_row;
            entry.frames = idle_frames;
            entry.duration_ms = idle_duration_ms;
            entry.once = false;
            entry.play_key = "idle";
            entry.bubble = null;
            entry.bubble_target = null;
            entry.moment = null;
            // Quiet also stops the walk and the duo's own reactions.
            entry.motion = null;
            entry.bubble_actions = &.{};
            entry.bubble_kind = null;
            entry.second_anim = null;
        }
        return entry;
    }

    /// The next instant after `now_ms` at which `entryAt` may change: the
    /// next entry or the end of a quiet window. Null = nothing scheduled
    /// (the refresh timer still runs).
    pub fn nextChangeAt(self: *const Timeline, now_ms: i64) ?i64 {
        var next: ?i64 = null;
        // First entry with at > now.
        var lo: usize = 0;
        var hi: usize = self.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.entries[mid].at_ms <= now_ms) lo = mid + 1 else hi = mid;
        }
        if (lo < self.entries.len) next = self.entries[lo].at_ms;
        if (self.quietUntilAt(now_ms)) |q| {
            if (next == null or q < next.?) next = q;
        }
        return next;
    }

    /// Time for a `--pets-refresh` run.
    pub fn refreshDue(self: *const Timeline, now_ms: i64) bool {
        return now_ms >= self.refresh_at_ms;
    }

    /// End of the session "Quiet until this session ends" covers at
    /// `now_ms` (the live one, else one starting within 30 min), or null
    /// when the menu item should be disabled. Mirrors the controller's
    /// currentSessionEndMs over calendarPhase.
    pub fn sessionQuietEnd(self: *const Timeline, now_ms: i64) ?i64 {
        var live: ?*const countdown.Session = null;
        var lead: ?*const countdown.Session = null;
        for (self.sessions) |*s| {
            if (s.start_ms <= now_ms and now_ms < s.end_ms) {
                if (live == null or s.start_ms > live.?.start_ms) live = s;
            } else if (s.start_ms - session_lead_ms <= now_ms and now_ms < s.start_ms) {
                if (lead == null or s.start_ms < lead.?.start_ms) lead = s;
            }
        }
        const session = live orelse lead orelse return null;
        return if (session.end_ms > now_ms) session.end_ms else null;
    }

    /// Hover bubble content at `now_ms` (controller.hoverContent): the
    /// duo's head-to-head while both pets show, else the session countdown
    /// unless session reactions are off. Null while quiet (no bubbles) or
    /// when there is nothing to say. Text is written into `buf`
    /// (≥ countdown.max_text_bytes) or points into the timeline.
    pub fn hover(self: *const Timeline, buf: []u8, now_ms: i64, duo_showing: bool) ?Hover {
        if (self.isQuiet(now_ms)) return null;
        if (duo_showing) {
            if (self.duo) |duo| return .{ .text = duo.text, .target = duo.target };
        }
        if (self.session_reactions == .off or !self.countdown_v1) return null;
        const text = countdown.hoverText(buf, self.sessions, now_ms) orelse return null;
        return .{ .text = text, .target = self.calendar_target };
    }

    /// The panel's countdown line at `now_ms` (the hover countdown, quiet
    /// or not: the panel is the user's own click), or null.
    pub fn panelCountdown(self: *const Timeline, buf: []u8, now_ms: i64) ?[]const u8 {
        const panel = self.panel orelse return null;
        if (!panel.countdown or !self.countdown_v1) return null;
        return countdown.hoverText(buf, self.sessions, now_ms);
    }
};

// ------------------------------------------------------------- loading

/// Read and validate `path` (must lie inside `user_data_dir`, as must every
/// sprite path in it).
pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8, user_data_dir: []const u8) Error!Timeline {
    if (!pathInside(user_data_dir, path)) return error.PathOutsideUserData;
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return error.ReadFailed;
    defer file.close(io);
    const len = file.length(io) catch return error.ReadFailed;
    if (len > max_file_bytes) return error.TooLarge;
    const bytes = try gpa.alloc(u8, @intCast(len));
    defer gpa.free(bytes);
    const n = file.readPositionalAll(io, bytes, 0) catch return error.ReadFailed;
    if (n != bytes.len) return error.ReadFailed;
    return parse(gpa, bytes, user_data_dir);
}

/// Validate a timeline document. Strings in the result are copies owned by
/// the timeline (free with `deinit`); `bytes` may be freed right after.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8, user_data_dir: []const u8) Error!Timeline {
    if (bytes.len > max_file_bytes) return error.TooLarge;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidTimeline;

    // The JSON tree lives in a scratch arena; only what playback needs is
    // copied into the timeline's own.
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), bytes, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = max_file_bytes,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidTimeline;
    const obj = object(root) orelse return error.InvalidTimeline;

    const v = int(obj, "v") orelse return error.InvalidTimeline;
    if (v < min_timeline_version or v > timeline_version) return error.UnsupportedVersion;

    var tl: Timeline = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .generated_at_ms = try isoField(obj, "generatedAt"),
        .until_ms = try isoField(obj, "until"),
        .refresh_at_ms = try isoField(obj, "refreshAt"),
        .pets = .{},
        .size = .m,
        .quiet_until_ms = null,
        .session_reactions = .calm,
        .entries = &.{},
        .sessions = &.{},
        .duo = null,
        .calendar_target = "/",
        .countdown_v1 = true,
    };
    errdefer tl.arena.deinit();
    const a = tl.arena.allocator();
    if (tl.until_ms <= tl.generated_at_ms) return error.InvalidTimeline;

    // pets
    const pets = object(obj.get("pets") orelse return error.InvalidTimeline) orelse return error.InvalidTimeline;
    tl.pets.first = try parseSprite(a, pets.get("first"), user_data_dir);
    tl.pets.second = try parseSprite(a, pets.get("second"), user_data_dir);

    tl.size = std.meta.stringToEnum(protocol.Size, str(obj, "size") orelse return error.InvalidTimeline) orelse
        return error.InvalidTimeline;

    switch (obj.get("quietUntil") orelse std.json.Value.null) {
        .null => {},
        .string => |s| tl.quiet_until_ms = parseIso(s) catch return error.InvalidTimeline,
        else => return error.InvalidTimeline,
    }

    tl.session_reactions = std.meta.stringToEnum(SessionReactions, str(obj, "sessionReactions") orelse
        return error.InvalidTimeline) orelse return error.InvalidTimeline;

    // entries
    const raw_entries = array(obj.get("entries") orelse return error.InvalidTimeline) orelse
        return error.InvalidTimeline;
    const entries = try a.alloc(Entry, raw_entries.len);
    var last_at: i64 = std.math.minInt(i64);
    for (raw_entries, entries) |raw, *entry| {
        entry.* = try parseEntry(a, raw);
        if (entry.at_ms < last_at) return error.InvalidTimeline;
        last_at = entry.at_ms;
        if (entry.visible) {
            if (tl.pets.first == null) return error.InvalidTimeline;
            if (entry.duo and tl.pets.second == null) return error.InvalidTimeline;
        }
    }
    tl.entries = entries;

    // sessions
    const raw_sessions = array(obj.get("sessions") orelse return error.InvalidTimeline) orelse
        return error.InvalidTimeline;
    const sessions = try a.alloc(countdown.Session, raw_sessions.len);
    for (raw_sessions, sessions) |raw, *session| {
        const o = object(raw) orelse return error.InvalidTimeline;
        session.* = .{
            .key = try a.dupe(u8, try sessionText(o, "key")),
            .kind = try a.dupe(u8, try sessionText(o, "kind")),
            .label = try a.dupe(u8, try sessionText(o, "label")),
            .gp = try a.dupe(u8, try sessionText(o, "gp")),
            .start_ms = try isoField(o, "start"),
            .end_ms = try isoField(o, "end"),
        };
        if (session.end_ms <= session.start_ms) return error.InvalidTimeline;
    }
    tl.sessions = sessions;

    // duo
    switch (obj.get("duo") orelse std.json.Value.null) {
        .null => {},
        .object => |o| {
            const text = str(o, "text") orelse return error.InvalidTimeline;
            const target = str(o, "target") orelse return error.InvalidTimeline;
            if (text.len == 0 or !protocol.appPathOk(target)) return error.InvalidTimeline;
            tl.duo = .{
                .text = try a.dupe(u8, clipUtf8(text, protocol.max_text_bytes)),
                .target = try a.dupe(u8, target),
            };
        },
        else => return error.InvalidTimeline,
    }

    if (obj.get("calendarTarget")) |value| {
        const target = switch (value) {
            .string => |s| s,
            else => return error.InvalidTimeline,
        };
        if (!protocol.appPathOk(target)) return error.InvalidTimeline;
        tl.calendar_target = try a.dupe(u8, target);
    }
    if (obj.get("countdown")) |value| {
        const o = object(value) orelse return error.InvalidTimeline;
        tl.countdown_v1 = std.mem.eql(u8, str(o, "format") orelse "", "v1");
    }
    tl.panel = try parsePanel(a, obj.get("panel"));
    return tl;
}

fn parsePanel(a: std.mem.Allocator, value: ?std.json.Value) Error!?Panel {
    const o = switch (value orelse return null) {
        .null => return null,
        .object => |o| o,
        else => return error.InvalidTimeline,
    };
    var panel: Panel = .{};
    switch (o.get("lines") orelse std.json.Value.null) {
        .null => {},
        .array => |raw| {
            if (raw.items.len > protocol.max_panel_lines) return error.InvalidTimeline;
            const lines = try a.alloc([]const u8, raw.items.len);
            for (raw.items, lines) |item, *line| {
                const text = switch (item) {
                    .string => |t| t,
                    else => return error.InvalidTimeline,
                };
                if (text.len == 0) return error.InvalidTimeline;
                line.* = try a.dupe(u8, clipUtf8(text, protocol.max_panel_line_bytes));
            }
            panel.lines = lines;
        },
        else => return error.InvalidTimeline,
    }
    switch (o.get("countdown") orelse std.json.Value.null) {
        .null => {},
        .bool => |b| panel.countdown = b,
        else => return error.InvalidTimeline,
    }
    const raw_actions = array(o.get("actions") orelse return error.InvalidTimeline) orelse return error.InvalidTimeline;
    if (raw_actions.len > protocol.max_panel_actions) return error.InvalidTimeline;
    const actions = try a.alloc(PanelAction, raw_actions.len);
    for (raw_actions, actions) |raw, *action| {
        const ao = object(raw) orelse return error.InvalidTimeline;
        const id = str(ao, "id") orelse return error.InvalidTimeline;
        if (!protocol.actionIdOk(id)) return error.InvalidTimeline;
        const label = str(ao, "label") orelse return error.InvalidTimeline;
        if (label.len == 0) return error.InvalidTimeline;
        const target = try optionalStr(ao, "target");
        if (target) |t| if (!protocol.appPathOk(t)) return error.InvalidTimeline;
        action.* = .{
            .id = try a.dupe(u8, id),
            .label = try a.dupe(u8, clipUtf8(label, protocol.max_action_label_bytes)),
            .target = if (target) |t| try a.dupe(u8, t) else null,
            .from_ms = try optionalIso(ao, "from"),
            .until_ms = try optionalIso(ao, "until"),
        };
    }
    panel.actions = actions;
    return panel;
}

fn optionalIso(o: std.json.ObjectMap, key: []const u8) Error!?i64 {
    const s = try optionalStr(o, key) orelse return null;
    return parseIso(s) catch error.InvalidTimeline;
}

/// `[{ id, label }]` or null (v2 `bubbleActions`), at most three.
fn parseEntryActions(a: std.mem.Allocator, value: ?std.json.Value) Error![]const protocol.Action {
    const raw = switch (value orelse return &.{}) {
        .null => return &.{},
        .array => |arr| arr.items,
        else => return error.InvalidTimeline,
    };
    if (raw.len > protocol.max_bubble_actions) return error.InvalidTimeline;
    const out = try a.alloc(protocol.Action, raw.len);
    for (raw, out) |item, *action| {
        const o = object(item) orelse return error.InvalidTimeline;
        const id = str(o, "id") orelse return error.InvalidTimeline;
        if (!protocol.actionIdOk(id)) return error.InvalidTimeline;
        const label = str(o, "label") orelse return error.InvalidTimeline;
        if (label.len == 0) return error.InvalidTimeline;
        action.* = .{ .id = try a.dupe(u8, id), .label = try a.dupe(u8, clipUtf8(label, protocol.max_action_label_bytes)) };
    }
    return out;
}

/// v2 `bubbleKind`: a BUBBLE_KINDS name (`[a-z-]`, ≤ 24 bytes) or null.
pub fn bubbleKindOk(kind: []const u8) bool {
    if (kind.len == 0 or kind.len > max_bubble_kind_bytes) return false;
    for (kind) |c| if (!((c >= 'a' and c <= 'z') or c == '-')) return false;
    return true;
}

fn parseSprite(a: std.mem.Allocator, value: ?std.json.Value, user_data_dir: []const u8) Error!?protocol.Sprite {
    const o = switch (value orelse return null) {
        .null => return null,
        .object => |o| o,
        else => return error.InvalidTimeline,
    };
    const path = str(o, "path") orelse return error.InvalidTimeline;
    if (path.len > protocol.max_path_bytes) return error.InvalidTimeline;
    if (!pathInside(user_data_dir, path)) return error.PathOutsideUserData;
    const rows = int(o, "rows") orelse return error.InvalidTimeline;
    if (rows != 9 and rows != 11) return error.InvalidTimeline;
    const scale = num(o, "scale") orelse return error.InvalidTimeline;
    if (!(scale > 0 and scale <= 8)) return error.InvalidTimeline;
    return .{ .path = try a.dupe(u8, path), .rows = @intCast(rows), .scale = @floatCast(scale) };
}

fn parseEntry(a: std.mem.Allocator, raw: std.json.Value) Error!Entry {
    const o = object(raw) orelse return error.InvalidTimeline;
    const at_ms = try isoField(o, "at");
    const visible = boolean(o, "visible") orelse return error.InvalidTimeline;
    if (!visible) return .{ .at_ms = at_ms, .visible = false };

    const state = std.meta.stringToEnum(protocol.State, str(o, "state") orelse return error.InvalidTimeline) orelse
        return error.InvalidTimeline;
    const row = int(o, "row") orelse return error.InvalidTimeline;
    const frames = int(o, "frames") orelse return error.InvalidTimeline;
    const duration = int(o, "durationMs") orelse return error.InvalidTimeline;
    if (row < 0 or row > 10 or frames < 1 or frames > 8) return error.InvalidTimeline;
    if (duration < 0 or duration > 60_000) return error.InvalidTimeline;
    const play_key = str(o, "playKey") orelse return error.InvalidTimeline;
    if (play_key.len > max_play_key_bytes) return error.InvalidTimeline;

    const bubble = try optionalStr(o, "bubble");
    const target = try optionalStr(o, "bubbleTarget");
    if (target) |t| if (!protocol.appPathOk(t)) return error.InvalidTimeline;

    var moment: ?Moment = null;
    switch (o.get("moment") orelse std.json.Value.null) {
        .null => {},
        .object => |m| {
            const name = std.meta.stringToEnum(MomentName, str(m, "name") orelse return error.InvalidTimeline) orelse
                return error.InvalidTimeline;
            const value = str(m, "value") orelse return error.InvalidTimeline;
            if (value.len == 0 or value.len > max_moment_value_bytes) return error.InvalidTimeline;
            moment = .{ .name = name, .value = try a.dupe(u8, value) };
        },
        else => return error.InvalidTimeline,
    }

    const bubble_text: ?[]const u8 = if (bubble) |b|
        (if (b.len == 0) null else try a.dupe(u8, clipUtf8(b, protocol.max_text_bytes)))
    else
        null;

    // v2 (strict like the rest: an unknown motion or pose is a skew).
    const motion: ?protocol.Motion = switch (o.get("motion") orelse std.json.Value.null) {
        .null => null,
        .string => |m| std.meta.stringToEnum(protocol.Motion, m) orelse return error.InvalidTimeline,
        else => return error.InvalidTimeline,
    };
    const sleeping = switch (o.get("sleeping") orelse std.json.Value.null) {
        .null => false,
        .bool => |b| b,
        else => return error.InvalidTimeline,
    };
    const actions = try parseEntryActions(a, o.get("bubbleActions"));
    const kind = try optionalStr(o, "bubbleKind");
    if (kind) |k| if (!bubbleKindOk(k)) return error.InvalidTimeline;
    const second_anim: ?protocol.Anim = switch (o.get("secondAnim") orelse std.json.Value.null) {
        .null => null,
        .object => blk: {
            const parsed = protocol.parseAnim(o.get("secondAnim")) catch return error.InvalidTimeline;
            const anim = parsed orelse return error.InvalidTimeline; // unknown pose
            if (anim.play_key.len > max_play_key_bytes) return error.InvalidTimeline;
            break :blk .{
                .state = anim.state,
                .row = anim.row,
                .frames = anim.frames,
                .duration_ms = anim.duration_ms,
                .once = anim.once,
                .still = anim.still,
                .play_key = try a.dupe(u8, anim.play_key),
                .delay_ms = anim.delay_ms,
            };
        },
        else => return error.InvalidTimeline,
    };
    return .{
        .at_ms = at_ms,
        .visible = true,
        .state = state,
        .row = @intCast(row),
        .frames = @intCast(frames),
        .duration_ms = @intCast(duration),
        .once = boolean(o, "once") orelse return error.InvalidTimeline,
        .still = boolean(o, "still") orelse return error.InvalidTimeline,
        .play_key = try a.dupe(u8, play_key),
        .bubble = bubble_text,
        .bubble_target = if (bubble_text != null and target != null) try a.dupe(u8, target.?) else null,
        .duo = boolean(o, "duo") orelse return error.InvalidTimeline,
        .moment = if (bubble_text != null) moment else null,
        .motion = motion,
        .sleeping = sleeping,
        .bubble_actions = if (bubble_text != null) actions else &.{},
        .bubble_kind = if (bubble_text != null and kind != null) try a.dupe(u8, kind.?) else null,
        .second_anim = second_anim,
    };
}

fn sessionText(o: std.json.ObjectMap, key: []const u8) Error![]const u8 {
    const s = str(o, key) orelse return error.InvalidTimeline;
    if (s.len > max_session_text_bytes) return error.InvalidTimeline;
    return s;
}

fn isoField(o: std.json.ObjectMap, key: []const u8) Error!i64 {
    const s = str(o, key) orelse return error.InvalidTimeline;
    return parseIso(s) catch error.InvalidTimeline;
}

// ---------------------------------------------------------------- paths

const windows = builtin.os.tag == .windows;

fn isSep(c: u8) bool {
    return c == '/' or (windows and c == '\\');
}

/// True when `path` names something strictly inside `dir`: same prefix
/// (case-insensitive on Windows) followed by a separator, and no `.` / `..`
/// component or NUL byte anywhere (on Windows also no `:` after the drive,
/// which would name an alternate data stream).
pub fn pathInside(dir: []const u8, path: []const u8) bool {
    var d = dir;
    while (d.len > 1 and isSep(d[d.len - 1])) d = d[0 .. d.len - 1];
    if (d.len == 0 or path.len <= d.len + 1) return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    const prefix_ok = if (windows)
        std.ascii.eqlIgnoreCase(path[0..d.len], d)
    else
        std.mem.eql(u8, path[0..d.len], d);
    if (!prefix_ok) return false;
    // "/" as the dir: the path already starts with the separator.
    const rest = if (isSep(d[d.len - 1])) path[d.len..] else blk: {
        if (!isSep(path[d.len])) return false;
        break :blk path[d.len + 1 ..];
    };
    if (rest.len == 0) return false;
    if (windows and std.mem.indexOfScalarPos(u8, path, 2, ':') != null) return false;
    var it = std.mem.tokenizeAny(u8, rest, if (windows) "/\\" else "/");
    var any = false;
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        any = true;
    }
    return any;
}

// ---------------------------------------------------------------- times

pub const IsoError = error{InvalidTime};

/// Parse an ISO-8601 instant as Electron writes it (`toISOString()`:
/// "2026-11-07T18:00:00.000Z"). Also accepts no seconds, any fraction
/// (truncated to ms) and a ±HH:MM offset. Returns Unix ms.
pub fn parseIso(s: []const u8) IsoError!i64 {
    if (s.len < 17 or s.len > 40) return error.InvalidTime;
    if (s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':') return error.InvalidTime;
    const year = try digits(s[0..4]);
    const month = try digits(s[5..7]);
    const day = try digits(s[8..10]);
    const hour = try digits(s[11..13]);
    const minute = try digits(s[14..16]);
    var i: usize = 16;
    var second: i64 = 0;
    var millis: i64 = 0;
    if (i < s.len and s[i] == ':') {
        if (i + 3 > s.len) return error.InvalidTime;
        second = try digits(s[i + 1 .. i + 3]);
        i += 3;
        if (i < s.len and s[i] == '.') {
            i += 1;
            const start = i;
            while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
            if (i == start) return error.InvalidTime;
            var scale: i64 = 100;
            for (s[start..@min(i, start + 3)]) |c| {
                millis += (c - '0') * scale;
                scale = @divTrunc(scale, 10);
            }
        }
    }
    if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, @intCast(month))) return error.InvalidTime;
    if (hour > 23 or minute > 59 or second > 59) return error.InvalidTime;
    if (i >= s.len) return error.InvalidTime;
    var offset_min: i64 = 0;
    if (s[i] == 'Z') {
        i += 1;
    } else if (s[i] == '+' or s[i] == '-') {
        if (i + 6 != s.len or s[i + 3] != ':') return error.InvalidTime;
        const oh = try digits(s[i + 1 .. i + 3]);
        const om = try digits(s[i + 4 .. i + 6]);
        if (oh > 23 or om > 59) return error.InvalidTime;
        offset_min = (oh * 60 + om) * (if (s[i] == '-') @as(i64, -1) else 1);
        i += 6;
    } else return error.InvalidTime;
    if (i != s.len) return error.InvalidTime;
    const days = daysFromCivil(year, @intCast(month), @intCast(day));
    return ((days * 24 + hour) * 60 + minute - offset_min) * 60_000 + second * 1000 + millis;
}

/// "YYYY-MM-DDTHH:MM:SS.sssZ" (as JS toISOString) for years 0–9999.
pub fn formatIso(buf: *[24]u8, ms: i64) []const u8 {
    const days = @divFloor(ms, 86_400_000);
    const rem = ms - days * 86_400_000;
    const civil = civilFromDays(days);
    const year: u64 = @intCast(std.math.clamp(civil.year, 0, 9999));
    const r: u64 = @intCast(rem);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year,          civil.month,     civil.day,
        r / 3_600_000, r / 60_000 % 60, r / 1000 % 60,
        r % 1000,
    }) catch unreachable;
}

fn digits(s: []const u8) IsoError!i64 {
    var v: i64 = 0;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return error.InvalidTime;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn daysInMonth(year: i64, month: u8) i64 {
    return switch (month) {
        2 => if (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

/// Days since 1970-01-01 (proleptic Gregorian; H. Hinnant's algorithm).
fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = @mod(@as(i64, month) + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

fn civilFromDays(days: i64) struct { year: i64, month: u8, day: u8 } {
    const z = days + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const month: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .year = yoe + era * 400 + @intFromBool(month <= 2), .month = month, .day = day };
}

// -------------------------------------------------------------- helpers

/// Longest prefix of `s` within `max` bytes that ends on a UTF-8 boundary.
fn clipUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

fn object(v: std.json.Value) ?std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

fn array(v: std.json.Value) ?[]const std.json.Value {
    return switch (v) {
        .array => |a| a.items,
        else => null,
    };
}

fn str(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (o.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// A string, null or missing; any other type rejects the document.
fn optionalStr(o: std.json.ObjectMap, key: []const u8) Error!?[]const u8 {
    return switch (o.get(key) orelse return null) {
        .string => |s| s,
        .null => null,
        else => error.InvalidTimeline,
    };
}

fn boolean(o: std.json.ObjectMap, key: []const u8) ?bool {
    return switch (o.get(key) orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

fn int(o: std.json.ObjectMap, key: []const u8) ?i64 {
    return switch (o.get(key) orelse return null) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f) and @floor(f) == f and @abs(f) < 1e15) @intFromFloat(f) else null,
        else => null,
    };
}

fn num(o: std.json.ObjectMap, key: []const u8) ?f64 {
    return switch (o.get(key) orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |f| if (std.math.isFinite(f)) f else null,
        else => null,
    };
}

// ---------------------------------------------------------------- tests

/// userData the desktop fixture emitter resolves sprite paths under (tests).
pub const fixture_user_data = "/tmp/ti-pet-fixture/ud";

/// Read `tests/fixtures/<name>` (tests run from packages/ti-pet).
pub fn readFixture(a: std.mem.Allocator, name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(a, "tests/fixtures/{s}", .{name});
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(max_file_bytes));
}

const testing = std.testing;

fn at(s: []const u8) i64 {
    return parseIso(s) catch unreachable;
}

test "parseIso / formatIso round trip and JS edge cases" {
    try testing.expectEqual(@as(i64, 0), try parseIso("1970-01-01T00:00:00.000Z"));
    try testing.expectEqual(@as(i64, 1795233600000), try parseIso("2026-11-21T04:00:00.000Z"));
    try testing.expectEqual(@as(i64, 1795233600000), try parseIso("2026-11-21T04:00:00Z"));
    try testing.expectEqual(@as(i64, 1795233600000), try parseIso("2026-11-21T04:00Z"));
    try testing.expectEqual(@as(i64, 1795233600000), try parseIso("2026-11-21T09:30:00+05:30"));
    try testing.expectEqual(@as(i64, 1795233600123), try parseIso("2026-11-21T04:00:00.1234567Z"));
    try testing.expectEqual(@as(i64, 1795233600100), try parseIso("2026-11-21T04:00:00.1Z"));
    try testing.expectEqual(@as(i64, 951782400000), try parseIso("2000-02-29T00:00:00Z"));
    for ([_][]const u8{
        "",                         "2026-11-21",                 "2026-11-21T04:00:00",
        "2026-13-01T00:00:00Z",     "2026-02-29T00:00:00Z",       "2026-11-21T24:00:00Z",
        "2026-11-21T04:00:00.Z",    "2026-11-21T04:00:00ZZ",      "2026-11-21 04:00:00Z",
        "2026-11-21T04:00:00+0530", "+02026-11-21T04:00:00.000Z",
    }) |bad| {
        try testing.expectError(error.InvalidTime, parseIso(bad));
    }
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("2026-11-07T18:00:00.000Z", formatIso(&buf, at("2026-11-07T18:00:00Z")));
    try testing.expectEqualStrings("1970-01-01T00:00:00.001Z", formatIso(&buf, 1));
    try testing.expectEqualStrings("2000-02-29T23:59:59.999Z", formatIso(&buf, at("2000-03-01T00:00:00Z") - 1));
    // Every day for a few years survives a round trip.
    var t: i64 = at("2023-12-25T13:14:15.678Z");
    while (t < at("2029-01-03T00:00:00Z")) : (t += 86_400_000 + 1) {
        try testing.expectEqual(t, try parseIso(formatIso(&buf, t)));
    }
}

test "pathInside" {
    const ud = "/home/u/.config/TracingInsights";
    try testing.expect(pathInside(ud, ud ++ "/pets/a/spritesheet.webp"));
    try testing.expect(pathInside(ud ++ "/", ud ++ "/pet-timeline.json"));
    try testing.expect(!pathInside(ud, ud));
    try testing.expect(!pathInside(ud, ud ++ "/"));
    try testing.expect(!pathInside(ud, ud ++ "x/pets/a.webp"));
    try testing.expect(!pathInside(ud, ud ++ "/../x.webp"));
    try testing.expect(!pathInside(ud, ud ++ "/pets/../../x.webp"));
    try testing.expect(!pathInside(ud, ud ++ "/./x.webp"));
    try testing.expect(!pathInside(ud, "/etc/passwd"));
    try testing.expect(!pathInside(ud, ud ++ "/a\x00b"));
    try testing.expect(!pathInside("", "/x"));
}

test "weekend fixture: header, sprites, entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try readFixture(arena.allocator(), "timeline-weekend.json");
    var tl = try parse(testing.allocator, bytes, fixture_user_data);
    defer tl.deinit();

    try testing.expectEqual(at("2026-11-07T12:00:00Z"), tl.generated_at_ms);
    try testing.expectEqual(at("2026-11-14T12:00:00Z"), tl.until_ms);
    try testing.expectEqual(at("2026-11-08T09:00:00Z"), tl.refresh_at_ms);
    try testing.expectEqual(protocol.Size.m, tl.size);
    try testing.expectEqual(SessionReactions.calm, tl.session_reactions);
    try testing.expectEqualStrings(fixture_user_data ++ "/pets/petdex-max-4/spritesheet.webp", tl.pets.first.?.path);
    try testing.expectEqual(@as(u8, 9), tl.pets.second.?.rows);
    try testing.expect(tl.entries.len > 20);
    try testing.expectEqual(@as(usize, 2), tl.sessions.len);
    try testing.expectEqualStrings("Qualifying", tl.sessions[0].label);
    try testing.expectEqualStrings("S\u{e3}o Paulo GP", tl.sessions[0].gp);
    try testing.expect(std.mem.startsWith(u8, tl.duo.?.target, "/stats/compare/drivers?"));
    try testing.expect(tl.countdown_v1);

    // The daily fact shows at generation time, as a moment.
    const first = tl.entryAt(tl.generated_at_ms).?;
    try testing.expect(first.visible and first.duo);
    try testing.expectEqualStrings("On this day \u{b7} 2026-11-07", first.bubble.?);
    try testing.expectEqualStrings("/stats/on-this-day/2026-11-07", first.bubble_target.?);
    try testing.expectEqual(MomentName.lastFactDay, first.moment.?.name);
    try testing.expectEqualStrings("2026-11-07", first.moment.?.value);
    // 15 s later the bubble is gone.
    try testing.expect(tl.entryAt(at("2026-11-07T12:00:15Z")).?.bubble == null);

    // Lights out holds the jump, then waiting with the bubble.
    const lights = tl.entryAt(at("2026-11-08T17:00:00.500Z")).?;
    try testing.expectEqual(protocol.State.jumping, lights.state);
    try testing.expect(lights.once);
    try testing.expectEqualStrings("calendar:2026_20_race:live", lights.play_key);
    try testing.expectEqualStrings("Lights out! \u{b7} S\u{e3}o Paulo GP", lights.bubble.?);
    try testing.expectEqual(at("2026-11-08T17:00:00.840Z"), tl.nextChangeAt(at("2026-11-08T17:00:00.500Z")).?);

    // The rate nudge is a moment with its own target.
    const rate = tl.entryAt(at("2026-11-08T20:00:01Z")).?;
    try testing.expectEqual(MomentName.lastRateKey, rate.moment.?.name);
    try testing.expectEqualStrings("/rate/2026/sao-paulo/race", rate.bubble_target.?);

    // render() mirrors a live render message.
    const r = lights.render(&tl).?;
    try testing.expectEqual(@as(u8, 4), r.row);
    try testing.expect(r.second != null);
    try testing.expectEqualStrings(tl.pets.first.?.path, r.atlas.path);

    // Before the first entry (clock moved back): the first; past the end: the last.
    try testing.expectEqual(tl.entries[0].at_ms, tl.entryAt(0).?.at_ms);
    try testing.expectEqual(tl.entries[tl.entries.len - 1].at_ms, tl.entryAt(at("2027-01-01T00:00:00Z")).?.at_ms);
    try testing.expect(tl.nextChangeAt(at("2027-01-01T00:00:00Z")) == null);
    try testing.expect(!tl.refreshDue(at("2026-11-08T08:59:59Z")));
    try testing.expect(tl.refreshDue(at("2026-11-08T09:00:00Z")));
}

test "quiet overlay: native quiet wins, no bubble, no moment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try readFixture(arena.allocator(), "timeline-weekend.json");
    var tl = try parse(testing.allocator, bytes, fixture_user_data);
    defer tl.deinit();

    const lights_at = at("2026-11-08T17:00:00.500Z");
    tl.setQuietUntil(at("2026-11-08T19:00:00Z"));
    const quiet = tl.entryAt(lights_at).?;
    try testing.expectEqual(protocol.State.idle, quiet.state);
    try testing.expectEqual(@as(u8, 0), quiet.row);
    try testing.expectEqual(@as(u8, 6), quiet.frames);
    try testing.expect(!quiet.once and quiet.bubble == null and quiet.bubble_target == null and quiet.moment == null);
    try testing.expectEqualStrings("idle", quiet.play_key);
    try testing.expect(quiet.duo);
    // Quiet ending is a change point; afterwards the compiled entry is back.
    try testing.expectEqual(at("2026-11-08T17:00:00.840Z"), tl.nextChangeAt(lights_at).?);
    try testing.expectEqual(at("2026-11-08T19:00:00Z"), tl.nextChangeAt(at("2026-11-08T18:00:00Z")).?);
    try testing.expect(tl.entryAt(at("2026-11-08T20:00:01Z")).?.moment != null);
    // No hover bubble while quiet.
    var buf: [countdown.max_text_bytes]u8 = undefined;
    try testing.expect(tl.hover(&buf, lights_at, true) == null);
    // Quiet off: the compiled entry again.
    tl.setQuietUntil(null);
    try testing.expectEqual(protocol.State.jumping, tl.entryAt(lights_at).?.state);
}

test "quiet compiled into the file; native 'off' overrides it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try readFixture(arena.allocator(), "timeline-quiet.json");
    var tl = try parse(testing.allocator, bytes, fixture_user_data);
    defer tl.deinit();
    const lead = at("2026-11-07T17:45:00Z");
    try testing.expect(tl.isQuiet(lead));
    try testing.expect(tl.entryAt(lead).?.bubble == null);
    try testing.expect(!tl.isQuiet(at("2026-11-07T19:30:00Z")));
    tl.setQuietUntil(null);
    try testing.expect(!tl.isQuiet(lead));
}

test "sessionQuietEnd: live session, else the one in its lead-in" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try readFixture(arena.allocator(), "timeline-weekend.json");
    var tl = try parse(testing.allocator, bytes, fixture_user_data);
    defer tl.deinit();
    const quali_end = at("2026-11-07T19:00:00Z");
    try testing.expect(tl.sessionQuietEnd(at("2026-11-07T17:29:59Z")) == null);
    try testing.expectEqual(quali_end, tl.sessionQuietEnd(at("2026-11-07T17:30:00Z")).?);
    try testing.expectEqual(quali_end, tl.sessionQuietEnd(at("2026-11-07T18:30:00Z")).?);
    try testing.expect(tl.sessionQuietEnd(quali_end) == null);
    try testing.expectEqual(at("2026-11-08T19:00:00Z"), tl.sessionQuietEnd(at("2026-11-08T16:45:00Z")).?);
}

test "hover: duo line while both show, else the countdown" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try readFixture(arena.allocator(), "timeline-weekend.json");
    var tl = try parse(testing.allocator, bytes, fixture_user_data);
    defer tl.deinit();
    var buf: [countdown.max_text_bytes]u8 = undefined;
    const t = at("2026-11-07T15:46:00Z");
    const duo = tl.hover(&buf, t, true).?;
    try testing.expectEqualStrings(tl.duo.?.text, duo.text);
    const solo = tl.hover(&buf, t, false).?;
    try testing.expectEqualStrings("Qualifying in 2 h 14 min \u{b7} S\u{e3}o Paulo GP", solo.text);
    try testing.expectEqualStrings("/", solo.target);
    tl.session_reactions = .off;
    try testing.expect(tl.hover(&buf, t, false) == null);
}

test "rejects: version, times, order, paths, poses, size" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try readFixture(a, "timeline-weekend.json");

    const Case = struct { find: []const u8, replace: []const u8, err: Error };
    const cases = [_]Case{
        .{ .find = "\"v\": 1,", .replace = "\"v\": 3,", .err = error.UnsupportedVersion },
        .{ .find = "\"v\": 1,", .replace = "\"v\": 0,", .err = error.UnsupportedVersion },
        .{ .find = "\"until\": \"2026-11-14T12:00:00.000Z\"", .replace = "\"until\": \"next week\"", .err = error.InvalidTimeline },
        .{ .find = "\"until\": \"2026-11-14T12:00:00.000Z\"", .replace = "\"until\": \"2026-11-07T11:00:00.000Z\"", .err = error.InvalidTimeline },
        .{ .find = "\"at\": \"2026-11-07T12:10:00.000Z\"", .replace = "\"at\": \"2026-11-07T11:10:00.000Z\"", .err = error.InvalidTimeline },
        .{ .find = "\"/tmp/ti-pet-fixture/ud/pets/petdex-lando", .replace = "\"/tmp/elsewhere/pets/petdex-lando", .err = error.PathOutsideUserData },
        .{ .find = "\"/tmp/ti-pet-fixture/ud/pets/petdex-max-4", .replace = "\"/tmp/ti-pet-fixture/ud/../pets/petdex-max-4", .err = error.PathOutsideUserData },
        .{ .find = "\"state\": \"waiting\"", .replace = "\"state\": \"dancing\"", .err = error.InvalidTimeline },
        .{ .find = "\"frames\": 6", .replace = "\"frames\": 9", .err = error.InvalidTimeline },
        .{ .find = "\"bubbleTarget\": \"/\"", .replace = "\"bubbleTarget\": \"//evil.example\"", .err = error.InvalidTimeline },
        .{ .find = "\"name\": \"lastFactDay\"", .replace = "\"name\": \"lastSomething\"", .err = error.InvalidTimeline },
        .{ .find = "\"sessionReactions\": \"calm\"", .replace = "\"sessionReactions\": \"loud\"", .err = error.InvalidTimeline },
        .{ .find = "\"size\": \"m\"", .replace = "\"size\": \"xl\"", .err = error.InvalidTimeline },
        .{ .find = "\"second\": {", .replace = "\"second\": null, \"x\": {", .err = error.InvalidTimeline },
        .{ .find = "\"v\": 1,", .replace = "\"v\": 1, \"v\": 1,", .err = error.InvalidTimeline },
    };
    for (cases) |c| {
        const idx = std.mem.indexOf(u8, good, c.find) orelse return error.TestFixtureChanged;
        const bad = try std.mem.concat(a, u8, &.{ good[0..idx], c.replace, good[idx + c.find.len ..] });
        try testing.expectError(c.err, parse(testing.allocator, bad, fixture_user_data));
    }
    try testing.expectError(error.InvalidTimeline, parse(testing.allocator, "[]", fixture_user_data));
    try testing.expectError(error.InvalidTimeline, parse(testing.allocator, "{\"v\":1", fixture_user_data));

    // Over 1 MB: rejected before parsing.
    const big = try a.alloc(u8, max_file_bytes + 1);
    @memset(big, ' ');
    try testing.expectError(error.TooLarge, parse(testing.allocator, big, fixture_user_data));
    // Unknown keys are fine.
    const extra = try std.mem.concat(a, u8, &.{ "{\"future\": [1, 2],", good[1..] });
    var tl = try parse(testing.allocator, extra, fixture_user_data);
    tl.deinit();
}

test "v2 fixture: motion, sleep, look rows, bubble buttons, greeting moment, duo reaction, panel" {
    // tests/fixtures/timeline-v2.json is emitted by the desktop side
    // (emit-native-fixtures.mjs): the São Paulo weekend for a round-3 pet.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try readFixture(arena.allocator(), "timeline-v2.json");
    var tl = try parse(testing.allocator, bytes, fixture_user_data);
    defer tl.deinit();
    try testing.expectEqual(@as(u8, 11), tl.pets.first.?.rows);
    try testing.expectEqual(@as(u8, 9), tl.pets.second.?.rows);

    // The daily fact at hand-off, with its three buttons.
    const fact = tl.entryAt(at("2026-11-07T12:00:01Z")).?;
    try testing.expectEqualStrings("fact", fact.bubble_kind.?);
    try testing.expectEqual(MomentName.lastFactDay, fact.moment.?.name);
    try testing.expectEqual(@as(usize, 3), fact.bubble_actions.len);
    try testing.expectEqualStrings("ok", fact.bubble_actions[0].id);
    try testing.expectEqualStrings("mute", fact.bubble_actions[2].id);
    try testing.expectEqualStrings("No daily facts", fact.bubble_actions[2].label);
    try testing.expect(fact.motion == null);
    // render() carries the v2 fields like a live payload.
    try testing.expectEqual(@as(usize, 3), fact.render(&tl).?.bubble_actions.len);

    // Then it roams; no bubble, no buttons, no kind.
    const roam = tl.entryAt(at("2026-11-07T12:01:00Z")).?;
    try testing.expectEqual(protocol.Motion.roam, roam.motion.?);
    try testing.expect(!roam.sleeping and roam.bubble_actions.len == 0 and roam.bubble_kind == null);

    // A look on the 11-row pet; its 9-row partner plays idle (its own anim).
    const look = tl.entryAt(at("2026-11-07T12:04:00.500Z")).?;
    try testing.expectEqual(protocol.State.@"look-a", look.state);
    try testing.expectEqual(@as(u8, 9), look.row);
    try testing.expectEqual(protocol.State.idle, look.second_anim.?.state);
    try testing.expectEqual(@as(u8, 0), look.second_anim.?.row);
    const look_b = tl.entryAt(at("2026-11-07T12:08:00.500Z")).?;
    try testing.expectEqual(@as(u8, 10), look_b.row);

    // The duo waves: the partner answers 700 ms later.
    const wave = tl.entryAt(at("2026-11-07T12:05:00.300Z")).?;
    try testing.expectEqual(protocol.State.waving, wave.state);
    try testing.expectEqual(protocol.State.waving, wave.second_anim.?.state);
    try testing.expectEqual(@as(u32, 700), wave.second_anim.?.delay_ms);
    try testing.expect(wave.second_anim.?.once);
    try testing.expectEqualStrings("duo-wave:1794053100000:second", wave.second_anim.?.play_key);

    // Asleep 30 min after hand-off: still idle, no walk.
    const asleep = tl.entryAt(at("2026-11-07T13:00:00Z")).?;
    try testing.expect(asleep.sleeping and asleep.still and asleep.motion == null);
    try testing.expectEqual(protocol.State.idle, asleep.state);

    // The evening greeting keeps its marker and its "No greetings" button.
    const greeting = tl.entryAt(at("2026-11-07T17:00:01Z")).?;
    try testing.expectEqual(MomentName.lastGreetingKey, greeting.moment.?.name);
    try testing.expectEqualStrings("2026-11-07:evening", greeting.moment.?.value);
    try testing.expectEqualStrings("greeting", greeting.bubble_kind.?);
    try testing.expectEqualStrings("No greetings", greeting.bubble_actions[2].label);
    try testing.expect(!greeting.sleeping);

    // Qualifying starts: jump, then the dash under the bubble.
    const jump = tl.entryAt(at("2026-11-07T18:00:00.500Z")).?;
    try testing.expectEqual(protocol.State.jumping, jump.state);
    try testing.expect(jump.motion == null);
    const dash = tl.entryAt(at("2026-11-07T18:00:01Z")).?;
    try testing.expectEqual(protocol.Motion.dash, dash.motion.?);
    try testing.expectEqualStrings("calendar", dash.bubble_kind.?);
    try testing.expectEqualStrings("quiet-session", dash.bubble_actions[1].id);
    try testing.expectEqualStrings("No session alerts", dash.bubble_actions[2].label);

    // Quiet: no walk, no buttons, no duo reaction (sleep stays).
    tl.setQuietUntil(at("2026-11-07T23:00:00Z"));
    const quiet = tl.entryAt(at("2026-11-07T18:00:01Z")).?;
    try testing.expect(quiet.motion == null and quiet.bubble_actions.len == 0 and quiet.bubble_kind == null);
    try testing.expect(tl.entryAt(at("2026-11-07T12:05:00.300Z")).?.second_anim == null);
    try testing.expect(tl.entryAt(at("2026-11-07T13:00:00Z")).?.sleeping);
    tl.setQuietUntil(null);
    try testing.expect(tl.entryAt(at("2026-11-07T12:05:00.300Z")).?.second_anim != null);

    // The static panel: the countdown on top is computed here, then the
    // compiled line; the rate button only inside the race's window.
    const panel = tl.panel.?;
    try testing.expect(panel.countdown);
    try testing.expectEqual(@as(usize, 1), panel.lines.len);
    try testing.expectEqualStrings("Lando Norris won the Mexico City GP", panel.lines[0]);
    try testing.expectEqual(@as(usize, 5), panel.actions.len);
    try testing.expectEqualStrings("/desktop/ask", panel.actions[0].target.?);
    try testing.expectEqualStrings("/settings/pets", panel.actions[4].target.?);
    var buf: [countdown.max_text_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        "Qualifying in 2 h 14 min \u{b7} S\u{e3}o Paulo GP",
        tl.panelCountdown(&buf, at("2026-11-07T15:46:00Z")).?,
    );
    const rate = panel.actions[1];
    try testing.expectEqualStrings("rate", rate.id);
    try testing.expectEqualStrings("/rate/2026/sao-paulo/race", rate.target.?);
    try testing.expect(!rate.shownAt(at("2026-11-08T19:59:59Z")));
    try testing.expect(rate.shownAt(at("2026-11-08T20:00:00Z")));
    try testing.expect(!rate.shownAt(at("2026-11-10T19:00:00Z")));
    try testing.expect(panel.actions[0].shownAt(at("2030-01-01T00:00:00Z")));
}

test "v1 documents still play: no panel, nothing new on entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try readFixture(arena.allocator(), "timeline-weekend.json");
    var tl = try parse(testing.allocator, bytes, fixture_user_data);
    defer tl.deinit();
    try testing.expect(tl.panel == null);
    var buf: [countdown.max_text_bytes]u8 = undefined;
    try testing.expect(tl.panelCountdown(&buf, at("2026-11-07T15:46:00Z")) == null);
    for (tl.entries) |e| {
        try testing.expect(e.motion == null and !e.sleeping and e.bubble_actions.len == 0);
        try testing.expect(e.bubble_kind == null and e.second_anim == null);
    }
}

test "v2 rejects: unknown motion / pose, bad buttons, bad panel" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try readFixture(a, "timeline-v2.json");
    // Each case edits the first occurrence of `find` in the emitted file.
    const Case = struct { find: []const u8, replace: []const u8 };
    const cases = [_]Case{
        .{ .find = "\"motion\": \"roam\"", .replace = "\"motion\": \"fly\"" },
        .{ .find = "\"motion\": \"dash\"", .replace = "\"motion\": true" },
        .{ .find = "\"sleeping\": true", .replace = "\"sleeping\": \"yes\"" },
        .{ .find = "\"state\": \"look-a\"", .replace = "\"state\": \"look-c\"" },
        // A fourth button.
        .{ .find = "\"bubbleActions\": [\n        {", .replace = "\"bubbleActions\": [\n        { \"id\": \"x\", \"label\": \"x\" },\n        {" },
        .{ .find = "\"id\": \"ok\"", .replace = "\"id\": \"OK\"" },
        .{ .find = "\"label\": \"OK\"", .replace = "\"label\": \"\"" },
        .{ .find = "\"bubbleKind\": \"fact\"", .replace = "\"bubbleKind\": \"Fact!\"" },
        .{ .find = "\"state\": \"waving\",\n        \"row\": 3", .replace = "\"state\": \"dancing\",\n        \"row\": 3" },
        .{ .find = "\"delayMs\": 700", .replace = "\"delayMs\": -1" },
        .{ .find = "\"target\": \"/desktop/ask\"", .replace = "\"target\": \"//evil.example\"" },
        .{ .find = "\"until\": \"2026-11-10T19:00:00.000Z\"", .replace = "\"until\": \"tomorrow\"" },
        .{ .find = "\"lines\": [\n      \"Lando Norris won the Mexico City GP\"\n    ]", .replace = "\"lines\": [\"a\", \"b\", \"c\", \"d\"]" },
        .{ .find = "\"countdown\": true", .replace = "\"countdown\": 1" },
        .{ .find = "\"name\": \"lastGreetingKey\"", .replace = "\"name\": \"lastHelloKey\"" },
    };
    for (cases) |c| {
        const idx = std.mem.indexOf(u8, good, c.find) orelse {
            std.debug.print("fixture text not found: {s}\n", .{c.find});
            return error.TestFixtureChanged;
        };
        const bad = try std.mem.concat(a, u8, &.{ good[0..idx], c.replace, good[idx + c.find.len ..] });
        if (parse(testing.allocator, bad, fixture_user_data)) |accepted| {
            var tl = accepted;
            tl.deinit();
            std.debug.print("accepted: {s} -> {s}\n", .{ c.find, c.replace });
            return error.TestExpectedError;
        } else |err| try testing.expectEqual(error.InvalidTimeline, err);
    }
    // A v1 reader's version gate is what keeps v2 away from an older pet.
    const v3 = try std.mem.replaceOwned(u8, a, good, "\"v\": 2,", "\"v\": 3,");
    try testing.expectError(error.UnsupportedVersion, parse(testing.allocator, v3, fixture_user_data));
}

test "v2 fixture never crashes when truncated or bit-flipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try readFixture(a, "timeline-v2.json");
    var len: usize = 0;
    while (len < good.len) : (len += 29) {
        if (parse(testing.allocator, good[0..len], fixture_user_data)) |tl| {
            var t = tl;
            t.deinit();
        } else |_| {}
    }
    var prng = std.Random.DefaultPrng.init(0x7632);
    const copy = try a.dupe(u8, good);
    var round: usize = 0;
    while (round < 300) : (round += 1) {
        @memcpy(copy, good);
        const at_byte = prng.random().uintLessThan(usize, copy.len);
        copy[at_byte] ^= @as(u8, 1) << prng.random().int(u3);
        if (parse(testing.allocator, copy, fixture_user_data)) |tl| {
            var t = tl;
            t.deinit();
        } else |_| {}
    }
}

test "load: file inside --user-data only" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    // Re-root the fixture's sprite paths at this temp dir, JSON-escaped:
    // a Windows temp path carries backslashes.
    const good = try readFixture(a, "timeline-weekend.json");
    const dir_json = try std.mem.replaceOwned(u8, a, dir, "\\", "\\\\");
    const moved = try std.mem.replaceOwned(u8, a, good, fixture_user_data, dir_json);
    try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = moved });
    const path = try std.fs.path.join(a, &.{ dir, file_name });

    var tl = try load(testing.allocator, io, path, dir);
    defer tl.deinit();
    try testing.expect(tl.entries.len > 20);
    try testing.expectError(error.PathOutsideUserData, load(testing.allocator, io, path, "/somewhere/else"));
    try testing.expectError(error.ReadFailed, load(testing.allocator, io, try std.fs.path.join(a, &.{ dir, "missing.json" }), dir));
}

test "truncated and bit-flipped documents never crash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try readFixture(a, "timeline-weekend.json");
    var len: usize = 0;
    while (len < good.len) : (len += 41) {
        if (parse(testing.allocator, good[0..len], fixture_user_data)) |tl| {
            var t = tl;
            t.deinit();
        } else |_| {}
    }
    var prng = std.Random.DefaultPrng.init(0x7469_7065_74);
    const copy = try a.dupe(u8, good);
    var round: usize = 0;
    while (round < 300) : (round += 1) {
        @memcpy(copy, good);
        const at_byte = prng.random().uintLessThan(usize, copy.len);
        copy[at_byte] ^= @as(u8, 1) << prng.random().int(u3);
        if (parse(testing.allocator, copy, fixture_user_data)) |tl| {
            var t = tl;
            t.deinit();
        } else |_| {}
    }
}
