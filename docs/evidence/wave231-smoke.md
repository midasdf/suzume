# Wave 231 browsing smoke test — 2026-10-09

Build: `zig build -Doptimize=ReleaseSafe`; engine: `SUZUME_JS=kotori`.
Xvfb: 1280×1024, 24-bit. These are rendering observations, not a claim that
modern-site support is complete.

## Results

| Page | Exit status | PNG dimensions | Observation |
|---|---:|---:|---|
| https://example.com | 0 | 1280×1042 | Text and link rendered. Before/after pixel difference: 0 (ImageMagick AE). Existing non-Latin glyph/layout problems remain. |
| https://www.google.com | 0 | 1280×1953 | Header and search controls rendered, but the search field is below the initial viewport and the logo is absent. The pre-change binary also produces a 1953px-tall page with this defect. |
| https://en.wikipedia.org/wiki/Zig_(programming_language) | 0 | 1280×17939 | Article content rendered, but styling is incomplete. A dynamic external script fetch failed. This page is not a clean smoke-test pass. |

Screenshots:

- `example-kotori-wave231.png`
- `google-kotori-before-wave230.png` (pre-change binary)
- `google-kotori-wave231.png`
- `wikipedia-kotori-wave231.png`

Google's log reports a script rejected by the existing size cap (1,123,814 bytes).
Do not raise that cap without measuring memory use on the 512MB target.
The screenshot path logged image completions after saving the PNG.
Image absence in a screenshot alone does not establish the cause.
The pre-change Google PNG includes a logo, while the post-change PNG does not.
Image-loading timing has not been controlled, so this visual difference remains unresolved.

The interactive browser was also inspected through WebDriver.
Google reported `title="Google"` and `url="https://www.google.com"`.
The DOM contains a `textarea[name=q]` and 8 image elements. An X11 capture still showed the search field outside the initial
viewport. DOM presence does not establish on-screen usability.

No Pi Zero 2W run, CORS/origin security check, or TLS safety audit was performed.

## Reproduction

```bash
cd /home/midasdf/suzume
zig build -Doptimize=ReleaseSafe
Xvfb :98 -screen 0 1280x1024x24 -ac
# Run the following in a second terminal; use fresh output paths.
DISPLAY=:98 SUZUME_JS=kotori timeout 90 ./zig-out/bin/suzume --screenshot /tmp/suzume-example.png https://example.com
DISPLAY=:98 SUZUME_JS=kotori timeout 120 ./zig-out/bin/suzume --screenshot /tmp/suzume-google.png https://www.google.com
DISPLAY=:98 SUZUME_JS=kotori timeout 120 ./zig-out/bin/suzume --screenshot /tmp/suzume-wikipedia.png 'https://en.wikipedia.org/wiki/Zig_(programming_language)'
```

For interactive inspection:

```bash
cd /home/midasdf/suzume
DISPLAY=:98 SUZUME_JS=kotori ./zig-out/bin/suzume --webdriver 9999
# In a second terminal:
curl -sS -X POST -H 'Content-Type: application/json' -d '{"capabilities":{}}' http://127.0.0.1:9999/session
curl -sS -X POST -H 'Content-Type: application/json' -d '{"url":"https://www.google.com"}' http://127.0.0.1:9999/session/suzume-session-1/url
curl -sS -X POST -H 'Content-Type: application/json' -d '{"script":"return {title:document.title,url:location.href,search:!!document.querySelector(\"textarea[name=q]\"),images:document.querySelectorAll(\"img\").length}","args":[]}' http://127.0.0.1:9999/session/suzume-session-1/execute/sync
DISPLAY=:98 import -window root /tmp/suzume-google-interactive.png
```

The HTML/CSS/JS served by live sites can change. Record the observed date.
Preserve local fixtures before diagnosing a rendering regression.
