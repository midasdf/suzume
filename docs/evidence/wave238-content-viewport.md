# Wave 238: lay out initial native pages inside browser chrome

Date: 2026-10-09 (UTC). Baseline: `a3631dd` (Wave 237), whose CI run
`37891670132` succeeded in all four jobs. Measurements use ReleaseSafe,
local HTTP, and Xvfb at 1280×1024. The original dirty worktree is untouched.

## CSS and JavaScript now use the same content height

Initial navigation and DOM restyling previously passed the entire framebuffer
height into CSS cascade/layout, while interactive painting clipped 88px for
the URL, tab, and status bars. A 100%-height page therefore extended below the
visible content area. kotori's viewport setter was never called, and QuickJS's
outer dimensions were fixed at 720×720.

`documentViewportHeight` now derives interactive layout height from
`chrome.contentHeight`. Full-page screenshot/layout-dump mode retains the
entire framebuffer height because that path does not paint browser chrome.
Both navigation and restyle use the same conversion. The synchronous-restyle
context keeps native dimensions, not already-converted content dimensions,
and refreshes them after relayout to avoid subtracting the chrome twice or
using a stale size. Heights at or below the chrome height clamp to zero before
subtraction, including the signed-integer lower bound.

The shared web-API viewport state also carries native window height. kotori
receives these dimensions before page scripts and after restyle; its window
properties and VM global bindings both update. QuickJS getters read the same
state, including actual outer dimensions rather than fixed constants.

`screen` remains a separate, incomplete polyfill. The kotori window setter no
longer mislabels window dimensions as monitor/work-area dimensions. This is
not full CSSOM View conformance; OS decorations and screen APIs are not
validated here, and kotori offset/rectangle APIs remain unimplemented.

## Red tests and deliberate baseline failure

Four unit tests were added: native content-height/clamping, unchanged bare
capture height, kotori window/global updates at 1280→640→1280 widths, and
capture outer height without synthetic chrome. Before implementation, three
failed while the unchanged-capture positive control already passed:
2266/2269 → 2269/2269. All 2265 old tests remain passing.

Two additional QuickJS assertions run through the existing DOM+JS smoke
path. The native assertion first failed with `[1280,936,720,720]` instead of
`[1280,936,1280,1024]`. Native and capture assertions now both pass in Debug
and ReleaseSafe; they are smoke assertions, not extra unit-test counts.

The controlled `benchmark/viewport-metrics.html` reports resolved CSS geometry
and window metadata before scripts finish and after style mutations. Against
the unmodified baseline, the expected native-height check fails: kotori has
no inner/outer dimensions, 100vh resolves to 1024px, and the wrong media-query
branch selects 300px. The final build reports:

| Mode / engine | inner width/height | outer width/height | 100vh | 50vh | media width |
|---|---:|---:|---:|---:|---:|
| Native / kotori and QuickJS | 1280 / 936 | 1280 / 1024 | 936px | 468px | 200px |
| Bare capture / both engines | 1280 / 1024 | 1280 / 1024 | 1024px | 512px | 300px |
| Native 640×480 / kotori | 640 / 392 | 640 / 480 | 392px | 196px | 200px |

Bare `innerHeight` agrees with `window.innerHeight`. Repeated style mutations
and synchronous resolved-style reads preserve these results. The small native
case rules out replacing the viewport with a single hardcoded 936px value.

## A real native window exposes the previously hidden footer

`benchmark/window-viewport.html` has no scripts, images, or external styles.
`import -window root` captures the actual X11 window, not the screenshot path.
The before/after images are `wave238-native-before.png` and
`wave238-native-after.png`. At x=1000, root-image rows 953 and 999 change from
main background RGB(238,242,247) to footer RGB(219,228,238). The footer is now
visible above the status bar. Xvfb shows a 1px window border, so these root
image coordinates include that border; document coordinates do not.

The corresponding full-page screenshots remain 1280×1024 with ImageMagick
AE=0. Capture layout dumps also match exactly. The intentional no-chrome
capture behavior is preserved rather than forced to match native coordinates.

## Actual X11 resize remains broken and is the next regression target

The Linux-only `zig build resize-x11-test-window -- WIDTH HEIGHT` utility uses
the existing XCB dependency and refuses a display with zero or multiple root
windows. Checked requests and geometry replies confirm 640×480→1280×1024.
Despite this actual window resize, the browser emits no resize event and its
metrics remain at 1280×936. This is a failing integration probe, not a pass.
The backend lacks `XCB_EVENT_MASK_STRUCTURE_NOTIFY` and a ConfigureNotify
handler; its `x_set_geometry` also rejects already-initialized surfaces.

The unit-level viewport setter updates correctly, but that does not prove
native resize delivery or framebuffer reallocation. No submodule/gitlink or
libnsfb patch change is included in this Wave. macOS GUI resize is separate
and requires its CI/native smoke evidence.

## Verification and unchanged WPT reports

| Verification | Result |
|---|---:|
| Full unit suite | 2269/2269, 80/80 steps |
| ReleaseSafe DOM + flex + RAM surface | 313/313, 25/25 steps including DOM/style and DOM+JS smoke |
| kotori DOM / flex / surface | 247/247 / 62/62 / 4/4 |
| QuickJS viewport smoke | 2/2 in Debug and ReleaseSafe |
| ReleaseSafe browser build | 12/12 steps |
| URL WPT | 6662 pass, 654 fail, 7316 total; 28 reports |
| Selected flex WPT | 1 pass, 37 fail, 38 total; 11 reports |
| Catchless-try browser regression | 6/6 |

Fresh baseline/final URL and flex summaries and all failure lines are identical.
The flex score still includes undefined-metric comparisons and is not layout
conformance evidence. WPT revision is
`2810902e6a3a78789efe5de3376d4f082087041f`.
The restored sparse WPT checkout initially lacked `interfaces/url.idl`, which
reduced idlharness from two failures to one and the denominator to 7315.
Restoring `interfaces/` and rerunning both binaries restored 7316; no smaller
denominator is used for the final comparison.

`src/core/script_executor.zig` has a pre-existing formatting difference in
`kotoriDispatchBodyOnload`; its one-line addition agrees with zig fmt without
changing that unrelated region. Other touched Zig files pass zig fmt checks.

## Reproduction

```bash
cd /home/midasdf/suzume-integration-20261009
zig build test --summary all
zig build test-kotori-dom test-flex-basis test-dom-js test-dom-style test-surface \
  -Doptimize=ReleaseSafe --summary all
zig build -Doptimize=ReleaseSafe --summary all
# In separate terminals:
Xvfb :118 -screen 0 1280x1024x24 -ac
python3 -m http.server 9877 --bind 127.0.0.1 --directory tests/wpt
# Native (timeout 124 is an intentional stop of an interactive browser):
DISPLAY=:118 SUZUME_JS=kotori timeout 10 ./zig-out/bin/suzume \
  http://127.0.0.1:9877/benchmark/viewport-metrics.html
# Capture (exits normally):
DISPLAY=:118 SUZUME_JS=kotori ./zig-out/bin/suzume \
  --screenshot /tmp/viewport.png \
  http://127.0.0.1:9877/benchmark/viewport-metrics.html
# While exactly one native browser is running on the dedicated display:
DISPLAY=:118 zig build resize-x11-test-window -Doptimize=ReleaseSafe -- 640 480
DISPLAY=:118 zig build resize-x11-test-window -Doptimize=ReleaseSafe -- 1280 1024
```

Logs and binaries are in `/tmp/suzume-wave238-20261009/` and may disappear on
reboot. The original tracked-diff SHA-256 remains
`6b83f349aec10af63b9a1ac68b15d472eab92a873eec7a679d4504e274849d4b`.
No Pi performance, live-site usability, complete finally, or new CSSOM metric
support is claimed.
