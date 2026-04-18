# kotori Layer 2A — AbortSignal Listener Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `addEventListener(type, cb, { signal })` spec-compliant per DOM §2.7.1 + §3.1 so that (a) `removeEventListener` detaches the abort step, (b) the abort handler closure is reachable for detachment, and (c) mid-dispatch aborts skip already-queued-but-unfired listeners. Target: ≥12/13 subtests on `dom/events/AddEventListenerOptions-signal.any.js` plus incidental wins in `dom/abort/*`.

**Architecture:** Three observable bugs live in `src/js/events.zig`:

1. **Handler capture leak (events.zig:173-181).** The abort closure is eval'd but the returned handler `JSValue` is thrown away; nothing can detach it later. Fix: eval a factory that *returns* the inner `function(){…}`, store the dup'd handler on the `ListenerRecord`.
2. **No abort detach on `removeEventListener` (events.zig:267-354).** The three removal paths (owned lxb node, JS-level `__el_<type>`, window/document entries) never call `signal.removeEventListener('abort', handler)`. The `_evtMap['abort']` entry leaks until the signal itself is GC'd. Fix: central `freeListenerRecord` helper that detaches the abort step before freeing.
3. **No `removed` flag on mid-dispatch removal (events.zig:760, :816).** Dispatch loops iterate a snapshot; when an abort fires mid-iteration and strips a later listener from the registry, that listener still fires from the snapshot. Fix: DOM §2.9 step 5.3 "soft-remove" — set `rec.removed=true` before freeing, check the flag in both dispatch helpers.

**Polyfill at `web_api.zig:2677-2691` is FINE.** It already implements `sig.addEventListener('abort', fn, {once:true})` + `sig.removeEventListener('abort', fn)` + `sig.aborted` + synchronous dispatch. No changes there. All work stays in `events.zig`.

**Tech Stack:** Zig 0.15.2, QuickJS (in-tree `src/js/kotori/`… bindings via `qjs` namespace in events.zig), lexbor DOM (callback-target bridging), WPT.

**Spec:** `docs/superpowers/specs/2026-04-19-kotori-2A-abortsignal-listener-design.md`
**Parent roadmap:** `docs/superpowers/specs/2026-04-17-kotori-suzume-wpt-100-roadmap.md` (Layer 2A, Wave 1)

---

## File Structure

### Files to modify
- `src/js/events.zig` — ONLY file touched.
  - L37-L43 `ListenerRecord` struct — add 3 new fields.
  - L162-L182 `jsAddEventListener` signal block — eval a handler-returning factory; dup `sig_val` + handler into record.
  - L267-L354 `jsRemoveEventListener` — call `freeListenerRecord` from each of the three removal paths (owned node at :307, window/document entry at :344; also the JS-level `__el_<type>` path at :315-:334 needs audit in Task 0 — may need parallel treatment, see Task 6).
  - L760 `callListenersOnNodeFiltered` — add `if (rec.removed) continue;` at loop head.
  - L787 once-fire cleanup — route through `freeListenerRecord`.
  - L816 `callEntryListenersFiltered` — add `if (rec.removed) continue;` at loop head.
  - New helper `freeListenerRecord(ctx, list, idx)` — central teardown (detach abort step + `JS_FreeValue` signal_ref / abort_handler_ref / callback + `orderedRemove`).

### Files NOT modified
- `src/js/web_api.zig` — the AbortSignal/AbortController polyfill at :2677-2691 already satisfies DOM §3.1 via `_evtMap['abort']` + `{once:true}` semantics. Do not touch.
- Any HTML / DOM interface layer — this is purely the listener registry / dispatch plumbing.

---

## Task 0: P0 Audit — No-Code Gate

**Files:** None modified; produces a notes file for reference during subsequent tasks.

**Purpose:** Verify spec assumptions against current HEAD (post-Layer-1B). Confirm the ListenerRecord shape, the three removal paths, the JS-level `__el_<type>` behavior under abort-during-dispatch, and baseline WPT numbers — before any code changes.

- [ ] **Step 0.1: Verify `ListenerRecord` field layout at events.zig:37-43**

Run:
```bash
cd ~/suzume
sed -n '35,50p' src/js/events.zig
```

Expected: a struct named `ListenerRecord` with fields `callback`, `capture`, `passive`, `once`. Record the exact line number for each field — Task 1 appends three new fields directly below `once`.

If the struct has drifted (e.g., Layer 1B added fields here), reconcile line numbers before Task 1.

- [ ] **Step 0.2: Verify `jsAddEventListener` signal handling at events.zig:162-182**

Run:
```bash
sed -n '160,185p' src/js/events.zig
```

Confirm the current structure:
- :163-:164 reads `sig_val = JS_GetPropertyStr("signal")`.
- :165-:168 throws TypeError on `signal === null`.
- :169-:172 short-circuits when `signal.aborted` is truthy.
- :173-:181 eval'd closure calls `sig.addEventListener('abort', function(){el.removeEventListener(...)}, {once:true})` — and **discards** the returned handler `JSValue`.

Record the exact range of the eval'd JS source — Task 2 rewrites this literal.

- [ ] **Step 0.3: Verify `jsRemoveEventListener` lacks abort detach at events.zig:267-354**

Run:
```bash
grep -n "signal\|abort_handler\|freeListenerRecord" src/js/events.zig | head -40
```

Expected: zero matches for `abort_handler` and zero for `freeListenerRecord` (helper does not yet exist). A few matches for `signal` inside `jsAddEventListener` only. Any match inside `jsRemoveEventListener` means prior work exists — reconcile.

Locate the three removal paths and note exact `orderedRemove` line numbers:
```bash
grep -n "orderedRemove" src/js/events.zig | head -10
```

Expected (per spec): :307 (owned lxb node), :344 (window/document entry), :787 (once-fire). Any drift → update Task 4 line refs.

- [ ] **Step 0.4: Verify `AbortSignal` polyfill works at web_api.zig:2677-2691**

Run:
```bash
sed -n '2675,2695p' src/js/web_api.zig
```

Confirm the polyfill defines: `aborted`, `reason`, `addEventListener('abort', fn, {once:true})`, `removeEventListener`, `dispatchEvent` over `_evtMap`, plus `AbortSignal.abort()` and `AbortController.prototype.abort()`. Write a micro-repro to verify:

```bash
cat > /tmp/abort-polyfill-probe.js <<'EOF'
const c = new AbortController();
const s = c.signal;
let n = 0;
s.addEventListener('abort', () => n++, { once: true });
c.abort();
c.abort();  // second abort must not re-fire
console.log(n === 1 ? 'OK' : 'FAIL: ' + n);
EOF
./zig-out/bin/suzume /tmp/abort-polyfill-probe.js
```

Expected: `OK`. If `FAIL`, the polyfill itself is broken and 2A cannot proceed — escalate. (Do not attempt to fix web_api.zig as part of 2A.)

- [ ] **Step 0.5: Audit the JS-level `__el_<type>` path at events.zig:245-256**

This is the critical risk (spec Risk 4). WPT `AddEventListenerOptions-signal.any.js` uses `new EventTarget()` which has no lxb node and no window/document entry, so listeners land in the JS-level `__el_<type>` array. Verify whether dispatch there snapshots the array or iterates live:

```bash
sed -n '240,260p' src/js/events.zig
grep -n "__el_" src/js/events.zig
```

Locate the dispatch site that reads `__el_<type>` (likely in the `dispatchEvent` native, search for `__el_`). Inspect whether it copies the array to a local before iteration or mutates-live. Write findings into `/tmp/2a-audit-notes.md`:

- If **live iteration**: no Task 6 changes needed — manual `removeEventListener` during abort-fire already strips the entry before the iterator advances.
- If **snapshot**: Task 6 is REQUIRED — mirror the `removed` flag concept into the JS array (either insert a `{fn, removed:false}` wrapper object, or add a parallel `__removed_<type>` bitmap).

Record the exact dispatch-site line numbers for JS-level path.

- [ ] **Step 0.6: Capture WPT baselines**

Run:
```bash
cd ~/suzume
zig build 2>&1 | tail -5   # confirm post-Layer-1B events.zig compiles cleanly
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
  dom/events/AddEventListenerOptions-signal.any.js \
  dom/events/AddEventListenerOptions-once.any.js \
  dom/events/AddEventListenerOptions-passive.any.js \
  dom/events/EventListenerOptions-capture.html \
  dom/events/Event-dispatch-listener-order.html \
  dom/abort/AbortSignal.any.js \
  dom/abort/event.any.js 2>&1 | tee /tmp/wpt-2a-baseline.txt
```

Record pass/fail counts per file — these are the reference numbers for Task 7 Gate A/B. Spec estimates current `signal.any.js` at 5-7/13 subtests; post-2A floor is 12/13.

- [ ] **Step 0.7: Write audit notes (no code)**

Write all findings into `/tmp/2a-audit-notes.md`. Include:
- Exact line numbers for ListenerRecord, add/remove handlers, orderedRemove call sites, JS-level dispatch site.
- Whether Risk 4 (JS-level snapshot) applies → Task 6 enabled or skipped.
- Baseline pass counts per WPT file.

No repo commit at this phase.

**Risk callout:** If Layer 1B merge shifted ANY of the line refs above by more than 5 lines, stop and re-anchor every subsequent task to the new line numbers before proceeding.

---

## Task 1: Extend `ListenerRecord` with abort-tracking fields

**Files:**
- Modify: `src/js/events.zig` — extend struct definition at L37-L43.

**Purpose:** Add the three fields required to (a) soft-remove mid-dispatch, (b) detach the abort step on manual remove.

- [ ] **Step 1.1: Extend ListenerRecord at events.zig:37-43**

Locate:
```zig
const ListenerRecord = struct {
    callback: qjs.JSValue,
    capture: bool = false,
    passive: bool = false,
    once: bool = false,
};
```

Replace with:
```zig
const ListenerRecord = struct {
    callback: qjs.JSValue,
    capture: bool = false,
    passive: bool = false,
    once: bool = false,
    // Layer 2A — AbortSignal integration (DOM §2.7.1 step 5, §2.9 step 5.3)
    removed: bool = false,                                  // soft-delete for mid-dispatch abort
    signal_ref: qjs.JSValue = quickjs.JS_UNDEFINED(),       // dup'd signal, so removeEventListener can detach
    abort_handler_ref: qjs.JSValue = quickjs.JS_UNDEFINED(),// dup'd handler closure, so we can pass back to sig.removeEventListener('abort', …)
};
```

Verify the helper `quickjs.JS_UNDEFINED()` is already imported at the top of events.zig (it should be — used elsewhere). If the module uses `qjs.JS_UNDEFINED` instead, use that spelling consistently.

- [ ] **Step 1.2: Confirm default-init of new fields is backward-compatible**

Every `ListenerRecord{…}` construction site (grep-audit):
```bash
grep -n "ListenerRecord{" src/js/events.zig
```

Each site must compile without passing the new fields (they have defaults). Build:
```bash
zig build 2>&1 | grep -E "error|ListenerRecord"
```

Expected: clean build. If any construction uses positional initializers (`ListenerRecord{ cb, cap, … }` without field names), it will break — convert to named init.

- [ ] **Step 1.3: Commit**

```
git add src/js/events.zig
git commit -m "events: extend ListenerRecord with abort-tracking fields (Layer 2A)

Adds `removed` bool (soft-delete for mid-dispatch abort per DOM §2.9
step 5.3) plus `signal_ref` / `abort_handler_ref` JSValues so manual
removeEventListener can detach the abort step.

Wiring comes in subsequent commits; this commit is struct-only."
```

**Risk:** Default-init of JSValue fields. `quickjs.JS_UNDEFINED()` must be a compile-time constant expression. If Zig rejects it as default value, use a pub const `UNDEF: qjs.JSValue = quickjs.JS_UNDEFINED();` at module scope and reference it as the default.

**WPT test mapping (ripple effects, full list lands in Task 7):**
- Test 1 "AbortSignal allows removing a listener" — enabled by fields.
- Test 2 "does not prevent removeEventListener" — enabled.
- Test 3 "works with once flag" — enabled.
- Test 4 "Removing once listener with signal" — enabled.
- Test 5 "AbortSignal to multiple listeners" — enabled.
- Test 6 "works with capture flag" — enabled.
- Test 7 "Aborting from a listener does not call future listeners" — enabled via `removed` field.
- Test 8 "Adding then aborting in another listener" — enabled via `removed` field.

---

## Task 2: Capture abort handler on add (events.zig:173-181)

**Files:**
- Modify: `src/js/events.zig` — rewrite the eval'd JS snippet in `jsAddEventListener`.

**Purpose:** Change the abort-registration closure from fire-and-forget to a factory that **returns** the inner handler, so we can dup it into `record.abort_handler_ref` for later detach. Also dup `sig_val` into `record.signal_ref`.

- [ ] **Step 2.1: Locate the current eval'd snippet**

```bash
sed -n '170,185p' src/js/events.zig
```

You should see approximately:
```zig
const sig_code =
    \\(function(sig, el, type, cb, cap){
    \\  sig.addEventListener('abort', function(){ el.removeEventListener(type, cb, cap); }, {once:true});
    \\})
;
// …JS_Eval sig_code, then JS_Call with (sig, this_val, args[0], args[1], JS_NewBool(capture))
```

- [ ] **Step 2.2: Rewrite the snippet to return the handler**

Replace with:
```zig
const sig_code =
    \\(function(sig, el, type, cb, cap){
    \\  var h = function(){ el.removeEventListener(type, cb, cap); };
    \\  sig.addEventListener('abort', h, {once:true});
    \\  return h;
    \\})
;
```

Capture the call result:
```zig
const handler = qjs.JS_Call(c, sig_fn, quickjs.JS_UNDEFINED(), 5, &call_args);
defer qjs.JS_FreeValue(c, handler);
// On exception: handler.tag == JS_TAG_EXCEPTION → propagate via JS_EXCEPTION return.
if (qjs.JS_IsException(handler) != 0) return handler;
```

- [ ] **Step 2.3: Dup the handler + signal into the (later-appended) record**

The record is constructed around events.zig:216-263 (per spec). Thread the two refs through construction. Minimally invasive approach: declare locals right after the call, then use them when building the `ListenerRecord`:

```zig
const dup_sig = qjs.JS_DupValue(c, sig_val);
const dup_handler = qjs.JS_DupValue(c, handler);
// … (later, when building the record) …
record.signal_ref = dup_sig;
record.abort_handler_ref = dup_handler;
```

If listener append is skipped (e.g., duplicate registration — §2.7.1 step 4 no-op), the two dup'd values leak. Guard: if the append path short-circuits, call `JS_FreeValue(c, dup_sig)` + `JS_FreeValue(c, dup_handler)` and also call `sig.removeEventListener('abort', dup_handler)` to undo the polyfill entry. Cross-reference the dedup check site (likely inside the same function near :216-:220).

- [ ] **Step 2.4: Build & quick-sanity**

```bash
zig build 2>&1 | tail -5
cat > /tmp/2a-t2-probe.js <<'EOF'
const c = new AbortController();
const et = new EventTarget();
let fired = 0;
et.addEventListener('x', () => fired++, { signal: c.signal });
et.dispatchEvent(new Event('x'));  // fires once
c.abort();
et.dispatchEvent(new Event('x'));  // must NOT fire
console.log(fired === 1 ? 'OK' : 'FAIL:' + fired);
EOF
./zig-out/bin/suzume /tmp/2a-t2-probe.js
```

Expected: `OK` (same behavior as pre-Task-2; we haven't wired detach yet, only captured the handler).

- [ ] **Step 2.5: Commit**

```
git add src/js/events.zig
git commit -m "events: capture abort handler on addEventListener (Layer 2A)

Change the eval'd abort-hook snippet to return the inner handler so we
can detach it later via sig.removeEventListener('abort', h). Dup both
signal and handler into the ListenerRecord's new refs. Teardown of the
refs lands in Task 3+4."
```

**Risk:** If the dedup-append branch isn't audited, the two dup'd values leak on duplicate registrations. Mitigation in Step 2.3 note.

**WPT test mapping (this commit enables observation but doesn't move counts yet — full effect after Task 4):**
- Tests 1, 2, 4 depend on detach path (Task 4). This commit is infrastructure only.

---

## Task 3: Add `freeListenerRecord` helper

**Files:**
- Modify: `src/js/events.zig` — insert helper near the top-of-file helpers section (after `ListenerRecord` / `ListenerList` definitions).

**Purpose:** Centralize the teardown sequence so every removal path (manual remove, once-fire, abort-fire via reentry) runs identical cleanup in the correct order.

- [ ] **Step 3.1: Define the helper**

```zig
/// DOM §2.7.1 + §3.1 — central teardown for a listener registration.
/// MUST be called with `list[idx]` still valid. Performs:
///   1. Mark `removed=true` so any active dispatch snapshot skips it.
///   2. If bound to a signal: call `sig.removeEventListener('abort', handler_ref)`
///      on the polyfill, then JS_FreeValue both dup'd refs.
///   3. JS_FreeValue the callback.
///   4. `orderedRemove` from the list.
/// Safe on double-call only if the caller re-derives idx (records shift).
fn freeListenerRecord(
    c: *qjs.JSContext,
    list: *ListenerList,
    idx: usize,
) void {
    var rec = &list.items[idx];
    rec.removed = true;

    if (rec.signal_ref.tag != qjs.JS_TAG_UNDEFINED and qjs.JS_IsUndefined(rec.signal_ref) == 0) {
        // Build args: ['abort', handler_ref]
        const abort_str = qjs.JS_NewString(c, "abort");
        defer qjs.JS_FreeValue(c, abort_str);
        var rm_args = [2]qjs.JSValue{ abort_str, rec.abort_handler_ref };
        const rm_fn = qjs.JS_GetPropertyStr(c, rec.signal_ref, "removeEventListener");
        defer qjs.JS_FreeValue(c, rm_fn);
        if (qjs.JS_IsFunction(c, rm_fn) != 0) {
            const r = qjs.JS_Call(c, rm_fn, rec.signal_ref, 2, &rm_args);
            qjs.JS_FreeValue(c, r);
            // Ignore exceptions here: the polyfill's splice is a no-op on missing entry,
            // so the only exceptions would be engine-level (OOM) — caller cannot recover.
        }
        qjs.JS_FreeValue(c, rec.signal_ref);
        qjs.JS_FreeValue(c, rec.abort_handler_ref);
        rec.signal_ref = quickjs.JS_UNDEFINED();
        rec.abort_handler_ref = quickjs.JS_UNDEFINED();
    }

    qjs.JS_FreeValue(c, rec.callback);
    _ = list.orderedRemove(idx);
}
```

Verify the precise spellings of `qjs.JS_TAG_UNDEFINED`, `qjs.JS_IsUndefined`, `qjs.JS_IsFunction` against the existing events.zig imports — if any are under a different namespace, adjust.

- [ ] **Step 3.2: Unit-smoke the helper compiles**

```bash
zig build 2>&1 | tail -5
```

Clean build expected. The helper has no callers yet; Task 4 wires them.

- [ ] **Step 3.3: Commit**

```
git add src/js/events.zig
git commit -m "events: add freeListenerRecord helper (Layer 2A)

Centralizes listener teardown: detach abort step, free dup'd
signal/handler refs, free callback, orderedRemove. No callers yet;
Task 4 wires all three removal paths to go through this helper."
```

**Risk:** The `JS_GetPropertyStr("removeEventListener")` dance allocates every call. For hot paths this is suboptimal but correctness-first. Measure in Task 7; if it shows in perf, cache a JSAtom.

**WPT test mapping:** None directly — helper-only commit.

---

## Task 4: Wire `freeListenerRecord` into all removal paths

**Files:**
- Modify: `src/js/events.zig`
  - `jsRemoveEventListener` manual-remove paths — owned-node (events.zig:307) and window/document entry (events.zig:344). JS-level `__el_<type>` path at :315-:334 handled here too if it uses a struct registry; if it stays pure-JS, Task 6 covers it.
  - Once-fire cleanup (events.zig:787) — replace the inline free with `freeListenerRecord`.
  - Abort-fire — no direct wiring; it re-enters `jsRemoveEventListener` via the eval'd closure, which lands in the manual-remove paths above.

**Purpose:** Replace ad-hoc `JS_FreeValue(callback)` + `orderedRemove` call sites with calls to the new helper, so abort-step detachment happens consistently.

- [ ] **Step 4.1: Patch owned-node manual-remove at events.zig:298-314**

Locate the block around `orderedRemove` at :307. Existing shape:
```zig
qjs.JS_FreeValue(c, list.items[idx].callback);
_ = list.orderedRemove(idx);
```

Replace with:
```zig
freeListenerRecord(c, list, idx);
```

- [ ] **Step 4.2: Patch window/document entry manual-remove at events.zig:335-352**

Same substitution around the `:344` `orderedRemove`. Verify the local variable names for `list` and `idx` match what `freeListenerRecord` expects; rename if needed.

- [ ] **Step 4.3: Patch JS-level `__el_<type>` path at events.zig:315-334**

Inspect what this path stores. Two cases:

**Case A — it stores ListenerRecords in a native list as well:** apply the same substitution. (Unlikely from spec reading but verify.)

**Case B — it stores raw JSValues in a JS array (`obj.__el_x = [fn1, fn2, …]`):** the path does not use `ListenerRecord` at all, so there's no signal_ref to free here. Leave this path unchanged in Task 4; Task 6 handles it.

Record which case applies in `/tmp/2a-audit-notes.md` (from Task 0.5).

- [ ] **Step 4.4: Patch once-fire at events.zig:787**

Locate the once-fire branch. Existing shape (approx):
```zig
if (rec.once) {
    qjs.JS_FreeValue(c, rec.callback);
    _ = list.orderedRemove(idx);
    // idx adjustment for iteration
}
```

Replace the free+orderedRemove with:
```zig
freeListenerRecord(c, list, idx);
```

**Iteration-index correction:** After `orderedRemove`, the following record has shifted into slot `idx`. The current loop already handles this (likely `continue` without incrementing `idx` or decrementing). Preserve that behavior — `freeListenerRecord` does not change list-length semantics vs. the inline version.

- [ ] **Step 4.5: Build + probe manual-remove detaches**

```bash
zig build 2>&1 | tail -5
cat > /tmp/2a-t4-probe.js <<'EOF'
const c = new AbortController();
const et = new EventTarget();
let fired = 0;
const cb = () => fired++;
et.addEventListener('x', cb, { signal: c.signal });
et.removeEventListener('x', cb);  // manual remove
c.abort();                         // abort fires — but handler was detached
et.dispatchEvent(new Event('x')); // must not fire; cb is gone
console.log(fired === 0 ? 'OK' : 'FAIL:' + fired);
EOF
./zig-out/bin/suzume /tmp/2a-t4-probe.js
```

Expected: `OK`. This is WPT test 2 behavior.

- [ ] **Step 4.6: Probe once+signal**

```bash
cat > /tmp/2a-t4-once.js <<'EOF'
const c = new AbortController();
const et = new EventTarget();
let fired = 0;
et.addEventListener('x', () => fired++, { once: true, signal: c.signal });
et.dispatchEvent(new Event('x'));  // fires, once-removes
c.abort();                          // must be no-op
et.dispatchEvent(new Event('x'));  // must not fire
console.log(fired === 1 ? 'OK' : 'FAIL:' + fired);
EOF
./zig-out/bin/suzume /tmp/2a-t4-once.js
```

Expected: `OK`. This is WPT test 3.

- [ ] **Step 4.7: Commit**

```
git add src/js/events.zig
git commit -m "events: route all listener removals through freeListenerRecord (Layer 2A)

Manual removeEventListener (owned-node, window/document paths) and
once-fire now detach the abort step via sig.removeEventListener('abort',
handler) before freeing. Abort-fire path is unchanged — it re-enters
jsRemoveEventListener via the eval'd closure, which now goes through
this same helper.

Fixes DOM §2.7.1 step 5 abort-step lifetime for addEventListener({signal}).
Enables WPT AddEventListenerOptions-signal subtests 1-6."
```

**Risk 1:** Re-entrancy. When abort-fire calls `removeEventListener`, the helper calls `sig.removeEventListener('abort', handler)` which the polyfill handles fine (splice is no-op on missing entry, the `{once:true}` branch already removed it). Verified in spec §"removeEventListener interaction" Case A.

**Risk 2:** If Step 4.3 Case B applies (pure-JS array), WPT tests 7-8 (abort-mid-dispatch on `new EventTarget()`) will still fail. Deferred to Task 6.

**WPT test mapping:**
- Test 1 "AbortSignal allows removing a listener" — PASS.
- Test 2 "does not prevent removeEventListener" — PASS.
- Test 3 "works with once flag" — PASS.
- Test 4 "Removing once listener with signal" — PASS.
- Test 5 "AbortSignal to multiple listeners" — PASS.
- Test 6 "works with capture flag" — PASS.
- Test 7 "Aborting from a listener does not call future listeners" — still FAIL (needs Task 5).
- Test 8 "Adding then aborting in another listener" — still FAIL (needs Task 5+6).

---

## Task 5: Add `removed` flag check in dispatch loops

**Files:**
- Modify: `src/js/events.zig`
  - `callListenersOnNodeFiltered` at L760 — add `if (rec.removed) continue;` at the head of the per-record loop.
  - `callEntryListenersFiltered` at L816 — same check.

**Purpose:** Honor DOM §2.9 step 5.3 "If listener's removed is true, then continue" so a mid-dispatch abort (which soft-removes later records via `freeListenerRecord.removed=true`) skips those records even though they're in the dispatch snapshot.

Note: `freeListenerRecord` both marks `removed=true` AND calls `orderedRemove`. Because dispatch iterates a **snapshot** (usually a local `ArrayList` clone made at loop start), the snapshot still holds the old-slot records. The `removed` flag has to live on the record itself — but wait, if `orderedRemove` shifts the live list, the snapshot still references the OLD record storage…

Re-audit the snapshot strategy:

- [ ] **Step 5.1: Determine dispatch snapshot mechanism**

```bash
sed -n '755,795p' src/js/events.zig
sed -n '810,850p' src/js/events.zig
```

Look for either (a) a local `var snapshot = list.clone()`, or (b) direct iteration over `list.items[i]`. Record the mechanism in `/tmp/2a-audit-notes.md`.

**If (a) clone:** the snapshot holds value copies of `ListenerRecord`. Setting `rec.removed = true` in the live list does NOT propagate to the snapshot. We need to either:
  - **Change snapshot to hold pointers/indices into the live list** (preferred — cheaper, aligns with spec). The `orderedRemove` then shifts indices — requires snapshot to store `(callback_ptr, capture, once, passive, removed_ptr)` tuples or similar, or a stable ID. Since `orderedRemove` invalidates index-based snapshots, the cleanest fix is **don't orderedRemove during dispatch**; instead just set `removed=true` and defer orderedRemove to a "cleanup swept" pass after dispatch.
  - Or **keep clone-value snapshot but have `freeListenerRecord` also reach into the current dispatch's snapshot and flip the flag** — which requires plumbing the active-dispatch's snapshot into the helper. Messy.

**If (b) direct iteration:** `removed=true` propagates naturally. But `orderedRemove` during iteration shifts records, risking skip/double-visit — existing code must already handle this (via adjusted index). Just adding `if (rec.removed) continue;` works.

- [ ] **Step 5.2: Implementation strategy — split into "mark" + "sweep"**

Recommended: modify `freeListenerRecord` so that **during active dispatch** it only marks `removed=true` and defers `orderedRemove` + frees to a post-dispatch sweep. Out of active dispatch, behavior is unchanged (immediate free).

Detect active dispatch via a thread-local / VM-global counter `dispatch_depth`:

```zig
var g_dispatch_depth: usize = 0;  // module-level

// In dispatch sites (callListenersOnNodeFiltered, callEntryListenersFiltered):
g_dispatch_depth += 1;
defer g_dispatch_depth -= 1;
```

And in `freeListenerRecord`:
```zig
if (g_dispatch_depth > 0) {
    rec.removed = true;
    // Defer signal detach + frees to sweep. But we still must detach *now*
    // because the polyfill's _evtMap entry could fire again if re-aborted.
    // Solution: do detach now, but keep callback alive until sweep.
    // … detach step here (call sig.removeEventListener)…
    qjs.JS_FreeValue(c, rec.signal_ref);
    qjs.JS_FreeValue(c, rec.abort_handler_ref);
    rec.signal_ref = quickjs.JS_UNDEFINED();
    rec.abort_handler_ref = quickjs.JS_UNDEFINED();
    return;  // leave callback + list entry; sweep handles later
}
// … non-dispatch path: full teardown as before…
```

And add a post-dispatch sweep at the end of each dispatch loop (after `defer g_dispatch_depth -= 1;`):

```zig
// Sweep: remove any records marked removed during this dispatch
var j: usize = 0;
while (j < list.items.len) {
    if (list.items[j].removed) {
        qjs.JS_FreeValue(c, list.items[j].callback);
        _ = list.orderedRemove(j);
        // idx stays — next record shifted into slot j
    } else {
        j += 1;
    }
}
```

- [ ] **Step 5.3: Add the `removed` check at both dispatch sites**

At L760 loop head:
```zig
for (list.items, 0..) |rec, i| {
    if (rec.removed) continue;
    _ = i;
    // … existing call logic …
}
```

Same at L816.

- [ ] **Step 5.4: Build + probe abort-during-dispatch**

```bash
zig build 2>&1 | tail -5
cat > /tmp/2a-t5-midabort.js <<'EOF'
const c = new AbortController();
const et = new EventTarget();
let order = [];
et.addEventListener('x', () => { order.push('A'); c.abort(); }, { signal: c.signal });
et.addEventListener('x', () => { order.push('B'); }, { signal: c.signal });
et.dispatchEvent(new Event('x'));
// Spec: A fires, aborts mid-dispatch, B must NOT fire.
console.log(JSON.stringify(order) === '["A"]' ? 'OK' : 'FAIL:' + JSON.stringify(order));
EOF
./zig-out/bin/suzume /tmp/2a-t5-midabort.js
```

Expected: `OK` — but only for the native registry path. If A and B land on the JS-level `__el_<type>` path (Case B in Task 4.3), still FAIL — Task 6 fixes that.

- [ ] **Step 5.5: Commit**

```
git add src/js/events.zig
git commit -m "events: honor removed flag in dispatch loops (Layer 2A)

DOM §2.9 step 5.3 requires skipping listeners whose removed bit is set
during the in-flight dispatch. Split freeListenerRecord into immediate
vs deferred modes based on g_dispatch_depth; added post-dispatch sweep
at both callListenersOnNodeFiltered and callEntryListenersFiltered.

Enables WPT AddEventListenerOptions-signal tests 7-8 for listeners in
the native registry path."
```

**Risk:** Re-entrant dispatch. If a listener dispatches a nested event (common pattern), `g_dispatch_depth` must stack — it does, because the `defer` decrement pops correctly. But the sweep runs at each level's exit; at inner-dispatch exit we sweep the list, which is correct if the inner dispatch is on the same target / same list. If on a different target, sweeping the outer target's list from inner dispatch is wrong. Mitigation: pass the active list explicitly to the sweep and only sweep the list the current dispatch is iterating. Verify implementation matches.

**WPT test mapping:**
- Test 7 "Aborting from a listener does not call future listeners" — PASS (native path).
- Test 8 "Adding then aborting in another listener" — PASS (native path).
- If tests 7-8 land on JS-level path, still FAIL — Task 6.

---

## Task 6: JS-level listener path treatment (conditional)

**Files:**
- Modify: `src/js/events.zig` — only if Task 0.5 audit flagged Case B (JS-level path uses snapshot dispatch).

**Purpose:** Mirror the `removed`-flag idea into the `__el_<type>` JS array so that `new EventTarget()` targets — which WPT uses extensively in signal.any.js — get the same mid-dispatch skip semantics.

**Gate:** Skip this entire task if Task 0.5 found the JS-level path already iterates the array live (mutations during iteration strip entries before they fire). Record the decision in the audit notes.

- [ ] **Step 6.1: Re-read audit notes**

```bash
cat /tmp/2a-audit-notes.md
```

If audit says "live iteration, no snapshot" → skip Task 6 entirely; mark tests 7-8 as already passing after Task 5.

If audit says "snapshot" → proceed.

- [ ] **Step 6.2: Pick a soft-remove scheme**

Option A (wrapper objects): change `__el_<type>` entries from bare functions to `{fn, removed:false}` records. Dispatch site reads `.fn` and checks `.removed`. `removeEventListener` finds the matching entry and sets `.removed=true` then splices.

Option B (parallel bitmap): keep `__el_<type>` as function array; add `__elr_<type>` as a parallel `Array<bool>` of same length. Dispatch site checks the bitmap.

Option A is simpler and self-documenting; it costs one extra object allocation per listener. Use Option A unless perf testing objects.

- [ ] **Step 6.3: Patch the JS-level add path**

Around events.zig:245-256, change:
```zig
// list.push(cb)
```
to:
```zig
// list.push({ fn: cb, removed: false, type: <type>, cap: <cap> })
```
(Exact Zig-side mechanics depend on how the path manipulates the JS array — grep the `JS_Call(push, …)` or `JS_SetPropertyUint32` site.)

- [ ] **Step 6.4: Patch the JS-level remove path (events.zig:315-334)**

Change the matching predicate from `entry === cb` to `entry.fn === cb && entry.cap === cap`. Before the splice, set `entry.removed = true` so any in-flight dispatch skips.

- [ ] **Step 6.5: Patch the JS-level dispatch site**

Locate via grep `__el_` in dispatch code. Change:
```zig
// for (const cb of arr) cb.call(this, evt);
```
to:
```zig
// for (const entry of snapshot) { if (entry.removed) continue; entry.fn.call(this, evt); }
```

- [ ] **Step 6.6: Build + re-run the Task 5.4 probe**

Expected: `["A"]` result even on `new EventTarget()` targets.

- [ ] **Step 6.7: Commit**

```
git add src/js/events.zig
git commit -m "events: JS-level __el_<type> path honors removed flag (Layer 2A)

new EventTarget() stores listeners in per-object JS arrays rather than
the native registry. Wraps each entry in {fn, removed, cap} so manual
remove and dispatch respect mid-flight abort-removal. Required for WPT
AddEventListenerOptions-signal tests 7-8 when target is EventTarget().

Conditional: only applies if dispatch site was snapshot-based. Live-
iteration path needs no change."
```

**Risk:** Any JS user-code that inspects `obj.__el_<type>` directly (internal API exposed?) breaks. Grep the repo for `__el_` in JS sources — expected zero hits outside events.zig / web_api.zig. If hit, either gate by a feature flag or switch to Option B (parallel bitmap).

**WPT test mapping:**
- Test 7 — PASS on EventTarget() targets.
- Test 8 — PASS on EventTarget() targets.
- Test 5 "AbortSignal to multiple listeners" — may already PASS from Task 4; verify unchanged.

---

## Task 7: WPT verification + regression check

**Files:** None modified.

**Purpose:** Run the target WPT files and confirm ≥12/13 subtests on `AddEventListenerOptions-signal.any.js`; confirm zero regressions on adjacent files.

- [ ] **Step 7.1: Run primary WPT**

```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
  dom/events/AddEventListenerOptions-signal.any.js 2>&1 | tee /tmp/wpt-2a-signal.txt
```

Required: ≥12/13 subtests PASS. Compare to baseline in `/tmp/wpt-2a-baseline.txt`. Record deltas.

If 11/13 or lower: diagnose which assertion number failed (the WPT runner prints test name per failure). Common culprits:
- test 7/8 fail → Task 6 missed or dispatch-depth nesting broken.
- test 2 fails → manual remove not detaching abort step (Task 4 wiring).
- test 10/11 fail → null-signal TypeError regressed (should be unchanged from events.zig:165-168).

- [ ] **Step 7.2: Run abort-related WPT**

```bash
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
  dom/abort/AbortSignal.any.js \
  dom/abort/event.any.js 2>&1 | tee /tmp/wpt-2a-abort.txt
```

Expected: incidental +1 to +3 subtest gains vs baseline. If any regressions, diagnose.

- [ ] **Step 7.3: Regression sweep**

```bash
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
  dom/events/AddEventListenerOptions-once.any.js \
  dom/events/AddEventListenerOptions-passive.any.js \
  dom/events/EventListenerOptions-capture.html \
  dom/events/Event-dispatch-listener-order.html 2>&1 | tee /tmp/wpt-2a-regress.txt
```

Required: **zero regressions**. Each file must match baseline pass count or exceed it. The once-fire path changed (now routes through `freeListenerRecord`), so `once.any.js` is the highest-risk regression candidate.

- [ ] **Step 7.4: Full dom/events sweep (belt-and-suspenders)**

```bash
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/events 2>&1 | tee /tmp/wpt-2a-events-full.txt
```

Required: aggregate pass count for dom/events ≥ baseline (MEMORY notes "dom/events 70/252 27.8%" — so floor is 70 + 5 from 2A = 75 minimum, realistic target 82-85).

- [ ] **Step 7.5: Memory-leak smoke test**

The suzume-wpt binary should not grow unboundedly across 1000 iterations of add+abort cycles. Quick probe:

```bash
cat > /tmp/2a-leak-probe.js <<'EOF'
for (let i = 0; i < 1000; i++) {
  const c = new AbortController();
  const et = new EventTarget();
  et.addEventListener('x', () => {}, { signal: c.signal });
  c.abort();
}
console.log('done', process?.memoryUsage?.() ?? '(no mem api)');
EOF
./zig-out/bin/suzume /tmp/2a-leak-probe.js
```

If the suzume runtime exposes `process.memoryUsage`, RSS should not grow by more than ~few MB. If it balloons, a JSValue ref is leaking — audit `freeListenerRecord` for missed `JS_FreeValue`.

- [ ] **Step 7.6: Write results into the plan / commit message**

Record final counts:
- Primary `AddEventListenerOptions-signal.any.js`: `N/13` (target ≥12).
- Adjacent `AbortSignal.any.js`, `event.any.js`: `+Δ` subtests.
- Regressions: `0` (must).
- Full dom/events delta: `+Δ` subtests.

- [ ] **Step 7.7: Commit verification evidence**

```
git add /tmp/wpt-2a-signal.txt  # or wherever the plan records results
# (If results live outside the repo, skip the add; commit is metadata-only.)
git commit -m "verify: Layer 2A WPT pass counts

AddEventListenerOptions-signal.any.js: X/13 (+Δ vs baseline)
Adjacent abort/*: +Δ subtests
Regressions in dom/events once/passive/capture/order: 0

Layer 2A acceptance criteria met. Ready for roadmap wave-1 close."
```

**Risk:** If `once.any.js` regresses, revert Task 4 Step 4.4 (once-fire routing) and inline-free; re-verify. The `freeListenerRecord` signal-detach branch is guarded by `signal_ref != UNDEF`, so non-signal once listeners should short-circuit to plain free — but audit the fast path.

**WPT test mapping (final commit, full 8-test name table):**

| # | WPT file — assertion | Subtest count | Task source |
|---|----------------------|---------------|-------------|
| 1 | signal.any.js — "AbortSignal allows removing a listener" | 4 | Task 4 |
| 2 | signal.any.js — "does not prevent removeEventListener" | 1 | Task 4 |
| 3 | signal.any.js — "works with once flag" | 1 | Task 4 |
| 4 | signal.any.js — "Removing once listener with signal" | 1 | Task 4 |
| 5 | signal.any.js — "multiple listeners" | 1 | Task 4 |
| 6 | signal.any.js — "works with capture flag" | 1 | Task 4 |
| 7 | signal.any.js — "Aborting from a listener does not call future" | 1 | Task 5 (+6 if JS path) |
| 8 | signal.any.js — "Adding then aborting in another listener" | 1 | Task 5 (+6 if JS path) |

Tests 9-11 (nested-listener no-crash, null-signal TypeError x2) are already passing pre-2A; preserve them through regression gate.

---

## Commit strategy

One commit per Task (1→7). Each commit is self-contained and bisectable:
- Task 1: struct-only, compiles, no behavior change.
- Task 2: handler captured, behavior identical (detach still absent).
- Task 3: helper-only, zero callers, compiles.
- Task 4: manual remove detaches — tests 1-6 go green.
- Task 5: mid-dispatch skip — tests 7-8 go green for native path.
- Task 6: (conditional) JS-level path — tests 7-8 also green for EventTarget() targets.
- Task 7: verification evidence only; may be squash-merged or kept for audit trail.

Bisect entry points if regressions land: `git bisect` between Task 4 and Task 5 commits to narrow dispatch-depth / sweep bugs.

---

## Serialization with Layer 1B

**Layer 1B must land first.** 1B edits events.zig:2416-3029 (mutation observer subsystem). 2A edits events.zig:37-354 and :760-844. No overlap in line ranges, no shared structs, no shared functions.

**Rebase protocol:**
1. Wait for 1B merge to master.
2. `git fetch && git rebase origin/master` on the 2A branch.
3. If the rebase succeeds cleanly, run Task 0 again — line numbers may have shifted if 1B added imports or module-level declarations near the top of events.zig. Re-anchor all line refs in `/tmp/2a-audit-notes.md` before proceeding past Task 0.
4. If the rebase surfaces conflicts, they are textual-adjacent (import-list additions) and resolve by union-merge. Never take sides on semantics — both subsystems must retain full functionality.

Do not start Task 1 until the rebase + re-audit completes.

---

## Acceptance criteria (recap from spec §Acceptance)

1. `AddEventListenerOptions-signal.any.js`: **≥12 of 13 subtests passing** (target 13).
2. Zero regressions in `AddEventListenerOptions-once.any.js`, `AddEventListenerOptions-passive.any.js`, `EventListenerOptions-capture.html`, `Event-dispatch-listener-order.html`.
3. `assert_throws_js(TypeError)` for `signal: null` continues to fire on tests 10-11 (null + null-listener). Unchanged from events.zig:165-168.
4. `once + signal` combined removal idempotent; manual remove after once-fire does not crash.
5. `controller.abort()` during dispatch skips already-queued-but-unfired listeners (tests 7-8).
6. `addEventListener` with already-aborted signal is a no-op (test 1 final assertion).
7. Memory: `ListenerRecord` teardown frees callback + signal_ref + abort_handler_ref on all three removal paths.
8. Code review: abort-step detach on manual remove lands in `jsRemoveEventListener` via `freeListenerRecord`. Not optional.

---

## Out of scope (carry forward, do not attempt)

- Native `AbortSignal` reimplementation — keep JS polyfill at web_api.zig:2677-2691.
- `AbortSignal.any()` / `AbortSignal.timeout()` semantics — already implemented, not touched.
- `fetch(…, {signal})` / XHR signal integration — different subsystem.
- WeakRef-based "forget to abort" leak mitigation — design notes only.
- Layer 1B MutationObserver work — separate plan, separate commit trail.
- Shadow DOM abort retargeting — already shadow-safe per spec Risk 5.
