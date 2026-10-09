# Wave 236: automatic column-flex cross sizes use intrinsic content

Date: 2026-10-09. Baseline: `14cb22f` (Wave 235), whose CI run
`37879314062` passed all four jobs. Browser runs use ReleaseSafe, kotori,
local HTTP, and Xvfb `:98` at 1280×1024.

## Non-stretched automatic widths were still container-wide

Column flex pre-layout used ordinary block sizing even when align-items or
align-self requested center/start/end. Thus auto-width heading/button boxes
filled the entire container, leaving no horizontal alignment space.

`layoutColumnItem` now resolves non-stretched automatic widths as fit-content,
using intrinsic min/max-content measurements without geometry fallback. It
applies numeric min/max-width constraints, including border-box adjustments,
then reflows at the resolved width while retaining the real parent as the
percentage reference. Temporary sizing properties are restored. Both column
paths use the same helper, including wrapped-column remeasurement.

Stretch/normal alignment, explicit widths, out-of-flow children, and replaced
boxes retain their existing paths. This is not complete flex conformance:
wrapped-column align-content distribution and replaced sizing still need work.

## Direct regressions preserve the existing suite

Eight tests in `src/test_flex_cross_size.zig` cover center/start/end, reverse
columns, a start-aligned wrapped line, both box-sizing modes, repeated widths
300→200→300, align-self, min/max conflicts, empty content, unbreakable overflow,
and unchanged stretch/explicit sizing.

Before implementation seven of eight failed: 52/59 combined tests passed.
Afterward Debug and ReleaseSafe pass 59/59, preserving all 51 old tests.
The existing flex target is now also run by Linux and macOS CI CSS steps.

| Verification | Before | After |
|---|---:|---:|
| Full unit suite | 2254/2254 | 2262/2262 |
| Full test steps | 80/80 | 80/80 |
| Flex suite | 51 existing tests | 59/59 Debug and ReleaseSafe |
| ReleaseSafe flex + production DOM/style | — | 17/17 steps |
| ReleaseSafe browser build | 12/12 steps | 12/12 steps |
| URL WPT | 6662/7316 | 6662/7316 |

Fresh before/after URL logs have identical summaries and failure lines across
28 reports, with zero missing reports. The 11 selected flex reports remain
1/38 with 37 failures and one zero-subtest page. The apparent pass still
compares two undefined offsetWidth values; it is not geometry evidence.
WPT revision: `2810902e6a3a78789efe5de3376d4f082087041f`.

## The controlled fixture now centers heading and button horizontally

For `benchmark/window-viewport.html`, both screenshots and box-tree bounds
remain 1280×1024:

| Margin box | Before x / width | After x / width | y |
|---|---:|---:|---:|
| h1 | 0 / 1280 | 583 / 114 | 411 |
| textarea | 400 / 480 | 400 / 480 | 475 |
| button | 0 / 1280 | 590 / 100 | 543 |

The main height remains 928 and footer y=976. Two anonymous space-only boxes
still consume 20px each; removing those is separate work. Before/after images
are `wave236-cross-before.png` and `wave236-cross-after.png`.

The ordinary-block control from Wave 235 has ImageMagick AE=0. No live-site,
Pi memory, browser-chrome content-height, or JS CSSOM support claim is made.

Formatting checks pass for the other changed Zig files. The new flex helper
region matches `zig fmt`; the rest of flex.zig retains pre-existing formatting
failures rather than introducing an unrelated whole-file reformat.

## Reproduction

```bash
cd /home/midasdf/suzume-integration-20261009
zig fmt --check src/layout/block.zig src/test_flex_basis.zig src/test_flex_cross_size.zig
zig build test --summary all
zig build test-flex-basis test-dom-style -Doptimize=ReleaseSafe --summary all
zig build -Doptimize=ReleaseSafe --summary all
# Serve tests/wpt on 127.0.0.1:9877, /tmp/wpt on 9876; Xvfb :98, 1280x1024x24.
DISPLAY=:98 SUZUME_JS=kotori timeout 60 ./zig-out/bin/suzume \
  --screenshot /tmp/wave236.png --dump-layout /tmp/wave236.layout \
  http://127.0.0.1:9877/benchmark/window-viewport.html
./tests/wpt/run_wpt_parallel.sh --jobs 8 url
```

Logs, baseline binary, and captures are in `/tmp/suzume-wave236-20261009/`.
Original dirty worktree and the libnsfb gitlink are excluded from this Wave.
