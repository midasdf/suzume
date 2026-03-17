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
| Input | evdev direct read (lowest latency path) |
| Font | Any BDF, comptime-embedded. 8x16 base + CJK double-width |
| Config | Compile-time `config.zig` (st philosophy) |
| Scrollback | None (tmux/zellij assumed) |
| PTY | `std.posix` only, no libc |
| Rendering | Damage tracking (dirty cells only) |
| Backends | fbdev / X11 (XCB+SHM) / Wayland (wl_shm) — comptime selection, zero runtime cost |
| Resize | X11/Wayland supported, TIOCSWINSZ + SIGWINCH |
| Event loop | Single-threaded, epoll |
| Perf targets | Startup <50ms, input latency <5ms, RSS <2MB (RPi Zero baseline) |

## Architecture

```
┌─────────────────────────────────────────────┐
│                 Event Loop                   │
│            (epoll: pty_fd + evdev_fd         │
│             + backend_fd + signalfd          │
│             + timerfd)                       │
│                                              │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐ │
│  │  evdev   │──▶│  VT      │   │  PTY     │ │
│  │  reader  │   │  parser  │◀──│  reader  │ │
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
│               │  only)   │   (fb/x11/wl)    │
│               └──────────┘                   │
└─────────────────────────────────────────────┘
```

**Flow:**
1. `epoll` waits on pty fd, evdev fd(s), backend fd, signalfd, timerfd
2. evdev event → keymap translation → write to PTY
3. PTY read → VT parser interprets escape sequences → Cell Grid update + dirty bit set
4. End of loop iteration: render only dirty cells to framebuffer/backend buffer
5. Backend presents buffer (noop for fbdev, XShmPutImage for X11, wl_surface_commit for Wayland)

## Cell Grid + Damage Tracking

```zig
const Cell = packed struct {
    char: u21,          // Unicode codepoint
    fg: u8,             // 256-color index
    bg: u8,             // 256-color index
    attrs: packed struct {
        bold: bool,
        italic: bool,
        underline: bool,
        reverse: bool,
        dim: bool,
        _pad: u3 = 0,
    },
};
// 5 bytes per cell. 80x45 grid = 18KB
```

**Dirty tracking:**
- `dirty_bitmap: []u1` — 1 bit per cell. 80x45 = 450 bytes
- VT parser sets bit when cell is written
- Render loop draws only cells with bit set
- Bitmap cleared after render

**TrueColor support:**
- 256-color index as base in Cell struct
- SGR 38/48 (TrueColor) stored in sparse map outside Cell (`HashMap(usize, [3]u8)` keyed by cell index)
- Most cells use 256-color, saving memory

**Bulk output optimization (AI coding scenario):**
- Read PTY in bulk (up to 64KB per read)
- Parse all VT sequences, update grid, but render only once at end of batch
- Cells that scroll off-screen are never rendered
- Result: `cat 100MB_file` only renders the final screen state

## VT Parser

State machine based on vt100.net state transition diagram.

**Supported (xterm-256color scope):**
- **CSI**: Cursor movement (CUU/CUD/CUF/CUB), erase (ED/EL), SGR (colors + attributes), scroll (SU/SD), DECSTBM, cursor save/restore, DEC modes (DECCKM, DECOM, DECAWM, etc.)
- **OSC**: Window title (0/1/2), clipboard (52)
- **DCS**: tmux passthrough
- **Characters**: UTF-8 decode → codepoint → Cell Grid write. CJK width detection (East Asian Width) for double-width cells

**Implementation:**
- Parser is pure-functional. Consumes input bytes, produces action list
- Actions: `Print(u21)`, `Execute(u8)`, `CsiDispatch(params, intermediate, final)`, `EscDispatch(intermediate, final)`, `OscDispatch(data)`
- Side effects (Grid mutation) handled by action executor, not parser
- UTF-8 decoder is incremental (survives partial reads), invalid sequences → U+FFFD

## Framebuffer Rendering

**FB device:**
- `/dev/fb0` via `mmap()`. Query pixel format/stride via `FBIOGET_VSCREENINFO` / `FBIOGET_FSCREENINFO`
- Supported formats: 32bpp BGRA (common), 16bpp RGB565 (some SBCs), 24bpp RGB

**BDF font (comptime-embedded):**
- BDF file parsed at `comptime` and glyph bitmaps embedded in binary
- Zero startup parse cost
- Glyph lookup: `[u21]?*const GlyphBitmap` — codepoint to bitmap
- Half-width (8xN) and full-width (16xN) distinguished
- Missing glyphs fall back to U+25AF (▯)

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

All three backends share the same hot path: write pixels into a memory buffer. Difference is only in init, present, and resize.

Selected at compile time via `config.zig`:

```zig
const Backend = switch (config.backend) {
    .fbdev => @import("backend/fbdev.zig"),
    .x11 => @import("backend/x11.zig"),
    .wayland => @import("backend/wayland.zig"),
};
```

Zero runtime cost — only selected backend code is compiled.

**Backend interface (comptime duck typing):**
- `init() → BackendState` — open device, create window/surface, allocate buffer
- `getBuffer() → []u8` — pointer to pixel buffer for direct writes
- `present()` — flush to screen (noop for fbdev, XShmPutImage for X11, wl_surface_commit for Wayland)
- `resize(w, h)` — handle resize (fbdev: noop, X11: ConfigureNotify, Wayland: xdg_toplevel.configure)
- `getFd() → ?fd_t` — fd for epoll integration (null for fbdev, xcb fd for X11, wl_display fd for Wayland)
- `deinit()` — cleanup

**Resize flow (X11/Wayland):**
1. Backend reports new pixel dimensions
2. Re-allocate Cell Grid to new cols/rows
3. Set all dirty bits (full redraw)
4. `ioctl(master_fd, TIOCSWINSZ, &new_size)` → child gets SIGWINCH

## evdev Input

**Device detection:**
- Scan `/dev/input/event*`, check `EVIOCGBIT` for `EV_KEY`
- Support multiple keyboard devices (e.g., HackberryPi P9981 + USB keyboard)
- All keyboard fds registered in epoll

**Keymap:**
- Linux keycode (e.g., `KEY_A=30`) → ASCII/UTF-8 via lookup table
- Keymap table defined in `config.zig` (compile-time). Default: US layout
- Modifier state (Shift/Ctrl/Alt/Meta) tracked

**Translation flow:**
```
evdev KEY_A (keycode=30)
  → check modifier state
  → keymap lookup → 'a' or 'A'
  → xterm modifier sequence (Ctrl+A → 0x01, Alt+A → ESC+'a')
  → write to PTY
```

**Special keys:**
- Function keys → xterm CSI sequences (`\e[11~` etc.)
- Arrow keys → DECCKM-dependent (`\eOA` or `\e[A`)
- Home/End/PgUp/PgDn → corresponding CSI sequences

**Key repeat:**
- Use kernel's `EV_REP` events directly (kernel manages repeat)
- Rate/delay configurable via `/sys/class/input/eventN/device/`

## PTY Management

**No libc — pure std.posix:**
1. `open("/dev/ptmx", ...)` → master fd
2. `ioctl(master_fd, TIOCSPTLCK, &unlock)` → unlock slave
3. `ioctl(master_fd, TIOCGPTN, &pty_num)` → get slave number → `/dev/pts/N`
4. `fork()` → child: `setsid()` → open slave → `TIOCSCTTY` → `dup2` stdin/stdout/stderr → `execve` shell

**Child environment:**
```
TERM=xterm-256color
COLORTERM=truecolor
COLUMNS={fb_width / font_width}
LINES={fb_height / font_height}
```

**Child exit detection:**
- `SIGCHLD` via `signalfd` integrated into epoll
- Shell dies → zt exits

## File Structure

```
zt/
├── build.zig
├── build.zig.zon
├── config.zig              # User config (colors, font, keymap, backend)
├── src/
│   ├── main.zig            # Entry point, event loop
│   ├── term.zig            # Cell Grid + dirty bitmap + resize
│   ├── vt.zig              # VT parser (state machine)
│   ├── pty.zig             # PTY creation + management
│   ├── input.zig           # evdev reader + keymap translation
│   ├── font.zig            # BDF comptime parser + glyph storage
│   ├── render.zig          # Common rendering logic (cell → pixels)
│   └── backend/
│       ├── fbdev.zig       # /dev/fb0 mmap
│       ├── x11.zig         # XCB + SHM
│       └── wayland.zig     # wl_shm + xdg_shell
├── fonts/
│   └── default.bdf         # Bundled default BDF font
└── docs/
```

10 source files. Each with a single clear responsibility.

## Performance Targets (HackberryPi Zero 2W baseline)

| Metric | Target | Reference |
|--------|--------|-----------|
| Startup time | <50ms | st: ~30ms, Ghostty: ~200ms |
| Input-to-screen latency | <5ms | st: ~5ms, Ghostty: ~8ms |
| `cat large_file` throughput | >5MB/s | st/X11: ~20MB/s (fbdev limited by memory bus) |
| RSS memory | <2MB | st: ~5MB, Ghostty: ~30MB |
| Binary size | <500KB | st: ~100KB (dynamic Xlib) |

**Startup optimization:**
- BDF font comptime-embedded → zero parse at startup
- No config file parsing (compile-time config)
- Minimal init: open fb/pty/evdev → ready

**Throughput optimization:**
- Bulk PTY read (up to 64KB)
- Batch VT parse → single render pass
- Off-screen cells never rendered

**Measurement methods:**
- Startup: `clock_gettime` at first and last init step
- Latency: evdev timestamp → render completion delta
- Throughput: bytes processed per second from PTY

## Comparison

**vs st:**
- st = X11 only, no BDF, no damage tracking, single backend
- zt = multi-backend, Japanese BDF comptime-embedded, dirty cell rendering

**vs Ghostty:**
- Ghostty = GPU rendering (Metal/OpenGL), large binary, rich features
- zt = CPU direct rendering, <500KB, minimal feature set, runs on RPi Zero
