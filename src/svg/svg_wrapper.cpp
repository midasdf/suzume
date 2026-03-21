#include "svg_wrapper.h"
#include <lunasvg.h>
#include <cstdlib>
#include <cstring>
#include <algorithm>

static constexpr int MAX_SVG_DIM = 1024;

extern "C" int svg_render(const char* data, int data_len, int target_w, int target_h, svg_result_t* out) {
    if (!data || data_len <= 0 || !out) return 0;

    auto doc = lunasvg::Document::loadFromData(data, static_cast<std::size_t>(data_len));
    if (!doc) return 0;

    // Determine rasterization dimensions
    uint32_t w = static_cast<uint32_t>(target_w);
    uint32_t h = static_cast<uint32_t>(target_h);

    if (w == 0 || h == 0) {
        auto box = doc->box();
        if (box.w <= 0 || box.h <= 0) return 0;
        w = static_cast<uint32_t>(box.w);
        h = static_cast<uint32_t>(box.h);
    }

    // Clamp to prevent OOM
    if (w > MAX_SVG_DIM || h > MAX_SVG_DIM) {
        double scale = std::min(
            static_cast<double>(MAX_SVG_DIM) / w,
            static_cast<double>(MAX_SVG_DIM) / h
        );
        w = std::max(static_cast<uint32_t>(w * scale), 1u);
        h = std::max(static_cast<uint32_t>(h * scale), 1u);
    }
    if (w == 0 || h == 0) return 0;

    auto bitmap = doc->renderToBitmap(w, h);
    if (!bitmap.data() || bitmap.width() == 0 || bitmap.height() == 0) return 0;

    // Convert ARGB premultiplied -> RGBA straight alpha
    bitmap.convertToRGBA();

    // Copy to malloc'd buffer (caller frees)
    std::size_t size = static_cast<std::size_t>(bitmap.width()) * bitmap.height() * 4;
    unsigned char* pixels = static_cast<unsigned char*>(std::malloc(size));
    if (!pixels) return 0;

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
