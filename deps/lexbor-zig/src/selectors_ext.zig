// const std = @import("std");

const core = @import("core_ext.zig");
const css = @import("css_ext.zig");
const dom = @import("dom_ext.zig");

// selectors/selectors.h
pub const lxb_selectors_opt_t = enum(c_int) {
    LXB_SELECTORS_OPT_DEFAULT = 0x00,
    LXB_SELECTORS_OPT_MATCH_ROOT = 1 << 1,
    LXB_SELECTORS_OPT_MATCH_FIRST = 1 << 2,
};

pub const lxb_selectors_t = lxb_selectors;
pub const lxb_selectors_entry_t = lxb_selectors_entry;
pub const lxb_selectors_nested_t = lxb_selectors_nested;

pub const lxb_selectors_cb_f = ?*const fn (node: ?*dom.lxb_dom_node_t, spec: css.lxb_css_selector_specificity_t, ctx: ?*anyopaque) callconv(.C) core.lxb_status_t;

// TODO: error: dependency loop detected
// pub const lxb_selectors_state_cb_f = ?*const fn (selectors: ?*lxb_selectors_t, entry: ?*lxb_selectors_entry_t) ?*lxb_selectors_entry_t;

// fixed(??)...
pub const lxb_selectors_state_cb_f = ?*const fn (selectors: ?*lxb_selectors_t, entry: ?*anyopaque) callconv(.C) ?*anyopaque;

pub const lxb_selectors_entry = extern struct {
    id: usize,
    combinator: css.lxb_css_selector_combinator_t,
    selector: ?*const css.lxb_css_selector_t,
    node: ?*dom.lxb_dom_node_t,
    next: ?*lxb_selectors_entry_t,
    prev: ?*lxb_selectors_entry_t,
    following: ?*lxb_selectors_entry_t,
    nested: ?*lxb_selectors_nested_t,
};

pub const lxb_selectors_nested = extern struct {
    entry: ?*lxb_selectors_entry_t,
    return_state: lxb_selectors_state_cb_f,
    cb: lxb_selectors_cb_f,
    ctx: ?*anyopaque,
    root: ?*dom.lxb_dom_node_t,
    last: ?*lxb_selectors_entry_t,
    parent: ?*lxb_selectors_nested_t,
    index: usize,
    found: bool,
};

pub const lxb_selectors = extern struct {
    state: lxb_selectors_state_cb_f,
    objs: ?*core.lexbor_dobject_t,
    nested: ?*core.lexbor_dobject_t,
    current: ?*lxb_selectors_nested_t,
    first: ?*lxb_selectors_entry_t,
    options: lxb_selectors_opt_t,
    status: core.lxb_status_t,
};
