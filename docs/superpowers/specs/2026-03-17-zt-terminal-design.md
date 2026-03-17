# zt — Framebuffer Terminal Emulator

**Date**: 2026-03-17
**Status**: Design approved

## Overview

zt is a Zig-based terminal emulator that renders directly to the Linux framebuffer. It aims to be faster than Ghostty and as simple as st, with Japanese BDF font support baked in at compile time.

**Core priorities**: Latency, startup time, memory usage.

## Decisions

| Item | Decision |
|------|----------|
| Language | Zig 0.15.2, no libc |
| VT compat | xterm-256color full |
| Input | Backend-native: evdev (fbdev), XCB events (X11), wl_keyboard (Wayland) |
| Font | Any BDF, comptime-embedded. 8x16 base + CJK double-width |
| Config | Compile-time `config.zig` (st philosophy) |
| Scrollback | None (tmux/zellij assumed) |
| PTY | `std.posix` only, no libc |
| Rendering | Damage tracking (dirty cells only) |
| Backends | fbdev / X11 (XCB+SHM) — comptime selection, zero runtime cost. Wayland deferred to Phase 2 |
| Resize | X11 supported (ConfigureNotify), fbdev VT switching handled |
| Event loop | Single-threaded, epoll |
| Perf targets | Startup <50ms, input latency <5ms, RSS <4MB (RPi Zero baseline) |

## Architecture

```
┌─────────────────────────────────────────────┐
│                 Event Loop                   │
│            (epoll: pty_fd + input_fd         │
│             + backend_fd + signalfd          │
│             + timerfd)                       │
│                                              │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐ │
│  │  Input   │──▶│  VT      │   │  PTY     │ │
│  │ (native) │   │  parser  │◀──│  reader  │ │
│  └──────────┘   └────┬─────┘   └──────────┘ │
│                      │                       │
│                      ▼                       │
│               ┌──────────┐                   │
│               │  Cell    │                   │
│               │  Grid    │                   │
│               │ + dirty  │                   │
│               │  bitmap  │                   │
│               └────┬─────┘                   │
│                    │                          │
│                    ▼                          │
│               ┌──────────┐                   │
│               │  render  │                   │
│               │ (dirty   │──▶ Backend        │
│               │  only)   │   (fb/x11)       │
│               └──────────┘                   │
└─────────────────────────────────────────────┘
```

**Flow:**
1. `epoll` waits on pty fd, input fd(s), backend fd, signalfd, timerfd
2. Input event (evdev or XCB key event) → keymap translation → write to PTY
3. PTY read → VT parser interprets escape sequences → Cell Grid update + dirty bit set
4. End of loop iteration: render only dirty cells to backend buffer
5. Backend presents buffer (noop for fbdev, XShmPutImage for X11)

## Cell Grid + Damage Tracking

```zig
const Cell = struct {
    char: u21,          // Unicode codepoint
    fg: u8,             // 256-color index
    bg: u8,             // 256-color index
    attrs: packed struct(u8) {
        bold: bool,
        italic: bool,
        underline: bool,
        reverse: bool,
        dim: bool,
        _pad: u3 = 0,
    },
};
// 8 bytes per cell (natural alignment). 80x45 grid = 28.8KB
```

Non-packed struct with natural alignment — avoids ARM unaligned access penalty on Cortex-A53.

**Dirty tracking:**
- `std.DynamicBitSet` — 1 bit per cell. 80x45 = 450 bits = 57 bytes
- VT parser sets bit when cell is written
- Render loop draws only cells with bit set
- Bitmap cleared after render

**TrueColor support:**
- 256-color index as base in Cell struct
- SGR 38/48 (TrueColor) stored in sparse map outside Cell (`HashMap(usize, [3]u8)` keyed by cell index)
- Most cells use 256-color, saving memory

**Alternate screen buffer (DECSET 47/1047/1049):**
- Two Cell Grid instances: main and alternate
- VT parser switches active grid on DECSET/DECRST 1049
- Required for vim, less, htop, etc.

**Bulk output optimization (AI coding scenario):**
- Read PTY in bulk (up to 64KB per read)
- Parse all VT sequences, update grid, but render only once at end of batch
- Cells that scroll off-screen are never rendered
- Result: `cat 100MB_file` only renders the final screen state

## VT Parser

State machine based on vt100.net state transition diagram.

**Supported (xterm-256color scope):**
- **CSI**: Cursor movement (CUU/CUD/CUF/CUB), erase (ED/EL), SGR (colors + attributes), scroll (SU/SD), DECSTBM, cursor save/restore, DEC modes (DECCKM, DECOM, DECAWM, DECSET 1049/47/1047 alternate screen, DECSET 2004 bracketed paste, etc.)
- **OSC**: Window title (0/1/2), clipboard (52)
- **DCS**: tmux passthrough
- **Characters**: UTF-8 decode → codepoint → Cell Grid write. CJK width detection (East Asian Width) for double-width cells

**Explicitly NOT supported (xterm features out of scope):**
- Sixel graphics
- ReGIS graphics
- Tektronix 4014 mode

**Implementation:**
- Parser is pure-functional. Consumes input bytes, produces action list
- Actions: `Print(u21)`, `Execute(u8)`, `CsiDispatch(params, intermediate, final)`, `EscDispatch(intermediate, final)`, `OscDispatch(data)`
- Side effects (Grid mutation) handled by action executor, not parser
- UTF-8 decoder is incremental (survives partial reads), invalid sequences → U+FFFD

**terminfo strategy:**
- Set `TERM=xterm-256color` — ubiquitous terminfo entry
- Full xterm-256color compliance is the target; no custom terminfo entry needed
- Mouse tracking: deferred to Phase 2 (applications fall back to keyboard-only gracefully)

## Framebuffer Rendering

**FB device:**
- `/dev/fb0` via `mmap()`. Query pixel format/stride via `FBIOGET_VSCREENINFO` / `FBIOGET_FSCREENINFO`
- Supported formats: 32bpp BGRA (common), 16bpp RGB565 (some SBCs), 24bpp RGB
- Shadow buffer for rendering, selective copy to fbdev to reduce tearing

**BDF font (comptime-embedded):**
- BDF file parsed at `comptime` and glyph bitmaps embedded in binary
- Zero startup parse cost
- Glyph lookup: comptime-generated lookup table indexed by codepoint
- Half-width (8xN) and full-width (16xN) distinguished
- Missing glyphs fall back to U+25AF (▯)
- Note: Large CJK fonts may slow compilation. If compile time exceeds 30s, switch to build.zig pre-processing step that generates a binary blob

**Cell rendering:**
```
1 cell = fill bg rect + blit glyph bitmap with fg color
```
- Bold: draw glyph shifted 1px right (bitmap font convention)
- Reverse: swap fg/bg
- Underline: horizontal line at bottom row
- Dim: darken fg color by 50%

**Cursor:**
- Block cursor = fg/bg inverted cell
- Blink via `timerfd_create` registered in epoll

## Backends

### Phase 1: fbdev + X11

Both backends share the same hot path: write pixels into a memory buffer.

Selected at compile time via `config.zig`:

```zig
const Backend = switch (config.backend) {
    .fbdev => @import("backend/fbdev.zig"),
    .x11 => @import("backend/x11.zig"),
};
```

Zero runtime cost — only selected backend code is compiled.

**Backend interface (comptime duck typing):**
- `init() → BackendState` — open device, create window/surface, allocate buffer
- `getBuffer() → []u8` — pointer to pixel buffer for direct writes
- `present()` — flush to screen (noop for fbdev, XShmPutImage for X11)
- `resize(w, h)` — handle resize (fbdev: noop, X11: ConfigureNotify)
- `getFd() → ?fd_t` — fd for epoll integration (null for fbdev, xcb fd for X11)
- `getInputEvents() → []InputEvent` — backend-native input (evdev for fbdev, XCB key events for X11)
- `deinit()` — cleanup

**Resize flow (X11):**
1. Backend reports new pixel dimensions via ConfigureNotify
2. Re-allocate Cell Grid to new cols/rows
3. Set all dirty bits (full redraw)
4. `ioctl(master_fd, TIOCSWINSZ, &new_size)` → child gets SIGWINCH

### Phase 2 (future): Wayland

Wayland backend (wl_shm + xdg_shell) deferred because implementing the Wayland wire protocol without libwayland-client is a large undertaking (registry, compositor, xdg_wm_base, wl_shm, wl_seat, wl_keyboard all manual). Will be designed and specced separately.

## Input

Input handling is **backend-native** — each backend provides input through its own mechanism:

**fbdev backend: evdev direct read**
- Scan `/dev/input/event*`, check `EVIOCGBIT` for `EV_KEY`
- Support multiple keyboard devices (e.g., HackberryPi P9981 + USB keyboard)
- All keyboard fds registered in epoll
- Requires root or `input` group membership
- Keymap table defined in `config.zig` (compile-time). Default: US layout
- Modifier state (Shift/Ctrl/Alt/Meta) tracked
- Key repeat: use kernel's `EV_REP` events directly

**X11 backend: XCB key events**
- Key events from XCB event loop (already in epoll via xcb fd)
- Uses system XKB keymap — respects user's configured keyboard layout
- No root/input group needed

**Common translation (both backends):**
```
keycode + modifiers
  → xterm modifier sequence (Ctrl+A → 0x01, Alt+A → ESC+'a')
  → function keys → xterm CSI sequences (\e[11~ etc.)
  → arrow keys → DECCKM-dependent (\eOA or \e[A)
  → write to PTY
```

**Selection / copy-paste:**
- Delegated to tmux/zellij (consistent with no-scrollback philosophy)
- OSC 52 clipboard support in VT parser for application-initiated clipboard operations
- Bracketed paste (DECSET 2004) supported for safe pasting in shells

**Mouse support:** Deferred to Phase 2. Applications fall back to keyboard-only mode.

## PTY Management

**No libc — pure std.posix:**

Child process setup sequence (order matters):
1. `open("/dev/ptmx", ...)` → master fd
2. `ioctl(master_fd, TIOCSPTLCK, &unlock)` → unlock slave
3. `ioctl(master_fd, TIOCGPTN, &pty_num)` → get slave number → `/dev/pts/N`
4. `fork()` → **in child:**
   a. `setsid()` — create new session (must be before opening slave)
   b. Open slave fd (`/dev/pts/N`)
   c. `ioctl(slave_fd, TIOCSCTTY, 0)` — set controlling terminal
   d. `dup2(slave_fd, 0/1/2)` — redirect stdin/stdout/stderr
   e. Close master fd and original slave fd
   f. Reset signal dispositions to default (SIGCHLD, SIGPIPE, etc.)
   g. Set up environment variables
   h. `execve` user's shell
5. **In parent:** close slave fd

**Child environment:**
```
TERM=xterm-256color
COLORTERM=truecolor
COLUMNS={width / font_width}
LINES={height / font_height}
SHELL={user's shell from /etc/passwd or $SHELL}
HOME={user's home}
USER={username}
PATH={inherited or /usr/local/bin:/usr/bin:/bin}
LANG={inherited}
```

## Signal Handling

All signals handled via `signalfd` integrated into epoll (no async signal handlers):

| Signal | Action |
|--------|--------|
| `SIGCHLD` | Child exited → clean up PTY → exit zt |
| `SIGTERM` | Graceful shutdown: restore console state, release fbdev, exit |
| `SIGINT` | Same as SIGTERM |
| `SIGHUP` | Same as SIGTERM |
| `SIGTSTP` | fbdev: save framebuffer state, release VT, stop. X11: just stop |
| `SIGCONT` | fbdev: re-acquire VT, restore framebuffer, redraw. X11: redraw |

**fbdev console restore on exit/crash:**
- `atexit`-equivalent cleanup: restore original VT mode, keyboard mode, and console state
- Without this, crash leaves user with blank screen and no input

## fbdev VT Switching

When running on fbdev, Linux virtual terminal switching (Ctrl+Alt+F1-F6) must be handled:

1. `VT_SETMODE` with `VT_PROCESS` — tell kernel we want to handle VT switches
2. On `SIGUSR1` (release signal): save state, release fbdev, `VT_RELDISP` to allow switch
3. On `SIGUSR2` (acquire signal): re-acquire fbdev, restore state, full redraw
4. `SIGUSR1`/`SIGUSR2` routed through signalfd into epoll

Without this, switching VTs while zt runs would corrupt both displays.

## File Structure

```
zt/
├── build.zig
├── build.zig.zon
├── config.zig              # User config (colors, font, keymap, backend)
├── src/
│   ├── main.zig            # Entry point, event loop, signal handling
│   ├── term.zig            # Cell Grid + dirty bitmap + resize + alt screen
│   ├── vt.zig              # VT parser (state machine)
│   ├── pty.zig             # PTY creation + management + child setup
│   ├── input.zig           # Common input translation (keycode → VT sequence)
│   ├── font.zig            # BDF comptime parser + glyph storage
│   ├── render.zig          # Common rendering logic (cell → pixels)
│   └── backend/
│       ├── fbdev.zig       # /dev/fb0 mmap + evdev input + VT switching
│       └── x11.zig         # XCB + SHM + XCB key events
├── fonts/
│   └── default.bdf         # Bundled default BDF font
└── docs/
```

9 source files. Each with a single clear responsibility.

## Performance Targets (HackberryPi Zero 2W baseline)

| Metric | Target | Reference |
|--------|--------|-----------|
| Startup time | <50ms | st: ~30ms, Ghostty: ~200ms |
| Input-to-screen latency | <5ms | st: ~5ms, Ghostty: ~8ms |
| `cat large_file` throughput | >5MB/s | st/X11: ~20MB/s (fbdev limited by memory bus) |
| RSS memory | <4MB | st: ~5MB, Ghostty: ~30MB |
| Binary size | <500KB (fbdev) / <1MB (X11) | st: ~100KB (dynamic Xlib) |

RSS target adjusted to 4MB to account for comptime-embedded CJK BDF font (~700KB for full CJK Unified Ideographs at 16x16). Measure early with target font.

**Startup optimization:**
- BDF font comptime-embedded → zero parse at startup
- No config file parsing (compile-time config)
- Minimal init: open fb/pty/input → ready

**Throughput optimization:**
- Bulk PTY read (up to 64KB)
- Batch VT parse → single render pass
- Off-screen cells never rendered
- Shadow buffer + selective copy to fbdev (reduces tearing)

**Measurement methods:**
- Startup: `clock_gettime` at first and last init step
- Latency: input timestamp → render completion delta
- Throughput: bytes processed per second from PTY

## Phasing

| Phase | Scope |
|-------|-------|
| Phase 1 | fbdev backend + X11 backend, VT parser, BDF font, evdev/XCB input, PTY, damage tracking |
| Phase 2 | Mouse support, Wayland backend, sixel (maybe) |

## Comparison

**vs st:**
- st = X11 only, no BDF, no damage tracking, single backend
- zt = multi-backend, Japanese BDF comptime-embedded, dirty cell rendering, fbdev native

**vs Ghostty:**
- Ghostty = GPU rendering (Metal/OpenGL), large binary, rich features
- zt = CPU direct rendering, <500KB, minimal feature set, runs on RPi Zero
