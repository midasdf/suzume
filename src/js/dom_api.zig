const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;
const lxb = @import("../bindings/lexbor.zig").c;
const events = @import("events.zig");

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
extern fn lxb_dom_element_local_name(element: *lxb.lxb_dom_element_t, len: *usize) ?[*]const u8;
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
var g_document: ?*anyopaque = null;

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
fn setDomDirtyIfConnected(elem: *lxb.lxb_dom_element_t) void {
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
var g_root_box: ?*const Box = null;

/// Set the root box pointer (called from main after layout).
pub fn setRootBox(root: ?*const Box) void {
    g_root_box = root;
}

/// Global styles pointer — set from main after cascade, used for getComputedStyle.
var g_styles: ?*const cascade_mod.StyleMap = null;

/// Set the styles pointer (called from main after cascade/restyle).
pub fn setStyles(styles: ?*const cascade_mod.StyleMap) void {
    g_styles = styles;
}

/// Viewport dimensions for getComputedStyle resolution.
var g_viewport_width: f32 = 800;
var g_viewport_height: f32 = 600;

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
}

/// Find the Box in the tree that corresponds to a given DOM node pointer.
fn findBoxForNode(root: *const Box, target: *lxb.lxb_dom_node_t) ?*const Box {
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
var g_current_url: ?[]const u8 = null;

/// Set the current page URL (called from main on navigation).
pub fn setCurrentUrl(url: ?[]const u8) void {
    g_current_url = url;
}

// ── Dynamic script execution support ────────────────────────────────
const JsRuntime = @import("runtime.zig").JsRuntime;
const Loader = @import("../net/loader.zig").Loader;
const resolveUrl = @import("../net/loader.zig").resolveUrl;
const adblock_mod = @import("../features/adblock.zig");

var g_js_rt: ?*JsRuntime = null;
var g_loader: ?*Loader = null;
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

// ── Serialization helper (for innerHTML/outerHTML) ──────────────────

const SerializeAccum = struct {
    buf: []u8,
    pos: usize,
    overflow: bool,
    heap_buf: ?[]u8, // if stack buf overflows, we switch to heap

    fn init(stack_buf: []u8) SerializeAccum {
        return .{ .buf = stack_buf, .pos = 0, .overflow = false, .heap_buf = null };
    }

    fn deinit(self: *SerializeAccum) void {
        if (self.heap_buf) |hb| std.heap.c_allocator.free(hb);
    }

    fn result(self: *SerializeAccum) []const u8 {
        return self.buf[0..self.pos];
    }

    fn append(self: *SerializeAccum, data: []const u8) bool {
        if (self.pos + data.len > self.buf.len) {
            // Need to grow
            const new_size = @max(self.buf.len * 2, self.pos + data.len + 1024);
            const new_buf = std.heap.c_allocator.alloc(u8, new_size) catch return false;
            @memcpy(new_buf[0..self.pos], self.buf[0..self.pos]);
            if (self.heap_buf) |old| std.heap.c_allocator.free(old);
            self.heap_buf = new_buf;
            self.buf = new_buf;
        }
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
        return true;
    }
};

fn serializeCallback(data: ?[*]const u8, len: usize, ctx: ?*anyopaque) callconv(.c) lxb.lxb_status_t {
    if (len == 0) return 0;
    const accum: *SerializeAccum = @ptrCast(@alignCast(ctx orelse return 1));
    const d = data orelse return 1;
    if (!accum.append(d[0..len])) return 1;
    return 0;
}

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

fn wrapNode(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) qjs.JSValue {
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

// ── CharacterData.data getter/setter (Text, Comment, PI) ────────────

fn textGetData(
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

fn textSetData(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const node = getNodeFromText(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const s = jsStringToSlice(c, args[0]) orelse {
        // null/undefined → empty string (JS wrapper should handle this, but be safe)
        _ = lxb_dom_node_text_content_set(node, "", 0);
        events.recordMutation(node, "characterData", null, null, null);
        setDomDirty();
        return quickjs.JS_UNDEFINED();
    };
    defer qjs.JS_FreeCString(c, s.ptr);
    _ = lxb_dom_node_text_content_set(node, s.ptr, s.len);
    events.recordMutation(node, "characterData", null, null, null);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

/// nodeValue getter for node_proto — returns null for Element/Document, data for Text/Comment
fn nodeGetNodeValue(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    // Text, Comment, PI have nodeValue = their data; everything else returns null
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

fn getNodeFromText(ctx: *qjs.JSContext, val: qjs.JSValue) ?*lxb.lxb_dom_node_t {
    const ptr = qjs.JS_GetOpaque2(ctx, val, text_class_id);
    if (ptr) |p| return @ptrCast(@alignCast(p));
    return null;
}

/// Get the lxb_dom_node_t* from a JS Element/Text value.
/// Tries both element and text class IDs.
fn getNode(ctx: *qjs.JSContext, val: qjs.JSValue) ?*lxb.lxb_dom_node_t {
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

fn getElement(ctx: *qjs.JSContext, val: qjs.JSValue) ?*lxb.lxb_dom_element_t {
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

// ── Element prototype methods ───────────────────────────────────────

fn elementGetTagName(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_NULL();
    var len: usize = 0;
    const name_ptr = lxb_dom_element_local_name(elem, &len);
    if (name_ptr == null or len == 0) return quickjs.JS_NULL();

    // Convert to uppercase (DOM spec: tagName is uppercase for HTML elements)
    var stack_buf: [256]u8 = undefined;
    const use_heap = len > stack_buf.len;
    const buf = if (use_heap)
        (std.heap.c_allocator.alloc(u8, len) catch return quickjs.JS_UNDEFINED())
    else
        stack_buf[0..len];
    defer if (use_heap) std.heap.c_allocator.free(buf);
    for (0..len) |i| {
        const ch = name_ptr.?[i];
        buf[i] = if (ch >= 'a' and ch <= 'z') ch - 32 else ch;
    }
    return qjs.JS_NewStringLen(c, buf.ptr, len);
}

fn elementGetLocalName(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_NULL();
    var len: usize = 0;
    const name_ptr = lxb_dom_element_local_name(elem, &len);
    if (name_ptr == null or len == 0) return quickjs.JS_NULL();
    // localName is lowercase (as stored by lexbor HTML parser)
    return qjs.JS_NewStringLen(c, name_ptr.?, len);
}

fn elementGetId(
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

fn elementSetId(
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

fn elementGetClassName(
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

fn elementSetClassName(
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

fn elementGetTextContent(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    var len: usize = 0;
    const ptr = lxb_dom_node_text_content(node, &len);
    if (ptr == null or len == 0) return qjs.JS_NewStringLen(c, "", 0);
    return qjs.JS_NewStringLen(c, ptr.?, len);
}

fn elementSetTextContent(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    // DOM spec: setting textContent to null is treated as empty string
    const s = jsStringToSlice(c, args[0]) orelse {
        _ = lxb_dom_node_text_content_set(node, "", 0);
        events.recordMutation(node, "childList", null, null, null);
        setDomDirty();
        return quickjs.JS_UNDEFINED();
    };
    defer qjs.JS_FreeCString(c, s.ptr);
    _ = lxb_dom_node_text_content_set(node, s.ptr, s.len);
    events.recordMutation(node, "childList", null, null, null);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

fn elementGetParentNode(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    const p = node.parent orelse return quickjs.JS_NULL();
    return wrapNode(c, p);
}

fn elementGetParentElement(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    const p: *lxb.lxb_dom_node_t = node.parent orelse return quickjs.JS_NULL();
    if (p.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return quickjs.JS_NULL();
    return wrapNode(c, p);
}

fn elementGetFirstChild(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    const child = node.first_child orelse return quickjs.JS_NULL();
    return wrapNode(c, child);
}

fn elementGetLastChild(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    const child = lxb_dom_node_last_child_noi(node) orelse return quickjs.JS_NULL();
    return wrapNode(c, child);
}

fn elementGetNextSibling(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    const sib = node.next orelse return quickjs.JS_NULL();
    return wrapNode(c, sib);
}

fn elementGetPreviousSibling(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    const sib = lxb_dom_node_prev_noi(node) orelse return quickjs.JS_NULL();
    return wrapNode(c, sib);
}

fn elementGetChildren(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    const arr = qjs.JS_NewArray(c);
    if (quickjs.JS_IsException(arr)) return arr;

    var idx: u32 = 0;
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        if (ch.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            _ = qjs.JS_SetPropertyUint32(c, arr, idx, wrapNode(c, ch));
            idx += 1;
        }
        child = ch.next;
    }
    return arr;
}

fn elementGetChildNodes(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    const arr = qjs.JS_NewArray(c);
    if (quickjs.JS_IsException(arr)) return arr;

    var idx: u32 = 0;
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        _ = qjs.JS_SetPropertyUint32(c, arr, idx, wrapNode(c, ch));
        idx += 1;
        child = ch.next;
    }
    return arr;
}

fn elementGetAttribute(
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

fn elementSetAttribute(
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

fn elementRemoveAttribute(
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

fn elementAppendChild(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const parent = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const child = getNode(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    lxb_dom_node_insert_child(parent, child);
    events.recordMutation(parent, "childList", child, null, null);
    setDomDirty();
    // Dynamic script execution: if a <script> is appended, fetch and execute it
    maybeExecuteDynamicScript(c, child, args[0]);
    // Upgrade custom elements in the inserted subtree
    upgradeSubtreeCustomElements(c, child);
    return qjs.JS_DupValue(c, args[0]);
}

fn elementRemoveChild(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const parent = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const child = getNode(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    // Verify child is actually a child of parent (DOM spec: NotFoundError)
    if (child.parent != parent) return quickjs.JS_UNDEFINED();
    lxb_dom_node_remove(child);
    events.recordMutation(parent, "childList", null, child, null);
    setDomDirty();
    return qjs.JS_DupValue(c, args[0]);
}

fn elementInsertBefore(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 2) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    _ = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const new_node = getNode(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    if (quickjs.JS_IsNull(args[1]) or quickjs.JS_IsUndefined(args[1])) {
        // If reference is null, act like appendChild
        const parent = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
        lxb_dom_node_insert_child(parent, new_node);
    } else {
        const ref_node = getNode(c, args[1]) orelse return quickjs.JS_UNDEFINED();
        lxb_dom_node_insert_before(ref_node, new_node);
    }
    const parent_node = getNode(c, this_val) orelse new_node;
    events.recordMutation(parent_node, "childList", new_node, null, null);
    setDomDirty();
    // Dynamic script execution: if a <script> is inserted, fetch and execute it
    maybeExecuteDynamicScript(c, new_node, args[0]);
    // Upgrade custom elements in the inserted subtree
    upgradeSubtreeCustomElements(c, new_node);
    return qjs.JS_DupValue(c, args[0]);
}

fn elementReplaceChild(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 2) return qjs.JS_ThrowTypeError(c, "Failed to execute 'replaceChild': 2 arguments required");
    const args = argv orelse return quickjs.JS_NULL();
    _ = getNode(c, this_val) orelse return quickjs.JS_NULL();
    const new_node = getNode(c, args[0]) orelse return quickjs.JS_NULL();
    const old_node = getNode(c, args[1]) orelse return quickjs.JS_NULL();
    // Insert new before old, then remove old
    lxb_dom_node_insert_before(old_node, new_node);
    lxb_dom_node_remove(old_node);
    setDomDirty();
    return qjs.JS_DupValue(c, args[1]); // returns the removed (old) node
}

// ── classList helper ────────────────────────────────────────────────

fn classListAdd(
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
    @import("../js/events.zig").recordMutation(@ptrCast(elem), "attributes", null, null, "class");
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

fn classListRemove(
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
    const events_mod = @import("../js/events.zig");
    events_mod.recordMutation(@ptrCast(elem), "attributes", null, null, "class");
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

fn classListContains(
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

fn classListToggle(
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

fn classListReplace(
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
    const ev = @import("../js/events.zig");
    ev.recordMutation(@ptrCast(elem), "attributes", null, null, "class");
    setDomDirty();
    return quickjs.JS_NewBool(true);
}

fn classListEntries(ctx: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: ?[*]qjs.JSValue) callconv(.c) qjs.JSValue {
    // Stub: return empty array (full iterator support TODO)
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewArray(c);
}

fn classListKeys(ctx: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: ?[*]qjs.JSValue) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewArray(c);
}

fn classListValues(ctx: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: ?[*]qjs.JSValue) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewArray(c);
}

/// Throw a DOMException with the given name and message.
/// DOM Standard §4.3: Uses the global DOMException constructor so
/// assert_throws_dom's `e.constructor === DOMException` check passes.
fn throwDOMException(c: *qjs.JSContext, name: []const u8, message: []const u8) qjs.JSValue {
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

/// Normalize class attribute: split by whitespace, deduplicate, rejoin with single spaces.
/// DOM spec: ordered set serialization for DOMTokenList.
fn normalizeClassAttribute(elem: *lxb.lxb_dom_element_t) void {
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

fn classContains(class_str: []const u8, needle: []const u8) bool {
    var iter = std.mem.tokenizeAny(u8, class_str, " \t\n\r\x0c");
    while (iter.next()) |cls| {
        if (std.mem.eql(u8, cls, needle)) return true;
    }
    return false;
}

fn classListItem(
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

fn classListForEach(
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

fn classListGetLength(
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

fn classListGetValue(
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
fn createClassList(ctx: *qjs.JSContext, element_val: qjs.JSValue) qjs.JSValue {
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

fn elementGetClassList(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return createClassList(c, this_val);
}

// ── innerHTML getter/setter ──────────────────────────────────────────

fn elementGetInnerHTML(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return qjs.JS_NewStringLen(c, "", 0);
    // Serialize all child nodes (innerHTML = deep serialization of children)
    var stack_buf: [8192]u8 = undefined;
    var accum = SerializeAccum.init(&stack_buf);
    defer accum.deinit();

    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        _ = lxb_html_serialize_tree_cb(ch, &serializeCallback, @ptrCast(&accum));
        child = ch.next;
    }
    const result = accum.result();
    return qjs.JS_NewStringLen(c, result.ptr, result.len);
}

fn elementSetInnerHTML(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, s.ptr);

    // Protect <body> from innerHTML overwrites that destroy page content.
    // jQuery Sizzle's feature detection sets body.innerHTML to test forms.
    // Only block writes that would replace content with small test markup;
    // allow legitimate larger innerHTML updates through.
    {
        var name_len: usize = 0;
        const name_ptr = lxb.lxb_dom_element_local_name(elem, &name_len);
        if (name_ptr) |np| {
            const tag = np[0..name_len];
            if (std.mem.eql(u8, tag, "body") and s.len < 200) {
                // Small innerHTML on body = likely feature detection probe, block it
                std.log.info("[DOM] innerHTML SET on <body> blocked (probe, {d} bytes)", .{s.len});
                return quickjs.JS_UNDEFINED();
            }
        }
    }

    // Remove all existing children
    while (node.first_child) |child| {
        lxb_dom_node_remove(child);
        _ = lxb_dom_node_destroy(child);
    }

    // If empty string, just clear
    if (s.len == 0) {
        setDomDirty();
        return quickjs.JS_UNDEFINED();
    }

    // Parse fragment and attach children
    const doc = g_document orelse return quickjs.JS_UNDEFINED();
    const frag = lxb_html_document_parse_fragment(doc, elem, s.ptr, s.len) orelse return quickjs.JS_UNDEFINED();

    // Move children from fragment to element
    while (frag.first_child) |child| {
        lxb_dom_node_remove(child);
        lxb_dom_node_insert_child(node, child);
    }
    // Destroy the fragment container itself
    _ = lxb_dom_node_destroy(frag);

    events.recordMutation(node, "childList", null, null, null);
    setDomDirty();

    // Upgrade custom elements in newly parsed subtree
    upgradeSubtreeCustomElements(c, node);

    return quickjs.JS_UNDEFINED();
}

// ── insertAdjacentHTML ──────────────────────────────────────────────

fn elementInsertAdjacentHTML(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 2) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);

    const pos_s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, pos_s.ptr);
    const position = pos_s.ptr[0..pos_s.len];

    const html_s = jsStringToSlice(c, args[1]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, html_s.ptr);

    if (html_s.len == 0) return quickjs.JS_UNDEFINED();

    // Parse fragment
    const doc = g_document orelse return quickjs.JS_UNDEFINED();
    const frag = lxb_html_document_parse_fragment(doc, elem, html_s.ptr, html_s.len) orelse return quickjs.JS_UNDEFINED();

    if (std.ascii.eqlIgnoreCase(position, "beforebegin")) {
        // Insert before this element (as previous sibling)
        while (frag.first_child) |child| {
            lxb_dom_node_remove(child);
            lxb_dom_node_insert_before(node, child);
        }
    } else if (std.ascii.eqlIgnoreCase(position, "afterbegin")) {
        // Insert as first child of this element
        // Insert in reverse order to maintain document order
        const last_inserted: ?*lxb.lxb_dom_node_t = node.first_child;
        while (frag.first_child) |child| {
            lxb_dom_node_remove(child);
            if (last_inserted) |ref| {
                lxb_dom_node_insert_before(ref, child);
            } else {
                lxb_dom_node_insert_child(node, child);
            }
        }
    } else if (std.ascii.eqlIgnoreCase(position, "beforeend")) {
        // Append as last child (same as innerHTML append)
        while (frag.first_child) |child| {
            lxb_dom_node_remove(child);
            lxb_dom_node_insert_child(node, child);
        }
    } else if (std.ascii.eqlIgnoreCase(position, "afterend")) {
        // Insert after this element (as next sibling)
        var insert_after: *lxb.lxb_dom_node_t = node;
        while (frag.first_child) |child| {
            lxb_dom_node_remove(child);
            lxb_dom_node_insert_after(insert_after, child);
            insert_after = child;
        }
    }

    _ = lxb_dom_node_destroy(frag);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

// ── element.attachShadow() stub ─────────────────────────────────────

fn elementAttachShadow(
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

fn elementInsertAdjacentElement(
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

fn elementInsertAdjacentText(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 2) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const doc = g_document orelse return quickjs.JS_UNDEFINED();

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

// ── outerHTML getter ────────────────────────────────────────────────

fn elementGetOuterHTML(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return qjs.JS_NewStringLen(c, "", 0);
    var stack_buf: [8192]u8 = undefined;
    var accum = SerializeAccum.init(&stack_buf);
    defer accum.deinit();
    _ = lxb_html_serialize_tree_cb(node, &serializeCallback, @ptrCast(&accum));
    const result = accum.result();
    return qjs.JS_NewStringLen(c, result.ptr, result.len);
}

// ── outerHTML setter ────────────────────────────────────────────────

fn elementSetOuterHTML(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    const parent_node = node.parent orelse return quickjs.JS_UNDEFINED();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, s.ptr);

    // Parse the HTML fragment using parent element as context
    const doc = g_document orelse return quickjs.JS_UNDEFINED();
    const parent_elem: *lxb.lxb_dom_element_t = @ptrCast(parent_node);
    const frag = lxb_html_document_parse_fragment(doc, parent_elem, s.ptr, s.len) orelse return quickjs.JS_UNDEFINED();

    // Insert parsed nodes before the current element
    while (frag.first_child) |child| {
        lxb_dom_node_remove(child);
        lxb_dom_node_insert_before(node, child);
    }
    _ = lxb_dom_node_destroy(frag);

    // Remove the current element
    lxb_dom_node_remove(node);
    _ = lxb_dom_node_destroy(node);

    events.recordMutation(parent_node, "childList", null, null, null);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

// ── element.style (CSSStyleDeclaration) ─────────────────────────────

/// Parse the style attribute string and get a specific property value.
fn getStyleProperty(style_str: []const u8, css_prop: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < style_str.len) {
        // Skip whitespace
        while (pos < style_str.len and (style_str[pos] == ' ' or style_str[pos] == '\t' or style_str[pos] == '\n')) pos += 1;
        if (pos >= style_str.len) break;
        // Find property name
        const prop_start = pos;
        while (pos < style_str.len and style_str[pos] != ':' and style_str[pos] != ';') pos += 1;
        if (pos >= style_str.len or style_str[pos] != ':') break;
        const prop_name = std.mem.trim(u8, style_str[prop_start..pos], " \t\n");
        pos += 1; // skip ':'
        // Find value
        const val_start = pos;
        while (pos < style_str.len and style_str[pos] != ';') pos += 1;
        const val = std.mem.trim(u8, style_str[val_start..pos], " \t\n");
        if (pos < style_str.len) pos += 1; // skip ';'

        if (std.ascii.eqlIgnoreCase(prop_name, css_prop)) return val;
    }
    return null;
}

/// Set a property in a style string, returning a new string in the provided buffer.
fn setStyleProperty(style_str: []const u8, css_prop: []const u8, css_val: []const u8, buf: []u8) ?[]const u8 {
    var out_pos: usize = 0;
    var found = false;

    // Copy existing properties, replacing the target one
    var iter_pos: usize = 0;
    while (iter_pos < style_str.len) {
        // Skip whitespace
        while (iter_pos < style_str.len and (style_str[iter_pos] == ' ' or style_str[iter_pos] == '\t')) iter_pos += 1;
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

        if (std.ascii.eqlIgnoreCase(prop_name, css_prop)) {
            found = true;
            if (css_val.len == 0) continue; // remove property
            // Write replacement
            const needed = prop_name.len + 2 + css_val.len + 2; // "prop: val; "
            if (out_pos + needed > buf.len) return null;
            @memcpy(buf[out_pos..][0..prop_name.len], prop_name);
            out_pos += prop_name.len;
            buf[out_pos] = ':';
            out_pos += 1;
            buf[out_pos] = ' ';
            out_pos += 1;
            @memcpy(buf[out_pos..][0..css_val.len], css_val);
            out_pos += css_val.len;
            buf[out_pos] = ';';
            out_pos += 1;
            buf[out_pos] = ' ';
            out_pos += 1;
        } else {
            // Copy existing property as-is
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
    }
    if (!found and css_val.len > 0) {
        // Append new property
        const needed = css_prop.len + 2 + css_val.len + 1;
        if (out_pos + needed > buf.len) return null;
        @memcpy(buf[out_pos..][0..css_prop.len], css_prop);
        out_pos += css_prop.len;
        buf[out_pos] = ':';
        out_pos += 1;
        buf[out_pos] = ' ';
        out_pos += 1;
        @memcpy(buf[out_pos..][0..css_val.len], css_val);
        out_pos += css_val.len;
        buf[out_pos] = ';';
        out_pos += 1;
    }

    // Trim trailing space
    if (out_pos > 0 and buf[out_pos - 1] == ' ') out_pos -= 1;
    return buf[0..out_pos];
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
fn reconstructBoxShorthandJSWithElem(c: *qjs.JSContext, style_str: []const u8, shorthand: []const u8, elem_val: qjs.JSValue) ?qjs.JSValue {
    const longhands = getBoxLonghands(shorthand) orelse return null;
    const top_raw = getStyleProperty(style_str, longhands[0]) orelse return null;
    const right_raw = getStyleProperty(style_str, longhands[1]) orelse return null;
    const bottom_raw = getStyleProperty(style_str, longhands[2]) orelse return null;
    const left_raw = getStyleProperty(style_str, longhands[3]) orelse return null;

    // If elem_val is provided and this is a length shorthand, resolve each value
    const has_elem = !quickjs.JS_IsUndefined(elem_val);
    if (has_elem and (eqlIgnoreCase(shorthand, "margin") or eqlIgnoreCase(shorthand, "padding"))) {
        const font_size = getElementFontSizeFromStyle(c, elem_val);
        const cb_width = getContainingBlockWidth(c, elem_val);
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
            return fmtBoxShorthand(c, resolved[0], resolved[1], resolved[2], resolved[3], &buf);
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
fn getLonghandFromShorthand(style_str: []const u8, longhand: []const u8) ?[]const u8 {
    const info = getShorthandInfoForLonghand(longhand) orelse return null;
    const shorthand_val = getStyleProperty(style_str, info.shorthand) orelse return null;

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
    if (eqlIgnoreCase(val, "none")) return "none";
    if (eqlIgnoreCase(val, "block")) return "block";
    if (eqlIgnoreCase(val, "inline")) return "inline";
    // Preserve input order for shorthand combos
    if (eqlIgnoreCase(val, "block inline")) return "block inline";
    if (eqlIgnoreCase(val, "inline block")) return "inline block";
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
        if (eqlIgnoreCase(kw, "block-start")) bs = true
        else if (eqlIgnoreCase(kw, "block-end")) be = true
        else if (eqlIgnoreCase(kw, "inline-start")) is_ = true
        else if (eqlIgnoreCase(kw, "inline-end")) ie = true
        else if (eqlIgnoreCase(kw, "block")) { bs = true; be = true; }
        else if (eqlIgnoreCase(kw, "inline")) { is_ = true; ie = true; }
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
    _ = qjs.JS_DefinePropertyGetSet(ctx, obj, cssTextAtom, qjs.JS_NewCFunction(ctx, &styleGetCssText, "get cssText", 0), qjs.JS_NewCFunction(ctx, &styleSetCssText, "set cssText", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
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
        if (!isValidCssValue(prop, val)) return quickjs.JS_UNDEFINED();
    }

    // Canonicalize CSS values for canonical serialization
    // CSS spec: unitless 0 → "0px" for length properties
    const trimmed_val2 = std.mem.trim(u8, val, " \t\r\n");
    const zero_px = "0px";
    var calc_buf: [512]u8 = undefined;
    const effective_val = if (std.mem.eql(u8, trimmed_val2, "0") and isComputedLengthProperty(prop))
        zero_px
    else if (eqlIgnoreCase(prop, "display"))
        canonicalizeDisplayValue(val)
    else if (val.len >= 5 and eqlIgnoreCase(val[0..5], "calc("))
        canonicalizeCalcValue(val, &calc_buf) orelse val
    else if (val.len >= 4 and (eqlIgnoreCase(val[0..4], "min(") or eqlIgnoreCase(val[0..4], "max(")))
        canonicalizeSingleArgMath(val, &calc_buf) orelse val
    else if (val.len >= 6 and eqlIgnoreCase(val[0..6], "clamp("))
        canonicalizeClamp(val, &calc_buf) orelse val
    else if (val.len >= 6 and eqlIgnoreCase(val[0..6], "round("))
        canonicalizeRoundModRem(val, &calc_buf) orelse val
    else if (val.len >= 4 and eqlIgnoreCase(val[0..4], "mod("))
        canonicalizeRoundModRem(val, &calc_buf) orelse val
    else if (val.len >= 4 and eqlIgnoreCase(val[0..4], "rem("))
        canonicalizeRoundModRem(val, &calc_buf) orelse val
    else
        val;

    var style_len: usize = 0;
    const style_ptr = lxb_dom_element_get_attribute(elem, "style", 5, &style_len);
    const current_style = if (style_ptr != null and style_len > 0) style_ptr.?[0..style_len] else "";

    // margin-trim value normalization (block-start block-end → block)
    if (eqlIgnoreCase(prop, "margin-trim")) {
        const trimmed_val = std.mem.trim(u8, val, " \t\r\n");
        if (trimmed_val.len > 0 and !eqlIgnoreCase(trimmed_val, "inherit") and
            !eqlIgnoreCase(trimmed_val, "initial") and !eqlIgnoreCase(trimmed_val, "unset") and
            !eqlIgnoreCase(trimmed_val, "revert"))
        {
            const normalized = normalizeMarginTrim(trimmed_val);
            var buf: [4096]u8 = undefined;
            if (setStyleProperty(current_style, prop, normalized, &buf)) |new_style| {
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
        if (eqlIgnoreCase(trimmed_val, "inherit") or eqlIgnoreCase(trimmed_val, "initial") or
            eqlIgnoreCase(trimmed_val, "unset") or eqlIgnoreCase(trimmed_val, "revert"))
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
    if (setStyleProperty(current_style, prop, effective_val, &buf)) |new_style| {
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
    if (getStyleProperty(style, prop)) |val| {
        // For element.style (specified value), color keywords stay as keywords
        // per CSSOM §6.7.2 and CSS Color Level 4 §15
        if (isColorProperty(prop)) {
            const tv = std.mem.trim(u8, val, " \t\r\n");
            // Named colors, transparent, currentcolor → return lowercase as-is
            // Check if it's a named color keyword (not a function like rgb(...))
            const is_keyword = blk: {
                if (eqlIgnoreCase(tv, "transparent") or eqlIgnoreCase(tv, "currentcolor")) break :blk true;
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
            if (tv.len >= 6 and eqlIgnoreCase(tv[0..6], "color(")) {
                return formatColorFuncComputed(c, tv);
            }
            if (color_mod.parseColor(tv)) |color| {
                var color_buf: [64]u8 = undefined;
                // Clamp alpha to [0, 1] range
                const clamped_a = if (color.a > 255) @as(u8, 255) else color.a;
                if (clamped_a == 255) {
                    const s = std.fmt.bufPrint(&color_buf, "rgb({d}, {d}, {d})", .{ color.r, color.g, color.b }) catch return qjs.JS_NewStringLen(c, val.ptr, val.len);
                    return qjs.JS_NewStringLen(c, s.ptr, s.len);
                } else {
                    const orig_alpha = extractOriginalAlpha(tv);
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
        const top_v = getStyleProperty(style, longhands[0]) orelse return qjs.JS_NewStringLen(c, "", 0);
        const right_v = getStyleProperty(style, longhands[1]) orelse return qjs.JS_NewStringLen(c, "", 0);
        const bottom_v = getStyleProperty(style, longhands[2]) orelse return qjs.JS_NewStringLen(c, "", 0);
        const left_v = getStyleProperty(style, longhands[3]) orelse return qjs.JS_NewStringLen(c, "", 0);
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
        if (getStyleProperty(current_style, prop)) |ov| {
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
    const old_val = getStyleProperty(current_style, prop);

    var buf: [4096]u8 = undefined;
    if (setStyleProperty(current_style, prop, "", &buf)) |new_style| {
        _ = lxb_dom_element_set_attribute(elem, "style", 5, new_style.ptr, new_style.len);
        setDomDirty();
    }

    if (old_val) |ov| {
        return qjs.JS_NewStringLen(c, ov.ptr, ov.len);
    }
    return qjs.JS_NewStringLen(c, "", 0);
}

fn styleGetCssText(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return qjs.JS_NewStringLen(c, "", 0);
    var style_len: usize = 0;
    const style_ptr = lxb_dom_element_get_attribute(elem, "style", 5, &style_len);
    if (style_ptr == null or style_len == 0) return qjs.JS_NewStringLen(c, "", 0);
    return qjs.JS_NewStringLen(c, style_ptr.?, style_len);
}

fn styleSetCssText(
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
    _ = lxb_dom_element_set_attribute(elem, "style", 5, s.ptr, s.len);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
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

// ── element.hasAttribute ────────────────────────────────────────────

fn elementHasAttribute(
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

// ── element.remove() ────────────────────────────────────────────────

fn elementRemove(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    if (node.parent != null) {
        lxb_dom_node_remove(node);
        setDomDirty();
    }
    return quickjs.JS_UNDEFINED();
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
            _ = lxb.lxb_dom_node_insert_child(parent, cn);
        } else if (qjs.JS_IsString(args[i])) {
            // String argument: create text node and append
            const s = jsStringToSlice(c, args[i]) orelse continue;
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
            if (first_child) |fc| {
                _ = lxb.lxb_dom_node_insert_before(fc, cn);
            } else {
                _ = lxb.lxb_dom_node_insert_child(parent, cn);
            }
        }
    }
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

// ── element.toggleAttribute / getAttributeNames / scrollIntoView ────

fn elementToggleAttribute(
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

fn elementGetAttributeNames(
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

            // Create Attr-like object
            const attr_obj = qjs.JS_NewObject(c);
            _ = qjs.JS_SetPropertyStr(c, attr_obj, "name", qjs.JS_NewStringLen(c, name_str.ptr, name_str.len));
            _ = qjs.JS_SetPropertyStr(c, attr_obj, "value", qjs.JS_NewStringLen(c, val_str.ptr, val_str.len));
            _ = qjs.JS_SetPropertyStr(c, attr_obj, "nodeName", qjs.JS_NewStringLen(c, name_str.ptr, name_str.len));
            _ = qjs.JS_SetPropertyStr(c, attr_obj, "nodeValue", qjs.JS_NewStringLen(c, val_str.ptr, val_str.len));
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

fn elementGetContext(
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

fn elementScrollIntoView(
    _: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    // Stub — actual scroll-to-element requires layout position lookup
    return quickjs.JS_UNDEFINED();
}

fn documentCreateComment(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    const doc = g_document orelse return quickjs.JS_NULL();

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

fn documentAdoptNode(
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

/// document.implementation.createDocumentType(qualifiedName, publicId, systemId)
fn implCreateDocumentType(
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
fn implCreateDocument(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    _ = argc;
    _ = argv;
    // Return a minimal document-like object via JS eval
    const js = "(document.implementation.createHTMLDocument(''))";
    return qjs.JS_Eval(c, js, js.len, "<createDoc>", qjs.JS_EVAL_TYPE_GLOBAL);
}

fn documentImportNode(
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

fn documentCreateRange(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    const range = qjs.JS_NewObject(c);
    _ = qjs.JS_SetPropertyStr(c, range, "startOffset", qjs.JS_NewInt32(c, 0));
    _ = qjs.JS_SetPropertyStr(c, range, "endOffset", qjs.JS_NewInt32(c, 0));
    _ = qjs.JS_SetPropertyStr(c, range, "collapsed", quickjs.JS_NewBool(true));
    _ = qjs.JS_SetPropertyStr(c, range, "setStart", qjs.JS_NewCFunction(c, &jsReturnNull, "setStart", 2));
    _ = qjs.JS_SetPropertyStr(c, range, "setEnd", qjs.JS_NewCFunction(c, &jsReturnNull, "setEnd", 2));
    _ = qjs.JS_SetPropertyStr(c, range, "selectNode", qjs.JS_NewCFunction(c, &jsReturnNull, "selectNode", 1));
    _ = qjs.JS_SetPropertyStr(c, range, "selectNodeContents", qjs.JS_NewCFunction(c, &jsReturnNull, "selectNodeContents", 1));
    _ = qjs.JS_SetPropertyStr(c, range, "collapse", qjs.JS_NewCFunction(c, &jsReturnNull, "collapse", 1));
    _ = qjs.JS_SetPropertyStr(c, range, "cloneRange", qjs.JS_NewCFunction(c, &documentCreateRange, "cloneRange", 0));
    _ = qjs.JS_SetPropertyStr(c, range, "getBoundingClientRect", qjs.JS_NewCFunction(c, &elementGetBoundingClientRect, "getBoundingClientRect", 0));
    return range;
}

fn documentCreateTreeWalker(
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
        \\(function(root, whatToShow) {
        \\  var tw = {
        \\    root: root,
        \\    currentNode: root,
        \\    whatToShow: whatToShow,
        \\    _accepts: function(node) {
        \\      if (whatToShow === -1 || whatToShow === 0xFFFFFFFF) return true;
        \\      var nt = node.nodeType;
        \\      if (nt === 1 && (whatToShow & 0x1)) return true;
        \\      if (nt === 3 && (whatToShow & 0x4)) return true;
        \\      if (nt === 8 && (whatToShow & 0x80)) return true;
        \\      if (nt === 9 && (whatToShow & 0x100)) return true;
        \\      if (nt === 11 && (whatToShow & 0x400)) return true;
        \\      return false;
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

    var call_args = [_]qjs.JSValue{
        qjs.JS_DupValue(c, root_val),
        qjs.JS_NewInt32(c, what_to_show),
    };
    const result = qjs.JS_Call(c, walker_fn, quickjs.JS_UNDEFINED(), 2, &call_args);
    qjs.JS_FreeValue(c, call_args[0]);
    qjs.JS_FreeValue(c, call_args[1]);
    return result;
}

fn jsReturnNull(
    _: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    return quickjs.JS_NULL();
}

// ── node.normalize() ────────────────────────────────────────────────
// Merge adjacent text nodes, remove empty text nodes.

fn nodeNormalize(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();

    normalizeNode(node);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

/// Internal normalize helper that works directly on DOM nodes (no JS context needed).
fn normalizeNode(node: *lxb.lxb_dom_node_t) void {
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        if (ch.type == lxb.LXB_DOM_NODE_TYPE_TEXT) {
            var text_len: usize = 0;
            const text_ptr = lxb_dom_node_text_content(ch, &text_len);

            if (text_len == 0 or text_ptr == null) {
                const next_sib: ?*lxb.lxb_dom_node_t = ch.next;
                lxb_dom_node_remove(ch);
                _ = lxb_dom_node_destroy(ch);
                child = next_sib;
                continue;
            }

            var next_node: ?*lxb.lxb_dom_node_t = ch.next;
            while (next_node) |next| {
                if (next.type != lxb.LXB_DOM_NODE_TYPE_TEXT) break;
                var next_len: usize = 0;
                const next_ptr = lxb_dom_node_text_content(next, &next_len);
                const after: ?*lxb.lxb_dom_node_t = next.next;
                if (next_len == 0 or next_ptr == null) {
                    lxb_dom_node_remove(next);
                    _ = lxb_dom_node_destroy(next);
                    next_node = after;
                    continue;
                }
                var merge_buf: [16384]u8 = undefined;
                const total = text_len + next_len;
                if (total <= merge_buf.len) {
                    @memcpy(merge_buf[0..text_len], text_ptr.?[0..text_len]);
                    @memcpy(merge_buf[text_len..][0..next_len], next_ptr.?[0..next_len]);
                    _ = lxb_dom_node_text_content_set(ch, &merge_buf, total);
                    text_len = total;
                    lxb_dom_node_remove(next);
                    _ = lxb_dom_node_destroy(next);
                } else {
                    // Buffer too small — stop merging this run to avoid data loss
                    break;
                }
                next_node = after;
            }
            child = ch.next;
        } else {
            if (ch.first_child != null) normalizeNode(ch);
            child = ch.next;
        }
    }
}

fn nodeIsEqualNode(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NewBool(false);
    if (argc < 1) return quickjs.JS_NewBool(false);
    const args = argv orelse return quickjs.JS_NewBool(false);
    const node_a = getNode(c, this_val) orelse return quickjs.JS_NewBool(false);
    const node_b = getNode(c, args[0]) orelse return quickjs.JS_NewBool(false);
    return quickjs.JS_NewBool(nodesAreEqual(node_a, node_b));
}

/// DOM Standard §4.4: Structural equality check for isEqualNode
fn nodesAreEqual(a: *lxb.lxb_dom_node_t, b: *lxb.lxb_dom_node_t) bool {
    // Same pointer = trivially equal
    if (a == b) return true;
    // nodeType must match
    if (a.type != b.type) return false;

    if (a.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
        const ea: *lxb.lxb_dom_element_t = @ptrCast(a);
        const eb: *lxb.lxb_dom_element_t = @ptrCast(b);
        // Compare localName
        var la_len: usize = 0;
        var lb_len: usize = 0;
        const la = lxb_dom_element_local_name(ea, &la_len);
        const lb = lxb_dom_element_local_name(eb, &lb_len);
        if (la_len != lb_len) return false;
        if (la != null and lb != null) {
            if (!std.mem.eql(u8, la.?[0..la_len], lb.?[0..lb_len])) return false;
        }
        // Compare number of attributes (simplified — count via walking)
        var attr_count_a: usize = 0;
        var attr_count_b: usize = 0;
        {
            // Count attributes of a
            const style_a_ptr = lxb_dom_element_get_attribute(ea, "id", 2, &la_len);
            _ = style_a_ptr;
            // Simplified: use attribute count from lexbor (not directly available)
            // For now, skip attribute count check (partial isEqualNode)
            _ = &attr_count_a;
            _ = &attr_count_b;
        }
    } else if (a.type == lxb.LXB_DOM_NODE_TYPE_TEXT or a.type == lxb.LXB_DOM_NODE_TYPE_COMMENT) {
        // Compare text content
        var ta_len: usize = 0;
        var tb_len: usize = 0;
        const ta = lxb_dom_node_text_content(a, &ta_len);
        const tb = lxb_dom_node_text_content(b, &tb_len);
        if (ta_len != tb_len) return false;
        if (ta != null and tb != null) {
            if (!std.mem.eql(u8, ta.?[0..ta_len], tb.?[0..tb_len])) return false;
        }
    }

    // Compare children recursively using DOM node wrapper
    const dom_node = @import("../dom/node.zig");
    const da = dom_node.DomNode{ .lxb_node = a };
    const db = dom_node.DomNode{ .lxb_node = b };
    var child_a = da.firstChild();
    var child_b = db.firstChild();
    while (child_a != null and child_b != null) {
        if (!nodesAreEqual(child_a.?.lxb_node, child_b.?.lxb_node)) return false;
        child_a = child_a.?.nextSibling();
        child_b = child_b.?.nextSibling();
    }
    return child_a == null and child_b == null;
}

fn nodeCompareDocumentPosition(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return qjs.JS_NewInt32(c, 0);
    const args = argv orelse return qjs.JS_NewInt32(c, 0);
    const node_a = getNode(c, this_val) orelse return qjs.JS_NewInt32(c, 1);
    const node_b = getNode(c, args[0]) orelse return qjs.JS_NewInt32(c, 1);
    if (node_a == node_b) return qjs.JS_NewInt32(c, 0);
    // Simplified: check if b is descendant of a, or vice versa
    var walk: ?*lxb.lxb_dom_node_t = node_b;
    while (walk) |w| {
        if (w == node_a) return qjs.JS_NewInt32(c, 16 | 4); // CONTAINS | FOLLOWING
        walk = w.parent;
    }
    walk = node_a;
    while (walk) |w| {
        if (w == node_b) return qjs.JS_NewInt32(c, 8 | 2); // CONTAINED_BY | PRECEDING
        walk = w.parent;
    }
    return qjs.JS_NewInt32(c, 1); // DISCONNECTED
}

// ── node.getRootNode() ──────────────────────────────────────────────

fn nodeGetRootNode(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    // Walk up to root (document node)
    var current: *lxb.lxb_dom_node_t = node;
    while (current.parent) |p| {
        current = p;
    }
    // If root is document node, return the JS document object
    if (current.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT) {
        const global = qjs.JS_GetGlobalObject(c);
        defer qjs.JS_FreeValue(c, global);
        return qjs.JS_GetPropertyStr(c, global, "document");
    }
    // Otherwise return the root element
    return wrapNode(c, current);
}

// ── node.ownerDocument ──────────────────────────────────────────────

fn nodeGetOwnerDocument(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    // Return the global document object
    const global = qjs.JS_GetGlobalObject(c);
    defer qjs.JS_FreeValue(c, global);
    return qjs.JS_GetPropertyStr(c, global, "document");
}

// ── node.isConnected ────────────────────────────────────────────────

fn nodeGetIsConnected(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NewBool(false);
    const node = getNode(c, this_val) orelse return quickjs.JS_NewBool(false);
    // Walk up to root — if root is document, node is connected
    var current: *lxb.lxb_dom_node_t = node;
    while (current.parent) |p| {
        current = p;
    }
    return quickjs.JS_NewBool(current.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT);
}

// ── element.contains(other) ─────────────────────────────────────────

fn elementContains(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NewBool(false);
    if (argc < 1) return quickjs.JS_NewBool(false);
    const args = argv orelse return quickjs.JS_NewBool(false);
    const node = getNode(c, this_val) orelse return quickjs.JS_NewBool(false);
    const other = getNode(c, args[0]) orelse return quickjs.JS_NewBool(false);

    // Walk up from other to see if we find node
    var cur: ?*lxb.lxb_dom_node_t = other;
    while (cur) |n| {
        if (n == node) return quickjs.JS_NewBool(true);
        cur = n.parent;
    }
    return quickjs.JS_NewBool(false);
}

// ── element.matches(selector) ───────────────────────────────────────

fn elementMatchesSelector(node: *lxb.lxb_dom_node_t, selector: []const u8) bool {
    if (selector.len == 0) return false;
    if (node.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return false;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);

    const sel = std.mem.trim(u8, selector, " \t\r\n");
    if (sel.len == 0) return false;

    // Handle comma-separated selector list (any match = true)
    var start: usize = 0;
    var depth: usize = 0;
    for (sel, 0..) |ch, i| {
        if (ch == '(' or ch == '[') depth += 1
        else if ((ch == ')' or ch == ']') and depth > 0) depth -= 1
        else if (ch == ',' and depth == 0) {
            if (matchSingleSimple(elem, std.mem.trim(u8, sel[start..i], " \t"))) return true;
            start = i + 1;
        }
    }
    return matchSingleSimple(elem, std.mem.trim(u8, sel[start..], " \t"));
}

fn matchSingleSimple(elem: *lxb.lxb_dom_element_t, sel: []const u8) bool {
    if (sel.len == 0) return false;

    // :not(inner) — negate inner match
    if (sel.len > 5 and std.ascii.eqlIgnoreCase(sel[0..5], ":not(") and sel[sel.len - 1] == ')') {
        return !elementMatchesSelector(@ptrCast(elem), sel[5 .. sel.len - 1]);
    }
    // :is(inner) / :where(inner) — OR of comma-separated
    if (sel.len > 4 and std.ascii.eqlIgnoreCase(sel[0..4], ":is(") and sel[sel.len - 1] == ')') {
        return elementMatchesSelector(@ptrCast(elem), sel[4 .. sel.len - 1]);
    }
    if (sel.len > 7 and std.ascii.eqlIgnoreCase(sel[0..7], ":where(") and sel[sel.len - 1] == ')') {
        return elementMatchesSelector(@ptrCast(elem), sel[7 .. sel.len - 1]);
    }

    // [attr] or [attr=value] etc.
    if (sel[0] == '[') {
        if (std.mem.indexOfScalar(u8, sel, ']')) |close| {
            const attr_expr = sel[1..close];
            return matchAttributeSelector(elem, attr_expr);
        }
        return false;
    }
    // #id
    if (sel[0] == '#') {
        var val_len: usize = 0;
        const val = lxb_dom_element_get_attribute(elem, "id", 2, &val_len);
        if (val != null and val_len == sel.len - 1) {
            return std.mem.eql(u8, val.?[0..val_len], sel[1..]);
        }
        return false;
    }
    // .class
    if (sel[0] == '.') {
        var val_len: usize = 0;
        const val = lxb_dom_element_get_attribute(elem, "class", 5, &val_len);
        if (val != null and val_len > 0) {
            return classContains(val.?[0..val_len], sel[1..]);
        }
        return false;
    }
    // * (universal)
    if (sel.len == 1 and sel[0] == '*') return true;

    // Compound: tag.class or tag#id
    if (std.mem.indexOfScalar(u8, sel, '.')) |dot| {
        if (dot > 0) {
            // tag.class
            var name_len: usize = 0;
            const name_ptr = lxb_dom_element_local_name(elem, &name_len);
            if (name_ptr == null or !std.ascii.eqlIgnoreCase(name_ptr.?[0..name_len], sel[0..dot])) return false;
            var val_len: usize = 0;
            const val = lxb_dom_element_get_attribute(elem, "class", 5, &val_len);
            if (val != null and val_len > 0) return classContains(val.?[0..val_len], sel[dot + 1 ..]);
            return false;
        }
    }
    if (std.mem.indexOfScalar(u8, sel, '#')) |hash| {
        if (hash > 0) {
            var name_len: usize = 0;
            const name_ptr = lxb_dom_element_local_name(elem, &name_len);
            if (name_ptr == null or !std.ascii.eqlIgnoreCase(name_ptr.?[0..name_len], sel[0..hash])) return false;
            var val_len: usize = 0;
            const val = lxb_dom_element_get_attribute(elem, "id", 2, &val_len);
            if (val != null and val_len == sel.len - hash - 1) return std.mem.eql(u8, val.?[0..val_len], sel[hash + 1 ..]);
            return false;
        }
    }

    // Plain tagname
    var name_len: usize = 0;
    const name_ptr = lxb_dom_element_local_name(elem, &name_len);
    if (name_ptr != null) {
        return std.ascii.eqlIgnoreCase(name_ptr.?[0..name_len], sel);
    }
    return false;
}

fn matchAttributeSelector(elem: *lxb.lxb_dom_element_t, expr: []const u8) bool {
    // [attr], [attr=val], [attr^=val], [attr$=val], [attr*=val], [attr~=val]
    const trimmed = std.mem.trim(u8, expr, " \t");
    // Find operator
    var op_pos: ?usize = null;
    var op_type: u8 = 0; // 0=exists, '='=exact, '^'=starts, '$'=ends, '*'=contains, '~'=word
    for (trimmed, 0..) |ch, i| {
        if (ch == '=' and i > 0) {
            if (trimmed[i - 1] == '^' or trimmed[i - 1] == '$' or trimmed[i - 1] == '*' or trimmed[i - 1] == '~' or trimmed[i - 1] == '|') {
                op_pos = i - 1;
                op_type = trimmed[i - 1];
            } else {
                op_pos = i;
                op_type = '=';
            }
            break;
        }
    }
    if (op_pos == null) {
        // [attr] — existence check
        var val_len: usize = 0;
        _ = lxb_dom_element_get_attribute(elem, trimmed.ptr, trimmed.len, &val_len);
        return lxb_dom_element_has_attribute(elem, trimmed.ptr, trimmed.len);
    }
    const attr_name = std.mem.trim(u8, trimmed[0..op_pos.?], " \t");
    const val_start = if (op_type == '=') op_pos.? + 1 else op_pos.? + 2;
    var expected = std.mem.trim(u8, trimmed[val_start..], " \t");
    // Strip quotes
    if (expected.len >= 2 and (expected[0] == '"' or expected[0] == '\'') and expected[expected.len - 1] == expected[0]) {
        expected = expected[1 .. expected.len - 1];
    }
    var val_len: usize = 0;
    const val = lxb_dom_element_get_attribute(elem, attr_name.ptr, attr_name.len, &val_len);
    if (val == null) return false;
    const actual = val.?[0..val_len];

    return switch (op_type) {
        '=' => std.mem.eql(u8, actual, expected),
        '^' => actual.len >= expected.len and std.mem.eql(u8, actual[0..expected.len], expected),
        '$' => actual.len >= expected.len and std.mem.eql(u8, actual[actual.len - expected.len ..], expected),
        '*' => std.mem.indexOf(u8, actual, expected) != null,
        '~' => classContains(actual, expected),
        else => false,
    };
}

fn elementMatches(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NewBool(false);
    if (argc < 1) return quickjs.JS_NewBool(false);
    const args = argv orelse return quickjs.JS_NewBool(false);
    const node = getNode(c, this_val) orelse return quickjs.JS_NewBool(false);
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NewBool(false);
    defer qjs.JS_FreeCString(c, s.ptr);
    return quickjs.JS_NewBool(elementMatchesSelector(node, s.ptr[0..s.len]));
}

// ── element.closest(selector) ───────────────────────────────────────

fn elementClosest(
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
    const sel = s.ptr[0..s.len];

    // Walk up from this element
    var cur: ?*lxb.lxb_dom_node_t = node;
    while (cur) |n| {
        if (elementMatchesSelector(n, sel)) return wrapNode(c, n);
        cur = n.parent;
    }
    return quickjs.JS_NULL();
}

// ── element.cloneNode(deep) ─────────────────────────────────────────

fn elementCloneNode(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();

    // Determine deep flag (default: shallow clone per DOM spec)
    var deep = false;
    if (argc > 0) {
        if (argv) |args| {
            deep = qjs.JS_ToBool(c, args[0]) > 0;
        }
    }

    // Text/Comment/PI nodes: create new node with same data
    if (node.type == lxb.LXB_DOM_NODE_TYPE_TEXT) {
        const doc = g_document orelse return quickjs.JS_NULL();
        var len: usize = 0;
        const txt = lxb_dom_node_text_content(node, &len);
        const new_text = lxb_dom_document_create_text_node(doc, if (txt) |t| t else "", if (txt != null) len else 0) orelse return quickjs.JS_NULL();
        return wrapNode(c, new_text);
    }
    if (node.type == lxb.LXB_DOM_NODE_TYPE_COMMENT) {
        const doc = g_document orelse return quickjs.JS_NULL();
        var len: usize = 0;
        const txt = lxb_dom_node_text_content(node, &len);
        const new_comment = lxb_dom_document_create_comment(doc, if (txt) |t| t else "", if (txt != null) len else 0) orelse return quickjs.JS_NULL();
        return wrapNode(c, new_comment);
    }

    // Element nodes: clone by serializing and re-parsing
    if (node.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return quickjs.JS_NULL();

    var stack_buf: [8192]u8 = undefined;
    var accum = SerializeAccum.init(&stack_buf);
    defer accum.deinit();

    if (deep) {
        _ = lxb_html_serialize_tree_cb(node, &serializeCallback, @ptrCast(&accum));
    } else {
        _ = lxb_html_serialize_cb(node, &serializeCallback, @ptrCast(&accum));
    }

    const html = accum.result();
    if (html.len == 0) return quickjs.JS_NULL();

    const doc = g_document orelse return quickjs.JS_NULL();
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    const frag = lxb_html_document_parse_fragment(doc, elem, html.ptr, html.len) orelse return quickjs.JS_NULL();

    // Get the first child from fragment (the cloned element)
    if (frag.first_child) |cloned| {
        lxb_dom_node_remove(cloned);
        _ = lxb_dom_node_destroy(frag);
        return wrapNode(c, cloned);
    }
    _ = lxb_dom_node_destroy(frag);
    return quickjs.JS_NULL();
}

// ── element.replaceWith(newNode) ────────────────────────────────────

fn elementReplaceWith(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const new_node = getNode(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    if (node.parent == null) return quickjs.JS_UNDEFINED();
    lxb_dom_node_insert_before(node, new_node);
    lxb_dom_node_remove(node);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

// ── element.before(node) / element.after(node) ─────────────────────

fn elementBefore(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const new_node = getNode(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    if (node.parent == null) return quickjs.JS_UNDEFINED();
    lxb_dom_node_insert_before(node, new_node);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

fn elementAfter(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const new_node = getNode(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    if (node.parent == null) return quickjs.JS_UNDEFINED();
    lxb_dom_node_insert_after(node, new_node);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

// ── element.dataset ─────────────────────────────────────────────────
// Minimal implementation: returns an object whose properties map to data-* attributes.
// We use a getter that creates a Proxy-like object with get/set traps via JS eval.

fn elementGetDataset(
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

fn datasetGet(
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

fn datasetSet(
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

fn camelToDataAttr(key: []const u8, buf: []u8) ?[]const u8 {
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

// ── Element querySelector/querySelectorAll on element scope ─────────

fn elementQuerySelector(
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

    const found = walkTreeBySelector(node, s.ptr[0..s.len]) orelse return quickjs.JS_NULL();
    return wrapNode(c, found);
}

fn elementQuerySelectorAll(
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
    walkTreeCollect(c, node, s.ptr[0..s.len], arr, &idx);
    return arr;
}

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
    walkTreeCollect(c, node, selector, arr, &idx);
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
    walkTreeCollect(c, node, s.ptr[0..s.len], arr, &idx);
    return arr;
}

// ── Element geometry (stub — returns 0 without layout) ──────────────

/// Helper: get Box dimensions for the element attached to this_val.
fn getBoxForThis(ctx: *qjs.JSContext, this_val: qjs.JSValue) ?*const Box {
    const root = g_root_box orelse return null;
    const node = getNodeFromThis(ctx, this_val) orelse return null;
    return findBoxForNode(root, node);
}

fn getNodeFromThis(ctx: *qjs.JSContext, this_val: qjs.JSValue) ?*lxb.lxb_dom_node_t {
    // Try element class first, then text class
    const ptr1 = qjs.JS_GetOpaque2(ctx, this_val, element_class_id);
    if (ptr1) |p| return @ptrCast(@alignCast(p));
    const ptr2 = qjs.JS_GetOpaque2(ctx, this_val, text_class_id);
    if (ptr2) |p| return @ptrCast(@alignCast(p));
    return null;
}

fn elementGetClientWidth(
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

fn elementGetClientHeight(
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

fn elementGetClientTop(
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

fn elementGetClientLeft(
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

fn elementGetOffsetWidth(
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

fn elementGetOffsetHeight(
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

fn elementGetOffsetTop(
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

fn elementGetOffsetLeft(
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

fn elementGetBoundingClientRect(
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

fn elementGetScrollTop(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewInt32(c, @intFromFloat(scroll_y));
}

fn elementGetScrollLeft(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewInt32(c, @intFromFloat(scroll_x));
}

// ── element.nodeType ────────────────────────────────────────────────

fn elementGetNodeType(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return qjs.JS_NewInt32(c, 1);
    return switch (node.type) {
        lxb.LXB_DOM_NODE_TYPE_ELEMENT => qjs.JS_NewInt32(c, 1),
        lxb.LXB_DOM_NODE_TYPE_TEXT => qjs.JS_NewInt32(c, 3),
        lxb.LXB_DOM_NODE_TYPE_COMMENT => qjs.JS_NewInt32(c, 8),
        lxb.LXB_DOM_NODE_TYPE_DOCUMENT => qjs.JS_NewInt32(c, 9),
        lxb.LXB_DOM_NODE_TYPE_DOCUMENT_FRAGMENT => qjs.JS_NewInt32(c, 11),
        else => qjs.JS_NewInt32(c, 1),
    };
}

// ── element.nodeName ────────────────────────────────────────────────

fn elementGetNodeName(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return qjs.JS_NewStringLen(c, "", 0);
    if (node.type == lxb.LXB_DOM_NODE_TYPE_TEXT) return qjs.JS_NewStringLen(c, "#text", 5);
    if (node.type == lxb.LXB_DOM_NODE_TYPE_COMMENT) return qjs.JS_NewStringLen(c, "#comment", 8);
    if (node.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT) return qjs.JS_NewStringLen(c, "#document", 9);
    // For elements, return tagName (uppercase)
    return elementGetTagName(ctx, this_val, argc, argv);
}

// ── document methods ────────────────────────────────────────────────

/// Iterative depth-first tree walk to find element by id (stack-safe)
fn walkTreeById(root: *lxb.lxb_dom_node_t, id: []const u8) ?*lxb.lxb_dom_node_t {
    var current: ?*lxb.lxb_dom_node_t = root;
    while (current) |node| {
        if (node.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
            var val_len: usize = 0;
            const val = lxb_dom_element_get_attribute(elem, "id", 2, &val_len);
            if (val != null and val_len == id.len) {
                if (std.mem.eql(u8, val.?[0..val_len], id)) return node;
            }
        }
        // Depth-first: try first child, then next sibling, then backtrack
        if (node.first_child) |child| {
            current = child;
        } else {
            var backtrack: ?*lxb.lxb_dom_node_t = node;
            current = null;
            while (backtrack) |bt| {
                if (bt == root) break;
                if (bt.next) |sibling| {
                    current = sibling;
                    break;
                }
                backtrack = bt.parent;
            }
        }
    }
    return null;
}

fn documentGetElementById(
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
    const found = walkTreeById(doc_node, s.ptr[0..s.len]) orelse return quickjs.JS_NULL();
    return wrapNode(c, found);
}

fn getDocumentNode() ?*lxb.lxb_dom_node_t {
    const doc = g_document orelse return null;
    return @ptrCast(@alignCast(doc));
}

fn walkTreeBySelector(node: *lxb.lxb_dom_node_t, selector: []const u8) ?*lxb.lxb_dom_node_t {
    if (selector.len == 0) return null;
    const trimmed = std.mem.trim(u8, selector, " \t");
    if (trimmed.len == 0) return null;

    // Handle comma-separated selectors at top level (not inside :not(), :is() etc.)
    {
        var depth: u32 = 0;
        var has_top_comma = false;
        for (trimmed) |ch| {
            if (ch == '(' or ch == '[') depth += 1
            else if ((ch == ')' or ch == ']') and depth > 0) depth -= 1
            else if (ch == ',' and depth == 0) { has_top_comma = true; break; }
        }
        if (has_top_comma) {
            var start: usize = 0;
            depth = 0;
            for (trimmed, 0..) |ch, idx| {
                if (ch == '(' or ch == '[') depth += 1
                else if ((ch == ')' or ch == ']') and depth > 0) depth -= 1
                else if (ch == ',' and depth == 0) {
                    const sub = std.mem.trim(u8, trimmed[start..idx], " \t");
                    if (sub.len > 0) {
                        if (walkTreeBySelector(node, sub)) |found| return found;
                    }
                    start = idx + 1;
                }
            }
            const sub = std.mem.trim(u8, trimmed[start..], " \t");
            if (sub.len > 0) {
                if (walkTreeBySelector(node, sub)) |found| return found;
            }
            return null;
        }
    }

    // Parse selector with combinators (>, +, ~, space)
    var parts_buf: [16]SelectorPart = undefined;
    const part_count = parseSelectorParts(trimmed, &parts_buf);
    if (part_count == 0) return null;
    const parts = parts_buf[0..part_count];

    var current: ?*lxb.lxb_dom_node_t = node;
    while (current) |n| {
        if (nodeMatchesCompound(n, parts)) return n;
        current = nextDfsNode(n, node);
    }
    return null;
}

/// Match a single simple selector: #id, .class, tag, tag.class, tag#id
fn walkTreeBySimpleSelector(node: *lxb.lxb_dom_node_t, selector: []const u8) ?*lxb.lxb_dom_node_t {
    if (selector.len == 0) return null;

    if (selector[0] == '#') {
        // ID selector
        return walkTreeById(node, selector[1..]);
    } else if (selector[0] == '.') {
        // Class selector
        return walkTreeByClass(node, selector[1..]);
    } else {
        // Check for tag.class or tag#id compound (e.g. "div.special")
        if (std.mem.indexOfScalar(u8, selector, '.')) |dot_idx| {
            // tag.class — find by tag first, then filter by class
            return walkTreeByTagAndClass(node, selector[0..dot_idx], selector[dot_idx + 1 ..]);
        }
        if (std.mem.indexOfScalar(u8, selector, '#')) |hash_idx| {
            // tag#id — find by id (tag is redundant but valid)
            return walkTreeById(node, selector[hash_idx + 1 ..]);
        }
        // Tag name selector
        return walkTreeByTag(node, selector);
    }
}

fn walkTreeByTagAndClass(root: *lxb.lxb_dom_node_t, tag_name: []const u8, class_name: []const u8) ?*lxb.lxb_dom_node_t {
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
        current = nextDfsNode(node, root);
    }
    return null;
}

/// Iterative depth-first next node (stack-safe tree traversal helper)
fn nextDfsNode(node: *lxb.lxb_dom_node_t, root: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t {
    if (node.first_child) |child| return child;
    var cur: ?*lxb.lxb_dom_node_t = node;
    while (cur) |c| {
        if (c == root) return null;
        if (c.next) |sibling| return sibling;
        cur = c.parent;
    }
    return null;
}

fn walkTreeByClass(root: *lxb.lxb_dom_node_t, class_name: []const u8) ?*lxb.lxb_dom_node_t {
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
        current = nextDfsNode(node, root);
    }
    return null;
}

fn walkTreeByTag(root: *lxb.lxb_dom_node_t, tag_name: []const u8) ?*lxb.lxb_dom_node_t {
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
        current = nextDfsNode(node, root);
    }
    return null;
}

fn documentQuerySelector(
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
    const found = walkTreeBySelector(doc_node, s.ptr[0..s.len]) orelse return quickjs.JS_NULL();
    return wrapNode(c, found);
}

fn documentQuerySelectorAll(
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
    walkTreeCollect(c, doc_node, s.ptr[0..s.len], arr, &idx);
    return arr;
}

fn documentGetElementsByClassName(
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
    walkTreeCollect(c, doc_node, selector_buf[0 .. 1 + class_name.len], arr, &idx);
    return arr;
}

fn documentGetElementsByTagName(
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
    walkTreeCollect(c, doc_node, s.ptr[0..s.len], arr, &idx);
    return arr;
}

fn documentGetElementsByName(
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
    walkTreeCollect(c, doc_node, selector_buf[0 .. prefix.len + name.len + suffix.len], arr, &idx);
    return arr;
}

/// Check if an element node matches a single simple selector (#id, .class, tag, tag[attr])
fn nodeMatchesSimple(node: *lxb.lxb_dom_node_t, selector: []const u8) bool {
    if (node.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return false;
    if (selector.len == 0) return false;

    // * (universal selector)
    if (selector.len == 1 and selector[0] == '*') return true;

    // :not(inner) — negate inner match
    if (selector.len > 5 and std.ascii.eqlIgnoreCase(selector[0..5], ":not(") and selector[selector.len - 1] == ')') {
        return !elementMatchesSelector(node, selector[5 .. selector.len - 1]);
    }
    // :is(inner) / :where(inner) — OR match
    if (selector.len > 4 and std.ascii.eqlIgnoreCase(selector[0..4], ":is(") and selector[selector.len - 1] == ')') {
        return elementMatchesSelector(node, selector[4 .. selector.len - 1]);
    }
    if (selector.len > 7 and std.ascii.eqlIgnoreCase(selector[0..7], ":where(") and selector[selector.len - 1] == ')') {
        return elementMatchesSelector(node, selector[7 .. selector.len - 1]);
    }

    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);

    // #id selector
    if (selector[0] == '#') {
        var val_len: usize = 0;
        const val = lxb_dom_element_get_attribute(elem, "id", 2, &val_len);
        return val != null and val_len == selector.len - 1 and
            std.mem.eql(u8, val.?[0..val_len], selector[1..]);
    }

    // .class selector
    if (selector[0] == '.') {
        var val_len: usize = 0;
        const val = lxb_dom_element_get_attribute(elem, "class", 5, &val_len);
        return val != null and val_len > 0 and classContains(val.?[0..val_len], selector[1..]);
    }

    // Find bracket position (attribute selector start)
    const bracket_idx = std.mem.indexOfScalar(u8, selector, '[');

    // Find dot position ONLY before bracket (dot inside [attr="val.ue"] is not a class)
    const dot_search_end = bracket_idx orelse selector.len;
    const dot_idx = std.mem.indexOfScalar(u8, selector[0..dot_search_end], '.');

    // Determine the tag name portion end
    const tag_end = dot_idx orelse bracket_idx orelse selector.len;

    // Check tag name (if present)
    if (tag_end > 0) {
        var name_len: usize = 0;
        const name_ptr = lxb_dom_element_local_name(elem, &name_len);
        if (name_ptr == null or name_len != tag_end or
            !std.ascii.eqlIgnoreCase(name_ptr.?[0..name_len], selector[0..tag_end])) return false;
    }

    // Check class (tag.class or tag.class[attr])
    if (dot_idx) |di| {
        const class_end = bracket_idx orelse selector.len;
        var val_len: usize = 0;
        const val = lxb_dom_element_get_attribute(elem, "class", 5, &val_len);
        if (val == null or val_len == 0 or
            !classContains(val.?[0..val_len], selector[di + 1 .. class_end])) return false;
    }

    // Check attribute selectors [attr="value"][attr2="value2"]...
    if (bracket_idx) |bi| {
        var pos: usize = bi;
        while (pos < selector.len) {
            if (selector[pos] != '[') break;
            const attr_start = pos + 1;
            const close = std.mem.indexOfScalarPos(u8, selector, attr_start, ']') orelse return false;
            const attr_inner = selector[attr_start..close];
            if (std.mem.indexOf(u8, attr_inner, "=\"")) |eq_idx| {
                const attr_name = attr_inner[0..eq_idx];
                const attr_val = std.mem.trim(u8, attr_inner[eq_idx + 2 ..], "\"'");
                var av_len: usize = 0;
                const av = lxb_dom_element_get_attribute(elem, attr_name.ptr, attr_name.len, &av_len);
                if (av == null or av_len != attr_val.len or !std.mem.eql(u8, av.?[0..av_len], attr_val)) return false;
            } else {
                var av_len: usize = 0;
                if (lxb_dom_element_get_attribute(elem, attr_inner.ptr, attr_inner.len, &av_len) == null) return false;
            }
            pos = close + 1;
        }
    }

    // If no bracket and no dot, it was a pure tag match (already checked above)
    // If bracket or dot present, all checks passed
    return true;
}

/// Combinator type between selector parts
const Combinator = enum { descendant, child, adjacent_sibling, general_sibling };

/// A parsed selector segment: simple selector + combinator to the next part
const SelectorPart = struct {
    selector: []const u8,
    combinator: Combinator, // combinator BEFORE this part (from the previous part to this one)
};

/// Parse a full CSS selector string into parts with combinators.
/// "div > .class + span ~ p" → [{div, descendant}, {.class, child}, {span, adjacent_sibling}, {p, general_sibling}]
fn parseSelectorParts(trimmed: []const u8, out: []SelectorPart) usize {
    var count: usize = 0;
    var i: usize = 0;
    var next_combinator: Combinator = .descendant;

    while (i < trimmed.len and count < out.len) {
        // Skip whitespace
        while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t')) i += 1;
        if (i >= trimmed.len) break;

        // Check for combinator tokens
        if (trimmed[i] == '>') {
            next_combinator = .child;
            i += 1;
            continue;
        } else if (trimmed[i] == '+') {
            next_combinator = .adjacent_sibling;
            i += 1;
            continue;
        } else if (trimmed[i] == '~') {
            next_combinator = .general_sibling;
            i += 1;
            continue;
        }

        // Read selector token (until space or combinator, respecting () and [])
        const start = i;
        var paren_depth: u32 = 0;
        var bracket_depth: u32 = 0;
        while (i < trimmed.len) {
            const c = trimmed[i];
            if (paren_depth == 0 and bracket_depth == 0 and
                (c == ' ' or c == '\t' or c == '>' or c == '+' or c == '~')) break;
            if (c == '(') paren_depth += 1
            else if (c == ')' and paren_depth > 0) paren_depth -= 1
            else if (c == '[') bracket_depth += 1
            else if (c == ']' and bracket_depth > 0) bracket_depth -= 1;
            i += 1;
        }

        if (i > start) {
            out[count] = .{ .selector = trimmed[start..i], .combinator = next_combinator };
            count += 1;
            next_combinator = .descendant; // default combinator is descendant (space)
        }
    }
    return count;
}

/// Check if a node matches a full compound selector with combinators (>, +, ~, space)
fn nodeMatchesCompound(node: *lxb.lxb_dom_node_t, parts: []const SelectorPart) bool {
    if (parts.len == 0) return false;
    // Last part must match the node itself
    if (!nodeMatchesSimple(node, parts[parts.len - 1].selector)) return false;
    if (parts.len == 1) return true;

    // Walk backwards through parts, checking relationships
    var current: *lxb.lxb_dom_node_t = node;
    var pi: usize = parts.len - 1;
    while (pi > 0) {
        pi -= 1;
        const part = parts[pi];
        const combinator = parts[pi + 1].combinator;

        switch (combinator) {
            .descendant => {
                // Any ancestor must match
                var ancestor: ?*lxb.lxb_dom_node_t = current.parent;
                var found = false;
                while (ancestor) |a| {
                    if (nodeMatchesSimple(a, part.selector)) {
                        current = a;
                        found = true;
                        break;
                    }
                    ancestor = a.parent;
                }
                if (!found) return false;
            },
            .child => {
                // Direct parent must match
                const parent = current.parent orelse return false;
                if (!nodeMatchesSimple(parent, part.selector)) return false;
                current = parent;
            },
            .adjacent_sibling => {
                // Previous element sibling must match
                const prev = prevElementSibling(current) orelse return false;
                if (!nodeMatchesSimple(prev, part.selector)) return false;
                current = prev;
            },
            .general_sibling => {
                // Any preceding element sibling must match
                var sib: ?*lxb.lxb_dom_node_t = prevElementSibling(current);
                var found = false;
                while (sib) |s| {
                    if (nodeMatchesSimple(s, part.selector)) {
                        current = s;
                        found = true;
                        break;
                    }
                    sib = prevElementSibling(s);
                }
                if (!found) return false;
            },
        }
    }
    return true;
}

/// Get previous element sibling (skip text/comment nodes)
fn prevElementSibling(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t {
    var cur: ?*lxb.lxb_dom_node_t = node.prev;
    while (cur) |c| {
        if (c.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) return c;
        cur = c.prev;
    }
    return null;
}

/// Iterative querySelectorAll collector — supports compound selectors with combinators
fn walkTreeCollect(ctx: *qjs.JSContext, root: *lxb.lxb_dom_node_t, selector: []const u8, arr: qjs.JSValue, idx: *u32) void {
    if (selector.len == 0) return;
    const trimmed = std.mem.trim(u8, selector, " \t");
    if (trimmed.len == 0) return;

    // Handle comma-separated selectors (top-level only, not inside :not() etc.)
    {
        var depth: u32 = 0;
        var has_top_comma = false;
        for (trimmed) |ch| {
            if (ch == '(' or ch == '[') depth += 1
            else if ((ch == ')' or ch == ']') and depth > 0) depth -= 1
            else if (ch == ',' and depth == 0) { has_top_comma = true; break; }
        }
        if (has_top_comma) {
            var start: usize = 0;
            depth = 0;
            for (trimmed, 0..) |ch, i| {
                if (ch == '(' or ch == '[') depth += 1
                else if ((ch == ')' or ch == ']') and depth > 0) depth -= 1
                else if (ch == ',' and depth == 0) {
                    const sub = std.mem.trim(u8, trimmed[start..i], " \t");
                    if (sub.len > 0) walkTreeCollect(ctx, root, sub, arr, idx);
                    start = i + 1;
                }
            }
            const sub = std.mem.trim(u8, trimmed[start..], " \t");
            if (sub.len > 0) walkTreeCollect(ctx, root, sub, arr, idx);
            return;
        }
    }

    var parts_buf: [16]SelectorPart = undefined;
    const part_count = parseSelectorParts(trimmed, &parts_buf);
    if (part_count == 0) return;
    const parts = parts_buf[0..part_count];

    var current: ?*lxb.lxb_dom_node_t = root;
    while (current) |node| {
        if (nodeMatchesCompound(node, parts)) {
            _ = qjs.JS_SetPropertyUint32(ctx, arr, idx.*, wrapNode(ctx, node));
            idx.* += 1;
        }
        current = nextDfsNode(node, root);
    }
}

fn documentCreateElement(
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

    const doc = g_document orelse return quickjs.JS_NULL();
    const elem = lxb_dom_document_create_element(doc, s.ptr, s.len, null) orelse return quickjs.JS_NULL();
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    const js_elem = wrapNode(c, node);

    // Custom element upgrade: check __ce_registry for matching tag name
    upgradeCustomElement(c, js_elem, s.ptr, s.len);

    return js_elem;
}

fn upgradeCustomElement(ctx: *qjs.JSContext, elem: qjs.JSValue, tag_ptr: [*]const u8, tag_len: usize) void {
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

/// Walk a DOM subtree and upgrade any custom elements (elements with '-' in tag name).
fn upgradeSubtreeCustomElements(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) void {
    // Check if this node is an element with a custom tag name (contains '-')
    if (node.*.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
        const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
        var name_len: usize = 0;
        const name_ptr: ?[*]const u8 = lxb.lxb_dom_element_local_name(elem, &name_len);
        if (name_ptr != null and name_len > 0) {
            const tag = name_ptr.?[0..name_len];
            // Custom elements must contain a hyphen
            if (std.mem.indexOfScalar(u8, tag, '-') != null) {
                const js_elem = wrapNode(ctx, node);
                upgradeCustomElement(ctx, js_elem, tag.ptr, tag.len);
                qjs.JS_FreeValue(ctx, js_elem);
            }
        }
    }

    // Recurse into children
    var child: ?*lxb.lxb_dom_node_t = node.*.first_child;
    while (child) |ch| {
        upgradeSubtreeCustomElements(ctx, ch);
        child = ch.*.next;
    }
}

fn documentCreateElementNS(
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

    const doc = g_document orelse return quickjs.JS_NULL();
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

fn documentCreateTextNode(
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

    const doc = g_document orelse return quickjs.JS_NULL();
    const text = lxb_dom_document_create_text_node(doc, s.ptr, s.len) orelse return quickjs.JS_NULL();
    return wrapNode(c, text);
}

fn documentGetBody(
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

fn documentGetTitle(
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

fn documentSetTitle(
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
        const doc_ptr = g_document orelse return quickjs.JS_UNDEFINED();
        const text_node = lxb_dom_document_create_text_node(doc_ptr, new_title.ptr, new_title.len);
        if (text_node) |tn| {
            lxb_dom_node_insert_child(title_node, @ptrCast(tn));
        }
    }
    return quickjs.JS_UNDEFINED();
}

fn documentGetDocumentElement(
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

fn documentGetHead(
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
fn extractDomain(url: []const u8) ?[]const u8 {
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

fn documentGetCookie(
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

    const domain = if (g_current_url) |url| extractDomain(url) orelse "" else "";
    if (domain.len == 0) return qjs.JS_NewStringLen(c, "", 0);

    const cookies = client.getCookiesForDomain(std.heap.c_allocator, domain) orelse {
        return qjs.JS_NewStringLen(c, "", 0);
    };
    defer std.heap.c_allocator.free(cookies);
    return qjs.JS_NewStringLen(c, cookies.ptr, cookies.len);
}

fn documentSetCookie(
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

    const domain = if (g_current_url) |url| extractDomain(url) orelse "" else "";
    if (domain.len == 0) return quickjs.JS_UNDEFINED();

    client.setJsCookie(domain, s.ptr[0..s.len]);
    return quickjs.JS_UNDEFINED();
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

// ── HTMLTemplateElement.content getter ───────────────────────────────

fn templateGetContent(
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
    const doc = g_document orelse return quickjs.JS_UNDEFINED();
    const frag_elem = lxb_dom_document_create_element(doc, "div", 3, null) orelse return quickjs.JS_UNDEFINED();
    const frag_node: *lxb.lxb_dom_node_t = @ptrCast(frag_elem);
    const frag = wrapNode(c, frag_node);

    // Cache it on the element
    _ = qjs.JS_DefinePropertyValue(c, this_val, cache_atom, qjs.JS_DupValue(c, frag), qjs.JS_PROP_CONFIGURABLE);

    return frag;
}

// ── HTMLElement.hidden getter/setter ─────────────────────────────────

fn elementGetHidden(
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

fn elementSetHidden(
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
        _ = lxb.lxb_dom_element_set_attribute(elem, "hidden", 6, "", 0);
    } else {
        // Remove hidden attribute
        _ = lxb.lxb_dom_element_remove_attribute(elem, "hidden", 6);
    }
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

// ── input.value / textarea.value / select.value ─────────────────────

fn elementGetValue(
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

fn elementSetValue(
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

// ── getComputedStyle() ──────────────────────────────────────────────

fn computedStyleGetPropertyValue(
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

    const prop_s = jsStringToSlice(c, args[0]) orelse return qjs.JS_NewStringLen(c, "", 0);
    defer qjs.JS_FreeCString(c, prop_s.ptr);
    const prop = prop_s.ptr[0..prop_s.len];

    // Check inline style FIRST (highest specificity — reflects JS modifications)
    const elem = getElement(c, elem_val);
    if (elem) |el| {
        var style_len: usize = 0;
        const style_ptr = lxb_dom_element_get_attribute(el, "style", 5, &style_len);
        if (style_ptr != null and style_len > 0) {
            if (getStyleProperty(style_ptr.?[0..style_len], prop)) |val| {
                // Resolve var() references in computed style getPropertyValue
                if (std.mem.indexOf(u8, val, "var(") != null) {
                    const resolved = resolveVarFromElement(c, elem_val, val);
                    if (resolved) |rv| {
                        return resolveInlineForComputed(c, prop, rv, elem_val);
                    }
                }
                const trimmed = std.mem.trim(u8, val, " \t\r\n");
                // Resolve CSS-wide keywords to computed values
                if (eqlIgnoreCase(trimmed, "initial")) {
                    return cssInitialValue(c, prop);
                } else if (eqlIgnoreCase(trimmed, "inherit")) {
                    return getInheritedComputedValue(c, elem_val, prop);
                } else if (eqlIgnoreCase(trimmed, "unset")) {
                    if (isCssInheritedProperty(prop)) {
                        return getInheritedComputedValue(c, elem_val, prop);
                    }
                    return cssInitialValue(c, prop);
                } else if (eqlIgnoreCase(trimmed, "revert")) {
                    // Fall through to cascade (UA value)
                } else {
                    return resolveInlineForComputed(c, prop, val, elem_val);
                }
            }
            // Try shorthand reconstruction from expanded longhands (with resolution)
            const istyle = style_ptr.?[0..style_len];
            if (reconstructBoxShorthandJSWithElem(c, istyle, prop, elem_val)) |reconstructed| {
                return reconstructed;
            }
            // Try longhand from stored shorthand — resolve to computed value
            if (getLonghandFromShorthand(istyle, prop)) |lh_val| {
                return resolveInlineForComputed(c, prop, lh_val, elem_val);
            }
        }
    }

    // Fall back to cascade computed style, using layout box used values where available
    const node = getNode(c, elem_val);
    if (node != null and g_styles != null) {
        if (g_styles.?.get(@intFromPtr(node.?))) |style| {
            // Try to use layout box for resolved margin/padding/dimension values
            const box_opt = if (g_root_box) |root| findBoxForNode(root, node.?) else null;
            return computedStyleToStringWithBox(c, &style, prop, box_opt);
        }
    }
    return qjs.JS_NewStringLen(c, "", 0);
}

/// Convert a ComputedStyle field to a CSS string for getComputedStyle (without box context).
fn computedStyleToString(c: *qjs.JSContext, style: *const ComputedStyle, prop: []const u8) qjs.JSValue {
    return computedStyleToStringWithBox(c, style, prop, null);
}

/// Convert a ComputedStyle field to a CSS string, using layout box used values when available.
fn computedStyleToStringWithBox(c: *qjs.JSContext, style: *const ComputedStyle, prop: []const u8, box_opt: ?*const Box) qjs.JSValue {
    // Map CSS logical properties to physical properties (horizontal-tb writing mode assumed)
    // Per CSS Logical Properties Level 1 spec
    const mapped_prop = mapLogicalToPhysical(prop);
    return computedStyleToStringWithBoxInner(c, style, mapped_prop, box_opt);
}

/// Map CSS logical properties to physical equivalents (assuming horizontal-tb)
fn mapLogicalToPhysical(prop: []const u8) []const u8 {
    // margin-block-start/end → margin-top/bottom
    if (eqlIgnoreCase(prop, "margin-block-start")) return "margin-top";
    if (eqlIgnoreCase(prop, "margin-block-end")) return "margin-bottom";
    if (eqlIgnoreCase(prop, "margin-inline-start")) return "margin-left";
    if (eqlIgnoreCase(prop, "margin-inline-end")) return "margin-right";
    // padding-block-start/end → padding-top/bottom
    if (eqlIgnoreCase(prop, "padding-block-start")) return "padding-top";
    if (eqlIgnoreCase(prop, "padding-block-end")) return "padding-bottom";
    if (eqlIgnoreCase(prop, "padding-inline-start")) return "padding-left";
    if (eqlIgnoreCase(prop, "padding-inline-end")) return "padding-right";
    // border-block-*-color/width/style → border-top/bottom-*
    if (eqlIgnoreCase(prop, "border-block-start-color")) return "border-top-color";
    if (eqlIgnoreCase(prop, "border-block-end-color")) return "border-bottom-color";
    if (eqlIgnoreCase(prop, "border-inline-start-color")) return "border-left-color";
    if (eqlIgnoreCase(prop, "border-inline-end-color")) return "border-right-color";
    if (eqlIgnoreCase(prop, "border-block-start-width")) return "border-top-width";
    if (eqlIgnoreCase(prop, "border-block-end-width")) return "border-bottom-width";
    if (eqlIgnoreCase(prop, "border-inline-start-width")) return "border-left-width";
    if (eqlIgnoreCase(prop, "border-inline-end-width")) return "border-right-width";
    if (eqlIgnoreCase(prop, "border-block-start-style")) return "border-top-style";
    if (eqlIgnoreCase(prop, "border-block-end-style")) return "border-bottom-style";
    if (eqlIgnoreCase(prop, "border-inline-start-style")) return "border-left-style";
    if (eqlIgnoreCase(prop, "border-inline-end-style")) return "border-right-style";
    // inset-block/inline → top/bottom/left/right
    if (eqlIgnoreCase(prop, "inset-block-start")) return "top";
    if (eqlIgnoreCase(prop, "inset-block-end")) return "bottom";
    if (eqlIgnoreCase(prop, "inset-inline-start")) return "left";
    if (eqlIgnoreCase(prop, "inset-inline-end")) return "right";
    // block-size/inline-size → height/width
    if (eqlIgnoreCase(prop, "block-size")) return "height";
    if (eqlIgnoreCase(prop, "inline-size")) return "width";
    if (eqlIgnoreCase(prop, "min-block-size")) return "min-height";
    if (eqlIgnoreCase(prop, "min-inline-size")) return "min-width";
    if (eqlIgnoreCase(prop, "max-block-size")) return "max-height";
    if (eqlIgnoreCase(prop, "max-inline-size")) return "max-width";
    return prop;
}

fn computedStyleToStringWithBoxInner(c: *qjs.JSContext, style: *const ComputedStyle, prop: []const u8, box_opt: ?*const Box) qjs.JSValue {
    // Format buffer for numeric values
    var buf: [128]u8 = undefined;

    if (std.mem.eql(u8, prop, "display")) {
        // CSS 2.1 §9.7: Blockification — position:absolute/fixed and float cause
        // inline display types to become their block equivalents
        const needs_blockify = (style.position == .absolute or style.position == .fixed or
            style.float_ != .none);
        const s = switch (style.display) {
            .block => "block",
            .inline_ => if (needs_blockify) "block" else "inline",
            .none => "none",
            .flex => "flex",
            .inline_block => if (needs_blockify) "block" else "inline-block",
            .inline_flex => if (needs_blockify) "flex" else "inline-flex",
            .grid => "grid",
            .inline_grid => if (needs_blockify) "grid" else "inline-grid",
            .table => "table",
            .inline_table => if (needs_blockify) "table" else "inline-table",
            // CSS Display L3 §2.7: Internal table display types blockify to "block"
            .table_row => if (needs_blockify) "block" else "table-row",
            .table_cell => if (needs_blockify) "block" else "table-cell",
            .table_caption => if (needs_blockify) "block" else "table-caption",
            .table_row_group => if (needs_blockify) "block" else "table-row-group",
            .table_header_group => if (needs_blockify) "block" else "table-header-group",
            .table_footer_group => if (needs_blockify) "block" else "table-footer-group",
            .table_column => if (needs_blockify) "block" else "table-column",
            .table_column_group => if (needs_blockify) "block" else "table-column-group",
            .list_item => "list-item",
            .contents => "contents",
            else => "block",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "position")) {
        const s = switch (style.position) {
            .static_ => "static",
            .relative => "relative",
            .absolute => "absolute",
            .fixed => "fixed",
            .sticky => "sticky",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "visibility")) {
        const s = switch (style.visibility) {
            .visible => "visible",
            .hidden => "hidden",
            .collapse => "collapse",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "color")) {
        return argbToCssColor(c, style.color, &buf);
    } else if (std.mem.eql(u8, prop, "background-color")) {
        return argbToCssColor(c, style.background_color, &buf);
    } else if (std.mem.eql(u8, prop, "outline-color")) {
        // Default outline-color is currentcolor → resolve to computed color
        return argbToCssColor(c, style.color, &buf);
    } else if (std.mem.eql(u8, prop, "caret-color")) {
        // Default caret-color is auto → resolved as currentcolor
        return argbToCssColor(c, style.color, &buf);
    } else if (std.mem.eql(u8, prop, "box-shadow")) {
        // Default box-shadow is none
        return qjs.JS_NewStringLen(c, "none", 4);
    } else if (std.mem.eql(u8, prop, "text-shadow")) {
        return qjs.JS_NewStringLen(c, "none", 4);
    } else if (std.mem.eql(u8, prop, "font-size")) {
        return fmtPx(c, style.font_size_px, &buf);
    } else if (std.mem.eql(u8, prop, "font-weight")) {
        const result = std.fmt.bufPrint(&buf, "{d}", .{style.font_weight}) catch return qjs.JS_NewStringLen(c, "400", 3);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    } else if (std.mem.eql(u8, prop, "font-family")) {
        if (style.font_family == .web_font) {
            if (style.font_family_name) |name| {
                return qjs.JS_NewStringLen(c, name.ptr, name.len);
            }
        }
        const s = switch (style.font_family) {
            .sans_serif, .web_font => "sans-serif",
            .serif => "serif",
            .monospace => "monospace",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "text-align")) {
        const s = switch (style.text_align) {
            .left => "left",
            .right => "right",
            .center => "center",
            .justify => "justify",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "width")) {
        // CSS 2.1: computed width is the used value (px) when in layout
        if (box_opt) |box| {
            if (style.width == .auto) {
                return qjs.JS_NewStringLen(c, "auto", 4);
            }
            return fmtPx(c, box.content.width, &buf);
        }
        return dimensionToString(c, style.width, &buf);
    } else if (std.mem.eql(u8, prop, "height")) {
        if (box_opt) |box| {
            if (style.height == .auto) {
                return qjs.JS_NewStringLen(c, "auto", 4);
            }
            return fmtPx(c, box.content.height, &buf);
        }
        return dimensionToString(c, style.height, &buf);
    } else if (std.mem.eql(u8, prop, "margin")) {
        if (box_opt) |box| {
            return fmtBoxShorthand(c, box.margin.top, box.margin.right, box.margin.bottom, box.margin.left, &buf);
        }
        return fmtBoxShorthand(c, style.margin_top, style.margin_right, style.margin_bottom, style.margin_left, &buf);
    } else if (std.mem.eql(u8, prop, "margin-top")) {
        if (box_opt) |box| return fmtPx(c, box.margin.top, &buf);
        return fmtPx(c, style.margin_top, &buf);
    } else if (std.mem.eql(u8, prop, "margin-right")) {
        if (box_opt) |box| return fmtPx(c, box.margin.right, &buf);
        return fmtPx(c, style.margin_right, &buf);
    } else if (std.mem.eql(u8, prop, "margin-bottom")) {
        if (box_opt) |box| return fmtPx(c, box.margin.bottom, &buf);
        return fmtPx(c, style.margin_bottom, &buf);
    } else if (std.mem.eql(u8, prop, "margin-left")) {
        if (box_opt) |box| return fmtPx(c, box.margin.left, &buf);
        return fmtPx(c, style.margin_left, &buf);
    } else if (std.mem.eql(u8, prop, "margin-trim")) {
        return fmtMarginTrim(c, style.margin_trim);
    } else if (std.mem.eql(u8, prop, "padding")) {
        if (box_opt) |box| {
            return fmtBoxShorthand(c, box.padding.top, box.padding.right, box.padding.bottom, box.padding.left, &buf);
        }
        return fmtBoxShorthand(c, style.padding_top, style.padding_right, style.padding_bottom, style.padding_left, &buf);
    } else if (std.mem.eql(u8, prop, "padding-top")) {
        if (box_opt) |box| return fmtPx(c, box.padding.top, &buf);
        return fmtPx(c, style.padding_top, &buf);
    } else if (std.mem.eql(u8, prop, "padding-right")) {
        if (box_opt) |box| return fmtPx(c, box.padding.right, &buf);
        return fmtPx(c, style.padding_right, &buf);
    } else if (std.mem.eql(u8, prop, "padding-bottom")) {
        if (box_opt) |box| return fmtPx(c, box.padding.bottom, &buf);
        return fmtPx(c, style.padding_bottom, &buf);
    } else if (std.mem.eql(u8, prop, "padding-left")) {
        if (box_opt) |box| return fmtPx(c, box.padding.left, &buf);
        return fmtPx(c, style.padding_left, &buf);
    } else if (std.mem.eql(u8, prop, "border-top-width")) {
        return fmtPx(c, style.border_top_width, &buf);
    } else if (std.mem.eql(u8, prop, "border-right-width")) {
        return fmtPx(c, style.border_right_width, &buf);
    } else if (std.mem.eql(u8, prop, "border-bottom-width")) {
        return fmtPx(c, style.border_bottom_width, &buf);
    } else if (std.mem.eql(u8, prop, "border-left-width")) {
        return fmtPx(c, style.border_left_width, &buf);
    } else if (std.mem.eql(u8, prop, "opacity")) {
        const clamped = @max(@as(f32, 0), @min(@as(f32, 1), style.opacity));
        const result = std.fmt.bufPrint(&buf, "{d}", .{clamped}) catch return qjs.JS_NewStringLen(c, "1", 1);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    } else if (std.mem.eql(u8, prop, "z-index")) {
        if (style.z_index == 0 and style.position == .static_) {
            return qjs.JS_NewStringLen(c, "auto", 4);
        }
        const result = std.fmt.bufPrint(&buf, "{d}", .{style.z_index}) catch return qjs.JS_NewStringLen(c, "0", 1);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    } else if (std.mem.eql(u8, prop, "overflow-x")) {
        return overflowToString(c, style.overflow_x);
    } else if (std.mem.eql(u8, prop, "overflow-y")) {
        return overflowToString(c, style.overflow_y);
    } else if (std.mem.eql(u8, prop, "flex-direction")) {
        const s = switch (style.flex_direction) {
            .row => "row",
            .row_reverse => "row-reverse",
            .column => "column",
            .column_reverse => "column-reverse",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "flex-grow")) {
        const result = std.fmt.bufPrint(&buf, "{d}", .{style.flex_grow}) catch return qjs.JS_NewStringLen(c, "0", 1);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    } else if (std.mem.eql(u8, prop, "flex-shrink")) {
        const result = std.fmt.bufPrint(&buf, "{d}", .{style.flex_shrink}) catch return qjs.JS_NewStringLen(c, "1", 1);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    } else if (std.mem.eql(u8, prop, "box-sizing")) {
        const s = switch (style.box_sizing) {
            .content_box => "content-box",
            .border_box => "border-box",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "float")) {
        const s = switch (style.float_) {
            .none => "none",
            .left => "left",
            .right => "right",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "clear")) {
        const s = switch (style.clear) {
            .none => "none",
            .left => "left",
            .right => "right",
            .both => "both",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "top")) {
        return dimensionToString(c, style.top, &buf);
    } else if (std.mem.eql(u8, prop, "right")) {
        return dimensionToString(c, style.right, &buf);
    } else if (std.mem.eql(u8, prop, "bottom")) {
        return dimensionToString(c, style.bottom, &buf);
    } else if (std.mem.eql(u8, prop, "left")) {
        return dimensionToString(c, style.left, &buf);
    } else if (std.mem.eql(u8, prop, "overflow")) {
        // Shorthand: if both axes are the same, return one value
        const x = switch (style.overflow_x) { .visible => "visible", .hidden => "hidden", .scroll => "scroll", .auto_ => "auto" };
        const y = switch (style.overflow_y) { .visible => "visible", .hidden => "hidden", .scroll => "scroll", .auto_ => "auto" };
        if (std.mem.eql(u8, x, y)) {
            return qjs.JS_NewStringLen(c, x.ptr, x.len);
        }
        const result = std.fmt.bufPrint(&buf, "{s} {s}", .{ x, y }) catch return qjs.JS_NewStringLen(c, "visible", 7);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    } else if (std.mem.eql(u8, prop, "min-width")) {
        return dimensionToString(c, style.min_width, &buf);
    } else if (std.mem.eql(u8, prop, "max-width")) {
        return dimensionToString(c, style.max_width, &buf);
    } else if (std.mem.eql(u8, prop, "min-height")) {
        return dimensionToString(c, style.min_height, &buf);
    } else if (std.mem.eql(u8, prop, "max-height")) {
        return dimensionToString(c, style.max_height, &buf);
    } else if (std.mem.eql(u8, prop, "line-height")) {
        return switch (style.line_height) {
            .normal => qjs.JS_NewStringLen(c, "normal", 6),
            .px => |v| fmtPx(c, v, &buf),
            .number => |n| blk: {
                const result = std.fmt.bufPrint(&buf, "{d}", .{n}) catch break :blk qjs.JS_NewStringLen(c, "normal", 6);
                break :blk qjs.JS_NewStringLen(c, result.ptr, result.len);
            },
        };
    } else if (std.mem.eql(u8, prop, "white-space")) {
        const s = switch (style.white_space) {
            .normal => "normal", .pre => "pre", .nowrap => "nowrap",
            .pre_wrap => "pre-wrap", .pre_line => "pre-line", .break_spaces => "break-spaces",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "word-break")) {
        const s = switch (style.word_break) { .normal => "normal", .break_all => "break-all", .keep_all => "keep-all" };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "text-overflow")) {
        const s = switch (style.text_overflow) { .clip => "clip", .ellipsis => "ellipsis" };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "font-style")) {
        const s = switch (style.font_style) { .normal => "normal", .italic => "italic", .oblique => "oblique" };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "vertical-align")) {
        const s = switch (style.vertical_align) {
            .baseline => "baseline", .top => "top", .middle => "middle", .bottom => "bottom",
            .text_top => "text-top", .text_bottom => "text-bottom", .sub => "sub", .super => "super",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "border-top-color") or std.mem.eql(u8, prop, "border-right-color") or
        std.mem.eql(u8, prop, "border-bottom-color") or std.mem.eql(u8, prop, "border-left-color"))
    {
        const color = if (std.mem.eql(u8, prop, "border-top-color")) style.border_top_color
            else if (std.mem.eql(u8, prop, "border-right-color")) style.border_right_color
            else if (std.mem.eql(u8, prop, "border-bottom-color")) style.border_bottom_color
            else style.border_left_color;
        return argbToCssColor(c, color, &buf);
    } else if (std.mem.eql(u8, prop, "border-top-style") or std.mem.eql(u8, prop, "border-right-style") or
        std.mem.eql(u8, prop, "border-bottom-style") or std.mem.eql(u8, prop, "border-left-style"))
    {
        const bs = if (std.mem.eql(u8, prop, "border-top-style")) style.border_top_style
            else if (std.mem.eql(u8, prop, "border-right-style")) style.border_right_style
            else if (std.mem.eql(u8, prop, "border-bottom-style")) style.border_bottom_style
            else style.border_left_style;
        const s = switch (bs) {
            .none => "none", .hidden => "hidden", .solid => "solid", .dashed => "dashed",
            .dotted => "dotted", .double_ => "double", .groove => "groove", .ridge => "ridge",
            .inset => "inset", .outset => "outset",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "aspect-ratio")) {
        if (style.aspect_ratio == 0) return qjs.JS_NewStringLen(c, "auto", 4);
        const result = std.fmt.bufPrint(&buf, "{d}", .{style.aspect_ratio}) catch return qjs.JS_NewStringLen(c, "auto", 4);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    } else if (std.mem.eql(u8, prop, "text-transform")) {
        const s = switch (style.text_transform) { .none => "none", .capitalize => "capitalize", .uppercase => "uppercase", .lowercase => "lowercase" };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "letter-spacing")) {
        if (style.letter_spacing == 0) return qjs.JS_NewStringLen(c, "normal", 6);
        return fmtPx(c, style.letter_spacing, &buf);
    } else if (std.mem.eql(u8, prop, "word-spacing")) {
        if (style.word_spacing == 0) return qjs.JS_NewStringLen(c, "0px", 3);
        return fmtPx(c, style.word_spacing, &buf);
    } else if (std.mem.eql(u8, prop, "text-indent")) {
        return fmtPx(c, style.text_indent, &buf);
    } else if (std.mem.eql(u8, prop, "reading-flow")) {
        const s = switch (style.reading_flow) {
            .normal => "normal",
            .flex_visual => "flex-visual",
            .flex_flow => "flex-flow",
            .grid_rows => "grid-rows",
            .grid_columns => "grid-columns",
            .grid_order => "grid-order",
            .source_order => "source-order",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "reading-order")) {
        const result = std.fmt.bufPrint(&buf, "{d}", .{style.reading_order}) catch return qjs.JS_NewStringLen(c, "0", 1);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    }

    // Unknown property — return empty string (not undefined)
    return qjs.JS_NewStringLen(c, "", 0);
}

/// Format an ARGB u32 as "rgb(r, g, b)" or "rgba(r, g, b, a)" string.
fn argbToCssColor(c: *qjs.JSContext, argb: u32, buf: *[128]u8) qjs.JSValue {
    const a = (argb >> 24) & 0xFF;
    const r = (argb >> 16) & 0xFF;
    const g_val = (argb >> 8) & 0xFF;
    const b_val = argb & 0xFF;
    if (a == 255) {
        const result = std.fmt.bufPrint(buf, "rgb({d}, {d}, {d})", .{ r, g_val, b_val }) catch return qjs.JS_NewStringLen(c, "", 0);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    } else if (a == 0 and r == 0 and g_val == 0 and b_val == 0) {
        const s = "rgba(0, 0, 0, 0)";
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else {
        // Round alpha to common fractions to match browser serialization
        // e.g. 128/255 ≈ 0.502 but CSS expects clean values like 0.5
        const alpha_raw: f32 = @as(f32, @floatFromInt(a)) / 255.0;
        // Round to nearest 1/1000 to produce cleaner output
        const alpha = @round(alpha_raw * 1000.0) / 1000.0;
        // Use minimal decimal places
        if (alpha == @round(alpha * 10.0) / 10.0) {
            const result = std.fmt.bufPrint(buf, "rgba({d}, {d}, {d}, {d:.1})", .{ r, g_val, b_val, alpha }) catch return qjs.JS_NewStringLen(c, "", 0);
            return qjs.JS_NewStringLen(c, result.ptr, result.len);
        } else if (alpha == @round(alpha * 100.0) / 100.0) {
            const result = std.fmt.bufPrint(buf, "rgba({d}, {d}, {d}, {d:.2})", .{ r, g_val, b_val, alpha }) catch return qjs.JS_NewStringLen(c, "", 0);
            return qjs.JS_NewStringLen(c, result.ptr, result.len);
        } else {
            const result = std.fmt.bufPrint(buf, "rgba({d}, {d}, {d}, {d:.3})", .{ r, g_val, b_val, alpha }) catch return qjs.JS_NewStringLen(c, "", 0);
            return qjs.JS_NewStringLen(c, result.ptr, result.len);
        }
    }
}

/// Format a px value as "Npx" string.
/// CSS Values 4 §10.11: NaN → 0px, ±Infinity → ±MAX_LENGTH px.
const MAX_CSS_LENGTH: f32 = 33554432.0; // 2^25, implementation-defined max CSS length
fn fmtPx(c: *qjs.JSContext, val: f32, buf: *[128]u8) qjs.JSValue {
    const clamped: f32 = if (std.math.isNan(val))
        0.0
    else if (std.math.isPositiveInf(val))
        MAX_CSS_LENGTH
    else if (std.math.isNegativeInf(val))
        -MAX_CSS_LENGTH
    else
        val;
    const result = std.fmt.bufPrint(buf, "{d}px", .{clamped}) catch return qjs.JS_NewStringLen(c, "0px", 3);
    return qjs.JS_NewStringLen(c, result.ptr, result.len);
}

/// Format margin-trim computed value.
fn fmtMarginTrim(c: *qjs.JSContext, mt: computed_mod.MarginTrim) qjs.JSValue {
    const bs = mt.block_start;
    const be = mt.block_end;
    const is_ = mt.inline_start;
    const ie = mt.inline_end;
    if (!bs and !be and !is_ and !ie) return qjs.JS_NewStringLen(c, "none", 4);
    if (bs and be and is_ and ie) return qjs.JS_NewStringLen(c, "block inline", 12);
    if (bs and be and !is_ and !ie) return qjs.JS_NewStringLen(c, "block", 5);
    if (!bs and !be and is_ and ie) return qjs.JS_NewStringLen(c, "inline", 6);
    // Individual keywords
    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    // CSS canonical order: block before inline? Actually spec says individual order doesn't matter
    // but WPT expects: block-start before inline-start, etc.
    // WPT margin-trim-computed expects block-start before inline-start
    // Canonical order: block-start, inline-start, block-end, inline-end (interleaved)
    const parts = [_]struct { flag: bool, name: []const u8 }{
        .{ .flag = bs, .name = "block-start" },
        .{ .flag = is_, .name = "inline-start" },
        .{ .flag = be, .name = "block-end" },
        .{ .flag = ie, .name = "inline-end" },
    };
    for (parts) |p| {
        if (p.flag) {
            if (pos > 0) {
                buf[pos] = ' ';
                pos += 1;
            }
            @memcpy(buf[pos..][0..p.name.len], p.name);
            pos += p.name.len;
        }
    }
    return qjs.JS_NewStringLen(c, &buf, pos);
}

/// Resolve an inline style value for getComputedStyle. For most properties returns as-is.
/// For margin-trim, canonicalizes to spec order (block before inline).
fn resolveInlineForComputed(c: *qjs.JSContext, prop: []const u8, val: []const u8, elem_val: qjs.JSValue) qjs.JSValue {
    if (eqlIgnoreCase(prop, "margin-trim")) return canonicalizeMarginTrimForComputed(c, val);

    // CSS 2.1 §9.7: Blockification — when position or float is set, inline display → block equiv
    if (eqlIgnoreCase(prop, "display")) {
        const elem = getElement(c, elem_val);
        if (elem) |el| {
            var style_len: usize = 0;
            const style_ptr = lxb_dom_element_get_attribute(el, "style", 5, &style_len);
            if (style_ptr != null and style_len > 0) {
                const istyle = style_ptr.?[0..style_len];
                const pos_val = getStyleProperty(istyle, "position");
                const float_val = getStyleProperty(istyle, "float");
                const needs_blockify = blk: {
                    if (pos_val) |p| {
                        const pt = std.mem.trim(u8, p, " ");
                        if (eqlIgnoreCase(pt, "absolute") or eqlIgnoreCase(pt, "fixed")) break :blk true;
                    }
                    if (float_val) |f| {
                        const ft = std.mem.trim(u8, f, " ");
                        if (eqlIgnoreCase(ft, "left") or eqlIgnoreCase(ft, "right")) break :blk true;
                    }
                    break :blk false;
                };
                if (needs_blockify) {
                    const tv = std.mem.trim(u8, val, " \t\r\n");
                    // CSS Display L3 §2.7: Blockification rules
                    const blockified: ?[]const u8 = if (eqlIgnoreCase(tv, "inline")) "block"
                    else if (eqlIgnoreCase(tv, "inline-block")) "block"
                    else if (eqlIgnoreCase(tv, "inline-table")) "table"
                    else if (eqlIgnoreCase(tv, "inline-flex")) "flex"
                    else if (eqlIgnoreCase(tv, "inline-grid")) "grid"
                    // Internal table display types blockify to "block"
                    else if (eqlIgnoreCase(tv, "table-row-group")) "block"
                    else if (eqlIgnoreCase(tv, "table-header-group")) "block"
                    else if (eqlIgnoreCase(tv, "table-footer-group")) "block"
                    else if (eqlIgnoreCase(tv, "table-row")) "block"
                    else if (eqlIgnoreCase(tv, "table-cell")) "block"
                    else if (eqlIgnoreCase(tv, "table-column")) "block"
                    else if (eqlIgnoreCase(tv, "table-column-group")) "block"
                    else if (eqlIgnoreCase(tv, "table-caption")) "block"
                    // Ruby internal display types blockify to "block"
                    else if (eqlIgnoreCase(tv, "ruby-base")) "block"
                    else if (eqlIgnoreCase(tv, "ruby-text")) "block"
                    else if (eqlIgnoreCase(tv, "ruby-base-container")) "block"
                    else if (eqlIgnoreCase(tv, "ruby-text-container")) "block"
                    else null;
                    if (blockified) |b| return qjs.JS_NewStringLen(c, b.ptr, b.len);
                }
            }
        }
        return qjs.JS_NewStringLen(c, val.ptr, val.len);
    }

    // Resolve opacity to clamped [0,1] numeric value
    if (eqlIgnoreCase(prop, "opacity")) {
        const trimmed_opacity = std.mem.trim(u8, val, " \t\r\n");
        var opacity_val: ?f64 = null;
        if (trimmed_opacity.len > 0 and trimmed_opacity[trimmed_opacity.len - 1] == '%') {
            opacity_val = (std.fmt.parseFloat(f64, trimmed_opacity[0 .. trimmed_opacity.len - 1]) catch null);
            if (opacity_val) |*v| v.* /= 100.0;
        } else {
            opacity_val = std.fmt.parseFloat(f64, trimmed_opacity) catch null;
        }
        if (opacity_val) |v| {
            const clamped = @max(0.0, @min(1.0, v));
            var obuf: [32]u8 = undefined;
            const os = std.fmt.bufPrint(&obuf, "{d}", .{clamped}) catch return qjs.JS_NewStringLen(c, val.ptr, val.len);
            return qjs.JS_NewStringLen(c, os.ptr, os.len);
        }
    }

    // Resolve color values to rgb()/rgba() form for computed style
    if (isColorProperty(prop)) {
        const color_mod = @import("../css/properties.zig");
        const trimmed_color = std.mem.trim(u8, val, " \t\r\n");
        // currentcolor resolves to inherited color
        if (eqlIgnoreCase(trimmed_color, "currentcolor")) {
            return getInheritedComputedValue(c, elem_val, "color");
        }
        // CSS Color 4: color() function keeps color() serialization
        if (eqlIgnoreCase(trimmed_color[0..@min(6, trimmed_color.len)], "color(")) {
            return formatColorFuncComputed(c, trimmed_color);
        }
        // CSS Color 4: oklab/oklch/lab/lch keep their serialization in computed style
        if (eqlIgnoreCase(trimmed_color[0..@min(6, trimmed_color.len)], "oklab(") or
            eqlIgnoreCase(trimmed_color[0..@min(6, trimmed_color.len)], "oklch(") or
            eqlIgnoreCase(trimmed_color[0..@min(4, trimmed_color.len)], "lab(") or
            eqlIgnoreCase(trimmed_color[0..@min(4, trimmed_color.len)], "lch("))
        {
            return formatModernColorComputed(c, trimmed_color);
        }
        if (color_mod.parseColor(trimmed_color)) |color| {
            var color_buf: [64]u8 = undefined;
            if (color.a == 255) {
                const s = std.fmt.bufPrint(&color_buf, "rgb({d}, {d}, {d})", .{ color.r, color.g, color.b }) catch return qjs.JS_NewStringLen(c, val.ptr, val.len);
                return qjs.JS_NewStringLen(c, s.ptr, s.len);
            } else if (color.a == 0) {
                const s = std.fmt.bufPrint(&color_buf, "rgba({d}, {d}, {d}, 0)", .{ color.r, color.g, color.b }) catch return qjs.JS_NewStringLen(c, val.ptr, val.len);
                return qjs.JS_NewStringLen(c, s.ptr, s.len);
            } else {
                // Try to preserve original alpha precision from the CSS value
                const orig_alpha = extractOriginalAlpha(trimmed_color);
                var alpha_buf: [16]u8 = undefined;
                const alpha_s = if (orig_alpha) |a|
                    std.fmt.bufPrint(&alpha_buf, "{d}", .{a}) catch "0"
                else blk: {
                    const a = @as(f32, @floatFromInt(color.a)) / 255.0;
                    break :blk std.fmt.bufPrint(&alpha_buf, "{d}", .{a}) catch "0";
                };
                const s = std.fmt.bufPrint(&color_buf, "rgba({d}, {d}, {d}, {s})", .{ color.r, color.g, color.b, alpha_s }) catch return qjs.JS_NewStringLen(c, val.ptr, val.len);
                return qjs.JS_NewStringLen(c, s.ptr, s.len);
            }
        }
    }

    // Resolve var() references before further processing
    if (std.mem.indexOf(u8, val, "var(") != null) {
        const resolved = resolveVarFromElement(c, elem_val, val);
        if (resolved) |rv| {
            // Recursively process the resolved value
            return resolveInlineForComputed(c, prop, rv, elem_val);
        }
    }

    const trimmed = std.mem.trim(u8, val, " \t\r\n");

    // Keywords that should not be resolved to px
    if (trimmed.len == 0 or
        eqlIgnoreCase(trimmed, "auto") or eqlIgnoreCase(trimmed, "none") or
        eqlIgnoreCase(trimmed, "normal") or eqlIgnoreCase(trimmed, "medium") or
        eqlIgnoreCase(trimmed, "thin") or eqlIgnoreCase(trimmed, "thick") or
        eqlIgnoreCase(trimmed, "min-content") or eqlIgnoreCase(trimmed, "max-content") or
        eqlIgnoreCase(trimmed, "fit-content") or eqlIgnoreCase(trimmed, "contents"))
    {
        return qjs.JS_NewStringLen(c, val.ptr, val.len);
    }

    // Integer properties: reading-order, order, z-index — resolve calc() to integer
    if (eqlIgnoreCase(prop, "reading-order") or eqlIgnoreCase(prop, "order")) {
        if (trimmed.len >= 5 and eqlIgnoreCase(trimmed[0..5], "calc(")) {
            const font_size = getElementFontSizeFromStyle(c, elem_val);
            if (cascade_mod.resolveValueToPx(trimmed, font_size, g_viewport_width, g_viewport_height, 0)) |v| {
                var buf: [64]u8 = undefined;
                const int_val: i32 = @intFromFloat(@round(v));
                const result = std.fmt.bufPrint(&buf, "{d}", .{int_val}) catch return qjs.JS_NewStringLen(c, "0", 1);
                return qjs.JS_NewStringLen(c, result.ptr, result.len);
            }
        }
        return qjs.JS_NewStringLen(c, val.ptr, val.len);
    }

    // Shorthand margin/padding: resolve each value individually
    if (eqlIgnoreCase(prop, "margin") or eqlIgnoreCase(prop, "padding")) {
        return resolveBoxShorthandForComputed(c, trimmed, elem_val);
    }

    // Only resolve length-type properties
    if (!isComputedLengthProperty(prop)) {
        return qjs.JS_NewStringLen(c, val.ptr, val.len);
    }

    // Get resolution context from computed style and layout tree
    const font_size = getElementFontSizeFromStyle(c, elem_val);
    // height/top/bottom use containing block height for %, everything else uses width
    // (CSS spec: margin/padding % always resolve against containing block WIDTH, even vertical)
    const pct_base = if (eqlIgnoreCase(prop, "height") or eqlIgnoreCase(prop, "min-height") or
        eqlIgnoreCase(prop, "max-height") or eqlIgnoreCase(prop, "top") or eqlIgnoreCase(prop, "bottom"))
        getContainingBlockHeight(c, elem_val)
    else
        getContainingBlockWidth(c, elem_val);

    if (cascade_mod.resolveValueToPx(trimmed, font_size, g_viewport_width, g_viewport_height, pct_base)) |px| {
        if (eqlIgnoreCase(prop, "margin-left"))
            std.debug.print("[DBG-inline] margin-left val={s} px={d} isInf={}\n", .{ trimmed, px, std.math.isInf(px) });
        var buf: [128]u8 = undefined;
        // CSS Values 4 §10.11: NaN → 0, ±Infinity → clamped to allowable range
        const clamped = if (std.math.isNan(px)) 0.0 else if (std.math.isInf(px)) @as(f32, 3.4028235e+38) else px;
        return fmtPx(c, clamped, &buf);
    }

    // Check if value contains NaN/infinity keywords and resolve to 0px
    if (containsNanOrInfinity(trimmed)) {
        return qjs.JS_NewStringLen(c, "0px", 3);
    }

    // Fallback: return as-is
    return qjs.JS_NewStringLen(c, val.ptr, val.len);
}

/// Resolve var() references for an element by building a custom property map
/// from inline styles of the element and its ancestors.
fn resolveVarFromElement(c: *qjs.JSContext, elem_val: qjs.JSValue, val: []const u8) ?[]const u8 {
    const variables_mod = @import("../css/variables.zig");

    // Build a simple var map from inline styles (element + ancestors)
    var var_map = variables_mod.VarMap.init(std.heap.c_allocator);
    defer var_map.deinit();

    // Walk up the DOM tree to collect custom properties
    var current = elem_val;
    var depth: usize = 0;
    while (depth < 20) : (depth += 1) {
        const el = getElement(c, current);
        if (el) |e| {
            var slen: usize = 0;
            const sptr = lxb_dom_element_get_attribute(e, "style", 5, &slen);
            if (sptr != null and slen > 0) {
                const istyle = sptr.?[0..slen];
                // Extract --custom-property definitions
                extractCustomProps(istyle, &var_map);
            }
        }
        // Move to parent element
        const parent = qjs.JS_GetPropertyStr(c, current, "parentElement");
        if (quickjs.JS_IsNull(parent) or quickjs.JS_IsUndefined(parent)) {
            qjs.JS_FreeValue(c, parent);
            break;
        }
        if (depth > 0) qjs.JS_FreeValue(c, current);
        current = parent;
    }
    if (depth > 0) qjs.JS_FreeValue(c, current);

    // Always try resolving — even with empty map, fallback values in var() need processing
    return variables_mod.resolveVarRefs(val, &var_map, std.heap.c_allocator);
}

/// Extract --custom-property definitions from an inline style string.
fn extractCustomProps(style: []const u8, var_map: anytype) void {
    var pos: usize = 0;
    while (pos < style.len) {
        // Find next property start
        while (pos < style.len and (style[pos] == ' ' or style[pos] == ';' or style[pos] == '\t' or style[pos] == '\n')) pos += 1;
        if (pos + 2 >= style.len) break;
        if (style[pos] == '-' and style[pos + 1] == '-') {
            // Custom property
            const name_start = pos;
            while (pos < style.len and style[pos] != ':' and style[pos] != ';') pos += 1;
            if (pos >= style.len or style[pos] != ':') continue;
            const name = std.mem.trim(u8, style[name_start..pos], " \t");
            pos += 1; // skip ':'
            const val_start = pos;
            while (pos < style.len and style[pos] != ';') pos += 1;
            const value = std.mem.trim(u8, style[val_start..pos], " \t");
            var_map.set(name, value) catch {};
        } else {
            // Skip to next semicolon
            while (pos < style.len and style[pos] != ';') pos += 1;
            if (pos < style.len) pos += 1;
        }
    }
}

/// Extract the original alpha value from a CSS color string like "rgba(2, 3, 4, 0.5)"
fn extractOriginalAlpha(color_str: []const u8) ?f64 {
    // Find last comma in rgba()/hsla() — alpha is after it
    var last_comma: ?usize = null;
    var depth: usize = 0;
    for (color_str, 0..) |ch, i| {
        if (ch == '(') depth += 1
        else if (ch == ')') { if (depth > 0) depth -= 1; }
        else if (ch == ',' and depth == 1) last_comma = i;
    }
    if (last_comma) |pos| {
        var end = color_str.len;
        while (end > 0 and (color_str[end - 1] == ')' or color_str[end - 1] == ' ')) end -= 1;
        const alpha_str = std.mem.trim(u8, color_str[pos + 1 .. end], " ");
        if (alpha_str.len > 0 and alpha_str[alpha_str.len - 1] == '%') {
            // Percentage: 50% → 0.5
            const pct = std.fmt.parseFloat(f64, alpha_str[0 .. alpha_str.len - 1]) catch return null;
            return pct / 100.0;
        }
        return std.fmt.parseFloat(f64, alpha_str) catch null;
    }
    return null;
}

/// Format color() function for computed value: color(srgb R G B) or color(srgb R G B / A)
fn formatColorFuncComputed(c: *qjs.JSContext, input: []const u8) qjs.JSValue {
    const color_mod = @import("../css/properties.zig");
    const inner = color_mod.extractFuncArgs(input) orelse return qjs.JS_NewStringLen(c, input.ptr, input.len);

    var iter = std.mem.tokenizeAny(u8, inner, " \t/,");
    const space = iter.next() orelse return qjs.JS_NewStringLen(c, input.ptr, input.len);

    var vals: [4]f32 = .{ 0, 0, 0, 1 };
    var count: usize = 0;
    while (iter.next()) |tok| {
        if (count >= 4) break;
        vals[count] = color_mod.parseColorComponent(tok, 1.0) orelse return qjs.JS_NewStringLen(c, input.ptr, input.len);
        count += 1;
    }
    if (count < 3) return qjs.JS_NewStringLen(c, input.ptr, input.len);

    var buf: [128]u8 = undefined;
    const result = if (count >= 4 and vals[3] < 1.0)
        std.fmt.bufPrint(&buf, "color({s} {d} {d} {d} / {d})", .{ space, vals[0], vals[1], vals[2], vals[3] }) catch return qjs.JS_NewStringLen(c, input.ptr, input.len)
    else
        std.fmt.bufPrint(&buf, "color({s} {d} {d} {d})", .{ space, vals[0], vals[1], vals[2] }) catch return qjs.JS_NewStringLen(c, input.ptr, input.len);
    return qjs.JS_NewStringLen(c, result.ptr, result.len);
}

/// Format modern color functions (oklab/oklch/lab/lch) for computed value
fn formatModernColorComputed(c: *qjs.JSContext, input: []const u8) qjs.JSValue {
    // For now, return as-is (proper serialization requires complex normalization)
    return qjs.JS_NewStringLen(c, input.ptr, input.len);
}

/// Check if a CSS property takes a color value.
fn isColorProperty(prop: []const u8) bool {
    return eqlIgnoreCase(prop, "color") or
        eqlIgnoreCase(prop, "background-color") or
        eqlIgnoreCase(prop, "border-color") or
        eqlIgnoreCase(prop, "border-top-color") or
        eqlIgnoreCase(prop, "border-right-color") or
        eqlIgnoreCase(prop, "border-bottom-color") or
        eqlIgnoreCase(prop, "border-left-color") or
        eqlIgnoreCase(prop, "outline-color") or
        eqlIgnoreCase(prop, "text-decoration-color") or
        eqlIgnoreCase(prop, "caret-color") or
        eqlIgnoreCase(prop, "column-rule-color");
}

/// Check if a CSS value string contains NaN or infinity keywords.
fn containsNanOrInfinity(s: []const u8) bool {
    var i: usize = 0;
    while (i + 3 <= s.len) : (i += 1) {
        if (eqlIgnoreCase(s[i..][0..3], "NaN")) return true;
        if (i + 8 <= s.len and eqlIgnoreCase(s[i..][0..8], "infinity")) return true;
    }
    return false;
}

/// Check if a CSS property's computed value should be resolved to px.
fn isComputedLengthProperty(prop: []const u8) bool {
    // Box model
    if (eqlIgnoreCase(prop, "margin-top") or eqlIgnoreCase(prop, "margin-right") or
        eqlIgnoreCase(prop, "margin-bottom") or eqlIgnoreCase(prop, "margin-left")) return true;
    if (eqlIgnoreCase(prop, "padding-top") or eqlIgnoreCase(prop, "padding-right") or
        eqlIgnoreCase(prop, "padding-bottom") or eqlIgnoreCase(prop, "padding-left")) return true;
    if (eqlIgnoreCase(prop, "border-top-width") or eqlIgnoreCase(prop, "border-right-width") or
        eqlIgnoreCase(prop, "border-bottom-width") or eqlIgnoreCase(prop, "border-left-width")) return true;
    // Dimensions
    if (eqlIgnoreCase(prop, "width") or eqlIgnoreCase(prop, "height") or
        eqlIgnoreCase(prop, "min-width") or eqlIgnoreCase(prop, "min-height") or
        eqlIgnoreCase(prop, "max-width") or eqlIgnoreCase(prop, "max-height")) return true;
    // Offsets
    if (eqlIgnoreCase(prop, "top") or eqlIgnoreCase(prop, "right") or
        eqlIgnoreCase(prop, "bottom") or eqlIgnoreCase(prop, "left")) return true;
    // Text
    if (eqlIgnoreCase(prop, "text-indent") or eqlIgnoreCase(prop, "letter-spacing") or
        eqlIgnoreCase(prop, "word-spacing")) return true;
    // Font/line
    if (eqlIgnoreCase(prop, "font-size") or eqlIgnoreCase(prop, "line-height")) return true;
    return false;
}

/// Get the element's computed font-size from the global style map.
fn getElementFontSizeFromStyle(c: *qjs.JSContext, elem_val: qjs.JSValue) f32 {
    const node = getNode(c, elem_val);
    if (node != null and g_styles != null) {
        if (g_styles.?.get(@intFromPtr(node.?))) |style| {
            return style.font_size_px;
        }
    }
    return 16.0; // default
}

/// Get containing block width from the layout tree.
/// For abs-pos elements, walks up to find nearest positioned ancestor (CSS spec).
fn getContainingBlockWidth(c: *qjs.JSContext, elem_val: qjs.JSValue) f32 {
    const root = g_root_box orelse return g_viewport_width;
    const lxb_node: *lxb.lxb_dom_node_t = getNode(c, elem_val) orelse return g_viewport_width;
    const box = findBoxForNode(root, lxb_node) orelse return g_viewport_width;

    // For absolute/fixed: containing block = nearest positioned ancestor's padding box
    if (box.style.position == .absolute or box.style.position == .fixed) {
        var ancestor = box.parent;
        while (ancestor) |a| {
            // Non-static position or root element forms a containing block
            if (a.style.position != .static_ or a.parent == null) {
                return a.content.width + a.padding.left + a.padding.right;
            }
            ancestor = a.parent;
        }
        return g_viewport_width;
    }

    if (box.parent) |parent| return parent.content.width;
    return g_viewport_width;
}

/// Get containing block height from the layout tree.
fn getContainingBlockHeight(c: *qjs.JSContext, elem_val: qjs.JSValue) f32 {
    const root = g_root_box orelse return g_viewport_height;
    const lxb_node: *lxb.lxb_dom_node_t = getNode(c, elem_val) orelse return g_viewport_height;
    const box = findBoxForNode(root, lxb_node) orelse return g_viewport_height;

    if (box.style.position == .absolute or box.style.position == .fixed) {
        var ancestor = box.parent;
        while (ancestor) |a| {
            if (a.style.position != .static_ or a.parent == null) {
                return a.content.height + a.padding.top + a.padding.bottom;
            }
            ancestor = a.parent;
        }
        return g_viewport_height;
    }

    if (box.parent) |parent| return parent.content.height;
    return g_viewport_height;
}

/// Resolve a margin/padding shorthand value (1-4 values) to computed px form.
fn resolveBoxShorthandForComputed(c: *qjs.JSContext, val: []const u8, elem_val: qjs.JSValue) qjs.JSValue {
    const font_size = getElementFontSizeFromStyle(c, elem_val);
    const cb_width = getContainingBlockWidth(c, elem_val);

    // Split into 1-4 values (space-separated, respecting calc() parens)
    var parts: [4][]const u8 = .{ "", "", "", "" };
    var part_count: usize = 0;
    var pos: usize = 0;
    var paren_depth: usize = 0;
    var start: usize = 0;
    while (pos <= val.len) {
        if (pos < val.len) {
            if (val[pos] == '(') { paren_depth += 1; pos += 1; continue; }
            if (val[pos] == ')') { if (paren_depth > 0) paren_depth -= 1; pos += 1; continue; }
            if (val[pos] != ' ' and val[pos] != '\t') { pos += 1; continue; }
            if (paren_depth > 0) { pos += 1; continue; }
        }
        // End of token
        if (pos > start) {
            const token = std.mem.trim(u8, val[start..pos], " \t");
            if (token.len > 0 and part_count < 4) {
                parts[part_count] = token;
                part_count += 1;
            }
        }
        pos += 1;
        start = pos;
    }

    if (part_count == 0) return qjs.JS_NewStringLen(c, val.ptr, val.len);

    // Resolve each value to px
    var resolved: [4]f32 = .{ 0, 0, 0, 0 };
    var all_resolved = true;
    for (0..part_count) |i| {
        if (cascade_mod.resolveValueToPx(parts[i], font_size, g_viewport_width, g_viewport_height, cb_width)) |px| {
            resolved[i] = px;
        } else {
            all_resolved = false;
            break;
        }
    }

    if (!all_resolved) return qjs.JS_NewStringLen(c, val.ptr, val.len);

    // Expand 1-4 values to 4 (CSS shorthand rules)
    const top = resolved[0];
    const right = if (part_count >= 2) resolved[1] else resolved[0];
    const bottom = if (part_count >= 3) resolved[2] else resolved[0];
    const left_ = if (part_count >= 4) resolved[3] else right;

    var buf: [128]u8 = undefined;
    return fmtBoxShorthand(c, top, right, bottom, left_, &buf);
}

/// Canonicalize a margin-trim inline value for getComputedStyle (block before inline).
fn canonicalizeMarginTrimForComputed(c: *qjs.JSContext, val: []const u8) qjs.JSValue {
    var mt = computed_mod.MarginTrim{};
    var pos: usize = 0;
    while (pos < val.len) {
        while (pos < val.len and (val[pos] == ' ' or val[pos] == '\t')) pos += 1;
        if (pos >= val.len) break;
        const start = pos;
        while (pos < val.len and val[pos] != ' ' and val[pos] != '\t') pos += 1;
        const kw = val[start..pos];
        if (eqlIgnoreCase(kw, "block-start") or eqlIgnoreCase(kw, "block")) mt.block_start = true;
        if (eqlIgnoreCase(kw, "block-end") or eqlIgnoreCase(kw, "block")) mt.block_end = true;
        if (eqlIgnoreCase(kw, "inline-start") or eqlIgnoreCase(kw, "inline")) mt.inline_start = true;
        if (eqlIgnoreCase(kw, "inline-end") or eqlIgnoreCase(kw, "inline")) mt.inline_end = true;
    }
    return fmtMarginTrim(c, mt);
}

/// Format a CSS shorthand box value (margin/padding) as "top right bottom left".
fn fmtBoxShorthand(c: *qjs.JSContext, top: f32, right: f32, bottom: f32, left: f32, buf: *[128]u8) qjs.JSValue {
    if (top == right and right == bottom and bottom == left) {
        return fmtPx(c, top, buf);
    } else if (top == bottom and right == left) {
        const result = std.fmt.bufPrint(buf, "{d}px {d}px", .{ top, right }) catch return qjs.JS_NewStringLen(c, "0px", 3);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    } else if (right == left) {
        const result = std.fmt.bufPrint(buf, "{d}px {d}px {d}px", .{ top, right, bottom }) catch return qjs.JS_NewStringLen(c, "0px", 3);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    } else {
        const result = std.fmt.bufPrint(buf, "{d}px {d}px {d}px {d}px", .{ top, right, bottom, left }) catch return qjs.JS_NewStringLen(c, "0px", 3);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    }
}

/// Format a Dimension value.
fn dimensionToString(c: *qjs.JSContext, dim: ComputedStyle.Dimension, buf: *[128]u8) qjs.JSValue {
    return switch (dim) {
        .auto => qjs.JS_NewStringLen(c, "auto", 4),
        .none => qjs.JS_NewStringLen(c, "none", 4),
        .px => |v| fmtPx(c, v, buf),
        .percent => |v| blk: {
            const pct = std.fmt.bufPrint(buf, "{d}%", .{v}) catch break :blk qjs.JS_NewStringLen(c, "0%", 2);
            break :blk qjs.JS_NewStringLen(c, pct.ptr, pct.len);
        },
        .min_content => qjs.JS_NewStringLen(c, "min-content", 11),
        .max_content => qjs.JS_NewStringLen(c, "max-content", 11),
        .fit_content => qjs.JS_NewStringLen(c, "fit-content", 11),
    };
}

/// Format Overflow enum.
fn overflowToString(c: *qjs.JSContext, overflow: ComputedStyle.Overflow) qjs.JSValue {
    const s = switch (overflow) {
        .visible => "visible",
        .hidden => "hidden",
        .scroll => "scroll",
        .auto_ => "auto",
    };
    return qjs.JS_NewStringLen(c, s.ptr, s.len);
}

// ── CSS-wide Keyword Resolution (initial/inherit/unset) ─────────────

/// Return the CSS initial value for a property (computed form).
fn cssInitialValue(c: *qjs.JSContext, prop: []const u8) qjs.JSValue {
    // Margin/padding/border-width initial = 0
    if (eqlIgnoreCase(prop, "margin-top") or eqlIgnoreCase(prop, "margin-right") or
        eqlIgnoreCase(prop, "margin-bottom") or eqlIgnoreCase(prop, "margin-left") or
        eqlIgnoreCase(prop, "padding-top") or eqlIgnoreCase(prop, "padding-right") or
        eqlIgnoreCase(prop, "padding-bottom") or eqlIgnoreCase(prop, "padding-left") or
        eqlIgnoreCase(prop, "border-top-width") or eqlIgnoreCase(prop, "border-right-width") or
        eqlIgnoreCase(prop, "border-bottom-width") or eqlIgnoreCase(prop, "border-left-width") or
        eqlIgnoreCase(prop, "text-indent"))
    {
        return qjs.JS_NewStringLen(c, "0px", 3);
    }
    // Dimensions + offsets initial = auto
    if (eqlIgnoreCase(prop, "width") or eqlIgnoreCase(prop, "height") or
        eqlIgnoreCase(prop, "min-width") or eqlIgnoreCase(prop, "min-height") or
        eqlIgnoreCase(prop, "max-width") or eqlIgnoreCase(prop, "max-height") or
        eqlIgnoreCase(prop, "z-index") or
        eqlIgnoreCase(prop, "top") or eqlIgnoreCase(prop, "right") or
        eqlIgnoreCase(prop, "bottom") or eqlIgnoreCase(prop, "left"))
    {
        return qjs.JS_NewStringLen(c, "auto", 4);
    }
    if (eqlIgnoreCase(prop, "display")) return qjs.JS_NewStringLen(c, "inline", 6);
    if (eqlIgnoreCase(prop, "position")) return qjs.JS_NewStringLen(c, "static", 6);
    if (eqlIgnoreCase(prop, "visibility")) return qjs.JS_NewStringLen(c, "visible", 7);
    if (eqlIgnoreCase(prop, "float")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "clear")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "margin-trim")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "overflow-x") or eqlIgnoreCase(prop, "overflow-y"))
        return qjs.JS_NewStringLen(c, "visible", 7);
    if (eqlIgnoreCase(prop, "opacity")) return qjs.JS_NewStringLen(c, "1", 1);
    if (eqlIgnoreCase(prop, "font-size")) return qjs.JS_NewStringLen(c, "16px", 4);
    if (eqlIgnoreCase(prop, "font-weight")) return qjs.JS_NewStringLen(c, "400", 3);
    if (eqlIgnoreCase(prop, "font-style")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "font-family")) return qjs.JS_NewStringLen(c, "sans-serif", 10);
    if (eqlIgnoreCase(prop, "text-align")) return qjs.JS_NewStringLen(c, "start", 5);
    if (eqlIgnoreCase(prop, "text-transform")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "text-decoration")) return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "text-overflow")) return qjs.JS_NewStringLen(c, "clip", 4);
    if (eqlIgnoreCase(prop, "line-height")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "vertical-align")) return qjs.JS_NewStringLen(c, "baseline", 8);
    if (eqlIgnoreCase(prop, "letter-spacing") or eqlIgnoreCase(prop, "word-spacing"))
        return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "word-break")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "white-space")) return qjs.JS_NewStringLen(c, "normal", 6);
    if (eqlIgnoreCase(prop, "color")) return qjs.JS_NewStringLen(c, "rgb(0, 0, 0)", 12);
    if (eqlIgnoreCase(prop, "background-color"))
        return qjs.JS_NewStringLen(c, "rgba(0, 0, 0, 0)", 17);
    if (eqlIgnoreCase(prop, "border-top-color") or eqlIgnoreCase(prop, "border-right-color") or
        eqlIgnoreCase(prop, "border-bottom-color") or eqlIgnoreCase(prop, "border-left-color"))
        return qjs.JS_NewStringLen(c, "rgb(0, 0, 0)", 12);
    if (eqlIgnoreCase(prop, "border-top-style") or eqlIgnoreCase(prop, "border-right-style") or
        eqlIgnoreCase(prop, "border-bottom-style") or eqlIgnoreCase(prop, "border-left-style"))
        return qjs.JS_NewStringLen(c, "none", 4);
    if (eqlIgnoreCase(prop, "box-sizing")) return qjs.JS_NewStringLen(c, "content-box", 11);
    if (eqlIgnoreCase(prop, "flex-grow")) return qjs.JS_NewStringLen(c, "0", 1);
    if (eqlIgnoreCase(prop, "flex-shrink")) return qjs.JS_NewStringLen(c, "1", 1);
    if (eqlIgnoreCase(prop, "flex-basis")) return qjs.JS_NewStringLen(c, "auto", 4);
    // Default fallback
    return qjs.JS_NewStringLen(c, "", 0);
}

/// Check if a CSS property is inherited by default (CSS spec).
fn isCssInheritedProperty(prop: []const u8) bool {
    const inherited = [_][]const u8{
        "color",          "font-size",       "font-weight",      "font-style",
        "font-family",    "font-variant",    "text-align",       "text-indent",
        "text-transform", "line-height",     "letter-spacing",   "word-spacing",
        "word-break",     "white-space",     "visibility",       "direction",
        "cursor",         "list-style-type", "list-style-position", "list-style-image",
        "border-collapse", "border-spacing", "caption-side",     "empty-cells",
        "quotes",         "orphans",         "widows",           "tab-size",
    };
    for (inherited) |p| {
        if (eqlIgnoreCase(prop, p)) return true;
    }
    return false;
}

/// Get the inherited (parent's) computed value for a property.
fn getInheritedComputedValue(c: *qjs.JSContext, elem_val: qjs.JSValue, prop: []const u8) qjs.JSValue {
    const node = getNode(c, elem_val) orelse return cssInitialValue(c, prop);
    const parent = node.parent orelse return cssInitialValue(c, prop);

    // Check parent's inline style first (reflects JS modifications)
    // Guard: only element nodes have attributes
    const parent_ptr: *lxb.lxb_dom_node_t = @ptrCast(parent);
    if (parent_ptr.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
        if (g_styles) |styles| {
            if (styles.get(@intFromPtr(parent))) |style| {
                return computedStyleToString(c, &style, prop);
            }
        }
        return cssInitialValue(c, prop);
    }
    const parent_elem: *lxb.lxb_dom_element_t = @ptrCast(parent);
    var pstyle_len: usize = 0;
    const pstyle_ptr = lxb_dom_element_get_attribute(parent_elem, "style", 5, &pstyle_len);
    if (pstyle_ptr != null and pstyle_len > 0) {
        const pstyle = pstyle_ptr.?[0..pstyle_len];
        if (getStyleProperty(pstyle, prop)) |val| {
            const trimmed = std.mem.trim(u8, val, " \t\r\n");
            // Don't return CSS-wide keywords — resolve them further
            if (!eqlIgnoreCase(trimmed, "initial") and !eqlIgnoreCase(trimmed, "inherit") and
                !eqlIgnoreCase(trimmed, "unset") and !eqlIgnoreCase(trimmed, "revert"))
            {
                return qjs.JS_NewStringLen(c, val.ptr, val.len);
            }
        }
        // Also try longhand from stored shorthand (parent has "margin: 10px" → get "margin-top")
        if (getLonghandFromShorthand(pstyle, prop)) |val| {
            return qjs.JS_NewStringLen(c, val.ptr, val.len);
        }
    }

    // Fall back to cascade computed style
    if (g_styles) |styles| {
        if (styles.get(@intFromPtr(parent))) |style| {
            return computedStyleToString(c, &style, prop);
        }
    }
    return cssInitialValue(c, prop);
}

/// CSS.supports(property, value) — checks if property+value is valid CSS
fn cssSupports(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NewBool(false);
    const args = argv orelse return quickjs.JS_NewBool(false);

    if (argc == 1) {
        // CSS.supports("display: flex") — condition string form
        // Parse "property: value" and validate
        const cond_s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NewBool(false);
        defer qjs.JS_FreeCString(c, cond_s.ptr);
        const cond = cond_s.ptr[0..cond_s.len];
        // Handle parenthesized form: "(display: flex)"
        var inner = cond;
        if (inner.len > 2 and inner[0] == '(' and inner[inner.len - 1] == ')') {
            inner = inner[1 .. inner.len - 1];
        }
        // Find the colon separating property from value
        if (std.mem.indexOfScalar(u8, inner, ':')) |colon_pos| {
            const prop_raw = std.mem.trim(u8, inner[0..colon_pos], " \t");
            const val_raw = std.mem.trim(u8, inner[colon_pos + 1 ..], " \t");
            if (prop_raw.len > 0 and val_raw.len > 0) {
                return quickjs.JS_NewBool(isValidCssValue(prop_raw, val_raw));
            }
        }
        // Not a simple "property: value" form — could be "not ()" or "() and ()"
        // For complex conditions, return false (conservative)
        return quickjs.JS_NewBool(false);
    }
    if (argc < 2) return quickjs.JS_NewBool(false);

    const prop_s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NewBool(false);
    defer qjs.JS_FreeCString(c, prop_s.ptr);
    const val_s = jsStringToSlice(c, args[1]) orelse return quickjs.JS_NewBool(false);
    defer qjs.JS_FreeCString(c, val_s.ptr);

    const prop = prop_s.ptr[0..prop_s.len];
    const val = val_s.ptr[0..val_s.len];

    // Validate via isValidCssValue (handles both longhand and shorthand)
    return quickjs.JS_NewBool(isValidCssValue(prop, val));
}

fn windowGetComputedStyle(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    // Verify the argument is a valid element
    _ = getElement(c, args[0]) orelse return quickjs.JS_UNDEFINED();

    // Build a CSSStyleDeclaration-like object backed by the element's inline style
    const obj = qjs.JS_NewObject(c);
    if (quickjs.JS_IsException(obj)) return obj;

    // Store element reference
    _ = qjs.JS_SetPropertyStr(c, obj, "__element", qjs.JS_DupValue(c, args[0]));

    // getPropertyValue method (live — always reads current computed style)
    _ = qjs.JS_SetPropertyStr(c, obj, "getPropertyValue", qjs.JS_NewCFunction(c, &computedStyleGetPropertyValue, "getPropertyValue", 1));

    // Set static property values directly from Zig — no JS eval needed.
    // This avoids the memory management issues (DupValue/FreeValue) that
    // caused segfaults during navigation with the previous eval approach.
    const node = getNode(c, args[0]);
    const style_opt: ?ComputedStyle = if (node != null and g_styles != null)
        g_styles.?.get(@intFromPtr(node.?))
    else
        null;

    // Find layout box for used-value resolution (margin/padding/width % → px)
    const box_opt: ?*const Box = if (node != null and g_root_box != null)
        findBoxForNode(g_root_box.?, node.?)
    else
        null;

    // Property name pairs: kebab-case (CSS) and camelCase (JS)
    const prop_pairs = .{
        .{ "display", "display" },
        .{ "position", "position" },
        .{ "visibility", "visibility" },
        .{ "color", "color" },
        .{ "background-color", "backgroundColor" },
        .{ "font-size", "fontSize" },
        .{ "font-weight", "fontWeight" },
        .{ "font-family", "fontFamily" },
        .{ "font-style", "fontStyle" },
        .{ "text-align", "textAlign" },
        .{ "text-transform", "textTransform" },
        .{ "text-overflow", "textOverflow" },
        .{ "text-indent", "textIndent" },
        .{ "letter-spacing", "letterSpacing" },
        .{ "word-spacing", "wordSpacing" },
        .{ "word-break", "wordBreak" },
        .{ "white-space", "whiteSpace" },
        .{ "line-height", "lineHeight" },
        .{ "vertical-align", "verticalAlign" },
        .{ "width", "width" },
        .{ "height", "height" },
        .{ "min-width", "minWidth" },
        .{ "max-width", "maxWidth" },
        .{ "min-height", "minHeight" },
        .{ "max-height", "maxHeight" },
        .{ "margin", "margin" },
        .{ "margin-top", "marginTop" },
        .{ "margin-right", "marginRight" },
        .{ "margin-bottom", "marginBottom" },
        .{ "margin-left", "marginLeft" },
        .{ "margin-trim", "marginTrim" },
        .{ "padding", "padding" },
        .{ "padding-top", "paddingTop" },
        .{ "padding-right", "paddingRight" },
        .{ "padding-bottom", "paddingBottom" },
        .{ "padding-left", "paddingLeft" },
        .{ "border-top-width", "borderTopWidth" },
        .{ "border-right-width", "borderRightWidth" },
        .{ "border-bottom-width", "borderBottomWidth" },
        .{ "border-left-width", "borderLeftWidth" },
        .{ "border-top-color", "borderTopColor" },
        .{ "border-right-color", "borderRightColor" },
        .{ "border-bottom-color", "borderBottomColor" },
        .{ "border-left-color", "borderLeftColor" },
        .{ "border-top-style", "borderTopStyle" },
        .{ "border-right-style", "borderRightStyle" },
        .{ "border-bottom-style", "borderBottomStyle" },
        .{ "border-left-style", "borderLeftStyle" },
        .{ "top", "top" },
        .{ "right", "right" },
        .{ "bottom", "bottom" },
        .{ "left", "left" },
        .{ "float", "float" },
        .{ "clear", "clear" },
        .{ "overflow", "overflow" },
        .{ "overflow-x", "overflowX" },
        .{ "overflow-y", "overflowY" },
        .{ "z-index", "zIndex" },
        .{ "opacity", "opacity" },
        .{ "box-sizing", "boxSizing" },
        .{ "flex-direction", "flexDirection" },
        .{ "flex-grow", "flexGrow" },
        .{ "flex-shrink", "flexShrink" },
        .{ "aspect-ratio", "aspectRatio" },
        .{ "reading-flow", "readingFlow" },
        .{ "reading-order", "readingOrder" },
    };

    // Check inline style attribute first (highest specificity — reflects JS modifications)
    const elem = getElement(c, args[0]);
    var inline_style: []const u8 = "";
    if (elem) |el| {
        var style_len: usize = 0;
        const style_ptr = lxb_dom_element_get_attribute(el, "style", 5, &style_len);
        if (style_ptr != null and style_len > 0) {
            inline_style = style_ptr.?[0..style_len];
        }
    }

    inline for (prop_pairs) |pair| {
        const css_name = pair[0];
        const js_name = pair[1];
        // Priority: inline style > cascade computed style
        var val: qjs.JSValue = undefined;
        if (inline_style.len > 0) {
            if (getStyleProperty(inline_style, css_name)) |inline_val| {
                const t = std.mem.trim(u8, inline_val, " \t\r\n");
                if (eqlIgnoreCase(t, "initial")) {
                    val = cssInitialValue(c, css_name);
                } else if (eqlIgnoreCase(t, "inherit")) {
                    val = getInheritedComputedValue(c, args[0], css_name);
                } else if (eqlIgnoreCase(t, "unset")) {
                    val = if (isCssInheritedProperty(css_name)) getInheritedComputedValue(c, args[0], css_name) else cssInitialValue(c, css_name);
                } else if (eqlIgnoreCase(t, "revert")) {
                    if (style_opt) |style| {
                        val = computedStyleToStringWithBox(c, &style, css_name, box_opt);
                    } else {
                        val = cssInitialValue(c, css_name);
                    }
                } else {
                    val = resolveInlineForComputed(c, css_name, inline_val, args[0]);
                }
            } else if (reconstructBoxShorthandJSWithElem(c, inline_style, css_name, args[0])) |reconstructed| {
                val = reconstructed;
            } else if (getLonghandFromShorthand(inline_style, css_name)) |lh_val| {
                val = resolveInlineForComputed(c, css_name, lh_val, args[0]);
            } else if (style_opt) |style| {
                val = computedStyleToStringWithBox(c, &style, css_name, box_opt);
            } else {
                val = qjs.JS_NewStringLen(c, "", 0);
            }
        } else if (style_opt) |style| {
            val = computedStyleToStringWithBox(c, &style, css_name, box_opt);
        } else {
            val = qjs.JS_NewStringLen(c, "", 0);
        }
        _ = qjs.JS_SetPropertyStr(c, obj, js_name, val);
        // Also set kebab-case name if different from camelCase
        if (!std.mem.eql(u8, css_name, js_name)) {
            var val2: qjs.JSValue = undefined;
            if (inline_style.len > 0) {
                if (getStyleProperty(inline_style, css_name)) |inline_val| {
                    const t2 = std.mem.trim(u8, inline_val, " \t\r\n");
                    if (eqlIgnoreCase(t2, "initial")) {
                        val2 = cssInitialValue(c, css_name);
                    } else if (eqlIgnoreCase(t2, "inherit")) {
                        val2 = getInheritedComputedValue(c, args[0], css_name);
                    } else if (eqlIgnoreCase(t2, "unset")) {
                        val2 = if (isCssInheritedProperty(css_name)) getInheritedComputedValue(c, args[0], css_name) else cssInitialValue(c, css_name);
                    } else if (eqlIgnoreCase(t2, "revert")) {
                        if (style_opt) |style| {
                            val2 = computedStyleToStringWithBox(c, &style, css_name, box_opt);
                        } else {
                            val2 = cssInitialValue(c, css_name);
                        }
                    } else {
                        val2 = resolveInlineForComputed(c, css_name, inline_val, args[0]);
                    }
                } else if (reconstructBoxShorthandJSWithElem(c, inline_style, css_name, args[0])) |reconstructed| {
                    val2 = reconstructed;
                } else if (getLonghandFromShorthand(inline_style, css_name)) |lh_val| {
                    val2 = resolveInlineForComputed(c, css_name, lh_val, args[0]);
                } else if (style_opt) |style| {
                    val2 = computedStyleToStringWithBox(c, &style, css_name, box_opt);
                } else {
                    val2 = qjs.JS_NewStringLen(c, "", 0);
                }
            } else if (style_opt) |style| {
                val2 = computedStyleToStringWithBox(c, &style, css_name, box_opt);
            } else {
                val2 = qjs.JS_NewStringLen(c, "", 0);
            }
            _ = qjs.JS_SetPropertyStr(c, obj, css_name, val2);
        }
    }

    return obj;
}

// ── document.createDocumentFragment() ───────────────────────────────

fn documentCreateDocumentFragment(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    // Simplified: create a div element (fragments are complex to implement properly)
    const c = ctx orelse return quickjs.JS_NULL();
    const doc = g_document orelse return quickjs.JS_NULL();
    const elem = lxb_dom_document_create_element(doc, "div", 3, null) orelse return quickjs.JS_NULL();
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    return wrapNode(c, node);
}

// ── document.readyState getter ──────────────────────────────────────

fn documentGetReadyState(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const state_str: []const u8 = switch (g_ready_state) {
        .loading => "loading",
        .interactive => "interactive",
        .complete => "complete",
    };
    return qjs.JS_NewString(c, state_str.ptr);
}

fn documentGetActiveElement(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (active_element) |node| {
        return wrapNode(c, node);
    }
    // Default: return document.body
    return documentGetBody(ctx, quickjs.JS_UNDEFINED(), 0, null);
}

// ── document.createEvent ────────────────────────────────────────────

fn documentCreateEvent(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    // Check if interface is "CustomEvent"
    var is_custom = false;
    if (argc >= 1) {
        if (argv) |args| {
            if (jsStringToSlice(c, args[0])) |s| {
                defer qjs.JS_FreeCString(c, s.ptr);
                is_custom = std.mem.eql(u8, s.ptr[0..s.len], "CustomEvent");
            }
        }
    }
    const js_code = if (is_custom) "(new CustomEvent(''))" else "(new Event(''))";
    return qjs.JS_Eval(c, js_code, js_code.len, "<createEvent>", qjs.JS_EVAL_TYPE_GLOBAL);
}

// ── document.write ─────────────────────────────────────────────────

fn documentWrite(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    // Only works during loading phase
    if (g_ready_state != .loading) {
        std.log.warn("[JS] document.write called after page load, ignoring", .{});
        return quickjs.JS_UNDEFINED();
    }

    const str = qjs.JS_ToCString(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, str);
    const html = std.mem.span(str);

    if (html.len == 0) return quickjs.JS_UNDEFINED();

    std.log.info("[JS] document.write: {d} bytes", .{html.len});

    // Parse HTML fragment and append to body
    const doc_ptr = g_document orelse return quickjs.JS_UNDEFINED();
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

    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

// ── No-op constructor for DOM interface globals ─────────────────────

fn jsNoOpConstructor(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewObject(c);
}

// ── Registration ────────────────────────────────────────────────────

/// Register DOM API classes and the `document` global.
/// Must be called after page parse and before script execution.
pub fn registerDomApis(rt: *qjs.JSRuntime, ctx: *qjs.JSContext, document_ptr: *anyopaque) void {
    g_document = document_ptr;
    dom_dirty = false;

    // Register Element class
    _ = qjs.JS_NewClassID(rt, &element_class_id);
    const elem_class_def = qjs.JSClassDef{
        .class_name = "Element",
        .finalizer = null,
        .gc_mark = null,
        .call = null,
        .exotic = null,
    };
    _ = qjs.JS_NewClass(rt, element_class_id, &elem_class_def);

    // Register Text class
    _ = qjs.JS_NewClassID(rt, &text_class_id);
    const text_class_def = qjs.JSClassDef{
        .class_name = "Text",
        .finalizer = null,
        .gc_mark = null,
        .call = null,
        .exotic = null,
    };
    _ = qjs.JS_NewClass(rt, text_class_id, &text_class_def);

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
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "appendChild", qjs.JS_NewCFunction(ctx, &elementAppendChild, "appendChild", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "removeChild", qjs.JS_NewCFunction(ctx, &elementRemoveChild, "removeChild", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "insertBefore", qjs.JS_NewCFunction(ctx, &elementInsertBefore, "insertBefore", 2));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "contains", qjs.JS_NewCFunction(ctx, &elementContains, "contains", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "cloneNode", qjs.JS_NewCFunction(ctx, &elementCloneNode, "cloneNode", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "replaceWith", qjs.JS_NewCFunction(ctx, &elementReplaceWith, "replaceWith", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "replaceChild", qjs.JS_NewCFunction(ctx, &elementReplaceChild, "replaceChild", 2));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "before", qjs.JS_NewCFunction(ctx, &elementBefore, "before", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "after", qjs.JS_NewCFunction(ctx, &elementAfter, "after", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "remove", qjs.JS_NewCFunction(ctx, &elementRemove, "remove", 0));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "append", qjs.JS_NewCFunction(ctx, &elementAppend, "append", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "prepend", qjs.JS_NewCFunction(ctx, &elementPrepend, "prepend", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "isEqualNode", qjs.JS_NewCFunction(ctx, &nodeIsEqualNode, "isEqualNode", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "normalize", qjs.JS_NewCFunction(ctx, &nodeNormalize, "normalize", 0));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "compareDocumentPosition", qjs.JS_NewCFunction(ctx, &nodeCompareDocumentPosition, "compareDocumentPosition", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "getRootNode", qjs.JS_NewCFunction(ctx, &nodeGetRootNode, "getRootNode", 0));
    // Namespace methods (stub — HTML documents don't use namespaces heavily)
    {
        const ns_js =
            \\(function(){
            \\  var NP=Node.prototype;
            \\  NP.lookupPrefix=function(ns){if(!ns)return null;var el=this.nodeType===1?this:this.parentElement;while(el){if(el.namespaceURI===ns&&el.prefix)return el.prefix;el=el.parentElement;}return null;};
            \\  NP.lookupNamespaceURI=function(prefix){var el=this.nodeType===1?this:this.parentElement;while(el){if(prefix===null||prefix===undefined){if(el.namespaceURI&&!el.prefix)return el.namespaceURI;}else if(el.prefix===prefix)return el.namespaceURI;el=el.parentElement;}if(!prefix)return 'http://www.w3.org/1999/xhtml';return null;};
            \\  NP.isDefaultNamespace=function(ns){return this.lookupNamespaceURI(null)===ns;};
            \\  NP.isSameNode=function(o){return this===o;};
            \\  NP.hasChildNodes=function(){return this.childNodes&&this.childNodes.length>0;};
            \\  NP.replaceChildren=function(){while(this.firstChild)this.removeChild(this.firstChild);for(var i=0;i<arguments.length;i++){var a=arguments[i];if(typeof a==='string')a=document.createTextNode(a);this.appendChild(a);}};
            \\  NP.prepend=NP.prepend||function(){var f=this.firstChild;for(var i=0;i<arguments.length;i++){var a=arguments[i];if(typeof a==='string')a=document.createTextNode(a);if(f)this.insertBefore(a,f);else this.appendChild(a);}};
            \\  NP.append=NP.append||function(){for(var i=0;i<arguments.length;i++){var a=arguments[i];if(typeof a==='string')a=document.createTextNode(a);this.appendChild(a);}};
            \\})()
        ;
        const r = qjs.JS_Eval(ctx, ns_js, ns_js.len, "<ns>", qjs.JS_EVAL_TYPE_GLOBAL);
        qjs.JS_FreeValue(ctx, r);
    }

    // Node constants
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "ELEMENT_NODE", qjs.JS_NewInt32(ctx, 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "TEXT_NODE", qjs.JS_NewInt32(ctx, 3));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "COMMENT_NODE", qjs.JS_NewInt32(ctx, 8));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "DOCUMENT_NODE", qjs.JS_NewInt32(ctx, 9));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "DOCUMENT_FRAGMENT_NODE", qjs.JS_NewInt32(ctx, 11));

    // Node getters
    {
        const textContentAtom = qjs.JS_NewAtom(ctx, "textContent");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, textContentAtom, qjs.JS_NewCFunction(ctx, &elementGetTextContent, "get textContent", 0), qjs.JS_NewCFunction(ctx, &elementSetTextContent, "set textContent", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, textContentAtom);
    }
    {
        const innerTextAtom = qjs.JS_NewAtom(ctx, "innerText");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, innerTextAtom, qjs.JS_NewCFunction(ctx, &elementGetInnerText, "get innerText", 0), qjs.JS_NewCFunction(ctx, &elementSetInnerText, "set innerText", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, innerTextAtom);
    }
    {
        const parentNodeAtom = qjs.JS_NewAtom(ctx, "parentNode");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, parentNodeAtom, qjs.JS_NewCFunction(ctx, &elementGetParentNode, "get parentNode", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, parentNodeAtom);
    }
    {
        const parentElementAtom = qjs.JS_NewAtom(ctx, "parentElement");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, parentElementAtom, qjs.JS_NewCFunction(ctx, &elementGetParentElement, "get parentElement", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, parentElementAtom);
    }
    {
        const ownerDocumentAtom = qjs.JS_NewAtom(ctx, "ownerDocument");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, ownerDocumentAtom, qjs.JS_NewCFunction(ctx, &nodeGetOwnerDocument, "get ownerDocument", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, ownerDocumentAtom);
    }
    // nodeValue: null for Element/Document, overridden on text_proto for CharacterData
    {
        const nodeValueAtom = qjs.JS_NewAtom(ctx, "nodeValue");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, nodeValueAtom, qjs.JS_NewCFunction(ctx, &nodeGetNodeValue, "get nodeValue", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, nodeValueAtom);
    }
    {
        const firstChildAtom = qjs.JS_NewAtom(ctx, "firstChild");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, firstChildAtom, qjs.JS_NewCFunction(ctx, &elementGetFirstChild, "get firstChild", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, firstChildAtom);
    }
    {
        const lastChildAtom = qjs.JS_NewAtom(ctx, "lastChild");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, lastChildAtom, qjs.JS_NewCFunction(ctx, &elementGetLastChild, "get lastChild", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, lastChildAtom);
    }
    {
        const nextSiblingAtom = qjs.JS_NewAtom(ctx, "nextSibling");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, nextSiblingAtom, qjs.JS_NewCFunction(ctx, &elementGetNextSibling, "get nextSibling", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, nextSiblingAtom);
    }
    {
        const prevSiblingAtom = qjs.JS_NewAtom(ctx, "previousSibling");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, prevSiblingAtom, qjs.JS_NewCFunction(ctx, &elementGetPreviousSibling, "get previousSibling", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, prevSiblingAtom);
    }
    {
        const childNodesAtom = qjs.JS_NewAtom(ctx, "childNodes");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, childNodesAtom, qjs.JS_NewCFunction(ctx, &elementGetChildNodes, "get childNodes", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
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
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, isConnectedAtom, qjs.JS_NewCFunction(ctx, &nodeGetIsConnected, "get isConnected", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, isConnectedAtom);
    }
    {
        const nodeTypeAtom = qjs.JS_NewAtom(ctx, "nodeType");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, nodeTypeAtom, qjs.JS_NewCFunction(ctx, &elementGetNodeType, "get nodeType", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, nodeTypeAtom);
    }
    {
        const nodeNameAtom = qjs.JS_NewAtom(ctx, "nodeName");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, nodeNameAtom, qjs.JS_NewCFunction(ctx, &elementGetNodeName, "get nodeName", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, nodeNameAtom);
    }

    // ── Element.prototype (inherits Node.prototype) ────────────────
    const elem_proto = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPrototype(ctx, elem_proto, node_proto);

    // Element methods
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "getAttribute", qjs.JS_NewCFunction(ctx, &elementGetAttribute, "getAttribute", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "setAttribute", qjs.JS_NewCFunction(ctx, &elementSetAttribute, "setAttribute", 2));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "removeAttribute", qjs.JS_NewCFunction(ctx, &elementRemoveAttribute, "removeAttribute", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "hasAttribute", qjs.JS_NewCFunction(ctx, &elementHasAttribute, "hasAttribute", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "matches", qjs.JS_NewCFunction(ctx, &elementMatches, "matches", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "closest", qjs.JS_NewCFunction(ctx, &elementClosest, "closest", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "getBoundingClientRect", qjs.JS_NewCFunction(ctx, &elementGetBoundingClientRect, "getBoundingClientRect", 0));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "querySelector", qjs.JS_NewCFunction(ctx, &elementQuerySelector, "querySelector", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "querySelectorAll", qjs.JS_NewCFunction(ctx, &elementQuerySelectorAll, "querySelectorAll", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "getElementsByClassName", qjs.JS_NewCFunction(ctx, &elementGetElementsByClassName, "getElementsByClassName", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "getElementsByTagName", qjs.JS_NewCFunction(ctx, &elementGetElementsByTagName, "getElementsByTagName", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "getElementsByTagNameNS", qjs.JS_NewCFunction(ctx, &elementGetElementsByTagName, "getElementsByTagNameNS", 2));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "toggleAttribute", qjs.JS_NewCFunction(ctx, &elementToggleAttribute, "toggleAttribute", 2));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "getAttributeNames", qjs.JS_NewCFunction(ctx, &elementGetAttributeNames, "getAttributeNames", 0));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "scrollIntoView", qjs.JS_NewCFunction(ctx, &elementScrollIntoView, "scrollIntoView", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "getContext", qjs.JS_NewCFunction(ctx, &elementGetContext, "getContext", 1));

    // attributes (NamedNodeMap) getter
    {
        const attributesAtom = qjs.JS_NewAtom(ctx, "attributes");
        _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, attributesAtom, qjs.JS_NewCFunction(ctx, &elementGetAttributes, "get attributes", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, attributesAtom);
    }

    // Element getters
    {
        const tagNameAtom = qjs.JS_NewAtom(ctx, "tagName");
        _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, tagNameAtom, qjs.JS_NewCFunction(ctx, &elementGetTagName, "get tagName", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, tagNameAtom);
    }
    {
        // localName: lowercase tag name (HTML spec)
        const localNameAtom = qjs.JS_NewAtom(ctx, "localName");
        _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, localNameAtom, qjs.JS_NewCFunction(ctx, &elementGetLocalName, "get localName", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
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
        _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, idAtom, qjs.JS_NewCFunction(ctx, &elementGetId, "get id", 0), qjs.JS_NewCFunction(ctx, &elementSetId, "set id", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, idAtom);
    }
    {
        const classNameAtom = qjs.JS_NewAtom(ctx, "className");
        _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, classNameAtom, qjs.JS_NewCFunction(ctx, &elementGetClassName, "get className", 0), qjs.JS_NewCFunction(ctx, &elementSetClassName, "set className", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, classNameAtom);
    }
    {
        const classListAtom = qjs.JS_NewAtom(ctx, "classList");
        _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, classListAtom, qjs.JS_NewCFunction(ctx, &elementGetClassList, "get classList", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, classListAtom);
    }
    {
        const innerHTMLAtom = qjs.JS_NewAtom(ctx, "innerHTML");
        _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, innerHTMLAtom, qjs.JS_NewCFunction(ctx, &elementGetInnerHTML, "get innerHTML", 0), qjs.JS_NewCFunction(ctx, &elementSetInnerHTML, "set innerHTML", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, innerHTMLAtom);
    }
    {
        const outerHTMLAtom = qjs.JS_NewAtom(ctx, "outerHTML");
        _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, outerHTMLAtom, qjs.JS_NewCFunction(ctx, &elementGetOuterHTML, "get outerHTML", 0), qjs.JS_NewCFunction(ctx, &elementSetOuterHTML, "set outerHTML", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, outerHTMLAtom);
    }
    {
        const childrenAtom = qjs.JS_NewAtom(ctx, "children");
        _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, childrenAtom, qjs.JS_NewCFunction(ctx, &elementGetChildren, "get children", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, childrenAtom);
    }

    // insertAdjacentHTML
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "insertAdjacentHTML", qjs.JS_NewCFunction(ctx, &elementInsertAdjacentHTML, "insertAdjacentHTML", 2));
    // attachShadow stub — returns the element itself as a pseudo-shadow root
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "attachShadow", qjs.JS_NewCFunction(ctx, &elementAttachShadow, "attachShadow", 1));
    // shadowRoot default = null (not undefined — many libs check `el.shadowRoot &&`)
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "shadowRoot", quickjs.JS_NULL());
    // HTMLTemplateElement.content getter (returns DocumentFragment for <template> elements)
    {
        const contentAtom = qjs.JS_NewAtom(ctx, "content");
        _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, contentAtom, qjs.JS_NewCFunction(ctx, &templateGetContent, "get content", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, contentAtom);
    }
    // Popover API stubs (GitHub checks showPopover existence)
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "showPopover", qjs.JS_NewCFunction(ctx, &jsReturnNull, "showPopover", 0));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "hidePopover", qjs.JS_NewCFunction(ctx, &jsReturnNull, "hidePopover", 0));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "togglePopover", qjs.JS_NewCFunction(ctx, &jsReturnNull, "togglePopover", 0));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "insertAdjacentElement", qjs.JS_NewCFunction(ctx, &elementInsertAdjacentElement, "insertAdjacentElement", 2));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "insertAdjacentText", qjs.JS_NewCFunction(ctx, &elementInsertAdjacentText, "insertAdjacentText", 2));

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
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, datasetAtom, qjs.JS_NewCFunction(ctx, &elementGetDataset, "get dataset", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, datasetAtom);
    }
    {
        const offsetWidthAtom = qjs.JS_NewAtom(ctx, "offsetWidth");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, offsetWidthAtom, qjs.JS_NewCFunction(ctx, &elementGetOffsetWidth, "get offsetWidth", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, offsetWidthAtom);
    }
    {
        const offsetHeightAtom = qjs.JS_NewAtom(ctx, "offsetHeight");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, offsetHeightAtom, qjs.JS_NewCFunction(ctx, &elementGetOffsetHeight, "get offsetHeight", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, offsetHeightAtom);
    }
    {
        const offsetTopAtom = qjs.JS_NewAtom(ctx, "offsetTop");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, offsetTopAtom, qjs.JS_NewCFunction(ctx, &elementGetOffsetTop, "get offsetTop", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, offsetTopAtom);
    }
    {
        const offsetLeftAtom = qjs.JS_NewAtom(ctx, "offsetLeft");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, offsetLeftAtom, qjs.JS_NewCFunction(ctx, &elementGetOffsetLeft, "get offsetLeft", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, offsetLeftAtom);
    }
    // clientWidth/clientHeight (padding box) and clientTop/clientLeft (border widths)
    {
        const cwAtom = qjs.JS_NewAtom(ctx, "clientWidth");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, cwAtom, qjs.JS_NewCFunction(ctx, &elementGetClientWidth, "get clientWidth", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, cwAtom);
    }
    {
        const chAtom = qjs.JS_NewAtom(ctx, "clientHeight");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, chAtom, qjs.JS_NewCFunction(ctx, &elementGetClientHeight, "get clientHeight", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, chAtom);
    }
    {
        const ctAtom = qjs.JS_NewAtom(ctx, "clientTop");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, ctAtom, qjs.JS_NewCFunction(ctx, &elementGetClientTop, "get clientTop", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, ctAtom);
    }
    {
        const clAtom = qjs.JS_NewAtom(ctx, "clientLeft");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, clAtom, qjs.JS_NewCFunction(ctx, &elementGetClientLeft, "get clientLeft", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, clAtom);
    }
    // scrollWidth/scrollHeight (same as clientWidth/Height for now — no overflow tracking)
    {
        const swAtom = qjs.JS_NewAtom(ctx, "scrollWidth");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, swAtom, qjs.JS_NewCFunction(ctx, &elementGetClientWidth, "get scrollWidth", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, swAtom);
    }
    {
        const shAtom = qjs.JS_NewAtom(ctx, "scrollHeight");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, shAtom, qjs.JS_NewCFunction(ctx, &elementGetClientHeight, "get scrollHeight", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, shAtom);
    }
    {
        const scrollTopAtom = qjs.JS_NewAtom(ctx, "scrollTop");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, scrollTopAtom, qjs.JS_NewCFunction(ctx, &elementGetScrollTop, "get scrollTop", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, scrollTopAtom);
    }
    {
        const scrollLeftAtom = qjs.JS_NewAtom(ctx, "scrollLeft");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, scrollLeftAtom, qjs.JS_NewCFunction(ctx, &elementGetScrollLeft, "get scrollLeft", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, scrollLeftAtom);
    }
    {
        const hiddenAtom = qjs.JS_NewAtom(ctx, "hidden");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, hiddenAtom, qjs.JS_NewCFunction(ctx, &elementGetHidden, "get hidden", 0), qjs.JS_NewCFunction(ctx, &elementSetHidden, "set hidden", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, hiddenAtom);
    }

    // input.value / textarea.value / select.value
    {
        const valueAtom = qjs.JS_NewAtom(ctx, "value");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, valueAtom, qjs.JS_NewCFunction(ctx, &elementGetValue, "get value", 0), qjs.JS_NewCFunction(ctx, &elementSetValue, "set value", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, valueAtom);
    }

    // Set HTMLElement.prototype as the class prototype (elements get this as their __proto__)
    qjs.JS_SetClassProto(ctx, element_class_id, qjs.JS_DupValue(ctx, html_element_proto));

    // ── Expose constructors as globals for instanceof ──────────────
    const global = qjs.JS_GetGlobalObject(ctx);

    const event_target_ctor = qjs.JS_NewCFunction2(ctx, &jsNoOpConstructor, "EventTarget", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, event_target_ctor, "prototype", qjs.JS_DupValue(ctx, event_target_proto));
    _ = qjs.JS_SetPropertyStr(ctx, global, "EventTarget", event_target_ctor);

    const node_ctor = qjs.JS_NewCFunction2(ctx, &jsNoOpConstructor, "Node", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "prototype", qjs.JS_DupValue(ctx, node_proto));
    // Node constants on the constructor too
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "ELEMENT_NODE", qjs.JS_NewInt32(ctx, 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "TEXT_NODE", qjs.JS_NewInt32(ctx, 3));
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "COMMENT_NODE", qjs.JS_NewInt32(ctx, 8));
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "DOCUMENT_NODE", qjs.JS_NewInt32(ctx, 9));
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "DOCUMENT_FRAGMENT_NODE", qjs.JS_NewInt32(ctx, 11));
    _ = qjs.JS_SetPropertyStr(ctx, global, "Node", node_ctor);

    const element_ctor = qjs.JS_NewCFunction2(ctx, &jsNoOpConstructor, "Element", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, element_ctor, "prototype", qjs.JS_DupValue(ctx, elem_proto));
    _ = qjs.JS_SetPropertyStr(ctx, global, "Element", element_ctor);

    const html_element_ctor = qjs.JS_NewCFunction2(ctx, &jsNoOpConstructor, "HTMLElement", 0, qjs.JS_CFUNC_constructor, 0);
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
    };
    for (html_subclasses) |name| {
        const ctor = qjs.JS_NewCFunction2(ctx, &jsNoOpConstructor, name.ptr, 0, qjs.JS_CFUNC_constructor, 0);
        _ = qjs.JS_SetPropertyStr(ctx, ctor, "prototype", qjs.JS_DupValue(ctx, html_element_proto));
        _ = qjs.JS_SetPropertyStr(ctx, global, name.ptr, ctor);
    }

    // DOM interface constructors (for instanceof checks in frameworks)
    const window_ctor = qjs.JS_NewCFunction2(ctx, &jsNoOpConstructor, "Window", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, global, "Window", window_ctor);

    const document_ctor = qjs.JS_NewCFunction2(ctx, &jsNoOpConstructor, "Document", 0, qjs.JS_CFUNC_constructor, 0);
    const doc_proto = qjs.JS_NewObject(ctx);
    // Document.prototype needs DOM query methods (popover polyfill monkey-patches these)
    _ = qjs.JS_SetPropertyStr(ctx, doc_proto, "querySelector", qjs.JS_NewCFunction(ctx, &documentQuerySelector, "querySelector", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_proto, "querySelectorAll", qjs.JS_NewCFunction(ctx, &documentQuerySelectorAll, "querySelectorAll", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_proto, "getElementById", qjs.JS_NewCFunction(ctx, &documentGetElementById, "getElementById", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_proto, "getElementsByClassName", qjs.JS_NewCFunction(ctx, &documentGetElementsByClassName, "getElementsByClassName", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_proto, "getElementsByTagName", qjs.JS_NewCFunction(ctx, &documentGetElementsByTagName, "getElementsByTagName", 1));
    _ = qjs.JS_SetPropertyStr(ctx, document_ctor, "prototype", doc_proto);
    _ = qjs.JS_SetPropertyStr(ctx, global, "Document", document_ctor);

    const doc_frag_ctor = qjs.JS_NewCFunction2(ctx, &jsNoOpConstructor, "DocumentFragment", 0, qjs.JS_CFUNC_constructor, 0);
    {
        const dfp = qjs.JS_NewObject(ctx);
        _ = qjs.JS_SetPropertyStr(ctx, dfp, "querySelector", qjs.JS_NewCFunction(ctx, &elementQuerySelector, "querySelector", 1));
        _ = qjs.JS_SetPropertyStr(ctx, dfp, "querySelectorAll", qjs.JS_NewCFunction(ctx, &elementQuerySelectorAll, "querySelectorAll", 1));
        _ = qjs.JS_SetPropertyStr(ctx, doc_frag_ctor, "prototype", dfp);
    }
    _ = qjs.JS_SetPropertyStr(ctx, global, "DocumentFragment", doc_frag_ctor);

    const nodelist_ctor = qjs.JS_NewCFunction2(ctx, &jsNoOpConstructor, "NodeList", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, global, "NodeList", nodelist_ctor);

    const htmlcol_ctor = qjs.JS_NewCFunction2(ctx, &jsNoOpConstructor, "HTMLCollection", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, global, "HTMLCollection", htmlcol_ctor);

    const range_ctor = qjs.JS_NewCFunction2(ctx, &jsNoOpConstructor, "Range", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, global, "Range", range_ctor);

    const comment_ctor = qjs.JS_NewCFunction2(ctx, &jsNoOpConstructor, "Comment", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, global, "Comment", comment_ctor);

    const text_ctor = qjs.JS_NewCFunction2(ctx, &jsNoOpConstructor, "Text", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, global, "Text", text_ctor);

    const shadow_root_ctor = qjs.JS_NewCFunction2(ctx, &jsNoOpConstructor, "ShadowRoot", 0, qjs.JS_CFUNC_constructor, 0);
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
            \\  ['src','href','action','type','name','alt','title','rel','target','placeholder','method','enctype','lang','dir','for'].forEach(function(a){
            \\    if(!(a in EP)){Object.defineProperty(EP,a,{get:function(){return this.getAttribute(a)||'';},set:function(v){this.setAttribute(a,v);},configurable:true});}
            \\  });
            \\  ['disabled','checked','selected','autofocus'].forEach(function(a){
            \\    if(!(a in EP)){Object.defineProperty(EP,a,{get:function(){return this.hasAttribute(a);},set:function(v){if(v)this.setAttribute(a,'');else this.removeAttribute(a);},configurable:true});}
            \\  });
            \\  Object.defineProperty(EP,'tabIndex',{get:function(){var v=this.getAttribute('tabindex');return v!==null?parseInt(v,10)||0:-1;},set:function(v){this.setAttribute('tabindex',String(v));},configurable:true});
            \\  Object.defineProperty(EP,'id',{get:function(){return this.getAttribute('id')||'';},set:function(v){this.setAttribute('id',v);},configurable:true});
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

    // ── Text prototype (inherits Node.prototype) ─────────────────────
    // Text/Comment/PI nodes get CharacterData methods via this prototype.
    const text_proto = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPrototype(ctx, text_proto, node_proto);

    // CharacterData: data/nodeValue native getter + JS-wrapped setter (handles null→"" per DOM spec)
    // We expose native getter as __nativeGetData and native setter as __nativeSetData,
    // then wrap them in JS to handle type coercion.
    _ = qjs.JS_SetPropertyStr(ctx, text_proto, "__nativeGetData", qjs.JS_NewCFunction(ctx, &textGetData, "__nativeGetData", 0));
    _ = qjs.JS_SetPropertyStr(ctx, text_proto, "__nativeSetData", qjs.JS_NewCFunction(ctx, &textSetData, "__nativeSetData", 1));

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
            \\Object.defineProperty(P,'wholeText',{get:function(){return this.data;},configurable:true});
            \\P.appendData=function(d){if(arguments.length<1)throw new TypeError("Failed to execute 'appendData': 1 argument required");this.data+=''+d;};
            \\P.insertData=function(o,d){if(arguments.length<2)throw new TypeError("Failed to execute 'insertData': 2 arguments required");var s=this.data;o=o>>>0;if(o>s.length)throw new DOMException('The index is not in the allowed range.','IndexSizeError');this.data=s.slice(0,o)+d+s.slice(o);};
            \\P.deleteData=function(o,c){if(arguments.length<2)throw new TypeError("Failed to execute 'deleteData': 2 arguments required");var s=this.data;o=o>>>0;c=c>>>0;if(o>s.length)throw new DOMException('The index is not in the allowed range.','IndexSizeError');this.data=s.slice(0,o)+s.slice(o+c);};
            \\P.replaceData=function(o,c,d){if(arguments.length<3)throw new TypeError("Failed to execute 'replaceData': 3 arguments required");var s=this.data;o=o>>>0;c=c>>>0;if(o>s.length)throw new DOMException('The index is not in the allowed range.','IndexSizeError');this.data=s.slice(0,o)+d+s.slice(o+c);};
            \\P.substringData=function(o,c){if(arguments.length<2)throw new TypeError("Failed to execute 'substringData': 2 arguments required");var s=this.data;o=o>>>0;c=c>>>0;if(o>s.length)throw new DOMException('The index is not in the allowed range.','IndexSizeError');return s.slice(o,o+c);};
            \\delete P.__nativeGetData;delete P.__nativeSetData;
            \\function noChild(m){return function(){throw new DOMException("Failed to execute '"+m+"' on 'Node': This node type does not support this method.",'HierarchyRequestError');};}
            \\P.appendChild=noChild('appendChild');P.insertBefore=noChild('insertBefore');
            \\P.removeChild=noChild('removeChild');P.replaceChild=noChild('replaceChild');
            \\P.replaceChildren=noChild('replaceChildren');P.prepend=noChild('prepend');P.append=noChild('append');
            \\})(__tp);delete __tp;
        ;
        const r = qjs.JS_Eval(ctx, cd_js, cd_js.len, "<chardata>", qjs.JS_EVAL_TYPE_GLOBAL);
        qjs.JS_FreeValue(ctx, r);
    }

    qjs.JS_SetClassProto(ctx, text_class_id, text_proto);

    // Free local proto references (class proto + constructors hold refs)
    qjs.JS_FreeValue(ctx, event_target_proto);
    qjs.JS_FreeValue(ctx, node_proto);
    qjs.JS_FreeValue(ctx, elem_proto);
    qjs.JS_FreeValue(ctx, html_element_proto);

    // Build document global
    const doc_obj = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "getElementById", qjs.JS_NewCFunction(ctx, &documentGetElementById, "getElementById", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "querySelector", qjs.JS_NewCFunction(ctx, &documentQuerySelector, "querySelector", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "querySelectorAll", qjs.JS_NewCFunction(ctx, &documentQuerySelectorAll, "querySelectorAll", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createElement", qjs.JS_NewCFunction(ctx, &documentCreateElement, "createElement", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createElementNS", qjs.JS_NewCFunction(ctx, &documentCreateElementNS, "createElementNS", 2));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createTextNode", qjs.JS_NewCFunction(ctx, &documentCreateTextNode, "createTextNode", 1));
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
            \\(function(name){return document.createAttributeNS(null,name.toLowerCase());})
        ;
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createAttribute", qjs.JS_Eval(ctx, create_attr_js, create_attr_js.len, "<attr>", qjs.JS_EVAL_TYPE_GLOBAL));
    }
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createDocumentFragment", qjs.JS_NewCFunction(ctx, &documentCreateDocumentFragment, "createDocumentFragment", 0));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createEvent", qjs.JS_NewCFunction(ctx, &documentCreateEvent, "createEvent", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "write", qjs.JS_NewCFunction(ctx, &documentWrite, "write", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "writeln", qjs.JS_NewCFunction(ctx, &documentWrite, "writeln", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "getElementsByClassName", qjs.JS_NewCFunction(ctx, &documentGetElementsByClassName, "getElementsByClassName", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "getElementsByTagName", qjs.JS_NewCFunction(ctx, &documentGetElementsByTagName, "getElementsByTagName", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "getElementsByTagNameNS", qjs.JS_NewCFunction(ctx, &documentGetElementsByTagName, "getElementsByTagNameNS", 2));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "getElementsByName", qjs.JS_NewCFunction(ctx, &documentGetElementsByName, "getElementsByName", 1));

    // document.adoptNode / importNode (stub — return the node as-is)
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "adoptNode", qjs.JS_NewCFunction(ctx, &documentAdoptNode, "adoptNode", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "importNode", qjs.JS_NewCFunction(ctx, &documentImportNode, "importNode", 2));
    // document.createRange (stub)
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createRange", qjs.JS_NewCFunction(ctx, &documentCreateRange, "createRange", 0));
    // document.createTreeWalker
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createTreeWalker", qjs.JS_NewCFunction(ctx, &documentCreateTreeWalker, "createTreeWalker", 3));
    // document.createNodeIterator
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createNodeIterator", qjs.JS_NewCFunction(ctx, &documentCreateTreeWalker, "createNodeIterator", 3));

    // document.readyState (getter)
    const readyStateAtom = qjs.JS_NewAtom(ctx, "readyState");
    _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, readyStateAtom, qjs.JS_NewCFunction(ctx, &documentGetReadyState, "get readyState", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, readyStateAtom);

    // document.activeElement (getter)
    {
        const activeElementAtom = qjs.JS_NewAtom(ctx, "activeElement");
        _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, activeElementAtom, qjs.JS_NewCFunction(ctx, &documentGetActiveElement, "get activeElement", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, activeElementAtom);
    }

    // document.location (alias to window.location)
    {
        const loc = qjs.JS_GetPropertyStr(ctx, global, "location");
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "location", loc);
    }

    // document.body (getter)
    const bodyAtom = qjs.JS_NewAtom(ctx, "body");
    _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, bodyAtom, qjs.JS_NewCFunction(ctx, &documentGetBody, "get body", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, bodyAtom);

    // document.title (getter)
    const titleAtom = qjs.JS_NewAtom(ctx, "title");
    _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, titleAtom, qjs.JS_NewCFunction(ctx, &documentGetTitle, "get title", 0), qjs.JS_NewCFunction(ctx, &documentSetTitle, "set title", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, titleAtom);

    // document.documentElement (getter)
    const docElemAtom = qjs.JS_NewAtom(ctx, "documentElement");
    _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, docElemAtom, qjs.JS_NewCFunction(ctx, &documentGetDocumentElement, "get documentElement", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, docElemAtom);

    // document.currentScript (null when not in script execution)
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "currentScript", quickjs.JS_NULL());

    // document.head (getter)
    const headAtom = qjs.JS_NewAtom(ctx, "head");
    _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, headAtom, qjs.JS_NewCFunction(ctx, &documentGetHead, "get head", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, headAtom);

    // document.cookie (getter/setter)
    const cookieAtom = qjs.JS_NewAtom(ctx, "cookie");
    _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, cookieAtom, qjs.JS_NewCFunction(ctx, &documentGetCookie, "get cookie", 0), qjs.JS_NewCFunction(ctx, &documentSetCookie, "set cookie", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, cookieAtom);

    // document.URL / referrer / domain
    if (g_current_url) |url| {
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "URL", qjs.JS_NewStringLen(ctx, url.ptr, url.len));
        const domain = extractDomain(url) orelse "";
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
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createComment", qjs.JS_NewCFunction(ctx, &documentCreateComment, "createComment", 1));

    // document.createProcessingInstruction(target, data)
    {
        const pi_js =
            \\(function(target, data) {
            \\  var pi = {nodeType:7, nodeName:target, target:target, data:data||'',
            \\          textContent:data||'', nodeValue:data||'', childNodes:[]};
            \\  pi.isEqualNode = function(o) {
            \\    if (!o || o.nodeType !== 7) return false;
            \\    return this.target === o.target && this.data === o.data;
            \\  };
            \\  pi.isSameNode = function(o) { return this === o; };
            \\  return pi;
            \\})
        ;
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createProcessingInstruction", qjs.JS_Eval(ctx,
            pi_js, pi_js.len, "<pi>", qjs.JS_EVAL_TYPE_GLOBAL));
    }

    // Document properties required by jQuery/Sizzle
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "nodeType", qjs.JS_NewInt32(ctx, 9)); // DOCUMENT_NODE
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "nodeName", qjs.JS_NewString(ctx, "#document"));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "defaultView", qjs.JS_DupValue(ctx, global)); // window
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "ownerDocument", quickjs.JS_NULL());
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "compatMode", qjs.JS_NewString(ctx, "CSS1Compat"));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "contentType", qjs.JS_NewString(ctx, "text/html"));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "characterSet", qjs.JS_NewString(ctx, "UTF-8"));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "charset", qjs.JS_NewString(ctx, "UTF-8")); // alias
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "inputEncoding", qjs.JS_NewString(ctx, "UTF-8")); // alias
    // document.doctype — stub as simple object matching the page's DOCTYPE
    {
        const dt_js =
            \\(function(){return {nodeType:10,name:'html',publicId:'',systemId:'',
            \\  nodeName:'html',ownerDocument:document,
            \\  isEqualNode:function(o){return o&&o.nodeType===10&&o.name===this.name&&o.publicId===this.publicId&&o.systemId===this.systemId;},
            \\  isSameNode:function(o){return this===o;}
            \\};})()
        ;
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "doctype", qjs.JS_Eval(ctx, dt_js, dt_js.len, "<doctype>", qjs.JS_EVAL_TYPE_GLOBAL));
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
            \\    t.textContent = title;
            \\    head.appendChild(t);
            \\  }
            \\  d.appendChild(head);
            \\  d.appendChild(body);
            \\  var doc = {
            \\    nodeType: 9, nodeName: '#document',
            \\    documentElement: d, head: head, body: body,
            \\    childNodes: [d], children: [d], firstChild: d, lastChild: d,
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
            \\    URL: 'about:blank',
            \\    documentURI: 'about:blank',
            \\    compatMode: 'CSS1Compat',
            \\    doctype: null,
            \\    defaultView: null,
            \\    hasFocus: function() { return false; },
            \\    cloneNode: function(deep) {
            \\      var nd = document.implementation.createHTMLDocument(title);
            \\      if(deep && d.innerHTML) nd.documentElement.innerHTML = d.innerHTML;
            \\      return nd;
            \\    },
            \\  };
            \\  return doc;
            \\})
        ;
        _ = qjs.JS_SetPropertyStr(ctx, impl, "createHTMLDocument", qjs.JS_Eval(ctx,
            create_html_doc_js, create_html_doc_js.len, "<impl>", qjs.JS_EVAL_TYPE_GLOBAL));
        const has_feature_js = "(function() { return true; })";
        _ = qjs.JS_SetPropertyStr(ctx, impl, "hasFeature", qjs.JS_Eval(ctx,
            has_feature_js, has_feature_js.len, "<impl>", qjs.JS_EVAL_TYPE_GLOBAL));
        _ = qjs.JS_SetPropertyStr(ctx, impl, "createDocumentType", qjs.JS_NewCFunction(ctx, &implCreateDocumentType, "createDocumentType", 3));
        _ = qjs.JS_SetPropertyStr(ctx, impl, "createDocument", qjs.JS_NewCFunction(ctx, &implCreateDocument, "createDocument", 3));
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "implementation", impl);
    }
    // document.adoptedStyleSheets (used by CSS-in-JS / popover polyfills)
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "adoptedStyleSheets", qjs.JS_NewArray(ctx));

    // Set document global (reuses `global` from constructor registration above)
    _ = qjs.JS_SetPropertyStr(ctx, global, "document", doc_obj);

    // Document constructor (new Document() creates a standalone XML document-like object)
    {
        const doc_ctor_js =
            \\(function() {
            \\  function Document() {
            \\    this.nodeType = 9;
            \\    this.nodeName = '#document';
            \\    this.childNodes = [];
            \\    this.children = [];
            \\    this.firstChild = null;
            \\    this.lastChild = null;
            \\    this.documentElement = null;
            \\  }
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
            \\  Document.prototype.appendChild = function(n) {
            \\    this.childNodes.push(n);
            \\    this.children.push(n);
            \\    this.firstChild = this.childNodes[0];
            \\    this.lastChild = this.childNodes[this.childNodes.length-1];
            \\    if(n.nodeType===1 && !this.documentElement) this.documentElement = n;
            \\    return n;
            \\  };
            \\  Document.prototype.importNode = function(n,d) { return n.cloneNode(d); };
            \\  Document.prototype.adoptNode = function(n) { return n; };
            \\  Document.prototype.implementation = document.implementation;
            \\  return Document;
            \\})()
        ;
        const ctor = qjs.JS_Eval(ctx, doc_ctor_js, doc_ctor_js.len, "<Document>", qjs.JS_EVAL_TYPE_GLOBAL);
        _ = qjs.JS_SetPropertyStr(ctx, global, "Document", ctor);
    }

    // window.location
    _ = qjs.JS_SetPropertyStr(ctx, global, "location", createLocationObject(ctx));

    // window.getComputedStyle
    _ = qjs.JS_SetPropertyStr(ctx, global, "getComputedStyle", qjs.JS_NewCFunction(ctx, &windowGetComputedStyle, "getComputedStyle", 1));

    // CSS global object with supports() method
    {
        const css_obj = qjs.JS_NewObject(ctx);
        _ = qjs.JS_SetPropertyStr(ctx, css_obj, "supports", qjs.JS_NewCFunction(ctx, &cssSupports, "supports", 2));
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

    qjs.JS_FreeValue(ctx, global);
}

// wrapNodePublic/getNodePublic moved to top of file (near wrapNode/getNode)

// ── CSS Value Validation (for element.style setter) ─────────────────

/// Check if a CSS value is valid for a given property name.
/// Used by styleSetProperty to reject invalid values per WPT spec.
fn isValidCssValue(prop: []const u8, val: []const u8) bool {
    const trimmed = std.mem.trim(u8, val, " \t\r\n");
    if (trimmed.len == 0) return true; // empty = remove property

    // CSS-wide keywords always valid for any property
    if (eqlIgnoreCase(trimmed, "inherit") or eqlIgnoreCase(trimmed, "initial") or
        eqlIgnoreCase(trimmed, "unset") or eqlIgnoreCase(trimmed, "revert")) return true;

    // var() always valid
    if (trimmed.len >= 4 and eqlIgnoreCase(trimmed[0..4], "var(")) return true;

    // Math functions valid if complete function call (ends with matching ')')
    if (trimmed[trimmed.len - 1] == ')') {
        if (trimmed.len >= 6 and eqlIgnoreCase(trimmed[0..5], "calc(")) return true;
        if (trimmed.len >= 5 and eqlIgnoreCase(trimmed[0..4], "min(")) return true;
        if (trimmed.len >= 5 and eqlIgnoreCase(trimmed[0..4], "max(")) return true;
        if (trimmed.len >= 7 and eqlIgnoreCase(trimmed[0..6], "clamp(")) return true;
        if (trimmed.len >= 7 and eqlIgnoreCase(trimmed[0..6], "round(")) return true;
        if (trimmed.len >= 5 and eqlIgnoreCase(trimmed[0..4], "mod(")) return true;
        if (trimmed.len >= 5 and eqlIgnoreCase(trimmed[0..4], "rem(")) return true;
        if (trimmed.len >= 5 and eqlIgnoreCase(trimmed[0..4], "abs(")) return true;
        if (trimmed.len >= 6 and eqlIgnoreCase(trimmed[0..5], "sign(")) return true;
        // Color functions
        if (trimmed.len >= 5 and eqlIgnoreCase(trimmed[0..4], "hwb(")) return true;
        if (trimmed.len >= 5 and eqlIgnoreCase(trimmed[0..4], "lab(")) return true;
        if (trimmed.len >= 5 and eqlIgnoreCase(trimmed[0..4], "lch(")) return true;
        if (trimmed.len >= 7 and eqlIgnoreCase(trimmed[0..6], "oklab(")) return true;
        if (trimmed.len >= 7 and eqlIgnoreCase(trimmed[0..6], "oklch(")) return true;
        if (trimmed.len >= 7 and eqlIgnoreCase(trimmed[0..6], "color(")) return true;
    }

    const prop_id = css_ast.PropertyId.fromString(prop);
    if (prop_id == .custom) return true;

    // Handle shorthand properties that map to .unknown in PropertyId
    if (prop_id == .unknown) {
        return isValidShorthandValue(prop, trimmed);
    }

    return switch (prop_id) {
        // Size properties: accept auto, lengths (non-negative), %, min/max/fit-content
        .width, .height, .min_width, .min_height => isValidSizeValue(trimmed, false),
        // max-width/max-height accept "none" but NOT "auto"
        .max_width, .max_height => isValidMaxSizeValue(trimmed),
        // Margin: accept auto, lengths (can be negative), %
        .margin_top, .margin_right, .margin_bottom, .margin_left => isValidMarginValue(trimmed),
        // Padding: like size, non-negative lengths and %
        .padding_top, .padding_right, .padding_bottom, .padding_left => isValidNonNegLength(trimmed),
        // Border widths: non-negative lengths or thin/medium/thick
        .border_top_width, .border_right_width, .border_bottom_width, .border_left_width => isValidBorderWidth(trimmed),
        // Display: all CSS display values (single and two-value syntax)
        .display => isValidDisplayValue(trimmed),
        // Color properties
        .color, .background_color, .border_top_color, .border_right_color,
        .border_bottom_color, .border_left_color => css_properties.parseColor(trimmed) != null or isValidColorKeyword(trimmed),
        // Numeric properties
        .opacity => blk: {
            if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '%') {
                break :blk std.fmt.parseFloat(f32, trimmed[0 .. trimmed.len - 1]) != error.InvalidCharacter;
            }
            break :blk std.fmt.parseFloat(f32, trimmed) != error.InvalidCharacter;
        },
        .z_index => std.fmt.parseInt(i32, trimmed, 10) != error.InvalidCharacter or eqlIgnoreCase(trimmed, "auto"),
        .flex_grow, .flex_shrink => isNonNegNumber(trimmed),
        // Font size: non-negative length or keyword
        .font_size => isValidFontSize(trimmed),
        // Font weight: number 1-1000 or keyword
        .font_weight => isValidFontWeight(trimmed),
        // Line height: normal, non-negative number, non-negative length
        .line_height => isValidLineHeight(trimmed),
        // Top/right/bottom/left: auto, lengths (can be negative), %
        .top, .right, .bottom, .left => isValidMarginValue(trimmed),
        // Float: none, left, right, inline-start, inline-end (NOT auto)
        .float_ => eqlIgnoreCase(trimmed, "none") or eqlIgnoreCase(trimmed, "left") or
            eqlIgnoreCase(trimmed, "right") or eqlIgnoreCase(trimmed, "inline-start") or
            eqlIgnoreCase(trimmed, "inline-end"),
        // Clear: none, left, right, both, inline-start, inline-end (NOT auto)
        .clear => eqlIgnoreCase(trimmed, "none") or eqlIgnoreCase(trimmed, "left") or
            eqlIgnoreCase(trimmed, "right") or eqlIgnoreCase(trimmed, "both") or
            eqlIgnoreCase(trimmed, "inline-start") or eqlIgnoreCase(trimmed, "inline-end"),
        // margin-trim: none, block, inline, block-start, block-end, inline-start, inline-end
        .margin_trim => isValidMarginTrimValue(trimmed),
        // reading-flow: normal, flex-visual, flex-flow, grid-rows, grid-columns, grid-order
        .reading_flow => eqlIgnoreCase(trimmed, "normal") or eqlIgnoreCase(trimmed, "flex-visual") or
            eqlIgnoreCase(trimmed, "flex-flow") or eqlIgnoreCase(trimmed, "grid-rows") or
            eqlIgnoreCase(trimmed, "grid-columns") or eqlIgnoreCase(trimmed, "grid-order") or
            eqlIgnoreCase(trimmed, "source-order"),
        // reading-order: <integer>
        .reading_order => std.fmt.parseInt(i32, trimmed, 10) != error.InvalidCharacter,
        // Visibility: visible, hidden, collapse (NOT auto, NOT none)
        .visibility => eqlIgnoreCase(trimmed, "visible") or eqlIgnoreCase(trimmed, "hidden") or
            eqlIgnoreCase(trimmed, "collapse"),
        // Overflow: visible, hidden, scroll, auto, clip (NOT none)
        .overflow_x, .overflow_y => isValidOverflowValue(trimmed),
        // text-wrap: wrap, nowrap, balance, pretty, stable, auto
        .text_wrap => eqlIgnoreCase(trimmed, "wrap") or eqlIgnoreCase(trimmed, "nowrap") or
            eqlIgnoreCase(trimmed, "balance") or eqlIgnoreCase(trimmed, "pretty") or
            eqlIgnoreCase(trimmed, "stable") or eqlIgnoreCase(trimmed, "auto"),
        // text-wrap-mode: wrap, nowrap
        .text_wrap_mode => eqlIgnoreCase(trimmed, "wrap") or eqlIgnoreCase(trimmed, "nowrap"),
        // text-wrap-style: auto, balance, pretty, stable
        .text_wrap_style => eqlIgnoreCase(trimmed, "auto") or eqlIgnoreCase(trimmed, "balance") or
            eqlIgnoreCase(trimmed, "pretty") or eqlIgnoreCase(trimmed, "stable"),
        // tab-size: non-negative number or non-negative length
        .tab_size => isNonNegNumber(trimmed) or isValidNonNegLength(trimmed),
        // hyphens: none, manual, auto
        .hyphens => eqlIgnoreCase(trimmed, "none") or eqlIgnoreCase(trimmed, "manual") or eqlIgnoreCase(trimmed, "auto"),
        // Keyword-only properties: delegate to parseValue, check for .raw
        else => blk: {
            const parsed = css_properties.parseValue(prop_id, val);
            break :blk switch (parsed) {
                .raw => false,
                else => true,
            };
        },
    };
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn isValidShorthandValue(prop: []const u8, val: []const u8) bool {
    // margin/padding shorthand: 1-4 values, each valid for the longhand
    if (eqlIgnoreCase(prop, "margin") or eqlIgnoreCase(prop, "margin-block") or
        eqlIgnoreCase(prop, "margin-inline"))
    {
        return isValidBoxShorthand(val, true);
    }
    if (eqlIgnoreCase(prop, "padding") or eqlIgnoreCase(prop, "padding-block") or
        eqlIgnoreCase(prop, "padding-inline"))
    {
        return isValidBoxShorthand(val, false);
    }
    if (eqlIgnoreCase(prop, "overflow")) {
        // overflow shorthand: 1-2 values from {visible, hidden, scroll, auto, clip}
        return isValidOverflowShorthand(val);
    }
    // Known shorthand properties that we don't deeply validate — accept
    const known_shorthands = [_][]const u8{
        "border", "border-top", "border-right", "border-bottom", "border-left",
        "border-radius", "border-color", "border-width", "border-style",
        "background", "font", "flex", "flex-flow", "transition", "animation",
        "text-decoration", "list-style", "outline", "grid", "grid-template",
        "grid-template-columns", "grid-template-rows", "grid-area", "grid-column",
        "grid-row", "gap", "place-content", "place-items", "place-self",
        "columns", "column-rule", "inset",
    };
    for (known_shorthands) |kw| {
        if (eqlIgnoreCase(prop, kw)) return true;
    }
    // Unknown property name — reject
    return false;
}

fn isValidBoxShorthand(val: []const u8, allow_negative: bool) bool {
    // Split by whitespace (respecting parentheses for calc() etc.), validate 1-4 parts
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < val.len) {
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
        const part = val[start..pos];
        count += 1;
        if (count > 4) return false;
        // calc()/var() parts are always valid
        if (part.len >= 5 and eqlIgnoreCase(part[0..5], "calc(") and part[part.len - 1] == ')') continue;
        if (part.len >= 4 and eqlIgnoreCase(part[0..4], "var(") and part[part.len - 1] == ')') continue;
        if (allow_negative) {
            if (!isValidMarginValue(part)) return false;
        } else {
            if (!isValidNonNegLength(part)) return false;
        }
    }
    return count >= 1 and count <= 4;
}

fn isValidDisplayValue(val: []const u8) bool {
    // Single-keyword display values
    const single = [_][]const u8{
        "none",          "contents",       "block",          "inline",
        "inline-block",  "flex",           "inline-flex",    "grid",
        "inline-grid",   "table",          "inline-table",   "list-item",
        "run-in",        "flow",           "flow-root",      "ruby",
        "ruby-base",     "ruby-text",      "ruby-base-container", "ruby-text-container",
        "table-row",     "table-cell",     "table-row-group", "table-header-group",
        "table-footer-group", "table-column", "table-column-group", "table-caption",
        "math",          "grid-lanes",     "inline-grid-lanes",
    };
    for (single) |kw| {
        if (eqlIgnoreCase(val, kw)) return true;
    }
    // Multi-value display: order-independent token classification
    // CSS Display 3: <display-outside> || <display-inside> | <display-listitem>
    // <display-outside> = block | inline | run-in
    // <display-inside> = flow | flow-root | table | flex | grid | ruby
    // <display-listitem> = <display-outside>? && [flow | flow-root]? && list-item
    const outside_kw = [_][]const u8{ "block", "inline", "run-in" };
    const inside_kw = [_][]const u8{ "flow", "flow-root", "table", "flex", "grid", "ruby", "grid-lanes" };

    var tokens: [3][]const u8 = .{ "", "", "" };
    var token_count: usize = 0;
    var pos: usize = 0;
    while (pos < val.len and token_count < 4) {
        while (pos < val.len and (val[pos] == ' ' or val[pos] == '\t')) pos += 1;
        if (pos >= val.len) break;
        const start = pos;
        while (pos < val.len and val[pos] != ' ' and val[pos] != '\t') pos += 1;
        if (token_count >= 3) return false; // >3 tokens invalid
        tokens[token_count] = val[start..pos];
        token_count += 1;
    }
    if (token_count < 2) return false;

    var has_outside = false;
    var has_inside = false;
    var has_list_item = false;
    var inside_is_flow_compat = false; // flow or flow-root (allowed with list-item)
    for (0..token_count) |i| {
        const tok = tokens[i];
        var matched = false;
        for (outside_kw) |kw| {
            if (eqlIgnoreCase(tok, kw)) {
                if (has_outside) return false; // duplicate outside
                has_outside = true;
                matched = true;
                break;
            }
        }
        if (!matched) {
            for (inside_kw) |kw| {
                if (eqlIgnoreCase(tok, kw)) {
                    if (has_inside) return false; // duplicate inside
                    has_inside = true;
                    if (eqlIgnoreCase(tok, "flow") or eqlIgnoreCase(tok, "flow-root"))
                        inside_is_flow_compat = true;
                    matched = true;
                    break;
                }
            }
        }
        if (!matched) {
            if (eqlIgnoreCase(tok, "list-item")) {
                if (has_list_item) return false;
                has_list_item = true;
                matched = true;
            }
        }
        if (!matched) return false; // unknown token
    }

    if (has_list_item) {
        // list-item only combines with flow/flow-root (not flex/grid/table/ruby)
        if (has_inside and !inside_is_flow_compat) return false;
        return true;
    }
    // outside + inside is valid (any combo)
    if (has_outside and has_inside) return true;
    return false;
}

/// Canonicalize a CSS display value to its shortest canonical form.
/// "block flow" → "block", "inline flow-root" → "inline-block", etc.
/// Returns only static string literals or the input — no buffer needed.
fn canonicalizeDisplayValue(val: []const u8) []const u8 {
    // Parse tokens (up to 3)
    var tokens: [3][]const u8 = .{ "", "", "" };
    var token_count: usize = 0;
    var pos: usize = 0;
    while (pos < val.len and token_count < 3) {
        while (pos < val.len and (val[pos] == ' ' or val[pos] == '\t')) pos += 1;
        if (pos >= val.len) break;
        const start = pos;
        while (pos < val.len and val[pos] != ' ' and val[pos] != '\t') pos += 1;
        tokens[token_count] = val[start..pos];
        token_count += 1;
    }

    if (token_count <= 1) {
        // Single-keyword canonical forms
        if (eqlIgnoreCase(val, "flow")) return "block";
        return val;
    }

    // Extract outer, inner, list-item
    var has_block = false;
    var has_inline = false;
    var has_run_in = false;
    var has_flow = false;
    var has_flow_root = false;
    var has_flex = false;
    var has_grid = false;
    var has_table = false;
    var has_ruby = false;
    var has_list_item = false;
    for (0..token_count) |i| {
        const tok = tokens[i];
        if (eqlIgnoreCase(tok, "block")) has_block = true
        else if (eqlIgnoreCase(tok, "inline")) has_inline = true
        else if (eqlIgnoreCase(tok, "run-in")) has_run_in = true
        else if (eqlIgnoreCase(tok, "flow")) has_flow = true
        else if (eqlIgnoreCase(tok, "flow-root")) has_flow_root = true
        else if (eqlIgnoreCase(tok, "flex")) has_flex = true
        else if (eqlIgnoreCase(tok, "grid")) has_grid = true
        else if (eqlIgnoreCase(tok, "table")) has_table = true
        else if (eqlIgnoreCase(tok, "ruby")) has_ruby = true
        else if (eqlIgnoreCase(tok, "list-item")) has_list_item = true;
    }

    if (!has_list_item) {
        if (has_flow or (!has_flow_root and !has_flex and !has_grid and !has_table and !has_ruby)) {
            if (has_block or (!has_inline and !has_run_in)) return "block";
            if (has_inline) return "inline";
            if (has_run_in) return "run-in";
        }
        if (has_flow_root) {
            if (has_block or (!has_inline and !has_run_in)) return "flow-root";
            if (has_inline) return "inline-block";
            if (has_run_in) return "run-in flow-root";
        }
        if (has_flex) {
            if (has_block or (!has_inline and !has_run_in)) return "flex";
            if (has_inline) return "inline-flex";
            if (has_run_in) return "run-in flex";
        }
        if (has_grid) {
            if (has_block or (!has_inline and !has_run_in)) return "grid";
            if (has_inline) return "inline-grid";
            if (has_run_in) return "run-in grid";
        }
        if (has_table) {
            if (has_block or (!has_inline and !has_run_in)) return "table";
            if (has_inline) return "inline-table";
            if (has_run_in) return "run-in table";
        }
        if (has_ruby) {
            if (has_inline) return "ruby";
            if (has_block) return "block ruby";
            if (has_run_in) return "run-in ruby";
        }
        return val; // unrecognized combo
    }

    // With list-item
    if (has_flow or (!has_flow_root and !has_flex and !has_grid and !has_table)) {
        if (has_block or (!has_inline and !has_run_in)) return "list-item";
        if (has_inline) return "inline list-item";
        if (has_run_in) return "run-in list-item";
    }
    if (has_flow_root) {
        if (has_block or (!has_inline and !has_run_in)) return "flow-root list-item";
        if (has_inline) return "inline flow-root list-item";
        if (has_run_in) return "run-in flow-root list-item";
    }
    return val;
}

/// Evaluate round(), mod(), rem() to calc(result) for constant numeric args.
fn canonicalizeRoundModRem(val: []const u8, buf: *[512]u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, val, " \t\r\n");
    if (trimmed[trimmed.len - 1] != ')') return null;

    var func_name: []const u8 = undefined;
    var prefix_len: usize = 0;
    if (trimmed.len >= 6 and eqlIgnoreCase(trimmed[0..6], "round(")) {
        func_name = "round";
        prefix_len = 6;
    } else if (trimmed.len >= 4 and eqlIgnoreCase(trimmed[0..4], "mod(")) {
        func_name = "mod";
        prefix_len = 4;
    } else if (trimmed.len >= 4 and eqlIgnoreCase(trimmed[0..4], "rem(")) {
        func_name = "rem";
        prefix_len = 4;
    } else return null;

    const inner = std.mem.trim(u8, trimmed[prefix_len .. trimmed.len - 1], " ");

    // Split on comma
    var comma_pos: ?usize = null;
    var depth: usize = 0;
    for (inner, 0..) |ch, i| {
        if (ch == '(') depth += 1
        else if (ch == ')') { if (depth > 0) depth -= 1; }
        else if (ch == ',' and depth == 0) { comma_pos = i; break; }
    }
    if (comma_pos == null) return null;
    const a_str = std.mem.trim(u8, inner[0..comma_pos.?], " ");
    const b_str = std.mem.trim(u8, inner[comma_pos.? + 1 ..], " ");

    // Try to parse both as numbers
    const a = std.fmt.parseFloat(f64, a_str) catch return null;
    const b = std.fmt.parseFloat(f64, b_str) catch return null;

    var result: f64 = undefined;
    if (std.mem.eql(u8, func_name, "round")) {
        if (b == 0) return null;
        result = @round(a / b) * b;
    } else if (std.mem.eql(u8, func_name, "mod")) {
        if (b == 0) return null;
        result = a - b * @floor(a / b); // CSS mod (always matches sign of b)
    } else if (std.mem.eql(u8, func_name, "rem")) {
        if (b == 0) return null;
        result = a - b * @trunc(a / b); // CSS rem (matches sign of a)
    }

    // Format as calc(result)
    const s = std.fmt.bufPrint(buf, "calc({d})", .{result}) catch return null;
    return canonicalizeCalcValue(s, buf);
}

/// Distributive expansion for calc():
/// "N * (A + B)" → recursively canonicalize "calc(N*A + N*B)"
/// "(A + B) / N" → recursively canonicalize "calc(A/N + B/N)"
/// "(expr) * N" → "calc(N * (expr))" when expr has functions (reorder only)
fn tryDistributiveExpansion(inner: []const u8, buf: *[512]u8) ?[]const u8 {
    // Pattern 1: "N * (expr)" where N is a number
    if (std.mem.indexOf(u8, inner, " * (")) |mul_pos| {
        const left = std.mem.trim(u8, inner[0..mul_pos], " ");
        // Check left is a plain number
        const scalar = std.fmt.parseFloat(f64, left) catch return null;
        _ = scalar;
        const rest = inner[mul_pos + 3 ..]; // "(expr)"
        if (rest.len < 2 or rest[0] != '(') return null;
        // Find matching closing paren
        const close = findMatchingParen(rest, 0) orelse return null;
        if (close != rest.len - 1) return null; // must be the last thing
        const expr_inner = rest[1..close];

        // If expr contains min()/max()/clamp(), don't expand, just emit as-is
        if (containsFunction(expr_inner)) {
            // Already in canonical form: "N * (expr)"
            var out: usize = 0;
            const prefix = "calc(";
            @memcpy(buf[out..][0..prefix.len], prefix);
            out += prefix.len;
            const emit = inner;
            if (out + emit.len + 1 <= buf.len) {
                @memcpy(buf[out..][0..emit.len], emit);
                out += emit.len;
                buf[out] = ')';
                out += 1;
                return buf[0..out];
            }
            return null;
        }

        // Distribute: N * (A + B - C) → N*A + N*B - N*C
        // Build expanded string and recursively canonicalize
        var exp_buf: [512]u8 = undefined;
        var exp_pos: usize = 0;
        const exp_prefix = "calc(";
        @memcpy(exp_buf[exp_pos..][0..exp_prefix.len], exp_prefix);
        exp_pos += exp_prefix.len;

        // Split expr_inner by + and - (top-level only)
        var epos: usize = 0;
        var first_term = true;
        while (epos < expr_inner.len) {
            while (epos < expr_inner.len and expr_inner[epos] == ' ') epos += 1;
            if (epos >= expr_inner.len) break;

            var term_sign: u8 = '+';
            if (!first_term) {
                if (expr_inner[epos] == '+') {
                    epos += 1;
                    while (epos < expr_inner.len and expr_inner[epos] == ' ') epos += 1;
                } else if (expr_inner[epos] == '-') {
                    term_sign = '-';
                    epos += 1;
                    while (epos < expr_inner.len and expr_inner[epos] == ' ') epos += 1;
                }
            }

            const tstart = epos;
            var nest: usize = 0;
            while (epos < expr_inner.len) {
                if (expr_inner[epos] == '(') nest += 1
                else if (expr_inner[epos] == ')') { if (nest > 0) nest -= 1; }
                else if (nest == 0 and epos > tstart and
                    (expr_inner[epos] == '+' or (expr_inner[epos] == '-' and epos > 0 and expr_inner[epos - 1] == ' ')))
                    break;
                epos += 1;
            }
            const term = std.mem.trim(u8, expr_inner[tstart..epos], " ");
            if (term.len == 0) continue;

            // Emit: " + N * term" or " - N * term"
            if (!first_term) {
                if (exp_pos + 3 >= exp_buf.len) return null;
                exp_buf[exp_pos] = ' ';
                exp_buf[exp_pos + 1] = term_sign;
                exp_buf[exp_pos + 2] = ' ';
                exp_pos += 3;
            }
            // Write "left * term"
            if (exp_pos + left.len + 3 + term.len >= exp_buf.len) return null;
            @memcpy(exp_buf[exp_pos..][0..left.len], left);
            exp_pos += left.len;
            @memcpy(exp_buf[exp_pos..][0..3], " * ");
            exp_pos += 3;
            @memcpy(exp_buf[exp_pos..][0..term.len], term);
            exp_pos += term.len;

            first_term = false;
        }
        if (exp_pos + 1 > exp_buf.len) return null;
        exp_buf[exp_pos] = ')';
        exp_pos += 1;

        // Recursively canonicalize
        return canonicalizeCalcValue(exp_buf[0..exp_pos], buf);
    }

    // Pattern 2: "(expr) * N" — reorder to "N * (expr)" and retry
    if (inner.len > 4 and inner[0] == '(') {
        const close = findMatchingParen(inner, 0) orelse return null;
        if (close + 3 < inner.len) {
            const after_paren = std.mem.trim(u8, inner[close + 1 ..], " ");
            if (after_paren.len > 2 and after_paren[0] == '*' and after_paren[1] == ' ') {
                const scalar_str = std.mem.trim(u8, after_paren[2..], " ");
                // Verify it's a number
                _ = std.fmt.parseFloat(f64, scalar_str) catch return null;
                // Reorder to "N * (expr)"
                var reorder_buf: [512]u8 = undefined;
                var rpos: usize = 0;
                const rprefix = "calc(";
                @memcpy(reorder_buf[rpos..][0..rprefix.len], rprefix);
                rpos += rprefix.len;
                @memcpy(reorder_buf[rpos..][0..scalar_str.len], scalar_str);
                rpos += scalar_str.len;
                @memcpy(reorder_buf[rpos..][0..3], " * ");
                rpos += 3;
                @memcpy(reorder_buf[rpos..][0..close + 1], inner[0 .. close + 1]);
                rpos += close + 1;
                reorder_buf[rpos] = ')';
                rpos += 1;
                return canonicalizeCalcValue(reorder_buf[0..rpos], buf);
            }
        }
    }

    // Pattern 3: "(expr) / N" — distribute division
    if (inner.len > 4 and inner[0] == '(') {
        const close = findMatchingParen(inner, 0) orelse return null;
        if (close + 3 < inner.len) {
            const after_paren = std.mem.trim(u8, inner[close + 1 ..], " ");
            if (after_paren.len > 2 and after_paren[0] == '/' and after_paren[1] == ' ') {
                const divisor_str = std.mem.trim(u8, after_paren[2..], " ");
                _ = std.fmt.parseFloat(f64, divisor_str) catch return null;
                const expr_inner = inner[1..close];

                if (containsFunction(expr_inner)) return null;

                // Distribute: (A + B) / N → A / N + B / N
                var exp_buf: [512]u8 = undefined;
                var exp_pos: usize = 0;
                const exp_prefix = "calc(";
                @memcpy(exp_buf[exp_pos..][0..exp_prefix.len], exp_prefix);
                exp_pos += exp_prefix.len;

                var epos: usize = 0;
                var first_term = true;
                while (epos < expr_inner.len) {
                    while (epos < expr_inner.len and expr_inner[epos] == ' ') epos += 1;
                    if (epos >= expr_inner.len) break;
                    var term_sign: u8 = '+';
                    if (!first_term) {
                        if (expr_inner[epos] == '+') {
                            epos += 1;
                            while (epos < expr_inner.len and expr_inner[epos] == ' ') epos += 1;
                        } else if (expr_inner[epos] == '-') {
                            term_sign = '-';
                            epos += 1;
                            while (epos < expr_inner.len and expr_inner[epos] == ' ') epos += 1;
                        }
                    }
                    const tstart = epos;
                    var nest: usize = 0;
                    while (epos < expr_inner.len) {
                        if (expr_inner[epos] == '(') nest += 1
                        else if (expr_inner[epos] == ')') { if (nest > 0) nest -= 1; }
                        else if (nest == 0 and epos > tstart and
                            (expr_inner[epos] == '+' or (expr_inner[epos] == '-' and epos > 0 and expr_inner[epos - 1] == ' ')))
                            break;
                        epos += 1;
                    }
                    const term = std.mem.trim(u8, expr_inner[tstart..epos], " ");
                    if (term.len == 0) continue;
                    if (!first_term) {
                        if (exp_pos + 3 >= exp_buf.len) return null;
                        exp_buf[exp_pos] = ' ';
                        exp_buf[exp_pos + 1] = term_sign;
                        exp_buf[exp_pos + 2] = ' ';
                        exp_pos += 3;
                    }
                    if (exp_pos + term.len + 3 + divisor_str.len >= exp_buf.len) return null;
                    @memcpy(exp_buf[exp_pos..][0..term.len], term);
                    exp_pos += term.len;
                    @memcpy(exp_buf[exp_pos..][0..3], " / ");
                    exp_pos += 3;
                    @memcpy(exp_buf[exp_pos..][0..divisor_str.len], divisor_str);
                    exp_pos += divisor_str.len;
                    first_term = false;
                }
                if (exp_pos + 1 > exp_buf.len) return null;
                exp_buf[exp_pos] = ')';
                exp_pos += 1;
                return canonicalizeCalcValue(exp_buf[0..exp_pos], buf);
            }
        }
    }

    return null;
}

fn findMatchingParen(s: []const u8, start: usize) ?usize {
    if (start >= s.len or s[start] != '(') return null;
    var depth: usize = 0;
    for (s[start..], start..) |ch, i| {
        if (ch == '(') depth += 1
        else if (ch == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn containsFunction(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "min(") != null or
        std.mem.indexOf(u8, s, "max(") != null or
        std.mem.indexOf(u8, s, "clamp(") != null;
}

/// Canonicalize a calc() expression per CSS Values 4 §11.3:
/// 1. Convert absolute length units (in, cm, mm, pt, pc, q) to px
/// 2. Combine terms with the same unit
/// 3. Reorder: numbers, %, then dimensions by unit (ASCII)
/// 4. Serialize with canonical sign handling
fn canonicalizeCalcValue(val: []const u8, buf: *[512]u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, val, " \t\r\n");
    if (trimmed.len < 6) return null;
    if (!eqlIgnoreCase(trimmed[0..5], "calc(")) return null;
    if (trimmed[trimmed.len - 1] != ')') return null;
    const raw_inner = std.mem.trim(u8, trimmed[5 .. trimmed.len - 1], " ");
    if (raw_inner.len == 0) return null;

    // Flatten nested calc(): "9pt + calc(9rem + 10px)" → "9pt + 9rem + 10px"
    // Removes "calc(" and its matching ")" while preserving min()/max() parens.
    var flat_buf: [512]u8 = undefined;
    var flat_pos: usize = 0;
    {
        var k: usize = 0;
        var calc_depth: usize = 0; // track nesting of stripped calc() parens
        var paren_depth: [16]usize = undefined; // paren depth at each calc strip
        while (k < raw_inner.len) {
            if (k + 5 <= raw_inner.len and eqlIgnoreCase(raw_inner[k..][0..5], "calc(")) {
                // Strip this calc( — record current paren nesting to find matching )
                if (calc_depth < 16) {
                    // Count how deep in parens we are at this point in flat output
                    var depth: usize = 0;
                    for (flat_buf[0..flat_pos]) |ch| {
                        if (ch == '(') depth += 1 else if (ch == ')') {
                            if (depth > 0) depth -= 1;
                        }
                    }
                    paren_depth[calc_depth] = depth;
                    calc_depth += 1;
                }
                k += 5; // skip "calc("
            } else if (raw_inner[k] == ')' and calc_depth > 0) {
                // Check if this ) matches a stripped calc(
                var depth: usize = 0;
                for (flat_buf[0..flat_pos]) |ch| {
                    if (ch == '(') depth += 1 else if (ch == ')') {
                        if (depth > 0) depth -= 1;
                    }
                }
                if (depth == paren_depth[calc_depth - 1]) {
                    // This ) matches the stripped calc( — skip it
                    calc_depth -= 1;
                    k += 1;
                } else {
                    // This ) belongs to something else (min/max) — keep it
                    if (flat_pos < flat_buf.len) {
                        flat_buf[flat_pos] = raw_inner[k];
                        flat_pos += 1;
                    }
                    k += 1;
                }
            } else {
                if (flat_pos < flat_buf.len) {
                    flat_buf[flat_pos] = raw_inner[k];
                    flat_pos += 1;
                }
                k += 1;
            }
        }
    }
    const inner = std.mem.trim(u8, flat_buf[0..flat_pos], " ");
    if (inner.len == 0) return null;

    // Distributive expansion: "N * (A + B)" → "N*A + N*B", "(A + B) / N" → "A/N + B/N"
    // Also handle scalar reordering: "(expr) * N" → "N * (expr)" when expr contains functions
    if (tryDistributiveExpansion(inner, buf)) |expanded| return expanded;

    // Parsed term: numeric value + canonical unit
    const CalcTerm = struct { value: f64, unit: []const u8 };
    var terms: [32]CalcTerm = undefined;
    var term_count: usize = 0;
    // Per-term unit buffers (each term may need its own lowercased unit)
    var unit_bufs: [32][16]u8 = undefined;
    var pos: usize = 0;

    while (pos < inner.len and term_count < 32) {
        while (pos < inner.len and (inner[pos] == ' ' or inner[pos] == '\t')) pos += 1;
        if (pos >= inner.len) break;

        // Detect operator sign
        var sign: f64 = 1.0;
        if (inner[pos] == '+') {
            pos += 1;
            while (pos < inner.len and inner[pos] == ' ') pos += 1;
        } else if (inner[pos] == '-') {
            sign = -1.0;
            pos += 1;
            while (pos < inner.len and inner[pos] == ' ') pos += 1;
        }

        // Read term (stop at next + or - with space before it)
        const term_start = pos;
        var nesting: usize = 0;
        while (pos < inner.len) {
            if (inner[pos] == '(') nesting += 1
            else if (inner[pos] == ')') { if (nesting > 0) nesting -= 1; }
            else if (nesting == 0 and pos > term_start and
                (inner[pos] == '+' or (inner[pos] == '-' and pos > 0 and inner[pos - 1] == ' ')))
                break;
            pos += 1;
        }
        const term_str = std.mem.trimRight(u8, inner[term_start..pos], " ");
        if (term_str.len == 0) continue;

        // Can't canonicalize nested functions (but allow * and / within a term)
        var has_paren = false;
        for (term_str) |ch| {
            if (ch == '(') { has_paren = true; break; }
        }
        if (has_paren) return null;

        // Handle multiplication/division within a term: "4 * 3px", "4pc / 8"
        var num_val: f64 = undefined;
        var raw_unit: []const u8 = undefined;
        if (std.mem.indexOf(u8, term_str, " * ")) |mul_pos| {
            // scalar * dimension OR dimension * scalar
            const left = std.mem.trim(u8, term_str[0..mul_pos], " ");
            const right_s = std.mem.trim(u8, term_str[mul_pos + 3 ..], " ");
            const lp = parseNumUnit(left);
            const rp = parseNumUnit(right_s);
            if (lp == null or rp == null) return null;
            if (lp.?.unit.len == 0 and rp.?.unit.len > 0) {
                num_val = lp.?.value * rp.?.value;
                raw_unit = rp.?.unit;
            } else if (lp.?.unit.len > 0 and rp.?.unit.len == 0) {
                num_val = lp.?.value * rp.?.value;
                raw_unit = lp.?.unit;
            } else return null; // both have units or both unitless — can't simplify
        } else if (std.mem.indexOf(u8, term_str, " / ")) |div_pos| {
            // dimension / scalar
            const left = std.mem.trim(u8, term_str[0..div_pos], " ");
            const right_s = std.mem.trim(u8, term_str[div_pos + 3 ..], " ");
            const lp = parseNumUnit(left);
            const rp = parseNumUnit(right_s);
            if (lp == null or rp == null) return null;
            if (rp.?.unit.len > 0) return null; // division by dimension
            if (@abs(rp.?.value) < 1e-20) return null; // div by zero
            num_val = lp.?.value / rp.?.value;
            raw_unit = lp.?.unit;
        } else {
            // Simple number+unit
            const p = parseNumUnit(term_str) orelse return null;
            num_val = p.value;
            raw_unit = p.unit;
        }
        const value = sign * num_val;

        // Convert absolute units to px
        const unit_lower = blk: {
            var ubuf: [16]u8 = undefined;
            for (raw_unit, 0..) |ch, k| {
                if (k >= 16) break;
                ubuf[k] = std.ascii.toLower(ch);
            }
            break :blk ubuf[0..@min(raw_unit.len, 16)];
        };
        var final_value = value;
        var final_unit: []const u8 = raw_unit;
        if (std.mem.eql(u8, unit_lower, "in")) {
            final_value = value * 96.0;
            final_unit = "px";
        } else if (std.mem.eql(u8, unit_lower, "cm")) {
            final_value = value * (96.0 / 2.54);
            final_unit = "px";
        } else if (std.mem.eql(u8, unit_lower, "mm")) {
            final_value = value * (96.0 / 25.4);
            final_unit = "px";
        } else if (std.mem.eql(u8, unit_lower, "q")) {
            final_value = value * (96.0 / 101.6);
            final_unit = "px";
        } else if (std.mem.eql(u8, unit_lower, "pt")) {
            final_value = value * (96.0 / 72.0);
            final_unit = "px";
        } else if (std.mem.eql(u8, unit_lower, "pc")) {
            final_value = value * 16.0;
            final_unit = "px";
        } else {
            // Lowercase the unit for canonical form — use per-term buffer
            for (raw_unit, 0..) |ch, k| {
                if (k >= 16) break;
                unit_bufs[term_count][k] = std.ascii.toLower(ch);
            }
            final_unit = unit_bufs[term_count][0..@min(raw_unit.len, 16)];
        }

        // Try to combine with existing term of same unit
        var combined = false;
        for (0..term_count) |k| {
            if (std.mem.eql(u8, terms[k].unit, final_unit)) {
                terms[k].value += final_value;
                combined = true;
                break;
            }
        }
        if (!combined) {
            terms[term_count] = .{ .value = final_value, .unit = final_unit };
            term_count += 1;
        }
    }

    if (term_count == 0) return null;

    // Sort: unitless (0), % (1), dimensions by unit ASCII (2+)
    var indices: [32]usize = undefined;
    for (0..term_count) |k| indices[k] = k;
    var i: usize = 1;
    while (i < term_count) : (i += 1) {
        var j = i;
        while (j > 0) {
            const a_u = terms[indices[j - 1]].unit;
            const b_u = terms[indices[j]].unit;
            if (calcUnitCmp(a_u, b_u) <= 0) break;
            const tmp = indices[j];
            indices[j] = indices[j - 1];
            indices[j - 1] = tmp;
            j -= 1;
        }
    }

    // Serialize
    var out: usize = 0;
    const pfx = "calc(";
    @memcpy(buf[out..][0..pfx.len], pfx);
    out += pfx.len;

    for (0..term_count) |idx| {
        const t = terms[indices[idx]];
        const is_neg = t.value < -1e-10;
        const abs_val = @abs(t.value);

        if (idx == 0) {
            if (is_neg) {
                buf[out] = '-';
                out += 1;
            }
        } else {
            if (is_neg) {
                @memcpy(buf[out..][0..3], " - ");
                out += 3;
            } else {
                @memcpy(buf[out..][0..3], " + ");
                out += 3;
            }
        }

        // Format number: integer if possible, else float
        const formatted = fmtCalcNum(abs_val, buf[out..][0..64]) orelse return null;
        out += formatted.len;

        // Unit
        if (out + t.unit.len >= buf.len) return null;
        @memcpy(buf[out..][0..t.unit.len], t.unit);
        out += t.unit.len;
    }

    buf[out] = ')';
    out += 1;
    return buf[0..out];
}

/// Parse a simple "number+unit" string into value and unit.
fn parseNumUnit(s: []const u8) ?struct { value: f64, unit: []const u8 } {
    var ne: usize = 0;
    if (ne < s.len and (s[ne] == '-' or s[ne] == '+')) ne += 1;
    while (ne < s.len and (s[ne] >= '0' and s[ne] <= '9' or s[ne] == '.')) ne += 1;
    if (ne == 0) return null;
    const v = std.fmt.parseFloat(f64, s[0..ne]) catch return null;
    return .{ .value = v, .unit = s[ne..] };
}

fn fmtCalcNum(val: f64, out: []u8) ?[]const u8 {
    // Integer if no fractional part
    const rounded = @round(val);
    if (@abs(val - rounded) < 1e-6) {
        const int_val: i64 = @intFromFloat(rounded);
        const n = std.fmt.bufPrint(out, "{d}", .{int_val}) catch return null;
        return n;
    }
    // Float, trim trailing zeros
    const n = std.fmt.bufPrint(out, "{d:.6}", .{val}) catch return null;
    var end = n.len;
    while (end > 0 and out[end - 1] == '0') end -= 1;
    if (end > 0 and out[end - 1] == '.') end -= 1;
    return out[0..end];
}

fn calcUnitCmp(a: []const u8, b: []const u8) i32 {
    const a_rank = calcUnitRank(a);
    const b_rank = calcUnitRank(b);
    if (a_rank < b_rank) return -1;
    if (a_rank > b_rank) return 1;
    const max_len = @max(a.len, b.len);
    for (0..max_len) |k| {
        const ac: u8 = if (k < a.len) std.ascii.toLower(a[k]) else 0;
        const bc: u8 = if (k < b.len) std.ascii.toLower(b[k]) else 0;
        if (ac < bc) return -1;
        if (ac > bc) return 1;
    }
    return 0;
}

fn calcUnitRank(unit: []const u8) u8 {
    if (unit.len == 0) return 0;
    if (std.mem.eql(u8, unit, "%")) return 1;
    return 2;
}

/// Simplify single-argument min()/max() to the bare value: min(1px) → calc(1px), min(1%) → 1%
/// Also converts absolute units: min(1in) → calc(96px)
fn canonicalizeSingleArgMath(val: []const u8, buf: *[512]u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, val, " \t\r\n");
    if (trimmed[trimmed.len - 1] != ')') return null;
    // Extract inner content
    var prefix_len: usize = 0;
    if (trimmed.len >= 4 and eqlIgnoreCase(trimmed[0..4], "min(")) prefix_len = 4
    else if (trimmed.len >= 4 and eqlIgnoreCase(trimmed[0..4], "max(")) prefix_len = 4
    else return null;
    const inner = std.mem.trim(u8, trimmed[prefix_len .. trimmed.len - 1], " ");
    // Check: single argument (no commas at top level)
    var nesting: usize = 0;
    for (inner) |ch| {
        if (ch == '(') nesting += 1
        else if (ch == ')') { if (nesting > 0) nesting -= 1; }
        else if (ch == ',' and nesting == 0) return null; // multi-arg
    }

    // Wrap as calc() and canonicalize
    var tmp_buf: [512]u8 = undefined;
    const calc_str = std.fmt.bufPrint(&tmp_buf, "calc({s})", .{inner}) catch return null;
    return canonicalizeCalcValue(calc_str, buf);
}

/// Simplify constant clamp(): clamp(1px, 2px, 3px) → calc(2px) when all args are same-unit constants
fn canonicalizeClamp(val: []const u8, buf: *[512]u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, val, " \t\r\n");
    if (trimmed.len < 7) return null;
    if (!eqlIgnoreCase(trimmed[0..6], "clamp(")) return null;
    if (trimmed[trimmed.len - 1] != ')') return null;
    const inner = std.mem.trim(u8, trimmed[6 .. trimmed.len - 1], " ");
    // Split on commas (top-level only)
    var args: [3][]const u8 = undefined;
    var arg_count: usize = 0;
    var start: usize = 0;
    var nesting: usize = 0;
    for (inner, 0..) |ch, k| {
        if (ch == '(') nesting += 1
        else if (ch == ')') { if (nesting > 0) nesting -= 1; }
        else if (ch == ',' and nesting == 0) {
            if (arg_count >= 3) return null;
            args[arg_count] = std.mem.trim(u8, inner[start..k], " ");
            arg_count += 1;
            start = k + 1;
        }
    }
    if (arg_count < 2) return null;
    args[arg_count] = std.mem.trim(u8, inner[start..], " ");
    arg_count += 1;
    if (arg_count != 3) return null;

    // Parse each arg as number+unit
    const parsed = struct {
        fn parse(s: []const u8) ?struct { value: f64, unit: []const u8 } {
            var ne: usize = 0;
            if (ne < s.len and (s[ne] == '-' or s[ne] == '+')) ne += 1;
            while (ne < s.len and (s[ne] >= '0' and s[ne] <= '9' or s[ne] == '.')) ne += 1;
            if (ne == 0) return null;
            const v = std.fmt.parseFloat(f64, s[0..ne]) catch return null;
            return .{ .value = v, .unit = s[ne..] };
        }
    };
    const min_arg = parsed.parse(args[0]) orelse return null;
    const val_arg = parsed.parse(args[1]) orelse return null;
    const max_arg = parsed.parse(args[2]) orelse return null;
    // All same unit
    if (!std.mem.eql(u8, min_arg.unit, val_arg.unit) or !std.mem.eql(u8, val_arg.unit, max_arg.unit)) return null;
    // Evaluate: clamp(min, val, max) = max(min, min(val, max))
    const result = @max(min_arg.value, @min(val_arg.value, max_arg.value));
    // Convert absolute units
    var calc_str_buf: [128]u8 = undefined;
    const calc_str = std.fmt.bufPrint(&calc_str_buf, "calc({d}{s})", .{ result, min_arg.unit }) catch return null;
    return canonicalizeCalcValue(calc_str, buf);
}

fn isValidMarginTrimValue(val: []const u8) bool {
    const single_keywords = [_][]const u8{ "none", "block", "inline", "block-start", "block-end", "inline-start", "inline-end" };
    for (single_keywords) |kw| {
        if (eqlIgnoreCase(val, kw)) return true;
    }
    // Multi-value parsing
    var has_block_sh = false; // "block" shorthand
    var has_inline_sh = false; // "inline" shorthand
    var has_individual = false;
    var bs = false;
    var be = false;
    var is_ = false;
    var ie = false;
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < val.len) {
        while (pos < val.len and (val[pos] == ' ' or val[pos] == '\t')) pos += 1;
        if (pos >= val.len) break;
        const start = pos;
        while (pos < val.len and val[pos] != ' ' and val[pos] != '\t') pos += 1;
        const kw = val[start..pos];
        count += 1;
        if (count > 4) return false;
        if (eqlIgnoreCase(kw, "block")) {
            if (has_block_sh) return false; // "block block"
            has_block_sh = true;
        } else if (eqlIgnoreCase(kw, "inline")) {
            if (has_inline_sh) return false; // "inline inline"
            has_inline_sh = true;
        } else if (eqlIgnoreCase(kw, "block-start")) {
            if (bs) return false;
            bs = true;
            has_individual = true;
        } else if (eqlIgnoreCase(kw, "block-end")) {
            if (be) return false;
            be = true;
            has_individual = true;
        } else if (eqlIgnoreCase(kw, "inline-start")) {
            if (is_) return false;
            is_ = true;
            has_individual = true;
        } else if (eqlIgnoreCase(kw, "inline-end")) {
            if (ie) return false;
            ie = true;
            has_individual = true;
        } else {
            return false;
        }
    }
    // "block"/"inline" can combine with each other but NOT with individual keywords
    if ((has_block_sh or has_inline_sh) and has_individual) return false;
    return count >= 2;
}

fn isValidOverflowShorthand(val: []const u8) bool {
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < val.len) {
        while (pos < val.len and (val[pos] == ' ' or val[pos] == '\t')) pos += 1;
        if (pos >= val.len) break;
        const start = pos;
        while (pos < val.len and val[pos] != ' ' and val[pos] != '\t') pos += 1;
        const part = val[start..pos];
        count += 1;
        if (count > 2) return false;
        if (!eqlIgnoreCase(part, "visible") and !eqlIgnoreCase(part, "hidden") and
            !eqlIgnoreCase(part, "scroll") and !eqlIgnoreCase(part, "auto") and
            !eqlIgnoreCase(part, "clip")) return false;
    }
    return count >= 1 and count <= 2;
}

fn isValidOverflowValue(val: []const u8) bool {
    return eqlIgnoreCase(val, "visible") or eqlIgnoreCase(val, "hidden") or
        eqlIgnoreCase(val, "scroll") or eqlIgnoreCase(val, "auto") or
        eqlIgnoreCase(val, "clip");
}

fn isValidMaxSizeValue(val: []const u8) bool {
    // max-width/max-height: accept none, lengths (non-negative), %, min/max/fit-content but NOT auto
    if (eqlIgnoreCase(val, "none")) return true;
    if (eqlIgnoreCase(val, "min-content") or eqlIgnoreCase(val, "max-content") or
        eqlIgnoreCase(val, "fit-content")) return true;
    if (val.len > 12 and eqlIgnoreCase(val[0..12], "fit-content(")) return true;
    return isValidNonNegLength(val);
}

fn isValidSizeValue(val: []const u8, allow_none: bool) bool {
    if (eqlIgnoreCase(val, "auto")) return true;
    if (allow_none and eqlIgnoreCase(val, "none")) return true;
    if (eqlIgnoreCase(val, "min-content") or eqlIgnoreCase(val, "max-content") or
        eqlIgnoreCase(val, "fit-content")) return true;
    // fit-content(length)
    if (val.len > 12 and eqlIgnoreCase(val[0..12], "fit-content(")) return true;
    return isValidNonNegLength(val);
}

fn isValidNonNegLength(val: []const u8) bool {
    if (css_properties.parseLength(val)) |len| {
        return len.value >= 0;
    }
    return false;
}

fn isValidMarginValue(val: []const u8) bool {
    if (eqlIgnoreCase(val, "auto")) return true;
    return css_properties.parseLength(val) != null;
}

fn isValidBorderWidth(val: []const u8) bool {
    if (eqlIgnoreCase(val, "thin") or eqlIgnoreCase(val, "medium") or eqlIgnoreCase(val, "thick")) return true;
    return isValidNonNegLength(val);
}

fn isValidColorKeyword(val: []const u8) bool {
    if (eqlIgnoreCase(val, "transparent") or eqlIgnoreCase(val, "currentcolor") or eqlIgnoreCase(val, "currentColor")) return true;
    // Named colors — use parseColor which handles them
    return false;
}

fn isNonNegNumber(val: []const u8) bool {
    const n = std.fmt.parseFloat(f32, val) catch return false;
    return n >= 0;
}

fn isValidFontSize(val: []const u8) bool {
    // Keywords
    const kws = [_][]const u8{ "xx-small", "x-small", "small", "medium", "large", "x-large", "xx-large", "xxx-large", "smaller", "larger" };
    for (kws) |kw| {
        if (eqlIgnoreCase(val, kw)) return true;
    }
    return isValidNonNegLength(val);
}

fn isValidFontWeight(val: []const u8) bool {
    if (eqlIgnoreCase(val, "normal") or eqlIgnoreCase(val, "bold") or
        eqlIgnoreCase(val, "bolder") or eqlIgnoreCase(val, "lighter")) return true;
    const n = std.fmt.parseInt(i32, val, 10) catch return false;
    return n >= 1 and n <= 1000;
}

fn isValidLineHeight(val: []const u8) bool {
    if (eqlIgnoreCase(val, "normal")) return true;
    // Non-negative number (unitless)
    if (std.fmt.parseFloat(f32, val)) |n| {
        return n >= 0;
    } else |_| {}
    return isValidNonNegLength(val);
}
