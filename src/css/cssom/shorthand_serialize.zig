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
pub fn serializeFlex(ctx: LookupCtx, buf: []u8) ?[]const u8 {
    const grow = std.mem.trim(u8, lhGet(ctx, "flex-grow") orelse return null, " \t");
    const shrink = std.mem.trim(u8, lhGet(ctx, "flex-shrink") orelse return null, " \t");
    const basis = std.mem.trim(u8, lhGet(ctx, "flex-basis") orelse return null, " \t");
    if (grow.len == 0 or shrink.len == 0 or basis.len == 0) return null;
    if (std.mem.eql(u8, grow, "0") and std.mem.eql(u8, shrink, "0") and std.ascii.eqlIgnoreCase(basis, "auto")) {
        return std.fmt.bufPrint(buf, "none", .{}) catch null;
    }
    if (std.mem.eql(u8, grow, "1") and std.mem.eql(u8, shrink, "1") and std.ascii.eqlIgnoreCase(basis, "auto")) {
        return std.fmt.bufPrint(buf, "auto", .{}) catch null;
    }
    return std.fmt.bufPrint(buf, "{s} {s} {s}", .{ grow, shrink, basis }) catch null;
}

/// Serialize "flex-flow" from flex-direction and flex-wrap.
pub fn serializeFlexFlow(ctx: LookupCtx, buf: []u8) ?[]const u8 {
    const dir = std.mem.trim(u8, lhGet(ctx, "flex-direction") orelse return null, " \t");
    const wrap = std.mem.trim(u8, lhGet(ctx, "flex-wrap") orelse return null, " \t");
    if (dir.len == 0 or wrap.len == 0) return null;
    const dir_default = std.ascii.eqlIgnoreCase(dir, "row");
    const wrap_default = std.ascii.eqlIgnoreCase(wrap, "nowrap");
    if (dir_default and wrap_default) {
        return std.fmt.bufPrint(buf, "row nowrap", .{}) catch null;
    } else if (wrap_default) {
        return std.fmt.bufPrint(buf, "{s}", .{dir}) catch null;
    } else if (dir_default) {
        return std.fmt.bufPrint(buf, "{s}", .{wrap}) catch null;
    } else {
        return std.fmt.bufPrint(buf, "{s} {s}", .{ dir, wrap }) catch null;
    }
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

test "serializeFlex — none" {
    const arr = [_]Entry{
        .{ .name = "flex-grow", .value = "0" },
        .{ .name = "flex-shrink", .value = "0" },
        .{ .name = "flex-basis", .value = "auto" },
    };
    const slice: []const Entry = &arr;
    var buf: [64]u8 = undefined;
    const r = serializeFlex(makeCtx(&slice), &buf);
    try std.testing.expectEqualStrings("none", r.?);
}

test "serializeFlex — auto" {
    const arr = [_]Entry{
        .{ .name = "flex-grow", .value = "1" },
        .{ .name = "flex-shrink", .value = "1" },
        .{ .name = "flex-basis", .value = "auto" },
    };
    const slice: []const Entry = &arr;
    var buf: [64]u8 = undefined;
    const r = serializeFlex(makeCtx(&slice), &buf);
    try std.testing.expectEqualStrings("auto", r.?);
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
