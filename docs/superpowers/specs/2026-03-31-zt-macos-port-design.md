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

### Migration from boolean to 3-way enum

Current build.zig passes a boolean `use_x11` to config. This must change to support 3 backends.

**Before:**
```zig
const backend_opt = b.option([]const u8, "backend", "Rendering backend: fbdev or x11") orelse "fbdev";
const is_x11 = std.mem.eql(u8, backend_opt, "x11");
// ...
options.addOption(bool, "use_x11", is_x11);
```

**After:**
```zig
const backend_opt = b.option([]const u8, "backend", "Rendering backend: fbdev, x11, or macos") orelse "fbdev";
const shell_opt = b.option([]const u8, "shell", "Shell path (default: /bin/sh)") orelse "/bin/sh";

const is_x11 = std.mem.eql(u8, backend_opt, "x11");
const is_macos = std.mem.eql(u8, backend_opt, "macos");
options.addOption(bool, "use_x11", is_x11);
options.addOption(bool, "use_macos", is_macos);
options.addOption([]const u8, "shell", shell_opt);
```

### Linking

```zig
if (is_x11) {
    // existing xcb/xkb linking
} else if (is_macos) {
    exe.linkFramework("Cocoa");
    exe.linkFramework("QuartzCore");
    exe.linkLibC();  // Required for objc_msgSend, posix_openpt, grantpt, etc.
}
```

X11 libraries are NOT linked when backend=macos. libc is required for both Obj-C runtime and POSIX PTY functions.

**Note**: The `-Dshell=` default of `/bin/sh` changes behavior for Linux too (was hardcoded `/bin/fish`). This is intentional — users should specify their preferred shell explicitly via `-Dshell=`.

## 2. Config Changes (`config.zig`)

```zig
pub const Backend = enum { fbdev, x11, macos };
pub const backend: Backend = if (build_options.use_macos) .macos else if (build_options.use_x11) .x11 else .fbdev;
pub const shell: [:0]const u8 = build_options.shell;
```

`keymap` option remains fbdev-only (macOS handles keyboard layout via Cocoa).

## 3. PTY macOS Adaptation (`pty.zig`)

Comptime branching on `builtin.os.tag == .macos` for platform-divergent PTY operations.

### libc Dependency

`posix_openpt()`, `grantpt()`, `unlockpt()`, `ptsname()` are libc functions not exposed by Zig's `std.posix`. Access via `@cImport` or `extern` declarations:

```zig
const c = @cImport({
    @cInclude("stdlib.h");  // posix_openpt, grantpt, unlockpt, ptsname
});
```

This requires `linkLibC()` in build.zig, which is already done for the macOS backend.

### API Mapping

| Operation | Linux | macOS |
|-----------|-------|-------|
| Open master | `open("/dev/ptmx")` | `c.posix_openpt(O_RDWR \| O_NOCTTY)` |
| Unlock slave | `ioctl(TIOCSPTLCK, 0)` | `c.grantpt(fd)` + `c.unlockpt(fd)` |
| Get slave path | `ioctl(TIOCGPTN)` → `/dev/pts/{N}` | `c.ptsname(fd)` (returns `[*:0]const u8`) |
| Create session | `linux.syscall0(.setsid)` | `std.posix.setsid()` (POSIX, works on both — consider using on Linux too) |
| Set controlling tty | `ioctl(TIOCSCTTY)` — `0x540E` | `ioctl(TIOCSCTTY)` — `0x20007461` |
| Set window size | `ioctl(TIOCSWINSZ)` — `0x5414` | `ioctl(TIOCSWINSZ)` — `0x80087467` |
| Non-blocking flag | `O_NONBLOCK = 0x800` | Use `std.posix` constants (portable) |
| fcntl F_GETFL/F_SETFL | Hardcoded `3`/`4` | Use `std.posix` constants (portable) |

### ioctl on macOS

Linux uses `linux.ioctl()`. macOS needs `std.c.ioctl()` or an extern declaration since Darwin ioctl has a different signature. Comptime branch:

```zig
const is_macos = builtin.os.tag == .macos;
const TIOCSWINSZ = if (is_macos) 0x80087467 else 0x5414;
const TIOCSCTTY = if (is_macos) 0x20007461 else 0x540E;
// Call via std.c.ioctl on macOS, linux.ioctl on Linux
```

### Shared (POSIX)

`fork()`, `dup2()`, `execveZ()`, `execvpeZ()`, `close()`, `kill()`, `waitpid()` — identical on both platforms via `std.posix`.

### Environment Variables

macOS skips `DISPLAY`, `WAYLAND_DISPLAY`, `XAUTHORITY`, `DBUS_SESSION_BUS_ADDRESS` (not applicable). Other env vars (HOME, USER, LANG, PATH, TERM, COLORTERM, SHELL, COLUMNS, LINES) are shared.

## 4. Event Loop macOS Adaptation (`main.zig`)

Replace Linux epoll+signalfd+timerfd with macOS kqueue equivalents via comptime branching.

### Scope of Changes

The following functions and code paths in main.zig need comptime branches:

| Function / Code | Linux | macOS |
|----------------|-------|-------|
| `setupSignals()` | `sigemptyset/sigaddset/sigprocmask` + `signalfd4` syscall | `sigprocmask` (via `std.posix`) + kqueue `EVFILT_SIGNAL` registration |
| `createTimerFd()` | `timerfd_create` + `timerfd_settime` | Not needed — kqueue `EVFILT_TIMER` with `data=500`, `fflags=NOTE_MSECONDS` |
| `epollAdd()` | `epoll_ctl(CTL_ADD)` | `kevent(EV_ADD)` |
| `epollSetPtyEvents()` | `epoll_ctl(CTL_MOD)` with `EPOLL.OUT` | `kevent` with `EVFILT_WRITE` + `EV_ADD\|EV_ENABLE` / `EV_ADD\|EV_DISABLE` |
| `ptyBufferedWrite()` | Calls `epollSetPtyEvents(epoll_fd, ...)` | Calls kqueue equivalent (same parameter pattern, different implementation) |
| `ptyFlushPending()` | Same as above | Same as above |
| `handleSignal()` | Read `signalfd_siginfo` struct | Read from `kevent.ident` (signal number) |
| Main event loop | `epoll_wait()` → `epoll_event[]` | `kevent()` → `struct kevent[]` |
| Event dispatch | `ev.data.u32` tag switching | `ev.filter` + `ev.ident` switching |
| Timer acknowledge | `read(timer_fd)` to consume expiration | No-op (kqueue auto-acknowledges timer) |

### kqueue Signal Handling

`EVFILT_SIGNAL` requires the signal to be **blocked** via `sigprocmask` (or `pthread_sigmask`). Using `SIG_IGN` will prevent kqueue from receiving the signal. The existing `sigprocmask` call is portable via `std.posix.sigprocmask()`.

SIGUSR1/USR2 (VT switching) are not registered on macOS — fbdev-only feature.

### kqueue Timer

`EVFILT_TIMER` with `data=500` and `fflags=NOTE_MSECONDS` for 500ms cursor blink interval. No separate fd — the timer is registered directly on the kqueue with an ident (e.g., `ident=1` for blink timer). The existing Linux code uses `500_000_000` nanoseconds; the kqueue equivalent is either `data=500` + `NOTE_MSECONDS` or `data=500_000_000` + `NOTE_NSECONDS`.

### Cocoa Event Loop Integration

**Problem**: Unlike X11 (which provides an fd for epoll), Cocoa events are not fd-based. Naive polling with short kqueue timeouts wastes CPU when idle.

**Solution**: Self-pipe pattern.

1. Create a pipe: `pipe(fds)` → `read_fd`, `write_fd`
2. Register `read_fd` on kqueue with `EVFILT_READ`
3. In the macOS backend, when Cocoa delivers events (via `NSApp sendEvent:` from `drawRect:` or input callbacks), write a byte to `write_fd` to wake kqueue
4. On kqueue wakeup from `read_fd`, drain the pipe and call `backend.pollEvents()`

This way kqueue can block indefinitely (`timeout = -1`) when idle, just like epoll does on Linux. The pipe write adds negligible latency (~microseconds).

macOS backend `getFd()` returns the `read_fd` of a self-pipe, making it work exactly like X11's `getFd()` returning the xcb connection fd. NSView callbacks (`keyDown:`, `drawRect:`, etc.) write a byte to `write_fd` to wake kqueue. main.zig polls backend events on backend fd activity — identical pattern to X11.

**Self-pipe details**:
- Both `read_fd` and `write_fd` are set to `O_NONBLOCK`
- `write_fd` non-blocking prevents deadlock if pipe buffer is full
- Draining: single `read()` into a small buffer (e.g., 64 bytes); `WouldBlock` means drained
- For initial event delivery (before user interaction), `pollEvents()` calls `NSApp nextEventMatchingMask:untilDate:inMode:dequeue:` with `untilDate:nil` (non-blocking). A one-shot `dispatch_async` on the main queue triggers the first wakeup

### Dynamic Timeout (shared logic)

The `epoll_timeout` / kqueue timeout calculation is shared:
- `-1` (block forever) when no dirty state and no Cocoa events pending
- Short timeout when render is pending (frame rate limiting)

## 5. macOS Backend (`backend/macos.zig`)

New file. The largest piece of new code.

### Architecture

```
[render.zig pixel output] → [CGBitmapContext buffer (BGRA32)]
    → [NSView drawRect: creates CGImage from buffer]
    → [screen]
```

**Pixel format**: CGBitmapContext must be created with `kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst` to get BGRA32 layout matching render.zig's `.bgra32` format. Explicit byte order avoids host-endian ambiguity.

### Obj-C Runtime Integration

Zig calls Obj-C runtime directly via `@cImport`:

```zig
const objc = @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
});
```

**`objc_msgSend` variants** (important for x86_64):
- `objc_msgSend` — standard calls
- `objc_msgSend_fpret` — functions returning `f64`/`f80` (x86_64 only; not needed on ARM64)
- `objc_msgSend_stret` — functions returning large structs (x86_64 only; not needed on ARM64)

On ARM64 (Apple Silicon), all calls use `objc_msgSend`. Since zt targets both architectures, use comptime branching for return-type-specific variants on x86_64:

```zig
const msgSend_CGRect = if (builtin.cpu.arch == .x86_64) objc.objc_msgSend_stret else objc.objc_msgSend;
```

### Backend Interface Contract

Exact signatures matching existing backends (Zig comptime duck-typing requires all methods to exist):

```zig
pub const MacosBackend = struct {
    // Fields
    buffer: []u8,                         // Slice over CGBitmapContext data
    width: u32,
    height: u32,
    stride: u32,
    wakeup_read_fd: posix.fd_t,           // O_NONBLOCK
    wakeup_write_fd: posix.fd_t,          // O_NONBLOCK
    // ... Cocoa object pointers (opaque ids)

    pub fn init() !MacosBackend          // No allocator (CG manages buffer)
    pub fn deinit(self: *MacosBackend) void
    pub fn getBuffer(self: *MacosBackend) []u8   // Slice, matching X11/fbdev
    pub fn getStride(self: *MacosBackend) u32
    pub fn getWidth(self: *MacosBackend) u32
    pub fn getHeight(self: *MacosBackend) u32
    pub fn markDirtyRows(self: *MacosBackend, start: u32, end: u32) void
    pub fn present(self: *MacosBackend) void
    pub fn flush(self: *MacosBackend) void               // No-op
    pub fn getFd(self: *MacosBackend) ?posix.fd_t         // Returns wakeup_read_fd
    pub fn pollEvents(self: *MacosBackend) ?Event         // NSApp nextEvent polling
    pub fn resize(self: *MacosBackend, w: u32, h: u32) !void  // Reallocate CGBitmapContext
    pub fn queryGeometry(self: *MacosBackend) struct { w: u32, h: u32 }  // NSView frame
    pub fn saveConsoleState(self: *MacosBackend) !void     // No-op
    pub fn restoreConsoleState(self: *MacosBackend) void   // No-op
    pub fn setupVtSwitching(self: *MacosBackend) !void     // No-op
    pub fn releaseVt(self: *MacosBackend) void             // No-op
    pub fn acquireVt(self: *MacosBackend) void             // No-op
    pub fn postInit(self: *MacosBackend) void              // No-op (or Cocoa finalization)
};
```

`init()` takes no allocator (same as X11 backend). CGBitmapContext manages its own buffer. Return type is `!MacosBackend` (can fail on NSApplication/NSWindow creation).

### NSView Subclass

Created at runtime via `objc_allocateClassPair` / `class_addMethod` / `objc_registerClassPair`.

**Protocol conformance**: `class_addProtocol(cls, objc_getProtocol("NSTextInputClient"))` must be called before `objc_registerClassPair` for IME to work.

Methods:

| Method | Purpose |
|--------|---------|
| `drawRect:` | Create CGImage from CGBitmapContext data, draw to view |
| `keyDown:` | Extract keyCode + modifierFlags, convert to Event.key |
| `flagsChanged:` | Modifier key changes (Shift/Ctrl/Option/Cmd press/release) |
| `insertText:replacementRange:` | IME committed text → Event.text |
| `setMarkedText:selectedRange:replacementRange:` | Pre-edit (IME handles display) |
| `unmarkText` | Clear pre-edit state |
| `hasMarkedText` | Return whether pre-edit is active |
| `firstRectForCharacterRange:actualRange:` | Report cursor screen position for IME window placement |
| `validAttributesForMarkedText` | Return empty NSArray |
| `viewDidChangeBackingProperties` | Handle Retina display scale changes |
| `acceptsFirstResponder` | Return YES |
| `canBecomeKeyView` | Return YES |

### NSWindow Delegate

For window lifecycle events not delivered through NSView:

| Method | Purpose | Event Produced |
|--------|---------|---------------|
| `windowShouldClose:` | Window close button clicked | `Event.close` |
| `windowDidBecomeKey:` | Window gained focus | `Event.focus_in` |
| `windowDidResignKey:` | Window lost focus | `Event.focus_out` |
| `windowDidResize:` | Window resized (live) | `Event.resize` |
| `windowDidChangeOcclusionState:` | Window uncovered (use `NSWindowOcclusionStateVisible` check) | `Event.expose` |

The delegate is set on the NSWindow via `[window setDelegate:view]` (the NSView subclass also acts as delegate).

### Standard macOS Keyboard Shortcuts

| Shortcut | Behavior |
|----------|----------|
| `Cmd+V` | Read `NSPasteboard.generalPasteboard` → Event.paste |
| `Cmd+Q` | Produce `Event.close` (clean shutdown) |
| `Cmd+W` | Produce `Event.close` (same as Cmd+Q for single-window app) |

These are intercepted in `keyDown:` before standard key translation. All other Cmd+key combinations are ignored (not forwarded to PTY).

### Keyboard Input

`NSEvent.keyCode` (macOS virtual keycodes) → Linux evdev keycodes via a comptime translation table in `input.zig`. After translation, existing `input.translateKey()` works unchanged.

Modifier keys from `NSEvent.modifierFlags`:
- `NSEventModifierFlagShift` → `mod_state.shift`
- `NSEventModifierFlagControl` → `mod_state.ctrl`
- `NSEventModifierFlagOption` → `mod_state.alt`
- `NSEventModifierFlagCommand` → `mod_state.meta`

Modifier key press/release is detected via `flagsChanged:` (not `keyDown:`).

### IME Support (`NSTextInputClient`)

Methods added to the NSView subclass (protocol conformance registered via `class_addProtocol`):

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
- `Cmd+V` detected in `keyDown:` → read `stringForType:NSPasteboardTypeString` → produce `Event.paste`
- Same role as X11 `CLIPBOARD` atom handling

## 6. Input Changes (`input.zig`)

### macOS Keycode Translation Table

Comptime `[128]u16` array mapping macOS virtual keycodes (0x00–0x7E) to Linux evdev KEY_* constants:

```
macOS 0x00 (kVK_ANSI_A)     → KEY_A (30)
macOS 0x01 (kVK_ANSI_S)     → KEY_S (31)
macOS 0x24 (kVK_Return)     → KEY_ENTER (28)
macOS 0x33 (kVK_Delete)     → KEY_BACKSPACE (14)
macOS 0x35 (kVK_Escape)     → KEY_ESC (1)
macOS 0x7E (kVK_UpArrow)    → KEY_UP (103)
... (full 128-entry table, macOS keycodes max out at 0x7E)
```

Existing `translateKey()` function unchanged — it receives evdev keycodes regardless of platform.

## 7. main.zig Updates

### Backend Selection (2-way → 3-way)

**Before:**
```zig
const Backend = if (config.backend == .fbdev)
    @import("backend/fbdev.zig").FbdevBackend
else
    @import("backend/x11.zig").X11Backend;
```

**After:**
```zig
const Backend = switch (config.backend) {
    .fbdev => @import("backend/fbdev.zig").FbdevBackend,
    .x11 => @import("backend/x11.zig").X11Backend,
    .macos => @import("backend/macos.zig").MacosBackend,
};
```

### Event Type Import

The macOS backend must export `pub const Event` with the same union variants as `backend/x11.zig`'s Event (key, text, paste, resize, expose, focus_in, focus_out, close). The import becomes:

```zig
const BackendEvent = if (config.backend == .x11)
    @import("backend/x11.zig").Event
else if (config.backend == .macos)
    @import("backend/macos.zig").Event
else
    void;
```

The event dispatch block in the main loop changes from `if (config.backend == .x11)` to `if (config.backend == .x11 or config.backend == .macos)`.

### Allocator Selection

macOS links libc, so should use `c_allocator` like X11:

```zig
const allocator = if (builtin.mode == .Debug)
    gpa.allocator()
else if (config.backend == .x11 or config.backend == .macos)
    std.heap.c_allocator
else
    std.heap.page_allocator;
```

### Backend Init

```zig
var backend = switch (config.backend) {
    .fbdev => try Backend.init(allocator),
    .x11, .macos => try Backend.init(),
};
```

### postInit / queryGeometry

```zig
if (config.backend == .x11 or config.backend == .macos) {
    backend.postInit();
}
// ...
if (config.backend == .x11 or config.backend == .macos) {
    const actual = backend.queryGeometry();
    // ... same resize logic
}
```

## 8. Unchanged Files

| File | Reason |
|------|--------|
| `term.zig` | Pure cell grid / scroll logic, no OS APIs |
| `vt.zig` | Pure VT100 parser state machine |
| `render.zig` | Pure pixel rendering |
| `font.zig` | Font blob parsing |
| `backend/fbdev.zig` | Linux-only, not compiled on macOS |
| `backend/x11.zig` | Not compiled when backend=macos |

## 9. File Change Summary

| File | Change |
|------|--------|
| `build.zig` | Add backend=macos, `use_macos` bool, shell option, Framework linking |
| `config.zig` | Backend enum 3-way, shell from build option |
| `src/main.zig` | Backend switch 3-way, kqueue comptime branches for all event loop functions, signal/timer adaptation |
| `src/pty.zig` | `@cImport("stdlib.h")` for posix_openpt/grantpt/unlockpt/ptsname, ioctl constant branching, setsid portability |
| `src/input.zig` | macOS keycode → evdev `[128]u16` translation table |
| `src/backend/macos.zig` | **New file** — Cocoa backend (~500-700 lines estimated) |
| `README.md` | macOS build instructions + untested disclaimer |

## 10. Known Risks & Limitations

1. **Untested on real hardware** — Developer does not own a Mac. Implementation based on Apple docs + Zig cross-compilation. README will clearly state this.
2. **Obj-C runtime from Zig** — Well-established pattern (mach-objc, zig-objc) but verbose. Type safety relies on correct `objc_msgSend` call signatures. x86_64 needs `_fpret`/`_stret` variants for specific return types.
3. **Retina displays** — `NSView` backing scale factor may be 2x. `viewDidChangeBackingProperties` handles this, but pixel-perfect rendering needs testing.
4. **CGBitmapContext performance** — Should be fast enough (direct memory buffer, no GPU round-trip), but not benchmarked on macOS.
5. **Self-pipe wakeup latency** — Adds ~microseconds, negligible for terminal use.
6. **IME edge cases** — Complex IME interactions (e.g., Kotoeri, Google Japanese Input) may have quirks not covered by `NSTextInputClient` alone.
7. **Shell default change** — `-Dshell=` defaults to `/bin/sh`, changing Linux behavior from hardcoded `/bin/fish`. Users must specify `-Dshell=/bin/fish` explicitly.
