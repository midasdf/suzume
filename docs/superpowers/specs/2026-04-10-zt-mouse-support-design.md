# zt Mouse Support Design Spec

## Overview

Add mouse support to zt terminal emulator for X11 and Wayland backends. Covers VT mouse tracking modes (applications like vim, tmux, htop) and terminal-native text selection with clipboard integration.

## Architecture

```
Backend (X11/Wayland)
  ↓ MouseEvent (pixel coords + button + modifiers)
Main (handleBackendEvent)
  ↓ pixel→cell conversion
  ├─ App captures mouse? → encode as VT sequence → PTY
  └─ No capture / Shift held? → terminal selection layer
```

### Four layers:

1. **Backend layer** — Platform-specific mouse event capture → unified `MouseEvent`
2. **Term layer** — Mouse mode state tracking (DECSET ?9/?1000/?1002/?1003/?1006)
3. **Main layer** — Dispatch logic: VT encoding or selection, coordinate conversion
4. **Selection layer** — Text selection state, rendering, clipboard copy

## 1. Backend Layer

### MouseEvent type (added to each backend's `Event` union)

```zig
pub const MouseEvent = struct {
    x: u32,          // pixel x
    y: u32,          // pixel y
    button: Button,
    action: Action,
    modifiers: input_mod.Modifiers, // reuse existing Modifiers struct

    pub const Button = enum(u3) {
        left = 0,
        middle = 1,
        right = 2,
        none = 3,       // no button held (motion without drag)
        wheel_up = 4,
        wheel_down = 5,
        wheel_left = 6,
        wheel_right = 7,
    };

    pub const Action = enum(u2) {
        press,
        release,
        motion,
    };
};
```

Event union addition:
```zig
pub const Event = union(enum) {
    key: KeyEvent,
    text: TextEvent,
    paste: PasteEvent,
    resize: ResizeEvent,
    mouse: MouseEvent,  // NEW
    expose: void,
    close: void,
    focus_in: void,
    focus_out: void,
};
```

### X11 backend changes (x11.zig)

In `pollEvents()` switch on `event_type`, add:

- `XCB_BUTTON_PRESS` — buttons 1-3 → press, buttons 4-7 → wheel events
- `XCB_BUTTON_RELEASE` — buttons 1-3 → release (ignore 4-7, wheel has no release)
- `XCB_MOTION_NOTIFY` — motion with button state from `event.state`

Must request these events in window creation. Add to event mask:
```
XCB_EVENT_MASK_BUTTON_PRESS | XCB_EVENT_MASK_BUTTON_RELEASE |
XCB_EVENT_MASK_POINTER_MOTION | XCB_EVENT_MASK_BUTTON_MOTION
```

Use `XCB_EVENT_MASK_BUTTON_MOTION` (motion only while button held) to avoid flooding with motion events when no mouse mode is active. Switch to `POINTER_MOTION` dynamically when ?1003 (any-event tracking) is enabled — this requires `xcb_change_window_attributes` to update the event mask at runtime.

### Wayland backend changes (wayland.zig)

`dispatchPointerEvent` already handles `ENTER` and `BUTTON` partially. Extend:

- `WL_POINTER_EVENT_BUTTON` — extract button + state, push MouseEvent to event queue
- `WL_POINTER_EVENT_MOTION` — extract x/y (wl_fixed_t → pixel), push MouseEvent
- `WL_POINTER_EVENT_AXIS` — wheel scroll (wl_fixed value, convert to discrete steps)

Track pointer position in struct fields (`pointer_x`, `pointer_y`) updated on every motion/enter, so button events can include position.

`WL_POINTER_EVENT_AXIS` (opcode 4) needs to be added to `seat.zig` — currently only ENTER(0), LEAVE(1), MOTION(2), BUTTON(3) are defined.

`WL_POINTER_EVENT_LEAVE` should clear any active selection drag state to avoid stuck selections.

Wayland button codes: BTN_LEFT=0x110, BTN_RIGHT=0x111, BTN_MIDDLE=0x112 (Linux input.h). Map to MouseEvent.Button.

## 2. Term Layer

### Mouse mode state (term.zig)

Add to `Term` struct:

```zig
// Mouse tracking modes (DECSET)
mouse_mode: MouseMode = .none,
mouse_encoding: MouseEncoding = .x10,

pub const MouseMode = enum(u3) {
    none = 0,
    x10 = 1,           // ?9: press only, no modifiers
    normal = 2,         // ?1000: press + release
    button = 3,         // ?1002: press + release + drag motion
    any = 4,            // ?1003: press + release + all motion
};

pub const MouseEncoding = enum(u2) {
    x10 = 0,           // Default: CSI M + 3 bytes (max 223 cols)
    utf8 = 1,          // ?1005: UTF-8 encoded coords
    sgr = 2,           // ?1006: CSI < Pb;Px;Py M/m (no limit)
    urxvt = 3,         // ?1015: CSI Pb;Px;Py M
};
```

### DECSET/DECRST handling (vt.zig)

Replace the current no-op line 1863 with actual state management:

```
9    → mouse_mode = .x10,     mouse_encoding = .x10
1000 → mouse_mode = .normal
1001 → (highlight, treat as .normal)
1002 → mouse_mode = .button
1003 → mouse_mode = .any
1005 → mouse_encoding = .utf8
1006 → mouse_encoding = .sgr
1015 → mouse_encoding = .urxvt
1016 → (SGR-pixel, treat as .sgr for now)
```

On DECRST: reset each mode individually. Mode resets (?9/?1000/?1002/?1003) only affect `mouse_mode`, NOT `mouse_encoding`. Encoding resets (?1005/?1006/?1015) only affect `mouse_encoding`. They are independent — an app can set ?1006 then ?1000 without losing SGR encoding.

XTSAVE/XTRESTORE (DECSET ?1s / ?1r): save/restore mouse_mode and mouse_encoding alongside existing saved_dec_modes.

## 3. Main Layer (main.zig)

### handleBackendEvent — new `.mouse` arm

```zig
.mouse => |mouse_ev| {
    refreshCursorBlinkOnUserInput(...);

    // Pixel → cell coordinate conversion
    const col: u32 = mouse_ev.x / config.cell_width;
    const row: u32 = mouse_ev.y / config.cell_height;

    // Clamp to terminal dimensions
    const cx = @min(col, term.cols -| 1);
    const cy = @min(row, term.rows -| 1);

    // Shift held → always terminal selection (bypass app mouse capture)
    if (mouse_ev.modifiers.shift) {
        handleTerminalSelection(term, mouse_ev, cx, cy, backend);
        return true;
    }

    // App captures mouse?
    if (term.mouse_mode != .none) {
        const seq = encodeMouseEvent(term, mouse_ev, cx, cy);
        if (seq.len > 0) {
            if (!ptyBufferedWrite(pty_ptr, seq.slice(), write_buf, write_pending, evloop_fd)) {
                return false;
            }
        }
    } else {
        // No app mouse mode → terminal selection
        handleTerminalSelection(term, mouse_ev, cx, cy, backend);
    }
},
```

### Button tracking

The main layer tracks which button is currently held for SGR release encoding:

```zig
var last_pressed_button: MouseEvent.Button = .none;
```

Updated on press (store button) and release (reset to `.none`). SGR mode requires the release sequence to report which button was released (0/1/2), not a generic release code.

### Backend contract for motion events

During motion events, `ev.button` reflects the button currently held (from X11 `event.state` / Wayland tracked state). If no button is held, `ev.button` is `.none`. This is how `.button` mode (?1002) distinguishes drag-motion (report) from free-motion (suppress).

### VT mouse sequence encoding

```zig
fn encodeMouseEvent(term: *const Term, ev: MouseEvent, cx: u32, cy: u32, last_btn: *MouseEvent.Button) EncodedMouse {
    // Filter events based on mouse mode
    switch (term.mouse_mode) {
        .none => return .{},
        .x10 => if (ev.action != .press) return .{},
        .normal => if (ev.action == .motion) return .{},
        .button => {
            // ?1002: report motion only while a button is held (drag)
            if (ev.action == .motion and ev.button == .none) return .{};
        },
        .any => {}, // report everything
    }

    // Track pressed button for SGR release encoding
    if (ev.action == .press) last_btn.* = ev.button;

    // Build button byte — for release, use last_pressed_button in SGR mode
    var btn: u8 = switch (ev.action) {
        .release => switch (term.mouse_encoding) {
            .sgr => switch (last_btn.*) {
                .left => 0,
                .middle => 1,
                .right => 2,
                else => 3,
            },
            else => 3, // X10/UTF-8/URXVT use generic release code
        },
        else => switch (ev.button) {
            .left => 0,
            .middle => 1,
            .right => 2,
            .none => 3,
            .wheel_up => 64,
            .wheel_down => 65,
            .wheel_left => 66,
            .wheel_right => 67,
        },
    };

    if (ev.action == .release) last_btn.* = .none;

    // Add modifier bits
    if (ev.modifiers.shift) btn |= 4;
    if (ev.modifiers.alt) btn |= 8;
    if (ev.modifiers.ctrl) btn |= 16;

    // Motion flag
    if (ev.action == .motion) btn |= 32;

    switch (term.mouse_encoding) {
        .sgr => {
            // CSI < Pb ; Px ; Py M  (press/motion)
            // CSI < Pb ; Px ; Py m  (release)
            // 1-based coordinates
            const suffix: u8 = if (ev.action == .release) 'm' else 'M';
            return formatSgr(btn, cx + 1, cy + 1, suffix);
        },
        .x10 => {
            // CSI M Cb Cx Cy  (all 1-based, +32 offset)
            // Max 223 columns (32+223=255)
            if (cx + 1 > 223 or cy + 1 > 223) return .{};
            return formatX10(btn + 32, @intCast(cx + 1 + 32), @intCast(cy + 1 + 32));
        },
        .utf8 => {
            // Like X10 but coords can be multi-byte UTF-8
            return formatUtf8(btn + 32, cx + 1 + 32, cy + 1 + 32);
        },
        .urxvt => {
            // CSI Pb ; Px ; Py M  (decimal, 1-based)
            return formatUrxvt(btn + 32, cx + 1, cy + 1);
        },
    }
}
```

`EncodedMouse` is a small fixed-buffer struct (max ~32 bytes) to avoid allocation.

## 4. Selection Layer

### Selection state (term.zig or new selection.zig)

Keep it in Term to access cell data directly:

```zig
// Text selection state
selection: ?Selection = null,

pub const Selection = struct {
    start_x: u32,
    start_y: u32,
    end_x: u32,
    end_y: u32,
    active: bool,  // currently dragging
};
```

### Selection logic (main.zig)

```
handleTerminalSelection(term, mouse_ev, cx, cy, backend):
  press left   → start new selection at (cx, cy), set active=true
  motion+active → update end to (cx, cy), mark dirty rows, trigger render
  release left  → finalize selection, copy to clipboard, set active=false
  press middle  → paste from clipboard (X11 primary selection)
  wheel         → if alt_screen: send arrow keys; else: scroll scrollback (future)
```

### Selection rendering

During render, cells within the selection range get inverted colors (swap fg/bg). This is a render-time check, no cell data modification needed:

```zig
// In render loop, for each cell:
if (term.selection) |sel| {
    if (cellInSelection(x, y, sel)) {
        // swap fg and bg for this cell
    }
}
```

### Clipboard integration

- **X11**: Use existing `xcb_set_selection_owner` + `XCB_SELECTION_REQUEST` handling for PRIMARY selection. Add CLIPBOARD support via Ctrl+C (or auto-copy on selection complete).
- **Wayland**: Use `wl_data_source` / `wl_data_device.set_selection` for clipboard. PRIMARY selection via `zwp_primary_selection_v1` if compositor supports it.

## Event Mask Management

For X11, mouse motion events can be noisy. Strategy:

- Default event mask includes `BUTTON_PRESS | BUTTON_RELEASE | BUTTON_MOTION` (motion only while dragging — needed for terminal selection)
- When ?1003 (any-event tracking) is set, add `POINTER_MOTION` via `xcb_change_window_attributes`
- When ?1003 is reset, remove `POINTER_MOTION`

This avoids unnecessary motion event processing when no app needs it.

For Wayland, pointer motion events are always delivered to the focused surface — no mask control needed. Filter in `dispatchPointerEvent` based on `mouse_mode`.

## Files Changed

| File | Changes |
|------|---------|
| `backend/x11.zig` | Add MouseEvent to Event union, handle XCB_BUTTON_PRESS/RELEASE/MOTION_NOTIFY in pollEvents, add motion event mask, event mask management |
| `backend/wayland.zig` | Complete dispatchPointerEvent (button/motion/axis), track pointer_x/pointer_y, push MouseEvent to event queue |
| `term.zig` | Add MouseMode, MouseEncoding, Selection structs and fields |
| `vt.zig` | Wire DECSET/DECRST ?9/?1000-?1006/?1015/?1016 to term.mouse_mode/mouse_encoding |
| `main.zig` | Add .mouse arm to handleBackendEvent, encodeMouseEvent, handleTerminalSelection, selection rendering in render loop |

## Out of Scope (for now)

- macOS and fbdev backends
- Scrollback scroll via wheel (no scrollback buffer exists yet)
- Double-click (word select) and triple-click (line select)
- URL detection/click
- SGR-pixel mode (?1016) with actual pixel coordinates
- Mouse shape changes (crosshair, pointer etc.)

## Testing

- Manual: run `vim`, `tmux`, `htop`, `mc` — verify click, scroll, drag selection work
- Manual: Shift+click to select text while vim has mouse enabled
- Manual: verify wheel scroll in tmux and less
- Verify SGR encoding with `cat -v` and `xxd` by printing mouse escape sequences
- Verify ?1003 motion tracking with `mouse-test` or similar tool
- Edge cases: click beyond terminal bounds, rapid scroll, wide characters in selection
