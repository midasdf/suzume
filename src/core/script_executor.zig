/// Script execution module — extracted from main.zig.
/// Handles finding, fetching, and executing <script> tags in the DOM.
const std = @import("std");
const Document = @import("../dom/tree.zig").Document;
const JsRuntime = @import("../js/runtime.zig").JsRuntime;
const quickjs = @import("../bindings/quickjs.zig");
const lxb = @import("../bindings/lexbor.zig").c;
const web_api = @import("../js/web_api.zig");
const dom_api = @import("../js/dom_api.zig");
const events = @import("../js/events.zig");
const adblock_mod = @import("../features/adblock.zig");
const resolveUrl = @import("../net/loader.zig").resolveUrl;
const Loader = @import("../net/loader.zig").Loader;
const painter_mod = @import("../paint/painter.zig");
const http_status = @import("../net/http_status.zig");

/// Maximum size for a fetched external script (1 MB).
pub const max_external_script_size = 1024 * 1024;
/// Maximum number of external scripts to fetch per page.
pub const max_external_script_count = 50;
/// Maximum total bytes of external scripts to load per page.
pub const max_external_script_total_bytes: usize = 2 * 1024 * 1024;
/// Timeout in seconds for fetching an external script.
pub const external_script_timeout = 5;

/// A script whose execution is deferred until after DOM parsing completes.
pub const DeferredScript = struct {
    code: []const u8, // Owned copy of script content
    is_external: bool,
    is_module: bool = false,
    source_url: ?[:0]const u8 = null,
};

/// Set document.currentScript to a script-like object with the given src URL.
pub fn setCurrentScript(ctx: *quickjs.c.JSContext, src_url: [:0]const u8) void {
    const global = quickjs.c.JS_GetGlobalObject(ctx);
    defer quickjs.c.JS_FreeValue(ctx, global);
    const doc_obj = quickjs.c.JS_GetPropertyStr(ctx, global, "document");
    defer quickjs.c.JS_FreeValue(ctx, doc_obj);
    if (quickjs.JS_IsUndefined(doc_obj) or quickjs.JS_IsNull(doc_obj)) return;

    const script_obj = quickjs.c.JS_NewObject(ctx);
    _ = quickjs.c.JS_SetPropertyStr(ctx, script_obj, "src", quickjs.c.JS_NewStringLen(ctx, src_url.ptr, src_url.len));
    _ = quickjs.c.JS_SetPropertyStr(ctx, script_obj, "type", quickjs.c.JS_NewString(ctx, "text/javascript"));
    _ = quickjs.c.JS_SetPropertyStr(ctx, script_obj, "tagName", quickjs.c.JS_NewString(ctx, "SCRIPT"));
    _ = quickjs.c.JS_SetPropertyStr(ctx, script_obj, "nodeName", quickjs.c.JS_NewString(ctx, "SCRIPT"));
    _ = quickjs.c.JS_SetPropertyStr(ctx, script_obj, "getAttribute", quickjs.c.JS_NewCFunction(ctx, &scriptGetAttribute, "getAttribute", 1));
    _ = quickjs.c.JS_SetPropertyStr(ctx, script_obj, "hasAttribute", quickjs.c.JS_NewCFunction(ctx, &scriptHasAttribute, "hasAttribute", 1));
    _ = quickjs.c.JS_SetPropertyStr(ctx, script_obj, "parentElement", quickjs.JS_NULL());
    _ = quickjs.c.JS_SetPropertyStr(ctx, doc_obj, "currentScript", script_obj);
}

fn scriptGetAttribute(ctx: ?*quickjs.c.JSContext, this_val: quickjs.c.JSValue, argc: c_int, argv: ?[*]quickjs.c.JSValue) callconv(.c) quickjs.c.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    return quickjs.c.JS_GetProperty(c, this_val, quickjs.c.JS_ValueToAtom(c, args[0]));
}

fn scriptHasAttribute(ctx: ?*quickjs.c.JSContext, this_val: quickjs.c.JSValue, argc: c_int, argv: ?[*]quickjs.c.JSValue) callconv(.c) quickjs.c.JSValue {
    _ = ctx;
    if (argc < 1) return quickjs.JS_NewBool(false);
    const args = argv orelse return quickjs.JS_NewBool(false);
    _ = args;
    _ = this_val;
    return quickjs.JS_NewBool(false);
}

/// Clear document.currentScript (set to null).
pub fn clearCurrentScript(ctx: *quickjs.c.JSContext) void {
    const global = quickjs.c.JS_GetGlobalObject(ctx);
    defer quickjs.c.JS_FreeValue(ctx, global);
    const doc_obj = quickjs.c.JS_GetPropertyStr(ctx, global, "document");
    defer quickjs.c.JS_FreeValue(ctx, doc_obj);
    if (quickjs.JS_IsUndefined(doc_obj) or quickjs.JS_IsNull(doc_obj)) return;
    _ = quickjs.c.JS_SetPropertyStr(ctx, doc_obj, "currentScript", quickjs.JS_NULL());
}

/// Find <script> tags in the DOM and execute their content.
/// Deferred scripts are collected during the DOM walk and executed after it completes.
pub fn executeScripts(doc: *Document, js_rt: *JsRuntime, alloc: std.mem.Allocator, loader: ?*Loader, base_url: ?[]const u8) void {
    const doc_node = doc.documentNode();
    var ext_count: usize = 0;
    var deferred: std.ArrayListUnmanaged(DeferredScript) = .empty;
    defer {
        for (deferred.items) |ds| alloc.free(ds.code);
        deferred.deinit(alloc);
    }

    collectAndExecScripts(doc_node.lxb_node, js_rt, alloc, loader, base_url, &ext_count, &deferred);

    // Execute deferred scripts in document order
    for (deferred.items) |ds| {
        std.debug.print("[JS] Executing deferred <script> ({d} bytes, external={any}, module={any})\n", .{ ds.code.len, ds.is_external, ds.is_module });
        if (ds.is_external and ds.source_url != null) {
            setCurrentScript(js_rt.ctx, ds.source_url.?);
        }
        const result = if (ds.is_module)
            js_rt.evalModule(ds.code, ds.source_url orelse "<module>")
        else
            js_rt.evalNamed(ds.code, ds.source_url orelse "<deferred>");
        defer result.deinit();
        if (ds.is_external) clearCurrentScript(js_rt.ctx);
        if (!result.isOk()) {
            std.debug.print("[JS:ERROR] {s}\n", .{result.value()});
        }
        js_rt.executePending();
    }
}

/// Parse a data: URI and return the decoded content.
pub fn parseDataUri(uri: []const u8, allocator: std.mem.Allocator) ?[]u8 {
    if (!std.mem.startsWith(u8, uri, "data:")) return null;
    const after_scheme = uri[5..];

    const comma_idx = std.mem.indexOf(u8, after_scheme, ",") orelse return null;
    const metadata = after_scheme[0..comma_idx];
    const data = after_scheme[comma_idx + 1 ..];

    const is_base64 = std.mem.indexOf(u8, metadata, ";base64") != null;

    if (is_base64) {
        var url_decoded = allocator.alloc(u8, data.len) catch return null;
        var ud_len: usize = 0;
        {
            var i: usize = 0;
            while (i < data.len) {
                if (data[i] == '%' and i + 2 < data.len) {
                    const high = hexDigit(data[i + 1]);
                    const low = hexDigit(data[i + 2]);
                    if (high != null and low != null) {
                        url_decoded[ud_len] = (@as(u8, high.?) << 4) | @as(u8, low.?);
                        ud_len += 1;
                        i += 3;
                        continue;
                    }
                }
                url_decoded[ud_len] = data[i];
                ud_len += 1;
                i += 1;
            }
        }

        var clean_len: usize = 0;
        for (url_decoded[0..ud_len]) |ch| {
            if (ch != ' ' and ch != '\t' and ch != '\r' and ch != '\n') {
                url_decoded[clean_len] = ch;
                clean_len += 1;
            }
        }

        const decoder = std.base64.standard.Decoder;
        const decoded_len = decoder.calcSizeForSlice(url_decoded[0..clean_len]) catch {
            allocator.free(url_decoded);
            return null;
        };
        var decoded = allocator.alloc(u8, decoded_len) catch {
            allocator.free(url_decoded);
            return null;
        };
        decoder.decode(decoded[0..decoded_len], url_decoded[0..clean_len]) catch {
            allocator.free(url_decoded);
            allocator.free(decoded);
            return null;
        };
        allocator.free(url_decoded);
        return decoded;
    } else {
        var result = allocator.alloc(u8, data.len) catch return null;
        var out_pos: usize = 0;
        var i: usize = 0;
        while (i < data.len) {
            if (data[i] == '%' and i + 2 < data.len) {
                const high = hexDigit(data[i + 1]);
                const low = hexDigit(data[i + 2]);
                if (high != null and low != null) {
                    result[out_pos] = (@as(u8, high.?) << 4) | @as(u8, low.?);
                    out_pos += 1;
                    i += 3;
                    continue;
                }
            }
            result[out_pos] = data[i];
            out_pos += 1;
            i += 1;
        }
        const shrunk = allocator.realloc(result, out_pos) catch return result[0..out_pos];
        return shrunk;
    }
}

pub fn hexDigit(c: u8) ?u4 {
    if (c >= '0' and c <= '9') return @intCast(c - '0');
    if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
    return null;
}

/// Recursively walk the DOM tree and collect/execute script elements.
pub fn collectAndExecScripts(node: *lxb.lxb_dom_node_t, js_rt: *JsRuntime, allocator: std.mem.Allocator, loader: ?*Loader, base_url: ?[]const u8, ext_count: *usize, deferred: *std.ArrayListUnmanaged(DeferredScript)) void {
    if (node.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
        const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
        var name_len: usize = 0;
        const name_ptr: ?[*]const u8 = lxb.lxb_dom_element_local_name(elem, &name_len);
        if (name_ptr != null and name_len == 6) {
            if (std.mem.eql(u8, name_ptr.?[0..6], "script")) {
                // Check script type attribute
                var type_len: usize = 0;
                const type_ptr: ?[*]const u8 = lxb.lxb_dom_element_get_attribute(elem, "type", 4, &type_len);
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

                // Skip scripts with nomodule attribute
                var nomod_len: usize = 0;
                const nomod_ptr: ?[*]const u8 = lxb.lxb_dom_element_get_attribute(elem, "nomodule", 8, &nomod_len);
                if (nomod_ptr != null) {
                    return;
                }

                // Check for defer attribute
                var defer_len: usize = 0;
                const defer_ptr: ?[*]const u8 = lxb.lxb_dom_element_get_attribute(elem, "defer", 5, &defer_len);
                const is_defer = (defer_ptr != null);

                // Check for src attribute (external script)
                var src_len: usize = 0;
                const src_ptr: ?[*]const u8 = lxb.lxb_dom_element_get_attribute(elem, "src", 3, &src_len);
                if (src_ptr != null and src_len > 0) {
                    handleExternalScript(src_ptr.?[0..src_len], js_rt, allocator, loader, base_url, ext_count, deferred, is_defer, is_module);
                } else {
                    handleInlineScript(node, js_rt, allocator, deferred, is_defer, is_module);
                }
                return; // Don't recurse into script content
            }
        }
    }
    // Recurse into children
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        collectAndExecScripts(ch, js_rt, allocator, loader, base_url, ext_count, deferred);
        child = ch.next;
    }
}

fn handleExternalScript(
    src: []const u8,
    js_rt: *JsRuntime,
    allocator: std.mem.Allocator,
    loader: ?*Loader,
    base_url: ?[]const u8,
    ext_count: *usize,
    deferred: *std.ArrayListUnmanaged(DeferredScript),
    is_defer: bool,
    is_module: bool,
) void {
    // Resolve URL (absolute http/https/data: or relative to base)
    const resolved_url = if (std.mem.startsWith(u8, src, "http://") or std.mem.startsWith(u8, src, "https://") or std.mem.startsWith(u8, src, "data:")) blk: {
        const u = allocator.allocSentinel(u8, src.len, 0) catch return;
        @memcpy(u, src);
        break :blk u;
    } else if (base_url) |bu|
        resolveUrl(allocator, bu, src) catch return
    else
        return;
    defer allocator.free(resolved_url);

    // Handle data: URIs inline
    if (std.mem.startsWith(u8, resolved_url, "data:")) {
        if (parseDataUri(resolved_url, allocator)) |code| {
            defer allocator.free(code);
            std.debug.print("[JS] Executing data: URI script ({d} bytes)\n", .{code.len});
            const eval_result = js_rt.eval(code);
            if (!eval_result.isOk()) {
                std.debug.print("[JS] data: URI script error: {s}\n", .{eval_result.value()});
            }
            eval_result.deinit();
            js_rt.executePending();
        }
        return;
    }

    // Verify resolved URL is http(s)
    if (!std.mem.startsWith(u8, resolved_url, "http://") and !std.mem.startsWith(u8, resolved_url, "https://")) {
        return;
    }

    const ld = loader orelse return;

    // Skip tracking/analytics scripts when adblock is enabled
    if (ld.adblock_enabled and adblock_mod.isTrackingScript(resolved_url)) {
        std.debug.print("[JS] Skipping tracking script: {s}\n", .{resolved_url});
        return;
    }

    if (ext_count.* >= max_external_script_count) {
        return;
    }

    std.debug.print("[JS] Fetching external script: {s}\n", .{resolved_url});

    var response = ld.loadBytesWithTimeout(resolved_url, external_script_timeout) catch |err| {
        std.debug.print("[JS] Failed to fetch external script {s}: {}\n", .{ resolved_url, err });
        return;
    };

    if (response.status_code != http_status.ok) {
        std.debug.print("[JS] External script returned status {d}: {s}\n", .{ response.status_code, resolved_url });
        response.deinit();
        return;
    }

    if (response.body.len > max_external_script_size) {
        std.debug.print("[JS] External script too large ({d} bytes, max {d}): {s}\n", .{ response.body.len, max_external_script_size, resolved_url });
        response.deinit();
        return;
    }

    ext_count.* += 1;

    if (is_defer) {
        const code_copy = allocator.alloc(u8, response.body.len) catch {
            response.deinit();
            return;
        };
        @memcpy(code_copy, response.body);
        response.deinit();
        std.debug.print("[JS] Deferring external <script src=\"{s}\"> ({d} bytes)\n", .{ resolved_url, code_copy.len });
        const src_url_copy = allocator.allocSentinel(u8, resolved_url.len, 0) catch {
            allocator.free(code_copy);
            return;
        };
        @memcpy(src_url_copy, resolved_url);
        deferred.append(allocator, .{ .code = code_copy, .is_external = true, .is_module = is_module, .source_url = src_url_copy }) catch {
            allocator.free(code_copy);
            allocator.free(src_url_copy);
            return;
        };
    } else {
        const code = response.body;
        std.debug.print("[JS] Executing external <script src=\"{s}\"> ({d} bytes, module={any})\n", .{ resolved_url, code.len, is_module });

        setCurrentScript(js_rt.ctx, resolved_url);

        const result = if (is_module)
            js_rt.evalModule(code, resolved_url)
        else
            js_rt.eval(code);
        defer result.deinit();

        clearCurrentScript(js_rt.ctx);

        if (!result.isOk()) {
            std.debug.print("[JS:ERROR] {s}\n", .{result.value()});
        }
        js_rt.executePending();
        response.deinit();
    }
}

fn handleInlineScript(
    node: *lxb.lxb_dom_node_t,
    js_rt: *JsRuntime,
    allocator: std.mem.Allocator,
    deferred: *std.ArrayListUnmanaged(DeferredScript),
    is_defer: bool,
    is_module: bool,
) void {
    var content_len: usize = 0;
    const content_ptr: ?[*]const u8 = lxb.lxb_dom_node_text_content(node, &content_len);
    if (content_ptr != null and content_len > 0) {
        if (content_len > 512 * 1024) {
            std.debug.print("[JS] Skipping large inline script ({d} bytes)\n", .{content_len});
        } else if (is_defer or is_module) {
            const code = content_ptr.?[0..content_len];
            const code_copy = allocator.alloc(u8, code.len) catch return;
            @memcpy(code_copy, code);
            std.debug.print("[JS] Deferring inline <script> ({d} bytes, module={any})\n", .{ code_copy.len, is_module });
            deferred.append(allocator, .{ .code = code_copy, .is_external = false, .is_module = is_module }) catch {
                allocator.free(code_copy);
                return;
            };
        } else {
            const code = content_ptr.?[0..content_len];
            std.debug.print("[JS] Executing <script> ({d} bytes)\n", .{content_len});
            const result = js_rt.eval(code);
            defer result.deinit();
            if (!result.isOk()) {
                std.debug.print("[JS:ERROR] {s}\n", .{result.value()});
            }
            js_rt.executePending();
        }
    }
}

/// Initialize JavaScript for a loaded page: set up DOM APIs, execute scripts, fire events.
pub fn initPageJs(doc: *Document, page_js_rt: *?JsRuntime, loaded_script_urls: *?std.StringHashMap(void), allocator: std.mem.Allocator, loader: ?*Loader, base_url: ?[]const u8, fonts: ?*painter_mod.FontCache) void {
    var js_rt = JsRuntime.init() catch {
        std.debug.print("[JS] Failed to init JS runtime\n", .{});
        return;
    };

    // Set current URL BEFORE registerDomApis so document.URL is correct
    dom_api.setCurrentUrl(base_url);

    // Register DOM APIs
    dom_api.registerDomApis(js_rt.rt, js_rt.ctx, @ptrCast(@alignCast(doc.html_doc)));

    // Set up top-level FrameState on this JSContext
    dom_api.g_top_frame = .{
        .document = @ptrCast(@alignCast(doc.html_doc)),
        .ctx = js_rt.ctx,
        .current_url = base_url,
    };
    quickjs.c.JS_SetContextOpaque(js_rt.ctx, @ptrCast(&dom_api.g_top_frame));

    // Register event APIs
    events.registerEventApis(js_rt.ctx);
    events.injectElementEventMethods(js_rt.ctx, dom_api.element_class_id);

    // Set JsRuntime and Loader for dynamic script execution
    dom_api.setJsRuntime(&js_rt);
    dom_api.setLoader(loader);
    loaded_script_urls.* = std.StringHashMap(void).init(allocator);
    dom_api.setLoadedScriptUrls(&loaded_script_urls.*.?);

    // Signal that JavaScript is enabled
    signalJsEnabled(doc);

    // readyState = "loading" during script execution
    dom_api.setReadyState(.loading);

    // HTML spec §7.3.3: Named access on Window
    _ = js_rt.eval("try{document.querySelectorAll('[id]').forEach(function(e){if(e.id&&!window[e.id])window[e.id]=e;})}catch(e){}");

    // Process <iframe> elements before scripts
    {
        const doc_node = doc.documentNode().lxb_node;
        dom_api.iframe.processIframes(js_rt.ctx, js_rt.rt, doc_node, &dom_api.g_top_frame, allocator, fonts);
    }

    // Execute <script> tags
    executeScripts(doc, &js_rt, allocator, loader, base_url);

    // Transition readyState and fire events per HTML spec
    dom_api.setReadyState(.interactive);
    events.dispatchDocumentEvent(js_rt.ctx, "readystatechange");
    events.dispatchDocumentEvent(js_rt.ctx, "DOMContentLoaded");
    js_rt.executePending();

    // Tick timers for setTimeout(fn, 0) callbacks.
    // Keep iterations low — heavy JS pages (google.com) can crash QuickJS-ng
    // in timer callbacks. Remaining timers fire safely in the main event loop.
    {
        var timer_iters: u32 = 0;
        while (web_api.tickTimers(js_rt.ctx) and timer_iters < 5) : (timer_iters += 1) {
            js_rt.executePending();
        }
    }

    // Complete loading
    dom_api.setReadyState(.complete);
    events.dispatchDocumentEvent(js_rt.ctx, "readystatechange");
    events.dispatchWindowEvent(js_rt.ctx, "load");
    js_rt.executePending();

    // Fire iframe load events
    dom_api.iframe.fireIframeLoadEvents(js_rt.ctx);
    js_rt.executePending();

    // Final timer tick (limited to avoid crashes on heavy JS pages)
    {
        var timer_iters: u32 = 0;
        while (web_api.tickTimers(js_rt.ctx) and timer_iters < 5) : (timer_iters += 1) {
            js_rt.executePending();
        }
    }

    page_js_rt.* = js_rt;
    // Re-set JsRuntime pointer to page-owned copy (stack var is about to go away)
    dom_api.setJsRuntime(&page_js_rt.*.?);
}

/// Signal that JavaScript is enabled by modifying CSS classes on <html> element.
fn signalJsEnabled(doc: *Document) void {
    const html_node = doc.root() orelse return;
    const html_elem: *lxb.lxb_dom_element_t = @ptrCast(html_node.lxb_node);

    var class_len: usize = 0;
    const class_ptr: ?[*]const u8 = lxb.lxb_dom_element_get_attribute(html_elem, "class", 5, &class_len);
    if (class_ptr == null or class_len == 0) return;

    const old_class = class_ptr.?[0..class_len];

    // Use stack buffer for typical class strings, fall back to heap for long ones (e.g. Tailwind)
    var stack_buf: [8192]u8 = undefined;
    var heap_buf: ?[]u8 = null;
    defer if (heap_buf) |hb| std.heap.c_allocator.free(hb);

    const buf: []u8 = if (class_len <= stack_buf.len)
        &stack_buf
    else blk: {
        heap_buf = std.heap.c_allocator.alloc(u8, class_len) catch return;
        break :blk heap_buf.?;
    };

    @memcpy(buf[0..class_len], old_class);
    var new_class: []u8 = buf[0..class_len];
    var changed = false;

    if (std.mem.indexOf(u8, new_class, "client-nojs")) |pos| {
        const remove_start = pos + 7;
        const remove_len: usize = 2;
        std.mem.copyForwards(u8, new_class[remove_start..], new_class[remove_start + remove_len .. class_len]);
        new_class = new_class[0 .. class_len - remove_len];
        changed = true;
    } else if (std.mem.indexOf(u8, new_class, "no-js")) |pos| {
        const is_start = pos == 0 or new_class[pos - 1] == ' ';
        const end = pos + 5;
        const is_end = end >= new_class.len or new_class[end] == ' ';
        if (is_start and is_end) {
            std.mem.copyForwards(u8, new_class[pos..], new_class[pos + 3 .. new_class.len]);
            new_class = new_class[0 .. new_class.len - 3];
            changed = true;
        }
    }

    if (changed) {
        _ = lxb.lxb_dom_element_set_attribute(html_elem, "class", 5, new_class.ptr, new_class.len);
    }
}

// ══════════════════════════════════════════════════════════════════════
// Kotori JS engine integration
// ══════════════════════════════════════════════════════════════════════

const kotori_rt_mod = @import("kotori_runtime");
const KotoriRuntime = kotori_rt_mod.KotoriRuntime;
const KotoriVM = kotori_rt_mod.VM;
const HttpClient = @import("../net/http.zig").HttpClient;

/// Bridge function: adapts HttpClient.request() to the kotori VM fetch callback signature.
fn kotoriFetchBridge(ctx: *anyopaque, allocator: std.mem.Allocator, url: []const u8, method: []const u8, body: ?[]const u8) ?KotoriVM.HttpFetchResult {
    const client: *HttpClient = @ptrCast(@alignCast(ctx));
    // Need null-terminated URL for libcurl
    const url_z = allocator.dupeZ(u8, url) catch return null;
    defer allocator.free(url_z);
    const method_z: ?[:0]const u8 = if (!std.mem.eql(u8, method, "GET"))
        allocator.dupeZ(u8, method) catch null
    else
        null;
    defer if (method_z) |m| allocator.free(m);

    const response = client.request(allocator, url_z, .{
        .method = method_z,
        .body = body,
        .timeout_secs = 15,
    }) catch return null;

    return .{
        .status = response.status_code,
        .body = response.body,
        .content_type = response.content_type,
    };
}

/// Initialize page JavaScript using the kotori engine (experimental).
/// Simplified path: inline scripts only, no modules/defer/events/timers.
pub fn initPageJsKotori(doc: *Document, page_kotori_rt: *?KotoriRuntime, allocator: std.mem.Allocator, loader: ?*Loader, base_url: ?[]const u8) void {
    const doc_ptr: *anyopaque = @ptrCast(@alignCast(doc.html_doc));

    var krt = KotoriRuntime.init(allocator, doc_ptr) catch {
        std.debug.print("[kotori] Failed to init kotori runtime\n", .{});
        return;
    };

    // Wire up fetch() API if loader is available
    if (loader) |l| {
        krt.setHttpFetcher(@ptrCast(l.client), &kotoriFetchBridge);
    }

    // Execute <script> tags (inline + external)
    const doc_node = doc.documentNode();
    var ext_count: usize = 0;
    kotoriExecScripts(doc_node.lxb_node, &krt, allocator, loader, base_url, &ext_count);

    page_kotori_rt.* = krt;
    std.debug.print("[kotori] Page JS initialized (kotori engine)\n", .{});
}

/// Walk DOM tree and execute <script> tags (inline + external) via kotori.
fn kotoriExecScripts(node: *lxb.lxb_dom_node_t, krt: *KotoriRuntime, allocator: std.mem.Allocator, loader: ?*Loader, base_url: ?[]const u8, ext_count: *usize) void {
    if (node.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
        const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
        var name_len: usize = 0;
        const name_ptr: ?[*]const u8 = lxb.lxb_dom_element_local_name(elem, &name_len);
        if (name_ptr != null and name_len == 6 and std.mem.eql(u8, name_ptr.?[0..6], "script")) {
            // Skip modules and non-JS types
            var type_len: usize = 0;
            const type_ptr: ?[*]const u8 = lxb.lxb_dom_element_get_attribute(elem, "type", 4, &type_len);
            if (type_ptr != null and type_len > 0) {
                const stype = type_ptr.?[0..type_len];
                if (std.mem.eql(u8, stype, "module")) return;
                const is_js = stype.len == 0 or
                    std.mem.eql(u8, stype, "text/javascript") or
                    std.mem.eql(u8, stype, "application/javascript");
                if (!is_js) return;
            }

            // Check for src attribute (external script)
            var src_len: usize = 0;
            const src_ptr: ?[*]const u8 = lxb.lxb_dom_element_get_attribute(elem, "src", 3, &src_len);
            if (src_ptr != null and src_len > 0) {
                kotoriHandleExternalScript(src_ptr.?[0..src_len], krt, allocator, loader, base_url, ext_count);
            } else {
                // Get inline content
                var content_len: usize = 0;
                const content_ptr: ?[*]const u8 = lxb.lxb_dom_node_text_content(node, &content_len);
                if (content_ptr != null and content_len > 0 and content_len <= 512 * 1024) {
                    const code = content_ptr.?[0..content_len];
                    std.debug.print("[kotori] Executing <script> ({d} bytes)\n", .{content_len});
                    const result = krt.eval(code);
                    if (!result.isOk()) {
                        if (result == .err) {
                            std.debug.print("[kotori:ERROR] {s}\n", .{result.err});
                        }
                    }
                }
            }
            return; // Don't recurse into script content
        }
    }
    // Recurse into children
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        kotoriExecScripts(ch, krt, allocator, loader, base_url, ext_count);
        child = ch.next;
    }
}

/// Fetch and execute an external script via kotori engine.
fn kotoriHandleExternalScript(
    src: []const u8,
    krt: *KotoriRuntime,
    allocator: std.mem.Allocator,
    loader: ?*Loader,
    base_url: ?[]const u8,
    ext_count: *usize,
) void {
    // Resolve URL
    const resolved_url = if (std.mem.startsWith(u8, src, "http://") or std.mem.startsWith(u8, src, "https://")) blk: {
        const u = allocator.allocSentinel(u8, src.len, 0) catch return;
        @memcpy(u, src);
        break :blk u;
    } else if (base_url) |bu|
        resolveUrl(allocator, bu, src) catch return
    else
        return;
    defer allocator.free(resolved_url);

    if (!std.mem.startsWith(u8, resolved_url, "http://") and !std.mem.startsWith(u8, resolved_url, "https://")) return;

    const ld = loader orelse return;
    if (ext_count.* >= max_external_script_count) return;

    std.debug.print("[kotori] Fetching external script: {s}\n", .{resolved_url});

    var response = ld.loadBytesWithTimeout(resolved_url, external_script_timeout) catch |err| {
        std.debug.print("[kotori] Failed to fetch external script {s}: {}\n", .{ resolved_url, err });
        return;
    };

    if (response.status_code != http_status.ok) {
        std.debug.print("[kotori] External script returned status {d}: {s}\n", .{ response.status_code, resolved_url });
        response.deinit();
        return;
    }

    if (response.body.len > max_external_script_size) {
        std.debug.print("[kotori] External script too large ({d} bytes): {s}\n", .{ response.body.len, resolved_url });
        response.deinit();
        return;
    }

    ext_count.* += 1;
    const code = response.body;
    std.debug.print("[kotori] Executing external <script src=\"{s}\"> ({d} bytes)\n", .{ resolved_url, code.len });

    const result = krt.eval(code);
    if (!result.isOk()) {
        if (result == .err) {
            std.debug.print("[kotori:ERROR] {s}\n", .{result.err});
        }
    }
    response.deinit();
}
