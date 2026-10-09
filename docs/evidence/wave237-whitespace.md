# Wave 237: whitespace-only text is not a flex/grid item

Date: 2026-10-09. Baseline: `648455c` (Wave 236). Its CI run
`37890251982` passed all four jobs, including the new Linux/macOS flex test
invocations. Browser measurements use ReleaseSafe, kotori, local HTTP, and
Xvfb `:98` at 1280×1024.

## Ignore document whitespace before allocating anonymous items

Flexbox §4 and Grid §6 exclude whitespace-only anonymous text items, including
preformatted whitespace. `tree.buildChildren` now skips such DOM text before
box allocation when the parent is flex, inline-flex, grid, or inline-grid.
The whitespace set is space, tab, LF, CR, and form feed; NBSP is not included.

Tree construction also applies flex/grid item wrapping to inline-level
containers. Previously `inline-flex` returned before grouping bare text,
because its own box type was inline_box rather than block. Nonempty text now
gets the same anonymous-item treatment as in block-level flex/grid.

Other block/inline whitespace handling is unchanged. This does not rewrite
nonempty text or strip its leading/trailing spaces.

## DOM-derived tree tests fail before the fix

Three tests in `src/test_flex_whitespace.zig` cover:

- Four display modes × normal/pre/pre-wrap (12 combinations): only the two
  element items remain despite surrounding/inter-element document whitespace.
- Four display modes retain both a nonempty text item and a NBSP text item.
- Ordinary block flow retains the separating space between two inline spans.

The first two tests failed before implementation; the ordinary-block positive
control already passed. Combined suite: 60/62 before, 62/62 afterward. All 59
old tests remain passing. The test target now includes the existing QuickJS
header path required by layout/tree's iframe state types; no new library or
runtime dependency is added.

| Verification | Before | After |
|---|---:|---:|
| Full unit suite | 2262/2262 | 2265/2265 |
| Full test steps | 80/80 | 80/80 |
| Flex/tree tests Debug / ReleaseSafe | 59 old tests | 62/62 each |
| ReleaseSafe flex + production DOM/style | — | 17/17 steps |
| ReleaseSafe browser build | 12/12 steps | 12/12 steps |
| URL WPT | 6662/7316 | 6662/7316 |

Comparison against Wave 236 logs preserves all 28 URL reports and their
per-file summaries/failure lines. No missing report or new failure line.
WPT revision remains `2810902e6a3a78789efe5de3376d4f082087041f`.
The 11 flex reports are also unchanged: 1/38 with 37 failures and one zero-test
page. The undefined-metrics "pass" is still not valid conformance evidence.

## The controlled fixture loses two phantom 20px items

`benchmark/window-viewport.html` retains 1280×1024 bounds, a 928px main box,
and footer y=976. Box count changes from 16 to 12: two anonymous blocks and
their two text children are gone.

| Element margin box | Before x/y/width | After x/y/width |
|---|---:|---:|
| h1 | 583 / 411 / 114 | 583 / 431 / 114 |
| textarea | 400 / 475 / 480 | 400 / 495 / 480 |
| button | 590 / 543 / 100 | 590 / 543 / 100 |

Textarea remains 480×48. The textarea-to-button border-box gap is now the
specified 12px, rather than 32px. Removing the phantom items makes the group
40px shorter; justify-content centers the resulting group again.

Before/after screenshots: `wave237-whitespace-before.png` and
`wave237-whitespace-after.png`. The ordinary-block control has ImageMagick
AE=0. No claim of complete browser usability, Pi performance, browser-chrome
viewport accounting, or kotori CSSOM metrics support is made.

## Reproduction

```bash
cd /home/midasdf/suzume-integration-20261009
zig fmt --check build.zig src/layout/tree.zig src/test_flex_basis.zig src/test_flex_whitespace.zig
zig build test-flex-basis --summary all
zig build test-flex-basis test-dom-style -Doptimize=ReleaseSafe --summary all
zig build test --summary all
zig build -Doptimize=ReleaseSafe --summary all
# Serve tests/wpt on 127.0.0.1:9877; Xvfb :98 at 1280x1024x24.
DISPLAY=:98 SUZUME_JS=kotori timeout 60 ./zig-out/bin/suzume \
  --screenshot /tmp/wave237.png --dump-layout /tmp/wave237.layout \
  http://127.0.0.1:9877/benchmark/window-viewport.html
./tests/wpt/run_wpt_parallel.sh --jobs 8 url
```

Artifacts are in `/tmp/suzume-wave237-20261009/`; the Wave 236 before logs and
images remain in `/tmp/suzume-wave236-20261009/`. Original dirty worktree and
libnsfb gitlink are not included.
