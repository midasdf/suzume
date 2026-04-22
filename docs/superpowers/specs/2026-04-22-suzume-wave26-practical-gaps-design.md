# Wave 26 — Practical-Use Gap Fill Design

**Date**: 2026-04-22
**Branch target**: `main` (tag `wave26-final` on completion)
**Baseline**: commit `7a4e39b` (Wave 25 final, 2026-04-22)
**Scope lane**: B-4 — Observer + Scroll + Form completion (hybrid depth × WPT+real-site verification)

---

## 1. Context & Motivation

The user requested practical-use improvements focused on Phase C roadmap blockers (`ResizeObserver`, `IntersectionObserver`, `element.scroll*`, `scrollIntoView`, `form.submit()`, `reportValidity`, `setCustomValidity`). A pre-design survey revealed that **all of these APIs already exist** in the codebase:

| API | File | Status |
|-----|------|--------|
| `ResizeObserver` | `src/js/resize_observer.zig` (338 lines) | constructor, observe, unobserve, disconnect, flush; 3 box modes (content/border/device-pixel-content) recognized |
| `IntersectionObserver` | `src/js/intersection_observer.zig` (473 lines) | constructor, observe, unobserve, disconnect, takeRecords; rootMargin + thresholds + crossesThreshold |
| `element.scroll/scrollTo/scrollBy` | `src/js/dom_element.zig:2848` | Implemented; stores position in `g_elem_scroll` map |
| `scrollIntoView` | `src/js/dom_element.zig:2907`, registered at `src/js/dom_api.zig:3622` | **Stub** (function returns `undefined` with no work; comment: "actual scroll-to-element requires layout position lookup") |
| `form.submit/requestSubmit` | `src/js/dom_element.zig:3130-3167` | Shipped in Wave 25 |
| `checkValidity/reportValidity/setCustomValidity` | `src/js/dom_element.zig:3226-3330` + JS polyfill in `src/js/dom_api.zig:3946-4035` | Present |
| `:valid / :invalid / :required / :optional / :placeholder-shown` | `src/js/dom_selector.zig:517-549, 1211-1335` | Implemented |

**Therefore Wave 26 is reframed from "build B-4" to "fill the observed gaps in B-4 implementations"** — i.e., make the existing surface genuinely useful for real sites and push WPT compliance on the relevant areas.

Observed gaps (verified via code reading, documented below):
- `IntersectionObserver.rootMargin` treats `%` as `px` (file comment line 61: "CSS %-based margin NYI"; line 95: "we treat % as px for now").
- `IntersectionObserver` non-viewport `root` not supported (line 121: "Non-null root NYI").
- `ResizeObserver.devicePixelContentBoxSize` uses DPR=1 (line 160: "DPR assumed 1 (no DPI info available)").
- `element.scroll*` position is written to a side map but nothing is known to **consume** the value during layout/paint (i.e., the scrolled offset may not affect rendering at all).
- `scrollIntoView` compliance with `{block, inline, behavior}` options not yet audited.
- `stepMismatch` in `ValidityState` polyfill is simplified (`src/js/dom_api.zig:4026`: `var stepMismatch = false;`).
- `ValidityState` flags are re-evaluated only on getter access — need to verify that `input`/`change` events (and pseudo-class cascade invalidation) actually re-run.

---

## 2. Goals

**Primary (must-land):**
1. `element.scroll/scrollTo/scrollBy/scrollIntoView` produce visible results on real pages with scrollable overflow containers.
2. `IntersectionObserver.rootMargin` supports `%` units per spec (resolved against root bounds).
3. `ValidityState.stepMismatch` is computed correctly for `<input type="number|range|date|time|datetime-local|month|week">`.
4. `:valid`/`:invalid` pseudo-class cascade invalidates on every `input`/`change` event so CSS reflects live state.

**Secondary (land if room):**
5. `IntersectionObserver` custom (non-viewport) `root` element.
6. `scrollIntoView` `{behavior: "smooth"}` animation (simple ease-out; RPi Zero 2W budget permitting).
7. `ResizeObserver.devicePixelContentBoxSize` honors `env.devicePixelRatio` if the layout/paint subsystem exposes it.

**Non-goals (explicitly deferred):**
- Scroll anchoring (CSS Scroll Anchoring L1).
- `ScrollTimeline` / scroll-linked animations.
- `CSS scroll-snap-*` (layout module, separate work).
- Rewriting `ValidityState` as a native Zig struct (JS polyfill shape must remain compatible).
- `form.checkValidity()` fieldset-disabled edge cases beyond what `dom_selector.zig` already covers.

---

## 3. Architecture

### 3.1 Component boundaries

```
┌─────────────────────────────────────────────────────────────────┐
│                       JS surface (QuickJS)                      │
│  Element.prototype.scroll/scrollTo/scrollBy/scrollIntoView       │
│  IntersectionObserver.prototype.observe (root-aware)             │
│  HTMLInputElement.validity.stepMismatch (live)                   │
│  MutationObserver hook → :valid/:invalid cascade invalidation    │
└───────────────┬─────────────────────────────┬────────────────────┘
                │                             │
┌───────────────┴────────────┐   ┌───────────┴──────────────────┐
│ dom_element.zig             │   │ intersection_observer.zig    │
│  - elementScroll*           │   │  - parseRootMargin (px+%)    │
│  - elementScrollIntoView    │   │  - getRootBounds (% resolve) │
│  - g_elem_scroll write path │   │  - root element lookup       │
└───────────────┬────────────┘   └─────────────────────────────┘
                │
┌───────────────┴──────────────────┐
│ layout/block.zig, layout/flex.zig │
│  - apply g_elem_scroll offset    │
│    when translating child origin │
└─────────────────────────────────┘
```

### 3.2 Data flow for scroll actually moving content

Today: JS writes to `g_elem_scroll[element_ptr] = { top, left }`. Layout reads nothing from this map. Paint therefore doesn't know the element is scrolled.

Proposed: at **paint time**, when walking the box tree, look up `g_elem_scroll[@intFromPtr(element)]` for each descendant whose computed `overflow-x`/`overflow-y` is `scroll` or `auto`; subtract that offset from the child-origin translation used for subsequent drawing calls. Layout output (box rects) is unchanged — only the paint-time walker applies the offset. This keeps `dom/nodes` WPT numbers (which read post-layout geometry) stable.

- Read point: the paint/render walker in `src/render/*.zig` (to be confirmed during Track A investigation; may fall back to `src/layout/*` if rendering is interleaved).
- Write point: `g_elem_scroll` (already set by JS `scrollTop=`, `scrollLeft=`, `scroll*()`).
- Clamp: clamp `top` to `[0, max(0, scroll_height - client_height)]`, same for `left`. `scrollHeight`/`scrollWidth` today mirror `clientHeight`/`clientWidth` — Track A **must** also compute the true overflow extent (max of descendant border-box bottom/right minus element's content-box top/left), otherwise clamping uses stale bounds.
- Observers: a successful scroll mutation should set `dom_api.scroll_events_pending = true` so the frame loop fires a `scroll` event on the element + invokes `IntersectionObserver` flush.

### 3.3 IntersectionObserver `%` rootMargin

Current `parseRootMargin` strips the unit and keeps the raw number. New behavior:

- Parse each value as `{ number: f32, is_percent: bool }`.
- At flush time inside `getRootBounds`, resolve percentages against:
  - top/bottom margin → `root_height * pct / 100`
  - left/right margin → `root_width * pct / 100`
  (per IntersectionObserver spec §3.3 "percentage values are resolved relative to the root's height or width").
- Keep the existing 1/2/3/4-value shorthand expansion.

### 3.4 ValidityState live cascade

- Wrap the setter for `HTMLInputElement.value`/`checked` and the `input`/`change` dispatch to call a single helper `invalidateValidityStyle(element)` that marks the element + its ancestor `<form>`/`<fieldset>` as needing selector re-evaluation.
- `stepMismatch`: implement in the JS polyfill at `src/js/dom_api.zig` around line 4026. Algorithm per HTML §4.10.18.4 "suffering from a step mismatch":
  - If `type` is not one of `number|range|date|time|datetime-local|month|week` → `stepMismatch = false`.
  - Read effective `step` value (default: `1` for integer-typed inputs, type-specific defaults per §4.10.5 table). If `step="any"` → `stepMismatch = false`.
  - Compute `step_base`: `min` attribute if set and parsable; else `value` attribute if set; else `0` for `number`/`range`, `1970-01-01` epoch for date/time types (converted to the type's numeric representation: seconds for time, ms since epoch for date/datetime, ISO week number for week, etc.).
  - Convert current `value` to the same numeric representation. If unparsable, `stepMismatch = false` (covered by `typeMismatch`).
  - Let `r = (value − step_base) mod step`. If `r != 0` and `r != step` (within floating tolerance `1e-9 * max(|step|, 1)`), set `stepMismatch = true`.
  - **Wave 26 scope**: land `number`/`range` only; date-family types deferred to a follow-up commit or Wave 27 (tracked as TODO in the polyfill).

### 3.5 scrollIntoView polish (stretch)

- Honor `options.block` (`start`/`center`/`end`/`nearest`) and `options.inline` (same).
- `options.behavior === "smooth"`: schedule an animation frame loop that eases the scroll offset over ~300ms via `requestAnimationFrame` (QuickJS already exposes rAF via the event loop). Fall back to instant on absence.

---

## 4. Track breakdown (5 parallel lanes for Phase 1)

| Track | Subject | Files touched | Risk | Est size | Depends on |
|-------|---------|---------------|------|----------|------------|
| **A** | `scroll*()` actually moves content | `dom_element.zig`, `dom_api.zig`, `layout/{block,flex,inline}.zig`, `render/*.zig` (paint translate) | High | L | — |
| **B** | `scrollIntoView` alignment + behavior | `dom_element.zig` (`elementScrollIntoView`) | Med | M | A (shares scroll clamp helper) |
| **C** | IntersectionObserver `rootMargin %` + custom `root` | `intersection_observer.zig` | Low | S | — |
| **D** | ValidityState `stepMismatch` + live `:valid`/`:invalid` | `dom_api.zig` (polyfill), `events.zig` (input/change hook), `dom_selector.zig` (cascade invalidate) | Med | M | — |
| **E** | ResizeObserver DPR propagation | `resize_observer.zig`, env/DPR accessor | Low | S | — |

**Conflicts**: A and B both mutate `dom_element.zig` scroll block (lines 2720–2950); run them sequentially on the same file (A first, B rebases). C/D/E are in disjoint files and run fully parallel. A also touches layout files; D touches events.zig — none of these overlap.

**Commit cadence**: one `feat(...)` commit per track, squash-landed on `main`, tag `wave26-final` at the end.

---

## 5. Testing & verification (Phase 2)

### 5.1 Unit tests (Zig `zig build test`)

- `intersection_observer.zig` — add tests covering `"10%"`, `"10% 20%"`, `"-5% 10px"` → resolved against a synthetic 1000×800 viewport.
- `dom_element.zig` — scroll clamp: `element.scrollTop = 9999` on a 300px container with 1000px content → clamped to 700.
- `dom_element.zig` — `scrollIntoView({block:"end"})` on a container with a child below fold → container `scrollTop` equals `child.offsetTop + child.offsetHeight − container.clientHeight`.

### 5.2 WPT measurement

Run baseline **before** starting Track A:
```
TIMEOUT=30 tests/wpt/run_wpt_parallel.sh --jobs 4 \
  resize-observer intersection-observer cssom-view \
  html/semantics/forms/the-input-element html/semantics/forms/constraints
```

Record baseline subtest counts per area into the design spec's "Results" section after each track lands. Track D success criterion: non-decreasing across `forms/constraints`. Track C success: non-decreasing on `intersection-observer`. Track A+B success: visible delta on `cssom-view` (even if only a few subtests move — this area is large and most tests need a full viewport).

### 5.3 Real-site smoke tests

Load each URL in suzume, manually scroll / interact, and document pass/fail:

| URL | Pass criteria |
|-----|---------------|
| Hacker News (`news.ycombinator.com`) | `window.scrollTo(0,0)` returns to top; inner listings scroll |
| Wikipedia article | Clicking TOC jump uses `scrollIntoView`; target is visible on screen |
| GitHub issue search | `input.required` fields show `:invalid` red border until filled |
| Any page with lazy-load images (e.g. Unsplash feed clone fixture) | Images below fold have their `IntersectionObserver` callback fire when scrolled near viewport |

Each of the four sites must either pass or have the failure mode recorded with a follow-up ticket.

### 5.4 Regression guard

After each track merges to `main`:
- Run `zig build && zig build test`.
- Re-run WPT on the track's primary area + `dom/nodes` and `dom/events` (regression canaries). Any drop >5 subtests in a canary area blocks the merge.

---

## 6. Error handling & edge cases

- **Scroll on non-scrollable element**: already a no-op via `isScrollableElement`. Keep that guard; document it in Track A.
- **`scrollTop` negative / NaN / Infinity**: QuickJS `JS_ToFloat64` returns finite or NaN; clamp NaN to 0, ±Infinity to clamp bound.
- **IntersectionObserver `rootMargin` parse failure**: preserve current behavior (fall through to zero margin); do not throw.
- **`ValidityState` during form disabled state**: `willValidate === false` path already short-circuits `checkValidity`; extend to `:valid`/`:invalid` selector matching so disabled fields never match `:invalid`.
- **`stepMismatch` for non-numeric inputs (text, email, etc.)**: return `false`. Only `number|range|date|time|datetime-local|month|week` participate.

---

## 7. Risks & mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Track A breaks existing WPT dom/nodes by changing child-origin math | High | Gate the scroll offset subtraction behind `g_elem_scroll` map lookup — zero offset = identity transform, so untouched elements keep exact old coords. Run `dom/nodes` canary after every commit. |
| `stepMismatch` for date inputs needs Date parsing in kotori | Med | Start with `number`/`range` only in a single commit; add date types in a second commit or defer to Wave 27 if budget blown. Mark deferred types as `stepMismatch = false` with a TODO. |
| IntersectionObserver custom `root` introduces lookup cost per flush | Low | Custom root is an optional pointer; when null, skip lookup. Cached element pointer resolved once at `observe()` time. |
| Smooth scroll animation uses rAF & may starve on 512MB RPi Zero 2W | Med | Tier as secondary goal; if the rAF budget is tight, fall back to instant. Gate via `env.prefers_reduced_motion` when available. |

---

## 8. Plan deliverable

After this spec is approved, the writing-plans skill will produce an implementation plan covering:
- Ordered steps per track (A → B, then C/D/E in parallel)
- Per-step file diffs, test commands, and verification commands
- Commit boundaries and PR structure
- WPT baseline/final measurement steps

---

## 9. Results

### 9.1 Baseline WPT (2026-04-22, pre-Track work, branch `wave26-practical-gaps` @ `77937ed`)

| Area | Pass | Total | % |
|------|------|-------|---|
| resize-observer | 0 | 14 | 0.0% |
| intersection-observer | 1 | 18 | 5.6% |
| cssom-view | 0 | 0 | — (1 file errored) |
| html/semantics/forms/the-input-element | 153 | 984 | 15.5% |
| html/semantics/forms/constraints | 0 | 33 | 0.0% |

**Notable baseline observations (surprising):**
- `forms/constraints`: 0 subtests pass — traced to WPT harness errors "Cannot read properties of undefined (reading 'valid')" / "willValidate expected true got undefined". Indicates the existing `ValidityState` polyfill isn't reaching `textarea` / `select` elements at runtime despite the polyfill loop targeting `HTMLTextAreaElement`/`HTMLSelectElement`. This is a **pre-existing bug, out of Wave 26 scope**; documented as a follow-up candidate.
- `intersection-observer`: 60/118 test files errored. Suggests harness timeout, not subtest failures — raising `TIMEOUT` above 30 for this area is a separate knob.
- `cssom-view`: single-file error — the area's default entry file isn't producing subtests with our runner. Needs a broader glob or different test-file discovery.

### 9.2 Per-track deltas (filled as tracks land)

- **Post Track E** (DPR accessor + resize_observer scaling): no expected change since DPR=1 on this platform; ran to verify no regression.
- **Post Track C** (rootMargin %): _TBD post-measurement_
- **Post Track D1** (stepMismatch number/range): _TBD post-measurement_
- **Post Track A** (scroll paint-time): _TBD — DEFERRED from this session_
- **Post Track B** (scrollIntoView): _TBD — DEFERRED from this session_

### 9.3 Real-site smoke results

_TBD — deferred to the session that lands Tracks A+B (scroll paint integration)._

### 9.4 Final tag

`wave26-final` — pending Track A+B completion.
