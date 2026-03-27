// iframe support — detection, loading, context creation
// Phase 2 of iframe implementation.

const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;
const lxb = @import("../bindings/lexbor.zig").c;
const api = @import("dom_api.zig");
const frame_state = @import("frame_state.zig");
const FrameState = frame_state.FrameState;
const events = @import("events.zig");

extern fn lxb_dom_element_get_attribute(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize, value_len: *usize) ?[*]const u8;
extern fn lxb_dom_element_local_name(element: *lxb.lxb_dom_element_t, len: *usize) ?[*]const u8;

// ── iframe Frame Storage ────────────────────────────────────────────

var iframe_frames: [frame_state.MAX_IFRAME_COUNT]FrameState = [_]FrameState{.{}} ** frame_state.MAX_IFRAME_COUNT;
var iframe_count: u32 = 0;

/// Allocate a new FrameState for an iframe. Returns null if limit reached.
pub fn allocFrame() ?*FrameState {
    if (iframe_count >= frame_state.MAX_IFRAME_COUNT) return null;
    const idx = iframe_count;
    iframe_count += 1;
    iframe_frames[idx] = .{};
    return &iframe_frames[idx];
}

// ── iframe Detection ────────────────────────────────────────────────

/// Walk DOM tree and set up contentDocument/contentWindow for each <iframe>.
/// Called after page scripts execute, from main.zig.
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
            // Check if this is an <iframe>
            const elem: *lxb.lxb_dom_element_t = @ptrCast(ch);
            var name_len: usize = 0;
            const name = lxb_dom_element_local_name(elem, &name_len);
            if (name != null and name_len == 6 and std.mem.eql(u8, name.?[0..6], "iframe")) {
                setupIframe(parent_ctx, rt, elem, parent_frame, allocator, depth);
            }
            // Recurse into children (but not into iframe content)
            walkForIframes(parent_ctx, rt, ch, parent_frame, allocator, depth);
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
    _ = rt;
    _ = allocator;

    // Get src attribute
    var src_len: usize = 0;
    const src_ptr = lxb_dom_element_get_attribute(elem, "src", 3, &src_len);

    // Get srcdoc attribute
    var srcdoc_len: usize = 0;
    const srcdoc_ptr = lxb_dom_element_get_attribute(elem, "srcdoc", 6, &srcdoc_len);

    // Determine what to load
    var content_url: ?[]const u8 = null;
    var inline_html: ?[]const u8 = null;

    if (srcdoc_ptr != null and srcdoc_len > 0) {
        inline_html = srcdoc_ptr.?[0..srcdoc_len];
    } else if (src_ptr != null and src_len > 0) {
        content_url = src_ptr.?[0..src_len];
    }
    // If neither src nor srcdoc, it's an about:blank iframe

    // For now, set contentDocument/contentWindow as stubs on the JS element
    // Full implementation (fetch + parse + new context) comes next
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    const js_elem = api.wrapNode(parent_ctx, node);

    // Create a minimal contentDocument (about:blank)
    const cd_js =
        \\(function(){
        \\  var d = new Document();
        \\  d.contentType = 'text/html';
        \\  d.URL = 'about:blank';
        \\  d.documentURI = 'about:blank';
        \\  return d;
        \\})()
    ;
    const content_doc = qjs.JS_Eval(parent_ctx, cd_js, cd_js.len, "<iframe-doc>", qjs.JS_EVAL_TYPE_GLOBAL);

    // Set contentDocument on iframe element
    _ = qjs.JS_SetPropertyStr(parent_ctx, js_elem, "contentDocument", qjs.JS_DupValue(parent_ctx, content_doc));

    // Create contentWindow
    const cw_js =
        \\(function(doc){
        \\  return {
        \\    document: doc,
        \\    parent: window,
        \\    top: window.top || window,
        \\    self: null,
        \\    location: { href: 'about:blank' },
        \\    navigator: window.navigator,
        \\    addEventListener: function(){},
        \\    removeEventListener: function(){},
        \\    dispatchEvent: function(){return true;},
        \\    getComputedStyle: window.getComputedStyle,
        \\    setTimeout: window.setTimeout,
        \\    setInterval: window.setInterval,
        \\    clearTimeout: window.clearTimeout,
        \\    clearInterval: window.clearInterval
        \\  };
        \\})
    ;
    const cw_fn = qjs.JS_Eval(parent_ctx, cw_js, cw_js.len, "<iframe-cw>", qjs.JS_EVAL_TYPE_GLOBAL);
    var cw_args = [1]qjs.JSValue{content_doc};
    const content_window = qjs.JS_Call(parent_ctx, cw_fn, quickjs.JS_UNDEFINED(), 1, &cw_args);
    qjs.JS_FreeValue(parent_ctx, cw_fn);

    // Set self-reference
    _ = qjs.JS_SetPropertyStr(parent_ctx, content_window, "self", qjs.JS_DupValue(parent_ctx, content_window));

    // Set contentWindow on iframe element
    _ = qjs.JS_SetPropertyStr(parent_ctx, js_elem, "contentWindow", content_window);

    // Set frameElement on contentWindow
    _ = qjs.JS_SetPropertyStr(parent_ctx, content_window, "frameElement", qjs.JS_DupValue(parent_ctx, js_elem));

    qjs.JS_FreeValue(parent_ctx, content_doc);
    qjs.JS_FreeValue(parent_ctx, js_elem);

    // TODO Phase 2 continued: use content_url/inline_html to fetch+parse real content
    // For now, about:blank stub is sufficient for basic contentDocument access
    _ = .{ content_url, inline_html, parent_frame, depth };
}
