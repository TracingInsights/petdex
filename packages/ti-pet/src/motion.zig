//! Roaming (round 3, SPEC 2a): the renderer side of the payload's
//! `motion`, native port of desktop/src/pets/roam.mjs in the tif1ai repo.
//! Change both together.
//!
//! Behaviour only says whether the pet may move (`motion`: roam / dash /
//! null); walking is the renderer's:
//!
//!   - walk horizontally at the current y inside the work area of the
//!     display the pet is on (the whole window: a duo walks as one group);
//!   - roam: pause `roam_pause_min_ms`…`roam_pause_max_ms` (uniform random,
//!     the payload's own row), then walk to a random x at least
//!     `roam_min_distance_px` away at `roam_speed_px_s` × size scale; repeat;
//!   - dash: run to the farther end of the range and back to where it
//!     started, at max(`dash_speed_px_s` × size scale, path / `dash_max_ms`);
//!     once per change of `motion` to dash;
//!   - while walking the pet shows running-left / running-right (`pose`);
//!   - x follows the clock (from + (to − from) × elapsed / duration), at
//!     most one window move per `motion_tick_ms` (≤ 30 per second);
//!   - a walk that ends or is stopped saves the position like a drop, once
//!     per walk and only when the pet moved;
//!   - no timers while `motion` is null.
//!
//! One native difference: the Native SDK cannot tell an app its display's
//! work area. Its window move clamps to it (Windows: the monitor's work
//! area, macOS: the screen's visible frame, Linux/X11: the X screen) and
//! reports when the clamp stopped it, so the walker learns the edges as it
//! meets them. An edge not met yet counts as `unknown_edge_span_px` away
//! (`dash_unknown_span_px` for a dash, which then runs at the plain dash
//! speed until the clamp stops it). Once both edges are known the targets
//! are exactly roam.mjs's. Forget the edges whenever the pet may have
//! changed display or size (`forgetEdges`).
//!
//! The walker keeps the x it last commanded rather than reading the window
//! back: an X11 window manager applies moves a little later, so a read
//! right after the last step can lag behind it (measured under Mutter:
//! a dash read 3 px short of where it was sent back to).
//!
//! Pure: time, randomness, the window and the timer come in through `Env`.

const std = @import("std");
const protocol = @import("protocol.zig");

pub const roam_speed_px_s: f64 = 80;
pub const roam_min_distance_px: f64 = 120;
pub const roam_pause_min_ms: i64 = 10_000;
pub const roam_pause_max_ms: i64 = 40_000;
/// One window move per tick at most: 34 ms ≈ 29.4 moves per second.
pub const motion_tick_ms: u32 = 34;
pub const dash_speed_px_s: f64 = 480;
/// The whole dash (out and back) takes at most this long.
pub const dash_max_ms: i64 = 8000;
/// An unmet work-area edge is assumed this far away for a roam target.
pub const unknown_edge_span_px: f64 = 480;
/// ... and this far for a dash (the clamp stops it at the real edge).
pub const dash_unknown_span_px: f64 = 4000;
/// An edge closer than this to where the clamp stopped counts as met.
const edge_slack_px: f64 = 0.5;

pub const Direction = enum { left, right };

pub const Phase = enum { idle, pause, walk, done };

pub const Range = struct { min_x: f64, max_x: f64 };

pub const Leg = struct {
    from_x: f64,
    to_x: f64,
    start_ms: i64,
    duration_ms: i64,

    pub fn init(from_x: f64, to_x: f64, start_ms: i64, speed: f64) Leg {
        const ms = @round(@abs(to_x - from_x) / speed * 1000);
        return .{ .from_x = from_x, .to_x = to_x, .start_ms = start_ms, .duration_ms = @max(1, @as(i64, @intFromFloat(ms))) };
    }

    pub fn end(self: Leg) i64 {
        return self.start_ms + self.duration_ms;
    }

    /// x on the leg at `t` (whole points).
    pub fn xAt(self: Leg, t: i64) f64 {
        const elapsed: f64 = @floatFromInt(t - self.start_ms);
        const p = std.math.clamp(elapsed / @as(f64, @floatFromInt(self.duration_ms)), 0, 1);
        return @round(self.from_x + (self.to_x - self.from_x) * p);
    }
};

/// Where the window went after a move: the clamp may have stopped it.
pub const Landed = struct { x: f64, hit: bool };

/// The walker's view of the world (main.zig binds it to the window).
pub const Env = struct {
    ctx: *anyopaque,
    now_ms: i64,
    random: std.Random,
    /// Size scale (s 0.5 / m 0.75 / l 1).
    scale: f64,
    /// The window's x now; null while there is no window to move.
    position: *const fn (ctx: *anyopaque) ?f64,
    /// Move to x (the OS clamps it into the work area).
    move_to: *const fn (ctx: *anyopaque, x: f64) ?Landed,
    /// Save the position like a drop (`x` = where the walk left it).
    save: *const fn (ctx: *anyopaque, x: f64) void,
    /// Call `tick` once, `ms` from now (replaces a pending wake-up).
    arm: *const fn (ctx: *anyopaque, ms: u32) void,
    disarm: *const fn (ctx: *anyopaque) void,
};

fn unit(random: std.Random) f64 {
    return random.float(f64);
}

/// Pause before the next roam walk.
pub fn roamPauseMs(random: std.Random) i64 {
    const span: f64 = @floatFromInt(roam_pause_max_ms - roam_pause_min_ms);
    return roam_pause_min_ms + @as(i64, @intFromFloat(@round(unit(random) * span)));
}

/// A random target in `range` at least `roam_min_distance_px` from `x`
/// (uniform over both sides together); null when there is none.
pub fn pickRoamTarget(x: f64, range: Range, random: std.Random) ?f64 {
    const left = @max(0, x - roam_min_distance_px - range.min_x);
    const right = @max(0, range.max_x - (x + roam_min_distance_px));
    const total = left + right;
    if (total <= 0) return null;
    const r = unit(random) * total;
    return @round(if (r < left) range.min_x + r else x + roam_min_distance_px + (r - left));
}

pub const DashPlan = struct { far: f64, speed: f64 };

/// Out to the farther end of `range` (left on a tie), at a speed that fits
/// the whole run into `dash_max_ms`; null when there is nowhere to go.
pub fn dashPlan(x: f64, range: Range, scale: f64) ?DashPlan {
    const far = if (x - range.min_x >= range.max_x - x) range.min_x else range.max_x;
    const distance = @abs(far - x);
    if (distance == 0) return null;
    const fit = 2 * distance / (@as(f64, @floatFromInt(dash_max_ms)) / 1000);
    return .{ .far = far, .speed = @max(dash_speed_px_s * scale, fit) };
}

pub const Walker = struct {
    /// The payload's motion.
    mode: ?protocol.Motion = null,
    phase: Phase = .idle,
    leg: ?Leg = null,
    /// The dash's way back (where it started).
    back_to: ?f64 = null,
    speed: f64 = 0,
    start_x: f64 = 0,
    /// Where the last step sent the window (null = not walking).
    cmd_x: ?f64 = null,
    /// Work-area edges met so far (window x at the left / right stop).
    left_edge: ?f64 = null,
    right_edge: ?f64 = null,

    /// The pet may be elsewhere now (drag, new size, shown again).
    pub fn forgetEdges(self: *Walker) void {
        self.left_edge = null;
        self.right_edge = null;
    }

    /// Range for a roam target (`span` past an unmet edge).
    pub fn range(self: *const Walker, x: f64, span: f64) Range {
        return .{ .min_x = self.left_edge orelse x - span, .max_x = self.right_edge orelse x + span };
    }

    /// Follow the payload's motion: a change stops a walk (saved), roam
    /// pauses first, dash runs at once.
    pub fn setMotion(self: *Walker, env: Env, next: ?protocol.Motion) void {
        if (next == self.mode) return;
        const moved = self.stopWalking(env);
        env.disarm(env.ctx);
        self.mode = next;
        self.phase = .idle;
        if (next) |m| switch (m) {
            .roam => self.schedulePause(env),
            .dash => self.startDash(env),
        };
        if (moved) |x| env.save(env.ctx, x);
    }

    /// Stop the current walk (saved); roaming pauses, a dash is over.
    pub fn interrupt(self: *Walker, env: Env) void {
        const was_walking = self.phase == .walk;
        const moved = self.stopWalking(env);
        if (!was_walking) return;
        if (self.mode == .roam) self.schedulePause(env) else self.phase = .done;
        if (moved) |x| env.save(env.ctx, x);
    }

    /// Hidden / re-shown: stop (saving a walk in progress), forget motion.
    pub fn stop(self: *Walker, env: Env) void {
        const moved = self.stopWalking(env);
        self.reset(env);
        if (moved) |x| env.save(env.ctx, x);
    }

    /// Row override while walking, else null.
    pub fn pose(self: *const Walker) ?Direction {
        if (self.phase != .walk) return null;
        const leg = self.leg orelse return null;
        return if (leg.to_x < leg.from_x) .left else .right;
    }

    pub fn walking(self: *const Walker) bool {
        return self.phase == .walk;
    }

    /// The timer fired (pause over, or the next move is due).
    pub fn tick(self: *Walker, env: Env) void {
        switch (self.phase) {
            .pause => self.startRoamWalk(env),
            .walk => self.step(env),
            .idle, .done => {},
        }
    }

    fn reset(self: *Walker, env: Env) void {
        env.disarm(env.ctx);
        self.mode = null;
        self.phase = .idle;
        self.leg = null;
        self.back_to = null;
        self.cmd_x = null;
    }

    /// Stop a walk in progress where it is: the x to save when it moved
    /// (the caller saves, last), else null.
    fn stopWalking(self: *Walker, env: Env) ?f64 {
        if (self.phase != .walk) return null;
        env.disarm(env.ctx);
        self.phase = .idle;
        self.leg = null;
        self.back_to = null;
        const here = self.cmd_x orelse env.position(env.ctx) orelse return null;
        self.cmd_x = null;
        return if (here != self.start_x) here else null;
    }

    fn schedulePause(self: *Walker, env: Env) void {
        self.phase = .pause;
        env.arm(env.ctx, @intCast(roamPauseMs(env.random)));
    }

    fn beginWalk(self: *Walker, env: Env, x: f64, to_x: f64, back_to: ?f64, speed: f64) void {
        self.speed = speed;
        self.start_x = x;
        self.cmd_x = x;
        self.leg = Leg.init(x, to_x, env.now_ms, speed);
        self.back_to = back_to;
        self.phase = .walk;
        env.arm(env.ctx, motion_tick_ms);
    }

    fn startRoamWalk(self: *Walker, env: Env) void {
        const x = env.position(env.ctx) orelse return self.reset(env);
        const target = pickRoamTarget(x, self.range(x, unknown_edge_span_px), env.random) orelse
            return self.schedulePause(env);
        self.beginWalk(env, x, target, null, roam_speed_px_s * env.scale);
    }

    fn startDash(self: *Walker, env: Env) void {
        const x = env.position(env.ctx) orelse {
            self.phase = .done;
            return;
        };
        const known = self.left_edge != null and self.right_edge != null;
        const plan = dashPlan(x, self.range(x, dash_unknown_span_px), env.scale) orelse {
            self.phase = .done;
            return;
        };
        // An unmet edge: run at the plain dash speed until the clamp stops it.
        const speed = if (known) plan.speed else dash_speed_px_s * env.scale;
        self.beginWalk(env, x, plan.far, x, speed);
    }

    fn step(self: *Walker, env: Env) void {
        var leg = self.leg orelse return;
        const actual = env.position(env.ctx) orelse return self.reset(env);
        const here = self.cmd_x orelse actual;
        const t = env.now_ms;
        var turned = false;
        if (t >= leg.end()) if (self.back_to) |back| {
            leg = Leg.init(leg.to_x, back, leg.end(), self.speed);
            self.back_to = null;
            turned = true;
        };
        const arrived = t >= leg.end();
        // A turn shows the far end itself; the next leg's timing still runs
        // from the exact turn time.
        const want = if (arrived) leg.to_x else if (turned) leg.from_x else leg.xAt(t);
        self.leg = leg;
        var landed: Landed = .{ .x = here, .hit = false };
        if (want != here) landed = env.move_to(env.ctx, want) orelse return self.reset(env);
        self.cmd_x = landed.x;
        if (landed.hit) {
            self.learnEdge(leg, landed.x);
            if (self.back_to) |back| {
                // The dash met its far end early: turn here, now.
                self.leg = Leg.init(landed.x, back, t, self.speed);
                self.back_to = null;
                env.arm(env.ctx, motion_tick_ms);
                return;
            }
            return self.arrive(env);
        }
        if (arrived) {
            // Arrived where an edge was thought to be, unstopped: it was not.
            if (self.left_edge) |e| if (@abs(e - leg.to_x) <= edge_slack_px and leg.to_x < leg.from_x) {
                self.left_edge = null;
            };
            if (self.right_edge) |e| if (@abs(e - leg.to_x) <= edge_slack_px and leg.to_x > leg.from_x) {
                self.right_edge = null;
            };
            return self.arrive(env);
        }
        env.arm(env.ctx, motion_tick_ms);
    }

    /// Arrived (or stopped by an edge): pause (roam) or rest (dash), then
    /// save like a drop.
    fn arrive(self: *Walker, env: Env) void {
        const moved = self.stopWalking(env);
        if (self.mode == .roam) self.schedulePause(env) else self.phase = .done;
        if (moved) |x| env.save(env.ctx, x);
    }

    fn learnEdge(self: *Walker, leg: Leg, x: f64) void {
        if (leg.to_x > leg.from_x) self.right_edge = x else self.left_edge = x;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// A window on a fake screen: x clamped to [min_x, max_x].
const Fake = struct {
    x: f64 = 500,
    min_x: f64 = 0,
    max_x: f64 = 1000,
    alive: bool = true,
    now: i64 = 0,
    saves: usize = 0,
    saved_x: f64 = 0,
    /// A lagging window manager: reads return where the window was before
    /// the last move.
    lagging: bool = false,
    read_x: ?f64 = null,
    moves: usize = 0,
    armed: ?u32 = null,
    prng: std.Random.DefaultPrng = .init(42),

    fn env(self: *Fake, scale: f64) Env {
        return .{
            .ctx = self,
            .now_ms = self.now,
            .random = self.prng.random(),
            .scale = scale,
            .position = position,
            .move_to = moveTo,
            .save = save,
            .arm = arm,
            .disarm = disarm,
        };
    }

    fn cast(ctx: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ctx));
    }
    fn position(ctx: *anyopaque) ?f64 {
        const f = cast(ctx);
        if (!f.alive) return null;
        return if (f.lagging) (f.read_x orelse f.x) else f.x;
    }
    fn moveTo(ctx: *anyopaque, x: f64) ?Landed {
        const f = cast(ctx);
        if (!f.alive) return null;
        f.moves += 1;
        const clamped = std.math.clamp(x, f.min_x, f.max_x);
        f.read_x = f.x;
        f.x = clamped;
        return .{ .x = clamped, .hit = clamped != x };
    }
    fn save(ctx: *anyopaque, x: f64) void {
        const f = cast(ctx);
        f.saves += 1;
        f.saved_x = x;
    }
    fn arm(ctx: *anyopaque, ms: u32) void {
        cast(ctx).armed = ms;
    }
    fn disarm(ctx: *anyopaque) void {
        cast(ctx).armed = null;
    }

    /// Fire the armed timer (advancing the clock); false when none.
    fn fire(self: *Fake, w: *Walker, scale: f64) bool {
        const ms = self.armed orelse return false;
        self.armed = null;
        self.now += ms;
        w.tick(self.env(scale));
        return true;
    }
};

test "pickRoamTarget: uniform over both sides, at least 120 away, null when cramped" {
    var prng = std.Random.DefaultPrng.init(1);
    const r = prng.random();
    var i: usize = 0;
    var lefts: usize = 0;
    while (i < 2000) : (i += 1) {
        const t = pickRoamTarget(500, .{ .min_x = 0, .max_x = 1000 }, r).?;
        try testing.expect(t >= 0 and t <= 1000);
        try testing.expect(@abs(t - 500) >= roam_min_distance_px);
        if (t < 500) lefts += 1;
    }
    // Both sides are 380 px: about half each.
    try testing.expect(lefts > 850 and lefts < 1150);
    // Near the left edge everything lands on the right.
    try testing.expect(pickRoamTarget(50, .{ .min_x = 0, .max_x = 1000 }, r).? >= 170);
    try testing.expect(pickRoamTarget(500, .{ .min_x = 400, .max_x = 600 }, r) == null);
}

test "roamPauseMs: 10–40 s" {
    var prng = std.Random.DefaultPrng.init(2);
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const ms = roamPauseMs(prng.random());
        try testing.expect(ms >= roam_pause_min_ms and ms <= roam_pause_max_ms);
    }
}

test "dashPlan: the farther end, sped up to fit 8 s" {
    const near_right = dashPlan(900, .{ .min_x = 0, .max_x = 1000 }, 0.75).?;
    try testing.expectEqual(@as(f64, 0), near_right.far);
    // 2 × 900 px in 8 s = 225 px/s < 480 × 0.75 = 360 px/s.
    try testing.expectEqual(@as(f64, 360), near_right.speed);
    const wide = dashPlan(100, .{ .min_x = 0, .max_x = 3000 }, 0.5).?;
    try testing.expectEqual(@as(f64, 3000), wide.far);
    try testing.expectEqual(@as(f64, 2 * 2900.0 / 8.0), wide.speed);
    // A tie goes left (roam.mjs).
    try testing.expectEqual(@as(f64, 0), dashPlan(500, .{ .min_x = 0, .max_x = 1000 }, 1).?.far);
    try testing.expect(dashPlan(0, .{ .min_x = 0, .max_x = 0 }, 1) == null);
}

test "Leg: x follows the clock, whole points" {
    const leg = Leg.init(100, 400, 1000, 60);
    try testing.expectEqual(@as(i64, 5000), leg.duration_ms);
    try testing.expectEqual(@as(f64, 100), leg.xAt(0));
    try testing.expectEqual(@as(f64, 250), leg.xAt(3500));
    try testing.expectEqual(@as(f64, 400), leg.xAt(9000));
}

test "roam: pause, walk at 80 px/s × scale, arrive, save once, pause again" {
    var f: Fake = .{ .x = 500 };
    var w: Walker = .{ .left_edge = 0, .right_edge = 1000 };
    const scale = 0.75;
    w.setMotion(f.env(scale), .roam);
    try testing.expectEqual(Phase.pause, w.phase);
    const pause = f.armed.?;
    try testing.expect(pause >= roam_pause_min_ms and pause <= roam_pause_max_ms);
    try testing.expect(w.pose() == null);
    try testing.expect(f.fire(&w, scale));
    try testing.expectEqual(Phase.walk, w.phase);
    try testing.expectEqual(motion_tick_ms, f.armed.?);
    const leg = w.leg.?;
    try testing.expect(@abs(leg.to_x - 500) >= roam_min_distance_px);
    // Duration = distance / (80 × 0.75).
    try testing.expectEqual(@as(i64, @intFromFloat(@round(@abs(leg.to_x - 500) / 60 * 1000))), leg.duration_ms);
    try testing.expectEqual(if (leg.to_x < 500) Direction.left else Direction.right, w.pose().?);
    var ticks: usize = 0;
    while (w.phase == .walk) : (ticks += 1) {
        const before = f.x;
        try testing.expect(f.fire(&w, scale));
        // Never more than one tick's worth of distance per move.
        try testing.expect(@abs(f.x - before) <= 60.0 * 34.0 / 1000.0 + 1);
    }
    try testing.expectEqual(leg.to_x, f.x);
    try testing.expectEqual(@as(usize, 1), f.saves);
    try testing.expectEqual(leg.to_x, f.saved_x);
    try testing.expectEqual(Phase.pause, w.phase);
    try testing.expect(f.armed.? >= roam_pause_min_ms);
    // ~ duration / 34 ms ticks: at most 30 moves a second.
    try testing.expect(@as(f64, @floatFromInt(f.moves)) <= @as(f64, @floatFromInt(leg.duration_ms)) / 1000.0 * 30 + 2);
    try testing.expect(ticks > 0);
}

test "motion null: no timers; a change stops the walk where it is and saves it" {
    var f: Fake = .{ .x = 500 };
    var w: Walker = .{ .left_edge = 0, .right_edge = 1000 };
    w.setMotion(f.env(1), .roam);
    _ = f.fire(&w, 1);
    _ = f.fire(&w, 1);
    _ = f.fire(&w, 1);
    try testing.expect(w.walking() and f.x != 500);
    w.setMotion(f.env(1), null);
    try testing.expect(f.armed == null);
    try testing.expectEqual(Phase.idle, w.phase);
    try testing.expectEqual(@as(usize, 1), f.saves);
    // Same motion again: nothing happens.
    w.setMotion(f.env(1), null);
    try testing.expect(f.armed == null);
    // A pause stopped before it walked saves nothing.
    w.setMotion(f.env(1), .roam);
    w.setMotion(f.env(1), null);
    try testing.expectEqual(@as(usize, 1), f.saves);
}

test "interrupt (drag, resize): roam saves and pauses, a dash is over" {
    var f: Fake = .{ .x = 500 };
    var w: Walker = .{ .left_edge = 0, .right_edge = 1000 };
    w.setMotion(f.env(1), .roam);
    _ = f.fire(&w, 1);
    _ = f.fire(&w, 1);
    w.interrupt(f.env(1));
    try testing.expectEqual(Phase.pause, w.phase);
    try testing.expectEqual(@as(usize, 1), f.saves);
    // While pausing an interrupt changes nothing.
    w.interrupt(f.env(1));
    try testing.expectEqual(Phase.pause, w.phase);
    w.setMotion(f.env(1), .dash);
    _ = f.fire(&w, 1);
    w.interrupt(f.env(1));
    try testing.expectEqual(Phase.done, w.phase);
    try testing.expect(f.armed == null);
    // stop() forgets the motion entirely.
    w.stop(f.env(1));
    try testing.expect(w.mode == null);
}

test "dash: to the farther end and back, once per change, under 8 s" {
    var f: Fake = .{ .x = 300, .now = 1000 };
    var w: Walker = .{ .left_edge = 0, .right_edge = 1000 };
    w.setMotion(f.env(0.75), .dash);
    try testing.expectEqual(Phase.walk, w.phase);
    try testing.expectEqual(Direction.right, w.pose().?);
    var far: f64 = 0;
    var turned_at: ?i64 = null;
    while (w.phase == .walk) {
        try testing.expect(f.fire(&w, 0.75));
        far = @max(far, f.x);
        if (turned_at == null and w.pose() == .left) turned_at = f.now;
    }
    try testing.expectEqual(@as(f64, 1000), far);
    try testing.expectEqual(@as(f64, 300), f.x);
    try testing.expect(turned_at != null);
    try testing.expect(f.now - 1000 <= dash_max_ms + 2 * motion_tick_ms);
    try testing.expectEqual(Phase.done, w.phase);
    try testing.expect(f.armed == null);
    // Back where it started: nothing to save.
    try testing.expectEqual(@as(usize, 0), f.saves);
    // Still 'dash': no second run until motion changes.
    w.setMotion(f.env(0.75), .dash);
    try testing.expectEqual(Phase.done, w.phase);
}

test "unknown edges: the clamp stops the walk and teaches the edge" {
    var f: Fake = .{ .x = 950, .min_x = 0, .max_x = 1000 };
    var w: Walker = .{};
    w.setMotion(f.env(1), .roam);
    // Force the walk to the right: the target is past the real edge.
    _ = f.fire(&w, 1);
    if (w.leg.?.to_x < 950) {
        // Went left: walk it out, then check the left side stays unknown.
        while (w.phase == .walk) _ = f.fire(&w, 1);
        try testing.expect(w.left_edge == null);
        return;
    }
    while (w.phase == .walk) _ = f.fire(&w, 1);
    try testing.expectEqual(@as(f64, 1000), w.right_edge.?);
    try testing.expectEqual(@as(f64, 1000), f.x);
    try testing.expectEqual(Phase.pause, w.phase);
    try testing.expectEqual(@as(usize, 1), f.saves);
    // Targets now stay inside the known edge.
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        _ = f.fire(&w, 1);
        if (w.leg) |leg| try testing.expect(leg.to_x <= 1000);
        while (w.phase == .walk) _ = f.fire(&w, 1);
    }
}

test "dash with unknown edges runs until the clamp, then comes back" {
    var f: Fake = .{ .x = 700, .min_x = 0, .max_x = 2000 };
    var w: Walker = .{};
    w.setMotion(f.env(1), .dash);
    // Tie on unknown edges: left first, at the plain dash speed.
    try testing.expectEqual(Direction.left, w.pose().?);
    try testing.expectEqual(dash_speed_px_s, w.speed);
    var low: f64 = 700;
    while (w.phase == .walk) {
        _ = f.fire(&w, 1);
        low = @min(low, f.x);
    }
    try testing.expectEqual(@as(f64, 0), low);
    try testing.expectEqual(@as(f64, 0), w.left_edge.?);
    try testing.expectEqual(@as(f64, 700), f.x);
    try testing.expectEqual(Phase.done, w.phase);
}

test "a lagging window read: the walk still saves (and the dash returns to) what it commanded" {
    var f: Fake = .{ .x = 300, .lagging = true };
    var w: Walker = .{ .left_edge = 0, .right_edge = 1000 };
    w.setMotion(f.env(1), .dash);
    while (w.phase == .walk) _ = f.fire(&w, 1);
    // Back where it started: nothing to save, though the window still
    // reads where the previous step left it.
    try testing.expectEqual(@as(f64, 300), f.x);
    try testing.expect(f.read_x.? != 300);
    try testing.expectEqual(@as(usize, 0), f.saves);
    // The window manager settles before the next walk.
    f.read_x = null;
    w.setMotion(f.env(1), .roam);
    _ = f.fire(&w, 1);
    const to = w.leg.?.to_x;
    while (w.phase == .walk) _ = f.fire(&w, 1);
    try testing.expectEqual(to, f.saved_x);
}

test "a stale edge the walk passes is forgotten; no window resets" {
    var f: Fake = .{ .x = 500, .min_x = 0, .max_x = 2000 };
    var w: Walker = .{ .left_edge = 0, .right_edge = 800 };
    w.setMotion(f.env(1), .dash);
    // Farther known end is 0 (500 vs 300): goes left; fine. Now a roam
    // whose target sits on the stale right edge.
    w.stop(f.env(1));
    w.mode = .roam;
    w.beginWalk(f.env(1), f.x, 800, null, 80);
    while (w.phase == .walk) _ = f.fire(&w, 1);
    try testing.expectEqual(@as(f64, 800), f.x);
    try testing.expect(w.right_edge == null);
    // The window went away: everything resets, no timer.
    f.alive = false;
    w.mode = .roam;
    w.phase = .pause;
    _ = f.fire(&w, 1);
    // fire() needs an armed timer; arm one by hand.
    f.armed = 1;
    _ = f.fire(&w, 1);
    try testing.expect(w.mode == null and f.armed == null);
}
