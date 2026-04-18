# kotori HTML/SVG/MathML Interface Dispatch + Native DOM Fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement spec-compliant `createElement`/`createElementNS` interface dispatch (HTML ~100 + SVG ~20 + MathML fallback), per-node `ownerDocument` slot, and live `NamedNodeMap` with Attr identity, unlocking ~684 WPT dom/nodes subtests.

**Architecture:** Add `_ownerDoc` internal slot on every Node JsObject; remove JS-level `wrapDocCreators`/`stampOwnerDocument`/`importNode` polyfill that currently masks the native getter; build `HTMLElement`/`SVGElement`/`MathMLElement` prototype hierarchies before the bootstrap document wrap; introduce new `kotori_html_interfaces.zig` resolver module; wire `applyInterfaceProto` into all four Node wrapper sites (`wrapNode`, `createJsOnlyElement`, `wrapShadowRoot`, `nativeCloneNode`).

**Tech Stack:** Zig 0.15.2, lexbor (HTML/XML parser), kotori JS engine (in-tree at `src/js/kotori/`), WPT (Web Platform Tests).

**Spec:** `docs/superpowers/specs/2026-04-18-kotori-html-interface-dispatch-design.md`
**Parent roadmap:** `docs/superpowers/specs/2026-04-17-kotori-suzume-wpt-100-roadmap.md` (Layer 1 sub-project)

---

## File Structure

### Files to create
- `src/js/kotori_html_interfaces.zig` — new module. Exports `HTML_NS`, `SVG_NS`, `MATH_NS` constants; `resolveInterface(namespace, local_name) []const u8`; internal comptime StaticStringMaps for HTML and SVG tag→interface lookup. Single responsibility, no dependencies on VM types beyond `std`.
- `tests/test_kotori_html_interfaces.zig` — unit tests for the resolver.

### Files to modify
- `src/js/kotori_dom.zig` — bulk of the work. ~6,000-line file. Touches spread across:
  - L584 bootstrap doc wrap — add `_ownerDoc` slot write
  - L727-L774 HTML ctor globals — fix shared-proto bug, wire per-interface prototypes
  - L1115-L1122 ownerDocument getter — rewrite to read `_ownerDoc` slot
  - L1742 `createJsOnlyElement` — add `owner_doc: JsValue` parameter
  - L2014-L2062 Attr builder — write slot via helper
  - L2439 DocumentType init — write slot via helper
  - L3383 `wrapShadowRoot` — write slot via helper + proto dispatch
  - L3424 `nativeDocumentConstructor` — write slot via helper
  - L3801 `wrapNode` — owner resolution via `node->owner_document` + proto dispatch
  - L3847-L3892 `buildAttributesMap` — L3887 one-line fix + Attr wrapper cache
  - L4305-ish `nativeCloneNode` — P0 verifies exact line; proto dispatch + slot
  - L4901 `createHTMLDocument` — write slot
  - L5200/L5247/L5326 impl.create* — migrate property→slot
  - New helper functions near top: `setNodeOwnerDoc`, `getNodeOwnerDoc`, `applyInterfaceProto`, `g_html_protos`/`g_svg_protos` HashMap declarations
  - `nativeImportNode` — rewrite for recursive clone with target doc
  - setAttribute/removeAttribute natives — Attr cache invalidation hooks

- `src/js/kotori_runtime.zig` — delete lines:
  - L1425-L1440 `stampOwnerDocument`
  - L1441-L1474 `wrapDocCreators`
  - L1477-L1495 impl wrapper block
  - L1499 `wrapDocCreators(document)` call
  - L1500-L1521 `importNode` polyfill + `Document.prototype.importNode` assignment + `document.importNode.bind`
  - Any `stampOwnerDocument`/`wrapDocCreators` callers elsewhere (grep audit in P0)

- `tests/test_kotori_dom.zig` — extend with ≥ 21 new tests covering dispatch, ownerDoc, attributes liveness, cross-doc scenarios.

### Files to NOT modify
- `src/js/kotori/vm.zig` — no VM changes needed (freeze API already exists at object.zig:429)
- `src/js/kotori/object.zig` — uses existing freeze API
- `src/js/dom_api.zig`, `dom_element.zig`, `dom_document.zig` — not touched (QuickJS bindings, parallel world)

---

## Task 0: P0 Audit — No-Code Gate

**Files:** None modified; produces a notes file for reference during subsequent tasks.

**Purpose:** Verify spec assumptions against current HEAD. Produces a concrete list of wrapper sites, an owner-document fixture result, and baseline WPT numbers before any code changes.

- [ ] **Step 0.1: Enumerate all `dom_node` wrapper sites**

Run:
```bash
cd ~/suzume
grep -n "createObj(\.{ \.obj_type = \.dom_node" src/js/kotori_dom.zig
```

Expected output: 5-10 lines, each a file:line. Compare against the spec §3.1 table (L584, L1742, L2014, L2439, L3383, L3424, L3801, L4305, L4901, L5200, L5247, L5326). Note any new lines not in the spec table. If found, add a row to the local notes before proceeding.

- [ ] **Step 0.2: Enumerate all `createJsOnlyElement` callers**

Run:
```bash
grep -n "createJsOnlyElement" src/js/kotori_dom.zig
```

Expected: the definition plus 2-4 callers. Each caller must pass a valid `owner_doc: JsValue` after Task 1. Record them.

- [ ] **Step 0.3: Confirm `wrapDocCreators`/`stampOwnerDocument` are only in one block**

Run:
```bash
grep -n "wrapDocCreators\|stampOwnerDocument" src/js/kotori_runtime.zig src/js/kotori_dom.zig
```

Expected: all matches between `kotori_runtime.zig:1425-1521`. If matches exist elsewhere, delete list in Task 2 must expand.

- [ ] **Step 0.4: Verify `nativeCloneNode` line number**

Run:
```bash
grep -n "fn nativeCloneNode\b" src/js/kotori_dom.zig
```

Expected: one match near L4305. Record the exact line number. Same for `nativeImportNode`:
```bash
grep -n "fn nativeImportNode\b" src/js/kotori_dom.zig
```

- [ ] **Step 0.5: Write lexbor `owner_document` fixture test**

Create a minimal probe (in a scratch test file or via the existing test harness) that calls `lxb_dom_document_create_element_noi` without `appendChild`, then reads `node->owner_document`. Verify it points to the creating document. If this fails, the `wrapNode` owner-resolution strategy must change (require explicit `owner_doc` param on every call).

The existing code at `src/js/dom_node.zig:2332` already reads `cur.owner_document` unconditionally, giving strong prior evidence that the field is populated. This fixture confirms it for the detached case.

- [ ] **Step 0.6: Record WPT baselines**

Run:
```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
  dom/nodes/Document-createElement.html \
  dom/nodes/Document-createElementNS.html \
  dom/nodes/attributes.html \
  dom/nodes/importNode.html 2>&1 | tee /tmp/wpt-baseline-p0.txt
```

Record pass/fail counts for each file. Also record full dom/nodes:
```bash
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/nodes 2>&1 | tee /tmp/wpt-domnodes-baseline.txt
```

These numbers become the reference for Gate A/B in Task 9.

- [ ] **Step 0.7: Commit audit notes (no code)**

Write findings into `/tmp/p0-audit-notes.md` for reference; no repo commit at this phase. P0 is a "no-code gate"; subsequent tasks use these notes to pass the right line numbers and baselines.

---

## Task 1: `_ownerDoc` Slot + Getter Rewrite + Wrapper Migration

**Files:**
- Modify: `src/js/kotori_dom.zig` — add helpers, rewrite getter, migrate 10 wrapper sites

**Purpose:** Install per-Node `_ownerDoc` slot, replace the globalThis.document fallback getter, and migrate every enumerated wrapper site to write the slot through a single helper. After this task, the native ownerDocument semantics are spec-correct — but the JS polyfill from `kotori_runtime.zig` still masks them. Task 2 removes that mask.

- [ ] **Step 1.1: Add `setNodeOwnerDoc` and `getNodeOwnerDoc` helpers**

Add near the top of `kotori_dom.zig` after the global declarations (~L40-L50):

```zig
/// DOM §4.4 — write the owner document slot on a Node JsObject.
/// `owner_doc_val` = JsValue.null_val for Document nodes themselves.
fn setNodeOwnerDoc(vm: *VM, obj: *JsObject, owner_doc_val: JsValue) void {
    const sid = vm.pool.intern("_ownerDoc") catch return;
    obj.setProperty(vm.allocator, sid, owner_doc_val) catch {};
}

/// DOM §4.4 — read the owner document slot. Returns null_val if unset.
fn getNodeOwnerDoc(vm: *VM, obj: *JsObject) JsValue {
    const sid = vm.pool.intern("_ownerDoc") catch return JsValue.null_val;
    return obj.getProperty(sid) orelse JsValue.null_val;
}
```

- [ ] **Step 1.2: Rewrite the ownerDocument getter at L1115-L1122**

Locate:
```zig
// Node.ownerDocument — null for Document nodes (DOM §4.4)
if (eql(name, "ownerDocument")) {
    return JsValue.{ .object = globalThis.document };
}
```

Replace with:
```zig
// Node.ownerDocument — read per-node _ownerDoc slot (DOM §4.4)
if (eql(name, "ownerDocument")) {
    return getNodeOwnerDoc(vm, obj);
}
```

Verify exact existing text first with:
```bash
sed -n '1113,1123p' src/js/kotori_dom.zig
```

- [ ] **Step 1.3: Write test for getter**

Create `tests/test_kotori_dom.zig` entry (append at end):

```zig
test "ownerDocument reads _ownerDoc slot, not globalThis" {
    // Minimal VM setup — use existing test harness conventions
    var vm = try testVm();
    defer vm.deinit();
    const node = try vm.createObj(.{});
    // Set a specific owner doc object
    const doc_a = try vm.createObj(.{});
    setNodeOwnerDoc(&vm, node, JsValue.initObject(doc_a));
    const got = getNodeOwnerDoc(&vm, node);
    try std.testing.expectEqual(@intFromPtr(doc_a), @intFromPtr(got.asObject()));
}
```

Adapt `testVm()` to whatever helper the test file already uses (search for existing `test "` entries to mirror the setup).

- [ ] **Step 1.4: Run test — should pass**

Run:
```bash
cd ~/suzume && zig build test 2>&1 | tail -40
```

Expected: new test passes. No regressions.

- [ ] **Step 1.5: Migrate L584 bootstrap doc wrap**

Find:
```zig
const doc_obj = try vm.createObj(.{ .obj_type = .dom_node });
doc_obj.data = .{ .dom_node = document_ptr };
doc_obj.prototype = ep;
nodeCachePut(vm.allocator, @ptrCast(@alignCast(document_ptr)), doc_obj);
```

Insert after the `nodeCachePut` line:
```zig
// Document itself has ownerDocument = null per DOM §4.4
setNodeOwnerDoc(vm, doc_obj, JsValue.null_val);
```

Also change `doc_obj.prototype = ep;` to `doc_obj.prototype = np;` — a Document node should use Node.prototype, not Element.prototype (verify `np` is the `g_node_proto` name in scope; if the local name differs, use `g_node_proto` or `vm.node_proto` as in surrounding code).

- [ ] **Step 1.6: Migrate `createJsOnlyElement` at L1742**

Change signature from:
```zig
fn createJsOnlyElement(vm: *VM, local_name: []const u8, ns_uri: ?[]const u8) !JsValue {
```

to:
```zig
fn createJsOnlyElement(vm: *VM, local_name: []const u8, ns_uri: ?[]const u8, owner_doc: JsValue) !JsValue {
```

Replace the existing line:
```zig
try obj.setProperty(vm.allocator, try vm.pool.intern("ownerDocument"), JsValue.null_val);
```
with:
```zig
setNodeOwnerDoc(vm, obj, owner_doc);
```

Then update every caller found in Step 0.2 to pass the appropriate `owner_doc`:
- If the caller is inside a `createElement`/`createElementNS` native, the owner is the `this_val` document (bound via JS call).
- If the caller is inside `impl.createDocument`, the owner is the newly-created doc.
- Use `JsValue.null_val` ONLY when wrapping a Document node itself.

- [ ] **Step 1.7: Migrate Attr builder at L2014-L2062**

Find the line near L2051:
```zig
try obj.setProperty(vm.allocator, try vm.pool.intern("ownerDocument"), owner_doc);
```

Replace with:
```zig
setNodeOwnerDoc(vm, obj, owner_doc);
```

Remove the now-redundant `vm.pool.intern("ownerDocument")` + `setProperty` for the JS-visible property — the getter at L1115 now handles it via the slot.

- [ ] **Step 1.8: Migrate L2439 DocumentType init**

Find:
```zig
try obj.setProperty(vm.allocator, try vm.pool.intern("ownerDocument"), JsValue.null_val);
```

Replace with:
```zig
setNodeOwnerDoc(vm, obj, JsValue.null_val);
```

Same pattern for every remaining L52xx setter (L5200, L5247, L5326).

- [ ] **Step 1.9: Migrate L3383 `wrapShadowRoot`**

After the `obj.prototype = vm.element_proto;` line:
```zig
// DOM §4.4 — shadow root's ownerDocument is its host's ownerDocument.
const host_val = /* derive from root_sr if accessible; else JsValue.null_val */;
setNodeOwnerDoc(vm, obj, host_val);
```

If deriving the host's ownerDoc is non-trivial, set to `JsValue.null_val` for this task and add a TODO comment — Shadow DOM is Non-goal per spec §1. The test at Task 1 does not exercise shadow root owner.

- [ ] **Step 1.10: Migrate L3424 `nativeDocumentConstructor`**

After `doc_obj.prototype = g_node_proto;`:
```zig
// DOM §4.4 — Document.ownerDocument = null
setNodeOwnerDoc(vm, doc_obj, JsValue.null_val);
```

- [ ] **Step 1.11: Migrate L3801 `wrapNode`**

Locate the existing:
```zig
obj.prototype = switch (nodeType(node)) {
    lxb.LXB_DOM_NODE_TYPE_ELEMENT => vm.element_proto,
    ...
};
nodeCachePut(vm.allocator, node, obj);
```

Insert before `nodeCachePut`:
```zig
// DOM §4.4 — resolve owner document from lexbor.
const owner_doc_val: JsValue = blk: {
    const nt = nodeType(node);
    if (nt == lxb.LXB_DOM_NODE_TYPE_DOCUMENT) break :blk JsValue.null_val;
    const od = node.owner_document;
    if (od == null) break :blk JsValue.null_val;
    const od_node: *lxb.lxb_dom_node_t = @ptrCast(@alignCast(od));
    // Recursive wrap: if doc not yet in cache, wrap it (shallow — no recursion into children).
    if (nodeCacheGet(od_node)) |cached| {
        break :blk JsValue.initObject(cached);
    }
    // Lazy-wrap the document node
    const doc_wrap = vm.createObj(.{ .obj_type = .dom_node }) catch break :blk JsValue.null_val;
    doc_wrap.data = .{ .dom_node = od_node };
    doc_wrap.prototype = g_node_proto;
    setNodeOwnerDoc(vm, doc_wrap, JsValue.null_val);
    nodeCachePut(vm.allocator, od_node, doc_wrap);
    break :blk JsValue.initObject(doc_wrap);
};
setNodeOwnerDoc(vm, obj, owner_doc_val);
```

The P0 fixture verified `node->owner_document` is non-null for detached nodes. If the fixture failed, instead add a required `owner_doc: JsValue` parameter to `wrapNode` and update every caller.

- [ ] **Step 1.12: Migrate L4901 `createHTMLDocument`**

After `doc_obj.prototype = g_node_proto;`:
```zig
// DOM §4.4 — Document.ownerDocument = null
setNodeOwnerDoc(vm, doc_obj, JsValue.null_val);
```

- [ ] **Step 1.13: Migrate `nativeCloneNode`**

Locate `fn nativeCloneNode` at the line recorded in Step 0.4. For each cloned-element wrap, set `_ownerDoc` to the source's ownerDoc (per DOM §4.4.1 "clone a node" step 3 — clone uses the same document unless an override is specified; the `importNode` wrapper provides the override in Task 2).

Concretely, find the `createObj(.{ .obj_type = .dom_node })` call inside cloneNode. After proto assignment, add:
```zig
const src_owner = getNodeOwnerDoc(vm, src_obj);
setNodeOwnerDoc(vm, clone_obj, src_owner);
```

- [ ] **Step 1.14: Run full test suite**

Run:
```bash
cd ~/suzume && zig build test 2>&1 | tail -40
```

Expected: all tests pass. If tests relying on `globalThis.document === el.ownerDocument` fail, they were relying on the bug; update them to compare to the actual creating doc.

- [ ] **Step 1.15: Commit**

```bash
cd ~/suzume
git add src/js/kotori_dom.zig tests/test_kotori_dom.zig
git commit -m "$(cat <<'EOF'
fix(kotori): ownerDocument uses per-node _ownerDoc slot across all wrapper sites (DOM §4.4)

Add setNodeOwnerDoc/getNodeOwnerDoc helpers; rewrite L1116 getter to read
the slot instead of returning globalThis.document. Migrate all 10
wrapper/creator sites enumerated in spec §3.1:
- L584 bootstrap doc (null_val)
- L1742 createJsOnlyElement (now takes owner_doc param)
- L2051 Attr builder
- L2439 DocumentType
- L3383 wrapShadowRoot
- L3424 nativeDocumentConstructor
- L3801 wrapNode (owner resolved via node->owner_document)
- L4305 nativeCloneNode (inherits src ownerDoc)
- L4901 createHTMLDocument
- L5200/5247/5326 impl.create* paths

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Remove JS ownerDocument Infrastructure + Rewrite `nativeImportNode`

**Files:**
- Modify: `src/js/kotori_runtime.zig` — delete L1425-L1521 block
- Modify: `src/js/kotori_dom.zig` — rewrite `nativeImportNode`

**Purpose:** Remove the JS-level `stampOwnerDocument`/`wrapDocCreators`/`impl wrappers`/`importNode` polyfill that currently installs instance-level `ownerDocument` getters, which silently defeat Task 1's slot-based native getter. Then rewrite `nativeImportNode` in Zig to perform DOM §4.4.1 "clone a node" recursively, writing `_ownerDoc = target_doc` on every cloned element.

- [ ] **Step 2.1: Verify delete scope with grep**

Run:
```bash
cd ~/suzume
grep -n "stampOwnerDocument\|wrapDocCreators" src/js/kotori_runtime.zig src/js/kotori_dom.zig src/js/*.zig
```

Expected: matches only within `src/js/kotori_runtime.zig` lines 1425-1521. If matches exist elsewhere, expand the delete scope before proceeding.

- [ ] **Step 2.2: Read the polyfill block**

Run:
```bash
sed -n '1423,1525p' src/js/kotori_runtime.zig > /tmp/polyfill-to-delete.txt
cat /tmp/polyfill-to-delete.txt
```

Confirms: `stampOwnerDocument` at ~L1425, `wrapDocCreators` at ~L1441, impl wrapper at ~L1477, `wrapDocCreators(document)` at ~L1499, `importNode` polyfill at ~L1500.

- [ ] **Step 2.3: Delete the block from `kotori_runtime.zig`**

Open `src/js/kotori_runtime.zig` in the editor. Delete the lines containing:
- The JS string fragment starting `function stampOwnerDocument(node, doc){` (line containing this)
- Continue deleting through and including the JS string fragment `try { document.importNode = importNode.bind(document); } catch(e) {}`

The exact line range from P0 is L1425-L1521. Verify after deletion with:
```bash
grep -n "stampOwnerDocument\|wrapDocCreators\|importNode" src/js/kotori_runtime.zig
```

Expected: zero matches.

- [ ] **Step 2.4: Rewrite `nativeImportNode` in `kotori_dom.zig`**

Locate `fn nativeImportNode` at the line recorded in Step 0.4. Replace the body with:

```zig
fn nativeImportNode(vm: *VM, this_val: JsValue, args: []const JsValue) JsValue {
    // DOM §4.5 + §4.4.1
    if (args.len < 1) return vm.throwTypeError("importNode requires at least 1 argument");
    const src_val = args[0];
    const deep = if (args.len >= 2) args[1].toBoolean() else false;
    const src_obj = src_val.asObject() orelse return vm.throwTypeError("argument is not a Node");
    const src_nt = nodeTypeFromObj(src_obj);
    if (src_nt == 9) { // DOCUMENT_NODE per DOM spec
        return vm.throwDomException("NotSupportedError", "Cannot import a Document");
    }
    const target_doc_obj = this_val.asObject() orelse return vm.throwTypeError("this is not a Document");
    const target_doc_val = JsValue.initObject(target_doc_obj);
    return cloneNodeRecursive(vm, src_obj, target_doc_val, deep) catch return JsValue.null_val;
}

/// DOM §4.4.1 "clone a node" — recursive when `deep` is true.
/// Every cloned element's _ownerDoc is set to `owner_doc`.
fn cloneNodeRecursive(vm: *VM, src: *JsObject, owner_doc: JsValue, deep: bool) !JsValue {
    // Clone the src node itself via lexbor clone_node API (detached).
    // Implementation borrows existing cloneNode internals — delegate to nativeCloneNode
    // factored as a helper if the current code supports that. If not, duplicate the
    // body here but swap the ownerDoc write to target_doc and recurse only when deep.
    //
    // Minimal pseudo-code:
    //   clone_obj = clone the lexbor node + wrap as JsObject + set _ownerDoc = owner_doc
    //   if deep, iterate src childNodes; for each, recurse; appendChild clone to parent clone
    //   return clone_obj
    //
    // The engineer should factor nativeCloneNode's body into a helper that takes an
    // explicit owner_doc parameter, then both importNode and cloneNode use it.
    //
    @panic("todo: factor cloneNode body — see plan");  // REMOVE before commit
}
```

The `@panic` above is a sentinel; before committing, the engineer factors `nativeCloneNode`'s existing implementation into a helper `cloneNodeImpl(vm, src, owner_doc, deep)`. Then:
- `nativeCloneNode` calls `cloneNodeImpl(vm, src, getNodeOwnerDoc(vm, src), deep)`.
- `nativeImportNode` calls `cloneNodeImpl(vm, src, JsValue.initObject(target_doc_obj), deep)`.

- [ ] **Step 2.5: Write unit test for importNode cross-doc ownership**

Append to `tests/test_kotori_dom.zig`:

```zig
test "importNode sets target as ownerDocument recursively" {
    var vm = try testVm();
    defer vm.deinit();
    // Create two docs via impl.createHTMLDocument
    const doc_a = try runJs(&vm, "document.implementation.createHTMLDocument('A')");
    const doc_b = try runJs(&vm, "document.implementation.createHTMLDocument('B')");
    const src = try runJs(&vm, "doc_a.createElement('div')");
    _ = try runJs(&vm, "src.appendChild(doc_a.createElement('span'))");
    const clone = try runJs(&vm, "doc_b.importNode(src, true)");
    const clone_owner = try runJs(&vm, "clone.ownerDocument");
    const child_owner = try runJs(&vm, "clone.firstChild.ownerDocument");
    try std.testing.expect(clone_owner.strictEqualsObject(doc_b));
    try std.testing.expect(child_owner.strictEqualsObject(doc_b));
}
```

Adapt `runJs` / `testVm` / `strictEqualsObject` to the actual helpers in `tests/test_kotori_dom.zig`.

- [ ] **Step 2.6: Run zig build test**

Run:
```bash
cd ~/suzume && zig build test 2>&1 | tail -40
```

Expected: all tests pass. If `importNode.html`-related tests fail, the cloneNodeRecursive implementation is incomplete — complete Step 2.4 refactor before continuing.

- [ ] **Step 2.7: Targeted WPT check**

Run:
```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/nodes/importNode.html 2>&1 | tail -20
```

Expected: importNode.html pass rate improves vs P0 baseline. 100% not required yet — attributes fix (Task 3) may be needed for some subtests.

- [ ] **Step 2.8: Commit**

```bash
cd ~/suzume
git add src/js/kotori_runtime.zig src/js/kotori_dom.zig tests/test_kotori_dom.zig
git commit -m "$(cat <<'EOF'
refactor(kotori): remove JS ownerDocument stamping; native importNode handles recursive clone with target doc

Delete the JS-level ownerDocument infrastructure from kotori_runtime.zig
L1425-L1521:
- stampOwnerDocument (subtree Object.defineProperty stamper)
- wrapDocCreators (monkey-patches createElement etc. to stamp return values)
- impl.createHTMLDocument/createDocument wrappers
- importNode polyfill + Document.prototype.importNode assignment

These all installed instance-level `ownerDocument` getters that
silently defeated the native _ownerDoc slot introduced in the previous
commit.

Rewrite nativeImportNode to perform DOM §4.4.1 "clone a node"
recursively in Zig, writing _ownerDoc = target_doc on every cloned
element. Factor nativeCloneNode body into shared cloneNodeImpl helper.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `buildAttributesMap` Fix + Attr Identity Cache + Live NamedNodeMap

**Files:**
- Modify: `src/js/kotori_dom.zig` — L3887 one-line fix, Attr wrapper cache, invalidation in setAttribute/removeAttribute natives
- Modify: `tests/test_kotori_dom.zig` — liveness + identity tests

**Purpose:** Fix the L3887 iteration bug and add Attr JS wrapper caching for identity; rebuild the NamedNodeMap per access for liveness; invalidate the wrapper cache entry on attribute removal.

- [ ] **Step 3.1: Write failing test for all-attributes iteration**

Append to `tests/test_kotori_dom.zig`:

```zig
test "el.attributes exposes ALL attributes via indexed access" {
    var vm = try testVm();
    defer vm.deinit();
    _ = try runJs(&vm,
        \\var el = document.createElement('div');
        \\el.setAttribute('a', '1');
        \\el.setAttribute('b', '2');
        \\el.setAttribute('c', '3');
    );
    const len = try runJs(&vm, "el.attributes.length");
    try std.testing.expectEqual(@as(f64, 3), len.asNumber());
    const a2 = try runJs(&vm, "el.attributes[2].name");
    const s = try vm.pool.get(a2.asStringId());
    try std.testing.expectEqualStrings("c", s);
}
```

- [ ] **Step 3.2: Run test — should fail with current bug**

Run:
```bash
cd ~/suzume && zig build test 2>&1 | grep -A 3 "attributes exposes ALL"
```

Expected: `expected 3, got 1` (the L3887 bug only exposes the first attr).

- [ ] **Step 3.3: Apply the L3887 one-line fix**

In `src/js/kotori_dom.zig`, locate:
```zig
attr = @ptrCast(@alignCast(a.node.next));
```

Replace with:
```zig
attr = @ptrCast(@alignCast(dom_b.lxb_dom_element_next_attribute_noi(a)));
```

If `lxb_dom_element_next_attribute_noi` is not yet exported through the `dom_b` binding, add the extern declaration. Verify existing pattern at L3852:
```zig
var attr: ?*lxb.lxb_dom_attr_t = @ptrCast(@alignCast(dom_b.lxb_dom_element_first_attribute_noi(elem)));
```
— the `_noi` variants are already in use; `next_attribute_noi` should also be available. If missing, add:
```zig
// In dom_b.zig (binding file)
pub extern fn lxb_dom_element_next_attribute_noi(attr: *lxb_dom_attr_t) ?*lxb_dom_attr_t;
```

- [ ] **Step 3.4: Run Step 3.1 test — should pass**

Run:
```bash
cd ~/suzume && zig build test 2>&1 | grep -A 3 "attributes exposes ALL"
```

Expected: PASS.

- [ ] **Step 3.5: Write failing test for Attr identity**

Append:
```zig
test "el.attributes[0] === el.attributes[0] (Attr identity)" {
    var vm = try testVm();
    defer vm.deinit();
    _ = try runJs(&vm,
        \\var el = document.createElement('div');
        \\el.setAttribute('x', '1');
    );
    const same = try runJs(&vm, "el.attributes[0] === el.attributes[0]");
    try std.testing.expect(same.asBool());
}
```

- [ ] **Step 3.6: Run test — should fail**

Expected: `expected true, got false`. `buildAttributesMap` currently allocates fresh Attr JsObjects per call.

- [ ] **Step 3.7: Add Attr wrapper cache to `buildAttributesMap`**

Before the function body, add a helper:
```zig
/// Pointer-keyed Attr wrapper cache. Keyed on lexbor attr struct pointer.
/// Lives on the Element JsObject as a hidden `_attrWrappers` property
/// storing a HashMap wrapper object (custom JS-visible object with a
/// Zig-side HashMap(usize → *JsObject) in its userdata).
fn getOrCreateAttrWrapper(vm: *VM, elem_obj: *JsObject, a: *lxb.lxb_dom_attr_t) !*JsObject {
    const cache_sid = try vm.pool.intern("_attrWrappers");
    const existing = elem_obj.getProperty(cache_sid);
    // TODO: cache implementation — simple HashMap stored in a dedicated obj_type.
    // For now, inline: iterate elem_obj's own properties looking for a match by pointer.
    // If not found, create a new Attr JsObject and cache it.
    _ = existing;
    _ = a;
    _ = vm;
    @panic("TODO: implement Attr wrapper cache");
}
```

Replace the `@panic` with a working implementation. Pattern:
1. Look up `_attrWrappers` on the Element. If absent, create a new `HashMap(usize, *JsObject)`-backed cache object (using the `native_data` field on JsObject if that's the pattern in kotori).
2. Hash key = `@intFromPtr(a)`. If hit, return the cached wrapper.
3. Miss: create the Attr JsObject (copy the existing creation code from `buildAttributesMap` lines 3859-3877), insert into the cache, return.

In `buildAttributesMap`, replace the ad-hoc Attr object creation (L3859-L3877) with a call to `getOrCreateAttrWrapper(vm, elem_obj, a)`.

- [ ] **Step 3.8: Run identity test — should pass**

Run Step 3.5 test again:
```bash
cd ~/suzume && zig build test 2>&1 | grep -A 3 "Attr identity"
```

Expected: PASS.

- [ ] **Step 3.9: Write failing test for liveness**

Append:
```zig
test "el.attributes is live: removeAttribute drops entry" {
    var vm = try testVm();
    defer vm.deinit();
    _ = try runJs(&vm,
        \\var el = document.createElement('div');
        \\el.setAttribute('a', '1');
        \\el.setAttribute('b', '2');
    );
    const before = try runJs(&vm, "el.attributes.length");
    try std.testing.expectEqual(@as(f64, 2), before.asNumber());
    _ = try runJs(&vm, "el.removeAttribute('a')");
    const after = try runJs(&vm, "el.attributes.length");
    try std.testing.expectEqual(@as(f64, 1), after.asNumber());
    const has_a = try runJs(&vm, "'a' in el.attributes");
    try std.testing.expect(!has_a.asBool());
}
```

- [ ] **Step 3.10: Run — should pass (rebuild-on-access design does this)**

Each `.attributes` access calls `buildAttributesMap` afresh. Since the fix in Step 3.3 now iterates ALL attrs correctly, and lexbor drops the attr on `removeAttribute`, the rebuilt map will reflect current state.

If this test fails, the NamedNodeMap is being cached at the element level across accesses. Remove any caching of the map object — only the Attr wrappers inside are cached.

- [ ] **Step 3.11: Add Attr wrapper invalidation to `removeAttribute` native**

Locate `fn nativeRemoveAttribute` (or the equivalent `setProperty`-driven path). After the lexbor `lxb_dom_element_remove_attribute` call, invalidate:
```zig
// Drop the stale Attr wrapper cache entry so a subsequent same-name insert
// doesn't hit a JS wrapper pointing to a freed lexbor struct.
const cache_sid = vm.pool.intern("_attrWrappers") catch return;
const cache_val = elem_obj.getProperty(cache_sid);
if (cache_val) |cv| {
    // Remove entry keyed on the now-freed attr pointer.
    // Implementation depends on the cache representation chosen in Step 3.7.
    _ = cv;
}
```

Same for `setAttributeNS`/`removeAttributeNS` natives.

- [ ] **Step 3.12: Run full attributes.html WPT**

Run:
```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/nodes/attributes.html 2>&1 | tail -20
```

Expected: pass count improves vs P0 baseline. 100% not required yet — the interface dispatch from later tasks may affect a few subtests.

- [ ] **Step 3.13: Commit**

```bash
cd ~/suzume
git add src/js/kotori_dom.zig tests/test_kotori_dom.zig
git commit -m "$(cat <<'EOF'
fix(kotori): buildAttributesMap iterates all attrs + Attr identity cache + liveness (DOM §4.9.1)

- L3887 one-line fix: replace a.node.next with
  dom_b.lxb_dom_element_next_attribute_noi(a) so iteration visits every
  attribute, not just the first.
- Add pointer-keyed _attrWrappers cache on Element JsObject so
  el.attributes[0] === el.attributes[0] holds.
- NamedNodeMap rebuilt per-access so removeAttribute/setAttribute
  immediately reflected in .length and 'name in el.attributes'.
- Invalidate _attrWrappers entry on removeAttribute/removeAttributeNS
  to avoid stale wrapper pointing to freed lexbor struct.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `kotori_html_interfaces.zig` New Module

**Files:**
- Create: `src/js/kotori_html_interfaces.zig`
- Create: `tests/test_kotori_html_interfaces.zig`
- Modify: `build.zig` (if it enumerates test files — grep to confirm)

**Purpose:** Single-responsibility resolver for `(namespace, local_name) → interface_name`. Pure-Zig, comptime-constructed tables, no dependency on VM types.

- [ ] **Step 4.1: Write failing test for HTML dispatch**

Create `tests/test_kotori_html_interfaces.zig`:

```zig
const std = @import("std");
const iface = @import("../src/js/kotori_html_interfaces.zig");

test "HTML_NS + div → HTMLDivElement" {
    try std.testing.expectEqualStrings("HTMLDivElement",
        iface.resolveInterface(iface.HTML_NS, "div"));
}

test "HTML_NS + input → HTMLInputElement" {
    try std.testing.expectEqualStrings("HTMLInputElement",
        iface.resolveInterface(iface.HTML_NS, "input"));
}

test "HTML_NS + xfoo → HTMLUnknownElement" {
    try std.testing.expectEqualStrings("HTMLUnknownElement",
        iface.resolveInterface(iface.HTML_NS, "xfoo"));
}

test "HTML_NS + abbr → HTMLElement (known-generic)" {
    try std.testing.expectEqualStrings("HTMLElement",
        iface.resolveInterface(iface.HTML_NS, "abbr"));
}

test "HTML_NS + foo-bar → HTMLElement (valid custom name)" {
    try std.testing.expectEqualStrings("HTMLElement",
        iface.resolveInterface(iface.HTML_NS, "foo-bar"));
}

test "SVG_NS + circle → SVGCircleElement" {
    try std.testing.expectEqualStrings("SVGCircleElement",
        iface.resolveInterface(iface.SVG_NS, "circle"));
}

test "SVG_NS + foo → SVGElement (unknown → fallback)" {
    try std.testing.expectEqualStrings("SVGElement",
        iface.resolveInterface(iface.SVG_NS, "foo"));
}

test "MATH_NS + mi → MathMLElement (single fallback)" {
    try std.testing.expectEqualStrings("MathMLElement",
        iface.resolveInterface(iface.MATH_NS, "mi"));
}

test "null namespace → Element" {
    try std.testing.expectEqualStrings("Element",
        iface.resolveInterface(null, "anything"));
}
```

- [ ] **Step 4.2: Run test — should fail (module does not exist yet)**

Run:
```bash
cd ~/suzume && zig build test 2>&1 | tail -20
```

Expected: compile error "file not found".

- [ ] **Step 4.3: Create the module**

Create `src/js/kotori_html_interfaces.zig`:

```zig
//! (namespace, local_name) → DOM interface name resolver.
//!
//! Spec references:
//! - HTML §4 element interfaces index:
//!   https://html.spec.whatwg.org/multipage/indices.html#element-interfaces
//! - SVG 2 §4 interface summary:
//!   https://svgwg.org/svg2-draft/types.html#InterfaceSummary
//! - MathML Core §2 (no per-tag DOM interfaces in this spec; all → MathMLElement)

const std = @import("std");

pub const HTML_NS = "http://www.w3.org/1999/xhtml";
pub const SVG_NS  = "http://www.w3.org/2000/svg";
pub const MATH_NS = "http://www.w3.org/1998/Math/MathML";

const html_iface = std.StaticStringMap([]const u8).initComptime(.{
    // Alphabetical per HTML §4 index. Entries map tag → interface. Tags
    // without a dedicated interface map to "HTMLElement".
    .{ "a", "HTMLAnchorElement" },
    .{ "abbr", "HTMLElement" },
    .{ "address", "HTMLElement" },
    .{ "area", "HTMLAreaElement" },
    .{ "article", "HTMLElement" },
    .{ "aside", "HTMLElement" },
    .{ "audio", "HTMLAudioElement" },
    .{ "b", "HTMLElement" },
    .{ "base", "HTMLBaseElement" },
    .{ "bdi", "HTMLElement" },
    .{ "bdo", "HTMLElement" },
    .{ "blockquote", "HTMLQuoteElement" },
    .{ "body", "HTMLBodyElement" },
    .{ "br", "HTMLBRElement" },
    .{ "button", "HTMLButtonElement" },
    .{ "canvas", "HTMLCanvasElement" },
    .{ "caption", "HTMLTableCaptionElement" },
    .{ "cite", "HTMLElement" },
    .{ "code", "HTMLElement" },
    .{ "col", "HTMLTableColElement" },
    .{ "colgroup", "HTMLTableColElement" },
    .{ "data", "HTMLDataElement" },
    .{ "datalist", "HTMLDataListElement" },
    .{ "dd", "HTMLElement" },
    .{ "del", "HTMLModElement" },
    .{ "details", "HTMLDetailsElement" },
    .{ "dfn", "HTMLElement" },
    .{ "dialog", "HTMLDialogElement" },
    .{ "div", "HTMLDivElement" },
    .{ "dl", "HTMLDListElement" },
    .{ "dt", "HTMLElement" },
    .{ "em", "HTMLElement" },
    .{ "embed", "HTMLEmbedElement" },
    .{ "fieldset", "HTMLFieldSetElement" },
    .{ "figcaption", "HTMLElement" },
    .{ "figure", "HTMLElement" },
    .{ "font", "HTMLFontElement" },
    .{ "footer", "HTMLElement" },
    .{ "form", "HTMLFormElement" },
    .{ "frame", "HTMLFrameElement" },
    .{ "frameset", "HTMLFrameSetElement" },
    .{ "h1", "HTMLHeadingElement" },
    .{ "h2", "HTMLHeadingElement" },
    .{ "h3", "HTMLHeadingElement" },
    .{ "h4", "HTMLHeadingElement" },
    .{ "h5", "HTMLHeadingElement" },
    .{ "h6", "HTMLHeadingElement" },
    .{ "head", "HTMLHeadElement" },
    .{ "header", "HTMLElement" },
    .{ "hgroup", "HTMLElement" },
    .{ "hr", "HTMLHRElement" },
    .{ "html", "HTMLHtmlElement" },
    .{ "i", "HTMLElement" },
    .{ "iframe", "HTMLIFrameElement" },
    .{ "img", "HTMLImageElement" },
    .{ "input", "HTMLInputElement" },
    .{ "ins", "HTMLModElement" },
    .{ "kbd", "HTMLElement" },
    .{ "label", "HTMLLabelElement" },
    .{ "legend", "HTMLLegendElement" },
    .{ "li", "HTMLLIElement" },
    .{ "link", "HTMLLinkElement" },
    .{ "main", "HTMLElement" },
    .{ "map", "HTMLMapElement" },
    .{ "mark", "HTMLElement" },
    .{ "marquee", "HTMLMarqueeElement" },
    .{ "menu", "HTMLMenuElement" },
    .{ "meta", "HTMLMetaElement" },
    .{ "meter", "HTMLMeterElement" },
    .{ "nav", "HTMLElement" },
    .{ "noscript", "HTMLElement" },
    .{ "object", "HTMLObjectElement" },
    .{ "ol", "HTMLOListElement" },
    .{ "optgroup", "HTMLOptGroupElement" },
    .{ "option", "HTMLOptionElement" },
    .{ "output", "HTMLOutputElement" },
    .{ "p", "HTMLParagraphElement" },
    .{ "param", "HTMLParamElement" },
    .{ "picture", "HTMLPictureElement" },
    .{ "pre", "HTMLPreElement" },
    .{ "progress", "HTMLProgressElement" },
    .{ "q", "HTMLQuoteElement" },
    .{ "rb", "HTMLElement" },
    .{ "rp", "HTMLElement" },
    .{ "rt", "HTMLElement" },
    .{ "rtc", "HTMLElement" },
    .{ "ruby", "HTMLElement" },
    .{ "s", "HTMLElement" },
    .{ "samp", "HTMLElement" },
    .{ "script", "HTMLScriptElement" },
    .{ "section", "HTMLElement" },
    .{ "select", "HTMLSelectElement" },
    .{ "slot", "HTMLSlotElement" },
    .{ "small", "HTMLElement" },
    .{ "source", "HTMLSourceElement" },
    .{ "span", "HTMLSpanElement" },
    .{ "strong", "HTMLElement" },
    .{ "style", "HTMLStyleElement" },
    .{ "sub", "HTMLElement" },
    .{ "summary", "HTMLElement" },
    .{ "sup", "HTMLElement" },
    .{ "table", "HTMLTableElement" },
    .{ "tbody", "HTMLTableSectionElement" },
    .{ "td", "HTMLTableCellElement" },
    .{ "template", "HTMLTemplateElement" },
    .{ "textarea", "HTMLTextAreaElement" },
    .{ "tfoot", "HTMLTableSectionElement" },
    .{ "th", "HTMLTableCellElement" },
    .{ "thead", "HTMLTableSectionElement" },
    .{ "time", "HTMLTimeElement" },
    .{ "title", "HTMLTitleElement" },
    .{ "tr", "HTMLTableRowElement" },
    .{ "track", "HTMLTrackElement" },
    .{ "u", "HTMLElement" },
    .{ "ul", "HTMLUListElement" },
    .{ "var", "HTMLElement" },
    .{ "video", "HTMLVideoElement" },
    .{ "wbr", "HTMLElement" },
    .{ "dir", "HTMLDirectoryElement" },
    .{ "listing", "HTMLPreElement" },
    .{ "plaintext", "HTMLElement" },
    .{ "xmp", "HTMLPreElement" },
});

const svg_iface = std.StaticStringMap([]const u8).initComptime(.{
    .{ "svg", "SVGSVGElement" },
    .{ "g", "SVGGElement" },
    .{ "defs", "SVGDefsElement" },
    .{ "symbol", "SVGSymbolElement" },
    .{ "use", "SVGUseElement" },
    .{ "circle", "SVGCircleElement" },
    .{ "ellipse", "SVGEllipseElement" },
    .{ "line", "SVGLineElement" },
    .{ "rect", "SVGRectElement" },
    .{ "polyline", "SVGPolylineElement" },
    .{ "polygon", "SVGPolygonElement" },
    .{ "path", "SVGPathElement" },
    .{ "text", "SVGTextElement" },
    .{ "tspan", "SVGTSpanElement" },
    .{ "image", "SVGImageElement" },
    .{ "foreignObject", "SVGForeignObjectElement" },
    .{ "marker", "SVGMarkerElement" },
    .{ "clipPath", "SVGClipPathElement" },
    .{ "mask", "SVGMaskElement" },
    .{ "pattern", "SVGPatternElement" },
});

pub fn resolveInterface(namespace: ?[]const u8, local_name: []const u8) []const u8 {
    const ns = namespace orelse return "Element";

    if (std.mem.eql(u8, ns, HTML_NS)) {
        // HTML namespace requires lowercase for HTML interface dispatch.
        if (!isAllLowerAscii(local_name)) return "HTMLUnknownElement";
        if (html_iface.get(local_name)) |iface| return iface;
        // Unknown tag in HTML NS: custom-element-name heuristic → HTMLElement; else HTMLUnknownElement.
        if (isValidCustomElementName(local_name)) return "HTMLElement";
        return "HTMLUnknownElement";
    }
    if (std.mem.eql(u8, ns, SVG_NS)) {
        if (svg_iface.get(local_name)) |iface| return iface;
        return "SVGElement";
    }
    if (std.mem.eql(u8, ns, MATH_NS)) {
        return "MathMLElement";
    }
    return "Element";
}

pub fn isKnownHtmlTag(local_name: []const u8) bool {
    return html_iface.get(local_name) != null;
}

pub fn isKnownSvgTag(local_name: []const u8) bool {
    return svg_iface.get(local_name) != null;
}

fn isAllLowerAscii(s: []const u8) bool {
    for (s) |c| {
        if (c >= 'A' and c <= 'Z') return false;
    }
    return true;
}

/// Minimal valid custom-element-name check — a lowercase ASCII name
/// containing at least one hyphen and not in the reserved list.
/// Full HTML §4.13 is Non-goal for this spec; this is the weakest check
/// that still routes 'foo-bar' → HTMLElement and 'xfoo' → HTMLUnknownElement.
fn isValidCustomElementName(name: []const u8) bool {
    if (name.len < 2) return false;
    if (!(name[0] >= 'a' and name[0] <= 'z')) return false;
    var has_hyphen = false;
    for (name) |c| {
        if (c == '-') has_hyphen = true;
    }
    return has_hyphen;
}
```

- [ ] **Step 4.4: Register test file in build.zig if needed**

Run:
```bash
grep -n "test_kotori" build.zig
```

If `tests/test_kotori_dom.zig` is listed, add a similar entry for `tests/test_kotori_html_interfaces.zig`. If the build system discovers test files via a pattern, no change needed.

- [ ] **Step 4.5: Run all Step 4.1 tests — should pass**

Run:
```bash
cd ~/suzume && zig build test 2>&1 | tail -20
```

Expected: 9 new tests pass, existing tests unaffected.

- [ ] **Step 4.6: Commit**

```bash
cd ~/suzume
git add src/js/kotori_html_interfaces.zig tests/test_kotori_html_interfaces.zig build.zig
git commit -m "$(cat <<'EOF'
feat(kotori): add kotori_html_interfaces resolver (HTML §4 + SVG2 §4 + MathML Core §2)

Single-responsibility module mapping (namespace, local_name) →
DOM interface name via comptime StaticStringMaps:
- ~115 HTML tag entries (HTML §4 element interfaces index)
- ~20 core SVG tag entries (SVG2 §4)
- MathML → single MathMLElement fallback (per-tag deferred)
- null namespace → "Element"
- Unknown HTML tag → HTMLUnknownElement (custom-element-name heuristic
  routes hyphenated names to HTMLElement per HTML §4.13 minimum)

No VM dependencies; pure Zig.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Prototype Hierarchy (`g_html_protos` / `g_svg_protos` + freeze)

**Files:**
- Modify: `src/js/kotori_dom.zig` — add global proto map declarations, build hierarchy in `initGlobalPrototypes` BEFORE L584 bootstrap doc wrap

**Purpose:** Build `HTMLElement.prototype`, `SVGElement.prototype`, `MathMLElement.prototype`, and every named subclass prototype, chained correctly. Freeze each. Critical that these are built **before** the bootstrap doc wrap at L584 — the init-order invariant.

- [ ] **Step 5.1: Declare global proto maps**

Near the top of `kotori_dom.zig` with other `g_*_proto` declarations (search for `g_node_proto`):
```zig
var g_html_element_proto: ?*JsObject = null;
var g_svg_element_proto: ?*JsObject = null;
var g_mathml_element_proto: ?*JsObject = null;

var g_html_protos: ?std.StringHashMap(*JsObject) = null;
var g_svg_protos: ?std.StringHashMap(*JsObject) = null;
```

- [ ] **Step 5.2: Add prototype build helper**

Above `initGlobalPrototypes`, add:
```zig
fn buildInterfaceProto(vm: *VM, parent: *JsObject) !*JsObject {
    const proto = try vm.createObj(.{});
    proto.prototype = parent;
    return proto;
}

fn populateInterfaceProtoMap(
    vm: *VM,
    parent: *JsObject,
    iface_table: anytype,
    dest: *std.StringHashMap(*JsObject),
) !void {
    // Collect unique interface names from the table values.
    // For StaticStringMap(T), iterate values via `.values`.
    const values = iface_table.values;
    for (values) |iface_name| {
        if (dest.contains(iface_name)) continue;
        const proto = try buildInterfaceProto(vm, parent);
        try dest.put(iface_name, proto);
    }
}
```

- [ ] **Step 5.3: Build hierarchy in `initGlobalPrototypes`**

Locate `initGlobalPrototypes` (search for the function definition). Inside it, AFTER `g_element_proto` is built (search for `g_element_proto = ep;` or similar) and BEFORE the L584 `const doc_obj = try vm.createObj(.{ .obj_type = .dom_node });` line, insert:

```zig
// ── HTMLElement/SVGElement/MathMLElement prototype hierarchy ──
// Must land BEFORE bootstrap doc wrap (L584) so applyInterfaceProto assertion holds.
const iface_mod = @import("kotori_html_interfaces.zig");

g_html_element_proto = try buildInterfaceProto(vm, ep);
g_svg_element_proto  = try buildInterfaceProto(vm, ep);
g_mathml_element_proto = try buildInterfaceProto(vm, ep);

var html_protos = std.StringHashMap(*JsObject).init(vm.allocator);
try html_protos.put("HTMLElement", g_html_element_proto.?);
try html_protos.put("HTMLUnknownElement", try buildInterfaceProto(vm, g_html_element_proto.?));
try populateInterfaceProtoMap(vm, g_html_element_proto.?, iface_mod.html_iface_values_for_plan(), &html_protos);
g_html_protos = html_protos;

var svg_protos = std.StringHashMap(*JsObject).init(vm.allocator);
try svg_protos.put("SVGElement", g_svg_element_proto.?);
try populateInterfaceProtoMap(vm, g_svg_element_proto.?, iface_mod.svg_iface_values_for_plan(), &svg_protos);
g_svg_protos = svg_protos;

// Freeze (spec correctness per HTML §4; object.zig:429)
try g_html_element_proto.?.freeze(vm.allocator);
var it = g_html_protos.?.iterator();
while (it.next()) |entry| try entry.value_ptr.*.freeze(vm.allocator);
try g_svg_element_proto.?.freeze(vm.allocator);
var sit = g_svg_protos.?.iterator();
while (sit.next()) |entry| try entry.value_ptr.*.freeze(vm.allocator);
try g_mathml_element_proto.?.freeze(vm.allocator);
```

Note: `iface_mod.html_iface_values_for_plan()` is a placeholder — the real pattern depends on whether `StaticStringMap.values` is directly iterable at comptime in Zig 0.15.2. If not, export `pub const html_iface_values = .{ "HTMLAnchorElement", ... };` from `kotori_html_interfaces.zig` as a flat comptime list of unique interface names, and iterate that.

**Simpler alternative** if the above iteration pattern is painful: write out the unique interface names explicitly in a `const html_iface_names = [_][]const u8{ ... };` array. The build loop becomes straightforward.

- [ ] **Step 5.4: Export unique interface name list from `kotori_html_interfaces.zig`**

Append to `src/js/kotori_html_interfaces.zig`:
```zig
/// Unique HTML interface names (subclass prototypes to build). Includes
/// HTMLElement and HTMLUnknownElement. Alphabetical for stable diffs.
pub const html_unique_ifaces = [_][]const u8{
    "HTMLAnchorElement", "HTMLAreaElement", "HTMLAudioElement",
    "HTMLBRElement", "HTMLBaseElement", "HTMLBodyElement", "HTMLButtonElement",
    "HTMLCanvasElement", "HTMLDListElement", "HTMLDataElement",
    "HTMLDataListElement", "HTMLDetailsElement", "HTMLDialogElement",
    "HTMLDirectoryElement", "HTMLDivElement", "HTMLElement", "HTMLEmbedElement",
    "HTMLFieldSetElement", "HTMLFontElement", "HTMLFormElement",
    "HTMLFrameElement", "HTMLFrameSetElement", "HTMLHRElement", "HTMLHeadElement",
    "HTMLHeadingElement", "HTMLHtmlElement", "HTMLIFrameElement",
    "HTMLImageElement", "HTMLInputElement", "HTMLLIElement", "HTMLLabelElement",
    "HTMLLegendElement", "HTMLLinkElement", "HTMLMapElement",
    "HTMLMarqueeElement", "HTMLMenuElement", "HTMLMetaElement",
    "HTMLMeterElement", "HTMLModElement", "HTMLOListElement", "HTMLObjectElement",
    "HTMLOptGroupElement", "HTMLOptionElement", "HTMLOutputElement",
    "HTMLParagraphElement", "HTMLParamElement", "HTMLPictureElement",
    "HTMLPreElement", "HTMLProgressElement", "HTMLQuoteElement",
    "HTMLScriptElement", "HTMLSelectElement", "HTMLSlotElement",
    "HTMLSourceElement", "HTMLSpanElement", "HTMLStyleElement",
    "HTMLTableCaptionElement", "HTMLTableCellElement", "HTMLTableColElement",
    "HTMLTableElement", "HTMLTableRowElement", "HTMLTableSectionElement",
    "HTMLTemplateElement", "HTMLTextAreaElement", "HTMLTimeElement",
    "HTMLTitleElement", "HTMLTrackElement", "HTMLUListElement",
    "HTMLUnknownElement", "HTMLVideoElement",
};

pub const svg_unique_ifaces = [_][]const u8{
    "SVGCircleElement", "SVGClipPathElement", "SVGDefsElement",
    "SVGElement", "SVGEllipseElement", "SVGForeignObjectElement",
    "SVGGElement", "SVGImageElement", "SVGLineElement", "SVGMarkerElement",
    "SVGMaskElement", "SVGPathElement", "SVGPatternElement", "SVGPolygonElement",
    "SVGPolylineElement", "SVGRectElement", "SVGSVGElement", "SVGSymbolElement",
    "SVGTSpanElement", "SVGTextElement", "SVGUseElement",
};
```

Then simplify Step 5.3's proto-building loop:
```zig
for (iface_mod.html_unique_ifaces) |iface_name| {
    const parent: *JsObject = if (std.mem.eql(u8, iface_name, "HTMLElement")) ep else g_html_element_proto.?;
    const proto = try buildInterfaceProto(vm, parent);
    try html_protos.put(iface_name, proto);
}
// HTMLElement itself is the parent — overwrite its entry with g_html_element_proto built first:
g_html_element_proto = try buildInterfaceProto(vm, ep);
try html_protos.put("HTMLElement", g_html_element_proto.?);
// (subsequent iterations parent to g_html_element_proto)
```

Cleaner reordering: build `g_html_element_proto` first, put it, then loop over the rest skipping "HTMLElement". Same pattern for SVG.

- [ ] **Step 5.5: Write test verifying proto chain**

Append to `tests/test_kotori_dom.zig`:
```zig
test "HTMLDivElement.prototype chains to HTMLElement.prototype chains to Element.prototype" {
    var vm = try testVm();
    defer vm.deinit();
    const div_proto = g_html_protos.?.get("HTMLDivElement").?;
    try std.testing.expectEqual(g_html_element_proto.?, div_proto.prototype.?);
    try std.testing.expectEqual(vm.element_proto.?, g_html_element_proto.?.prototype.?);
}
```

- [ ] **Step 5.6: Run — should pass**

Run:
```bash
cd ~/suzume && zig build test 2>&1 | tail -10
```

Expected: PASS. No runtime regressions (hierarchy built but not yet used).

- [ ] **Step 5.7: Commit**

```bash
cd ~/suzume
git add src/js/kotori_dom.zig src/js/kotori_html_interfaces.zig tests/test_kotori_dom.zig
git commit -m "$(cat <<'EOF'
feat(kotori): HTMLElement/SVGElement/MathMLElement prototype hierarchy, built before bootstrap doc wrap

Add g_html_element_proto / g_svg_element_proto / g_mathml_element_proto
plus per-subclass g_html_protos / g_svg_protos StringHashMaps built in
initGlobalPrototypes BEFORE the L584 bootstrap doc wrap — so that
applyInterfaceProto's invariant (g_html_protos != null) holds from the
very first wrapNode call.

All prototypes frozen via JsObject.freeze for spec correctness
(HTML §4 prototype chain immutability), not performance.

Builds ~68 HTML + ~21 SVG + 1 MathML prototypes (~30 KB binary impact,
within RPi Zero 2W budget).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Fix L742 Shared-Proto Bug + Run P3c Audit

**Files:**
- Modify: `src/js/kotori_dom.zig` — L742-L774 ctor wiring
- Produces: P3c audit report (committed as part of commit body)

**Purpose:** Fix the bug where all 67 HTMLXxxElement constructors share `g_element_proto`. Wire each ctor to its matching prototype. Then run the shared-proto regression audit: baseline vs this commit only, classify any PASS→FAIL flips.

- [ ] **Step 6.1: Snapshot pre-audit WPT baseline**

Run:
```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/nodes 2>&1 | tee /tmp/wpt-pre-p3b.txt
```

This is the "before" snapshot for the P3c diff.

- [ ] **Step 6.2: Rewrite L742-L774 HTML ctor wiring**

Locate:
```zig
const html_elem_val = JsValue.initObject(ep);
const html_names = [_][]const u8{ ... };
for (html_names) |ename| {
    const hctor = try vm.createObj(.{ .obj_type = .native_function });
    hctor.data = .{ .native_fn = &nativeNoOpConstructor };
    hctor.setProperty(vm.allocator, proto_sid, html_elem_val) catch {};
    try vm.globals.put(vm.allocator, try vm.pool.intern(ename), JsValue.initObject(hctor));
}
```

Replace with:
```zig
const iface_mod = @import("kotori_html_interfaces.zig");
for (iface_mod.html_unique_ifaces) |ename| {
    const hctor = try vm.createObj(.{ .obj_type = .native_function });
    hctor.data = .{ .native_fn = &nativeNoOpConstructor };
    const ctor_proto = g_html_protos.?.get(ename) orelse g_html_element_proto.?;
    hctor.setProperty(vm.allocator, proto_sid, JsValue.initObject(ctor_proto)) catch {};
    try vm.globals.put(vm.allocator, try vm.pool.intern(ename), JsValue.initObject(hctor));
}

// SVG ctors
for (iface_mod.svg_unique_ifaces) |ename| {
    const sctor = try vm.createObj(.{ .obj_type = .native_function });
    sctor.data = .{ .native_fn = &nativeNoOpConstructor };
    const ctor_proto = g_svg_protos.?.get(ename) orelse g_svg_element_proto.?;
    sctor.setProperty(vm.allocator, proto_sid, JsValue.initObject(ctor_proto)) catch {};
    try vm.globals.put(vm.allocator, try vm.pool.intern(ename), JsValue.initObject(sctor));
}

// MathMLElement ctor
const mctor = try vm.createObj(.{ .obj_type = .native_function });
mctor.data = .{ .native_fn = &nativeNoOpConstructor };
mctor.setProperty(vm.allocator, proto_sid, JsValue.initObject(g_mathml_element_proto.?)) catch {};
try vm.globals.put(vm.allocator, try vm.pool.intern("MathMLElement"), JsValue.initObject(mctor));
```

- [ ] **Step 6.3: Run zig build test**

Run:
```bash
cd ~/suzume && zig build test 2>&1 | tail -30
```

Expected: all existing tests pass. If a test asserts `div instanceof HTMLAnchorElement === true` (relying on the bug), it was wrong and needs fixing — update the test to assert `=== false`.

- [ ] **Step 6.4: Run P3c audit — post-snapshot**

Run:
```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/nodes 2>&1 | tee /tmp/wpt-post-p3b.txt
```

- [ ] **Step 6.5: Diff the snapshots**

Run:
```bash
diff <(grep -E "PASS|FAIL" /tmp/wpt-pre-p3b.txt) <(grep -E "PASS|FAIL" /tmp/wpt-post-p3b.txt) > /tmp/p3c-diff.txt
cat /tmp/p3c-diff.txt
```

For every subtest that flipped PASS→FAIL, classify:
- **(a) Test bug**: the test depended on the shared-proto bug. Leave the regression; document.
- **(b) Resolver stricter than spec**: our `resolveInterface` returned the wrong interface. Fix the resolver.
- **(c) Legitimate regression**: HTMLElement.prototype is missing a shared method. Add it — reserve 0.5d budget.

Write classification into a file `/tmp/p3c-audit.md` with format:
```
| Subtest | Classification | Action |
|---|---|---|
```

- [ ] **Step 6.6: Fix any category (b) or (c) regressions**

For each category (b) finding, edit `kotori_html_interfaces.zig` to map the affected tag to the correct interface and re-run the audit.

For each category (c) finding, add the missing method to `g_html_element_proto` via `vm.registerNativeMethod(g_html_element_proto.?, "methodName", &nativeMethod);` after the hierarchy is built in Task 5.

- [ ] **Step 6.7: Re-run targeted WPT**

Run:
```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
  dom/nodes/Document-createElement.html dom/nodes/Document-createElementNS.html 2>&1 | tail -20
```

- [ ] **Step 6.8: Commit with audit findings in body**

```bash
cd ~/suzume
git add src/js/kotori_dom.zig src/js/kotori_html_interfaces.zig tests/test_kotori_dom.zig
git commit -m "$(cat <<'EOF'
fix(kotori): wire HTML/SVG/MathML ctors to their own prototypes; run shared-proto audit

Previously all 67 HTML*Element constructors shared g_element_proto at
L742, making `div instanceof HTMLAnchorElement === true` hold by
accident. Each ctor now gets its matching per-interface prototype from
g_html_protos / g_svg_protos.

P3c shared-proto regression audit (baseline vs this change only):
- Category (a) test-bug regressions: <N>
- Category (b) resolver fixes applied: <list>
- Category (c) HTMLElement methods added: <list>

Net delta: +<N> / -<M> subtests — see /tmp/p3c-audit.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Fill in the <N> placeholders from the actual audit before committing.

---

## Task 7: `applyInterfaceProto` Helper + Integration into 4 Wrapper Sites

**Files:**
- Modify: `src/js/kotori_dom.zig` — add helper, wire into `wrapNode`, `createJsOnlyElement`, `wrapShadowRoot`, `nativeCloneNode`/`cloneNodeImpl`

**Purpose:** Single helper assigns the correct prototype to a Node JsObject from `(namespace, local_name, owner_doc)`. Hook it into every element-producing wrapper site.

- [ ] **Step 7.1: Add the helper**

Near the top of `kotori_dom.zig` after `setNodeOwnerDoc`:

```zig
/// DOM §4.5.3 + HTML §4 + SVG2 §4 + MathML Core §2 — assign the correct
/// interface prototype and owner-document slot to a newly-created element.
fn applyInterfaceProto(
    vm: *VM,
    obj: *JsObject,
    namespace: ?[]const u8,
    local_name: []const u8,
    owner_doc: JsValue,
) void {
    const iface_mod = @import("kotori_html_interfaces.zig");
    std.debug.assert(g_html_protos != null); // init-order invariant (spec §3.6)
    setNodeOwnerDoc(vm, obj, owner_doc);
    const iface_name = iface_mod.resolveInterface(namespace, local_name);
    // Look up proto: HTML tables first, then SVG, then Element default.
    if (g_html_protos.?.get(iface_name)) |p| {
        obj.prototype = p;
        return;
    }
    if (g_svg_protos.?.get(iface_name)) |p| {
        obj.prototype = p;
        return;
    }
    if (std.mem.eql(u8, iface_name, "MathMLElement")) {
        obj.prototype = g_mathml_element_proto.?;
        return;
    }
    // "Element" fallback (null namespace, or SVG/MathML without map hit above).
    obj.prototype = vm.element_proto.?;
}
```

- [ ] **Step 7.2: Wire into `wrapNode` at L3801**

Replace the existing `obj.prototype = switch (nodeType(node)) { ... };` block (from Task 1) with:

```zig
const nt = nodeType(node);
if (nt == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
    // Resolve namespace + local name from lexbor.
    var ns_len: usize = 0;
    const ns_ptr_raw = dom_b.lxb_dom_element_namespace_uri(@ptrCast(node), &ns_len);
    const ns_slice: ?[]const u8 = if (ns_ptr_raw) |p| p[0..ns_len] else null;
    var ln_len: usize = 0;
    const ln_ptr = dom_b.lxb_dom_element_local_name(@ptrCast(node), &ln_len) orelse "";
    const ln_slice: []const u8 = if (ln_len > 0) ln_ptr[0..ln_len] else "";
    // Owner doc — already resolved earlier in this function (Task 1).
    applyInterfaceProto(vm, obj, ns_slice, ln_slice, owner_doc_val);
} else {
    obj.prototype = switch (nt) {
        lxb.LXB_DOM_NODE_TYPE_TEXT => g_text_proto,
        lxb.LXB_DOM_NODE_TYPE_COMMENT => g_comment_proto,
        lxb.LXB_DOM_NODE_TYPE_DOCUMENT_TYPE => g_doctype_proto,
        lxb.LXB_DOM_NODE_TYPE_DOCUMENT_FRAGMENT => g_node_proto,
        else => g_node_proto,
    };
    setNodeOwnerDoc(vm, obj, owner_doc_val);
}
```

If the lexbor helper names differ (e.g. `lxb_dom_element_namespace` vs `_uri`), grep existing callers in `kotori_dom.zig` for the correct symbol.

- [ ] **Step 7.3: Wire into `createJsOnlyElement` at L1742**

Replace the `obj.prototype = vm.element_proto;` line (or the equivalent from Task 1's owner_doc param work) with:
```zig
applyInterfaceProto(vm, obj, ns_uri, local_name, owner_doc);
```

Remove any now-redundant `setNodeOwnerDoc` call — `applyInterfaceProto` does it.

- [ ] **Step 7.4: Wire into `wrapShadowRoot` at L3383**

The fragment is conceptually an Element-like node in some contexts but not a true element; keep its prototype as `element_proto` (existing behavior) but call `applyInterfaceProto(vm, obj, null, "", host_owner_doc)` which routes null-namespace → `Element` proto cleanly. The only reason to call it is to write the `_ownerDoc` slot through the same path.

- [ ] **Step 7.5: Wire into `cloneNodeImpl`**

Inside `cloneNodeImpl` (the factored helper from Task 2), for each cloned element:
```zig
// Derive namespace + local name from the cloned lexbor node.
var ns_len: usize = 0;
const ns_ptr = dom_b.lxb_dom_element_namespace_uri(@ptrCast(cloned_node), &ns_len);
var ln_len: usize = 0;
const ln_ptr = dom_b.lxb_dom_element_local_name(@ptrCast(cloned_node), &ln_len);
const ns_s: ?[]const u8 = if (ns_ptr) |p| p[0..ns_len] else null;
const ln_s: []const u8 = if (ln_ptr) |p| p[0..ln_len] else "";
applyInterfaceProto(vm, clone_obj, ns_s, ln_s, owner_doc);
```

- [ ] **Step 7.6: Run all unit tests**

Run:
```bash
cd ~/suzume && zig build test 2>&1 | tail -30
```

Expected: all pass.

- [ ] **Step 7.7: Targeted WPT run**

Run:
```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
  dom/nodes/Document-createElement.html \
  dom/nodes/Document-createElementNS.html \
  dom/nodes/attributes.html \
  dom/nodes/importNode.html 2>&1 | tee /tmp/wpt-p4.txt
```

Expected: Document-createElement.html → 147/147 (100%). Document-createElementNS.html → ≥ 95%. attributes.html → 100%. importNode.html → 100%.

If any gate misses, classify the failure (likely a resolver miss for a specific tag, or a missing setNodeOwnerDoc path) and fix inline before committing.

- [ ] **Step 7.8: Commit**

```bash
cd ~/suzume
git add src/js/kotori_dom.zig tests/test_kotori_dom.zig
git commit -m "$(cat <<'EOF'
feat(kotori): wrapNode + createJsOnlyElement + wrapShadowRoot + cloneNodeImpl dispatch interface prototype (DOM §4.5.3)

Introduce applyInterfaceProto(vm, obj, ns, local, owner_doc): resolves
the correct HTML/SVG/MathML interface via kotori_html_interfaces and
assigns both the prototype and the _ownerDoc slot in one call.

Wired into all four Node-wrapper creation sites:
- wrapNode (L3801) — parser/query path; namespace + local_name from lexbor
- createJsOnlyElement (L1742) — XML-doc JS-only path
- wrapShadowRoot (L3383) — element_proto via null-namespace route
- cloneNodeImpl (L4305 helper) — preserves ns/local on clones

WPT delta vs P0 baseline (see /tmp/wpt-p4.txt): <to be filled in>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Unit Test Coverage Sweep

**Files:**
- Modify: `tests/test_kotori_dom.zig` — add the full 21-test suite from spec §6.1 if not already added
- Modify: `tests/test_kotori_html_interfaces.zig` — ensure all resolver cases covered

**Purpose:** Fill gaps in unit test coverage so `zig build test` alone validates the contract. Most tests already added across Tasks 1-7; this task audits and fills.

- [ ] **Step 8.1: Audit which of the 21 spec §6.1 tests are already in the suite**

Run:
```bash
grep -E "^test " tests/test_kotori_dom.zig | tail -30
```

Cross-check against spec §6.1 numbered list. Note any missing.

- [ ] **Step 8.2: Add the missing tests**

For each missing test from spec §6.1, append a test block mirroring the existing patterns. Ensure coverage includes:
- Dispatch: items 1-12 (div/DIV/input/xfoo/foo-bar/123/createElementNS null/HTML_NS/SVG_NS cases)
- Negative instanceof: items 13-14 (div not HTMLAnchor; svg.circle not HTMLElement)
- ownerDoc: items 15-18 (createElement, Document itself = null, importNode cross-doc, XML-doc cross-doc)
- Attributes: items 19-21 (length/ordering, identity, liveness)

Example test 14:
```zig
test "svg.circle instanceof HTMLElement === false" {
    var vm = try testVm();
    defer vm.deinit();
    _ = try runJs(&vm,
        \\var c = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
    );
    const is_html = try runJs(&vm, "c instanceof HTMLElement");
    try std.testing.expect(!is_html.asBool());
    const is_svg = try runJs(&vm, "c instanceof SVGCircleElement");
    try std.testing.expect(is_svg.asBool());
}
```

- [ ] **Step 8.3: Run full suite**

Run:
```bash
cd ~/suzume && zig build test 2>&1 | tail -30
```

Expected: all ≥ 21 new tests pass, zero regressions.

- [ ] **Step 8.4: Commit**

```bash
cd ~/suzume
git add tests/test_kotori_dom.zig tests/test_kotori_html_interfaces.zig
git commit -m "$(cat <<'EOF'
test(kotori): interface dispatch + ownerDoc + NamedNodeMap WPT coverage

Add ≥ 21 unit tests per spec §6.1:
- HTML/SVG/MathML dispatch
- Negative instanceof (shared-proto bug verification)
- ownerDoc across HTML/XML documents and importNode cross-doc
- NamedNodeMap length, Attr identity, removeAttribute liveness

zig build test green; all new tests pass.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: WPT Verification + Final Gate Sign-off

**Files:** None modified. Produces verification evidence.

**Purpose:** Run the full WPT gate matrix (A/B/C/D) with 3-run stability; verifier agent (different context, per OMC no-self-approval rule) signs off against spec §1 success criteria.

- [ ] **Step 9.1: Run Gate A — 4 target files**

Run 3 times:
```bash
cd ~/suzume
for run in 1 2 3; do
  TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
    dom/nodes/Document-createElement.html \
    dom/nodes/Document-createElementNS.html \
    dom/nodes/attributes.html \
    dom/nodes/importNode.html 2>&1 | tee /tmp/wpt-gate-a-run$run.txt
done
```

Verify: pass counts identical across 3 runs. If they vary, investigate flakiness before declaring success.

- [ ] **Step 9.2: Run Gate B — dom/nodes full**

Run:
```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/nodes 2>&1 | tee /tmp/wpt-gate-b.txt
```

Verify: total ≥ 6050 / 7869 (~77%); Node-contains 1482/1482; compareDocumentPosition 1444/1444.

- [ ] **Step 9.3: Run Gate C — dom/events regression**

Run:
```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/events 2>&1 | tee /tmp/wpt-gate-c.txt
```

Verify: ≥ 70/252 preserved (no regression from baseline).

- [ ] **Step 9.4: Run Gate D — html/dom first measurement**

Run:
```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 html/dom 2>&1 | tee /tmp/wpt-gate-d.txt
```

Verify: no regression worse than −20 subtests vs baseline (accept first-measurement variance).

- [ ] **Step 9.5: Dispatch verifier agent (separate context)**

Per OMC rule (no self-approval), dispatch a verifier agent with:
- The spec path: `docs/superpowers/specs/2026-04-18-kotori-html-interface-dispatch-design.md`
- The gate output files in `/tmp/wpt-gate-*.txt`
- Success criteria from spec §1

Ask it to sign off (APPROVED / REJECTED), citing specific subtest counts.

Example dispatch prompt:
> Verify that the implementation at HEAD satisfies the success criteria in `docs/superpowers/specs/2026-04-18-kotori-html-interface-dispatch-design.md` §1. Inputs: /tmp/wpt-gate-{a1,a2,a3,b,c,d}.txt. For each of the 5 success criteria, cite the evidence line and declare PASS/FAIL. Final verdict: APPROVED or REJECTED with reasons.

- [ ] **Step 9.6: Record sign-off in memory**

If APPROVED, update project memory with the new WPT baselines:
```bash
# Append to memory/project_suzume_wpt_progress.md via the memory helper
# or manually edit to add a session entry.
```

- [ ] **Step 9.7: Final commit (optional, documentation-only)**

If any notes/docs were updated during this task, commit them:
```bash
cd ~/suzume
git add docs/superpowers/plans/2026-04-18-kotori-html-interface-dispatch.md || true
git commit -m "docs: mark kotori HTML interface dispatch plan as complete" 2>/dev/null || true
```

---

## Completion Checklist

Before declaring this plan DONE:

- [ ] All 8 implementation commits landed on master (or merged from worktree)
- [ ] `zig build test` is green at HEAD
- [ ] Gate A: 3 of 4 target files at 100% (createElementNS ≥ 95%)
- [ ] Gate B: dom/nodes ≥ 6050/7869; no regression in Node-contains / compareDocumentPosition
- [ ] Gate C: dom/events ≥ 70/252
- [ ] Gate D: html/dom baseline recorded; no hard regression
- [ ] Verifier agent APPROVED in separate context
- [ ] Memory updated with new WPT numbers
- [ ] /tmp/wpt-*.txt artifacts preserved or attached to commit bodies for future bisect

---

## Notes for the Executor

- The spec is the contract. When in doubt between the plan and the spec, the spec wins — read `docs/superpowers/specs/2026-04-18-kotori-html-interface-dispatch-design.md`.
- **Do not skip P0.** The audit is the foundation for correct line numbers and the lexbor fixture result. If you skip it and the fixture would have failed, you'll waste Tasks 1-7.
- Commits are atomic. If a commit's `zig build test` fails, revert and re-iterate — do not stack commits on broken HEAD.
- Tasks 1 and 2 are a **co-dependent pair** — they must land together or neither. If you bisect, bisect across both.
- The P3c audit (Task 6) is not optional. Category (b)/(c) findings must be resolved in-commit, not deferred.
- WPT 100% for createElementNS.html is deferred to a follow-up (SVG/MathML subclass methods spec). Do not chase it here.

