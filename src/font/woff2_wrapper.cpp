#include "woff2_wrapper.h"
#include <cstdlib>
#include <cstring>

// Use the deprecated but simpler C-compatible API that avoids std::string
// woff2/decode.h declares:
//   size_t ComputeWOFF2FinalSize(const uint8_t*, size_t)
//   bool ConvertWOFF2ToTTF(uint8_t*, size_t, const uint8_t*, size_t)
namespace woff2 {
    extern size_t ComputeWOFF2FinalSize(const uint8_t* data, size_t length);
    extern bool ConvertWOFF2ToTTF(uint8_t* result, size_t result_length,
                                  const uint8_t* data, size_t length);
}

extern "C" uint8_t* woff2_decode(const uint8_t* data, size_t data_len, size_t* out_len) {
    size_t final_size = woff2::ComputeWOFF2FinalSize(data, data_len);
    if (final_size == 0 || final_size > 100 * 1024 * 1024) { // cap at 100MB
        return nullptr;
    }

    uint8_t* result = (uint8_t*)malloc(final_size);
    if (!result) return nullptr;

    if (!woff2::ConvertWOFF2ToTTF(result, final_size, data, data_len)) {
        free(result);
        return nullptr;
    }

    *out_len = final_size;
    return result;
}
