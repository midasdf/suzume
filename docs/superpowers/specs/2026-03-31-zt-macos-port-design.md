# zt macOS Port Design Spec

## Overview

Add macOS support to zt terminal emulator via a new Cocoa/AppKit backend (`-Dbackend=macos`), kqueue-based event loop, and POSIX PTY abstraction. The core rendering pipeline (term.zig, vt.zig, render.zig, font.zig) remains untouched.

**Constraint**: Developer does not own a Mac — this is a best-effort implementation based on Apple documentation and Zig's cross-compilation capabilities. README will note this.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Display backend | Cocoa/AppKit native (`objc_msgSend` from Zig) | Native experience, no XQuartz dependency |
| Backend selection | Explicit `-Dbackend=macos` (3-way enum) | Consistent with existing pattern |
| Shell path | Build option `-Dshell=` (default `/bin/sh`) | Lightweight, matches existing comptime options |
| OS abstraction | Comptime inline branching (`builtin.os.tag == .macos`) | Matches existing backend comptime pattern, minimal file additions |
| IME | Include in initial version via `NSTextInputClient` | Feature parity with X11 XIM support |

## 1. Build System (`build.zig`)

### New Options

```zig
const backend_opt = b.option([]const u8, "backend", "Rendering backend: fbdev, x11, or macos") orelse "fbdev";
const shell_opt = b.option([]const u8, "shell", "Shell path (default: /bin/sh)") orelse "/bin/sh";
```

### Linking (macOS backend)

```zig
if (is_macos) {
    exe.linkFramework("Cocoa");
    exe.linkFramework("QuartzCore");
    exe.linkLibC();
}
```

X11 libraries are NOT linked when backend=macos.

### Config Module

`shell` is passed through build options to `config.zig`, replacing the hardcoded `/bin/fish`.

## 2. Config Changes (`config.zig`)

```zig
pub const Backend = enum { fbdev, x11, macos };
pub const backend: Backend = // derived from build_options
pub const shell: [:0]const u8 = build_options.shell;
```

`keymap` option remains fbdev-only (macOS handles keyboard layout via Cocoa).

## 3. PTY macOS Adaptation (`pty.zig`)

Comptime branching on `builtin.os.tag == .macos` for platform-divergent PTY operations:

### API Mapping

| Operation | Linux | macOS |
|-----------|-------|-------|
| Open master | `open("/dev/ptmx")` | `posix_openpt(O_RDWR)` via libc |
| Unlock slave | `ioctl(TIOCSPTLCK, 0)` | `grantpt()` + `unlockpt()` via libc |
| Get slave path | `ioctl(TIOCGPTN)` → `/dev/pts/{N}` | `ptsname()` via libc |
| Create session | `syscall0(.setsid)` | `setsid()` via libc (POSIX) |
| Set controlling tty | `ioctl(TIOCSCTTY, 0)` — value `0x540E` | `ioctl(TIOCSCTTY, 0)` — value `0x20007461` |
| Set window size | `ioctl(TIOCSWINSZ)` — value `0x5414` | `ioctl(TIOCSWINSZ)` — value `0x80087467` |
| Non-blocking flag | `O_NONBLOCK = 0x800` | `O_NONBLOCK = 0x0004` |

### Shared (POSIX)

`fork()`, `dup2()`, `execveZ()`, `execvpeZ()`, `close()`, `fcntl()` — identical on both platforms via `std.posix`.

### Environment Variables

macOS skips `DISPLAY`, `WAYLAND_DISPLAY`, `XAUTHORITY`, `DBUS_SESSION_BUS_ADDRESS` (not applicable). Other env vars (HOME, USER, LANG, PATH, TERM, COLORTERM, SHELL, COLUMNS, LINES) are shared.

## 4. Event Loop macOS Adaptation (`main.zig`)

Replace Linux epoll+signalfd+timerfd with macOS kqueue equivalents via comptime branching.

### API Mapping

| Linux | macOS kqueue | Purpose |
|-------|-------------|---------|
| `epoll_create1()` | `kqueue()` | Create event loop |
| `epoll_ctl(CTL_ADD)` | `kevent(EV_ADD)` | Register fd |
| `epoll_ctl(CTL_MOD)` | `kevent(EV_ADD\|EV_ENABLE/DISABLE)` | Modify watched events |
| `epoll_wait()` | `kevent()` with timeout | Wait for events |
| `signalfd` + read | `EVFILT_SIGNAL` | Signal delivery as events |
| `timerfd_create` + read | `EVFILT_TIMER` + `NOTE_MSECONDS` | Cursor blink timer (500ms) |

### Key Differences

- **No timerfd needed**: kqueue's `EVFILT_TIMER` registers directly on the kqueue, no separate fd.
- **No signalfd needed**: `EVFILT_SIGNAL` delivers signals as kqueue events. `sigprocmask` still required to block default handlers.
- **Event identification**: `epoll_event.data.u32` tag → `kevent.ident` + `kevent.filter` for identification.
- **SIGUSR1/USR2 (VT switching)**: Not registered on macOS — fbdev-only feature.

### Event Loop Structure

The `while (running)` loop structure is identical. Only the syscalls for waiting and dispatching change. PTY read/write, rendering, frame rate limiting, dirty tracking — all shared.

### macOS Backend Event Integration

Unlike X11 (which provides an fd for epoll), Cocoa events are not fd-based. Strategy:
- kqueue timeout is short (1-2ms) when input is expected
- On each kqueue timeout/wakeup, poll `NSApp nextEventMatchingMask:untilDate:inMode:dequeue:`
- PTY and timer events still arrive via kqueue with zero additional latency

## 5. macOS Backend (`backend/macos.zig`)

New file. The largest piece of new code.

### Architecture

```
[render.zig pixel output] → [CGBitmapContext buffer (BGRA32)]
    → [NSView drawRect: creates CGImage from buffer]
    → [screen]
```

### Obj-C Runtime Integration

Zig calls Obj-C runtime directly via `@cImport`:

```zig
const objc = @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
});
```

Pattern: `objc_msgSend(target, sel_registerName("methodName"), args...)` for all Cocoa API calls.

### Public Interface

Matches existing fbdev/x11 backends:

| Method | Implementation |
|--------|---------------|
| `init()` | Create NSApplication, NSWindow, NSView subclass, allocate CGBitmapContext |
| `deinit()` | Release Cocoa objects, free buffer |
| `getBuffer()` | Return `CGBitmapContextGetData()` pointer |
| `getStride()` | `CGBitmapContextGetBytesPerRow()` |
| `getWidth()` / `getHeight()` | Window content view bounds |
| `markDirtyRows(start, end)` | Track dirty region for partial redraw |
| `present()` | `[view setNeedsDisplay:YES]` |
| `flush()` | No-op (event polling handled separately) |
| `getFd()` | Returns `null` (Cocoa is not fd-based) |
| `pollEvents()` | `NSApp nextEventMatchingMask:` → return Event union |
| `resize(w, h)` | Reallocate CGBitmapContext with new dimensions |
| `saveConsoleState()` | No-op |
| `restoreConsoleState()` | No-op |
| `setupVtSwitching()` | No-op |
| `releaseVt()` / `acquireVt()` | No-op |

### NSView Subclass

Created at runtime via `objc_allocateClassPair` / `class_addMethod` / `objc_registerClassPair`:

- `drawRect:` — Create CGImage from CGBitmapContext data, draw to view
- `keyDown:` — Extract keyCode + modifierFlags, convert to Event.key
- `insertText:replacementRange:` — IME committed text → Event.text
- `setMarkedText:selectedRange:replacementRange:` — Pre-edit (IME handles display)
- `firstRectForCharacterRange:actualRange:` — Report cursor screen position for IME window placement
- `viewDidChangeBackingProperties` — Handle Retina display scale changes
- `acceptsFirstResponder` — Return YES
- `canBecomeKeyView` — Return YES

### Keyboard Input

`NSEvent.keyCode` (macOS virtual keycodes) → Linux evdev keycodes via a comptime `[256]u16` translation table in `input.zig`. After translation, existing `input.translateKey()` works unchanged.

Modifier keys from `NSEvent.modifierFlags`:
- `NSEventModifierFlagShift` → `mod_state.shift`
- `NSEventModifierFlagControl` → `mod_state.ctrl`
- `NSEventModifierFlagOption` → `mod_state.alt`
- `NSEventModifierFlagCommand` → `mod_state.meta`

### IME Support (`NSTextInputClient`)

Methods added to the NSView subclass:

| Protocol Method | Behavior |
|----------------|----------|
| `insertText:replacementRange:` | Committed text → write UTF-8 to PTY (same as X11 XIM commit) |
| `setMarkedText:selectedRange:replacementRange:` | Store pre-edit state (IME draws its own candidate window) |
| `unmarkText` | Clear pre-edit state |
| `hasMarkedText` | Return whether pre-edit is active |
| `firstRectForCharacterRange:actualRange:` | Return cursor pixel rect in screen coordinates for IME popup positioning |
| `validAttributesForMarkedText` | Return empty NSArray |

### Clipboard

`NSPasteboard.generalPasteboard`:
- `Cmd+V` detected in keyDown → read `stringForType:NSPasteboardTypeString` → write to PTY as Event.paste
- Same role as X11 `CLIPBOARD` atom handling

## 6. Input Changes (`input.zig`)

### macOS Keycode Translation Table

Comptime `[256]u16` array mapping macOS virtual keycodes to Linux evdev KEY_* constants:

```
macOS 0x00 (kVK_ANSI_A)     → KEY_A (30)
macOS 0x01 (kVK_ANSI_S)     → KEY_S (31)
macOS 0x24 (kVK_Return)     → KEY_ENTER (28)
macOS 0x33 (kVK_Delete)     → KEY_BACKSPACE (14)
macOS 0x35 (kVK_Escape)     → KEY_ESC (1)
macOS 0x7E (kVK_UpArrow)    → KEY_UP (103)
... (full 128-entry table)
```

Existing `translateKey()` function unchanged — it receives evdev keycodes regardless of platform.

## 7. Unchanged Files

| File | Reason |
|------|--------|
| `term.zig` | Pure cell grid / scroll logic, no OS APIs |
| `vt.zig` | Pure VT100 parser state machine |
| `render.zig` | Pure pixel rendering |
| `font.zig` | Font blob parsing |
| `backend/fbdev.zig` | Linux-only, not compiled on macOS |
| `backend/x11.zig` | Not compiled when backend=macos |

## 8. File Change Summary

| File | Change |
|------|--------|
| `build.zig` | Add backend=macos, shell option, Framework linking |
| `config.zig` | Backend enum + shell from build option |
| `src/main.zig` | kqueue comptime branch, Backend switch, signal/timer adaptation |
| `src/pty.zig` | posix_openpt/grantpt/unlockpt/ptsname, ioctl constant branching |
| `src/input.zig` | macOS keycode → evdev translation table |
| `src/backend/macos.zig` | **New file** — Cocoa backend |
| `README.md` | macOS build instructions + untested disclaimer |

## 9. Known Risks & Limitations

1. **Untested on real hardware** — Developer does not own a Mac. Implementation based on Apple docs + Zig cross-compilation. README will clearly state this.
2. **Obj-C runtime from Zig** — Well-established pattern (mach-objc, zig-objc) but verbose. Type safety relies on correct `objc_msgSend` call signatures.
3. **Retina displays** — `NSView` backing scale factor may be 2x. `viewDidChangeBackingProperties` handles this, but pixel-perfect rendering needs testing.
4. **CGBitmapContext performance** — Should be fast enough (direct memory buffer, no GPU round-trip), but not benchmarked on macOS.
5. **kqueue + Cocoa event loop integration** — Polling NSApp events on kqueue timeout adds up to 1-2ms latency for keyboard input. Acceptable for a terminal emulator.
6. **IME edge cases** — Complex IME interactions (e.g., Kotoeri, Google Japanese Input) may have quirks not covered by `NSTextInputClient` alone.
