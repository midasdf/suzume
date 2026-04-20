//! shorthand_serialize.zig — Phase 3 canonical shorthand serializers
//!
//! Each serializer takes a lookup function for individual longhands and returns
//! a canonical shorthand string, or null if any component is missing / flags
//! are inconsistent.
//!
//! Canonical TRBL compression rules (used by margin, padding, border-width,
//! border-style, border-color):
//!   1 value:  T==R==B==L  → "T"
//!   2 values: T==B, R==L  → "T R"
//!   3 values: R==L        → "T R B"
//!   4 values:             → "T R B L"

const std = @import("std");

/// A small struct carrying the four TRBL values.
const Trbl = struct { top: []const u8, right: []const u8, bottom: []const u8, left: []const u8 };

/// Build the compressed TRBL string into `buf`.  Returns the slice or null if
/// any component is the empty string.
pub fn serializeTrbl(trbl: Trbl, buf: []u8) ?[]const u8 {
    const t = std.mem.trim(u8, trbl.top, " \t\r\n");
    const r = std.mem.trim(u8, trbl.right, " \t\r\n");
    const b = std.mem.trim(u8, trbl.bottom, " \t\r\n");
    const l = std.mem.trim(u8, trbl.left, " \t\r\n");
    if (t.len == 0 or r.len == 0 or b.len == 0 or l.len == 0) return null;

    if (std.mem.eql(u8, t, r) and std.mem.eql(u8, r, b) and std.mem.eql(u8, b, l)) {
        return std.fmt.bufPrint(buf, "{s}", .{t}) catch null;
    } else if (std.mem.eql(u8, t, b) and std.mem.eql(u8, r, l)) {
        return std.fmt.bufPrint(buf, "{s} {s}", .{ t, r }) catch null;
    } else if (std.mem.eql(u8, r, l)) {
        return std.fmt.bufPrint(buf, "{s} {s} {s}", .{ t, r, b }) catch null;
    } else {
        return std.fmt.bufPrint(buf, "{s} {s} {s} {s}", .{ t, r, b, l }) catch null;
    }
}

/// Shorthand descriptor: maps a shorthand name to its canonical serialization
/// function. Returns an allocated string or null.
///
/// `getLonghand` is a callback: fn(name: []const u8) ?[]const u8
/// Returns null when any required longhand is absent or important flags differ.

/// Context passed to serializer callbacks.  `ptr` is an opaque pointer to the
/// lookup context; `get` retrieves a longhand value by name (returns null if absent).
pub const LookupCtx = struct {
    ptr: *const anyopaque,
    get: *const fn (ctx: *const anyopaque, name: []const u8) ?[]const u8,
};

fn lhGet(ctx: LookupCtx, name: []const u8) ?[]const u8 {
    return ctx.get(ctx.ptr, name);
}

/// Serialize "margin" / "padding" / "border-width" / "border-style" / "border-color"
/// from their four longhands.  Returns a slice into `buf`, or null.
pub fn serializeBoxShorthand(
    comptime top: []const u8,
    comptime right: []const u8,
    comptime bottom: []const u8,
    comptime left: []const u8,
    ctx: LookupCtx,
    buf: []u8,
) ?[]const u8 {
    const t = lhGet(ctx, top) orelse return null;
    const r = lhGet(ctx, right) orelse return null;
    const b = lhGet(ctx, bottom) orelse return null;
    const l = lhGet(ctx, left) orelse return null;
    return serializeTrbl(.{ .top = t, .right = r, .bottom = b, .left = l }, buf);
}

/// Serialize "flex" from flex-grow, flex-shrink, flex-basis.
/// Per CSSOM §6.7.2 + CSS Flexbox L1 §7.1.1: canonical three-part form.
pub fn serializeFlex(ctx: LookupCtx, buf: []u8) ?[]const u8 {
    const grow = std.mem.trim(u8, lhGet(ctx, "flex-grow") orelse return null, " \t");
    const shrink = std.mem.trim(u8, lhGet(ctx, "flex-shrink") orelse return null, " \t");
    const basis = std.mem.trim(u8, lhGet(ctx, "flex-basis") orelse return null, " \t");
    if (grow.len == 0 or shrink.len == 0 or basis.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s} {s} {s}", .{ grow, shrink, basis }) catch null;
}

/// Serialize "flex-flow" from flex-direction and flex-wrap.
/// Per CSS Flexbox L1 §7.2: omit components that match their initial value,
/// except when both are initial — then serialize just the direction.
pub fn serializeFlexFlow(ctx: LookupCtx, buf: []u8) ?[]const u8 {
    const dir = std.mem.trim(u8, lhGet(ctx, "flex-direction") orelse return null, " \t");
    const wrap = std.mem.trim(u8, lhGet(ctx, "flex-wrap") orelse return null, " \t");
    if (dir.len == 0 or wrap.len == 0) return null;
    const wrap_default = std.ascii.eqlIgnoreCase(wrap, "nowrap");
    if (wrap_default) {
        return std.fmt.bufPrint(buf, "{s}", .{dir}) catch null;
    }
    return std.fmt.bufPrint(buf, "{s} {s}", .{ dir, wrap }) catch null;
}

/// Serialize a two-value logical shorthand from its start/end longhands
/// (e.g. margin-block, margin-inline, padding-block, padding-inline,
/// inset-block, inset-inline).  Canonical compression: "A A" → "A".
pub fn serializeStartEndShorthand(
    comptime start: []const u8,
    comptime end: []const u8,
    ctx: LookupCtx,
    buf: []u8,
) ?[]const u8 {
    const s = std.mem.trim(u8, lhGet(ctx, start) orelse return null, " \t\r\n");
    const e = std.mem.trim(u8, lhGet(ctx, end) orelse return null, " \t\r\n");
    if (s.len == 0 or e.len == 0) return null;
    if (std.mem.eql(u8, s, e)) return std.fmt.bufPrint(buf, "{s}", .{s}) catch null;
    return std.fmt.bufPrint(buf, "{s} {s}", .{ s, e }) catch null;
}

/// Serialize a width/style/color triple (border-top, border-right,
/// border-bottom, border-left, outline).  Per CSS Backgrounds 3 §4.9 and
/// CSS UI 4 §3.1, the canonical form is `<width> <style> <color>` with a
/// single space separator; all three components are always emitted.
pub fn serializeWidthStyleColor(
    comptime width_prop: []const u8,
    comptime style_prop: []const u8,
    comptime color_prop: []const u8,
    ctx: LookupCtx,
    buf: []u8,
) ?[]const u8 {
    const w = std.mem.trim(u8, lhGet(ctx, width_prop) orelse return null, " \t\r\n");
    const s = std.mem.trim(u8, lhGet(ctx, style_prop) orelse return null, " \t\r\n");
    const c = std.mem.trim(u8, lhGet(ctx, color_prop) orelse return null, " \t\r\n");
    if (w.len == 0 or s.len == 0 or c.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s} {s} {s}", .{ w, s, c }) catch null;
}

/// Serialize the `border` shorthand (CSS Backgrounds 3 §4.9).
/// Only emits a value when all four sides (top/right/bottom/left) share
/// the same width, style and color — otherwise returns null so the
/// caller falls back to individual side serialization.
pub fn serializeBorder(ctx: LookupCtx, buf: []u8) ?[]const u8 {
    const tw = std.mem.trim(u8, lhGet(ctx, "border-top-width") orelse return null, " \t\r\n");
    const rw = std.mem.trim(u8, lhGet(ctx, "border-right-width") orelse return null, " \t\r\n");
    const bw = std.mem.trim(u8, lhGet(ctx, "border-bottom-width") orelse return null, " \t\r\n");
    const lw = std.mem.trim(u8, lhGet(ctx, "border-left-width") orelse return null, " \t\r\n");
    const ts = std.mem.trim(u8, lhGet(ctx, "border-top-style") orelse return null, " \t\r\n");
    const rs = std.mem.trim(u8, lhGet(ctx, "border-right-style") orelse return null, " \t\r\n");
    const bs = std.mem.trim(u8, lhGet(ctx, "border-bottom-style") orelse return null, " \t\r\n");
    const ls = std.mem.trim(u8, lhGet(ctx, "border-left-style") orelse return null, " \t\r\n");
    const tc = std.mem.trim(u8, lhGet(ctx, "border-top-color") orelse return null, " \t\r\n");
    const rc = std.mem.trim(u8, lhGet(ctx, "border-right-color") orelse return null, " \t\r\n");
    const bc = std.mem.trim(u8, lhGet(ctx, "border-bottom-color") orelse return null, " \t\r\n");
    const lc = std.mem.trim(u8, lhGet(ctx, "border-left-color") orelse return null, " \t\r\n");
    if (tw.len == 0 or ts.len == 0 or tc.len == 0) return null;
    // All four sides must match for the shorthand to round-trip.
    if (!std.mem.eql(u8, tw, rw) or !std.mem.eql(u8, tw, bw) or !std.mem.eql(u8, tw, lw)) return null;
    if (!std.mem.eql(u8, ts, rs) or !std.mem.eql(u8, ts, bs) or !std.mem.eql(u8, ts, ls)) return null;
    if (!std.mem.eql(u8, tc, rc) or !std.mem.eql(u8, tc, bc) or !std.mem.eql(u8, tc, lc)) return null;
    return std.fmt.bufPrint(buf, "{s} {s} {s}", .{ tw, ts, tc }) catch null;
}

/// Serialize the `gap` shorthand from row-gap + column-gap.
/// Per CSS Box Alignment 3 §8.3: `<row-gap> <column-gap>`, collapsing to
/// a single value when both components are equal.
pub fn serializeGap(ctx: LookupCtx, buf: []u8) ?[]const u8 {
    const row = std.mem.trim(u8, lhGet(ctx, "row-gap") orelse return null, " \t\r\n");
    const col = std.mem.trim(u8, lhGet(ctx, "column-gap") orelse return null, " \t\r\n");
    if (row.len == 0 or col.len == 0) return null;
    if (std.mem.eql(u8, row, col)) return std.fmt.bufPrint(buf, "{s}", .{row}) catch null;
    return std.fmt.bufPrint(buf, "{s} {s}", .{ row, col }) catch null;
}

/// Serialize the `font` shorthand (CSS Fonts 4 §10.6) — basic subset.
/// Canonical form: `[<style>] [<weight>] <size>[/<line-height>] <family>`.
/// We omit style/weight when they are at their initial value ("normal"),
/// and include the `/<line-height>` segment only when line-height is not
/// "normal".  font-variant is not modelled separately by the parser so it
/// is never emitted.  If font-size or font-family are missing the
/// shorthand is not serializable (returns null).
pub fn serializeFont(ctx: LookupCtx, buf: []u8) ?[]const u8 {
    const size = std.mem.trim(u8, lhGet(ctx, "font-size") orelse return null, " \t\r\n");
    const family = std.mem.trim(u8, lhGet(ctx, "font-family") orelse return null, " \t\r\n");
    if (size.len == 0 or family.len == 0) return null;

    // Optional components — absent or "normal" means omit.
    const style_raw = lhGet(ctx, "font-style") orelse "normal";
    const weight_raw = lhGet(ctx, "font-weight") orelse "normal";
    const lh_raw = lhGet(ctx, "line-height") orelse "normal";
    const style = std.mem.trim(u8, style_raw, " \t\r\n");
    const weight = std.mem.trim(u8, weight_raw, " \t\r\n");
    const lh = std.mem.trim(u8, lh_raw, " \t\r\n");

    const has_style = style.len > 0 and !std.ascii.eqlIgnoreCase(style, "normal");
    const has_weight = weight.len > 0 and !std.ascii.eqlIgnoreCase(weight, "normal");
    const has_lh = lh.len > 0 and !std.ascii.eqlIgnoreCase(lh, "normal");

    if (has_style and has_weight and has_lh) {
        return std.fmt.bufPrint(buf, "{s} {s} {s}/{s} {s}", .{ style, weight, size, lh, family }) catch null;
    }
    if (has_style and has_weight) {
        return std.fmt.bufPrint(buf, "{s} {s} {s} {s}", .{ style, weight, size, family }) catch null;
    }
    if (has_style and has_lh) {
        return std.fmt.bufPrint(buf, "{s} {s}/{s} {s}", .{ style, size, lh, family }) catch null;
    }
    if (has_weight and has_lh) {
        return std.fmt.bufPrint(buf, "{s} {s}/{s} {s}", .{ weight, size, lh, family }) catch null;
    }
    if (has_style) {
        return std.fmt.bufPrint(buf, "{s} {s} {s}", .{ style, size, family }) catch null;
    }
    if (has_weight) {
        return std.fmt.bufPrint(buf, "{s} {s} {s}", .{ weight, size, family }) catch null;
    }
    if (has_lh) {
        return std.fmt.bufPrint(buf, "{s}/{s} {s}", .{ size, lh, family }) catch null;
    }
    return std.fmt.bufPrint(buf, "{s} {s}", .{ size, family }) catch null;
}

/// Dispatch: given a shorthand name and a LookupCtx, return the canonical string.
pub fn serializeShorthand(shorthand: []const u8, ctx: LookupCtx, buf: []u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(shorthand, "margin")) {
        return serializeBoxShorthand("margin-top", "margin-right", "margin-bottom", "margin-left", ctx, buf);
    }
    if (std.ascii.eqlIgnoreCase(shorthand, "padding")) {
        return serializeBoxShorthand("padding-top", "padding-right", "padding-bottom", "padding-left", ctx, buf);
    }
    if (std.ascii.eqlIgnoreCase(shorthand, "border-width")) {
        return serializeBoxShorthand("border-top-width", "border-right-width", "border-bottom-width", "border-left-width", ctx, buf);
    }
    if (std.ascii.eqlIgnoreCase(shorthand, "border-style")) {
        return serializeBoxShorthand("border-top-style", "border-right-style", "border-bottom-style", "border-left-style", ctx, buf);
    }
    if (std.ascii.eqlIgnoreCase(shorthand, "border-color")) {
        return serializeBoxShorthand("border-top-color", "border-right-color", "border-bottom-color", "border-left-color", ctx, buf);
    }
    if (std.ascii.eqlIgnoreCase(shorthand, "flex")) {
        return serializeFlex(ctx, buf);
    }
    if (std.ascii.eqlIgnoreCase(shorthand, "flex-flow")) {
        return serializeFlexFlow(ctx, buf);
    }
    // Physical TRBL positioning shorthand (CSS Position 3 §2.1)
    if (std.ascii.eqlIgnoreCase(shorthand, "inset")) {
        return serializeBoxShorthand("top", "right", "bottom", "left", ctx, buf);
    }
    // Logical start/end shorthands (CSS Logical 1 §4).  The suzume parser
    // currently expands logical properties to physical ones (LTR assumed in
    // src/css/properties.zig), so we reverse that mapping here:
    //   block-start/end → top/bottom
    //   inline-start/end → left/right
    if (std.ascii.eqlIgnoreCase(shorthand, "margin-block")) {
        return serializeStartEndShorthand("margin-top", "margin-bottom", ctx, buf);
    }
    if (std.ascii.eqlIgnoreCase(shorthand, "margin-inline")) {
        return serializeStartEndShorthand("margin-left", "margin-right", ctx, buf);
    }
    if (std.ascii.eqlIgnoreCase(shorthand, "padding-block")) {
        return serializeStartEndShorthand("padding-top", "padding-bottom", ctx, buf);
    }
    if (std.ascii.eqlIgnoreCase(shorthand, "padding-inline")) {
        return serializeStartEndShorthand("padding-left", "padding-right", ctx, buf);
    }
    if (std.ascii.eqlIgnoreCase(shorthand, "inset-block")) {
        return serializeStartEndShorthand("top", "bottom", ctx, buf);
    }
    if (std.ascii.eqlIgnoreCase(shorthand, "inset-inline")) {
        return serializeStartEndShorthand("left", "right", ctx, buf);
    }
    // Border side shorthands (CSS Backgrounds 3 §4.9): width + style + color
    if (std.ascii.eqlIgnoreCase(shorthand, "border-top")) {
        return serializeWidthStyleColor("border-top-width", "border-top-style", "border-top-color", ctx, buf);
    }
    if (std.ascii.eqlIgnoreCase(shorthand, "border-right")) {
        return serializeWidthStyleColor("border-right-width", "border-right-style", "border-right-color", ctx, buf);
    }
    if (std.ascii.eqlIgnoreCase(shorthand, "border-bottom")) {
        return serializeWidthStyleColor("border-bottom-width", "border-bottom-style", "border-bottom-color", ctx, buf);
    }
    if (std.ascii.eqlIgnoreCase(shorthand, "border-left")) {
        return serializeWidthStyleColor("border-left-width", "border-left-style", "border-left-color", ctx, buf);
    }
    // Four-sided border shorthand (CSS Backgrounds 3 §4.9)
    if (std.ascii.eqlIgnoreCase(shorthand, "border")) {
        return serializeBorder(ctx, buf);
    }
    // outline shorthand (CSS UI 4 §3.1): width + style + color
    if (std.ascii.eqlIgnoreCase(shorthand, "outline")) {
        return serializeWidthStyleColor("outline-width", "outline-style", "outline-color", ctx, buf);
    }
    // Gap shorthand (CSS Box Alignment 3 §8.3): row-gap + column-gap
    if (std.ascii.eqlIgnoreCase(shorthand, "gap") or
        std.ascii.eqlIgnoreCase(shorthand, "grid-gap"))
    {
        return serializeGap(ctx, buf);
    }
    // Font shorthand (CSS Fonts 4 §10.6) — basic subset
    if (std.ascii.eqlIgnoreCase(shorthand, "font")) {
        return serializeFont(ctx, buf);
    }
    return null;
}

/// Convenience: serialize a shorthand directly from a StyleDeclList entries slice.
/// The entries slice must remain valid for the duration of this call.
pub fn serializeShorthandFromEntries(
    shorthand: []const u8,
    entries: []const struct { name: []const u8, value: []const u8 },
    buf: []u8,
) ?[]const u8 {
    const Impl = struct {
        fn get(ptr: *const anyopaque, name: []const u8) ?[]const u8 {
            const slice: *const []const struct { name: []const u8, value: []const u8 } = @ptrCast(@alignCast(ptr));
            for (slice.*) |e| {
                if (std.ascii.eqlIgnoreCase(e.name, name)) return e.value;
            }
            return null;
        }
    };
    const ctx = LookupCtx{ .ptr = @ptrCast(&entries), .get = Impl.get };
    return serializeShorthand(shorthand, ctx, buf);
}

// ── Tests ─────────────────────────────────────────────────────────────

const Entry = struct { name: []const u8, value: []const u8 };

/// Test helper: wraps a slice fat-pointer in a LookupCtx.
/// `slice_ptr` must point to a slice ([]const Entry) whose lifetime covers the call.
fn makeCtx(slice_ptr: *const []const Entry) LookupCtx {
    const Impl = struct {
        fn get(ptr: *const anyopaque, name: []const u8) ?[]const u8 {
            const sp: *const []const Entry = @ptrCast(@alignCast(ptr));
            for (sp.*) |e| {
                if (std.ascii.eqlIgnoreCase(e.name, name)) return e.value;
            }
            return null;
        }
    };
    return .{ .ptr = @ptrCast(slice_ptr), .get = Impl.get };
}

test "serializeTrbl — all equal" {
    var buf: [64]u8 = undefined;
    const r = serializeTrbl(.{ .top = "1px", .right = "1px", .bottom = "1px", .left = "1px" }, &buf);
    try std.testing.expectEqualStrings("1px", r.?);
}

test "serializeTrbl — 2-value" {
    var buf: [64]u8 = undefined;
    const r = serializeTrbl(.{ .top = "1px", .right = "2px", .bottom = "1px", .left = "2px" }, &buf);
    try std.testing.expectEqualStrings("1px 2px", r.?);
}

test "serializeTrbl — 3-value" {
    var buf: [64]u8 = undefined;
    const r = serializeTrbl(.{ .top = "1px", .right = "2px", .bottom = "3px", .left = "2px" }, &buf);
    try std.testing.expectEqualStrings("1px 2px 3px", r.?);
}

test "serializeTrbl — 4-value" {
    var buf: [64]u8 = undefined;
    const r = serializeTrbl(.{ .top = "1px", .right = "2px", .bottom = "3px", .left = "4px" }, &buf);
    try std.testing.expectEqualStrings("1px 2px 3px 4px", r.?);
}

test "serializeTrbl — missing returns null" {
    var buf: [64]u8 = undefined;
    const r = serializeTrbl(.{ .top = "", .right = "2px", .bottom = "3px", .left = "4px" }, &buf);
    try std.testing.expect(r == null);
}

test "serializeFlex — none (0 0 auto canonical)" {
    const arr = [_]Entry{
        .{ .name = "flex-grow", .value = "0" },
        .{ .name = "flex-shrink", .value = "0" },
        .{ .name = "flex-basis", .value = "auto" },
    };
    const slice: []const Entry = &arr;
    var buf: [64]u8 = undefined;
    const r = serializeFlex(makeCtx(&slice), &buf);
    try std.testing.expectEqualStrings("0 0 auto", r.?);
}

test "serializeFlex — auto (1 1 auto canonical)" {
    const arr = [_]Entry{
        .{ .name = "flex-grow", .value = "1" },
        .{ .name = "flex-shrink", .value = "1" },
        .{ .name = "flex-basis", .value = "auto" },
    };
    const slice: []const Entry = &arr;
    var buf: [64]u8 = undefined;
    const r = serializeFlex(makeCtx(&slice), &buf);
    try std.testing.expectEqualStrings("1 1 auto", r.?);
}

test "serializeFlex — numeric" {
    const arr = [_]Entry{
        .{ .name = "flex-grow", .value = "2" },
        .{ .name = "flex-shrink", .value = "1" },
        .{ .name = "flex-basis", .value = "0px" },
    };
    const slice: []const Entry = &arr;
    var buf: [64]u8 = undefined;
    const r = serializeFlex(makeCtx(&slice), &buf);
    try std.testing.expectEqualStrings("2 1 0px", r.?);
}

test "serializeShorthand margin dispatch" {
    const arr = [_]Entry{
        .{ .name = "margin-top", .value = "5px" },
        .{ .name = "margin-right", .value = "5px" },
        .{ .name = "margin-bottom", .value = "5px" },
        .{ .name = "margin-left", .value = "5px" },
    };
    const slice: []const Entry = &arr;
    var buf: [64]u8 = undefined;
    const r = serializeShorthand("margin", makeCtx(&slice), &buf);
    try std.testing.expectEqualStrings("5px", r.?);
}

test "serializeShorthand flex-flow direction only" {
    const arr = [_]Entry{
        .{ .name = "flex-direction", .value = "column" },
        .{ .name = "flex-wrap", .value = "nowrap" },
    };
    const slice: []const Entry = &arr;
    var buf: [64]u8 = undefined;
    const r = serializeShorthand("flex-flow", makeCtx(&slice), &buf);
    try std.testing.expectEqualStrings("column", r.?);
}

test "serializeFlexFlow — row nowrap collapses to row" {
    const arr = [_]Entry{
        .{ .name = "flex-direction", .value = "row" },
        .{ .name = "flex-wrap", .value = "nowrap" },
    };
    const slice: []const Entry = &arr;
    var buf: [64]u8 = undefined;
    const r = serializeFlexFlow(makeCtx(&slice), &buf);
    try std.testing.expectEqualStrings("row", r.?);
}

test "serializeFlexFlow — column-reverse wrap" {
    const arr = [_]Entry{
        .{ .name = "flex-direction", .value = "column-reverse" },
        .{ .name = "flex-wrap", .value = "wrap" },
    };
    const slice: []const Entry = &arr;
    var buf: [64]u8 = undefined;
    const r = serializeFlexFlow(makeCtx(&slice), &buf);
    try std.testing.expectEqualStrings("column-reverse wrap", r.?);
}

test "serializeFlexFlow — row wrap (wrap non-initial)" {
    const arr = [_]Entry{
        .{ .name = "flex-direction", .value = "row" },
        .{ .name = "flex-wrap", .value = "wrap" },
    };
    const slice: []const Entry = &arr;
    var buf: [64]u8 = undefined;
    const r = serializeFlexFlow(makeCtx(&slice), &buf);
    try std.testing.expectEqualStrings("row wrap", r.?);
}

test "serializeShorthand inset — all equal compresses to 1 value" {
    const arr = [_]Entry{
        .{ .name = "top", .value = "5px" },
        .{ .name = "right", .value = "5px" },
        .{ .name = "bottom", .value = "5px" },
        .{ .name = "left", .value = "5px" },
    };
    const slice: []const Entry = &arr;
    var buf: [64]u8 = undefined;
    const r = serializeShorthand("inset", makeCtx(&slice), &buf);
    try std.testing.expectEqualStrings("5px", r.?);
}

test "serializeShorthand inset — 4-value" {
    const arr = [_]Entry{
        .{ .name = "top", .value = "1px" },
        .{ .name = "right", .value = "2px" },
        .{ .name = "bottom", .value = "3px" },
        .{ .name = "left", .value = "4px" },
    };
    const slice: []const Entry = &arr;
    var buf: [64]u8 = undefined;
    const r = serializeShorthand("inset", makeCtx(&slice), &buf);
    try std.testing.expectEqualStrings("1px 2px 3px 4px", r.?);
}

test "serializeShorthand margin-block — equal compresses (reads margin-top/bottom)" {
    const arr = [_]Entry{
        .{ .name = "margin-top", .value = "10px" },
        .{ .name = "margin-bottom", .value = "10px" },
    };
    const slice: []const Entry = &arr;
    var buf: [64]u8 = undefined;
    const r = serializeShorthand("margin-block", makeCtx(&slice), &buf);
    try std.testing.expectEqualStrings("10px", r.?);
}

test "serializeShorthand margin-inline — unequal stays as pair (reads margin-left/right)" {
    const arr = [_]Entry{
        .{ .name = "margin-left", .value = "5px" },
        .{ .name = "margin-right", .value = "10px" },
    };
    const slice: []const Entry = &arr;
    var buf: [64]u8 = undefined;
    const r = serializeShorthand("margin-inline", makeCtx(&slice), &buf);
    try std.testing.expectEqualStrings("5px 10px", r.?);
}

test "serializeShorthand padding-block — equal compresses (reads padding-top/bottom)" {
    const arr = [_]Entry{
        .{ .name = "padding-top", .value = "3px" },
        .{ .name = "padding-bottom", .value = "3px" },
    };
    const slice: []const Entry = &arr;
    var buf: [64]u8 = undefined;
    const r = serializeShorthand("padding-block", makeCtx(&slice), &buf);
    try std.testing.expectEqualStrings("3px", r.?);
}

test "serializeShorthand inset-inline — missing longhand returns null" {
    const arr = [_]Entry{
        .{ .name = "left", .value = "5px" },
        // missing right
    };
    const slice: []const Entry = &arr;
    var buf: [64]u8 = undefined;
    const r = serializeShorthand("inset-inline", makeCtx(&slice), &buf);
    try std.testing.expect(r == null);
}

test "serializeShorthand inset-block — equal (reads top/bottom)" {
    const arr = [_]Entry{
        .{ .name = "top", .value = "4px" },
        .{ .name = "bottom", .value = "4px" },
    };
    const slice: []const Entry = &arr;
    var buf: [64]u8 = undefined;
    const r = serializeShorthand("inset-block", makeCtx(&slice), &buf);
    try std.testing.expectEqualStrings("4px", r.?);
}

// ── Wave 9 shorthands ────────────────────────────────────────────────

test "serializeShorthand border-top — width/style/color triple" {
    const arr = [_]Entry{
        .{ .name = "border-top-width", .value = "1px" },
        .{ .name = "border-top-style", .value = "solid" },
        .{ .name = "border-top-color", .value = "red" },
    };
    const slice: []const Entry = &arr;
    var buf: [64]u8 = undefined;
    const r = serializeShorthand("border-top", makeCtx(&slice), &buf);
    try std.testing.expectEqualStrings("1px solid red", r.?);
}

test "serializeShorthand border-left — width/style/color triple" {
    const arr = [_]Entry{
        .{ .name = "border-left-width", .value = "2px" },
        .{ .name = "border-left-style", .value = "dashed" },
        .{ .name = "border-left-color", .value = "blue" },
    };
    const slice: []const Entry = &arr;
    var buf: [64]u8 = undefined;
    const r = serializeShorthand("border-left", makeCtx(&slice), &buf);
    try std.testing.expectEqualStrings("2px dashed blue", r.?);
}

test "serializeShorthand border-right — missing longhand returns null" {
    const arr = [_]Entry{
        .{ .name = "border-right-width", .value = "1px" },
        .{ .name = "border-right-style", .value = "solid" },
        // missing color
    };
    const slice: []const Entry = &arr;
    var buf: [64]u8 = undefined;
    const r = serializeShorthand("border-right", makeCtx(&slice), &buf);
    try std.testing.expect(r == null);
}

test "serializeShorthand border — all four sides equal" {
    const arr = [_]Entry{
        .{ .name = "border-top-width", .value = "1px" },
        .{ .name = "border-right-width", .value = "1px" },
        .{ .name = "border-bottom-width", .value = "1px" },
        .{ .name = "border-left-width", .value = "1px" },
        .{ .name = "border-top-style", .value = "solid" },
        .{ .name = "border-right-style", .value = "solid" },
        .{ .name = "border-bottom-style", .value = "solid" },
        .{ .name = "border-left-style", .value = "solid" },
        .{ .name = "border-top-color", .value = "red" },
        .{ .name = "border-right-color", .value = "red" },
        .{ .name = "border-bottom-color", .value = "red" },
        .{ .name = "border-left-color", .value = "red" },
    };
    const slice: []const Entry = &arr;
    var buf: [64]u8 = undefined;
    const r = serializeShorthand("border", makeCtx(&slice), &buf);
    try std.testing.expectEqualStrings("1px solid red", r.?);
}

test "serializeShorthand border — sides differ returns null" {
    const arr = [_]Entry{
        .{ .name = "border-top-width", .value = "1px" },
        .{ .name = "border-right-width", .value = "2px" }, // differs
        .{ .name = "border-bottom-width", .value = "1px" },
        .{ .name = "border-left-width", .value = "1px" },
        .{ .name = "border-top-style", .value = "solid" },
        .{ .name = "border-right-style", .value = "solid" },
        .{ .name = "border-bottom-style", .value = "solid" },
        .{ .name = "border-left-style", .value = "solid" },
        .{ .name = "border-top-color", .value = "red" },
        .{ .name = "border-right-color", .value = "red" },
        .{ .name = "border-bottom-color", .value = "red" },
        .{ .name = "border-left-color", .value = "red" },
    };
    const slice: []const Entry = &arr;
    var buf: [64]u8 = undefined;
    const r = serializeShorthand("border", makeCtx(&slice), &buf);
    try std.testing.expect(r == null);
}

test "serializeShorthand outline — width/style/color triple" {
    const arr = [_]Entry{
        .{ .name = "outline-width", .value = "2px" },
        .{ .name = "outline-style", .value = "dotted" },
        .{ .name = "outline-color", .value = "green" },
    };
    const slice: []const Entry = &arr;
    var buf: [64]u8 = undefined;
    const r = serializeShorthand("outline", makeCtx(&slice), &buf);
    try std.testing.expectEqualStrings("2px dotted green", r.?);
}

test "serializeShorthand outline — missing width returns null" {
    const arr = [_]Entry{
        // missing outline-width
        .{ .name = "outline-style", .value = "solid" },
        .{ .name = "outline-color", .value = "black" },
    };
    const slice: []const Entry = &arr;
    var buf: [64]u8 = undefined;
    const r = serializeShorthand("outline", makeCtx(&slice), &buf);
    try std.testing.expect(r == null);
}

test "serializeShorthand gap — equal components collapse" {
    const arr = [_]Entry{
        .{ .name = "row-gap", .value = "10px" },
        .{ .name = "column-gap", .value = "10px" },
    };
    const slice: []const Entry = &arr;
    var buf: [64]u8 = undefined;
    const r = serializeShorthand("gap", makeCtx(&slice), &buf);
    try std.testing.expectEqualStrings("10px", r.?);
}

test "serializeShorthand gap — unequal components stay as pair (row before column)" {
    const arr = [_]Entry{
        .{ .name = "row-gap", .value = "10px" },
        .{ .name = "column-gap", .value = "20px" },
    };
    const slice: []const Entry = &arr;
    var buf: [64]u8 = undefined;
    const r = serializeShorthand("gap", makeCtx(&slice), &buf);
    try std.testing.expectEqualStrings("10px 20px", r.?);
}

test "serializeShorthand grid-gap alias routes to gap" {
    const arr = [_]Entry{
        .{ .name = "row-gap", .value = "5px" },
        .{ .name = "column-gap", .value = "5px" },
    };
    const slice: []const Entry = &arr;
    var buf: [64]u8 = undefined;
    const r = serializeShorthand("grid-gap", makeCtx(&slice), &buf);
    try std.testing.expectEqualStrings("5px", r.?);
}

test "serializeShorthand font — size + family only (normals omitted)" {
    const arr = [_]Entry{
        .{ .name = "font-style", .value = "normal" },
        .{ .name = "font-weight", .value = "normal" },
        .{ .name = "font-size", .value = "14px" },
        .{ .name = "line-height", .value = "normal" },
        .{ .name = "font-family", .value = "sans-serif" },
    };
    const slice: []const Entry = &arr;
    var buf: [128]u8 = undefined;
    const r = serializeShorthand("font", makeCtx(&slice), &buf);
    try std.testing.expectEqualStrings("14px sans-serif", r.?);
}

test "serializeShorthand font — italic bold with size/line-height" {
    const arr = [_]Entry{
        .{ .name = "font-style", .value = "italic" },
        .{ .name = "font-weight", .value = "bold" },
        .{ .name = "font-size", .value = "16px" },
        .{ .name = "line-height", .value = "1.5" },
        .{ .name = "font-family", .value = "serif" },
    };
    const slice: []const Entry = &arr;
    var buf: [128]u8 = undefined;
    const r = serializeShorthand("font", makeCtx(&slice), &buf);
    try std.testing.expectEqualStrings("italic bold 16px/1.5 serif", r.?);
}

test "serializeShorthand font — missing family returns null" {
    const arr = [_]Entry{
        .{ .name = "font-size", .value = "12px" },
        // missing font-family
    };
    const slice: []const Entry = &arr;
    var buf: [128]u8 = undefined;
    const r = serializeShorthand("font", makeCtx(&slice), &buf);
    try std.testing.expect(r == null);
}
