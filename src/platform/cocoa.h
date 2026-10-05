#ifndef SUZUME_COCOA_H
#define SUZUME_COCOA_H
#include <stdbool.h>
#include "libnsfb.h"
#include "libnsfb_event.h"
void *suzume_cocoa_create(int width, int height);
void suzume_cocoa_destroy(void *window);
void suzume_cocoa_present(void *window, const unsigned char *pixels, int width, int height, int stride);
bool suzume_cocoa_poll(void *window, nsfb_event_t *event, int timeout);
int suzume_cocoa_key_text(void *window, unsigned char *buffer, int capacity);
void suzume_cocoa_cursor(int shape);
bool suzume_cocoa_composing(void *window);
int suzume_cocoa_clipboard(unsigned char *buffer, int capacity);
void suzume_cocoa_copy(const unsigned char *text, int length);
int suzume_cocoa_font_path(const unsigned char *family, int length, unsigned char *buffer, int capacity);
#endif
