// const std = @import("std");

const core = @import("core_ext.zig");
const ns = @import("ns_ext.zig");
const tag = @import("tag_ext.zig");

// dom/interfaces/document.h

pub const lxb_dom_document_cmode_t = enum(c_int) {
    LXB_DOM_DOCUMENT_CMODE_NO_QUIRKS = 0x00,
    LXB_DOM_DOCUMENT_CMODE_QUIRKS = 0x01,
    LXB_DOM_DOCUMENT_CMODE_LIMITED_QUIRKS = 0x02,
};

pub const lxb_dom_document_dtype_t = enum(c_int) {
    LXB_DOM_DOCUMENT_DTYPE_UNDEF = 0x00,
    LXB_DOM_DOCUMENT_DTYPE_HTML = 0x01,
    LXB_DOM_DOCUMENT_DTYPE_XML = 0x02,
};

pub const lxb_dom_document = extern struct {
    node: lxb_dom_node_t,

    compat_mode: lxb_dom_document_cmode_t,
    type: lxb_dom_document_dtype_t,

    doctype: ?*lxb_dom_document_type_t,
    element: ?*lxb_dom_element_t,

    create_interface: lxb_dom_interface_create_f,
    clone_interface: lxb_dom_interface_clone_f,
    destroy_interface: lxb_dom_interface_destroy_f,

    ev_insert: lxb_dom_event_insert_f,
    ev_remove: lxb_dom_event_remove_f,
    ev_destroy: lxb_dom_event_destroy_f,
    ev_set_value: lxb_dom_event_set_value_f,

    mraw: ?*core.lexbor_mraw_t,
    text: ?*core.lexbor_mraw_t,
    tags: ?*core.lexbor_hash_t,
    attrs: ?*core.lexbor_hash_t,
    prefix: ?*core.lexbor_hash_t,
    ns: ?*core.lexbor_hash_t,
    parser: ?*anyopaque,
    user: ?*anyopaque,

    tags_inherited: bool,
    ns_inherited: bool,

    scripting: bool,
};

pub extern fn lxb_dom_document_create_element(document: ?*lxb_dom_document_t, local_name: ?*const core.lxb_char_t, lname_len: usize, reserved_for_opt: ?*anyopaque) ?*lxb_dom_element_t;

pub extern fn lxb_dom_document_create_text_node(document: ?*lxb_dom_document_t, data: ?*const core.lxb_char_t, len: usize) ?*lxb_dom_text_t;

// dom/interfaces/node.h

pub const lxb_dom_node_simple_walker_f = ?*const fn (node: ?*lxb_dom_node_t, ctx: ?*anyopaque) callconv(.C) core.lexbor_action_t;

pub const lxb_dom_node_type_t = enum(c_int) {
    undef = 0x00,
    element = 0x01,
    attribute = 0x02,
    text = 0x03,
    cdata_section = 0x04,
    entity_reference = 0x05, // HISTORICAL
    entity = 0x06, // HISTORICAL
    processing_instruction = 0x07,
    comment = 0x08,
    document = 0x09,
    document_type = 0x0a,
    document_fragment = 0x0b,
    notation = 0x0c, // HISTORICAL
    last_entry = 0x0d,
};

pub const lxb_dom_node = extern struct {
    event_target: lxb_dom_event_target_t,

    local_name: usize,
    prefix: usize,
    ns: usize,

    owner_document: ?*lxb_dom_document_t,

    next: ?*lxb_dom_node_t,
    prev: ?*lxb_dom_node_t,
    parent: ?*lxb_dom_node_t,
    first_child: ?*lxb_dom_node_t,
    last_child: ?*lxb_dom_node_t,
    user: ?*anyopaque,

    type: lxb_dom_node_type_t,

    // #ifdef LXB_DOM_NODE_USER_VARIABLES
    //     LXB_DOM_NODE_USER_VARIABLES
    // #endif /* LXB_DOM_NODE_USER_VARIABLES */
};

pub extern fn lxb_dom_node_insert_child(to: ?*lxb_dom_node_t, node: ?*lxb_dom_node_t) void;

// dom/interface.h

pub inline fn lxb_dom_interface_node(obj: anytype) *lxb_dom_node_t {
    return @as(*lxb_dom_node_t, @ptrCast(obj));
}

pub inline fn lxb_dom_interface_element(obj: anytype) *lxb_dom_element_t {
    return @as(*lxb_dom_element_t, @ptrCast(obj));
}

pub const lxb_dom_event_target_t = lxb_dom_event_target;
pub const lxb_dom_node_t = lxb_dom_node;
pub const lxb_dom_element_t = lxb_dom_element;
pub const lxb_dom_attr_t = lxb_dom_attr;
pub const lxb_dom_document_t = lxb_dom_document;
pub const lxb_dom_document_type_t = lxb_dom_document_type;
pub const lxb_dom_document_fragment_t = lxb_dom_document_fragment;
pub const lxb_dom_shadow_root_t = lxb_dom_shadow_root;
pub const lxb_dom_character_data_t = lxb_dom_character_data;
pub const lxb_dom_text_t = lxb_dom_text;
pub const lxb_dom_cdata_section_t = lxb_dom_cdata_section;
pub const lxb_dom_processing_instruction_t = lxb_dom_processing_instruction;
pub const lxb_dom_comment_t = lxb_dom_comment;

pub const lxb_dom_interface_t = void;

pub const lxb_dom_interface_constructor_f = ?*const fn (document: ?*anyopaque) callconv(.C) ?*anyopaque;

pub const lxb_dom_interface_destructor_f = ?*const fn (intrfc: ?*anyopaque) callconv(.C) ?*anyopaque;

pub const lxb_dom_interface_create_f = ?*const fn (document: ?*lxb_dom_document_t, tag_id: tag.lxb_tag_id_enum_t, ns: ns.lxb_ns_id_t) callconv(.C) ?*lxb_dom_interface_t;

pub const lxb_dom_interface_clone_f = ?*const fn (document: ?*lxb_dom_document_t, intrfc: ?*const lxb_dom_interface_t) callconv(.C) ?*lxb_dom_interface_t;

pub const lxb_dom_interface_destroy_f = ?*const fn (intrfc: ?*lxb_dom_interface_t) callconv(.C) ?*lxb_dom_interface_t;

pub const lxb_dom_event_insert_f = ?*const fn (node: ?*lxb_dom_node_t) callconv(.C) core.lxb_status_t;

pub const lxb_dom_event_remove_f = ?*const fn (node: ?*lxb_dom_node_t) callconv(.C) core.lxb_status_t;

pub const lxb_dom_event_destroy_f = ?*const fn (node: ?*lxb_dom_node_t) callconv(.C) core.lxb_status_t;

pub const lxb_dom_event_set_value_f = ?*const fn (node: ?*lxb_dom_node_t, value: ?*const core.lxb_char_t, length: usize) callconv(.C) core.lxb_status_t;

// dom/interfaces/event_target.h

pub const lxb_dom_event_target = extern struct {
    events: ?*anyopaque,
};

// dom/interfaces/element.h

pub const lxb_dom_element_custom_state_t = enum(c_int) {
    LXB_DOM_ELEMENT_CUSTOM_STATE_UNDEFINED = 0x00,
    LXB_DOM_ELEMENT_CUSTOM_STATE_FAILED = 0x01,
    LXB_DOM_ELEMENT_CUSTOM_STATE_UNCUSTOMIZED = 0x02,
    LXB_DOM_ELEMENT_CUSTOM_STATE_CUSTOM = 0x03,
};

pub const lxb_dom_element = extern struct {
    node: lxb_dom_node_t,
    upper_name: lxb_dom_attr_id_t,
    qualified_name: lxb_dom_attr_id_t,
    is_value: ?*core.lexbor_str_t,
    first_attr: ?*lxb_dom_attr_t,
    last_attr: ?*lxb_dom_attr_t,
    attr_id: ?*lxb_dom_attr_t,
    attr_class: ?*lxb_dom_attr_t,
    custom_state: lxb_dom_element_custom_state_t,
};

pub extern fn lxb_dom_elements_by_tag_name(root: ?*lxb_dom_element_t, collection: ?*lxb_dom_collection_t, qualified_name: ?*const core.lxb_char_t, len: usize) core.lexbor_status_t;

pub extern fn lxb_dom_elements_by_class_name(root: ?*lxb_dom_element_t, collection: ?*lxb_dom_collection_t, class_name: ?*const core.lxb_char_t, len: usize) core.lexbor_status_t;

pub extern fn lxb_dom_elements_by_attr_begin(root: ?*lxb_dom_element_t, collection: ?*lxb_dom_collection_t, qualified_name: ?*const core.lxb_char_t, qname_len: usize, value: ?*const core.lxb_char_t, value_len: usize, case_insensitive: bool) core.lexbor_status_t;

pub extern fn lxb_dom_elements_by_attr_end(root: ?*lxb_dom_element_t, collection: ?*lxb_dom_collection_t, qualified_name: ?*const core.lxb_char_t, qname_len: usize, value: ?*const core.lxb_char_t, value_len: usize, case_insensitive: bool) core.lexbor_status_t;

pub extern fn lxb_dom_elements_by_attr_contain(root: ?*lxb_dom_element_t, collection: ?*lxb_dom_collection_t, qualified_name: ?*const core.lxb_char_t, qname_len: usize, value: ?*const core.lxb_char_t, value_len: usize, case_insensitive: bool) core.lexbor_status_t;

pub extern fn lxb_dom_elements_by_attr(root: ?*lxb_dom_element_t, collection: ?*lxb_dom_collection_t, qualified_name: ?*const core.lxb_char_t, qname_len: usize, value: ?*const core.lxb_char_t, value_len: usize, case_insensitive: bool) core.lexbor_status_t;

pub extern fn lxb_dom_element_set_attribute(element: ?*lxb_dom_element_t, qualified_name: ?*const core.lxb_char_t, qn_len: usize, value: ?*const core.lxb_char_t, value_len: usize) ?*lxb_dom_attr_t;

pub extern fn lxb_dom_element_has_attribute(element: ?*lxb_dom_element_t, qualified_name: ?*const core.lxb_char_t, qn_len: usize) bool;

pub extern fn lxb_dom_element_get_attribute(element: ?*lxb_dom_element_t, qualified_name: ?*const core.lxb_char_t, qn_len: usize, value_len: ?*usize) ?[*:0]const core.lxb_char_t;

pub extern fn lxb_dom_element_attr_by_name(element: ?*lxb_dom_element_t, qualified_name: ?*const core.lxb_char_t, length: usize) ?*lxb_dom_attr_t;

pub extern fn lxb_dom_element_remove_attribute(element: ?*lxb_dom_element_t, qualified_name: ?*const core.lxb_char_t, qn_len: usize) core.lxb_status_t;

pub extern fn lxb_dom_element_qualified_name(element: ?*lxb_dom_element_t, len: ?*usize) ?[*:0]const core.lxb_char_t;

pub inline fn lxb_dom_element_first_attribute(element: ?*lxb_dom_element_t) ?*lxb_dom_attr_t {
    return element.?.first_attr;
}

pub inline fn lxb_dom_element_prev_attribute(attr: ?*lxb_dom_attr_t) ?*lxb_dom_attr_t {
    return attr.?.prev;
}

pub inline fn lxb_dom_element_next_attribute(attr: ?*lxb_dom_attr_t) ?*lxb_dom_attr_t {
    return attr.?.next;
}

// dom/interfaces/attr.h

pub const lxb_dom_attr_data_t = extern struct {
    entry: core.lexbor_hash_entry_t,
    attr_id: lxb_dom_attr_id_t,
    ref_count: usize,
    read_only: bool,
};

pub const lxb_dom_attr = extern struct {
    node: lxb_dom_node_t,
    upper_name: lxb_dom_attr_id_t,
    qualified_name: lxb_dom_attr_id_t,
    value: ?*core.lexbor_str_t,
    owner: ?*lxb_dom_element_t,
    next: ?*lxb_dom_attr_t,
    prev: ?*lxb_dom_attr_t,
};

pub extern fn lxb_dom_attr_qualified_name(attr: ?*lxb_dom_attr_t, len: ?*usize) ?[*:0]core.lxb_char_t;

pub extern fn lxb_dom_attr_set_value(attr: ?*lxb_dom_attr_t, value: ?*const core.lxb_char_t, value_len: usize) core.lxb_status_t;

pub inline fn lxb_dom_attr_value(attr: ?*lxb_dom_attr_t, len: ?*usize) ?[*:0]const core.lxb_char_t {
    if (attr.?.value == null) {
        if (len != null) {
            len.?.* = 0;
        }

        return null;
    }

    if (len != null) {
        len.?.* = attr.?.value.?.length;
    }

    return @ptrCast(attr.?.value.?.data);
}

// dom/interfaces/attr_const.h

pub const lxb_dom_attr_id_t = usize;

pub const lxb_dom_attr_id_enum_t = enum(c_int) {
    LXB_DOM_ATTR__UNDEF = 0x0000,
    LXB_DOM_ATTR_ACTIVE = 0x0001,
    LXB_DOM_ATTR_ALT = 0x0002,
    LXB_DOM_ATTR_CHARSET = 0x0003,
    LXB_DOM_ATTR_CHECKED = 0x0004,
    LXB_DOM_ATTR_CLASS = 0x0005,
    LXB_DOM_ATTR_COLOR = 0x0006,
    LXB_DOM_ATTR_CONTENT = 0x0007,
    LXB_DOM_ATTR_DIR = 0x0008,
    LXB_DOM_ATTR_DISABLED = 0x0009,
    LXB_DOM_ATTR_FACE = 0x000a,
    LXB_DOM_ATTR_FOCUS = 0x000b,
    LXB_DOM_ATTR_FOR = 0x000c,
    LXB_DOM_ATTR_HEIGHT = 0x000d,
    LXB_DOM_ATTR_HOVER = 0x000e,
    LXB_DOM_ATTR_HREF = 0x000f,
    LXB_DOM_ATTR_HTML = 0x0010,
    LXB_DOM_ATTR_HTTP_EQUIV = 0x0011,
    LXB_DOM_ATTR_ID = 0x0012,
    LXB_DOM_ATTR_IS = 0x0013,
    LXB_DOM_ATTR_MAXLENGTH = 0x0014,
    LXB_DOM_ATTR_PLACEHOLDER = 0x0015,
    LXB_DOM_ATTR_POOL = 0x0016,
    LXB_DOM_ATTR_PUBLIC = 0x0017,
    LXB_DOM_ATTR_READONLY = 0x0018,
    LXB_DOM_ATTR_REQUIRED = 0x0019,
    LXB_DOM_ATTR_SCHEME = 0x001a,
    LXB_DOM_ATTR_SELECTED = 0x001b,
    LXB_DOM_ATTR_SIZE = 0x001c,
    LXB_DOM_ATTR_SLOT = 0x001d,
    LXB_DOM_ATTR_SRC = 0x001e,
    LXB_DOM_ATTR_STYLE = 0x001f,
    LXB_DOM_ATTR_SYSTEM = 0x0020,
    LXB_DOM_ATTR_TITLE = 0x0021,
    LXB_DOM_ATTR_TYPE = 0x0022,
    LXB_DOM_ATTR_WIDTH = 0x0023,
    LXB_DOM_ATTR__LAST_ENTRY = 0x0024,
};

// dom/interfaces/document_type.h

pub const lxb_dom_document_type = extern struct {
    node: lxb_dom_node_t,
    name: lxb_dom_attr_id_t,
    public_id: core.lexbor_str_t,
    system_id: core.lexbor_str_t,
};

// dom/interfaces/document_fragment.h

pub const lxb_dom_document_fragment = extern struct {
    node: lxb_dom_node_t,
    host: ?*lxb_dom_element_t,
};

// dom/interfaces/character_data.h

pub const lxb_dom_character_data = extern struct {
    node: lxb_dom_node_t,
    data: core.lexbor_str_t,
};

// dom/interfaces/cdata_section.h

pub const lxb_dom_cdata_section = extern struct {
    text: lxb_dom_text_t,
};

// dom/interfaces/comment.h

pub const lxb_dom_comment = extern struct {
    char_data: lxb_dom_character_data_t,
};

// dom/interfaces/shadow_root.h

pub const lxb_dom_shadow_root_mode_t = enum(c_int) {
    LXB_DOM_SHADOW_ROOT_MODE_OPEN = 0x00,
    LXB_DOM_SHADOW_ROOT_MODE_CLOSED = 0x01,
};

pub const lxb_dom_shadow_root = extern struct {
    document_fragment: lxb_dom_document_fragment_t,
    mode: lxb_dom_shadow_root_mode_t,
    host: ?*lxb_dom_element_t,
};

// dom/interfaces/text.h

pub const lxb_dom_text = extern struct {
    char_data: lxb_dom_character_data_t,
};

// dom/interfaces/processing_instruction.h

pub const lxb_dom_processing_instruction = extern struct {
    char_data: lxb_dom_character_data_t,
    target: core.lexbor_str_t,
};

// dom/collection.h
pub const lxb_dom_collection_t = extern struct {
    array: core.lexbor_array_t,
    document: ?*lxb_dom_document_t,
};

pub extern fn lxb_dom_collection_create(document: ?*lxb_dom_document_t) ?*lxb_dom_collection_t;
pub extern fn lxb_dom_collection_init(col: ?*lxb_dom_collection_t, start_list_size: usize) core.lxb_status_t;
pub extern fn lxb_dom_collection_destroy(col: ?*lxb_dom_collection_t, self_destroy: bool) ?*lxb_dom_collection_t;

pub inline fn lxb_dom_collection_make(document: ?*lxb_dom_document_t, start_list_size: usize) ?*lxb_dom_collection_t {
    const col = lxb_dom_collection_create(document);
    const status = lxb_dom_collection_init(col, start_list_size);

    if (status != @intFromEnum(core.lexbor_status_t.ok)) {
        return lxb_dom_collection_destroy(col, true);
    }

    return col;
}

pub inline fn lxb_dom_collection_length(col: ?*lxb_dom_collection_t) usize {
    return core.lexbor_array_length(&col.?.array);
}

pub inline fn lxb_dom_collection_element(col: ?*lxb_dom_collection_t, idx: usize) ?*lxb_dom_element_t {
    return @ptrCast(@alignCast(core.lexbor_array_get(&col.?.array, idx)));
}

pub inline fn lxb_dom_collection_clean(col: ?*lxb_dom_collection_t) void {
    core.lexbor_array_clean(&col.?.array);
}
