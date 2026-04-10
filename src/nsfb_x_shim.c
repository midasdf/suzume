// Fallback shims for optional libnsfb XCB extras.
// Some libnsfb versions/forks expose these symbols; upstream may not.
// Provide no-op/zero implementations so the project can link and run without IME/cursor features.

#include <stdint.h>
#include <stdbool.h>
#include "libnsfb.h"

unsigned int nsfb_x_last_keycode = 0;
unsigned int nsfb_x_last_keystate = 0;

unsigned long nsfb_x_get_window_id(nsfb_t *fb)
{
    (void)fb;
    return 0;
}

void nsfb_x_set_cursor_shape(nsfb_t *fb, int shape)
{
    (void)fb;
    (void)shape;
}

