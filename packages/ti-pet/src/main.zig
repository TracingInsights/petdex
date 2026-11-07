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

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const is_linux = builtin.target.os.tag == .linux;

pub const State = sprite.State;

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
    tray_pick: u8,
    pet_pick: u8,
    noop,

    pub const view_unbound = .{ "frame_tick", "poll_tick", "drag_watchdog", "frame_clock", "appearance", "native_drag_started", "native_drag_ended", "pointer_click", "pointer_dblclick", "pointer_enter", "pointer_leave", "tray_pick" };
};

const PathBuf = struct {
    buf: [protocol.max_path_bytes]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const PathBuf) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *PathBuf, s: []const u8) bool {
        const n = @min(s.len, self.buf.len);
        const changed = !std.mem.eql(u8, self.buf[0..self.len], s[0..n]);
        @memcpy(self.buf[0..n], s[0..n]);
        self.len = n;
        return changed;
    }
};

const Loaded = struct {
    path: PathBuf = .{},
    row: u8 = 255,
    frames: u8 = 0,
    rows: u8 = 9,
    ok: bool = false,
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

pub const Model = struct {
    // --- what is shown ---
    /// Electron's show/hide, or Show/Hide pet from the menus offline.
    visible: bool = true,
    /// The current timeline entry hides the pet (visible: false).
    timeline_hidden: bool = false,
    size: protocol.Size = .m,
    duo: bool = false,
    state: State = .idle,
    row: u8 = 0,
    frames: u8 = 6,
    frame_ms: u32 = 183,
    once: bool = false,
    still: bool = false,
    frame_index: usize = 0,
    play_key: [128]u8 = undefined,
    play_key_len: usize = 0,
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

    // --- driver ---
    /// Electron finished hello.
    connected: bool = false,
    /// Electron sent show/hide/render/menu: it decides everything.
    driven: bool = false,
    timeline: ?core.Timeline = null,
    /// Last timeline entry applied (index), to apply each once.
    timeline_entry: ?usize = null,

    // --- local reactions (not driven) ---
    local_state: ?State = null,
    local_until_ms: i64 = 0,
    quiet_until_ms: i64 = 0,

    // --- pointer / window ---
    dragging: bool = false,
    drag_dir: i8 = 0,
    pet_x: f64 = 0,
    pet_y: f64 = 0,
    have_position: bool = false,
    pending_move: ?protocol.Point = null,
    hover_inside: bool = false,
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

/// Make the registered frames match what the model wants to show.
fn syncFrames(model: *Model, fx: *Effects) void {
    syncOne(&model.first, &model.want_first, model.want_first_rows, model.row, model.frames, first_image_base, fx);
    if (model.duo and model.want_second.len > 0) {
        syncOne(&model.second, &model.want_second, model.want_second_rows, model.row, model.frames, second_image_base, fx);
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

const Show = struct {
    state: State,
    row: u8,
    frames: u8,
    duration_ms: u32,
    once: bool = false,
    still: bool = false,
    play_key: []const u8 = "",
};

/// Upstream's frame table for a state (used for local reactions, where no
/// payload says how to play it).
fn localShow(state: State, key: []const u8) Show {
    const def = sprite.stateDef(state);
    var total: u32 = 0;
    for (def.frames) |f| total += f.dur_ms;
    const once = state == .jumping or state == .waving or state == .failed;
    return .{ .state = state, .row = @intCast(def.row), .frames = @intCast(def.frames.len), .duration_ms = total, .once = once, .play_key = key };
}

fn applyShow(model: *Model, show: Show, fx: *Effects) void {
    const key_changed = !std.mem.eql(u8, model.play_key[0..model.play_key_len], show.play_key);
    const restart = key_changed or show.state != model.state or show.row != model.row or show.still != model.still;
    model.state = show.state;
    model.row = show.row;
    model.frames = @max(1, @min(show.frames, 8));
    model.frame_ms = @max(16, show.duration_ms / model.frames);
    model.once = show.once;
    model.still = show.still or model.reduce_motion;
    const n = @min(show.play_key.len, model.play_key.len);
    @memcpy(model.play_key[0..n], show.play_key[0..n]);
    model.play_key_len = n;
    syncFrames(model, fx);
    fitWindow(model, fx);
    if (restart) {
        model.frame_index = 0;
        armFrameTimer(model, fx);
    }
}

fn setBubble(model: *Model, text: ?[]const u8, target: ?[]const u8, until_ms: i64) void {
    const t = protocol.clipUtf8(text orelse "", model.bubble.len);
    @memcpy(model.bubble[0..t.len], t);
    model.bubble_len = t.len;
    _ = model.bubble_target.set(target orelse "");
    model.bubble_until_ms = until_ms;
}

fn armFrameTimer(model: *const Model, fx: *Effects) void {
    fx.cancelTimer(frame_timer_key);
    if (model.still or model.frames <= 1 or !onScreen(model)) return;
    if (model.once and model.frame_index + 1 >= model.frames) return;
    fx.startTimer(.{
        .key = frame_timer_key,
        .interval_ms = model.frame_ms,
        .mode = .one_shot,
        .on_fire = Effects.timerMsg(.frame_tick),
    });
}

/// Not driven: the timeline entry or idle, unless a local reaction plays.
fn showUndriven(model: *Model, fx: *Effects) void {
    if (model.driven) return;
    const now = fx.wallMs();
    if (model.local_state) |state| {
        if (now < model.local_until_ms) {
            applyShow(model, localShow(state, "local"), fx);
            return;
        }
        model.local_state = null;
    }
    if (model.timeline) |*tl| {
        if (tl.entryAt(now)) |hit| {
            const entry = hit.entry;
            if (model.timeline_entry == null or model.timeline_entry.? != hit.index) {
                model.timeline_entry = hit.index;
                const shows = entry.visible and model.visible and now >= model.quiet_until_ms;
                if (shows) {
                    setBubble(model, entry.bubble, entry.bubble_target, 0);
                    // Only a bubble that really showed counts; one eaten by
                    // quiet or a hidden pet stays unreported so Electron
                    // shows it again.
                    if (entry.bubble != null) if (entry.moment) |m| core.recordMoment(args.user_data, m);
                } else {
                    setBubble(model, null, null, 0);
                }
            }
            model.timeline_hidden = !entry.visible;
            if (!entry.visible) {
                fx.cancelTimer(frame_timer_key);
                fitWindow(model, fx);
                return;
            }
            model.duo = entry.duo;
            if (now < model.quiet_until_ms) {
                applyShow(model, localShow(.idle, "quiet"), fx);
            } else {
                applyShow(model, .{
                    .state = entry.state,
                    .row = entry.row,
                    .frames = entry.frames,
                    .duration_ms = entry.duration_ms,
                    .once = entry.once,
                    .still = entry.still,
                    .play_key = entry.play_key,
                }, fx);
            }
            return;
        }
    }
    applyShow(model, localShow(.idle, "idle"), fx);
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
            syncFrames(model, fx);
            fitWindow(model, fx);
            armFrameTimer(model, fx);
            placeWindow(model, fx);
        },
        .hide => {
            model.driven = true;
            model.visible = false;
            setBubble(model, null, null, 0);
            fx.cancelTimer(frame_timer_key);
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
            defer placeWindow(model, fx);
            applyShow(model, .{
                .state = r.state,
                .row = r.row,
                .frames = r.frames,
                .duration_ms = r.duration_ms,
                .once = r.once,
                .still = r.still,
                .play_key = r.play_key,
            }, fx);
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
                // its quiet wins (a quiet ended in the app must end).
                model.quiet_until_ms = tl.quiet_until_ms;
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
    if (model.connected and model.driven) return send(protocol.Event{ .event = .click });
    react(model, .jumping, fx);
}

fn onDoubleClick(model: *Model) void {
    if (model.connected and model.driven) return send(protocol.Event{ .event = .dblclick });
    core.openApp(appLaunch(), "/");
}

fn onHover(model: *Model, fx: *Effects) void {
    if (model.connected and model.driven) return send(protocol.Event{ .event = .hover });
    const now = fx.wallMs();
    if (now < model.quiet_until_ms) return;
    var buf: [256]u8 = undefined;
    const text: ?[]const u8 = if (model.timeline) |*tl|
        (if (showsDuo(model)) tl.duo_text else null) orelse core.hoverText(&buf, tl, now)
    else
        null;
    if (text) |t| setBubble(model, t, if (model.timeline) |*tl| tl.calendar_target else "/", now + hover_bubble_ms);
    react(model, .waving, fx);
}

fn onBubbleClick(model: *Model) void {
    if (model.connected and model.driven) return send(protocol.Event{ .event = .bubbleClick });
    const target = model.bubble_target.slice();
    if (protocol.appPathOk(target)) core.openApp(appLaunch(), target);
}

fn react(model: *Model, state: State, fx: *Effects) void {
    model.local_state = state;
    model.local_until_ms = fx.wallMs() + react_ms;
    showUndriven(model, fx);
}

fn dragStarted(model: *Model, dir: i8, fx: *Effects) void {
    model.dragging = true;
    model.drag_dir = dir;
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
    fx.cancelTimer(drag_watchdog_key);
    if (is_linux) readPosition(model, fx);
    if (model.connected and model.driven) {
        // position goes BEFORE dragEnd (native-protocol.mjs).
        if (model.have_position) send(protocol.Position{ .x = model.pet_x + firstOffset(model), .y = model.pet_y, .secondSide = .left });
        send(protocol.Event{ .event = .dragEnd });
        return;
    }
    if (model.have_position) core.savePosition(args.user_data, model.pet_x + firstOffset(model), model.pet_y);
    model.local_state = null;
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
        .quiet => |kind| {
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
        },
        .toggle_pet => {
            model.visible = !model.visible;
            core.saveEnabled(args.user_data, model.visible);
            if (model.visible) showUndriven(model, fx) else fx.cancelTimer(frame_timer_key);
            fitWindow(model, fx);
        },
        .size => |s| {
            model.size = s;
            core.saveSize(args.user_data, s);
            fitWindow(model, fx);
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
    _ = fx.moveWindow("main", want.x - firstOffset(model) - cur.x, want.y - cur.y, true);
    model.pending_move = null;
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
            if (model.once and model.frame_index + 1 >= model.frames) return;
            model.frame_index = (model.frame_index + 1) % model.frames;
            armFrameTimer(model, fx);
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
        .pointer_dblclick => onDoubleClick(model),
        .pointer_enter => {
            if (!model.hover_inside and !model.dragging) onHover(model, fx);
            model.hover_inside = true;
        },
        .pointer_leave => model.hover_inside = false,
        .bubble_click => onBubbleClick(model),
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
            showUndriven(model, fx);
        }
    }
    if (model.bubble_until_ms != 0 and now >= model.bubble_until_ms) setBubble(model, null, null, 0);
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
    }
    if (changed) showUndriven(model, fx);
    if (model.timeline) |*tl| {
        // launch.zig keeps one run at a time and backs off on failure.
        if (tl.refresh_at_ms > 0 and now >= tl.refresh_at_ms) core.refreshApp(appLaunch());
    }
}

/// Win/mac only (Linux reports pointer and drag through commands): the
/// frame clock samples cursor and button like upstream's app-owned drag.
fn frameClock(model: *Model, fx: *Effects) void {
    const read = fx.moveWindow("main", 0, 0, false) orelse return;
    model.pet_x = read.x;
    model.pet_y = read.y;
    model.have_position = true;
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
                onDoubleClick(model);
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
    model.hover_inside = inside;
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

fn spriteNode(ui: *AppUi, model: *const Model, base: u64, label: []const u8) AppUi.Node {
    var node = ui.image(.{
        .width = spriteW(model),
        .height = spriteH(model),
        .image = base + model.frame_index,
        .semantics = .{ .label = label },
    });
    node.widget.image_fit = .stretch;
    node.widget.image_sampling = .nearest;
    return node;
}

pub fn rootView(ui: *AppUi, model: *const Model) AppUi.Node {
    const menu = petMenu(model);
    if (!onScreen(model) or !model.first.ok) {
        return ui.el(.stack, .{ .grow = 1, .context_menu = menu }, .{});
    }
    var first = spriteNode(ui, model, first_image_base, "TracingInsights pet");
    first.context_menu = menu;
    const body = if (showsDuo(model)) blk: {
        var second = spriteNode(ui, model, second_image_base, "Second pet");
        second.context_menu = menu;
        // The second pet stands on the left (pet-window.mjs duoSecondSide).
        break :blk ui.row(.{ .gap = duoGap(model), .cross = .end }, .{ second, first });
    } else first;
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

// ---------------------------------------------------------------- bubble

const bubble_w: f32 = 260;
const bubble_h: f32 = 64;
const bubble_gap: f32 = 6;

fn bubbleShown(model: *const Model) bool {
    return onScreen(model) and model.first.ok and model.bubble_len > 0;
}

fn petWindows(model: *const Model, scratch: *PetApp.WindowsScratch) []const PetApp.WindowDescriptor {
    if (!bubbleShown(model)) return scratch.windows[0..0];
    if (is_linux) {
        // A GtkPopover anchored above the sprite (upstream's Linux path):
        // GTK_POS_TOP places the popup above the pointing rectangle.
        scratch.windows[0] = .{
            .label = "bubble",
            .canvas_label = "bubble-canvas",
            .width = bubble_w,
            .height = bubble_h,
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
            .label = "bubble",
            .canvas_label = "bubble-canvas",
            .width = bubble_w,
            .height = bubble_h,
            .x = @floatCast(model.pet_x + windowW(model) / 2 - bubble_w / 2),
            .y = @floatCast(model.pet_y - bubble_h - bubble_gap),
            .resizable = false,
            .titlebar = .chromeless,
            .floating = true,
            .fullscreen_overlay = true,
            .transparent = true,
        };
    }
    return scratch.windows[0..1];
}

fn windowView(ui: *AppUi, model: *const Model, label: []const u8) AppUi.Node {
    _ = label;
    var text = ui.text(.{ .size = .sm }, model.bubble[0..model.bubble_len]);
    text.widget.style.foreground = if (model.dark) canvas.Color.rgb8(237, 237, 238) else canvas.Color.rgb8(17, 17, 17);
    var card = ui.el(.panel, .{ .padding = 10, .on_press = .bubble_click, .semantics = .{ .label = "Pet bubble" } }, .{text});
    card.widget.style.radius = 14;
    card.widget.style.stroke_width = 1;
    if (model.dark) {
        card.widget.style.background = canvas.Color.rgb8(25, 25, 28);
        card.widget.style.border = canvas.Color.rgba8(255, 255, 255, 26);
    } else {
        card.widget.style.background = canvas.Color.rgb8(255, 255, 255);
        card.widget.style.border = canvas.Color.rgb8(214, 214, 220);
    }
    return ui.column(.{ .grow = 1, .main = .end, .cross = .center }, .{card});
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
        const pid: u32 = if (builtin.os.tag == .linux) @intCast(std.os.linux.getpid()) else if (builtin.os.tag == .windows) 0 else @intCast(std.c.getpid());
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
}
