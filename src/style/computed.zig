/// Zig-friendly computed style struct extracted from LibCSS's css_computed_style.
pub const ComputedStyle = struct {
    color: u32 = 0xFFcdd6f4, // ARGB, Catppuccin Mocha text default
    background_color: u32 = 0x00000000, // ARGB, transparent default
    font_size_px: f32 = 16.0,
    font_weight: u16 = 400,
    font_style: FontStyle = .normal,
    display: Display = .block,
    margin_top: f32 = 0,
    margin_right: f32 = 0,
    margin_bottom: f32 = 0,
    margin_left: f32 = 0,
    padding_top: f32 = 0,
    padding_right: f32 = 0,
    padding_bottom: f32 = 0,
    padding_left: f32 = 0,
    border_top_width: f32 = 0,
    border_right_width: f32 = 0,
    border_bottom_width: f32 = 0,
    border_left_width: f32 = 0,
    border_top_color: u32 = 0xFF000000,
    border_right_color: u32 = 0xFF000000,
    border_bottom_color: u32 = 0xFF000000,
    border_left_color: u32 = 0xFF000000,

    // Text properties
    text_align: TextAlign = .left,
    text_decoration: TextDecoration = .{},
    white_space: WhiteSpace = .normal,
    text_transform: TextTransform = .none,
    letter_spacing: f32 = 0,
    line_height: LineHeight = .normal,
    visibility: Visibility = .visible,

    // Dimensions
    width: Dimension = .auto,
    height: Dimension = .auto,
    min_width: Dimension = .auto,
    max_width: Dimension = .none,
    min_height: Dimension = .auto,
    max_height: Dimension = .none,

    // Overflow
    overflow_x: Overflow = .visible,
    overflow_y: Overflow = .visible,

    // Position
    position: Position = .static_,

    // List
    list_style_type: ListStyleType = .disc,

    // Float / clear / box-sizing
    float_: Float = .none,
    clear: Clear = .none,
    box_sizing: BoxSizing = .content_box,

    // Margin auto flags (for centering)
    margin_left_auto: bool = false,
    margin_right_auto: bool = false,

    // Border radius
    border_radius_tl: f32 = 0, // top-left
    border_radius_tr: f32 = 0, // top-right
    border_radius_bl: f32 = 0, // bottom-left
    border_radius_br: f32 = 0, // bottom-right

    // Flexbox properties
    flex_direction: FlexDirection = .row,
    flex_wrap: FlexWrap = .nowrap,
    justify_content: JustifyContent = .flex_start,
    align_items: AlignItems = .stretch,
    flex_grow: f32 = 0,
    flex_shrink: f32 = 1,
    flex_basis: Dimension = .auto,
    gap: f32 = 0, // column-gap, used for both row and column in flex

    pub const Display = enum {
        block,
        inline_,
        none,
        flex,
        table,
        inline_block,
        list_item,
        inline_flex,
        grid,
        inline_grid,
        table_row,
        table_cell,
        table_row_group,
        table_header_group,
        table_footer_group,
        table_column,
        table_column_group,
        table_caption,
        other,
    };

    pub const TextAlign = enum {
        left,
        right,
        center,
        justify,
    };

    pub const TextDecoration = packed struct {
        underline: bool = false,
        line_through: bool = false,
        overline: bool = false,
    };

    pub const WhiteSpace = enum {
        normal,
        pre,
        nowrap,
        pre_wrap,
        pre_line,
    };

    pub const Overflow = enum {
        visible,
        hidden,
        scroll,
        auto_,
    };

    pub const Position = enum {
        static_,
        relative,
        absolute,
        fixed,
        sticky,
    };

    pub const FontStyle = enum {
        normal,
        italic,
        oblique,
    };

    pub const ListStyleType = enum {
        disc,
        circle,
        square,
        decimal,
        none,
        other,
    };

    pub const FlexDirection = enum {
        row,
        row_reverse,
        column,
        column_reverse,
    };

    pub const FlexWrap = enum {
        nowrap,
        wrap,
        wrap_reverse,
    };

    pub const JustifyContent = enum {
        flex_start,
        flex_end,
        center,
        space_between,
        space_around,
        space_evenly,
    };

    pub const AlignItems = enum {
        stretch,
        flex_start,
        flex_end,
        center,
        baseline,
    };

    pub const Float = enum {
        none,
        left,
        right,
    };

    pub const Clear = enum {
        none,
        left,
        right,
        both,
    };

    pub const BoxSizing = enum {
        content_box,
        border_box,
    };

    pub const TextTransform = enum {
        none,
        capitalize,
        uppercase,
        lowercase,
    };

    pub const Visibility = enum {
        visible,
        hidden,
        collapse,
    };

    pub const LineHeight = union(enum) {
        normal,
        px: f32,
        number: f32,
    };

    pub const Dimension = union(enum) {
        auto,
        none,
        px: f32,
        percent: f32,
    };
};
