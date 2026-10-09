# Wave 234: catchless try must not swallow exceptions

Date: 2026-10-09. Baseline: `af24774` (Wave 233). All browser measurements
used ReleaseSafe, kotori, Xvfb `:98` at 1280×1024, and local HTTP fixtures.
Wave 233 GitHub CI run `37866706875` completed successfully.

## A geometry negative control exposed false successes

The initial investigation selected 11 flex WPT files. They reported 38 passes,
zero failures, and one file with zero subtests. This was not evidence of flex
conformance: kotori returned `undefined` for `offsetWidth`.

A negative control used a 100px-wide element with
`data-expected-width="9999"`. Direct `assert_equals(element.offsetWidth, 9999)`
failed, but the same check via WPT's `checkLayout('.check')` passed. Global
`isNaN(undefined)` correctly returned true; numerical conversion was not the
cause.

`check-layout-th.js` performs its assertions inside `try { ... } finally { ... }`.
`Compiler.compileTryCatch` installed an exception handler even when no `catch`
clause existed. That handler popped the thrown value and continued normally.
Thus an assertion failure became a reported success.

The fix rethrows the original value instead of discarding it. It uses the
existing throw opcode and does not add runtime state or change catch handlers.

**Scope:** exception propagation only. The compiler still does not execute the
AST finalizer. Finally side effects and abrupt completion involving return,
break, or continue remain unimplemented and require separate tests and work.
This is not complete try/finally support.

## Tests failed before the fix and passed afterward

Four new VM tests cover thrown-object identity, a native TypeError, throwing
inside an Array.forEach callback, and unreachable statements after a throw.

| Verification | Before | After |
|---|---:|---:|
| New VM tests | 0/4 | 4/4 |
| Entire kotori Debug suite | 1040/1044 | 1044/1044 |
| kotori ReleaseSafe suite | — | 1044/1044 |
| Direct Debug test-binary execution | — | 1044/1044 |
| Full unit suite | 2244/2244 | 2248/2248 |
| ReleaseSafe browser build | 12/12 steps | 12/12 steps |
| `kotori/catchless-try.html` browser fixture | 1/6 | 6/6 |

The browser fixture also verifies that a missing geometry value cannot pass a
tolerance guard and that a matching value still succeeds. Its existing positive
control remained passing; the five failing cases became passing.

An additional deliberately failing control loaded the unmodified WPT helper.
It included four direct/callback negative assertions, one positive NaN guard,
and the incorrect `checkLayout` width:

- Before: PASS=2 FAIL=4 TOTAL=6; the helper incorrectly passed.
- After: PASS=1 FAIL=5 TOTAL=6; all five intended negative tests failed.

## Flex scores were reclassified, not rendering improvements

WPT checkout: `2810902e6a3a78789efe5de3376d4f082087041f`.

| File under `css/css-flexbox/` | Before PASS/TOTAL | After PASS/TOTAL |
|---|---:|---:|
| percentage-margins-001.html | 3/3 | 0/3 |
| percentage-max-width-cross-axis.html | 2/2 | 0/2 |
| percentage-padding-001.html | 1/1 | 0/1 |
| radiobutton-min-size.html | 1/1 | 1/1 |
| relayout-align-items.html | 2/2 | 0/2 |
| relayout-image-load.html | 0/0 | 0/0 |
| stretched-child-shrink-on-relayout.html | 6/6 | 0/6 |
| table-as-item-cross-size.html | 1/1 | 0/1 |
| table-with-percent-intrinsic-width.html | 2/2 | 0/2 |
| text-as-flexitem-size-001.html | 18/18 | 0/18 |
| total-min-max-violation-zero.html | 2/2 | 0/2 |
| Total | 38/38 | 1/38 |

The 37 newly reported failures expose checks previously swallowed by the
compiler. They are not accepted as loss of working geometry support. The
remaining radio-button "pass" compares `ref.offsetWidth` with
`check.offsetWidth`: both are `undefined`, so it is also invalid evidence of
sizing. The zero-subtest image test is not successful coverage either.

No flex conformance claim is made from this selection. Restore real geometry
coverage by implementing a layout-backed kotori CSSOM interface, including
layout synchronization, and adding positive and negative controls. Do not
replace missing metrics with constants just to recover the old score.

## Existing URL results and the no-script image are unchanged

The URL suite still reports 6662 PASS, 654 FAIL, 7316 TOTAL over the same 28
files. Comparison with the Wave 233 final logs found zero missing reports,
zero changed per-file summaries, and zero changed failure lines. This does not
prove that every unrelated WPT suite has truthful reporting.

The local `benchmark/window-viewport.html` screenshot remains 1280×1024 and
ImageMagick AE=0 compared with Wave 233. Heading/button alignment is still
incorrect; this Wave changes exception semantics, not the layout algorithm.

The original `/home/midasdf/suzume` tracked diff remains untouched:
`6b83f349aec10af63b9a1ac68b15d472eab92a873eec7a679d4504e274849d4b`.
The integration worktree's dirty libnsfb submodule is not staged.

## Reproduction

```bash
cd /home/midasdf/suzume-integration-20261009
zig fmt --check src/js/kotori/compiler.zig tests/test_kotori_vm.zig
zig build test --summary all
zig build test-kotori -Doptimize=ReleaseSafe --summary all
zig build -Doptimize=ReleaseSafe --summary all
# Serve /tmp/wpt on 127.0.0.1:9876; use Xvfb :98 at 1280x1024x24.
ln -s "$PWD/tests/wpt/kotori/catchless-try.html" /tmp/wpt/__suzume_catchless_try_20261009.html
DISPLAY=:98 SUZUME_JS=kotori timeout 90 ./zig-out/bin/suzume \
  --wpt-mode http://127.0.0.1:9876/__suzume_catchless_try_20261009.html
./tests/wpt/run_wpt_parallel.sh --jobs 8 url
```

Baseline binaries, the negative control, before/after WPT logs, full build/test
logs, and screenshots are in `/tmp/suzume-wave234-20261009/`. Temporary artifacts
may disappear after reboot; the committed browser fixture preserves the positive
regression checks.
