//! dom_style.zig — CSS/Style-related functions extracted from dom_api.zig
//!
//! Contains: getComputedStyle, CSS.supports, computed-style formatting,
//! CSS value validation/canonicalization, style property access, color formatting,
//! calc helpers, and all related CSS utility functions.

const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;
const lxb = @import("../bindings/lexbor.zig").c;
const api = @import("dom_api.zig");
const ComputedStyle = @import("../css/computed.zig").ComputedStyle;
const Box = @import("../layout/box.zig").Box;
const cascade_mod = @import("../css/cascade.zig");
const css_ast = @import("../css/ast.zig");
const css_properties = @import("../css/properties.zig");
const computed_mod = @import("../css/computed.zig");

// ── Helpers (delegated to dom_api) ───────────────────────────────────

fn getNode(ctx: *qjs.JSContext, val: qjs.JSValue) ?*lxb.lxb_dom_node_t {
    return api.getNode(ctx, val);
}

fn getElement(ctx: *qjs.JSContext, val: qjs.JSValue) ?*lxb.lxb_dom_element_t {
    return api.getElement(ctx, val);
}

const StringSlice = struct { ptr: [*]const u8, len: usize };

fn jsStringToSlice(ctx: *qjs.JSContext, val: qjs.JSValue) ?StringSlice {
    const result = api.jsStringToSlice(ctx, val) orelse return null;
    return StringSlice{ .ptr = result.ptr, .len = result.len };
}

// ── External Lexbor functions ────────────────────────────────────────
extern fn lxb_dom_element_get_attribute(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize, value_len: *usize) ?[*]const u8;
extern fn lxb_dom_element_set_attribute(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize, value: [*]const u8, value_len: usize) ?*anyopaque;

// ── Style Property Access ────────────────────────────────────────────

pub fn getStyleProperty(style_str: []const u8, css_prop: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < style_str.len) {
        // Skip whitespace
        while (pos < style_str.len and (style_str[pos] == ' ' or style_str[pos] == '\t' or style_str[pos] == '\n')) pos += 1;
        if (pos >= style_str.len) break;
        // Find property name
        const prop_start = pos;
        while (pos < style_str.len and style_str[pos] != ':' and style_str[pos] != ';') pos += 1;
        if (pos >= style_str.len or style_str[pos] != ':') break;
        const prop_name = std.mem.trim(u8, style_str[prop_start..pos], " \t\n");
        pos += 1; // skip ':'
        // Find value
        const val_start = pos;
        while (pos < style_str.len and style_str[pos] != ';') pos += 1;
        const val = std.mem.trim(u8, style_str[val_start..pos], " \t\n");
        if (pos < style_str.len) pos += 1; // skip ';'

        if (std.ascii.eqlIgnoreCase(prop_name, css_prop)) return val;
    }
    return null;
}

/// Set a property in a style string, returning a new string in the provided buffer.
pub fn setStyleProperty(style_str: []const u8, css_prop: []const u8, css_val: []const u8, buf: []u8) ?[]const u8 {
    var out_pos: usize = 0;
    var found = false;

    // Copy existing properties, replacing the target one
    var iter_pos: usize = 0;
    while (iter_pos < style_str.len) {
        // Skip whitespace
        while (iter_pos < style_str.len and (style_str[iter_pos] == ' ' or style_str[iter_pos] == '\t')) iter_pos += 1;
        if (iter_pos >= style_str.len) break;
        const prop_start = iter_pos;
        while (iter_pos < style_str.len and style_str[iter_pos] != ':' and style_str[iter_pos] != ';') iter_pos += 1;
        if (iter_pos >= style_str.len or style_str[iter_pos] != ':') break;
        const prop_name = std.mem.trim(u8, style_str[prop_start..iter_pos], " \t\n");
        iter_pos += 1; // skip ':'
        const val_start = iter_pos;
        while (iter_pos < style_str.len and style_str[iter_pos] != ';') iter_pos += 1;
        const val = std.mem.trim(u8, style_str[val_start..iter_pos], " \t\n");
        if (iter_pos < style_str.len) iter_pos += 1; // skip ';'

        if (std.ascii.eqlIgnoreCase(prop_name, css_prop)) {
            found = true;
            if (css_val.len == 0) continue; // remove property
            // Write replacement
            const needed = prop_name.len + 2 + css_val.len + 2; // "prop: val; "
            if (out_pos + needed > buf.len) return null;
            @memcpy(buf[out_pos..][0..prop_name.len], prop_name);
            out_pos += prop_name.len;
            buf[out_pos] = ':';
            out_pos += 1;
            buf[out_pos] = ' ';
            out_pos += 1;
            @memcpy(buf[out_pos..][0..css_val.len], css_val);
            out_pos += css_val.len;
            buf[out_pos] = ';';
            out_pos += 1;
            buf[out_pos] = ' ';
            out_pos += 1;
        } else {
            // Copy existing property as-is
            const needed = prop_name.len + 2 + val.len + 2;
            if (out_pos + needed > buf.len) return null;
            @memcpy(buf[out_pos..][0..prop_name.len], prop_name);
            out_pos += prop_name.len;
            buf[out_pos] = ':';
            out_pos += 1;
            buf[out_pos] = ' ';
            out_pos += 1;
            @memcpy(buf[out_pos..][0..val.len], val);
            out_pos += val.len;
            buf[out_pos] = ';';
            out_pos += 1;
            buf[out_pos] = ' ';
            out_pos += 1;
        }
    }
    if (!found and css_val.len > 0) {
        // Append new property
        const needed = css_prop.len + 2 + css_val.len + 1;
        if (out_pos + needed > buf.len) return null;
        @memcpy(buf[out_pos..][0..css_prop.len], css_prop);
        out_pos += css_prop.len;
        buf[out_pos] = ':';
        out_pos += 1;
        buf[out_pos] = ' ';
        out_pos += 1;
        @memcpy(buf[out_pos..][0..css_val.len], css_val);
        out_pos += css_val.len;
        buf[out_pos] = ';';
        out_pos += 1;
    }

    // Trim trailing space
    if (out_pos > 0 and buf[out_pos - 1] == ' ') out_pos -= 1;
    return buf[0..out_pos];
}

// ── Style cssText getter/setter ────────────────────────────────────

pub fn styleGetCssText(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return qjs.JS_NewStringLen(c, "", 0);
    var style_len: usize = 0;
    const style_ptr = lxb_dom_element_get_attribute(elem, "style", 5, &style_len);
    if (style_ptr == null or style_len == 0) return qjs.JS_NewStringLen(c, "", 0);
    return qjs.JS_NewStringLen(c, style_ptr.?, style_len);
}

pub fn styleSetCssText(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return quickjs.JS_UNDEFINED();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, s.ptr);
    _ = lxb_dom_element_set_attribute(elem, "style", 5, s.ptr, s.len);
    api.setDomDirty();
    return quickjs.JS_UNDEFINED();
}

// ── computedStyleGetPropertyValue ──────────────────────────────────

pub fn computedStyleGetPropertyValue(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return qjs.JS_NewStringLen(c, "", 0);
    const args = argv orelse return qjs.JS_NewStringLen(c, "", 0);

    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);

    const prop_s = jsStringToSlice(c, args[0]) orelse return qjs.JS_NewStringLen(c, "", 0);
    defer qjs.JS_FreeCString(c, prop_s.ptr);
    const prop = prop_s.ptr[0..prop_s.len];

    // Check inline style FIRST (highest specificity — reflects JS modifications)
    const elem = getElement(c, elem_val);
    if (elem) |el| {
        var style_len: usize = 0;
        const style_ptr = lxb_dom_element_get_attribute(el, "style", 5, &style_len);
        if (style_ptr != null and style_len > 0) {
            if (getStyleProperty(style_ptr.?[0..style_len], prop)) |val| {
                // Resolve var() references in computed style getPropertyValue
                if (std.mem.indexOf(u8, val, "var(") != null) {
                    const resolved = resolveVarFromElement(c, elem_val, val);
                    if (resolved) |rv| {
                        return resolveInlineForComputed(c, prop, rv, elem_val);
                    }
                }
                const trimmed = std.mem.trim(u8, val, " \t\r\n");
                // Resolve CSS-wide keywords to computed values
                if (eqlIgnoreCase(trimmed, "initial")) {
                    return cssInitialValue(c, prop);
                } else if (eqlIgnoreCase(trimmed, "inherit")) {
                    return getInheritedComputedValue(c, elem_val, prop);
                } else if (eqlIgnoreCase(trimmed, "unset")) {
                    if (isCssInheritedProperty(prop)) {
                        return getInheritedComputedValue(c, elem_val, prop);
                    }
                    return cssInitialValue(c, prop);
                } else if (eqlIgnoreCase(trimmed, "revert")) {
                    // Fall through to cascade (UA value)
                } else {
                    return resolveInlineForComputed(c, prop, val, elem_val);
                }
            }
            // Try shorthand reconstruction from expanded longhands (with resolution)
            const istyle = style_ptr.?[0..style_len];
            if (api.reconstructBoxShorthandJSWithElem(c, istyle, prop, elem_val)) |reconstructed| {
                return reconstructed;
            }
            // Try longhand from stored shorthand — resolve to computed value
            if (api.getLonghandFromShorthand(istyle, prop)) |lh_val| {
                return resolveInlineForComputed(c, prop, lh_val, elem_val);
            }
        }
    }

    // Fall back to cascade computed style, using layout box used values where available
    const node = getNode(c, elem_val);
    if (node != null and api.getStylesForCtx(c) != null) {
        if (api.getStylesForCtx(c).?.get(@intFromPtr(node.?))) |style| {
            // Try to use layout box for resolved margin/padding/dimension values
            const box_opt = if (api.getRootBox(c)) |root| api.findBoxForNode(root, node.?) else null;
            return computedStyleToStringWithBox(c, &style, prop, box_opt);
        }
    }
    return qjs.JS_NewStringLen(c, "", 0);
}

// ── Computed Style Formatting ──────────────────────────────────────

/// Convert a ComputedStyle field to a CSS string for getComputedStyle (without box context).
pub fn computedStyleToString(c: *qjs.JSContext, style: *const ComputedStyle, prop: []const u8) qjs.JSValue {
    return computedStyleToStringWithBox(c, style, prop, null);
}

/// Convert a ComputedStyle field to a CSS string, using layout box used values when available.
pub fn computedStyleToStringWithBox(c: *qjs.JSContext, style: *const ComputedStyle, prop: []const u8, box_opt: ?*const Box) qjs.JSValue {
    // Map CSS logical properties to physical properties (horizontal-tb writing mode assumed)
    // Per CSS Logical Properties Level 1 spec
    const mapped_prop = mapLogicalToPhysical(prop);
    return computedStyleToStringWithBoxInner(c, style, mapped_prop, box_opt);
}

/// Map CSS logical properties to physical equivalents (assuming horizontal-tb)
pub fn mapLogicalToPhysical(prop: []const u8) []const u8 {
    // margin-block-start/end → margin-top/bottom
    if (eqlIgnoreCase(prop, "margin-block-start")) return "margin-top";
    if (eqlIgnoreCase(prop, "margin-block-end")) return "margin-bottom";
    if (eqlIgnoreCase(prop, "margin-inline-start")) return "margin-left";
    if (eqlIgnoreCase(prop, "margin-inline-end")) return "margin-right";
    // padding-block-start/end → padding-top/bottom
    if (eqlIgnoreCase(prop, "padding-block-start")) return "padding-top";
    if (eqlIgnoreCase(prop, "padding-block-end")) return "padding-bottom";
    if (eqlIgnoreCase(prop, "padding-inline-start")) return "padding-left";
    if (eqlIgnoreCase(prop, "padding-inline-end")) return "padding-right";
    // border-block-*-color/width/style → border-top/bottom-*
    if (eqlIgnoreCase(prop, "border-block-start-color")) return "border-top-color";
    if (eqlIgnoreCase(prop, "border-block-end-color")) return "border-bottom-color";
    if (eqlIgnoreCase(prop, "border-inline-start-color")) return "border-left-color";
    if (eqlIgnoreCase(prop, "border-inline-end-color")) return "border-right-color";
    if (eqlIgnoreCase(prop, "border-block-start-width")) return "border-top-width";
    if (eqlIgnoreCase(prop, "border-block-end-width")) return "border-bottom-width";
    if (eqlIgnoreCase(prop, "border-inline-start-width")) return "border-left-width";
    if (eqlIgnoreCase(prop, "border-inline-end-width")) return "border-right-width";
    if (eqlIgnoreCase(prop, "border-block-start-style")) return "border-top-style";
    if (eqlIgnoreCase(prop, "border-block-end-style")) return "border-bottom-style";
    if (eqlIgnoreCase(prop, "border-inline-start-style")) return "border-left-style";
    if (eqlIgnoreCase(prop, "border-inline-end-style")) return "border-right-style";
    // inset-block/inline → top/bottom/left/right
    if (eqlIgnoreCase(prop, "inset-block-start")) return "top";
    if (eqlIgnoreCase(prop, "inset-block-end")) return "bottom";
    if (eqlIgnoreCase(prop, "inset-inline-start")) return "left";
    if (eqlIgnoreCase(prop, "inset-inline-end")) return "right";
    // block-size/inline-size → height/width
    if (eqlIgnoreCase(prop, "block-size")) return "height";
    if (eqlIgnoreCase(prop, "inline-size")) return "width";
    if (eqlIgnoreCase(prop, "min-block-size")) return "min-height";
    if (eqlIgnoreCase(prop, "min-inline-size")) return "min-width";
    if (eqlIgnoreCase(prop, "max-block-size")) return "max-height";
    if (eqlIgnoreCase(prop, "max-inline-size")) return "max-width";
    return prop;
}

pub fn computedStyleToStringWithBoxInner(c: *qjs.JSContext, style: *const ComputedStyle, prop: []const u8, box_opt: ?*const Box) qjs.JSValue {
    // Format buffer for numeric values
    var buf: [128]u8 = undefined;

    if (std.mem.eql(u8, prop, "display")) {
        // CSS 2.1 §9.7: Blockification — position:absolute/fixed and float cause
        // inline display types to become their block equivalents
        const needs_blockify = (style.position == .absolute or style.position == .fixed or
            style.float_ != .none);
        const s = switch (style.display) {
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
            // CSS Display L3 §2.7: Internal table display types blockify to "block"
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
            else => "block",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "position")) {
        const s = switch (style.position) {
            .static_ => "static",
            .relative => "relative",
            .absolute => "absolute",
            .fixed => "fixed",
            .sticky => "sticky",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "visibility")) {
        const s = switch (style.visibility) {
            .visible => "visible",
            .hidden => "hidden",
            .collapse => "collapse",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "color")) {
        return argbToCssColor(c, style.color, &buf);
    } else if (std.mem.eql(u8, prop, "background-color")) {
        return argbToCssColor(c, style.background_color, &buf);
    } else if (std.mem.eql(u8, prop, "outline-color")) {
        // Default outline-color is currentcolor → resolve to computed color
        return argbToCssColor(c, style.color, &buf);
    } else if (std.mem.eql(u8, prop, "caret-color")) {
        // Default caret-color is auto → resolved as currentcolor
        return argbToCssColor(c, style.color, &buf);
    } else if (std.mem.eql(u8, prop, "box-shadow")) {
        // Default box-shadow is none
        return qjs.JS_NewStringLen(c, "none", 4);
    } else if (std.mem.eql(u8, prop, "text-shadow")) {
        return qjs.JS_NewStringLen(c, "none", 4);
    } else if (std.mem.eql(u8, prop, "font-size")) {
        return fmtPx(c, style.font_size_px, &buf);
    } else if (std.mem.eql(u8, prop, "font-weight")) {
        const result = std.fmt.bufPrint(&buf, "{d}", .{style.font_weight}) catch return qjs.JS_NewStringLen(c, "400", 3);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    } else if (std.mem.eql(u8, prop, "font-family")) {
        if (style.font_family == .web_font) {
            if (style.font_family_name) |name| {
                return qjs.JS_NewStringLen(c, name.ptr, name.len);
            }
        }
        const s = switch (style.font_family) {
            .sans_serif, .web_font => "sans-serif",
            .serif => "serif",
            .monospace => "monospace",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "text-align")) {
        const s = switch (style.text_align) {
            .left => "left",
            .right => "right",
            .center => "center",
            .justify => "justify",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "width")) {
        // CSS 2.1: computed width is the used value (px) when in layout
        if (box_opt) |box| {
            if (style.width == .auto) {
                return qjs.JS_NewStringLen(c, "auto", 4);
            }
            return fmtPx(c, box.content.width, &buf);
        }
        return dimensionToString(c, style.width, &buf);
    } else if (std.mem.eql(u8, prop, "height")) {
        if (box_opt) |box| {
            if (style.height == .auto) {
                return qjs.JS_NewStringLen(c, "auto", 4);
            }
            return fmtPx(c, box.content.height, &buf);
        }
        return dimensionToString(c, style.height, &buf);
    } else if (std.mem.eql(u8, prop, "margin")) {
        if (box_opt) |box| {
            return fmtBoxShorthand(c, box.margin.top, box.margin.right, box.margin.bottom, box.margin.left, &buf);
        }
        return fmtBoxShorthand(c, style.margin_top, style.margin_right, style.margin_bottom, style.margin_left, &buf);
    } else if (std.mem.eql(u8, prop, "margin-top")) {
        if (box_opt) |box| return fmtPx(c, box.margin.top, &buf);
        return fmtPx(c, style.margin_top, &buf);
    } else if (std.mem.eql(u8, prop, "margin-right")) {
        if (box_opt) |box| return fmtPx(c, box.margin.right, &buf);
        return fmtPx(c, style.margin_right, &buf);
    } else if (std.mem.eql(u8, prop, "margin-bottom")) {
        if (box_opt) |box| return fmtPx(c, box.margin.bottom, &buf);
        return fmtPx(c, style.margin_bottom, &buf);
    } else if (std.mem.eql(u8, prop, "margin-left")) {
        if (box_opt) |box| return fmtPx(c, box.margin.left, &buf);
        return fmtPx(c, style.margin_left, &buf);
    } else if (std.mem.eql(u8, prop, "margin-trim")) {
        return fmtMarginTrim(c, style.margin_trim);
    } else if (std.mem.eql(u8, prop, "padding")) {
        if (box_opt) |box| {
            return fmtBoxShorthand(c, box.padding.top, box.padding.right, box.padding.bottom, box.padding.left, &buf);
        }
        return fmtBoxShorthand(c, style.padding_top, style.padding_right, style.padding_bottom, style.padding_left, &buf);
    } else if (std.mem.eql(u8, prop, "padding-top")) {
        if (box_opt) |box| return fmtPx(c, box.padding.top, &buf);
        return fmtPx(c, style.padding_top, &buf);
    } else if (std.mem.eql(u8, prop, "padding-right")) {
        if (box_opt) |box| return fmtPx(c, box.padding.right, &buf);
        return fmtPx(c, style.padding_right, &buf);
    } else if (std.mem.eql(u8, prop, "padding-bottom")) {
        if (box_opt) |box| return fmtPx(c, box.padding.bottom, &buf);
        return fmtPx(c, style.padding_bottom, &buf);
    } else if (std.mem.eql(u8, prop, "padding-left")) {
        if (box_opt) |box| return fmtPx(c, box.padding.left, &buf);
        return fmtPx(c, style.padding_left, &buf);
    } else if (std.mem.eql(u8, prop, "border-top-width")) {
        return fmtPx(c, style.border_top_width, &buf);
    } else if (std.mem.eql(u8, prop, "border-right-width")) {
        return fmtPx(c, style.border_right_width, &buf);
    } else if (std.mem.eql(u8, prop, "border-bottom-width")) {
        return fmtPx(c, style.border_bottom_width, &buf);
    } else if (std.mem.eql(u8, prop, "border-left-width")) {
        return fmtPx(c, style.border_left_width, &buf);
    } else if (std.mem.eql(u8, prop, "opacity")) {
        const clamped = @max(@as(f32, 0), @min(@as(f32, 1), style.opacity));
        const result = std.fmt.bufPrint(&buf, "{d}", .{clamped}) catch return qjs.JS_NewStringLen(c, "1", 1);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    } else if (std.mem.eql(u8, prop, "z-index")) {
        if (style.z_index == 0 and style.position == .static_) {
            return qjs.JS_NewStringLen(c, "auto", 4);
        }
        const result = std.fmt.bufPrint(&buf, "{d}", .{style.z_index}) catch return qjs.JS_NewStringLen(c, "0", 1);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    } else if (std.mem.eql(u8, prop, "overflow-x")) {
        return overflowToString(c, style.overflow_x);
    } else if (std.mem.eql(u8, prop, "overflow-y")) {
        return overflowToString(c, style.overflow_y);
    } else if (std.mem.eql(u8, prop, "flex-direction")) {
        const s = switch (style.flex_direction) {
            .row => "row",
            .row_reverse => "row-reverse",
            .column => "column",
            .column_reverse => "column-reverse",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "flex-grow")) {
        const result = std.fmt.bufPrint(&buf, "{d}", .{style.flex_grow}) catch return qjs.JS_NewStringLen(c, "0", 1);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    } else if (std.mem.eql(u8, prop, "flex-shrink")) {
        const result = std.fmt.bufPrint(&buf, "{d}", .{style.flex_shrink}) catch return qjs.JS_NewStringLen(c, "1", 1);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    } else if (std.mem.eql(u8, prop, "box-sizing")) {
        const s = switch (style.box_sizing) {
            .content_box => "content-box",
            .border_box => "border-box",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "float")) {
        const s = switch (style.float_) {
            .none => "none",
            .left => "left",
            .right => "right",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "clear")) {
        const s = switch (style.clear) {
            .none => "none",
            .left => "left",
            .right => "right",
            .both => "both",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "top")) {
        return dimensionToString(c, style.top, &buf);
    } else if (std.mem.eql(u8, prop, "right")) {
        return dimensionToString(c, style.right, &buf);
    } else if (std.mem.eql(u8, prop, "bottom")) {
        return dimensionToString(c, style.bottom, &buf);
    } else if (std.mem.eql(u8, prop, "left")) {
        return dimensionToString(c, style.left, &buf);
    } else if (std.mem.eql(u8, prop, "overflow")) {
        // Shorthand: if both axes are the same, return one value
        const x = switch (style.overflow_x) { .visible => "visible", .hidden => "hidden", .scroll => "scroll", .auto_ => "auto" };
        const y = switch (style.overflow_y) { .visible => "visible", .hidden => "hidden", .scroll => "scroll", .auto_ => "auto" };
        if (std.mem.eql(u8, x, y)) {
            return qjs.JS_NewStringLen(c, x.ptr, x.len);
        }
        const result = std.fmt.bufPrint(&buf, "{s} {s}", .{ x, y }) catch return qjs.JS_NewStringLen(c, "visible", 7);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    } else if (std.mem.eql(u8, prop, "min-width")) {
        return dimensionToString(c, style.min_width, &buf);
    } else if (std.mem.eql(u8, prop, "max-width")) {
        return dimensionToString(c, style.max_width, &buf);
    } else if (std.mem.eql(u8, prop, "min-height")) {
        return dimensionToString(c, style.min_height, &buf);
    } else if (std.mem.eql(u8, prop, "max-height")) {
        return dimensionToString(c, style.max_height, &buf);
    } else if (std.mem.eql(u8, prop, "line-height")) {
        return switch (style.line_height) {
            .normal => qjs.JS_NewStringLen(c, "normal", 6),
            .px => |v| fmtPx(c, v, &buf),
            .number => |n| blk: {
                const result = std.fmt.bufPrint(&buf, "{d}", .{n}) catch break :blk qjs.JS_NewStringLen(c, "normal", 6);
                break :blk qjs.JS_NewStringLen(c, result.ptr, result.len);
            },
        };
    } else if (std.mem.eql(u8, prop, "white-space")) {
        const s = switch (style.white_space) {
            .normal => "normal", .pre => "pre", .nowrap => "nowrap",
            .pre_wrap => "pre-wrap", .pre_line => "pre-line", .break_spaces => "break-spaces",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "word-break")) {
        const s = switch (style.word_break) { .normal => "normal", .break_all => "break-all", .keep_all => "keep-all" };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "text-overflow")) {
        const s = switch (style.text_overflow) { .clip => "clip", .ellipsis => "ellipsis" };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "font-style")) {
        const s = switch (style.font_style) { .normal => "normal", .italic => "italic", .oblique => "oblique" };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "vertical-align")) {
        const s = switch (style.vertical_align) {
            .baseline => "baseline", .top => "top", .middle => "middle", .bottom => "bottom",
            .text_top => "text-top", .text_bottom => "text-bottom", .sub => "sub", .super => "super",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "border-top-color") or std.mem.eql(u8, prop, "border-right-color") or
        std.mem.eql(u8, prop, "border-bottom-color") or std.mem.eql(u8, prop, "border-left-color"))
    {
        const color = if (std.mem.eql(u8, prop, "border-top-color")) style.border_top_color
            else if (std.mem.eql(u8, prop, "border-right-color")) style.border_right_color
            else if (std.mem.eql(u8, prop, "border-bottom-color")) style.border_bottom_color
            else style.border_left_color;
        return argbToCssColor(c, color, &buf);
    } else if (std.mem.eql(u8, prop, "border-top-style") or std.mem.eql(u8, prop, "border-right-style") or
        std.mem.eql(u8, prop, "border-bottom-style") or std.mem.eql(u8, prop, "border-left-style"))
    {
        const bs = if (std.mem.eql(u8, prop, "border-top-style")) style.border_top_style
            else if (std.mem.eql(u8, prop, "border-right-style")) style.border_right_style
            else if (std.mem.eql(u8, prop, "border-bottom-style")) style.border_bottom_style
            else style.border_left_style;
        const s = switch (bs) {
            .none => "none", .hidden => "hidden", .solid => "solid", .dashed => "dashed",
            .dotted => "dotted", .double_ => "double", .groove => "groove", .ridge => "ridge",
            .inset => "inset", .outset => "outset",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "aspect-ratio")) {
        if (style.aspect_ratio == 0) return qjs.JS_NewStringLen(c, "auto", 4);
        const result = std.fmt.bufPrint(&buf, "{d}", .{style.aspect_ratio}) catch return qjs.JS_NewStringLen(c, "auto", 4);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    } else if (std.mem.eql(u8, prop, "text-transform")) {
        const s = switch (style.text_transform) { .none => "none", .capitalize => "capitalize", .uppercase => "uppercase", .lowercase => "lowercase" };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "letter-spacing")) {
        if (style.letter_spacing == 0) return qjs.JS_NewStringLen(c, "normal", 6);
        return fmtPx(c, style.letter_spacing, &buf);
    } else if (std.mem.eql(u8, prop, "word-spacing")) {
        if (style.word_spacing == 0) return qjs.JS_NewStringLen(c, "0px", 3);
        return fmtPx(c, style.word_spacing, &buf);
    } else if (std.mem.eql(u8, prop, "text-indent")) {
        return fmtPx(c, style.text_indent, &buf);
    } else if (std.mem.eql(u8, prop, "reading-flow")) {
        const s = switch (style.reading_flow) {
            .normal => "normal",
            .flex_visual => "flex-visual",
            .flex_flow => "flex-flow",
            .grid_rows => "grid-rows",
            .grid_columns => "grid-columns",
            .grid_order => "grid-order",
            .source_order => "source-order",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "reading-order")) {
        const result = std.fmt.bufPrint(&buf, "{d}", .{style.reading_order}) catch return qjs.JS_NewStringLen(c, "0", 1);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    }

    // Unknown property — return empty string (not undefined)
    return qjs.JS_NewStringLen(c, "", 0);
}

// ── CSS Value Formatting ───────────────────────────────────────────

/// Format an ARGB u32 as "rgb(r, g, b)" or "rgba(r, g, b, a)" string.
pub fn argbToCssColor(c: *qjs.JSContext, argb: u32, buf: *[128]u8) qjs.JSValue {
    const a = (argb >> 24) & 0xFF;
    const r = (argb >> 16) & 0xFF;
    const g_val = (argb >> 8) & 0xFF;
    const b_val = argb & 0xFF;
    if (a == 255) {
        const result = std.fmt.bufPrint(buf, "rgb({d}, {d}, {d})", .{ r, g_val, b_val }) catch return qjs.JS_NewStringLen(c, "", 0);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    } else if (a == 0 and r == 0 and g_val == 0 and b_val == 0) {
        const s = "rgba(0, 0, 0, 0)";
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else {
        // Round alpha to common fractions to match browser serialization
        const alpha_raw: f32 = @as(f32, @floatFromInt(a)) / 255.0;
        const alpha = @round(alpha_raw * 1000.0) / 1000.0;
        // Use minimal decimal places
        if (alpha == @round(alpha * 10.0) / 10.0) {
            const result = std.fmt.bufPrint(buf, "rgba({d}, {d}, {d}, {d:.1})", .{ r, g_val, b_val, alpha }) catch return qjs.JS_NewStringLen(c, "", 0);
            return qjs.JS_NewStringLen(c, result.ptr, result.len);
        } else if (alpha == @round(alpha * 100.0) / 100.0) {
            const result = std.fmt.bufPrint(buf, "rgba({d}, {d}, {d}, {d:.2})", .{ r, g_val, b_val, alpha }) catch return qjs.JS_NewStringLen(c, "", 0);
            return qjs.JS_NewStringLen(c, result.ptr, result.len);
        } else {
            const result = std.fmt.bufPrint(buf, "rgba({d}, {d}, {d}, {d:.3})", .{ r, g_val, b_val, alpha }) catch return qjs.JS_NewStringLen(c, "", 0);
            return qjs.JS_NewStringLen(c, result.ptr, result.len);
        }
    }
}

/// Format a px value as "Npx" string.
/// CSS Values 4 §10.11: NaN → 0px, ±Infinity → ±MAX_LENGTH px.
const MAX_CSS_LENGTH: f32 = 33554432.0; // 2^25, implementation-defined max CSS length
pub fn fmtPx(c: *qjs.JSContext, val: f32, buf: *[128]u8) qjs.JSValue {
    const clamped: f32 = if (std.math.isNan(val))
        0.0
    else if (std.math.isPositiveInf(val))
        MAX_CSS_LENGTH
    else if (std.math.isNegativeInf(val))
        -MAX_CSS_LENGTH
    else
        val;
    const result = std.fmt.bufPrint(buf, "{d}px", .{clamped}) catch return qjs.JS_NewStringLen(c, "0px", 3);
    return qjs.JS_NewStringLen(c, result.ptr, result.len);
}

/// Format margin-trim computed value.
pub fn fmtMarginTrim(c: *qjs.JSContext, mt: computed_mod.MarginTrim) qjs.JSValue {
    const bs = mt.block_start;
    const be = mt.block_end;
    const is_ = mt.inline_start;
    const ie = mt.inline_end;
    if (!bs and !be and !is_ and !ie) return qjs.JS_NewStringLen(c, "none", 4);
    if (bs and be and is_ and ie) return qjs.JS_NewStringLen(c, "block inline", 12);
    if (bs and be and !is_ and !ie) return qjs.JS_NewStringLen(c, "block", 5);
    if (!bs and !be and is_ and ie) return qjs.JS_NewStringLen(c, "inline", 6);
    // Individual keywords
    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    // CSS canonical order: block before inline? Actually spec says individual order doesn't matter
    // but WPT expects: block-start before inline-start, etc.
    // WPT margin-trim-computed expects block-start before inline-start
    // Canonical order: block-start, inline-start, block-end, inline-end (interleaved)
    const parts = [_]struct { flag: bool, name: []const u8 }{
        .{ .flag = bs, .name = "block-start" },
        .{ .flag = is_, .name = "inline-start" },
        .{ .flag = be, .name = "block-end" },
        .{ .flag = ie, .name = "inline-end" },
    };
    for (parts) |p| {
        if (p.flag) {
            if (pos > 0) {
                buf[pos] = ' ';
                pos += 1;
            }
            @memcpy(buf[pos..][0..p.name.len], p.name);
            pos += p.name.len;
        }
    }
    return qjs.JS_NewStringLen(c, &buf, pos);
}

// ── Inline Style Resolution for Computed Style ─────────────────────

/// Resolve an inline style value for getComputedStyle. For most properties returns as-is.
/// For margin-trim, canonicalizes to spec order (block before inline).
pub fn resolveInlineForComputed(c: *qjs.JSContext, prop: []const u8, val: []const u8, elem_val: qjs.JSValue) qjs.JSValue {
    if (eqlIgnoreCase(prop, "margin-trim")) return canonicalizeMarginTrimForComputed(c, val);
    // word-spacing/letter-spacing: 'normal' computes to '0px'
    if ((eqlIgnoreCase(prop, "word-spacing") or eqlIgnoreCase(prop, "letter-spacing")) and
        eqlIgnoreCase(std.mem.trim(u8, val, " \t"), "normal"))
        return qjs.JS_NewStringLen(c, "0px", 3);
    // top/right/bottom/left/inset-*: percentages should be preserved in computed value
    if (eqlIgnoreCase(prop, "top") or eqlIgnoreCase(prop, "right") or
        eqlIgnoreCase(prop, "bottom") or eqlIgnoreCase(prop, "left") or
        std.mem.startsWith(u8, prop, "inset"))
    {
        const tv = std.mem.trim(u8, val, " \t");
        if (tv.len > 0 and tv[tv.len - 1] == '%') return qjs.JS_NewStringLen(c, tv.ptr, tv.len);
        if (tv.len >= 5 and eqlIgnoreCase(tv[0..5], "calc(") and std.mem.indexOf(u8, tv, "%") != null)
            return qjs.JS_NewStringLen(c, tv.ptr, tv.len);
    }
    // text-indent: percentages should be preserved in computed value
    if (eqlIgnoreCase(prop, "text-indent")) {
        const tv = std.mem.trim(u8, val, " \t");
        if (tv.len > 0 and tv[tv.len - 1] == '%') return qjs.JS_NewStringLen(c, tv.ptr, tv.len);
        // calc() with % should be preserved
        if (tv.len >= 5 and eqlIgnoreCase(tv[0..5], "calc(") and std.mem.indexOf(u8, tv, "%") != null)
            return qjs.JS_NewStringLen(c, tv.ptr, tv.len);
    }
    // transition/animation-timing-function: normalize step keywords
    if (eqlIgnoreCase(prop, "transition-timing-function") or eqlIgnoreCase(prop, "animation-timing-function")) {
        const tv = std.mem.trim(u8, val, " \t");
        if (eqlIgnoreCase(tv, "step-start")) return qjs.JS_NewStringLen(c, "steps(1, start)", 15);
        if (eqlIgnoreCase(tv, "step-end")) return qjs.JS_NewStringLen(c, "steps(1)", 8);
        // steps(N, end) → steps(N), steps(N, jump-end) → steps(N)
        if (tv.len >= 6 and eqlIgnoreCase(tv[0..6], "steps(")) {
            if (std.mem.endsWith(u8, tv, ", end)") or std.mem.endsWith(u8, tv, ",end)")) {
                // Extract N
                const num_start: usize = 6;
                const comma = std.mem.indexOf(u8, tv[num_start..], ",") orelse return qjs.JS_NewStringLen(c, val.ptr, val.len);
                const num = std.mem.trim(u8, tv[num_start .. num_start + comma], " ");
                var sbuf: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&sbuf, "steps({s})", .{num}) catch return qjs.JS_NewStringLen(c, val.ptr, val.len);
                return qjs.JS_NewStringLen(c, s.ptr, s.len);
            }
            if (std.mem.endsWith(u8, tv, ", jump-end)") or std.mem.endsWith(u8, tv, ",jump-end)")) {
                const num_start: usize = 6;
                const comma = std.mem.indexOf(u8, tv[num_start..], ",") orelse return qjs.JS_NewStringLen(c, val.ptr, val.len);
                const num = std.mem.trim(u8, tv[num_start .. num_start + comma], " ");
                var sbuf: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&sbuf, "steps({s})", .{num}) catch return qjs.JS_NewStringLen(c, val.ptr, val.len);
                return qjs.JS_NewStringLen(c, s.ptr, s.len);
            }
        }
    }
    // overflow-clip-margin: normalize order and defaults
    if (eqlIgnoreCase(prop, "overflow-clip-margin")) {
        const tv = std.mem.trim(u8, val, " \t");
        // padding-box is default, so 'padding-box' alone → '0px', 'padding-box 0px' → '0px'
        if (eqlIgnoreCase(tv, "padding-box") or eqlIgnoreCase(tv, "padding-box 0px"))
            return qjs.JS_NewStringLen(c, "0px", 3);
        // content-box 0px → content-box
        if (eqlIgnoreCase(tv, "content-box 0px"))
            return qjs.JS_NewStringLen(c, "content-box", 11);
        // Reorder: length first → box first (e.g. '10px content-box' → 'content-box 10px')
        if (std.mem.indexOf(u8, tv, " ")) |sp| {
            const first = tv[0..sp];
            const second = std.mem.trim(u8, tv[sp + 1 ..], " ");
            if (eqlIgnoreCase(second, "content-box") or eqlIgnoreCase(second, "padding-box") or eqlIgnoreCase(second, "border-box")) {
                var rbuf: [64]u8 = undefined;
                if (eqlIgnoreCase(second, "padding-box")) {
                    // padding-box is default, just return the length
                    return qjs.JS_NewStringLen(c, first.ptr, first.len);
                }
                const s = std.fmt.bufPrint(&rbuf, "{s} {s}", .{ second, first }) catch return qjs.JS_NewStringLen(c, val.ptr, val.len);
                return qjs.JS_NewStringLen(c, s.ptr, s.len);
            }
        }
    }
    // Border/outline width: round to integer px
    if (eqlIgnoreCase(prop, "outline-width") or eqlIgnoreCase(prop, "border-top-width") or
        eqlIgnoreCase(prop, "border-right-width") or eqlIgnoreCase(prop, "border-bottom-width") or
        eqlIgnoreCase(prop, "border-left-width"))
    {
        const tv = std.mem.trim(u8, val, " \t");
        if (tv.len > 2 and std.mem.endsWith(u8, tv, "px")) {
            if (std.fmt.parseFloat(f32, tv[0 .. tv.len - 2])) |f| {
                const rounded = @as(i32, @intFromFloat(@round(f)));
                var ibuf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&ibuf, "{d}px", .{rounded}) catch return qjs.JS_NewStringLen(c, val.ptr, val.len);
                return qjs.JS_NewStringLen(c, s.ptr, s.len);
            } else |_| {}
        }
        // keyword → px
        if (eqlIgnoreCase(tv, "thin")) return qjs.JS_NewStringLen(c, "1px", 3);
        if (eqlIgnoreCase(tv, "medium")) return qjs.JS_NewStringLen(c, "3px", 3);
        if (eqlIgnoreCase(tv, "thick")) return qjs.JS_NewStringLen(c, "5px", 3);
    }
    // contain: canonicalize longhand combinations to shorthand keywords
    if (eqlIgnoreCase(prop, "contain")) {
        const tv = std.mem.trim(u8, val, " \t");
        // Check for 'content' = style layout paint
        if (eqlIgnoreCase(tv, "style layout paint") or eqlIgnoreCase(tv, "layout paint style") or
            eqlIgnoreCase(tv, "paint layout style") or eqlIgnoreCase(tv, "paint style layout") or
            eqlIgnoreCase(tv, "layout style paint") or eqlIgnoreCase(tv, "style paint layout"))
            return qjs.JS_NewStringLen(c, "content", 7);
        // Check for 'strict' = size style layout paint (but NOT inline-size)
        if (std.mem.indexOf(u8, tv, "size") != null and std.mem.indexOf(u8, tv, "inline-size") == null and
            std.mem.indexOf(u8, tv, "style") != null and
            std.mem.indexOf(u8, tv, "layout") != null and std.mem.indexOf(u8, tv, "paint") != null)
            return qjs.JS_NewStringLen(c, "strict", 6);
    }
    // scroll-snap-type: strip default 'proximity' strictness
    if (eqlIgnoreCase(prop, "scroll-snap-type")) {
        const tv = std.mem.trim(u8, val, " \t");
        if (std.mem.endsWith(u8, tv, " proximity")) {
            const trimmed_len = tv.len - 10; // " proximity" = 10 chars
            return qjs.JS_NewStringLen(c, tv.ptr, trimmed_len);
        }
    }
    // background-repeat: 'X X' → 'X' when both values are the same
    if (eqlIgnoreCase(prop, "background-repeat")) {
        const tv = std.mem.trim(u8, val, " \t");
        if (std.mem.indexOf(u8, tv, " ")) |sp| {
            const first = tv[0..sp];
            const second = std.mem.trim(u8, tv[sp + 1 ..], " ");
            if (eqlIgnoreCase(first, second))
                return qjs.JS_NewStringLen(c, first.ptr, first.len);
        }
    }
    // background-size: normalize 'auto auto' → 'auto', '1px' → '1px auto'
    if (eqlIgnoreCase(prop, "background-size")) {
        const tv = std.mem.trim(u8, val, " \t");
        if (eqlIgnoreCase(tv, "auto auto")) return qjs.JS_NewStringLen(c, "auto", 4);
        // Single value (not keyword) → add 'auto' second value
        if (!eqlIgnoreCase(tv, "auto") and !eqlIgnoreCase(tv, "cover") and !eqlIgnoreCase(tv, "contain") and
            std.mem.indexOf(u8, tv, " ") == null and tv.len > 0)
        {
            var sbuf: [128]u8 = undefined;
            const s = std.fmt.bufPrint(&sbuf, "{s} auto", .{tv}) catch return qjs.JS_NewStringLen(c, val.ptr, val.len);
            return qjs.JS_NewStringLen(c, s.ptr, s.len);
        }
    }
    // background-position-x/y: keywords to %
    if (eqlIgnoreCase(prop, "background-position-x") or eqlIgnoreCase(prop, "background-position-y") or
        eqlIgnoreCase(prop, "background-position"))
    {
        const tv = std.mem.trim(u8, val, " \t");
        if (eqlIgnoreCase(tv, "left") or eqlIgnoreCase(tv, "top")) return qjs.JS_NewStringLen(c, "0%", 2);
        if (eqlIgnoreCase(tv, "center")) return qjs.JS_NewStringLen(c, "50%", 3);
        if (eqlIgnoreCase(tv, "right") or eqlIgnoreCase(tv, "bottom")) return qjs.JS_NewStringLen(c, "100%", 4);
    }
    // font-width/font-stretch: keywords to %
    if (eqlIgnoreCase(prop, "font-width") or eqlIgnoreCase(prop, "font-stretch")) {
        const tv = std.mem.trim(u8, val, " \t");
        if (eqlIgnoreCase(tv, "ultra-condensed")) return qjs.JS_NewStringLen(c, "50%", 3);
        if (eqlIgnoreCase(tv, "extra-condensed")) return qjs.JS_NewStringLen(c, "62.5%", 5);
        if (eqlIgnoreCase(tv, "condensed")) return qjs.JS_NewStringLen(c, "75%", 3);
        if (eqlIgnoreCase(tv, "semi-condensed")) return qjs.JS_NewStringLen(c, "87.5%", 5);
        if (eqlIgnoreCase(tv, "normal")) return qjs.JS_NewStringLen(c, "100%", 4);
        if (eqlIgnoreCase(tv, "semi-expanded")) return qjs.JS_NewStringLen(c, "112.5%", 6);
        if (eqlIgnoreCase(tv, "expanded")) return qjs.JS_NewStringLen(c, "125%", 4);
        if (eqlIgnoreCase(tv, "extra-expanded")) return qjs.JS_NewStringLen(c, "150%", 4);
        if (eqlIgnoreCase(tv, "ultra-expanded")) return qjs.JS_NewStringLen(c, "200%", 4);
    }
    // font-size: absolute keywords to px (based on medium = 16px)
    if (eqlIgnoreCase(prop, "font-size")) {
        const tv = std.mem.trim(u8, val, " \t");
        if (eqlIgnoreCase(tv, "xx-small")) return qjs.JS_NewStringLen(c, "9px", 3);
        if (eqlIgnoreCase(tv, "x-small")) return qjs.JS_NewStringLen(c, "10px", 4);
        if (eqlIgnoreCase(tv, "small")) return qjs.JS_NewStringLen(c, "13px", 4);
        if (eqlIgnoreCase(tv, "medium")) return qjs.JS_NewStringLen(c, "16px", 4);
        if (eqlIgnoreCase(tv, "large")) return qjs.JS_NewStringLen(c, "18px", 4);
        if (eqlIgnoreCase(tv, "x-large")) return qjs.JS_NewStringLen(c, "24px", 4);
        if (eqlIgnoreCase(tv, "xx-large")) return qjs.JS_NewStringLen(c, "32px", 4);
        if (eqlIgnoreCase(tv, "xxx-large")) return qjs.JS_NewStringLen(c, "48px", 4);
        if (eqlIgnoreCase(tv, "smaller")) return qjs.JS_NewStringLen(c, "13px", 4);
        if (eqlIgnoreCase(tv, "larger")) return qjs.JS_NewStringLen(c, "19px", 4);
    }
    // font-weight: keywords to numbers
    if (eqlIgnoreCase(prop, "font-weight")) {
        const tv = std.mem.trim(u8, val, " \t");
        if (eqlIgnoreCase(tv, "normal")) return qjs.JS_NewStringLen(c, "400", 3);
        if (eqlIgnoreCase(tv, "bold")) return qjs.JS_NewStringLen(c, "700", 3);
    }

    // CSS 2.1 §9.7: Blockification — when position or float is set, inline display → block equiv
    if (eqlIgnoreCase(prop, "display")) {
        const elem = getElement(c, elem_val);
        if (elem) |el| {
            var style_len: usize = 0;
            const style_ptr = lxb_dom_element_get_attribute(el, "style", 5, &style_len);
            if (style_ptr != null and style_len > 0) {
                const istyle = style_ptr.?[0..style_len];
                const pos_val = getStyleProperty(istyle, "position");
                const float_val = getStyleProperty(istyle, "float");
                const needs_blockify = blk: {
                    if (pos_val) |p| {
                        const pt = std.mem.trim(u8, p, " ");
                        if (eqlIgnoreCase(pt, "absolute") or eqlIgnoreCase(pt, "fixed")) break :blk true;
                    }
                    if (float_val) |f| {
                        const ft = std.mem.trim(u8, f, " ");
                        if (eqlIgnoreCase(ft, "left") or eqlIgnoreCase(ft, "right")) break :blk true;
                    }
                    break :blk false;
                };
                if (needs_blockify) {
                    const tv = std.mem.trim(u8, val, " \t\r\n");
                    // CSS Display L3 §2.7: Blockification rules
                    const blockified: ?[]const u8 = if (eqlIgnoreCase(tv, "inline")) "block"
                    else if (eqlIgnoreCase(tv, "inline-block")) "block"
                    else if (eqlIgnoreCase(tv, "inline-table")) "table"
                    else if (eqlIgnoreCase(tv, "inline-flex")) "flex"
                    else if (eqlIgnoreCase(tv, "inline-grid")) "grid"
                    // Internal table display types blockify to "block"
                    else if (eqlIgnoreCase(tv, "table-row-group")) "block"
                    else if (eqlIgnoreCase(tv, "table-header-group")) "block"
                    else if (eqlIgnoreCase(tv, "table-footer-group")) "block"
                    else if (eqlIgnoreCase(tv, "table-row")) "block"
                    else if (eqlIgnoreCase(tv, "table-cell")) "block"
                    else if (eqlIgnoreCase(tv, "table-column")) "block"
                    else if (eqlIgnoreCase(tv, "table-column-group")) "block"
                    else if (eqlIgnoreCase(tv, "table-caption")) "block"
                    // Ruby internal display types blockify to "block"
                    else if (eqlIgnoreCase(tv, "ruby-base")) "block"
                    else if (eqlIgnoreCase(tv, "ruby-text")) "block"
                    else if (eqlIgnoreCase(tv, "ruby-base-container")) "block"
                    else if (eqlIgnoreCase(tv, "ruby-text-container")) "block"
                    else null;
                    if (blockified) |b| return qjs.JS_NewStringLen(c, b.ptr, b.len);
                }
            }
        }
        return qjs.JS_NewStringLen(c, val.ptr, val.len);
    }

    // Resolve opacity to clamped [0,1] numeric value
    if (eqlIgnoreCase(prop, "opacity")) {
        const trimmed_opacity = std.mem.trim(u8, val, " \t\r\n");
        var opacity_val: ?f64 = null;
        // Try math functions first (calc, clamp, min, max)
        if (isCssMathFunc(trimmed_opacity)) {
            // For opacity, 100% = 1.0, so use pct_base = 1.0 (value * 1.0 / 100 = value/100)
            const font_size = getElementFontSizeFromStyle(c, elem_val);
            if (cascade_mod.resolveValueToPx(trimmed_opacity, font_size, api.g_viewport_width, api.g_viewport_height, 1.0)) |v| {
                opacity_val = @floatCast(v);
            }
        } else if (trimmed_opacity.len > 0 and trimmed_opacity[trimmed_opacity.len - 1] == '%') {
            opacity_val = (std.fmt.parseFloat(f64, trimmed_opacity[0 .. trimmed_opacity.len - 1]) catch null);
            if (opacity_val) |*v| v.* /= 100.0;
        } else {
            opacity_val = std.fmt.parseFloat(f64, trimmed_opacity) catch null;
        }
        if (opacity_val) |v| {
            const clamped = @max(0.0, @min(1.0, v));
            // Round to 6 significant digits to avoid f32 precision artifacts
            const rounded = @round(clamped * 1000000.0) / 1000000.0;
            var obuf: [32]u8 = undefined;
            const os = std.fmt.bufPrint(&obuf, "{d}", .{rounded}) catch return qjs.JS_NewStringLen(c, val.ptr, val.len);
            return qjs.JS_NewStringLen(c, os.ptr, os.len);
        }
    }

    // Resolve color values to rgb()/rgba() form for computed style
    if (isColorProperty(prop)) {
        const color_mod = @import("../css/properties.zig");
        const trimmed_color = std.mem.trim(u8, val, " \t\r\n");
        // currentcolor resolves to inherited color
        if (eqlIgnoreCase(trimmed_color, "currentcolor")) {
            return getInheritedComputedValue(c, elem_val, "color");
        }
        // CSS Color 4: color() function keeps color() serialization
        if (eqlIgnoreCase(trimmed_color[0..@min(6, trimmed_color.len)], "color(")) {
            return formatColorFuncComputed(c, trimmed_color);
        }
        // CSS Color 4: oklab/oklch/lab/lch keep their serialization in computed style
        if (eqlIgnoreCase(trimmed_color[0..@min(6, trimmed_color.len)], "oklab(") or
            eqlIgnoreCase(trimmed_color[0..@min(6, trimmed_color.len)], "oklch(") or
            eqlIgnoreCase(trimmed_color[0..@min(4, trimmed_color.len)], "lab(") or
            eqlIgnoreCase(trimmed_color[0..@min(4, trimmed_color.len)], "lch("))
        {
            return formatModernColorComputed(c, trimmed_color);
        }
        // CSS Color 5: color-mix() serializes as color(srgb ...) in computed style
        if (trimmed_color.len >= 10 and eqlIgnoreCase(trimmed_color[0..10], "color-mix(")) {
            if (color_mod.parseColor(trimmed_color)) |color| {
                return formatAsColorSrgb(c, color);
            }
        }
        if (color_mod.parseColor(trimmed_color)) |color| {
            var color_buf: [64]u8 = undefined;
            if (color.a == 255) {
                const s = std.fmt.bufPrint(&color_buf, "rgb({d}, {d}, {d})", .{ color.r, color.g, color.b }) catch return qjs.JS_NewStringLen(c, val.ptr, val.len);
                return qjs.JS_NewStringLen(c, s.ptr, s.len);
            } else if (color.a == 0) {
                const s = std.fmt.bufPrint(&color_buf, "rgba({d}, {d}, {d}, 0)", .{ color.r, color.g, color.b }) catch return qjs.JS_NewStringLen(c, val.ptr, val.len);
                return qjs.JS_NewStringLen(c, s.ptr, s.len);
            } else {
                // Try to preserve original alpha precision from the CSS value
                const orig_alpha = extractOriginalAlpha(trimmed_color);
                var alpha_buf: [16]u8 = undefined;
                const alpha_s = if (orig_alpha) |a|
                    std.fmt.bufPrint(&alpha_buf, "{d}", .{a}) catch "0"
                else blk: {
                    const a = @as(f32, @floatFromInt(color.a)) / 255.0;
                    break :blk std.fmt.bufPrint(&alpha_buf, "{d}", .{a}) catch "0";
                };
                const s = std.fmt.bufPrint(&color_buf, "rgba({d}, {d}, {d}, {s})", .{ color.r, color.g, color.b, alpha_s }) catch return qjs.JS_NewStringLen(c, val.ptr, val.len);
                return qjs.JS_NewStringLen(c, s.ptr, s.len);
            }
        }
    }

    // Resolve var() references before further processing
    if (std.mem.indexOf(u8, val, "var(") != null) {
        const resolved = resolveVarFromElement(c, elem_val, val);
        if (resolved) |rv| {
            // Recursively process the resolved value
            return resolveInlineForComputed(c, prop, rv, elem_val);
        }
    }

    const trimmed = std.mem.trim(u8, val, " \t\r\n");

    // Keywords that should not be resolved to px
    if (trimmed.len == 0 or
        eqlIgnoreCase(trimmed, "auto") or eqlIgnoreCase(trimmed, "none") or
        eqlIgnoreCase(trimmed, "normal") or eqlIgnoreCase(trimmed, "medium") or
        eqlIgnoreCase(trimmed, "thin") or eqlIgnoreCase(trimmed, "thick") or
        eqlIgnoreCase(trimmed, "min-content") or eqlIgnoreCase(trimmed, "max-content") or
        eqlIgnoreCase(trimmed, "fit-content") or eqlIgnoreCase(trimmed, "contents"))
    {
        return qjs.JS_NewStringLen(c, val.ptr, val.len);
    }

    // Integer properties: reading-order, order, z-index — resolve math functions to integer
    if (eqlIgnoreCase(prop, "reading-order") or eqlIgnoreCase(prop, "order") or eqlIgnoreCase(prop, "z-index")) {
        if (isCssMathFunc(trimmed)) {
            const font_size = getElementFontSizeFromStyle(c, elem_val);
            if (cascade_mod.resolveValueToPx(trimmed, font_size, api.g_viewport_width, api.g_viewport_height, 0)) |v| {
                var buf: [64]u8 = undefined;
                const int_val: i32 = @intFromFloat(@round(v));
                const result = std.fmt.bufPrint(&buf, "{d}", .{int_val}) catch return qjs.JS_NewStringLen(c, "0", 1);
                return qjs.JS_NewStringLen(c, result.ptr, result.len);
            }
        }
        return qjs.JS_NewStringLen(c, val.ptr, val.len);
    }

    // Number/length dual properties: tab-size — can be a number or length
    if (eqlIgnoreCase(prop, "tab-size")) {
        if (isCssMathFunc(trimmed)) {
            const font_size = getElementFontSizeFromStyle(c, elem_val);
            if (cascade_mod.resolveValueToPx(trimmed, font_size, api.g_viewport_width, api.g_viewport_height, 0)) |v| {
                var buf: [128]u8 = undefined;
                // Check if result should be px or number by looking at the input
                const has_unit = std.mem.indexOf(u8, trimmed, "px") != null or
                    std.mem.indexOf(u8, trimmed, "em") != null;
                if (has_unit) {
                    return fmtPx(c, v, &buf);
                }
                // Format as number (integer if whole)
                const iv: i32 = @intFromFloat(@round(v));
                const result = if (@abs(v - @as(f32, @floatFromInt(iv))) < 0.0001)
                    std.fmt.bufPrint(&buf, "{d}", .{iv}) catch return qjs.JS_NewStringLen(c, "0", 1)
                else
                    std.fmt.bufPrint(&buf, "{d}", .{v}) catch return qjs.JS_NewStringLen(c, "0", 1);
                return qjs.JS_NewStringLen(c, result.ptr, result.len);
            }
        }
        return qjs.JS_NewStringLen(c, val.ptr, val.len);
    }

    // Number properties: scale, opacity etc. — resolve math functions to number
    if (eqlIgnoreCase(prop, "scale")) {
        if (isCssMathFunc(trimmed)) {
            const font_size = getElementFontSizeFromStyle(c, elem_val);
            if (cascade_mod.resolveValueToPx(trimmed, font_size, api.g_viewport_width, api.g_viewport_height, 0)) |v| {
                var buf: [64]u8 = undefined;
                // Format as integer if whole, otherwise as float
                const iv: i32 = @intFromFloat(@round(v));
                const result = if (@abs(v - @as(f32, @floatFromInt(iv))) < 0.0001)
                    std.fmt.bufPrint(&buf, "{d}", .{iv}) catch return qjs.JS_NewStringLen(c, "0", 1)
                else
                    std.fmt.bufPrint(&buf, "{d}", .{v}) catch return qjs.JS_NewStringLen(c, "0", 1);
                return qjs.JS_NewStringLen(c, result.ptr, result.len);
            }
        }
        return qjs.JS_NewStringLen(c, val.ptr, val.len);
    }

    // Angle properties: rotate, transition-delay (resolved to deg)
    if (eqlIgnoreCase(prop, "rotate")) {
        if (isCssMathFunc(trimmed)) {
            const font_size = getElementFontSizeFromStyle(c, elem_val);
            if (cascade_mod.resolveValueToPx(trimmed, font_size, api.g_viewport_width, api.g_viewport_height, 0)) |v| {
                var buf: [64]u8 = undefined;
                // Format as integer if whole, otherwise float, with deg suffix
                const iv: i32 = @intFromFloat(@round(v));
                const result = if (@abs(v - @as(f32, @floatFromInt(iv))) < 0.0001)
                    std.fmt.bufPrint(&buf, "{d}deg", .{iv}) catch return qjs.JS_NewStringLen(c, "0deg", 4)
                else
                    std.fmt.bufPrint(&buf, "{d}deg", .{v}) catch return qjs.JS_NewStringLen(c, "0deg", 4);
                return qjs.JS_NewStringLen(c, result.ptr, result.len);
            }
        }
        return qjs.JS_NewStringLen(c, val.ptr, val.len);
    }

    // Time properties: transition-delay
    if (eqlIgnoreCase(prop, "transition-delay")) {
        if (isCssMathFunc(trimmed)) {
            const font_size = getElementFontSizeFromStyle(c, elem_val);
            if (cascade_mod.resolveValueToPx(trimmed, font_size, api.g_viewport_width, api.g_viewport_height, 0)) |v| {
                var buf: [64]u8 = undefined;
                const result = std.fmt.bufPrint(&buf, "{d}s", .{v}) catch return qjs.JS_NewStringLen(c, "0s", 2);
                return qjs.JS_NewStringLen(c, result.ptr, result.len);
            }
        }
        return qjs.JS_NewStringLen(c, val.ptr, val.len);
    }

    // Shorthand margin/padding: resolve each value individually
    if (eqlIgnoreCase(prop, "margin") or eqlIgnoreCase(prop, "padding")) {
        return resolveBoxShorthandForComputed(c, trimmed, elem_val);
    }

    // Only resolve length-type properties
    if (!isComputedLengthProperty(prop)) {
        return qjs.JS_NewStringLen(c, val.ptr, val.len);
    }

    // Get resolution context from computed style and layout tree
    const font_size = getElementFontSizeFromStyle(c, elem_val);
    // height/top/bottom use containing block height for %, everything else uses width
    // (CSS spec: margin/padding % always resolve against containing block WIDTH, even vertical)
    const pct_base = if (eqlIgnoreCase(prop, "height") or eqlIgnoreCase(prop, "min-height") or
        eqlIgnoreCase(prop, "max-height") or eqlIgnoreCase(prop, "top") or eqlIgnoreCase(prop, "bottom"))
        getContainingBlockHeight(c, elem_val)
    else
        getContainingBlockWidth(c, elem_val);

    if (cascade_mod.resolveValueToPx(trimmed, font_size, api.g_viewport_width, api.g_viewport_height, pct_base)) |px| {
        var buf: [128]u8 = undefined;
        // CSS Values 4 §10.11: NaN → 0, ±Infinity → clamped to allowable range
        const clamped = if (std.math.isNan(px)) 0.0 else if (std.math.isInf(px)) @as(f32, 3.4028235e+38) else px;
        return fmtPx(c, clamped, &buf);
    }

    // Check if value contains NaN/infinity keywords and resolve to 0px
    if (containsNanOrInfinity(trimmed)) {
        return qjs.JS_NewStringLen(c, "0px", 3);
    }

    // Fallback: return as-is
    return qjs.JS_NewStringLen(c, val.ptr, val.len);
}

// ── Variable Resolution ────────────────────────────────────────────

/// Resolve var() references for an element by building a custom property map
/// from inline styles of the element and its ancestors.
pub fn resolveVarFromElement(c: *qjs.JSContext, elem_val: qjs.JSValue, val: []const u8) ?[]const u8 {
    const variables_mod = @import("../css/variables.zig");

    // Build a simple var map from inline styles (element + ancestors)
    var var_map = variables_mod.VarMap.init(std.heap.c_allocator);
    defer var_map.deinit();

    // Walk up the DOM tree to collect custom properties
    var current = elem_val;
    var depth: usize = 0;
    while (depth < 20) : (depth += 1) {
        const el = getElement(c, current);
        if (el) |e| {
            var slen: usize = 0;
            const sptr = lxb_dom_element_get_attribute(e, "style", 5, &slen);
            if (sptr != null and slen > 0) {
                const istyle = sptr.?[0..slen];
                // Extract --custom-property definitions
                extractCustomProps(istyle, &var_map);
            }
        }
        // Move to parent element
        const parent = qjs.JS_GetPropertyStr(c, current, "parentElement");
        if (quickjs.JS_IsNull(parent) or quickjs.JS_IsUndefined(parent)) {
            qjs.JS_FreeValue(c, parent);
            break;
        }
        if (depth > 0) qjs.JS_FreeValue(c, current);
        current = parent;
    }
    if (depth > 0) qjs.JS_FreeValue(c, current);

    // Always try resolving — even with empty map, fallback values in var() need processing
    return variables_mod.resolveVarRefs(val, &var_map, std.heap.c_allocator);
}

/// Extract --custom-property definitions from an inline style string.
pub fn extractCustomProps(style: []const u8, var_map: anytype) void {
    var pos: usize = 0;
    while (pos < style.len) {
        // Find next property start
        while (pos < style.len and (style[pos] == ' ' or style[pos] == ';' or style[pos] == '\t' or style[pos] == '\n')) pos += 1;
        if (pos + 2 >= style.len) break;
        if (style[pos] == '-' and style[pos + 1] == '-') {
            // Custom property
            const name_start = pos;
            while (pos < style.len and style[pos] != ':' and style[pos] != ';') pos += 1;
            if (pos >= style.len or style[pos] != ':') continue;
            const name = std.mem.trim(u8, style[name_start..pos], " \t");
            pos += 1; // skip ':'
            const val_start = pos;
            while (pos < style.len and style[pos] != ';') pos += 1;
            const value = std.mem.trim(u8, style[val_start..pos], " \t");
            var_map.set(name, value) catch {};
        } else {
            // Skip to next semicolon
            while (pos < style.len and style[pos] != ';') pos += 1;
            if (pos < style.len) pos += 1;
        }
    }
}

/// Extract the original alpha value from a CSS color string like "rgba(2, 3, 4, 0.5)"
pub fn extractOriginalAlpha(color_str: []const u8) ?f64 {
    // Find alpha separator: last comma (legacy) or '/' (modern) at depth 1
    var last_comma: ?usize = null;
    var slash_pos: ?usize = null;
    var depth: usize = 0;
    for (color_str, 0..) |ch, i| {
        if (ch == '(') depth += 1
        else if (ch == ')') { if (depth > 0) depth -= 1; }
        else if (depth == 1) {
            if (ch == ',') last_comma = i;
            if (ch == '/') slash_pos = i;
        }
    }
    // Modern syntax: use '/' separator
    const sep_pos = slash_pos orelse last_comma orelse return null;
    // For comma syntax, we need at least 3 commas for rgba (4 args) — check if this is actually the alpha separator
    if (slash_pos == null) {
        // Count commas to ensure 4th arg exists (alpha)
        var comma_count: usize = 0;
        for (color_str) |ch| {
            if (ch == ',') comma_count += 1;
        }
        if (comma_count < 3) return null; // Only 3 args, no alpha
    }
    var end = color_str.len;
    while (end > 0 and (color_str[end - 1] == ')' or color_str[end - 1] == ' ')) end -= 1;
    const alpha_str = std.mem.trim(u8, color_str[sep_pos + 1 .. end], " ");
    if (alpha_str.len == 0) return null;
    if (alpha_str[alpha_str.len - 1] == '%') {
        // Percentage: 50% → 0.5
        const pct = std.fmt.parseFloat(f64, alpha_str[0 .. alpha_str.len - 1]) catch return null;
        return pct / 100.0;
    }
    return std.fmt.parseFloat(f64, alpha_str) catch null;
}

// ── Color Formatting ───────────────────────────────────────────────

/// Format a parsed Color as color(srgb R G B) or color(srgb R G B / A).
/// Used for CSS Color 5 color-mix() computed values.
fn formatAsColorSrgb(c: *qjs.JSContext, color: @import("../css/values.zig").Color) qjs.JSValue {
    var buf: [128]u8 = undefined;
    const r = @as(f64, @floatFromInt(color.r)) / 255.0;
    const g_val = @as(f64, @floatFromInt(color.g)) / 255.0;
    const b_val = @as(f64, @floatFromInt(color.b)) / 255.0;
    if (color.a == 255) {
        const s = std.fmt.bufPrint(&buf, "color(srgb {d:.6} {d:.6} {d:.6})", .{ r, g_val, b_val }) catch return qjs.JS_NewStringLen(c, "", 0);
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (color.a == 0) {
        const s = std.fmt.bufPrint(&buf, "color(srgb {d:.6} {d:.6} {d:.6} / 0)", .{ r, g_val, b_val }) catch return qjs.JS_NewStringLen(c, "", 0);
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else {
        const a = @as(f64, @floatFromInt(color.a)) / 255.0;
        const s = std.fmt.bufPrint(&buf, "color(srgb {d:.6} {d:.6} {d:.6} / {d:.6})", .{ r, g_val, b_val, a }) catch return qjs.JS_NewStringLen(c, "", 0);
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    }
}

/// Format color() function for computed value: color(srgb R G B) or color(srgb R G B / A)
pub fn formatColorFuncComputed(c: *qjs.JSContext, input: []const u8) qjs.JSValue {
    const color_mod = @import("../css/properties.zig");
    const inner = color_mod.extractFuncArgs(input) orelse return qjs.JS_NewStringLen(c, input.ptr, input.len);

    var iter = std.mem.tokenizeAny(u8, inner, " \t/,");
    const space = iter.next() orelse return qjs.JS_NewStringLen(c, input.ptr, input.len);

    var vals: [4]f32 = .{ 0, 0, 0, 1 };
    var count: usize = 0;
    while (iter.next()) |tok| {
        if (count >= 4) break;
        vals[count] = color_mod.parseColorComponent(tok, 1.0) orelse return qjs.JS_NewStringLen(c, input.ptr, input.len);
        count += 1;
    }
    if (count < 3) return qjs.JS_NewStringLen(c, input.ptr, input.len);

    var buf: [128]u8 = undefined;
    const result = if (count >= 4 and vals[3] < 1.0)
        std.fmt.bufPrint(&buf, "color({s} {d} {d} {d} / {d})", .{ space, vals[0], vals[1], vals[2], vals[3] }) catch return qjs.JS_NewStringLen(c, input.ptr, input.len)
    else
        std.fmt.bufPrint(&buf, "color({s} {d} {d} {d})", .{ space, vals[0], vals[1], vals[2] }) catch return qjs.JS_NewStringLen(c, input.ptr, input.len);
    return qjs.JS_NewStringLen(c, result.ptr, result.len);
}

/// Format modern color functions (oklab/oklch/lab/lch) for computed value
pub fn formatModernColorComputed(c: *qjs.JSContext, input: []const u8) qjs.JSValue {
    // For now, return as-is (proper serialization requires complex normalization)
    return qjs.JS_NewStringLen(c, input.ptr, input.len);
}

// ── CSS Helper Functions ───────────────────────────────────────────

/// Check if a CSS property takes a color value.
pub fn isColorProperty(prop: []const u8) bool {
    return eqlIgnoreCase(prop, "color") or
        eqlIgnoreCase(prop, "background-color") or
        eqlIgnoreCase(prop, "border-color") or
        eqlIgnoreCase(prop, "border-top-color") or
        eqlIgnoreCase(prop, "border-right-color") or
        eqlIgnoreCase(prop, "border-bottom-color") or
        eqlIgnoreCase(prop, "border-left-color") or
        eqlIgnoreCase(prop, "outline-color") or
        eqlIgnoreCase(prop, "text-decoration-color") or
        eqlIgnoreCase(prop, "caret-color") or
        eqlIgnoreCase(prop, "column-rule-color");
}

/// Check if a CSS value string contains NaN or infinity keywords.
/// Check if value starts with a CSS math function that should be resolved.
pub fn isCssMathFunc(s: []const u8) bool {
    if (s.len < 4) return false;
    return (s.len >= 5 and eqlIgnoreCase(s[0..5], "calc(")) or
        (eqlIgnoreCase(s[0..4], "min(")) or
        (eqlIgnoreCase(s[0..4], "max(")) or
        (s.len >= 6 and eqlIgnoreCase(s[0..6], "clamp(")) or
        (s.len >= 6 and eqlIgnoreCase(s[0..6], "round(")) or
        (eqlIgnoreCase(s[0..4], "mod(")) or
        (eqlIgnoreCase(s[0..4], "rem(")) or
        (eqlIgnoreCase(s[0..4], "abs(")) or
        (s.len >= 5 and eqlIgnoreCase(s[0..5], "sign(")) or
        (eqlIgnoreCase(s[0..4], "sin(")) or
        (eqlIgnoreCase(s[0..4], "cos(")) or
        (eqlIgnoreCase(s[0..4], "tan(")) or
        (s.len >= 5 and eqlIgnoreCase(s[0..5], "asin(")) or
        (s.len >= 5 and eqlIgnoreCase(s[0..5], "acos(")) or
        (s.len >= 5 and eqlIgnoreCase(s[0..5], "atan(")) or
        (s.len >= 6 and eqlIgnoreCase(s[0..6], "atan2(")) or
        (s.len >= 5 and eqlIgnoreCase(s[0..5], "sqrt(")) or
        (eqlIgnoreCase(s[0..4], "pow(")) or
        (s.len >= 6 and eqlIgnoreCase(s[0..6], "hypot(")) or
        (eqlIgnoreCase(s[0..4], "log(")) or
        (eqlIgnoreCase(s[0..4], "exp("));
}

pub fn containsNanOrInfinity(s: []const u8) bool {
    var i: usize = 0;
    while (i + 3 <= s.len) : (i += 1) {
        if (eqlIgnoreCase(s[i..][0..3], "NaN")) return true;
        if (i + 8 <= s.len and eqlIgnoreCase(s[i..][0..8], "infinity")) return true;
    }
    return false;
}

/// Check if a CSS property's computed value should be resolved to px.
pub fn isComputedLengthProperty(prop: []const u8) bool {
    // Box model
    if (eqlIgnoreCase(prop, "margin-top") or eqlIgnoreCase(prop, "margin-right") or
        eqlIgnoreCase(prop, "margin-bottom") or eqlIgnoreCase(prop, "margin-left")) return true;
    if (eqlIgnoreCase(prop, "padding-top") or eqlIgnoreCase(prop, "padding-right") or
        eqlIgnoreCase(prop, "padding-bottom") or eqlIgnoreCase(prop, "padding-left")) return true;
    if (eqlIgnoreCase(prop, "border-top-width") or eqlIgnoreCase(prop, "border-right-width") or
        eqlIgnoreCase(prop, "border-bottom-width") or eqlIgnoreCase(prop, "border-left-width")) return true;
    // Dimensions
    if (eqlIgnoreCase(prop, "width") or eqlIgnoreCase(prop, "height") or
        eqlIgnoreCase(prop, "min-width") or eqlIgnoreCase(prop, "min-height") or
        eqlIgnoreCase(prop, "max-width") or eqlIgnoreCase(prop, "max-height")) return true;
    // Offsets
    if (eqlIgnoreCase(prop, "top") or eqlIgnoreCase(prop, "right") or
        eqlIgnoreCase(prop, "bottom") or eqlIgnoreCase(prop, "left")) return true;
    // Text
    if (eqlIgnoreCase(prop, "text-indent") or eqlIgnoreCase(prop, "letter-spacing") or
        eqlIgnoreCase(prop, "word-spacing")) return true;
    // Font/line
    if (eqlIgnoreCase(prop, "font-size") or eqlIgnoreCase(prop, "line-height")) return true;
    return false;
}

/// Get the element's computed font-size from the global style map.
pub fn getElementFontSizeFromStyle(c: *qjs.JSContext, elem_val: qjs.JSValue) f32 {
    const node = getNode(c, elem_val);
    if (node != null and api.getStylesForCtx(c) != null) {
        if (api.getStylesForCtx(c).?.get(@intFromPtr(node.?))) |style| {
            return style.font_size_px;
        }
    }
    return 16.0; // default
}

/// Get containing block width from the layout tree.
/// For abs-pos elements, walks up to find nearest positioned ancestor (CSS spec).
pub fn getContainingBlockWidth(c: *qjs.JSContext, elem_val: qjs.JSValue) f32 {
    const root = api.getRootBox(c) orelse return api.g_viewport_width;
    const lxb_node: *lxb.lxb_dom_node_t = getNode(c, elem_val) orelse return api.g_viewport_width;
    const box = api.findBoxForNode(root, lxb_node) orelse return api.g_viewport_width;

    // For absolute/fixed: containing block = nearest positioned ancestor's padding box
    if (box.style.position == .absolute or box.style.position == .fixed) {
        var ancestor = box.parent;
        while (ancestor) |a| {
            // Non-static position or root element forms a containing block
            if (a.style.position != .static_ or a.parent == null) {
                return a.content.width + a.padding.left + a.padding.right;
            }
            ancestor = a.parent;
        }
        return api.g_viewport_width;
    }

    if (box.parent) |parent| return parent.content.width;
    return api.g_viewport_width;
}

/// Get containing block height from the layout tree.
pub fn getContainingBlockHeight(c: *qjs.JSContext, elem_val: qjs.JSValue) f32 {
    const root = api.getRootBox(c) orelse return api.g_viewport_height;
    const lxb_node: *lxb.lxb_dom_node_t = getNode(c, elem_val) orelse return api.g_viewport_height;
    const box = api.findBoxForNode(root, lxb_node) orelse return api.g_viewport_height;

    if (box.style.position == .absolute or box.style.position == .fixed) {
        var ancestor = box.parent;
        while (ancestor) |a| {
            if (a.style.position != .static_ or a.parent == null) {
                return a.content.height + a.padding.top + a.padding.bottom;
            }
            ancestor = a.parent;
        }
        return api.g_viewport_height;
    }

    if (box.parent) |parent| return parent.content.height;
    return api.g_viewport_height;
}

/// Resolve a margin/padding shorthand value (1-4 values) to computed px form.
pub fn resolveBoxShorthandForComputed(c: *qjs.JSContext, val: []const u8, elem_val: qjs.JSValue) qjs.JSValue {
    const font_size = getElementFontSizeFromStyle(c, elem_val);
    const cb_width = getContainingBlockWidth(c, elem_val);

    // Split into 1-4 values (space-separated, respecting calc() parens)
    var parts: [4][]const u8 = .{ "", "", "", "" };
    var part_count: usize = 0;
    var pos: usize = 0;
    var paren_depth: usize = 0;
    var start: usize = 0;
    while (pos <= val.len) {
        if (pos < val.len) {
            if (val[pos] == '(') { paren_depth += 1; pos += 1; continue; }
            if (val[pos] == ')') { if (paren_depth > 0) paren_depth -= 1; pos += 1; continue; }
            if (val[pos] != ' ' and val[pos] != '\t') { pos += 1; continue; }
            if (paren_depth > 0) { pos += 1; continue; }
        }
        // End of token
        if (pos > start) {
            const token = std.mem.trim(u8, val[start..pos], " \t");
            if (token.len > 0 and part_count < 4) {
                parts[part_count] = token;
                part_count += 1;
            }
        }
        pos += 1;
        start = pos;
    }

    if (part_count == 0) return qjs.JS_NewStringLen(c, val.ptr, val.len);

    // Resolve each value to px
    var resolved: [4]f32 = .{ 0, 0, 0, 0 };
    var all_resolved = true;
    for (0..part_count) |i| {
        if (cascade_mod.resolveValueToPx(parts[i], font_size, api.g_viewport_width, api.g_viewport_height, cb_width)) |px| {
            resolved[i] = px;
        } else {
            all_resolved = false;
            break;
        }
    }

    if (!all_resolved) return qjs.JS_NewStringLen(c, val.ptr, val.len);

    // Expand 1-4 values to 4 (CSS shorthand rules)
    const top = resolved[0];
    const right = if (part_count >= 2) resolved[1] else resolved[0];
    const bottom = if (part_count >= 3) resolved[2] else resolved[0];
    const left_ = if (part_count >= 4) resolved[3] else right;

    var buf: [128]u8 = undefined;
    return fmtBoxShorthand(c, top, right, bottom, left_, &buf);
}

/// Canonicalize a margin-trim inline value for getComputedStyle (block before inline).
pub fn canonicalizeMarginTrimForComputed(c: *qjs.JSContext, val: []const u8) qjs.JSValue {
    var mt = computed_mod.MarginTrim{};
    var pos: usize = 0;
    while (pos < val.len) {
        while (pos < val.len and (val[pos] == ' ' or val[pos] == '\t')) pos += 1;
        if (pos >= val.len) break;
        const start = pos;
        while (pos < val.len and val[pos] != ' ' and val[pos] != '\t') pos += 1;
        const kw = val[start..pos];
        if (eqlIgnoreCase(kw, "block-start") or eqlIgnoreCase(kw, "block")) mt.block_start = true;
        if (eqlIgnoreCase(kw, "block-end") or eqlIgnoreCase(kw, "block")) mt.block_end = true;
        if (eqlIgnoreCase(kw, "inline-start") or eqlIgnoreCase(kw, "inline")) mt.inline_start = true;
        if (eqlIgnoreCase(kw, "inline-end") or eqlIgnoreCase(kw, "inline")) mt.inline_end = true;
    }
    return fmtMarginTrim(c, mt);
}

/// Format a CSS shorthand box value (margin/padding) as "top right bottom left".
pub fn fmtBoxShorthand(c: *qjs.JSContext, top: f32, right: f32, bottom: f32, left: f32, buf: *[128]u8) qjs.JSValue {
    if (top == right and right == bottom and bottom == left) {
        return fmtPx(c, top, buf);
    } else if (top == bottom and right == left) {
        const result = std.fmt.bufPrint(buf, "{d}px {d}px", .{ top, right }) catch return qjs.JS_NewStringLen(c, "0px", 3);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    } else if (right == left) {
        const result = std.fmt.bufPrint(buf, "{d}px {d}px {d}px", .{ top, right, bottom }) catch return qjs.JS_NewStringLen(c, "0px", 3);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    } else {
        const result = std.fmt.bufPrint(buf, "{d}px {d}px {d}px {d}px", .{ top, right, bottom, left }) catch return qjs.JS_NewStringLen(c, "0px", 3);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    }
}

/// Format a Dimension value.
pub fn dimensionToString(c: *qjs.JSContext, dim: ComputedStyle.Dimension, buf: *[128]u8) qjs.JSValue {
    return switch (dim) {
        .auto => qjs.JS_NewStringLen(c, "auto", 4),
        .none => qjs.JS_NewStringLen(c, "none", 4),
        .px => |v| fmtPx(c, v, buf),
        .percent => |v| blk: {
            const pct = std.fmt.bufPrint(buf, "{d}%", .{v}) catch break :blk qjs.JS_NewStringLen(c, "0%", 2);
            break :blk qjs.JS_NewStringLen(c, pct.ptr, pct.len);
        },
        .min_content => qjs.JS_NewStringLen(c, "min-content", 11),
        .max_content => qjs.JS_NewStringLen(c, "max-content", 11),
        .fit_content => qjs.JS_NewStringLen(c, "fit-content", 11),
    };
}

/// Format Overflow enum.
pub fn overflowToString(c: *qjs.JSContext, overflow: ComputedStyle.Overflow) qjs.JSValue {
    const s = switch (overflow) {
        .visible => "visible",
        .hidden => "hidden",
        .scroll => "scroll",
        .auto_ => "auto",
    };
    return qjs.JS_NewStringLen(c, s.ptr, s.len);
}

// ── CSS-wide Keyword Resolution (initial/inherit/unset) ────────────

// ── CSS-wide Keyword Resolution (initial/inherit/unset) ─────────────

/// Return the CSS initial value for a property (computed form).
pub fn cssInitialValue(c: *qjs.JSContext, prop: []const u8) qjs.JSValue {
    // Margin/padding/border-width initial = 0
    if (eqlIgnoreCase(prop, "margin-top") or eqlIgnoreCase(prop, "margin-right") or
        eqlIgnoreCase(prop, "margin-bottom") or eqlIgnoreCase(prop, "margin-left") or
        eqlIgnoreCase(prop, "padding-top") or eqlIgnoreCase(prop, "padding-right") or
        eqlIgnoreCase(prop, "padding-bottom") or eqlIgnoreCase(prop, "padding-left") or
        eqlIgnoreCase(prop, "border-top-width") or eqlIgnoreCase(prop, "border-right-width") or
        eqlIgnoreCase(prop, "border-bottom-width") or eqlIgnoreCase(prop, "border-left-width") or
        eqlIgnoreCase(prop, "text-indent"))
    {
        return qjs.JS_NewStringLen(c, "0px", 3);
    }
    // Dimensions + offsets initial = auto
    if (eqlIgnoreCase(prop, "width") or eqlIgnoreCase(prop, "height") or
        eqlIgnoreCase(prop, "min-width") or eqlIgnoreCase(prop, "min-height") or
        eqlIgnoreCase(prop, "max-width") or eqlIgnoreCase(prop, "max-height") or
        eqlIgnoreCase(prop, "z-index") or
        eqlIgnoreCase(prop, "top") or eqlIgnoreCase(prop, "right") or
        eqlIgnoreCase(prop, "bottom") or eqlIgnoreCase(prop, "left"))
    {
        return qjs.JS_NewStringLen(c, "auto", 4);
    }
    if (eqlIgnoreCase(prop, "display")) return qjs.JS_NewStringLen(c, "inline", 6);
    if (eqlIgnoreCase(prop, "position")) return qjs.JS_NewStringLen(c, "static", 6);
    if (eqlIgnoreCase(prop, "visibility")) return qjs.JS_NewStringLen(c, "visible", 7);
    if (eqlIgnoreCase(prop, "float")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "clear")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "margin-trim")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "overflow-x") or eqlIgnoreCase(prop, "overflow-y"))
        return qjs.JS_NewStringLen(c, "visible", 7);
    if (eqlIgnoreCase(prop, "opacity")) return qjs.JS_NewStringLen(c, "1", 1);
    if (eqlIgnoreCase(prop, "font-size")) return qjs.JS_NewStringLen(c, "16px", 4);
    if (eqlIgnoreCase(prop, "font-weight")) return qjs.JS_NewStringLen(c, "400", 3);
    if (eqlIgnoreCase(prop, "font-style")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "font-family")) return qjs.JS_NewStringLen(c, "sans-serif", 10);
    if (eqlIgnoreCase(prop, "text-align")) return qjs.JS_NewStringLen(c, "start", 5);
    if (eqlIgnoreCase(prop, "text-transform")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "text-decoration")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "text-overflow")) return qjs.JS_NewStringLen(c, "clip", 4);
    if (eqlIgnoreCase(prop, "line-height")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "vertical-align")) return qjs.JS_NewStringLen(c, "baseline", 8);
    if (eqlIgnoreCase(prop, "letter-spacing") or eqlIgnoreCase(prop, "word-spacing"))
        return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "word-break")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "line-break")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "overflow-wrap") or eqlIgnoreCase(prop, "word-wrap"))
        return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "hyphens")) return qjs.JS_NewStringLen(c, "manual", 6);
    if (eqlIgnoreCase(prop, "text-decoration-line")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "text-decoration-style")) return qjs.JS_NewStringLen(c, "solid", 5);
    if (eqlIgnoreCase(prop, "text-decoration-color")) return qjs.JS_NewStringLen(c, "rgb(0, 0, 0)", 12);
    if (eqlIgnoreCase(prop, "text-underline-position")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "text-underline-offset")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "text-emphasis-style")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "text-emphasis-color")) return qjs.JS_NewStringLen(c, "rgb(0, 0, 0)", 12);
    if (eqlIgnoreCase(prop, "text-shadow")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "white-space")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "white-space-collapse")) return qjs.JS_NewStringLen(c, "collapse", 8);
    if (eqlIgnoreCase(prop, "text-wrap") or eqlIgnoreCase(prop, "text-wrap-mode"))
        return qjs.JS_NewStringLen(c, "wrap", 4);
    if (eqlIgnoreCase(prop, "text-wrap-style")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "text-align-last")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "text-align-all")) return qjs.JS_NewStringLen(c, "start", 5);
    if (eqlIgnoreCase(prop, "text-justify")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "text-autospace")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "text-spacing-trim")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "text-spacing")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "text-group-align")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "word-space-transform")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "hyphenate-character")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "hyphenate-limit-chars")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "hanging-punctuation")) return qjs.JS_NewStringLen(c, "none", 4);
    // CSS Logical Properties (default to auto for position, 0px for size)
    if (eqlIgnoreCase(prop, "inset-block-start") or eqlIgnoreCase(prop, "inset-block-end") or
        eqlIgnoreCase(prop, "inset-inline-start") or eqlIgnoreCase(prop, "inset-inline-end"))
        return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "margin-block-start") or eqlIgnoreCase(prop, "margin-block-end") or
        eqlIgnoreCase(prop, "margin-inline-start") or eqlIgnoreCase(prop, "margin-inline-end"))
        return qjs.JS_NewStringLen(c, "0px", 3);
    if (eqlIgnoreCase(prop, "padding-block-start") or eqlIgnoreCase(prop, "padding-block-end") or
        eqlIgnoreCase(prop, "padding-inline-start") or eqlIgnoreCase(prop, "padding-inline-end"))
        return qjs.JS_NewStringLen(c, "0px", 3);
    if (eqlIgnoreCase(prop, "block-size") or eqlIgnoreCase(prop, "inline-size"))
        return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "min-block-size") or eqlIgnoreCase(prop, "min-inline-size"))
        return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "max-block-size") or eqlIgnoreCase(prop, "max-inline-size"))
        return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "scrollbar-gutter")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "overflow-clip-margin")) return qjs.JS_NewStringLen(c, "0px", 3);
    if (eqlIgnoreCase(prop, "flex-wrap")) return qjs.JS_NewStringLen(c, "nowrap", 6);
    if (eqlIgnoreCase(prop, "flex-flow")) return qjs.JS_NewStringLen(c, "row nowrap", 10);
    if (eqlIgnoreCase(prop, "justify-content") or eqlIgnoreCase(prop, "align-content"))
        return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "align-items")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "align-self")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "row-gap") or eqlIgnoreCase(prop, "column-gap") or eqlIgnoreCase(prop, "gap"))
        return qjs.JS_NewStringLen(c, "normal", 6);
    // CSS Backgrounds defaults
    if (eqlIgnoreCase(prop, "background-attachment")) return qjs.JS_NewStringLen(c, "scroll", 6);
    if (eqlIgnoreCase(prop, "background-clip")) return qjs.JS_NewStringLen(c, "border-box", 10);
    if (eqlIgnoreCase(prop, "background-image")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "background-origin")) return qjs.JS_NewStringLen(c, "padding-box", 11);
    if (eqlIgnoreCase(prop, "background-position")) return qjs.JS_NewStringLen(c, "0% 0%", 5);
    if (eqlIgnoreCase(prop, "background-position-x") or eqlIgnoreCase(prop, "background-position-y"))
        return qjs.JS_NewStringLen(c, "0%", 2);
    if (eqlIgnoreCase(prop, "background-repeat")) return qjs.JS_NewStringLen(c, "repeat", 6);
    if (eqlIgnoreCase(prop, "background-size")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "border-image-source")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "border-image-slice")) return qjs.JS_NewStringLen(c, "100%", 4);
    if (eqlIgnoreCase(prop, "border-image-width")) return qjs.JS_NewStringLen(c, "1", 1);
    if (eqlIgnoreCase(prop, "border-image-outset")) return qjs.JS_NewStringLen(c, "0", 1);
    if (eqlIgnoreCase(prop, "border-image-repeat")) return qjs.JS_NewStringLen(c, "stretch", 7);
    if (eqlIgnoreCase(prop, "border-top-left-radius") or eqlIgnoreCase(prop, "border-top-right-radius") or
        eqlIgnoreCase(prop, "border-bottom-left-radius") or eqlIgnoreCase(prop, "border-bottom-right-radius"))
        return qjs.JS_NewStringLen(c, "0px", 3);
    if (eqlIgnoreCase(prop, "box-shadow")) return qjs.JS_NewStringLen(c, "none", 4);
    // CSS Transforms
    if (eqlIgnoreCase(prop, "backface-visibility")) return qjs.JS_NewStringLen(c, "visible", 7);
    if (eqlIgnoreCase(prop, "perspective")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "perspective-origin")) return qjs.JS_NewStringLen(c, "50% 50%", 7);
    if (eqlIgnoreCase(prop, "transform-box")) return qjs.JS_NewStringLen(c, "view-box", 8);
    if (eqlIgnoreCase(prop, "transform-origin")) return qjs.JS_NewStringLen(c, "50% 50% 0px", 11);
    if (eqlIgnoreCase(prop, "transform-style")) return qjs.JS_NewStringLen(c, "flat", 4);
    // CSS Writing Modes
    if (eqlIgnoreCase(prop, "writing-mode")) return qjs.JS_NewStringLen(c, "horizontal-tb", 13);
    if (eqlIgnoreCase(prop, "text-orientation")) return qjs.JS_NewStringLen(c, "mixed", 5);
    if (eqlIgnoreCase(prop, "text-combine-upright")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "direction")) return qjs.JS_NewStringLen(c, "ltr", 3);
    if (eqlIgnoreCase(prop, "unicode-bidi")) return qjs.JS_NewStringLen(c, "normal", 6);
    // CSS Fonts
    if (eqlIgnoreCase(prop, "font-kerning")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "font-feature-settings")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "font-language-override")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "font-optical-sizing")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "font-palette")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "font-size-adjust")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "font-stretch") or eqlIgnoreCase(prop, "font-width"))
        return qjs.JS_NewStringLen(c, "100%", 4);
    if (eqlIgnoreCase(prop, "font-synthesis")) return qjs.JS_NewStringLen(c, "weight style small-caps", 23);
    if (eqlIgnoreCase(prop, "font-variant")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "font-variant-caps")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "font-variant-east-asian")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "font-variant-ligatures")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "font-variant-numeric")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "font-variant-position")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "font-variation-settings")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "font-synthesis-weight")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "font-synthesis-style")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "font-synthesis-small-caps")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "font-variant-alternates")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "font-variant-emoji")) return qjs.JS_NewStringLen(c, "normal", 6);
    // CSS Grid
    if (eqlIgnoreCase(prop, "grid-auto-columns") or eqlIgnoreCase(prop, "grid-auto-rows"))
        return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "grid-auto-flow")) return qjs.JS_NewStringLen(c, "row", 3);
    if (eqlIgnoreCase(prop, "grid-template-areas")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "grid-template-columns") or eqlIgnoreCase(prop, "grid-template-rows"))
        return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "grid-column-start") or eqlIgnoreCase(prop, "grid-column-end") or
        eqlIgnoreCase(prop, "grid-row-start") or eqlIgnoreCase(prop, "grid-row-end"))
        return qjs.JS_NewStringLen(c, "auto", 4);
    // CSS Animations
    if (eqlIgnoreCase(prop, "animation-delay")) return qjs.JS_NewStringLen(c, "0s", 2);
    if (eqlIgnoreCase(prop, "animation-direction")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "animation-duration")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "animation-fill-mode")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "animation-iteration-count")) return qjs.JS_NewStringLen(c, "1", 1);
    if (eqlIgnoreCase(prop, "animation-name")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "animation-play-state")) return qjs.JS_NewStringLen(c, "running", 7);
    if (eqlIgnoreCase(prop, "animation-timing-function")) return qjs.JS_NewStringLen(c, "ease", 4);
    if (eqlIgnoreCase(prop, "animation-range-start")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "animation-range-end")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "animation-timeline")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "animation-composition")) return qjs.JS_NewStringLen(c, "replace", 7);
    // CSS Transitions
    if (eqlIgnoreCase(prop, "transition-property")) return qjs.JS_NewStringLen(c, "all", 3);
    if (eqlIgnoreCase(prop, "transition-duration")) return qjs.JS_NewStringLen(c, "0s", 2);
    if (eqlIgnoreCase(prop, "transition-timing-function")) return qjs.JS_NewStringLen(c, "ease", 4);
    // CSS Images
    if (eqlIgnoreCase(prop, "image-orientation")) return qjs.JS_NewStringLen(c, "from-image", 10);
    if (eqlIgnoreCase(prop, "image-rendering")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "object-fit")) return qjs.JS_NewStringLen(c, "fill", 4);
    if (eqlIgnoreCase(prop, "object-position")) return qjs.JS_NewStringLen(c, "50% 50%", 7);
    // CSS Masking
    // CSS Filter Effects
    if (eqlIgnoreCase(prop, "flood-color")) return qjs.JS_NewStringLen(c, "rgb(0, 0, 0)", 12);
    if (eqlIgnoreCase(prop, "flood-opacity")) return qjs.JS_NewStringLen(c, "1", 1);
    if (eqlIgnoreCase(prop, "lighting-color")) return qjs.JS_NewStringLen(c, "rgb(255, 255, 255)", 18);
    if (eqlIgnoreCase(prop, "color-interpolation-filters")) return qjs.JS_NewStringLen(c, "linearRGB", 9);
    if (eqlIgnoreCase(prop, "filter") or eqlIgnoreCase(prop, "backdrop-filter"))
        return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "outline-offset")) return qjs.JS_NewStringLen(c, "0px", 3);
    if (eqlIgnoreCase(prop, "field-sizing")) return qjs.JS_NewStringLen(c, "fixed", 5);
    if (eqlIgnoreCase(prop, "interactivity")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "clip")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "clip-path")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "clip-rule")) return qjs.JS_NewStringLen(c, "nonzero", 7);
    if (eqlIgnoreCase(prop, "mask-image")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "mask-repeat")) return qjs.JS_NewStringLen(c, "repeat", 6);
    if (eqlIgnoreCase(prop, "mask-position")) return qjs.JS_NewStringLen(c, "0% 0%", 5);
    if (eqlIgnoreCase(prop, "mask-size")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "mask-composite")) return qjs.JS_NewStringLen(c, "add", 3);
    if (eqlIgnoreCase(prop, "mask-type")) return qjs.JS_NewStringLen(c, "luminance", 9);
    // CSS Shapes
    if (eqlIgnoreCase(prop, "shape-outside")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "shape-margin")) return qjs.JS_NewStringLen(c, "0px", 3);
    if (eqlIgnoreCase(prop, "shape-image-threshold")) return qjs.JS_NewStringLen(c, "0", 1);
    // CSS Multi-column
    if (eqlIgnoreCase(prop, "column-count")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "column-width")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "column-fill")) return qjs.JS_NewStringLen(c, "balance", 7);
    if (eqlIgnoreCase(prop, "column-span")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "column-rule-width")) return qjs.JS_NewStringLen(c, "medium", 6);
    if (eqlIgnoreCase(prop, "column-rule-style")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "column-rule-color")) return qjs.JS_NewStringLen(c, "rgb(0, 0, 0)", 12);
    // CSS Lists
    if (eqlIgnoreCase(prop, "list-style-position")) return qjs.JS_NewStringLen(c, "outside", 7);
    if (eqlIgnoreCase(prop, "list-style-image")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "list-style-type")) return qjs.JS_NewStringLen(c, "disc", 4);
    if (eqlIgnoreCase(prop, "counter-set") or eqlIgnoreCase(prop, "counter-reset") or
        eqlIgnoreCase(prop, "counter-increment"))
        return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "content")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "quotes")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "overscroll-behavior") or eqlIgnoreCase(prop, "overscroll-behavior-x") or
        eqlIgnoreCase(prop, "overscroll-behavior-y"))
        return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "scroll-markers")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "scroll-target-group")) return qjs.JS_NewStringLen(c, "none", 4);
    // CSS Tables
    if (eqlIgnoreCase(prop, "caption-side")) return qjs.JS_NewStringLen(c, "top", 3);
    if (eqlIgnoreCase(prop, "empty-cells")) return qjs.JS_NewStringLen(c, "show", 4);
    if (eqlIgnoreCase(prop, "table-layout")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "border-spacing")) return qjs.JS_NewStringLen(c, "0px 0px", 7);
    // CSS Inline
    if (eqlIgnoreCase(prop, "alignment-baseline")) return qjs.JS_NewStringLen(c, "baseline", 8);
    if (eqlIgnoreCase(prop, "dominant-baseline")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "baseline-shift")) return qjs.JS_NewStringLen(c, "0px", 3);
    // CSS Page
    if (eqlIgnoreCase(prop, "break-before") or eqlIgnoreCase(prop, "break-after"))
        return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "break-inside")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "orphans") or eqlIgnoreCase(prop, "widows"))
        return qjs.JS_NewStringLen(c, "2", 1);
    if (eqlIgnoreCase(prop, "page")) return qjs.JS_NewStringLen(c, "auto", 4);
    // CSS View Transitions
    if (eqlIgnoreCase(prop, "view-transition-name")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "view-transition-class")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "offset-anchor")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "offset-position")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "corner-shape")) return qjs.JS_NewStringLen(c, "round", 5);
    if (eqlIgnoreCase(prop, "text-size-adjust")) return qjs.JS_NewStringLen(c, "auto", 4);
    // CSS Anchor Position
    if (eqlIgnoreCase(prop, "anchor-scope") or eqlIgnoreCase(prop, "anchor-name"))
        return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "position-anchor")) return qjs.JS_NewStringLen(c, "implicit", 8);
    if (eqlIgnoreCase(prop, "position-area")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "position-visibility")) return qjs.JS_NewStringLen(c, "always", 6);
    // CSS Color Adjust
    if (eqlIgnoreCase(prop, "color-adjust") or eqlIgnoreCase(prop, "print-color-adjust"))
        return qjs.JS_NewStringLen(c, "economy", 7);
    if (eqlIgnoreCase(prop, "forced-color-adjust")) return qjs.JS_NewStringLen(c, "auto", 4);
    // CSS Logical borders
    if (eqlIgnoreCase(prop, "border-block-start-color") or eqlIgnoreCase(prop, "border-block-end-color") or
        eqlIgnoreCase(prop, "border-inline-start-color") or eqlIgnoreCase(prop, "border-inline-end-color"))
        return qjs.JS_NewStringLen(c, "rgb(0, 0, 0)", 12);
    if (eqlIgnoreCase(prop, "border-block-start-width") or eqlIgnoreCase(prop, "border-block-end-width") or
        eqlIgnoreCase(prop, "border-inline-start-width") or eqlIgnoreCase(prop, "border-inline-end-width"))
        return qjs.JS_NewStringLen(c, "medium", 6);
    if (eqlIgnoreCase(prop, "border-block-start-style") or eqlIgnoreCase(prop, "border-block-end-style") or
        eqlIgnoreCase(prop, "border-inline-start-style") or eqlIgnoreCase(prop, "border-inline-end-style"))
        return qjs.JS_NewStringLen(c, "none", 4);
    // CSS Align
    if (eqlIgnoreCase(prop, "place-content") or eqlIgnoreCase(prop, "place-items"))
        return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "place-self")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "justify-items")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "justify-self")) return qjs.JS_NewStringLen(c, "auto", 4);
    // CSS Will Change
    if (eqlIgnoreCase(prop, "will-change")) return qjs.JS_NewStringLen(c, "auto", 4);
    // CSS Motion
    if (eqlIgnoreCase(prop, "offset-path")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "offset-distance")) return qjs.JS_NewStringLen(c, "0px", 3);
    if (eqlIgnoreCase(prop, "offset-rotate")) return qjs.JS_NewStringLen(c, "auto", 4);
    // CSS Scroll Snap
    if (eqlIgnoreCase(prop, "scroll-snap-type")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "scroll-snap-align")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "scroll-snap-stop")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "scroll-padding-top") or eqlIgnoreCase(prop, "scroll-padding-right") or
        eqlIgnoreCase(prop, "scroll-padding-bottom") or eqlIgnoreCase(prop, "scroll-padding-left"))
        return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "scroll-margin-top") or eqlIgnoreCase(prop, "scroll-margin-right") or
        eqlIgnoreCase(prop, "scroll-margin-bottom") or eqlIgnoreCase(prop, "scroll-margin-left") or
        eqlIgnoreCase(prop, "scroll-margin-block-start") or eqlIgnoreCase(prop, "scroll-margin-block-end") or
        eqlIgnoreCase(prop, "scroll-margin-inline-start") or eqlIgnoreCase(prop, "scroll-margin-inline-end"))
        return qjs.JS_NewStringLen(c, "0px", 3);
    if (eqlIgnoreCase(prop, "scroll-padding-block-start") or eqlIgnoreCase(prop, "scroll-padding-block-end") or
        eqlIgnoreCase(prop, "scroll-padding-inline-start") or eqlIgnoreCase(prop, "scroll-padding-inline-end"))
        return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "color")) return qjs.JS_NewStringLen(c, "rgb(0, 0, 0)", 12);
    if (eqlIgnoreCase(prop, "background-color"))
        return qjs.JS_NewStringLen(c, "rgba(0, 0, 0, 0)", 17);
    if (eqlIgnoreCase(prop, "border-top-color") or eqlIgnoreCase(prop, "border-right-color") or
        eqlIgnoreCase(prop, "border-bottom-color") or eqlIgnoreCase(prop, "border-left-color"))
        return qjs.JS_NewStringLen(c, "rgb(0, 0, 0)", 12);
    if (eqlIgnoreCase(prop, "border-top-style") or eqlIgnoreCase(prop, "border-right-style") or
        eqlIgnoreCase(prop, "border-bottom-style") or eqlIgnoreCase(prop, "border-left-style"))
        return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "box-sizing")) return qjs.JS_NewStringLen(c, "content-box", 11);
    if (eqlIgnoreCase(prop, "flex-grow")) return qjs.JS_NewStringLen(c, "0", 1);
    if (eqlIgnoreCase(prop, "flex-shrink")) return qjs.JS_NewStringLen(c, "1", 1);
    if (eqlIgnoreCase(prop, "flex-basis")) return qjs.JS_NewStringLen(c, "auto", 4);
    // CSS Transforms Level 2 individual properties
    if (eqlIgnoreCase(prop, "scale")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "rotate")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "translate")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "transform")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "transition-delay")) return qjs.JS_NewStringLen(c, "0s", 2);
    if (eqlIgnoreCase(prop, "order")) return qjs.JS_NewStringLen(c, "0", 1);
    if (eqlIgnoreCase(prop, "aspect-ratio")) return qjs.JS_NewStringLen(c, "auto", 4);
    if (eqlIgnoreCase(prop, "reading-flow")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "reading-order")) return qjs.JS_NewStringLen(c, "0", 1);
    // Default fallback
    return qjs.JS_NewStringLen(c, "", 0);
}

/// Check if a CSS property is inherited by default (CSS spec).
pub fn isCssInheritedProperty(prop: []const u8) bool {
    const inherited = [_][]const u8{
        "color",          "font-size",       "font-weight",      "font-style",
        "font-family",    "font-variant",    "text-align",       "text-indent",
        "text-transform", "line-height",     "letter-spacing",   "word-spacing",
        "word-break",     "white-space",     "visibility",       "direction",
        "cursor",         "list-style-type", "list-style-position", "list-style-image",
        "border-collapse", "border-spacing", "caption-side",     "empty-cells",
        "quotes",         "orphans",         "widows",           "tab-size",
    };
    for (inherited) |p| {
        if (eqlIgnoreCase(prop, p)) return true;
    }
    return false;
}

/// Get the inherited (parent's) computed value for a property.
pub fn getInheritedComputedValue(c: *qjs.JSContext, elem_val: qjs.JSValue, prop: []const u8) qjs.JSValue {
    const node = getNode(c, elem_val) orelse return cssInitialValue(c, prop);
    const parent = node.parent orelse return cssInitialValue(c, prop);

    // Check parent's inline style first (reflects JS modifications)
    // Guard: only element nodes have attributes
    const parent_ptr: *lxb.lxb_dom_node_t = @ptrCast(parent);
    if (parent_ptr.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
        if (api.getStylesForCtx(c)) |styles| {
            if (styles.get(@intFromPtr(parent))) |style| {
                return computedStyleToString(c, &style, prop);
            }
        }
        return cssInitialValue(c, prop);
    }
    const parent_elem: *lxb.lxb_dom_element_t = @ptrCast(parent);
    var pstyle_len: usize = 0;
    const pstyle_ptr = lxb_dom_element_get_attribute(parent_elem, "style", 5, &pstyle_len);
    if (pstyle_ptr != null and pstyle_len > 0) {
        const pstyle = pstyle_ptr.?[0..pstyle_len];
        if (getStyleProperty(pstyle, prop)) |val| {
            const trimmed = std.mem.trim(u8, val, " \t\r\n");
            // Don't return CSS-wide keywords — resolve them further
            if (!eqlIgnoreCase(trimmed, "initial") and !eqlIgnoreCase(trimmed, "inherit") and
                !eqlIgnoreCase(trimmed, "unset") and !eqlIgnoreCase(trimmed, "revert"))
            {
                return qjs.JS_NewStringLen(c, val.ptr, val.len);
            }
        }
        // Also try longhand from stored shorthand (parent has "margin: 10px" → get "margin-top")
        if (api.getLonghandFromShorthand(pstyle, prop)) |val| {
            return qjs.JS_NewStringLen(c, val.ptr, val.len);
        }
    }

    // Fall back to cascade computed style
    if (api.getStylesForCtx(c)) |styles| {
        if (styles.get(@intFromPtr(parent))) |style| {
            return computedStyleToString(c, &style, prop);
        }
    }
    return cssInitialValue(c, prop);
}

// ── CSS.supports ──────────────────────────────────────────────────

/// CSS.supports(property, value) — checks if property+value is valid CSS
pub fn cssSupports(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NewBool(false);
    const args = argv orelse return quickjs.JS_NewBool(false);

    if (argc == 1) {
        // CSS.supports("display: flex") — condition string form
        // Parse "property: value" and validate
        const cond_s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NewBool(false);
        defer qjs.JS_FreeCString(c, cond_s.ptr);
        const cond = cond_s.ptr[0..cond_s.len];
        // Handle parenthesized form: "(display: flex)"
        var inner = cond;
        if (inner.len > 2 and inner[0] == '(' and inner[inner.len - 1] == ')') {
            inner = inner[1 .. inner.len - 1];
        }
        // Find the colon separating property from value
        if (std.mem.indexOfScalar(u8, inner, ':')) |colon_pos| {
            const prop_raw = std.mem.trim(u8, inner[0..colon_pos], " \t");
            const val_raw = std.mem.trim(u8, inner[colon_pos + 1 ..], " \t");
            if (prop_raw.len > 0 and val_raw.len > 0) {
                return quickjs.JS_NewBool(isValidCssValue(prop_raw, val_raw));
            }
        }
        // Not a simple "property: value" form — could be "not ()" or "() and ()"
        // For complex conditions, return false (conservative)
        return quickjs.JS_NewBool(false);
    }
    if (argc < 2) return quickjs.JS_NewBool(false);

    const prop_s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NewBool(false);
    defer qjs.JS_FreeCString(c, prop_s.ptr);
    const val_s = jsStringToSlice(c, args[1]) orelse return quickjs.JS_NewBool(false);
    defer qjs.JS_FreeCString(c, val_s.ptr);

    const prop = prop_s.ptr[0..prop_s.len];
    const val = val_s.ptr[0..val_s.len];

    // Validate via isValidCssValue (handles both longhand and shorthand)
    return quickjs.JS_NewBool(isValidCssValue(prop, val));
}

// ── window.getComputedStyle ───────────────────────────────────────

pub fn windowGetComputedStyle(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    // Verify the argument is a valid element
    _ = getElement(c, args[0]) orelse return quickjs.JS_UNDEFINED();

    // Build a CSSStyleDeclaration-like object backed by the element's inline style
    const obj = qjs.JS_NewObject(c);
    if (quickjs.JS_IsException(obj)) return obj;

    // Store element reference
    _ = qjs.JS_SetPropertyStr(c, obj, "__element", qjs.JS_DupValue(c, args[0]));

    // getPropertyValue method (live — always reads current computed style)
    _ = qjs.JS_SetPropertyStr(c, obj, "getPropertyValue", qjs.JS_NewCFunction(c, &computedStyleGetPropertyValue, "getPropertyValue", 1));

    // Set static property values directly from Zig — no JS eval needed.
    // This avoids the memory management issues (DupValue/FreeValue) that
    // caused segfaults during navigation with the previous eval approach.
    const node = getNode(c, args[0]);
    const style_opt: ?ComputedStyle = if (node != null and api.getStylesForCtx(c) != null)
        api.getStylesForCtx(c).?.get(@intFromPtr(node.?))
    else
        null;

    // Find layout box for used-value resolution (margin/padding/width % → px)
    const box_opt: ?*const Box = if (node != null and api.getRootBox(c) != null)
        api.findBoxForNode(api.getRootBox(c).?, node.?)
    else
        null;

    // Property name pairs: kebab-case (CSS) and camelCase (JS)
    const prop_pairs = .{
        .{ "display", "display" },
        .{ "position", "position" },
        .{ "visibility", "visibility" },
        .{ "color", "color" },
        .{ "background-color", "backgroundColor" },
        .{ "font-size", "fontSize" },
        .{ "font-weight", "fontWeight" },
        .{ "font-family", "fontFamily" },
        .{ "font-style", "fontStyle" },
        .{ "text-align", "textAlign" },
        .{ "text-transform", "textTransform" },
        .{ "text-overflow", "textOverflow" },
        .{ "text-indent", "textIndent" },
        .{ "letter-spacing", "letterSpacing" },
        .{ "word-spacing", "wordSpacing" },
        .{ "word-break", "wordBreak" },
        .{ "white-space", "whiteSpace" },
        .{ "line-height", "lineHeight" },
        .{ "vertical-align", "verticalAlign" },
        .{ "width", "width" },
        .{ "height", "height" },
        .{ "min-width", "minWidth" },
        .{ "max-width", "maxWidth" },
        .{ "min-height", "minHeight" },
        .{ "max-height", "maxHeight" },
        .{ "margin", "margin" },
        .{ "margin-top", "marginTop" },
        .{ "margin-right", "marginRight" },
        .{ "margin-bottom", "marginBottom" },
        .{ "margin-left", "marginLeft" },
        .{ "margin-trim", "marginTrim" },
        .{ "padding", "padding" },
        .{ "padding-top", "paddingTop" },
        .{ "padding-right", "paddingRight" },
        .{ "padding-bottom", "paddingBottom" },
        .{ "padding-left", "paddingLeft" },
        .{ "border-top-width", "borderTopWidth" },
        .{ "border-right-width", "borderRightWidth" },
        .{ "border-bottom-width", "borderBottomWidth" },
        .{ "border-left-width", "borderLeftWidth" },
        .{ "border-top-color", "borderTopColor" },
        .{ "border-right-color", "borderRightColor" },
        .{ "border-bottom-color", "borderBottomColor" },
        .{ "border-left-color", "borderLeftColor" },
        .{ "border-top-style", "borderTopStyle" },
        .{ "border-right-style", "borderRightStyle" },
        .{ "border-bottom-style", "borderBottomStyle" },
        .{ "border-left-style", "borderLeftStyle" },
        .{ "top", "top" },
        .{ "right", "right" },
        .{ "bottom", "bottom" },
        .{ "left", "left" },
        .{ "float", "float" },
        .{ "clear", "clear" },
        .{ "overflow", "overflow" },
        .{ "overflow-x", "overflowX" },
        .{ "overflow-y", "overflowY" },
        .{ "z-index", "zIndex" },
        .{ "opacity", "opacity" },
        .{ "box-sizing", "boxSizing" },
        .{ "flex-direction", "flexDirection" },
        .{ "flex-grow", "flexGrow" },
        .{ "flex-shrink", "flexShrink" },
        .{ "aspect-ratio", "aspectRatio" },
        .{ "reading-flow", "readingFlow" },
        .{ "reading-order", "readingOrder" },
        // CSS Transforms Level 2 individual properties
        .{ "scale", "scale" },
        .{ "rotate", "rotate" },
        .{ "translate", "translate" },
        // Additional properties for CSS math function tests
        .{ "flex-basis", "flexBasis" },
        .{ "order", "order" },
        .{ "transform", "transform" },
        .{ "transition-delay", "transitionDelay" },
        .{ "tab-size", "tabSize" },
        // CSS Text properties
        .{ "line-break", "lineBreak" },
        .{ "overflow-wrap", "overflowWrap" },
        .{ "word-wrap", "wordWrap" },
        .{ "hyphens", "hyphens" },
        .{ "text-decoration-line", "textDecorationLine" },
        .{ "text-decoration-style", "textDecorationStyle" },
        .{ "text-decoration-color", "textDecorationColor" },
        .{ "text-underline-position", "textUnderlinePosition" },
        .{ "text-underline-offset", "textUnderlineOffset" },
        .{ "text-emphasis-style", "textEmphasisStyle" },
        .{ "text-emphasis-color", "textEmphasisColor" },
        .{ "text-shadow", "textShadow" },
        .{ "text-align-last", "textAlignLast" },
        .{ "text-align-all", "textAlignAll" },
        .{ "text-justify", "textJustify" },
        .{ "text-autospace", "textAutospace" },
        .{ "text-spacing-trim", "textSpacingTrim" },
        .{ "text-spacing", "textSpacing" },
        .{ "text-group-align", "textGroupAlign" },
        .{ "word-space-transform", "wordSpaceTransform" },
        .{ "hyphenate-character", "hyphenateCharacter" },
        .{ "hyphenate-limit-chars", "hyphenateLimitChars" },
        .{ "hanging-punctuation", "hangingPunctuation" },
        .{ "white-space-collapse", "whiteSpaceCollapse" },
        .{ "text-wrap", "textWrap" },
        .{ "text-wrap-mode", "textWrapMode" },
        .{ "text-wrap-style", "textWrapStyle" },
        .{ "text-decoration", "textDecoration" },
        // CSS UI/Visual
        .{ "cursor", "cursor" },
        .{ "pointer-events", "pointerEvents" },
        .{ "user-select", "userSelect" },
        .{ "resize", "resize" },
        .{ "appearance", "appearance" },
        .{ "outline-style", "outlineStyle" },
        .{ "outline-width", "outlineWidth" },
        .{ "outline-color", "outlineColor" },
        .{ "outline-offset", "outlineOffset" },
        // CSS Layout
        .{ "contain", "contain" },
        .{ "container-type", "containerType" },
        .{ "container-name", "containerName" },
        .{ "content-visibility", "contentVisibility" },
        .{ "isolation", "isolation" },
        .{ "mix-blend-mode", "mixBlendMode" },
        .{ "object-fit", "objectFit" },
        .{ "object-position", "objectPosition" },
        // CSS Scroll
        .{ "scroll-behavior", "scrollBehavior" },
        .{ "scroll-snap-type", "scrollSnapType" },
        .{ "touch-action", "touchAction" },
        // CSS Color
        .{ "accent-color", "accentColor" },
        .{ "caret-color", "caretColor" },
        .{ "color-scheme", "colorScheme" },
        // CSS Logical Properties
        .{ "inset-block-start", "insetBlockStart" },
        .{ "inset-block-end", "insetBlockEnd" },
        .{ "inset-inline-start", "insetInlineStart" },
        .{ "inset-inline-end", "insetInlineEnd" },
        .{ "inset-block", "insetBlock" },
        .{ "inset-inline", "insetInline" },
        .{ "margin-block-start", "marginBlockStart" },
        .{ "margin-block-end", "marginBlockEnd" },
        .{ "margin-inline-start", "marginInlineStart" },
        .{ "margin-inline-end", "marginInlineEnd" },
        .{ "padding-block-start", "paddingBlockStart" },
        .{ "padding-block-end", "paddingBlockEnd" },
        .{ "padding-inline-start", "paddingInlineStart" },
        .{ "padding-inline-end", "paddingInlineEnd" },
        .{ "block-size", "blockSize" },
        .{ "inline-size", "inlineSize" },
        .{ "min-block-size", "minBlockSize" },
        .{ "min-inline-size", "minInlineSize" },
        .{ "max-block-size", "maxBlockSize" },
        .{ "max-inline-size", "maxInlineSize" },
        .{ "scrollbar-gutter", "scrollbarGutter" },
        .{ "overflow-clip-margin", "overflowClipMargin" },
        .{ "text-overflow", "textOverflow" },
        // CSS Flexbox (ensure all are in computed style)
        .{ "flex-wrap", "flexWrap" },
        .{ "flex-flow", "flexFlow" },
        .{ "flex-basis", "flexBasis" },
        .{ "order", "order" },
        .{ "justify-content", "justifyContent" },
        .{ "align-items", "alignItems" },
        .{ "align-self", "alignSelf" },
        .{ "align-content", "alignContent" },
        .{ "flex-grow", "flexGrow" },
        .{ "flex-shrink", "flexShrink" },
        .{ "gap", "gap" },
        .{ "row-gap", "rowGap" },
        .{ "column-gap", "columnGap" },
        // CSS Backgrounds
        .{ "background-attachment", "backgroundAttachment" },
        .{ "background-clip", "backgroundClip" },
        .{ "background-image", "backgroundImage" },
        .{ "background-origin", "backgroundOrigin" },
        .{ "background-position", "backgroundPosition" },
        .{ "background-position-x", "backgroundPositionX" },
        .{ "background-position-y", "backgroundPositionY" },
        .{ "background-repeat", "backgroundRepeat" },
        .{ "background-size", "backgroundSize" },
        .{ "border-image", "borderImage" },
        .{ "border-image-source", "borderImageSource" },
        .{ "border-image-slice", "borderImageSlice" },
        .{ "border-image-width", "borderImageWidth" },
        .{ "border-image-outset", "borderImageOutset" },
        .{ "border-image-repeat", "borderImageRepeat" },
        .{ "border-top-left-radius", "borderTopLeftRadius" },
        .{ "border-top-right-radius", "borderTopRightRadius" },
        .{ "border-bottom-left-radius", "borderBottomLeftRadius" },
        .{ "border-bottom-right-radius", "borderBottomRightRadius" },
        .{ "box-shadow", "boxShadow" },
        // CSS Transforms
        .{ "backface-visibility", "backfaceVisibility" },
        .{ "perspective", "perspective" },
        .{ "perspective-origin", "perspectiveOrigin" },
        .{ "transform-box", "transformBox" },
        .{ "transform-origin", "transformOrigin" },
        .{ "transform-style", "transformStyle" },
        // CSS Writing Modes
        .{ "writing-mode", "writingMode" },
        .{ "text-orientation", "textOrientation" },
        .{ "text-combine-upright", "textCombineUpright" },
        .{ "direction", "direction" },
        .{ "unicode-bidi", "unicodeBidi" },
        // CSS Fonts
        .{ "font-kerning", "fontKerning" },
        .{ "font-feature-settings", "fontFeatureSettings" },
        .{ "font-language-override", "fontLanguageOverride" },
        .{ "font-optical-sizing", "fontOpticalSizing" },
        .{ "font-palette", "fontPalette" },
        .{ "font-size-adjust", "fontSizeAdjust" },
        .{ "font-stretch", "fontStretch" },
        .{ "font-synthesis", "fontSynthesis" },
        .{ "font-variant", "fontVariant" },
        .{ "font-variant-caps", "fontVariantCaps" },
        .{ "font-variant-east-asian", "fontVariantEastAsian" },
        .{ "font-variant-ligatures", "fontVariantLigatures" },
        .{ "font-variant-numeric", "fontVariantNumeric" },
        .{ "font-variant-position", "fontVariantPosition" },
        .{ "font-variation-settings", "fontVariationSettings" },
        // CSS Grid
        .{ "grid-auto-columns", "gridAutoColumns" },
        .{ "grid-auto-rows", "gridAutoRows" },
        .{ "grid-auto-flow", "gridAutoFlow" },
        .{ "grid-template-areas", "gridTemplateAreas" },
        .{ "grid-template", "gridTemplate" },
        .{ "grid-column-start", "gridColumnStart" },
        .{ "grid-column-end", "gridColumnEnd" },
        .{ "grid-row-start", "gridRowStart" },
        .{ "grid-row-end", "gridRowEnd" },
        .{ "grid-area", "gridArea" },
        // CSS Images
        .{ "image-orientation", "imageOrientation" },
        .{ "image-rendering", "imageRendering" },
        .{ "object-fit", "objectFit" },
        .{ "object-position", "objectPosition" },
        // CSS Scroll Snap
        .{ "scroll-snap-type", "scrollSnapType" },
        .{ "scroll-snap-align", "scrollSnapAlign" },
        .{ "scroll-snap-stop", "scrollSnapStop" },
        .{ "scroll-padding-top", "scrollPaddingTop" },
        .{ "scroll-padding-right", "scrollPaddingRight" },
        .{ "scroll-padding-bottom", "scrollPaddingBottom" },
        .{ "scroll-padding-left", "scrollPaddingLeft" },
        .{ "scroll-margin-top", "scrollMarginTop" },
        .{ "scroll-margin-right", "scrollMarginRight" },
        .{ "scroll-margin-bottom", "scrollMarginBottom" },
        .{ "scroll-margin-left", "scrollMarginLeft" },
        .{ "scroll-padding-block-start", "scrollPaddingBlockStart" },
        .{ "scroll-padding-block-end", "scrollPaddingBlockEnd" },
        .{ "scroll-padding-inline-start", "scrollPaddingInlineStart" },
        .{ "scroll-padding-inline-end", "scrollPaddingInlineEnd" },
        .{ "scroll-margin-block-start", "scrollMarginBlockStart" },
        .{ "scroll-margin-block-end", "scrollMarginBlockEnd" },
        .{ "scroll-margin-inline-start", "scrollMarginInlineStart" },
        .{ "scroll-margin-inline-end", "scrollMarginInlineEnd" },
        // CSS Fonts extra
        .{ "font-synthesis-weight", "fontSynthesisWeight" },
        .{ "font-synthesis-style", "fontSynthesisStyle" },
        .{ "font-synthesis-small-caps", "fontSynthesisSmallCaps" },
        .{ "font-variant-alternates", "fontVariantAlternates" },
        .{ "font-variant-emoji", "fontVariantEmoji" },
        .{ "font-width", "fontWidth" },
        // CSS Masking
        // CSS Filter Effects
        .{ "field-sizing", "fieldSizing" },
        .{ "interactivity", "interactivity" },
        .{ "clip", "clip" },
        .{ "flood-color", "floodColor" },
        .{ "flood-opacity", "floodOpacity" },
        .{ "lighting-color", "lightingColor" },
        .{ "color-interpolation-filters", "colorInterpolationFilters" },
        .{ "filter", "filter" },
        .{ "backdrop-filter", "backdropFilter" },
        .{ "clip-path", "clipPath" },
        .{ "clip-rule", "clipRule" },
        .{ "mask-image", "maskImage" },
        .{ "mask-repeat", "maskRepeat" },
        .{ "mask-position", "maskPosition" },
        .{ "mask-size", "maskSize" },
        .{ "mask-composite", "maskComposite" },
        .{ "mask-type", "maskType" },
        // CSS Shapes
        .{ "shape-outside", "shapeOutside" },
        .{ "shape-margin", "shapeMargin" },
        .{ "shape-image-threshold", "shapeImageThreshold" },
        // CSS Multi-column
        .{ "column-count", "columnCount" },
        .{ "column-width", "columnWidth" },
        .{ "column-fill", "columnFill" },
        .{ "column-span", "columnSpan" },
        .{ "column-rule-width", "columnRuleWidth" },
        .{ "column-rule-style", "columnRuleStyle" },
        .{ "column-rule-color", "columnRuleColor" },
        // CSS Lists
        .{ "list-style-position", "listStylePosition" },
        .{ "list-style-image", "listStyleImage" },
        .{ "list-style-type", "listStyleType" },
        .{ "counter-set", "counterSet" },
        .{ "counter-reset", "counterReset" },
        .{ "counter-increment", "counterIncrement" },
        // CSS Tables
        .{ "caption-side", "captionSide" },
        .{ "empty-cells", "emptyCells" },
        .{ "border-spacing", "borderSpacing" },
        .{ "table-layout", "tableLayout" },
        .{ "border-collapse", "borderCollapse" },
        // CSS Inline
        .{ "alignment-baseline", "alignmentBaseline" },
        .{ "dominant-baseline", "dominantBaseline" },
        .{ "baseline-shift", "baselineShift" },
        // CSS Page
        .{ "break-before", "breakBefore" },
        .{ "break-after", "breakAfter" },
        .{ "break-inside", "breakInside" },
        .{ "orphans", "orphans" },
        .{ "widows", "widows" },
        .{ "page", "page" },
        // CSS View Transitions
        .{ "view-transition-name", "viewTransitionName" },
        .{ "view-transition-class", "viewTransitionClass" },
        .{ "offset-anchor", "offsetAnchor" },
        .{ "offset-position", "offsetPosition" },
        .{ "corner-shape", "cornerShape" },
        .{ "overscroll-behavior", "overscrollBehavior" },
        .{ "overscroll-behavior-x", "overscrollBehaviorX" },
        .{ "overscroll-behavior-y", "overscrollBehaviorY" },
        .{ "quotes", "quotes" },
        .{ "content", "content" },
        .{ "scroll-markers", "scrollMarkers" },
        .{ "scroll-target-group", "scrollTargetGroup" },
        .{ "text-size-adjust", "textSizeAdjust" },
        // CSS Anchor Position
        .{ "anchor-scope", "anchorScope" },
        .{ "anchor-name", "anchorName" },
        .{ "position-anchor", "positionAnchor" },
        .{ "position-area", "positionArea" },
        .{ "position-visibility", "positionVisibility" },
        // CSS Color Adjust
        .{ "color-adjust", "colorAdjust" },
        .{ "print-color-adjust", "printColorAdjust" },
        .{ "forced-color-adjust", "forcedColorAdjust" },
        // CSS Logical borders
        .{ "border-block-start-color", "borderBlockStartColor" },
        .{ "border-block-end-color", "borderBlockEndColor" },
        .{ "border-inline-start-color", "borderInlineStartColor" },
        .{ "border-inline-end-color", "borderInlineEndColor" },
        .{ "border-block-start-width", "borderBlockStartWidth" },
        .{ "border-block-end-width", "borderBlockEndWidth" },
        .{ "border-inline-start-width", "borderInlineStartWidth" },
        .{ "border-inline-end-width", "borderInlineEndWidth" },
        .{ "border-block-start-style", "borderBlockStartStyle" },
        .{ "border-block-end-style", "borderBlockEndStyle" },
        .{ "border-inline-start-style", "borderInlineStartStyle" },
        .{ "border-inline-end-style", "borderInlineEndStyle" },
        // CSS Align
        .{ "place-content", "placeContent" },
        .{ "place-items", "placeItems" },
        .{ "place-self", "placeSelf" },
        .{ "row-gap", "rowGap" },
        .{ "column-gap", "columnGap" },
        .{ "grid-row-gap", "gridRowGap" },
        .{ "grid-column-gap", "gridColumnGap" },
        .{ "grid-gap", "gridGap" },
        .{ "grid-template-columns", "gridTemplateColumns" },
        .{ "grid-template-rows", "gridTemplateRows" },
        .{ "justify-items", "justifyItems" },
        .{ "justify-self", "justifySelf" },
        // CSS Will Change
        .{ "will-change", "willChange" },
        // CSS Motion
        .{ "offset-path", "offsetPath" },
        .{ "offset-distance", "offsetDistance" },
        .{ "offset-rotate", "offsetRotate" },
        // CSS Animations
        .{ "animation-delay", "animationDelay" },
        .{ "animation-direction", "animationDirection" },
        .{ "animation-duration", "animationDuration" },
        .{ "animation-fill-mode", "animationFillMode" },
        .{ "animation-iteration-count", "animationIterationCount" },
        .{ "animation-name", "animationName" },
        .{ "animation-play-state", "animationPlayState" },
        .{ "animation-timing-function", "animationTimingFunction" },
        .{ "animation-range-start", "animationRangeStart" },
        .{ "animation-range-end", "animationRangeEnd" },
        .{ "animation-timeline", "animationTimeline" },
        .{ "animation-composition", "animationComposition" },
        // CSS Transitions
        .{ "transition-property", "transitionProperty" },
        .{ "transition-duration", "transitionDuration" },
        .{ "transition-timing-function", "transitionTimingFunction" },
    };

    // Check inline style attribute first (highest specificity — reflects JS modifications)
    const elem = getElement(c, args[0]);
    var inline_style: []const u8 = "";
    if (elem) |el| {
        var style_len: usize = 0;
        const style_ptr = lxb_dom_element_get_attribute(el, "style", 5, &style_len);
        if (style_ptr != null and style_len > 0) {
            inline_style = style_ptr.?[0..style_len];
        }
    }

    inline for (prop_pairs) |pair| {
        const css_name = pair[0];
        const js_name = pair[1];
        // Priority: inline style > cascade computed style
        var val: qjs.JSValue = undefined;
        if (inline_style.len > 0) {
            if (getStyleProperty(inline_style, css_name)) |inline_val| {
                const t = std.mem.trim(u8, inline_val, " \t\r\n");
                if (eqlIgnoreCase(t, "initial")) {
                    val = cssInitialValue(c, css_name);
                } else if (eqlIgnoreCase(t, "inherit")) {
                    val = getInheritedComputedValue(c, args[0], css_name);
                } else if (eqlIgnoreCase(t, "unset")) {
                    val = if (isCssInheritedProperty(css_name)) getInheritedComputedValue(c, args[0], css_name) else cssInitialValue(c, css_name);
                } else if (eqlIgnoreCase(t, "revert")) {
                    if (style_opt) |style| {
                        val = computedStyleToStringWithBox(c, &style, css_name, box_opt);
                    } else {
                        val = cssInitialValue(c, css_name);
                    }
                } else {
                    val = resolveInlineForComputed(c, css_name, inline_val, args[0]);
                }
            } else if (api.reconstructBoxShorthandJSWithElem(c, inline_style, css_name, args[0])) |reconstructed| {
                val = reconstructed;
            } else if (api.getLonghandFromShorthand(inline_style, css_name)) |lh_val| {
                val = resolveInlineForComputed(c, css_name, lh_val, args[0]);
            } else if (style_opt) |style| {
                val = computedStyleToStringWithBox(c, &style, css_name, box_opt);
            } else {
                val = qjs.JS_NewStringLen(c, "", 0);
            }
        } else if (style_opt) |style| {
            val = computedStyleToStringWithBox(c, &style, css_name, box_opt);
        } else {
            val = qjs.JS_NewStringLen(c, "", 0);
        }
        _ = qjs.JS_SetPropertyStr(c, obj, js_name, val);
        // Also set kebab-case name if different from camelCase
        if (!std.mem.eql(u8, css_name, js_name)) {
            var val2: qjs.JSValue = undefined;
            if (inline_style.len > 0) {
                if (getStyleProperty(inline_style, css_name)) |inline_val| {
                    const t2 = std.mem.trim(u8, inline_val, " \t\r\n");
                    if (eqlIgnoreCase(t2, "initial")) {
                        val2 = cssInitialValue(c, css_name);
                    } else if (eqlIgnoreCase(t2, "inherit")) {
                        val2 = getInheritedComputedValue(c, args[0], css_name);
                    } else if (eqlIgnoreCase(t2, "unset")) {
                        val2 = if (isCssInheritedProperty(css_name)) getInheritedComputedValue(c, args[0], css_name) else cssInitialValue(c, css_name);
                    } else if (eqlIgnoreCase(t2, "revert")) {
                        if (style_opt) |style| {
                            val2 = computedStyleToStringWithBox(c, &style, css_name, box_opt);
                        } else {
                            val2 = cssInitialValue(c, css_name);
                        }
                    } else {
                        val2 = resolveInlineForComputed(c, css_name, inline_val, args[0]);
                    }
                } else if (api.reconstructBoxShorthandJSWithElem(c, inline_style, css_name, args[0])) |reconstructed| {
                    val2 = reconstructed;
                } else if (api.getLonghandFromShorthand(inline_style, css_name)) |lh_val| {
                    val2 = resolveInlineForComputed(c, css_name, lh_val, args[0]);
                } else if (style_opt) |style| {
                    val2 = computedStyleToStringWithBox(c, &style, css_name, box_opt);
                } else {
                    val2 = qjs.JS_NewStringLen(c, "", 0);
                }
            } else if (style_opt) |style| {
                val2 = computedStyleToStringWithBox(c, &style, css_name, box_opt);
            } else {
                val2 = qjs.JS_NewStringLen(c, "", 0);
            }
            _ = qjs.JS_SetPropertyStr(c, obj, css_name, val2);
        }
    }

    return obj;
}

// ── CSS Value Validation ──────────────────────────────────────────

pub fn isValidCssValue(prop: []const u8, val: []const u8) bool {
    const trimmed = std.mem.trim(u8, val, " \t\r\n");
    if (trimmed.len == 0) return true; // empty = remove property

    // CSS-wide keywords always valid for any property
    if (eqlIgnoreCase(trimmed, "inherit") or eqlIgnoreCase(trimmed, "initial") or
        eqlIgnoreCase(trimmed, "unset") or eqlIgnoreCase(trimmed, "revert")) return true;

    // var() always valid
    if (trimmed.len >= 4 and eqlIgnoreCase(trimmed[0..4], "var(")) return true;

    // Math functions valid if complete function call (ends with matching ')')
    if (trimmed[trimmed.len - 1] == ')') {
        if (trimmed.len >= 6 and eqlIgnoreCase(trimmed[0..5], "calc(")) return true;
        if (trimmed.len >= 5 and eqlIgnoreCase(trimmed[0..4], "min(")) return true;
        if (trimmed.len >= 5 and eqlIgnoreCase(trimmed[0..4], "max(")) return true;
        if (trimmed.len >= 7 and eqlIgnoreCase(trimmed[0..6], "clamp(")) return true;
        if (trimmed.len >= 7 and eqlIgnoreCase(trimmed[0..6], "round(")) return true;
        if (trimmed.len >= 5 and eqlIgnoreCase(trimmed[0..4], "mod(")) return true;
        if (trimmed.len >= 5 and eqlIgnoreCase(trimmed[0..4], "rem(")) return true;
        if (trimmed.len >= 5 and eqlIgnoreCase(trimmed[0..4], "abs(")) return true;
        if (trimmed.len >= 6 and eqlIgnoreCase(trimmed[0..5], "sign(")) return true;
        // Trig functions
        if (trimmed.len >= 5 and eqlIgnoreCase(trimmed[0..4], "sin(")) return true;
        if (trimmed.len >= 5 and eqlIgnoreCase(trimmed[0..4], "cos(")) return true;
        if (trimmed.len >= 5 and eqlIgnoreCase(trimmed[0..4], "tan(")) return true;
        if (trimmed.len >= 6 and eqlIgnoreCase(trimmed[0..5], "asin(")) return true;
        if (trimmed.len >= 6 and eqlIgnoreCase(trimmed[0..5], "acos(")) return true;
        if (trimmed.len >= 6 and eqlIgnoreCase(trimmed[0..5], "atan(")) return true;
        if (trimmed.len >= 7 and eqlIgnoreCase(trimmed[0..6], "atan2(")) return true;
        if (trimmed.len >= 6 and eqlIgnoreCase(trimmed[0..5], "sqrt(")) return true;
        if (trimmed.len >= 5 and eqlIgnoreCase(trimmed[0..4], "pow(")) return true;
        if (trimmed.len >= 7 and eqlIgnoreCase(trimmed[0..6], "hypot(")) return true;
        if (trimmed.len >= 5 and eqlIgnoreCase(trimmed[0..4], "log(")) return true;
        if (trimmed.len >= 5 and eqlIgnoreCase(trimmed[0..4], "exp(")) return true;
        // Color functions
        if (trimmed.len >= 5 and eqlIgnoreCase(trimmed[0..4], "hwb(")) return true;
        if (trimmed.len >= 5 and eqlIgnoreCase(trimmed[0..4], "lab(")) return true;
        if (trimmed.len >= 5 and eqlIgnoreCase(trimmed[0..4], "lch(")) return true;
        if (trimmed.len >= 7 and eqlIgnoreCase(trimmed[0..6], "oklab(")) return true;
        if (trimmed.len >= 7 and eqlIgnoreCase(trimmed[0..6], "oklch(")) return true;
        if (trimmed.len >= 7 and eqlIgnoreCase(trimmed[0..6], "color(")) return true;
    }

    const prop_id = css_ast.PropertyId.fromString(prop);
    if (prop_id == .custom) return true;

    // Handle shorthand properties that map to .unknown in PropertyId
    if (prop_id == .unknown) {
        return isValidShorthandValue(prop, trimmed);
    }

    return switch (prop_id) {
        // Size properties: accept auto, lengths (non-negative), %, min/max/fit-content
        .width, .height, .min_width, .min_height => isValidSizeValue(trimmed, false),
        // max-width/max-height accept "none" but NOT "auto"
        .max_width, .max_height => isValidMaxSizeValue(trimmed),
        // Margin: accept auto, lengths (can be negative), %
        .margin_top, .margin_right, .margin_bottom, .margin_left => isValidMarginValue(trimmed),
        // Padding: like size, non-negative lengths and %
        .padding_top, .padding_right, .padding_bottom, .padding_left => isValidNonNegLength(trimmed),
        // Border widths: non-negative lengths or thin/medium/thick
        .border_top_width, .border_right_width, .border_bottom_width, .border_left_width => isValidBorderWidth(trimmed),
        // Display: all CSS display values (single and two-value syntax)
        .display => isValidDisplayValue(trimmed),
        // Color properties
        .color, .background_color, .border_top_color, .border_right_color,
        .border_bottom_color, .border_left_color,
        .caret_color, .accent_color, .outline_color => css_properties.parseColor(trimmed) != null or isValidColorKeyword(trimmed) or isColorFuncWithCalc(trimmed) or
            eqlIgnoreCase(trimmed, "auto") or eqlIgnoreCase(trimmed, "currentcolor") or eqlIgnoreCase(trimmed, "currentColor"),
        // Numeric properties
        .opacity => blk: {
            if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '%') {
                break :blk std.fmt.parseFloat(f32, trimmed[0 .. trimmed.len - 1]) != error.InvalidCharacter;
            }
            break :blk std.fmt.parseFloat(f32, trimmed) != error.InvalidCharacter;
        },
        .z_index, .order => std.fmt.parseInt(i32, trimmed, 10) != error.InvalidCharacter or eqlIgnoreCase(trimmed, "auto"),
        .flex_grow, .flex_shrink => isNonNegNumber(trimmed),
        // Font size: non-negative length or keyword
        .font_size => isValidFontSize(trimmed),
        // Font weight: number 1-1000 or keyword
        .font_weight => isValidFontWeight(trimmed),
        // Line height: normal, non-negative number, non-negative length
        .line_height => isValidLineHeight(trimmed),
        // Top/right/bottom/left: auto, lengths (can be negative), %
        .top, .right, .bottom, .left => isValidMarginValue(trimmed),
        // Float: none, left, right, inline-start, inline-end (NOT auto)
        .float_ => eqlIgnoreCase(trimmed, "none") or eqlIgnoreCase(trimmed, "left") or
            eqlIgnoreCase(trimmed, "right") or eqlIgnoreCase(trimmed, "inline-start") or
            eqlIgnoreCase(trimmed, "inline-end"),
        // Clear: none, left, right, both, inline-start, inline-end (NOT auto)
        .clear => eqlIgnoreCase(trimmed, "none") or eqlIgnoreCase(trimmed, "left") or
            eqlIgnoreCase(trimmed, "right") or eqlIgnoreCase(trimmed, "both") or
            eqlIgnoreCase(trimmed, "inline-start") or eqlIgnoreCase(trimmed, "inline-end"),
        // margin-trim: none, block, inline, block-start, block-end, inline-start, inline-end
        .margin_trim => isValidMarginTrimValue(trimmed),
        // reading-flow: normal, flex-visual, flex-flow, grid-rows, grid-columns, grid-order
        .reading_flow => eqlIgnoreCase(trimmed, "normal") or eqlIgnoreCase(trimmed, "flex-visual") or
            eqlIgnoreCase(trimmed, "flex-flow") or eqlIgnoreCase(trimmed, "grid-rows") or
            eqlIgnoreCase(trimmed, "grid-columns") or eqlIgnoreCase(trimmed, "grid-order") or
            eqlIgnoreCase(trimmed, "source-order"),
        // reading-order: <integer>
        .reading_order => std.fmt.parseInt(i32, trimmed, 10) != error.InvalidCharacter,
        // Visibility: visible, hidden, collapse (NOT auto, NOT none)
        .visibility => eqlIgnoreCase(trimmed, "visible") or eqlIgnoreCase(trimmed, "hidden") or
            eqlIgnoreCase(trimmed, "collapse"),
        // Overflow: visible, hidden, scroll, auto, clip (NOT none)
        .overflow_x, .overflow_y => isValidOverflowValue(trimmed),
        // Cursor: keyword list (auto, default, pointer, text, wait, help, crosshair, etc.)
        .cursor => true, // Accept any cursor value (complex: url(), keyword, etc.)
        // Outline style: same as border-style
        .outline_style => eqlIgnoreCase(trimmed, "auto") or eqlIgnoreCase(trimmed, "none") or
            eqlIgnoreCase(trimmed, "dotted") or eqlIgnoreCase(trimmed, "dashed") or
            eqlIgnoreCase(trimmed, "solid") or eqlIgnoreCase(trimmed, "double") or
            eqlIgnoreCase(trimmed, "groove") or eqlIgnoreCase(trimmed, "ridge") or
            eqlIgnoreCase(trimmed, "inset") or eqlIgnoreCase(trimmed, "outset"),
        // Outline width: like border-width
        .outline_width => isValidBorderWidth(trimmed),
        // Flex wrap: nowrap, wrap, wrap-reverse
        .flex_wrap => eqlIgnoreCase(trimmed, "nowrap") or eqlIgnoreCase(trimmed, "wrap") or eqlIgnoreCase(trimmed, "wrap-reverse"),
        // Grid auto flow
        .grid_auto_flow => eqlIgnoreCase(trimmed, "row") or eqlIgnoreCase(trimmed, "column") or
            eqlIgnoreCase(trimmed, "dense") or eqlIgnoreCase(trimmed, "row dense") or
            eqlIgnoreCase(trimmed, "column dense"),
        // Grid auto columns/rows: accept track sizes
        .grid_auto_columns, .grid_auto_rows => true, // Accept any track size value
        // Grid line values: auto, number, span, name
        .grid_column_start, .grid_row_start => true, // Accept any grid line value
        // Grid template areas: none or string
        .grid_template_areas, .grid_template_columns, .grid_template_rows => true,
        // Animation/Transition properties: accept any valid value
        .animation_delay, .animation_direction, .animation_duration,
        .animation_fill_mode, .animation_iteration_count, .animation_name,
        .animation_play_state, .animation_timing_function,
        .transition_property, .transition_duration, .transition_timing_function,
        .transition_delay => true,
        // Other properties that accept complex values
        .filter, .backdrop_filter, .box_shadow, .text_shadow,
        .content, .counter_reset, .counter_increment, .will_change,
        .background_image, .background_repeat, .background_position,
        .background_size,
        .border_radius_top_left, .border_radius_top_right,
        .border_radius_bottom_left, .border_radius_bottom_right,
        .border_spacing, .grid_area, .transform,
        .letter_spacing, .word_spacing, .text_indent,
        .row_gap, .column_gap,
        .aspect_ratio,
        .object_fit, .contain,
        .font_family, .font_style,
        .vertical_align,
        .align_content, .align_items, .align_self,
        .justify_content, .justify_items, .justify_self,
        .color_scheme,
        // All remaining PropertyId variants that take complex/keyword values
        .position, .box_sizing,
        .border_top_style, .border_right_style, .border_bottom_style, .border_left_style,
        .text_align, .text_decoration, .text_transform, .white_space, .word_break,
        .overflow_wrap, .text_overflow, .list_style_type,
        .flex_direction, .flex_basis, .gap, .grid_column_end, .grid_row_end,
        .border_collapse, .table_layout,
        .text_decoration_color, .text_decoration_style, .text_decoration_thickness,
        .text_underline_offset, .appearance, .user_select, .pointer_events,
        .touch_action => true, // baseline, top, middle, bottom, sub, super, text-top, text-bottom, length, %
        // Note: outline-offset and resize are handled via known_shorthands (no PropertyId)
        // text-wrap: wrap, nowrap, balance, pretty, stable, auto
        .text_wrap => eqlIgnoreCase(trimmed, "wrap") or eqlIgnoreCase(trimmed, "nowrap") or
            eqlIgnoreCase(trimmed, "balance") or eqlIgnoreCase(trimmed, "pretty") or
            eqlIgnoreCase(trimmed, "stable") or eqlIgnoreCase(trimmed, "auto"),
        // text-wrap-mode: wrap, nowrap
        .text_wrap_mode => eqlIgnoreCase(trimmed, "wrap") or eqlIgnoreCase(trimmed, "nowrap"),
        // text-wrap-style: auto, balance, pretty, stable
        .text_wrap_style => eqlIgnoreCase(trimmed, "auto") or eqlIgnoreCase(trimmed, "balance") or
            eqlIgnoreCase(trimmed, "pretty") or eqlIgnoreCase(trimmed, "stable"),
        // tab-size: non-negative number or non-negative length
        .tab_size => isNonNegNumber(trimmed) or isValidNonNegLength(trimmed),
        // hyphens: none, manual, auto
        .hyphens => eqlIgnoreCase(trimmed, "none") or eqlIgnoreCase(trimmed, "manual") or eqlIgnoreCase(trimmed, "auto"),
        // Keyword-only properties: delegate to parseValue, check for .raw
        else => blk: {
            const parsed = css_properties.parseValue(prop_id, val);
            break :blk switch (parsed) {
                .raw => false,
                else => true,
            };
        },
    };
}

pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub fn isValidShorthandValue(prop: []const u8, val: []const u8) bool {
    // margin/padding shorthand: 1-4 values, each valid for the longhand
    if (eqlIgnoreCase(prop, "margin") or eqlIgnoreCase(prop, "margin-block") or
        eqlIgnoreCase(prop, "margin-inline"))
    {
        return isValidBoxShorthand(val, true);
    }
    if (eqlIgnoreCase(prop, "padding") or eqlIgnoreCase(prop, "padding-block") or
        eqlIgnoreCase(prop, "padding-inline"))
    {
        return isValidBoxShorthand(val, false);
    }
    if (eqlIgnoreCase(prop, "overflow")) {
        // overflow shorthand: 1-2 values from {visible, hidden, scroll, auto, clip}
        return isValidOverflowShorthand(val);
    }
    // CSS Transforms Level 2: individual transform properties
    if (eqlIgnoreCase(prop, "rotate")) {
        // none, angle, or math function returning angle
        if (eqlIgnoreCase(val, "none")) return true;
        if (val.len > 0 and val[val.len - 1] == ')') return true; // math function
        // Angle values: Ndeg, Nrad, Ngrad, Nturn
        if (std.mem.endsWith(u8, val, "deg") or std.mem.endsWith(u8, val, "rad") or
            std.mem.endsWith(u8, val, "grad") or std.mem.endsWith(u8, val, "turn"))
            return true;
        return std.fmt.parseFloat(f32, val) != error.InvalidCharacter; // bare number = degrees
    }
    if (eqlIgnoreCase(prop, "scale")) {
        if (eqlIgnoreCase(val, "none")) return true;
        if (val.len > 0 and val[val.len - 1] == ')') return true;
        return std.fmt.parseFloat(f32, val) != error.InvalidCharacter;
    }
    if (eqlIgnoreCase(prop, "translate")) {
        if (eqlIgnoreCase(val, "none")) return true;
        return true; // Accept any translate value
    }
    // Known shorthand properties that we don't deeply validate — accept
    const known_shorthands = [_][]const u8{
        "border",               "border-top",           "border-right",           "border-bottom",       "border-left",
        "border-radius",        "border-color",         "border-width",           "border-style",
        "background",           "font",                 "flex",                   "flex-flow",           "transition",           "animation",
        "text-decoration",      "list-style",           "outline",                "grid",                "grid-template",
        "grid-template-columns","grid-template-rows",   "grid-area",              "grid-column",
        "grid-row",             "gap",                  "place-content",          "place-items",         "place-self",
        "columns",              "column-rule",          "inset",
        // CSS Text properties (keyword values)
        "line-break",           "overflow-wrap",        "word-wrap",              "hyphens",
        "text-decoration-line", "text-decoration-style","text-decoration-color",
        "text-underline-position","text-underline-offset","text-emphasis-style",  "text-emphasis-color",
        "text-shadow",          "white-space-collapse",  "text-wrap",             "text-wrap-mode",      "text-wrap-style",
        "text-indent",          "tab-size",             "text-align-last",      "text-align-all",
        "text-justify",         "text-autospace",       "text-spacing-trim",    "text-spacing",
        "text-group-align",     "word-space-transform",
        "hyphenate-character",  "hyphenate-limit-chars","hanging-punctuation",
        // CSS positioning/layout properties
        "contain",              "content-visibility",   "container-type",         "container-name",
        "aspect-ratio",         "object-fit",           "object-position",
        "isolation",            "mix-blend-mode",       "filter",                 "backdrop-filter",
        "clip-path",            "mask",                 "mask-image",
        "scroll-behavior",     "overscroll-behavior",   "scroll-snap-type",       "scroll-snap-align",
        // CSS Logical Properties
        "inset-block-start",   "inset-block-end",      "inset-inline-start",     "inset-inline-end",
        "inset-block",         "inset-inline",
        "margin-block-start",  "margin-block-end",     "margin-inline-start",    "margin-inline-end",
        "padding-block-start", "padding-block-end",    "padding-inline-start",   "padding-inline-end",
        "border-block-start-width","border-block-end-width","border-inline-start-width","border-inline-end-width",
        "border-block-start-style","border-block-end-style","border-inline-start-style","border-inline-end-style",
        "border-block-start-color","border-block-end-color","border-inline-start-color","border-inline-end-color",
        "border-block-width",  "border-block-style",   "border-block-color",
        "border-inline-width", "border-inline-style",  "border-inline-color",
        "border-block-start",  "border-block-end",     "border-inline-start",    "border-inline-end",
        "border-block",        "border-inline",
        // CSS Transforms
        "backface-visibility", "perspective",          "perspective-origin",     "transform-box",
        "transform-origin",    "transform-style",
        // CSS Writing Modes
        "writing-mode",        "text-orientation",     "text-combine-upright",   "direction",
        "unicode-bidi",
        // CSS Fonts
        "font-kerning",        "font-feature-settings","font-language-override", "font-optical-sizing",
        "font-palette",        "font-size-adjust",     "font-stretch",           "font-synthesis",
        "font-variant",        "font-variant-caps",    "font-variant-east-asian","font-variant-ligatures",
        "font-variant-numeric","font-variant-position","font-variation-settings",
        "font-synthesis-weight","font-synthesis-style", "font-synthesis-small-caps","font-synthesis-position",
        "font-variant-alternates","font-variant-emoji",  "font-width",
        // CSS Grid
        "grid-auto-columns",   "grid-auto-rows",       "grid-auto-flow",
        "grid-template-areas", "grid-template",
        "grid-column-start",   "grid-column-end",      "grid-row-start",         "grid-row-end",
        // CSS Animations
        "animation-delay",     "animation-direction",  "animation-duration",     "animation-fill-mode",
        "animation-iteration-count","animation-name",  "animation-play-state",   "animation-timing-function",
        "animation-range-start","animation-range-end",  "animation-range",        "animation-timeline",
        "animation-composition",
        // CSS Transitions
        "transition-property", "transition-duration",  "transition-timing-function",
        "transition-behavior",
        "block-size",          "inline-size",          "min-block-size",         "min-inline-size",
        "max-block-size",      "max-inline-size",
        // CSS Backgrounds
        "background-attachment","background-clip",      "background-image",       "background-origin",
        "background-position", "background-position-x","background-position-y",  "background-repeat",
        "background-size",     "border-image",         "border-image-source",    "border-image-slice",
        "border-image-width",  "border-image-outset",  "border-image-repeat",
        "border-top-left-radius","border-top-right-radius","border-bottom-left-radius","border-bottom-right-radius",
        "border-top-radius","border-bottom-radius","border-left-radius","border-right-radius",
        "border-block-start-radius","border-block-end-radius","border-inline-start-radius","border-inline-end-radius",
        "corner-shape",        "corners",
        // CSS Overscroll Behavior
        "overscroll-behavior", "overscroll-behavior-x","overscroll-behavior-y",
        "overscroll-behavior-block","overscroll-behavior-inline",
        // CSS Gaps (rule)
        "rule-break",          "rule-inset-start",     "rule-inset-end",
        "rule-inset",          "rule-fill",            "rule-align",
        "rule-color",          "rule-width",           "rule-style",
        "rule-size",           "rule-length",          "rule",
        // CSS Content
        "quotes",
        // CSS Size Adjust
        "text-size-adjust",
        // CSS Anchor Position
        "anchor-scope",        "anchor-name",          "position-anchor",
        "position-area",       "position-try-fallbacks","position-try-order",
        "position-visibility", "inset-area",
        // CSS Color Adjust
        "color-adjust",        "print-color-adjust",   "forced-color-adjust",
        "color-scheme",
        // CSS Rhythm
        "block-step-size",     "block-step-insert",    "block-step-align",
        "block-step-round",    "block-step",           "line-height-step",
        // CSS Overflow
        "overflow-block",      "overflow-inline",      "scrollbar-gutter",       "overflow-clip-margin",
        "text-overflow",       "scroll-markers",       "scroll-target-group",    "scroll-buttons",
        "line-clamp",          "max-lines",            "block-ellipsis",         "continue",
        // CSS Images
        "image-orientation",   "image-rendering",      "image-resolution",
        // CSS UI (not in PropertyId)
        "outline-offset",      "field-sizing",         "interactivity",
        // CSS Filter Effects
        "flood-color",         "flood-opacity",        "lighting-color",         "clip",
        "color-interpolation-filters",
        // CSS Masking
        "clip-path",           "clip-rule",            "mask-image",             "mask-mode",
        "mask-repeat",         "mask-position",        "mask-clip",              "mask-origin",
        "mask-size",           "mask-composite",       "mask-type",              "mask",
        "mask-border",         "mask-border-source",   "mask-border-slice",      "mask-border-width",
        "mask-border-outset",  "mask-border-repeat",   "mask-border-mode",
        // CSS Shapes
        "shape-outside",       "shape-margin",         "shape-image-threshold",
        // CSS Multi-column
        "column-count",        "column-width",         "column-fill",            "column-span",
        "column-rule-width",   "column-rule-style",    "column-rule-color",
        // CSS Ruby
        "ruby-align",          "ruby-position",
        // CSS Lists
        "list-style-position", "list-style-image",     "marker-side",            "counter-set",
        // CSS Tables
        "caption-side",        "empty-cells",          "border-spacing",
        // CSS Inline
        "alignment-baseline",  "dominant-baseline",    "baseline-shift",         "initial-letter",
        "line-height-step",    "vertical-align",
        // CSS Page
        "break-before",        "break-after",          "break-inside",           "orphans",
        "widows",              "page",
        // CSS View Transitions
        "view-transition-name","view-transition-class",
        // CSS Logical (borders)
        "border-block-start-color","border-block-end-color",
        "border-inline-start-color","border-inline-end-color",
        "border-block-color",  "border-inline-color",
        "border-block-start-width","border-block-end-width",
        "border-inline-start-width","border-inline-end-width",
        "border-block-start-style","border-block-end-style",
        "border-inline-start-style","border-inline-end-style",
        // CSS Align
        "place-content",       "place-items",          "place-self",
        "row-gap",             "column-gap",
        "grid-row-gap",        "grid-column-gap",      "grid-gap",
        // CSS Will Change
        "will-change",
        // CSS Motion
        "offset-path",         "offset-distance",      "offset-rotate",
        "offset-anchor",       "offset-position",      "offset",
        // CSS Text Box Trim
        "text-box-trim",       "text-box-edge",        "text-box",
        // CSS Scroll Snap
        "scroll-snap-type",    "scroll-snap-align",    "scroll-snap-stop",
        "scroll-padding",      "scroll-padding-top",   "scroll-padding-right",
        "scroll-padding-bottom","scroll-padding-left",  "scroll-padding-block",
        "scroll-padding-inline","scroll-margin",        "scroll-margin-top",
        "scroll-margin-right", "scroll-margin-bottom", "scroll-margin-left",
        "scroll-margin-block", "scroll-margin-inline",
        "scroll-padding-block-start","scroll-padding-block-end",
        "scroll-padding-inline-start","scroll-padding-inline-end",
        "scroll-margin-block-start","scroll-margin-block-end",
        "scroll-margin-inline-start","scroll-margin-inline-end",
        "touch-action",         "user-select",          "pointer-events",         "resize",
        "appearance",           "accent-color",         "caret-color",            "color-scheme",
        "forced-color-adjust",  "print-color-adjust",
    };
    for (known_shorthands) |kw| {
        if (eqlIgnoreCase(prop, kw)) return true;
    }
    // Unknown property name — reject
    return false;
}

pub fn isValidBoxShorthand(val: []const u8, allow_negative: bool) bool {
    // Split by whitespace (respecting parentheses for calc() etc.), validate 1-4 parts
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < val.len) {
        while (pos < val.len and (val[pos] == ' ' or val[pos] == '\t')) pos += 1;
        if (pos >= val.len) break;
        const start = pos;
        var paren_depth: i32 = 0;
        while (pos < val.len) {
            if (val[pos] == '(') {
                paren_depth += 1;
            } else if (val[pos] == ')') {
                paren_depth -= 1;
            } else if ((val[pos] == ' ' or val[pos] == '\t') and paren_depth == 0) {
                break;
            }
            pos += 1;
        }
        const part = val[start..pos];
        count += 1;
        if (count > 4) return false;
        // calc()/var() parts are always valid
        if (part.len >= 5 and eqlIgnoreCase(part[0..5], "calc(") and part[part.len - 1] == ')') continue;
        if (part.len >= 4 and eqlIgnoreCase(part[0..4], "var(") and part[part.len - 1] == ')') continue;
        if (allow_negative) {
            if (!isValidMarginValue(part)) return false;
        } else {
            if (!isValidNonNegLength(part)) return false;
        }
    }
    return count >= 1 and count <= 4;
}

pub fn isValidDisplayValue(val: []const u8) bool {
    // Single-keyword display values
    const single = [_][]const u8{
        "none",          "contents",       "block",          "inline",
        "inline-block",  "flex",           "inline-flex",    "grid",
        "inline-grid",   "table",          "inline-table",   "list-item",
        "run-in",        "flow",           "flow-root",      "ruby",
        "ruby-base",     "ruby-text",      "ruby-base-container", "ruby-text-container",
        "table-row",     "table-cell",     "table-row-group", "table-header-group",
        "table-footer-group", "table-column", "table-column-group", "table-caption",
        "math",          "grid-lanes",     "inline-grid-lanes",
    };
    for (single) |kw| {
        if (eqlIgnoreCase(val, kw)) return true;
    }
    // Multi-value display: order-independent token classification
    // CSS Display 3: <display-outside> || <display-inside> | <display-listitem>
    // <display-outside> = block | inline | run-in
    // <display-inside> = flow | flow-root | table | flex | grid | ruby
    // <display-listitem> = <display-outside>? && [flow | flow-root]? && list-item
    const outside_kw = [_][]const u8{ "block", "inline", "run-in" };
    const inside_kw = [_][]const u8{ "flow", "flow-root", "table", "flex", "grid", "ruby", "grid-lanes" };

    var tokens: [3][]const u8 = .{ "", "", "" };
    var token_count: usize = 0;
    var pos: usize = 0;
    while (pos < val.len and token_count < 4) {
        while (pos < val.len and (val[pos] == ' ' or val[pos] == '\t')) pos += 1;
        if (pos >= val.len) break;
        const start = pos;
        while (pos < val.len and val[pos] != ' ' and val[pos] != '\t') pos += 1;
        if (token_count >= 3) return false; // >3 tokens invalid
        tokens[token_count] = val[start..pos];
        token_count += 1;
    }
    if (token_count < 2) return false;

    var has_outside = false;
    var has_inside = false;
    var has_list_item = false;
    var inside_is_flow_compat = false; // flow or flow-root (allowed with list-item)
    for (0..token_count) |i| {
        const tok = tokens[i];
        var matched = false;
        for (outside_kw) |kw| {
            if (eqlIgnoreCase(tok, kw)) {
                if (has_outside) return false; // duplicate outside
                has_outside = true;
                matched = true;
                break;
            }
        }
        if (!matched) {
            for (inside_kw) |kw| {
                if (eqlIgnoreCase(tok, kw)) {
                    if (has_inside) return false; // duplicate inside
                    has_inside = true;
                    if (eqlIgnoreCase(tok, "flow") or eqlIgnoreCase(tok, "flow-root"))
                        inside_is_flow_compat = true;
                    matched = true;
                    break;
                }
            }
        }
        if (!matched) {
            if (eqlIgnoreCase(tok, "list-item")) {
                if (has_list_item) return false;
                has_list_item = true;
                matched = true;
            }
        }
        if (!matched) return false; // unknown token
    }

    if (has_list_item) {
        // list-item only combines with flow/flow-root (not flex/grid/table/ruby)
        if (has_inside and !inside_is_flow_compat) return false;
        return true;
    }
    // outside + inside is valid (any combo)
    if (has_outside and has_inside) return true;
    return false;
}

// ── CSS Value Canonicalization ─────────────────────────────────────

/// Canonicalize a CSS display value to its shortest canonical form.
/// "block flow" → "block", "inline flow-root" → "inline-block", etc.
/// Returns only static string literals or the input — no buffer needed.
pub fn canonicalizeDisplayValue(val: []const u8) []const u8 {
    // Parse tokens (up to 3)
    var tokens: [3][]const u8 = .{ "", "", "" };
    var token_count: usize = 0;
    var pos: usize = 0;
    while (pos < val.len and token_count < 3) {
        while (pos < val.len and (val[pos] == ' ' or val[pos] == '\t')) pos += 1;
        if (pos >= val.len) break;
        const start = pos;
        while (pos < val.len and val[pos] != ' ' and val[pos] != '\t') pos += 1;
        tokens[token_count] = val[start..pos];
        token_count += 1;
    }

    if (token_count <= 1) {
        // Single-keyword canonical forms
        if (eqlIgnoreCase(val, "flow")) return "block";
        return val;
    }

    // Extract outer, inner, list-item
    var has_block = false;
    var has_inline = false;
    var has_run_in = false;
    var has_flow = false;
    var has_flow_root = false;
    var has_flex = false;
    var has_grid = false;
    var has_table = false;
    var has_ruby = false;
    var has_list_item = false;
    for (0..token_count) |i| {
        const tok = tokens[i];
        if (eqlIgnoreCase(tok, "block")) has_block = true
        else if (eqlIgnoreCase(tok, "inline")) has_inline = true
        else if (eqlIgnoreCase(tok, "run-in")) has_run_in = true
        else if (eqlIgnoreCase(tok, "flow")) has_flow = true
        else if (eqlIgnoreCase(tok, "flow-root")) has_flow_root = true
        else if (eqlIgnoreCase(tok, "flex")) has_flex = true
        else if (eqlIgnoreCase(tok, "grid")) has_grid = true
        else if (eqlIgnoreCase(tok, "table")) has_table = true
        else if (eqlIgnoreCase(tok, "ruby")) has_ruby = true
        else if (eqlIgnoreCase(tok, "list-item")) has_list_item = true;
    }

    if (!has_list_item) {
        if (has_flow or (!has_flow_root and !has_flex and !has_grid and !has_table and !has_ruby)) {
            if (has_block or (!has_inline and !has_run_in)) return "block";
            if (has_inline) return "inline";
            if (has_run_in) return "run-in";
        }
        if (has_flow_root) {
            if (has_block or (!has_inline and !has_run_in)) return "flow-root";
            if (has_inline) return "inline-block";
            if (has_run_in) return "run-in flow-root";
        }
        if (has_flex) {
            if (has_block or (!has_inline and !has_run_in)) return "flex";
            if (has_inline) return "inline-flex";
            if (has_run_in) return "run-in flex";
        }
        if (has_grid) {
            if (has_block or (!has_inline and !has_run_in)) return "grid";
            if (has_inline) return "inline-grid";
            if (has_run_in) return "run-in grid";
        }
        if (has_table) {
            if (has_block or (!has_inline and !has_run_in)) return "table";
            if (has_inline) return "inline-table";
            if (has_run_in) return "run-in table";
        }
        if (has_ruby) {
            if (has_inline) return "ruby";
            if (has_block) return "block ruby";
            if (has_run_in) return "run-in ruby";
        }
        return val; // unrecognized combo
    }

    // With list-item
    if (has_flow or (!has_flow_root and !has_flex and !has_grid and !has_table)) {
        if (has_block or (!has_inline and !has_run_in)) return "list-item";
        if (has_inline) return "inline list-item";
        if (has_run_in) return "run-in list-item";
    }
    if (has_flow_root) {
        if (has_block or (!has_inline and !has_run_in)) return "flow-root list-item";
        if (has_inline) return "inline flow-root list-item";
        if (has_run_in) return "run-in flow-root list-item";
    }
    return val;
}

/// Evaluate round(), mod(), rem() to calc(result) for constant numeric args.
pub fn canonicalizeRoundModRem(val: []const u8, buf: *[512]u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, val, " \t\r\n");
    if (trimmed[trimmed.len - 1] != ')') return null;

    var func_name: []const u8 = undefined;
    var prefix_len: usize = 0;
    if (trimmed.len >= 6 and eqlIgnoreCase(trimmed[0..6], "round(")) {
        func_name = "round";
        prefix_len = 6;
    } else if (trimmed.len >= 4 and eqlIgnoreCase(trimmed[0..4], "mod(")) {
        func_name = "mod";
        prefix_len = 4;
    } else if (trimmed.len >= 4 and eqlIgnoreCase(trimmed[0..4], "rem(")) {
        func_name = "rem";
        prefix_len = 4;
    } else return null;

    const inner = std.mem.trim(u8, trimmed[prefix_len .. trimmed.len - 1], " ");

    // Split on commas at depth 0
    var commas: [3]usize = undefined;
    var comma_count: usize = 0;
    var depth: usize = 0;
    for (inner, 0..) |ch, i| {
        if (ch == '(') depth += 1
        else if (ch == ')') { if (depth > 0) depth -= 1; }
        else if (ch == ',' and depth == 0 and comma_count < 3) {
            commas[comma_count] = i;
            comma_count += 1;
        }
    }
    if (comma_count == 0) return null;

    var a: f64 = undefined;
    var b: f64 = undefined;
    var strategy: enum { nearest, up, down, to_zero } = .nearest;

    if (std.mem.eql(u8, func_name, "round") and comma_count == 2) {
        // round(strategy, A, B) — 3-arg form
        const strat_str = std.mem.trim(u8, inner[0..commas[0]], " ");
        const a_str = std.mem.trim(u8, inner[commas[0] + 1 .. commas[1]], " ");
        const b_str = std.mem.trim(u8, inner[commas[1] + 1 ..], " ");
        if (eqlIgnoreCase(strat_str, "up")) strategy = .up
        else if (eqlIgnoreCase(strat_str, "down")) strategy = .down
        else if (eqlIgnoreCase(strat_str, "to-zero")) strategy = .to_zero
        else strategy = .nearest;
        a = std.fmt.parseFloat(f64, a_str) catch return null;
        b = std.fmt.parseFloat(f64, b_str) catch return null;
    } else if (std.mem.eql(u8, func_name, "round") and comma_count == 1) {
        // round(A, B) or round(strategy, A)
        const first = std.mem.trim(u8, inner[0..commas[0]], " ");
        const second = std.mem.trim(u8, inner[commas[0] + 1 ..], " ");
        if (eqlIgnoreCase(first, "nearest") or eqlIgnoreCase(first, "up") or
            eqlIgnoreCase(first, "down") or eqlIgnoreCase(first, "to-zero"))
        {
            if (eqlIgnoreCase(first, "up")) strategy = .up
            else if (eqlIgnoreCase(first, "down")) strategy = .down
            else if (eqlIgnoreCase(first, "to-zero")) strategy = .to_zero;
            a = std.fmt.parseFloat(f64, second) catch return null;
            b = 1;
        } else {
            a = std.fmt.parseFloat(f64, first) catch return null;
            b = std.fmt.parseFloat(f64, second) catch return null;
        }
    } else if (std.mem.eql(u8, func_name, "round") and comma_count == 0) {
        // round(A) — round to nearest integer
        a = std.fmt.parseFloat(f64, std.mem.trim(u8, inner, " ")) catch return null;
        b = 1;
    } else if (comma_count >= 1) {
        // 2-arg form: func(A, B)
        const a_str = std.mem.trim(u8, inner[0..commas[0]], " ");
        const b_str = std.mem.trim(u8, inner[commas[0] + 1 ..], " ");
        a = std.fmt.parseFloat(f64, a_str) catch return null;
        b = std.fmt.parseFloat(f64, b_str) catch return null;
    } else return null;

    var result: f64 = undefined;
    if (std.mem.eql(u8, func_name, "round")) {
        if (b == 0) return null;
        result = switch (strategy) {
            .nearest => @round(a / b) * b,
            .up => std.math.ceil(a / b) * b,
            .down => @floor(a / b) * b,
            .to_zero => @trunc(a / b) * b,
        };
    } else if (std.mem.eql(u8, func_name, "mod")) {
        if (b == 0) return null;
        result = a - b * @floor(a / b); // CSS mod (always matches sign of b)
    } else if (std.mem.eql(u8, func_name, "rem")) {
        if (b == 0) return null;
        result = a - b * @trunc(a / b); // CSS rem (matches sign of a)
    }

    // Format as calc(result)
    const s = std.fmt.bufPrint(buf, "calc({d})", .{result}) catch return null;
    return canonicalizeCalcValue(s, buf);
}

/// Distributive expansion for calc():
/// "N * (A + B)" → recursively canonicalize "calc(N*A + N*B)"
/// "(A + B) / N" → recursively canonicalize "calc(A/N + B/N)"
/// "(expr) * N" → "calc(N * (expr))" when expr has functions (reorder only)
pub fn tryDistributiveExpansion(inner: []const u8, buf: *[512]u8) ?[]const u8 {
    // Pattern 1: "N * (expr)" where N is a number
    if (std.mem.indexOf(u8, inner, " * (")) |mul_pos| {
        const left = std.mem.trim(u8, inner[0..mul_pos], " ");
        // Check left is a plain number
        const scalar = std.fmt.parseFloat(f64, left) catch return null;
        _ = scalar;
        const rest = inner[mul_pos + 3 ..]; // "(expr)"
        if (rest.len < 2 or rest[0] != '(') return null;
        // Find matching closing paren
        const close = findMatchingParen(rest, 0) orelse return null;
        if (close != rest.len - 1) return null; // must be the last thing
        const expr_inner = rest[1..close];

        // If expr contains min()/max()/clamp(), don't expand, just emit as-is
        if (containsFunction(expr_inner)) {
            // Already in canonical form: "N * (expr)"
            var out: usize = 0;
            const prefix = "calc(";
            @memcpy(buf[out..][0..prefix.len], prefix);
            out += prefix.len;
            const emit = inner;
            if (out + emit.len + 1 <= buf.len) {
                @memcpy(buf[out..][0..emit.len], emit);
                out += emit.len;
                buf[out] = ')';
                out += 1;
                return buf[0..out];
            }
            return null;
        }

        // Distribute: N * (A + B - C) → N*A + N*B - N*C
        // Build expanded string and recursively canonicalize
        var exp_buf: [512]u8 = undefined;
        var exp_pos: usize = 0;
        const exp_prefix = "calc(";
        @memcpy(exp_buf[exp_pos..][0..exp_prefix.len], exp_prefix);
        exp_pos += exp_prefix.len;

        // Split expr_inner by + and - (top-level only)
        var epos: usize = 0;
        var first_term = true;
        while (epos < expr_inner.len) {
            while (epos < expr_inner.len and expr_inner[epos] == ' ') epos += 1;
            if (epos >= expr_inner.len) break;

            var term_sign: u8 = '+';
            if (!first_term) {
                if (expr_inner[epos] == '+') {
                    epos += 1;
                    while (epos < expr_inner.len and expr_inner[epos] == ' ') epos += 1;
                } else if (expr_inner[epos] == '-') {
                    term_sign = '-';
                    epos += 1;
                    while (epos < expr_inner.len and expr_inner[epos] == ' ') epos += 1;
                }
            }

            const tstart = epos;
            var nest: usize = 0;
            while (epos < expr_inner.len) {
                if (expr_inner[epos] == '(') nest += 1
                else if (expr_inner[epos] == ')') { if (nest > 0) nest -= 1; }
                else if (nest == 0 and epos > tstart and
                    (expr_inner[epos] == '+' or (expr_inner[epos] == '-' and epos > 0 and expr_inner[epos - 1] == ' ')))
                    break;
                epos += 1;
            }
            const term = std.mem.trim(u8, expr_inner[tstart..epos], " ");
            if (term.len == 0) continue;

            // Emit: " + N * term" or " - N * term"
            if (!first_term) {
                if (exp_pos + 3 >= exp_buf.len) return null;
                exp_buf[exp_pos] = ' ';
                exp_buf[exp_pos + 1] = term_sign;
                exp_buf[exp_pos + 2] = ' ';
                exp_pos += 3;
            }
            // Write "left * term"
            if (exp_pos + left.len + 3 + term.len >= exp_buf.len) return null;
            @memcpy(exp_buf[exp_pos..][0..left.len], left);
            exp_pos += left.len;
            @memcpy(exp_buf[exp_pos..][0..3], " * ");
            exp_pos += 3;
            @memcpy(exp_buf[exp_pos..][0..term.len], term);
            exp_pos += term.len;

            first_term = false;
        }
        if (exp_pos + 1 > exp_buf.len) return null;
        exp_buf[exp_pos] = ')';
        exp_pos += 1;

        // Recursively canonicalize
        return canonicalizeCalcValue(exp_buf[0..exp_pos], buf);
    }

    // Pattern 2: "(expr) * N" — reorder to "N * (expr)" and retry
    if (inner.len > 4 and inner[0] == '(') {
        const close = findMatchingParen(inner, 0) orelse return null;
        if (close + 3 < inner.len) {
            const after_paren = std.mem.trim(u8, inner[close + 1 ..], " ");
            if (after_paren.len > 2 and after_paren[0] == '*' and after_paren[1] == ' ') {
                const scalar_str = std.mem.trim(u8, after_paren[2..], " ");
                // Verify it's a number
                _ = std.fmt.parseFloat(f64, scalar_str) catch return null;
                // Reorder to "N * (expr)"
                var reorder_buf: [512]u8 = undefined;
                var rpos: usize = 0;
                const rprefix = "calc(";
                @memcpy(reorder_buf[rpos..][0..rprefix.len], rprefix);
                rpos += rprefix.len;
                @memcpy(reorder_buf[rpos..][0..scalar_str.len], scalar_str);
                rpos += scalar_str.len;
                @memcpy(reorder_buf[rpos..][0..3], " * ");
                rpos += 3;
                @memcpy(reorder_buf[rpos..][0..close + 1], inner[0 .. close + 1]);
                rpos += close + 1;
                reorder_buf[rpos] = ')';
                rpos += 1;
                return canonicalizeCalcValue(reorder_buf[0..rpos], buf);
            }
        }
    }

    // Pattern 3: "(expr) / N" — distribute division
    if (inner.len > 4 and inner[0] == '(') {
        const close = findMatchingParen(inner, 0) orelse return null;
        if (close + 3 < inner.len) {
            const after_paren = std.mem.trim(u8, inner[close + 1 ..], " ");
            if (after_paren.len > 2 and after_paren[0] == '/' and after_paren[1] == ' ') {
                const divisor_str = std.mem.trim(u8, after_paren[2..], " ");
                _ = std.fmt.parseFloat(f64, divisor_str) catch return null;
                const expr_inner = inner[1..close];

                if (containsFunction(expr_inner)) return null;

                // Distribute: (A + B) / N → A / N + B / N
                var exp_buf: [512]u8 = undefined;
                var exp_pos: usize = 0;
                const exp_prefix = "calc(";
                @memcpy(exp_buf[exp_pos..][0..exp_prefix.len], exp_prefix);
                exp_pos += exp_prefix.len;

                var epos: usize = 0;
                var first_term = true;
                while (epos < expr_inner.len) {
                    while (epos < expr_inner.len and expr_inner[epos] == ' ') epos += 1;
                    if (epos >= expr_inner.len) break;
                    var term_sign: u8 = '+';
                    if (!first_term) {
                        if (expr_inner[epos] == '+') {
                            epos += 1;
                            while (epos < expr_inner.len and expr_inner[epos] == ' ') epos += 1;
                        } else if (expr_inner[epos] == '-') {
                            term_sign = '-';
                            epos += 1;
                            while (epos < expr_inner.len and expr_inner[epos] == ' ') epos += 1;
                        }
                    }
                    const tstart = epos;
                    var nest: usize = 0;
                    while (epos < expr_inner.len) {
                        if (expr_inner[epos] == '(') nest += 1
                        else if (expr_inner[epos] == ')') { if (nest > 0) nest -= 1; }
                        else if (nest == 0 and epos > tstart and
                            (expr_inner[epos] == '+' or (expr_inner[epos] == '-' and epos > 0 and expr_inner[epos - 1] == ' ')))
                            break;
                        epos += 1;
                    }
                    const term = std.mem.trim(u8, expr_inner[tstart..epos], " ");
                    if (term.len == 0) continue;
                    if (!first_term) {
                        if (exp_pos + 3 >= exp_buf.len) return null;
                        exp_buf[exp_pos] = ' ';
                        exp_buf[exp_pos + 1] = term_sign;
                        exp_buf[exp_pos + 2] = ' ';
                        exp_pos += 3;
                    }
                    if (exp_pos + term.len + 3 + divisor_str.len >= exp_buf.len) return null;
                    @memcpy(exp_buf[exp_pos..][0..term.len], term);
                    exp_pos += term.len;
                    @memcpy(exp_buf[exp_pos..][0..3], " / ");
                    exp_pos += 3;
                    @memcpy(exp_buf[exp_pos..][0..divisor_str.len], divisor_str);
                    exp_pos += divisor_str.len;
                    first_term = false;
                }
                if (exp_pos + 1 > exp_buf.len) return null;
                exp_buf[exp_pos] = ')';
                exp_pos += 1;
                return canonicalizeCalcValue(exp_buf[0..exp_pos], buf);
            }
        }
    }

    return null;
}

pub fn findMatchingParen(s: []const u8, start: usize) ?usize {
    if (start >= s.len or s[start] != '(') return null;
    var depth: usize = 0;
    for (s[start..], start..) |ch, i| {
        if (ch == '(') depth += 1
        else if (ch == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

/// Evaluate a calc expression for serialization, preserving NaN/infinity.
/// Only handles pure-number expressions (no units).
fn evalCalcForSerialize(expr: []const u8) ?f64 {
    return evalCalcExprSerialize(expr, 0);
}

fn evalCalcExprSerialize(expr: []const u8, depth: u32) ?f64 {
    if (depth > 10) return null;
    const s = std.mem.trim(u8, expr, " \t");
    if (s.len == 0) return null;

    // Strip outer parens
    if (s[0] == '(' and s[s.len - 1] == ')') {
        var pd: usize = 0;
        var all_wrapped = true;
        for (s, 0..) |ch, i| {
            if (ch == '(') pd += 1 else if (ch == ')') pd -= 1;
            if (pd == 0 and i < s.len - 1) { all_wrapped = false; break; }
        }
        if (all_wrapped) return evalCalcExprSerialize(s[1 .. s.len - 1], depth + 1);
    }

    // Find last + or - at depth 0 (lowest precedence)
    var paren_depth: usize = 0;
    var last_add_sub: ?usize = null;
    var last_mul_div: ?usize = null;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '(') { paren_depth += 1; continue; }
        if (s[i] == ')') { if (paren_depth > 0) paren_depth -= 1; continue; }
        if (paren_depth == 0 and i > 0 and i + 1 < s.len and s[i - 1] == ' ' and s[i + 1] == ' ') {
            if (s[i] == '+' or s[i] == '-') last_add_sub = i;
        }
        if (paren_depth == 0 and (s[i] == '*' or s[i] == '/') and i > 0 and i + 1 < s.len) {
            last_mul_div = i;
        }
    }

    if (last_add_sub) |pos| {
        const l = evalCalcExprSerialize(s[0 .. pos - 1], depth + 1) orelse return null;
        const r = evalCalcExprSerialize(s[pos + 2 ..], depth + 1) orelse return null;
        return if (s[pos] == '+') l + r else l - r;
    }
    if (last_mul_div) |pos| {
        const l = evalCalcExprSerialize(s[0..pos], depth + 1) orelse return null;
        const r = evalCalcExprSerialize(s[pos + 1 ..], depth + 1) orelse return null;
        return if (s[pos] == '*') l * r else l / r; // IEEE 754: x/0 = ±inf
    }

    // Atom
    if (std.ascii.eqlIgnoreCase(s, "infinity")) return std.math.inf(f64);
    if (std.ascii.eqlIgnoreCase(s, "-infinity")) return -std.math.inf(f64);
    if (std.ascii.eqlIgnoreCase(s, "NaN") or std.ascii.eqlIgnoreCase(s, "nan")) return std.math.nan(f64);
    if (std.ascii.eqlIgnoreCase(s, "pi")) return std.math.pi;
    if (std.ascii.eqlIgnoreCase(s, "e")) return std.math.e;
    return std.fmt.parseFloat(f64, s) catch null;
}

fn containsInfNanKeyword(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (i + 8 <= s.len and std.ascii.eqlIgnoreCase(s[i..][0..8], "infinity")) return true;
        if (i + 3 <= s.len and std.ascii.eqlIgnoreCase(s[i..][0..3], "NaN")) return true;
        if (i + 3 <= s.len and std.ascii.eqlIgnoreCase(s[i..][0..3], "nan")) return true;
    }
    return false;
}

pub fn containsFunction(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "min(") != null or
        std.mem.indexOf(u8, s, "max(") != null or
        std.mem.indexOf(u8, s, "clamp(") != null;
}

/// Canonicalize a calc() expression per CSS Values 4 §11.3:
/// 1. Convert absolute length units (in, cm, mm, pt, pc, q) to px
/// 2. Combine terms with the same unit
/// 3. Reorder: numbers, %, then dimensions by unit (ASCII)
/// 4. Serialize with canonical sign handling
pub fn canonicalizeCalcValue(val: []const u8, buf: *[512]u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, val, " \t\r\n");
    if (trimmed.len < 6) return null;
    if (!eqlIgnoreCase(trimmed[0..5], "calc(")) return null;
    if (trimmed[trimmed.len - 1] != ')') return null;
    const raw_inner = std.mem.trim(u8, trimmed[5 .. trimmed.len - 1], " ");
    if (raw_inner.len == 0) return null;

    // Early simplification: if expression contains infinity/NaN keywords,
    // try to evaluate and simplify to calc(NaN) or calc(infinity)
    if (containsInfNanKeyword(raw_inner)) {
        if (evalCalcForSerialize(raw_inner)) |v| {
            if (std.math.isNan(v)) {
                const r = std.fmt.bufPrint(buf, "calc(NaN)", .{}) catch return null;
                return r;
            }
            if (std.math.isInf(v)) {
                if (v > 0) {
                    const r = std.fmt.bufPrint(buf, "calc(infinity)", .{}) catch return null;
                    return r;
                } else {
                    const r = std.fmt.bufPrint(buf, "calc(-infinity)", .{}) catch return null;
                    return r;
                }
            }
        }
    }

    // Flatten nested calc(): "9pt + calc(9rem + 10px)" → "9pt + 9rem + 10px"
    // Removes "calc(" and its matching ")" while preserving min()/max() parens.
    var flat_buf: [512]u8 = undefined;
    var flat_pos: usize = 0;
    {
        var k: usize = 0;
        var calc_depth: usize = 0; // track nesting of stripped calc() parens
        var paren_depth: [16]usize = undefined; // paren depth at each calc strip
        while (k < raw_inner.len) {
            if (k + 5 <= raw_inner.len and eqlIgnoreCase(raw_inner[k..][0..5], "calc(")) {
                // Strip this calc( — record current paren nesting to find matching )
                if (calc_depth < 16) {
                    // Count how deep in parens we are at this point in flat output
                    var depth: usize = 0;
                    for (flat_buf[0..flat_pos]) |ch| {
                        if (ch == '(') depth += 1 else if (ch == ')') {
                            if (depth > 0) depth -= 1;
                        }
                    }
                    paren_depth[calc_depth] = depth;
                    calc_depth += 1;
                }
                k += 5; // skip "calc("
            } else if (raw_inner[k] == ')' and calc_depth > 0) {
                // Check if this ) matches a stripped calc(
                var depth: usize = 0;
                for (flat_buf[0..flat_pos]) |ch| {
                    if (ch == '(') depth += 1 else if (ch == ')') {
                        if (depth > 0) depth -= 1;
                    }
                }
                if (depth == paren_depth[calc_depth - 1]) {
                    // This ) matches the stripped calc( — skip it
                    calc_depth -= 1;
                    k += 1;
                } else {
                    // This ) belongs to something else (min/max) — keep it
                    if (flat_pos < flat_buf.len) {
                        flat_buf[flat_pos] = raw_inner[k];
                        flat_pos += 1;
                    }
                    k += 1;
                }
            } else {
                if (flat_pos < flat_buf.len) {
                    flat_buf[flat_pos] = raw_inner[k];
                    flat_pos += 1;
                }
                k += 1;
            }
        }
    }
    const inner = std.mem.trim(u8, flat_buf[0..flat_pos], " ");
    if (inner.len == 0) return null;

    // Distributive expansion: "N * (A + B)" → "N*A + N*B", "(A + B) / N" → "A/N + B/N"
    // Also handle scalar reordering: "(expr) * N" → "N * (expr)" when expr contains functions
    if (tryDistributiveExpansion(inner, buf)) |expanded| return expanded;

    // Parsed term: numeric value + canonical unit
    const CalcTerm = struct { value: f64, unit: []const u8 };
    var terms: [32]CalcTerm = undefined;
    var term_count: usize = 0;
    // Per-term unit buffers (each term may need its own lowercased unit)
    var unit_bufs: [32][16]u8 = undefined;
    var pos: usize = 0;

    while (pos < inner.len and term_count < 32) {
        while (pos < inner.len and (inner[pos] == ' ' or inner[pos] == '\t')) pos += 1;
        if (pos >= inner.len) break;

        // Detect operator sign
        var sign: f64 = 1.0;
        if (inner[pos] == '+') {
            pos += 1;
            while (pos < inner.len and inner[pos] == ' ') pos += 1;
        } else if (inner[pos] == '-') {
            sign = -1.0;
            pos += 1;
            while (pos < inner.len and inner[pos] == ' ') pos += 1;
        }

        // Read term (stop at next + or - with space before it)
        const term_start = pos;
        var nesting: usize = 0;
        while (pos < inner.len) {
            if (inner[pos] == '(') nesting += 1
            else if (inner[pos] == ')') { if (nesting > 0) nesting -= 1; }
            else if (nesting == 0 and pos > term_start and
                (inner[pos] == '+' or (inner[pos] == '-' and pos > 0 and inner[pos - 1] == ' ')))
                break;
            pos += 1;
        }
        const term_str = std.mem.trimRight(u8, inner[term_start..pos], " ");
        if (term_str.len == 0) continue;

        // Can't canonicalize nested functions (but allow * and / within a term)
        var has_paren = false;
        for (term_str) |ch| {
            if (ch == '(') { has_paren = true; break; }
        }
        if (has_paren) return null;

        // Handle multiplication/division within a term: "4 * 3px", "4pc / 8"
        var num_val: f64 = undefined;
        var raw_unit: []const u8 = undefined;
        if (std.mem.indexOf(u8, term_str, " * ")) |mul_pos| {
            // scalar * dimension OR dimension * scalar
            const left = std.mem.trim(u8, term_str[0..mul_pos], " ");
            const right_s = std.mem.trim(u8, term_str[mul_pos + 3 ..], " ");
            const lp = parseNumUnit(left);
            const rp = parseNumUnit(right_s);
            if (lp == null or rp == null) return null;
            if (lp.?.unit.len == 0 and rp.?.unit.len > 0) {
                num_val = lp.?.value * rp.?.value;
                raw_unit = rp.?.unit;
            } else if (lp.?.unit.len > 0 and rp.?.unit.len == 0) {
                num_val = lp.?.value * rp.?.value;
                raw_unit = lp.?.unit;
            } else return null; // both have units or both unitless — can't simplify
        } else if (std.mem.indexOf(u8, term_str, " / ")) |div_pos| {
            // dimension / scalar
            const left = std.mem.trim(u8, term_str[0..div_pos], " ");
            const right_s = std.mem.trim(u8, term_str[div_pos + 3 ..], " ");
            const lp = parseNumUnit(left);
            const rp = parseNumUnit(right_s);
            if (lp == null or rp == null) return null;
            if (rp.?.unit.len > 0) return null; // division by dimension
            if (@abs(rp.?.value) < 1e-20) return null; // div by zero
            num_val = lp.?.value / rp.?.value;
            raw_unit = lp.?.unit;
        } else {
            // Simple number+unit
            const p = parseNumUnit(term_str) orelse return null;
            num_val = p.value;
            raw_unit = p.unit;
        }
        const value = sign * num_val;

        // Convert absolute units to px
        const unit_lower = blk: {
            var ubuf: [16]u8 = undefined;
            for (raw_unit, 0..) |ch, k| {
                if (k >= 16) break;
                ubuf[k] = std.ascii.toLower(ch);
            }
            break :blk ubuf[0..@min(raw_unit.len, 16)];
        };
        var final_value = value;
        var final_unit: []const u8 = raw_unit;
        if (std.mem.eql(u8, unit_lower, "in")) {
            final_value = value * 96.0;
            final_unit = "px";
        } else if (std.mem.eql(u8, unit_lower, "cm")) {
            final_value = value * (96.0 / 2.54);
            final_unit = "px";
        } else if (std.mem.eql(u8, unit_lower, "mm")) {
            final_value = value * (96.0 / 25.4);
            final_unit = "px";
        } else if (std.mem.eql(u8, unit_lower, "q")) {
            final_value = value * (96.0 / 101.6);
            final_unit = "px";
        } else if (std.mem.eql(u8, unit_lower, "pt")) {
            final_value = value * (96.0 / 72.0);
            final_unit = "px";
        } else if (std.mem.eql(u8, unit_lower, "pc")) {
            final_value = value * 16.0;
            final_unit = "px";
        } else {
            // Lowercase the unit for canonical form — use per-term buffer
            for (raw_unit, 0..) |ch, k| {
                if (k >= 16) break;
                unit_bufs[term_count][k] = std.ascii.toLower(ch);
            }
            final_unit = unit_bufs[term_count][0..@min(raw_unit.len, 16)];
        }

        // Try to combine with existing term of same unit
        var combined = false;
        for (0..term_count) |k| {
            if (std.mem.eql(u8, terms[k].unit, final_unit)) {
                terms[k].value += final_value;
                combined = true;
                break;
            }
        }
        if (!combined) {
            terms[term_count] = .{ .value = final_value, .unit = final_unit };
            term_count += 1;
        }
    }

    if (term_count == 0) return null;

    // Sort: unitless (0), % (1), dimensions by unit ASCII (2+)
    var indices: [32]usize = undefined;
    for (0..term_count) |k| indices[k] = k;
    var i: usize = 1;
    while (i < term_count) : (i += 1) {
        var j = i;
        while (j > 0) {
            const a_u = terms[indices[j - 1]].unit;
            const b_u = terms[indices[j]].unit;
            if (calcUnitCmp(a_u, b_u) <= 0) break;
            const tmp = indices[j];
            indices[j] = indices[j - 1];
            indices[j - 1] = tmp;
            j -= 1;
        }
    }

    // Serialize
    var out: usize = 0;
    const pfx = "calc(";
    @memcpy(buf[out..][0..pfx.len], pfx);
    out += pfx.len;

    for (0..term_count) |idx| {
        const t = terms[indices[idx]];
        const is_neg = t.value < -1e-10;
        const abs_val = @abs(t.value);

        if (idx == 0) {
            if (is_neg) {
                buf[out] = '-';
                out += 1;
            }
        } else {
            if (is_neg) {
                @memcpy(buf[out..][0..3], " - ");
                out += 3;
            } else {
                @memcpy(buf[out..][0..3], " + ");
                out += 3;
            }
        }

        // Format number: integer if possible, else float
        const formatted = fmtCalcNum(abs_val, buf[out..][0..64]) orelse return null;
        out += formatted.len;

        // Unit
        if (out + t.unit.len >= buf.len) return null;
        @memcpy(buf[out..][0..t.unit.len], t.unit);
        out += t.unit.len;
    }

    buf[out] = ')';
    out += 1;
    return buf[0..out];
}

/// Parse a simple "number+unit" string into value and unit.
pub fn parseNumUnit(s: []const u8) ?struct { value: f64, unit: []const u8 } {
    var ne: usize = 0;
    if (ne < s.len and (s[ne] == '-' or s[ne] == '+')) ne += 1;
    while (ne < s.len and (s[ne] >= '0' and s[ne] <= '9' or s[ne] == '.')) ne += 1;
    if (ne == 0) return null;
    const v = std.fmt.parseFloat(f64, s[0..ne]) catch return null;
    return .{ .value = v, .unit = s[ne..] };
}

pub fn fmtCalcNum(val: f64, out: []u8) ?[]const u8 {
    // Integer if no fractional part
    const rounded = @round(val);
    if (@abs(val - rounded) < 1e-6) {
        const int_val: i64 = @intFromFloat(rounded);
        const n = std.fmt.bufPrint(out, "{d}", .{int_val}) catch return null;
        return n;
    }
    // Float, trim trailing zeros
    const n = std.fmt.bufPrint(out, "{d:.6}", .{val}) catch return null;
    var end = n.len;
    while (end > 0 and out[end - 1] == '0') end -= 1;
    if (end > 0 and out[end - 1] == '.') end -= 1;
    return out[0..end];
}

pub fn calcUnitCmp(a: []const u8, b: []const u8) i32 {
    const a_rank = calcUnitRank(a);
    const b_rank = calcUnitRank(b);
    if (a_rank < b_rank) return -1;
    if (a_rank > b_rank) return 1;
    const max_len = @max(a.len, b.len);
    for (0..max_len) |k| {
        const ac: u8 = if (k < a.len) std.ascii.toLower(a[k]) else 0;
        const bc: u8 = if (k < b.len) std.ascii.toLower(b[k]) else 0;
        if (ac < bc) return -1;
        if (ac > bc) return 1;
    }
    return 0;
}

pub fn calcUnitRank(unit: []const u8) u8 {
    if (unit.len == 0) return 0;
    if (std.mem.eql(u8, unit, "%")) return 1;
    return 2;
}

/// Simplify single-argument min()/max() to the bare value: min(1px) → calc(1px), min(1%) → 1%
/// Also converts absolute units: min(1in) → calc(96px)
pub fn canonicalizeSingleArgMath(val: []const u8, buf: *[512]u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, val, " \t\r\n");
    if (trimmed[trimmed.len - 1] != ')') return null;
    // Extract inner content
    var prefix_len: usize = 0;
    if (trimmed.len >= 4 and eqlIgnoreCase(trimmed[0..4], "min(")) prefix_len = 4
    else if (trimmed.len >= 4 and eqlIgnoreCase(trimmed[0..4], "max(")) prefix_len = 4
    else return null;
    const inner = std.mem.trim(u8, trimmed[prefix_len .. trimmed.len - 1], " ");
    // Check: single argument (no commas at top level)
    var nesting: usize = 0;
    for (inner) |ch| {
        if (ch == '(') nesting += 1
        else if (ch == ')') { if (nesting > 0) nesting -= 1; }
        else if (ch == ',' and nesting == 0) return null; // multi-arg
    }

    // Wrap as calc() and canonicalize
    var tmp_buf: [512]u8 = undefined;
    const calc_str = std.fmt.bufPrint(&tmp_buf, "calc({s})", .{inner}) catch return null;
    return canonicalizeCalcValue(calc_str, buf);
}

/// Simplify constant clamp(): clamp(1px, 2px, 3px) → calc(2px) when all args are same-unit constants
pub fn canonicalizeClamp(val: []const u8, buf: *[512]u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, val, " \t\r\n");
    if (trimmed.len < 7) return null;
    if (!eqlIgnoreCase(trimmed[0..6], "clamp(")) return null;
    if (trimmed[trimmed.len - 1] != ')') return null;
    const inner = std.mem.trim(u8, trimmed[6 .. trimmed.len - 1], " ");
    // Split on commas (top-level only)
    var args: [3][]const u8 = undefined;
    var arg_count: usize = 0;
    var start: usize = 0;
    var nesting: usize = 0;
    for (inner, 0..) |ch, k| {
        if (ch == '(') nesting += 1
        else if (ch == ')') { if (nesting > 0) nesting -= 1; }
        else if (ch == ',' and nesting == 0) {
            if (arg_count >= 3) return null;
            args[arg_count] = std.mem.trim(u8, inner[start..k], " ");
            arg_count += 1;
            start = k + 1;
        }
    }
    if (arg_count < 2) return null;
    args[arg_count] = std.mem.trim(u8, inner[start..], " ");
    arg_count += 1;
    if (arg_count != 3) return null;

    // Parse each arg as number+unit
    const parsed = struct {
        fn parse(s: []const u8) ?struct { value: f64, unit: []const u8 } {
            var ne: usize = 0;
            if (ne < s.len and (s[ne] == '-' or s[ne] == '+')) ne += 1;
            while (ne < s.len and (s[ne] >= '0' and s[ne] <= '9' or s[ne] == '.')) ne += 1;
            if (ne == 0) return null;
            const v = std.fmt.parseFloat(f64, s[0..ne]) catch return null;
            return .{ .value = v, .unit = s[ne..] };
        }
    };
    const min_arg = parsed.parse(args[0]) orelse return null;
    const val_arg = parsed.parse(args[1]) orelse return null;
    const max_arg = parsed.parse(args[2]) orelse return null;
    // All same unit
    if (!std.mem.eql(u8, min_arg.unit, val_arg.unit) or !std.mem.eql(u8, val_arg.unit, max_arg.unit)) return null;
    // Evaluate: clamp(min, val, max) = max(min, min(val, max))
    const result = @max(min_arg.value, @min(val_arg.value, max_arg.value));
    // Convert absolute units
    var calc_str_buf: [128]u8 = undefined;
    const calc_str = std.fmt.bufPrint(&calc_str_buf, "calc({d}{s})", .{ result, min_arg.unit }) catch return null;
    return canonicalizeCalcValue(calc_str, buf);
}

pub fn isValidMarginTrimValue(val: []const u8) bool {
    const single_keywords = [_][]const u8{ "none", "block", "inline", "block-start", "block-end", "inline-start", "inline-end" };
    for (single_keywords) |kw| {
        if (eqlIgnoreCase(val, kw)) return true;
    }
    // Multi-value parsing
    var has_block_sh = false; // "block" shorthand
    var has_inline_sh = false; // "inline" shorthand
    var has_individual = false;
    var bs = false;
    var be = false;
    var is_ = false;
    var ie = false;
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < val.len) {
        while (pos < val.len and (val[pos] == ' ' or val[pos] == '\t')) pos += 1;
        if (pos >= val.len) break;
        const start = pos;
        while (pos < val.len and val[pos] != ' ' and val[pos] != '\t') pos += 1;
        const kw = val[start..pos];
        count += 1;
        if (count > 4) return false;
        if (eqlIgnoreCase(kw, "block")) {
            if (has_block_sh) return false; // "block block"
            has_block_sh = true;
        } else if (eqlIgnoreCase(kw, "inline")) {
            if (has_inline_sh) return false; // "inline inline"
            has_inline_sh = true;
        } else if (eqlIgnoreCase(kw, "block-start")) {
            if (bs) return false;
            bs = true;
            has_individual = true;
        } else if (eqlIgnoreCase(kw, "block-end")) {
            if (be) return false;
            be = true;
            has_individual = true;
        } else if (eqlIgnoreCase(kw, "inline-start")) {
            if (is_) return false;
            is_ = true;
            has_individual = true;
        } else if (eqlIgnoreCase(kw, "inline-end")) {
            if (ie) return false;
            ie = true;
            has_individual = true;
        } else {
            return false;
        }
    }
    // "block"/"inline" can combine with each other but NOT with individual keywords
    if ((has_block_sh or has_inline_sh) and has_individual) return false;
    return count >= 2;
}

pub fn isValidOverflowShorthand(val: []const u8) bool {
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < val.len) {
        while (pos < val.len and (val[pos] == ' ' or val[pos] == '\t')) pos += 1;
        if (pos >= val.len) break;
        const start = pos;
        while (pos < val.len and val[pos] != ' ' and val[pos] != '\t') pos += 1;
        const part = val[start..pos];
        count += 1;
        if (count > 2) return false;
        if (!eqlIgnoreCase(part, "visible") and !eqlIgnoreCase(part, "hidden") and
            !eqlIgnoreCase(part, "scroll") and !eqlIgnoreCase(part, "auto") and
            !eqlIgnoreCase(part, "clip")) return false;
    }
    return count >= 1 and count <= 2;
}

pub fn isValidOverflowValue(val: []const u8) bool {
    return eqlIgnoreCase(val, "visible") or eqlIgnoreCase(val, "hidden") or
        eqlIgnoreCase(val, "scroll") or eqlIgnoreCase(val, "auto") or
        eqlIgnoreCase(val, "clip");
}

pub fn isValidMaxSizeValue(val: []const u8) bool {
    // max-width/max-height: accept none, lengths (non-negative), %, min/max/fit-content but NOT auto
    if (eqlIgnoreCase(val, "none")) return true;
    if (eqlIgnoreCase(val, "min-content") or eqlIgnoreCase(val, "max-content") or
        eqlIgnoreCase(val, "fit-content")) return true;
    if (val.len > 12 and eqlIgnoreCase(val[0..12], "fit-content(")) return true;
    return isValidNonNegLength(val);
}

pub fn isValidSizeValue(val: []const u8, allow_none: bool) bool {
    if (eqlIgnoreCase(val, "auto")) return true;
    if (allow_none and eqlIgnoreCase(val, "none")) return true;
    if (eqlIgnoreCase(val, "min-content") or eqlIgnoreCase(val, "max-content") or
        eqlIgnoreCase(val, "fit-content")) return true;
    // fit-content(length)
    if (val.len > 12 and eqlIgnoreCase(val[0..12], "fit-content(")) return true;
    return isValidNonNegLength(val);
}

pub fn isValidNonNegLength(val: []const u8) bool {
    if (css_properties.parseLength(val)) |len| {
        return len.value >= 0;
    }
    return false;
}

pub fn isValidMarginValue(val: []const u8) bool {
    if (eqlIgnoreCase(val, "auto")) return true;
    return css_properties.parseLength(val) != null;
}

pub fn isValidBorderWidth(val: []const u8) bool {
    if (eqlIgnoreCase(val, "thin") or eqlIgnoreCase(val, "medium") or eqlIgnoreCase(val, "thick")) return true;
    return isValidNonNegLength(val);
}

/// Canonicalize a color keyword to lowercase for system colors / currentcolor.
pub fn canonicalizeColorKeyword(val: []const u8, buf: []u8) ?[]const u8 {
    // System colors: canonicalize to lowercase
    const system_colors = [_][]const u8{
        "activetext", "buttonborder", "buttonface", "buttontext", "canvas",
        "canvastext", "field", "fieldtext", "graytext", "highlight",
        "highlighttext", "linktext", "mark", "marktext", "selecteditem",
        "selecteditemtext", "accentcolor", "accentcolortext", "visitedtext",
    };
    for (system_colors) |sc| {
        if (eqlIgnoreCase(val, sc)) {
            if (sc.len <= buf.len) {
                @memcpy(buf[0..sc.len], sc);
                return buf[0..sc.len];
            }
        }
    }
    // currentcolor → currentcolor
    if (eqlIgnoreCase(val, "currentcolor") or eqlIgnoreCase(val, "currentColor")) {
        const s = "currentcolor";
        @memcpy(buf[0..s.len], s);
        return buf[0..s.len];
    }
    return null;
}

/// Canonicalize color-scheme: move "only" to the end.
pub fn canonicalizeColorScheme(val: []const u8, buf: []u8) ?[]const u8 {
    // "only light dark" → "light dark only"
    const trimmed = std.mem.trim(u8, val, " \t");
    if (trimmed.len < 5) return null;
    // Check if starts with "only "
    if (eqlIgnoreCase(trimmed[0..5], "only ")) {
        const rest = std.mem.trim(u8, trimmed[5..], " \t");
        if (rest.len == 0) return null;
        const needed = rest.len + 5; // "rest only"
        if (needed > buf.len) return null;
        @memcpy(buf[0..rest.len], rest);
        buf[rest.len] = ' ';
        @memcpy(buf[rest.len + 1 ..][0..4], "only");
        return buf[0..needed];
    }
    return null;
}

pub fn isValidColorKeyword(val: []const u8) bool {
    if (eqlIgnoreCase(val, "transparent") or eqlIgnoreCase(val, "currentcolor") or eqlIgnoreCase(val, "currentColor")) return true;
    // CSS system colors
    const system_colors = [_][]const u8{
        "ActiveText", "ButtonBorder", "ButtonFace", "ButtonText", "Canvas",
        "CanvasText", "Field", "FieldText", "GrayText", "Highlight",
        "HighlightText", "LinkText", "Mark", "MarkText", "SelectedItem",
        "SelectedItemText", "AccentColor", "AccentColorText", "VisitedText",
    };
    for (system_colors) |sc| {
        if (eqlIgnoreCase(val, sc)) return true;
    }
    return false;
}

/// Check if value is a color function containing calc() that parseColor can't handle yet
/// but should still be accepted as valid (e.g., rgb(calc(50 + sign(1em)), 0, 0)).
fn isColorFuncWithCalc(val: []const u8) bool {
    if (val.len < 4) return false;
    // Must be a known color function
    const is_color_fn = (val.len >= 4 and eqlIgnoreCase(val[0..4], "rgb(")) or
        (val.len >= 5 and eqlIgnoreCase(val[0..5], "rgba(")) or
        (val.len >= 4 and eqlIgnoreCase(val[0..4], "hsl(")) or
        (val.len >= 5 and eqlIgnoreCase(val[0..5], "hsla(")) or
        (val.len >= 4 and eqlIgnoreCase(val[0..4], "hwb(")) or
        (val.len >= 5 and eqlIgnoreCase(val[0..5], "lab(")) or
        (val.len >= 5 and eqlIgnoreCase(val[0..5], "lch(")) or
        (val.len >= 6 and eqlIgnoreCase(val[0..6], "oklab(")) or
        (val.len >= 6 and eqlIgnoreCase(val[0..6], "oklch(")) or
        (val.len >= 6 and eqlIgnoreCase(val[0..6], "color("));
    if (!is_color_fn) return false;
    // Must end with ')'
    if (val[val.len - 1] != ')') return false;
    // Must contain calc( inside
    var i: usize = 0;
    while (i + 5 <= val.len) : (i += 1) {
        if (eqlIgnoreCase(val[i..][0..5], "calc(")) return true;
    }
    return false;
}

pub fn isNonNegNumber(val: []const u8) bool {
    const n = std.fmt.parseFloat(f32, val) catch return false;
    return n >= 0;
}

pub fn isValidFontSize(val: []const u8) bool {
    // Keywords
    const kws = [_][]const u8{ "xx-small", "x-small", "small", "medium", "large", "x-large", "xx-large", "xxx-large", "smaller", "larger" };
    for (kws) |kw| {
        if (eqlIgnoreCase(val, kw)) return true;
    }
    return isValidNonNegLength(val);
}

pub fn isValidFontWeight(val: []const u8) bool {
    if (eqlIgnoreCase(val, "normal") or eqlIgnoreCase(val, "bold") or
        eqlIgnoreCase(val, "bolder") or eqlIgnoreCase(val, "lighter")) return true;
    const n = std.fmt.parseFloat(f32, val) catch return false;
    return n >= 1 and n <= 1000;
}

pub fn isValidLineHeight(val: []const u8) bool {
    if (eqlIgnoreCase(val, "normal")) return true;
    // Non-negative number (unitless)
    if (std.fmt.parseFloat(f32, val)) |n| {
        return n >= 0;
    } else |_| {}
    return isValidNonNegLength(val);
}
