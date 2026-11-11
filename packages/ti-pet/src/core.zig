//! The seam between main.zig (tp-ui lane) and the pure modules of the
//! tp-core lane: timeline.zig, state.zig, launch.zig, countdown.zig.
//!
//! main.zig only ever calls the names below; the bodies forward to the
//! tp-core modules (wired by tp-core 2026-11-06).

const std = @import("std");
const protocol = @import("protocol.zig");
const sprite = @import("sprite.zig");
const timeline = @import("timeline.zig");
const countdown = @import("countdown.zig");
const state = @import("state.zig");
const launch = @import("launch.zig");

const log = std.log.scoped(.ti_pet);

/// One Io for the loop thread's file work (state file, timeline) and clock.
var loop_threaded: ?std.Io.Threaded = null;

fn loopIo() std.Io {
    if (loop_threaded == null) loop_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    return loop_threaded.?.io();
}

fn nowMs() i64 {
    return std.Io.Clock.real.now(loopIo()).toMilliseconds();
}

pub const AppLaunch = struct {
    app: ?[]const u8,
    app_args: []const []const u8,
    env: ?*const std.process.Environ.Map,
};

// ------------------------------------------------------------- timeline

pub const Moment = struct {
    name: []const u8,
    value: []const u8,
};

pub const Entry = struct {
    visible: bool = true,
    state: protocol.State = .idle,
    row: u8 = 0,
    frames: u8 = 6,
    duration_ms: u32 = 1100,
    once: bool = false,
    still: bool = false,
    play_key: []const u8 = "",
    bubble: ?[]const u8 = null,
    bubble_target: ?[]const u8 = null,
    duo: bool = false,
    moment: ?Moment = null,
    // timeline v2
    motion: ?protocol.Motion = null,
    sleeping: bool = false,
    bubble_actions: []const protocol.Action = &.{},
    bubble_kind: ?[]const u8 = null,
    second_anim: ?protocol.Anim = null,
};

pub const Panel = timeline.Panel;
pub const PanelAction = timeline.PanelAction;

pub const TimelineSprite = struct {
    path: []const u8,
    rows: u8,
};

pub const Hit = struct { index: usize, entry: Entry };

pub const Timeline = struct {
    first: ?TimelineSprite = null,
    second: ?TimelineSprite = null,
    size: protocol.Size = .m,
    quiet_until_ms: i64 = 0,
    refresh_at_ms: i64 = 0,
    duo_text: ?[]const u8 = null,
    calendar_target: []const u8 = "/",
    /// The validated document (timeline.zig); owns every slice above.
    inner: ?*timeline.Timeline = null,
    gpa: std.mem.Allocator = std.heap.page_allocator,

    /// Parse + validate pet-timeline.json v1. Sprite paths must lie inside
    /// the file's own directory (= userData); prefer `loadInside`.
    pub fn load(gpa: std.mem.Allocator, path: []const u8) !Timeline {
        return loadInside(gpa, path, null);
    }

    /// As `load`, with the file and every sprite path required to lie
    /// inside `user_data` (`--user-data`) when given.
    pub fn loadInside(gpa: std.mem.Allocator, path: []const u8, user_data: ?[]const u8) !Timeline {
        const root = user_data orelse (std.fs.path.dirname(path) orelse return error.PathOutsideUserData);
        const inner = try gpa.create(timeline.Timeline);
        errdefer gpa.destroy(inner);
        inner.* = timeline.load(gpa, loopIo(), path, root) catch |err| {
            log.warn("timeline {s} rejected: {t}", .{ path, err });
            return err;
        };
        const sp = struct {
            fn of(s: ?protocol.Sprite) ?TimelineSprite {
                const x = s orelse return null;
                return .{ .path = x.path, .rows = x.rows };
            }
        };
        return .{
            .first = sp.of(inner.pets.first),
            .second = sp.of(inner.pets.second),
            .size = inner.size,
            .quiet_until_ms = inner.quiet_until_ms orelse 0,
            .refresh_at_ms = inner.refresh_at_ms,
            .duo_text = if (inner.duo) |d| d.text else null,
            .calendar_target = inner.calendar_target,
            .inner = inner,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Timeline) void {
        if (self.inner) |inner| {
            inner.deinit();
            self.gpa.destroy(inner);
        }
        self.* = .{};
    }

    /// The compiled entry holding at `now_ms` (entries hold until the
    /// next), with its index. Quiet is not applied here (main.zig does).
    pub fn entryAt(self: *const Timeline, now_ms: i64) ?Hit {
        const inner = self.inner orelse return null;
        const index = inner.indexAt(now_ms) orelse return null;
        const e = inner.entries[index];
        return .{ .index = index, .entry = .{
            .visible = e.visible,
            .state = e.state,
            .row = e.row,
            .frames = e.frames,
            .duration_ms = e.duration_ms,
            .once = e.once,
            .still = e.still,
            .play_key = e.play_key,
            .bubble = e.bubble,
            .bubble_target = e.bubble_target,
            .duo = e.duo,
            .moment = if (e.moment) |m| .{ .name = @tagName(m.name), .value = m.value } else null,
            .motion = e.motion,
            .sleeping = e.sleeping,
            .bubble_actions = e.bubble_actions,
            .bubble_kind = e.bubble_kind,
            .second_anim = e.second_anim,
        } };
    }

    /// The click panel compiled into the file (v2), or null.
    pub fn panel(self: *const Timeline) ?Panel {
        const inner = self.inner orelse return null;
        return inner.panel;
    }

    /// The panel's countdown line at `now_ms` (into `buf`), or null.
    pub fn panelCountdown(self: *const Timeline, buf: []u8, now_ms: i64) ?[]const u8 {
        const inner = self.inner orelse return null;
        return inner.panelCountdown(buf, now_ms);
    }

    /// A calendar `mute` offline: no hover countdown either (as
    /// sessionReactions 'off' does in the app).
    pub fn muteSessionReactions(self: *Timeline) void {
        if (self.inner) |inner| inner.session_reactions = .off;
    }

    /// End of the session "Quiet until this session ends" covers: the one
    /// live at `now_ms`, else one starting within 30 min (the desktop
    /// controller's rule); null otherwise.
    pub fn sessionEndAfter(self: *const Timeline, now_ms: i64) ?i64 {
        const inner = self.inner orelse return null;
        return inner.sessionQuietEnd(now_ms);
    }
};

/// "<label> in <formatCountdown> · <gp>" / "<label> is live · <gp>" for the
/// next session, written into `buf`; null when session reactions are off.
pub fn hoverText(buf: []u8, tl: *const Timeline, now_ms: i64) ?[]const u8 {
    const inner = tl.inner orelse return null;
    if (inner.session_reactions == .off or !inner.countdown_v1) return null;
    return countdown.hoverText(buf, inner.sessions, now_ms);
}

// ----------------------------------------------------------------- state

pub const max_bubble_kind_bytes = timeline.max_bubble_kind_bytes;
pub const max_mutes = state.max_mutes;

pub const NativeState = struct {
    enabled: ?bool = null,
    size: ?protocol.Size = null,
    /// null = not changed natively, 0 = Quiet switched off.
    quiet_until_ms: ?i64 = null,
    /// Bubble kinds muted while Electron was gone.
    mutes: [state.max_mutes]state.Mute = undefined,
    mutes_len: usize = 0,
};

/// pet-native-state.json as this pet wrote it while Electron was gone
/// (Electron deletes it once merged).
pub fn loadNativeState(user_data: ?[]const u8) ?NativeState {
    const dir = user_data orelse return null;
    const st = state.read(loopIo(), dir);
    var out: NativeState = .{
        .enabled = st.enabled,
        .size = st.size,
        .quiet_until_ms = switch (st.quiet) {
            .unset => null,
            .off => 0,
            .until => |ms| ms,
        },
    };
    for (st.muted()) |m| {
        out.mutes[out.mutes_len] = m;
        out.mutes_len += 1;
    }
    return out;
}

fn saveChange(user_data: ?[]const u8, change: state.Change) void {
    const dir = user_data orelse return;
    _ = state.update(loopIo(), dir, nowMs(), change) catch |err| log.warn("native state: {t}", .{err});
}

/// Append to shownMoments (call only for a moment that was on screen).
pub fn recordMoment(user_data: ?[]const u8, moment: Moment) void {
    const name = std.meta.stringToEnum(state.MomentName, moment.name) orelse return;
    saveChange(user_data, .{ .shown_moment = .{ .name = name, .value = moment.value } });
}

pub fn savePosition(user_data: ?[]const u8, x: f64, y: f64) void {
    saveChange(user_data, .{ .position = .{ .x = x, .y = y } });
}

/// null = Quiet off.
pub fn saveQuiet(user_data: ?[]const u8, until_ms: ?i64) void {
    saveChange(user_data, .{ .quiet_until = until_ms });
}

pub fn saveEnabled(user_data: ?[]const u8, enabled: bool) void {
    saveChange(user_data, .{ .enabled = enabled });
}

pub fn saveSize(user_data: ?[]const u8, size: protocol.Size) void {
    saveChange(user_data, .{ .size = size });
}

/// A bubble kind switched off with a bubble's `mute` button (Electron turns
/// it into the matching setting on its next start).
pub fn saveMute(user_data: ?[]const u8, kind: []const u8) void {
    saveChange(user_data, .{ .mute = kind });
}

/// Electron applies it to the OS login item on its next start.
pub fn saveLaunchAtLogin(user_data: ?[]const u8, enabled: bool) void {
    saveChange(user_data, .{ .launch_at_login = enabled });
}

/// Flip launchAtLogin. Only works once this pet has written a value: the
/// current setting lives in Electron's menu (the item's `checked`), so
/// prefer `saveLaunchAtLogin(user_data, !item.checked)`.
pub fn toggleLaunchAtLogin(user_data: ?[]const u8) void {
    const dir = user_data orelse return;
    const current = state.read(loopIo(), dir).launch_at_login orelse {
        log.warn("launchAtLogin: current value unknown, not toggled", .{});
        return;
    };
    saveLaunchAtLogin(user_data, !current);
}

// ---------------------------------------------------------------- launch

/// Spawn guards live here between calls (launch.zig Launcher).
var launcher: ?launch.Launcher = null;

fn launcherFor(l: AppLaunch) ?*launch.Launcher {
    const app = l.app orelse return null;
    if (launcher == null) launcher = launch.Launcher.init(std.heap.page_allocator, app, l.app_args);
    launcher.?.env = l.env;
    return &launcher.?;
}

fn report(what: []const u8, result: launch.Result) void {
    if (result != .started) log.info("{s}: {t}", .{ what, result });
}

/// `<app> [app args] --pets-open=<path>`, detached.
pub fn openApp(l: AppLaunch, path: []const u8) void {
    const x = launcherFor(l) orelse return;
    report("open", x.openApp(path, nowMs()));
}

/// `<app> [app args] --pets-refresh`. Safe to call on every poll while a
/// refresh is due: one run at a time, backed off after a failed run.
pub fn refreshApp(l: AppLaunch) void {
    const x = launcherFor(l) orelse return;
    report("refresh", x.refreshApp(nowMs()));
}

/// A `handoff` arrived: the refresh run (if any) worked.
pub fn noteHandoff() void {
    if (launcher) |*x| x.noteHandoff();
}

/// `<app> [app args] --pets-install-update`.
pub fn installUpdate(l: AppLaunch) void {
    const x = launcherFor(l) orelse return;
    report("install-update", x.installUpdate(nowMs()));
}

/// `<app> [app args] --hidden` (login start with nothing to draw).
pub fn startHidden(l: AppLaunch) void {
    const x = launcherFor(l) orelse return;
    report("hidden", x.startHidden(nowMs()));
}

/// Reap exited children, run the refresh timeout (poll tick).
pub fn reap() void {
    if (launcher) |*x| x.reap(nowMs());
}

// ------------------------------------------------------------- pet dirs

/// `--pet <dir>` (manual runs and tests): pet.json's spritesheetPath when
/// it names a plain file in the folder, else spritesheet.webp / .png.
pub fn petSheetPath(buf: []u8, dir: []const u8) ?[]const u8 {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var json_buf: [16 * 1024]u8 = undefined;
    var candidates: [3][]const u8 = .{ "", "spritesheet.webp", "spritesheet.png" };
    var path_buf: [protocol.max_path_bytes]u8 = undefined;
    if (std.fmt.bufPrint(&path_buf, "{s}/pet.json", .{dir})) |pj| {
        if (readSmall(io, pj, &json_buf)) |json| {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            if (std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{})) |root| {
                if (root == .object) if (root.object.get("spritesheetPath")) |v| if (v == .string and plainName(v.string)) {
                    const n = @min(v.string.len, 128);
                    @memcpy(path_buf[0..n], v.string[0..n]);
                    candidates[0] = path_buf[0..n];
                };
            } else |_| {}
        }
    } else |_| {}
    for (candidates) |name| {
        if (name.len == 0) continue;
        const full = std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name }) catch continue;
        std.Io.Dir.accessAbsolute(io, full, .{}) catch continue;
        return full;
    }
    return null;
}

fn plainName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return false;
    return !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..");
}

fn readSmall(io: std.Io, path: []const u8, buf: []u8) ?[]const u8 {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    const n = file.readPositionalAll(io, buf, 0) catch return null;
    if (n == 0 or n == buf.len) return null;
    return buf[0..n];
}
