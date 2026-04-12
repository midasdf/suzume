// Per-frame state for iframe support.
// Each JSContext (top-level or iframe) has a FrameState attached via JS_SetContextOpaque.
// This replaces global singletons (g_document, g_root_box, g_styles, etc.)

const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;
const Box = @import("../layout/box.zig").Box;
const cascade_mod = @import("../css/cascade.zig");

pub const MAX_IFRAME_DEPTH: u32 = 5;
pub const MAX_IFRAME_COUNT: u32 = 32;

pub const ReadyState = enum { loading, interactive, complete };

pub const FrameState = struct {
    // DOM
    document: ?*anyopaque = null, // Lexbor HTML document
    dom_dirty: bool = false,
    mutation_observers_pending: bool = false,
    active_element: ?*anyopaque = null, // lxb_dom_node_t
    hovered_element: ?*anyopaque = null,

    // Layout
    root_box: ?*const Box = null,
    styles: ?*const cascade_mod.StyleMap = null,
    custom_props: ?*const cascade_mod.CustomPropMap = null,
    viewport_width: f32 = 800,
    viewport_height: f32 = 600,

    // Scroll
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    pending_scroll_x: ?f32 = null,
    pending_scroll_y: ?f32 = null,

    // Navigation
    current_url: ?[]const u8 = null,
    ready_state: ReadyState = .loading,
    is_xml: bool = false, // True for XML/XHTML/SVG iframe documents

    // Frame hierarchy
    parent_frame: ?*FrameState = null,
    ctx: ?*qjs.JSContext = null,
    depth: u32 = 0, // 0 = top-level
};

/// Get FrameState from a JSContext's opaque pointer.
pub fn getFrameStateFromCtx(ctx: *qjs.JSContext) ?*FrameState {
    const raw = qjs.JS_GetContextOpaque(ctx);
    if (raw) |ptr| {
        return @ptrCast(@alignCast(ptr));
    }
    return null;
}
