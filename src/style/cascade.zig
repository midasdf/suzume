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

    // Borders — only render if border-style is solid
    var b_len: css.css_fixed = 0;
    var b_unit: css.css_unit = css.CSS_UNIT_PX;
    var b_color: css.css_color = 0;

    if (css.css_computed_border_top_style(style) == css.CSS_BORDER_STYLE_SOLID) {
        const bw_type = css.css_computed_border_top_width(style, &b_len, &b_unit);
        result.border_top_width = borderWidthValue(bw_type, b_len, b_unit, default_font_size);
        if (css.css_computed_border_top_color(style, &b_color) == css.CSS_BORDER_COLOR_COLOR) {
            result.border_top_color = b_color;
        }
    }
    if (css.css_computed_border_right_style(style) == css.CSS_BORDER_STYLE_SOLID) {
        const bw_type = css.css_computed_border_right_width(style, &b_len, &b_unit);
        result.border_right_width = borderWidthValue(bw_type, b_len, b_unit, default_font_size);
        if (css.css_computed_border_right_color(style, &b_color) == css.CSS_BORDER_COLOR_COLOR) {
            result.border_right_color = b_color;
        }
    }
    if (css.css_computed_border_bottom_style(style) == css.CSS_BORDER_STYLE_SOLID) {
        const bw_type = css.css_computed_border_bottom_width(style, &b_len, &b_unit);
        result.border_bottom_width = borderWidthValue(bw_type, b_len, b_unit, default_font_size);
        if (css.css_computed_border_bottom_color(style, &b_color) == css.CSS_BORDER_COLOR_COLOR) {
            result.border_bottom_color = b_color;
        }
    }
    if (css.css_computed_border_left_style(style) == css.CSS_BORDER_STYLE_SOLID) {
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
            .{ .px = lengthToPx(w_len, w_unit, default_font_size) };
    }

    // Height
    var h_len: css.css_fixed = 0;
    var h_unit: css.css_unit = css.CSS_UNIT_PX;
    const h_type = css.css_computed_height(style, &h_len, &h_unit);
    if (h_type == css.CSS_HEIGHT_SET) {
        result.height = if (h_unit == css.CSS_UNIT_PCT)
            .{ .percent = fixedToF32(h_len) }
        else
            .{ .px = lengthToPx(h_len, h_unit, default_font_size) };
    }

    // Min/max width
    var mw_len: css.css_fixed = 0;
    var mw_unit: css.css_unit = css.CSS_UNIT_PX;
    if (css.css_computed_min_width(style, &mw_len, &mw_unit) == css.CSS_MIN_WIDTH_SET) {
        result.min_width = if (mw_unit == css.CSS_UNIT_PCT)
            .{ .percent = fixedToF32(mw_len) }
        else
            .{ .px = lengthToPx(mw_len, mw_unit, default_font_size) };
    }
    if (css.css_computed_max_width(style, &mw_len, &mw_unit) == css.CSS_MAX_WIDTH_SET) {
        result.max_width = if (mw_unit == css.CSS_UNIT_PCT)
            .{ .percent = fixedToF32(mw_len) }
        else
            .{ .px = lengthToPx(mw_len, mw_unit, default_font_size) };
    }

    // Min/max height
    var mh_len: css.css_fixed = 0;
    var mh_unit: css.css_unit = css.CSS_UNIT_PX;
    if (css.css_computed_min_height(style, &mh_len, &mh_unit) == css.CSS_MIN_HEIGHT_SET) {
        result.min_height = if (mh_unit == css.CSS_UNIT_PCT)
            .{ .percent = fixedToF32(mh_len) }
        else
            .{ .px = lengthToPx(mh_len, mh_unit, default_font_size) };
    }
    if (css.css_computed_max_height(style, &mh_len, &mh_unit) == css.CSS_MAX_HEIGHT_SET) {
        result.max_height = if (mh_unit == css.CSS_UNIT_PCT)
            .{ .percent = fixedToF32(mh_len) }
        else
            .{ .px = lengthToPx(mh_len, mh_unit, default_font_size) };
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

    return result;
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
    \\b, strong { font-weight: bold; }
    \\em, i { font-style: italic; }
    \\a { color: #89b4fa; text-decoration: underline; }
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

/// Walk DOM tree and select styles for each element node.
fn walkAndSelect(
    node: DomNode,
    ctx: *css.css_select_ctx,
    unit_ctx: *const css.css_unit_ctx,
    media: *const css.css_media,
    handler: *css.css_select_handler,
    styles: *StyleMap,
) !void {
    if (node.nodeType() == .element) {
        // Determine if this is the root element
        var is_root = false;
        if (node.parent()) |p| {
            is_root = (p.nodeType() == .document);
        }

        var results: ?*css.css_select_results = null;
        const err = css.css_select_style(ctx, @ptrCast(node.lxb_node), unit_ctx, media, null, handler, null, &results);
        if (err == css.CSS_OK) {
            if (results) |res| {
                defer _ = css.css_select_results_destroy(res);
                if (res.styles[css.CSS_PSEUDO_ELEMENT_NONE]) |computed| {
                    const style = extractStyle(computed, is_root);
                    try styles.put(@intFromPtr(node.lxb_node), style);
                }
            }
        }
    }

    // Recurse into children
    var child = node.firstChild();
    while (child) |c| {
        try walkAndSelect(c, ctx, unit_ctx, media, handler, styles);
        child = c.nextSibling();
    }
}

/// Run the full style cascade on a parsed document.
/// Extracts <style> elements, parses CSS, and selects styles for all elements.
pub fn cascade(doc_root: DomNode, allocator: std.mem.Allocator) !CascadeResult {
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

    // 2. Collect CSS from <style> elements
    const css_text = try collectStyleText(doc_root, allocator);
    defer allocator.free(css_text);

    // 3. Create author stylesheet
    const sheet = try createSheet(css_text, "about:style");
    result.sheet = sheet;

    // 4. Create select context
    var ctx: ?*css.css_select_ctx = null;
    var err = css.css_select_ctx_create(&ctx);
    if (err != css.CSS_OK or ctx == null) return error.CssSelectCtxCreateFailed;
    result.ctx = ctx;

    // 5. Add stylesheets to context (UA first, then author)
    err = css.css_select_ctx_append_sheet(ctx.?, ua_sheet, css.CSS_ORIGIN_UA, null);
    if (err != css.CSS_OK) return error.CssAppendSheetFailed;

    err = css.css_select_ctx_append_sheet(ctx.?, sheet, css.CSS_ORIGIN_AUTHOR, null);
    if (err != css.CSS_OK) return error.CssAppendSheetFailed;

    // 6. Set up media and unit context
    var media = std.mem.zeroes(css.css_media);
    media.type = css.CSS_MEDIA_SCREEN;

    var unit_ctx = std.mem.zeroes(css.css_unit_ctx);
    unit_ctx.viewport_width = intToFixed(720);
    unit_ctx.viewport_height = intToFixed(720);
    unit_ctx.font_size_default = intToFixed(16);
    unit_ctx.font_size_minimum = intToFixed(6);
    unit_ctx.device_dpi = intToFixed(96);
    unit_ctx.root_style = null;
    unit_ctx.pw = null;
    unit_ctx.measure = null;

    // 7. Set up handler
    var handler = select_handler.getHandler();

    // 8. Walk DOM and select styles
    try walkAndSelect(doc_root, ctx.?, &unit_ctx, &media, &handler, &result.styles);

    return result;
}
