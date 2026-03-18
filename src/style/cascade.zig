const std = @import("std");
const css = @import("../bindings/css.zig").c;
const lxb = @import("../bindings/lexbor.zig").c;
const DomNode = @import("../dom/node.zig").DomNode;
const ComputedStyle = @import("computed.zig").ComputedStyle;
const select_handler = @import("select.zig");

/// CSS fixed-point (22:10) to f32.
fn fixedToF32(v: css.css_fixed) f32 {
    return @as(f32, @floatFromInt(v)) / @as(f32, 1024.0);
}

/// CSS INTTOFIX equivalent.
fn intToFixed(a: i32) css.css_fixed {
    const v: i64 = @as(i64, a) * (1 << 10);
    if (v < std.math.minInt(i32)) return std.math.minInt(i32);
    if (v > std.math.maxInt(i32)) return std.math.maxInt(i32);
    return @intCast(v);
}

/// URL resolution callback — just copies the URL as-is.
fn resolveUrl(_: ?*anyopaque, _: [*c]const u8, rel: ?*css.lwc_string, abs: ?*?*css.lwc_string) callconv(.c) css.css_error {
    const out = abs orelse return css.CSS_BADPARM;
    if (rel) |r| {
        out.* = css.lwc_string_ref(r);
    } else {
        out.* = null;
    }
    return css.CSS_OK;
}

/// Map css_display_e to our Display enum.
fn mapDisplay(val: u8) ComputedStyle.Display {
    return switch (val) {
        css.CSS_DISPLAY_BLOCK => .block,
        css.CSS_DISPLAY_INLINE => .inline_,
        css.CSS_DISPLAY_NONE => .none,
        css.CSS_DISPLAY_FLEX => .flex,
        css.CSS_DISPLAY_INLINE_FLEX => .inline_flex,
        css.CSS_DISPLAY_INLINE_BLOCK => .inline_block,
        css.CSS_DISPLAY_TABLE => .table,
        css.CSS_DISPLAY_LIST_ITEM => .list_item,
        css.CSS_DISPLAY_GRID => .grid,
        css.CSS_DISPLAY_INLINE_GRID => .inline_grid,
        css.CSS_DISPLAY_TABLE_ROW => .table_row,
        css.CSS_DISPLAY_TABLE_CELL => .table_cell,
        css.CSS_DISPLAY_TABLE_ROW_GROUP => .table_row_group,
        css.CSS_DISPLAY_TABLE_HEADER_GROUP => .table_header_group,
        css.CSS_DISPLAY_TABLE_FOOTER_GROUP => .table_footer_group,
        css.CSS_DISPLAY_TABLE_COLUMN => .table_column,
        css.CSS_DISPLAY_TABLE_COLUMN_GROUP => .table_column_group,
        css.CSS_DISPLAY_TABLE_CAPTION => .table_caption,
        else => .other,
    };
}

/// Map css_font_weight_e to numeric weight.
fn mapFontWeight(val: u8) u16 {
    return switch (val) {
        css.CSS_FONT_WEIGHT_NORMAL, css.CSS_FONT_WEIGHT_400 => 400,
        css.CSS_FONT_WEIGHT_BOLD, css.CSS_FONT_WEIGHT_700 => 700,
        css.CSS_FONT_WEIGHT_100 => 100,
        css.CSS_FONT_WEIGHT_200 => 200,
        css.CSS_FONT_WEIGHT_300 => 300,
        css.CSS_FONT_WEIGHT_500 => 500,
        css.CSS_FONT_WEIGHT_600 => 600,
        css.CSS_FONT_WEIGHT_800 => 800,
        css.CSS_FONT_WEIGHT_900 => 900,
        else => 400,
    };
}

/// Extract a length value in px from css_fixed + css_unit.
/// Only handles px and simple units; others fall back to default.
fn lengthToPx(length: css.css_fixed, unit: css.css_unit, default_font_size: f32) f32 {
    return lengthToPxVp(length, unit, default_font_size, 0, 0);
}

/// Extract a length value in px, with viewport dimensions for vw/vh units.
fn lengthToPxVp(length: css.css_fixed, unit: css.css_unit, default_font_size: f32, vw: f32, vh: f32) f32 {
    const val = fixedToF32(length);
    return switch (unit) {
        css.CSS_UNIT_PX => val,
        css.CSS_UNIT_EM => val * default_font_size,
        css.CSS_UNIT_REM => val * default_font_size,
        css.CSS_UNIT_PT => val * (96.0 / 72.0),
        css.CSS_UNIT_PCT => val * default_font_size / 100.0,
        css.CSS_UNIT_CM => val * (96.0 / 2.54),
        css.CSS_UNIT_MM => val * (96.0 / 25.4),
        css.CSS_UNIT_IN => val * 96.0,
        css.CSS_UNIT_VW => val * vw / 100.0,
        css.CSS_UNIT_VH => val * vh / 100.0,
        else => val,
    };
}

/// Convert length to px, using containing_width for percentage resolution.
fn lengthToPxPct(length: css.css_fixed, unit: css.css_unit, default_font_size: f32, containing_width: f32) f32 {
    if (unit == css.CSS_UNIT_PCT) {
        return fixedToF32(length) * containing_width / 100.0;
    }
    return lengthToPx(length, unit, default_font_size);
}

/// Convert length to px, using containing_width for percentage resolution and viewport dims for vw/vh.
fn lengthToPxPctVp(length: css.css_fixed, unit: css.css_unit, default_font_size: f32, containing_width: f32, vw: f32, vh: f32) f32 {
    if (unit == css.CSS_UNIT_PCT) {
        return fixedToF32(length) * containing_width / 100.0;
    }
    return lengthToPxVp(length, unit, default_font_size, vw, vh);
}

/// Check if a border style should be rendered (anything other than none/hidden/inherit).
fn hasBorderStyle(style_val: u8) bool {
    return style_val != css.CSS_BORDER_STYLE_NONE and
        style_val != css.CSS_BORDER_STYLE_HIDDEN and
        style_val != css.CSS_BORDER_STYLE_INHERIT;
}

/// Convert border-width type + value to pixels.
fn borderWidthValue(bw_type: u8, length: css.css_fixed, unit: css.css_unit, default_font_size: f32) f32 {
    return switch (bw_type) {
        css.CSS_BORDER_WIDTH_THIN => 1.0,
        css.CSS_BORDER_WIDTH_MEDIUM => 3.0,
        css.CSS_BORDER_WIDTH_THICK => 5.0,
        css.CSS_BORDER_WIDTH_WIDTH => lengthToPx(length, unit, default_font_size),
        else => 0.0,
    };
}

/// Extract a ComputedStyle from a LibCSS css_computed_style.
fn extractStyle(style: *const css.css_computed_style, is_root: bool) ComputedStyle {
    return extractStyleVp(style, is_root, 0, 0);
}

/// Extract a ComputedStyle with viewport dimensions for vw/vh unit resolution.
fn extractStyleVp(style: *const css.css_computed_style, is_root: bool, vw: f32, vh: f32) ComputedStyle {
    var result = ComputedStyle{};
    const default_font_size: f32 = 16.0;

    // Color (foreground)
    var color: css.css_color = 0;
    const color_type = css.css_computed_color(style, &color);
    if (color_type == css.CSS_COLOR_COLOR) {
        result.color = color;
    }

    // Background color
    var bg_color: css.css_color = 0;
    const bg_type = css.css_computed_background_color(style, &bg_color);
    if (bg_type == css.CSS_BACKGROUND_COLOR_COLOR) {
        result.background_color = bg_color;
    }

    // Font size
    var fs_length: css.css_fixed = 0;
    var fs_unit: css.css_unit = css.CSS_UNIT_PX;
    const fs_type = css.css_computed_font_size(style, &fs_length, &fs_unit);
    if (fs_type == css.CSS_FONT_SIZE_DIMENSION) {
        result.font_size_px = lengthToPx(fs_length, fs_unit, default_font_size);
    }

    // Font weight
    result.font_weight = mapFontWeight(css.css_computed_font_weight(style));

    // Font style
    const font_style_val = css.css_computed_font_style(style);
    result.font_style = switch (font_style_val) {
        css.CSS_FONT_STYLE_ITALIC => .italic,
        css.CSS_FONT_STYLE_OBLIQUE => .oblique,
        else => .normal,
    };

    // Display
    result.display = mapDisplay(css.css_computed_display(style, is_root));

    // Margins (with auto detection)
    var m_len: css.css_fixed = 0;
    var m_unit: css.css_unit = css.CSS_UNIT_PX;
    const mt_type = css.css_computed_margin_top(style, &m_len, &m_unit);
    if (mt_type == css.CSS_MARGIN_SET)
        result.margin_top = lengthToPx(m_len, m_unit, default_font_size);

    const mr_type = css.css_computed_margin_right(style, &m_len, &m_unit);
    if (mr_type == css.CSS_MARGIN_SET)
        result.margin_right = lengthToPx(m_len, m_unit, default_font_size)
    else if (mr_type == css.CSS_MARGIN_AUTO)
        result.margin_right_auto = true;

    const mb_type = css.css_computed_margin_bottom(style, &m_len, &m_unit);
    if (mb_type == css.CSS_MARGIN_SET)
        result.margin_bottom = lengthToPx(m_len, m_unit, default_font_size);

    const ml_type = css.css_computed_margin_left(style, &m_len, &m_unit);
    if (ml_type == css.CSS_MARGIN_SET)
        result.margin_left = lengthToPx(m_len, m_unit, default_font_size)
    else if (ml_type == css.CSS_MARGIN_AUTO)
        result.margin_left_auto = true;

    // Paddings
    var p_len: css.css_fixed = 0;
    var p_unit: css.css_unit = css.CSS_UNIT_PX;
    if (css.css_computed_padding_top(style, &p_len, &p_unit) == css.CSS_PADDING_SET)
        result.padding_top = lengthToPx(p_len, p_unit, default_font_size);
    if (css.css_computed_padding_right(style, &p_len, &p_unit) == css.CSS_PADDING_SET)
        result.padding_right = lengthToPx(p_len, p_unit, default_font_size);
    if (css.css_computed_padding_bottom(style, &p_len, &p_unit) == css.CSS_PADDING_SET)
        result.padding_bottom = lengthToPx(p_len, p_unit, default_font_size);
    if (css.css_computed_padding_left(style, &p_len, &p_unit) == css.CSS_PADDING_SET)
        result.padding_left = lengthToPx(p_len, p_unit, default_font_size);

    // Borders — render for any visible border-style (not none/hidden)
    var b_len: css.css_fixed = 0;
    var b_unit: css.css_unit = css.CSS_UNIT_PX;
    var b_color: css.css_color = 0;

    if (hasBorderStyle(css.css_computed_border_top_style(style))) {
        const bw_type = css.css_computed_border_top_width(style, &b_len, &b_unit);
        result.border_top_width = borderWidthValue(bw_type, b_len, b_unit, default_font_size);
        if (css.css_computed_border_top_color(style, &b_color) == css.CSS_BORDER_COLOR_COLOR) {
            result.border_top_color = b_color;
        }
    }
    if (hasBorderStyle(css.css_computed_border_right_style(style))) {
        const bw_type = css.css_computed_border_right_width(style, &b_len, &b_unit);
        result.border_right_width = borderWidthValue(bw_type, b_len, b_unit, default_font_size);
        if (css.css_computed_border_right_color(style, &b_color) == css.CSS_BORDER_COLOR_COLOR) {
            result.border_right_color = b_color;
        }
    }
    if (hasBorderStyle(css.css_computed_border_bottom_style(style))) {
        const bw_type = css.css_computed_border_bottom_width(style, &b_len, &b_unit);
        result.border_bottom_width = borderWidthValue(bw_type, b_len, b_unit, default_font_size);
        if (css.css_computed_border_bottom_color(style, &b_color) == css.CSS_BORDER_COLOR_COLOR) {
            result.border_bottom_color = b_color;
        }
    }
    if (hasBorderStyle(css.css_computed_border_left_style(style))) {
        const bw_type = css.css_computed_border_left_width(style, &b_len, &b_unit);
        result.border_left_width = borderWidthValue(bw_type, b_len, b_unit, default_font_size);
        if (css.css_computed_border_left_color(style, &b_color) == css.CSS_BORDER_COLOR_COLOR) {
            result.border_left_color = b_color;
        }
    }

    // Text align
    const ta_val = css.css_computed_text_align(style);
    result.text_align = switch (ta_val) {
        css.CSS_TEXT_ALIGN_RIGHT, css.CSS_TEXT_ALIGN_LIBCSS_RIGHT => .right,
        css.CSS_TEXT_ALIGN_CENTER, css.CSS_TEXT_ALIGN_LIBCSS_CENTER => .center,
        css.CSS_TEXT_ALIGN_JUSTIFY => .justify,
        else => .left,
    };

    // Text decoration (bitmask)
    const td_val = css.css_computed_text_decoration(style);
    result.text_decoration = .{
        .underline = (td_val & css.CSS_TEXT_DECORATION_UNDERLINE) != 0,
        .line_through = (td_val & css.CSS_TEXT_DECORATION_LINE_THROUGH) != 0,
        .overline = (td_val & css.CSS_TEXT_DECORATION_OVERLINE) != 0,
    };

    // White space
    const ws_val = css.css_computed_white_space(style);
    result.white_space = switch (ws_val) {
        css.CSS_WHITE_SPACE_PRE => .pre,
        css.CSS_WHITE_SPACE_NOWRAP => .nowrap,
        css.CSS_WHITE_SPACE_PRE_WRAP => .pre_wrap,
        css.CSS_WHITE_SPACE_PRE_LINE => .pre_line,
        else => .normal,
    };

    // Width
    var w_len: css.css_fixed = 0;
    var w_unit: css.css_unit = css.CSS_UNIT_PX;
    const w_type = css.css_computed_width(style, &w_len, &w_unit);
    if (w_type == css.CSS_WIDTH_SET) {
        result.width = if (w_unit == css.CSS_UNIT_PCT)
            .{ .percent = fixedToF32(w_len) }
        else
            .{ .px = lengthToPxVp(w_len, w_unit, default_font_size, vw, vh) };
    }

    // Height
    var h_len: css.css_fixed = 0;
    var h_unit: css.css_unit = css.CSS_UNIT_PX;
    const h_type = css.css_computed_height(style, &h_len, &h_unit);
    if (h_type == css.CSS_HEIGHT_SET) {
        result.height = if (h_unit == css.CSS_UNIT_PCT)
            .{ .percent = fixedToF32(h_len) }
        else
            .{ .px = lengthToPxVp(h_len, h_unit, default_font_size, vw, vh) };
    }

    // Min/max width
    var mw_len: css.css_fixed = 0;
    var mw_unit: css.css_unit = css.CSS_UNIT_PX;
    if (css.css_computed_min_width(style, &mw_len, &mw_unit) == css.CSS_MIN_WIDTH_SET) {
        result.min_width = if (mw_unit == css.CSS_UNIT_PCT)
            .{ .percent = fixedToF32(mw_len) }
        else
            .{ .px = lengthToPxVp(mw_len, mw_unit, default_font_size, vw, vh) };
    }
    if (css.css_computed_max_width(style, &mw_len, &mw_unit) == css.CSS_MAX_WIDTH_SET) {
        result.max_width = if (mw_unit == css.CSS_UNIT_PCT)
            .{ .percent = fixedToF32(mw_len) }
        else
            .{ .px = lengthToPxVp(mw_len, mw_unit, default_font_size, vw, vh) };
    }

    // Min/max height
    var mh_len: css.css_fixed = 0;
    var mh_unit: css.css_unit = css.CSS_UNIT_PX;
    if (css.css_computed_min_height(style, &mh_len, &mh_unit) == css.CSS_MIN_HEIGHT_SET) {
        result.min_height = if (mh_unit == css.CSS_UNIT_PCT)
            .{ .percent = fixedToF32(mh_len) }
        else
            .{ .px = lengthToPxVp(mh_len, mh_unit, default_font_size, vw, vh) };
    }
    if (css.css_computed_max_height(style, &mh_len, &mh_unit) == css.CSS_MAX_HEIGHT_SET) {
        result.max_height = if (mh_unit == css.CSS_UNIT_PCT)
            .{ .percent = fixedToF32(mh_len) }
        else
            .{ .px = lengthToPxVp(mh_len, mh_unit, default_font_size, vw, vh) };
    }

    // Overflow
    const ox_val = css.css_computed_overflow_x(style);
    result.overflow_x = switch (ox_val) {
        css.CSS_OVERFLOW_HIDDEN => .hidden,
        css.CSS_OVERFLOW_SCROLL => .scroll,
        css.CSS_OVERFLOW_AUTO => .auto_,
        else => .visible,
    };
    const oy_val = css.css_computed_overflow_y(style);
    result.overflow_y = switch (oy_val) {
        css.CSS_OVERFLOW_HIDDEN => .hidden,
        css.CSS_OVERFLOW_SCROLL => .scroll,
        css.CSS_OVERFLOW_AUTO => .auto_,
        else => .visible,
    };

    // Position
    const pos_val = css.css_computed_position(style);
    result.position = switch (pos_val) {
        css.CSS_POSITION_RELATIVE => .relative,
        css.CSS_POSITION_ABSOLUTE => .absolute,
        css.CSS_POSITION_FIXED => .fixed,
        css.CSS_POSITION_STICKY => .sticky,
        else => .static_,
    };

    // Position offsets (top, left, right, bottom)
    var pos_len: css.css_fixed = 0;
    var pos_unit: css.css_unit = css.CSS_UNIT_PX;
    if (css.css_computed_top(style, &pos_len, &pos_unit) == css.CSS_TOP_SET) {
        result.top = if (pos_unit == css.CSS_UNIT_PCT) .{ .percent = fixedToF32(pos_len) } else .{ .px = lengthToPx(pos_len, pos_unit, default_font_size) };
    }
    if (css.css_computed_left(style, &pos_len, &pos_unit) == css.CSS_LEFT_SET) {
        result.left = if (pos_unit == css.CSS_UNIT_PCT) .{ .percent = fixedToF32(pos_len) } else .{ .px = lengthToPx(pos_len, pos_unit, default_font_size) };
    }
    if (css.css_computed_right(style, &pos_len, &pos_unit) == css.CSS_RIGHT_SET) {
        result.right = if (pos_unit == css.CSS_UNIT_PCT) .{ .percent = fixedToF32(pos_len) } else .{ .px = lengthToPx(pos_len, pos_unit, default_font_size) };
    }
    if (css.css_computed_bottom(style, &pos_len, &pos_unit) == css.CSS_BOTTOM_SET) {
        result.bottom = if (pos_unit == css.CSS_UNIT_PCT) .{ .percent = fixedToF32(pos_len) } else .{ .px = lengthToPx(pos_len, pos_unit, default_font_size) };
    }

    // z-index
    var zi_val: i32 = 0;
    if (css.css_computed_z_index(style, &zi_val) == css.CSS_Z_INDEX_SET) {
        result.z_index = zi_val;
    }

    // vertical-align
    var va_len: css.css_fixed = 0;
    var va_unit: css.css_unit = css.CSS_UNIT_PX;
    const va_val = css.css_computed_vertical_align(style, &va_len, &va_unit);
    result.vertical_align = switch (va_val) {
        css.CSS_VERTICAL_ALIGN_BASELINE => .baseline,
        css.CSS_VERTICAL_ALIGN_SUB => .sub,
        css.CSS_VERTICAL_ALIGN_SUPER => .super,
        css.CSS_VERTICAL_ALIGN_TOP => .top,
        css.CSS_VERTICAL_ALIGN_TEXT_TOP => .text_top,
        css.CSS_VERTICAL_ALIGN_MIDDLE => .middle,
        css.CSS_VERTICAL_ALIGN_BOTTOM => .bottom,
        css.CSS_VERTICAL_ALIGN_TEXT_BOTTOM => .text_bottom,
        else => .baseline,
    };

    // List style type
    const lst_val = css.css_computed_list_style_type(style);
    result.list_style_type = switch (lst_val) {
        css.CSS_LIST_STYLE_TYPE_DISC => .disc,
        css.CSS_LIST_STYLE_TYPE_CIRCLE => .circle,
        css.CSS_LIST_STYLE_TYPE_SQUARE => .square,
        css.CSS_LIST_STYLE_TYPE_DECIMAL => .decimal,
        css.CSS_LIST_STYLE_TYPE_NONE => .none,
        else => .other,
    };

    // Flexbox properties
    const fd_val = css.css_computed_flex_direction(style);
    result.flex_direction = switch (fd_val) {
        css.CSS_FLEX_DIRECTION_ROW_REVERSE => .row_reverse,
        css.CSS_FLEX_DIRECTION_COLUMN => .column,
        css.CSS_FLEX_DIRECTION_COLUMN_REVERSE => .column_reverse,
        else => .row,
    };

    const fw_val = css.css_computed_flex_wrap(style);
    result.flex_wrap = switch (fw_val) {
        css.CSS_FLEX_WRAP_WRAP => .wrap,
        css.CSS_FLEX_WRAP_WRAP_REVERSE => .wrap_reverse,
        else => .nowrap,
    };

    const jc_val = css.css_computed_justify_content(style);
    result.justify_content = switch (jc_val) {
        css.CSS_JUSTIFY_CONTENT_FLEX_END => .flex_end,
        css.CSS_JUSTIFY_CONTENT_CENTER => .center,
        css.CSS_JUSTIFY_CONTENT_SPACE_BETWEEN => .space_between,
        css.CSS_JUSTIFY_CONTENT_SPACE_AROUND => .space_around,
        css.CSS_JUSTIFY_CONTENT_SPACE_EVENLY => .space_evenly,
        else => .flex_start,
    };

    const ai_val = css.css_computed_align_items(style);
    result.align_items = switch (ai_val) {
        css.CSS_ALIGN_ITEMS_FLEX_START => .flex_start,
        css.CSS_ALIGN_ITEMS_FLEX_END => .flex_end,
        css.CSS_ALIGN_ITEMS_CENTER => .center,
        css.CSS_ALIGN_ITEMS_BASELINE => .baseline,
        else => .stretch,
    };

    var fg_val: css.css_fixed = 0;
    if (css.css_computed_flex_grow(style, &fg_val) == css.CSS_FLEX_GROW_SET) {
        result.flex_grow = fixedToF32(fg_val);
    }

    var fs_val: css.css_fixed = 0;
    if (css.css_computed_flex_shrink(style, &fs_val) == css.CSS_FLEX_SHRINK_SET) {
        result.flex_shrink = fixedToF32(fs_val);
    }

    var fb_len: css.css_fixed = 0;
    var fb_unit: css.css_unit = css.CSS_UNIT_PX;
    const fb_type = css.css_computed_flex_basis(style, &fb_len, &fb_unit);
    if (fb_type == css.CSS_FLEX_BASIS_SET) {
        result.flex_basis = .{ .px = lengthToPx(fb_len, fb_unit, default_font_size) };
    }

    // Gap (column-gap)
    var gap_len: css.css_fixed = 0;
    var gap_unit: css.css_unit = css.CSS_UNIT_PX;
    if (css.css_computed_column_gap(style, &gap_len, &gap_unit) == css.CSS_COLUMN_GAP_SET) {
        result.gap = lengthToPx(gap_len, gap_unit, default_font_size);
    }

    // Float
    const float_val = css.css_computed_float(style);
    result.float_ = switch (float_val) {
        css.CSS_FLOAT_LEFT => .left,
        css.CSS_FLOAT_RIGHT => .right,
        else => .none,
    };

    // Clear
    const clear_val = css.css_computed_clear(style);
    result.clear = switch (clear_val) {
        css.CSS_CLEAR_LEFT => .left,
        css.CSS_CLEAR_RIGHT => .right,
        css.CSS_CLEAR_BOTH => .both,
        else => .none,
    };

    // Box sizing
    const bs_val = css.css_computed_box_sizing(style);
    result.box_sizing = switch (bs_val) {
        css.CSS_BOX_SIZING_BORDER_BOX => .border_box,
        else => .content_box,
    };

    // Visibility
    const vis_val = css.css_computed_visibility(style);
    result.visibility = switch (vis_val) {
        css.CSS_VISIBILITY_HIDDEN => .hidden,
        css.CSS_VISIBILITY_COLLAPSE => .collapse,
        else => .visible,
    };

    // Text transform
    const tt_val = css.css_computed_text_transform(style);
    result.text_transform = switch (tt_val) {
        css.CSS_TEXT_TRANSFORM_CAPITALIZE => .capitalize,
        css.CSS_TEXT_TRANSFORM_UPPERCASE => .uppercase,
        css.CSS_TEXT_TRANSFORM_LOWERCASE => .lowercase,
        else => .none,
    };

    // Letter spacing
    var ls_len: css.css_fixed = 0;
    var ls_unit: css.css_unit = css.CSS_UNIT_PX;
    if (css.css_computed_letter_spacing(style, &ls_len, &ls_unit) == css.CSS_LETTER_SPACING_SET) {
        result.letter_spacing = lengthToPx(ls_len, ls_unit, default_font_size);
    }

    // Line height
    var lh_len: css.css_fixed = 0;
    var lh_unit: css.css_unit = css.CSS_UNIT_PX;
    const lh_type = css.css_computed_line_height(style, &lh_len, &lh_unit);
    if (lh_type == css.CSS_LINE_HEIGHT_DIMENSION) {
        result.line_height = .{ .px = lengthToPx(lh_len, lh_unit, default_font_size) };
    } else if (lh_type == css.CSS_LINE_HEIGHT_NUMBER) {
        result.line_height = .{ .number = fixedToF32(lh_len) };
    }

    // Opacity
    var opacity_val: css.css_fixed = 0;
    if (css.css_computed_opacity(style, &opacity_val) == css.CSS_OPACITY_SET) {
        const op = fixedToF32(opacity_val);
        result.opacity = std.math.clamp(op, 0.0, 1.0);
    }

    return result;
}

/// Parse a CSS length value (e.g. "10px", "1.5em", "50%") from a string slice.
/// Returns the value in pixels, or null if parsing fails.
fn parseCssLength(value: []const u8, default_font_size: f32) ?f32 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;

    // Try to find where the numeric part ends
    var num_end: usize = 0;
    var has_dot = false;
    for (trimmed) |ch| {
        if (ch >= '0' and ch <= '9') {
            num_end += 1;
        } else if (ch == '.' and !has_dot) {
            has_dot = true;
            num_end += 1;
        } else {
            break;
        }
    }
    if (num_end == 0) return null;

    const num = std.fmt.parseFloat(f32, trimmed[0..num_end]) catch return null;
    const unit = std.mem.trim(u8, trimmed[num_end..], " \t");

    if (unit.len == 0 or std.mem.eql(u8, unit, "px")) {
        return num;
    } else if (std.mem.eql(u8, unit, "em") or std.mem.eql(u8, unit, "rem")) {
        return num * default_font_size;
    } else if (std.mem.eql(u8, unit, "pt")) {
        return num * (96.0 / 72.0);
    } else if (std.mem.eql(u8, unit, "%")) {
        // For border-radius, percentage is relative to box size — approximate with font size
        return num * default_font_size / 100.0;
    }
    return num; // fallback: treat as px
}

/// Extract border-radius values from an inline style string.
/// Handles: border-radius: Xpx; and individual corner properties.
fn parseBorderRadius(style_text: []const u8, result: *ComputedStyle) void {
    const default_font_size: f32 = 16.0;

    // Search for "border-radius" in the style text
    var pos: usize = 0;
    while (pos < style_text.len) {
        // Find next "border-" prefix
        const remaining = style_text[pos..];
        const idx = std.mem.indexOf(u8, remaining, "border-") orelse break;
        const start = pos + idx;

        // Check which border-radius property
        const after = style_text[start..];
        if (std.mem.startsWith(u8, after, "border-top-left-radius")) {
            if (extractPropertyValue(style_text, start + "border-top-left-radius".len)) |val| {
                if (parseCssLength(val, default_font_size)) |px| result.border_radius_tl = px;
            }
        } else if (std.mem.startsWith(u8, after, "border-top-right-radius")) {
            if (extractPropertyValue(style_text, start + "border-top-right-radius".len)) |val| {
                if (parseCssLength(val, default_font_size)) |px| result.border_radius_tr = px;
            }
        } else if (std.mem.startsWith(u8, after, "border-bottom-left-radius")) {
            if (extractPropertyValue(style_text, start + "border-bottom-left-radius".len)) |val| {
                if (parseCssLength(val, default_font_size)) |px| result.border_radius_bl = px;
            }
        } else if (std.mem.startsWith(u8, after, "border-bottom-right-radius")) {
            if (extractPropertyValue(style_text, start + "border-bottom-right-radius".len)) |val| {
                if (parseCssLength(val, default_font_size)) |px| result.border_radius_br = px;
            }
        } else if (std.mem.startsWith(u8, after, "border-radius")) {
            // Shorthand: border-radius: X; (use same value for all corners)
            if (extractPropertyValue(style_text, start + "border-radius".len)) |val| {
                if (parseCssLength(val, default_font_size)) |px| {
                    result.border_radius_tl = px;
                    result.border_radius_tr = px;
                    result.border_radius_bl = px;
                    result.border_radius_br = px;
                }
            }
        }

        pos = start + 7; // advance past "border-"
    }
}

/// Parse a box-shadow or text-shadow value string.
/// Handles: Xpx Ypx [blur] [color] — skips 'inset' keyword.
/// Returns (offset_x, offset_y, blur, color_argb).
fn parseShadowValue(value: []const u8) ?struct { x: f32, y: f32, blur: f32, color: u32 } {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;

    // Skip "none"
    if (std.mem.eql(u8, trimmed, "none")) return null;

    // Tokenize, skip "inset"
    var tokens: [8][]const u8 = undefined;
    var token_count: usize = 0;
    var iter = std.mem.tokenizeAny(u8, trimmed, " \t");
    while (iter.next()) |tok| {
        if (token_count >= 8) break;
        // Skip 'inset' keyword
        if (std.mem.eql(u8, tok, "inset")) continue;
        tokens[token_count] = tok;
        token_count += 1;
    }

    if (token_count < 2) return null;

    // First two tokens must be lengths (offset-x, offset-y)
    const x = parseCssLength(tokens[0], 16.0) orelse return null;
    const y = parseCssLength(tokens[1], 16.0) orelse return null;

    var blur: f32 = 0;
    var color: u32 = 0x80000000; // default semi-transparent black

    var color_start: usize = 2;

    // Third token might be blur-radius (if it's a length)
    if (token_count >= 3) {
        if (parseCssLength(tokens[2], 16.0)) |b| {
            blur = b;
            color_start = 3;
            // Fourth token could also be spread-radius — skip it if it's a number
            if (token_count >= 4) {
                if (parseCssLength(tokens[3], 16.0)) |_| {
                    // This is spread-radius, skip it
                    color_start = 4;
                }
            }
        }
    }

    // Remaining tokens form the color
    if (color_start < token_count) {
        // Join remaining tokens to handle "rgb(0, 0, 0)" etc.
        // For simplicity, try each remaining token and the full remainder
        var color_buf: [128]u8 = undefined;
        var color_len: usize = 0;
        for (color_start..token_count) |i| {
            if (color_len > 0 and color_len < color_buf.len) {
                color_buf[color_len] = ' ';
                color_len += 1;
            }
            const tok = tokens[i];
            if (color_len + tok.len <= color_buf.len) {
                @memcpy(color_buf[color_len .. color_len + tok.len], tok);
                color_len += tok.len;
            }
        }
        if (color_len > 0) {
            if (parseCssColor(color_buf[0..color_len])) |c| {
                color = c;
            }
        }
    }

    return .{ .x = x, .y = y, .blur = blur, .color = color };
}

/// Extract box-shadow values from an inline style string.
fn parseBoxShadow(style_text: []const u8, result: *ComputedStyle) void {
    const idx = std.mem.indexOf(u8, style_text, "box-shadow") orelse return;
    // Make sure it's not "-box-shadow" or similar
    if (idx > 0 and style_text[idx - 1] != ';' and style_text[idx - 1] != ' ' and
        style_text[idx - 1] != '\t' and style_text[idx - 1] != '{')
    {
        return;
    }
    if (extractPropertyValue(style_text, idx + "box-shadow".len)) |val| {
        if (parseShadowValue(val)) |s| {
            result.box_shadow_x = s.x;
            result.box_shadow_y = s.y;
            result.box_shadow_blur = s.blur;
            result.box_shadow_color = s.color;
        }
    }
}

/// Extract text-shadow values from an inline style string.
fn parseTextShadow(style_text: []const u8, result: *ComputedStyle) void {
    const idx = std.mem.indexOf(u8, style_text, "text-shadow") orelse return;
    if (idx > 0 and style_text[idx - 1] != ';' and style_text[idx - 1] != ' ' and
        style_text[idx - 1] != '\t' and style_text[idx - 1] != '{')
    {
        return;
    }
    if (extractPropertyValue(style_text, idx + "text-shadow".len)) |val| {
        if (parseShadowValue(val)) |s| {
            result.text_shadow_x = s.x;
            result.text_shadow_y = s.y;
            result.text_shadow_blur = s.blur;
            result.text_shadow_color = s.color;
        }
    }
}

/// Parse a linear-gradient value and extract start/end colors + direction.
/// Handles: linear-gradient(to bottom, #fff, #000), linear-gradient(180deg, red, blue)
fn parseLinearGradient(value: []const u8, result: *ComputedStyle) void {
    // Find "linear-gradient("
    const lg_start = std.mem.indexOf(u8, value, "linear-gradient(") orelse return;
    const inner_start = lg_start + "linear-gradient(".len;
    const inner_end = std.mem.indexOfScalarPos(u8, value, inner_start, ')') orelse return;
    const inner = value[inner_start..inner_end];

    // Split by commas
    var parts: [8][]const u8 = undefined;
    var part_count: usize = 0;
    var part_iter = std.mem.splitScalar(u8, inner, ',');
    while (part_iter.next()) |part| {
        if (part_count >= 8) break;
        parts[part_count] = std.mem.trim(u8, part, " \t\r\n");
        part_count += 1;
    }

    if (part_count < 2) return;

    var direction: ComputedStyle.GradientDirection = .to_bottom;
    var color_start_idx: usize = 0;

    // Check if first part is a direction
    const first = parts[0];
    if (std.mem.startsWith(u8, first, "to ")) {
        const dir = std.mem.trim(u8, first[3..], " \t");
        if (std.mem.eql(u8, dir, "bottom")) {
            direction = .to_bottom;
        } else if (std.mem.eql(u8, dir, "right")) {
            direction = .to_right;
        } else if (std.mem.eql(u8, dir, "top")) {
            direction = .to_top;
        } else if (std.mem.eql(u8, dir, "left")) {
            direction = .to_left;
        }
        color_start_idx = 1;
    } else if (std.mem.endsWith(u8, first, "deg")) {
        // Parse degree
        const deg_str = first[0 .. first.len - 3];
        if (std.fmt.parseFloat(f32, deg_str)) |deg| {
            // Map common degrees to directions
            const normalized = @mod(deg, 360.0);
            if (normalized < 45 or normalized >= 315) {
                direction = .to_bottom; // 0deg = to bottom (CSS convention: 0deg = to top, but common usage)
            } else if (normalized >= 45 and normalized < 135) {
                direction = .to_right;
            } else if (normalized >= 135 and normalized < 225) {
                direction = .to_bottom;
            } else {
                direction = .to_left;
            }
            // More precise: CSS 0deg = to top, 90deg = to right, 180deg = to bottom
            if (normalized >= 0 and normalized < 90) {
                direction = .to_top;
            } else if (normalized >= 90 and normalized < 180) {
                direction = .to_right;
            } else if (normalized >= 180 and normalized < 270) {
                direction = .to_bottom;
            } else {
                direction = .to_left;
            }
        } else |_| {}
        color_start_idx = 1;
    }

    // Extract first and last color
    if (color_start_idx >= part_count) return;
    const first_color_str = parts[color_start_idx];
    const last_color_str = parts[part_count - 1];

    // Strip any percentage/length suffix from color stops (e.g., "red 20%")
    const first_color_tok = blk: {
        // If it contains a space, take only the first word (color part)
        var tok_iter = std.mem.tokenizeScalar(u8, first_color_str, ' ');
        break :blk tok_iter.next() orelse return;
    };
    const last_color_tok = blk: {
        var tok_iter = std.mem.tokenizeScalar(u8, last_color_str, ' ');
        break :blk tok_iter.next() orelse return;
    };

    const start_color = parseCssColor(first_color_tok) orelse return;
    const end_color = parseCssColor(last_color_tok) orelse return;

    result.gradient_color_start = start_color;
    result.gradient_color_end = end_color;
    result.gradient_direction = direction;
}

/// Extract the value part after a property name, skipping ':' and whitespace, up to ';' or end.
fn extractPropertyValue(text: []const u8, prop_end: usize) ?[]const u8 {
    if (prop_end >= text.len) return null;
    var i = prop_end;

    // Skip whitespace
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;

    // Expect ':'
    if (i >= text.len or text[i] != ':') return null;
    i += 1;

    // Skip whitespace after ':'
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;

    // Find end (';' or end of string)
    const val_start = i;
    while (i < text.len and text[i] != ';' and text[i] != '}') i += 1;

    if (val_start >= i) return null;
    return std.mem.trim(u8, text[val_start..i], " \t");
}

/// A CSS rule entry for properties unsupported/unreliable in LibCSS
/// (e.g. border-radius, background-color from shorthand, color, height).
const CssPropertyRule = struct {
    selector: []const u8, // raw selector text (trimmed)
    border_radius: ?f32 = null,
    background_color: ?u32 = null, // ARGB
    color: ?u32 = null, // ARGB
    height: ?f32 = null, // px
    box_shadow: ?struct { x: f32, y: f32, blur: f32, color: u32 } = null,
    text_shadow: ?struct { x: f32, y: f32, blur: f32, color: u32 } = null,
    gradient_start: ?u32 = null,
    gradient_end: ?u32 = null,
    gradient_direction: ?ComputedStyle.GradientDirection = null,
    word_break: ?ComputedStyle.WordBreak = null,
    overflow_wrap: ?ComputedStyle.OverflowWrap = null,
    text_overflow: ?ComputedStyle.TextOverflow = null,
    visibility: ?ComputedStyle.Visibility = null,
    opacity: ?f32 = null,
};

/// Parse a CSS color value from text.
/// Supports: #RGB, #RRGGBB, #RRGGBBAA, rgb(), rgba(), and common named colors.
fn parseCssColor(value: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (trimmed[0] == '#') {
        return parseHexColor(trimmed);
    }

    if (std.mem.startsWith(u8, trimmed, "rgba(")) {
        return parseRgbaFunc(trimmed);
    }
    if (std.mem.startsWith(u8, trimmed, "rgb(")) {
        return parseRgbFunc(trimmed);
    }
    if (std.mem.startsWith(u8, trimmed, "hsla(")) {
        return parseHslaFunc(trimmed);
    }
    if (std.mem.startsWith(u8, trimmed, "hsl(")) {
        return parseHslFunc(trimmed);
    }

    // Named colors (case-insensitive)
    return namedColor(trimmed);
}

fn parseHexColor(hex: []const u8) ?u32 {
    // hex starts with '#'
    const digits = hex[1..];
    if (digits.len == 3) {
        // #RGB -> #RRGGBB
        const r = hexDigit(digits[0]) orelse return null;
        const g = hexDigit(digits[1]) orelse return null;
        const b = hexDigit(digits[2]) orelse return null;
        return 0xFF000000 | (@as(u32, r) * 17 << 16) | (@as(u32, g) * 17 << 8) | (@as(u32, b) * 17);
    } else if (digits.len == 4) {
        // #RGBA -> #RRGGBBAA
        const r = hexDigit(digits[0]) orelse return null;
        const g = hexDigit(digits[1]) orelse return null;
        const b = hexDigit(digits[2]) orelse return null;
        const a = hexDigit(digits[3]) orelse return null;
        return (@as(u32, a) * 17 << 24) | (@as(u32, r) * 17 << 16) | (@as(u32, g) * 17 << 8) | (@as(u32, b) * 17);
    } else if (digits.len == 6) {
        // #RRGGBB
        const r = parseHexByte(digits[0..2]) orelse return null;
        const g = parseHexByte(digits[2..4]) orelse return null;
        const b = parseHexByte(digits[4..6]) orelse return null;
        return 0xFF000000 | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
    } else if (digits.len == 8) {
        // #RRGGBBAA
        const r = parseHexByte(digits[0..2]) orelse return null;
        const g = parseHexByte(digits[2..4]) orelse return null;
        const b = parseHexByte(digits[4..6]) orelse return null;
        const a = parseHexByte(digits[6..8]) orelse return null;
        return (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
    }
    return null;
}

fn hexDigit(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn parseHexByte(s: *const [2]u8) ?u8 {
    const hi = hexDigit(s[0]) orelse return null;
    const lo = hexDigit(s[1]) orelse return null;
    return hi * 16 + lo;
}

fn parseRgbFunc(text: []const u8) ?u32 {
    // rgb(R, G, B) or rgb(R G B)
    const start = std.mem.indexOf(u8, text, "(") orelse return null;
    const end = std.mem.indexOf(u8, text, ")") orelse return null;
    if (start >= end) return null;
    const inner = text[start + 1 .. end];
    var nums: [3]u8 = undefined;
    var count: usize = 0;
    var iter = std.mem.tokenizeAny(u8, inner, ", /\t");
    while (iter.next()) |tok| {
        if (count >= 3) break;
        const val = std.fmt.parseFloat(f32, tok) catch return null;
        nums[count] = @intFromFloat(std.math.clamp(val, 0, 255));
        count += 1;
    }
    if (count < 3) return null;
    return 0xFF000000 | (@as(u32, nums[0]) << 16) | (@as(u32, nums[1]) << 8) | @as(u32, nums[2]);
}

fn parseRgbaFunc(text: []const u8) ?u32 {
    // rgba(R, G, B, A)
    const start = std.mem.indexOf(u8, text, "(") orelse return null;
    const end = std.mem.indexOf(u8, text, ")") orelse return null;
    if (start >= end) return null;
    const inner = text[start + 1 .. end];
    var nums: [4]f32 = undefined;
    var count: usize = 0;
    var iter = std.mem.tokenizeAny(u8, inner, ", /\t");
    while (iter.next()) |tok| {
        if (count >= 4) break;
        nums[count] = std.fmt.parseFloat(f32, tok) catch return null;
        count += 1;
    }
    if (count < 4) return null;
    const r: u8 = @intFromFloat(std.math.clamp(nums[0], 0, 255));
    const g: u8 = @intFromFloat(std.math.clamp(nums[1], 0, 255));
    const b: u8 = @intFromFloat(std.math.clamp(nums[2], 0, 255));
    // Alpha: 0.0-1.0 range
    const a: u8 = @intFromFloat(std.math.clamp(nums[3] * 255.0, 0, 255));
    return (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

fn hslToRgb(h_deg: f32, s_pct: f32, l_pct: f32) struct { r: u8, g: u8, b: u8 } {
    const s = std.math.clamp(s_pct / 100.0, 0.0, 1.0);
    const l = std.math.clamp(l_pct / 100.0, 0.0, 1.0);
    // Normalize hue to 0-360
    var h = @mod(h_deg, 360.0);
    if (h < 0) h += 360.0;

    const c = (1.0 - @abs(2.0 * l - 1.0)) * s;
    const h_prime = h / 60.0;
    const x = c * (1.0 - @abs(@mod(h_prime, 2.0) - 1.0));
    const m = l - c / 2.0;

    var r1: f32 = 0;
    var g1: f32 = 0;
    var b1: f32 = 0;

    if (h_prime < 1.0) {
        r1 = c;
        g1 = x;
    } else if (h_prime < 2.0) {
        r1 = x;
        g1 = c;
    } else if (h_prime < 3.0) {
        g1 = c;
        b1 = x;
    } else if (h_prime < 4.0) {
        g1 = x;
        b1 = c;
    } else if (h_prime < 5.0) {
        r1 = x;
        b1 = c;
    } else {
        r1 = c;
        b1 = x;
    }

    return .{
        .r = @intFromFloat(std.math.clamp((r1 + m) * 255.0 + 0.5, 0.0, 255.0)),
        .g = @intFromFloat(std.math.clamp((g1 + m) * 255.0 + 0.5, 0.0, 255.0)),
        .b = @intFromFloat(std.math.clamp((b1 + m) * 255.0 + 0.5, 0.0, 255.0)),
    };
}

fn parseHslFunc(text: []const u8) ?u32 {
    // hsl(H, S%, L%) or hsl(H S% L%)
    const start = std.mem.indexOf(u8, text, "(") orelse return null;
    const end = std.mem.indexOf(u8, text, ")") orelse return null;
    if (start >= end) return null;
    const inner = text[start + 1 .. end];
    var vals: [3]f32 = undefined;
    var count: usize = 0;
    var iter = std.mem.tokenizeAny(u8, inner, ", \t");
    while (iter.next()) |tok| {
        if (count >= 3) break;
        // Strip trailing '%' if present
        const clean = if (tok.len > 0 and tok[tok.len - 1] == '%') tok[0 .. tok.len - 1] else tok;
        // Strip "deg" suffix if present
        const clean2 = if (std.mem.endsWith(u8, clean, "deg")) clean[0 .. clean.len - 3] else clean;
        vals[count] = std.fmt.parseFloat(f32, clean2) catch return null;
        count += 1;
    }
    if (count < 3) return null;
    const rgb = hslToRgb(vals[0], vals[1], vals[2]);
    return 0xFF000000 | (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | @as(u32, rgb.b);
}

fn parseHslaFunc(text: []const u8) ?u32 {
    // hsla(H, S%, L%, A) or hsla(H S% L% / A)
    const start = std.mem.indexOf(u8, text, "(") orelse return null;
    const end = std.mem.indexOf(u8, text, ")") orelse return null;
    if (start >= end) return null;
    const inner = text[start + 1 .. end];
    var vals: [4]f32 = undefined;
    var count: usize = 0;
    var iter = std.mem.tokenizeAny(u8, inner, ", /\t");
    while (iter.next()) |tok| {
        if (count >= 4) break;
        const clean = if (tok.len > 0 and tok[tok.len - 1] == '%') tok[0 .. tok.len - 1] else tok;
        const clean2 = if (std.mem.endsWith(u8, clean, "deg")) clean[0 .. clean.len - 3] else clean;
        vals[count] = std.fmt.parseFloat(f32, clean2) catch return null;
        count += 1;
    }
    if (count < 4) return null;
    const rgb = hslToRgb(vals[0], vals[1], vals[2]);
    // Alpha: if > 1.0 treat as 0-255, otherwise 0.0-1.0
    const alpha_f = if (vals[3] <= 1.0) vals[3] * 255.0 else vals[3];
    const a: u8 = @intFromFloat(std.math.clamp(alpha_f, 0.0, 255.0));
    return (@as(u32, a) << 24) | (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | @as(u32, rgb.b);
}

fn namedColor(name: []const u8) ?u32 {
    const table = .{
        .{ "transparent", 0x00000000 },
        .{ "white", 0xFFFFFFFF },
        .{ "black", 0xFF000000 },
        .{ "red", 0xFFFF0000 },
        .{ "green", 0xFF008000 },
        .{ "blue", 0xFF0000FF },
        .{ "yellow", 0xFFFFFF00 },
        .{ "orange", 0xFFFFA500 },
        .{ "purple", 0xFF800080 },
        .{ "gray", 0xFF808080 },
        .{ "grey", 0xFF808080 },
        .{ "silver", 0xFFC0C0C0 },
        .{ "navy", 0xFF000080 },
        .{ "teal", 0xFF008080 },
        .{ "aqua", 0xFF00FFFF },
        .{ "cyan", 0xFF00FFFF },
        .{ "lime", 0xFF00FF00 },
        .{ "maroon", 0xFF800000 },
        .{ "olive", 0xFF808000 },
        .{ "fuchsia", 0xFFFF00FF },
        .{ "magenta", 0xFFFF00FF },
        .{ "coral", 0xFFFF7F50 },
        .{ "tomato", 0xFFFF6347 },
        .{ "gold", 0xFFFFD700 },
        .{ "pink", 0xFFFFC0CB },
        .{ "lightgray", 0xFFD3D3D3 },
        .{ "lightgrey", 0xFFD3D3D3 },
        .{ "darkgray", 0xFFA9A9A9 },
        .{ "darkgrey", 0xFFA9A9A9 },
        .{ "whitesmoke", 0xFFF5F5F5 },
        .{ "wheat", 0xFFF5DEB3 },
        .{ "linen", 0xFFFAF0E6 },
        .{ "beige", 0xFFF5F5DC },
        .{ "ivory", 0xFFFFFFF0 },
        .{ "azure", 0xFFF0FFFF },
        .{ "lavender", 0xFFE6E6FA },
        .{ "plum", 0xFFDDA0DD },
        .{ "orchid", 0xFFDA70D6 },
        .{ "salmon", 0xFFFA8072 },
        .{ "khaki", 0xFFF0E68C },
        .{ "sienna", 0xFFA0522D },
        .{ "chocolate", 0xFFD2691E },
        .{ "tan", 0xFFD2B48C },
        .{ "indigo", 0xFF4B0082 },
        .{ "crimson", 0xFFDC143C },
        .{ "turquoise", 0xFF40E0D0 },
        .{ "steelblue", 0xFF4682B4 },
        .{ "slategray", 0xFF708090 },
        .{ "slategrey", 0xFF708090 },
        .{ "dimgray", 0xFF696969 },
        .{ "dimgrey", 0xFF696969 },
        .{ "gainsboro", 0xFFDCDCDC },
        .{ "honeydew", 0xFFF0FFF0 },
        .{ "mintcream", 0xFFF5FFFA },
        .{ "seashell", 0xFFFFF5EE },
        .{ "snow", 0xFFFFFAFA },
        .{ "ghostwhite", 0xFFF8F8FF },
        .{ "floralwhite", 0xFFFFFAF0 },
        .{ "aliceblue", 0xFFF0F8FF },
        .{ "antiquewhite", 0xFFFAEBD7 },
        .{ "cornsilk", 0xFFFFF8DC },
        .{ "lemonchiffon", 0xFFFFFACD },
        .{ "lightyellow", 0xFFFFFFE0 },
        .{ "lightcyan", 0xFFE0FFFF },
        .{ "lightblue", 0xFFADD8E6 },
        .{ "lightgreen", 0xFF90EE90 },
        .{ "lightpink", 0xFFFFB6C1 },
        .{ "lightsalmon", 0xFFFFA07A },
        .{ "lightcoral", 0xFFF08080 },
        .{ "lightsteelblue", 0xFFB0C4DE },
        .{ "lightskyblue", 0xFF87CEFA },
        .{ "lightseagreen", 0xFF20B2AA },
        .{ "darkblue", 0xFF00008B },
        .{ "darkcyan", 0xFF008B8B },
        .{ "darkgreen", 0xFF006400 },
        .{ "darkred", 0xFF8B0000 },
        .{ "darkorange", 0xFFFF8C00 },
        .{ "darkviolet", 0xFF9400D3 },
        .{ "deeppink", 0xFFFF1493 },
        .{ "deepskyblue", 0xFF00BFFF },
        .{ "dodgerblue", 0xFF1E90FF },
        .{ "firebrick", 0xFFB22222 },
        .{ "forestgreen", 0xFF228B22 },
        .{ "greenyellow", 0xFFADFF2F },
        .{ "hotpink", 0xFFFF69B4 },
        .{ "limegreen", 0xFF32CD32 },
        .{ "mediumblue", 0xFF0000CD },
        .{ "mediumpurple", 0xFF9370DB },
        .{ "mediumseagreen", 0xFF3CB371 },
        .{ "midnightblue", 0xFF191970 },
        .{ "mistyrose", 0xFFFFE4E1 },
        .{ "moccasin", 0xFFFFE4B5 },
        .{ "navajowhite", 0xFFFFDEAD },
        .{ "oldlace", 0xFFFDF5E6 },
        .{ "olivedrab", 0xFF6B8E23 },
        .{ "orangered", 0xFFFF4500 },
        .{ "palegoldenrod", 0xFFEEE8AA },
        .{ "palegreen", 0xFF98FB98 },
        .{ "paleturquoise", 0xFFAFEEEE },
        .{ "palevioletred", 0xFFDB7093 },
        .{ "papayawhip", 0xFFFFEFD5 },
        .{ "peachpuff", 0xFFFFDAB9 },
        .{ "peru", 0xFFCD853F },
        .{ "powderblue", 0xFFB0E0E6 },
        .{ "rosybrown", 0xFFBC8F8F },
        .{ "royalblue", 0xFF4169E1 },
        .{ "saddlebrown", 0xFF8B4513 },
        .{ "sandybrown", 0xFFF4A460 },
        .{ "seagreen", 0xFF2E8B57 },
        .{ "skyblue", 0xFF87CEEB },
        .{ "slateblue", 0xFF6A5ACD },
        .{ "springgreen", 0xFF00FF7F },
        .{ "thistle", 0xFFD8BFD8 },
        .{ "violet", 0xFFEE82EE },
        .{ "yellowgreen", 0xFF9ACD32 },
        .{ "inherit", null },
        .{ "initial", null },
    };
    inline for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(name, entry[0])) return entry[1];
    }
    return null;
}

/// Extract the first color value from a CSS `background` shorthand.
/// Returns the color if found, null if the value is only url()/position/repeat.
fn extractBgShorthandColor(value: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");

    // If it starts with a color indicator, try parsing the first token
    if (trimmed.len == 0) return null;

    // Try the whole value as a color first (e.g., "background: #ecedee")
    if (parseCssColor(trimmed)) |c| return c;

    // Try parsing the first token (before space) as a color
    // e.g., "red url(...) repeat-x" -> try "red"
    var iter = std.mem.tokenizeScalar(u8, trimmed, ' ');
    if (iter.next()) |first_token| {
        // Skip if first token is url(...)
        if (std.mem.startsWith(u8, first_token, "url(")) return null;
        if (std.mem.eql(u8, first_token, "none")) return null;
        return parseCssColor(first_token);
    }
    return null;
}

/// Parse a word-break CSS value.
fn parseWordBreak(val: []const u8) ?ComputedStyle.WordBreak {
    const trimmed = std.mem.trim(u8, val, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "break-all")) return .break_all;
    if (std.mem.eql(u8, trimmed, "keep-all")) return .keep_all;
    if (std.mem.eql(u8, trimmed, "normal")) return .normal;
    return null;
}

/// Parse an overflow-wrap (or word-wrap) CSS value.
fn parseOverflowWrap(val: []const u8) ?ComputedStyle.OverflowWrap {
    const trimmed = std.mem.trim(u8, val, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "break-word")) return .break_word;
    if (std.mem.eql(u8, trimmed, "anywhere")) return .anywhere;
    if (std.mem.eql(u8, trimmed, "normal")) return .normal;
    return null;
}

/// Parse a text-overflow CSS value.
fn parseTextOverflow(val: []const u8) ?ComputedStyle.TextOverflow {
    const trimmed = std.mem.trim(u8, val, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "ellipsis")) return .ellipsis;
    if (std.mem.eql(u8, trimmed, "clip")) return .clip;
    return null;
}

/// Extract properties of interest from a CSS rule body into a CssPropertyRule.
fn extractPropertiesFromBody(body: []const u8, rule: *CssPropertyRule, has_any: *bool) void {
    // border-radius
    if (std.mem.indexOf(u8, body, "border-radius")) |br_idx| {
        const prop_start = br_idx + "border-radius".len;
        if (extractPropertyValue(body, prop_start)) |val| {
            if (parseCssLength(val, 16.0)) |px| {
                rule.border_radius = px;
                has_any.* = true;
            }
        }
    }

    // background-color (explicit property)
    if (std.mem.indexOf(u8, body, "background-color")) |bc_idx| {
        const prop_start = bc_idx + "background-color".len;
        if (extractPropertyValue(body, prop_start)) |val| {
            if (parseCssColor(val)) |c| {
                rule.background_color = c;
                has_any.* = true;
            }
        }
    }

    // background shorthand — extract color if present (only if background-color wasn't already found)
    if (rule.background_color == null) {
        if (std.mem.indexOf(u8, body, "background")) |bg_idx| {
            const after_pos = bg_idx + "background".len;
            const is_shorthand = after_pos >= body.len or
                body[after_pos] == ':' or body[after_pos] == ' ' or body[after_pos] == '\t';
            if (is_shorthand) {
                if (extractPropertyValue(body, after_pos)) |val| {
                    if (extractBgShorthandColor(val)) |c| {
                        rule.background_color = c;
                        has_any.* = true;
                    }
                }
            }
        }
    }

    // color (foreground)
    {
        var search_pos: usize = 0;
        while (search_pos < body.len) {
            const ci = std.mem.indexOfPos(u8, body, search_pos, "color") orelse break;
            const is_standalone = (ci == 0 or (body[ci - 1] != '-' and body[ci - 1] != '_'));
            if (is_standalone) {
                const prop_start = ci + "color".len;
                if (extractPropertyValue(body, prop_start)) |val| {
                    if (parseCssColor(val)) |c| {
                        rule.color = c;
                        has_any.* = true;
                    }
                }
                break;
            }
            search_pos = ci + 1;
        }
    }

    // height
    if (std.mem.indexOf(u8, body, "height")) |h_idx| {
        const is_plain_height = (h_idx == 0 or (body[h_idx - 1] != '-' and body[h_idx - 1] != '_'));
        if (is_plain_height) {
            const prop_start = h_idx + "height".len;
            if (extractPropertyValue(body, prop_start)) |val| {
                if (parseCssLength(val, 16.0)) |px| {
                    rule.height = px;
                    has_any.* = true;
                }
            }
        }
    }

    // box-shadow
    if (std.mem.indexOf(u8, body, "box-shadow")) |bs_idx| {
        const is_plain = (bs_idx == 0 or (body[bs_idx - 1] != '-' and body[bs_idx - 1] != '_'));
        if (is_plain) {
            if (extractPropertyValue(body, bs_idx + "box-shadow".len)) |val| {
                if (parseShadowValue(val)) |s| {
                    rule.box_shadow = .{ .x = s.x, .y = s.y, .blur = s.blur, .color = s.color };
                    has_any.* = true;
                }
            }
        }
    }

    // text-shadow
    if (std.mem.indexOf(u8, body, "text-shadow")) |ts_idx| {
        const is_plain = (ts_idx == 0 or (body[ts_idx - 1] != '-' and body[ts_idx - 1] != '_'));
        if (is_plain) {
            if (extractPropertyValue(body, ts_idx + "text-shadow".len)) |val| {
                if (parseShadowValue(val)) |s| {
                    rule.text_shadow = .{ .x = s.x, .y = s.y, .blur = s.blur, .color = s.color };
                    has_any.* = true;
                }
            }
        }
    }

    // linear-gradient in background/background-image
    if (std.mem.indexOf(u8, body, "linear-gradient")) |_| {
        if (std.mem.indexOf(u8, body, "background")) |bg_idx| {
            const after_pos = bg_idx + "background".len;
            if (after_pos < body.len and (body[after_pos] == ':' or body[after_pos] == '-')) {
                var val_start = after_pos;
                while (val_start < body.len and body[val_start] != ':') val_start += 1;
                if (val_start < body.len) {
                    if (extractPropertyValue(body, val_start)) |_| {
                        var dummy_style = ComputedStyle{};
                        parseLinearGradient(body, &dummy_style);
                        if ((dummy_style.gradient_color_start >> 24) > 0 or (dummy_style.gradient_color_end >> 24) > 0) {
                            rule.gradient_start = dummy_style.gradient_color_start;
                            rule.gradient_end = dummy_style.gradient_color_end;
                            rule.gradient_direction = dummy_style.gradient_direction;
                            has_any.* = true;
                        }
                    }
                }
            }
        }
    }

    // word-break
    if (std.mem.indexOf(u8, body, "word-break")) |wb_idx| {
        const is_plain = (wb_idx == 0 or (body[wb_idx - 1] != '-' and body[wb_idx - 1] != '_'));
        if (is_plain) {
            if (extractPropertyValue(body, wb_idx + "word-break".len)) |val| {
                rule.word_break = parseWordBreak(val);
                if (rule.word_break != null) has_any.* = true;
            }
        }
    }

    // overflow-wrap (also handles legacy word-wrap)
    if (std.mem.indexOf(u8, body, "overflow-wrap")) |ow_idx| {
        if (extractPropertyValue(body, ow_idx + "overflow-wrap".len)) |val| {
            rule.overflow_wrap = parseOverflowWrap(val);
            if (rule.overflow_wrap != null) has_any.* = true;
        }
    } else if (std.mem.indexOf(u8, body, "word-wrap")) |ww_idx| {
        const is_plain = (ww_idx == 0 or (body[ww_idx - 1] != '-' and body[ww_idx - 1] != '_'));
        if (is_plain) {
            if (extractPropertyValue(body, ww_idx + "word-wrap".len)) |val| {
                rule.overflow_wrap = parseOverflowWrap(val);
                if (rule.overflow_wrap != null) has_any.* = true;
            }
        }
    }

    // text-overflow
    if (std.mem.indexOf(u8, body, "text-overflow")) |to_idx| {
        if (extractPropertyValue(body, to_idx + "text-overflow".len)) |val| {
            rule.text_overflow = parseTextOverflow(val);
            if (rule.text_overflow != null) has_any.* = true;
        }
    }

    // opacity
    if (std.mem.indexOf(u8, body, "opacity")) |op_idx| {
        const is_plain = (op_idx == 0 or (body[op_idx - 1] != '-' and body[op_idx - 1] != '_'));
        if (is_plain) {
            if (extractPropertyValue(body, op_idx + "opacity".len)) |val| {
                if (std.fmt.parseFloat(f32, std.mem.trim(u8, val, " \t\r\n"))) |op| {
                    rule.opacity = std.math.clamp(op, 0.0, 1.0);
                    has_any.* = true;
                } else |_| {}
            }
        }
    }

    // visibility
    if (std.mem.indexOf(u8, body, "visibility")) |vi_idx| {
        const is_plain = (vi_idx == 0 or (body[vi_idx - 1] != '-' and body[vi_idx - 1] != '_'));
        if (is_plain) {
            if (extractPropertyValue(body, vi_idx + "visibility".len)) |val| {
                const trimmed = std.mem.trim(u8, val, " \t\r\n");
                if (std.mem.eql(u8, trimmed, "hidden")) {
                    rule.visibility = .hidden;
                    has_any.* = true;
                } else if (std.mem.eql(u8, trimmed, "visible")) {
                    rule.visibility = .visible;
                    has_any.* = true;
                } else if (std.mem.eql(u8, trimmed, "collapse")) {
                    rule.visibility = .collapse;
                    has_any.* = true;
                }
            }
        }
    }
}

/// Parse raw CSS text to extract property rules for properties LibCSS doesn't handle well.
/// Returns a list of selector -> property mappings.
fn extractCssPropertyRules(css_text: []const u8, allocator: std.mem.Allocator) !std.ArrayListUnmanaged(CssPropertyRule) {
    var rules: std.ArrayListUnmanaged(CssPropertyRule) = .empty;
    errdefer rules.deinit(allocator);

    var pos: usize = 0;
    while (pos < css_text.len) {
        // Skip comments between rules
        if (skipCssCommentOrString(css_text, pos)) |after| {
            pos = after;
            continue;
        }
        // Find the next '{' — everything before it is the selector
        const brace_open = std.mem.indexOfScalarPos(u8, css_text, pos, '{') orelse break;

        // Find matching '}' — handle nested braces, comments, and strings
        const brace_close = findMatchingBrace(css_text, brace_open) orelse break;

        const selector_raw = std.mem.trim(u8, css_text[pos..brace_open], " \t\r\n");
        const body = css_text[brace_open + 1 .. brace_close];

        // Skip at-rules (@media, @keyframes, etc.) — their bodies contain
        // nested rules that would need recursive parsing. For now, skip
        // the entire block and rely on LibCSS for at-rule handling.
        if (selector_raw.len > 0 and selector_raw[0] == '@') {
            pos = brace_close + 1;
            continue;
        }

        // Extract all properties of interest from this rule body
        var rule = CssPropertyRule{ .selector = undefined };
        var has_any = false;
        extractPropertiesFromBody(body, &rule, &has_any);

        if (has_any) {
            // Store each comma-separated selector
            var sel_iter = std.mem.splitScalar(u8, selector_raw, ',');
            while (sel_iter.next()) |sel_part| {
                const trimmed_sel = std.mem.trim(u8, sel_part, " \t\r\n");
                if (trimmed_sel.len > 0) {
                    var r = rule;
                    r.selector = trimmed_sel;
                    try rules.append(allocator, r);
                }
            }
        }

        pos = brace_close + 1;
    }

    return rules;
}

/// Check if a simple CSS selector matches a DOM element.
/// Supports: tag, .class, #id, tag.class, tag#id
fn selectorMatchesElement(selector: []const u8, node: DomNode) bool {
    if (node.nodeType() != .element) return false;

    var sel = selector;

    // Skip leading '*' (universal selector)
    if (sel.len > 0 and sel[0] == '*') {
        sel = sel[1..];
    }

    // Reject complex selectors (containing spaces, >, +, ~, [, :, etc.)
    for (sel) |ch| {
        if (ch == ' ' or ch == '>' or ch == '+' or ch == '~' or ch == '[' or ch == ':') return false;
    }

    // Parse selector into tag, class, id components
    var expected_tag: ?[]const u8 = null;
    var expected_class: ?[]const u8 = null;
    var expected_id: ?[]const u8 = null;

    var i: usize = 0;
    const orig_sel = sel;

    // Tag name is the portion before any '.' or '#'
    while (i < orig_sel.len and orig_sel[i] != '.' and orig_sel[i] != '#') : (i += 1) {}
    if (i > 0) {
        expected_tag = orig_sel[0..i];
    }

    // Parse remaining class/id parts
    while (i < orig_sel.len) {
        if (orig_sel[i] == '.') {
            i += 1;
            const start = i;
            while (i < orig_sel.len and orig_sel[i] != '.' and orig_sel[i] != '#') : (i += 1) {}
            if (i > start) {
                expected_class = orig_sel[start..i];
            }
        } else if (orig_sel[i] == '#') {
            i += 1;
            const start = i;
            while (i < orig_sel.len and orig_sel[i] != '.' and orig_sel[i] != '#') : (i += 1) {}
            if (i > start) {
                expected_id = orig_sel[start..i];
            }
        } else {
            i += 1;
        }
    }

    // Match tag
    if (expected_tag) |tag| {
        const node_tag = node.tagName() orelse return false;
        if (!std.ascii.eqlIgnoreCase(tag, node_tag)) return false;
    }

    // Match class
    if (expected_class) |cls| {
        const node_class = node.getAttribute("class") orelse return false;
        // Check if the class attribute contains the expected class
        // (space-separated list)
        var class_iter = std.mem.tokenizeAny(u8, node_class, " \t");
        var found = false;
        while (class_iter.next()) |c| {
            if (std.mem.eql(u8, c, cls)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }

    // Match id
    if (expected_id) |id| {
        const node_id = node.getAttribute("id") orelse return false;
        if (!std.mem.eql(u8, node_id, id)) return false;
    }

    // If no components were specified (e.g., empty selector), no match
    if (expected_tag == null and expected_class == null and expected_id == null) return false;

    return true;
}

/// Style map: maps node pointer (usize) -> ComputedStyle.
pub const StyleMap = std.AutoHashMap(usize, ComputedStyle);

/// Result of cascade: owns the style map + LibCSS resources.
pub const CascadeResult = struct {
    styles: StyleMap,
    sheet: ?*css.css_stylesheet,
    ua_sheet: ?*css.css_stylesheet,
    ctx: ?*css.css_select_ctx,

    pub fn getStyle(self: *const CascadeResult, node: DomNode) ?ComputedStyle {
        return self.styles.get(@intFromPtr(node.lxb_node));
    }

    pub fn deinit(self: *CascadeResult) void {
        self.styles.deinit();
        if (self.ctx) |ctx| _ = css.css_select_ctx_destroy(ctx);
        if (self.sheet) |sheet| _ = css.css_stylesheet_destroy(sheet);
        if (self.ua_sheet) |sheet| _ = css.css_stylesheet_destroy(sheet);
    }
};

/// Minimal user-agent default stylesheet (Catppuccin Mocha theme).
const ua_stylesheet_text =
    \\html { color: #cdd6f4; }
    \\body { margin: 8px; color: #cdd6f4; }
    \\html, body, div, section, article, aside, nav, main,
    \\header, footer, h1, h2, h3, h4, h5, h6, p, blockquote,
    \\dl, dt, dd, figure, figcaption, form, fieldset,
    \\hr, address, details, summary { display: block; }
    \\head, style, script, link, meta, title, template { display: none; }
    \\table { display: table; border-collapse: separate; }
    \\tr { display: table-row; }
    \\td, th { display: table-cell; padding: 1px; }
    \\th { font-weight: bold; text-align: center; }
    \\thead { display: table-header-group; }
    \\tbody { display: table-row-group; }
    \\tfoot { display: table-footer-group; }
    \\col { display: table-column; }
    \\colgroup { display: table-column-group; }
    \\caption { display: table-caption; }
    \\ul, ol { display: block; padding-left: 40px; margin-top: 1em; margin-bottom: 1em; }
    \\li { display: list-item; }
    \\h1 { font-size: 2em; font-weight: bold; margin-top: 0.67em; margin-bottom: 0.67em; }
    \\h2 { font-size: 1.5em; font-weight: bold; margin-top: 0.83em; margin-bottom: 0.83em; }
    \\h3 { font-size: 1.17em; font-weight: bold; margin-top: 1em; margin-bottom: 1em; }
    \\h4 { font-weight: bold; margin-top: 1.33em; margin-bottom: 1.33em; }
    \\h5 { font-size: 0.83em; font-weight: bold; margin-top: 1.67em; margin-bottom: 1.67em; }
    \\h6 { font-size: 0.67em; font-weight: bold; margin-top: 2.33em; margin-bottom: 2.33em; }
    \\b, strong { font-weight: bold; display: inline; }
    \\em, i { font-style: italic; display: inline; }
    \\a { color: #89b4fa; text-decoration: underline; display: inline; }
    \\span, u, s, del, ins, q, cite, dfn, var, kbd, samp { display: inline; }
    \\pre, code { white-space: pre; }
    \\code { color: #a6e3a1; }
    \\pre { margin-top: 1em; margin-bottom: 1em; padding: 8px; }
    \\hr { border-top: 1px solid #45475a; margin-top: 8px; margin-bottom: 8px; }
    \\p { margin-top: 1em; margin-bottom: 1em; }
    \\blockquote { margin-left: 40px; margin-right: 40px; margin-top: 1em; margin-bottom: 1em;
    \\  border-left: 3px solid #45475a; padding-left: 12px; }
    \\button { display: inline-block; padding: 4px 12px;
    \\  border: 1px solid #45475a; color: #cdd6f4; }
    \\input, textarea { display: inline-block; padding: 4px 6px;
    \\  border: 1px solid #45475a; color: #cdd6f4; }
    \\select { display: inline-block; padding: 4px 6px;
    \\  border: 1px solid #45475a; color: #cdd6f4; }
    \\small { font-size: 0.83em; }
    \\sub, sup { font-size: 0.75em; }
    \\mark { color: #1e1e2e; }
    \\abbr { text-decoration: underline; }
    \\center { display: block; text-align: center; }
    \\noscript { display: none; }
    \\details { display: block; }
    \\summary { display: block; }
    \\dialog { display: none; }
    \\template { display: none; }
;

/// Walk the DOM tree recursively and collect <style> element text content.
fn collectStyleText(node: DomNode, allocator: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try walkForStyles(node, &buf, allocator);

    return buf.toOwnedSlice(allocator);
}

fn walkForStyles(node: DomNode, buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
    if (node.nodeType() == .element) {
        if (node.tagName()) |tag| {
            if (std.mem.eql(u8, tag, "style")) {
                // Collect text content of <style> element
                var child = node.firstChild();
                while (child) |c| {
                    if (c.nodeType() == .text) {
                        if (c.textContent()) |text| {
                            try buf.appendSlice(allocator, text);
                            try buf.append(allocator, '\n');
                        }
                    }
                    child = c.nextSibling();
                }
                return; // Don't recurse into style element children
            }
        }
    }
    // Recurse into children
    var child = node.firstChild();
    while (child) |c| {
        try walkForStyles(c, buf, allocator);
        child = c.nextSibling();
    }
}

/// Filter out ONLY blanket "hide everything" CSS rules like:
///   "table,div,span,p{display:none}"
/// These are used by Google as a pre-JS hidden state. We only strip rules where
/// the selector contains MULTIPLE common element tags (not class/id selectors).
fn filterHarmfulCss(input: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var pos: usize = 0;
    while (pos < input.len) {
        const brace_open = std.mem.indexOfScalarPos(u8, input, pos, '{') orelse {
            try result.appendSlice(allocator, input[pos..]);
            break;
        };
        const brace_close = std.mem.indexOfScalarPos(u8, input, brace_open + 1, '}') orelse {
            try result.appendSlice(allocator, input[pos..]);
            break;
        };

        const selector = std.mem.trim(u8, input[pos..brace_open], " \t\r\n");
        const body = std.mem.trim(u8, input[brace_open + 1 .. brace_close], " \t\r\n");

        // Only strip if: body is EXACTLY "display:none" AND selector is a
        // comma-separated list of bare tag names (no dots, hashes, or colons)
        const is_blanket_hide = blk: {
            if (!std.mem.eql(u8, body, "display:none")) break :blk false;
            // Must have commas (multiple selectors)
            if (std.mem.indexOf(u8, selector, ",") == null) break :blk false;
            // Must NOT contain class/id/pseudo selectors
            if (std.mem.indexOf(u8, selector, ".") != null) break :blk false;
            if (std.mem.indexOf(u8, selector, "#") != null) break :blk false;
            if (std.mem.indexOf(u8, selector, ":") != null) break :blk false;
            if (std.mem.indexOf(u8, selector, "[") != null) break :blk false;
            break :blk true;
        };

        if (is_blanket_hide) {
            pos = brace_close + 1;
        } else {
            try result.appendSlice(allocator, input[pos .. brace_close + 1]);
            pos = brace_close + 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Create a LibCSS stylesheet from a CSS text string.
fn createSheet(css_text: []const u8, url: [*c]const u8) !*css.css_stylesheet {
    var params = std.mem.zeroes(css.css_stylesheet_params);
    params.params_version = css.CSS_STYLESHEET_PARAMS_VERSION_1;
    params.level = css.CSS_LEVEL_DEFAULT;
    params.charset = "UTF-8";
    params.url = url;
    params.title = null;
    params.allow_quirks = false;
    params.inline_style = false;
    params.resolve = resolveUrl;
    params.resolve_pw = null;
    params.import = null;
    params.import_pw = null;
    params.color = null;
    params.color_pw = null;
    params.font = null;
    params.font_pw = null;

    var sheet: ?*css.css_stylesheet = null;
    var err = css.css_stylesheet_create(&params, &sheet);
    if (err != css.CSS_OK or sheet == null) return error.CssSheetCreateFailed;

    if (css_text.len > 0) {
        err = css.css_stylesheet_append_data(sheet.?, css_text.ptr, css_text.len);
        if (err != css.CSS_OK and err != css.CSS_NEEDDATA) {
            _ = css.css_stylesheet_destroy(sheet.?);
            return error.CssSheetAppendFailed;
        }
    }
    err = css.css_stylesheet_data_done(sheet.?);
    if (err != css.CSS_OK) {
        _ = css.css_stylesheet_destroy(sheet.?);
        return error.CssSheetDataDoneFailed;
    }

    return sheet.?;
}

/// Create an inline stylesheet from a style attribute value.
fn createInlineSheet(style_text: []const u8) ?*css.css_stylesheet {
    var params = std.mem.zeroes(css.css_stylesheet_params);
    params.params_version = css.CSS_STYLESHEET_PARAMS_VERSION_1;
    params.level = css.CSS_LEVEL_DEFAULT;
    params.charset = "UTF-8";
    params.url = "about:inline";
    params.title = null;
    params.allow_quirks = false;
    params.inline_style = true;
    params.resolve = resolveUrl;
    params.resolve_pw = null;
    params.import = null;
    params.import_pw = null;
    params.color = null;
    params.color_pw = null;
    params.font = null;
    params.font_pw = null;

    var sheet: ?*css.css_stylesheet = null;
    var err = css.css_stylesheet_create(&params, &sheet);
    if (err != css.CSS_OK or sheet == null) return null;

    if (style_text.len > 0) {
        err = css.css_stylesheet_append_data(sheet.?, style_text.ptr, style_text.len);
        if (err != css.CSS_OK and err != css.CSS_NEEDDATA) {
            _ = css.css_stylesheet_destroy(sheet.?);
            return null;
        }
    }
    err = css.css_stylesheet_data_done(sheet.?);
    if (err != css.CSS_OK) {
        _ = css.css_stylesheet_destroy(sheet.?);
        return null;
    }

    return sheet.?;
}

/// CSS Custom Properties (CSS Variables) support.
/// LibCSS does not support var() references, so we pre-process CSS text
/// to resolve variable references before passing it to LibCSS.
const CssVarMap = std.StringHashMap([]const u8);

/// Skip CSS comments and string literals when scanning.
/// Returns the position after the comment/string, or null if not at one.
fn skipCssCommentOrString(text: []const u8, pos: usize) ?usize {
    if (pos + 1 < text.len and text[pos] == '/' and text[pos + 1] == '*') {
        // CSS comment: /* ... */
        var i = pos + 2;
        while (i + 1 < text.len) : (i += 1) {
            if (text[i] == '*' and text[i + 1] == '/') return i + 2;
        }
        return text.len; // unterminated comment
    }
    if (text[pos] == '"' or text[pos] == '\'') {
        // CSS string literal
        const quote = text[pos];
        var i = pos + 1;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\\' and i + 1 < text.len) {
                i += 1; // skip escaped char
                continue;
            }
            if (text[i] == quote) return i + 1;
        }
        return text.len; // unterminated string
    }
    return null;
}

/// Find matching '}' for a '{' at brace_open, handling nested braces,
/// CSS comments, and string literals correctly.
fn findMatchingBrace(text: []const u8, brace_open: usize) ?usize {
    var depth: usize = 1;
    var i: usize = brace_open + 1;
    while (i < text.len and depth > 0) {
        // Skip comments and strings
        if (skipCssCommentOrString(text, i)) |after| {
            i = after;
            continue;
        }
        if (text[i] == '{') depth += 1;
        if (text[i] == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
        i += 1;
    }
    return null; // unmatched
}

/// Extract CSS custom property declarations (--name: value) from CSS text.
/// Focuses on :root, html, *, body blocks (global scope) which covers ~80% of real usage.
fn extractCssVariables(css_text: []const u8, allocator: std.mem.Allocator) !CssVarMap {
    var vars = CssVarMap.init(allocator);
    errdefer {
        var it = vars.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        vars.deinit();
    }

    var pos: usize = 0;
    while (pos < css_text.len) {
        // Skip comments between rules
        if (skipCssCommentOrString(css_text, pos)) |after| {
            pos = after;
            continue;
        }
        // Find next '{'
        const brace_open = std.mem.indexOfScalarPos(u8, css_text, pos, '{') orelse break;
        // Find matching '}' — handle nested braces, comments, and strings
        const brace_close = findMatchingBrace(css_text, brace_open) orelse break;

        const body = css_text[brace_open + 1 .. brace_close];

        // Parse body for --* declarations
        var body_pos: usize = 0;
        while (body_pos < body.len) {
            // Skip whitespace
            while (body_pos < body.len and (body[body_pos] == ' ' or body[body_pos] == '\t' or
                body[body_pos] == '\n' or body[body_pos] == '\r'))
            {
                body_pos += 1;
            }
            if (body_pos >= body.len) break;

            // Skip CSS comments inside rule bodies
            if (skipCssCommentOrString(body, body_pos)) |after| {
                body_pos = after;
                continue;
            }

            // Check if this is a custom property declaration (starts with --)
            if (body_pos + 2 < body.len and body[body_pos] == '-' and body[body_pos + 1] == '-') {
                // Find the property name (up to ':')
                const name_start = body_pos;
                const colon = std.mem.indexOfScalarPos(u8, body, body_pos, ':') orelse {
                    body_pos = (std.mem.indexOfScalarPos(u8, body, body_pos, ';') orelse body.len);
                    if (body_pos < body.len) body_pos += 1;
                    continue;
                };
                const name = std.mem.trim(u8, body[name_start..colon], " \t");

                // Find the value (up to ';' or '}'), skipping comments and strings
                const val_start = colon + 1;
                var val_end = val_start;
                var paren_depth: usize = 0;
                while (val_end < body.len) {
                    if (skipCssCommentOrString(body, val_end)) |after| {
                        val_end = after;
                        continue;
                    }
                    if (body[val_end] == '(') paren_depth += 1;
                    if (body[val_end] == ')') {
                        if (paren_depth > 0) paren_depth -= 1;
                    }
                    if (body[val_end] == ';' and paren_depth == 0) break;
                    if (body[val_end] == '}' and paren_depth == 0) break;
                    val_end += 1;
                }
                const value = std.mem.trim(u8, body[val_start..val_end], " \t\r\n");

                if (name.len > 2 and value.len > 0) {
                    // Store in map (allocate copies)
                    // Skip if already exists (first declaration wins, simpler and safer)
                    if (!vars.contains(name)) {
                        const name_copy = try allocator.dupe(u8, name);
                        const value_copy = try allocator.dupe(u8, value);
                        try vars.put(name_copy, value_copy);
                    }
                }

                body_pos = if (val_end < body.len and body[val_end] == ';') val_end + 1 else val_end;
            } else {
                // Skip to next ';' or nested block, respecting comments/strings
                var skip_depth: usize = 0;
                while (body_pos < body.len) {
                    if (skipCssCommentOrString(body, body_pos)) |after| {
                        body_pos = after;
                        continue;
                    }
                    if (body[body_pos] == '{') skip_depth += 1;
                    if (body[body_pos] == '}') {
                        if (skip_depth > 0) {
                            skip_depth -= 1;
                        } else break;
                    }
                    if (body[body_pos] == ';' and skip_depth == 0) {
                        body_pos += 1;
                        break;
                    }
                    body_pos += 1;
                }
            }
        }

        pos = brace_close + 1;
    }

    return vars;
}

/// Resolve var() references in CSS text using the provided variable map.
/// Handles nested var() in values and fallback values: var(--name, fallback).
/// max_depth prevents infinite recursion from circular variable references.
fn resolveCssVariables(css_text: []const u8, vars: *const CssVarMap, allocator: std.mem.Allocator) ![]const u8 {
    // Single-pass resolution (no recursive var-in-var resolution to avoid memory issues)
    return resolveCssVariablesDepth(css_text, vars, allocator, 9);
}

fn resolveCssVariablesDepth(css_text: []const u8, vars: *const CssVarMap, allocator: std.mem.Allocator, depth: usize) ![]const u8 {
    if (depth > 10) {
        // Prevent infinite recursion from circular references
        return try allocator.dupe(u8, css_text);
    }

    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var pos: usize = 0;
    while (pos < css_text.len) {
        // Find next "var("
        const var_start = std.mem.indexOfPos(u8, css_text, pos, "var(") orelse {
            try result.appendSlice(allocator, css_text[pos..]);
            break;
        };

        // Copy everything before "var("
        try result.appendSlice(allocator, css_text[pos..var_start]);

        // Find matching closing ')' — handle nested parentheses
        var paren_depth: usize = 1;
        var i: usize = var_start + 4; // after "var("
        while (i < css_text.len and paren_depth > 0) : (i += 1) {
            if (css_text[i] == '(') paren_depth += 1;
            if (css_text[i] == ')') paren_depth -= 1;
        }

        if (paren_depth == 0) {
            // i now points one past the closing ')'
            const inner = std.mem.trim(u8, css_text[var_start + 4 .. i - 1], " \t");

            // Parse: --name or --name, fallback
            // Find first comma that isn't inside nested parens
            var comma_pos: ?usize = null;
            var inner_depth: usize = 0;
            for (inner, 0..) |ch, idx| {
                if (ch == '(') inner_depth += 1;
                if (ch == ')') {
                    if (inner_depth > 0) inner_depth -= 1;
                }
                if (ch == ',' and inner_depth == 0) {
                    comma_pos = idx;
                    break;
                }
            }

            const var_name = std.mem.trim(u8, if (comma_pos) |c| inner[0..c] else inner, " \t");
            const fallback = if (comma_pos) |c| std.mem.trim(u8, inner[c + 1 ..], " \t") else null;

            // Look up variable value (no recursive resolution to avoid memory issues)
            if (vars.get(var_name)) |value| {
                try result.appendSlice(allocator, value);
            } else if (fallback) |fb| {
                try result.appendSlice(allocator, fb);
            }
            // else: no value and no fallback — output nothing (property becomes invalid per CSS spec)

            pos = i; // past ')'
        } else {
            // Malformed var() — no matching ')'. Copy "var(" literally and continue.
            try result.appendSlice(allocator, css_text[var_start .. var_start + 4]);
            pos = var_start + 4;
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Resolve var() references in an inline style string using the global variable map.
fn resolveInlineStyleVars(style_attr: []const u8, vars: *const CssVarMap, allocator: std.mem.Allocator) !?[]const u8 {
    if (std.mem.indexOf(u8, style_attr, "var(") == null) return null;
    return try resolveCssVariables(style_attr, vars, allocator);
}

/// Walk DOM tree and select styles for each element node.
fn walkAndSelect(
    node: DomNode,
    ctx: *css.css_select_ctx,
    unit_ctx: *const css.css_unit_ctx,
    media: *const css.css_media,
    handler: *css.css_select_handler,
    styles: *StyleMap,
    property_rules: []const CssPropertyRule,
    vw: f32,
    vh: f32,
    css_vars: *const CssVarMap,
    allocator: std.mem.Allocator,
) !void {
    if (node.nodeType() == .element) {
        // Determine if this is the root element
        var is_root = false;
        if (node.parent()) |p| {
            is_root = (p.nodeType() == .document);
        }

        // Check for inline style attribute, resolving var() references
        var inline_sheet: ?*css.css_stylesheet = null;
        var resolved_inline: ?[]const u8 = null;
        if (node.getAttribute("style")) |style_attr| {
            resolved_inline = try resolveInlineStyleVars(style_attr, css_vars, allocator);
            inline_sheet = createInlineSheet(resolved_inline orelse style_attr);
        }
        defer if (resolved_inline) |r| allocator.free(r);
        defer if (inline_sheet) |s| {
            _ = css.css_stylesheet_destroy(s);
        };

        var results: ?*css.css_select_results = null;
        const err = css.css_select_style(ctx, @ptrCast(node.lxb_node), unit_ctx, media, inline_sheet, handler, null, &results);
        if (err == css.CSS_OK) {
            if (results) |res| {
                defer _ = css.css_select_results_destroy(res);
                if (res.styles[css.CSS_PSEUDO_ELEMENT_NONE]) |computed| {
                    var style = extractStyleVp(computed, is_root, vw, vh);

                    // Parse border-radius from inline style (LibCSS doesn't support it)
                    // Use resolved inline style (with var() substituted) if available
                    const effective_inline = resolved_inline orelse node.getAttribute("style");
                    if (effective_inline) |style_attr| {
                        parseBorderRadius(style_attr, &style);
                    }

                    // Apply properties from CSS rules as fallback
                    // (for properties LibCSS doesn't handle well)
                    for (property_rules) |rule| {
                        if (selectorMatchesElement(rule.selector, node)) {
                            // border-radius (if not already set by inline style)
                            if (rule.border_radius) |radius| {
                                if (style.border_radius_tl == 0 and style.border_radius_tr == 0 and
                                    style.border_radius_bl == 0 and style.border_radius_br == 0)
                                {
                                    style.border_radius_tl = radius;
                                    style.border_radius_tr = radius;
                                    style.border_radius_bl = radius;
                                    style.border_radius_br = radius;
                                }
                            }

                            // background-color fallback (when LibCSS reports transparent)
                            if (rule.background_color) |bg| {
                                if (style.background_color == 0x00000000) {
                                    style.background_color = bg;
                                }
                            }

                            // color fallback (when LibCSS reports default)
                            if (rule.color) |fg| {
                                if (style.color == 0xFFcdd6f4) {
                                    style.color = fg;
                                }
                            }

                            // height fallback (when LibCSS reports auto/unset)
                            if (rule.height) |h| {
                                if (style.height == .auto) {
                                    style.height = .{ .px = h };
                                }
                            }

                            // box-shadow from CSS rules
                            if (rule.box_shadow) |bs| {
                                if (style.box_shadow_color == 0x00000000) {
                                    style.box_shadow_x = bs.x;
                                    style.box_shadow_y = bs.y;
                                    style.box_shadow_blur = bs.blur;
                                    style.box_shadow_color = bs.color;
                                }
                            }

                            // text-shadow from CSS rules
                            if (rule.text_shadow) |ts| {
                                if (style.text_shadow_color == 0x00000000) {
                                    style.text_shadow_x = ts.x;
                                    style.text_shadow_y = ts.y;
                                    style.text_shadow_blur = ts.blur;
                                    style.text_shadow_color = ts.color;
                                }
                            }

                            // gradient from CSS rules
                            if (rule.gradient_start) |gs| {
                                if (style.gradient_color_start == 0x00000000 and style.gradient_color_end == 0x00000000) {
                                    style.gradient_color_start = gs;
                                    style.gradient_color_end = rule.gradient_end orelse 0x00000000;
                                    style.gradient_direction = rule.gradient_direction orelse .to_bottom;
                                }
                            }

                            // word-break from CSS rules
                            if (rule.word_break) |wb| {
                                if (style.word_break == .normal) style.word_break = wb;
                            }

                            // overflow-wrap from CSS rules
                            if (rule.overflow_wrap) |ow| {
                                if (style.overflow_wrap == .normal) style.overflow_wrap = ow;
                            }

                            // visibility from CSS rules — always apply (last rule wins)
                            if (rule.visibility) |vis| {
                                style.visibility = vis;
                            }

                            // opacity from CSS rules
                            if (rule.opacity) |op| {
                                if (style.opacity == 1.0) style.opacity = op;
                            }

                            // text-overflow from CSS rules
                            if (rule.text_overflow) |to| {
                                if (style.text_overflow == .clip) style.text_overflow = to;
                            }
                        }
                    }

                    // Parse additional properties from inline style as fallback
                    if (effective_inline) |style_attr| {
                        // Opacity
                        if (style.opacity == 1.0) {
                            if (std.mem.indexOf(u8, style_attr, "opacity")) |op_idx| {
                                if (extractPropertyValue(style_attr, op_idx + "opacity".len)) |val| {
                                    if (std.fmt.parseFloat(f32, std.mem.trim(u8, val, " \t"))) |op| {
                                        style.opacity = std.math.clamp(op, 0.0, 1.0);
                                    } else |_| {}
                                }
                            }
                        }

                        // background-color from inline style
                        if (style.background_color == 0x00000000) {
                            if (std.mem.indexOf(u8, style_attr, "background-color")) |bc_idx| {
                                if (extractPropertyValue(style_attr, bc_idx + "background-color".len)) |val| {
                                    if (parseCssColor(val)) |c| {
                                        style.background_color = c;
                                    }
                                }
                            }
                        }

                        // background shorthand from inline style
                        if (style.background_color == 0x00000000) {
                            if (std.mem.indexOf(u8, style_attr, "background")) |bg_idx| {
                                const after_pos = bg_idx + "background".len;
                                const is_shorthand = after_pos >= style_attr.len or
                                    (style_attr[after_pos] == ':' or style_attr[after_pos] == ' ' or style_attr[after_pos] == '\t');
                                if (is_shorthand) {
                                    if (extractPropertyValue(style_attr, after_pos)) |val| {
                                        if (extractBgShorthandColor(val)) |c| {
                                            style.background_color = c;
                                        }
                                    }
                                }
                            }
                        }

                        // color from inline style
                        if (style.color == 0xFFcdd6f4) {
                            var search_pos: usize = 0;
                            while (search_pos < style_attr.len) {
                                const ci = std.mem.indexOfPos(u8, style_attr, search_pos, "color") orelse break;
                                const is_standalone = (ci == 0 or (style_attr[ci - 1] != '-' and style_attr[ci - 1] != '_'));
                                if (is_standalone) {
                                    if (extractPropertyValue(style_attr, ci + "color".len)) |val| {
                                        if (parseCssColor(val)) |c| {
                                            style.color = c;
                                        }
                                    }
                                    break;
                                }
                                search_pos = ci + 1;
                            }
                        }

                        // height from inline style
                        if (style.height == .auto) {
                            if (std.mem.indexOf(u8, style_attr, "height")) |h_idx| {
                                const is_plain = (h_idx == 0 or (style_attr[h_idx - 1] != '-' and style_attr[h_idx - 1] != '_'));
                                if (is_plain) {
                                    if (extractPropertyValue(style_attr, h_idx + "height".len)) |val| {
                                        if (parseCssLength(val, 16.0)) |px| {
                                            style.height = .{ .px = px };
                                        }
                                    }
                                }
                            }
                        }

                        // box-shadow from inline style
                        if (style.box_shadow_color == 0x00000000) {
                            parseBoxShadow(style_attr, &style);
                        }

                        // text-shadow from inline style
                        if (style.text_shadow_color == 0x00000000) {
                            parseTextShadow(style_attr, &style);
                        }

                        // linear-gradient from inline background
                        if (style.gradient_color_start == 0x00000000 and style.gradient_color_end == 0x00000000) {
                            if (std.mem.indexOf(u8, style_attr, "linear-gradient") != null) {
                                parseLinearGradient(style_attr, &style);
                            }
                        }

                        // word-break from inline style
                        if (style.word_break == .normal) {
                            if (std.mem.indexOf(u8, style_attr, "word-break")) |wb_idx| {
                                const is_plain = (wb_idx == 0 or (style_attr[wb_idx - 1] != '-' and style_attr[wb_idx - 1] != '_'));
                                if (is_plain) {
                                    if (extractPropertyValue(style_attr, wb_idx + "word-break".len)) |val| {
                                        if (parseWordBreak(val)) |wb| style.word_break = wb;
                                    }
                                }
                            }
                        }

                        // overflow-wrap from inline style (also check word-wrap alias)
                        if (style.overflow_wrap == .normal) {
                            if (std.mem.indexOf(u8, style_attr, "overflow-wrap")) |ow_idx| {
                                if (extractPropertyValue(style_attr, ow_idx + "overflow-wrap".len)) |val| {
                                    if (parseOverflowWrap(val)) |ow| style.overflow_wrap = ow;
                                }
                            } else if (std.mem.indexOf(u8, style_attr, "word-wrap")) |ww_idx| {
                                const is_plain = (ww_idx == 0 or (style_attr[ww_idx - 1] != '-' and style_attr[ww_idx - 1] != '_'));
                                if (is_plain) {
                                    if (extractPropertyValue(style_attr, ww_idx + "word-wrap".len)) |val| {
                                        if (parseOverflowWrap(val)) |ow| style.overflow_wrap = ow;
                                    }
                                }
                            }
                        }

                        // text-overflow from inline style
                        if (style.text_overflow == .clip) {
                            if (std.mem.indexOf(u8, style_attr, "text-overflow")) |to_idx| {
                                if (extractPropertyValue(style_attr, to_idx + "text-overflow".len)) |val| {
                                    if (parseTextOverflow(val)) |to| style.text_overflow = to;
                                }
                            }
                        }

                        // visibility from inline style
                        if (std.mem.indexOf(u8, style_attr, "visibility")) |vi_idx| {
                            const is_plain = (vi_idx == 0 or (style_attr[vi_idx - 1] != '-' and style_attr[vi_idx - 1] != '_'));
                            if (is_plain) {
                                if (extractPropertyValue(style_attr, vi_idx + "visibility".len)) |val| {
                                    const trimmed_vis = std.mem.trim(u8, val, " \t\r\n");
                                    if (std.mem.eql(u8, trimmed_vis, "hidden")) {
                                        style.visibility = .hidden;
                                    } else if (std.mem.eql(u8, trimmed_vis, "visible")) {
                                        style.visibility = .visible;
                                    } else if (std.mem.eql(u8, trimmed_vis, "collapse")) {
                                        style.visibility = .collapse;
                                    }
                                }
                            }
                        }
                    }

                    try styles.put(@intFromPtr(node.lxb_node), style);
                }
            }
        }
    }

    // Recurse into children
    var child = node.firstChild();
    while (child) |c| {
        try walkAndSelect(c, ctx, unit_ctx, media, handler, styles, property_rules, vw, vh, css_vars, allocator);
        child = c.nextSibling();
    }
}

/// Run the full style cascade on a parsed document.
/// Extracts <style> elements, parses CSS, and selects styles for all elements.
pub fn cascade(doc_root: DomNode, allocator: std.mem.Allocator, external_css: ?[]const u8, viewport_width: u32, viewport_height: u32) !CascadeResult {
    var result = CascadeResult{
        .styles = StyleMap.init(allocator),
        .sheet = null,
        .ua_sheet = null,
        .ctx = null,
    };
    errdefer result.deinit();

    // 1. Create UA default stylesheet
    const ua_sheet = try createSheet(ua_stylesheet_text, "about:ua");
    result.ua_sheet = ua_sheet;

    // 2. Collect CSS from <style> elements in the DOM
    const dom_css = try collectStyleText(doc_root, allocator);
    defer allocator.free(dom_css);

    // 3. Combine external CSS (from <link> fetches) with DOM <style> content.
    // External CSS goes first (matches typical <head> order: <link> before <style>).
    // DOM <style> content appended after, so it naturally overrides per CSS cascade.
    const combined_css = if (external_css) |ext| blk: {
        const combined = try allocator.alloc(u8, ext.len + 1 + dom_css.len);
        @memcpy(combined[0..ext.len], ext);
        combined[ext.len] = '\n';
        @memcpy(combined[ext.len + 1 ..], dom_css);
        break :blk combined;
    } else blk: {
        break :blk try allocator.dupe(u8, dom_css);
    };
    defer allocator.free(combined_css);

    // 4. Filter harmful CSS patterns — only when inline <style> contains
    // blanket element-hiding rules (common in Google's pre-JS hidden state).
    // Skip filter if no DOM <style> content (external CSS alone is unlikely harmful).
    const css_text = if (dom_css.len > 0 and std.mem.indexOf(u8, dom_css, "display:none") != null)
        try filterHarmfulCss(combined_css, allocator)
    else
        try allocator.dupe(u8, combined_css);
    defer allocator.free(css_text);

    // 4.5. Resolve CSS custom properties (var() references)
    // Skip var() resolution for very large CSS (>512KB) — LibCSS may crash on
    // resolved output. The brace/comment-aware parser is safe, but the downstream
    // C library (LibCSS) can corrupt memory with very large inputs.
    const max_css_for_var_resolution: usize = 512 * 1024;
    var css_vars = if (css_text.len <= max_css_for_var_resolution)
        try extractCssVariables(css_text, allocator)
    else
        CssVarMap.init(allocator);
    defer {
        var vit = css_vars.iterator();
        while (vit.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        css_vars.deinit();
    }

    const resolved_css = if (css_vars.count() > 0 and std.mem.indexOf(u8, css_text, "var(") != null)
        try resolveCssVariables(css_text, &css_vars, allocator)
    else
        try allocator.dupe(u8, css_text);
    defer allocator.free(resolved_css);

    // 5. Create author stylesheet (using resolved CSS with var() substituted)
    const sheet = try createSheet(resolved_css, "about:style");
    result.sheet = sheet;

    // 6. Create select context
    var ctx: ?*css.css_select_ctx = null;
    var err = css.css_select_ctx_create(&ctx);
    if (err != css.CSS_OK or ctx == null) return error.CssSelectCtxCreateFailed;
    result.ctx = ctx;

    // 7. Add stylesheets to context (UA first, then author)
    err = css.css_select_ctx_append_sheet(ctx.?, ua_sheet, css.CSS_ORIGIN_UA, null);
    if (err != css.CSS_OK) return error.CssAppendSheetFailed;

    err = css.css_select_ctx_append_sheet(ctx.?, sheet, css.CSS_ORIGIN_AUTHOR, null);
    if (err != css.CSS_OK) return error.CssAppendSheetFailed;

    // 8. Set up media and unit context
    var media = std.mem.zeroes(css.css_media);
    media.type = css.CSS_MEDIA_SCREEN;

    var unit_ctx = std.mem.zeroes(css.css_unit_ctx);
    unit_ctx.viewport_width = intToFixed(@intCast(viewport_width));
    unit_ctx.viewport_height = intToFixed(@intCast(viewport_height));
    unit_ctx.font_size_default = intToFixed(16);
    unit_ctx.font_size_minimum = intToFixed(6);
    unit_ctx.device_dpi = intToFixed(96);
    unit_ctx.root_style = null;
    unit_ctx.pw = null;
    unit_ctx.measure = null;

    // 9. Set up handler
    var handler = select_handler.getHandler();

    // 10. Extract CSS property rules from resolved text (border-radius, background-color, color, height)
    var property_rules = try extractCssPropertyRules(resolved_css, allocator);
    defer property_rules.deinit(allocator);

    // 11. Walk DOM and select styles (pass css_vars for inline style var() resolution)
    const vw_f: f32 = @floatFromInt(viewport_width);
    const vh_f: f32 = @floatFromInt(viewport_height);
    try walkAndSelect(doc_root, ctx.?, &unit_ctx, &media, &handler, &result.styles, property_rules.items, vw_f, vh_f, &css_vars, allocator);

    return result;
}
