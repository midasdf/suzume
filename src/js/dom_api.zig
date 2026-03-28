const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;
const lxb = @import("../bindings/lexbor.zig").c;
const events = @import("events.zig");
pub const serialize = @import("dom_serialize.zig");
pub const dom_text = @import("dom_text.zig");
pub const dom_sel = @import("dom_selector.zig");
pub const dom_node = @import("dom_node.zig");
pub const dom_elem = @import("dom_element.zig");
pub const dom_doc = @import("dom_document.zig");
pub const dom_style = @import("dom_style.zig");
pub const frame_state = @import("frame_state.zig");
pub const iframe = @import("iframe.zig");
pub const FrameState = frame_state.FrameState;

// ── External Lexbor functions (avoid cImport issues) ────────────────
extern fn lxb_dom_document_create_element(document: *anyopaque, local_name: [*]const u8, lname_len: usize, reserved: ?*anyopaque) ?*lxb.lxb_dom_element_t;
extern fn lxb_dom_document_create_text_node(document: *anyopaque, data: [*]const u8, len: usize) ?*lxb.lxb_dom_node_t;
extern fn lxb_dom_node_insert_child(to: *lxb.lxb_dom_node_t, node: *lxb.lxb_dom_node_t) void;
extern fn lxb_dom_node_insert_before(to: *lxb.lxb_dom_node_t, node: *lxb.lxb_dom_node_t) void;
extern fn lxb_dom_node_remove(node: *lxb.lxb_dom_node_t) void;
extern fn lxb_dom_node_destroy(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t;
extern fn lxb_dom_node_text_content(node: *lxb.lxb_dom_node_t, len: *usize) ?[*]const u8;
extern fn lxb_dom_node_text_content_set(node: *lxb.lxb_dom_node_t, content: [*]const u8, len: usize) lxb.lxb_status_t;
extern fn lxb_dom_element_set_attribute(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize, value: [*]const u8, value_len: usize) ?*anyopaque;
extern fn lxb_dom_element_get_attribute(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize, value_len: *usize) ?[*]const u8;
extern fn lxb_dom_element_remove_attribute(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize) lxb.lxb_status_t;
pub extern fn lxb_dom_element_local_name(element: *lxb.lxb_dom_element_t, len: *usize) ?[*]const u8;
extern fn lxb_dom_node_last_child_noi(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t;
extern fn lxb_dom_node_prev_noi(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t;
extern fn lxb_dom_element_has_attribute(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize) bool;
extern fn lxb_dom_node_insert_after(to: *lxb.lxb_dom_node_t, node: *lxb.lxb_dom_node_t) void;
extern fn lxb_dom_document_create_comment(document: *anyopaque, data: [*]const u8, len: usize) ?*lxb.lxb_dom_node_t;

// Lexbor attribute iteration (using _noi ABI-safe non-inline variants)
extern fn lxb_dom_element_first_attribute_noi(element: *lxb.lxb_dom_element_t) ?*anyopaque;
extern fn lxb_dom_element_next_attribute_noi(attr: *anyopaque) ?*anyopaque;
extern fn lxb_dom_attr_qualified_name(attr: *anyopaque, len: *usize) ?[*]const u8;
extern fn lxb_dom_attr_value_noi(attr: *anyopaque, len: *usize) ?[*]const u8;

// Lexbor HTML serialization (for innerHTML/outerHTML)
const lxb_html_serialize_cb_f = ?*const fn (data: ?[*]const u8, len: usize, ctx: ?*anyopaque) callconv(.c) lxb.lxb_status_t;
extern fn lxb_html_serialize_tree_cb(node: *lxb.lxb_dom_node_t, cb: lxb_html_serialize_cb_f, ctx: ?*anyopaque) lxb.lxb_status_t;
extern fn lxb_html_serialize_cb(node: *lxb.lxb_dom_node_t, cb: lxb_html_serialize_cb_f, ctx: ?*anyopaque) lxb.lxb_status_t;
extern fn lxb_html_serialize_deep_cb(node: *lxb.lxb_dom_node_t, cb: lxb_html_serialize_cb_f, ctx: ?*anyopaque) lxb.lxb_status_t;

// Lexbor HTML fragment parsing (for innerHTML setter)
extern fn lxb_html_document_parse_fragment(document: *anyopaque, element: *lxb.lxb_dom_element_t, html: [*]const u8, size: usize) ?*lxb.lxb_dom_node_t;

// ── Class IDs (set during init) ─────────────────────────────────────
pub var element_class_id: qjs.JSClassID = 0;
pub var text_class_id: qjs.JSClassID = 0;

// ── Global state ────────────────────────────────────────────────────
/// The lxb_dom_document_t pointer (cast to *anyopaque because of cImport limitations).
/// Set once during registerDomApis.
pub var g_document: ?*anyopaque = null;

/// DOM dirty flag — set when JS mutates the DOM tree. Checked by the main loop.
pub var dom_dirty: bool = false;
pub var mutation_observers_pending: bool = false;

/// Currently focused element (set from main.zig when input is focused/blurred).
pub var active_element: ?*lxb.lxb_dom_node_t = null;

/// Currently hovered element (set from main.zig on mouse move).
pub var hovered_element: ?*lxb.lxb_dom_node_t = null;

/// Scroll position, synced from main.zig.
pub var scroll_x: f32 = 0;
pub var scroll_y: f32 = 0;
/// Scroll request from JS (scrollTo/scrollBy). null = no pending request.
pub var pending_scroll_x: ?f32 = null;
pub var pending_scroll_y: ?f32 = null;

/// Top-level frame state (fallback during migration to per-frame architecture)
pub var g_top_frame: FrameState = .{};

// ── Per-frame accessor helpers ──────────────────────────────────────
// These check the JSContext's opaque FrameState first, then fall back to globals.
// During iframe support, each Context will have its own FrameState.

pub fn getDocument(ctx: *qjs.JSContext) ?*anyopaque {
    if (frame_state.getFrameStateFromCtx(ctx)) |fs| {
        if (fs.document) |doc| return doc;
    }
    return g_document;
}

pub fn getRootBox(ctx: *qjs.JSContext) ?*const Box {
    if (frame_state.getFrameStateFromCtx(ctx)) |fs| {
        if (fs.root_box) |rb| return rb;
    }
    return g_root_box;
}

pub fn getStylesForCtx(ctx: *qjs.JSContext) ?*const cascade_mod.StyleMap {
    if (frame_state.getFrameStateFromCtx(ctx)) |fs| {
        if (fs.styles) |s| return s;
    }
    return g_styles;
}

pub fn getViewportForCtx(ctx: *qjs.JSContext) struct { w: f32, h: f32 } {
    if (frame_state.getFrameStateFromCtx(ctx)) |fs| {
        if (fs.viewport_width != 0 or fs.viewport_height != 0)
            return .{ .w = fs.viewport_width, .h = fs.viewport_height };
    }
    return .{ .w = g_viewport_width, .h = g_viewport_height };
}

pub fn setDomDirty() void {
    dom_dirty = true;
    mutation_observers_pending = true;
}

/// Check if an element is connected to the document (has an ancestor chain reaching the document node).
fn isElementConnected(elem: *lxb.lxb_dom_element_t) bool {
    var current: ?*lxb.lxb_dom_node_t = @as(*lxb.lxb_dom_node_t, @ptrCast(elem)).parent;
    while (current) |n| {
        if (n.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT) return true;
        current = n.parent;
    }
    return false;
}

/// Set DOM dirty flag only if the element is connected to the document tree.
/// Disconnected elements (e.g. from createElement) don't need restyle.
pub fn setDomDirtyIfConnected(elem: *lxb.lxb_dom_element_t) void {
    if (isElementConnected(elem)) setDomDirty();
}

/// Global root box pointer — set from main after layout, used for offset/rect queries.
const Box = @import("../layout/box.zig").Box;
const DomNode = @import("../dom/node.zig").DomNode;
const cascade_mod = @import("../css/cascade.zig");
const computed_mod = @import("../css/computed.zig");
const ComputedStyle = computed_mod.ComputedStyle;
const css_ast = @import("../css/ast.zig");
const css_properties = @import("../css/properties.zig");
pub var g_root_box: ?*const Box = null;

/// Set the root box pointer (called from main after layout).
pub fn setRootBox(root: ?*const Box) void {
    g_root_box = root;
    g_top_frame.root_box = root;
}

/// Global styles pointer — set from main after cascade, used for getComputedStyle.
pub var g_styles: ?*const cascade_mod.StyleMap = null;

/// Set the styles pointer (called from main after cascade/restyle).
pub fn setStyles(styles: ?*const cascade_mod.StyleMap) void {
    g_styles = styles;
    g_top_frame.styles = styles;
}

/// Viewport dimensions for getComputedStyle resolution.
pub var g_viewport_width: f32 = 800;
pub var g_viewport_height: f32 = 600;

/// Set viewport dimensions (called from main after layout).
/// For CSS viewport units (vw/vh), use the actual window viewport size,
/// not the layout surface size. Falls back to web_api.viewport if available.
pub fn setViewport(w: f32, h: f32) void {
    const web_api = @import("web_api.zig");
    // Use web_api viewport (window.innerWidth/Height) if set, otherwise use provided
    const vw: f32 = @floatFromInt(web_api.getViewportWidth());
    const vh: f32 = @floatFromInt(web_api.getViewportHeight());
    g_viewport_width = if (vw > 0) vw else w;
    g_viewport_height = if (vh > 0) vh else h;
    g_top_frame.viewport_width = g_viewport_width;
    g_top_frame.viewport_height = g_viewport_height;
}

/// Find the Box in the tree that corresponds to a given DOM node pointer.
pub fn findBoxForNode(root: *const Box, target: *lxb.lxb_dom_node_t) ?*const Box {
    if (root.dom_node) |dn| {
        if (dn.lxb_node == target) return root;
    }
    for (root.children.items) |child| {
        if (findBoxForNode(child, target)) |found| return found;
    }
    return null;
}

/// Ready state for document.readyState
pub var g_ready_state: enum { loading, interactive, complete } = .loading;

pub fn setReadyState(state: @TypeOf(g_ready_state)) void {
    g_ready_state = state;
}

/// Current page URL — set from main when navigating.
pub var g_current_url: ?[]const u8 = null;

/// Set the current page URL (called from main on navigation).
pub fn setCurrentUrl(url: ?[]const u8) void {
    g_current_url = url;
    g_top_frame.current_url = url;
}

// ── Dynamic script execution support ────────────────────────────────
const JsRuntime = @import("runtime.zig").JsRuntime;
const Loader = @import("../net/loader.zig").Loader;
const resolveUrl = @import("../net/loader.zig").resolveUrl;
const adblock_mod = @import("../features/adblock.zig");

var g_js_rt: ?*JsRuntime = null;
pub var g_loader: ?*Loader = null;
/// Track loaded script URLs to prevent duplicate execution
var g_loaded_script_urls: ?*std.StringHashMap(void) = null;

pub fn setJsRuntime(rt: ?*JsRuntime) void {
    g_js_rt = rt;
}

pub fn setLoader(loader: ?*Loader) void {
    g_loader = loader;
}

pub fn setLoadedScriptUrls(urls: ?*std.StringHashMap(void)) void {
    g_loaded_script_urls = urls;
}

/// Check if a node is a <script> element and execute it dynamically.
/// Called from elementAppendChild/elementInsertBefore when a script is inserted into the DOM.
pub fn maybeExecuteDynamicScriptPublic(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t, js_val: qjs.JSValue) void {
    maybeExecuteDynamicScript(ctx, node, js_val);
}

fn maybeExecuteDynamicScript(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t, js_val: qjs.JSValue) void {
    if (node.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return;

    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    var name_len: usize = 0;
    const name_ptr: ?[*]const u8 = lxb_dom_element_local_name(elem, &name_len);
    if (name_ptr == null or name_len != 6) return;
    if (!std.mem.eql(u8, name_ptr.?[0..6], "script")) return;

    // Check script type — only execute JS types
    var type_len: usize = 0;
    const type_ptr: ?[*]const u8 = lxb_dom_element_get_attribute(elem, "type", 4, &type_len);
    var is_module = false;
    if (type_ptr != null and type_len > 0) {
        const script_type = type_ptr.?[0..type_len];
        if (std.mem.eql(u8, script_type, "module")) {
            is_module = true;
        } else {
            const is_js = script_type.len == 0 or
                std.mem.eql(u8, script_type, "text/javascript") or
                std.mem.eql(u8, script_type, "application/javascript");
            if (!is_js) return;
        }
    }

    // Check for src attribute (external script)
    var src_len: usize = 0;
    const src_ptr: ?[*]const u8 = lxb_dom_element_get_attribute(elem, "src", 3, &src_len);
    if (src_ptr != null and src_len > 0) {
        executeDynamicExternalScript(ctx, src_ptr.?[0..src_len], is_module, js_val);
    } else {
        // Inline script: get textContent
        var content_len: usize = 0;
        const content_ptr: ?[*]const u8 = lxb_dom_node_text_content(node, &content_len);
        if (content_ptr != null and content_len > 0 and content_len <= 512 * 1024) {
            executeDynamicInlineScript(ctx, content_ptr.?[0..content_len], is_module, js_val);
        }
    }
}

fn executeDynamicExternalScript(ctx: *qjs.JSContext, src: []const u8, is_module: bool, js_val: qjs.JSValue) void {
    const js_rt = g_js_rt orelse return;
    const ld = g_loader orelse return;
    const allocator = std.heap.c_allocator;

    // Resolve URL
    const resolved_url = if (std.mem.startsWith(u8, src, "http://") or std.mem.startsWith(u8, src, "https://") or std.mem.startsWith(u8, src, "data:"))
        blk: {
            const u = allocator.allocSentinel(u8, src.len, 0) catch return;
            @memcpy(u, src);
            break :blk u;
        }
    else if (g_current_url) |bu|
        resolveUrl(allocator, bu, src) catch return
    else
        return;
    defer allocator.free(resolved_url);

    // Check duplicate
    if (g_loaded_script_urls) |urls| {
        if (urls.contains(resolved_url)) {
            std.debug.print("[JS:DYN] Skipping duplicate script: {s}\n", .{resolved_url});
            return;
        }
        // Track this URL
        const key = allocator.alloc(u8, resolved_url.len) catch return;
        @memcpy(key, resolved_url);
        urls.put(key, {}) catch {
            allocator.free(key);
        };
    }

    // Handle data: URIs
    if (std.mem.startsWith(u8, resolved_url, "data:")) {
        // data: URI scripts — parse and eval inline
        return;
    }

    if (!std.mem.startsWith(u8, resolved_url, "http://") and !std.mem.startsWith(u8, resolved_url, "https://")) return;

    // Skip tracking scripts
    if (ld.adblock_enabled and adblock_mod.isTrackingScript(resolved_url)) {
        std.debug.print("[JS:DYN] Skipping tracking script: {s}\n", .{resolved_url});
        return;
    }

    std.debug.print("[JS:DYN] Fetching dynamic script: {s}\n", .{resolved_url});

    var response = ld.loadBytesWithTimeout(resolved_url, 5) catch |err| {
        std.debug.print("[JS:DYN] Failed to fetch {s}: {}\n", .{ resolved_url, err });
        fireDynamicScriptEvent(ctx, js_val, "error");
        return;
    };

    if (response.status_code != 200) {
        std.debug.print("[JS:DYN] Script returned status {d}: {s}\n", .{ response.status_code, resolved_url });
        response.deinit();
        fireDynamicScriptEvent(ctx, js_val, "error");
        return;
    }

    if (response.body.len > 1024 * 1024) {
        std.debug.print("[JS:DYN] Script too large ({d} bytes): {s}\n", .{ response.body.len, resolved_url });
        response.deinit();
        fireDynamicScriptEvent(ctx, js_val, "error");
        return;
    }

    const code = response.body;
    std.debug.print("[JS:DYN] Executing dynamic script: {s} ({d} bytes, module={any})\n", .{ resolved_url, code.len, is_module });

    // Set document.currentScript
    setDynamicCurrentScript(ctx, resolved_url);

    const result = if (is_module)
        js_rt.evalModule(code, resolved_url)
    else
        js_rt.evalNamed(code, resolved_url);
    defer result.deinit();

    // Clear document.currentScript
    clearDynamicCurrentScript(ctx);

    if (!result.isOk()) {
        std.debug.print("[JS:DYN:ERROR] {s}\n", .{result.value()});
        response.deinit();
        fireDynamicScriptEvent(ctx, js_val, "error");
        return;
    }

    js_rt.executePending();
    response.deinit();

    // Fire onload
    fireDynamicScriptEvent(ctx, js_val, "load");
}

fn executeDynamicInlineScript(ctx: *qjs.JSContext, code: []const u8, is_module: bool, js_val: qjs.JSValue) void {
    const js_rt = g_js_rt orelse return;

    std.debug.print("[JS:DYN] Executing dynamic inline script ({d} bytes, module={any})\n", .{ code.len, is_module });

    const result = if (is_module)
        js_rt.evalModule(code, "<dynamic-inline>")
    else
        js_rt.eval(code);
    defer result.deinit();

    if (!result.isOk()) {
        std.debug.print("[JS:DYN:ERROR] {s}\n", .{result.value()});
        fireDynamicScriptEvent(ctx, js_val, "error");
        return;
    }

    js_rt.executePending();
    fireDynamicScriptEvent(ctx, js_val, "load");
}

/// Fire 'load' or 'error' event on a script element's JS object.
fn fireDynamicScriptEvent(ctx: *qjs.JSContext, js_val: qjs.JSValue, event_name: [*:0]const u8) void {
    // Try onload/onerror property callback
    const callback_name = if (std.mem.eql(u8, std.mem.span(event_name), "load")) "onload" else "onerror";
    const cb = qjs.JS_GetPropertyStr(ctx, js_val, callback_name);
    if (!quickjs.JS_IsUndefined(cb) and !quickjs.JS_IsNull(cb)) {
        const ret = qjs.JS_Call(ctx, cb, js_val, 0, null);
        if (quickjs.JS_IsException(ret)) {
            const exc = qjs.JS_GetException(ctx);
            defer qjs.JS_FreeValue(ctx, exc);
            const exc_str = qjs.JS_ToCString(ctx, exc);
            if (exc_str) |s| {
                std.debug.print("[JS:DYN] {s} callback error: {s}\n", .{ callback_name, std.mem.span(s) });
                qjs.JS_FreeCString(ctx, s);
            }
        } else {
            qjs.JS_FreeValue(ctx, ret);
        }
    }
    qjs.JS_FreeValue(ctx, cb);
}

/// Set document.currentScript for dynamic scripts
fn setDynamicCurrentScript(ctx: *qjs.JSContext, src_url: [:0]const u8) void {
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);
    const doc_obj = qjs.JS_GetPropertyStr(ctx, global, "document");
    defer qjs.JS_FreeValue(ctx, doc_obj);
    if (quickjs.JS_IsUndefined(doc_obj) or quickjs.JS_IsNull(doc_obj)) return;

    const script_obj = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPropertyStr(ctx, script_obj, "src", qjs.JS_NewStringLen(ctx, src_url.ptr, src_url.len));
    _ = qjs.JS_SetPropertyStr(ctx, script_obj, "type", qjs.JS_NewString(ctx, "text/javascript"));
    _ = qjs.JS_SetPropertyStr(ctx, script_obj, "tagName", qjs.JS_NewString(ctx, "SCRIPT"));
    _ = qjs.JS_SetPropertyStr(ctx, script_obj, "nodeName", qjs.JS_NewString(ctx, "SCRIPT"));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "currentScript", script_obj);
}

fn clearDynamicCurrentScript(ctx: *qjs.JSContext) void {
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);
    const doc_obj = qjs.JS_GetPropertyStr(ctx, global, "document");
    defer qjs.JS_FreeValue(ctx, doc_obj);
    if (quickjs.JS_IsUndefined(doc_obj) or quickjs.JS_IsNull(doc_obj)) return;
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "currentScript", quickjs.JS_NULL());
}

// ── Serialization (moved to dom_serialize.zig) ─────────────────────
const SerializeAccum = serialize.SerializeAccum;

const serializeCallback = serialize.serializeCallback;

// ── Helpers ─────────────────────────────────────────────────────────

/// Wrap a lxb_dom_node_t pointer into a JS Element object.
// ── Node identity cache ─────────────────────────────────────────────
// Maps DOM node pointer → JSValue to ensure the same DOM node always
// returns the same JS wrapper object (identity preservation for ===).
const NodeCache = std.AutoHashMap(usize, qjs.JSValue);
var node_cache: ?NodeCache = null;

fn initNodeCache() void {
    if (node_cache == null) {
        node_cache = NodeCache.init(std.heap.c_allocator);
    }
}

/// Clear the node identity cache (called on page navigation).
pub fn clearNodeCache(ctx: *qjs.JSContext) void {
    if (node_cache) |*cache| {
        var iter = cache.iterator();
        while (iter.next()) |entry| {
            qjs.JS_FreeValue(ctx, entry.value_ptr.*);
        }
        cache.clearRetainingCapacity();
    }
}

pub fn wrapNode(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) qjs.JSValue {
    initNodeCache();
    const key = @intFromPtr(node);

    // Return cached wrapper if it exists
    if (node_cache.?.get(key)) |cached| {
        return qjs.JS_DupValue(ctx, cached);
    }

    // Create new wrapper — CharacterData subtypes (Text, Comment, PI) use text class
    const node_type = node.type;
    const obj = if (node_type == lxb.LXB_DOM_NODE_TYPE_TEXT or
        node_type == lxb.LXB_DOM_NODE_TYPE_COMMENT or
        node_type == lxb.LXB_DOM_NODE_TYPE_PROCESSING_INSTRUCTION)
        wrapTextNew(ctx, node)
    else
        wrapElementNew(ctx, node);

    if (!quickjs.JS_IsException(obj)) {
        // Cache with a dup'd reference
        node_cache.?.put(key, qjs.JS_DupValue(ctx, obj)) catch {};
    }
    return obj;
}

fn wrapElementNew(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) qjs.JSValue {
    const obj = qjs.JS_NewObjectClass(ctx, @intCast(element_class_id));
    if (quickjs.JS_IsException(obj)) return obj;
    _ = qjs.JS_SetOpaque(obj, @ptrCast(node));
    return obj;
}

fn wrapTextNew(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) qjs.JSValue {
    const obj = qjs.JS_NewObjectClass(ctx, @intCast(text_class_id));
    if (quickjs.JS_IsException(obj)) return obj;
    _ = qjs.JS_SetOpaque(obj, @ptrCast(node));
    return obj;
}

/// Get the lxb_dom_node_t* from a JS Element/Text value.
/// Tries both element and text class IDs.
pub fn getNode(ctx: *qjs.JSContext, val: qjs.JSValue) ?*lxb.lxb_dom_node_t {
    // Try element class first
    const ptr1 = qjs.JS_GetOpaque2(ctx, val, element_class_id);
    if (ptr1) |p| return @ptrCast(@alignCast(p));
    // Try text class
    const ptr2 = qjs.JS_GetOpaque2(ctx, val, text_class_id);
    if (ptr2) |p| return @ptrCast(@alignCast(p));
    return null;
}

pub fn wrapNodePublic(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) qjs.JSValue {
    return wrapNode(ctx, node);
}

pub fn getNodePublic(ctx: *qjs.JSContext, val: qjs.JSValue) ?*lxb.lxb_dom_node_t {
    return getNode(ctx, val);
}

pub fn getElement(ctx: *qjs.JSContext, val: qjs.JSValue) ?*lxb.lxb_dom_element_t {
    const node = getNode(ctx, val) orelse return null;
    if (node.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return null;
    return @ptrCast(node);
}

pub fn jsStringToSlice(ctx: *qjs.JSContext, val: qjs.JSValue) ?struct { ptr: [*]const u8, len: usize } {
    var len: usize = 0;
    const cstr = qjs.JS_ToCStringLen(ctx, &len, val);
    if (cstr == null) return null;
    return .{ .ptr = cstr, .len = len };
}

/// Throw a DOMException with the given name and message.
/// DOM Standard §4.3: Uses the global DOMException constructor so
/// assert_throws_dom's `e.constructor === DOMException` check passes.
pub fn throwDOMException(c: *qjs.JSContext, name: []const u8, message: []const u8) qjs.JSValue {
    // Use the global DOMException constructor: new DOMException(message, name)
    const global = qjs.JS_GetGlobalObject(c);
    defer qjs.JS_FreeValue(c, global);
    const ctor = qjs.JS_GetPropertyStr(c, global, "DOMException");
    defer qjs.JS_FreeValue(c, ctor);

    if (!quickjs.JS_IsUndefined(ctor)) {
        var args_arr = [2]qjs.JSValue{
            qjs.JS_NewStringLen(c, message.ptr, message.len),
            qjs.JS_NewStringLen(c, name.ptr, name.len),
        };
        const exc = qjs.JS_CallConstructor(c, ctor, 2, &args_arr);
        qjs.JS_FreeValue(c, args_arr[0]);
        qjs.JS_FreeValue(c, args_arr[1]);
        if (!quickjs.JS_IsException(exc)) {
            return qjs.JS_Throw(c, exc);
        }
    }

    // Fallback: plain object (if DOMException not registered)
    const err = qjs.JS_NewObject(c);
    _ = qjs.JS_SetPropertyStr(c, err, "name", qjs.JS_NewStringLen(c, name.ptr, name.len));
    _ = qjs.JS_SetPropertyStr(c, err, "message", qjs.JS_NewStringLen(c, message.ptr, message.len));
    const code: i32 = if (std.mem.eql(u8, name, "SyntaxError")) 12
        else if (std.mem.eql(u8, name, "InvalidCharacterError")) 5
        else if (std.mem.eql(u8, name, "NotFoundError")) 8
        else if (std.mem.eql(u8, name, "HierarchyRequestError")) 3
        else 0;
    _ = qjs.JS_SetPropertyStr(c, err, "code", qjs.JS_NewInt32(c, code));
    return qjs.JS_Throw(c, err);
}


pub fn classContains(class_str: []const u8, needle: []const u8) bool {
    var iter = std.mem.tokenizeAny(u8, class_str, " \t\n\r\x0c");
    while (iter.next()) |cls| {
        if (std.mem.eql(u8, cls, needle)) return true;
    }
    return false;
}


// ── Shorthand ↔ Longhand Expansion ──────────────────────────────────

/// Get the 4 longhand property names for a box shorthand (margin/padding).
fn getBoxLonghands(shorthand: []const u8) ?[4][]const u8 {
    if (std.ascii.eqlIgnoreCase(shorthand, "margin")) {
        return .{ "margin-top", "margin-right", "margin-bottom", "margin-left" };
    }
    if (std.ascii.eqlIgnoreCase(shorthand, "padding")) {
        return .{ "padding-top", "padding-right", "padding-bottom", "padding-left" };
    }
    return null;
}

/// Split a box shorthand value into 1-4 parts, respecting parentheses for calc().
fn splitBoxShorthandParts(val: []const u8, out: *[4][]const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < val.len and count < 4) {
        while (pos < val.len and (val[pos] == ' ' or val[pos] == '\t')) pos += 1;
        if (pos >= val.len) break;
        const start = pos;
        var paren_depth: i32 = 0;
        while (pos < val.len) {
            if (val[pos] == '(') {
                paren_depth += 1;
            } else if (val[pos] == ')') {
                paren_depth -= 1;
            } else if ((val[pos] == ' ' or val[pos] == '\t') and paren_depth == 0) {
                break;
            }
            pos += 1;
        }
        out[count] = val[start..pos];
        count += 1;
    }
    return count;
}

/// Expand a box shorthand in a style string: remove shorthand + existing longhands,
/// then append the 4 expanded longhand values.
fn expandBoxShorthandInStyle(style_str: []const u8, shorthand: []const u8, longhands: [4][]const u8, vals: [4][]const u8, buf: []u8) ?[]const u8 {
    var out_pos: usize = 0;

    // Copy existing properties, skipping shorthand and its longhands
    var iter_pos: usize = 0;
    while (iter_pos < style_str.len) {
        while (iter_pos < style_str.len and (style_str[iter_pos] == ' ' or style_str[iter_pos] == '\t' or style_str[iter_pos] == '\n')) iter_pos += 1;
        if (iter_pos >= style_str.len) break;
        const prop_start = iter_pos;
        while (iter_pos < style_str.len and style_str[iter_pos] != ':' and style_str[iter_pos] != ';') iter_pos += 1;
        if (iter_pos >= style_str.len or style_str[iter_pos] != ':') break;
        const prop_name = std.mem.trim(u8, style_str[prop_start..iter_pos], " \t\n");
        iter_pos += 1; // skip ':'
        const val_start = iter_pos;
        while (iter_pos < style_str.len and style_str[iter_pos] != ';') iter_pos += 1;
        const val = std.mem.trim(u8, style_str[val_start..iter_pos], " \t\n");
        if (iter_pos < style_str.len) iter_pos += 1; // skip ';'

        // Skip if it's the shorthand or one of its longhands
        if (std.ascii.eqlIgnoreCase(prop_name, shorthand)) continue;
        var skip = false;
        for (longhands) |lh| {
            if (std.ascii.eqlIgnoreCase(prop_name, lh)) {
                skip = true;
                break;
            }
        }
        if (skip) continue;

        // Copy property
        const needed = prop_name.len + 2 + val.len + 2;
        if (out_pos + needed > buf.len) return null;
        @memcpy(buf[out_pos..][0..prop_name.len], prop_name);
        out_pos += prop_name.len;
        buf[out_pos] = ':';
        out_pos += 1;
        buf[out_pos] = ' ';
        out_pos += 1;
        @memcpy(buf[out_pos..][0..val.len], val);
        out_pos += val.len;
        buf[out_pos] = ';';
        out_pos += 1;
        buf[out_pos] = ' ';
        out_pos += 1;
    }

    // Append the 4 longhands
    for (longhands, 0..) |lh, i| {
        const v = vals[i];
        const needed = lh.len + 2 + v.len + 2;
        if (out_pos + needed > buf.len) return null;
        @memcpy(buf[out_pos..][0..lh.len], lh);
        out_pos += lh.len;
        buf[out_pos] = ':';
        out_pos += 1;
        buf[out_pos] = ' ';
        out_pos += 1;
        @memcpy(buf[out_pos..][0..v.len], v);
        out_pos += v.len;
        buf[out_pos] = ';';
        out_pos += 1;
        buf[out_pos] = ' ';
        out_pos += 1;
    }

    if (out_pos > 0 and buf[out_pos - 1] == ' ') out_pos -= 1;
    return buf[0..out_pos];
}

/// Remove a box shorthand and all its longhands from a style string.
fn removeBoxShorthandFromStyle(style_str: []const u8, shorthand: []const u8, longhands: [4][]const u8, buf: []u8) ?[]const u8 {
    var out_pos: usize = 0;
    var iter_pos: usize = 0;
    while (iter_pos < style_str.len) {
        while (iter_pos < style_str.len and (style_str[iter_pos] == ' ' or style_str[iter_pos] == '\t' or style_str[iter_pos] == '\n')) iter_pos += 1;
        if (iter_pos >= style_str.len) break;
        const prop_start = iter_pos;
        while (iter_pos < style_str.len and style_str[iter_pos] != ':' and style_str[iter_pos] != ';') iter_pos += 1;
        if (iter_pos >= style_str.len or style_str[iter_pos] != ':') break;
        const prop_name = std.mem.trim(u8, style_str[prop_start..iter_pos], " \t\n");
        iter_pos += 1;
        const val_start = iter_pos;
        while (iter_pos < style_str.len and style_str[iter_pos] != ';') iter_pos += 1;
        const val = std.mem.trim(u8, style_str[val_start..iter_pos], " \t\n");
        if (iter_pos < style_str.len) iter_pos += 1;

        if (std.ascii.eqlIgnoreCase(prop_name, shorthand)) continue;
        var skip = false;
        for (longhands) |lh| {
            if (std.ascii.eqlIgnoreCase(prop_name, lh)) {
                skip = true;
                break;
            }
        }
        if (skip) continue;

        const needed = prop_name.len + 2 + val.len + 2;
        if (out_pos + needed > buf.len) return null;
        @memcpy(buf[out_pos..][0..prop_name.len], prop_name);
        out_pos += prop_name.len;
        buf[out_pos] = ':';
        out_pos += 1;
        buf[out_pos] = ' ';
        out_pos += 1;
        @memcpy(buf[out_pos..][0..val.len], val);
        out_pos += val.len;
        buf[out_pos] = ';';
        out_pos += 1;
        buf[out_pos] = ' ';
        out_pos += 1;
    }
    if (out_pos > 0 and buf[out_pos - 1] == ' ') out_pos -= 1;
    return buf[0..out_pos];
}

const ShorthandInfo = struct {
    shorthand: []const u8,
    index: usize,
};

/// Given a longhand name, find its parent shorthand and position index (0=top,1=right,2=bottom,3=left).
fn getShorthandInfoForLonghand(longhand: []const u8) ?ShorthandInfo {
    const mapping = [_]struct { lh: []const u8, sh: []const u8, idx: usize }{
        .{ .lh = "margin-top", .sh = "margin", .idx = 0 },
        .{ .lh = "margin-right", .sh = "margin", .idx = 1 },
        .{ .lh = "margin-bottom", .sh = "margin", .idx = 2 },
        .{ .lh = "margin-left", .sh = "margin", .idx = 3 },
        .{ .lh = "padding-top", .sh = "padding", .idx = 0 },
        .{ .lh = "padding-right", .sh = "padding", .idx = 1 },
        .{ .lh = "padding-bottom", .sh = "padding", .idx = 2 },
        .{ .lh = "padding-left", .sh = "padding", .idx = 3 },
    };
    for (mapping) |m| {
        if (std.ascii.eqlIgnoreCase(longhand, m.lh)) {
            return .{ .shorthand = m.sh, .index = m.idx };
        }
    }
    return null;
}

/// Reconstruct a box shorthand value from its longhands in inline style, returning a JS string.
fn reconstructBoxShorthandJS(c: *qjs.JSContext, style_str: []const u8, shorthand: []const u8) ?qjs.JSValue {
    return reconstructBoxShorthandJSWithElem(c, style_str, shorthand, quickjs.JS_UNDEFINED());
}

/// Reconstruct a box shorthand from expanded longhands, optionally resolving values.
pub fn reconstructBoxShorthandJSWithElem(c: *qjs.JSContext, style_str: []const u8, shorthand: []const u8, elem_val: qjs.JSValue) ?qjs.JSValue {
    const longhands = getBoxLonghands(shorthand) orelse return null;
    const top_raw = dom_style.getStyleProperty(style_str, longhands[0]) orelse return null;
    const right_raw = dom_style.getStyleProperty(style_str, longhands[1]) orelse return null;
    const bottom_raw = dom_style.getStyleProperty(style_str, longhands[2]) orelse return null;
    const left_raw = dom_style.getStyleProperty(style_str, longhands[3]) orelse return null;

    // If elem_val is provided and this is a length shorthand, resolve each value
    const has_elem = !quickjs.JS_IsUndefined(elem_val);
    if (has_elem and (dom_style.eqlIgnoreCase(shorthand, "margin") or dom_style.eqlIgnoreCase(shorthand, "padding"))) {
        const font_size = dom_style.getElementFontSizeFromStyle(c, elem_val);
        const cb_width = dom_style.getContainingBlockWidth(c, elem_val);
        var resolved: [4]f32 = undefined;
        var all_resolved = true;
        const raw_vals = [4][]const u8{ top_raw, right_raw, bottom_raw, left_raw };
        for (0..4) |i| {
            const trimmed = std.mem.trim(u8, raw_vals[i], " \t\r\n");
            if (cascade_mod.resolveValueToPx(trimmed, font_size, g_viewport_width, g_viewport_height, cb_width)) |px| {
                resolved[i] = px;
            } else {
                all_resolved = false;
                break;
            }
        }
        if (all_resolved) {
            var buf: [128]u8 = undefined;
            return dom_style.fmtBoxShorthand(c, resolved[0], resolved[1], resolved[2], resolved[3], &buf);
        }
    }

    // Fallback: return raw values
    var buf: [256]u8 = undefined;
    if (std.mem.eql(u8, top_raw, right_raw) and std.mem.eql(u8, right_raw, bottom_raw) and std.mem.eql(u8, bottom_raw, left_raw)) {
        return qjs.JS_NewStringLen(c, top_raw.ptr, top_raw.len);
    } else if (std.mem.eql(u8, top_raw, bottom_raw) and std.mem.eql(u8, right_raw, left_raw)) {
        const r = std.fmt.bufPrint(&buf, "{s} {s}", .{ top_raw, right_raw }) catch return null;
        return qjs.JS_NewStringLen(c, r.ptr, r.len);
    } else if (std.mem.eql(u8, right_raw, left_raw)) {
        const r = std.fmt.bufPrint(&buf, "{s} {s} {s}", .{ top_raw, right_raw, bottom_raw }) catch return null;
        return qjs.JS_NewStringLen(c, r.ptr, r.len);
    } else {
        const r = std.fmt.bufPrint(&buf, "{s} {s} {s} {s}", .{ top_raw, right_raw, bottom_raw, left_raw }) catch return null;
        return qjs.JS_NewStringLen(c, r.ptr, r.len);
    }
}

/// Extract a longhand value from a stored shorthand in the style string.
pub fn getLonghandFromShorthand(style_str: []const u8, longhand: []const u8) ?[]const u8 {
    const info = getShorthandInfoForLonghand(longhand) orelse return null;
    const shorthand_val = dom_style.getStyleProperty(style_str, info.shorthand) orelse return null;

    var parts: [4][]const u8 = undefined;
    const count = splitBoxShorthandParts(shorthand_val, &parts);
    if (count == 0) return null;

    const expanded: [4][]const u8 = switch (count) {
        1 => .{ parts[0], parts[0], parts[0], parts[0] },
        2 => .{ parts[0], parts[1], parts[0], parts[1] },
        3 => .{ parts[0], parts[1], parts[2], parts[1] },
        4 => .{ parts[0], parts[1], parts[2], parts[3] },
        else => return null,
    };
    return expanded[info.index];
}

/// Normalize margin-trim value to canonical form.
fn normalizeMarginTrim(val: []const u8) []const u8 {
    if (dom_style.eqlIgnoreCase(val, "none")) return "none";
    if (dom_style.eqlIgnoreCase(val, "block")) return "block";
    if (dom_style.eqlIgnoreCase(val, "inline")) return "inline";
    // Preserve input order for shorthand combos
    if (dom_style.eqlIgnoreCase(val, "block inline")) return "block inline";
    if (dom_style.eqlIgnoreCase(val, "inline block")) return "inline block";
    // Parse keywords and canonicalize
    var bs = false;
    var be = false;
    var is_ = false;
    var ie = false;
    var pos: usize = 0;
    while (pos < val.len) {
        while (pos < val.len and (val[pos] == ' ' or val[pos] == '\t')) pos += 1;
        if (pos >= val.len) break;
        const start = pos;
        while (pos < val.len and val[pos] != ' ' and val[pos] != '\t') pos += 1;
        const kw = val[start..pos];
        if (dom_style.eqlIgnoreCase(kw, "block-start")) bs = true
        else if (dom_style.eqlIgnoreCase(kw, "block-end")) be = true
        else if (dom_style.eqlIgnoreCase(kw, "inline-start")) is_ = true
        else if (dom_style.eqlIgnoreCase(kw, "inline-end")) ie = true
        else if (dom_style.eqlIgnoreCase(kw, "block")) { bs = true; be = true; }
        else if (dom_style.eqlIgnoreCase(kw, "inline")) { is_ = true; ie = true; }
    }
    // Condensation: individual keywords → shorthand where possible
    if (bs and be and is_ and ie) return "block inline";
    if (bs and be and !is_ and !ie) return "block";
    if (!bs and !be and is_ and ie) return "inline";
    // "block inline" / "inline block" → preserve input order
    return val;
}

/// Create a style object for an element.
/// Uses setProperty/getPropertyValue as native methods, and sets up
/// camelCase property access via a JavaScript Proxy-like wrapper.
fn createStyleObject(ctx: *qjs.JSContext, element_val: qjs.JSValue) qjs.JSValue {
    const obj = qjs.JS_NewObject(ctx);
    if (quickjs.JS_IsException(obj)) return obj;

    // Store element reference
    _ = qjs.JS_SetPropertyStr(ctx, obj, "__element", qjs.JS_DupValue(ctx, element_val));

    // Native methods
    _ = qjs.JS_SetPropertyStr(ctx, obj, "setProperty", qjs.JS_NewCFunction(ctx, &styleSetProperty, "setProperty", 2));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "getPropertyValue", qjs.JS_NewCFunction(ctx, &styleGetPropertyValue, "getPropertyValue", 1));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "removeProperty", qjs.JS_NewCFunction(ctx, &styleRemoveProperty, "removeProperty", 1));

    // cssText getter/setter
    const cssTextAtom = qjs.JS_NewAtom(ctx, "cssText");
    _ = qjs.JS_DefinePropertyGetSet(ctx, obj, cssTextAtom, qjs.JS_NewCFunction(ctx, &dom_style.styleGetCssText, "get cssText", 0), qjs.JS_NewCFunction(ctx, &dom_style.styleSetCssText, "set cssText", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, cssTextAtom);

    // Define CSS property getter/setters using JS_NewCFunctionData.
    // Each getter/setter receives the CSS name as func_data[0].
    // This avoids Proxy (which triggers GC corruption on heavy JS pages).
    const camel_css_pairs = comptime [_]struct { camel: [:0]const u8, css: [:0]const u8 }{
        .{ .camel = "color", .css = "color" },
        .{ .camel = "backgroundColor", .css = "background-color" },
        .{ .camel = "background", .css = "background" },
        .{ .camel = "display", .css = "display" },
        .{ .camel = "width", .css = "width" },
        .{ .camel = "height", .css = "height" },
        .{ .camel = "minWidth", .css = "min-width" },
        .{ .camel = "minHeight", .css = "min-height" },
        .{ .camel = "maxWidth", .css = "max-width" },
        .{ .camel = "maxHeight", .css = "max-height" },
        .{ .camel = "margin", .css = "margin" },
        .{ .camel = "marginTop", .css = "margin-top" },
        .{ .camel = "marginRight", .css = "margin-right" },
        .{ .camel = "marginBottom", .css = "margin-bottom" },
        .{ .camel = "marginLeft", .css = "margin-left" },
        .{ .camel = "padding", .css = "padding" },
        .{ .camel = "paddingTop", .css = "padding-top" },
        .{ .camel = "paddingRight", .css = "padding-right" },
        .{ .camel = "paddingBottom", .css = "padding-bottom" },
        .{ .camel = "paddingLeft", .css = "padding-left" },
        .{ .camel = "border", .css = "border" },
        .{ .camel = "borderTop", .css = "border-top" },
        .{ .camel = "borderRight", .css = "border-right" },
        .{ .camel = "borderBottom", .css = "border-bottom" },
        .{ .camel = "borderLeft", .css = "border-left" },
        .{ .camel = "borderRadius", .css = "border-radius" },
        .{ .camel = "borderColor", .css = "border-color" },
        .{ .camel = "borderWidth", .css = "border-width" },
        .{ .camel = "borderStyle", .css = "border-style" },
        .{ .camel = "borderCollapse", .css = "border-collapse" },
        .{ .camel = "fontSize", .css = "font-size" },
        .{ .camel = "fontWeight", .css = "font-weight" },
        .{ .camel = "fontFamily", .css = "font-family" },
        .{ .camel = "fontStyle", .css = "font-style" },
        .{ .camel = "textAlign", .css = "text-align" },
        .{ .camel = "textDecoration", .css = "text-decoration" },
        .{ .camel = "textTransform", .css = "text-transform" },
        .{ .camel = "textIndent", .css = "text-indent" },
        .{ .camel = "lineHeight", .css = "line-height" },
        .{ .camel = "letterSpacing", .css = "letter-spacing" },
        .{ .camel = "position", .css = "position" },
        .{ .camel = "top", .css = "top" },
        .{ .camel = "left", .css = "left" },
        .{ .camel = "right", .css = "right" },
        .{ .camel = "bottom", .css = "bottom" },
        .{ .camel = "zIndex", .css = "z-index" },
        .{ .camel = "opacity", .css = "opacity" },
        .{ .camel = "visibility", .css = "visibility" },
        .{ .camel = "overflow", .css = "overflow" },
        .{ .camel = "overflowX", .css = "overflow-x" },
        .{ .camel = "overflowY", .css = "overflow-y" },
        .{ .camel = "cursor", .css = "cursor" },
        .{ .camel = "float", .css = "float" },
        .{ .camel = "clear", .css = "clear" },
        .{ .camel = "transform", .css = "transform" },
        .{ .camel = "transition", .css = "transition" },
        .{ .camel = "boxShadow", .css = "box-shadow" },
        .{ .camel = "textShadow", .css = "text-shadow" },
        .{ .camel = "whiteSpace", .css = "white-space" },
        .{ .camel = "wordBreak", .css = "word-break" },
        .{ .camel = "wordWrap", .css = "word-wrap" },
        .{ .camel = "textWrap", .css = "text-wrap" },
        .{ .camel = "textWrapMode", .css = "text-wrap-mode" },
        .{ .camel = "textWrapStyle", .css = "text-wrap-style" },
        .{ .camel = "tabSize", .css = "tab-size" },
        .{ .camel = "hyphens", .css = "hyphens" },
        .{ .camel = "overflowWrap", .css = "overflow-wrap" },
        .{ .camel = "flexDirection", .css = "flex-direction" },
        .{ .camel = "flexWrap", .css = "flex-wrap" },
        .{ .camel = "justifyContent", .css = "justify-content" },
        .{ .camel = "alignItems", .css = "align-items" },
        .{ .camel = "alignSelf", .css = "align-self" },
        .{ .camel = "flex", .css = "flex" },
        .{ .camel = "flexGrow", .css = "flex-grow" },
        .{ .camel = "flexShrink", .css = "flex-shrink" },
        .{ .camel = "flexBasis", .css = "flex-basis" },
        .{ .camel = "gap", .css = "gap" },
        .{ .camel = "gridTemplateColumns", .css = "grid-template-columns" },
        .{ .camel = "gridTemplateRows", .css = "grid-template-rows" },
        .{ .camel = "gridColumn", .css = "grid-column" },
        .{ .camel = "gridRow", .css = "grid-row" },
        .{ .camel = "listStyle", .css = "list-style" },
        .{ .camel = "listStyleType", .css = "list-style-type" },
        .{ .camel = "outline", .css = "outline" },
        .{ .camel = "outlineColor", .css = "outline-color" },
        .{ .camel = "outlineStyle", .css = "outline-style" },
        .{ .camel = "outlineWidth", .css = "outline-width" },
        .{ .camel = "content", .css = "content" },
        .{ .camel = "pointerEvents", .css = "pointer-events" },
        .{ .camel = "userSelect", .css = "user-select" },
        .{ .camel = "objectFit", .css = "object-fit" },
        .{ .camel = "verticalAlign", .css = "vertical-align" },
        .{ .camel = "boxSizing", .css = "box-sizing" },
        .{ .camel = "marginTrim", .css = "margin-trim" },
        .{ .camel = "readingFlow", .css = "reading-flow" },
        .{ .camel = "readingOrder", .css = "reading-order" },
        .{ .camel = "order", .css = "order" },
        .{ .camel = "tableLayout", .css = "table-layout" },
        .{ .camel = "willChange", .css = "will-change" },
    };

    for (camel_css_pairs) |pair| {
        const css_js = qjs.JS_NewStringLen(ctx, pair.css.ptr, pair.css.len);
        // Define getter/setter for camelCase name
        {
            var gd = [1]qjs.JSValue{qjs.JS_DupValue(ctx, css_js)};
            var sd = [1]qjs.JSValue{qjs.JS_DupValue(ctx, css_js)};
            const getter = qjs.JS_NewCFunctionData(ctx, &stylePropDataGet, 0, 0, 1, &gd);
            const setter = qjs.JS_NewCFunctionData(ctx, &stylePropDataSet, 1, 0, 1, &sd);
            const atom = qjs.JS_NewAtom(ctx, pair.camel);
            _ = qjs.JS_DefinePropertyGetSet(ctx, obj, atom, getter, setter, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
            qjs.JS_FreeAtom(ctx, atom);
            qjs.JS_FreeValue(ctx, gd[0]);
            qjs.JS_FreeValue(ctx, sd[0]);
        }
        // Also define for CSS name (hyphenated) if different from camelCase
        if (!std.mem.eql(u8, pair.camel, pair.css)) {
            var gd = [1]qjs.JSValue{qjs.JS_DupValue(ctx, css_js)};
            var sd = [1]qjs.JSValue{qjs.JS_DupValue(ctx, css_js)};
            const getter = qjs.JS_NewCFunctionData(ctx, &stylePropDataGet, 0, 0, 1, &gd);
            const setter = qjs.JS_NewCFunctionData(ctx, &stylePropDataSet, 1, 0, 1, &sd);
            const atom = qjs.JS_NewAtom(ctx, pair.css);
            _ = qjs.JS_DefinePropertyGetSet(ctx, obj, atom, getter, setter, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
            qjs.JS_FreeAtom(ctx, atom);
            qjs.JS_FreeValue(ctx, gd[0]);
            qjs.JS_FreeValue(ctx, sd[0]);
        }
        qjs.JS_FreeValue(ctx, css_js);
    }

    return obj;
}

/// Getter for CSS property via JS_NewCFunctionData. func_data[0] = CSS name string.
fn stylePropDataGet(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
    _: c_int,
    func_data: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const gpv = qjs.JS_GetPropertyStr(c, this_val, "getPropertyValue");
    if (quickjs.JS_IsUndefined(gpv)) return qjs.JS_NewStringLen(c, "", 0);
    defer qjs.JS_FreeValue(c, gpv);
    var call_args = [1]qjs.JSValue{qjs.JS_DupValue(c, func_data[0])};
    const result = qjs.JS_Call(c, gpv, this_val, 1, &call_args);
    qjs.JS_FreeValue(c, call_args[0]);
    return result;
}

/// Setter for CSS property via JS_NewCFunctionData. func_data[0] = CSS name string.
fn stylePropDataSet(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
    _: c_int,
    func_data: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    // Convert value to string
    var val_len: usize = 0;
    const val_ptr = qjs.JS_ToCStringLen(c, &val_len, argv[0]);
    if (val_ptr == null) return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, val_ptr);
    const val_str = qjs.JS_NewStringLen(c, val_ptr, val_len);
    const sp = qjs.JS_GetPropertyStr(c, this_val, "setProperty");
    if (quickjs.JS_IsUndefined(sp)) {
        qjs.JS_FreeValue(c, val_str);
        return quickjs.JS_UNDEFINED();
    }
    defer qjs.JS_FreeValue(c, sp);
    var call_args = [2]qjs.JSValue{ qjs.JS_DupValue(c, func_data[0]), val_str };
    const result = qjs.JS_Call(c, sp, this_val, 2, &call_args);
    qjs.JS_FreeValue(c, call_args[0]);
    qjs.JS_FreeValue(c, val_str);
    qjs.JS_FreeValue(c, result);
    return quickjs.JS_UNDEFINED();
}

fn styleSetProperty(
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

    const prop_s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, prop_s.ptr);
    const val_s = jsStringToSlice(c, args[1]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, val_s.ptr);

    const prop = prop_s.ptr[0..prop_s.len];
    const val = val_s.ptr[0..val_s.len];

    // Validate CSS value: reject invalid values (WPT -invalid tests expect this)
    if (val.len > 0) {
        if (!dom_style.isValidCssValue(prop, val)) return quickjs.JS_UNDEFINED();
    }

    // Canonicalize CSS values for canonical serialization
    // CSS spec: unitless 0 → "0px" for length properties
    const trimmed_val2 = std.mem.trim(u8, val, " \t\r\n");
    const zero_px = "0px";
    var calc_buf: [512]u8 = undefined;
    const effective_val = if (std.mem.eql(u8, trimmed_val2, "0") and dom_style.isComputedLengthProperty(prop))
        zero_px
    else if (dom_style.eqlIgnoreCase(prop, "display"))
        dom_style.canonicalizeDisplayValue(val)
    else if (val.len >= 5 and dom_style.eqlIgnoreCase(val[0..5], "calc("))
        dom_style.canonicalizeCalcValue(val, &calc_buf) orelse val
    else if (val.len >= 4 and (dom_style.eqlIgnoreCase(val[0..4], "min(") or dom_style.eqlIgnoreCase(val[0..4], "max(")))
        dom_style.canonicalizeSingleArgMath(val, &calc_buf) orelse val
    else if (val.len >= 6 and dom_style.eqlIgnoreCase(val[0..6], "clamp("))
        dom_style.canonicalizeClamp(val, &calc_buf) orelse val
    else if (val.len >= 6 and dom_style.eqlIgnoreCase(val[0..6], "round("))
        dom_style.canonicalizeRoundModRem(val, &calc_buf) orelse val
    else if (val.len >= 4 and dom_style.eqlIgnoreCase(val[0..4], "mod("))
        dom_style.canonicalizeRoundModRem(val, &calc_buf) orelse val
    else if (val.len >= 4 and dom_style.eqlIgnoreCase(val[0..4], "rem("))
        dom_style.canonicalizeRoundModRem(val, &calc_buf) orelse val
    else
        val;

    var style_len: usize = 0;
    const style_ptr = lxb_dom_element_get_attribute(elem, "style", 5, &style_len);
    const current_style = if (style_ptr != null and style_len > 0) style_ptr.?[0..style_len] else "";

    // margin-trim value normalization (block-start block-end → block)
    if (dom_style.eqlIgnoreCase(prop, "margin-trim")) {
        const trimmed_val = std.mem.trim(u8, val, " \t\r\n");
        if (trimmed_val.len > 0 and !dom_style.eqlIgnoreCase(trimmed_val, "inherit") and
            !dom_style.eqlIgnoreCase(trimmed_val, "initial") and !dom_style.eqlIgnoreCase(trimmed_val, "unset") and
            !dom_style.eqlIgnoreCase(trimmed_val, "revert"))
        {
            const normalized = normalizeMarginTrim(trimmed_val);
            var buf: [4096]u8 = undefined;
            if (dom_style.setStyleProperty(current_style, prop, normalized, &buf)) |new_style| {
                _ = lxb_dom_element_set_attribute(elem, "style", 5, new_style.ptr, new_style.len);
                setDomDirtyIfConnected(elem);
            }
            return quickjs.JS_UNDEFINED();
        }
    }

    // Box shorthand expansion (margin, padding → longhands)
    if (getBoxLonghands(prop)) |longhands| {
        const trimmed_val = std.mem.trim(u8, val, " \t\r\n");
        if (trimmed_val.len == 0) {
            // Remove shorthand and all longhands
            var buf: [4096]u8 = undefined;
            if (removeBoxShorthandFromStyle(current_style, prop, longhands, &buf)) |new_style| {
                _ = lxb_dom_element_set_attribute(elem, "style", 5, new_style.ptr, new_style.len);
                setDomDirtyIfConnected(elem);
            }
            return quickjs.JS_UNDEFINED();
        }
        var expanded_vals: [4][]const u8 = undefined;
        if (dom_style.eqlIgnoreCase(trimmed_val, "inherit") or dom_style.eqlIgnoreCase(trimmed_val, "initial") or
            dom_style.eqlIgnoreCase(trimmed_val, "unset") or dom_style.eqlIgnoreCase(trimmed_val, "revert"))
        {
            expanded_vals = .{ trimmed_val, trimmed_val, trimmed_val, trimmed_val };
        } else {
            var parts: [4][]const u8 = undefined;
            const count = splitBoxShorthandParts(trimmed_val, &parts);
            if (count == 0) return quickjs.JS_UNDEFINED();
            expanded_vals = switch (count) {
                1 => .{ parts[0], parts[0], parts[0], parts[0] },
                2 => .{ parts[0], parts[1], parts[0], parts[1] },
                3 => .{ parts[0], parts[1], parts[2], parts[1] },
                4 => .{ parts[0], parts[1], parts[2], parts[3] },
                else => return quickjs.JS_UNDEFINED(),
            };
        }
        var buf: [4096]u8 = undefined;
        if (expandBoxShorthandInStyle(current_style, prop, longhands, expanded_vals, &buf)) |new_style| {
            _ = lxb_dom_element_set_attribute(elem, "style", 5, new_style.ptr, new_style.len);
            setDomDirtyIfConnected(elem);
        }
        return quickjs.JS_UNDEFINED();
    }

    var buf: [4096]u8 = undefined;
    if (dom_style.setStyleProperty(current_style, prop, effective_val, &buf)) |new_style| {
        _ = lxb_dom_element_set_attribute(elem, "style", 5, new_style.ptr, new_style.len);
        setDomDirtyIfConnected(elem);
    }
    return quickjs.JS_UNDEFINED();
}

fn styleGetPropertyValue(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return qjs.JS_NewStringLen(c, "", 0);
    const args = argv orelse return qjs.JS_NewStringLen(c, "", 0);

    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return qjs.JS_NewStringLen(c, "", 0);

    const prop_s = jsStringToSlice(c, args[0]) orelse return qjs.JS_NewStringLen(c, "", 0);
    defer qjs.JS_FreeCString(c, prop_s.ptr);

    var style_len: usize = 0;
    const style_ptr = lxb_dom_element_get_attribute(elem, "style", 5, &style_len);
    if (style_ptr == null or style_len == 0) return qjs.JS_NewStringLen(c, "", 0);

    const style = style_ptr.?[0..style_len];
    const prop = prop_s.ptr[0..prop_s.len];

    // Direct lookup
    if (dom_style.getStyleProperty(style, prop)) |val| {
        // For element.style (specified value), color keywords stay as keywords
        // per CSSOM §6.7.2 and CSS Color Level 4 §15
        if (dom_style.isColorProperty(prop)) {
            const tv = std.mem.trim(u8, val, " \t\r\n");
            // Named colors, transparent, currentcolor → return lowercase as-is
            // Check if it's a named color keyword (not a function like rgb(...))
            const is_keyword = blk: {
                if (dom_style.eqlIgnoreCase(tv, "transparent") or dom_style.eqlIgnoreCase(tv, "currentcolor")) break :blk true;
                // If it has parentheses, it's a function, not a keyword
                if (std.mem.indexOf(u8, tv, "(") != null) break :blk false;
                // If parseColor succeeds and it's not a hex (#...), it's a named color
                const color_mod2 = @import("../css/properties.zig");
                if (tv.len > 0 and tv[0] == '#') break :blk false;
                break :blk color_mod2.parseColor(tv) != null;
            };
            if (is_keyword) {
                // Lowercase the keyword
                var lbuf: [32]u8 = undefined;
                if (tv.len <= lbuf.len) {
                    for (tv, 0..) |ch, i| {
                        lbuf[i] = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
                    }
                    return qjs.JS_NewStringLen(c, &lbuf, tv.len);
                }
                return qjs.JS_NewStringLen(c, tv.ptr, tv.len);
            }
            // rgb()/rgba()/hsl()/hsla() → normalize to canonical rgb()/rgba()
            const color_mod = @import("../css/properties.zig");
            if (tv.len >= 6 and dom_style.eqlIgnoreCase(tv[0..6], "color(")) {
                return dom_style.formatColorFuncComputed(c, tv);
            }
            if (color_mod.parseColor(tv)) |color| {
                var color_buf: [64]u8 = undefined;
                // Clamp alpha to [0, 1] range
                const clamped_a = if (color.a > 255) @as(u8, 255) else color.a;
                if (clamped_a == 255) {
                    const s = std.fmt.bufPrint(&color_buf, "rgb({d}, {d}, {d})", .{ color.r, color.g, color.b }) catch return qjs.JS_NewStringLen(c, val.ptr, val.len);
                    return qjs.JS_NewStringLen(c, s.ptr, s.len);
                } else {
                    const orig_alpha = dom_style.extractOriginalAlpha(tv);
                    var alpha_buf: [16]u8 = undefined;
                    const alpha_s = if (orig_alpha) |a| blk: {
                        // Clamp negative alpha to 0
                        const clamped = if (a < 0) @as(f32, 0) else if (a > 1) @as(f32, 1) else a;
                        break :blk std.fmt.bufPrint(&alpha_buf, "{d}", .{clamped}) catch "0";
                    } else blk: {
                        const a = @as(f32, @floatFromInt(clamped_a)) / 255.0;
                        break :blk std.fmt.bufPrint(&alpha_buf, "{d}", .{a}) catch "0";
                    };
                    const s = std.fmt.bufPrint(&color_buf, "rgba({d}, {d}, {d}, {s})", .{ color.r, color.g, color.b, alpha_s }) catch return qjs.JS_NewStringLen(c, val.ptr, val.len);
                    return qjs.JS_NewStringLen(c, s.ptr, s.len);
                }
            }
        }
        return qjs.JS_NewStringLen(c, val.ptr, val.len);
    }

    // Try shorthand reconstruction from longhands (e.g., "margin" from margin-top/right/bottom/left)
    if (getBoxLonghands(prop)) |longhands| {
        const top_v = dom_style.getStyleProperty(style, longhands[0]) orelse return qjs.JS_NewStringLen(c, "", 0);
        const right_v = dom_style.getStyleProperty(style, longhands[1]) orelse return qjs.JS_NewStringLen(c, "", 0);
        const bottom_v = dom_style.getStyleProperty(style, longhands[2]) orelse return qjs.JS_NewStringLen(c, "", 0);
        const left_v = dom_style.getStyleProperty(style, longhands[3]) orelse return qjs.JS_NewStringLen(c, "", 0);
        var buf: [256]u8 = undefined;
        if (std.mem.eql(u8, top_v, right_v) and std.mem.eql(u8, right_v, bottom_v) and std.mem.eql(u8, bottom_v, left_v)) {
            return qjs.JS_NewStringLen(c, top_v.ptr, top_v.len);
        } else if (std.mem.eql(u8, top_v, bottom_v) and std.mem.eql(u8, right_v, left_v)) {
            const r = std.fmt.bufPrint(&buf, "{s} {s}", .{ top_v, right_v }) catch return qjs.JS_NewStringLen(c, "", 0);
            return qjs.JS_NewStringLen(c, r.ptr, r.len);
        } else if (std.mem.eql(u8, right_v, left_v)) {
            const r = std.fmt.bufPrint(&buf, "{s} {s} {s}", .{ top_v, right_v, bottom_v }) catch return qjs.JS_NewStringLen(c, "", 0);
            return qjs.JS_NewStringLen(c, r.ptr, r.len);
        } else {
            const r = std.fmt.bufPrint(&buf, "{s} {s} {s} {s}", .{ top_v, right_v, bottom_v, left_v }) catch return qjs.JS_NewStringLen(c, "", 0);
            return qjs.JS_NewStringLen(c, r.ptr, r.len);
        }
    }

    // Try extracting longhand from stored shorthand (e.g., "margin-top" from "margin: 1px 2px")
    if (getLonghandFromShorthand(style, prop)) |val| {
        return qjs.JS_NewStringLen(c, val.ptr, val.len);
    }

    return qjs.JS_NewStringLen(c, "", 0);
}

fn styleRemoveProperty(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return qjs.JS_NewStringLen(c, "", 0);
    const args = argv orelse return qjs.JS_NewStringLen(c, "", 0);

    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return qjs.JS_NewStringLen(c, "", 0);

    const prop_s = jsStringToSlice(c, args[0]) orelse return qjs.JS_NewStringLen(c, "", 0);
    defer qjs.JS_FreeCString(c, prop_s.ptr);

    var style_len: usize = 0;
    const style_ptr = lxb_dom_element_get_attribute(elem, "style", 5, &style_len);
    if (style_ptr == null or style_len == 0) return qjs.JS_NewStringLen(c, "", 0);

    const current_style = style_ptr.?[0..style_len];
    const prop = prop_s.ptr[0..prop_s.len];

    // Box shorthand removal — remove shorthand + all longhands, return old value
    if (getBoxLonghands(prop)) |longhands| {
        // Capture old value before removal (reconstruct from longhands if needed)
        var old_js: qjs.JSValue = qjs.JS_NewStringLen(c, "", 0);
        if (dom_style.getStyleProperty(current_style, prop)) |ov| {
            old_js = qjs.JS_NewStringLen(c, ov.ptr, ov.len);
        } else if (reconstructBoxShorthandJS(c, current_style, prop)) |reconstructed| {
            old_js = reconstructed;
        }
        var buf: [4096]u8 = undefined;
        if (removeBoxShorthandFromStyle(current_style, prop, longhands, &buf)) |new_style| {
            _ = lxb_dom_element_set_attribute(elem, "style", 5, new_style.ptr, new_style.len);
            setDomDirty();
        }
        return old_js;
    }

    // Get old value first
    const old_val = dom_style.getStyleProperty(current_style, prop);

    var buf: [4096]u8 = undefined;
    if (dom_style.setStyleProperty(current_style, prop, "", &buf)) |new_style| {
        _ = lxb_dom_element_set_attribute(elem, "style", 5, new_style.ptr, new_style.len);
        setDomDirty();
    }

    if (old_val) |ov| {
        return qjs.JS_NewStringLen(c, ov.ptr, ov.len);
    }
    return qjs.JS_NewStringLen(c, "", 0);
}

fn elementGetStyle(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();

    // Return cached style object if available (avoids creating hundreds of Proxies
    // when WPT tests access element.style repeatedly in batch)
    const cached = qjs.JS_GetPropertyStr(c, this_val, "__style");
    if (!quickjs.JS_IsUndefined(cached) and !quickjs.JS_IsNull(cached)) {
        return cached; // GetPropertyStr already incremented refcount
    }
    qjs.JS_FreeValue(c, cached);

    const style_obj = createStyleObject(c, this_val);
    if (!quickjs.JS_IsException(style_obj)) {
        _ = qjs.JS_SetPropertyStr(c, this_val, "__style", qjs.JS_DupValue(c, style_obj));
    }
    return style_obj;
}

// ── element.append(...nodes) / prepend(...nodes) ────────────────────

fn elementAppend(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const parent = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    var i: usize = 0;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        const child_node = getNode(c, args[i]);
        if (child_node) |cn| {
            // Remove from old parent first (DOM spec)
            if (cn.parent != null) lxb.lxb_dom_node_remove(cn);
            _ = lxb.lxb_dom_node_insert_child(parent, cn);
        } else {
            // Non-Node argument: convert to string and create text node
            // DOM spec: "If nodes is a string, replace it with a new Text node"
            const s = jsStringToSlice(c, qjs.JS_ToString(c, args[i])) orelse continue;
            defer qjs.JS_FreeCString(c, s.ptr);
            if (g_document) |doc| {
                const text_node = lxb_dom_document_create_text_node(doc, s.ptr, s.len);
                if (text_node) |tn| {
                    _ = lxb.lxb_dom_node_insert_child(parent, tn);
                }
            }
        }
    }
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

fn elementPrepend(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const parent = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const first_child = lxb.lxb_dom_node_first_child(parent);
    var i: usize = 0;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        const child_node = getNode(c, args[i]);
        if (child_node) |cn| {
            if (cn.parent != null) lxb.lxb_dom_node_remove(cn);
            if (first_child) |fc| {
                _ = lxb.lxb_dom_node_insert_before(fc, cn);
            } else {
                _ = lxb.lxb_dom_node_insert_child(parent, cn);
            }
        } else {
            // Non-Node argument: convert to string and create text node
            const s = jsStringToSlice(c, qjs.JS_ToString(c, args[i])) orelse continue;
            defer qjs.JS_FreeCString(c, s.ptr);
            if (g_document) |doc| {
                const text_node = lxb_dom_document_create_text_node(doc, s.ptr, s.len);
                if (text_node) |tn| {
                    if (first_child) |fc| {
                        _ = lxb.lxb_dom_node_insert_before(fc, tn);
                    } else {
                        _ = lxb.lxb_dom_node_insert_child(parent, tn);
                    }
                }
            }
        }
    }
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

// ── element.attributes (NamedNodeMap) ───────────────────────────────

fn elementGetAttributes(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    const elem = getElement(c, this_val) orelse return qjs.JS_NewObject(c);
    const obj = qjs.JS_NewObject(c);
    if (quickjs.JS_IsException(obj)) return obj;

    var count: u32 = 0;
    var attr: ?*anyopaque = lxb_dom_element_first_attribute_noi(elem);
    while (attr) |a| {
        var name_len: usize = 0;
        const name_ptr = lxb_dom_attr_qualified_name(a, &name_len);
        var val_len: usize = 0;
        const val_ptr = lxb_dom_attr_value_noi(a, &val_len);

        if (name_ptr) |np| {
            const name_str = np[0..name_len];
            const val_str = if (val_ptr) |vp| vp[0..val_len] else "";

            // Create Attr-like object per DOM spec
            const attr_obj = qjs.JS_NewObject(c);
            _ = qjs.JS_SetPropertyStr(c, attr_obj, "nodeType", qjs.JS_NewInt32(c, 2));
            _ = qjs.JS_SetPropertyStr(c, attr_obj, "name", qjs.JS_NewStringLen(c, name_str.ptr, name_str.len));
            _ = qjs.JS_SetPropertyStr(c, attr_obj, "value", qjs.JS_NewStringLen(c, val_str.ptr, val_str.len));
            _ = qjs.JS_SetPropertyStr(c, attr_obj, "nodeName", qjs.JS_NewStringLen(c, name_str.ptr, name_str.len));
            _ = qjs.JS_SetPropertyStr(c, attr_obj, "nodeValue", qjs.JS_NewStringLen(c, val_str.ptr, val_str.len));
            _ = qjs.JS_SetPropertyStr(c, attr_obj, "localName", qjs.JS_NewStringLen(c, name_str.ptr, name_str.len));
            _ = qjs.JS_SetPropertyStr(c, attr_obj, "namespaceURI", quickjs.JS_NULL());
            _ = qjs.JS_SetPropertyStr(c, attr_obj, "prefix", quickjs.JS_NULL());
            _ = qjs.JS_SetPropertyStr(c, attr_obj, "ownerElement", qjs.JS_DupValue(c, this_val));
            _ = qjs.JS_SetPropertyStr(c, attr_obj, "specified", quickjs.JS_NewBool(true));

            // Indexed access
            _ = qjs.JS_SetPropertyUint32(c, obj, count, qjs.JS_DupValue(c, attr_obj));
            // Named access
            _ = qjs.JS_SetPropertyStr(c, obj, name_str.ptr, attr_obj);
            count += 1;
        }
        attr = lxb_dom_element_next_attribute_noi(a);
    }

    _ = qjs.JS_SetPropertyStr(c, obj, "length", qjs.JS_NewInt32(c, @intCast(count)));

    // getNamedItem method
    const gni_js =
        \\(function(){var m=this;return function(n){for(var i=0;i<m.length;i++)if(m[i]&&m[i].name===n)return m[i];return null;};})()
    ;
    const gni_fn = qjs.JS_Eval(c, gni_js, gni_js.len, "<attributes>", qjs.JS_EVAL_TYPE_GLOBAL);
    if (!quickjs.JS_IsException(gni_fn)) {
        var this_arg = [_]qjs.JSValue{obj};
        const bound = qjs.JS_Call(c, gni_fn, obj, 0, &this_arg);
        _ = qjs.JS_SetPropertyStr(c, obj, "getNamedItem", bound);
        qjs.JS_FreeValue(c, gni_fn);
    }

    // item method
    const item_js =
        \\(function(){var m=this;return function(i){return m[i]||null;};})()
    ;
    const item_fn = qjs.JS_Eval(c, item_js, item_js.len, "<attributes>", qjs.JS_EVAL_TYPE_GLOBAL);
    if (!quickjs.JS_IsException(item_fn)) {
        var item_arg = [_]qjs.JSValue{obj};
        const bound_item = qjs.JS_Call(c, item_fn, obj, 0, &item_arg);
        _ = qjs.JS_SetPropertyStr(c, obj, "item", bound_item);
        qjs.JS_FreeValue(c, item_fn);
    }

    return obj;
}


// ── element.dataset ─────────────────────────────────────────────────

fn elementGetElementsByClassName(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, s.ptr);

    // Build CSS selector: ".className"
    const class_name = s.ptr[0..s.len];
    var selector_buf: [256]u8 = undefined;
    if (class_name.len + 1 > selector_buf.len) return quickjs.JS_NULL();
    selector_buf[0] = '.';
    @memcpy(selector_buf[1 .. 1 + class_name.len], class_name);
    const selector = selector_buf[0 .. 1 + class_name.len];

    const arr = qjs.JS_NewArray(c);
    if (quickjs.JS_IsException(arr)) return arr;
    var idx: u32 = 0;
    dom_sel.walkTreeCollect(c, node, selector, arr, &idx);
    dom_doc.wrapAsHTMLCollection(c, arr);
    return arr;
}

fn elementGetElementsByTagName(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, s.ptr);

    const arr = qjs.JS_NewArray(c);
    if (quickjs.JS_IsException(arr)) return arr;
    var idx: u32 = 0;
    dom_sel.walkTreeCollect(c, node, s.ptr[0..s.len], arr, &idx);
    // Set HTMLCollection prototype
    dom_doc.wrapAsHTMLCollection(c, arr);
    return arr;
}

pub fn upgradeCustomElement(ctx: *qjs.JSContext, elem: qjs.JSValue, tag_ptr: [*]const u8, tag_len: usize) void {
    // Convert tag name to lowercase for registry lookup (null-terminated)
    var lower_buf: [129]u8 = undefined;
    if (tag_len >= lower_buf.len) return;
    for (0..tag_len) |i| {
        const ch = tag_ptr[i];
        lower_buf[i] = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
    }
    lower_buf[tag_len] = 0; // null terminate

    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);

    const registry = qjs.JS_GetPropertyStr(ctx, global, "__ce_registry");
    defer qjs.JS_FreeValue(ctx, registry);
    if (quickjs.JS_IsUndefined(registry) or quickjs.JS_IsNull(registry)) return;

    const ctor = qjs.JS_GetPropertyStr(ctx, registry, &lower_buf);
    defer qjs.JS_FreeValue(ctx, ctor);
    if (quickjs.JS_IsUndefined(ctor) or quickjs.JS_IsNull(ctor)) return;

    // Call __ce_upgradeEl(elem, ctor)
    const upgrade_fn = qjs.JS_GetPropertyStr(ctx, global, "__ce_upgradeEl");
    defer qjs.JS_FreeValue(ctx, upgrade_fn);
    if (quickjs.JS_IsUndefined(upgrade_fn)) return;

    var call_args = [2]qjs.JSValue{ elem, ctor };
    const result = qjs.JS_Call(ctx, upgrade_fn, quickjs.JS_UNDEFINED(), 2, &call_args);
    qjs.JS_FreeValue(ctx, result);
}

// ── window.location ─────────────────────────────────────────────────

fn windowLocationGetHref(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (g_current_url) |url| {
        return qjs.JS_NewStringLen(c, url.ptr, url.len);
    }
    return qjs.JS_NewStringLen(c, "", 0);
}

fn windowLocationGetProtocol(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (g_current_url) |url| {
        if (std.mem.indexOf(u8, url, "://")) |idx| {
            return qjs.JS_NewStringLen(c, url.ptr, idx + 1); // includes the ':'
        }
    }
    return qjs.JS_NewStringLen(c, "", 0);
}

fn windowLocationGetHostname(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (g_current_url) |url| {
        if (std.mem.indexOf(u8, url, "://")) |idx| {
            const after = url[idx + 3 ..];
            const end = std.mem.indexOfAny(u8, after, ":/") orelse after.len;
            return qjs.JS_NewStringLen(c, after.ptr, end);
        }
    }
    return qjs.JS_NewStringLen(c, "", 0);
}

fn windowLocationGetHost(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (g_current_url) |url| {
        if (std.mem.indexOf(u8, url, "://")) |idx| {
            const after = url[idx + 3 ..];
            const end = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
            return qjs.JS_NewStringLen(c, after.ptr, end);
        }
    }
    return qjs.JS_NewStringLen(c, "", 0);
}

fn windowLocationGetPathname(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (g_current_url) |url| {
        if (std.mem.indexOf(u8, url, "://")) |idx| {
            const after = url[idx + 3 ..];
            if (std.mem.indexOfScalar(u8, after, '/')) |slash| {
                const path_start = after[slash..];
                // Path is up to ? or #
                const end = std.mem.indexOfAny(u8, path_start, "?#") orelse path_start.len;
                return qjs.JS_NewStringLen(c, path_start.ptr, end);
            }
        }
    }
    return qjs.JS_NewStringLen(c, "/", 1);
}

fn windowLocationGetSearch(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (g_current_url) |url| {
        if (std.mem.indexOfScalar(u8, url, '?')) |q| {
            const end = std.mem.indexOfScalar(u8, url[q..], '#') orelse url.len - q;
            return qjs.JS_NewStringLen(c, url[q..].ptr, end);
        }
    }
    return qjs.JS_NewStringLen(c, "", 0);
}

fn windowLocationGetHash(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (g_current_url) |url| {
        if (std.mem.indexOfScalar(u8, url, '#')) |h| {
            return qjs.JS_NewStringLen(c, url[h..].ptr, url.len - h);
        }
    }
    return qjs.JS_NewStringLen(c, "", 0);
}

fn windowLocationGetOrigin(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (g_current_url) |url| {
        if (std.mem.indexOf(u8, url, "://")) |idx| {
            const after = url[idx + 3 ..];
            const end = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
            return qjs.JS_NewStringLen(c, url.ptr, idx + 3 + end);
        }
    }
    return qjs.JS_NewStringLen(c, "", 0);
}

fn windowLocationToString(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    return windowLocationGetHref(ctx, quickjs.JS_UNDEFINED(), 0, null);
}

fn windowLocationReload(
    _: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    // Stub — actual reload requires main loop integration
    return quickjs.JS_UNDEFINED();
}

fn windowLocationAssign(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const url_s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, url_s.ptr);
    // Delegate to web_api for actual navigation
    const web_api = @import("web_api.zig");
    web_api.requestNavigation(url_s.ptr[0..url_s.len]);
    return quickjs.JS_UNDEFINED();
}

fn createLocationObject(ctx: *qjs.JSContext) qjs.JSValue {
    const loc = qjs.JS_NewObject(ctx);
    if (quickjs.JS_IsException(loc)) return loc;

    // href getter
    const hrefAtom = qjs.JS_NewAtom(ctx, "href");
    _ = qjs.JS_DefinePropertyGetSet(ctx, loc, hrefAtom, qjs.JS_NewCFunction(ctx, &windowLocationGetHref, "get href", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, hrefAtom);

    const protocolAtom = qjs.JS_NewAtom(ctx, "protocol");
    _ = qjs.JS_DefinePropertyGetSet(ctx, loc, protocolAtom, qjs.JS_NewCFunction(ctx, &windowLocationGetProtocol, "get protocol", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, protocolAtom);

    const hostnameAtom = qjs.JS_NewAtom(ctx, "hostname");
    _ = qjs.JS_DefinePropertyGetSet(ctx, loc, hostnameAtom, qjs.JS_NewCFunction(ctx, &windowLocationGetHostname, "get hostname", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, hostnameAtom);

    const hostAtom = qjs.JS_NewAtom(ctx, "host");
    _ = qjs.JS_DefinePropertyGetSet(ctx, loc, hostAtom, qjs.JS_NewCFunction(ctx, &windowLocationGetHost, "get host", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, hostAtom);

    const pathnameAtom = qjs.JS_NewAtom(ctx, "pathname");
    _ = qjs.JS_DefinePropertyGetSet(ctx, loc, pathnameAtom, qjs.JS_NewCFunction(ctx, &windowLocationGetPathname, "get pathname", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, pathnameAtom);

    const searchAtom = qjs.JS_NewAtom(ctx, "search");
    _ = qjs.JS_DefinePropertyGetSet(ctx, loc, searchAtom, qjs.JS_NewCFunction(ctx, &windowLocationGetSearch, "get search", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, searchAtom);

    const hashAtom = qjs.JS_NewAtom(ctx, "hash");
    _ = qjs.JS_DefinePropertyGetSet(ctx, loc, hashAtom, qjs.JS_NewCFunction(ctx, &windowLocationGetHash, "get hash", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, hashAtom);

    const originAtom = qjs.JS_NewAtom(ctx, "origin");
    _ = qjs.JS_DefinePropertyGetSet(ctx, loc, originAtom, qjs.JS_NewCFunction(ctx, &windowLocationGetOrigin, "get origin", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, originAtom);

    _ = qjs.JS_SetPropertyStr(ctx, loc, "reload", qjs.JS_NewCFunction(ctx, &windowLocationReload, "reload", 0));
    _ = qjs.JS_SetPropertyStr(ctx, loc, "assign", qjs.JS_NewCFunction(ctx, &windowLocationAssign, "assign", 1));
    _ = qjs.JS_SetPropertyStr(ctx, loc, "replace", qjs.JS_NewCFunction(ctx, &windowLocationAssign, "replace", 1));
    _ = qjs.JS_SetPropertyStr(ctx, loc, "toString", qjs.JS_NewCFunction(ctx, &windowLocationToString, "toString", 0));

    return loc;
}

fn jsGetScrollX(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewFloat64(c, scroll_x);
}

fn jsGetScrollY(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewFloat64(c, scroll_y);
}

// ── window.scrollTo / window.scrollBy ───────────────────────────────

fn windowScrollTo(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    // scrollTo(x, y) or scrollTo({top, left})
    if (argc >= 2) {
        var x_val: f64 = 0;
        var y_val: f64 = 0;
        _ = qjs.JS_ToFloat64(c, &x_val, args[0]);
        _ = qjs.JS_ToFloat64(c, &y_val, args[1]);
        pending_scroll_x = @floatCast(x_val);
        pending_scroll_y = @floatCast(y_val);
    } else {
        // Options object: {top, left, behavior}
        const opts = args[0];
        const top_val = qjs.JS_GetPropertyStr(c, opts, "top");
        const left_val = qjs.JS_GetPropertyStr(c, opts, "left");
        defer qjs.JS_FreeValue(c, top_val);
        defer qjs.JS_FreeValue(c, left_val);
        if (!quickjs.JS_IsUndefined(top_val)) {
            var y_val: f64 = 0;
            _ = qjs.JS_ToFloat64(c, &y_val, top_val);
            pending_scroll_y = @floatCast(y_val);
        }
        if (!quickjs.JS_IsUndefined(left_val)) {
            var x_val: f64 = 0;
            _ = qjs.JS_ToFloat64(c, &x_val, left_val);
            pending_scroll_x = @floatCast(x_val);
        }
    }
    return quickjs.JS_UNDEFINED();
}

fn windowScrollBy(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    if (argc >= 2) {
        var dx: f64 = 0;
        var dy: f64 = 0;
        _ = qjs.JS_ToFloat64(c, &dx, args[0]);
        _ = qjs.JS_ToFloat64(c, &dy, args[1]);
        pending_scroll_x = scroll_x + @as(f32, @floatCast(dx));
        pending_scroll_y = scroll_y + @as(f32, @floatCast(dy));
    } else {
        const opts = args[0];
        const top_val = qjs.JS_GetPropertyStr(c, opts, "top");
        const left_val = qjs.JS_GetPropertyStr(c, opts, "left");
        defer qjs.JS_FreeValue(c, top_val);
        defer qjs.JS_FreeValue(c, left_val);
        if (!quickjs.JS_IsUndefined(top_val)) {
            var dy: f64 = 0;
            _ = qjs.JS_ToFloat64(c, &dy, top_val);
            pending_scroll_y = scroll_y + @as(f32, @floatCast(dy));
        }
        if (!quickjs.JS_IsUndefined(left_val)) {
            var dx: f64 = 0;
            _ = qjs.JS_ToFloat64(c, &dx, left_val);
            pending_scroll_x = scroll_x + @as(f32, @floatCast(dx));
        }
    }
    return quickjs.JS_UNDEFINED();
}

fn windowGetInnerWidth(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewInt32(c, 800); // Default; could be made configurable
}

fn windowGetInnerHeight(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewInt32(c, 600); // Default; could be made configurable
}

// ── innerText (getter/setter) ───────────────────────────────────────

fn elementGetInnerText(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    // Simplified: return same as textContent (full CSS-aware version is too complex)
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    var len: usize = 0;
    const ptr = lxb_dom_node_text_content(node, &len);
    if (ptr == null or len == 0) return qjs.JS_NewStringLen(c, "", 0);
    return qjs.JS_NewStringLen(c, ptr.?, len);
}

fn elementSetInnerText(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    // Same as textContent setter: replace all children with a text node
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, s.ptr);
    _ = lxb_dom_node_text_content_set(node, s.ptr, s.len);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

// ── Element navigation properties ───────────────────────────────────

fn elementGetFirstElementChild(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        if (ch.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) return wrapNode(c, ch);
        child = ch.next;
    }
    return quickjs.JS_NULL();
}

fn elementGetLastElementChild(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    var child: ?*lxb.lxb_dom_node_t = lxb_dom_node_last_child_noi(node);
    while (child) |ch| {
        if (ch.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) return wrapNode(c, ch);
        child = lxb_dom_node_prev_noi(ch);
    }
    return quickjs.JS_NULL();
}

fn elementGetNextElementSibling(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    var sib: ?*lxb.lxb_dom_node_t = node.next;
    while (sib) |s| {
        if (s.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) return wrapNode(c, s);
        sib = s.next;
    }
    return quickjs.JS_NULL();
}

fn elementGetPreviousElementSibling(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    var sib: ?*lxb.lxb_dom_node_t = lxb_dom_node_prev_noi(node);
    while (sib) |s| {
        if (s.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) return wrapNode(c, s);
        sib = lxb_dom_node_prev_noi(s);
    }
    return quickjs.JS_NULL();
}

fn elementGetChildElementCount(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return qjs.JS_NewInt32(c, 0);
    var count: i32 = 0;
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        if (ch.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) count += 1;
        child = ch.next;
    }
    return qjs.JS_NewInt32(c, count);
}

/// Format a px value as "Npx" string.
/// CSS Values 4 §10.11: NaN → 0px, ±Infinity → ±MAX_LENGTH px.
const MAX_CSS_LENGTH: f32 = 33554432.0; // 2^25, implementation-defined max CSS length

// ── Registration ────────────────────────────────────────────────────

/// Register DOM API classes and the `document` global.
/// Must be called after page parse and before script execution.
/// Register Element and Text classes on the Runtime. Call ONCE per Runtime.
/// Must be called before registerDomApis.
pub fn registerDomClasses(rt: *qjs.JSRuntime) void {
    if (element_class_id != 0) return; // Already registered

    _ = qjs.JS_NewClassID(rt, &element_class_id);
    const elem_class_def = qjs.JSClassDef{
        .class_name = "Element",
        .finalizer = null,
        .gc_mark = null,
        .call = null,
        .exotic = null,
    };
    _ = qjs.JS_NewClass(rt, element_class_id, &elem_class_def);

    _ = qjs.JS_NewClassID(rt, &text_class_id);
    const text_class_def = qjs.JSClassDef{
        .class_name = "Text",
        .finalizer = null,
        .gc_mark = null,
        .call = null,
        .exotic = null,
    };
    _ = qjs.JS_NewClass(rt, text_class_id, &text_class_def);
}

/// Register DOM APIs on a JSContext. Can be called multiple times (once per iframe).
/// Requires registerDomClasses(rt) to have been called first.
pub fn registerDomApis(rt: *qjs.JSRuntime, ctx: *qjs.JSContext, document_ptr: *anyopaque) void {
    // Ensure classes are registered (idempotent)
    registerDomClasses(rt);

    g_document = document_ptr;
    g_top_frame.document = document_ptr;
    dom_dirty = false;

    // ── DOM Prototype Chain ──────────────────────────────────────────
    // EventTarget.prototype → Node.prototype → Element.prototype → HTMLElement.prototype
    // This mirrors the browser's prototype chain so instanceof checks work.

    // ── EventTarget.prototype ──────────────────────────────────────
    const event_target_proto = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPropertyStr(ctx, event_target_proto, "addEventListener", qjs.JS_NewCFunction(ctx, &events.jsAddEventListener, "addEventListener", 2));
    _ = qjs.JS_SetPropertyStr(ctx, event_target_proto, "removeEventListener", qjs.JS_NewCFunction(ctx, &events.jsRemoveEventListener, "removeEventListener", 2));

    // ── Node.prototype (inherits EventTarget.prototype) ────────────
    const node_proto = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPrototype(ctx, node_proto, event_target_proto);

    // Node methods
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "appendChild", qjs.JS_NewCFunction(ctx, &dom_node.elementAppendChild, "appendChild", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "removeChild", qjs.JS_NewCFunction(ctx, &dom_node.elementRemoveChild, "removeChild", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "insertBefore", qjs.JS_NewCFunction(ctx, &dom_node.elementInsertBefore, "insertBefore", 2));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "contains", qjs.JS_NewCFunction(ctx, &dom_node.elementContains, "contains", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "cloneNode", qjs.JS_NewCFunction(ctx, &dom_node.elementCloneNode, "cloneNode", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "replaceWith", qjs.JS_NewCFunction(ctx, &dom_node.elementReplaceWith, "replaceWith", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "replaceChild", qjs.JS_NewCFunction(ctx, &dom_node.elementReplaceChild, "replaceChild", 2));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "before", qjs.JS_NewCFunction(ctx, &dom_node.elementBefore, "before", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "after", qjs.JS_NewCFunction(ctx, &dom_node.elementAfter, "after", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "remove", qjs.JS_NewCFunction(ctx, &dom_node.elementRemove, "remove", 0));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "append", qjs.JS_NewCFunction(ctx, &elementAppend, "append", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "prepend", qjs.JS_NewCFunction(ctx, &elementPrepend, "prepend", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "isEqualNode", qjs.JS_NewCFunction(ctx, &dom_node.nodeIsEqualNode, "isEqualNode", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "normalize", qjs.JS_NewCFunction(ctx, &dom_node.nodeNormalize, "normalize", 0));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "compareDocumentPosition", qjs.JS_NewCFunction(ctx, &dom_node.nodeCompareDocumentPosition, "compareDocumentPosition", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "getRootNode", qjs.JS_NewCFunction(ctx, &dom_node.nodeGetRootNode, "getRootNode", 0));
    // Namespace methods + Node polyfills — set directly on node_proto (not via Node.prototype
    // which isn't defined yet at this point)
    {
        const g = qjs.JS_GetGlobalObject(ctx);
        _ = qjs.JS_SetPropertyStr(ctx, g, "__np", qjs.JS_DupValue(ctx, node_proto));
        qjs.JS_FreeValue(ctx, g);
        const ns_js =
            \\(function(){
            \\  var NP=globalThis.__np;
            \\  NP.lookupPrefix=function(ns){if(!ns)return null;var el=this.nodeType===1?this:this.parentElement;while(el){if(el.namespaceURI===ns&&el.prefix)return el.prefix;el=el.parentElement;}return null;};
            \\  NP.lookupNamespaceURI=function(prefix){var el=this.nodeType===1?this:this.parentElement;while(el){if(prefix===null||prefix===undefined){if(el.namespaceURI&&!el.prefix)return el.namespaceURI;}else if(el.prefix===prefix)return el.namespaceURI;el=el.parentElement;}if(!prefix)return 'http://www.w3.org/1999/xhtml';return null;};
            \\  NP.isDefaultNamespace=function(ns){return this.lookupNamespaceURI(null)===ns;};
            \\  NP.isSameNode=function(o){return this===o;};
            \\  NP.hasChildNodes=function(){return this.childNodes&&this.childNodes.length>0;};
            \\  delete globalThis.__np;
            \\  function _toNode(a){return(a&&typeof a==='object'&&a.nodeType)?a:document.createTextNode(String(a));}
            \\  NP.replaceChildren=function(){while(this.firstChild)this.removeChild(this.firstChild);for(var i=0;i<arguments.length;i++)this.appendChild(_toNode(arguments[i]));};
            \\  NP.prepend=NP.prepend||function(){var f=this.firstChild;for(var i=0;i<arguments.length;i++){var a=_toNode(arguments[i]);if(f)this.insertBefore(a,f);else this.appendChild(a);}};
            \\  NP.append=NP.append||function(){for(var i=0;i<arguments.length;i++)this.appendChild(_toNode(arguments[i]));};
            \\})()
        ;
        const r = qjs.JS_Eval(ctx, ns_js, ns_js.len, "<ns>", qjs.JS_EVAL_TYPE_GLOBAL);
        qjs.JS_FreeValue(ctx, r);
    }

    // Node constants
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "ELEMENT_NODE", qjs.JS_NewInt32(ctx, 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "ATTRIBUTE_NODE", qjs.JS_NewInt32(ctx, 2));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "TEXT_NODE", qjs.JS_NewInt32(ctx, 3));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "CDATA_SECTION_NODE", qjs.JS_NewInt32(ctx, 4));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "PROCESSING_INSTRUCTION_NODE", qjs.JS_NewInt32(ctx, 7));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "COMMENT_NODE", qjs.JS_NewInt32(ctx, 8));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "DOCUMENT_NODE", qjs.JS_NewInt32(ctx, 9));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "DOCUMENT_TYPE_NODE", qjs.JS_NewInt32(ctx, 10));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "DOCUMENT_FRAGMENT_NODE", qjs.JS_NewInt32(ctx, 11));
    // DOCUMENT_POSITION constants
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "DOCUMENT_POSITION_DISCONNECTED", qjs.JS_NewInt32(ctx, 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "DOCUMENT_POSITION_PRECEDING", qjs.JS_NewInt32(ctx, 2));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "DOCUMENT_POSITION_FOLLOWING", qjs.JS_NewInt32(ctx, 4));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "DOCUMENT_POSITION_CONTAINS", qjs.JS_NewInt32(ctx, 8));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "DOCUMENT_POSITION_CONTAINED_BY", qjs.JS_NewInt32(ctx, 16));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC", qjs.JS_NewInt32(ctx, 32));

    // Node getters
    {
        const textContentAtom = qjs.JS_NewAtom(ctx, "textContent");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, textContentAtom, qjs.JS_NewCFunction(ctx, &dom_node.elementGetTextContent, "get textContent", 0), qjs.JS_NewCFunction(ctx, &dom_node.elementSetTextContent, "set textContent", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, textContentAtom);
    }
    {
        const innerTextAtom = qjs.JS_NewAtom(ctx, "innerText");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, innerTextAtom, qjs.JS_NewCFunction(ctx, &elementGetInnerText, "get innerText", 0), qjs.JS_NewCFunction(ctx, &elementSetInnerText, "set innerText", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, innerTextAtom);
    }
    {
        const parentNodeAtom = qjs.JS_NewAtom(ctx, "parentNode");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, parentNodeAtom, qjs.JS_NewCFunction(ctx, &dom_node.elementGetParentNode, "get parentNode", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, parentNodeAtom);
    }
    {
        const parentElementAtom = qjs.JS_NewAtom(ctx, "parentElement");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, parentElementAtom, qjs.JS_NewCFunction(ctx, &dom_node.elementGetParentElement, "get parentElement", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, parentElementAtom);
    }
    {
        const ownerDocumentAtom = qjs.JS_NewAtom(ctx, "ownerDocument");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, ownerDocumentAtom, qjs.JS_NewCFunction(ctx, &dom_node.nodeGetOwnerDocument, "get ownerDocument", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, ownerDocumentAtom);
    }
    // nodeValue: null for Element/Document, overridden on text_proto for CharacterData
    {
        const nodeValueAtom = qjs.JS_NewAtom(ctx, "nodeValue");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, nodeValueAtom, qjs.JS_NewCFunction(ctx, &dom_text.nodeGetNodeValue, "get nodeValue", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, nodeValueAtom);
    }
    {
        const firstChildAtom = qjs.JS_NewAtom(ctx, "firstChild");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, firstChildAtom, qjs.JS_NewCFunction(ctx, &dom_node.elementGetFirstChild, "get firstChild", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, firstChildAtom);
    }
    {
        const lastChildAtom = qjs.JS_NewAtom(ctx, "lastChild");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, lastChildAtom, qjs.JS_NewCFunction(ctx, &dom_node.elementGetLastChild, "get lastChild", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, lastChildAtom);
    }
    {
        const nextSiblingAtom = qjs.JS_NewAtom(ctx, "nextSibling");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, nextSiblingAtom, qjs.JS_NewCFunction(ctx, &dom_node.elementGetNextSibling, "get nextSibling", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, nextSiblingAtom);
    }
    {
        const prevSiblingAtom = qjs.JS_NewAtom(ctx, "previousSibling");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, prevSiblingAtom, qjs.JS_NewCFunction(ctx, &dom_node.elementGetPreviousSibling, "get previousSibling", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, prevSiblingAtom);
    }
    {
        const childNodesAtom = qjs.JS_NewAtom(ctx, "childNodes");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, childNodesAtom, qjs.JS_NewCFunction(ctx, &dom_node.elementGetChildNodes, "get childNodes", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, childNodesAtom);
    }
    {
        const firstElementChildAtom = qjs.JS_NewAtom(ctx, "firstElementChild");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, firstElementChildAtom, qjs.JS_NewCFunction(ctx, &elementGetFirstElementChild, "get firstElementChild", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, firstElementChildAtom);
    }
    {
        const lastElementChildAtom = qjs.JS_NewAtom(ctx, "lastElementChild");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, lastElementChildAtom, qjs.JS_NewCFunction(ctx, &elementGetLastElementChild, "get lastElementChild", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, lastElementChildAtom);
    }
    {
        const nextElementSiblingAtom = qjs.JS_NewAtom(ctx, "nextElementSibling");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, nextElementSiblingAtom, qjs.JS_NewCFunction(ctx, &elementGetNextElementSibling, "get nextElementSibling", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, nextElementSiblingAtom);
    }
    {
        const previousElementSiblingAtom = qjs.JS_NewAtom(ctx, "previousElementSibling");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, previousElementSiblingAtom, qjs.JS_NewCFunction(ctx, &elementGetPreviousElementSibling, "get previousElementSibling", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, previousElementSiblingAtom);
    }
    {
        const childElementCountAtom = qjs.JS_NewAtom(ctx, "childElementCount");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, childElementCountAtom, qjs.JS_NewCFunction(ctx, &elementGetChildElementCount, "get childElementCount", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, childElementCountAtom);
    }
    {
        const isConnectedAtom = qjs.JS_NewAtom(ctx, "isConnected");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, isConnectedAtom, qjs.JS_NewCFunction(ctx, &dom_node.nodeGetIsConnected, "get isConnected", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, isConnectedAtom);
    }
    {
        const nodeTypeAtom = qjs.JS_NewAtom(ctx, "nodeType");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, nodeTypeAtom, qjs.JS_NewCFunction(ctx, &dom_node.elementGetNodeType, "get nodeType", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, nodeTypeAtom);
    }
    {
        const nodeNameAtom = qjs.JS_NewAtom(ctx, "nodeName");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, nodeNameAtom, qjs.JS_NewCFunction(ctx, &dom_node.elementGetNodeName, "get nodeName", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, nodeNameAtom);
    }

    // ── Element.prototype (inherits Node.prototype) ────────────────
    const elem_proto = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPrototype(ctx, elem_proto, node_proto);

    // Element methods
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "getAttribute", qjs.JS_NewCFunction(ctx, &dom_elem.elementGetAttribute, "getAttribute", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "setAttribute", qjs.JS_NewCFunction(ctx, &dom_elem.elementSetAttribute, "setAttribute", 2));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "removeAttribute", qjs.JS_NewCFunction(ctx, &dom_elem.elementRemoveAttribute, "removeAttribute", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "hasAttribute", qjs.JS_NewCFunction(ctx, &dom_elem.elementHasAttribute, "hasAttribute", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "getAttributeNS", qjs.JS_NewCFunction(ctx, &dom_elem.elementGetAttributeNS, "getAttributeNS", 2));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "setAttributeNS", qjs.JS_NewCFunction(ctx, &dom_elem.elementSetAttributeNS, "setAttributeNS", 3));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "hasAttributeNS", qjs.JS_NewCFunction(ctx, &dom_elem.elementHasAttributeNS, "hasAttributeNS", 2));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "removeAttributeNS", qjs.JS_NewCFunction(ctx, &dom_elem.elementRemoveAttributeNS, "removeAttributeNS", 2));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "matches", qjs.JS_NewCFunction(ctx, &dom_sel.elementMatches, "matches", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "closest", qjs.JS_NewCFunction(ctx, &dom_sel.elementClosest, "closest", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "getBoundingClientRect", qjs.JS_NewCFunction(ctx, &dom_elem.elementGetBoundingClientRect, "getBoundingClientRect", 0));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "querySelector", qjs.JS_NewCFunction(ctx, &dom_sel.elementQuerySelector, "querySelector", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "querySelectorAll", qjs.JS_NewCFunction(ctx, &dom_sel.elementQuerySelectorAll, "querySelectorAll", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "getElementsByClassName", qjs.JS_NewCFunction(ctx, &elementGetElementsByClassName, "getElementsByClassName", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "getElementsByTagName", qjs.JS_NewCFunction(ctx, &elementGetElementsByTagName, "getElementsByTagName", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "getElementsByTagNameNS", qjs.JS_NewCFunction(ctx, &elementGetElementsByTagName, "getElementsByTagNameNS", 2));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "toggleAttribute", qjs.JS_NewCFunction(ctx, &dom_elem.elementToggleAttribute, "toggleAttribute", 2));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "getAttributeNames", qjs.JS_NewCFunction(ctx, &dom_elem.elementGetAttributeNames, "getAttributeNames", 0));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "scrollIntoView", qjs.JS_NewCFunction(ctx, &dom_elem.elementScrollIntoView, "scrollIntoView", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "getContext", qjs.JS_NewCFunction(ctx, &dom_elem.elementGetContext, "getContext", 1));

    // attributes (NamedNodeMap) getter
    {
        const attributesAtom = qjs.JS_NewAtom(ctx, "attributes");
        _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, attributesAtom, qjs.JS_NewCFunction(ctx, &elementGetAttributes, "get attributes", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, attributesAtom);
    }

    // Element getters
    {
        const tagNameAtom = qjs.JS_NewAtom(ctx, "tagName");
        _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, tagNameAtom, qjs.JS_NewCFunction(ctx, &dom_node.elementGetTagName, "get tagName", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, tagNameAtom);
    }
    {
        // localName: lowercase tag name (HTML spec)
        const localNameAtom = qjs.JS_NewAtom(ctx, "localName");
        _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, localNameAtom, qjs.JS_NewCFunction(ctx, &dom_node.elementGetLocalName, "get localName", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, localNameAtom);
    }
    {
        // namespaceURI: always "http://www.w3.org/1999/xhtml" for HTML elements
        _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "namespaceURI", qjs.JS_NewString(ctx, "http://www.w3.org/1999/xhtml"));
        // prefix: null for HTML elements
        _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "prefix", quickjs.JS_NULL());
    }
    {
        const idAtom = qjs.JS_NewAtom(ctx, "id");
        _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, idAtom, qjs.JS_NewCFunction(ctx, &dom_elem.elementGetId, "get id", 0), qjs.JS_NewCFunction(ctx, &dom_elem.elementSetId, "set id", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, idAtom);
    }
    {
        const classNameAtom = qjs.JS_NewAtom(ctx, "className");
        _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, classNameAtom, qjs.JS_NewCFunction(ctx, &dom_elem.elementGetClassName, "get className", 0), qjs.JS_NewCFunction(ctx, &dom_elem.elementSetClassName, "set className", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, classNameAtom);
    }
    {
        const classListAtom = qjs.JS_NewAtom(ctx, "classList");
        _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, classListAtom, qjs.JS_NewCFunction(ctx, &dom_elem.elementGetClassList, "get classList", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, classListAtom);
    }
    {
        const innerHTMLAtom = qjs.JS_NewAtom(ctx, "innerHTML");
        _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, innerHTMLAtom, qjs.JS_NewCFunction(ctx, &serialize.elementGetInnerHTML, "get innerHTML", 0), qjs.JS_NewCFunction(ctx, &serialize.elementSetInnerHTML, "set innerHTML", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, innerHTMLAtom);
    }
    {
        const outerHTMLAtom = qjs.JS_NewAtom(ctx, "outerHTML");
        _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, outerHTMLAtom, qjs.JS_NewCFunction(ctx, &serialize.elementGetOuterHTML, "get outerHTML", 0), qjs.JS_NewCFunction(ctx, &serialize.elementSetOuterHTML, "set outerHTML", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, outerHTMLAtom);
    }
    {
        const childrenAtom = qjs.JS_NewAtom(ctx, "children");
        _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, childrenAtom, qjs.JS_NewCFunction(ctx, &dom_node.elementGetChildren, "get children", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, childrenAtom);
    }

    // insertAdjacentHTML
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "insertAdjacentHTML", qjs.JS_NewCFunction(ctx, &serialize.elementInsertAdjacentHTML, "insertAdjacentHTML", 2));
    // attachShadow stub — returns the element itself as a pseudo-shadow root
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "attachShadow", qjs.JS_NewCFunction(ctx, &dom_elem.elementAttachShadow, "attachShadow", 1));
    // shadowRoot default = null (not undefined — many libs check `el.shadowRoot &&`)
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "shadowRoot", quickjs.JS_NULL());
    // HTMLTemplateElement.content getter (returns DocumentFragment for <template> elements)
    {
        const contentAtom = qjs.JS_NewAtom(ctx, "content");
        _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, contentAtom, qjs.JS_NewCFunction(ctx, &dom_elem.templateGetContent, "get content", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, contentAtom);
    }
    // Popover API stubs (GitHub checks showPopover existence)
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "showPopover", qjs.JS_NewCFunction(ctx, &dom_doc.jsReturnNull, "showPopover", 0));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "hidePopover", qjs.JS_NewCFunction(ctx, &dom_doc.jsReturnNull, "hidePopover", 0));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "togglePopover", qjs.JS_NewCFunction(ctx, &dom_doc.jsReturnNull, "togglePopover", 0));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "insertAdjacentElement", qjs.JS_NewCFunction(ctx, &dom_elem.elementInsertAdjacentElement, "insertAdjacentElement", 2));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "insertAdjacentText", qjs.JS_NewCFunction(ctx, &dom_elem.elementInsertAdjacentText, "insertAdjacentText", 2));

    // ── HTMLElement.prototype (inherits Element.prototype) ──────────
    const html_element_proto = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPrototype(ctx, html_element_proto, elem_proto);

    // HTMLElement getters
    {
        const styleAtom = qjs.JS_NewAtom(ctx, "style");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, styleAtom, qjs.JS_NewCFunction(ctx, &elementGetStyle, "get style", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, styleAtom);
    }
    {
        const datasetAtom = qjs.JS_NewAtom(ctx, "dataset");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, datasetAtom, qjs.JS_NewCFunction(ctx, &dom_elem.elementGetDataset, "get dataset", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, datasetAtom);
    }
    {
        const offsetWidthAtom = qjs.JS_NewAtom(ctx, "offsetWidth");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, offsetWidthAtom, qjs.JS_NewCFunction(ctx, &dom_elem.elementGetOffsetWidth, "get offsetWidth", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, offsetWidthAtom);
    }
    {
        const offsetHeightAtom = qjs.JS_NewAtom(ctx, "offsetHeight");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, offsetHeightAtom, qjs.JS_NewCFunction(ctx, &dom_elem.elementGetOffsetHeight, "get offsetHeight", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, offsetHeightAtom);
    }
    {
        const offsetTopAtom = qjs.JS_NewAtom(ctx, "offsetTop");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, offsetTopAtom, qjs.JS_NewCFunction(ctx, &dom_elem.elementGetOffsetTop, "get offsetTop", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, offsetTopAtom);
    }
    {
        const offsetLeftAtom = qjs.JS_NewAtom(ctx, "offsetLeft");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, offsetLeftAtom, qjs.JS_NewCFunction(ctx, &dom_elem.elementGetOffsetLeft, "get offsetLeft", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, offsetLeftAtom);
    }
    // clientWidth/clientHeight (padding box) and clientTop/clientLeft (border widths)
    {
        const cwAtom = qjs.JS_NewAtom(ctx, "clientWidth");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, cwAtom, qjs.JS_NewCFunction(ctx, &dom_elem.elementGetClientWidth, "get clientWidth", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, cwAtom);
    }
    {
        const chAtom = qjs.JS_NewAtom(ctx, "clientHeight");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, chAtom, qjs.JS_NewCFunction(ctx, &dom_elem.elementGetClientHeight, "get clientHeight", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, chAtom);
    }
    {
        const ctAtom = qjs.JS_NewAtom(ctx, "clientTop");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, ctAtom, qjs.JS_NewCFunction(ctx, &dom_elem.elementGetClientTop, "get clientTop", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, ctAtom);
    }
    {
        const clAtom = qjs.JS_NewAtom(ctx, "clientLeft");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, clAtom, qjs.JS_NewCFunction(ctx, &dom_elem.elementGetClientLeft, "get clientLeft", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, clAtom);
    }
    // scrollWidth/scrollHeight (same as clientWidth/Height for now — no overflow tracking)
    {
        const swAtom = qjs.JS_NewAtom(ctx, "scrollWidth");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, swAtom, qjs.JS_NewCFunction(ctx, &dom_elem.elementGetClientWidth, "get scrollWidth", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, swAtom);
    }
    {
        const shAtom = qjs.JS_NewAtom(ctx, "scrollHeight");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, shAtom, qjs.JS_NewCFunction(ctx, &dom_elem.elementGetClientHeight, "get scrollHeight", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, shAtom);
    }
    {
        const scrollTopAtom = qjs.JS_NewAtom(ctx, "scrollTop");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, scrollTopAtom, qjs.JS_NewCFunction(ctx, &dom_elem.elementGetScrollTop, "get scrollTop", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, scrollTopAtom);
    }
    {
        const scrollLeftAtom = qjs.JS_NewAtom(ctx, "scrollLeft");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, scrollLeftAtom, qjs.JS_NewCFunction(ctx, &dom_elem.elementGetScrollLeft, "get scrollLeft", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, scrollLeftAtom);
    }
    {
        const hiddenAtom = qjs.JS_NewAtom(ctx, "hidden");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, hiddenAtom, qjs.JS_NewCFunction(ctx, &dom_elem.elementGetHidden, "get hidden", 0), qjs.JS_NewCFunction(ctx, &dom_elem.elementSetHidden, "set hidden", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, hiddenAtom);
    }

    // input.value / textarea.value / select.value
    {
        const valueAtom = qjs.JS_NewAtom(ctx, "value");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, valueAtom, qjs.JS_NewCFunction(ctx, &dom_elem.elementGetValue, "get value", 0), qjs.JS_NewCFunction(ctx, &dom_elem.elementSetValue, "set value", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, valueAtom);
    }

    // Set HTMLElement.prototype as the class prototype (elements get this as their __proto__)
    qjs.JS_SetClassProto(ctx, element_class_id, qjs.JS_DupValue(ctx, html_element_proto));

    // ── Expose constructors as globals for instanceof ──────────────
    const global = qjs.JS_GetGlobalObject(ctx);

    const event_target_ctor = qjs.JS_NewCFunction2(ctx, &dom_doc.jsNoOpConstructor, "EventTarget", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, event_target_ctor, "prototype", qjs.JS_DupValue(ctx, event_target_proto));
    _ = qjs.JS_SetPropertyStr(ctx, global, "EventTarget", event_target_ctor);

    const node_ctor = qjs.JS_NewCFunction2(ctx, &dom_doc.jsNoOpConstructor, "Node", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "prototype", qjs.JS_DupValue(ctx, node_proto));
    // Node constants on the constructor too
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "ELEMENT_NODE", qjs.JS_NewInt32(ctx, 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "ATTRIBUTE_NODE", qjs.JS_NewInt32(ctx, 2));
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "TEXT_NODE", qjs.JS_NewInt32(ctx, 3));
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "CDATA_SECTION_NODE", qjs.JS_NewInt32(ctx, 4));
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "PROCESSING_INSTRUCTION_NODE", qjs.JS_NewInt32(ctx, 7));
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "COMMENT_NODE", qjs.JS_NewInt32(ctx, 8));
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "DOCUMENT_NODE", qjs.JS_NewInt32(ctx, 9));
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "DOCUMENT_TYPE_NODE", qjs.JS_NewInt32(ctx, 10));
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "DOCUMENT_FRAGMENT_NODE", qjs.JS_NewInt32(ctx, 11));
    // DOCUMENT_POSITION constants on constructor (for Node.DOCUMENT_POSITION_*)
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "DOCUMENT_POSITION_DISCONNECTED", qjs.JS_NewInt32(ctx, 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "DOCUMENT_POSITION_PRECEDING", qjs.JS_NewInt32(ctx, 2));
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "DOCUMENT_POSITION_FOLLOWING", qjs.JS_NewInt32(ctx, 4));
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "DOCUMENT_POSITION_CONTAINS", qjs.JS_NewInt32(ctx, 8));
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "DOCUMENT_POSITION_CONTAINED_BY", qjs.JS_NewInt32(ctx, 16));
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC", qjs.JS_NewInt32(ctx, 32));
    _ = qjs.JS_SetPropertyStr(ctx, global, "Node", node_ctor);

    const element_ctor = qjs.JS_NewCFunction2(ctx, &dom_doc.jsNoOpConstructor, "Element", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, element_ctor, "prototype", qjs.JS_DupValue(ctx, elem_proto));
    _ = qjs.JS_SetPropertyStr(ctx, global, "Element", element_ctor);

    const html_element_ctor = qjs.JS_NewCFunction2(ctx, &dom_doc.jsNoOpConstructor, "HTMLElement", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, html_element_ctor, "prototype", qjs.JS_DupValue(ctx, html_element_proto));
    _ = qjs.JS_SetPropertyStr(ctx, global, "HTMLElement", html_element_ctor);

    // HTML element subclass constructors (for instanceof checks)
    const html_subclasses = [_][]const u8{
        "HTMLDivElement",       "HTMLSpanElement",      "HTMLParagraphElement",
        "HTMLImageElement",     "HTMLAnchorElement",    "HTMLFormElement",
        "HTMLInputElement",     "HTMLTextAreaElement",  "HTMLSelectElement",
        "HTMLButtonElement",    "HTMLTableElement",     "HTMLTableRowElement",
        "HTMLTableCellElement", "HTMLLIElement",        "HTMLUListElement",
        "HTMLOListElement",     "HTMLHeadingElement",   "HTMLPreElement",
        "HTMLCanvasElement",    "HTMLVideoElement",     "HTMLAudioElement",
        "HTMLIFrameElement",    "HTMLLabelElement",     "HTMLScriptElement",
        "HTMLStyleElement",     "HTMLLinkElement",      "HTMLMetaElement",
        "HTMLBRElement",        "HTMLHRElement",        "HTMLBodyElement",
        "HTMLHeadElement",      "HTMLHtmlElement",      "HTMLOptionElement",
        "HTMLTemplateElement",  "HTMLDialogElement",    "HTMLDetailsElement",
        "HTMLSummaryElement",   "HTMLFieldSetElement",  "HTMLLegendElement",
        "HTMLTitleElement",     "HTMLBaseElement",      "HTMLAreaElement",
        "HTMLDataElement",      "HTMLTimeElement",      "HTMLOutputElement",
        "HTMLProgressElement",  "HTMLMeterElement",     "HTMLDataListElement",
        "HTMLOptGroupElement",  "HTMLObjectElement",    "HTMLEmbedElement",
        "HTMLSourceElement",    "HTMLTrackElement",     "HTMLMapElement",
        "HTMLTableSectionElement", "HTMLTableColElement", "HTMLTableCaptionElement",
        "HTMLQuoteElement",     "HTMLModElement",       "HTMLPictureElement",
        "HTMLSlotElement",      "HTMLMenuElement",      "HTMLUnknownElement",
        "HTMLDirectoryElement", "HTMLDListElement",     "HTMLFontElement",
        "HTMLFrameElement",     "HTMLFrameSetElement",  "HTMLMarqueeElement",
        "HTMLTableHeaderCellElement", "HTMLTableDataCellElement",
        "HTMLParamElement",
    };
    for (html_subclasses) |name| {
        const ctor = qjs.JS_NewCFunction2(ctx, &dom_doc.jsNoOpConstructor, name.ptr, 0, qjs.JS_CFUNC_constructor, 0);
        _ = qjs.JS_SetPropertyStr(ctx, ctor, "prototype", qjs.JS_DupValue(ctx, html_element_proto));
        _ = qjs.JS_SetPropertyStr(ctx, global, name.ptr, ctor);
    }

    // DOM interface constructors (for instanceof checks in frameworks)
    const window_ctor = qjs.JS_NewCFunction2(ctx, &dom_doc.jsNoOpConstructor, "Window", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, global, "Window", window_ctor);

    const document_ctor = qjs.JS_NewCFunction2(ctx, &dom_doc.jsNoOpConstructor, "Document", 0, qjs.JS_CFUNC_constructor, 0);
    const doc_proto = qjs.JS_NewObject(ctx);
    // Document.prototype needs DOM query methods (popover polyfill monkey-patches these)
    _ = qjs.JS_SetPropertyStr(ctx, doc_proto, "querySelector", qjs.JS_NewCFunction(ctx, &dom_sel.documentQuerySelector, "querySelector", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_proto, "querySelectorAll", qjs.JS_NewCFunction(ctx, &dom_sel.documentQuerySelectorAll, "querySelectorAll", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_proto, "getElementById", qjs.JS_NewCFunction(ctx, &dom_doc.documentGetElementById, "getElementById", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_proto, "getElementsByClassName", qjs.JS_NewCFunction(ctx, &dom_doc.documentGetElementsByClassName, "getElementsByClassName", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_proto, "getElementsByTagName", qjs.JS_NewCFunction(ctx, &dom_doc.documentGetElementsByTagName, "getElementsByTagName", 1));
    _ = qjs.JS_SetPropertyStr(ctx, document_ctor, "prototype", doc_proto);
    _ = qjs.JS_SetPropertyStr(ctx, global, "Document", document_ctor);

    const doc_frag_ctor = qjs.JS_NewCFunction2(ctx, &dom_doc.jsNoOpConstructor, "DocumentFragment", 0, qjs.JS_CFUNC_constructor, 0);
    {
        const dfp = qjs.JS_NewObject(ctx);
        _ = qjs.JS_SetPropertyStr(ctx, dfp, "querySelector", qjs.JS_NewCFunction(ctx, &dom_sel.elementQuerySelector, "querySelector", 1));
        _ = qjs.JS_SetPropertyStr(ctx, dfp, "querySelectorAll", qjs.JS_NewCFunction(ctx, &dom_sel.elementQuerySelectorAll, "querySelectorAll", 1));
        _ = qjs.JS_SetPropertyStr(ctx, doc_frag_ctor, "prototype", dfp);
    }
    _ = qjs.JS_SetPropertyStr(ctx, global, "DocumentFragment", doc_frag_ctor);

    const nodelist_ctor = qjs.JS_NewCFunction2(ctx, &dom_doc.jsNoOpConstructor, "NodeList", 0, qjs.JS_CFUNC_constructor, 0);
    {
        const nlp_js =
            \\(function(){
            \\  var p={};
            \\  p.item=function(i){return i>=0&&i<this.length?this[i]:null;};
            \\  p.forEach=function(cb,t){for(var i=0;i<this.length;i++)cb.call(t,this[i],i,this);};
            \\  p.entries=function(){var a=[];for(var i=0;i<this.length;i++)a.push([i,this[i]]);return a[Symbol.iterator]();};
            \\  p.keys=function(){var a=[];for(var i=0;i<this.length;i++)a.push(i);return a[Symbol.iterator]();};
            \\  p.values=function(){var a=[];for(var i=0;i<this.length;i++)a.push(this[i]);return a[Symbol.iterator]();};
            \\  p[Symbol.iterator]=function(){var self=this,i=0;return{next:function(){return i<self.length?{value:self[i++],done:false}:{done:true};}};};
            \\  return p;
            \\})()
        ;
        const nlp = qjs.JS_Eval(ctx, nlp_js, nlp_js.len, "<NodeList.p>", qjs.JS_EVAL_TYPE_GLOBAL);
        _ = qjs.JS_SetPropertyStr(ctx, nodelist_ctor, "prototype", nlp);
    }
    _ = qjs.JS_SetPropertyStr(ctx, global, "NodeList", nodelist_ctor);

    const htmlcol_ctor = qjs.JS_NewCFunction2(ctx, &dom_doc.jsNoOpConstructor, "HTMLCollection", 0, qjs.JS_CFUNC_constructor, 0);
    {
        const hcp_js =
            \\(function(){
            \\  var p={};
            \\  p.item=function(i){return i>=0&&i<this.length?this[i]:null;};
            \\  p.namedItem=function(n){for(var i=0;i<this.length;i++){if(this[i].id===n||this[i].name===n)return this[i];}return null;};
            \\  p[Symbol.iterator]=function(){var self=this,i=0;return{next:function(){return i<self.length?{value:self[i++],done:false}:{done:true};}};};
            \\  return p;
            \\})()
        ;
        const hcp = qjs.JS_Eval(ctx, hcp_js, hcp_js.len, "<HTMLCollection.p>", qjs.JS_EVAL_TYPE_GLOBAL);
        _ = qjs.JS_SetPropertyStr(ctx, htmlcol_ctor, "prototype", hcp);
    }
    _ = qjs.JS_SetPropertyStr(ctx, global, "HTMLCollection", htmlcol_ctor);

    const range_ctor = qjs.JS_NewCFunction2(ctx, &dom_doc.jsNoOpConstructor, "Range", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, global, "Range", range_ctor);

    // DocumentType constructor
    const doctype_ctor = qjs.JS_NewCFunction2(ctx, &dom_doc.jsNoOpConstructor, "DocumentType", 0, qjs.JS_CFUNC_constructor, 0);
    // DocumentType.prototype inherits Node.prototype
    {
        const dtp = qjs.JS_NewObject(ctx);
        _ = qjs.JS_SetPrototype(ctx, dtp, qjs.JS_GetClassProto(ctx, @import("dom_api.zig").element_class_id)); // Node proto via element class
        _ = qjs.JS_SetPropertyStr(ctx, doctype_ctor, "prototype", dtp);
    }
    _ = qjs.JS_SetPropertyStr(ctx, global, "DocumentType", doctype_ctor);

    // DocumentFragment constructor
    const docfrag_ctor = qjs.JS_NewCFunction2(ctx, &dom_doc.jsNoOpConstructor, "DocumentFragment", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, global, "DocumentFragment", docfrag_ctor);

    const shadow_root_ctor = qjs.JS_NewCFunction2(ctx, &dom_doc.jsNoOpConstructor, "ShadowRoot", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, global, "ShadowRoot", shadow_root_ctor);

    // window.top / window.parent / window.self / window.frames
    _ = qjs.JS_SetPropertyStr(ctx, global, "top", qjs.JS_DupValue(ctx, global));
    _ = qjs.JS_SetPropertyStr(ctx, global, "parent", qjs.JS_DupValue(ctx, global));
    _ = qjs.JS_SetPropertyStr(ctx, global, "frames", qjs.JS_DupValue(ctx, global));
    _ = qjs.JS_SetPropertyStr(ctx, global, "frameElement", quickjs.JS_NULL());
    _ = qjs.JS_SetPropertyStr(ctx, global, "length", qjs.JS_NewInt32(ctx, 0)); // frames.length

    // Reflected HTML attributes (src, href, etc.) as property getters/setters
    {
        const reflected_js =
            \\(function(){
            \\  var EP=Element.prototype;
            \\  ['src','href','action','type','name','alt','title','rel','target','placeholder','method','enctype','lang','for'].forEach(function(a){
            \\    if(!(a in EP)){Object.defineProperty(EP,a,{get:function(){return this.getAttribute(a)||'';},set:function(v){this.setAttribute(a,v);},configurable:true});}
            \\  });
            \\  ['disabled','checked','selected','autofocus'].forEach(function(a){
            \\    if(!(a in EP)){Object.defineProperty(EP,a,{get:function(){return this.hasAttribute(a);},set:function(v){if(v)this.setAttribute(a,'');else this.removeAttribute(a);},configurable:true});}
            \\  });
            \\  Object.defineProperty(EP,'tabIndex',{get:function(){var v=this.getAttribute('tabindex');return v!==null?parseInt(v,10)||0:-1;},set:function(v){this.setAttribute('tabindex',String(v));},configurable:true});
            \\  Object.defineProperty(EP,'id',{get:function(){return this.getAttribute('id')||'';},set:function(v){this.setAttribute('id',v);},configurable:true});
            \\  Object.defineProperty(EP,'translate',{get:function(){var v=this.getAttribute('translate');if(v==='yes'||v==='')return true;if(v==='no')return false;var p=this.parentElement;return p?p.translate:true;},set:function(v){this.setAttribute('translate',v?'yes':'no');},configurable:true});
            \\  Object.defineProperty(EP,'draggable',{get:function(){var v=this.getAttribute('draggable');return v==='true';},set:function(v){this.setAttribute('draggable',v?'true':'false');},configurable:true});
            \\  Object.defineProperty(EP,'spellcheck',{get:function(){var v=this.getAttribute('spellcheck');return v!=='false';},set:function(v){this.setAttribute('spellcheck',v?'true':'false');},configurable:true});
            \\  Object.defineProperty(EP,'contentEditable',{get:function(){return this.getAttribute('contenteditable')||'inherit';},set:function(v){this.setAttribute('contenteditable',v);},configurable:true});
            \\  Object.defineProperty(EP,'isContentEditable',{get:function(){var v=this.getAttribute('contenteditable');return v==='true'||v==='';},configurable:true});
            \\  Object.defineProperty(EP,'slot',{get:function(){return this.getAttribute('slot')||'';},set:function(v){this.setAttribute('slot',v);},configurable:true});
            \\  Object.defineProperty(EP,'accessKey',{get:function(){return this.getAttribute('accesskey')||'';},set:function(v){this.setAttribute('accesskey',v);},configurable:true});
            \\  Object.defineProperty(EP,'dir',{get:function(){var v=this.getAttribute('dir');if(v===null)return'';v=v.toLowerCase();if(v==='ltr'||v==='rtl'||v==='auto')return v;return'';},set:function(v){this.setAttribute('dir',v);},configurable:true,enumerable:true});
            \\  EP.getAttributeNode=function(n){if(!this.hasAttribute(n))return null;return{nodeType:2,name:n,localName:n.toLowerCase(),value:this.getAttribute(n),namespaceURI:null,prefix:null,specified:true,ownerElement:this,get nodeValue(){return this.value;},set nodeValue(v){this.value=v;this.ownerElement.setAttribute(this.name,v);}};};
            \\  EP.getAttributeNodeNS=function(ns,ln){return this.getAttributeNode(ln);};
            \\  EP.setAttributeNode=function(attr){var old=this.getAttributeNode(attr.name);this.setAttribute(attr.name,attr.value);attr.ownerElement=this;return old;};
            \\  EP.setAttributeNodeNS=EP.setAttributeNode;
            \\  EP.removeAttributeNode=function(attr){if(!this.hasAttribute(attr.name))throw new DOMException('','NotFoundError');this.removeAttribute(attr.name);attr.ownerElement=null;return attr;};
            \\})();
        ;
        const r = qjs.JS_Eval(ctx, reflected_js, reflected_js.len, "<reflected-attrs>", qjs.JS_EVAL_TYPE_GLOBAL);
        qjs.JS_FreeValue(ctx, r);
    }

    // GlobalEventHandlers + WindowEventHandlers on HTMLElement.prototype
    // Per spec, all on* properties must be initialized to null (not undefined)
    {
        const evthandler_js =
            \\(function(){
            \\  var events=['abort','auxclick','beforeinput','blur','cancel','canplay','canplaythrough',
            \\    'change','click','close','contextmenu','copy','cuechange','cut','dblclick','drag','dragend',
            \\    'dragenter','dragleave','dragover','dragstart','drop','durationchange','emptied','ended',
            \\    'error','focus','focusin','focusout','formdata','gotpointercapture','input','invalid',
            \\    'keydown','keypress','keyup','load','loadeddata','loadedmetadata','loadstart',
            \\    'lostpointercapture','mousedown','mouseenter','mouseleave','mousemove','mouseout',
            \\    'mouseover','mouseup','paste','pause','play','playing','pointercancel','pointerdown',
            \\    'pointerenter','pointerleave','pointermove','pointerout','pointerover','pointerup',
            \\    'progress','ratechange','reset','resize','scroll','scrollend','securitypolicyviolation',
            \\    'seeked','seeking','select','selectionchange','selectstart','slotchange','stalled',
            \\    'submit','suspend','timeupdate','toggle','touchcancel','touchend','touchmove',
            \\    'touchstart','transitioncancel','transitionend','transitionrun','transitionstart',
            \\    'volumechange','waiting','webkitanimationend','webkitanimationiteration',
            \\    'webkitanimationstart','webkittransitionend','wheel'];
            \\  var EP=HTMLElement.prototype;
            \\  var _hm=new WeakMap();
            \\  events.forEach(function(e){var prop='on'+e;if(!(prop in EP)){
            \\    (function(ev,eid){Object.defineProperty(EP,ev,{get:function(){var m=_hm.get(this);return m?m[eid]||null:null;},set:function(v){var m=_hm.get(this);if(!m){m={};_hm.set(this,m);}m[eid]=(typeof v==='function')?v:null;},configurable:true,enumerable:true});})(prop,e);
            \\  }});
            \\})()
        ;
        const evt_r = qjs.JS_Eval(ctx, evthandler_js, evthandler_js.len, "<evthandlers>", qjs.JS_EVAL_TYPE_GLOBAL);
        qjs.JS_FreeValue(ctx, evt_r);
    }

    // HTML global attributes reflected as IDL properties on HTMLElement.prototype
    {
        const html_reflect_js =
            \\(function(){
            \\  var EP=HTMLElement.prototype;
            \\  function reflectStr(prop,attr){if(!(prop in EP))Object.defineProperty(EP,prop,{get:function(){return this.getAttribute(attr)||'';},set:function(v){this.setAttribute(attr,''+v);},configurable:true,enumerable:true});}
            \\  function reflectNullStr(prop,attr){if(!(prop in EP))Object.defineProperty(EP,prop,{get:function(){return this.getAttribute(attr);},set:function(v){if(v===null)this.removeAttribute(attr);else this.setAttribute(attr,''+v);},configurable:true,enumerable:true});}
            \\  function reflectEnum(prop,attr,kws){Object.defineProperty(EP,prop,{get:function(){var v=this.getAttribute(attr);if(v===null)return'';v=v.toLowerCase();for(var i=0;i<kws.length;i++)if(kws[i]===v)return v;return'';},set:function(v){this.setAttribute(attr,''+v);},configurable:true,enumerable:true});}
            \\  reflectEnum('inputMode','inputmode',['none','text','tel','url','email','numeric','decimal','search']);
            \\  reflectEnum('enterKeyHint','enterkeyhint',['enter','done','go','next','previous','search','send']);
            \\  reflectStr('accessKey','accesskey');
            \\  reflectStr('autocapitalize','autocapitalize');
            \\  reflectStr('dir','dir');
            \\  reflectStr('lang','lang');
            \\  reflectStr('title','title');
            \\  reflectStr('innerText','innerText');
            \\  reflectStr('popover','popover');
            \\  reflectNullStr('nonce','nonce');
            \\  reflectNullStr('slot','slot');
            \\  if(!('contentEditable' in EP))Object.defineProperty(EP,'contentEditable',{get:function(){return this.getAttribute('contenteditable')||'inherit';},set:function(v){this.setAttribute('contenteditable',''+v);},configurable:true,enumerable:true});
            \\  if(!('translate' in EP))Object.defineProperty(EP,'translate',{get:function(){var v=this.getAttribute('translate');return v==='no'?false:true;},set:function(v){this.setAttribute('translate',v?'yes':'no');},configurable:true,enumerable:true});
            \\  if(!('draggable' in EP))Object.defineProperty(EP,'draggable',{get:function(){var v=this.getAttribute('draggable');return v==='true';},set:function(v){this.setAttribute('draggable',v?'true':'false');},configurable:true,enumerable:true});
            \\  if(!('spellcheck' in EP))Object.defineProperty(EP,'spellcheck',{get:function(){var v=this.getAttribute('spellcheck');return v!=='false';},set:function(v){this.setAttribute('spellcheck',v?'true':'false');},configurable:true,enumerable:true});
            \\  if(!('hidden' in EP))Object.defineProperty(EP,'hidden',{get:function(){return this.hasAttribute('hidden');},set:function(v){if(v)this.setAttribute('hidden','');else this.removeAttribute('hidden');},configurable:true,enumerable:true});
            \\  if(!('tabIndex' in EP))Object.defineProperty(EP,'tabIndex',{get:function(){var v=this.getAttribute('tabindex');return v!==null?parseInt(v,10)||0:-1;},set:function(v){this.setAttribute('tabindex',''+v);},configurable:true,enumerable:true});
            \\})()
        ;
        const hr = qjs.JS_Eval(ctx, html_reflect_js, html_reflect_js.len, "<htmlreflect>", qjs.JS_EVAL_TYPE_GLOBAL);
        qjs.JS_FreeValue(ctx, hr);
    }

    // Element-specific IDL attribute reflection
    {
        const elem_reflect_js =
            \\(function(){
            \\  function rs(C,prop,attr){if(!attr)attr=prop.toLowerCase();Object.defineProperty(C.prototype,prop,{get:function(){return this.getAttribute(attr)||'';},set:function(v){this.setAttribute(attr,''+v);},configurable:true,enumerable:true});}
            \\  function rb(C,prop,attr){if(!attr)attr=prop.toLowerCase();Object.defineProperty(C.prototype,prop,{get:function(){return this.hasAttribute(attr);},set:function(v){if(v)this.setAttribute(attr,'');else this.removeAttribute(attr);},configurable:true,enumerable:true});}
            \\  function rn(C,prop,attr){if(!attr)attr=prop.toLowerCase();Object.defineProperty(C.prototype,prop,{get:function(){return this.getAttribute(attr);},set:function(v){if(v===null)this.removeAttribute(attr);else this.setAttribute(attr,''+v);},configurable:true,enumerable:true});}
            \\  function ru(C,prop,attr){if(!attr)attr=prop.toLowerCase();Object.defineProperty(C.prototype,prop,{get:function(){return this.getAttribute(attr)||'';},set:function(v){this.setAttribute(attr,''+v);},configurable:true,enumerable:true});}
            \\  function rco(C,prop,attr){if(!attr)attr=prop.toLowerCase();Object.defineProperty(C.prototype,prop,{get:function(){var v=this.getAttribute(attr);if(v===null)return null;v=v.toLowerCase();if(v==='use-credentials')return'use-credentials';return'anonymous';},set:function(v){if(v===null)this.removeAttribute(attr);else this.setAttribute(attr,''+v);},configurable:true,enumerable:true});}
            \\  if(typeof HTMLScriptElement!=='undefined'){var S=HTMLScriptElement;ru(S,'src');rs(S,'type');rs(S,'charset');rs(S,'text');rs(S,'event');rs(S,'integrity');rs(S,'referrerPolicy','referrerpolicy');rs(S,'fetchPriority','fetchpriority');rb(S,'defer');rb(S,'noModule','nomodule');rb(S,'async');rco(S,'crossOrigin','crossorigin');rs(S,'htmlFor','for');}
            \\  if(typeof HTMLHtmlElement!=='undefined'){rs(HTMLHtmlElement,'version');}
            \\  if(typeof HTMLDialogElement!=='undefined'){rb(HTMLDialogElement,'open');}
            \\  if(typeof HTMLDetailsElement!=='undefined'){rb(HTMLDetailsElement,'open');}
            \\  if(typeof HTMLMenuElement!=='undefined'){rb(HTMLMenuElement,'compact');}
            \\  if(typeof HTMLModElement!=='undefined'){rs(HTMLModElement,'cite');rs(HTMLModElement,'dateTime','datetime');}
            \\  if(typeof HTMLQuoteElement!=='undefined'){rs(HTMLQuoteElement,'cite');}
            \\  if(typeof HTMLAnchorElement!=='undefined'){var A=HTMLAnchorElement;rs(A,'href');rs(A,'target');rs(A,'download');rs(A,'rel');rs(A,'hreflang');rs(A,'type');rs(A,'text');rs(A,'referrerPolicy','referrerpolicy');}
            \\  if(typeof HTMLImageElement!=='undefined'){var I=HTMLImageElement;ru(I,'src');rs(I,'alt');rs(I,'srcset');rs(I,'sizes');rs(I,'referrerPolicy','referrerpolicy');rs(I,'fetchPriority','fetchpriority');rb(I,'isMap','ismap');rs(I,'useMap','usemap');rco(I,'crossOrigin','crossorigin');rs(I,'decoding');rs(I,'loading');}
            \\  if(typeof HTMLLinkElement!=='undefined'){var L=HTMLLinkElement;ru(L,'href');rs(L,'rel');rs(L,'type');rs(L,'media');rs(L,'integrity');rco(L,'crossOrigin','crossorigin');rs(L,'referrerPolicy','referrerpolicy');rs(L,'fetchPriority','fetchpriority');rb(L,'disabled');}
            \\  if(typeof HTMLMetaElement!=='undefined'){var M=HTMLMetaElement;rs(M,'name');rs(M,'content');rs(M,'httpEquiv','http-equiv');rs(M,'media');}
            \\  if(typeof HTMLStyleElement!=='undefined'){rs(HTMLStyleElement,'media');rb(HTMLStyleElement,'disabled');}
            \\})()
        ;
        const er = qjs.JS_Eval(ctx, elem_reflect_js, elem_reflect_js.len, "<elemreflect>", qjs.JS_EVAL_TYPE_GLOBAL);
        qjs.JS_FreeValue(ctx, er);
    }

    // ARIA attribute reflection per ARIA in HTML spec (with enumerated support)
    {
        const aria_js =
            \\(function(){
            \\  var EP=Element.prototype;
            \\  var enumDefs={
            \\    ariaAtomic:{kw:['true','false'],nc:{'':'false'},iv:'false',dv:null},
            \\    ariaAutoComplete:{kw:['inline','list','both','none'],nc:{},iv:'none',dv:'none'},
            \\    ariaBusy:{kw:['true','false'],nc:{'':'false'},iv:'false',dv:'false'},
            \\    ariaChecked:{kw:['true','false','mixed'],nc:{'':null},iv:null,dv:null},
            \\    ariaCurrent:{kw:['page','step','location','date','time','true','false'],nc:{'':'false'},iv:'true',dv:'false'},
            \\    ariaDisabled:{kw:['true','false'],nc:{'':'false'},iv:'false',dv:'false'},
            \\    ariaExpanded:{kw:['true','false'],nc:{'':null},iv:null,dv:null},
            \\    ariaHasPopup:{kw:['true','false','menu','dialog','listbox','tree','grid'],nc:{},iv:'false',dv:null},
            \\    ariaHidden:{kw:['true','false'],nc:{'':'false'},iv:'false',dv:'false'},
            \\    ariaInvalid:{kw:['true','false','spelling','grammar'],nc:{'':'false'},iv:'true',dv:'false'},
            \\    ariaLive:{kw:['polite','assertive','off'],nc:{},iv:'off',dv:'off'},
            \\    ariaModal:{kw:['true','false'],nc:{'':'false'},iv:'false',dv:'false'},
            \\    ariaMultiLine:{kw:['true','false'],nc:{'':'false'},iv:'false',dv:'false'},
            \\    ariaMultiSelectable:{kw:['true','false'],nc:{'':'false'},iv:'false',dv:'false'},
            \\    ariaOrientation:{kw:['horizontal','vertical'],nc:{'':null},iv:null,dv:null},
            \\    ariaPressed:{kw:['true','false','mixed'],nc:{'':null},iv:null,dv:null},
            \\    ariaReadOnly:{kw:['true','false'],nc:{'':'false'},iv:'false',dv:'false'},
            \\    ariaRequired:{kw:['true','false'],nc:{'':'false'},iv:'false',dv:'false'},
            \\    ariaSelected:{kw:['true','false'],nc:{'':null},iv:null,dv:null},
            \\    ariaSort:{kw:['ascending','descending','other','none'],nc:{},iv:'none',dv:'none'}
            \\  };
            \\  var ariaAttrs={role:'role',ariaAtomic:'aria-atomic',ariaAutoComplete:'aria-autocomplete',
            \\    ariaBrailleLabel:'aria-braillelabel',ariaBrailleRoleDescription:'aria-brailleroledescription',
            \\    ariaBusy:'aria-busy',ariaChecked:'aria-checked',ariaColCount:'aria-colcount',
            \\    ariaColIndex:'aria-colindex',ariaColIndexText:'aria-colindextext',ariaColSpan:'aria-colspan',
            \\    ariaCurrent:'aria-current',ariaDescription:'aria-description',ariaDisabled:'aria-disabled',
            \\    ariaExpanded:'aria-expanded',ariaHasPopup:'aria-haspopup',ariaHidden:'aria-hidden',
            \\    ariaInvalid:'aria-invalid',ariaKeyShortcuts:'aria-keyshortcuts',ariaLabel:'aria-label',
            \\    ariaLevel:'aria-level',ariaLive:'aria-live',ariaModal:'aria-modal',ariaMultiLine:'aria-multiline',
            \\    ariaMultiSelectable:'aria-multiselectable',ariaOrientation:'aria-orientation',
            \\    ariaPlaceholder:'aria-placeholder',ariaPosInSet:'aria-posinset',ariaPressed:'aria-pressed',
            \\    ariaReadOnly:'aria-readonly',ariaRelevant:'aria-relevant',ariaRequired:'aria-required',
            \\    ariaRoleDescription:'aria-roledescription',ariaRowCount:'aria-rowcount',
            \\    ariaRowIndex:'aria-rowindex',ariaRowIndexText:'aria-rowindextext',ariaRowSpan:'aria-rowspan',
            \\    ariaSelected:'aria-selected',ariaSetSize:'aria-setsize',ariaSort:'aria-sort',
            \\    ariaValueMax:'aria-valuemax',ariaValueMin:'aria-valuemin',ariaValueNow:'aria-valuenow',
            \\    ariaValueText:'aria-valuetext'};
            \\  for(var prop in ariaAttrs){(function(p,a){
            \\    var ed=enumDefs[p];
            \\    if(ed){
            \\      Object.defineProperty(EP,p,{get:function(){
            \\        var v=this.getAttribute(a);
            \\        if(v===null)return ed.dv;
            \\        if(v in ed.nc)return ed.nc[v];
            \\        var lv=v.toLowerCase();
            \\        for(var i=0;i<ed.kw.length;i++){if(ed.kw[i]===lv)return lv;}
            \\        return ed.iv;
            \\      },set:function(v){if(v===null||v===undefined)this.removeAttribute(a);else this.setAttribute(a,''+v);},configurable:true,enumerable:true});
            \\    }else{
            \\      Object.defineProperty(EP,p,{get:function(){var v=this.getAttribute(a);return v;},set:function(v){if(v===null||v===undefined)this.removeAttribute(a);else this.setAttribute(a,''+v);},configurable:true,enumerable:true});
            \\    }
            \\  })(prop,ariaAttrs[prop]);}
            \\})()
        ;
        const aria_r = qjs.JS_Eval(ctx, aria_js, aria_js.len, "<aria>", qjs.JS_EVAL_TYPE_GLOBAL);
        qjs.JS_FreeValue(ctx, aria_r);
    }

    // Element @@unscopables per DOM spec
    {
        const unscopables_js =
            \\(function(){
            \\  Element.prototype[Symbol.unscopables]={before:true,after:true,replaceWith:true,remove:true,prepend:true,append:true,slot:true};
            \\})()
        ;
        const ur = qjs.JS_Eval(ctx, unscopables_js, unscopables_js.len, "<unscopables>", qjs.JS_EVAL_TYPE_GLOBAL);
        qjs.JS_FreeValue(ctx, ur);
    }

    // ── Text prototype (inherits Node.prototype) ─────────────────────
    // Text/Comment/PI nodes get CharacterData methods via this prototype.
    const text_proto = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPrototype(ctx, text_proto, node_proto);

    // CharacterData: data/nodeValue native getter + JS-wrapped setter (handles null→"" per DOM spec)
    // We expose native getter as __nativeGetData and native setter as __nativeSetData,
    // then wrap them in JS to handle type coercion.
    _ = qjs.JS_SetPropertyStr(ctx, text_proto, "__nativeGetData", qjs.JS_NewCFunction(ctx, &dom_text.textGetData, "__nativeGetData", 0));
    _ = qjs.JS_SetPropertyStr(ctx, text_proto, "__nativeSetData", qjs.JS_NewCFunction(ctx, &dom_text.textSetData, "__nativeSetData", 1));

    // CharacterData methods via JS — wraps native data access with proper coercion
    {
        _ = qjs.JS_SetPropertyStr(ctx, global, "__tp", qjs.JS_DupValue(ctx, text_proto));
        const cd_js =
            \\(function(P){
            \\var G=P.__nativeGetData,S=P.__nativeSetData;
            \\function sd(v){S.call(this,v===null?'':''+v);}
            \\Object.defineProperty(P,'data',{get:G,set:sd,configurable:true,enumerable:true});
            \\Object.defineProperty(P,'nodeValue',{get:G,set:sd,configurable:true,enumerable:true});
            \\Object.defineProperty(P,'length',{get:function(){return this.data.length;},configurable:true});
            \\Object.defineProperty(P,'wholeText',{get:function(){if(this.nodeType!==3)return this.data;var t='',n=this;while(n.previousSibling&&n.previousSibling.nodeType===3)n=n.previousSibling;while(n&&n.nodeType===3){t+=n.data;n=n.nextSibling;}return t;},configurable:true});
            \\P.appendData=function(d){if(arguments.length<1)throw new TypeError("Failed to execute 'appendData': 1 argument required");this.data+=''+d;};
            \\P.insertData=function(o,d){if(arguments.length<2)throw new TypeError("Failed to execute 'insertData': 2 arguments required");var s=this.data;o=o>>>0;if(o>s.length)throw new DOMException('The index is not in the allowed range.','IndexSizeError');this.data=s.slice(0,o)+d+s.slice(o);};
            \\P.deleteData=function(o,c){if(arguments.length<2)throw new TypeError("Failed to execute 'deleteData': 2 arguments required");var s=this.data;o=o>>>0;c=c>>>0;if(o>s.length)throw new DOMException('The index is not in the allowed range.','IndexSizeError');this.data=s.slice(0,o)+s.slice(o+c);};
            \\P.replaceData=function(o,c,d){if(arguments.length<3)throw new TypeError("Failed to execute 'replaceData': 3 arguments required");var s=this.data;o=o>>>0;c=c>>>0;if(o>s.length)throw new DOMException('The index is not in the allowed range.','IndexSizeError');this.data=s.slice(0,o)+d+s.slice(o+c);};
            \\P.substringData=function(o,c){if(arguments.length<2)throw new TypeError("Failed to execute 'substringData': 2 arguments required");var s=this.data;o=o>>>0;c=c>>>0;if(o>s.length)throw new DOMException('The index is not in the allowed range.','IndexSizeError');return s.slice(o,o+c);};
            \\delete P.__nativeGetData;delete P.__nativeSetData;
            \\function noChild(m){return function(){throw new DOMException("Failed to execute '"+m+"' on 'Node': This node type does not support this method.",'HierarchyRequestError');};}
            \\P.splitText=function(o){if(this.nodeType!==3)throw new DOMException("Not a Text node",'InvalidNodeTypeError');o=o>>>0;var s=this.data;if(o>s.length)throw new DOMException('The index is not in the allowed range.','IndexSizeError');var newData=s.slice(o);this.data=s.slice(0,o);var n=document.createTextNode(newData);if(this.parentNode)this.parentNode.insertBefore(n,this.nextSibling);return n;};
            \\P.appendChild=noChild('appendChild');P.insertBefore=noChild('insertBefore');
            \\P.removeChild=noChild('removeChild');P.replaceChild=noChild('replaceChild');
            \\P.replaceChildren=noChild('replaceChildren');P.prepend=noChild('prepend');P.append=noChild('append');
            \\})(__tp);delete __tp;
        ;
        const r = qjs.JS_Eval(ctx, cd_js, cd_js.len, "<chardata>", qjs.JS_EVAL_TYPE_GLOBAL);
        qjs.JS_FreeValue(ctx, r);
    }

    qjs.JS_SetClassProto(ctx, text_class_id, text_proto);

    // Text/CharacterData/Comment/PI constructors with prototype for instanceof
    {
        const tp = qjs.JS_GetClassProto(ctx, text_class_id);
        // Text constructor: new Text(data?) creates a real text node
        const text_ctor = qjs.JS_NewCFunction2(ctx, &dom_doc.jsTextConstructor, "Text", 0, qjs.JS_CFUNC_constructor, 0);
        _ = qjs.JS_SetPropertyStr(ctx, text_ctor, "prototype", qjs.JS_DupValue(ctx, tp));
        _ = qjs.JS_SetPropertyStr(ctx, global, "Text", text_ctor);
        const chardata_ctor = qjs.JS_NewCFunction2(ctx, &dom_doc.jsNoOpConstructor, "CharacterData", 0, qjs.JS_CFUNC_constructor, 0);
        _ = qjs.JS_SetPropertyStr(ctx, chardata_ctor, "prototype", qjs.JS_DupValue(ctx, tp));
        _ = qjs.JS_SetPropertyStr(ctx, global, "CharacterData", chardata_ctor);
        // Comment constructor: new Comment(data?) creates a real comment node
        const comment_ctor = qjs.JS_NewCFunction2(ctx, &dom_doc.jsCommentConstructor, "Comment", 0, qjs.JS_CFUNC_constructor, 0);
        _ = qjs.JS_SetPropertyStr(ctx, comment_ctor, "prototype", qjs.JS_DupValue(ctx, tp));
        _ = qjs.JS_SetPropertyStr(ctx, global, "Comment", comment_ctor);
        const pi_ctor = qjs.JS_NewCFunction2(ctx, &dom_doc.jsNoOpConstructor, "ProcessingInstruction", 0, qjs.JS_CFUNC_constructor, 0);
        _ = qjs.JS_SetPropertyStr(ctx, pi_ctor, "prototype", qjs.JS_DupValue(ctx, tp));
        _ = qjs.JS_SetPropertyStr(ctx, global, "ProcessingInstruction", pi_ctor);
        qjs.JS_FreeValue(ctx, tp);
    }

    // Free local proto references (class proto + constructors hold refs)
    qjs.JS_FreeValue(ctx, event_target_proto);
    qjs.JS_FreeValue(ctx, node_proto);
    qjs.JS_FreeValue(ctx, elem_proto);
    qjs.JS_FreeValue(ctx, html_element_proto);

    // Build document global
    const doc_obj = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "getElementById", qjs.JS_NewCFunction(ctx, &dom_doc.documentGetElementById, "getElementById", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "querySelector", qjs.JS_NewCFunction(ctx, &dom_sel.documentQuerySelector, "querySelector", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "querySelectorAll", qjs.JS_NewCFunction(ctx, &dom_sel.documentQuerySelectorAll, "querySelectorAll", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createElement", qjs.JS_NewCFunction(ctx, &dom_doc.documentCreateElement, "createElement", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createElementNS", qjs.JS_NewCFunction(ctx, &dom_doc.documentCreateElementNS, "createElementNS", 2));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createTextNode", qjs.JS_NewCFunction(ctx, &dom_doc.documentCreateTextNode, "createTextNode", 1));
    // createAttribute(localName) + createAttributeNS(namespace, qualifiedName)
    {
        const attr_js =
            \\(function(ns,qn){var a={nodeType:2,name:qn,value:'',namespaceURI:ns,prefix:null,localName:qn,specified:true,ownerElement:null,ownerDocument:document};
            \\var ci=qn.indexOf(':');if(ci>=0){a.prefix=qn.substring(0,ci);a.localName=qn.substring(ci+1);}
            \\a.isEqualNode=function(o){if(!o||o.nodeType!==2)return false;return this.namespaceURI===o.namespaceURI&&this.localName===o.localName&&this.value===o.value;};
            \\a.isSameNode=function(o){return this===o;};
            \\Object.defineProperty(a,'nodeValue',{get:function(){return this.value;},set:function(v){this.value=v;},configurable:true});
            \\Object.defineProperty(a,'textContent',{get:function(){return this.value;},set:function(v){this.value=v;},configurable:true});
            \\return a;})
        ;
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createAttributeNS", qjs.JS_Eval(ctx, attr_js, attr_js.len, "<attrNS>", qjs.JS_EVAL_TYPE_GLOBAL));
        const create_attr_js =
            \\(function(name){if(!name||name.length===0)throw new DOMException('The string did not match the expected pattern.','InvalidCharacterError');return document.createAttributeNS(null,name.toLowerCase());})
        ;
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createAttribute", qjs.JS_Eval(ctx, create_attr_js, create_attr_js.len, "<attr>", qjs.JS_EVAL_TYPE_GLOBAL));
    }
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createDocumentFragment", qjs.JS_NewCFunction(ctx, &dom_doc.documentCreateDocumentFragment, "createDocumentFragment", 0));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createEvent", qjs.JS_NewCFunction(ctx, &dom_doc.documentCreateEvent, "createEvent", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "write", qjs.JS_NewCFunction(ctx, &dom_doc.documentWrite, "write", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "writeln", qjs.JS_NewCFunction(ctx, &dom_doc.documentWrite, "writeln", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "getElementsByClassName", qjs.JS_NewCFunction(ctx, &dom_doc.documentGetElementsByClassName, "getElementsByClassName", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "getElementsByTagName", qjs.JS_NewCFunction(ctx, &dom_doc.documentGetElementsByTagName, "getElementsByTagName", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "getElementsByTagNameNS", qjs.JS_NewCFunction(ctx, &dom_doc.documentGetElementsByTagName, "getElementsByTagNameNS", 2));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "getElementsByName", qjs.JS_NewCFunction(ctx, &dom_doc.documentGetElementsByName, "getElementsByName", 1));

    // document.adoptNode / importNode (stub — return the node as-is)
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "adoptNode", qjs.JS_NewCFunction(ctx, &dom_doc.documentAdoptNode, "adoptNode", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "contains", qjs.JS_NewCFunction(ctx, &dom_node.elementContains, "contains", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "compareDocumentPosition", qjs.JS_NewCFunction(ctx, &dom_node.nodeCompareDocumentPosition, "compareDocumentPosition", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "hasChildNodes", qjs.JS_NewCFunction(ctx, &dom_doc.jsReturnTrue, "hasChildNodes", 0));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "normalize", qjs.JS_NewCFunction(ctx, &dom_node.nodeNormalize, "normalize", 0));
    // Document childNodes/firstChild/lastChild getters (native DOM tree)
    {
        const cn_atom = qjs.JS_NewAtom(ctx, "childNodes");
        _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, cn_atom, qjs.JS_NewCFunction(ctx, &dom_node.elementGetChildNodes, "get childNodes", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, cn_atom);
    }
    {
        const fc_atom = qjs.JS_NewAtom(ctx, "firstChild");
        _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, fc_atom, qjs.JS_NewCFunction(ctx, &dom_node.elementGetFirstChild, "get firstChild", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, fc_atom);
    }
    {
        const lc_atom = qjs.JS_NewAtom(ctx, "lastChild");
        _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, lc_atom, qjs.JS_NewCFunction(ctx, &dom_node.elementGetLastChild, "get lastChild", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, lc_atom);
    }
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "isEqualNode", qjs.JS_NewCFunction(ctx, &dom_node.nodeIsEqualNode, "isEqualNode", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "getRootNode", qjs.JS_NewCFunction(ctx, &dom_node.nodeGetRootNode, "getRootNode", 0));
    // document.isSameNode, lookupPrefix, lookupNamespaceURI, isDefaultNamespace
    {
        const doc_ns_js =
            \\(function(d){
            \\  d.isSameNode=function(o){return d===o;};
            \\  d.lookupPrefix=function(){return null;};
            \\  d.lookupNamespaceURI=function(p){if(!p)return 'http://www.w3.org/1999/xhtml';return null;};
            \\  d.isDefaultNamespace=function(ns){return ns==='http://www.w3.org/1999/xhtml';};
            \\})
        ;
        const doc_ns_fn = qjs.JS_Eval(ctx, doc_ns_js, doc_ns_js.len, "<doc-ns>", qjs.JS_EVAL_TYPE_GLOBAL);
        var doc_ns_args = [1]qjs.JSValue{qjs.JS_DupValue(ctx, doc_obj)};
        const doc_ns_r = qjs.JS_Call(ctx, doc_ns_fn, quickjs.JS_UNDEFINED(), 1, &doc_ns_args);
        qjs.JS_FreeValue(ctx, doc_ns_r);
        qjs.JS_FreeValue(ctx, doc_ns_args[0]);
        qjs.JS_FreeValue(ctx, doc_ns_fn);
    }
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "importNode", qjs.JS_NewCFunction(ctx, &dom_doc.documentImportNode, "importNode", 2));
    // document.createRange (stub)
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createRange", qjs.JS_NewCFunction(ctx, &dom_doc.documentCreateRange, "createRange", 0));
    // document.elementFromPoint(x, y) — stub returns body or documentElement
    {
        const efp_js = "(function(x,y){return document.body||document.documentElement||null;})";
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "elementFromPoint", qjs.JS_Eval(ctx, efp_js, efp_js.len, "<efp>", qjs.JS_EVAL_TYPE_GLOBAL));
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "elementsFromPoint", qjs.JS_Eval(ctx,
            "(function(x,y){var e=document.elementFromPoint(x,y);return e?[e]:[];})",
            "(function(x,y){var e=document.elementFromPoint(x,y);return e?[e]:[];})".len,
            "<efps>", qjs.JS_EVAL_TYPE_GLOBAL));
    }
    // document.createTreeWalker
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createTreeWalker", qjs.JS_NewCFunction(ctx, &dom_doc.documentCreateTreeWalker, "createTreeWalker", 3));
    // document.createNodeIterator
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createNodeIterator", qjs.JS_NewCFunction(ctx, &dom_doc.documentCreateNodeIterator, "createNodeIterator", 3));

    // document.readyState (getter)
    const readyStateAtom = qjs.JS_NewAtom(ctx, "readyState");
    _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, readyStateAtom, qjs.JS_NewCFunction(ctx, &dom_doc.documentGetReadyState, "get readyState", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, readyStateAtom);

    // document.activeElement (getter)
    {
        const activeElementAtom = qjs.JS_NewAtom(ctx, "activeElement");
        _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, activeElementAtom, qjs.JS_NewCFunction(ctx, &dom_doc.documentGetActiveElement, "get activeElement", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, activeElementAtom);
    }

    // document.location (alias to window.location)
    {
        const loc = qjs.JS_GetPropertyStr(ctx, global, "location");
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "location", loc);
    }

    // document.body (getter)
    const bodyAtom = qjs.JS_NewAtom(ctx, "body");
    _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, bodyAtom, qjs.JS_NewCFunction(ctx, &dom_doc.documentGetBody, "get body", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, bodyAtom);

    // document.title (getter)
    const titleAtom = qjs.JS_NewAtom(ctx, "title");
    _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, titleAtom, qjs.JS_NewCFunction(ctx, &dom_doc.documentGetTitle, "get title", 0), qjs.JS_NewCFunction(ctx, &dom_doc.documentSetTitle, "set title", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, titleAtom);

    // document.documentElement (getter)
    const docElemAtom = qjs.JS_NewAtom(ctx, "documentElement");
    _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, docElemAtom, qjs.JS_NewCFunction(ctx, &dom_doc.documentGetDocumentElement, "get documentElement", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, docElemAtom);

    // document.currentScript (null when not in script execution)
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "currentScript", quickjs.JS_NULL());

    // document.head (getter)
    const headAtom = qjs.JS_NewAtom(ctx, "head");
    _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, headAtom, qjs.JS_NewCFunction(ctx, &dom_doc.documentGetHead, "get head", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, headAtom);

    // document.cookie (getter/setter)
    const cookieAtom = qjs.JS_NewAtom(ctx, "cookie");
    _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, cookieAtom, qjs.JS_NewCFunction(ctx, &dom_doc.documentGetCookie, "get cookie", 0), qjs.JS_NewCFunction(ctx, &dom_doc.documentSetCookie, "set cookie", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, cookieAtom);

    // document.URL / referrer / domain
    if (g_current_url) |url| {
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "URL", qjs.JS_NewStringLen(ctx, url.ptr, url.len));
        const domain = dom_doc.extractDomain(url) orelse "";
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "domain", qjs.JS_NewStringLen(ctx, domain.ptr, domain.len));
    } else {
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "URL", qjs.JS_NewString(ctx, ""));
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "domain", qjs.JS_NewString(ctx, ""));
    }
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "referrer", qjs.JS_NewString(ctx, ""));
    // document.documentURI (alias for document.URL)
    if (g_current_url) |url| {
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "documentURI", qjs.JS_NewStringLen(ctx, url.ptr, url.len));
    } else {
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "documentURI", qjs.JS_NewString(ctx, ""));
    }
    // document.hasFocus() — always returns true (single-window browser)
    {
        const hf_js = "(function(){return true;})";
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "hasFocus", qjs.JS_Eval(ctx, hf_js, hf_js.len, "<hasFocus>", qjs.JS_EVAL_TYPE_GLOBAL));
    }
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createComment", qjs.JS_NewCFunction(ctx, &dom_doc.documentCreateComment, "createComment", 1));

    // document.createCDATASection — HTML documents must throw NotSupportedError
    {
        const cdata_js = "(function(){throw new DOMException('This is an HTML document.','NotSupportedError');})";
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createCDATASection", qjs.JS_Eval(ctx, cdata_js, cdata_js.len, "<cdata>", qjs.JS_EVAL_TYPE_GLOBAL));
    }

    // document.createProcessingInstruction(target, data)
    {
        const pi_js =
            \\(function(target, data) {
            \\  if(!target||target.length===0)throw new DOMException('The string did not match the expected pattern.','InvalidCharacterError');
            \\  if(data&&data.indexOf('?>')>=0)throw new DOMException('The string did not match the expected pattern.','InvalidCharacterError');
            \\  var pi = {nodeType:7, nodeName:target, target:target, data:data||'',
            \\          textContent:data||'', nodeValue:data||'', childNodes:[],
            \\          parentNode:null, parentElement:null, ownerDocument:document,
            \\          previousSibling:null, nextSibling:null, firstChild:null, lastChild:null};
            \\  pi.isEqualNode = function(o) {
            \\    if (!o || o.nodeType !== 7) return false;
            \\    return this.target === o.target && this.data === o.data;
            \\  };
            \\  pi.isSameNode = function(o) { return this === o; };
            \\  pi.cloneNode = function() { return document.createProcessingInstruction(this.target, this.data); };
            \\  pi.lookupPrefix = function() { return null; };
            \\  pi.lookupNamespaceURI = function() { return null; };
            \\  pi.isDefaultNamespace = function() { return false; };
            \\  pi.remove = function() { if(this.parentNode) this.parentNode.removeChild(this); };
            \\  pi.before = function() {};
            \\  pi.after = function() {};
            \\  pi.replaceWith = function() {};
            \\  pi.contains = function() { return false; };
            \\  pi.hasChildNodes = function() { return false; };
            \\  pi.compareDocumentPosition = function() { return 0; };
            \\  pi.getRootNode = function() { return this.parentNode ? this.parentNode.getRootNode() : this; };
            \\  if(typeof ProcessingInstruction!=='undefined')Object.setPrototypeOf(pi,ProcessingInstruction.prototype);
            \\  return pi;
            \\})
        ;
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createProcessingInstruction", qjs.JS_Eval(ctx,
            pi_js, pi_js.len, "<pi>", qjs.JS_EVAL_TYPE_GLOBAL));
    }

    // Document properties required by jQuery/Sizzle
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "nodeType", qjs.JS_NewInt32(ctx, 9)); // DOCUMENT_NODE
    // Document.textContent: getter returns null, setter is no-op per spec
    {
        const tc_atom = qjs.JS_NewAtom(ctx, "textContent");
        const tc_get_js = "(function(){return null;})";
        const tc_set_js = "(function(){})";
        _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, tc_atom, qjs.JS_Eval(ctx, tc_get_js, tc_get_js.len, "<tc-g>", qjs.JS_EVAL_TYPE_GLOBAL), qjs.JS_Eval(ctx, tc_set_js, tc_set_js.len, "<tc-s>", qjs.JS_EVAL_TYPE_GLOBAL), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, tc_atom);
    }
    // Document.nodeValue: getter returns null, setter is no-op per spec
    {
        const nv_atom = qjs.JS_NewAtom(ctx, "nodeValue");
        const nv_get_js = "(function(){return null;})";
        const nv_set_js = "(function(){})";
        _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, nv_atom, qjs.JS_Eval(ctx, nv_get_js, nv_get_js.len, "<nv-g>", qjs.JS_EVAL_TYPE_GLOBAL), qjs.JS_Eval(ctx, nv_set_js, nv_set_js.len, "<nv-s>", qjs.JS_EVAL_TYPE_GLOBAL), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, nv_atom);
    }
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "nodeName", qjs.JS_NewString(ctx, "#document"));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "defaultView", qjs.JS_DupValue(ctx, global)); // window
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "ownerDocument", quickjs.JS_NULL());
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "parentNode", quickjs.JS_NULL());
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "parentElement", quickjs.JS_NULL());
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "nextSibling", quickjs.JS_NULL());
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "previousSibling", quickjs.JS_NULL());
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "isConnected", quickjs.JS_NewBool(true));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "compatMode", qjs.JS_NewString(ctx, "CSS1Compat"));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "contentType", qjs.JS_NewString(ctx, "text/html"));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "characterSet", qjs.JS_NewString(ctx, "UTF-8"));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "charset", qjs.JS_NewString(ctx, "UTF-8")); // alias
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "inputEncoding", qjs.JS_NewString(ctx, "UTF-8")); // alias
    // document.doctype — plain JS object (no eval to avoid 'document is not defined')
    {
        const dt_obj = qjs.JS_NewObject(ctx);
        _ = qjs.JS_SetPropertyStr(ctx, dt_obj, "nodeType", qjs.JS_NewInt32(ctx, 10));
        _ = qjs.JS_SetPropertyStr(ctx, dt_obj, "name", qjs.JS_NewString(ctx, "html"));
        _ = qjs.JS_SetPropertyStr(ctx, dt_obj, "nodeName", qjs.JS_NewString(ctx, "html"));
        _ = qjs.JS_SetPropertyStr(ctx, dt_obj, "publicId", qjs.JS_NewString(ctx, ""));
        _ = qjs.JS_SetPropertyStr(ctx, dt_obj, "systemId", qjs.JS_NewString(ctx, ""));
        _ = qjs.JS_SetPropertyStr(ctx, dt_obj, "ownerDocument", quickjs.JS_NULL()); // will be patched after doc registered
        _ = qjs.JS_SetPropertyStr(ctx, dt_obj, "nodeValue", quickjs.JS_NULL());
        _ = qjs.JS_SetPropertyStr(ctx, dt_obj, "textContent", quickjs.JS_NULL());
        // Set DocumentType.prototype for instanceof checks
        const dt_proto_js = "(function(dt){if(typeof DocumentType!=='undefined')Object.setPrototypeOf(dt,DocumentType.prototype);})";
        const dt_proto_fn = qjs.JS_Eval(ctx, dt_proto_js, dt_proto_js.len, "<dt-proto>", qjs.JS_EVAL_TYPE_GLOBAL);
        if (!quickjs.JS_IsException(dt_proto_fn)) {
            var dt_args = [1]qjs.JSValue{qjs.JS_DupValue(ctx, dt_obj)};
            const dt_r = qjs.JS_Call(ctx, dt_proto_fn, quickjs.JS_UNDEFINED(), 1, &dt_args);
            qjs.JS_FreeValue(ctx, dt_r);
            qjs.JS_FreeValue(ctx, dt_args[0]);
            qjs.JS_FreeValue(ctx, dt_proto_fn);
        }
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "doctype", dt_obj);
    }

    // document.forms / links / images (query-based getters)
    {
        const forms_js = "(function(){return document.querySelectorAll('form');})";
        const formsAtom = qjs.JS_NewAtom(ctx, "forms");
        _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, formsAtom, qjs.JS_Eval(ctx, forms_js, forms_js.len, "<forms>", qjs.JS_EVAL_TYPE_GLOBAL), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, formsAtom);
    }
    {
        const links_js = "(function(){return document.querySelectorAll('a[href],area[href]');})";
        const linksAtom = qjs.JS_NewAtom(ctx, "links");
        _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, linksAtom, qjs.JS_Eval(ctx, links_js, links_js.len, "<links>", qjs.JS_EVAL_TYPE_GLOBAL), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, linksAtom);
    }
    {
        const images_js = "(function(){return document.querySelectorAll('img');})";
        const imagesAtom = qjs.JS_NewAtom(ctx, "images");
        _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, imagesAtom, qjs.JS_Eval(ctx, images_js, images_js.len, "<images>", qjs.JS_EVAL_TYPE_GLOBAL), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, imagesAtom);
    }

    // document.scripts
    {
        const scripts_js = "(function(){return document.querySelectorAll('script');})";
        const scriptsAtom = qjs.JS_NewAtom(ctx, "scripts");
        _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, scriptsAtom, qjs.JS_Eval(ctx, scripts_js, scripts_js.len, "<scripts>", qjs.JS_EVAL_TYPE_GLOBAL), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, scriptsAtom);
    }
    // document.embeds/plugins (empty)
    {
        const empty_js = "(function(){return [];})";
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "embeds", qjs.JS_Eval(ctx, empty_js, empty_js.len, "<embeds>", qjs.JS_EVAL_TYPE_GLOBAL));
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "plugins", qjs.JS_Eval(ctx, empty_js, empty_js.len, "<plugins>", qjs.JS_EVAL_TYPE_GLOBAL));
    }

    // document.implementation
    {
        const impl = qjs.JS_NewObject(ctx);
        // createHTMLDocument: returns a minimal standalone document-like object
        const create_html_doc_js =
            \\(function(title) {
            \\  var d = document.createElement('html');
            \\  var head = document.createElement('head');
            \\  var body = document.createElement('body');
            \\  if (title !== undefined) {
            \\    var t = document.createElement('title');
            \\    t.textContent = String(title);
            \\    head.appendChild(t);
            \\  }
            \\  d.appendChild(head);
            \\  d.appendChild(body);
            \\  var dt={nodeType:10,name:'html',nodeName:'html',publicId:'',systemId:'',ownerDocument:null,parentNode:null,nextSibling:d,previousSibling:null,firstChild:null,lastChild:null,childNodes:[],nodeValue:null,textContent:null,parentElement:null,internalSubset:null};
            \\  if(typeof DocumentType!=='undefined')Object.setPrototypeOf(dt,DocumentType.prototype);
            \\  var doc = {
            \\    nodeType: 9, nodeName: '#document',
            \\    documentElement: d, head: head, body: body,
            \\    doctype: dt,
            \\    childNodes: [dt,d], children: [d], firstChild: dt, lastChild: d,
            \\    createElement: function(t) { return document.createElement(t); },
            \\    createElementNS: function(ns, t) { return document.createElementNS ? document.createElementNS(ns, t) : document.createElement(t); },
            \\    createTextNode: function(t) { return document.createTextNode(t); },
            \\    createComment: function(t) { var c = document.createComment ? document.createComment(t) : {nodeType:8,nodeName:'#comment',data:t,textContent:t}; return c; },
            \\    createDocumentFragment: function() { return document.createDocumentFragment(); },
            \\    createEvent: function(t) { return document.createEvent(t); },
            \\    getElementById: function(id) { return d.querySelector('#'+CSS.escape(id)); },
            \\    getElementsByTagName: function(t) { return d.getElementsByTagName(t); },
            \\    getElementsByClassName: function(c) { return d.getElementsByClassName(c); },
            \\    querySelector: function(s) { return d.querySelector(s); },
            \\    querySelectorAll: function(s) { return d.querySelectorAll(s); },
            \\    appendChild: function(n) { return d.appendChild(n); },
            \\    removeChild: function(n) { return d.removeChild(n); },
            \\    importNode: function(n, deep) { return n.cloneNode(deep); },
            \\    adoptNode: function(n) { return n; },
            \\    title: title || '',
            \\    implementation: document.implementation,
            \\    addEventListener: function(t,f,o) { d.addEventListener(t,f,o); },
            \\    removeEventListener: function(t,f,o) { d.removeEventListener(t,f,o); },
            \\    dispatchEvent: function(e) { return d.dispatchEvent(e); },
            \\    createAttribute: function(n) { return document.createAttribute(n); },
            \\    createAttributeNS: function(ns,qn) { return document.createAttributeNS(ns,qn); },
            \\    createTreeWalker: function(r,w,f) { return document.createTreeWalker(r,w,f); },
            \\    createNodeIterator: function(r,w,f) { return document.createNodeIterator(r,w,f); },
            \\    createRange: function() { return document.createRange(); },
            \\    ownerDocument: null,
            \\    contentType: 'text/html',
            \\    characterSet: 'UTF-8',
            \\    charset: 'UTF-8',
            \\    inputEncoding: 'UTF-8',
            \\    URL: 'about:blank',
            \\    documentURI: 'about:blank',
            \\    compatMode: 'CSS1Compat',
            \\    defaultView: null,
            \\    location: null,
            \\    hidden: true,
            \\    visibilityState: 'hidden',
            \\    readyState: 'complete',
            \\    hasFocus: function() { return false; },
            \\    cloneNode: function(deep) {
            \\      var nd = document.implementation.createHTMLDocument(title);
            \\      if(deep && d.innerHTML) nd.documentElement.innerHTML = d.innerHTML;
            \\      return nd;
            \\    },
            \\  };
            \\  if(typeof Document!=='undefined')Object.setPrototypeOf(doc,Document.prototype);
            \\  doc.implementation={
            \\    createDocumentType:function(n,p,s){var dt=document.implementation.createDocumentType(n,p,s);dt.ownerDocument=doc;return dt;},
            \\    createHTMLDocument:function(t){return document.implementation.createHTMLDocument(t);},
            \\    createDocument:function(ns,qn,dt){return document.implementation.createDocument(ns,qn,dt);},
            \\    hasFeature:function(){return true;}
            \\  };
            \\  return doc;
            \\})
        ;
        _ = qjs.JS_SetPropertyStr(ctx, impl, "createHTMLDocument", qjs.JS_Eval(ctx,
            create_html_doc_js, create_html_doc_js.len, "<impl>", qjs.JS_EVAL_TYPE_GLOBAL));
        const has_feature_js = "(function() { return true; })";
        _ = qjs.JS_SetPropertyStr(ctx, impl, "hasFeature", qjs.JS_Eval(ctx,
            has_feature_js, has_feature_js.len, "<impl>", qjs.JS_EVAL_TYPE_GLOBAL));
        _ = qjs.JS_SetPropertyStr(ctx, impl, "createDocumentType", qjs.JS_NewCFunction(ctx, &dom_doc.implCreateDocumentType, "createDocumentType", 3));
        _ = qjs.JS_SetPropertyStr(ctx, impl, "createDocument", qjs.JS_NewCFunction(ctx, &dom_doc.implCreateDocument, "createDocument", 3));
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "implementation", impl);
    }
    // document.adoptedStyleSheets (used by CSS-in-JS / popover polyfills)
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "adoptedStyleSheets", qjs.JS_NewArray(ctx));
    // Page Visibility API
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "hidden", quickjs.JS_NewBool(false));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "visibilityState", qjs.JS_NewString(ctx, "visible"));
    // document.dir
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "dir", qjs.JS_NewString(ctx, ""));
    // document.designMode
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "designMode", qjs.JS_NewString(ctx, "off"));
    // Document event methods
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "addEventListener", qjs.JS_NewCFunction(ctx, &events.jsAddEventListenerPub, "addEventListener", 3));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "removeEventListener", qjs.JS_NewCFunction(ctx, &events.jsRemoveEventListenerPub, "removeEventListener", 3));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "dispatchEvent", qjs.JS_NewCFunction(ctx, &events.jsWindowDispatchEventPub, "dispatchEvent", 1));
    // document.cloneNode(deep) — uses DOMParser-style native parse to avoid script re-execution
    {
        const cn_js =
            \\(function(deep){
            \\  if(!deep) return new DOMParser().parseFromString('','text/html');
            \\  var html=document.documentElement?document.documentElement.outerHTML:'';
            \\  var dt=document.doctype;
            \\  var src=(dt?'<!DOCTYPE '+(dt.name||'html')+'>':'')+html;
            \\  return new DOMParser().parseFromString(src,'text/html');
            \\})
        ;
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "cloneNode", qjs.JS_Eval(ctx, cn_js, cn_js.len, "<doc-clone>", qjs.JS_EVAL_TYPE_GLOBAL));
    }
    // document.lastModified
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "lastModified", qjs.JS_NewString(ctx, ""));

    // Set document global (reuses `global` from constructor registration above)
    _ = qjs.JS_SetPropertyStr(ctx, global, "document", doc_obj);

    // Document constructor (new Document() creates a standalone XML document-like object)
    {
        const doc_ctor_js =
            \\(function() {
            \\  function Document() {
            \\    Object.defineProperty(this,'nodeType',{value:9,writable:false,configurable:true,enumerable:true});
            \\    Object.defineProperty(this,'nodeName',{value:'#document',writable:false,configurable:true,enumerable:true});
            \\    this._childNodes = [];
            \\    this._children = [];
            \\    Object.defineProperty(this,'childNodes',{get:function(){return this._childNodes;},configurable:true,enumerable:true});
            \\    Object.defineProperty(this,'children',{get:function(){return this._children;},configurable:true,enumerable:true});
            \\    Object.defineProperty(this,'firstChild',{value:null,writable:true,configurable:true,enumerable:true});
            \\    Object.defineProperty(this,'lastChild',{value:null,writable:true,configurable:true,enumerable:true});
            \\    Object.defineProperty(this,'documentElement',{value:null,writable:true,configurable:true,enumerable:true});
            \\    Object.defineProperty(this,'ownerDocument',{value:null,writable:true,configurable:true,enumerable:true});
            \\    Object.defineProperty(this,'parentNode',{value:null,writable:true,configurable:true,enumerable:true});
            \\    Object.defineProperty(this,'parentElement',{value:null,writable:true,configurable:true,enumerable:true});
            \\    Object.defineProperty(this,'nextSibling',{value:null,writable:true,configurable:true,enumerable:true});
            \\    Object.defineProperty(this,'previousSibling',{value:null,writable:true,configurable:true,enumerable:true});
            \\    this.doctype = null;
            \\    this.head = null;
            \\    this.body = null;
            \\    this.contentType = 'application/xml';
            \\    this.characterSet = 'UTF-8';
            \\    this.charset = 'UTF-8';
            \\    this.inputEncoding = 'UTF-8';
            \\    this.URL = 'about:blank';
            \\    this.documentURI = 'about:blank';
            \\    this.compatMode = 'CSS1Compat';
            \\    this.implementation = document.implementation;
            \\    this.location = null;
            \\    this.defaultView = null;
            \\    this.hidden = false;
            \\    this.visibilityState = 'visible';
            \\  }
            \\  Object.setPrototypeOf(Document.prototype, Node.prototype);
            \\  Document.prototype.createElement = function(t) { return document.createElement(t); };
            \\  Document.prototype.createElementNS = function(ns,t) { return document.createElementNS(ns,t); };
            \\  Document.prototype.createTextNode = function(t) { return document.createTextNode(t); };
            \\  Document.prototype.createComment = function(t) { return document.createComment(t); };
            \\  Document.prototype.createDocumentFragment = function() { return document.createDocumentFragment(); };
            \\  Document.prototype.createProcessingInstruction = function(t,d) { return document.createProcessingInstruction(t,d); };
            \\  Document.prototype.createCDATASection = function(d) { return {nodeType:4,nodeName:'#cdata-section',data:d,textContent:d,nodeValue:d,childNodes:[]}; };
            \\  Document.prototype.createEvent = function(t) { return document.createEvent(t); };
            \\  Document.prototype.getElementById = function(id) { if(this.documentElement) return this.documentElement.querySelector('#'+CSS.escape(id)); return null; };
            \\  Document.prototype.querySelector = function(s) { if(this.documentElement) return this.documentElement.querySelector(s); return null; };
            \\  Document.prototype.querySelectorAll = function(s) { if(this.documentElement) return this.documentElement.querySelectorAll(s); return []; };
            \\  Document.prototype.getElementsByTagName = function(t) { if(this.documentElement) return this.documentElement.getElementsByTagName(t); return []; };
            \\  function _docPreInsert(doc,n){
            \\    var nt=n.nodeType;
            \\    if(nt!==1&&nt!==3&&nt!==7&&nt!==8&&nt!==10&&nt!==11)throw new DOMException("HierarchyRequestError","HierarchyRequestError");
            \\    if(nt===3)throw new DOMException("HierarchyRequestError","HierarchyRequestError");
            \\    var p=doc;while(p){if(p===n)throw new DOMException("HierarchyRequestError","HierarchyRequestError");p=p.parentNode;}
            \\    if(nt===1&&doc.documentElement&&doc.documentElement!==n)throw new DOMException("HierarchyRequestError","HierarchyRequestError");
            \\    if(nt===10&&doc.doctype&&doc.doctype!==n)throw new DOMException("HierarchyRequestError","HierarchyRequestError");
            \\    if(nt===11){var ec=0;for(var i=0;i<(n.childNodes?n.childNodes.length:0);i++){if(n.childNodes[i].nodeType===1)ec++;if(n.childNodes[i].nodeType===3)throw new DOMException("HierarchyRequestError","HierarchyRequestError");}if(ec>1||(ec===1&&doc.documentElement))throw new DOMException("HierarchyRequestError","HierarchyRequestError");}
            \\  }
            \\  Document.prototype.appendChild = function(n) {
            \\    _docPreInsert(this,n);
            \\    if(n.parentNode)n.parentNode.removeChild(n);
            \\    n.parentNode=this;n.ownerDocument=this;
            \\    this._childNodes.push(n);
            \\    if(n.nodeType===1)this._children.push(n);
            \\    this.firstChild = this._childNodes[0];
            \\    this.lastChild = this._childNodes[this._childNodes.length-1];
            \\    if(n.nodeType===1 && !this.documentElement) this.documentElement = n;
            \\    if(n.nodeType===10) this.doctype = n;
            \\    return n;
            \\  };
            \\  Document.prototype.removeChild = function(n) {
            \\    var i=this._childNodes.indexOf(n);if(i>=0)this._childNodes.splice(i,1);
            \\    var j=this._children.indexOf(n);if(j>=0)this._children.splice(j,1);
            \\    n.parentNode=null;
            \\    this.firstChild=this._childNodes[0]||null;this.lastChild=this._childNodes[this._childNodes.length-1]||null;
            \\    if(this.documentElement===n)this.documentElement=null;
            \\    if(this.doctype===n)this.doctype=null;
            \\    return n;
            \\  };
            \\  Document.prototype.insertBefore = function(n,ref) {
            \\    if(!ref)return this.appendChild(n);
            \\    _docPreInsert(this,n);
            \\    if(n.parentNode)n.parentNode.removeChild(n);
            \\    n.parentNode=this;n.ownerDocument=this;
            \\    var i=this._childNodes.indexOf(ref);if(i>=0)this._childNodes.splice(i,0,n);else this._childNodes.push(n);
            \\    if(n.nodeType===1){var j=this._children.indexOf(ref);if(j>=0)this._children.splice(j,0,n);else this._children.push(n);}
            \\    this.firstChild=this._childNodes[0];this.lastChild=this._childNodes[this._childNodes.length-1];
            \\    if(n.nodeType===1&&!this.documentElement)this.documentElement=n;
            \\    if(n.nodeType===10)this.doctype=n;
            \\    return n;
            \\  };
            \\  Document.prototype.prepend = function(){var f=this._childNodes[0]||null;for(var i=0;i<arguments.length;i++){var a=arguments[i];if(typeof a==='string')a={nodeType:3,nodeName:'#text',data:a,textContent:a,nodeValue:a,childNodes:[],parentNode:null};_docPreInsert(this,a);if(f)this.insertBefore(a,f);else this.appendChild(a);}};
            \\  Document.prototype.append = function(){for(var i=0;i<arguments.length;i++){var a=arguments[i];if(typeof a==='string')a={nodeType:3,nodeName:'#text',data:a,textContent:a,nodeValue:a,childNodes:[],parentNode:null};this.appendChild(a);}};
            \\  Document.prototype.replaceChildren = function(){while(this._childNodes.length>0)this.removeChild(this._childNodes[this._childNodes.length-1]);for(var i=0;i<arguments.length;i++){var a=arguments[i];if(typeof a==='string')a={nodeType:3,nodeName:'#text',data:a,textContent:a,nodeValue:a,childNodes:[],parentNode:null};this.appendChild(a);}};
            \\  Document.prototype.importNode = function(n,d) { return n.cloneNode(d); };
            \\  Document.prototype.adoptNode = function(n) { return n; };
            \\  Document.prototype.createAttribute = function(n) { return document.createAttribute(n); };
            \\  Document.prototype.createAttributeNS = function(ns,qn) { return document.createAttributeNS(ns,qn); };
            \\  Document.prototype.createRange = function() { return document.createRange(); };
            \\  Document.prototype.createTreeWalker = function(r,w,f) { return document.createTreeWalker(r,w,f); };
            \\  Document.prototype.createNodeIterator = function(r,w,f) { return document.createNodeIterator(r,w,f); };
            \\  Document.prototype.implementation = document.implementation;
            \\  return Document;
            \\})()
        ;
        const ctor = qjs.JS_Eval(ctx, doc_ctor_js, doc_ctor_js.len, "<Document>", qjs.JS_EVAL_TYPE_GLOBAL);
        _ = qjs.JS_SetPropertyStr(ctx, global, "Document", ctor);
    }

    // XMLDocument extends Document
    {
        const xml_doc_js =
            \\(function(){
            \\  function XMLDocument(){Document.call(this);this.contentType='application/xml';}
            \\  XMLDocument.prototype=Object.create(Document.prototype);
            \\  XMLDocument.prototype.constructor=XMLDocument;
            \\  return XMLDocument;
            \\})()
        ;
        const xml_ctor = qjs.JS_Eval(ctx, xml_doc_js, xml_doc_js.len, "<XMLDocument>", qjs.JS_EVAL_TYPE_GLOBAL);
        _ = qjs.JS_SetPropertyStr(ctx, global, "XMLDocument", xml_ctor);
    }

    // window.location
    _ = qjs.JS_SetPropertyStr(ctx, global, "location", createLocationObject(ctx));

    // window.getComputedStyle
    _ = qjs.JS_SetPropertyStr(ctx, global, "getComputedStyle", qjs.JS_NewCFunction(ctx, &dom_style.windowGetComputedStyle, "getComputedStyle", 1));

    // CSS global object with supports() and escape() methods
    {
        const css_obj = qjs.JS_NewObject(ctx);
        _ = qjs.JS_SetPropertyStr(ctx, css_obj, "supports", qjs.JS_NewCFunction(ctx, &dom_style.cssSupports, "supports", 2));
        // CSS.escape() per CSSOM spec
        const escape_js =
            \\(function(v){
            \\  v=String(v);if(!v.length)return '';
            \\  var r='',i=0,c;
            \\  if(v.length===1&&v.charCodeAt(0)===0)return '\uFFFD';
            \\  for(;i<v.length;i++){c=v.charCodeAt(i);
            \\    if(c===0){r+='\uFFFD';}
            \\    else if(c>=1&&c<=31||c===127||(i===0&&c>=48&&c<=57)||(i===1&&c>=48&&c<=57&&v.charCodeAt(0)===45)){r+='\\'+c.toString(16)+' ';}
            \\    else if(i===0&&c===45&&v.length===1){r+='\\'+v.charAt(i);}
            \\    else if(c>=128||c===45||c===95||(c>=48&&c<=57)||(c>=65&&c<=90)||(c>=97&&c<=122)){r+=v.charAt(i);}
            \\    else{r+='\\'+v.charAt(i);}
            \\  }return r;
            \\})
        ;
        _ = qjs.JS_SetPropertyStr(ctx, css_obj, "escape", qjs.JS_Eval(ctx, escape_js, escape_js.len, "<css-escape>", qjs.JS_EVAL_TYPE_GLOBAL));
        _ = qjs.JS_SetPropertyStr(ctx, global, "CSS", css_obj);
    }

    // window.scrollTo / window.scrollBy
    _ = qjs.JS_SetPropertyStr(ctx, global, "scrollTo", qjs.JS_NewCFunction(ctx, &windowScrollTo, "scrollTo", 2));
    _ = qjs.JS_SetPropertyStr(ctx, global, "scrollBy", qjs.JS_NewCFunction(ctx, &windowScrollBy, "scrollBy", 2));

    // window.innerWidth / window.innerHeight
    const innerWidthAtom = qjs.JS_NewAtom(ctx, "innerWidth");
    _ = qjs.JS_DefinePropertyGetSet(ctx, global, innerWidthAtom, qjs.JS_NewCFunction(ctx, &windowGetInnerWidth, "get innerWidth", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, innerWidthAtom);

    const innerHeightAtom = qjs.JS_NewAtom(ctx, "innerHeight");
    _ = qjs.JS_DefinePropertyGetSet(ctx, global, innerHeightAtom, qjs.JS_NewCFunction(ctx, &windowGetInnerHeight, "get innerHeight", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, innerHeightAtom);

    // window.scrollX / scrollY / pageXOffset / pageYOffset
    {
        const scrollXAtom = qjs.JS_NewAtom(ctx, "scrollX");
        _ = qjs.JS_DefinePropertyGetSet(ctx, global, scrollXAtom, qjs.JS_NewCFunction(ctx, &jsGetScrollX, "get scrollX", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, scrollXAtom);
    }
    {
        const scrollYAtom = qjs.JS_NewAtom(ctx, "scrollY");
        _ = qjs.JS_DefinePropertyGetSet(ctx, global, scrollYAtom, qjs.JS_NewCFunction(ctx, &jsGetScrollY, "get scrollY", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, scrollYAtom);
    }
    {
        const pageXOffsetAtom = qjs.JS_NewAtom(ctx, "pageXOffset");
        _ = qjs.JS_DefinePropertyGetSet(ctx, global, pageXOffsetAtom, qjs.JS_NewCFunction(ctx, &jsGetScrollX, "get pageXOffset", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, pageXOffsetAtom);
    }
    {
        const pageYOffsetAtom = qjs.JS_NewAtom(ctx, "pageYOffset");
        _ = qjs.JS_DefinePropertyGetSet(ctx, global, pageYOffsetAtom, qjs.JS_NewCFunction(ctx, &jsGetScrollY, "get pageYOffset", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, pageYOffsetAtom);
    }

    // navigator object (minimal)
    const nav_obj = qjs.JS_NewObject(ctx);
    const nav_ua = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
    _ = qjs.JS_SetPropertyStr(ctx, nav_obj, "userAgent", qjs.JS_NewStringLen(ctx, nav_ua, nav_ua.len));
    _ = qjs.JS_SetPropertyStr(ctx, nav_obj, "language", qjs.JS_NewStringLen(ctx, "en", 2));
    _ = qjs.JS_SetPropertyStr(ctx, nav_obj, "platform", qjs.JS_NewStringLen(ctx, "Linux", 5));
    _ = qjs.JS_SetPropertyStr(ctx, global, "navigator", nav_obj);

    // HTML spec: window, self, globalThis all refer to the global object
    _ = qjs.JS_SetPropertyStr(ctx, global, "window", qjs.JS_DupValue(ctx, global));
    _ = qjs.JS_SetPropertyStr(ctx, global, "self", qjs.JS_DupValue(ctx, global));

    // DOM Standard §4.3: Register DOMException constructor
    // Must be a proper JS class so `e.constructor === DOMException` works in assert_throws_dom
    const dom_exc_script =
        \\function DOMException(message, name) {
        \\  this.message = message || '';
        \\  this.name = name || 'Error';
        \\  var codes = {IndexSizeError:1,HierarchyRequestError:3,WrongDocumentError:4,
        \\    InvalidCharacterError:5,NoModificationAllowedError:7,NotFoundError:8,
        \\    NotSupportedError:9,InUseAttributeError:10,InvalidStateError:11,
        \\    SyntaxError:12,InvalidModificationError:13,NamespaceError:14,
        \\    InvalidAccessError:15,SecurityError:18,NetworkError:19,AbortError:20,
        \\    URLMismatchError:21,TimeoutError:23,InvalidNodeTypeError:24,DataCloneError:25};
        \\  this.code = codes[this.name] || 0;
        \\}
        \\DOMException.prototype = Object.create(Error.prototype);
        \\DOMException.prototype.constructor = DOMException;
        \\DOMException.prototype.toString = function() { return 'DOMException: ' + this.message; };
    ;
    const exc_result = qjs.JS_Eval(ctx, dom_exc_script.ptr, dom_exc_script.len, "<domexception>", 0);
    qjs.JS_FreeValue(ctx, exc_result);

    // Fix document.doctype prototype (must happen after DocumentType is defined)
    {
        const fix_dt_js =
            \\(function(){if(document.doctype&&typeof DocumentType!=='undefined')Object.setPrototypeOf(document.doctype,DocumentType.prototype);})()
        ;
        const fix_r = qjs.JS_Eval(ctx, fix_dt_js, fix_dt_js.len, "<fix-dt>", qjs.JS_EVAL_TYPE_GLOBAL);
        qjs.JS_FreeValue(ctx, fix_r);
    }

    qjs.JS_FreeValue(ctx, global);
}

// wrapNodePublic/getNodePublic moved to top of file (near wrapNode/getNode)

// ── CSS Value Validation (for element.style setter) ─────────────────


