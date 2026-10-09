# Wave 233 — native X11 window bounds

Measured on 2026-10-09, Linux x86_64, Zig 0.16, kotori, ReleaseSafe.
Baseline: Wave 232, `908d115`. Display: Xvfb `:106`, 1280×1024, without a window manager.

## Cause and change

The existing policy is to fill the available screen, not to force a small fixed window. Commit `5f16e13` requested 4096×4096 and relied on the X server/window manager to constrain it. On Xvfb without a window manager, the actual framebuffer remained 4096×4096. A centered input could therefore lie outside the physical screen.

`Surface.init` now queries the existing XCB dependency for the first root screen, matching libnsfb's backend, and limits each requested dimension before allocating the native framebuffer. The temporary connection is closed. Smaller explicit window sizes remain unchanged. macOS retains its existing AppKit path, and RAM-only full-page screenshot surfaces remain unbounded by the screen.

Non-positive initial/resize dimensions are rejected before backend allocation. An invalid resize leaves the existing framebuffer intact. RAM surface tests are now available on Linux as well as macOS, included in `zig build test`, and run in the Linux CI job.

## Controlled rendering and memory comparison

The self-authored fixture is `tests/wpt/benchmark/window-viewport.html`. It contains no scripts, images, or external CSS. Both runs used identical fixture bytes, fonts, display, and browser settings.

| Case | Wave 232 | Wave 233 |
|---|---:|---:|
| Default requested size | 4096×4096 | 4096×4096 |
| Actual default framebuffer / PNG | 4096×4096 | 1280×1024 |
| Textarea margin box | x=1808, y=112, 480×48 | x=400, y=112, 480×48 |
| Observed process VmHWM while capturing | 205436 KiB (200.6 MiB) | 53236 KiB (52.0 MiB) |
| Explicit 640×480 capture | 640×480 | 640×480 |
| Explicit 640×480 pixel difference | — | ImageMagick AE=0 |
| Explicit 800×1600 native request | — | 800×1024 |
| RAM-only 64×6000 surface | 64×6000 | 64×6000 |

The textarea was completely outside the 1280-pixel screen in the baseline and lies inside it after the change. `wave233-viewport-before.png` is the top-left 1280×1024 crop of the oversized baseline PNG; `wave233-viewport-after.png` is the complete corrected PNG.

VmHWM was sampled from `/proc/<browser-pid>/status` every 10 ms. The observed reduction is 74.1%, but these are sampled process high-water marks for a screenshot operation on x86_64, not total system memory, steady-state browsing, or a Raspberry Pi measurement. No performance or real-site-completion claim is made from these numbers.

The fixture also exposes separate layout limitations: its heading/button do not follow the requested flex alignment, and native browsing still needs content-height accounting for browser chrome. Those issues are not fixed by screen bounding.

## Tests and WPT

- Before the dimension validation: RAM tests 2/4 passed; the two new invalid-geometry tests failed.
- After implementation, Debug and ReleaseSafe: RAM tests 4/4 passed.
- Full unit suite: 2240/2240 → 2244/2244, 80/80 build steps. The increase includes the existing RAM test newly included on Linux.
- ReleaseSafe browser build: 12/12 steps succeeded.
- URL WPT: 6662/7316 → 6662/7316, same 28 reports, no missing reports, no new failure lines.
- WPT revision: `2810902e6a3a78789efe5de3376d4f082087041f`.
- `data-uri-fragment.html` still reports zero subtests; it does not validate iframe behavior.
- Wave 232 GitHub CI run `37864269467` completed successfully in all four jobs, including macOS native smoke tests. Wave 233 CI is a separate run.

A fresh Google capture with the corrected native bounds produced 1280×1084, rather than the upstream baseline's 4096×4156. The 1,123,848-byte external script was still rejected. The live page was not preserved for a before/after comparison, so this is an observation, not a visual regression or usability verdict.

## Reproduction

```bash
cd /home/midasdf/suzume-integration-20261009
zig build test --summary all
zig build test-surface -Doptimize=ReleaseSafe --summary all
zig build -Doptimize=ReleaseSafe --summary all
# Separate terminals:
Xvfb :106 -screen 0 1280x1024x24 -ac
python3 -m http.server 9877 --bind 127.0.0.1 --directory tests/wpt/benchmark
# Capture with default settings:
env -u SUZUME_WIDTH -u SUZUME_HEIGHT DISPLAY=:106 SUZUME_JS=kotori \
  ./zig-out/bin/suzume --screenshot /tmp/viewport.png --dump-layout /tmp/viewport.layout \
  http://127.0.0.1:9877/window-viewport.html
# Explicit smaller settings must remain unchanged:
DISPLAY=:106 SUZUME_JS=kotori SUZUME_WIDTH=640 SUZUME_HEIGHT=480 \
  ./zig-out/bin/suzume --screenshot /tmp/viewport-small.png \
  http://127.0.0.1:9877/window-viewport.html
./tests/wpt/run_wpt_parallel.sh --jobs 8 url
```

For the baseline, build `908d115` in a separate worktree rather than resetting a dirty checkout. Detailed logs, full baseline PNGs, layout dumps, and sampled memory values are temporarily under `/tmp/suzume-integration-20261009/`, with names beginning `viewport-`, `surface-`, `wave233-`, and `wpt-wave233/`.
