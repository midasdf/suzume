const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;
const lxb = @import("../bindings/lexbor.zig").c;
const api = @import("dom_api.zig");
const events = @import("events.zig");

// ── External Lexbor functions ────────────────────────────────────────
extern fn lxb_dom_document_create_element(document: *anyopaque, local_name: [*]const u8, lname_len: usize, reserved: ?*anyopaque) ?*lxb.lxb_dom_element_t;
/// Validate an HTML element name per HTML spec §13.1.2.1
/// HTML is very permissive — only empty and NUL are rejected
fn isValidElementName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| {
        if (ch == 0) return false; // NUL character
    }
    return true;
}

extern fn lxb_dom_document_create_text_node(document: *anyopaque, data: [*]const u8, len: usize) ?*lxb.lxb_dom_node_t;
extern fn lxb_dom_document_create_comment(document: *anyopaque, data: [*]const u8, len: usize) ?*lxb.lxb_dom_node_t;
extern fn lxb_dom_node_insert_child(to: *lxb.lxb_dom_node_t, node: *lxb.lxb_dom_node_t) void;
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
    _: qjs.JSValue,
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
    return qjs.JS_DupValue(c, node_val);
}

/// Validate an XML qualified name per https://dom.spec.whatwg.org/#validate
fn isValidXmlName(name: []const u8) bool {
    if (name.len == 0) return false;
    const first = name[0];
    // First char: letter, underscore, colon, or non-ASCII (UTF-8 multibyte)
    if (!std.ascii.isAlphabetic(first) and first != '_' and first != ':' and first < 0x80) return false;
    for (name[1..]) |ch| {
        // Subsequent: alphanumeric, _, :, -, ., or non-ASCII
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != ':' and ch != '-' and ch != '.' and ch < 0x80) return false;
    }
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
    _ = qjs.JS_SetPropertyStr(c, obj, "nodeValue", quickjs.JS_NULL());
    _ = qjs.JS_SetPropertyStr(c, obj, "textContent", quickjs.JS_NULL());
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
    // isEqualNode for DocumentType
    const ieq_js = "(function(o){if(!o||o.nodeType!==10)return false;return this.name===o.name&&this.publicId===o.publicId&&this.systemId===o.systemId;})";
    const ieq_fn = qjs.JS_Eval(c, ieq_js, ieq_js.len, "<dt-ieq>", qjs.JS_EVAL_TYPE_GLOBAL);
    _ = qjs.JS_SetPropertyStr(c, obj, "isEqualNode", ieq_fn);
    const isn_js = "(function(o){return this===o;})";
    const isn_fn = qjs.JS_Eval(c, isn_js, isn_js.len, "<dt-isn>", qjs.JS_EVAL_TYPE_GLOBAL);
    _ = qjs.JS_SetPropertyStr(c, obj, "isSameNode", isn_fn);
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

    // Get namespace and qualifiedName
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
    if (argc >= 2 and !quickjs.JS_IsNull(args[1]) and !quickjs.JS_IsUndefined(args[1])) {
        if (jsStringToSlice(c, args[1])) |s| {
            qname = s.ptr[0..s.len];
            qname_ptr = s.ptr;
        }
    }
    defer {
        if (ns_ptr) |p| qjs.JS_FreeCString(c, p);
        if (qname_ptr) |p| qjs.JS_FreeCString(c, p);
    }

    // Validate qualifiedName per DOM spec
    if (qname) |qn| {
        if (qn.len > 0 and !isValidXmlName(qn)) {
            return throwDOMException(c, "InvalidCharacterError", "The string contains invalid characters.");
        }
        // Check namespace constraints
        if (std.mem.indexOfScalar(u8, qn, ':')) |colon_pos| {
            // Has prefix — namespace must not be null
            if (ns == null) return throwDOMException(c, "NamespaceError", "The namespace URI provided is not valid for the given qualifiedName.");
            const prefix = qn[0..colon_pos];
            const local = qn[colon_pos + 1 ..];
            if (local.len == 0) return throwDOMException(c, "InvalidCharacterError", "The string contains invalid characters.");
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
    const range_js =
        \\(function(){
        \\  var r={startContainer:document,startOffset:0,endContainer:document,endOffset:0,commonAncestorContainer:document};
        \\  Object.defineProperty(r,'collapsed',{get:function(){return this.startContainer===this.endContainer&&this.startOffset===this.endOffset;},configurable:true,enumerable:true});
        \\  r._updateAncestor=function(){var a=this.startContainer,b=this.endContainer;if(a===b){this.commonAncestorContainer=a;return;}
        \\    var pa=[],n=a;while(n){pa.push(n);n=n.parentNode;}n=b;while(n){for(var i=0;i<pa.length;i++)if(pa[i]===n){this.commonAncestorContainer=n;return;}n=n.parentNode;}
        \\    this.commonAncestorContainer=document;};
        \\  r.setStart=function(n,o){this.startContainer=n;this.startOffset=o;this._updateAncestor();};
        \\  r.setEnd=function(n,o){this.endContainer=n;this.endOffset=o;this._updateAncestor();};
        \\  r.setStartBefore=function(n){this.startContainer=n.parentNode;var i=0;var c=n.parentNode.firstChild;while(c&&c!==n){i++;c=c.nextSibling;}this.startOffset=i;this._updateAncestor();};
        \\  r.setStartAfter=function(n){this.startContainer=n.parentNode;var i=0;var c=n.parentNode.firstChild;while(c&&c!==n){i++;c=c.nextSibling;}this.startOffset=i+1;this._updateAncestor();};
        \\  r.setEndBefore=function(n){this.endContainer=n.parentNode;var i=0;var c=n.parentNode.firstChild;while(c&&c!==n){i++;c=c.nextSibling;}this.endOffset=i;this._updateAncestor();};
        \\  r.setEndAfter=function(n){this.endContainer=n.parentNode;var i=0;var c=n.parentNode.firstChild;while(c&&c!==n){i++;c=c.nextSibling;}this.endOffset=i+1;this._updateAncestor();};
        \\  r.selectNode=function(n){if(n.parentNode){this.setStartBefore(n);this.setEndAfter(n);}};
        \\  r.selectNodeContents=function(n){this.startContainer=n;this.startOffset=0;this.endContainer=n;this.endOffset=n.childNodes?n.childNodes.length:0;this._updateAncestor();};
        \\  r.collapse=function(toStart){if(toStart){this.endContainer=this.startContainer;this.endOffset=this.startOffset;}else{this.startContainer=this.endContainer;this.startOffset=this.endOffset;}this._updateAncestor();};
        \\  r.cloneRange=function(){var nr=document.createRange();nr.setStart(this.startContainer,this.startOffset);nr.setEnd(this.endContainer,this.endOffset);return nr;};
        \\  r.cloneContents=function(){return document.createDocumentFragment();};
        \\  r.deleteContents=function(){};
        \\  r.extractContents=function(){return document.createDocumentFragment();};
        \\  r.insertNode=function(n){var sc=this.startContainer;if(sc.nodeType===3){var p=sc.parentNode;if(p)p.insertBefore(n,sc);}else{var ref=sc.childNodes[this.startOffset]||null;sc.insertBefore(n,ref);}};
        \\  r.surroundContents=function(n){};
        \\  r.compareBoundaryPoints=function(how,sr){return 0;};
        \\  r.isPointInRange=function(n,o){return false;};
        \\  r.comparePoint=function(n,o){return 0;};
        \\  r.intersectsNode=function(n){return false;};
        \\  r.detach=function(){};
        \\  r.toString=function(){return '';};
        \\  r.createContextualFragment=function(html){var t=document.createElement('div');t.innerHTML=html;var f=document.createDocumentFragment();while(t.firstChild)f.appendChild(t.firstChild);return f;};
        \\  r.getBoundingClientRect=function(){return{x:0,y:0,width:0,height:0,top:0,right:0,bottom:0,left:0};};
        \\  r.getClientRects=function(){return[];};
        \\  r.START_TO_START=0;r.START_TO_END=1;r.END_TO_END=2;r.END_TO_START=3;
        \\  return r;
        \\})()
    ;
    const range = qjs.JS_Eval(c, range_js, range_js.len, "<range>", qjs.JS_EVAL_TYPE_GLOBAL);
    return range;
}

pub fn documentCreateTreeWalker(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();

    // Get root node
    const root_val = if (argc >= 1) args[0] else return quickjs.JS_NULL();

    // Get whatToShow (default: SHOW_ALL = 0xFFFFFFFF)
    var what_to_show: i32 = -1; // 0xFFFFFFFF as signed
    if (argc >= 2) {
        _ = qjs.JS_ToInt32(c, &what_to_show, args[1]);
    }

    // Build TreeWalker as a JS polyfill that uses native DOM traversal
    const walker_js =
        \\(function(root, whatToShow, filter) {
        \\  var tw = {
        \\    root: root,
        \\    currentNode: root,
        \\    whatToShow: whatToShow,
        \\    filter: filter || null,
        \\    _accepts: function(node) {
        \\      if (whatToShow !== -1 && whatToShow !== 0xFFFFFFFF) {
        \\        var nt = node.nodeType;
        \\        var mask = 1 << (nt - 1);
        \\        if (!(whatToShow & mask)) return false;
        \\      }
        \\      if (this.filter) {
        \\        var r = typeof this.filter === 'function' ? this.filter(node) : this.filter.acceptNode(node);
        \\        return r === 1; /* NodeFilter.FILTER_ACCEPT */
        \\      }
        \\      return true;
        \\    },
        \\    nextNode: function() {
        \\      var node = this.currentNode;
        \\      // Try first child
        \\      if (node.firstChild) {
        \\        node = node.firstChild;
        \\        while (node) {
        \\          if (this._accepts(node)) { this.currentNode = node; return node; }
        \\          if (node.firstChild) { node = node.firstChild; continue; }
        \\          while (node && !node.nextSibling) {
        \\            node = node.parentNode;
        \\            if (!node || node === this.root) return null;
        \\          }
        \\          if (node) node = node.nextSibling;
        \\        }
        \\        return null;
        \\      }
        \\      // No children, try siblings
        \\      while (node && node !== this.root) {
        \\        if (node.nextSibling) {
        \\          node = node.nextSibling;
        \\          if (this._accepts(node)) { this.currentNode = node; return node; }
        \\          if (node.firstChild) {
        \\            node = node.firstChild;
        \\            while (node) {
        \\              if (this._accepts(node)) { this.currentNode = node; return node; }
        \\              if (node.firstChild) { node = node.firstChild; continue; }
        \\              while (node && !node.nextSibling) {
        \\                node = node.parentNode;
        \\                if (!node || node === this.root) return null;
        \\              }
        \\              if (node) node = node.nextSibling;
        \\            }
        \\          }
        \\          continue;
        \\        }
        \\        node = node.parentNode;
        \\      }
        \\      return null;
        \\    },
        \\    previousNode: function() {
        \\      var node = this.currentNode;
        \\      if (node === this.root) return null;
        \\      if (node.previousSibling) {
        \\        node = node.previousSibling;
        \\        while (node.lastChild) node = node.lastChild;
        \\        if (this._accepts(node)) { this.currentNode = node; return node; }
        \\      }
        \\      var parent = node.parentNode;
        \\      if (!parent || parent === this.root) return null;
        \\      if (this._accepts(parent)) { this.currentNode = parent; return parent; }
        \\      return null;
        \\    },
        \\    firstChild: function() {
        \\      var node = this.currentNode.firstChild;
        \\      while (node) {
        \\        if (this._accepts(node)) { this.currentNode = node; return node; }
        \\        node = node.nextSibling;
        \\      }
        \\      return null;
        \\    },
        \\    lastChild: function() {
        \\      var node = this.currentNode.lastChild;
        \\      while (node) {
        \\        if (this._accepts(node)) { this.currentNode = node; return node; }
        \\        node = node.previousSibling;
        \\      }
        \\      return null;
        \\    },
        \\    parentNode: function() {
        \\      var node = this.currentNode.parentNode;
        \\      if (node && node !== this.root && this._accepts(node)) {
        \\        this.currentNode = node;
        \\        return node;
        \\      }
        \\      return null;
        \\    },
        \\    nextSibling: function() {
        \\      var node = this.currentNode.nextSibling;
        \\      while (node) {
        \\        if (this._accepts(node)) { this.currentNode = node; return node; }
        \\        node = node.nextSibling;
        \\      }
        \\      return null;
        \\    },
        \\    previousSibling: function() {
        \\      var node = this.currentNode.previousSibling;
        \\      while (node) {
        \\        if (this._accepts(node)) { this.currentNode = node; return node; }
        \\        node = node.previousSibling;
        \\      }
        \\      return null;
        \\    }
        \\  };
        \\  return tw;
        \\})
    ;
    const walker_fn = qjs.JS_Eval(c, walker_js, walker_js.len, "<treeWalker>", qjs.JS_EVAL_TYPE_GLOBAL);
    if (quickjs.JS_IsException(walker_fn)) return quickjs.JS_NULL();
    defer qjs.JS_FreeValue(c, walker_fn);

    const filter_val = if (argc >= 3) qjs.JS_DupValue(c, args[2]) else quickjs.JS_NULL();
    var call_args = [_]qjs.JSValue{
        qjs.JS_DupValue(c, root_val),
        qjs.JS_NewInt32(c, what_to_show),
        filter_val,
    };
    const result = qjs.JS_Call(c, walker_fn, quickjs.JS_UNDEFINED(), 3, &call_args);
    qjs.JS_FreeValue(c, call_args[0]);
    qjs.JS_FreeValue(c, call_args[1]);
    qjs.JS_FreeValue(c, call_args[2]);
    return result;
}

pub fn jsReturnNull(
    _: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    return quickjs.JS_NULL();
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
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, s.ptr);

    const doc_node = getDocumentNode() orelse return quickjs.JS_NULL();
    const found = api.dom_sel.walkTreeById(doc_node, s.ptr[0..s.len]) orelse return quickjs.JS_NULL();
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

    var selector_buf: [256]u8 = undefined;
    const class_name = s.ptr[0..s.len];
    if (class_name.len + 1 > selector_buf.len) return quickjs.JS_NULL();
    selector_buf[0] = '.';
    @memcpy(selector_buf[1 .. 1 + class_name.len], class_name);

    const arr = qjs.JS_NewArray(c);
    if (quickjs.JS_IsException(arr)) return arr;
    const doc_node = getDocumentNode() orelse return arr;
    var idx: u32 = 0;
    api.dom_sel.walkTreeCollect(c, doc_node, selector_buf[0 .. 1 + class_name.len], arr, &idx);
    return arr;
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
    return arr;
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

    var selector_buf: [270]u8 = undefined;
    const name = s.ptr[0..s.len];
    const prefix = "[name=\"";
    const suffix = "\"]";
    if (prefix.len + name.len + suffix.len > selector_buf.len) return quickjs.JS_NULL();
    @memcpy(selector_buf[0..prefix.len], prefix);
    @memcpy(selector_buf[prefix.len .. prefix.len + name.len], name);
    @memcpy(selector_buf[prefix.len + name.len .. prefix.len + name.len + suffix.len], suffix);

    const arr = qjs.JS_NewArray(c);
    if (quickjs.JS_IsException(arr)) return arr;
    const doc_node = getDocumentNode() orelse return arr;
    var idx: u32 = 0;
    api.dom_sel.walkTreeCollect(c, doc_node, selector_buf[0 .. prefix.len + name.len + suffix.len], arr, &idx);
    return arr;
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

pub fn documentCreateElementNS(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 2) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const s = jsStringToSlice(c, args[1]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, s.ptr);

    const doc = api.getDocument(c) orelse return quickjs.JS_NULL();
    // Handle qualified name (prefix:localName)
    const tag = s.ptr[0..s.len];
    const elem = lxb_dom_document_create_element(doc, tag.ptr, tag.len, null) orelse return quickjs.JS_NULL();
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    const obj = wrapNode(c, node);
    // Set namespace-related properties on the JS object
    _ = qjs.JS_SetPropertyStr(c, obj, "namespaceURI", qjs.JS_DupValue(c, args[0]));
    // Parse prefix from qualifiedName
    if (std.mem.indexOf(u8, tag, ":")) |colon_pos| {
        _ = qjs.JS_SetPropertyStr(c, obj, "prefix", qjs.JS_NewStringLen(c, tag.ptr, colon_pos));
        _ = qjs.JS_SetPropertyStr(c, obj, "localName", qjs.JS_NewStringLen(c, tag.ptr + colon_pos + 1, tag.len - colon_pos - 1));
    } else {
        _ = qjs.JS_SetPropertyStr(c, obj, "prefix", quickjs.JS_NULL());
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
    // Walk to find <body> element
    const found = walkTreeByTag(doc_node, "body") orelse return quickjs.JS_NULL();
    return wrapNode(c, found);
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
    return qjs.JS_NewStringLen(c, ptr.?, len);
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
    if (walkTreeByTag(doc_node, "title")) |title_node| {
        // Remove all existing children
        while (title_node.first_child) |child| {
            lxb_dom_node_remove(child);
            _ = lxb_dom_node_destroy(child);
        }
        // Create new text node with the title content
        const doc_ptr = api.g_document orelse return quickjs.JS_UNDEFINED();
        const text_node = lxb_dom_document_create_text_node(doc_ptr, new_title.ptr, new_title.len);
        if (text_node) |tn| {
            lxb_dom_node_insert_child(title_node, @ptrCast(tn));
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
    // Override nodeType and nodeName to match DocumentFragment spec
    _ = qjs.JS_SetPropertyStr(c, obj, "nodeType", qjs.JS_NewInt32(c, 11));
    _ = qjs.JS_SetPropertyStr(c, obj, "nodeName", qjs.JS_NewString(c, "#document-fragment"));
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
                if (std.ascii.eqlIgnoreCase(name, "customevent") or std.ascii.eqlIgnoreCase(name, "customevent")) iface = "CustomEvent"
                else if (std.ascii.eqlIgnoreCase(name, "event") or std.ascii.eqlIgnoreCase(name, "events") or std.ascii.eqlIgnoreCase(name, "htmlevents")) iface = "Event"
                else if (std.ascii.eqlIgnoreCase(name, "mouseevent") or std.ascii.eqlIgnoreCase(name, "mouseevents")) iface = "MouseEvent"
                else if (std.ascii.eqlIgnoreCase(name, "keyboardevent")) iface = "KeyboardEvent"
                else if (std.ascii.eqlIgnoreCase(name, "uievent") or std.ascii.eqlIgnoreCase(name, "uievents")) iface = "UIEvent"
                else if (std.ascii.eqlIgnoreCase(name, "focusevent")) iface = "FocusEvent"
                else if (std.ascii.eqlIgnoreCase(name, "wheelevent")) iface = "WheelEvent"
                else if (std.ascii.eqlIgnoreCase(name, "compositionevent")) iface = "CompositionEvent"
                else if (std.ascii.eqlIgnoreCase(name, "messageevent")) iface = "MessageEvent"
                else if (std.ascii.eqlIgnoreCase(name, "inputevent")) iface = "InputEvent"
                else if (std.ascii.eqlIgnoreCase(name, "pointerevent")) iface = "PointerEvent"
                else if (std.ascii.eqlIgnoreCase(name, "touchevent")) iface = "TouchEvent"
                else if (std.ascii.eqlIgnoreCase(name, "hashchangeevent")) iface = "HashChangeEvent"
                else if (std.ascii.eqlIgnoreCase(name, "popstateevent")) iface = "PopStateEvent"
                else if (std.ascii.eqlIgnoreCase(name, "errorevent")) iface = "ErrorEvent"
                else if (std.ascii.eqlIgnoreCase(name, "progressevent")) iface = "ProgressEvent"
                else if (std.ascii.eqlIgnoreCase(name, "closeevent")) iface = "CloseEvent"
                else if (std.ascii.eqlIgnoreCase(name, "beforeunloadevent")) iface = "BeforeUnloadEvent"
                else if (std.ascii.eqlIgnoreCase(name, "storageevent")) iface = "StorageEvent"
                else if (std.ascii.eqlIgnoreCase(name, "transitionevent")) iface = "TransitionEvent"
                else if (std.ascii.eqlIgnoreCase(name, "animationevent")) iface = "AnimationEvent"
                else if (std.ascii.eqlIgnoreCase(name, "pagetransitionevent")) iface = "PageTransitionEvent"
                else if (std.ascii.eqlIgnoreCase(name, "dragevent") or std.ascii.eqlIgnoreCase(name, "dragevents")) iface = "DragEvent"
                else if (std.ascii.eqlIgnoreCase(name, "svgevents")) iface = "Event";
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
    else if (std.mem.eql(u8, iface, "WheelEvent"))
        "(new WheelEvent(''))"
    else if (std.mem.eql(u8, iface, "CompositionEvent"))
        "(new CompositionEvent(''))"
    else if (std.mem.eql(u8, iface, "MessageEvent"))
        "(new MessageEvent(''))"
    else if (std.mem.eql(u8, iface, "InputEvent"))
        "(new InputEvent(''))"
    else if (std.mem.eql(u8, iface, "PointerEvent"))
        "(new PointerEvent(''))"
    else if (std.mem.eql(u8, iface, "TouchEvent"))
        "(new TouchEvent(''))"
    else if (std.mem.eql(u8, iface, "HashChangeEvent"))
        "(new HashChangeEvent(''))"
    else if (std.mem.eql(u8, iface, "PopStateEvent"))
        "(new PopStateEvent(''))"
    else if (std.mem.eql(u8, iface, "ErrorEvent"))
        "(new ErrorEvent(''))"
    else if (std.mem.eql(u8, iface, "ProgressEvent"))
        "(new ProgressEvent(''))"
    else if (std.mem.eql(u8, iface, "CloseEvent"))
        "(new CloseEvent(''))"
    else if (std.mem.eql(u8, iface, "BeforeUnloadEvent"))
        "(new BeforeUnloadEvent(''))"
    else if (std.mem.eql(u8, iface, "StorageEvent"))
        "(new StorageEvent(''))"
    else if (std.mem.eql(u8, iface, "TransitionEvent"))
        "(new TransitionEvent(''))"
    else if (std.mem.eql(u8, iface, "AnimationEvent"))
        "(new AnimationEvent(''))"
    else if (std.mem.eql(u8, iface, "PageTransitionEvent"))
        "(new PageTransitionEvent(''))"
    else if (std.mem.eql(u8, iface, "DragEvent"))
        "(new DragEvent(''))"
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
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewObject(c);
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
