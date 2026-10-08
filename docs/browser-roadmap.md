# Browser reliability and performance plan

## Implemented

### HTTP reliability and memory

- Certificate errors no longer trigger an insecure HTTP retry.
- Process-wide curl initialization runs once; one client's destruction cannot
  tear down global state still used by image workers and other clients.
- HTTP/2 negotiation survives handle reset. Supported compression is enabled
  with automatic decompression; redirect count and redirect protocols are bounded.
- Redirect/interim response validators are discarded, duplicate headers are
  freed, and failure paths release captured metadata.
- Conditional response cache has an 8 MiB owned-data budget and 128-entry cap
  (map/allocator overhead is additional, not a total browser memory limit).
  Coarse eviction clears the cache at the limit; oversized bodies are not kept.
- URL-only caching is disabled for custom-header/cookie requests and responses
  containing no-store, Vary or Set-Cookie. Uncacheable replacements invalidate
  old entries. Allocations roll back on failure and cache teardown frees all data.
- Offline HTTP/TLS regression fixtures and fail-on-error CI were added.
- WebSockets share process-wide curl initialization, only accept ws/wss, and
  never retry certificate errors with TLS verification disabled. Receive calls
  now supply required frame metadata; incomplete sends no longer report success.

### Native macOS GUI

- AppKit window and input bridge, with RAM libnsfb rendering; no XQuartz,
  Chromium or WebKit dependency. Linux keeps its XCB backend.
- CoreText resolves system fonts instead of requiring Fontconfig on macOS.
- Native menus, window controls, Command shortcuts, clipboard, cursor changes,
  mouse/vertical trackpad scrolling, resize, and IME UTF-8 commits.
- Back/forward/reload toolbar; address selection and horizontal caret visibility;
  UTF-8-safe TextInput deletion/movement and Shift selection.
- Fixed libnsfb's Darwin byte-order detection under POSIX feature macros. It
  mistakenly selected big-endian plotting, turning white into yellow.
- Fixed CJK fallback: HarfBuzz clusters are byte offsets, not codepoints. Fallback
  measurement and drawing now use the actual glyph advance consistently.
- about:blank now produces a local document instead of a failed curl request.
  Fresh-profile startup also loads the configured homepage instead of leaving
  the first tab without a document; title and initial history are populated.
- Application/zip packaging recursively embeds non-system dylibs, rewrites load
  paths, and ad-hoc signs/verifies the bundle. Apple's notarization is separate.
- Build requirements corrected to Zig 0.16.x, matching existing source APIs.
  Linux build/input and macOS build/renderer/input CI are now blocking.

### Per-tab navigation history

- Back/forward lists now belong to each tab instead of a single process-wide
  list. Switching or closing tabs preserves other tabs' navigation positions.
- Private tabs retain in-memory back/forward navigation without writing it to
  the persistent visited-page database or session file.
- New tabs seed their initial URL once; session restoration replaces the
  startup homepage entry with the restored URL. Full histories aren't persisted.
- Back/forward positions advance only after a successful load. New navigation
  allocates before discarding forward entries, preserving the list on OOM and
  safely accepting URLs that alias an existing entry.
- Five `test-navigation` tests pass locally in Debug and ReleaseSafe, including
  tab isolation, private tabs, closing, restoration, branching, aliased URLs and
  allocation-failure cleanup. Linux/macOS CI now runs this target. These are
  state/ownership regressions, not end-to-end keyboard-navigation tests.
- JavaScript History API/SPA traversal, POST replay and per-entry scroll
  restoration still need integration work.

### CSS correctness and regression coverage

- CSS and CSSStyleDeclaration tests now run as actual roots, including the
  previously undiscovered CSSOM tests. Stale Zig/API expectations were repaired;
  parser fixtures explicitly own arenas, matching production AST ownership.
- Fixed nesting emission/cascade order, declarations following nested rules,
  compound type/ID selectors, parent selector lists and conditional groups.
  Quoted/escaped punctuation no longer corrupts selector splitting/substitution.
- Cascade keys retain all 32 source-order bits instead of capping at rule 255.
  !important no longer reverses specificity; UA !important has correct priority.
  Packed specificity saturates rather than wrapping, and HSL/RGB alpha use the
  same nearest-byte quantization.
- Unsafe style sharing was removed: selected attributes and a partial parent
  hash did not capture ancestor selectors, arbitrary attributes, inherited fonts
  or variable scope. Unconditional sibling counting was also quadratic, and the
  arena retained duplicate computed styles for the page's lifetime.
- Retained custom-property maps now have an arena-owned root parent, not a
  pointer to a stack-local VarMap after cascade returns.
- CSS regression checks are now blocking on Linux and macOS CI.

### Layout and native paint

- Fixed lost horizontal margins for block, flex, grid and table containers,
  including negative/percentage margins and nested positioning. Root box edges
  now come from CSS; navigation/reflow no longer erase authored html margins.
- Unitless line-height now multiplies font size rather than becoming tiny pixel
  heights; percentage line-height resolves against font size. Anonymous boxes
  inherit text properties, not parent borders, positioning or opacity.
- Flex/grid/table auto margins resolve after sizing; repeated resize discards
  old resolved auto margins instead of shrinking or shifting boxes twice.
- Added production geometry assertions and an offline packaged-GUI PNG test
  that checks exact marker colors, area and position through real layout/paint.

### Modern-site layout compatibility (Google, Wikipedia)

Four defects made mainstream sites unrenderable. All four were reproduced
offline (fetched HTML with every stylesheet inlined, so the fixtures are
deterministic and network-free) and fixed at the layout layer:

- **Percentage heights no longer resolve against the viewport when the
  containing block's height is indefinite.** `height: 100%` inside a short
  ancestor used to become the window height, which stretched the whole
  containing block. Wikipedia's `.mw-logo{height:100%}` inside a flex row
  turned its 50px header into 676px. Percentage heights now behave as `auto`
  in that case, per CSS 2.1 §10.5; flex and grid layout receive the containing
  block's definite height explicitly instead of reading the global viewport.
- **Definite-height flex/grid containers keep their size.** `layoutFlexColumn`
  ended with `max(definite, content)`, so a `height:100%` column grew past the
  viewport when content overflowed; Google's homepage measured 1030px instead
  of 742px and pushed its own search form off-screen. Grid containers now also
  resolve `calc()`/percentage heights and apply min/max-height.
- **Flex item intrinsic contributions are computed from the box tree, not from
  a container-width layout.** `shrink-to-fit` measured the already-laid-out
  children, so any descendant with `width:100%` (Google's
  `div.AorTac{flex-grow:1}` wrapping a `width:100%` flex header) reported the
  full container width and made the nav row overflow — the top links stacked
  vertically. New `computeIntrinsicMainWidthPublic` /
  `computeIntrinsicMinContentWidthPublic` recurse without depending on a
  previous layout pass; `min-width:auto` uses the min-content (content size
  suggestion, Flexbox L1 §4.5).
- **`max-width` is applied before `margin:auto` centring.** Auto margins were
  computed from the pre-clamped width, so `max-width:688px;margin:auto`
  (Google's search field) stayed pinned left instead of centring.
- Re-entering a flex/grid container for a definite containing height
  (`relayoutChildrenWithContainingHeight`) now respects its formatting context;
  plain block layout there re-stretched every item and discarded the per-item
  main sizes the flex algorithm had just computed.

`--dump-layout <path>` (`--dump-layout-verbose`) writes a DOM-shaped outline of
the painted box tree with geometry and the CSS properties most often
responsible for a break, which is how these were located. Four new regression
cases cover the flex/grid definite-size, intrinsic-width and max-width-centring
behaviour (44 production layout regressions total).

Measured effect (1200x800 headless screenshots): google.com went from only two
header links drawn at a 1395px page height to a correct header, logo, centred
search box, buttons and footer; en.wikipedia.org went from an empty page to a
complete article with its 81px header (previously 676px).

## Verification

Locally verified on an Apple Silicon Mac using Zig 0.16.0:

- ReleaseSafe browser build and relocatable bundle generation.
- TextInput, CJK fallback and RAM framebuffer regressions: seven tests pass.
- CSS regression suites in Debug and ReleaseSafe: **363/363 tests pass**, with
  testing-allocator leak checks, including 99 CSSOM tests previously not run,
  nine new nesting/selector fixtures and cascade-priority regressions. This is
  a regression baseline, not proof of complete CSS standards compatibility.
- Production layout regressions: **44 cases pass**, including flex/grid
  definite-size retention, percentage-height resolution inside indefinite-height
  ancestors, intrinsic (max-content/min-content) flex contributions and
  max-width-before-auto-margin centring. Re-verified against offline fixtures of
  google.com and en.wikipedia.org: the Google nav row no longer overflows, the
  page is 742px tall instead of 1030px, and the Wikipedia header is 81px instead
  of 676px.
- Packaged-browser DOM/CSS integration assertions pass for 17 additional
  fixtures: nesting, trailing declarations, !important specificity, parent-list
  specificity, conditional groups, a 301-rule stylesheet, line-height, distinct
  ancestor/attribute contexts, inherited fonts, retained variable scopes and
  standard pre/code defaults.
- Production geometry: 40 cases pass, covering block/flex/grid/table margins,
  root box edges, real font line metrics, anonymous-box inheritance, signed and
  BFC-sibling margin collapse, nested/repeated layout, fixed-height boundaries,
  text-align versus block positioning, pre height and line-buffer reuse.
  Wrapping checks cover normal/keep-all overflow, explicit break-word/anywhere/
  break-all, latest mixed Latin/CJK boundaries and retrying words on empty lines
  across inline text nodes before emergency splitting. Mixed-height wrapped
  lines finish at the tallest inline's height without carrying it to later lines;
  overflowing words retain their occupied cursor width. Ellipsis regressions
  cover UTF-8/shaped prefixes and containers too narrow for any retained text.
- Renderer/input/CSS combined: 371 tests pass in Debug and ReleaseSafe.
  Text metric tests verify exact-byte ownership, eviction, fallback invalidation
  and bounded scratch-buffer retention.
- Offline HTTP/WebSocket tests in Debug and ReleaseSafe: nine tests each with
  Homebrew curl, including compression, 304 reuse, redirects, no-store/Vary,
  binary POST, self-signed HTTPS/WSS rejection, WebSocket text/frame metadata,
  memory budgets and allocation-failure injection. Builds without curl ws/wss
  explicitly skip the two WebSocket integration cases; macOS CI requires them.
- AppKit smoke test: actual color/orientation presentation, input/modifiers, IME
  callback commits, CoreText font files, clipboard, resize and quit lifecycle.
- Packaged browser screenshots of a local Japanese/form/link fixture and
  about:blank, plus full-GUI fresh-profile/default-homepage and exact-pixel
  block/flex/grid margin smoke tests.

The local stripped bundle is approximately **10 MiB**, including six embedded
dylibs; its zip is approximately **3.7 MiB**. These are build-artifact sizes, not memory
usage measurements, and will vary with toolchains and dependencies.

A five-run ReleaseSafe **headless CSS microbenchmark** on Apple A18 Pro measured
10,003-element sibling cascade median **313.83 → 13.52 ms** and peak process RSS
**91.59 → 48.59 MiB** after unsafe sharing/sibling scans were removed. A repeated-row
case became about 15% slower; this tradeoff is recorded rather than hidden.
These are not GUI/browser-wide or competitor benchmarks. See the
[workloads, samples and limitations](benchmarks/README.md).

Linux and Intel full-browser builds are not locally verified. CI results are
separate from local verification. Native callback tests are not a human Japanese
IME UX test, and screenshot presence does not establish complete site correctness.
See [macOS instructions](macos.md) for remaining GUI limitations.

## Next priorities

1. **Everyday navigation correctness**: local fixtures for redirects and final
   URL-relative resources, end-to-end back/forward and SPA history, reload, forms/POST,
   downloads, keyboard input, tabs, resize and error-page recovery.
2. **Layout compatibility**: compare local CSS/flex/grid/forms/script fixtures
   with a mainstream browser; expand standards coverage and repair geometry/
   painting regressions before claiming modern-site compatibility. Existing
   margin/line-layout defects remain.
3. **Native UX**: Retina-resolution text/layout, caret-aligned IME candidates and
   inline preedit, consistent selection across find/forms, horizontal gestures,
   native title updates, file dialogs and accessibility.
4. **Security boundaries**: audit cookies (domain/path/HttpOnly/Secure), origin
   isolation, fetch/CORS, mixed content and credential forwarding. Expand
   WebSocket fragmentation/backpressure coverage. Do not use sensitive accounts yet.
5. **Responsiveness**: main-thread document/script/style fetching still blocks.
   Add cancellation-aware asynchronous loading while preserving script ordering;
   reduce unnecessary whole-page style/layout/paint work.
6. **Measured performance**: fixed ReleaseSafe fixtures, viewport, fonts and JS
   engine on macOS, Linux and Pi Zero 2W. Record cold/warm startup, first paint,
   load completion, peak RSS, idle CPU and transferred bytes. Report median and
   p95 over repeated runs alongside correctness results.

“World's fastest/lightest” remains a goal, not an established property. Compare
identical workloads against both lightweight and mainstream browsers, without
bypassing TLS or silently omitting essential page behavior.
