# Layer 2A — AbortSignal Listener Integration Design Spec

**Date**: 2026-04-19
**Layer**: 2A (dom/events, WPT 100% roadmap)
**Target**: `/tmp/wpt/dom/events/AddEventListenerOptions-signal.any.js` (~12 subtests) plus incidental wins in `/tmp/wpt/dom/abort/event.any.js` and `AbortSignal.any.js`.
**Files touched**: `src/js/events.zig` only (polyfill in `src/js/web_api.zig` requires no rewrite).

---

## Context

DOM §2.7.1 step 1.3 (+ step 8) defines two observable behaviors for `addEventListener(type, listener, { signal })`:

1. If `options.signal` is not null **and** `signal.aborted` is already true, **do not add** the listener and return.
2. If the listener is added and `signal` is not null, the user agent MUST register an *abort step* on the signal whose effect, when the signal aborts, is equivalent to calling `removeEventListener(type, listener, capture)` on the same target.

Additionally, DOM §3.1 requires `signal` to be either absent, an `AbortSignal` instance, or `undefined`. Passing `null` explicitly is a TypeError (this is a WebIDL-level constraint because the IDL type is `AbortSignal` with no nullable).

WPT file `AddEventListenerOptions-signal.any.js` encodes all of the above plus combinations with `once`, `capture`, nested dispatch, and "abort during dispatch". suzume currently passes only a subset of these (exact count not measured; note WPT recorded "dom/events 70/252" (27.8%) per MEMORY, with signal behavior known-broken).

The work overlaps with **Layer 1B** (MutationObserver completion) because both edit `events.zig`. The overlap is entirely spatial (same file): 1B lives at events.zig:2373-2749 (mutation observer subsystem), 2A lives at events.zig:37-354 (listener registry + add/remove). No shared data structures, no shared control flow. See *Risk / regression* for the serialization contract.

---

## Spec (DOM §2.7.1 + §3.1)

### §2.7.1 add an event listener (excerpt)

> To **add an event listener**, given an EventTarget object `target` and an event listener `listener`, run these steps:
>
> 1. If `target` is a ServiceWorkerGlobalScope object, its service worker's script resource's has ever been evaluated flag is set, and `listener`'s type matches the type attribute value of any of the service worker events, then report a warning…
> 2. If `listener`'s signal is not null and is aborted, then return.
> 3. If `listener`'s callback is null, then return.
> 4. If `target`'s event listener list does not contain an event listener whose type is `listener`'s type, callback is `listener`'s callback, and capture is `listener`'s capture, then append `listener` to `target`'s event listener list.
> 5. If `listener`'s signal is not null, then add the following abort steps to it:
>    - **Remove an event listener** with `target` and `listener`.

### §3.1 AbortSignal (excerpt)

> Each AbortSignal object has associated **abort steps** (a list of algorithms). To **add an algorithm `algorithm` to an AbortSignal object `signal`**, if `signal` is not aborted, append `algorithm` to `signal`'s abort steps.
>
> To **signal abort**, given an AbortSignal `signal` and reason `reason`, if `signal` is aborted, return; set `signal`'s abort reason to `reason`; for each `algorithm` in `signal`'s abort steps, run `algorithm`; empty `signal`'s abort steps; fire an event named "abort" at `signal`.

### WebIDL signature (for reference)

```webidl
dictionary AddEventListenerOptions : EventListenerOptions {
  boolean passive;
  boolean once = false;
  AbortSignal signal;       // no '?' → null is a TypeError
};
```

---

## Current state

All file:line citations are against `master@beb7a4b`.

### `src/js/events.zig`

- **ListenerRecord** (events.zig:37-43) stores `{ callback, capture, passive, once }`. No `signal` handle, no abort-step handle.
- **jsAddEventListener** (events.zig:119-265) parses the options dict. Relevant block at events.zig:162-182:
  - events.zig:163-164 reads `sig_val = GetPropertyStr("signal")`.
  - events.zig:165-168 throws TypeError if `signal === null` — correct per WebIDL.
  - events.zig:169-172 short-circuits when `signal.aborted` is already true — this matches §2.7.1 step 2.
  - events.zig:173-181 registers the abort hook via a JS eval'd closure: `sig.addEventListener('abort', function(){el.removeEventListener(type,cb,cap);}, {once:true});`.
- Critical defect #1: the closure captures `type, cb, cap` but fires *before* the main listener is appended when `signal.aborted` goes from `false → true` across two `et.dispatchEvent` calls — this path works in isolation, but the closure path does not survive `once + signal` correctly (see "once + signal" below).
- Critical defect #2: the eval'd abort registration runs **before** the listener is actually appended to suzume's internal registry (events.zig:216-263). For the `EventTarget()` path (no underlying lxb node, not window, not document) the code at events.zig:245-256 stores the listener via JS property `__el_<type>` on the object itself. There is **no wiring** that lets this JS property bag observe the abort closure — the closure calls `el.removeEventListener(type, cb, cap)` which *does* land in `jsRemoveEventListener` → events.zig:323-332 path, which removes from `__el_<type>`. So this particular path actually works by accident, provided the JS-stored list is consistent.
- Critical defect #3: `{signal, capture}` variation. The abort closure passes `cap` as a bare boolean (events.zig:177 `JS_NewBool(capture)`). `removeEventListener` accepts either boolean or dict; the boolean form at events.zig:292-293 reads capture via `JS_ToBool`. Works for capture=true.
- Critical defect #4: **nested dispatch / "abort during dispatch"**. The `AddEventListenerOptions-signal.any.js` test "Aborting from a listener does not call future listeners" expects that when listener A aborts the controller mid-dispatch, listener B (registered with the same signal) is removed before it fires. Current implementation: `sig.dispatchEvent('abort')` inside the polyfill (web_api.zig:2689) runs the abort handlers synchronously. Each abort handler calls `removeEventListener` which **mutates** the callback list during iteration at events.zig:822-844 (callEntryListenersFiltered). The iterator snapshot semantics are unclear — need verification (see Test plan). The spec is explicit: abort steps must run **before** the listener is invoked on each tick, meaning a removed listener must not fire even if the dispatch loop has already built its snapshot.
- **ListenerList** (events.zig:45) is a plain `ArrayListUnmanaged(ListenerRecord)`. Removal is O(n) scan by `jsValueEqual(callback, callback) && capture == capture`. There is no stable "listener id" — removal always matches by callback identity + capture flag. This is adequate for spec compliance but means we cannot track "this specific registration's abort step".
- **jsRemoveEventListener** (events.zig:267-354) handles three dispatch paths: owned `lxb_dom_node_t` at events.zig:298-314, JS-level `__el_<type>` at events.zig:315-334, and window/document entries at events.zig:335-352. None of them do any cleanup of an associated abort step. **This is the core bug**: when the user calls `removeEventListener` manually, the abort step stays registered on the signal and will fire later if the signal aborts, calling `removeEventListener` a second time (harmless, it becomes a no-op) — **BUT** the `signal.addEventListener('abort', ...)` registration leaks until the signal itself is GC'd.

### `src/js/web_api.zig`

- **AbortSignal / AbortController polyfill** (web_api.zig:2677-2691). It is a pure-JS polyfill, wrapping:
  - `this.aborted` (plain boolean), `this.reason`, `this.onabort`, `this._evtMap`.
  - `AbortSignal.prototype.addEventListener / removeEventListener / dispatchEvent` — DOM-less mini-implementation over `_evtMap`.
  - `AbortSignal.prototype.throwIfAborted` (web_api.zig:2682).
  - `AbortSignal.abort(reason)` static (web_api.zig:2683), `AbortSignal.timeout(ms)` (web_api.zig:2684), `AbortSignal.any(signals)` (web_api.zig:2685-2686).
  - `AbortController.prototype.abort(reason)` (web_api.zig:2689): flips `signal.aborted = true`, sets `reason`, fires "abort" event synchronously via `s.dispatchEvent(e)` which walks `_evtMap['abort']` under web_api.zig:2681.
- The polyfill is self-contained. The native `jsAddEventListener` at events.zig:174 registers the abort step **on the polyfill's** `addEventListener` (by calling `sig.addEventListener('abort', ...)` from the eval'd JS). That works correctly because the polyfill stores the handler in `_evtMap['abort']` and runs it on dispatch.
- **No rewrite of web_api.zig is required** for Layer 2A. The polyfill already satisfies DOM §3.1 abort-steps via its event listener semantics. All the work is in events.zig.

### Summary of current behavior vs spec

| §2.7.1 / WPT behavior                                          | Current state                              | Evidence                     |
|----------------------------------------------------------------|--------------------------------------------|------------------------------|
| null signal throws TypeError                                   | Correct                                    | events.zig:165-168           |
| Already-aborted signal → listener not added                    | Correct                                    | events.zig:169-172           |
| Abort after add → listener removed before next dispatch        | Correct (via eval'd closure)               | events.zig:173-181           |
| `removeEventListener` detaches the abort step                  | **Missing**                                | events.zig:267-354 (no path) |
| `once + signal` — either trigger removes                       | Partially works (both fire `remove` → idempotent) | events.zig:787 + :174 |
| `capture: true, signal`                                        | Correct (cap threaded through)             | events.zig:177               |
| Abort mid-dispatch removes unfired later listeners             | **Needs verification** (snapshot semantics) | events.zig:822-844           |
| Adding listener mid-dispatch with already-signaled controller → never fires | Correct                           | events.zig:169-172           |

Three of eight behaviors fail or are unverified. Target of ~15 subtests is realistic.

---

## Algorithm

Direct transliteration of DOM §2.7.1 steps 1-5 into the Zig call at events.zig:119-265.

### Step 1: Option parsing (already present)

Keep existing events.zig:144-187 logic:
- Normalize `options` argument: if object → read `{capture, passive, once, signal}`; if boolean → capture only, no signal.
- `signal === null` → `JS_ThrowTypeError`.
- `signal === undefined` → no signal.
- Otherwise retain `sig_val` for steps 2 and 5.

### Step 2: Early abort check

Keep existing events.zig:170-172:
```zig
const aborted = qjs.JS_GetPropertyStr(c, sig_val, "aborted");
defer qjs.JS_FreeValue(c, aborted);
if (qjs.JS_ToBool(c, aborted) > 0) return quickjs.JS_UNDEFINED();
```

This correctly consumes `sig_val` references and returns **before** the listener is appended — matches §2.7.1 step 2.

### Step 3: Register listener

Unchanged (events.zig:216-263). The `ListenerRecord` stored on the internal registry now gains one extra field (see *Abort-steps registry*):

```zig
const ListenerRecord = struct {
    callback: qjs.JSValue,
    capture: bool = false,
    passive: bool = false,
    once: bool = false,
    // New for 2A:
    removed: bool = false,       // soft-delete flag for mid-dispatch abort
    signal_ref: qjs.JSValue = quickjs.JS_UNDEFINED(),  // dup'd signal reference, for detach on removeEventListener
    abort_handler_ref: qjs.JSValue = quickjs.JS_UNDEFINED(), // the `function(){removeEventListener(...)}` closure, so we can detach
};
```

`removed` is set to `true` when the listener is abort-removed or remove-removed mid-dispatch, so the dispatch loop can skip it (same pattern as DOM §2.9 step 5.3: "If listener's removed is true, then continue").

### Step 4: Register abort step

Replace the eval'd closure at events.zig:174-181 with a pair of native helpers:

1. Build a QJS closure that captures `this_val`, `args[0]` (type), `args[1]` (callback), and `capture` — so when the signal fires "abort", it calls our native `jsRemoveEventListener` with identical arguments. Simplest implementation keeps the JS-eval approach but **stores the returned handler** so `removeEventListener` can detach it.
2. Call `sig.addEventListener('abort', <handler>, { once: true })` via the polyfill — this already works; the only change is we now keep the handler's `JSValue` in `record.abort_handler_ref` and keep `sig_val` in `record.signal_ref` via `JS_DupValue`.

Pseudocode:
```zig
if (sig_val.tag != qjs.JS_TAG_UNDEFINED and !quickjs.JS_IsNull(sig_val)) {
    // Build native handler closure — see impl notes below
    const handler = makeAbortHandler(c, this_val, args[0], args[1], capture);
    var ael_args = [3]qjs.JSValue{ /* 'abort' */, handler, /* {once:true} */ };
    _ = callOnSignal(c, sig_val, "addEventListener", &ael_args);
    record.signal_ref = qjs.JS_DupValue(c, sig_val);
    record.abort_handler_ref = qjs.JS_DupValue(c, handler);
    // caller still holds the handler via the signal's _evtMap; we hold a dup so we can remove later
}
```

Implementation note: we can keep the existing `JS_Eval`-based handler factory (events.zig:175) to avoid writing a C-closure allocator; the returned `sig_fn` call at events.zig:178 already produces the handler function inside the JS eval. We just need to modify the JS snippet to **return** the inner abort-function instead of discarding it, so we can capture it for later detach:

```
(function(sig,el,type,cb,cap){
  var h = function(){ el.removeEventListener(type, cb, cap); };
  sig.addEventListener('abort', h, { once:true });
  return h;
})
```

This returned handler is the value stored in `record.abort_handler_ref`.

### Step 5: Listener dispatch — skip removed

Inside `callListenersOnNodeFiltered` (events.zig:760) and `callEntryListenersFiltered` (events.zig:816), add an early continue if `rec.removed`:

```zig
if (rec.removed) continue;
```

This matches DOM §2.9 step 5.3 and ensures "abort during dispatch" removes unfired later listeners in the same dispatch snapshot.

### Step 6: Mutate-on-abort path

When the abort handler fires, it calls `el.removeEventListener(type, cb, cap)` which re-enters `jsRemoveEventListener` at events.zig:267. This path must:
- Find the matching record (by callback identity + capture flag — unchanged).
- Set `record.removed = true` **before** freeing the callback, so an active dispatch loop skips it.
- Free `callback`, `signal_ref`, `abort_handler_ref` (if non-undefined).
- Remove the record from the list (existing `orderedRemove` at events.zig:307).

### Step 7: Manual-remove path detaches abort step

When user calls `removeEventListener(type, cb, cap)` manually, the existing path at events.zig:298-352 finds the record. **New step**: before freeing the record, if `record.signal_ref` is non-undefined and `record.abort_handler_ref` is non-undefined, call `signal_ref.removeEventListener('abort', abort_handler_ref)` via native JS call to detach the abort hook. Then free both dup'd refs.

```zig
if (record.signal_ref.tag != qjs.JS_TAG_UNDEFINED) {
    var rm_args = [2]qjs.JSValue{ /* 'abort' */, record.abort_handler_ref };
    _ = callOnSignal(c, record.signal_ref, "removeEventListener", &rm_args);
    qjs.JS_FreeValue(c, record.signal_ref);
    qjs.JS_FreeValue(c, record.abort_handler_ref);
}
```

---

## Options normalization

Per DOM §2.7.1 WebIDL, the third argument normalizes as:

| Input                                | Result                                                          |
|--------------------------------------|-----------------------------------------------------------------|
| absent / undefined                   | `{capture:false, passive:default, once:false, signal:undefined}` |
| boolean (any truthy)                 | `{capture:boolean, passive:default, once:false, signal:undefined}` |
| object                               | Read each key; missing keys → defaults; `signal:null` → TypeError |

Current events.zig:144-186 already implements this correctly. **No change** in Layer 2A except:
- Ensure `signal` is only honored on the object path (events.zig:145 branch). Current code is already structured this way.
- Ensure the boolean-capture path at events.zig:184-186 does **not** attempt to read `signal` (impossible since we never look up properties on a boolean). Current code is already correct.

One subtle spec detail: **options getters run even when the listener is null** (§2.7.1 step 1 order). events.zig:213-214 performs the null-callback check *after* option parsing (events.zig:144-211), so getter side effects still fire. This is already compliant and must remain.

Additional WPT coverage (`Passing null as the signal should throw (listener is also null)`, test 11 at signal.any.js:140-143) verifies this exact ordering: null-signal TypeError wins over null-listener silent-return. Current events.zig:165-168 fires the TypeError before the null-callback check at events.zig:213 — compliant.

---

## Abort-steps registry

Spec model: §3.1 defines "abort steps" as a list of algorithms on the signal. We model this by delegating to the polyfill's own `_evtMap['abort']` (web_api.zig:2681) — every "abort step" from addEventListener becomes an entry in `_evtMap['abort']`. When the controller aborts (web_api.zig:2689), `s.dispatchEvent(e)` walks `_evtMap['abort']` synchronously in registration order.

**Why this is sufficient**: §3.1 requires `signal`'s abort steps to run in order on "signal abort". The polyfill does exactly that.

**Why we also store `abort_handler_ref` in the ListenerRecord**: so manual `removeEventListener` can *detach* the abort step (§2.7.1 implies the abort step is a closure whose lifetime is bound to the listener; detaching on manual removal is an optimization, not a hard spec requirement — but required to avoid memory leaks under long-running pages).

**Ownership**:
- The polyfill's `_evtMap['abort']` holds a strong reference to the handler function (stored via `_evtMap[t].push({fn:fn, ...})` at web_api.zig:2679).
- Our `ListenerRecord.abort_handler_ref` holds a **duplicated** reference (via `JS_DupValue`) so we can safely pass it back to `sig.removeEventListener` later without worrying about whether the polyfill has already cleared it on a `{once:true}` abort fire.
- On manual removeEventListener: free both `signal_ref` and `abort_handler_ref`. The polyfill drops its entry too (via the `sig.removeEventListener` call we made).
- On abort-fire (`{once:true}`): the polyfill clears its entry (web_api.zig:2681 `if(a[i].once)this.removeEventListener(e.type,a[i].fn);`). Our `ListenerRecord` is gone by then anyway because the abort handler already called `removeEventListener` on the target, which freed the record.

**Native vs JS split**: this design is identical whether `AbortSignal` is the JS polyfill (today) or a future native implementation. The contract is `sig.addEventListener('abort', fn, {once:true})` + `sig.removeEventListener('abort', fn)`. A native `AbortSignal` must expose those two methods on its prototype; the native `jsAddEventListener` treats `sig_val` opaquely via `JS_GetPropertyStr` + `JS_Call`, which works for both forms.

---

## removeEventListener interaction

Two observable cases matter:

### Case A: Abort then removeEventListener

1. `controller.abort()` fires → polyfill's `dispatchEvent('abort')` runs each entry in `_evtMap['abort']`.
2. Each entry calls `target.removeEventListener(type, cb, cap)`.
3. `jsRemoveEventListener` finds the record, marks `removed=true`, calls `sig.removeEventListener('abort', handler_ref)` to detach. Signal has already fired and the polyfill already removed the `{once:true}` entry at web_api.zig:2681 — so our extra `removeEventListener` is a no-op (the polyfill's splice at web_api.zig:2680 handles missing entries safely). Then free callback + dup'd refs.

### Case B: removeEventListener then abort

1. `target.removeEventListener(type, cb, cap)` — `jsRemoveEventListener` finds the record, marks `removed=true`, calls `sig.removeEventListener('abort', handler_ref)` to detach the abort step from the polyfill's `_evtMap['abort']`. Free callback + dup'd refs.
2. Later, `controller.abort()` fires. Polyfill's `_evtMap['abort']` no longer contains our handler (we detached it in step 1). No-op.
3. WPT test "Passing an AbortSignal to addEventListener does not prevent removeEventListener" (signal.any.js:23-34) exercises exactly this sequence — expects `count === 0` after manual remove + dispatch.

### Case C: Signal aborts while no listener is registered

User calls `et.addEventListener('test', handler, {signal})` after `controller.abort()`. events.zig:169-172 returns early without appending. The signal's `_evtMap['abort']` is not touched. WPT "Passing an aborted signal never adds the handler" (signal.any.js:18-20) covers this.

---

## once + signal interaction

Union-of-conditions: either trigger removes the listener.

### once fires first

1. Listener with `{once:true, signal}` fires during dispatch.
2. events.zig:787 runs `once` removal: finds its own record, calls `orderedRemove`, frees `callback`. **Must also** free `signal_ref` / detach abort step (**new code path**).
3. If signal later aborts, the abort handler calls `removeEventListener(type, cb, cap)` — no matching record → no-op.

### signal fires first

1. `controller.abort()` → polyfill fires 'abort' handlers → each calls `removeEventListener`.
2. `jsRemoveEventListener` finds record (still `once` flagged, never fired), marks `removed=true`, frees.
3. Subsequent `dispatchEvent('test')` → record is gone. No fire. WPT "Passing an AbortSignal to addEventListener works with the once flag" (signal.any.js:36-47) covers this.

### Manual remove of once+signal

1. `target.removeEventListener(type, cb)` finds record (once+signal), marks removed, detaches abort step, frees. 
2. WPT "Removing a once listener works with a passed signal" (signal.any.js:49-60) covers this.

**Implementation invariant**: every listener-free path (manual remove, once-fire, abort-fire) must:
1. Set `record.removed = true` first.
2. If `signal_ref != undefined`: call `sig.removeEventListener('abort', abort_handler_ref)` then `JS_FreeValue` both refs.
3. `JS_FreeValue(callback)` and `orderedRemove`.

Extract this into a helper `fn freeListenerRecord(ctx, list, idx)` to avoid duplicating the cleanup across three sites (events.zig:307, :344, :787).

---

## Test plan

Primary test file: `/tmp/wpt/dom/events/AddEventListenerOptions-signal.any.js` (verified exists, 11 tests, ~11-14 subtests depending on html-window/worker harness).

| # | Assertion message                                                        | Subtests | Covered by algorithm step |
|---|--------------------------------------------------------------------------|----------|----------------------------|
| 1 | "Passing an AbortSignal to addEventListener options should allow removing a listener" (4 assert_equals) | 4 | Step 4 + Case A |
| 2 | "Passing an AbortSignal to addEventListener does not prevent removeEventListener" | 1 | Case B |
| 3 | "Passing an AbortSignal to addEventListener works with the once flag"    | 1 | once+signal "signal first" |
| 4 | "Removing a once listener works with a passed signal"                    | 1 | once+signal "manual remove" |
| 5 | "Passing an AbortSignal to multiple listeners"                           | 1 | Multiple records share signal |
| 6 | "Passing an AbortSignal to addEventListener works with the capture flag" | 1 | Capture threading at events.zig:177 |
| 7 | "Aborting from a listener does not call future listeners"                | 1 | `removed` flag mid-dispatch |
| 8 | "Adding then aborting a listener in another listener does not call it"   | 1 | `removed` flag mid-dispatch + re-entry |
| 9 | "Aborting from a nested listener should remove it"                       | 0 (no assert) | Must not crash |
| 10 | "Passing null as the signal should throw"                               | 1 | events.zig:165-168 |
| 11 | "Passing null as the signal should throw (listener is also null)"       | 1 | events.zig:165-168 + option ordering |

**Total: 13 subtests** (from signal.any.js). Secondary: `/tmp/wpt/dom/abort/AbortSignal.any.js` (verified exists, tests signal ergonomics not listener integration) and `abort-signal-any.any.js` may gain 1-2 incidental passes once the detach path is clean. Conservative target: **12 subtests** passing (current estimated: 5-7).

### Verification commands

```bash
cd ~/suzume
zig build
# Run the WPT suite via suzume's runner (assumes WPT subset harness exists):
./zig-out/bin/suzume-wpt --tests dom/events/AddEventListenerOptions-signal.any.js
./zig-out/bin/suzume-wpt --tests dom/abort/AbortSignal.any.js
# Compare before/after pass counts; commit with message referencing Layer 2A.
```

### Regression checks

- `/tmp/wpt/dom/events/AddEventListenerOptions-once.any.js` must not regress (once without signal).
- `/tmp/wpt/dom/events/AddEventListenerOptions-passive.any.js` must not regress.
- `/tmp/wpt/dom/events/EventListenerOptions-capture.html` must not regress.
- `/tmp/wpt/dom/events/Event-dispatch-listener-order.html` (listener order under abort mid-dispatch) — worth checking.

---

## Risk / regression

### Risk 1 — Layer 1B serialization

Layer 1B (MutationObserver completion) also touches `events.zig`. Code regions are disjoint:

| Feature | Line range | Data structures touched |
|---------|------------|-------------------------|
| Layer 2A (this spec) | events.zig:37-354, :760-844 | `ListenerRecord`, `ListenerEntry`, `WindowListenerEntry`, `jsAddEventListener`, `jsRemoveEventListener`, `callListenersOnNodeFiltered`, `callEntryListenersFiltered` |
| Layer 1B (MutationObserver) | events.zig:2416-2780 | `MutationRecord`, `MutationObserverEntry`, `mutation_observers`, `recordMutation*` family, `flushMutationObservers` |

No struct is shared. No function is shared. Sequential merge is risk-free provided both branches rebase from the same master. A single rebase conflict class exists: if Layer 1B adds a new pub symbol near the top of events.zig (e.g., extending the imports list or adding a global), the merge will textually conflict but semantically integrate. **Recommendation**: merge 1B first (more disruptive subsystem), then rebase 2A on top. Per roadmap Wave 1 sequencing at roadmap.md:275-279, this is already the planned order.

### Risk 2 — Mid-dispatch removal correctness

The `removed` flag + early-continue pattern is the canonical DOM §2.9 step 5.3 fix, but must be applied at both dispatch helpers (events.zig:760 and :816). Missing one site leaves tests 7-8 failing. Mitigation: add the check once in a `shouldSkipListener(rec)` helper; call from both sites.

### Risk 3 — Double-free under abort-fire + manual-remove race

If a handler runs `controller.abort()` and then `target.removeEventListener(...)` in the same microtask, the polyfill's synchronous abort fire will execute the abort handler (which calls `removeEventListener`). The **user's** subsequent manual call finds no matching record and is a no-op. No double free. Safe.

### Risk 4 — JS-level listener path (`__el_<type>`) at events.zig:245-256

This path stores listeners as a JS array property on the target instead of in our native registry. It has no `removed` flag, no `signal_ref` tracking. Abort integration still works (the abort closure calls `removeEventListener` which re-enters events.zig and hits the JS-level removal at events.zig:323-332), but *mid-dispatch abort on JS-path listeners* may not obey the `removed` flag because dispatch iterates the JS array, not our struct. **Impact assessment**: WPT's `AddEventListenerOptions-signal.any.js` uses `new EventTarget()` (signal.any.js:8) which routes through the JS-level path. Verify during implementation whether JS-path dispatch snapshots the array or iterates live. If live, no action needed; if snapshotted, mirror the `removed` idea with a `.removed` boolean inserted into the JS object. **Empirical check required in test plan**.

### Risk 5 — Native AbortSignal migration

If a future patch replaces the JS polyfill (web_api.zig:2677-2691) with a native Zig AbortSignal, this design still holds as long as the native form still exposes `addEventListener('abort', fn, {once:true})` + `removeEventListener('abort', fn)` + a boolean `.aborted` property. Spec compliance is written against the abstract interface, so only the polyfill file changes. Zero impact on events.zig.

### Risk 6 — Memory: abort handler leak on GC'd target

If the user drops all references to the target without calling `removeEventListener` and without aborting the signal, our `signal._evtMap['abort']` still holds the closure which captures `el` (target). `el` is only GC-able if nothing references it — but the closure *does* reference it. **This is the classic "forget to abort" leak** documented in the spec. It is out of scope for 2A (fixing it requires WeakRef plumbing). Note in design but do not fix.

---

## Acceptance criteria

1. `AddEventListenerOptions-signal.any.js`: **≥ 12 of 13 subtests passing** (target: all 13; risk-adjusted floor).
2. No regression in `AddEventListenerOptions-once.any.js`, `AddEventListenerOptions-passive.any.js`, `EventListenerOptions-capture.html`.
3. `assert_throws_js(TypeError)` for `signal: null` fires on both signal.any.js tests 10 and 11 (null + null-listener).
4. `once + signal` combined removal is idempotent — manual remove after once-fire does not crash.
5. `controller.abort()` during dispatch prevents already-queued-but-unfired listeners from running (tests 7-8).
6. Adding a listener with `{signal}` after `controller.abort()` is a no-op, verified by test 1 final assertion (signal.any.js:18-20).
7. Memory: `ListenerRecord` cleanup path frees `callback`, `signal_ref`, `abort_handler_ref` on all three removal paths (abort-fire, manual-remove, once-fire). Verified via valgrind or AddressSanitizer run on the suzume-wpt binary.
8. **Code review criterion**: abort-step detach on manual remove lands in `jsRemoveEventListener`. Not optional.

---

## Out of scope

- Native `AbortSignal` reimplementation (stays JS polyfill at web_api.zig:2677-2691).
- `AbortSignal.any()` semantics (web_api.zig:2685-2686) — already implemented; not touched.
- `AbortSignal.timeout(ms)` microtask ordering vs `setTimeout` queue — orthogonal to listener integration.
- `fetch(..., {signal})` / XHR signal integration — different subsystem, not part of DOM §2.7.1.
- WeakRef-based leak mitigation for "forget to abort" scenarios — design notes only, implementation deferred.
- Layer 1B MutationObserver changes — separate spec, separate commit.
- Shadow DOM retargeting interactions with abort — already shadow-safe because the abort step only calls `removeEventListener` by object identity; no event-path semantics involved.
- CSSOM / HTML reflection — different layers of the roadmap.
