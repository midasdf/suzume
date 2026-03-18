const std = @import("std");

pub const Unit = enum {
    px, em, rem, vh, vw, vmin, vmax,
    svh, dvh, lvh, svw, dvw, lvw, // small/dynamic/large viewport units
    pt, pc, cm, mm, in_,
    ch, ex, lh,
    percent,
    fr,
    deg, rad, grad, turn,
    s, ms,
    none,
};

pub const Length = struct {
    value: f32,
    unit: Unit,
};

pub const Color = struct {
    r: u8, g: u8, b: u8, a: u8,

    pub fn toArgb(self: Color) u32 {
        return (@as(u32, self.a) << 24) | (@as(u32, self.r) << 16) |
               (@as(u32, self.g) << 8) | @as(u32, self.b);
    }

    pub fn fromArgb(argb: u32) Color {
        return .{
            .a = @truncate(argb >> 24),
            .r = @truncate(argb >> 16),
            .g = @truncate(argb >> 8),
            .b = @truncate(argb),
        };
    }

    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const white = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
};

pub const CalcOp = enum { add, sub, mul, div, value };

pub const CalcNode = struct {
    op: CalcOp,
    value: Value = .{ .keyword = .none },
};

pub const Keyword = enum {
    // CSS-wide
    none, auto, inherit, initial, unset, revert,
    // Display
    block, inline_, inline_block, flex, inline_flex,
    grid, inline_grid, table, list_item,
    table_row, table_cell, table_row_group,
    table_header_group, table_footer_group,
    table_column, table_column_group, table_caption,
    // Visibility
    hidden, visible, collapse,
    // Position
    static_, relative, absolute, fixed, sticky,
    // Text
    left, right, center, justify, start, end,
    normal, nowrap, pre, pre_wrap, pre_line, break_all, keep_all,
    // Font
    bold, bolder, lighter, italic, oblique,
    // Text decoration
    underline, line_through, overline,
    // Overflow
    scroll, auto_overflow,
    // Box sizing
    content_box, border_box,
    // Float/clear
    float_left, float_right, clear_left, clear_right, clear_both,
    // Flex
    row, row_reverse, column, column_reverse, wrap, wrap_reverse,
    flex_start, flex_end, space_between, space_around, space_evenly, stretch, baseline,
    // List
    disc, circle, square, decimal, lower_alpha, upper_alpha, lower_roman, upper_roman,
    // Misc
    transparent_kw, currentcolor,
    // Border style
    solid, dashed, dotted, double, groove, ridge, inset, outset,
    // Word break / overflow-wrap
    break_word, anywhere,
    // Text overflow
    clip, ellipsis,
    // Text transform
    uppercase, lowercase, capitalize,
};

pub const VarRef = struct {
    name: []const u8,
    fallback: ?[]const u8,
};

pub const FunctionValue = struct {
    name: []const u8,
    args: []Value,
};

pub const Value = union(enum) {
    keyword: Keyword,
    length: Length,
    percentage: f32,
    number: f32,
    integer: i32,
    color: Color,
    string: []const u8,
    url: []const u8,
    calc: []CalcNode,
    list: []Value,
    var_ref: VarRef,
    function: FunctionValue,
    raw: []const u8,
};
