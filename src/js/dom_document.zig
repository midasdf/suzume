const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;
const lxb = @import("../bindings/lexbor.zig").c;
const api = @import("dom_api.zig");
const events = @import("events.zig");

// ── External Lexbor functions ────────────────────────────────────────
extern fn lxb_dom_document_create_element(document: *anyopaque, local_name: [*]const u8, lname_len: usize, reserved: ?*anyopaque) ?*lxb.lxb_dom_element_t;
/// Validate an HTML element name per HTML spec §13.1.2.1
/// HTML createElement: validate per XML Name production (slightly stricter than browsers,
/// but avoids crashes with truly invalid names in lexbor).
fn isValidElementName(name: []const u8) bool {
    return isValidXmlName(name);
}

pub extern fn lxb_dom_document_create_text_node(document: *anyopaque, data: [*]const u8, len: usize) ?*lxb.lxb_dom_node_t;
extern fn lxb_dom_document_create_comment(document: *anyopaque, data: [*]const u8, len: usize) ?*lxb.lxb_dom_node_t;
extern fn lxb_dom_node_insert_child(to: *lxb.lxb_dom_node_t, node: *lxb.lxb_dom_node_t) void;
extern fn lxb_dom_node_insert_before(to: *lxb.lxb_dom_node_t, node: *lxb.lxb_dom_node_t) void;
extern fn lxb_dom_node_remove(node: *lxb.lxb_dom_node_t) void;
extern fn lxb_dom_node_destroy(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t;
extern fn lxb_dom_node_text_content(node: *lxb.lxb_dom_node_t, len: *usize) ?[*]const u8;
pub extern fn lxb_dom_element_local_name(element: *lxb.lxb_dom_element_t, len: *usize) ?[*]const u8;
extern fn lxb_dom_element_get_attribute(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize, value_len: *usize) ?[*]const u8;
extern fn lxb_html_document_parse_fragment(document: *anyopaque, element: *lxb.lxb_dom_element_t, html: [*]const u8, size: usize) ?*lxb.lxb_dom_node_t;

// ── Helpers (delegated to dom_api) ───────────────────────────────────

fn wrapNode(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) qjs.JSValue {
    return api.wrapNode(ctx, node);
}

const StringSlice = @typeInfo(@typeInfo(@TypeOf(api.jsStringToSlice)).@"fn".return_type.?).optional.child;

fn jsStringToSlice(ctx: *qjs.JSContext, val: qjs.JSValue) ?StringSlice {
    return api.jsStringToSlice(ctx, val);
}

fn throwDOMException(c: *qjs.JSContext, name: []const u8, message: []const u8) qjs.JSValue {
    return api.throwDOMException(c, name, message);
}

fn classContains(class_str: []const u8, needle: []const u8) bool {
    return api.classContains(class_str, needle);
}

// ── Document functions ───────────────────────────────────────────────

pub fn documentCreateComment(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    const doc = api.getDocument(c) orelse return quickjs.JS_NULL();

    // Get the data string (default to empty)
    var data_ptr: [*]const u8 = "";
    var data_len: usize = 0;
    if (argc >= 1) {
        if (argv) |args| {
            if (jsStringToSlice(c, args[0])) |s| {
                data_ptr = s.ptr;
                data_len = s.len;
            }
        }
    }
    const comment_node = lxb_dom_document_create_comment(doc, data_ptr, data_len) orelse {
        if (data_len > 0) qjs.JS_FreeCString(c, data_ptr);
        return quickjs.JS_NULL();
    };
    const result = wrapNode(c, comment_node);
    if (data_len > 0) qjs.JS_FreeCString(c, data_ptr);
    return result;
}

pub fn documentAdoptNode(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const node_val = args[0];

    // DOM spec: throw NotSupportedError for Document nodes
    const nt = qjs.JS_GetPropertyStr(c, node_val, "nodeType");
    defer qjs.JS_FreeValue(c, nt);
    var node_type: i32 = 0;
    _ = qjs.JS_ToInt32(c, &node_type, nt);
    if (node_type == 9) { // DOCUMENT_NODE
        return throwDOMException(c, "NotSupportedError", "Cannot adopt a document node.");
    }

    // Remove from parent if it has one (both Lexbor DOM and JS-level)
    const node_opt = api.getNode(c, node_val);
    if (node_opt) |node| {
        if (node.parent != null) {
            lxb_dom_node_remove(node);
        }
    } else {
        // JS-level Document constructor nodes: remove via JS parentNode
        const parent_val = qjs.JS_GetPropertyStr(c, node_val, "parentNode");
        defer qjs.JS_FreeValue(c, parent_val);
        if (!quickjs.JS_IsNull(parent_val) and !quickjs.JS_IsUndefined(parent_val)) {
            const remove_fn = qjs.JS_GetPropertyStr(c, parent_val, "removeChild");
            defer qjs.JS_FreeValue(c, remove_fn);
            if (!quickjs.JS_IsUndefined(remove_fn)) {
                var rm_args = [1]qjs.JSValue{qjs.JS_DupValue(c, node_val)};
                const rm_result = qjs.JS_Call(c, remove_fn, parent_val, 1, &rm_args);
                qjs.JS_FreeValue(c, rm_result);
                qjs.JS_FreeValue(c, rm_args[0]);
            }
        }
    }

    // DOM spec: set ownerDocument on node and all descendants to the adopting document
    // this_val is the document object calling adoptNode
    // For the main document, use document; otherwise use the JS document object
    const doc_val = blk: {
        // Check if this_val has nodeType=9 (it's a document)
        const this_nt = qjs.JS_GetPropertyStr(c, this_val, "nodeType");
        defer qjs.JS_FreeValue(c, this_nt);
        var this_node_type: i32 = 0;
        _ = qjs.JS_ToInt32(c, &this_node_type, this_nt);
        if (this_node_type == 9) {
            break :blk qjs.JS_DupValue(c, this_val);
        }
        // Fallback to global document
        const global = qjs.JS_GetGlobalObject(c);
        defer qjs.JS_FreeValue(c, global);
        break :blk qjs.JS_GetPropertyStr(c, global, "document");
    };
    defer qjs.JS_FreeValue(c, doc_val);

    // Recursively set ownerDocument on node and all descendants
    setOwnerDocumentRecursive(c, node_val, doc_val);

    // Set parentNode to null (adoption removes from parent)
    _ = qjs.JS_SetPropertyStr(c, node_val, "parentNode", quickjs.JS_NULL());

    return qjs.JS_DupValue(c, node_val);
}

/// Recursively set ownerDocument on a node and all its descendants.
fn setOwnerDocumentRecursive(ctx: *qjs.JSContext, node: qjs.JSValue, doc: qjs.JSValue) void {
    _ = qjs.JS_SetPropertyStr(ctx, node, "ownerDocument", qjs.JS_DupValue(ctx, doc));

    // Recurse into childNodes
    const children = qjs.JS_GetPropertyStr(ctx, node, "childNodes");
    defer qjs.JS_FreeValue(ctx, children);
    if (quickjs.JS_IsUndefined(children) or quickjs.JS_IsNull(children)) return;

    const len_val = qjs.JS_GetPropertyStr(ctx, children, "length");
    defer qjs.JS_FreeValue(ctx, len_val);
    var len: i32 = 0;
    _ = qjs.JS_ToInt32(ctx, &len, len_val);

    var i: i32 = 0;
    while (i < len) : (i += 1) {
        const child = qjs.JS_GetPropertyUint32(ctx, children, @intCast(i));
        defer qjs.JS_FreeValue(ctx, child);
        if (!quickjs.JS_IsUndefined(child) and !quickjs.JS_IsNull(child)) {
            setOwnerDocumentRecursive(ctx, child, doc);
        }
    }
}

/// Check if a byte is an ASCII character that is INVALID in XML Name start position.
/// Per XML spec + browser implementations: digits, hyphen, dot, and special ASCII symbols
/// at the start are invalid. Letters, underscore, colon, and non-ASCII are valid.
pub fn isInvalidNameStartChar(ch: u8) bool {
    if (ch >= 0x80) return false; // non-ASCII: valid (UTF-8 continuation or lead)
    if (std.ascii.isAlphabetic(ch)) return false;
    if (ch == '_' or ch == ':') return false;
    return true; // digits, special chars like <, >, space, etc.
}

/// Check if a byte is an ASCII character that is INVALID in XML Name continuation position.
/// Most ASCII special chars are allowed in names by browsers (lenient parsing),
/// except for a specific set of clearly invalid characters.
pub fn isInvalidNameChar(ch: u8) bool {
    if (ch >= 0x80) return false; // non-ASCII: valid
    if (std.ascii.isAlphanumeric(ch)) return false;
    if (ch == '_' or ch == ':' or ch == '-' or ch == '.') return false;
    // Characters that are definitely invalid per all browser implementations:
    // Note: < is allowed in continuation position by browsers; > is always invalid
    return switch (ch) {
        ' ',
        '\t',
        '\n',
        '\r',
        '>',
        '/',
        '=',
        '"',
        '\'',
        '^',
        '!',
        '@',
        '#',
        '$',
        '%',
        '&',
        '*',
        '(',
        ')',
        '+',
        '[',
        ']',
        '\\',
        ';',
        '`',
        ',',
        '~',
        => true,
        else => false, // other chars like {, }, |, ?, <, > — browsers allow these in names
    };
}

/// Validate an XML Name production (lenient, matching browser behavior).
pub fn isValidXmlName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (isInvalidNameStartChar(name[0])) return false;
    for (name[1..]) |ch| {
        if (isInvalidNameChar(ch)) return false;
    }
    return true;
}

/// Validate an XML QName: prefix:localName with proper NCName constraints.
/// Used for createElementNS, createAttributeNS namespace validation.
pub fn isValidXmlQName(name: []const u8) bool {
    if (name.len == 0) return true; // empty is handled separately
    if (!isValidXmlName(name)) return false;
    // Colon handling: colon at start or end is invalid QName
    if (name[0] == ':' or name[name.len - 1] == ':') return false;
    return true;
}

/// Validate QName production per DOM spec "validate" step.
/// Matches browser behavior: for prefixed names (prefix:local), only the
/// local name's start char is strictly validated. The prefix is lenient.
/// For unprefixed names, start char is strictly validated.
pub fn isValidQName(name: []const u8) bool {
    if (name.len == 0) return false;
    // Check for invalid characters anywhere in the name
    for (name) |ch| {
        if (isInvalidNameChar(ch)) return false;
    }
    // Find colon to split prefix:localName
    if (std.mem.indexOfScalar(u8, name, ':')) |colon| {
        // Prefixed name: validate local name start char
        const local = name[colon + 1 ..];
        if (local.len == 0) return false; // trailing colon
        if (isInvalidNameStartChar(local[0])) return false;
        // Check for double colon (e.g., "a::b" is still valid per browsers)
        return true;
    }
    // Unprefixed name: validate start char strictly
    if (isInvalidNameStartChar(name[0])) return false;
    return true;
}

/// document.implementation.createDocumentType(qualifiedName, publicId, systemId)
pub fn implCreateDocumentType(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    // DOM spec: validate qualifiedName (browsers are lenient, only reject obvious invalids)
    if (argc >= 1) {
        const name_s = api.jsStringToSlice(c, args[0]);
        if (name_s) |ns| {
            defer qjs.JS_FreeCString(c, ns.ptr);
            const name = ns.ptr[0..ns.len];
            for (name) |ch| {
                if (ch == '>' or ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
                    return throwDOMException(c, "InvalidCharacterError", "The string contains invalid characters.");
                }
            }
        }
    }
    const obj = qjs.JS_NewObject(c);
    _ = qjs.JS_SetPropertyStr(c, obj, "nodeType", qjs.JS_NewInt32(c, 10));
    // name
    if (argc >= 1) {
        _ = qjs.JS_SetPropertyStr(c, obj, "name", qjs.JS_DupValue(c, args[0]));
        _ = qjs.JS_SetPropertyStr(c, obj, "nodeName", qjs.JS_DupValue(c, args[0]));
    } else {
        _ = qjs.JS_SetPropertyStr(c, obj, "name", qjs.JS_NewString(c, ""));
        _ = qjs.JS_SetPropertyStr(c, obj, "nodeName", qjs.JS_NewString(c, ""));
    }
    // publicId
    if (argc >= 2) {
        _ = qjs.JS_SetPropertyStr(c, obj, "publicId", qjs.JS_DupValue(c, args[1]));
    } else {
        _ = qjs.JS_SetPropertyStr(c, obj, "publicId", qjs.JS_NewString(c, ""));
    }
    // systemId
    if (argc >= 3) {
        _ = qjs.JS_SetPropertyStr(c, obj, "systemId", qjs.JS_DupValue(c, args[2]));
    } else {
        _ = qjs.JS_SetPropertyStr(c, obj, "systemId", qjs.JS_NewString(c, ""));
    }
    _ = qjs.JS_SetPropertyStr(c, obj, "childNodes", qjs.JS_NewArray(c));
    // DocumentType: nodeValue and textContent are null (getter), setter is no-op per DOM spec
    {
        const nv_js =
            \\(function(o){
            \\  Object.defineProperty(o,'nodeValue',{get:function(){return null;},set:function(){},configurable:true,enumerable:true});
            \\  Object.defineProperty(o,'textContent',{get:function(){return null;},set:function(){},configurable:true,enumerable:true});
            \\})
        ;
        const nv_fn = qjs.JS_Eval(c, nv_js, nv_js.len, "<dt-nv>", qjs.JS_EVAL_TYPE_GLOBAL);
        if (!quickjs.JS_IsException(nv_fn)) {
            var nv_args = [1]qjs.JSValue{obj};
            const nv_r = qjs.JS_Call(c, nv_fn, quickjs.JS_UNDEFINED(), 1, &nv_args);
            qjs.JS_FreeValue(c, nv_r);
            qjs.JS_FreeValue(c, nv_fn);
        }
    }
    _ = qjs.JS_SetPropertyStr(c, obj, "firstChild", quickjs.JS_NULL());
    _ = qjs.JS_SetPropertyStr(c, obj, "lastChild", quickjs.JS_NULL());
    _ = qjs.JS_SetPropertyStr(c, obj, "parentElement", quickjs.JS_NULL());
    _ = qjs.JS_SetPropertyStr(c, obj, "internalSubset", quickjs.JS_NULL());
    // ownerDocument = the calling document
    {
        const global = qjs.JS_GetGlobalObject(c);
        defer qjs.JS_FreeValue(c, global);
        const doc_val = qjs.JS_GetPropertyStr(c, global, "document");
        _ = qjs.JS_SetPropertyStr(c, obj, "ownerDocument", doc_val);
    }
    _ = qjs.JS_SetPropertyStr(c, obj, "parentNode", quickjs.JS_NULL());
    _ = qjs.JS_SetPropertyStr(c, obj, "nextSibling", quickjs.JS_NULL());
    _ = qjs.JS_SetPropertyStr(c, obj, "previousSibling", quickjs.JS_NULL());
    // Set DocumentType.prototype so it inherits Node methods (compareDocumentPosition etc.)
    {
        const global = qjs.JS_GetGlobalObject(c);
        defer qjs.JS_FreeValue(c, global);
        const dt_ctor = qjs.JS_GetPropertyStr(c, global, "DocumentType");
        defer qjs.JS_FreeValue(c, dt_ctor);
        const dt_proto = qjs.JS_GetPropertyStr(c, dt_ctor, "prototype");
        defer qjs.JS_FreeValue(c, dt_proto);
        if (!quickjs.JS_IsUndefined(dt_proto)) {
            _ = qjs.JS_SetPrototype(c, obj, dt_proto);
        }
    }
    // isEqualNode for DocumentType
    const ieq_js = "(function(o){if(!o||o.nodeType!==10)return false;return this.name===o.name&&this.publicId===o.publicId&&this.systemId===o.systemId;})";
    const ieq_fn = qjs.JS_Eval(c, ieq_js, ieq_js.len, "<dt-ieq>", qjs.JS_EVAL_TYPE_GLOBAL);
    _ = qjs.JS_SetPropertyStr(c, obj, "isEqualNode", ieq_fn);
    const isn_js = "(function(o){return this===o;})";
    const isn_fn = qjs.JS_Eval(c, isn_js, isn_js.len, "<dt-isn>", qjs.JS_EVAL_TYPE_GLOBAL);
    _ = qjs.JS_SetPropertyStr(c, obj, "isSameNode", isn_fn);
    // compareDocumentPosition for JS-only DocumentType nodes
    {
        const cdp_js =
            \\(function(other){
            \\  if(this===other)return 0;
            \\  var DISC=1,PREC=2,FOLL=4,CONT=8,CONTBY=16,IMPL=32;
            \\  if(!other||typeof other!=='object'||!('nodeType' in other))return DISC|IMPL|PREC;
            \\  var n=other.parentNode;while(n){if(n===this)return CONTBY|FOLL;n=n.parentNode;}
            \\  n=this.parentNode;while(n){if(n===other)return CONT|PREC;n=n.parentNode;}
            \\  var rA=this;while(rA.parentNode)rA=rA.parentNode;
            \\  var rB=other;while(rB.parentNode)rB=rB.parentNode;
            \\  if(rA!==rB)return DISC|IMPL|PREC;
            \\  var cA=[],cB=[];n=this;while(n){cA.push(n);n=n.parentNode;}
            \\  n=other;while(n){cB.push(n);n=n.parentNode;}
            \\  var ia=cA.length-1,ib=cB.length-1;
            \\  while(ia>0&&ib>0){ia--;ib--;if(cA[ia]!==cB[ib]){
            \\    var p=cA[ia+1],cn=p&&p.childNodes;
            \\    if(cn){for(var k=0;k<cn.length;k++){if(cn[k]===cA[ia])return FOLL;if(cn[k]===cB[ib])return PREC;}}
            \\    return PREC;}}
            \\  return FOLL;
            \\})
        ;
        _ = qjs.JS_SetPropertyStr(c, obj, "compareDocumentPosition", qjs.JS_Eval(c, cdp_js, cdp_js.len, "<dt-cdp>", qjs.JS_EVAL_TYPE_GLOBAL));
    }
    // Node methods needed for WPT
    {
        const rm_js = "(function(){if(this.parentNode)this.parentNode.removeChild(this);})";
        _ = qjs.JS_SetPropertyStr(c, obj, "remove", qjs.JS_Eval(c, rm_js, rm_js.len, "<dt-rm>", qjs.JS_EVAL_TYPE_GLOBAL));
        const cn_js = "(function(d){var o=document.implementation.createDocumentType(this.name,this.publicId,this.systemId);if(d&&this.childNodes)for(var i=0;i<this.childNodes.length;i++)o.childNodes.push(this.childNodes[i].cloneNode(true));return o;})";
        _ = qjs.JS_SetPropertyStr(c, obj, "cloneNode", qjs.JS_Eval(c, cn_js, cn_js.len, "<dt-cn>", qjs.JS_EVAL_TYPE_GLOBAL));
        const cont_js = "(function(o){return this===o;})";
        _ = qjs.JS_SetPropertyStr(c, obj, "contains", qjs.JS_Eval(c, cont_js, cont_js.len, "<dt-cont>", qjs.JS_EVAL_TYPE_GLOBAL));
        const hcn_js = "(function(){return false;})";
        _ = qjs.JS_SetPropertyStr(c, obj, "hasChildNodes", qjs.JS_Eval(c, hcn_js, hcn_js.len, "<dt-hcn>", qjs.JS_EVAL_TYPE_GLOBAL));
        const grn_js = "(function(){return this.parentNode?this.parentNode.getRootNode():this;})";
        _ = qjs.JS_SetPropertyStr(c, obj, "getRootNode", qjs.JS_Eval(c, grn_js, grn_js.len, "<dt-grn>", qjs.JS_EVAL_TYPE_GLOBAL));
        const lp_js = "(function(){return null;})";
        _ = qjs.JS_SetPropertyStr(c, obj, "lookupPrefix", qjs.JS_Eval(c, lp_js, lp_js.len, "<dt-lp>", qjs.JS_EVAL_TYPE_GLOBAL));
        _ = qjs.JS_SetPropertyStr(c, obj, "lookupNamespaceURI", qjs.JS_Eval(c, lp_js, lp_js.len, "<dt-lns>", qjs.JS_EVAL_TYPE_GLOBAL));
        const idn_js = "(function(ns){return false;})";
        _ = qjs.JS_SetPropertyStr(c, obj, "isDefaultNamespace", qjs.JS_Eval(c, idn_js, idn_js.len, "<dt-idn>", qjs.JS_EVAL_TYPE_GLOBAL));
    }
    return obj;
}

/// document.implementation.createDocument(namespace, qualifiedName, doctype)
pub fn implCreateDocument(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();

    // WebIDL: createDocument requires at least 2 arguments
    if (argc < 2) {
        _ = qjs.JS_ThrowTypeError(c, "Failed to execute 'createDocument': 2 arguments required.");
        return quickjs.JS_EXCEPTION();
    }

    // Validate 3rd argument (doctype): must be DocumentType (nodeType 10), null, or undefined
    if (argc >= 3 and !quickjs.JS_IsNull(args[2]) and !quickjs.JS_IsUndefined(args[2])) {
        // Must be an object with nodeType === 10
        const nt_check = qjs.JS_GetPropertyStr(c, args[2], "nodeType");
        var nt_v: i32 = 0;
        _ = qjs.JS_ToInt32(c, &nt_v, nt_check);
        qjs.JS_FreeValue(c, nt_check);
        if (nt_v != 10) {
            _ = qjs.JS_ThrowTypeError(c, "Failed to execute 'createDocument': parameter 3 is not of type 'DocumentType'.");
            return quickjs.JS_EXCEPTION();
        }
    }

    // Get namespace and qualifiedName
    // Per WebIDL: namespace is DOMString? (nullable), qualifiedName is [LegacyNullToEmptyString] DOMString
    var ns: ?[]const u8 = null;
    var ns_ptr: ?[*]const u8 = null;
    var qname: ?[]const u8 = null;
    var qname_ptr: ?[*]const u8 = null;
    if (argc >= 1 and !quickjs.JS_IsNull(args[0]) and !quickjs.JS_IsUndefined(args[0])) {
        if (jsStringToSlice(c, args[0])) |s| {
            ns = s.ptr[0..s.len];
            ns_ptr = s.ptr;
        }
    }
    if (argc >= 2) {
        if (quickjs.JS_IsNull(args[1])) {
            // [LegacyNullToEmptyString]: null → ""
            qname = "";
        } else {
            // undefined → "undefined", other values → toString
            const str_val = qjs.JS_ToString(c, args[1]);
            if (!quickjs.JS_IsException(str_val)) {
                if (jsStringToSlice(c, str_val)) |s| {
                    qname = s.ptr[0..s.len];
                    qname_ptr = s.ptr;
                }
                qjs.JS_FreeValue(c, str_val);
            }
        }
    }
    defer {
        if (ns_ptr) |p| qjs.JS_FreeCString(c, p);
        if (qname_ptr) |p| qjs.JS_FreeCString(c, p);
    }

    // Validate qualifiedName per DOM spec (QName production)
    if (qname) |qn| {
        if (qn.len > 0 and !isValidQName(qn)) {
            return throwDOMException(c, "InvalidCharacterError", "The string contains invalid characters.");
        }
        // Check namespace constraints per DOM spec:
        // 1. Split on FIRST colon: empty prefix or localpart → InvalidCharacterError
        // 2. Then check namespace constraints → NamespaceError
        if (std.mem.indexOfScalar(u8, qn, ':')) |colon_pos| {
            const prefix = qn[0..colon_pos];
            const local = qn[colon_pos + 1 ..];
            // Empty prefix (:foo) or localpart (foo:) → InvalidCharacterError
            if (prefix.len == 0 or local.len == 0)
                return throwDOMException(c, "InvalidCharacterError", "The string contains invalid characters.");
            // Has prefix — namespace must not be null
            if (ns == null) return throwDOMException(c, "NamespaceError", "The namespace URI provided is not valid for the given qualifiedName.");
            // xml: prefix requires XML namespace
            if (std.mem.eql(u8, prefix, "xml") and !std.mem.eql(u8, ns.?, "http://www.w3.org/XML/1998/namespace"))
                return throwDOMException(c, "NamespaceError", "The namespace URI provided is not valid for the given qualifiedName.");
            // xmlns: prefix requires XMLNS namespace
            if (std.mem.eql(u8, prefix, "xmlns") and !std.mem.eql(u8, ns.?, "http://www.w3.org/2000/xmlns/"))
                return throwDOMException(c, "NamespaceError", "The namespace URI provided is not valid for the given qualifiedName.");
        } else {
            // No prefix — xmlns localname requires XMLNS namespace
            if (std.mem.eql(u8, qn, "xmlns") and (ns == null or !std.mem.eql(u8, ns.?, "http://www.w3.org/2000/xmlns/")))
                return throwDOMException(c, "NamespaceError", "The namespace URI provided is not valid for the given qualifiedName.");
        }
    }

    // Build XML document-like object via Document constructor
    const js =
        \\(function(){var d=typeof XMLDocument!=='undefined'?new XMLDocument():new Document();d.contentType='application/xml';d.characterSet='UTF-8';d.charset='UTF-8';d.inputEncoding='UTF-8';d.URL='about:blank';d.documentURI='about:blank';d.compatMode='CSS1Compat';return d;})()
    ;
    const doc = qjs.JS_Eval(c, js, js.len, "<createDoc>", qjs.JS_EVAL_TYPE_GLOBAL);

    // Set contentType based on namespace
    if (ns) |ns_str| {
        if (std.mem.eql(u8, ns_str, "http://www.w3.org/1999/xhtml")) {
            _ = qjs.JS_SetPropertyStr(c, doc, "contentType", qjs.JS_NewString(c, "application/xhtml+xml"));
        } else if (std.mem.eql(u8, ns_str, "http://www.w3.org/2000/svg")) {
            _ = qjs.JS_SetPropertyStr(c, doc, "contentType", qjs.JS_NewString(c, "image/svg+xml"));
        }
    }

    // If doctype is provided, validate it's a DocumentType (nodeType === 10) and append
    if (argc >= 3 and !quickjs.JS_IsNull(args[2]) and !quickjs.JS_IsUndefined(args[2])) {
        const nt_val = qjs.JS_GetPropertyStr(c, args[2], "nodeType");
        var nt_int: i32 = 0;
        _ = qjs.JS_ToInt32(c, &nt_int, nt_val);
        qjs.JS_FreeValue(c, nt_val);
        if (nt_int == 10) {
            const append_dt_js = "(function(d,dt){d.appendChild(dt);d.doctype=dt;dt.ownerDocument=d;})";
            const dt_fn = qjs.JS_Eval(c, append_dt_js, append_dt_js.len, "<appendDT>", qjs.JS_EVAL_TYPE_GLOBAL);
            if (!quickjs.JS_IsException(dt_fn)) {
                var dt_args = [2]qjs.JSValue{ doc, args[2] };
                const dt_r = qjs.JS_Call(c, dt_fn, quickjs.JS_UNDEFINED(), 2, &dt_args);
                if (quickjs.JS_IsException(dt_r)) {
                    qjs.JS_FreeValue(c, dt_fn);
                    qjs.JS_FreeValue(c, doc);
                    return quickjs.JS_EXCEPTION();
                }
                qjs.JS_FreeValue(c, dt_r);
                qjs.JS_FreeValue(c, dt_fn);
            }
        }
    }

    // If qualifiedName is provided, create and append document element
    if (qname) |qn| {
        if (qn.len > 0) {
            const create_js = "(function(d,ns,qn){var e=document.createElementNS(ns,qn);d.appendChild(e);d.documentElement=e;return d;})";
            const fn_val = qjs.JS_Eval(c, create_js, create_js.len, "<createDocEl>", qjs.JS_EVAL_TYPE_GLOBAL);
            var call_args = [3]qjs.JSValue{ doc, if (ns != null) args[0] else quickjs.JS_NULL(), args[1] };
            const result = qjs.JS_Call(c, fn_val, quickjs.JS_UNDEFINED(), 3, &call_args);
            qjs.JS_FreeValue(c, fn_val);
            qjs.JS_FreeValue(c, doc);
            return result;
        }
    }

    return doc;
}

pub fn documentImportNode(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    return qjs.JS_DupValue(c, args[0]);
}

pub fn documentCreateRange(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    // Use the global __createRange factory (set up in initRangePrototype)
    const factory_js = "typeof __createRange==='function'?__createRange():null";
    const result = qjs.JS_Eval(c, factory_js, factory_js.len, "<range>", qjs.JS_EVAL_TYPE_GLOBAL);
    if (quickjs.JS_IsNull(result) or quickjs.JS_IsException(result)) {
        // Fallback: call initRangePrototype first, then try again
        const retry_js = "typeof __createRange==='function'?__createRange():{}";
        return qjs.JS_Eval(c, retry_js, retry_js.len, "<range>", qjs.JS_EVAL_TYPE_GLOBAL);
    }
    return result;
}

/// Initialize Range.prototype and the __createRange factory function
/// Called once during DOM setup to create spec-compliant Range objects
pub fn initRangePrototype(c: *qjs.JSContext) void {
    const range_init_js =
        \\(function(){
        \\  /* === Helper: node length per DOM spec === */
        \\  function nLen(n){
        \\    var t=n.nodeType;
        \\    if(t===10)return 0; /* DocumentType */
        \\    if(t===3||t===7||t===8)return(n.data||n.textContent||'').length; /* Text,PI,Comment */
        \\    return n.childNodes?n.childNodes.length:0;
        \\  }
        \\  /* === Helper: root of node === */
        \\  function root(n){while(n.parentNode)n=n.parentNode;return n;}
        \\  /* === Helper: index of node in parent === */
        \\  function idx(n){var i=0,c=n.parentNode?n.parentNode.firstChild:null;while(c&&c!==n){i++;c=c.nextSibling;}return i;}
        \\  /* === Boundary point comparison (DOM spec §5.2) === */
        \\  /* Returns -1 (before), 0 (equal), 1 (after) */
        \\  function bpCmp(nA,oA,nB,oB){
        \\    if(nA===nB)return oA<oB?-1:oA>oB?1:0;
        \\    var pos=nA.compareDocumentPosition(nB);
        \\    if(pos&16){ /* CONTAINS: nA is ancestor of nB */
        \\      var ch=nB;while(ch.parentNode!==nA)ch=ch.parentNode;
        \\      return oA<=idx(ch)?-1:1;
        \\    }
        \\    if(pos&8){ /* CONTAINED_BY: nB is ancestor of nA */
        \\      var ch=nA;while(ch.parentNode!==nB)ch=ch.parentNode;
        \\      return idx(ch)<oB?-1:1;
        \\    }
        \\    if(pos&4)return -1; /* FOLLOWING: nB follows nA */
        \\    if(pos&2)return 1;  /* PRECEDING: nB precedes nA */
        \\    return 0; /* disconnected */
        \\  }
        \\  /* === Range prototype === */
        \\  var RP=typeof Range!=='undefined'?Range.prototype:{};
        \\  RP._ua=function(){
        \\    var a=this.startContainer,b=this.endContainer;
        \\    if(a===b){this.commonAncestorContainer=a;return;}
        \\    var pa=[],n=a;while(n){pa.push(n);n=n.parentNode;}
        \\    n=b;while(n){for(var i=0;i<pa.length;i++)if(pa[i]===n){this.commonAncestorContainer=n;return;}n=n.parentNode;}
        \\    this.commonAncestorContainer=document;
        \\  };
        \\  Object.defineProperty(RP,'collapsed',{get:function(){return this.startContainer===this.endContainer&&this.startOffset===this.endOffset;},configurable:true,enumerable:true});
        \\  RP.setStart=function(n,o){
        \\    if(!n||n.nodeType===undefined)throw new TypeError("Invalid node");
        \\    o=o>>>0;if(o>nLen(n))throw new DOMException('','IndexSizeError');
        \\    this.startContainer=n;this.startOffset=o;
        \\    /* If start is after end, set end = start */
        \\    if(bpCmp(this.startContainer,this.startOffset,this.endContainer,this.endOffset)>0){
        \\      this.endContainer=this.startContainer;this.endOffset=this.startOffset;}
        \\    this._ua();
        \\  };
        \\  RP.setEnd=function(n,o){
        \\    if(!n||n.nodeType===undefined)throw new TypeError("Invalid node");
        \\    o=o>>>0;if(o>nLen(n))throw new DOMException('','IndexSizeError');
        \\    this.endContainer=n;this.endOffset=o;
        \\    if(bpCmp(this.startContainer,this.startOffset,this.endContainer,this.endOffset)>0){
        \\      this.startContainer=this.endContainer;this.startOffset=this.endOffset;}
        \\    this._ua();
        \\  };
        \\  RP.setStartBefore=function(n){var p=n.parentNode;if(!p)throw new DOMException('','InvalidNodeTypeError');this.setStart(p,idx(n));};
        \\  RP.setStartAfter=function(n){var p=n.parentNode;if(!p)throw new DOMException('','InvalidNodeTypeError');this.setStart(p,idx(n)+1);};
        \\  RP.setEndBefore=function(n){var p=n.parentNode;if(!p)throw new DOMException('','InvalidNodeTypeError');this.setEnd(p,idx(n));};
        \\  RP.setEndAfter=function(n){var p=n.parentNode;if(!p)throw new DOMException('','InvalidNodeTypeError');this.setEnd(p,idx(n)+1);};
        \\  RP.selectNode=function(n){var p=n.parentNode;if(!p)throw new DOMException('','InvalidNodeTypeError');var i=idx(n);this.setStart(p,i);this.setEnd(p,i+1);};
        \\  RP.selectNodeContents=function(n){this.startContainer=n;this.startOffset=0;this.endContainer=n;this.endOffset=nLen(n);this._ua();};
        \\  RP.collapse=function(toStart){
        \\    if(toStart){this.endContainer=this.startContainer;this.endOffset=this.startOffset;}
        \\    else{this.startContainer=this.endContainer;this.startOffset=this.endOffset;}
        \\    this._ua();
        \\  };
        \\  RP.cloneRange=function(){var nr=__createRange();nr.startContainer=this.startContainer;nr.startOffset=this.startOffset;nr.endContainer=this.endContainer;nr.endOffset=this.endOffset;nr._ua();return nr;};
        \\  RP.compareBoundaryPoints=function(how,sr){
        \\    if(!(sr instanceof Range))throw new TypeError("Argument is not a Range");
        \\    if(root(this.startContainer)!==root(sr.startContainer))throw new DOMException('','WrongDocumentError');
        \\    var thisP,thisO,srcP,srcO;
        \\    switch(how){
        \\      case 0:thisP=this.startContainer;thisO=this.startOffset;srcP=sr.startContainer;srcO=sr.startOffset;break;
        \\      case 1:thisP=this.startContainer;thisO=this.startOffset;srcP=sr.endContainer;srcO=sr.endOffset;break;
        \\      case 2:thisP=this.endContainer;thisO=this.endOffset;srcP=sr.endContainer;srcO=sr.endOffset;break;
        \\      case 3:thisP=this.endContainer;thisO=this.endOffset;srcP=sr.startContainer;srcO=sr.startOffset;break;
        \\      default:throw new DOMException('','NotSupportedError');
        \\    }
        \\    return bpCmp(thisP,thisO,srcP,srcO);
        \\  };
        \\  RP.isPointInRange=function(n,o){
        \\    if(root(n)!==root(this.startContainer))return false;
        \\    if(n.nodeType===10)throw new DOMException('','InvalidNodeTypeError');
        \\    o=o>>>0;if(o>nLen(n))throw new DOMException('','IndexSizeError');
        \\    if(bpCmp(n,o,this.startContainer,this.startOffset)<0)return false;
        \\    if(bpCmp(n,o,this.endContainer,this.endOffset)>0)return false;
        \\    return true;
        \\  };
        \\  RP.comparePoint=function(n,o){
        \\    if(root(n)!==root(this.startContainer))throw new DOMException('','WrongDocumentError');
        \\    if(n.nodeType===10)throw new DOMException('','InvalidNodeTypeError');
        \\    o=o>>>0;if(o>nLen(n))throw new DOMException('','IndexSizeError');
        \\    if(bpCmp(n,o,this.startContainer,this.startOffset)<0)return -1;
        \\    if(bpCmp(n,o,this.endContainer,this.endOffset)>0)return 1;
        \\    return 0;
        \\  };
        \\  RP.intersectsNode=function(n){
        \\    if(root(n)!==root(this.startContainer))return false;
        \\    var p=n.parentNode;
        \\    if(!p)return true;
        \\    var offset=idx(n);
        \\    return bpCmp(p,offset,this.endContainer,this.endOffset)<0&&bpCmp(p,offset+1,this.startContainer,this.startOffset)>0;
        \\  };
        \\  RP.toString=function(){
        \\    var s=this.startContainer,so=this.startOffset,e=this.endContainer,eo=this.endOffset;
        \\    if(s===e){
        \\      if(s.nodeType===3)return(s.data||'').substring(so,eo);
        \\      /* Same element container: collect text from children [so, eo) */
        \\      var r='',cn=s.childNodes;
        \\      for(var i=so;i<eo&&i<cn.length;i++){
        \\        if(cn[i].nodeType===3)r+=cn[i].data||'';
        \\        else if(cn[i].textContent!==undefined)r+=cn[i].textContent||'';
        \\      }
        \\      return r;
        \\    }
        \\    var result='';
        \\    /* Collect text within range using tree walker */
        \\    if(s.nodeType===3)result+=(s.data||'').substring(so);
        \\    /* Walk all text nodes between start and end */
        \\    var cur=s;
        \\    function nextNode(n){if(n.firstChild)return n.firstChild;while(n){if(n.nextSibling)return n.nextSibling;n=n.parentNode;}return null;}
        \\    cur=nextNode(s);
        \\    while(cur&&cur!==e){
        \\      if(cur.nodeType===3)result+=cur.data||'';
        \\      if(cur.contains&&cur.contains(e))cur=cur.firstChild;
        \\      else cur=nextNode(cur);
        \\    }
        \\    if(e.nodeType===3)result+=(e.data||'').substring(0,eo);
        \\    return result;
        \\  };
        \\  RP.detach=function(){};
        \\  RP.cloneContents=function(){
        \\    var f=document.createDocumentFragment();
        \\    if(this.collapsed)return f;
        \\    var s=this.startContainer,so=this.startOffset,e=this.endContainer,eo=this.endOffset;
        \\    if(s===e&&s.nodeType===3){f.appendChild(document.createTextNode((s.data||'').substring(so,eo)));return f;}
        \\    /* Simplified: clone text in range */
        \\    if(s.nodeType===3){f.appendChild(document.createTextNode((s.data||'').substring(so)));}
        \\    var cur=s;
        \\    function next(n){if(n.firstChild)return n.firstChild;while(n){if(n.nextSibling)return n.nextSibling;n=n.parentNode;}return null;}
        \\    cur=next(s);
        \\    while(cur&&cur!==e){
        \\      if(cur.nodeType===3){f.appendChild(document.createTextNode(cur.data||''));}
        \\      else if(cur.nodeType===1){f.appendChild(cur.cloneNode(false));}
        \\      if(cur.contains&&cur.contains(e)){cur=cur.firstChild;}else{cur=next(cur);}
        \\    }
        \\    if(e.nodeType===3){f.appendChild(document.createTextNode((e.data||'').substring(0,eo)));}
        \\    return f;
        \\  };
        \\  RP.deleteContents=function(){
        \\    if(this.collapsed)return;
        \\    var s=this.startContainer,so=this.startOffset,e=this.endContainer,eo=this.endOffset;
        \\    if(s===e&&s.nodeType===3){s.deleteData(so,eo-so);return;}
        \\    /* Collect nodes fully in range, then remove */
        \\    var toRemove=[];
        \\    function next(n){if(n.firstChild)return n.firstChild;while(n){if(n.nextSibling)return n.nextSibling;n=n.parentNode;}return null;}
        \\    var cur=next(s);
        \\    while(cur&&cur!==e){
        \\      var n2=next(cur);
        \\      if(!cur.contains||!cur.contains(e)){toRemove.push(cur);}
        \\      cur=n2;
        \\    }
        \\    for(var i=0;i<toRemove.length;i++){if(toRemove[i].parentNode)toRemove[i].parentNode.removeChild(toRemove[i]);}
        \\    if(s.nodeType===3&&s.deleteData)s.deleteData(so,(s.data||'').length-so);
        \\    if(e.nodeType===3&&e.deleteData)e.deleteData(0,eo);
        \\    this.collapse(true);
        \\  };
        \\  RP.extractContents=function(){
        \\    var f=this.cloneContents();
        \\    this.deleteContents();
        \\    return f;
        \\  };
        \\  RP.insertNode=function(n){
        \\    var sc=this.startContainer,so=this.startOffset;
        \\    if(sc.nodeType===3){var p=sc.parentNode;if(p){var ref=sc;
        \\      if(so>0&&so<(sc.data||'').length){sc.splitText(so);ref=sc.nextSibling;}
        \\      else if(so===0)ref=sc;
        \\      else ref=sc.nextSibling;
        \\      p.insertBefore(n,ref);}}
        \\    else{var ref=sc.childNodes[so]||null;sc.insertBefore(n,ref);}
        \\  };
        \\  RP.surroundContents=function(newParent){
        \\    var s=this.startContainer,e=this.endContainer;
        \\    /* Check for partial non-Text containment */
        \\    if(s.nodeType!==3&&s!==e&&(s.contains?!s.contains(e):true))throw new DOMException('','InvalidStateError');
        \\    if(newParent.nodeType===11||newParent.nodeType===9||newParent.nodeType===10)throw new DOMException('','InvalidNodeTypeError');
        \\    var frag=this.extractContents();
        \\    while(newParent.firstChild)newParent.removeChild(newParent.firstChild);
        \\    this.insertNode(newParent);
        \\    newParent.appendChild(frag);
        \\    this.selectNode(newParent);
        \\  };
        \\  RP.createContextualFragment=function(html){
        \\    var t=document.createElement('div');t.innerHTML=html;
        \\    var f=document.createDocumentFragment();while(t.firstChild)f.appendChild(t.firstChild);return f;
        \\  };
        \\  RP.getBoundingClientRect=function(){return{x:0,y:0,width:0,height:0,top:0,right:0,bottom:0,left:0};};
        \\  RP.getClientRects=function(){return[];};
        \\  /* Static constants on prototype */
        \\  RP.START_TO_START=0;RP.START_TO_END=1;RP.END_TO_END=2;RP.END_TO_START=3;
        \\  /* Factory function — accepts optional ownerDoc */
        \\  globalThis.__createRange=function(doc){
        \\    var d=doc||document;
        \\    var r=Object.create(RP);
        \\    r.startContainer=d;r.startOffset=0;r.endContainer=d;r.endOffset=0;r.commonAncestorContainer=d;
        \\    return r;
        \\  };
        \\  /* Override Range constructor so new Range() works */
        \\  if(typeof Range!=='undefined'){
        \\    var oldProto=Range.prototype;
        \\    var props=Object.getOwnPropertyNames(RP);
        \\    for(var i=0;i<props.length;i++){
        \\      var d=Object.getOwnPropertyDescriptor(RP,props[i]);
        \\      if(d)Object.defineProperty(oldProto,props[i],d);
        \\    }
        \\    Range.START_TO_START=0;Range.START_TO_END=1;Range.END_TO_END=2;Range.END_TO_START=3;
        \\    Range.prototype.START_TO_START=0;Range.prototype.START_TO_END=1;Range.prototype.END_TO_END=2;Range.prototype.END_TO_START=3;
        \\    /* Patch constructor to init fields */
        \\    var _origRange=Range;
        \\    globalThis.Range=function Range(){
        \\      var r=Object.create(_origRange.prototype);
        \\      r.startContainer=document;r.startOffset=0;r.endContainer=document;r.endOffset=0;r.commonAncestorContainer=document;
        \\      return r;
        \\    };
        \\    globalThis.Range.prototype=_origRange.prototype;
        \\    globalThis.Range.START_TO_START=0;globalThis.Range.START_TO_END=1;globalThis.Range.END_TO_END=2;globalThis.Range.END_TO_START=3;
        \\    _origRange.prototype.constructor=globalThis.Range;
        \\  }
        \\})()
    ;
    const r = qjs.JS_Eval(c, range_init_js, range_init_js.len, "<range-init>", qjs.JS_EVAL_TYPE_GLOBAL);
    qjs.JS_FreeValue(c, r);
}

pub fn documentCreateTreeWalker(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return qjs.JS_ThrowTypeError(c, "Failed to execute 'createTreeWalker': 1 argument required.");
    const args = argv orelse return quickjs.JS_NULL();

    // Get root node — must be a valid Node (DOM spec: TypeError if not)
    const root_val = args[0];
    if (quickjs.JS_IsNull(root_val) or quickjs.JS_IsUndefined(root_val)) {
        return qjs.JS_ThrowTypeError(c, "Failed to execute 'createTreeWalker': parameter 1 is not of type 'Node'.");
    }
    // Validate it's a Node by checking for nodeType property
    const nt_val = qjs.JS_GetPropertyStr(c, root_val, "nodeType");
    defer qjs.JS_FreeValue(c, nt_val);
    if (quickjs.JS_IsUndefined(nt_val) or quickjs.JS_IsNull(nt_val)) {
        return qjs.JS_ThrowTypeError(c, "Failed to execute 'createTreeWalker': parameter 1 is not of type 'Node'.");
    }
    var node_type: i32 = 0;
    if (qjs.JS_ToInt32(c, &node_type, nt_val) < 0 or node_type < 1 or node_type > 12) {
        return qjs.JS_ThrowTypeError(c, "Failed to execute 'createTreeWalker': parameter 1 is not of type 'Node'.");
    }

    // Get whatToShow (default: SHOW_ALL = 0xFFFFFFFF)
    // Use unsigned to match DOM spec (4294967295, not -1)
    var what_to_show: u32 = 0xFFFFFFFF;
    if (argc >= 2 and !quickjs.JS_IsUndefined(args[1])) {
        var signed: i32 = -1;
        _ = qjs.JS_ToInt32(c, &signed, args[1]);
        what_to_show = @bitCast(signed);
    }

    // Build TreeWalker as a JS polyfill that uses native DOM traversal
    const walker_js =
        \\(function(root, whatToShow, filter) {
        \\  var tw = {
        \\    root: root,
        \\    currentNode: root,
        \\    whatToShow: whatToShow,
        \\    filter: filter || null,
        \\    _check: function(node) {
        \\      if (whatToShow !== 0xFFFFFFFF) {
        \\        var nt = node.nodeType;
        \\        var mask = 1 << (nt - 1);
        \\        if (!(whatToShow & mask)) return 3; /* FILTER_SKIP */
        \\      }
        \\      if (this.filter) {
        \\        var r = typeof this.filter === 'function' ? this.filter(node) : this.filter.acceptNode(node);
        \\        return +r; /* Web IDL unsigned short coercion: true→1(ACCEPT), false→0, 2=REJECT, 3=SKIP */
        \\      }
        \\      return 1; /* FILTER_ACCEPT */
        \\    },
        \\    _accepts: function(node) { return this._check(node) === 1; },
        \\    nextNode: function() {
        \\      var node = this.currentNode, result = 1;
        \\      while (true) {
        \\        while (result !== 2 && node.firstChild) {
        \\          node = node.firstChild;
        \\          result = this._check(node);
        \\          if (result === 1) { this.currentNode = node; return node; }
        \\        }
        \\        var tmp = node;
        \\        while (tmp) {
        \\          if (tmp === this.root) return null;
        \\          var sib = tmp.nextSibling;
        \\          if (sib) { node = sib; break; }
        \\          tmp = tmp.parentNode;
        \\        }
        \\        if (!tmp) return null;
        \\        result = this._check(node);
        \\        if (result === 1) { this.currentNode = node; return node; }
        \\      }
        \\    },
        \\    previousNode: function() {
        \\      var node = this.currentNode;
        \\      while (node !== this.root) {
        \\        var sib = node.previousSibling;
        \\        while (sib) {
        \\          node = sib;
        \\          var result = this._check(node);
        \\          while (result !== 2 && node.lastChild) {
        \\            node = node.lastChild;
        \\            result = this._check(node);
        \\          }
        \\          if (result === 1) { this.currentNode = node; return node; }
        \\          sib = node.previousSibling;
        \\        }
        \\        if (node === this.root || !node.parentNode) return null;
        \\        node = node.parentNode;
        \\        if (this._check(node) === 1) { this.currentNode = node; return node; }
        \\      }
        \\      return null;
        \\    },
        \\    firstChild: function() {
        \\      var node = this.currentNode.firstChild;
        \\      while (node) {
        \\        var r = this._check(node);
        \\        if (r === 1) { this.currentNode = node; return node; }
        \\        if (r === 3 && node.firstChild) { node = node.firstChild; continue; } /* SKIP: descend */
        \\        /* REJECT or SKIP with no children: try sibling */
        \\        while (node && !node.nextSibling && node !== this.currentNode) node = node.parentNode;
        \\        node = node && node !== this.currentNode ? node.nextSibling : null;
        \\      }
        \\      return null;
        \\    },
        \\    lastChild: function() {
        \\      var node = this.currentNode.lastChild;
        \\      while (node) {
        \\        var r = this._check(node);
        \\        if (r === 1) { this.currentNode = node; return node; }
        \\        if (r === 3 && node.lastChild) { node = node.lastChild; continue; }
        \\        while (node && !node.previousSibling && node !== this.currentNode) node = node.parentNode;
        \\        node = node && node !== this.currentNode ? node.previousSibling : null;
        \\      }
        \\      return null;
        \\    },
        \\    parentNode: function() {
        \\      var node = this.currentNode;
        \\      while (node && node !== this.root) {
        \\        node = node.parentNode;
        \\        if (!node || node === this.root) return null;
        \\        if (this._accepts(node)) { this.currentNode = node; return node; }
        \\      }
        \\      return null;
        \\    },
        \\    nextSibling: function() {
        \\      var node = this.currentNode;
        \\      if (node === this.root) return null;
        \\      while (true) {
        \\        var sibling = node.nextSibling;
        \\        while (sibling) {
        \\          node = sibling;
        \\          var r = this._check(node);
        \\          if (r === 1) { this.currentNode = node; return node; }
        \\          if (r === 3 && node.firstChild) { sibling = node.firstChild; }
        \\          else { sibling = node.nextSibling; }
        \\        }
        \\        node = node.parentNode;
        \\        if (!node || node === this.root) return null;
        \\        if (this._check(node) === 1) return null;
        \\      }
        \\    },
        \\    previousSibling: function() {
        \\      var node = this.currentNode;
        \\      if (node === this.root) return null;
        \\      while (true) {
        \\        var sibling = node.previousSibling;
        \\        while (sibling) {
        \\          node = sibling;
        \\          var r = this._check(node);
        \\          if (r === 1) { this.currentNode = node; return node; }
        \\          if (r === 3 && node.lastChild) { sibling = node.lastChild; }
        \\          else { sibling = node.previousSibling; }
        \\        }
        \\        node = node.parentNode;
        \\        if (!node || node === this.root) return null;
        \\        if (this._check(node) === 1) return null;
        \\      }
        \\    }
        \\  };
        \\  var _currentNode = tw.currentNode;
        \\  Object.defineProperty(tw,'currentNode',{get:function(){return _currentNode;},set:function(v){if(!v||typeof v!=='object'||v.nodeType===undefined)throw new TypeError("Failed to set 'currentNode': The provided value is not of type 'Node'.");_currentNode=v;},enumerable:true,configurable:true});
        \\  Object.defineProperty(tw,'root',{value:tw.root,writable:false,enumerable:true});
        \\  Object.defineProperty(tw,'whatToShow',{value:tw.whatToShow,writable:false,enumerable:true});
        \\  Object.defineProperty(tw,'filter',{value:tw.filter,writable:false,enumerable:true});
        \\  tw[Symbol.toStringTag]='TreeWalker';
        \\  return tw;
        \\})
    ;
    const walker_fn = qjs.JS_Eval(c, walker_js, walker_js.len, "<treeWalker>", qjs.JS_EVAL_TYPE_GLOBAL);
    if (quickjs.JS_IsException(walker_fn)) return quickjs.JS_NULL();
    defer qjs.JS_FreeValue(c, walker_fn);

    const filter_val = if (argc >= 3) qjs.JS_DupValue(c, args[2]) else quickjs.JS_NULL();
    var call_args = [_]qjs.JSValue{
        qjs.JS_DupValue(c, root_val),
        qjs.JS_NewFloat64(c, @floatFromInt(what_to_show)),
        filter_val,
    };
    const result = qjs.JS_Call(c, walker_fn, quickjs.JS_UNDEFINED(), 3, &call_args);
    qjs.JS_FreeValue(c, call_args[0]);
    qjs.JS_FreeValue(c, call_args[1]);
    qjs.JS_FreeValue(c, call_args[2]);
    return result;
}

/// document.createNodeIterator(root, whatToShow, filter)
/// Wraps TreeWalker with NodeIterator-specific properties
pub fn documentCreateNodeIterator(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    // Create a TreeWalker first, then wrap as NodeIterator
    const tw = documentCreateTreeWalker(ctx, this_val, argc, argv);
    if (quickjs.JS_IsException(tw) or quickjs.JS_IsNull(tw)) return tw;
    // Add NodeIterator-specific properties (using object properties for pre-removing access)
    const ni_js =
        \\(function(ni){
        \\  ni._ref = ni.root;
        \\  ni._before = true;
        \\  Object.defineProperty(ni,'referenceNode',{get:function(){return ni._ref;},enumerable:true});
        \\  Object.defineProperty(ni,'pointerBeforeReferenceNode',{get:function(){return ni._before;},enumerable:true});
        \\  Object.defineProperty(ni,'root',{value:ni.root,writable:false,enumerable:true});
        \\  Object.defineProperty(ni,'whatToShow',{value:ni.whatToShow,writable:false,enumerable:true});
        \\  Object.defineProperty(ni,'filter',{value:ni.filter,writable:false,enumerable:true});
        \\  ni.detach = function(){};
        \\  ni[Symbol.toStringTag] = 'NodeIterator';
        \\  var origNext = ni.nextNode, origPrev = ni.previousNode, _started = false;
        \\  ni.nextNode = function(){
        \\    if(!_started){_started=true;var r=ni._check?ni._check(ni._ref):1;if(r===1){ni._before=false;return ni._ref;}}
        \\    var n=origNext.call(this);if(n){ni._ref=n;ni._before=false;}return n;
        \\  };
        \\  ni.previousNode = function(){var n=origPrev.call(this);if(n){ni._ref=n;ni._before=true;}return n;};
        \\  if(typeof __niRegistry!=='undefined')__niRegistry.push(ni);
        \\})
    ;
    const ni_fn = qjs.JS_Eval(c, ni_js, ni_js.len, "<nodeiter>", qjs.JS_EVAL_TYPE_GLOBAL);
    if (!quickjs.JS_IsException(ni_fn)) {
        var ni_args = [1]qjs.JSValue{tw};
        const ni_r = qjs.JS_Call(c, ni_fn, quickjs.JS_UNDEFINED(), 1, &ni_args);
        qjs.JS_FreeValue(c, ni_r);
        qjs.JS_FreeValue(c, ni_fn);
    }
    return tw;
}

pub fn jsReturnNull(
    _: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    return quickjs.JS_NULL();
}

pub fn jsReturnTrue(
    _: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    return quickjs.JS_NewBool(true);
}

pub fn getDocumentNode() ?*lxb.lxb_dom_node_t {
    const doc = api.g_document orelse return null;
    return @ptrCast(@alignCast(doc));
}

pub fn walkTreeByTagAndClass(root: *lxb.lxb_dom_node_t, tag_name: []const u8, class_name: []const u8) ?*lxb.lxb_dom_node_t {
    var current: ?*lxb.lxb_dom_node_t = root;
    while (current) |node| {
        if (node.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
            // Check tag name
            var name_len: usize = 0;
            const name_ptr = lxb_dom_element_local_name(elem, &name_len);
            if (name_ptr != null and name_len == tag_name.len and
                std.ascii.eqlIgnoreCase(name_ptr.?[0..name_len], tag_name))
            {
                // Check class
                var val_len: usize = 0;
                const val = lxb_dom_element_get_attribute(elem, "class", 5, &val_len);
                if (val != null and val_len > 0 and classContains(val.?[0..val_len], class_name)) return node;
            }
        }
        current = api.dom_sel.nextDfsNode(node, root);
    }
    return null;
}

pub fn walkTreeByClass(root: *lxb.lxb_dom_node_t, class_name: []const u8) ?*lxb.lxb_dom_node_t {
    var current: ?*lxb.lxb_dom_node_t = root;
    while (current) |node| {
        if (node.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
            var val_len: usize = 0;
            const val = lxb_dom_element_get_attribute(elem, "class", 5, &val_len);
            if (val != null and val_len > 0) {
                if (classContains(val.?[0..val_len], class_name)) return node;
            }
        }
        current = api.dom_sel.nextDfsNode(node, root);
    }
    return null;
}

pub fn walkTreeByTag(root: *lxb.lxb_dom_node_t, tag_name: []const u8) ?*lxb.lxb_dom_node_t {
    var current: ?*lxb.lxb_dom_node_t = root;
    while (current) |node| {
        if (node.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
            var name_len: usize = 0;
            const name_ptr = lxb_dom_element_local_name(elem, &name_len);
            if (name_ptr != null and name_len == tag_name.len) {
                // Case-insensitive comparison (DOM tags may be upper or lowercase)
                if (std.ascii.eqlIgnoreCase(name_ptr.?[0..name_len], tag_name)) return node;
            }
        }
        current = api.dom_sel.nextDfsNode(node, root);
    }
    return null;
}

pub fn documentGetElementById(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, s.ptr);
    // DOM spec: getElementById with empty string returns null
    if (s.len == 0) return quickjs.JS_NULL();

    // Search from this node (DocumentFragment) or main document
    const root_node = api.getNodePublic(c, this_val) orelse (getDocumentNode() orelse return quickjs.JS_NULL());
    const found = api.dom_sel.walkTreeById(root_node, s.ptr[0..s.len]) orelse return quickjs.JS_NULL();
    return wrapNode(c, found);
}

pub fn documentGetElementsByClassName(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, s.ptr);

    var selector_buf: [512]u8 = undefined;
    const class_name = s.ptr[0..s.len];
    // Get document JS object as root for live collection
    const global = qjs.JS_GetGlobalObject(c);
    const doc_js = qjs.JS_GetPropertyStr(c, global, "document");
    qjs.JS_FreeValue(c, global);
    defer qjs.JS_FreeValue(c, doc_js);

    const selector = api.buildClassSelector(class_name, &selector_buf) orelse {
        return makeLiveHTMLCollection(c, doc_js, "");
    };

    return makeLiveHTMLCollection(c, doc_js, selector);
}

pub fn documentGetElementsByTagName(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, s.ptr);

    const arr = qjs.JS_NewArray(c);
    if (quickjs.JS_IsException(arr)) return arr;
    const doc_node = getDocumentNode() orelse return arr;
    var idx: u32 = 0;
    api.dom_sel.walkTreeCollect(c, doc_node, s.ptr[0..s.len], arr, &idx);
    // Set HTMLCollection prototype for instanceof checks
    wrapAsHTMLCollection(c, arr);
    return arr;
}

pub fn wrapAsHTMLCollection(c: *qjs.JSContext, arr: qjs.JSValue) void {
    const js =
        \\(function(a){if(typeof HTMLCollection!=='undefined')Object.setPrototypeOf(a,HTMLCollection.prototype);})
    ;
    const fn_val = qjs.JS_Eval(c, js, js.len, "<htmlcol>", qjs.JS_EVAL_TYPE_GLOBAL);
    if (!quickjs.JS_IsException(fn_val)) {
        var args = [1]qjs.JSValue{arr};
        const r = qjs.JS_Call(c, fn_val, quickjs.JS_UNDEFINED(), 1, &args);
        qjs.JS_FreeValue(c, r);
        qjs.JS_FreeValue(c, fn_val);
    }
}

/// Create a live HTMLCollection backed by querySelectorAll that re-evaluates on access.
/// root_js is the JS element/document to call querySelectorAll on.
/// selector is the CSS selector string (empty string = always empty collection).
pub fn makeLiveHTMLCollection(c: *qjs.JSContext, root_js: qjs.JSValue, selector: []const u8) qjs.JSValue {
    const js =
        \\(function(root,sel){
        \\  if(!sel)return new Proxy([],{
        \\    get:function(o,p){if(p==='length')return 0;if(p==='item')return function(){return null;};
        \\      if(p==='namedItem')return function(){return null;};
        \\      if(p===Symbol.iterator)return function*(){};
        \\      if(p===Symbol.toStringTag)return'HTMLCollection';
        \\      if(typeof p==='string'&&!isNaN(p))return undefined;return o[p];}});
        \\  function _q(){try{return root.querySelectorAll(sel);}catch(e){return[];}}
        \\  var proxy=new Proxy([],{
        \\    get:function(o,p){
        \\      if(p===Symbol.toStringTag)return'HTMLCollection';
        \\      var r=_q(),len=r.length;
        \\      if(p==='length')return len;
        \\      if(p==='item')return function(i){return i>=0&&i<len?r[i]:null;};
        \\      if(p==='namedItem')return function(n){for(var i=0;i<len;i++){var e=r[i];if(e.id===n||e.name===n)return e;}return null;};
        \\      if(p===Symbol.iterator)return function*(){for(var i=0;i<len;i++)yield r[i];};
        \\      if(typeof p==='string'&&!isNaN(p)){var i=+p;return i>=0&&i<len?r[i]:undefined;}
        \\      return o[p];
        \\    },
        \\    has:function(o,p){if(p==='length'||p==='item'||p==='namedItem')return true;
        \\      if(typeof p==='string'&&!isNaN(p)){var r=_q();return +p<r.length;}return p in o;},
        \\    getOwnPropertyDescriptor:function(o,p){
        \\      if(typeof p==='string'&&!isNaN(p)){var r=_q(),i=+p;if(i>=0&&i<r.length)return{value:r[i],writable:false,enumerable:true,configurable:true};}
        \\      if(p==='length'){var r2=_q();return{value:r2.length,writable:false,enumerable:false,configurable:true};}
        \\      return Object.getOwnPropertyDescriptor(o,p);},
        \\    ownKeys:function(){var r=_q(),k=[];for(var i=0;i<r.length;i++)k.push(String(i));k.push('length');return k;}
        \\  });
        \\  if(typeof HTMLCollection!=='undefined')Object.setPrototypeOf(proxy,HTMLCollection.prototype);
        \\  return proxy;
        \\})
    ;
    const fn_val = qjs.JS_Eval(c, js, js.len, "<live-htmlcol>", qjs.JS_EVAL_TYPE_GLOBAL);
    if (quickjs.JS_IsException(fn_val)) return quickjs.JS_NULL();
    const sel_js = qjs.JS_NewStringLen(c, selector.ptr, selector.len);
    // If empty selector, pass null to get empty collection
    const sel_arg = if (selector.len == 0) quickjs.JS_NULL() else sel_js;
    var call_args = [2]qjs.JSValue{ root_js, sel_arg };
    const result = qjs.JS_Call(c, fn_val, quickjs.JS_UNDEFINED(), 2, &call_args);
    qjs.JS_FreeValue(c, sel_js);
    qjs.JS_FreeValue(c, fn_val);
    if (quickjs.JS_IsException(result)) return quickjs.JS_NULL();
    return result;
}

pub fn documentGetElementsByName(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, s.ptr);

    // Build CSS selector [name="..."]
    var selector_buf: [270]u8 = undefined;
    const name = s.ptr[0..s.len];
    const prefix = "[name=\"";
    const suffix = "\"]";
    if (prefix.len + name.len + suffix.len > selector_buf.len) return quickjs.JS_NULL();
    @memcpy(selector_buf[0..prefix.len], prefix);
    @memcpy(selector_buf[prefix.len .. prefix.len + name.len], name);
    @memcpy(selector_buf[prefix.len + name.len .. prefix.len + name.len + suffix.len], suffix);
    const selector = selector_buf[0 .. prefix.len + name.len + suffix.len];

    // Return a live NodeList via Proxy that re-queries on access
    const live_js =
        \\(function(sel){
        \\  function _q(){try{var r=document.querySelectorAll(sel),a=[];for(var i=0;i<r.length;i++){var ns=r[i].namespaceURI;if(!ns||ns==='http://www.w3.org/1999/xhtml')a.push(r[i]);}return a;}catch(e){return[];}}
        \\  return new Proxy({},{
        \\    get:function(t,p){
        \\      var r=Array.from(_q()),len=r.length;
        \\      if(p==='length')return len;
        \\      if(p==='item')return function(i){return i>=0&&i<len?r[i]:null;};
        \\      if(p===Symbol.iterator)return function*(){for(var i=0;i<len;i++)yield r[i];};
        \\      if(p===Symbol.toStringTag)return'NodeList';
        \\      if(typeof p==='string'&&/^\d+$/.test(p)){var i=p>>>0;return i<len?r[i]:undefined;}
        \\      if(p==='forEach')return function(cb,th){var a=Array.from(_q());for(var i=0;i<a.length;i++)cb.call(th,a[i],i,this);};
        \\      if(p==='entries')return function*(){var a=Array.from(_q());for(var i=0;i<a.length;i++)yield[i,a[i]];};
        \\      if(p==='keys')return function*(){var a=Array.from(_q());for(var i=0;i<a.length;i++)yield i;};
        \\      if(p==='values')return function*(){var a=Array.from(_q());for(var i=0;i<a.length;i++)yield a[i];};
        \\      return t[p];
        \\    },
        \\    has:function(t,p){
        \\      if(typeof p==='string'&&/^\d+$/.test(p)){var r=_q();return(p>>>0)<r.length;}
        \\      return p==='length'||p==='item';
        \\    },
        \\    ownKeys:function(){
        \\      var r=_q(),k=[];for(var i=0;i<r.length;i++)k.push(String(i));return k;
        \\    },
        \\    getOwnPropertyDescriptor:function(t,p){
        \\      var r=Array.from(_q());
        \\      if(typeof p==='string'&&/^\d+$/.test(p)){var i=p>>>0;if(i<r.length)return{value:r[i],writable:false,enumerable:true,configurable:true};}
        \\      return undefined;
        \\    },
        \\    getPrototypeOf:function(){return typeof NodeList!=='undefined'?NodeList.prototype:Object.prototype;}
        \\  });
        \\})
    ;
    const fn_val = qjs.JS_Eval(c, live_js, live_js.len, "<gbn>", qjs.JS_EVAL_TYPE_GLOBAL);
    if (quickjs.JS_IsException(fn_val)) return quickjs.JS_NULL();
    defer qjs.JS_FreeValue(c, fn_val);
    const sel_str = qjs.JS_NewStringLen(c, selector.ptr, selector.len);
    defer qjs.JS_FreeValue(c, sel_str);
    var call_args = [1]qjs.JSValue{sel_str};
    return qjs.JS_Call(c, fn_val, quickjs.JS_UNDEFINED(), 1, &call_args);
}

pub fn documentCreateElement(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, s.ptr);

    // Validate element name
    const tag = s.ptr[0..s.len];
    if (tag.len == 0 or !isValidElementName(tag))
        return api.throwDOMException(c, "InvalidCharacterError", "The string contains invalid characters.");

    const doc = api.getDocument(c) orelse return quickjs.JS_NULL();
    const elem = lxb_dom_document_create_element(doc, s.ptr, s.len, null) orelse return quickjs.JS_NULL();
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    const js_elem = wrapNode(c, node);

    // Custom element upgrade: check __ce_registry for matching tag name
    api.upgradeCustomElement(c, js_elem, s.ptr, s.len);

    return js_elem;
}

/// DOM spec "validate and extract" algorithm for createElementNS/createAttributeNS.
/// Returns the validated namespace, prefix, and localName, or throws DOMException.
fn validateAndExtract(c: *qjs.JSContext, ns_arg: qjs.JSValue, qn_arg: qjs.JSValue) ?qjs.JSValue {
    const XML_NS = "http://www.w3.org/XML/1998/namespace";
    const XMLNS_NS = "http://www.w3.org/2000/xmlns/";

    // Get qualifiedName as string (null/undefined → "null"/"undefined" per WebIDL)
    const qn_s = jsStringToSlice(c, qn_arg) orelse {
        // null becomes "null" string
        return null;
    };
    defer qjs.JS_FreeCString(c, qn_s.ptr);
    const qn = qn_s.ptr[0..qn_s.len];

    // Step 1: validate qualifiedName against QName production (matching browser behavior)
    // Empty qualifiedName is always invalid
    if (qn.len == 0 or !isValidQName(qn)) {
        _ = throwDOMException(c, "InvalidCharacterError", "The string contains invalid characters.");
        return @as(qjs.JSValue, quickjs.JS_EXCEPTION());
    }

    // Get namespace (null, undefined, "" → null per spec; "" treated as null)
    var ns: ?[]const u8 = null;
    var ns_ptr: ?[*]const u8 = null;
    if (!quickjs.JS_IsNull(ns_arg) and !quickjs.JS_IsUndefined(ns_arg)) {
        if (jsStringToSlice(c, ns_arg)) |ns_s| {
            const ns_str = ns_s.ptr[0..ns_s.len];
            if (ns_str.len > 0) {
                ns = ns_str;
                ns_ptr = ns_s.ptr;
            } else {
                qjs.JS_FreeCString(c, ns_s.ptr);
            }
        }
    }
    defer if (ns_ptr) |p| qjs.JS_FreeCString(c, p);

    // Step 2: validate QName — colon at start/end is INVALID_CHARACTER_ERR
    if (qn.len > 0 and (qn[0] == ':' or qn[qn.len - 1] == ':')) {
        _ = throwDOMException(c, "InvalidCharacterError", "The string contains invalid characters.");
        return quickjs.JS_EXCEPTION();
    }

    // Find first colon for prefix extraction
    const colon_pos = std.mem.indexOf(u8, qn, ":");
    const prefix: ?[]const u8 = if (colon_pos) |cp| qn[0..cp] else null;
    const local_name: []const u8 = if (colon_pos) |cp| qn[cp + 1 ..] else qn;

    // Step 3: If namespace is null and prefix is not null → NAMESPACE_ERR
    if (ns == null and prefix != null) {
        _ = throwDOMException(c, "NamespaceError", "The namespace URI provided is not valid for the given qualifiedName.");
        return quickjs.JS_EXCEPTION();
    }

    // Step 4: If prefix is "xml" and namespace is not XML namespace → NAMESPACE_ERR
    if (prefix != null and std.mem.eql(u8, prefix.?, "xml") and (ns == null or !std.mem.eql(u8, ns.?, XML_NS))) {
        _ = throwDOMException(c, "NamespaceError", "The namespace URI provided is not valid for the given qualifiedName.");
        return quickjs.JS_EXCEPTION();
    }

    // Step 5: If qualifiedName is "xmlns" or prefix is "xmlns", namespace must be XMLNS
    if ((std.mem.eql(u8, qn, "xmlns") or (prefix != null and std.mem.eql(u8, prefix.?, "xmlns"))) and
        (ns == null or !std.mem.eql(u8, ns.?, XMLNS_NS)))
    {
        _ = throwDOMException(c, "NamespaceError", "The namespace URI provided is not valid for the given qualifiedName.");
        return quickjs.JS_EXCEPTION();
    }

    // Step 6: If namespace is XMLNS and qualifiedName is not "xmlns" and prefix is not "xmlns" → NAMESPACE_ERR
    if (ns != null and std.mem.eql(u8, ns.?, XMLNS_NS) and
        !std.mem.eql(u8, qn, "xmlns") and (prefix == null or !std.mem.eql(u8, prefix.?, "xmlns")))
    {
        _ = throwDOMException(c, "NamespaceError", "The namespace URI provided is not valid for the given qualifiedName.");
        return quickjs.JS_EXCEPTION();
    }

    // Validate localName part (after colon) — must be a valid Name start
    if (colon_pos != null and local_name.len > 0 and isInvalidNameStartChar(local_name[0])) {
        _ = throwDOMException(c, "InvalidCharacterError", "The string contains invalid characters.");
        return quickjs.JS_EXCEPTION();
    }

    return null; // success — no error
}

pub fn documentCreateElementNS(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 2) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();

    // Validate and extract per DOM spec
    if (validateAndExtract(c, args[0], args[1])) |err| {
        _ = err;
        return quickjs.JS_EXCEPTION();
    }

    // Compute namespace per spec: null, undefined, "" all become JS null
    const ns_js = blk: {
        if (quickjs.JS_IsNull(args[0]) or quickjs.JS_IsUndefined(args[0])) break :blk quickjs.JS_NULL();
        if (jsStringToSlice(c, args[0])) |ns_s| {
            defer qjs.JS_FreeCString(c, ns_s.ptr);
            if (ns_s.len == 0) break :blk quickjs.JS_NULL();
        }
        break :blk qjs.JS_DupValue(c, args[0]);
    };

    const s = jsStringToSlice(c, args[1]) orelse {
        // null/undefined → use "null"/"undefined" string
        const tag = "null";
        const doc = api.getDocument(c) orelse return quickjs.JS_NULL();
        const elem = lxb_dom_document_create_element(doc, tag.ptr, tag.len, null) orelse return quickjs.JS_NULL();
        const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
        const obj = wrapNode(c, node);
        _ = qjs.JS_SetPropertyStr(c, obj, "namespaceURI", ns_js);
        _ = qjs.JS_SetPropertyStr(c, obj, "prefix", quickjs.JS_NULL());
        return obj;
    };
    defer qjs.JS_FreeCString(c, s.ptr);
    const tag = s.ptr[0..s.len];

    const doc = api.getDocument(c) orelse return quickjs.JS_NULL();
    // Use localName for element creation (strip prefix)
    const colon_pos = std.mem.indexOf(u8, tag, ":");
    const local_name = if (colon_pos) |cp| tag[cp + 1 ..] else tag;
    const create_name = if (local_name.len > 0) local_name else tag;
    const elem = lxb_dom_document_create_element(doc, create_name.ptr, create_name.len, null) orelse return quickjs.JS_NULL();
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    const obj = wrapNode(c, node);

    // For non-HTML namespace elements, reset prototype to Element.prototype
    // (wrapNode sets HTML-specific prototypes based on tag name, but non-HTML
    // namespace elements should not be instances of HTMLElement)
    {
        const is_html_ns = blk: {
            if (quickjs.JS_IsNull(ns_js) or quickjs.JS_IsUndefined(ns_js)) break :blk false;
            if (jsStringToSlice(c, ns_js)) |ns_s| {
                defer qjs.JS_FreeCString(c, ns_s.ptr);
                break :blk std.mem.eql(u8, ns_s.ptr[0..ns_s.len], "http://www.w3.org/1999/xhtml");
            }
            break :blk false;
        };
        if (!is_html_ns) {
            // Non-HTML namespace → Element.prototype
            const global = qjs.JS_GetGlobalObject(c);
            defer qjs.JS_FreeValue(c, global);
            const elem_ctor = qjs.JS_GetPropertyStr(c, global, "Element");
            defer qjs.JS_FreeValue(c, elem_ctor);
            if (!quickjs.JS_IsUndefined(elem_ctor)) {
                const elem_proto = qjs.JS_GetPropertyStr(c, elem_ctor, "prototype");
                defer qjs.JS_FreeValue(c, elem_proto);
                if (!quickjs.JS_IsUndefined(elem_proto)) {
                    _ = qjs.JS_SetPrototype(c, obj, elem_proto);
                }
            }
        } else {
            // HTML namespace but upper-case local name → HTMLUnknownElement
            // Per spec, only lowercase names map to known HTML element interfaces
            var has_upper = false;
            for (create_name) |ch| {
                if (ch >= 'A' and ch <= 'Z') {
                    has_upper = true;
                    break;
                }
            }
            if (has_upper) {
                const global = qjs.JS_GetGlobalObject(c);
                defer qjs.JS_FreeValue(c, global);
                const proto_map = qjs.JS_GetPropertyStr(c, global, "__elProtos");
                defer qjs.JS_FreeValue(c, proto_map);
                if (!quickjs.JS_IsUndefined(proto_map)) {
                    const unk_proto = qjs.JS_GetPropertyStr(c, proto_map, "__unknown");
                    defer qjs.JS_FreeValue(c, unk_proto);
                    if (!quickjs.JS_IsUndefined(unk_proto) and !quickjs.JS_IsNull(unk_proto)) {
                        _ = qjs.JS_SetPrototype(c, obj, unk_proto);
                    }
                }
            }
        }
    }

    // Set namespace-related properties on the JS object
    _ = qjs.JS_SetPropertyStr(c, obj, "namespaceURI", ns_js);
    if (colon_pos) |cp| {
        _ = qjs.JS_SetPropertyStr(c, obj, "prefix", qjs.JS_NewStringLen(c, tag.ptr, cp));
        // Store original-case localName (lexbor lowercases everything)
        _ = qjs.JS_SetPropertyStr(c, obj, "__origLocal", qjs.JS_NewStringLen(c, tag.ptr + cp + 1, tag.len - cp - 1));
    } else {
        _ = qjs.JS_SetPropertyStr(c, obj, "prefix", quickjs.JS_NULL());
        // Store original-case localName (lexbor lowercases everything)
        _ = qjs.JS_SetPropertyStr(c, obj, "__origLocal", qjs.JS_NewStringLen(c, local_name.ptr, local_name.len));
    }
    return obj;
}

pub fn documentCreateTextNode(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, s.ptr);

    const doc = api.getDocument(c) orelse return quickjs.JS_NULL();
    const text = lxb_dom_document_create_text_node(doc, s.ptr, s.len) orelse return quickjs.JS_NULL();
    return wrapNode(c, text);
}

pub fn documentGetBody(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    const doc_node = getDocumentNode() orelse return quickjs.JS_NULL();
    // HTML spec: body element is the first child of <html> that is <body> or <frameset>
    const html_node = walkTreeByTag(doc_node, "html") orelse return quickjs.JS_NULL();
    var child: ?*lxb.lxb_dom_node_t = html_node.first_child;
    while (child) |ch| {
        if (ch.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            const elem: *lxb.lxb_dom_element_t = @ptrCast(ch);
            var name_len: usize = 0;
            const name_ptr = lxb_dom_element_local_name(elem, &name_len);
            if (name_ptr != null and name_len > 0) {
                const name = name_ptr.?[0..name_len];
                if (std.mem.eql(u8, name, "body") or std.mem.eql(u8, name, "frameset")) {
                    return wrapNode(c, ch);
                }
            }
        }
        child = ch.next;
    }
    return quickjs.JS_NULL();
}

pub fn documentSetBody(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    // HTML spec: setter must accept only body or frameset elements
    const new_node = api.getNodePublic(c, args[0]);
    if (new_node == null or (new_node != null and new_node.?.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT)) {
        return throwDOMException(c, "HierarchyRequestError", "The new body element must be a 'body' or 'frameset' element.");
    }
    const new_elem: *lxb.lxb_dom_element_t = @ptrCast(new_node.?);
    var name_len: usize = 0;
    const name_ptr = lxb_dom_element_local_name(new_elem, &name_len);
    if (name_ptr == null or name_len == 0) return throwDOMException(c, "HierarchyRequestError", "The new body element must be a 'body' or 'frameset' element.");
    const name = name_ptr.?[0..name_len];
    if (!std.mem.eql(u8, name, "body") and !std.mem.eql(u8, name, "frameset")) {
        return throwDOMException(c, "HierarchyRequestError", "The new body element must be a 'body' or 'frameset' element.");
    }

    // Must have a document element (html)
    const doc_node = getDocumentNode() orelse return throwDOMException(c, "HierarchyRequestError", "No document element.");
    const html_node = walkTreeByTag(doc_node, "html") orelse return throwDOMException(c, "HierarchyRequestError", "No document element.");

    // Find existing body/frameset to replace
    var existing: ?*lxb.lxb_dom_node_t = null;
    var child: ?*lxb.lxb_dom_node_t = html_node.first_child;
    while (child) |ch| {
        if (ch.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            const ch_elem: *lxb.lxb_dom_element_t = @ptrCast(ch);
            var ch_name_len: usize = 0;
            const ch_name_ptr = lxb_dom_element_local_name(ch_elem, &ch_name_len);
            if (ch_name_ptr != null and ch_name_len > 0) {
                const ch_name = ch_name_ptr.?[0..ch_name_len];
                if (std.mem.eql(u8, ch_name, "body") or std.mem.eql(u8, ch_name, "frameset")) {
                    existing = ch;
                    break;
                }
            }
        }
        child = ch.next;
    }

    const nn = new_node.?;
    // Detach new node from old parent
    if (nn.parent != null) lxb_dom_node_remove(nn);

    if (existing) |ex| {
        // Replace existing body/frameset
        lxb_dom_node_insert_before(ex, nn);
        lxb_dom_node_remove(ex);
    } else {
        // Append to html element
        lxb_dom_node_insert_child(html_node, nn);
    }
    api.setDomDirty();
    return quickjs.JS_UNDEFINED();
}

pub fn documentGetTitle(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    const doc_node = getDocumentNode() orelse return qjs.JS_NewStringLen(c, "", 0);
    const title_node = walkTreeByTag(doc_node, "title") orelse return qjs.JS_NewStringLen(c, "", 0);
    var len: usize = 0;
    const ptr = lxb_dom_node_text_content(title_node, &len);
    if (ptr == null or len == 0) return qjs.JS_NewStringLen(c, "", 0);
    // HTML spec: strip and collapse whitespace
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var in_space = true; // trim leading
    for (ptr.?[0..len]) |ch| {
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 0x0C) {
            if (!in_space and pos < buf.len) {
                buf[pos] = ' ';
                pos += 1;
                in_space = true;
            }
        } else {
            if (pos < buf.len) {
                buf[pos] = ch;
                pos += 1;
            }
            in_space = false;
        }
    }
    // trim trailing space
    if (pos > 0 and buf[pos - 1] == ' ') pos -= 1;
    return qjs.JS_NewStringLen(c, &buf, pos);
}

pub fn documentSetTitle(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const new_title = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, new_title.ptr);

    // Find <title> element in DOM and set its text content
    const doc_node = getDocumentNode() orelse return quickjs.JS_UNDEFINED();
    const doc_ptr = api.g_document orelse return quickjs.JS_UNDEFINED();
    var title_node = walkTreeByTag(doc_node, "title");
    // HTML spec: if no title element exists, create one in <head>
    if (title_node == null) {
        if (walkTreeByTag(doc_node, "head")) |head_node| {
            const new_elem = lxb_dom_document_create_element(doc_ptr, "title", 5, null);
            if (new_elem) |elem| {
                const elem_node: *lxb.lxb_dom_node_t = @ptrCast(elem);
                lxb_dom_node_insert_child(head_node, elem_node);
                title_node = elem_node;
            }
        }
    }
    if (title_node) |tn| {
        // Remove all existing children
        while (tn.first_child) |child| {
            lxb_dom_node_remove(child);
            _ = lxb_dom_node_destroy(child);
        }
        // Create new text node with the title content (skip if empty)
        if (new_title.len > 0) {
            const text_node = lxb_dom_document_create_text_node(doc_ptr, new_title.ptr, new_title.len);
            if (text_node) |text| {
                lxb_dom_node_insert_child(tn, @ptrCast(text));
            }
        }
    }
    return quickjs.JS_UNDEFINED();
}

pub fn documentGetDocumentElement(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    const doc_node = getDocumentNode() orelse return quickjs.JS_NULL();
    const found = walkTreeByTag(doc_node, "html") orelse return quickjs.JS_NULL();
    return wrapNode(c, found);
}

pub fn documentGetHead(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    const doc_node = getDocumentNode() orelse return quickjs.JS_NULL();
    if (walkTreeByTag(doc_node, "head")) |found| return wrapNode(c, found);
    // Fallback: if <head> not found, try <html> element (scripts may run before head is parsed)
    if (walkTreeByTag(doc_node, "html")) |html_node| return wrapNode(c, html_node);
    // Last resort: return document element itself so .querySelectorAll etc. still work
    return wrapNode(c, doc_node);
}

// ── document.cookie ─────────────────────────────────────────────────

/// Extract domain from a URL (e.g., "https://www.example.com/path" -> "www.example.com")
pub fn extractDomain(url: []const u8) ?[]const u8 {
    // Skip scheme
    var rest = url;
    if (std.mem.indexOf(u8, rest, "://")) |idx| {
        rest = rest[idx + 3 ..];
    }
    // Take up to first '/' or end
    if (std.mem.indexOf(u8, rest, "/")) |idx| {
        rest = rest[0..idx];
    }
    // Remove port
    if (std.mem.indexOf(u8, rest, ":")) |idx| {
        rest = rest[0..idx];
    }
    if (rest.len == 0) return null;
    return rest;
}

pub fn documentGetCookie(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const web_api = @import("web_api.zig");
    const client = web_api.getHttpClient() orelse {
        return qjs.JS_NewStringLen(c, "", 0);
    };

    const domain = if (api.g_current_url) |url| extractDomain(url) orelse "" else "";
    if (domain.len == 0) return qjs.JS_NewStringLen(c, "", 0);

    const cookies = client.getCookiesForDomain(std.heap.c_allocator, domain) orelse {
        return qjs.JS_NewStringLen(c, "", 0);
    };
    defer std.heap.c_allocator.free(cookies);
    return qjs.JS_NewStringLen(c, cookies.ptr, cookies.len);
}

pub fn documentSetCookie(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, s.ptr);

    const web_api = @import("web_api.zig");
    const client = web_api.getHttpClient() orelse return quickjs.JS_UNDEFINED();

    const domain = if (api.g_current_url) |url| extractDomain(url) orelse "" else "";
    if (domain.len == 0) return quickjs.JS_UNDEFINED();

    client.setJsCookie(domain, s.ptr[0..s.len]);
    return quickjs.JS_UNDEFINED();
}

pub fn documentCreateDocumentFragment(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    // Use a real Lexbor element but override nodeType/nodeName for spec compliance
    const doc = api.getDocument(c) orelse return quickjs.JS_NULL();
    const elem = lxb_dom_document_create_element(doc, "div", 3, null) orelse return quickjs.JS_NULL();
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    const obj = wrapNode(c, node);
    // Override nodeType and nodeName with defineProperty to override prototype getters
    {
        const fix_js =
            \\(function(f){
            \\  Object.defineProperty(f,'nodeType',{value:11,writable:false,configurable:true,enumerable:true});
            \\  Object.defineProperty(f,'nodeName',{value:'#document-fragment',writable:false,configurable:true,enumerable:true});
            \\  Object.defineProperty(f,'nodeValue',{value:null,writable:false,configurable:true,enumerable:true});
            \\  Object.defineProperty(f,'ownerDocument',{value:document,writable:true,configurable:true,enumerable:true});
            \\  Object.defineProperty(f,'textContent',{get:function(){var t='';var n=this.firstChild;while(n){if(n.nodeType===3)t+=n.data||'';else if(n.nodeType===1)t+=n.textContent||'';n=n.nextSibling;}return t;},set:function(v){while(this.firstChild)this.removeChild(this.firstChild);this.__jsChildren=[];if(v!==null&&v!==undefined&&v!=='')this.appendChild(document.createTextNode(''+v));},configurable:true,enumerable:true});
            \\  f.getElementById=function(id){if(!id||id==='')return null;return this.querySelector('#'+CSS.escape(id));};
            \\})
        ;
        const fix_fn = qjs.JS_Eval(c, fix_js, fix_js.len, "<frag-fix>", qjs.JS_EVAL_TYPE_GLOBAL);
        if (!quickjs.JS_IsException(fix_fn)) {
            var fix_args = [1]qjs.JSValue{obj};
            const fix_r = qjs.JS_Call(c, fix_fn, quickjs.JS_UNDEFINED(), 1, &fix_args);
            qjs.JS_FreeValue(c, fix_r);
            qjs.JS_FreeValue(c, fix_fn);
        }
    }
    return obj;
}

// ── document.readyState getter ──────────────────────────────────────

pub fn documentGetReadyState(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const state_str: []const u8 = switch (api.g_ready_state) {
        .loading => "loading",
        .interactive => "interactive",
        .complete => "complete",
    };
    return qjs.JS_NewString(c, state_str.ptr);
}

pub fn documentGetActiveElement(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (api.active_element) |node| {
        return wrapNode(c, node);
    }
    // Default: return document.body
    return documentGetBody(ctx, quickjs.JS_UNDEFINED(), 0, null);
}

// ── document.createEvent ────────────────────────────────────────────

pub fn documentCreateEvent(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    // Map interface names to constructors per DOM spec
    var iface: []const u8 = "Event";
    if (argc >= 1) {
        if (argv) |a| {
            if (jsStringToSlice(c, a[0])) |s| {
                defer qjs.JS_FreeCString(c, s.ptr);
                const name = s.ptr[0..s.len];
                // Legacy event interface aliases per DOM spec §5.1
                if (std.ascii.eqlIgnoreCase(name, "customevent")) iface = "CustomEvent" else if (std.ascii.eqlIgnoreCase(name, "event") or std.ascii.eqlIgnoreCase(name, "events") or std.ascii.eqlIgnoreCase(name, "htmlevents") or std.ascii.eqlIgnoreCase(name, "svgevents")) iface = "Event" else if (std.ascii.eqlIgnoreCase(name, "mouseevent") or std.ascii.eqlIgnoreCase(name, "mouseevents")) iface = "MouseEvent" else if (std.ascii.eqlIgnoreCase(name, "keyboardevent")) iface = "KeyboardEvent" else if (std.ascii.eqlIgnoreCase(name, "uievent") or std.ascii.eqlIgnoreCase(name, "uievents")) iface = "UIEvent" else if (std.ascii.eqlIgnoreCase(name, "focusevent")) iface = "FocusEvent" else if (std.ascii.eqlIgnoreCase(name, "compositionevent")) iface = "CompositionEvent" else if (std.ascii.eqlIgnoreCase(name, "textevent")) iface = "TextEvent" else if (std.ascii.eqlIgnoreCase(name, "messageevent")) iface = "MessageEvent" else if (std.ascii.eqlIgnoreCase(name, "hashchangeevent")) iface = "HashChangeEvent" else if (std.ascii.eqlIgnoreCase(name, "storageevent")) iface = "StorageEvent" else if (std.ascii.eqlIgnoreCase(name, "beforeunloadevent")) iface = "BeforeUnloadEvent" else if (std.ascii.eqlIgnoreCase(name, "dragevent")) iface = "DragEvent" else if (std.ascii.eqlIgnoreCase(name, "touchevent")) iface = "TouchEvent" else if (std.ascii.eqlIgnoreCase(name, "devicemotionevent")) iface = "DeviceMotionEvent" else if (std.ascii.eqlIgnoreCase(name, "deviceorientationevent")) iface = "DeviceOrientationEvent" else {
                    // Non-legacy interface → NotSupportedError per DOM spec
                    return throwDOMException(c, "NotSupportedError", "The provided event type is not supported.");
                }
            }
        }
    }
    // Use direct string literals to avoid buffer issues
    const js_code: []const u8 = if (std.mem.eql(u8, iface, "CustomEvent"))
        "(new CustomEvent(''))"
    else if (std.mem.eql(u8, iface, "MouseEvent"))
        "(new MouseEvent(''))"
    else if (std.mem.eql(u8, iface, "KeyboardEvent"))
        "(new KeyboardEvent(''))"
    else if (std.mem.eql(u8, iface, "UIEvent"))
        "(new UIEvent(''))"
    else if (std.mem.eql(u8, iface, "FocusEvent"))
        "(new FocusEvent(''))"
    else if (std.mem.eql(u8, iface, "CompositionEvent"))
        "(new CompositionEvent(''))"
    else if (std.mem.eql(u8, iface, "TextEvent"))
        "(new TextEvent(''))"
    else if (std.mem.eql(u8, iface, "MessageEvent"))
        "(new MessageEvent(''))"
    else if (std.mem.eql(u8, iface, "TouchEvent"))
        "(new TouchEvent(''))"
    else if (std.mem.eql(u8, iface, "HashChangeEvent"))
        "(new HashChangeEvent(''))"
    else if (std.mem.eql(u8, iface, "PopStateEvent"))
        "(new PopStateEvent(''))"
    else if (std.mem.eql(u8, iface, "ProgressEvent"))
        "(new ProgressEvent(''))"
    else if (std.mem.eql(u8, iface, "BeforeUnloadEvent"))
        "(new BeforeUnloadEvent(''))"
    else if (std.mem.eql(u8, iface, "StorageEvent"))
        "(new StorageEvent(''))"
    else if (std.mem.eql(u8, iface, "PageTransitionEvent"))
        "(new PageTransitionEvent(''))"
    else if (std.mem.eql(u8, iface, "DragEvent"))
        "(new DragEvent(''))"
    else if (std.mem.eql(u8, iface, "DeviceMotionEvent"))
        "(new DeviceMotionEvent(''))"
    else if (std.mem.eql(u8, iface, "DeviceOrientationEvent"))
        "(new DeviceOrientationEvent(''))"
    else
        "(new Event(''))";
    const event_obj = qjs.JS_Eval(c, js_code.ptr, js_code.len, "<createEvent>", qjs.JS_EVAL_TYPE_GLOBAL);
    if (!quickjs.JS_IsException(event_obj)) {
        // DOM spec: createEvent returns an uninitialized event (type='', _initialized=false)
        _ = qjs.JS_SetPropertyStr(c, event_obj, "type", qjs.JS_NewString(c, ""));
        _ = qjs.JS_SetPropertyStr(c, event_obj, "_initialized", quickjs.JS_NewBool(false));
        _ = qjs.JS_SetPropertyStr(c, event_obj, "isTrusted", quickjs.JS_NewBool(false));
    }
    return event_obj;
}

// ── document.write ─────────────────────────────────────────────────

pub fn documentWrite(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    // Only works during loading phase
    if (api.g_ready_state != .loading) {
        std.log.warn("[JS] document.write called after page load, ignoring", .{});
        return quickjs.JS_UNDEFINED();
    }

    const str = qjs.JS_ToCString(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, str);
    const html = std.mem.span(str);

    if (html.len == 0) return quickjs.JS_UNDEFINED();

    std.log.info("[JS] document.write: {d} bytes", .{html.len});

    // Parse HTML fragment and append to body
    const doc_ptr = api.getDocument(c) orelse return quickjs.JS_UNDEFINED();
    const doc_node = getDocumentNode() orelse return quickjs.JS_UNDEFINED();
    const body_node = walkTreeByTag(doc_node, "body") orelse return quickjs.JS_UNDEFINED();
    const body_elem: *lxb.lxb_dom_element_t = @ptrCast(body_node);

    // Parse HTML fragment using lexbor
    const frag = lxb_html_document_parse_fragment(doc_ptr, body_elem, html.ptr, html.len) orelse return quickjs.JS_UNDEFINED();

    // Move children from fragment to body
    while (frag.first_child) |child| {
        lxb_dom_node_remove(child);
        lxb_dom_node_insert_child(body_node, child);
    }
    _ = lxb_dom_node_destroy(frag);

    // Check if <script> was injected (case-insensitive)
    {
        var has_script = false;
        var si: usize = 0;
        while (si + 7 < html.len) : (si += 1) {
            if (html[si] == '<' and
                (html[si + 1] == 's' or html[si + 1] == 'S') and
                (html[si + 2] == 'c' or html[si + 2] == 'C') and
                (html[si + 3] == 'r' or html[si + 3] == 'R') and
                (html[si + 4] == 'i' or html[si + 4] == 'I') and
                (html[si + 5] == 'p' or html[si + 5] == 'P') and
                (html[si + 6] == 't' or html[si + 6] == 'T'))
            {
                has_script = true;
                break;
            }
        }
        if (has_script) {
            std.log.warn("[JS] document.write injected <script> — execution not supported", .{});
        }
    }

    api.setDomDirty();
    return quickjs.JS_UNDEFINED();
}

// ── No-op constructor for DOM interface globals ─────────────────────

pub fn jsNoOpConstructor(
    ctx: ?*qjs.JSContext,
    new_target: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    // Create object with new.target.prototype for correct prototype chain
    const proto = qjs.JS_GetPropertyStr(c, new_target, "prototype");
    const obj = qjs.JS_NewObject(c);
    if (!quickjs.JS_IsUndefined(proto) and !quickjs.JS_IsNull(proto)) {
        _ = qjs.JS_SetPrototype(c, obj, proto);
    }
    qjs.JS_FreeValue(c, proto);
    return obj;
}

/// new Text(data?) — creates a real text node via document.createTextNode
pub fn jsTextConstructor(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const doc = api.getDocument(c) orelse return quickjs.JS_UNDEFINED();
    if (argc >= 1) {
        if (argv) |args| {
            if (!quickjs.JS_IsUndefined(args[0])) {
                if (api.jsStringToSlice(c, args[0])) |s| {
                    defer qjs.JS_FreeCString(c, s.ptr);
                    const node = lxb_dom_document_create_text_node(doc, s.ptr, s.len) orelse return quickjs.JS_UNDEFINED();
                    return wrapNode(c, node);
                }
            }
        }
    }
    const node = lxb_dom_document_create_text_node(doc, "", 0) orelse return quickjs.JS_UNDEFINED();
    return wrapNode(c, node);
}

/// new Comment(data?) — creates a real comment node via document.createComment
pub fn jsCommentConstructor(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const doc = api.getDocument(c) orelse return quickjs.JS_UNDEFINED();
    if (argc >= 1) {
        if (argv) |args| {
            // Convert to string (handles undefined -> "undefined" per JS, but spec says default is "")
            if (!quickjs.JS_IsUndefined(args[0])) {
                if (api.jsStringToSlice(c, args[0])) |s| {
                    defer qjs.JS_FreeCString(c, s.ptr);
                    const node = lxb_dom_document_create_comment(doc, s.ptr, s.len) orelse return quickjs.JS_UNDEFINED();
                    return wrapNode(c, node);
                }
            }
        }
    }
    const node = lxb_dom_document_create_comment(doc, "", 0) orelse return quickjs.JS_UNDEFINED();
    return wrapNode(c, node);
}

// ── DOMParser native parse ──────────────────────────────────────────
// Creates a new lexbor document, parses HTML, returns wrapped nodes.
// Called from JS as: __suzume_dom_parse(htmlString)
// Returns: { documentElement, body, head, hasDoctype, doctypeName, doctypePublicId, doctypeSystemId }

extern fn lxb_html_document_create() ?*anyopaque;
extern fn lxb_html_document_parse(document: *anyopaque, html: [*]const u8, size: usize) u32;
extern fn lxb_html_document_body_element_noi(document: *anyopaque) ?*lxb.lxb_dom_node_t;
extern fn lxb_html_document_head_element_noi(document: *anyopaque) ?*lxb.lxb_dom_node_t;

// Storage for DOMParser-created documents (prevent GC/free)
var parsed_docs: [16]?*anyopaque = .{null} ** 16;
var parsed_doc_count: usize = 0;

pub fn suzumeDomParse(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();

    const html_s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, html_s.ptr);

    // Create new lexbor document
    const new_doc = lxb_html_document_create() orelse return quickjs.JS_NULL();
    const status = lxb_html_document_parse(new_doc, html_s.ptr, html_s.len);
    if (status != 0) return quickjs.JS_NULL();

    // Store to prevent premature deallocation
    if (parsed_doc_count < parsed_docs.len) {
        parsed_docs[parsed_doc_count] = new_doc;
        parsed_doc_count += 1;
    }

    // Get key elements
    const doc_node: *lxb.lxb_dom_node_t = @ptrCast(@alignCast(new_doc));
    const body_node = lxb_html_document_body_element_noi(new_doc);
    const head_node = lxb_html_document_head_element_noi(new_doc);

    // Get document element (html) — it's the first element child of the document node
    var doc_element: ?*lxb.lxb_dom_node_t = null;
    {
        var child: ?*lxb.lxb_dom_node_t = doc_node.first_child;
        while (child) |ch| {
            if (ch.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
                doc_element = ch;
                break;
            }
            child = ch.next;
        }
    }

    // Build result object — wrap the document node so it has opaque pointer for addEventListener
    const result = wrapNode(c, doc_node);
    if (doc_element) |de| {
        _ = qjs.JS_SetPropertyStr(c, result, "documentElement", wrapNode(c, de));
    } else {
        _ = qjs.JS_SetPropertyStr(c, result, "documentElement", quickjs.JS_NULL());
    }
    if (body_node) |bn| {
        _ = qjs.JS_SetPropertyStr(c, result, "body", wrapNode(c, bn));
    } else {
        _ = qjs.JS_SetPropertyStr(c, result, "body", quickjs.JS_NULL());
    }
    if (head_node) |hn| {
        _ = qjs.JS_SetPropertyStr(c, result, "head", wrapNode(c, hn));
    } else {
        _ = qjs.JS_SetPropertyStr(c, result, "head", quickjs.JS_NULL());
    }

    // Check for doctype (first child of document, nodeType == 10)
    var has_doctype = false;
    {
        var child: ?*lxb.lxb_dom_node_t = doc_node.first_child;
        while (child) |ch| {
            if (ch.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT_TYPE) {
                has_doctype = true;
                // Get doctype name from the element's local_name
                const dt_elem: *lxb.lxb_dom_element_t = @ptrCast(ch);
                var name_len: usize = 0;
                const name_ptr = lxb_dom_element_local_name(dt_elem, &name_len);
                if (name_ptr) |np| {
                    _ = qjs.JS_SetPropertyStr(c, result, "doctypeName", qjs.JS_NewStringLen(c, np, name_len));
                } else {
                    _ = qjs.JS_SetPropertyStr(c, result, "doctypeName", qjs.JS_NewString(c, "html"));
                }
                break;
            }
            child = ch.next;
        }
    }
    _ = qjs.JS_SetPropertyStr(c, result, "hasDoctype", quickjs.JS_NewBool(has_doctype));

    return result;
}
