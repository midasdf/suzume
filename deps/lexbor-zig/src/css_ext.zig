// const std = @import("std");

const core = @import("core_ext.zig");

// css/base.h

pub const LEXBOR_CSS_VERSION_MAJOR = 1;
pub const LEXBOR_CSS_VERSION_MINOR = 2;
pub const LEXBOR_CSS_VERSION_PATCH = 0;
pub const LEXBOR_CSS_VERSION_STRING = "1.2.0";

pub const lxb_css_memory_t = extern struct {
    objs: ?*core.lexbor_dobject_t,
    mraw: ?*core.lexbor_mraw_t,
    tree: ?*core.lexbor_mraw_t,
};

pub const lxb_css_type_t = u32;

pub const lxb_css_parser_t = lxb_css_parser;
pub const lxb_css_parser_state_t = lxb_css_parser_state;
pub const lxb_css_parser_error_t = lxb_css_parser_error;

pub const lxb_css_syntax_tokenizer_t = lxb_css_syntax_tokenizer;
pub const lxb_css_syntax_token_t = lxb_css_syntax_token;

pub const lxb_css_parser_state_f = ?*const fn (parser: ?*lxb_css_parser_t, token: ?*const lxb_css_syntax_token_t, ctx: ?*anyopaque) callconv(.C) bool;

pub const lxb_css_style_create_f = ?*const fn (memory: ?*lxb_css_memory_t) callconv(.C) ?*anyopaque;

pub const lxb_css_style_serialize_f = ?*const fn (style: ?*const anyopaque, cb: core.lexbor_serialize_cb_f, ctx: ?*anyopaque) callconv(.C) core.lxb_status_t;

pub const lxb_css_style_destroy_f = ?*const fn (memory: ?*lxb_css_memory_t, style: ?*anyopaque, self_destroy: bool) callconv(.C) ?*anyopaque;

pub const lxb_css_stylesheet_t = lxb_css_stylesheet;
pub const lxb_css_rule_list_t = lxb_css_rule_list;
pub const lxb_css_rule_style_t = lxb_css_rule_style;
pub const lxb_css_rule_bad_style_t = lxb_css_rule_bad_style;
pub const lxb_css_rule_declaration_list_t = lxb_css_rule_declaration_list;
pub const lxb_css_rule_declaration_t = lxb_css_rule_declaration;
pub const lxb_css_rule_at_t = lxb_css_rule_at;

pub const lxb_css_entry_data_t = extern struct {
    name: core.lxb_char_t,
    length: usize,
    unique: usize,
    state: lxb_css_parser_state_f,
    create: lxb_css_style_create_f,
    destroy: lxb_css_style_destroy_f,
    serialize: lxb_css_style_serialize_f,
    initial: ?*anyopaque,
};

pub const lxb_css_data_t = extern struct {
    name: ?*core.lxb_char_t,
    length: usize,
    unique: usize,
};

// css/selectors/base.h

pub const lxb_css_selectors_t = lxb_css_selectors;
pub const lxb_css_selector_t = lxb_css_selector;
pub const lxb_css_selector_list_t = lxb_css_selector_list;

// css/selectors/selectors.h

pub const lxb_css_selectors = extern struct {
    list: ?*lxb_css_selector_list_t,
    list_last: ?*lxb_css_selector_list_t,
    parent: ?*lxb_css_selector_t,
    combinator: lxb_css_selector_combinator_t,
    comb_default: lxb_css_selector_combinator_t,
    @"error": usize,
    status: bool,
    err_in_function: bool,
    failed: bool,
};

// css/selectors/selector.h

pub const lxb_css_selector_type_t = enum(c_int) {
    LXB_CSS_SELECTOR_TYPE__UNDEF = 0x00,
    LXB_CSS_SELECTOR_TYPE_ANY,
    LXB_CSS_SELECTOR_TYPE_ELEMENT, // div, tag name <div>
    LXB_CSS_SELECTOR_TYPE_ID, // #hash
    LXB_CSS_SELECTOR_TYPE_CLASS, // .class
    LXB_CSS_SELECTOR_TYPE_ATTRIBUTE, // [key=val], <... key="val">
    LXB_CSS_SELECTOR_TYPE_PSEUDO_CLASS, // :pseudo
    LXB_CSS_SELECTOR_TYPE_PSEUDO_CLASS_FUNCTION, // :function(...)
    LXB_CSS_SELECTOR_TYPE_PSEUDO_ELEMENT, // ::pseudo */
    LXB_CSS_SELECTOR_TYPE_PSEUDO_ELEMENT_FUNCTION, // ::function(...)
    LXB_CSS_SELECTOR_TYPE__LAST_ENTRY,
};

pub const lxb_css_selector_combinator_t = enum(c_int) {
    LXB_CSS_SELECTOR_COMBINATOR_DESCENDANT = 0x00, // WHITESPACE
    LXB_CSS_SELECTOR_COMBINATOR_CLOSE, // two compound selectors [key=val].foo
    LXB_CSS_SELECTOR_COMBINATOR_CHILD, // '>'
    LXB_CSS_SELECTOR_COMBINATOR_SIBLING, // '+'
    LXB_CSS_SELECTOR_COMBINATOR_FOLLOWING, // '~'
    LXB_CSS_SELECTOR_COMBINATOR_CELL, // '||'
    LXB_CSS_SELECTOR_COMBINATOR__LAST_ENTRY,
};

pub const lxb_css_selector_match_t = enum(c_int) {
    LXB_CSS_SELECTOR_MATCH_EQUAL = 0x00, //  =
    LXB_CSS_SELECTOR_MATCH_INCLUDE, // ~=
    LXB_CSS_SELECTOR_MATCH_DASH, // |=
    LXB_CSS_SELECTOR_MATCH_PREFIX, // ^=
    LXB_CSS_SELECTOR_MATCH_SUFFIX, // $=
    LXB_CSS_SELECTOR_MATCH_SUBSTRING, // *=
    LXB_CSS_SELECTOR_MATCH__LAST_ENTRY,
};

pub const lxb_css_selector_modifier_t = enum(c_int) {
    LXB_CSS_SELECTOR_MODIFIER_UNSET = 0x00,
    LXB_CSS_SELECTOR_MODIFIER_I,
    LXB_CSS_SELECTOR_MODIFIER_S,
    LXB_CSS_SELECTOR_MODIFIER__LAST_ENTRY,
};

pub const lxb_css_selector_attribute_t = extern struct {
    match: lxb_css_selector_match_t,
    modifier: lxb_css_selector_modifier_t,
    value: core.lexbor_str_t,
};

pub const lxb_css_selector_pseudo_t = extern struct {
    type: c_uint,
    data: ?*anyopaque,
};

pub const lxb_css_selector = extern struct {
    type: lxb_css_selector_type_t,
    combinator: lxb_css_selector_combinator_t,
    name: core.lexbor_str_t,
    ns: core.lexbor_str_t,
    u: extern union {
        attribute: lxb_css_selector_attribute_t,
        pseudo: lxb_css_selector_pseudo_t,
    },
    next: ?*lxb_css_selector_t,
    prev: ?*lxb_css_selector_t,
    list: ?*lxb_css_selector_list_t,
};

pub const lxb_css_selector_list = extern struct {
    first: ?*lxb_css_selector_t,
    last: ?*lxb_css_selector_t,
    parent: ?*lxb_css_selector_t,
    next: ?*lxb_css_selector_list,
    prev: ?*lxb_css_selector_list,
    memory: ?*lxb_css_memory_t,
    specificity: ?*lxb_css_selector_specificity_t,
};

pub const lxb_css_selector_specificity_t = u32;

// css/parser.h

pub const LXB_CSS_SYNTAX_PARSER_ERROR_UNDEF = 0x0000;
// eof-in-at-rule
pub const LXB_CSS_SYNTAX_PARSER_ERROR_EOINATRU = 0x0001;
// eof-in-qualified-rule
pub const LXB_CSS_SYNTAX_PARSER_ERROR_EOINQURU = 0x0002;
// eof-in-simple-block
pub const LXB_CSS_SYNTAX_PARSER_ERROR_EOINSIBL = 0x0003;
// eof-in-function
pub const LXB_CSS_SYNTAX_PARSER_ERROR_EOINFU = 0x0004;
// eof-before-parse-rule
pub const LXB_CSS_SYNTAX_PARSER_ERROR_EOBEPARU = 0x0005;
// unexpected-token-after-parse-rule
pub const LXB_CSS_SYNTAX_PARSER_ERROR_UNTOAFPARU = 0x0006;
// eof-before-parse-component-value
pub const LXB_CSS_SYNTAX_PARSER_ERROR_EOBEPACOVA = 0x0007;
// unexpected-token-after-parse-component-value
pub const LXB_CSS_SYNTAX_PARSER_ERROR_UNTOAFPACOVA = 0x0008;
// unexpected-token-in-declaration
pub const LXB_CSS_SYNTAX_PARSER_ERROR_UNTOINDE = 0x0009;

pub const lxb_css_parser_stage_t = enum(c_int) {
    LXB_CSS_PARSER_CLEAN = 0,
    LXB_CSS_PARSER_RUN,
    LXB_CSS_PARSER_STOP,
    LXB_CSS_PARSER_END,
};

pub const lxb_css_parser = extern struct {
    block: lxb_css_parser_state_f,
    context: ?*anyopaque,
    tkz: ?*lxb_css_syntax_tokenizer_t,
    selectors: ?*lxb_css_selectors_t,
    old_selectors: ?*lxb_css_selectors_t,
    memory: ?*lxb_css_memory_t,
    old_memory: ?*lxb_css_memory_t,
    rules_begin: ?*lxb_css_syntax_rule_t,
    rules_end: ?*lxb_css_syntax_rule_t,
    rules: ?*lxb_css_syntax_rule_t,
};

pub const lxb_css_parser_state = extern struct {
    state: lxb_css_parser_state_f,
    context: ?*anyopaque,
    root: bool,
};

pub const lxb_css_parser_error = extern struct {
    message: core.lexbor_str_t,
};

// css/syntax/tokenizer.h

pub const lxb_css_syntax_tokenizer_state_f = ?*const fn (tkz: ?*lxb_css_syntax_tokenizer_t, token: ?*lxb_css_syntax_token_t, data: ?*const core.lxb_char_t, end: ?*const core.lxb_char_t) callconv(.C) ?*core.lxb_char_t;

pub const lxb_css_syntax_tokenizer_chunk_f = ?*const fn (tkz: ?*lxb_css_syntax_tokenizer_t, data: ?*const ?*core.lxb_char_t, end: ?*const ?*core.lxb_char_t, ctx: ?*anyopaque) callconv(.C) core.lxb_status_t;

pub const lxb_css_syntax_tokenizer_opt = enum(c_int) {
    LXB_CSS_SYNTAX_TOKENIZER_OPT_UNDEF = 0x00,
};

pub const lxb_css_syntax_tokenizer_cache_t = extern struct {
    list: ?*?*lxb_css_syntax_token_t,
    size: usize,
    length: usize,
};

pub const lxb_css_syntax_tokenizer = extern struct {
    cache: ?*lxb_css_syntax_tokenizer_cache_t,
    tokens: ?*core.lexbor_dobject_t,
    parse_errors: core.lexbor_array_obj_t,
    in_begin: ?*const core.lxb_char_t,
    in_end: ?*const core.lxb_char_t,
    begin: ?*const core.lxb_char_t,
    offset: usize,
    cache_pos: usize,
    prepared: usize,
    mraw: ?*core.lexbor_mraw_t,
    chunk_cb: lxb_css_syntax_tokenizer_chunk_f,
    chunk_ctx: ?*anyopaque,
    start: ?*core.lxb_char_t,
    pos: ?*core.lxb_char_t,
    end: ?*const core.lxb_char_t,
    buffer: [128]core.lxb_char_t,
    token_data: lxb_css_syntax_token_data_t,
    opt: c_uint,
    status: core.lxb_status_t,
    eof: bool,
    with_comment: bool,
};

// css/syntax/token.h

pub const lxb_css_syntax_token_data_t = lxb_css_syntax_token_data;

pub const lxb_css_syntax_token_data_cb_f = ?*const fn (begin: ?*const core.lxb_char_t, end: ?*const ?*core.lxb_char_t, str: ?*core.lexbor_str_t, mraw: ?*core.lexbor_mraw_t, td: ?*lxb_css_syntax_token_data_t) callconv(.C) ?*core.lxb_char_t;

pub const lxb_css_syntax_token_cb_f = ?*const fn (data: ?*const core.lxb_char_t, len: usize, ctx: ?*anyopaque) callconv(.C) core.lxb_status_t;

pub const lxb_css_syntax_token_data = extern struct {
    cb: lxb_css_syntax_token_data_cb_f,
    status: core.lxb_status_t,
    count: c_int,
    num: u32,
    is_last: bool,
};

pub const lxb_css_syntax_token_type_t = enum(c_int) {
    LXB_CSS_SYNTAX_TOKEN_UNDEF = 0x00,

    // String tokens.
    LXB_CSS_SYNTAX_TOKEN_IDENT,
    LXB_CSS_SYNTAX_TOKEN_FUNCTION,
    LXB_CSS_SYNTAX_TOKEN_AT_KEYWORD,
    LXB_CSS_SYNTAX_TOKEN_HASH,
    LXB_CSS_SYNTAX_TOKEN_STRING,
    LXB_CSS_SYNTAX_TOKEN_BAD_STRING,
    LXB_CSS_SYNTAX_TOKEN_URL,
    LXB_CSS_SYNTAX_TOKEN_BAD_URL,
    LXB_CSS_SYNTAX_TOKEN_COMMENT, // not in specification
    LXB_CSS_SYNTAX_TOKEN_WHITESPACE,

    // Has a string.
    LXB_CSS_SYNTAX_TOKEN_DIMENSION,

    // Other tokens.
    LXB_CSS_SYNTAX_TOKEN_DELIM,
    LXB_CSS_SYNTAX_TOKEN_NUMBER,
    LXB_CSS_SYNTAX_TOKEN_PERCENTAGE,
    LXB_CSS_SYNTAX_TOKEN_CDO,
    LXB_CSS_SYNTAX_TOKEN_CDC,
    LXB_CSS_SYNTAX_TOKEN_COLON,
    LXB_CSS_SYNTAX_TOKEN_SEMICOLON,
    LXB_CSS_SYNTAX_TOKEN_COMMA,
    LXB_CSS_SYNTAX_TOKEN_LS_BRACKET, // U+005B LEFT SQUARE BRACKET ([)
    LXB_CSS_SYNTAX_TOKEN_RS_BRACKET, // U+005D RIGHT SQUARE BRACKET (])
    LXB_CSS_SYNTAX_TOKEN_L_PARENTHESIS, // U+0028 LEFT PARENTHESIS (()
    LXB_CSS_SYNTAX_TOKEN_R_PARENTHESIS, // U+0029 RIGHT PARENTHESIS ())
    LXB_CSS_SYNTAX_TOKEN_LC_BRACKET, // U+007B LEFT CURLY BRACKET ({)
    LXB_CSS_SYNTAX_TOKEN_RC_BRACKET, // U+007D RIGHT CURLY BRACKET (})
    LXB_CSS_SYNTAX_TOKEN__EOF,
    LXB_CSS_SYNTAX_TOKEN__TERMINATED, // Deprecated, use LXB_CSS_SYNTAX_TOKEN__END.
    LXB_CSS_SYNTAX_TOKEN__END = 0x27, // manually counted...
    LXB_CSS_SYNTAX_TOKEN__LAST_ENTRY,
};

pub const lxb_css_syntax_token_base_t = extern struct {
    begin: ?*const core.lxb_char_t,
    length: usize,
    user_id: usize,
};

pub const lxb_css_syntax_token_number_t = extern struct {
    base: lxb_css_syntax_token_base_t,
    num: f64,
    is_float: bool,
    have_sign: bool,
};

pub const lxb_css_syntax_token_string_t = extern struct {
    base: lxb_css_syntax_token_base_t,
    data: ?*const core.lxb_char_t,
    length: usize,
};

pub const lxb_css_syntax_token_dimension_t = extern struct {
    num: lxb_css_syntax_token_number_t,
    str: lxb_css_syntax_token_string_t,
};

pub const lxb_css_syntax_token_delim_t = extern struct {
    base: lxb_css_syntax_token_base_t,
    character: ?*const core.lxb_char_t,
};

pub const lxb_css_syntax_token_ident_t = lxb_css_syntax_token_string_t;
pub const lxb_css_syntax_token_function_t = lxb_css_syntax_token_string_t;
pub const lxb_css_syntax_token_at_keyword_t = lxb_css_syntax_token_string_t;
pub const lxb_css_syntax_token_hash_t = lxb_css_syntax_token_string_t;
pub const lxb_css_syntax_token_bad_string_t = lxb_css_syntax_token_string_t;
pub const lxb_css_syntax_token_url_t = lxb_css_syntax_token_string_t;
pub const lxb_css_syntax_token_bad_url_t = lxb_css_syntax_token_string_t;
pub const lxb_css_syntax_token_percentage_t = lxb_css_syntax_token_number_t;
pub const lxb_css_syntax_token_whitespace_t = lxb_css_syntax_token_string_t;
pub const lxb_css_syntax_token_cdo_t = lxb_css_syntax_token_base_t;
pub const lxb_css_syntax_token_cdc_t = lxb_css_syntax_token_base_t;
pub const lxb_css_syntax_token_colon_t = lxb_css_syntax_token_base_t;
pub const lxb_css_syntax_token_semicolon_t = lxb_css_syntax_token_base_t;
pub const lxb_css_syntax_token_comma_t = lxb_css_syntax_token_base_t;
pub const lxb_css_syntax_token_ls_bracket_t = lxb_css_syntax_token_base_t;
pub const lxb_css_syntax_token_rs_bracket_t = lxb_css_syntax_token_base_t;
pub const lxb_css_syntax_token_l_parenthesis_t = lxb_css_syntax_token_base_t;
pub const lxb_css_syntax_token_r_parenthesis_t = lxb_css_syntax_token_base_t;
pub const lxb_css_syntax_token_lc_bracket_t = lxb_css_syntax_token_base_t;
pub const lxb_css_syntax_token_rc_bracket_t = lxb_css_syntax_token_base_t;
pub const lxb_css_syntax_token_comment_t = lxb_css_syntax_token_string_t;
pub const lxb_css_syntax_token_terminated_t = lxb_css_syntax_token_base_t;

pub const lxb_css_syntax_token = extern struct { types: extern union {
    base: lxb_css_syntax_token_base_t,
    comment: lxb_css_syntax_token_comment_t,
    number: lxb_css_syntax_token_number_t,
    dimension: lxb_css_syntax_token_dimension_t,
    percentage: lxb_css_syntax_token_percentage_t,
    hash: lxb_css_syntax_token_hash_t,
    string: lxb_css_syntax_token_string_t,
    bad_string: lxb_css_syntax_token_bad_string_t,
    delim: lxb_css_syntax_token_delim_t,
    lparenthesis: lxb_css_syntax_token_l_parenthesis_t,
    rparenthesis: lxb_css_syntax_token_r_parenthesis_t,
    cdc: lxb_css_syntax_token_cdc_t,
    function: lxb_css_syntax_token_function_t,
    ident: lxb_css_syntax_token_ident_t,
    url: lxb_css_syntax_token_url_t,
    bad_url: lxb_css_syntax_token_bad_url_t,
    at_keyword: lxb_css_syntax_token_at_keyword_t,
    whitespace: lxb_css_syntax_token_whitespace_t,
    terminated: lxb_css_syntax_token_terminated_t,
}, type: lxb_css_syntax_token_type_t, offset: usize, cloned: bool };

// css/syntax/syntax.h

pub const lxb_css_syntax_rule_t = lxb_css_syntax_rule;

pub const lxb_css_syntax_state_f = ?*const fn (parser: ?*lxb_css_parser_t, token: ?*const ?*lxb_css_syntax_token_t, rule: ?*lxb_css_syntax_rule) callconv(.C) ?*lxb_css_syntax_token_t;

pub const lxb_css_syntax_declaration_end_f = ?*const fn (parser: ?*lxb_css_parser_t, ctx: ?*anyopaque, important: bool, failed: bool) callconv(.C) ?*core.lxb_status_t;

pub const lxb_css_syntax_cb_done_f = ?*const fn (parser: ?*lxb_css_parser_t, token: ?*const lxb_css_syntax_token_t, ctx: ?*anyopaque, failed: bool) callconv(.C) ?*core.lxb_status_t;

pub const lxb_css_syntax_list_rules_offset_t = extern struct {
    begin: usize,
    end: usize,
};

pub const lxb_css_syntax_at_rules_offset_t = extern struct {
    name: usize,
    prelude: usize,
    prelude_end: usize,
    block: usize,
    block_end: usize,
};

pub const lxb_css_syntax_qualified_offset_t = extern struct {
    prelude: usize,
    prelude_end: usize,
    block: usize,
    block_end: usize,
};

pub const lxb_css_syntax_declarations_offset_t = extern struct {
    begin: usize,
    end: usize,
    name_begin: usize,
    name_end: usize,
    value_begin: usize,
    before_important: usize,
    value_end: usize,
};

pub const lxb_css_syntax_cb_base_t = extern struct {
    state: lxb_css_parser_state_f,
    block: lxb_css_parser_state_f,
    failed: lxb_css_parser_state_f,
    end: lxb_css_syntax_cb_done_f,
};

pub const lxb_css_syntax_cb_pipe_t = lxb_css_syntax_cb_base_t;
pub const lxb_css_syntax_cb_block_t = lxb_css_syntax_cb_base_t;
pub const lxb_css_syntax_cb_function_t = lxb_css_syntax_cb_base_t;
pub const lxb_css_syntax_cb_components_t = lxb_css_syntax_cb_base_t;
pub const lxb_css_syntax_cb_at_rule_t = lxb_css_syntax_cb_base_t;
pub const lxb_css_syntax_cb_qualified_rule_t = lxb_css_syntax_cb_base_t;

pub const lxb_css_syntax_cb_declarations_t = extern struct {
    cb: lxb_css_syntax_cb_base_t,
    declaration_end: lxb_css_syntax_declaration_end_f,
    at_rule: ?*const lxb_css_syntax_cb_at_rule_t,
};

pub const lxb_css_syntax_cb_list_rules_t = extern struct {
    cb: lxb_css_syntax_cb_base_t,
    next: lxb_css_parser_state_f,
    at_rule: ?*const lxb_css_syntax_cb_at_rule_t,
    qualified_rule: ?*const lxb_css_syntax_cb_qualified_rule_t,
};

pub const lxb_css_syntax_rule = extern struct {
    phase: lxb_css_syntax_state_f,
    state: lxb_css_parser_state_f,
    state_back: lxb_css_parser_state_f,
    back: lxb_css_parser_state_f,
    cbx: extern union {
        cb: ?*lxb_css_syntax_cb_base_t,
        list_rules: ?*lxb_css_syntax_cb_list_rules_t,
        at_rule: ?*lxb_css_syntax_cb_at_rule_t,
        qualified_rule: ?*lxb_css_syntax_cb_qualified_rule_t,
        declarations: ?*lxb_css_syntax_cb_declarations_t,
        components: ?*lxb_css_syntax_cb_components_t,
        func: ?*lxb_css_syntax_cb_function_t,
        block: ?*lxb_css_syntax_cb_block_t,
        pipe: ?*lxb_css_syntax_cb_pipe_t,
        user: ?*anyopaque,
    },
    context: ?*anyopaque,
    offset: usize,
    deep: usize,
    block_end: lxb_css_syntax_token_t,
    skip_ending: bool,
    skip_consume: bool,
    important: bool,
    failed: bool,
    top_level: bool,
    u: extern union {
        parser: ?*lxb_css_parser_t,
        cb: ?*const lxb_css_syntax_cb_list_rules_t,
        data: ?*const core.lxb_char_t,
        length: usize,
        ctx: ?*anyopaque,
        top_level: bool,
    },
};

// css/stylesheet.h

pub const lxb_css_stylesheet = extern struct {
    root: ?*lxb_css_rule_t,
    memory: ?*lxb_css_memory_t,
    element: ?*anyopaque,
};

// css/rule.h

pub const lxb_css_rule_type_t = enum(c_int) {
    LXB_CSS_RULE_UNDEF = 0,
    LXB_CSS_RULE_STYLESHEET,
    LXB_CSS_RULE_LIST,
    LXB_CSS_RULE_AT_RULE,
    LXB_CSS_RULE_STYLE,
    LXB_CSS_RULE_BAD_STYLE,
    LXB_CSS_RULE_DECLARATION_LIST,
    LXB_CSS_RULE_DECLARATION,
};

const lxb_css_rule_t = lxb_css_rule;

pub const lxb_css_rule = extern struct {
    type: lxb_css_rule_type_t,
    next: ?*lxb_css_rule_t,
    prev: ?*lxb_css_rule_t,
    parent: ?*lxb_css_rule_t,
    begin: ?*const core.lxb_char_t,
    end: ?*const core.lxb_char_t,
    memory: ?*lxb_css_memory_t,
    ref_count: usize,
};

pub const lxb_css_rule_list = extern struct {
    rule: lxb_css_rule_t,
    first: ?*lxb_css_rule_t,
    last: ?*lxb_css_rule_t,
};

pub const lxb_css_rule_at = extern struct {
    rule: lxb_css_rule_t,
    type: usize,
    u: extern union {
        undef: ?*lxb_css_at_rule__undef_t,
        custom: ?*lxb_css_at_rule__custom_t,
        media: ?*lxb_css_at_rule_media_t,
        ns: ?*lxb_css_at_rule_namespace_t,
        user: ?*anyopaque,
    },
};

pub const lxb_css_rule_style = extern struct {
    rule: lxb_css_rule_t,
    selector: ?*lxb_css_selector_list_t,
    declarations: ?*lxb_css_rule_declaration_list_t,
};

pub const lxb_css_rule_bad_style = extern struct {
    rule: lxb_css_rule_t,
    selector: core.lexbor_str_t,
    declarations: ?*lxb_css_rule_declaration_list_t,
};

pub const lxb_css_rule_declaration_list = extern struct {
    rule: lxb_css_rule_t,
    first: ?*lxb_css_rule_t,
    last: ?*lxb_css_rule_t,
    count: usize,
};

pub const lxb_css_rule_declaration = extern struct {
    rule: lxb_css_rule_t,
    type: usize,
    u: extern union { undef: ?*lxb_css_property__undef_t, custom: ?*lxb_css_property__custom_t, display: ?*lxb_css_property_display_t, order: ?*lxb_css_property_order_t, visibility: ?*lxb_css_property_visibility_t, width: ?*lxb_css_property_width_t, height: ?*lxb_css_property_height_t, box_sizing: ?*lxb_css_property_box_sizing_t, margin: ?*lxb_css_property_margin_t, margin_top: ?*lxb_css_property_margin_top_t, margin_right: ?*lxb_css_property_margin_right_t, margin_bottom: ?*lxb_css_property_margin_bottom_t, margin_left: ?*lxb_css_property_margin_left_t, padding: ?*lxb_css_property_padding_t, padding_top: ?*lxb_css_property_padding_top_t, padding_right: ?*lxb_css_property_padding_right_t, padding_bottom: ?*lxb_css_property_padding_bottom_t, padding_left: ?*lxb_css_property_padding_left_t, border: ?*lxb_css_property_border_t, border_top: ?*lxb_css_property_border_top_t, border_right: ?*lxb_css_property_border_right_t, border_bottom: ?*lxb_css_property_border_bottom_t, border_left: ?*lxb_css_property_border_left_t, border_top_color: ?*lxb_css_property_border_top_color_t, border_right_color: ?*lxb_css_property_border_right_color_t, border_bottom_color: ?*lxb_css_property_border_bottom_color_t, border_left_color: ?*lxb_css_property_border_left_color_t, background_color: ?*lxb_css_property_background_color_t, color: ?*lxb_css_property_color_t, opacity: ?*lxb_css_property_opacity_t, position: ?*lxb_css_property_position_t, top: ?*lxb_css_property_top_t, right: ?*lxb_css_property_right_t, bottom: ?*lxb_css_property_bottom_t, left: ?*lxb_css_property_left_t, inset_block_start: ?*lxb_css_property_inset_block_start_t, inset_inline_start: ?*lxb_css_property_inset_inline_start_t, inset_block_end: ?*lxb_css_property_inset_block_end_t, inset_inline_end: ?*lxb_css_property_inset_inline_end_t, text_transform: ?*lxb_css_property_text_transform_t, text_align: ?*lxb_css_property_text_align_t, text_align_all: ?*lxb_css_property_text_align_all_t, text_align_last: ?*lxb_css_property_text_align_last_t, text_justify: ?*lxb_css_property_text_justify_t, text_indent: ?*lxb_css_property_text_indent_t, white_space: ?*lxb_css_property_white_space_t, tab_size: ?*lxb_css_property_tab_size_t, word_break: ?*lxb_css_property_word_break_t, line_break: ?*lxb_css_property_line_break_t, hyphens: ?*lxb_css_property_hyphens_t, overflow_wrap: ?*lxb_css_property_overflow_wrap_t, word_wrap: ?*lxb_css_property_word_wrap_t, word_spacing: ?*lxb_css_property_word_spacing_t, letter_spacing: ?*lxb_css_property_letter_spacing_t, hanging_punctuation: ?*lxb_css_property_hanging_punctuation_t, font_family: ?*lxb_css_property_font_family_t, font_weight: ?*lxb_css_property_font_weight_t, font_stretch: ?*lxb_css_property_font_stretch_t, font_style: ?*lxb_css_property_font_style_t, font_size: ?*lxb_css_property_font_size_t, float_reference: ?*lxb_css_property_float_reference_t, floatp: ?*lxb_css_property_float_t, clear: ?*lxb_css_property_clear_t, float_defer: ?*lxb_css_property_float_defer_t, float_offset: ?*lxb_css_property_float_offset_t, wrap_flow: ?*lxb_css_property_wrap_flow_t, wrap_through: ?*lxb_css_property_wrap_through_t, flex_direction: ?*lxb_css_property_flex_direction_t, flex_wrap: ?*lxb_css_property_flex_wrap_t, flex_flow: ?*lxb_css_property_flex_flow_t, flex: ?*lxb_css_property_flex_t, flex_grow: ?*lxb_css_property_flex_grow_t, flex_shrink: ?*lxb_css_property_flex_shrink_t, flex_basis: ?*lxb_css_property_flex_basis_t, justify_content: ?*lxb_css_property_justify_content_t, align_items: ?*lxb_css_property_align_items_t, align_self: ?*lxb_css_property_align_self_t, align_content: ?*lxb_css_property_align_content_t, dominant_baseline: ?*lxb_css_property_dominant_baseline_t, vertical_align: ?*lxb_css_property_vertical_align_t, baseline_source: ?*lxb_css_property_baseline_source_t, alignment_baseline: ?*lxb_css_property_alignment_baseline_t, baseline_shift: ?*lxb_css_property_baseline_shift_t, line_height: ?*lxb_css_property_line_height_t, z_index: ?*lxb_css_property_z_index_t, direction: ?*lxb_css_property_direction_t, unicode_bidi: ?*lxb_css_property_unicode_bidi_t, writing_mode: ?*lxb_css_property_writing_mode_t, text_orientation: ?*lxb_css_property_text_orientation_t, text_combine_upright: ?*lxb_css_property_text_combine_upright_t, overflow_x: ?*lxb_css_property_overflow_x_t, overflow_y: ?*lxb_css_property_overflow_y_t, overflow_block: ?*lxb_css_property_overflow_block_t, overflow_inline: ?*lxb_css_property_overflow_inline_t, text_overflow: ?*lxb_css_property_text_overflow_t, text_decoration_line: ?*lxb_css_property_text_decoration_line_t, text_decoration_style: ?*lxb_css_property_text_decoration_style_t, text_decoration_color: ?*lxb_css_property_text_decoration_color_t, text_decoration: ?*lxb_css_property_text_decoration_t, user: ?*anyopaque },
    important: bool,
};

// css/at_rule.h

pub const lxb_css_at_rule__undef_t = extern struct {
    type: lxb_css_at_rule_type_t,
    prelude: core.lexbor_str_t,
    block: core.lexbor_str_t,
};

pub const lxb_css_at_rule__custom_t = extern struct {
    name: core.lexbor_str_t,
    prelude: core.lexbor_str_t,
    block: core.lexbor_str_t,
};

pub const lxb_css_at_rule_media_t = extern struct {
    reserved: usize,
};

pub const lxb_css_at_rule_namespace_t = extern struct {
    reserved: usize,
};

// css/at_rule/const.h

pub const LXB_CSS_AT_RULE__UNDEF = 0x0000;
pub const LXB_CSS_AT_RULE__CUSTOM = 0x0001;
pub const LXB_CSS_AT_RULE_MEDIA = 0x0002;
pub const LXB_CSS_AT_RULE_NAMESPACE = 0x0003;
pub const LXB_CSS_AT_RULE__LAST_ENTRY = 0x0004;

pub const lxb_css_at_rule_type_t = usize;

// css/property.h

pub const lxb_css_property__undef_t = extern struct {
    type: lxb_css_property_type_t,
    value: core.lexbor_str_t,
};

pub const lxb_css_property__custom_t = extern struct {
    name: core.lexbor_str_t,
    value: core.lexbor_str_t,
};
pub const lxb_css_property_display_t = extern struct {
    a: lxb_css_display_type_t,
    b: lxb_css_display_type_t,
    c: lxb_css_display_type_t,
};

pub const lxb_css_property_order_t = lxb_css_value_integer_type_t;

pub const lxb_css_property_visibility_t = extern struct {
    type: lxb_css_visibility_type_t,
};

pub const lxb_css_property_width_t = lxb_css_value_length_percentage_t;
pub const lxb_css_property_height_t = lxb_css_value_length_percentage_t;
pub const lxb_css_property_min_width_t = lxb_css_value_length_percentage_t;
pub const lxb_css_property_min_height_t = lxb_css_value_length_percentage_t;
pub const lxb_css_property_max_width_t = lxb_css_value_length_percentage_t;
pub const lxb_css_property_max_height_t = lxb_css_value_length_percentage_t;
pub const lxb_css_property_margin_top_t = lxb_css_value_length_percentage_t;
pub const lxb_css_property_margin_right_t = lxb_css_value_length_percentage_t;
pub const lxb_css_property_margin_bottom_t = lxb_css_value_length_percentage_t;
pub const lxb_css_property_margin_left_t = lxb_css_value_length_percentage_t;
pub const lxb_css_property_padding_top_t = lxb_css_value_length_percentage_t;
pub const lxb_css_property_padding_right_t = lxb_css_value_length_percentage_t;
pub const lxb_css_property_padding_bottom_t = lxb_css_value_length_percentage_t;
pub const lxb_css_property_padding_left_t = lxb_css_value_length_percentage_t;

pub const lxb_css_property_box_sizing_t = extern struct {
    type: lxb_css_box_sizing_type_t,
};

pub const lxb_css_property_margin_t = extern struct {
    top: lxb_css_property_margin_top_t,
    right: lxb_css_property_margin_right_t,
    bottom: lxb_css_property_margin_bottom_t,
    left: lxb_css_property_margin_left_t,
};

pub const lxb_css_property_padding_t = extern struct {
    top: lxb_css_property_padding_top_t,
    right: lxb_css_property_padding_right_t,
    bottom: lxb_css_property_padding_bottom_t,
    left: lxb_css_property_padding_left_t,
};

pub const lxb_css_property_border_t = extern struct {
    style: lxb_css_value_type_t,
    width: lxb_css_value_length_type_t,
    color: lxb_css_value_color_t,
};

pub const lxb_css_property_border_top_t = lxb_css_property_border_t;
pub const lxb_css_property_border_right_t = lxb_css_property_border_t;
pub const lxb_css_property_border_bottom_t = lxb_css_property_border_t;
pub const lxb_css_property_border_left_t = lxb_css_property_border_t;

pub const lxb_css_property_border_top_color_t = lxb_css_value_color_t;
pub const lxb_css_property_border_right_color_t = lxb_css_value_color_t;
pub const lxb_css_property_border_bottom_color_t = lxb_css_value_color_t;
pub const lxb_css_property_border_left_color_t = lxb_css_value_color_t;

pub const lxb_css_property_background_color_t = lxb_css_value_color_t;

pub const lxb_css_property_color_t = lxb_css_value_color_t;
pub const lxb_css_property_opacity_t = lxb_css_value_number_percentage_t;

pub const lxb_css_property_position_t = extern struct {
    type: lxb_css_position_type_t,
};

pub const lxb_css_property_top_t = lxb_css_value_length_percentage_t;
pub const lxb_css_property_right_t = lxb_css_value_length_percentage_t;
pub const lxb_css_property_bottom_t = lxb_css_value_length_percentage_t;
pub const lxb_css_property_left_t = lxb_css_value_length_percentage_t;

pub const lxb_css_property_inset_block_start_t = lxb_css_value_length_percentage_t;
pub const lxb_css_property_inset_inline_start_t = lxb_css_value_length_percentage_t;
pub const lxb_css_property_inset_block_end_t = lxb_css_value_length_percentage_t;
pub const lxb_css_property_inset_inline_end_t = lxb_css_value_length_percentage_t;

pub const lxb_css_property_text_transform_t = extern struct {
    type_case: lxb_css_text_transform_type_t,
    full_width: lxb_css_text_transform_type_t,
    full_size_kana: lxb_css_text_transform_type_t,
};

pub const lxb_css_property_text_align_t = extern struct {
    type: lxb_css_text_align_type_t,
};

pub const lxb_css_property_text_align_all_t = extern struct {
    type: lxb_css_text_align_all_type_t,
};

pub const lxb_css_property_text_align_last_t = extern struct {
    type: lxb_css_text_align_last_type_t,
};

pub const lxb_css_property_text_justify_t = extern struct {
    type: lxb_css_text_justify_type_t,
};

pub const lxb_css_property_text_indent_t = extern struct {
    length: lxb_css_value_length_percentage_t,
    type: lxb_css_text_indent_type_t,
    hanging: lxb_css_text_indent_type_t,
    each_line: lxb_css_text_indent_type_t,
};

pub const lxb_css_property_white_space_t = extern struct {
    type: lxb_css_white_space_type_t,
};

pub const lxb_css_property_tab_size_t = lxb_css_value_number_length_t;

pub const lxb_css_property_word_break_t = extern struct {
    type: lxb_css_word_break_type_t,
};

pub const lxb_css_property_line_break_t = extern struct {
    type: lxb_css_line_break_type_t,
};

pub const lxb_css_property_hyphens_t = extern struct {
    type: lxb_css_hyphens_type_t,
};

pub const lxb_css_property_overflow_wrap_t = extern struct {
    type: lxb_css_overflow_wrap_type_t,
};

pub const lxb_css_property_word_wrap_t = extern struct {
    type: lxb_css_word_wrap_type_t,
};

pub const lxb_css_property_word_spacing_t = lxb_css_value_length_type_t;
pub const lxb_css_property_letter_spacing_t = lxb_css_value_length_type_t;

pub const lxb_css_property_hanging_punctuation_t = extern struct {
    type_first: lxb_css_hanging_punctuation_type_t,
    force_allow: lxb_css_hanging_punctuation_type_t,
    last: lxb_css_hanging_punctuation_type_t,
};

pub const lxb_css_property_family_name_t = lxb_css_property_family_name;

pub const lxb_css_property_family_name = extern struct {
    generic: bool,
    u: extern union {
        type: lxb_css_font_family_type_t,
        str: core.lexbor_str_t,
    },
    next: ?*lxb_css_property_family_name_t,
    prev: ?*lxb_css_property_family_name_t,
};

pub const lxb_css_property_font_family_t = extern struct {
    first: ?*lxb_css_property_family_name_t,
    last: ?*lxb_css_property_family_name_t,
    count: usize,
};

pub const lxb_css_property_font_weight_t = lxb_css_value_number_type_t;
pub const lxb_css_property_font_stretch_t = lxb_css_value_percentage_type_t;
pub const lxb_css_property_font_style_t = lxb_css_value_angle_type_t;
pub const lxb_css_property_font_size_t = lxb_css_value_length_percentage_type_t;

pub const lxb_css_property_float_reference_t = extern struct {
    type: lxb_css_float_reference_type_t,
};

pub const lxb_css_property_float_t = extern struct {
    type: lxb_css_float_type_t,
    length: lxb_css_value_length_type_t,
    snap_type: lxb_css_float_type_t,
};

pub const lxb_css_property_clear_t = extern struct {
    type: lxb_css_clear_type_t,
};

pub const lxb_css_property_float_offset_t = lxb_css_value_length_percentage_t;
pub const lxb_css_property_float_defer_t = lxb_css_value_integer_type_t;

pub const lxb_css_property_wrap_flow_t = extern struct {
    type: lxb_css_wrap_flow_type_t,
};

pub const lxb_css_property_wrap_through_t = extern struct {
    type: lxb_css_wrap_through_type_t,
};

pub const lxb_css_property_flex_direction_t = extern struct {
    type: lxb_css_flex_direction_type_t,
};

pub const lxb_css_property_flex_wrap_t = extern struct {
    type: lxb_css_flex_wrap_type_t,
};

pub const lxb_css_property_flex_flow_t = extern struct {
    type_direction: lxb_css_flex_direction_type_t,
    wrap: lxb_css_flex_wrap_type_t,
};

pub const lxb_css_property_flex_grow_t = lxb_css_value_number_type_t;
pub const lxb_css_property_flex_shrink_t = lxb_css_value_number_type_t;
pub const lxb_css_property_flex_basis_t = lxb_css_property_width_t;

pub const lxb_css_property_flex_t = extern struct {
    type: lxb_css_flex_type_t,
    grow: lxb_css_property_flex_grow_t,
    shrink: lxb_css_property_flex_shrink_t,
    basis: lxb_css_property_flex_basis_t,
};

pub const lxb_css_property_justify_content_t = extern struct {
    type: lxb_css_justify_content_type_t,
};

pub const lxb_css_property_align_items_t = extern struct {
    type: lxb_css_align_items_type_t,
};

pub const lxb_css_property_align_self_t = extern struct { type: lxb_css_align_self_type_t };

pub const lxb_css_property_align_content_t = extern struct {
    type: lxb_css_align_content_type_t,
};

pub const lxb_css_property_dominant_baseline_t = extern struct {
    type: lxb_css_dominant_baseline_type_t,
};

pub const lxb_css_property_baseline_source_t = extern struct {
    type: lxb_css_baseline_source_type_t,
};

pub const lxb_css_property_alignment_baseline_t = extern struct {
    type: lxb_css_alignment_baseline_type_t,
};

pub const lxb_css_property_baseline_shift_t = lxb_css_value_length_percentage_t;

pub const lxb_css_property_vertical_align_t = extern struct {
    type: lxb_css_vertical_align_type_t,
    alignment: lxb_css_property_alignment_baseline_t,
    shift: lxb_css_property_baseline_shift_t,
};

pub const lxb_css_property_line_height_t = lxb_css_value_number_length_percentage_t;

pub const lxb_css_property_z_index_t = lxb_css_value_integer_type_t;

pub const lxb_css_property_direction_t = extern struct {
    type: lxb_css_direction_type_t,
};

pub const lxb_css_property_unicode_bidi_t = extern struct {
    type: lxb_css_unicode_bidi_type_t,
};

pub const lxb_css_property_writing_mode_t = extern struct {
    type: lxb_css_writing_mode_type_t,
};

pub const lxb_css_property_text_orientation_t = extern struct {
    type: lxb_css_text_orientation_type_t,
};

pub const lxb_css_property_text_combine_upright_t = extern struct {
    type: lxb_css_text_combine_upright_type_t,
    // If the integer is omitted, it computes to 2.
    // Integers outside the range 2-4 are invalid.
    digits: lxb_css_value_integer_t,
};

pub const lxb_css_property_overflow_x_t = extern struct {
    type: lxb_css_overflow_x_type_t,
};

pub const lxb_css_property_overflow_y_t = extern struct {
    type: lxb_css_overflow_y_type_t,
};

pub const lxb_css_property_overflow_block_t = extern struct {
    type: lxb_css_overflow_block_type_t,
};

pub const lxb_css_property_overflow_inline_t = extern struct {
    type: lxb_css_overflow_inline_type_t,
};

pub const lxb_css_property_text_overflow_t = extern struct {
    type: lxb_css_text_overflow_type_t,
};

pub const lxb_css_property_text_decoration_line_t = extern struct {
    type: lxb_css_text_decoration_line_type_t,
    underline: lxb_css_text_decoration_line_type_t,
    overline: lxb_css_text_decoration_line_type_t,
    line_through: lxb_css_text_decoration_line_type_t,
    blink: lxb_css_text_decoration_line_type_t,
};

pub const lxb_css_property_text_decoration_style_t = extern struct {
    type: lxb_css_text_decoration_style_type_t,
};

pub const lxb_css_property_text_decoration_color_t = lxb_css_value_color_t;

pub const lxb_css_property_text_decoration_t = extern struct {
    line: lxb_css_property_text_decoration_line_t,
    style: lxb_css_property_text_decoration_style_t,
    color: lxb_css_property_text_decoration_color_t,
};

// css/property/const.h

pub const LXB_CSS_PROPERTY__UNDEF = 0x0000;
pub const LXB_CSS_PROPERTY__CUSTOM = 0x0001;
pub const LXB_CSS_PROPERTY_ALIGN_CONTENT = 0x0002;
pub const LXB_CSS_PROPERTY_ALIGN_ITEMS = 0x0003;
pub const LXB_CSS_PROPERTY_ALIGN_SELF = 0x0004;
pub const LXB_CSS_PROPERTY_ALIGNMENT_BASELINE = 0x0005;
pub const LXB_CSS_PROPERTY_BACKGROUND_COLOR = 0x0006;
pub const LXB_CSS_PROPERTY_BASELINE_SHIFT = 0x0007;
pub const LXB_CSS_PROPERTY_BASELINE_SOURCE = 0x0008;
pub const LXB_CSS_PROPERTY_BORDER = 0x0009;
pub const LXB_CSS_PROPERTY_BORDER_BOTTOM = 0x000a;
pub const LXB_CSS_PROPERTY_BORDER_BOTTOM_COLOR = 0x000b;
pub const LXB_CSS_PROPERTY_BORDER_LEFT = 0x000c;
pub const LXB_CSS_PROPERTY_BORDER_LEFT_COLOR = 0x000d;
pub const LXB_CSS_PROPERTY_BORDER_RIGHT = 0x000e;
pub const LXB_CSS_PROPERTY_BORDER_RIGHT_COLOR = 0x000f;
pub const LXB_CSS_PROPERTY_BORDER_TOP = 0x0010;
pub const LXB_CSS_PROPERTY_BORDER_TOP_COLOR = 0x0011;
pub const LXB_CSS_PROPERTY_BOTTOM = 0x0012;
pub const LXB_CSS_PROPERTY_BOX_SIZING = 0x0013;
pub const LXB_CSS_PROPERTY_CLEAR = 0x0014;
pub const LXB_CSS_PROPERTY_COLOR = 0x0015;
pub const LXB_CSS_PROPERTY_DIRECTION = 0x0016;
pub const LXB_CSS_PROPERTY_DISPLAY = 0x0017;
pub const LXB_CSS_PROPERTY_DOMINANT_BASELINE = 0x0018;
pub const LXB_CSS_PROPERTY_FLEX = 0x0019;
pub const LXB_CSS_PROPERTY_FLEX_BASIS = 0x001a;
pub const LXB_CSS_PROPERTY_FLEX_DIRECTION = 0x001b;
pub const LXB_CSS_PROPERTY_FLEX_FLOW = 0x001c;
pub const LXB_CSS_PROPERTY_FLEX_GROW = 0x001d;
pub const LXB_CSS_PROPERTY_FLEX_SHRINK = 0x001e;
pub const LXB_CSS_PROPERTY_FLEX_WRAP = 0x001f;
pub const LXB_CSS_PROPERTY_FLOAT = 0x0020;
pub const LXB_CSS_PROPERTY_FLOAT_DEFER = 0x0021;
pub const LXB_CSS_PROPERTY_FLOAT_OFFSET = 0x0022;
pub const LXB_CSS_PROPERTY_FLOAT_REFERENCE = 0x0023;
pub const LXB_CSS_PROPERTY_FONT_FAMILY = 0x0024;
pub const LXB_CSS_PROPERTY_FONT_SIZE = 0x0025;
pub const LXB_CSS_PROPERTY_FONT_STRETCH = 0x0026;
pub const LXB_CSS_PROPERTY_FONT_STYLE = 0x0027;
pub const LXB_CSS_PROPERTY_FONT_WEIGHT = 0x0028;
pub const LXB_CSS_PROPERTY_HANGING_PUNCTUATION = 0x0029;
pub const LXB_CSS_PROPERTY_HEIGHT = 0x002a;
pub const LXB_CSS_PROPERTY_HYPHENS = 0x002b;
pub const LXB_CSS_PROPERTY_INSET_BLOCK_END = 0x002c;
pub const LXB_CSS_PROPERTY_INSET_BLOCK_START = 0x002d;
pub const LXB_CSS_PROPERTY_INSET_INLINE_END = 0x002e;
pub const LXB_CSS_PROPERTY_INSET_INLINE_START = 0x002f;
pub const LXB_CSS_PROPERTY_JUSTIFY_CONTENT = 0x0030;
pub const LXB_CSS_PROPERTY_LEFT = 0x0031;
pub const LXB_CSS_PROPERTY_LETTER_SPACING = 0x0032;
pub const LXB_CSS_PROPERTY_LINE_BREAK = 0x0033;
pub const LXB_CSS_PROPERTY_LINE_HEIGHT = 0x0034;
pub const LXB_CSS_PROPERTY_MARGIN = 0x0035;
pub const LXB_CSS_PROPERTY_MARGIN_BOTTOM = 0x0036;
pub const LXB_CSS_PROPERTY_MARGIN_LEFT = 0x0037;
pub const LXB_CSS_PROPERTY_MARGIN_RIGHT = 0x0038;
pub const LXB_CSS_PROPERTY_MARGIN_TOP = 0x0039;
pub const LXB_CSS_PROPERTY_MAX_HEIGHT = 0x003a;
pub const LXB_CSS_PROPERTY_MAX_WIDTH = 0x003b;
pub const LXB_CSS_PROPERTY_MIN_HEIGHT = 0x003c;
pub const LXB_CSS_PROPERTY_MIN_WIDTH = 0x003d;
pub const LXB_CSS_PROPERTY_OPACITY = 0x003e;
pub const LXB_CSS_PROPERTY_ORDER = 0x003f;
pub const LXB_CSS_PROPERTY_OVERFLOW_BLOCK = 0x0040;
pub const LXB_CSS_PROPERTY_OVERFLOW_INLINE = 0x0041;
pub const LXB_CSS_PROPERTY_OVERFLOW_WRAP = 0x0042;
pub const LXB_CSS_PROPERTY_OVERFLOW_X = 0x0043;
pub const LXB_CSS_PROPERTY_OVERFLOW_Y = 0x0044;
pub const LXB_CSS_PROPERTY_PADDING = 0x0045;
pub const LXB_CSS_PROPERTY_PADDING_BOTTOM = 0x0046;
pub const LXB_CSS_PROPERTY_PADDING_LEFT = 0x0047;
pub const LXB_CSS_PROPERTY_PADDING_RIGHT = 0x0048;
pub const LXB_CSS_PROPERTY_PADDING_TOP = 0x0049;
pub const LXB_CSS_PROPERTY_POSITION = 0x004a;
pub const LXB_CSS_PROPERTY_RIGHT = 0x004b;
pub const LXB_CSS_PROPERTY_TAB_SIZE = 0x004c;
pub const LXB_CSS_PROPERTY_TEXT_ALIGN = 0x004d;
pub const LXB_CSS_PROPERTY_TEXT_ALIGN_ALL = 0x004e;
pub const LXB_CSS_PROPERTY_TEXT_ALIGN_LAST = 0x004f;
pub const LXB_CSS_PROPERTY_TEXT_COMBINE_UPRIGHT = 0x0050;
pub const LXB_CSS_PROPERTY_TEXT_DECORATION = 0x0051;
pub const LXB_CSS_PROPERTY_TEXT_DECORATION_COLOR = 0x0052;
pub const LXB_CSS_PROPERTY_TEXT_DECORATION_LINE = 0x0053;
pub const LXB_CSS_PROPERTY_TEXT_DECORATION_STYLE = 0x0054;
pub const LXB_CSS_PROPERTY_TEXT_INDENT = 0x0055;
pub const LXB_CSS_PROPERTY_TEXT_JUSTIFY = 0x0056;
pub const LXB_CSS_PROPERTY_TEXT_ORIENTATION = 0x0057;
pub const LXB_CSS_PROPERTY_TEXT_OVERFLOW = 0x0058;
pub const LXB_CSS_PROPERTY_TEXT_TRANSFORM = 0x0059;
pub const LXB_CSS_PROPERTY_TOP = 0x005a;
pub const LXB_CSS_PROPERTY_UNICODE_BIDI = 0x005b;
pub const LXB_CSS_PROPERTY_VERTICAL_ALIGN = 0x005c;
pub const LXB_CSS_PROPERTY_VISIBILITY = 0x005d;
pub const LXB_CSS_PROPERTY_WHITE_SPACE = 0x005e;
pub const LXB_CSS_PROPERTY_WIDTH = 0x005f;
pub const LXB_CSS_PROPERTY_WORD_BREAK = 0x0060;
pub const LXB_CSS_PROPERTY_WORD_SPACING = 0x0061;
pub const LXB_CSS_PROPERTY_WORD_WRAP = 0x0062;
pub const LXB_CSS_PROPERTY_WRAP_FLOW = 0x0063;
pub const LXB_CSS_PROPERTY_WRAP_THROUGH = 0x0064;
pub const LXB_CSS_PROPERTY_WRITING_MODE = 0x0065;
pub const LXB_CSS_PROPERTY_Z_INDEX = 0x0066;
pub const LXB_CSS_PROPERTY__LAST_ENTRY = 0x0067;

pub const lxb_css_property_type_t = usize;

pub const LXB_CSS_ALIGN_CONTENT_FLEX_START = LXB_CSS_VALUE_FLEX_START;
pub const LXB_CSS_ALIGN_CONTENT_FLEX_END = LXB_CSS_VALUE_FLEX_END;
pub const LXB_CSS_ALIGN_CONTENT_CENTER = LXB_CSS_VALUE_CENTER;
pub const LXB_CSS_ALIGN_CONTENT_SPACE_BETWEEN = LXB_CSS_VALUE_SPACE_BETWEEN;
pub const LXB_CSS_ALIGN_CONTENT_SPACE_AROUND = LXB_CSS_VALUE_SPACE_AROUND;
pub const LXB_CSS_ALIGN_CONTENT_STRETCH = LXB_CSS_VALUE_STRETCH;

pub const lxb_css_align_content_type_t = c_uint;

pub const LXB_CSS_ALIGN_ITEMS_FLEX_START = LXB_CSS_VALUE_FLEX_START;
pub const LXB_CSS_ALIGN_ITEMS_FLEX_END = LXB_CSS_VALUE_FLEX_END;
pub const LXB_CSS_ALIGN_ITEMS_CENTER = LXB_CSS_VALUE_CENTER;
pub const LXB_CSS_ALIGN_ITEMS_BASELINE = LXB_CSS_VALUE_BASELINE;
pub const LXB_CSS_ALIGN_ITEMS_STRETCH = LXB_CSS_VALUE_STRETCH;

pub const lxb_css_align_items_type_t = c_uint;

pub const LXB_CSS_ALIGN_SELF_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_ALIGN_SELF_FLEX_START = LXB_CSS_VALUE_FLEX_START;
pub const LXB_CSS_ALIGN_SELF_FLEX_END = LXB_CSS_VALUE_FLEX_END;
pub const LXB_CSS_ALIGN_SELF_CENTER = LXB_CSS_VALUE_CENTER;
pub const LXB_CSS_ALIGN_SELF_BASELINE = LXB_CSS_VALUE_BASELINE;
pub const LXB_CSS_ALIGN_SELF_STRETCH = LXB_CSS_VALUE_STRETCH;

pub const lxb_css_align_self_type_t = c_uint;

pub const LXB_CSS_ALIGNMENT_BASELINE_BASELINE = LXB_CSS_VALUE_BASELINE;
pub const LXB_CSS_ALIGNMENT_BASELINE_TEXT_BOTTOM = LXB_CSS_VALUE_TEXT_BOTTOM;
pub const LXB_CSS_ALIGNMENT_BASELINE_ALPHABETIC = LXB_CSS_VALUE_ALPHABETIC;
pub const LXB_CSS_ALIGNMENT_BASELINE_IDEOGRAPHIC = LXB_CSS_VALUE_IDEOGRAPHIC;
pub const LXB_CSS_ALIGNMENT_BASELINE_MIDDLE = LXB_CSS_VALUE_MIDDLE;
pub const LXB_CSS_ALIGNMENT_BASELINE_CENTRAL = LXB_CSS_VALUE_CENTRAL;
pub const LXB_CSS_ALIGNMENT_BASELINE_MATHEMATICAL = LXB_CSS_VALUE_MATHEMATICAL;
pub const LXB_CSS_ALIGNMENT_BASELINE_TEXT_TOP = LXB_CSS_VALUE_TEXT_TOP;

pub const lxb_css_alignment_baseline_type_t = c_uint;

pub const LXB_CSS_BASELINE_SHIFT__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_BASELINE_SHIFT__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;
pub const LXB_CSS_BASELINE_SHIFT_SUB = LXB_CSS_VALUE_SUB;
pub const LXB_CSS_BASELINE_SHIFT_SUPER = LXB_CSS_VALUE_SUPER;
pub const LXB_CSS_BASELINE_SHIFT_TOP = LXB_CSS_VALUE_TOP;
pub const LXB_CSS_BASELINE_SHIFT_CENTER = LXB_CSS_VALUE_CENTER;
pub const LXB_CSS_BASELINE_SHIFT_BOTTOM = LXB_CSS_VALUE_BOTTOM;

pub const lxb_css_baseline_shift_type_t = c_uint;

pub const LXB_CSS_BASELINE_SOURCE_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_BASELINE_SOURCE_FIRST = LXB_CSS_VALUE_FIRST;
pub const LXB_CSS_BASELINE_SOURCE_LAST = LXB_CSS_VALUE_LAST;

pub const lxb_css_baseline_source_type_t = c_uint;

pub const LXB_CSS_BORDER_THIN = LXB_CSS_VALUE_THIN;
pub const LXB_CSS_BORDER_MEDIUM = LXB_CSS_VALUE_MEDIUM;
pub const LXB_CSS_BORDER_THICK = LXB_CSS_VALUE_THICK;
pub const LXB_CSS_BORDER_NONE = LXB_CSS_VALUE_NONE;
pub const LXB_CSS_BORDER_HIDDEN = LXB_CSS_VALUE_HIDDEN;
pub const LXB_CSS_BORDER_DOTTED = LXB_CSS_VALUE_DOTTED;
pub const LXB_CSS_BORDER_DASHED = LXB_CSS_VALUE_DASHED;
pub const LXB_CSS_BORDER_SOLID = LXB_CSS_VALUE_SOLID;
pub const LXB_CSS_BORDER_DOUBLE = LXB_CSS_VALUE_DOUBLE;
pub const LXB_CSS_BORDER_GROOVE = LXB_CSS_VALUE_GROOVE;
pub const LXB_CSS_BORDER_RIDGE = LXB_CSS_VALUE_RIDGE;
pub const LXB_CSS_BORDER_INSET = LXB_CSS_VALUE_INSET;
pub const LXB_CSS_BORDER_OUTSET = LXB_CSS_VALUE_OUTSET;
pub const LXB_CSS_BORDER__LENGTH = LXB_CSS_VALUE__LENGTH;

pub const lxb_css_border_type_t = c_uint;

pub const LXB_CSS_BORDER_BOTTOM_THIN = LXB_CSS_VALUE_THIN;
pub const LXB_CSS_BORDER_BOTTOM_MEDIUM = LXB_CSS_VALUE_MEDIUM;
pub const LXB_CSS_BORDER_BOTTOM_THICK = LXB_CSS_VALUE_THICK;
pub const LXB_CSS_BORDER_BOTTOM_NONE = LXB_CSS_VALUE_NONE;
pub const LXB_CSS_BORDER_BOTTOM_HIDDEN = LXB_CSS_VALUE_HIDDEN;
pub const LXB_CSS_BORDER_BOTTOM_DOTTED = LXB_CSS_VALUE_DOTTED;
pub const LXB_CSS_BORDER_BOTTOM_DASHED = LXB_CSS_VALUE_DASHED;
pub const LXB_CSS_BORDER_BOTTOM_SOLID = LXB_CSS_VALUE_SOLID;
pub const LXB_CSS_BORDER_BOTTOM_DOUBLE = LXB_CSS_VALUE_DOUBLE;
pub const LXB_CSS_BORDER_BOTTOM_GROOVE = LXB_CSS_VALUE_GROOVE;
pub const LXB_CSS_BORDER_BOTTOM_RIDGE = LXB_CSS_VALUE_RIDGE;
pub const LXB_CSS_BORDER_BOTTOM_INSET = LXB_CSS_VALUE_INSET;
pub const LXB_CSS_BORDER_BOTTOM_OUTSET = LXB_CSS_VALUE_OUTSET;
pub const LXB_CSS_BORDER_BOTTOM__LENGTH = LXB_CSS_VALUE__LENGTH;

pub const lxb_css_border_bottom_type_t = c_uint;

pub const LXB_CSS_BORDER_LEFT_THIN = LXB_CSS_VALUE_THIN;
pub const LXB_CSS_BORDER_LEFT_MEDIUM = LXB_CSS_VALUE_MEDIUM;
pub const LXB_CSS_BORDER_LEFT_THICK = LXB_CSS_VALUE_THICK;
pub const LXB_CSS_BORDER_LEFT_NONE = LXB_CSS_VALUE_NONE;
pub const LXB_CSS_BORDER_LEFT_HIDDEN = LXB_CSS_VALUE_HIDDEN;
pub const LXB_CSS_BORDER_LEFT_DOTTED = LXB_CSS_VALUE_DOTTED;
pub const LXB_CSS_BORDER_LEFT_DASHED = LXB_CSS_VALUE_DASHED;
pub const LXB_CSS_BORDER_LEFT_SOLID = LXB_CSS_VALUE_SOLID;
pub const LXB_CSS_BORDER_LEFT_DOUBLE = LXB_CSS_VALUE_DOUBLE;
pub const LXB_CSS_BORDER_LEFT_GROOVE = LXB_CSS_VALUE_GROOVE;
pub const LXB_CSS_BORDER_LEFT_RIDGE = LXB_CSS_VALUE_RIDGE;
pub const LXB_CSS_BORDER_LEFT_INSET = LXB_CSS_VALUE_INSET;
pub const LXB_CSS_BORDER_LEFT_OUTSET = LXB_CSS_VALUE_OUTSET;
pub const LXB_CSS_BORDER_LEFT__LENGTH = LXB_CSS_VALUE__LENGTH;

pub const lxb_css_border_left_type_t = c_uint;

pub const LXB_CSS_BORDER_RIGHT_THIN = LXB_CSS_VALUE_THIN;
pub const LXB_CSS_BORDER_RIGHT_MEDIUM = LXB_CSS_VALUE_MEDIUM;
pub const LXB_CSS_BORDER_RIGHT_THICK = LXB_CSS_VALUE_THICK;
pub const LXB_CSS_BORDER_RIGHT_NONE = LXB_CSS_VALUE_NONE;
pub const LXB_CSS_BORDER_RIGHT_HIDDEN = LXB_CSS_VALUE_HIDDEN;
pub const LXB_CSS_BORDER_RIGHT_DOTTED = LXB_CSS_VALUE_DOTTED;
pub const LXB_CSS_BORDER_RIGHT_DASHED = LXB_CSS_VALUE_DASHED;
pub const LXB_CSS_BORDER_RIGHT_SOLID = LXB_CSS_VALUE_SOLID;
pub const LXB_CSS_BORDER_RIGHT_DOUBLE = LXB_CSS_VALUE_DOUBLE;
pub const LXB_CSS_BORDER_RIGHT_GROOVE = LXB_CSS_VALUE_GROOVE;
pub const LXB_CSS_BORDER_RIGHT_RIDGE = LXB_CSS_VALUE_RIDGE;
pub const LXB_CSS_BORDER_RIGHT_INSET = LXB_CSS_VALUE_INSET;
pub const LXB_CSS_BORDER_RIGHT_OUTSET = LXB_CSS_VALUE_OUTSET;
pub const LXB_CSS_BORDER_RIGHT__LENGTH = LXB_CSS_VALUE__LENGTH;

pub const lxb_css_border_right_type_t = c_uint;

pub const LXB_CSS_BORDER_TOP_THIN = LXB_CSS_VALUE_THIN;
pub const LXB_CSS_BORDER_TOP_MEDIUM = LXB_CSS_VALUE_MEDIUM;
pub const LXB_CSS_BORDER_TOP_THICK = LXB_CSS_VALUE_THICK;
pub const LXB_CSS_BORDER_TOP_NONE = LXB_CSS_VALUE_NONE;
pub const LXB_CSS_BORDER_TOP_HIDDEN = LXB_CSS_VALUE_HIDDEN;
pub const LXB_CSS_BORDER_TOP_DOTTED = LXB_CSS_VALUE_DOTTED;
pub const LXB_CSS_BORDER_TOP_DASHED = LXB_CSS_VALUE_DASHED;
pub const LXB_CSS_BORDER_TOP_SOLID = LXB_CSS_VALUE_SOLID;
pub const LXB_CSS_BORDER_TOP_DOUBLE = LXB_CSS_VALUE_DOUBLE;
pub const LXB_CSS_BORDER_TOP_GROOVE = LXB_CSS_VALUE_GROOVE;
pub const LXB_CSS_BORDER_TOP_RIDGE = LXB_CSS_VALUE_RIDGE;
pub const LXB_CSS_BORDER_TOP_INSET = LXB_CSS_VALUE_INSET;
pub const LXB_CSS_BORDER_TOP_OUTSET = LXB_CSS_VALUE_OUTSET;
pub const LXB_CSS_BORDER_TOP__LENGTH = LXB_CSS_VALUE__LENGTH;

pub const lxb_css_border_top_type_t = c_uint;

pub const LXB_CSS_BOTTOM_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_BOTTOM__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_BOTTOM__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;

pub const lxb_css_bottom_type_t = c_uint;

pub const LXB_CSS_BOX_SIZING_CONTENT_BOX = LXB_CSS_VALUE_CONTENT_BOX;
pub const LXB_CSS_BOX_SIZING_BORDER_BOX = LXB_CSS_VALUE_BORDER_BOX;

pub const lxb_css_box_sizing_type_t = c_uint;

pub const LXB_CSS_CLEAR_INLINE_START = LXB_CSS_VALUE_INLINE_START;
pub const LXB_CSS_CLEAR_INLINE_END = LXB_CSS_VALUE_INLINE_END;
pub const LXB_CSS_CLEAR_BLOCK_START = LXB_CSS_VALUE_BLOCK_START;
pub const LXB_CSS_CLEAR_BLOCK_END = LXB_CSS_VALUE_BLOCK_END;
pub const LXB_CSS_CLEAR_LEFT = LXB_CSS_VALUE_LEFT;
pub const LXB_CSS_CLEAR_RIGHT = LXB_CSS_VALUE_RIGHT;
pub const LXB_CSS_CLEAR_TOP = LXB_CSS_VALUE_TOP;
pub const LXB_CSS_CLEAR_BOTTOM = LXB_CSS_VALUE_BOTTOM;
pub const LXB_CSS_CLEAR_NONE = LXB_CSS_VALUE_NONE;

pub const lxb_css_clear_type_t = c_uint;

pub const LXB_CSS_COLOR_CURRENTCOLOR = LXB_CSS_VALUE_CURRENTCOLOR;
pub const LXB_CSS_COLOR_TRANSPARENT = LXB_CSS_VALUE_TRANSPARENT;
pub const LXB_CSS_COLOR_HEX = LXB_CSS_VALUE_HEX;
pub const LXB_CSS_COLOR_ALICEBLUE = LXB_CSS_VALUE_ALICEBLUE;
pub const LXB_CSS_COLOR_ANTIQUEWHITE = LXB_CSS_VALUE_ANTIQUEWHITE;
pub const LXB_CSS_COLOR_AQUA = LXB_CSS_VALUE_AQUA;
pub const LXB_CSS_COLOR_AQUAMARINE = LXB_CSS_VALUE_AQUAMARINE;
pub const LXB_CSS_COLOR_AZURE = LXB_CSS_VALUE_AZURE;
pub const LXB_CSS_COLOR_BEIGE = LXB_CSS_VALUE_BEIGE;
pub const LXB_CSS_COLOR_BISQUE = LXB_CSS_VALUE_BISQUE;
pub const LXB_CSS_COLOR_BLACK = LXB_CSS_VALUE_BLACK;
pub const LXB_CSS_COLOR_BLANCHEDALMOND = LXB_CSS_VALUE_BLANCHEDALMOND;
pub const LXB_CSS_COLOR_BLUE = LXB_CSS_VALUE_BLUE;
pub const LXB_CSS_COLOR_BLUEVIOLET = LXB_CSS_VALUE_BLUEVIOLET;
pub const LXB_CSS_COLOR_BROWN = LXB_CSS_VALUE_BROWN;
pub const LXB_CSS_COLOR_BURLYWOOD = LXB_CSS_VALUE_BURLYWOOD;
pub const LXB_CSS_COLOR_CADETBLUE = LXB_CSS_VALUE_CADETBLUE;
pub const LXB_CSS_COLOR_CHARTREUSE = LXB_CSS_VALUE_CHARTREUSE;
pub const LXB_CSS_COLOR_CHOCOLATE = LXB_CSS_VALUE_CHOCOLATE;
pub const LXB_CSS_COLOR_CORAL = LXB_CSS_VALUE_CORAL;
pub const LXB_CSS_COLOR_CORNFLOWERBLUE = LXB_CSS_VALUE_CORNFLOWERBLUE;
pub const LXB_CSS_COLOR_CORNSILK = LXB_CSS_VALUE_CORNSILK;
pub const LXB_CSS_COLOR_CRIMSON = LXB_CSS_VALUE_CRIMSON;
pub const LXB_CSS_COLOR_CYAN = LXB_CSS_VALUE_CYAN;
pub const LXB_CSS_COLOR_DARKBLUE = LXB_CSS_VALUE_DARKBLUE;
pub const LXB_CSS_COLOR_DARKCYAN = LXB_CSS_VALUE_DARKCYAN;
pub const LXB_CSS_COLOR_DARKGOLDENROD = LXB_CSS_VALUE_DARKGOLDENROD;
pub const LXB_CSS_COLOR_DARKGRAY = LXB_CSS_VALUE_DARKGRAY;
pub const LXB_CSS_COLOR_DARKGREEN = LXB_CSS_VALUE_DARKGREEN;
pub const LXB_CSS_COLOR_DARKGREY = LXB_CSS_VALUE_DARKGREY;
pub const LXB_CSS_COLOR_DARKKHAKI = LXB_CSS_VALUE_DARKKHAKI;
pub const LXB_CSS_COLOR_DARKMAGENTA = LXB_CSS_VALUE_DARKMAGENTA;
pub const LXB_CSS_COLOR_DARKOLIVEGREEN = LXB_CSS_VALUE_DARKOLIVEGREEN;
pub const LXB_CSS_COLOR_DARKORANGE = LXB_CSS_VALUE_DARKORANGE;
pub const LXB_CSS_COLOR_DARKORCHID = LXB_CSS_VALUE_DARKORCHID;
pub const LXB_CSS_COLOR_DARKRED = LXB_CSS_VALUE_DARKRED;
pub const LXB_CSS_COLOR_DARKSALMON = LXB_CSS_VALUE_DARKSALMON;
pub const LXB_CSS_COLOR_DARKSEAGREEN = LXB_CSS_VALUE_DARKSEAGREEN;
pub const LXB_CSS_COLOR_DARKSLATEBLUE = LXB_CSS_VALUE_DARKSLATEBLUE;
pub const LXB_CSS_COLOR_DARKSLATEGRAY = LXB_CSS_VALUE_DARKSLATEGRAY;
pub const LXB_CSS_COLOR_DARKSLATEGREY = LXB_CSS_VALUE_DARKSLATEGREY;
pub const LXB_CSS_COLOR_DARKTURQUOISE = LXB_CSS_VALUE_DARKTURQUOISE;
pub const LXB_CSS_COLOR_DARKVIOLET = LXB_CSS_VALUE_DARKVIOLET;
pub const LXB_CSS_COLOR_DEEPPINK = LXB_CSS_VALUE_DEEPPINK;
pub const LXB_CSS_COLOR_DEEPSKYBLUE = LXB_CSS_VALUE_DEEPSKYBLUE;
pub const LXB_CSS_COLOR_DIMGRAY = LXB_CSS_VALUE_DIMGRAY;
pub const LXB_CSS_COLOR_DIMGREY = LXB_CSS_VALUE_DIMGREY;
pub const LXB_CSS_COLOR_DODGERBLUE = LXB_CSS_VALUE_DODGERBLUE;
pub const LXB_CSS_COLOR_FIREBRICK = LXB_CSS_VALUE_FIREBRICK;
pub const LXB_CSS_COLOR_FLORALWHITE = LXB_CSS_VALUE_FLORALWHITE;
pub const LXB_CSS_COLOR_FORESTGREEN = LXB_CSS_VALUE_FORESTGREEN;
pub const LXB_CSS_COLOR_FUCHSIA = LXB_CSS_VALUE_FUCHSIA;
pub const LXB_CSS_COLOR_GAINSBORO = LXB_CSS_VALUE_GAINSBORO;
pub const LXB_CSS_COLOR_GHOSTWHITE = LXB_CSS_VALUE_GHOSTWHITE;
pub const LXB_CSS_COLOR_GOLD = LXB_CSS_VALUE_GOLD;
pub const LXB_CSS_COLOR_GOLDENROD = LXB_CSS_VALUE_GOLDENROD;
pub const LXB_CSS_COLOR_GRAY = LXB_CSS_VALUE_GRAY;
pub const LXB_CSS_COLOR_GREEN = LXB_CSS_VALUE_GREEN;
pub const LXB_CSS_COLOR_GREENYELLOW = LXB_CSS_VALUE_GREENYELLOW;
pub const LXB_CSS_COLOR_GREY = LXB_CSS_VALUE_GREY;
pub const LXB_CSS_COLOR_HONEYDEW = LXB_CSS_VALUE_HONEYDEW;
pub const LXB_CSS_COLOR_HOTPINK = LXB_CSS_VALUE_HOTPINK;
pub const LXB_CSS_COLOR_INDIANRED = LXB_CSS_VALUE_INDIANRED;
pub const LXB_CSS_COLOR_INDIGO = LXB_CSS_VALUE_INDIGO;
pub const LXB_CSS_COLOR_IVORY = LXB_CSS_VALUE_IVORY;
pub const LXB_CSS_COLOR_KHAKI = LXB_CSS_VALUE_KHAKI;
pub const LXB_CSS_COLOR_LAVENDER = LXB_CSS_VALUE_LAVENDER;
pub const LXB_CSS_COLOR_LAVENDERBLUSH = LXB_CSS_VALUE_LAVENDERBLUSH;
pub const LXB_CSS_COLOR_LAWNGREEN = LXB_CSS_VALUE_LAWNGREEN;
pub const LXB_CSS_COLOR_LEMONCHIFFON = LXB_CSS_VALUE_LEMONCHIFFON;
pub const LXB_CSS_COLOR_LIGHTBLUE = LXB_CSS_VALUE_LIGHTBLUE;
pub const LXB_CSS_COLOR_LIGHTCORAL = LXB_CSS_VALUE_LIGHTCORAL;
pub const LXB_CSS_COLOR_LIGHTCYAN = LXB_CSS_VALUE_LIGHTCYAN;
pub const LXB_CSS_COLOR_LIGHTGOLDENRODYELLOW = LXB_CSS_VALUE_LIGHTGOLDENRODYELLOW;
pub const LXB_CSS_COLOR_LIGHTGRAY = LXB_CSS_VALUE_LIGHTGRAY;
pub const LXB_CSS_COLOR_LIGHTGREEN = LXB_CSS_VALUE_LIGHTGREEN;
pub const LXB_CSS_COLOR_LIGHTGREY = LXB_CSS_VALUE_LIGHTGREY;
pub const LXB_CSS_COLOR_LIGHTPINK = LXB_CSS_VALUE_LIGHTPINK;
pub const LXB_CSS_COLOR_LIGHTSALMON = LXB_CSS_VALUE_LIGHTSALMON;
pub const LXB_CSS_COLOR_LIGHTSEAGREEN = LXB_CSS_VALUE_LIGHTSEAGREEN;
pub const LXB_CSS_COLOR_LIGHTSKYBLUE = LXB_CSS_VALUE_LIGHTSKYBLUE;
pub const LXB_CSS_COLOR_LIGHTSLATEGRAY = LXB_CSS_VALUE_LIGHTSLATEGRAY;
pub const LXB_CSS_COLOR_LIGHTSLATEGREY = LXB_CSS_VALUE_LIGHTSLATEGREY;
pub const LXB_CSS_COLOR_LIGHTSTEELBLUE = LXB_CSS_VALUE_LIGHTSTEELBLUE;
pub const LXB_CSS_COLOR_LIGHTYELLOW = LXB_CSS_VALUE_LIGHTYELLOW;
pub const LXB_CSS_COLOR_LIME = LXB_CSS_VALUE_LIME;
pub const LXB_CSS_COLOR_LIMEGREEN = LXB_CSS_VALUE_LIMEGREEN;
pub const LXB_CSS_COLOR_LINEN = LXB_CSS_VALUE_LINEN;
pub const LXB_CSS_COLOR_MAGENTA = LXB_CSS_VALUE_MAGENTA;
pub const LXB_CSS_COLOR_MAROON = LXB_CSS_VALUE_MAROON;
pub const LXB_CSS_COLOR_MEDIUMAQUAMARINE = LXB_CSS_VALUE_MEDIUMAQUAMARINE;
pub const LXB_CSS_COLOR_MEDIUMBLUE = LXB_CSS_VALUE_MEDIUMBLUE;
pub const LXB_CSS_COLOR_MEDIUMORCHID = LXB_CSS_VALUE_MEDIUMORCHID;
pub const LXB_CSS_COLOR_MEDIUMPURPLE = LXB_CSS_VALUE_MEDIUMPURPLE;
pub const LXB_CSS_COLOR_MEDIUMSEAGREEN = LXB_CSS_VALUE_MEDIUMSEAGREEN;
pub const LXB_CSS_COLOR_MEDIUMSLATEBLUE = LXB_CSS_VALUE_MEDIUMSLATEBLUE;
pub const LXB_CSS_COLOR_MEDIUMSPRINGGREEN = LXB_CSS_VALUE_MEDIUMSPRINGGREEN;
pub const LXB_CSS_COLOR_MEDIUMTURQUOISE = LXB_CSS_VALUE_MEDIUMTURQUOISE;
pub const LXB_CSS_COLOR_MEDIUMVIOLETRED = LXB_CSS_VALUE_MEDIUMVIOLETRED;
pub const LXB_CSS_COLOR_MIDNIGHTBLUE = LXB_CSS_VALUE_MIDNIGHTBLUE;
pub const LXB_CSS_COLOR_MINTCREAM = LXB_CSS_VALUE_MINTCREAM;
pub const LXB_CSS_COLOR_MISTYROSE = LXB_CSS_VALUE_MISTYROSE;
pub const LXB_CSS_COLOR_MOCCASIN = LXB_CSS_VALUE_MOCCASIN;
pub const LXB_CSS_COLOR_NAVAJOWHITE = LXB_CSS_VALUE_NAVAJOWHITE;
pub const LXB_CSS_COLOR_NAVY = LXB_CSS_VALUE_NAVY;
pub const LXB_CSS_COLOR_OLDLACE = LXB_CSS_VALUE_OLDLACE;
pub const LXB_CSS_COLOR_OLIVE = LXB_CSS_VALUE_OLIVE;
pub const LXB_CSS_COLOR_OLIVEDRAB = LXB_CSS_VALUE_OLIVEDRAB;
pub const LXB_CSS_COLOR_ORANGE = LXB_CSS_VALUE_ORANGE;
pub const LXB_CSS_COLOR_ORANGERED = LXB_CSS_VALUE_ORANGERED;
pub const LXB_CSS_COLOR_ORCHID = LXB_CSS_VALUE_ORCHID;
pub const LXB_CSS_COLOR_PALEGOLDENROD = LXB_CSS_VALUE_PALEGOLDENROD;
pub const LXB_CSS_COLOR_PALEGREEN = LXB_CSS_VALUE_PALEGREEN;
pub const LXB_CSS_COLOR_PALETURQUOISE = LXB_CSS_VALUE_PALETURQUOISE;
pub const LXB_CSS_COLOR_PALEVIOLETRED = LXB_CSS_VALUE_PALEVIOLETRED;
pub const LXB_CSS_COLOR_PAPAYAWHIP = LXB_CSS_VALUE_PAPAYAWHIP;
pub const LXB_CSS_COLOR_PEACHPUFF = LXB_CSS_VALUE_PEACHPUFF;
pub const LXB_CSS_COLOR_PERU = LXB_CSS_VALUE_PERU;
pub const LXB_CSS_COLOR_PINK = LXB_CSS_VALUE_PINK;
pub const LXB_CSS_COLOR_PLUM = LXB_CSS_VALUE_PLUM;
pub const LXB_CSS_COLOR_POWDERBLUE = LXB_CSS_VALUE_POWDERBLUE;
pub const LXB_CSS_COLOR_PURPLE = LXB_CSS_VALUE_PURPLE;
pub const LXB_CSS_COLOR_REBECCAPURPLE = LXB_CSS_VALUE_REBECCAPURPLE;
pub const LXB_CSS_COLOR_RED = LXB_CSS_VALUE_RED;
pub const LXB_CSS_COLOR_ROSYBROWN = LXB_CSS_VALUE_ROSYBROWN;
pub const LXB_CSS_COLOR_ROYALBLUE = LXB_CSS_VALUE_ROYALBLUE;
pub const LXB_CSS_COLOR_SADDLEBROWN = LXB_CSS_VALUE_SADDLEBROWN;
pub const LXB_CSS_COLOR_SALMON = LXB_CSS_VALUE_SALMON;
pub const LXB_CSS_COLOR_SANDYBROWN = LXB_CSS_VALUE_SANDYBROWN;
pub const LXB_CSS_COLOR_SEAGREEN = LXB_CSS_VALUE_SEAGREEN;
pub const LXB_CSS_COLOR_SEASHELL = LXB_CSS_VALUE_SEASHELL;
pub const LXB_CSS_COLOR_SIENNA = LXB_CSS_VALUE_SIENNA;
pub const LXB_CSS_COLOR_SILVER = LXB_CSS_VALUE_SILVER;
pub const LXB_CSS_COLOR_SKYBLUE = LXB_CSS_VALUE_SKYBLUE;
pub const LXB_CSS_COLOR_SLATEBLUE = LXB_CSS_VALUE_SLATEBLUE;
pub const LXB_CSS_COLOR_SLATEGRAY = LXB_CSS_VALUE_SLATEGRAY;
pub const LXB_CSS_COLOR_SLATEGREY = LXB_CSS_VALUE_SLATEGREY;
pub const LXB_CSS_COLOR_SNOW = LXB_CSS_VALUE_SNOW;
pub const LXB_CSS_COLOR_SPRINGGREEN = LXB_CSS_VALUE_SPRINGGREEN;
pub const LXB_CSS_COLOR_STEELBLUE = LXB_CSS_VALUE_STEELBLUE;
pub const LXB_CSS_COLOR_TAN = LXB_CSS_VALUE_TAN;
pub const LXB_CSS_COLOR_TEAL = LXB_CSS_VALUE_TEAL;
pub const LXB_CSS_COLOR_THISTLE = LXB_CSS_VALUE_THISTLE;
pub const LXB_CSS_COLOR_TOMATO = LXB_CSS_VALUE_TOMATO;
pub const LXB_CSS_COLOR_TURQUOISE = LXB_CSS_VALUE_TURQUOISE;
pub const LXB_CSS_COLOR_VIOLET = LXB_CSS_VALUE_VIOLET;
pub const LXB_CSS_COLOR_WHEAT = LXB_CSS_VALUE_WHEAT;
pub const LXB_CSS_COLOR_WHITE = LXB_CSS_VALUE_WHITE;
pub const LXB_CSS_COLOR_WHITESMOKE = LXB_CSS_VALUE_WHITESMOKE;
pub const LXB_CSS_COLOR_YELLOW = LXB_CSS_VALUE_YELLOW;
pub const LXB_CSS_COLOR_YELLOWGREEN = LXB_CSS_VALUE_YELLOWGREEN;
pub const LXB_CSS_COLOR_CANVAS = LXB_CSS_VALUE_CANVAS;
pub const LXB_CSS_COLOR_CANVASTEXT = LXB_CSS_VALUE_CANVASTEXT;
pub const LXB_CSS_COLOR_LINKTEXT = LXB_CSS_VALUE_LINKTEXT;
pub const LXB_CSS_COLOR_VISITEDTEXT = LXB_CSS_VALUE_VISITEDTEXT;
pub const LXB_CSS_COLOR_ACTIVETEXT = LXB_CSS_VALUE_ACTIVETEXT;
pub const LXB_CSS_COLOR_BUTTONFACE = LXB_CSS_VALUE_BUTTONFACE;
pub const LXB_CSS_COLOR_BUTTONTEXT = LXB_CSS_VALUE_BUTTONTEXT;
pub const LXB_CSS_COLOR_BUTTONBORDER = LXB_CSS_VALUE_BUTTONBORDER;
pub const LXB_CSS_COLOR_FIELD = LXB_CSS_VALUE_FIELD;
pub const LXB_CSS_COLOR_FIELDTEXT = LXB_CSS_VALUE_FIELDTEXT;
pub const LXB_CSS_COLOR_HIGHLIGHT = LXB_CSS_VALUE_HIGHLIGHT;
pub const LXB_CSS_COLOR_HIGHLIGHTTEXT = LXB_CSS_VALUE_HIGHLIGHTTEXT;
pub const LXB_CSS_COLOR_SELECTEDITEM = LXB_CSS_VALUE_SELECTEDITEM;
pub const LXB_CSS_COLOR_SELECTEDITEMTEXT = LXB_CSS_VALUE_SELECTEDITEMTEXT;
pub const LXB_CSS_COLOR_MARK = LXB_CSS_VALUE_MARK;
pub const LXB_CSS_COLOR_MARKTEXT = LXB_CSS_VALUE_MARKTEXT;
pub const LXB_CSS_COLOR_GRAYTEXT = LXB_CSS_VALUE_GRAYTEXT;
pub const LXB_CSS_COLOR_ACCENTCOLOR = LXB_CSS_VALUE_ACCENTCOLOR;
pub const LXB_CSS_COLOR_ACCENTCOLORTEXT = LXB_CSS_VALUE_ACCENTCOLORTEXT;
pub const LXB_CSS_COLOR_RGB = LXB_CSS_VALUE_RGB;
pub const LXB_CSS_COLOR_RGBA = LXB_CSS_VALUE_RGBA;
pub const LXB_CSS_COLOR_HSL = LXB_CSS_VALUE_HSL;
pub const LXB_CSS_COLOR_HSLA = LXB_CSS_VALUE_HSLA;
pub const LXB_CSS_COLOR_HWB = LXB_CSS_VALUE_HWB;
pub const LXB_CSS_COLOR_LAB = LXB_CSS_VALUE_LAB;
pub const LXB_CSS_COLOR_LCH = LXB_CSS_VALUE_LCH;
pub const LXB_CSS_COLOR_OKLAB = LXB_CSS_VALUE_OKLAB;
pub const LXB_CSS_COLOR_OKLCH = LXB_CSS_VALUE_OKLCH;
pub const LXB_CSS_COLOR_COLOR = LXB_CSS_VALUE_COLOR;

pub const lxb_css_color_type_t = c_uint;

pub const LXB_CSS_DIRECTION_LTR = LXB_CSS_VALUE_LTR;
pub const LXB_CSS_DIRECTION_RTL = LXB_CSS_VALUE_RTL;

pub const lxb_css_direction_type_t = c_uint;

pub const LXB_CSS_DISPLAY_BLOCK = LXB_CSS_VALUE_BLOCK;
pub const LXB_CSS_DISPLAY_INLINE = LXB_CSS_VALUE_INLINE;
pub const LXB_CSS_DISPLAY_RUN_IN = LXB_CSS_VALUE_RUN_IN;
pub const LXB_CSS_DISPLAY_FLOW = LXB_CSS_VALUE_FLOW;
pub const LXB_CSS_DISPLAY_FLOW_ROOT = LXB_CSS_VALUE_FLOW_ROOT;
pub const LXB_CSS_DISPLAY_TABLE = LXB_CSS_VALUE_TABLE;
pub const LXB_CSS_DISPLAY_FLEX = LXB_CSS_VALUE_FLEX;
pub const LXB_CSS_DISPLAY_GRID = LXB_CSS_VALUE_GRID;
pub const LXB_CSS_DISPLAY_RUBY = LXB_CSS_VALUE_RUBY;
pub const LXB_CSS_DISPLAY_LIST_ITEM = LXB_CSS_VALUE_LIST_ITEM;
pub const LXB_CSS_DISPLAY_TABLE_ROW_GROUP = LXB_CSS_VALUE_TABLE_ROW_GROUP;
pub const LXB_CSS_DISPLAY_TABLE_HEADER_GROUP = LXB_CSS_VALUE_TABLE_HEADER_GROUP;
pub const LXB_CSS_DISPLAY_TABLE_FOOTER_GROUP = LXB_CSS_VALUE_TABLE_FOOTER_GROUP;
pub const LXB_CSS_DISPLAY_TABLE_ROW = LXB_CSS_VALUE_TABLE_ROW;
pub const LXB_CSS_DISPLAY_TABLE_CELL = LXB_CSS_VALUE_TABLE_CELL;
pub const LXB_CSS_DISPLAY_TABLE_COLUMN_GROUP = LXB_CSS_VALUE_TABLE_COLUMN_GROUP;
pub const LXB_CSS_DISPLAY_TABLE_COLUMN = LXB_CSS_VALUE_TABLE_COLUMN;
pub const LXB_CSS_DISPLAY_TABLE_CAPTION = LXB_CSS_VALUE_TABLE_CAPTION;
pub const LXB_CSS_DISPLAY_RUBY_BASE = LXB_CSS_VALUE_RUBY_BASE;
pub const LXB_CSS_DISPLAY_RUBY_TEXT = LXB_CSS_VALUE_RUBY_TEXT;
pub const LXB_CSS_DISPLAY_RUBY_BASE_CONTAINER = LXB_CSS_VALUE_RUBY_BASE_CONTAINER;
pub const LXB_CSS_DISPLAY_RUBY_TEXT_CONTAINER = LXB_CSS_VALUE_RUBY_TEXT_CONTAINER;
pub const LXB_CSS_DISPLAY_CONTENTS = LXB_CSS_VALUE_CONTENTS;
pub const LXB_CSS_DISPLAY_NONE = LXB_CSS_VALUE_NONE;
pub const LXB_CSS_DISPLAY_INLINE_BLOCK = LXB_CSS_VALUE_INLINE_BLOCK;
pub const LXB_CSS_DISPLAY_INLINE_TABLE = LXB_CSS_VALUE_INLINE_TABLE;
pub const LXB_CSS_DISPLAY_INLINE_FLEX = LXB_CSS_VALUE_INLINE_FLEX;
pub const LXB_CSS_DISPLAY_INLINE_GRID = LXB_CSS_VALUE_INLINE_GRID;

pub const lxb_css_display_type_t = c_uint;

pub const LXB_CSS_DOMINANT_BASELINE_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_DOMINANT_BASELINE_TEXT_BOTTOM = LXB_CSS_VALUE_TEXT_BOTTOM;
pub const LXB_CSS_DOMINANT_BASELINE_ALPHABETIC = LXB_CSS_VALUE_ALPHABETIC;
pub const LXB_CSS_DOMINANT_BASELINE_IDEOGRAPHIC = LXB_CSS_VALUE_IDEOGRAPHIC;
pub const LXB_CSS_DOMINANT_BASELINE_MIDDLE = LXB_CSS_VALUE_MIDDLE;
pub const LXB_CSS_DOMINANT_BASELINE_CENTRAL = LXB_CSS_VALUE_CENTRAL;
pub const LXB_CSS_DOMINANT_BASELINE_MATHEMATICAL = LXB_CSS_VALUE_MATHEMATICAL;
pub const LXB_CSS_DOMINANT_BASELINE_HANGING = LXB_CSS_VALUE_HANGING;
pub const LXB_CSS_DOMINANT_BASELINE_TEXT_TOP = LXB_CSS_VALUE_TEXT_TOP;

pub const lxb_css_dominant_baseline_type_t = c_uint;

pub const LXB_CSS_FLEX_NONE = LXB_CSS_VALUE_NONE;

pub const lxb_css_flex_type_t = c_uint;

pub const LXB_CSS_FLEX_BASIS_CONTENT = LXB_CSS_VALUE_CONTENT;

pub const lxb_css_flex_basis_type_t = c_uint;

pub const LXB_CSS_FLEX_DIRECTION_ROW = LXB_CSS_VALUE_ROW;
pub const LXB_CSS_FLEX_DIRECTION_ROW_REVERSE = LXB_CSS_VALUE_ROW_REVERSE;
pub const LXB_CSS_FLEX_DIRECTION_COLUMN = LXB_CSS_VALUE_COLUMN;
pub const LXB_CSS_FLEX_DIRECTION_COLUMN_REVERSE = LXB_CSS_VALUE_COLUMN_REVERSE;

pub const lxb_css_flex_direction_type_t = c_uint;

pub const LXB_CSS_FLEX_GROW__NUMBER = LXB_CSS_VALUE__NUMBER;

pub const lxb_css_flex_grow_type_t = c_uint;

pub const LXB_CSS_FLEX_SHRINK__NUMBER = LXB_CSS_VALUE__NUMBER;

pub const lxb_css_flex_shrink_type_t = c_uint;

pub const LXB_CSS_FLEX_WRAP_NOWRAP = LXB_CSS_VALUE_NOWRAP;
pub const LXB_CSS_FLEX_WRAP_WRAP = LXB_CSS_VALUE_WRAP;
pub const LXB_CSS_FLEX_WRAP_WRAP_REVERSE = LXB_CSS_VALUE_WRAP_REVERSE;

pub const lxb_css_flex_wrap_type_t = c_uint;

pub const LXB_CSS_FLOAT_BLOCK_START = LXB_CSS_VALUE_BLOCK_START;
pub const LXB_CSS_FLOAT_BLOCK_END = LXB_CSS_VALUE_BLOCK_END;
pub const LXB_CSS_FLOAT_INLINE_START = LXB_CSS_VALUE_INLINE_START;
pub const LXB_CSS_FLOAT_INLINE_END = LXB_CSS_VALUE_INLINE_END;
pub const LXB_CSS_FLOAT_SNAP_BLOCK = LXB_CSS_VALUE_SNAP_BLOCK;
pub const LXB_CSS_FLOAT_START = LXB_CSS_VALUE_START;
pub const LXB_CSS_FLOAT_END = LXB_CSS_VALUE_END;
pub const LXB_CSS_FLOAT_NEAR = LXB_CSS_VALUE_NEAR;
pub const LXB_CSS_FLOAT_SNAP_INLINE = LXB_CSS_VALUE_SNAP_INLINE;
pub const LXB_CSS_FLOAT_LEFT = LXB_CSS_VALUE_LEFT;
pub const LXB_CSS_FLOAT_RIGHT = LXB_CSS_VALUE_RIGHT;
pub const LXB_CSS_FLOAT_TOP = LXB_CSS_VALUE_TOP;
pub const LXB_CSS_FLOAT_BOTTOM = LXB_CSS_VALUE_BOTTOM;
pub const LXB_CSS_FLOAT_NONE = LXB_CSS_VALUE_NONE;

pub const lxb_css_float_type_t = c_uint;

pub const LXB_CSS_FLOAT_DEFER__INTEGER = LXB_CSS_VALUE__INTEGER;
pub const LXB_CSS_FLOAT_DEFER_LAST = LXB_CSS_VALUE_LAST;
pub const LXB_CSS_FLOAT_DEFER_NONE = LXB_CSS_VALUE_NONE;

pub const lxb_css_float_defer_type_t = c_uint;

pub const LXB_CSS_FLOAT_OFFSET__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_FLOAT_OFFSET__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;

pub const lxb_css_float_offset_type_t = c_uint;

pub const LXB_CSS_FLOAT_REFERENCE_INLINE = LXB_CSS_VALUE_INLINE;
pub const LXB_CSS_FLOAT_REFERENCE_COLUMN = LXB_CSS_VALUE_COLUMN;
pub const LXB_CSS_FLOAT_REFERENCE_REGION = LXB_CSS_VALUE_REGION;
pub const LXB_CSS_FLOAT_REFERENCE_PAGE = LXB_CSS_VALUE_PAGE;

pub const lxb_css_float_reference_type_t = c_uint;

pub const LXB_CSS_FONT_FAMILY_SERIF = LXB_CSS_VALUE_SERIF;
pub const LXB_CSS_FONT_FAMILY_SANS_SERIF = LXB_CSS_VALUE_SANS_SERIF;
pub const LXB_CSS_FONT_FAMILY_CURSIVE = LXB_CSS_VALUE_CURSIVE;
pub const LXB_CSS_FONT_FAMILY_FANTASY = LXB_CSS_VALUE_FANTASY;
pub const LXB_CSS_FONT_FAMILY_MONOSPACE = LXB_CSS_VALUE_MONOSPACE;
pub const LXB_CSS_FONT_FAMILY_SYSTEM_UI = LXB_CSS_VALUE_SYSTEM_UI;
pub const LXB_CSS_FONT_FAMILY_EMOJI = LXB_CSS_VALUE_EMOJI;
pub const LXB_CSS_FONT_FAMILY_MATH = LXB_CSS_VALUE_MATH;
pub const LXB_CSS_FONT_FAMILY_FANGSONG = LXB_CSS_VALUE_FANGSONG;
pub const LXB_CSS_FONT_FAMILY_UI_SERIF = LXB_CSS_VALUE_UI_SERIF;
pub const LXB_CSS_FONT_FAMILY_UI_SANS_SERIF = LXB_CSS_VALUE_UI_SANS_SERIF;
pub const LXB_CSS_FONT_FAMILY_UI_MONOSPACE = LXB_CSS_VALUE_UI_MONOSPACE;
pub const LXB_CSS_FONT_FAMILY_UI_ROUNDED = LXB_CSS_VALUE_UI_ROUNDED;

pub const lxb_css_font_family_type_t = c_uint;

pub const LXB_CSS_FONT_SIZE_XX_SMALL = LXB_CSS_VALUE_XX_SMALL;
pub const LXB_CSS_FONT_SIZE_X_SMALL = LXB_CSS_VALUE_X_SMALL;
pub const LXB_CSS_FONT_SIZE_SMALL = LXB_CSS_VALUE_SMALL;
pub const LXB_CSS_FONT_SIZE_MEDIUM = LXB_CSS_VALUE_MEDIUM;
pub const LXB_CSS_FONT_SIZE_LARGE = LXB_CSS_VALUE_LARGE;
pub const LXB_CSS_FONT_SIZE_X_LARGE = LXB_CSS_VALUE_X_LARGE;
pub const LXB_CSS_FONT_SIZE_XX_LARGE = LXB_CSS_VALUE_XX_LARGE;
pub const LXB_CSS_FONT_SIZE_XXX_LARGE = LXB_CSS_VALUE_XXX_LARGE;
pub const LXB_CSS_FONT_SIZE_LARGER = LXB_CSS_VALUE_LARGER;
pub const LXB_CSS_FONT_SIZE_SMALLER = LXB_CSS_VALUE_SMALLER;
pub const LXB_CSS_FONT_SIZE_MATH = LXB_CSS_VALUE_MATH;
pub const LXB_CSS_FONT_SIZE__LENGTH = LXB_CSS_VALUE__LENGTH;

pub const lxb_css_font_size_type_t = c_uint;

pub const LXB_CSS_FONT_STRETCH_NORMAL = LXB_CSS_VALUE_NORMAL;
pub const LXB_CSS_FONT_STRETCH__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;
pub const LXB_CSS_FONT_STRETCH_ULTRA_CONDENSED = LXB_CSS_VALUE_ULTRA_CONDENSED;
pub const LXB_CSS_FONT_STRETCH_EXTRA_CONDENSED = LXB_CSS_VALUE_EXTRA_CONDENSED;
pub const LXB_CSS_FONT_STRETCH_CONDENSED = LXB_CSS_VALUE_CONDENSED;
pub const LXB_CSS_FONT_STRETCH_SEMI_CONDENSED = LXB_CSS_VALUE_SEMI_CONDENSED;
pub const LXB_CSS_FONT_STRETCH_SEMI_EXPANDED = LXB_CSS_VALUE_SEMI_EXPANDED;
pub const LXB_CSS_FONT_STRETCH_EXPANDED = LXB_CSS_VALUE_EXPANDED;
pub const LXB_CSS_FONT_STRETCH_EXTRA_EXPANDED = LXB_CSS_VALUE_EXTRA_EXPANDED;
pub const LXB_CSS_FONT_STRETCH_ULTRA_EXPANDED = LXB_CSS_VALUE_ULTRA_EXPANDED;

pub const lxb_css_font_stretch_type_t = c_uint;

pub const LXB_CSS_FONT_STYLE_NORMAL = LXB_CSS_VALUE_NORMAL;
pub const LXB_CSS_FONT_STYLE_ITALIC = LXB_CSS_VALUE_ITALIC;
pub const LXB_CSS_FONT_STYLE_OBLIQUE = LXB_CSS_VALUE_OBLIQUE;

pub const lxb_css_font_style_type_t = c_uint;

pub const LXB_CSS_FONT_WEIGHT_NORMAL = LXB_CSS_VALUE_NORMAL;
pub const LXB_CSS_FONT_WEIGHT_BOLD = LXB_CSS_VALUE_BOLD;
pub const LXB_CSS_FONT_WEIGHT__NUMBER = LXB_CSS_VALUE__NUMBER;
pub const LXB_CSS_FONT_WEIGHT_BOLDER = LXB_CSS_VALUE_BOLDER;
pub const LXB_CSS_FONT_WEIGHT_LIGHTER = LXB_CSS_VALUE_LIGHTER;

pub const lxb_css_font_weight_type_t = c_uint;

pub const LXB_CSS_HANGING_PUNCTUATION_NONE = LXB_CSS_VALUE_NONE;
pub const LXB_CSS_HANGING_PUNCTUATION_FIRST = LXB_CSS_VALUE_FIRST;
pub const LXB_CSS_HANGING_PUNCTUATION_FORCE_END = LXB_CSS_VALUE_FORCE_END;
pub const LXB_CSS_HANGING_PUNCTUATION_ALLOW_END = LXB_CSS_VALUE_ALLOW_END;
pub const LXB_CSS_HANGING_PUNCTUATION_LAST = LXB_CSS_VALUE_LAST;

pub const lxb_css_hanging_punctuation_type_t = c_uint;

pub const LXB_CSS_HEIGHT_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_HEIGHT_MIN_CONTENT = LXB_CSS_VALUE_MIN_CONTENT;
pub const LXB_CSS_HEIGHT_MAX_CONTENT = LXB_CSS_VALUE_MAX_CONTENT;
pub const LXB_CSS_HEIGHT__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_HEIGHT__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;
pub const LXB_CSS_HEIGHT__NUMBER = LXB_CSS_VALUE__NUMBER;
pub const LXB_CSS_HEIGHT__ANGLE = LXB_CSS_VALUE__ANGLE;

pub const lxb_css_height_type_t = c_uint;

pub const LXB_CSS_HYPHENS_NONE = LXB_CSS_VALUE_NONE;
pub const LXB_CSS_HYPHENS_MANUAL = LXB_CSS_VALUE_MANUAL;
pub const LXB_CSS_HYPHENS_AUTO = LXB_CSS_VALUE_AUTO;

pub const lxb_css_hyphens_type_t = c_uint;

pub const LXB_CSS_INSET_BLOCK_END_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_INSET_BLOCK_END__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_INSET_BLOCK_END__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;

pub const lxb_css_inset_block_end_type_t = c_uint;

pub const LXB_CSS_INSET_BLOCK_START_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_INSET_BLOCK_START__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_INSET_BLOCK_START__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;

pub const lxb_css_inset_block_start_type_t = c_uint;

pub const LXB_CSS_INSET_INLINE_END_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_INSET_INLINE_END__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_INSET_INLINE_END__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;

pub const lxb_css_inset_inline_end_type_t = c_uint;

pub const LXB_CSS_INSET_INLINE_START_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_INSET_INLINE_START__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_INSET_INLINE_START__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;

pub const lxb_css_inset_inline_start_type_t = c_uint;

pub const LXB_CSS_JUSTIFY_CONTENT_FLEX_START = LXB_CSS_VALUE_FLEX_START;
pub const LXB_CSS_JUSTIFY_CONTENT_FLEX_END = LXB_CSS_VALUE_FLEX_END;
pub const LXB_CSS_JUSTIFY_CONTENT_CENTER = LXB_CSS_VALUE_CENTER;
pub const LXB_CSS_JUSTIFY_CONTENT_SPACE_BETWEEN = LXB_CSS_VALUE_SPACE_BETWEEN;
pub const LXB_CSS_JUSTIFY_CONTENT_SPACE_AROUND = LXB_CSS_VALUE_SPACE_AROUND;

pub const lxb_css_justify_content_type_t = c_uint;

pub const LXB_CSS_LEFT_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_LEFT__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_LEFT__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;

pub const lxb_css_left_type_t = c_uint;

pub const LXB_CSS_LETTER_SPACING_NORMAL = LXB_CSS_VALUE_NORMAL;
pub const LXB_CSS_LETTER_SPACING__LENGTH = LXB_CSS_VALUE__LENGTH;

pub const lxb_css_letter_spacing_type_t = c_uint;

pub const LXB_CSS_LINE_BREAK_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_LINE_BREAK_LOOSE = LXB_CSS_VALUE_LOOSE;
pub const LXB_CSS_LINE_BREAK_NORMAL = LXB_CSS_VALUE_NORMAL;
pub const LXB_CSS_LINE_BREAK_STRICT = LXB_CSS_VALUE_STRICT;
pub const LXB_CSS_LINE_BREAK_ANYWHERE = LXB_CSS_VALUE_ANYWHERE;

pub const lxb_css_line_break_type_t = c_uint;

pub const LXB_CSS_LINE_HEIGHT_NORMAL = LXB_CSS_VALUE_NORMAL;
pub const LXB_CSS_LINE_HEIGHT__NUMBER = LXB_CSS_VALUE__NUMBER;
pub const LXB_CSS_LINE_HEIGHT__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_LINE_HEIGHT__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;

pub const lxb_css_line_height_type_t = c_uint;

pub const LXB_CSS_MARGIN_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_MARGIN__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_MARGIN__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;

pub const lxb_css_margin_type_t = c_uint;

pub const LXB_CSS_MARGIN_BOTTOM_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_MARGIN_BOTTOM__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_MARGIN_BOTTOM__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;

pub const lxb_css_margin_bottom_type_t = c_uint;

pub const LXB_CSS_MARGIN_LEFT_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_MARGIN_LEFT__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_MARGIN_LEFT__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;

pub const lxb_css_margin_left_type_t = c_uint;

pub const LXB_CSS_MARGIN_RIGHT_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_MARGIN_RIGHT__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_MARGIN_RIGHT__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;

pub const lxb_css_margin_right_type_t = c_uint;

pub const LXB_CSS_MARGIN_TOP_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_MARGIN_TOP__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_MARGIN_TOP__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;

pub const lxb_css_margin_top_type_t = c_uint;

pub const LXB_CSS_MAX_HEIGHT_NONE = LXB_CSS_VALUE_NONE;
pub const LXB_CSS_MAX_HEIGHT_MIN_CONTENT = LXB_CSS_VALUE_MIN_CONTENT;
pub const LXB_CSS_MAX_HEIGHT_MAX_CONTENT = LXB_CSS_VALUE_MAX_CONTENT;
pub const LXB_CSS_MAX_HEIGHT__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_MAX_HEIGHT__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;
pub const LXB_CSS_MAX_HEIGHT__NUMBER = LXB_CSS_VALUE__NUMBER;
pub const LXB_CSS_MAX_HEIGHT__ANGLE = LXB_CSS_VALUE__ANGLE;

pub const lxb_css_max_height_type_t = c_uint;

pub const LXB_CSS_MAX_WIDTH_NONE = LXB_CSS_VALUE_NONE;
pub const LXB_CSS_MAX_WIDTH_MIN_CONTENT = LXB_CSS_VALUE_MIN_CONTENT;
pub const LXB_CSS_MAX_WIDTH_MAX_CONTENT = LXB_CSS_VALUE_MAX_CONTENT;
pub const LXB_CSS_MAX_WIDTH__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_MAX_WIDTH__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;
pub const LXB_CSS_MAX_WIDTH__NUMBER = LXB_CSS_VALUE__NUMBER;
pub const LXB_CSS_MAX_WIDTH__ANGLE = LXB_CSS_VALUE__ANGLE;

pub const lxb_css_max_width_type_t = c_uint;

pub const LXB_CSS_MIN_HEIGHT_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_MIN_HEIGHT_MIN_CONTENT = LXB_CSS_VALUE_MIN_CONTENT;
pub const LXB_CSS_MIN_HEIGHT_MAX_CONTENT = LXB_CSS_VALUE_MAX_CONTENT;
pub const LXB_CSS_MIN_HEIGHT__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_MIN_HEIGHT__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;
pub const LXB_CSS_MIN_HEIGHT__NUMBER = LXB_CSS_VALUE__NUMBER;
pub const LXB_CSS_MIN_HEIGHT__ANGLE = LXB_CSS_VALUE__ANGLE;

pub const lxb_css_min_height_type_t = c_uint;

pub const LXB_CSS_MIN_WIDTH_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_MIN_WIDTH_MIN_CONTENT = LXB_CSS_VALUE_MIN_CONTENT;
pub const LXB_CSS_MIN_WIDTH_MAX_CONTENT = LXB_CSS_VALUE_MAX_CONTENT;
pub const LXB_CSS_MIN_WIDTH__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_MIN_WIDTH__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;
pub const LXB_CSS_MIN_WIDTH__NUMBER = LXB_CSS_VALUE__NUMBER;
pub const LXB_CSS_MIN_WIDTH__ANGLE = LXB_CSS_VALUE__ANGLE;

pub const lxb_css_min_width_type_t = c_uint;

pub const LXB_CSS_OPACITY__NUMBER = LXB_CSS_VALUE__NUMBER;
pub const LXB_CSS_OPACITY__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;

pub const lxb_css_opacity_type_t = c_uint;

pub const LXB_CSS_ORDER__INTEGER = LXB_CSS_VALUE__INTEGER;

pub const lxb_css_order_type_t = c_uint;

pub const LXB_CSS_OVERFLOW_BLOCK_VISIBLE = LXB_CSS_VALUE_VISIBLE;
pub const LXB_CSS_OVERFLOW_BLOCK_HIDDEN = LXB_CSS_VALUE_HIDDEN;
pub const LXB_CSS_OVERFLOW_BLOCK_CLIP = LXB_CSS_VALUE_CLIP;
pub const LXB_CSS_OVERFLOW_BLOCK_SCROLL = LXB_CSS_VALUE_SCROLL;
pub const LXB_CSS_OVERFLOW_BLOCK_AUTO = LXB_CSS_VALUE_AUTO;

pub const lxb_css_overflow_block_type_t = c_uint;

pub const LXB_CSS_OVERFLOW_INLINE_VISIBLE = LXB_CSS_VALUE_VISIBLE;
pub const LXB_CSS_OVERFLOW_INLINE_HIDDEN = LXB_CSS_VALUE_HIDDEN;
pub const LXB_CSS_OVERFLOW_INLINE_CLIP = LXB_CSS_VALUE_CLIP;
pub const LXB_CSS_OVERFLOW_INLINE_SCROLL = LXB_CSS_VALUE_SCROLL;
pub const LXB_CSS_OVERFLOW_INLINE_AUTO = LXB_CSS_VALUE_AUTO;

pub const lxb_css_overflow_inline_type_t = c_uint;

pub const LXB_CSS_OVERFLOW_WRAP_NORMAL = LXB_CSS_VALUE_NORMAL;
pub const LXB_CSS_OVERFLOW_WRAP_BREAK_WORD = LXB_CSS_VALUE_BREAK_WORD;
pub const LXB_CSS_OVERFLOW_WRAP_ANYWHERE = LXB_CSS_VALUE_ANYWHERE;

pub const lxb_css_overflow_wrap_type_t = c_uint;

pub const LXB_CSS_OVERFLOW_X_VISIBLE = LXB_CSS_VALUE_VISIBLE;
pub const LXB_CSS_OVERFLOW_X_HIDDEN = LXB_CSS_VALUE_HIDDEN;
pub const LXB_CSS_OVERFLOW_X_CLIP = LXB_CSS_VALUE_CLIP;
pub const LXB_CSS_OVERFLOW_X_SCROLL = LXB_CSS_VALUE_SCROLL;
pub const LXB_CSS_OVERFLOW_X_AUTO = LXB_CSS_VALUE_AUTO;

pub const lxb_css_overflow_x_type_t = c_uint;

pub const LXB_CSS_OVERFLOW_Y_VISIBLE = LXB_CSS_VALUE_VISIBLE;
pub const LXB_CSS_OVERFLOW_Y_HIDDEN = LXB_CSS_VALUE_HIDDEN;
pub const LXB_CSS_OVERFLOW_Y_CLIP = LXB_CSS_VALUE_CLIP;
pub const LXB_CSS_OVERFLOW_Y_SCROLL = LXB_CSS_VALUE_SCROLL;
pub const LXB_CSS_OVERFLOW_Y_AUTO = LXB_CSS_VALUE_AUTO;

pub const lxb_css_overflow_y_type_t = c_uint;

pub const LXB_CSS_PADDING_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_PADDING__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_PADDING__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;

pub const lxb_css_padding_type_t = c_uint;

pub const LXB_CSS_PADDING_BOTTOM_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_PADDING_BOTTOM__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_PADDING_BOTTOM__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;

pub const lxb_css_padding_bottom_type_t = c_uint;

pub const LXB_CSS_PADDING_LEFT_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_PADDING_LEFT__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_PADDING_LEFT__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;

pub const lxb_css_padding_left_type_t = c_uint;

pub const LXB_CSS_PADDING_RIGHT_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_PADDING_RIGHT__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_PADDING_RIGHT__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;

pub const lxb_css_padding_right_type_t = c_uint;

pub const LXB_CSS_PADDING_TOP_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_PADDING_TOP__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_PADDING_TOP__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;

pub const lxb_css_padding_top_type_t = c_uint;

pub const LXB_CSS_POSITION_STATIC = LXB_CSS_VALUE_STATIC;
pub const LXB_CSS_POSITION_RELATIVE = LXB_CSS_VALUE_RELATIVE;
pub const LXB_CSS_POSITION_ABSOLUTE = LXB_CSS_VALUE_ABSOLUTE;
pub const LXB_CSS_POSITION_STICKY = LXB_CSS_VALUE_STICKY;
pub const LXB_CSS_POSITION_FIXED = LXB_CSS_VALUE_FIXED;

pub const lxb_css_position_type_t = c_uint;

pub const LXB_CSS_RIGHT_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_RIGHT__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_RIGHT__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;

pub const lxb_css_right_type_t = c_uint;

pub const LXB_CSS_TAB_SIZE__NUMBER = LXB_CSS_VALUE__NUMBER;
pub const LXB_CSS_TAB_SIZE__LENGTH = LXB_CSS_VALUE__LENGTH;

pub const lxb_css_tab_size_type_t = c_uint;

pub const LXB_CSS_TEXT_ALIGN_START = LXB_CSS_VALUE_START;
pub const LXB_CSS_TEXT_ALIGN_END = LXB_CSS_VALUE_END;
pub const LXB_CSS_TEXT_ALIGN_LEFT = LXB_CSS_VALUE_LEFT;
pub const LXB_CSS_TEXT_ALIGN_RIGHT = LXB_CSS_VALUE_RIGHT;
pub const LXB_CSS_TEXT_ALIGN_CENTER = LXB_CSS_VALUE_CENTER;
pub const LXB_CSS_TEXT_ALIGN_JUSTIFY = LXB_CSS_VALUE_JUSTIFY;
pub const LXB_CSS_TEXT_ALIGN_MATCH_PARENT = LXB_CSS_VALUE_MATCH_PARENT;
pub const LXB_CSS_TEXT_ALIGN_JUSTIFY_ALL = LXB_CSS_VALUE_JUSTIFY_ALL;

pub const lxb_css_text_align_type_t = c_uint;

pub const LXB_CSS_TEXT_ALIGN_ALL_START = LXB_CSS_VALUE_START;
pub const LXB_CSS_TEXT_ALIGN_ALL_END = LXB_CSS_VALUE_END;
pub const LXB_CSS_TEXT_ALIGN_ALL_LEFT = LXB_CSS_VALUE_LEFT;
pub const LXB_CSS_TEXT_ALIGN_ALL_RIGHT = LXB_CSS_VALUE_RIGHT;
pub const LXB_CSS_TEXT_ALIGN_ALL_CENTER = LXB_CSS_VALUE_CENTER;
pub const LXB_CSS_TEXT_ALIGN_ALL_JUSTIFY = LXB_CSS_VALUE_JUSTIFY;
pub const LXB_CSS_TEXT_ALIGN_ALL_MATCH_PARENT = LXB_CSS_VALUE_MATCH_PARENT;

pub const lxb_css_text_align_all_type_t = c_uint;

pub const LXB_CSS_TEXT_ALIGN_LAST_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_TEXT_ALIGN_LAST_START = LXB_CSS_VALUE_START;
pub const LXB_CSS_TEXT_ALIGN_LAST_END = LXB_CSS_VALUE_END;
pub const LXB_CSS_TEXT_ALIGN_LAST_LEFT = LXB_CSS_VALUE_LEFT;
pub const LXB_CSS_TEXT_ALIGN_LAST_RIGHT = LXB_CSS_VALUE_RIGHT;
pub const LXB_CSS_TEXT_ALIGN_LAST_CENTER = LXB_CSS_VALUE_CENTER;
pub const LXB_CSS_TEXT_ALIGN_LAST_JUSTIFY = LXB_CSS_VALUE_JUSTIFY;
pub const LXB_CSS_TEXT_ALIGN_LAST_MATCH_PARENT = LXB_CSS_VALUE_MATCH_PARENT;

pub const lxb_css_text_align_last_type_t = c_uint;

pub const LXB_CSS_TEXT_COMBINE_UPRIGHT_NONE = LXB_CSS_VALUE_NONE;
pub const LXB_CSS_TEXT_COMBINE_UPRIGHT_ALL = LXB_CSS_VALUE_ALL;
pub const LXB_CSS_TEXT_COMBINE_UPRIGHT_DIGITS = LXB_CSS_VALUE_DIGITS;

pub const lxb_css_text_combine_upright_type_t = c_uint;

pub const LXB_CSS_TEXT_DECORATION_LINE_NONE = LXB_CSS_VALUE_NONE;
pub const LXB_CSS_TEXT_DECORATION_LINE_UNDERLINE = LXB_CSS_VALUE_UNDERLINE;
pub const LXB_CSS_TEXT_DECORATION_LINE_OVERLINE = LXB_CSS_VALUE_OVERLINE;
pub const LXB_CSS_TEXT_DECORATION_LINE_LINE_THROUGH = LXB_CSS_VALUE_LINE_THROUGH;
pub const LXB_CSS_TEXT_DECORATION_LINE_BLINK = LXB_CSS_VALUE_BLINK;

pub const lxb_css_text_decoration_line_type_t = c_uint;

pub const LXB_CSS_TEXT_DECORATION_STYLE_SOLID = LXB_CSS_VALUE_SOLID;
pub const LXB_CSS_TEXT_DECORATION_STYLE_DOUBLE = LXB_CSS_VALUE_DOUBLE;
pub const LXB_CSS_TEXT_DECORATION_STYLE_DOTTED = LXB_CSS_VALUE_DOTTED;
pub const LXB_CSS_TEXT_DECORATION_STYLE_DASHED = LXB_CSS_VALUE_DASHED;
pub const LXB_CSS_TEXT_DECORATION_STYLE_WAVY = LXB_CSS_VALUE_WAVY;

pub const lxb_css_text_decoration_style_type_t = c_uint;

pub const LXB_CSS_TEXT_INDENT__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_TEXT_INDENT__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;
pub const LXB_CSS_TEXT_INDENT_HANGING = LXB_CSS_VALUE_HANGING;
pub const LXB_CSS_TEXT_INDENT_EACH_LINE = LXB_CSS_VALUE_EACH_LINE;

pub const lxb_css_text_indent_type_t = c_uint;

pub const LXB_CSS_TEXT_JUSTIFY_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_TEXT_JUSTIFY_NONE = LXB_CSS_VALUE_NONE;
pub const LXB_CSS_TEXT_JUSTIFY_INTER_WORD = LXB_CSS_VALUE_INTER_WORD;
pub const LXB_CSS_TEXT_JUSTIFY_INTER_CHARACTER = LXB_CSS_VALUE_INTER_CHARACTER;

pub const lxb_css_text_justify_type_t = c_uint;

pub const LXB_CSS_TEXT_ORIENTATION_MIXED = LXB_CSS_VALUE_MIXED;
pub const LXB_CSS_TEXT_ORIENTATION_UPRIGHT = LXB_CSS_VALUE_UPRIGHT;
pub const LXB_CSS_TEXT_ORIENTATION_SIDEWAYS = LXB_CSS_VALUE_SIDEWAYS;

pub const lxb_css_text_orientation_type_t = c_uint;

pub const LXB_CSS_TEXT_OVERFLOW_CLIP = LXB_CSS_VALUE_CLIP;
pub const LXB_CSS_TEXT_OVERFLOW_ELLIPSIS = LXB_CSS_VALUE_ELLIPSIS;

pub const lxb_css_text_overflow_type_t = c_uint;

pub const LXB_CSS_TEXT_TRANSFORM_NONE = LXB_CSS_VALUE_NONE;
pub const LXB_CSS_TEXT_TRANSFORM_CAPITALIZE = LXB_CSS_VALUE_CAPITALIZE;
pub const LXB_CSS_TEXT_TRANSFORM_UPPERCASE = LXB_CSS_VALUE_UPPERCASE;
pub const LXB_CSS_TEXT_TRANSFORM_LOWERCASE = LXB_CSS_VALUE_LOWERCASE;
pub const LXB_CSS_TEXT_TRANSFORM_FULL_WIDTH = LXB_CSS_VALUE_FULL_WIDTH;
pub const LXB_CSS_TEXT_TRANSFORM_FULL_SIZE_KANA = LXB_CSS_VALUE_FULL_SIZE_KANA;

pub const lxb_css_text_transform_type_t = c_uint;

pub const LXB_CSS_TOP_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_TOP__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_TOP__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;

pub const lxb_css_top_type_t = c_uint;

pub const LXB_CSS_UNICODE_BIDI_NORMAL = LXB_CSS_VALUE_NORMAL;
pub const LXB_CSS_UNICODE_BIDI_EMBED = LXB_CSS_VALUE_EMBED;
pub const LXB_CSS_UNICODE_BIDI_ISOLATE = LXB_CSS_VALUE_ISOLATE;
pub const LXB_CSS_UNICODE_BIDI_BIDI_OVERRIDE = LXB_CSS_VALUE_BIDI_OVERRIDE;
pub const LXB_CSS_UNICODE_BIDI_ISOLATE_OVERRIDE = LXB_CSS_VALUE_ISOLATE_OVERRIDE;
pub const LXB_CSS_UNICODE_BIDI_PLAINTEXT = LXB_CSS_VALUE_PLAINTEXT;

pub const lxb_css_unicode_bidi_type_t = c_uint;

pub const LXB_CSS_VERTICAL_ALIGN_FIRST = LXB_CSS_VALUE_FIRST;
pub const LXB_CSS_VERTICAL_ALIGN_LAST = LXB_CSS_VALUE_LAST;

pub const lxb_css_vertical_align_type_t = c_uint;

pub const LXB_CSS_VISIBILITY_VISIBLE = LXB_CSS_VALUE_VISIBLE;
pub const LXB_CSS_VISIBILITY_HIDDEN = LXB_CSS_VALUE_HIDDEN;
pub const LXB_CSS_VISIBILITY_COLLAPSE = LXB_CSS_VALUE_COLLAPSE;

pub const lxb_css_visibility_type_t = c_uint;

pub const LXB_CSS_WHITE_SPACE_NORMAL = LXB_CSS_VALUE_NORMAL;
pub const LXB_CSS_WHITE_SPACE_PRE = LXB_CSS_VALUE_PRE;
pub const LXB_CSS_WHITE_SPACE_NOWRAP = LXB_CSS_VALUE_NOWRAP;
pub const LXB_CSS_WHITE_SPACE_PRE_WRAP = LXB_CSS_VALUE_PRE_WRAP;
pub const LXB_CSS_WHITE_SPACE_BREAK_SPACES = LXB_CSS_VALUE_BREAK_SPACES;
pub const LXB_CSS_WHITE_SPACE_PRE_LINE = LXB_CSS_VALUE_PRE_LINE;

pub const lxb_css_white_space_type_t = c_uint;

pub const LXB_CSS_WIDTH_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_WIDTH_MIN_CONTENT = LXB_CSS_VALUE_MIN_CONTENT;
pub const LXB_CSS_WIDTH_MAX_CONTENT = LXB_CSS_VALUE_MAX_CONTENT;
pub const LXB_CSS_WIDTH__LENGTH = LXB_CSS_VALUE__LENGTH;
pub const LXB_CSS_WIDTH__PERCENTAGE = LXB_CSS_VALUE__PERCENTAGE;
pub const LXB_CSS_WIDTH__NUMBER = LXB_CSS_VALUE__NUMBER;
pub const LXB_CSS_WIDTH__ANGLE = LXB_CSS_VALUE__ANGLE;

pub const lxb_css_width_type_t = c_uint;

pub const LXB_CSS_WORD_BREAK_NORMAL = LXB_CSS_VALUE_NORMAL;
pub const LXB_CSS_WORD_BREAK_KEEP_ALL = LXB_CSS_VALUE_KEEP_ALL;
pub const LXB_CSS_WORD_BREAK_BREAK_ALL = LXB_CSS_VALUE_BREAK_ALL;
pub const LXB_CSS_WORD_BREAK_BREAK_WORD = LXB_CSS_VALUE_BREAK_WORD;

pub const lxb_css_word_break_type_t = c_uint;

pub const LXB_CSS_WORD_SPACING_NORMAL = LXB_CSS_VALUE_NORMAL;
pub const LXB_CSS_WORD_SPACING__LENGTH = LXB_CSS_VALUE__LENGTH;

pub const lxb_css_word_spacing_type_t = c_uint;

pub const LXB_CSS_WORD_WRAP_NORMAL = LXB_CSS_VALUE_NORMAL;
pub const LXB_CSS_WORD_WRAP_BREAK_WORD = LXB_CSS_VALUE_BREAK_WORD;
pub const LXB_CSS_WORD_WRAP_ANYWHERE = LXB_CSS_VALUE_ANYWHERE;

pub const lxb_css_word_wrap_type_t = c_uint;

pub const LXB_CSS_WRAP_FLOW_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_WRAP_FLOW_BOTH = LXB_CSS_VALUE_BOTH;
pub const LXB_CSS_WRAP_FLOW_START = LXB_CSS_VALUE_START;
pub const LXB_CSS_WRAP_FLOW_END = LXB_CSS_VALUE_END;
pub const LXB_CSS_WRAP_FLOW_MINIMUM = LXB_CSS_VALUE_MINIMUM;
pub const LXB_CSS_WRAP_FLOW_MAXIMUM = LXB_CSS_VALUE_MAXIMUM;
pub const LXB_CSS_WRAP_FLOW_CLEAR = LXB_CSS_VALUE_CLEAR;

pub const lxb_css_wrap_flow_type_t = c_uint;

pub const LXB_CSS_WRAP_THROUGH_WRAP = LXB_CSS_VALUE_WRAP;
pub const LXB_CSS_WRAP_THROUGH_NONE = LXB_CSS_VALUE_NONE;

pub const lxb_css_wrap_through_type_t = c_uint;

pub const LXB_CSS_WRITING_MODE_HORIZONTAL_TB = LXB_CSS_VALUE_HORIZONTAL_TB;
pub const LXB_CSS_WRITING_MODE_VERTICAL_RL = LXB_CSS_VALUE_VERTICAL_RL;
pub const LXB_CSS_WRITING_MODE_VERTICAL_LR = LXB_CSS_VALUE_VERTICAL_LR;
pub const LXB_CSS_WRITING_MODE_SIDEWAYS_RL = LXB_CSS_VALUE_SIDEWAYS_RL;
pub const LXB_CSS_WRITING_MODE_SIDEWAYS_LR = LXB_CSS_VALUE_SIDEWAYS_LR;

pub const lxb_css_writing_mode_type_t = c_uint;

pub const LXB_CSS_Z_INDEX_AUTO = LXB_CSS_VALUE_AUTO;
pub const LXB_CSS_Z_INDEX__INTEGER = LXB_CSS_VALUE__INTEGER;

pub const lxb_css_z_index_type_t = c_uint;

// css/value/const.h

pub const LXB_CSS_VALUE__UNDEF = 0x0000;
pub const LXB_CSS_VALUE_INITIAL = 0x0001;
pub const LXB_CSS_VALUE_INHERIT = 0x0002;
pub const LXB_CSS_VALUE_UNSET = 0x0003;
pub const LXB_CSS_VALUE_REVERT = 0x0004;
pub const LXB_CSS_VALUE_FLEX_START = 0x0005;
pub const LXB_CSS_VALUE_FLEX_END = 0x0006;
pub const LXB_CSS_VALUE_CENTER = 0x0007;
pub const LXB_CSS_VALUE_SPACE_BETWEEN = 0x0008;
pub const LXB_CSS_VALUE_SPACE_AROUND = 0x0009;
pub const LXB_CSS_VALUE_STRETCH = 0x000a;
pub const LXB_CSS_VALUE_BASELINE = 0x000b;
pub const LXB_CSS_VALUE_AUTO = 0x000c;
pub const LXB_CSS_VALUE_TEXT_BOTTOM = 0x000d;
pub const LXB_CSS_VALUE_ALPHABETIC = 0x000e;
pub const LXB_CSS_VALUE_IDEOGRAPHIC = 0x000f;
pub const LXB_CSS_VALUE_MIDDLE = 0x0010;
pub const LXB_CSS_VALUE_CENTRAL = 0x0011;
pub const LXB_CSS_VALUE_MATHEMATICAL = 0x0012;
pub const LXB_CSS_VALUE_TEXT_TOP = 0x0013;
pub const LXB_CSS_VALUE__LENGTH = 0x0014;
pub const LXB_CSS_VALUE__PERCENTAGE = 0x0015;
pub const LXB_CSS_VALUE_SUB = 0x0016;
pub const LXB_CSS_VALUE_SUPER = 0x0017;
pub const LXB_CSS_VALUE_TOP = 0x0018;
pub const LXB_CSS_VALUE_BOTTOM = 0x0019;
pub const LXB_CSS_VALUE_FIRST = 0x001a;
pub const LXB_CSS_VALUE_LAST = 0x001b;
pub const LXB_CSS_VALUE_THIN = 0x001c;
pub const LXB_CSS_VALUE_MEDIUM = 0x001d;
pub const LXB_CSS_VALUE_THICK = 0x001e;
pub const LXB_CSS_VALUE_NONE = 0x001f;
pub const LXB_CSS_VALUE_HIDDEN = 0x0020;
pub const LXB_CSS_VALUE_DOTTED = 0x0021;
pub const LXB_CSS_VALUE_DASHED = 0x0022;
pub const LXB_CSS_VALUE_SOLID = 0x0023;
pub const LXB_CSS_VALUE_DOUBLE = 0x0024;
pub const LXB_CSS_VALUE_GROOVE = 0x0025;
pub const LXB_CSS_VALUE_RIDGE = 0x0026;
pub const LXB_CSS_VALUE_INSET = 0x0027;
pub const LXB_CSS_VALUE_OUTSET = 0x0028;
pub const LXB_CSS_VALUE_CONTENT_BOX = 0x0029;
pub const LXB_CSS_VALUE_BORDER_BOX = 0x002a;
pub const LXB_CSS_VALUE_INLINE_START = 0x002b;
pub const LXB_CSS_VALUE_INLINE_END = 0x002c;
pub const LXB_CSS_VALUE_BLOCK_START = 0x002d;
pub const LXB_CSS_VALUE_BLOCK_END = 0x002e;
pub const LXB_CSS_VALUE_LEFT = 0x002f;
pub const LXB_CSS_VALUE_RIGHT = 0x0030;
pub const LXB_CSS_VALUE_CURRENTCOLOR = 0x0031;
pub const LXB_CSS_VALUE_TRANSPARENT = 0x0032;
pub const LXB_CSS_VALUE_HEX = 0x0033;
pub const LXB_CSS_VALUE_ALICEBLUE = 0x0034;
pub const LXB_CSS_VALUE_ANTIQUEWHITE = 0x0035;
pub const LXB_CSS_VALUE_AQUA = 0x0036;
pub const LXB_CSS_VALUE_AQUAMARINE = 0x0037;
pub const LXB_CSS_VALUE_AZURE = 0x0038;
pub const LXB_CSS_VALUE_BEIGE = 0x0039;
pub const LXB_CSS_VALUE_BISQUE = 0x003a;
pub const LXB_CSS_VALUE_BLACK = 0x003b;
pub const LXB_CSS_VALUE_BLANCHEDALMOND = 0x003c;
pub const LXB_CSS_VALUE_BLUE = 0x003d;
pub const LXB_CSS_VALUE_BLUEVIOLET = 0x003e;
pub const LXB_CSS_VALUE_BROWN = 0x003f;
pub const LXB_CSS_VALUE_BURLYWOOD = 0x0040;
pub const LXB_CSS_VALUE_CADETBLUE = 0x0041;
pub const LXB_CSS_VALUE_CHARTREUSE = 0x0042;
pub const LXB_CSS_VALUE_CHOCOLATE = 0x0043;
pub const LXB_CSS_VALUE_CORAL = 0x0044;
pub const LXB_CSS_VALUE_CORNFLOWERBLUE = 0x0045;
pub const LXB_CSS_VALUE_CORNSILK = 0x0046;
pub const LXB_CSS_VALUE_CRIMSON = 0x0047;
pub const LXB_CSS_VALUE_CYAN = 0x0048;
pub const LXB_CSS_VALUE_DARKBLUE = 0x0049;
pub const LXB_CSS_VALUE_DARKCYAN = 0x004a;
pub const LXB_CSS_VALUE_DARKGOLDENROD = 0x004b;
pub const LXB_CSS_VALUE_DARKGRAY = 0x004c;
pub const LXB_CSS_VALUE_DARKGREEN = 0x004d;
pub const LXB_CSS_VALUE_DARKGREY = 0x004e;
pub const LXB_CSS_VALUE_DARKKHAKI = 0x004f;
pub const LXB_CSS_VALUE_DARKMAGENTA = 0x0050;
pub const LXB_CSS_VALUE_DARKOLIVEGREEN = 0x0051;
pub const LXB_CSS_VALUE_DARKORANGE = 0x0052;
pub const LXB_CSS_VALUE_DARKORCHID = 0x0053;
pub const LXB_CSS_VALUE_DARKRED = 0x0054;
pub const LXB_CSS_VALUE_DARKSALMON = 0x0055;
pub const LXB_CSS_VALUE_DARKSEAGREEN = 0x0056;
pub const LXB_CSS_VALUE_DARKSLATEBLUE = 0x0057;
pub const LXB_CSS_VALUE_DARKSLATEGRAY = 0x0058;
pub const LXB_CSS_VALUE_DARKSLATEGREY = 0x0059;
pub const LXB_CSS_VALUE_DARKTURQUOISE = 0x005a;
pub const LXB_CSS_VALUE_DARKVIOLET = 0x005b;
pub const LXB_CSS_VALUE_DEEPPINK = 0x005c;
pub const LXB_CSS_VALUE_DEEPSKYBLUE = 0x005d;
pub const LXB_CSS_VALUE_DIMGRAY = 0x005e;
pub const LXB_CSS_VALUE_DIMGREY = 0x005f;
pub const LXB_CSS_VALUE_DODGERBLUE = 0x0060;
pub const LXB_CSS_VALUE_FIREBRICK = 0x0061;
pub const LXB_CSS_VALUE_FLORALWHITE = 0x0062;
pub const LXB_CSS_VALUE_FORESTGREEN = 0x0063;
pub const LXB_CSS_VALUE_FUCHSIA = 0x0064;
pub const LXB_CSS_VALUE_GAINSBORO = 0x0065;
pub const LXB_CSS_VALUE_GHOSTWHITE = 0x0066;
pub const LXB_CSS_VALUE_GOLD = 0x0067;
pub const LXB_CSS_VALUE_GOLDENROD = 0x0068;
pub const LXB_CSS_VALUE_GRAY = 0x0069;
pub const LXB_CSS_VALUE_GREEN = 0x006a;
pub const LXB_CSS_VALUE_GREENYELLOW = 0x006b;
pub const LXB_CSS_VALUE_GREY = 0x006c;
pub const LXB_CSS_VALUE_HONEYDEW = 0x006d;
pub const LXB_CSS_VALUE_HOTPINK = 0x006e;
pub const LXB_CSS_VALUE_INDIANRED = 0x006f;
pub const LXB_CSS_VALUE_INDIGO = 0x0070;
pub const LXB_CSS_VALUE_IVORY = 0x0071;
pub const LXB_CSS_VALUE_KHAKI = 0x0072;
pub const LXB_CSS_VALUE_LAVENDER = 0x0073;
pub const LXB_CSS_VALUE_LAVENDERBLUSH = 0x0074;
pub const LXB_CSS_VALUE_LAWNGREEN = 0x0075;
pub const LXB_CSS_VALUE_LEMONCHIFFON = 0x0076;
pub const LXB_CSS_VALUE_LIGHTBLUE = 0x0077;
pub const LXB_CSS_VALUE_LIGHTCORAL = 0x0078;
pub const LXB_CSS_VALUE_LIGHTCYAN = 0x0079;
pub const LXB_CSS_VALUE_LIGHTGOLDENRODYELLOW = 0x007a;
pub const LXB_CSS_VALUE_LIGHTGRAY = 0x007b;
pub const LXB_CSS_VALUE_LIGHTGREEN = 0x007c;
pub const LXB_CSS_VALUE_LIGHTGREY = 0x007d;
pub const LXB_CSS_VALUE_LIGHTPINK = 0x007e;
pub const LXB_CSS_VALUE_LIGHTSALMON = 0x007f;
pub const LXB_CSS_VALUE_LIGHTSEAGREEN = 0x0080;
pub const LXB_CSS_VALUE_LIGHTSKYBLUE = 0x0081;
pub const LXB_CSS_VALUE_LIGHTSLATEGRAY = 0x0082;
pub const LXB_CSS_VALUE_LIGHTSLATEGREY = 0x0083;
pub const LXB_CSS_VALUE_LIGHTSTEELBLUE = 0x0084;
pub const LXB_CSS_VALUE_LIGHTYELLOW = 0x0085;
pub const LXB_CSS_VALUE_LIME = 0x0086;
pub const LXB_CSS_VALUE_LIMEGREEN = 0x0087;
pub const LXB_CSS_VALUE_LINEN = 0x0088;
pub const LXB_CSS_VALUE_MAGENTA = 0x0089;
pub const LXB_CSS_VALUE_MAROON = 0x008a;
pub const LXB_CSS_VALUE_MEDIUMAQUAMARINE = 0x008b;
pub const LXB_CSS_VALUE_MEDIUMBLUE = 0x008c;
pub const LXB_CSS_VALUE_MEDIUMORCHID = 0x008d;
pub const LXB_CSS_VALUE_MEDIUMPURPLE = 0x008e;
pub const LXB_CSS_VALUE_MEDIUMSEAGREEN = 0x008f;
pub const LXB_CSS_VALUE_MEDIUMSLATEBLUE = 0x0090;
pub const LXB_CSS_VALUE_MEDIUMSPRINGGREEN = 0x0091;
pub const LXB_CSS_VALUE_MEDIUMTURQUOISE = 0x0092;
pub const LXB_CSS_VALUE_MEDIUMVIOLETRED = 0x0093;
pub const LXB_CSS_VALUE_MIDNIGHTBLUE = 0x0094;
pub const LXB_CSS_VALUE_MINTCREAM = 0x0095;
pub const LXB_CSS_VALUE_MISTYROSE = 0x0096;
pub const LXB_CSS_VALUE_MOCCASIN = 0x0097;
pub const LXB_CSS_VALUE_NAVAJOWHITE = 0x0098;
pub const LXB_CSS_VALUE_NAVY = 0x0099;
pub const LXB_CSS_VALUE_OLDLACE = 0x009a;
pub const LXB_CSS_VALUE_OLIVE = 0x009b;
pub const LXB_CSS_VALUE_OLIVEDRAB = 0x009c;
pub const LXB_CSS_VALUE_ORANGE = 0x009d;
pub const LXB_CSS_VALUE_ORANGERED = 0x009e;
pub const LXB_CSS_VALUE_ORCHID = 0x009f;
pub const LXB_CSS_VALUE_PALEGOLDENROD = 0x00a0;
pub const LXB_CSS_VALUE_PALEGREEN = 0x00a1;
pub const LXB_CSS_VALUE_PALETURQUOISE = 0x00a2;
pub const LXB_CSS_VALUE_PALEVIOLETRED = 0x00a3;
pub const LXB_CSS_VALUE_PAPAYAWHIP = 0x00a4;
pub const LXB_CSS_VALUE_PEACHPUFF = 0x00a5;
pub const LXB_CSS_VALUE_PERU = 0x00a6;
pub const LXB_CSS_VALUE_PINK = 0x00a7;
pub const LXB_CSS_VALUE_PLUM = 0x00a8;
pub const LXB_CSS_VALUE_POWDERBLUE = 0x00a9;
pub const LXB_CSS_VALUE_PURPLE = 0x00aa;
pub const LXB_CSS_VALUE_REBECCAPURPLE = 0x00ab;
pub const LXB_CSS_VALUE_RED = 0x00ac;
pub const LXB_CSS_VALUE_ROSYBROWN = 0x00ad;
pub const LXB_CSS_VALUE_ROYALBLUE = 0x00ae;
pub const LXB_CSS_VALUE_SADDLEBROWN = 0x00af;
pub const LXB_CSS_VALUE_SALMON = 0x00b0;
pub const LXB_CSS_VALUE_SANDYBROWN = 0x00b1;
pub const LXB_CSS_VALUE_SEAGREEN = 0x00b2;
pub const LXB_CSS_VALUE_SEASHELL = 0x00b3;
pub const LXB_CSS_VALUE_SIENNA = 0x00b4;
pub const LXB_CSS_VALUE_SILVER = 0x00b5;
pub const LXB_CSS_VALUE_SKYBLUE = 0x00b6;
pub const LXB_CSS_VALUE_SLATEBLUE = 0x00b7;
pub const LXB_CSS_VALUE_SLATEGRAY = 0x00b8;
pub const LXB_CSS_VALUE_SLATEGREY = 0x00b9;
pub const LXB_CSS_VALUE_SNOW = 0x00ba;
pub const LXB_CSS_VALUE_SPRINGGREEN = 0x00bb;
pub const LXB_CSS_VALUE_STEELBLUE = 0x00bc;
pub const LXB_CSS_VALUE_TAN = 0x00bd;
pub const LXB_CSS_VALUE_TEAL = 0x00be;
pub const LXB_CSS_VALUE_THISTLE = 0x00bf;
pub const LXB_CSS_VALUE_TOMATO = 0x00c0;
pub const LXB_CSS_VALUE_TURQUOISE = 0x00c1;
pub const LXB_CSS_VALUE_VIOLET = 0x00c2;
pub const LXB_CSS_VALUE_WHEAT = 0x00c3;
pub const LXB_CSS_VALUE_WHITE = 0x00c4;
pub const LXB_CSS_VALUE_WHITESMOKE = 0x00c5;
pub const LXB_CSS_VALUE_YELLOW = 0x00c6;
pub const LXB_CSS_VALUE_YELLOWGREEN = 0x00c7;
pub const LXB_CSS_VALUE_CANVAS = 0x00c8;
pub const LXB_CSS_VALUE_CANVASTEXT = 0x00c9;
pub const LXB_CSS_VALUE_LINKTEXT = 0x00ca;
pub const LXB_CSS_VALUE_VISITEDTEXT = 0x00cb;
pub const LXB_CSS_VALUE_ACTIVETEXT = 0x00cc;
pub const LXB_CSS_VALUE_BUTTONFACE = 0x00cd;
pub const LXB_CSS_VALUE_BUTTONTEXT = 0x00ce;
pub const LXB_CSS_VALUE_BUTTONBORDER = 0x00cf;
pub const LXB_CSS_VALUE_FIELD = 0x00d0;
pub const LXB_CSS_VALUE_FIELDTEXT = 0x00d1;
pub const LXB_CSS_VALUE_HIGHLIGHT = 0x00d2;
pub const LXB_CSS_VALUE_HIGHLIGHTTEXT = 0x00d3;
pub const LXB_CSS_VALUE_SELECTEDITEM = 0x00d4;
pub const LXB_CSS_VALUE_SELECTEDITEMTEXT = 0x00d5;
pub const LXB_CSS_VALUE_MARK = 0x00d6;
pub const LXB_CSS_VALUE_MARKTEXT = 0x00d7;
pub const LXB_CSS_VALUE_GRAYTEXT = 0x00d8;
pub const LXB_CSS_VALUE_ACCENTCOLOR = 0x00d9;
pub const LXB_CSS_VALUE_ACCENTCOLORTEXT = 0x00da;
pub const LXB_CSS_VALUE_RGB = 0x00db;
pub const LXB_CSS_VALUE_RGBA = 0x00dc;
pub const LXB_CSS_VALUE_HSL = 0x00dd;
pub const LXB_CSS_VALUE_HSLA = 0x00de;
pub const LXB_CSS_VALUE_HWB = 0x00df;
pub const LXB_CSS_VALUE_LAB = 0x00e0;
pub const LXB_CSS_VALUE_LCH = 0x00e1;
pub const LXB_CSS_VALUE_OKLAB = 0x00e2;
pub const LXB_CSS_VALUE_OKLCH = 0x00e3;
pub const LXB_CSS_VALUE_COLOR = 0x00e4;
pub const LXB_CSS_VALUE_LTR = 0x00e5;
pub const LXB_CSS_VALUE_RTL = 0x00e6;
pub const LXB_CSS_VALUE_BLOCK = 0x00e7;
pub const LXB_CSS_VALUE_INLINE = 0x00e8;
pub const LXB_CSS_VALUE_RUN_IN = 0x00e9;
pub const LXB_CSS_VALUE_FLOW = 0x00ea;
pub const LXB_CSS_VALUE_FLOW_ROOT = 0x00eb;
pub const LXB_CSS_VALUE_TABLE = 0x00ec;
pub const LXB_CSS_VALUE_FLEX = 0x00ed;
pub const LXB_CSS_VALUE_GRID = 0x00ee;
pub const LXB_CSS_VALUE_RUBY = 0x00ef;
pub const LXB_CSS_VALUE_LIST_ITEM = 0x00f0;
pub const LXB_CSS_VALUE_TABLE_ROW_GROUP = 0x00f1;
pub const LXB_CSS_VALUE_TABLE_HEADER_GROUP = 0x00f2;
pub const LXB_CSS_VALUE_TABLE_FOOTER_GROUP = 0x00f3;
pub const LXB_CSS_VALUE_TABLE_ROW = 0x00f4;
pub const LXB_CSS_VALUE_TABLE_CELL = 0x00f5;
pub const LXB_CSS_VALUE_TABLE_COLUMN_GROUP = 0x00f6;
pub const LXB_CSS_VALUE_TABLE_COLUMN = 0x00f7;
pub const LXB_CSS_VALUE_TABLE_CAPTION = 0x00f8;
pub const LXB_CSS_VALUE_RUBY_BASE = 0x00f9;
pub const LXB_CSS_VALUE_RUBY_TEXT = 0x00fa;
pub const LXB_CSS_VALUE_RUBY_BASE_CONTAINER = 0x00fb;
pub const LXB_CSS_VALUE_RUBY_TEXT_CONTAINER = 0x00fc;
pub const LXB_CSS_VALUE_CONTENTS = 0x00fd;
pub const LXB_CSS_VALUE_INLINE_BLOCK = 0x00fe;
pub const LXB_CSS_VALUE_INLINE_TABLE = 0x00ff;
pub const LXB_CSS_VALUE_INLINE_FLEX = 0x0100;
pub const LXB_CSS_VALUE_INLINE_GRID = 0x0101;
pub const LXB_CSS_VALUE_HANGING = 0x0102;
pub const LXB_CSS_VALUE_CONTENT = 0x0103;
pub const LXB_CSS_VALUE_ROW = 0x0104;
pub const LXB_CSS_VALUE_ROW_REVERSE = 0x0105;
pub const LXB_CSS_VALUE_COLUMN = 0x0106;
pub const LXB_CSS_VALUE_COLUMN_REVERSE = 0x0107;
pub const LXB_CSS_VALUE__NUMBER = 0x0108;
pub const LXB_CSS_VALUE_NOWRAP = 0x0109;
pub const LXB_CSS_VALUE_WRAP = 0x010a;
pub const LXB_CSS_VALUE_WRAP_REVERSE = 0x010b;
pub const LXB_CSS_VALUE_SNAP_BLOCK = 0x010c;
pub const LXB_CSS_VALUE_START = 0x010d;
pub const LXB_CSS_VALUE_END = 0x010e;
pub const LXB_CSS_VALUE_NEAR = 0x010f;
pub const LXB_CSS_VALUE_SNAP_INLINE = 0x0110;
pub const LXB_CSS_VALUE__INTEGER = 0x0111;
pub const LXB_CSS_VALUE_REGION = 0x0112;
pub const LXB_CSS_VALUE_PAGE = 0x0113;
pub const LXB_CSS_VALUE_SERIF = 0x0114;
pub const LXB_CSS_VALUE_SANS_SERIF = 0x0115;
pub const LXB_CSS_VALUE_CURSIVE = 0x0116;
pub const LXB_CSS_VALUE_FANTASY = 0x0117;
pub const LXB_CSS_VALUE_MONOSPACE = 0x0118;
pub const LXB_CSS_VALUE_SYSTEM_UI = 0x0119;
pub const LXB_CSS_VALUE_EMOJI = 0x011a;
pub const LXB_CSS_VALUE_MATH = 0x011b;
pub const LXB_CSS_VALUE_FANGSONG = 0x011c;
pub const LXB_CSS_VALUE_UI_SERIF = 0x011d;
pub const LXB_CSS_VALUE_UI_SANS_SERIF = 0x011e;
pub const LXB_CSS_VALUE_UI_MONOSPACE = 0x011f;
pub const LXB_CSS_VALUE_UI_ROUNDED = 0x0120;
pub const LXB_CSS_VALUE_XX_SMALL = 0x0121;
pub const LXB_CSS_VALUE_X_SMALL = 0x0122;
pub const LXB_CSS_VALUE_SMALL = 0x0123;
pub const LXB_CSS_VALUE_LARGE = 0x0124;
pub const LXB_CSS_VALUE_X_LARGE = 0x0125;
pub const LXB_CSS_VALUE_XX_LARGE = 0x0126;
pub const LXB_CSS_VALUE_XXX_LARGE = 0x0127;
pub const LXB_CSS_VALUE_LARGER = 0x0128;
pub const LXB_CSS_VALUE_SMALLER = 0x0129;
pub const LXB_CSS_VALUE_NORMAL = 0x012a;
pub const LXB_CSS_VALUE_ULTRA_CONDENSED = 0x012b;
pub const LXB_CSS_VALUE_EXTRA_CONDENSED = 0x012c;
pub const LXB_CSS_VALUE_CONDENSED = 0x012d;
pub const LXB_CSS_VALUE_SEMI_CONDENSED = 0x012e;
pub const LXB_CSS_VALUE_SEMI_EXPANDED = 0x012f;
pub const LXB_CSS_VALUE_EXPANDED = 0x0130;
pub const LXB_CSS_VALUE_EXTRA_EXPANDED = 0x0131;
pub const LXB_CSS_VALUE_ULTRA_EXPANDED = 0x0132;
pub const LXB_CSS_VALUE_ITALIC = 0x0133;
pub const LXB_CSS_VALUE_OBLIQUE = 0x0134;
pub const LXB_CSS_VALUE_BOLD = 0x0135;
pub const LXB_CSS_VALUE_BOLDER = 0x0136;
pub const LXB_CSS_VALUE_LIGHTER = 0x0137;
pub const LXB_CSS_VALUE_FORCE_END = 0x0138;
pub const LXB_CSS_VALUE_ALLOW_END = 0x0139;
pub const LXB_CSS_VALUE_MIN_CONTENT = 0x013a;
pub const LXB_CSS_VALUE_MAX_CONTENT = 0x013b;
pub const LXB_CSS_VALUE__ANGLE = 0x013c;
pub const LXB_CSS_VALUE_MANUAL = 0x013d;
pub const LXB_CSS_VALUE_LOOSE = 0x013e;
pub const LXB_CSS_VALUE_STRICT = 0x013f;
pub const LXB_CSS_VALUE_ANYWHERE = 0x0140;
pub const LXB_CSS_VALUE_VISIBLE = 0x0141;
pub const LXB_CSS_VALUE_CLIP = 0x0142;
pub const LXB_CSS_VALUE_SCROLL = 0x0143;
pub const LXB_CSS_VALUE_BREAK_WORD = 0x0144;
pub const LXB_CSS_VALUE_STATIC = 0x0145;
pub const LXB_CSS_VALUE_RELATIVE = 0x0146;
pub const LXB_CSS_VALUE_ABSOLUTE = 0x0147;
pub const LXB_CSS_VALUE_STICKY = 0x0148;
pub const LXB_CSS_VALUE_FIXED = 0x0149;
pub const LXB_CSS_VALUE_JUSTIFY = 0x014a;
pub const LXB_CSS_VALUE_MATCH_PARENT = 0x014b;
pub const LXB_CSS_VALUE_JUSTIFY_ALL = 0x014c;
pub const LXB_CSS_VALUE_ALL = 0x014d;
pub const LXB_CSS_VALUE_DIGITS = 0x014e;
pub const LXB_CSS_VALUE_UNDERLINE = 0x014f;
pub const LXB_CSS_VALUE_OVERLINE = 0x0150;
pub const LXB_CSS_VALUE_LINE_THROUGH = 0x0151;
pub const LXB_CSS_VALUE_BLINK = 0x0152;
pub const LXB_CSS_VALUE_WAVY = 0x0153;
pub const LXB_CSS_VALUE_EACH_LINE = 0x0154;
pub const LXB_CSS_VALUE_INTER_WORD = 0x0155;
pub const LXB_CSS_VALUE_INTER_CHARACTER = 0x0156;
pub const LXB_CSS_VALUE_MIXED = 0x0157;
pub const LXB_CSS_VALUE_UPRIGHT = 0x0158;
pub const LXB_CSS_VALUE_SIDEWAYS = 0x0159;
pub const LXB_CSS_VALUE_ELLIPSIS = 0x015a;
pub const LXB_CSS_VALUE_CAPITALIZE = 0x015b;
pub const LXB_CSS_VALUE_UPPERCASE = 0x015c;
pub const LXB_CSS_VALUE_LOWERCASE = 0x015d;
pub const LXB_CSS_VALUE_FULL_WIDTH = 0x015e;
pub const LXB_CSS_VALUE_FULL_SIZE_KANA = 0x015f;
pub const LXB_CSS_VALUE_EMBED = 0x0160;
pub const LXB_CSS_VALUE_ISOLATE = 0x0161;
pub const LXB_CSS_VALUE_BIDI_OVERRIDE = 0x0162;
pub const LXB_CSS_VALUE_ISOLATE_OVERRIDE = 0x0163;
pub const LXB_CSS_VALUE_PLAINTEXT = 0x0164;
pub const LXB_CSS_VALUE_COLLAPSE = 0x0165;
pub const LXB_CSS_VALUE_PRE = 0x0166;
pub const LXB_CSS_VALUE_PRE_WRAP = 0x0167;
pub const LXB_CSS_VALUE_BREAK_SPACES = 0x0168;
pub const LXB_CSS_VALUE_PRE_LINE = 0x0169;
pub const LXB_CSS_VALUE_KEEP_ALL = 0x016a;
pub const LXB_CSS_VALUE_BREAK_ALL = 0x016b;
pub const LXB_CSS_VALUE_BOTH = 0x016c;
pub const LXB_CSS_VALUE_MINIMUM = 0x016d;
pub const LXB_CSS_VALUE_MAXIMUM = 0x016e;
pub const LXB_CSS_VALUE_CLEAR = 0x016f;
pub const LXB_CSS_VALUE_HORIZONTAL_TB = 0x0170;
pub const LXB_CSS_VALUE_VERTICAL_RL = 0x0171;
pub const LXB_CSS_VALUE_VERTICAL_LR = 0x0172;
pub const LXB_CSS_VALUE_SIDEWAYS_RL = 0x0173;
pub const LXB_CSS_VALUE_SIDEWAYS_LR = 0x0174;
pub const LXB_CSS_VALUE__LAST_ENTRY = 0x0175;

pub const lxb_css_value_type_t = c_uint;

// css/value.h

pub const lxb_css_value_number_t = extern struct {
    num: f64,
    is_float: bool,
};

pub const lxb_css_value_integer_t = extern struct {
    num: c_long,
};

pub const lxb_css_value_percentage_t = lxb_css_value_number_t;

pub const lxb_css_value_length_t = extern struct {
    num: f64,
    is_float: bool,
    unit: lxb_css_unit_t,
};

pub const lxb_css_value_length_percentage_t = extern struct {
    type: lxb_css_value_type_t,
    u: extern union {
        length: lxb_css_value_length_t,
        percentage: lxb_css_value_percentage_t,
    },
};

pub const lxb_css_value_number_length_percentage_t = extern struct {
    type: lxb_css_value_type_t,
    u: extern union {
        number: lxb_css_value_number_t,
        length: lxb_css_value_length_t,
        percentage: lxb_css_value_percentage_t,
    },
};

pub const lxb_css_value_number_length_t = extern struct {
    type: lxb_css_value_type_t,
    u: extern union {
        number: lxb_css_value_number_t,
        length: lxb_css_value_length_t,
    },
};

pub const lxb_css_value_number_percentage_t = extern struct {
    type: lxb_css_value_type_t,
    u: extern union {
        number: lxb_css_value_number_t,
        percentage: lxb_css_value_percentage_t,
    },
};

pub const lxb_css_value_number_type_t = extern struct {
    type: lxb_css_value_type_t,
    number: lxb_css_value_number_t,
};

pub const lxb_css_value_integer_type_t = extern struct {
    type: lxb_css_value_type_t,
    integer: lxb_css_value_integer_t,
};

pub const lxb_css_value_percentage_type_t = extern struct {
    type: lxb_css_value_type_t,
    percentage: lxb_css_value_percentage_t,
};

pub const lxb_css_value_length_type_t = extern struct {
    type: lxb_css_value_type_t,
    length: lxb_css_value_length_t,
};

pub const lxb_css_value_length_percentage_type_t = extern struct {
    type: lxb_css_value_type_t,
    length: lxb_css_value_length_percentage_t,
};

pub const lxb_css_value_angle_t = extern struct {
    num: f64,
    is_float: bool,
    unit: lxb_css_unit_angel_t,
};

pub const lxb_css_value_angle_type_t = extern struct {
    type: lxb_css_value_type_t,
    angle: lxb_css_value_angle_t,
};

pub const lxb_css_value_hue_t = extern struct {
    type: lxb_css_value_type_t,

    u: extern union {
        number: lxb_css_value_number_t,
        angle: lxb_css_value_angle_t,
    },
};

pub const lxb_css_value_color_hex_rgba_t = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

pub const lxb_css_value_color_hex_type_t = enum(c_int) {
    LXB_CSS_PROPERTY_COLOR_HEX_TYPE_3 = 0x00,
    LXB_CSS_PROPERTY_COLOR_HEX_TYPE_4,
    LXB_CSS_PROPERTY_COLOR_HEX_TYPE_6,
    LXB_CSS_PROPERTY_COLOR_HEX_TYPE_8,
};

pub const lxb_css_value_color_hex_t = extern struct {
    rgba: lxb_css_value_color_hex_rgba_t,
    type: lxb_css_value_color_hex_type_t,
};

pub const lxb_css_value_color_rgba_t = extern struct {
    // If R is <percent> when G and B should be <percent> to.
    // If R is <number> when G and B should be <number> to.
    // R, G, B can be NONE regardless of neighboring values.
    // 'A' can be <percentage> or <number> or NONE.
    r: lxb_css_value_number_percentage_t,
    g: lxb_css_value_number_percentage_t,
    b: lxb_css_value_number_percentage_t,
    a: lxb_css_value_number_percentage_t,
    old: bool,
};

pub const lxb_css_value_color_hsla_t = extern struct {
    h: lxb_css_value_hue_t,
    s: lxb_css_value_percentage_type_t,
    l: lxb_css_value_percentage_type_t,
    a: lxb_css_value_number_percentage_t,
    old: bool,
};

pub const lxb_css_value_color_lab_t = extern struct {
    l: lxb_css_value_number_percentage_t,
    a: lxb_css_value_number_percentage_t,
    b: lxb_css_value_number_percentage_t,
    alpha: lxb_css_value_number_percentage_t,
};

pub const lxb_css_value_color_lch_t = extern struct {
    l: lxb_css_value_number_percentage_t,
    c: lxb_css_value_number_percentage_t,
    h: lxb_css_value_hue_t,
    a: lxb_css_value_number_percentage_t,
};

pub const lxb_css_value_color_t = extern struct {
    type: lxb_css_value_type_t,
    u: extern union {
        hex: lxb_css_value_color_hex_t,
        rgh: lxb_css_value_color_rgba_t,
        hsl: lxb_css_value_color_hsla_t,
        hwb: lxb_css_value_color_hsla_t,
        lab: lxb_css_value_color_lab_t,
        lch: lxb_css_value_color_lch_t,
    },
};

// css/unit/const.h

pub const lxb_css_unit_t = enum(c_int) {
    LXB_CSS_UNIT__UNDEF = 0x0000,
    LXB_CSS_UNIT__LAST_ENTRY = 0x0022,
};

pub const lxb_css_unit_absolute_t = enum(c_int) {
    LXB_CSS_UNIT_ABSOLUTE__BEGIN = 0x0001,
    LXB_CSS_UNIT_Q = 0x0001,
    LXB_CSS_UNIT_CM = 0x0002,
    LXB_CSS_UNIT_IN = 0x0003,
    LXB_CSS_UNIT_MM = 0x0004,
    LXB_CSS_UNIT_PC = 0x0005,
    LXB_CSS_UNIT_PT = 0x0006,
    LXB_CSS_UNIT_PX = 0x0007,
    LXB_CSS_UNIT_ABSOLUTE__LAST_ENTRY = 0x0008,
};

pub const lxb_css_unit_relative_t = enum(c_int) {
    LXB_CSS_UNIT_RELATIVE__BEGIN = 0x0008,
    LXB_CSS_UNIT_CAP = 0x0008,
    LXB_CSS_UNIT_CH = 0x0009,
    LXB_CSS_UNIT_EM = 0x000a,
    LXB_CSS_UNIT_EX = 0x000b,
    LXB_CSS_UNIT_IC = 0x000c,
    LXB_CSS_UNIT_LH = 0x000d,
    LXB_CSS_UNIT_REM = 0x000e,
    LXB_CSS_UNIT_RLH = 0x000f,
    LXB_CSS_UNIT_VB = 0x0010,
    LXB_CSS_UNIT_VH = 0x0011,
    LXB_CSS_UNIT_VI = 0x0012,
    LXB_CSS_UNIT_VMAX = 0x0013,
    LXB_CSS_UNIT_VMIN = 0x0014,
    LXB_CSS_UNIT_VW = 0x0015,
    LXB_CSS_UNIT_RELATIVE__LAST_ENTRY = 0x0016,
};

pub const lxb_css_unit_angel_t = enum(c_int) {
    LXB_CSS_UNIT_ANGEL__BEGIN = 0x0016,
    LXB_CSS_UNIT_DEG = 0x0016,
    LXB_CSS_UNIT_GRAD = 0x0017,
    LXB_CSS_UNIT_RAD = 0x0018,
    LXB_CSS_UNIT_TURN = 0x0019,
    LXB_CSS_UNIT_ANGEL__LAST_ENTRY = 0x001a,
};

pub const lxb_css_unit_frequency_t = enum(c_int) {
    LXB_CSS_UNIT_FREQUENCY__BEGIN = 0x001a,
    LXB_CSS_UNIT_HZ = 0x001a,
    LXB_CSS_UNIT_KHZ = 0x001b,
    LXB_CSS_UNIT_FREQUENCY__LAST_ENTRY = 0x001c,
};

pub const lxb_css_unit_resolution_t = enum(c_int) {
    LXB_CSS_UNIT_RESOLUTION__BEGIN = 0x001c,
    LXB_CSS_UNIT_DPCM = 0x001c,
    LXB_CSS_UNIT_DPI = 0x001d,
    LXB_CSS_UNIT_DPPX = 0x001e,
    LXB_CSS_UNIT_X = 0x001f,
    LXB_CSS_UNIT_RESOLUTION__LAST_ENTRY = 0x0020,
};

pub const lxb_css_unit_duration_t = enum(c_int) {
    LXB_CSS_UNIT_DURATION__BEGIN = 0x0020,
    LXB_CSS_UNIT_MS = 0x0020,
    LXB_CSS_UNIT_S = 0x0021,
    LXB_CSS_UNIT_DURATION__LAST_ENTRY = 0x0022,
};
