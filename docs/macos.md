# macOS

Suzume uses a native AppKit window on macOS, backed by the same libnsfb software
renderer, DOM, CSS, layout and JS engines as Linux. It does not embed WebKit or
Chromium and does not require XQuartz/X11. CoreText resolves system font files;
FreeType/HarfBuzz still measure, shape and rasterize the text.

## Build and launch

Requirements: macOS 15+, Xcode Command Line Tools, Homebrew, Python 3, Zig 0.16.x.
The application is locally verified on Apple Silicon. The script chooses either
Apple Silicon or Intel from the host architecture; Intel needs separate testing.
The resulting bundle's actual minimum OS is the highest requirement of the
executable and its embedded Homebrew libraries. Packaging records that version
in Info.plist rather than claiming that newer bottles work on older Macs. The
locally built bundle requires macOS 27 because this machine's bottles target 27.

```sh
git submodule update --init --recursive
brew bundle --file=Brewfile.macos
bash scripts/build-macos.sh
open zig-out/Suzume.app
```

`ZIG=/path/to/zig-0.16.0 bash scripts/build-macos.sh` overrides the compiler.
The globally installed `zig` may be a newer, incompatible version.

Outputs:

- `zig-out/bin/suzume`: development command-line executable.
- `zig-out/Suzume.app`: application with bundled non-system dynamic libraries.
- `zig-out/Suzume-macos.zip`: portable archive preserving executable permissions.

The bundle uses relative library paths and local ad-hoc signing. It can be moved
without retaining the developer's Homebrew paths. Downloaded applications still
need normal Gatekeeper handling: this build is **not Apple notarized**. Do not
disable Gatekeeper globally. Signing/notarization with a Developer ID is separate
release work.

To launch a specific URL:

```sh
open zig-out/Suzume.app --args https://example.com
# Force the more compatible JS engine for complex sites:
SUZUME_JS=quickjs zig-out/Suzume.app/Contents/MacOS/suzume https://example.com
```

## GUI and input

- Native resizable window, standard window controls, menu bar and Dock presence.
- Back, forward and reload controls beside the address bar.
- Command+L selects the address without erasing it. Typing/pasting replaces the
  selection; Escape restores the current URL.
- Command+T/W/R/F/Q: new tab, close tab, reload, find, quit.
- Command+A/C/V: select all, copy selection and paste in the address/form input.
- Command+H uses the native Hide action. Option+Left/Right navigates history.
- UTF-8 cursor movement, deletion and Shift+arrow selection in TextInput fields.
- Mouse movement, clicking, dragging and vertical trackpad/wheel scrolling.
- AppKit IME commits are delivered as UTF-8, including candidate-window commits.
- Held modifiers are released when the window loses focus.
- Window/menu/Dock quit requests let the browser save its session before exit.

Initial content size is 1200×800 logical pixels, constrained by the available
screen. Override with `SUZUME_WIDTH` and `SUZUME_HEIGHT`. RAM-only screenshot
surfaces never create another native window.

## Regression checks

```sh
prefix="$(brew --prefix)"
# Use x86_64-macos.15.0 on Intel.
ZIG="$prefix/opt/zig@0.16/bin/zig"
"$ZIG" build test-ui-input test-text-fallback test-surface \
  -Doptimize=ReleaseSafe -Dtarget=aarch64-macos.15.0 \
  --search-prefix "$prefix" --search-prefix "$prefix/opt/curl" \
  --search-prefix "$prefix/opt/sqlite"

clang -fobjc-arc -I deps/libnsfb/include -I src/platform \
  src/platform/cocoa.m tests/cocoa_smoke.m \
  -framework Cocoa -framework CoreGraphics -framework CoreText -o /tmp/cocoa-smoke
/tmp/cocoa-smoke
```

`zig build test-css` is a separate audit with known existing failures. Its runner
has been corrected to execute individual suites, rather than reporting success
with zero tests; see the roadmap for the baseline.

The native test needs a logged-in desktop, but no Accessibility or Screen
Recording permission. It exercises actual AppKit presentation and orientation,
key/modifier translation, IME commits, CoreText paths, clipboard, resize and quit.
It is not a complete end-to-end test of browser navigation or a human IME session.
The `--gui-smoke OUTPUT.png URL` browser option runs eight event-loop iterations,
captures the actual painted browser chrome/content, saves its session and exits.
`python3 tests/macos_browser_smoke.py` checks both explicit `about:blank` and a
fresh-profile launch without a URL. It verifies that the default homepage is
actually loaded and its title/session saved. Each case uses an isolated HOME.

Manual browser fixture:

```sh
python3 -m http.server 18765 --bind 127.0.0.1 --directory tests/fixtures
open zig-out/Suzume.app --args http://127.0.0.1:18765/macos-smoke.html
```

## Known limitations

- Existing web-platform/layout defects remain; native presentation is not an
  assertion that all modern sites render or behave correctly.
- IME preedit text is not painted inline yet, and candidate placement currently
  uses a fixed address-bar anchor. Real Japanese IME UX needs more manual testing.
- Find-bar editing and page selection are separate older implementations and do
  not yet have all the TextInput selection/clipboard behavior.
- Framebuffer rendering uses logical pixels; full Retina-resolution text/layout
  is not implemented. Horizontal/gesture scrolling and pinch zoom need work.
- Native title tracking, downloads, file dialogs, per-tab history correctness,
  accessibility tree and cancellation-aware asynchronous document loading remain
  priorities.
- HTTP and WebSocket certificate verification are strict, with no insecure TLS
  retry. Other security boundaries and WebSocket fragmentation/backpressure still
  need audit. Do not use sensitive accounts yet.

See [the browser roadmap](browser-roadmap.md) for measurement and compatibility
priorities. No world-fastest/lightest claim has been established.
