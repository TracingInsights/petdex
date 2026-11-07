//! Starting the TracingInsights desktop app from the native pet.
//!
//! The pet outlives Electron (docs/DESKTOP_PETS_NATIVE_PLAN.md §4.4 in the
//! tif1ai repo) and starts it again for four reasons, each one argv flag
//! that desktop/src/main.mjs understands:
//!
//!   open      `--pets-open=<path>`   Open / Choose pet… / a bubble click
//!   refresh   `--pets-refresh`       recompile the timeline, then exit
//!   install   `--pets-install-update` Restart to update
//!   hidden    `--hidden`             tray-less start (login item fallback)
//!
//! argv = `--app` + every `--app-arg` the pet was started with + the flag.
//! The child is fully detached: its own session (setsid) on POSIX,
//! DETACHED_PROCESS on Windows, stdio on /dev/null, no inherited file
//! descriptor or handle (the pet's socket must never leak into Electron),
//! and `GDK_BACKEND` dropped from its environment (the pet runs on XWayland;
//! Electron picks its own backend).
//!
//! Guards, so a broken app can never turn into a spawn loop:
//! - refresh: one run at a time; a run that has not handed over within
//!   `refresh_timeout_ms` is given up on (not killed: the user may have
//!   turned it into a normal start) and counts as a failure; failures back
//!   off 5 min, 10 min, … up to 6 h; a hand-off resets them.
//! - open / install / hidden: the same request twice within
//!   `repeat_window_ms` starts one app; `crash_limit` starts that died
//!   abnormally within `crash_window_ms` of starting block these starts
//!   for `crash_block_ms`.
//!
//! POSIX needs libc (fork/setsid/execve); the app links it anyway (GTK).
//! Call `reap` from a timer (every second is plenty) to collect exited
//! children and run the refresh timeout.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");

const is_windows = builtin.os.tag == .windows;

comptime {
    if (!is_windows and !builtin.link_libc) @compileError("launch.zig needs libc (zig test -lc)");
}

pub const open_arg_prefix = "--pets-open=";
pub const refresh_arg = "--pets-refresh";
pub const install_update_arg = "--pets-install-update";
pub const hidden_arg = "--hidden";

/// Variables removed from the app's environment.
pub const stripped_env = [_][]const u8{"GDK_BACKEND"};

pub const refresh_timeout_ms: i64 = 30_000;
pub const refresh_backoff_first_ms: i64 = 5 * 60 * 1000;
pub const refresh_backoff_max_ms: i64 = 6 * 60 * 60 * 1000;
pub const repeat_window_ms: i64 = 1500;
pub const crash_limit: usize = 3;
pub const crash_window_ms: i64 = 60_000;
pub const crash_block_ms: i64 = 5 * 60 * 1000;
/// An exit this soon after starting, abnormal, counts as a crash.
pub const crash_after_start_ms: i64 = 10_000;

const max_children = 16;

pub const Mode = union(enum) {
    open: []const u8,
    refresh,
    install_update,
    hidden,

    fn eql(a: Mode, b: Mode) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .open => |p| std.mem.eql(u8, p, b.open),
            else => true,
        };
    }
};

pub const Result = enum {
    started,
    /// A refresh is still running, or the same request just started one.
    already_running,
    /// Held back by the refresh back-off or the crash guard.
    backing_off,
    /// `--pets-open` path that the app would refuse (see protocol.appPathOk).
    invalid,
    /// The app could not be started (missing, not executable, out of fds).
    failed,
};

const Pid = if (is_windows) std.os.windows.HANDLE else std.posix.pid_t;

const Child = struct {
    pid: Pid,
    started_ms: i64,
    is_refresh: bool,
};

pub const Launcher = struct {
    gpa: std.mem.Allocator,
    app: []const u8,
    app_args: []const []const u8,
    /// The environment to start the app with (POSIX); null = this
    /// process's. `stripped_env` is removed either way.
    env: ?*const std.process.Environ.Map = null,

    children: [max_children]Child = undefined,
    children_len: usize = 0,

    /// The refresh run being waited for (index into `children` is not
    /// stable, so it is kept by pid).
    refresh_pid: ?Pid = null,
    refresh_started_ms: i64 = 0,
    refresh_failures: u32 = 0,
    refresh_not_before_ms: i64 = 0,

    crashes: [crash_limit]i64 = @splat(0),
    crashes_len: usize = 0,
    blocked_until_ms: i64 = 0,

    last_mode: ?Mode = null,
    last_path_buf: [512]u8 = undefined,
    last_started_ms: i64 = 0,

    /// `app` and `app_args` are borrowed (the pet's argv lives forever).
    pub fn init(gpa: std.mem.Allocator, app: []const u8, app_args: []const []const u8) Launcher {
        return .{ .gpa = gpa, .app = app, .app_args = app_args };
    }

    pub fn openApp(self: *Launcher, path: []const u8, now_ms: i64) Result {
        return self.launch(.{ .open = path }, now_ms);
    }

    pub fn refreshApp(self: *Launcher, now_ms: i64) Result {
        return self.launch(.refresh, now_ms);
    }

    pub fn installUpdate(self: *Launcher, now_ms: i64) Result {
        return self.launch(.install_update, now_ms);
    }

    pub fn startHidden(self: *Launcher, now_ms: i64) Result {
        return self.launch(.hidden, now_ms);
    }

    /// A refresh run is in flight (spawned, not yet exited, handed over or
    /// timed out).
    pub fn refreshRunning(self: *const Launcher) bool {
        return self.refresh_pid != null;
    }

    /// Earliest time `refreshApp` will start a run (back-off).
    pub fn refreshAllowedAt(self: *const Launcher) i64 {
        return self.refresh_not_before_ms;
    }

    /// Electron handed a new timeline over: the refresh worked.
    pub fn noteHandoff(self: *Launcher) void {
        self.refresh_pid = null;
        self.refresh_failures = 0;
        self.refresh_not_before_ms = 0;
    }

    pub fn launch(self: *Launcher, mode: Mode, now_ms: i64) Result {
        if (mode == .open and !protocol.appPathOk(mode.open)) return .invalid;
        if (mode == .refresh) {
            if (self.refresh_pid != null) return .already_running;
            if (now_ms < self.refresh_not_before_ms) return .backing_off;
        } else {
            if (now_ms < self.blocked_until_ms) return .backing_off;
            if (self.last_mode) |last| {
                if (last.eql(mode) and now_ms - self.last_started_ms < repeat_window_ms) return .already_running;
            }
        }
        self.reap(now_ms);
        if (self.children_len == max_children) return .backing_off;

        var arg_buf: [open_arg_prefix.len + 512]u8 = undefined;
        const flag: []const u8 = switch (mode) {
            .open => |path| std.fmt.bufPrint(&arg_buf, "{s}{s}", .{ open_arg_prefix, path }) catch return .invalid,
            .refresh => refresh_arg,
            .install_update => install_update_arg,
            .hidden => hidden_arg,
        };
        const pid = spawnDetached(self.gpa, self.app, self.app_args, flag, self.env) catch return .failed;
        self.children[self.children_len] = .{ .pid = pid, .started_ms = now_ms, .is_refresh = mode == .refresh };
        self.children_len += 1;
        if (mode == .refresh) {
            self.refresh_pid = pid;
            self.refresh_started_ms = now_ms;
        } else {
            self.last_mode = switch (mode) {
                .open => |path| blk: {
                    @memcpy(self.last_path_buf[0..path.len], path);
                    break :blk .{ .open = self.last_path_buf[0..path.len] };
                },
                else => mode,
            };
            self.last_started_ms = now_ms;
        }
        return .started;
    }

    /// Collect exited children; give up on a refresh run past its timeout.
    pub fn reap(self: *Launcher, now_ms: i64) void {
        var i: usize = 0;
        while (i < self.children_len) {
            const child = self.children[i];
            const exit = pollExit(child.pid) orelse {
                i += 1;
                continue;
            };
            if (self.refresh_pid != null and samePid(self.refresh_pid.?, child.pid)) {
                // Exited without handing over (noteHandoff clears refresh_pid).
                self.refresh_pid = null;
                self.refreshFailed(now_ms);
            } else if (!child.is_refresh and !exit.clean and now_ms - child.started_ms < crash_after_start_ms) {
                self.noteCrash(now_ms);
            }
            self.children[i] = self.children[self.children_len - 1];
            self.children_len -= 1;
        }
        if (self.refresh_pid != null and now_ms - self.refresh_started_ms >= refresh_timeout_ms) {
            self.refresh_pid = null;
            self.refreshFailed(now_ms);
        }
    }

    fn refreshFailed(self: *Launcher, now_ms: i64) void {
        self.refresh_failures +|= 1;
        const shift: u6 = @intCast(@min(self.refresh_failures - 1, 16));
        const delay = @min(refresh_backoff_first_ms << shift, refresh_backoff_max_ms);
        self.refresh_not_before_ms = now_ms + delay;
    }

    fn noteCrash(self: *Launcher, now_ms: i64) void {
        // Keep the crashes inside the window, newest last.
        var kept: usize = 0;
        for (self.crashes[0..self.crashes_len]) |t| {
            if (now_ms - t < crash_window_ms) {
                self.crashes[kept] = t;
                kept += 1;
            }
        }
        if (kept == crash_limit) {
            std.mem.copyForwards(i64, self.crashes[0 .. crash_limit - 1], self.crashes[1..crash_limit]);
            kept -= 1;
        }
        self.crashes[kept] = now_ms;
        self.crashes_len = kept + 1;
        if (self.crashes_len >= crash_limit) {
            self.blocked_until_ms = now_ms + crash_block_ms;
            self.crashes_len = 0;
        }
    }
};

fn samePid(a: Pid, b: Pid) bool {
    return a == b;
}

const Exit = struct { clean: bool };

// ---------------------------------------------------------------- POSIX

const SpawnError = error{ SpawnFailed, OutOfMemory };

fn spawnDetached(gpa: std.mem.Allocator, app: []const u8, app_args: []const []const u8, flag: []const u8, env: ?*const std.process.Environ.Map) SpawnError!Pid {
    // Windows inherits the environment (GDK_BACKEND only matters on Linux).
    return if (is_windows) spawnWindows(gpa, app, app_args, flag) else spawnPosix(gpa, app, app_args, flag, env);
}

fn spawnPosix(gpa: std.mem.Allocator, app: []const u8, app_args: []const []const u8, flag: []const u8, env: ?*const std.process.Environ.Map) SpawnError!std.posix.pid_t {
    const c = std.c;
    // Everything the child needs is built before fork: after it only
    // async-signal-safe calls are allowed (other threads may hold locks).
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const argv = try a.allocSentinel(?[*:0]const u8, app_args.len + 2, null);
    argv[0] = try a.dupeZ(u8, app);
    for (app_args, 1..) |arg, i| argv[i] = try a.dupeZ(u8, arg);
    argv[app_args.len + 1] = try a.dupeZ(u8, flag);

    const envp = if (env) |map| try mapEnv(a, map) else try childEnv(a, std.mem.sliceTo(c.environ, null));

    const dev_null = c.open("/dev/null", .{ .ACCMODE = .RDWR });
    if (dev_null < 0) return error.SpawnFailed;
    defer _ = c.close(dev_null);

    // exec failures come back through a close-on-exec pipe: EOF = exec'd.
    var err_pipe: [2]c.fd_t = undefined;
    if (c.pipe(&err_pipe) != 0) return error.SpawnFailed;
    defer _ = c.close(err_pipe[0]);
    _ = c.fcntl(err_pipe[0], c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    _ = c.fcntl(err_pipe[1], c.F.SETFD, @as(c_int, c.FD_CLOEXEC));

    const empty_mask = std.posix.sigemptyset();

    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(err_pipe[1]);
        return error.SpawnFailed;
    }
    if (pid == 0) {
        // Child.
        _ = c.setsid();
        _ = c.sigprocmask(std.posix.SIG.SETMASK, &empty_mask, null);
        _ = c.dup2(dev_null, 0);
        _ = c.dup2(dev_null, 1);
        _ = c.dup2(dev_null, 2);
        closeFrom(3, err_pipe[1]);
        _ = c.execve(argv[0].?, argv.ptr, envp.ptr);
        const errno: u8 = @truncate(@as(c_uint, @bitCast(c._errno().*)));
        _ = c.write(err_pipe[1], @ptrCast(&errno), 1);
        c._exit(127);
    }
    _ = c.close(err_pipe[1]);
    var report: [1]u8 = undefined;
    const n = while (true) {
        const r = c.read(err_pipe[0], &report, 1);
        if (r < 0 and c._errno().* == @intFromEnum(c.E.INTR)) continue;
        break r;
    };
    if (n == 1) {
        // exec failed: the child already exited; collect it now.
        var status: c_int = 0;
        _ = c.waitpid(pid, &status, 0);
        return error.SpawnFailed;
    }
    return pid;
}

/// Close every descriptor from `first` up except `keep` (child only).
fn closeFrom(first: c_int, keep: c_int) void {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const max = std.math.maxInt(linux.fd_t);
        if (keep > first) _ = linux.close_range(first, keep - 1, .{ .UNSHARE = false, .CLOEXEC = false });
        if (linux.errno(linux.close_range(keep + 1, max, .{ .UNSHARE = false, .CLOEXEC = false })) == .SUCCESS) return;
    }
    var fd: c_int = first;
    while (fd < 4096) : (fd += 1) {
        if (fd != keep) _ = std.c.close(fd);
    }
}

/// The parent's environment minus `stripped_env`, as a NULL-terminated
/// array of `NAME=value` strings.
fn childEnv(a: std.mem.Allocator, parent: []const ?[*:0]u8) ![:null]?[*:0]const u8 {
    var out: std.ArrayList(?[*:0]const u8) = .empty;
    outer: for (parent) |entry| {
        const s = std.mem.sliceTo(entry.?, 0);
        for (stripped_env) |name| {
            if (s.len > name.len and std.mem.startsWith(u8, s, name) and s[name.len] == '=') continue :outer;
        }
        try out.append(a, entry.?);
    }
    return out.toOwnedSliceSentinel(a, null);
}

/// `NAME=value` strings from an environment map, minus `stripped_env`.
fn mapEnv(a: std.mem.Allocator, map: *const std.process.Environ.Map) ![:null]?[*:0]const u8 {
    var out: std.ArrayList(?[*:0]const u8) = .empty;
    outer: for (map.keys(), map.values()) |key, value| {
        for (stripped_env) |name| if (std.mem.eql(u8, key, name)) continue :outer;
        try out.append(a, try std.fmt.allocPrintSentinel(a, "{s}={s}", .{ key, value }, 0));
    }
    return out.toOwnedSliceSentinel(a, null);
}

fn pollExit(pid: Pid) ?Exit {
    if (is_windows) return pollExitWindows(pid);
    var status: c_int = 0;
    const r = std.c.waitpid(pid, &status, std.c.W.NOHANG);
    if (r == 0) return null;
    // Gone already (or not ours): treat as exited, cleanly.
    if (r < 0) return .{ .clean = true };
    const s: u32 = @bitCast(status);
    return .{ .clean = std.c.W.IFEXITED(s) and std.c.W.EXITSTATUS(s) == 0 };
}

// -------------------------------------------------------------- Windows

const win = std.os.windows;
const WAIT_OBJECT_0: u32 = 0;
const STILL_ACTIVE: u32 = 259;

extern "kernel32" fn WaitForSingleObject(handle: win.HANDLE, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(handle: win.HANDLE, code: *u32) callconv(.winapi) win.BOOL;

fn spawnWindows(gpa: std.mem.Allocator, app: []const u8, app_args: []const []const u8, flag: []const u8) SpawnError!win.HANDLE {
    if (!is_windows) unreachable;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var line: std.ArrayList(u8) = .empty;
    try appendQuoted(a, &line, app);
    for (app_args) |arg| {
        try line.append(a, ' ');
        try appendQuoted(a, &line, arg);
    }
    try line.append(a, ' ');
    try appendQuoted(a, &line, flag);
    const cmd = std.unicode.wtf8ToWtf16LeAllocZ(a, line.items) catch return error.SpawnFailed;
    const app_w = std.unicode.wtf8ToWtf16LeAllocZ(a, app) catch return error.SpawnFailed;

    var si = std.mem.zeroes(win.STARTUPINFOW);
    si.cb = @sizeOf(win.STARTUPINFOW);
    var pi: win.PROCESS.INFORMATION = undefined;
    // No handle inheritance: the pet's pipe never reaches Electron.
    // GDK_BACKEND is a Linux-only concern; the environment is inherited.
    const ok = win.kernel32.CreateProcessW(app_w.ptr, cmd.ptr, null, null, .FALSE, .{
        .detached_process = true,
        .create_new_process_group = true,
    }, null, null, &si, &pi);
    if (!ok.toBool()) return error.SpawnFailed;
    win.CloseHandle(pi.hThread);
    return pi.hProcess;
}

fn pollExitWindows(handle: win.HANDLE) ?Exit {
    if (!is_windows) unreachable;
    if (WaitForSingleObject(handle, 0) != WAIT_OBJECT_0) return null;
    var code: u32 = 0;
    const got = GetExitCodeProcess(handle, &code).toBool();
    win.CloseHandle(handle);
    return .{ .clean = got and code == 0 };
}

/// One argument quoted the way CommandLineToArgvW / the MSVC runtime
/// split it back (backslashes doubled before a quote).
fn appendQuoted(a: std.mem.Allocator, out: *std.ArrayList(u8), arg: []const u8) !void {
    const needs = arg.len == 0 or std.mem.indexOfAny(u8, arg, " \t\n\x0b\"") != null;
    if (!needs) return out.appendSlice(a, arg);
    try out.append(a, '"');
    var backslashes: usize = 0;
    for (arg) |ch| {
        if (ch == '\\') {
            backslashes += 1;
            continue;
        }
        if (ch == '"') {
            try out.appendNTimes(a, '\\', backslashes * 2 + 1);
        } else {
            try out.appendNTimes(a, '\\', backslashes);
        }
        backslashes = 0;
        try out.append(a, ch);
    }
    try out.appendNTimes(a, '\\', backslashes * 2);
    try out.append(a, '"');
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "appendQuoted: CommandLineToArgvW rules" {
    const cases = [_][2][]const u8{
        .{ "C:\\Program Files\\TracingInsights\\TracingInsights.exe", "\"C:\\Program Files\\TracingInsights\\TracingInsights.exe\"" },
        .{ "--pets-open=/stats", "--pets-open=/stats" },
        .{ "", "\"\"" },
        .{ "a\"b", "\"a\\\"b\"" },
        .{ "dir with space\\", "\"dir with space\\\\\"" },
        .{ "x\\\\\"y z", "\"x\\\\\\\\\\\"y z\"" },
    };
    for (cases) |c| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try appendQuoted(testing.allocator, &out, c[0]);
        try testing.expectEqualStrings(c[1], out.items);
    }
}

test "mapEnv drops GDK_BACKEND" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var map = std.process.Environ.Map.init(arena.allocator());
    try map.put("HOME", "/home/u");
    try map.put("GDK_BACKEND", "x11");
    const env = try mapEnv(arena.allocator(), &map);
    try testing.expectEqual(@as(usize, 1), env.len);
    try testing.expectEqualStrings("HOME=/home/u", std.mem.sliceTo(env[0].?, 0));
}

test "childEnv drops GDK_BACKEND only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var entries = [_:null]?[*:0]u8{
        @constCast("HOME=/home/u"),
        @constCast("GDK_BACKEND=x11"),
        @constCast("GDK_BACKEND_EXTRA=1"),
        @constCast("DISPLAY=:0"),
    };
    const env = try childEnv(arena.allocator(), &entries);
    try testing.expectEqual(@as(usize, 3), env.len);
    try testing.expectEqualStrings("HOME=/home/u", std.mem.sliceTo(env[0].?, 0));
    try testing.expectEqualStrings("GDK_BACKEND_EXTRA=1", std.mem.sliceTo(env[1].?, 0));
    try testing.expect(env[3] == null);
}

/// A shell script standing in for the Electron app: logs its argv,
/// environment, session and open descriptors, then exits with $TI_EXIT
/// after $TI_SLEEP seconds.
const fake_app =
    \\#!/bin/sh
    \\log="$(dirname "$0")/log"
    \\{
    \\  echo "args:$*"
    \\  echo "gdk:${GDK_BACKEND-unset}"
    \\  echo "sid:$(ps -o sid= -p $$ | tr -d ' ')"
    \\  echo "fds:$(ls /proc/$$/fd 2>/dev/null | tr '\n' ' ')"
    \\} >> "$log"
    \\sleep "${TI_SLEEP:-0}"
    \\exit "${TI_EXIT:-0}"
    \\
;

fn waitUntil(l: *Launcher, now: *i64, done: *const fn (*Launcher) bool) !void {
    var tries: usize = 0;
    while (!done(l)) : (tries += 1) {
        if (tries > 400) return error.Timeout;
        try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
        now.* += 10;
        l.reap(now.*);
    }
}

test "spawns detached, without GDK_BACKEND or our descriptors; refresh de-dup" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    try tmp.dir.writeFile(io, .{ .sub_path = "app", .data = fake_app, .flags = .{ .permissions = @enumFromInt(0o700) } });
    const app = try std.fs.path.join(a, &.{ dir, "app" });

    // A descriptor without CLOEXEC that the child must not inherit.
    // (High number: the shell's own `ls` reuses the low ones.)
    const opened = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY });
    const leaky: c_int = 77;
    try testing.expectEqual(leaky, std.c.dup2(opened, leaky));
    _ = std.c.close(opened);
    defer _ = std.c.close(leaky);

    // The pet itself runs with GDK_BACKEND=x11; the app must not see it.
    const env = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    };
    try testing.expectEqual(@as(c_int, 0), env.setenv("GDK_BACKEND", "x11", 1));
    defer _ = env.unsetenv("GDK_BACKEND");

    var l = Launcher.init(testing.allocator, app, &.{ "/opt/app dir", "--x" });
    var now: i64 = 1_000_000;
    try testing.expectEqual(Result.started, l.refreshApp(now));
    try testing.expect(l.refreshRunning());
    try testing.expectEqual(Result.already_running, l.refreshApp(now + 5));
    // Exited without a hand-off: a failure, backed off 5 min.
    try waitUntil(&l, &now, struct {
        fn f(x: *Launcher) bool {
            return !x.refreshRunning();
        }
    }.f);
    try testing.expectEqual(Result.backing_off, l.refreshApp(now));
    try testing.expectEqual(now + refresh_backoff_first_ms, l.refreshAllowedAt());
    l.noteHandoff();
    try testing.expectEqual(Result.started, l.refreshApp(now));
    try waitUntil(&l, &now, struct {
        fn f(x: *Launcher) bool {
            return x.children_len == 0;
        }
    }.f);

    try testing.expectEqual(Result.invalid, l.openApp("//evil.example", now));
    try testing.expectEqual(Result.started, l.openApp("/stats", now));
    try testing.expectEqual(Result.already_running, l.openApp("/stats", now + 100));
    try waitUntil(&l, &now, struct {
        fn f(x: *Launcher) bool {
            return x.children_len == 0;
        }
    }.f);

    const log = try tmp.dir.readFileAlloc(io, "log", a, .limited(64 * 1024));
    try testing.expect(std.mem.indexOf(u8, log, "args:/opt/app dir --x --pets-refresh\n") != null);
    try testing.expect(std.mem.indexOf(u8, log, "args:/opt/app dir --x --pets-open=/stats\n") != null);
    try testing.expect(std.mem.indexOf(u8, log, "gdk:unset") != null);
    // Its own session (sid = its pid, not ours).
    var sid_buf: [32]u8 = undefined;
    const our_sid = try std.fmt.bufPrint(&sid_buf, "sid:{d}\n", .{std.os.linux.getsid(0)});
    try testing.expect(std.mem.indexOf(u8, log, our_sid) == null);
    // Only stdio (+ the shell's own) — never `leaky`.
    var fd_buf: [16]u8 = undefined;
    const leaky_fd = try std.fmt.bufPrint(&fd_buf, " {d} ", .{leaky});
    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "fds:")) continue;
        try testing.expect(std.mem.indexOf(u8, line, leaky_fd) == null);
    }
}

test "refresh timeout gives up without killing; missing app fails" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var l = Launcher.init(testing.allocator, "/nonexistent/ti-app", &.{});
    try testing.expectEqual(Result.failed, l.refreshApp(0));
    try testing.expect(!l.refreshRunning());

    l = Launcher.init(testing.allocator, "/bin/sleep", &.{"0.3"});
    try testing.expectEqual(Result.started, l.refreshApp(0));
    l.reap(refresh_timeout_ms);
    try testing.expect(!l.refreshRunning());
    try testing.expectEqual(refresh_timeout_ms + refresh_backoff_first_ms, l.refreshAllowedAt());
    try testing.expectEqual(@as(usize, 1), l.children_len); // still reaped later
    var now: i64 = refresh_timeout_ms;
    try waitUntil(&l, &now, struct {
        fn f(x: *Launcher) bool {
            return x.children_len == 0;
        }
    }.f);
    // Failures double, capped.
    l.refresh_failures = 20;
    l.refreshFailed(0);
    try testing.expectEqual(refresh_backoff_max_ms, l.refreshAllowedAt());
}

test "crash guard: three quick abnormal exits block opens" {
    var l = Launcher.init(testing.allocator, "/bin/false", &.{});
    l.noteCrash(0);
    l.noteCrash(1000);
    try testing.expectEqual(@as(i64, 0), l.blocked_until_ms);
    l.noteCrash(70_000); // the first fell out of the window
    try testing.expectEqual(@as(i64, 0), l.blocked_until_ms);
    l.noteCrash(71_000);
    try testing.expectEqual(@as(i64, 0), l.blocked_until_ms);
    l.noteCrash(72_000);
    try testing.expectEqual(72_000 + crash_block_ms, l.blocked_until_ms);
    try testing.expectEqual(Result.backing_off, l.openApp("/", 73_000));
    try testing.expectEqual(Result.backing_off, l.startHidden(73_000));
}
