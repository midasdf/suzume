const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;
const lxb = @import("../bindings/lexbor.zig").c;
const api = @import("dom_api.zig");
const events = @import("events.zig");
const Box = @import("../layout/box.zig").Box;

// ── External Lexbor functions ────────────────────────────────────────
extern fn lxb_dom_element_set_attribute(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize, value: [*]const u8, value_len: usize) ?*anyopaque;
extern fn lxb_dom_element_get_attribute(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize, value_len: *usize) ?[*]const u8;
extern fn lxb_dom_element_remove_attribute(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize) lxb.lxb_status_t;
extern fn lxb_dom_element_has_attribute(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize) bool;
extern fn lxb_dom_element_local_name(element: *lxb.lxb_dom_element_t, len: *usize) ?[*]const u8;
extern fn lxb_dom_element_first_attribute_noi(element: *lxb.lxb_dom_element_t) ?*anyopaque;
extern fn lxb_dom_element_next_attribute_noi(attr: *anyopaque) ?*anyopaque;
extern fn lxb_dom_attr_qualified_name(attr: *anyopaque, len: *usize) ?[*]const u8;
extern fn lxb_dom_attr_value_noi(attr: *anyopaque, len: *usize) ?[*]const u8;
extern fn lxb_dom_node_insert_child(to: *lxb.lxb_dom_node_t, node: *lxb.lxb_dom_node_t) void;
extern fn lxb_dom_node_insert_before(to: *lxb.lxb_dom_node_t, node: *lxb.lxb_dom_node_t) void;
extern fn lxb_dom_node_insert_after(to: *lxb.lxb_dom_node_t, node: *lxb.lxb_dom_node_t) void;
extern fn lxb_dom_node_text_content(node: *lxb.lxb_dom_node_t, len: *usize) ?[*]const u8;
extern fn lxb_dom_node_text_content_set(node: *lxb.lxb_dom_node_t, content: [*]const u8, len: usize) lxb.lxb_status_t;
extern fn lxb_dom_document_create_element(document: *anyopaque, local_name: [*]const u8, lname_len: usize, reserved: ?*anyopaque) ?*lxb.lxb_dom_element_t;
extern fn lxb_dom_document_create_text_node(document: *anyopaque, data: [*]const u8, len: usize) ?*lxb.lxb_dom_node_t;

// ── Helpers (delegated to dom_api) ───────────────────────────────────

fn getNode(ctx: *qjs.JSContext, val: qjs.JSValue) ?*lxb.lxb_dom_node_t {
    return api.getNode(ctx, val);
}

fn getElement(ctx: *qjs.JSContext, val: qjs.JSValue) ?*lxb.lxb_dom_element_t {
    return api.getElement(ctx, val);
}

fn wrapNode(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) qjs.JSValue {
    return api.wrapNode(ctx, node);
}

const StringSlice = struct { ptr: [*]const u8, len: usize };

fn jsStringToSlice(ctx: *qjs.JSContext, val: qjs.JSValue) ?StringSlice {
    const result = api.jsStringToSlice(ctx, val) orelse return null;
    return StringSlice{ .ptr = result.ptr, .len = result.len };
}

fn setDomDirty() void {
    api.setDomDirty();
}

fn setDomDirtyIfConnected(elem: *lxb.lxb_dom_element_t) void {
    api.setDomDirtyIfConnected(elem);
}

fn classContains(class_str: []const u8, needle: []const u8) bool {
    return api.classContains(class_str, needle);
}

fn throwDOMException(c: *qjs.JSContext, name: []const u8, message: []const u8) qjs.JSValue {
    return api.throwDOMException(c, name, message);
}

fn findBoxForNode(root: *const Box, target: *lxb.lxb_dom_node_t) ?*const Box {
    return api.findBoxForNode(root, target);
}

// ── Attribute functions ──────────────────────────────────────────────

pub fn elementGetId(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_NULL();
    var val_len: usize = 0;
    const val = lxb_dom_element_get_attribute(elem, "id", 2, &val_len);
    if (val == null or val_len == 0) return qjs.JS_NewStringLen(c, "", 0);
    return qjs.JS_NewStringLen(c, val.?, val_len);
}

pub fn elementSetId(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, s.ptr);
    _ = lxb_dom_element_set_attribute(elem, "id", 2, s.ptr, s.len);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

pub fn elementGetClassName(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_NULL();
    var val_len: usize = 0;
    const val = lxb_dom_element_get_attribute(elem, "class", 5, &val_len);
    if (val == null or val_len == 0) return qjs.JS_NewStringLen(c, "", 0);
    return qjs.JS_NewStringLen(c, val.?, val_len);
}

pub fn elementSetClassName(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, s.ptr);
    _ = lxb_dom_element_set_attribute(elem, "class", 5, s.ptr, s.len);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

pub fn elementGetAttribute(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const elem = getElement(c, this_val) orelse return quickjs.JS_NULL();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, s.ptr);
    var val_len: usize = 0;
    const val = lxb_dom_element_get_attribute(elem, s.ptr, s.len, &val_len);
    if (val == null) return quickjs.JS_NULL();
    return qjs.JS_NewStringLen(c, val.?, val_len); // empty string when val_len == 0
}

pub fn elementSetAttribute(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 2) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const name = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, name.ptr);
    const val = jsStringToSlice(c, args[1]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, val.ptr);
    _ = lxb_dom_element_set_attribute(elem, name.ptr, name.len, val.ptr, val.len);
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    events.recordMutation(node, "attributes", null, null, name.ptr[0..name.len]);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

pub fn elementRemoveAttribute(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const name = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, name.ptr);
    _ = lxb_dom_element_remove_attribute(elem, name.ptr, name.len);
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    events.recordMutation(node, "attributes", null, null, name.ptr[0..name.len]);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

pub fn elementHasAttribute(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NewBool(false);
    if (argc < 1) return quickjs.JS_NewBool(false);
    const args = argv orelse return quickjs.JS_NewBool(false);
    const elem = getElement(c, this_val) orelse return quickjs.JS_NewBool(false);
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NewBool(false);
    defer qjs.JS_FreeCString(c, s.ptr);
    return quickjs.JS_NewBool(lxb_dom_element_has_attribute(elem, s.ptr, s.len));
}

pub fn elementToggleAttribute(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NewBool(false);
    if (argc < 1) return quickjs.JS_NewBool(false);
    const args = argv orelse return quickjs.JS_NewBool(false);
    const elem = getElement(c, this_val) orelse return quickjs.JS_NewBool(false);
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NewBool(false);
    defer qjs.JS_FreeCString(c, s.ptr);

    const has = lxb_dom_element_has_attribute(elem, s.ptr, s.len);

    // If force argument provided
    if (argc >= 2) {
        const force = qjs.JS_ToBool(c, args[1]) > 0;
        if (force and !has) {
            _ = lxb_dom_element_set_attribute(elem, s.ptr, s.len, "", 0);
            setDomDirty();
            return quickjs.JS_NewBool(true);
        } else if (!force and has) {
            _ = lxb_dom_element_remove_attribute(elem, s.ptr, s.len);
            setDomDirty();
            return quickjs.JS_NewBool(false);
        }
        return quickjs.JS_NewBool(has);
    }

    if (has) {
        _ = lxb_dom_element_remove_attribute(elem, s.ptr, s.len);
        setDomDirty();
        return quickjs.JS_NewBool(false);
    } else {
        _ = lxb_dom_element_set_attribute(elem, s.ptr, s.len, "", 0);
        setDomDirty();
        return quickjs.JS_NewBool(true);
    }
}

pub fn elementGetAttributeNames(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    const elem = getElement(c, this_val) orelse return qjs.JS_NewArray(c);
    const arr = qjs.JS_NewArray(c);
    if (quickjs.JS_IsException(arr)) return arr;

    var idx: u32 = 0;
    var attr: ?*anyopaque = lxb_dom_element_first_attribute_noi(elem);
    while (attr) |a| {
        var name_len: usize = 0;
        const name_ptr = lxb_dom_attr_qualified_name(a, &name_len);
        if (name_ptr) |np| {
            _ = qjs.JS_SetPropertyUint32(c, arr, idx, qjs.JS_NewStringLen(c, np, name_len));
            idx += 1;
        }
        attr = lxb_dom_element_next_attribute_noi(a);
    }
    return arr;
}

// ── classList helper ────────────────────────────────────────────────

/// Validate a DOMTokenList token per DOM Standard §7.1:
/// - Must not be empty string (SyntaxError)
/// - Must not contain ASCII whitespace (InvalidCharacterError)
fn validateToken(c: *qjs.JSContext, token: []const u8) ?qjs.JSValue {
    if (token.len == 0) {
        return throwDOMException(c, "SyntaxError", "The token provided must not be empty.");
    }
    for (token) |ch| {
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 0x0c) {
            return throwDOMException(c, "InvalidCharacterError", "The token provided contains HTML space characters, which are not valid in tokens.");
        }
    }
    return null;
}

pub fn classListAdd(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    // Get the element from classList.__element
    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return quickjs.JS_UNDEFINED();

    const cls_to_add = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();

    // DOM §7.1: Validate token
    if (validateToken(c, cls_to_add.ptr[0..cls_to_add.len])) |exc| return exc;
    defer qjs.JS_FreeCString(c, cls_to_add.ptr);

    // Get current class
    var cur_len: usize = 0;
    const cur = lxb_dom_element_get_attribute(elem, "class", 5, &cur_len);

    if (cur != null and cur_len > 0) {
        // Check if already present
        const current = cur.?[0..cur_len];
        if (classContains(current, cls_to_add.ptr[0..cls_to_add.len])) return quickjs.JS_UNDEFINED();
        // Compute required length and use heap allocation if needed
        const required_len = cur_len + 1 + cls_to_add.len;
        var stack_buf: [1024]u8 = undefined;
        const use_heap = required_len > stack_buf.len;
        const buf = if (use_heap)
            (std.heap.c_allocator.alloc(u8, required_len) catch return quickjs.JS_EXCEPTION())
        else
            stack_buf[0..required_len];
        defer if (use_heap) std.heap.c_allocator.free(buf);
        @memcpy(buf[0..cur_len], cur.?[0..cur_len]);
        buf[cur_len] = ' ';
        @memcpy(buf[cur_len + 1 ..][0..cls_to_add.len], cls_to_add.ptr[0..cls_to_add.len]);
        _ = lxb_dom_element_set_attribute(elem, "class", 5, buf.ptr, required_len);
    } else {
        _ = lxb_dom_element_set_attribute(elem, "class", 5, cls_to_add.ptr, cls_to_add.len);
    }
    normalizeClassAttribute(elem);
    // Notify MutationObserver of attribute change
    events.recordMutation(@ptrCast(elem), "attributes", null, null, "class");
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

pub fn classListRemove(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return quickjs.JS_UNDEFINED();

    const cls_to_remove = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, cls_to_remove.ptr);
    // DOM §7.1: Validate token
    if (validateToken(c, cls_to_remove.ptr[0..cls_to_remove.len])) |exc| return exc;

    var cur_len: usize = 0;
    const cur = lxb_dom_element_get_attribute(elem, "class", 5, &cur_len);
    if (cur == null or cur_len == 0) return quickjs.JS_UNDEFINED();

    const current = cur.?[0..cur_len];
    const remove_str = cls_to_remove.ptr[0..cls_to_remove.len];

    // Rebuild class string without the removed class (using ASCII whitespace split)
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    var iter = std.mem.tokenizeAny(u8, current, " \t\n\r\x0c");
    var first = true;
    while (iter.next()) |cls| {
        if (cls.len == 0) continue;
        if (std.mem.eql(u8, cls, remove_str)) continue;
        if (!first and pos < buf.len) {
            buf[pos] = ' ';
            pos += 1;
        }
        const copy_len = @min(cls.len, buf.len - pos);
        @memcpy(buf[pos..][0..copy_len], cls[0..copy_len]);
        pos += copy_len;
        first = false;
    }
    _ = lxb_dom_element_set_attribute(elem, "class", 5, &buf, pos);
    events.recordMutation(@ptrCast(elem), "attributes", null, null, "class");
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

pub fn classListContains(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_NewBool(false);
    const args = argv orelse return quickjs.JS_NewBool(false);

    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return quickjs.JS_NewBool(false);

    const cls_name = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NewBool(false);
    defer qjs.JS_FreeCString(c, cls_name.ptr);
    // DOM §7.1: Validate token
    if (validateToken(c, cls_name.ptr[0..cls_name.len])) |exc| return exc;

    var cur_len: usize = 0;
    const cur = lxb_dom_element_get_attribute(elem, "class", 5, &cur_len);
    if (cur == null or cur_len == 0) return quickjs.JS_NewBool(false);
    return quickjs.JS_NewBool(classContains(cur.?[0..cur_len], cls_name.ptr[0..cls_name.len]));
}

pub fn classListToggle(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return quickjs.JS_NewBool(false);

    const cls_name = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NewBool(false);
    defer qjs.JS_FreeCString(c, cls_name.ptr);
    // DOM §7.1: Validate token
    if (validateToken(c, cls_name.ptr[0..cls_name.len])) |exc| return exc;

    var cur_len: usize = 0;
    const cur = lxb_dom_element_get_attribute(elem, "class", 5, &cur_len);
    const has = if (cur != null and cur_len > 0)
        classContains(cur.?[0..cur_len], cls_name.ptr[0..cls_name.len])
    else
        false;

    // DOM spec §7.1: toggle(token, force) — if force is present, use it
    if (argc >= 2) {
        var force_val: c_int = 0;
        if (qjs.JS_ToBool(c, args[1]) >= 0) {
            force_val = qjs.JS_ToBool(c, args[1]);
        }
        const force = force_val != 0;
        if (force and !has) {
            _ = classListAdd(ctx, this_val, 1, argv);
            return quickjs.JS_NewBool(true);
        } else if (!force and has) {
            _ = classListRemove(ctx, this_val, 1, argv);
            return quickjs.JS_NewBool(false);
        }
        return quickjs.JS_NewBool(has);
    }

    if (has) {
        // Remove
        _ = classListRemove(ctx, this_val, 1, argv);
        return quickjs.JS_NewBool(false);
    } else {
        // Add
        _ = classListAdd(ctx, this_val, 1, argv);
        return quickjs.JS_NewBool(true);
    }
}

pub fn classListReplace(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NewBool(false);
    if (argc < 2) return quickjs.JS_NewBool(false);
    const args = argv orelse return quickjs.JS_NewBool(false);

    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return quickjs.JS_NewBool(false);

    const old_cls = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NewBool(false);
    defer qjs.JS_FreeCString(c, old_cls.ptr);
    const new_cls = jsStringToSlice(c, args[1]) orelse return quickjs.JS_NewBool(false);
    defer qjs.JS_FreeCString(c, new_cls.ptr);

    // DOM §7.1: Validate both tokens
    if (validateToken(c, old_cls.ptr[0..old_cls.len])) |exc| return exc;
    if (validateToken(c, new_cls.ptr[0..new_cls.len])) |exc| return exc;

    var cur_len: usize = 0;
    const cur = lxb_dom_element_get_attribute(elem, "class", 5, &cur_len);
    if (cur == null or cur_len == 0) return quickjs.JS_NewBool(false);

    const cur_str = cur.?[0..cur_len];
    if (!classContains(cur_str, old_cls.ptr[0..old_cls.len])) return quickjs.JS_NewBool(false);

    // Replace old with new in-place (single mutation per spec)
    const old_str = old_cls.ptr[0..old_cls.len];
    const new_str = new_cls.ptr[0..new_cls.len];
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var replaced = false;
    var iter = std.mem.tokenizeAny(u8, cur_str, " \t\n\r\x0c");
    while (iter.next()) |tok| {
        if (tok.len == 0) continue;
        if (pos > 0 and pos < buf.len) { buf[pos] = ' '; pos += 1; }
        if (!replaced and std.mem.eql(u8, tok, old_str)) {
            // Replace first occurrence of old with new
            if (pos + new_str.len <= buf.len) {
                @memcpy(buf[pos..][0..new_str.len], new_str);
                pos += new_str.len;
            }
            replaced = true;
        } else if (replaced and std.mem.eql(u8, tok, new_str)) {
            continue; // Skip duplicate of new token
        } else {
            if (pos + tok.len <= buf.len) {
                @memcpy(buf[pos..][0..tok.len], tok);
                pos += tok.len;
            }
        }
    }
    _ = lxb_dom_element_set_attribute(elem, "class", 5, &buf, pos);
    events.recordMutation(@ptrCast(elem), "attributes", null, null, "class");
    setDomDirty();
    return quickjs.JS_NewBool(true);
}

pub fn classListEntries(ctx: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: ?[*]qjs.JSValue) callconv(.c) qjs.JSValue {
    // Stub: return empty array (full iterator support TODO)
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewArray(c);
}

pub fn classListKeys(ctx: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: ?[*]qjs.JSValue) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewArray(c);
}

pub fn classListValues(ctx: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: ?[*]qjs.JSValue) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewArray(c);
}

/// Normalize class attribute: split by whitespace, deduplicate, rejoin with single spaces.
/// DOM spec: ordered set serialization for DOMTokenList.
pub fn normalizeClassAttribute(elem: *lxb.lxb_dom_element_t) void {
    var attr_len: usize = 0;
    const attr_ptr = lxb_dom_element_get_attribute(elem, "class", 5, &attr_len);
    if (attr_ptr == null or attr_len == 0) return;

    const class_str = attr_ptr.?[0..attr_len];
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var seen: [64][]const u8 = undefined;
    var seen_count: usize = 0;

    var iter = std.mem.tokenizeAny(u8, class_str, " \t\n\r\x0c");
    while (iter.next()) |tok| {
        if (tok.len == 0) continue;
        // Deduplicate
        var dup = false;
        for (seen[0..seen_count]) |s| {
            if (std.mem.eql(u8, s, tok)) { dup = true; break; }
        }
        if (dup) continue;
        if (seen_count < 64) { seen[seen_count] = tok; seen_count += 1; }

        if (pos > 0 and pos < buf.len) { buf[pos] = ' '; pos += 1; }
        if (pos + tok.len <= buf.len) {
            @memcpy(buf[pos..][0..tok.len], tok);
            pos += tok.len;
        }
    }
    _ = lxb_dom_element_set_attribute(elem, "class", 5, &buf, pos);
}

pub fn classListItem(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    var idx: i32 = 0;
    if (qjs.JS_ToInt32(c, &idx, args[0]) < 0) return quickjs.JS_NULL();
    if (idx < 0) return quickjs.JS_NULL();

    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return quickjs.JS_NULL();

    var attr_len: usize = 0;
    const attr_ptr = lxb_dom_element_get_attribute(elem, "class", 5, &attr_len);
    if (attr_ptr == null or attr_len == 0) return quickjs.JS_NULL();

    const class_str = attr_ptr.?[0..attr_len];
    var i: i32 = 0;
    var seen: [64][]const u8 = undefined;
    var seen_count: usize = 0;
    var iter = std.mem.tokenizeAny(u8, class_str, " \t\n\r\x0c");
    while (iter.next()) |cls| {
        if (cls.len == 0) continue;
        var dup = false;
        for (seen[0..seen_count]) |s| {
            if (std.mem.eql(u8, s, cls)) { dup = true; break; }
        }
        if (!dup) {
            if (seen_count < 64) { seen[seen_count] = cls; seen_count += 1; }
            if (i == idx) return qjs.JS_NewStringLen(c, cls.ptr, cls.len);
            i += 1;
        }
    }
    return quickjs.JS_NULL();
}

pub fn classListForEach(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const callback = args[0];

    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return quickjs.JS_UNDEFINED();

    var attr_len: usize = 0;
    const attr_ptr = lxb_dom_element_get_attribute(elem, "class", 5, &attr_len);
    if (attr_ptr == null or attr_len == 0) return quickjs.JS_UNDEFINED();

    const class_str = attr_ptr.?[0..attr_len];
    var i: i32 = 0;
    var seen_fe: [64][]const u8 = undefined;
    var seen_fe_count: usize = 0;
    var iter = std.mem.tokenizeAny(u8, class_str, " \t\n\r\x0c");
    while (iter.next()) |cls| {
        if (cls.len == 0) continue;
        var dup_fe = false;
        for (seen_fe[0..seen_fe_count]) |s| {
            if (std.mem.eql(u8, s, cls)) { dup_fe = true; break; }
        }
        if (dup_fe) continue;
        if (seen_fe_count < 64) { seen_fe[seen_fe_count] = cls; seen_fe_count += 1; }
        var cb_args = [_]qjs.JSValue{
            qjs.JS_NewStringLen(c, cls.ptr, cls.len),
            qjs.JS_NewInt32(c, i),
            this_val,
        };
        const ret = qjs.JS_Call(c, callback, this_val, 3, &cb_args);
        qjs.JS_FreeValue(c, cb_args[0]);
        qjs.JS_FreeValue(c, cb_args[1]);
        qjs.JS_FreeValue(c, ret);
        i += 1;
    }
    return quickjs.JS_UNDEFINED();
}

pub fn classListGetLength(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return qjs.JS_NewInt32(c, 0);

    var attr_len: usize = 0;
    const attr_ptr = lxb_dom_element_get_attribute(elem, "class", 5, &attr_len);
    if (attr_ptr == null or attr_len == 0) return qjs.JS_NewInt32(c, 0);

    const class_str = attr_ptr.?[0..attr_len];
    // Count unique tokens split by ASCII whitespace (DOMTokenList spec)
    var count: i32 = 0;
    var seen: [64][]const u8 = undefined;
    var seen_count: usize = 0;
    var iter = std.mem.tokenizeAny(u8, class_str, " \t\n\r\x0c");
    while (iter.next()) |cls| {
        if (cls.len == 0) continue;
        // Check for duplicate
        var dup = false;
        for (seen[0..seen_count]) |s| {
            if (std.mem.eql(u8, s, cls)) { dup = true; break; }
        }
        if (!dup) {
            if (seen_count < 64) { seen[seen_count] = cls; seen_count += 1; }
            count += 1;
        }
    }
    return qjs.JS_NewInt32(c, count);
}

pub fn classListGetValue(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return qjs.JS_NewStringLen(c, "", 0);

    var attr_len: usize = 0;
    const attr_ptr = lxb_dom_element_get_attribute(elem, "class", 5, &attr_len);
    if (attr_ptr == null or attr_len == 0) return qjs.JS_NewStringLen(c, "", 0);
    return qjs.JS_NewStringLen(c, attr_ptr.?, attr_len);
}

/// Create a classList object for the given element JS value.
pub fn createClassList(ctx: *qjs.JSContext, element_val: qjs.JSValue) qjs.JSValue {
    const obj = qjs.JS_NewObject(ctx);
    if (quickjs.JS_IsException(obj)) return obj;
    _ = qjs.JS_SetPropertyStr(ctx, obj, "__element", qjs.JS_DupValue(ctx, element_val));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "add", qjs.JS_NewCFunction(ctx, &classListAdd, "add", 1));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "remove", qjs.JS_NewCFunction(ctx, &classListRemove, "remove", 1));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "contains", qjs.JS_NewCFunction(ctx, &classListContains, "contains", 1));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "toggle", qjs.JS_NewCFunction(ctx, &classListToggle, "toggle", 1));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "replace", qjs.JS_NewCFunction(ctx, &classListReplace, "replace", 2));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "item", qjs.JS_NewCFunction(ctx, &classListItem, "item", 1));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "forEach", qjs.JS_NewCFunction(ctx, &classListForEach, "forEach", 1));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "toString", qjs.JS_NewCFunction(ctx, &classListGetValue, "toString", 0));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "entries", qjs.JS_NewCFunction(ctx, &classListEntries, "entries", 0));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "keys", qjs.JS_NewCFunction(ctx, &classListKeys, "keys", 0));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "values", qjs.JS_NewCFunction(ctx, &classListValues, "values", 0));

    // length getter
    {
        const lengthAtom = qjs.JS_NewAtom(ctx, "length");
        _ = qjs.JS_DefinePropertyGetSet(ctx, obj, lengthAtom, qjs.JS_NewCFunction(ctx, &classListGetLength, "get length", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, lengthAtom);
    }
    // value getter
    {
        const valueAtom = qjs.JS_NewAtom(ctx, "value");
        _ = qjs.JS_DefinePropertyGetSet(ctx, obj, valueAtom, qjs.JS_NewCFunction(ctx, &classListGetValue, "get value", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, valueAtom);
    }

    // Set indexed properties and Symbol.iterator via JS eval
    const iter_js =
        \\(function(cl){
        \\  var elem=cl.__element;
        \\  if(elem){
        \\    var c=elem.getAttribute('class');
        \\    if(c){
        \\      var parts=c.split(/\s+/).filter(function(s){return s.length>0;});
        \\      for(var i=0;i<parts.length;i++)Object.defineProperty(cl,i,{value:parts[i],configurable:true,enumerable:true});
        \\    }
        \\  }
        \\  cl[Symbol.iterator]=function(){var idx=0,self=this;return{next:function(){var v=self.item(idx++);return v===null?{done:true}:{done:false,value:v};}};};
        \\})
    ;
    const iter_fn = qjs.JS_Eval(ctx, iter_js, iter_js.len, "<classList>", qjs.JS_EVAL_TYPE_GLOBAL);
    if (!quickjs.JS_IsException(iter_fn)) {
        var call_args = [_]qjs.JSValue{obj};
        const ret = qjs.JS_Call(ctx, iter_fn, quickjs.JS_UNDEFINED(), 1, &call_args);
        qjs.JS_FreeValue(ctx, ret);
        qjs.JS_FreeValue(ctx, iter_fn);
    }

    return obj;
}

pub fn elementGetClassList(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return createClassList(c, this_val);
}

// ── element.attachShadow() stub ─────────────────────────────────────

pub fn elementAttachShadow(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    // Create a pseudo-shadow root object that delegates to the element
    const shadow = qjs.JS_NewObject(c);
    // Copy key methods from the element so querySelector etc. work on shadowRoot
    const qs = qjs.JS_GetPropertyStr(c, this_val, "querySelector");
    _ = qjs.JS_SetPropertyStr(c, shadow, "querySelector", qs);
    const qsa = qjs.JS_GetPropertyStr(c, this_val, "querySelectorAll");
    _ = qjs.JS_SetPropertyStr(c, shadow, "querySelectorAll", qsa);
    const ac = qjs.JS_GetPropertyStr(c, this_val, "appendChild");
    _ = qjs.JS_SetPropertyStr(c, shadow, "appendChild", ac);
    const ih_get = qjs.JS_GetPropertyStr(c, this_val, "innerHTML");
    _ = qjs.JS_SetPropertyStr(c, shadow, "innerHTML", ih_get);
    _ = qjs.JS_SetPropertyStr(c, shadow, "host", qjs.JS_DupValue(c, this_val));
    _ = qjs.JS_SetPropertyStr(c, shadow, "mode", qjs.JS_NewString(c, "open"));
    // Store on element as .shadowRoot
    _ = qjs.JS_SetPropertyStr(c, this_val, "shadowRoot", qjs.JS_DupValue(c, shadow));
    return shadow;
}

// ── element.insertAdjacentElement() ─────────────────────────────────

pub fn elementInsertAdjacentElement(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 2) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    const new_node = getNode(c, args[1]) orelse return quickjs.JS_NULL();

    const pos_s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, pos_s.ptr);
    const position = pos_s.ptr[0..pos_s.len];

    if (std.ascii.eqlIgnoreCase(position, "beforebegin")) {
        lxb_dom_node_insert_before(node, new_node);
    } else if (std.ascii.eqlIgnoreCase(position, "afterbegin")) {
        if (node.first_child) |first| {
            lxb_dom_node_insert_before(first, new_node);
        } else {
            lxb_dom_node_insert_child(node, new_node);
        }
    } else if (std.ascii.eqlIgnoreCase(position, "beforeend")) {
        lxb_dom_node_insert_child(node, new_node);
    } else if (std.ascii.eqlIgnoreCase(position, "afterend")) {
        lxb_dom_node_insert_after(node, new_node);
    } else {
        return quickjs.JS_NULL();
    }
    setDomDirty();
    return qjs.JS_DupValue(c, args[1]);
}

// ── element.insertAdjacentText() ────────────────────────────────────

pub fn elementInsertAdjacentText(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 2) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const doc = api.g_document orelse return quickjs.JS_UNDEFINED();

    const pos_s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, pos_s.ptr);
    const position = pos_s.ptr[0..pos_s.len];

    const text_s = jsStringToSlice(c, args[1]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, text_s.ptr);

    const text_node = lxb_dom_document_create_text_node(doc, text_s.ptr, text_s.len) orelse return quickjs.JS_UNDEFINED();

    if (std.ascii.eqlIgnoreCase(position, "beforebegin")) {
        lxb_dom_node_insert_before(node, text_node);
    } else if (std.ascii.eqlIgnoreCase(position, "afterbegin")) {
        if (node.first_child) |first| {
            lxb_dom_node_insert_before(first, text_node);
        } else {
            lxb_dom_node_insert_child(node, text_node);
        }
    } else if (std.ascii.eqlIgnoreCase(position, "beforeend")) {
        lxb_dom_node_insert_child(node, text_node);
    } else if (std.ascii.eqlIgnoreCase(position, "afterend")) {
        lxb_dom_node_insert_after(node, text_node);
    } else {
        return quickjs.JS_UNDEFINED();
    }
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

// ── Dataset (data-* attributes) ─────────────────────────────────────

pub fn elementGetDataset(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const obj = qjs.JS_NewObject(c);
    if (quickjs.JS_IsException(obj)) return obj;
    _ = qjs.JS_SetPropertyStr(c, obj, "__element", qjs.JS_DupValue(c, this_val));
    _ = qjs.JS_SetPropertyStr(c, obj, "get", qjs.JS_NewCFunction(c, &datasetGet, "get", 1));
    _ = qjs.JS_SetPropertyStr(c, obj, "set", qjs.JS_NewCFunction(c, &datasetSet, "set", 2));
    return obj;
}

pub fn datasetGet(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return quickjs.JS_UNDEFINED();

    const key = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, key.ptr);

    // Convert camelCase key to data-kebab-case attribute name
    var attr_buf: [256]u8 = undefined;
    const attr_name = camelToDataAttr(key.ptr[0..key.len], &attr_buf) orelse return quickjs.JS_UNDEFINED();

    var val_len: usize = 0;
    const val = lxb_dom_element_get_attribute(elem, attr_name.ptr, attr_name.len, &val_len);
    if (val == null) return quickjs.JS_UNDEFINED();
    return qjs.JS_NewStringLen(c, val.?, val_len);
}

pub fn datasetSet(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 2) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return quickjs.JS_UNDEFINED();

    const key = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, key.ptr);
    const val = jsStringToSlice(c, args[1]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, val.ptr);

    var attr_buf: [256]u8 = undefined;
    const attr_name = camelToDataAttr(key.ptr[0..key.len], &attr_buf) orelse return quickjs.JS_UNDEFINED();
    _ = lxb_dom_element_set_attribute(elem, attr_name.ptr, attr_name.len, val.ptr, val.len);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

pub fn camelToDataAttr(key: []const u8, buf: []u8) ?[]const u8 {
    // "data-" prefix
    if (buf.len < 5 + key.len * 2) return null;
    @memcpy(buf[0..5], "data-");
    var pos: usize = 5;
    for (key) |ch| {
        if (ch >= 'A' and ch <= 'Z') {
            if (pos + 2 > buf.len) return null;
            buf[pos] = '-';
            pos += 1;
            buf[pos] = ch + 32; // lowercase
            pos += 1;
        } else {
            if (pos + 1 > buf.len) return null;
            buf[pos] = ch;
            pos += 1;
        }
    }
    return buf[0..pos];
}

// ── Value getter/setter (input, textarea, select) ───────────────────

pub fn elementGetValue(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return qjs.JS_NewStringLen(c, "", 0);

    // Check tag name
    var name_len: usize = 0;
    const name_ptr = lxb_dom_element_local_name(elem, &name_len);
    if (name_ptr == null) return qjs.JS_NewStringLen(c, "", 0);
    const tag = name_ptr.?[0..name_len];

    if (std.mem.eql(u8, tag, "textarea")) {
        // textarea: value = textContent
        const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
        var len: usize = 0;
        const ptr = lxb_dom_node_text_content(node, &len);
        if (ptr == null or len == 0) return qjs.JS_NewStringLen(c, "", 0);
        return qjs.JS_NewStringLen(c, ptr.?, len);
    } else if (std.mem.eql(u8, tag, "select")) {
        // select: find selected option's value
        return getSelectedOptionValue(c, @ptrCast(elem));
    } else {
        // input and other elements: use "value" attribute
        var attr_len: usize = 0;
        const attr_ptr = lxb_dom_element_get_attribute(elem, "value", 5, &attr_len);
        if (attr_ptr == null) return qjs.JS_NewStringLen(c, "", 0);
        return qjs.JS_NewStringLen(c, attr_ptr.?, attr_len);
    }
}

pub fn elementSetValue(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_UNDEFINED();

    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, s.ptr);

    // Check tag name
    var name_len: usize = 0;
    const name_ptr = lxb_dom_element_local_name(elem, &name_len);
    if (name_ptr == null) return quickjs.JS_UNDEFINED();
    const tag = name_ptr.?[0..name_len];

    if (std.mem.eql(u8, tag, "textarea")) {
        // textarea: set textContent
        const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
        _ = lxb_dom_node_text_content_set(node, s.ptr, s.len);
    } else {
        // input, select, etc.: set "value" attribute
        _ = lxb_dom_element_set_attribute(elem, "value", 5, s.ptr, s.len);
    }
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

fn getSelectedOptionValue(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) qjs.JSValue {
    // Walk children to find first <option> with "selected" attribute, or first <option>
    var first_option_value: ?struct { ptr: [*]const u8, len: usize } = null;
    var child = lxb.lxb_dom_node_first_child(node);
    while (child) |ch| : (child = lxb.lxb_dom_node_next(ch)) {
        if (ch.*.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) continue;
        const ch_elem: *lxb.lxb_dom_element_t = @ptrCast(ch);
        var ch_name_len: usize = 0;
        const ch_name = lxb_dom_element_local_name(ch_elem, &ch_name_len);
        if (ch_name == null) continue;
        if (!std.mem.eql(u8, ch_name.?[0..ch_name_len], "option")) continue;

        var val_len: usize = 0;
        const val_ptr = lxb_dom_element_get_attribute(ch_elem, "value", 5, &val_len);

        // Check if this option has "selected" attribute (boolean attribute)
        if (lxb_dom_element_has_attribute(ch_elem, "selected", 8)) {
            // This is the selected option
            if (val_ptr) |vp| {
                return qjs.JS_NewStringLen(ctx, vp, val_len);
            }
            // No value attribute, use textContent
            var tc_len: usize = 0;
            const tc = lxb_dom_node_text_content(ch, &tc_len);
            if (tc) |t| return qjs.JS_NewStringLen(ctx, t, tc_len);
            return qjs.JS_NewStringLen(ctx, "", 0);
        }

        // Track first option as default
        if (first_option_value == null) {
            if (val_ptr) |vp| {
                first_option_value = .{ .ptr = vp, .len = val_len };
            } else {
                var tc_len: usize = 0;
                const tc = lxb_dom_node_text_content(ch, &tc_len);
                if (tc) |t| {
                    first_option_value = .{ .ptr = t, .len = tc_len };
                }
            }
        }
    }

    // No selected attribute found, return first option's value
    if (first_option_value) |v| {
        return qjs.JS_NewStringLen(ctx, v.ptr, v.len);
    }
    return qjs.JS_NewStringLen(ctx, "", 0);
}

// ── Hidden getter/setter ────────────────────────────────────────────

pub fn elementGetHidden(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_NewBool(false);
    var attr_len: usize = 0;
    const attr_ptr = lxb_dom_element_get_attribute(elem, "hidden", 6, &attr_len);
    // hidden attribute exists = true (even if empty string)
    return quickjs.JS_NewBool(attr_ptr != null);
}

pub fn elementSetHidden(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_UNDEFINED();

    const val = qjs.JS_ToBool(c, args[0]);
    if (val > 0) {
        // Set hidden attribute
        _ = lxb_dom_element_set_attribute(elem, "hidden", 6, "", 0);
    } else {
        // Remove hidden attribute
        _ = lxb_dom_element_remove_attribute(elem, "hidden", 6);
    }
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

// ── Scroll getters ──────────────────────────────────────────────────

pub fn elementGetScrollTop(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewInt32(c, @intFromFloat(api.scroll_y));
}

pub fn elementGetScrollLeft(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewInt32(c, @intFromFloat(api.scroll_x));
}

pub fn elementScrollIntoView(
    _: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    // Stub — actual scroll-to-element requires layout position lookup
    return quickjs.JS_UNDEFINED();
}

// ── Canvas getContext ────────────────────────────────────────────────

pub fn elementGetContext(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();

    // Check if this is a canvas element
    const elem = getElement(c, this_val) orelse return quickjs.JS_NULL();
    var name_len: usize = 0;
    const name_ptr = lxb_dom_element_local_name(elem, &name_len);
    if (name_ptr == null) return quickjs.JS_NULL();
    if (!std.mem.eql(u8, name_ptr.?[0..name_len], "canvas")) return quickjs.JS_NULL();

    // Check context type
    const type_s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, type_s.ptr);
    if (!std.mem.eql(u8, type_s.ptr[0..type_s.len], "2d")) return quickjs.JS_NULL();

    // Get canvas dimensions from attributes or defaults
    var width: u32 = 300;
    var height: u32 = 150;
    var attr_len: usize = 0;
    const w_attr = lxb_dom_element_get_attribute(elem, "width", 5, &attr_len);
    if (w_attr) |wa| {
        width = std.fmt.parseInt(u32, wa[0..attr_len], 10) catch 300;
    }
    var h_attr_len: usize = 0;
    const h_attr = lxb_dom_element_get_attribute(elem, "height", 6, &h_attr_len);
    if (h_attr) |ha| {
        height = std.fmt.parseInt(u32, ha[0..h_attr_len], 10) catch 150;
    }

    const canvas_mod = @import("canvas.zig");
    return canvas_mod.createContext2D(c, width, height);
}

// ── Template content ────────────────────────────────────────────────

pub fn templateGetContent(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_UNDEFINED();

    // Only <template> elements have a .content property
    var name_len: usize = 0;
    const name_ptr = lxb_dom_element_local_name(elem, &name_len);
    if (name_ptr == null or name_len != 8) return quickjs.JS_UNDEFINED();
    if (!std.mem.eql(u8, name_ptr.?[0..8], "template")) return quickjs.JS_UNDEFINED();

    // Return cached __content__ if it exists
    const cache_atom = qjs.JS_NewAtom(c, "__content__");
    defer qjs.JS_FreeAtom(c, cache_atom);
    const cached = qjs.JS_GetProperty(c, this_val, cache_atom);
    if (!quickjs.JS_IsUndefined(cached) and !quickjs.JS_IsException(cached)) {
        return cached;
    }
    qjs.JS_FreeValue(c, cached);

    // Create a DocumentFragment (simplified as a detached div)
    const doc = api.g_document orelse return quickjs.JS_UNDEFINED();
    const frag_elem = lxb_dom_document_create_element(doc, "div", 3, null) orelse return quickjs.JS_UNDEFINED();
    const frag_node: *lxb.lxb_dom_node_t = @ptrCast(frag_elem);
    const frag = wrapNode(c, frag_node);

    // Cache it on the element
    _ = qjs.JS_DefinePropertyValue(c, this_val, cache_atom, qjs.JS_DupValue(c, frag), qjs.JS_PROP_CONFIGURABLE);

    return frag;
}

// ── Element geometry ────────────────────────────────────────────────

/// Helper: get Box dimensions for the element attached to this_val.
pub fn getBoxForThis(ctx: *qjs.JSContext, this_val: qjs.JSValue) ?*const Box {
    const root = api.g_root_box orelse return null;
    const node = getNodeFromThis(ctx, this_val) orelse return null;
    return findBoxForNode(root, node);
}

pub fn getNodeFromThis(ctx: *qjs.JSContext, this_val: qjs.JSValue) ?*lxb.lxb_dom_node_t {
    // Try element class first, then text class
    const ptr1 = qjs.JS_GetOpaque2(ctx, this_val, api.element_class_id);
    if (ptr1) |p| return @ptrCast(@alignCast(p));
    const ptr2 = qjs.JS_GetOpaque2(ctx, this_val, api.text_class_id);
    if (ptr2) |p| return @ptrCast(@alignCast(p));
    return null;
}

pub fn elementGetClientWidth(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (getBoxForThis(c, this_val)) |box| {
        const pbox = box.paddingBox();
        return qjs.JS_NewInt32(c, @intFromFloat(pbox.width));
    }
    return qjs.JS_NewInt32(c, 0);
}

pub fn elementGetClientHeight(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (getBoxForThis(c, this_val)) |box| {
        const pbox = box.paddingBox();
        return qjs.JS_NewInt32(c, @intFromFloat(pbox.height));
    }
    return qjs.JS_NewInt32(c, 0);
}

pub fn elementGetClientTop(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (getBoxForThis(c, this_val)) |box| {
        return qjs.JS_NewInt32(c, @intFromFloat(box.border.top));
    }
    return qjs.JS_NewInt32(c, 0);
}

pub fn elementGetClientLeft(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (getBoxForThis(c, this_val)) |box| {
        return qjs.JS_NewInt32(c, @intFromFloat(box.border.left));
    }
    return qjs.JS_NewInt32(c, 0);
}

pub fn elementGetOffsetWidth(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (getBoxForThis(c, this_val)) |box| {
        const bbox = box.borderBox();
        return qjs.JS_NewInt32(c, @intFromFloat(bbox.width));
    }
    return qjs.JS_NewInt32(c, 0);
}

pub fn elementGetOffsetHeight(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (getBoxForThis(c, this_val)) |box| {
        const bbox = box.borderBox();
        return qjs.JS_NewInt32(c, @intFromFloat(bbox.height));
    }
    return qjs.JS_NewInt32(c, 0);
}

pub fn elementGetOffsetTop(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (getBoxForThis(c, this_val)) |box| {
        const bbox = box.borderBox();
        return qjs.JS_NewInt32(c, @intFromFloat(bbox.y));
    }
    return qjs.JS_NewInt32(c, 0);
}

pub fn elementGetOffsetLeft(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (getBoxForThis(c, this_val)) |box| {
        const bbox = box.borderBox();
        return qjs.JS_NewInt32(c, @intFromFloat(bbox.x));
    }
    return qjs.JS_NewInt32(c, 0);
}

pub fn elementGetBoundingClientRect(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const obj = qjs.JS_NewObject(c);
    if (quickjs.JS_IsException(obj)) return obj;

    if (getBoxForThis(c, this_val)) |box| {
        const bbox = box.borderBox();
        _ = qjs.JS_SetPropertyStr(c, obj, "x", qjs.JS_NewFloat64(c, bbox.x));
        _ = qjs.JS_SetPropertyStr(c, obj, "y", qjs.JS_NewFloat64(c, bbox.y));
        _ = qjs.JS_SetPropertyStr(c, obj, "top", qjs.JS_NewFloat64(c, bbox.y));
        _ = qjs.JS_SetPropertyStr(c, obj, "left", qjs.JS_NewFloat64(c, bbox.x));
        _ = qjs.JS_SetPropertyStr(c, obj, "width", qjs.JS_NewFloat64(c, bbox.width));
        _ = qjs.JS_SetPropertyStr(c, obj, "height", qjs.JS_NewFloat64(c, bbox.height));
        _ = qjs.JS_SetPropertyStr(c, obj, "right", qjs.JS_NewFloat64(c, bbox.x + bbox.width));
        _ = qjs.JS_SetPropertyStr(c, obj, "bottom", qjs.JS_NewFloat64(c, bbox.y + bbox.height));
    } else {
        _ = qjs.JS_SetPropertyStr(c, obj, "x", qjs.JS_NewFloat64(c, 0));
        _ = qjs.JS_SetPropertyStr(c, obj, "y", qjs.JS_NewFloat64(c, 0));
        _ = qjs.JS_SetPropertyStr(c, obj, "top", qjs.JS_NewFloat64(c, 0));
        _ = qjs.JS_SetPropertyStr(c, obj, "left", qjs.JS_NewFloat64(c, 0));
        _ = qjs.JS_SetPropertyStr(c, obj, "width", qjs.JS_NewFloat64(c, 0));
        _ = qjs.JS_SetPropertyStr(c, obj, "height", qjs.JS_NewFloat64(c, 0));
        _ = qjs.JS_SetPropertyStr(c, obj, "right", qjs.JS_NewFloat64(c, 0));
        _ = qjs.JS_SetPropertyStr(c, obj, "bottom", qjs.JS_NewFloat64(c, 0));
    }
    return obj;
}
