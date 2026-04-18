# kotori Layer 1D.1 — Native Attr Methods + Polyfill Retirement — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the Layer 1D Task 9 regression (commit `7c31ab6` reverted the polyfill delete after -26 subtests) by promoting the five Attr-node methods (`getAttributeNode`, `getAttributeNodeNS`, `setAttributeNode`, `setAttributeNodeNS`, `removeAttributeNode`) and the three namespace-aware methods (`hasAttributeNS`, `getAttributeNS`, `removeAttributeNS`) to native `Element.prototype` bindings with full WHATWG DOM §4.9.1 semantics (InUseAttributeError, NotFoundError, `""`→null ns coercion, HTML-doc lowercase). Upgrade `nativeToggleAttribute` QName validation to `dom_names.isValidAttrName`, extend `refreshAttributesMap` to sweep stale indexed + named keys, then **as the final commit** delete the 333-line JS polyfill at `src/js/kotori_runtime.zig:1491-1823`. WPT target: recover the -26 regression on `dom/nodes/attributes.html` to ≥35/67 (stretch ≥50/67) while NOT regressing `NamedNodeMap-supported-property-names.html`.

**Architecture:**
- All five `…Node` methods are thin wrappers around the Layer 1D NamedNodeMap internals. DOM §4.9.1 prose says `Element.setAttributeNode(attr)` ≡ `this.attributes.setNamedItem(attr)` — we delegate to the same lexbor + `g_attr_wrappers` code path already installed by Layer 1D (`nativeNnmSetNamedItem` at `kotori_dom.zig:4530`, `setAttrOwnerElement` at `kotori_dom.zig:4411`).
- Attr-lookup logic factored into two new reusable helpers: `getAttrByQName(vm, elem, qn)` (HTML lowercase branch + `lxb_dom_element_attr_by_name`) and `getAttrByNsLocal(vm, elem, ns, local)` (walk-and-match via `lxb_dom_element_first_attribute_noi` / `next_attribute_noi`). Both return `?*JsObject` via `getOrCreateAttrWrapper` so native methods and Layer 1D `NamedNodeMap.getNamedItem[NS]` share one truth path.
- `maybeLowercaseForHtml(elem, src, buf)` extracted once from `nativeToggleAttribute` and reused across all new natives and Layer 1D's existing `nativeNnmGetNamedItem`. Must tolerate detached elements (null owner document — skip lowercase).
- Attr backing-pointer tracking via `getAttrBackingPtr` / `setAttrBackingPtr` on the Attr JsObject (spec §R1): `setAttributeNode` transferring an Attr from elA → elB creates a new `lxb_dom_attr_t*` on elB; the old `g_attr_wrappers` key must be dropped and the new ptr re-keyed to the same JsObject so identity holds across mutations.
- `refreshAttributesMap` (kotori_dom.zig:4791) adds a high-water-mark sweep for stale indexed keys (`__nnmMaxIdx`) and a named-key ghost-list sweep (`__nnmNames`) so the shrink case `el.attributes[oldN-1]` correctly returns `undefined`.
- **Critical dependency — polyfill delete ordering:** All eleven scope items (Tasks 1-10) must land individually and be verified via `zig build test` + WPT spot-checks BEFORE the polyfill delete (Task 11). Deleting earlier produces the -26 regression that Layer 1D Task 9 already hit.

**Tech Stack:** Zig 0.15.2, lexbor (`lxb_dom_element_first_attribute_noi`, `lxb_dom_element_next_attribute_noi`, `lxb_dom_element_attr_by_name`, `lxb_dom_element_set_attribute`, `lxb_dom_element_remove_attribute`, `lxb_dom_attr_local_name`, `lxb_dom_attr_qualified_name`), kotori JS engine (`src/js/kotori/`), `src/js/dom_names.zig` (Layer 1A QName helpers — `isValidName`, `isValidAttrName`, `validateAndExtract`), WPT (Web Platform Tests).

**Spec:** `docs/superpowers/specs/2026-04-19-kotori-1D-1-attr-node-methods-design.md`
**Parent plan:** `docs/superpowers/plans/2026-04-19-kotori-1D-namednodemap-methods.md` (Layer 1D)
**Parent roadmap:** `docs/superpowers/specs/2026-04-17-kotori-suzume-wpt-100-roadmap.md` §Layer 1D.1
**Base commit:** `741d834` (docs: Layer 1D.1 spec). Layer 1D native NamedNodeMap already landed on `main`; the polyfill is re-installed via revert `7c31ab6`.

---

## File Structure

### Files to modify
- `src/js/kotori_dom.zig` — **all native code for this layer**. Touches:
  - `nativeToggleAttribute` @ ~L5698-L5720 — upgrade empty-check to `dom_names.isValidAttrName` (spec §QName validation wiring, work item #1).
  - `nativeSetAttribute` @ L3011 and `nativeSetAttributeNS` @ L3051 — confirmed already wired per spec table (no change; audit only).
  - `getOrCreateAttrWrapper` @ L4187-L4229 — add `getAttrBackingPtr` / `setAttrBackingPtr` slot helpers (stash the lexbor ptr on the Attr JsObject for cheap re-key on transfer).
  - `refreshAttributesMap` @ L4791-L4831 — add `__nnmMaxIdx` high-water sweep + `__nnmNames` ghost-list sweep.
  - New natives (appended near the other Element.prototype Attr methods): `nativeGetAttributeNode`, `nativeGetAttributeNodeNS`, `nativeSetAttributeNodeImpl` (registered under both `setAttributeNode` and `setAttributeNodeNS`), `nativeRemoveAttributeNode`, `nativeHasAttributeNS`, `nativeGetAttributeNS`, `nativeRemoveAttributeNS`.
  - New helpers: `getAttrByQName`, `getAttrByNsLocal`, `maybeLowercaseForHtml`, `attrNsMatches`, `attrLocalNameEquals`, `attrQualifiedNameSlice`, `isAttrObject`, `readAttrObjNs`, `readAttrObjLocalName`, `readAttrObjPrefix`, `readAttrObjValue`, `buildQNameFromAttrObj`, `getAttrBackingPtr`, `setAttrBackingPtr`. Grep each name first — if a Layer 1D helper already exists, reuse it.
  - Element.prototype registration block — add 8 new `try el_proto.setProperty(...)` lines for the new natives.
  - New StringId slots: `g_sid_attr_backing_ptr` ("__attrBackingPtr"), `g_sid_nnm_max_idx` ("__nnmMaxIdx"), `g_sid_nnm_names` ("__nnmNames"). Intern inside existing init path near L4739 (`initNamedNodeMapProto`).

- `src/js/kotori_runtime.zig` — **delete-only** work in Task 11. Remove lines 1491-1823 (the 333-line `attributes_polyfill_js` IIFE + its doc comment) AND the `_ = self.eval(attributes_polyfill_js);` call site at L92. No other edits.

- `tests/test_kotori_dom.zig` — extend with ~12 unit tests (one or two per new native) covering spec error paths (InUseAttributeError, NotFoundError, TypeError) and identity guarantees.

### Files to NOT modify
- `src/js/kotori/vm.zig` — zero VM changes. `pending_throw`, `createDOMExceptionObj`, `createNativeFn`, string pool, and object model are all sufficient as-is. Layer 1D already proved the VM's Attr-object plumbing handles everything this layer needs.
- `src/js/dom_names.zig` — already has `isValidName` @ L74, `isValidAttrName` @ L99, `validateAndExtract` @ L161. Reused read-only.
- `src/js/dom_api.zig`, `src/js/dom_element.zig`, `src/js/dom_document.zig` — QuickJS-era parallel bindings; not touched.
- `src/js/kotori/object.zig` — no object-model changes.
- Any scope outside `src/js/kotori_dom.zig` + `src/js/kotori_runtime.zig` + tests.

---

## Task 0: P0 Audit — No-Code Gate

**Files:** None modified; produces a notes file for subsequent tasks.

**Purpose:** Verify spec line references against current HEAD (`741d834`). Spec lists numbers keyed to `4da2d54` and the revert; drift on `kotori_dom.zig` is expected (grep shows `nativeSetAttribute` at L3011 not L3024, `nativeToggleAttribute` at L5698 not L5707). Measure baseline WPT counts and confirm Layer 1A's `dom_names.zig` helpers are importable from `kotori_dom.zig`.

- [ ] **Step 0.1: Confirm base commit and polyfill presence**

```bash
cd ~/suzume
git rev-parse HEAD   # expect 741d834 (or descendant if this plan is cherry-picked)
grep -n "attributes_polyfill_js" src/js/kotori_runtime.zig
```

Expected: two hits — the `_ = self.eval(attributes_polyfill_js);` call at L92 and the `const attributes_polyfill_js =` declaration at L1491. Record the exact line numbers.

```bash
sed -n '1491,1495p' src/js/kotori_runtime.zig
sed -n '1818,1825p' src/js/kotori_runtime.zig
```

Expected: opening `const attributes_polyfill_js = \\(function(){...` at L1491 and closing `\\})();` near L1822-L1823. If the block has drifted, update Task 11's delete range before running it.

- [ ] **Step 0.2: Locate all drifted native-method line references**

Grep and record actual line numbers (they replace the spec's stale numbers):

```bash
cd ~/suzume
grep -n "^fn nativeSetAttribute\|^fn nativeSetAttributeNS\|^fn nativeRemoveAttribute\|^fn nativeToggleAttribute\|^fn nativeGetAttribute\|^fn nativeHasAttribute\|^fn nativeCreateAttribute\|^fn nativeCreateAttributeNS\|^fn getOrCreateAttrWrapper\|^fn refreshAttributesMap\|^fn buildAttributesMap\|^fn setAttrOwnerElement\|^fn initNamedNodeMapProto\|^fn nativeNnmSetNamedItem\|^fn nativeNnmGetNamedItem\|^fn invalidateAttrWrapper\|^fn queueValidationErr" src/js/kotori_dom.zig
```

Expected neighborhood (as of `741d834`):
- `invalidateAttrWrapper` ~L433
- `nativeCreateAttribute` ~L2285
- `nativeCreateAttributeNS` ~L2314
- `nativeSetAttribute` ~L3011
- `nativeSetAttributeNS` ~L3051
- `nativeGetAttribute` ~L3090
- `nativeRemoveAttribute` ~L3105
- `getOrCreateAttrWrapper` ~L4187
- `setAttrOwnerElement` ~L4411 (Layer 1D landed this)
- `nativeNnmSetNamedItem` ~L4530 (Layer 1D)
- `initNamedNodeMapProto` ~L4739 (Layer 1D)
- `refreshAttributesMap` ~L4791 (Layer 1D)
- `buildAttributesMap` ~L4841 (Layer 1D)
- `nativeToggleAttribute` ~L5698

Write the authoritative map to `/tmp/1D-1-line-map.md`; every task below refers to it (treat spec's 4da2d54-era L-numbers as approximate anchors).

- [ ] **Step 0.3: Confirm `dom_names.zig` exports are importable**

```bash
grep -n "^pub fn isValidName\|^pub fn isValidAttrName\|^pub fn validateAndExtract" src/js/dom_names.zig
grep -n "dom_names" src/js/kotori_dom.zig | head -5
```

Expected: three `pub fn` exports in `dom_names.zig` (L74, L99, L161). `kotori_dom.zig` already `const dom_names = @import("dom_names.zig");` somewhere — verify. If the import is missing, Task 9 adds it.

- [ ] **Step 0.4: Confirm `queueValidationErr` bridge exists**

```bash
grep -n "fn queueValidationErr\|queueValidationErr(" src/js/kotori_dom.zig | head -5
```

Expected: a `fn queueValidationErr(vm, err_name)` helper (spec refs L2113-L2117 era). Record its current location. Task 3/4/9 call into it for `InvalidCharacterError` / `NamespaceError`.

- [ ] **Step 0.5: Baseline WPT measurement**

```bash
cd ~/suzume
zig build -Doptimize=ReleaseSafe 2>&1 | tail -20
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
  dom/nodes/attributes.html \
  dom/nodes/NamedNodeMap-supported-property-names.html \
  dom/nodes/Element-hasAttributeNS.html \
  dom/nodes/Element-removeAttributeNS.html \
  dom/nodes/Element-getAttributeNode.html \
  dom/nodes/Element-setAttributeNode.html \
  dom/nodes/Element-removeAttributeNode.html 2>&1 | tee /tmp/wpt-1D-1-baseline.txt
```

Record pass/fail counts. `attributes.html` should read approximately **35/67 passing** (post-revert). This is the floor that Task 11 must not regress below; stretch target is ≥50/67. NamedNodeMap-supported-property-names.html becomes a secondary gate for the stale-named-key sweep (Task 10).

- [ ] **Step 0.6: Confirm `importNode` Attr handling (spec §R4)**

```bash
grep -n "importNode\|nodeType.*2\|LXB_DOM_NODE_TYPE_ATTRIBUTE" src/js/kotori_dom.zig | head -20
```

Spec §R4 warns the polyfill's `Document.importNode` extension for Attr nodes may be load-bearing. Confirm native `importNode` accepts `nodeType===2` OR record that Task 11 must add an Attr branch before deletion.

- [ ] **Step 0.7: Record findings**

Write all six findings to `/tmp/p0-1D-1-audit.md`. No repo commit — P0 is a gate.

**Risk callout:** If Step 0.1 shows the polyfill is already deleted (e.g., a reapplied Task 9 that slipped through), **stop** and re-scope — Tasks 1-10 may already be partially covered or the baseline may be lower than -26. Escalate before writing code.

---

## Task 1: Implement `getAttributeNode` + `getAttributeNodeNS` (shared lookup helpers)

**Files:**
- Modify: `src/js/kotori_dom.zig` — add `getAttrByQName`, `getAttrByNsLocal`, `maybeLowercaseForHtml`, `attrNsMatches`, `attrLocalNameEquals`, `nativeGetAttributeNode`, `nativeGetAttributeNodeNS`; register on Element.prototype.

**Purpose:** Both methods walk the lexbor attribute list for a match; they are identical shape except for the key (qname vs ns+local). Factor the inner walk once so Layer 1D's `NamedNodeMap.getNamedItem[NS]` can share the same code path (spec §Implementation). No mutation; returns `Attr | null`.

- [ ] **Step 1.1: Add `maybeLowercaseForHtml` helper**

Extract from `nativeToggleAttribute` (~L5713-L5719). Place near the other utility helpers (e.g. just above `getOrCreateAttrWrapper` @ L4187):

```zig
/// DOM §4.9.1 "get an attribute by name" step 1: lowercase qname iff the
/// element is in the HTML namespace AND its node document is an HTML
/// document. `buf` must be at least src.len bytes; returns a slice into
/// either `buf` (lowercased) or the original `src` (pass-through).
fn maybeLowercaseForHtml(elem: *lxb.lxb_dom_element_t, src: []const u8, buf: []u8) []const u8 {
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    if (node.ns != lxb.LXB_NS_HTML) return src;
    // Detached element tolerance: node.owner_document may be null.
    const doc_opaque = node.owner_document orelse return src;
    // is_html flag set by the HTML parser path on the document node.
    const doc: *lxb.lxb_dom_document_t = @ptrCast(@alignCast(doc_opaque));
    if (!doc.is_html) return src;
    if (src.len > buf.len) return src; // safety — caller sizes buf
    for (src, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..src.len];
}
```

Verify lexbor field names (`node.ns`, `node.owner_document`, `doc.is_html`) with `grep -n "is_html\|owner_document" include/lexbor/dom/` and adjust if the bindings differ.

- [ ] **Step 1.2: Add `attrNsMatches` and `attrLocalNameEquals`**

```zig
/// Compare an lxb attr's namespace against the caller-supplied ns slice.
/// `ns == null` matches only attrs whose ns id is LXB_NS__UNDEF / 0.
fn attrNsMatches(attr: *lxb.lxb_dom_attr_t, ns: ?[]const u8) bool {
    const node: *lxb.lxb_dom_node_t = @ptrCast(attr);
    if (ns == null) return node.ns == lxb.LXB_NS__UNDEF or node.ns == 0;
    // Resolve ns id → uri via nsIdToUri helper (kotori_dom.zig ~L501).
    const uri = nsIdToUri(node.ns) orelse return false;
    return std.mem.eql(u8, uri, ns.?);
}

fn attrLocalNameEquals(attr: *lxb.lxb_dom_attr_t, local: []const u8) bool {
    var len: usize = 0;
    const ptr = dom_b.lxb_dom_attr_local_name(attr, &len);
    if (ptr == null) return false;
    return std.mem.eql(u8, ptr.?[0..len], local);
}
```

- [ ] **Step 1.3: Add `getAttrByQName` and `getAttrByNsLocal`**

```zig
/// DOM §4.9.1 "get an attribute by name".
fn getAttrByQName(vm: *VM, elem: *lxb.lxb_dom_element_t, qn_in: []const u8) ?*JsObject {
    var buf: [256]u8 = undefined;
    const qn = maybeLowercaseForHtml(elem, qn_in, &buf);
    const a_opaque = dom_b.lxb_dom_element_attr_by_name(elem, qn.ptr, qn.len) orelse return null;
    const a: *lxb.lxb_dom_attr_t = @ptrCast(@alignCast(a_opaque));
    return getOrCreateAttrWrapper(vm, a);
}

/// DOM §4.9.1 "get an attribute by namespace and local name".
fn getAttrByNsLocal(vm: *VM, elem: *lxb.lxb_dom_element_t,
                   ns_in: ?[]const u8, local: []const u8) ?*JsObject {
    const ns: ?[]const u8 = if (ns_in) |n| (if (n.len == 0) null else n) else null;
    var a_opaque = dom_b.lxb_dom_element_first_attribute_noi(elem);
    while (a_opaque) |p| {
        const attr: *lxb.lxb_dom_attr_t = @ptrCast(@alignCast(p));
        if (attrNsMatches(attr, ns) and attrLocalNameEquals(attr, local)) {
            return getOrCreateAttrWrapper(vm, attr);
        }
        a_opaque = dom_b.lxb_dom_element_next_attribute_noi(attr);
    }
    return null;
}
```

If a Layer 1D `lookupAttrByNsLocal` helper already exists (grep confirmed as part of the NamedNodeMap work), **reuse it** — `getAttrByNsLocal` simply wraps it with `getOrCreateAttrWrapper`.

- [ ] **Step 1.4: Add `nativeGetAttributeNode` + `nativeGetAttributeNodeNS`**

Per spec §Method: getAttributeNode §Implementation:

```zig
fn nativeGetAttributeNode(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    if (args.len == 0) return JsValue.null_val;
    const vm = VM.vmFromCtx(ctx);
    const node = getThisNode(this) orelse return JsValue.null_val;
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.null_val;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    const qn_sid = args[0].toStringId(vm) catch return JsValue.null_val;
    const qn = vm.pool.get(qn_sid) orelse return JsValue.null_val;
    return if (getAttrByQName(vm, elem, qn)) |o| JsValue.initObject(o) else JsValue.null_val;
}

fn nativeGetAttributeNodeNS(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    if (args.len < 2) return JsValue.null_val;
    const vm = VM.vmFromCtx(ctx);
    const node = getThisNode(this) orelse return JsValue.null_val;
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.null_val;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    const ns_arg = args[0];
    const ns: ?[]const u8 = if (ns_arg.isNull() or ns_arg.isUndefined()) null else blk: {
        const s_sid = ns_arg.toStringId(vm) catch break :blk @as(?[]const u8, null);
        const s = vm.pool.get(s_sid) orelse break :blk @as(?[]const u8, null);
        break :blk s;
    };
    const local_sid = args[1].toStringId(vm) catch return JsValue.null_val;
    const local = vm.pool.get(local_sid) orelse return JsValue.null_val;
    return if (getAttrByNsLocal(vm, elem, ns, local)) |o| JsValue.initObject(o) else JsValue.null_val;
}
```

- [ ] **Step 1.5: Register on Element.prototype**

Grep the Element.prototype registration block for existing entries (`"getAttribute"` registration site). Add:

```zig
try el_proto.setProperty(vm.allocator, try vm.pool.intern("getAttributeNode"),
    JsValue.initObject(try vm.createNativeFn(&nativeGetAttributeNode)));
try el_proto.setProperty(vm.allocator, try vm.pool.intern("getAttributeNodeNS"),
    JsValue.initObject(try vm.createNativeFn(&nativeGetAttributeNodeNS)));
```

- [ ] **Step 1.6: Unit tests**

Append to `tests/test_kotori_dom.zig`:

```zig
test "getAttributeNode returns same object as attributes[0]" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\el.setAttribute('id', 'x');
        \\el.attributes[0] === el.getAttributeNode('id');
    );
    try std.testing.expect(ok.asBool());
}

test "getAttributeNode returns null on miss" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\document.createElement('div').getAttributeNode('missing') === null;
    );
    try std.testing.expect(ok.asBool());
}

test "getAttributeNodeNS coerces empty string ns to null" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\el.setAttribute('id', 'x');
        \\el.getAttributeNodeNS('', 'id') !== null;
    );
    try std.testing.expect(ok.asBool());
}
```

- [ ] **Step 1.7: Build + test + commit**

```bash
cd ~/suzume && zig build test 2>&1 | tail -30
git add src/js/kotori_dom.zig tests/test_kotori_dom.zig
git commit -m "$(cat <<'EOF'
feat(kotori): Element.getAttributeNode[NS] native (1D.1 Task 1)

Add native bindings for DOM §4.9.1 getAttributeNode/getAttributeNodeNS
plus three new shared helpers (getAttrByQName, getAttrByNsLocal,
maybeLowercaseForHtml) that factor the lexbor attr walk used by both
Element.prototype and NamedNodeMap.prototype.

Spec: docs/superpowers/specs/2026-04-19-kotori-1D-1-attr-node-methods-design.md
  §Method: getAttributeNode / getAttributeNodeNS

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Risk callout:** `maybeLowercaseForHtml` must tolerate null owner-document (newly created, not-yet-inserted elements). If `node.owner_document` is not optional in the lexbor bindings, guard with an equality check against the VM's default document.

---

## Task 2: Implement `hasAttributeNS` + `getAttributeNS`

**Files:**
- Modify: `src/js/kotori_dom.zig` — 2 new natives; register on Element.prototype.

**Purpose:** Close the namespace-aware read surface. Both methods reuse `getAttrByNsLocal` from Task 1. Per spec §Method: hasAttributeNS / getAttributeNS / removeAttributeNS, neither throws; both handle `""`→null ns coercion.

- [ ] **Step 2.1: Add `nativeHasAttributeNS`**

```zig
fn nativeHasAttributeNS(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    if (args.len < 2) return JsValue.initBool(false);
    const vm = VM.vmFromCtx(ctx);
    const node = getThisNode(this) orelse return JsValue.initBool(false);
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.initBool(false);
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    const ns = extractOptionalStringArg(vm, args[0]);
    const local = extractStringArg(vm, args[1]) orelse return JsValue.initBool(false);
    return JsValue.initBool(getAttrByNsLocal(vm, elem, ns, local) != null);
}
```

`extractOptionalStringArg(vm, v)` — if `v` is null/undefined returns `null`; else ToString into an interned string and return its slice. Write once if it doesn't already exist (grep first).

- [ ] **Step 2.2: Add `nativeGetAttributeNS`**

```zig
fn nativeGetAttributeNS(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    if (args.len < 2) return JsValue.null_val;
    const vm = VM.vmFromCtx(ctx);
    const node = getThisNode(this) orelse return JsValue.null_val;
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.null_val;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    const ns = extractOptionalStringArg(vm, args[0]);
    const local = extractStringArg(vm, args[1]) orelse return JsValue.null_val;
    const attr_obj = getAttrByNsLocal(vm, elem, ns, local) orelse return JsValue.null_val;
    const v_sid = try vm.pool.intern("value");
    return attr_obj.getProperty(v_sid) orelse JsValue.null_val;
}
```

- [ ] **Step 2.3: Register on Element.prototype + unit tests**

```zig
try el_proto.setProperty(vm.allocator, try vm.pool.intern("hasAttributeNS"),
    JsValue.initObject(try vm.createNativeFn(&nativeHasAttributeNS)));
try el_proto.setProperty(vm.allocator, try vm.pool.intern("getAttributeNS"),
    JsValue.initObject(try vm.createNativeFn(&nativeGetAttributeNS)));
```

Tests:

```zig
test "hasAttributeNS returns true for matching ns+local" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
        \\el.setAttributeNS('http://www.w3.org/1999/xlink', 'xlink:href', '#x');
        \\el.hasAttributeNS('http://www.w3.org/1999/xlink', 'href');
    );
    try std.testing.expect(ok.asBool());
}

test "getAttributeNS returns value string, null when absent" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\el.setAttributeNS(null, 'id', 'x');
        \\el.getAttributeNS(null, 'id') === 'x' &&
        \\el.getAttributeNS(null, 'missing') === null;
    );
    try std.testing.expect(ok.asBool());
}
```

- [ ] **Step 2.4: Build + test + commit**

```bash
cd ~/suzume && zig build test 2>&1 | tail -30
git add src/js/kotori_dom.zig tests/test_kotori_dom.zig
git commit -m "$(cat <<'EOF'
feat(kotori): Element.hasAttributeNS + getAttributeNS native (1D.1 Task 2)

Add DOM §4.9.1 namespace-aware getters. Both reuse getAttrByNsLocal
from Task 1 and honour the '' -> null namespace coercion. Neither
method throws.

Spec: docs/superpowers/specs/2026-04-19-kotori-1D-1-attr-node-methods-design.md
  §Method: hasAttributeNS / getAttributeNS / removeAttributeNS

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Risk callout:** spec §Edge cases requires `""` ns → null BEFORE lookup. `extractOptionalStringArg` must NOT return an empty-string slice — either coerce inside the helper or guard in the caller.

---

## Task 3: Implement `removeAttributeNS`

**Files:**
- Modify: `src/js/kotori_dom.zig` — 1 new native; registration.

**Purpose:** Silent remove (no throw) by ns+local. Lexbor lacks a remove-by-ns-local primitive, so walk the list to find the match, then call `lxb_dom_element_remove_attribute` with the qualified name extracted from the matching attr.

- [ ] **Step 3.1: Add `nativeRemoveAttributeNS`**

```zig
fn nativeRemoveAttributeNS(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    if (args.len < 2) return JsValue.undefined_val;
    const vm = VM.vmFromCtx(ctx);
    const node = getThisNode(this) orelse return JsValue.undefined_val;
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.undefined_val;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    const ns = extractOptionalStringArg(vm, args[0]);
    const local = extractStringArg(vm, args[1]) orelse return JsValue.undefined_val;

    var a_opaque = dom_b.lxb_dom_element_first_attribute_noi(elem);
    while (a_opaque) |p| {
        const attr: *lxb.lxb_dom_attr_t = @ptrCast(@alignCast(p));
        if (attrNsMatches(attr, ns) and attrLocalNameEquals(attr, local)) {
            // Clear ownerElement on any cached wrapper BEFORE lexbor frees.
            if (g_attr_wrappers.get(@intFromPtr(attr))) |w| {
                setAttrOwnerElement(vm, w, JsValue.null_val);
            }
            invalidateAttrWrapper(attr);
            var qn_len: usize = 0;
            const qn_ptr = dom_b.lxb_dom_attr_qualified_name(attr, &qn_len);
            if (qn_ptr) |qn| {
                _ = dom_b.lxb_dom_element_remove_attribute(elem, qn, qn_len);
            }
            bumpElemAttrVersion(elem);
            setDomDirty();
            return JsValue.undefined_val;
        }
        a_opaque = dom_b.lxb_dom_element_next_attribute_noi(attr);
    }
    return JsValue.undefined_val; // silent no-op on miss
}
```

- [ ] **Step 3.2: Register + tests**

```zig
try el_proto.setProperty(vm.allocator, try vm.pool.intern("removeAttributeNS"),
    JsValue.initObject(try vm.createNativeFn(&nativeRemoveAttributeNS)));
```

```zig
test "removeAttributeNS silent no-op when absent" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\el.removeAttributeNS(null, 'missing');
        \\el.attributes.length === 0;
    );
    try std.testing.expect(ok.asBool());
}

test "removeAttributeNS removes matching attr and clears ownerElement" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\el.setAttributeNS(null, 'id', 'x');
        \\var a = el.getAttributeNodeNS(null, 'id');
        \\el.removeAttributeNS(null, 'id');
        \\a.ownerElement === null && el.attributes.length === 0;
    );
    try std.testing.expect(ok.asBool());
}
```

- [ ] **Step 3.3: Build + test + commit**

```bash
cd ~/suzume && zig build test 2>&1 | tail -30
git add src/js/kotori_dom.zig tests/test_kotori_dom.zig
git commit -m "$(cat <<'EOF'
feat(kotori): Element.removeAttributeNS native (1D.1 Task 3)

Silent remove by (ns, localName). Walks lexbor once, clears
ownerElement on the cached wrapper before invalidation, resolves the
qualifiedName for lexbor's qname-based remove primitive, bumps the
per-element version counter.

Spec: docs/superpowers/specs/2026-04-19-kotori-1D-1-attr-node-methods-design.md
  §Method: removeAttributeNS

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Risk callout:** Ordering — clear `ownerElement` and call `invalidateAttrWrapper` BEFORE `lxb_dom_element_remove_attribute`. After lexbor removes the attr its pointer may be freed/reassigned, and a stale `g_attr_wrappers` entry would alias a future Attr.

---

## Task 4: Backing-ptr slot helpers on Attr JsObject

**Files:**
- Modify: `src/js/kotori_dom.zig` — add `g_sid_attr_backing_ptr` StringId, `getAttrBackingPtr`/`setAttrBackingPtr` helpers; wire into `getOrCreateAttrWrapper` @ L4187.

**Purpose:** Spec §R1 — when `setAttributeNode` transfers an Attr from `elA` to `elB`, lexbor creates a new `lxb_dom_attr_t*` on `elB`'s list. The old `g_attr_wrappers` key must be removed and the new ptr re-keyed to the SAME JsObject so identity holds. To do this cheaply, stash the current backing ptr on the Attr JsObject itself.

- [ ] **Step 4.1: Intern StringId and declare helpers**

Add near the other NamedNodeMap StringIds (intern inside `initNamedNodeMapProto` @ L4739):

```zig
// At module scope near g_sid_nnm_elem etc.
var g_sid_attr_backing_ptr: ?StringId = null; // "__attrBackingPtr"

// Inside initNamedNodeMapProto:
g_sid_attr_backing_ptr = try vm.pool.intern("__attrBackingPtr");
```

Helpers:

```zig
fn getAttrBackingPtr(attr_obj: *JsObject) ?usize {
    const sid = g_sid_attr_backing_ptr orelse return null;
    const v = attr_obj.getProperty(sid) orelse return null;
    if (v.isNull() or v.isUndefined()) return null;
    const f = v.toNumber();
    if (f == 0.0) return null;
    return @intFromFloat(f);
}

fn setAttrBackingPtr(attr_obj: *JsObject, ptr: usize) void {
    const sid = g_sid_attr_backing_ptr orelse return;
    const v = if (ptr == 0) JsValue.null_val
             else JsValue.initNumber(@floatFromInt(ptr));
    attr_obj.setProperty(g_alloc, sid, v) catch {};
}
```

- [ ] **Step 4.2: Wire into `getOrCreateAttrWrapper` @ L4187**

After the wrapper is built and just before the `g_attr_wrappers.put(...)` call, add:

```zig
setAttrBackingPtr(attr_obj, @intFromPtr(a));
```

- [ ] **Step 4.3: Unit test (identity roundtrip)**

```zig
test "Attr wrapper preserves identity across multiple getAttributeNode calls" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\el.setAttribute('id', 'x');
        \\var a1 = el.getAttributeNode('id');
        \\var a2 = el.getAttributeNode('id');
        \\a1 === a2 && a1 === el.attributes[0];
    );
    try std.testing.expect(ok.asBool());
}
```

- [ ] **Step 4.4: Build + test + commit**

```bash
cd ~/suzume && zig build test 2>&1 | tail -30
git add src/js/kotori_dom.zig tests/test_kotori_dom.zig
git commit -m "$(cat <<'EOF'
feat(kotori): Attr.__attrBackingPtr slot for transfer re-key (1D.1 Task 4)

Stash the lexbor lxb_dom_attr_t* on the Attr JsObject via a hidden
__attrBackingPtr property. setAttributeNode (Task 5) uses this to drop
the stale g_attr_wrappers entry and re-key the new ptr -> same
JsObject so identity holds across cross-element Attr transfers.

Spec: docs/superpowers/specs/2026-04-19-kotori-1D-1-attr-node-methods-design.md
  §R1 (setAttributeNode cache identity under rebinding)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Risk callout:** `g_alloc` must be the same allocator used for all `setProperty` calls on Attr JsObjects. If the existing convention uses `vm.allocator` instead, switch accordingly; mixing allocators here is a silent free-list corruption bug.

---

## Task 5: Implement `setAttributeNode` + `setAttributeNodeNS` (shared native)

**Files:**
- Modify: `src/js/kotori_dom.zig` — `nativeSetAttributeNodeImpl` + reader helpers (`readAttrObjNs`, `readAttrObjLocalName`, `readAttrObjPrefix`, `readAttrObjValue`, `buildQNameFromAttrObj`, `isAttrObject`); register under both names.

**Purpose:** Highest-complexity task in this layer. Spec §Method: setAttributeNode has 7 coupled steps: InUseAttributeError, (ns, local) lookup, idempotence, lexbor write, re-key (Task 4), ownerElement transfer, return old-or-null. Both `setAttributeNode` and `setAttributeNodeNS` register the SAME native (spec: "likewise"). Delegates where possible to Layer 1D's `nativeNnmSetNamedItem` path already at L4530.

- [ ] **Step 5.1: Add `isAttrObject` guard**

```zig
fn isAttrObject(obj: *JsObject) bool {
    // Duck-type: nodeType === 2. createAttribute/createAttributeNS sets it;
    // Layer 1D wrappers also carry it.
    const nt_sid = vm_pool_intern_or_null("nodeType") orelse return false;
    const v = obj.getProperty(nt_sid) orelse return false;
    if (!v.isNumber()) return false;
    return @as(u32, @intFromFloat(v.toNumber())) == 2;
}
```

(Pseudocode — use the repo's actual intern helper. If a Layer 1D helper like `isAttrWrapperObj` already exists, reuse it.)

- [ ] **Step 5.2: Add attr-object field readers**

```zig
fn readAttrObjNs(vm: *VM, obj: *JsObject) ?[]const u8 {
    const sid = vm.pool.intern("namespaceURI") catch return null;
    const v = obj.getProperty(sid) orelse return null;
    if (v.isNull() or v.isUndefined()) return null;
    const s = vm.pool.get(v.asStringId()) orelse return null;
    if (s.len == 0) return null; // "" coerces to null per spec step 1
    return s;
}

fn readAttrObjLocalName(vm: *VM, obj: *JsObject) ?[]const u8 {
    const sid = vm.pool.intern("localName") catch return null;
    const v = obj.getProperty(sid) orelse return null;
    return vm.pool.get(v.asStringId());
}

fn readAttrObjPrefix(vm: *VM, obj: *JsObject) ?[]const u8 {
    const sid = vm.pool.intern("prefix") catch return null;
    const v = obj.getProperty(sid) orelse return null;
    if (v.isNull() or v.isUndefined()) return null;
    return vm.pool.get(v.asStringId());
}

fn readAttrObjValue(vm: *VM, obj: *JsObject) []const u8 {
    const sid = vm.pool.intern("value") catch return "";
    const v = obj.getProperty(sid) orelse return "";
    return vm.pool.get(v.asStringId()) orelse "";
}

fn buildQNameFromAttrObj(vm: *VM, obj: *JsObject, buf: []u8) ?[]const u8 {
    const local = readAttrObjLocalName(vm, obj) orelse return null;
    if (readAttrObjPrefix(vm, obj)) |p| {
        const n = p.len + 1 + local.len;
        if (n > buf.len) return null;
        @memcpy(buf[0..p.len], p);
        buf[p.len] = ':';
        @memcpy(buf[p.len + 1 ..][0..local.len], local);
        return buf[0..n];
    }
    return local;
}
```

- [ ] **Step 5.3: Add `nativeSetAttributeNodeImpl`**

Per spec §Method: setAttributeNode §Implementation (full body); key differences from Layer 1D `nativeNnmSetNamedItem`: `this` is an Element (not a map); InUseAttributeError uses the full-object `attr.ownerElement` read (falling back to `__ownerElemPtr` from Layer 1D when present):

```zig
fn nativeSetAttributeNodeImpl(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isObject()) {
        vm.pending_throw = try createDOMExceptionObj(vm, "TypeError");
        return JsValue.undefined_val;
    }
    const node = getThisNode(this) orelse return JsValue.undefined_val;
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.undefined_val;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);

    const attr_obj = args[0].asObject().?;
    if (!isAttrObject(attr_obj)) {
        vm.pending_throw = try createDOMExceptionObj(vm, "TypeError");
        return JsValue.undefined_val;
    }

    // Defensive QName validation — callers may have bare-object'd an Attr.
    // createAttributeNS already ran validateAndExtract; this guards createAttribute path.
    if (readAttrObjLocalName(vm, attr_obj)) |ln_slice| {
        // Build the qualified name early for validation.
        var qn_buf_v: [256]u8 = undefined;
        if (buildQNameFromAttrObj(vm, attr_obj, &qn_buf_v)) |qn_v| {
            if (!dom_names.isValidAttrName(qn_v)) {
                try queueValidationErr(vm, "InvalidCharacterError");
                return JsValue.undefined_val;
            }
        }
        _ = ln_slice;
    }

    // Step 1: InUseAttributeError if attr.ownerElement is some OTHER element.
    // Prefer the Layer 1D __ownerElemPtr slot if present; else fall back to
    // reading the ownerElement own property.
    const owner_ptr_opt: ?usize = blk: {
        if (g_sid_owner_elem_ptr) |sid| {
            if (attr_obj.getProperty(sid)) |v| {
                if (!v.isNull() and !v.isUndefined()) {
                    const f = v.toNumber();
                    if (f != 0.0) break :blk @as(?usize, @intFromFloat(f));
                }
            }
        }
        break :blk null;
    };
    if (owner_ptr_opt) |ptr| {
        const this_node_ptr = @intFromPtr(@as(*lxb.lxb_dom_node_t, @ptrCast(elem)));
        if (ptr != this_node_ptr and ptr != 0) {
            vm.pending_throw = try createDOMExceptionObj(vm, "InUseAttributeError");
            return JsValue.undefined_val;
        }
    }

    // Read Attr metadata for lookup + write.
    const ns = readAttrObjNs(vm, attr_obj);
    const local = readAttrObjLocalName(vm, attr_obj) orelse return JsValue.null_val;
    const value = readAttrObjValue(vm, attr_obj);
    var qn_buf: [512]u8 = undefined;
    const qn = buildQNameFromAttrObj(vm, attr_obj, &qn_buf) orelse return JsValue.null_val;

    // Step 2: find existing attr at (ns, localName).
    const old_obj = getAttrByNsLocal(vm, elem, ns, local);
    // Step 3: idempotence — same Attr already on this element at this (ns, local).
    if (old_obj) |oa| if (oa == attr_obj) return JsValue.initObject(oa);

    // Step 4/5: write via lexbor. Mirrors nativeSetAttribute / nativeSetAttributeNS.
    _ = dom_b.lxb_dom_element_set_attribute(elem, qn.ptr, qn.len, value.ptr, value.len);
    bumpElemAttrVersion(elem);
    setDomDirty();

    // Task 4 re-key: drop stale backing key, put new ptr -> attr_obj.
    const new_lxb_opaque = dom_b.lxb_dom_element_attr_by_name(elem, qn.ptr, qn.len)
        orelse return JsValue.null_val;
    const new_lxb: *lxb.lxb_dom_attr_t = @ptrCast(@alignCast(new_lxb_opaque));
    if (getAttrBackingPtr(attr_obj)) |old_key| {
        if (old_key != @intFromPtr(new_lxb)) {
            _ = g_attr_wrappers.remove(old_key);
        }
    }
    g_attr_wrappers.put(vm.allocator, @intFromPtr(new_lxb), attr_obj) catch {};
    setAttrBackingPtr(attr_obj, @intFromPtr(new_lxb));

    // Step 6: set attr's element.
    const owner_js = wrapNode(vm, @ptrCast(elem)) orelse return JsValue.null_val;
    setAttrOwnerElement(vm, attr_obj, JsValue.initObject(owner_js));

    // Step 4 side-effect: clear displaced old attr's ownerElement.
    if (old_obj) |oa| if (oa != attr_obj) setAttrOwnerElement(vm, oa, JsValue.null_val);

    // Step 7: return old or null.
    return if (old_obj) |oa| JsValue.initObject(oa) else JsValue.null_val;
}
```

- [ ] **Step 5.4: Register under BOTH names (spec: "likewise")**

```zig
const set_node_fn = try vm.createNativeFn(&nativeSetAttributeNodeImpl);
try el_proto.setProperty(vm.allocator, try vm.pool.intern("setAttributeNode"),
    JsValue.initObject(set_node_fn));
try el_proto.setProperty(vm.allocator, try vm.pool.intern("setAttributeNodeNS"),
    JsValue.initObject(set_node_fn));
```

- [ ] **Step 5.5: Unit tests — all four spec behaviours**

```zig
test "setAttributeNode returns null when appending new attr" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\var a = document.createAttribute('id'); a.value = 'x';
        \\var prev = el.setAttributeNode(a);
        \\prev === null && el.getAttribute('id') === 'x' && a.ownerElement === el;
    );
    try std.testing.expect(ok.asBool());
}

test "setAttributeNode returns old Attr when replacing" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\el.setAttribute('id', 'old');
        \\var oldNode = el.getAttributeNode('id');
        \\var a = document.createAttribute('id'); a.value = 'new';
        \\var ret = el.setAttributeNode(a);
        \\ret === oldNode && oldNode.ownerElement === null &&
        \\el.getAttribute('id') === 'new';
    );
    try std.testing.expect(ok.asBool());
}

test "setAttributeNode throws InUseAttributeError" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var a = document.createElement('div');
        \\var b = document.createElement('div');
        \\a.setAttribute('id', 'x');
        \\var aAttr = a.getAttributeNode('id');
        \\try { b.setAttributeNode(aAttr); false; }
        \\catch (e) { e.name === 'InUseAttributeError'; }
    );
    try std.testing.expect(ok.asBool());
}

test "setAttributeNode throws TypeError for non-Attr" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\try { el.setAttributeNode({}); false; }
        \\catch (e) { e.name === 'TypeError'; }
    );
    try std.testing.expect(ok.asBool());
}
```

- [ ] **Step 5.6: Build + test + commit**

```bash
cd ~/suzume && zig build test 2>&1 | tail -30
git add src/js/kotori_dom.zig tests/test_kotori_dom.zig
git commit -m "$(cat <<'EOF'
feat(kotori): Element.setAttributeNode[NS] native (1D.1 Task 5)

Implement DOM §4.9.1 7-step setAttributeNode algorithm with
InUseAttributeError, idempotence, lexbor write, backing-ptr re-key
(Task 4), ownerElement transfer, and old-attr return. Both
setAttributeNode and setAttributeNodeNS share one native per WebIDL.

Spec: docs/superpowers/specs/2026-04-19-kotori-1D-1-attr-node-methods-design.md
  §Method: setAttributeNode / setAttributeNodeNS

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Risk callouts:**
- **Pending throw ordering**: Set `vm.pending_throw` BEFORE returning `undefined_val`. Any reversed ordering silently swallows the exception.
- **Re-key correctness (spec §R1)**: `g_attr_wrappers.remove(old_key)` must use the OLD ptr from `getAttrBackingPtr(attr_obj)` — NOT the old_obj's ptr. If `attr_obj` was previously detached (no old key) the remove is a no-op; if it was attached to a prior element, the old key is freed.
- **Spec-bound QName validation**: The defensive `isValidAttrName` guard at Step 5.3 matches spec §QName validation wiring work-item #2. Omitting it bypasses ~3 WPT subtests that construct bare-object Attrs.

---

## Task 6: Implement `removeAttributeNode`

**Files:**
- Modify: `src/js/kotori_dom.zig` — 1 new native; registration.

**Purpose:** Spec §Method: removeAttributeNode — throw `NotFoundError` when attr is not in this element's attribute list; else remove and return. Uses the backing-ptr from Task 4 for the containment check (O(N) walk comparing lexbor pointers).

- [ ] **Step 6.1: Add `nativeRemoveAttributeNode`**

```zig
fn nativeRemoveAttributeNode(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isObject()) {
        vm.pending_throw = try createDOMExceptionObj(vm, "TypeError");
        return JsValue.undefined_val;
    }
    const node = getThisNode(this) orelse return JsValue.undefined_val;
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.undefined_val;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);

    const attr_obj = args[0].asObject().?;
    if (!isAttrObject(attr_obj)) {
        vm.pending_throw = try createDOMExceptionObj(vm, "TypeError");
        return JsValue.undefined_val;
    }

    // Step 1: containment check via backing ptr.
    const backing = getAttrBackingPtr(attr_obj) orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    };
    var a_opaque = dom_b.lxb_dom_element_first_attribute_noi(elem);
    var found: ?*lxb.lxb_dom_attr_t = null;
    while (a_opaque) |p| {
        const attr: *lxb.lxb_dom_attr_t = @ptrCast(@alignCast(p));
        if (@intFromPtr(attr) == backing) { found = attr; break; }
        a_opaque = dom_b.lxb_dom_element_next_attribute_noi(attr);
    }
    const target = found orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    };

    // Step 2: remove by qualified name (lexbor has no remove-by-ptr).
    var qn_len: usize = 0;
    const qn_ptr = dom_b.lxb_dom_attr_qualified_name(target, &qn_len);
    if (qn_ptr == null) {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    }

    // Clear wrapper state BEFORE lexbor frees.
    setAttrOwnerElement(vm, attr_obj, JsValue.null_val);
    _ = g_attr_wrappers.remove(backing);
    setAttrBackingPtr(attr_obj, 0);
    _ = dom_b.lxb_dom_element_remove_attribute(elem, qn_ptr, qn_len);
    bumpElemAttrVersion(elem);
    setDomDirty();

    // Step 3: return passed-in Attr.
    return JsValue.initObject(attr_obj);
}
```

- [ ] **Step 6.2: Register + tests**

```zig
try el_proto.setProperty(vm.allocator, try vm.pool.intern("removeAttributeNode"),
    JsValue.initObject(try vm.createNativeFn(&nativeRemoveAttributeNode)));
```

```zig
test "removeAttributeNode returns the Attr and clears ownerElement" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\el.setAttribute('id', 'x');
        \\var a = el.getAttributeNode('id');
        \\var r = el.removeAttributeNode(a);
        \\r === a && a.ownerElement === null && el.attributes.length === 0;
    );
    try std.testing.expect(ok.asBool());
}

test "removeAttributeNode throws NotFoundError when Attr is not in list" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\var orphan = document.createAttribute('id');
        \\try { el.removeAttributeNode(orphan); false; }
        \\catch (e) { e.name === 'NotFoundError'; }
    );
    try std.testing.expect(ok.asBool());
}

test "removeAttributeNode throws TypeError for non-Attr" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\try { el.removeAttributeNode({}); false; }
        \\catch (e) { e.name === 'TypeError'; }
    );
    try std.testing.expect(ok.asBool());
}
```

- [ ] **Step 6.3: Build + test + commit**

```bash
cd ~/suzume && zig build test 2>&1 | tail -30
git add src/js/kotori_dom.zig tests/test_kotori_dom.zig
git commit -m "$(cat <<'EOF'
feat(kotori): Element.removeAttributeNode native (1D.1 Task 6)

Implement DOM §4.9.1 3-step removeAttributeNode. Containment check
walks lexbor's attribute list comparing against the Attr's backing ptr
from Task 4; on match, clears ownerElement, invalidates the
g_attr_wrappers key, calls lexbor remove_attribute by qualified name,
and returns the passed-in Attr. NotFoundError for non-containment,
TypeError for non-object / non-Attr.

Spec: docs/superpowers/specs/2026-04-19-kotori-1D-1-attr-node-methods-design.md
  §Method: removeAttributeNode

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Risk callout (spec §R3):** Do NOT unify `nativeRemoveAttributeNode` with `nativeRemoveAttribute` or `nativeNnmRemoveNamedItem` — the three have different throw semantics: Element.removeAttribute silently succeeds on miss, NamedNodeMap.removeNamedItem throws NotFoundError on miss, Element.removeAttributeNode throws NotFoundError. Keep the three paths separated in code.

---

## Task 7: Upgrade `nativeToggleAttribute` QName validation

**Files:**
- Modify: `src/js/kotori_dom.zig` — `nativeToggleAttribute` @ ~L5698 (swap empty-check for `dom_names.isValidAttrName`).

**Purpose:** Spec §QName validation wiring work-item #1. Current code only checks `name_raw.len == 0`; the polyfill (and Layer 1A for setAttribute/setAttributeNS) enforces full QName validation via `dom_names.isValidAttrName`. Mirror that here for parity so `toggleAttribute('foo bar')` → `InvalidCharacterError`.

- [ ] **Step 7.1: Locate and patch**

From Task 0's line map, `nativeToggleAttribute` is at ~L5698. Find the existing guard (spec ref `name_raw.len == 0`):

```zig
// OLD
if (name_raw.len == 0) {
    vm.pending_throw = try createDOMExceptionObj(vm, "InvalidCharacterError");
    return JsValue.undefined_val;
}
```

Replace with:

```zig
// NEW
if (!dom_names.isValidAttrName(name_raw)) {
    try queueValidationErr(vm, "InvalidCharacterError");
    return JsValue.undefined_val;
}
```

`queueValidationErr` is the Layer 1A bridge that sets `vm.pending_throw` with a stable DOMException.name. Use the repo's actual helper location from Task 0.4.

- [ ] **Step 7.2: Unit tests**

```zig
test "toggleAttribute throws InvalidCharacterError on invalid qname" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\try { el.toggleAttribute('foo bar'); false; }
        \\catch (e) { e.name === 'InvalidCharacterError'; }
    );
    try std.testing.expect(ok.asBool());
}

test "toggleAttribute still throws on empty name" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\try { el.toggleAttribute(''); false; }
        \\catch (e) { e.name === 'InvalidCharacterError'; }
    );
    try std.testing.expect(ok.asBool());
}
```

- [ ] **Step 7.3: Build + test + commit**

```bash
cd ~/suzume && zig build test 2>&1 | tail -30
git add src/js/kotori_dom.zig tests/test_kotori_dom.zig
git commit -m "$(cat <<'EOF'
feat(kotori): nativeToggleAttribute full isValidAttrName validation (1D.1 Task 7)

Upgrade the empty-check guard to dom_names.isValidAttrName for parity
with setAttribute / setAttributeNS (Layer 1A). Fixes WPT subtests that
exercise toggleAttribute('foo bar') expecting InvalidCharacterError,
which previously passed silently because the old guard only rejected
empty strings.

Spec: docs/superpowers/specs/2026-04-19-kotori-1D-1-attr-node-methods-design.md
  §QName validation wiring, work item #1

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Risk callout:** If the existing code passes `name_raw` through `argToString` FIRST, the validation must happen AFTER the ToString coercion — WPT sends `toggleAttribute(null)` which ToStrings to `"null"` (a valid name).

---

## Task 8: `refreshAttributesMap` — sweep stale indexed + named keys

**Files:**
- Modify: `src/js/kotori_dom.zig` — `refreshAttributesMap` @ L4791, new StringIds `g_sid_nnm_max_idx` + `g_sid_nnm_names`.

**Purpose:** Spec §refreshAttributesMap stale-index sweep — close the ~6 subtests driven by `el.attributes[oldN-1] === undefined` after a shrink. Track `__nnmMaxIdx` (high-water mark of written indexed keys) and `__nnmNames` (ghost-list of last-seen qnames as an inner JsObject). On refresh, delete surplus indexed keys and any named keys not in the current pass.

- [ ] **Step 8.1: Declare + intern new StringIds**

At module scope:
```zig
var g_sid_nnm_max_idx: ?StringId = null; // "__nnmMaxIdx"
var g_sid_nnm_names:   ?StringId = null; // "__nnmNames"
```

Inside `initNamedNodeMapProto`:
```zig
g_sid_nnm_max_idx = try vm.pool.intern("__nnmMaxIdx");
g_sid_nnm_names   = try vm.pool.intern("__nnmNames");
```

- [ ] **Step 8.2: Confirm `JsObject.removeProperty` exists**

```bash
grep -n "fn removeProperty\|\.removeProperty" src/js/kotori/object.zig src/js/kotori_dom.zig | head -10
```

Per spec §`removeProperty` requirement: if missing, land a 3-line helper on `JsObject` that unsets a named slot — but restrict to this file if possible to preserve the "no VM/object-model changes" property of this layer. If `JsObject.removeProperty` is not available, fall back to `setProperty(sid, JsValue.undefined_val)` + caller-side `hasOwnProperty` check elsewhere. Document the choice in the commit.

- [ ] **Step 8.3: Patch `refreshAttributesMap`**

Existing function body at L4791-L4831 writes indexed + named + length props. Wrap with sweeps:

```zig
fn refreshAttributesMap(vm: *VM, map_obj: *JsObject, elem: *lxb.lxb_dom_element_t) void {
    const cur_ver = g_elem_attr_ver.get(@intFromPtr(elem)) orelse 0;
    if (g_sid_nnm_ver) |sid|
        map_obj.setProperty(vm.allocator, sid, JsValue.initNumber(@floatFromInt(cur_ver))) catch {};

    // Read previous high-water mark of indexed properties.
    const prev_max: u32 = blk: {
        if (g_sid_nnm_max_idx) |sid| {
            if (map_obj.getProperty(sid)) |v| {
                if (!v.isNull() and !v.isUndefined())
                    break :blk @intFromFloat(v.toNumber());
            }
        }
        break :blk 0;
    };

    // Read ghost-list of last-seen qnames.
    const prev_names: ?*JsObject = blk: {
        if (g_sid_nnm_names) |sid| {
            if (map_obj.getProperty(sid)) |v| {
                if (v.isObject()) break :blk v.asObject();
            }
        }
        break :blk null;
    };

    // Build a fresh names set for THIS pass.
    const new_names = vm.createObj(.{}) catch null;

    var count: u32 = 0;
    var a_opaque = dom_b.lxb_dom_element_first_attribute_noi(elem);
    while (a_opaque) |p| {
        const attr: *lxb.lxb_dom_attr_t = @ptrCast(@alignCast(p));

        // … existing body: indexed set + named set via getOrCreateAttrWrapper …
        // (preserve pre-1D-1 logic; only insert tracking below)

        // Record qname in the new ghost-list.
        var qn_len: usize = 0;
        const qn_ptr = dom_b.lxb_dom_attr_qualified_name(attr, &qn_len);
        if (qn_ptr) |qn_p| {
            if (new_names) |nn| {
                if (vm.pool.intern(qn_p[0..qn_len])) |qn_sid| {
                    nn.setProperty(vm.allocator, qn_sid, JsValue.initBool(true)) catch {};
                }
            }
        }

        count += 1;
        a_opaque = dom_b.lxb_dom_element_next_attribute_noi(attr);
    }

    // Sweep stale indexed keys [count .. prev_max-1].
    if (prev_max > count) {
        var i: u32 = count;
        while (i < prev_max) : (i += 1) {
            var idx_buf: [16]u8 = undefined;
            if (std.fmt.bufPrint(&idx_buf, "{d}", .{i})) |idx_str| {
                if (vm.pool.intern(idx_str)) |sid| _ = map_obj.removeProperty(sid);
            } else |_| {}
        }
    }

    // Sweep stale NAMED keys: iterate prev_names, delete any qname not in new_names.
    if (prev_names) |pn| {
        if (new_names) |nn| {
            // Iterate pn's own properties. Use the VM's for-in primitive or
            // walk pn.props directly (repo-specific; grep first).
            var it = pn.propsIterator();
            while (it.next()) |entry| {
                if (nn.getProperty(entry.key) == null) {
                    _ = map_obj.removeProperty(entry.key);
                }
            }
        }
    }

    // Store new max + new names for next cycle.
    if (g_sid_nnm_max_idx) |sid|
        map_obj.setProperty(vm.allocator, sid, JsValue.initNumber(@floatFromInt(count))) catch {};
    if (g_sid_nnm_names) |sid| if (new_names) |nn|
        map_obj.setProperty(vm.allocator, sid, JsValue.initObject(nn)) catch {};

    if (vm.pool.intern("length")) |len_sid|
        map_obj.setProperty(vm.allocator, len_sid, JsValue.initNumber(@floatFromInt(count))) catch {};
}
```

Note `pn.propsIterator()` is pseudocode — substitute with the repo's actual property-iteration primitive (grep `propsIterator\|fn iter` in `src/js/kotori/object.zig`). If no iterator is available, switch to an array-stash scheme: store `__nnmNamesArr` as a native array of interned qnames instead.

- [ ] **Step 8.4: Caller audit per spec §Caller-audit notes**

Grep every caller of `refreshAttributesMap` and confirm the callers work with the new tracking slots:

```bash
grep -n "refreshAttributesMap" src/js/kotori_dom.zig
```

Expected call sites: inside `buildAttributesMap` (L4841) and the Element.attributes getter cache-hit path. Both should be safe — the new slots are additive.

- [ ] **Step 8.5: Unit tests (shrink case + named-key ghost)**

```zig
test "map index properties shrink correctly after removeAttribute" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\el.setAttribute('a', '1');
        \\el.setAttribute('b', '2');
        \\var m = el.attributes;
        \\var _ = m[1];  // materialise
        \\el.removeAttribute('a');
        \\m[1] === undefined && m.length === 1;
    );
    try std.testing.expect(ok.asBool());
}

test "map named properties sweep removed qnames" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\el.setAttribute('id', 'x');
        \\var m = el.attributes;
        \\var _ = m.id;
        \\el.removeAttribute('id');
        \\m.id === undefined;
    );
    try std.testing.expect(ok.asBool());
}
```

- [ ] **Step 8.6: Build + test + commit**

```bash
cd ~/suzume && zig build test 2>&1 | tail -30
git add src/js/kotori_dom.zig tests/test_kotori_dom.zig
git commit -m "$(cat <<'EOF'
feat(kotori): refreshAttributesMap stale indexed + named key sweep (1D.1 Task 8)

Add __nnmMaxIdx (high-water mark) and __nnmNames (ghost-list) tracking
slots. On each refresh, delete indexed keys [count..prev_max) and any
named keys from the previous pass that are not in the current lexbor
attribute list.

Fixes ~6 subtests that observe el.attributes[oldN-1] === undefined
after a shrink or el.attributes.oldName === undefined after removal.

Spec: docs/superpowers/specs/2026-04-19-kotori-1D-1-attr-node-methods-design.md
  §refreshAttributesMap stale-index sweep

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Risk callouts (spec §R5):** Named-key sweep is O(prev_N + cur_N) per refresh. For SVG elements with 20+ attrs this may show up in profiles; measure against full `dom/nodes` + `svg` baseline. If regression appears, fall back to Option B (drop-recreate) but verify `el.attributes === el.attributes` still holds WITHOUT intervening mutations.

---

## Task 9 — WPT interim verification before polyfill delete

**Files:** None modified. Verification only.

**Purpose:** Spec §Pre-deletion checklist — WPT `attributes.html` must score ≥ 35/67 **with the polyfill still installed** so Task 11 becomes a net-zero commit (the native path drove the gains; deletion removes the parallel code path without changing behaviour).

- [ ] **Step 9.1: Run target WPT files with polyfill still installed**

```bash
cd ~/suzume
zig build -Doptimize=ReleaseSafe 2>&1 | tail -20
for run in 1 2 3; do
  TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
    dom/nodes/attributes.html \
    dom/nodes/NamedNodeMap-supported-property-names.html \
    dom/nodes/Element-hasAttributeNS.html \
    dom/nodes/Element-removeAttributeNS.html \
    dom/nodes/Element-getAttributeNode.html \
    dom/nodes/Element-setAttributeNode.html \
    dom/nodes/Element-removeAttributeNode.html 2>&1 | tee /tmp/wpt-1D-1-pre-delete-run$run.txt
done
```

Expected: `attributes.html` ≥ **35/67**. If lower, one of Tasks 1-8 has a gap — do NOT proceed to Task 10. Diagnose which native method the failing subtest hits and fix inline.

- [ ] **Step 9.2: Gate check**

Compare vs `/tmp/wpt-1D-1-baseline.txt` from Task 0: every file must be ≥ baseline. If any file regresses, bisect across Tasks 1-8 to find the introducing commit.

- [ ] **Step 9.3: Record findings**

Append a summary block to `/tmp/p0-1D-1-audit.md` with the 3-run counts. No commit at this phase — this is a gate.

**Risk callout:** If `attributes.html` falls short of 35/67 here, the plan's premise is wrong — either the polyfill was doing more than the spec's §Context analysis captured, OR Task 5/6/8's native code path has a spec-divergence. Do NOT proceed to Tasks 10/11 until gate passes.

---

## Task 10: `importNode` Attr pre-check (conditional)

**Files:**
- Modify: `src/js/kotori_dom.zig` — only if Task 0.6 found that native `importNode` does NOT handle `nodeType===2`.

**Purpose:** Spec §R4 — the polyfill's docstring at `kotori_runtime.zig:1486-1490` says it "extends Document.importNode to handle Attr nodes returned by our polyfilled getAttributeNodeNS." If native `importNode` already handles Attr, this task is a no-op commit marker. Otherwise add a minimal Attr branch so Task 11 does not regress `Document-importNode.html`.

- [ ] **Step 10.1: Confirm whether native `importNode` handles Attr**

```bash
cd ~/suzume
grep -n "importNode\|nativeImportNode" src/js/kotori_dom.zig | head -20
```

Locate the `nativeImportNode` function body. Inside it, grep for `LXB_DOM_NODE_TYPE_ATTRIBUTE` or `nodeType == 2`. If present with a clone path, SKIP to Step 10.4 (no changes). Else proceed.

- [ ] **Step 10.2: Add Attr branch to `nativeImportNode` (if missing)**

Inside the switch on `nodeType`:

```zig
2 => { // LXB_DOM_NODE_TYPE_ATTRIBUTE — deep clone has no children to walk.
    // createAttributeNS(attr.namespaceURI, attr.qualifiedName).value = attr.value
    const ns = readAttrObjNs(vm, src_obj);
    const local = readAttrObjLocalName(vm, src_obj) orelse return JsValue.null_val;
    var qn_buf: [512]u8 = undefined;
    const qn = buildQNameFromAttrObj(vm, src_obj, &qn_buf) orelse return JsValue.null_val;
    const value = readAttrObjValue(vm, src_obj);
    const new_attr = try createAttributeOnDocument(vm, doc, ns, qn, value);
    _ = local;
    return JsValue.initObject(new_attr);
},
```

`createAttributeOnDocument` is pseudocode — use whichever internal createAttribute helper the rest of the file uses (grep for `createAttributeNS` callers).

- [ ] **Step 10.3: Unit test (if branch added)**

```zig
test "importNode(attr) clones an Attr across documents" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var d1 = document.implementation.createDocument(null, 'root', null);
        \\var el = d1.documentElement;
        \\el.setAttribute('id', 'x');
        \\var a = el.getAttributeNode('id');
        \\var b = document.importNode(a, true);
        \\b !== a && b.value === 'x' && b.ownerElement === null;
    );
    try std.testing.expect(ok.asBool());
}
```

- [ ] **Step 10.4: Build + test + commit (or skip)**

If no changes: commit with `--allow-empty` only if strictly needed by the subagent plan runner; otherwise skip this task and note its skip in `/tmp/p0-1D-1-audit.md`.

```bash
cd ~/suzume && zig build test 2>&1 | tail -30
git add src/js/kotori_dom.zig tests/test_kotori_dom.zig
git commit -m "$(cat <<'EOF'
feat(kotori): importNode Attr branch (1D.1 Task 10)

Add nodeType===2 case to nativeImportNode so Task 11's polyfill delete
does not regress Document-importNode.html. The polyfill previously
extended Document.importNode to handle Attr wrappers returned by
polyfilled getAttributeNodeNS; this mirrors that behaviour natively.

Spec: docs/superpowers/specs/2026-04-19-kotori-1D-1-attr-node-methods-design.md
  §R4 (polyfill createAttribute clone semantics)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Risk callout:** If the Attr branch is already present in `nativeImportNode`, this task is pure audit. Do NOT force-add duplicated code for plan bookkeeping — just mark skipped.

---

## Task 11: Delete the JS polyfill (MUST BE LAST CODE TASK)

**Files:**
- Modify: `src/js/kotori_runtime.zig` — delete L1491-L1823 (`attributes_polyfill_js` block + preceding doc comment) AND the `_ = self.eval(attributes_polyfill_js);` call at L92.

**Purpose:** Retire the 333-line polyfill. Spec §Polyfill deletion — after all eleven native methods / features are in place, the native code matches the polyfill's surface area with matching semantics. The identity bug (polyfill Attr `!==` native Attr for the same DOM attribute) is gone when only the native path exists.

**Prerequisite gate:** Tasks 1-10 committed. `zig build test` green. Task 9's WPT gate passed (`attributes.html` ≥ 35/67 WITH polyfill installed). If any precondition fails, DO NOT proceed.

- [ ] **Step 11.1: Re-confirm baseline with polyfill still present**

```bash
cd ~/suzume
zig build test 2>&1 | tail -10
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
  dom/nodes/attributes.html \
  dom/nodes/NamedNodeMap-supported-property-names.html \
  dom/nodes/Element-hasAttributeNS.html \
  dom/nodes/Element-removeAttributeNS.html 2>&1 | tee /tmp/wpt-1D-1-pre-delete.txt
```

Confirm counts match the best run from Task 9. This is the floor — post-delete must be equal or higher.

- [ ] **Step 11.2: Delete the `self.eval` call at L92**

Use `Edit` with a unique anchor. Grep first:

```bash
grep -n "attributes_polyfill_js" src/js/kotori_runtime.zig
```

Delete the line:

```zig
_ = self.eval(attributes_polyfill_js);
```

- [ ] **Step 11.3: Delete the polyfill block at L1491-L1823**

Locate opening and closing anchors:

```bash
sed -n '1485,1495p' src/js/kotori_runtime.zig   # doc comment + `const ... =`
sed -n '1818,1828p' src/js/kotori_runtime.zig   # closing `})();` + `;`
```

Use `Edit` with the surrounding anchors (NOT a line-range delete) to avoid drift. Include any doc comments immediately preceding the `const attributes_polyfill_js =` block (spec ref L1486-L1490).

- [ ] **Step 11.4: Build + test**

```bash
cd ~/suzume && zig build test 2>&1 | tail -30
```

Expected: **all unit tests pass**. If any test fails, do NOT revert — diagnose which native method or helper is missing. The failure localises the gap.

- [ ] **Step 11.5: Post-delete WPT**

```bash
cd ~/suzume
for run in 1 2 3; do
  TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
    dom/nodes/attributes.html \
    dom/nodes/NamedNodeMap-supported-property-names.html \
    dom/nodes/Element-hasAttributeNS.html \
    dom/nodes/Element-removeAttributeNS.html \
    dom/nodes/Element-getAttributeNode.html \
    dom/nodes/Element-setAttributeNode.html \
    dom/nodes/Element-removeAttributeNode.html \
    dom/nodes/Document-importNode.html 2>&1 | tee /tmp/wpt-1D-1-post-delete-run$run.txt
done
```

Expected: identical to Task 9 counts (net-zero). Any drop worse than -1 subtest per file is a blocker.

- [ ] **Step 11.6: Commit**

```bash
cd ~/suzume
git add src/js/kotori_runtime.zig
git commit -m "$(cat <<'EOF'
refactor(kotori): retire attributes_polyfill_js (Layer 1D.1 Task 11)

Remove the 333-line JS sidecar polyfill at kotori_runtime.zig:1491-1823
(reinstalled via revert 7c31ab6 after Layer 1D Task 9) and its eval()
call site at L92.

All eleven contract items listed in the Layer 1D.1 spec are now
covered natively:
  1-2. Element.getAttributeNode[NS]            (1D.1 Task 1)
  3-4. Element.setAttributeNode[NS]            (1D.1 Task 5)
  5.   Element.removeAttributeNode             (1D.1 Task 6)
  6.   Element.hasAttributeNS                  (1D.1 Task 2)
  7.   Element.getAttributeNS                  (1D.1 Task 2)
  8.   Element.removeAttributeNS               (1D.1 Task 3)
  9.   nativeToggleAttribute isValidAttrName   (1D.1 Task 7)
  10.  refreshAttributesMap stale-key sweep    (1D.1 Task 8)
  11.  importNode Attr branch                  (1D.1 Task 10)

el.attributes[0] === el.getAttributeNode('id') now holds across all
entry points; the polyfill's parallel __attrList sidecar is gone.

WPT attributes.html delta recorded at /tmp/wpt-1D-1-post-delete-run*.txt.

Spec: docs/superpowers/specs/2026-04-19-kotori-1D-1-attr-node-methods-design.md
  §Polyfill deletion, §Acceptance criteria

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Risk callouts (highest-risk task):**
- **Ordering**: MUST be the last code task. Tasks 1-10 install every contract item the polyfill provided; deleting earlier produces the -26 regression that motivated this plan.
- **`setAttributeNode` / `getAttributeNode` / `removeAttributeNode` coverage**: Tasks 1/5/6 own these three. If any native registration is missing (grep `setAttributeNode` in `el_proto` registration blocks), Step 11.4 will surface the gap — fix in-place, do NOT revert.
- **`importNode` Attr branch**: If Task 10 was skipped (native already handled), Step 11.5's `Document-importNode.html` line must not regress. If it does, revert Task 11 ONLY, finish Task 10's Attr branch properly, then re-run.
- **Polyfill `validateAndExtract` / `validateName`**: These are Layer 1A's responsibility. If Task 11 surfaces QName-validation regressions (WPT subtests expecting `InvalidCharacterError` / `NamespaceError`), the native call sites already cover them per spec §QName validation wiring table — debug the call site, not the polyfill.

---

## Task 12: Final WPT verification + spec acceptance gate

**Files:** None modified. Produces verification evidence.

**Purpose:** Run the full acceptance-criteria sweep. Dispatch a verifier agent in a separate context per OMC's no-self-approval rule.

- [ ] **Step 12.1: Gate A — primary targets (3 runs)**

```bash
cd ~/suzume
for run in 1 2 3; do
  TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
    dom/nodes/attributes.html \
    dom/nodes/NamedNodeMap-supported-property-names.html 2>&1 | tee /tmp/wpt-1D-1-gate-a-run$run.txt
done
```

Spec targets:
- `attributes.html`: **≥ 35/67** (recovers the -26 regression); **stretch ≥ 50/67**.
- `NamedNodeMap-supported-property-names.html`: ≥ Layer 1D baseline + 5 subtests from the stale-name sweep.

Counts must be identical across 3 runs (flake check).

- [ ] **Step 12.2: Gate B — Element/Attr neighborhood regression**

```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
  dom/nodes/Element-getAttributeNode.html \
  dom/nodes/Element-setAttributeNode.html \
  dom/nodes/Element-removeAttributeNode.html \
  dom/nodes/Element-hasAttributeNS.html \
  dom/nodes/Element-removeAttributeNS.html \
  dom/nodes/Document-importNode.html \
  dom/nodes/Node-cloneNode-AElement.html 2>&1 | tee /tmp/wpt-1D-1-gate-b.txt
```

Expected: no regression worse than -2 subtests vs `/tmp/wpt-1D-1-baseline.txt`.

- [ ] **Step 12.3: Gate C — dom/nodes full regression**

```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/nodes 2>&1 | tee /tmp/wpt-1D-1-gate-c.txt
```

Expected: no net regression vs pre-1D-1 baseline from Task 0.5.

- [ ] **Step 12.4: Identity spot-check**

```bash
./zig-out/bin/suzume --eval "
var el = document.createElement('div');
el.setAttribute('x', '1');
console.log(el.attributes[0] === el.getAttributeNode('x'));  // expect true
console.log(el.attributes[0] === el.attributes.getNamedItem('x'));  // expect true
"
```

Both must print `true` — this is spec §Acceptance criteria bullet #1 and the single strongest signal that the polyfill-vs-native identity bug is gone.

- [ ] **Step 12.5: Dispatch verifier agent (separate context)**

Per OMC rule, dispatch a verifier subagent with:
- Spec: `docs/superpowers/specs/2026-04-19-kotori-1D-1-attr-node-methods-design.md`
- Gate outputs: `/tmp/wpt-1D-1-{baseline,gate-a-run{1,2,3},gate-b,gate-c,post-delete-run{1,2,3}}.txt`
- Success criteria: spec §Acceptance criteria (9 checkboxes)

Ask for APPROVED / REJECTED with per-criterion citation.

- [ ] **Step 12.6: Record WPT progress**

If APPROVED, append session entry to `memory/project_suzume_wpt_progress.md` recording new subtest counts for `attributes.html` + `NamedNodeMap-supported-property-names.html` + the three Attr-node files + the two NS files.

- [ ] **Step 12.7: Mark plan complete**

No commit required — documentation stays in-repo.

---

## Completion Checklist

Before declaring this plan DONE:

- [ ] Tasks 1-10 commits landed (11 total including Task 9/11; Task 10 may be a no-op skip)
- [ ] `zig build test` green at HEAD
- [ ] Spec §Acceptance criteria bullet 1: `el.attributes[0] === el.getAttributeNode('id')` holds
- [ ] Spec §Acceptance criteria bullets 2-4: setAttributeNode / removeAttributeNode error semantics (InUseAttributeError / NotFoundError / TypeError) verified via unit tests
- [ ] Spec §Acceptance criteria bullet 5: `""` → null ns coercion verified for `hasAttributeNS` / `getAttributeNS` / `removeAttributeNS`
- [ ] Spec §Acceptance criteria bullet 6: `nativeToggleAttribute` calls `dom_names.isValidAttrName`
- [ ] Spec §Acceptance criteria bullet 7: `refreshAttributesMap` sweeps stale indexed AND named keys
- [ ] Spec §Acceptance criteria bullet 8: `attributes_polyfill_js` removed from `kotori_runtime.zig`; eval call at L92 removed
- [ ] Spec §Acceptance criteria bullet 9: `attributes.html` ≥ 35/67 (stretch ≥ 50/67)
- [ ] `baseline_results.txt` shows no regressions in `dom/nodes/Element-*`, `dom/nodes/Attr-*`, `html/dom/reflection-*`
- [ ] Verifier agent APPROVED in separate context
- [ ] Memory updated with new WPT numbers

---

## Notes for the Executor

- **Spec is the contract.** When plan and spec differ, the spec wins: `docs/superpowers/specs/2026-04-19-kotori-1D-1-attr-node-methods-design.md`.
- **Do not skip Task 0.** Line numbers in the spec were captured at `4da2d54`; this plan's Task 0.2 produces a fresh line map. Follow the fresh map, not the spec.
- **One commit per task.** Each task is individually bisectable. If a WPT regression appears after Task 11, bisect across Tasks 1-10 first; the commit introducing the drop localises the bug.
- **Task 5 is the highest-complexity task.** Budget extra time; the InUseAttributeError + idempotence + re-key interlock mirrors Layer 1D Task 7's complexity.
- **Task 11 (polyfill delete) is the highest-risk task.** Do not proceed without green `zig build test` on every prior task AND Task 9's WPT interim gate passing. If Task 11 Step 11.4 fails, diagnose in-place — do NOT revert without understanding which native shim is missing.
- **Scope is `src/js/kotori_dom.zig` + `src/js/kotori_runtime.zig` only.** If any task suggests editing `src/js/kotori/vm.zig` or `src/js/kotori/object.zig`, stop — the VM's primitives (`pending_throw`, `createDOMExceptionObj`, `createNativeFn`, property iteration) are already sufficient. Task 8's `removeProperty` is the only possible object-model touchpoint; prefer `setProperty(sid, undefined)` + audit over a new object-model primitive.
- **Task 10 may be a no-op.** If native `importNode` already handles Attr, skip without commit and record in the audit notes. Do not force-add duplicated code for plan bookkeeping.
- **Do not re-land Task 9's full polyfill delete without gate passing.** The -26 regression that motivated this entire plan came from deleting too early. The explicit pre-delete WPT gate (Task 9) + post-delete verification (Task 11.5) exists precisely to prevent that.
