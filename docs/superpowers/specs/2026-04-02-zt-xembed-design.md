# zt XEmbed Support Design Spec

## Date
2026-04-02

## Goal
Add XEmbed protocol support to zt so it can be embedded into zz (and any other XEmbed-compliant container like suckless tabbed).

## Context
- zz (Zig code editor) embeds terminals via XEmbed: creates a child XCB window, passes its ID to the terminal via `-w <wid>`, and the terminal creates itself as a child of that window
- zt currently only creates top-level windows with `screen.root` as parent
- zz's `embedFlag()` returns `-w` by default for unknown terminals, so zt just needs to support `-w`

## Approach: Full XEmbed Protocol (Option B)
Implement the complete XEmbed client protocol, not just the minimal `-w` reparent. This ensures compatibility with both zz (which doesn't send XEmbed messages) and proper XEmbed embedders (tabbed, etc.).

---

## Section 1: Command-Line Arguments & Mode Switching

### Files Changed
- `src/main.zig` — arg parsing
- `src/backend/x11.zig` — `init()` signature

### Argument Format
```
zt                    # normal mode (top-level window)
zt -w 12345678        # embedded mode (child of window 12345678)
zt -w 12345678 -e sh  # embedded + command
```

### `X11Backend.init()` Signature Change
```
pub fn init() !Self  -->  pub fn init(embed_window: u32) !Self
```
- `embed_window == 0` — normal mode, use `screen.root` as parent
- `embed_window != 0` — embedded mode, use `embed_window` as parent

### `main.zig` Backend Switch Restructuring
The current code groups `.x11, .wayland, .macos` together. This must be split so `.x11` gets `embed_window`:
```zig
// Before:  .x11, .wayland, .macos => try Backend.init(),
// After:
.x11 => try Backend.init(embed_window),
.wayland, .macos => try Backend.init(),
```

### `-w` Parsing Order
`-w <wid>` must be parsed in the same `while` loop as `-e`, as an `else if` branch. Since `-e` consumes all remaining args and breaks, `-w` must appear before `-e` on the command line. The parser does not break on `-w` (it continues to find `-e`).

### Embedded Mode Differences at Init
- `xcb_create_window` parent: `screen.root` -> `embed_window`
- Initial size: query via `xcb_get_geometry(embed_window)` instead of 80x24 cells
- **Skip** `WM_NAME`, `WM_CLASS` (not needed for embedded windows)
- **Skip setting `WM_PROTOCOLS` property** but still intern `WM_DELETE_WINDOW` atom (keeps `wm_delete_atom` nonzero to avoid false matches against XEmbed ClientMessages with timestamp 0 in `data32[0]`)

### Other Backends
```zig
var backend = switch (config.backend) {
    .fbdev => try Backend.init(allocator),
    .x11 => try Backend.init(embed_window),
    .wayland, .macos => try Backend.init(),
};
```
`-w` is silently ignored for non-X11 backends.

---

## Section 2: XEmbed Protocol Implementation

### New Atoms
Interned in the batched `xcb_intern_atom` section of `init()` (alongside existing WM_PROTOCOLS, CLIPBOARD, etc.):
```
_XEMBED       — ClientMessage type for XEmbed messages
_XEMBED_INFO  — Window property (version + flags)
```
These atoms are interned unconditionally (both modes) to avoid blocking the event loop later. They are only **used** in embedded mode.

### `_XEMBED_INFO` Property
Set on window immediately after creation in embedded mode:
```
version: 0    (CARD32)
flags:   1    (CARD32)  — XEMBED_MAPPED (bit 0)
```

`XEMBED_MAPPED` is set from the start. Reason: embedders like zz that don't send XEmbed messages need the window to be visible immediately after `xcb_map_window`. Proper XEmbed embedders (tabbed) read this flag to decide whether to map.

### XEmbed Message Handling
Added to `CLIENT_MESSAGE` branch in `pollEvents()`.

**Dispatch logic**: XEmbed ClientMessages are identified by `msg.*.type == xembed_atom`. This is a different dispatch path from the existing `WM_DELETE_WINDOW` check (which has `type == WM_PROTOCOLS`, `data32[0] == WM_DELETE_WINDOW`). The handler checks `msg.*.type` first:
1. If `msg.*.type == xembed_atom` → XEmbed message, code is in `data32[1]`
2. Else if `msg.*.data.data32[0] == wm_delete_atom` → close (existing behavior)
3. Else → skip

**XEmbed ClientMessage wire format** (per freedesktop.org spec):
- `data32[0]` = timestamp (often 0)
- `data32[1]` = message code
- `data32[2]` = detail (varies by message)
- `data32[3]` = data1 (varies by message)
- `data32[4]` = data2 (varies by message)

| Message | Code (`data32[1]`) | zt Response |
|---------|-------------------|-------------|
| `XEMBED_EMBEDDED_NOTIFY` | 0 | Store embedder window (`data32[3]`) and protocol version (`data32[4]`), negotiate `min(0, embedder_version)` |
| `XEMBED_WINDOW_ACTIVATE` | 1 | Set `xembed_active = true` |
| `XEMBED_WINDOW_DEACTIVATE` | 2 | Set `xembed_active = false` |
| `XEMBED_FOCUS_IN` | 4 | Return `focus_in` event. Note: `data32[2]` contains focus direction (CURRENT=0, FIRST=1, LAST=2) — intentionally ignored since a terminal has no tab order |
| `XEMBED_FOCUS_OUT` | 5 | Return `focus_out` event |
| `XEMBED_MODALITY_ON` | 10 | No-op (terminal doesn't need modal control) |
| `XEMBED_MODALITY_OFF` | 11 | No-op |

### New Struct Fields
```zig
embed_parent: u32 = 0,            // 0 = top-level, non-0 = embedded
xembed_atom: xcb_atom_t = 0,      // _XEMBED
xembed_info_atom: xcb_atom_t = 0, // _XEMBED_INFO
embedder_window: u32 = 0,         // from EMBEDDED_NOTIFY
xembed_version: u32 = 0,          // negotiated protocol version
xembed_active: bool = false,      // WINDOW_ACTIVATE state
```

### Focus Management
In embedded mode, if zt needs to request focus (e.g., future mouse click support), it sends `XEMBED_REQUEST_FOCUS` (code 3) to `embedder_window`. Currently keyboard-only, so zt just receives focus from the embedder via `xcb_set_input_focus`. `XEMBED_REQUEST_FOCUS` implementation is deferred until mouse support is added.

---

## Section 3: Lifecycle Management

### Parent Window Destruction
Two detection paths:

1. **`DESTROY_NOTIFY`** — already returns `close` in current code
2. **XCB connection error** — check at top of `pollEvents()` unconditionally (both modes). A severed X connection should terminate in either case:
```zig
if (c.xcb_connection_has_error(self.connection) != 0) {
    return .close;
}
```

### Event Mask
Add `XCB_EVENT_MASK_FOCUS_CHANGE` unconditionally (both modes). Current code handles `FOCUS_IN`/`FOCUS_OUT` but doesn't request them in the event mask — works in normal mode because WMs send them anyway, but embedded mode needs explicit subscription.

```zig
const event_mask: u32 = c.XCB_EVENT_MASK_KEY_PRESS |
    c.XCB_EVENT_MASK_KEY_RELEASE |
    c.XCB_EVENT_MASK_STRUCTURE_NOTIFY |
    c.XCB_EVENT_MASK_EXPOSURE |
    c.XCB_EVENT_MASK_FOCUS_CHANGE;
```

### `deinit()`
No changes needed — destroys own window only (same as current).

---

## Section 4: SHM Buffer Initialization

### Initial Size in Embedded Mode
Query parent geometry instead of using fixed 80x24:

```zig
const width, const height = if (embed_parent != 0) blk: {
    const cookie = c.xcb_get_geometry(connection, embed_parent);
    const reply = c.xcb_get_geometry_reply(connection, cookie, null);
    if (reply) |r| {
        defer std.c.free(r);
        break :blk .{ @intCast(r.*.width), @intCast(r.*.height) };
    }
    break :blk .{ 80 * config.cell_width, 24 * config.cell_height };
} else .{ 80 * config.cell_width, 24 * config.cell_height };
```

Subsequent resizes handled normally via `ConfigureNotify` -> `resize()`.

---

## Section 5: Scope & Impact

### Files Changed (2 files)
| File | Changes |
|------|---------|
| `src/main.zig` | `-w <wid>` parsing, pass `embed_window` to `Backend.init()` |
| `src/backend/x11.zig` | `init(embed_window)` signature, XEmbed atoms/properties/messages, event mask, parent geometry query, connection error check |

### Not In Scope
- Wayland/macOS/fbdev embedding (XEmbed is X11-only)
- Mouse event handling (not implemented in zt, orthogonal to this change)
- `_NET_WM_*` EWMH properties (not needed for embedded or current normal mode)

### Testing
```bash
# 1. Regression: normal top-level mode
zig build -Dbackend=x11 -Doptimize=ReleaseFast
./zig-out/bin/zt

# 2. Embed into arbitrary window
WID=$(xdotool search --name "some_window")
./zig-out/bin/zt -w $WID

# 3. Embed into zz
ZZ_TERMINAL="./path/to/zt" zz
```
