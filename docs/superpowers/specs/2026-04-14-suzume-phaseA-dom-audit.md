# suzume Phase A — DOM + Events 仕様準拠監査

**Date:** 2026-04-14
**Scope:** `src/js/dom_*.zig` + `events.zig` vs WHATWG DOM Standard / HTML Standard
**Approach:** spec-driven — find violations of the spec, not WPT test hacks

---

## Executive Summary

1. **jsComposedPath() returns empty array** — Critical stub violation. Spec requires path to walk DOM tree from target to document root; currently returns `[]`, breaking event.composedPath() contract. Event dispatch already builds `_path` — jsComposedPath just ignores it.
2. **attachShadow() is pseudo-implementation** — Returns a fake shadow root object with delegated methods, not a true ShadowRoot. Shadow DOM is not isolated; tree queries and child manipulation still affect the main tree.
3. **elementFromPoint(x,y) stub** — Always returns `document.body || document.documentElement`, ignoring coordinates.
4. **Pre-insertion validation incomplete** — appendChild/insertBefore/replaceChild skip DOM §3.2.4 step 5.3 (Document with >1 element child).
5. **Event.initEvent() state reset missing** — Does not reset defaultPrevented/target/eventPhase per spec step 3.

---

## HIGH-PRIORITY VIOLATIONS

### 1. jsComposedPath() returns empty array instead of event path
- **File:** `events.zig:414–420`
- **Spec:** [DOM §4.4.3 Event.composedPath()](https://dom.spec.whatwg.org/#dom-event-composedpath)
- **Current:** `return qjs.JS_NewArray(c);` (always empty)
- **Expected:** Return `_path` property (already built during dispatch at `events.zig:983`)
- **Fix complexity:** S (1–2 lines)
- **Impact:** Breaks event delegation libraries that walk composedPath.

### 2. attachShadow() is a stub returning fake shadow root
- **File:** `dom_element.zig:1498–1524`
- **Spec:** [DOM §4.8.2 Element.attachShadow()](https://dom.spec.whatwg.org/#dom-element-attachshadow)
- **Current:** Creates plain JS object with copied methods; no tree isolation.
- **Expected:** Real ShadowRoot (DocumentFragment-like) with separate tree scope, slot distribution, retargeting.
- **Fix complexity:** L (requires lexbor tree compartmentalization)
- **Impact:** Web Components silently broken.

### 3. elementFromPoint(x, y) ignores coordinates
- **File:** `dom_api.zig:4433–4438`
- **Spec:** [CSSOM View §15.4.1](https://drafts.cssom.org/cssom-view/#dom-document-elementfrompoint)
- **Current:** `(function(x,y){return document.body||document.documentElement||null;})`
- **Expected:** Hit-test box tree for topmost element at viewport (x,y).
- **Fix complexity:** M (needs Box→coord lookup, ties to layout engine)
- **Impact:** Hit testing, testing frameworks (Playwright/Cypress).

### 4. Pre-insertion validation missing "one element per Document" check
- **File:** `dom_node.zig:759–772` (appendChild), similar in insertBefore/replaceChild
- **Spec:** [DOM §3.2.4 pre-insert step 5.3](https://dom.spec.whatwg.org/#concept-pre-insert)
- **Current:** Validates hierarchy/type but skips Document element-uniqueness.
- **Expected:** If parent is Document and node is Element, throw HierarchyRequestError if Document already has an Element child.
- **Fix complexity:** S (5 lines)
- **Impact:** Invalid multi-root documents pass validation.

### 5. Event dispatch side channel — cancelBubble sync is wrong
- **File:** `events.zig:623–630` (syncStopFlags)
- **Spec:** [DOM §4.4.3 legacy cancelBubble](https://dom.spec.whatwg.org/#dom-event-cancelbubble)
- **Current:** Treats cancelBubble as stop flag.
- **Expected:** cancelBubble is a legacy alias for the stopPropagation flag; setter sets it, but it's not the bubbles property.
- **Fix complexity:** S

### 6. Shadow DOM event retargeting missing
- **File:** `events.zig:505–520`, `983–1050`
- **Spec:** [DOM §4.4 Event Retargeting](https://dom.spec.whatwg.org/#retarget)
- **Current:** No retargeting. event.target always original node.
- **Expected:** Retarget target to host when event crosses shadow boundary.
- **Fix complexity:** L (depends on real shadow DOM)
- **Impact:** Deferred until attachShadow is real.

### 7. elementsFromPoint() stub
- **File:** `dom_api.zig:4437`
- **Spec:** [CSSOM View §15.4.2](https://drafts.cssom.org/cssom-view/#dom-document-elementsfrompoint)
- **Current:** Returns `[elementFromPoint(...)]`
- **Expected:** List all elements at (x,y) in paint order.
- **Fix complexity:** M

### 8. Node.getRootNode() missing `{composed}` option
- **File:** `dom_node.zig:2175–2200`
- **Spec:** [DOM §3.4.6](https://dom.spec.whatwg.org/#dom-node-getrootnode)
- **Current:** No options parameter; always walks to ultimate root.
- **Expected:** With `{composed: false}` (default), stop at shadow boundaries.
- **Fix complexity:** M (depends on shadow DOM; can implement option plumbing now)

### 9. Node.isConnected returns true for nodes in detached shadow roots / fragments
- **File:** `dom_node.zig:2233–2245`
- **Spec:** [DOM §3.4.8](https://dom.spec.whatwg.org/#dom-node-isconnected)
- **Current:** True if ultimate root is Document type.
- **Expected:** True iff shadow-including inclusive ancestor is a Document.
- **Fix complexity:** M

### 10. composedPath/retarget link — already-built _path discarded
- **Duplicate of #1 but emphasizing:** dispatch code at events.zig:983 builds `_path` correctly. The only gap is jsComposedPath returning it.

---

## MEDIUM-PRIORITY VIOLATIONS

### 11. documentCreateRange() non-functional
- `dom_api.zig:4431` — Range stub without getBoundingClientRect/compareBoundaryPoints.

### 12. importNode / adoptNode don't transfer ownerDocument
- `dom_api.zig:4389`/4801 — importNode just calls cloneNode; adoptNode is no-op.
- **Spec:** [DOM §3.5.1–3.5.2](https://dom.spec.whatwg.org/#dom-document-importnode)

### 13. Element.closest() ignores shadow boundaries
- `dom_selector.zig:1352–1378` — walks parent chain crossing shadow boundaries.

### 14. removeEventListener fails on callback-wrapper identity mismatch
- `events.zig:250–312` — matches by JS value pointer identity.

### 15. MutationObserver childList mutations truncated at 64
- `dom_serialize.zig:106–164` — fixed buffer `[64]` drops overflow.

### 16. Node.normalize() only handles Text, not Comment/PI
- `dom_node.zig:1637–1698`

### 17. Event.initEvent() doesn't reset defaultPrevented/target/eventPhase
- `events.zig:423–430` — only resets type/bubbles/cancelable.
- **Spec:** [DOM §4.4.1](https://dom.spec.whatwg.org/#dom-event-initevent) step 3.
- **Fix complexity:** S (5 lines)

### 18. Non-bubbling events fire in capture phase incorrectly
- `events.zig:1050–1100`

---

## LOW-PRIORITY / COSMETIC

19. Popover API stubs — `dom_api.zig:3417–3419`
20. attachShadow options validation — delegatesFocus unchecked
21. compareDocumentPosition uses JS eval fallback — `dom_node.zig:2018–2070`
22. Template.content returns fake DocumentFragment (div with overridden nodeType) — `dom_element.zig:2107–2134`

---

## DEFERRED / OUT-OF-SCOPE

- **Shadow DOM tree scoping** — requires lexbor compartmentalization (multi-week effort). Do Phase A fixes first, then dedicate a separate phase.
- **Cross-realm event dispatch** — needs multi-document support (iframes/workers).
- **Focus/activation (link traversal)** — needs layout engine integration.
- **Clipboard events** — platform integration.

---

## RECOMMENDED FIX ORDER

### Wave 1 — Cheap wins (~1 day total)
1. **jsComposedPath()** return `_path` property instead of empty array (S)
2. **appendChild Document element uniqueness** — pre-insert step 5.3 (S)
3. **insertBefore/replaceChild** same check (S)
4. **Event.initEvent() state reset** — defaultPrevented/target/eventPhase (S)
5. **Node.normalize()** handle Comment/PI (S)
6. **cancelBubble sync** cleanup (S)

### Wave 2 — Medium fixes (2–3 days)
7. **getRootNode({composed})** — add option plumbing (M)
8. **isConnected shadow-aware** check (M)
9. **importNode/adoptNode** ownerDocument transfer (M)
10. **removeEventListener** callback identity fix (M)
11. **MutationObserver buffer** — dynamic (M)

### Wave 3 — Deferred / coordinates
12. elementFromPoint real hit-test (M, needs layout)
13. Shadow DOM tree isolation (L, dedicated phase)

---

## CONCLUSION

Core DOM (~70% compliant) has critical gaps in event `composedPath`, Shadow DOM, and pre-insertion validation. Wave 1 (6 items, ~1 day) brings Phase A to ~85% compliance with minimal risk. Wave 2 closes remaining spec-level holes. Wave 3 requires bigger investment and can be split into dedicated sub-phases.
