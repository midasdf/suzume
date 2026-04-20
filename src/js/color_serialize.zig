//! color_serialize.zig — CSS Color Level 4 §15 / CSSOM §7.6 canonical
//! serialization of resolved color values for getComputedStyle.
//!
//! The serializer is JS-engine-agnostic (no qjs/kotori imports) so both
//! paths can share a single spec-correct implementation:
//!   - QuickJS: `dom_style.argbToCssColor` wraps this helper.
//!   - Kotori : `css/cssom/computed_slice.argbToSlice` may delegate here
//!              once its cascade plumbing lands (see Wave 10 notes).
//!
//! Spec references:
//!   - CSS Color 4 §15 (Serializing sRGB values)
//!     https://drafts.csswg.org/css-color-4/#serializing-sRGB-values
//!   - CSSOM §7.6 (Resolved values / legacy rgb/rgba form)
//!     https://drafts.csswg.org/cssom/#resolved-value
//!
//! Canonical form for resolved sRGB color values:
//!   - alpha == 255  → "rgb(R, G, B)"
//!   - alpha  < 255  → "rgba(R, G, B, A)" (legacy comma syntax per §7.6)
//!     where A is formatted with minimum decimal places that round-trip
//!     the underlying u8 alpha value (1, 2, or 3 decimals; "0" / "1" are
//!     written without trailing ".0" per browser convention).

const std = @import("std");

/// Canonical serialization error kinds (caller-visible).
pub const SerializeError = error{BufferTooSmall};

/// Pack 8-bit ARGB components into the storage layout used by
/// ComputedStyle (a=msb, b=lsb).
pub inline fn pack(a: u8, r: u8, g: u8, b: u8) u32 {
    return (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

/// Serialize an ARGB u32 into a caller-supplied buffer per CSS Color 4 §15 /
/// CSSOM §7.6. Returns the written slice. Returns null only if the buffer
/// cannot hold the result (caller should pass ≥32 bytes — longest form is
/// "rgba(255, 255, 255, 0.XXX)" ≈ 26 chars).
pub fn argbToBuf(argb: u32, buf: []u8) ?[]const u8 {
    const a: u8 = @intCast((argb >> 24) & 0xFF);
    const r: u8 = @intCast((argb >> 16) & 0xFF);
    const g: u8 = @intCast((argb >> 8) & 0xFF);
    const b: u8 = @intCast(argb & 0xFF);
    return componentsToBuf(r, g, b, a, buf);
}

/// Serialize 8-bit sRGB components into a caller-supplied buffer. See
/// `argbToBuf` for the canonical form. Exposed separately so callers that
/// already have unpacked components can skip the pack/unpack round-trip.
pub fn componentsToBuf(r: u8, g: u8, b: u8, a: u8, buf: []u8) ?[]const u8 {
    if (a == 255) {
        return std.fmt.bufPrint(buf, "rgb({d}, {d}, {d})", .{ r, g, b }) catch return null;
    }
    // Canonical form for alpha == 0: "rgba(R, G, B, 0)" — no trailing .0.
    // Matches Chrome/Firefox output (browser convention; CSS Color 4 §15
    // allows minimum precision, and "0" is the shortest round-trip).
    if (a == 0) {
        return std.fmt.bufPrint(buf, "rgba({d}, {d}, {d}, 0)", .{ r, g, b }) catch return null;
    }
    // Alpha is a u8 in [1,254] — pick the minimum decimal precision that
    // round-trips the byte value. 1/255≈0.004, 127/255≈0.498, 254/255≈0.996
    // so 3 decimals always suffice; shorter is allowed when exact.
    const alpha_raw: f32 = @as(f32, @floatFromInt(a)) / 255.0;
    const alpha = @round(alpha_raw * 1000.0) / 1000.0;
    if (alpha == @round(alpha * 10.0) / 10.0) {
        return std.fmt.bufPrint(buf, "rgba({d}, {d}, {d}, {d:.1})", .{ r, g, b, alpha }) catch return null;
    } else if (alpha == @round(alpha * 100.0) / 100.0) {
        return std.fmt.bufPrint(buf, "rgba({d}, {d}, {d}, {d:.2})", .{ r, g, b, alpha }) catch return null;
    }
    return std.fmt.bufPrint(buf, "rgba({d}, {d}, {d}, {d:.3})", .{ r, g, b, alpha }) catch return null;
}

// ── Tests ─────────────────────────────────────────────────────────────

test "opaque rgb form" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("rgb(255, 0, 0)", argbToBuf(pack(255, 255, 0, 0), &buf).?);
    try std.testing.expectEqualStrings("rgb(0, 128, 0)", argbToBuf(pack(255, 0, 128, 0), &buf).?);
    try std.testing.expectEqualStrings("rgb(0, 0, 0)", argbToBuf(pack(255, 0, 0, 0), &buf).?);
    try std.testing.expectEqualStrings("rgb(255, 255, 255)", argbToBuf(pack(255, 255, 255, 255), &buf).?);
}

test "transparent alpha 0 bare integer" {
    var buf: [64]u8 = undefined;
    // transparent keyword → rgba(0, 0, 0, 0)
    try std.testing.expectEqualStrings("rgba(0, 0, 0, 0)", argbToBuf(pack(0, 0, 0, 0), &buf).?);
    // alpha=0 with non-zero channels preserves channels
    try std.testing.expectEqualStrings("rgba(255, 0, 0, 0)", argbToBuf(pack(0, 255, 0, 0), &buf).?);
    try std.testing.expectEqualStrings("rgba(1, 2, 3, 0)", argbToBuf(pack(0, 1, 2, 3), &buf).?);
}

test "alpha decimal precision" {
    var buf: [64]u8 = undefined;
    // 128/255 ≈ 0.502 → 3 decimals
    try std.testing.expectEqualStrings("rgba(0, 0, 0, 0.502)", argbToBuf(pack(128, 0, 0, 0), &buf).?);
    // 170/255 ≈ 0.667
    try std.testing.expectEqualStrings("rgba(255, 0, 0, 0.667)", argbToBuf(pack(170, 255, 0, 0), &buf).?);
    // 255/2 = 127.5 → a=127 gives 0.498, a=128 gives 0.502
    try std.testing.expectEqualStrings("rgba(1, 2, 3, 0.498)", argbToBuf(pack(127, 1, 2, 3), &buf).?);
}
