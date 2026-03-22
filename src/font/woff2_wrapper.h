#ifndef WOFF2_WRAPPER_H
#define WOFF2_WRAPPER_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Decode WOFF2 data to TTF/OTF.
 * Returns newly malloc'd buffer on success (caller must free), NULL on failure.
 * out_len is set to the output length. */
uint8_t* woff2_decode(const uint8_t* data, size_t data_len, size_t* out_len);

#ifdef __cplusplus
}
#endif

#endif /* WOFF2_WRAPPER_H */
