//! computed_slice.zig — JS-engine-agnostic computed style serializer.
//!
//! Serializes a resolved ComputedStyle property into a caller-owned buffer,
//! returning a `[]const u8` slice. Mirrors the CSSOM §6.5 resolved-value
//! algorithm for the property subset most commonly queried by WPT / real
//! pages (dimensions, margin/padding, display, position, color, typography,
//! flex, overflow).
//!
//! This complements the QuickJS-specific serializer in `src/js/dom_style.zig`
//! (`computedStyleToStringWithBox`) so the kotori JS engine can share the
//! cascade resolution path without depending on qjs types.
//!
//! Spec: CSSOM §6.5 (resolved value), CSSOM §6.7 (getPropertyValue).

const std = @import("std");
const computed_mod = @import("../computed.zig");
const ComputedStyle = computed_mod.ComputedStyle;
const Box = @import("../../layout/box.zig").Box;

/// Serialize `prop` from `style` (with optional layout `box_opt` for used
/// values) into `buf`. Returns the written slice or `null` if the property
/// is not supported by this serializer (caller should fall back to inline
/// style lookup).
pub fn computedStyleToSlice(
    style: *const ComputedStyle,
    prop: []const u8,
    box_opt: ?*const Box,
    buf: []u8,
) ?[]const u8 {
    const eq = std.mem.eql;

    // Layout / display
    if (eq(u8, prop, "display")) return displayStr(style);
    if (eq(u8, prop, "position")) return positionStr(style.position);
    if (eq(u8, prop, "visibility")) return visibilityStr(style.visibility);
    if (eq(u8, prop, "float")) return floatStr(style.float_);
    if (eq(u8, prop, "clear")) return clearStr(style.clear);
    if (eq(u8, prop, "box-sizing"))
        return if (style.box_sizing == .border_box) "border-box" else "content-box";
    if (eq(u8, prop, "overflow-x")) return overflowStr(style.overflow_x);
    if (eq(u8, prop, "overflow-y")) return overflowStr(style.overflow_y);
    if (eq(u8, prop, "overflow"))
        return if (style.overflow_x == style.overflow_y) overflowStr(style.overflow_x) else null;

    // Dimensions
    if (eq(u8, prop, "width")) {
        if (box_opt) |b| {
            if (style.width == .auto) return "auto";
            return fmtPx(b.content.width, buf);
        }
        return dimStr(style.width, buf);
    }
    if (eq(u8, prop, "height")) {
        if (box_opt) |b| {
            if (style.height == .auto) return "auto";
            return fmtPx(b.content.height, buf);
        }
        return dimStr(style.height, buf);
    }
    if (eq(u8, prop, "min-width")) return dimStr(style.min_width, buf);
    if (eq(u8, prop, "max-width")) return dimStr(style.max_width, buf);
    if (eq(u8, prop, "min-height")) return dimStr(style.min_height, buf);
    if (eq(u8, prop, "max-height")) return dimStr(style.max_height, buf);

    // Margin
    if (eq(u8, prop, "margin-top"))
        return fmtPx(if (box_opt) |b| b.margin.top else style.margin_top, buf);
    if (eq(u8, prop, "margin-right"))
        return fmtPx(if (box_opt) |b| b.margin.right else style.margin_right, buf);
    if (eq(u8, prop, "margin-bottom"))
        return fmtPx(if (box_opt) |b| b.margin.bottom else style.margin_bottom, buf);
    if (eq(u8, prop, "margin-left"))
        return fmtPx(if (box_opt) |b| b.margin.left else style.margin_left, buf);

    // Padding
    if (eq(u8, prop, "padding-top"))
        return fmtPx(if (box_opt) |b| b.padding.top else style.padding_top, buf);
    if (eq(u8, prop, "padding-right"))
        return fmtPx(if (box_opt) |b| b.padding.right else style.padding_right, buf);
    if (eq(u8, prop, "padding-bottom"))
        return fmtPx(if (box_opt) |b| b.padding.bottom else style.padding_bottom, buf);
    if (eq(u8, prop, "padding-left"))
        return fmtPx(if (box_opt) |b| b.padding.left else style.padding_left, buf);

    // Border width
    if (eq(u8, prop, "border-top-width")) return fmtPx(style.border_top_width, buf);
    if (eq(u8, prop, "border-right-width")) return fmtPx(style.border_right_width, buf);
    if (eq(u8, prop, "border-bottom-width")) return fmtPx(style.border_bottom_width, buf);
    if (eq(u8, prop, "border-left-width")) return fmtPx(style.border_left_width, buf);

    // Border style
    if (eq(u8, prop, "border-top-style")) return borderStyleStr(style.border_top_style);
    if (eq(u8, prop, "border-right-style")) return borderStyleStr(style.border_right_style);
    if (eq(u8, prop, "border-bottom-style")) return borderStyleStr(style.border_bottom_style);
    if (eq(u8, prop, "border-left-style")) return borderStyleStr(style.border_left_style);

    // Position offsets
    if (eq(u8, prop, "top")) return dimStr(style.top, buf);
    if (eq(u8, prop, "left")) return dimStr(style.left, buf);
    if (eq(u8, prop, "right")) return dimStr(style.right, buf);
    if (eq(u8, prop, "bottom")) return dimStr(style.bottom, buf);
    if (eq(u8, prop, "z-index")) {
        return std.fmt.bufPrint(buf, "{d}", .{style.z_index}) catch null;
    }

    // Color
    if (eq(u8, prop, "color")) return argbToSlice(style.color, buf);
    if (eq(u8, prop, "background-color")) return argbToSlice(style.background_color, buf);
    if (eq(u8, prop, "border-top-color")) return argbToSlice(style.border_top_color, buf);
    if (eq(u8, prop, "border-right-color")) return argbToSlice(style.border_right_color, buf);
    if (eq(u8, prop, "border-bottom-color")) return argbToSlice(style.border_bottom_color, buf);
    if (eq(u8, prop, "border-left-color")) return argbToSlice(style.border_left_color, buf);

    // Typography
    if (eq(u8, prop, "font-size")) return fmtPx(style.font_size_px, buf);
    if (eq(u8, prop, "font-weight"))
        return std.fmt.bufPrint(buf, "{d}", .{style.font_weight}) catch null;
    if (eq(u8, prop, "font-family")) return fontFamilyStr(style);
    if (eq(u8, prop, "font-style")) return fontStyleStr(style.font_style);
    if (eq(u8, prop, "text-align")) return textAlignStr(style.text_align);
    if (eq(u8, prop, "line-height")) {
        return switch (style.line_height) {
            .normal => "normal",
            .px => |v| fmtPx(v, buf),
            .number => |v| std.fmt.bufPrint(buf, "{d}", .{v}) catch null,
        };
    }
    if (eq(u8, prop, "opacity")) {
        return std.fmt.bufPrint(buf, "{d}", .{style.opacity}) catch null;
    }

    // Flex
    if (eq(u8, prop, "flex-direction")) return flexDirectionStr(style.flex_direction);
    if (eq(u8, prop, "flex-wrap")) return flexWrapStr(style.flex_wrap);
    if (eq(u8, prop, "flex-grow"))
        return std.fmt.bufPrint(buf, "{d}", .{style.flex_grow}) catch null;
    if (eq(u8, prop, "flex-shrink"))
        return std.fmt.bufPrint(buf, "{d}", .{style.flex_shrink}) catch null;
    if (eq(u8, prop, "flex-basis")) return dimStr(style.flex_basis, buf);
    if (eq(u8, prop, "justify-content")) return justifyContentStr(style.justify_content);
    if (eq(u8, prop, "align-content")) return alignContentStr(style.align_content);
    if (eq(u8, prop, "align-items")) return alignItemsStr(style.align_items);
    if (eq(u8, prop, "align-self")) return alignItemsStr(style.align_self);
    if (eq(u8, prop, "order"))
        return std.fmt.bufPrint(buf, "{d}", .{style.order}) catch null;
    if (eq(u8, prop, "gap") or eq(u8, prop, "column-gap")) return fmtPx(style.gap, buf);
    if (eq(u8, prop, "row-gap")) return fmtPx(style.row_gap, buf);

    return null;
}

fn fmtPx(v: f32, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{d}px", .{v}) catch null;
}

fn dimStr(dim: ComputedStyle.Dimension, buf: []u8) ?[]const u8 {
    return switch (dim) {
        .auto => "auto",
        .none => "none",
        .px => |v| fmtPx(v, buf),
        .percent => |v| std.fmt.bufPrint(buf, "{d}%", .{v}) catch null,
        .min_content => "min-content",
        .max_content => "max-content",
        .fit_content => "fit-content",
        .content => "content",
        .calc => |expr| expr,
    };
}

fn argbToSlice(argb: u32, buf: []u8) ?[]const u8 {
    const a: u8 = @intCast((argb >> 24) & 0xFF);
    const r: u8 = @intCast((argb >> 16) & 0xFF);
    const g: u8 = @intCast((argb >> 8) & 0xFF);
    const b: u8 = @intCast(argb & 0xFF);
    if (a == 255) {
        return std.fmt.bufPrint(buf, "rgb({d}, {d}, {d})", .{ r, g, b }) catch null;
    } else if (a == 0) {
        // CSSOM: transparent serializes as "rgba(0, 0, 0, 0)"
        return std.fmt.bufPrint(buf, "rgba({d}, {d}, {d}, 0)", .{ r, g, b }) catch null;
    } else {
        const af: f32 = @as(f32, @floatFromInt(a)) / 255.0;
        return std.fmt.bufPrint(buf, "rgba({d}, {d}, {d}, {d})", .{ r, g, b, af }) catch null;
    }
}

fn displayStr(style: *const ComputedStyle) []const u8 {
    // CSS 2.1 §9.7 blockification.
    const needs_blockify = (style.position == .absolute or style.position == .fixed or
        style.float_ != .none);
    return switch (style.display) {
        .block => "block",
        .inline_ => if (needs_blockify) "block" else "inline",
        .none => "none",
        .flex => "flex",
        .inline_block => if (needs_blockify) "block" else "inline-block",
        .inline_flex => if (needs_blockify) "flex" else "inline-flex",
        .grid => "grid",
        .inline_grid => if (needs_blockify) "grid" else "inline-grid",
        .table => "table",
        .inline_table => if (needs_blockify) "table" else "inline-table",
        .table_row => if (needs_blockify) "block" else "table-row",
        .table_cell => if (needs_blockify) "block" else "table-cell",
        .table_caption => if (needs_blockify) "block" else "table-caption",
        .table_row_group => if (needs_blockify) "block" else "table-row-group",
        .table_header_group => if (needs_blockify) "block" else "table-header-group",
        .table_footer_group => if (needs_blockify) "block" else "table-footer-group",
        .table_column => if (needs_blockify) "block" else "table-column",
        .table_column_group => if (needs_blockify) "block" else "table-column-group",
        .list_item => "list-item",
        .contents => "contents",
        .other => "block",
    };
}

fn positionStr(p: ComputedStyle.Position) []const u8 {
    return switch (p) {
        .static_ => "static",
        .relative => "relative",
        .absolute => "absolute",
        .fixed => "fixed",
        .sticky => "sticky",
    };
}

fn visibilityStr(v: ComputedStyle.Visibility) []const u8 {
    return switch (v) {
        .visible => "visible",
        .hidden => "hidden",
        .collapse => "collapse",
    };
}

fn floatStr(f: ComputedStyle.Float) []const u8 {
    return switch (f) { .none => "none", .left => "left", .right => "right" };
}

fn clearStr(c: ComputedStyle.Clear) []const u8 {
    return switch (c) { .none => "none", .left => "left", .right => "right", .both => "both" };
}

fn overflowStr(o: ComputedStyle.Overflow) []const u8 {
    return switch (o) {
        .visible => "visible",
        .hidden => "hidden",
        .scroll => "scroll",
        .auto_ => "auto",
    };
}

fn borderStyleStr(s: ComputedStyle.BorderStyle) []const u8 {
    return switch (s) {
        .none => "none",
        .hidden => "hidden",
        .solid => "solid",
        .dashed => "dashed",
        .dotted => "dotted",
        .double_ => "double",
        .groove => "groove",
        .ridge => "ridge",
        .inset => "inset",
        .outset => "outset",
    };
}

fn fontFamilyStr(style: *const ComputedStyle) []const u8 {
    if (style.font_family == .web_font) {
        if (style.font_family_name) |name| return name;
    }
    return switch (style.font_family) {
        .sans_serif, .web_font => "sans-serif",
        .serif => "serif",
        .monospace => "monospace",
    };
}

fn fontStyleStr(s: ComputedStyle.FontStyle) []const u8 {
    return switch (s) { .normal => "normal", .italic => "italic", .oblique => "oblique" };
}

fn textAlignStr(a: ComputedStyle.TextAlign) []const u8 {
    return switch (a) { .left => "left", .right => "right", .center => "center", .justify => "justify" };
}

fn flexDirectionStr(d: ComputedStyle.FlexDirection) []const u8 {
    return switch (d) {
        .row => "row",
        .row_reverse => "row-reverse",
        .column => "column",
        .column_reverse => "column-reverse",
    };
}

fn flexWrapStr(w: ComputedStyle.FlexWrap) []const u8 {
    return switch (w) { .nowrap => "nowrap", .wrap => "wrap", .wrap_reverse => "wrap-reverse" };
}

fn justifyContentStr(j: ComputedStyle.JustifyContent) []const u8 {
    return switch (j) {
        .normal => "normal",
        .flex_start => "flex-start",
        .flex_end => "flex-end",
        .center => "center",
        .space_between => "space-between",
        .space_around => "space-around",
        .space_evenly => "space-evenly",
    };
}

fn alignContentStr(a: ComputedStyle.AlignContent) []const u8 {
    return switch (a) {
        .normal => "normal",
        .stretch => "stretch",
        .flex_start => "flex-start",
        .flex_end => "flex-end",
        .center => "center",
        .space_between => "space-between",
        .space_around => "space-around",
        .space_evenly => "space-evenly",
    };
}

fn alignItemsStr(a: ComputedStyle.AlignItems) []const u8 {
    return switch (a) {
        .auto => "normal",
        .stretch => "stretch",
        .flex_start => "flex-start",
        .flex_end => "flex-end",
        .center => "center",
        .baseline => "baseline",
    };
}

