# JS Engine Improvement — anthropic.com Compatibility

**Date**: 2026-03-19
**Goal**: Make anthropic.com render readable content (nav + hero + section text) by fixing JS engine gaps that cause a white screen.
**Target device**: Raspberry Pi Zero 2W (512MB RAM)

## Problem

anthropic.com loads blank because four visibility gates all hide content, and JS failures prevent any of them from resolving:

1. **Anti-flicker class**: `<html class="anti-flicker">` sets `visibility: hidden !important; opacity: 0 !important`. A 4-second `setTimeout` fallback should remove it, but jQuery initialization fails first, cascading errors.
2. **Word Animation FOUC**: `document.write()` injects `<style>` with `opacity: 0 !important` on headings. `DOMContentLoaded` handler should remove it — but the event never fires.
3. **Webflow IX2/IX3**: jQuery-dependent animation engine that transitions `opacity: 0 → 1` on scroll. Dead because jQuery never loads.
4. **GSAP ScrollTrigger**: Scroll-based animations. Dead because GSAP TextPlugin fails to parse (UTF-8 corruption).

**Root cause cascade**: jQuery can't read `window.document` → everything downstream dies.

## Technology Stack (anthropic.com)

- **Platform**: Webflow (CDN: website-files.com)
- **JS**: jQuery 3.5.1, Webflow IX2/IX3 runtime (~643KB), GSAP 3.14.2 + TextPlugin + SplitText + ScrollTrigger (~135KB), inline scripts (~100KB)
- **CSS**: Webflow generated, 2758 `var()` usages, heavy flexbox/grid, `calc()`/`clamp()`/`min()`/`max()`, `:is()`/`:not()` selectors
- **Total JS**: ~970KB source code

## Design

### 1. UTF-8 Sanitization + Script Size Limit

**File**: `src/js/runtime.zig`

Before passing JS source to `JS_Eval`, sanitize invalid UTF-8 sequences by replacing them with U+FFFD. QuickJS is UTF-8 strict and rejects any script with invalid bytes.

Algorithm: walk the byte array, validate each UTF-8 sequence (1-4 bytes), replace invalid sequences with `\xEF\xBF\xBD` (U+FFFD encoded).

Raise external script size limit from 512KB to 1MB. The Webflow ant-brand chunk2 is 638KB and currently gets rejected.

### 2. document/window Global Fix

**File**: `src/js/dom_api.zig`

**Diagnosis first**: Before writing code, add a diagnostic eval before jQuery loads to confirm the hypothesis:
```js
console.log("window check:", typeof window, typeof document, window === globalThis, window.document === document);
```

Current code analysis shows:
- `events.zig` line 381 sets `window = globalThis` (via JS_SetPropertyStr)
- `web_api.zig` line 782 has a JS guard: `if(typeof window==='undefined'){globalThis.window=globalThis;}`
- `dom_api.zig` line 2776 sets `document` on the global object

These suggest `window.document` should work. The real bug may be subtler (e.g., ordering issue between registerDomApis and registerEventApis, or jQuery checking something before globals are fully set up).

**Fix approach**:
- Ensure registration order: set `window = globalThis` FIRST (before document setup)
- Verify `window.document` is the same object as `document`
- Add `document.defaultView` → returns `window`
- Add `document.implementation` stub (jQuery checks this)
- Add `document.compatMode` → `"CSS1Compat"`

### 3. document.readyState + document.write()

**File**: `src/js/dom_api.zig`, `src/main.zig`

**readyState**:
- Global variable `g_ready_state` initialized to `"loading"`
- `document.readyState` getter returns current value
- Transitions: `"loading"` → `"interactive"` → `"complete"` (driven from main.zig)
- `readyState` must be wired up BEFORE events fire — jQuery checks `document.readyState === "complete"` synchronously

**document.write(html_string)**:
- During `readyState == "loading"`: parse HTML fragment via lexbor, append resulting nodes to `document.body` (or current insertion point)
- After loading: log warning and ignore (spec says replace document, but that's destructive and rarely intended)
- `document.writeln(html_string)`: same but appends `\n`
- Handles `<style>` injection: parsed style tags get their CSS text extracted and fed into the cascade on next restyle
- **Out of scope**: `<script>` tags injected via document.write are NOT executed. This is complex and not needed for anthropic.com (only `<style>` is injected). Log a warning if a `<script>` tag is detected in the written HTML.

### 4. DOMContentLoaded / load Event Firing

**File**: `src/main.zig`, `src/js/events.zig`

After all `<script>` tags have been executed (both inline and external):

1. Set `document.readyState = "interactive"`
2. Dispatch `readystatechange` on `document`
3. Dispatch `DOMContentLoaded` on `document` (bubbles: true, cancelable: false)
4. Execute pending JS jobs (`executePending()`)
5. **Run `web_api.tickTimers()` in a loop** to process setTimeout(fn, 0) callbacks — the current `initPageJs()` in main.zig only calls `executePending()` but does NOT tick timers. This must be added. Loop until no more timers are due (max 100 iterations to prevent infinite loop).
6. Set `document.readyState = "complete"`
7. Dispatch `readystatechange` on `document`
8. Dispatch `load` on `window`
9. Execute pending JS jobs again
10. Tick timers again

Note: the anti-flicker 4-second timeout will NOT fire here (it's 4000ms in the future). It will fire during the main event loop's normal timer ticking. This is fine — the page will become visible after 4 seconds if the Intellimize script doesn't load.

### 5. document.createEvent()

**File**: `src/js/dom_api.zig`

jQuery's internal event system uses the old `document.createEvent("Event")` / `event.initEvent(type, bubbles, cancelable)` pattern.

- `document.createEvent(type)` → returns Event-like object with `.initEvent()`, `.type`, `.bubbles`, `.cancelable`, `.defaultPrevented`, `.preventDefault()`, `.stopPropagation()`
- Support event type strings: `"Event"`, `"Events"`, `"HTMLEvents"`, `"MouseEvent"`, `"MouseEvents"`, `"KeyboardEvent"`

Also add: `document.getElementsByClassName(name)` and `document.getElementsByTagName(name)` — jQuery uses these as fast paths before falling back to querySelector. Cheap to implement using existing DOM tree walking.

### 6. Complex CSS Selectors for querySelector/querySelectorAll

**File**: `src/js/selectors.zig` (new), `src/js/dom_api.zig`, `src/css/selectors.zig`

Current querySelector only matches `#id`, `.class`, `tagname`. anthropic.com needs:
- Descendant combinator: `.foo .bar`
- Child combinator: `.foo > .bar`
- Attribute selectors: `[attr]`, `[attr=val]`, `[attr*=val]`, `[attr^=val]`, `[attr$=val]`
- `:not(.class)`, `:not([attr])`
- Compound selectors: `div.class#id`, `h1:not(.foo)`
- Comma-separated: `h1, .u-display-xxl, .u-display-xl`

**Approach**: Bridge to the existing CSS selector engine in `src/css/selectors.zig`. Create a thin bridge that:
1. Parses the selector string using the existing CSS selector parser
2. Walks the DOM tree depth-first
3. For each node, calls the existing `matchSelector()` function
4. Collects matches into a JS array

**Prerequisite**: The CSS selector engine currently does NOT support `:not()`. It handles `:where()` and `:is()` with simplified inner parsing, but `:not()` is treated as an unknown pseudo-class and silently skipped. Must extend `src/css/selectors.zig`:
- Add a `negation` variant to `SimpleSelector` union for `:not(inner_selector)`
- Add negation case to `matchSimple()` that returns `!matchSelector(inner)`
- Parse `:not(...)` content as a simple selector list

This also benefits the CSS cascade (`:not()` selectors in stylesheets will match correctly).

### 7. IntersectionObserver Implementation

**File**: `src/js/web_api.zig`

Replace the existing no-op stub (current stub at web_api.zig line 787 has `.observe()` as complete no-op that never calls the callback).

Simplified implementation that treats all observed elements as immediately visible:

- `new IntersectionObserver(callback, options)` — stores callback
- `.observe(element)` — schedules callback via `setTimeout(fn, 16)` with entry `{ isIntersecting: true, intersectionRatio: 1.0, target: element, boundingClientRect: element.getBoundingClientRect() }`
- `.unobserve(element)` — removes from observation list
- `.disconnect()` — clears all observations

This fires the word-animation callbacks immediately, transitioning headings from opacity:0 to opacity:1.

Future improvement: actual viewport intersection checking via scroll position + getBoundingClientRect comparison.

### 8. getComputedStyle Improvement

**File**: `src/js/dom_api.zig`

Connect `window.getComputedStyle(element)` to the CSS cascade result. Currently (dom_api.zig line 2342) it only reads the `style` attribute (inline style).

- Store `g_styles` pointer (CascadeResult) in dom_api.zig, set from main.zig after cascade
- On `getComputedStyle(el)` call, look up the element's DomNode in g_styles
- **Bridge complexity**: CascadeResult maps DomNode wrappers (Zig struct), not raw `lxb_dom_node_t` pointers. The JS element's opaque pointer is a `*lxb_dom_node_t`. Must construct a DomNode wrapper from the raw pointer to perform the lookup. DomNode is a thin wrapper (`src/dom/node.zig`) so this is straightforward.
- Return a Proxy that maps property names to computed values from the cascade
- Fallback chain: cascade result → inline style → default values
- Key properties to support: `opacity`, `display`, `visibility`, `position`, `width`, `height`, `color`, `background-color`, `font-size`, `transform`, `transition`, `margin-*`, `padding-*`
- Values returned as strings with units (e.g., `"16px"`, `"0.5"`, `"block"`)

### 9. Memory Optimization

**File**: `src/js/runtime.zig`, `src/features/adblock.zig`

**QuickJS memory limit**: 32MB → 48MB. Memory budget on Pi Zero 2W:
- Kernel + base system: ~60-80MB
- X11 + i3: ~30-50MB
- Suzume binary + lexbor + fonts + CSS + layout: ~60-100MB (varies by page)
- Available for JS: ~100-150MB conservatively
- 48MB is safe with headroom. **Must monitor RSS during testing on actual device.**

**Script source release**: After `JS_Eval`, free the source text buffer immediately. QuickJS compiles to bytecode internally; the source string is not needed after eval.

**Explicit GC**: Call `JS_RunGC(rt)` after each external script eval and after DOMContentLoaded firing.

**Tracking script filter**: Integrate into existing `src/features/adblock.zig` rather than creating a duplicate URL filtering system in the JS loader. Add URL keyword patterns: `analytics`, `tracking`, `hubspot`, `gtm`, `google-analytics`, `googletagmanager`, `onetrust`, `segment`, `hotjar`, `sentry`, `datadog`, `newrelic`. Log skipped URLs at info level.

This saves ~200KB+ of JS memory for anthropic.com (HubSpot, Intellimize, OneTrust).

**OOM handling**: If `JS_Eval` fails with memory error, run GC and retry once. If still fails, skip that script and continue.

## Implementation Order

Each step builds on the previous. Test after each step.

| Step | Component | Depends On | Test |
|------|-----------|------------|------|
| 1 | UTF-8 sanitize + script size limit | — | GSAP TextPlugin parses without SyntaxError |
| 2 | document/window global fix | — | jQuery initializes without TypeError |
| 1+2 | **Integration test** | Steps 1, 2 | jQuery loads AND GSAP parses on anthropic.com |
| 3 | readyState + document.write | Step 2 | `document.readyState` returns correct value; FOUC style injected |
| 4 | DOMContentLoaded/load firing | Step 3 | jQuery `.ready()` callbacks execute; timer ticks run |
| 5 | document.createEvent + getElementsBy* | Step 2 | jQuery event system works |
| 6 | `:not()` in CSS selector engine + complex querySelector | — | `querySelectorAll("h1:not(.no-animate)")` returns elements |
| 7 | IntersectionObserver | Step 4 | Word animation callbacks fire |
| 8 | getComputedStyle | Steps 4, 6 | Webflow tram reads opacity values |
| 9 | Memory optimization | All above | anthropic.com loads on Pi Zero 2W without OOM; monitor RSS |

## Success Criteria

- anthropic.com renders: header navigation, hero text, main content sections visible and readable
- No white screen — at least text content is visible within 10 seconds
- Hacker News, old.reddit.com, example.com continue to render correctly (no regression)
- Memory usage stays under 48MB for JS on anthropic.com
- Pi Zero 2W can load the page without OOM kill
- RSS monitored on actual device during testing

## Out of Scope

- Full GSAP animation playback (scroll-triggered animations)
- Webflow IX2 scroll-based interaction animations
- Lottie/SVG globe animation
- Video autoplay
- Service Workers, IndexedDB
- CSS `@keyframes` animation execution
- Shadow DOM / Web Components (beyond basic customElements.define stub)
- `<script>` tags injected via document.write (only `<style>` supported)
