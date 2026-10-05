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
- Application/zip packaging recursively embeds non-system dylibs, rewrites load
  paths, and ad-hoc signs/verifies the bundle. Apple's notarization is separate.
- Build requirements corrected to Zig 0.16.x, matching existing source APIs.
  Linux build/input and macOS build/renderer/input CI are now blocking.
- CSS test discovery fixed: separately imported test modules were previously
  producing a successful zero-test run. The suites now run as individual roots.
  Existing failures are exposed by a separate advisory CI audit, not hidden.

## Verification

Locally verified on an Apple Silicon Mac using Zig 0.16.0:

- ReleaseSafe browser build and relocatable bundle generation.
- TextInput, CJK fallback and RAM framebuffer regressions: seven tests pass.
- Real CSS audit: 175/183 runnable tests pass, eight fail, and three other suites
  have stale-API compilation failures. Parser tests also report 153 allocations
  because they use the testing allocator with the current borrowed-arena parser
  API; that report is not evidence of 153 leaks in the browser's arena-backed
  parsing path. CSS compatibility and test/API maintenance remain unfinished.
- Offline HTTP/TLS tests in Debug and ReleaseSafe: six tests each, including
  compression, 304 reuse, redirects, no-store/Vary, binary POST, self-signed TLS
  rejection, memory budgets and allocation-failure injection.
- AppKit smoke test: actual color/orientation presentation, input/modifiers, IME
  callback commits, CoreText font files, clipboard, resize and quit lifecycle.
- Packaged browser screenshots of a local Japanese/form/link fixture and
  about:blank, plus the full-GUI event-loop smoke mode.

The local stripped bundle is approximately **10 MiB**, including six embedded
dylibs; its zip is approximately **3.7 MiB**. These are build-artifact sizes, not memory
usage measurements, and will vary with toolchains and dependencies.

Linux and Intel full-browser builds are not locally verified. CI results are
separate from local verification. Native callback tests are not a human Japanese
IME UX test, and screenshot presence does not establish complete site correctness.
See [macOS instructions](macos.md) for remaining GUI limitations.

## Next priorities

1. **Everyday navigation correctness**: local fixtures for redirects and final
   URL-relative resources, per-tab back/forward history, reload, forms/POST,
   downloads, keyboard input, tabs, resize and error-page recovery.
2. **Layout compatibility**: compare local CSS/flex/grid/forms/script fixtures
   with a mainstream browser; repair the now-visible CSS audit/test ownership/API
   failures and geometry/painting regressions before claiming modern-site
   compatibility. Existing margin/line-layout defects remain.
3. **Native UX**: Retina-resolution text/layout, caret-aligned IME candidates and
   inline preedit, consistent selection across find/forms, horizontal gestures,
   native title updates, file dialogs and accessibility.
4. **Security boundaries**: remove the remaining WebSocket insecure TLS retry;
   audit cookies (domain/path/HttpOnly/Secure), origin isolation, fetch/CORS,
   mixed content and credential forwarding. Do not use sensitive accounts yet.
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
