# SVG Rendering (lunasvg) Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add SVG rendering to suzume via lunasvg so `<img src="*.svg">`, `background-image: url("*.svg")`, and inline `<svg>` work.

**Architecture:** lunasvg (C++ v2.4.1) compiles as a static library via the existing `allyourcodebase/lunasvg` Zig package. A thin C wrapper (`svg_wrapper.cpp`) bridges C++ → C. Zig calls the C wrapper, gets RGBA pixels, and feeds them into the existing `DecodedImage` → `ImageCache` → `painter` pipeline.

**Tech Stack:** Zig 0.14, lunasvg 2.4.1 (C++17), PlutoVG (C), STB image (existing)

**Spec:** `docs/superpowers/specs/2026-03-21-svg-rendering-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `build.zig.zon` | Modify | Add `allyourcodebase/lunasvg` dependency |
| `build.zig` | Modify | Link lunasvg static library, add svg_wrapper.cpp, include paths |
| `src/svg/svg_wrapper.h` | Create | C API: `svg_render()`, `svg_free()`, `svg_add_font()` |
| `src/svg/svg_wrapper.cpp` | Create | C++ impl: load SVG → rasterize → RGBA conversion → copy to STB-allocated buffer |
| `src/svg/decoder.zig` | Create | Zig wrapper around C API, returns `DecodedImage` |
| `src/paint/image.zig` | Modify | SVG fallback in `decodeImage()` when STB fails |
| `src/layout/tree.zig` | Modify | Remove SVG img skip; add inline `<svg>` as replaced box |
| `src/main.zig` | Modify | Remove `isSvgUrl`/`isSvgContentType` filters; add font registration; handle `data:image/svg+xml` |
| `tests/fixtures/test_svg.html` | Create | Test page with `<img src>`, `background-image url()`, and inline `<svg>` |

---

## Chunk 1: Build Integration + C Wrapper

### Task 1: Add lunasvg Zig dependency

**Files:**
- Modify: `build.zig.zon`

- [ ] **Step 1: Add lunasvg to build.zig.zon dependencies**

Run `zig fetch` to get the package hash:

```bash
zig fetch --save=lunasvg https://github.com/allyourcodebase/lunasvg/archive/refs/heads/master.tar.gz
```

This adds the dependency to `build.zig.zon` with the correct hash.

- [ ] **Step 2: Verify fetch succeeded**

Run: `grep lunasvg build.zig.zon`
Expected: dependency entry with URL and hash

- [ ] **Step 3: Commit**

```bash
git add build.zig.zon
git commit -m "build: add lunasvg zig package dependency"
```

---

### Task 2: Link lunasvg in build.zig

**Files:**
- Modify: `build.zig:11-14` (add dependency), `build.zig:46-50` (link library), `build.zig:78` (include path)

- [ ] **Step 1: Add lunasvg dependency and link**

In `build.zig`, after the harfbuzz dependency block (line ~19-22), add:

```zig
const lunasvg_dep = b.dependency("lunasvg", .{
    .target = target,
    .optimize = optimize,
});
```

Note: `allyourcodebase/lunasvg` exposes `addLunasvg` as a public function. We need to call it to get the library artifact. Since it's a wrapper package, we use its `artifact()`:

```zig
// Try getting the pre-built artifact
const lunasvg_lib = lunasvg_dep.artifact("lunasvg-static");
```

After `exe.linkLibrary(libnsfb);` (line ~50), add:

```zig
exe.linkLibrary(lunasvg_lib);
```

After `exe.addIncludePath(b.path("src/stb"));` (line ~78), add:

```zig
// lunasvg headers (for svg_wrapper)
exe.addIncludePath(lunasvg_dep.path("include"));
```

Wait — the allyourcodebase package uses `b.dependency("lunasvg", .{})` internally to get the upstream source. When we use it as a dependency ourselves, we should use it differently. Let me check: the package's `addLunasvg` function is `pub`, so we can call it directly.

Actually, the simplest approach: since the allyourcodebase package exposes a static library artifact named `"lunasvg-static"`, we just need:

```zig
const lunasvg_pkg = b.dependency("lunasvg", .{
    .target = target,
    .optimize = optimize,
});
const lunasvg_lib = lunasvg_pkg.artifact("lunasvg-static");
exe.linkLibrary(lunasvg_lib);
```

The include path for the header comes from the installed headers in the artifact.

- [ ] **Step 2: Build to verify lunasvg compiles**

Run: `zig build 2>&1 | head -20`
Expected: successful build (or linker warnings about unused symbols, which is OK)

- [ ] **Step 3: Commit**

```bash
git add build.zig
git commit -m "build: link lunasvg static library"
```

---

### Task 3: Create C wrapper for lunasvg

**Files:**
- Create: `src/svg/svg_wrapper.h`
- Create: `src/svg/svg_wrapper.cpp`

- [ ] **Step 1: Create svg_wrapper.h**

```c
// src/svg/svg_wrapper.h
#ifndef SVG_WRAPPER_H
#define SVG_WRAPPER_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct svg_result {
    unsigned char* pixels;  // RGBA straight alpha, allocated via stbi malloc
    int width;
    int height;
} svg_result_t;

// Render SVG data to RGBA pixels.
// target_w/target_h: desired rasterization size. 0 = use SVG intrinsic size.
// Returns 1 on success, 0 on failure.
// On success, caller must free out->pixels via stbi_image_free().
int svg_render(const char* data, int data_len, int target_w, int target_h, svg_result_t* out);

// Register a font file for SVG text rendering (lunasvg font face).
void svg_add_font(const char* family, int bold, int italic, const char* path);

#ifdef __cplusplus
}
#endif

#endif // SVG_WRAPPER_H
```

- [ ] **Step 2: Create svg_wrapper.cpp**

```cpp
// src/svg/svg_wrapper.cpp
#include "svg_wrapper.h"
#include <lunasvg.h>
#include <cstdlib>
#include <cstring>
#include <algorithm>

// Use STB's allocator so DecodedImage.deinit() (stbi_image_free) works uniformly
extern "C" {
    // stb_image defines STBI_MALLOC as malloc by default
    // We just use malloc/free which matches stbi_image_free's behavior
}

static constexpr int MAX_SVG_DIM = 1024;

extern "C" int svg_render(const char* data, int data_len, int target_w, int target_h, svg_result_t* out) {
    if (!data || data_len <= 0 || !out) return 0;

    auto doc = lunasvg::Document::loadFromData(data, static_cast<std::size_t>(data_len));
    if (!doc) return 0;

    // Determine rasterization dimensions
    uint32_t w = static_cast<uint32_t>(target_w);
    uint32_t h = static_cast<uint32_t>(target_h);

    if (w == 0 || h == 0) {
        // Use SVG intrinsic dimensions
        auto box = doc->box();
        if (box.w <= 0 || box.h <= 0) return 0;  // No intrinsic size
        w = static_cast<uint32_t>(box.w);
        h = static_cast<uint32_t>(box.h);
    }

    // Clamp to prevent OOM
    if (w > MAX_SVG_DIM || h > MAX_SVG_DIM) {
        double scale = std::min(
            static_cast<double>(MAX_SVG_DIM) / w,
            static_cast<double>(MAX_SVG_DIM) / h
        );
        w = static_cast<uint32_t>(w * scale);
        h = static_cast<uint32_t>(h * scale);
    }
    if (w == 0 || h == 0) return 0;

    // Rasterize
    auto bitmap = doc->renderToBitmap(w, h);
    if (!bitmap.data() || bitmap.width() == 0 || bitmap.height() == 0) return 0;

    // Convert ARGB premultiplied → RGBA straight alpha (in-place)
    bitmap.convertToRGBA();

    // Copy to malloc'd buffer (so stbi_image_free / free() can release it)
    std::size_t size = static_cast<std::size_t>(bitmap.width()) * bitmap.height() * 4;
    unsigned char* pixels = static_cast<unsigned char*>(malloc(size));
    if (!pixels) return 0;

    // Copy row by row (bitmap stride may differ from width*4)
    for (uint32_t y = 0; y < bitmap.height(); ++y) {
        std::memcpy(
            pixels + y * bitmap.width() * 4,
            bitmap.data() + y * bitmap.stride(),
            bitmap.width() * 4
        );
    }

    out->pixels = pixels;
    out->width = static_cast<int>(bitmap.width());
    out->height = static_cast<int>(bitmap.height());
    return 1;
}

extern "C" void svg_add_font(const char* family, int bold, int italic, const char* path) {
    // lunasvg v2.x does not have a font registration API
    // Text in SVGs uses the built-in font or system fonts
    // This is a no-op placeholder for future versions
    (void)family; (void)bold; (void)italic; (void)path;
}
```

- [ ] **Step 3: Add svg_wrapper.cpp to build.zig**

After the xim_helper.c block (line ~87-90), add:

```zig
// SVG wrapper (C++ bridge to lunasvg)
exe.addCSourceFile(.{
    .file = b.path("src/svg/svg_wrapper.cpp"),
    .flags = &.{"-std=c++17", "-fno-exceptions", "-fno-rtti", "-fno-sanitize=undefined"},
});
exe.addIncludePath(b.path("src/svg"));
```

- [ ] **Step 4: Build to verify wrapper compiles**

Run: `zig build 2>&1 | head -20`
Expected: successful build

- [ ] **Step 5: Commit**

```bash
git add src/svg/svg_wrapper.h src/svg/svg_wrapper.cpp build.zig
git commit -m "feat: add C wrapper for lunasvg SVG rasterizer"
```

---

### Task 4: Create Zig SVG decoder module

**Files:**
- Create: `src/svg/decoder.zig`

- [ ] **Step 1: Create decoder.zig**

```zig
// src/svg/decoder.zig
const std = @import("std");
const DecodedImage = @import("../paint/image.zig").DecodedImage;

const c = @cImport({
    @cInclude("svg_wrapper.h");
});

/// Decode SVG data into RGBA pixels via lunasvg.
/// target_w/target_h: desired size, 0 = use SVG intrinsic dimensions.
/// Returns DecodedImage on success (pixels freed via stbi_image_free in deinit).
pub fn decodeSvg(data: []const u8, target_w: u32, target_h: u32) ?DecodedImage {
    if (data.len == 0) return null;

    var result: c.svg_result_t = undefined;
    if (c.svg_render(
        @ptrCast(data.ptr),
        @intCast(data.len),
        @intCast(target_w),
        @intCast(target_h),
        &result,
    ) != 1) {
        return null;
    }

    if (result.pixels == null or result.width <= 0 or result.height <= 0) return null;

    return DecodedImage{
        .pixels = @ptrCast(result.pixels),
        .width = @intCast(result.width),
        .height = @intCast(result.height),
    };
}
```

- [ ] **Step 2: Build to verify decoder compiles**

Run: `zig build 2>&1 | head -20`
Expected: successful build (decoder not yet used, but import chain validates)

- [ ] **Step 3: Commit**

```bash
git add src/svg/decoder.zig
git commit -m "feat: add Zig SVG decoder wrapping lunasvg C API"
```

---

## Chunk 2: Image Pipeline Integration

### Task 5: Add SVG fallback to decodeImage

**Files:**
- Modify: `src/paint/image.zig:26-47` (decodeImage function)

- [ ] **Step 1: Add SVG import and fallback**

At the top of `src/paint/image.zig`, add:

```zig
const svg_decoder = @import("../svg/decoder.zig");
```

In `decodeImage()`, after the STB null check (line ~40), before returning `ImageError.DecodeFailed`, add SVG fallback:

```zig
    if (pixels == null) {
        // STB failed — try SVG decoder (handles .svg files that STB can't decode)
        if (svg_decoder.decodeSvg(data, 0, 0)) |svg_img| {
            return svg_img;
        }
        return ImageError.DecodeFailed;
    }
```

- [ ] **Step 2: Build to verify**

Run: `zig build 2>&1 | head -20`
Expected: successful build

- [ ] **Step 3: Commit**

```bash
git add src/paint/image.zig
git commit -m "feat: SVG fallback in decodeImage when STB fails"
```

---

### Task 6: Remove SVG skip in tree.zig

**Files:**
- Modify: `src/layout/tree.zig:213-230`

- [ ] **Step 1: Delete the SVG img skip block**

Remove the entire block from line 213 to 230:

```zig
                        // Skip SVG images entirely — stb_image can't decode them
                        // and showing alt text / placeholders just creates visual spam
                        const is_svg = if (img_src) |src| blk: {
                            ...
                        } else false;

                        if (is_svg) {
                            // Skip this element entirely — don't create any box
                            continue;
                        }
```

SVG images now go through the normal replaced-element path like PNG/JPEG.

- [ ] **Step 2: Build and verify**

Run: `zig build 2>&1 | head -20`
Expected: successful build

- [ ] **Step 3: Commit**

```bash
git add src/layout/tree.zig
git commit -m "feat: allow SVG images in <img> tags (no longer skipped)"
```

---

### Task 7: Remove SVG filters in main.zig

**Files:**
- Modify: `src/main.zig` (image loading loop, ~line 1916-1940)

- [ ] **Step 1: Remove isSvgUrl and isSvgContentType checks**

In the image loading loop (~line 1916), change:

```zig
if (!isTrackingPixel(img_url, entry.intrinsic_width, entry.intrinsic_height) and !isSvgUrl(img_url)) {
```

to:

```zig
if (!isTrackingPixel(img_url, entry.intrinsic_width, entry.intrinsic_height)) {
```

Also remove the `isSvgUrl(resolved)` check (~line 1920):

```zig
if (!isSvgUrl(resolved)) {
```

→ remove this condition (keep the inner block).

And remove the `isSvgContentType(resp.content_type)` check (~line 1924):

```zig
and !isSvgContentType(resp.content_type)
```

→ remove this condition from the `if`.

- [ ] **Step 2: Build and verify**

Run: `zig build 2>&1 | head -20`
Expected: successful build

- [ ] **Step 3: Test with HN (the primary SVG use case)**

Run in Docker or locally:
```bash
DISPLAY=:0 timeout 15 zig-out/bin/suzume --url "https://news.ycombinator.com" 2>&1 | tail -10
```

Look for: no segfaults, SVG images being loaded (triangle.svg for vote arrows).

- [ ] **Step 4: Commit**

```bash
git add src/main.zig
git commit -m "feat: allow SVG images in image loading pipeline"
```

---

## Chunk 3: Inline SVG + Data URL Support

### Task 8: Handle data:image/svg+xml URLs in image loader

**Files:**
- Modify: `src/main.zig` (image loading loop)

- [ ] **Step 1: Add data URL detection before HTTP fetch**

In the image loading section, before `resolveUrl` and HTTP fetch (~line 1917), add handling for data: URLs:

```zig
const img_url = entry.url;
if (!isTrackingPixel(img_url, entry.intrinsic_width, entry.intrinsic_height)) {
    // Check for inline SVG data URL (bypass HTTP fetch)
    if (std.mem.startsWith(u8, img_url, "data:image/svg+xml,")) {
        const svg_data = img_url["data:image/svg+xml,".len..];
        if (svg_data.len > 0) {
            const svg_decoder = @import("svg/decoder.zig");
            if (svg_decoder.decodeSvg(svg_data, 0, 0)) |img| {
                const px_count: u64 = @as(u64, img.width) * @as(u64, img.height);
                if (px_count <= 4 * 1024 * 1024) {
                    if (pg.image_cache) |*ic| {
                        ic.put(img_url, img) catch {
                            var mimg = img;
                            mimg.deinit();
                        };
                        pg.pending_images_loaded += 1;
                    }
                }
            }
        }
    } else if (pg.base_url) |base| {
        // existing HTTP fetch path...
```

- [ ] **Step 2: Build and verify**

Run: `zig build 2>&1 | head -20`

- [ ] **Step 3: Commit**

```bash
git add src/main.zig
git commit -m "feat: handle data:image/svg+xml URLs for inline SVG"
```

---

### Task 9: Add inline `<svg>` detection in tree.zig

**Files:**
- Modify: `src/layout/tree.zig` (element processing loop)

- [ ] **Step 1: Add inline SVG handling**

In the tag processing section (after `<img>` handling), add `<svg>` detection:

```zig
// Handle inline <svg> elements — rasterize via lunasvg
if (std.mem.eql(u8, tag, "svg")) {
    // Serialize SVG DOM to string
    const lxb = @import("../bindings/lexbor.zig").c;
    var str: lxb.lexbor_str_t = .{ .data = null, .length = 0 };
    var mhe = lxb.lexbor_mraw_create();
    if (lxb.lexbor_mraw_init(mhe, 4096) == 0) {  // LXB_STATUS_OK
        _ = lxb.lxb_html_serialize_tree_str(@ptrCast(child.lxb_node), &str);
        if (str.data != null and str.length > 0) {
            const svg_text = str.data[0..str.length];
            // Store as data URL for the image loader
            const prefix = "data:image/svg+xml,";
            const url_buf = allocator.alloc(u8, prefix.len + svg_text.len) catch null;
            if (url_buf) |buf| {
                @memcpy(buf[0..prefix.len], prefix);
                @memcpy(buf[prefix.len..], svg_text);
                child_box.box_type = .replaced;
                child_box.image_url = buf;
                // Get intrinsic dimensions from SVG attributes
                var svg_w: f32 = 100; // default
                var svg_h: f32 = 100;
                if (child.getAttribute("width")) |w_str| svg_w = parseFloatAttr(w_str);
                if (child.getAttribute("height")) |h_str| svg_h = parseFloatAttr(h_str);
                child_box.intrinsic_width = svg_w;
                child_box.intrinsic_height = svg_h;
            }
        }
        lxb.lexbor_mraw_destroy(mhe, true);
    }
    // Don't recurse into SVG children (they're part of the SVG, not HTML)
    continue;
}
```

Note: The exact lexbor serialization API may differ — check `src/bindings/lexbor.zig` for the available functions. Adjust `lxb_html_serialize_tree_str` usage to match the binding.

- [ ] **Step 2: Build and verify**

Run: `zig build 2>&1 | head -20`

- [ ] **Step 3: Create test fixture**

Create `tests/fixtures/test_svg.html`:

```html
<!DOCTYPE html>
<html>
<head><title>SVG Test</title></head>
<body style="background: white; font-family: sans-serif;">
  <h2>1. Inline SVG</h2>
  <svg width="100" height="100" xmlns="http://www.w3.org/2000/svg">
    <circle cx="50" cy="50" r="40" fill="orange" stroke="black" stroke-width="2"/>
  </svg>

  <h2>2. SVG img tag</h2>
  <p>HN triangle: <img src="https://news.ycombinator.com/triangle.svg" width="16" height="16"></p>

  <h2>3. Background-image SVG</h2>
  <div style="width:100px; height:100px; background-image:url('https://news.ycombinator.com/triangle.svg'); background-repeat:no-repeat; background-size:contain; border:1px solid #ccc;"></div>

  <h2>4. Inline SVG with path</h2>
  <svg width="120" height="120" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
    <path d="M12 2L2 22h20L12 2z" fill="red" stroke="black" stroke-width="1"/>
  </svg>
</body>
</html>
```

- [ ] **Step 4: Commit**

```bash
git add src/layout/tree.zig tests/fixtures/test_svg.html
git commit -m "feat: inline <svg> element support — serialize and rasterize"
```

---

## Chunk 4: Testing + Polish

### Task 10: Docker comparison test with SVG sites

**Files:**
- No new files

- [ ] **Step 1: Build and rebuild Docker**

```bash
zig build
docker build -t suzume-compare -f tests/Dockerfile.compare .
```

- [ ] **Step 2: Run comparison on HN (primary SVG test)**

```bash
docker run --rm \
  -v $(pwd)/tests/screenshots/docker-results:/app/results \
  -v /usr/share/fonts:/usr/share/fonts:ro \
  --shm-size=512m \
  suzume-compare "https://news.ycombinator.com"
```

Expected: HN vote arrows (▲) now visible. Diff % should decrease from 35.8%.

- [ ] **Step 3: Test with local SVG fixture**

```bash
python3 -m http.server 8765 &
DISPLAY=:0 timeout 10 zig-out/bin/suzume --url "http://localhost:8765/tests/fixtures/test_svg.html"
```

Verify: orange circle, HN triangle img, background-image div, red triangle path all render.

- [ ] **Step 4: Run broader comparison**

```bash
docker run --rm \
  -v $(pwd)/tests/screenshots/docker-results:/app/results \
  -v /usr/share/fonts:/usr/share/fonts:ro \
  --shm-size=512m \
  suzume-compare "https://news.ycombinator.com" "https://lobste.rs" "https://github.com"
```

- [ ] **Step 5: Commit any fixes**

```bash
git add -A
git commit -m "test: verify SVG rendering on HN, lobsters, GitHub"
```

---

### Task 11: Push and update memory

- [ ] **Step 1: Push all commits**

```bash
git push origin main
```

- [ ] **Step 2: Update project memory**

Update `~/.claude/projects/-home-midasdf/memory/project_suzume.md` with:
- SVG rendering: implemented via lunasvg
- Known limitations from spec
- New Docker test results
