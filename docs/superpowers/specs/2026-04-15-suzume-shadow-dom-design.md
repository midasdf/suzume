# Suzume Shadow DOM — Design Spec

**Date**: 2026-04-15
**Status**: Design, not yet implemented
**Scope target**: Unblock common Web Components (lit, custom `<x-foo>` with templates/slots)
**Related specs**: `2026-04-14-suzume-phaseA-dom-audit.md`, `2026-03-27-dom-api-refactor-design.md`

---

## Executive Summary

suzume currently exposes `Element.attachShadow()` as a thin JS facade that copies method references from the host element (`src/js/dom_element.zig:1498-1521`). There is no tree isolation, no retargeting, no slot distribution, and no style scoping. Any `shadowRoot.appendChild(...)` mutates the host's light tree; `event.target` inside a "shadow" leaks the real node; `getRootNode()` ignores `{composed}`.

This spec proposes a practical, phased implementation of **Shadow DOM v1** (DOM Standard §4.8, §4.4, HTML §4.13) on top of the existing lexbor-backed DOM. We recommend **Option B (scope-tagged nodes)** for the tree model: store shadow subtrees in lexbor but tag each node with a `shadow_root_id` so traversal, selector matching, and CSS scoping honor the boundary without forking lexbor or running a parallel tree.

The rollout lands in three phases:
1. Real tree scope + `attachShadow` + scoped traversal (enables `<template>` + `innerHTML` component rendering).
2. Event retargeting + `{composed}` support (enables framework event handling).
3. Slots + style encapsulation (enables composition and isolated styling).

Estimated effort: **3–5 engineer-weeks** across all three phases; Phase 1 alone is ~1 week and unblocks most lit/stencil/vanilla component libraries that do not rely on slotted projection.

---

## Current State

| Concern | File:Line | Status |
|---|---|---|
| `Element.attachShadow()` | `src/js/dom_element.zig:1498-1521` | Pseudo — copies methods, no isolation |
| ShadowRoot prototype | none | Does not exist; plain object |
| `getRootNode()` | `src/js/dom_api.zig:3151`, `src/js/dom_document.zig:397` | Ignores `{composed}` option |
| `isConnected` | `src/js/dom_api.zig:3303-3305` | Shadow-unaware; reports host-tree connectivity only |
| Event dispatch + `composedPath` | `src/js/events.zig:445-510, 945-1070` | Has `composed` flag per event type, but no retargeting; `_path` built from parent chain of a single tree |
| Slot / `<slot>` | none | Unhandled; falls through as unknown element |
| Style scoping | `src/css/*` | Global stylesheet; no per-scope rule set |

Callers across `src/main.zig`, `src/layout/table.zig`, and `src/net/webdriver.zig` reference `shadowRoot`, but only as an opaque property — none depend on real isolation yet, so migration cost is low.

---

## Spec Requirements Summary

Minimum compliant surface per DOM §4.8:

- `Element.attachShadow(init)` with `init.mode` ∈ `{open, closed}`, optional `delegatesFocus: bool`, `slotAssignment: "named" | "manual"`.
- `ShadowRoot` extends `DocumentFragment` with `host`, `mode`, `delegatesFocus`, `slotAssignment`, `innerHTML`.
- `Node.getRootNode({composed})` — when `composed=true`, walk through shadow boundaries to the document.
- `Node.isConnected` — true iff the shadow-inclusive root is the document.
- `Event.composedPath()` with retargeting (DOM §4.4 "retargeting algorithm").
- `<slot>` element with `assignedNodes({flatten})`, `assignedElements()`, `slotchange` event.
- CSS rules defined inside a shadow root apply only to that scope; `:host`, `:host()`, `::slotted()` selectors.

Out of scope for this spec: declarative shadow DOM (`<template shadowrootmode>`), form-associated custom elements, focus delegation edge cases, CSS `::part`/`::theme`.

---

## Design

### 1. Tree Scope Model — recommend **Option B**

**Option A (fork lexbor, add shadow-root node type).** Cleanest conceptually. ShadowRoot becomes a first-class `lxb_dom_node_type_t`. Rejected: forking lexbor blocks upstream updates we rely on for HTML parsing correctness, and every lexbor consumer in the codebase (selector engine, serializer, WPT harness fixtures) would need node-type awareness.

**Option B (scope-tagged nodes in lexbor) — RECOMMENDED.** A ShadowRoot is a Zig-side struct owning a `lxb_dom_document_fragment_t` (already exists in lexbor) as its storage root. Every `lxb_dom_node_t` inside carries a `shadow_root_id: u32` tag via a side-table (`AutoHashMap(*lxb_dom_node_t, u32)`) or by stealing a bit from `node->user`. Traversal primitives in `src/js/dom_api.zig` and the CSS selector matcher gain a `scope_id` parameter; when crossing from a node with scope `X` to a child whose scope differs, traversal stops (unless composed). `host` is stored in the ShadowRoot struct and is the only legal upward escape.

Tradeoffs: requires auditing every traversal call site (~40 in `dom_api.zig`, ~15 in `selector_match.zig`), but no lexbor fork, no parallel tree, and querySelector can still use lexbor's native walker by bounding it with a scope predicate.

**Option C (separate Zig-side tree).** Adds a second tree abstraction — duplicated parent/child/sibling logic, duplicated serializer, duplicated mutation observer. Rejected: doubles the surface area of an already complex DOM layer.

**Storage sketch**:
```zig
pub const ShadowRoot = struct {
    id: u32,
    host: *lxb_dom_element_t,
    fragment: *lxb_dom_document_fragment_t,  // storage root
    mode: Mode,                                // open | closed
    delegates_focus: bool,
    slot_assignment: SlotAssignment,           // named | manual
    stylesheets: std.ArrayList(*CssStylesheet),
};

// In DocumentContext:
shadow_roots: std.AutoHashMap(u32, *ShadowRoot),
node_scope: std.AutoHashMap(*lxb_dom_node_t, u32),  // 0 = document scope
```

Host navigation: `element.shadowRoot` returns the ShadowRoot JS wrapper if mode is `open`, else `null`. `closed` mode keeps the struct accessible internally but hidden from JS.

### 2. Event Retargeting (DOM §4.4)

During `dispatchEventWithObj` (`src/js/events.zig:953`), build a **composed path** of `(node, slot-in-closed-tree, target, relatedTarget, touchTargetList)` tuples by walking from the target up through `parentNode` / `host` boundaries. For each event phase step, compute the retargeted target:

```
retarget(A, B):
    while true:
        if A is not a node, or A's root is not a shadow root: return A
        if B is a node and A's root is a shadow-including inclusive ancestor of B: return A
        A = A's root's host
```

Store the pre-retargeted list once, then at each listener invocation patch `event.target` and `event.currentTarget` to the retargeted values for that step. The existing `composedPath` implementation (`events.zig:508, 996-1070`) already reserves the `_path` slot — extend it to store the tuple list and expose only nodes visible from the listener's root (closed-tree filtering).

Events with `composed: false` stop at the nearest shadow boundary. The `composed_events` whitelist at `events.zig:449-459` is already correct; no change needed there.

### 3. Slot Distribution (HTML §4.13)

A `<slot>` inside a shadow tree acts as an insertion point for the host's light children. Algorithm on shadow tree assembly (or on mutation of host children / slot attributes):

1. For `slotAssignment: "named"`: for each light child of host, read `slot` attribute (default `""`). Find first `<slot>` in the shadow tree whose `name` attribute matches. Record the assignment in `slot.assigned_nodes: ArrayList(*Node)`.
2. For `slotAssignment: "manual"`: only nodes added via `slot.assign(...)` are assigned.
3. `slot.assignedNodes({flatten: true})` recursively expands nested slots.
4. Fire `slotchange` as a bubbling, non-composed event on the slot when its assignment set changes.

Rendering implications (for `src/layout/*`): the **flattened tree** (not the shadow tree) is what layout sees. The flattening walker, given a shadow host, yields: for each node in shadow tree, if it is a slot, substitute assigned nodes; else recurse. Expose `flattenedChildren(node)` as a layout-side iterator. Light children of a shadow host that are NOT assigned to any slot are not rendered.

### 4. Style Encapsulation

Each ShadowRoot owns a `stylesheets` list independent of the document's stylesheet set. CSS selector matching (`src/css/selector_match.zig` — referenced in `2026-04-15-suzume-phaseB-css-audit.md`) gains a `scope_id` parameter equal to the node's `shadow_root_id`:

- A rule from stylesheet S matches node N only if `S.scope == N.scope`.
- `:host` matches the shadow root's host element (scope switch for this selector only).
- `:host(<compound>)` matches host if the compound selector matches host.
- `::slotted(<compound>)` matches light-tree nodes distributed into a slot, evaluated against the compound in the **light tree's** scope.
- Inherited properties (color, font) cross shadow boundaries normally; non-inherited do not.

Phase 3 scope: ship `:host` and simple scoping. Defer `::slotted`, `::part`, `::theme` to a follow-up.

### 5. API Surface

| API | Phase | Notes |
|---|---|---|
| `Element.attachShadow({mode, delegatesFocus, slotAssignment})` | 1 | Throws `NotSupportedError` on second call or on disallowed elements (input, img, etc. — maintain allowlist) |
| `Element.shadowRoot` | 1 | Returns `ShadowRoot` if open, else `null` |
| `ShadowRoot.host / .mode / .delegatesFocus / .slotAssignment` | 1 | Read-only |
| `ShadowRoot.innerHTML` get/set | 1 | Parses into scope-tagged nodes |
| `ShadowRoot.querySelector(All)` | 1 | Scoped traversal |
| `Node.getRootNode({composed})` | 1 | Honor `composed` flag; default shadow-bounded |
| `Node.isConnected` | 1 | Shadow-inclusive root must be document |
| `Event.composedPath()` + retargeted `.target` | 2 | Per §4.4 |
| `HTMLSlotElement.assignedNodes/Elements/assign` | 3 | |
| `slotchange` event | 3 | |
| `:host`, scoped stylesheet matching | 3 | |

### 6. Phased Rollout

**Phase 1 — Tree scope + attachShadow (1 week)**
- Add `ShadowRoot` Zig struct, `shadow_roots` + `node_scope` maps on DocumentContext.
- Replace `elementAttachShadow` (`dom_element.zig:1498`) with real creation of a document fragment + ShadowRoot wrapper.
- Add ShadowRoot JS class with `host`, `mode`, `innerHTML`, `querySelector*`, `append*`, `getElementById`.
- Scope-tag nodes on insert; enforce scope boundary in `dom_api.zig` traversal helpers.
- Fix `getRootNode({composed})` and `isConnected` to honor scope.
- Tests: WPT `shadow-dom/ShadowRoot-interface.html`, `Element-interface-attachShadow.html`.

**Phase 2 — Event retargeting (1 week)**
- Refactor `dispatchEventWithObj` to build the composed path as tuples.
- Implement retarget algorithm; patch `target`/`currentTarget` per listener step.
- Closed-tree filtering of `composedPath()`.
- Tests: WPT `shadow-dom/event-*`.

**Phase 3 — Slots + style (1–3 weeks)**
- `<slot>` element class, assignment algorithm, `slotchange`.
- Flattened tree iterator consumed by layout.
- Scoped stylesheet list on ShadowRoot; selector matcher `scope_id` parameter; `:host` selector.
- Tests: WPT `shadow-dom/slots/*`, `css/css-scoping/*`.

---

## Open Questions / Risks

1. **lexbor mutation callbacks**: does every mutation path (parser, innerHTML setter, appendChild, replaceWith) go through a single chokepoint we can use to assign `shadow_root_id`? If not, we risk un-tagged nodes leaking scope. Needs a Phase 0 audit of insertion sites in `dom_element.zig` and the HTML parser adapter.
2. **Selector engine reuse**: the current querySelector uses lexbor's selector matcher. It may not expose a scope-predicate hook; we may need to wrap its walker with a post-filter (acceptable perf cost for Phase 1) or patch lexbor's callback.
3. **Custom element upgrade + shadow**: `connectedCallback` fires on shadow-inclusive connection; our current `isConnected` fix must land before custom elements (`web_api.zig:1738`) can be trusted inside shadow trees.
4. **Serialization**: `outerHTML` of a host should NOT include the shadow tree (unless declarative shadow DOM is opted in). Current serializer needs a scope check.
5. **WebDriver**: `src/net/webdriver.zig` references `shadowRoot`; verify the WebDriver shadow-root endpoint (`GET /element/:id/shadow`) maps to the new struct.
6. **Memory model**: ShadowRoot lifetime is tied to host element lifetime. On host removal from document, shadow stays attached (spec); on host GC, shadow and contents must be freed. Confirm with the existing JS finalizer path in `dom_api.zig`.

---

## Effort Estimate

| Phase | Eng-weeks | Risk |
|---|---|---|
| Phase 1 (scope + attachShadow) | 1.0 | Medium — traversal audit is broad |
| Phase 2 (retargeting) | 1.0 | Low — localized to `events.zig` |
| Phase 3 (slots + style) | 1.5–3.0 | Medium-high — layout integration + selector matcher changes |
| **Total** | **3.5–5.0** | |

Phase 1 alone unblocks the majority of "renders a template into a shadow root and queries inside it" component patterns, which is the most common real-world usage we see blocked today.
