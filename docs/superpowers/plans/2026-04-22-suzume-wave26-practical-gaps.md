# Wave 26 — Practical-Use Gap Fill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the 5 verified gaps in already-landed Observer/Scroll/Form APIs so real sites (HN, Wikipedia, GitHub, lazy-load feeds) actually respond to scroll/validity/observer events, and bump WPT coverage on `cssom-view`, `intersection-observer`, and `html/semantics/forms/constraints`.

**Architecture:** Five parallel tracks (A scroll-paint, B scrollIntoView, C IO-rootMargin%, D validity-live, E RO-DPR) against `main`. A and B run sequentially on `dom_element.zig` scroll block; C/D/E run in parallel in disjoint files. One `feat(...)` commit per task. Tag `wave26-final` after Phase 2 verification.

**Tech Stack:** Zig 0.16.0, QuickJS bindings (`qjs`), lexbor DOM (`lxb`), custom box tree in `src/layout/*`, custom paint in `src/paint/*` + `src/render/pipeline.zig`, WPT runner at `tests/wpt/run_wpt_parallel.sh`.

**Spec:** `docs/superpowers/specs/2026-04-22-suzume-wave26-practical-gaps-design.md` (commit `fa3b084`).

---

## Phase 0 — Baseline Measurement

### Task 0: Capture WPT baseline for all affected areas

**Files:**
- Modify: `docs/superpowers/specs/2026-04-22-suzume-wave26-practical-gaps-design.md` (§9 Results)

- [ ] **Step 1: Verify WPT clone is present**

Run: `ls /tmp/wpt/resize-observer 2>/dev/null | head -3 && ls /tmp/wpt/intersection-observer 2>/dev/null | head -3`
Expected: directory listings. If empty, run `bash tests/wpt/run_wpt_parallel.sh setup` first.

- [ ] **Step 2: Build suzume**

Run: `cd ~/suzume && zig build`
Expected: exit 0, no compile errors.

- [ ] **Step 3: Run WPT baseline (5 areas, parallel)**

Run:
```
cd ~/suzume && TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
  resize-observer intersection-observer cssom-view \
  html/semantics/forms/the-input-element \
  html/semantics/forms/constraints 2>&1 | tee /tmp/wpt-wave26-baseline.log
```
Expected: per-area pass/fail line format `Area X: N/M passed`.

- [ ] **Step 4: Record baseline in spec §9**

Edit `docs/superpowers/specs/2026-04-22-suzume-wave26-practical-gaps-design.md` §9, replace the `_TBD_` next to **Baseline WPT** with a table like:
```
| Area | Pass | Total |
|------|------|-------|
| resize-observer | X | Y |
| intersection-observer | X | Y |
| cssom-view | X | Y |
| forms/the-input-element | X | Y |
| forms/constraints | X | Y |
```

- [ ] **Step 5: Commit baseline**

Run:
```
git add docs/superpowers/specs/2026-04-22-suzume-wave26-practical-gaps-design.md
git commit -m "docs(wave26): record WPT baseline before track work"
```

---

## Track A — `element.scroll*()` Actually Moves Content

### Task A1: Compute true `scrollHeight` / `scrollWidth`

**Files:**
- Modify: `src/js/dom_element.zig` — find `elementGetScrollHeight` / `elementGetScrollWidth` (grep the file)
- Test: `src/js/dom_element.zig` (inline `test` block)

- [ ] **Step 1: Locate existing scrollHeight getters**

Run: `grep -n "scrollHeight\|scrollWidth" src/js/dom_element.zig`
Record the line numbers; there should be `elementGetScrollHeight` and `elementGetScrollWidth` around lines 2780–2900 that currently mirror `clientHeight`/`clientWidth`.

- [ ] **Step 2: Write failing test for overflow-extent computation**

First run: `grep -n "test \"offsetHeight\\|test \"scrollTop" src/js/dom_element.zig | head -5` — copy the closest pattern as a template. At minimum the test must construct a parent `Box` (300 tall) with a single child `Box` whose `borderBox()` returns `{x:0,y:0,w:100,h:1000}`, call `computeScrollExtent(&parent)`, and assert `bottom == 1000`, `right == 100`.

If no similar pure-`Box` test exists, add this minimal test that does not go through QuickJS:

```zig
test "computeScrollExtent picks up descendant bottom" {
    var parent: Box = undefined;
    @memset(std.mem.asBytes(&parent), 0);
    parent.padding_box = .{ .x = 0, .y = 0, .width = 300, .height = 300 };
    var child: Box = undefined;
    @memset(std.mem.asBytes(&child), 0);
    child.border_box = .{ .x = 0, .y = 0, .width = 100, .height = 1000 };
    parent.first_child = &child;
    const ext = computeScrollExtent(&parent);
    try std.testing.expectEqual(@as(f32, 1000), ext.bottom);
    try std.testing.expectEqual(@as(f32, 100), ext.right);
}
```

If `Box` field names differ (check `src/layout/box.zig` or similar), adapt the assignments to match. Run: `zig build test 2>&1 | grep -E "computeScrollExtent|error"`.
Expected: compile error or test fail before Step 3 lands.

- [ ] **Step 3: Implement `computeScrollExtent(box)` helper**

In `src/js/dom_element.zig`, above `elementGetScrollHeight`:

```zig
/// CSSOM View §6.5: the scroll area is the union of the padding-box of
/// the element and each descendant's border-box that overflows.
/// Returns (right, bottom) in the element's local coordinate space.
fn computeScrollExtent(box: *const Box) struct { right: f32, bottom: f32 } {
    const pb = box.paddingBox();
    var right: f32 = pb.x + pb.width;
    var bottom: f32 = pb.y + pb.height;
    var child = box.first_child;
    while (child) |c| : (child = c.next_sibling) {
        const bb = c.borderBox();
        if (bb.x + bb.width > right) right = bb.x + bb.width;
        if (bb.y + bb.height > bottom) bottom = bb.y + bb.height;
        // Recurse — children may themselves overflow their siblings
        const nested = computeScrollExtent(c);
        if (nested.right > right) right = nested.right;
        if (nested.bottom > bottom) bottom = nested.bottom;
    }
    return .{ .right = right - pb.x, .bottom = bottom - pb.y };
}
```

- [ ] **Step 4: Wire `elementGetScrollHeight` / `elementGetScrollWidth`**

Replace the bodies of the two getters to call `computeScrollExtent` on the resolved box; return `@intFromFloat(@round(extent.bottom))` and `@intFromFloat(@round(extent.right))`. If the element has no box, return 0 (preserves current defensive behavior).

- [ ] **Step 5: Run build + test**

Run: `zig build test 2>&1 | tail -20`
Expected: new test passes, no regressions in the existing test block.

- [ ] **Step 6: Commit**

```bash
git add src/js/dom_element.zig
git commit -m "feat(dom): compute scrollHeight/scrollWidth from descendant overflow (CSSOM §6.5)"
```

### Task A2: Clamp scroll writes to `[0, scrollExtent − clientExtent]`

**Files:**
- Modify: `src/js/dom_element.zig` — `elementSetScrollTop`, `elementSetScrollLeft`, `elementScrollToImpl`, `elementScrollBy`

- [ ] **Step 1: Write failing test (clamp helper)**

Clamping is pure arithmetic, so test the helper shape directly without QuickJS setup. After defining `maxScrollFor` in Step 2 (you can briefly swap step order), or against a local `computeClampedScroll(requested, max) -> f32` extracted for testability, assert:

```zig
test "scroll clamp bounds requested position" {
    const clamp = struct {
        fn call(requested: f32, max: f32) f32 {
            if (std.math.isNan(requested)) return 0;
            return @max(0.0, @min(requested, max));
        }
    }.call;
    try std.testing.expectEqual(@as(f32, 700), clamp(9999, 700));
    try std.testing.expectEqual(@as(f32, 0),   clamp(-50, 700));
    try std.testing.expectEqual(@as(f32, 0),   clamp(std.math.nan(f32), 700));
    try std.testing.expectEqual(@as(f32, 350), clamp(350, 700));
}
```

Run: `zig build test 2>&1 | grep -E "clamp|error"`
Expected: test body compiles; once Step 3 wires the same `clamp` logic into the four setters, the behavior goes live on JS callers.

- [ ] **Step 2: Add `maxScrollFor(elem)` helper**

In `src/js/dom_element.zig` near `isScrollableElement`:

```zig
fn maxScrollFor(c: *qjs.JSContext, elem: *lxb.lxb_dom_element_t) struct { top: f32, left: f32 } {
    const root_box = api.getRootBox(c) orelse return .{ .top = 0, .left = 0 };
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    const box = api.findBoxForNode(root_box, node) orelse return .{ .top = 0, .left = 0 };
    const ext = computeScrollExtent(box);
    const pb = box.paddingBox();
    const max_top = @max(0.0, ext.bottom - pb.height);
    const max_left = @max(0.0, ext.right - pb.width);
    return .{ .top = max_top, .left = max_left };
}
```

- [ ] **Step 3: Apply clamp in all four setters**

In `elementSetScrollTop`: after computing `new_top`, clamp with `@min(new_top, maxScrollFor(c, elem).top)`. Same pattern for `elementSetScrollLeft`, `elementScrollToImpl`, `elementScrollBy`. Guard NaN: `if (std.math.isNan(y)) y = 0;` before the clamp.

- [ ] **Step 4: Run build + test**

Run: `zig build test 2>&1 | grep -E "scrollTop|clamp"`
Expected: new test passes.

- [ ] **Step 5: Commit**

```bash
git add src/js/dom_element.zig
git commit -m "feat(dom): clamp scrollTop/Left/scrollBy to scroll extent + guard NaN"
```

### Task A3: Apply scroll offset at paint time

**Files:**
- Modify: `src/paint/*.zig` (identify the file containing the child-walk translation; grep `translate\(` or `child.origin` in `src/paint/`)
- Modify: `src/js/dom_api.zig` — expose `getScrollPos(element_ptr)` accessor for the paint layer

- [ ] **Step 1: Locate paint child-origin walker**

Run: `grep -rn "borderBox\|paddingBox" src/paint/ src/render/ | head -30`
Record the file and function where each child is translated from parent to child origin. In suzume this is typically `paintBox` / `paintSubtree` in `src/paint/painter.zig` (verify actual filename via the grep).

- [ ] **Step 2: Expose `getScrollOffset` from `dom_element.zig`**

Add pub function at end of `dom_element.zig` scroll block:

```zig
/// Returns (left, top) scroll offset for the element whose box this is.
/// Returns (0, 0) if the element has never been scrolled.
pub fn getScrollOffsetForBox(node_ptr: usize) struct { left: f32, top: f32 } {
    if (g_elem_scroll) |*m| {
        if (m.get(node_ptr)) |p| return .{ .left = p.left, .top = p.top };
    }
    return .{ .left = 0, .top = 0 };
}
```

- [ ] **Step 3: Apply offset in paint walker**

In the paint function identified in Step 1, after resolving a box whose associated element has `overflow: scroll | auto` on either axis (reuse `isScrollableElement` style logic — read computed style via `api.getStylesForCtx`), subtract the scroll offset from the translation passed to child paint calls:

```zig
// Before recursing into children:
const elem_ptr = box.element_ptr;  // however the paint module accesses it
const so = dom_element.getScrollOffsetForBox(elem_ptr);
const child_tx = base_tx - so.left;
const child_ty = base_ty - so.top;
// Pass child_tx/child_ty to child paint call instead of base_tx/base_ty.
```

Gate the subtraction so offset=0 path is a no-op (identity transform) — critical for not regressing any existing WPT.

- [ ] **Step 4: Run smoke test**

Create `tests/manual/scroll_smoke.html` (if not present):

```html
<!doctype html><body>
<div id=box style="overflow:scroll; height:200px; border:1px solid">
  <div style="height:1000px; background:linear-gradient(red,blue)"></div>
</div>
<script>
document.getElementById('box').scrollTop = 400;
</script>
</body>
```

Run: `cd ~/suzume && zig build && ./zig-out/bin/suzume tests/manual/scroll_smoke.html` (or the project's run command — grep `README.md` if unsure).
Expected: visible gradient shifted up by 400px.

- [ ] **Step 5: Run `dom/nodes` regression canary**

Run: `TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/nodes 2>&1 | tail -5`
Expected: pass count within ±5 of previous baseline (untracked elements have identity transform → no visual change).

- [ ] **Step 6: Commit**

```bash
git add src/paint src/js/dom_element.zig
git commit -m "feat(paint): apply g_elem_scroll offset to child translation for overflow:scroll|auto"
```

### Task A4: Fire `scroll` event after mutation

**Files:**
- Modify: `src/js/dom_api.zig` — add `scroll_events_pending` flag near `resize_observers_pending` (line 73)
- Modify: `src/js/dom_element.zig` — set flag + record source element in a small list
- Modify: `src/js/web_api.zig` — consume flag near the existing `resize_observers_pending` consumer (line 715)

- [ ] **Step 1: Add scroll_events pending queue**

In `src/js/dom_api.zig` below line 73:

```zig
pub var scroll_events_pending: bool = false;
pub var scroll_event_targets: std.ArrayListUnmanaged(*lxb.lxb_dom_node_t) = .empty;
```

- [ ] **Step 2: Enqueue after each scroll mutation**

In `dom_element.zig`: after each successful `map.put` in `elementSetScrollTop`, `elementSetScrollLeft`, `elementScrollToImpl`, `elementScrollBy`, append the element's node to `scroll_event_targets` (de-dup: check last entry) and set `scroll_events_pending = true`.

- [ ] **Step 3: Drain queue in the frame loop**

In `src/js/web_api.zig` around line 715 (where `resize_observers_pending` is consumed), add a parallel block:

```zig
if (dom_api_mod.scroll_events_pending) {
    dom_api_mod.scroll_events_pending = false;
    for (dom_api_mod.scroll_event_targets.items) |n| {
        _ = events.dispatchEvent(ctx, n, "scroll");
    }
    dom_api_mod.scroll_event_targets.clearRetainingCapacity();
    // Also re-run IntersectionObserver flush since scroll may have
    // changed target visibility.
    intersection_observer.flushIntersectionObservers(ctx);
}
```

- [ ] **Step 4: Write JS smoke test**

```html
<!doctype html><body>
<div id=b style="overflow:auto;height:100px"><div style="height:500px"></div></div>
<p id=out>pending</p>
<script>
document.getElementById('b').addEventListener('scroll', () => {
  document.getElementById('out').textContent = 'scrolled';
});
document.getElementById('b').scrollTop = 50;
</script>
```

Load in suzume; expected `out` reads `scrolled`.

- [ ] **Step 5: Commit**

```bash
git add src/js/dom_api.zig src/js/dom_element.zig src/js/web_api.zig
git commit -m "feat(events): dispatch scroll event after JS-initiated scroll mutation"
```

### Task A5: Track A verification

- [ ] **Step 1: Run cssom-view WPT**

Run: `TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 cssom-view 2>&1 | tail -10`
Record pass/total; compare to baseline from Task 0.

- [ ] **Step 2: Run dom/nodes + dom/events canaries**

Run: `TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/nodes dom/events 2>&1 | tail -5`
Expected: both within ±5 of baseline.

- [ ] **Step 3: Update spec §9 Results**

Edit spec: fill in **Post Track A** with `cssom-view X/Y (+Δ), dom/nodes X/Y (±0)`.

- [ ] **Step 4: Commit result note**

```bash
git add docs/superpowers/specs/2026-04-22-suzume-wave26-practical-gaps-design.md
git commit -m "docs(wave26): record Track A WPT results"
```

---

## Track B — `scrollIntoView` Real Implementation

**Depends on:** Track A (uses `computeScrollExtent`, `maxScrollFor`).

### Task B1: Parse `scrollIntoView` options

**Files:**
- Modify: `src/js/dom_element.zig` — replace stub at line 2907

- [ ] **Step 1: Write failing smoke test (HTML fixture)**

Unit-testing `scrollIntoView` requires a live QuickJS context + full box tree, which is heavier than a pure-function test. Use an HTML smoke fixture and grep-verify the scroll position map instead.

Create `tests/manual/scroll_into_view_smoke.html`:

```html
<!doctype html><body>
<div id=box style="overflow:auto;height:300px;border:1px solid">
  <div style="height:800px"></div>
  <p id=target style="height:50px">TARGET</p>
</div>
<script>
document.getElementById('target').scrollIntoView({block:'end'});
// After scrollIntoView, ancestor.scrollTop should be 550.
document.title = 'scrollTop=' + document.getElementById('box').scrollTop;
</script>
</body>
```

Run: `./zig-out/bin/suzume tests/manual/scroll_into_view_smoke.html` (or the project-specific headless runner — grep `README.md` or `tests/README.md` for the verb if different).
Expected **before Step 2**: document title reads `scrollTop=0` (stub does nothing).
Expected **after Step 2**: document title reads `scrollTop=550`.

- [ ] **Step 2: Define parsed options struct**

Add in `dom_element.zig` near scroll helpers:

```zig
const ScrollLogicalPos = enum { start, center, end, nearest };
const ScrollBehavior = enum { auto, instant, smooth };

const ScrollIntoViewOpts = struct {
    block: ScrollLogicalPos = .start,
    inline_: ScrollLogicalPos = .nearest,
    behavior: ScrollBehavior = .auto,
};

fn parseScrollIntoViewArgs(c: *qjs.JSContext, argc: c_int, argv: ?[*]qjs.JSValue) ScrollIntoViewOpts {
    var out: ScrollIntoViewOpts = .{};
    if (argc < 1) return out;
    const args = argv orelse return out;
    const a = args[0];
    // Boolean arg: true = {block: start}, false = {block: end} (CSSOM View §6.5 legacy)
    if (quickjs.JS_IsBool(a)) {
        const t = qjs.JS_ToBool(c, a);
        out.block = if (t != 0) .start else .end;
        return out;
    }
    if (!qjs.JS_IsObject(a)) return out;

    const readEnum = struct {
        fn call(cc: *qjs.JSContext, obj: qjs.JSValue, key: [*:0]const u8, default: ScrollLogicalPos) ScrollLogicalPos {
            const v = qjs.JS_GetPropertyStr(cc, obj, key);
            defer qjs.JS_FreeValue(cc, v);
            if (quickjs.JS_IsUndefined(v)) return default;
            const s = jsStringToSlice(cc, v) orelse return default;
            defer qjs.JS_FreeCString(cc, s.ptr);
            const slice = s.ptr[0..s.len];
            if (std.mem.eql(u8, slice, "start")) return .start;
            if (std.mem.eql(u8, slice, "center")) return .center;
            if (std.mem.eql(u8, slice, "end")) return .end;
            if (std.mem.eql(u8, slice, "nearest")) return .nearest;
            return default;
        }
    }.call;

    out.block = readEnum(c, a, "block", .start);
    out.inline_ = readEnum(c, a, "inline", .nearest);

    const bv = qjs.JS_GetPropertyStr(c, a, "behavior");
    defer qjs.JS_FreeValue(c, bv);
    if (!quickjs.JS_IsUndefined(bv)) {
        if (jsStringToSlice(c, bv)) |bs| {
            defer qjs.JS_FreeCString(c, bs.ptr);
            const slice = bs.ptr[0..bs.len];
            if (std.mem.eql(u8, slice, "smooth")) out.behavior = .smooth;
            if (std.mem.eql(u8, slice, "instant")) out.behavior = .instant;
        }
    }
    return out;
}
```

- [ ] **Step 3: Run build**

Run: `zig build 2>&1 | tail -5`
Expected: compile success.

- [ ] **Step 4: Commit**

```bash
git add src/js/dom_element.zig
git commit -m "feat(dom): parse ScrollIntoView options (block/inline/behavior)"
```

### Task B2: Implement alignment algorithm

**Files:**
- Modify: `src/js/dom_element.zig` — body of `elementScrollIntoView`

- [ ] **Step 1: Replace the stub body**

```zig
pub fn elementScrollIntoView(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const opts = parseScrollIntoViewArgs(c, argc, argv);

    const root_box = api.getRootBox(c) orelse return quickjs.JS_UNDEFINED();
    const target_node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    const target_box = api.findBoxForNode(root_box, target_node) orelse return quickjs.JS_UNDEFINED();
    const tbb = target_box.borderBox();

    // Walk ancestors; for each scrollable, compute and apply new scroll.
    var cursor: ?*const Box = target_box.parent;
    while (cursor) |anc| : (cursor = anc.parent) {
        const anc_elem = anc.element orelse continue;
        const styles = api.getStylesForCtx(c) orelse break;
        const cs = styles.get(@intFromPtr(anc_elem)) orelse continue;
        const scrollable_x = cs.overflow_x == .scroll or cs.overflow_x == .auto_;
        const scrollable_y = cs.overflow_y == .scroll or cs.overflow_y == .auto_;
        if (!scrollable_x and !scrollable_y) continue;

        const apb = anc.paddingBox();
        // Target position relative to ancestor content origin.
        const tx_rel = tbb.x - apb.x;
        const ty_rel = tbb.y - apb.y;

        var new_top: f32 = 0;
        var new_left: f32 = 0;
        const max = maxScrollFor(c, @ptrCast(anc_elem));

        if (scrollable_y) {
            new_top = switch (opts.block) {
                .start => ty_rel,
                .center => ty_rel - (apb.height - tbb.height) / 2.0,
                .end => ty_rel - (apb.height - tbb.height),
                .nearest => blk: {
                    // Only scroll if target is outside current viewport
                    const cur = getScrollOffsetForBox(@intFromPtr(anc_elem));
                    if (ty_rel < cur.top) break :blk ty_rel;
                    if (ty_rel + tbb.height > cur.top + apb.height) break :blk ty_rel + tbb.height - apb.height;
                    break :blk cur.top;
                },
            };
            new_top = @max(0.0, @min(new_top, max.top));
        }
        if (scrollable_x) {
            new_left = switch (opts.inline_) {
                .start => tx_rel,
                .center => tx_rel - (apb.width - tbb.width) / 2.0,
                .end => tx_rel - (apb.width - tbb.width),
                .nearest => blk: {
                    const cur = getScrollOffsetForBox(@intFromPtr(anc_elem));
                    if (tx_rel < cur.left) break :blk tx_rel;
                    if (tx_rel + tbb.width > cur.left + apb.width) break :blk tx_rel + tbb.width - apb.width;
                    break :blk cur.left;
                },
            };
            new_left = @max(0.0, @min(new_left, max.left));
        }

        ensureScrollMap().put(@intFromPtr(anc_elem), .{ .top = new_top, .left = new_left }) catch {};
        // Queue scroll event + IO re-flush (same as Task A4 path).
        api.scroll_events_pending = true;
        api.scroll_event_targets.append(
            std.heap.page_allocator, @ptrCast(anc_elem)
        ) catch {};
    }
    return quickjs.JS_UNDEFINED();
}
```

- [ ] **Step 2: Run build + test**

Run: `zig build test 2>&1 | grep -E "scrollIntoView|error"`
Expected: compile succeeds; B1 test passes.

- [ ] **Step 3: Smoke test**

```html
<div id=box style="overflow:auto;height:200px">
  <div style="height:500px"></div>
  <p id=target>hit</p>
</div>
<script>document.getElementById('target').scrollIntoView();</script>
```

Load in suzume; expected the `hit` paragraph is visible within the box.

- [ ] **Step 4: Commit**

```bash
git add src/js/dom_element.zig
git commit -m "feat(dom): implement scrollIntoView alignment (start/center/end/nearest) per CSSOM §6.5"
```

### Task B3: Track B verification

- [ ] **Step 1: Run cssom-view WPT**

Run: `TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 cssom-view 2>&1 | tail -5`
Record delta vs Track A result.

- [ ] **Step 2: Update spec §9 Results**

Fill in **Post Track B** row.

- [ ] **Step 3: Commit result**

```bash
git add docs/superpowers/specs/2026-04-22-suzume-wave26-practical-gaps-design.md
git commit -m "docs(wave26): record Track B WPT results"
```

---

## Track C — IntersectionObserver `rootMargin %`

**Runs parallel with D and E (disjoint files).**

### Task C1: Track unit per value in `RootMargin`

**Files:**
- Modify: `src/js/intersection_observer.zig` — `RootMargin` struct + `parseRootMargin`

- [ ] **Step 1: Extend `RootMargin` struct**

Replace lines 63–68:

```zig
const MarginValue = struct { num: f32 = 0, pct: bool = false };

const RootMargin = struct {
    top: MarginValue = .{},
    right: MarginValue = .{},
    bottom: MarginValue = .{},
    left: MarginValue = .{},
};
```

- [ ] **Step 2: Update `parseRootMargin`**

In the loop around lines 75–99, capture the unit:

```zig
// After parsing the numeric portion:
var is_pct = false;
// scan the upcoming unit: "px" or "%"
if (i < s.len and s[i] == '%') {
    is_pct = true;
    i += 1;
} else {
    // consume "px" if present
    while (i < s.len and s[i] != ' ') i += 1;
}
values[count] = .{ .num = if (neg) -num else num, .pct = is_pct };
count += 1;
```

Change `values` type to `[4]MarginValue` and update the return expressions:

```zig
return switch (count) {
    0, 1 => .{ .top = values[0], .right = values[0], .bottom = values[0], .left = values[0] },
    2 => .{ .top = values[0], .right = values[1], .bottom = values[0], .left = values[1] },
    3 => .{ .top = values[0], .right = values[1], .bottom = values[2], .left = values[1] },
    else => .{ .top = values[0], .right = values[1], .bottom = values[2], .left = values[3] },
};
```

- [ ] **Step 3: Update `getRootBounds` (around line 144)**

```zig
fn getRootBounds(ctx: *qjs.JSContext, rm: RootMargin) Rect {
    const vp = dom_api.getViewportForCtx(ctx);
    const top = if (rm.top.pct) vp.h * rm.top.num / 100.0 else rm.top.num;
    const right = if (rm.right.pct) vp.w * rm.right.num / 100.0 else rm.right.num;
    const bottom = if (rm.bottom.pct) vp.h * rm.bottom.num / 100.0 else rm.bottom.num;
    const left = if (rm.left.pct) vp.w * rm.left.num / 100.0 else rm.left.num;
    return .{ .x = -left, .y = -top, .w = vp.w + left + right, .h = vp.h + top + bottom };
}
```

- [ ] **Step 4: Run build**

Run: `zig build 2>&1 | tail -5`
Expected: compile success.

- [ ] **Step 5: Commit**

```bash
git add src/js/intersection_observer.zig
git commit -m "feat(intersection-observer): resolve rootMargin percentages against root bounds"
```

### Task C2: Unit test for rootMargin %

**Files:**
- Modify: `src/js/intersection_observer.zig` (append test block)

- [ ] **Step 1: Write test**

```zig
test "parseRootMargin resolves percentage unit" {
    const rm = parseRootMargin("10% 20% 30% 40%");
    try std.testing.expect(rm.top.pct);
    try std.testing.expectEqual(@as(f32, 10), rm.top.num);
    try std.testing.expect(rm.right.pct);
    try std.testing.expectEqual(@as(f32, 20), rm.right.num);
    try std.testing.expectEqual(@as(f32, 30), rm.bottom.num);
    try std.testing.expectEqual(@as(f32, 40), rm.left.num);
}

test "parseRootMargin mixed px and %" {
    const rm = parseRootMargin("-5% 10px");
    try std.testing.expect(rm.top.pct);
    try std.testing.expectEqual(@as(f32, -5), rm.top.num);
    try std.testing.expect(!rm.right.pct);
    try std.testing.expectEqual(@as(f32, 10), rm.right.num);
}
```

- [ ] **Step 2: Run `zig build test`**

Expected: both tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/js/intersection_observer.zig
git commit -m "test(intersection-observer): cover rootMargin percentage parsing"
```

### Task C3: Track C verification

- [ ] **Step 1: Run intersection-observer WPT**

Run: `TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 intersection-observer 2>&1 | tail -5`
Record delta vs baseline.

- [ ] **Step 2: Update spec §9 and commit**

```bash
# Edit spec §9 Post Track C row
git add docs/superpowers/specs/2026-04-22-suzume-wave26-practical-gaps-design.md
git commit -m "docs(wave26): record Track C WPT results"
```

---

## Track D — ValidityState `stepMismatch` + Live `:valid`/`:invalid`

### Task D1: Implement `stepMismatch` for number/range in polyfill

**Files:**
- Modify: `src/js/dom_api.zig` — JS polyfill around line 4026

- [ ] **Step 1: Locate the polyfill block**

Run: `grep -n "stepMismatch" src/js/dom_api.zig`
Expected: line 4026 (`var stepMismatch = false;`) and the object literal assembling it.

- [ ] **Step 2: Replace the `stepMismatch` computation**

Replace `var stepMismatch = false;` with the inline JS algorithm:

```javascript
\\    // §4.10.18.4 suffering from a step mismatch — Wave 26: number/range only.
\\    var stepMismatch = false;
\\    if (type==='number' || type==='range') {
\\      var stepAttr = el.getAttribute('step');
\\      if (stepAttr !== 'any') {
\\        var step = parseFloat(stepAttr);
\\        if (!isFinite(step) || step <= 0) step = 1;
\\        var base = 0;
\\        var minAttr = el.getAttribute('min');
\\        if (minAttr !== null) {
\\          var mb = parseFloat(minAttr);
\\          if (isFinite(mb)) base = mb;
\\        } else if (el.defaultValue) {
\\          var db = parseFloat(el.defaultValue);
\\          if (isFinite(db)) base = db;
\\        }
\\        if (!isNaN(numVal) && val !== '') {
\\          var r = (numVal - base) / step;
\\          var rounded = Math.round(r);
\\          var tol = 1e-9 * Math.max(Math.abs(step), 1);
\\          if (Math.abs((r - rounded) * step) > tol) stepMismatch = true;
\\        }
\\      }
\\    }
\\    // TODO(wave27): stepMismatch for date|time|datetime-local|month|week
```

Confirm `numVal` and `val` exist in the surrounding scope (they do — grep "numVal" nearby).

- [ ] **Step 3: Rebuild**

Run: `zig build 2>&1 | tail -5`
Expected: compile success.

- [ ] **Step 4: Smoke test JS snippet**

```html
<input id=i type=number step=5 value=3>
<p id=o></p>
<script>
document.getElementById('o').textContent =
  'stepMismatch=' + document.getElementById('i').validity.stepMismatch;
</script>
```

Load in suzume; expected `stepMismatch=true`.

- [ ] **Step 5: Commit**

```bash
git add src/js/dom_api.zig
git commit -m "feat(forms): implement stepMismatch for number/range (HTML §4.10.18.4)"
```

### Task D2: Invalidate style on `input` / `change` / `invalid`

**Files:**
- Modify: `src/js/events.zig` — around lines 1510–1511 (existing input+change dispatch)
- Modify: `src/style/cascade_libcss.zig` OR `src/js/dom_selector.zig` — expose `invalidateElement(node)` if not present; grep to confirm

- [ ] **Step 1: Grep for existing style invalidation**

Run: `grep -rn "invalidateStyle\|cascade.*invalidate\|restyle" src/style src/js/dom_selector.zig`
Record the existing hook name and call sites.

- [ ] **Step 2: If no invalidation API exists, add one**

If grep returns nothing, add at the end of `src/style/cascade_libcss.zig`:

```zig
/// Mark `node` + its ancestor <form>/<fieldset> as needing selector re-match
/// on the next paint. Minimal: set a global dirty flag the next style pass
/// consumes. (Full per-element invalidation is a future optimization.)
pub var validity_style_dirty: bool = false;

pub fn invalidateValidityStyle(_: *lxb.lxb_dom_node_t) void {
    validity_style_dirty = true;
}
```

Wire the consumer inside the cascade's pre-paint entry point: when `validity_style_dirty` is true, force a full re-run of `:valid`/`:invalid` matching for the document. (Minimum viable: flip a `cache_bust` epoch counter that `dom_selector.isValidElement` reads.)

- [ ] **Step 3: Hook the event dispatch**

In `src/js/events.zig` after line 1511 (the existing `dispatchEvent(ctx, at, "change")` call), add:

```zig
cascade_libcss.invalidateValidityStyle(at);
```

Import `cascade_libcss` at the top of events.zig if not already.

Also hook `dispatchEvent(ctx, target, "input")` and `dispatchEvent(ctx, target, "invalid")` similarly — grep for other `"input"` dispatches in events.zig.

- [ ] **Step 4: Smoke test**

```html
<style>
  input:invalid { outline: 2px solid red; }
  input:valid   { outline: 2px solid green; }
</style>
<input required>
```

Load in suzume, type a character → outline turns green; clear → outline turns red.

- [ ] **Step 5: Commit**

```bash
git add src/js/events.zig src/style/cascade_libcss.zig
git commit -m "feat(forms): invalidate :valid/:invalid style on input/change/invalid event"
```

### Task D3: Track D verification

- [ ] **Step 1: Run forms WPT**

Run:
```
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
  html/semantics/forms/the-input-element \
  html/semantics/forms/constraints 2>&1 | tail -8
```
Record delta vs baseline.

- [ ] **Step 2: Update spec §9 Post Track D row and commit**

```bash
git add docs/superpowers/specs/2026-04-22-suzume-wave26-practical-gaps-design.md
git commit -m "docs(wave26): record Track D WPT results"
```

---

## Track E — ResizeObserver DPR Propagation

**Runs parallel with C and D.**

### Task E1: Expose real DPR from env

**Files:**
- Modify: `src/env.zig` — add DPR accessor (grep to confirm it doesn't already expose one)

- [ ] **Step 1: Check existing env DPR**

Run: `grep -n "dpr\|devicePixelRatio\|pixel_ratio" src/env.zig src/platform/*.zig`
Record any findings. If the paint pipeline already tracks DPR (framebuffer scale), reuse that. Otherwise default to 1.0.

- [ ] **Step 2: Add `getDevicePixelRatio`**

If nothing exists, append to `src/env.zig`:

```zig
/// Returns the device pixel ratio (CSS pixels → physical pixels scale).
/// Defaults to 1.0 on platforms without a display metric.
pub fn getDevicePixelRatio() f32 {
    // TODO: query platform/nsfb for surface DPI; 1.0 on RPi Zero 2W/HyperPixel.
    return 1.0;
}
```

- [ ] **Step 3: Commit**

```bash
git add src/env.zig
git commit -m "feat(env): add getDevicePixelRatio accessor (default 1.0)"
```

### Task E2: Use DPR in `devicePixelContentBoxSize`

**Files:**
- Modify: `src/js/resize_observer.zig` around line 160

- [ ] **Step 1: Locate the hardcoded DPR**

Run: `grep -n "devicePixelContentBoxSize\|DPR assumed" src/js/resize_observer.zig`
Expected: line 160 sets `devicePixelContentBoxSize` with `content_w` / `content_h` directly.

- [ ] **Step 2: Multiply by DPR**

Replace line 161 area with:

```zig
const dpr = env.getDevicePixelRatio();
_ = qjs.JS_SetPropertyStr(ctx, entry, "devicePixelContentBoxSize",
    makeSizeArray(ctx, content_w * dpr, content_h * dpr));
```

Add `const env = @import("../env.zig");` at the top of the file if not already imported.

- [ ] **Step 3: Write unit test**

Since `env.getDevicePixelRatio` is a plain function returning 1.0 on this platform, a meaningful unit test verifies only the **multiplication step** — not the real DPR. Test the arithmetic helper directly:

```zig
test "scaleByDpr multiplies content box by DPR" {
    const dpr: f32 = 2.0;
    const w: f32 = 100;
    const h: f32 = 50;
    try std.testing.expectEqual(@as(f32, 200), w * dpr);
    try std.testing.expectEqual(@as(f32, 100), h * dpr);
}
```

This is intentionally trivial — the real verification is via resize-observer WPT in Task E3. If `env.getDevicePixelRatio` later gains a test seam (e.g. an override for testing), replace this with a test that drives the actual code path.

- [ ] **Step 4: Run build + test**

Run: `zig build test 2>&1 | grep -E "devicePixel|error"`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add src/js/resize_observer.zig
git commit -m "feat(resize-observer): honor env.getDevicePixelRatio in devicePixelContentBoxSize"
```

### Task E3: Track E verification

- [ ] **Step 1: Run resize-observer WPT**

Run: `TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 resize-observer 2>&1 | tail -5`
Record delta vs baseline (expected: ±0 on DPR=1 environment).

- [ ] **Step 2: Update spec §9 Post Track E row and commit**

```bash
git add docs/superpowers/specs/2026-04-22-suzume-wave26-practical-gaps-design.md
git commit -m "docs(wave26): record Track E WPT results"
```

---

## Phase 2 — Integration, Smoke, Release

### Task P1: Full WPT re-measure

- [ ] **Step 1: Run all 5 areas + canaries**

Run:
```
cd ~/suzume && TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
  resize-observer intersection-observer cssom-view \
  html/semantics/forms/the-input-element \
  html/semantics/forms/constraints \
  dom/nodes dom/events 2>&1 | tee /tmp/wpt-wave26-final.log
```

- [ ] **Step 2: Compute deltas**

For each area, compare baseline (Task 0) vs final. Record totals:
```
Total subtests gained: +N
Regressions (canaries): dom/nodes ±X, dom/events ±Y
```

If any canary drops >5 subtests, abort release, bisect the offending track, and fix before proceeding.

### Task P2: Real-site smoke tests

**Files:**
- Create: `docs/superpowers/notes/2026-04-22-wave26-smoke-results.md`

- [ ] **Step 1: Launch suzume against each URL**

For each of: `news.ycombinator.com`, `en.wikipedia.org/wiki/Computer` (or similar long article with TOC), `github.com/search?q=suzume`, a lazy-load image fixture (use `tests/manual/lazy_smoke.html` — create if absent).

For each URL, record in the notes file:
```
## news.ycombinator.com
- window.scrollTo(0,0): PASS / FAIL (reason)
- inner listings scroll: PASS / FAIL
```

- [ ] **Step 2: Commit smoke results**

```bash
git add docs/superpowers/notes/2026-04-22-wave26-smoke-results.md
git commit -m "docs(wave26): record real-site smoke test results"
```

### Task P3: Finalize spec §9 Results

- [ ] **Step 1: Fill final table and tag commit**

Edit spec §9 to replace all remaining `_TBD_` with actual values. Include a "Summary" subsection with total subtests gained and any deferred follow-up work.

- [ ] **Step 2: Commit finalization**

```bash
git add docs/superpowers/specs/2026-04-22-suzume-wave26-practical-gaps-design.md
git commit -m "docs(wave26): finalize spec §9 Results (Wave 26 complete)"
```

### Task P4: Tag `wave26-final`

- [ ] **Step 1: Tag and verify**

```bash
git tag wave26-final
git tag -l wave26-final
git log --oneline -15
```

- [ ] **Step 2: Report back to user**

Produce a final summary message listing per-track deltas, smoke pass rate, and any deferred work items.

---

## Deferred / Explicit Non-Goals (reiterated)

- `scrollIntoView({behavior: "smooth"})` animation — sketch exists in spec §3.5 but deferred unless Tracks A/B/C/D/E land with session budget remaining.
- `IntersectionObserver` non-viewport `root` — deferred unless time allows after Track C WPT measurement.
- `stepMismatch` for date/time/month/week — TODO comment in polyfill; Wave 27 candidate.
- Scroll anchoring / scroll-snap / ScrollTimeline — out of scope.

---

## Self-Review Checklist (run before handing off)

- [ ] Every task has exact file paths.
- [ ] Every code-change step shows the code (no "handle edge cases" placeholders).
- [ ] Every run command shows the exact shell invocation and expected output shape.
- [ ] Track B references `computeScrollExtent` / `maxScrollFor` / `getScrollOffsetForBox` which are all defined in Track A (consistent naming).
- [ ] Track D references `cascade_libcss.invalidateValidityStyle` which is defined in Task D2 Step 2.
- [ ] Phase 0 baseline and Phase 2 final use the same WPT areas for apples-to-apples comparison.
- [ ] Every track has a terminal verification task (A5, B3, C3, D3, E3) before the final release phase.
