//! TracingInsights Pet (`ti-pet`): Petdex's native pet renderer, driven by
//! the TracingInsights desktop app (docs/DESKTOP_PETS_NATIVE_PLAN.md in the
//! tif1ai repo).
//!
//! The pet has three drivers, highest first:
//!  1. Electron, connected over the per-user socket (ipc.zig): every
//!     render payload comes from the desktop controller, and every
//!     interaction (click, drag, hover, menu) goes back as an event. The
//!     pet decides nothing while driven.
//!  2. The timeline Electron compiled before it quit (timeline.zig, tp-core
//!     lane): entries play in order; local interactions are answered here.
//!  3. Neither (started by hand with `--pet`): idle, plus the same local
//!     interactions.
//!
//! Round 3 (both drivers): a second animation track for the duo partner
//! (`secondAnim`, with its start delay), the v2 look-around rows, walking
//! (`motion`, motion.zig), the sleeping "z z" mark, the answer-ready badge,
//! buttons under the bubble and the click panel. While Electron drives, the
//! buttons only report (`bubbleAction` / `panelAction` events); offline the
//! pet answers them from the timeline (ok, quiet, mute, panel targets).
//!
//! No agent hooks, no :7777 server, no ~/.petdex or ~/.codex scanning, no
//! updater, no settings window: those stay in packages/petdex-desktop-native.

const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const sprite = @import("sprite.zig");
const protocol = @import("protocol.zig");
// Same API on both: a Unix socket on POSIX, a named pipe on Windows.
const ipc = if (builtin.os.tag == .windows) @import("pipe_windows.zig") else @import("ipc.zig");
const core = @import("core.zig");
const motion = @import("motion.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const is_linux = builtin.target.os.tag == .linux;

pub const State = protocol.State;

const canvas_label = "pet-canvas";
const frame_w: f32 = 192;
const frame_h: f32 = 208;
const cols: usize = 8;
/// Gap between duo sprites, as a share of one sprite's width
/// (pet-window.mjs DUO_GAP_RATIO).
const duo_gap_ratio: f32 = 0.05;
/// Linux keeps a transparent band under the sprite (upstream's edge pad).
const pet_edge_pad: f32 = if (is_linux) 8 else 0;
/// First and second sprite frames live in image slots 1..8 and 9..16.
const first_image_base: u64 = 1;
const second_image_base: u64 = 9;

const frame_timer_key: u64 = 1;
const poll_timer_key: u64 = 2;
const drag_watchdog_key: u64 = 3;
/// The duo partner's own animation (`secondAnim`) and its start delay.
const frame2_timer_key: u64 = 4;
/// Walking (motion.zig): one-shot pauses and 34 ms steps, only while a
/// motion is on.
const walk_timer_key: u64 = 5;
/// Socket mailbox poll: fast while Electron is connected (its renders
/// should land within a frame or two), slow otherwise (timeline entries
/// and local reactions only need ~1 s). Each wake costs ~0.13 % CPU.
const poll_fast_ms: u32 = 100;
const poll_slow_ms: u32 = 1000;
const drag_watchdog_ms: u32 = 5000;
/// Local reactions (no Electron): how long a click / hover plays.
const react_ms: i64 = 1200;
const hover_bubble_ms: i64 = 6000;
/// Two clicks this close together are a double-click (Win/mac taps).
const double_click_ms: i64 = 400;
const tap_max_ms: i64 = 400;
const tap_slop_px: f64 = 3;
/// The click panel closes after this long without the pointer on the pet
/// or the panel (SPEC 3a).
const panel_idle_ms: i64 = 20_000;
/// No roaming for this long after a hover, click or drag (behaviour.mjs
/// gates roam the same way; while Electron drives this only bridges the
/// time until its next render).
const roam_after_interaction_ms: i64 = 30_000;
/// Offline, an interaction keeps a sleeping timeline entry awake this long
/// (AMBIENT_SLEEP_MS): the timeline was compiled with nobody touching it.
const awake_after_interaction_ms: i64 = 30 * 60 * 1000;
/// Linux reports pointer enter / leave for the pet and its bubble / panel
/// alike: a re-enter this soon after a leave is the same hover.
const hover_regrace_ms: i64 = 400;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Pet canvas", .accessibility_label = "TracingInsights pet", .gpu_backend = if (is_linux) .software else .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .premultiplied, .gpu_color_space = .srgb, .gpu_vsync = true },
};

// ------------------------------------------------------------------ args

const max_app_args = 8;
const Args = struct {
    pet_dir: ?[]const u8 = null,
    second_dir: ?[]const u8 = null,
    socket: ?[]const u8 = null,
    token_file: ?[]const u8 = null,
    user_data: ?[]const u8 = null,
    app: ?[]const u8 = null,
    app_args: [max_app_args][]const u8 = undefined,
    app_args_len: usize = 0,
    timeline: ?[]const u8 = null,
    login: bool = false,
    size: protocol.Size = .m,
};
var args: Args = .{};
var gpa: std.mem.Allocator = std.heap.page_allocator;
var server: ?*ipc.Server = null;
var launch_env: ?std.process.Environ.Map = null;

fn appLaunch() core.AppLaunch {
    return .{
        .app = args.app,
        .app_args = args.app_args[0..args.app_args_len],
        .env = if (launch_env) |*e| e else null,
    };
}

// ------------------------------------------------------------------ model

pub const Msg = union(enum) {
    frame_tick: native_sdk.EffectTimer,
    frame2_tick: native_sdk.EffectTimer,
    walk_tick: native_sdk.EffectTimer,
    poll_tick: native_sdk.EffectTimer,
    drag_watchdog: native_sdk.EffectTimer,
    frame_clock,
    appearance: native_sdk.platform.Appearance,
    native_drag_started: i8,
    native_drag_ended,
    pointer_click,
    pointer_dblclick,
    pointer_enter,
    pointer_leave,
    bubble_click,
    bubble_action: u8,
    panel_action: u8,
    escape,
    tray_pick: u8,
    pet_pick: u8,
    noop,

    pub const view_unbound = .{ "frame_tick", "frame2_tick", "walk_tick", "poll_tick", "drag_watchdog", "frame_clock", "appearance", "native_drag_started", "native_drag_ended", "pointer_click", "pointer_dblclick", "pointer_enter", "pointer_leave", "escape", "tray_pick" };
};

/// A fixed-size UTF-8 string.
fn Buf(comptime n: usize) type {
    return struct {
        buf: [n]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }

        /// Copy `s` in (clipped on a code point); true when it changed.
        fn set(self: *Self, s: []const u8) bool {
            const t = protocol.clipUtf8(s, n);
            const changed = !std.mem.eql(u8, self.buf[0..self.len], t);
            std.mem.copyForwards(u8, self.buf[0..t.len], t);
            self.len = t.len;
            return changed;
        }
    };
}

const PathBuf = Buf(protocol.max_path_bytes);
const KeyBuf = Buf(protocol.max_play_key_bytes);
const KindBuf = Buf(core.max_bubble_kind_bytes);

const Loaded = struct {
    path: PathBuf = .{},
    row: u8 = 255,
    frames: u8 = 0,
    rows: u8 = 9,
    ok: bool = false,
};

/// One button (bubble action or panel action).
const ActionSlot = struct {
    id: Buf(protocol.max_action_id_bytes) = .{},
    label: Buf(protocol.max_action_label_bytes) = .{},
    /// Offline only: the app path a panel button opens (empty = none).
    target: Buf(512) = .{},
};

/// An animation a driver asked for, with its own copy of the play key.
const AnimStore = struct {
    state: State = .idle,
    row: u8 = 0,
    frames: u8 = 6,
    duration_ms: u32 = 1100,
    once: bool = false,
    still: bool = false,
    delay_ms: u32 = 0,
    key: KeyBuf = .{},

    fn set(self: *AnimStore, a: protocol.Anim) void {
        self.state = a.state;
        self.row = a.row;
        self.frames = a.frames;
        self.duration_ms = a.duration_ms;
        self.once = a.once;
        self.still = a.still;
        self.delay_ms = a.delay_ms;
        _ = self.key.set(a.play_key);
    }

    fn get(self: *const AnimStore) protocol.Anim {
        return .{
            .state = self.state,
            .row = self.row,
            .frames = self.frames,
            .duration_ms = self.duration_ms,
            .once = self.once,
            .still = self.still,
            .play_key = self.key.slice(),
            .delay_ms = self.delay_ms,
        };
    }
};

/// What one sprite is playing.
const Track = struct {
    state: State = .idle,
    row: u8 = 0,
    frames: u8 = 6,
    frame_ms: u32 = 183,
    once: bool = false,
    still: bool = false,
    frame_index: usize = 0,
    key: KeyBuf = .{},
    /// Frame 0 holds this long before the animation starts (secondAnim).
    delay_ms: u32 = 0,
    delay_pending: bool = false,

    /// Play `a`; true when the animation restarts (new key, pose, row or
    /// stillness), as the live renderer does.
    fn take(self: *Track, a: protocol.Anim, reduce_motion: bool) bool {
        const still = a.still or reduce_motion;
        const restart = !std.mem.eql(u8, self.key.slice(), a.play_key) or a.state != self.state or
            a.row != self.row or still != self.still;
        self.state = a.state;
        self.row = a.row;
        self.frames = @max(1, @min(a.frames, 8));
        self.frame_ms = @max(16, a.duration_ms / self.frames);
        self.once = a.once;
        self.still = still;
        _ = self.key.set(a.play_key);
        if (restart) {
            self.frame_index = 0;
            self.delay_ms = a.delay_ms;
            self.delay_pending = a.delay_ms > 0 and !still;
        }
        if (self.frame_index >= self.frames) self.frame_index = 0;
        return restart;
    }

    fn animates(self: *const Track) bool {
        if (self.still or self.frames <= 1) return false;
        return !(self.once and self.frame_index + 1 >= self.frames);
    }

    /// Next frame; false when a one-shot already shows its last.
    fn advance(self: *Track) bool {
        if (self.once and self.frame_index + 1 >= self.frames) return false;
        self.frame_index = (self.frame_index + 1) % self.frames;
        return true;
    }
};

const OfflineSlot = union(enum) {
    none,
    open: PathBuf,
    install_update,
    quit,
    quiet: protocol.QuietKind,
    toggle_pet,
    size: protocol.Size,
    launch_at_login,
};

const MenuSlot = struct {
    id: [protocol.max_menu_id_bytes]u8 = undefined,
    id_len: usize = 0,
    label: [protocol.max_menu_label_bytes]u8 = undefined,
    label_len: usize = 0,
    kind: protocol.MenuKind = .normal,
    checked: bool = false,
    enabled: bool = true,
    offline: OfflineSlot = .none,

    fn idSlice(self: *const MenuSlot) []const u8 {
        return self.id[0..self.id_len];
    }

    /// Neither the tray nor the canvas menu draws check marks: a checked
    /// item gets a "✓ " prefix, composed into `buf`.
    fn display(self: *const MenuSlot, buf: []u8) []const u8 {
        const checkable = self.kind == .checkbox or self.kind == .radio;
        const mark: []const u8 = if (checkable and self.checked) "✓ " else "";
        return std.fmt.bufPrint(buf, "{s}{s}", .{ mark, self.label[0..self.label_len] }) catch self.label[0..self.label_len];
    }
};

const Menu = struct {
    items: [protocol.max_menu_items]MenuSlot = undefined,
    len: usize = 0,
};

/// The floating window next to the pet: the bubble (with or without
/// buttons) or the click panel, which replaces the bubble while open.
const Float = enum {
    none,
    bubble,
    bubble_actions,
    panel,

    fn label(self: Float) []const u8 {
        return switch (self) {
            .none => "",
            .bubble => "bubble",
            .bubble_actions => "bubble-actions",
            .panel => "panel",
        };
    }
};

pub const Model = struct {
    // --- what is shown ---
    /// Electron's show/hide, or Show/Hide pet from the menus offline.
    visible: bool = true,
    /// The current timeline entry hides the pet (visible: false).
    timeline_hidden: bool = false,
    size: protocol.Size = .m,
    duo: bool = false,
    /// What the driver wants the first sprite to play, and the second's
    /// own animation when it has one (else it mirrors the first).
    want_anim: AnimStore = .{},
    want_second_anim: AnimStore = .{},
    want_second_own: bool = false,
    /// The two tracks on screen (the walk overlay and the atlas-row
    /// fallback applied); the second mirrors the first's frames when
    /// `second_mirrors`.
    anim: Track = .{},
    anim2: Track = .{},
    second_mirrors: bool = true,
    /// A frame timer is pending for the track (re-armed when the pet is
    /// shown again with the same animation).
    timer1_on: bool = false,
    timer2_on: bool = false,
    /// Still frame + the "z z" mark (SPEC 2b).
    sleeping: bool = false,
    first: Loaded = .{},
    second: Loaded = .{},
    /// Paths of the sprites to show (first, second).
    want_first: PathBuf = .{},
    want_first_rows: u8 = 9,
    want_second: PathBuf = .{},
    want_second_rows: u8 = 9,
    bubble: [protocol.max_text_bytes]u8 = undefined,
    bubble_len: usize = 0,
    /// Where a bubble click leads while no Electron is connected.
    bubble_target: PathBuf = .{},
    bubble_until_ms: i64 = 0,
    /// Buttons under the bubble (SPEC 2e) and, offline, the bubble's kind
    /// (what `mute` switches off).
    bubble_actions: [protocol.max_bubble_actions]ActionSlot = undefined,
    bubble_actions_len: usize = 0,
    bubble_kind: KindBuf = .{},
    /// Answer-ready badge (SPEC 3b; Electron only).
    badge: bool = false,
    badge_label: Buf(protocol.max_badge_label_bytes) = .{},
    /// Click panel (SPEC 3a). Live: Electron's `panel`; offline: the
    /// timeline's, with the countdown line on top.
    panel_open: bool = false,
    panel_lines: [protocol.max_panel_lines + 1]Buf(protocol.max_panel_line_bytes) = undefined,
    panel_lines_len: usize = 0,
    panel_actions: [protocol.max_panel_actions]ActionSlot = undefined,
    panel_actions_len: usize = 0,
    /// Closes when the pointer has been off the pet and panel until then.
    panel_deadline_ms: i64 = 0,
    /// Live: the pet closed Electron's panel itself (20 s, Escape) and
    /// waits for a render without one before showing the next.
    panel_dismissed: bool = false,
    /// Win/mac: the floating window last declared and the height it got.
    float_shown: Float = .none,
    float_w_applied: f32 = 0,
    float_h_applied: f32 = 0,
    pointer_in_float: bool = false,

    // --- motion (motion.zig) ---
    /// The driver's `motion` (payload or timeline entry).
    motion_want: ?protocol.Motion = null,
    walker: motion.Walker = .{},
    rng: std.Random.DefaultPrng = .init(0),
    /// No roam until then (an interaction).
    roam_block_until_ms: i64 = 0,
    /// A dash ran in the current dash episode (the driver's motion has
    /// stayed 'dash' since): no second run after an interruption.
    dash_spent: bool = false,
    /// fitWindow changed the size: the walk stops, its edges are stale.
    resized: bool = false,

    // --- driver ---
    /// Electron finished hello.
    connected: bool = false,
    /// Electron sent show/hide/render/menu: it decides everything.
    driven: bool = false,
    timeline: ?core.Timeline = null,
    /// Last timeline entry applied (index), to apply each once.
    timeline_entry: ?usize = null,

    // --- local reactions (not driven) ---
    local_state: ?sprite.State = null,
    local_until_ms: i64 = 0,
    quiet_until_ms: i64 = 0,
    /// A sleeping entry shows the pet awake until then (an interaction).
    awake_until_ms: i64 = 0,
    /// Bubble kinds muted offline (and saved for Electron).
    mutes: [core.max_mutes]KindBuf = undefined,
    mutes_len: usize = 0,
    /// The bubble text the user OK'ed: entries repeating it stay quiet.
    dismissed: Buf(protocol.max_text_bytes) = .{},

    // --- pointer / window ---
    dragging: bool = false,
    drag_dir: i8 = 0,
    pet_x: f64 = 0,
    pet_y: f64 = 0,
    have_position: bool = false,
    pending_move: ?protocol.Point = null,
    hover_inside: bool = false,
    pointer_left_ms: i64 = 0,
    press_ms: i64 = 0,
    press_x: f64 = 0,
    press_y: f64 = 0,
    grab_dx: f64 = 0,
    grab_dy: f64 = 0,
    primary_was_down: bool = false,
    last_click_ms: i64 = 0,
    window_w: f32 = 0,
    window_h: f32 = 0,
    window_first_off: f32 = 0,
    window_sprite_w: f32 = 0,

    tray: Menu = .{},
    pet_menu: Menu = .{},
    dark: bool = true,
    reduce_motion: bool = false,
    poll_ms: u32 = 0,
};

pub const Effects = native_sdk.Effects(Msg);
const PetApp = native_sdk.UiApp(Model, Msg);
pub const AppUi = canvas.Ui(Msg);

// ------------------------------------------------------------ geometry

fn spriteW(model: *const Model) f32 {
    return @round(frame_w * model.size.scale());
}

fn spriteH(model: *const Model) f32 {
    return @round(frame_h * model.size.scale());
}

fn duoGap(model: *const Model) f32 {
    return @round(spriteW(model) * duo_gap_ratio);
}

/// The pet is on screen: shown by its driver and not hidden by a timeline
/// entry (that only counts while Electron is not driving).
fn onScreen(model: *const Model) bool {
    return model.visible and (model.driven or !model.timeline_hidden);
}

fn showsDuo(model: *const Model) bool {
    return model.duo and model.second.ok;
}

fn windowW(model: *const Model) f32 {
    const w = spriteW(model);
    return if (showsDuo(model)) w * 2 + duoGap(model) else w;
}

fn windowH(model: *const Model) f32 {
    return spriteH(model) + pet_edge_pad;
}

/// x of the first sprite inside the window (the duo partner is on its left).
fn firstOffset(model: *const Model) f32 {
    return if (showsDuo(model)) spriteW(model) + duoGap(model) else 0;
}

/// Resize for the current size / duo keeping the first sprite's
/// bottom-right corner where it was (pet-window.mjs grows the same way).
fn fitWindow(model: *Model, fx: *Effects) void {
    if (!onScreen(model)) {
        // Hidden: a 1x1 window catches no clicks (closing the last
        // window would quit the app). Its origin stays put, so showing
        // again restores the same top-left.
        if (model.window_w != 1 and fx.resizeWindow("main", 1, 1, .top_left)) {
            model.window_w = 1;
            model.window_h = 1;
        }
        return;
    }
    const w = windowW(model);
    const h = windowH(model);
    if (w == model.window_w and h == model.window_h) return;
    if (model.window_w == 1) model.window_w = 0; // back from hidden: no anchoring
    const before = fx.moveWindow("main", 0, 0, false);
    if (!fx.resizeWindow("main", w, h, .top_left)) return;
    if (before) |b| if (model.window_w > 0) {
        const right = b.x + model.window_first_off + model.window_sprite_w;
        const bottom = b.y + model.window_h - pet_edge_pad;
        const nx = right - firstOffset(model) - spriteW(model);
        const ny = bottom - spriteH(model);
        _ = fx.moveWindow("main", nx - b.x, ny - b.y, true);
    };
    model.window_w = w;
    model.window_h = h;
    model.window_first_off = firstOffset(model);
    model.window_sprite_w = spriteW(model);
    model.resized = true;
}

// ---------------------------------------------------------- sprite frames

const max_sheet_file_bytes: usize = 8 * 1024 * 1024;

/// Decode `path`, cut `frames` cells of `row` and register them in slots
/// `base..base+frames-1`. The decoded sheet is freed right away: holding
/// two decoded sheets would cost ~27 MB for a duo, and a state change
/// decoding again costs a few tens of ms.
fn registerRow(fx: *Effects, path: []const u8, rows_hint: u8, row: u8, frames: u8, base: u64) ?u8 {
    const services = fx.services orelse return null;
    const encoded = readFileAlloc(path, max_sheet_file_bytes) orelse return null;
    defer gpa.free(encoded);
    // The largest accepted sheet is a 2x v2 atlas (3072x4576 RGBA).
    const max_pixels: usize = 3072 * 4576 * 4;
    const pixels = gpa.alloc(u8, max_pixels) catch return null;
    defer gpa.free(pixels);
    const decoded = services.decodeImage(encoded, pixels) catch return null;
    if (decoded.width < cols or decoded.height == 0) return null;
    // v2 sheets are 8x11 cells; the aspect tells them apart like upstream.
    const rows: usize = if (decoded.height * 1536 >= decoded.width * 2288) 11 else if (rows_hint == 11) 11 else 9;
    if (row >= rows) return null;
    const fw = decoded.width / cols;
    const fh = decoded.height / rows;
    if (fw * fh * 4 > native_sdk.max_registered_canvas_image_pixel_bytes) return null;
    const scratch = gpa.alloc(u8, fw * fh * 4) catch return null;
    defer gpa.free(scratch);
    const n: usize = @min(frames, cols);
    for (0..n) |i| {
        const src_x = i * fw;
        const src_y = @as(usize, row) * fh;
        for (0..fh) |y| {
            const src_off = ((src_y + y) * decoded.width + src_x) * 4;
            @memcpy(scratch[y * fw * 4 ..][0 .. fw * 4], pixels[src_off..][0 .. fw * 4]);
        }
        fx.registerImage(base + i, fw, fh, scratch) catch return null;
    }
    return @intCast(rows);
}

/// Make the registered frames match what the tracks show.
fn syncFrames(model: *Model, fx: *Effects) void {
    syncOne(&model.first, &model.want_first, model.want_first_rows, model.anim.row, model.anim.frames, first_image_base, fx);
    if (model.duo and model.want_second.len > 0) {
        const t = if (model.second_mirrors) &model.anim else &model.anim2;
        syncOne(&model.second, &model.want_second, model.want_second_rows, t.row, t.frames, second_image_base, fx);
    } else {
        model.second.ok = false;
    }
}

fn syncOne(loaded: *Loaded, want: *const PathBuf, rows: u8, row: u8, frames: u8, base: u64, fx: *Effects) void {
    if (want.len == 0) {
        loaded.ok = false;
        return;
    }
    const same = loaded.ok and loaded.row == row and loaded.frames >= frames and
        std.mem.eql(u8, loaded.path.slice(), want.slice());
    if (same) return;
    _ = loaded.path.set(want.slice());
    loaded.row = row;
    loaded.frames = frames;
    if (registerRow(fx, want.slice(), rows, row, frames, base)) |r| {
        loaded.rows = r;
        loaded.ok = true;
    } else {
        loaded.ok = false;
        std.debug.print("ti-pet: could not draw {s} (on Linux, WebP needs webp-pixbuf-loader)\n", .{want.slice()});
    }
}

// --------------------------------------------------------- what to show

/// Upstream's frame table for a state (local reactions, the walk and the
/// row fallback, where no payload says how to play it).
fn localAnim(state: sprite.State, key: []const u8) protocol.Anim {
    const def = sprite.stateDef(state);
    var total: u32 = 0;
    for (def.frames) |f| total += f.dur_ms;
    const once = state == .jumping or state == .waving or state == .failed;
    return .{ .state = .fromSprite(state), .row = @intCast(def.row), .frames = @intCast(def.frames.len), .duration_ms = total, .once = once, .play_key = key };
}

/// A row the sheet lacks (v2 look-around on a 9-row sheet) plays idle
/// (SPEC 4b: also the duo partner's fallback).
fn fitRows(a: protocol.Anim, rows: u8, key: []const u8) protocol.Anim {
    if (a.row < rows) return a;
    var idle = localAnim(.idle, key);
    idle.still = a.still;
    return idle;
}

fn setWant(model: *Model, first: protocol.Anim, second: ?protocol.Anim) void {
    model.want_anim.set(first);
    if (second) |s| {
        model.want_second_anim.set(s);
        model.want_second_own = true;
    } else model.want_second_own = false;
}

/// Put what the driver wants on screen: the walk overlay (both sprites
/// run), the row fallback per sheet, frames, window size, frame timers.
fn applyTracks(model: *Model, fx: *Effects) void {
    var first = model.want_anim.get();
    var second: ?protocol.Anim = if (model.want_second_own) model.want_second_anim.get() else null;
    if (model.walker.pose()) |dir| {
        first = if (dir == .left) localAnim(.@"running-left", "walk:left") else localAnim(.@"running-right", "walk:right");
        second = null;
    }
    first = fitRows(first, model.want_first_rows, "fallback");
    const restart1 = model.anim.take(first, model.reduce_motion);
    var mirrors = true;
    var restart2 = false;
    if (second) |s| {
        mirrors = false;
        restart2 = model.anim2.take(fitRows(s, model.want_second_rows, "fallback:second"), model.reduce_motion);
    } else if (first.row >= model.want_second_rows) {
        mirrors = false;
        restart2 = model.anim2.take(fitRows(first, model.want_second_rows, "fallback:second"), model.reduce_motion);
    }
    if (mirrors != model.second_mirrors) restart2 = true;
    model.second_mirrors = mirrors;
    syncFrames(model, fx);
    fitWindow(model, fx);
    if (restart1 or !model.timer1_on) armFrameTimer(model, fx);
    if (restart2 or !model.timer2_on) armFrame2Timer(model, fx);
}

/// applyTracks, then stop a walk the resize made stale (its edges too).
fn refreshAnim(model: *Model, fx: *Effects) void {
    applyTracks(model, fx);
    if (model.resized) {
        model.resized = false;
        model.walker.forgetEdges();
        walk(model, fx, .interrupt);
    }
}

fn setBubble(model: *Model, text: ?[]const u8, target: ?[]const u8, until_ms: i64) void {
    const t = protocol.clipUtf8(text orelse "", model.bubble.len);
    @memcpy(model.bubble[0..t.len], t);
    model.bubble_len = t.len;
    _ = model.bubble_target.set(target orelse "");
    model.bubble_until_ms = until_ms;
    model.bubble_actions_len = 0;
    model.bubble_kind.len = 0;
}

/// Buttons for the bubble set just before (none without a bubble).
fn setBubbleActions(model: *Model, actions: []const protocol.Action, kind: ?[]const u8) void {
    model.bubble_actions_len = 0;
    _ = model.bubble_kind.set(kind orelse "");
    if (model.bubble_len == 0) return;
    for (actions) |a| {
        if (model.bubble_actions_len >= model.bubble_actions.len) break;
        var slot: ActionSlot = .{};
        _ = slot.id.set(a.id);
        _ = slot.label.set(a.label);
        model.bubble_actions[model.bubble_actions_len] = slot;
        model.bubble_actions_len += 1;
    }
}

fn setBadge(model: *Model, badge: ?protocol.Badge) void {
    model.badge = badge != null;
    _ = model.badge_label.set(if (badge) |b| b.label else "");
}

fn armFrameTimer(model: *Model, fx: *Effects) void {
    fx.cancelTimer(frame_timer_key);
    model.timer1_on = false;
    if (!onScreen(model) or !model.anim.animates()) return;
    fx.startTimer(.{
        .key = frame_timer_key,
        .interval_ms = model.anim.frame_ms,
        .mode = .one_shot,
        .on_fire = Effects.timerMsg(.frame_tick),
    });
    model.timer1_on = true;
}

/// The duo partner's own track: its start delay, then its frames.
fn armFrame2Timer(model: *Model, fx: *Effects) void {
    fx.cancelTimer(frame2_timer_key);
    model.timer2_on = false;
    if (model.second_mirrors or !model.duo or !onScreen(model)) return;
    const t = &model.anim2;
    const interval = if (t.delay_pending) t.delay_ms else if (t.animates()) t.frame_ms else return;
    fx.startTimer(.{
        .key = frame2_timer_key,
        .interval_ms = interval,
        .mode = .one_shot,
        .on_fire = Effects.timerMsg(.frame2_tick),
    });
    model.timer2_on = true;
}

fn armFrameTimers(model: *Model, fx: *Effects) void {
    armFrameTimer(model, fx);
    armFrame2Timer(model, fx);
}

fn cancelFrameTimers(model: *Model, fx: *Effects) void {
    fx.cancelTimer(frame_timer_key);
    fx.cancelTimer(frame2_timer_key);
    model.timer1_on = false;
    model.timer2_on = false;
}

/// Not driven: the timeline entry or idle, unless a local reaction plays.
fn showUndriven(model: *Model, fx: *Effects) void {
    if (model.driven) return;
    const now = fx.wallMs();
    defer updateMotion(model, fx);
    if (model.local_state) |state| {
        if (now < model.local_until_ms) {
            setWant(model, localAnim(state, "local"), null);
            model.sleeping = false;
            refreshAnim(model, fx);
            return;
        }
        model.local_state = null;
    }
    if (model.timeline) |*tl| {
        if (tl.entryAt(now)) |hit| {
            const entry = hit.entry;
            const quiet = now < model.quiet_until_ms;
            if (model.timeline_entry == null or model.timeline_entry.? != hit.index) {
                model.timeline_entry = hit.index;
                applyEntryBubble(model, entry, quiet, now);
            }
            model.timeline_hidden = !entry.visible;
            if (!entry.visible) {
                setMotionWant(model, null);
                cancelFrameTimers(model, fx);
                fitWindow(model, fx);
                return;
            }
            model.duo = entry.duo;
            // An interaction offline wakes a sleeping entry for a while.
            const asleep = entry.sleeping and now >= model.awake_until_ms;
            model.sleeping = asleep;
            if (quiet) {
                // behaviour.mjs: quiet → idle, no bubbles, no walking.
                var idle = localAnim(.idle, "quiet");
                idle.still = asleep or (entry.still and !entry.sleeping);
                setWant(model, idle, null);
                setMotionWant(model, null);
            } else if (entry.sleeping and !asleep) {
                setWant(model, localAnim(.idle, "awake"), null);
                setMotionWant(model, null);
            } else {
                setWant(model, .{
                    .state = entry.state,
                    .row = entry.row,
                    .frames = entry.frames,
                    .duration_ms = entry.duration_ms,
                    .once = entry.once,
                    .still = entry.still,
                    .play_key = entry.play_key,
                }, if (entry.duo) entry.second_anim else null);
                setMotionWant(model, entry.motion);
            }
            refreshAnim(model, fx);
            return;
        }
    }
    setWant(model, localAnim(.idle, "idle"), null);
    model.sleeping = false;
    setMotionWant(model, null);
    refreshAnim(model, fx);
}

/// A new timeline entry's bubble, once: quiet, a hidden pet, a muted kind
/// or the bubble the user just OK'ed show none. A hover line still showing
/// wins (behaviour.mjs ranks hover first); the entry's bubble comes back
/// when it expires (poll).
fn applyEntryBubble(model: *Model, entry: core.Entry, quiet: bool, now: i64) void {
    if (model.bubble_until_ms > now) return;
    // An open panel holds new bubbles back (and their moments unreported);
    // closing it applies the entry again.
    if (model.panel_open) {
        setBubble(model, null, null, 0);
        return;
    }
    const text = entry.bubble orelse {
        model.dismissed.len = 0;
        setBubble(model, null, null, 0);
        return;
    };
    const shows = entry.visible and model.visible and !quiet;
    const muted = if (entry.bubble_kind) |k| isMuted(model, k) else false;
    if (!shows or muted or std.mem.eql(u8, model.dismissed.slice(), text)) {
        setBubble(model, null, null, 0);
        return;
    }
    model.dismissed.len = 0;
    setBubble(model, text, entry.bubble_target, 0);
    setBubbleActions(model, entry.bubble_actions, entry.bubble_kind);
    // Only a bubble that really showed counts; one eaten by quiet or a
    // hidden pet stays unreported so Electron shows it again.
    if (entry.moment) |m| core.recordMoment(args.user_data, m);
}

fn isMuted(model: *const Model, kind: []const u8) bool {
    for (model.mutes[0..model.mutes_len]) |*m| if (std.mem.eql(u8, m.slice(), kind)) return true;
    return false;
}

fn addMute(model: *Model, kind: []const u8) void {
    if (isMuted(model, kind) or model.mutes_len >= model.mutes.len) return;
    var m: KindBuf = .{};
    _ = m.set(kind);
    model.mutes[model.mutes_len] = m;
    model.mutes_len += 1;
}

// ---------------------------------------------------------------- walking

const WalkCtx = struct { model: *Model, fx: *Effects };

fn walkCtx(p: *anyopaque) *WalkCtx {
    return @ptrCast(@alignCast(p));
}

fn walkPosition(p: *anyopaque) ?f64 {
    const c = walkCtx(p);
    const r = c.fx.moveWindow("main", 0, 0, false) orelse return null;
    return r.x;
}

fn walkMove(p: *anyopaque, x: f64) ?motion.Landed {
    const c = walkCtx(p);
    const cur = c.fx.moveWindow("main", 0, 0, false) orelse return null;
    // clamp: the host keeps the window inside the work area and says so.
    const r = c.fx.moveWindow("main", x - cur.x, 0, true) orelse return null;
    c.model.pet_x = r.x;
    c.model.pet_y = r.y;
    c.model.have_position = true;
    return .{ .x = r.x, .hit = r.hit_x };
}

fn walkSave(p: *anyopaque, window_x: f64) void {
    const c = walkCtx(p);
    // y from the window (walks are horizontal); x as the walker sent it.
    readPosition(c.model, c.fx);
    if (!c.model.have_position) return;
    c.model.pet_x = window_x;
    const x = window_x + firstOffset(c.model);
    if (c.model.connected and c.model.driven) {
        send(protocol.Position{ .x = x, .y = c.model.pet_y, .secondSide = .left, .walk = true });
    } else core.savePosition(args.user_data, x, c.model.pet_y);
}

fn walkArm(p: *anyopaque, ms: u32) void {
    walkCtx(p).fx.startTimer(.{ .key = walk_timer_key, .interval_ms = ms, .mode = .one_shot, .on_fire = Effects.timerMsg(.walk_tick) });
}

fn walkDisarm(p: *anyopaque) void {
    walkCtx(p).fx.cancelTimer(walk_timer_key);
}

const WalkOp = union(enum) { tick, interrupt, stop, set: ?protocol.Motion };

/// One walker call; the pose it leaves (running or not) goes on screen.
fn walk(model: *Model, fx: *Effects, op: WalkOp) void {
    const before = model.walker.pose();
    var ctx: WalkCtx = .{ .model = model, .fx = fx };
    const env: motion.Env = .{
        .ctx = &ctx,
        .now_ms = fx.wallMs(),
        .random = model.rng.random(),
        .scale = model.size.scale(),
        .position = walkPosition,
        .move_to = walkMove,
        .save = walkSave,
        .arm = walkArm,
        .disarm = walkDisarm,
    };
    switch (op) {
        .tick => model.walker.tick(env),
        .interrupt => model.walker.interrupt(env),
        .stop => model.walker.stop(env),
        .set => |m| {
            if (m == .dash and model.walker.mode != .dash) model.dash_spent = true;
            model.walker.setMotion(env, m);
        },
    }
    if (!std.meta.eql(before, model.walker.pose())) applyTracks(model, fx);
}

/// The driver's motion minus what the pet sees itself: hidden, dragged,
/// hovered, panel open, reduce motion, asleep, just touched; offline also
/// quiet, a local reaction or bubble (the timeline's own gates are
/// compiled in). A dash runs once per moment.
fn effectiveMotion(model: *const Model, now: i64) ?protocol.Motion {
    const want = model.motion_want orelse return null;
    if (!onScreen(model) or !model.first.ok or model.dragging or model.reduce_motion or model.sleeping) return null;
    if (want == .dash) return if (model.dash_spent and model.walker.mode != .dash) null else .dash;
    if (model.hover_inside or model.panel_open or now < model.roam_block_until_ms) return null;
    if (!model.driven) {
        if (now < model.quiet_until_ms or model.local_state != null or model.bubble_len > 0) return null;
    }
    return .roam;
}

/// The driver's motion; leaving 'dash' ends the dash episode.
fn setMotionWant(model: *Model, m: ?protocol.Motion) void {
    model.motion_want = m;
    if (m != .dash) model.dash_spent = false;
}

fn updateMotion(model: *Model, fx: *Effects) void {
    walk(model, fx, .{ .set = effectiveMotion(model, fx.wallMs()) });
}

/// A hover, click or drag: stop walking now and roam no sooner than
/// `roam_after_interaction_ms`; offline it also wakes a sleeping pet.
fn touched(model: *Model, fx: *Effects) void {
    const now = fx.wallMs();
    model.roam_block_until_ms = now + roam_after_interaction_ms;
    if (!model.driven) model.awake_until_ms = now + awake_after_interaction_ms;
    walk(model, fx, .interrupt);
    updateMotion(model, fx);
}

// ------------------------------------------------------------- panel

/// Live: Electron's panel (it decides open / closed).
fn setLivePanel(model: *Model, panel: ?protocol.Panel, now: i64) void {
    const p = panel orelse {
        model.panel_open = false;
        model.panel_dismissed = false;
        return;
    };
    if (model.panel_dismissed) return;
    if (!model.panel_open) model.panel_deadline_ms = now + panel_idle_ms;
    model.panel_open = true;
    model.panel_lines_len = 0;
    for (p.lines) |line| addPanelLine(model, line);
    model.panel_actions_len = 0;
    for (p.actions) |a| addPanelAction(model, a.id, a.label, "");
}

fn addPanelLine(model: *Model, line: []const u8) void {
    if (model.panel_lines_len >= model.panel_lines.len) return;
    var b: Buf(protocol.max_panel_line_bytes) = .{};
    _ = b.set(line);
    model.panel_lines[model.panel_lines_len] = b;
    model.panel_lines_len += 1;
}

fn addPanelAction(model: *Model, id: []const u8, label: []const u8, target: []const u8) void {
    if (model.panel_actions_len >= model.panel_actions.len) return;
    var slot: ActionSlot = .{};
    _ = slot.id.set(id);
    _ = slot.label.set(label);
    _ = slot.target.set(target);
    model.panel_actions[model.panel_actions_len] = slot;
    model.panel_actions_len += 1;
}

/// Offline: the timeline's static panel at `now` (countdown line on top,
/// buttons inside their windows). False when it has nothing to show.
fn fillOfflinePanel(model: *Model, now: i64) bool {
    model.panel_lines_len = 0;
    model.panel_actions_len = 0;
    const tl = &(model.timeline orelse return false);
    const panel = tl.panel() orelse return false;
    var buf: [256]u8 = undefined;
    if (tl.panelCountdown(&buf, now)) |line| addPanelLine(model, line);
    for (panel.lines) |line| addPanelLine(model, line);
    for (panel.actions) |a| {
        if (a.shownAt(now)) addPanelAction(model, a.id, a.label, a.target orelse "");
    }
    return model.panel_lines_len > 0 or model.panel_actions_len > 0;
}

/// The pet closes the panel itself (20 s, Escape): live, Electron hears
/// `panelAction close` (L4's PANEL_CLOSE_ID) and the panel stays shut
/// until a render drops it.
fn closePanelHere(model: *Model) void {
    if (!model.panel_open) return;
    if (model.connected and model.driven) {
        model.panel_open = false;
        model.panel_dismissed = true;
        send(protocol.Event{ .event = .panelAction, .id = protocol.panel_close_id });
    } else closeOfflinePanel(model);
}

/// Offline: the entry's bubble (held back while the panel was open, as
/// the controller holds once-only moments) is applied again.
fn closeOfflinePanel(model: *Model) void {
    if (!model.panel_open) return;
    model.panel_open = false;
    model.timeline_entry = null;
}

fn toggleOfflinePanel(model: *Model, now: i64) void {
    if (model.panel_open) return closeOfflinePanel(model);
    if (!fillOfflinePanel(model, now)) return;
    model.panel_open = true;
    model.panel_deadline_ms = now + panel_idle_ms;
}

// ------------------------------------------------------------ messages

fn send(message: anytype) void {
    const s = server orelse return;
    var buf: [1024]u8 = undefined;
    const line = protocol.encode(&buf, message) orelse return;
    _ = s.send(line);
}

fn handleLine(model: *Model, line: []const u8, fx: *Effects) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const msg = protocol.parseLine(arena.allocator(), line) catch {
        send(protocol.Error{ .code = "bad-message", .message = "Line rejected." });
        return;
    };
    switch (msg) {
        .hello => {},
        .show => |s| {
            model.driven = true;
            model.visible = true;
            model.size = s.size;
            model.duo = s.duo;
            if (s.position) |p| model.pending_move = p;
            walk(model, fx, .stop);
            model.walker.forgetEdges();
            syncFrames(model, fx);
            fitWindow(model, fx);
            armFrameTimers(model, fx);
            placeWindow(model, fx);
        },
        .hide => {
            model.driven = true;
            model.visible = false;
            setBubble(model, null, null, 0);
            model.panel_open = false;
            walk(model, fx, .stop);
            cancelFrameTimers(model, fx);
            fitWindow(model, fx);
        },
        .render => |r| {
            model.driven = true;
            model.size = r.size;
            model.duo = r.second != null;
            _ = model.want_first.set(r.atlas.path);
            model.want_first_rows = r.atlas.rows;
            if (r.second) |second| {
                _ = model.want_second.set(second.path);
                model.want_second_rows = second.rows;
            }
            setBubble(model, r.bubble, null, 0);
            setBubbleActions(model, r.bubble_actions, null);
            setBadge(model, r.badge);
            setLivePanel(model, r.panel, fx.wallMs());
            model.sleeping = r.sleeping;
            setMotionWant(model, r.motion);
            setWant(model, r.anim(), r.second_anim);
            defer placeWindow(model, fx);
            refreshAnim(model, fx);
            updateMotion(model, fx);
        },
        .menu => |m| {
            model.driven = true;
            copyMenu(&model.tray, m.tray);
            copyMenu(&model.pet_menu, m.pet);
        },
        .handoff => |path| {
            if (core.Timeline.loadInside(gpa, path, args.user_data)) |tl| {
                if (model.timeline) |*old| old.deinit();
                model.timeline = tl;
                model.timeline_entry = null;
                applyTimelineSprites(model);
                // Electron merged our native state before compiling, so
                // its quiet wins (a quiet ended in the app must end), and
                // its settings carry our mutes now.
                model.quiet_until_ms = tl.quiet_until_ms;
                model.mutes_len = 0;
                model.dismissed.len = 0;
                core.noteHandoff();
                send(protocol.Ack{});
            } else |_| {
                send(protocol.Error{ .code = "timeline", .message = "Timeline rejected." });
            }
        },
        .quit => quitPet(),
    }
}

fn applyTimelineSprites(model: *Model) void {
    const tl = &(model.timeline orelse return);
    if (tl.first) |first| {
        _ = model.want_first.set(first.path);
        model.want_first_rows = first.rows;
    }
    if (tl.second) |second| {
        _ = model.want_second.set(second.path);
        model.want_second_rows = second.rows;
    } else model.want_second.len = 0;
    model.size = tl.size;
}

fn copyMenu(dst: *Menu, items: []const protocol.MenuItem) void {
    dst.len = 0;
    for (items) |item| {
        if (dst.len >= dst.items.len) break;
        var slot: MenuSlot = .{ .kind = item.kind, .checked = item.checked, .enabled = item.enabled };
        const id = protocol.clipUtf8(item.id, slot.id.len);
        @memcpy(slot.id[0..id.len], id);
        slot.id_len = id.len;
        const label = protocol.clipUtf8(item.label, slot.label.len);
        @memcpy(slot.label[0..label.len], label);
        slot.label_len = label.len;
        slot.offline = if (item.offline) |o| switch (o) {
            .open => |p| blk: {
                var pb: PathBuf = .{};
                _ = pb.set(p);
                break :blk .{ .open = pb };
            },
            .install_update => .install_update,
            .quit => .quit,
            .quiet => |k| .{ .quiet = k },
            .toggle_pet => .toggle_pet,
            .size => |s| .{ .size = s },
            .launch_at_login => .launch_at_login,
        } else .none;
        dst.items[dst.len] = slot;
        dst.len += 1;
    }
}

/// Menus before any Electron has connected (started at login): enough to
/// get to the app, hide the pet or quit.
fn defaultMenus(model: *Model) void {
    const items = [_]protocol.MenuItem{
        .{ .id = "tray.open-tracinginsights", .label = "Open TracingInsights", .offline = .{ .open = "/" } },
        .{ .id = "tray.choose-pet", .label = "Choose pet…", .offline = .{ .open = "/settings/pets" } },
        .{ .id = "tray.hide-pet", .label = "Show/Hide pet", .offline = .toggle_pet },
        .{ .id = "tray.quiet.for-1-hour", .label = "Quiet for 1 hour", .offline = .{ .quiet = .@"1h" } },
        .{ .id = "tray.sep-1", .label = "", .kind = .separator },
        .{ .id = "tray.quit", .label = "Quit", .offline = .quit },
    };
    copyMenu(&model.tray, &items);
    copyMenu(&model.pet_menu, items[0..4]);
}

// ------------------------------------------------------------ interaction

fn onClick(model: *Model, fx: *Effects) void {
    touched(model, fx);
    if (model.connected and model.driven) return send(protocol.Event{ .event = .click });
    // Offline: jump, and the panel opens / closes (SPEC 3a).
    toggleOfflinePanel(model, fx.wallMs());
    react(model, .jumping, fx);
}

fn onDoubleClick(model: *Model, fx: *Effects) void {
    touched(model, fx);
    if (model.connected and model.driven) return send(protocol.Event{ .event = .dblclick });
    core.openApp(appLaunch(), "/");
}

fn onHover(model: *Model, fx: *Effects) void {
    touched(model, fx);
    if (model.connected and model.driven) return send(protocol.Event{ .event = .hover });
    const now = fx.wallMs();
    if (now < model.quiet_until_ms) return;
    // The panel stays in front of a hover line.
    if (!model.panel_open) {
        var buf: [256]u8 = undefined;
        const text: ?[]const u8 = if (model.timeline) |*tl|
            (if (showsDuo(model)) tl.duo_text else null) orelse core.hoverText(&buf, tl, now)
        else
            null;
        if (text) |t| setBubble(model, t, if (model.timeline) |*tl| tl.calendar_target else "/", now + hover_bubble_ms);
    }
    react(model, .waving, fx);
}

fn onBubbleClick(model: *Model, fx: *Effects) void {
    touched(model, fx);
    if (model.connected and model.driven) return send(protocol.Event{ .event = .bubbleClick });
    const target = model.bubble_target.slice();
    if (protocol.appPathOk(target)) core.openApp(appLaunch(), target);
}

/// A button under the bubble. Live it only reports; offline: ok dismisses,
/// quiet-* quiets like the tray, mute silences the bubble's kind for the
/// rest of the timeline and records it for Electron.
fn onBubbleAction(model: *Model, index: u8, fx: *Effects) void {
    if (index >= model.bubble_actions_len) return;
    const id = model.bubble_actions[index].id.slice();
    if (model.connected and model.driven) return send(protocol.Event{ .event = .bubbleAction, .id = id });
    if (std.mem.eql(u8, id, "quiet-1h")) return setQuiet(model, .@"1h", fx);
    if (std.mem.eql(u8, id, "quiet-session")) return setQuiet(model, .session, fx);
    if (std.mem.eql(u8, id, "mute")) {
        const kind = model.bubble_kind.slice();
        if (kind.len > 0) {
            addMute(model, kind);
            core.saveMute(args.user_data, kind);
            if (std.mem.eql(u8, kind, "calendar")) if (model.timeline) |*tl| tl.muteSessionReactions();
        }
    } else if (!std.mem.eql(u8, id, "ok")) return;
    _ = model.dismissed.set(model.bubble[0..model.bubble_len]);
    setBubble(model, null, null, 0);
    updateMotion(model, fx);
}

/// A panel button. Live it only reports; offline it opens its target.
fn onPanelAction(model: *Model, index: u8, fx: *Effects) void {
    if (index >= model.panel_actions_len) return;
    const slot = &model.panel_actions[index];
    if (model.connected and model.driven) return send(protocol.Event{ .event = .panelAction, .id = slot.id.slice() });
    // Copy the path out first: closing may refill the panel's slots.
    var target: Buf(512) = .{};
    _ = target.set(slot.target.slice());
    closeOfflinePanel(model);
    if (protocol.appPathOk(target.slice())) core.openApp(appLaunch(), target.slice());
    showUndriven(model, fx);
}

fn react(model: *Model, state: sprite.State, fx: *Effects) void {
    model.local_state = state;
    model.local_until_ms = fx.wallMs() + react_ms;
    showUndriven(model, fx);
}

fn dragStarted(model: *Model, dir: i8, fx: *Effects) void {
    model.dragging = true;
    model.drag_dir = dir;
    touched(model, fx);
    fx.startTimer(.{ .key = drag_watchdog_key, .interval_ms = drag_watchdog_ms, .mode = .one_shot, .on_fire = Effects.timerMsg(.drag_watchdog) });
    if (model.connected and model.driven) {
        if (dir != 0) send(protocol.Event{ .event = .drag, .dx = @floatFromInt(@as(i32, dir) * 12), .dy = 0 });
        return;
    }
    model.local_state = if (dir < 0) .@"running-left" else .@"running-right";
    model.local_until_ms = std.math.maxInt(i64);
    showUndriven(model, fx);
}

fn readPosition(model: *Model, fx: *Effects) void {
    // X11 / Win / mac; Wayland cannot report a window position.
    const r = fx.moveWindow("main", 0, 0, false) orelse return;
    model.pet_x = r.x;
    model.pet_y = r.y;
    model.have_position = true;
}

fn dragEnded(model: *Model, fx: *Effects) void {
    if (!model.dragging) return;
    model.dragging = false;
    // Maybe another display now: the walk's edges are unknown again.
    model.walker.forgetEdges();
    fx.cancelTimer(drag_watchdog_key);
    if (is_linux) readPosition(model, fx);
    if (model.connected and model.driven) {
        // position goes BEFORE dragEnd (native-protocol.mjs).
        if (model.have_position) send(protocol.Position{ .x = model.pet_x + firstOffset(model), .y = model.pet_y, .secondSide = .left });
        send(protocol.Event{ .event = .dragEnd });
        updateMotion(model, fx);
        return;
    }
    if (model.have_position) core.savePosition(args.user_data, model.pet_x + firstOffset(model), model.pet_y);
    model.local_state = null;
    showUndriven(model, fx);
}

/// Quiet from the menus or a bubble button while no Electron is connected.
fn setQuiet(model: *Model, kind: protocol.QuietKind, fx: *Effects) void {
    const now = fx.wallMs();
    model.quiet_until_ms = switch (kind) {
        .off => 0,
        .@"1h" => now + 60 * 60 * 1000,
        .session => if (model.timeline) |*tl| tl.sessionEndAfter(now) orelse now else now,
    };
    core.saveQuiet(args.user_data, if (model.quiet_until_ms > now) model.quiet_until_ms else null);
    setBubble(model, null, null, 0);
    model.timeline_entry = null;
    showUndriven(model, fx);
}

fn pick(model: *Model, menu: *Menu, index: u8, fx: *Effects) void {
    if (index >= menu.len) return;
    const item = &menu.items[index];

    if (item.kind == .separator or !item.enabled) return;
    // Connected = Electron decides, even before it took over the pet:
    // exiting on our own Quit would look like a crash and be respawned.
    if (model.connected) {
        const toggles = item.kind == .checkbox;
        send(protocol.MenuAction{ .id = item.idSlice(), .checked = if (toggles) !item.checked else null });
        return;
    }
    switch (item.offline) {
        .none => {},
        .open => |p| core.openApp(appLaunch(), p.slice()),
        .install_update => core.installUpdate(appLaunch()),
        .quit => quitPet(),
        .quiet => |kind| setQuiet(model, kind, fx),
        .toggle_pet => {
            model.visible = !model.visible;
            core.saveEnabled(args.user_data, model.visible);
            if (model.visible) showUndriven(model, fx) else {
                cancelFrameTimers(model, fx);
                model.panel_open = false;
                walk(model, fx, .stop);
            }
            fitWindow(model, fx);
        },
        .size => |s| {
            model.size = s;
            core.saveSize(args.user_data, s);
            fitWindow(model, fx);
            refreshAnim(model, fx);
        },
        .launch_at_login => {
            // The current value lives in Electron's menu item.
            core.saveLaunchAtLogin(args.user_data, !item.checked);
            item.checked = !item.checked;
        },
    }
}

fn placeWindow(model: *Model, fx: *Effects) void {
    const want = model.pending_move orelse return;
    // Native Wayland has no client-side positioning: the compositor places it.
    const cur = fx.moveWindow("main", 0, 0, false) orelse {
        model.pending_move = null;
        return;
    };
    // `position` is the first sprite's top-left (native-pet.mjs groupRect).
    const moved = fx.moveWindow("main", want.x - firstOffset(model) - cur.x, want.y - cur.y, true);
    model.pending_move = null;
    if (!is_linux) if (moved) |m| {
        model.pet_x = m.x;
        model.pet_y = m.y;
        model.have_position = true;
    };
}

fn quitPet() void {
    if (server) |s| s.shutdown();
    switch (builtin.os.tag) {
        .windows => std.process.exit(0),
        .linux => _ = std.os.linux.kill(std.os.linux.getpid(), .TERM),
        else => _ = std.c.kill(std.c.getpid(), .TERM),
    }
}

// ---------------------------------------------------------------- update

pub fn boot(model: *Model, fx: *Effects) void {
    model.size = args.size;
    model.rng = .init(@bitCast(fx.wallMs()));
    defaultMenus(model);
    if (args.pet_dir) |dir| {
        var buf: [protocol.max_path_bytes]u8 = undefined;
        if (core.petSheetPath(&buf, dir)) |p| _ = model.want_first.set(p);
    }
    if (args.second_dir) |dir| {
        var buf: [protocol.max_path_bytes]u8 = undefined;
        if (core.petSheetPath(&buf, dir)) |p| {
            _ = model.want_second.set(p);
            model.duo = true;
        }
    }
    if (args.timeline) |path| {
        if (core.Timeline.loadInside(gpa, path, args.user_data)) |tl| {
            model.timeline = tl;
            applyTimelineSprites(model);
            model.quiet_until_ms = tl.quiet_until_ms;
        } else |_| {}
    }
    if (core.loadNativeState(args.user_data)) |st| {
        if (st.enabled) |e| model.visible = e;
        if (st.size) |s| model.size = s;
        if (st.quiet_until_ms) |q| model.quiet_until_ms = q;
        // Muted offline before a restart of the pet: still muted.
        for (st.mutes[0..st.mutes_len]) |*m| addMute(model, m.kind());
        if (model.timeline) |*tl| if (isMuted(model, "calendar")) tl.muteSessionReactions();
    }
    setPollRate(model, fx);
    showUndriven(model, fx);
    // Started at login with nothing it can draw: hand over to the app.
    if (args.login and !model.first.ok) core.startHidden(appLaunch());
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .frame_tick => |timer| {
            if (timer.outcome != .fired) return;
            model.timer1_on = false;
            if (!model.anim.advance()) return;
            armFrameTimer(model, fx);
        },
        .frame2_tick => |timer| {
            if (timer.outcome != .fired) return;
            model.timer2_on = false;
            if (model.anim2.delay_pending) {
                model.anim2.delay_pending = false;
            } else if (!model.anim2.advance()) return;
            armFrame2Timer(model, fx);
        },
        .walk_tick => |timer| {
            if (timer.outcome != .fired) return;
            walk(model, fx, .tick);
        },
        .poll_tick => |timer| {
            if (timer.outcome != .fired) return;
            poll(model, fx);
        },
        .drag_watchdog => |timer| {
            if (timer.outcome != .fired) return;
            dragEnded(model, fx);
        },
        .frame_clock => frameClock(model, fx),
        .appearance => |a| {
            model.dark = a.color_scheme == .dark;
            model.reduce_motion = a.reduce_motion;
        },
        .native_drag_started => |dir| dragStarted(model, dir, fx),
        .native_drag_ended => dragEnded(model, fx),
        .pointer_click => onClick(model, fx),
        .pointer_dblclick => onDoubleClick(model, fx),
        .pointer_enter => {
            const now = fx.wallMs();
            // Back from the bubble / panel (or a flicker): the same hover.
            const fresh = now - model.pointer_left_ms > hover_regrace_ms;
            if (!model.hover_inside and !model.dragging and fresh) onHover(model, fx);
            model.hover_inside = true;
            updateMotion(model, fx);
        },
        .pointer_leave => {
            model.hover_inside = false;
            model.pointer_left_ms = fx.wallMs();
        },
        .bubble_click => onBubbleClick(model, fx),
        .bubble_action => |i| onBubbleAction(model, i, fx),
        .panel_action => |i| onPanelAction(model, i, fx),
        .escape => if (model.panel_open) {
            closePanelHere(model);
            showUndriven(model, fx);
            updateMotion(model, fx);
        },
        .tray_pick => |i| pick(model, &model.tray, i, fx),
        .pet_pick => |i| pick(model, &model.pet_menu, i, fx),
        .noop => {},
    }
}

fn setPollRate(model: *Model, fx: *Effects) void {
    const want = if (model.connected) poll_fast_ms else poll_slow_ms;
    if (model.poll_ms == want) return;
    fx.cancelTimer(poll_timer_key);
    fx.startTimer(.{ .key = poll_timer_key, .interval_ms = want, .mode = .repeating, .on_fire = Effects.timerMsg(.poll_tick) });
    model.poll_ms = want;
}

fn poll(model: *Model, fx: *Effects) void {
    defer setPollRate(model, fx);
    const now = fx.wallMs();
    core.reap();
    if (server) |s| {
        var lines: [64][]u8 = undefined;
        var n: usize = 0;
        const status = s.take(&lines, &n);
        if (status.connected) {
            model.connected = true;
            // Taking over waits for the first show/hide/render/menu.
            model.driven = false;
        }
        for (lines[0..n]) |line| {
            handleLine(model, line, fx);
            gpa.free(line);
        }
        if (status.disconnected or (model.connected and !status.live and !status.connected)) {
            model.connected = false;
            model.driven = false;
            model.timeline_entry = null;
            // Electron's badge and panel die with it.
            model.badge = false;
            model.panel_open = false;
            model.panel_dismissed = false;
            showUndriven(model, fx);
        }
    }
    if (model.bubble_until_ms != 0 and now >= model.bubble_until_ms) {
        setBubble(model, null, null, 0);
        // A hover line covered the entry's bubble: bring it back.
        if (!model.driven) model.timeline_entry = null;
    }
    pollPanel(model, now);
    placeBubble(model, fx);
    defer updateMotion(model, fx);
    if (model.driven) return;
    // Re-evaluate only when something changed: a local reaction ended or
    // the timeline moved to its next entry. Re-applying every tick cost
    // ~2.7 % CPU at 10 Hz for nothing.
    var changed = false;
    if (model.local_state != null and now >= model.local_until_ms) {
        model.local_state = null;
        model.timeline_entry = null;
        changed = true;
    }
    if (model.timeline) |*tl| {
        const index: ?usize = if (tl.entryAt(now)) |hit| hit.index else null;
        if (index != model.timeline_entry) changed = true;
        // A sleeping entry falls asleep again once the wake-up ran out.
        if (tl.entryAt(now)) |hit| if (hit.entry.sleeping and hit.entry.visible) {
            if ((now >= model.awake_until_ms) != model.sleeping) changed = true;
        };
    }
    if (changed) showUndriven(model, fx);
    if (model.timeline) |*tl| {
        // launch.zig keeps one run at a time and backs off on failure.
        if (tl.refresh_at_ms > 0 and now >= tl.refresh_at_ms) core.refreshApp(appLaunch());
    }
}

/// The panel's 20 s rule (and, offline, its countdown line).
fn pollPanel(model: *Model, now: i64) void {
    if (!model.panel_open) return;
    if (model.hover_inside or model.pointer_in_float) {
        model.panel_deadline_ms = now + panel_idle_ms;
    } else if (now >= model.panel_deadline_ms) {
        return closePanelHere(model);
    }
    if (!model.driven and !fillOfflinePanel(model, now)) closeOfflinePanel(model);
}

/// Win/mac only (Linux reports pointer and drag through commands): the
/// frame clock samples cursor and button like upstream's app-owned drag.
fn frameClock(model: *Model, fx: *Effects) void {
    const read = fx.moveWindow("main", 0, 0, false) orelse return;
    model.pet_x = read.x;
    model.pet_y = read.y;
    model.have_position = true;
    // The bubble follows the pet (also while it is dragged or walks).
    defer placeBubbleAt(model, fx, model.pet_x, model.pet_y);
    const now = fx.wallMs();
    if (model.dragging) {
        if (read.primary_down) {
            const dx = (read.cursor_x - model.grab_dx) - read.x;
            const dy = (read.cursor_y - model.grab_dy) - read.y;
            if (dx != 0 or dy != 0) {
                if (fx.moveWindow("main", dx, dy, false)) |moved| {
                    model.pet_x = moved.x;
                    model.pet_y = moved.y;
                }
                const dir: i8 = if (dx > 1) 1 else if (dx < -1) -1 else 0;
                if (dir != 0 and dir != model.drag_dir) dragStarted(model, dir, fx);
            }
            return;
        }
        const tap = now - model.press_ms <= tap_max_ms and @abs(read.x - model.press_x) < tap_slop_px and @abs(read.y - model.press_y) < tap_slop_px;
        if (tap) {
            model.dragging = false;
            fx.cancelTimer(drag_watchdog_key);
            if (now - model.last_click_ms <= double_click_ms) {
                model.last_click_ms = 0;
                onDoubleClick(model, fx);
            } else {
                model.last_click_ms = now;
                onClick(model, fx);
            }
        } else dragEnded(model, fx);
        model.primary_was_down = false;
        return;
    }
    const inside = read.cursor_x >= read.x and read.cursor_x <= read.x + windowW(model) and
        read.cursor_y >= read.y and read.cursor_y <= read.y + windowH(model);
    if (inside and !model.hover_inside) onHover(model, fx);
    if (inside != model.hover_inside) {
        model.hover_inside = inside;
        updateMotion(model, fx);
    }
    // The panel counts as "pointer inside" too (its 20 s rule).
    model.pointer_in_float = false;
    const shown = floatShown(model);
    if (shown == .panel) if (fx.moveWindow(shown.label(), 0, 0, false)) |f| {
        const size = floatSize(model, shown);
        model.pointer_in_float = read.cursor_x >= f.x and read.cursor_x <= f.x + size.w and
            read.cursor_y >= f.y and read.cursor_y <= f.y + size.h;
    };
    if (read.primary_down and !model.primary_was_down and inside) {
        model.dragging = true;
        model.drag_dir = 0;
        model.grab_dx = read.cursor_x - read.x;
        model.grab_dy = read.cursor_y - read.y;
        model.press_x = read.x;
        model.press_y = read.y;
        model.press_ms = now;
    }
    model.primary_was_down = read.primary_down;
}

pub fn onCommand(name: []const u8) ?Msg {
    if (std.mem.startsWith(u8, name, tray_command_prefix)) {
        const i = std.fmt.parseInt(u8, name[tray_command_prefix.len..], 10) catch return null;
        return .{ .tray_pick = i };
    }
    if (!is_linux) return null;
    if (std.mem.eql(u8, name, "native-sdk.window-drag.begin")) return .{ .native_drag_started = 0 };
    if (std.mem.eql(u8, name, "native-sdk.window-drag.begin-left")) return .{ .native_drag_started = -1 };
    if (std.mem.eql(u8, name, "native-sdk.window-drag.begin-right")) return .{ .native_drag_started = 1 };
    if (std.mem.eql(u8, name, "native-sdk.window-drag.end")) return .native_drag_ended;
    // From packages/ti-pet/patches/ti-pet-sdk-linux-pointer.patch.
    if (std.mem.eql(u8, name, "native-sdk.window-drag.click")) return .pointer_click;
    if (std.mem.eql(u8, name, "native-sdk.window-drag.dblclick")) return .pointer_dblclick;
    if (std.mem.eql(u8, name, "native-sdk.pointer.enter")) return .pointer_enter;
    if (std.mem.eql(u8, name, "native-sdk.pointer.leave")) return .pointer_leave;
    return null;
}

pub fn onFrame(model: *const Model, frame: native_sdk.platform.GpuFrame) ?Msg {
    _ = model;
    _ = frame;
    return .frame_clock;
}

fn onAppearance(appearance: native_sdk.platform.Appearance) ?Msg {
    return .{ .appearance = appearance };
}

/// Escape closes the panel (when a key reaches the pet at all).
fn onKey(keyboard: canvas.WidgetKeyboardEvent) ?Msg {
    if (keyboard.phase == .key_down and std.mem.eql(u8, keyboard.key, "escape")) return .escape;
    return null;
}

// ------------------------------------------------------------------ view

fn tokens(model: *const Model) canvas.DesignTokens {
    var t = canvas.DesignTokens.theme(.{
        .color_scheme = if (model.dark) .dark else .light,
        .reduce_motion = model.reduce_motion,
    });
    // Transparent pet and bubble windows clear to zero alpha.
    t.colors.background = canvas.Color.rgba8(0, 0, 0, 0);
    return t;
}

var pet_menu_scratch: [protocol.max_menu_items]AppUi.ContextMenuItem = undefined;
var pet_label_scratch: [protocol.max_menu_items][protocol.max_menu_label_bytes + 4]u8 = undefined;
var tray_label_scratch: [protocol.max_menu_items][protocol.max_menu_label_bytes + 4]u8 = undefined;

fn petMenu(model: *const Model) []const AppUi.ContextMenuItem {
    for (model.pet_menu.items[0..model.pet_menu.len], 0..) |*item, i| {
        pet_menu_scratch[i] = if (item.kind == .separator)
            .{ .separator = true }
        else
            .{ .label = item.display(&pet_label_scratch[i]), .msg = .{ .pet_pick = @intCast(i) }, .enabled = item.enabled };
    }
    return pet_menu_scratch[0..model.pet_menu.len];
}

fn spriteNode(ui: *AppUi, model: *const Model, base: u64, frame_index: usize, label: []const u8) AppUi.Node {
    var node = ui.image(.{
        .width = spriteW(model),
        .height = spriteH(model),
        .image = base + frame_index,
        .semantics = .{ .label = label },
    });
    node.widget.image_fit = .stretch;
    node.widget.image_sampling = .nearest;
    return node;
}

/// Answer-ready dot (pet.css #badge: 14 px, #e10600, white ring).
const badge_d: f32 = 14;

/// The sprites plus, on top, the sleeping "z z" by the first pet's head
/// (pet.js applySleep: 0.64 w in, 0.08 h down) and the answer-ready dot at
/// its upper right (pet.js: 10 % of w in from the right, BADGE_TOP 0.25 h
/// down, clear of the "z z").
fn withMarks(ui: *AppUi, model: *const Model, sprites: AppUi.Node) AppUi.Node {
    if (!model.sleeping and !model.badge) return sprites;
    const sw = spriteW(model);
    const h = spriteH(model);
    const left = firstOffset(model);
    var nodes: [3]AppUi.Node = undefined;
    var n: usize = 0;
    nodes[n] = sprites;
    n += 1;
    if (model.sleeping) {
        // pet.js sizes it max(10, 0.1 h) px: s / m / l → small / body / large.
        var z = ui.text(.{
            .size = switch (model.size) {
                .s => .sm,
                .m => .default,
                .l => .lg,
            },
            .frame = geometry.RectF.init(@round(left + sw * 0.64), @round(h * 0.08), @round(sw * 0.34), @round(@max(14, h * 0.16))),
            .semantics = .{ .label = "Asleep" },
        }, "z z");
        z.widget.style.foreground = if (model.dark) canvas.Color.rgb8(196, 206, 230) else canvas.Color.rgb8(92, 104, 140);
        nodes[n] = z;
        n += 1;
    }
    if (model.badge) {
        var dot = ui.el(.panel, .{
            .frame = geometry.RectF.init(@round(left + sw - sw * 0.1 - badge_d), @round(h * 0.25), badge_d, badge_d),
            .padding = 0,
            .semantics = .{ .label = model.badge_label.slice() },
        }, .{});
        dot.widget.style.background = canvas.Color.rgb8(225, 6, 0);
        dot.widget.style.border = canvas.Color.rgb8(255, 255, 255);
        dot.widget.style.stroke_width = 2;
        dot.widget.style.radius = badge_d / 2;
        nodes[n] = dot;
        n += 1;
    }
    return ui.stack(.{ .width = windowW(model), .height = h }, nodes[0..n]);
}

pub fn rootView(ui: *AppUi, model: *const Model) AppUi.Node {
    const menu = petMenu(model);
    if (!onScreen(model) or !model.first.ok) {
        return ui.el(.stack, .{ .grow = 1, .context_menu = menu }, .{});
    }
    var first = spriteNode(ui, model, first_image_base, model.anim.frame_index, "TracingInsights pet");
    first.context_menu = menu;
    const sprites = if (showsDuo(model)) blk: {
        const index = if (model.second_mirrors) model.anim.frame_index else model.anim2.frame_index;
        var second = spriteNode(ui, model, second_image_base, index, "Second pet");
        second.context_menu = menu;
        // The second pet stands on the left (pet-window.mjs duoSecondSide).
        break :blk ui.row(.{ .gap = duoGap(model), .cross = .end }, .{ second, first });
    } else first;
    const body = withMarks(ui, model, sprites);
    if (is_linux) {
        // GTK hands primary presses to the compositor (window drag); the
        // ti-pet SDK patch reports clicks, double-clicks and hover back.
        return ui.column(.{ .grow = 1, .main = .end, .cross = .center, .window_drag = true, .context_menu = menu }, .{
            body,
            ui.el(.stack, .{ .width = 1, .height = pet_edge_pad }, .{}),
        });
    }
    return ui.column(.{ .grow = 1, .main = .end, .cross = .center, .on_press = .noop, .context_menu = menu }, .{body});
}

// ------------------------------------------------- bubble and panel

const bubble_w: f32 = 260;
const bubble_h: f32 = 64;
/// A bubble with buttons and the panel grow up to this wide (pet-window.mjs
/// bubbleArea: 240–440 px), then wrap their buttons.
const float_max_w: f32 = 440;
const panel_min_w: f32 = 300;
const panel_line_h: f32 = 20;
const button_row_h: f32 = 34;
const button_gap: f32 = 6;
const card_pad: f32 = 10;
const bubble_gap: f32 = 6;
const max_float_buttons = @max(protocol.max_bubble_actions, protocol.max_panel_actions);

/// A small button's width, estimated like pet-window.mjs (~8 px a
/// character + 16 px padding).
fn buttonW(label: []const u8) f32 {
    const chars = std.unicode.utf8CountCodepoints(label) catch label.len;
    return @as(f32, @floatFromInt(chars)) * 8 + 16;
}

/// A text line's width (~7 px a character at the bubble's size).
fn lineW(text: []const u8) f32 {
    const chars = std.unicode.utf8CountCodepoints(text) catch text.len;
    return @as(f32, @floatFromInt(chars)) * 7;
}

/// Buttons laid out greedily in rows `inner` wide: the row of each button
/// in `row_of`; returns the number of rows.
fn wrapButtons(slots: []const ActionSlot, inner: f32, row_of: []u8) usize {
    var rows: usize = 0;
    var used: f32 = 0;
    for (slots, 0..) |*slot, i| {
        const w = buttonW(slot.label.slice());
        if (rows == 0 or (used > 0 and used + button_gap + w > inner)) {
            rows += 1;
            used = w;
        } else used += button_gap + w;
        row_of[i] = @intCast(rows - 1);
    }
    return rows;
}

fn rowWidth(slots: []const ActionSlot) f32 {
    var w: f32 = 0;
    for (slots, 0..) |*slot, i| w += buttonW(slot.label.slice()) + (if (i > 0) button_gap else 0);
    return w;
}

fn floatShown(model: *const Model) Float {
    if (!onScreen(model) or !model.first.ok) return .none;
    if (model.panel_open and (model.panel_lines_len > 0 or model.panel_actions_len > 0)) return .panel;
    if (model.bubble_len == 0) return .none;
    return if (model.bubble_actions_len > 0) .bubble_actions else .bubble;
}

const FloatSize = struct { w: f32, h: f32, rows: usize = 0 };

fn floatSize(model: *const Model, f: Float) FloatSize {
    var row_of: [max_float_buttons]u8 = undefined;
    return switch (f) {
        .none, .bubble => .{ .w = bubble_w, .h = bubble_h },
        .bubble_actions => blk: {
            const slots = model.bubble_actions[0..model.bubble_actions_len];
            const w = std.math.clamp(rowWidth(slots) + 2 * card_pad + 4, bubble_w, float_max_w);
            const rows = wrapButtons(slots, w - 2 * card_pad - 4, &row_of);
            break :blk .{ .w = w, .h = 68 + @as(f32, @floatFromInt(rows)) * button_row_h, .rows = rows };
        },
        .panel => blk: {
            const slots = model.panel_actions[0..model.panel_actions_len];
            var widest = rowWidth(slots);
            for (model.panel_lines[0..model.panel_lines_len]) |*line| widest = @max(widest, lineW(line.slice()));
            const w = std.math.clamp(widest + 2 * card_pad + 4, panel_min_w, float_max_w);
            const rows = wrapButtons(slots, w - 2 * card_pad - 4, &row_of);
            const lines: f32 = @floatFromInt(model.panel_lines_len);
            const gap: f32 = if (rows > 0 and model.panel_lines_len > 0) 6 else 0;
            break :blk .{ .w = w, .h = 26 + lines * panel_line_h + gap + @as(f32, @floatFromInt(rows)) * button_row_h, .rows = rows };
        },
    };
}

/// Win/mac: the floating window's top-left for a pet window at (pet_x,
/// pet_y), centred over the sprite group (it spans the whole window) and
/// above it, or below when it would leave the top of the screen.
fn floatX(model: *const Model, pet_x: f64, size: FloatSize) f64 {
    return pet_x + windowW(model) / 2 - size.w / 2;
}

fn floatY(model: *const Model, pet_y: f64, size: FloatSize) f64 {
    const above = pet_y - size.h - bubble_gap;
    return if (above >= 0) above else pet_y + windowH(model) + bubble_gap;
}

/// Win/mac: keep the floating window centred above the pet. The SDK
/// applies a secondary window's x/y only when it creates it (AppKit even
/// centres it on screen), so it is moved by the difference between where
/// it is and where it belongs. Both rects come from moveWindow, which
/// every host reports in one space (top-left origin, points / DIPs).
/// (pet_x, pet_y) is the main window's fresh origin. Linux uses a
/// GtkPopover anchored to the pet instead (GTK flips it below itself).
fn placeBubbleAt(model: *Model, fx: *Effects, pet_x: f64, pet_y: f64) void {
    if (is_linux) return;
    const shown = floatShown(model);
    if (shown != model.float_shown) {
        // A new window: created at its declared size.
        model.float_shown = shown;
        const declared = floatSize(model, shown);
        model.float_w_applied = declared.w;
        model.float_h_applied = declared.h;
    }
    if (shown == .none) return;
    const size = floatSize(model, shown);
    // New text or buttons change the size (secondary windows are not
    // resized from their declaration once created).
    if ((size.w != model.float_w_applied or size.h != model.float_h_applied) and
        fx.resizeWindow(shown.label(), size.w, size.h, .top_left))
    {
        model.float_w_applied = size.w;
        model.float_h_applied = size.h;
    }
    // Null until the runtime created the declared window (after update).
    const cur = fx.moveWindow(shown.label(), 0, 0, false) orelse return;
    const dx = floatX(model, pet_x, size) - cur.x;
    const dy = floatY(model, pet_y, size) - cur.y;
    if (@abs(dx) < 0.5 and @abs(dy) < 0.5) return;
    _ = fx.moveWindow(shown.label(), dx, dy, false);
}

fn placeBubble(model: *Model, fx: *Effects) void {
    if (is_linux or floatShown(model) == .none) return;
    const pet = fx.moveWindow("main", 0, 0, false) orelse return;
    model.pet_x = pet.x;
    model.pet_y = pet.y;
    model.have_position = true;
    placeBubbleAt(model, fx, pet.x, pet.y);
}

fn petWindows(model: *const Model, scratch: *PetApp.WindowsScratch) []const PetApp.WindowDescriptor {
    const shown = floatShown(model);
    if (shown == .none) return scratch.windows[0..0];
    const size = floatSize(model, shown);
    if (is_linux) {
        // A GtkPopover anchored above the sprite (upstream's Linux path):
        // GTK_POS_TOP places the popup above the pointing rectangle.
        scratch.windows[0] = .{
            .label = shown.label(),
            .canvas_label = "bubble-canvas",
            .width = size.w,
            .height = size.h,
            .x = windowW(model) / 2,
            .y = @max(0, windowH(model) - pet_edge_pad - spriteH(model) - bubble_gap),
            .resizable = false,
            .titlebar = .chromeless,
            .floating = true,
            .transparent = true,
            .popup_parent = "main",
        };
    } else {
        scratch.windows[0] = .{
            .label = shown.label(),
            .canvas_label = "bubble-canvas",
            .width = size.w,
            .height = size.h,
            .x = @floatCast(floatX(model, model.pet_x, size)),
            .y = @floatCast(floatY(model, model.pet_y, size)),
            .resizable = false,
            .titlebar = .chromeless,
            .floating = true,
            .fullscreen_overlay = true,
            .transparent = true,
        };
    }
    return scratch.windows[0..1];
}

fn textColor(model: *const Model) canvas.Color {
    return if (model.dark) canvas.Color.rgb8(237, 237, 238) else canvas.Color.rgb8(17, 17, 17);
}

/// The bubble / panel card look (the Electron bubble's).
fn card(ui: *AppUi, model: *const Model, options: AppUi.ElementOptions, content: AppUi.Node) AppUi.Node {
    var c = ui.el(.panel, options, .{content});
    c.widget.style.radius = 14;
    c.widget.style.stroke_width = 1;
    if (model.dark) {
        c.widget.style.background = canvas.Color.rgb8(25, 25, 28);
        c.widget.style.border = canvas.Color.rgba8(255, 255, 255, 26);
    } else {
        c.widget.style.background = canvas.Color.rgb8(255, 255, 255);
        c.widget.style.border = canvas.Color.rgb8(214, 214, 220);
    }
    return c;
}

fn buttonNode(ui: *AppUi, label: []const u8, msg: Msg) AppUi.Node {
    return ui.button(.{ .size = .sm, .variant = .outline, .on_press = msg, .semantics = .{ .label = label } }, label);
}

/// The button rows for `slots` wrapped inside `inner`; `msg_of(i)` is the
/// press message of button `i`. Writes rows into `out`, returns them.
fn buttonRows(ui: *AppUi, slots: []const ActionSlot, inner: f32, comptime tag: std.meta.Tag(Msg), out: []AppUi.Node) []AppUi.Node {
    var row_of: [max_float_buttons]u8 = undefined;
    const rows = wrapButtons(slots, inner, &row_of);
    var start: usize = 0;
    for (0..rows) |r| {
        var end = start;
        while (end < slots.len and row_of[end] == r) end += 1;
        var buttons: [max_float_buttons]AppUi.Node = undefined;
        for (start..end) |j| buttons[j - start] = buttonNode(ui, slots[j].label.slice(), @unionInit(Msg, @tagName(tag), @intCast(j)));
        out[r] = ui.row(.{ .gap = button_gap }, buttons[0 .. end - start]);
        start = end;
    }
    return out[0..rows];
}

fn bubbleView(ui: *AppUi, model: *const Model) AppUi.Node {
    var text = ui.text(.{ .size = .sm }, model.bubble[0..model.bubble_len]);
    text.widget.style.foreground = textColor(model);
    const content = if (model.bubble_actions_len == 0) text else blk: {
        const size = floatSize(model, .bubble_actions);
        var rows: [max_float_buttons + 1]AppUi.Node = undefined;
        rows[0] = text;
        const buttons = buttonRows(ui, model.bubble_actions[0..model.bubble_actions_len], size.w - 2 * card_pad - 4, .bubble_action, rows[1..]);
        break :blk ui.column(.{ .gap = 8 }, rows[0 .. 1 + buttons.len]);
    };
    // A click on the text opens its target; a button never does.
    const c = card(ui, model, .{ .padding = 10, .on_press = .bubble_click, .semantics = .{ .label = "Pet bubble" } }, content);
    return ui.column(.{ .grow = 1, .main = .end, .cross = .center }, .{c});
}

fn panelView(ui: *AppUi, model: *const Model) AppUi.Node {
    var rows: [protocol.max_panel_lines + 1 + max_float_buttons]AppUi.Node = undefined;
    var n: usize = 0;
    for (model.panel_lines[0..model.panel_lines_len]) |*line| {
        var t = ui.text(.{ .size = .sm }, line.slice());
        t.widget.style.foreground = textColor(model);
        rows[n] = t;
        n += 1;
    }
    const size = floatSize(model, .panel);
    n += buttonRows(ui, model.panel_actions[0..model.panel_actions_len], size.w - 2 * card_pad - 4, .panel_action, rows[n..]).len;
    const c = card(ui, model, .{ .padding = 10, .semantics = .{ .label = "Pet panel" } }, ui.column(.{ .gap = 6 }, rows[0..n]));
    return ui.column(.{ .grow = 1, .main = .end, .cross = .center }, .{c});
}

fn windowView(ui: *AppUi, model: *const Model, label: []const u8) AppUi.Node {
    if (std.mem.eql(u8, label, "panel")) return panelView(ui, model);
    return bubbleView(ui, model);
}

// ------------------------------------------------------------------ tray

const tray_command_prefix = "ti.tray.";
const tray_commands = blk: {
    var names: [protocol.max_menu_items][]const u8 = undefined;
    for (0..protocol.max_menu_items) |i| names[i] = std.fmt.comptimePrint("ti.tray.{d}", .{i});
    break :blk names;
};

fn statusItem(model: *const Model, scratch: *PetApp.StatusItemScratch) PetApp.StatusItemState {
    const n = @min(model.tray.len, scratch.items.len);
    for (model.tray.items[0..n], 0..) |*item, i| {
        scratch.items[i] = if (item.kind == .separator)
            .{ .id = @intCast(i + 1), .separator = true }
        else
            .{ .id = @intCast(i + 1), .label = item.display(&tray_label_scratch[i]), .command = tray_commands[i], .enabled = item.enabled };
    }
    return .{ .items = scratch.items[0..n] };
}

const tray_icon_png = @embedFile("tray-icon.png");
var tray_icon_path_buf: [protocol.max_path_bytes]u8 = undefined;
var tray_icon_path: []const u8 = "";

/// The platform takes a tray icon PATH: write the embedded PNG into the
/// user-data dir (Electron's userData) once per start.
fn materializeTrayIcon() void {
    const dir = args.user_data orelse return;
    const path = std.fmt.bufPrint(&tray_icon_path_buf, "{s}/pet-tray-icon.png", .{dir}) catch return;
    if (writeFile(path, tray_icon_png)) tray_icon_path = path;
}

// ------------------------------------------------------------------ files

fn readFileAlloc(path: []const u8, max: usize) ?[]u8 {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    const stat = file.stat(io) catch return null;
    const size: usize = @intCast(stat.size);
    if (size == 0 or size > max) return null;
    const buf = gpa.alloc(u8, size) catch return null;
    const n = file.readPositionalAll(io, buf, 0) catch {
        gpa.free(buf);
        return null;
    };
    if (n != size) {
        gpa.free(buf);
        return null;
    }
    return buf;
}

fn writeFile(path: []const u8, bytes: []const u8) bool {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var file = std.Io.Dir.createFileAbsolute(io, path, .{}) catch return false;
    defer file.close(io);
    file.writePositionalAll(io, bytes, 0) catch return false;
    return true;
}

// ------------------------------------------------------------------ main

fn parseArgs(init: std.process.Init) !void {
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    _ = it.next();
    while (it.next()) |arg| {
        const eql = std.mem.eql;
        if (eql(u8, arg, "--login")) {
            args.login = true;
            continue;
        }
        const value = it.next() orelse break;
        const owned = try gpa.dupe(u8, value);
        if (eql(u8, arg, "--pet")) args.pet_dir = owned else if (eql(u8, arg, "--second")) args.second_dir = owned else if (eql(u8, arg, "--socket")) args.socket = owned else if (eql(u8, arg, "--token-file")) args.token_file = owned else if (eql(u8, arg, "--user-data")) args.user_data = owned else if (eql(u8, arg, "--app")) args.app = owned else if (eql(u8, arg, "--timeline")) args.timeline = owned else if (eql(u8, arg, "--size")) {
            args.size = std.meta.stringToEnum(protocol.Size, owned) orelse .m;
        } else if (eql(u8, arg, "--app-arg")) {
            if (args.app_args_len < max_app_args) {
                args.app_args[args.app_args_len] = owned;
                args.app_args_len += 1;
            }
        }
    }
    if (args.timeline == null) {
        if (args.user_data) |dir| args.timeline = try std.fmt.allocPrint(gpa, "{s}/pet-timeline.json", .{dir});
    }
}

/// The size boot will apply: the saved native state, else the timeline,
/// else `--size` (Electron never passes it). The window must start at it:
/// on X11 a resize while boot runs, before the window is first shown,
/// left the canvas blank (measured 2026-11-07: a start from a size-L
/// timeline drew nothing until something resized the window again).
fn initialSize() protocol.Size {
    if (core.loadNativeState(args.user_data)) |st| if (st.size) |s| return s;
    if (args.timeline) |path| {
        if (core.Timeline.loadInside(gpa, path, args.user_data)) |loaded| {
            var tl = loaded;
            defer tl.deinit();
            return tl.size;
        } else |_| {}
    }
    return args.size;
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub fn main(init: std.process.Init) !void {
    try parseArgs(init);
    args.size = initialSize();
    // Electron must not inherit our GDK_BACKEND=x11 (its own windows stay
    // native Wayland).
    if (init.environ_map.clone(gpa)) |env| {
        launch_env = env;
        _ = launch_env.?.swapRemove("GDK_BACKEND");
    } else |_| {}
    if (is_linux and init.environ_map.get("GSK_RENDERER") == null) {
        // The pet canvas is software-drawn: GTK's GL renderer would only
        // load the GPU driver stack (~10 MB PSS measured, same CPU).
        _ = setenv("GSK_RENDERER", "cairo", 0);
        // GDK still opens a GL context for the display under the cairo
        // renderer (NVIDIA EGL + Mesa: +25 MB private, +45 MB PSS
        // measured 2026-11-06, same CPU). GTK >= 4.16 reads this; older
        // GTK ignores it. Electron gets launch_env, cloned before this.
        if (init.environ_map.get("GDK_DISABLE") == null) _ = setenv("GDK_DISABLE", "gl", 0);
    }
    if (args.socket) |socket| {
        const token = args.token_file orelse return error.MissingTokenFile;
        const pid: u32 = if (builtin.os.tag == .linux) @intCast(std.os.linux.getpid()) else if (builtin.os.tag == .windows) std.os.windows.GetCurrentProcessId() else @intCast(std.c.getpid());
        server = ipc.start(gpa, socket, token, pid) catch |err| switch (err) {
            // One pet per profile: the running one keeps the socket.
            error.AlreadyRunning => return,
            else => blk: {
                std.debug.print("ti-pet: socket unavailable ({s})\n", .{@errorName(err)});
                break :blk null;
            },
        };
    }
    materializeTrayIcon();

    const shell_windows = [_]native_sdk.ShellWindow{.{
        .label = "main",
        .title = "TracingInsights Pet",
        .width = @round(frame_w * args.size.scale()),
        .height = @round(frame_h * args.size.scale()) + pet_edge_pad,
        .resizable = false,
        .restore_state = false,
        .titlebar = .chromeless,
        .floating = true,
        .fullscreen_overlay = true,
        .transparent = true,
        .views = &shell_views,
    }};
    const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

    const app_state = try PetApp.create(std.heap.page_allocator, .{
        .name = "ti-pet",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .init_fx = boot,
        .view = rootView,
        .on_command = onCommand,
        .status_item = .{ .icon_path = tray_icon_path, .tooltip = "TracingInsights" },
        .status_item_fn = statusItem,
        .on_frame = if (is_linux) null else onFrame,
        .windows_fn = petWindows,
        .window_view = windowView,
        .tokens_fn = tokens,
        .on_appearance = onAppearance,
        .on_key = onKey,
    });
    defer app_state.destroy();
    app_state.model = .{};

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "ti-pet",
        .window_title = "TracingInsights Pet",
        .bundle_id = "dev.tracinginsights.pet",
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, @round(frame_w * args.size.scale()), @round(frame_h * args.size.scale()) + pet_edge_pad),
        .restore_state = false,
        .js_window_api = false,
        .menus = &.{},
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = protocol;
    _ = motion;
}
