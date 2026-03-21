# SVG Rendering via lunasvg — Design Spec

## Goal

Add SVG rendering to suzume using lunasvg (C++ library with PlutoVG backend). Support all three SVG use cases: `<img src="*.svg">`, `background-image: url("*.svg")`, and inline `<svg>` elements.

## Constraints

- RPi Zero 2W: 512MB RAM, Cortex-A53
- Binary size budget: keep total under ~6MB
- lunasvg adds ~200KB to binary
- SVG rasterizations cached in existing ImageCache (20MB limit)

## Library Choice: lunasvg

- SVG 1.1/2.0 coverage: paths, shapes, text, gradients, clipPath, mask, patterns, CSS `<style>`
- Not supported: animations (`<animate>`), filters (`<filter>`), scripts
- Backend: PlutoVG (C), lightweight 2D vector rasterizer
- Build: C++17, no external dependencies beyond PlutoVG (bundled)
- Output: ARGB32 premultiplied pixel buffer

## Architecture

```
SVG source (file bytes or inline DOM)
  ↓
[svg_decoder.zig] — extern "C" wrapper around lunasvg C++ API
  ↓
Document::loadFromData(svg_bytes)
  ↓
document->renderToBitmap(target_w, target_h)
  ↓
ARGB32 premultiplied → RGBA straight alpha conversion
  ↓
DecodedImage { .pixels, .width, .height }
  ↓
ImageCache (existing) → painter.zig renders via blitImageScaled
```

The SVG decoder produces the same `DecodedImage` struct as STB, so it plugs into the existing image pipeline with zero changes to the paint layer.

## Components

### 1. Build Integration (`build.zig`)

Add lunasvg + plutovg as C/C++ compilation units:

```
deps/lunasvg/
├── include/
│   └── lunasvg.h
├── source/
│   ├── lunasvg.cpp
│   ├── graphics.cpp
│   ├── svgelement.cpp
│   ├── svggeometryelement.cpp
│   ├── svglayoutstate.cpp
│   ├── svgpaintelement.cpp
│   ├── svgparser.cpp
│   ├── svgproperty.cpp
│   ├── svgrenderstate.cpp
│   └── svgtextelement.cpp
└── plutovg/
    ├── include/
    │   └── plutovg.h
    └── source/
        ├── plutovg-blend.c
        ├── plutovg-canvas.c
        ├── plutovg-font.c
        ├── plutovg-matrix.c
        ├── plutovg-paint.c
        ├── plutovg-path.c
        ├── plutovg-rasterize.c
        └── plutovg-surface.c
```

Zig's build system compiles C++ with `addCSourceFiles(.{ .flags = &.{"-std=c++17"} })`. PlutoVG is pure C, compiled separately.

### 2. C Wrapper (`deps/lunasvg/svg_wrapper.cpp`)

Thin extern "C" bridge since Zig cannot call C++ directly:

```c
// svg_wrapper.h
typedef struct svg_result {
    unsigned char* pixels;  // RGBA (converted from ARGB premultiplied)
    int width;
    int height;
} svg_result_t;

// Render SVG data to RGBA pixels. Caller must free pixels with svg_free().
// Returns 1 on success, 0 on failure.
int svg_render(const char* data, int data_len, int target_w, int target_h, svg_result_t* out);

// Free pixels returned by svg_render.
void svg_free(unsigned char* pixels);

// Register a font file for SVG text rendering.
void svg_add_font(const char* family, int bold, int italic, const char* path);
```

The wrapper handles:
- `Document::loadFromData()` from raw bytes
- `renderToBitmap(w, h)` with transparent background
- ARGB premultiplied → RGBA straight alpha conversion (in-place)
- Memory: `malloc` for pixel buffer, caller frees via `svg_free()`

### 3. SVG Decoder (`src/svg/decoder.zig`)

Zig module wrapping the C API:

```zig
const DecodedImage = @import("../paint/image.zig").DecodedImage;

pub fn decodeSvg(data: []const u8, target_w: u32, target_h: u32) ?DecodedImage {
    var result: c.svg_result_t = undefined;
    if (c.svg_render(data.ptr, @intCast(data.len), @intCast(target_w), @intCast(target_h), &result) != 1) {
        return null;
    }
    return DecodedImage{
        .pixels = result.pixels,
        .width = @intCast(result.width),
        .height = @intCast(result.height),
    };
}

pub fn registerFont(family: [*:0]const u8, bold: bool, italic: bool, path: [*:0]const u8) void {
    c.svg_add_font(family, @intFromBool(bold), @intFromBool(italic), path);
}
```

### 4. Existing Code Modifications

#### `src/paint/image.zig` — Add SVG fallback to decodeImage

```zig
pub fn decodeImage(data: []const u8) ImageError!DecodedImage {
    // Try STB first (PNG, JPEG, GIF, BMP)
    // ... existing code ...
    if (pixels == null) {
        // STB failed — try SVG decoder
        if (svg_decoder.decodeSvg(data, 0, 0)) |svg_img| {
            return svg_img;
        }
        return ImageError.DecodeFailed;
    }
    // ... existing code ...
}
```

When target_w/h are 0, lunasvg uses the SVG's intrinsic viewBox dimensions.

#### `src/layout/tree.zig` — Remove SVG skip

Delete lines 213-230 (the `is_svg` check that skips `<img src="*.svg">`). SVG images now go through the normal replaced-element path.

Add inline `<svg>` handling: when the tag is `"svg"`, serialize the element's outerHTML, store it as `image_url` with a `data:image/svg+xml,` prefix so the image loader can identify it.

#### `src/main.zig` — Remove SVG filters

- Remove `isSvgUrl()` checks from image loading loop
- Remove `isSvgContentType()` checks
- SVGs are now decoded like any other image format

#### `src/main.zig` — Font registration at startup

After font path is determined, register it with lunasvg:
```zig
svg_decoder.registerFont("sans-serif", false, false, font_path);
```

### 5. Inline SVG Handling

For `<svg>...</svg>` in HTML:

1. `tree.zig` detects `<svg>` tag
2. Serializes the SVG DOM subtree to string via lexbor's `lxb_html_serialize_tree_str()`
3. Creates a replaced box with `image_url = "data:image/svg+xml,<svg>..."` (or stores SVG data separately)
4. The image loader detects the `data:image/svg+xml` prefix and passes the SVG text directly to `decodeSvg()`
5. Intrinsic dimensions come from `<svg width="..." height="...">` or viewBox

### 6. Size Clamping

SVGs can declare arbitrary dimensions. Clamp rasterization to prevent OOM:

- Max rasterization size: 1024x1024 pixels (4MB RGBA)
- If SVG viewBox > 1024 in either axis, scale proportionally to fit
- For `<img>` with explicit width/height attributes, use those (already handled by tree.zig)
- For background-image, use the element's padding box dimensions

## Memory Budget

| Item | Size |
|------|------|
| lunasvg binary | ~200KB |
| Per SVG Document (during render) | ~50-200KB (freed after rasterization) |
| Per rasterized SVG (cached) | width × height × 4 bytes |
| Max single SVG | 1024×1024×4 = 4MB |
| ImageCache total | 20MB (shared with raster images) |

## Testing

1. **HN vote arrows** — `triangle.svg` background-image renders as orange triangle
2. **GitHub icons** — Octicons SVG icons in `<img>` tags
3. **Inline SVG test** — HTML file with `<svg><circle>`, `<svg><path>`, `<svg><text>`
4. **Docker comparison** — Firefox vs suzume diff % on SVG-heavy sites
5. **Memory test** — Load page with 50+ SVG icons, verify no OOM on 512MB device

## Implementation Order

1. **Fetch and build lunasvg + plutovg** — get deps, add to build.zig
2. **C wrapper** — svg_wrapper.cpp/h with render + free + font functions
3. **Zig decoder** — src/svg/decoder.zig wrapping C API
4. **Image pipeline integration** — SVG fallback in decodeImage, remove SVG skips
5. **Inline SVG** — tree.zig detection + serialization
6. **Font registration** — pass suzume's font to lunasvg at startup
7. **Testing** — HN arrows, inline SVG, Docker comparison
