// iframe support — detection, loading, context creation

const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;
const lxb = @import("../bindings/lexbor.zig").c;
const api = @import("dom_api.zig");
const frame_state = @import("frame_state.zig");
const FrameState = frame_state.FrameState;
const events = @import("events.zig");
const Document = @import("../dom/tree.zig").Document;
const Loader = @import("../net/loader.zig").Loader;
const resolveUrl = @import("../net/loader.zig").resolveUrl;

extern fn lxb_dom_element_get_attribute(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize, value_len: *usize) ?[*]const u8;
extern fn lxb_dom_element_local_name(element: *lxb.lxb_dom_element_t, len: *usize) ?[*]const u8;

// ── iframe Detection ────────────────────────────────────────────────

/// Walk DOM tree and set up contentDocument/contentWindow for each <iframe>.
pub fn processIframes(
    parent_ctx: *qjs.JSContext,
    rt: *qjs.JSRuntime,
    doc_node: *lxb.lxb_dom_node_t,
    parent_frame: *FrameState,
    allocator: std.mem.Allocator,
) void {
    _ = rt;
    walkForIframes(parent_ctx, doc_node, parent_frame, allocator, 0);
}

fn walkForIframes(
    parent_ctx: *qjs.JSContext,
    node: *lxb.lxb_dom_node_t,
    parent_frame: *FrameState,
    allocator: std.mem.Allocator,
    depth: u32,
) void {
    if (depth > frame_state.MAX_IFRAME_DEPTH) return;

    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        if (ch.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            const elem: *lxb.lxb_dom_element_t = @ptrCast(ch);
            var name_len: usize = 0;
            const name = lxb_dom_element_local_name(elem, &name_len);
            if (name != null and name_len == 6 and std.mem.eql(u8, name.?[0..6], "iframe")) {
                setupIframe(parent_ctx, elem, parent_frame, allocator, depth);
            }
            walkForIframes(parent_ctx, ch, parent_frame, allocator, depth);
        }
        child = ch.next;
    }
}

fn setupIframe(
    parent_ctx: *qjs.JSContext,
    elem: *lxb.lxb_dom_element_t,
    parent_frame: *FrameState,
    allocator: std.mem.Allocator,
    depth: u32,
) void {
    _ = parent_frame;
    _ = depth;

    // Get src and srcdoc attributes
    var src_len: usize = 0;
    const src_ptr = lxb_dom_element_get_attribute(elem, "src", 3, &src_len);
    var srcdoc_len: usize = 0;
    const srcdoc_ptr = lxb_dom_element_get_attribute(elem, "srcdoc", 6, &srcdoc_len);

    // Wrap the iframe element for JS property setting
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    const js_elem = api.wrapNode(parent_ctx, node);
    defer qjs.JS_FreeValue(parent_ctx, js_elem);

    // Try to load iframe content
    var content_doc_js: qjs.JSValue = quickjs.JS_UNDEFINED();
    var iframe_url: []const u8 = "about:blank";

    if (srcdoc_ptr != null and srcdoc_len > 0) {
        // srcdoc: parse inline HTML
        content_doc_js = createDocumentFromHTML(parent_ctx, srcdoc_ptr.?[0..srcdoc_len], "about:srcdoc");
        iframe_url = "about:srcdoc";
    } else if (src_ptr != null and src_len > 0) {
        // src: fetch URL and parse
        const src = src_ptr.?[0..src_len];
        content_doc_js = fetchAndCreateDocument(parent_ctx, src, allocator);
        iframe_url = src;
    }

    // If no content loaded, create about:blank
    if (quickjs.JS_IsUndefined(content_doc_js) or quickjs.JS_IsException(content_doc_js)) {
        content_doc_js = createAboutBlankDocument(parent_ctx);
    }

    // Set URL on the document
    _ = qjs.JS_SetPropertyStr(parent_ctx, content_doc_js, "URL", qjs.JS_NewStringLen(parent_ctx, iframe_url.ptr, iframe_url.len));
    _ = qjs.JS_SetPropertyStr(parent_ctx, content_doc_js, "documentURI", qjs.JS_NewStringLen(parent_ctx, iframe_url.ptr, iframe_url.len));

    // Set contentDocument
    _ = qjs.JS_SetPropertyStr(parent_ctx, js_elem, "contentDocument", qjs.JS_DupValue(parent_ctx, content_doc_js));

    // Create contentWindow
    const cw_js =
        \\(function(doc, url){
        \\  var w = {
        \\    document: doc,
        \\    parent: window,
        \\    top: window.top || window,
        \\    self: null,
        \\    location: { href: url, protocol: 'http:', host: location.host, hostname: location.hostname },
        \\    navigator: window.navigator,
        \\    addEventListener: function(t,f,o){doc.addEventListener(t,f,o);},
        \\    removeEventListener: function(t,f,o){doc.removeEventListener(t,f,o);},
        \\    dispatchEvent: function(e){return true;},
        \\    getComputedStyle: window.getComputedStyle,
        \\    setTimeout: window.setTimeout,
        \\    setInterval: window.setInterval,
        \\    clearTimeout: window.clearTimeout,
        \\    clearInterval: window.clearInterval,
        \\    matchMedia: window.matchMedia,
        \\    CSS: window.CSS,
        \\    Node: window.Node,
        \\    Element: window.Element,
        \\    Document: window.Document,
        \\    Event: window.Event,
        \\    CustomEvent: window.CustomEvent,
        \\    MouseEvent: window.MouseEvent,
        \\    KeyboardEvent: window.KeyboardEvent
        \\  };
        \\  w.self = w;
        \\  w.window = w;
        \\  return w;
        \\})
    ;
    const cw_fn = qjs.JS_Eval(parent_ctx, cw_js, cw_js.len, "<iframe-cw>", qjs.JS_EVAL_TYPE_GLOBAL);
    var cw_args = [2]qjs.JSValue{ content_doc_js, qjs.JS_NewStringLen(parent_ctx, iframe_url.ptr, iframe_url.len) };
    const content_window = qjs.JS_Call(parent_ctx, cw_fn, quickjs.JS_UNDEFINED(), 2, &cw_args);
    qjs.JS_FreeValue(parent_ctx, cw_fn);
    qjs.JS_FreeValue(parent_ctx, cw_args[1]);

    _ = qjs.JS_SetPropertyStr(parent_ctx, js_elem, "contentWindow", content_window);
    _ = qjs.JS_SetPropertyStr(parent_ctx, content_window, "frameElement", qjs.JS_DupValue(parent_ctx, js_elem));

    qjs.JS_FreeValue(parent_ctx, content_doc_js);
}

// ── Document Creation Helpers ───────────────────────────────────────

fn createAboutBlankDocument(ctx: *qjs.JSContext) qjs.JSValue {
    const js =
        \\(function(){
        \\  var d = new Document();
        \\  d.contentType = 'text/html';
        \\  d.URL = 'about:blank';
        \\  d.documentURI = 'about:blank';
        \\  return d;
        \\})()
    ;
    return qjs.JS_Eval(ctx, js, js.len, "<iframe-blank>", qjs.JS_EVAL_TYPE_GLOBAL);
}

fn createDocumentFromHTML(ctx: *qjs.JSContext, html: []const u8, url: []const u8) qjs.JSValue {
    _ = url;
    // Parse HTML using DOMParser polyfill
    // This creates a Document-like object with querySelector etc.
    const parser_js =
        \\(function(html){
        \\  var p = new DOMParser();
        \\  return p.parseFromString(html, 'text/html');
        \\})
    ;
    const fn_val = qjs.JS_Eval(ctx, parser_js, parser_js.len, "<iframe-parse>", qjs.JS_EVAL_TYPE_GLOBAL);
    if (quickjs.JS_IsException(fn_val)) return fn_val;

    var args = [1]qjs.JSValue{qjs.JS_NewStringLen(ctx, html.ptr, html.len)};
    const result = qjs.JS_Call(ctx, fn_val, quickjs.JS_UNDEFINED(), 1, &args);
    qjs.JS_FreeValue(ctx, fn_val);
    qjs.JS_FreeValue(ctx, args[0]);
    return result;
}

fn fetchAndCreateDocument(ctx: *qjs.JSContext, src: []const u8, allocator: std.mem.Allocator) qjs.JSValue {
    const loader = api.g_loader orelse return quickjs.JS_UNDEFINED();

    // Resolve relative URL
    const base = api.g_top_frame.current_url orelse "";
    const resolved = resolveUrl(allocator, src, base) catch return quickjs.JS_UNDEFINED();
    defer allocator.free(resolved);

    // Fetch content
    var response = loader.loadBytes(resolved) catch return quickjs.JS_UNDEFINED();
    defer response.deinit();

    // Determine content type from HTTP header or URL extension
    const ct = response.content_type;
    const is_xml = std.mem.indexOf(u8, ct, "xml") != null or
        std.mem.indexOf(u8, ct, "svg") != null or
        std.mem.endsWith(u8, src, ".xml") or
        std.mem.endsWith(u8, src, ".xhtml") or
        std.mem.endsWith(u8, src, ".svg");

    if (is_xml) {
        // Create XML document via DOMParser
        const parser_js =
            \\(function(text){
            \\  var p = new DOMParser();
            \\  var d = p.parseFromString(text, 'application/xml');
            \\  d.contentType = 'application/xml';
            \\  return d;
            \\})
        ;
        const fn_val = qjs.JS_Eval(ctx, parser_js, parser_js.len, "<iframe-xml>", qjs.JS_EVAL_TYPE_GLOBAL);
        if (quickjs.JS_IsException(fn_val)) return fn_val;

        var args = [1]qjs.JSValue{qjs.JS_NewStringLen(ctx, response.body.ptr, response.body.len)};
        const result = qjs.JS_Call(ctx, fn_val, quickjs.JS_UNDEFINED(), 1, &args);
        qjs.JS_FreeValue(ctx, fn_val);
        qjs.JS_FreeValue(ctx, args[0]);
        return result;
    } else {
        // HTML document
        return createDocumentFromHTML(ctx, response.body, src);
    }
}
