const std = @import("std");
const values = @import("values.zig");

pub const PropertyId = enum(u16) {
    // Box model
    display,
    position,
    float_,
    clear,
    box_sizing,
    width,
    height,
    min_width,
    max_width,
    min_height,
    max_height,
    margin_top,
    margin_right,
    margin_bottom,
    margin_left,
    padding_top,
    padding_right,
    padding_bottom,
    padding_left,
    // Borders
    border_top_width,
    border_right_width,
    border_bottom_width,
    border_left_width,
    border_top_color,
    border_right_color,
    border_bottom_color,
    border_left_color,
    border_top_style,
    border_right_style,
    border_bottom_style,
    border_left_style,
    border_radius_top_left,
    border_radius_top_right,
    border_radius_bottom_left,
    border_radius_bottom_right,
    // Colors
    color,
    background_color,
    background_image,
    background_repeat,
    background_position,
    background_size,
    opacity,
    // Typography
    font_size,
    font_weight,
    font_style,
    font_family,
    line_height,
    letter_spacing,
    word_spacing,
    text_indent,
    text_align,
    text_decoration,
    text_transform,
    white_space,
    word_break,
    overflow_wrap,
    text_overflow,
    vertical_align,
    visibility,
    // Layout
    overflow_x,
    overflow_y,
    z_index,
    top,
    right,
    bottom,
    left,
    // Lists
    list_style_type,
    // Flex
    flex_direction,
    flex_wrap,
    justify_content,
    align_items,
    align_self,
    flex_grow,
    flex_shrink,
    flex_basis,
    gap,
    row_gap,
    column_gap,
    // Grid
    grid_template_columns,
    grid_template_rows,
    grid_auto_flow,
    grid_auto_columns,
    grid_column_start,
    grid_column_end,
    grid_row_start,
    grid_row_end,
    // Shadows
    box_shadow,
    text_shadow,
    // Transforms
    transform,
    // Content
    content,
    // Counters
    counter_reset,
    counter_increment,
    // Transitions
    transition_property,
    transition_duration,
    transition_timing_function,
    transition_delay,
    // Animations
    animation_name,
    animation_duration,
    animation_timing_function,
    animation_delay,
    animation_iteration_count,
    animation_direction,
    animation_fill_mode,
    animation_play_state,
    // Filters
    filter,
    backdrop_filter,
    // Object fit
    object_fit,
    // Outline
    outline_width,
    outline_color,
    outline_style,
    // Custom property
    custom,
    // Unknown (preserved)
    unknown,
    _,

    const property_map = std.StaticStringMap(PropertyId).initComptime(.{
        .{ "display", .display },
        .{ "position", .position },
        .{ "float", .float_ },
        .{ "clear", .clear },
        .{ "box-sizing", .box_sizing },
        .{ "width", .width },
        .{ "height", .height },
        .{ "min-width", .min_width },
        .{ "max-width", .max_width },
        .{ "min-height", .min_height },
        .{ "max-height", .max_height },
        .{ "margin-top", .margin_top },
        .{ "margin-right", .margin_right },
        .{ "margin-bottom", .margin_bottom },
        .{ "margin-left", .margin_left },
        .{ "padding-top", .padding_top },
        .{ "padding-right", .padding_right },
        .{ "padding-bottom", .padding_bottom },
        .{ "padding-left", .padding_left },
        .{ "border-top-width", .border_top_width },
        .{ "border-right-width", .border_right_width },
        .{ "border-bottom-width", .border_bottom_width },
        .{ "border-left-width", .border_left_width },
        .{ "border-top-color", .border_top_color },
        .{ "border-right-color", .border_right_color },
        .{ "border-bottom-color", .border_bottom_color },
        .{ "border-left-color", .border_left_color },
        .{ "border-top-style", .border_top_style },
        .{ "border-right-style", .border_right_style },
        .{ "border-bottom-style", .border_bottom_style },
        .{ "border-left-style", .border_left_style },
        .{ "border-top-left-radius", .border_radius_top_left },
        .{ "border-top-right-radius", .border_radius_top_right },
        .{ "border-bottom-left-radius", .border_radius_bottom_left },
        .{ "border-bottom-right-radius", .border_radius_bottom_right },
        .{ "color", .color },
        .{ "background-color", .background_color },
        .{ "background-image", .background_image },
        .{ "background-repeat", .background_repeat },
        .{ "background-position", .background_position },
        .{ "background-size", .background_size },
        .{ "opacity", .opacity },
        .{ "font-size", .font_size },
        .{ "font-weight", .font_weight },
        .{ "font-style", .font_style },
        .{ "font-family", .font_family },
        .{ "line-height", .line_height },
        .{ "letter-spacing", .letter_spacing },
        .{ "word-spacing", .word_spacing },
        .{ "text-indent", .text_indent },
        .{ "text-align", .text_align },
        .{ "text-decoration", .text_decoration },
        .{ "text-transform", .text_transform },
        .{ "white-space", .white_space },
        .{ "word-break", .word_break },
        .{ "overflow-wrap", .overflow_wrap },
        .{ "text-overflow", .text_overflow },
        .{ "vertical-align", .vertical_align },
        .{ "visibility", .visibility },
        .{ "overflow-x", .overflow_x },
        .{ "overflow-y", .overflow_y },
        .{ "z-index", .z_index },
        .{ "top", .top },
        .{ "right", .right },
        .{ "bottom", .bottom },
        .{ "left", .left },
        .{ "list-style-type", .list_style_type },
        .{ "flex-direction", .flex_direction },
        .{ "flex-wrap", .flex_wrap },
        .{ "justify-content", .justify_content },
        .{ "align-items", .align_items },
        .{ "align-self", .align_self },
        .{ "flex-grow", .flex_grow },
        .{ "flex-shrink", .flex_shrink },
        .{ "flex-basis", .flex_basis },
        .{ "gap", .gap },
        .{ "row-gap", .row_gap },
        .{ "column-gap", .column_gap },
        .{ "grid-template-columns", .grid_template_columns },
        .{ "grid-template-rows", .grid_template_rows },
        .{ "grid-auto-flow", .grid_auto_flow },
        .{ "grid-auto-columns", .grid_auto_columns },
        .{ "grid-column-start", .grid_column_start },
        .{ "grid-column-end", .grid_column_end },
        .{ "grid-row-start", .grid_row_start },
        .{ "grid-row-end", .grid_row_end },
        .{ "box-shadow", .box_shadow },
        .{ "text-shadow", .text_shadow },
        .{ "transform", .transform },
        .{ "content", .content },
        .{ "counter-reset", .counter_reset },
        .{ "counter-increment", .counter_increment },
        .{ "transition-property", .transition_property },
        .{ "transition-duration", .transition_duration },
        .{ "transition-timing-function", .transition_timing_function },
        .{ "transition-delay", .transition_delay },
        .{ "animation-name", .animation_name },
        .{ "animation-duration", .animation_duration },
        .{ "animation-timing-function", .animation_timing_function },
        .{ "animation-delay", .animation_delay },
        .{ "animation-iteration-count", .animation_iteration_count },
        .{ "animation-direction", .animation_direction },
        .{ "animation-fill-mode", .animation_fill_mode },
        .{ "animation-play-state", .animation_play_state },
        .{ "filter", .filter },
        .{ "backdrop-filter", .backdrop_filter },
        .{ "object-fit", .object_fit },
        .{ "outline-width", .outline_width },
        .{ "outline-color", .outline_color },
        .{ "outline-style", .outline_style },
    });

    pub fn fromString(name: []const u8) PropertyId {
        if (name.len >= 2 and name[0] == '-' and name[1] == '-') {
            return .custom;
        }
        // Lowercase for case-insensitive lookup
        var buf: [64]u8 = undefined;
        if (name.len > buf.len) return .unknown;
        for (name, 0..) |c, i| {
            buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        return property_map.get(buf[0..name.len]) orelse .unknown;
    }
};

pub const Declaration = struct {
    property: PropertyId,
    property_name: []const u8,
    value_raw: []const u8,
    important: bool = false,
};

pub const Selector = struct {
    source: []const u8,
};

pub const StyleRule = struct {
    selectors: []Selector,
    declarations: []Declaration,
    source_order: u32,
};

pub const MediaQuery = struct {
    raw: []const u8,
};

pub const Rule = union(enum) {
    style: StyleRule,
    media: MediaRule,
    keyframes: KeyframesRule,
    font_face: FontFaceRule,
};

pub const MediaRule = struct {
    query: MediaQuery,
    rules: []Rule,
};

pub const Keyframe = struct {
    selector_raw: []const u8,
    declarations: []Declaration,
};

pub const KeyframesRule = struct {
    name: []const u8,
    keyframes: []Keyframe,
};

pub const FontFaceRule = struct {
    declarations: []Declaration,
};

pub const Stylesheet = struct {
    rules: []Rule,
};
