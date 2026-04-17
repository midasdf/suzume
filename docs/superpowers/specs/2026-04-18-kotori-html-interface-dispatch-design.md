# kotori HTML Interface Dispatch + Native DOM Fixes — Design Spec

**Date**: 2026-04-18
**Scope**: dom/nodes 68.2% → ~77% via `createElement` / `createElementNS` HTML\*Element prototype dispatch, `ownerDocument` per-node slot, and `buildAttributesMap` lexbor iteration fix.
**Parent roadmap**: `docs/superpowers/specs/2026-04-17-kotori-suzume-wpt-100-roadmap.md` — Layer 1 (dom/nodes algorithms) sub-project.
**Approach**: Spec-driven (WHATWG DOM §4.5.3, HTML spec §4, WebIDL §3.7). No test-hacks.

---

## 1. Goal

Implement `createElement` / `createElementNS` so that elements receive the correct `HTML*Element` prototype per HTML spec §4, with spec-correct `ownerDocument` semantics and correct `attributes` NamedNodeMap iteration.

### Success Criteria (all required)

1. **Individual WPT files at 100%** (fresh measurement, TIMEOUT=30, `--jobs 4`):
   - `dom/nodes/Document-createElement.html` — **147 / 147**
   - `dom/nodes/Document-createElementNS.html` — **596 / 596**
   - `dom/nodes/attributes.html` — **100%** (baseline 32 fails resolved)
   - `dom/nodes/importNode.html` — **100%** (baseline 4 fails resolved)
2. **WHATWG DOM §4.5.3 compliance**:
   - `createElement` executes all 8 algorithm steps including tag validation, lowercasing for HTML documents, and "create an element" internal algorithm.
   - `createElementNS` dispatches HTML\*Element only when namespace is HTML (`http://www.w3.org/1999/xhtml`).
3. **HTML spec §4 compliance**: every element listed in the `Element interfaces` table is mapped to its declared interface via prototype chain.
4. **No dom/nodes regression**: Node-contains (1482/1482), compareDocumentPosition (1444/1444), dom/events (70/252), zig build test — all maintained.

### Non-goals (deferred to future specs)

- Reflected IDL attributes (`input.value`, `a.href`, `form.submit()`)
- Custom Elements registry (`customElements.define`)
- SVG / MathML interface dispatch
- Element upgrade on adoption
- classList Proxy indexed access (separate B-track)

---

## 2. Architecture

```
Object.prototype
  └─ Node.prototype (g_node_proto)
      ├─ CharacterData.prototype (g_chardata_proto)
      │   ├─ Text.prototype
      │   └─ Comment.prototype
      ├─ Document.prototype
      ├─ DocumentFragment.prototype
      ├─ DocumentType.prototype
      └─ Element.prototype (g_element_proto)
          └─ HTMLElement.prototype            ← NEW
              ├─ HTMLDivElement.prototype     ← NEW
              ├─ HTMLInputElement.prototype   ← NEW
              ├─ HTMLAnchorElement.prototype  ← NEW
              ├─ ... (~100 subclasses)        ← NEW
              └─ HTMLUnknownElement.prototype ← NEW (fallback)
```

### Dataflow: `document.createElement("div")`

```
1. JS call → kotori_dom.zig createElement native
2. Tag validation (DOM §4.5.3 step 1-3, existing code)
3. Lowercase tag for HTML docs (step 4, existing code)
4. lxb_dom_document_create_element_noi (lexbor)
5. Wrap into JsObject (existing g_node_cache path)
6. NEW: kotori_html_interfaces.resolveHtmlInterface("div") → "HTMLDivElement"
7. NEW: lookup proto by interface name (comptime map), assign to obj.prototype
8. NEW: set obj._ownerDoc internal slot = creating document
9. Return JsValue.{ .object = obj }
```

---

## 3. Components

### 3.1 `ownerDocument` getter fix — DOM §4.4

**Current** (`src/js/kotori_dom.zig` L1115-1116):
```zig
// Node.ownerDocument — null for Document nodes (DOM §4.4)
if (eql(name, "ownerDocument")) return JsValue.{ .object = globalThis.document };
```

**Design**:
- Add internal slot `_ownerDoc` (hidden property, not enumerable) to every Node JsObject at creation time.
- Refactor the getter to read from the slot; Document itself returns `JsValue.null_val` (DOM §4.4).
- All existing `ownerDocument` setters (L1762, L2051, L2439, L5200, L5247, L5326) migrate to writing the `_ownerDoc` slot through a single helper `setNodeOwnerDoc(obj, doc)`.
- `importNode` (DOM §4.5 step 5) sets the slot to the **target** document on every cloned node in the subtree.
- `adoptNode` switches the slot on the adopted subtree.

**Helper placement**: `kotori_dom.zig` top (near `setNodePrototype` existing helper).

### 3.2 `buildAttributesMap` fix — DOM §4.9.1

**Current** (`src/js/kotori_dom.zig` L3847+): walks `a.node.next`, which traverses the generic node sibling list, not the attribute list. Only the first attribute is exposed via `el.attributes[i]`.

**Fix**: use the lexbor-provided iterator:
```zig
var cur: ?*lxb.lxb_dom_attr_t = lxb.lxb_dom_element_first_attribute_noi(elem);
while (cur) |a| : (cur = lxb.lxb_dom_element_next_attribute_noi(a)) {
    // register a into NamedNodeMap
}
```

`NamedNodeMap` must expose:
- `.length` — count
- `[i]` indexed access (spec-ordered: insertion order per lexbor)
- `.getNamedItem(name)`, `.setNamedItem(attr)`, `.removeNamedItem(name)` (existing, still backed by the map)

### 3.3 `kotori_html_interfaces.zig` — new module

Single responsibility: **tag name → interface name** lookup.

**Public API**:
```zig
pub fn resolveHtmlInterface(tag_lower: []const u8) []const u8;
// Returns interface name like "HTMLDivElement". Unknown → "HTMLUnknownElement".

pub fn isKnownHtmlTag(tag_lower: []const u8) bool;
// Used by parser wrap path to decide HTMLUnknownElement vs HTMLElement dispatch.
```

**Internal**:
```zig
const interface_table = std.StaticStringMap([]const u8).initComptime(.{
    .{ "a", "HTMLAnchorElement" },
    .{ "abbr", "HTMLElement" },
    .{ "address", "HTMLElement" },
    .{ "area", "HTMLAreaElement" },
    // ... ~100 entries from HTML spec §4
});
```

**Source of truth**: [HTML Living Standard §4](https://html.spec.whatwg.org/multipage/indices.html#element-interfaces) Element interfaces table — transcribed verbatim.

### 3.4 HTMLElement prototype hierarchy

**Placement**: extend `kotori_dom.zig` near the existing `HTMLElement` ctor registration (L727-L753). The constructor globals are already registered; this spec connects their `.prototype` objects into the chain and populates the subclass prototypes.

**Generated structure** (at `initGlobalPrototypes()` time, once per VM init):
```zig
// After g_element_proto exists:
g_html_element_proto = createProto(vm, g_element_proto, "HTMLElement");

// Comptime iterate interface_table values → unique interface names
// For each unique interface name, create proto with parent = g_html_element_proto
// Register under `g_html_protos: std.StaticStringMap(*JsObject)`
g_html_protos = buildHtmlProtoMap(vm, g_html_element_proto);

// Wire ctor.prototype = proto for each HTML*Element constructor registered at L727-L753
```

**Key constraints**:
- Prototypes are **frozen** (setProperty of prototype chain members is rejected) so the VM's inline cache can rely on them.
- No per-instance proto mutation after creation; all dispatch happens at creation time.

### 3.5 Integration into 3 creation paths

All three paths below must call a new helper `applyHtmlInterfaceProto(obj, tag_lower, namespace, owner_doc)` before returning the wrapped object:

1. **`document.createElement(tag)`** (kotori_dom.zig createElement native) — namespace = HTML_NS by default for HTML docs.
2. **`document.createElementNS(ns, qname)`** (kotori_dom.zig createElementNS native) — namespace = ns arg; dispatch HTML\*Element only if ns == HTML_NS **and** qname is lowercase.
3. **HTML parser wrap path** (`wrapExistingNode` or equivalent when lexbor-parsed elements first reach JS) — namespace from lexbor node, tag from lexbor local name.

The helper:
```zig
pub fn applyHtmlInterfaceProto(
    obj: *JsObject,
    tag_lower: []const u8,
    namespace: []const u8,
    owner_doc: *JsObject,
) void {
    setNodeOwnerDoc(obj, owner_doc);
    if (!std.mem.eql(u8, namespace, HTML_NS)) {
        obj.prototype = g_element_proto; // non-HTML stays Element
        return;
    }
    if (!isLowercaseAscii(tag_lower)) {
        obj.prototype = g_html_unknown_proto;
        return;
    }
    const iface = kotori_html_interfaces.resolveHtmlInterface(tag_lower);
    obj.prototype = g_html_protos.get(iface) orelse g_html_unknown_proto;
}
```

---

## 4. Edge Cases & Error Handling

| Input | Expected | Spec |
|---|---|---|
| `createElement("DIV")` on HTML doc | lowercased → HTMLDivElement | DOM §4.5.3 step 4 |
| `createElement("DIV")` on XML doc | HTMLUnknownElement (HTML NS, non-lowercase) | DOM §4.5.3 + HTML §3.2 |
| `createElement("foo-bar")` | HTMLElement (valid custom name, no registry) | HTML §4.13 (registry OOS) |
| `createElement("xfoo")` | HTMLUnknownElement (unknown tag) | HTML §4.0 |
| `createElement("123")` | throws `InvalidCharacterError` | DOM §4.5.3 step 1 |
| `createElementNS(null, "div")` | Element (null namespace, no HTML dispatch) | DOM §4.5.3 step 7 |
| `createElementNS(HTML_NS, "div")` | HTMLDivElement | DOM §4.5.3 + HTML §4 |
| `createElementNS(HTML_NS, "DIV")` | HTMLUnknownElement | HTML §3.2 (HTML NS requires lowercase) |
| `createElementNS(SVG_NS, "circle")` | Element (SVG not in scope) | Non-goal |
| `Document.ownerDocument` | `null` | DOM §4.4 |
| `doc.createElement("div").ownerDocument` | `doc` (not globalThis.document) | DOM §4.4 |
| `target.importNode(node, true)` | clone's ownerDoc = target (recursive) | DOM §4.5 step 5 |
| `el.attributes[i]` for i < length | Attr node at spec-ordered index i | DOM §4.9.1 |

---

## 5. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| `_ownerDoc` slot migration breaks code paths that relied on `globalThis.document` fallback | dom/nodes subtests regress | After P1, run dom/nodes WPT and compare vs baseline; fix any regressions before proceeding |
| Deep prototype chain slows VM property lookup | Test timeouts | Freeze prototypes so VM inline cache applies; benchmark a representative element-heavy test (e.g., `Node-contains`) pre/post |
| 100 subclass prototypes at VM init slow startup | Cold-start latency | Use `comptime` to build the proto map once per VM; lazy-init optional if measured slow |
| HTML parser path `wrapExistingNode` missed | Parser-created elements get HTMLUnknownElement | P4 audit: grep all lexbor element wrap sites, ensure all go through `applyHtmlInterfaceProto` |
| Flaky WPT measurements | False pass/fail on 100% criterion | Require 3 consecutive identical runs before declaring success |
| Attribute insertion order changes break attributes.html assertions | Expected order vs lexbor order mismatch | Verify lexbor iteration order matches spec's insertion order via unit test with fixture |

---

## 6. Testing

### 6.1 Unit tests (`tests/test_kotori_dom.zig`, extend)

Minimum 15 tests:

```
createElement('div')   → HTMLDivElement prototype
createElement('DIV')   → HTMLDivElement (lowercased, HTML doc)
createElement('input') → HTMLInputElement
createElement('xfoo')  → HTMLUnknownElement
createElement('foo-bar') → HTMLElement
createElement('123')   → throws InvalidCharacterError
createElementNS(null, 'div')   → Element only
createElementNS(HTML_NS, 'div') → HTMLDivElement
createElementNS(HTML_NS, 'DIV') → HTMLUnknownElement
createElementNS(SVG_NS, 'circle') → Element only
instanceof HTMLElement works (positive + negative)
instanceof HTMLDivElement works (positive + negative)
doc.createElement('div').ownerDocument === doc
Document.ownerDocument === null
importNode cross-doc sets target as ownerDocument recursively
buildAttributesMap exposes all attributes via el.attributes[i]
el.attributes.length matches attribute count
```

`zig build test` green is a Phase gate.

### 6.2 WPT verification

```bash
cd ~/suzume
# Targeted 4-file run
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
  dom/nodes/Document-createElement.html \
  dom/nodes/Document-createElementNS.html \
  dom/nodes/attributes.html \
  dom/nodes/importNode.html

# Full dom/nodes regression check
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/nodes

# dom/events regression check
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/events
```

Success gate: targeted run at 100%, full `dom/nodes` ≥ 6050/7869 (~77%), `dom/events` ≥ 70/252, `Node-contains` = 1482/1482, `compareDocumentPosition` = 1444/1444.

### 6.3 Verification separation

Implementation and verification run in **different contexts** (OMC rule: no self-approval). A separate `verifier` agent runs the WPT suite, compares against spec checklist, and reports.

---

## 7. Implementation Phases

| Phase | Content | LOC | Time | Deps |
|---|---|---|---|---|
| P1 | `ownerDocument` slot + `setNodeOwnerDoc` helper + migrate 6 existing writers + `buildAttributesMap` lexbor fix | ~150 | 0.5d | — |
| P2 | `kotori_html_interfaces.zig` new module, ~100-entry StaticStringMap | ~250 | 0.5d | — (parallel with P1) |
| P3 | `HTMLElement` + ~100 subclass + `HTMLUnknownElement` prototype hierarchy, frozen | ~400 | 1d | P1, P2 |
| P4 | `applyHtmlInterfaceProto` helper + integration into createElement, createElementNS, parser wrap paths | ~200 | 0.5d | P3 |
| P5 | Unit tests (≥15), `zig build test` full pass | ~300 | 0.5d | P4 |
| P6 | WPT measurement (4-file targeted + dom/nodes regression + dom/events regression), verifier sign-off | — | 0.5d | P5 |
| **Total** | | **~1,300** | **~3.5d** | |

### Commit plan (atomic, one per Phase)

1. `fix(kotori): ownerDocument uses per-node _ownerDoc slot (DOM §4.4)`
2. `fix(kotori): buildAttributesMap uses lexbor next_attribute_noi (DOM §4.9.1)`
3. `feat(kotori): add kotori_html_interfaces tag→interface resolver (HTML §4)`
4. `feat(kotori): HTMLElement + ~100 subclass prototype hierarchy`
5. `feat(kotori): createElement/createElementNS dispatches HTML*Element prototype (DOM §4.5.3)`
6. `test(kotori): HTML interface dispatch + attribute iteration WPT coverage`

---

## 8. Open Questions (to resolve during writing-plans)

- Do any existing tests in `tests/test_kotori_dom.zig` rely on `ownerDocument === globalThis.document`? Audit during P1.
- Does `wrapExistingNode` (parser path) currently run at document load time or on first JS access? Determines whether P4 can use the existing call site or needs a new hook.
- Is the lexbor `next_attribute_noi` symbol already re-exported through `lxb.zig`? If not, P1 adds the binding.

These are implementation-detail questions best answered while drafting the plan with real file reads, not design-level blockers.

---

## 9. References

- [WHATWG DOM §4.5.3 Document.createElement / createElementNS](https://dom.spec.whatwg.org/#dom-document-createelement)
- [WHATWG DOM §4.4 Node.ownerDocument](https://dom.spec.whatwg.org/#dom-node-ownerdocument)
- [WHATWG DOM §4.9 Element attributes / NamedNodeMap](https://dom.spec.whatwg.org/#interface-namednodemap)
- [HTML Living Standard §3.2 Semantics, structure, APIs](https://html.spec.whatwg.org/multipage/dom.html)
- [HTML Living Standard §4 The elements of HTML](https://html.spec.whatwg.org/multipage/semantics.html)
- [HTML Living Standard — Element interfaces index](https://html.spec.whatwg.org/multipage/indices.html#element-interfaces)
- [WebIDL §3.7 Platform objects](https://webidl.spec.whatwg.org/#dfn-platform-object)
- Master roadmap: `docs/superpowers/specs/2026-04-17-kotori-suzume-wpt-100-roadmap.md` (Layer 1)
