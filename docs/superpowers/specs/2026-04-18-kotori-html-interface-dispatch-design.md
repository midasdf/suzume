# kotori HTML/SVG/MathML Interface Dispatch + Native DOM Fixes — Design Spec

**Date**: 2026-04-18 (revised after critic review)
**Scope**: dom/nodes 68.2% → ~77% via `createElement` / `createElementNS` interface prototype dispatch (HTML + minimal SVG/MathML), per-node `ownerDocument` slot (DOM §4.4), live `NamedNodeMap` with attr identity (DOM §4.9.1), and `buildAttributesMap` lexbor iteration fix.
**Parent roadmap**: `docs/superpowers/specs/2026-04-17-kotori-suzume-wpt-100-roadmap.md` — Layer 1 (dom/nodes algorithms) sub-project.
**Approach**: Spec-driven (WHATWG DOM §4.5.3, §4.4, §4.9.1; HTML §4; SVG2 §4; MathML Core §2; WebIDL §3.7). No test-hacks.

---

## 1. Goal & Success Criteria

Implement `createElement` / `createElementNS` so that elements receive the correct interface prototype per HTML §4, SVG2 §4, and MathML Core §2, with spec-correct `ownerDocument` semantics and a live `NamedNodeMap` with stable Attr identity.

### Success Criteria (all required)

1. **Individual WPT files (fresh measurement, TIMEOUT=30, `--jobs 4`)**:
   - `dom/nodes/Document-createElement.html` — **100%** (baseline 9/147)
   - `dom/nodes/Document-createElementNS.html` — **≥ 95%** (596 subtests; last 5% gate allowed for exotic SVG/MathML edge cases deferred)
   - `dom/nodes/attributes.html` — **100%** (baseline 32 fails resolved)
   - `dom/nodes/importNode.html` — **100%** (baseline 4 fails resolved)
2. **WHATWG DOM §4.5.3** — all 8 algorithm steps honored; HTML dispatch only when namespace = `http://www.w3.org/1999/xhtml`.
3. **HTML §4** — every element in the HTML Element interfaces table mapped via prototype chain.
4. **SVG2 §4 + MathML Core §2** — minimum dispatch for core SVG (~20 tags) and MathML (~10 tags) elements so that `createElementNS(SVG_NS, "circle") instanceof SVGElement` succeeds.
5. **No regression**: Node-contains 1482/1482, compareDocumentPosition 1444/1444, dom/events 70/252, zig build test — all maintained.
6. **Shared-proto regression audit**: before P3 commit, diff WPT results with the `HTMLAnchorElement.prototype === HTMLDivElement.prototype` bug fix gated, confirm no net subtest loss.

### Non-goals (deferred to future specs)

- Reflected IDL attributes (`input.value`, `a.href`, `form.submit()`, `img.src`)
- Custom Elements registry (`customElements.define`, potentially-custom-element upgrade)
- `SVGSVGElement` / `SVGGraphicsElement` subclass-specific methods (e.g. `getBBox`)
- MathMLMathElement subclass-specific IDL
- Template content document owner semantics beyond what base `_ownerDoc` provides
- Shadow DOM element ownership
- classList Proxy indexed access (separate B-track spec)

---

## 2. Architecture

```
Object.prototype
  └─ EventTarget.prototype
      └─ Node.prototype (g_node_proto)
          ├─ CharacterData.prototype → Text / Comment / ProcessingInstruction
          ├─ Document.prototype (+ XMLDocument.prototype, HTMLDocument = Document)
          ├─ DocumentFragment.prototype
          ├─ DocumentType.prototype
          └─ Element.prototype (g_element_proto)
              ├─ HTMLElement.prototype (g_html_element_proto)         ← NEW
              │   ├─ HTMLDivElement.prototype                         ← NEW
              │   ├─ HTMLInputElement.prototype                       ← NEW
              │   ├─ HTMLAnchorElement.prototype                      ← NEW
              │   ├─ ... (~70 HTML subclasses matching L743-L768)     ← NEW
              │   └─ HTMLUnknownElement.prototype                     ← NEW
              ├─ SVGElement.prototype (g_svg_element_proto)           ← NEW
              │   ├─ SVGGraphicsElement.prototype                     ← NEW (minimal)
              │   ├─ SVGSVGElement.prototype, SVGCircleElement, ...   ← NEW (~20)
              │   └─ SVGUnknownElement fallback = SVGElement          ← NEW
              └─ MathMLElement.prototype (g_mathml_element_proto)     ← NEW
                  └─ ~10 MathML subclasses                            ← NEW
```

### Dataflow: `document.createElement("div")`

```
1. JS call → kotori_dom.zig createElement native (existing)
2. Tag validation + lowercase (existing, DOM §4.5.3 steps 1-4)
3. lxb_dom_document_create_element_noi (lexbor)
4. wrapNode(node) (existing L3796)
   ├─ nodeCacheGet — return if hit
   ├─ create JsObject
   ├─ NEW: resolve interface via kotori_html_interfaces + assign prototype
   ├─ NEW: write _ownerDoc internal slot to the caller document
   └─ nodeCachePut (after proto+slot set)
5. Return
```

### Dataflow: `doc.createElementNS(SVG_NS, "circle")`

```
1. createElementNS native (existing)
2. Namespace + qname validation
3. lxb_dom_document_create_element_noi with ns id
4. wrapNode → interface resolver dispatches on namespace
   HTML_NS + lowercase local → HTML table
   SVG_NS  → SVG table (fallback SVGElement)
   MathML_NS → MathML table (fallback MathMLElement)
   else → Element (g_element_proto)
5. _ownerDoc = target doc
```

---

## 3. Components

### 3.1 `_ownerDoc` internal slot + full wrapper audit — DOM §4.4

**Reality check** (verified against `kotori_dom.zig` HEAD = `da2b99a`):
- L1115-1116 getter: returns `globalThis.document` → wrong for every cross-doc case.
- L1762 `createJsOnlyElement`: writes `ownerDocument` = **`JsValue.null_val`** as an ordinary property. The globalThis.document in §1115 masks this null today; removing the mask without writing the slot regresses XML-doc elements.
- L2051 inside Attr builder: property, not slot.
- L2439 DocumentType JS init: property.
- L5200 impl.createDocument: property on returned doc's root.
- L5247 impl.createDocument.createElement path: property.
- L5326 impl.createDocumentType: property.

**Design**:

- **Convention**: every Node JsObject carries `_ownerDoc` interned property name (U+005F prefix distinguishes it from the JS-visible `ownerDocument`). It is **not enumerable**. It stores the owner `*JsObject` directly (document object), or `JsValue.null_val` for Document itself.
- **Single helper**:
  ```zig
  fn setNodeOwnerDoc(vm: *VM, obj: *JsObject, owner_doc_val: JsValue) void;
  fn getNodeOwnerDoc(vm: *VM, obj: *JsObject) JsValue; // returns null_val for Document
  ```
- **Getter rewrite** (L1115): reads `_ownerDoc` via `getNodeOwnerDoc`; returns it directly — no globalThis fallback.
- **All wrapper/creator call sites must write the slot**:

  | Site (file:line) | Current state | Required change |
  |---|---|---|
  | `createJsOnlyElement` L1742 | writes `null_val` property (masked) | write `_ownerDoc` via helper; arg `owner_doc: *JsObject` now required |
  | `wrapNode` L3796 | no slot write | resolve owner via lexbor `node.owner_document` or cache parent; write slot before `nodeCachePut` |
  | Attr builder ~L2014 | property | slot write with ownerDoc from Attr's owning element |
  | DocumentType L2439 | property | slot |
  | impl.createDocument L5200/L5247/L5326 | property | slot (owner = the newly created doc) |
  | `cloneNode` (located at runtime audit in P1) | whatever | slot = target doc per DOM §4.5 "clone a node" |
  | `importNode` native L2323 | property (verified in P0 audit) | slot = target doc (recursive) |

- **`wrapNode` owner-doc resolution**: lexbor provides `node->owner_document`. Cast to `*lxb_dom_document_t`, find its cached JS wrapper in `g_node_cache`, fall back to lazy-wrap the document. If the document node is not yet cached (first entry), wrap it first, then element. Document.ownerDocument = null per DOM §4.4 — handle before slot write.

**Removed**: the L1115 globalThis.document fallback.

### 3.2 `importNode` JS polyfill removal + native rewrite — DOM §4.5

**Current state**: `kotori_runtime.zig` L1500-1521 installs a JS-level `Document.prototype.importNode` polyfill that clones and calls a JS helper `stampOwnerDocument`. With `_ownerDoc` slot in place, the polyfill is obsolete and actively harmful (it overrides native dispatch).

**Action**:
- Delete L1500-1521 from `kotori_runtime.zig` (the `function importNode(node, deep){ ... }` block, the `Document.prototype.importNode = importNode` assignment, and the `document.importNode.bind` line).
- Also delete the `stampOwnerDocument` helper if it's only called from here (grep and confirm before delete).
- Keep `wrapDocCreators` and `cloneNodeInto` — they serve other purposes.
- The native `nativeImportNode` (existing at ~L2323 of `kotori_dom.zig`) becomes the sole path. Rewrite it to do "clone a node" (DOM §4.4.1) recursively, passing `target_doc` as owner for every cloned node.

### 3.3 `buildAttributesMap` fix + live NamedNodeMap — DOM §4.9.1

**Precise fix at `kotori_dom.zig:3887`**: `attr = @ptrCast(@alignCast(a.node.next));` → use lexbor's attribute iterator:
```zig
attr = @ptrCast(@alignCast(dom_b.lxb_dom_element_next_attribute_noi(a)));
```

**But this is not enough for `attributes.html` 100%.** DOM §4.9.1 requires:
- **Live map**: `el.attributes.length` must reflect current attribute count when read — NOT a snapshot.
- **Stable Attr identity**: `el.attributes[0] === el.attributes[0]` must be true in the same microtask.
- **Named access**: `el.attributes.getNamedItem(name)`, indexed & named bracket access consistent.

**Design**:

- **Element-level caches** on the Element JsObject:
  - `_attrMap`: cached NamedNodeMap JsObject (single instance per element); built on first `.attributes` access, reused thereafter.
  - `_attrWrappers`: `HashMap(*lxb_dom_attr_t → *JsObject)` caching Attr JS wrappers by pointer so `el.attributes[0] === el.attributes[0]`.

- **Access model**: the cached `_attrMap` exposes `.length` and indexed access via a **custom property getter** (not a snapshot). On every access, it iterates lexbor, syncs the map's enumerable `[0]..[length-1]` indices and named properties, and returns.

- **Simpler fallback if the full live proxy is too much for this spec**: keep NamedNodeMap re-built each access but cache Attr wrappers by pointer, so identity holds within a single microtask session. Rebuild is O(attr_count), which is ≤ 10 for typical elements. **This is the path of least risk; committed in P2b.**

- **Invalidation**: `setAttribute` / `removeAttribute` / `setAttributeNS` / `removeAttributeNS` must invalidate the indexed map (but keep the Attr wrapper cache, since Attr objects survive until lexbor frees them).

### 3.4 `kotori_html_interfaces.zig` — new module

Single responsibility: **(namespace, tag) → interface name** lookup.

**Public API**:
```zig
pub const HTML_NS = "http://www.w3.org/1999/xhtml";
pub const SVG_NS  = "http://www.w3.org/2000/svg";
pub const MATH_NS = "http://www.w3.org/1998/Math/MathML";

pub fn resolveInterface(namespace: ?[]const u8, local_name: []const u8) []const u8;
// Returns "HTMLDivElement" / "SVGCircleElement" / "MathMLIdentifierElement" / etc.
// - null namespace → "Element"
// - HTML_NS + lowercase known tag → mapped HTMLXxxElement
// - HTML_NS + lowercase unknown tag → "HTMLUnknownElement"
//   (valid custom element name check deferred — Non-goal, currently treat as HTMLElement)
// - HTML_NS + non-lowercase → "HTMLUnknownElement"
// - SVG_NS + known tag → mapped SVGXxxElement; else "SVGElement"
// - MATH_NS → "MathMLElement" (no per-tag dispatch needed for WPT pass)
// - else → "Element"

pub fn isKnownHtmlTag(local_name: []const u8) bool;
pub fn isKnownSvgTag(local_name: []const u8)  bool;
```

**Internal tables**:
```zig
const html_iface = std.StaticStringMap([]const u8).initComptime(.{
    .{ "a", "HTMLAnchorElement" },
    .{ "abbr", "HTMLElement" }, // generic HTMLElement
    // ... ~100 HTML entries from HTML §4 indices
});

const svg_iface = std.StaticStringMap([]const u8).initComptime(.{
    .{ "svg", "SVGSVGElement" },
    .{ "circle", "SVGCircleElement" },
    .{ "rect", "SVGRectElement" },
    .{ "path", "SVGPathElement" },
    .{ "g", "SVGGElement" },
    .{ "text", "SVGTextElement" },
    // ... ~20 core SVG entries from SVG2 §4 index
});
// MathML: all elements map to "MathMLElement" in this spec; future spec can add per-element.
```

**Source of truth**:
- HTML: https://html.spec.whatwg.org/multipage/indices.html#element-interfaces
- SVG: https://svgwg.org/svg2-draft/types.html#InterfaceSummary
- MathML: https://w3c.github.io/mathml-core/#dom-and-javascript

### 3.5 Prototype hierarchy — fix shared-proto bug at L742

**Current bug** (`kotori_dom.zig` L742):
```zig
const html_elem_val = JsValue.initObject(ep);  // ep = g_element_proto
// L769-774: every HTMLXxxElement ctor gets html_elem_val as .prototype
```
All 67 HTML ctors share `g_element_proto`, making `div instanceof HTMLAnchorElement` accidentally `true`.

**Fix**:
1. Build `g_html_element_proto` parented to `g_element_proto`.
2. For every HTML interface name in `html_iface.values()` unique set (plus `HTMLElement` and `HTMLUnknownElement`):
   - Create prototype object with parent `g_html_element_proto`.
   - Register in a global `g_html_protos: std.StringHashMap(*JsObject)` (initialized once per VM, not static because it holds runtime pointers).
3. When wiring ctor globals at L769-774, look up the correct proto per ctor name; use `g_html_element_proto` for the special name "HTMLElement".
4. Same for SVG: `g_svg_element_proto` + per-name SVG prototypes in `g_svg_protos`.
5. Same for MathML: single `g_mathml_element_proto`.
6. **Freeze each prototype**: `proto.freeze(vm.allocator)` — confirmed available at `kotori/object.zig:429`. Rationale: spec correctness (prototype chain stability per HTML §4), not performance.

### 3.6 `applyInterfaceProto` helper + 3 integration sites

```zig
fn applyInterfaceProto(
    vm: *VM,
    obj: *JsObject,
    namespace: ?[]const u8,
    local_name: []const u8,
    owner_doc: JsValue,
) void {
    setNodeOwnerDoc(vm, obj, owner_doc);
    const iface = kotori_html_interfaces.resolveInterface(namespace, local_name);
    const proto = resolveProto(iface) orelse vm.element_proto.?;
    obj.prototype = proto;
}
```

**Integration sites** (real call sites verified against code):
1. `wrapNode` (`kotori_dom.zig:3796`) — replaces the `switch (nodeType(node))` block for ELEMENT nodes. Owner doc derived from `node->owner_document`. **Guard**: `if (g_html_protos == null) use element_proto only` — handles early boot where globalThis.document wrap fires before `initGlobalPrototypes` completes.
2. `createJsOnlyElement` (`kotori_dom.zig:1742`) — accepts an extra `owner_doc: JsValue` parameter; every call site updated to pass the creating document. XML doc path.
3. `nativeCloneNode` / cloneNode native path (located during P1 audit) — target = the original owner doc unless it's an `adoptNode` invocation.

### 3.7 Shared-proto regression audit (P3 gate)

Before the P3 commit lands:
1. Baseline: current HEAD WPT `dom/nodes` results by subtest name.
2. Apply **only** the ctor-prototype wiring change (no resolver active). Measure again.
3. Diff: any subtest that flipped PASS → FAIL is a shared-proto-dependent test. Collect the list.
4. Manually audit those failures: they are one of (a) test bug; (b) our dispatch is *stricter* than the spec (spec issue — fix resolver); or (c) legitimate regression (widen HTMLElement proto to include the missing method).
5. Record findings in the P3 commit body.

---

## 4. Edge Cases

| Input | Expected | Spec reference |
|---|---|---|
| `createElement("div")` HTML doc | HTMLDivElement prototype, ownerDoc = doc | DOM §4.5.3 + HTML §4 |
| `createElement("DIV")` HTML doc | lowercased → HTMLDivElement | DOM §4.5.3 step 4 |
| `createElement("foo-bar")` HTML doc | HTMLElement (custom-element-name logic deferred; Non-goal §1) | HTML §4.13 (OOS) |
| `createElement("xfoo")` HTML doc | HTMLUnknownElement | HTML §4.0 |
| `createElement("123")` | throws InvalidCharacterError | DOM §4.5.3 step 1 |
| `createElementNS(null, "div")` | Element (no interface dispatch) | DOM §4.5.3 step 7 |
| `createElementNS(HTML_NS, "div")` | HTMLDivElement | DOM §4.5.3 + HTML §4 |
| `createElementNS(HTML_NS, "DIV")` | HTMLUnknownElement | HTML §3.2 |
| `createElementNS(SVG_NS, "circle")` | SVGCircleElement | SVG2 §4 |
| `createElementNS(SVG_NS, "foo")` | SVGElement (unknown SVG → fallback) | SVG2 §4 |
| `createElementNS(MATH_NS, "mi")` | MathMLElement | MathML Core §2 |
| `Document.ownerDocument` | null | DOM §4.4 |
| `doc.createElement("div").ownerDocument` | `doc` | DOM §4.4 |
| `(new XMLDocument()).createElement("div").ownerDocument` | the XMLDocument | DOM §4.4 |
| `target.importNode(node, true).ownerDocument` | target (recursive) | DOM §4.5 + §4.4 |
| `el.attributes[0] === el.attributes[0]` | true in same microtask | DOM §4.9.1 |
| `el.setAttribute("x","1"); el.attributes.length` | increments by 1 (live) | DOM §4.9.1 |
| `el.removeAttribute("x"); "x" in el.attributes` | false (live) | DOM §4.9.1 |

---

## 5. Risks & Mitigations

| Risk | Severity | Impact | Mitigation |
|---|---|---|---|
| `_ownerDoc` slot migration misses a wrapper path → silent regression | **High** | XML-doc or cloneNode elements report wrong ownerDoc | §3.1 enumerates every wrapper; P1 audit task literally greps `vm.createObj(.{ .obj_type = .dom_node })` and verifies each hit calls `setNodeOwnerDoc` |
| `importNode` polyfill removal breaks callers expecting JS-level behavior | **Medium** | importNode-related tests regress | Native rewrite done in same commit; `zig build test` + targeted `importNode.html` run before commit; if regression, revert polyfill + iterate |
| Shared-proto regression (M7) | **High** | Tests passing today via `div instanceof HTMLAnchorElement == true` bug flip to FAIL | §3.7 audit; may adjust HTMLElement.prototype method set if we find missing shared methods |
| SVG/MathML dispatch incomplete → `createElementNS` gate at 95% instead of 100% | Medium | Success criterion 1b already allows 95% for this | Document remaining 5% as follow-up WPT list in commit body |
| NamedNodeMap liveness via per-access rebuild is O(n); pathological tests with 1000+ attrs slow | Low | Harness timeout | Typical elements have ≤10 attrs; benchmark attribute-heavy fixtures during P2b |
| Deep prototype chain slows VM property lookup | Low | WPT timeout | Zig 0.15.2 VM has no inline-cache (confirmed by absence of `ic` keyword in vm.zig); freezing is only for spec correctness. If measurably slow, add IC in follow-up spec |
| `g_html_protos` HashMap at init inflates binary size | Low | RPi Zero 2W 5MB budget | ~100 × 200 byte + StringHashMap overhead ≈ 30 KB; well within budget |
| Lexbor `node->owner_document` null for detached nodes | Medium | `wrapNode` slot write panics or writes null | Use `vm.current_document` as fallback (existing VM field if present; else globalThis.document wrap) |
| Attr wrapper cache leaks after lexbor frees attr | Medium | UAF | Clear `_attrWrappers` on attribute removal via setAttribute/removeAttribute native hooks |

---

## 6. Testing

### 6.1 Unit tests (`tests/test_kotori_dom.zig`, extend — minimum 18)

```
[dispatch]
 1. createElement('div')   prototype === HTMLDivElement.prototype
 2. createElement('DIV')   prototype === HTMLDivElement.prototype (lowercased)
 3. createElement('input') prototype === HTMLInputElement.prototype
 4. createElement('xfoo')  prototype === HTMLUnknownElement.prototype
 5. createElement('foo-bar') prototype === HTMLElement.prototype
 6. createElement('123')   throws InvalidCharacterError
 7. createElementNS(null, 'div')      is Element only (not HTMLDivElement)
 8. createElementNS(HTML_NS, 'div')   is HTMLDivElement
 9. createElementNS(HTML_NS, 'DIV')   is HTMLUnknownElement
10. createElementNS(SVG_NS, 'circle') is SVGCircleElement AND SVGElement AND Element
11. createElementNS(SVG_NS, 'foo')    is SVGElement only
12. createElementNS(MATH_NS, 'mi')    is MathMLElement
[instanceof negative — ensures shared-proto bug is gone]
13. div instanceof HTMLAnchorElement === false
14. svg_circle instanceof HTMLElement === false
[ownerDoc]
15. doc.createElement('div').ownerDocument === doc
16. Document.ownerDocument === null
17. doc2.importNode(doc1.createElement('div'), true).ownerDocument === doc2 (recursive)
[attributes]
18. el.setAttribute('a','1'); el.setAttribute('b','2'); el.attributes.length === 2 && el.attributes[1].name === 'b'
19. el.attributes[0] === el.attributes[0] (Attr identity)
20. el.removeAttribute('a'); el.attributes.length === 1 (liveness)
```

`zig build test` must be green at every Phase gate.

### 6.2 WPT verification matrix

```bash
cd ~/suzume
# Gate A — 4 targeted files
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
  dom/nodes/Document-createElement.html \
  dom/nodes/Document-createElementNS.html \
  dom/nodes/attributes.html \
  dom/nodes/importNode.html

# Gate B — dom/nodes full
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/nodes

# Gate C — dom/events regression
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/events

# Gate D — html/dom regression (first touch)
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 html/dom
```

Success gates:
- Gate A: 3 of 4 files at 100% (createElementNS ≥ 95%).
- Gate B: total dom/nodes ≥ **6050/7869** (~77%); Node-contains 1482/1482 preserved; compareDocumentPosition 1444/1444 preserved.
- Gate C: dom/events ≥ 70/252 preserved.
- Gate D: html/dom — record baseline on first run; no regression worse than −20 subtests (tolerance for first measurement variance).
- 3 consecutive identical runs required before declaring success (measurement discipline).

### 6.3 Verification separation

Writer agent implements; verifier agent (different context) runs WPT + spec-checklist sign-off. No self-approval.

---

## 7. Implementation Phases

| Phase | Content | LOC | Time | Deps |
|---|---|---|---|---|
| **P0** | Full wrapper-site audit: grep `createObj(.{ .obj_type = .dom_node })` + `createJsOnlyElement` callers + `cloneNode` path; produce exhaustive `_ownerDoc` write-site list | — | 0.5d | — |
| **P1a** | `setNodeOwnerDoc` helper + getter rewrite + migrate every P0-enumerated site | ~200 | 0.5d | P0 |
| **P1b** | Remove `importNode` JS polyfill (`kotori_runtime.zig:1500-1521`); rewrite native `nativeImportNode` for recursive clone with target doc | ~150 | 0.5d | P1a |
| **P1c** | `buildAttributesMap` L3887 fix + Attr wrapper cache + liveness wrapper | ~200 | 0.5d | — (parallel with P1a/P1b) |
| **P2**  | `kotori_html_interfaces.zig` new module: HTML ~100 + SVG ~20 + MathML 1 entries, `resolveInterface`, namespace constants | ~350 | 1d | — |
| **P3a** | Build `g_html_element_proto`, `g_svg_element_proto`, `g_mathml_element_proto`, and all subclass prototypes; `g_html_protos`/`g_svg_protos` HashMaps; freeze all | ~300 | 0.5d | P2 |
| **P3b** | Fix L742 shared-proto bug: each ctor gets its matching prototype | ~50 | 0.25d | P3a |
| **P3c** | **Shared-proto regression audit** (§3.7): baseline → P3b only → diff → fix/document | — | 0.5d | P3b |
| **P4**  | `applyInterfaceProto` helper + wire into `wrapNode`, `createJsOnlyElement`, `nativeCloneNode` | ~200 | 0.5d | P1a, P3c |
| **P5**  | Unit tests (≥18); `zig build test` full green | ~400 | 0.5d | P4 |
| **P6**  | WPT gate A/B/C/D (verifier agent); 3-run stability check; final commit | — | 0.5d | P5 |
| **Total** | | **~1,650** | **~5.25d** | |

### Commit plan (8 atomic commits)

1. `fix(kotori): ownerDocument uses per-node _ownerDoc slot across all wrapper sites (DOM §4.4)`
2. `refactor(kotori): remove JS importNode polyfill; native handles recursive clone with target doc`
3. `fix(kotori): buildAttributesMap uses lexbor next_attribute + live map + Attr identity cache (DOM §4.9.1)`
4. `feat(kotori): add kotori_html_interfaces resolver (HTML §4 + SVG2 §4 + MathML Core §2)`
5. `feat(kotori): HTMLElement/SVGElement/MathMLElement prototype hierarchy with per-subclass protos`
6. `fix(kotori): wire HTML*/SVG*/MathMLElement ctors to their own prototypes (shared-proto audit: N tests affected — see body)`
7. `feat(kotori): wrapNode + createJsOnlyElement dispatch interface prototype on creation (DOM §4.5.3)`
8. `test(kotori): interface dispatch + ownerDoc + NamedNodeMap WPT coverage`

---

## 8. Design Decisions (resolved from open questions)

- **`JsObject.freeze`** — confirmed at `src/js/kotori/object.zig:429`. Used for prototype immutability per HTML §4 spec requirement.
- **`wrapNode` vs `wrapExistingNode`** — there is no `wrapExistingNode`. `wrapNode` at `kotori_dom.zig:3796` is the sole JS-wrapper entry for parser-produced and query-result nodes. `applyInterfaceProto` hooks here.
- **`importNode` native vs JS** — the JS polyfill at `kotori_runtime.zig:1500-1521` currently overrides any native work. §3.2 removes it; only native handles importNode after P1b.
- **`buildAttributesMap` actual bug** — it is precisely one line: L3887 `attr = @ptrCast(@alignCast(a.node.next));`. The function at L1509-1540 already has the correct pattern; we copy it.
- **Custom element name fallback** (`foo-bar`) — Non-goal. Current behavior: HTMLElement (registry-less upgrade deferred to custom-element spec).
- **SVG/MathML dispatch scope** — minimum viable: `SVGElement` + per-tag map for ~20 core SVG, `MathMLElement` single prototype for all MathML (no per-tag). Full SVG interface hierarchy deferred.
- **`NamedNodeMap` liveness path** — rebuild indices per access with Attr wrapper cache for identity. Full Proxy-based live map deferred if rebuild proves fast enough.
- **Binary size impact** — estimated 30 KB (~100 HTML + 20 SVG prototype objects + StaticStringMap table). Within RPi Zero 2W 5 MB budget.

---

## 9. References

- [WHATWG DOM §4.4 Node — ownerDocument](https://dom.spec.whatwg.org/#dom-node-ownerdocument)
- [WHATWG DOM §4.4.1 clone a node](https://dom.spec.whatwg.org/#concept-node-clone)
- [WHATWG DOM §4.5.3 createElement / createElementNS](https://dom.spec.whatwg.org/#dom-document-createelement)
- [WHATWG DOM §4.5 importNode](https://dom.spec.whatwg.org/#dom-document-importnode)
- [WHATWG DOM §4.9 attributes / NamedNodeMap](https://dom.spec.whatwg.org/#interface-namednodemap)
- [HTML Living Standard §3.2 Semantics, structure, APIs](https://html.spec.whatwg.org/multipage/dom.html)
- [HTML Living Standard §4 The elements of HTML](https://html.spec.whatwg.org/multipage/semantics.html)
- [HTML Living Standard — Element interfaces index](https://html.spec.whatwg.org/multipage/indices.html#element-interfaces)
- [SVG 2 §4 Basic data types and interfaces](https://svgwg.org/svg2-draft/types.html)
- [MathML Core §2 MathML fundamentals](https://w3c.github.io/mathml-core/#fundamentals)
- [WebIDL §3.7 Platform objects](https://webidl.spec.whatwg.org/#dfn-platform-object)
- Master roadmap: `docs/superpowers/specs/2026-04-17-kotori-suzume-wpt-100-roadmap.md` (Layer 1)
- Critic review feedback: session 2026-04-18 (NEEDS_REVISION → resolved in this revision)
