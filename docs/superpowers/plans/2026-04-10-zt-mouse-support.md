# zt Mouse Support Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add mouse support (VT tracking modes + terminal text selection) to zt for X11 and Wayland backends.

**Architecture:** Backend-specific mouse events are unified into a `MouseEvent` type, dispatched through the existing `handleBackendEvent` in main.zig. Term tracks mouse mode state set by DECSET sequences. Main layer either encodes mouse events as VT sequences for the PTY (when app captures mouse) or handles terminal-native text selection (when no app capture or Shift held).

**Tech Stack:** Zig, XCB (X11), Wayland protocol, existing zt backend abstraction

**Spec:** `docs/superpowers/specs/2026-04-10-zt-mouse-support-design.md`

---

## Chunk 1: Foundation (MouseEvent type + Term state)

### Task 1: Add MouseEvent type and mouse fields to Term

**Files:**
- Modify: `zt/src/backend/x11.zig:14-23` (Event union)
- Modify: `zt/src/backend/wayland.zig` (Event union — same structure)
- Modify: `zt/src/term.zig:177` (after focus_events field)
- Modify: `zt/src/vt.zig:1863` (DECSET mouse mode handling)
- Modify: `zt/src/main.zig:506-608` (handleBackendEvent)

- [ ] **Step 1: Add MouseEvent to X11 Event union**

In `zt/src/backend/x11.zig`, add the MouseEvent struct and variant to Event:

```zig
pub const MouseEvent = struct {
    x: u32, // pixel x
    y: u32, // pixel y
    button: Button,
    action: Action,
    modifiers: input_mod.Modifiers,

    pub const Button = enum(u3) {
        left = 0,
        middle = 1,
        right = 2,
        none = 3,
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

- [ ] **Step 2: Add same MouseEvent to Wayland Event union**

In `zt/src/backend/wayland.zig`, add the identical `MouseEvent` struct and `mouse` variant to its `Event` union. The struct definition is identical — both backends share the same type layout.

- [ ] **Step 3: Add mouse mode state to Term**

In `zt/src/term.zig`, after the `focus_events` field (line ~177), add:

```zig
// Mouse tracking modes (DECSET)
mouse_mode: MouseMode = .none,
mouse_encoding: MouseEncoding = .x10,

pub const MouseMode = enum(u3) {
    none = 0,
    x10 = 1,       // ?9: press only, no modifiers
    normal = 2,     // ?1000: press + release
    button = 3,     // ?1002: press + release + drag motion
    any = 4,        // ?1003: press + release + all motion
};

pub const MouseEncoding = enum(u2) {
    x10 = 0,       // CSI M + 3 bytes (max 223 cols)
    utf8 = 1,      // ?1005: UTF-8 coords
    sgr = 2,       // ?1006: CSI < Pb;Px;Py M/m
    urxvt = 3,     // ?1015: CSI Pb;Px;Py M
};
```

- [ ] **Step 4: Wire DECSET/DECRST to mouse mode state**

In `zt/src/vt.zig`, replace the no-op line 1863:
```zig
// Mouse tracking modes (accepted but not processed — no mouse support yet)
9, 1000, 1001, 1002, 1003, 1005, 1006, 1015, 1016 => {},
```

With:
```zig
9 => {
    term.mouse_mode = if (set) .x10 else .none;
    if (set) term.mouse_encoding = .x10;
},
1000 => term.mouse_mode = if (set) .normal else .none,
1001 => term.mouse_mode = if (set) .normal else .none, // highlight → treat as normal
1002 => term.mouse_mode = if (set) .button else .none,
1003 => term.mouse_mode = if (set) .any else .none,
1005 => term.mouse_encoding = if (set) .utf8 else .x10,
1006 => term.mouse_encoding = if (set) .sgr else .x10,
1015 => term.mouse_encoding = if (set) .urxvt else .x10,
1016 => term.mouse_encoding = if (set) .sgr else .x10, // SGR-pixel → treat as SGR
```

- [ ] **Step 5: Add stub .mouse arm to handleBackendEvent**

In `zt/src/main.zig`, in `handleBackendEvent` (line ~520 switch), add before `.close`:

```zig
.mouse => {
    // TODO: implement mouse dispatch
},
```

This is a compile-check stub — no logic yet.

- [ ] **Step 6: Build and verify compilation**

Run: `cd zt && zig build 2>&1 | head -20`
Expected: Clean compilation with no errors.

- [ ] **Step 7: Commit**

```bash
git add zt/src/backend/x11.zig zt/src/backend/wayland.zig zt/src/term.zig zt/src/vt.zig zt/src/main.zig
git commit -m "feat(zt): add MouseEvent type and mouse mode state tracking

Wire DECSET ?9/?1000-?1006/?1015/?1016 to term.mouse_mode/mouse_encoding.
Add MouseEvent struct to X11 and Wayland backend Event unions.
Stub mouse handler in main event dispatch."
```

---

## Chunk 2: X11 Mouse Events

### Task 2: Handle mouse events in X11 backend

**Files:**
- Modify: `zt/src/backend/x11.zig:155-159` (event mask)
- Modify: `zt/src/backend/x11.zig:935-1221` (pollEvents switch)

- [ ] **Step 1: Add mouse events to X11 event mask**

In `zt/src/backend/x11.zig`, change the event_mask (line ~155) to include mouse events:

```zig
const event_mask: u32 = c.XCB_EVENT_MASK_KEY_PRESS |
    c.XCB_EVENT_MASK_KEY_RELEASE |
    c.XCB_EVENT_MASK_STRUCTURE_NOTIFY |
    c.XCB_EVENT_MASK_EXPOSURE |
    c.XCB_EVENT_MASK_FOCUS_CHANGE |
    c.XCB_EVENT_MASK_BUTTON_PRESS |
    c.XCB_EVENT_MASK_BUTTON_RELEASE |
    c.XCB_EVENT_MASK_BUTTON_MOTION;  // motion only while button held
```

- [ ] **Step 2: Handle XCB_BUTTON_PRESS in pollEvents**

In the `switch (event_type)` block in `pollEvents`, add before the `else` branch (line ~1214):

```zig
c.XCB_BUTTON_PRESS => {
    const btn_ev: *c.xcb_button_press_event_t = @ptrCast(@alignCast(event));
    // Skip unknown buttons (> 7)
    if (btn_ev.*.detail == 0 or btn_ev.*.detail > 7) continue;
    const mods = xcbStateToMods(btn_ev.*.state);
    const button: MouseEvent.Button = switch (btn_ev.*.detail) {
        1 => .left,
        2 => .middle,
        3 => .right,
        4 => .wheel_up,
        5 => .wheel_down,
        6 => .wheel_left,
        7 => .wheel_right,
        else => unreachable,
    };
    return .{ .mouse = .{
        .x = @intCast(@max(0, btn_ev.*.event_x)),
        .y = @intCast(@max(0, btn_ev.*.event_y)),
        .button = button,
        .action = .press,
        .modifiers = mods,
    } };
},
```

- [ ] **Step 3: Handle XCB_BUTTON_RELEASE**

Add right after BUTTON_PRESS:

```zig
c.XCB_BUTTON_RELEASE => {
    const btn_ev: *c.xcb_button_release_event_t = @ptrCast(@alignCast(event));
    // Ignore wheel button releases (4-7)
    if (btn_ev.*.detail >= 4) continue;
    const mods = xcbStateToMods(btn_ev.*.state);
    const button: MouseEvent.Button = switch (btn_ev.*.detail) {
        1 => .left,
        2 => .middle,
        3 => .right,
        else => continue,
    };
    return .{ .mouse = .{
        .x = @intCast(@max(0, btn_ev.*.event_x)),
        .y = @intCast(@max(0, btn_ev.*.event_y)),
        .button = button,
        .action = .release,
        .modifiers = mods,
    } };
},
```

- [ ] **Step 4: Handle XCB_MOTION_NOTIFY**

Add right after BUTTON_RELEASE:

```zig
c.XCB_MOTION_NOTIFY => {
    const motion: *c.xcb_motion_notify_event_t = @ptrCast(@alignCast(event));
    const mods = xcbStateToMods(motion.*.state);
    // Determine which button is held from X11 state bits
    const button: MouseEvent.Button = if (motion.*.state & c.XCB_BUTTON_MASK_1 != 0)
        .left
    else if (motion.*.state & c.XCB_BUTTON_MASK_2 != 0)
        .middle
    else if (motion.*.state & c.XCB_BUTTON_MASK_3 != 0)
        .right
    else
        .none;
    return .{ .mouse = .{
        .x = @intCast(@max(0, motion.*.event_x)),
        .y = @intCast(@max(0, motion.*.event_y)),
        .button = button,
        .action = .motion,
        .modifiers = mods,
    } };
},
```

- [ ] **Step 5: Build and verify**

Run: `cd zt && zig build 2>&1 | head -20`
Expected: Clean compilation.

- [ ] **Step 6: Manual test — verify mouse events arrive**

Launch zt, add a temporary `std.log.info` in the `.mouse` stub in main.zig to print mouse events. Click/scroll in the terminal and check stderr output. Remove the debug log after verifying.

- [ ] **Step 7: Commit**

```bash
git add zt/src/backend/x11.zig
git commit -m "feat(zt): handle X11 mouse events (press/release/motion)

Add BUTTON_PRESS, BUTTON_RELEASE, MOTION_NOTIFY handlers to X11
pollEvents. Include mouse button/wheel events in window event mask."
```

---

## Chunk 3: Wayland Mouse Events

### Task 3: Handle mouse events in Wayland backend

**Files:**
- Modify: `zt/src/backend/wayland.zig:115-137` (add pointer_x/pointer_y fields)
- Modify: `zt/src/backend/wayland.zig:1111-1139` (dispatchPointerEvent)
- Modify: `zt/src/backend/wayland/seat.zig:41-47` (add AXIS opcode)

- [ ] **Step 1: Add pointer tracking fields and AXIS constant**

In `zt/src/backend/wayland.zig`, add after `pointer_serial` (line ~137):

```zig
pointer_x: u32 = 0, // last known pixel x
pointer_y: u32 = 0, // last known pixel y
```

In `zt/src/backend/wayland/seat.zig`, after `WL_POINTER_EVENT_BUTTON` (line ~44):

```zig
pub const WL_POINTER_EVENT_AXIS: u16 = 4;
pub const WL_POINTER_EVENT_FRAME: u16 = 5;
```

- [ ] **Step 2: Extend dispatchPointerEvent for BUTTON**

Replace the existing `WL_POINTER_EVENT_BUTTON` handler (lines 1131-1136):

```zig
seat_mod.WL_POINTER_EVENT_BUTTON => {
    // Payload: serial(u32) + time(u32) + button(u32) + state(u32)
    var pos: usize = 0;
    const serial = wire.getUint(payload, &pos);
    self.pointer_serial = serial;
    _ = wire.getUint(payload, &pos); // time
    const linux_button = wire.getUint(payload, &pos);
    const state = wire.getUint(payload, &pos);

    const button: Event.MouseEvent.Button = switch (linux_button) {
        0x110 => .left,   // BTN_LEFT
        0x111 => .right,  // BTN_RIGHT
        0x112 => .middle, // BTN_MIDDLE
        else => return,
    };
    const action: Event.MouseEvent.Action = if (state != 0) .press else .release;
    self.queueEvent(.{ .mouse = .{
        .x = self.pointer_x,
        .y = self.pointer_y,
        .button = button,
        .action = action,
        .modifiers = self.keyboard.getModifiers(),
    } });
},
```

Note: `self.keyboard.getModifiers()` — check if KeyboardState has a method to get current modifiers. If not, track modifier state from wl_keyboard events. This may need a helper function or field.

- [ ] **Step 3: Add MOTION handler**

In `dispatchPointerEvent`, add a case for MOTION:

```zig
seat_mod.WL_POINTER_EVENT_MOTION => {
    // Payload: time(u32) + x(fixed) + y(fixed)
    var pos: usize = 0;
    _ = wire.getUint(payload, &pos); // time
    const x_fixed: i32 = @bitCast(wire.getUint(payload, &pos));
    const y_fixed: i32 = @bitCast(wire.getUint(payload, &pos));
    // wl_fixed_t: signed 24.8 format — clamp negative to 0
    self.pointer_x = @intCast(@max(0, x_fixed >> 8));
    self.pointer_y = @intCast(@max(0, y_fixed >> 8));

    // Determine held button from last press (track in pointer state)
    self.queueEvent(.{ .mouse = .{
        .x = self.pointer_x,
        .y = self.pointer_y,
        .button = self.pointer_button,
        .action = .motion,
        .modifiers = self.keyboard.getModifiers(),
    } });
},
```

Add `pointer_button: Event.MouseEvent.Button = .none` field to track currently pressed button. Set on BUTTON press, reset on BUTTON release.

- [ ] **Step 4: Update ENTER to track position**

In the existing `WL_POINTER_EVENT_ENTER` handler, after extracting serial, add position tracking:

```zig
_ = wire.getUint(payload, &pos); // surface
const x_fixed = wire.getUint(payload, &pos);
const y_fixed = wire.getUint(payload, &pos);
self.pointer_x = x_fixed >> 8;
self.pointer_y = y_fixed >> 8;
```

- [ ] **Step 5: Add AXIS handler for wheel scroll**

```zig
seat_mod.WL_POINTER_EVENT_AXIS => {
    // Payload: time(u32) + axis(u32) + value(fixed)
    var pos: usize = 0;
    _ = wire.getUint(payload, &pos); // time
    const axis = wire.getUint(payload, &pos);
    const value_fixed: i32 = @bitCast(wire.getUint(payload, &pos));
    // axis 0 = vertical, 1 = horizontal
    // value > 0 = down/right, < 0 = up/left
    const button: Event.MouseEvent.Button = if (axis == 0)
        (if (value_fixed > 0) .wheel_down else .wheel_up)
    else
        (if (value_fixed > 0) .wheel_right else .wheel_left);
    self.queueEvent(.{ .mouse = .{
        .x = self.pointer_x,
        .y = self.pointer_y,
        .button = button,
        .action = .press,
        .modifiers = self.keyboard.getModifiers(),
    } });
},
```

Note: `wire.getUint` returns `u32`; the `@bitCast` to `i32` handles the signed wl_fixed_t axis value.

- [ ] **Step 6: Add LEAVE handler to clear drag state**

```zig
seat_mod.WL_POINTER_EVENT_LEAVE => {
    self.pointer_button = .none;
},
```

- [ ] **Step 7: Handle getModifiers for Wayland**

Check if `KeyboardState` in `seat.zig` tracks modifier state. If it has fields like `mods_depressed`, `mods_latched`, `mods_locked` from `wl_keyboard.modifiers` event, add a helper:

```zig
pub fn getModifiers(self: *const KeyboardState) input_mod.Modifiers {
    // Extract from XKB state if available, otherwise from cached mod values
    // This depends on existing keyboard implementation
}
```

If modifiers aren't tracked, add `current_modifiers: input_mod.Modifiers = .{}` to the Wayland struct and update it on `wl_keyboard.modifiers` events.

- [ ] **Step 8: Build and verify**

Run: `cd zt && zig build 2>&1 | head -20`
Expected: Clean compilation.

- [ ] **Step 9: Commit**

```bash
git add zt/src/backend/wayland.zig zt/src/backend/wayland/seat.zig
git commit -m "feat(zt): handle Wayland mouse events (button/motion/axis)

Complete dispatchPointerEvent with button press/release, pointer
motion tracking, and axis (wheel) events. Track pointer position
for button events. Add LEAVE handler to clear drag state."
```

---

## Chunk 4: VT Mouse Encoding + Main Dispatch

### Task 4: Implement mouse event encoding and dispatch in main.zig

**Files:**
- Modify: `zt/src/main.zig:506-608` (handleBackendEvent .mouse arm)

- [ ] **Step 1: Add EncodedMouse helper struct**

Add near the top of `main.zig` (after imports, before functions):

```zig
const EncodedMouse = struct {
    data: [32]u8 = undefined,
    len: u8 = 0,

    fn slice(self: *const EncodedMouse) []const u8 {
        return self.data[0..self.len];
    }
};
```

- [ ] **Step 2: Implement encodeMouseEvent function**

Add after `handleBackendEvent`:

```zig
fn encodeMouseEvent(term: *const Term, ev: BackendEvent.MouseEvent, cx: u32, cy: u32, last_btn: *BackendEvent.MouseEvent.Button) EncodedMouse {
    const MouseMode = Term.MouseMode;
    const MouseEncoding = Term.MouseEncoding;
    const MouseButton = BackendEvent.MouseEvent.Button;

    // Filter events based on mouse mode
    switch (term.mouse_mode) {
        .none => return .{},
        .x10 => {
            if (ev.action != .press) return .{};
        },
        .normal => {
            if (ev.action == .motion) return .{};
        },
        .button => {
            // ?1002: motion only while button held (drag)
            if (ev.action == .motion and ev.button == .none) return .{};
        },
        .any => {}, // report everything
    }

    // Track pressed button for SGR release
    if (ev.action == .press and ev.button != .none) {
        last_btn.* = ev.button;
    }

    // Build button byte
    var btn: u8 = switch (ev.action) {
        .release => switch (term.mouse_encoding) {
            .sgr => switch (last_btn.*) {
                .left => 0,
                .middle => 1,
                .right => 2,
                else => 3,
            },
            else => 3, // X10/UTF-8/URXVT: generic release
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

    if (ev.action == .release) {
        last_btn.* = .none;
    }

    // Modifier bits (not for X10 mode)
    if (term.mouse_mode != .x10) {
        if (ev.modifiers.shift) btn |= 4;
        if (ev.modifiers.alt) btn |= 8;
        if (ev.modifiers.ctrl) btn |= 16;
    }

    // Motion flag
    if (ev.action == .motion) btn |= 32;

    var result: EncodedMouse = .{};

    switch (term.mouse_encoding) {
        .sgr => {
            // CSI < Pb ; Px ; Py M/m
            const suffix: u8 = if (ev.action == .release) 'm' else 'M';
            result.len = @intCast(std.fmt.bufPrint(&result.data, "\x1b[<{d};{d};{d}{c}", .{
                btn, cx + 1, cy + 1, suffix,
            }) catch return .{}).len;
        },
        .x10 => {
            // CSI M Cb Cx Cy (max 223)
            if (cx + 1 > 223 or cy + 1 > 223) return .{};
            result.data[0] = 0x1b;
            result.data[1] = '[';
            result.data[2] = 'M';
            result.data[3] = btn + 32;
            result.data[4] = @intCast(cx + 1 + 32);
            result.data[5] = @intCast(cy + 1 + 32);
            result.len = 6;
        },
        .utf8 => {
            // Like X10 but coords encoded as UTF-8
            result.data[0] = 0x1b;
            result.data[1] = '[';
            result.data[2] = 'M';
            result.data[3] = btn + 32;
            var pos: u8 = 4;
            pos += encodeUtf8Coord(cx + 1 + 32, result.data[pos..]);
            pos += encodeUtf8Coord(cy + 1 + 32, result.data[pos..]);
            result.len = pos;
        },
        .urxvt => {
            // CSI Pb ; Px ; Py M
            result.len = @intCast(std.fmt.bufPrint(&result.data, "\x1b[{d};{d};{d}M", .{
                btn + 32, cx + 1, cy + 1,
            }) catch return .{}).len;
        },
    }
    return result;
}

fn encodeUtf8Coord(val: u32, buf: []u8) u8 {
    if (val < 0x80) {
        buf[0] = @intCast(val);
        return 1;
    } else if (val < 0x800) {
        buf[0] = @intCast(0xC0 | (val >> 6));
        buf[1] = @intCast(0x80 | (val & 0x3F));
        return 2;
    } else {
        buf[0] = @intCast(0xE0 | (val >> 12));
        buf[1] = @intCast(0x80 | ((val >> 6) & 0x3F));
        buf[2] = @intCast(0x80 | (val & 0x3F));
        return 3;
    }
}
```

- [ ] **Step 3: Implement .mouse dispatch in handleBackendEvent**

Replace the `.mouse => {}` stub.

Also add a local variable alongside the other state vars in main (near `cursor_visible_blink`, `cursor_blink_active`, etc.):

```zig
var last_pressed_button: BackendEvent.MouseEvent.Button = .none;
```

Then the `.mouse` arm:

```zig
.mouse => |mouse_ev| {
    refreshCursorBlinkOnUserInput(cursor_visible_blink, cursor_blink_active, last_input_ns);

    // Pixel → cell coordinate conversion
    const col: u32 = mouse_ev.x / config.cell_width;
    const row: u32 = mouse_ev.y / config.cell_height;
    const cx = @min(col, term.cols -| 1);
    const cy = @min(row, term.rows -| 1);

    // Shift held → terminal selection (bypass app mouse capture)
    if (mouse_ev.modifiers.shift) {
        // TODO: terminal selection (Task 6)
        return true;
    }

    // App captures mouse → encode VT sequence
    if (term.mouse_mode != .none) {
        const seq = encodeMouseEvent(term, mouse_ev, cx, cy, &last_pressed_button);
        if (seq.len > 0) {
            if (!ptyBufferedWrite(pty_ptr, seq.slice(), write_buf, write_pending, evloop_fd)) {
                return false;
            }
        }
    } else {
        // No app mouse mode → terminal selection
        // TODO: terminal selection (Task 6)
    }
},
```

- [ ] **Step 4: Build and verify**

Run: `cd zt && zig build 2>&1 | head -20`
Expected: Clean compilation.

- [ ] **Step 5: Manual test — verify VT encoding works**

Launch zt, run `vim` (which sets ?1006 SGR mode), click around. Verify vim responds to mouse clicks. Test with `tmux` as well (uses ?1002 button mode by default).

Quick encoding test: run `cat` in zt and click — raw escape sequences should appear.

- [ ] **Step 6: Commit**

```bash
git add zt/src/main.zig
git commit -m "feat(zt): implement VT mouse encoding and event dispatch

Support SGR (?1006), X10, UTF-8 (?1005), and URXVT (?1015) encodings.
All mouse modes: X10 (?9), Normal (?1000), Button (?1002), Any (?1003).
Track last pressed button for correct SGR release encoding."
```

---

## Chunk 5: Selection Layer

### Task 5: Add Selection state to Term

**Files:**
- Modify: `zt/src/term.zig` (add Selection struct and field)

- [ ] **Step 1: Add Selection struct and field to Term**

In `zt/src/term.zig`, after the mouse mode fields:

```zig
// Text selection state
selection: ?Selection = null,

pub const Selection = struct {
    start_x: u32,
    start_y: u32,
    end_x: u32,
    end_y: u32,
    active: bool, // currently dragging

    /// Returns ordered start/end (top-left to bottom-right)
    pub fn ordered(self: Selection) struct { sx: u32, sy: u32, ex: u32, ey: u32 } {
        if (self.start_y < self.end_y or (self.start_y == self.end_y and self.start_x <= self.end_x)) {
            return .{ .sx = self.start_x, .sy = self.start_y, .ex = self.end_x, .ey = self.end_y };
        } else {
            return .{ .sx = self.end_x, .sy = self.end_y, .ex = self.start_x, .ey = self.start_y };
        }
    }

    /// Check if a cell is within the selection range
    pub fn contains(self: Selection, x: u32, y: u32) bool {
        const o = self.ordered();
        if (y < o.sy or y > o.ey) return false;
        if (y == o.sy and y == o.ey) return x >= o.sx and x <= o.ex;
        if (y == o.sy) return x >= o.sx;
        if (y == o.ey) return x <= o.ex;
        return true; // middle row
    }
};
```

- [ ] **Step 2: Build and verify**

Run: `cd zt && zig build 2>&1 | head -20`

- [ ] **Step 3: Commit**

```bash
git add zt/src/term.zig
git commit -m "feat(zt): add Selection struct to Term for text selection state"
```

### Task 6: Implement terminal selection handling in main.zig

**Files:**
- Modify: `zt/src/main.zig` (handleTerminalSelection + selection rendering)

- [ ] **Step 1: Implement handleTerminalSelection**

Add after `encodeMouseEvent`:

```zig
fn handleTerminalSelection(term: *Term, ev: BackendEvent.MouseEvent, cx: u32, cy: u32) void {
    const MouseButton = BackendEvent.MouseEvent.Button;

    switch (ev.action) {
        .press => switch (ev.button) {
            .left => {
                // Start new selection
                term.selection = .{
                    .start_x = cx,
                    .start_y = cy,
                    .end_x = cx,
                    .end_y = cy,
                    .active = true,
                };
                // Mark screen dirty for selection highlight
                const total = @as(usize, term.cols) * @as(usize, term.rows);
                term.markDirtyRange(.{ .start = 0, .end = total });
            },
            .wheel_up, .wheel_down => {
                // When no app captures mouse and in alt screen,
                // translate wheel to arrow keys for less/man etc.
                // TODO: scrollback when implemented
            },
            else => {},
        },
        .motion => {
            if (term.selection) |*sel| {
                if (sel.active) {
                    sel.end_x = cx;
                    sel.end_y = cy;
                    // Mark dirty for selection update
                    const total = @as(usize, term.cols) * @as(usize, term.rows);
                    term.markDirtyRange(.{ .start = 0, .end = total });
                }
            }
        },
        .release => {
            if (ev.button == .left) {
                if (term.selection) |*sel| {
                    sel.active = false;
                    // If start == end, clear selection (was just a click)
                    if (sel.start_x == sel.end_x and sel.start_y == sel.end_y) {
                        term.selection = null;
                    }
                    // TODO: copy to clipboard (Task 7)
                }
                const total = @as(usize, term.cols) * @as(usize, term.rows);
                term.markDirtyRange(.{ .start = 0, .end = total });
            }
        },
    }
}
```

- [ ] **Step 2: Wire handleTerminalSelection into .mouse dispatch**

Replace the two `// TODO: terminal selection (Task 6)` comments in handleBackendEvent:

```zig
handleTerminalSelection(term, mouse_ev, cx, cy);
```

- [ ] **Step 3: Add selection rendering in the render loop**

In `main.zig`, in the render loop (around line ~1175), after cursor inversion and before `skip_bg`:

```zig
// Selection highlight: invert fg/bg
if (term.selection) |sel| {
    if (sel.contains(x, y)) {
        const tmp_idx = render_cell.fg;
        render_cell.fg = render_cell.bg;
        render_cell.bg = tmp_idx;
        const tmp_rgb = fg_rgb;
        fg_rgb = bg_rgb;
        bg_rgb = tmp_rgb;
    }
}
```

Place this AFTER the cursor inversion block (line ~1187) so selection and cursor are independent visual effects.

- [ ] **Step 4: Clear selection on terminal output**

When the terminal receives new output, clear selection to prevent stale highlights. In `main.zig`, where PTY data is read and fed to the VT parser, add:

```zig
// Clear selection when terminal content changes
if (term.selection != null) {
    term.selection = null;
    term.all_dirty = true;
}
```

Find where `vt.execute` or PTY read → VT parse happens and add this before/after.

- [ ] **Step 5: Build and verify**

Run: `cd zt && zig build 2>&1 | head -20`

- [ ] **Step 6: Manual test — verify selection**

Launch zt, drag mouse to select text. Verify:
- Selected text is highlighted (inverted colors)
- Selection clears when terminal receives new output
- Shift+click creates selection even in vim
- Single click (no drag) does not leave stale selection

- [ ] **Step 7: Commit**

```bash
git add zt/src/main.zig
git commit -m "feat(zt): implement terminal text selection with highlight

Left-click drag to select text, rendered with inverted fg/bg.
Selection auto-clears on new terminal output. Shift bypasses
app mouse capture for selection."
```

---

## Chunk 6: Clipboard Integration

### Task 7: Copy selection to clipboard

**Files:**
- Modify: `zt/src/main.zig` (extract selection text)
- Modify: `zt/src/backend/x11.zig` (clipboard set)
- Modify: `zt/src/backend/wayland.zig` (clipboard set)

- [ ] **Step 1: Add extractSelectionText to main.zig**

```zig
fn extractSelectionText(term: *const Term, buf: []u8) []const u8 {
    const sel = term.selection orelse return &.{};
    const o = sel.ordered();
    var pos: usize = 0;

    var y = o.sy;
    while (y <= o.ey) : (y += 1) {
        const start_x = if (y == o.sy) o.sx else 0;
        const end_x = if (y == o.ey) o.ex else term.cols - 1;

        const phys_row = term.row_map[y];
        const row_base = @as(usize, phys_row) * @as(usize, term.cols);
        const row_cells = term.cells[row_base..][0..term.cols];

        var x = start_x;
        while (x <= end_x) : (x += 1) {
            const ch = row_cells[x].char;
            if (ch == 0 or row_cells[x].attrs.wide_dummy) continue;
            // Encode codepoint as UTF-8
            const len = std.unicode.utf8Encode(ch, buf[pos..]) catch break;
            pos += len;
            if (pos + 4 >= buf.len) break;
        }
        // Add newline between rows (not after last)
        if (y < o.ey and pos + 1 < buf.len) {
            buf[pos] = '\n';
            pos += 1;
        }
    }
    return buf[0..pos];
}
```

- [ ] **Step 2: Add setClipboard to X11 backend**

Add a method to the X11 backend struct. X11 clipboard ownership is complex (requires responding to SelectionRequest events). Simplest approach: store the text and claim PRIMARY selection ownership, then handle XCB_SELECTION_REQUEST:

```zig
// In X11 struct, add fields:
selection_text: [16384]u8 = undefined,
selection_text_len: u32 = 0,

pub fn setClipboard(self: *Self, text: []const u8) void {
    const len = @min(text.len, self.selection_text.len);
    @memcpy(self.selection_text[0..len], text[0..len]);
    self.selection_text_len = @intCast(len);
    // Claim PRIMARY selection ownership
    _ = c.xcb_set_selection_owner(
        self.connection,
        self.window,
        c.XCB_ATOM_PRIMARY,
        c.XCB_CURRENT_TIME,
    );
    _ = c.xcb_flush(self.connection);
}
```

Then handle `XCB_SELECTION_REQUEST` in pollEvents to respond with the selection text when another app requests it.

- [ ] **Step 3: Add XCB_SELECTION_REQUEST handler**

In pollEvents switch, add:

```zig
c.XCB_SELECTION_REQUEST => {
    const req: *c.xcb_selection_request_event_t = @ptrCast(@alignCast(event));
    // Respond with our selection text
    if (self.selection_text_len > 0) {
        _ = c.xcb_change_property(
            self.connection,
            c.XCB_PROP_MODE_REPLACE,
            req.*.requestor,
            req.*.property,
            self.utf8_atom, // UTF8_STRING
            8,
            self.selection_text_len,
            &self.selection_text,
        );
    }
    // Send SelectionNotify response
    var notify: c.xcb_selection_notify_event_t = undefined;
    notify.response_type = c.XCB_SELECTION_NOTIFY;
    notify.requestor = req.*.requestor;
    notify.selection = req.*.selection;
    notify.target = req.*.target;
    notify.property = if (self.selection_text_len > 0) req.*.property else 0;
    notify.time = req.*.time;
    _ = c.xcb_send_event(self.connection, 0, req.*.requestor, 0, @ptrCast(&notify));
    _ = c.xcb_flush(self.connection);
    continue;
},
```

- [ ] **Step 4: Add setClipboard to Wayland backend**

Wayland clipboard is more complex (wl_data_source). For the initial version, store text and set up a data source when the clipboard module supports it. If the existing clipboard module already handles data source/offer for paste, extend it for copy.

```zig
pub fn setClipboard(self: *Self, text: []const u8) void {
    // Store selection text for later retrieval
    const len = @min(text.len, 16384);
    @memcpy(self.selection_text[0..len], text[0..len]);
    self.selection_text_len = @intCast(len);
    // TODO: create wl_data_source and set_selection
    // This requires the clipboard module to support copy (not just paste)
}
```

- [ ] **Step 5: Wire clipboard copy to selection release**

In `handleTerminalSelection`, when selection is finalized (release left button), add:

```zig
// Copy selection to clipboard
var clipboard_buf: [16384]u8 = undefined;
const text = extractSelectionText(term, &clipboard_buf);
if (text.len > 0) {
    backend.setClipboard(text);
}
```

- [ ] **Step 6: Build and verify**

Run: `cd zt && zig build 2>&1 | head -20`

- [ ] **Step 7: Manual test — verify clipboard**

Launch zt. Select text with mouse drag. Try pasting in another terminal/app. On X11: middle-click paste should work. On Wayland: clipboard may need the full data_source implementation — if it doesn't work in this pass, it's OK for MVP (X11 clipboard is the priority).

- [ ] **Step 8: Commit**

```bash
git add zt/src/main.zig zt/src/backend/x11.zig zt/src/backend/wayland.zig
git commit -m "feat(zt): copy selected text to clipboard

Extract selected text from terminal cells, set PRIMARY selection
on X11 with SelectionRequest handler. Wayland clipboard stub."
```

---

## Chunk 7: Event Mask Management + Polish

### Task 8: Dynamic X11 event mask for ?1003

**Files:**
- Modify: `zt/src/backend/x11.zig` (add setMouseMotionTracking method)
- Modify: `zt/src/vt.zig` or `zt/src/main.zig` (call on mode change)

- [ ] **Step 1: Add event mask update method to X11**

```zig
pub fn setMouseMotionTracking(self: *Self, enable: bool) void {
    var mask: u32 = c.XCB_EVENT_MASK_KEY_PRESS |
        c.XCB_EVENT_MASK_KEY_RELEASE |
        c.XCB_EVENT_MASK_STRUCTURE_NOTIFY |
        c.XCB_EVENT_MASK_EXPOSURE |
        c.XCB_EVENT_MASK_FOCUS_CHANGE |
        c.XCB_EVENT_MASK_BUTTON_PRESS |
        c.XCB_EVENT_MASK_BUTTON_RELEASE |
        c.XCB_EVENT_MASK_BUTTON_MOTION;
    if (enable) {
        mask |= c.XCB_EVENT_MASK_POINTER_MOTION;
    }
    const values = [_]u32{mask};
    _ = c.xcb_change_window_attributes(
        self.connection,
        self.window,
        c.XCB_CW_EVENT_MASK,
        &values,
    );
    _ = c.xcb_flush(self.connection);
}
```

- [ ] **Step 2: Call after VT execution in main event loop**

In `main.zig`, after the VT parser processes PTY data (where `vt.execute` is called), check if mouse_mode changed and update the X11 event mask. Add a `prev_mouse_mode` variable alongside other state:

```zig
var prev_mouse_mode: Term.MouseMode = .none;
```

After each VT execution pass:
```zig
if (term.mouse_mode != prev_mouse_mode) {
    backend.setMouseMotionTracking(term.mouse_mode == .any);
    prev_mouse_mode = term.mouse_mode;
}
```

For Wayland, `setMouseMotionTracking` is a no-op (motion events always delivered). Add the method stub to the Wayland backend:

```zig
pub fn setMouseMotionTracking(self: *Self, enable: bool) void {
    _ = self;
    _ = enable;
    // Wayland delivers pointer motion unconditionally — filter in dispatchPointerEvent
}
```

- [ ] **Step 3: Build, test, commit**

Run: `cd zt && zig build 2>&1 | head -20`

```bash
git add zt/src/backend/x11.zig zt/src/main.zig
git commit -m "feat(zt): dynamic X11 event mask for ?1003 any-event tracking"
```

### Task 9: Final integration test

- [ ] **Step 1: Test vim mouse support**

Launch zt → `vim` → `:set mouse=a` → click to position cursor, scroll with wheel, visual select with mouse drag.

- [ ] **Step 2: Test tmux mouse support**

Launch zt → `tmux` → `set -g mouse on` → click to switch panes, scroll in panes, resize panes by dragging borders.

- [ ] **Step 3: Test htop**

Launch zt → `htop` → click menu items, scroll process list.

- [ ] **Step 4: Test terminal selection**

Without any app mouse capture: drag to select text, verify clipboard copy works. With vim running: Shift+drag to force terminal selection.

- [ ] **Step 5: Test cat encoding output**

Run `cat` in zt, click/scroll — verify raw SGR escape sequences appear correctly:
- Click: `^[[<0;col;rowM`
- Release: `^[[<0;col;rowm`
- Wheel up: `^[[<64;col;rowM`

- [ ] **Step 6: Edge case tests**

- Click beyond terminal bounds (should clamp to last col/row)
- Rapid scrolling
- Wide characters in selection
- Switch between mouse-enabled app and shell (mode resets correctly)
