const std = @import("std");
const env = @import("env.zig");
const Surface = @import("paint/surface.zig").Surface;
const TextRenderer = @import("paint/text.zig").TextRenderer;
const GlyphBitmap = @import("paint/text.zig").GlyphBitmap;
const Document = @import("dom/tree.zig").Document;
const cascade_mod = @import("css/cascade.zig");
const anim_mod = @import("css/animation.zig");
const ast_mod = @import("css/ast.zig");
const ComputedStyle = @import("css/computed.zig").ComputedStyle;
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
const ImageFetcher = @import("net/image_fetcher.zig").ImageFetcher;

const default_window_w = chrome.default_window_w;
const default_window_h = chrome.default_window_h;

// Default background colour (Catppuccin Mocha base)
const default_bg = 0xFF1e1e2e;

// Font paths
const font_cjk = "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc";
const font_fallback = "/usr/share/fonts/TTF/DejaVuSans.ttf";
const font_serif = "/usr/share/fonts/TTF/DejaVuSerif.ttf";
const font_mono = "/usr/share/fonts/TTF/DejaVuSansMono.ttf";

const hit_test_mod = @import("hit_test.zig");
const dom_test = @import("test_dom_style.zig");
const JsRuntime = @import("js/runtime.zig").JsRuntime;
const quickjs = @import("bindings/quickjs.zig");
const web_api = @import("js/web_api.zig");
const dom_api = @import("js/dom_api.zig");
const kotori = @import("kotori");
const kotori_dom = @import("kotori_dom");
const kotori_runtime = @import("kotori_runtime");
const dom_selector = @import("js/dom_selector.zig");
const events = @import("js/events.zig");
const WebDriverServer = @import("net/webdriver.zig").WebDriverServer;
const CommandSlot = @import("net/webdriver.zig").CommandSlot;
const WindowManager = @import("js/window_manager.zig").WindowManager;
const DomNode = @import("dom/node.zig").DomNode;
const lxb = @import("bindings/lexbor.zig").c;

// Extracted modules
const script_executor = @import("core/script_executor.zig");
const form_handler = @import("core/form_handler.zig");
const session = @import("core/session.zig");
const url_utils = @import("core/url_utils.zig");
const http_status = @import("net/http_status.zig");

// ── Sync restyle for getComputedStyle ─────────────────────────────
// When JS calls getComputedStyle() after DOM mutations, we need fresh styles.
// These globals store the current page context for the synchronous restyle callback.
var g_restyle_page: ?*PageState = null;
var g_restyle_allocator: std.mem.Allocator = undefined;
var g_restyle_fonts: ?*painter_mod.FontCache = null;
var g_restyle_width: i32 = 800;
var g_restyle_height: i32 = 600;

fn syncRestyle() void {
    if (g_restyle_page) |page| {
        if (g_restyle_fonts) |fonts| {
            restylePage(page, g_restyle_allocator, fonts, g_restyle_width, g_restyle_height);
        }
    }
}

/// Bridge: kotori.getComputedStyle → flush pending restyle/layout.
/// Matches `windowGetComputedStyle`'s call to `dom_api.flushStylesIfDirty`.
fn kotoriFlushStylesIfDirty() void {
    dom_api.flushStylesIfDirty();
}

/// Bridge: kotori DOM mutation → set the shared `dom_api` cascade dirty
/// flag (bumps dom_version, arms MutationObserver pending, and flags the
/// cascade so the next `flushStylesIfDirty` triggers a sync restyle).
///
/// kotori_dom keeps its own local `dom_dirty` for event-loop bookkeeping;
/// this bridge wires the *second* flag that `flushStylesIfDirty` actually
/// reads. Without it, `el.style.color = 'black'` + `getComputedStyle(el)`
/// returned the stale parent-cascaded color under kotori (Wave 10 Track C).
fn kotoriMarkDomDirty() void {
    dom_api.setDomDirty();
}

/// Bridge: kotori DOM style setters → CSSOM §6.7.2 invalid-value
/// rejection via `dom_style.isValidCssValue`. Called before writing any
/// `el.style.X = Y`, `el.style[X] = Y`, or `el.style.setProperty(X, Y)`.
/// Returns true to allow the write, false to silently ignore.
fn kotoriValidateCssValue(prop: []const u8, val: []const u8) bool {
    const dom_style_mod = @import("js/dom_style.zig");
    return dom_style_mod.isValidCssValue(prop, val);
}

fn kotoriElementMatches(node_opaque: *anyopaque, selector: []const u8) bool {
    const node: *lxb.lxb_dom_node_t = @ptrCast(@alignCast(node_opaque));
    return dom_selector.elementMatchesSelector(node, selector);
}

/// Bridge: kotori.getComputedStyle → resolve the CSSOM §6.5 resolved value
/// for `prop` on `node`. Serializes into `buf` and returns the slice, or
/// `null` if the property is not supported by the shared serializer (caller
/// falls back to inline-style attribute lookup).
extern fn lxb_dom_element_get_attribute(element: *lxb.lxb_dom_element_t, qn: [*]const u8, qn_len: usize, value_len: *usize) ?[*]const u8;

fn kotoriResolveComputedValue(
    node_opaque: *anyopaque,
    prop: []const u8,
    buf: []u8,
) ?[]const u8 {
    const computed_slice = @import("css/cssom/computed_slice.zig");
    const dom_style_mod = @import("js/dom_style.zig");
    const node: *lxb.lxb_dom_node_t = @ptrCast(@alignCast(node_opaque));

    // Try cascade-resolved value first.
    if (dom_api.g_styles) |styles_map| {
        if (styles_map.get(@intFromPtr(node))) |computed| {
            const box_opt = if (dom_api.g_root_box) |root|
                dom_api.findBoxForNode(root, node)
            else
                null;
            if (computed_slice.computedStyleToSlice(&computed, prop, box_opt, buf)) |slice| {
                return slice;
            }
        }
    }

    // For color properties with a color-mix() inline value, serialize it
    // according to CSS Color 5 §3.2 specified-value rules (normalize percentages,
    // omit default "shorter hue" method). This covers WPT getPropertyValue tests
    // that run without a full cascade (disconnected elements / no layout).
    if (dom_style_mod.isColorProperty(prop) and
        node.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT)
    {
        const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
        var attr_len: usize = 0;
        if (lxb_dom_element_get_attribute(elem, "style", 5, &attr_len)) |style_ptr| {
            const style_str = style_ptr[0..attr_len];
            if (dom_style_mod.getStyleProperty(style_str, prop)) |raw_val| {
                if (raw_val.len >= 10 and
                    (raw_val[0] == 'c' or raw_val[0] == 'C') and
                    std.ascii.startsWithIgnoreCase(raw_val, "color-mix("))
                {
                    if (dom_style_mod.serializeColorMixToBuf(raw_val, buf)) |serialized| {
                        return serialized;
                    }
                }
            }
        }
    }

    return null;
}

/// After `tab_mgr` switches the active tab, restore scroll/URL bar and lazy-load an empty page if needed.
fn applyActiveTabToUi(
    allocator: std.mem.Allocator,
    tab_mgr: *TabManager,
    page_states: *std.ArrayListUnmanaged(PageState),
    url_input: *TextInput,
    current_url: *?[]u8,
    scroll_y: *f32,
    scroll_x: *f32,
    loader: *Loader,
    fonts: *painter_mod.FontCache,
    storage: ?*Storage,
    surface_width: i32,
    surface_height: i32,
    status_text: *[]const u8,
    needs_repaint: *bool,
) void {
    if (tab_mgr.getActiveTab()) |tab| {
        scroll_y.* = tab.scroll_y;
        scroll_x.* = tab.scroll_x;
        url_input.setText(tab.url);
        url_input.focused = false;
        if (current_url.*) |old| allocator.free(old);
        current_url.* = allocator.dupe(u8, tab.url) catch null;

        if (tab_mgr.active_index < page_states.items.len) {
            const pg = &page_states.items[tab_mgr.active_index];
            if (pg.root_box == null and pg.error_message == null and tab.url.len > 0) {
                const url_z = allocator.allocSentinel(u8, tab.url.len, 0) catch return;
                defer allocator.free(url_z);
                @memcpy(url_z, tab.url);
                status_text.* = "Loading...";
                needs_repaint.* = true;
                if (navigateTo(allocator, loader, url_z, fonts, pg, storage, surface_width, surface_height)) {
                    status_text.* = "Done";
                    scroll_y.* = 0;
                    scroll_x.* = 0;
                } else {
                    status_text.* = "Failed";
                }
            }
        }
    }
}

/// Scroll so `match_y` is near the vertical center of the content viewport.
fn centerScrollOnMatchY(scroll_y: *f32, surface_height: i32, match_y: f32) void {
    const ch = @as(f32, @floatFromInt(chrome.contentHeight(surface_height)));
    scroll_y.* = @max(0, match_y - ch / 2.0);
}

fn recordHistoryIfNotPrivate(storage: ?*Storage, tab_mgr: *TabManager, url: []const u8, title: []const u8) void {
    const s = storage orelse return;
    const is_priv = if (tab_mgr.getActiveTab()) |t| t.is_private else false;
    if (!is_priv) s.addHistory(url, title);
}

/// Drop forward history entries after `history_pos` (frees their strings).
fn truncateForwardHistory(allocator: std.mem.Allocator, history: *std.ArrayListUnmanaged([]u8), history_pos: usize) void {
    if (history_pos + 1 >= history.items.len) return;
    for (history.items[history_pos + 1 ..]) |item| {
        allocator.free(item);
    }
    history.shrinkRetainingCapacity(history_pos + 1);
}

/// Append a copy of `url` to history and move `history_pos` to the new tail. Returns false on OOM.
fn pushHistoryNavigationUrl(
    allocator: std.mem.Allocator,
    history: *std.ArrayListUnmanaged([]u8),
    history_pos: *usize,
    url: []const u8,
) bool {
    const owned = allocator.dupe(u8, url) catch return false;
    history.append(allocator, owned) catch {
        allocator.free(owned);
        return false;
    };
    history_pos.* = history.items.len - 1;
    return true;
}

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

const font_resolver = @import("paint/font_resolver.zig");

// Fontconfig-resolved font paths (set at startup, valid for program lifetime)
var fc_sans_path: ?[:0]const u8 = null;
var fc_serif_path: ?[:0]const u8 = null;
var fc_mono_path: ?[:0]const u8 = null;

fn initFontPaths(allocator: std.mem.Allocator) void {
    // Resolve generic font families via fontconfig (matches Firefox behavior)
    fc_sans_path = font_resolver.resolve(allocator, "sans-serif");
    fc_serif_path = font_resolver.resolve(allocator, "serif");
    fc_mono_path = font_resolver.resolve(allocator, "monospace");
}

fn findFont() [*:0]const u8 {
    // Use fontconfig-resolved sans-serif if available
    if (fc_sans_path) |p| return p.ptr;
    // Fallback to hardcoded paths
    const cjk_path: []const u8 = font_cjk[0..font_cjk.len];
    if (std.Io.Dir.openFileAbsolute(env.ioOrPanic(), cjk_path, .{})) |f| {
        f.close(env.ioOrPanic());
        return font_cjk;
    } else |_| {}
    return font_fallback;
}

fn findSerifFont() [*:0]const u8 {
    if (fc_serif_path) |p| return p.ptr;
    return font_serif;
}

fn findMonoFont() [*:0]const u8 {
    if (fc_mono_path) |p| return p.ptr;
    return font_mono;
}

fn findFallbackFont() ?[*:0]const u8 {
    // If the primary font is fontconfig-resolved, provide CJK fallback
    const cjk_path: []const u8 = font_cjk[0..font_cjk.len];
    if (std.Io.Dir.openFileAbsolute(env.ioOrPanic(), cjk_path, .{})) |f| {
        f.close(env.ioOrPanic());
        return font_cjk;
    } else |_| {}
    const latin_path: []const u8 = font_fallback[0..font_fallback.len];
    if (std.Io.Dir.openFileAbsolute(env.ioOrPanic(), latin_path, .{})) |f| {
        f.close(env.ioOrPanic());
        return font_fallback;
    } else |_| {}
    return null;
}

fn fontPathSlice(path: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (path[len] != 0) len += 1;
    return path[0..len];
}

fn testHttp(allocator: std.mem.Allocator) !void {
    var client = try HttpClient.init();
    defer client.deinit();

    var response = try client.get(allocator, "http://example.com");
    defer response.deinit();
    if (response.status_code < 200 or response.status_code >= 400 or response.body.len == 0) {
        return error.HttpSmokeFailed;
    }
    std.debug.print("HTTP smoke PASS ({d}, {d} bytes)\n", .{ response.status_code, response.body.len });
}

/// Timestamp of last restyle (ms), used to throttle to ~60fps.
var last_restyle_time: i64 = 0;
const min_restyle_interval_ms: i64 = 16; // ~60fps

/// Re-style and re-layout a page after JS DOM mutation.
/// Rebuilds the style cascade, box tree, and layout from the current DOM state.
/// Walk the box tree and clamp any non-finite or absurdly large geometry to
/// safe values. The layout engine can emit `inf` / `NaN` / f32-max for
/// boxes whose computed style references a value that overflows during
/// layout (e.g. Google's flex layout with `height: calc(100% - 560px)` on a
/// parent whose own height is itself derived from a percentage). Downstream
/// paint and scroll code does `@intFromFloat` which panics on infinity, so
/// we sanitize once at the source.
fn sanitizeBoxGeometry(box: *Box) void {
    const max_dim: f32 = 16384.0;
    const safe = struct {
        fn f(v: f32) f32 {
            if (!std.math.isFinite(v)) return 0;
            return @max(@min(v, max_dim), -max_dim);
        }
    }.f;
    box.content.x = safe(box.content.x);
    box.content.y = safe(box.content.y);
    box.content.width = @max(safe(box.content.width), 0);
    box.content.height = @max(safe(box.content.height), 0);
    box.margin.left = safe(box.margin.left);
    box.margin.right = safe(box.margin.right);
    box.margin.top = safe(box.margin.top);
    box.margin.bottom = safe(box.margin.bottom);
    box.padding.left = @max(safe(box.padding.left), 0);
    box.padding.right = @max(safe(box.padding.right), 0);
    box.padding.top = @max(safe(box.padding.top), 0);
    box.padding.bottom = @max(safe(box.padding.bottom), 0);
    box.border.left = @max(safe(box.border.left), 0);
    box.border.right = @max(safe(box.border.right), 0);
    box.border.top = @max(safe(box.border.top), 0);
    box.border.bottom = @max(safe(box.border.bottom), 0);
    // Sanitize computed style dimensions that paint code reads directly.
    box.style.border_top_width = @max(safe(box.style.border_top_width), 0);
    box.style.border_right_width = @max(safe(box.style.border_right_width), 0);
    box.style.border_bottom_width = @max(safe(box.style.border_bottom_width), 0);
    box.style.border_left_width = @max(safe(box.style.border_left_width), 0);
    box.style.border_radius_tl = @max(safe(box.style.border_radius_tl), 0);
    box.style.border_radius_tr = @max(safe(box.style.border_radius_tr), 0);
    box.style.border_radius_bl = @max(safe(box.style.border_radius_bl), 0);
    box.style.border_radius_br = @max(safe(box.style.border_radius_br), 0);
    box.style.outline_width = @max(safe(box.style.outline_width), 0);
    box.style.box_shadow_x = safe(box.style.box_shadow_x);
    box.style.box_shadow_y = safe(box.style.box_shadow_y);
    box.style.box_shadow_blur = @max(safe(box.style.box_shadow_blur), 0);
    box.style.font_size_px = @max(safe(box.style.font_size_px), 1);
    for (box.children.items) |child| sanitizeBoxGeometry(child);
}

fn restylePage(page: *PageState, allocator: std.mem.Allocator, fonts: *painter_mod.FontCache, layout_width: i32, layout_height: i32) void {
    const doc = &(page.doc orelse return);

    const root_node = doc.root() orelse return;

    // Re-cascade styles from the current DOM (includes any <style> tags JS may have added)
    var new_styles = cascade_mod.cascade(root_node, allocator, page.external_css, @intCast(layout_width), @intCast(layout_height)) catch return;

    // Build new box tree from html root (not body) for proper CSS background propagation
    const new_root_box = box_tree.buildBoxTree(root_node, &new_styles, allocator) catch {
        new_styles.deinit();
        return;
    };

    // html root has no margin; body margin is applied via CSS cascade
    new_root_box.margin = .{};

    // Layout with full viewport width
    const content_w: f32 = @floatFromInt(layout_width);
    block_layout.layoutBlockVp(new_root_box, content_w, 0, fonts, @floatFromInt(layout_height));

    // Sanitize box geometry: clamp any non-finite or absurdly large values
    // that the layout engine can emit when fed a JS-built DOM with extreme
    // computed styles. Without this, downstream paint/scroll code can
    // @intFromFloat an infinity and panic. The clamp is large (16384px = ~
    // 17 screens at 1280 wide) so it never affects legitimate layout but
    // caps pathological cases.
    sanitizeBoxGeometry(new_root_box);

    // Replace old styles and box tree (order matters: box tree refs styles)
    // Note: old root_box is arena-allocated by buildBoxTree and not individually freed.
    // Old styles must be freed after the old box tree is no longer referenced.
    if (page.styles) |*s| s.deinit();
    page.styles = new_styles;
    page.root_box = new_root_box;
    page.total_height = painter_mod.contentHeight(new_root_box);
    page.total_width = painter_mod.contentWidth(new_root_box);

    // Free owned URL copies from old pending images before re-collecting
    for (page.pending_images.items) |entry| {
        allocator.free(@constCast(entry.url));
    }
    page.pending_images.clearRetainingCapacity();
    page.pending_images_idx = 0;
    collectImageUrls(new_root_box, &page.pending_images, allocator);

    // Update global root box and styles pointers for JS layout/style queries
    dom_api.setRootBox(new_root_box);
    dom_api.setStyles(&page.styles.?.styles);
    dom_api.setCustomProps(&page.styles.?.custom_props);
    dom_api.setViewport(@floatFromInt(layout_width), @floatFromInt(layout_height));

    std.debug.print("[JS] DOM mutation → re-styled and re-laid out (height={d:.0} width={d:.0} children={d})\n", .{
        page.total_height, page.total_width, new_root_box.children.items.len,
    });
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
    kotori_rt: ?kotori_runtime.KotoriRuntime = null,
    /// External CSS text (from <link> fetches), kept for re-cascade after DOM mutation.
    external_css: ?[]const u8 = null,
    /// Pending image URLs for incremental loading (1 per event loop tick).
    pending_images: std.ArrayListUnmanaged(ImageUrlEntry) = .empty,
    pending_images_idx: usize = 0,
    pending_images_loaded: usize = 0,
    /// Generation stamp matching in-flight background image fetches to this
    /// page; results with a stale stamp are dropped after navigation.
    fetch_gen: u64 = 0,
    /// URLs already handed to the fetch pool (dedup across restyle re-collects).
    submitted_images: ?std.StringHashMap(void) = null,
    /// Base URL for resolving relative image URLs.
    base_url: ?[]const u8 = null,
    /// Error message to display when page load fails.
    error_message: ?[]const u8 = null,
    error_alloc: ?[]u8 = null,
    /// Loaded script URLs for dynamic script dedup.
    loaded_script_urls: ?std.StringHashMap(void) = null,
    /// CSS animation state.
    anim_state: ?anim_mod.AnimationState = null,
    /// Deferred JS init: run after first paint for faster initial render.
    pending_js_init: bool = false,

    fn deinit(self: *PageState) void {
        // Clear dynamic script execution globals (safe — just nulls pointers)
        dom_api.setJsRuntime(null);
        dom_api.setLoader(null);
        dom_api.setLoadedScriptUrls(null);
        dom_api.setRootBox(null);
        dom_api.setStyles(null);
        dom_api.setCustomProps(null);
        // Reset global state without freeing JS values (leak-safe)
        dom_api.resetNodeCacheLeaky();
        events.resetEventsLeaky();
        // Leak the entire old page state during navigation.
        // QuickJS with disabled GC corrupts the heap during teardown,
        // causing cascading free() failures in subsequent allocations.
        // This is the standard approach for embedded browsers — each page
        // gets a fresh runtime, and the OS reclaims everything on exit.
        self.* = .{};
    }
};

/// Active tab's page state, or null if indices are out of sync.
fn activePageState(tab_mgr: *const TabManager, page_states: *std.ArrayListUnmanaged(PageState)) ?*PageState {
    if (tab_mgr.active_index < page_states.items.len) {
        return &page_states.items[tab_mgr.active_index];
    }
    return null;
}

// Script types and functions are now in core/script_executor.zig
const DeferredScript = script_executor.DeferredScript;
const setCurrentScript = script_executor.setCurrentScript;
const clearCurrentScript = script_executor.clearCurrentScript;

// executeScripts is now in core/script_executor.zig
const executeScripts = script_executor.executeScripts;

// parseDataUri, hexDigit, and script constants are now in core/script_executor.zig
const parseDataUri = script_executor.parseDataUri;
const hexDigit = script_executor.hexDigit;

// collectAndExecScripts is now in core/script_executor.zig

/// Initialize JavaScript for a loaded page: set up DOM APIs, execute scripts, fire events.
/// Delegates to core/script_executor.zig.
/// Default: kotori engine. Set SUZUME_JS=quickjs for legacy QuickJS engine.
fn initPageJs(doc: *Document, page: *PageState, allocator: std.mem.Allocator, loader: ?*Loader, base_url: ?[]const u8, fonts: ?*painter_mod.FontCache) void {
    // Extract URL fragment for :target pseudo-class
    if (base_url) |url| {
        if (std.mem.indexOfScalar(u8, url, '#')) |hash_pos| {
            const frag = url[hash_pos + 1 ..];
            const copy_len = @min(frag.len, dom_api.url_fragment.len);
            @memcpy(dom_api.url_fragment[0..copy_len], frag[0..copy_len]);
            dom_api.url_fragment_len = copy_len;
        } else {
            dom_api.url_fragment_len = 0;
        }
    } else {
        dom_api.url_fragment_len = 0;
    }

    // Check for JS engine flag (default: kotori, set SUZUME_JS=quickjs for legacy)
    const use_quickjs = if (env.get("SUZUME_JS")) |val|
        std.mem.eql(u8, val, "quickjs")
    else
        false;

    if (use_quickjs) {
        script_executor.initPageJs(doc, &page.js_rt, &page.loaded_script_urls, allocator, loader, base_url, fonts);
    } else {
        script_executor.initPageJsKotori(doc, &page.kotori_rt, allocator, loader, base_url);
    }
}

/// Recursively collect image URLs from the box tree.
/// Monotonic stamp tying background image fetches to the PageState that
/// requested them. Bumped per navigation; never zero for a live page.
var g_fetch_gen_counter: u64 = 0;

fn nextFetchGen() u64 {
    g_fetch_gen_counter += 1;
    return g_fetch_gen_counter;
}

const ImageUrlEntry = struct {
    url: []const u8,
    intrinsic_width: f32,
    intrinsic_height: f32,
    is_retry: bool = false, // true if this is a retry attempt (don't retry again)
    dom_node: ?*lxb.lxb_dom_node_t = null, // For firing onload/onerror events
};

fn collectImageUrls(box: *const Box, urls: *std.ArrayListUnmanaged(ImageUrlEntry), allocator: std.mem.Allocator) void {
    if (box.box_type == .replaced) {
        if (box.image_url) |url| {
            // Copy URL to owned memory so it survives DOM/style mutations
            const url_copy = allocator.alloc(u8, url.len) catch return;
            @memcpy(url_copy, url);
            urls.append(allocator, .{
                .url = url_copy,
                .intrinsic_width = box.intrinsic_width,
                .intrinsic_height = box.intrinsic_height,
                .dom_node = if (box.dom_node) |dn| dn.lxb_node else null,
            }) catch {
                allocator.free(url_copy);
                return;
            };
        }
    }
    // Also collect CSS background-image url() references
    if (box.style.background_image_url) |url| {
        if (url.len > 0 and url.len < 4096) {
            const url_copy = allocator.alloc(u8, url.len) catch return;
            @memcpy(url_copy, url);
            urls.append(allocator, .{
                .url = url_copy,
                .intrinsic_width = 0,
                .intrinsic_height = 0,
            }) catch {
                allocator.free(url_copy);
            };
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
                    // Also check CSS width/height
                    const has_css_w = box.style.width != .auto;
                    const has_css_h = box.style.height != .auto;
                    const has_w = has_html_w or has_css_w;
                    const has_h = has_html_h or has_css_h;

                    if (has_w and !has_h) {
                        // Width specified, compute height from aspect ratio
                        box.intrinsic_height = box.intrinsic_width * actual_h / actual_w;
                        updated.* = true;
                    } else if (!has_w and has_h) {
                        // Height specified, compute width from aspect ratio
                        box.intrinsic_width = box.intrinsic_height * actual_w / actual_h;
                        updated.* = true;
                    } else if (!has_w and !has_h) {
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

// signalJsEnabled is now in core/script_executor.zig

/// Temporary storage for pre-hover style snapshots (node_ptr → style).
var transition_snapshots: std.AutoHashMapUnmanaged(usize, ComputedStyle) = .empty;

/// Save style snapshots for the hovered element and its ancestors before restyle.
fn saveTransitionSnapshot(pg: *PageState, _: *anim_mod.AnimationState, hover_node: *lxb.lxb_dom_node_t) void {
    transition_snapshots.clearRetainingCapacity();
    const styles = &(pg.styles orelse return);

    // Save styles for the hover node and ancestors (since :hover propagates up)
    var cur: ?*lxb.lxb_dom_node_t = hover_node;
    var depth: u32 = 0;
    while (cur) |n| : (depth += 1) {
        if (depth > 20) break;
        const dn = DomNode{ .lxb_node = n };
        if (styles.getStyle(dn)) |cs| {
            if (cs.transition_duration > 0) {
                transition_snapshots.put(std.heap.c_allocator, @intFromPtr(n), cs) catch {};
            }
        }
        cur = n.parent;
    }
}

/// After restyle, compare new styles with saved snapshots and start transitions.
fn startHoverTransitions(pg: *PageState, anim_state: *anim_mod.AnimationState) void {
    const styles = &(pg.styles orelse return);

    const now_ms: f64 = @as(f64, @floatFromInt(env.nowMs()));

    var it = transition_snapshots.iterator();
    while (it.next()) |entry| {
        const node_ptr = entry.key_ptr.*;
        const old_style = entry.value_ptr.*;
        const node: *lxb.lxb_dom_node_t = @ptrFromInt(node_ptr);
        const dn = DomNode{ .lxb_node = node };
        const new_style = styles.getStyle(dn) orelse continue;

        // Check if any transitional property changed
        const changed = old_style.opacity != new_style.opacity or
            old_style.color != new_style.color or
            old_style.background_color != new_style.background_color or
            old_style.transform_translate_x != new_style.transform_translate_x or
            old_style.transform_translate_y != new_style.transform_translate_y or
            old_style.transform_scale_x != new_style.transform_scale_x or
            old_style.transform_scale_y != new_style.transform_scale_y;

        if (changed) {
            anim_state.startTransition(node_ptr, old_style, now_ms);
        }
    }
}

/// Walk the box tree and apply CSS animations to elements with animation-name set.
fn dispatchAnimationEvents(ctx: *quickjs.c.JSContext, anim_state: *anim_mod.AnimationState) void {
    const qjs = quickjs.c;
    for (anim_state.pending_events.items) |ev| {
        // Find the DOM node from pointer
        const node: *lxb.lxb_dom_node_t = @ptrFromInt(ev.node_ptr);
        const target_js = dom_api.wrapNode(ctx, node);
        if (quickjs.JS_IsNull(target_js) or quickjs.JS_IsUndefined(target_js)) continue;
        defer qjs.JS_FreeValue(ctx, target_js);

        // Determine event constructor and type string
        const is_transition = switch (ev.event_type) {
            .transition_end, .transition_start, .transition_run, .transition_cancel => true,
            else => false,
        };
        const type_str = switch (ev.event_type) {
            .transition_end => "transitionend",
            .transition_start => "transitionstart",
            .transition_run => "transitionrun",
            .transition_cancel => "transitioncancel",
            .animation_end => "animationend",
            .animation_start => "animationstart",
            .animation_iteration => "animationiteration",
            .animation_cancel => "animationcancel",
        };

        // Create and dispatch event via JS
        const js_code = if (is_transition)
            "(function(el,type,prop,time){var e=new TransitionEvent(type,{propertyName:prop,elapsedTime:time,bubbles:true});el.dispatchEvent(e);})"
        else
            "(function(el,type,name,time){var e=new AnimationEvent(type,{animationName:name,elapsedTime:time,bubbles:true});el.dispatchEvent(e);})";

        const fn_val = qjs.JS_Eval(ctx, js_code, js_code.len, "<anim-evt>", qjs.JS_EVAL_TYPE_GLOBAL);
        if (!quickjs.JS_IsException(fn_val)) {
            var args = [4]quickjs.c.JSValue{
                target_js,
                qjs.JS_NewStringLen(ctx, type_str.ptr, type_str.len),
                qjs.JS_NewStringLen(ctx, ev.name.ptr, ev.name.len),
                qjs.JS_NewFloat64(ctx, @floatCast(ev.elapsed_time)),
            };
            const r = qjs.JS_Call(ctx, fn_val, quickjs.JS_UNDEFINED(), 4, &args);
            qjs.JS_FreeValue(ctx, r);
            qjs.JS_FreeValue(ctx, fn_val);
        }
    }
    anim_state.pending_events.clearRetainingCapacity();
}

fn applyAnimationsToBoxTree(
    box: *Box,
    anim_state: *anim_mod.AnimationState,
    keyframes_map: *const std.StringHashMapUnmanaged(ast_mod.KeyframesRule),
    now_ms: f64,
) void {
    // Check if this box has an animation
    if (box.style.animation_name) |name| {
        if (name.len > 0 and box.style.animation_duration > 0) {
            // Register animation if not already running
            anim_state.startAnimation(box.style, now_ms);

            // Find the animation instance
            for (anim_state.animations.items) |*anim| {
                if (std.mem.eql(u8, anim.name, name)) {
                    const was_finished = anim.finished;
                    if (anim_mod.computeProgress(anim, now_ms)) |progress| {
                        if (keyframes_map.get(name)) |kf_rule| {
                            anim_mod.applyKeyframes(&box.style, kf_rule.keyframes, progress);
                        }
                    }
                    if (!was_finished and anim.finished) {
                        if (box.dom_node) |dn| {
                            anim_state.pending_events.append(anim_state.allocator, .{
                                .node_ptr = @intFromPtr(dn.lxb_node),
                                .event_type = .animation_end,
                                .name = anim.name,
                                .elapsed_time = anim.duration_s * anim.iteration_count,
                            }) catch {};
                        }
                    }
                    break;
                }
            }
        }
    }

    // Apply active transitions for this box's DOM node
    if (box.dom_node) |dn| {
        const node_ptr = @intFromPtr(dn.lxb_node);
        for (anim_state.transitions.items) |*tr| {
            if (tr.node_ptr == node_ptr and !tr.finished) {
                const was_finished = tr.finished;
                anim_mod.applyTransition(&box.style, tr, now_ms);
                if (!was_finished and tr.finished) {
                    // Transition just completed — queue transitionend event
                    anim_state.pending_events.append(anim_state.allocator, .{
                        .node_ptr = node_ptr,
                        .event_type = .transition_end,
                        .name = anim_mod.transitionPropertyName(tr.property),
                        .elapsed_time = tr.duration_s,
                    }) catch {};
                }
            }
        }
    }

    // Recurse into children
    for (box.children.items) |child| {
        applyAnimationsToBoxTree(child, anim_state, keyframes_map, now_ms);
    }
}

/// Download and register @font-face web fonts.
fn loadWebFonts(
    font_faces: []const cascade_mod.FontFaceInfo,
    fonts: *painter_mod.FontCache,
    loader: *Loader,
    allocator: std.mem.Allocator,
    base_url: [:0]const u8,
) void {
    for (font_faces) |ff| {
        // Skip if already registered
        if (fonts.web_fonts.get(ff.family) != null) continue;

        // Resolve relative URL
        const resolved = resolveUrl(allocator, base_url, ff.src_url) catch continue;
        defer allocator.free(resolved);

        // Download font file (with short timeout)
        const response = loader.loadBytesWithTimeout(resolved, 10) catch continue;
        if (response.body.len == 0) {
            allocator.free(response.body);
            continue;
        }

        // Transfer ownership of font data to FontCache
        fonts.registerWebFont(ff.family, response.body);
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
    // Clean up iframes before page
    dom_api.iframe.resetIframes();
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
        var styles = cascade_mod.cascade(root_node, allocator, null, @intCast(layout_width), @intCast(layout_height)) catch {
            doc.deinit();
            allocator.free(html_owned);
            return false;
        };

        const root_box = box_tree.buildBoxTree(root_node, &styles, allocator) catch {
            styles.deinit();
            doc.deinit();
            allocator.free(html_owned);
            return false;
        };

        // Apply body margin to the root box (html element has 0 margin by default)
        // html root has no margin; body margin is applied via CSS cascade
        root_box.margin = .{};

        const content_w: f32 = @floatFromInt(layout_width);
        block_layout.layoutBlockVp(root_box, content_w, 0, fonts, @floatFromInt(layout_height));
        sanitizeBoxGeometry(root_box);

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
    // Style (pass external CSS from loader — includes <link> stylesheets)
    const ext_css: ?[]const u8 = if (content.css.len > 0) content.css else null;
    var styles = cascade_mod.cascade(root_node, allocator, ext_css, @intCast(layout_width), @intCast(layout_height)) catch {
        doc.deinit();
        return false;
    };

    // Download and register @font-face web fonts
    if (styles.font_faces.items.len > 0) {
        loadWebFonts(styles.font_faces.items, fonts, loader, allocator, url_z);
    }

    // Build box tree from html root for proper CSS background propagation
    const root_box = box_tree.buildBoxTree(root_node, &styles, allocator) catch {
        styles.deinit();
        doc.deinit();
        return false;
    };

    // html root has no margin; body margin is applied via CSS cascade
    root_box.margin = .{};

    // Layout with full viewport width
    const content_w: f32 = @floatFromInt(layout_width);
    block_layout.layoutBlockVp(root_box, content_w, 0, fonts, @floatFromInt(layout_height));
    sanitizeBoxGeometry(root_box);

    // Collect image URLs for incremental loading
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
        .fetch_gen = nextFetchGen(),
        .base_url = base_url_copy,
        .anim_state = anim_mod.AnimationState.init(allocator),
    };

    // Set root box and styles pointers for JS layout/style queries
    dom_api.setRootBox(page.root_box);
    dom_api.setStyles(if (page.styles) |*s| &s.styles else null);
    dom_api.setCustomProps(if (page.styles) |*s| &s.custom_props else null);
    dom_api.setViewport(@floatFromInt(layout_width), @floatFromInt(layout_height));

    // Set up sync restyle context for getComputedStyle during JS execution
    g_restyle_page = page;
    g_restyle_allocator = allocator;
    g_restyle_fonts = fonts;
    g_restyle_width = layout_width;
    g_restyle_height = layout_height;
    dom_api.restyle_fn = &syncRestyle;

    // Bridge kotori.getComputedStyle to the same cascade result the QuickJS
    // path uses (CSSOM §6.5 resolved value algorithm). Harmless to re-set
    // each navigation — both values are global.
    kotori_dom.setFlushCallback(&kotoriFlushStylesIfDirty);
    kotori_dom.setResolveCallback(&kotoriResolveComputedValue);
    kotori_dom.setValidateCallback(&kotoriValidateCssValue);
    kotori_dom.setMarkDirtyCallback(&kotoriMarkDomDirty);
    kotori_dom.setElementMatchesCallback(&kotoriElementMatches);

    // Defer JavaScript execution until after first paint for faster initial render.
    page.pending_js_init = true;

    return true;
}

fn testJs() !void {
    var js_rt = try JsRuntime.init();
    defer js_rt.deinit();

    const result = js_rt.eval("1 + 2");
    defer result.deinit();
    if (!result.isOk() or !std.mem.eql(u8, result.value(), "3")) return error.JsSmokeFailed;
    const storage_key_result = js_rt.eval(
        \\sessionStorage.clear();
        \\sessionStorage.setItem("a", "1");
        \\sessionStorage.key(4294967296) === "a" &&
        \\sessionStorage.key(NaN) === "a" &&
        \\sessionStorage.key(-1) === null ? "ok" : "bad";
    );
    defer storage_key_result.deinit();
    if (!storage_key_result.isOk() or !std.mem.eql(u8, storage_key_result.value(), "ok")) return error.JsSmokeFailed;
    std.debug.print("JS smoke PASS\n", .{});
}
fn testDomJs() !void {
    const html =
        \\<html><body>
        \\<p id="out" class="one two one">before</p>
        \\<script>
        \\var out = document.getElementById("out");
        \\var tokens = Array.prototype.join.call(out.classList, ",");
        \\var iter = [...out.classList].join(",");
        \\var keys = Array.from(out.classList.keys()).join(",");
        \\var values = Array.from(out.classList.values()).join(",");
        \\var entries = Array.from(out.classList.entries()).map(function(e){ return e[0] + "=" + e[1]; }).join(",");
        \\var ctorThrows = false;
        \\try { new DOMTokenList(); } catch (e) { ctorThrows = e instanceof TypeError; }
        \\var classSame = out.classList === out.classList;
        \\var classCacheHidden = Object.keys(out).indexOf("__classList") === -1;
        \\var classIsTokenList = out.classList instanceof DOMTokenList && Object.prototype.toString.call(out.classList) === "[object DOMTokenList]";
        \\var classContainsNoThrow = out.classList.contains("bad token") === false;
        \\out.setAttribute("class", "one\ttwo one");
        \\out.classList.add();
        \\out.classList.remove();
        \\var classNoArg = out.getAttribute("class") === "one two";
        \\var bare = document.createElement("p");
        \\bare.classList.add();
        \\var classNoAttr = bare.getAttribute("class") === null;
        \\var many = document.createElement("p");
        \\var manyTokens = [], manyArgs = [];
        \\for (var i = 0; i < 33; i++) { manyTokens.push("c" + i); manyArgs.push("c" + i); }
        \\many.className = manyTokens.join(" ");
        \\many.classList.remove.apply(many.classList, manyArgs);
        \\var classRemoveMany = many.className === "";
        \\var manyDup = document.createElement("p");
        \\manyTokens = [];
        \\for (var j = 0; j < 130; j++) manyTokens.push("d" + j);
        \\manyTokens.push("d129");
        \\manyDup.className = manyTokens.join(" ");
        \\manyDup.classList.add();
        \\var classDedupMany = manyDup.classList.length === 130 && manyDup.classList.item(129) === "d129" && manyDup.className.split("d129").length === 2;
        \\globalThis.__classListItemIndexConverts =
        \\  out.classList.item(4294967296) === "one" &&
        \\  out.classList.item(NaN) === "one" &&
        \\  out.classList.item(-1) === null;
        \\var longClass = document.createElement("p");
        \\document.body.appendChild(longClass);
        \\var longToken = Array(5002).join("x");
        \\globalThis.__longToken = longToken;
        \\longClass.classList.add(longToken);
        \\var classLongToken = longClass.className.length === longToken.length && longClass.classList.contains(longToken);
        \\globalThis.__classLongOldValue = false;
        \\var longOldValueRecords = [];
        \\new MutationObserver(function(recs) {
        \\  for (var r = 0; r < recs.length; r++) longOldValueRecords.push(recs[r].oldValue);
        \\  globalThis.__classLongOldValue = longOldValueRecords[0] === globalThis.__longToken && longOldValueRecords[1] === globalThis.__longOldToken;
        \\}).observe(longClass, { attributes: true, attributeOldValue: true });
        \\longClass.className = Array(5002).join("y");
        \\globalThis.__longOldToken = longClass.className;
        \\longClass.classList.remove(globalThis.__longOldToken);
        \\var longAttr = document.createElement("div");
        \\document.body.appendChild(longAttr);
        \\var longAttrName = "DATA-" + Array(1100).join("A");
        \\var lowerLongAttrName = "data-" + Array(1100).join("a");
        \\longAttr.setAttribute(longAttrName, "v");
        \\globalThis.__attrLongName = longAttr.getAttribute(lowerLongAttrName) === "v" && longAttr.hasAttribute(lowerLongAttrName);
        \\longAttr.toggleAttribute(longAttrName, false);
        \\globalThis.__attrLongName = globalThis.__attrLongName && !longAttr.hasAttribute(lowerLongAttrName);
        \\globalThis.__attrLongOldValue = false;
        \\var longAttrValue = Array(5002).join("z");
        \\var longAttrOldRecords = [];
        \\longAttr.setAttribute("data-long-old", longAttrValue);
        \\new MutationObserver(function(recs) {
        \\  for (var ar = 0; ar < recs.length; ar++) longAttrOldRecords.push(recs[ar].oldValue);
        \\  globalThis.__attrLongOldValue = longAttrOldRecords[0] === longAttrValue && longAttrOldRecords[2] === longAttrValue && longAttrOldRecords[4] === longAttrValue;
        \\}).observe(longAttr, { attributes: true, attributeOldValue: true, attributeFilter: ["data-long-old"] });
        \\longAttr.setAttribute("data-long-old", "new");
        \\longAttr.setAttribute("data-long-old", longAttrValue);
        \\longAttr.removeAttribute("data-long-old");
        \\longAttr.setAttribute("data-long-old", longAttrValue);
        \\longAttr.toggleAttribute("data-long-old", false);
        \\globalThis.__nsAttrLongOldValue = false;
        \\var nsAttrOldRecords = [];
        \\longAttr.setAttributeNS("urn:test", "p:long", longAttrValue);
        \\new MutationObserver(function(recs) {
        \\  for (var nsr = 0; nsr < recs.length; nsr++) {
        \\    if (recs[nsr].attributeNamespace === "urn:test" && recs[nsr].attributeName === "long") nsAttrOldRecords.push(recs[nsr].oldValue);
        \\  }
        \\  globalThis.__nsAttrLongOldValue = nsAttrOldRecords[0] === longAttrValue && nsAttrOldRecords[2] === longAttrValue;
        \\}).observe(longAttr, { attributes: true, attributeOldValue: true });
        \\longAttr.setAttributeNS("urn:test", "q:long", "new");
        \\longAttr.setAttributeNS("urn:test", "p:long", longAttrValue);
        \\longAttr.removeAttributeNS("urn:test", "long");
        \\globalThis.__textLongOldValue = false;
        \\var longTextValue = Array(5002).join("t");
        \\var textNode = document.createTextNode(longTextValue);
        \\document.body.appendChild(textNode);
        \\var textOldRecords = [];
        \\new MutationObserver(function(recs) {
        \\  for (var tr = 0; tr < recs.length; tr++) textOldRecords.push(recs[tr].oldValue);
        \\  globalThis.__textLongOldValue = textOldRecords[0] === longTextValue && textOldRecords[2] === longTextValue;
        \\}).observe(textNode, { characterData: true, characterDataOldValue: true });
        \\textNode.data = "new";
        \\textNode.data = longTextValue;
        \\textNode.textContent = "newer";
        \\globalThis.__normalizeLongOldValue = false;
        \\var normalizeHost = document.createElement("div");
        \\var normalizeHugeTextValue = Array(17002).join("n");
        \\var normalizeLongText = document.createTextNode(normalizeHugeTextValue);
        \\normalizeHost.appendChild(normalizeLongText);
        \\normalizeHost.appendChild(document.createTextNode("tail"));
        \\document.body.appendChild(normalizeHost);
        \\var normalizeOldRecords = [];
        \\new MutationObserver(function(recs) {
        \\  for (var nr = 0; nr < recs.length; nr++) normalizeOldRecords.push(recs[nr].oldValue);
        \\  globalThis.__normalizeLongOldValue =
        \\    normalizeOldRecords[0] === normalizeHugeTextValue &&
        \\    normalizeLongText.data === normalizeHugeTextValue + "tail";
        \\}).observe(normalizeLongText, { characterData: true, characterDataOldValue: true });
        \\normalizeHost.normalize();
        \\globalThis.__liveChildNodesItemIndexConverts =
        \\  normalizeHost.childNodes.item(4294967296) === normalizeHost.childNodes.item(0) &&
        \\  normalizeHost.childNodes.item(NaN) === normalizeHost.childNodes.item(0);
        \\globalThis.__documentChildNodesItemIndexConverts =
        \\  document.childNodes.length > 0 &&
        \\  typeof document.childNodes.item === "function" &&
        \\  document.childNodes.item(4294967296) === document.childNodes.item(0) &&
        \\  document.childNodes.item(NaN) === document.childNodes.item(0);
        \\globalThis.__documentChildrenItemIndexConverts =
        \\  document.children.length > 0 &&
        \\  typeof document.children.item === "function" &&
        \\  document.children.item(4294967296) === document.children.item(0) &&
        \\  document.children.item(NaN) === document.children.item(0);
        \\var standaloneDoc = new Document();
        \\var standaloneDocEl = document.createElement("standalone-doc-item");
        \\standaloneDoc.appendChild(standaloneDocEl);
        \\globalThis.__newDocumentItemIndexConverts =
        \\  standaloneDoc.childNodes.item(4294967296) === standaloneDocEl &&
        \\  standaloneDoc.childNodes.item(NaN) === standaloneDocEl &&
        \\  standaloneDoc.children.item(4294967296) === standaloneDocEl &&
        \\  standaloneDoc.children.item(NaN) === standaloneDocEl;
        \\var jsOnlyTextHost = document.createElement("div");
        \\var jsOnlyTextValue = Array(33002).join("j");
        \\jsOnlyTextHost.appendChild({ nodeType: 3, data: jsOnlyTextValue, parentNode: null });
        \\jsOnlyTextHost.appendChild(document.createTextNode("tail"));
        \\globalThis.__jsOnlyTextContentLong = jsOnlyTextHost.textContent === jsOnlyTextValue + "tail";
        \\var longTitle = Array(5002).join("q");
        \\document.title = " \n" + longTitle + "\t tail ";
        \\globalThis.__titleLong = document.title === longTitle + " tail";
        \\var longSelectorValue = Array(1502).join("M") + "tail";
        \\var longSelectorExpected = Array(1502).join("m") + "TAIL";
        \\var longSelectorEscapedExpected = Array(1502).join("m") + "\\54 AIL";
        \\var selectorHost = document.createElement("div");
        \\selectorHost.setAttribute("data-long-selector", longSelectorValue);
        \\document.body.appendChild(selectorHost);
        \\globalThis.__selectorLongCI =
        \\  document.querySelector('[data-long-selector="' + longSelectorExpected + '" i]') === selectorHost &&
        \\  document.querySelector('[data-long-selector$="TAIL" i]') === selectorHost &&
        \\  document.querySelector('[data-long-selector*="mTAIL" i]') === selectorHost &&
        \\  document.querySelector('[data-long-selector="' + longSelectorEscapedExpected + '" i]') === selectorHost;
        \\var longEscapedClassToken = "sel" + Array(1502).join("x") + "tail";
        \\var longEscapedClassSelector = ".sel" + Array(1502).join("x") + "\\74 ail";
        \\var classSelectorHost = document.createElement("p");
        \\classSelectorHost.className = longEscapedClassToken;
        \\document.body.appendChild(classSelectorHost);
        \\var longEscapedIdValue = "id" + Array(1502).join("u") + "tail";
        \\var longEscapedIdSelector = "#id" + Array(1502).join("u") + "\\74 ail";
        \\var idSelectorHost = document.createElement("p");
        \\idSelectorHost.id = longEscapedIdValue;
        \\document.body.appendChild(idSelectorHost);
        \\globalThis.__selectorLongEscapedSimple =
        \\  document.querySelector(longEscapedClassSelector) === classSelectorHost &&
        \\  document.querySelector(longEscapedIdSelector) === idSelectorHost;
        \\var classCollectionHost = document.createElement("section");
        \\var classCollectionChild = document.createElement("span");
        \\classCollectionChild.className = longEscapedClassToken;
        \\classCollectionHost.appendChild(classCollectionChild);
        \\document.body.appendChild(classCollectionHost);
        \\globalThis.__classNameLongCollection =
        \\  document.getElementsByClassName(longEscapedClassToken).length >= 2 &&
        \\  classCollectionHost.getElementsByClassName(longEscapedClassToken).item(0) === classCollectionChild;
        \\globalThis.__liveHTMLCollectionItemIndexConverts =
        \\  classCollectionHost.getElementsByClassName(longEscapedClassToken).item(4294967296) === classCollectionChild &&
        \\  classCollectionHost.getElementsByClassName(longEscapedClassToken).item(NaN) === classCollectionChild;
        \\var longUpperAttrName = "DATA-" + Array(1502).join("A");
        \\var upperAttrSelectorHost = document.createElement("div");
        \\upperAttrSelectorHost.setAttribute(longUpperAttrName, "VALUE");
        \\document.body.appendChild(upperAttrSelectorHost);
        \\globalThis.__selectorLongAttrName =
        \\  document.querySelector("[" + longUpperAttrName + "]") === upperAttrSelectorHost &&
        \\  document.querySelector("[" + longUpperAttrName + "='VALUE']") === upperAttrSelectorHost;
        \\globalThis.__namedNodeMapItemIndexConverts =
        \\  upperAttrSelectorHost.attributes.item(4294967296) === upperAttrSelectorHost.attributes.item(0) &&
        \\  upperAttrSelectorHost.attributes.item(NaN) === upperAttrSelectorHost.attributes.item(0);
        \\var longNameValue = "n" + Array(1502).join("a") + "'tail";
        \\var longNameHost = document.createElement("input");
        \\longNameHost.setAttribute("name", longNameValue);
        \\document.body.appendChild(longNameHost);
        \\globalThis.__getElementsByNameLong =
        \\  document.getElementsByName(longNameValue).length === 1 &&
        \\  document.getElementsByName(longNameValue).item(0) === longNameHost &&
        \\  document.getElementsByName(longNameValue + "x").length === 0;
        \\globalThis.__liveNodeListItemIndexConverts =
        \\  document.getElementsByName(longNameValue).item(4294967296) === longNameHost &&
        \\  document.getElementsByName(longNameValue).item(NaN) === longNameHost;
        \\var longStyleHost = document.createElement("div");
        \\var longStyleValue = Array(5002).join("s");
        \\longStyleHost.style.setProperty("--long-style-value", longStyleValue);
        \\var removedLongStyle = longStyleHost.style.removeProperty("--long-style-value");
        \\globalThis.__styleLongSetProperty =
        \\  removedLongStyle === longStyleValue &&
        \\  longStyleHost.style.getPropertyValue("--long-style-value") === "" &&
        \\  longStyleHost.getAttribute("style").indexOf(longStyleValue) === -1;
        \\var invalidPriorityEmptyHost = document.createElement("div");
        \\invalidPriorityEmptyHost.style.setProperty("color", "red");
        \\invalidPriorityEmptyHost.style.setProperty("color", "", "definitely-not-important");
        \\invalidPriorityEmptyHost.style.setProperty("color", "blue", 0);
        \\invalidPriorityEmptyHost.style.setProperty("background-color", "red");
        \\invalidPriorityEmptyHost.style.setProperty("background-color");
        \\invalidPriorityEmptyHost.style.setProperty("--Inline-Mixed", "kept");
        \\invalidPriorityEmptyHost.style.setProperty("--Priority-Mixed", "kept", "important");
        \\var inlineMixedRemove = invalidPriorityEmptyHost.style.removeProperty("--inline-mixed");
        \\var emptyCustomInlineHost = document.createElement("div");
        \\emptyCustomInlineHost.style.cssText = "color: ; --Inline-Empty: ; background-color: red";
        \\var emptyCustomInlineItem = "";
        \\var emptyNormalInlineItem = "";
        \\for (var ec = 0; ec < emptyCustomInlineHost.style.length; ec++) {
        \\  if (emptyCustomInlineHost.style.item(ec) === "--Inline-Empty") emptyCustomInlineItem = "--Inline-Empty";
        \\  if (emptyCustomInlineHost.style.item(ec) === "color") emptyNormalInlineItem = "color";
        \\}
        \\globalThis.__styleEmptySetInvalidPriority =
        \\  invalidPriorityEmptyHost.style.getPropertyValue("color") === "" &&
        \\  invalidPriorityEmptyHost.style.getPropertyValue("background-color") === "" &&
        \\  invalidPriorityEmptyHost.style.getPropertyValue("--Inline-Mixed") === "kept" &&
        \\  invalidPriorityEmptyHost.style.getPropertyValue("--inline-mixed") === "" &&
        \\  invalidPriorityEmptyHost.style.getPropertyPriority("--Priority-Mixed") === "important" &&
        \\  invalidPriorityEmptyHost.style.getPropertyPriority("--priority-mixed") === "" &&
        \\  inlineMixedRemove === "" &&
        \\  emptyCustomInlineItem === "--Inline-Empty" &&
        \\  emptyNormalInlineItem === "" &&
        \\  emptyCustomInlineHost.style.getPropertyValue("background-color") === "red";
        \\var ruleStyleHost = document.createElement("style");
        \\ruleStyleHost.textContent = "p { color: red; --Parsed-Mixed: kept; --Parsed-Empty: ; --Parsed-String: \"a;b\"; --Parsed-Brace: \"}\"; --Parsed-After-Brace: after; }";
        \\document.body.appendChild(ruleStyleHost);
        \\globalThis.__styleSheetListItemIndexConverts =
        \\  document.styleSheets.item(4294967296) === document.styleSheets.item(0) &&
        \\  document.styleSheets.item(NaN) === document.styleSheets.item(0);
        \\var attrBraceSheet = new CSSStyleSheet();
        \\attrBraceSheet.replaceSync("a[data-x=\"{\"] { --Attr-Brace: ok; }");
        \\globalThis.__cssRuleOpenBraceInString =
        \\  attrBraceSheet.cssRules.length === 1 &&
        \\  attrBraceSheet.cssRules[0].selectorText === "a[data-x=\"{\"]" &&
        \\  attrBraceSheet.cssRules[0].style.getPropertyValue("--Attr-Brace") === "ok";
        \\var insertBraceSheet = new CSSStyleSheet();
        \\var insertBraceIndex = insertBraceSheet.insertRule("a[data-y=\"{\"] { --Insert-Brace: ok; }", 0);
        \\globalThis.__cssInsertRuleOpenBraceInString =
        \\  insertBraceIndex === 0 &&
        \\  insertBraceSheet.cssRules.length === 1 &&
        \\  insertBraceSheet.cssRules[0].selectorText === "a[data-y=\"{\"]" &&
        \\  insertBraceSheet.cssRules[0].style.getPropertyValue("--Insert-Brace") === "ok";
        \\var insertTrailingCommentSheet = new CSSStyleSheet();
        \\insertTrailingCommentSheet.insertRule("p { --Insert-Trailing-Comment: ok; } /* } */", 0);
        \\globalThis.__cssInsertRuleTrailingCommentBrace =
        \\  insertTrailingCommentSheet.cssRules.length === 1 &&
        \\  insertTrailingCommentSheet.cssRules[0].style.getPropertyValue("--Insert-Trailing-Comment") === "ok" &&
        \\  insertTrailingCommentSheet.cssRules[0].cssText === "p { --Insert-Trailing-Comment: ok; }";
        \\var insertRuleTrailingRuleThrows = false;
        \\try { new CSSStyleSheet().insertRule("p { color: red; } a { color: blue; }", 0); } catch (e) { insertRuleTrailingRuleThrows = e.name === "SyntaxError"; }
        \\globalThis.__cssInsertRuleTrailingRuleThrows = insertRuleTrailingRuleThrows;
        \\var insertRuleMissingCloseThrows = false;
        \\try { new CSSStyleSheet().insertRule("p { color: red", 0); } catch (e) { insertRuleMissingCloseThrows = e.name === "SyntaxError"; }
        \\globalThis.__cssInsertRuleMissingCloseThrows = insertRuleMissingCloseThrows;
        \\var insertRuleStringIndexSheet = new CSSStyleSheet();
        \\insertRuleStringIndexSheet.insertRule("p { --Insert-String-Index-Old: old; }", 0);
        \\var insertRuleStringIndex = insertRuleStringIndexSheet.insertRule("a { --Insert-String-Index: ok; }", "0");
        \\globalThis.__cssInsertRuleStringIndexConverts =
        \\  insertRuleStringIndex === 0 &&
        \\  insertRuleStringIndexSheet.cssRules[0].selectorText === "a";
        \\var groupingBraceSheet = new CSSStyleSheet();
        \\groupingBraceSheet.replaceSync("@media screen { }");
        \\var groupingInsertIndex = groupingBraceSheet.cssRules[0].insertRule("a[data-z=\"{\"] { --Grouping-Insert-Brace: ok; }", 0);
        \\globalThis.__cssGroupingInsertRuleOpenBraceInString =
        \\  groupingInsertIndex === 0 &&
        \\  groupingBraceSheet.cssRules[0].cssRules.length === 1 &&
        \\  groupingBraceSheet.cssRules[0].cssRules[0].selectorText === "a[data-z=\"{\"]" &&
        \\  groupingBraceSheet.cssRules[0].cssRules[0].style.getPropertyValue("--Grouping-Insert-Brace") === "ok";
        \\var groupingTrailingIndex = groupingBraceSheet.cssRules[0].insertRule("p { --Grouping-Trailing-Comment: ok; } /* } */", 1);
        \\globalThis.__cssGroupingInsertRuleTrailingCommentBrace =
        \\  groupingTrailingIndex === 1 &&
        \\  groupingBraceSheet.cssRules[0].cssRules.length === 2 &&
        \\  groupingBraceSheet.cssRules[0].cssRules[1].style.getPropertyValue("--Grouping-Trailing-Comment") === "ok" &&
        \\  groupingBraceSheet.cssRules[0].cssRules[1].cssText === "p { --Grouping-Trailing-Comment: ok; }";
        \\var groupingSyncHost = document.createElement("style");
        \\groupingSyncHost.textContent = "@media screen { }";
        \\document.body.appendChild(groupingSyncHost);
        \\groupingSyncHost.sheet.cssRules[0].insertRule("p { --Grouping-Sync: ok; }", 0);
        \\globalThis.__cssGroupingInsertRuleSyncsOwner =
        \\  groupingSyncHost.textContent.indexOf("--Grouping-Sync: ok") !== -1;
        \\groupingSyncHost.sheet.cssRules[0].deleteRule(0);
        \\globalThis.__cssGroupingDeleteRuleSyncsOwner =
        \\  groupingSyncHost.textContent.indexOf("--Grouping-Sync: ok") === -1;
        \\var groupingNestedAtIndex = groupingBraceSheet.cssRules[0].insertRule("@supports (display: block) { p { --Grouping-Nested-At: ok; } }", 2);
        \\globalThis.__cssGroupingInsertNestedAtRule =
        \\  groupingNestedAtIndex === 2 &&
        \\  groupingBraceSheet.cssRules[0].cssRules[2].type === CSSRule.SUPPORTS_RULE &&
        \\  groupingBraceSheet.cssRules[0].cssRules[2].cssRules.length === 1 &&
        \\  groupingBraceSheet.cssRules[0].cssRules[2].cssRules[0].style.getPropertyValue("--Grouping-Nested-At") === "ok";
        \\var groupingInvalidSelectorThrows = false;
        \\try { groupingBraceSheet.cssRules[0].insertRule("> { color: red; }", 0); } catch (e) { groupingInvalidSelectorThrows = e.name === "SyntaxError"; }
        \\globalThis.__cssGroupingInsertInvalidSelectorThrows = groupingInvalidSelectorThrows;
        \\var groupingInsertTrailingRuleThrows = false;
        \\try { groupingBraceSheet.cssRules[0].insertRule("p { color: red; } a { color: blue; }", 0); } catch (e) { groupingInsertTrailingRuleThrows = e.name === "SyntaxError"; }
        \\globalThis.__cssGroupingInsertTrailingRuleThrows = groupingInsertTrailingRuleThrows;
        \\var groupingInsertMissingCloseThrows = false;
        \\try { groupingBraceSheet.cssRules[0].insertRule("p { color: red", 0); } catch (e) { groupingInsertMissingCloseThrows = e.name === "SyntaxError"; }
        \\globalThis.__cssGroupingInsertMissingCloseThrows = groupingInsertMissingCloseThrows;
        \\var groupingDefaultIndexSheet = new CSSStyleSheet();
        \\groupingDefaultIndexSheet.replaceSync("@media screen { p { --Existing-Default-Index: old; } }");
        \\var groupingDefaultIndex = groupingDefaultIndexSheet.cssRules[0].insertRule("p { --Grouping-Default-Index: ok; }");
        \\globalThis.__cssGroupingInsertDefaultIndex =
        \\  groupingDefaultIndex === 0 &&
        \\  groupingDefaultIndexSheet.cssRules[0].cssRules[0].style.getPropertyValue("--Grouping-Default-Index") === "ok" &&
        \\  groupingDefaultIndexSheet.cssRules[0].cssRules[1].style.getPropertyValue("--Existing-Default-Index") === "old";
        \\var groupingStringIndex = groupingDefaultIndexSheet.cssRules[0].insertRule("a { --Grouping-String-Index: ok; }", "0");
        \\globalThis.__cssGroupingInsertRuleStringIndexConverts =
        \\  groupingStringIndex === 0 &&
        \\  groupingDefaultIndexSheet.cssRules[0].cssRules[0].selectorText === "a";
        \\globalThis.__cssGroupingInsertedRuleParentRule =
        \\  groupingDefaultIndexSheet.cssRules[0].cssRules[0].parentRule === groupingDefaultIndexSheet.cssRules[0];
        \\var parsedParentRuleSheet = new CSSStyleSheet();
        \\parsedParentRuleSheet.replaceSync("@media screen { p { --Parsed-Parent-Rule: ok; } }");
        \\globalThis.__cssParsedRuleParentRule =
        \\  parsedParentRuleSheet.cssRules[0].parentRule === null &&
        \\  parsedParentRuleSheet.cssRules[0].cssRules[0].parentRule === parsedParentRuleSheet.cssRules[0];
        \\globalThis.__cssMediaListItemIndexConverts =
        \\  parsedParentRuleSheet.cssRules[0].media.item(4294967296) === "screen" &&
        \\  parsedParentRuleSheet.cssRules[0].media.item(NaN) === "screen";
        \\var deletedGroupingRule = groupingDefaultIndexSheet.cssRules[0].cssRules[0];
        \\groupingDefaultIndexSheet.cssRules[0].deleteRule(0);
        \\globalThis.__cssGroupingDeletedRuleParentRefs =
        \\  deletedGroupingRule.parentRule === null &&
        \\  deletedGroupingRule.parentStyleSheet === null;
        \\var deletedSheetRuleSheet = new CSSStyleSheet();
        \\deletedSheetRuleSheet.replaceSync("p { --Deleted-Sheet-Rule: ok; }");
        \\var deletedSheetRule = deletedSheetRuleSheet.cssRules[0];
        \\deletedSheetRuleSheet.deleteRule(0);
        \\globalThis.__cssDeletedSheetRuleParentRefs =
        \\  deletedSheetRule.parentRule === null &&
        \\  deletedSheetRule.parentStyleSheet === null;
        \\var replacedRuleSheet = new CSSStyleSheet();
        \\replacedRuleSheet.replaceSync("@media screen { p { --Replace-Old-Rule: old; } }");
        \\var replacedTopRule = replacedRuleSheet.cssRules[0];
        \\var replacedChildRule = replacedTopRule.cssRules[0];
        \\replacedRuleSheet.replaceSync("a { --Replace-New-Rule: new; }");
        \\globalThis.__cssReplaceClearsOldRuleParentRefs =
        \\  replacedTopRule.parentRule === null &&
        \\  replacedTopRule.parentStyleSheet === null &&
        \\  replacedChildRule.parentRule === null &&
        \\  replacedChildRule.parentStyleSheet === null;
        \\var styleTextReplaceHost = document.createElement("style");
        \\styleTextReplaceHost.textContent = "@media screen { p { --Style-Text-Old-Rule: old; } }";
        \\document.body.appendChild(styleTextReplaceHost);
        \\var styleTextOldTopRule = styleTextReplaceHost.sheet.cssRules[0];
        \\var styleTextOldChildRule = styleTextOldTopRule.cssRules[0];
        \\styleTextReplaceHost.textContent = "a { --Style-Text-New-Rule: new; }";
        \\void styleTextReplaceHost.sheet.cssRules.length;
        \\globalThis.__cssStyleTextReplaceClearsOldRuleParentRefs =
        \\  styleTextOldTopRule.parentRule === null &&
        \\  styleTextOldTopRule.parentStyleSheet === null &&
        \\  styleTextOldChildRule.parentRule === null &&
        \\  styleTextOldChildRule.parentStyleSheet === null;
        \\var selectorTextSyncHost = document.createElement("style");
        \\selectorTextSyncHost.textContent = "p { --Selector-Text-Sync: ok; }";
        \\document.body.appendChild(selectorTextSyncHost);
        \\selectorTextSyncHost.sheet.cssRules[0].selectorText = "a";
        \\globalThis.__cssSelectorTextSyncsOwner =
        \\  selectorTextSyncHost.textContent.indexOf("a { --Selector-Text-Sync: ok; }") !== -1;
        \\var selectorTextObjectNoThrow = true;
        \\try { selectorTextSyncHost.sheet.cssRules[0].selectorText = { toString: function(){ return "span"; } }; } catch (e) { selectorTextObjectNoThrow = false; }
        \\globalThis.__cssSelectorTextObjectStringifies =
        \\  selectorTextObjectNoThrow &&
        \\  selectorTextSyncHost.sheet.cssRules[0].selectorText === "span";
        \\var ruleStyleCssTextObjectHost = document.createElement("style");
        \\ruleStyleCssTextObjectHost.textContent = "p { color: red; }";
        \\document.body.appendChild(ruleStyleCssTextObjectHost);
        \\ruleStyleCssTextObjectHost.sheet.cssRules[0].style.cssText = { toString: function(){ return "--Rule-CssText-Object: ok;"; } };
        \\globalThis.__cssRuleStyleCssTextObjectStringifies =
        \\  ruleStyleCssTextObjectHost.sheet.cssRules[0].style.getPropertyValue("--Rule-CssText-Object") === "ok" &&
        \\  ruleStyleCssTextObjectHost.textContent.indexOf("--Rule-CssText-Object: ok") !== -1;
        \\var deletedNestedGroupingRuleSheet = new CSSStyleSheet();
        \\deletedNestedGroupingRuleSheet.replaceSync("@media screen { @supports (display: block) { p { --Deleted-Nested-Grouping-Rule: ok; } } }");
        \\var deletedNestedGroupingRule = deletedNestedGroupingRuleSheet.cssRules[0].cssRules[0];
        \\var deletedNestedGroupingChildRule = deletedNestedGroupingRule.cssRules[0];
        \\deletedNestedGroupingRuleSheet.cssRules[0].deleteRule(0);
        \\globalThis.__cssGroupingDeletedNestedRuleParentRefs =
        \\  deletedNestedGroupingRule.parentRule === null &&
        \\  deletedNestedGroupingRule.parentStyleSheet === null &&
        \\  deletedNestedGroupingChildRule.parentRule === null &&
        \\  deletedNestedGroupingChildRule.parentStyleSheet === null;
        \\var deletedNestedSheetRuleSheet = new CSSStyleSheet();
        \\deletedNestedSheetRuleSheet.replaceSync("@media screen { p { --Deleted-Nested-Sheet-Rule: ok; } }");
        \\var deletedNestedSheetRule = deletedNestedSheetRuleSheet.cssRules[0];
        \\var deletedNestedSheetChildRule = deletedNestedSheetRule.cssRules[0];
        \\deletedNestedSheetRuleSheet.deleteRule(0);
        \\globalThis.__cssDeletedNestedSheetRuleParentRefs =
        \\  deletedNestedSheetRule.parentRule === null &&
        \\  deletedNestedSheetRule.parentStyleSheet === null &&
        \\  deletedNestedSheetChildRule.parentRule === null &&
        \\  deletedNestedSheetChildRule.parentStyleSheet === null;
        \\var deleteRuleWrapIndexSheet = new CSSStyleSheet();
        \\deleteRuleWrapIndexSheet.replaceSync("p { --Delete-Wrap-Index: ok; }");
        \\var deleteRuleWrapIndexConverts = false;
        \\try { deleteRuleWrapIndexSheet.deleteRule(4294967296); deleteRuleWrapIndexConverts = deleteRuleWrapIndexSheet.cssRules.length === 0; } catch (e) {}
        \\globalThis.__cssDeleteRuleWrapIndexConverts = deleteRuleWrapIndexConverts;
        \\var groupingDeleteRuleWrapIndexSheet = new CSSStyleSheet();
        \\groupingDeleteRuleWrapIndexSheet.replaceSync("@media screen { p { --Grouping-Delete-Wrap-Index: ok; } }");
        \\var groupingDeleteRuleWrapIndexConverts = false;
        \\try { groupingDeleteRuleWrapIndexSheet.cssRules[0].deleteRule(4294967296); groupingDeleteRuleWrapIndexConverts = groupingDeleteRuleWrapIndexSheet.cssRules[0].cssRules.length === 0; } catch (e) {}
        \\globalThis.__cssGroupingDeleteRuleWrapIndexConverts = groupingDeleteRuleWrapIndexConverts;
        \\var deleteDefaultIndexEmptyThrows = false;
        \\try { new CSSStyleSheet().deleteRule(); } catch (e) { deleteDefaultIndexEmptyThrows = e.name === "IndexSizeError"; }
        \\globalThis.__cssDeleteRuleDefaultIndexEmptyThrows = deleteDefaultIndexEmptyThrows;
        \\var groupingDeleteDefaultIndexEmptyThrows = false;
        \\try { groupingDefaultIndexSheet.cssRules[0].deleteRule(); groupingDefaultIndexSheet.cssRules[0].deleteRule(); groupingDefaultIndexSheet.cssRules[0].deleteRule(); } catch (e) { groupingDeleteDefaultIndexEmptyThrows = e.name === "IndexSizeError"; }
        \\globalThis.__cssGroupingDeleteRuleDefaultIndexEmptyThrows = groupingDeleteDefaultIndexEmptyThrows;
        \\var supportsSemiSheet = new CSSStyleSheet();
        \\supportsSemiSheet.replaceSync("@supports (content: \"a;b\") { p { --Supports-Semi: ok; } }");
        \\globalThis.__cssAtRuleHeaderSemiInString =
        \\  supportsSemiSheet.cssRules.length === 1 &&
        \\  supportsSemiSheet.cssRules[0].cssRules.length === 1 &&
        \\  supportsSemiSheet.cssRules[0].cssRules[0].style.getPropertyValue("--Supports-Semi") === "ok";
        \\var commentAtRuleSheet = new CSSStyleSheet();
        \\commentAtRuleSheet.replaceSync("/* lead */ @media screen { p { --Comment-At-Rule: ok; } }");
        \\globalThis.__cssLeadingCommentAtRule =
        \\  commentAtRuleSheet.cssRules.length === 1 &&
        \\  commentAtRuleSheet.cssRules[0].type === CSSRule.MEDIA_RULE &&
        \\  commentAtRuleSheet.cssRules[0].cssRules.length === 1 &&
        \\  commentAtRuleSheet.cssRules[0].cssRules[0].style.getPropertyValue("--Comment-At-Rule") === "ok";
        \\var declCommentSemiSheet = new CSSStyleSheet();
        \\declCommentSemiSheet.replaceSync("p { /* ; */ --Decl-Comment-Semi: ok; --Decl-Value-Comment-Semi: before /* ; */ after; color /* name */: green; background-color /* : */: blue; }");
        \\globalThis.__cssDeclCommentSemiIgnored =
        \\  declCommentSemiSheet.cssRules.length === 1 &&
        \\  declCommentSemiSheet.cssRules[0].style.getPropertyValue("--Decl-Comment-Semi") === "ok" &&
        \\  declCommentSemiSheet.cssRules[0].style.getPropertyValue("--Decl-Value-Comment-Semi") === "before /* ; */ after" &&
        \\  declCommentSemiSheet.cssRules[0].style.getPropertyValue("color") === "green" &&
        \\  declCommentSemiSheet.cssRules[0].style.getPropertyValue("background-color") === "blue";
        \\var commentBraceSheet = new CSSStyleSheet();
        \\commentBraceSheet.replaceSync("/* { */ p { --Comment-Brace: ok; /* } */ }");
        \\globalThis.__cssCommentBraceIgnored =
        \\  commentBraceSheet.cssRules.length === 1 &&
        \\  commentBraceSheet.cssRules[0].selectorText === "p" &&
        \\  commentBraceSheet.cssRules[0].style.getPropertyValue("--Comment-Brace") === "ok";
        \\var ruleStyle = document.styleSheets[0].cssRules[0].style;
        \\var emptyCustomRuleItem = "";
        \\for (var rc = 0; rc < ruleStyle.length; rc++) {
        \\  if (ruleStyle.item(rc) === "--Parsed-Empty") emptyCustomRuleItem = "--Parsed-Empty";
        \\}
        \\globalThis.__cssRuleStyleItemIndexConverts =
        \\  ruleStyle.item(4294967296) === ruleStyle.item(0) &&
        \\  ruleStyle.item(NaN) === ruleStyle.item(0);
        \\ruleStyle.setProperty("color", "", "definitely-not-important");
        \\ruleStyle.setProperty("color", "blue", 0);
        \\var ruleObjectName = { toString: function(){ return "--rule-object-name"; } };
        \\ruleStyle.setProperty(ruleObjectName, "ok");
        \\ruleStyle.setProperty("--Mixed-Case", "kept");
        \\ruleStyle.setProperty("background-color", "red");
        \\ruleStyle.setProperty("background-color");
        \\globalThis.__ruleStyleEmptySetInvalidPriority =
        \\  ruleStyle.getPropertyValue("color") === "" &&
        \\  ruleStyle.getPropertyValue("--Parsed-Mixed") === "kept" &&
        \\  ruleStyle.getPropertyValue("--parsed-mixed") === "" &&
        \\  ruleStyle.getPropertyValue("--Parsed-String") === "\"a;b\"" &&
        \\  ruleStyle.getPropertyValue("--Parsed-Brace") === "\"}\"" &&
        \\  ruleStyle.getPropertyValue("--Parsed-After-Brace") === "after" &&
        \\  emptyCustomRuleItem === "--Parsed-Empty" &&
        \\  ruleStyle.getPropertyValue("--rule-object-name") === "ok" &&
        \\  ruleStyle.getPropertyValue("--Mixed-Case") === "kept" &&
        \\  ruleStyle.getPropertyValue("--mixed-case") === "" &&
        \\  ruleStyle.getPropertyValue("background-color") === "";
        \\var longBoxHost = document.createElement("div");
        \\var longBoxA = "var(--" + Array(302).join("a") + ")";
        \\var longBoxB = "var(--" + Array(302).join("b") + ")";
        \\longBoxHost.style.setProperty("margin-top", longBoxA);
        \\longBoxHost.style.setProperty("margin-right", longBoxB);
        \\longBoxHost.style.setProperty("margin-bottom", longBoxA);
        \\longBoxHost.style.setProperty("margin-left", longBoxB);
        \\var longBoxTop = longBoxHost.style.getPropertyValue("margin-top");
        \\var longBoxRight = longBoxHost.style.getPropertyValue("margin-right");
        \\var longBoxMargin = longBoxHost.style.getPropertyValue("margin");
        \\var longBoxShorthandHost = document.createElement("div");
        \\var longBoxHugeA = "var(--" + Array(5002).join("m") + ")";
        \\var longBoxHugeB = "var(--" + Array(5002).join("n") + ")";
        \\longBoxShorthandHost.style.setProperty("margin", longBoxHugeA + " " + longBoxHugeB);
        \\var longBoxHugeMargin = longBoxShorthandHost.style.getPropertyValue("margin");
        \\var longBoxRemoveHost = document.createElement("div");
        \\var longBoxKeep = Array(5002).join("k");
        \\longBoxRemoveHost.style.setProperty("--keep-long", longBoxKeep);
        \\longBoxRemoveHost.style.setProperty("margin-top", longBoxHugeA);
        \\longBoxRemoveHost.style.setProperty("margin-right", longBoxHugeB);
        \\longBoxRemoveHost.style.setProperty("margin-bottom", longBoxHugeA);
        \\longBoxRemoveHost.style.setProperty("margin-left", longBoxHugeB);
        \\var removedLongBoxMargin = longBoxRemoveHost.style.removeProperty("margin");
        \\globalThis.__styleLongShorthandGet =
        \\  longBoxTop.length > 256 &&
        \\  longBoxRight.length > 256 &&
        \\  longBoxMargin === longBoxTop + " " + longBoxRight &&
        \\  longBoxHost.style.removeProperty("margin") === longBoxMargin &&
        \\  longBoxShorthandHost.style.getPropertyValue("margin-top") === longBoxHugeA &&
        \\  longBoxShorthandHost.style.getPropertyValue("margin-right") === longBoxHugeB &&
        \\  longBoxShorthandHost.style.getPropertyValue("margin-bottom") === longBoxHugeA &&
        \\  longBoxShorthandHost.style.getPropertyValue("margin-left") === longBoxHugeB &&
        \\  longBoxHugeMargin === longBoxHugeA + " " + longBoxHugeB &&
        \\  removedLongBoxMargin === longBoxHugeMargin &&
        \\  longBoxRemoveHost.style.getPropertyValue("--keep-long") === longBoxKeep &&
        \\  longBoxRemoveHost.style.getPropertyValue("margin-top") === "" &&
        \\  longBoxRemoveHost.style.getPropertyValue("margin-right") === "";
        \\var longFlexHost = document.createElement("div");
        \\var longFlexBasis = "var(--" + Array(302).join("f") + ")";
        \\longFlexHost.style.setProperty("flex-grow", "1");
        \\longFlexHost.style.setProperty("flex-shrink", "0");
        \\longFlexHost.style.setProperty("flex-basis", longFlexBasis);
        \\var longFlexValue = longFlexHost.style.getPropertyValue("flex");
        \\var computedLongFlexValue = getComputedStyle(longFlexHost).getPropertyValue("flex");
        \\var longFlexRemoveHost = document.createElement("div");
        \\longFlexRemoveHost.style.setProperty("flex-grow", "1");
        \\longFlexRemoveHost.style.setProperty("flex-shrink", "0");
        \\longFlexRemoveHost.style.setProperty("flex-basis", longFlexBasis);
        \\var removedLongFlexValue = longFlexRemoveHost.style.removeProperty("flex");
        \\var flexFlowRemoveHost = document.createElement("div");
        \\flexFlowRemoveHost.style.setProperty("flex-direction", "column");
        \\flexFlowRemoveHost.style.setProperty("flex-wrap", "wrap");
        \\var removedFlexFlowValue = flexFlowRemoveHost.style.removeProperty("flex-flow");
        \\var longFlexFlowHost = document.createElement("div");
        \\var longFlexDirection = "var(--" + Array(302).join("d") + ")";
        \\longFlexFlowHost.style.setProperty("flex-direction", longFlexDirection);
        \\longFlexFlowHost.style.setProperty("flex-wrap", "wrap");
        \\var longFlexFlowValue = longFlexFlowHost.style.getPropertyValue("flex-flow");
        \\var longFlexShorthandHost = document.createElement("div");
        \\var longFlexHugeBasis = Array(5002).join("1") + "px";
        \\longFlexShorthandHost.style.setProperty("flex", "1 0 " + longFlexHugeBasis);
        \\var longFlexShorthandValue = longFlexShorthandHost.style.getPropertyValue("flex");
        \\var flexSetHost = document.createElement("div");
        \\flexSetHost.style.setProperty("--keep-flex", longBoxKeep);
        \\flexSetHost.style.setProperty("flex", "2 0 10px");
        \\var flexSetValue = flexSetHost.style.getPropertyValue("flex");
        \\var flexFlowSetHost = document.createElement("div");
        \\flexFlowSetHost.style.setProperty("--keep-flow", longBoxKeep);
        \\flexFlowSetHost.style.setProperty("flex-flow", "column wrap");
        \\var flexFlowSetValue = flexFlowSetHost.style.getPropertyValue("flex-flow");
        \\globalThis.__styleLongFlexGet =
        \\  longFlexHost.style.getPropertyValue("flex-basis").length > 256 &&
        \\  longFlexValue === "1 0 " + longFlexHost.style.getPropertyValue("flex-basis") &&
        \\  computedLongFlexValue === longFlexValue &&
        \\  removedLongFlexValue === longFlexValue &&
        \\  longFlexRemoveHost.style.getPropertyValue("flex-grow") === "" &&
        \\  longFlexRemoveHost.style.getPropertyValue("flex-shrink") === "" &&
        \\  longFlexRemoveHost.style.getPropertyValue("flex-basis") === "" &&
        \\  removedFlexFlowValue === "column wrap" &&
        \\  flexFlowRemoveHost.style.getPropertyValue("flex-direction") === "" &&
        \\  flexFlowRemoveHost.style.getPropertyValue("flex-wrap") === "" &&
        \\  longFlexFlowValue === longFlexDirection + " wrap" &&
        \\  longFlexShorthandHost.style.getPropertyValue("flex-basis") === longFlexHugeBasis &&
        \\  longFlexShorthandValue === "1 0 " + longFlexHugeBasis &&
        \\  flexSetHost.style.getPropertyValue("--keep-flex") === longBoxKeep &&
        \\  flexSetHost.style.getPropertyValue("flex-grow") === "2" &&
        \\  flexSetHost.style.getPropertyValue("flex-shrink") === "0" &&
        \\  flexSetHost.style.getPropertyValue("flex-basis") === "10px" &&
        \\  flexSetValue === "2 0 10px" &&
        \\  flexFlowSetHost.style.getPropertyValue("--keep-flow") === longBoxKeep &&
        \\  flexFlowSetHost.style.getPropertyValue("flex-direction") === "column" &&
        \\  flexFlowSetHost.style.getPropertyValue("flex-wrap") === "wrap" &&
        \\  flexFlowSetValue === "column wrap";
        \\var supportsThrows = false;
        \\try { out.classList.supports("x"); } catch (e) { supportsThrows = e instanceof TypeError; }
        \\var link = document.createElement("link");
        \\link.rel = "bad token";
        \\var relContainsNoThrow = link.relList.contains("bad token") === false;
        \\link.rel = "stylesheet preload";
        \\var relIter = Array.from(link.relList.values()).join(",");
        \\var relKeys = Array.from(link.relList.keys()).join(",");
        \\var relEntries = Array.from(link.relList.entries()).map(function(e){ return e[0] + "=" + e[1]; }).join(",");
        \\var relForEach = "";
        \\link.relList.forEach(function(v, i){ relForEach += (i ? "," : "") + i + "=" + v; });
        \\var relSame = link.relList === link.relList;
        \\var relCacheHidden = Object.keys(link).indexOf("__relList") === -1;
        \\var relIsTokenList = link.relList instanceof DOMTokenList && Object.prototype.toString.call(link.relList) === "[object DOMTokenList]";
        \\var relInvalidThrows = false;
        \\try { link.relList.add("bad token"); } catch (e) { relInvalidThrows = e.name === "InvalidCharacterError"; }
        \\var relAddAtomic = false;
        \\try { link.relList.add("next", "bad token"); } catch (e) { relAddAtomic = e.name === "InvalidCharacterError" && link.rel === "stylesheet preload"; }
        \\var relRemoveAtomic = false;
        \\try { link.relList.remove("stylesheet", "bad token"); } catch (e) { relRemoveAtomic = e.name === "InvalidCharacterError" && link.rel === "stylesheet preload"; }
        \\var relToggleBool = link.relList.toggle("preload", "yes") === true;
        \\var relReplace = link.relList.replace("preload", "prefetch") === true && link.rel === "stylesheet prefetch";
        \\var relReplacePrecedence = false;
        \\try { link.relList.replace("bad token", ""); } catch (e) { relReplacePrecedence = e.name === "SyntaxError"; }
        \\link.relList.add("next", "next");
        \\var relAddDedup = link.rel === "stylesheet prefetch next";
        \\link.rel = "stylesheet\tpreload";
        \\link.relList.add("preload");
        \\var relAddWhitespace = link.rel === "stylesheet preload";
        \\link.rel = "stylesheet\tpreload";
        \\link.relList.remove("stylesheet");
        \\var relRemoveWhitespace = link.rel === "preload";
        \\link.rel = "stylesheet\tpreload";
        \\link.relList.add();
        \\link.relList.remove();
        \\var relNoArg = link.rel === "stylesheet preload";
        \\var emptyLink = document.createElement("link");
        \\emptyLink.relList.add();
        \\emptyLink.relList.remove("stylesheet");
        \\emptyLink.relList.toggle("stylesheet", false);
        \\var relNoAttr = emptyLink.getAttribute("rel") === null;
        \\link.rel = "stylesheet preload stylesheet";
        \\var relOrderedSet = link.relList.length === 2 && Array.from(link.relList.values()).join(",") === "stylesheet,preload";
        \\var relSupports = link.relList.supports("STYLESHEET") && !link.relList.supports("definitely-not-a-rel") && !link.relList.supports("") && !link.relList.supports("bad token");
        \\globalThis.__relListItemIndexConverts =
        \\  link.relList.item(4294967296) === "stylesheet" &&
        \\  link.relList.item(NaN) === "stylesheet";
        \\var nodeListForItem = document.querySelectorAll("p");
        \\globalThis.__nodeListItemIndexConverts =
        \\  nodeListForItem.item(4294967296) === nodeListForItem.item(0) &&
        \\  nodeListForItem.item(NaN) === nodeListForItem.item(0);
        \\out.textContent = tokens + ":" + out.classList.length + ":" + iter + ":" + keys + ":" + values + ":" + entries + ":" + ctorThrows + ":" + classSame + ":" + classCacheHidden + ":" + classIsTokenList + ":" + classContainsNoThrow + ":" + classNoArg + ":" + classNoAttr + ":" + classRemoveMany + ":" + classDedupMany + ":" + classLongToken + ":" + supportsThrows + ":" + relSame + ":" + relCacheHidden + ":" + relIsTokenList + ":" + relContainsNoThrow + ":" + relInvalidThrows + ":" + relAddAtomic + ":" + relRemoveAtomic + ":" + relToggleBool + ":" + relReplace + ":" + relReplacePrecedence + ":" + relAddDedup + ":" + relAddWhitespace + ":" + relRemoveWhitespace + ":" + relNoArg + ":" + relNoAttr + ":" + relOrderedSet + ":" + relSupports + ":" + relIter + ":" + relKeys + ":" + relEntries + ":" + relForEach;
        \\</script>
        \\</body></html>
    ;

    var doc = try Document.parse(html);
    defer doc.deinit();

    var js_rt = try JsRuntime.init();
    defer js_rt.deinit();
    defer events.deinitEvents(js_rt.ctx);

    dom_api.registerDomApis(js_rt.rt, js_rt.ctx, @ptrCast(@alignCast(doc.html_doc)));
    events.registerEventApis(js_rt.ctx);
    events.injectElementEventMethods(js_rt.ctx, dom_api.element_class_id);
    executeScripts(&doc, &js_rt, std.heap.c_allocator, null, null);
    _ = web_api.tickTimers(js_rt.ctx);

    const result = js_rt.eval("document.getElementById('out').textContent + ':' + globalThis.__classLongOldValue + ':' + globalThis.__attrLongName + ':' + globalThis.__attrLongOldValue + ':' + globalThis.__nsAttrLongOldValue + ':' + globalThis.__textLongOldValue + ':' + globalThis.__normalizeLongOldValue + ':' + globalThis.__liveChildNodesItemIndexConverts + ':' + globalThis.__documentChildNodesItemIndexConverts + ':' + globalThis.__documentChildrenItemIndexConverts + ':' + globalThis.__newDocumentItemIndexConverts + ':' + globalThis.__jsOnlyTextContentLong + ':' + globalThis.__titleLong + ':' + globalThis.__selectorLongCI + ':' + globalThis.__selectorLongEscapedSimple + ':' + globalThis.__classNameLongCollection + ':' + globalThis.__liveHTMLCollectionItemIndexConverts + ':' + globalThis.__selectorLongAttrName + ':' + globalThis.__namedNodeMapItemIndexConverts + ':' + globalThis.__getElementsByNameLong + ':' + globalThis.__liveNodeListItemIndexConverts + ':' + globalThis.__styleLongSetProperty + ':' + globalThis.__styleEmptySetInvalidPriority + ':' + globalThis.__ruleStyleEmptySetInvalidPriority + ':' + globalThis.__cssRuleStyleItemIndexConverts + ':' + globalThis.__styleSheetListItemIndexConverts + ':' + globalThis.__cssRuleOpenBraceInString + ':' + globalThis.__cssInsertRuleOpenBraceInString + ':' + globalThis.__cssInsertRuleTrailingCommentBrace + ':' + globalThis.__cssInsertRuleTrailingRuleThrows + ':' + globalThis.__cssInsertRuleMissingCloseThrows + ':' + globalThis.__cssInsertRuleStringIndexConverts + ':' + globalThis.__cssGroupingInsertRuleOpenBraceInString + ':' + globalThis.__cssGroupingInsertRuleTrailingCommentBrace + ':' + globalThis.__cssGroupingInsertRuleSyncsOwner + ':' + globalThis.__cssGroupingDeleteRuleSyncsOwner + ':' + globalThis.__cssGroupingInsertNestedAtRule + ':' + globalThis.__cssGroupingInsertInvalidSelectorThrows + ':' + globalThis.__cssGroupingInsertTrailingRuleThrows + ':' + globalThis.__cssGroupingInsertMissingCloseThrows + ':' + globalThis.__cssGroupingInsertDefaultIndex + ':' + globalThis.__cssGroupingInsertRuleStringIndexConverts + ':' + globalThis.__cssGroupingInsertedRuleParentRule + ':' + globalThis.__cssParsedRuleParentRule + ':' + globalThis.__cssGroupingDeletedRuleParentRefs + ':' + globalThis.__cssDeletedSheetRuleParentRefs + ':' + globalThis.__cssReplaceClearsOldRuleParentRefs + ':' + globalThis.__cssStyleTextReplaceClearsOldRuleParentRefs + ':' + globalThis.__cssSelectorTextSyncsOwner + ':' + globalThis.__cssSelectorTextObjectStringifies + ':' + globalThis.__cssRuleStyleCssTextObjectStringifies + ':' + globalThis.__cssGroupingDeletedNestedRuleParentRefs + ':' + globalThis.__cssDeletedNestedSheetRuleParentRefs + ':' + globalThis.__cssDeleteRuleWrapIndexConverts + ':' + globalThis.__cssGroupingDeleteRuleWrapIndexConverts + ':' + globalThis.__cssDeleteRuleDefaultIndexEmptyThrows + ':' + globalThis.__cssGroupingDeleteRuleDefaultIndexEmptyThrows + ':' + globalThis.__cssAtRuleHeaderSemiInString + ':' + globalThis.__cssLeadingCommentAtRule + ':' + globalThis.__cssDeclCommentSemiIgnored + ':' + globalThis.__cssCommentBraceIgnored + ':' + globalThis.__cssMediaListItemIndexConverts + ':' + globalThis.__styleLongShorthandGet + ':' + globalThis.__styleLongFlexGet + ':' + globalThis.__relListItemIndexConverts + ':' + globalThis.__nodeListItemIndexConverts + ':' + globalThis.__classListItemIndexConverts");
    defer result.deinit();
    const expected = "one,two:2:one,two:0,1:one,two:0=one,1=two:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:stylesheet,preload:0,1:0=stylesheet,1=preload:0=stylesheet,1=preload:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true:true";
    if (!result.isOk() or !std.mem.eql(u8, result.value(), expected)) {
        if (result.isOk()) std.debug.print("DOM JS smoke got: {s}\n", .{result.value()});
        return error.DomJsSmokeFailed;
    }
    std.debug.print("DOM JS smoke PASS\n", .{});
}

// Session management is now in core/session.zig
const serializeSession = session.serializeSession;

// URL utilities are now in core/url_utils.zig
const processUrlInput = url_utils.processUrlInput;
const isTrackingPixel = url_utils.isTrackingPixel;
const isSvgUrl = url_utils.isSvgUrl;
const isSvgContentType = url_utils.isSvgContentType;

// Form utilities are now in core/form_handler.zig
const findFormElement = form_handler.findFormElement;
const isTextFormElement = form_handler.isTextFormElement;
const findParentForm = form_handler.findParentForm;
const urlEncode = form_handler.urlEncode;
const extractQueryParam = form_handler.extractQueryParam;
const collectFormData = form_handler.collectFormData;

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

pub fn main(init: std.process.Init) !void {
    // Stash the Environ.Map and Io so former std.posix.getenv / std.fs.cwd
    // call sites can still perform global-style lookups via src/env.zig.
    env.map = init.environ_map;
    env.io = init.io;
    kotori.io.io = init.io;

    // Use GeneralPurposeAllocator in debug mode for double-free / use-after-free detection.
    // In release mode, use c_allocator for performance.
    var gpa: std.heap.DebugAllocator(.{
        .stack_trace_frames = if (@import("builtin").mode == .Debug) 8 else 0,
        .safety = (@import("builtin").mode == .Debug),
    }) = .init;
    defer if (@import("builtin").mode == .Debug) {
        _ = gpa.deinit();
    };
    const allocator = if (@import("builtin").mode == .Debug) gpa.allocator() else std.heap.c_allocator;

    // Parse arguments — Zig 0.16 provides Args via the main parameter rather than
    // a global std.process.args() helper. Init wraps Init.Minimal.
    var args = init.minimal.args.iterate();
    _ = args.skip();
    var initial_url: ?[]const u8 = null;
    var run_test_dom = false;
    var run_test_http = false;
    var run_test_js = false;
    var run_test_dom_js = false;
    var screenshot_path: ?[]const u8 = null;
    var webdriver_port: ?u16 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--test-dom")) {
            run_test_dom = true;
        } else if (std.mem.eql(u8, arg, "--test-http")) {
            run_test_http = true;
        } else if (std.mem.eql(u8, arg, "--test-js")) {
            run_test_js = true;
        } else if (std.mem.eql(u8, arg, "--test-dom-js")) {
            run_test_dom_js = true;
        } else if (std.mem.eql(u8, arg, "--wpt-mode")) {
            web_api.wpt_mode = true;
            // Mirror into the kotori engine's IO bridge (separate module,
            // cannot @import web_api). kotori's console.log consults this
            // flag to route "ALERT:" lines to stdout and set
            // `kotori.io.wpt_result_sent` on "ALERT: RESULT:".
            kotori.io.wpt_mode = true;
        } else if (std.mem.eql(u8, arg, "--screenshot")) {
            screenshot_path = args.next();
        } else if (std.mem.startsWith(u8, arg, "--webdriver=")) {
            webdriver_port = std.fmt.parseInt(u16, arg["--webdriver=".len..], 10) catch null;
        } else if (std.mem.eql(u8, arg, "--webdriver")) {
            if (args.next()) |port_str| {
                webdriver_port = std.fmt.parseInt(u16, port_str, 10) catch null;
            }
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
    const storage_ptr: ?*Storage = if (storage_inst) |*s| s else null;

    // Init HTTP client
    var http_client = HttpClient.init() catch |err| {
        std.debug.print("Failed to init HTTP client: {}\n", .{err});
        return err;
    };
    defer http_client.deinit();

    // Set up persistent cookie storage
    const cookie_path = blk: {
        const home = env.get("HOME") orelse break :blk null;
        const path = std.fmt.allocPrint(allocator, "{s}/.local/share/suzume/cookies.txt", .{home}) catch break :blk null;
        const path_z = allocator.allocSentinel(u8, path.len, 0) catch {
            allocator.free(path);
            break :blk null;
        };
        @memcpy(path_z, path);
        allocator.free(path);
        break :blk path_z;
    };
    if (cookie_path) |cp| {
        // Ensure directory exists
        const dir_end = std.mem.lastIndexOf(u8, cp, "/") orelse 0;
        if (dir_end > 0) {
            std.Io.Dir.cwd().createDirPath(env.ioOrPanic(), cp[0..dir_end]) catch {};
        }
        http_client.setCookieFile(cp);
        std.debug.print("Cookie file: {s}\n", .{cp});
    }

    // Share HTTP client with fetch() API so cookies are shared
    web_api.setSharedHttpClient(&http_client);

    var loader = Loader.init(allocator, &http_client);

    // Background image fetch pool — keeps the blocking curl calls off this
    // (UI) thread; decode/layout/events still happen here at drain time.
    var image_fetcher: ImageFetcher = .{};
    image_fetcher.start();
    defer image_fetcher.stop();

    // Font
    // Resolve generic font families via fontconfig (matches Firefox/Chrome behavior)
    initFontPaths(allocator);

    const font_path = findFont();
    std.debug.print("Using font: {s}\n", .{fontPathSlice(font_path)});

    var fonts = painter_mod.FontCache.init(allocator, font_path);
    defer fonts.deinit();

    // Set font paths for serif and monospace families (fontconfig-resolved)
    fonts.font_path_serif = findSerifFont();
    fonts.font_path_mono = findMonoFont();
    // Load fallback font for glyphs missing from primary font
    fonts.font_path_cjk_fallback = findFallbackFont();

    // Surface (check env vars for window size override)
    chrome.initWindowSize();
    var surface = Surface.init(chrome.default_window_w, chrome.default_window_h) catch |err| {
        std.debug.print("Failed to create surface: {}\n", .{err});
        return err;
    };
    defer surface.deinit();

    // Process pending X11 events to pick up WM-assigned geometry
    // (ConfigureNotify from tiling WM like i3 arrives before event loop)
    while (surface.pollEvent(0)) |init_event| {
        if (init_event.type == nsfb_c.NSFB_EVENT_RESIZE) {
            surface.refreshGeometry();
        }
    }
    surface.refreshGeometry();

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
    var prev_scroll_y: f32 = 0;
    var prev_scroll_x: f32 = 0;

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

    // Restore session if no initial URL provided (skip in WebDriver mode)
    if (initial_url == null and webdriver_port == null) {
        if (storage_ptr) |s| {
            if (s.loadSession()) |session_json| {
                defer allocator.free(session_json);
                session.restoreSession(allocator, session_json, &tab_mgr, &page_states.items.len, &struct {
                    fn noop() void {}
                }.noop);

                // Auto-load the active (first) tab after session restore
                if (tab_mgr.getActiveTab()) |tab| {
                    if (tab.url.len > 0) {
                        if (activePageState(&tab_mgr, &page_states)) |pg| {
                            const url_z = allocator.allocSentinel(u8, tab.url.len, 0) catch null;
                            if (url_z) |uz| {
                                defer allocator.free(uz);
                                @memcpy(uz, tab.url);
                                url_input.setText(tab.url);
                                url_input.focused = false;
                                status_text = "Loading...";
                                if (navigateTo(allocator, &loader, uz, &fonts, pg, storage_ptr, surface.width, surface.height)) {
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
    }

    // Ensure user scripts directory exists
    userscript.ensureScriptsDir(allocator);

    // Set initial JS viewport dimensions before first navigation
    web_api.setViewportSize(
        @intCast(surface.width),
        @intCast(@max(0, chrome.contentHeight(surface.height))),
    );

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
                if (navigateTo(allocator, &loader, uz, &fonts, &page_states.items[0], storage_ptr, surface.width, surface.height)) {
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
                    recordHistoryIfNotPrivate(storage_ptr, &tab_mgr, url, init_title orelse url);
                } else {
                    status_text = "Failed";
                }
            }
        }
    }

    // Screenshot mode: render page (including deferred JS, images, and any
    // DOM mutations they trigger) and dump to PNG, then exit.
    //
    // The interactive event loop drives three things incrementally:
    //   (a) deferred page-JS init (pending_js_init),
    //   (b) background image fetch submit/drain (image_fetcher + pending_images),
    //   (c) restyle when DOM becomes dirty.
    // The screenshot path skips the event loop, so it must replay those three
    // steps itself. We loop until the page is stable: no pending JS, no in-flight
    // image fetches, and DOM not dirty. A bounded iteration count guards
    // against runaway scripts.
    if (screenshot_path) |spath| {
        if (page_states.items.len == 0) {
            surface.fillRect(0, 0, surface.width, surface.height, 0xFFFFFFFF);
            surface.update();
            _ = surface.dumpToPng(spath);
            std.debug.print("[screenshot] Saved to {s} (no page)\n", .{spath});
            return;
        }
        const pg = &page_states.items[0];

        // Set restyle context so JS-side getComputedStyle / mark_dirty work
        // exactly like the interactive path.
        g_restyle_page = pg;
        g_restyle_allocator = allocator;
        g_restyle_fonts = &fonts;
        g_restyle_width = surface.width;
        g_restyle_height = surface.height;

        const max_iters: usize = 32;
        var iter: usize = 0;
        while (iter < max_iters) : (iter += 1) {
            var did_work = false;

            // (a) Deferred JS init — runs inline <script> and external scripts,
            // which is what most modern pages need to construct visible DOM.
            if (pg.pending_js_init) {
                pg.pending_js_init = false;
                if (pg.doc) |*doc| {
                    initPageJs(
                        doc,
                        pg,
                        allocator,
                        &loader,
                        if (pg.base_url) |bu| bu else null,
                        &fonts,
                    );
                    did_work = true;
                }
            }

            // Tick JS timers (setTimeout/setInterval) and pump pending jobs so
            // post-init callbacks (e.g. DOMContentLoaded handlers that build UI
            // asynchronously) get a chance to run.
            if (pg.js_rt) |*js_rt| {
                _ = web_api.tickTimers(js_rt.ctx);
                web_api.tickWebSockets(js_rt.ctx);
                web_api.tickWorkers(js_rt.ctx);
                js_rt.executePending();
            }
            // kotori timers: fire pending timers and microtasks a few times
            // so short setTimeout(0) chains resolve within the budget.
            if (pg.kotori_rt) |*krt| {
                var tk: usize = 0;
                while (tk < 4) : (tk += 1) {
                    _ = krt.runPendingTimers();
                }
            }

            // (b) Submit pending image fetches and drain completed ones.
            // Mirrors the interactive loop's incremental-image block. The
            // drain must run even if no submits happen this iteration, because
            // a previous iteration's submits may have just completed.
            while (pg.pending_images_idx < pg.pending_images.items.len and
                pg.pending_images_loaded < 300)
            {
                const entry = pg.pending_images.items[pg.pending_images_idx];
                pg.pending_images_idx += 1;

                const img_url = entry.url;
                if (pg.image_cache) |*ic| {
                    if (ic.get(img_url) != null) continue;
                }
                const data_svg_prefix = "data:image/svg+xml,";
                if (std.mem.startsWith(u8, img_url, data_svg_prefix)) {
                    const svg_data = img_url[data_svg_prefix.len..];
                    if (svg_data.len > 0) {
                        const svg_decoder = @import("svg/decoder.zig");
                        if (svg_decoder.decodeSvg(@as([]const u8, svg_data), 0, 0)) |img| {
                            const px_count: u64 = @as(u64, img.width) * @as(u64, img.height);
                            if (px_count <= 4 * 1024 * 1024) {
                                if (pg.image_cache) |*ic| {
                                    ic.put(img_url, img) catch {
                                        var mimg = img;
                                        mimg.deinit();
                                    };
                                    pg.pending_images_loaded += 1;
                                    did_work = true;
                                    if (entry.dom_node) |node| {
                                        if (pg.js_rt) |*jrt| {
                                            _ = events.dispatchEvent(jrt.ctx, node, "load");
                                            jrt.executePending();
                                        }
                                    }
                                }
                            } else {
                                var mimg = img;
                                mimg.deinit();
                            }
                        }
                    }
                } else if (image_fetcher.isActive() and
                    !isTrackingPixel(img_url, entry.intrinsic_width, entry.intrinsic_height))
                {
                    if (pg.base_url) |base| {
                        if (resolveUrl(allocator, base, img_url)) |resolved| {
                            defer allocator.free(resolved);
                            if (pg.submitted_images == null) {
                                pg.submitted_images = std.StringHashMap(void).init(allocator);
                            }
                            if (pg.submitted_images.?.contains(img_url)) continue;
                            if (allocator.dupe(u8, img_url)) |key_copy| {
                                pg.submitted_images.?.put(key_copy, {}) catch allocator.free(key_copy);
                            } else |_| {}
                            image_fetcher.submit(
                                img_url,
                                resolved,
                                entry.intrinsic_width,
                                entry.intrinsic_height,
                                false,
                                if (entry.dom_node) |n| @as(*anyopaque, @ptrCast(n)) else null,
                                pg.fetch_gen,
                            ) catch {};
                            did_work = true;
                        } else |_| {}
                    }
                }
            }

            // Drain completed fetches (decode + insert + fire load/error).
            while (image_fetcher.popResult()) |res_val| {
                var res = res_val;
                defer res.deinit();
                if (pg.fetch_gen != 0 and pg.fetch_gen != res.job.generation) continue;
                const img_url = res.job.url;
                if (pg.image_cache) |*ic| {
                    if (ic.get(img_url) != null) continue;
                }
                const node_opt: ?*lxb.lxb_dom_node_t = if (res.job.dom_node) |n|
                    @ptrCast(@alignCast(n))
                else
                    null;
                const body = res.body orelse {
                    if (!res.job.is_retry) {
                        image_fetcher.submit(
                            img_url,
                            res.job.resolved,
                            res.job.intrinsic_width,
                            res.job.intrinsic_height,
                            true,
                            res.job.dom_node,
                            res.job.generation,
                        ) catch {};
                    } else if (node_opt) |node| {
                        if (pg.js_rt) |*jrt| {
                            _ = events.dispatchEvent(jrt.ctx, node, "error");
                            jrt.executePending();
                        }
                    }
                    continue;
                };
                if (decodeImage(body)) |img| {
                    const px_count: u64 = @as(u64, img.width) * @as(u64, img.height);
                    if (px_count <= 4 * 1024 * 1024) {
                        if (pg.image_cache) |*ic| {
                            ic.put(img_url, img) catch {
                                var mimg = img;
                                mimg.deinit();
                                continue;
                            };
                            pg.pending_images_loaded += 1;
                            if (pg.root_box) |rb| {
                                var updated = false;
                                updateImageDimensions(rb, ic, &updated);
                                if (updated) {
                                    const cw: f32 = @floatFromInt(surface.width);
                                    block_layout.layoutBlockVp(rb, cw, 0, &fonts, @floatFromInt(surface.height));
                                    pg.total_height = painter_mod.contentHeight(rb);
                                    pg.total_width = painter_mod.contentWidth(rb);
                                }
                            }
                            did_work = true;
                            if (node_opt) |node| {
                                if (pg.js_rt) |*jrt| {
                                    _ = events.dispatchEvent(jrt.ctx, node, "load");
                                    jrt.executePending();
                                }
                            }
                        }
                    } else {
                        var mimg = img;
                        mimg.deinit();
                    }
                } else |_| {
                    if (node_opt) |node| {
                        if (pg.js_rt) |*jrt| {
                            _ = events.dispatchEvent(jrt.ctx, node, "error");
                            jrt.executePending();
                        }
                    }
                }
            }

            // (c) Restyle if JS / image loads mutated the DOM.
            if (dom_api.dom_dirty or kotori_dom.dom_dirty) {
                dom_api.dom_dirty = false;
                kotori_dom.dom_dirty = false;
                restylePage(pg, allocator, &fonts, surface.width, surface.height);
                did_work = true;
            }

            // If no work happened this iteration but image fetches are still
            // in flight, wait briefly for them to land before giving up.
            if (!did_work and image_fetcher.busy()) {
                env.sleepNs(50 * std.time.ns_per_ms);
                continue;
            }
            if (!did_work) break;
        }

        // Render. The visible window may be smaller than the page content
        // (e.g. Google's flex layout overflows past body height:100% and the
        // search form sits below the viewport). The X backend refuses to grow
        // past the screen size, so for screenshot we render to a fresh RAM
        // surface sized to the full page height. The visible X surface stays
        // untouched (the screenshot path exits immediately afterwards anyway).
        //
        // Clamp the page height to a sane maximum: 16384px is well above any
        // realistic page (a 1280-wide page would need ~16 screens of content)
        // and protects against runaway layout output (e.g. a JS-built DOM
        // whose computed height overflowed to f32 max).
        const render_w: i32 = surface.width;
        // total_height can be NaN/infinity/f32-max if a JS-built DOM has
        // absurd computed dimensions. Treat any non-finite or > 16384 value
        // as "fit the visible window" so we don't try to allocate a 3.4e38px
        // RAM surface (which would OOM) or @intFromFloat an overflowed f32.
        var clamped_page_h: f32 = @floatFromInt(surface.height);
        if (std.math.isFinite(pg.total_height) and pg.total_height < 16384) {
            clamped_page_h = @max(clamped_page_h, pg.total_height);
        }
        const render_h: i32 = @intFromFloat(clamped_page_h);

        var dump_surface: ?Surface = if (render_h > surface.height)
            Surface.initRam(render_w, render_h) catch null
        else
            null;
        defer if (dump_surface) |*ds| ds.deinit();

        const target: *Surface = if (dump_surface) |*ds| ds else &surface;
        target.fillRect(0, 0, target.width, target.height, 0xFFFFFFFF);
        if (pg.root_box) |root_box| {
            const ic_ptr: ?*ImageCache = if (pg.image_cache) |*ic| ic else null;
            painter_mod.paint(root_box, target, &fonts, 0, 0, 0, target.height, ic_ptr);
        }
        if (dump_surface == null) surface.update();
        if (target.dumpToPng(spath)) {
            std.debug.print("[screenshot] Saved to {s} ({d}x{d})\n", .{ spath, target.width, target.height });
        } else {
            std.debug.print("[screenshot] Failed to save to {s}\n", .{spath});
        }
        return;
    }

    // Window manager for multi-window support (WebDriver + window.open)
    var window_mgr = WindowManager.init(allocator);
    _ = window_mgr.createInitialWindow() catch {};

    // WebDriver server (if --webdriver=PORT specified)
    // Set global window manager for window.open() JS function
    web_api.global_window_mgr = &window_mgr;

    var wd_slot = CommandSlot{};
    var wd_server: ?WebDriverServer = null;
    if (webdriver_port) |port| {
        wd_server = WebDriverServer.init(allocator, port, &wd_slot);
        wd_server.?.start() catch |e| {
            std.debug.print("[WebDriver] Failed to start: {}\n", .{e});
        };
    }

    // Initial paint
    var needs_repaint = true;

    // Event loop
    var running = true;
    while (running) {
        // WPT mode: exit after test result is sent.
        // Either engine (QuickJS via web_api, or kotori via kotori_io) may
        // emit the "ALERT: RESULT:" line that flips these flags.
        if (web_api.wpt_mode and (web_api.wpt_result_sent or kotori.io.wpt_result_sent)) {
            break;
        }

        // WebDriver: poll command queue and execute
        if (wd_server != null) {
            if (wd_slot.poll()) |cmd| {
                const wd_resp = handleWebDriverCommand(
                    cmd,
                    allocator,
                    &loader,
                    &fonts,
                    &page_states,
                    &tab_mgr,
                    &surface,
                    &needs_repaint,
                    &scroll_y,
                    &scroll_x,
                    storage_ptr,
                    &window_mgr,
                );
                wd_slot.respond(wd_resp);
            }
        }

        // Repaint if needed
        // Apply CSS animations before repaint
        {
            const anim_pg = activePageState(&tab_mgr, &page_states);
            if (anim_pg) |pg| {
                if (pg.anim_state) |*as| {
                    if (pg.root_box != null and pg.styles != null and as.hasActiveAnimations()) {
                        const now_ms: f64 = @as(f64, @floatFromInt(env.nowMs()));
                        applyAnimationsToBoxTree(pg.root_box.?, as, &pg.styles.?.keyframes, now_ms);
                    }
                    // Dispatch pending transition/animation events to JS
                    if (as.pending_events.items.len > 0) {
                        if (pg.js_rt) |jrt| {
                            dispatchAnimationEvents(jrt.ctx, as);
                        }
                    }
                }
            }
        }

        if (needs_repaint) {
            // CSS background propagation (per CSS Backgrounds L3 §2.11.2):
            // 1. If html has a background, use it for the canvas
            // 2. Else if body has a background, propagate it to the canvas
            // 3. Else default to white
            const canvas_bg: ?u32 = blk: {
                const active_pg = activePageState(&tab_mgr, &page_states);
                if (active_pg) |pg| {
                    if (pg.root_box) |root| {
                        // Step 1: check html element background
                        const html_bg = root.style.background_color;
                        if (html_bg != 0x00000000) break :blk html_bg;
                        // Step 2: find body child and use its background
                        for (root.children.items) |child| {
                            if (child.dom_node) |dn| {
                                const tag = dn.tagName() orelse "";
                                if (std.mem.eql(u8, tag, "body") or std.mem.eql(u8, tag, "BODY")) {
                                    const body_bg = child.style.background_color;
                                    if (body_bg != 0x00000000) break :blk body_bg;
                                    break;
                                }
                            }
                        }
                        // Step 3: default to white
                        break :blk @as(u32, 0xFFFFFFFF);
                    }
                }
                break :blk null;
            };
            chrome.clearContentArea(&surface, canvas_bg);

            // Paint page content (from active tab's page state)
            const active_page = activePageState(&tab_mgr, &page_states);

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

        // Deferred JS init: execute scripts after first paint for faster initial render
        {
            const active_pg = activePageState(&tab_mgr, &page_states);
            if (active_pg) |pg| {
                if (pg.pending_js_init) {
                    pg.pending_js_init = false;
                    if (pg.doc) |*doc| {
                        initPageJs(doc, pg, allocator, &loader, if (pg.base_url) |bu| bu else null, &fonts);

                        // Post-JS anti-flicker cleanup
                        if (pg.js_rt) |*rt| {
                            const cleanup = rt.eval(
                                \\(function() {
                                \\  var h = document.documentElement;
                                \\  if (!h) return;
                                \\  var had = !!(h.className && /\banti-flicker\b/.test(h.className));
                                \\  if (had) {
                                \\    h.className = h.className.replace(/\banti-flicker\b/g, '').trim();
                                \\    if (h.classList) h.classList.add('w-mod-ix3');
                                \\  }
                                \\})()
                            );
                            if (!cleanup.isOk()) {
                                std.debug.print("[JS] cleanup eval failed: {s}\n", .{cleanup.value()});
                            }
                            cleanup.deinit();
                        }

                        // Re-style if JS mutated the DOM
                        if (dom_api.dom_dirty or kotori_dom.dom_dirty) {
                            dom_api.dom_dirty = false;
                            kotori_dom.dom_dirty = false;
                            restylePage(pg, allocator, &fonts, surface.width, surface.height);
                        }

                        // Execute user scripts
                        if (pg.js_rt) |*js_rt| {
                            userscript.executeUserScripts(js_rt, allocator);
                        }

                        needs_repaint = true;
                    }
                }
            }
        }

        // Tick JS timers (setTimeout/setInterval) and check for DOM mutations
        {
            const active_pg = activePageState(&tab_mgr, &page_states);
            if (active_pg) |pg| {
                if (pg.js_rt) |*js_rt| {
                    // Sync scroll position to JS before ticking timers
                    dom_api.scroll_x = scroll_x;
                    dom_api.scroll_y = scroll_y;

                    _ = web_api.tickTimers(js_rt.ctx);
                    web_api.tickWebSockets(js_rt.ctx);
                    web_api.tickWorkers(js_rt.ctx);
                    js_rt.executePending();
                    // Tick timers for all active iframe contexts
                    dom_api.iframe.tickAllIframeTimers();
                    if (dom_api.dom_dirty) {
                        const now_ms = env.nowMs();
                        if (now_ms - last_restyle_time >= min_restyle_interval_ms) {
                            dom_api.dom_dirty = false;
                            restylePage(pg, allocator, &fonts, surface.width, surface.height);
                            last_restyle_time = now_ms;
                            needs_repaint = true;
                        }
                    }
                    // Apply pending scroll requests from JS (clamp to content bounds)
                    if (dom_api.pending_scroll_y) |sy| {
                        const max_scroll_y = @max(pg.total_height - @as(f32, @floatFromInt(surface.height - chrome.content_y - chrome.status_bar_height)), 0);
                        scroll_y = @max(0, @min(sy, max_scroll_y));
                        dom_api.pending_scroll_y = null;
                        needs_repaint = true;
                    }
                    if (dom_api.pending_scroll_x) |sx| {
                        const max_scroll_x = @max(pg.total_width - @as(f32, @floatFromInt(surface.width)), 0);
                        scroll_x = @max(0, @min(sx, max_scroll_x));
                        dom_api.pending_scroll_x = null;
                        needs_repaint = true;
                    }

                    // Dispatch 'scroll' event when scroll position changed
                    if (scroll_y != prev_scroll_y or scroll_x != prev_scroll_x) {
                        prev_scroll_y = scroll_y;
                        prev_scroll_x = scroll_x;
                        dom_api.scroll_x = scroll_x;
                        dom_api.scroll_y = scroll_y;
                        events.dispatchWindowEvent(js_rt.ctx, "scroll");
                        js_rt.executePending();
                    }
                }

                // Tick kotori timers (separate engine, separate timer list).
                // Without this, setInterval/setTimeout callbacks only fire when
                // script_executor.zig drives the runtime (at initPageJs) — so
                // long-running pages (like WPT testharness) would see timers
                // throttle to ~one tick per render pass (~2 s) instead of the
                // requested cadence. runPendingTimers ignores delay on purpose
                // (see vm.zig comment); the caller — the main loop — gates it.
                if (pg.kotori_rt) |*krt| {
                    _ = krt.runPendingTimers();
                }

                // Tick CSS animations
                if (pg.anim_state) |*as| {
                    if (as.hasActiveAnimations()) {
                        needs_repaint = true; // Continuous repaint while animations run
                    }
                }
            }
        }

        // Check for JS-initiated navigation (location.assign, location.href = ...)
        if (web_api.getPendingNavigation()) |nav_url| {
            defer std.heap.c_allocator.free(nav_url);
            const nav_url_z = allocator.allocSentinel(u8, nav_url.len, 0) catch null;
            if (nav_url_z) |uz| {
                defer allocator.free(uz);
                @memcpy(uz, nav_url);
                const nav_pg = activePageState(&tab_mgr, &page_states);
                if (nav_pg) |pg| {
                    status_text = "Loading...";
                    if (navigateTo(allocator, &loader, uz, &fonts, pg, storage_ptr, surface.width, surface.height)) {
                        status_text = "Done";
                        scroll_y = 0;
                        scroll_x = 0;
                        if (current_url) |old| allocator.free(old);
                        current_url = allocator.dupe(u8, nav_url) catch null;
                        url_input.setText(nav_url);
                        tab_mgr.updateActiveUrl(nav_url);
                        needs_repaint = true;
                    } else {
                        status_text = "Failed";
                    }
                }
            }
        }

        // Check for history.pushState URL bar update
        if (web_api.getPendingUrlUpdate()) |new_url| {
            defer std.heap.c_allocator.free(new_url);
            url_input.setText(new_url);
            needs_repaint = true;
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
                        const xim_pg = activePageState(&tab_mgr, &page_states);
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
            if (storage_ptr) |s| {
                if (serializeSession(allocator, &tab_mgr)) |json| {
                    defer allocator.free(json);
                    s.saveSession(json);
                }
            }
        }

        // Incremental image loading: hand fetches to the background pool
        // (non-blocking), then integrate any completed results — decode,
        // cache insert, relayout and load/error events all stay on this
        // thread, so no DOM/JS state is ever touched off-thread.
        {
            const active_img_pg = activePageState(&tab_mgr, &page_states);
            if (active_img_pg) |pg| {
                while (pg.pending_images_idx < pg.pending_images.items.len and pg.pending_images_loaded < 300) {
                    const entry = pg.pending_images.items[pg.pending_images_idx];
                    pg.pending_images_idx += 1;

                    const img_url = entry.url;
                    // Skip if already cached (dedup — same URL may appear multiple times)
                    if (pg.image_cache) |*ic| {
                        if (ic.get(img_url) != null) continue;
                    }
                    // Handle data:image/svg+xml, URLs (inline SVGs) — bypass HTTP fetch
                    const data_svg_prefix = "data:image/svg+xml,";
                    if (std.mem.startsWith(u8, img_url, data_svg_prefix)) {
                        const svg_data = img_url[data_svg_prefix.len..];
                        if (svg_data.len > 0) {
                            const svg_decoder = @import("svg/decoder.zig");
                            if (svg_decoder.decodeSvg(@as([]const u8, svg_data), 0, 0)) |img| {
                                const px_count: u64 = @as(u64, img.width) * @as(u64, img.height);
                                if (px_count <= 4 * 1024 * 1024) {
                                    if (pg.image_cache) |*ic| {
                                        ic.put(img_url, img) catch {
                                            var mimg = img;
                                            mimg.deinit();
                                        };
                                        pg.pending_images_loaded += 1;
                                        needs_repaint = true;
                                        // Fire 'load' event on SVG img element
                                        if (entry.dom_node) |node| {
                                            if (pg.js_rt) |*jrt| {
                                                _ = events.dispatchEvent(jrt.ctx, node, "load");
                                                jrt.executePending();
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } else if (image_fetcher.isActive() and !isTrackingPixel(img_url, entry.intrinsic_width, entry.intrinsic_height)) {
                        if (pg.base_url) |base| {
                            if (resolveUrl(allocator, base, img_url)) |resolved| {
                                defer allocator.free(resolved);
                                // Dedup against fetches already in flight (the
                                // same src can be re-collected after a restyle
                                // before its first fetch completes).
                                if (pg.submitted_images == null) {
                                    pg.submitted_images = std.StringHashMap(void).init(allocator);
                                }
                                if (pg.submitted_images.?.contains(img_url)) continue;
                                if (allocator.dupe(u8, img_url)) |key_copy| {
                                    pg.submitted_images.?.put(key_copy, {}) catch allocator.free(key_copy);
                                } else |_| {}
                                image_fetcher.submit(
                                    img_url,
                                    resolved,
                                    entry.intrinsic_width,
                                    entry.intrinsic_height,
                                    false,
                                    if (entry.dom_node) |n| @as(*anyopaque, @ptrCast(n)) else null,
                                    pg.fetch_gen,
                                ) catch {};
                            } else |_| {}
                        }
                    }
                }
            }

            // Drain completed fetches for ALL live pages (matched by
            // generation); results that outlived their page are dropped.
            while (image_fetcher.popResult()) |res_val| {
                var res = res_val;
                defer res.deinit();
                var target: ?*PageState = null;
                for (page_states.items) |*ps| {
                    if (ps.fetch_gen != 0 and ps.fetch_gen == res.job.generation) {
                        target = ps;
                        break;
                    }
                }
                const tpg = target orelse continue;
                const img_url = res.job.url;
                if (tpg.image_cache) |*ic| {
                    if (ic.get(img_url) != null) continue;
                }
                const node_opt: ?*lxb.lxb_dom_node_t = if (res.job.dom_node) |n| @ptrCast(@alignCast(n)) else null;
                const body = res.body orelse {
                    // HTTP fetch failed — retry once if not already a retry
                    if (!res.job.is_retry) {
                        image_fetcher.submit(
                            img_url,
                            res.job.resolved,
                            res.job.intrinsic_width,
                            res.job.intrinsic_height,
                            true,
                            res.job.dom_node,
                            res.job.generation,
                        ) catch {};
                    } else if (node_opt) |node| {
                        // Final retry failed — fire 'error' event
                        if (tpg.js_rt) |*jrt| {
                            _ = events.dispatchEvent(jrt.ctx, node, "error");
                            jrt.executePending();
                        }
                    }
                    continue;
                };
                if (decodeImage(body)) |img| {
                    const px_count: u64 = @as(u64, img.width) * @as(u64, img.height);
                    if (px_count <= 4 * 1024 * 1024) {
                        if (tpg.image_cache) |*ic| {
                            ic.put(img_url, img) catch {
                                var mimg = img;
                                mimg.deinit();
                                continue;
                            };
                            tpg.pending_images_loaded += 1;
                            // Update intrinsic dimensions from actual image
                            if (tpg.root_box) |rb| {
                                var updated = false;
                                updateImageDimensions(rb, ic, &updated);
                                if (updated) {
                                    // Re-layout to apply new aspect ratios
                                    const cw: f32 = @floatFromInt(surface.width);
                                    block_layout.layoutBlockVp(rb, cw, 0, &fonts, @floatFromInt(surface.height));
                                    tpg.total_height = painter_mod.contentHeight(rb);
                                    tpg.total_width = painter_mod.contentWidth(rb);
                                }
                            }
                            needs_repaint = true;
                            // Fire 'load' event on the img element
                            if (node_opt) |node| {
                                if (tpg.js_rt) |*jrt| {
                                    _ = events.dispatchEvent(jrt.ctx, node, "load");
                                    jrt.executePending();
                                }
                            }
                        }
                    } else {
                        var mimg = img;
                        mimg.deinit();
                    }
                } else |_| {
                    // Image decode failed — fire 'error' event
                    if (node_opt) |node| {
                        if (tpg.js_rt) |*jrt| {
                            _ = events.dispatchEvent(jrt.ctx, node, "error");
                            jrt.executePending();
                        }
                    }
                }
            }
        }

        // Use shorter poll timeout when repaint pending or WebDriver active;
        // timers use 4ms (avoid busy-spin while staying responsive)
        const poll_timeout: i32 = if (needs_repaint or wd_server != null) 0 else if (web_api.hasTimers() or image_fetcher.busy()) 4 else 50;
        if (surface.pollEvent(poll_timeout)) |event| {
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
                    // Update JS viewport dimensions
                    web_api.setViewportSize(
                        @intCast(surface.width),
                        @intCast(@max(0, chrome.contentHeight(surface.height))),
                    );
                    // Re-layout page content for new width
                    const resize_pg = activePageState(&tab_mgr, &page_states);
                    if (resize_pg) |pg| {
                        // Full re-cascade + re-layout for viewport-dependent CSS (@media, vw/vh)
                        restylePage(pg, allocator, &fonts, surface.width, surface.height);
                        // Clamp scroll to new content bounds
                        const ch = @as(f32, @floatFromInt(chrome.contentHeight(surface.height)));
                        const max_scroll = @max(if (pg.total_height > ch) pg.total_height - ch else 0, 0);
                        scroll_y = @max(0, @min(scroll_y, max_scroll));
                    }
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
                        applyActiveTabToUi(allocator, &tab_mgr, &page_states, &url_input, &current_url, &scroll_y, &scroll_x, &loader, &fonts, storage_ptr, surface.width, surface.height, &status_text, &needs_repaint);
                        status_text = "Tab closed";
                        needs_repaint = true;
                        std.debug.print("[Tabs] Closed tab, now {d} tabs\n", .{tab_mgr.tabCount()});
                        continue;
                    }

                    // Ctrl+Tab: next tab
                    if (ctrl_held and key == nsfb_c.NSFB_KEY_TAB and !shift_held) {
                        tab_mgr.saveScrollPosition(scroll_y, scroll_x);
                        if (tab_mgr.nextTab()) {
                            applyActiveTabToUi(allocator, &tab_mgr, &page_states, &url_input, &current_url, &scroll_y, &scroll_x, &loader, &fonts, storage_ptr, surface.width, surface.height, &status_text, &needs_repaint);
                            needs_repaint = true;
                        }
                        continue;
                    }

                    // Ctrl+Shift+Tab: previous tab
                    if (ctrl_held and key == nsfb_c.NSFB_KEY_TAB and shift_held) {
                        tab_mgr.saveScrollPosition(scroll_y, scroll_x);
                        if (tab_mgr.prevTab()) {
                            applyActiveTabToUi(allocator, &tab_mgr, &page_states, &url_input, &current_url, &scroll_y, &scroll_x, &loader, &fonts, storage_ptr, surface.width, surface.height, &status_text, &needs_repaint);
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
                                applyActiveTabToUi(allocator, &tab_mgr, &page_states, &url_input, &current_url, &scroll_y, &scroll_x, &loader, &fonts, storage_ptr, surface.width, surface.height, &status_text, &needs_repaint);
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
                            const pg = activePageState(&tab_mgr, &page_states) orelse continue;
                            if (navigateTo(allocator, &loader, url_z, &fonts, pg, storage_ptr, surface.width, surface.height)) {
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
                            const pg = activePageState(&tab_mgr, &page_states) orelse continue;
                            if (navigateTo(allocator, &loader, url_z, &fonts, pg, storage_ptr, surface.width, surface.height)) {
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
                        const pg = activePageState(&tab_mgr, &page_states) orelse continue;
                        if (navigateTo(allocator, &loader, url_z, &fonts, pg, storage_ptr, surface.width, surface.height)) {
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
                        if (storage_ptr) |s| {
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
                            const pg = activePageState(&tab_mgr, &page_states) orelse continue;
                            if (navigateTo(allocator, &loader, url_z, &fonts, pg, storage_ptr, surface.width, surface.height)) {
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
                            const pg = activePageState(&tab_mgr, &page_states) orelse continue;
                            if (navigateTo(allocator, &loader, url_z, &fonts, pg, storage_ptr, surface.width, surface.height)) {
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
                                applyActiveTabToUi(allocator, &tab_mgr, &page_states, &url_input, &current_url, &scroll_y, &scroll_x, &loader, &fonts, storage_ptr, surface.width, surface.height, &status_text, &needs_repaint);
                                needs_repaint = true;
                                continue;
                            },
                            .switch_tab => {
                                tab_mgr.saveScrollPosition(scroll_y, scroll_x);
                                if (tab_mgr.switchTo(tab_hit.index)) {
                                    applyActiveTabToUi(allocator, &tab_mgr, &page_states, &url_input, &current_url, &scroll_y, &scroll_x, &loader, &fonts, storage_ptr, surface.width, surface.height, &status_text, &needs_repaint);
                                    needs_repaint = true;
                                }
                                continue;
                            },
                            .none => {},
                        }

                        // Not a tab bar click — forward to regular click handler
                        const active_pg = activePageState(&tab_mgr, &page_states);
                        if (active_pg) |page| {
                            prev_focused_input_node = focused_input_node;
                            const click_navigated = handleClick(
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
                                storage_ptr,
                                surface.width,
                                surface.height,
                                &focused_input_node,
                                &form_input,
                            );
                            // Dispatch focus/blur events when focused element changes
                            if (focused_input_node != prev_focused_input_node) {
                                dom_api.active_element = focused_input_node;
                                if (page.js_rt) |*js_rt| {
                                    if (prev_focused_input_node) |prev_node| {
                                        // Fire 'change' event on blur (value may have changed)
                                        _ = events.dispatchEvent(js_rt.ctx, prev_node, "change");
                                        _ = events.dispatchEvent(js_rt.ctx, prev_node, "blur");
                                        js_rt.executePending();
                                    }
                                    if (focused_input_node) |new_node| {
                                        _ = events.dispatchEvent(js_rt.ctx, new_node, "focus");
                                        js_rt.executePending();
                                    }
                                }
                            }
                            // Update tab title; record history only on real navigation (link/form submit)
                            if (current_url) |cu| {
                                tab_mgr.updateActiveUrl(cu);
                                const active_pg_title = activePageState(&tab_mgr, &page_states);
                                const click_title = if (active_pg_title) |pgt| (if (pgt.doc) |*d| extractTitle(d) else null) else null;
                                tab_mgr.updateActiveTitle(click_title orelse cu);
                                if (click_navigated) {
                                    recordHistoryIfNotPrivate(storage_ptr, &tab_mgr, cu, click_title orelse cu);
                                }
                            }
                        }
                        continue;
                    }
                    if (key == nsfb_c.NSFB_KEY_MOUSE_4 or key == nsfb_c.NSFB_KEY_MOUSE_5) {
                        const active_pg = activePageState(&tab_mgr, &page_states);
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
                                                    const xim_pg2 = activePageState(&tab_mgr, &page_states);
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
                                const active_pg_fb = activePageState(&tab_mgr, &page_states);
                                if (active_pg_fb) |pg| {
                                    find_bar.performSearch(pg.root_box);
                                }
                                needs_repaint = true;
                            },
                            .next_match => {
                                find_bar.nextMatch();
                                if (find_bar.currentMatchY()) |match_y| {
                                    centerScrollOnMatchY(&scroll_y, surface.height, match_y);
                                }
                                needs_repaint = true;
                            },
                            .prev_match => {
                                find_bar.prevMatch();
                                if (find_bar.currentMatchY()) |match_y| {
                                    centerScrollOnMatchY(&scroll_y, surface.height, match_y);
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
                            const kd_pg = activePageState(&tab_mgr, &page_states);
                            if (kd_pg) |pg| {
                                if (pg.js_rt) |*js_rt| {
                                    _ = events.dispatchKeyboardEvent(js_rt.ctx, focused_input_node.?, "keydown", key);
                                    js_rt.executePending();
                                }
                            }
                        }
                        if (key == nsfb_c.NSFB_KEY_TAB) {
                            const active_pg_for_tab = activePageState(&tab_mgr, &page_states);
                            if (active_pg_for_tab) |pg_tab| {
                                focused_input_node = focusNextTextInput(pg_tab, focused_input_node, shift_held);
                                if (focused_input_node) |next_node| {
                                    const next_dn = DomNode{ .lxb_node = next_node };
                                    const current_value = next_dn.getAttribute("value") orelse "";
                                    form_input.setText(current_value);
                                    url_input.focused = false;
                                }
                            } else {
                                focused_input_node = null;
                            }
                            needs_repaint = true;
                            continue;
                        }
                        const form_result = form_input.handleKey(key, shift_held);
                        switch (form_result) {
                            .submit => {
                                // Enter pressed: submit the form
                                const pg = activePageState(&tab_mgr, &page_states) orelse continue;
                                const fi_node = focused_input_node.?;
                                const fi_form = findParentForm(fi_node) orelse continue;
                                if (submitForm(allocator, fi_form, fi_node, &form_input, current_url, &loader, &fonts, pg, storage_ptr, surface.width, surface.height)) |nav_url| {
                                    defer allocator.free(nav_url);
                                    url_input.setText(nav_url);
                                    url_input.focused = false;
                                    focused_input_node = null;
                                    status_text = "Loading...";
                                    needs_repaint = true;

                                    truncateForwardHistory(allocator, &history, history_pos);
                                    _ = pushHistoryNavigationUrl(allocator, &history, &history_pos, nav_url);
                                    if (current_url) |old| allocator.free(old);
                                    current_url = allocator.dupe(u8, nav_url) catch null;
                                    tab_mgr.updateActiveUrl(nav_url);
                                    tab_mgr.updateActiveTitle(nav_url);
                                    recordHistoryIfNotPrivate(storage_ptr, &tab_mgr, nav_url, nav_url);
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
                                    const input_pg = activePageState(&tab_mgr, &page_states);
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

                                    const pg = activePageState(&tab_mgr, &page_states) orelse continue;
                                    if (navigateTo(allocator, &loader, url_z, &fonts, pg, storage_ptr, surface.width, surface.height)) {
                                        status_text = "Done";
                                        scroll_y = 0;
                                        scroll_x = 0;
                                        url_input.focused = false;

                                        truncateForwardHistory(allocator, &history, history_pos);
                                        _ = pushHistoryNavigationUrl(allocator, &history, &history_pos, nav_target);
                                        if (current_url) |old| allocator.free(old);
                                        current_url = allocator.dupe(u8, nav_target) catch null;

                                        // Update tab URL and extract page title
                                        tab_mgr.updateActiveUrl(nav_target);
                                        const page_title = if (pg.doc) |*d| extractTitle(d) else null;
                                        tab_mgr.updateActiveTitle(page_title orelse nav_target);

                                        recordHistoryIfNotPrivate(storage_ptr, &tab_mgr, nav_target, page_title orelse nav_target);
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
                            const active_pg2 = activePageState(&tab_mgr, &page_states);
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
                        const ku_pg = activePageState(&tab_mgr, &page_states);
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

                    // Dispatch mousemove to JS if in content area
                    if (mouse_y >= chrome.content_y and mouse_y < surface.height - chrome.status_bar_height) {
                        const pg_move = activePageState(&tab_mgr, &page_states);
                        if (pg_move) |p_move| {
                            if (p_move.js_rt) |*js_rt| {
                                if (p_move.root_box) |root| {
                                    const lx_m = @as(f32, @floatFromInt(mouse_x)) + scroll_x;
                                    const ly_m = @as(f32, @floatFromInt(mouse_y - chrome.content_y)) + scroll_y;
                                    const hit_result_hover = hit_test_mod.hitTest(root, .{ .x = lx_m, .y = ly_m });
                                    if (hit_result_hover.dom_node) |dn| {
                                        const mnode: *lxb.lxb_dom_node_t = dn.lxb_node;
                                        // Update hover state for CSS :hover
                                        if (dom_api.hovered_element != mnode) {
                                            // Save pre-hover styles for transitions
                                            if (p_move.anim_state) |*as| {
                                                saveTransitionSnapshot(p_move, as, mnode);
                                            }
                                            dom_api.hovered_element = mnode;
                                            // Restyle to apply :hover CSS rules
                                            restylePage(p_move, allocator, &fonts, surface.width, surface.height);
                                            // Start transitions for changed properties
                                            if (p_move.anim_state) |*as| {
                                                startHoverTransitions(p_move, as);
                                            }
                                            needs_repaint = true;
                                        }
                                        _ = events.dispatchMouseEvent(js_rt.ctx, mnode, "mousemove", mouse_x, mouse_y - chrome.content_y, 0);
                                        js_rt.executePending();
                                    } else {
                                        if (dom_api.hovered_element != null) {
                                            // Save pre-unhover styles for transitions
                                            if (p_move.anim_state) |*as| {
                                                saveTransitionSnapshot(p_move, as, dom_api.hovered_element.?);
                                            }
                                            dom_api.hovered_element = null;
                                            restylePage(p_move, allocator, &fonts, surface.width, surface.height);
                                            if (p_move.anim_state) |*as| {
                                                startHoverTransitions(p_move, as);
                                            }
                                            needs_repaint = true;
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        if (dom_api.hovered_element != null) {
                            dom_api.hovered_element = null;
                            needs_repaint = true;
                        }
                    }

                    // Update cursor shape based on what's under the mouse
                    if (mouse_y >= chrome.content_y and mouse_y < surface.height - chrome.status_bar_height) {
                        const layout_x = @as(f32, @floatFromInt(mouse_x)) + scroll_x;
                        const layout_y = @as(f32, @floatFromInt(mouse_y - chrome.content_y)) + scroll_y;
                        const pg = activePageState(&tab_mgr, &page_states);
                        if (pg) |p| {
                            if (p.root_box) |root| {
                                const move_result = hit_test_mod.hitTest(root, .{ .x = layout_x, .y = layout_y });
                                if (move_result.link_url != null) {
                                    surface.setCursor(.pointer);
                                } else if (move_result.form_element) |fe| {
                                    const ftag = fe.tagName() orelse "";
                                    var cursor_set = false;
                                    if (std.mem.eql(u8, ftag, "input")) {
                                        const itype = fe.getAttribute("type") orelse "text";
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
                                    if (!cursor_set) {
                                        surface.setCursor(.arrow);
                                    }
                                } else {
                                    surface.setCursor(.arrow);
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
    if (storage_ptr) |s| {
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

fn collectFocusableNodes(box: *const Box, out: *std.ArrayListUnmanaged(*lxb.lxb_dom_node_t)) void {
    if (box.dom_node) |dn| {
        const node = dn.lxb_node;
        if (isTextFormElement(node)) {
            out.append(std.heap.c_allocator, node) catch {};
        }
    }
    for (box.children.items) |child| {
        collectFocusableNodes(child, out);
    }
}

fn focusNextTextInput(page: *PageState, current: ?*lxb.lxb_dom_node_t, reverse: bool) ?*lxb.lxb_dom_node_t {
    const root = page.root_box orelse return null;
    var nodes: std.ArrayListUnmanaged(*lxb.lxb_dom_node_t) = .empty;
    defer nodes.deinit(std.heap.c_allocator);
    collectFocusableNodes(root, &nodes);
    if (nodes.items.len == 0) return null;

    const idx_opt: ?usize = if (current) |cur| blk: {
        for (nodes.items, 0..) |n, i| {
            if (n == cur) break :blk i;
        }
        break :blk null;
    } else null;

    if (reverse) {
        if (idx_opt) |idx| {
            const next_idx = if (idx == 0) nodes.items.len - 1 else idx - 1;
            return nodes.items[next_idx];
        }
        return nodes.items[nodes.items.len - 1];
    } else {
        if (idx_opt) |idx| {
            const next_idx = if (idx + 1 >= nodes.items.len) 0 else idx + 1;
            return nodes.items[next_idx];
        }
        return nodes.items[0];
    }
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

/// Dispatch mousedown → mouseup → click at the hit target; restyle if DOM dirty.
/// Returns true if the click default action was prevented.
fn clickJsMouseSequencePrevented(
    allocator: std.mem.Allocator,
    page: *PageState,
    js_rt: *JsRuntime,
    root_box: *const Box,
    layout_x: f32,
    layout_y: f32,
    mouse_x: i32,
    mouse_y_content: i32,
    fonts: *painter_mod.FontCache,
    win_w: i32,
    win_h: i32,
    needs_repaint: *bool,
) bool {
    const js_hit = hit_test_mod.hitTest(root_box, .{ .x = layout_x, .y = layout_y });
    if (js_hit.dom_node) |dn| {
        const node: *lxb.lxb_dom_node_t = dn.lxb_node;
        _ = events.dispatchMouseEvent(js_rt.ctx, node, "mousedown", mouse_x, mouse_y_content, 0);
        js_rt.executePending();
        _ = events.dispatchMouseEvent(js_rt.ctx, node, "mouseup", mouse_x, mouse_y_content, 0);
        js_rt.executePending();
        const click_allowed = events.dispatchMouseEvent(js_rt.ctx, node, "click", mouse_x, mouse_y_content, 0);
        js_rt.executePending();
        if (dom_api.dom_dirty) {
            dom_api.dom_dirty = false;
            restylePage(page, allocator, fonts, win_w, win_h);
            needs_repaint.* = true;
        }
        return !click_allowed;
    }
    return false;
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
) bool {
    // Click in URL bar?
    if (my < chrome.url_bar_height) {
        url_input.focused = true;
        focused_input_node.* = null; // unfocus form input
        needs_repaint.* = true;
        return false;
    }

    // Click in status bar? (ignore)
    if (my >= win_h - chrome.status_bar_height) return false;

    // Click in content area — unfocus URL bar
    url_input.focused = false;

    // Hit test for links and JS events
    if (page.root_box) |root_box| {
        // Convert screen coords to layout coords
        const layout_x: f32 = @as(f32, @floatFromInt(mx)) + scroll_x.*;
        const layout_y: f32 = @as(f32, @floatFromInt(my - chrome.content_y)) + scroll_y.*;

        std.debug.print("[click] screen=({d},{d}) layout=({d:.0},{d:.0}) scroll=({d:.0},{d:.0}) content_y={d}\n", .{ mx, my, layout_x, layout_y, scroll_x.*, scroll_y.*, chrome.content_y });

        // Dispatch mouse events to JavaScript: mousedown → mouseup → click
        const click_prevented = blk: {
            if (page.js_rt) |*js_rt| {
                break :blk clickJsMouseSequencePrevented(
                    allocator,
                    page,
                    js_rt,
                    root_box,
                    layout_x,
                    layout_y,
                    mx,
                    my - chrome.content_y,
                    fonts,
                    win_w,
                    win_h,
                    needs_repaint,
                );
            }
            break :blk false;
        };

        // If JS called preventDefault() on click, skip default actions
        if (click_prevented) return false;

        // Re-read root_box in case restylePage replaced it
        const current_root = page.root_box orelse return false;
        const click_result = hit_test_mod.hitTest(current_root, .{ .x = layout_x, .y = layout_y });
        if (click_result.dom_node) |dn| {
            const hdn = dn;
            std.debug.print("[click] hitNode tag={s} link={s}\n", .{ hdn.tagName() orelse "?", if (click_result.link_url) |l| l else "(none)" });
        } else {
            std.debug.print("[click] hitNode=null link={s}\n", .{if (click_result.link_url) |l| l else "(none)"});
        }

        // Check for form element clicks before link navigation
        if (click_result.dom_node) |dn| {
            const node: *lxb.lxb_dom_node_t = dn.lxb_node;
            const dom_node = dn;

            // Form element already found by unified hitTest
            if (click_result.form_element) |fe| {
                std.debug.print("[form] Found form element: {s}\n", .{fe.tagName() orelse "?"});
            } else {
                std.debug.print("[form] No form element found near {s}\n", .{dom_node.tagName() orelse "?"});
            }

            // Also check via findFormElement for children (hitTest only walks up)
            const legacy_form = findFormElement(node);
            const form_node_dn = click_result.form_element orelse if (legacy_form) |lf| DomNode{ .lxb_node = lf } else null;

            if (form_node_dn) |fdom| {
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
                        focused_input_node.* = fdom.lxb_node;
                        const current_value = fdom.getAttribute("value") orelse "";
                        form_input.setText(current_value);
                        std.debug.print("[form] Focused input type={s} value=\"{s}\"\n", .{ input_type, current_value });
                        needs_repaint.* = true;
                        return false;
                    } else if (is_button_input) {
                        // Submit button clicked — submit the form
                        std.debug.print("[form] Submit button clicked\n", .{});
                        const btn_form = findParentForm(fdom.lxb_node) orelse return false;
                        if (submitForm(allocator, btn_form, focused_input_node.*, form_input, current_url.*, loader, fonts, page, storage, win_w, win_h)) |nav_url| {
                            defer allocator.free(nav_url);
                            url_input.setText(nav_url);
                            url_input.focused = false;
                            focused_input_node.* = null;
                            status_text.* = "Done";
                            scroll_y.* = 0;
                            scroll_x.* = 0;

                            truncateForwardHistory(allocator, history, history_pos.*);
                            if (!pushHistoryNavigationUrl(allocator, history, history_pos, nav_url)) return false;
                            if (current_url.*) |old| allocator.free(old);
                            current_url.* = allocator.dupe(u8, nav_url) catch null;
                            needs_repaint.* = true;
                            return true;
                        }
                        needs_repaint.* = true;
                        return false;
                    }
                } else if (std.mem.eql(u8, ftag, "textarea")) {
                    // <textarea> — focus for text input (Google search uses textarea)
                    focused_input_node.* = fdom.lxb_node;
                    const current_value = fdom.getAttribute("value") orelse "";
                    form_input.setText(current_value);
                    std.debug.print("[form] Focused textarea\n", .{});
                    needs_repaint.* = true;
                    return false;
                } else if (std.mem.eql(u8, ftag, "button")) {
                    // <button> click — submit the form
                    std.debug.print("[form] <button> clicked\n", .{});
                    const button_form = findParentForm(fdom.lxb_node) orelse return false;
                    if (submitForm(allocator, button_form, focused_input_node.*, form_input, current_url.*, loader, fonts, page, storage, win_w, win_h)) |nav_url| {
                        defer allocator.free(nav_url);
                        url_input.setText(nav_url);
                        url_input.focused = false;
                        focused_input_node.* = null;
                        status_text.* = "Done";
                        scroll_y.* = 0;
                        scroll_x.* = 0;

                        truncateForwardHistory(allocator, history, history_pos.*);
                        if (!pushHistoryNavigationUrl(allocator, history, history_pos, nav_url)) return false;
                        if (current_url.*) |old| allocator.free(old);
                        current_url.* = allocator.dupe(u8, nav_url) catch null;
                        needs_repaint.* = true;
                        return true;
                    }
                    needs_repaint.* = true;
                    return false;
                }
            }

            // If clicked on something that's not a form element, unfocus
            // dom_node used in debug print above
            focused_input_node.* = null;
        } else {
            focused_input_node.* = null;
        }

        if (click_result.link_url) |link_href| {
            // Resolve URL
            const base = if (current_url.*) |u| u else "";
            const resolved = resolveUrl(allocator, base, link_href) catch return false;
            defer allocator.free(resolved);

            std.debug.print("Navigating to: {s}\n", .{resolved});

            url_input.setText(resolved);
            status_text.* = "Loading...";
            needs_repaint.* = true;

            if (navigateTo(allocator, loader, resolved, fonts, page, storage, win_w, win_h)) {
                status_text.* = "Done";
                scroll_y.* = 0;
                scroll_x.* = 0;

                truncateForwardHistory(allocator, history, history_pos.*);
                if (!pushHistoryNavigationUrl(allocator, history, history_pos, resolved)) return false;

                if (current_url.*) |old| allocator.free(old);
                const cu = allocator.alloc(u8, resolved.len) catch null;
                if (cu) |c| {
                    @memcpy(c, resolved);
                    current_url.* = c;
                }
                needs_repaint.* = true;
                return true;
            } else {
                status_text.* = "Failed";
            }
            needs_repaint.* = true;
            return false;
        } else {
            needs_repaint.* = true; // repaint to show unfocused URL bar
            return false;
        }
    } else {
        needs_repaint.* = true;
        return false;
    }
}

// Form element detection and data collection functions are now in core/form_handler.zig

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
    const method_str = form_dn.getAttribute("method") orelse "get";
    const is_post = std.mem.eql(u8, method_str, "post") or std.mem.eql(u8, method_str, "POST");

    std.debug.print("[form] Submitting form method=\"{s}\" action=\"{s}\"\n", .{ method_str, action });

    // Collect form data
    const query_string = collectFormData(allocator, form_node, focused_node, form_text) orelse return null;
    defer allocator.free(query_string);

    std.debug.print("[form] Form data: {s}\n", .{query_string});

    // Build full URL: resolve action against current URL
    const base = if (current_url) |u| u else "";
    const resolved_action = resolveUrl(allocator, base, action) catch return null;
    defer allocator.free(resolved_action);

    if (is_post) {
        // POST: send form data to action URL, navigate to result
        const url_z = allocator.allocSentinel(u8, resolved_action.len, 0) catch return null;
        @memcpy(url_z, resolved_action);

        std.debug.print("[form] POST to: {s}\n", .{resolved_action});

        var headers_arr = [_][2][]const u8{
            .{ "Content-Type", "application/x-www-form-urlencoded" },
        };
        var response = loader.client.request(allocator, url_z, .{
            .method = "POST",
            .body = query_string,
            .headers = &headers_arr,
            .timeout_secs = 15,
        }) catch {
            allocator.free(url_z);
            return null;
        };

        // Check for redirect (3xx) — follow it with GET
        if (response.status_code >= 300 and response.status_code < 400) {
            // For redirect, just navigate to action URL (simplified)
            response.deinit();
            if (navigateTo(allocator, loader, url_z, fonts, page, storage, win_w, win_h)) {
                const final_url = allocator.dupe(u8, resolved_action) catch {
                    allocator.free(url_z);
                    return null;
                };
                allocator.free(url_z);
                return final_url;
            }
            allocator.free(url_z);
            return null;
        }

        // Non-redirect: load the response body as HTML
        page.deinit();

        const html = allocator.alloc(u8, response.body.len) catch {
            response.deinit();
            allocator.free(url_z);
            return null;
        };
        @memcpy(html, response.body);
        response.deinit();

        // Parse and load using the same flow as navigateTo
        const parse_doc = Document.parse(html) catch {
            allocator.free(html);
            allocator.free(url_z);
            return null;
        };

        // Set up page state with parsed document
        page.doc = parse_doc;

        // Style and layout the POST response
        restylePage(page, allocator, fonts, win_w, win_h);

        // Execute JS on the POST result page
        if (page.doc) |*pd| {
            initPageJs(pd, page, allocator, loader, resolved_action, fonts);
        }

        const final_url = allocator.dupe(u8, resolved_action) catch {
            allocator.free(url_z);
            return null;
        };
        allocator.free(url_z);
        return final_url;
    }

    // GET: append query string to URL
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
    pub const kotori_dom_api = @import("kotori_dom");
    pub const kotori_rt = @import("kotori_runtime");
};

// ── WebDriver Command Handler ───────────────────────────────────────

const webdriver = @import("net/webdriver.zig");

fn webDriverStringResponse(allocator: std.mem.Allocator, value: []const u8) webdriver.Response {
    const body = std.fmt.allocPrint(allocator, "{{\"value\":{f}}}", .{std.json.fmt(value, .{})}) catch return .{ .body = "{\"value\":\"\"}" };
    return .{ .body = body, .allocated = true };
}

fn webDriverRawValueResponse(allocator: std.mem.Allocator, raw_json: []const u8) webdriver.Response {
    const body = std.fmt.allocPrint(allocator, "{{\"value\":{s}}}", .{raw_json}) catch return .{ .body = "{\"value\":null}" };
    return .{ .body = body, .allocated = true };
}

fn webDriverStringArrayResponse(allocator: std.mem.Allocator, values: []const []const u8) webdriver.Response {
    const body = std.fmt.allocPrint(allocator, "{{\"value\":{f}}}", .{std.json.fmt(values, .{})}) catch return .{ .body = "{\"value\":[]}" };
    return .{ .body = body, .allocated = true };
}

fn webDriverEvalResponse(allocator: std.mem.Allocator, val: []const u8) webdriver.Response {
    if (std.mem.eql(u8, val, "undefined")) return webDriverRawValueResponse(allocator, "null");
    const raw = val.len > 0 and (std.mem.eql(u8, val, "null") or
        std.mem.eql(u8, val, "true") or
        std.mem.eql(u8, val, "false") or
        (val[0] >= '0' and val[0] <= '9') or
        val[0] == '-' or val[0] == '{' or val[0] == '[' or val[0] == '"');
    if (raw) return webDriverRawValueResponse(allocator, val);
    return webDriverStringResponse(allocator, val);
}

test "webDriverStringResponse escapes JSON strings without fixed buffer cap" {
    const resp = webDriverStringResponse(std.testing.allocator, "a\"b\\c\n");
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expect(resp.allocated);
    try std.testing.expectEqualStrings("{\"value\":\"a\\\"b\\\\c\\n\"}", resp.body);

    const long = try std.testing.allocator.alloc(u8, 5000);
    defer std.testing.allocator.free(long);
    @memset(long, 'x');
    const long_resp = webDriverStringResponse(std.testing.allocator, long);
    defer if (long_resp.allocated) std.testing.allocator.free(@constCast(long_resp.body));
    try std.testing.expect(long_resp.body.len > 5000);

    const empty = webDriverEvalResponse(std.testing.allocator, "");
    defer if (empty.allocated) std.testing.allocator.free(@constCast(empty.body));
    try std.testing.expectEqualStrings("{\"value\":\"\"}", empty.body);

    const undef = webDriverEvalResponse(std.testing.allocator, "undefined");
    defer if (undef.allocated) std.testing.allocator.free(@constCast(undef.body));
    try std.testing.expectEqualStrings("{\"value\":null}", undef.body);

    const handles = [_][]const u8{ "window-0", "quote\"slash\\" };
    const arr = webDriverStringArrayResponse(std.testing.allocator, &handles);
    defer if (arr.allocated) std.testing.allocator.free(@constCast(arr.body));
    try std.testing.expectEqualStrings("{\"value\":[\"window-0\",\"quote\\\"slash\\\\\"]}", arr.body);
}

fn handleWebDriverCommand(
    cmd: webdriver.Command,
    allocator: std.mem.Allocator,
    loader_ptr: *Loader,
    fonts: *painter_mod.FontCache,
    page_states: *std.ArrayListUnmanaged(PageState),
    tab_mgr: *TabManager,
    surface: *Surface,
    needs_repaint: *bool,
    scroll_y: *f32,
    scroll_x: *f32,
    storage: ?*Storage,
    window_mgr: *WindowManager,
) webdriver.Response {
    switch (cmd.tag) {
        .navigate => {
            const url = cmd.payload;
            if (url.len == 0) return .{ .status = 400, .body = "{\"value\":{\"error\":\"invalid argument\",\"message\":\"empty url\",\"stacktrace\":\"\"}}" };

            // about:blank is a no-op navigation
            if (std.mem.eql(u8, url, "about:blank")) {
                return .{ .body = "{\"value\":null}" };
            }

            // Create sentinel-terminated copy for navigateTo (NOT freed - navigateTo may store reference)
            const url_z = allocator.allocSentinel(u8, url.len, 0) catch return .{ .status = 500, .body = "{\"value\":{\"error\":\"unknown error\",\"message\":\"OOM\",\"stacktrace\":\"\"}}" };
            @memcpy(url_z, url);

            if (page_states.items.len > 0) {
                if (navigateTo(allocator, loader_ptr, url_z, fonts, &page_states.items[window_mgr.getActiveTabIndex()], storage, surface.width, surface.height)) {
                    scroll_y.* = 0;
                    scroll_x.* = 0;
                    needs_repaint.* = true;
                    // Duplicate URL before responding (cmd.payload points into WebDriver recv_buf)
                    if (allocator.dupe(u8, url)) |u| {
                        tab_mgr.updateActiveUrl(u);
                    } else |_| {}
                    return .{ .body = "{\"value\":null}" };
                }
            }
            return .{ .status = 500, .body = "{\"value\":{\"error\":\"unknown error\",\"message\":\"navigation failed\",\"stacktrace\":\"\"}}" };
        },
        .get_url => {
            // Return current URL
            if (tab_mgr.getActiveTab()) |tab| {
                return webDriverStringResponse(allocator, tab.url);
            }
            return .{ .body = "{\"value\":\"about:blank\"}" };
        },
        .get_title => {
            if (page_states.items.len > 0) {
                if (page_states.items[window_mgr.getActiveTabIndex()].doc) |*d| {
                    const title = extractTitle(d);
                    if (title) |t| {
                        return webDriverStringResponse(allocator, t);
                    }
                }
            }
            return .{ .body = "{\"value\":\"\"}" };
        },
        .execute_sync => {
            const script = cmd.payload;
            const active_idx = window_mgr.getActiveTabIndex();
            if (page_states.items.len > 0 and active_idx < page_states.items.len) {
                if (page_states.items[active_idx].js_rt) |*js_rt| {
                    // Wrap script: extract args from body JSON, apply with args
                    const body_json = cmd.payload2;
                    const wrapped = std.fmt.allocPrint(allocator,
                        \\(function() {{
                        \\  var __body = {s};
                        \\  var __args = (__body && __body.args) ? __body.args : [];
                        \\  return (function() {{ {s} }}).apply(null, __args);
                        \\}})()
                    , .{ body_json, script }) catch return .{ .status = 500, .body = "{\"value\":null}" };
                    defer allocator.free(wrapped);

                    std.debug.print("[WD-exec] script({d}): {s}\n", .{ wrapped.len, wrapped[0..@min(200, wrapped.len)] });
                    const result = js_rt.eval(wrapped);
                    js_rt.executePending();

                    switch (result) {
                        .ok => |val| {
                            return webDriverEvalResponse(allocator, val);
                        },
                        .err => |e| {
                            std.debug.print("[WD-exec] ERR: {s}\n", .{e[0..@min(200, e.len)]});
                            return .{ .status = 500, .body = "{\"value\":{\"error\":\"javascript error\",\"message\":\"script error\",\"stacktrace\":\"\"}}" };
                        },
                    }
                }
            }
            return .{ .status = 500, .body = "{\"value\":{\"error\":\"no such window\",\"message\":\"No JS runtime\",\"stacktrace\":\"\"}}" };
        },
        .execute_async => {
            const script = cmd.payload;
            const async_idx = window_mgr.getActiveTabIndex();
            std.debug.print("[WD-async-entry] idx={d} len={d}\n", .{ async_idx, page_states.items.len });
            if (page_states.items.len > 0 and async_idx < page_states.items.len) {
                const has_rt = page_states.items[async_idx].js_rt != null;
                if (!has_rt) {
                    std.debug.print("[WD-async] idx={d} len={d} NO JS RT\n", .{ async_idx, page_states.items.len });
                }
                if (page_states.items[async_idx].js_rt) |*js_rt| {
                    // Inject callback into global scope, execute script, return immediately
                    // The callback sets window.__wd_async_done and window.__wd_async_result
                    // The event loop will poll for completion and send the response
                    // Extract args from the full request body JSON
                    const body_json = cmd.payload2;
                    const setup = std.fmt.allocPrint(allocator,
                        \\window.__wd_async_done = false;
                        \\window.__wd_async_result = null;
                        \\(function() {{
                        \\  var __cb = function(r) {{
                        \\    window.__wd_async_done = true;
                        \\    window.__wd_async_result = (r === undefined || r === null) ? null : r;
                        \\  }};
                        \\  var __body = {s};
                        \\  var __args = (__body && __body.args) ? __body.args.slice() : [];
                        \\  __args.push(__cb);
                        \\  (function() {{ {s} }}).apply(null, __args);
                        \\}})();
                    , .{ body_json, script }) catch return .{ .status = 500, .body = "{\"value\":null}" };
                    defer allocator.free(setup);

                    _ = js_rt.eval(setup);
                    js_rt.executePending();

                    // Check once if the callback completed synchronously
                    js_rt.executePending();
                    _ = web_api.tickTimers(js_rt.ctx);
                    js_rt.executePending();

                    const check = js_rt.eval("window.__wd_async_done ? JSON.stringify(window.__wd_async_result) : null");
                    switch (check) {
                        .ok => |val| {
                            if (!std.mem.eql(u8, val, "null") and !std.mem.eql(u8, val, "undefined") and val.len > 0) {
                                return webDriverRawValueResponse(allocator, val);
                            }
                        },
                        .err => {},
                    }
                    // Not completed synchronously — return null
                    // wptrunner will handle the timeout on its side
                    return .{ .body = "{\"value\":null}" };
                }
            }
            return .{ .status = 500, .body = "{\"value\":{\"error\":\"no such window\",\"message\":\"No JS runtime\",\"stacktrace\":\"\"}}" };
        },
        .screenshot => {
            // Dump framebuffer to temp PNG, read, base64-encode
            const tmp_path = "/tmp/suzume-wd-screenshot.png";
            // Paint first
            if (page_states.items.len > 0) {
                const pg = &page_states.items[window_mgr.getActiveTabIndex()];
                if (pg.root_box) |root_box| {
                    surface.fillRect(0, 0, surface.width, surface.height, 0xFFFFFFFF);
                    const ic_ptr: ?*ImageCache = if (pg.image_cache) |*ic| ic else null;
                    painter_mod.paint(root_box, surface, fonts, 0, 0, 0, surface.height, ic_ptr);
                    surface.update();
                }
            }
            if (surface.dumpToPng(tmp_path)) {
                const file = std.Io.Dir.cwd().openFile(env.ioOrPanic(), tmp_path, .{}) catch return .{ .status = 500, .body = "{\"value\":\"\"}" };
                defer file.close(env.ioOrPanic());
                const png_data = env.readToEndAlloc(file, allocator, 10 * 1024 * 1024) catch return .{ .status = 500, .body = "{\"value\":\"\"}" };
                defer allocator.free(png_data);

                const base64_enc = std.base64.standard.Encoder;
                const b64_len = base64_enc.calcSize(png_data.len);
                // Build response: {"value":"<base64>"}
                const total_len = 10 + b64_len + 2; // {"value":"..."}
                const resp_mem = allocator.alloc(u8, total_len) catch return .{ .status = 500, .body = "{\"value\":\"\"}" };
                @memcpy(resp_mem[0..10], "{\"value\":\"");
                _ = base64_enc.encode(resp_mem[10..][0..b64_len], png_data);
                @memcpy(resp_mem[10 + b64_len ..][0..2], "\"}");
                return .{ .body = resp_mem, .allocated = true };
            }
            return .{ .status = 500, .body = "{\"value\":\"\"}" };
        },
        .close_window, .noop => {
            return .{ .body = "{\"value\":null}" };
        },
        .window_new => {
            // Create a new window (tab + PageState + window handle)
            const new_idx = page_states.items.len;
            var new_page = PageState{};
            // Initialize a minimal JS runtime for the new window (required for WebDriver execute)
            var js_rt = JsRuntime.init() catch return .{ .status = 500, .body = "{\"value\":{\"error\":\"unknown error\",\"message\":\"JS init failed\",\"stacktrace\":\"\"}}" };
            dom_api.registerDomApis(js_rt.rt, js_rt.ctx, @ptrCast(js_rt.ctx)); // dummy doc ptr
            web_api.registerWebApis(&js_rt);
            new_page.js_rt = js_rt;
            page_states.append(allocator, new_page) catch return .{ .status = 500, .body = "{\"value\":{\"error\":\"unknown error\",\"message\":\"OOM\",\"stacktrace\":\"\"}}" };
            const new_handle = window_mgr.createWindow(
                window_mgr.getActiveHandle(),
                "",
                new_idx,
            ) catch return .{ .status = 500, .body = "{\"value\":{\"error\":\"unknown error\",\"message\":\"window create failed\",\"stacktrace\":\"\"}}" };
            const body = std.fmt.allocPrint(allocator, "{{\"value\":{{\"handle\":{f},\"type\":\"tab\"}}}}", .{std.json.fmt(new_handle, .{})}) catch return .{ .body = "{\"value\":null}" };
            return .{ .body = body, .allocated = true };
        },
        .window_switch => {
            const handle = cmd.payload;
            if (window_mgr.switchTo(handle)) {
                tab_mgr.active_index = window_mgr.getActiveTabIndex();
                return .{ .body = "{\"value\":null}" };
            }
            return .{ .status = 404, .body = "{\"value\":{\"error\":\"no such window\",\"message\":\"Window not found\",\"stacktrace\":\"\"}}" };
        },
        .window_close => {
            if (window_mgr.getActiveHandle()) |handle| {
                window_mgr.closeWindow(handle);
            }
            // Return remaining handles
            var handles_buf: [16][]const u8 = undefined;
            const count = window_mgr.getHandles(&handles_buf);
            if (count > 0) {
                return webDriverStringArrayResponse(allocator, handles_buf[0..count]);
            }
            return .{ .body = "{\"value\":[]}" };
        },
        .get_window_handle => {
            if (window_mgr.getActiveHandle()) |handle| {
                return webDriverStringResponse(allocator, handle);
            }
            return .{ .body = "{\"value\":\"\"}" };
        },
        .get_window_handles => {
            var handles_buf: [16][]const u8 = undefined;
            const count = window_mgr.getHandles(&handles_buf);
            return webDriverStringArrayResponse(allocator, handles_buf[0..count]);
        },
    }
}
