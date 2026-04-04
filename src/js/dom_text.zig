// DOM Text/CharacterData/Comment — data getter/setter, CharacterData methods
// Extracted from dom_api.zig for modularity.

const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;
const lxb = @import("../bindings/lexbor.zig").c;
const api = @import("dom_api.zig");
const events = @import("events.zig");

extern fn lxb_dom_node_text_content(node: *lxb.lxb_dom_node_t, len: *usize) ?[*]const u8;
extern fn lxb_dom_node_text_content_set(node: *lxb.lxb_dom_node_t, content: [*]const u8, len: usize) lxb.lxb_status_t;

// ── CharacterData.data getter ───────────────────────────────────────

pub fn textGetData(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNodeFromText(c, this_val) orelse return qjs.JS_NewString(c, "");
    var len: usize = 0;
    const txt = lxb_dom_node_text_content(node, &len);
    if (txt) |t| return qjs.JS_NewStringLen(c, t, len);
    return qjs.JS_NewString(c, "");
}

// ── CharacterData.data setter ───────────────────────────────────────

pub fn textSetData(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const node = getNodeFromText(c, this_val) orelse return quickjs.JS_UNDEFINED();
    // Capture old text content before mutation for MutationObserver characterDataOldValue
    // Must copy to local buffer because lxb_dom_node_text_content_set invalidates the pointer
    var old_text_buf: [4096]u8 = undefined;
    var old_text: ?[]const u8 = null;
    {
        var old_len: usize = 0;
        const old_ptr = lxb_dom_node_text_content(node, &old_len);
        if (old_ptr) |p| {
            const copy_len = @min(old_len, old_text_buf.len);
            @memcpy(old_text_buf[0..copy_len], p[0..copy_len]);
            old_text = old_text_buf[0..copy_len];
        }
    }
    const s = api.jsStringToSlice(c, args[0]) orelse {
        _ = lxb_dom_node_text_content_set(node, "", 0);
        events.recordMutationWithOldValue(node, "characterData", null, null, null, old_text);
        api.setDomDirty();
        return quickjs.JS_UNDEFINED();
    };
    defer qjs.JS_FreeCString(c, s.ptr);
    _ = lxb_dom_node_text_content_set(node, s.ptr, s.len);
    events.recordMutationWithOldValue(node, "characterData", null, null, null, old_text);
    api.setDomDirty();
    return quickjs.JS_UNDEFINED();
}

// ── nodeValue getter (Node.prototype) ───────────────────────────────

pub fn nodeGetNodeValue(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = api.getNode(c, this_val) orelse return quickjs.JS_NULL();
    if (node.type == lxb.LXB_DOM_NODE_TYPE_TEXT or
        node.type == lxb.LXB_DOM_NODE_TYPE_COMMENT or
        node.type == lxb.LXB_DOM_NODE_TYPE_PROCESSING_INSTRUCTION)
    {
        var len: usize = 0;
        const txt = lxb_dom_node_text_content(node, &len);
        if (txt) |t| return qjs.JS_NewStringLen(c, t, len);
        return qjs.JS_NewString(c, "");
    }
    return quickjs.JS_NULL();
}

// ── Helper ──────────────────────────────────────────────────────────

fn getNodeFromText(ctx: *qjs.JSContext, val: qjs.JSValue) ?*lxb.lxb_dom_node_t {
    const ptr = qjs.JS_GetOpaque2(ctx, val, api.text_class_id);
    if (ptr) |p| return @ptrCast(@alignCast(p));
    return null;
}
