#ifndef SVG_WRAPPER_H
#define SVG_WRAPPER_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct svg_result {
    unsigned char* pixels;  /* RGBA straight alpha, malloc'd */
    int width;
    int height;
} svg_result_t;

/* Render SVG data to RGBA pixels.
 * target_w/target_h: desired size. 0 = use SVG intrinsic dimensions.
 * Returns 1 on success, 0 on failure.
 * On success, caller must free out->pixels via free(). */
int svg_render(const char* data, int data_len, int target_w, int target_h, svg_result_t* out);

#ifdef __cplusplus
}
#endif

#endif
