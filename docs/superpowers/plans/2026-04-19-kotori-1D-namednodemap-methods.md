# kotori Layer 1D — NamedNodeMap Methods — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promote `Element.attributes` from a synthetic plain `JsObject` to a spec-compliant `NamedNodeMap` with its own prototype (`g_namednodemap_proto`), the 8 WHATWG DOM §4.9.2 methods (`item`, `getNamedItem[NS]`, `setNamedItem[NS]`, `removeNamedItem[NS]`, `[Symbol.iterator]`), live semantics via a per-element version counter, and stable `el.attributes === el.attributes` identity — then retire the 333-line JS polyfill at `src/js/kotori_runtime.zig:1491-1823` that shadows the native code path. WPT delta target: +18 to +32 subtests on `dom/nodes/attributes.html` and ≥50% pass on `dom/nodes/NamedNodeMap-supported-property-names.html`.

**Architecture:**
- New module-level slot `g_namednodemap_proto: ?*JsObject` alongside `g_attr_wrappers` (`kotori_dom.zig:423`).
- New init function `initNamedNodeMapProto(vm)` called from `initKotoriDom` / `ensureDomEnv` **before** the bootstrap document wrap (preserves the `g_html_protos != null` assertion ordering at `kotori_dom.zig:477`).
- `globalThis.NamedNodeMap` constructor wired to `g_namednodemap_proto` as `.prototype`; constructor itself throws `TypeError` when invoked (WebIDL §3.6.1).
- `buildAttributesMap` (`kotori_dom.zig:4236-4273`) sets `map_obj.prototype = g_namednodemap_proto.?` and stashes the owning element pointer in a hidden `__nnmElem` slot so methods can re-resolve the live attribute list without a full rewalk.
- Per-Element attribute version counter (`g_elem_attr_ver: std.AutoHashMapUnmanaged(usize, u64)`) bumped at every mutation site; map objects stash the version they were built at in `__nnmVer` and lazily refresh indexed/named own properties via a refactored `refreshAttributesMap` helper.
- `el.attributes === el.attributes` identity: cache the map JsObject on the Element via `__nnmCache` slot.
- `Attr.ownerElement` promoted to first-class: `setAttrOwnerElement(vm, attr_obj, owner)` helper writes both the JS own property AND a hidden `__ownerElemPtr` integer slot; called from `getOrCreateAttrWrapper`, `nativeRemoveAttribute`, `nativeToggleAttribute` (removal branch), and the new `setNamedItem` path.
- **Critical dependency — polyfill delete ordering:** The 333-line `attributes_polyfill_js` at `kotori_runtime.zig:1491-1823` overrides `Element.prototype.setAttribute`/`getAttribute`/`setAttributeNode`/etc. and maintains a parallel `__attrList` sidecar whose Attr wrappers are **not `===`** to the native `g_attr_wrappers` entries. This polyfill MUST remain in place while Tasks 1-8 are implemented (so existing tests keep passing) and is removed **only after** the native code covers all its functionality. Removing it earlier regresses the WPT baseline.

**Tech Stack:** Zig 0.15.2, lexbor (HTML parser — `lxb_dom_element_first_attribute_noi`, `lxb_dom_element_next_attribute_noi`, `lxb_dom_element_attr_by_name`, `lxb_dom_element_set_attribute`, `lxb_dom_element_remove_attribute`), kotori JS engine (in-tree at `src/js/kotori/`), WPT (Web Platform Tests).

**Spec:** `docs/superpowers/specs/2026-04-19-kotori-1D-namednodemap-methods-design.md`
**Parent roadmap:** `docs/superpowers/specs/2026-04-17-kotori-suzume-wpt-100-roadmap.md` §1D (Layer 1 sub-project, target +18 to +59 subtests)

---

## File Structure

### Files to modify
- `src/js/kotori_dom.zig` — **bulk of the work**. ~6,000-line file. Touches:
  - Near L40-L425 — declare `g_namednodemap_proto`, `g_elem_attr_ver`, new `StringId` slots (`g_sid_nnm_elem`, `g_sid_nnm_ver`, `g_sid_nnm_cache`, `g_sid_owner_elem_ptr`)
  - `initKotoriDom` / `ensureDomEnv` — call new `initNamedNodeMapProto(vm)` before bootstrap doc wrap
  - `getOrCreateAttrWrapper` (L4188-L4229) — set `ownerElement` via `setAttrOwnerElement` using `attr.node.owner → lxb_dom_element_t*`
  - `buildAttributesMap` (L4236-L4273) — prototype-link to `g_namednodemap_proto`, stash `__nnmElem` + `__nnmVer`; factor body into `refreshAttributesMap(vm, map_obj, elem)` so liveness paths can call it
  - Element.attributes getter at L1206-L1210 — add identity cache via `__nnmCache` lookup before calling `buildAttributesMap`
  - `nativeSetAttribute` (L3045-L3075) — call `bumpElemAttrVersion(elem)` after successful set
  - `nativeSetAttributeNS` (L3073-L3112) — same
  - `nativeRemoveAttribute` (L3114-L3140) — same; also clear `setAttrOwnerElement(old_attr, null)`
  - `nativeToggleAttribute` (L4999-L5050) — same at both add and remove branches
  - New native functions appended near the existing NamedNodeMap-adjacent helpers: `nativeNnmItem`, `nativeNnmGetNamedItem`, `nativeNnmGetNamedItemNS`, `nativeNnmSetNamedItem` (shared with `setNamedItemNS`), `nativeNnmRemoveNamedItem`, `nativeNnmRemoveNamedItemNS`, `nativeNnmSymbolIterator`, `nativeNnmIteratorNext`, and the `NamedNodeMap` constructor stub (`nativeNnmConstructor`)
  - New helpers: `nnmElem(this) ?*lxb.lxb_dom_element_t`, `bumpElemAttrVersion(elem)`, `refreshAttributesMap(vm, map_obj, elem)`, `setAttrOwnerElement(vm, attr_obj, owner)`, `elementInHtmlDoc(elem)`, `lookupAttrByNsLocal(elem, ns, local)`, `iterResultDone(vm)`, `iterResultValue(vm, val)` (reuse existing if present — grep first)

- `src/js/kotori_runtime.zig` — **delete** the `attributes_polyfill_js` block at **lines 1491-1823** (the 333-line IIFE) AND remove the `_ = self.eval(attributes_polyfill_js);` call site at **L92**. Per spec §R1 the polyfill's `validateAndExtract` / `validateName` QName-validation pieces are Layer 1A's responsibility; they are **not** in scope for 1D — Layer 1A either owns them already or handles that follow-up.

- `tests/test_kotori_dom.zig` — extend with new unit tests for each method (~8-10 tests).

### Files to NOT modify
- `src/js/kotori/vm.zig` — **no VM changes needed** per spec §Iterator. The `Symbol.iterator` registration pattern at `vm.zig:2385-2388` (nativeArraySymbolIterator) already works for any prototype. `get_iterator` opcode dispatch at `vm.zig:1863-1874` already calls `resolveIterator` which reads `obj.symbol_props`. Iterator results use `obj_type = .iterator` with `iterator_data.source` — NamedNodeMap reuses all of this.
- `src/js/dom_api.zig`, `src/js/dom_element.zig`, `src/js/dom_document.zig` — QuickJS-era parallel binding; not touched.
- `src/js/kotori/object.zig` — no object-model changes.

---

## Task 0: P0 Audit — No-Code Gate

**Files:** None modified; produces a notes file for subsequent tasks.

**Purpose:** Verify spec assumptions against current HEAD. Produces baseline WPT numbers, confirms the polyfill is still the only `NamedNodeMap` implementation, and confirms the iterator infrastructure is still VM-level-ready. No code writes.

- [ ] **Step 0.1: Verify the JS polyfill is still present at kotori_runtime.zig:1491-1823**

Run:
```bash
cd ~/suzume
grep -n "attributes_polyfill_js" src/js/kotori_runtime.zig
```

Expected: two hits — one declaration near L1491, one `self.eval(attributes_polyfill_js)` call near L92. Record both line numbers exactly. Then:

```bash
sed -n '1491,1495p' src/js/kotori_runtime.zig
sed -n '1818,1825p' src/js/kotori_runtime.zig
```

Expected: opening `const attributes_polyfill_js = \\(function(){...` at L1491 and closing `\\})();` + `;` at ~L1823. If the block has drifted (ownership by an earlier layer) adjust Task 9's delete range before running it.

- [ ] **Step 0.2: Verify `buildAttributesMap` at kotori_dom.zig:4236-4273 uses plain `JsObject` (no prototype)**

Run:
```bash
grep -n "fn buildAttributesMap" src/js/kotori_dom.zig
sed -n '4236,4275p' src/js/kotori_dom.zig
```

Expected: function body calls `vm.createObj(.{})` without a subsequent `.prototype =` assignment. If a prototype link already exists, the Task 2 refactor becomes smaller — record the discovery.

- [ ] **Step 0.3: Verify `g_attr_wrappers` at kotori_dom.zig:423**

Run:
```bash
grep -n "g_attr_wrappers" src/js/kotori_dom.zig | head -20
```

Expected: declaration at L423; `invalidateAttrWrapper` at L427-L429; deinit at L572-L573; `put` at L4228 (inside `getOrCreateAttrWrapper`); one `get` cache-hit at L4190. Confirm no stale references in `dom_api.zig` or other legacy files.

- [ ] **Step 0.4: Verify iterator pattern at vm.zig:2385-2388**

Run:
```bash
sed -n '2380,2395p' src/js/kotori/vm.zig
```

Expected: the block ends with `try ap.symbol_props.?.put(self.allocator, SYMBOL_ITERATOR, JsValue.initObject(arr_iter_fn));`. This confirms the same pattern is available for NamedNodeMap. Also verify `SYMBOL_ITERATOR` is a module-level constant:

```bash
grep -n "^\(pub \)\?const SYMBOL_ITERATOR" src/js/kotori/vm.zig
```

Expected: single declaration. If it is file-local (not `pub`), Task 8 must either use it via an internal accessor or add a small `pub` getter — record whichever.

- [ ] **Step 0.5: Baseline WPT measurements**

Run:
```bash
cd ~/suzume
zig build -Doptimize=ReleaseSafe 2>&1 | tail -20
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
  dom/nodes/attributes.html \
  dom/nodes/NamedNodeMap-supported-property-names.html \
  dom/nodes/Element-hasAttributes.html 2>&1 | tee /tmp/wpt-1D-baseline.txt
```

Record pass/fail counts for each file. These become the reference for Task 11's gate. Per spec target: attributes.html needs **+18 to +32 subtests**, NamedNodeMap-supported-property-names.html needs **≥50% pass**.

- [ ] **Step 0.6: Spot-check existing `ownerElement` population**

Run:
```bash
grep -n "ownerElement" src/js/kotori_dom.zig | head -30
```

Confirm: `createAttribute`/`createAttributeNS` at L2280 already writes `ownerElement: null`; `getOrCreateAttrWrapper` at L4188-L4229 does **not** currently set `ownerElement`. Task 10 closes this gap.

- [ ] **Step 0.7: Record findings**

Write the six findings above into `/tmp/p0-1D-audit.md` for reference during Tasks 1-11. No repo commit at this phase — P0 is a no-code gate.

**Risk callout:** If Step 0.1 shows the polyfill has already been deleted by an earlier layer, **stop** and re-scope: the premise of this plan (polyfill-delete ordering) is invalidated and the native path may already own the contract partially. Treat as a planning regression and escalate to the roadmap owner before writing code.

---

## Task 1: Register `NamedNodeMap.prototype` + global constructor

**Files:**
- Modify: `src/js/kotori_dom.zig` — add `g_namednodemap_proto`, string IDs, `initNamedNodeMapProto`, constructor stub, hook into init

**Purpose:** Install the prototype and constructor so subsequent tasks can hang native methods on a stable object, and so `instanceof NamedNodeMap` + `Symbol.toStringTag` work. Nothing calls into the new prototype yet — existing maps still return plain objects (fixed in Task 2).

- [ ] **Step 1.1: Declare the module-level slot and new `StringId`s**

Find the `g_attr_wrappers` declaration at `kotori_dom.zig:423`. Insert immediately after it:

```zig
/// DOM §4.9.2 NamedNodeMap.prototype — single shared prototype for every
/// live `Element.attributes` object. Populated during initNamedNodeMapProto()
/// before any document is wrapped.
var g_namednodemap_proto: ?*JsObject = null;

/// Per-element monotonic version counter. Bumped at every mutation
/// (setAttribute / setAttributeNS / removeAttribute / toggleAttribute /
/// setNamedItem / removeNamedItem). Read via `__nnmVer` slot on map objects
/// to decide whether to refresh indexed+named snapshots.
var g_elem_attr_ver: std.AutoHashMapUnmanaged(usize, u64) = .{};

// Interned string IDs for hidden NamedNodeMap slots. Populated in initNamedNodeMapProto.
var g_sid_nnm_elem: ?StringId = null;       // "__nnmElem"      usize elem ptr
var g_sid_nnm_ver: ?StringId = null;        // "__nnmVer"       u64 version
var g_sid_nnm_cache: ?StringId = null;      // "__nnmCache"     *JsObject map
var g_sid_owner_elem_ptr: ?StringId = null; // "__ownerElemPtr" usize elem ptr (on Attr)
```

Also extend the existing deinit near L572 to free the version map:
```zig
g_elem_attr_ver.deinit(g_alloc);
g_elem_attr_ver = .{};
```

- [ ] **Step 1.2: Write `initNamedNodeMapProto`**

Add near the other init helpers in `kotori_dom.zig` (reference existing pattern around the HTML proto init):

```zig
fn initNamedNodeMapProto(vm: *VM) !void {
    if (g_namednodemap_proto != null) return; // idempotent

    // Intern hidden slot names once.
    g_sid_nnm_elem = try vm.pool.intern("__nnmElem");
    g_sid_nnm_ver = try vm.pool.intern("__nnmVer");
    g_sid_nnm_cache = try vm.pool.intern("__nnmCache");
    g_sid_owner_elem_ptr = try vm.pool.intern("__ownerElemPtr");

    const proto = try vm.createObj(.{});
    // proto.prototype stays as vm.object_proto default.
    g_namednodemap_proto = proto;

    // Symbol.toStringTag = "NamedNodeMap"
    const tag_sid = try vm.pool.intern("Symbol.toStringTag_nnm_tag");
    _ = tag_sid; // placeholder if kotori's symbol-toStringTag convention differs
    // Use the convention already adopted elsewhere in kotori_dom.zig for toStringTag.
    // Example (adjust to repo style):
    try proto.setProperty(vm.allocator, try vm.pool.intern("@@toStringTag"),
        try JsValue.fromStr(vm, "NamedNodeMap"));

    // Constructor object.
    const ctor = try vm.createNativeFn(&nativeNnmConstructor);
    try ctor.setProperty(vm.allocator, try vm.pool.intern("prototype"),
        JsValue.initObject(proto));
    try proto.setProperty(vm.allocator, try vm.pool.intern("constructor"),
        JsValue.initObject(ctor));
    try vm.globals.put(vm.allocator, try vm.pool.intern("NamedNodeMap"),
        JsValue.initObject(ctor));

    // Method registration happens in Tasks 5-8 to keep commits atomic.
}

fn nativeNnmConstructor(ctx: *anyopaque, _: JsValue, _: []const u8) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    vm.pending_throw = try createDOMExceptionObj(vm, "TypeError");
    return JsValue.undefined_val;
}
```

**Verify first** that kotori's toStringTag convention is `"@@toStringTag"` or an actual Symbol — grep `grep -n "toStringTag" src/js/kotori_dom.zig` for existing precedent and match it. If kotori uses `vm.symbol_to_string_tag` or similar, substitute.

- [ ] **Step 1.3: Hook into `initKotoriDom` / `ensureDomEnv`**

Find the init path that sets up the other protos (search for `g_html_protos` setup near L477). Immediately after `vm.element_proto` is available and **before** the bootstrap document is wrapped, insert:

```zig
try initNamedNodeMapProto(vm);
```

Rationale (spec §Init sequence): `Attr.ownerElement` paths need `vm.element_proto` to already exist; `buildAttributesMap` called during bootstrap document wrap needs `g_namednodemap_proto` to be non-null.

- [ ] **Step 1.4: Unit test — prototype plumbing**

Append to `tests/test_kotori_dom.zig`:

```zig
test "NamedNodeMap constructor + prototype are installed before first document wrap" {
    var vm = try testVm();
    defer vm.deinit();
    const has_ctor = try runJs(&vm, "typeof NamedNodeMap === 'function'");
    try std.testing.expect(has_ctor.asBool());
    const has_proto = try runJs(&vm, "typeof NamedNodeMap.prototype === 'object'");
    try std.testing.expect(has_proto.asBool());
    const stringtag = try runJs(&vm,
        \\Object.prototype.toString.call(NamedNodeMap.prototype) === '[object NamedNodeMap]'
    );
    try std.testing.expect(stringtag.asBool());
}

test "new NamedNodeMap() throws TypeError" {
    var vm = try testVm();
    defer vm.deinit();
    const threw = try runJs(&vm,
        \\try { new NamedNodeMap(); false; } catch (e) { e instanceof TypeError; }
    );
    try std.testing.expect(threw.asBool());
}
```

- [ ] **Step 1.5: Build + test**

```bash
cd ~/suzume && zig build test 2>&1 | tail -30
```

Expected: new tests pass. No regressions elsewhere. Existing `el.attributes.__proto__ === Object.prototype` tests (if any) must still pass because `buildAttributesMap` is **not** yet wired — that is Task 2.

- [ ] **Step 1.6: Commit**

```bash
cd ~/suzume
git add src/js/kotori_dom.zig tests/test_kotori_dom.zig
git commit -m "$(cat <<'EOF'
feat(kotori): register NamedNodeMap.prototype + constructor (Layer 1D Task 1)

Add g_namednodemap_proto slot, g_elem_attr_ver per-element version
counter, and four hidden StringId slots (__nnmElem, __nnmVer,
__nnmCache, __ownerElemPtr). initNamedNodeMapProto(vm) is called from
initKotoriDom before the bootstrap document wrap so buildAttributesMap
in Task 2 can link to it.

globalThis.NamedNodeMap is a native constructor that throws TypeError
on direct invocation (WebIDL §3.6.1). Methods are added in Tasks 5-8.

Spec: docs/superpowers/specs/2026-04-19-kotori-1D-namednodemap-methods-design.md §"NamedNodeMap prototype registration"

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Risk callout:** The polyfill at `kotori_runtime.zig:1491-1823` still runs after this task — any WPT subtest exercising `el.attributes.constructor === NamedNodeMap` still fails because `buildAttributesMap` has not yet been wired to `g_namednodemap_proto`. This is **expected** until Task 2 lands.

---

## Task 2: Refactor `buildAttributesMap` to link prototype + stash backing element

**Files:**
- Modify: `src/js/kotori_dom.zig` — rewire map construction (L4236-L4273), extract `refreshAttributesMap`

**Purpose:** Make every newly built `el.attributes` map object carry the `NamedNodeMap` prototype and a backing-element pointer, so methods added in later tasks can resolve the live list. Preserve existing indexed/named own-property prewrite (spec §Liveness Option A) so `map[0]` and `map["id"]` keep working without custom getters.

- [ ] **Step 2.1: Extract refresh body**

Factor the existing walk body (currently inline in `buildAttributesMap` at L4236-L4273) into:

```zig
fn refreshAttributesMap(vm: *VM, map_obj: *JsObject, elem: *lxb.lxb_dom_element_t) void {
    // Clear stale indexed/named props from any previous refresh.
    // (Walk existing own keys; for keys that are either numeric strings
    //  <= previous length, or own properties stamped during a prior refresh,
    //  delete.) Cheapest: track last length via __nnmVer slot and a parallel
    //  __nnmLen slot OR just re-overwrite then truncate length downward.
    var idx: u32 = 0;
    var a: ?*lxb.lxb_dom_attr_t =
        @ptrCast(@alignCast(dom_b.lxb_dom_element_first_attribute_noi(elem)));
    while (a) |attr| : (idx += 1) {
        const obj = getOrCreateAttrWrapper(vm, attr) orelse break;
        // Indexed own prop
        var buf: [16]u8 = undefined;
        const idx_str = std.fmt.bufPrint(&buf, "{d}", .{idx}) catch break;
        const idx_sid = vm.pool.intern(idx_str) catch break;
        map_obj.setProperty(vm.allocator, idx_sid, JsValue.initObject(obj)) catch break;
        // Named own prop (qualified name)
        const qn = attrQualifiedName(attr) orelse {
            a = @ptrCast(@alignCast(dom_b.lxb_dom_element_next_attribute_noi(attr)));
            continue;
        };
        const qn_sid = vm.pool.intern(qn) catch break;
        map_obj.setProperty(vm.allocator, qn_sid, JsValue.initObject(obj)) catch break;
        a = @ptrCast(@alignCast(dom_b.lxb_dom_element_next_attribute_noi(attr)));
    }
    const len_sid = vm.pool.intern("length") catch return;
    map_obj.setProperty(vm.allocator, len_sid, JsValue.initNumber(@floatFromInt(idx))) catch {};

    // Record the version this snapshot reflects.
    const cur_ver = g_elem_attr_ver.get(@intFromPtr(elem)) orelse 0;
    map_obj.setProperty(vm.allocator, g_sid_nnm_ver.?, JsValue.initNumber(@floatFromInt(cur_ver))) catch {};
}
```

Use existing `attrQualifiedName` if present (grep `attrQualifiedName|qualified_name|qname` to find the helper, else build from `lxb_dom_attr_qualified_name`).

- [ ] **Step 2.2: Rewrite `buildAttributesMap`**

Replace L4236-L4273 with:

```zig
fn buildAttributesMap(vm: *VM, elem: *lxb.lxb_dom_element_t) ?JsValue {
    const map_obj = vm.createObj(.{}) catch return null;
    // §4.9.2 — NamedNodeMap prototype chain.
    if (g_namednodemap_proto) |p| map_obj.prototype = p;
    // Stash backing element for native methods (cast to usize for portability).
    map_obj.setProperty(vm.allocator, g_sid_nnm_elem.?,
        JsValue.initNumber(@floatFromInt(@intFromPtr(elem)))) catch {};
    refreshAttributesMap(vm, map_obj, elem);
    return JsValue.initObject(map_obj);
}
```

Add `nnmElem` decoder helper near the other helpers:

```zig
/// Decode the hidden `__nnmElem` slot. Returns null if the map was not built
/// by buildAttributesMap or the slot was clobbered.
fn nnmElem(this: JsValue) ?*lxb.lxb_dom_element_t {
    if (!this.isObject()) return null;
    const obj = this.asObject() orelse return null;
    const sid = g_sid_nnm_elem orelse return null;
    const v = obj.getProperty(sid) orelse return null;
    const n = v.toNumber();
    if (n == 0.0) return null;
    return @ptrFromInt(@as(usize, @intFromFloat(n)));
}
```

- [ ] **Step 2.3: Unit tests — prototype link + indexed access + named access still work**

```zig
test "el.attributes links to NamedNodeMap.prototype" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\el.setAttribute('id', 'x');
        \\Object.getPrototypeOf(el.attributes) === NamedNodeMap.prototype;
    );
    try std.testing.expect(ok.asBool());
}

test "el.attributes[0] and el.attributes['id'] still resolve" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\el.setAttribute('id', 'x');
        \\el.attributes[0].value === 'x' && el.attributes['id'].value === 'x';
    );
    try std.testing.expect(ok.asBool());
}
```

- [ ] **Step 2.4: Build + test**

```bash
cd ~/suzume && zig build test 2>&1 | tail -30
```

Expected: pass. The polyfill is still active and may shadow some paths — that's fine; the native path now has the prototype.

- [ ] **Step 2.5: Commit**

```bash
cd ~/suzume
git add src/js/kotori_dom.zig tests/test_kotori_dom.zig
git commit -m "$(cat <<'EOF'
refactor(kotori): wire buildAttributesMap to NamedNodeMap.prototype (1D Task 2)

Factor the attribute walk into refreshAttributesMap(vm, map_obj, elem)
and rewrite buildAttributesMap so every map object links to
g_namednodemap_proto and stashes the backing element pointer in the
hidden __nnmElem slot. Indexed + named own-property prewrite preserved
(spec §Liveness Option A). Methods (Tasks 5-8) will consume nnmElem
and lazy-refresh via the __nnmVer counter.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Risk callout:** Do NOT remove the indexed/named prewrite yet. Option B (pure lazy walk) needs a custom named-getter hook which kotori lacks — Task 2 stays on Option A per spec recommendation.

---

## Task 3: Add `Element.attributes` identity cache

**Files:**
- Modify: `src/js/kotori_dom.zig` — Element.attributes getter at L1206-L1210

**Purpose:** Satisfy spec §4.9.2 note "Each `attributes` getter invocation returns the *same* `NamedNodeMap`." Today `buildAttributesMap` creates a fresh object every call, so `el.attributes === el.attributes` fails.

- [ ] **Step 3.1: Rewrite the `attributes` getter**

Find at `kotori_dom.zig:1206-1210`:

```zig
if (eql(name, "attributes")) {
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.undefined_val;
    return buildAttributesMap(vm, @ptrCast(node));
}
```

Replace with:

```zig
if (eql(name, "attributes")) {
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.undefined_val;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(@alignCast(node));
    // Identity cache: same map object across calls (DOM §4.9.2).
    const cache_sid = g_sid_nnm_cache orelse return buildAttributesMap(vm, elem) orelse JsValue.null_val;
    if (obj.getProperty(cache_sid)) |cached| {
        if (cached.isObject()) {
            const map = cached.asObject().?;
            // Refresh lazily if the element's attr version moved.
            const cur = g_elem_attr_ver.get(@intFromPtr(elem)) orelse 0;
            const stamped_val = map.getProperty(g_sid_nnm_ver.?) orelse JsValue.initNumber(0);
            const stamped: u64 = @intFromFloat(stamped_val.toNumber());
            if (stamped != cur) refreshAttributesMap(vm, map, elem);
            return JsValue.initObject(map);
        }
    }
    const built = buildAttributesMap(vm, elem) orelse return JsValue.null_val;
    obj.setProperty(vm.allocator, cache_sid, built) catch {};
    return built;
}
```

- [ ] **Step 3.2: Unit test — identity invariant**

```zig
test "el.attributes === el.attributes (identity cache)" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\el.setAttribute('id', 'x');
        \\el.attributes === el.attributes;
    );
    try std.testing.expect(ok.asBool());
}
```

- [ ] **Step 3.3: Build + test**

```bash
cd ~/suzume && zig build test 2>&1 | tail -30
```

- [ ] **Step 3.4: Commit**

```bash
cd ~/suzume
git add src/js/kotori_dom.zig tests/test_kotori_dom.zig
git commit -m "$(cat <<'EOF'
feat(kotori): el.attributes identity cache via __nnmCache slot (1D Task 3)

DOM §4.9.2 requires el.attributes === el.attributes. Cache the
NamedNodeMap on the Element JsObject the first time it's requested
and reuse it on subsequent calls, refreshing lazily against the
g_elem_attr_ver counter (Task 4 wires bumps).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Risk callout:** Without Task 4's version bumps, the refresh path never fires — stale `length` after `setAttribute` is a known intermediate state. Fix lands in Task 4.

---

## Task 4: Version-bump invalidation at mutation sites

**Files:**
- Modify: `src/js/kotori_dom.zig` — `nativeSetAttribute` (L3045), `nativeSetAttributeNS` (L3073), `nativeRemoveAttribute` (L3114), `nativeToggleAttribute` (L4999)

**Purpose:** Every lexbor-level attribute mutation must bump `g_elem_attr_ver[elem]` so the identity-cached map refreshes on the next read. Close the liveness hole introduced in Task 3.

- [ ] **Step 4.1: Add `bumpElemAttrVersion` helper**

Near `invalidateAttrWrapper` (L427-L429):

```zig
/// Monotonic per-element attr-version bump. Called at every mutation site.
fn bumpElemAttrVersion(elem: *lxb.lxb_dom_element_t) void {
    const key = @intFromPtr(elem);
    const gop = g_elem_attr_ver.getOrPut(g_alloc, key) catch return;
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* +%= 1;
}
```

- [ ] **Step 4.2: Call bumps at existing mutation sites**

Add `bumpElemAttrVersion(elem);` at:
- `nativeSetAttribute` — just after `lxb_dom_element_set_attribute` (`kotori_dom.zig:3063` / `3066` area, near the existing `invalidateAttrWrapper` calls)
- `nativeSetAttributeNS` — same (L3090 / L3093)
- `nativeRemoveAttribute` — after `lxb_dom_element_remove_attribute` (L3126)
- `nativeToggleAttribute` — both add branch (L5035) and remove branch (L5044)

Verify each site currently resolves `elem: *lxb_dom_element_t`. If a site has the node-pointer but not the element-pointer, cast with `@ptrCast(@alignCast(node))` as surrounding code does.

- [ ] **Step 4.3: Unit test — liveness across identity cache**

```zig
test "el.attributes liveness: length updates after setAttribute on a cached map" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\var m = el.attributes;
        \\var before = m.length;
        \\el.setAttribute('id', 'x');
        \\var after = m.length;
        \\before === 0 && after === 1 && m['id'].value === 'x';
    );
    try std.testing.expect(ok.asBool());
}

test "el.attributes liveness: length drops after removeAttribute" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\el.setAttribute('id', 'x');
        \\var m = el.attributes;
        \\var before = m.length;
        \\el.removeAttribute('id');
        \\before === 1 && m.length === 0;
    );
    try std.testing.expect(ok.asBool());
}
```

- [ ] **Step 4.4: Build + test**

```bash
cd ~/suzume && zig build test 2>&1 | tail -30
```

- [ ] **Step 4.5: Commit**

```bash
cd ~/suzume
git add src/js/kotori_dom.zig tests/test_kotori_dom.zig
git commit -m "$(cat <<'EOF'
feat(kotori): version-bump liveness for NamedNodeMap (1D Task 4)

Add bumpElemAttrVersion(elem) called at every lexbor-level attribute
mutation: nativeSetAttribute/NS, nativeRemoveAttribute,
nativeToggleAttribute (add + remove branches). The identity-cached
NamedNodeMap (Task 3) reads this counter on each property access and
calls refreshAttributesMap when the snapshot is stale.

Closes the liveness gap from DOM §4.9.2 "The map is live."

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Risk callout:** The JS polyfill also calls the overridden `setAttribute` and does its own sidecar bookkeeping. With Tasks 3+4 landed, the native cache is consistent — but tests that still route through the polyfill's `setAttributeNode` sidecar may see divergence. This is tolerated until Task 9 deletes the polyfill.

---

## Task 5: Implement `item` + `getNamedItem` + `getNamedItemNS`

**Files:**
- Modify: `src/js/kotori_dom.zig` — add 3 natives, register on `g_namednodemap_proto`

**Purpose:** Three read-only methods that never throw. Simplest natives in the set; good warm-up before the write methods.

- [ ] **Step 5.1: Add `elementInHtmlDoc` helper**

```zig
/// DOM §4.9.1 step 1 — lowercase qualifiedName when the element is in the
/// HTML namespace AND owning document is an HTML document.
fn elementInHtmlDoc(elem: *lxb.lxb_dom_element_t) bool {
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    if (node.ns != 0x02) return false; // LXB_NS_HTML sentinel per lexbor/ns.h
    const doc = node.owner_document orelse return false;
    // lexbor stores doc type via lxb_html_document_t vs lxb_xml_document_t branch.
    // Reuse whichever helper exists — e.g. isHtmlDoc(doc) or check doc->compat_mode.
    return isHtmlDoc(doc); // verify helper name; may be named docIsHtml
}
```

Grep `grep -n "doc.*html\|html.*doc\|isHtml" src/js/kotori_dom.zig` to find the real helper; if absent, inline the branch against the lexbor doc-type field.

- [ ] **Step 5.2: Add `nativeNnmItem`**

```zig
fn nativeNnmItem(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0) return JsValue.null_val;
    const elem = nnmElem(this) orelse return JsValue.null_val;
    const want_f = args[0].toNumber();
    if (std.math.isNan(want_f) or want_f < 0) return JsValue.null_val;
    const want: u32 = @intFromFloat(want_f);
    var idx: u32 = 0;
    var a: ?*lxb.lxb_dom_attr_t =
        @ptrCast(@alignCast(dom_b.lxb_dom_element_first_attribute_noi(elem)));
    while (a) |attr| : (idx += 1) {
        if (idx == want) {
            const obj = getOrCreateAttrWrapper(vm, attr) orelse return JsValue.null_val;
            return JsValue.initObject(obj);
        }
        a = @ptrCast(@alignCast(dom_b.lxb_dom_element_next_attribute_noi(attr)));
    }
    return JsValue.null_val;
}
```

- [ ] **Step 5.3: Add `nativeNnmGetNamedItem`**

```zig
fn nativeNnmGetNamedItem(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0) return JsValue.null_val;
    const elem = nnmElem(this) orelse return JsValue.null_val;
    const qn_sid = args[0].toStringId(vm) catch return JsValue.null_val;
    var qn = vm.pool.get(qn_sid) orelse return JsValue.null_val;
    var lower_buf: [256]u8 = undefined;
    if (elementInHtmlDoc(elem) and qn.len <= lower_buf.len) {
        for (qn, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
        qn = lower_buf[0..qn.len];
    }
    const a = dom_b.lxb_dom_element_attr_by_name(elem, qn.ptr, qn.len) orelse
        return JsValue.null_val;
    const obj = getOrCreateAttrWrapper(vm, @ptrCast(@alignCast(a))) orelse return JsValue.null_val;
    return JsValue.initObject(obj);
}
```

- [ ] **Step 5.4: Add `nativeNnmGetNamedItemNS` + `lookupAttrByNsLocal` helper**

```zig
fn lookupAttrByNsLocal(elem: *lxb.lxb_dom_element_t, ns: ?[]const u8, local: []const u8) ?*lxb.lxb_dom_attr_t {
    var a: ?*lxb.lxb_dom_attr_t =
        @ptrCast(@alignCast(dom_b.lxb_dom_element_first_attribute_noi(elem)));
    while (a) |attr| {
        const attr_ns = nsIdToUri(attr.node.ns);
        const attr_local = attrLocalName(attr); // use existing helper
        const ns_match = switch (attr_ns) {
            null => ns == null,
            else => |u| ns != null and std.mem.eql(u8, u, ns.?),
        };
        if (ns_match and std.mem.eql(u8, attr_local, local)) return attr;
        a = @ptrCast(@alignCast(dom_b.lxb_dom_element_next_attribute_noi(attr)));
    }
    return null;
}

fn nativeNnmGetNamedItemNS(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len < 2) return JsValue.null_val;
    const elem = nnmElem(this) orelse return JsValue.null_val;
    // §4.9.1: if namespace is "" set it to null.
    const ns_arg = args[0];
    const ns_slice: ?[]const u8 = if (ns_arg.isNull() or ns_arg.isUndefined()) null else blk: {
        const s = vm.pool.get(ns_arg.asStringId()) orelse break :blk @as(?[]const u8, null);
        if (s.len == 0) break :blk @as(?[]const u8, null);
        break :blk s;
    };
    const local_sid = args[1].toStringId(vm) catch return JsValue.null_val;
    const local = vm.pool.get(local_sid) orelse return JsValue.null_val;
    const a = lookupAttrByNsLocal(elem, ns_slice, local) orelse return JsValue.null_val;
    const obj = getOrCreateAttrWrapper(vm, a) orelse return JsValue.null_val;
    return JsValue.initObject(obj);
}
```

- [ ] **Step 5.5: Register methods on `g_namednodemap_proto`**

Inside `initNamedNodeMapProto` (extend from Task 1), after the `constructor` setup:

```zig
try proto.setProperty(vm.allocator, try vm.pool.intern("item"),
    JsValue.initObject(try vm.createNativeFn(&nativeNnmItem)));
try proto.setProperty(vm.allocator, try vm.pool.intern("getNamedItem"),
    JsValue.initObject(try vm.createNativeFn(&nativeNnmGetNamedItem)));
try proto.setProperty(vm.allocator, try vm.pool.intern("getNamedItemNS"),
    JsValue.initObject(try vm.createNativeFn(&nativeNnmGetNamedItemNS)));
```

- [ ] **Step 5.6: Unit tests**

```zig
test "NamedNodeMap.item(0)/item(999)/item(-1)" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\el.setAttribute('id', 'x');
        \\el.attributes.item(0).value === 'x' &&
        \\el.attributes.item(999) === null &&
        \\el.attributes.item(-1) === null;
    );
    try std.testing.expect(ok.asBool());
}

test "NamedNodeMap.getNamedItem is case-insensitive in HTML doc" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\el.setAttribute('data-x', '1');
        \\el.attributes.getNamedItem('DATA-X').value === '1' &&
        \\el.attributes.getNamedItem('missing') === null;
    );
    try std.testing.expect(ok.asBool());
}

test "NamedNodeMap.getNamedItemNS empty-string ns coerces to null" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\el.setAttribute('id', 'x');
        \\el.attributes.getNamedItemNS('', 'id').value === 'x' &&
        \\el.attributes.getNamedItemNS(null, 'id').value === 'x';
    );
    try std.testing.expect(ok.asBool());
}
```

- [ ] **Step 5.7: Build + test + commit**

```bash
cd ~/suzume && zig build test 2>&1 | tail -30
git add src/js/kotori_dom.zig tests/test_kotori_dom.zig
git commit -m "$(cat <<'EOF'
feat(kotori): NamedNodeMap.item + getNamedItem[NS] (1D Task 5)

Three read-only natives per DOM §4.9.2:
- item(index): lexbor walk to the i-th attribute, null out of bounds.
- getNamedItem(qn): HTML-ns + HTML-doc lowercase dance, lookup via
  lxb_dom_element_attr_by_name.
- getNamedItemNS(ns, local): empty-string ns -> null per §4.9.1,
  manual walk (no lexbor NS-aware lookup helper).

All return cached Attr wrappers via getOrCreateAttrWrapper for identity
stability.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Risk callout:** Polyfill's `getAttributeNode` still routes through the JS sidecar. Until Task 9 deletes the polyfill, `map.getNamedItem('x') === el.getAttributeNode('x')` may fail because the two paths produce different objects. Acceptable intermediate state.

---

## Task 6: Implement `removeNamedItem` + `removeNamedItemNS`

**Files:**
- Modify: `src/js/kotori_dom.zig` — 2 natives + registration

**Purpose:** Throw `NotFoundError` on absent attrs; return the just-removed Attr wrapper on success with its `ownerElement` cleared. Bumps version via the already-wired lexbor removal path.

- [ ] **Step 6.1: Add `nativeNnmRemoveNamedItem`**

```zig
fn nativeNnmRemoveNamedItem(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0) {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    }
    const elem = nnmElem(this) orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    };
    const qn_sid = args[0].toStringId(vm) catch return JsValue.undefined_val;
    var qn = vm.pool.get(qn_sid) orelse return JsValue.undefined_val;
    var lower_buf: [256]u8 = undefined;
    if (elementInHtmlDoc(elem) and qn.len <= lower_buf.len) {
        for (qn, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
        qn = lower_buf[0..qn.len];
    }
    const lxb_attr_opaque = dom_b.lxb_dom_element_attr_by_name(elem, qn.ptr, qn.len) orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    };
    const lxb_attr: *lxb.lxb_dom_attr_t = @ptrCast(@alignCast(lxb_attr_opaque));
    const attr_obj = getOrCreateAttrWrapper(vm, lxb_attr);
    // Drop the cache entry BEFORE lexbor frees the attr struct.
    invalidateAttrWrapper(lxb_attr);
    _ = dom_b.lxb_dom_element_remove_attribute(elem, qn.ptr, qn.len);
    bumpElemAttrVersion(elem);
    if (attr_obj) |o| setAttrOwnerElement(vm, o, JsValue.null_val);
    return if (attr_obj) |o| JsValue.initObject(o) else JsValue.null_val;
}
```

- [ ] **Step 6.2: Add `nativeNnmRemoveNamedItemNS`**

```zig
fn nativeNnmRemoveNamedItemNS(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len < 2) {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    }
    const elem = nnmElem(this) orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    };
    const ns_arg = args[0];
    const ns_slice: ?[]const u8 = if (ns_arg.isNull() or ns_arg.isUndefined()) null else blk: {
        const s = vm.pool.get(ns_arg.asStringId()) orelse break :blk @as(?[]const u8, null);
        if (s.len == 0) break :blk @as(?[]const u8, null);
        break :blk s;
    };
    const local = vm.pool.get(args[1].asStringId()) orelse return JsValue.undefined_val;
    const lxb_attr = lookupAttrByNsLocal(elem, ns_slice, local) orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    };
    const attr_obj = getOrCreateAttrWrapper(vm, lxb_attr);
    // Resolve qualifiedName for lexbor removal call.
    const qn = attrQualifiedName(lxb_attr) orelse return JsValue.undefined_val;
    invalidateAttrWrapper(lxb_attr);
    _ = dom_b.lxb_dom_element_remove_attribute(elem, qn.ptr, qn.len);
    bumpElemAttrVersion(elem);
    if (attr_obj) |o| setAttrOwnerElement(vm, o, JsValue.null_val);
    return if (attr_obj) |o| JsValue.initObject(o) else JsValue.null_val;
}
```

- [ ] **Step 6.3: Register on prototype**

```zig
try proto.setProperty(vm.allocator, try vm.pool.intern("removeNamedItem"),
    JsValue.initObject(try vm.createNativeFn(&nativeNnmRemoveNamedItem)));
try proto.setProperty(vm.allocator, try vm.pool.intern("removeNamedItemNS"),
    JsValue.initObject(try vm.createNativeFn(&nativeNnmRemoveNamedItemNS)));
```

- [ ] **Step 6.4: Unit tests**

```zig
test "removeNamedItem returns the removed Attr and clears ownerElement" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\el.setAttribute('id', 'x');
        \\var a = el.attributes.removeNamedItem('id');
        \\a.value === 'x' && a.ownerElement === null && el.attributes.length === 0;
    );
    try std.testing.expect(ok.asBool());
}

test "removeNamedItem throws NotFoundError when absent" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\try { el.attributes.removeNamedItem('missing'); false; }
        \\catch (e) { e.name === 'NotFoundError'; }
    );
    try std.testing.expect(ok.asBool());
}
```

- [ ] **Step 6.5: Build + test + commit**

```bash
cd ~/suzume && zig build test 2>&1 | tail -30
git add src/js/kotori_dom.zig tests/test_kotori_dom.zig
git commit -m "$(cat <<'EOF'
feat(kotori): NamedNodeMap.removeNamedItem[NS] (1D Task 6)

Throw NotFoundError when the qualifiedName / (ns, localName) pair
resolves to null; on success, invalidate g_attr_wrappers BEFORE the
lexbor removal call (avoid stale ptr key), bump the element attr
version, and clear ownerElement on the returned Attr wrapper.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Risk callout:** Ordering matters — `invalidateAttrWrapper` MUST run before `lxb_dom_element_remove_attribute`. After removal the pointer may be freed or reassigned by lexbor; a stale hashmap entry would then alias a future Attr.

---

## Task 7: Implement `setNamedItem` + `setNamedItemNS` (HARDEST)

**Files:**
- Modify: `src/js/kotori_dom.zig` — shared native, re-key helper, owner-tracking

**Purpose:** Three coupled concerns: (a) `InUseAttributeError` when the Attr is attached to a different Element; (b) re-keying `g_attr_wrappers` so the just-set Attr JsObject aliases the new `lxb_dom_attr_t*`; (c) idempotence when the same Attr is re-set on the same Element. Spec §Method: setNamedItem lists 7 steps; preserve ordering.

- [ ] **Step 7.1: Add `setAttrOwnerElement` helper**

```zig
/// Write Attr.ownerElement (JS own property) AND the hidden __ownerElemPtr
/// slot so native methods can verify ownership cheaply.
fn setAttrOwnerElement(vm: *VM, attr_obj: *JsObject, owner: JsValue) void {
    const oe_sid = vm.pool.intern("ownerElement") catch return;
    attr_obj.setProperty(vm.allocator, oe_sid, owner) catch {};
    const ptr_sid = g_sid_owner_elem_ptr orelse return;
    if (owner.isNull() or owner.isUndefined()) {
        attr_obj.setProperty(vm.allocator, ptr_sid, JsValue.null_val) catch {};
        return;
    }
    const owner_obj = owner.asObject() orelse return;
    const node = dataOf(owner_obj) orelse return; // reuse existing .dom_node accessor
    attr_obj.setProperty(vm.allocator, ptr_sid,
        JsValue.initNumber(@floatFromInt(@intFromPtr(node)))) catch {};
}
```

- [ ] **Step 7.2: Add shared `nativeNnmSetNamedItem`**

```zig
fn nativeNnmSetNamedItem(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isObject()) {
        vm.pending_throw = try createDOMExceptionObj(vm, "TypeError");
        return JsValue.undefined_val;
    }
    const elem = nnmElem(this) orelse return JsValue.undefined_val;
    const attr_obj = args[0].asObject().?;

    // Step 1: InUseAttributeError if attr.ownerElement is a different element.
    const ptr_sid = g_sid_owner_elem_ptr.?;
    if (attr_obj.getProperty(ptr_sid)) |stashed| {
        if (!stashed.isNull() and !stashed.isUndefined()) {
            const ptr_f = stashed.toNumber();
            if (ptr_f != 0.0) {
                const owner_ptr: usize = @intFromFloat(ptr_f);
                if (owner_ptr != @intFromPtr(@as(*lxb.lxb_dom_node_t, @ptrCast(elem)))) {
                    vm.pending_throw = try createDOMExceptionObj(vm, "InUseAttributeError");
                    return JsValue.undefined_val;
                }
            }
        }
    }

    // Extract Attr metadata. Attr objects already carry these props from
    // createAttribute/createAttributeNS (kotori_dom.zig:2280).
    const ns_v = attr_obj.getProperty(try vm.pool.intern("namespaceURI")) orelse JsValue.null_val;
    const ns_slice: ?[]const u8 = if (ns_v.isNull() or ns_v.isUndefined()) null else blk: {
        const s = vm.pool.get(ns_v.asStringId()) orelse break :blk @as(?[]const u8, null);
        if (s.len == 0) break :blk @as(?[]const u8, null);
        break :blk s;
    };
    const local_v = attr_obj.getProperty(try vm.pool.intern("localName")) orelse return JsValue.undefined_val;
    const local = vm.pool.get(local_v.asStringId()) orelse return JsValue.undefined_val;
    const prefix_v = attr_obj.getProperty(try vm.pool.intern("prefix")) orelse JsValue.null_val;
    const prefix_opt: ?[]const u8 = if (prefix_v.isNull() or prefix_v.isUndefined()) null else
        vm.pool.get(prefix_v.asStringId());
    const value_v = attr_obj.getProperty(try vm.pool.intern("value")) orelse
        try JsValue.fromStr(vm, "");
    const value = vm.pool.get(value_v.asStringId()) orelse "";

    // Step 2: look up old attr at (ns, local).
    const old_lxb = lookupAttrByNsLocal(elem, ns_slice, local);
    const old_obj: ?*JsObject = if (old_lxb) |a| getOrCreateAttrWrapper(vm, a) else null;

    // Step 3: idempotence — same attr object already on this element.
    if (old_obj != null and old_obj.? == attr_obj) {
        return JsValue.initObject(attr_obj);
    }

    // Compose qualified name for lexbor (it treats NS-aware attrs by qname).
    var qn_buf: [512]u8 = undefined;
    const qn: []const u8 = if (prefix_opt) |p| blk: {
        const n = p.len + 1 + local.len;
        if (n > qn_buf.len) return JsValue.undefined_val;
        @memcpy(qn_buf[0..p.len], p);
        qn_buf[p.len] = ':';
        @memcpy(qn_buf[p.len + 1 ..][0..local.len], local);
        break :blk qn_buf[0..n];
    } else local;

    // Step 4/5: write via lexbor.
    _ = dom_b.lxb_dom_element_set_attribute(elem, qn.ptr, qn.len, value.ptr, value.len);
    bumpElemAttrVersion(elem);

    // Re-resolve the just-written lexbor attr and alias attr_obj as its wrapper.
    const new_lxb_opaque = dom_b.lxb_dom_element_attr_by_name(elem, qn.ptr, qn.len)
        orelse return JsValue.null_val;
    const new_lxb: *lxb.lxb_dom_attr_t = @ptrCast(@alignCast(new_lxb_opaque));
    // Drop any prior cache entry (old_lxb key is now stale AFTER set_attribute
    // in the replace case) and re-key to the new ptr -> attr_obj.
    if (old_lxb) |ol| invalidateAttrWrapper(ol);
    g_attr_wrappers.put(vm.allocator, @intFromPtr(new_lxb), attr_obj) catch {};

    // Step 6: set attr's element.
    const owner_node = lxbElemToJsNode(vm, elem);
    setAttrOwnerElement(vm, attr_obj, owner_node);
    // Old attr wrapper (if distinct) loses its owner.
    if (old_obj) |oa| if (oa != attr_obj) setAttrOwnerElement(vm, oa, JsValue.null_val);

    // Step 7: return old or null.
    return if (old_obj) |oa| JsValue.initObject(oa) else JsValue.null_val;
}
```

`lxbElemToJsNode(vm, elem)` wraps via `wrapNode(vm, @ptrCast(elem))`. Verify the exact helper name in-repo.

- [ ] **Step 7.3: Register as both `setNamedItem` and `setNamedItemNS`**

Per spec §WebIDL legacy: same native, both names.

```zig
const set_fn = try vm.createNativeFn(&nativeNnmSetNamedItem);
try proto.setProperty(vm.allocator, try vm.pool.intern("setNamedItem"),
    JsValue.initObject(set_fn));
try proto.setProperty(vm.allocator, try vm.pool.intern("setNamedItemNS"),
    JsValue.initObject(set_fn));
```

- [ ] **Step 7.4: Unit tests — all three spec behaviors**

```zig
test "setNamedItem returns null when appending new attr" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\var a = document.createAttribute('id'); a.value = 'x';
        \\var prev = el.attributes.setNamedItem(a);
        \\prev === null && el.attributes.getNamedItem('id').value === 'x';
    );
    try std.testing.expect(ok.asBool());
}

test "setNamedItem returns old Attr when replacing" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\el.setAttribute('id', 'old');
        \\var oldNode = el.attributes.getNamedItem('id');
        \\var a = document.createAttribute('id'); a.value = 'new';
        \\var ret = el.attributes.setNamedItem(a);
        \\ret === oldNode && oldNode.ownerElement === null &&
        \\el.attributes.getNamedItem('id').value === 'new';
    );
    try std.testing.expect(ok.asBool());
}

test "setNamedItem throws InUseAttributeError for Attr of another Element" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var a = document.createElement('div');
        \\var b = document.createElement('div');
        \\a.setAttribute('id', 'x');
        \\var aAttr = a.attributes.getNamedItem('id');
        \\try { b.attributes.setNamedItem(aAttr); false; }
        \\catch (e) { e.name === 'InUseAttributeError'; }
    );
    try std.testing.expect(ok.asBool());
}

test "setNamedItem is idempotent on the same element" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\el.setAttribute('id', 'x');
        \\var a = el.attributes.getNamedItem('id');
        \\el.attributes.setNamedItem(a) === a;
    );
    try std.testing.expect(ok.asBool());
}
```

- [ ] **Step 7.5: Build + test + commit**

```bash
cd ~/suzume && zig build test 2>&1 | tail -30
git add src/js/kotori_dom.zig tests/test_kotori_dom.zig
git commit -m "$(cat <<'EOF'
feat(kotori): NamedNodeMap.setNamedItem[NS] with InUseAttributeError + re-key (1D Task 7)

Implement DOM §4.9.2 7-step algorithm: ownership check via
__ownerElemPtr slot, lookup by (ns, localName), idempotence guard,
lexbor set_attribute, g_attr_wrappers re-key (drop old ptr, put new
ptr -> attr_obj), setAttrOwnerElement on the incoming Attr, clear
ownerElement on the displaced Attr, version bump, return old or null.

setNamedItem and setNamedItemNS share the native per WebIDL legacy
interface rule.

Spec: docs/superpowers/specs/2026-04-19-kotori-1D-namednodemap-methods-design.md
  §Method: setNamedItem, §R2 (wrapper identity across element boundaries)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Risk callouts:**
- **R2 (wrapper identity)**: If `g_attr_wrappers.put(new_ptr, attr_obj)` is forgotten, subsequent `el.attributes.getNamedItem('id')` returns a *different* JsObject than the one just set — every spec test comparing `setNamedItem(a) === oldNode` breaks.
- **Lexbor NS-aware set**: The lexbor `set_attribute` signature takes only `(elem, name, name_len, value, value_len)` — it cannot set namespace metadata. For the NS case, rely on the prior `createAttributeNS` side-effects OR mirror the pattern already used by `nativeSetAttributeNS` at L3073-L3112 (grep that code for how it stashes ns).
- **Pending throw ordering**: If the InUseAttributeError is not set **before** returning undefined, the VM's caller treats the return as a valid value. Verify the kotori convention (`vm.pending_throw` pattern) matches surrounding code.

---

## Task 8: Implement `[Symbol.iterator]`

**Files:**
- Modify: `src/js/kotori_dom.zig` — 2 natives + symbol_props registration

**Purpose:** `for (let a of el.attributes)` and `[...el.attributes]` both invoke `@@iterator`. The VM pattern at `vm.zig:2385-2388` shows exactly how: register a native under `SYMBOL_ITERATOR` in `proto.symbol_props`. **No VM changes required** (verified in Task 0.4).

- [ ] **Step 8.1: Add iterator-result helpers (reuse if present)**

Grep first: `grep -n "iterResultDone\|iterResultValue\|IteratorResult" src/js/kotori_dom.zig src/js/kotori/vm.zig`. If they exist, skip; else:

```zig
fn iterResultDone(vm: *VM) !JsValue {
    const r = try vm.createObj(.{});
    try r.setProperty(vm.allocator, try vm.pool.intern("value"), JsValue.undefined_val);
    try r.setProperty(vm.allocator, try vm.pool.intern("done"), JsValue.initBool(true));
    return JsValue.initObject(r);
}

fn iterResultValue(vm: *VM, val: JsValue) !JsValue {
    const r = try vm.createObj(.{});
    try r.setProperty(vm.allocator, try vm.pool.intern("value"), val);
    try r.setProperty(vm.allocator, try vm.pool.intern("done"), JsValue.initBool(false));
    return JsValue.initObject(r);
}
```

- [ ] **Step 8.2: Add iterator natives**

```zig
fn nativeNnmSymbolIterator(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const iter = try vm.createObj(.{ .obj_type = .iterator });
    iter.data = .{ .iterator_data = .{ .source = this } };
    try vm.registerNativeMethod(iter, "next", &nativeNnmIteratorNext);
    try iter.setProperty(vm.allocator, try vm.pool.intern("__i"),
        JsValue.initNumber(0));
    return JsValue.initObject(iter);
}

fn nativeNnmIteratorNext(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const iter = this.asObject() orelse return iterResultDone(vm);
    const src = iter.data.iterator_data.source;
    const elem = nnmElem(src) orelse return iterResultDone(vm);
    const i_sid = try vm.pool.intern("__i");
    const i_val = iter.getProperty(i_sid) orelse JsValue.initNumber(0);
    const i: u32 = @intFromFloat(i_val.toNumber());
    var j: u32 = 0;
    var a: ?*lxb.lxb_dom_attr_t =
        @ptrCast(@alignCast(dom_b.lxb_dom_element_first_attribute_noi(elem)));
    while (a) |attr| : (j += 1) {
        if (j == i) {
            const obj = getOrCreateAttrWrapper(vm, attr) orelse return iterResultDone(vm);
            try iter.setProperty(vm.allocator, i_sid,
                JsValue.initNumber(@floatFromInt(i + 1)));
            return iterResultValue(vm, JsValue.initObject(obj));
        }
        a = @ptrCast(@alignCast(dom_b.lxb_dom_element_next_attribute_noi(attr)));
    }
    return iterResultDone(vm);
}
```

- [ ] **Step 8.3: Register on prototype via `symbol_props`**

Extend `initNamedNodeMapProto`:

```zig
if (proto.symbol_props == null) proto.symbol_props = .{};
const iter_fn = try vm.createNativeFn(&nativeNnmSymbolIterator);
try proto.symbol_props.?.put(vm.allocator, SYMBOL_ITERATOR,
    JsValue.initObject(iter_fn));
```

If `SYMBOL_ITERATOR` is not `pub` from vm.zig, either add `pub` (one-line change outside the spec's "no VM changes" line — but non-semantic) or add a getter `vm.symbolIterator()`. Prefer the getter to keep the vm.zig diff to zero **visible** API change.

- [ ] **Step 8.4: Unit tests**

```zig
test "for..of el.attributes yields Attr nodes in index order" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\el.setAttribute('a', '1');
        \\el.setAttribute('b', '2');
        \\var names = [];
        \\for (var a of el.attributes) names.push(a.name);
        \\names.length === 2 && names[0] === 'a' && names[1] === 'b';
    );
    try std.testing.expect(ok.asBool());
}

test "[...el.attributes] has correct length" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\el.setAttribute('a', '1'); el.setAttribute('b', '2'); el.setAttribute('c', '3');
        \\[...el.attributes].length === 3;
    );
    try std.testing.expect(ok.asBool());
}

test "el.attributes[Symbol.iterator] is callable" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\typeof el.attributes[Symbol.iterator] === 'function';
    );
    try std.testing.expect(ok.asBool());
}
```

- [ ] **Step 8.5: Build + test + commit**

```bash
cd ~/suzume && zig build test 2>&1 | tail -30
git add src/js/kotori_dom.zig tests/test_kotori_dom.zig
git commit -m "$(cat <<'EOF'
feat(kotori): NamedNodeMap [Symbol.iterator] (1D Task 8)

Register native @@iterator on g_namednodemap_proto.symbol_props,
reusing the array-iterator pattern at vm.zig:2385-2388 and the
.iterator obj_type infrastructure (get_iterator opcode at
vm.zig:1863-1874). No VM changes required.

next() walks lexbor from head each call for spec-correct liveness.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Risk callout (spec §R4):** Native walk per `next()` gives live-mutation reflection, but inserting a new attribute at index 0 mid-iteration can show the same element twice — spec is ambiguous and browser behavior matches our implementation.

---

## Task 9: Delete the JS polyfill (MUST BE LAST CODE TASK)

**Files:**
- Modify: `src/js/kotori_runtime.zig` — delete L1491-L1823 + the call site at L92

**Purpose:** Retire the 333-line `attributes_polyfill_js` block now that native code covers all of its functionality. Per spec §R1 this is **the single largest source of confusion** in the current codebase — two parallel Attr representations that are not `===`. After this task, the native `g_attr_wrappers` path is the only truth.

**Prerequisite gate:** Tasks 1-8 must be committed and `zig build test` must be green on HEAD. If any earlier task is unfinished or has skipped tests, DO NOT proceed.

- [ ] **Step 9.1: Re-confirm baseline**

```bash
cd ~/suzume
zig build test 2>&1 | tail -10
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
  dom/nodes/attributes.html \
  dom/nodes/NamedNodeMap-supported-property-names.html \
  dom/nodes/Element-hasAttributes.html 2>&1 | tee /tmp/wpt-1D-pre-delete.txt
```

Record the pre-delete subtest counts. Compare to `/tmp/wpt-1D-baseline.txt` from Task 0; counts should be equal or higher (never lower).

- [ ] **Step 9.2: Delete the `self.eval(attributes_polyfill_js)` call at L92**

```bash
sed -n '90,94p' src/js/kotori_runtime.zig
```

Expected around L92:
```zig
    _ = self.eval(attributes_polyfill_js);
```

Delete that line.

- [ ] **Step 9.3: Delete the polyfill block at L1491-L1823**

Verify exact bounds:
```bash
grep -n "^    const attributes_polyfill_js =\|^    ;$" src/js/kotori_runtime.zig | head -10
```

Locate the opening `const attributes_polyfill_js =` (L1491) and its closing `;` (near L1823 — a standalone `    ;` terminating the multiline string literal). Delete the entire range including any preceding `///` doc comments that describe the polyfill (lines L1476-L1490 in the spec reference).

Use `Edit` with a unique surrounding anchor, not a line-range delete, to avoid drift:
```zig
// old_string starts with the doc comment block immediately above the polyfill
// and ends with the terminating `;` + blank line before the next function.
```

- [ ] **Step 9.4: Build + test**

```bash
cd ~/suzume && zig build test 2>&1 | tail -30
```

Expected: **all unit tests still pass** because Tasks 1-8 cover every contract the polyfill provided for `Element.attributes` / `setNamedItem` / `removeNamedItem` / iterator. If any test fails, do NOT revert — diagnose: either (a) a spec gap not covered by 1D (escalate to roadmap; likely a Layer 1A QName-validation bleed), or (b) a helper signature the polyfill was papering over. Fix inline in this task.

- [ ] **Step 9.5: WPT delta measurement**

```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
  dom/nodes/attributes.html \
  dom/nodes/NamedNodeMap-supported-property-names.html \
  dom/nodes/Element-hasAttributes.html \
  dom/nodes/Element-getAttributeNode.html \
  dom/nodes/Element-setAttributeNode.html \
  dom/nodes/Element-removeAttributeNode.html 2>&1 | tee /tmp/wpt-1D-post-delete.txt
```

Compare vs `/tmp/wpt-1D-pre-delete.txt` — counts must be equal or higher. The extra three files (getAttributeNode / setAttributeNode / removeAttributeNode) are the polyfill's former turf; per spec §R1.3 the native `setNamedItem` pipeline should now satisfy them via the one-liner `setAttributeNode(attr) := this.attributes.setNamedItem(attr)` shape.

- [ ] **Step 9.6: Regression sweep — importNode + clone**

The polyfill touched `Document.prototype.importNode` and some clone semantics. Run:

```bash
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
  dom/nodes/Document-importNode.html \
  dom/nodes/Node-cloneNode-AElement.html \
  dom/nodes/attributes 2>&1 | tee /tmp/wpt-1D-regression.txt
```

Expected: no regression worse than -2 subtests vs baseline from `/tmp/wpt-1D-baseline.txt`.

- [ ] **Step 9.7: Commit**

```bash
cd ~/suzume
git add src/js/kotori_runtime.zig
git commit -m "$(cat <<'EOF'
refactor(kotori): retire attributes_polyfill_js (Layer 1D Task 9)

Remove the 333-line JS sidecar polyfill at kotori_runtime.zig:1491-1823
(installed in commit 453bfc6) and its eval() call site at L92. The
polyfill's lexbor iteration workaround was obsoleted by eff3c7b and
its API surface is now fully native:

- Element.prototype.setAttribute / getAttribute / removeAttribute /
  hasAttribute / toggleAttribute — always were native, polyfill was
  shadow-overriding them.
- setAttributeNode / getAttributeNode / removeAttributeNode — now
  rewritten on top of the native NamedNodeMap methods from Tasks 5-8.
- Attr ownerElement tracking — Task 10 (and setAttrOwnerElement
  helper from Task 7) now own this end-to-end.

QName validation pieces (validateAndExtract / validateName) are
Layer 1A's responsibility per the parent roadmap and are out of
scope for 1D.

WPT delta attached at /tmp/wpt-1D-post-delete.txt.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Risk callouts (highest-risk task in the plan):**
- **Ordering**: If this task lands before Tasks 1-8 complete, WPT regresses immediately because the native path is incomplete. The plan orders this **last among code tasks** precisely for this reason.
- **Setting/getAttributeNode**: These three polyfill methods (`setAttributeNode`/`getAttributeNode`/`removeAttributeNode`) are **not** individually covered by Tasks 1-8. If the existing `Element.prototype.setAttributeNode` has no native fallback, Step 9.4 will surface it — the in-task fix is to add three small native shims that forward to the NamedNodeMap methods (`setAttributeNode(a) := this.attributes.setNamedItem(a)`). If they already exist natively (grep `nativeSetAttributeNode`), no action.
- **importNode cross-contamination**: The polyfill included an `importNode` extension for Attr nodes. If Layer 1A has not yet shipped, removing this may regress `Document-importNode.html` — Step 9.6 measures. Acceptable regression threshold per spec §R1.4: none in `dom/nodes/Element-*`, `dom/nodes/Attr-*`, `html/dom/reflection-*`. If breached, defer the polyfill delete to a follow-up and keep Tasks 1-8 shipped.

---

## Task 10: `Attr.ownerElement` tracking end-to-end

**Files:**
- Modify: `src/js/kotori_dom.zig` — `getOrCreateAttrWrapper` (L4188), `nativeRemoveAttribute` (L3114), `nativeToggleAttribute` (L4999 removal branch)

**Purpose:** Close the gap identified in Task 0.6: `getOrCreateAttrWrapper` does not currently set `ownerElement`, so Attr wrappers created via `el.attributes[0]` have no `ownerElement` and the `InUseAttributeError` check in Task 7 silently returns null. This task wires `setAttrOwnerElement` at every Attr-creation / detachment site.

**Note:** Per spec §ownerElement maintenance plan, this task's substance is mostly done inside Tasks 5-7 (setAttrOwnerElement helper exists from Task 7 Step 7.1). This task is the **audit + gap-fill** pass.

- [ ] **Step 10.1: Patch `getOrCreateAttrWrapper` at L4188**

Locate the function body between L4188-L4229. After the wrapper is built and before the `g_attr_wrappers.put` call, insert:

```zig
// DOM §4.9 Attr.ownerElement is set to the containing element for
// attrs that are part of an element's attribute list.
const owner_node: ?*lxb.lxb_dom_node_t = a.node.owner; // lexbor field
if (owner_node) |on| {
    const owner_js = wrapNode(vm, on) orelse null;
    if (owner_js) |oj| setAttrOwnerElement(vm, attr_obj, JsValue.initObject(oj));
} else {
    setAttrOwnerElement(vm, attr_obj, JsValue.null_val);
}
```

Verify the exact name of the lexbor `owner` field on `lxb_dom_attr_t` — `grep "owner" include/lexbor/dom/interfaces/attr.h` within the lexbor headers (likely `node.owner` pointing to the element node).

- [ ] **Step 10.2: Patch `nativeRemoveAttribute` at L3114 (removal side)**

Inside the function, just before `lxb_dom_element_remove_attribute` and `invalidateAttrWrapper`:

```zig
if (g_attr_wrappers.get(@intFromPtr(lxb_attr))) |cached_wrap| {
    setAttrOwnerElement(vm, cached_wrap, JsValue.null_val);
}
```

- [ ] **Step 10.3: Patch `nativeToggleAttribute` remove branch at L4999**

Same pattern as Step 10.2 inside the remove branch (when `force === false` or the attr exists and force is unset).

- [ ] **Step 10.4: Unit tests**

```zig
test "Attr wrapper from el.attributes[0] has correct ownerElement" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\el.setAttribute('id', 'x');
        \\el.attributes[0].ownerElement === el;
    );
    try std.testing.expect(ok.asBool());
}

test "Attr.ownerElement becomes null after removeAttribute" {
    var vm = try testVm();
    defer vm.deinit();
    const ok = try runJs(&vm,
        \\var el = document.createElement('div');
        \\el.setAttribute('id', 'x');
        \\var a = el.attributes[0];
        \\el.removeAttribute('id');
        \\a.ownerElement === null;
    );
    try std.testing.expect(ok.asBool());
}
```

- [ ] **Step 10.5: Build + test + commit**

```bash
cd ~/suzume && zig build test 2>&1 | tail -30
git add src/js/kotori_dom.zig tests/test_kotori_dom.zig
git commit -m "$(cat <<'EOF'
feat(kotori): Attr.ownerElement end-to-end tracking (1D Task 10)

Wire setAttrOwnerElement from Task 7 into every Attr creation and
detachment site:
- getOrCreateAttrWrapper (L4188): set ownerElement from a.node.owner
- nativeRemoveAttribute (L3114): clear ownerElement before removal
- nativeToggleAttribute (L4999, remove branch): same

Fixes the gap where el.attributes[0].ownerElement returned undefined
and where setNamedItem's InUseAttributeError check (Task 7) silently
returned null because ownerElement was unset.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Risk callout:** If Task 9 (polyfill delete) already landed, this task is no longer strictly required for unit tests to pass — but it IS required for the Task 11 WPT gate. Land it regardless.

---

## Task 11: WPT verification + final gate sign-off

**Files:** None modified. Produces verification evidence.

**Purpose:** Run target + regression WPT files with 3-run stability; record deltas; dispatch verifier agent (different context per OMC no-self-approval rule) to sign off against spec §Acceptance criteria.

- [ ] **Step 11.1: Gate A — primary targets (3 runs)**

```bash
cd ~/suzume
for run in 1 2 3; do
  TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
    dom/nodes/attributes.html \
    dom/nodes/NamedNodeMap-supported-property-names.html \
    dom/nodes/Element-hasAttributes.html 2>&1 | tee /tmp/wpt-1D-gate-a-run$run.txt
done
```

Verify counts are identical across 3 runs (flake check). Targets from spec:
- `attributes.html`: **+18 to +32 subtests** vs baseline from `/tmp/wpt-1D-baseline.txt` (67 total)
- `NamedNodeMap-supported-property-names.html`: **≥50% pass**
- `Element-hasAttributes.html`: no regression (relies on `map.length` liveness)

- [ ] **Step 11.2: Gate B — Element/Attr neighborhood regression**

```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
  dom/nodes/Element-getAttributeNode.html \
  dom/nodes/Element-setAttributeNode.html \
  dom/nodes/Element-removeAttributeNode.html \
  dom/nodes/attributes.html \
  dom/nodes/Document-importNode.html 2>&1 | tee /tmp/wpt-1D-gate-b.txt
```

Verify: no regression worse than -2 subtests total vs baseline.

- [ ] **Step 11.3: Gate C — dom/nodes full regression**

```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/nodes 2>&1 | tee /tmp/wpt-1D-gate-c.txt
```

Verify: no net regression vs pre-1D baseline.

- [ ] **Step 11.4: Dispatch verifier agent (separate context)**

Per OMC rule (no self-approval), dispatch a verifier subagent with:
- Spec path: `docs/superpowers/specs/2026-04-19-kotori-1D-namednodemap-methods-design.md`
- Gate outputs: `/tmp/wpt-1D-gate-{a-run1,a-run2,a-run3,b,c}.txt`
- Success criteria: spec §Acceptance criteria (13 checkboxes)

Ask for APPROVED / REJECTED with per-criterion citation.

- [ ] **Step 11.5: Record WPT progress in memory**

If APPROVED, append a session entry to `memory/project_suzume_wpt_progress.md` via the memory helper. Record the new subtest counts for the three target files.

- [ ] **Step 11.6: Mark plan complete**

No commit needed — documentation stays in-repo.

---

## Completion Checklist

Before declaring this plan DONE:

- [ ] All 10 implementation commits landed (Tasks 1-10)
- [ ] `zig build test` green at HEAD
- [ ] `globalThis.NamedNodeMap.prototype === el.attributes.__proto__`
- [ ] `el.attributes === el.attributes` (identity cache)
- [ ] All 8 methods callable: `item`, `getNamedItem`, `getNamedItemNS`, `setNamedItem`, `setNamedItemNS`, `removeNamedItem`, `removeNamedItemNS`, `[Symbol.iterator]`
- [ ] `setNamedItem` with another element's Attr throws `InUseAttributeError`
- [ ] `removeNamedItem`/`removeNamedItemNS` for absent attr throws `NotFoundError`
- [ ] Liveness: `setAttribute` after map read reflects on next read (length + item + getNamedItem)
- [ ] `for..of el.attributes` yields Attr objects in index order; `[...el.attributes].length === el.attributes.length`
- [ ] `kotori_runtime.zig` polyfill fully removed (spec §Acceptance criteria bullet 11)
- [ ] Gate A: attributes.html **+18 to +32 subtests**; NamedNodeMap-supported-property-names.html **≥50%**
- [ ] Gate B: no regression worse than -2 in dom/nodes/Element-*Attribute*.html
- [ ] Gate C: no net regression in full dom/nodes
- [ ] Verifier agent APPROVED in separate context
- [ ] Memory updated with new WPT numbers

---

## Notes for the Executor

- **Spec is the contract.** When plan and spec differ, the spec wins: `docs/superpowers/specs/2026-04-19-kotori-1D-namednodemap-methods-design.md`.
- **Do not skip Task 0.** Line numbers in this plan (3045, 3114, 4188, 4236, 4999, 1491-1823, 423, 477) come from the spec's reading of HEAD `beb7a4b`. If HEAD has advanced, Task 0 audits catch drift before wasted code.
- **Commit order is load-bearing.** Tasks 1→2→3→4 install the substrate; Tasks 5→6→7→8 install methods; Task 9 (polyfill delete) MUST be last among code tasks; Task 10 is a gap-fill that may move earlier only if helpers collide. If you bisect, bisect across Tasks 1+2 as a co-dependent pair.
- **Task 7 is the highest-complexity task.** Budget extra time; the InUseAttributeError + re-key + idempotence interlock is the single largest correctness risk in the plan.
- **Polyfill delete (Task 9) is the highest-risk task.** Do not proceed without green `zig build test` on every prior task. If Task 9 Step 9.4 fails, diagnose in-place — do NOT revert the polyfill deletion without understanding which Attr-Node shim is missing.
- **No VM changes.** If any task suggests editing `src/js/kotori/vm.zig`, stop — the spec's §Iterator verification at `vm.zig:2385-2388` proves this is not needed. Escalate instead.
- **WPT 100% for NamedNodeMap-supported-property-names.html is NOT a target.** ≥50% is the spec's gate; `LegacyUnenumerableNamedProperties` semantics may require named-getter hooks that are out of 1D scope.
