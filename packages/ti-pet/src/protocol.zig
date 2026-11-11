//! TracingInsights pet protocol, native side.
//!
//! Mirrors desktop/src/pets/native-protocol.mjs in the tif1ai repo
//! (NATIVE_PROTOCOL_VERSION 1): one UTF-8 JSON object per line, at most
//! `max_line_bytes`, `kind` first. Change both files together.
//!
//! Electron -> native: hello, show, hide, render, menu, handoff, quit.
//! native -> Electron: ready, event, position, menuAction, ack, error.
//!
//! Parsing is strict about shape and lenient about extra keys: an unknown
//! kind or a field of the wrong type rejects the line (the caller drops the
//! connection, as the desktop side does), unknown keys are ignored so a
//! newer desktop can add fields without breaking an older pet.
//!
//! Round 3 grew the render payload without a version bump (both sides
//! require an equal `protocol` at hello / ready, so a bump would turn every
//! skew into "no native pet"). Instead the pet lists what it draws in
//! `ready.caps` (`caps` below) and Electron leaves out what an older pet
//! lacks. Every new field defaults to "nothing new", and its unknown
//! *values* (a future motion, badge kind or second-sprite state) are read
//! as that default rather than rejecting the line. The new events
//! (bubbleAction, panelAction — `close` included, when the pet shuts the
//! panel itself) are only ever sent in answer to a field only a newer
//! Electron sends, so an older Electron never sees one.

const std = @import("std");
const sprite = @import("sprite.zig");

pub const protocol_version: u32 = 1;
/// What this pet draws (`ready.caps`): v1's four, then round 3's. Electron
/// strips a payload field whose cap is missing (native-protocol.mjs).
pub const caps = [_][]const u8{
    "duo",    "bubble",      "menu",           "timeline",
    // round 3
    "motion", "sleep",       "bubble-actions", "panel",
    "badge",  "second-anim", "v2-rows",        "timeline-v2",
};
pub const max_line_bytes: usize = 64 * 1024;
pub const max_path_bytes: usize = 1024;
pub const max_text_bytes: usize = 600;
pub const max_menu_items: usize = 32;
pub const max_menu_id_bytes: usize = 64;
pub const max_menu_label_bytes: usize = 96;
pub const token_hex_len: usize = 64;
/// Bubble buttons (SPEC 2e: at most three; more are dropped).
pub const max_bubble_actions: usize = 3;
/// Click panel (SPEC 3a): lines and buttons beyond these are dropped.
pub const max_panel_lines: usize = 3;
pub const max_panel_actions: usize = 6;
/// 60 characters of up to four UTF-8 bytes.
pub const max_panel_line_bytes: usize = 240;
pub const max_action_id_bytes: usize = 32;
pub const max_action_label_bytes: usize = 64;
pub const max_badge_label_bytes: usize = 64;
pub const max_play_key_bytes: usize = 128;
/// A second-sprite animation may start this late at most (duo waves).
pub const max_delay_ms: u32 = 10_000;

pub const Size = enum {
    s,
    m,
    l,

    /// Display scale of a 192x208 cell (desktop contract PET_SIZES).
    pub fn scale(self: Size) f32 {
        return switch (self) {
            .s => 0.5,
            .m => 0.75,
            .l => 1.0,
        };
    }
};

/// Animation states: upstream's nine (sprite.zig, same order) plus the
/// two look-around rows of 8x11 (Petdex v2) sheets. sprite.zig stays a
/// byte-identical upstream copy, so the extension lives here.
pub const State = enum(u8) {
    idle,
    @"running-right",
    @"running-left",
    waving,
    jumping,
    failed,
    waiting,
    running,
    review,
    @"look-a",
    @"look-b",

    pub fn fromSprite(s: sprite.State) State {
        return @enumFromInt(@intFromEnum(s));
    }
};

comptime {
    for (std.meta.fields(sprite.State)) |f| {
        if (!std.mem.eql(u8, f.name, @tagName(@as(State, @enumFromInt(f.value))))) {
            @compileError("protocol.State must start with sprite.State, in order");
        }
    }
}

/// Renderer-owned motion (SPEC 2a): wander while ambient, or one run
/// across the display and back at a session start.
pub const Motion = enum { roam, dash };

/// One button: a bubble action (ok, quiet-1h, quiet-session, mute) or a
/// panel action (ask, rate, stats, hot-lap, pets). Ids are not checked
/// against those lists here (Electron validates what comes back), only
/// against `actionIdOk`, so a newer Electron can add one.
pub const Action = struct {
    id: []const u8,
    label: []const u8,
};

pub const Panel = struct {
    lines: []const []const u8,
    actions: []const Action,
};

pub const Badge = struct {
    label: []const u8,
};

/// An animation: the render payload's own fields, or `secondAnim` (the
/// duo partner's own reaction, started `delay_ms` late).
pub const Anim = struct {
    state: State,
    row: u8,
    frames: u8,
    duration_ms: u32,
    once: bool = false,
    still: bool = false,
    play_key: []const u8 = "",
    delay_ms: u32 = 0,
};

pub const Sprite = struct {
    path: []const u8,
    /// Atlas rows (9 = v1, 11 = v2).
    rows: u8,
    /// Sheet pixel scale (1 = 192x208 cells).
    scale: f32,
};

pub const Render = struct {
    state: State,
    row: u8,
    frames: u8,
    duration_ms: u32,
    once: bool,
    still: bool,
    play_key: []const u8,
    bubble: ?[]const u8,
    size: Size,
    atlas: Sprite,
    second: ?Sprite,
    // --- round 3; each defaults to "nothing new" ---
    motion: ?Motion = null,
    /// Still frame plus the "z z" mark (SPEC 2b).
    sleeping: bool = false,
    bubble_actions: []const Action = &.{},
    /// Open while non-null (Electron toggles it on click).
    panel: ?Panel = null,
    badge: ?Badge = null,
    /// Null: the second sprite plays the first's animation.
    second_anim: ?Anim = null,

    pub fn anim(self: Render) Anim {
        return .{
            .state = self.state,
            .row = self.row,
            .frames = self.frames,
            .duration_ms = self.duration_ms,
            .once = self.once,
            .still = self.still,
            .play_key = self.play_key,
        };
    }
};

pub const Point = struct { x: f64, y: f64 };

pub const Show = struct {
    size: Size,
    duo: bool,
    position: ?Point,
};

pub const QuietKind = enum { session, @"1h", off };

/// What the pet does with a menu item while no Electron is connected
/// (`offline` in native-protocol.mjs MenuItem).
pub const Offline = union(enum) {
    open: []const u8,
    install_update,
    quit,
    quiet: QuietKind,
    toggle_pet,
    size: Size,
    launch_at_login,
};

pub const MenuKind = enum { normal, checkbox, radio, separator };

/// One menu row. Submenus are flattened by the parser: a child's label is
/// prefixed with its parent's ("Quiet: For 1 hour"), because neither the
/// tray nor the canvas context menu of the Native SDK nests.
pub const MenuItem = struct {
    id: []const u8,
    label: []const u8,
    kind: MenuKind = .normal,
    checked: bool = false,
    enabled: bool = true,
    offline: ?Offline = null,
};

pub const Menu = struct {
    tray: []const MenuItem,
    pet: []const MenuItem,
};

pub const Hello = struct {
    token: []const u8,
    protocol: u32,
};

pub const Inbound = union(enum) {
    hello: Hello,
    show: Show,
    hide,
    render: Render,
    menu: Menu,
    handoff: []const u8,
    quit,
};

pub const ParseError = error{ InvalidLine, LineTooLong, OutOfMemory };

/// Parse one line (without its newline). Slices in the result point into
/// `arena`-owned memory; free the arena when done with the message.
pub fn parseLine(arena: std.mem.Allocator, line: []const u8) ParseError!Inbound {
    if (line.len > max_line_bytes) return error.LineTooLong;
    if (!std.unicode.utf8ValidateSlice(line)) return error.InvalidLine;
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = max_line_bytes,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidLine;
    if (root != .object) return error.InvalidLine;
    const obj = root.object;
    const kind = str(obj, "kind") orelse return error.InvalidLine;

    if (eql(kind, "hello")) {
        const token = str(obj, "token") orelse return error.InvalidLine;
        const version = int(obj, "protocol") orelse return error.InvalidLine;
        if (version < 0 or version > std.math.maxInt(u32)) return error.InvalidLine;
        return .{ .hello = .{ .token = token, .protocol = @intCast(version) } };
    }
    if (eql(kind, "show")) {
        const size = parseSize(str(obj, "size")) orelse .m;
        const duo = boolean(obj, "duo") orelse false;
        var position: ?Point = null;
        if (obj.get("position")) |p| switch (p) {
            .null => {},
            .object => |o| {
                const x = num(o, "x") orelse return error.InvalidLine;
                const y = num(o, "y") orelse return error.InvalidLine;
                if (@abs(x) > 1e6 or @abs(y) > 1e6) return error.InvalidLine;
                position = .{ .x = x, .y = y };
            },
            else => return error.InvalidLine,
        };
        return .{ .show = .{ .size = size, .duo = duo, .position = position } };
    }
    if (eql(kind, "hide")) return .hide;
    if (eql(kind, "quit")) return .quit;
    if (eql(kind, "handoff")) {
        const path = str(obj, "timelinePath") orelse return error.InvalidLine;
        if (path.len == 0 or path.len > max_path_bytes) return error.InvalidLine;
        return .{ .handoff = path };
    }
    if (eql(kind, "render")) {
        const payload = switch (obj.get("payload") orelse return error.InvalidLine) {
            .object => |o| o,
            else => return error.InvalidLine,
        };
        return .{ .render = try parseRender(arena, payload) };
    }
    if (eql(kind, "menu")) {
        const tray = try parseMenu(arena, obj.get("tray"));
        const pet = try parseMenu(arena, obj.get("pet"));
        return .{ .menu = .{ .tray = tray, .pet = pet } };
    }
    return error.InvalidLine;
}

fn parseRender(arena: std.mem.Allocator, o: std.json.ObjectMap) ParseError!Render {
    const state_name = str(o, "state") orelse return error.InvalidLine;
    const state = std.meta.stringToEnum(State, state_name) orelse return error.InvalidLine;
    const row = int(o, "row") orelse return error.InvalidLine;
    const frames = int(o, "frames") orelse return error.InvalidLine;
    const duration = int(o, "durationMs") orelse return error.InvalidLine;
    if (row < 0 or row > 10 or frames < 1 or frames > 8) return error.InvalidLine;
    if (duration < 0 or duration > 60_000) return error.InvalidLine;
    const atlas = try parseSprite(o.get("atlas") orelse return error.InvalidLine) orelse return error.InvalidLine;
    const second = if (o.get("second")) |v| try parseSprite(v) else null;
    var bubble: ?[]const u8 = null;
    if (o.get("bubble")) |b| switch (b) {
        .null => {},
        .string => |s| bubble = clipUtf8(s, max_text_bytes),
        else => return error.InvalidLine,
    };
    return .{
        .state = state,
        .row = @intCast(row),
        .frames = @intCast(frames),
        .duration_ms = @intCast(duration),
        .once = boolean(o, "once") orelse false,
        .still = boolean(o, "still") orelse false,
        .play_key = clipUtf8(str(o, "playKey") orelse "", max_play_key_bytes),
        .bubble = if (bubble) |text| (if (text.len == 0) null else text) else null,
        .size = parseSize(str(o, "size")) orelse .m,
        .atlas = atlas,
        .second = second,
        .motion = try parseMotion(o.get("motion")),
        .sleeping = try optionalBool(o, "sleeping"),
        .bubble_actions = try parseActions(arena, o.get("bubbleActions"), max_bubble_actions),
        .panel = try parsePanel(arena, o.get("panel")),
        .badge = try parseBadge(o.get("badge")),
        .second_anim = try parseAnim(o.get("secondAnim")),
    };
}

/// null / missing = no motion; an unknown value too (a newer motion).
pub fn parseMotion(v: ?std.json.Value) ParseError!?Motion {
    return switch (v orelse return null) {
        .null => null,
        .string => |s| std.meta.stringToEnum(Motion, s),
        else => error.InvalidLine,
    };
}

/// Missing = false; a non-boolean rejects.
pub fn optionalBool(o: std.json.ObjectMap, key: []const u8) ParseError!bool {
    return switch (o.get(key) orelse return false) {
        .bool => |b| b,
        .null => false,
        else => error.InvalidLine,
    };
}

/// `[{ id, label }]` (or null): at most `max` kept, labels clipped.
pub fn parseActions(arena: std.mem.Allocator, v: ?std.json.Value, max: usize) ParseError![]const Action {
    const items = switch (v orelse return &.{}) {
        .null => return &.{},
        .array => |a| a.items,
        else => return error.InvalidLine,
    };
    var out: std.ArrayList(Action) = .empty;
    for (items) |raw| {
        const o = switch (raw) {
            .object => |o| o,
            else => return error.InvalidLine,
        };
        const id = str(o, "id") orelse return error.InvalidLine;
        if (!actionIdOk(id)) return error.InvalidLine;
        const label = str(o, "label") orelse return error.InvalidLine;
        if (out.items.len >= max) continue;
        try out.append(arena, .{ .id = id, .label = clipUtf8(label, max_action_label_bytes) });
    }
    return out.items;
}

/// `{ lines: string[], actions: [{ id, label }] }` (or null).
fn parsePanel(arena: std.mem.Allocator, v: ?std.json.Value) ParseError!?Panel {
    const o = switch (v orelse return null) {
        .null => return null,
        .object => |o| o,
        else => return error.InvalidLine,
    };
    var lines: std.ArrayList([]const u8) = .empty;
    switch (o.get("lines") orelse std.json.Value.null) {
        .null => {},
        .array => |a| for (a.items) |item| {
            const line = switch (item) {
                .string => |s| s,
                else => return error.InvalidLine,
            };
            if (line.len == 0 or lines.items.len >= max_panel_lines) continue;
            try lines.append(arena, clipUtf8(line, max_panel_line_bytes));
        },
        else => return error.InvalidLine,
    }
    return .{
        .lines = lines.items,
        .actions = try parseActions(arena, o.get("actions"), max_panel_actions),
    };
}

/// `{ kind: 'answer', label }` (or null); another kind is read as null.
fn parseBadge(v: ?std.json.Value) ParseError!?Badge {
    const o = switch (v orelse return null) {
        .null => return null,
        .object => |o| o,
        else => return error.InvalidLine,
    };
    const kind = str(o, "kind") orelse return error.InvalidLine;
    if (!eql(kind, "answer")) return null;
    const label = str(o, "label") orelse "";
    return .{ .label = clipUtf8(if (label.len == 0) "Answer ready" else label, max_badge_label_bytes) };
}

/// `{ state, row, frames, durationMs, once, still, playKey, delayMs? }` or
/// null. A state this pet does not know reads as null (the second sprite
/// then mirrors the first); a bad row / frame count rejects like the
/// payload's own.
pub fn parseAnim(v: ?std.json.Value) ParseError!?Anim {
    const o = switch (v orelse return null) {
        .null => return null,
        .object => |o| o,
        else => return error.InvalidLine,
    };
    const state_name = str(o, "state") orelse return error.InvalidLine;
    const row = int(o, "row") orelse return error.InvalidLine;
    const frames = int(o, "frames") orelse return error.InvalidLine;
    const duration = int(o, "durationMs") orelse return error.InvalidLine;
    if (row < 0 or row > 10 or frames < 1 or frames > 8) return error.InvalidLine;
    if (duration < 0 or duration > 60_000) return error.InvalidLine;
    const delay: i64 = switch (o.get("delayMs") orelse std.json.Value.null) {
        .null => 0,
        else => int(o, "delayMs") orelse return error.InvalidLine,
    };
    if (delay < 0) return error.InvalidLine;
    const state = std.meta.stringToEnum(State, state_name) orelse return null;
    return .{
        .state = state,
        .row = @intCast(row),
        .frames = @intCast(frames),
        .duration_ms = @intCast(duration),
        .once = try optionalBool(o, "once"),
        .still = try optionalBool(o, "still"),
        .play_key = clipUtf8(str(o, "playKey") orelse "", max_play_key_bytes),
        .delay_ms = @intCast(@min(delay, max_delay_ms)),
    };
}

/// Action ids: `[a-z0-9-]`, 1–32 bytes.
pub fn actionIdOk(id: []const u8) bool {
    if (id.len == 0 or id.len > max_action_id_bytes) return false;
    for (id) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn parseSprite(v: std.json.Value) ParseError!?Sprite {
    const o = switch (v) {
        .null => return null,
        .object => |o| o,
        else => return error.InvalidLine,
    };
    const path = str(o, "path") orelse return error.InvalidLine;
    if (path.len == 0 or path.len > max_path_bytes) return error.InvalidLine;
    const rows = int(o, "rows") orelse 9;
    if (rows != 9 and rows != 11) return error.InvalidLine;
    const scale = num(o, "scale") orelse 1;
    if (!(scale > 0 and scale <= 8)) return error.InvalidLine;
    return .{ .path = path, .rows = @intCast(rows), .scale = @floatCast(scale) };
}

fn parseMenu(arena: std.mem.Allocator, v: ?std.json.Value) ParseError![]const MenuItem {
    const value = v orelse return &.{};
    const items = switch (value) {
        .array => |a| a.items,
        .null => return &.{},
        else => return error.InvalidLine,
    };
    var out: std.ArrayList(MenuItem) = .empty;
    try flatten(arena, &out, items, "");
    return out.items;
}

fn flatten(arena: std.mem.Allocator, out: *std.ArrayList(MenuItem), items: []const std.json.Value, prefix: []const u8) ParseError!void {
    for (items) |raw| {
        if (out.items.len >= max_menu_items) return;
        const o = switch (raw) {
            .object => |o| o,
            else => return error.InvalidLine,
        };
        const id = str(o, "id") orelse return error.InvalidLine;
        if (!menuIdOk(id)) return error.InvalidLine;
        const label = clipUtf8(str(o, "label") orelse "", max_menu_label_bytes);
        const kind: MenuKind = if (str(o, "type")) |t|
            std.meta.stringToEnum(MenuKind, t) orelse return error.InvalidLine
        else
            .normal;
        if (o.get("submenu")) |sub| switch (sub) {
            .array => |a| {
                const child_prefix = try std.fmt.allocPrint(arena, "{s}{s}: ", .{ prefix, label });
                try flatten(arena, out, a.items, child_prefix);
                continue;
            },
            .null => {},
            else => return error.InvalidLine,
        };
        if (kind == .separator) {
            // No leading or doubled separators after flattening.
            if (out.items.len == 0 or out.items[out.items.len - 1].kind == .separator) continue;
            try out.append(arena, .{ .id = id, .label = "", .kind = .separator });
            continue;
        }
        const full_label = if (prefix.len > 0)
            clipUtf8(try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, label }), max_menu_label_bytes)
        else
            label;
        try out.append(arena, .{
            .id = id,
            .label = full_label,
            .kind = kind,
            .checked = boolean(o, "checked") orelse false,
            .enabled = boolean(o, "enabled") orelse true,
            .offline = try parseOffline(o.get("offline")),
        });
    }
}

fn parseOffline(v: ?std.json.Value) ParseError!?Offline {
    const value = v orelse return null;
    const o = switch (value) {
        .object => |o| o,
        .null => return null,
        else => return error.InvalidLine,
    };
    const action = str(o, "do") orelse return error.InvalidLine;
    if (eql(action, "open")) {
        const path = str(o, "path") orelse return error.InvalidLine;
        if (!appPathOk(path)) return error.InvalidLine;
        return .{ .open = path };
    }
    if (eql(action, "install-update")) return .install_update;
    if (eql(action, "quit")) return .quit;
    if (eql(action, "toggle-pet")) return .toggle_pet;
    if (eql(action, "launch-at-login")) return .launch_at_login;
    if (eql(action, "quiet")) {
        const kind = std.meta.stringToEnum(QuietKind, str(o, "kind") orelse "") orelse return error.InvalidLine;
        return .{ .quiet = kind };
    }
    if (eql(action, "size")) {
        return .{ .size = parseSize(str(o, "size")) orelse return error.InvalidLine };
    }
    // An action this pet does not know: keep the item, do nothing offline.
    return null;
}

/// Same rule as parsePetsOpenArg on the desktop side: "/..." only, never
/// "//host", backslashes or control characters.
pub fn appPathOk(path: []const u8) bool {
    if (path.len == 0 or path.len > 512) return false;
    if (path[0] != '/') return false;
    if (path.len > 1 and path[1] == '/') return false;
    for (path) |c| {
        if (c == '\\' or c < 0x20 or c == 0x7f) return false;
    }
    return true;
}

pub fn menuIdOk(id: []const u8) bool {
    if (id.len == 0 or id.len > max_menu_id_bytes) return false;
    for (id) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '.' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// Constant-time token comparison (the token file holds 64 hex chars).
pub fn tokenMatches(expected: []const u8, got: []const u8) bool {
    const want = std.mem.trim(u8, expected, " \t\r\n");
    if (want.len != token_hex_len or got.len != token_hex_len) return false;
    var diff: u8 = 0;
    for (want, got) |a, b| diff |= a ^ b;
    return diff == 0;
}

// ------------------------------------------------------------- outbound

pub const NativeEvent = enum {
    drag,
    dragEnd,
    click,
    dblclick,
    hover,
    bubbleClick,
    // round 3: sent only while the payload carries what they answer
    /// A bubble button (`id` = one of the payload's bubbleActions).
    bubbleAction,
    /// A panel button (`id` = one of the payload's panel actions), or
    /// `id` = `panel_close_id` when the pet closed the panel itself.
    panelAction,
};

/// panelAction id for "the pet closed the panel" (20 s without the
/// pointer, Escape): contract.mjs PANEL_CLOSE_ID.
pub const panel_close_id = "close";
pub const SecondSide = enum { left, right };

/// Encode an outbound message as one JSON line (with its newline) into
/// `buf`. Returns the written slice, or null when it does not fit.
pub fn encode(buf: []u8, message: anytype) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    std.json.Stringify.value(message, .{ .emit_null_optional_fields = false }, &w) catch return null;
    w.writeByte('\n') catch return null;
    return w.buffered();
}

pub const Ready = struct {
    kind: []const u8 = "ready",
    protocol: u32 = protocol_version,
    version: []const u8,
    caps: []const []const u8,
    pid: u32,
};

pub const Event = struct {
    kind: []const u8 = "event",
    event: NativeEvent,
    dx: ?f64 = null,
    dy: ?f64 = null,
    id: ?[]const u8 = null,
};

pub const Position = struct {
    kind: []const u8 = "position",
    x: f64,
    y: f64,
    displayId: ?[]const u8 = null,
    secondSide: SecondSide = .left,
    /// Sent at the end of a walk (motion): save it like a drop.
    walk: ?bool = null,
};

pub const MenuAction = struct {
    kind: []const u8 = "menuAction",
    id: []const u8,
    checked: ?bool = null,
};

pub const Ack = struct {
    kind: []const u8 = "ack",
    of: []const u8 = "handoff",
};

pub const Error = struct {
    kind: []const u8 = "error",
    code: []const u8,
    message: []const u8,
};

// -------------------------------------------------------------- helpers

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn str(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn boolean(o: std.json.ObjectMap, key: []const u8) ?bool {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

fn int(o: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f) and @floor(f) == f and @abs(f) < 1e15) @intFromFloat(f) else null,
        else => null,
    };
}

fn num(o: std.json.ObjectMap, key: []const u8) ?f64 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| if (std.math.isFinite(f)) f else null,
        else => null,
    };
}

fn parseSize(s: ?[]const u8) ?Size {
    return std.meta.stringToEnum(Size, s orelse return null);
}

/// Longest prefix of `s` that is at most `max` bytes and ends on a UTF-8
/// boundary.
pub fn clipUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn parseTest(line: []const u8) !Inbound {
    return parseLine(testing.allocator, line);
}

test "hello, hide, quit, handoff" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hello = try parseLine(a, "{\"kind\":\"hello\",\"token\":\"ab\",\"protocol\":1,\"appVersion\":\"0.2.0\"}");
    try testing.expectEqualStrings("ab", hello.hello.token);
    try testing.expectEqual(@as(u32, 1), hello.hello.protocol);
    try testing.expect((try parseLine(a, "{\"kind\":\"hide\"}")) == .hide);
    try testing.expect((try parseLine(a, "{\"kind\":\"quit\"}")) == .quit);
    const h = try parseLine(a, "{\"kind\":\"handoff\",\"timelinePath\":\"/u/pet-timeline.json\"}");
    try testing.expectEqualStrings("/u/pet-timeline.json", h.handoff);
}

test "render payload" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const line =
        \\{"kind":"render","payload":{"state":"running-left","row":2,"frames":8,"durationMs":1060,
        \\"once":false,"still":false,"playKey":"k1","bubble":"Qualifying in 2 h · São Paulo GP","size":"l",
        \\"atlas":{"path":"/p/a.webp","rows":11,"scale":1},"second":{"path":"/p/b.png","rows":9,"scale":2}}}
    ;
    const msg = try parseLine(arena.allocator(), line);
    const r = msg.render;
    try testing.expectEqual(State.@"running-left", r.state);
    try testing.expectEqual(@as(u8, 2), r.row);
    try testing.expectEqual(@as(u8, 8), r.frames);
    try testing.expectEqual(@as(u32, 1060), r.duration_ms);
    try testing.expectEqual(Size.l, r.size);
    try testing.expectEqualStrings("/p/a.webp", r.atlas.path);
    try testing.expectEqual(@as(u8, 11), r.atlas.rows);
    try testing.expectEqualStrings("/p/b.png", r.second.?.path);
    try testing.expectEqual(@as(f32, 2), r.second.?.scale);
    try testing.expect(std.mem.startsWith(u8, r.bubble.?, "Qualifying"));
}

test "render: a v1 payload reads every round-3 field as nothing new" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = (try parseLine(arena.allocator(),
        \\{"kind":"render","payload":{"state":"idle","row":0,"frames":6,"durationMs":1100,"once":false,"still":false,
        \\"playKey":"idle","bubble":null,"size":"m","atlas":{"path":"/p/a.png","rows":9,"scale":1},"second":null}}
    )).render;
    try testing.expect(r.motion == null and !r.sleeping and r.bubble_actions.len == 0);
    try testing.expect(r.panel == null and r.badge == null and r.second_anim == null);
    try testing.expectEqual(State.idle, r.anim().state);
    try testing.expectEqual(@as(u32, 0), r.anim().delay_ms);
}

test "render: round-3 fields (motion, sleep, bubble buttons, panel, badge, secondAnim, v2 rows)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const line =
        \\{"kind":"render","payload":{"state":"look-a","row":9,"frames":8,"durationMs":1120,"once":true,"still":false,
        \\"playKey":"look:1","bubble":"Did you know?","size":"m","atlas":{"path":"/p/a.webp","rows":11,"scale":1},
        \\"second":{"path":"/p/b.webp","rows":9,"scale":1},"motion":"roam","sleeping":true,
        \\"bubbleActions":[{"id":"ok","label":"OK"},{"id":"quiet-1h","label":"Quiet 1 h"},{"id":"mute","label":"No daily facts"},{"id":"quiet-session","label":"x"}],
        \\"panel":{"lines":["Race in 2 h · Abu Dhabi GP","Norris P1","three","four"],"actions":[{"id":"ask","label":"Ask F1"},{"id":"hot-lap","label":"Hot lap"}]},
        \\"badge":{"kind":"answer","label":"Answer ready"},
        \\"secondAnim":{"state":"waving","row":3,"frames":4,"durationMs":700,"once":true,"still":false,"playKey":"duo-wave:2","delayMs":700},
        \\"future":{"x":1}}}
    ;
    const r = (try parseLine(arena.allocator(), line)).render;
    try testing.expectEqual(State.@"look-a", r.state);
    try testing.expectEqual(@as(u8, 9), r.row);
    try testing.expectEqual(Motion.roam, r.motion.?);
    try testing.expect(r.sleeping);
    // At most three bubble buttons; the fourth is dropped.
    try testing.expectEqual(@as(usize, 3), r.bubble_actions.len);
    try testing.expectEqualStrings("mute", r.bubble_actions[2].id);
    try testing.expectEqualStrings("No daily facts", r.bubble_actions[2].label);
    // At most three panel lines.
    try testing.expectEqual(@as(usize, 3), r.panel.?.lines.len);
    try testing.expectEqualStrings("Norris P1", r.panel.?.lines[1]);
    try testing.expectEqualStrings("hot-lap", r.panel.?.actions[1].id);
    try testing.expectEqualStrings("Answer ready", r.badge.?.label);
    const second = r.second_anim.?;
    try testing.expectEqual(State.waving, second.state);
    try testing.expectEqual(@as(u32, 700), second.delay_ms);
    try testing.expect(second.once);
    try testing.expectEqualStrings("duo-wave:2", second.play_key);
}

test "render: unknown round-3 values read as nothing new, wrong types reject" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const head = "{\"kind\":\"render\",\"payload\":{\"state\":\"idle\",\"row\":0,\"frames\":6,\"durationMs\":1100,\"atlas\":{\"path\":\"/a\"},";
    const lenient = [_][]const u8{
        "\"motion\":\"fly\"}}",
        "\"badge\":{\"kind\":\"mail\",\"label\":\"x\"}}}",
        "\"secondAnim\":{\"state\":\"dance\",\"row\":0,\"frames\":6,\"durationMs\":1}}}",
        "\"panel\":null,\"bubbleActions\":null,\"secondAnim\":null,\"badge\":null,\"motion\":null}}",
    };
    for (lenient) |tail| {
        const r = (try parseLine(a, try std.mem.concat(a, u8, &.{ head, tail }))).render;
        try testing.expect(r.motion == null and r.badge == null and r.second_anim == null and r.panel == null);
    }
    // Delays are capped; a missing badge label gets the default.
    const capped = (try parseLine(a, try std.mem.concat(a, u8, &.{ head, "\"secondAnim\":{\"state\":\"idle\",\"row\":0,\"frames\":6,\"durationMs\":1,\"delayMs\":99999},\"badge\":{\"kind\":\"answer\"}}}" }))).render;
    try testing.expectEqual(max_delay_ms, capped.second_anim.?.delay_ms);
    try testing.expectEqualStrings("Answer ready", capped.badge.?.label);
    const strict = [_][]const u8{
        "\"motion\":1}}",
        "\"sleeping\":\"yes\"}}",
        "\"bubbleActions\":{\"id\":\"ok\"}}}",
        "\"bubbleActions\":[{\"id\":\"OK!\",\"label\":\"OK\"}]}}",
        "\"bubbleActions\":[{\"id\":\"ok\"}]}}",
        "\"panel\":{\"lines\":[1],\"actions\":[]}}}",
        "\"panel\":[]}}",
        "\"badge\":\"answer\"}}",
        "\"secondAnim\":{\"state\":\"idle\",\"row\":11,\"frames\":6,\"durationMs\":1}}}",
        "\"secondAnim\":{\"state\":\"idle\",\"row\":0,\"frames\":6,\"durationMs\":1,\"delayMs\":-1}}}",
    };
    for (strict) |tail| {
        try testing.expectError(error.InvalidLine, parseLine(a, try std.mem.concat(a, u8, &.{ head, tail })));
    }
}

test "State extends sprite.State in order" {
    try testing.expectEqual(State.review, State.fromSprite(.review));
    try testing.expectEqual(State.@"running-left", State.fromSprite(.@"running-left"));
    try testing.expect(actionIdOk("quiet-session") and actionIdOk("hot-lap"));
    try testing.expect(!actionIdOk("") and !actionIdOk("Quiet") and !actionIdOk("a.b") and !actionIdOk("x" ** 33));
}

test "render rejects bad shapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = [_][]const u8{
        "{\"kind\":\"render\"}",
        "{\"kind\":\"render\",\"payload\":{\"state\":\"dancing\",\"row\":0,\"frames\":6,\"durationMs\":1,\"atlas\":{\"path\":\"/a\"}}}",
        "{\"kind\":\"render\",\"payload\":{\"state\":\"idle\",\"row\":0,\"frames\":9,\"durationMs\":1,\"atlas\":{\"path\":\"/a\"}}}",
        "{\"kind\":\"render\",\"payload\":{\"state\":\"idle\",\"row\":0,\"frames\":6,\"durationMs\":1,\"atlas\":{\"path\":\"/a\",\"rows\":10}}}",
        "{\"kind\":\"render\",\"payload\":{\"state\":\"idle\",\"row\":0,\"frames\":6,\"durationMs\":1,\"atlas\":null}}",
        "{\"kind\":\"nope\"}",
        "[1,2]",
        "{\"kind\":\"hello\",\"token\":\"a\",\"token\":\"b\",\"protocol\":1}",
        "not json",
    };
    for (bad) |line| try testing.expectError(error.InvalidLine, parseLine(a, line));
}

test "oversize line" {
    const big = try testing.allocator.alloc(u8, max_line_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, ' ');
    try testing.expectError(error.LineTooLong, parseTest(big));
}

test "menu flattens submenus and maps offline actions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const line =
        \\{"kind":"menu","tray":[
        \\ {"id":"tray.open-tracinginsights","label":"Open TracingInsights","offline":{"do":"open","path":"/"}},
        \\ {"id":"tray.sep-1","label":"","type":"separator"},
        \\ {"id":"tray.quiet","label":"Quiet","submenu":[
        \\   {"id":"tray.quiet.for-1-hour","label":"For 1 hour","offline":{"do":"quiet","kind":"1h"}},
        \\   {"id":"tray.quiet.off","label":"Off","type":"radio","checked":true,"offline":{"do":"quiet","kind":"off"}}]},
        \\ {"id":"tray.launch-at-login","label":"Launch at login","type":"checkbox","checked":false,"offline":{"do":"launch-at-login"}},
        \\ {"id":"tray.restart-to-update","label":"Restart to update (0.3.0)","offline":{"do":"install-update"}},
        \\ {"id":"tray.future","label":"Future","offline":{"do":"teleport"}},
        \\ {"id":"tray.quit","label":"Quit","offline":{"do":"quit"}}],
        \\ "pet":[{"id":"pet.size.small","label":"Small","offline":{"do":"size","size":"s"}}]}
    ;
    const msg = try parseLine(arena.allocator(), line);
    const tray = msg.menu.tray;
    try testing.expectEqual(@as(usize, 8), tray.len);
    try testing.expectEqualStrings("/", tray[0].offline.?.open);
    try testing.expectEqual(MenuKind.separator, tray[1].kind);
    try testing.expectEqualStrings("Quiet: For 1 hour", tray[2].label);
    try testing.expectEqual(QuietKind.@"1h", tray[2].offline.?.quiet);
    try testing.expect(tray[3].checked);
    try testing.expect(tray[4].offline.? == .launch_at_login);
    try testing.expect(tray[5].offline.? == .install_update);
    try testing.expect(tray[6].offline == null);
    try testing.expectEqual(Size.s, msg.menu.pet[0].offline.?.size);
}

test "menu rejects unsafe ids and open paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.InvalidLine, parseLine(a, "{\"kind\":\"menu\",\"tray\":[{\"id\":\"Tray Open\",\"label\":\"x\"}],\"pet\":[]}"));
    try testing.expectError(error.InvalidLine, parseLine(a, "{\"kind\":\"menu\",\"tray\":[{\"id\":\"a\",\"label\":\"x\",\"offline\":{\"do\":\"open\",\"path\":\"//evil\"}}],\"pet\":[]}"));
    try testing.expect(!appPathOk("/a\\b"));
    try testing.expect(!appPathOk("https://x"));
    try testing.expect(appPathOk("/settings/pets"));
}

test "show with and without a position" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s1 = try parseLine(a, "{\"kind\":\"show\",\"size\":\"s\",\"duo\":true,\"position\":{\"x\":10,\"y\":-20.5}}");
    try testing.expectEqual(Size.s, s1.show.size);
    try testing.expect(s1.show.duo);
    try testing.expectEqual(@as(f64, -20.5), s1.show.position.?.y);
    const s2 = try parseLine(a, "{\"kind\":\"show\",\"size\":\"m\",\"duo\":false,\"position\":null}");
    try testing.expect(s2.show.position == null);
}

test "token comparison" {
    const t = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try testing.expect(tokenMatches(t ++ "\n", t));
    try testing.expect(!tokenMatches(t, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdee"));
    try testing.expect(!tokenMatches(t, "short"));
}

test "encode outbound lines" {
    var buf: [256]u8 = undefined;
    const line = encode(&buf, Event{ .event = .drag, .dx = -12, .dy = 0 }).?;
    try testing.expectEqualStrings("{\"kind\":\"event\",\"event\":\"drag\",\"dx\":-12,\"dy\":0}\n", line);
    const click = encode(&buf, Event{ .event = .click }).?;
    try testing.expectEqualStrings("{\"kind\":\"event\",\"event\":\"click\"}\n", click);
    const pos = encode(&buf, Position{ .x = 40, .y = 60, .secondSide = .right }).?;
    try testing.expectEqualStrings("{\"kind\":\"position\",\"x\":40,\"y\":60,\"secondSide\":\"right\"}\n", pos);
    const duo_caps = [_][]const u8{"duo"};
    const ready = encode(&buf, Ready{ .version = "0.1.0", .caps = &duo_caps, .pid = 7 }).?;
    try testing.expectEqualStrings("{\"kind\":\"ready\",\"protocol\":1,\"version\":\"0.1.0\",\"caps\":[\"duo\"],\"pid\":7}\n", ready);
    var tiny: [8]u8 = undefined;
    try testing.expect(encode(&tiny, Ack{}) == null);
    // Round 3: button events carry the id; a walk's end says so.
    try testing.expectEqualStrings(
        "{\"kind\":\"event\",\"event\":\"bubbleAction\",\"id\":\"quiet-1h\"}\n",
        encode(&buf, Event{ .event = .bubbleAction, .id = "quiet-1h" }).?,
    );
    try testing.expectEqualStrings(
        "{\"kind\":\"event\",\"event\":\"panelAction\",\"id\":\"ask\"}\n",
        encode(&buf, Event{ .event = .panelAction, .id = "ask" }).?,
    );
    try testing.expectEqualStrings(
        "{\"kind\":\"event\",\"event\":\"panelAction\",\"id\":\"close\"}\n",
        encode(&buf, Event{ .event = .panelAction, .id = panel_close_id }).?,
    );
    try testing.expectEqualStrings(
        "{\"kind\":\"position\",\"x\":10,\"y\":20,\"secondSide\":\"left\",\"walk\":true}\n",
        encode(&buf, Position{ .x = 10, .y = 20, .walk = true }).?,
    );
    var big: [512]u8 = undefined;
    const all = encode(&big, Ready{ .version = "0.2.0", .caps = &caps, .pid = 7 }).?;
    for ([_][]const u8{ "\"motion\"", "\"sleep\"", "\"bubble-actions\"", "\"panel\"", "\"badge\"", "\"second-anim\"", "\"v2-rows\"", "\"timeline-v2\"" }) |cap| {
        try testing.expect(std.mem.indexOf(u8, all, cap) != null);
    }
}

test "clipUtf8 keeps whole code points" {
    try testing.expectEqualStrings("S", clipUtf8("Sã", 2));
    try testing.expectEqualStrings("Sã", clipUtf8("Sã", 3));
}
