const std = @import("std");
const Surface = @import("paint/surface.zig").Surface;
const TextRenderer = @import("paint/text.zig").TextRenderer;
const GlyphBitmap = @import("paint/text.zig").GlyphBitmap;
const Document = @import("dom/tree.zig").Document;
const cascade_mod = @import("css/cascade.zig");
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
const TabManager = @import("ui/tabs.zig").TabManager;
const Storage = @import("features/storage.zig").Storage;
const Config = @import("features/config.zig").Config;
const internal_pages = @import("features/internal_pages.zig");
const search = @import("features/search.zig");
const FindBar = search.FindBar;
const adblock_mod = @import("features/adblock.zig");
const userscript = @import("features/userscript.zig");
const Box = @import("layout/box.zig").Box;
const ImageCache = @import("paint/image.zig").ImageCache;
const decodeImage = @import("paint/image.zig").decodeImage;

const default_window_w = chrome.default_window_w;
const default_window_h = chrome.default_window_h;

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

/// Re-style and re-layout a page after JS DOM mutation.
/// Rebuilds the style cascade, box tree, and layout from the current DOM state.
fn restylePage(page: *PageState, allocator: std.mem.Allocator, fonts: *painter_mod.FontCache, layout_width: i32, layout_height: i32) void {
    const doc = &(page.doc orelse return);

    const root_node = doc.root() orelse return;
    const body_node = doc.body() orelse return;

    // Re-cascade styles from the current DOM (includes any <style> tags JS may have added)
    var new_styles = cascade_mod.cascade(root_node, allocator, page.external_css, @intCast(layout_width), @intCast(layout_height)) catch return;

    // Build new box tree
    const new_root_box = box_tree.buildBoxTree(body_node, &new_styles, allocator) catch {
        new_styles.deinit();
        return;
    };

    // Apply body margin
    const body_style = new_styles.getStyle(body_node) orelse @import("css/computed.zig").ComputedStyle{};
    const body_margin: f32 = if (body_style.margin_top == 0 and body_style.margin_left == 0) 8.0 else body_style.margin_left;
    new_root_box.margin = .{ .top = body_margin, .right = body_margin, .bottom = body_margin, .left = body_margin };

    // Layout
    const content_w: f32 = @floatFromInt(layout_width);
    const root_containing_width = content_w - new_root_box.margin.left - new_root_box.margin.right;
    block_layout.layoutBlockVp(new_root_box, root_containing_width, 0, fonts, @floatFromInt(layout_height));
    block_layout.adjustXPositions(new_root_box, new_root_box.margin.left);
    block_layout.adjustYPositions(new_root_box, new_root_box.margin.top);

    // Replace old styles and box tree (order matters: box tree refs styles)
    // Note: old root_box is arena-allocated by buildBoxTree and not individually freed.
    // Old styles must be freed after the old box tree is no longer referenced.
    if (page.styles) |*s| s.deinit();
    page.styles = new_styles;
    page.root_box = new_root_box;
    page.total_height = painter_mod.contentHeight(new_root_box);
    page.total_width = painter_mod.contentWidth(new_root_box);

    // Re-collect pending images from new box tree
    page.pending_images.clearRetainingCapacity();
    page.pending_images_idx = 0;
    collectImageUrls(new_root_box, &page.pending_images, allocator);

    // Update global root box pointer for JS layout queries
    dom_api.setRootBox(new_root_box);

    std.debug.print("[JS] DOM mutation → re-styled and re-laid out\n", .{});
}

/// Browser state holding the current page's data.
const PageState = struct {
    doc: ?Document = null,
    styles: ?cascade_mod.CascadeResult = null,
    root_box: ?*Box = null,
    total_height: f32 = 0,
    total_width: f32 = 0,
    image_cache: ?ImageCache = null,
    js_rt: ?JsRuntime = null,
    /// External CSS text (from <link> fetches), kept for re-cascade after DOM mutation.
    external_css: ?[]const u8 = null,
    /// Pending image URLs for incremental loading (1 per event loop tick).
    pending_images: std.ArrayListUnmanaged(ImageUrlEntry) = .empty,
    pending_images_idx: usize = 0,
    pending_images_loaded: usize = 0,
    /// Base URL for resolving relative image URLs.
    base_url: ?[]const u8 = null,
    /// Error message to display when page load fails.
    error_message: ?[]const u8 = null,
    error_alloc: ?[]u8 = null,

    fn deinit(self: *PageState) void {
        if (self.js_rt) |*jrt| {
            events.deinitEvents(jrt.ctx);
            jrt.deinit();
        }
        if (self.image_cache) |*ic| ic.deinit();
        self.pending_images.deinit(std.heap.c_allocator);
        if (self.base_url) |bu| std.heap.c_allocator.free(bu);
        if (self.external_css) |ec| std.heap.c_allocator.free(ec);
        if (self.styles) |*s| s.deinit();
        if (self.doc) |*d| d.deinit();
        if (self.error_alloc) |ea| std.heap.c_allocator.free(ea);
        self.* = .{};
    }
};

/// Find <script> tags in the DOM and execute their content.
fn executeScripts(doc: *Document, js_rt: *JsRuntime, allocator: std.mem.Allocator, loader: ?*Loader, base_url: ?[]const u8) void {
    const doc_node = doc.documentNode();
    var ext_count: usize = 0;
    collectAndExecScripts(doc_node.lxb_node, js_rt, allocator, loader, base_url, &ext_count);
}

/// Maximum size for a fetched external script (500 KB).
const max_external_script_size = 512 * 1024;
/// Maximum number of external scripts to fetch per page.
const max_external_script_count = 10;
/// Timeout in seconds for fetching an external script.
const external_script_timeout = 5;

fn collectAndExecScripts(node: *lxb.lxb_dom_node_t, js_rt: *JsRuntime, allocator: std.mem.Allocator, loader: ?*Loader, base_url: ?[]const u8, ext_count: *usize) void {
    if (node.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
        const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
        var name_len: usize = 0;
        const name_ptr: ?[*]const u8 = lxb.lxb_dom_element_local_name(elem, &name_len);
        if (name_ptr != null and name_len == 6) {
            if (std.mem.eql(u8, name_ptr.?[0..6], "script")) {
                // Skip type="module" scripts (ES modules not supported)
                var type_len: usize = 0;
                const type_ptr: ?[*]const u8 = lxb.lxb_dom_element_get_attribute(elem, "type", 4, &type_len);
                if (type_ptr != null and type_len > 0) {
                    const script_type = type_ptr.?[0..type_len];
                    // Only execute scripts with type="" (default), "text/javascript",
                    // or "application/javascript". Skip everything else (module, json, etc.)
                    const is_js = script_type.len == 0 or
                        std.mem.eql(u8, script_type, "text/javascript") or
                        std.mem.eql(u8, script_type, "application/javascript");
                    if (!is_js) return;
                }

                // Skip scripts with nomodule attribute
                var nomod_len: usize = 0;
                const nomod_ptr: ?[*]const u8 = lxb.lxb_dom_element_get_attribute(elem, "nomodule", 8, &nomod_len);
                if (nomod_ptr != null) {
                    return;
                }

                // Check for src attribute (external script)
                var src_len: usize = 0;
                const src_ptr: ?[*]const u8 = lxb.lxb_dom_element_get_attribute(elem, "src", 3, &src_len);
                if (src_ptr != null and src_len > 0) {
                    // External script
                    const src = src_ptr.?[0..src_len];

                    // Only fetch http:// or https:// URLs
                    const resolved_url = if (std.mem.startsWith(u8, src, "http://") or std.mem.startsWith(u8, src, "https://"))
                        blk: {
                            const u = allocator.allocSentinel(u8, src.len, 0) catch return;
                            @memcpy(u, src);
                            break :blk u;
                        }
                    else if (base_url) |bu|
                        resolveUrl(allocator, bu, src) catch return
                    else
                        return;
                    defer allocator.free(resolved_url);

                    // Verify resolved URL is http(s)
                    if (!std.mem.startsWith(u8, resolved_url, "http://") and !std.mem.startsWith(u8, resolved_url, "https://")) {
                        return;
                    }

                    // Check count limit
                    if (ext_count.* >= max_external_script_count) {
                        std.debug.print("[JS] External script limit reached ({d}), skipping: {s}\n", .{ max_external_script_count, resolved_url });
                        return;
                    }

                    const ld = loader orelse return;

                    std.debug.print("[JS] Fetching external script: {s}\n", .{resolved_url});

                    var response = ld.loadBytesWithTimeout(resolved_url, external_script_timeout) catch |err| {
                        std.debug.print("[JS] Failed to fetch external script {s}: {}\n", .{ resolved_url, err });
                        return;
                    };
                    defer response.deinit();

                    if (response.status_code != 200) {
                        std.debug.print("[JS] External script returned status {d}: {s}\n", .{ response.status_code, resolved_url });
                        return;
                    }

                    // Check size limit
                    if (response.body.len > max_external_script_size) {
                        std.debug.print("[JS] External script too large ({d} bytes, max {d}): {s}\n", .{ response.body.len, max_external_script_size, resolved_url });
                        return;
                    }

                    ext_count.* += 1;
                    const code = response.body;
                    std.debug.print("[JS] Executing external <script src=\"{s}\"> ({d} bytes)\n", .{ resolved_url, code.len });
                    const result = js_rt.eval(code);
                    defer result.deinit();
                    if (!result.isOk()) {
                        std.debug.print("[JS:ERROR] {s}\n", .{result.value()});
                    }
                    js_rt.executePending();
                } else {
                    // Inline script: get text content of <script> tag
                    var content_len: usize = 0;
                    const content_ptr: ?[*]const u8 = lxb.lxb_dom_node_text_content(node, &content_len);
                    if (content_ptr != null and content_len > 0) {
                        // Skip very large inline scripts (often JSON data blobs that crash)
                        if (content_len > 100 * 1024) {
                            std.debug.print("[JS] Skipping large inline script ({d} bytes)\n", .{content_len});
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
                return; // Don't recurse into script content
            }
        }
    }
    // Recurse into children
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        collectAndExecScripts(ch, js_rt, allocator, loader, base_url, ext_count);
        child = ch.next;
    }
}

/// Initialize JavaScript for a loaded page: set up DOM APIs, execute scripts, fire events.
fn initPageJs(doc: *Document, page: *PageState, allocator: std.mem.Allocator, loader: ?*Loader, base_url: ?[]const u8) void {
    var js_rt = JsRuntime.init() catch {
        std.debug.print("[JS] Failed to init JS runtime\n", .{});
        return;
    };

    // Register DOM APIs
    dom_api.registerDomApis(js_rt.rt, js_rt.ctx, @ptrCast(@alignCast(doc.html_doc)));

    // Register event APIs (addEventListener on window/document/elements)
    events.registerEventApis(js_rt.ctx);

    // Execute <script> tags (including external scripts via src attribute)
    executeScripts(doc, &js_rt, allocator, loader, base_url);

    // Fire DOMContentLoaded
    events.dispatchDocumentEvent(js_rt.ctx, "DOMContentLoaded");
    js_rt.executePending();

    // Fire load
    events.dispatchWindowEvent(js_rt.ctx, "load");
    js_rt.executePending();

    page.js_rt = js_rt;
}

/// Recursively collect image URLs from the box tree.
const ImageUrlEntry = struct {
    url: []const u8,
    intrinsic_width: f32,
    intrinsic_height: f32,
};

fn collectImageUrls(box: *const Box, urls: *std.ArrayListUnmanaged(ImageUrlEntry), allocator: std.mem.Allocator) void {
    if (box.box_type == .replaced) {
        if (box.image_url) |url| {
            urls.append(allocator, .{
                .url = url,
                .intrinsic_width = box.intrinsic_width,
                .intrinsic_height = box.intrinsic_height,
            }) catch {};
        }
    }
    for (box.children.items) |child| {
        collectImageUrls(child, urls, allocator);
    }
}

/// Recursively update replaced box intrinsic dimensions from decoded image cache.
/// When only width OR height was specified in HTML, computes the other from the
/// actual image aspect ratio. When neither was specified, uses actual image dimensions.
fn updateImageDimensions(box: *Box, cache: *ImageCache, updated: *bool) void {
    if (box.box_type == .replaced) {
        if (box.image_url) |url| {
            if (cache.get(url)) |img| {
                const actual_w: f32 = @floatFromInt(img.width);
                const actual_h: f32 = @floatFromInt(img.height);
                if (actual_w > 0 and actual_h > 0) {
                    const has_html_w = box.dom_node != null and
                        (if (box.dom_node.?.getAttribute("width")) |_| true else false);
                    const has_html_h = box.dom_node != null and
                        (if (box.dom_node.?.getAttribute("height")) |_| true else false);

                    if (has_html_w and !has_html_h) {
                        // Width specified, compute height from aspect ratio
                        box.intrinsic_height = box.intrinsic_width * actual_h / actual_w;
                        updated.* = true;
                    } else if (!has_html_w and has_html_h) {
                        // Height specified, compute width from aspect ratio
                        box.intrinsic_width = box.intrinsic_height * actual_w / actual_h;
                        updated.* = true;
                    } else if (!has_html_w and !has_html_h) {
                        // Neither specified, use actual image dimensions
                        box.intrinsic_width = actual_w;
                        box.intrinsic_height = actual_h;
                        updated.* = true;
                    }
                    // Both specified: keep HTML-specified dimensions (may distort)
                }
            }
        }
    }
    for (box.children.items) |child| {
        updateImageDimensions(child, cache, updated);
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
    storage: ?*Storage,
    layout_width: i32,
    layout_height: i32,
) bool {
    // Clean up old page
    page.deinit();

    // Check for internal suzume:// pages
    if (internal_pages.isInternalUrl(url_z)) {
        const html_owned = internal_pages.generatePage(allocator, url_z, storage) orelse {
            const msg = std.fmt.allocPrint(allocator, "Failed to generate internal page: {s}", .{url_z}) catch return false;
            page.error_message = msg;
            page.error_alloc = msg;
            return false;
        };

        // Parse the generated HTML
        var doc = Document.parse(html_owned) catch {
            allocator.free(html_owned);
            return false;
        };

        const root_node = doc.root() orelse {
            doc.deinit();
            allocator.free(html_owned);
            return false;
        };
        const body_node = doc.body() orelse {
            doc.deinit();
            allocator.free(html_owned);
            return false;
        };

        var styles = cascade_mod.cascade(root_node, allocator, null, @intCast(layout_width), @intCast(layout_height)) catch {
            doc.deinit();
            allocator.free(html_owned);
            return false;
        };

        const root_box = box_tree.buildBoxTree(body_node, &styles, allocator) catch {
            styles.deinit();
            doc.deinit();
            allocator.free(html_owned);
            return false;
        };

        const body_style = styles.getStyle(body_node) orelse @import("css/computed.zig").ComputedStyle{};
        const body_margin: f32 = if (body_style.margin_top == 0 and body_style.margin_left == 0) 8.0 else body_style.margin_left;
        root_box.margin = .{ .top = body_margin, .right = body_margin, .bottom = body_margin, .left = body_margin };

        const content_w: f32 = @floatFromInt(layout_width);
        const root_containing_width = content_w - root_box.margin.left - root_box.margin.right;
        block_layout.layoutBlockVp(root_box, root_containing_width, 0, fonts, @floatFromInt(layout_height));
        block_layout.adjustXPositions(root_box, root_box.margin.left);
        block_layout.adjustYPositions(root_box, root_box.margin.top);

        const total_h = painter_mod.contentHeight(root_box);
        const total_w = painter_mod.contentWidth(root_box);
        page.* = .{
            .doc = doc,
            .styles = styles,
            .root_box = root_box,
            .total_height = total_h,
            .total_width = total_w,
            .image_cache = ImageCache.init(allocator),
        };
        allocator.free(html_owned);
        return true;
    }

    // Check for downloadable content by doing a fetch and checking content type
    // For now, just do the standard page load

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

    // Style (pass external CSS from loader — includes <link> stylesheets)
    const ext_css: ?[]const u8 = if (content.css.len > 0) content.css else null;
    var styles = cascade_mod.cascade(root_node, allocator, ext_css, @intCast(layout_width), @intCast(layout_height)) catch {
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
    const body_style = styles.getStyle(body_node) orelse @import("css/computed.zig").ComputedStyle{};
    const body_margin: f32 = if (body_style.margin_top == 0 and body_style.margin_left == 0) 8.0 else body_style.margin_left;
    root_box.margin = .{ .top = body_margin, .right = body_margin, .bottom = body_margin, .left = body_margin };

    // Layout
    const content_w: f32 = @floatFromInt(layout_width);
    const root_containing_width = content_w - root_box.margin.left - root_box.margin.right;
    block_layout.layoutBlockVp(root_box, root_containing_width, 0, fonts, @floatFromInt(layout_height));
    block_layout.adjustXPositions(root_box, root_box.margin.left);
    block_layout.adjustYPositions(root_box, root_box.margin.top);

    // Collect image URLs for incremental loading (loaded 1 per event loop tick)
    const img_cache = ImageCache.init(allocator);
    var pending_imgs: std.ArrayListUnmanaged(ImageUrlEntry) = .empty;
    collectImageUrls(root_box, &pending_imgs, allocator);

    // Save base URL for image resolution
    const base_url_copy: ?[]const u8 = blk: {
        const bu = allocator.alloc(u8, url_z.len) catch break :blk null;
        @memcpy(bu, url_z);
        break :blk bu;
    };

    const total_h = painter_mod.contentHeight(root_box);
    const total_w = painter_mod.contentWidth(root_box);

    // Save external CSS for re-cascade after DOM mutations
    const saved_ext_css: ?[]const u8 = if (content.css.len > 0) blk: {
        const css_copy = allocator.alloc(u8, content.css.len) catch null;
        if (css_copy) |cc| {
            @memcpy(cc, content.css);
            break :blk cc;
        }
        break :blk null;
    } else null;

    page.* = .{
        .doc = doc,
        .styles = styles,
        .root_box = root_box,
        .total_height = total_h,
        .total_width = total_w,
        .image_cache = img_cache,
        .external_css = saved_ext_css,
        .pending_images = pending_imgs,
        .pending_images_idx = 0,
        .pending_images_loaded = 0,
        .base_url = base_url_copy,
    };

    // Set root box pointer for JS layout queries (offsetWidth, getBoundingClientRect, etc.)
    dom_api.setRootBox(page.root_box);

    // Initialize JavaScript: DOM APIs, execute scripts, fire events
    initPageJs(&page.doc.?, page, allocator, loader, base_url_copy);

    // Re-style if JS mutated the DOM during script execution
    if (dom_api.dom_dirty) {
        dom_api.dom_dirty = false;
        restylePage(page, allocator, fonts, layout_width, layout_height);
    }

    // Execute user scripts after page load
    if (page.js_rt) |*js_rt| {
        userscript.executeUserScripts(js_rt, allocator);
    }

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

    // Execute scripts (test mode: no loader/base_url for external scripts)
    executeScripts(&doc, &js_rt, std.heap.c_allocator, null, null);

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

/// Serialize open tabs to JSON for session persistence.
/// Excludes private tabs.
/// Append a JSON-escaped string to the list, handling control characters.
fn appendJsonEscaped(json: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, str: []const u8) !void {
    for (str) |ch| {
        switch (ch) {
            '"' => try json.appendSlice(allocator, "\\\""),
            '\\' => try json.appendSlice(allocator, "\\\\"),
            '\n' => try json.appendSlice(allocator, "\\n"),
            '\r' => try json.appendSlice(allocator, "\\r"),
            '\t' => try json.appendSlice(allocator, "\\t"),
            else => {
                if (ch < 0x20) {
                    // Escape other control characters as \u00XX
                    try json.appendSlice(allocator, "\\u00");
                    const hex = "0123456789abcdef";
                    try json.append(allocator, hex[(ch >> 4) & 0x0f]);
                    try json.append(allocator, hex[ch & 0x0f]);
                } else {
                    try json.append(allocator, ch);
                }
            },
        }
    }
}

fn serializeSession(allocator: std.mem.Allocator, tab_mgr: *const TabManager) ?[]u8 {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(allocator);

    json.appendSlice(allocator, "[") catch return null;
    var first = true;
    for (tab_mgr.tabs.items) |tab| {
        if (tab.is_private) continue;
        if (tab.url.len == 0) continue;

        if (!first) {
            json.appendSlice(allocator, ",") catch return null;
        }
        first = false;

        json.appendSlice(allocator, "{\"url\":\"") catch return null;
        // Escape the URL for JSON
        appendJsonEscaped(&json, allocator, tab.url) catch return null;
        json.appendSlice(allocator, "\",\"title\":\"") catch return null;
        appendJsonEscaped(&json, allocator, tab.title) catch return null;
        // Write scroll_y as integer
        var scroll_buf: [32]u8 = undefined;
        const scroll_str = std.fmt.bufPrint(&scroll_buf, "{d}", .{@as(i32, @intFromFloat(tab.scroll_y))}) catch "0";
        json.appendSlice(allocator, "\",\"scroll_y\":") catch return null;
        json.appendSlice(allocator, scroll_str) catch return null;
        // Write scroll_x as integer
        var scroll_x_buf: [32]u8 = undefined;
        const scroll_x_str = std.fmt.bufPrint(&scroll_x_buf, "{d}", .{@as(i32, @intFromFloat(tab.scroll_x))}) catch "0";
        json.appendSlice(allocator, ",\"scroll_x\":") catch return null;
        json.appendSlice(allocator, scroll_x_str) catch return null;
        json.appendSlice(allocator, "}") catch return null;
    }
    json.appendSlice(allocator, "]") catch return null;

    return json.toOwnedSlice(allocator) catch null;
}

/// Restore tabs from session JSON.
/// Tabs are restored with URLs and titles but pages are NOT loaded (lazy loading).
/// The active tab will be loaded on first paint; other tabs load when switched to.
fn restoreSession(
    allocator: std.mem.Allocator,
    json: []const u8,
    tab_mgr: *TabManager,
    page_states: *std.ArrayListUnmanaged(PageState),
) void {
    // Simple JSON array parser for [{"url":"...","title":"...","scroll_y":N}, ...]
    // We extract url and title fields using basic string scanning
    var pos: usize = 0;
    var tab_count: usize = 0;

    while (pos < json.len) {
        // Find next "url":"
        const url_key = std.mem.indexOfPos(u8, json, pos, "\"url\":\"") orelse break;
        const url_start = url_key + 7; // length of "url":"
        const url_end = std.mem.indexOfPos(u8, json, url_start, "\"") orelse break;
        const url = json[url_start..url_end];

        // Try to extract title
        var title: []const u8 = url;
        const title_key = std.mem.indexOfPos(u8, json, url_end, "\"title\":\"");
        if (title_key) |tk| {
            const title_start = tk + 9;
            if (std.mem.indexOfPos(u8, json, title_start, "\"")) |title_end| {
                title = json[title_start..title_end];
            }
        }

        if (url.len > 0) {
            if (tab_count == 0 and tab_mgr.tabCount() == 1) {
                // Replace the default first tab instead of creating a new one
                tab_mgr.updateActiveUrl(url);
                tab_mgr.updateActiveTitle(if (title.len > 0) title else url);
            } else {
                _ = tab_mgr.newTab(url);
                // Update the title for the newly created tab
                tab_mgr.updateActiveTitle(if (title.len > 0) title else url);
                page_states.append(allocator, PageState{}) catch |err| {
                    std.debug.print("[Error] Failed to append page state: {}\n", .{err});
                };
            }
            tab_count += 1;
        }

        pos = url_end + 1;
    }

    if (tab_count > 0) {
        // Switch to first tab
        _ = tab_mgr.switchTo(0);
        std.debug.print("[Session] Restored {d} tabs (lazy loading)\n", .{tab_count});
    }
}

/// Process URL bar input: detect search queries vs URLs.
/// - If input starts with http:// or https://, use as-is.
/// - If input contains a dot (e.g. "example.com"), prepend https://
/// - Otherwise, treat as a search query and redirect to Brave Search.
/// Returns an owned sentinel-terminated string.
fn processUrlInput(allocator: std.mem.Allocator, input: []const u8) ![:0]const u8 {
    // Already a full URL
    if (std.mem.startsWith(u8, input, "http://") or std.mem.startsWith(u8, input, "https://")) {
        const result = try allocator.allocSentinel(u8, input.len, 0);
        @memcpy(result, input);
        return result;
    }

    // Internal pages
    if (std.mem.startsWith(u8, input, "suzume://")) {
        const result = try allocator.allocSentinel(u8, input.len, 0);
        @memcpy(result, input);
        return result;
    }

    // Contains a dot — likely a domain name, prepend https://
    if (std.mem.indexOf(u8, input, ".") != null) {
        const prefix = "https://";
        const result = try allocator.allocSentinel(u8, prefix.len + input.len, 0);
        @memcpy(result[0..prefix.len], prefix);
        @memcpy(result[prefix.len..][0..input.len], input);
        return result;
    }

    // Otherwise, treat as a search query
    // URL-encode the query for Brave Search
    const base = "https://search.brave.com/search?q=";
    const source = "&source=web";

    // Calculate encoded length
    var encoded_len: usize = 0;
    for (input) |ch| {
        if (isUrlSafe(ch)) {
            encoded_len += 1;
        } else if (ch == ' ') {
            encoded_len += 1; // '+'
        } else {
            encoded_len += 3; // %XX
        }
    }

    const total_len = base.len + encoded_len + source.len;
    const result = try allocator.allocSentinel(u8, total_len, 0);

    @memcpy(result[0..base.len], base);

    var pos: usize = base.len;
    for (input) |ch| {
        if (isUrlSafe(ch)) {
            result[pos] = ch;
            pos += 1;
        } else if (ch == ' ') {
            result[pos] = '+';
            pos += 1;
        } else {
            const hex = "0123456789ABCDEF";
            result[pos] = '%';
            result[pos + 1] = hex[(ch >> 4) & 0x0f];
            result[pos + 2] = hex[ch & 0x0f];
            pos += 3;
        }
    }

    @memcpy(result[pos..][0..source.len], source);
    return result;
}

/// Check if a URL points to an SVG image (by file extension).
/// Check if a URL is likely a tracking pixel or beacon image.
fn isTrackingPixel(url: []const u8, intrinsic_w: f32, intrinsic_h: f32) bool {
    // Skip if HTML attributes indicate tiny dimensions (1x1, 2x1, etc.)
    const is_tiny = intrinsic_w > 0 and intrinsic_h > 0 and intrinsic_w <= 2 and intrinsic_h <= 2;
    if (is_tiny) {
        return true;
    }

    // URL keyword check only when dimensions are unknown (0x0) — avoids
    // false positives on URLs like "/pixel-art/logo.png"
    if (intrinsic_w == 0 and intrinsic_h == 0) {
        // Case-insensitive check using stack buffer
        var lower_buf: [512]u8 = undefined;
        const check_len = @min(url.len, lower_buf.len);
        for (url[0..check_len], 0..) |ch, idx| {
            lower_buf[idx] = std.ascii.toLower(ch);
        }
        const lower_url = lower_buf[0..check_len];
        // Only match path-segment boundaries: "/pixel." "/beacon/" "/1x1" "/spacer."
        const tracking_patterns = [_][]const u8{ "/pixel.", "/beacon", "/1x1", "/spacer." };
        for (tracking_patterns) |pattern| {
            if (std.mem.indexOf(u8, lower_url, pattern) != null) {
                return true;
            }
        }
    }

    return false;
}

fn isSvgUrl(url: []const u8) bool {
    // Strip query string and fragment
    const path_end = std.mem.indexOf(u8, url, "?") orelse std.mem.indexOf(u8, url, "#") orelse url.len;
    const path = url[0..path_end];
    if (path.len < 4) return false;

    const ext = path[path.len - 4 ..];
    return std.mem.eql(u8, ext, ".svg");
}

/// Check if content-type indicates SVG.
fn isSvgContentType(content_type: []const u8) bool {
    return std.mem.startsWith(u8, content_type, "image/svg");
}

fn isUrlSafe(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or
        (ch >= 'a' and ch <= 'z') or
        (ch >= '0' and ch <= '9') or
        ch == '-' or ch == '_' or ch == '.' or ch == '~';
}

/// Extract the <title> text from a parsed document.
fn extractTitle(doc: *Document) ?[]const u8 {
    const head_node = doc.head() orelse return null;
    var child = head_node.firstChild();
    while (child) |node| {
        defer child = node.nextSibling();
        if (node.nodeType() != .element) continue;
        const tag = node.tagName() orelse continue;
        if (std.mem.eql(u8, tag, "title")) {
            // Get text content of <title>
            if (node.firstChild()) |text_node| {
                return text_node.textContent();
            }
            return null;
        }
    }
    return null;
}

pub fn main() !void {
    // Use GeneralPurposeAllocator in debug mode for double-free / use-after-free detection.
    // In release mode, use c_allocator for performance.
    var gpa: std.heap.GeneralPurposeAllocator(.{
        .stack_trace_frames = if (@import("builtin").mode == .Debug) 8 else 0,
        .safety = (@import("builtin").mode == .Debug),
    }) = .init;
    defer if (@import("builtin").mode == .Debug) {
        _ = gpa.deinit();
    };
    const allocator = if (@import("builtin").mode == .Debug) gpa.allocator() else std.heap.c_allocator;

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

    std.debug.print("suzume v0.4.0 — browser mode\n", .{});

    // Init config
    var config = Config.init(allocator);
    defer config.deinit();

    // Init storage
    var storage_inst: ?Storage = Storage.init(allocator) catch |err| blk: {
        std.debug.print("Warning: failed to init storage: {}\n", .{err});
        break :blk null;
    };
    defer if (storage_inst) |*s| s.deinit();

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
    var surface = Surface.init(default_window_w, default_window_h) catch |err| {
        std.debug.print("Failed to create surface: {}\n", .{err});
        return err;
    };
    defer surface.deinit();

    // Initialize XIM (X Input Method) for fcitx5/mozc Japanese input
    if (surface.initXim()) {
        std.debug.print("[XIM] Input method initialized\n", .{});
        surface.ximFocusIn();
    } else {
        std.debug.print("[XIM] Input method not available (Japanese input disabled)\n", .{});
    }
    defer surface.deinitXim();

    // URL bar input
    var url_input = TextInput.init(allocator);
    defer url_input.deinit();
    url_input.focused = true;

    // Status
    var status_text: []const u8 = "Ready";

    // Tab manager
    const max_tabs_cfg = config.getInt("max_active_tabs") orelse 3;
    var tab_mgr = TabManager.init(allocator, @intCast(@max(max_tabs_cfg, 1)));
    defer tab_mgr.deinit();

    // Page states: one per tab. Index corresponds to tab index.
    var page_states: std.ArrayListUnmanaged(PageState) = .empty;
    defer {
        for (page_states.items) |*ps| ps.deinit();
        page_states.deinit(allocator);
    }

    // Create initial tab
    {
        const homepage = config.get("homepage") orelse "about:blank";
        _ = tab_mgr.newTab(if (initial_url) |u| u else homepage);
        page_states.append(allocator, PageState{}) catch |err| {
            std.debug.print("[Error] Failed to append initial page state: {}\n", .{err});
        };
    }

    // Scroll
    var scroll_y: f32 = 0;
    var scroll_x: f32 = 0;

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

    // Focused form input state
    var focused_input_node: ?*lxb.lxb_dom_node_t = null; // DOM node of focused <input>
    var prev_focused_input_node: ?*lxb.lxb_dom_node_t = null; // Previously focused node (for blur events)
    var form_input = TextInput.init(allocator); // text buffer for focused input
    var xim_composing: bool = false; // true when Mozc/XIM is in composition state
    defer form_input.deinit();

    // Modifier key state
    var shift_held = false;
    var ctrl_held = false;
    var alt_held = false;

    // Mouse position tracking (for move events)
    var mouse_x: i32 = 0;
    var mouse_y: i32 = 0;

    // Find bar (Ctrl+F)
    var find_bar = FindBar.init(allocator);
    defer find_bar.deinit();

    // Session persistence timer (save every ~30 seconds)
    // We count event loop iterations; at 50ms poll timeout, ~600 iterations = 30s
    var session_timer: u32 = 0;
    const session_save_interval: u32 = 600;

    // Apply adblock config to loader
    if (config.get("adblock_enabled")) |val| {
        loader.adblock_enabled = std.mem.eql(u8, val, "true");
    }

    // Restore session if no initial URL provided
    if (initial_url == null) {
        if (storage_inst) |*s| {
            if (s.loadSession()) |session_json| {
                defer allocator.free(session_json);
                restoreSession(allocator, session_json, &tab_mgr, &page_states);

                // Auto-load the active (first) tab after session restore
                if (tab_mgr.getActiveTab()) |tab| {
                    if (tab.url.len > 0 and tab_mgr.active_index < page_states.items.len) {
                        const pg = &page_states.items[tab_mgr.active_index];
                        const url_z = allocator.allocSentinel(u8, tab.url.len, 0) catch null;
                        if (url_z) |uz| {
                            defer allocator.free(uz);
                            @memcpy(uz, tab.url);
                            url_input.setText(tab.url);
                            url_input.focused = false;
                            status_text = "Loading...";
                            if (navigateTo(allocator, &loader, uz, &fonts, pg, if (storage_inst) |*si| si else null, surface.width, surface.height)) {
                                status_text = "Done";
                                scroll_y = 0;
                                scroll_x = 0;
                                if (current_url) |old| allocator.free(old);
                                current_url = allocator.dupe(u8, tab.url) catch null;
                            } else {
                                status_text = "Failed";
                            }
                        }
                    }
                }
            }
        }
    }

    // Ensure user scripts directory exists
    userscript.ensureScriptsDir(allocator);

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

            if (page_states.items.len > 0) {
                if (navigateTo(allocator, &loader, uz, &fonts, &page_states.items[0], if (storage_inst) |*s| s else null, surface.width, surface.height)) {
                    status_text = "Done";
                    scroll_y = 0;
                    scroll_x = 0;
                    tab_mgr.updateActiveUrl(url);
                    // Extract page title
                    const init_title = if (page_states.items[0].doc) |*d| extractTitle(d) else null;
                    tab_mgr.updateActiveTitle(init_title orelse url);
                    // Store in history
                    const owned = allocator.alloc(u8, url.len) catch null;
                    if (owned) |o| {
                        @memcpy(o, url);
                        history.append(allocator, o) catch {};
                        history_pos = history.items.len - 1;
                        if (current_url) |old| allocator.free(old);
                        const cu = allocator.alloc(u8, url.len) catch null;
                        if (cu) |cc| {
                            @memcpy(cc, url);
                            current_url = cc;
                        }
                    }
                    // Record in storage (skip for private tabs)
                    if (storage_inst) |*s| {
                        const is_priv = if (tab_mgr.getActiveTab()) |t| t.is_private else false;
                        if (!is_priv) {
                            s.addHistory(url, init_title orelse url);
                        }
                    }
                } else {
                    status_text = "Failed";
                }
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

            // Paint page content (from active tab's page state)
            const active_page: ?*PageState = if (tab_mgr.active_index < page_states.items.len)
                &page_states.items[tab_mgr.active_index]
            else
                null;

            if (active_page) |page| {
                if (page.root_box) |root_box| {
                    // scroll_y is in layout coords; we offset by content_y for screen position
                    const adjusted_scroll = scroll_y - @as(f32, @floatFromInt(chrome.content_y));
                    const ic_ptr: ?*ImageCache = if (page.image_cache) |*ic| ic else null;
                    painter_mod.paint(
                        root_box,
                        &surface,
                        &fonts,
                        adjusted_scroll,
                        scroll_x,
                        chrome.content_y,
                        chrome.content_y + chrome.contentHeight(surface.height),
                        ic_ptr,
                    );

                    // Paint focused form input overlay
                    if (focused_input_node != null) {
                        paintFocusedInput(
                            root_box,
                            &surface,
                            &fonts,
                            focused_input_node.?,
                            &form_input,
                            adjusted_scroll,
                            scroll_x,
                            chrome.content_y,
                            chrome.content_y + chrome.contentHeight(surface.height),
                        );
                    }
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
            }

            // Paint chrome on top
            chrome.paintUrlBar(&surface, &fonts, &url_input);
            chrome.paintTabBar(&surface, &fonts, &tab_mgr);
            chrome.paintStatusBar(&surface, &fonts, status_text);

            // Paint find bar (above status bar, if visible)
            search.paintFindBar(&surface, &fonts, &find_bar);

            surface.update();
            needs_repaint = false;
        }

        // Tick JS timers (setTimeout/setInterval) and check for DOM mutations
        // Limit timer execution to prevent blocking the event loop
        {
            const active_pg: ?*PageState = if (tab_mgr.active_index < page_states.items.len)
                &page_states.items[tab_mgr.active_index]
            else
                null;
            if (active_pg) |pg| {
                if (pg.js_rt) |*js_rt| {
                    _ = web_api.tickTimers(js_rt.ctx);
                    js_rt.executePending();
                    if (dom_api.dom_dirty) {
                        dom_api.dom_dirty = false;
                        restylePage(pg, allocator, &fonts, surface.width, surface.height);
                        needs_repaint = true;
                    }
                }
            }
        }

        // Poll XIM for asynchronously committed text (Mozc confirmed input)
        if (surface.xim_initialized) {
            if (surface.pollXimCommitted()) |committed| {
                xim_composing = false; // composition completed
                if (find_bar.visible) {
                    find_bar.insertText(committed);
                } else if (focused_input_node != null) {
                    form_input.insertText(committed);
                    // Dispatch "input" event on the focused element
                    {
                        const xim_pg: ?*PageState = if (tab_mgr.active_index < page_states.items.len) &page_states.items[tab_mgr.active_index] else null;
                        if (xim_pg) |pg| {
                            if (pg.js_rt) |*js_rt| {
                                _ = events.dispatchEvent(js_rt.ctx, focused_input_node.?, "input");
                                js_rt.executePending();
                            }
                        }
                    }
                } else if (url_input.focused) {
                    url_input.insertText(committed);
                }
                needs_repaint = true;
            }
        }

        // Session persistence: save periodically
        session_timer += 1;
        if (session_timer >= session_save_interval) {
            session_timer = 0;
            if (storage_inst) |*s| {
                if (serializeSession(allocator, &tab_mgr)) |json| {
                    defer allocator.free(json);
                    s.saveSession(json);
                }
            }
        }

        // Incremental image loading: load 1 image per event loop tick
        {
            const active_img_pg: ?*PageState = if (tab_mgr.active_index < page_states.items.len)
                &page_states.items[tab_mgr.active_index]
            else
                null;
            if (active_img_pg) |pg| {
                if (pg.pending_images_idx < pg.pending_images.items.len and pg.pending_images_loaded < 30) {
                    const entry = pg.pending_images.items[pg.pending_images_idx];
                    pg.pending_images_idx += 1;

                    const img_url = entry.url;
                    if (!isTrackingPixel(img_url, entry.intrinsic_width, entry.intrinsic_height) and !isSvgUrl(img_url)) {
                        if (pg.base_url) |base| {
                            if (resolveUrl(allocator, base, img_url)) |resolved| {
                                defer allocator.free(resolved);
                                if (!isSvgUrl(resolved)) {
                                    if (loader.loadBytesWithTimeout(resolved, 3)) |resp_val| {
                                        var resp = resp_val;
                                        defer resp.deinit();
                                        if (resp.status_code == 200 and resp.body.len > 0 and resp.body.len <= 2 * 1024 * 1024 and !isSvgContentType(resp.content_type)) {
                                            if (decodeImage(resp.body)) |img| {
                                                const px_count: u64 = @as(u64, img.width) * @as(u64, img.height);
                                                if (px_count <= 4 * 1024 * 1024) {
                                                    if (pg.image_cache) |*ic| {
                                                        ic.put(img_url, img) catch {
                                                            var mimg = img;
                                                            mimg.deinit();
                                                        };
                                                        pg.pending_images_loaded += 1;
                                                        // Update intrinsic dimensions from actual image
                                                        if (pg.root_box) |rb| {
                                                            var updated = false;
                                                            updateImageDimensions(rb, ic, &updated);
                                                            if (updated) {
                                                                // Re-layout to apply new aspect ratios
                                                                const cw: f32 = @floatFromInt(surface.width);
                                                                const rcw = cw - rb.margin.left - rb.margin.right;
                                                                block_layout.layoutBlockVp(rb, rcw, 0, &fonts, @floatFromInt(surface.height));
                                                                block_layout.adjustXPositions(rb, rb.margin.left);
                                                                block_layout.adjustYPositions(rb, rb.margin.top);
                                                                pg.total_height = painter_mod.contentHeight(rb);
                                                                pg.total_width = painter_mod.contentWidth(rb);
                                                            }
                                                        }
                                                        needs_repaint = true;
                                                    }
                                                } else {
                                                    var mimg = img;
                                                    mimg.deinit();
                                                }
                                            } else |_| {}
                                        }
                                    } else |_| {}
                                }
                            } else |_| {}
                        }
                    }
                }
            }
        }

        if (surface.pollEvent(50)) |event| {
            switch (event.type) {
                nsfb_c.NSFB_EVENT_CONTROL => {
                    if (event.value.controlcode == nsfb_c.NSFB_CONTROL_QUIT) {
                        running = false;
                    }
                },

                nsfb_c.NSFB_EVENT_RESIZE => {
                    // Window was resized (e.g. by i3 tiling WM)
                    surface.refreshGeometry();
                    std.debug.print("[Resize] New size: {d}x{d}\n", .{ surface.width, surface.height });
                    needs_repaint = true;
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

                    // Ctrl+L: focus URL bar and select all (clear for new input)
                    if (ctrl_held and key == nsfb_c.NSFB_KEY_l) {
                        url_input.focused = true;
                        // Clear the URL bar so user can immediately type a new URL.
                        // Old URL is restored on Escape.
                        url_input.setText("");
                        needs_repaint = true;
                        continue;
                    }

                    // Ctrl+T: new tab
                    if (ctrl_held and key == nsfb_c.NSFB_KEY_t) {
                        // Save scroll position of current tab
                        tab_mgr.saveScrollPosition(scroll_y, scroll_x);

                        const homepage = config.get("homepage") orelse "about:blank";
                        _ = tab_mgr.newTab(homepage);
                        page_states.append(allocator, PageState{}) catch |err| {
                            std.debug.print("[Error] Failed to append page state: {}\n", .{err});
                        };

                        // Reset state for new tab
                        scroll_y = 0;
                        scroll_x = 0;
                        url_input.setText("");
                        url_input.focused = true;
                        if (current_url) |old| allocator.free(old);
                        current_url = null;
                        status_text = "New Tab";
                        needs_repaint = true;
                        std.debug.print("[Tabs] New tab (total: {d})\n", .{tab_mgr.tabCount()});
                        continue;
                    }

                    // Ctrl+W: close current tab
                    if (ctrl_held and key == nsfb_c.NSFB_KEY_w) {
                        if (tab_mgr.tabCount() <= 1) {
                            // Last tab — quit
                            running = false;
                            continue;
                        }
                        const close_idx = tab_mgr.active_index;
                        // Clean up page state
                        if (close_idx < page_states.items.len) {
                            page_states.items[close_idx].deinit();
                            _ = page_states.orderedRemove(close_idx);
                        }
                        tab_mgr.closeTab(close_idx);

                        // Restore state from new active tab
                        if (tab_mgr.getActiveTab()) |tab| {
                            scroll_y = tab.scroll_y;
                            scroll_x = tab.scroll_x;
                            url_input.setText(tab.url);
                            url_input.focused = false;
                            if (current_url) |old| allocator.free(old);
                            current_url = allocator.dupe(u8, tab.url) catch null;
                        }
                        status_text = "Tab closed";
                        needs_repaint = true;
                        std.debug.print("[Tabs] Closed tab, now {d} tabs\n", .{tab_mgr.tabCount()});
                        continue;
                    }

                    // Ctrl+Tab: next tab
                    if (ctrl_held and key == nsfb_c.NSFB_KEY_TAB and !shift_held) {
                        tab_mgr.saveScrollPosition(scroll_y, scroll_x);
                        if (tab_mgr.nextTab()) {
                            if (tab_mgr.getActiveTab()) |tab| {
                                scroll_y = tab.scroll_y;
                                scroll_x = tab.scroll_x;
                                url_input.setText(tab.url);
                                url_input.focused = false;
                                if (current_url) |old| allocator.free(old);
                                current_url = allocator.dupe(u8, tab.url) catch null;
                            }
                            needs_repaint = true;
                        }
                        continue;
                    }

                    // Ctrl+Shift+Tab: previous tab
                    if (ctrl_held and key == nsfb_c.NSFB_KEY_TAB and shift_held) {
                        tab_mgr.saveScrollPosition(scroll_y, scroll_x);
                        if (tab_mgr.prevTab()) {
                            if (tab_mgr.getActiveTab()) |tab| {
                                scroll_y = tab.scroll_y;
                                scroll_x = tab.scroll_x;
                                url_input.setText(tab.url);
                                url_input.focused = false;
                                if (current_url) |old| allocator.free(old);
                                current_url = allocator.dupe(u8, tab.url) catch null;
                            }
                            needs_repaint = true;
                        }
                        continue;
                    }

                    // Ctrl+1 through Ctrl+9: switch to tab N
                    if (ctrl_held and key >= nsfb_c.NSFB_KEY_1 and key <= nsfb_c.NSFB_KEY_9) {
                        const tab_idx: usize = @intCast(key - nsfb_c.NSFB_KEY_1);
                        if (tab_idx < tab_mgr.tabCount()) {
                            tab_mgr.saveScrollPosition(scroll_y, scroll_x);
                            if (tab_mgr.switchTo(tab_idx)) {
                                if (tab_mgr.getActiveTab()) |tab| {
                                    scroll_y = tab.scroll_y;
                                    scroll_x = tab.scroll_x;
                                    url_input.setText(tab.url);
                                    url_input.focused = false;
                                    if (current_url) |old| allocator.free(old);
                                    current_url = allocator.dupe(u8, tab.url) catch null;
                                }
                                needs_repaint = true;
                            }
                        }
                        continue;
                    }

                    // F5: reload
                    if (key == nsfb_c.NSFB_KEY_F5) {
                        focused_input_node = null;
                        if (current_url) |url| {
                            const url_z = allocator.allocSentinel(u8, url.len, 0) catch continue;
                            defer allocator.free(url_z);
                            @memcpy(url_z, url);
                            status_text = "Loading...";
                            needs_repaint = true;
                            const pg = if (tab_mgr.active_index < page_states.items.len) &page_states.items[tab_mgr.active_index] else continue;
                            if (navigateTo(allocator, &loader, url_z, &fonts, pg, if (storage_inst) |*s| s else null, surface.width, surface.height)) {
                                status_text = "Done";
                                scroll_y = 0;
                                scroll_x = 0;
                            } else {
                                status_text = "Failed";
                            }
                            needs_repaint = true;
                        }
                        continue;
                    }

                    // Ctrl+R: reload
                    if (ctrl_held and key == nsfb_c.NSFB_KEY_r) {
                        focused_input_node = null;
                        if (current_url) |url| {
                            const url_z = allocator.allocSentinel(u8, url.len, 0) catch continue;
                            defer allocator.free(url_z);
                            @memcpy(url_z, url);
                            status_text = "Loading...";
                            needs_repaint = true;
                            const pg = if (tab_mgr.active_index < page_states.items.len) &page_states.items[tab_mgr.active_index] else continue;
                            if (navigateTo(allocator, &loader, url_z, &fonts, pg, if (storage_inst) |*s| s else null, surface.width, surface.height)) {
                                status_text = "Done";
                                scroll_y = 0;
                                scroll_x = 0;
                            } else {
                                status_text = "Failed";
                            }
                            needs_repaint = true;
                        }
                        continue;
                    }

                    // Ctrl+H: open history page
                    if (ctrl_held and key == nsfb_c.NSFB_KEY_h) {
                        url_input.setText("suzume://history");
                        url_input.focused = false;
                        status_text = "Loading...";
                        needs_repaint = true;
                        const hist_url = "suzume://history";
                        const url_z = allocator.allocSentinel(u8, hist_url.len, 0) catch continue;
                        defer allocator.free(url_z);
                        @memcpy(url_z, hist_url);
                        const pg = if (tab_mgr.active_index < page_states.items.len) &page_states.items[tab_mgr.active_index] else continue;
                        if (navigateTo(allocator, &loader, url_z, &fonts, pg, if (storage_inst) |*s| s else null, surface.width, surface.height)) {
                            status_text = "Done";
                            scroll_y = 0;
                            scroll_x = 0;
                            tab_mgr.updateActiveUrl(hist_url);
                            tab_mgr.updateActiveTitle("History");
                        } else {
                            status_text = "Failed";
                        }
                        needs_repaint = true;
                        continue;
                    }

                    // Ctrl+D: toggle bookmark for current URL
                    if (ctrl_held and key == nsfb_c.NSFB_KEY_d) {
                        if (storage_inst) |*s| {
                            if (current_url) |url| {
                                if (s.isBookmarked(url)) {
                                    s.removeBookmark(url);
                                    status_text = "Bookmark removed";
                                    std.debug.print("[Bookmarks] Removed: {s}\n", .{url});
                                } else {
                                    const title = if (tab_mgr.getActiveTab()) |t| t.title else url;
                                    s.addBookmark(url, title);
                                    status_text = "Bookmarked!";
                                    std.debug.print("[Bookmarks] Added: {s}\n", .{url});
                                }
                                needs_repaint = true;
                            }
                        }
                        continue;
                    }

                    // Ctrl+F: open find bar
                    if (ctrl_held and key == nsfb_c.NSFB_KEY_f) {
                        find_bar.open();
                        url_input.focused = false;
                        needs_repaint = true;
                        continue;
                    }

                    // Ctrl+Shift+N: new private tab
                    if (ctrl_held and shift_held and key == nsfb_c.NSFB_KEY_n) {
                        tab_mgr.saveScrollPosition(scroll_y, scroll_x);
                        const homepage = config.get("homepage") orelse "about:blank";
                        _ = tab_mgr.newPrivateTab(homepage);
                        page_states.append(allocator, PageState{}) catch |err| {
                            std.debug.print("[Error] Failed to append page state: {}\n", .{err});
                        };
                        scroll_y = 0;
                        scroll_x = 0;
                        url_input.setText("");
                        url_input.focused = true;
                        if (current_url) |old| allocator.free(old);
                        current_url = null;
                        status_text = "Private Tab";
                        needs_repaint = true;
                        std.debug.print("[Tabs] New private tab (total: {d})\n", .{tab_mgr.tabCount()});
                        continue;
                    }

                    // Alt+Left: back
                    if (alt_held and key == nsfb_c.NSFB_KEY_LEFT) {
                        focused_input_node = null;
                        if (history_pos > 0) {
                            history_pos -= 1;
                            const url = history.items[history_pos];
                            const url_z = allocator.allocSentinel(u8, url.len, 0) catch continue;
                            defer allocator.free(url_z);
                            @memcpy(url_z, url);
                            url_input.setText(url);
                            status_text = "Loading...";
                            needs_repaint = true;
                            const pg = if (tab_mgr.active_index < page_states.items.len) &page_states.items[tab_mgr.active_index] else continue;
                            if (navigateTo(allocator, &loader, url_z, &fonts, pg, if (storage_inst) |*s| s else null, surface.width, surface.height)) {
                                status_text = "Done";
                                scroll_y = 0;
                                scroll_x = 0;
                                if (current_url) |old| allocator.free(old);
                                const cu = allocator.alloc(u8, url.len) catch null;
                                if (cu) |c| {
                                    @memcpy(c, url);
                                    current_url = c;
                                }
                                tab_mgr.updateActiveUrl(url);
                            } else {
                                status_text = "Failed";
                            }
                            needs_repaint = true;
                        }
                        continue;
                    }

                    // Alt+Right: forward
                    if (alt_held and key == nsfb_c.NSFB_KEY_RIGHT) {
                        focused_input_node = null;
                        if (history_pos + 1 < history.items.len) {
                            history_pos += 1;
                            const url = history.items[history_pos];
                            const url_z = allocator.allocSentinel(u8, url.len, 0) catch continue;
                            defer allocator.free(url_z);
                            @memcpy(url_z, url);
                            url_input.setText(url);
                            status_text = "Loading...";
                            needs_repaint = true;
                            const pg = if (tab_mgr.active_index < page_states.items.len) &page_states.items[tab_mgr.active_index] else continue;
                            if (navigateTo(allocator, &loader, url_z, &fonts, pg, if (storage_inst) |*s| s else null, surface.width, surface.height)) {
                                status_text = "Done";
                                scroll_y = 0;
                                scroll_x = 0;
                                if (current_url) |old| allocator.free(old);
                                const cu = allocator.alloc(u8, url.len) catch null;
                                if (cu) |c| {
                                    @memcpy(c, url);
                                    current_url = c;
                                }
                                tab_mgr.updateActiveUrl(url);
                            } else {
                                status_text = "Failed";
                            }
                            needs_repaint = true;
                        }
                        continue;
                    }

                    // Handle mouse events regardless of focus
                    if (key == nsfb_c.NSFB_KEY_MOUSE_1) {
                        std.debug.print("[MOUSE] click at ({d},{d})\n", .{ mouse_x, mouse_y });
                        // Check tab bar clicks first
                        const tab_hit = chrome.hitTestTabBar(mouse_x, mouse_y, &tab_mgr, surface.width);
                        switch (tab_hit.action) {
                            .new_tab => {
                                tab_mgr.saveScrollPosition(scroll_y, scroll_x);
                                const homepage = config.get("homepage") orelse "about:blank";
                                _ = tab_mgr.newTab(homepage);
                                page_states.append(allocator, PageState{}) catch |err| {
                                    std.debug.print("[Error] Failed to append page state: {}\n", .{err});
                                };
                                scroll_y = 0;
                                scroll_x = 0;
                                url_input.setText("");
                                url_input.focused = true;
                                if (current_url) |old| allocator.free(old);
                                current_url = null;
                                status_text = "New Tab";
                                needs_repaint = true;
                                continue;
                            },
                            .close_tab => {
                                if (tab_mgr.tabCount() <= 1) {
                                    running = false;
                                    continue;
                                }
                                const ci = tab_hit.index;
                                if (ci < page_states.items.len) {
                                    page_states.items[ci].deinit();
                                    _ = page_states.orderedRemove(ci);
                                }
                                tab_mgr.closeTab(ci);
                                if (tab_mgr.getActiveTab()) |tab| {
                                    scroll_y = tab.scroll_y;
                                    scroll_x = tab.scroll_x;
                                    url_input.setText(tab.url);
                                    url_input.focused = false;
                                    if (current_url) |old| allocator.free(old);
                                    current_url = allocator.dupe(u8, tab.url) catch null;
                                }
                                needs_repaint = true;
                                continue;
                            },
                            .switch_tab => {
                                tab_mgr.saveScrollPosition(scroll_y, scroll_x);
                                if (tab_mgr.switchTo(tab_hit.index)) {
                                    if (tab_mgr.getActiveTab()) |tab| {
                                        scroll_y = tab.scroll_y;
                                        scroll_x = tab.scroll_x;
                                        url_input.setText(tab.url);
                                        url_input.focused = false;
                                        if (current_url) |old| allocator.free(old);
                                        current_url = allocator.dupe(u8, tab.url) catch null;

                                        // Lazy load: if this tab has no loaded page, navigate to its URL
                                        if (tab_hit.index < page_states.items.len) {
                                            const pg = &page_states.items[tab_hit.index];
                                            if (pg.root_box == null and pg.error_message == null and tab.url.len > 0) {
                                                const url_z = allocator.allocSentinel(u8, tab.url.len, 0) catch null;
                                                if (url_z) |uz| {
                                                    defer allocator.free(uz);
                                                    @memcpy(uz, tab.url);
                                                    status_text = "Loading...";
                                                    if (navigateTo(allocator, &loader, uz, &fonts, pg, if (storage_inst) |*s| s else null, surface.width, surface.height)) {
                                                        status_text = "Done";
                                                        scroll_y = 0;
                                                        scroll_x = 0;
                                                    } else {
                                                        status_text = "Failed";
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    needs_repaint = true;
                                }
                                continue;
                            },
                            .none => {},
                        }

                        // Not a tab bar click — forward to regular click handler
                        const active_pg: ?*PageState = if (tab_mgr.active_index < page_states.items.len)
                            &page_states.items[tab_mgr.active_index]
                        else
                            null;
                        if (active_pg) |page| {
                            prev_focused_input_node = focused_input_node;
                            handleClick(
                                allocator,
                                mouse_x,
                                mouse_y,
                                &url_input,
                                &scroll_y,
                                &scroll_x,
                                page,
                                &fonts,
                                &loader,
                                &history,
                                &history_pos,
                                &current_url,
                                &status_text,
                                &needs_repaint,
                                if (storage_inst) |*s| s else null,
                                surface.width,
                                surface.height,
                                &focused_input_node,
                                &form_input,
                            );
                            // Dispatch focus/blur events when focused element changes
                            if (focused_input_node != prev_focused_input_node) {
                                if (page.js_rt) |*js_rt| {
                                    if (prev_focused_input_node) |prev_node| {
                                        _ = events.dispatchEvent(js_rt.ctx, prev_node, "blur");
                                        js_rt.executePending();
                                    }
                                    if (focused_input_node) |new_node| {
                                        _ = events.dispatchEvent(js_rt.ctx, new_node, "focus");
                                        js_rt.executePending();
                                    }
                                }
                            }
                            // Update tab with new URL and page title
                            if (current_url) |cu| {
                                tab_mgr.updateActiveUrl(cu);
                                const active_pg_title: ?*PageState = if (tab_mgr.active_index < page_states.items.len) &page_states.items[tab_mgr.active_index] else null;
                                const click_title = if (active_pg_title) |pgt| (if (pgt.doc) |*d| extractTitle(d) else null) else null;
                                tab_mgr.updateActiveTitle(click_title orelse cu);
                                // Record in storage with title
                                if (storage_inst) |*s| {
                                    const is_priv = if (tab_mgr.getActiveTab()) |t| t.is_private else false;
                                    if (!is_priv) s.addHistory(cu, click_title orelse cu);
                                }
                            }
                        }
                        continue;
                    }
                    if (key == nsfb_c.NSFB_KEY_MOUSE_4 or key == nsfb_c.NSFB_KEY_MOUSE_5) {
                        const active_pg: ?*PageState = if (tab_mgr.active_index < page_states.items.len)
                            &page_states.items[tab_mgr.active_index]
                        else
                            null;
                        const total_h: f32 = if (active_pg) |pg| pg.total_height else 0;
                        const ch = @as(f32, @floatFromInt(chrome.contentHeight(surface.height)));
                        var new_scroll = scroll_y;
                        if (key == nsfb_c.NSFB_KEY_MOUSE_4) {
                            new_scroll -= 40;
                        } else {
                            new_scroll += 40;
                        }
                        const max_scroll = @max(total_h - ch, 0);
                        new_scroll = @max(0, @min(new_scroll, max_scroll));
                        if (new_scroll != scroll_y) {
                            scroll_y = new_scroll;
                            needs_repaint = true;
                        }
                        continue;
                    }

                    // XIM (Input Method) processing — try composing first
                    // when any text input is focused.
                    // Skip control keys (backspace, enter, escape, arrows, etc.)
                    // so they work normally even when Mozc is active.
                    if (surface.xim_initialized and !ctrl_held and !alt_held) {
                        // Keys that never go to XIM
                        const is_nav_key = (key == nsfb_c.NSFB_KEY_BACKSPACE or
                            key == nsfb_c.NSFB_KEY_DELETE or
                            key == nsfb_c.NSFB_KEY_TAB or
                            key == nsfb_c.NSFB_KEY_LEFT or
                            key == nsfb_c.NSFB_KEY_RIGHT or
                            key == nsfb_c.NSFB_KEY_UP or
                            key == nsfb_c.NSFB_KEY_DOWN or
                            key == nsfb_c.NSFB_KEY_HOME or
                            key == nsfb_c.NSFB_KEY_END or
                            key == nsfb_c.NSFB_KEY_PAGEUP or
                            key == nsfb_c.NSFB_KEY_PAGEDOWN);
                        // Enter/Escape: only send to XIM when composing (Mozc active)
                        const is_confirm_key = (key == nsfb_c.NSFB_KEY_RETURN or
                            key == nsfb_c.NSFB_KEY_ESCAPE);
                        const is_control_key = is_nav_key or (is_confirm_key and !xim_composing);
                        const any_text_focused = find_bar.visible or focused_input_node != null or url_input.focused;
                        if (any_text_focused and !is_control_key) {
                            const xim_res = surface.processKeyXim(true);
                            switch (xim_res.result) {
                                .text => {
                                    // XIM produced text — composition complete
                                    xim_composing = false;
                                    if (xim_res.text) |composed| {
                                        // Skip control characters (let normal handler deal with them)
                                        const is_control = composed.len > 0 and composed[0] < 0x20;
                                        if (!is_control) {
                                            if (find_bar.visible) {
                                                find_bar.insertText(composed);
                                            } else if (focused_input_node != null) {
                                                form_input.insertText(composed);
                                                std.debug.print("[input] XIM text into form: \"{s}\" total=\"{s}\"\n", .{ composed, form_input.getText() });
                                                // Dispatch "input" event on the focused element
                                                {
                                                    const xim_pg2: ?*PageState = if (tab_mgr.active_index < page_states.items.len) &page_states.items[tab_mgr.active_index] else null;
                                                    if (xim_pg2) |pg| {
                                                        if (pg.js_rt) |*js_rt| {
                                                            _ = events.dispatchEvent(js_rt.ctx, focused_input_node.?, "input");
                                                            js_rt.executePending();
                                                        }
                                                    }
                                                }
                                            } else if (url_input.focused) {
                                                url_input.insertText(composed);
                                            }
                                            needs_repaint = true;
                                            continue;
                                        }
                                    }
                                },
                                .filtered => {
                                    // Key consumed by IME — now composing
                                    xim_composing = true;
                                    continue;
                                },
                                .none => {
                                    // Not handled by XIM — fall through to normal handler
                                },
                            }
                        }
                    }

                    // Find bar key handling (takes priority when visible)
                    if (find_bar.visible) {
                        const find_result = find_bar.handleKey(key, shift_held);
                        switch (find_result) {
                            .close => {
                                find_bar.close();
                                needs_repaint = true;
                            },
                            .search => {
                                const active_pg_fb: ?*PageState = if (tab_mgr.active_index < page_states.items.len)
                                    &page_states.items[tab_mgr.active_index]
                                else
                                    null;
                                if (active_pg_fb) |pg| {
                                    find_bar.performSearch(pg.root_box);
                                }
                                needs_repaint = true;
                            },
                            .next_match => {
                                find_bar.nextMatch();
                                if (find_bar.currentMatchY()) |match_y| {
                                    scroll_y = @max(0, match_y - @as(f32, @floatFromInt(chrome.contentHeight(surface.height))) / 2.0);
                                }
                                needs_repaint = true;
                            },
                            .prev_match => {
                                find_bar.prevMatch();
                                if (find_bar.currentMatchY()) |match_y| {
                                    scroll_y = @max(0, match_y - @as(f32, @floatFromInt(chrome.contentHeight(surface.height))) / 2.0);
                                }
                                needs_repaint = true;
                            },
                            .consumed => {
                                needs_repaint = true;
                            },
                            .ignored => {},
                        }
                        continue;
                    }

                    // Handle focused form input
                    if (focused_input_node != null) {
                        // Dispatch "keydown" event on the focused element
                        {
                            const kd_pg: ?*PageState = if (tab_mgr.active_index < page_states.items.len) &page_states.items[tab_mgr.active_index] else null;
                            if (kd_pg) |pg| {
                                if (pg.js_rt) |*js_rt| {
                                    _ = events.dispatchKeyboardEvent(js_rt.ctx, focused_input_node.?, "keydown", key);
                                    js_rt.executePending();
                                }
                            }
                        }
                        if (key == nsfb_c.NSFB_KEY_TAB) {
                            // Tab: unfocus form input (TODO: focus next input)
                            focused_input_node = null;
                            needs_repaint = true;
                            continue;
                        }
                        const form_result = form_input.handleKey(key, shift_held);
                        switch (form_result) {
                            .submit => {
                                // Enter pressed: submit the form
                                const pg = if (tab_mgr.active_index < page_states.items.len) &page_states.items[tab_mgr.active_index] else continue;
                                const fi_node = focused_input_node.?;
                                const fi_form = findParentForm(fi_node) orelse continue;
                                if (submitForm(allocator, fi_form, fi_node, &form_input, current_url, &loader, &fonts, pg, if (storage_inst) |*s| s else null, surface.width, surface.height)) |nav_url| {
                                    defer allocator.free(nav_url);
                                    url_input.setText(nav_url);
                                    url_input.focused = false;
                                    focused_input_node = null;
                                    status_text = "Loading...";
                                    needs_repaint = true;

                                    // Truncate forward history
                                    if (history_pos + 1 < history.items.len) {
                                        for (history.items[history_pos + 1 ..]) |item| {
                                            allocator.free(item);
                                        }
                                        history.shrinkRetainingCapacity(history_pos + 1);
                                    }
                                    // Add to history
                                    const owned = allocator.alloc(u8, nav_url.len) catch null;
                                    if (owned) |o| {
                                        @memcpy(o, nav_url);
                                        history.append(allocator, o) catch {};
                                        history_pos = history.items.len - 1;
                                    }
                                    if (current_url) |old| allocator.free(old);
                                    current_url = allocator.dupe(u8, nav_url) catch null;
                                    tab_mgr.updateActiveUrl(nav_url);
                                    tab_mgr.updateActiveTitle(nav_url);
                                    if (storage_inst) |*s| {
                                        const is_priv = if (tab_mgr.getActiveTab()) |t| t.is_private else false;
                                        if (!is_priv) s.addHistory(nav_url, nav_url);
                                    }
                                    scroll_y = 0;
                                    scroll_x = 0;
                                    status_text = "Done";
                                } else {
                                    // submitForm returned null (no form found or error)
                                    // Just unfocus
                                    focused_input_node = null;
                                }
                                needs_repaint = true;
                            },
                            .cancel => {
                                focused_input_node = null;
                                needs_repaint = true;
                            },
                            .consumed => {
                                // Dispatch "input" event on the focused element
                                if (focused_input_node) |fi_node_input| {
                                    const input_pg: ?*PageState = if (tab_mgr.active_index < page_states.items.len) &page_states.items[tab_mgr.active_index] else null;
                                    if (input_pg) |pg| {
                                        if (pg.js_rt) |*js_rt| {
                                            _ = events.dispatchEvent(js_rt.ctx, fi_node_input, "input");
                                            js_rt.executePending();
                                        }
                                    }
                                }
                                needs_repaint = true;
                            },
                            .ignored => {},
                        }
                        continue;
                    }

                    if (url_input.focused) {
                        // Route to text input
                        const result = url_input.handleKey(key, shift_held);
                        switch (result) {
                            .submit => {
                                // Clear form focus before navigation
                                focused_input_node = null;
                                // Navigate to URL (with search query detection)
                                const url_text = url_input.getText();
                                if (url_text.len > 0) {
                                    // Determine the actual URL to navigate to
                                    const nav_target = processUrlInput(allocator, url_text) catch continue;
                                    defer allocator.free(nav_target);

                                    // Update the URL bar to show the resolved URL
                                    url_input.setText(nav_target);

                                    const url_z = nav_target;

                                    status_text = "Loading...";
                                    needs_repaint = true;

                                    const pg = if (tab_mgr.active_index < page_states.items.len) &page_states.items[tab_mgr.active_index] else continue;
                                    if (navigateTo(allocator, &loader, url_z, &fonts, pg, if (storage_inst) |*s| s else null, surface.width, surface.height)) {
                                        status_text = "Done";
                                        scroll_y = 0;
                                        scroll_x = 0;
                                        url_input.focused = false;

                                        // Truncate forward history if we navigated from middle
                                        if (history_pos + 1 < history.items.len) {
                                            for (history.items[history_pos + 1 ..]) |item| {
                                                allocator.free(item);
                                            }
                                            history.shrinkRetainingCapacity(history_pos + 1);
                                        }

                                        // Add to history (use nav_target since url_text may be stale)
                                        const owned = allocator.dupe(u8, nav_target) catch null;
                                        if (owned) |o| {
                                            history.append(allocator, o) catch {};
                                            history_pos = history.items.len - 1;
                                        }
                                        if (current_url) |old| allocator.free(old);
                                        current_url = allocator.dupe(u8, nav_target) catch null;

                                        // Update tab URL and extract page title
                                        tab_mgr.updateActiveUrl(nav_target);
                                        const page_title = if (pg.doc) |*d| extractTitle(d) else null;
                                        tab_mgr.updateActiveTitle(page_title orelse nav_target);

                                        // Record in storage (skip for private tabs)
                                        if (storage_inst) |*s| {
                                            const is_priv = if (tab_mgr.getActiveTab()) |t| t.is_private else false;
                                            if (!is_priv) {
                                                s.addHistory(nav_target, page_title orelse nav_target);
                                            }
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
                            const active_pg2: ?*PageState = if (tab_mgr.active_index < page_states.items.len)
                                &page_states.items[tab_mgr.active_index]
                            else
                                null;
                            const total_h2: f32 = if (active_pg2) |pg| pg.total_height else 0;
                            const total_w2: f32 = if (active_pg2) |pg| pg.total_width else 0;
                            const ch = @as(f32, @floatFromInt(chrome.contentHeight(surface.height)));
                            const cw = @as(f32, @floatFromInt(surface.width));
                            var new_scroll = scroll_y;
                            var new_scroll_x = scroll_x;

                            if (key == nsfb_c.NSFB_KEY_UP) {
                                new_scroll -= 40;
                            } else if (key == nsfb_c.NSFB_KEY_DOWN) {
                                new_scroll += 40;
                            } else if (key == nsfb_c.NSFB_KEY_LEFT) {
                                new_scroll_x -= 40;
                            } else if (key == nsfb_c.NSFB_KEY_RIGHT) {
                                new_scroll_x += 40;
                            } else if (key == nsfb_c.NSFB_KEY_PAGEUP) {
                                new_scroll -= ch;
                            } else if (key == nsfb_c.NSFB_KEY_PAGEDOWN) {
                                new_scroll += ch;
                            } else if (key == nsfb_c.NSFB_KEY_HOME) {
                                new_scroll = 0;
                                new_scroll_x = 0;
                            } else if (key == nsfb_c.NSFB_KEY_END) {
                                if (total_h2 > ch) {
                                    new_scroll = total_h2 - ch;
                                }
                            } else if (key == nsfb_c.NSFB_KEY_ESCAPE) {
                                // Do nothing in content view; Ctrl+Q to quit
                                continue;
                            }

                            // Clamp vertical
                            const max_scroll = @max(total_h2 - ch, 0);
                            new_scroll = @max(0, @min(new_scroll, max_scroll));
                            if (new_scroll != scroll_y) {
                                scroll_y = new_scroll;
                                needs_repaint = true;
                            }

                            // Clamp horizontal (only scroll if content wider than viewport)
                            const max_scroll_x = @max(total_w2 - cw, 0);
                            new_scroll_x = @max(0, @min(new_scroll_x, max_scroll_x));
                            if (new_scroll_x != scroll_x) {
                                scroll_x = new_scroll_x;
                                needs_repaint = true;
                            }
                        }
                    }
                },

                nsfb_c.NSFB_EVENT_KEY_UP => {
                    const key = event.value.keycode;

                    // Dispatch "keyup" event on the focused form element
                    if (focused_input_node) |ku_node| {
                        const ku_pg: ?*PageState = if (tab_mgr.active_index < page_states.items.len) &page_states.items[tab_mgr.active_index] else null;
                        if (ku_pg) |pg| {
                            if (pg.js_rt) |*js_rt| {
                                _ = events.dispatchKeyboardEvent(js_rt.ctx, ku_node, "keyup", key);
                                js_rt.executePending();
                            }
                        }
                    }

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

                    // Update cursor shape based on what's under the mouse
                    if (mouse_y >= chrome.content_y and mouse_y < surface.height - chrome.status_bar_height) {
                        const layout_x = @as(f32, @floatFromInt(mouse_x)) + scroll_x;
                        const layout_y = @as(f32, @floatFromInt(mouse_y - chrome.content_y)) + scroll_y;
                        const pg = if (tab_mgr.active_index < page_states.items.len) &page_states.items[tab_mgr.active_index] else null;
                        if (pg) |p| {
                            if (p.root_box) |root| {
                                const link = painter_mod.hitTestLink(root, layout_x, layout_y);
                                if (link != null) {
                                    surface.setCursor(.pointer);
                                } else {
                                    // Check for form elements
                                    const hit = painter_mod.hitTestNode(root, layout_x, layout_y);
                                    var cursor_set = false;
                                    if (hit) |node_ptr| {
                                        const fnode = findFormElement(@ptrCast(@alignCast(node_ptr)));
                                        if (fnode) |fn_node| {
                                            const fdn = DomNode{ .lxb_node = fn_node };
                                            const ftag = fdn.tagName() orelse "";
                                            if (std.mem.eql(u8, ftag, "input")) {
                                                const itype = fdn.getAttribute("type") orelse "text";
                                                if (std.mem.eql(u8, itype, "submit") or
                                                    std.mem.eql(u8, itype, "button") or
                                                    std.mem.eql(u8, itype, "reset"))
                                                {
                                                    surface.setCursor(.pointer);
                                                } else {
                                                    surface.setCursor(.text);
                                                }
                                                cursor_set = true;
                                            } else if (std.mem.eql(u8, ftag, "button")) {
                                                surface.setCursor(.pointer);
                                                cursor_set = true;
                                            }
                                        }
                                    }
                                    if (!cursor_set) {
                                        surface.setCursor(.arrow);
                                    }
                                }
                            }
                        }
                    } else if (mouse_y < chrome.url_bar_height) {
                        surface.setCursor(.text);
                    } else {
                        surface.setCursor(.arrow);
                    }
                },

                else => {},
            }
        }
    }

    // Save session on exit
    if (storage_inst) |*s| {
        if (serializeSession(allocator, &tab_mgr)) |json| {
            defer allocator.free(json);
            s.saveSession(json);
            std.debug.print("[Session] Saved {d} bytes\n", .{json.len});
        }
    }

    std.debug.print("Bye!\n", .{});
}

/// Find the layout Box that corresponds to a given DOM node pointer.
fn findBoxForNode(box: *const Box, target_node: *lxb.lxb_dom_node_t) ?*const Box {
    if (box.dom_node) |dn| {
        if (dn.lxb_node == target_node) return box;
    }
    for (box.children.items) |child| {
        if (findBoxForNode(child, target_node)) |found| return found;
    }
    return null;
}

/// Paint the focused form input: highlight border + render typed text with cursor.
fn paintFocusedInput(
    root_box: *const Box,
    surface: *Surface,
    fonts: *painter_mod.FontCache,
    focused_node: *lxb.lxb_dom_node_t,
    form_input_ptr: *TextInput,
    scroll_y: f32,
    scroll_x: f32,
    clip_top: i32,
    clip_bottom: i32,
) void {
    const input_box = findBoxForNode(root_box, focused_node) orelse {
        std.debug.print("[paint] Cannot find box for focused textarea node\n", .{});
        return;
    };
    const pbox = input_box.paddingBox();
    const sx: i32 = @as(i32, @intFromFloat(pbox.x)) - @as(i32, @intFromFloat(scroll_x));
    const sy: i32 = @intFromFloat(pbox.y - scroll_y);
    const sw: i32 = @intFromFloat(@max(pbox.width, 0));
    const sh: i32 = @intFromFloat(@max(pbox.height, 0));

    // Skip if outside clip region
    if (sy + sh < clip_top or sy > clip_bottom) return;

    // Draw focus border (blue highlight #89b4fa)
    const focus_color = Surface.argbToColour(0xFF89b4fa);
    // Top
    surface.fillRect(sx - 1, sy - 1, sw + 2, 2, focus_color);
    // Bottom
    surface.fillRect(sx - 1, sy + sh - 1, sw + 2, 2, focus_color);
    // Left
    surface.fillRect(sx - 1, sy - 1, 2, sh + 2, focus_color);
    // Right
    surface.fillRect(sx + sw - 1, sy - 1, 2, sh + 2, focus_color);

    // Paint input background to clear old text
    const bg_color = Surface.argbToColour(input_box.style.background_color);
    const content_x: i32 = @intFromFloat(input_box.content.x - scroll_x);
    const content_y: i32 = @intFromFloat(input_box.content.y - scroll_y);
    const content_w: i32 = @intFromFloat(@max(input_box.content.width, 0));
    const content_h: i32 = @intFromFloat(@max(input_box.content.height, 0));
    surface.fillRect(content_x, content_y, content_w, content_h, bg_color);

    // Render typed text
    const size_px: u32 = @intFromFloat(input_box.style.font_size_px);
    const tr = fonts.getRenderer(size_px) orelse return;
    const text = form_input_ptr.getText();
    const text_color = Surface.argbToColour(0xFFcdd6f4); // catppuccin text
    const m = tr.measure(if (text.len > 0) text else " ");
    const text_y = content_y + @divTrunc(content_h - m.height, 2) + m.ascent;

    const BlitCtx = struct {
        surface: *Surface,
        colour: u32,
        clip_top: i32,
        clip_bottom: i32,
        offset_x: i32,
    };
    const blit_fn = struct {
        fn f(ctx: BlitCtx, glyph: GlyphBitmap) void {
            const gy_bottom = glyph.y + @as(i32, @intCast(glyph.height));
            if (gy_bottom <= ctx.clip_top or glyph.y >= ctx.clip_bottom) return;
            ctx.surface.blitGlyph8(
                glyph.x + ctx.offset_x,
                glyph.y,
                @intCast(glyph.width),
                @intCast(glyph.height),
                glyph.buffer,
                glyph.pitch,
                ctx.colour,
            );
        }
    }.f;

    if (text.len > 0) {
        tr.renderGlyphs(
            text,
            content_x,
            text_y,
            BlitCtx,
            .{ .surface = surface, .colour = text_color, .clip_top = clip_top, .clip_bottom = clip_bottom, .offset_x = 0 },
            blit_fn,
        );
    }

    // Draw cursor
    const cursor_text = if (form_input_ptr.cursor > 0 and form_input_ptr.cursor <= text.len)
        text[0..form_input_ptr.cursor]
    else if (form_input_ptr.cursor == 0)
        ""
    else
        text;
    const cursor_m = if (cursor_text.len > 0) tr.measure(cursor_text) else tr.measure("");
    const cursor_x = content_x + cursor_m.width;
    const cursor_color = Surface.argbToColour(0xFFcdd6f4);
    surface.fillRect(cursor_x, content_y + 2, 1, content_h - 4, cursor_color);
}

fn handleClick(
    allocator: std.mem.Allocator,
    mx: i32,
    my: i32,
    url_input: *TextInput,
    scroll_y: *f32,
    scroll_x: *f32,
    page: *PageState,
    fonts: *painter_mod.FontCache,
    loader: *Loader,
    history: *std.ArrayListUnmanaged([]u8),
    history_pos: *usize,
    current_url: *?[]u8,
    status_text: *[]const u8,
    needs_repaint: *bool,
    storage: ?*Storage,
    win_w: i32,
    win_h: i32,
    focused_input_node: *?*lxb.lxb_dom_node_t,
    form_input: *TextInput,
) void {
    // Click in URL bar?
    if (my < chrome.url_bar_height) {
        url_input.focused = true;
        focused_input_node.* = null; // unfocus form input
        needs_repaint.* = true;
        return;
    }

    // Click in status bar? (ignore)
    if (my >= win_h - chrome.status_bar_height) return;

    // Click in content area — unfocus URL bar
    url_input.focused = false;

    // Hit test for links and JS events
    if (page.root_box) |root_box| {
        // Convert screen coords to layout coords
        const layout_x: f32 = @as(f32, @floatFromInt(mx)) + scroll_x.*;
        const layout_y: f32 = @as(f32, @floatFromInt(my - chrome.content_y)) + scroll_y.*;

        std.debug.print("[click] screen=({d},{d}) layout=({d:.0},{d:.0}) scroll=({d:.0},{d:.0}) content_y={d}\n", .{ mx, my, layout_x, layout_y, scroll_x.*, scroll_y.*, chrome.content_y });

        // Dispatch click event to JavaScript
        if (page.js_rt) |*js_rt| {
            if (painter_mod.hitTestNode(root_box, layout_x, layout_y)) |node_ptr| {
                const node: *lxb.lxb_dom_node_t = @ptrCast(@alignCast(node_ptr));
                _ = events.dispatchEvent(js_rt.ctx, node, "click");
                js_rt.executePending();
                // Re-style and re-layout if DOM was mutated by the event handler
                if (dom_api.dom_dirty) {
                    dom_api.dom_dirty = false;
                    restylePage(page, allocator, fonts, win_w, win_h);
                    needs_repaint.* = true;
                }
            }
        }

        // Re-read root_box in case restylePage replaced it
        const current_root = page.root_box orelse return;
        const hit_link = painter_mod.hitTestLink(current_root, layout_x, layout_y);
        const hit_node = painter_mod.hitTestNode(current_root, layout_x, layout_y);
        if (hit_node) |np| {
            const hn: *lxb.lxb_dom_node_t = @ptrCast(@alignCast(np));
            const hdn = DomNode{ .lxb_node = hn };
            std.debug.print("[click] hitNode tag={s} link={s}\n", .{ hdn.tagName() orelse "?", if (hit_link) |l| l else "(none)" });
        } else {
            std.debug.print("[click] hitNode=null link={s}\n", .{if (hit_link) |l| l else "(none)"});
        }

        // Check for form element clicks before link navigation
        if (hit_node) |node_ptr| {
            const node: *lxb.lxb_dom_node_t = @ptrCast(@alignCast(node_ptr));
            const dom_node = DomNode{ .lxb_node = node };

            // Walk up/down to find the actual form element
            const form_node = findFormElement(node);
            if (form_node) |fn_| {
                const fdn = DomNode{ .lxb_node = fn_ };
                std.debug.print("[form] Found form element: {s}\n", .{fdn.tagName() orelse "?"});
            } else {
                std.debug.print("[form] No form element found near {s}\n", .{dom_node.tagName() orelse "?"});
            }

            if (form_node) |fnode| {
                const fdom = DomNode{ .lxb_node = fnode };
                const ftag = fdom.tagName() orelse "";

                if (std.mem.eql(u8, ftag, "input")) {
                    const input_type = fdom.getAttribute("type") orelse "text";
                    const is_text_input = std.mem.eql(u8, input_type, "text") or
                        std.mem.eql(u8, input_type, "search") or
                        std.mem.eql(u8, input_type, "password") or
                        std.mem.eql(u8, input_type, "email") or
                        std.mem.eql(u8, input_type, "url") or
                        std.mem.eql(u8, input_type, "tel") or
                        std.mem.eql(u8, input_type, "number");
                    const is_button_input = std.mem.eql(u8, input_type, "submit") or
                        std.mem.eql(u8, input_type, "button") or
                        std.mem.eql(u8, input_type, "reset");

                    if (is_text_input) {
                        // Focus this input
                        focused_input_node.* = fnode;
                        const current_value = fdom.getAttribute("value") orelse "";
                        form_input.setText(current_value);
                        std.debug.print("[form] Focused input type={s} value=\"{s}\"\n", .{ input_type, current_value });
                        needs_repaint.* = true;
                        return;
                    } else if (is_button_input) {
                        // Submit button clicked — submit the form
                        std.debug.print("[form] Submit button clicked\n", .{});
                        const btn_form = findParentForm(fnode) orelse return;
                        if (submitForm(allocator, btn_form, focused_input_node.*, form_input, current_url.*, loader, fonts, page, storage, win_w, win_h)) |nav_url| {
                            defer allocator.free(nav_url);
                            url_input.setText(nav_url);
                            url_input.focused = false;
                            focused_input_node.* = null;
                            status_text.* = "Done";
                            scroll_y.* = 0;
                            scroll_x.* = 0;

                            // Truncate forward history
                            if (history_pos.* + 1 < history.items.len) {
                                for (history.items[history_pos.* + 1 ..]) |item| {
                                    allocator.free(item);
                                }
                                history.shrinkRetainingCapacity(history_pos.* + 1);
                            }
                            const owned = allocator.alloc(u8, nav_url.len) catch return;
                            @memcpy(owned, nav_url);
                            history.append(allocator, owned) catch {
                                allocator.free(owned);
                                return;
                            };
                            history_pos.* = history.items.len - 1;
                            if (current_url.*) |old| allocator.free(old);
                            current_url.* = allocator.dupe(u8, nav_url) catch null;
                        }
                        needs_repaint.* = true;
                        return;
                    }
                } else if (std.mem.eql(u8, ftag, "textarea")) {
                    // <textarea> — focus for text input (Google search uses textarea)
                    focused_input_node.* = fnode;
                    const current_value = fdom.getAttribute("value") orelse "";
                    form_input.setText(current_value);
                    std.debug.print("[form] Focused textarea\n", .{});
                    needs_repaint.* = true;
                    return;
                } else if (std.mem.eql(u8, ftag, "button")) {
                    // <button> click — submit the form
                    std.debug.print("[form] <button> clicked\n", .{});
                    const button_form = findParentForm(fnode) orelse return;
                    if (submitForm(allocator, button_form, focused_input_node.*, form_input, current_url.*, loader, fonts, page, storage, win_w, win_h)) |nav_url| {
                        defer allocator.free(nav_url);
                        url_input.setText(nav_url);
                        url_input.focused = false;
                        focused_input_node.* = null;
                        status_text.* = "Done";
                        scroll_y.* = 0;
                        scroll_x.* = 0;

                        if (history_pos.* + 1 < history.items.len) {
                            for (history.items[history_pos.* + 1 ..]) |item| {
                                allocator.free(item);
                            }
                            history.shrinkRetainingCapacity(history_pos.* + 1);
                        }
                        const owned = allocator.alloc(u8, nav_url.len) catch return;
                        @memcpy(owned, nav_url);
                        history.append(allocator, owned) catch {
                            allocator.free(owned);
                            return;
                        };
                        history_pos.* = history.items.len - 1;
                        if (current_url.*) |old| allocator.free(old);
                        current_url.* = allocator.dupe(u8, nav_url) catch null;
                    }
                    needs_repaint.* = true;
                    return;
                }
            }

            // If clicked on something that's not a form element, unfocus
            // dom_node used in debug print above
            focused_input_node.* = null;
        } else {
            focused_input_node.* = null;
        }

        if (hit_link) |link_href| {
            // Resolve URL
            const base = if (current_url.*) |u| u else "";
            const resolved = resolveUrl(allocator, base, link_href) catch return;
            defer allocator.free(resolved);

            std.debug.print("Navigating to: {s}\n", .{resolved});

            url_input.setText(resolved);
            status_text.* = "Loading...";
            needs_repaint.* = true;

            if (navigateTo(allocator, loader, resolved, fonts, page, storage, win_w, win_h)) {
                status_text.* = "Done";
                scroll_y.* = 0;
                scroll_x.* = 0;

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

/// Walk up the DOM tree to find a form-relevant element (input, button, textarea, select).
/// This handles clicks on text children inside form elements.
fn findFormElement(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t {
    // First check: is this node itself a form element?
    if (isFormElement(node)) return node;

    // Search UP (ancestors) — maybe we clicked on text inside a button
    var current: ?*lxb.lxb_dom_node_t = node.parent;
    var depth: u32 = 0;
    while (current) |n| : (depth += 1) {
        if (depth > 5) break;
        if (isFormElement(n)) return n;
        current = n.parent;
    }

    // Search DOWN (descendants) — maybe we clicked on a div containing an input
    if (findFormElementInChildren(node, 0)) |found| return found;

    return null;
}

fn isFormElement(node: *lxb.lxb_dom_node_t) bool {
    if (node.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return false;
    const dn = DomNode{ .lxb_node = node };
    const tag = dn.tagName() orelse return false;
    return std.mem.eql(u8, tag, "input") or
        std.mem.eql(u8, tag, "button") or
        std.mem.eql(u8, tag, "textarea") or
        std.mem.eql(u8, tag, "select");
}

fn findFormElementInChildren(node: *lxb.lxb_dom_node_t, depth: u32) ?*lxb.lxb_dom_node_t {
    if (depth > 20) return null;
    // First pass: look for text inputs (input[text/search/...], textarea) — preferred
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |c| {
        if (isTextFormElement(c)) return c;
        child = c.next;
    }
    // Recurse for text inputs
    child = node.first_child;
    while (child) |c| {
        if (findFormElementInChildren(c, depth + 1)) |found| {
            if (isTextFormElement(found)) return found;
        }
        child = c.next;
    }
    // Second pass: any form element
    child = node.first_child;
    while (child) |c| {
        if (isFormElement(c)) return c;
        if (findFormElementInChildren(c, depth + 1)) |found| return found;
        child = c.next;
    }
    return null;
}

fn isTextFormElement(node: *lxb.lxb_dom_node_t) bool {
    if (node.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return false;
    const dn = DomNode{ .lxb_node = node };
    // Skip elements with style="display:none" (like Google's hidden textarea.csi)
    if (dn.getAttribute("style")) |inline_style| {
        if (std.mem.indexOf(u8, inline_style, "display:none") != null or
            std.mem.indexOf(u8, inline_style, "display: none") != null)
            return false;
    }
    const tag = dn.tagName() orelse return false;
    if (std.mem.eql(u8, tag, "textarea")) return true;
    if (std.mem.eql(u8, tag, "input")) {
        const it = dn.getAttribute("type") orelse "text";
        return std.mem.eql(u8, it, "text") or std.mem.eql(u8, it, "search") or
            std.mem.eql(u8, it, "password") or std.mem.eql(u8, it, "email") or
            std.mem.eql(u8, it, "url") or std.mem.eql(u8, it, "tel") or
            std.mem.eql(u8, it, "number");
    }
    return false;
}

/// Find the parent <form> element of a given DOM node.
fn findParentForm(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t {
    var current: ?*lxb.lxb_dom_node_t = node.parent;
    var depth: u32 = 0;
    while (current) |n| : (depth += 1) {
        if (depth > 50) break;
        if (n.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            const dn = DomNode{ .lxb_node = n };
            if (dn.tagName()) |tag| {
                if (std.mem.eql(u8, tag, "form")) return n;
            }
        }
        current = n.parent;
    }
    return null;
}

/// Extract a query parameter value from a query string like "q=test&foo=bar"
fn extractQueryParam(query_string: []const u8, param_name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < query_string.len) {
        // Find next parameter
        const eq = std.mem.indexOfScalarPos(u8, query_string, pos, '=') orelse break;
        const name = query_string[pos..eq];
        const amp = std.mem.indexOfScalarPos(u8, query_string, eq + 1, '&') orelse query_string.len;
        if (std.mem.eql(u8, name, param_name)) {
            return query_string[eq + 1 .. amp];
        }
        pos = if (amp < query_string.len) amp + 1 else query_string.len;
    }
    return null;
}

/// URL-encode a string for form submission query parameters.
fn urlEncode(allocator: std.mem.Allocator, input_str: []const u8) ?[]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (input_str) |ch| {
        if (ch == ' ') {
            buf.append(allocator, '+') catch {
                buf.deinit(allocator);
                return null;
            };
        } else if ((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~')
        {
            buf.append(allocator, ch) catch {
                buf.deinit(allocator);
                return null;
            };
        } else {
            buf.append(allocator, '%') catch {
                buf.deinit(allocator);
                return null;
            };
            const hex = "0123456789ABCDEF";
            buf.append(allocator, hex[ch >> 4]) catch {
                buf.deinit(allocator);
                return null;
            };
            buf.append(allocator, hex[ch & 0x0F]) catch {
                buf.deinit(allocator);
                return null;
            };
        }
    }
    return buf.toOwnedSlice(allocator) catch null;
}

/// Collect all form input name=value pairs by walking descendants of a form element.
fn collectFormData(allocator: std.mem.Allocator, form_node: *lxb.lxb_dom_node_t, focused_node: ?*lxb.lxb_dom_node_t, form_text: *TextInput) ?[]u8 {
    var pairs: std.ArrayListUnmanaged(u8) = .empty;
    var first = true;
    collectFormDataRecurse(allocator, form_node, focused_node, form_text, &pairs, &first);
    return pairs.toOwnedSlice(allocator) catch {
        pairs.deinit(allocator);
        return null;
    };
}

fn collectFormDataRecurse(
    allocator: std.mem.Allocator,
    node: *lxb.lxb_dom_node_t,
    focused_node: ?*lxb.lxb_dom_node_t,
    form_text: *TextInput,
    pairs: *std.ArrayListUnmanaged(u8),
    first: *bool,
) void {
    if (node.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
        const dn = DomNode{ .lxb_node = node };
        if (dn.tagName()) |tag| {
            if (std.mem.eql(u8, tag, "textarea")) {
                // Textarea: collect name and value (use form_text if focused)
                if (dn.getAttribute("name")) |name| {
                    const value = if (focused_node != null and node == focused_node.?)
                        form_text.getText()
                    else
                        (dn.getAttribute("value") orelse "");

                    const enc_name = urlEncode(allocator, name) orelse return;
                    defer allocator.free(enc_name);
                    const enc_value = urlEncode(allocator, value) orelse return;
                    defer allocator.free(enc_value);

                    if (!first.*) {
                        pairs.append(allocator, '&') catch return;
                    }
                    pairs.appendSlice(allocator, enc_name) catch return;
                    pairs.append(allocator, '=') catch return;
                    pairs.appendSlice(allocator, enc_value) catch return;
                    first.* = false;
                }
            } else if (std.mem.eql(u8, tag, "input")) {
                const input_type = dn.getAttribute("type") orelse "text";
                // Skip submit/button/hidden/reset for data collection
                // Actually include hidden inputs, skip submit/button/reset
                if (!std.mem.eql(u8, input_type, "submit") and
                    !std.mem.eql(u8, input_type, "button") and
                    !std.mem.eql(u8, input_type, "reset") and
                    !std.mem.eql(u8, input_type, "image"))
                {
                    if (dn.getAttribute("name")) |name| {
                        // Get value: use form_text if this is the focused node, else DOM attribute
                        const value = if (focused_node != null and node == focused_node.?)
                            form_text.getText()
                        else
                            (dn.getAttribute("value") orelse "");

                        const enc_name = urlEncode(allocator, name) orelse return;
                        defer allocator.free(enc_name);
                        const enc_value = urlEncode(allocator, value) orelse return;
                        defer allocator.free(enc_value);

                        if (!first.*) {
                            pairs.append(allocator, '&') catch return;
                        }
                        pairs.appendSlice(allocator, enc_name) catch return;
                        pairs.append(allocator, '=') catch return;
                        pairs.appendSlice(allocator, enc_value) catch return;
                        first.* = false;
                    }
                }
            }
        }
    }

    // Recurse into children
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        collectFormDataRecurse(allocator, ch, focused_node, form_text, pairs, first);
        child = ch.next;
    }
}

/// Submit a form: find parent <form>, collect data, build URL, navigate.
/// Returns the navigation URL (caller must free) or null on failure.
fn submitForm(
    allocator: std.mem.Allocator,
    form_node: *lxb.lxb_dom_node_t,
    focused_node: ?*lxb.lxb_dom_node_t,
    form_text: *TextInput,
    current_url: ?[]u8,
    loader: *Loader,
    fonts: *painter_mod.FontCache,
    page: *PageState,
    storage: ?*Storage,
    win_w: i32,
    win_h: i32,
) ?[]u8 {
    // Dispatch "submit" event on the form element (before actual submission)
    if (page.js_rt) |*js_rt| {
        const allow = events.dispatchEvent(js_rt.ctx, form_node, "submit");
        js_rt.executePending();
        if (!allow) {
            // preventDefault was called — cancel form submission
            return null;
        }
    }

    const form_dn = DomNode{ .lxb_node = form_node };

    // Get action URL (default to current page)
    const action = form_dn.getAttribute("action") orelse "";
    const method = form_dn.getAttribute("method") orelse "get";
    _ = method; // We only support GET for now

    std.debug.print("[form] Submitting form action=\"{s}\"\n", .{action});

    // Collect form data
    const query_string = collectFormData(allocator, form_node, focused_node, form_text) orelse return null;
    defer allocator.free(query_string);

    std.debug.print("[form] Query string: {s}\n", .{query_string});

    // Build full URL: resolve action against current URL, append query string
    const base = if (current_url) |u| u else "";
    const resolved_action = resolveUrl(allocator, base, action) catch return null;
    defer allocator.free(resolved_action);

    // Build final URL with query string
    var final_url_buf: std.ArrayListUnmanaged(u8) = .empty;
    final_url_buf.appendSlice(allocator, resolved_action) catch return null;

    if (query_string.len > 0) {
        // Check if action already has a '?'
        if (std.mem.indexOf(u8, resolved_action, "?") != null) {
            final_url_buf.append(allocator, '&') catch {
                final_url_buf.deinit(allocator);
                return null;
            };
        } else {
            final_url_buf.append(allocator, '?') catch {
                final_url_buf.deinit(allocator);
                return null;
            };
        }
        final_url_buf.appendSlice(allocator, query_string) catch {
            final_url_buf.deinit(allocator);
            return null;
        };
    }

    const final_url = final_url_buf.toOwnedSlice(allocator) catch {
        final_url_buf.deinit(allocator);
        return null;
    };
    // We need a sentinel-terminated copy for navigation
    const url_z = allocator.allocSentinel(u8, final_url.len, 0) catch {
        allocator.free(final_url);
        return null;
    };
    @memcpy(url_z, final_url);

    std.debug.print("[form] Navigating to: {s}\n", .{final_url});

    if (navigateTo(allocator, loader, url_z, fonts, page, storage, win_w, win_h)) {
        allocator.free(url_z);
        return final_url;
    } else {
        allocator.free(url_z);
        allocator.free(final_url);
        return null;
    }
}

// Re-export modules so they are reachable from the build
pub const dom = struct {
    pub const node = @import("dom/node.zig");
    pub const tree = @import("dom/tree.zig");
};

pub const style = struct {
    pub const computed = @import("css/computed.zig");
    pub const cascade = @import("css/cascade.zig");
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
    pub const tabs = @import("ui/tabs.zig");
};

pub const features = struct {
    pub const storage = @import("features/storage.zig");
    pub const config_mod = @import("features/config.zig");
    pub const internal_pgs = @import("features/internal_pages.zig");
    pub const search_mod = @import("features/search.zig");
    pub const adblock = @import("features/adblock.zig");
    pub const userscripts = @import("features/userscript.zig");
};

pub const js = struct {
    pub const runtime = @import("js/runtime.zig");
    pub const web_apis = @import("js/web_api.zig");
    pub const dom_apis = @import("js/dom_api.zig");
    pub const event_system = @import("js/events.zig");
};
