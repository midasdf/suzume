# Layer 1B — MutationObserver Completion Design Spec

**Date**: 2026-04-19
**Author**: planner (OMC)
**Roadmap**: `docs/superpowers/specs/2026-04-17-kotori-suzume-wpt-100-roadmap.md` — Layer 1B
**Target**: +44 WPT subtests across `dom/nodes/MutationObserver-childList.html` (7/25 → 25/25), `-attributes.html` (3/21 → 21/21), `-characterData.html` (0/8 → 8/8).
**Spec baseline**: WHATWG DOM Living Standard §4.3 "Observing changes to nodes" (<https://dom.spec.whatwg.org/#mutation-observers>), with §4.3.3 "queue a mutation record" and §4.3.4 "notify mutation observers" as the normative references.

---

## Context

suzume already ships a working MutationObserver, but the implementation grew piecemeal as callers were added. Reading `src/js/events.zig` reveals two structural facts that shape this spec:

1. **There is already a `recordMutationFull` helper at `events.zig:2665`** — it accepts target, type, added, removed, attr_name, attr_ns, old_value, prev_sib, next_sib, and correctly gates records with subtree, attributeFilter, and `attributeOldValue`/`characterDataOldValue`. Thin wrappers (`recordMutation`, `recordMutationChildList`, `recordMutationWithOldValue`, `recordMutationAttrNS`) already funnel through it.
2. **A second, parallel MutationObserver implementation exists in `src/js/kotori_dom.zig` at lines 6286–6430** (`recordChildListMutation`, `recordAttributeMutation`, `recordCharDataMutation`). These serve the kotori-VM object path. They have a slightly different subtree check (`isAncestor` at `kotori_dom.zig:6432`) but *no attributeFilter* gating and *no previousSibling/nextSibling* support.

So "add a central `recordMutation` helper" is **already done on the QuickJS side** — the real Layer 1B work is (a) fixing the half-dozen callers that bypass it or pass wrong args, (b) bringing the kotori path to parity, and (c) closing feature gaps (`toggleAttribute`, `appendData`/`deleteData`/`insertData`/`replaceData`, innerHTML sibling metadata).

This spec is additive / non-conflicting with Layer 2A (AbortSignal): 2A touches `addEventListener` around `events.zig:162`, while 1B touches the MutationObserver block `events.zig:2416–3029`. The two blocks do not overlap.

---

## DOM §4.3 Summary (Normative Excerpts)

### §4.3.2 — MutationObserverInit dictionary
Observer options:
- `childList: boolean` — observe insertion/removal of children
- `attributes: boolean` — observe attribute changes
- `characterData: boolean` — observe CharacterData.data changes
- `subtree: boolean` — extend observation to all descendants of the target
- `attributeOldValue: boolean` — when `attributes` is true, include the prior value in every record
- `characterDataOldValue: boolean` — same for CharacterData
- `attributeFilter: sequence<DOMString>` — when non-empty, only listed attribute names produce records

### §4.3.3 — "queue a mutation record"
> To queue a mutation record of `type` for target `target` with name `name`, namespace `namespace`, oldValue `oldValue`, addedNodes `addedNodes`, removedNodes `removedNodes`, previousSibling `previousSibling`, and nextSibling `nextSibling`, run these steps:
>
> 1. Let `interestedObservers` be an empty map.
> 2. Let `nodes` be the inclusive ancestors of `target`.
> 3. For each `node` in `nodes`, and then for each registered observer of `node` with options `options`:
>    1. If `node` is not `target` and `options["subtree"]` is false, continue.
>    2. If `type` is "attributes" and `options["attributes"]` is not true, continue.
>    3. If `type` is "attributes", `options["attributeFilter"]` exists, and `name` is not in `options["attributeFilter"]`, or `namespace` is not null, continue.
>    4. If `type` is "characterData" and `options["characterData"]` is not true, continue.
>    5. If `type` is "childList" and `options["childList"]` is false, continue.
>    6. If `observer` is not in `interestedObservers`, set `interestedObservers[observer]` to null. Then if `type` is "attributes" and `options["attributeOldValue"]` is true, or `type` is "characterData" and `options["characterDataOldValue"]` is true, set `interestedObservers[observer]` to `oldValue`.
> 4. For each `observer` → `mappedOldValue` of `interestedObservers`:
>    1. Let `record` be a new MutationRecord with `type` = type, `target` = target, `attributeName` = name, `attributeNamespace` = namespace, `oldValue` = mappedOldValue, `addedNodes` = addedNodes, `removedNodes` = removedNodes, `previousSibling` = previousSibling, `nextSibling` = nextSibling.
>    2. Enqueue `record` to `observer`'s record queue.
> 5. Queue a mutation observer microtask.

### §4.3.4 — "notify mutation observers"
- Each observer's queue is drained to its callback as `(records, observer)`.
- Callbacks run as microtasks; all observers see all their records atomically per microtask checkpoint.

### §4.3.5 — MutationRecord fields
`type`, `target`, `addedNodes` (NodeList), `removedNodes` (NodeList), `previousSibling`, `nextSibling`, `attributeName`, `attributeNamespace`, `oldValue`. Missing fields MUST be serialized as `null`, never `undefined`.

---

## Central `recordMutation` helper (status: exists; needs consolidation)

### QuickJS side (events.zig)

**Existing signature** — `src/js/events.zig:2665`:

```zig
fn recordMutationFull(
    target: *lxb.lxb_dom_node_t,
    mutation_type: []const u8,
    added: ?*lxb.lxb_dom_node_t,
    removed: ?*lxb.lxb_dom_node_t,
    attr_name: ?[]const u8,
    attr_namespace: ?[]const u8,
    old_value: ?[]const u8,
    prev_sib: ?*lxb.lxb_dom_node_t,
    next_sib: ?*lxb.lxb_dom_node_t,
) void
```

It correctly implements the §4.3.3 gating loop at `events.zig:2676–2731`:
- subtree test: `(t.node == target) or (t.subtree and isDescendant(target, t.node))` at line 2679
- type test: `want = t.child_list | t.attributes | t.character_data` at line 2683
- attributeFilter test: `t.matchesAttributeFilter(attr_name)` at line 2687
- oldValue capture: gated on `attribute_old_value` / `character_data_old_value` at lines 2713–2719

**Gaps**:
1. The single-target bulk helpers (`recordMutationChildListBulk` at 2537, `recordMutationChildListMulti` at 2574, `recordMutationChildListRemovedMulti` at 2613) each re-implement the gating loop and do **not** share the attributeFilter/oldValue guards. They are only used for childList, so attributeFilter is irrelevant there, but they duplicate the subtree-match logic and the `break` (single-entry) semantic. Risk: drift. Proposed fix: refactor them to call a shared `recordMutationCommon(target, record_builder)` that runs the §4.3.3 loop once.
2. The `.ok` path inside `recordMutationFull` does `break` after the first matching target on a given observer (line 2731). That's correct (§4.3.3 says each observer gets at most one record per event). But it means the spec's "inclusive ancestors" walk is implicit — if an observer has two registered targets and both match (e.g., an outer subtree + a directly-observed inner node), only one record is queued. This matches the spec because **the observer entry itself is what gets recorded against**, not the option tuple. No change needed; document the invariant.

### kotori-VM side (kotori_dom.zig)

**Existing three helpers** at `kotori_dom.zig:6287`, `6345`, `6390`:
- `recordChildListMutation(vm, target, added, removed, prev_sib, next_sib)`
- `recordAttributeMutation(vm, target, attr_name, old_value)` — **missing attributeFilter**, **missing namespace**
- `recordCharDataMutation(vm, target, old_value)` — **missing type-enum dispatch**

The design here is coherent but undergeared. Layer 1B consolidates these into a single `recordMutationKotori` with the same shape as `recordMutationFull`, and fixes the attributeFilter/namespace gaps. The record struct (`MoRecord` near `kotori_dom.zig:6441`) already has all the fields (`previous_sibling`, `next_sibling`, `attribute_name`, `old_value`), so this is purely call-site consolidation.

### Proposed unified API (both sides)

Keep the existing thin wrappers for ergonomic call sites — they're already widely used (e.g., `recordMutationWithOldValue` is called from 11 places in `dom_element.zig`, `dom_text.zig`, `dom_node.zig`). Instead:

- Fill the missing wrappers: add `recordMutationCharacterData(target, old_value)` as a 2-arg alias for the characterData case (today callers still use `recordMutationWithOldValue(…, "characterData", null, null, null, old_value)` which reads weirdly — see `dom_text.zig:57, 63`).
- Add `recordMutationChildListSingle` and teach it `prev_sib`/`next_sib` always, so the common childList path always threads sibling metadata. Today `dom_node.zig:329` and `dom_node.zig:338` and `kotori_dom.zig` callers pass `null, null`, losing the information.
- Mirror every QuickJS helper with a kotori-side twin. Table in "Caller audit matrix" below.

---

## Gap 1: `subtree` option — status in code

**Current**: correctly honored in the QuickJS path. `events.zig:2679` does `(t.node == target) or (t.subtree and isDescendant(target, t.node))`, and `isDescendant` at `events.zig:2736` walks `node.parent` upward.

**Kotori-VM path**: also honored, via `isAncestor` at `kotori_dom.zig:6432`. Same semantics.

**Gap per roadmap**: "subtree option not honored (records all mutations regardless)". This is stale — the code is correct as of the current HEAD `beb7a4b`. What *is* still missing:

1. **Subtree must consider `target` itself even when subtree=true + target ≠ observer target**. The current code already does this (`t.node == target OR isDescendant`), but the walk goes *node → ancestors* only. Per §4.3.3 step 2, we need **inclusive ancestors**: `target` itself counts. Verified: `t.node == target` covers it. OK.
2. **Subtree and characterData interaction** — when observer is on an element with `{subtree:true, characterData:true}`, text-node descendants' data changes should fire. The current `isDescendant(target, t.node)` with `target = text_node` walks up and hits the element — works correctly. Confirmed by reading `events.zig:2679`.
3. **Subtree childList for removed descendants** — when a subtree of N is detached, the removal must be recorded at N's parent. This is what `removeChild` does via `events.recordMutationChildList(parent, null, child, rm_prev, rm_next)` at `dom_node.zig:961`. OK.

**Action**: no algorithmic change. Add regression tests (see Test plan) to prevent subtree gating from regressing during Layer 2A's events.zig edits.

---

## Gap 2: textContent childList records

**Current (elements)**: `kotori_dom.zig:275–365` (`elementSetTextContent`). The function already records:
- `dom_node.zig`-style childList at `kotori_dom.zig:329` (for null/undefined assignment) — but passes `null, null, null` for added/removed/prev_sib.
- `kotori_dom.zig:361` — correctly records `(added_child, removed_child, null)` when the assignment is a non-empty string.

**Current (Text/Comment/PI)**: `kotori_dom.zig:287–319` — correctly records `characterData` with old_value. OK.

**Gaps**:
1. Line 329 and 338 record `childList` but lose the **list of removed children**. Spec §4.3.3 requires `removedNodes` to contain every detached descendant. The loop at `kotori_dom.zig:324–326` removes all children one-by-one without collecting pointers:

   ```zig
   // kotori_dom.zig:324 — current
   while (node.first_child) |child| {
       lxb_dom_node_remove(child);
   }
   _ = qjs.JS_SetPropertyStr(c, this_val, "__jsChildren", qjs.JS_NewArray(c));
   events.recordMutation(node, "childList", null, null, null);
   ```

   Fix: collect first (same pattern as `dom_serialize.zig:126` for innerHTML), then emit bulk:

   ```zig
   // proposed
   const removed = try collectChildren(node);
   defer allocator.free(removed);
   while (node.first_child) |child| lxb_dom_node_remove(child);
   _ = qjs.JS_SetPropertyStr(c, this_val, "__jsChildren", qjs.JS_NewArray(c));
   events.recordMutationChildListBulk(node, &.{}, removed, null, null);
   ```

2. Line 344 (`removed_child = node.first_child`) captures only the *first* removed child as a single pointer, then line 361 emits one record with `(added_child, removed_child)`. When the element had N children, N−1 of them are silently dropped from `removedNodes`. Same fix as (1) — collect all, then emit bulk.

3. `previous_sibling` / `next_sibling` — §4.3.5 says these fields are populated "if applicable". For the textContent setter, the spec invokes "replace all" (DOM §4.2.7 step 3), which does **not** set prev/next sibling on the synthesized record. Passing `null, null` is correct here.

---

## Gap 3: characterData records

### 3a. `CharacterData.data` setter (QuickJS path)

**Current**: `dom_text.zig:32–66` — correctly captures `old_text` into a stack buffer before `text_content_set`, emits `events.recordMutationWithOldValue(node, "characterData", null, null, null, old_text)` at lines 57 and 63. **OK**.

### 3b. `appendData` / `deleteData` / `insertData` / `replaceData` — **BROKEN**

Two parallel implementations, both bypass MutationObserver recording:

**QuickJS JS polyfill (`dom_api.zig:4636–4640`)**: the polyfill sets `this.data = …`, which routes back through the `textSetData` setter above — *so MO IS recorded on this path via the round-trip*. Verified by reading line 4637: `this.data+=''+d;`. OK.

**Kotori native (`kotori_dom.zig:4578–4661`)**: `nativeAppendData`, `nativeDeleteData`, `nativeInsertData`, `nativeReplaceData` all call `dom_b.lxb_dom_node_text_content_set(info.node, buf.items.ptr, buf.items.len)` **directly**, never touching `recordCharDataMutation`. This is the dominant path when tests run under kotori (which is the default per roadmap Session #6). This single gap explains why `MutationObserver-characterData.html` sits at 0/8.

**Fix** — add recording to each of the four natives. Example for `nativeAppendData` (`kotori_dom.zig:4578`):

```zig
fn nativeAppendData(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const info = getCharData(vm, this) orelse return JsValue.undefined_val;
    if (args.len == 0) return error.TypeError;
    // NEW: snapshot old text BEFORE mutation (text_content_set invalidates pointer)
    var old_buf: [4096]u8 = undefined;
    const old_len = @min(info.text.len, old_buf.len);
    @memcpy(old_buf[0..old_len], info.text[0..old_len]);
    const old_value = old_buf[0..old_len];
    // … existing append logic …
    _ = dom_b.lxb_dom_node_text_content_set(info.node, buf.items.ptr, buf.items.len);
    recordCharDataMutation(vm, info.node, old_value); // NEW
    return JsValue.undefined_val;
}
```

Same pattern for the other three. The 4096-byte cap matches existing buffers elsewhere (`dom_text.zig:44`, `dom_element.zig:215`). For texts longer than 4 KiB, spill to `allocator.alloc` — same pattern as `classListAdd` at `dom_element.zig:795–808`.

### 3c. `textContent` setter on Text/Comment/PI (already OK)

Covered by `kotori_dom.zig:287–319` — confirmed at Gap 2 section above.

### 3d. `nodeValue` setter (DOM §4.4 — alias for data on CharacterData)

Grep shows only getter (`dom_text.zig:70`). No setter currently routes through MO. **Deferred to Layer 1F** (needs Node.nodeValue setter work anyway) — note in Open Questions but not blocking 44-test target.

---

## Gap 4: `normalize()` childList records

**Current**: `dom_node.zig:1720–1787`. `nodeNormalize` dispatches to `normalizeNodeWithMutations`, which already emits `recordMutationChildList` for each removed/merged text node:
- Empty text removal: line 1746 — `recordMutationChildList(node, null, ch, prev_sib, next_sib)` ✓
- Merged-then-removed sibling: line 1760 and 1775 ✓

**Gap**: the merged **target** text node has its data changed (from e.g. "foo" to "foobar"), but **no `characterData` record is emitted** for the merge. Per DOM §4.4.2 "normalize" step 3.1–3.3, each concatenation is a characterData mutation on the surviving text node.

Fix — in `normalizeNodeWithMutations` before `lxb_dom_node_text_content_set(ch, &merge_buf, total)` at line 1771, capture old text and emit a characterData record for `ch` after the merge:

```zig
// dom_node.zig:1766 — proposed addition
const old_cur_len = cur_len;
var old_cur_buf: [4096]u8 = undefined;
const oc_len = @min(old_cur_len, old_cur_buf.len);
if (cur_ptr) |cp| @memcpy(old_cur_buf[0..oc_len], cp[0..oc_len]);
const old_cur = old_cur_buf[0..oc_len];
// existing merge:
_ = lxb_dom_node_text_content_set(ch, &merge_buf, total);
// NEW:
events.recordMutationWithOldValue(ch, "characterData", null, null, null, old_cur);
// then the removal, already present:
lxb_dom_node_remove(next);
events.recordMutationChildList(node, null, next, prev_s, after);
```

Two records per merge: one characterData on `ch`, one childList on `node` for the removed sibling. This matches spec §4.4.2 and what WPT `MutationObserver-childList.html#normalize` expects.

**Second normalize function**: `normalizeNode` at `dom_node.zig:1792–1841` is a "silent" variant called from internal C-facing code. Per the comment at 1790–1791, it deliberately skips MO. Confirm no JS-facing entrypoint calls it, then leave alone. Grep for `normalizeNode(` (no `WithMutations`) confirms it is only invoked internally by Range boundary updates in `dom_document.zig`. OK.

---

## Gap 5: `attributeFilter` completeness

**Current QuickJS path**: `events.zig:2454–2461` defines `matchesAttributeFilter`, and `events.zig:2687` gates records on it inside `recordMutationFull`. This is correct and complete for callers that go through `recordMutationFull`.

**Gaps**:

1. **Kotori-VM path has NO filter**. `kotori_dom.zig:6345` (`recordAttributeMutation`) never consults `attribute_filter`. When a kotori-observed element's attribute is set, the filter is ignored. Fix: add filter field to `MoTarget` (the struct near `kotori_dom.zig:374` observer storage), copy it during `observe()`, and gate inside the new consolidated helper.

2. **Namespace gating**: §4.3.3 step 3.3 says attributeFilter matches are restricted to namespace == null. The current QuickJS `matchesAttributeFilter` ignores namespace — if an `xlink:href` attribute matches filter `["href"]`, a record fires. Spec forbids this. Fix in `events.zig:2687`:

   ```zig
   // events.zig:2687 — current
   if (std.mem.eql(u8, mutation_type, "attributes") and !t.matchesAttributeFilter(attr_name)) continue;
   // proposed
   if (std.mem.eql(u8, mutation_type, "attributes")) {
       if (t.attribute_filter.items.len > 0) {
           if (attr_namespace != null) continue;           // filter only matches null-ns
           if (!t.matchesAttributeFilter(attr_name)) continue;
       }
   }
   ```

3. **setAttribute without a caller connected-check bypass**: `dom_element.zig:228` wraps the `recordMutationWithOldValue` call in `if (api.isElementConnected(elem))`. That's wrong — §4.3.3 fires observers based on observer-target reachability, not document-connectedness of the mutating element. An observer on a detached subtree's root MUST still fire for setAttribute inside that subtree. Fix: remove the `isElementConnected` gate; the `isDescendant` walk inside `recordMutationFull` handles reachability correctly.

---

## Gap 6: `attributeOldValue` in removeAttribute

**Current**: `dom_element.zig:619–653`. `elementRemoveAttribute` correctly captures `old_val` before removal (lines 634–643) and emits `recordMutationWithOldValue(..., "attributes", ..., old_val)` at line 650. **Looks OK**.

**Real gap**: **`toggleAttribute` at `dom_element.zig:672–719` records nothing at all**. Neither the add branch (line 699, 715) nor the remove branch (line 703, 711) calls any `events.recordMutation*` helper. This is the single biggest contributor to `MutationObserver-attributes.html` sitting at 3/21 — toggleAttribute is exercised by many of the 18 failing subtests.

Fix — four record calls, one per branch:

```zig
// dom_element.zig:672 — proposed
pub fn elementToggleAttribute(/* args */) callconv(.c) qjs.JSValue {
    // … existing validation …
    const has = lxb_dom_element_has_attribute(elem, name.ptr, name.len);
    // Capture old value once, up front (only meaningful when 'has' is true)
    var old_val_buf: [4096]u8 = undefined;
    var old_val: ?[]const u8 = null;
    if (has) {
        var ov_len: usize = 0;
        const ov_ptr = lxb_dom_element_get_attribute(elem, name.ptr, name.len, &ov_len);
        if (ov_ptr != null) {
            const cl = @min(ov_len, old_val_buf.len);
            @memcpy(old_val_buf[0..cl], ov_ptr.?[0..cl]);
            old_val = old_val_buf[0..cl];
        }
    }
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);

    if (argc >= 2) {
        const force = qjs.JS_ToBool(c, args[1]) > 0;
        if (force and !has) {
            _ = lxb_dom_element_set_attribute(elem, name.ptr, name.len, "", 0);
            events.recordMutationWithOldValue(node, "attributes", null, null, name, null);
            setDomDirty();
            return quickjs.JS_NewBool(true);
        } else if (!force and has) {
            _ = lxb_dom_element_remove_attribute(elem, name.ptr, name.len);
            events.recordMutationWithOldValue(node, "attributes", null, null, name, old_val);
            setDomDirty();
            return quickjs.JS_NewBool(false);
        }
        return quickjs.JS_NewBool(has);
    }

    if (has) {
        _ = lxb_dom_element_remove_attribute(elem, name.ptr, name.len);
        events.recordMutationWithOldValue(node, "attributes", null, null, name, old_val);
        setDomDirty();
        return quickjs.JS_NewBool(false);
    } else {
        _ = lxb_dom_element_set_attribute(elem, name.ptr, name.len, "", 0);
        events.recordMutationWithOldValue(node, "attributes", null, null, name, null);
        setDomDirty();
        return quickjs.JS_NewBool(true);
    }
}
```

Also verify that the kotori-VM `nativeToggleAttribute` (registered at `kotori_dom.zig:716`) records. Reading is pending — if it bypasses MO too, apply the same pattern.

---

## Caller audit matrix

Format: `callsite → current state → required change`.

| # | Mutation site | Current file:line | State | Change |
|---|---|---|---|---|
| 1 | `appendChild` | `dom_node.zig:858, 884` | emits `recordMutationChildListMulti` / `recordMutationChildList` with prev/next siblings | **OK** |
| 2 | `insertBefore` | `dom_node.zig:1127, 1169` | emits with prev/next siblings | **OK** |
| 3 | `removeChild` | `dom_node.zig:961` | `recordMutationChildList(parent, null, child, rm_prev, rm_next)` | **OK** |
| 4 | `replaceChild` | `dom_node.zig:1324, 1327, 1337, 1344` | emits for add + remove | **OK** |
| 5 | `replaceChildren` batching | `events.zig:2483–2503` (suppression) + `dom_node.zig:2427+` | bulk record at end | **OK** |
| 6 | `setAttribute` | `dom_element.zig:226–230` | gated by `isElementConnected` (bug) | **FIX**: remove `isElementConnected` gate (Gap 5.3) |
| 7 | `removeAttribute` | `dom_element.zig:648–650` | emits with old_val | **OK** (Gap 6 is really about toggleAttribute) |
| 8 | `toggleAttribute` | `dom_element.zig:672–719` | **no MO recording** | **FIX**: 4 record calls (Gap 6) |
| 9 | `setAttributeNS` | `dom_element.zig:434–436, 466–488` | emits `recordMutationAttrNS` (ns + local_name + old_val) | **OK** |
| 10 | `removeAttributeNS` | `dom_element.zig:597–608` | emits `recordMutationAttrNS` | **OK** |
| 11 | `id=`, `className=` setters | `dom_element.zig:116, 161` | emit with old_val | **OK** |
| 12 | `classList.add/remove/toggle` | `dom_element.zig:874, 970, 1149` | emit with old_class_copy | **OK** |
| 13 | `textContent=` on Element | `kotori_dom.zig:329, 338, 361` | single-node added/removed (loses N−1 removed) | **FIX**: collect all removed, use `recordMutationChildListBulk` (Gap 2) |
| 14 | `textContent=` on Text/Comment/PI | `kotori_dom.zig:309, 316` | emits characterData+old_value | **OK** |
| 15 | `CharacterData.data=` setter | `dom_text.zig:57, 63` | emits characterData+old_value | **OK** (code path goes via QJS setter) |
| 16 | Kotori `data=` setter (VM path) | `kotori_dom.zig` data setter (~line 4500s) | **investigate**: same polyfill story? | **AUDIT** — confirm that kotori data setter calls `recordCharDataMutation` |
| 17 | `appendData` (kotori native) | `kotori_dom.zig:4578–4589` | **no MO recording** | **FIX**: snapshot old_text, call `recordCharDataMutation` (Gap 3b) |
| 18 | `deleteData` (kotori native) | `kotori_dom.zig:4591–4613` | **no MO recording** | **FIX**: same pattern |
| 19 | `insertData` (kotori native) | `kotori_dom.zig:4615–4635` | **no MO recording** | **FIX**: same pattern |
| 20 | `replaceData` (kotori native) | `kotori_dom.zig:4637–4661` | **no MO recording** | **FIX**: same pattern |
| 21 | `substringData` | `kotori_dom.zig:4663–4678` | read-only, no mutation | **N/A** |
| 22 | `appendData`/… polyfill | `dom_api.zig:4636–4640` | routes through `this.data=` → QJS setter → records | **OK** |
| 23 | `normalize()` — merge target data change | `dom_node.zig:1771` | **no characterData record for the surviving text node** | **FIX**: snapshot + `recordMutationWithOldValue(ch, "characterData", …, old_cur)` (Gap 4) |
| 24 | `normalize()` — child removal | `dom_node.zig:1746, 1760, 1775` | emits childList with prev/next siblings | **OK** |
| 25 | `innerHTML=` setter | `dom_serialize.zig:126–154` | bulk record with all added/removed, siblings = `null, null` | **OK** — siblings are null per spec "replace all" |
| 26 | `outerHTML=` setter | `dom_serialize.zig:205, 221` | bulk record on parent | **OK** |
| 27 | `insertAdjacentHTML` | `dom_serialize.zig:228–268` | **no MO recording** | **FIX**: record childList bulk for added nodes at target position (spec: §3.6 fragment insertion is a mutation) |
| 28 | Kotori-VM attribute filter | `kotori_dom.zig:6345–6387` (`recordAttributeMutation`) | no `attribute_filter` field consulted | **FIX**: add filter member to MO target, gate in helper (Gap 5.1) |
| 29 | Kotori-VM childList siblings | `kotori_dom.zig:6287` (`recordChildListMutation`) | accepts prev/next but most callers pass null | **AUDIT**: ensure each caller threads real siblings (list pending: grep `recordChildListMutation(`) |
| 30 | attributeFilter namespace gate | `events.zig:2687` | filter applies regardless of namespace | **FIX**: skip filter-matching when attr_namespace != null (Gap 5.2) |

Items 6, 8, 13, 17–20, 23, 27, 28, 30 are the **10 required code changes**. Items marked AUDIT (16, 29) need a quick check and possibly another change.

---

## Test plan

### Unit-level (Zig tests in `src/js/events_test.zig` if missing, else extend)

1. Observer on parent with `{subtree:true, attributes:true}` — setAttribute on grandchild fires one record with correct target.
2. Observer on parent with `{subtree:false, attributes:true}` — setAttribute on child fires **zero** records.
3. Observer with `attributeFilter:["foo"]` — setAttribute("bar", …) fires zero, setAttribute("foo", …) fires one.
4. Observer with `attributeFilter:["href"]` — setAttributeNS("xlink", "href", …) fires **zero** (namespace gate).
5. `toggleAttribute("foo")` on observed element — fires one attributes record with old_value=null (add branch), then one with old_value="" (remove branch).
6. `appendData` on observed Text (characterData, characterDataOldValue=true) — one record with correct oldValue.
7. `normalize()` on a parent with three consecutive text nodes — exactly one characterData record on the survivor + two childList records for the removed siblings.
8. `innerHTML=` setter — one childList record with `addedNodes.length == N_new` and `removedNodes.length == N_old`, siblings both null.

### WPT (acceptance)

Run:
```bash
cd ~/suzume && zig build -Doptimize=ReleaseSafe 2>&1 | tail -5
./tests/wpt/run_wpt.sh dom/nodes/MutationObserver-childList.html dom/nodes/MutationObserver-attributes.html dom/nodes/MutationObserver-characterData.html 2>&1 | tail -20
```

Expected deltas:
- `MutationObserver-childList.html`: 7/25 → 25/25 (+18)
- `MutationObserver-attributes.html`: 3/21 → 21/21 (+18)
- `MutationObserver-characterData.html`: 0/8 → 8/8 (+8)
- **Total: +44** — matches roadmap target.

### Regression sentinel

Before merging Layer 1B, also re-run:
- `dom/nodes/Document-createElement.html`
- `dom/nodes/Element-setAttribute.html`
- `dom/nodes/Node-replaceChild.html`
- `dom/nodes/Node-normalize.html`

No regressions permitted.

---

## Risk / regression

1. **Memory growth** — 10 new record emission sites, each allocating a `MutationRecord` + attribute-name copy + old-value copy. On pages that thrash attributes in a tight loop without draining observers, this can OOM on the 512 MB RPi Zero 2W target. Mitigation: `flushMutationObservers` is already called from microtask checkpoints (`web_api.zig:703`). No new allocation rate issues beyond what spec mandates.
2. **Layer 2A overlap** — AbortSignal work also edits `events.zig`. The 1B changes are confined to the MutationObserver block (`events.zig:2416–3029`), while 2A edits the addEventListener path (`events.zig:162` region). Git merge: should be clean. Dispatch 1B first since 2A depends on a stable event infrastructure.
3. **Kotori-VM consolidation** — unifying three kotori MO helpers into one is a refactor, not a spec fix. If time-boxed, the minimum viable change is just (a) add attributeFilter gate to `recordAttributeMutation` and (b) add the four CharacterData natives. Consolidation can be deferred.
4. **Bulk-record helper duplication** — the three `recordMutation{,ChildList}{,Bulk,Multi,RemovedMulti}` variants in `events.zig:2516–2642` each re-implement the gating loop. If we later add a new option (e.g., `useScopedRegistry` for SSR), we'd need to touch three loops. Documented in "Out of scope" — track as tech debt, address in a future cleanup pass.
5. **Old-value buffer cap** — all the "capture old value" sites use 4 KiB stack buffers. For attribute values or text nodes exceeding 4 KiB, we silently truncate. Per WPT, this is fine for every subtest in the target set (they use short values). For correctness, a later pass should spill to heap (pattern in `dom_element.zig:795`).

---

## Acceptance criteria

1. `zig build` green with no new warnings.
2. New Zig unit tests in `src/js/events_test.zig` (or new `src/js/mutation_observer_test.zig`) — all passing.
3. WPT deltas:
   - `MutationObserver-childList.html`: ≥ 24/25 (1 subtest tolerance for edge cases outside scope)
   - `MutationObserver-attributes.html`: ≥ 20/21
   - `MutationObserver-characterData.html`: 8/8
   - Combined: ≥ 44 additional subtests passing.
4. No regressions in the sentinel tests listed above (Document-createElement, Element-setAttribute, Node-replaceChild, Node-normalize).
5. Code review checklist:
   - Every mutation site in the audit matrix reviewed.
   - Both QuickJS and kotori-VM paths covered (where applicable).
   - No `isElementConnected` gate around `recordMutation*` calls.
   - `attributeFilter` is ns-null only.

---

## Out of scope

- **Consolidation of `recordMutation{,ChildList}{,Bulk,Multi,RemovedMulti}` into one helper** — deferred to a future refactor pass; current duplication is correct, just redundant.
- **`Node.nodeValue=` setter MO recording** — currently only a getter exists (`dom_text.zig:70`); add setter in Layer 1F (Range/TreeWalker polish) since that layer already touches Text node plumbing.
- **Heap-spill for old-value buffers > 4 KiB** — behind a later correctness pass; no WPT test in the target set exceeds 4 KiB.
- **MutationRecord prototype chain** (so `records[0] instanceof MutationRecord` returns true) — already handled by the existing stub at `dom_api.zig:4373`. If 1C (createEvent compat) surfaces issues, fix there.
- **Shadow DOM composed-path interaction** — MutationObserver crossing shadow boundaries is forbidden by spec §4.3.3 step 3.1 (subtree does not cross a ShadowRoot). Verify via the existing shadow_root.zig path; not a 1B deliverable.
- **AbortSignal `{signal}` on observe()** — MutationObserver has no signal option in DOM 2024 spec; listener AbortSignal is Layer 2A's concern.

---

## Open questions

Append to `.omc/plans/open-questions.md`:

- **[1B-Q1]** Does the kotori-VM `data=` setter route through `recordCharDataMutation`? Audit needed before executor starts — blocks Gap 3b if it does (would mean only the 4 native methods need fixing) vs. doesn't (would mean the data= setter needs fixing too).
- **[1B-Q2]** `insertAdjacentHTML` (audit matrix #27) — is the missing MO recording in scope for this layer or deferred? If WPT `MutationObserver-childList.html` exercises it, it's in-scope. Confirm with a quick grep of the WPT test source before starting.
- **[1B-Q3]** Old-value buffer truncation at 4 KiB — acceptable for now, or lift to heap-backed ArrayList in this layer? Current spec recommends deferring; confirm with critic.
