# Wave 7 — css/css-values Phase 6.2 Forecast

**Date**: 2026-04-20  
**Baseline**: Phase 6.1 measurement (`2026-04-20-wave6-phase61-css-values.txt`)  
**Baseline score**: 592/4259 pass (3667 failing across 177 files)  
**Phase 6.2.1 (narrow-keyword attempt)**: 596/4259 (+4 net, no regressions)

---

## 1. Summary Table

Phase 6.2 delivers three mechanics atomically: VM bracket dispatch, computed-style routing, and deep semantic validator (`css_validator.zig`). The table below maps to design doc categories A–E.

| Cat | Description | Failing subtests | Est. recovery | Rate | Evidence |
|-----|-------------|-----------------|--------------|------|----------|
| A/computed | Math-func computed routing (getComputedStyle returns resolved value) | 944 | 700 | 74% | round-mod-rem-computed(243), signs-abs-computed(233), minmax-*-computed(330): bracket GET now routes through DOM resolved value path |
| A/invalid | Math-func deep arg-type validator (clamp/round/abs/sign/hypot) | 389 | 250 | 64% | round-mod-rem-invalid(90), signs-abs-invalid(37), exp-log-invalid(36), hypot-pow-sqrt(36), minmax-*-invalid(3×36): reject type-incompatible args |
| A/serialize | Math-func serialize tests (used-value side only) | 624 | 120 | 19% | Only tests comparing _used-value_ serialization unlock; specified-value canonical form (Phase 6.3) not in scope |
| A/other | round-function, signed-zero, calc-angle, calc-background-pos | 737 | 200 | 27% | round-function(191) recovers via computed routing; signed-zero(162) blocked by Phase 6.3 numeric normalization; if-conditionals(200) and random(109) need Phase 6.4 |
| B | Gradient inner arg validation | 11 | 8 | 73% | linear-gradient first-arg calc(sign(%)*1turn) rejection; percentage-without-context(10) |
| C | calc-size grammar (first-arg basis keywords) | 263 | 180 | 68% | Wave 5 Attempt B regressed calc-size-parsing 56→38; first-arg basis fix restores plus more |
| D | URL request modifier functions | 69 | 40 | 58% | url-request-modifiers-computed(23) and serialize(23): request(integrity()) validator |
| E | Shorthand descent (transform, background, position) | 237 | 130 | 55% | line-break-ch-unit(97 needs font-metrics, NOT validator work); calc-angle-values(27); position-computed partial |
| Other | attr(), if(), random(), animations | 393 | 30 | 8% | attr() requires evaluation infrastructure (Phase 6.5+); if()/random() Phase 6.4+ |
| **Total** | | **3667** | **1658** | **45%** | Expected post-6.2: **2250/4259** (floor gate: +200=792, stretch gate: +500=1092) |

**Floor gate passes** (≥792): forecast 2250 clears by ≥1458 margin.  
**Stretch gate** (+500 = 1092): forecast 2250 clears by ≥1158 margin.

---

## 2. Top 20 Failing Files

Ranked by subtest count. One-line mechanism diagnosis per file.

| Rank | File | Fail | Mechanism |
|------|------|------|-----------|
| 1 | `round-mod-rem-computed.html` | 243 | math-type: computed routing not resolving round/mod/rem to numeric used values |
| 2 | `signs-abs-computed.html` | 233 | math-type: abs()/sign() valid values over-rejected by surface validator |
| 3 | `if-conditionals.html` | 200 | CSS if() function — evaluation infrastructure not implemented (Phase 6.4+) |
| 4 | `round-function.html` | 191 | math-type: round() valid values rejected; computed routing not wired |
| 5 | `signed-zero.html` | 162 | serialization: −0 canonical form requires Phase 6.3 numeric normalization |
| 6 | `random-computed.tentative.html` | 109 | random() primitive not implemented (Phase 6.4+) |
| 7 | `line-break-ch-unit.html` | 97 | shorthand/computed: ch/ic units need font-metrics layout pass, not validator work |
| 8 | `round-mod-rem-invalid.html` | 90 | math-type: round(strategy,A,B) deep arg-type check missing |
| 9 | `minmax-length-computed.html` | 80 | math-type: min()/max() valid length values over-rejected by surface validator |
| 10 | `position/position-computed.tentative.html` | 67 | shorthand: position shorthand computed routing returns wrong format |
| 11 | `acos-asin-atan-atan2-serialize.html` | 62 | math-type: bracket SET silently drops valid trig values (no computed routing) |
| 12 | `calc-size/calc-size-parsing.html` | 56 | calc-size: basis-keyword allowed only in first arg; Wave 5 Attempt B regressed 56→38 |
| 13 | `minmax-length-percent-computed.html` | 50 | math-type: min(1px+1%) valid mixed-unit value over-rejected |
| 14 | `hypot-pow-sqrt-computed.html` | 47 | math-type: hypot(A+) same-type arity rule incorrectly rejecting valid calls |
| 15 | `clamp-length-serialize.html` | 46 | serialization: specified-value canonical form for clamp() needs Phase 6.3 |
| 16 | `if-cycle.html` | 46 | CSS if() cycle detection — requires if() evaluation (Phase 6.4+) |
| 17 | `acos-asin-atan-atan2-computed.html` | 45 | computed routing: getComputedStyle returns raw "acos(1)" not resolved "0deg" |
| 18 | `minmax-length-percent-serialize.html` | 45 | math-type: min()/max() bracket SET dropping valid values; serialize blocked |
| 19 | `calc-infinity-nan-serialize-length.html` | 41 | serialization: NaN/infinity canonical form ("calc(NaN*1px)") needs Phase 6.3 |
| 20 | `minmax-number-serialize.html` | 40 | math-type: min()/max() bracket SET not wired; serialize tests blocked |

---

## 3. Residuals Not Addressable by Phase 6.2

These failures require later phase work. Do not include in Phase 6.2 gate evaluation.

### Phase 6.3 — Specified-value serialization normalization (~649 subtests)

Term-sort, nested-calc flatten, numeric collapse, NaN/infinity canonical form, `min(X)→calc(X)` degenerate. Key files:

- `acos-asin-atan-atan2-serialize.html` — 62 failing (specified-value round-trip, not used-value)
- `clamp-length-serialize.html` — 46
- `minmax-length-percent-serialize.html` — 45
- `calc-infinity-nan-serialize-{length,angle,resolution,time}.html` — 41+30+29+29=129
- `signed-zero.html` — 162 (−0 serialization semantics)
- `calc-catch-divide-by-0.html` — 21 (infinity/NaN canonical form)

### Phase 6.4 — CSS `if()` function (~246 subtests)

- `if-conditionals.html` — 200 (if() evaluation from scratch)
- `if-cycle.html` — 46 (cycle detection in if() context)

### Phase 6.4 — `random()` function (~164 subtests)

- `random-computed.tentative.html` — 109
- `random-serialize.tentative.html` — 38
- `random-in-container-query.tentative.html` — 9, etc.

### Phase 6.5+ — `attr()` evaluation (~95 subtests)

The remaining attr() failures require full typed `attr()` evaluation (resolve `attr(data-foo type(<length>))` at computed-style time). Phase 6.2 validator work does not cover this.

- `attr-all-types.html` — 35 remaining
- `attr-cycle.html` — 29
- `attr-security.html` — 14 (image-set/src url attr substitution)

### Phase 6.4+ — `line-break-ch-unit.html` (97 subtests)

Requires font-metrics layout pass to resolve `ch`/`ic` units. No amount of validator work recovers this; needs layout engine integration.

---

## 4. Sentinel Tests for Phase 6.2 Verification

Run these 10 files individually after the atomic commit. Each gives a clean go/no-go signal for a specific Phase 6.2 mechanic. All are currently at 0 pass (or near-0) so any movement is unambiguous.

| # | File | Before | Expected after | Gate | Mechanic verified |
|---|------|--------|---------------|------|-------------------|
| 1 | `acos-asin-atan-atan2-computed.html` | 0/45 | 40/45 | ≥35 | computed routing: resolved angle value in getComputedStyle |
| 2 | `minmax-length-computed.html` | 0/80 | 65/80 | ≥50 | deep validator accepts min()/max() with valid length args |
| 3 | `hypot-pow-sqrt-computed.html` | 0/47 | 38/47 | ≥30 | deep validator accepts hypot(A+) same-type; computed routing |
| 4 | `round-mod-rem-invalid.html` | 18/108 | 90/108 | ≥70 | deep validator: round(strategy,A,B) arg-type rejection |
| 5 | `signs-abs-invalid.html` | 16/53 | 45/53 | ≥38 | deep validator: abs(calc-sum) accepted; abs(none) rejected |
| 6 | `acos-asin-atan-atan2-serialize.html` | 0/62 | 30/62 | ≥20 | bracket SET stores valid trig values; computed routing returns canonical angle |
| 7 | `calc-size/calc-size-parsing.html` | 38/94 | 75/94 | ≥60 | calc-size first-arg basis-keyword acceptance (restores Wave 5 regression) |
| 8 | `urls/url-request-modifiers-computed.sub.html` | 0/23 | 18/23 | ≥14 | request() modifier grammar accepted; url+modifier stored correctly |
| 9 | `calc-angle-values.html` | 0/27 | 20/27 | ≥15 | computed routing for angle properties: undefined→resolved number |
| 10 | `attr-all-types.html` | 93/128 | 93/128 | ≥93 | non-regression: deep validator must not over-reject valid attr() values |

**Cheap pre-merge smoke**: run only these 10 files (~30s). If all 10 gates pass, proceed to full WPT measurement. If sentinel 7 (`calc-size-parsing`) is below 60 or sentinel 10 (`attr-all-types`) drops below 93, do not merge.

[OBJECTIVE] Forecast Phase 6.2 subtest recovery for css/css-values WPT suite

[DATA] Phase 6.1 baseline: 592/4259 pass, 3667 failing, 177 files. Phase 6.2.1 narrow-keyword: +4 net (596/4259). Three measurement files plus Wave 5 retrospective analyzed.

[FINDING] Phase 6.2 is forecast to recover ~1658 subtests, bringing css/css-values to ~2250/4259 pass.
[STAT:n] n=3667 failing subtests across 177 files
[STAT:effect_size] Category A (math-type) accounts for 2694/3667 (74%) of all failures; 700+250+120+200=1270 recovery from Cat A alone
[STAT:ci] Floor gate +200 and stretch gate +500 both cleared with large margin (forecast +1658)

[LIMITATION] Recovery estimates assume correct implementation of all three Phase 6.2 mechanics. If deep validator over-rejects (as surface validator did in Wave 5 Attempt B), Cat A/invalid recovery will be lower. Serialization estimates (Cat A/serialize, 19% recovery rate) are uncertain — some "used-value" serialize tests may behave like "specified-value" tests at runtime.
