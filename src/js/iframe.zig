// iframe support — detection, loading, JS context creation, script execution

const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;
const lxb = @import("../bindings/lexbor.zig").c;
const api = @import("dom_api.zig");
const frame_state = @import("frame_state.zig");
const FrameState = frame_state.FrameState;
const events = @import("events.zig");
const web_api = @import("web_api.zig");
const Document = @import("../dom/tree.zig").Document;
const Loader = @import("../net/loader.zig").Loader;
const resolveUrl = @import("../net/loader.zig").resolveUrl;

extern fn lxb_dom_element_get_attribute(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize, value_len: *usize) ?[*]const u8;
extern fn lxb_dom_element_local_name(element: *lxb.lxb_dom_element_t, len: *usize) ?[*]const u8;

// ── iframe Frame Storage ────────────────────────────────────────────

var iframe_frames: [frame_state.MAX_IFRAME_COUNT]FrameState = [_]FrameState{.{}} ** frame_state.MAX_IFRAME_COUNT;
var iframe_contexts: [frame_state.MAX_IFRAME_COUNT]?*qjs.JSContext = [_]?*qjs.JSContext{null} ** frame_state.MAX_IFRAME_COUNT;
var iframe_docs: [frame_state.MAX_IFRAME_COUNT]?Document = [_]?Document{null} ** frame_state.MAX_IFRAME_COUNT;
var iframe_count: u32 = 0;

// ── iframe Detection ────────────────────────────────────────────────

const FontCache = @import("../paint/painter.zig").FontCache;

pub fn processIframes(
    parent_ctx: *qjs.JSContext,
    rt: *qjs.JSRuntime,
    doc_node: *lxb.lxb_dom_node_t,
    parent_frame: *FrameState,
    allocator: std.mem.Allocator,
    fonts: ?*FontCache,
) void {
    walkForIframes(parent_ctx, rt, doc_node, parent_frame, allocator, 0, fonts);
}

fn walkForIframes(
    parent_ctx: *qjs.JSContext,
    rt: *qjs.JSRuntime,
    node: *lxb.lxb_dom_node_t,
    parent_frame: *FrameState,
    allocator: std.mem.Allocator,
    depth: u32,
    fonts: ?*FontCache,
) void {
    if (depth > frame_state.MAX_IFRAME_DEPTH) return;

    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        if (ch.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            const elem: *lxb.lxb_dom_element_t = @ptrCast(ch);
            var name_len: usize = 0;
            const name = lxb_dom_element_local_name(elem, &name_len);
            if (name != null and name_len == 6 and std.mem.eql(u8, name.?[0..6], "iframe")) {
                setupIframe(parent_ctx, rt, elem, parent_frame, allocator, depth, fonts);
            }
            if (name == null or name_len != 6 or !std.mem.eql(u8, name.?[0..6], "iframe")) {
                walkForIframes(parent_ctx, rt, ch, parent_frame, allocator, depth, fonts);
            }
        }
        child = ch.next;
    }
}

fn setupIframe(
    parent_ctx: *qjs.JSContext,
    rt: *qjs.JSRuntime,
    elem: *lxb.lxb_dom_element_t,
    parent_frame: *FrameState,
    allocator: std.mem.Allocator,
    depth: u32,
    fonts: ?*FontCache,
) void {
    if (iframe_count >= frame_state.MAX_IFRAME_COUNT) return;

    // Get src and srcdoc attributes
    var src_len: usize = 0;
    const src_ptr = lxb_dom_element_get_attribute(elem, "src", 3, &src_len);
    var srcdoc_len: usize = 0;
    const srcdoc_ptr = lxb_dom_element_get_attribute(elem, "srcdoc", 6, &srcdoc_len);

    // Determine content source
    var html_content: ?[]const u8 = null;
    var iframe_url: []const u8 = "about:blank";
    var fetched_html: ?[]u8 = null;
    defer if (fetched_html) |fh| allocator.free(fh);

    var is_xml = false;
    if (srcdoc_ptr != null and srcdoc_len > 0) {
        html_content = srcdoc_ptr.?[0..srcdoc_len];
        iframe_url = "about:srcdoc";
    } else if (src_ptr != null and src_len > 0) {
        // Fetch src URL
        const src = src_ptr.?[0..src_len];
        is_xml = isXmlUrl(src);
        if (fetchIframeContent(src, allocator)) |content| {
            fetched_html = content;
            html_content = content;
            iframe_url = src;
        }
    }

    // Parse HTML into real Lexbor Document
    const iframe_doc = if (html_content) |html|
        Document.parse(html) catch null
    else
        Document.parse("<!DOCTYPE html><html><head></head><body></body></html>") catch null;

    if (iframe_doc == null) return;

    const idx = iframe_count;
    iframe_docs[idx] = iframe_doc;
    iframe_count += 1;

    const doc_ptr: *anyopaque = @ptrCast(@alignCast(iframe_doc.?.html_doc));

    // Create new JSContext on the same Runtime
    const iframe_ctx = qjs.JS_NewContext(rt) orelse return;
    iframe_contexts[idx] = iframe_ctx;

    // Create FrameState for this iframe
    iframe_frames[idx] = .{
        .document = doc_ptr,
        .ctx = iframe_ctx,
        .current_url = iframe_url,
        .parent_frame = parent_frame,
        .depth = depth + 1,
        .is_xml = is_xml,
    };
    qjs.JS_SetContextOpaque(iframe_ctx, @ptrCast(&iframe_frames[idx]));

    // Save ALL parent globals BEFORE registerDomApis/registerWebApis overwrites them
    const saved_doc = api.g_document;
    const saved_url = api.g_top_frame.current_url;
    const saved_dirty = api.dom_dirty;
    const saved_web_ctx = web_api.getGlobalCtx();

    // Register DOM APIs on iframe context (classes already registered on Runtime)
    api.registerDomApis(rt, iframe_ctx, doc_ptr);
    events.registerEventApis(iframe_ctx);

    // registerWebApis expects a struct with .ctx field
    const CtxWrapper = struct { ctx: *qjs.JSContext };
    var ctx_wrap = CtxWrapper{ .ctx = iframe_ctx };
    web_api.registerWebApis(&ctx_wrap);

    // Inject event methods into Element prototype
    events.injectElementEventMethods(iframe_ctx, api.element_class_id);

    // CRITICAL: While g_document still points to the iframe's document,
    // capture documentElement/body/head elements and override the getters
    // using JS closures. Otherwise, after g_document is restored, the
    // native getters would return the parent's elements.
    {
        const iframe_global_tmp = qjs.JS_GetGlobalObject(iframe_ctx);
        defer qjs.JS_FreeValue(iframe_ctx, iframe_global_tmp);
        const iframe_doc_tmp = qjs.JS_GetPropertyStr(iframe_ctx, iframe_global_tmp, "document");
        defer qjs.JS_FreeValue(iframe_ctx, iframe_doc_tmp);

        // Get elements while g_document is correct
        const docEl = qjs.JS_GetPropertyStr(iframe_ctx, iframe_doc_tmp, "documentElement");
        const bodyEl = qjs.JS_GetPropertyStr(iframe_ctx, iframe_doc_tmp, "body");
        const headEl = qjs.JS_GetPropertyStr(iframe_ctx, iframe_doc_tmp, "head");

        // Override getters with closures that capture the correct elements
        const fix_js =
            \\(function(doc,de,b,h){
            \\  Object.defineProperty(doc,'documentElement',{get:function(){return de;},configurable:true,enumerable:true});
            \\  Object.defineProperty(doc,'body',{get:function(){return b;},configurable:true,enumerable:true});
            \\  Object.defineProperty(doc,'head',{get:function(){return h;},configurable:true,enumerable:true});
            \\})
        ;
        const fix_fn = qjs.JS_Eval(iframe_ctx, fix_js, fix_js.len, "<iframe-fix>", qjs.JS_EVAL_TYPE_GLOBAL);
        if (!quickjs.JS_IsException(fix_fn)) {
            var fix_args = [4]qjs.JSValue{ iframe_doc_tmp, docEl, bodyEl, headEl };
            const fix_r = qjs.JS_Call(iframe_ctx, fix_fn, quickjs.JS_UNDEFINED(), 4, &fix_args);
            qjs.JS_FreeValue(iframe_ctx, fix_r);
        }
        qjs.JS_FreeValue(iframe_ctx, fix_fn);
        qjs.JS_FreeValue(iframe_ctx, docEl);
        qjs.JS_FreeValue(iframe_ctx, bodyEl);
        qjs.JS_FreeValue(iframe_ctx, headEl);
    }

    // Restore parent globals (registerDomApis/registerWebApis overwrote them)
    api.g_document = saved_doc;
    api.g_top_frame.document = saved_doc;
    api.g_top_frame.current_url = saved_url;
    api.dom_dirty = saved_dirty;
    web_api.setGlobalCtx(saved_web_ctx);

    // Build iframe layout (cascade → box tree → layout)
    buildIframeLayout(iframe_doc, elem, allocator, idx, fonts);

    // Set contentDocument on parent's iframe element
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    const js_elem = api.wrapNode(parent_ctx, node);
    defer qjs.JS_FreeValue(parent_ctx, js_elem);

    // Get the iframe context's document object
    const iframe_global = qjs.JS_GetGlobalObject(iframe_ctx);
    const iframe_doc_obj = qjs.JS_GetPropertyStr(iframe_ctx, iframe_global, "document");

    // For XML iframes: override documentElement to return body.firstChild (the actual XML root)
    // Lexbor (HTML5 parser) wraps XML content in <html><head></head><body>...</body></html>
    // Note: XHTML files (.xhtml) keep standard HTML document structure
    if (is_xml) {
        // Determine if this is pure XML vs XHTML/MathML
        const is_xhtml = blk: {
            var path = iframe_url;
            if (std.mem.indexOfScalar(u8, path, '?')) |q| path = path[0..q];
            if (std.mem.indexOfScalar(u8, path, '#')) |h| path = path[0..h];
            if (std.mem.endsWith(u8, path, ".xhtml")) break :blk true;
            break :blk false;
        };
        const xml_fix_js = if (is_xhtml)
            \\(function(doc){
            \\  doc.contentType='application/xhtml+xml';
            \\})
        else
            \\(function(doc){
            \\  doc.contentType='application/xml';
            \\  var b=doc.body||doc.getElementsByTagName('body')[0];
            \\  if(b&&b.firstChild){
            \\    var xmlRoot=b.firstChild;
            \\    Object.defineProperty(doc,'documentElement',{get:function(){return xmlRoot;},configurable:true,enumerable:true});
            \\    Object.defineProperty(doc,'body',{get:function(){return null;},configurable:true,enumerable:true});
            \\    Object.defineProperty(doc,'head',{get:function(){return null;},configurable:true,enumerable:true});
            \\  }
            \\})
        ;
        const xml_fn = qjs.JS_Eval(iframe_ctx, xml_fix_js, xml_fix_js.len, "<xml-fix>", qjs.JS_EVAL_TYPE_GLOBAL);
        if (!quickjs.JS_IsException(xml_fn)) {
            var xml_args = [1]qjs.JSValue{qjs.JS_DupValue(iframe_ctx, iframe_doc_obj)};
            const xml_result = qjs.JS_Call(iframe_ctx, xml_fn, quickjs.JS_UNDEFINED(), 1, &xml_args);
            qjs.JS_FreeValue(iframe_ctx, xml_result);
            qjs.JS_FreeValue(iframe_ctx, xml_args[0]);
            qjs.JS_FreeValue(iframe_ctx, xml_fn);
        }
    }

    // Set contentDocument (cross-context: we set it as a property on the parent element)
    // Note: This is a simplified cross-context bridge — the document object
    // was created in iframe_ctx but we reference it from parent_ctx.
    // For same-origin iframes this works in QuickJS since they share the Runtime.
    _ = qjs.JS_SetPropertyStr(parent_ctx, js_elem, "contentDocument", iframe_doc_obj);

    // Create contentWindow proxy in parent context
    // This is a bridge object that delegates to the iframe's global
    const cw_js =
        \\(function(iframeGlobal){
        \\  var cw={
        \\    document: iframeGlobal.document,
        \\    parent: window,
        \\    top: window.top || window,
        \\    self: iframeGlobal,
        \\    window: iframeGlobal,
        \\    location: { href: iframeGlobal.location ? iframeGlobal.location.href : 'about:blank' },
        \\    navigator: window.navigator,
        \\    addEventListener: function(t,f,o){iframeGlobal.addEventListener(t,f,o);},
        \\    removeEventListener: function(t,f,o){iframeGlobal.removeEventListener(t,f,o);},
        \\    dispatchEvent: function(e){return iframeGlobal.dispatchEvent(e);},
        \\    getComputedStyle: iframeGlobal.getComputedStyle,
        \\    setTimeout: iframeGlobal.setTimeout,
        \\    setInterval: iframeGlobal.setInterval,
        \\    clearTimeout: iframeGlobal.clearTimeout,
        \\    clearInterval: iframeGlobal.clearInterval
        \\  };
        \\  var names=['Element','Node','HTMLElement','Document','DocumentFragment','DocumentType',
        \\    'Text','Comment','ProcessingInstruction','Event','CustomEvent','DOMException',
        \\    'HTMLHtmlElement','HTMLHeadElement','HTMLBodyElement','HTMLDivElement','HTMLSpanElement',
        \\    'HTMLParagraphElement','HTMLInputElement','HTMLFormElement','HTMLAnchorElement',
        \\    'HTMLImageElement','HTMLScriptElement','HTMLStyleElement','HTMLLinkElement',
        \\    'HTMLIFrameElement','HTMLUnknownElement','NodeList','HTMLCollection',
        \\    'NodeFilter','DOMParser','XMLSerializer','CSS','MutationObserver',
        \\    'HTMLTableElement','HTMLTableRowElement','HTMLTableCellElement',
        \\    'HTMLUListElement','HTMLOListElement','HTMLLIElement','HTMLPreElement',
        \\    'HTMLCanvasElement','HTMLVideoElement','HTMLAudioElement',
        \\    'HTMLButtonElement','HTMLSelectElement','HTMLTextAreaElement',
        \\    'HTMLBRElement','HTMLHRElement','HTMLOptionElement',
        \\    'HTMLMetaElement','HTMLTitleElement','HTMLBaseElement',
        \\    'HTMLHeadingElement','HTMLQuoteElement','HTMLLabelElement'];
        \\  for(var i=0;i<names.length;i++){if(typeof iframeGlobal[names[i]]!=='undefined')cw[names[i]]=iframeGlobal[names[i]];}
        \\  return cw;
        \\})
    ;

    // We call this in the PARENT context but pass the iframe global
    // Cross-context JSValue passing works within same Runtime in QuickJS
    const cw_fn = qjs.JS_Eval(parent_ctx, cw_js, cw_js.len, "<iframe-cw>", qjs.JS_EVAL_TYPE_GLOBAL);
    var cw_args = [1]qjs.JSValue{iframe_global};
    const content_window = qjs.JS_Call(parent_ctx, cw_fn, quickjs.JS_UNDEFINED(), 1, &cw_args);
    qjs.JS_FreeValue(parent_ctx, cw_fn);
    qjs.JS_FreeValue(parent_ctx, iframe_global);

    _ = qjs.JS_SetPropertyStr(parent_ctx, js_elem, "contentWindow", content_window);
    _ = qjs.JS_SetPropertyStr(parent_ctx, content_window, "frameElement", qjs.JS_DupValue(parent_ctx, js_elem));

    // Update window.frames (window[idx] = contentWindow, window.length++)
    {
        const parent_global = qjs.JS_GetGlobalObject(parent_ctx);
        defer qjs.JS_FreeValue(parent_ctx, parent_global);
        const len_val = qjs.JS_GetPropertyStr(parent_ctx, parent_global, "length");
        var len: i32 = 0;
        _ = qjs.JS_ToInt32(parent_ctx, &len, len_val);
        qjs.JS_FreeValue(parent_ctx, len_val);
        _ = qjs.JS_SetPropertyUint32(parent_ctx, parent_global, @intCast(len), qjs.JS_DupValue(parent_ctx, content_window));
        _ = qjs.JS_SetPropertyStr(parent_ctx, parent_global, "length", qjs.JS_NewInt32(parent_ctx, len + 1));
    }

    // Fire load event on iframe element (in parent context)
    // Many WPT tests depend on iframe.onload
    {
        const load_js =
            \\(function(el){
            \\  var e = new Event('load');
            \\  if(el.onload) el.onload(e);
            \\  el.dispatchEvent(e);
            \\})
        ;
        const load_fn = qjs.JS_Eval(parent_ctx, load_js, load_js.len, "<iframe-load>", qjs.JS_EVAL_TYPE_GLOBAL);
        if (!quickjs.JS_IsException(load_fn)) {
            var load_args = [1]qjs.JSValue{qjs.JS_DupValue(parent_ctx, js_elem)};
            const load_result = qjs.JS_Call(parent_ctx, load_fn, quickjs.JS_UNDEFINED(), 1, &load_args);
            qjs.JS_FreeValue(parent_ctx, load_result);
            qjs.JS_FreeValue(parent_ctx, load_args[0]);
            qjs.JS_FreeValue(parent_ctx, load_fn);
        }
    }
}

// ── Content Fetching ────────────────────────────────────────────────

fn fetchIframeContent(src: []const u8, allocator: std.mem.Allocator) ?[]u8 {
    const loader = api.g_loader orelse return null;
    const base = api.g_top_frame.current_url orelse "";

    const resolved = resolveUrl(allocator, base, src) catch return null;
    defer allocator.free(resolved);

    var response = loader.loadBytes(resolved) catch return null;
    // Copy body before response.deinit frees it
    const body_copy = allocator.alloc(u8, response.body.len) catch {
        response.deinit();
        return null;
    };
    @memcpy(body_copy, response.body);
    response.deinit();
    return body_copy;
}

// ── Cleanup ─────────────────────────────────────────────────────────

/// Reset all iframe state. Call on page navigation.
pub fn resetIframes() void {
    var i: u32 = 0;
    while (i < iframe_count) : (i += 1) {
        // Free JSContext
        if (iframe_contexts[i]) |ctx| {
            qjs.JS_FreeContext(ctx);
            iframe_contexts[i] = null;
        }
        // Free Lexbor Document
        if (iframe_docs[i]) |*doc| {
            doc.deinit();
            iframe_docs[i] = null;
        }
        // Reset FrameState
        iframe_frames[i] = .{};
    }
    iframe_count = 0;
}

/// Set up a dynamically-created iframe (from JS appendChild/insertBefore).
/// Lightweight version of setupIframe: no layout, no font cache needed.
pub fn setupDynamicIframe(parent_ctx: *qjs.JSContext, elem: *lxb.lxb_dom_element_t) void {
    if (iframe_count >= frame_state.MAX_IFRAME_COUNT) return;

    const allocator = std.heap.c_allocator;
    const rt = qjs.JS_GetRuntime(parent_ctx) orelse return;

    // Get srcdoc/src for content
    var src_len: usize = 0;
    const src_ptr = lxb_dom_element_get_attribute(elem, "src", 3, &src_len);
    var srcdoc_len: usize = 0;
    const srcdoc_ptr = lxb_dom_element_get_attribute(elem, "srcdoc", 6, &srcdoc_len);

    var html_content: ?[]const u8 = null;
    var iframe_url: []const u8 = "about:blank";
    var fetched_html: ?[]u8 = null;
    defer if (fetched_html) |fh| allocator.free(fh);

    if (srcdoc_ptr != null and srcdoc_len > 0) {
        html_content = srcdoc_ptr.?[0..srcdoc_len];
        iframe_url = "about:srcdoc";
    } else if (src_ptr != null and src_len > 0) {
        const src = src_ptr.?[0..src_len];
        if (fetchIframeContent(src, allocator)) |content| {
            fetched_html = content;
            html_content = content;
            iframe_url = src;
        }
    }

    // Parse HTML into Lexbor Document
    const iframe_doc = if (html_content) |html|
        Document.parse(html) catch null
    else
        Document.parse("<!DOCTYPE html><html><head></head><body></body></html>") catch null;

    if (iframe_doc == null) return;

    const idx = iframe_count;
    iframe_docs[idx] = iframe_doc;
    iframe_count += 1;

    const doc_ptr: *anyopaque = @ptrCast(@alignCast(iframe_doc.?.html_doc));

    // Create new JSContext
    const iframe_ctx = qjs.JS_NewContext(rt) orelse return;
    iframe_contexts[idx] = iframe_ctx;

    // FrameState
    iframe_frames[idx] = .{
        .document = doc_ptr,
        .ctx = iframe_ctx,
        .current_url = iframe_url,
        .parent_frame = &api.g_top_frame,
        .depth = 1,
    };
    qjs.JS_SetContextOpaque(iframe_ctx, @ptrCast(&iframe_frames[idx]));

    // Save parent globals
    const saved_doc = api.g_document;
    const saved_url = api.g_top_frame.current_url;
    const saved_dirty = api.dom_dirty;
    const saved_web_ctx = web_api.getGlobalCtx();

    // Register APIs on iframe context
    api.registerDomApis(rt, iframe_ctx, doc_ptr);
    events.registerEventApis(iframe_ctx);
    const CtxWrapper = struct { ctx: *qjs.JSContext };
    var ctx_wrap = CtxWrapper{ .ctx = iframe_ctx };
    web_api.registerWebApis(&ctx_wrap);
    events.injectElementEventMethods(iframe_ctx, api.element_class_id);

    // Fix document element getters for iframe context
    {
        const ig = qjs.JS_GetGlobalObject(iframe_ctx);
        defer qjs.JS_FreeValue(iframe_ctx, ig);
        const id = qjs.JS_GetPropertyStr(iframe_ctx, ig, "document");
        defer qjs.JS_FreeValue(iframe_ctx, id);
        const de = qjs.JS_GetPropertyStr(iframe_ctx, id, "documentElement");
        const b = qjs.JS_GetPropertyStr(iframe_ctx, id, "body");
        const h = qjs.JS_GetPropertyStr(iframe_ctx, id, "head");
        const fix =
            \\(function(doc,de,b,h){
            \\  Object.defineProperty(doc,'documentElement',{get:function(){return de;},configurable:true});
            \\  Object.defineProperty(doc,'body',{get:function(){return b;},configurable:true});
            \\  Object.defineProperty(doc,'head',{get:function(){return h;},configurable:true});
            \\})
        ;
        const fix_fn = qjs.JS_Eval(iframe_ctx, fix, fix.len, "<dif>", qjs.JS_EVAL_TYPE_GLOBAL);
        if (!quickjs.JS_IsException(fix_fn)) {
            var fa = [4]qjs.JSValue{ id, de, b, h };
            const fr = qjs.JS_Call(iframe_ctx, fix_fn, quickjs.JS_UNDEFINED(), 4, &fa);
            qjs.JS_FreeValue(iframe_ctx, fr);
        }
        qjs.JS_FreeValue(iframe_ctx, fix_fn);
        qjs.JS_FreeValue(iframe_ctx, de);
        qjs.JS_FreeValue(iframe_ctx, b);
        qjs.JS_FreeValue(iframe_ctx, h);
    }

    // Restore parent globals
    api.g_document = saved_doc;
    api.g_top_frame.document = saved_doc;
    api.g_top_frame.current_url = saved_url;
    api.dom_dirty = saved_dirty;
    web_api.setGlobalCtx(saved_web_ctx);

    // Set contentDocument/contentWindow on parent element
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    const js_elem = api.wrapNode(parent_ctx, node);

    const iframe_global = qjs.JS_GetGlobalObject(iframe_ctx);
    const iframe_doc_obj = qjs.JS_GetPropertyStr(iframe_ctx, iframe_global, "document");

    _ = qjs.JS_SetPropertyStr(parent_ctx, js_elem, "contentDocument", iframe_doc_obj);

    // contentWindow bridge
    const cw_js =
        \\(function(ig){
        \\  var cw={document:ig.document,parent:window,top:window,
        \\    location:{href:ig.location?ig.location.href:'about:blank'},
        \\    navigator:window.navigator,closed:false,
        \\    addEventListener:function(t,f,o){ig.addEventListener(t,f,o);},
        \\    removeEventListener:function(t,f,o){ig.removeEventListener(t,f,o);},
        \\    dispatchEvent:function(e){return ig.dispatchEvent(e);},
        \\    getComputedStyle:ig.getComputedStyle,
        \\    setTimeout:ig.setTimeout,clearTimeout:ig.clearTimeout,
        \\    postMessage:function(){},focus:function(){},blur:function(){},
        \\    close:function(){this.closed=true;}};
        \\  cw.window=cw;cw.self=cw;return cw;
        \\})
    ;
    const cw_fn = qjs.JS_Eval(parent_ctx, cw_js, cw_js.len, "<dicw>", qjs.JS_EVAL_TYPE_GLOBAL);
    var cw_args = [1]qjs.JSValue{iframe_global};
    const cw = qjs.JS_Call(parent_ctx, cw_fn, quickjs.JS_UNDEFINED(), 1, &cw_args);
    qjs.JS_FreeValue(parent_ctx, cw_fn);
    qjs.JS_FreeValue(parent_ctx, iframe_global);

    _ = qjs.JS_SetPropertyStr(parent_ctx, js_elem, "contentWindow", cw);
    _ = qjs.JS_SetPropertyStr(parent_ctx, cw, "frameElement", qjs.JS_DupValue(parent_ctx, js_elem));

    // Update window.frames (window[idx] = contentWindow, window.length++)
    {
        const parent_global = qjs.JS_GetGlobalObject(parent_ctx);
        defer qjs.JS_FreeValue(parent_ctx, parent_global);
        const len_val = qjs.JS_GetPropertyStr(parent_ctx, parent_global, "length");
        var len: i32 = 0;
        _ = qjs.JS_ToInt32(parent_ctx, &len, len_val);
        qjs.JS_FreeValue(parent_ctx, len_val);
        _ = qjs.JS_SetPropertyUint32(parent_ctx, parent_global, @intCast(len), qjs.JS_DupValue(parent_ctx, cw));
        _ = qjs.JS_SetPropertyStr(parent_ctx, parent_global, "length", qjs.JS_NewInt32(parent_ctx, len + 1));
    }

    qjs.JS_FreeValue(parent_ctx, js_elem);
}

fn buildIframeLayout(maybe_doc: ?Document, elem: *lxb.lxb_dom_element_t, allocator: std.mem.Allocator, idx: u32, fonts: ?*FontCache) void {
    const doc = maybe_doc orelse return;
    const root_node = doc.root() orelse return;

    // Get iframe dimensions from attributes (default 300x150 per spec)
    var iw: f32 = 300;
    var ih: f32 = 150;
    var attr_len: usize = 0;
    if (lxb_dom_element_get_attribute(elem, "width", 5, &attr_len)) |w| {
        iw = std.fmt.parseFloat(f32, w[0..attr_len]) catch 300;
    }
    attr_len = 0;
    if (lxb_dom_element_get_attribute(elem, "height", 6, &attr_len)) |h| {
        ih = std.fmt.parseFloat(f32, h[0..attr_len]) catch 150;
    }

    const cascade_mod = @import("../css/cascade.zig");
    const box_tree = @import("../layout/tree.zig");
    const block_layout = @import("../layout/block.zig");

    var iframe_styles = cascade_mod.cascade(root_node, allocator, null, @intFromFloat(iw), @intFromFloat(ih)) catch return;

    const iframe_root_box = box_tree.buildBoxTree(root_node, &iframe_styles, allocator) catch {
        iframe_styles.deinit();
        return;
    };
    iframe_root_box.margin = .{};
    // Layout with font cache (if available)
    if (fonts) |f| {
        block_layout.layoutBlockVp(iframe_root_box, iw, 0, f, ih);
    }

    // Store in FrameState (styles field is StyleMap pointer, get from CascadeResult)
    iframe_frames[idx].root_box = iframe_root_box;
    iframe_frames[idx].styles = &iframe_styles.styles;
    iframe_frames[idx].viewport_width = iw;
    iframe_frames[idx].viewport_height = ih;
    // Note: iframe_styles ownership transferred — don't deinit here
}

/// Find the FrameState for an iframe element's DOM node.
pub fn findFrameForNode(node: *lxb.lxb_dom_node_t) ?*const FrameState {
    const target = @intFromPtr(node);
    var i: u32 = 0;
    while (i < iframe_count) : (i += 1) {
        // Compare the DOM node that was passed to setupIframe
        // We stored the FrameState's document, not the iframe element itself.
        // For now, match by index order (iframes are processed in DOM order)
        // TODO: Store iframe element pointer in FrameState for precise matching
        _ = target;
    }
    return null;
}

/// Get FrameState by index (for tree.zig to set iframe_frame on Box)
pub fn getFrameByIndex(idx: u32) ?*const FrameState {
    if (idx < iframe_count) return &iframe_frames[idx];
    return null;
}

/// Get current iframe count
pub fn getIframeCount() u32 {
    return iframe_count;
}

/// Tick timers and pending jobs for all active iframe contexts.
/// Called from main event loop.
pub fn tickAllIframeTimers() void {
    var i: u32 = 0;
    while (i < iframe_count) : (i += 1) {
        if (iframe_contexts[i]) |ctx| {
            _ = web_api.tickTimers(ctx);
            // Execute pending promises/microtasks for this context
            // Note: JS_ExecutePendingJob works at Runtime level, handles all contexts
        }
    }
}

/// Fire load events on all iframe elements after page scripts have executed.
/// This ensures onload handlers set by scripts are called.
pub fn fireIframeLoadEvents(parent_ctx: *qjs.JSContext) void {
    const js =
        \\(function(){
        \\  var iframes = document.querySelectorAll('iframe');
        \\  for(var i=0; i<iframes.length; i++){
        \\    var e = new Event('load');
        \\    var handler = iframes[i].onload || null;
        \\    if(!handler && iframes[i].getAttribute('onload')){
        \\      try { handler = new Function('event', iframes[i].getAttribute('onload')); } catch(ex){}
        \\    }
        \\    if(handler) try { handler.call(iframes[i], e); } catch(ex){}
        \\    try { iframes[i].dispatchEvent(e); } catch(ex){}
        \\  }
        \\})()
    ;
    const r = qjs.JS_Eval(parent_ctx, js, js.len, "<iframe-load-events>", qjs.JS_EVAL_TYPE_GLOBAL);
    qjs.JS_FreeValue(parent_ctx, r);
}

/// Check if a URL points to XML content (by extension)
fn isXmlUrl(url: []const u8) bool {
    // Strip query string and fragment
    var path = url;
    if (std.mem.indexOfScalar(u8, path, '?')) |q| path = path[0..q];
    if (std.mem.indexOfScalar(u8, path, '#')) |h| path = path[0..h];
    // Check extension
    if (std.mem.endsWith(u8, path, ".xml")) return true;
    if (std.mem.endsWith(u8, path, ".xhtml")) return true;
    if (std.mem.endsWith(u8, path, ".svg")) return true;
    if (std.mem.endsWith(u8, path, ".xsl")) return true;
    if (std.mem.endsWith(u8, path, ".xslt")) return true;
    if (std.mem.endsWith(u8, path, ".mathml")) return true;
    return false;
}

/// Check if two URLs have the same origin (protocol + host + port)
pub fn isSameOrigin(url1: []const u8, url2: []const u8) bool {
    // Extract origin from URLs
    const origin1 = extractOrigin(url1);
    const origin2 = extractOrigin(url2);
    return std.mem.eql(u8, origin1, origin2);
}

fn extractOrigin(url: []const u8) []const u8 {
    // Find "://" 
    if (std.mem.indexOf(u8, url, "://")) |proto_end| {
        const after_proto = url[proto_end + 3 ..];
        // Find end of host:port (next "/" or end of string)
        if (std.mem.indexOfScalar(u8, after_proto, '/')) |slash| {
            return url[0 .. proto_end + 3 + slash];
        }
        return url;
    }
    // Relative URL or about:blank — same origin as parent
    return "";
}
