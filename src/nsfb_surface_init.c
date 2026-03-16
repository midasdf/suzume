/* Manual surface registration for libnsfb.
 *
 * libnsfb uses __attribute__((constructor)) to register surface backends,
 * but Zig's linker does not process .init_array sections from static archives.
 * This file provides an explicit initialization function instead.
 */
#include <stdbool.h>
#include "libnsfb.h"

/* From surface.h (private header) */
typedef struct nsfb_surface_rtns_s nsfb_surface_rtns_t;
extern void _nsfb_register_surface(const enum nsfb_type_e type,
                                   const nsfb_surface_rtns_t *rtns,
                                   const char *name);

/* Defined in surface/x.c and surface/ram.c */
extern const nsfb_surface_rtns_t x_rtns;
extern const nsfb_surface_rtns_t ram_rtns;

void nsfb_surface_init_all(void) {
    _nsfb_register_surface(NSFB_SURFACE_X, &x_rtns, "x");
    _nsfb_register_surface(NSFB_SURFACE_RAM, &ram_rtns, "ram");
}
