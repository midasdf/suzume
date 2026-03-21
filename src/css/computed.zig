/// Zig-friendly computed style struct extracted from LibCSS's css_computed_style.
///
/// Fields are organized into logical groups for readability and to prepare for a
/// future optimization where the struct is split into sub-structs (inherited vs.
/// non-inherited, box-model, visual-effects, etc.) so that parent styles can share
/// a single heap-allocated pointer for the inherited portion instead of copying
/// every field on every child node.  That refactoring would touch layout, paint,
/// cascade, and the whole tree traversal, so it is deferred; the grouping here
/// makes the eventual split straightforward.
pub const FontFamily = enum(u8) {
    sans_serif, // Verdana, Arial, Helvetica, system-ui, sans-serif
    serif, // Times, Georgia, serif
    monospace, // Courier, monospace
};

pub const ComputedStyle = struct {

    // ═══════════════════════════════════════════════════════════════
    // Inherited Properties (cascade from parent when not overridden)
    // ═══════════════════════════════════════════════════════════════

    // Color & typography
    color: u32 = 0xFF000000, // ARGB, standard black text default
    color_set_by_css: bool = false, // true when CSS explicitly set color
    font_size_px: f32 = 16.0,
    font_family: FontFamily = .sans_serif,
    font_weight: u16 = 400,
    font_style: FontStyle = .normal,
    line_height: LineHeight = .normal,
    letter_spacing: f32 = 0,

    // Text layout & wrapping
    text_align: TextAlign = .left,
    text_decoration: TextDecoration = .{},
    text_transform: TextTransform = .none,
    text_overflow: TextOverflow = .clip,
    white_space: WhiteSpace = .normal,
    word_break: WordBreak = .normal,
    overflow_wrap: OverflowWrap = .normal,
    vertical_align: VerticalAlign = .baseline,

    // Other inherited properties
    visibility: Visibility = .visible,
    list_style_type: ListStyleType = .disc,

    // ═══════════════════════════════════════════════════════════════
    // Box Model (non-inherited)
    // ═══════════════════════════════════════════════════════════════

    display: Display = .block,
    box_sizing: BoxSizing = .content_box,

    // Dimensions
    width: Dimension = .auto,
    height: Dimension = .auto,
    min_width: Dimension = .auto,
    max_width: Dimension = .none,
    min_height: Dimension = .auto,
    max_height: Dimension = .none,

    // Margins
    margin_top: f32 = 0,
    margin_right: f32 = 0,
    margin_bottom: f32 = 0,
    margin_left: f32 = 0,
    margin_top_auto: bool = false,
    margin_bottom_auto: bool = false,
    margin_left_auto: bool = false,
    margin_right_auto: bool = false,

    // Padding
    padding_top: f32 = 0,
    padding_right: f32 = 0,
    padding_bottom: f32 = 0,
    padding_left: f32 = 0,

    // Borders
    border_top_width: f32 = 0,
    border_right_width: f32 = 0,
    border_bottom_width: f32 = 0,
    border_left_width: f32 = 0,
    border_top_color: u32 = 0xFF000000,
    border_right_color: u32 = 0xFF000000,
    border_bottom_color: u32 = 0xFF000000,
    border_left_color: u32 = 0xFF000000,
    border_radius_tl: f32 = 0, // top-left
    border_radius_tr: f32 = 0, // top-right
    border_radius_bl: f32 = 0, // bottom-left
    border_radius_br: f32 = 0, // bottom-right

    // Overflow
    overflow_x: Overflow = .visible,
    overflow_y: Overflow = .visible,

    // Positioning
    position: Position = .static_,
    z_index: i32 = 0,
    top: Dimension = .auto,
    left: Dimension = .auto,
    right: Dimension = .auto,
    bottom: Dimension = .auto,

    // Float & clear
    float_: Float = .none,
    clear: Clear = .none,

    // ═══════════════════════════════════════════════════════════════
    // Flexbox
    // ═══════════════════════════════════════════════════════════════

    flex_direction: FlexDirection = .row,
    flex_wrap: FlexWrap = .nowrap,
    justify_content: JustifyContent = .flex_start,
    align_content: AlignContent = .stretch,
    align_items: AlignItems = .stretch,
    align_self: AlignItems = .auto,
    flex_grow: f32 = 0,
    flex_shrink: f32 = 1,
    flex_basis: Dimension = .auto,
    order: i32 = 0, // flex/grid item order (default 0)
    gap: f32 = 0, // column-gap, used for both row and column in flex
    row_gap: f32 = 0, // row-gap, separate from column gap

    // ═══════════════════════════════════════════════════════════════
    // Grid
    // ═══════════════════════════════════════════════════════════════

    grid_template_columns: []const GridTrackSize = &.{},
    grid_template_rows: []const GridTrackSize = &.{},
    grid_auto_flow: GridAutoFlow = .row,
    grid_auto_columns: GridTrackSize = .auto,
    grid_column_start: i16 = 0, // 0 = auto
    grid_column_end: i16 = 0,
    grid_row_start: i16 = 0,
    grid_row_end: i16 = 0,
    grid_column_span: u16 = 1,
    grid_row_span: u16 = 1,

    // ═══════════════════════════════════════════════════════════════
    // Visual Effects
    // ═══════════════════════════════════════════════════════════════

    background_color: u32 = 0x00000000, // ARGB, transparent default
    /// CSS background-image url() value. Points into CSS AST source memory —
    /// valid as long as the owning CascadeResult (page.styles) is alive.
    /// Freed when CascadeResult.deinit() is called during restyle.
    background_image_url: ?[]const u8 = null,
    opacity: f32 = 1.0,
    object_fit: ObjectFit = .fill,

    // Box shadow
    box_shadow_x: f32 = 0,
    box_shadow_y: f32 = 0,
    box_shadow_blur: f32 = 0,
    box_shadow_color: u32 = 0x00000000, // ARGB, transparent = no shadow

    // Text shadow
    text_shadow_x: f32 = 0,
    text_shadow_y: f32 = 0,
    text_shadow_blur: f32 = 0,
    text_shadow_color: u32 = 0x00000000, // ARGB, transparent = no shadow

    // Linear gradient (basic 2-color)
    gradient_color_start: u32 = 0x00000000, // ARGB, transparent = no gradient
    gradient_color_end: u32 = 0x00000000, // ARGB
    gradient_direction: GradientDirection = .to_bottom,

    // Filters
    filter_grayscale: f32 = 0,
    filter_brightness: f32 = 1,
    filter_blur: f32 = 0,

    // Outline
    outline_width: f32 = 0,
    outline_color: u32 = 0xFF000000,

    // ═══════════════════════════════════════════════════════════════
    // Transforms & Animations
    // ═══════════════════════════════════════════════════════════════

    // Transforms
    transform_translate_x: f32 = 0,
    transform_translate_y: f32 = 0,

    // Transitions (parsed but not yet animated)
    transition_duration: f32 = 0,
    transition_delay: f32 = 0,

    // Animations (parsed but not yet animated)
    animation_name: ?[]const u8 = null,
    animation_duration: f32 = 0,

    // ═══════════════════════════════════════════════════════════════
    // Counters & Generated Content
    // ═══════════════════════════════════════════════════════════════

    counter_reset: ?[]const u8 = null,
    counter_increment: ?[]const u8 = null,

    // CSS content property (for ::before/::after pseudo-elements)
    content: ?[]const u8 = null,

    // ═══════════════════════════════════════════════════════════════
    // Pseudo-elements (::before / ::after)
    // ═══════════════════════════════════════════════════════════════

    before_content: ?[]const u8 = null,
    after_content: ?[]const u8 = null,
    before_display: Display = .inline_,
    after_display: Display = .inline_,

    // ═══════════════════════════════════════════════════════════════
    // Type Definitions
    // ═══════════════════════════════════════════════════════════════

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
        auto, // align-self default: inherit from parent's align-items
        stretch,
        flex_start,
        flex_end,
        center,
        baseline,
    };

    pub const AlignContent = enum {
        stretch,
        flex_start,
        flex_end,
        center,
        space_between,
        space_around,
        space_evenly,
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

    pub const VerticalAlign = enum {
        baseline,
        top,
        middle,
        bottom,
        text_top,
        text_bottom,
        sub,
        super,
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

    pub const WordBreak = enum {
        normal,
        break_all,
        keep_all,
    };

    pub const OverflowWrap = enum {
        normal,
        break_word,
        anywhere,
    };

    pub const TextOverflow = enum {
        clip,
        ellipsis,
    };

    pub const GradientDirection = enum {
        to_bottom,
        to_right,
        to_top,
        to_left,
    };

    pub const GridTrackSize = union(enum) {
        px: f32,
        fr: f32,
        percent: f32,
        auto,
    };

    pub const GridAutoFlow = enum {
        row,
        column,
    };

    pub const ObjectFit = enum { fill, contain, cover, none, scale_down };
};
