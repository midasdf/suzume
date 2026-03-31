# zt Wayland Backend Design Spec

**Date**: 2026-04-01
**Status**: Approved
**Scope**: Add Wayland backend to zt terminal emulator

## Overview

Add a fourth backend (`-Dbackend=wayland`) to zt, implementing the Wayland display protocol in pure Zig without libwayland-client. Uses wl_shm for buffer sharing, fitting directly into the existing software rendering pipeline.

## Goals

- Wayland-native terminal with zero external Wayland library dependencies
- xdg-shell compliant for broad compositor support (Sway, Hyprland, GNOME, KDE, etc.)
- Japanese IME support via text-input-v3 from day one
- Full clipboard support (wl_data_device + primary selection)
- Same public API as existing backends (comptime switch, zero-cost)

## Non-Goals

- GPU rendering (DMA-BUF, EGL, Vulkan)
- Fractional scaling (existing `-Dscale` flag is sufficient)
- Client-side decorations (fallback to borderless if SSD unavailable)
- Mouse selection / scrollback (not implemented in zt core)
- Touchscreen / tablet input

## Protocols

| Protocol | Version | Purpose |
|----------|---------|---------|
| wl_compositor | 4+ | Surface creation |
| wl_shm | 1 | Shared memory buffers |
| xdg_wm_base | 2+ | Window management |
| wl_seat | 5+ | Keyboard + pointer |
| zwp_text_input_v3 | 1 | IME (fcitx5, ibus) |
| wl_data_device_manager | 3 | Clipboard (copy/paste) |
| zwp_primary_selection_device_manager_v1 | 1 | Primary selection (middle-click paste) |
| zxdg_decoration_manager_v1 | 1 | Server-side decoration |
| wp_cursor_shape_manager_v1 | 1 | Cursor shape (avoids loading cursor theme manually) |

## File Structure

```
src/backend/
├── wayland.zig              # WaylandBackend struct (public API)
└── wayland/
    ├── wire.zig             # Wire protocol: socket, message encode/decode, fd passing
    ├── core.zig             # wl_display, wl_registry, wl_compositor, wl_shm, wl_buffer
    ├── xdg_shell.zig        # xdg_wm_base, xdg_surface, xdg_toplevel, configure handshake
    ├── seat.zig             # wl_seat, wl_keyboard (xkbcommon), wl_pointer
    ├── text_input.zig       # zwp_text_input_v3: preedit, commit
    ├── clipboard.zig        # wl_data_device + zwp_primary_selection
    └── decoration.zig       # zxdg_decoration_manager_v1 (SSD preference)
```

## Build Integration

### config.zig

```zig
pub const Backend = enum { fbdev, x11, wayland, macos };
```

### build.zig

New `-Dbackend=wayland` option. Links only `xkbcommon` (no xcb, no libwayland). All Wayland communication via pure Zig over UNIX socket.

### main.zig

Add `.wayland` branch to all `switch (config.backend)` and `if (config.backend == .x11 or config.backend == .macos)` conditionals in main.zig. Includes: `Backend` type import, `BackendEvent` union, `backend.init()` call (no allocator arg, matching x11/macos pattern), and event dispatch in the epoll loop.

Event loop uses Linux epoll (shared with fbdev/x11). Wayland socket fd registered in epoll alongside PTY fd and timer fds.

Build.zig adds `use_wayland` boolean flag (matching existing `use_x11`/`use_macos` pattern) to derive the backend enum in config.zig.

## Wire Protocol (wire.zig)

### Connection

1. Read `$WAYLAND_DISPLAY` (default: `wayland-0`)
2. Connect to UNIX socket at `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY`

### Message Format

All messages share a common header:

```
[object_id: u32][size_opcode: u32][payload...]
                 upper 16 bits = total size in bytes (4-byte aligned, includes 8-byte header)
                 lower 16 bits = opcode
```

Individual arguments within messages are padded to 4-byte boundaries (not 8).

### Key Types

```zig
const Header = packed struct {
    object_id: u32,
    size_opcode: u32,
};

const Message = struct {
    header: Header,
    payload: []const u8,
    fds: []const posix.fd_t,
};
```

### fd Passing

Uses `sendmsg`/`recvmsg` with `SCM_RIGHTS` ancillary data. Required for passing `memfd_create` fds to the compositor for wl_shm buffer sharing.

### Object ID Management

- Client allocates IDs starting from 1, incrementing
- `wl_display` is always ID 1 (fixed)
- Released IDs recycled via free list

### Receive Buffer

4KB ring buffer. On epoll IN: `recvmsg` -> parse headers -> dispatch to registered handlers via object_id lookup table. Multiple messages may arrive in a single `recvmsg`. Must handle partial reads where a message spans two `recvmsg` calls (buffer remaining bytes, prepend to next read).

### Error Handling

`wl_display` (object ID 1) can send an `error` event at any time, indicating a protocol violation or compositor-side error. wire.zig must always dispatch `wl_display.error` and surface it as a fatal error with the error code and message. Without this, protocol violations result in silent hangs or crashes with no diagnostic information.

## Core Protocol (core.zig)

### Startup Sequence

```
connect() -> wl_display (ID=1)
  -> wl_display.get_registry() -> wl_registry
  -> wl_registry.global events (enumerate available interfaces)
     bind required globals:
       wl_compositor, wl_shm, xdg_wm_base, wl_seat,
       wl_data_device_manager, zwp_text_input_manager_v3,
       zxdg_decoration_manager_v1, zwp_primary_selection_device_manager_v1
  -> wl_display.sync() (roundtrip: ensure all globals received)
  -> wl_shm.format events (verify ARGB8888 supported; mandatory per protocol)
  -> wl_compositor.create_surface() -> wl_surface
  -> xdg_wm_base.get_xdg_surface(wl_surface) -> xdg_surface
  -> xdg_surface.get_toplevel() -> xdg_toplevel
     set_title("zt"), set_app_id("zt"), set_min_size(...)
  -> decoration: set_mode(server_side)
  -> wl_surface.commit() (triggers initial configure)
  -> receive xdg_toplevel.configure(width, height, states)
  -> xdg_surface.ack_configure(serial)
  -> create SHM buffers -> first frame render
```

### wl_shm Double Buffer

```
memfd_create("zt-shm") -> fd
ftruncate(fd, width * height * 4 * 2)   // 2 pages
mmap() -> memory region

wl_shm.create_pool(fd, size) -> wl_shm_pool
pool.create_buffer(offset=0, ...)          -> buffer_a
pool.create_buffer(offset=page_size, ...)  -> buffer_b
```

- `buffer.release` event signals buffer is reusable
- render.zig writes to current buffer's `[]u8` (identical to X11 path)
- `present()`: `wl_surface.attach(buffer)` -> `wl_surface.damage_buffer(dirty_y_min..dirty_y_max)` -> `wl_surface.commit()`
- Buffer swap on each present

### Pixel Format

Wayland `WL_SHM_FORMAT_ARGB8888` on little-endian has the same memory layout as X11's BGRA32. No changes to render.zig needed. Call `wl_surface.set_buffer_scale(config.scale)` during surface setup to inform the compositor of the buffer's scale factor (prevents double-scaling on HiDPI displays).

### Resize

On `xdg_toplevel.configure(width, height, states)`:
1. If width=0, height=0: client chooses size (initial display)
2. Otherwise: recreate SHM pool with new dimensions
3. Call term.resize() to update grid
4. Full redraw (set all_dirty)

## Input (seat.zig)

### Keyboard

```
wl_seat.get_keyboard() -> wl_keyboard

wl_keyboard.keymap(format=xkb_v1, fd, size)
  -> mmap(fd, size) -> xkb_keymap_new_from_string()
  -> xkb_state_new(keymap)

wl_keyboard.key(serial, time, key, state)
  -> key is evdev keycode (no conversion needed, unlike X11's keycode-8)
  -> xkb_state_key_get_utf8() for text
  -> feed to existing input.zig evdev path

wl_keyboard.modifiers(serial, depressed, latched, locked, group)
  -> xkb_state_update_mask()

wl_keyboard.enter(serial, surface, keys[])
  -> focus gained, keys[] = currently held keys

wl_keyboard.leave(serial, surface)
  -> focus lost
```

Wayland keycodes are native evdev keycodes. The existing `input.zig` keycode-to-VT100 translation works without modification.

### Key Repeat

Client-side responsibility in Wayland (unlike X11/fbdev where server/kernel handles it).

```
wl_keyboard.repeat_info(rate, delay)
  -> timerfd_create(CLOCK_MONOTONIC)
  -> on key press: timerfd_settime(delay_ms, then interval = 1000/rate ms)
  -> on key release / new key: reset timer
  -> timerfd registered in backend's internal epoll (see Internal Epoll section)
```

### Internal Epoll

The Wayland backend creates its own internal epoll fd that wraps:
- The Wayland socket fd (protocol events)
- The key repeat timerfd
- Clipboard pipe read fds (temporary, removed after read completes)

This internal epoll fd is what `getFd()` returns to main.zig. When main.zig's outer epoll signals the backend fd as readable, `pollEvents()` calls `epoll_wait` on the internal epoll to determine which internal fd fired. This keeps main.zig's dispatch logic unchanged (single backend fd, single `EpollTag.backend`).

### Pointer (minimal)

```
wl_seat.get_pointer() -> wl_pointer
  enter: set cursor shape via wp_cursor_shape_device_v1.set_shape(default)
         fallback if wp_cursor_shape_manager_v1 unavailable: create 1x1 wl_surface as cursor
  leave: no action
  button: store serial for clipboard operations
```

In Wayland, the compositor does NOT set a cursor for the client. The client must explicitly set its own cursor on `wl_pointer.enter`. Using `wp_cursor_shape_manager_v1` avoids loading cursor theme files manually.

No mouse selection or scroll handling.

## IME (text_input.zig)

### Protocol

```
zwp_text_input_manager_v3.get_text_input(wl_seat) -> zwp_text_input_v3
```

### Lifecycle

```
keyboard.enter -> text_input.enable() + commit()
keyboard.leave -> text_input.disable() + commit()
```

### Events

```
text_input.preedit_string(text, cursor_begin, cursor_end)
  -> store preedit text, render as underlined overlay at cursor position

text_input.commit_string(text)
  -> write UTF-8 bytes to PTY (identical to X11 XIM commit path)

text_input.done(serial)
  -> batch end marker, apply preedit + commit together
```

### Preedit Rendering

Preedit text drawn as underlined overlay at terminal cursor position during the render phase in wayland.zig. No changes to term.zig. Cleared on commit_string or disable.

### Comparison with X11 XIM

| Aspect | X11 XIM | Wayland text-input-v3 |
|--------|---------|----------------------|
| Connection | xcb-imdkit, async callbacks | Simple Wayland object |
| Key filtering | Manual: pass to XIM, wait for consumed/forwarded | Compositor handles filtering |
| Preedit | XIM callback management | Event-driven |
| Commit | Callback | Event-driven |
| Complexity | ~500 lines | ~100 lines estimated |

## Clipboard (clipboard.zig)

### wl_data_device (Ctrl+Shift+V / Ctrl+Shift+C)

**Paste (receive)**:
```
wl_data_device.data_offer event -> check for "text/plain;charset=utf-8"
Ctrl+Shift+V:
  pipe2() -> (read_fd, write_fd)
  data_offer.receive("text/plain;charset=utf-8", write_fd)
  wl_display.flush()
  register read_fd in epoll -> read data -> write to PTY
  close both fds
```

**Copy (send)**:
```
wl_data_device_manager.create_data_source() -> source
source.offer("text/plain;charset=utf-8")
wl_data_device.set_selection(source, serial)
  -> on source.send event: write(fd, selection_text)
```

### Primary Selection (middle-click / Shift+Insert)

Same pattern as wl_data_device but using `zwp_primary_selection_*` interfaces:

```
zwp_primary_selection_device_manager_v1.get_device(wl_seat) -> device
device.selection event -> offer.receive() -> pipe -> PTY
```

### Implementation Note

wl_data_device and primary_selection share the same offer/receive/send pattern. Internal helpers reuse the `pipe2 -> receive -> epoll read -> PTY write` flow.

Pipe read fds are registered in epoll for non-blocking reads to avoid blocking the UI.

## XDG Shell Lifecycle (xdg_shell.zig)

### ping/pong

Compositors send `xdg_wm_base.ping(serial)` periodically to check client responsiveness. The client must respond with `xdg_wm_base.pong(serial)` immediately. Failure to respond causes compositors to grey out the window or show "not responding" dialogs. This is handled in `pollEvents()` as a simple event -> response, no state tracking needed.

## Decoration (decoration.zig)

```
zxdg_decoration_manager_v1.get_toplevel_decoration(xdg_toplevel) -> decoration
decoration.set_mode(server_side)
  -> decoration.configure(mode):
     server_side -> OK, compositor draws title bar
     client_side -> run borderless (no CSD implementation)
```

## WaylandBackend Struct

```zig
pub const WaylandBackend = struct {
    // Wire protocol
    socket_fd: posix.fd_t,

    // Core objects
    display: wl.Display,
    registry: wl.Registry,
    compositor: ?wl.Compositor,
    shm: ?wl.Shm,
    xdg_wm_base: ?xdg.WmBase,
    seat: ?wl.Seat,

    // SHM buffers
    shm_fd: posix.fd_t,
    shm_pool: wl.ShmPool,
    buffers: [2]Buffer,
    current_buffer: u1,

    // Input
    xkb_context: *xkb.Context,
    xkb_state: ?*xkb.State,
    repeat_timer_fd: posix.fd_t,
    repeat_key: ?u32,

    // IME
    preedit_text: ?[]const u8,

    // Clipboard
    clipboard_offer: ?wl.DataOffer,
    primary_offer: ?PrimaryOffer,

    // Window state
    width: u32,
    height: u32,
    configured: bool,
    dirty_y_min: u32,
    dirty_y_max: u32,

    // Public API (same signatures as x11.zig)
    pub fn init() !WaylandBackend
    pub fn deinit(self: *WaylandBackend) void
    pub fn postInit(self: *WaylandBackend) void
    pub fn getBuffer(self: *WaylandBackend) []u8
    pub fn getStride(self: *WaylandBackend) u32
    pub fn getWidth(self: *WaylandBackend) u32
    pub fn getHeight(self: *WaylandBackend) u32
    pub fn getBpp(self: *WaylandBackend) u32
    pub fn markDirtyRows(self: *WaylandBackend, y_start: u32, y_end: u32) void
    pub fn present(self: *WaylandBackend) void
    pub fn flush(self: *WaylandBackend) void
    pub fn resize(self: *WaylandBackend, w: u32, h: u32) !void
    pub fn queryGeometry(self: *WaylandBackend) struct { w: u32, h: u32 }
    pub fn getFd(self: *WaylandBackend) ?posix.fd_t
    pub fn pollEvents(self: *WaylandBackend, ...) ?Event

    // No-op stubs (fbdev-only, called unconditionally by main.zig)
    pub fn saveConsoleState(self: *WaylandBackend) !void
    pub fn restoreConsoleState(self: *WaylandBackend) void
    pub fn setupVtSwitching(self: *WaylandBackend) !void
    pub fn releaseVt(self: *WaylandBackend) void
    pub fn acquireVt(self: *WaylandBackend) void
};
```

## Dependencies

| Dependency | Wayland backend | X11 backend | Notes |
|-----------|----------------|-------------|-------|
| libwayland-client | No | N/A | Pure Zig wire protocol |
| xcb | No | Yes | Not needed |
| xcb-shm | No | Yes | Using wl_shm via Zig |
| xcb-xkb | No | Yes | Not needed |
| xcb-imdkit | No | Yes | Using text-input-v3 |
| xkbcommon | Yes | Yes | Keymap parsing (shared) |
| xkbcommon-x11 | No | Yes | Not needed |

Only external dependency: `xkbcommon` (already used by X11 backend).

## Estimated Size

| File | Estimated LoC |
|------|--------------|
| wayland.zig | ~350 |
| wire.zig | ~450 |
| core.zig | ~250 |
| xdg_shell.zig | ~200 |
| seat.zig | ~300 |
| text_input.zig | ~120 |
| clipboard.zig | ~250 |
| decoration.zig | ~80 |
| **Total** | **~2000** |

Wire protocol is the largest module due to: socket connection, sendmsg/recvmsg with SCM_RIGHTS, message framing with partial-read handling, object ID allocation with free list, event dispatch table, and argument serialization for 8 Wayland types (int, uint, fixed, string, object, new_id, array, fd).

## Testing Strategy

- **Unit tests**: Wire protocol message encode/decode, object ID allocation, event dispatch
- **Integration tests**: Connect to a running compositor (Sway/Hyprland in CI or manual), verify window creation, keyboard input, resize
- **Manual testing**: vim, fish, Claude Code under Wayland compositors
- **IME testing**: fcitx5 under Sway with Japanese input

## Risk Assessment

| Risk | Mitigation |
|------|-----------|
| Wire protocol bugs (byte ordering, alignment) | Extensive unit tests for message format |
| Compositor-specific quirks | Target xdg-shell strict compliance, test on Sway + GNOME |
| Key repeat timing drift | Use timerfd absolute mode, not relative |
| SHM buffer race (write while compositor reads) | Double buffer with release event tracking |
| preedit rendering artifacts | Clear preedit region before redraw |
| Cursor invisible on hover | wp_cursor_shape_manager_v1, fallback to 1x1 surface |
| Client marked unresponsive | Always handle xdg_wm_base ping with immediate pong |
