# JS Engine Improvement Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make anthropic.com render readable content by fixing JS engine gaps that cause a white screen.

**Architecture:** Fix jQuery initialization cascade by ensuring window/document globals are correct, implement missing DOM APIs (document.write, readyState, createEvent, DOMContentLoaded), upgrade querySelector to use the existing CSS selector engine, and add IntersectionObserver + getComputedStyle for animation visibility. Memory-optimized for Pi Zero 2W (512MB).

**Tech Stack:** Zig, QuickJS-ng, lexbor HTML parser

**Spec:** `docs/superpowers/specs/2026-03-19-js-engine-improvement-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `src/js/runtime.zig` | Modify | UTF-8 sanitizer, memory limit 48MB, GC strategy, OOM handling |
| `src/js/dom_api.zig` | Modify | document.write, readyState, createEvent, getComputedStyle, getElementsBy*, window/document global fix |
| `src/js/web_api.zig` | Modify | IntersectionObserver upgrade (no-op → callback-firing) |
| `src/js/events.zig` | Modify | DOMContentLoaded/load/readystatechange dispatch helpers |
| `src/js/selectors.zig` | Create | Bridge from JS querySelector to CSS selector engine |
| `src/css/selectors.zig` | Modify | Add `:not()` pseudo-class support |
| `src/main.zig` | Modify | Event firing sequence, script size limit, timer ticking, g_styles |
| `src/features/adblock.zig` | Modify | Tracking script URL filter |

---

## Chunk 1: Foundation (Tasks 1-3)

### Task 1: UTF-8 Sanitizer

**Files:**
- Modify: `src/js/runtime.zig:40` (eval function)

- [ ] **Step 1: Add UTF-8 sanitize function to runtime.zig**

Add before the `eval` function (~line 38). This function replaces invalid UTF-8 bytes with U+FFFD so QuickJS doesn't reject the script.

```zig
/// Sanitize a byte buffer so every byte sequence is valid UTF-8.
/// Invalid sequences are replaced with U+FFFD (EF BF BD).
/// Returns a newly allocated buffer that the caller must free.
fn sanitizeUtf8(input: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.ensureTotalCapacity(input.len);

    var i: usize = 0;
    while (i < input.len) {
        const b0 = input[i];
        const seq_len: usize = if (b0 < 0x80) 1
            else if (b0 < 0xC0) 0 // invalid continuation byte
            else if (b0 < 0xE0) 2
            else if (b0 < 0xF0) 3
            else if (b0 < 0xF8) 4
            else 0; // invalid

        if (seq_len == 0) {
            // Invalid leading byte — emit replacement char
            try out.appendSlice("\xEF\xBF\xBD");
            i += 1;
            continue;
        }

        // Check that we have enough continuation bytes
        if (i + seq_len > input.len) {
            try out.appendSlice("\xEF\xBF\xBD");
            i += 1;
            continue;
        }

        // Validate continuation bytes (must be 10xxxxxx)
        var valid = true;
        for (1..seq_len) |j| {
            if ((input[i + j] & 0xC0) != 0x80) {
                valid = false;
                break;
            }
        }

        if (valid) {
            try out.appendSlice(input[i..i + seq_len]);
            i += seq_len;
        } else {
            try out.appendSlice("\xEF\xBF\xBD");
            i += 1;
        }
    }
    return out.toOwnedSlice();
}
```

- [ ] **Step 2: Integrate sanitizer into eval()**

In the `eval` function (~line 40), sanitize before passing to `JS_Eval`:

```zig
pub fn eval(self: *JsRuntime, code: []const u8) EvalResult {
    // Sanitize invalid UTF-8 sequences before QuickJS eval
    const clean_code = sanitizeUtf8(code, std.heap.c_allocator) catch code;
    defer if (clean_code.ptr != code.ptr) std.heap.c_allocator.free(clean_code);

    const val = qjs.JS_Eval(self.ctx, clean_code.ptr, clean_code.len, "<eval>", qjs.JS_EVAL_TYPE_GLOBAL);
    // ... rest unchanged
}
```

- [ ] **Step 3: Raise memory limit to 48MB**

At `src/js/runtime.zig:14`, change:

```zig
// Before:
qjs.JS_SetMemoryLimit(self.rt, 32 * 1024 * 1024);
// After:
qjs.JS_SetMemoryLimit(self.rt, 48 * 1024 * 1024);
```

- [ ] **Step 4: Raise script size limit to 1MB**

At `src/main.zig:216`, change:

```zig
// Before:
const max_external_script_size = 512 * 1024;
// After:
const max_external_script_size = 1024 * 1024;
```

- [ ] **Step 5: Add explicit GC after each external script eval**

In `src/main.zig`, after the `js_rt.eval()` call for external scripts (~line 206), add:

```zig
// After eval:
qjs.JS_RunGC(js_rt.rt);
```

Find the right location by searching for `js_rt.eval` calls in collectAndExecScripts.

- [ ] **Step 6: Build and test**

```bash
cd ~/suzume && zig build
```

Then test with anthropic.com — GSAP TextPlugin should no longer show `SyntaxError: invalid UTF-8 sequence`. The 638KB Webflow chunk should now be loaded instead of "External script too large".

- [ ] **Step 7: Commit**

```bash
cd ~/suzume && git add src/js/runtime.zig src/main.zig
git commit -m "fix: UTF-8 sanitizer for JS eval, raise script/memory limits

- Sanitize invalid UTF-8 sequences before QuickJS eval (replaces with U+FFFD)
- Raise JS memory limit from 32MB to 48MB for complex sites
- Raise external script size limit from 512KB to 1MB (Webflow chunks)
- Add explicit GC after each external script eval"
```

---

### Task 2: document/window Global Fix

**Files:**
- Modify: `src/js/dom_api.zig:2461` (registerDomApis)
- Modify: `src/js/events.zig:362` (registerEventApis)

- [ ] **Step 1: Add diagnostic eval to confirm hypothesis**

Temporarily add to `src/main.zig` initPageJs function (~line 388), right after registerDomApis and registerEventApis but before script execution:

```zig
_ = js_rt.eval(
    \\console.log("[DIAG] window===globalThis:", typeof window !== 'undefined' && window === globalThis);
    \\console.log("[DIAG] window.document:", typeof window !== 'undefined' && typeof window.document);
    \\console.log("[DIAG] document:", typeof document);
    \\console.log("[DIAG] document.createElement:", typeof document !== 'undefined' && typeof document.createElement);
);
```

- [ ] **Step 2: Build and run against anthropic.com, capture output**

```bash
cd ~/suzume && zig build
Xephyr :47 -screen 1024x768 -ac &
DISPLAY=:47 timeout 15 ./zig-out/bin/suzume "https://anthropic.com" 2>&1 | grep DIAG
```

Check which values are `undefined` — this reveals the actual bug.

- [ ] **Step 3: Fix based on diagnosis**

The most likely fix: ensure `window` is set as `globalThis` alias BEFORE `document` is registered. In `registerDomApis()` (~line 2461), add at the very top:

```zig
// Ensure window = globalThis before setting up document
const global = qjs.JS_GetGlobalObject(ctx);
defer qjs.JS_FreeValue(ctx, global);
_ = qjs.JS_SetPropertyStr(ctx, global, "window", qjs.JS_DupValue(ctx, global));
```

Then also add these document properties that jQuery checks:

```zig
// After setting document on global (~line 2776):
// document.defaultView = window
_ = qjs.JS_SetPropertyStr(ctx, doc_obj, "defaultView", qjs.JS_DupValue(ctx, global));
// document.compatMode
const compat_val = qjs.JS_NewString(ctx, "CSS1Compat");
_ = qjs.JS_SetPropertyStr(ctx, doc_obj, "compatMode", compat_val);
// document.implementation (stub object)
_ = js_rt.eval("document.implementation = { createHTMLDocument: function(t) { return document; }, hasFeature: function() { return true; } };");
```

- [ ] **Step 4: Remove diagnostic eval, build and test**

Remove the diagnostic eval added in Step 1. Build and run against anthropic.com:

```bash
cd ~/suzume && zig build
Xephyr :47 -screen 1024x768 -ac &
DISPLAY=:47 timeout 15 ./zig-out/bin/suzume "https://anthropic.com" 2>&1 | grep -E "TypeError|createElement"
```

jQuery should no longer show `cannot read property 'createElement' of undefined`.

- [ ] **Step 5: Commit**

```bash
cd ~/suzume && git add src/js/dom_api.zig src/js/events.zig
git commit -m "fix: ensure window/document globals for jQuery compatibility

- Set window = globalThis before document registration
- Add document.defaultView, compatMode, implementation
- jQuery factory function can now find window.document.createElement"
```

---

### Task 3: document.readyState + document.write()

**Files:**
- Modify: `src/js/dom_api.zig`
- Modify: `src/main.zig`

- [ ] **Step 1: Add readyState global and getter**

In `src/js/dom_api.zig`, near the global variables (~line 43):

```zig
var g_ready_state: enum { loading, interactive, complete } = .loading;

pub fn setReadyState(state: enum { loading, interactive, complete }) void {
    g_ready_state = state;
}
```

In `registerDomApis`, add a getter for `document.readyState`. This needs to be a JS getter (not a static property) so it returns the current value:

```zig
// After document object setup, add readyState getter via eval:
_ = js_rt_eval(
    \\Object.defineProperty(document, 'readyState', {
    \\  get: function() { return __getReadyState(); },
    \\  configurable: true
    \\});
);
```

Register `__getReadyState` as a native function that reads `g_ready_state` and returns `"loading"`, `"interactive"`, or `"complete"`.

- [ ] **Step 2: Implement document.write()**

Add native function in `src/js/dom_api.zig`:

```zig
fn documentWrite(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*]qjs.JSValue) callconv(.C) qjs.JSValue {
    if (argc < 1) return qjs.JS_UNDEFINED;

    // Only works during loading phase
    if (g_ready_state != .loading) {
        std.log.warn("[JS] document.write called after page load, ignoring", .{});
        return qjs.JS_UNDEFINED;
    }

    const str = qjs.JS_ToCString(ctx, argv[0]) orelse return qjs.JS_UNDEFINED;
    defer qjs.JS_FreeCString(ctx, str);
    const html = std.mem.span(str);

    if (html.len == 0) return qjs.JS_UNDEFINED;

    // Parse HTML fragment via lexbor and append to body
    if (g_document) |doc| {
        const body = getBodyNode(doc) orelse return qjs.JS_UNDEFINED;
        // Use lexbor fragment parsing
        parseAndAppendFragment(doc, body, html);
        setDomDirty();

        // Check if we injected a <script> tag
        if (std.mem.indexOf(u8, html, "<script") != null) {
            std.log.warn("[JS] document.write injected <script> — execution not supported", .{});
        }
    }
    return qjs.JS_UNDEFINED;
}
```

Implement `parseAndAppendFragment` using lexbor's `lxb_html_document_parse_fragment` or by parsing a temporary document and moving nodes. Register as `document.write` and `document.writeln` in registerDomApis.

- [ ] **Step 3: Wire readyState transitions in main.zig**

In `src/main.zig` initPageJs (~line 378):

```zig
// Before script execution:
dom_api.setReadyState(.loading);

// ... execute scripts ...

// After scripts, before DOMContentLoaded:
dom_api.setReadyState(.interactive);

// ... dispatch DOMContentLoaded ...

// After load event:
dom_api.setReadyState(.complete);
```

- [ ] **Step 4: Build and test**

```bash
cd ~/suzume && zig build
```

Test: load anthropic.com, check logs for `document.write` calls. The FOUC prevention `<style>` should appear in the DOM.

- [ ] **Step 5: Commit**

```bash
cd ~/suzume && git add src/js/dom_api.zig src/main.zig
git commit -m "feat: document.readyState and document.write() implementation

- readyState transitions: loading → interactive → complete
- document.write() parses HTML fragments and appends to body during loading
- document.writeln() adds newline
- Script injection via document.write logged but not executed"
```

---

## Chunk 2: Events & jQuery (Tasks 4-5)

### Task 4: DOMContentLoaded / load Event Firing

**Files:**
- Modify: `src/main.zig:378` (initPageJs)
- Modify: `src/js/events.zig`

- [ ] **Step 1: Add readystatechange dispatch helper**

In `src/js/events.zig`, add:

```zig
pub fn dispatchReadyStateChange(ctx: ?*qjs.JSContext) void {
    dispatchDocumentEvent(ctx, "readystatechange");
}
```

- [ ] **Step 2: Rewrite initPageJs event sequence**

In `src/main.zig` initPageJs (~line 378), replace the current DOMContentLoaded/load dispatch with the full sequence:

```zig
// 1. readyState transitions are set in Task 3

// 2. After all scripts executed:
dom_api.setReadyState(.interactive);
events.dispatchReadyStateChange(js_ctx);
events.dispatchDocumentEvent(js_ctx, "DOMContentLoaded");

// 3. Execute pending promise jobs
js_rt.executePending();

// 4. Tick timers for setTimeout(fn, 0) callbacks — critical for anti-flicker
var timer_iters: u32 = 0;
while (web_api.tickTimers(js_ctx) and timer_iters < 100) : (timer_iters += 1) {
    js_rt.executePending();
}

// 5. Complete loading
dom_api.setReadyState(.complete);
events.dispatchReadyStateChange(js_ctx);
events.dispatchWindowEvent(js_ctx, "load");

// 6. Final cleanup
js_rt.executePending();
timer_iters = 0;
while (web_api.tickTimers(js_ctx) and timer_iters < 100) : (timer_iters += 1) {
    js_rt.executePending();
}
```

- [ ] **Step 3: Build and test**

```bash
cd ~/suzume && zig build
```

Test: load anthropic.com. jQuery `.ready()` callbacks should execute — look for fewer `ReferenceError` messages in the logs. The anti-flicker class should eventually be removed (may need to wait for 4s timer in the main event loop).

- [ ] **Step 4: Commit**

```bash
cd ~/suzume && git add src/main.zig src/js/events.zig
git commit -m "feat: proper DOMContentLoaded/load event sequence with timer ticking

- Fire readystatechange, DOMContentLoaded, load in spec order
- Tick timers between events for setTimeout(fn, 0) callbacks
- jQuery .ready() and page init scripts now execute"
```

---

### Task 5: document.createEvent + getElementsBy*

**Files:**
- Modify: `src/js/dom_api.zig`

- [ ] **Step 1: Implement document.createEvent()**

Add native function and register it on the document object:

```zig
fn documentCreateEvent(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*]qjs.JSValue) callconv(.C) qjs.JSValue {
    // Returns an Event-like object with initEvent() method
    _ = argc;
    _ = argv;
    const result = qjs.JS_Eval(ctx.?,
        \\(function() {
        \\  var e = { type: '', bubbles: false, cancelable: false,
        \\    defaultPrevented: false, _stopped: false,
        \\    preventDefault: function() { this.defaultPrevented = true; },
        \\    stopPropagation: function() { this._stopped = true; },
        \\    stopImmediatePropagation: function() { this._stopped = true; },
        \\    initEvent: function(type, bubbles, cancelable) {
        \\      this.type = type;
        \\      this.bubbles = bubbles !== false;
        \\      this.cancelable = cancelable !== false;
        \\    }
        \\  };
        \\  return e;
        \\})()
    , 0, "<createEvent>", qjs.JS_EVAL_TYPE_GLOBAL);
    return result;
}
```

Register in registerDomApis on the document object.

- [ ] **Step 2: Implement getElementsByClassName and getElementsByTagName**

Add via JS eval in registerDomApis (simpler than native since they return live-ish collections):

```zig
_ = js_rt_eval(
    \\document.getElementsByClassName = function(name) {
    \\  return document.querySelectorAll('.' + name);
    \\};
    \\document.getElementsByTagName = function(name) {
    \\  return document.querySelectorAll(name);
    \\};
    \\document.getElementsByName = function(name) {
    \\  return document.querySelectorAll('[name="' + name + '"]');
    \\};
);
```

Note: getElementsByClassName/TagName with complex querySelector won't work until Task 6, but the simple tag/class selectors already work with current querySelector.

- [ ] **Step 3: Add window.getSelection stub**

```zig
_ = js_rt_eval(
    \\window.getSelection = function() {
    \\  return { toString: function() { return ''; }, rangeCount: 0,
    \\    getRangeAt: function() { return null; },
    \\    removeAllRanges: function() {},
    \\    addRange: function() {} };
    \\};
);
```

- [ ] **Step 4: Build and test**

```bash
cd ~/suzume && zig build
```

Test on anthropic.com — jQuery's event system should stop throwing errors about createEvent.

- [ ] **Step 5: Commit**

```bash
cd ~/suzume && git add src/js/dom_api.zig
git commit -m "feat: document.createEvent, getElementsBy*, getSelection

- createEvent returns Event object with initEvent() for jQuery compat
- getElementsByClassName/TagName delegate to querySelectorAll
- window.getSelection returns empty stub"
```

---

## Chunk 3: Selectors (Task 6)

### Task 6: :not() in CSS Engine + Complex querySelector

**Files:**
- Modify: `src/css/selectors.zig:86` (SimpleSelector), `src/css/selectors.zig:693` (matchSimple)
- Create: `src/js/selectors.zig`
- Modify: `src/js/dom_api.zig`

- [ ] **Step 1: Add :not() to CSS selector engine**

In `src/css/selectors.zig`, extend the `SimpleSelector` union (~line 86) to add a negation variant:

```zig
pub const SimpleSelector = union(enum) {
    type_sel: []const u8,
    class: []const u8,
    id: []const u8,
    universal,
    attribute: AttributeSelector,
    pseudo_class: PseudoClass,
    negation: *Selector, // :not(inner_selector)
};
```

In `matchSimple()` (~line 693), add the negation case:

```zig
.negation => |inner_sel| {
    // :not(sel) matches if the inner selector does NOT match
    return !matches(inner_sel, node, parent_chain);
},
```

In the selector parser, handle `:not(` by parsing the inner content as a simple selector and wrapping it.

- [ ] **Step 2: Run CSS tests to verify no regression**

```bash
cd ~/suzume && zig build test-css
```

All existing tests should pass.

- [ ] **Step 3: Create src/js/selectors.zig bridge**

New file that bridges JS querySelector calls to the CSS selector engine:

```zig
const std = @import("std");
const DomNode = @import("../dom/node.zig").DomNode;
const css_selectors = @import("../css/selectors.zig");
const parser_mod = @import("../css/parser.zig");

/// Parse a CSS selector string and match it against a DOM subtree.
/// Returns all matching nodes.
pub fn querySelectorAll(
    root: DomNode,
    selector_str: []const u8,
    allocator: std.mem.Allocator,
) ![]DomNode {
    // Parse selector string
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = parser_mod.Parser.init(selector_str, arena.allocator());
    const selectors = parser.parseSelectorList() catch {
        // Fall back to simple matching if parse fails
        return simpleFallback(root, selector_str, allocator);
    };

    // Walk DOM tree depth-first, collect matches
    var results = std.ArrayList(DomNode).init(allocator);
    errdefer results.deinit();

    var stack: [256]DomNode = undefined;
    var stack_len: usize = 0;

    // Push root's children
    if (root.firstChild()) |first| {
        stack[0] = first;
        stack_len = 1;
    }

    while (stack_len > 0) {
        stack_len -= 1;
        const node = stack[stack_len];

        if (node.nodeType() == .element) {
            // Test against each selector in the comma-separated list
            for (selectors) |sel| {
                if (css_selectors.matches(&sel, node, null)) {
                    try results.append(node);
                    break;
                }
            }
        }

        // Push siblings and children
        if (node.nextSibling()) |sib| {
            if (stack_len < stack.len) {
                stack[stack_len] = sib;
                stack_len += 1;
            }
        }
        if (node.nodeType() == .element) {
            if (node.firstChild()) |child| {
                if (stack_len < stack.len) {
                    stack[stack_len] = child;
                    stack_len += 1;
                }
            }
        }
    }

    return results.toOwnedSlice();
}

/// First match only.
pub fn querySelector(root: DomNode, selector_str: []const u8, allocator: std.mem.Allocator) ?DomNode {
    const results = querySelectorAll(root, selector_str, allocator) catch return null;
    defer allocator.free(results);
    return if (results.len > 0) results[0] else null;
}
```

Note: The actual parser integration depends on the CSS parser's API. The selector parser in `src/css/parser.zig` parses selectors as part of CSS rules. We may need to extract a `parseSelectorList(input: []const u8)` standalone function or create a wrapper. Check the parser API when implementing.

- [ ] **Step 4: Wire querySelector to the new bridge**

In `src/js/dom_api.zig`, modify `walkTreeBySelector` (~line 1707) and `walkTreeCollect` (~line 1806) to try the new bridge first, falling back to simple matching:

```zig
fn walkTreeBySelector(root: anytype, selector: []const u8) ?*lxb.lxb_dom_node_t {
    // Try CSS selector engine bridge first
    const dom_root = DomNode{ .lxb_node = root };
    if (js_selectors.querySelector(dom_root, selector, std.heap.c_allocator)) |result| {
        return result.lxb_node;
    }
    // Fall back to simple matching (existing code)
    // ...
}
```

- [ ] **Step 5: Build and test**

```bash
cd ~/suzume && zig build && zig build test-css
```

Manual test: add a temporary eval to test complex selectors:
```js
console.log("not-test:", document.querySelectorAll("h1:not(.no-animate)").length);
```

- [ ] **Step 6: Commit**

```bash
cd ~/suzume && git add src/css/selectors.zig src/js/selectors.zig src/js/dom_api.zig
git commit -m "feat: complex CSS selectors for querySelector + :not() support

- Add :not() pseudo-class to CSS selector engine
- Bridge querySelector/querySelectorAll to CSS selector matcher
- Supports descendant, child, attribute, compound, comma selectors
- Falls back to simple matching on parse failure"
```

---

## Chunk 4: Visibility & Polish (Tasks 7-9)

### Task 7: IntersectionObserver

**Files:**
- Modify: `src/js/web_api.zig:787` (replace existing stub)

- [ ] **Step 1: Replace IntersectionObserver stub**

In `src/js/web_api.zig`, find the IntersectionObserver stub in the compat_stubs JS string (~line 787) and replace it:

```javascript
globalThis.IntersectionObserver = function(callback, options) {
  this._cb = callback;
  this._entries = [];
  this._disconnected = false;
  this.observe = function(el) {
    if (this._disconnected) return;
    var self = this;
    var entry = {
      isIntersecting: true,
      intersectionRatio: 1.0,
      target: el,
      boundingClientRect: (el.getBoundingClientRect ? el.getBoundingClientRect() : {x:0,y:0,width:0,height:0,top:0,left:0,right:0,bottom:0}),
      intersectionRect: {x:0,y:0,width:0,height:0,top:0,left:0,right:0,bottom:0},
      rootBounds: null,
      time: (typeof performance !== 'undefined' ? performance.now() : 0)
    };
    setTimeout(function() {
      if (!self._disconnected) self._cb([entry], self);
    }, 16);
  };
  this.unobserve = function(el) {};
  this.disconnect = function() { this._disconnected = true; };
  this.takeRecords = function() { return []; };
};
```

- [ ] **Step 2: Build and test**

```bash
cd ~/suzume && zig build
```

Test on anthropic.com — word animation callbacks should fire, setting heading opacity to 1.

- [ ] **Step 3: Commit**

```bash
cd ~/suzume && git add src/js/web_api.zig
git commit -m "feat: IntersectionObserver fires callbacks for observed elements

- Replace no-op stub with callback-firing implementation
- All observed elements treated as immediately visible
- Fires word-animation callbacks on anthropic.com"
```

---

### Task 8: getComputedStyle Improvement

**Files:**
- Modify: `src/js/dom_api.zig:2371` (windowGetComputedStyle)
- Modify: `src/main.zig` (set g_styles)

- [ ] **Step 1: Add g_styles global and setter**

In `src/js/dom_api.zig`, near other globals (~line 43):

```zig
const cascade_mod = @import("../css/cascade.zig");

var g_styles: ?*const cascade_mod.CascadeResult = null;

pub fn setStyles(styles: ?*const cascade_mod.CascadeResult) void {
    g_styles = styles;
}
```

In `src/main.zig`, after cascade and before JS execution, call:

```zig
dom_api.setStyles(&styles);
```

Also call it again after any restyle (dom_dirty path).

- [ ] **Step 2: Improve getComputedStyle native function**

Rewrite `windowGetComputedStyle` (~line 2371) to look up cascade results:

```zig
fn windowGetComputedStyle(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*]qjs.JSValue) callconv(.C) qjs.JSValue {
    if (argc < 1) return qjs.JS_UNDEFINED;

    // Get the DOM node from the JS element
    const node_ptr = getNodePublic(ctx, argv[0]) orelse return currentFallback(ctx, argv[0]);
    const dom_node = DomNode{ .lxb_node = node_ptr };

    // Try cascade result first
    if (g_styles) |styles| {
        if (styles.getStyle(dom_node)) |computed| {
            return buildComputedStyleProxy(ctx, computed, argv[0]);
        }
    }

    // Fallback to inline style reading (existing behavior)
    return currentFallback(ctx, argv[0]);
}
```

Implement `buildComputedStyleProxy` that creates a JS Proxy returning computed values as strings. Map key ComputedStyle fields to CSS property names.

- [ ] **Step 3: Build and test**

```bash
cd ~/suzume && zig build
```

Test: Webflow tram should be able to read opacity and transform values.

- [ ] **Step 4: Commit**

```bash
cd ~/suzume && git add src/js/dom_api.zig src/main.zig
git commit -m "feat: getComputedStyle returns CSS cascade results

- Connect to CascadeResult for computed property values
- Falls back to inline style if cascade unavailable
- Returns string values for opacity, display, visibility, etc."
```

---

### Task 9: Memory Optimization + Tracking Filter

**Files:**
- Modify: `src/features/adblock.zig`
- Modify: `src/main.zig`

- [ ] **Step 1: Add tracking script patterns to adblock**

In `src/features/adblock.zig`, add a new function:

```zig
const tracking_patterns = [_][]const u8{
    "analytics", "tracking", "hubspot", "gtm",
    "google-analytics", "googletagmanager", "onetrust",
    "segment", "hotjar", "sentry", "datadog", "newrelic",
    "intellimize", "optimizely", "crazyegg", "mouseflow",
};

pub fn isTrackingScript(url: []const u8) bool {
    const lower_url = url; // URLs are typically already lowercase
    for (tracking_patterns) |pattern| {
        if (std.mem.indexOf(u8, lower_url, pattern) != null) return true;
    }
    return false;
}
```

- [ ] **Step 2: Skip tracking scripts in main.zig**

In the script execution loop in `src/main.zig` (collectAndExecScripts ~line 201), before fetching external scripts:

```zig
if (adblock.isTrackingScript(script_url)) {
    std.log.info("[JS] Skipping tracking script: {s}", .{script_url});
    continue;
}
```

- [ ] **Step 3: Add OOM retry logic**

In `src/js/runtime.zig` eval function, after JS_Eval fails:

```zig
if (qjs.JS_IsException(val)) {
    // Check if it's a memory error — try GC and retry once
    qjs.JS_RunGC(self.rt);
    const retry_val = qjs.JS_Eval(self.ctx, clean_code.ptr, clean_code.len, "<eval>", qjs.JS_EVAL_TYPE_GLOBAL);
    if (!qjs.JS_IsException(retry_val)) {
        return .{ .ok = retry_val };
    }
    // Original error handling continues...
}
```

- [ ] **Step 4: Build and test on anthropic.com**

```bash
cd ~/suzume && zig build
```

Verify tracking scripts are skipped in logs. Verify no OOM on anthropic.com.

- [ ] **Step 5: Commit**

```bash
cd ~/suzume && git add src/features/adblock.zig src/main.zig src/js/runtime.zig
git commit -m "feat: tracking script filter and OOM resilience

- Skip analytics/tracking scripts to save memory on Pi Zero 2W
- GC + retry on JS eval OOM before giving up
- Integrated into existing adblock filter system"
```

---

## Chunk 5: Integration Test + CodeRabbit Review (Task 10)

### Task 10: Full Integration Test + Review

- [ ] **Step 1: Test anthropic.com end-to-end**

```bash
cd ~/suzume && zig build
Xephyr :47 -screen 1024x768 -ac &
DISPLAY=:47 i3 &
sleep 1
DISPLAY=:47 timeout 20 ./zig-out/bin/suzume "https://anthropic.com" &
sleep 15
DISPLAY=:47 import -window root ~/suzume/screenshots/suzume-anthropic-final.png
```

Verify: header nav visible, hero text visible, content sections visible.

- [ ] **Step 2: Test regression on existing sites**

```bash
# HN
Xephyr :48 -screen 1024x768 -ac &
DISPLAY=:48 i3 &
sleep 1
DISPLAY=:48 timeout 12 ./zig-out/bin/suzume "https://news.ycombinator.com" &
sleep 8
DISPLAY=:48 import -window root ~/suzume/screenshots/suzume-hn-regression.png

# example.com
Xephyr :49 -screen 1024x768 -ac &
DISPLAY=:49 i3 &
sleep 1
DISPLAY=:49 timeout 8 ./zig-out/bin/suzume "https://example.com" &
sleep 5
DISPLAY=:49 import -window root ~/suzume/screenshots/suzume-example-regression.png
```

Compare with previous screenshots — no visual regression.

- [ ] **Step 3: Run CSS test suite**

```bash
cd ~/suzume && zig build test-css
```

All tests pass.

- [ ] **Step 4: CodeRabbit review**

```bash
cd ~/suzume && cr review
```

Fix any issues flagged by CodeRabbit.

- [ ] **Step 5: Push**

```bash
cd ~/suzume && git push origin main
```
