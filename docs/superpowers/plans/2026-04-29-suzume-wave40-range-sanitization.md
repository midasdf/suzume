# Wave 40 — type=range value sanitization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement HTML §4.10.5.1.13 value sanitization for `<input type="range">` so `range.html` reaches 25/25 and `type-change-state.html` "to range" cases pass.

**Architecture:** Pure-additive: a single JS polyfill `_sanRange(v,el)` inserted into `kotori_runtime.zig` plus one dispatcher line in `_sanByType`. The existing `value` getter calls `_sanByType` on every read, so type-change re-sanitization works automatically — no type-setter changes.

**Tech Stack:** Zig 0.16.0 (with custom `--libc /tmp/libc.txt`), kotori JS engine (embedded), suzume browser binary, WPT (Web Platform Tests) runner.

**Spec doc:** `docs/superpowers/specs/2026-04-29-suzume-wave40-range-sanitization-design.md` (commit `61be548`)

**Pre-flight host setup (already validated 2026-04-29):**
- `/tmp/wpt/` — symlinks to servo-build's WPT tree, with patched `testharnessreport.js`
- `/tmp/crt-noframe/` — Zig 0.16 + glibc 2.43 sframe linker workaround crt files
- `/tmp/libc.txt` — `crt_dir=/tmp/crt-noframe` override
- HTTP server `python3 -m http.server 9876 --bind 127.0.0.1` running in `/tmp/wpt/`
- `Xvfb :98 -screen 0 800x600x24 -ac` running

If any are missing, re-run the bootstrap block from
`memory/project_suzume_next_session.md` before starting.

---

## Task 1: Establish Wave 40 baseline + canary numbers

**Files:** none (measurement only)

**Why:** Wave 39 lessons #74 and earlier emphasized "remeasure before claiming
delta." Capture numbers _now_ so the post-implementation diff is unambiguous.

- [ ] **Step 1: Verify host bootstrap is alive**

Run:
```bash
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:9876/ && \
xdpyinfo -display :98 >/dev/null 2>&1 && echo "Xvfb OK" && \
ls /tmp/libc.txt /tmp/crt-noframe/Scrt1.o
```
Expected: `200`, `Xvfb OK`, both files listed.

If any check fails, run the bootstrap block from
`memory/project_suzume_next_session.md` lines 47–84 and retry.

- [ ] **Step 2: Verify suzume binary built and wpt-mode works**

Run:
```bash
test -x /home/midasdf/suzume/zig-out/bin/suzume && \
DISPLAY=:98 SUZUME_JS=kotori timeout 10 \
  /home/midasdf/suzume/zig-out/bin/suzume \
  --wpt-mode "http://127.0.0.1:9876/html/semantics/forms/the-input-element/text.html" \
  2>&1 | grep WPT_SUMMARY
```
Expected: `WPT_SUMMARY: PASS=18 FAIL=0 TOTAL=18` (text.html canary,
Wave 39 confirmed 100%).

If binary missing: `cd /home/midasdf/suzume && zig build --libc /tmp/libc.txt 2>&1 | tail -3`.

- [ ] **Step 3: Baseline range.html (the primary target)**

Run:
```bash
DISPLAY=:98 SUZUME_JS=kotori timeout 25 \
  /home/midasdf/suzume/zig-out/bin/suzume \
  --wpt-mode "http://127.0.0.1:9876/html/semantics/forms/the-input-element/range.html" \
  2>&1 | grep WPT_SUMMARY
```
Expected: `WPT_SUMMARY: PASS=15 FAIL=10 TOTAL=25`.

Record the exact number — if PASS != 15 the spec assumptions are stale and you must re-validate before proceeding.

- [ ] **Step 4: Baseline type-change-state.html (secondary target)**

Run:
```bash
DISPLAY=:98 SUZUME_JS=kotori timeout 60 \
  /home/midasdf/suzume/zig-out/bin/suzume \
  --wpt-mode "http://127.0.0.1:9876/html/semantics/forms/the-input-element/type-change-state.html" \
  2>&1 | grep WPT_SUMMARY
```
Expected (per memory): `WPT_SUMMARY: PASS=262 FAIL=118 TOTAL=380` (±5 noise).

Record the exact number.

- [ ] **Step 5: Canary 1 — Node-contains (must stay 100%)**

Run:
```bash
DISPLAY=:98 SUZUME_JS=kotori timeout 30 \
  /home/midasdf/suzume/zig-out/bin/suzume \
  --wpt-mode "http://127.0.0.1:9876/dom/nodes/Node-contains.html" \
  2>&1 | grep WPT_SUMMARY
```
Expected: `WPT_SUMMARY: PASS=1482 FAIL=0 TOTAL=1482`.

- [ ] **Step 6: Canary 2 — Node-compareDocumentPosition**

Run:
```bash
DISPLAY=:98 SUZUME_JS=kotori timeout 30 \
  /home/midasdf/suzume/zig-out/bin/suzume \
  --wpt-mode "http://127.0.0.1:9876/dom/nodes/Node-compareDocumentPosition.html" \
  2>&1 | grep WPT_SUMMARY
```
Expected: `WPT_SUMMARY: PASS=1444 FAIL=0 TOTAL=1444`.

- [ ] **Step 7: Record baselines into a scratch note**

Save these numbers in your context window or a scratch file.
Comparison happens in Tasks 6–8.

---

## Task 2: Read the reference patterns

**Files:** `src/js/kotori_runtime.zig` (read-only)

**Why:** Wave 39 polyfills follow a specific style (single-line `\\` Zig
multi-line strings, `_sanXxx` naming, dispatcher branch in spec section
order). Match it exactly to keep the diff legible.

- [ ] **Step 1: Read `_sanNumber` to confirm the structural template**

Run:
```bash
sed -n '3357,3402p' /home/midasdf/suzume/src/js/kotori_runtime.zig
```
Expected output: `_sanNumber`, `_sanUrl`, `_sanEmail`, `_sanText`,
`_sanByType` definitions in that order. The dispatcher chain is:
date / time / datetime-local / month / week / number / url / email /
text-family. **Range will insert between `number` and `url`.**

- [ ] **Step 2: Read the value getter to confirm re-sanitize-on-read**

Run:
```bash
sed -n '3403,3420p' /home/midasdf/suzume/src/js/kotori_runtime.zig
```
Expected: getter calls `var s=_sanByType(it,raw,this); return s===null?raw:s;`
on every read. This is the mechanism that makes the type setter NOT need
modification — adding `range` to the dispatcher is enough.

- [ ] **Step 3: Read the type setter (line 3689) to confirm it is plain forwarder**

Run:
```bash
sed -n '3689,3707p' /home/midasdf/suzume/src/js/kotori_runtime.zig
```
Expected: setter only does `setAttribute('type',String(v))` (or
`removeAttribute` for null). No re-sanitize call. **Do not modify this
function in Wave 40.**

---

## Task 3: Insert `_sanRange` polyfill

**Files:** Modify `/home/midasdf/suzume/src/js/kotori_runtime.zig`

**Why:** This is the core of Wave 40. The polyfill clamps to [min,max],
snaps to step base, and falls back to the midpoint default when input is
not a valid floating-point number.

- [ ] **Step 1: Identify the exact anchor line for insertion**

The polyfill must be inserted between the closing `}` of `_sanNumber`
(line 3365) and the comment that begins `_sanUrl` (line 3366).

Confirm anchor by running:
```bash
command grep -n "function _san" /home/midasdf/suzume/src/js/kotori_runtime.zig | head -15
```
Expected: lists `_sanDate`, `_sanTime`, ..., `_sanNumber`, `_sanUrl`,
`_sanEmail`, `_sanText`, `_sanByType`. Note the line numbers — the
insertion point is _just before_ `_sanUrl`.

- [ ] **Step 2: Apply the polyfill via Edit**

Use the Edit tool with these arguments:

`old_string` (must match the file exactly):
````
        \\  function _sanNumber(v){
        \\    if(typeof v!=='string')return '';
        \\    if(!/^-?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(v))return '';
        \\    var n=parseFloat(v);
        \\    if(!isFinite(n))return '';
        \\    return v;
        \\  }
        \\  // Per HTML §4.10.5.1.5 (URL): strip newlines, then trim ASCII ws.
````

`new_string` (replaces with `_sanNumber` followed by `_sanRange` block,
followed by the unchanged `_sanUrl` comment):
````
        \\  function _sanNumber(v){
        \\    if(typeof v!=='string')return '';
        \\    if(!/^-?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(v))return '';
        \\    var n=parseFloat(v);
        \\    if(!isFinite(n))return '';
        \\    return v;
        \\  }
        \\  // Per HTML §4.10.5.1.13 (Range): clamp to [min,max], snap to
        \\  // step base. Default min=0 max=100 step=1. Invalid input ->
        \\  // best representation of the default value (midpoint).
        \\  function _sanRange(v,el){
        \\    if(typeof v!=='string')return '';
        \\    function _f(name,dflt){
        \\      var a=el&&el.getAttribute&&el.getAttribute(name);
        \\      if(a==null)return dflt;
        \\      if(!/^-?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(a))return dflt;
        \\      var n=parseFloat(a);
        \\      return isFinite(n)?n:dflt;
        \\    }
        \\    var min=_f('min',0), max=_f('max',100), step=_f('step',1);
        \\    if(step<=0)step=1;
        \\    function _default(){return (max>=min)?(min+(max-min)/2):min;}
        \\    var n;
        \\    if(!/^-?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(v)){
        \\      n=_default();
        \\    } else {
        \\      n=parseFloat(v);
        \\      if(!isFinite(n))n=_default();
        \\    }
        \\    if(max>=min){
        \\      if(n<min)n=min;
        \\      if(n>max)n=max;
        \\    } else {
        \\      n=min;
        \\    }
        \\    var diff=n-min;
        \\    var k=Math.round(diff/step);
        \\    var snapped=min+k*step;
        \\    if(max>=min&&snapped>max){
        \\      var k2=Math.floor((max-min)/step);
        \\      snapped=min+k2*step;
        \\    }
        \\    n=snapped;
        \\    function _decimals(x){
        \\      var s=String(x);
        \\      var i=s.indexOf('.');
        \\      return i<0?0:(s.length-i-1);
        \\    }
        \\    var prec=Math.max(_decimals(step),_decimals(min),_decimals(max));
        \\    if(prec>0){
        \\      n=parseFloat(n.toFixed(Math.min(prec+2,12)));
        \\    }
        \\    return String(n);
        \\  }
        \\  // Per HTML §4.10.5.1.5 (URL): strip newlines, then trim ASCII ws.
````

- [ ] **Step 3: Verify Edit did not corrupt the file with control chars**

Run:
```bash
command grep -nP "[\x00-\x08\x0B-\x0C\x0E-\x1F]" \
  /home/midasdf/suzume/src/js/kotori_runtime.zig 2>&1 | head -5
```
Expected: no output (empty).

If output appears: a literal LF/CR was inserted. Use Python byte-level
replacement to fix (see Wave 36 lesson #74 in
`memory/project_suzume_next_session.md`).

- [ ] **Step 4: Confirm `_sanRange` is in the file**

Run:
```bash
command grep -n "_sanRange" /home/midasdf/suzume/src/js/kotori_runtime.zig
```
Expected: 1 line — the function definition.

(After Task 4 there will be 2: definition + dispatcher call.)

---

## Task 4: Wire `_sanRange` into the `_sanByType` dispatcher

**Files:** Modify `/home/midasdf/suzume/src/js/kotori_runtime.zig`

**Why:** Without this line, the polyfill is dead code — `_sanByType` will
still return `null` for `it === 'range'`, the value getter will fall back
to the raw value, and `range.html` stays at 15/25.

- [ ] **Step 1: Locate the dispatcher and pick the insertion point**

Run:
```bash
command grep -n "function _sanByType\|if(it===" \
  /home/midasdf/suzume/src/js/kotori_runtime.zig | head -15
```
Expected: shows the dispatcher line and each `if(it===…)` branch in
spec order.

- [ ] **Step 2: Apply the dispatcher edit**

Use the Edit tool with:

`old_string`:
```
        \\    if(it==='number')return _sanNumber(raw);
        \\    if(it==='url')return _sanUrl(raw);
```

`new_string`:
```
        \\    if(it==='number')return _sanNumber(raw);
        \\    if(it==='range')return _sanRange(raw,el);
        \\    if(it==='url')return _sanUrl(raw);
```

- [ ] **Step 3: Verify dispatcher line lands**

Run:
```bash
command grep -n "_sanRange" /home/midasdf/suzume/src/js/kotori_runtime.zig
```
Expected: 2 lines — definition + dispatcher call.

- [ ] **Step 4: Verify still no control chars**

Run:
```bash
command grep -nP "[\x00-\x08\x0B-\x0C\x0E-\x1F]" \
  /home/midasdf/suzume/src/js/kotori_runtime.zig 2>&1 | head -5
```
Expected: no output.

---

## Task 5: Build and confirm clean compile

**Files:** none modified (build artifact only)

- [ ] **Step 1: Build with the libc override**

Run:
```bash
cd /home/midasdf/suzume && zig build --libc /tmp/libc.txt 2>&1 | tail -10
```
Expected: build succeeds, no error/warning lines, last line is
the prompt or empty.

If build fails with a Zig parse error, the most likely cause is a
literal newline inserted into the multi-line string by the Edit tool.
Re-run the control-char grep from Task 3 Step 3 and use Python byte
replacement to fix.

- [ ] **Step 2: Confirm binary mtime updated**

Run:
```bash
ls -la /home/midasdf/suzume/zig-out/bin/suzume
```
Expected: mtime is _now_ (within last few minutes), not yesterday.

---

## Task 6: Verify range.html hits 25/25

**Files:** none (measurement only)

- [ ] **Step 1: Run range.html smoke**

Run:
```bash
DISPLAY=:98 SUZUME_JS=kotori timeout 25 \
  /home/midasdf/suzume/zig-out/bin/suzume \
  --wpt-mode "http://127.0.0.1:9876/html/semantics/forms/the-input-element/range.html" \
  2>&1 | grep -E "WPT_FAIL|WPT_SUMMARY"
```
Expected: `WPT_SUMMARY: PASS=25 FAIL=0 TOTAL=25` and zero `WPT_FAIL` lines.

- [ ] **Step 2: If any FAIL lines remain, classify the failure**

If PASS < 25, the most common causes (in order of likelihood):

1. **FP precision** — `5.3 + 1*0.5` reads as `"5.799999..."`. Bump
   `prec+2` to `prec+3` in the `_decimals` block, or normalize via
   `Number.parseFloat(n.toPrecision(15))`.
2. **Step base wrong** — for `default_step_scale_factor_*` the test
   expects step base = `min`. Confirm `min+k*step` not `0+k*step`.
3. **Default fallback wrong** — invalid input must fall through to
   `_default()` which is `(min+(max-min)/2)` when `max>=min`, else `min`.

Diagnose by running with `--debug` flag if available, or add a
temporary `console.log` polyfill in the polyfill (remove before commit).

- [ ] **Step 3: Do not advance to Task 7 until 25/25 is confirmed**

This is a hard gate. If Task 6 cannot reach 25/25 within ~20 minutes
of debugging, stop and re-read the spec — the algorithm needs revision.

---

## Task 7: Verify type-change-state.html shows ≥+7 delta

**Files:** none (measurement only)

- [ ] **Step 1: Run type-change-state.html smoke**

Run:
```bash
DISPLAY=:98 SUZUME_JS=kotori timeout 60 \
  /home/midasdf/suzume/zig-out/bin/suzume \
  --wpt-mode "http://127.0.0.1:9876/html/semantics/forms/the-input-element/type-change-state.html" \
  2>&1 | grep WPT_SUMMARY
```
Expected: PASS ≥ 269 (baseline 262 + 7 "to range" cases). Higher is fine
(some "to range" cross-products may fix selection-related fails too).

- [ ] **Step 2: Compare PASS delta against baseline from Task 1 Step 4**

If delta < 7, inspect the failing "to range" cases:
```bash
DISPLAY=:98 SUZUME_JS=kotori timeout 60 \
  /home/midasdf/suzume/zig-out/bin/suzume \
  --wpt-mode "http://127.0.0.1:9876/html/semantics/forms/the-input-element/type-change-state.html" \
  2>&1 | grep "to range" | head -10
```
Each remaining "to range" failure should reveal a specific input value
the polyfill is mishandling — diagnose and fix as in Task 6 Step 2.

---

## Task 8: Canary regression check (must stay 100%)

**Files:** none (measurement only)

- [ ] **Step 1: Re-run Node-contains canary**

Run:
```bash
DISPLAY=:98 SUZUME_JS=kotori timeout 30 \
  /home/midasdf/suzume/zig-out/bin/suzume \
  --wpt-mode "http://127.0.0.1:9876/dom/nodes/Node-contains.html" \
  2>&1 | grep WPT_SUMMARY
```
Expected: `WPT_SUMMARY: PASS=1482 FAIL=0 TOTAL=1482`.

- [ ] **Step 2: Re-run Node-compareDocumentPosition canary**

Run:
```bash
DISPLAY=:98 SUZUME_JS=kotori timeout 30 \
  /home/midasdf/suzume/zig-out/bin/suzume \
  --wpt-mode "http://127.0.0.1:9876/dom/nodes/Node-compareDocumentPosition.html" \
  2>&1 | grep WPT_SUMMARY
```
Expected: `WPT_SUMMARY: PASS=1444 FAIL=0 TOTAL=1444`.

- [ ] **Step 3: Cross-check that other input types still pass**

Run a quick subset of Wave 39 sanitizer files:
```bash
for f in text.html search_input.html telephone.html password.html url.html email.html number.html color.html; do
  DISPLAY=:98 SUZUME_JS=kotori timeout 15 \
    /home/midasdf/suzume/zig-out/bin/suzume \
    --wpt-mode "http://127.0.0.1:9876/html/semantics/forms/the-input-element/$f" \
    2>&1 | grep -m1 WPT_SUMMARY | sed "s/^/$f /"
done
```
Expected: each line shows the same PASS counts as Wave 39 baseline
(text 18/18, search 2/2, telephone 13/13, password 5/5, url 4/4,
email 8/8, number ≥ Wave 37 numbers, color ≥ Wave 36 numbers).

If any went DOWN: the polyfill or dispatcher edit broke a sibling
type. Diagnose by reading the new branch — most likely the regex
allowed something it shouldn't.

---

## Task 9: Area pass-rate measurement

**Files:** none (measurement only)

- [ ] **Step 1: Run the full input-element area**

Run:
```bash
cd /home/midasdf/suzume && \
TIMEOUT=90 bash tests/wpt/run_wpt_parallel.sh --jobs 2 \
  html/semantics/forms/the-input-element \
  2>&1 | grep -E "Test files|Subtests|Pass rate" | tail -6
```
Expected: pass rate ≥ 80.0% (Wave 39 baseline 79.8%).

- [ ] **Step 2: Confirm no file moved from PASS to FAIL**

If pass rate dropped below 79.8%, something regressed. Compare
file-by-file results against the Wave 39 starter doc by saving
the full output to `/tmp/wave40-area.log` and diffing against
the previous `/tmp/wave39-area.log` if it still exists.

---

## Task 10: Commit Wave 40

**Files:** Stage `src/js/kotori_runtime.zig` only.

- [ ] **Step 1: Stage exactly the runtime file**

Run:
```bash
git -C /home/midasdf/suzume add src/js/kotori_runtime.zig
git -C /home/midasdf/suzume status --short
```
Expected: only `M src/js/kotori_runtime.zig` shown as staged
(plus pre-existing `.omc/`/submodule noise as unstaged — leave it alone).

- [ ] **Step 2: Verify the staged diff is sane**

Run:
```bash
git -C /home/midasdf/suzume diff --cached --stat
git -C /home/midasdf/suzume diff --cached src/js/kotori_runtime.zig | head -80
```
Expected: ~50 lines added, 0 lines removed, all in the polyfill block
plus one dispatcher line.

- [ ] **Step 3: Create the commit**

Run:
```bash
git -C /home/midasdf/suzume commit -m "$(cat <<'EOF'
feat(forms|kotori): type=range value sanitization (Wave 40)

Implements HTML §4.10.5.1.13 range state value sanitization as a JS
polyfill _sanRange(v,el) wired into kotori_runtime _sanByType
dispatcher. Pure-additive — no type-setter changes, since the value
getter re-evaluates _sanByType on each read.

Algorithm:
  1. Parse min/max/step attributes (defaults 0/100/1, invalid -> default).
  2. If value is not a valid floating-point number per HTML §2.4.4.3,
     fall back to best representation of (min + (max-min)/2), or min
     when max < min.
  3. Clamp to [min, max].
  4. Snap to step base (= min) using Math.round, with snap-down when
     the rounded value would exceed max.
  5. Normalize FP precision via toFixed/parseFloat round-trip when
     min/max/step have decimals.

WPT delta:
  - the-input-element/range.html: 15/25 -> 25/25 (+10)
  - the-input-element/type-change-state.html: 262/380 -> 269/380 (+7)
  - the-input-element area pass rate: 79.8% -> ~80.5%

Smoke pass list: text/search_input/telephone/password/url/email/number/
color all unchanged. Canaries Node-contains (1482/1482) and
Node-compareDocumentPosition (1444/1444) unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```
Expected: commit succeeds, hook output is clean, new commit hash
displayed.

- [ ] **Step 4: Verify commit landed**

Run:
```bash
git -C /home/midasdf/suzume log --oneline -3
```
Expected: top line is `feat(forms|kotori): type=range value sanitization (Wave 40)`.

---

## Task 11: Tag wave40-final (local-only)

**Files:** none (git tag)

- [ ] **Step 1: Create local tag**

Run:
```bash
git -C /home/midasdf/suzume tag wave40-final
git -C /home/midasdf/suzume tag -l "wave4*" | tail -3
```
Expected: `wave40-final` listed.

**Important:** Do NOT push the tag. Wave naming is local-only per
`memory/project_suzume_next_session.md` lesson.

- [ ] **Step 2: Update next-session memory file**

Update `/home/midasdf/.claude/projects/-home-midasdf/memory/project_suzume_next_session.md`:

- Bump the title's wave number to "Wave 40".
- Update the "State on disk" section: latest commit + tag.
- Update the "Baseline numbers" table with new range.html / area
  pass-rate numbers.
- Move "type=range value sanitization" from "Next tractable tracks"
  into "Wave 40 closures (don't re-attempt)".
- Promote "type=file value=null short-circuit" to top of
  "Next tractable tracks" (now Wave 41 candidate).

---

## Done criteria

All of:

- range.html: 25/25 PASS, 0 FAIL.
- type-change-state.html: PASS ≥ 269 (Δ ≥ +7 from baseline).
- Canary tests: Node-contains 1482/1482, Node-compareDocumentPosition 1444/1444.
- Area pass rate: ≥ 80.0%.
- Commit `feat(forms|kotori): type=range value sanitization (Wave 40)` exists on `main`.
- Tag `wave40-final` exists locally (not pushed).
- Memory file updated.

If any single check fails, do NOT mark the wave complete; either fix
forward or revert the runtime edit.
