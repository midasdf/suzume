# Layer 1B — MutationObserver Completion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the six concrete MutationObserver recording gaps that block +44 WPT subtests across `dom/nodes/MutationObserver-childList.html` (7/25 → 25/25), `-attributes.html` (3/21 → 21/21), and `-characterData.html` (0/8 → 8/8). No helper is being rebuilt — the central `recordMutationFull` helper already exists at `src/js/events.zig:2665` and already implements the §4.3.3 gating loop correctly (subtree + attributeFilter + oldValue). The work is **caller-side**: fix 6 bugs/bypasses in `dom_element.zig`, `kotori_dom.zig`, and `dom_node.zig`.

**Architecture:**
- QuickJS MO path: `recordMutationFull` at `events.zig:2665` + thin wrappers (`recordMutation`, `recordMutationChildList`, `recordMutationWithOldValue`, `recordMutationAttrNS`). Keep these; only **callers** change.
- kotori-VM MO path: parallel implementation at `kotori_dom.zig:6286–6430` (`recordChildListMutation`, `recordAttributeMutation`, `recordCharDataMutation`). This path has a missing `attributeFilter` gate that must be brought to parity.
- No new wrapper helpers are introduced in this layer (deferred to a future consolidation pass — see spec §Out-of-scope and Task 0 open-questions).
- All 6 fixes are additive; each is behind an independent commit that keeps `zig build test` green at every HEAD.

**Tech Stack:** Zig 0.15.2, lexbor (DOM), kotori JS engine (in-tree at `src/js/kotori/`), QuickJS, WPT (Web Platform Tests).

**Spec:** `docs/superpowers/specs/2026-04-19-kotori-1B-mutation-observer-design.md`
**Parent roadmap:** `docs/superpowers/specs/2026-04-17-kotori-suzume-wpt-100-roadmap.md` (Layer 1B)

---

## File Structure

### Files to modify
- `src/js/events.zig` — used for reference reads only (the helper at L2665 is assumed correct); no edits expected unless the kotori-parity refactor in Task 4 chooses to mirror a local helper into this file. Layer 2A also touches this file, but in a disjoint region (`L162` addEventListener); merge risk is addressed by landing 1B first so 2A rebases.
- `src/js/dom_element.zig` — fix `setAttribute` isElementConnected gate (Task 1); wire `toggleAttribute` MO recording in 4 branches (Task 2).
- `src/js/kotori_dom.zig` — wire `appendData`/`deleteData`/`insertData`/`replaceData` MO recording (Task 3); sync `attributeFilter` gating in `recordAttributeMutation` with the QuickJS side (Task 4); audit+patch `textContent` setter (Task 5).
- `src/js/dom_node.zig` — verify `normalize()` emits `characterData` for the surviving merged text node in addition to the existing `childList` for removed siblings (Task 6).

### Files NOT to modify
- `src/js/events.zig` central helper — it is already correct (see spec §"Central recordMutation helper"). Only Layer 2A changes this file in a disjoint region.
- `src/js/dom_text.zig` — `CharacterData.data` setter already records correctly (spec §Gap 3a / audit matrix row 15).
- `src/js/dom_serialize.zig` — `innerHTML=`/`outerHTML=` already record bulk correctly (audit matrix rows 25/26).
- `src/js/dom_api.zig` — `appendData`/`deleteData`/`insertData`/`replaceData` JS polyfill routes through the Text `data=` setter which already records (audit matrix row 22); only the kotori **native** path is broken.
- `src/js/kotori/vm.zig`, `src/js/kotori/object.zig` — no VM changes needed.

---

## Task 0: P0 Audit — No-Code Gate

**Files:** None modified. Produces audit notes and baseline WPT numbers for reference during subsequent tasks.

**Purpose:** Verify spec assumptions against current HEAD (commit `beb7a4b` was the reference; re-verify at the executor's HEAD). Confirm the central helper still works, confirm the 6 caller bugs are still present, record the WPT baseline for all MO-* files, and copy the 3 open questions into `.omc/plans/open-questions.md`.

This task writes **zero code changes**. Its output is purely informational. Skipping this task risks wasting Tasks 1–6 on stale line numbers.

### Caller audit matrix (authoritative — from spec)

Reference during every subsequent task. Items 6, 8, 13, 17–20, 23, 27, 28, 30 are the **10 required changes**; items 16 and 29 are AUDIT items that may expand scope.

| # | Mutation site | File:line | State | Layer 1B action |
|---|---|---|---|---|
| 1 | `appendChild` | `dom_node.zig:858, 884` | emits with prev/next | **OK** |
| 2 | `insertBefore` | `dom_node.zig:1127, 1169` | emits with prev/next | **OK** |
| 3 | `removeChild` | `dom_node.zig:961` | emits with prev/next | **OK** |
| 4 | `replaceChild` | `dom_node.zig:1324, 1327, 1337, 1344` | emits | **OK** |
| 5 | `replaceChildren` batching | `events.zig:2483–2503` + `dom_node.zig:2427+` | bulk record | **OK** |
| 6 | `setAttribute` | `dom_element.zig:226–230` | gated by `isElementConnected` — **BUG** | **Task 1** |
| 7 | `removeAttribute` | `dom_element.zig:648–650` | emits with old_val | **OK** |
| 8 | `toggleAttribute` | `dom_element.zig:672–719` | **ZERO MO recording** | **Task 2** |
| 9 | `setAttributeNS` | `dom_element.zig:434–488` | emits NS | **OK** |
| 10 | `removeAttributeNS` | `dom_element.zig:597–608` | emits NS | **OK** |
| 11 | `id=`, `className=` setters | `dom_element.zig:116, 161` | emits | **OK** |
| 12 | `classList.add/remove/toggle` | `dom_element.zig:874, 970, 1149` | emits | **OK** |
| 13 | `textContent=` on Element | `kotori_dom.zig:329, 338, 361` | loses N−1 removed children | **Task 5** |
| 14 | `textContent=` on Text/Comment/PI | `kotori_dom.zig:309, 316` | emits characterData | **OK** |
| 15 | `CharacterData.data=` setter | `dom_text.zig:57, 63` | emits | **OK** |
| 16 | Kotori `data=` setter | `kotori_dom.zig` ~L4500s | **AUDIT** | **Task 0.5** |
| 17 | `appendData` (kotori native) | `kotori_dom.zig:4578–4589` | **ZERO** | **Task 3** |
| 18 | `deleteData` (kotori native) | `kotori_dom.zig:4591–4613` | **ZERO** | **Task 3** |
| 19 | `insertData` (kotori native) | `kotori_dom.zig:4615–4635` | **ZERO** | **Task 3** |
| 20 | `replaceData` (kotori native) | `kotori_dom.zig:4637–4661` | **ZERO** | **Task 3** |
| 21 | `substringData` | `kotori_dom.zig:4663–4678` | read-only | **N/A** |
| 22 | `appendData`/… JS polyfill | `dom_api.zig:4636–4640` | routes via `this.data=` | **OK** |
| 23 | `normalize()` — merge target | `dom_node.zig:1771` | **no characterData record** | **Task 6** |
| 24 | `normalize()` — child removal | `dom_node.zig:1746, 1760, 1775` | emits childList | **OK** |
| 25 | `innerHTML=` setter | `dom_serialize.zig:126–154` | bulk record | **OK** |
| 26 | `outerHTML=` setter | `dom_serialize.zig:205, 221` | bulk record | **OK** |
| 27 | `insertAdjacentHTML` | `dom_serialize.zig:228–268` | **no recording** | **Open Q 1B-Q2** (likely deferred) |
| 28 | Kotori-VM attribute filter | `kotori_dom.zig:6345–6387` | no attributeFilter consulted | **Task 4** |
| 29 | Kotori-VM childList siblings | `kotori_dom.zig:6287` | most callers pass null | **Task 0.6 AUDIT** |
| 30 | attributeFilter namespace gate | `events.zig:2687` | filter applies regardless of ns | **Task 4** (QJS side) |

### Steps

- [ ] **Step 0.1: Verify central `recordMutationFull` helper at `events.zig:2665`**

Run:
```bash
cd ~/suzume
grep -n "^fn recordMutationFull" src/js/events.zig
```

Expected: exactly one match, line number close to `2665`. Record the actual line into `/tmp/p0-audit-1B.md`. If the signature differs from the spec (target, mutation_type, added, removed, attr_name, attr_namespace, old_value, prev_sib, next_sib), stop and re-baseline the plan.

Read the gating loop body at the recorded line:
```bash
sed -n '2665,2735p' src/js/events.zig
```

Confirm:
- line ~2679 — subtree test `(t.node == target) or (t.subtree and isDescendant(target, t.node))`
- line ~2683 — type test `want = t.child_list | t.attributes | t.character_data`
- line ~2687 — `matchesAttributeFilter` call
- lines ~2713–2719 — oldValue capture gated by `attribute_old_value` / `character_data_old_value`

Note any drift from the spec. Drift invalidates Task 4's "mirror the QJS logic" approach.

- [ ] **Step 0.2: Verify `toggleAttribute` ZERO-recording bug at `dom_element.zig:672–719`**

Run:
```bash
grep -n "fn elementToggleAttribute\b" src/js/dom_element.zig
sed -n '672,720p' src/js/dom_element.zig
```

Expected: 4 mutation branches (force=true+has=false, force=true+has=true, force=false+has=true, force=false+has=false + the no-force variants) and **zero** calls to any `events.recordMutation*`. If a call already exists, the gap has been partially closed elsewhere — re-read the function and update Task 2 to only fill the remaining branches.

- [ ] **Step 0.3: Verify CharacterData natives ZERO-recording bug at `kotori_dom.zig:4578–4661`**

Run:
```bash
grep -n "fn nativeAppendData\|fn nativeDeleteData\|fn nativeInsertData\|fn nativeReplaceData" src/js/kotori_dom.zig
```

Record the 4 line numbers. For each, read the body and confirm it calls `lxb_dom_node_text_content_set` directly with **no** subsequent `recordCharDataMutation` call. If any one already records, narrow Task 3 scope to the remaining ones.

```bash
grep -c "recordCharDataMutation\|recordMutationFull" src/js/kotori_dom.zig | head -5
```

- [ ] **Step 0.4: Verify both QuickJS + kotori MO implementations exist**

Run:
```bash
grep -n "^fn recordChildListMutation\|^fn recordAttributeMutation\|^fn recordCharDataMutation" src/js/kotori_dom.zig
grep -n "^fn recordMutationFull\|^fn recordMutation\b\|^fn recordMutationChildList\|^fn recordMutationWithOldValue\|^fn recordMutationAttrNS" src/js/events.zig
```

Expected: 3 matches in `kotori_dom.zig` (lines ~6287, ~6345, ~6390), and 4–6 matches in `events.zig` including `recordMutationFull` at ~L2665.

Task 4 cross-reference — read the `matchesAttributeFilter` logic on both sides:
```bash
sed -n '2454,2461p' src/js/events.zig      # QJS matchesAttributeFilter
sed -n '6345,6390p' src/js/kotori_dom.zig  # kotori recordAttributeMutation (filter absent)
```

Confirm the kotori helper does **not** consult any `attribute_filter` field on its observer target struct (`MoTarget` near `kotori_dom.zig:374`).

- [ ] **Step 0.5: AUDIT — kotori `data=` setter (matrix row 16)**

Run:
```bash
grep -n "setter.*data\|\"data\".*setter\|setData\b" src/js/kotori_dom.zig | head -20
```

Locate the Text/Comment/PI `data=` setter (typical filename lines 4500–4570). Read:
```bash
sed -n '4490,4580p' src/js/kotori_dom.zig
```

Confirm it calls `recordCharDataMutation` (or equivalent). If YES → Task 3 only needs to fix the 4 natives. If NO → Task 3 scope expands to include the setter.

Record finding in `/tmp/p0-audit-1B.md`.

- [ ] **Step 0.6: AUDIT — kotori childList sibling threading (matrix row 29)**

Run:
```bash
grep -n "recordChildListMutation(" src/js/kotori_dom.zig
```

For each callsite, check whether the `prev_sib` and `next_sib` arguments (4th and 5th positional) are `null` or actual sibling pointers. Tally:
- `# of callsites passing null, null`: _______
- `# of callsites passing real siblings`: _______

If more than 2 callsites pass `null, null`, Task 5 (textContent) + a small follow-up in Task 6 (normalize) may need to also patch sibling threading. Note findings.

- [ ] **Step 0.7: Baseline MO-* WPT measurement**

Run:
```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
  dom/nodes/MutationObserver-childList.html \
  dom/nodes/MutationObserver-attributes.html \
  dom/nodes/MutationObserver-characterData.html \
  dom/nodes/MutationObserver-document.html \
  dom/nodes/MutationObserver-inner-outer.html 2>&1 | tee /tmp/wpt-1B-baseline.txt
```

Record pass/fail per file. Expected baseline from roadmap (re-confirm):
- `MutationObserver-childList.html`: 7/25
- `MutationObserver-attributes.html`: 3/21
- `MutationObserver-characterData.html`: 0/8
- `MutationObserver-document.html`: baseline to be recorded (not previously tracked)
- `MutationObserver-inner-outer.html`: baseline to be recorded

Also capture dom/nodes sentinel totals (for regression protection in Task 7):
```bash
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
  dom/nodes/Document-createElement.html \
  dom/nodes/Element-setAttribute.html \
  dom/nodes/Node-replaceChild.html \
  dom/nodes/Node-normalize.html 2>&1 | tee /tmp/wpt-1B-sentinels.txt
```

- [ ] **Step 0.8: Copy open questions to `.omc/plans/open-questions.md`**

Create `.omc/plans/` if missing:
```bash
mkdir -p /home/midasdf/suzume/.omc/plans
```

Append the 3 spec open questions to `.omc/plans/open-questions.md`:

```markdown
## Layer 1B MutationObserver Completion - 2026-04-19

- [ ] **[1B-Q1]** Does the kotori-VM `data=` setter route through `recordCharDataMutation`? — Gate answer from P0 Step 0.5 before Task 3; blocks whether Task 3 scope is 4 natives only or 4 natives + setter.
- [ ] **[1B-Q2]** `insertAdjacentHTML` (audit matrix #27) — is this in scope for Layer 1B or deferred? — Needs a grep of WPT `MutationObserver-childList.html` source for `insertAdjacentHTML` invocation. If the test exercises it, in scope; otherwise defer to Layer 1F.
- [ ] **[1B-Q3]** Old-value buffer truncation at 4 KiB — acceptable for Layer 1B, or promote to heap-backed ArrayList now? — Current spec defers; confirm with critic before shipping Task 7.
```

If `.omc/plans/open-questions.md` already exists, **append** to it with the `## Layer 1B …` header. Do not overwrite.

- [ ] **Step 0.9: Write audit notes**

Produce `/tmp/p0-audit-1B.md` containing:
- Verified line numbers (adjusted vs. spec reference `beb7a4b`)
- Findings from Steps 0.5 and 0.6 (AUDIT items 16 and 29)
- Baseline WPT counts per file
- Any drift in `recordMutationFull` signature or gating loop
- Any tasks whose scope changes as a result (e.g., "Task 3 scope expanded to include `data=` setter because P0 Step 0.5 found it bypasses MO")

No git commit for this task — P0 is a no-code gate.

---

## Task 1: Fix `setAttribute` `isElementConnected` Gate Bug

**Files:**
- Modify: `src/js/dom_element.zig` — remove the `isElementConnected` gate around `recordMutationWithOldValue` at L228.

**Purpose:** DOM §4.3.3 says mutation observers fire based on **observer-target reachability** (walked by `isDescendant` inside `recordMutationFull`), not on whether the mutating element is connected to the top-level document. The current gate at `dom_element.zig:228` incorrectly drops records when an observer is registered on a detached subtree root.

This unblocks subtests in `MutationObserver-attributes.html` that deliberately observe a disconnected subtree.

- [ ] **Step 1.1: Write failing unit test for detached subtree observer**

Append to `src/js/events_test.zig` (or create `src/js/mutation_observer_test.zig` if the former does not exist — check with `ls src/js/*test.zig`):

```zig
test "MO on detached subtree root fires for setAttribute inside subtree" {
    // Build a detached element tree: root <- child
    // Observe root with {subtree:true, attributes:true}
    // Call setAttribute on child
    // Expect exactly 1 record
    // (Test harness detail: mirror the pattern used by any existing MO test in the repo.)
    //
    // PROBE first — if events_test.zig has no existing MO scaffolding,
    // author this test via a minimal inline VM + document setup based
    // on the pattern in tests/test_kotori_dom.zig.
}
```

- [ ] **Step 1.2: Run test — should FAIL under current HEAD**

```bash
cd ~/suzume && zig build test 2>&1 | grep -A 3 "MO on detached subtree"
```

Expected: 0 records observed instead of 1.

- [ ] **Step 1.3: Read the current gate at `dom_element.zig:228`**

```bash
sed -n '220,235p' src/js/dom_element.zig
```

Expected current pattern (verify exact text before editing):

```zig
// dom_element.zig — current L226-L230 (approximate)
if (api.isElementConnected(elem)) {
    events.recordMutationWithOldValue(node, "attributes", null, null, name, attr_namespace, old_val);
}
```

- [ ] **Step 1.4: Remove the gate**

Replace the `if (api.isElementConnected(elem))` block with the unconditional call:

```zig
// dom_element.zig — proposed L226-L230
events.recordMutationWithOldValue(node, "attributes", null, null, name, attr_namespace, old_val);
```

(The `isDescendant` walk inside `recordMutationFull` correctly handles observer-target reachability regardless of document-connectedness.)

- [ ] **Step 1.5: Run test — should PASS**

```bash
cd ~/suzume && zig build test 2>&1 | grep -A 3 "MO on detached subtree"
```

Expected: record count = 1.

- [ ] **Step 1.6: Regression check — `Element-setAttribute.html` still passes**

```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/nodes/Element-setAttribute.html 2>&1 | tail -10
```

Expected: pass count ≥ baseline from `/tmp/wpt-1B-sentinels.txt`.

### Acceptance criteria
- [ ] New test `MO on detached subtree root fires for setAttribute inside subtree` passes.
- [ ] `zig build test` green.
- [ ] `Element-setAttribute.html` pass count unchanged or improved.

- [ ] **Step 1.7: Commit**

```bash
cd ~/suzume
git add src/js/dom_element.zig src/js/events_test.zig
git commit -m "$(cat <<'EOF'
fix(dom): remove isElementConnected gate around setAttribute MO recording (DOM §4.3.3)

MutationObserver reachability is determined by the isDescendant walk
inside recordMutationFull (events.zig:2679), not by whether the
mutating element is attached to the top-level document. The
isElementConnected gate at dom_element.zig:228 incorrectly dropped
records for observers registered on detached subtree roots.

Adds regression test: observer on detached root with {subtree:true,
attributes:true} must fire when a child's attribute is set.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Wire `toggleAttribute` MO Recording (4 Branches)

**Files:**
- Modify: `src/js/dom_element.zig` — add `recordMutationWithOldValue` calls to all 4 branches of `elementToggleAttribute` at L672–L719.

**Purpose:** Per the audit matrix row 8, `toggleAttribute` emits **zero** MutationRecords today across all 4 branches (force=true/has=false, force=true/has=true, implicit-remove, implicit-add). This is the single biggest contributor to `MutationObserver-attributes.html` failing at 3/21.

Also audit the kotori-VM mirror (`nativeToggleAttribute` registered at `kotori_dom.zig:716`) and apply the same fix if it bypasses MO.

- [ ] **Step 2.1: Write failing test — add branch**

Append to `src/js/events_test.zig`:

```zig
test "toggleAttribute add branch emits one attributes record" {
    // Build <div>, observe with {attributes:true, attributeOldValue:true}.
    // Call el.toggleAttribute("foo") (no force).
    // Expect exactly 1 record with type=attributes, attributeName="foo",
    // oldValue=null (attribute didn't exist before).
}

test "toggleAttribute remove branch emits one attributes record with old value" {
    // Build <div foo="bar">, observe same options.
    // Call el.toggleAttribute("foo").
    // Expect 1 record with oldValue="bar".
}

test "toggleAttribute(force=true) on existing attr is a no-op — zero records" {
    // Build <div foo="bar">, observe.
    // Call el.toggleAttribute("foo", true).
    // Expect 0 records (no actual mutation).
}

test "toggleAttribute(force=false) on absent attr is a no-op — zero records" {
    // Build <div>, observe.
    // Call el.toggleAttribute("foo", false).
    // Expect 0 records.
}
```

- [ ] **Step 2.2: Run tests — all 4 should FAIL**

```bash
cd ~/suzume && zig build test 2>&1 | grep "toggleAttribute"
```

Expected: first two tests get 0 records (expected 1); last two accidentally pass (no-op matches expectation but for wrong reason). That's acceptable — the assertion is "zero records," which currently holds because *no* records ever fire.

- [ ] **Step 2.3: Read current `elementToggleAttribute` body**

```bash
sed -n '672,720p' src/js/dom_element.zig
```

Confirm structure matches the spec §Gap 6 sketch: 4 mutation branches (with-force true+has=false, with-force false+has=true) and 2 no-op returns + 2 implicit branches (no force + has → remove; no force + !has → add).

- [ ] **Step 2.4: Patch the 4 mutating branches per spec §Gap 6**

Replace the body with the spec's proposed version. Key points:
1. Capture `old_val` via a 4 KiB stack buffer *before* any mutation — mirror pattern at `dom_element.zig:215` / `dom_text.zig:44`.
2. Four `recordMutationWithOldValue` calls — two with `old_val` (remove branches) and two with `null` (add branches).
3. Attribute namespace is always `null` for `toggleAttribute` (spec says attribute namespace for this API is the null namespace).
4. Preserve the `setDomDirty()` calls already present.

Concrete patch (confirm against current code first):

```zig
// dom_element.zig L672 — proposed
pub fn elementToggleAttribute(/* existing args */) callconv(.c) qjs.JSValue {
    // … existing validation …
    const has = lxb_dom_element_has_attribute(elem, name.ptr, name.len);

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
            events.recordMutationWithOldValue(node, "attributes", null, null, name, null, null);
            setDomDirty();
            return quickjs.JS_NewBool(true);
        } else if (!force and has) {
            _ = lxb_dom_element_remove_attribute(elem, name.ptr, name.len);
            events.recordMutationWithOldValue(node, "attributes", null, null, name, null, old_val);
            setDomDirty();
            return quickjs.JS_NewBool(false);
        }
        return quickjs.JS_NewBool(has);
    }

    if (has) {
        _ = lxb_dom_element_remove_attribute(elem, name.ptr, name.len);
        events.recordMutationWithOldValue(node, "attributes", null, null, name, null, old_val);
        setDomDirty();
        return quickjs.JS_NewBool(false);
    } else {
        _ = lxb_dom_element_set_attribute(elem, name.ptr, name.len, "", 0);
        events.recordMutationWithOldValue(node, "attributes", null, null, name, null, null);
        setDomDirty();
        return quickjs.JS_NewBool(true);
    }
}
```

Adjust the argument count of `recordMutationWithOldValue` to match the actual wrapper signature in `events.zig` (it threads through to `recordMutationFull`; verify whether `attr_namespace` is a required positional or omitted from the wrapper).

- [ ] **Step 2.5: Run the 4 unit tests — should PASS**

```bash
cd ~/suzume && zig build test 2>&1 | grep "toggleAttribute"
```

- [ ] **Step 2.6: AUDIT kotori `nativeToggleAttribute`**

```bash
grep -n "nativeToggleAttribute\b" src/js/kotori_dom.zig
```

Read the function body at the matched line. If it bypasses MO (no `recordAttributeMutation` call), apply the same pattern using the kotori-side helper. If it already records, annotate in the commit message.

- [ ] **Step 2.7: Targeted WPT check**

```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/nodes/MutationObserver-attributes.html 2>&1 | tail -15
```

Expected: pass count ≥ 10/21 (toggleAttribute unlocks ~7–10 subtests; remaining ~8 gated by Task 4's attributeFilter fix).

### Acceptance criteria
- [ ] All 4 new `toggleAttribute` unit tests pass.
- [ ] kotori-side audit completed; fix applied if bypass confirmed (else noted).
- [ ] `MutationObserver-attributes.html` pass count improved vs. baseline.
- [ ] `Element-setAttribute.html` unchanged (no regression).

- [ ] **Step 2.8: Commit**

```bash
cd ~/suzume
git add src/js/dom_element.zig src/js/kotori_dom.zig src/js/events_test.zig
git commit -m "$(cat <<'EOF'
fix(dom): wire toggleAttribute MO recording across all 4 branches (DOM §4.3.3)

Previously toggleAttribute at dom_element.zig:672-719 emitted zero
MutationRecords regardless of branch — add/remove with or without
force. This single omission accounted for ~8 subtest failures in
MutationObserver-attributes.html.

Add 4 recordMutationWithOldValue calls:
- force=true && !has    → record with oldValue=null (add)
- force=false && has    → record with oldValue=old (remove)
- no-force, has         → record with oldValue=old (remove)
- no-force, !has        → record with oldValue=null (add)

oldValue captured into 4 KiB stack buffer before mutation (pattern
matches dom_text.zig:44 / dom_element.zig:215). Attribute namespace
always null per spec — toggleAttribute has no NS variant.

If P0 audit found kotori nativeToggleAttribute also bypasses MO,
same pattern applied there via recordAttributeMutation.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Wire CharacterData Native Methods MO Recording

**Files:**
- Modify: `src/js/kotori_dom.zig` — add `recordCharDataMutation` calls to `nativeAppendData` (L4578), `nativeDeleteData` (L4591), `nativeInsertData` (L4615), `nativeReplaceData` (L4637). If P0 Step 0.5 found the `data=` setter also bypasses, include it here.

**Purpose:** Unlocks the full 0/8 → 8/8 in `MutationObserver-characterData.html`. These 4 kotori-native methods call `lxb_dom_node_text_content_set` directly and never touch the MO recording path. The QuickJS polyfill at `dom_api.zig:4636–4640` routes via `this.data=` and thus already records, but the kotori path is dominant in practice (per roadmap Session #6 default).

- [ ] **Step 3.1: Write failing tests (1 per method)**

Append to `src/js/events_test.zig` (or the test file used by the MO tests from Task 1):

```zig
test "appendData fires one characterData record with old value" {
    // Build <div>abc</div>, observe the Text with
    // {characterData:true, characterDataOldValue:true}.
    // Call text.appendData("xyz").
    // Expect 1 record: type=characterData, oldValue="abc", target=text.
}

test "deleteData fires one characterData record" { /* oldValue=pre-delete text */ }
test "insertData fires one characterData record" { /* oldValue=pre-insert text */ }
test "replaceData fires one characterData record" { /* oldValue=pre-replace text */ }
```

- [ ] **Step 3.2: Run tests — all 4 should FAIL**

```bash
cd ~/suzume && zig build test 2>&1 | grep -E "(appendData|deleteData|insertData|replaceData) fires"
```

- [ ] **Step 3.3: Read `nativeAppendData` at the line recorded in P0 Step 0.3**

```bash
sed -n '4578,4595p' src/js/kotori_dom.zig
```

Identify:
- Where `info.text` (the pre-mutation text) is read.
- Where `dom_b.lxb_dom_node_text_content_set(info.node, …)` is called — this is the mutation point.

- [ ] **Step 3.4: Patch `nativeAppendData` — snapshot old text + record**

Use the spec §Gap 3b pattern (4 KiB stack buffer, fall back to heap alloc for texts > 4 KiB as in `dom_element.zig:795–808`):

```zig
fn nativeAppendData(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const info = getCharData(vm, this) orelse return JsValue.undefined_val;
    if (args.len == 0) return error.TypeError;

    // NEW: snapshot old text BEFORE mutation (text_content_set invalidates pointer).
    var old_buf: [4096]u8 = undefined;
    var old_heap: ?[]u8 = null;
    defer if (old_heap) |h| vm.allocator.free(h);
    const old_value: []const u8 = blk: {
        if (info.text.len <= old_buf.len) {
            @memcpy(old_buf[0..info.text.len], info.text);
            break :blk old_buf[0..info.text.len];
        } else {
            const h = try vm.allocator.alloc(u8, info.text.len);
            old_heap = h;
            @memcpy(h, info.text);
            break :blk h;
        }
    };

    // … existing append logic that builds `buf` and calls text_content_set …
    _ = dom_b.lxb_dom_node_text_content_set(info.node, buf.items.ptr, buf.items.len);

    // NEW: record characterData mutation.
    recordCharDataMutation(vm, info.node, old_value);
    return JsValue.undefined_val;
}
```

- [ ] **Step 3.5: Apply the same pattern to `nativeDeleteData`, `nativeInsertData`, `nativeReplaceData`**

Same snapshot-before-mutation + `recordCharDataMutation(vm, info.node, old_value)` post-mutation pattern in each.

- [ ] **Step 3.6: If P0 Step 0.5 found `data=` setter bypass, patch it here too**

Otherwise skip. Annotate in the commit message which scope was taken.

- [ ] **Step 3.7: Run the 4 unit tests — should PASS**

- [ ] **Step 3.8: Targeted WPT check**

```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/nodes/MutationObserver-characterData.html 2>&1 | tail -15
```

Expected: 8/8 (or 7/8 if 1B-Q3 heap-spill variance bites — treat 7/8 as pass for this task; full 8/8 is Task 7's WPT gate).

### Acceptance criteria
- [ ] All 4 new CharacterData native unit tests pass.
- [ ] `MutationObserver-characterData.html` pass count ≥ 7/8.
- [ ] `zig build test` green, no regression in other kotori tests.

- [ ] **Step 3.9: Commit**

```bash
cd ~/suzume
git add src/js/kotori_dom.zig src/js/events_test.zig
git commit -m "$(cat <<'EOF'
fix(kotori): record characterData MO for appendData/deleteData/insertData/replaceData (DOM §4.3.3)

The four kotori-native CharacterData methods at kotori_dom.zig:4578-4661
called lxb_dom_node_text_content_set directly and never routed through
recordCharDataMutation. This single omission accounted for the entire
0/8 on MutationObserver-characterData.html.

Fix: snapshot old text into a 4 KiB stack buffer (spill to heap when
text > 4 KiB, pattern from dom_element.zig:795-808) BEFORE
text_content_set invalidates the lexbor pointer, then record AFTER
the mutation.

The QuickJS dom_api.zig polyfill was already correct because it
routed through `this.data=` → dom_text.zig setter; only the kotori
native path was broken.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: kotori-VM Path `attributeFilter` Parity + Namespace Gate

**Files:**
- Modify: `src/js/kotori_dom.zig` — add `attribute_filter` field to `MoTarget` struct (near L374); populate during `observe()`; gate in `recordAttributeMutation` (L6345–L6387).
- Modify: `src/js/events.zig` — tighten the QuickJS `recordMutationFull` attributeFilter gate at L2687 to apply only when `attr_namespace == null` (spec §Gap 5.2).

**Purpose:** Two distinct but related fixes:
1. **Kotori-parity:** the kotori MO path ignores `attributeFilter` entirely — a kotori-observed element with `{attributeFilter: ["class"]}` fires records for setAttribute("id", …).
2. **QJS namespace-gate:** §4.3.3 step 3.3 restricts `attributeFilter` matches to `attr_namespace == null`. Current QJS code at `events.zig:2687` applies the filter regardless of namespace.

This task touches `events.zig`, overlapping with Layer 2A's territory. The edit is surgical (L2687 range only; 2A edits L162 range). **Land 1B first**, then 2A rebases.

- [ ] **Step 4.1: Write failing tests — kotori attributeFilter**

```zig
test "kotori MO attributeFilter gates records" {
    // Observe with {attributes:true, attributeFilter:["foo"]}.
    // setAttribute("bar", "v"); setAttribute("foo", "v");
    // Expect exactly 1 record (for "foo"), not 2.
    // Run under kotori VM path specifically.
}

test "attributeFilter does not match namespaced attributes (ns gate)" {
    // Observe with {attributes:true, attributeFilter:["href"]}.
    // setAttributeNS("http://www.w3.org/1999/xlink", "href", "...");
    // Expect 0 records.
}
```

- [ ] **Step 4.2: Run tests — both should FAIL**

- [ ] **Step 4.3: Read MoTarget struct near `kotori_dom.zig:374`**

```bash
grep -n "MoTarget\b" src/js/kotori_dom.zig
sed -n '370,400p' src/js/kotori_dom.zig
```

Confirm the struct fields. Currently has `subtree`, `child_list`, `attributes`, `character_data`, `attribute_old_value`, `character_data_old_value` (or equivalent naming); missing `attribute_filter`.

- [ ] **Step 4.4: Add `attribute_filter` field to MoTarget**

```zig
pub const MoTarget = struct {
    node: *lxb.lxb_dom_node_t,
    observer: *MoObserver,
    subtree: bool,
    child_list: bool,
    attributes: bool,
    character_data: bool,
    attribute_old_value: bool,
    character_data_old_value: bool,
    // NEW: attributeFilter gate — empty slice = "no filter, match all".
    attribute_filter: []const []const u8,
    // (existing fields continue)
};
```

- [ ] **Step 4.5: Populate `attribute_filter` in `observe()`**

Locate the MO `observe()` native (grep `nativeMoObserve\|observe.*MoTarget` in `kotori_dom.zig`). Where the options dict is parsed, read `attributeFilter` as a JS array and copy to a `[]const []const u8` owned by the MoTarget. On unobserve, free.

Mirror the QJS side at `events.zig:2416+` — read the same logic for the `attribute_filter` copy pattern.

- [ ] **Step 4.6: Gate `recordAttributeMutation` on the filter**

At `kotori_dom.zig:6345` inside `recordAttributeMutation`, before queuing the record, mirror the QJS logic:

```zig
// In the per-target loop, after the subtree match and attributes flag check:
if (t.attribute_filter.len > 0) {
    var matched = false;
    for (t.attribute_filter) |f| {
        if (std.mem.eql(u8, f, attr_name)) { matched = true; break; }
    }
    if (!matched) continue;
}
```

- [ ] **Step 4.7: QJS namespace-gate fix at `events.zig:2687`**

Read current:

```bash
sed -n '2685,2695p' src/js/events.zig
```

Current (approximate):

```zig
if (std.mem.eql(u8, mutation_type, "attributes") and !t.matchesAttributeFilter(attr_name)) continue;
```

Replace with:

```zig
if (std.mem.eql(u8, mutation_type, "attributes")) {
    if (t.attribute_filter.items.len > 0) {
        if (attr_namespace != null) continue;   // spec §4.3.3 step 3.3 — filter only matches ns=null
        if (!t.matchesAttributeFilter(attr_name)) continue;
    }
}
```

- [ ] **Step 4.8: Run both unit tests — should PASS**

- [ ] **Step 4.9: Targeted WPT**

```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/nodes/MutationObserver-attributes.html 2>&1 | tail -15
```

Expected: combined with Task 2, pass count ≥ 20/21 (one edge-case subtest may stay failing — see spec §Acceptance).

### Acceptance criteria
- [ ] Kotori `attribute_filter` unit test passes.
- [ ] Namespace-gate unit test passes.
- [ ] QJS `events.zig:2687` patch is confined to the filter block — no other logic touched (to minimize merge risk with Layer 2A).
- [ ] `MutationObserver-attributes.html` pass count ≥ 20/21.

- [ ] **Step 4.10: Commit**

```bash
cd ~/suzume
git add src/js/kotori_dom.zig src/js/events.zig src/js/events_test.zig
git commit -m "$(cat <<'EOF'
fix(dom): attributeFilter parity on kotori path + namespace gate on QJS path (DOM §4.3.3 step 3.3)

Two fixes for attributeFilter correctness:

1. kotori_dom.zig: add attribute_filter field to MoTarget (near L374),
   populate it during observe(), and gate recordAttributeMutation at
   L6345 on it. Previously the kotori MO path ignored attributeFilter
   entirely — any attribute mutation fired for observers regardless
   of the filter list.

2. events.zig:2687: restrict QJS attributeFilter matching to
   attr_namespace == null per DOM §4.3.3 step 3.3. Previously
   setAttributeNS("xlink", "href", ...) with filter ["href"] fired
   incorrectly.

Surgical edits to events.zig:2687 to minimize merge risk with
Layer 2A (AbortSignal, events.zig:162 region).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `textContent=` Setter — Collect All Removed Children

**Files:**
- Modify: `src/js/kotori_dom.zig` — patch `elementSetTextContent` at L275–L365 so the childList MutationRecord's `removedNodes` contains **every** detached descendant, not just the first.

**Purpose:** Audit matrix row 13: when an element has N children and `el.textContent = "…"` is called, the loop at L324–L326 removes children one-by-one, and the single `recordMutation(node, "childList", null, null, null)` call at L329 records zero removed children. Same at L344 where only `node.first_child` is captured. Spec §4.3.3 requires `removedNodes` to contain every detached descendant.

This unlocks several subtests in `MutationObserver-childList.html` that assert `removedNodes.length === expected`.

- [ ] **Step 5.1: Write failing test**

```zig
test "textContent setter records childList with ALL removed children" {
    // Build <div><a/><b/><c/></div> (3 children).
    // Observe with {childList:true}.
    // Call div.textContent = "hello".
    // Expect 1 record: type=childList,
    //   addedNodes.length === 1 (the new text node),
    //   removedNodes.length === 3.
}

test "textContent setter with empty string records all removed children" {
    // Build <div><a/><b/></div>, observe.
    // Call div.textContent = "".
    // Expect removedNodes.length === 2, addedNodes.length === 0.
}
```

- [ ] **Step 5.2: Run tests — should FAIL with `removedNodes.length === 1`**

- [ ] **Step 5.3: Read `elementSetTextContent` at L275–L365**

```bash
sed -n '275,370p' src/js/kotori_dom.zig
```

Identify:
- L324–L326 — the remove-all-children loop (for empty/null assignment branch).
- L344 — the `removed_child = node.first_child` single-pointer capture.
- L329, L338, L361 — the three `recordMutation*` call sites.

- [ ] **Step 5.4: Collect child pointers before removing**

Add a local collection helper at the top of the function body (above the branching):

```zig
fn collectChildren(allocator: std.mem.Allocator, node: *lxb.lxb_dom_node_t) ![]*lxb.lxb_dom_node_t {
    var list = std.ArrayList(*lxb.lxb_dom_node_t).init(allocator);
    errdefer list.deinit();
    var ch = node.first_child;
    while (ch) |c| : (ch = c.next) {
        try list.append(c);
    }
    return try list.toOwnedSlice();
}
```

(Mirror the existing pattern near `dom_serialize.zig:126` if it already exports a collection helper — prefer reuse over duplication.)

- [ ] **Step 5.5: Patch the null/empty branch at L324**

```zig
// proposed replacement near L324
const removed = try collectChildren(vm.allocator, node);
defer vm.allocator.free(removed);
while (node.first_child) |child| {
    lxb_dom_node_remove(child);
}
_ = qjs.JS_SetPropertyStr(c, this_val, "__jsChildren", qjs.JS_NewArray(c));
// Emit bulk childList record with full removedNodes list.
events.recordMutationChildListBulk(node, &.{}, removed, null, null);
```

- [ ] **Step 5.6: Patch the string-assignment branch at L344**

Same pattern: collect first, then remove, then emit bulk with `(&.{added_child}, removed, null, null)`.

- [ ] **Step 5.7: Run unit tests — should PASS**

- [ ] **Step 5.8: Regression check**

```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
  dom/nodes/Node-textContent.html \
  dom/nodes/MutationObserver-childList.html 2>&1 | tail -15
```

Expected: `Node-textContent.html` unchanged; `MutationObserver-childList.html` improved.

### Acceptance criteria
- [ ] Both new unit tests pass.
- [ ] `Node-textContent.html` pass count unchanged.
- [ ] No regression in `dom/nodes` dashboard.

- [ ] **Step 5.9: Commit**

```bash
cd ~/suzume
git add src/js/kotori_dom.zig src/js/events_test.zig
git commit -m "$(cat <<'EOF'
fix(kotori): textContent setter records all removed children in childList MO (DOM §4.2.7)

elementSetTextContent at kotori_dom.zig:275-365 emitted a childList
record with removedNodes containing at most 1 entry (either empty
slice at L329 or only node.first_child at L344), while DOM §4.2.7
"replace all" requires removedNodes to contain every detached
descendant.

Fix: collect all child pointers via collectChildren before the
remove loop, then emit via recordMutationChildListBulk with the full
slice. prev/next siblings remain null per spec — the synthesized
"replace all" record does not populate sibling metadata.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `normalize()` — Emit `characterData` Record for Merged Text Survivor

**Files:**
- Modify: `src/js/dom_node.zig` — in `normalizeNodeWithMutations` around L1766–L1775, add a `characterData` record for the surviving text node whose `data` was concatenated, in addition to the existing `childList` record for the removed merged sibling.

**Purpose:** Audit matrix row 23. Per DOM §4.4.2 step 3.1–3.3, each concatenation during `normalize()` is both a childList mutation (removal of the merged sibling from the parent) AND a characterData mutation (the surviving text node's `data` changes from e.g. "foo" to "foobar"). The latter is currently missing.

The second `normalize()` function (`dom_node.zig:1792–1841`, non-MO silent variant) is deliberately skipped per its header comment and is only called from C-facing internal code (verified via spec). Do **not** add recording there.

- [ ] **Step 6.1: Write failing test**

```zig
test "normalize emits characterData record for merged survivor and childList for removed sibling" {
    // Build <div>foo<!--x-->bar</div> — no wait, that has a comment between.
    // Simpler: build <div> with three adjacent text nodes "foo", "bar", "baz" manually
    // via appendChild of createTextNode (so normalize will merge them).
    // Observe div with {subtree:true, childList:true, characterData:true, characterDataOldValue:true}.
    // Call div.normalize().
    // Expect:
    //   - 2 characterData records: one on foo with oldValue="foo" (becomes "foobar"),
    //     then one on foo with oldValue="foobar" (becomes "foobarbaz"). (The normalize
    //     algorithm merges left-to-right, applying two concatenations.)
    //   - 2 childList records: one for the removal of "bar", one for "baz".
    // Total 4 records; assert types in order.
}
```

Exact expected record count/sequence depends on the lexbor iteration order in `normalizeNodeWithMutations` — use the existing childList records as an oracle: read the current test output, count the childList records, then the expected characterData count equals that number.

- [ ] **Step 6.2: Run test — should FAIL with 0 characterData records observed**

- [ ] **Step 6.3: Read `normalizeNodeWithMutations` at L1720–L1787**

```bash
sed -n '1720,1790p' src/js/dom_node.zig
```

Locate:
- L1746 — existing `recordMutationChildList` for empty text removal.
- L1760, L1775 — existing childList records.
- L1771 — `lxb_dom_node_text_content_set(ch, &merge_buf, total)` — the actual data concatenation on the survivor.

- [ ] **Step 6.4: Snapshot old data, emit characterData record**

Before L1771, capture the survivor's pre-merge text. After L1771, emit the record:

```zig
// dom_node.zig — proposed addition near L1766
var old_cur_buf: [4096]u8 = undefined;
const oc_len = @min(cur_len, old_cur_buf.len);
if (cur_ptr) |cp| @memcpy(old_cur_buf[0..oc_len], cp[0..oc_len]);
const old_cur = old_cur_buf[0..oc_len];

// Existing merge (preserved):
_ = lxb_dom_node_text_content_set(ch, &merge_buf, total);

// NEW: characterData record on the surviving text node.
events.recordMutationWithOldValue(ch, "characterData", null, null, null, null, old_cur);

// Existing removal + childList record (preserved):
lxb_dom_node_remove(next);
events.recordMutationChildList(node, null, next, prev_s, after);
```

(Adjust `recordMutationWithOldValue` argument count to match wrapper signature — see Task 2 note.)

- [ ] **Step 6.5: Run test — should PASS**

- [ ] **Step 6.6: Regression check `Node-normalize.html`**

```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/nodes/Node-normalize.html 2>&1 | tail -10
```

Expected: pass count ≥ baseline from `/tmp/wpt-1B-sentinels.txt`.

### Acceptance criteria
- [ ] New `normalize` unit test passes.
- [ ] `Node-normalize.html` pass count unchanged or improved (no regression).
- [ ] Silent `normalizeNode` variant at L1792–L1841 is NOT modified (intentionally — it is non-MO per header comment).

- [ ] **Step 6.7: Commit**

```bash
cd ~/suzume
git add src/js/dom_node.zig src/js/events_test.zig
git commit -m "$(cat <<'EOF'
fix(dom): normalize emits characterData MO for merged text survivor (DOM §4.4.2)

normalizeNodeWithMutations at dom_node.zig:1720-1787 already emitted
childList records for each removed merged sibling, but per DOM §4.4.2
step 3.1-3.3 each concatenation is ALSO a characterData mutation on
the surviving text node (its `data` changes from e.g. "foo" to
"foobar").

Fix: snapshot cur_ptr[0..cur_len] into a 4 KiB stack buffer before
text_content_set (line 1771), then emit
recordMutationWithOldValue(ch, "characterData", ..., old_cur) before
the removal + childList record.

The non-MO silent normalizeNode variant at L1792-L1841 is
intentionally left alone (its header comment documents this;
internal C-facing Range boundary updates only).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: WPT Verification + Final Gate Sign-off

**Files:** None modified. Produces verification evidence.

**Purpose:** Run the full WPT matrix 3 times (stability check), compute delta vs. P0 baseline, verify +44 subtest target is met, dispatch verifier agent in separate context for APPROVED/REJECTED sign-off.

- [ ] **Step 7.1: Run Gate A — 5 MO target files**

```bash
cd ~/suzume
for run in 1 2 3; do
  TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
    dom/nodes/MutationObserver-childList.html \
    dom/nodes/MutationObserver-attributes.html \
    dom/nodes/MutationObserver-characterData.html \
    dom/nodes/MutationObserver-document.html \
    dom/nodes/MutationObserver-inner-outer.html 2>&1 | tee /tmp/wpt-1B-gate-a-run$run.txt
done
```

Verify pass counts identical across 3 runs; investigate flakiness if not.

Expected deltas (vs. `/tmp/wpt-1B-baseline.txt`):
- `MutationObserver-childList.html`: +18 (7 → ≥24)
- `MutationObserver-attributes.html`: +17–18 (3 → ≥20)
- `MutationObserver-characterData.html`: +7–8 (0 → ≥7)
- **Total: ≥ +44**

Spec §Acceptance tolerates 1 subtest slippage per file (see spec §Acceptance).

- [ ] **Step 7.2: Run Gate B — sentinel regression check**

```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
  dom/nodes/Document-createElement.html \
  dom/nodes/Element-setAttribute.html \
  dom/nodes/Node-replaceChild.html \
  dom/nodes/Node-normalize.html 2>&1 | tee /tmp/wpt-1B-gate-b.txt
```

Verify: every sentinel pass count ≥ `/tmp/wpt-1B-sentinels.txt` baseline. Any regression blocks the commit.

- [ ] **Step 7.3: Run Gate C — dom/nodes dashboard totals**

```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/nodes 2>&1 | tee /tmp/wpt-1B-gate-c.txt
```

Verify: total improves by approximately +44 vs. P0 dom/nodes baseline. Some variance is expected from unrelated subtests.

- [ ] **Step 7.4: Dispatch verifier agent (separate context)**

Per OMC rule (no self-approval), dispatch a verifier with:
- Spec: `docs/superpowers/specs/2026-04-19-kotori-1B-mutation-observer-design.md`
- Gate outputs: `/tmp/wpt-1B-gate-{a-run1,a-run2,a-run3,b,c}.txt`
- Criteria: spec §Acceptance (combined ≥ +44 subtests, no sentinel regression).

Example prompt:
> Verify that the implementation at HEAD satisfies the spec §Acceptance criteria in `docs/superpowers/specs/2026-04-19-kotori-1B-mutation-observer-design.md`. Inputs: /tmp/wpt-1B-baseline.txt, /tmp/wpt-1B-sentinels.txt, /tmp/wpt-1B-gate-{a-run1..3,b,c}.txt. For each of the 5 acceptance bullets, cite the evidence line and declare PASS/FAIL. Final verdict: APPROVED or REJECTED with reasons.

- [ ] **Step 7.5: Update project memory with new WPT baselines**

On APPROVED, append a session entry to `memory/project_suzume_wpt_progress.md` noting Layer 1B completion and new MO-* numbers. Reference commit SHAs from Tasks 1–6.

- [ ] **Step 7.6: Close open questions**

Re-visit `.omc/plans/open-questions.md` and mark any resolved items:
- [1B-Q1] — resolve based on P0 Step 0.5 finding.
- [1B-Q2] — resolve based on WPT source grep (did insertAdjacentHTML exercise matter or not?).
- [1B-Q3] — resolve: keep 4 KiB stack buffers unless verifier flags truncation as a WPT blocker.

---

## Completion Checklist

Before declaring this plan DONE:

- [ ] All 6 implementation commits (Tasks 1–6) landed on master (or merged from worktree); each commit is bisectable — `zig build test` green at every HEAD.
- [ ] `.omc/plans/open-questions.md` has Layer 1B entries; all 3 resolved at completion.
- [ ] Gate A (3 stability runs): `MutationObserver-childList.html` ≥ 24/25, `-attributes.html` ≥ 20/21, `-characterData.html` ≥ 7/8; combined ≥ +44 subtests vs. P0 baseline.
- [ ] Gate B (sentinels): zero regression in `Document-createElement`, `Element-setAttribute`, `Node-replaceChild`, `Node-normalize`.
- [ ] Gate C: `dom/nodes` dashboard improved by ~+44 (±small variance from unrelated subtests).
- [ ] Verifier agent APPROVED in separate context.
- [ ] Memory updated with Layer 1B numbers in `memory/project_suzume_wpt_progress.md`.
- [ ] Gate output files preserved in `/tmp/wpt-1B-*.txt` for future bisect.

---

## Notes for the Executor

- **Do not rebuild `recordMutationFull`.** The helper at `events.zig:2665` already implements §4.3.3 correctly. Work is caller-side only.
- **Land this plan BEFORE Layer 2A.** Both touch `events.zig` but in disjoint regions (1B: L2687; 2A: L162). Merge risk is low but non-zero; sequencing eliminates it entirely.
- **Spec wins on disagreement.** When the plan and spec diverge, read `docs/superpowers/specs/2026-04-19-kotori-1B-mutation-observer-design.md` — the caller audit matrix there is authoritative.
- **P0 is a hard gate.** The 3 AUDIT items (1B-Q1, matrix row 16, matrix row 29) may expand scope. If Step 0.5 or 0.6 finds additional bypasses, resolve them inside the most appropriate of Tasks 3–5, **not** as new tasks.
- **One commit per task.** Atomic. If `zig build test` fails, revert and iterate — do not stack.
- **Old-value buffers are 4 KiB stack.** Per 1B-Q3, this is acceptable for the WPT target set. If a subtest exceeds 4 KiB, spill to heap via `allocator.alloc` — pattern at `dom_element.zig:795–808`.
- **Kotori-VM is the default path.** Per roadmap Session #6, kotori is the default VM. Do not assume QuickJS-side correctness implies end-to-end correctness — every fix that touches `events.zig` must have a kotori twin (Task 4 does this deliberately).
