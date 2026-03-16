const std = @import("std");
const Surface = @import("paint/surface.zig").Surface;
const TextRenderer = @import("paint/text.zig").TextRenderer;
const GlyphBitmap = @import("paint/text.zig").GlyphBitmap;
const Document = @import("dom/tree.zig").Document;
const cascade_mod = @import("style/cascade.zig");
const box_tree = @import("layout/tree.zig");
const block_layout = @import("layout/block.zig");
const painter_mod = @import("paint/painter.zig");
const nsfb_c = @import("bindings/nsfb.zig").c;
const HttpClient = @import("net/http.zig").HttpClient;
const Loader = @import("net/loader.zig").Loader;
const resolveUrl = @import("net/loader.zig").resolveUrl;
const chrome = @import("ui/chrome.zig");
const TextInput = @import("ui/input.zig").TextInput;
const InputResult = @import("ui/input.zig").InputResult;
const Box = @import("layout/box.zig").Box;
const ImageCache = @import("paint/image.zig").ImageCache;
const decodeImage = @import("paint/image.zig").decodeImage;

const window_w = chrome.window_w;
const window_h = chrome.window_h;

// Default background colour (Catppuccin Mocha base)
const default_bg = 0xFF1e1e2e;

// Font paths
const font_cjk = "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc";
const font_fallback = "/usr/share/fonts/TTF/DejaVuSans.ttf";

const dom_test = @import("test_dom_style.zig");
const JsRuntime = @import("js/runtime.zig").JsRuntime;
const web_api = @import("js/web_api.zig");
const dom_api = @import("js/dom_api.zig");
const events = @import("js/events.zig");
const DomNode = @import("dom/node.zig").DomNode;
const lxb = @import("bindings/lexbor.zig").c;

const ErrBlitCtx = struct {
    surface: *Surface,
    colour: u32,
};

fn blitGlyphErr(ctx: ErrBlitCtx, glyph: GlyphBitmap) void {
    ctx.surface.blitGlyph8(
        glyph.x,
        glyph.y,
        @intCast(glyph.width),
        @intCast(glyph.height),
        glyph.buffer,
        glyph.pitch,
        ctx.colour,
    );
}

fn findFont() [*:0]const u8 {
    const cjk_path: []const u8 = font_cjk[0..font_cjk.len];
    if (std.fs.openFileAbsolute(cjk_path, .{})) |f| {
        f.close();
        return font_cjk;
    } else |_| {}
    return font_fallback;
}

fn fontPathSlice(path: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (path[len] != 0) len += 1;
    return path[0..len];
}

fn testHttp(allocator: std.mem.Allocator) !void {
    std.debug.print("=== HTTP Client Test ===\n", .{});
    var client = HttpClient.init() catch |err| {
        std.debug.print("Failed to init HTTP client: {}\n", .{err});
        return err;
    };
    defer client.deinit();
    std.debug.print("Fetching http://example.com ...\n", .{});
    var response = client.get(allocator, "http://example.com") catch |err| {
        std.debug.print("Failed to fetch: {}\n", .{err});
        return err;
    };
    defer response.deinit();
    std.debug.print("Status: {d}\n", .{response.status_code});
    std.debug.print("Content-Type: {s}\n", .{response.content_type});
    std.debug.print("Body length: {d} bytes\n", .{response.body.len});
    const preview_len = @min(response.body.len, 200);
    std.debug.print("Body preview:\n{s}\n", .{response.body[0..preview_len]});
    std.debug.print("=== Test complete ===\n", .{});
}

/// Browser state holding the current page's data.
const PageState = struct {
    doc: ?Document = null,
    styles: ?cascade_mod.CascadeResult = null,
    root_box: ?*Box = null,
    total_height: f32 = 0,
    image_cache: ?ImageCache = null,
    js_rt: ?JsRuntime = null,
    /// Error message to display when page load fails.
    error_message: ?[]const u8 = null,
    error_alloc: ?[]u8 = null,

    fn deinit(self: *PageState) void {
        if (self.js_rt) |*jrt| {
            events.deinitEvents(jrt.ctx);
            jrt.deinit();
        }
        if (self.image_cache) |*ic| ic.deinit();
        if (self.styles) |*s| s.deinit();
        if (self.doc) |*d| d.deinit();
        if (self.error_alloc) |ea| std.heap.c_allocator.free(ea);
        self.* = .{};
    }
};

/// Find <script> tags in the DOM and execute their content.
fn executeScripts(doc: *Document, js_rt: *JsRuntime) void {
    const doc_node = doc.documentNode();
    collectAndExecScripts(doc_node.lxb_node, js_rt);
}

fn collectAndExecScripts(node: *lxb.lxb_dom_node_t, js_rt: *JsRuntime) void {
    if (node.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
        const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
        var name_len: usize = 0;
        const name_ptr: ?[*]const u8 = lxb.lxb_dom_element_local_name(elem, &name_len);
        if (name_ptr != null and name_len == 6) {
            if (std.mem.eql(u8, name_ptr.?[0..6], "script")) {
                // Get text content of <script> tag
                var content_len: usize = 0;
                const content_ptr: ?[*]const u8 = lxb.lxb_dom_node_text_content(node, &content_len);
                if (content_ptr != null and content_len > 0) {
                    const code = content_ptr.?[0..content_len];
                    std.debug.print("[JS] Executing <script> ({d} bytes)\n", .{content_len});
                    const result = js_rt.eval(code);
                    defer result.deinit();
                    if (!result.isOk()) {
                        std.debug.print("[JS:ERROR] {s}\n", .{result.value()});
                    }
                    js_rt.executePending();
                }
                return; // Don't recurse into script content
            }
        }
    }
    // Recurse into children
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        collectAndExecScripts(ch, js_rt);
        child = ch.next;
    }
}

/// Initialize JavaScript for a loaded page: set up DOM APIs, execute scripts, fire events.
fn initPageJs(doc: *Document, page: *PageState) void {
    var js_rt = JsRuntime.init() catch {
        std.debug.print("[JS] Failed to init JS runtime\n", .{});
        return;
    };

    // Register DOM APIs
    dom_api.registerDomApis(js_rt.rt, js_rt.ctx, @ptrCast(@alignCast(doc.html_doc)));

    // Register event APIs (addEventListener on window/document/elements)
    events.registerEventApis(js_rt.ctx);
    events.injectElementEventMethods(js_rt.ctx, events.getElementClassId());
    events.injectElementEventMethods(js_rt.ctx, events.getTextClassId());

    // Execute <script> tags
    executeScripts(doc, &js_rt);

    // Fire DOMContentLoaded
    events.dispatchDocumentEvent(js_rt.ctx, "DOMContentLoaded");
    js_rt.executePending();

    // Fire load
    events.dispatchWindowEvent(js_rt.ctx, "load");
    js_rt.executePending();

    page.js_rt = js_rt;
}

/// Recursively collect image URLs from the box tree.
fn collectImageUrls(box: *const Box, urls: *std.ArrayListUnmanaged([]const u8), allocator: std.mem.Allocator) void {
    if (box.box_type == .replaced) {
        if (box.image_url) |url| {
            urls.append(allocator, url) catch {};
        }
    }
    for (box.children.items) |child| {
        collectImageUrls(child, urls, allocator);
    }
}

/// Navigate to a URL: fetch, parse, style, layout.
/// Returns true on success, false on failure.
fn navigateTo(
    allocator: std.mem.Allocator,
    loader: *Loader,
    url_z: [:0]const u8,
    fonts: *painter_mod.FontCache,
    page: *PageState,
) bool {
    // Clean up old page
    page.deinit();

    // Fetch
    var content = loader.loadPage(url_z) catch |err| {
        std.debug.print("Failed to load {s}: {}\n", .{ url_z, err });
        // Store error message for display
        const msg = std.fmt.allocPrint(allocator, "Failed to load: {s}\nError: {}", .{ url_z, err }) catch return false;
        page.error_message = msg;
        page.error_alloc = msg;
        return false;
    };
    defer content.deinit();

    // Parse
    var doc = Document.parse(content.html) catch {
        std.debug.print("Failed to parse HTML\n", .{});
        const msg = std.fmt.allocPrint(allocator, "Failed to parse HTML from: {s}", .{url_z}) catch return false;
        page.error_message = msg;
        page.error_alloc = msg;
        return false;
    };

    const root_node = doc.root() orelse {
        doc.deinit();
        return false;
    };
    const body_node = doc.body() orelse {
        doc.deinit();
        return false;
    };

    // Style
    var styles = cascade_mod.cascade(root_node, allocator) catch {
        doc.deinit();
        return false;
    };

    // Build box tree
    const root_box = box_tree.buildBoxTree(body_node, &styles, allocator) catch {
        styles.deinit();
        doc.deinit();
        return false;
    };

    // Apply body margin
    const body_style = styles.getStyle(body_node) orelse @import("style/computed.zig").ComputedStyle{};
    const body_margin: f32 = if (body_style.margin_top == 0 and body_style.margin_left == 0) 8.0 else body_style.margin_left;
    root_box.margin = .{ .top = body_margin, .right = body_margin, .bottom = body_margin, .left = body_margin };

    // Layout
    const content_w: f32 = @floatFromInt(chrome.window_w);
    const root_containing_width = content_w - root_box.margin.left - root_box.margin.right;
    block_layout.layoutBlock(root_box, root_containing_width, 0, fonts);
    block_layout.adjustXPositions(root_box, root_box.margin.left);
    block_layout.adjustYPositions(root_box, root_box.margin.top);

    // Load images
    var img_cache = ImageCache.init(allocator);
    var img_urls: std.ArrayListUnmanaged([]const u8) = .empty;
    defer img_urls.deinit(allocator);
    collectImageUrls(root_box, &img_urls, allocator);

    for (img_urls.items) |img_url| {
        // Resolve relative URL
        const resolved = resolveUrl(allocator, url_z, img_url) catch continue;
        defer allocator.free(resolved);

        std.debug.print("Loading image: {s}\n", .{resolved});

        var resp = loader.loadBytes(resolved) catch continue;
        defer resp.deinit();

        if (resp.status_code == 200 and resp.body.len > 0) {
            const img = decodeImage(resp.body) catch continue;
            img_cache.put(img_url, img) catch {
                var mimg = img;
                mimg.deinit();
            };
        }
    }

    const total_h = painter_mod.contentHeight(root_box);

    page.* = .{
        .doc = doc,
        .styles = styles,
        .root_box = root_box,
        .total_height = total_h,
        .image_cache = img_cache,
    };

    // Initialize JavaScript: DOM APIs, execute scripts, fire events
    initPageJs(&page.doc.?, page);

    return true;
}

fn testJs() void {
    std.debug.print("=== QuickJS-ng Integration Test ===\n", .{});

    var js_rt = JsRuntime.init() catch |err| {
        std.debug.print("Failed to init JS runtime: {}\n", .{err});
        return;
    };
    defer js_rt.deinit();

    // Test 1: arithmetic
    {
        const result = js_rt.eval("1 + 2");
        defer result.deinit();
        std.debug.print("  1 + 2 = {s} {s}\n", .{
            result.value(),
            if (std.mem.eql(u8, result.value(), "3")) "[PASS]" else "[FAIL]",
        });
    }

    // Test 2: string concatenation
    {
        const result = js_rt.eval("'hello ' + 'world'");
        defer result.deinit();
        std.debug.print("  'hello ' + 'world' = {s} {s}\n", .{
            result.value(),
            if (std.mem.eql(u8, result.value(), "hello world")) "[PASS]" else "[FAIL]",
        });
    }

    // Test 3: JSON.stringify
    {
        const result = js_rt.eval("JSON.stringify({a: 1})");
        defer result.deinit();
        std.debug.print("  JSON.stringify({{a: 1}}) = {s} {s}\n", .{
            result.value(),
            if (std.mem.eql(u8, result.value(), "{\"a\":1}")) "[PASS]" else "[FAIL]",
        });
    }

    // Test 4: console.log
    std.debug.print("  console.log test (expect '[JS:LOG] Hello from JS!' on stderr):\n", .{});
    {
        const result = js_rt.eval("console.log('Hello from JS!')");
        defer result.deinit();
        std.debug.print("  console.log returned: {s} {s}\n", .{
            result.value(),
            if (result.isOk()) "[PASS]" else "[FAIL]",
        });
    }

    // Test 5: console.warn and console.error
    {
        const result = js_rt.eval("console.warn('warning!'); console.error('error!')");
        defer result.deinit();
        std.debug.print("  console.warn/error: {s}\n", .{if (result.isOk()) "[PASS]" else "[FAIL]"});
    }

    // Test 6: setTimeout
    std.debug.print("  setTimeout test (expect '[JS:LOG] delayed!' on stderr):\n", .{});
    {
        const result = js_rt.eval("setTimeout(() => console.log('delayed!'), 50)");
        defer result.deinit();
        std.debug.print("  setTimeout returned timer id: {s} {s}\n", .{
            result.value(),
            if (result.isOk()) "[PASS]" else "[FAIL]",
        });
    }

    // Run the timer loop
    {
        var iterations: u32 = 0;
        while (web_api.hasTimers() and iterations < 200) : (iterations += 1) {
            _ = web_api.tickTimers(js_rt.ctx);
            js_rt.executePending();
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        std.debug.print("  Timer loop finished after {d} iterations {s}\n", .{
            iterations,
            if (!web_api.hasTimers()) "[PASS]" else "[FAIL]",
        });
    }

    // Test 7: setInterval + clearInterval
    std.debug.print("  setInterval/clearInterval test:\n", .{});
    {
        const result = js_rt.eval(
            \\var count = 0;
            \\var id = setInterval(function() {
            \\    count++;
            \\    console.log('tick ' + count);
            \\    if (count >= 3) clearInterval(id);
            \\}, 30);
            \\id
        );
        defer result.deinit();

        var iterations: u32 = 0;
        while (web_api.hasTimers() and iterations < 200) : (iterations += 1) {
            _ = web_api.tickTimers(js_rt.ctx);
            js_rt.executePending();
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        std.debug.print("  setInterval loop finished after {d} iterations {s}\n", .{
            iterations,
            if (!web_api.hasTimers()) "[PASS]" else "[FAIL]",
        });
    }

    // Test 8: error handling
    {
        const result = js_rt.eval("undeclared_variable");
        defer result.deinit();
        std.debug.print("  error handling: {s} {s}\n", .{
            result.value(),
            if (!result.isOk()) "[PASS]" else "[FAIL]",
        });
    }

    std.debug.print("=== All JS tests done ===\n", .{});
}

fn testDomJs() void {
    std.debug.print("=== DOM + JS Integration Test ===\n", .{});

    const html =
        \\<html><body>
        \\<button id="btn">Click me</button>
        \\<p id="output">...</p>
        \\<div class="container"><span class="item">A</span><span class="item">B</span></div>
        \\<script>
        \\  // Test 1: document.getElementById
        \\  var btn = document.getElementById("btn");
        \\  console.log("Test1 getElementById: " + (btn ? "PASS" : "FAIL"));
        \\
        \\  // Test 2: tagName
        \\  console.log("Test2 tagName: " + (btn.tagName === "BUTTON" ? "PASS" : "FAIL") + " (got: " + btn.tagName + ")");
        \\
        \\  // Test 3: textContent getter
        \\  console.log("Test3 textContent: " + (btn.textContent === "Click me" ? "PASS" : "FAIL") + " (got: " + btn.textContent + ")");
        \\
        \\  // Test 4: textContent setter
        \\  var output = document.getElementById("output");
        \\  output.textContent = "Changed!";
        \\  console.log("Test4 setTextContent: " + (output.textContent === "Changed!" ? "PASS" : "FAIL") + " (got: " + output.textContent + ")");
        \\
        \\  // Test 5: getAttribute/setAttribute
        \\  btn.setAttribute("data-test", "hello");
        \\  console.log("Test5 setAttribute: " + (btn.getAttribute("data-test") === "hello" ? "PASS" : "FAIL"));
        \\
        \\  // Test 6: document.body
        \\  var body = document.body;
        \\  console.log("Test6 body: " + (body ? "PASS" : "FAIL"));
        \\  console.log("Test6b body.tagName: " + (body.tagName === "BODY" ? "PASS" : "FAIL") + " (got: " + body.tagName + ")");
        \\
        \\  // Test 7: querySelector
        \\  var container = document.querySelector(".container");
        \\  console.log("Test7 querySelector: " + (container ? "PASS" : "FAIL"));
        \\
        \\  // Test 8: children
        \\  var kids = container.children;
        \\  console.log("Test8 children.length: " + (kids.length === 2 ? "PASS" : "FAIL") + " (got: " + kids.length + ")");
        \\
        \\  // Test 9: createElement + appendChild
        \\  var newElem = document.createElement("div");
        \\  newElem.setAttribute("id", "new-div");
        \\  newElem.textContent = "New element";
        \\  document.body.appendChild(newElem);
        \\  var found = document.getElementById("new-div");
        \\  console.log("Test9 createElement+appendChild: " + (found ? "PASS" : "FAIL"));
        \\
        \\  // Test 10: addEventListener + event dispatch
        \\  var clicked = false;
        \\  btn.addEventListener("click", function(e) {
        \\    clicked = true;
        \\    console.log("Test10 click handler called: PASS (type=" + e.type + ")");
        \\  });
        \\  console.log("Test10 addEventListener registered (click test needs dispatchEvent)");
        \\
        \\  // Test 11: classList
        \\  container.classList.add("active");
        \\  console.log("Test11 classList.add: " + (container.className.indexOf("active") >= 0 ? "PASS" : "FAIL"));
        \\  container.classList.remove("active");
        \\  console.log("Test11b classList.remove: " + (container.className.indexOf("active") < 0 ? "PASS" : "FAIL"));
        \\
        \\  // Test 12: parentNode
        \\  console.log("Test12 parentNode: " + (btn.parentNode ? "PASS" : "FAIL"));
        \\  console.log("Test12b parentNode.tagName: " + btn.parentNode.tagName);
        \\
        \\  // Test 13: DOMContentLoaded (set handler before it fires is typical, but here we just test)
        \\  console.log("All DOM tests completed!");
        \\</script>
        \\</body></html>
    ;

    var doc = Document.parse(html) catch {
        std.debug.print("FAIL: Failed to parse HTML\n", .{});
        return;
    };
    defer doc.deinit();

    var js_rt = JsRuntime.init() catch {
        std.debug.print("FAIL: Failed to init JS runtime\n", .{});
        return;
    };
    defer js_rt.deinit();

    // Register DOM APIs
    dom_api.registerDomApis(js_rt.rt, js_rt.ctx, @ptrCast(@alignCast(doc.html_doc)));
    events.registerEventApis(js_rt.ctx);
    events.injectElementEventMethods(js_rt.ctx, events.getElementClassId());
    events.injectElementEventMethods(js_rt.ctx, events.getTextClassId());

    // Execute scripts
    executeScripts(&doc, &js_rt);

    // Fire DOMContentLoaded and load
    events.dispatchDocumentEvent(js_rt.ctx, "DOMContentLoaded");
    js_rt.executePending();
    events.dispatchWindowEvent(js_rt.ctx, "load");
    js_rt.executePending();

    // Simulate a click on the button
    std.debug.print("\n--- Simulating click on #btn ---\n", .{});
    const btn_node = findNodeById(doc.documentNode().lxb_node, "btn");
    if (btn_node) |node| {
        _ = events.dispatchEvent(js_rt.ctx, node, "click");
        js_rt.executePending();
    } else {
        std.debug.print("FAIL: Could not find #btn for click test\n", .{});
    }

    // Clean up events
    events.deinitEvents(js_rt.ctx);

    std.debug.print("=== DOM + JS tests done ===\n", .{});
}

fn findNodeById(node: *lxb.lxb_dom_node_t, id: []const u8) ?*lxb.lxb_dom_node_t {
    if (node.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
        const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
        var val_len: usize = 0;
        const val: ?[*]const u8 = lxb.lxb_dom_element_get_attribute(elem, "id", 2, &val_len);
        if (val != null and val_len == id.len) {
            if (std.mem.eql(u8, val.?[0..val_len], id)) return node;
        }
    }
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        if (findNodeById(ch, id)) |found| return found;
        child = ch.next;
    }
    return null;
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // Parse arguments
    var args = std.process.args();
    _ = args.skip();
    var initial_url: ?[]const u8 = null;
    var run_test_dom = false;
    var run_test_http = false;
    var run_test_js = false;
    var run_test_dom_js = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--test-dom")) {
            run_test_dom = true;
        } else if (std.mem.eql(u8, arg, "--test-http")) {
            run_test_http = true;
        } else if (std.mem.eql(u8, arg, "--test-js")) {
            run_test_js = true;
        } else if (std.mem.eql(u8, arg, "--test-dom-js")) {
            run_test_dom_js = true;
        } else {
            initial_url = arg;
        }
    }

    if (run_test_dom) return dom_test.main();
    if (run_test_http) return testHttp(allocator);
    if (run_test_js) return testJs();
    if (run_test_dom_js) return testDomJs();

    std.debug.print("suzume v0.3.0 — browser mode\n", .{});

    // Init HTTP client
    var http_client = HttpClient.init() catch |err| {
        std.debug.print("Failed to init HTTP client: {}\n", .{err});
        return err;
    };
    defer http_client.deinit();

    var loader = Loader.init(allocator, &http_client);

    // Font
    const font_path = findFont();
    std.debug.print("Using font: {s}\n", .{fontPathSlice(font_path)});

    var fonts = painter_mod.FontCache.init(allocator, font_path);
    defer fonts.deinit();

    // Surface
    var surface = Surface.init(window_w, window_h) catch |err| {
        std.debug.print("Failed to create surface: {}\n", .{err});
        return err;
    };
    defer surface.deinit();

    // URL bar input
    var url_input = TextInput.init(allocator);
    defer url_input.deinit();
    url_input.focused = true;

    // Status
    var status_text: []const u8 = "Ready";

    // Page state
    var page = PageState{};
    defer page.deinit();

    // Scroll
    var scroll_y: f32 = 0;

    // History
    var history: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (history.items) |item| allocator.free(item);
        history.deinit(allocator);
    }
    var history_pos: usize = 0;

    // Current URL (owned)
    var current_url: ?[]u8 = null;
    defer if (current_url) |u| allocator.free(u);

    // Modifier key state
    var shift_held = false;
    var ctrl_held = false;
    var alt_held = false;

    // Mouse position tracking (for move events)
    var mouse_x: i32 = 0;
    var mouse_y: i32 = 0;

    // If initial URL provided, navigate to it
    if (initial_url) |url| {
        url_input.setText(url);
        url_input.focused = false;

        // Make sentinel-terminated copy
        const url_z = allocator.allocSentinel(u8, url.len, 0) catch null;
        if (url_z) |uz| {
            defer allocator.free(uz);
            @memcpy(uz, url);
            status_text = "Loading...";

            if (navigateTo(allocator, &loader, uz, &fonts, &page)) {
                status_text = "Done";
                scroll_y = 0;
                // Store in history
                const owned = allocator.alloc(u8, url.len) catch null;
                if (owned) |o| {
                    @memcpy(o, url);
                    history.append(allocator, o) catch {};
                    history_pos = history.items.len - 1;
                    if (current_url) |old| allocator.free(old);
                    const cu = allocator.alloc(u8, url.len) catch null;
                    if (cu) |c| {
                        @memcpy(c, url);
                        current_url = c;
                    }
                }
            } else {
                status_text = "Failed";
            }
        }
    }

    // Initial paint
    var needs_repaint = true;

    // Event loop
    var running = true;
    while (running) {
        // Repaint if needed
        if (needs_repaint) {
            // Clear content area
            chrome.clearContentArea(&surface);

            // Paint page content
            if (page.root_box) |root_box| {
                // scroll_y is in layout coords; we offset by content_y for screen position
                const adjusted_scroll = scroll_y - @as(f32, @floatFromInt(chrome.content_y));
                const ic_ptr: ?*ImageCache = if (page.image_cache) |*ic| ic else null;
                painter_mod.paint(
                    root_box,
                    &surface,
                    &fonts,
                    adjusted_scroll,
                    chrome.content_y,
                    chrome.content_y + chrome.content_height,
                    ic_ptr,
                );
            } else if (page.error_message) |err_msg| {
                // Display error message in the content area
                const err_font_size: u32 = 14;
                if (fonts.getRenderer(err_font_size)) |tr| {
                    const m = tr.measure(err_msg);
                    const err_x: i32 = 16;
                    const err_y: i32 = chrome.content_y + 24 + m.ascent;
                    tr.renderGlyphs(
                        err_msg,
                        err_x,
                        err_y,
                        ErrBlitCtx,
                        .{ .surface = &surface, .colour = Surface.argbToColour(0xFFf38ba8) },
                        blitGlyphErr,
                    );
                }
            }

            // Paint chrome on top
            chrome.paintUrlBar(&surface, &fonts, &url_input);
            chrome.paintStatusBar(&surface, &fonts, status_text);

            surface.update();
            needs_repaint = false;
        }

        // Tick JS timers (setTimeout/setInterval) and check for DOM mutations
        if (page.js_rt) |*js_rt| {
            _ = web_api.tickTimers(js_rt.ctx);
            js_rt.executePending();
            if (dom_api.dom_dirty) {
                dom_api.dom_dirty = false;
                // DOM was mutated by JS — need to re-style, re-layout, repaint
                // For now, just repaint (full re-layout on DOM mutation is Phase 5)
                needs_repaint = true;
            }
        }

        if (surface.pollEvent(50)) |event| {
            switch (event.type) {
                nsfb_c.NSFB_EVENT_CONTROL => {
                    if (event.value.controlcode == nsfb_c.NSFB_CONTROL_QUIT) {
                        running = false;
                    }
                },

                nsfb_c.NSFB_EVENT_KEY_DOWN => {
                    const key = event.value.keycode;

                    // Track modifier state
                    if (key == nsfb_c.NSFB_KEY_LSHIFT or key == nsfb_c.NSFB_KEY_RSHIFT) {
                        shift_held = true;
                        continue;
                    }
                    if (key == nsfb_c.NSFB_KEY_LCTRL or key == nsfb_c.NSFB_KEY_RCTRL) {
                        ctrl_held = true;
                        continue;
                    }
                    if (key == nsfb_c.NSFB_KEY_LALT or key == nsfb_c.NSFB_KEY_RALT) {
                        alt_held = true;
                        continue;
                    }

                    // Ctrl+Q: quit
                    if (ctrl_held and key == nsfb_c.NSFB_KEY_q) {
                        running = false;
                        continue;
                    }

                    // Ctrl+L: focus URL bar
                    if (ctrl_held and key == nsfb_c.NSFB_KEY_l) {
                        url_input.focused = true;
                        // Select all (move cursor to end)
                        url_input.cursor = url_input.buf.items.len;
                        needs_repaint = true;
                        continue;
                    }

                    // F5: reload
                    if (key == nsfb_c.NSFB_KEY_F5) {
                        if (current_url) |url| {
                            const url_z = allocator.allocSentinel(u8, url.len, 0) catch continue;
                            defer allocator.free(url_z);
                            @memcpy(url_z, url);
                            status_text = "Loading...";
                            needs_repaint = true;
                            if (navigateTo(allocator, &loader, url_z, &fonts, &page)) {
                                status_text = "Done";
                                scroll_y = 0;
                            } else {
                                status_text = "Failed";
                            }
                            needs_repaint = true;
                        }
                        continue;
                    }

                    // Ctrl+R: reload
                    if (ctrl_held and key == nsfb_c.NSFB_KEY_r) {
                        if (current_url) |url| {
                            const url_z = allocator.allocSentinel(u8, url.len, 0) catch continue;
                            defer allocator.free(url_z);
                            @memcpy(url_z, url);
                            status_text = "Loading...";
                            needs_repaint = true;
                            if (navigateTo(allocator, &loader, url_z, &fonts, &page)) {
                                status_text = "Done";
                                scroll_y = 0;
                            } else {
                                status_text = "Failed";
                            }
                            needs_repaint = true;
                        }
                        continue;
                    }

                    // Alt+Left: back
                    if (alt_held and key == nsfb_c.NSFB_KEY_LEFT) {
                        if (history_pos > 0) {
                            history_pos -= 1;
                            const url = history.items[history_pos];
                            const url_z = allocator.allocSentinel(u8, url.len, 0) catch continue;
                            defer allocator.free(url_z);
                            @memcpy(url_z, url);
                            url_input.setText(url);
                            status_text = "Loading...";
                            needs_repaint = true;
                            if (navigateTo(allocator, &loader, url_z, &fonts, &page)) {
                                status_text = "Done";
                                scroll_y = 0;
                                if (current_url) |old| allocator.free(old);
                                const cu = allocator.alloc(u8, url.len) catch null;
                                if (cu) |c| {
                                    @memcpy(c, url);
                                    current_url = c;
                                }
                            } else {
                                status_text = "Failed";
                            }
                            needs_repaint = true;
                        }
                        continue;
                    }

                    // Alt+Right: forward
                    if (alt_held and key == nsfb_c.NSFB_KEY_RIGHT) {
                        if (history_pos + 1 < history.items.len) {
                            history_pos += 1;
                            const url = history.items[history_pos];
                            const url_z = allocator.allocSentinel(u8, url.len, 0) catch continue;
                            defer allocator.free(url_z);
                            @memcpy(url_z, url);
                            url_input.setText(url);
                            status_text = "Loading...";
                            needs_repaint = true;
                            if (navigateTo(allocator, &loader, url_z, &fonts, &page)) {
                                status_text = "Done";
                                scroll_y = 0;
                                if (current_url) |old| allocator.free(old);
                                const cu = allocator.alloc(u8, url.len) catch null;
                                if (cu) |c| {
                                    @memcpy(c, url);
                                    current_url = c;
                                }
                            } else {
                                status_text = "Failed";
                            }
                            needs_repaint = true;
                        }
                        continue;
                    }

                    // Handle mouse events regardless of focus
                    if (key == nsfb_c.NSFB_KEY_MOUSE_1) {
                        handleClick(
                            allocator,
                            mouse_x,
                            mouse_y,
                            &url_input,
                            &scroll_y,
                            &page,
                            &fonts,
                            &loader,
                            &history,
                            &history_pos,
                            &current_url,
                            &status_text,
                            &needs_repaint,
                        );
                        continue;
                    }
                    if (key == nsfb_c.NSFB_KEY_MOUSE_4 or key == nsfb_c.NSFB_KEY_MOUSE_5) {
                        const ch = @as(f32, @floatFromInt(chrome.content_height));
                        var new_scroll = scroll_y;
                        if (key == nsfb_c.NSFB_KEY_MOUSE_4) {
                            new_scroll -= 40;
                        } else {
                            new_scroll += 40;
                        }
                        const max_scroll = @max(page.total_height - ch, 0);
                        new_scroll = @max(0, @min(new_scroll, max_scroll));
                        if (new_scroll != scroll_y) {
                            scroll_y = new_scroll;
                            needs_repaint = true;
                        }
                        continue;
                    }

                    if (url_input.focused) {
                        // Route to text input
                        const result = url_input.handleKey(key, shift_held);
                        switch (result) {
                            .submit => {
                                // Navigate to URL
                                const url_text = url_input.getText();
                                if (url_text.len > 0) {
                                    const url_z = allocator.allocSentinel(u8, url_text.len, 0) catch continue;
                                    defer allocator.free(url_z);
                                    @memcpy(url_z, url_text);

                                    status_text = "Loading...";
                                    needs_repaint = true;

                                    if (navigateTo(allocator, &loader, url_z, &fonts, &page)) {
                                        status_text = "Done";
                                        scroll_y = 0;
                                        url_input.focused = false;

                                        // Truncate forward history if we navigated from middle
                                        if (history_pos + 1 < history.items.len) {
                                            for (history.items[history_pos + 1 ..]) |item| {
                                                allocator.free(item);
                                            }
                                            history.shrinkRetainingCapacity(history_pos + 1);
                                        }

                                        // Add to history
                                        const owned = allocator.alloc(u8, url_text.len) catch null;
                                        if (owned) |o| {
                                            @memcpy(o, url_text);
                                            history.append(allocator, o) catch {};
                                            history_pos = history.items.len - 1;
                                        }
                                        if (current_url) |old| allocator.free(old);
                                        const cu = allocator.alloc(u8, url_text.len) catch null;
                                        if (cu) |c| {
                                            @memcpy(c, url_text);
                                            current_url = c;
                                        }
                                    } else {
                                        status_text = "Failed";
                                    }
                                }
                                needs_repaint = true;
                            },
                            .cancel => {
                                url_input.focused = false;
                                // Restore URL from current
                                if (current_url) |url| {
                                    url_input.setText(url);
                                }
                                needs_repaint = true;
                            },
                            .consumed => {
                                needs_repaint = true;
                            },
                            .ignored => {},
                        }
                    } else {
                        // Content area: handle scroll keys
                        {
                            const ch = @as(f32, @floatFromInt(chrome.content_height));
                            var new_scroll = scroll_y;

                            if (key == nsfb_c.NSFB_KEY_UP) {
                                new_scroll -= 40;
                            } else if (key == nsfb_c.NSFB_KEY_DOWN) {
                                new_scroll += 40;
                            } else if (key == nsfb_c.NSFB_KEY_PAGEUP) {
                                new_scroll -= ch;
                            } else if (key == nsfb_c.NSFB_KEY_PAGEDOWN) {
                                new_scroll += ch;
                            } else if (key == nsfb_c.NSFB_KEY_HOME) {
                                new_scroll = 0;
                            } else if (key == nsfb_c.NSFB_KEY_END) {
                                if (page.total_height > ch) {
                                    new_scroll = page.total_height - ch;
                                }
                            } else if (key == nsfb_c.NSFB_KEY_ESCAPE) {
                                // Do nothing in content view; Ctrl+Q to quit
                                continue;
                            }

                            // Clamp
                            const max_scroll = @max(page.total_height - ch, 0);
                            new_scroll = @max(0, @min(new_scroll, max_scroll));
                            if (new_scroll != scroll_y) {
                                scroll_y = new_scroll;
                                needs_repaint = true;
                            }
                        }
                    }
                },

                nsfb_c.NSFB_EVENT_KEY_UP => {
                    const key = event.value.keycode;
                    if (key == nsfb_c.NSFB_KEY_LSHIFT or key == nsfb_c.NSFB_KEY_RSHIFT) {
                        shift_held = false;
                    }
                    if (key == nsfb_c.NSFB_KEY_LCTRL or key == nsfb_c.NSFB_KEY_RCTRL) {
                        ctrl_held = false;
                    }
                    if (key == nsfb_c.NSFB_KEY_LALT or key == nsfb_c.NSFB_KEY_RALT) {
                        alt_held = false;
                    }
                },

                nsfb_c.NSFB_EVENT_MOVE_ABSOLUTE => {
                    mouse_x = event.value.vector.x;
                    mouse_y = event.value.vector.y;
                },

                else => {},
            }
        }
    }

    std.debug.print("Bye!\n", .{});
}

fn handleClick(
    allocator: std.mem.Allocator,
    mx: i32,
    my: i32,
    url_input: *TextInput,
    scroll_y: *f32,
    page: *PageState,
    fonts: *painter_mod.FontCache,
    loader: *Loader,
    history: *std.ArrayListUnmanaged([]u8),
    history_pos: *usize,
    current_url: *?[]u8,
    status_text: *[]const u8,
    needs_repaint: *bool,
) void {
    // Click in URL bar?
    if (my < chrome.url_bar_height) {
        url_input.focused = true;
        needs_repaint.* = true;
        return;
    }

    // Click in status bar? (ignore)
    if (my >= chrome.window_h - chrome.status_bar_height) return;

    // Click in content area — unfocus URL bar
    url_input.focused = false;

    // Hit test for links and JS events
    if (page.root_box) |root_box| {
        // Convert screen coords to layout coords
        const layout_x: f32 = @floatFromInt(mx);
        const layout_y: f32 = @as(f32, @floatFromInt(my - chrome.content_y)) + scroll_y.*;

        // Dispatch click event to JavaScript
        if (page.js_rt) |*js_rt| {
            if (painter_mod.hitTestNode(root_box, layout_x, layout_y)) |node_ptr| {
                const node: *lxb.lxb_dom_node_t = @ptrCast(@alignCast(node_ptr));
                _ = events.dispatchEvent(js_rt.ctx, node, "click");
                js_rt.executePending();
                // Check if DOM was mutated by the event handler
                if (dom_api.dom_dirty) {
                    dom_api.dom_dirty = false;
                    needs_repaint.* = true;
                    // TODO: re-style and re-layout after DOM mutation
                }
            }
        }

        if (painter_mod.hitTestLink(root_box, layout_x, layout_y)) |link_href| {
            // Resolve URL
            const base = if (current_url.*) |u| u else "";
            const resolved = resolveUrl(allocator, base, link_href) catch return;
            defer allocator.free(resolved);

            std.debug.print("Navigating to: {s}\n", .{resolved});

            url_input.setText(resolved);
            status_text.* = "Loading...";
            needs_repaint.* = true;

            if (navigateTo(allocator, loader, resolved, fonts, page)) {
                status_text.* = "Done";
                scroll_y.* = 0;

                // Truncate forward history
                if (history_pos.* + 1 < history.items.len) {
                    for (history.items[history_pos.* + 1 ..]) |item| {
                        allocator.free(item);
                    }
                    history.shrinkRetainingCapacity(history_pos.* + 1);
                }

                // Add to history
                const owned = allocator.alloc(u8, resolved.len) catch return;
                @memcpy(owned, resolved);
                history.append(allocator, owned) catch {
                    allocator.free(owned);
                    return;
                };
                history_pos.* = history.items.len - 1;

                if (current_url.*) |old| allocator.free(old);
                const cu = allocator.alloc(u8, resolved.len) catch null;
                if (cu) |c| {
                    @memcpy(c, resolved);
                    current_url.* = c;
                }
            } else {
                status_text.* = "Failed";
            }
            needs_repaint.* = true;
        } else {
            needs_repaint.* = true; // repaint to show unfocused URL bar
        }
    } else {
        needs_repaint.* = true;
    }
}

// Re-export modules so they are reachable from the build
pub const dom = struct {
    pub const node = @import("dom/node.zig");
    pub const tree = @import("dom/tree.zig");
};

pub const style = struct {
    pub const computed = @import("style/computed.zig");
    pub const select = @import("style/select.zig");
    pub const cascade = @import("style/cascade.zig");
};

pub const layout = struct {
    pub const box = @import("layout/box.zig");
    pub const tree = @import("layout/tree.zig");
    pub const block = @import("layout/block.zig");
};

pub const paint = struct {
    pub const painter = @import("paint/painter.zig");
    pub const image = @import("paint/image.zig");
};

pub const net = struct {
    pub const http = @import("net/http.zig");
    pub const loader = @import("net/loader.zig");
};

pub const ui = struct {
    pub const chrome_mod = @import("ui/chrome.zig");
    pub const input = @import("ui/input.zig");
};

pub const js = struct {
    pub const runtime = @import("js/runtime.zig");
    pub const web_apis = @import("js/web_api.zig");
    pub const dom_apis = @import("js/dom_api.zig");
    pub const event_system = @import("js/events.zig");
};
