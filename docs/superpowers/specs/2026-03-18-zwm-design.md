# zwm — Ultra-Minimal Tiling Window Manager in Zig

## Overview

zwm is an ultra-minimal tiling window manager for X11, written in Zig. Inspired by dwm's philosophy of simplicity but designed from scratch using xcb (not Xlib) for minimal overhead. Primary target is the HackberryPi Zero (720x720 display, 4GB RAM, Cortex-A53) but works on any X11 Linux system.

**Core principles:**
- Minimal binary size (target <50KB ReleaseSmall)
- Zero runtime config parsing — all configuration at comptime via `config.zig`
- xcb direct — no Xlib wrapper overhead
- Single-threaded blocking event loop
- ~1500 lines of Zig total

## Target Environment

| Property | Value |
|----------|-------|
| Primary device | HackberryPi Zero (RPi Zero 2W) |
| Display | 720x720 HyperPixel4 (fbdev) |
| RAM | 4GB |
| CPU | Cortex-A53 (aarch64), overclocked 1.2GHz |
| Display server | X.org with xf86-video-fbdev |
| Secondary target | Any Linux x86_64/aarch64 with X11 |

## Architecture

### File Structure

```
zwm/
├── build.zig
├── build.zig.zon
├── src/
│   ├── main.zig       # Entry point, event loop, signal handling
│   ├── wm.zig         # WM state, client management, event dispatch
│   ├── xcb.zig        # @cImport for xcb + thin helpers
│   ├── layout.zig     # Master+stack tiling calculation (pure functions)
│   ├── monitor.zig    # Multi-monitor management via XRandR
│   └── config.zig     # Comptime configuration (keybinds, colors, gaps)
```

6 files total. Each module has a single responsibility.

### Dependencies

**System libraries (linked via `@cImport`):**
- `xcb` — core X11 protocol
- `xcb-keysyms` — key symbol resolution
- `xcb-randr` — multi-monitor detection and hotplug

**No external Zig packages.** Only `std` and the three xcb C libraries above.

EWMH/ICCCM atoms (`_NET_SUPPORTED`, `WM_DELETE_WINDOW`, etc.) are managed manually via `xcb_intern_atom`, same approach as dwm. No `xcb-util-wm` dependency — keeps the dependency count minimal and avoids pulling in unused helpers.

### Build

```zig
// build.zig links:
exe.linkSystemLibrary("xcb");
exe.linkSystemLibrary("xcb-keysyms");
exe.linkSystemLibrary("xcb-randr");
exe.linkLibC();
```

Cross-compilation for aarch64 supported via `zig build -Dtarget=aarch64-linux-gnu`. Note: when cross-compiling with system C libraries, a sysroot with aarch64 xcb headers/libs is needed (see HackberryPi paru cross-compile notes for sysroot setup pattern).

## Data Model

### Client

A doubly-linked list of clients:

```zig
const ClientList = struct { first: ?*Client = null, last: ?*Client = null };
```

Represents a managed window:

```zig
const Client = struct {
    window: xcb.Window,
    x: i16,
    y: i16,
    w: u16,
    h: u16,
    tags: u9,            // Bitmask, 9 tags (workspaces)
    is_floating: bool,
    is_fullscreen: bool,
    monitor: *Monitor,
    // Intrusive doubly-linked list node
    prev: ?*Client,
    next: ?*Client,
};
```

### Monitor

Represents a physical output:

```zig
const Monitor = struct {
    x: i16,
    y: i16,
    w: u16,
    h: u16,
    selected_tags: u9,     // Currently visible tags (bitmask)
    master_factor: f32,    // Ratio of master area width (0.0–1.0)
    master_count: u8,      // Number of windows in master area
    clients: ClientList,   // All clients on this monitor
    focus_stack: ClientList, // Focus order (MRU)
    // Linked list of monitors
    prev: ?*Monitor,
    next: ?*Monitor,
};
```

### Tag System

Tags use a 9-bit bitmask (`u9`), identical to dwm:

- Each window has `tags: u9` — which tags it belongs to
- Each monitor has `selected_tags: u9` — which tags are currently visible
- A window is visible when `client.tags & monitor.selected_tags != 0`
- Multiple tags can be selected simultaneously (e.g., view tag 1 and 3 together)
- A window can belong to multiple tags

This is more flexible than i3's workspace model. On a 720x720 screen, you'll typically use one tag at a time, but multi-tag view is there when useful.

## Layout Engine

### Master+Stack

Single layout algorithm. Pure function with no xcb dependency:

```zig
const Geometry = struct { x: i16, y: i16, w: u16, h: u16 };

fn tile(
    visible_clients: []const *Client,
    mon_area: Geometry,
    master_count: u8,
    master_factor: f32,
    gap: u16,
) []Geometry
```

**Behavior:**
- 0 clients: no-op
- 1 client: fills entire monitor area (no gaps, no border — monocle)
- 2+ clients: master area on left, stack on right

```
┌──────────┬─────────┐
│          │  stack1  │
│  master  ├─────────┤
│          │  stack2  │
│          ├─────────┤
│          │  stack3  │
└──────────┴─────────┘
```

- Master width = `mon_area.w * master_factor`
- Stack windows split the remaining width equally in height
- Multiple master windows: master area splits vertically
- Gap and border values from comptime config

### Why Only One Layout

720x720 is too small for complex layouts to be useful. Master+stack handles the common cases:
- Single window → fullscreen automatically
- Two windows → side by side
- Many windows → one focus + overview

Adding more layouts later is straightforward — `layout.zig` is a pure function, just add another and wire it to a keybind.

## Multi-Monitor Support

### Detection

Uses XRandR extension:
1. On startup: query via `xcb_randr_get_screen_resources` + `xcb_randr_get_crtc_info` (widely supported; RandR 1.5 `get_monitors` may not be available on fbdev)
2. Subscribe to `XCB_RANDR_NOTIFY_MASK_SCREEN_CHANGE`
3. On hotplug event: re-query monitors, redistribute clients

### Monitor Model

- Each monitor owns an independent set of: selected tags, master factor, master count, client list, focus stack
- Monitors are stored in a linked list
- One monitor is the "selected" monitor (where keyboard focus is)

### Monitor Operations

| Keybind | Action |
|---------|--------|
| `Mod+,` | Focus previous monitor |
| `Mod+.` | Focus next monitor |
| `Mod+Shift+,` | Send focused window to previous monitor |
| `Mod+Shift+.` | Send focused window to next monitor |

When a window moves between monitors, it keeps its tags but gets re-tiled on the destination monitor.

## Configuration (config.zig)

All configuration is comptime. Changing settings requires recompilation (`zig build` takes <1s).

```zig
pub const mod_key: Modifier = .mod4;    // Super key
pub const terminal: []const u8 = "st";
pub const master_factor: f32 = 0.55;
pub const gap_px: u16 = 0;
pub const border_px: u16 = 1;
pub const border_color: u32 = 0x444444;
pub const border_focus_color: u32 = 0xBBBBBB;
pub const snap_px: u16 = 16;           // Floating window snap distance

pub const keys = [_]Key{
    // Window management
    key(.mod, .Return, spawn, .{&.{"st"}}),
    key(.mod, .p, spawn, .{&.{ "rofi", "-show", "run" }}),
    key(.mod, .j, focus_next, .{}),
    key(.mod, .k, focus_prev, .{}),
    key(.mod, .h, adjust_master_factor, .{-0.05}),
    key(.mod, .l, adjust_master_factor, .{0.05}),
    key(.mod_shift, .Return, zoom, .{}),        // Swap with master
    key(.mod_shift, .c, kill_client, .{}),
    key(.mod, .space, toggle_floating, .{}),
    key(.mod, .f, toggle_fullscreen, .{}),
    key(.mod, .i, adjust_master_count, .{1}),
    key(.mod, .d, adjust_master_count, .{-1}),

    // Monitor
    key(.mod, .comma, focus_monitor, .{-1}),
    key(.mod, .period, focus_monitor, .{1}),
    key(.mod_shift, .comma, send_to_monitor, .{-1}),
    key(.mod_shift, .period, send_to_monitor, .{1}),

    // Quit/restart
    key(.mod_shift, .q, quit, .{}),

    // Tags 1-9 generated at comptime
} ++ tag_keys();

/// Generates keybinds for tags 1-9.
/// num_key(0) returns keysym for "1", num_key(8) returns keysym for "9".
/// Tag index 0 = bitmask 1<<0 = key "1", tag index 8 = bitmask 1<<8 = key "9".
fn tag_keys() [18]Key {
    var k: [18]Key = undefined;
    for (0..9) |i| {
        k[i * 2] = key(.mod, num_key(i), view_tag, .{i});
        k[i * 2 + 1] = key(.mod_shift, num_key(i), tag_client, .{i});
    }
    return k;
}
```

The `key()` function and tag key generation are all resolved at comptime. Zero runtime cost, type-safe, compiler-checked.

`spawn` uses `fork` + `execvp` with an argv array (no shell). For commands needing shell features, pass `&.{ "sh", "-c", "command" }` explicitly.

## Event Loop

### Startup Sequence

```
1. Open xcb connection
2. Check for existing WM (SubstructureRedirect)
   → If taken, print error and exit
3. Query XRandR for monitors
4. Subscribe to XRandR screen change events
5. Grab configured key combinations
6. Scan for pre-existing windows (MapRequest replay)
7. Enter blocking event loop
```

### Event Handling

Single-threaded, blocking `xcb_wait_for_event` loop:

| Event | Handler |
|-------|---------|
| `MapRequest` | Add client to monitor's client list, assign current tags, re-tile |
| `UnmapNotify` | Remove client, re-tile |
| `DestroyNotify` | Remove client if tracked, re-tile |
| `KeyPress` | Look up in comptime key table, execute action |
| `EnterNotify` | Sloppy focus — focus window under cursor |
| `ConfigureRequest` | Floating: honor request. Tiling: send current geometry |
| `PropertyNotify` | Handle WM_HINTS, WM_NAME changes |
| `ButtonPress` | Start floating window move (`Mod+Button1`) or resize (`Mod+Button3`) |
| `ButtonRelease` | End move/resize grab |
| `MotionNotify` | Update floating window position/size during grab |
| `RandR ScreenChange` | Re-detect monitors, redistribute clients |

### Signal Handling

- `SIGCHLD`: set to `SIG_IGN` to automatically reap child processes (prevents zombie accumulation from spawned terminals/apps)
- `SIGTERM`, `SIGINT`: clean shutdown (ungrab keys, close xcb connection, exit)
- `SIGHUP`: restart (exec self)

## EWMH / ICCCM Support

Minimal but functional subset:

- `_NET_SUPPORTED` — advertise supported atoms
- `_NET_WM_STATE_FULLSCREEN` — fullscreen toggle
- `_NET_ACTIVE_WINDOW` — report focused window
- `_NET_WM_NAME` / `WM_NAME` — window titles (for status bar integration)
- `_NET_CURRENT_DESKTOP` — report active tag (for status bar)
- `_NET_NUMBER_OF_DESKTOPS` — report 9
- `WM_DELETE_WINDOW` — graceful window close via ICCCM
- `WM_PROTOCOLS` — protocol negotiation
- `WM_TAKE_FOCUS` — focus handling for clients that request it
- `_NET_WM_STRUT_PARTIAL` — reserve screen space for external bars

All atoms resolved manually via `xcb_intern_atom` at startup.

Enough for status bars (i3blocks, polybar) and well-behaved applications.

## Status Bar Integration

zwm does NOT include a built-in bar. Instead:

- Set `_NET_CURRENT_DESKTOP` and root window `WM_NAME` so external bars can read WM state
- Reserve screen space for bars via `_NET_WM_STRUT_PARTIAL` (bars request space, WM honors it)
- Works with: i3blocks, polybar, lemonbar, or any EWMH-aware bar

On HackberryPi, the existing i3blocks setup works unchanged.

## Floating Window Handling

Some windows should not be tiled:

- Windows with `WM_TRANSIENT_FOR` set (dialogs)
- Windows with fixed size hints (`WM_NORMAL_HINTS` min_size == max_size)
- Windows toggled floating via `Mod+Space`

Floating windows:
- Render above tiled windows
- Can be moved/resized with `Mod+Button1` (move) and `Mod+Button3` (resize)
- Snap to edges when within `snap_px` pixels

## Memory Management

- Use Zig's `GeneralPurposeAllocator` in debug, `c_allocator` in release
- Client structs allocated per-window, freed on unmap/destroy
- No dynamic config parsing, no string allocation for settings
- Total runtime memory: proportional to number of open windows only
- Expected RSS: <1MB for typical usage (well under HackberryPi's 4GB)

## Error Handling

- xcb connection errors: log and exit cleanly
- Individual event handler errors: log, skip event, continue loop
- Child process spawn failures: log, continue (don't crash WM because terminal failed to launch)
- No panics in release builds — all error paths handled explicitly

## Testing Strategy

- **layout.zig**: Unit tests for tiling calculations (pure functions, no xcb needed)
- **config.zig**: Comptime tests — invalid configs fail to compile
- **Integration**: Manual testing with `Xephyr` (nested X server) for development on desktop
- **On-device**: Direct testing on HackberryPi

```bash
# Development with Xephyr (720x720 to match HackberryPi)
Xephyr -br -ac -noreset -screen 720x720 :1 &
DISPLAY=:1 zig-out/bin/zwm
```

## Non-Goals

These are explicitly out of scope:

- **IPC socket** — no runtime control protocol (keep it simple)
- **Multiple layouts** — master+stack only for v1
- **Built-in bar** — use external bars
- **Wayland support** — HackberryPi has no DRM/KMS; revisit when hardware supports it
- **Window decorations** — borders only, no title bars
- **Session management** — not needed for this use case
- **Animations** — unnecessary overhead on constrained hardware
