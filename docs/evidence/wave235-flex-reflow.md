# Wave 235: keep used dimensions during nested formatting-context reflow

Date: 2026-10-09. Baseline: `83bcd72` (Wave 234).
Browser measurements use ReleaseSafe, kotori, local HTTP, and Xvfb `:98` at
1280×1024. Wave 234 CI run `37877396993` passed all four jobs, including macOS
native window/input smoke tests.

## A flex item's resolved height was lost while laying out its descendants

The existing `block.relayoutChildrenWithContainingHeight` preserved the item's
stored height after reflow, but only pinned width during the reflow itself. A
nested flex container with authored `height:auto` therefore positioned its
children using an intrinsic height, not the height allocated by flex growth or
stretch. Restoring the outer height afterward did not repair those positions.

The helper now temporarily pins both content-box dimensions, directly re-enters
the appropriate flex/grid algorithm, and restores the computed style. Direct
entry keeps percentage insets resolved against their original parent rather
than recalculating them against a synthetic containing width.

The available width includes the item's existing margin, padding, and border,
so the formatting algorithm does not subtract those insets twice. Reflow also
retains the item's origin, translating descendants together when required.
There is no new allocation or JS compatibility shim.

## Direct geometry checks, not the invalid flex WPT score

Six tests in `src/test_flex_relayout.zig` are discovered by the existing
`test-flex-basis` target:

- Nested row and column flex items, each with content-box and border-box sizing.
- Each of those four cases lays out at 200px, 120px, then 200px again, checking
  used size, item origin, both child-center coordinates, and style restoration.
- Two additional cases retain parent-relative 5% horizontal padding while a
  narrower item grows vertically, for both box-sizing modes.

The first four cases all failed before implementation (45/49 existing/new
combined tests passed). The percentage-inset guards were added while validating
the implementation. The final Debug and ReleaseSafe suites pass 51/51, including
all 45 existing tests.

| Verification | Baseline | Wave 235 |
|---|---:|---:|
| Full unit suite | 2248/2248 | 2254/2254 |
| Full unit build steps | 80/80 | 80/80 |
| Flex suite Debug / ReleaseSafe | 45 existing tests | 51/51 each |
| ReleaseSafe flex + production DOM/style targets | — | 17/17 steps |
| Production CSS cascade / layout checks | 17 / 44 | 17 / 44 |
| ReleaseSafe browser build | 12/12 steps | 12/12 steps |
| URL WPT | 6662/7316 | 6662/7316 |

The 28 URL reports have identical per-file summaries and failure lines, with
zero missing reports. WPT revision remains
`2810902e6a3a78789efe5de3376d4f082087041f`.

The same 11 flex WPT reports also retain identical summaries and failure lines:
1 PASS, 37 FAIL, 38 TOTAL, plus the zero-subtest image-load page. As established
in Wave 234, the one reported pass compares two undefined metrics and is not
valid sizing evidence. No flex conformance claim is made from that score.

## Controlled viewport fixture now honors vertical centering

`tests/wpt/benchmark/window-viewport.html` has no scripts, images, or external
styles. Both captures are 1280×1024; the main box is unchanged at y=48 with
height=928. The direct layout dump shows:

| Element | Before y | After y |
|---|---:|---:|
| h1 margin box | 48 | 411 |
| textarea margin box | 112 | 475 |
| button margin box | 180 | 543 |
| footer | 976 | 976 |

Textarea x=400 and size=480×48 remain unchanged. The overall box-tree bounds
remain 1280×1024. The before/after images are committed as
`wave235-flex-before.png` and `wave235-flex-after.png`.

This fixes vertical positioning, not the whole fixture. Heading/button
cross-axis auto sizing is still too wide, and anonymous whitespace boxes still
consume height. Browser-chrome-excluded viewport height and kotori's layout-backed
CSSOM metrics also need separate work. No live-site or Pi performance claim is
made.

A separate local ordinary-block control (640px article with padding/border and
two paragraphs, no flex or external assets) has ImageMagick AE=0 between the two
binaries. That is a scoped non-regression check, not broad visual coverage.

## Reproduction

```bash
cd /home/midasdf/suzume-integration-20261009
zig fmt --check src/layout/block.zig src/test_flex_basis.zig src/test_flex_relayout.zig
zig build test-flex-basis --summary all
zig build test-flex-basis test-dom-style -Doptimize=ReleaseSafe --summary all
zig build test --summary all
zig build -Doptimize=ReleaseSafe --summary all
# Serve tests/wpt on 127.0.0.1:9877 and use Xvfb :98 at 1280x1024x24.
DISPLAY=:98 SUZUME_JS=kotori timeout 60 ./zig-out/bin/suzume \
  --screenshot /tmp/wave235.png --dump-layout /tmp/wave235.layout \
  http://127.0.0.1:9877/benchmark/window-viewport.html
./tests/wpt/run_wpt_parallel.sh --jobs 8 url
```

Raw tests/build logs, WPT logs, block-control captures, and layout dumps are in
`/tmp/suzume-wave235-20261009/`; temporary artifacts may disappear on reboot.
The original worktree's tracked diff remains
`6b83f349aec10af63b9a1ac68b15d472eab92a873eec7a679d4504e274849d4b`.
Neither original pending work nor the libnsfb gitlink is included in this Wave.
