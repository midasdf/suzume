/*
 * XIM (X Input Method) helper for suzume browser.
 *
 * Provides XIM integration alongside the existing xcb-based X11 backend.
 * This opens a separate Xlib Display connection to the same X server
 * and uses Xlib's XIM/XIC API to handle input method composition
 * (e.g., fcitx5-mozc for Japanese input).
 */

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xresource.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <locale.h>

static Display *xim_display = NULL;
static XIM xim = NULL;
static XIC xic = NULL;
static Window xim_window = 0;

/* Initialize XIM for a given X11 window.
 * Returns 0 on success, negative on failure. */
int xim_init(unsigned long window_id) {
    /* Set locale for XIM — must be done before XOpenDisplay */
    setlocale(LC_ALL, "");

    if (!XSupportsLocale()) {
        fprintf(stderr, "[XIM] X does not support current locale\n");
        /* Continue anyway — basic input may still work */
    }

    /* Open a separate Xlib Display connection (same X server as xcb) */
    xim_display = XOpenDisplay(NULL);
    if (!xim_display) {
        fprintf(stderr, "[XIM] Failed to open Xlib display\n");
        return -1;
    }

    xim_window = (Window)window_id;

    /* Set locale modifiers for XIM.
     * Empty string means use XMODIFIERS env var (which fcitx5 sets). */
    if (XSetLocaleModifiers("") == NULL) {
        fprintf(stderr, "[XIM] XSetLocaleModifiers failed, trying @im=none\n");
        XSetLocaleModifiers("@im=none");
    }

    /* Open input method */
    xim = XOpenIM(xim_display, NULL, NULL, NULL);
    if (!xim) {
        /* Try with fcitx explicitly */
        fprintf(stderr, "[XIM] XOpenIM failed, trying @im=fcitx\n");
        XSetLocaleModifiers("@im=fcitx");
        xim = XOpenIM(xim_display, NULL, NULL, NULL);
    }
    if (!xim) {
        fprintf(stderr, "[XIM] Could not open input method\n");
        XCloseDisplay(xim_display);
        xim_display = NULL;
        return -2;
    }

    /* Create input context */
    xic = XCreateIC(xim,
        XNInputStyle, XIMPreeditNothing | XIMStatusNothing,
        XNClientWindow, xim_window,
        XNFocusWindow, xim_window,
        NULL);
    if (!xic) {
        fprintf(stderr, "[XIM] Could not create input context\n");
        XCloseIM(xim);
        xim = NULL;
        XCloseDisplay(xim_display);
        xim_display = NULL;
        return -3;
    }

    fprintf(stderr, "[XIM] Initialized successfully\n");
    return 0;
}

/* Process a key event through XIM.
 * Returns UTF-8 string length in buf, or 0 if filtered/no output.
 *
 * key_code: raw X11 keycode (from xcb event detail)
 * state: X11 modifier mask (from xcb event state)
 * is_press: 1 for KeyPress, 0 for KeyRelease
 * buf: output buffer for composed UTF-8 text
 * buf_size: size of output buffer
 */
int xim_process_key(unsigned int key_code, unsigned int state, int is_press,
                    char *buf, int buf_size) {
    if (!xim_display || !xic) return 0;

    XKeyEvent xev;
    memset(&xev, 0, sizeof(xev));
    xev.type = is_press ? KeyPress : KeyRelease;
    xev.display = xim_display;
    xev.window = xim_window;
    xev.keycode = key_code;
    xev.state = state;
    /* serial, time, root, subwindow, x, y etc. left as 0 — XIM doesn't need them */

    /* Check if XIM wants to filter this event (e.g., composing state) */
    if (XFilterEvent((XEvent *)&xev, xim_window)) {
        return 0; /* Filtered by IME — event consumed for composition */
    }

    if (!is_press) return 0;

    /* Look up the composed string */
    KeySym keysym;
    Status status;
    int len = Xutf8LookupString(xic, &xev, buf, buf_size - 1, &keysym, &status);

    if (status == XLookupChars || status == XLookupBoth) {
        buf[len] = '\0';
        return len;
    }

    return 0;
}

/* Notify XIM that our window gained focus */
void xim_focus_in(void) {
    if (xic) XSetICFocus(xic);
}

/* Notify XIM that our window lost focus */
void xim_focus_out(void) {
    if (xic) XUnsetICFocus(xic);
}

/* Clean up XIM resources */
void xim_cleanup(void) {
    if (xic) { XDestroyIC(xic); xic = NULL; }
    if (xim) { XCloseIM(xim); xim = NULL; }
    if (xim_display) { XCloseDisplay(xim_display); xim_display = NULL; }
}
