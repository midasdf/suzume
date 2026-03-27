# iframe Full Implementation Design

## Problem

iframe is the single largest WPT blocker (~1500+ subtests). Tests use `<iframe>` to create isolated documents for cross-document DOM testing. suzume currently has no iframe support — `<iframe>` elements are parsed but have no contentDocument, contentWindow, or rendering.

## Requirements

- **Rendering**: iframe content renders inside parent page at correct position/size
- **JS isolation**: Each iframe gets its own JS Context (same QuickJS Runtime)
- **Limit**: 5-10 concurrent iframes (RPi Zero 2W, 512MB RAM constraint)
- **DOM access**: `iframe.contentDocument`, `iframe.contentWindow` work
- **Nesting**: Iframes within iframes supported (up to depth limit)

## Architecture

### FrameState

Central per-frame state, replacing global singletons:

```zig
pub const FrameState = struct {
    document: *anyopaque,                    // Lexbor HTML document
    root_box: ?*const Box,                   // Layout box tree
    styles: ?*const cascade.CascadeResult,   // Computed styles
    viewport_width: f32,                     // iframe width
    viewport_height: f32,                    // iframe height
    current_url: ?[]const u8,               // Frame URL
    parent_frame: ?*FrameState,             // Parent (null = top-level)
    child_frames: ArrayList(*FrameState),    // Nested iframes
    ctx: *qjs.JSContext,                     // JS context for this frame
    loader: *Loader,                         // Shared resource loader
    ready_state: ReadyState,                 // loading/interactive/complete
    scroll_x: f32,                           // Frame scroll position
    scroll_y: f32,
    dom_dirty: bool,                         // Mutation flag
    allocator: Allocator,
};
```

### Global Singleton Replacement

Current architecture uses `g_document`, `g_root_box`, `g_styles` etc. as global vars. These are replaced by FrameState accessed via QuickJS Context opaque pointer:

```zig
// New helper (used by all DOM functions)
pub fn getFrameState(ctx: *qjs.JSContext) *FrameState {
    if (qjs.JS_GetContextOpaque(ctx)) |opaque| {
        return @ptrCast(@alignCast(opaque));
    }
    // Fallback to top-level frame during transition
    return &g_top_frame;
}

// Convenience
pub fn getDocument(ctx: *qjs.JSContext) *anyopaque {
    return getFrameState(ctx).document;
}
```

Migration strategy: Replace `g_document` references with `getDocument(ctx)` incrementally. The fallback ensures existing code works during transition.

### JS Context Architecture

```
QuickJS Runtime (shared, 1 per browser)
├── Context 0 (top-level page)
│   ├── window/document/location globals
│   ├── FrameState → Lexbor Doc 0
│   └── JS_SetContextOpaque → &frame_states[0]
├── Context 1 (iframe #1)
│   ├── window/document/location globals
│   ├── FrameState → Lexbor Doc 1
│   └── JS_SetContextOpaque → &frame_states[1]
└── Context 2 (iframe #2)
    ├── window/document/location globals
    ├── FrameState → Lexbor Doc 2
    └── JS_SetContextOpaque → &frame_states[2]
```

Each Context gets its own:
- `registerDomApis()` call (own prototype chain, own document object)
- `registerEventApis()` call
- `registerWebApis()` call
- Own timer list, event listeners

Shared across all Contexts:
- QuickJS Runtime (GC, memory management)
- Loader (HTTP client)
- Font cache
- Image cache

### Rendering

iframe is a **replaced element** in the layout system (like `<img>`):

1. **Layout**: iframe Box gets fixed dimensions from CSS width/height or HTML attributes (default 300x150 per spec)
2. **Internal layout**: iframe's box tree is built and laid out independently within those dimensions
3. **Paint**: During parent paint, when iframe box is reached:
   - Save clip rect
   - Set clip to iframe box content area
   - Paint iframe's box tree with offset = iframe content position
   - Restore clip rect

```
Parent paint:
  paint(body_box)
    paint(div_box)
      paint(iframe_box)  ← replaced element
        // Paint iframe's internal box tree here
        paintIframeContent(iframe_frame_state, surface, iframe_x, iframe_y, clip)
    paint(p_box)
```

### Page Load Flow

```
Lexbor parses <iframe src="url">
  ↓
detectIframeElements(doc) — DFS walk after parse
  ↓
For each <iframe>:
  1. Read src attribute
  2. loader.loadPage(src) → {html, css}
  3. Lexbor parse html → new Document
  4. JS_NewContext(rt) → new context
  5. FrameState.init(document, ctx, parent_frame)
  6. JS_SetContextOpaque(ctx, &frame_state)
  7. registerDomApis(rt, ctx, document)
  8. registerEventApis(ctx)
  9. registerWebApis(ctx)
  10. executeScripts(document, ctx, loader)
  11. cascade(document) → styles
  12. buildBoxTree(document, styles) → root_box
  13. layoutBlockVp(root_box, iframe_width, iframe_height)
  14. Store root_box in FrameState
  15. Set iframe element's contentDocument/contentWindow JS properties
  16. Mark parent dom_dirty for repaint
```

### JS API

```javascript
// HTMLIFrameElement properties
iframe.contentDocument  // → FrameState.document JS wrapper (null if cross-origin)
iframe.contentWindow    // → FrameState.ctx global object (null if cross-origin)
iframe.src              // getter/setter, setter triggers reload
iframe.width            // reflected attribute
iframe.height           // reflected attribute
iframe.name             // reflected attribute

// Cross-frame access
iframe.contentWindow.document === iframe.contentDocument  // true
iframe.contentWindow.parent === window                     // true
iframe.contentWindow.top === window.top                    // true
iframe.contentWindow.frameElement === iframe                // true
```

### Event Loop Integration

The main event loop must tick ALL active iframe contexts:

```zig
// Current (single context):
web_api.tickTimers(js_rt.ctx);
js_rt.executePending();

// New (all frames):
for (active_frames) |frame| {
    web_api.tickTimersForContext(frame.ctx);
    executePendingForContext(frame.ctx);
    if (frame.dom_dirty) {
        restyleFrame(frame);
        needs_repaint = true;
    }
}
```

### Memory Budget

Per iframe (~5-10MB):
- Lexbor Document: ~1-3MB (depends on page size)
- QuickJS Context: ~2-3MB (heap + bytecode)
- Box tree: ~0.5-1MB
- Styles: ~0.5-1MB

With 5-10 iframes: 25-100MB total. Fits in 512MB with ~200MB for main page + OS.

### Cross-Origin Policy

- Same-origin: full contentDocument/contentWindow access
- Cross-origin: contentDocument returns null, contentWindow limited to postMessage
- Origin check: compare protocol + host + port of parent URL vs iframe URL

### Nesting Limit

Max iframe depth: 5 levels. Beyond that, iframe src is not loaded (prevents recursion bombs).

## Implementation Phases

### Phase 1: FrameState + Global Replacement
- Create FrameState struct
- Implement getFrameState/getDocument helpers (with null-field fallback to globals)
- Split registerDomApis into registerClasses (once per Runtime) + registerContextApis (per Context)
- Set up JS_SetContextOpaque for top-level page
- Sync global setters (setRootBox, setStyles) to g_top_frame BEFORE module replacements
- Replace g_document → getDocument(ctx) in all DOM modules (including ~15 globals: dom_dirty, active_element, scroll, viewport, timers, etc.)
- Verify no regression

### Phase 2: iframe Element Detection + Loading
- Detect `<iframe>` in DOM tree after parse
- Handle srcdoc attribute (inline HTML, common in WPT)
- Handle no-src (about:blank) iframes
- Handle dynamic iframe creation via JS (createElement + appendChild)
- Fetch iframe src via Loader
- Parse into new Lexbor Document
- Create new JS Context + FrameState
- Fire iframe load event (critical for WPT test harnesses)

### Phase 2.5: Cross-Context Object Strategy
- Define how contentDocument/contentWindow JSValues are accessed across Contexts
- Options: proxy objects, shared document in parent context, or bridge pattern
- This must be solved before Phase 3
- Detect `<iframe>` in DOM tree after parse
- Fetch iframe src via Loader
- Parse into new Lexbor Document
- Create new JS Context + FrameState

### Phase 3: iframe JS Environment
- registerDomApis for iframe context
- Set up contentDocument/contentWindow properties
- iframe.contentWindow.parent/top/frameElement
- Script execution in iframe context

### Phase 4: iframe Layout + Rendering
- iframe as replaced element in layout (fixed dimensions)
- Build box tree for iframe content
- Paint iframe content into parent surface with clipping

### Phase 5: Event Loop + Lifecycle
- Tick timers for all active frame contexts
- Handle iframe load/error events
- iframe.src setter triggers reload
- iframe removal cleans up FrameState

### Phase 6: Cross-Origin + Security
- Origin comparison
- Restrict cross-origin contentDocument access
- sandbox attribute basics

## Success Criteria

- WPT dom/nodes tests using `<iframe src="dummy.xml">` pass
- iframe content renders visually in parent page
- contentDocument/contentWindow accessible from parent JS
- No memory leaks on iframe creation/destruction
- No regression on existing WPT scores
