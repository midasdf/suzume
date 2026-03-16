// const std = @import("std");

const core = @import("core_ext.zig");
const css = @import("css_ext.zig");
const dom = @import("dom_ext.zig");
const selectors = @import("selectors_ext.zig");
const tag = @import("tag_ext.zig");

// html/interfaces/document.h

pub const lxb_html_document_done_cb_f = ?*const fn (document: ?*lxb_html_document_t) callconv(.C) core.lxb_status_t;

pub const lxb_html_document_opt_t = c_uint;

pub const lxb_html_document_ready_state_t = enum(c_int) {
    LXB_HTML_DOCUMENT_READY_STATE_UNDEF = 0x00,
    LXB_HTML_DOCUMENT_READY_STATE_LOADING = 0x01,
    LXB_HTML_DOCUMENT_READY_STATE_INTERACTIVE = 0x02,
    LXB_HTML_DOCUMENT_READY_STATE_COMPLETE = 0x03,
};

pub const lxb_html_document_opt = enum(c_int) {
    LXB_HTML_DOCUMENT_OPT_UNDEF = 0x00,
    LXB_HTML_DOCUMENT_PARSE_WO_COPY = 0x01,
};

pub const lxb_html_document_css_t = extern struct {
    memory: ?*css.lxb_css_memory_t,
    css_selectors: ?*css.lxb_css_selectors_t,
    parser: ?*css.lxb_css_parser_t,
    selectors: ?*selectors.lxb_selectors_t,
    styles: ?*core.lexbor_avl_t,
    stylesheets: ?*core.lexbor_array_t,
    weak: ?*core.lexbor_dobject_t,
    customs: ?*core.lexbor_hash_t,
    customs_id: usize,
};

pub const lxb_html_document = extern struct {
    dom_document: dom.lxb_dom_document_t,
    iframe_srcdoc: ?*anyopaque,
    head: ?*lxb_html_head_element_t,
    body: ?*lxb_html_body_element_t,
    css: lxb_html_document_css_t,
    css_init: bool,
    done: lxb_html_document_done_cb_f,
    ready_state: lxb_html_document_ready_state_t,
    opt: lxb_html_document_opt_t,
};

pub extern fn lxb_html_document_create() ?*lxb_html_document_t;
pub extern fn lxb_html_document_clean(document: ?*lxb_html_document_t) void;
pub extern fn lxb_html_document_destroy(document: ?*lxb_html_document_t) ?*lxb_html_document_t;
pub extern fn lxb_html_document_parse(document: ?*lxb_html_document_t, html: ?*const core.lxb_char_t, size: usize) core.lxb_status_t;
pub extern fn lxb_html_document_parse_chunk_begin(document: ?*lxb_html_document_t) core.lxb_status_t;
pub extern fn lxb_html_document_parse_chunk(document: ?*lxb_html_document_t, html: ?*const core.lxb_char_t, size: usize) core.lxb_status_t;
pub extern fn lxb_html_document_parse_chunk_end(document: ?*lxb_html_document_t) core.lxb_status_t;

pub extern fn lxb_html_document_title(document: ?*lxb_html_document_t, len: ?*usize) ?[*:0]core.lxb_char_t;
pub extern fn lxb_html_document_title_set(document: ?*lxb_html_document_t, title: ?*const core.lxb_char_t, len: usize) core.lxb_status_t;
pub extern fn lxb_html_document_title_raw(document: ?*lxb_html_document_t, len: ?*usize) ?[*:0]core.lxb_char_t;

// inline functions
pub inline fn lxb_html_document_body_element(document: ?*lxb_html_document_t) ?*lxb_html_body_element_t {
    return document.?.body;
}

// html/interface.h

pub inline fn lxb_html_interface_template(obj: anytype) *lxb_html_template_element_t {
    return @as(*lxb_html_template_element_t, @ptrCast(obj));
}

pub inline fn lxb_html_interface_element(obj: anytype) *lxb_html_element_t {
    return @as(*lxb_html_element_t, @ptrCast(obj));
}

pub const lxb_html_document_t = lxb_html_document;
pub const lxb_html_anchor_element_t = lxb_html_anchor_element;
pub const lxb_html_area_element_t = lxb_html_area_element;
pub const lxb_html_audio_element_t = lxb_html_audio_element;
pub const lxb_html_br_element_t = lxb_html_br_element;
pub const lxb_html_base_element_t = lxb_html_base_element;
pub const lxb_html_body_element_t = lxb_html_body_element;
pub const lxb_html_button_element_t = lxb_html_button_element;
pub const lxb_html_canvas_element_t = lxb_html_canvas_element;
pub const lxb_html_d_list_element_t = lxb_html_d_list_element;
pub const lxb_html_data_element_t = lxb_html_data_element;
pub const lxb_html_data_list_element_t = lxb_html_data_list_element;
pub const lxb_html_details_element_t = lxb_html_details_element;
pub const lxb_html_dialog_element_t = lxb_html_dialog_element;
pub const lxb_html_directory_element_t = lxb_html_directory_element;
pub const lxb_html_div_element_t = lxb_html_div_element;
pub const lxb_html_element_t = lxb_html_element;
pub const lxb_html_embed_element_t = lxb_html_embed_element;
pub const lxb_html_field_set_element_t = lxb_html_field_set_element;
pub const lxb_html_font_element_t = lxb_html_font_element;
pub const lxb_html_form_element_t = lxb_html_form_element;
pub const lxb_html_frame_element_t = lxb_html_frame_element;
pub const lxb_html_frame_set_element_t = lxb_html_frame_set_element;
pub const lxb_html_hr_element_t = lxb_html_hr_element;
pub const lxb_html_head_element_t = lxb_html_head_element;
pub const lxb_html_heading_element_t = lxb_html_heading_element;
pub const lxb_html_html_element_t = lxb_html_html_element;
pub const lxb_html_iframe_element_t = lxb_html_iframe_element;
pub const lxb_html_image_element_t = lxb_html_image_element;
pub const lxb_html_input_element_t = lxb_html_input_element;
pub const lxb_html_li_element_t = lxb_html_li_element;
pub const lxb_html_label_element_t = lxb_html_label_element;
pub const lxb_html_legend_element_t = lxb_html_legend_element;
pub const lxb_html_link_element_t = lxb_html_link_element;
pub const lxb_html_map_element_t = lxb_html_map_element;
pub const lxb_html_marquee_element_t = lxb_html_marquee_element;
pub const lxb_html_media_element_t = lxb_html_media_element;
pub const lxb_html_menu_element_t = lxb_html_menu_element;
pub const lxb_html_meta_element_t = lxb_html_meta_element;
pub const lxb_html_meter_element_t = lxb_html_meter_element;
pub const lxb_html_mod_element_t = lxb_html_mod_element;
pub const lxb_html_o_list_element_t = lxb_html_o_list_element;
pub const lxb_html_object_element_t = lxb_html_object_element;
pub const lxb_html_opt_group_element_t = lxb_html_opt_group_element;
pub const lxb_html_option_element_t = lxb_html_option_element;
pub const lxb_html_output_element_t = lxb_html_output_element;
pub const lxb_html_paragraph_element_t = lxb_html_paragraph_element;
pub const lxb_html_param_element_t = lxb_html_param_element;
pub const lxb_html_picture_element_t = lxb_html_picture_element;
pub const lxb_html_pre_element_t = lxb_html_pre_element;
pub const lxb_html_progress_element_t = lxb_html_progress_element;
pub const lxb_html_quote_element_t = lxb_html_quote_element;
pub const lxb_html_script_element_t = lxb_html_script_element;
pub const lxb_html_select_element_t = lxb_html_select_element;
pub const lxb_html_slot_element_t = lxb_html_slot_element;
pub const lxb_html_source_element_t = lxb_html_source_element;
pub const lxb_html_span_element_t = lxb_html_span_element;
pub const lxb_html_style_element_t = lxb_html_style_element;
pub const lxb_html_table_caption_element_t = lxb_html_table_caption_element;
pub const lxb_html_table_cell_element_t = lxb_html_table_cell_element;
pub const lxb_html_table_col_element_t = lxb_html_table_col_element;
pub const lxb_html_table_element_t = lxb_html_table_element;
pub const lxb_html_table_row_element_t = lxb_html_table_row_element;
pub const lxb_html_table_section_element_t = lxb_html_table_section_element;
pub const lxb_html_template_element_t = lxb_html_template_element;
pub const lxb_html_text_area_element_t = lxb_html_text_area_element;
pub const lxb_html_time_element_t = lxb_html_time_element;
pub const lxb_html_title_element_t = lxb_html_title_element;
pub const lxb_html_track_element_t = lxb_html_track_element;
pub const lxb_html_u_list_element_t = lxb_html_u_list_element;
pub const lxb_html_unknown_element_t = lxb_html_unknown_element;
pub const lxb_html_video_element_t = lxb_html_video_element;
pub const lxb_html_window_t = lxb_html_window;

// html/interfaces/anchor_element.h

pub const lxb_html_anchor_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/area_element.h

pub const lxb_html_area_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/audio_element.h

pub const lxb_html_audio_element = extern struct {
    media_element: lxb_html_media_element_t,
};

// html/interfaces/base_element.h

pub const lxb_html_base_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/body_element.h

pub const lxb_html_body_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/br_element.h

pub const lxb_html_br_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/button_element.h

pub const lxb_html_button_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/canvas_element.h

pub const lxb_html_canvas_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/d_list_element.h

pub const lxb_html_d_list_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/data_element.h

pub const lxb_html_data_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/data_list_element.h

pub const lxb_html_data_list_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/details_element.h

pub const lxb_html_details_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/dialog_element.h

pub const lxb_html_dialog_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/directory_element.h

pub const lxb_html_directory_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/div_element.h

pub const lxb_html_div_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/element.h

pub const lxb_html_element = extern struct {
    element: dom.lxb_dom_element_t,
    style: ?*core.lexbor_avl_node_t,
    list: ?*css.lxb_css_rule_declaration_list_t,
};

pub const lxb_html_element_style_opt_t = enum(c_int) {
    LXB_HTML_ELEMENT_OPT_UNDEF = 0x00,
};

pub const lxb_html_element_style_cb_f = ?*const fn (element: ?*lxb_html_element_t, declr: ?*const css.lxb_css_rule_declaration_t, ctx: ?*anyopaque, spec: css.lxb_css_selector_specificity_t, is_weak: bool) callconv(.C) core.lxb_status_t;

// html/interfaces/embed_element.h

pub const lxb_html_embed_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/field_set_element.h

pub const lxb_html_field_set_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/font_element.h

pub const lxb_html_font_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/form_element.h

pub const lxb_html_form_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/frame_element.h

pub const lxb_html_frame_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/frame_set_element.h

pub const lxb_html_frame_set_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/head_element.h

pub const lxb_html_head_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/heading_element.h

pub const lxb_html_heading_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/hr_element.h

pub const lxb_html_hr_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/html_element.h

pub const lxb_html_html_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/iframe_element.h

pub const lxb_html_iframe_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/image_element.h

pub const lxb_html_image_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/input_element.h

pub const lxb_html_input_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/label_element.h

pub const lxb_html_label_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/legend_element.h

pub const lxb_html_legend_element = extern struct {
    element: lxb_html_element_t,
};

pub extern fn lxb_html_legend_element_interface_create(document: ?*lxb_html_document_t) ?*lxb_html_legend_element_t;
pub extern fn lxb_html_legend_element_interface_destroy(legend_element: ?*lxb_html_legend_element_t) ?*lxb_html_legend_element_t;

// html/interfaces/li_element.h

pub const lxb_html_li_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/link_element.h

pub const lxb_html_link_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/map_element.h

pub const lxb_html_map_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/marquee_element.h

pub const lxb_html_marquee_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/media_element.h

pub const lxb_html_media_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/menu_element.h

pub const lxb_html_menu_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/meta_element.h

pub const lxb_html_meta_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/meter_element.h

pub const lxb_html_meter_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/mod_element.h

pub const lxb_html_mod_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/o_list_element.h

pub const lxb_html_o_list_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/object_element.h

pub const lxb_html_object_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/opt_group_element.h

pub const lxb_html_opt_group_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/option_element.h

pub const lxb_html_option_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/output_element.h

pub const lxb_html_output_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/paragraph_element.h

pub const lxb_html_paragraph_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/param_element.h

pub const lxb_html_param_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/picture_element.h

pub const lxb_html_picture_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/pre_element.h

pub const lxb_html_pre_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/progress_element.h

pub const lxb_html_progress_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/quote_element.h

pub const lxb_html_quote_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/script_element.h

pub const lxb_html_script_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/select_element.h

pub const lxb_html_select_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/slot_element.h

pub const lxb_html_slot_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/source_element.h

pub const lxb_html_source_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/span_element.h

pub const lxb_html_span_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/style_element.h

pub const lxb_html_style_element = extern struct {
    element: lxb_html_element_t,
    stylesheet: ?*css.lxb_css_stylesheet_t,
};

// html/interfaces/table_caption_element.h

pub const lxb_html_table_caption_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/table_cell_element.h

pub const lxb_html_table_cell_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/table_col_element.h

pub const lxb_html_table_col_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/table_element.h

pub const lxb_html_table_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/table_row_element.h

pub const lxb_html_table_row_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/table_section_element.h

pub const lxb_html_table_section_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/template_element.h

pub const lxb_html_template_element = extern struct {
    element: lxb_html_element_t,
    content: ?*dom.lxb_dom_document_fragment_t,
};

// html/interfaces/text_area_element.h

pub const lxb_html_text_area_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/time_element.h

pub const lxb_html_time_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/title_element.h

pub const lxb_html_title_element = extern struct {
    element: lxb_html_element_t,
    strict_text: ?*core.lexbor_str_t,
};

// html/interfaces/track_element.h

pub const lxb_html_track_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/u_list_element.h

pub const lxb_html_u_list_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/unknown_element.h

pub const lxb_html_unknown_element = extern struct {
    element: lxb_html_element_t,
};

// html/interfaces/video_element.h

pub const lxb_html_video_element = extern struct {
    media_element: lxb_html_media_element_t,
};

// html/interfaces/window.h

pub const lxb_html_window = extern struct {
    event_target: dom.lxb_dom_event_target_t,
};

// html/serialize.h

pub const lxb_html_serialize_opt_t = c_int;

pub const lxb_html_serialize_opt = enum(c_int) {
    undef = 0x00,
    skip_ws_nodes = 0x01,
    skip_comment = 0x02,
    raw = 0x04,
    without_closing = 0x08,
    tag_with_ns = 0x10,
    without_text_indent = 0x20,
    full_doctype = 0x40,
};

pub const lxb_html_serialize_cb_f = ?*const fn (data: ?[*:0]const core.lxb_char_t, len: usize, ctx: ?*anyopaque) callconv(.C) core.lxb_status_t;

pub extern fn lxb_html_serialize_pretty_tree_cb(node: ?*dom.lxb_dom_node_t, opt: lxb_html_serialize_opt_t, indent: usize, cb: lxb_html_serialize_cb_f, ctx: ?*anyopaque) core.lxb_status_t;
pub extern fn lxb_html_serialize_pretty_cb(node: ?*dom.lxb_dom_node_t, opt: lxb_html_serialize_opt_t, indent: usize, cb: lxb_html_serialize_cb_f, ctx: ?*anyopaque) core.lxb_status_t;

// html/parser.h

pub const lxb_html_parser_state_t = enum(c_int) {
    LXB_HTML_PARSER_STATE_BEGIN = 0x00,
    LXB_HTML_PARSER_STATE_PROCESS = 0x01,
    LXB_HTML_PARSER_STATE_END = 0x02,
    LXB_HTML_PARSER_STATE_FRAGMENT_PROCESS = 0x03,
    LXB_HTML_PARSER_STATE_ERROR = 0x04,
};

pub const lxb_html_parser_t = extern struct {
    tkz: ?*lxb_html_tokenizer_t,
    tree: ?*lxb_html_tree_t,
    original_tree: ?*lxb_html_tree_t,
    root: ?*dom.lxb_dom_node_t,
    form: ?*dom.lxb_dom_node_t,
    state: lxb_html_parser_state_t,
    status: core.lxb_status_t,
    ref_count: usize,
};

pub extern fn lxb_html_parser_create() ?*lxb_html_parser_t;
pub extern fn lxb_html_parser_init(parser: ?*lxb_html_parser_t) core.lxb_status_t;
pub extern fn lxb_html_parser_destroy(parser: ?*lxb_html_parser_t) ?*lxb_html_parser_t;
pub extern fn lxb_html_parse(parser: ?*lxb_html_parser_t, html: ?*const core.lxb_char_t, size: usize) ?*lxb_html_document_t;
pub extern fn lxb_html_parse_chunk_begin(parser: ?*lxb_html_parser_t) ?*lxb_html_document_t;
pub extern fn lxb_html_parse_chunk_process(parser: ?*lxb_html_parser_t, html: ?*const core.lxb_char_t, size: usize) core.lxb_status_t;
pub extern fn lxb_html_parse_chunk_end(parser: ?*lxb_html_parser_t) core.lxb_status_t;

// html/tokenizer.h

pub const lxb_html_tokenizer_state_f = ?*const fn (tkz: ?*lxb_html_tokenizer_t, data: ?*const core.lxb_char_t, end: ?*const core.lxb_char_t) callconv(.C) ?*core.lxb_char_t;

pub const lxb_html_tokenizer_token_f = ?*const fn (tkz: ?*lxb_html_tokenizer_t, token: ?*lxb_html_token_t, ctx: ?*anyopaque) callconv(.C) ?*lxb_html_token_t;

pub const lxb_html_tokenizer = extern struct {
    state: lxb_html_tokenizer_state_f,
    state_return: lxb_html_tokenizer_state_f,
    callback_token_done: lxb_html_tokenizer_token_f,
    callback_token_ctx: ?*anyopaque,
    tags: ?*core.lexbor_hash_t,
    attrs: ?*core.lexbor_hash_t,
    attrs_mraw: ?*core.lexbor_mraw_t,
    mraw: ?*core.lexbor_mraw_t,
    token: ?*lxb_html_token_t,
    dobj_token: ?*core.lexbor_dobject_t,
    dobj_token_attr: ?*core.lexbor_dobject_t,
    parse_errors: ?*core.lexbor_array_obj_t,
    tree: ?*lxb_html_tree_t,
    markup: ?*const core.lxb_char_t,
    temp: ?*const core.lxb_char_t,
    tmp_tag_id: tag.lxb_tag_id_enum_t,
    start: ?*core.lxb_char_t,
    pos: ?*core.lxb_char_t,
    end: ?*const core.lxb_char_t,
    begin: ?*const core.lxb_char_t,
    last: ?*const core.lxb_char_t,
    entity: ?*const core.lexbor_sbst_entry_static_t,
    entity_match: ?*const core.lexbor_sbst_entry_static_t,
    entity_start: usize,
    entity_end: usize,
    entity_length: u32,
    entity_number: u32,
    is_attribute: bool,
    opt: lxb_html_tokenizer_opt_t,
    status: core.lxb_status_t,
    is_eof: bool,

    base: ?*lxb_html_tokenizer_t,
    ref_count: usize,
};

pub const lxb_html_tokenizer_eof = @extern(**const core.lxb_char_t, .{ .name = "lxb_html_tokenizer_eof" });

pub extern fn lxb_html_tokenizer_create() ?*lxb_html_tokenizer_t;

pub extern fn lxb_html_tokenizer_init(tkz: ?*lxb_html_tokenizer_t) core.lxb_status_t;

pub extern fn lxb_html_tokenizer_begin(tkz: ?*lxb_html_tokenizer_t) core.lxb_status_t;

pub extern fn lxb_html_tokenizer_chunk(tkz: ?*lxb_html_tokenizer_t, data: ?*const core.lxb_char_t, size: usize) core.lxb_status_t;

pub extern fn lxb_html_tokenizer_end(tkz: ?*lxb_html_tokenizer_t) core.lxb_status_t;

pub extern fn lxb_html_tokenizer_destroy(tkz: ?*lxb_html_tokenizer_t) ?*lxb_html_tokenizer_t;

pub inline fn lxb_html_tokenizer_callback_token_done_set(tkz: ?*lxb_html_tokenizer_t, call_func: lxb_html_tokenizer_token_f, ctx: ?*anyopaque) void {
    tkz.?.callback_token_done = call_func;
    tkz.?.callback_token_ctx = ctx;
}

// html/base.h

pub const LEXBOR_HTML_VERSION_MAJOR = 2;
pub const LEXBOR_HTML_VERSION_MINOR = 5;
pub const LEXBOR_HTML_VERSION_PATCH = 0;
pub const LEXBOR_HTML_VERSION_STRING = "2.5.0";

pub const lxb_html_tokenizer_t = lxb_html_tokenizer;
pub const lxb_html_tokenizer_opt_t = c_uint;
pub const lxb_html_tree_t = lxb_html_tree;

pub const lxb_html_status_t = enum(c_int) {
    LXB_HTML_STATUS_OK = 0x0000,
};

// html/token.h

pub const lxb_html_token_type_t = c_int;

pub const lxb_html_token_type = enum(c_int) {
    open = 0x0000,
    close = 0x0001,
    close_self = 0x0002,
    force_quirks = 0x0004,
    done = 0x0008,
};

pub const lxb_html_token_t = extern struct {
    begin: ?[*]const core.lxb_char_t,
    end: ?[*]const core.lxb_char_t,
    text_start: ?[*]const core.lxb_char_t,
    text_end: ?[*]const core.lxb_char_t,
    attr_first: ?*lxb_html_token_attr_t,
    attr_last: ?*lxb_html_token_attr_t,
    base_element: ?*anyopaque,

    null_count: usize,
    tag_id: tag.lxb_tag_id_enum_t,
    type: lxb_html_token_type_t,
};

// html/tree.h

pub const lxb_html_tree_insertion_mode_f = ?*const fn (tree: ?*lxb_html_tree_t, token: ?*lxb_html_token_t) callconv(.C) bool;

pub const lxb_html_tree_append_attr_f = ?*const fn (tree: ?*lxb_html_tree_t, attr: ?*dom.lxb_dom_attr_t, ctx: ?*anyopaque) callconv(.C) core.lxb_status_t;

pub const lxb_html_tree_pending_table_t = extern struct {
    text_list: ?*core.lexbor_array_obj_t,
    have_non_ws: bool,
};

pub const lxb_html_tree = extern struct {
    tkz_ref: ?*lxb_html_tokenizer_t,
    document: ?*lxb_html_document_t,
    fragment: ?*dom.lxb_dom_node_t,
    form: ?*lxb_html_form_element_t,
    open_elements: ?*core.lexbor_array_t,
    active_formatting: ?*core.lexbor_array_t,
    template_insertion_modes: ?*core.lexbor_array_obj_t,
    pending_table: lxb_html_tree_pending_table_t,
    parse_errors: ?*core.lexbor_array_obj_t,
    foster_parenting: bool,
    frameset_ok: bool,
    scripting: bool,
    mode: lxb_html_tree_insertion_mode_f,
    original_mode: lxb_html_tree_insertion_mode_f,
    before_append_attr: lxb_html_tree_append_attr_f,
    status: core.lxb_status_t,
    ref_count: usize,
};

pub const lxb_html_tree_insertion_position_t = enum(c_int) {
    LXB_HTML_TREE_INSERTION_POSITION_CHILD = 0x00,
    LXB_HTML_TREE_INSERTION_POSITION_BEFORE = 0x01,
};

// html/token_attr.h

pub const lxb_html_token_attr_t = lxb_html_token_attr;
pub const lxb_html_token_attr_type_t = c_int;

pub const lxb_html_token_attr_type = enum(c_int) {
    LXB_HTML_TOKEN_ATTR_TYPE_UNDEF = 0x0000,
    LXB_HTML_TOKEN_ATTR_TYPE_NAME_NULL = 0x0001,
    LXB_HTML_TOKEN_ATTR_TYPE_VALUE_NULL = 0x0002,
};

pub const lxb_html_token_attr = extern struct {
    name_begin: ?[*]const core.lxb_char_t,
    name_end: ?[*]const core.lxb_char_t,
    value_begin: ?[*]const core.lxb_char_t,
    value_end: ?[*]const core.lxb_char_t,
    name: ?*const dom.lxb_dom_attr_data_t,
    value: ?[*:0]core.lxb_char_t,
    value_size: usize,
    next: ?*lxb_html_token_attr_t,
    prev: ?*lxb_html_token_attr_t,
    type: lxb_html_token_attr_type_t,
};

pub extern fn lxb_html_token_attr_create(dobj: ?*core.lexbor_dobject_t) ?*lxb_html_token_attr_t;

pub extern fn lxb_html_token_attr_clean(attr: ?*lxb_html_token_attr_t) void;

pub extern fn lxb_html_token_attr_destroy(attr: ?*lxb_html_token_attr_t, dobj: ?*core.lexbor_dobject_t) ?*lxb_html_token_attr_t;

pub extern fn lxb_html_token_attr_name(attr: ?*lxb_html_token_attr_t, length: ?*usize) ?[*:0]const core.lxb_char_t;

// html/tag.h

pub const lxb_html_tag_category_t = c_int;

pub const lxb_html_tag_category = enum(c_int) {
    LXB_HTML_TAG_CATEGORY__UNDEF = 0x0000,
    LXB_HTML_TAG_CATEGORY_ORDINARY = 0x0001,
    LXB_HTML_TAG_CATEGORY_SPECIAL = 0x0002,
    LXB_HTML_TAG_CATEGORY_FORMATTING = 0x0004,
    LXB_HTML_TAG_CATEGORY_SCOPE = 0x0008,
    LXB_HTML_TAG_CATEGORY_SCOPE_LIST_ITEM = 0x0010,
    LXB_HTML_TAG_CATEGORY_SCOPE_BUTTON = 0x0020,
    LXB_HTML_TAG_CATEGORY_SCOPE_TABLE = 0x0040,
    LXB_HTML_TAG_CATEGORY_SCOPE_SELECT = 0x0080,
};

pub const lxb_html_tag_fixname_t = extern struct {
    name: ?*const core.lxb_char_t,
    len: c_uint,
};

// TODO: #define LXB_HTML_TAG_RES_CATS
// TODO: #define LXB_HTML_TAG_RES_FIXNAME_SVG

pub inline fn lxb_html_tag_is_void(tag_id: tag.lxb_tag_id_enum_t) bool {
    switch (tag_id) {
        .area,
        .base,
        .br,
        .col,
        .embed,
        .hr,
        .img,
        .input,
        .link,
        .meta,
        .source,
        .track,
        .wbr,
        => return true,
        else => return false,
    }
}

// html/interfaces/element.h

pub extern fn lxb_html_element_inner_html_set(element: ?*lxb_html_element_t, html: ?*const core.lxb_char_t, size: usize) ?*lxb_html_element_t;

// html/encoding.h

pub const lxb_html_encoding_entry_t = extern struct {
    name: ?[*]const core.lxb_char_t,
    end: ?[*]const core.lxb_char_t,
};

pub const lxb_html_encoding_t = extern struct {
    cache: core.lexbor_array_obj_t,
    result: core.lexbor_array_obj_t,
};

pub extern fn lxb_html_encoding_init(em: ?*lxb_html_encoding_t) core.lxb_status_t;

pub extern fn lxb_html_encoding_destroy(em: ?*lxb_html_encoding_t, self_destroy: bool) ?*lxb_html_encoding_t;

pub extern fn lxb_html_encoding_determine(em: ?*lxb_html_encoding_t, data: ?*const core.lxb_char_t, end: ?*const core.lxb_char_t) core.lxb_status_t;

pub extern fn lxb_html_encoding_content(data: ?*const core.lxb_char_t, end: ?*const core.lxb_char_t, name_end: ?*?*const core.lxb_char_t) ?[*:0]const core.lxb_char_t;

pub inline fn lxb_html_encoding_meta_entry(em: ?*lxb_html_encoding_t, idx: usize) ?*lxb_html_encoding_entry_t {
    return @ptrCast(@alignCast(core.lexbor_array_obj_get(&em.?.result, idx)));
}
