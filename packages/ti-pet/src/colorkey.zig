//! Windows colour key: keep pure-black sprite pixels on screen.
//!
//! The Native SDK's Windows host makes a transparent window layered and
//! colour-keyed on pure black (`SetLayeredWindowAttributes(hwnd, RGB(0, 0,
//! 0), 255, LWA_COLORKEY)`, webview2_host.cpp `applyCompanionWindowChrome`):
//! the DWM drops every pixel that is exactly (0, 0, 0). The runtime clears a
//! transparent window to (0, 0, 0, 0), and the present path copies the
//! framebuffer's RGB with the alpha byte forced to 255, so the cleared
//! background is keyed away — and so is any sprite pixel that is drawn as
//! exactly black. Pet art has black outlines and eyes: on Windows they
//! became holes onto whatever is behind the pet (ti-pet-v0.1.1 too).
//!
//! What reaches the key, per source pixel: the reference renderer blends
//! STRAIGHT alpha (`blendRgba8`: out = (src·a + dst·da·(1 − a)) / out_a),
//! and a sprite is drawn over the cleared (0, 0, 0, 0) window, so the
//! blended RGB is the source's own RGB at any alpha. An alpha-128 black
//! pixel is stored as (0, 0, 0, 128) and presented as (0, 0, 0): keyed. A
//! non-black partial pixel is presented fully opaque in its own colour (the
//! key cannot blend; the SDK accepts hard edges). The decoded sheet is
//! straight alpha too (WIC `32bppRGBA`, gdk-pixbuf), so a dark colour never
//! rounds to black the way a premultiplied one could.
//!
//! The fix, before the frames are registered (Windows only): a pure-black
//! pixel at least half opaque becomes (0, 0, 1), the darkest colour that is
//! not the key. Fainter black (< 128) stays as it is, which the key drops
//! just as it drops alpha-0 pixels: a soft black shadow keeps falling
//! through instead of turning into a solid blob. Nothing else ti-pet draws
//! on Windows uses pure black (house theme text/surfaces are ≥ (9, 9, 11);
//! "z z", the badge and the bubble/panel are coloured), and the shadow /
//! scrim washes are translucent black that either blends over an opaque
//! card or should fall through.
//!
//! Since `patches/ti-pet-sdk-windows-present.patch` the host presents a
//! transparent window with per-pixel alpha (UpdateLayeredWindow) and keys
//! on nothing; the colour key above is only its fallback, taken when that
//! first UpdateLayeredWindow fails ("ti-pet: sdk: window … colour key" under
//! TI_PET_DEBUG). The lift stays for that fallback: on the alpha path,
//! (0, 0, 1) cannot be told from black.

const std = @import("std");
const builtin = @import("builtin");

/// Only the Windows host keys transparent windows on a colour.
pub const needed = builtin.os.tag == .windows;
/// The key (an RGB triple; the host ignores alpha when presenting).
pub const key_rgb = [3]u8{ 0, 0, 0 };
/// What a kept black pixel becomes: the darkest colour that is not the key.
pub const lifted_rgb = [3]u8{ 0, 0, 1 };
/// Black at least this opaque is kept (lifted); fainter black goes.
pub const min_alpha: u8 = 128;

/// Lift every pure-black pixel of straight-alpha RGBA8 `pixels` whose alpha
/// is at least `min_alpha` to `lifted_rgb`. Returns how many changed. A
/// trailing partial pixel is left alone.
pub fn liftKeyedBlack(pixels: []u8) usize {
    var lifted: usize = 0;
    var i: usize = 0;
    while (i + 4 <= pixels.len) : (i += 4) {
        const px = pixels[i..][0..4];
        if (px[3] < min_alpha) continue;
        if (px[0] != key_rgb[0] or px[1] != key_rgb[1] or px[2] != key_rgb[2]) continue;
        px[0] = lifted_rgb[0];
        px[1] = lifted_rgb[1];
        px[2] = lifted_rgb[2];
        lifted += 1;
    }
    return lifted;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// The Windows present of one straight-alpha sprite pixel drawn over the
/// cleared window (the renderer's straight blend, then RGB with alpha
/// forced to 255): what the DWM compares against the key.
fn presented(px: [4]u8) [3]u8 {
    if (px[3] == 0) return .{ 0, 0, 0 };
    return .{ px[0], px[1], px[2] };
}

fn keyed(px: [4]u8) bool {
    return std.mem.eql(u8, &presented(px), &key_rgb);
}

test "half-opaque and opaque black is lifted; fainter black and colours are not" {
    var pixels = [_]u8{
        0, 0, 0, 255, // opaque black (outline, eyes)
        0, 0, 0, 128, // half-opaque black: lifted
        0, 0, 0, 127, // fainter: left to the key
        0, 0, 0, 1,
        0, 0, 0, 0, // transparent
        0,   0, 1,   255, // already not the key
        1,   0, 0,   200,
        255, 0, 255, 255,
        0, 0, 0, // a trailing partial pixel is ignored
    };
    try testing.expectEqual(@as(usize, 2), liftKeyedBlack(&pixels));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 1, 255 }, pixels[0..4]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 1, 128 }, pixels[4..8]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 127 }, pixels[8..12]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1 }, pixels[12..16]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, pixels[16..20]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 1, 255 }, pixels[20..24]);
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 200 }, pixels[24..28]);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 255, 255 }, pixels[28..32]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, pixels[32..35]);
    // Idempotent.
    try testing.expectEqual(@as(usize, 0), liftKeyedBlack(&pixels));
}

test "after the lift no pixel at least half opaque reaches the key" {
    // Every alpha with a pure-black colour, plus a few dark colours.
    var pixels: [256 * 4 * 3]u8 = undefined;
    for (0..256) |a| {
        for (0..3) |c| {
            const i = (a * 3 + c) * 4;
            pixels[i..][0..4].* = switch (c) {
                0 => .{ 0, 0, 0, @intCast(a) },
                1 => .{ 0, 0, 1, @intCast(a) },
                else => .{ 9, 9, 11, @intCast(a) },
            };
        }
    }
    // Before: every non-transparent black pixel would be a hole.
    var holes_before: usize = 0;
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        const px = pixels[i..][0..4].*;
        if (px[3] > 0 and keyed(px)) holes_before += 1;
    }
    try testing.expectEqual(@as(usize, 255), holes_before);
    try testing.expectEqual(256 - @as(usize, min_alpha), liftKeyedBlack(&pixels));
    i = 0;
    while (i < pixels.len) : (i += 4) {
        const px = pixels[i..][0..4].*;
        // Gone: transparent pixels (meant to be), and black fainter than
        // `min_alpha`. Everything else stays on screen.
        const black = px[0] == 0 and px[1] == 0 and px[2] == 0;
        try testing.expectEqual(px[3] == 0 or (px[3] < min_alpha and black), keyed(px));
    }
}

test "the lift colour is not the key and is the darkest such colour" {
    try testing.expect(!std.mem.eql(u8, &lifted_rgb, &key_rgb));
    const sum = @as(u16, lifted_rgb[0]) + lifted_rgb[1] + lifted_rgb[2];
    try testing.expectEqual(@as(u16, 1), sum);
    // Blue weighs least in luminance (BT.709: 0.0722).
    try testing.expectEqual(@as(u8, 1), lifted_rgb[2]);
}
