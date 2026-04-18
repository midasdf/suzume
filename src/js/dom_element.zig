const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;
const lxb = @import("../bindings/lexbor.zig").c;
const api = @import("dom_api.zig");
const events = @import("events.zig");
const Box = @import("../layout/box.zig").Box;
const dom_bindings = @import("dom_bindings.zig");
const dom_doc = @import("dom_document.zig");

// ── Helpers (from shared dom_bindings) ──────────────────────────────
const lowercaseAttrName = dom_bindings.lowercaseAttrName;

// ── Lexbor functions (from shared dom_bindings) ─────────────────────
const lxb_dom_element_set_attribute = dom_bindings.lxb_dom_element_set_attribute;
const lxb_dom_element_get_attribute = dom_bindings.lxb_dom_element_get_attribute;
const lxb_dom_element_remove_attribute = dom_bindings.lxb_dom_element_remove_attribute;
const lxb_dom_element_has_attribute = dom_bindings.lxb_dom_element_has_attribute;
const lxb_dom_element_local_name = dom_bindings.lxb_dom_element_local_name;
const lxb_dom_element_first_attribute_noi = dom_bindings.lxb_dom_element_first_attribute_noi;
const lxb_dom_element_next_attribute_noi = dom_bindings.lxb_dom_element_next_attribute_noi;
const lxb_dom_attr_qualified_name = dom_bindings.lxb_dom_attr_qualified_name;
const lxb_dom_attr_value_noi = dom_bindings.lxb_dom_attr_value_noi;
const lxb_dom_node_insert_child = dom_bindings.lxb_dom_node_insert_child;
const lxb_dom_node_insert_before = dom_bindings.lxb_dom_node_insert_before;
const lxb_dom_node_insert_after = dom_bindings.lxb_dom_node_insert_after;
const lxb_dom_node_remove = dom_bindings.lxb_dom_node_remove;
const lxb_dom_node_text_content = dom_bindings.lxb_dom_node_text_content;
const lxb_dom_node_text_content_set = dom_bindings.lxb_dom_node_text_content_set;
const lxb_dom_document_create_element = dom_bindings.lxb_dom_document_create_element;
const lxb_dom_document_create_text_node = dom_bindings.lxb_dom_document_create_text_node;

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
    // Capture old value for MutationObserver
    var _ov_buf: [4096]u8 = undefined;
    var old_val: ?[]const u8 = null;
    {
        var ov_len: usize = 0;
        const ov_ptr = lxb_dom_element_get_attribute(elem, "id", 2, &ov_len);
        if (ov_ptr != null) {
            const cl = @min(ov_len, _ov_buf.len);
            @memcpy(_ov_buf[0..cl], ov_ptr.?[0..cl]);
            old_val = _ov_buf[0..cl];
        }
    }
    _ = lxb_dom_element_set_attribute(elem, "id", 2, s.ptr, s.len);
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    events.recordMutationWithOldValue(node, "attributes", null, null, "id", old_val);
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
    // Capture old class value before modification
    var _ov_buf: [4096]u8 = undefined;
    var old_val: ?[]const u8 = null;
    {
        var ov_len: usize = 0;
        const ov_ptr = lxb_dom_element_get_attribute(elem, "class", 5, &ov_len);
        if (ov_ptr != null) {
            const cl = @min(ov_len, _ov_buf.len);
            @memcpy(_ov_buf[0..cl], ov_ptr.?[0..cl]);
            old_val = _ov_buf[0..cl];
        }
    }
    _ = lxb_dom_element_set_attribute(elem, "class", 5, s.ptr, s.len);
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    events.recordMutationWithOldValue(node, "attributes", null, null, "class", old_val);
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
    var lower_buf: [1024]u8 = undefined;
    const name = lowercaseAttrName(s.ptr[0..s.len], &lower_buf);
    var val_len: usize = 0;
    const val = lxb_dom_element_get_attribute(elem, name.ptr, name.len, &val_len);
    if (val == null) {
        // HTML spec: attribute with no value (e.g. <div disabled>) returns ""
        if (lxb_dom_element_has_attribute(elem, name.ptr, name.len))
            return qjs.JS_NewStringLen(c, "", 0);
        return quickjs.JS_NULL();
    }
    return qjs.JS_NewStringLen(c, val.?, val_len);
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
    // DOM spec: throw InvalidCharacterError for empty name
    // Note: browsers are lenient and only reject empty string, not strict XML Name production
    if (name.len == 0) {
        return throwDOMException(c, "InvalidCharacterError", "The string contains invalid characters.");
    }
    const val = jsStringToSlice(c, args[1]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, val.ptr);
    // DOM spec: HTML elements lowercase attribute names
    var lower_buf: [1024]u8 = undefined;
    const attr_name = lowercaseAttrName(name.ptr[0..name.len], &lower_buf);
    // Capture old value before setting (for MutationObserver attributeOldValue)
    // Must copy to stack buffer because lexbor invalidates pointer on set_attribute
    var old_val_buf: [4096]u8 = undefined;
    var old_val_copy: ?[]const u8 = null;
    {
        var ov_len: usize = 0;
        const ov_ptr = lxb_dom_element_get_attribute(elem, attr_name.ptr, attr_name.len, &ov_len);
        if (ov_ptr != null) {
            const copy_len = @min(ov_len, old_val_buf.len);
            @memcpy(old_val_buf[0..copy_len], ov_ptr.?[0..copy_len]);
            old_val_copy = old_val_buf[0..copy_len];
        }
    }
    _ = lxb_dom_element_set_attribute(elem, attr_name.ptr, attr_name.len, val.ptr, val.len);
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    // DOM §4.3.3: MutationObserver reachability is determined by the isDescendant
    // walk inside recordMutationFull, not by whether the mutating element is
    // attached to the top-level document. Observers registered on detached
    // subtree roots must still fire for attribute changes on descendants.
    events.recordMutationWithOldValue(node, "attributes", null, null, name.ptr[0..name.len], old_val_copy);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

// ── Namespace-aware attribute methods ──────────────────────────────
// In HTML documents, these work like their non-NS counterparts using the local name.

pub fn elementGetAttributeNS(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 2) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const elem = getElement(c, this_val) orelse return quickjs.JS_NULL();
    // args[0] = namespace (nullable), args[1] = localName
    var req_ns: ?[]const u8 = null;
    var req_ns_ptr: ?[*]const u8 = null;
    if (!quickjs.JS_IsNull(args[0]) and !quickjs.JS_IsUndefined(args[0])) {
        if (jsStringToSlice(c, args[0])) |ns_s| {
            req_ns_ptr = ns_s.ptr;
            req_ns = ns_s.ptr[0..ns_s.len];
        }
    }
    defer if (req_ns_ptr) |p| qjs.JS_FreeCString(c, p);
    // Treat empty namespace as null per DOM spec
    if (req_ns) |ns| {
        if (ns.len == 0) req_ns = null;
    }
    const local = jsStringToSlice(c, args[1]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, local.ptr);
    const local_s = local.ptr[0..local.len];

    // Get __attrNS namespace map
    const attr_ns_obj = qjs.JS_GetPropertyStr(c, this_val, "__attrNS");
    defer qjs.JS_FreeValue(c, attr_ns_obj);

    // DOM spec: getAttributeNS matches by namespace AND local name (case-sensitive)
    var attr_it: ?*anyopaque = lxb_dom_element_first_attribute_noi(elem);
    while (attr_it) |attr| {
        var attr_name_len: usize = 0;
        if (lxb_dom_attr_qualified_name(attr, &attr_name_len)) |attr_name_ptr| {
            const attr_qname = attr_name_ptr[0..attr_name_len];
            const attr_local = extractLocalName(attr_qname);
            if (std.mem.eql(u8, attr_local, local_s)) {
                // Check namespace match
                if (!quickjs.JS_IsUndefined(attr_ns_obj) and !quickjs.JS_IsNull(attr_ns_obj)) {
                    const ns_val = qjs.JS_GetPropertyStr(c, attr_ns_obj, attr_name_ptr);
                    defer qjs.JS_FreeValue(c, ns_val);
                    if (!quickjs.JS_IsUndefined(ns_val) and !quickjs.JS_IsNull(ns_val)) {
                        if (jsStringToSlice(c, ns_val)) |ns_s| {
                            defer qjs.JS_FreeCString(c, ns_s.ptr);
                            const ns_str = ns_s.ptr[0..ns_s.len];
                            // Both must have matching namespace
                            if (req_ns) |rns| {
                                if (std.mem.eql(u8, ns_str, rns)) {
                                    var val_len: usize = 0;
                                    if (lxb_dom_attr_value_noi(attr, &val_len)) |val_ptr| {
                                        return qjs.JS_NewStringLen(c, val_ptr, val_len);
                                    }
                                    return qjs.JS_NewStringLen(c, "", 0);
                                }
                            }
                            // ns_str is non-empty but req_ns is null — no match
                            attr_it = lxb_dom_element_next_attribute_noi(attr);
                            continue;
                        }
                    }
                }
                // Attribute has no stored namespace (null) — match if req_ns is also null
                // Only match unprefixed attributes to avoid false positives (e.g. "xml:lang")
                if (req_ns == null and std.mem.indexOfScalar(u8, attr_qname, ':') == null) {
                    var val_len: usize = 0;
                    if (lxb_dom_attr_value_noi(attr, &val_len)) |val_ptr| {
                        return qjs.JS_NewStringLen(c, val_ptr, val_len);
                    }
                    return qjs.JS_NewStringLen(c, "", 0);
                }
            }
        }
        attr_it = lxb_dom_element_next_attribute_noi(attr);
    }
    return quickjs.JS_NULL();
}

pub fn elementSetAttributeNS(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 3) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_UNDEFINED();

    // args[0] = namespace, args[1] = qualifiedName, args[2] = value
    const qname = jsStringToSlice(c, args[1]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, qname.ptr);
    const qname_s = qname.ptr[0..qname.len];

    // DOM spec: validate qualifiedName per QName production (matching browser behavior)
    if (!dom_doc.isValidQName(qname_s)) {
        return throwDOMException(c, "InvalidCharacterError", "The string contains invalid characters.");
    }
    if (!dom_doc.isValidXmlQName(qname_s)) {
        return throwDOMException(c, "InvalidCharacterError", "The string contains invalid characters.");
    }

    // Get namespace string
    var ns_slice: ?[]const u8 = null;
    var ns_cstr: ?[*]const u8 = null;
    if (!quickjs.JS_IsNull(args[0]) and !quickjs.JS_IsUndefined(args[0])) {
        if (jsStringToSlice(c, args[0])) |ns_s| {
            ns_cstr = ns_s.ptr;
            ns_slice = ns_s.ptr[0..ns_s.len];
        }
    }
    defer if (ns_cstr) |p| qjs.JS_FreeCString(c, p);
    // Treat empty namespace as null
    const namespace: ?[]const u8 = if (ns_slice) |ns| (if (ns.len == 0) null else ns) else null;

    // Extract prefix and local name
    var prefix: ?[]const u8 = null;
    var local_name: []const u8 = qname_s;
    if (std.mem.indexOfScalar(u8, qname_s, ':')) |colon| {
        prefix = qname_s[0..colon];
        local_name = qname_s[colon + 1 ..];
        // Local name after colon must not be empty
        if (local_name.len == 0) {
            return throwDOMException(c, "InvalidCharacterError", "The string contains invalid characters.");
        }
    }

    // DOM spec namespace validation:
    // 1. If namespace is null and prefix is not null, throw NamespaceError
    if (namespace == null and prefix != null) {
        return throwDOMException(c, "NamespaceError", "A namespace is required to use a prefix.");
    }
    // 2. If prefix is "xml" and namespace is not the XML namespace
    if (prefix) |p| {
        if (std.mem.eql(u8, p, "xml") and
            (namespace == null or !std.mem.eql(u8, namespace.?, "http://www.w3.org/XML/1998/namespace")))
        {
            return throwDOMException(c, "NamespaceError", "The xml prefix must use the XML namespace.");
        }
    }
    // 3. If qualifiedName or prefix is "xmlns" and namespace is not the XMLNS namespace
    const is_xmlns_qname = std.mem.eql(u8, qname_s, "xmlns");
    const is_xmlns_prefix = if (prefix) |p| std.mem.eql(u8, p, "xmlns") else false;
    if ((is_xmlns_qname or is_xmlns_prefix) and
        (namespace == null or !std.mem.eql(u8, namespace.?, "http://www.w3.org/2000/xmlns/")))
    {
        return throwDOMException(c, "NamespaceError", "The xmlns prefix/name must use the XMLNS namespace.");
    }
    // 4. If namespace is XMLNS and neither qualifiedName nor prefix is "xmlns"
    if (namespace) |ns| {
        if (std.mem.eql(u8, ns, "http://www.w3.org/2000/xmlns/") and !is_xmlns_qname and !is_xmlns_prefix) {
            return throwDOMException(c, "NamespaceError", "The XMLNS namespace requires xmlns as prefix or qualified name.");
        }
    }

    const val = jsStringToSlice(c, args[2]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, val.ptr);

    // DOM spec: if an attribute with the same namespace and local name exists,
    // update it (even if the prefix differs). Remove old qualified name first.
    {
        const attr_ns_obj = qjs.JS_GetPropertyStr(c, this_val, "__attrNS");
        defer qjs.JS_FreeValue(c, attr_ns_obj);
        if (!quickjs.JS_IsUndefined(attr_ns_obj) and !quickjs.JS_IsNull(attr_ns_obj)) {
            // Iterate existing attributes to find same ns+localName with different qname
            var attr_it: ?*anyopaque = lxb_dom_element_first_attribute_noi(elem);
            while (attr_it) |attr| {
                var attr_name_len: usize = 0;
                if (lxb_dom_attr_qualified_name(attr, &attr_name_len)) |attr_name_ptr| {
                    const attr_qn = attr_name_ptr[0..attr_name_len];
                    const attr_local = extractLocalName(attr_qn);
                    if (std.mem.eql(u8, attr_local, local_name) and !std.mem.eql(u8, attr_qn, qname_s)) {
                        // Check if namespace matches
                        const stored_ns = qjs.JS_GetPropertyStr(c, attr_ns_obj, attr_name_ptr);
                        defer qjs.JS_FreeValue(c, stored_ns);
                        if (!quickjs.JS_IsUndefined(stored_ns) and !quickjs.JS_IsNull(stored_ns)) {
                            if (jsStringToSlice(c, stored_ns)) |sns| {
                                defer qjs.JS_FreeCString(c, sns.ptr);
                                const stored = sns.ptr[0..sns.len];
                                const req_ns = namespace orelse "";
                                if (std.mem.eql(u8, stored, req_ns)) {
                                    // Same ns+local, different prefix: update value in-place, keep original qname
                                    // Capture old value for MutationObserver
                                    var _ov_ns: [4096]u8 = undefined;
                                    var ov_ns: ?[]const u8 = null;
                                    {
                                        var ovl: usize = 0;
                                        const ovp = lxb_dom_attr_value_noi(attr, &ovl);
                                        if (ovp != null) {
                                            const cl2 = @min(ovl, _ov_ns.len);
                                            @memcpy(_ov_ns[0..cl2], ovp.?[0..cl2]);
                                            ov_ns = _ov_ns[0..cl2];
                                        }
                                    }
                                    _ = lxb_dom_element_set_attribute(elem, attr_qn.ptr, attr_qn.len, val.ptr, val.len);
                                    const node_m: *lxb.lxb_dom_node_t = @ptrCast(elem);
                                    events.recordMutationAttrNS(node_m, local_name, ns_slice, ov_ns);
                                    setDomDirty();
                                    return quickjs.JS_UNDEFINED();
                                }
                            }
                        } else if (namespace == null) {
                            // Both null namespace
                            _ = lxb_dom_element_remove_attribute(elem, attr_qn.ptr, attr_qn.len);
                            break;
                        }
                    }
                }
                attr_it = lxb_dom_element_next_attribute_noi(attr);
            }
        }
    }

    // Capture old value before setting
    var _ov_buf: [4096]u8 = undefined;
    var old_val: ?[]const u8 = null;
    {
        var ov_len: usize = 0;
        const ov_ptr = lxb_dom_element_get_attribute(elem, qname_s.ptr, qname_s.len, &ov_len);
        if (ov_ptr != null) {
            const cl = @min(ov_len, _ov_buf.len);
            @memcpy(_ov_buf[0..cl], ov_ptr.?[0..cl]);
            old_val = _ov_buf[0..cl];
        }
    }
    // Store using the qualified name (prefix:localName) to preserve prefix
    _ = lxb_dom_element_set_attribute(elem, qname_s.ptr, qname_s.len, val.ptr, val.len);

    // Store namespace metadata for isEqualNode attribute comparison
    // __attrNS maps qualifiedName → namespaceURI
    {
        const attr_ns_obj = qjs.JS_GetPropertyStr(c, this_val, "__attrNS");
        const ns_map = if (quickjs.JS_IsUndefined(attr_ns_obj) or quickjs.JS_IsNull(attr_ns_obj)) blk: {
            qjs.JS_FreeValue(c, attr_ns_obj);
            const new_map = qjs.JS_NewObject(c);
            _ = qjs.JS_SetPropertyStr(c, this_val, "__attrNS", qjs.JS_DupValue(c, new_map));
            break :blk new_map;
        } else attr_ns_obj;
        defer qjs.JS_FreeValue(c, ns_map);

        if (namespace) |ns| {
            _ = qjs.JS_SetPropertyStr(c, ns_map, qname_s.ptr, qjs.JS_NewStringLen(c, ns.ptr, ns.len));
        } else {
            _ = qjs.JS_SetPropertyStr(c, ns_map, qname_s.ptr, quickjs.JS_NULL());
        }
    }

    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    events.recordMutationAttrNS(node, local_name, ns_slice, old_val);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

pub fn elementHasAttributeNS(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NewBool(false);
    if (argc < 2) return quickjs.JS_NewBool(false);
    const args = argv orelse return quickjs.JS_NewBool(false);
    const elem = getElement(c, this_val) orelse return quickjs.JS_NewBool(false);
    // args[0] = namespace (nullable), args[1] = localName
    var req_ns: ?[]const u8 = null;
    var req_ns_ptr: ?[*]const u8 = null;
    if (!quickjs.JS_IsNull(args[0]) and !quickjs.JS_IsUndefined(args[0])) {
        if (jsStringToSlice(c, args[0])) |ns_s| {
            req_ns_ptr = ns_s.ptr;
            req_ns = ns_s.ptr[0..ns_s.len];
        }
    }
    defer if (req_ns_ptr) |p| qjs.JS_FreeCString(c, p);
    if (req_ns) |ns| {
        if (ns.len == 0) req_ns = null;
    }
    const local = jsStringToSlice(c, args[1]) orelse return quickjs.JS_NewBool(false);
    defer qjs.JS_FreeCString(c, local.ptr);
    const local_s = local.ptr[0..local.len];

    // Get __attrNS namespace map
    const attr_ns_obj = qjs.JS_GetPropertyStr(c, this_val, "__attrNS");
    defer qjs.JS_FreeValue(c, attr_ns_obj);

    var attr_it: ?*anyopaque = lxb_dom_element_first_attribute_noi(elem);
    while (attr_it) |attr| {
        var attr_name_len: usize = 0;
        if (lxb_dom_attr_qualified_name(attr, &attr_name_len)) |attr_name_ptr| {
            const attr_qname = attr_name_ptr[0..attr_name_len];
            const attr_local = extractLocalName(attr_qname);
            if (std.mem.eql(u8, attr_local, local_s)) {
                // Check namespace match via __attrNS
                if (!quickjs.JS_IsUndefined(attr_ns_obj) and !quickjs.JS_IsNull(attr_ns_obj)) {
                    const ns_val = qjs.JS_GetPropertyStr(c, attr_ns_obj, attr_name_ptr);
                    defer qjs.JS_FreeValue(c, ns_val);
                    if (!quickjs.JS_IsUndefined(ns_val) and !quickjs.JS_IsNull(ns_val)) {
                        if (jsStringToSlice(c, ns_val)) |ns_s| {
                            defer qjs.JS_FreeCString(c, ns_s.ptr);
                            if (req_ns) |rns| {
                                if (std.mem.eql(u8, ns_s.ptr[0..ns_s.len], rns)) return quickjs.JS_NewBool(true);
                            }
                            attr_it = lxb_dom_element_next_attribute_noi(attr);
                            continue;
                        }
                    }
                }
                // No stored namespace — match if req_ns is also null (unprefixed only)
                if (req_ns == null and std.mem.indexOfScalar(u8, attr_qname, ':') == null) return quickjs.JS_NewBool(true);
            }
        }
        attr_it = lxb_dom_element_next_attribute_noi(attr);
    }
    return quickjs.JS_NewBool(false);
}

/// Extract local name from a qualified name (e.g., "foo:bar" → "bar", "bar" → "bar")
fn extractLocalName(qname: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, qname, ':')) |colon| {
        return qname[colon + 1 ..];
    }
    return qname;
}

pub fn elementRemoveAttributeNS(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 2) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const local = jsStringToSlice(c, args[1]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, local.ptr);
    const local_s = local.ptr[0..local.len];
    // Find the attribute by matching local name from qualified names
    var attr_it: ?*anyopaque = lxb_dom_element_first_attribute_noi(elem);
    while (attr_it) |attr| {
        var attr_name_len: usize = 0;
        if (lxb_dom_attr_qualified_name(attr, &attr_name_len)) |attr_name_ptr| {
            const attr_qname = attr_name_ptr[0..attr_name_len];
            const attr_local = extractLocalName(attr_qname);
            if (std.mem.eql(u8, attr_local, local_s)) {
                // Capture old value before removal
                var _ov_buf2: [4096]u8 = undefined;
                var ov2: ?[]const u8 = null;
                {
                    var ov_len: usize = 0;
                    const ov_ptr = lxb_dom_attr_value_noi(attr, &ov_len);
                    if (ov_ptr != null) {
                        const cl = @min(ov_len, _ov_buf2.len);
                        @memcpy(_ov_buf2[0..cl], ov_ptr.?[0..cl]);
                        ov2 = _ov_buf2[0..cl];
                    }
                }
                // Remove by full qualified name
                _ = lxb_dom_element_remove_attribute(elem, attr_qname.ptr, attr_qname.len);
                const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
                // Get namespace from first argument for MutationRecord
                var rm_ns: ?[]const u8 = null;
                var rm_ns_cstr: ?[*]const u8 = null;
                if (!quickjs.JS_IsNull(args[0]) and !quickjs.JS_IsUndefined(args[0])) {
                    if (jsStringToSlice(c, args[0])) |ns_s| {
                        rm_ns_cstr = ns_s.ptr;
                        rm_ns = ns_s.ptr[0..ns_s.len];
                    }
                }
                events.recordMutationAttrNS(node, local_s, rm_ns, ov2);
                if (rm_ns_cstr) |p| qjs.JS_FreeCString(c, p);
                setDomDirty();
                return quickjs.JS_UNDEFINED();
            }
        }
        attr_it = lxb_dom_element_next_attribute_noi(attr);
    }
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
    const name_raw = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, name_raw.ptr);
    var lower_buf: [1024]u8 = undefined;
    const name = lowercaseAttrName(name_raw.ptr[0..name_raw.len], &lower_buf);
    // Capture old value before removal
    var _ov_buf: [4096]u8 = undefined;
    var old_val: ?[]const u8 = null;
    {
        var ov_len: usize = 0;
        const ov_ptr = lxb_dom_element_get_attribute(elem, name.ptr, name.len, &ov_len);
        if (ov_ptr != null) {
            const cl = @min(ov_len, _ov_buf.len);
            @memcpy(_ov_buf[0..cl], ov_ptr.?[0..cl]);
            old_val = _ov_buf[0..cl];
        }
    }
    // DOM spec: removeAttribute is a no-op if attribute doesn't exist
    if (!lxb_dom_element_has_attribute(elem, name.ptr, name.len))
        return quickjs.JS_UNDEFINED();
    _ = lxb_dom_element_remove_attribute(elem, name.ptr, name.len);
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    events.recordMutationWithOldValue(node, "attributes", null, null, name, old_val);
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
    var lower_buf: [1024]u8 = undefined;
    const name = lowercaseAttrName(s.ptr[0..s.len], &lower_buf);
    return quickjs.JS_NewBool(lxb_dom_element_has_attribute(elem, name.ptr, name.len));
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
    // Validate name per DOM spec — browsers only reject empty string
    if (s.len == 0) {
        return throwDOMException(c, "InvalidCharacterError", "The string contains invalid characters.");
    }

    // DOM spec: HTML elements lowercase attribute names
    var lower_buf: [1024]u8 = undefined;
    const name = lowercaseAttrName(s.ptr[0..s.len], &lower_buf);

    const has = lxb_dom_element_has_attribute(elem, name.ptr, name.len);

    // If force argument provided
    if (argc >= 2) {
        const force = qjs.JS_ToBool(c, args[1]) > 0;
        if (force and !has) {
            _ = lxb_dom_element_set_attribute(elem, name.ptr, name.len, "", 0);
            setDomDirty();
            return quickjs.JS_NewBool(true);
        } else if (!force and has) {
            _ = lxb_dom_element_remove_attribute(elem, name.ptr, name.len);
            setDomDirty();
            return quickjs.JS_NewBool(false);
        }
        return quickjs.JS_NewBool(has);
    }

    if (has) {
        _ = lxb_dom_element_remove_attribute(elem, name.ptr, name.len);
        setDomDirty();
        return quickjs.JS_NewBool(false);
    } else {
        _ = lxb_dom_element_set_attribute(elem, name.ptr, name.len, "", 0);
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
    const args = if (argc > 0) (argv orelse return quickjs.JS_UNDEFINED()) else null;

    // Get the element from classList.__element
    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return quickjs.JS_UNDEFINED();

    // DOM §7.1: Validate ALL tokens first before making changes
    var arg_idx: usize = 0;
    if (args) |a| {
        while (arg_idx < @as(usize, @intCast(argc))) : (arg_idx += 1) {
            const token_s = jsStringToSlice(c, a[arg_idx]) orelse return quickjs.JS_UNDEFINED();
            if (validateToken(c, token_s.ptr[0..token_s.len])) |exc| {
                qjs.JS_FreeCString(c, token_s.ptr);
                return exc;
            }
            qjs.JS_FreeCString(c, token_s.ptr);
        }
    }

    // No args + no existing class attribute = no-op
    var cur_len: usize = 0;
    const cur = lxb_dom_element_get_attribute(elem, "class", 5, &cur_len);
    // Save old class value before modification (lexbor invalidates pointer on set)
    var _ocb: [4096]u8 = undefined;
    var old_class_heap: ?[]u8 = null;
    defer if (old_class_heap) |h| std.heap.page_allocator.free(h);
    var old_class_copy: ?[]const u8 = null;
    if (cur != null) {
        if (cur_len <= _ocb.len) {
            @memcpy(_ocb[0..cur_len], cur.?[0..cur_len]);
            old_class_copy = _ocb[0..cur_len];
        } else {
            old_class_heap = std.heap.page_allocator.alloc(u8, cur_len) catch null;
            if (old_class_heap) |h| {
                @memcpy(h, cur.?[0..cur_len]);
                old_class_copy = h;
            }
        }
    }
    if (argc == 0 and (cur == null or cur_len == 0)) return quickjs.JS_UNDEFINED();

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var seen_buf: [128][]const u8 = undefined;
    var seen_count: usize = 0;

    // First, collect existing unique tokens
    if (cur != null and cur_len > 0) {
        var iter = std.mem.tokenizeAny(u8, cur.?[0..cur_len], " \t\n\r\x0c");
        while (iter.next()) |cls| {
            if (cls.len == 0) continue;
            var dup = false;
            for (seen_buf[0..seen_count]) |s| {
                if (std.mem.eql(u8, s, cls)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            if (pos > 0 and pos < buf.len) {
                buf[pos] = ' ';
                pos += 1;
            }
            const copy_len = @min(cls.len, buf.len - pos);
            @memcpy(buf[pos..][0..copy_len], cls[0..copy_len]);
            if (seen_count < seen_buf.len) {
                seen_buf[seen_count] = buf[pos..][0..copy_len];
                seen_count += 1;
            }
            pos += copy_len;
        }
    }

    // Then add new tokens (if not already present)
    arg_idx = 0;
    if (args) |a| {
        while (arg_idx < @as(usize, @intCast(argc))) : (arg_idx += 1) {
            const token_s = jsStringToSlice(c, a[arg_idx]) orelse continue;
            defer qjs.JS_FreeCString(c, token_s.ptr);
            const token = token_s.ptr[0..token_s.len];
            var dup = false;
            for (seen_buf[0..seen_count]) |s| {
                if (std.mem.eql(u8, s, token)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            if (pos > 0 and pos < buf.len) {
                buf[pos] = ' ';
                pos += 1;
            }
            const copy_len = @min(token.len, buf.len - pos);
            @memcpy(buf[pos..][0..copy_len], token[0..copy_len]);
            if (seen_count < seen_buf.len) {
                seen_buf[seen_count] = buf[pos..][0..copy_len];
                seen_count += 1;
            }
            pos += copy_len;
        }
    }

    _ = lxb_dom_element_set_attribute(elem, "class", 5, &buf, pos);
    events.recordMutationWithOldValue(@ptrCast(elem), "attributes", null, null, "class", old_class_copy);
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
    const args = if (argc > 0) (argv orelse return quickjs.JS_UNDEFINED()) else null;

    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return quickjs.JS_UNDEFINED();

    // DOM §7.1: Validate ALL tokens first
    if (args) |a| {
        var arg_idx: usize = 0;
        while (arg_idx < @as(usize, @intCast(argc))) : (arg_idx += 1) {
            const token_s = jsStringToSlice(c, a[arg_idx]) orelse return quickjs.JS_UNDEFINED();
            if (validateToken(c, token_s.ptr[0..token_s.len])) |exc| {
                qjs.JS_FreeCString(c, token_s.ptr);
                return exc;
            }
            qjs.JS_FreeCString(c, token_s.ptr);
        }
    }

    var cur_len: usize = 0;
    const cur = lxb_dom_element_get_attribute(elem, "class", 5, &cur_len);
    var _ocb: [4096]u8 = undefined;
    var old_class_copy: ?[]const u8 = null;
    if (cur != null) {
        const cl = @min(cur_len, _ocb.len);
        @memcpy(_ocb[0..cl], cur.?[0..cl]);
        old_class_copy = _ocb[0..cl];
    }
    if (cur == null or cur_len == 0) return quickjs.JS_UNDEFINED();

    // Collect tokens to remove
    var remove_strs: [32][]const u8 = undefined;
    var remove_ptrs: [32][*]const u8 = undefined;
    var remove_count: usize = 0;
    if (args) |a| {
        var ri: usize = 0;
        while (ri < @as(usize, @intCast(argc)) and remove_count < remove_strs.len) : (ri += 1) {
            const token_s = jsStringToSlice(c, a[ri]) orelse continue;
            remove_ptrs[remove_count] = token_s.ptr;
            remove_strs[remove_count] = token_s.ptr[0..token_s.len];
            remove_count += 1;
        }
    }
    defer for (remove_ptrs[0..remove_count]) |p| qjs.JS_FreeCString(c, p);

    // Rebuild class string without removed classes, also dedup
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var seen_buf: [128][]const u8 = undefined;
    var seen_count: usize = 0;
    var iter = std.mem.tokenizeAny(u8, cur.?[0..cur_len], " \t\n\r\x0c");
    while (iter.next()) |cls| {
        if (cls.len == 0) continue;
        // Skip if in remove list
        var should_remove = false;
        for (remove_strs[0..remove_count]) |rm| {
            if (std.mem.eql(u8, cls, rm)) {
                should_remove = true;
                break;
            }
        }
        if (should_remove) continue;
        // Dedup
        var dup = false;
        for (seen_buf[0..seen_count]) |s| {
            if (std.mem.eql(u8, s, cls)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        if (pos > 0 and pos < buf.len) {
            buf[pos] = ' ';
            pos += 1;
        }
        const copy_len = @min(cls.len, buf.len - pos);
        @memcpy(buf[pos..][0..copy_len], cls[0..copy_len]);
        if (seen_count < seen_buf.len) {
            seen_buf[seen_count] = buf[pos..][0..copy_len];
            seen_count += 1;
        }
        pos += copy_len;
    }
    _ = lxb_dom_element_set_attribute(elem, "class", 5, &buf, pos);
    events.recordMutationWithOldValue(@ptrCast(elem), "attributes", null, null, "class", old_class_copy);
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
    // DOM §7.1 contains() step 1: run validation steps (throws SyntaxError / InvalidCharacterError)
    if (validateToken(c, cls_name.ptr[0..cls_name.len])) |exc| return exc;
    const token = cls_name.ptr[0..cls_name.len];

    var cur_len: usize = 0;
    const cur = lxb_dom_element_get_attribute(elem, "class", 5, &cur_len);
    if (cur == null or cur_len == 0) return quickjs.JS_NewBool(false);
    return quickjs.JS_NewBool(classContains(cur.?[0..cur_len], token));
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

    // DOM spec: Check ALL tokens for empty FIRST (SyntaxError), then whitespace (InvalidCharacterError)
    const old_tok = old_cls.ptr[0..old_cls.len];
    const new_tok = new_cls.ptr[0..new_cls.len];
    if (old_tok.len == 0 or new_tok.len == 0)
        return throwDOMException(c, "SyntaxError", "The token provided must not be empty.");
    for (old_tok) |ch| {
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 0x0c)
            return throwDOMException(c, "InvalidCharacterError", "The token provided contains HTML space characters, which are not valid in tokens.");
    }
    for (new_tok) |ch| {
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 0x0c)
            return throwDOMException(c, "InvalidCharacterError", "The token provided contains HTML space characters, which are not valid in tokens.");
    }

    var cur_len: usize = 0;
    const cur = lxb_dom_element_get_attribute(elem, "class", 5, &cur_len);
    var _ocb: [4096]u8 = undefined;
    var old_class_copy: ?[]const u8 = null;
    if (cur != null) {
        const cl = @min(cur_len, _ocb.len);
        @memcpy(_ocb[0..cl], cur.?[0..cl]);
        old_class_copy = _ocb[0..cl];
    }
    if (cur == null or cur_len == 0) return quickjs.JS_NewBool(false);

    const cur_str = cur.?[0..cur_len];
    if (!classContains(cur_str, old_cls.ptr[0..old_cls.len])) return quickjs.JS_NewBool(false);

    // DOM spec: Replace first occurrence of old with new, remove other old occurrences,
    // and deduplicate (ordered set semantics)
    const old_str = old_cls.ptr[0..old_cls.len];
    const new_str = new_cls.ptr[0..new_cls.len];

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var seen_buf: [128][]const u8 = undefined;
    var seen_count: usize = 0;
    var replaced_first = false;
    var iter = std.mem.tokenizeAny(u8, cur_str, " \t\n\r\x0c");
    while (iter.next()) |tok| {
        if (tok.len == 0) continue;
        var effective_tok = tok;
        if (std.mem.eql(u8, tok, old_str)) {
            if (!replaced_first) {
                // Replace first occurrence of old with new
                effective_tok = new_str;
                replaced_first = true;
            } else {
                // Skip subsequent occurrences of old
                continue;
            }
        }
        // Dedup: skip if already seen
        var dup = false;
        for (seen_buf[0..seen_count]) |s| {
            if (std.mem.eql(u8, s, effective_tok)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        if (pos > 0 and pos < buf.len) {
            buf[pos] = ' ';
            pos += 1;
        }
        if (pos + effective_tok.len <= buf.len) {
            @memcpy(buf[pos..][0..effective_tok.len], effective_tok);
            if (seen_count < seen_buf.len) {
                seen_buf[seen_count] = buf[pos..][0..effective_tok.len];
                seen_count += 1;
            }
            pos += effective_tok.len;
        }
    }
    _ = lxb_dom_element_set_attribute(elem, "class", 5, &buf, pos);
    events.recordMutationWithOldValue(@ptrCast(elem), "attributes", null, null, "class", old_class_copy);
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
            if (std.mem.eql(u8, s, tok)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        if (seen_count < 64) {
            seen[seen_count] = tok;
            seen_count += 1;
        }

        if (pos > 0 and pos < buf.len) {
            buf[pos] = ' ';
            pos += 1;
        }
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
            if (std.mem.eql(u8, s, cls)) {
                dup = true;
                break;
            }
        }
        if (!dup) {
            if (seen_count < 64) {
                seen[seen_count] = cls;
                seen_count += 1;
            }
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
            if (std.mem.eql(u8, s, cls)) {
                dup_fe = true;
                break;
            }
        }
        if (dup_fe) continue;
        if (seen_fe_count < 64) {
            seen_fe[seen_fe_count] = cls;
            seen_fe_count += 1;
        }
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
            if (std.mem.eql(u8, s, cls)) {
                dup = true;
                break;
            }
        }
        if (!dup) {
            if (seen_count < 64) {
                seen[seen_count] = cls;
                seen_count += 1;
            }
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
pub fn classListSetValue(
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
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, s.ptr);
    _ = lxb_dom_element_set_attribute(elem, "class", 5, s.ptr, s.len);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

/// classList setter: element.classList = "foo bar" sets the class attribute
pub fn elementSetClassList(
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
    _ = qjs.JS_SetPropertyStr(ctx, obj, "toString", qjs.JS_NewCFunction(ctx, &classListGetValue, "toString", 0));
    // DOMTokenList spec: inherit keys/values/entries/forEach/Symbol.iterator from Array.prototype
    {
        const iter_js =
            \\(function(cl){
            \\  cl.keys=Array.prototype.keys;
            \\  cl.values=Array.prototype.values||Array.prototype[Symbol.iterator];
            \\  cl.entries=Array.prototype.entries;
            \\  cl.forEach=Array.prototype.forEach;
            \\  cl[Symbol.iterator]=Array.prototype[Symbol.iterator];
            \\})
        ;
        const iter_fn = qjs.JS_Eval(ctx, iter_js, iter_js.len, "<cl-iter>", qjs.JS_EVAL_TYPE_GLOBAL);
        if (!quickjs.JS_IsException(iter_fn)) {
            var iter_args = [1]qjs.JSValue{obj};
            const iter_r = qjs.JS_Call(ctx, iter_fn, quickjs.JS_UNDEFINED(), 1, &iter_args);
            qjs.JS_FreeValue(ctx, iter_r);
            qjs.JS_FreeValue(ctx, iter_fn);
        }
    }

    // length getter
    {
        const lengthAtom = qjs.JS_NewAtom(ctx, "length");
        _ = qjs.JS_DefinePropertyGetSet(ctx, obj, lengthAtom, qjs.JS_NewCFunction(ctx, &classListGetLength, "get length", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, lengthAtom);
    }
    // value getter + setter
    {
        const valueAtom = qjs.JS_NewAtom(ctx, "value");
        _ = qjs.JS_DefinePropertyGetSet(ctx, obj, valueAtom, qjs.JS_NewCFunction(ctx, &classListGetValue, "get value", 0), qjs.JS_NewCFunction(ctx, &classListSetValue, "set value", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, valueAtom);
    }

    // Wrap classList in a Proxy for dynamic indexed access and Symbol.iterator
    const iter_js =
        \\(function(cl){
        \\  cl[Symbol.toStringTag]='DOMTokenList';
        \\  cl._tokens=function(){var e=this.__element;if(!e)return[];var c=e.getAttribute('class');if(!c)return[];var seen={},r=[];c.split(/[\x20\t\n\r\f]+/).forEach(function(s){if(s&&!seen[s]){seen[s]=1;r.push(s);}});return r;};
        \\  return new Proxy(cl,{get:function(t,p,r){if(p==='length'){return t._tokens().length;}if(typeof p==='string'&&/^\d+$/.test(p)){var toks=t._tokens();var i=parseInt(p);return i<toks.length?toks[i]:undefined;}if(p===Symbol.toStringTag)return'DOMTokenList';return Reflect.get(t,p,r);},set:function(t,p,v,r){return Reflect.set(t,p,v,r);},has:function(t,p){if(typeof p==='string'&&/^\d+$/.test(p)){return parseInt(p)<t._tokens().length;}return p in t;}});
        \\})
    ;
    const iter_fn = qjs.JS_Eval(ctx, iter_js, iter_js.len, "<classList>", qjs.JS_EVAL_TYPE_GLOBAL);
    if (!quickjs.JS_IsException(iter_fn)) {
        var call_args = [_]qjs.JSValue{obj};
        const proxy = qjs.JS_Call(ctx, iter_fn, quickjs.JS_UNDEFINED(), 1, &call_args);
        qjs.JS_FreeValue(ctx, iter_fn);
        if (!quickjs.JS_IsException(proxy)) {
            qjs.JS_FreeValue(ctx, obj); // Release original, return Proxy
            return proxy;
        }
        qjs.JS_FreeValue(ctx, proxy);
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
    // Return cached classList for object identity (spec requirement)
    const cached = qjs.JS_GetPropertyStr(c, this_val, "__classList");
    if (!quickjs.JS_IsUndefined(cached) and !quickjs.JS_IsNull(cached)) {
        return cached;
    }
    qjs.JS_FreeValue(c, cached);
    const cl = createClassList(c, this_val);
    _ = qjs.JS_SetPropertyStr(c, this_val, "__classList", qjs.JS_DupValue(c, cl));
    return cl;
}

// ── element.attachShadow() — Shadow DOM v1 Phase 1 ──────────────────
//
// Spec: https://dom.spec.whatwg.org/#dom-element-attachshadow
// Implementation: see src/js/shadow_root.zig for the tree-scope model.

const shadow_root = @import("shadow_root.zig");

pub fn elementAttachShadow(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse
        return qjs.JS_ThrowTypeError(c, "Failed to execute 'attachShadow' on 'Element': receiver is not an Element.");

    // ── Parse init dict ─────────────────────────────────────────────
    var mode: shadow_root.Mode = .open;
    var delegates_focus: bool = false;
    var slot_assignment: shadow_root.SlotAssignment = .named;
    var has_mode: bool = false;

    if (argc >= 1) {
        const args = argv orelse return quickjs.JS_UNDEFINED();
        const init = args[0];
        if (!quickjs.JS_IsUndefined(init) and !quickjs.JS_IsNull(init)) {
            // mode (required per spec for attachShadow)
            const mode_val = qjs.JS_GetPropertyStr(c, init, "mode");
            defer qjs.JS_FreeValue(c, mode_val);
            if (!quickjs.JS_IsUndefined(mode_val)) {
                if (jsStringToSlice(c, mode_val)) |s| {
                    defer qjs.JS_FreeCString(c, s.ptr);
                    const ms = s.ptr[0..s.len];
                    if (std.mem.eql(u8, ms, "open")) {
                        mode = .open;
                        has_mode = true;
                    } else if (std.mem.eql(u8, ms, "closed")) {
                        mode = .closed;
                        has_mode = true;
                    } else {
                        return qjs.JS_ThrowTypeError(c, "Failed to execute 'attachShadow' on 'Element': mode must be 'open' or 'closed'.");
                    }
                }
            }
            const df_val = qjs.JS_GetPropertyStr(c, init, "delegatesFocus");
            defer qjs.JS_FreeValue(c, df_val);
            if (!quickjs.JS_IsUndefined(df_val)) {
                delegates_focus = qjs.JS_ToBool(c, df_val) != 0;
            }
            const sa_val = qjs.JS_GetPropertyStr(c, init, "slotAssignment");
            defer qjs.JS_FreeValue(c, sa_val);
            if (!quickjs.JS_IsUndefined(sa_val) and !quickjs.JS_IsNull(sa_val)) {
                if (jsStringToSlice(c, sa_val)) |s| {
                    defer qjs.JS_FreeCString(c, s.ptr);
                    const sas = s.ptr[0..s.len];
                    if (std.mem.eql(u8, sas, "named")) {
                        slot_assignment = .named;
                    } else if (std.mem.eql(u8, sas, "manual")) {
                        slot_assignment = .manual;
                    } else {
                        return qjs.JS_ThrowTypeError(c, "Failed to execute 'attachShadow' on 'Element': slotAssignment must be 'named' or 'manual'.");
                    }
                }
            }
        }
    }
    if (!has_mode) {
        return qjs.JS_ThrowTypeError(c, "Failed to execute 'attachShadow' on 'Element': options.mode is required.");
    }

    // ── Host allowlist (Spec §4.8) ─────────────────────────────────
    var name_len: usize = 0;
    const name_ptr = lxb_dom_element_local_name(elem, &name_len);
    if (name_ptr == null or name_len == 0) {
        return api.throwDOMException(c, "NotSupportedError", "Element cannot host a shadow root.");
    }
    const local_name = name_ptr.?[0..name_len];
    if (!shadow_root.isAllowedShadowHost(local_name)) {
        return api.throwDOMException(c, "NotSupportedError", "This element cannot host a shadow root.");
    }

    // ── Second-call guard ──────────────────────────────────────────
    if (shadow_root.shadowRootForHost(elem) != null) {
        return api.throwDOMException(c, "NotSupportedError", "Shadow root already attached.");
    }

    // ── Create backing fragment + ShadowRoot struct ────────────────
    const doc = api.getDocument(c) orelse return quickjs.JS_UNDEFINED();
    const sr = shadow_root.create(doc, elem, mode, delegates_focus, slot_assignment) orelse
        return api.throwDOMException(c, "InvalidStateError", "Failed to create shadow root.");

    // ── Build JS wrapper backed by the fragment node ────────────────
    // Using element_class_id lets existing Node/Element methods (appendChild,
    // querySelector, innerHTML, etc.) work against the fragment via getNode.
    const wrapper = qjs.JS_NewObjectClass(c, @intCast(api.element_class_id));
    if (quickjs.JS_IsException(wrapper)) return wrapper;
    _ = qjs.JS_SetOpaque(wrapper, @ptrCast(sr.fragment));

    // Prototype chain: ShadowRoot.prototype (if registered) → Element.prototype
    {
        const global = qjs.JS_GetGlobalObject(c);
        defer qjs.JS_FreeValue(c, global);
        const ctor = qjs.JS_GetPropertyStr(c, global, "ShadowRoot");
        defer qjs.JS_FreeValue(c, ctor);
        if (!quickjs.JS_IsUndefined(ctor)) {
            const proto = qjs.JS_GetPropertyStr(c, ctor, "prototype");
            defer qjs.JS_FreeValue(c, proto);
            if (!quickjs.JS_IsUndefined(proto) and !quickjs.JS_IsNull(proto)) {
                _ = qjs.JS_SetPrototype(c, wrapper, proto);
            }
        }
    }

    // Fixed per-instance attrs.
    _ = qjs.JS_SetPropertyStr(c, wrapper, "host", qjs.JS_DupValue(c, this_val));
    _ = qjs.JS_SetPropertyStr(c, wrapper, "mode", qjs.JS_NewString(c, switch (mode) {
        .open => "open",
        .closed => "closed",
    }));
    _ = qjs.JS_SetPropertyStr(c, wrapper, "delegatesFocus", quickjs.JS_NewBool(delegates_focus));
    _ = qjs.JS_SetPropertyStr(c, wrapper, "slotAssignment", qjs.JS_NewString(c, switch (slot_assignment) {
        .named => "named",
        .manual => "manual",
    }));
    // nodeType 11 (DocumentFragment) — matches the underlying fragment.
    _ = qjs.JS_SetPropertyStr(c, wrapper, "nodeType", qjs.JS_NewInt32(c, 11));
    _ = qjs.JS_SetPropertyStr(c, wrapper, "nodeName", qjs.JS_NewString(c, "#document-fragment"));
    // Marker so getRootNode / isConnected fast-paths can detect shadow root.
    _ = qjs.JS_SetPropertyStr(c, wrapper, "__isShadowRoot", quickjs.JS_NewBool(true));
    _ = qjs.JS_SetPropertyStr(c, wrapper, "__shadowId", qjs.JS_NewInt32(c, @intCast(sr.id)));

    // Expose on host only for open mode (closed is hidden from JS).
    if (mode == .open) {
        _ = qjs.JS_SetPropertyStr(c, this_val, "shadowRoot", qjs.JS_DupValue(c, wrapper));
    } else {
        _ = qjs.JS_SetPropertyStr(c, this_val, "shadowRoot", quickjs.JS_NULL());
    }
    return wrapper;
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

    // Validate position FIRST before detaching (avoid orphaning on invalid position)
    const is_before_begin = std.ascii.eqlIgnoreCase(position, "beforebegin");
    const is_after_begin = std.ascii.eqlIgnoreCase(position, "afterbegin");
    const is_before_end = std.ascii.eqlIgnoreCase(position, "beforeend");
    const is_after_end = std.ascii.eqlIgnoreCase(position, "afterend");

    if (!is_before_begin and !is_after_begin and !is_before_end and !is_after_end) {
        return throwDOMException(c, "SyntaxError", "An invalid or illegal string was specified.");
    }
    // Check parent exists for beforebegin/afterend before detaching
    if (is_before_begin or is_after_end) {
        if (node.parent == null) return quickjs.JS_NULL();
    }
    // DOM spec: Document can only have one Element child
    // Determine the parent node for the insertion
    const parent_node: ?*lxb.lxb_dom_node_t = if (is_before_begin or is_after_end) node.parent else node;
    if (parent_node) |pn| {
        if (pn.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT and new_node.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            // Check if document already has an element child
            var child: ?*lxb.lxb_dom_node_t = pn.first_child;
            while (child) |ch| {
                if (ch.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
                    return throwDOMException(c, "HierarchyRequestError", "The operation would yield an incorrect node tree.");
                }
                child = ch.next;
            }
        }
    }

    // Now safe to detach from old parent
    if (new_node.parent != null) lxb_dom_node_remove(new_node);

    if (is_before_begin) {
        lxb_dom_node_insert_before(node, new_node);
    } else if (is_after_begin) {
        if (node.first_child) |first| {
            lxb_dom_node_insert_before(first, new_node);
        } else {
            lxb_dom_node_insert_child(node, new_node);
        }
    } else if (is_before_end) {
        lxb_dom_node_insert_child(node, new_node);
    } else { // is_after_end
        lxb_dom_node_insert_after(node, new_node);
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

    // Validate position first
    const is_before_begin = std.ascii.eqlIgnoreCase(position, "beforebegin");
    const is_after_end = std.ascii.eqlIgnoreCase(position, "afterend");
    const is_after_begin = std.ascii.eqlIgnoreCase(position, "afterbegin");
    const is_before_end = std.ascii.eqlIgnoreCase(position, "beforeend");
    if (!is_before_begin and !is_after_begin and !is_before_end and !is_after_end) {
        return throwDOMException(c, "SyntaxError", "An invalid or illegal string was specified.");
    }

    // DOM spec: Document cannot have Text children
    const parent_node: ?*lxb.lxb_dom_node_t = if (is_before_begin or is_after_end) node.parent else node;
    if (parent_node) |pn| {
        if (pn.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT) {
            return throwDOMException(c, "HierarchyRequestError", "The operation would yield an incorrect node tree.");
        }
    }

    const text_node = lxb_dom_document_create_text_node(doc, text_s.ptr, text_s.len) orelse return quickjs.JS_UNDEFINED();

    if (is_before_begin) {
        if (node.parent == null) return quickjs.JS_UNDEFINED();
        lxb_dom_node_insert_before(node, text_node);
    } else if (is_after_begin) {
        if (node.first_child) |first| {
            lxb_dom_node_insert_before(first, text_node);
        } else {
            lxb_dom_node_insert_child(node, text_node);
        }
    } else if (is_before_end) {
        lxb_dom_node_insert_child(node, text_node);
    } else { // is_after_end
        if (node.parent == null) return quickjs.JS_UNDEFINED();
        lxb_dom_node_insert_after(node, text_node);
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
    // Create a Proxy-based DOMStringMap that intercepts property access
    const ds_js =
        \\(function(el){
        \\  function toAttr(k){
        \\    var r='data-';
        \\    for(var i=0;i<k.length;i++){
        \\      var ch=k[i];
        \\      if(ch>='A'&&ch<='Z')r+='-'+ch.toLowerCase();
        \\      else r+=ch;
        \\    }
        \\    return r;
        \\  }
        \\  function toKey(a){
        \\    var s=a.slice(5),r='',up=false;
        \\    for(var i=0;i<s.length;i++){
        \\      if(s[i]==='-'){up=true;}
        \\      else if(up){r+=s[i].toUpperCase();up=false;}
        \\      else r+=s[i];
        \\    }
        \\    if(up)r+='-';
        \\    return r;
        \\  }
        \\  function getKeys(){
        \\    var k=[],attrs=el.attributes;
        \\    if(attrs)for(var i=0;i<attrs.length;i++){
        \\      var n=attrs[i].name;
        \\      if(n.length>=5&&n.substring(0,5)==='data-')k.push(toKey(n));
        \\    }
        \\    return k;
        \\  }
        \\  var h={
        \\    get:function(t,p){
        \\      if(typeof p!=='string')return t[p];
        \\      var v=el.getAttribute(toAttr(p));
        \\      return v;
        \\    },
        \\    set:function(t,p,v){
        \\      if(typeof p!=='string')return false;
        \\      el.setAttribute(toAttr(p),''+v);return true;
        \\    },
        \\    has:function(t,p){
        \\      if(typeof p!=='string')return p in t;
        \\      return el.hasAttribute(toAttr(p));
        \\    },
        \\    deleteProperty:function(t,p){
        \\      if(typeof p!=='string')return false;
        \\      el.removeAttribute(toAttr(p));return true;
        \\    },
        \\    ownKeys:function(){
        \\      var attrs=el.getAttributeNames?el.getAttributeNames():[];
        \\      var k=[];
        \\      for(var i=0;i<attrs.length;i++){
        \\        var n=attrs[i];
        \\        if(n.length>=5&&n.substring(0,5)==='data-')k.push(toKey(n));
        \\      }
        \\      return k;
        \\    },
        \\    getOwnPropertyDescriptor:function(t,p){
        \\      if(typeof p!=='string')return undefined;
        \\      var v=el.getAttribute(toAttr(p));
        \\      if(v!==null)return{value:v,writable:true,enumerable:true,configurable:true};
        \\      return undefined;
        \\    },
        \\    getPrototypeOf:function(){return typeof DOMStringMap!=='undefined'?DOMStringMap.prototype:Object.prototype;}
        \\  };
        \\  return new Proxy({},h);
        \\})
    ;
    const fn_val = qjs.JS_Eval(c, ds_js, ds_js.len, "<dataset>", qjs.JS_EVAL_TYPE_GLOBAL);
    if (quickjs.JS_IsException(fn_val)) return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeValue(c, fn_val);
    var call_args = [1]qjs.JSValue{this_val};
    return qjs.JS_Call(c, fn_val, quickjs.JS_UNDEFINED(), 1, &call_args);
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

// ── href property (reflected string attribute) ──────────────────────

pub fn elementGetHref(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_UNDEFINED();
    var attr_len: usize = 0;
    const attr_ptr = lxb_dom_element_get_attribute(elem, "href", 4, &attr_len);
    if (attr_ptr == null) return qjs.JS_NewStringLen(c, "", 0);
    return qjs.JS_NewStringLen(c, attr_ptr, attr_len);
}

pub fn elementSetHref(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_UNDEFINED();

    const s = api.jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, s.ptr);
    _ = lxb_dom_element_set_attribute(elem, "href", 4, s.ptr, s.len);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

// ── disabled property (reflected boolean attribute) ─────────────────

pub fn elementGetDisabled(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_NewBool(false);
    var attr_len: usize = 0;
    const attr_ptr = lxb_dom_element_get_attribute(elem, "disabled", 8, &attr_len);
    return quickjs.JS_NewBool(attr_ptr != null);
}

pub fn elementSetDisabled(
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
        _ = lxb_dom_element_set_attribute(elem, "disabled", 8, "", 0);
    } else {
        _ = lxb_dom_element_remove_attribute(elem, "disabled", 8);
    }
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

// ── Per-element scroll state (CSSOM View §6.5) ──────────────────────
//
// Keyed on the lxb_dom_element_t pointer (as usize).  Entries are
// created on first write; missing entry → position is (0, 0).

const ElemScrollPos = struct { top: f32, left: f32 };

/// Global map: element ptr → scroll position.  Allocated lazily with
/// the page allocator; lives for the lifetime of the process.
var g_elem_scroll: ?std.AutoHashMap(usize, ElemScrollPos) = null;

fn ensureScrollMap() *std.AutoHashMap(usize, ElemScrollPos) {
    if (g_elem_scroll == null) {
        g_elem_scroll = std.AutoHashMap(usize, ElemScrollPos).init(std.heap.page_allocator);
    }
    return &g_elem_scroll.?;
}

/// Returns true if the element has a scrollable overflow on either axis.
/// Per CSSOM View §6.5: scroll(), scrollTo(), scrollBy() are no-ops on
/// non-scrollable elements (overflow != scroll|auto on x or y).
fn isScrollableElement(c: *qjs.JSContext, elem: *lxb.lxb_dom_element_t) bool {
    const styles = api.getStylesForCtx(c) orelse return false;
    const cs = styles.get(@intFromPtr(elem)) orelse return false;
    const scrollable_x = cs.overflow_x == .scroll or cs.overflow_x == .auto_;
    const scrollable_y = cs.overflow_y == .scroll or cs.overflow_y == .auto_;
    return scrollable_x or scrollable_y;
}

/// Parse (x, y) or ({top, left, behavior}) from JS args into (left, top).
/// Returns null if args are empty/invalid.
fn parseScrollArgs(
    c: *qjs.JSContext,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) ?struct { left: f32, top: f32 } {
    if (argc < 1) return null;
    const args = argv orelse return null;
    if (argc >= 2) {
        var x: f64 = 0;
        var y: f64 = 0;
        _ = qjs.JS_ToFloat64(c, &x, args[0]);
        _ = qjs.JS_ToFloat64(c, &y, args[1]);
        return .{ .left = @floatCast(x), .top = @floatCast(y) };
    }
    // Single options object: { top?, left?, behavior? }
    const opts = args[0];
    var left: f64 = 0;
    var top: f64 = 0;
    var has_left = false;
    var has_top = false;
    const top_val = qjs.JS_GetPropertyStr(c, opts, "top");
    const left_val = qjs.JS_GetPropertyStr(c, opts, "left");
    defer qjs.JS_FreeValue(c, top_val);
    defer qjs.JS_FreeValue(c, left_val);
    if (!quickjs.JS_IsUndefined(top_val)) {
        _ = qjs.JS_ToFloat64(c, &top, top_val);
        has_top = true;
    }
    if (!quickjs.JS_IsUndefined(left_val)) {
        _ = qjs.JS_ToFloat64(c, &left, left_val);
        has_left = true;
    }
    if (!has_top and !has_left) return null;
    return .{ .left = @floatCast(left), .top = @floatCast(top) };
}

// ── Scroll getters ──────────────────────────────────────────────────

pub fn elementGetScrollTop(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return qjs.JS_NewInt32(c, 0);
    const map = ensureScrollMap();
    const pos = map.get(@intFromPtr(elem)) orelse return qjs.JS_NewInt32(c, 0);
    return qjs.JS_NewInt32(c, @intFromFloat(pos.top));
}

pub fn elementGetScrollLeft(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return qjs.JS_NewInt32(c, 0);
    const map = ensureScrollMap();
    const pos = map.get(@intFromPtr(elem)) orelse return qjs.JS_NewInt32(c, 0);
    return qjs.JS_NewInt32(c, @intFromFloat(pos.left));
}

// ── Scroll setters ──────────────────────────────────────────────────

pub fn elementSetScrollTop(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_UNDEFINED();
    if (!isScrollableElement(c, elem)) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    var y: f64 = 0;
    _ = qjs.JS_ToFloat64(c, &y, args[0]);
    const new_top: f32 = @floatCast(@max(0.0, y));
    const map = ensureScrollMap();
    const key = @intFromPtr(elem);
    const existing = map.get(key) orelse ElemScrollPos{ .top = 0, .left = 0 };
    map.put(key, .{ .top = new_top, .left = existing.left }) catch {};
    return quickjs.JS_UNDEFINED();
}

pub fn elementSetScrollLeft(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_UNDEFINED();
    if (!isScrollableElement(c, elem)) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    var x: f64 = 0;
    _ = qjs.JS_ToFloat64(c, &x, args[0]);
    const new_left: f32 = @floatCast(@max(0.0, x));
    const map = ensureScrollMap();
    const key = @intFromPtr(elem);
    const existing = map.get(key) orelse ElemScrollPos{ .top = 0, .left = 0 };
    map.put(key, .{ .top = existing.top, .left = new_left }) catch {};
    return quickjs.JS_UNDEFINED();
}

// ── Element.scroll / scrollTo / scrollBy (CSSOM View §6.5) ──────────

/// Shared implementation for scroll() / scrollTo():
/// Sets absolute scroll position. No-op for non-scrollable elements.
/// Clamps to [0, +∞) (lower bound per spec; upper bound would need
/// scrollWidth/scrollHeight, which currently mirrors clientWidth/Height).
fn elementScrollToImpl(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_UNDEFINED();
    if (!isScrollableElement(c, elem)) return quickjs.JS_UNDEFINED();
    const parsed = parseScrollArgs(c, argc, argv) orelse return quickjs.JS_UNDEFINED();
    const new_left: f32 = @max(0.0, parsed.left);
    const new_top: f32 = @max(0.0, parsed.top);
    ensureScrollMap().put(@intFromPtr(elem), .{ .top = new_top, .left = new_left }) catch {};
    return quickjs.JS_UNDEFINED();
}

pub fn elementScroll(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    return elementScrollToImpl(ctx, this_val, argc, argv);
}

pub fn elementScrollTo(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    return elementScrollToImpl(ctx, this_val, argc, argv);
}

pub fn elementScrollBy(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_UNDEFINED();
    if (!isScrollableElement(c, elem)) return quickjs.JS_UNDEFINED();
    const delta = parseScrollArgs(c, argc, argv) orelse return quickjs.JS_UNDEFINED();
    const key = @intFromPtr(elem);
    const map = ensureScrollMap();
    const cur = map.get(key) orelse ElemScrollPos{ .top = 0, .left = 0 };
    const new_left: f32 = @max(0.0, cur.left + delta.left);
    const new_top: f32 = @max(0.0, cur.top + delta.top);
    map.put(key, .{ .top = new_top, .left = new_left }) catch {};
    return quickjs.JS_UNDEFINED();
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
    const root = api.getRootBox(ctx) orelse return null;
    const node = getNodeFromThis(ctx, this_val) orelse return null;
    return findBoxForNode(root, node);
}

pub fn getNodeFromThis(ctx: *qjs.JSContext, this_val: qjs.JSValue) ?*lxb.lxb_dom_node_t {
    _ = ctx;
    // Try element class first, then text class (use JS_GetOpaque to avoid TypeError)
    const ptr1 = qjs.JS_GetOpaque(this_val, api.element_class_id);
    if (ptr1) |p| return @ptrCast(@alignCast(p));
    const ptr2 = qjs.JS_GetOpaque(this_val, api.text_class_id);
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
        // CSSOM View §6.5: offsetWidth is border-box width rounded to nearest integer.
        return qjs.JS_NewInt32(c, @intFromFloat(@round(bbox.width)));
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
        // CSSOM View §6.5: offsetHeight is the border-box height rounded to the
        // nearest integer (not truncated). Use @round so sub-pixel values like
        // 12.5 → 13 rather than 12.
        return qjs.JS_NewInt32(c, @intFromFloat(@round(bbox.height)));
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

// ── HTMLFormElement.submit() / requestSubmit() ───────────────────────
// HTML Living Standard §4.10.21.3 "Form submission"

/// HTMLFormElement.submit() — bypasses validation and submit event (per spec).
/// No-op if the form is not connected to a document.
pub fn formSubmit(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    // Per spec: if form is not connected, return early.
    const conn = qjs.JS_GetPropertyStr(c, this_val, "isConnected");
    const is_connected = qjs.JS_ToBool(c, conn) > 0;
    qjs.JS_FreeValue(c, conn);
    if (!is_connected) return quickjs.JS_UNDEFINED();
    // Navigation / network layer is not yet wired in this test harness;
    // fire a non-cancelable synthetic submit so JS observers can react.
    const js_code =
        \\(function(form){
        \\  var ev;
        \\  try { ev = new SubmitEvent('submit', {bubbles:true, cancelable:false, submitter:null}); }
        \\  catch(e) { ev = new Event('submit', {bubbles:true, cancelable:false}); ev.submitter=null; }
        \\  form.dispatchEvent(ev);
        \\})
    ;
    const fn_val = qjs.JS_Eval(c, js_code, js_code.len, "<form-submit>", qjs.JS_EVAL_TYPE_GLOBAL);
    if (!quickjs.JS_IsException(fn_val)) {
        var args = [_]qjs.JSValue{this_val};
        const result = qjs.JS_Call(c, fn_val, quickjs.JS_UNDEFINED(), 1, &args);
        qjs.JS_FreeValue(c, result);
    }
    qjs.JS_FreeValue(c, fn_val);
    return quickjs.JS_UNDEFINED();
}

/// HTMLFormElement.requestSubmit(submitter?) — dispatches cancelable submit event,
/// then runs the submit algorithm if not prevented (HTML §4.10.21.3).
/// No-op if the form is not connected. Throws TypeError for wrong-form submitter.
pub fn formRequestSubmit(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    // Per spec: if form is not connected, return early.
    const conn = qjs.JS_GetPropertyStr(c, this_val, "isConnected");
    const is_connected = qjs.JS_ToBool(c, conn) > 0;
    qjs.JS_FreeValue(c, conn);
    if (!is_connected) return quickjs.JS_UNDEFINED();

    // Validate optional submitter argument.
    const submitter_val: qjs.JSValue = if (argc >= 1 and argv != null)
        argv.?[0]
    else
        quickjs.JS_NULL();

    // If submitter provided (not null/undefined), verify it belongs to this form.
    if (!quickjs.JS_IsNull(submitter_val) and !quickjs.JS_IsUndefined(submitter_val)) {
        // submitter.form must === this form (per spec)
        const submitter_form = qjs.JS_GetPropertyStr(c, submitter_val, "form");
        const same = qjs.JS_IsStrictEqual(c, submitter_form, this_val);
        qjs.JS_FreeValue(c, submitter_form);
        if (!same) {
            // Throw TypeError per spec: submitter must be a button in this form.
            return throwDOMException(c, "TypeError", "The specified element is not owned by this form element.");
        }
    }

    // Dispatch cancelable submit event; run submit algorithm if not prevented.
    const js_code =
        \\(function(form, submitter){
        \\  var ev;
        \\  var sub = (submitter===null||submitter===undefined)?null:submitter;
        \\  try { ev = new SubmitEvent('submit', {bubbles:true, cancelable:true, submitter:sub}); }
        \\  catch(e) { ev = new Event('submit', {bubbles:true, cancelable:true}); ev.submitter=sub; }
        \\  var notCanceled = form.dispatchEvent(ev);
        \\  // If not canceled, proceed with submission (navigation not yet wired).
        \\  return notCanceled;
        \\})
    ;
    const fn_val = qjs.JS_Eval(c, js_code, js_code.len, "<form-requestsubmit>", qjs.JS_EVAL_TYPE_GLOBAL);
    if (!quickjs.JS_IsException(fn_val)) {
        var args = [_]qjs.JSValue{ this_val, submitter_val };
        const result = qjs.JS_Call(c, fn_val, quickjs.JS_UNDEFINED(), 2, &args);
        qjs.JS_FreeValue(c, result);
    }
    qjs.JS_FreeValue(c, fn_val);
    return quickjs.JS_UNDEFINED();
}

// ── Constraint validation API ────────────────────────────────────────
// HTML Living Standard §4.10.18 "Constraint validation"

/// HTMLInputElement/TextAreaElement/etc. checkValidity() — §4.10.18.4
/// Returns false and fires a non-bubbling cancelable "invalid" event when
/// the element suffers from a validity constraint violation. Returns true
/// otherwise.
pub fn formControlCheckValidity(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    // Read the element's internal validity state object (set by the JS polyfill).
    // The polyfill stores `_customError` and validity flags on the element.
    // A simpler strategy: evaluate willValidate first; if false always return true.
    const wv = qjs.JS_GetPropertyStr(c, this_val, "willValidate");
    const will_validate = qjs.JS_ToBool(c, wv) > 0;
    qjs.JS_FreeValue(c, wv);
    if (!will_validate) return qjs.JS_NewBool(c, true);

    // Check validity.valid
    const validity = qjs.JS_GetPropertyStr(c, this_val, "validity");
    const valid_prop = qjs.JS_GetPropertyStr(c, validity, "valid");
    const is_valid = qjs.JS_ToBool(c, valid_prop) > 0;
    qjs.JS_FreeValue(c, valid_prop);
    qjs.JS_FreeValue(c, validity);

    if (is_valid) return qjs.JS_NewBool(c, true);

    // Fire "invalid" event — non-bubbling, cancelable (§4.10.18.4 step 3).
    const js_code =
        \\(function(el){
        \\  var ev = new Event('invalid', {bubbles:false, cancelable:true});
        \\  el.dispatchEvent(ev);
        \\})
    ;
    const fn_val = qjs.JS_Eval(c, js_code, js_code.len, "<checkValidity>", qjs.JS_EVAL_TYPE_GLOBAL);
    if (!quickjs.JS_IsException(fn_val)) {
        var args = [_]qjs.JSValue{this_val};
        const r = qjs.JS_Call(c, fn_val, quickjs.JS_UNDEFINED(), 1, &args);
        qjs.JS_FreeValue(c, r);
    }
    qjs.JS_FreeValue(c, fn_val);
    return qjs.JS_NewBool(c, false);
}

/// HTMLInputElement/etc. reportValidity() — §4.10.18.4
/// Same as checkValidity() but also shows a validation UI message (not yet
/// implemented; we match the return value contract). Returns true if valid.
pub fn formControlReportValidity(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    // Per spec reportValidity is identical to checkValidity in terms of return
    // value and invalid-event firing; the only difference is optional UI which
    // we omit. Delegate to checkValidity.
    return formControlCheckValidity(ctx, this_val, argc, argv);
}

/// HTMLFormElement.checkValidity() — §4.10.21.2 "statically validate the
/// constraints": fires invalid events on each invalid submittable element,
/// returns false if any are invalid.
pub fn formCheckValidity(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    // Collect submittable elements via querySelectorAll and call checkValidity
    // on each; if any returns false the form is invalid.
    const js_code =
        \\(function(form){
        \\  var els = form.querySelectorAll('input,select,textarea,button');
        \\  var allValid = true;
        \\  for(var i=0;i<els.length;i++){
        \\    var el=els[i];
        \\    if(typeof el.checkValidity==='function'){
        \\      if(!el.checkValidity()) allValid=false;
        \\    }
        \\  }
        \\  return allValid;
        \\})
    ;
    const fn_val = qjs.JS_Eval(c, js_code, js_code.len, "<form-checkValidity>", qjs.JS_EVAL_TYPE_GLOBAL);
    if (quickjs.JS_IsException(fn_val)) return fn_val;
    var args = [_]qjs.JSValue{this_val};
    const result = qjs.JS_Call(c, fn_val, quickjs.JS_UNDEFINED(), 1, &args);
    qjs.JS_FreeValue(c, fn_val);
    return result;
}

/// HTMLFormElement.reportValidity() — §4.10.21.2
/// Same as checkValidity() but additionally shows validation UI.
pub fn formReportValidity(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    return formCheckValidity(ctx, this_val, argc, argv);
}

/// input.setCustomValidity(message) — §4.10.18.5
/// Sets or clears a custom validity message on the element.
/// Empty string clears (element becomes valid); non-empty sets customError.
pub fn formControlSetCustomValidity(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const msg_val: qjs.JSValue = if (argc >= 1 and argv != null)
        argv.?[0]
    else
        qjs.JS_NewString(c, "");
    // Store message on element as _customValidationMessage; the JS polyfill
    // uses this to reflect validity.customError and validationMessage.
    _ = qjs.JS_SetPropertyStr(c, this_val, "_customValidationMessage", qjs.JS_DupValue(c, msg_val));
    // Invalidate the cached validity object so next access recomputes.
    _ = qjs.JS_DeleteProperty(c, this_val, qjs.JS_NewAtom(c, "_validityCache"), 0);
    return quickjs.JS_UNDEFINED();
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
