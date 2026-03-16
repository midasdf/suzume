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

    // Display
    result.display = mapDisplay(css.css_computed_display(style, is_root));

    // Margins
    var m_len: css.css_fixed = 0;
    var m_unit: css.css_unit = css.CSS_UNIT_PX;
    if (css.css_computed_margin_top(style, &m_len, &m_unit) == css.CSS_MARGIN_SET)
        result.margin_top = lengthToPx(m_len, m_unit, default_font_size);
    if (css.css_computed_margin_right(style, &m_len, &m_unit) == css.CSS_MARGIN_SET)
        result.margin_right = lengthToPx(m_len, m_unit, default_font_size);
    if (css.css_computed_margin_bottom(style, &m_len, &m_unit) == css.CSS_MARGIN_SET)
        result.margin_bottom = lengthToPx(m_len, m_unit, default_font_size);
    if (css.css_computed_margin_left(style, &m_len, &m_unit) == css.CSS_MARGIN_SET)
        result.margin_left = lengthToPx(m_len, m_unit, default_font_size);

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

/// Minimal user-agent default stylesheet.
/// Sets display:block for standard block-level elements and display:none
/// for elements that should not render.
const ua_stylesheet_text =
    \\html, body, div, section, article, aside, nav, main,
    \\header, footer, h1, h2, h3, h4, h5, h6, p, blockquote, pre,
    \\ul, ol, li, dl, dt, dd, figure, figcaption, form, fieldset,
    \\table, hr, address, details, summary { display: block; }
    \\head, style, script, link, meta, title { display: none; }
    \\table { display: table; }
    \\tr { display: table-row; }
    \\td, th { display: table-cell; }
    \\thead { display: table-header-group; }
    \\tbody { display: table-row-group; }
    \\tfoot { display: table-footer-group; }
    \\col { display: table-column; }
    \\colgroup { display: table-column-group; }
    \\caption { display: table-caption; }
    \\li { display: list-item; }
    \\h1 { font-size: 2em; font-weight: bold; }
    \\h2 { font-size: 1.5em; font-weight: bold; }
    \\h3 { font-size: 1.17em; font-weight: bold; }
    \\h4 { font-weight: bold; }
    \\h5 { font-size: 0.83em; font-weight: bold; }
    \\h6 { font-size: 0.67em; font-weight: bold; }
    \\b, strong { font-weight: bold; }
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
