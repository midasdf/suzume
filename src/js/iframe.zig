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

pub fn processIframes(
    parent_ctx: *qjs.JSContext,
    rt: *qjs.JSRuntime,
    doc_node: *lxb.lxb_dom_node_t,
    parent_frame: *FrameState,
    allocator: std.mem.Allocator,
) void {
    walkForIframes(parent_ctx, rt, doc_node, parent_frame, allocator, 0);
}

fn walkForIframes(
    parent_ctx: *qjs.JSContext,
    rt: *qjs.JSRuntime,
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
                setupIframe(parent_ctx, rt, elem, parent_frame, allocator, depth);
            }
            // Don't recurse INTO iframe content — only scan parent document
            if (name == null or name_len != 6 or !std.mem.eql(u8, name.?[0..6], "iframe")) {
                walkForIframes(parent_ctx, rt, ch, parent_frame, allocator, depth);
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

    if (srcdoc_ptr != null and srcdoc_len > 0) {
        html_content = srcdoc_ptr.?[0..srcdoc_len];
        iframe_url = "about:srcdoc";
    } else if (src_ptr != null and src_len > 0) {
        // Fetch src URL
        const src = src_ptr.?[0..src_len];
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

    // Restore parent globals (registerDomApis/registerWebApis overwrote them)
    api.g_document = saved_doc;
    api.g_top_frame.document = saved_doc;
    api.g_top_frame.current_url = saved_url;
    api.dom_dirty = saved_dirty;
    web_api.setGlobalCtx(saved_web_ctx);

    // TODO: Execute scripts in iframe document
    // For now, skip script execution (Phase 3 enhancement)

    // Set contentDocument on parent's iframe element
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    const js_elem = api.wrapNode(parent_ctx, node);
    defer qjs.JS_FreeValue(parent_ctx, js_elem);

    // Get the iframe context's document object
    const iframe_global = qjs.JS_GetGlobalObject(iframe_ctx);
    const iframe_doc_obj = qjs.JS_GetPropertyStr(iframe_ctx, iframe_global, "document");

    // Set contentDocument (cross-context: we set it as a property on the parent element)
    // Note: This is a simplified cross-context bridge — the document object
    // was created in iframe_ctx but we reference it from parent_ctx.
    // For same-origin iframes this works in QuickJS since they share the Runtime.
    _ = qjs.JS_SetPropertyStr(parent_ctx, js_elem, "contentDocument", iframe_doc_obj);

    // Create contentWindow proxy in parent context
    // This is a bridge object that delegates to the iframe's global
    const cw_js =
        \\(function(iframeGlobal){
        \\  return {
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
}

// ── Content Fetching ────────────────────────────────────────────────

fn fetchIframeContent(src: []const u8, allocator: std.mem.Allocator) ?[]u8 {
    const loader = api.g_loader orelse return null;
    const base = api.g_top_frame.current_url orelse "";

    const resolved = resolveUrl(allocator, src, base) catch return null;
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
