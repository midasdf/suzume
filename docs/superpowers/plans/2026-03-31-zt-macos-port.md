# zt macOS Port Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add macOS support to zt via Cocoa/AppKit backend, kqueue event loop, and POSIX PTY abstraction.

**Architecture:** Comptime inline branching (`builtin.os.tag == .macos` / `config.backend == .macos`) in existing files, plus one new file `src/backend/macos.zig`. Core rendering pipeline untouched.

**Tech Stack:** Zig 0.15, Cocoa/AppKit via `objc_msgSend`, kqueue, CGBitmapContext

**Testing constraint:** Developer does not own a Mac. Linux-side changes verified by building with `-Dbackend=x11` and running existing tests. macOS backend code (`backend/macos.zig`) is behind comptime switches and cannot be compiled/tested on Linux — only syntactic/structural correctness is ensured.

**Spec:** `docs/superpowers/specs/2026-03-31-zt-macos-port-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `build.zig` | Modify | Add `backend=macos`, `-Dshell=`, macOS Framework linking |
| `config.zig` | Modify | 3-way Backend enum, shell from build option |
| `src/pty.zig` | Modify | macOS PTY: posix_openpt/grantpt/unlockpt/ptsname, ioctl constants |
| `src/input.zig` | Modify | macOS keycode → evdev translation table |
| `src/main.zig` | Modify | 3-way backend switch, kqueue event loop, allocator selection |
| `src/backend/macos.zig` | Create | Cocoa backend: NSWindow, NSView, CGBitmapContext, IME |
| `README.md` | Modify | Add macOS build instructions + untested disclaimer to existing README |

---

## Chunk 1: Build System + Config

### Task 1: Add `-Dshell=` build option and update config

**Files:**
- Modify: `build.zig:7-22` (options block)
- Modify: `config.zig:39` (shell constant)

- [ ] **Step 1: Add shell option to build.zig**

In `build.zig`, after the existing `pty_buf_kb` option (line 15), add:

```zig
const shell_opt = b.option([]const u8, "shell", "Shell path (default: /bin/sh)") orelse "/bin/sh";
```

And in the options block (after line 22):

```zig
options.addOption([]const u8, "shell", shell_opt);
```

- [ ] **Step 2: Update config.zig to use shell build option**

Replace line 39 (`pub const shell = "/bin/fish";`) with:

```zig
pub const shell: [:0]const u8 = build_options.shell;
```

- [ ] **Step 3: Verify Linux build still works**

Run: `cd ~/zt && zig build -Dbackend=x11 -Dshell=/bin/fish`
Expected: Builds successfully (same behavior as before)

Run: `cd ~/zt && zig build -Dbackend=x11`
Expected: Builds with default shell `/bin/sh`

- [ ] **Step 4: Run existing tests**

Run: `cd ~/zt && zig build test -Dbackend=x11 -Dshell=/bin/echo`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
cd ~/zt && git add build.zig config.zig
git commit -m "Add -Dshell= build option, replace hardcoded /bin/fish"
```

### Task 2: Add `backend=macos` to build system and config

**Files:**
- Modify: `build.zig:7-54` (backend option, linking)
- Modify: `config.zig:3-8` (Backend enum)

- [ ] **Step 1: Add macos backend option to build.zig**

Change line 7 description:
```zig
const backend_opt = b.option([]const u8, "backend", "Rendering backend: fbdev, x11, or macos") orelse "fbdev";
```

After `const is_x11 = ...` (line 8), add:
```zig
const is_macos = std.mem.eql(u8, backend_opt, "macos");
```

In options block, after `options.addOption(bool, "use_x11", is_x11);` (line 18), add:
```zig
options.addOption(bool, "use_macos", is_macos);
```

- [ ] **Step 2: Add macOS Framework linking**

Change the linking block (lines 45-54) from:

```zig
if (std.mem.eql(u8, backend_opt, "x11")) {
    exe.linkSystemLibrary("xcb");
    // ... existing xcb libs ...
    exe.linkLibC();
}
```

To:

```zig
if (is_x11) {
    exe.linkSystemLibrary("xcb");
    exe.linkSystemLibrary("xcb-shm");
    exe.linkSystemLibrary("xcb-xkb");
    exe.linkSystemLibrary("xcb-imdkit");
    exe.linkSystemLibrary("xcb-util");
    exe.linkSystemLibrary("xkbcommon");
    exe.linkSystemLibrary("xkbcommon-x11");
    exe.linkLibC();
} else if (is_macos) {
    exe.linkFramework("Cocoa");
    exe.linkFramework("QuartzCore");
    exe.linkLibC();
}
```

- [ ] **Step 3: Update config.zig Backend enum**

Change the Backend enum and derivation:

```zig
pub const Backend = enum {
    fbdev,
    x11,
    macos,
};

pub const backend: Backend = if (build_options.use_macos) .macos else if (build_options.use_x11) .x11 else .fbdev;
```

- [ ] **Step 4: Verify existing backends still work**

Run: `cd ~/zt && zig build -Dbackend=x11 -Dshell=/bin/fish`
Expected: Builds successfully

Run: `cd ~/zt && zig build -Dbackend=fbdev -Dshell=/bin/fish`
Expected: Builds successfully

Run: `cd ~/zt && zig build test -Dbackend=x11 -Dshell=/bin/echo`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
cd ~/zt && git add build.zig config.zig
git commit -m "Add backend=macos option to build system and config"
```

---

## Chunk 2: PTY macOS Adaptation

### Task 3: Add macOS comptime branches to pty.zig

**Files:**
- Modify: `src/pty.zig` (throughout)

- [ ] **Step 1: Add builtin import and OS-conditional constants**

At the top of `pty.zig`, after the existing imports (lines 1-4), add:

```zig
const builtin = @import("builtin");
const is_macos = builtin.os.tag == .macos;
```

Add libc import for macOS PTY functions (after existing imports):

```zig
const c = if (is_macos) @cImport({
    @cInclude("stdlib.h");
    @cInclude("util.h"); // macOS openpty/forkpty
}) else struct {};
```

Change the ioctl constants (lines 6-10) to comptime-conditional:

```zig
const TIOCSPTLCK: u32 = 0x40045431; // Linux only
const TIOCGPTN: u32 = 0x80045430;   // Linux only
const TIOCSCTTY: u32 = if (is_macos) 0x20007461 else 0x540E;
const TIOCSWINSZ: u32 = if (is_macos) 0x80087467 else 0x5414;
```

- [ ] **Step 2: Add macOS PTY open/unlock/slave-path logic**

In the `spawn` function, replace the master open + unlock + slave path logic (lines 25-56) with comptime-branched version:

```zig
// 1. Open master
const master_fd = if (is_macos) blk: {
    const fd = c.posix_openpt(std.posix.O.RDWR | std.posix.O.NOCTTY);
    if (fd < 0) return error.PosixOpenPtFailed;
    break :blk @as(posix.fd_t, fd);
} else blk: {
    break :blk try posix.open(
        "/dev/ptmx",
        .{ .ACCMODE = .RDWR, .NOCTTY = true },
        0,
    );
};
errdefer posix.close(master_fd);

// 2. Unlock slave
if (is_macos) {
    if (c.grantpt(master_fd) < 0) return error.GrantPtFailed;
    if (c.unlockpt(master_fd) < 0) return error.UnlockPtFailed;
} else {
    var unlock: c_int = 0;
    const unlock_rc = linux.ioctl(
        @intCast(master_fd),
        TIOCSPTLCK,
        @intFromPtr(&unlock),
    );
    if (@as(isize, @bitCast(unlock_rc)) < 0) return error.IoctlFailed;
}

// 3. Get slave path
var slave_path_buf: [32]u8 = undefined;
const slave_path: [:0]const u8 = if (is_macos) blk: {
    const raw = c.ptsname(master_fd) orelse return error.PtsnameFailed;
    break :blk std.mem.span(raw);
} else blk: {
    var pty_num: c_int = undefined;
    const ptn_rc = linux.ioctl(
        @intCast(master_fd),
        TIOCGPTN,
        @intFromPtr(&pty_num),
    );
    if (@as(isize, @bitCast(ptn_rc)) < 0) return error.IoctlFailed;
    break :blk std.fmt.bufPrintZ(
        &slave_path_buf,
        "/dev/pts/{d}",
        .{pty_num},
    ) catch return error.PathTooLong;
};
```

- [ ] **Step 3: Update child process setsid and ioctl calls**

In the child process block (after fork), update `setsid`:

```zig
// a. Create new session
if (is_macos) {
    _ = std.posix.setsid() catch {};
} else {
    _ = linux.syscall0(.setsid);
}
```

Update the controlling terminal ioctl:

```zig
// c. Set controlling terminal
if (is_macos) {
    _ = std.c.ioctl(@intCast(slave_fd), TIOCSCTTY, @as(c_int, 0));
} else {
    _ = linux.ioctl(@intCast(slave_fd), TIOCSCTTY, 0);
}
```

Update window size ioctl:

```zig
// f. Set window size
var ws = Winsize{ .ws_row = rows, .ws_col = cols };
if (is_macos) {
    _ = std.c.ioctl(@intCast(slave_fd), TIOCSWINSZ, @intFromPtr(&ws));
} else {
    _ = linux.ioctl(@intCast(slave_fd), TIOCSWINSZ, @intFromPtr(&ws));
}
```

- [ ] **Step 4: Update environment variables for macOS**

In the child env setup, skip X11/Wayland vars on macOS:

```zig
if (!is_macos) {
    // X11 / Wayland display variables (only on Linux)
    // ... existing DISPLAY, WAYLAND_DISPLAY, XAUTHORITY, etc.
    if (display_env) |e| { env_arr[ei] = e; ei += 1; }
    if (wayland_env) |e| { env_arr[ei] = e; ei += 1; }
    if (xauth_env) |e| { env_arr[ei] = e; ei += 1; }
    if (xdg_runtime_env) |e| { env_arr[ei] = e; ei += 1; }
    if (dbus_env) |e| { env_arr[ei] = e; ei += 1; }
}
```

- [ ] **Step 5: Update parent process non-blocking setup**

Replace hardcoded fcntl constants (lines 173-177) with portable `std.posix`:

```zig
// Set master_fd nonblocking
const flags = try posix.fcntl(master_fd, std.posix.F.GETFL, 0);
_ = try posix.fcntl(master_fd, std.posix.F.SETFL, flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));
```

- [ ] **Step 6: Update resize method ioctl**

In the `resize` method (lines 200-208):

```zig
pub fn resize(self: *Pty, cols: u16, rows: u16) !void {
    var ws = Winsize{ .ws_row = rows, .ws_col = cols };
    if (is_macos) {
        const rc = std.c.ioctl(@intCast(self.master_fd), TIOCSWINSZ, @intFromPtr(&ws));
        if (rc < 0) return error.IoctlFailed;
    } else {
        const rc = linux.ioctl(
            @intCast(self.master_fd),
            TIOCSWINSZ,
            @intFromPtr(&ws),
        );
        if (@as(isize, @bitCast(rc)) < 0) return error.IoctlFailed;
    }
}
```

- [ ] **Step 7: Verify Linux build and tests**

Run: `cd ~/zt && zig build -Dbackend=x11 -Dshell=/bin/fish`
Expected: Builds successfully (macOS branches are dead code, not compiled)

Run: `cd ~/zt && zig build test -Dbackend=x11 -Dshell=/bin/echo`
Expected: All tests pass (existing PTY test still works)

- [ ] **Step 8: Commit**

```bash
cd ~/zt && git add src/pty.zig
git commit -m "Add macOS comptime branches to PTY handling"
```

---

## Chunk 3: Input macOS Keycode Table

### Task 4: Add macOS virtual keycode → evdev translation table

**Files:**
- Modify: `src/input.zig` (add table after KEY struct)

- [ ] **Step 1: Write test for keycode translation**

At the bottom of `input.zig`, before the existing tests, add:

```zig
test "macOS keycode translation: common keys" {
    // kVK_ANSI_A (0x00) → KEY_A (30)
    try testing.expectEqual(@as(u16, KEY.A), macosToEvdev(0x00));
    // kVK_Return (0x24) → KEY_ENTER (28)
    try testing.expectEqual(@as(u16, KEY.ENTER), macosToEvdev(0x24));
    // kVK_Delete (0x33) → KEY_BACKSPACE (14)
    try testing.expectEqual(@as(u16, KEY.BACKSPACE), macosToEvdev(0x33));
    // kVK_Escape (0x35) → KEY_ESC (1)
    try testing.expectEqual(@as(u16, KEY.ESC), macosToEvdev(0x35));
    // kVK_UpArrow (0x7E) → KEY_UP (103)
    try testing.expectEqual(@as(u16, KEY.UP), macosToEvdev(0x7E));
    // kVK_Space (0x31) → KEY_SPACE (57)
    try testing.expectEqual(@as(u16, KEY.SPACE), macosToEvdev(0x31));
    // kVK_Tab (0x30) → KEY_TAB (15)
    try testing.expectEqual(@as(u16, KEY.TAB), macosToEvdev(0x30));
    // Unknown keycode → 0
    try testing.expectEqual(@as(u16, 0), macosToEvdev(0x7F));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/zt && zig build test -Dbackend=x11 -Dshell=/bin/echo 2>&1 | head -20`
Expected: FAIL — `macosToEvdev` not defined

- [ ] **Step 3: Implement macOS keycode translation table**

After the `KEY` struct (around line 96), add:

```zig
/// macOS virtual keycode → Linux evdev keycode translation.
/// Maps macOS kVK_* codes (0x00-0x7E) to evdev KEY_* codes.
/// Unmapped keycodes return 0.
pub fn macosToEvdev(keycode: u8) u16 {
    if (keycode >= macos_to_evdev_table.len) return 0;
    return macos_to_evdev_table[keycode];
}

const macos_to_evdev_table: [128]u16 = buildMacosTable();

fn buildMacosTable() [128]u16 {
    var table = [_]u16{0} ** 128;
    // Letters (ANSI layout)
    table[0x00] = KEY.A;
    table[0x01] = KEY.S;
    table[0x02] = KEY.D;
    table[0x03] = KEY.F;
    table[0x04] = KEY.H;
    table[0x05] = KEY.G;
    table[0x06] = KEY.Z;
    table[0x07] = KEY.X;
    table[0x08] = KEY.C;
    table[0x09] = KEY.V;
    table[0x0B] = KEY.B;
    table[0x0C] = KEY.Q;
    table[0x0D] = KEY.W;
    table[0x0E] = KEY.E;
    table[0x0F] = KEY.R;
    table[0x10] = KEY.Y;
    table[0x11] = KEY.T;
    // Numbers
    table[0x12] = KEY.@"1";
    table[0x13] = KEY.@"2";
    table[0x14] = KEY.@"3";
    table[0x15] = KEY.@"4";
    table[0x16] = KEY.@"6";
    table[0x17] = KEY.@"5";
    table[0x18] = KEY.EQUAL;
    table[0x19] = KEY.@"9";
    table[0x1A] = KEY.@"7";
    table[0x1B] = KEY.MINUS;
    table[0x1C] = KEY.@"8";
    table[0x1D] = KEY.@"0";
    // Symbols
    table[0x1E] = KEY.RIGHTBRACE;
    table[0x1F] = KEY.O;
    table[0x20] = KEY.U;
    table[0x21] = KEY.LEFTBRACE;
    table[0x22] = KEY.I;
    table[0x23] = KEY.P;
    table[0x25] = KEY.L;
    table[0x26] = KEY.J;
    table[0x27] = KEY.APOSTROPHE;
    table[0x28] = KEY.K;
    table[0x29] = KEY.SEMICOLON;
    table[0x2A] = KEY.BACKSLASH;
    table[0x2B] = KEY.COMMA;
    table[0x2C] = KEY.SLASH;
    table[0x2D] = KEY.N;
    table[0x2E] = KEY.M;
    table[0x2F] = KEY.DOT;
    table[0x32] = KEY.GRAVE;
    // Special keys
    table[0x24] = KEY.ENTER;
    table[0x30] = KEY.TAB;
    table[0x31] = KEY.SPACE;
    table[0x33] = KEY.BACKSPACE;
    table[0x35] = KEY.ESC;
    // Modifier keycodes (for flagsChanged:)
    table[0x38] = KEY.LEFTSHIFT;
    table[0x3A] = KEY.LEFTALT;    // Option
    table[0x3B] = KEY.LEFTCTRL;
    table[0x3C] = KEY.RIGHTSHIFT;
    table[0x3D] = KEY.RIGHTALT;   // Right Option
    table[0x3E] = KEY.RIGHTCTRL;
    table[0x37] = KEY.LEFTMETA;   // Command
    table[0x36] = KEY.RIGHTMETA;  // Right Command
    // Function keys
    table[0x7A] = KEY.F1;
    table[0x78] = KEY.F2;
    table[0x63] = KEY.F3;
    table[0x76] = KEY.F4;
    table[0x60] = KEY.F5;
    table[0x61] = KEY.F6;
    table[0x62] = KEY.F7;
    table[0x64] = KEY.F8;
    table[0x65] = KEY.F9;
    table[0x6D] = KEY.F10;
    table[0x67] = KEY.F11;
    table[0x6F] = KEY.F12;
    // Navigation
    table[0x7E] = KEY.UP;
    table[0x7D] = KEY.DOWN;
    table[0x7B] = KEY.LEFT;
    table[0x7C] = KEY.RIGHT;
    table[0x73] = KEY.HOME;
    table[0x77] = KEY.END;
    table[0x74] = KEY.PAGEUP;
    table[0x79] = KEY.PAGEDOWN;
    table[0x72] = KEY.INSERT;     // Help key on Mac, maps to Insert
    table[0x75] = KEY.DELETE;     // Forward Delete
    return table;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/zt && zig build test -Dbackend=x11 -Dshell=/bin/echo`
Expected: All tests pass, including the new macOS keycode test

- [ ] **Step 5: Commit**

```bash
cd ~/zt && git add src/input.zig
git commit -m "Add macOS virtual keycode to evdev translation table"
```

---

## Chunk 4: Event Loop kqueue Adaptation

### Task 5: Add kqueue comptime branches to main.zig event loop helpers

**Files:**
- Modify: `src/main.zig:1-180` (imports, signal setup, timer, epoll helpers)

This is the largest change to main.zig. We add comptime branches for all Linux-specific event loop functions.

- [ ] **Step 1: Add macOS imports and OS detection**

At the top of `main.zig`, after line 2 (`const builtin = @import("builtin");`), add:

```zig
const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;
```

The `const linux = std.os.linux;` import (line 3) should be conditional:

```zig
const linux = if (is_linux) std.os.linux else struct {};
```

For macOS kqueue constants, use `std.c`:

```zig
const c_os = if (is_macos) std.c else struct {
    pub const EVFILT = struct {};
    pub const NOTE = struct {};
};
```

- [ ] **Step 2: Refactor setupSignals() with comptime branch**

Replace the existing `setupSignals()` function (lines 34-59) with:

```zig
fn setupSignals() !std.posix.fd_t {
    if (is_linux) {
        // Existing Linux signalfd implementation
        var mask = linux.sigemptyset();
        linux.sigaddset(&mask, linux.SIG.CHLD);
        linux.sigaddset(&mask, linux.SIG.TERM);
        linux.sigaddset(&mask, linux.SIG.INT);
        linux.sigaddset(&mask, linux.SIG.HUP);
        linux.sigaddset(&mask, linux.SIG.USR1);
        linux.sigaddset(&mask, linux.SIG.USR2);
        _ = linux.sigprocmask(0, &mask, null);
        const SFD_NONBLOCK: u32 = 0o4000;
        const SFD_CLOEXEC: u32 = 0o2000000;
        const fd_raw = linux.syscall4(
            .signalfd4,
            @as(usize, @bitCast(@as(isize, -1))),
            @intFromPtr(&mask),
            @sizeOf(linux.sigset_t),
            SFD_NONBLOCK | SFD_CLOEXEC,
        );
        const fd_isize: isize = @bitCast(fd_raw);
        if (fd_isize < 0) return error.SignalFdFailed;
        return @intCast(fd_isize);
    } else {
        // macOS: block signals with sigprocmask (kqueue EVFILT_SIGNAL needs this)
        // Signals are registered on kqueue directly, no signalfd needed
        // Return -1 as sentinel (no fd to close)
        var mask = std.mem.zeroes(std.c.sigset_t);
        // Use libc sigaddset on macOS
        _ = std.c.sigaddset(&mask, std.c.SIG.CHLD);
        _ = std.c.sigaddset(&mask, std.c.SIG.TERM);
        _ = std.c.sigaddset(&mask, std.c.SIG.INT);
        _ = std.c.sigaddset(&mask, std.c.SIG.HUP);
        // No USR1/USR2 on macOS (fbdev VT switching only)
        _ = std.c.sigprocmask(std.c.SIG.BLOCK, &mask, null);
        return -1; // sentinel: no fd to manage
    }
}
```

- [ ] **Step 3: Refactor createTimerFd() with comptime branch**

Replace the existing `createTimerFd()` function (lines 65-79) with:

```zig
fn createTimerFd(interval_ns: u64) !std.posix.fd_t {
    if (is_linux) {
        const fd_raw = linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true });
        const fd_isize: isize = @bitCast(fd_raw);
        if (fd_isize < 0) return error.TimerFdFailed;
        const timer_fd: std.posix.fd_t = @intCast(fd_isize);
        const sec: isize = @intCast(interval_ns / std.time.ns_per_s);
        const nsec: isize = @intCast(interval_ns % std.time.ns_per_s);
        const ts = linux.timespec{ .sec = sec, .nsec = nsec };
        const spec = linux.itimerspec{ .it_interval = ts, .it_value = ts };
        const rc = linux.timerfd_settime(timer_fd, .{}, &spec, null);
        const rc_isize: isize = @bitCast(rc);
        if (rc_isize < 0) return error.TimerSetFailed;
        return timer_fd;
    } else {
        // macOS: timer registered directly on kqueue (EVFILT_TIMER)
        // No separate fd needed
        _ = interval_ns;
        return -1; // sentinel
    }
}
```

- [ ] **Step 4: Add kqueue helper functions alongside epoll helpers**

After the existing epoll helpers (lines 84-110), add macOS kqueue equivalents:

```zig
// =============================================================================
// kqueue helpers (macOS)
// =============================================================================

const KqueueIdent = enum(usize) {
    pty = 0,
    signal_chld = 1,
    signal_term = 2,
    signal_int = 3,
    signal_hup = 4,
    timer = 10,
    backend = 20,
};

fn kqueueAdd(kq: i32, fd: std.posix.fd_t, ident: usize, filter: i16) !void {
    var changelist = [1]std.posix.Kevent{.{
        .ident = ident,
        .filter = filter,
        .flags = std.c.EV.ADD,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    }};
    // For fd-based filters, ident IS the fd
    if (filter == std.c.EVFILT.READ or filter == std.c.EVFILT.WRITE) {
        changelist[0].ident = @intCast(fd);
        changelist[0].udata = ident; // store our tag in udata
    }
    _ = std.posix.kevent(kq, &changelist, &.{}, null) catch return error.KEventFailed;
}

fn kqueueAddSignal(kq: i32, sig: u6) !void {
    var changelist = [1]std.posix.Kevent{.{
        .ident = sig,
        .filter = std.c.EVFILT.SIGNAL,
        .flags = std.c.EV.ADD,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    }};
    _ = std.posix.kevent(kq, &changelist, &.{}, null) catch return error.KEventFailed;
}

fn kqueueAddTimer(kq: i32, ident: usize, interval_ms: u32) !void {
    var changelist = [1]std.posix.Kevent{.{
        .ident = ident,
        .filter = std.c.EVFILT.TIMER,
        .flags = std.c.EV.ADD,
        .fflags = std.c.NOTE.MSECONDS,
        .data = interval_ms,
        .udata = 0,
    }};
    _ = std.posix.kevent(kq, &changelist, &.{}, null) catch return error.KEventFailed;
}

fn kqueueSetPtyWrite(kq: i32, pty_fd: std.posix.fd_t, enable: bool) void {
    var changelist = [1]std.posix.Kevent{.{
        .ident = @intCast(pty_fd),
        .filter = std.c.EVFILT.WRITE,
        .flags = std.c.EV.ADD | if (enable) std.c.EV.ENABLE else std.c.EV.DISABLE,
        .fflags = 0,
        .data = 0,
        .udata = @intFromEnum(KqueueIdent.pty),
    }};
    _ = std.posix.kevent(kq, &changelist, &.{}, null) catch {};
}
```

- [ ] **Step 5: Update ptyBufferedWrite/ptyFlushPending for cross-platform**

The `epoll_fd: i32` parameter serves the same role as `kq: i32`. The functions already take it as `i32`. Just update the internal calls:

In `ptyBufferedWrite`, change `epollSetPtyEvents(epoll_fd, pty_ptr.master_fd, true)` to:

```zig
if (is_linux) {
    epollSetPtyEvents(epoll_fd, pty_ptr.master_fd, true);
} else {
    kqueueSetPtyWrite(epoll_fd, pty_ptr.master_fd, true);
}
```

Same pattern in `ptyFlushPending`: replace `epollSetPtyEvents(..., false)` and `epollSetPtyEvents(..., true)` similarly.

- [ ] **Step 6: Update handleSignal for cross-platform**

Replace `handleSignal` (lines 185-201):

```zig
fn handleSignal(sig_fd: std.posix.fd_t, signo_override: ?u32, backend: *Backend) bool {
    const signo: u32 = if (signo_override) |s| s else blk: {
        // Linux: read signalfd_siginfo
        var siginfo: linux.signalfd_siginfo = undefined;
        _ = std.posix.read(sig_fd, std.mem.asBytes(&siginfo)) catch return true;
        break :blk siginfo.signo;
    };

    return switch (signo) {
        linux.SIG.CHLD, linux.SIG.TERM, linux.SIG.INT, linux.SIG.HUP => false,
        linux.SIG.USR1 => blk: {
            backend.releaseVt();
            break :blk true;
        },
        linux.SIG.USR2 => blk: {
            backend.acquireVt();
            break :blk true;
        },
        else => true,
    };
}
```

Note: On macOS, `signo` comes from `kevent.ident` (passed as `signo_override`). On Linux, it's read from `signalfd_siginfo`. The SIG constants use the linux namespace but numeric values match across platforms for CHLD/TERM/INT/HUP.

**IMPORTANT**: Update the **existing Linux call site** in the event loop too. The old `handleSignal(sig_fd, &backend)` becomes `handleSignal(sig_fd, null, &backend)`.

- [ ] **Step 7: Verify Linux build and tests**

Run: `cd ~/zt && zig build -Dbackend=x11 -Dshell=/bin/fish`
Expected: Builds successfully

Run: `cd ~/zt && zig build test -Dbackend=x11 -Dshell=/bin/echo`
Expected: All tests pass

- [ ] **Step 8: Commit**

```bash
cd ~/zt && git add src/main.zig
git commit -m "Add kqueue helper functions and cross-platform event loop setup"
```

### Task 6: Update main() function for cross-platform event loop

**Files:**
- Modify: `src/main.zig:206-636` (main function)

- [ ] **Step 1: Update backend selection to 3-way switch**

Replace lines 15-24 (Backend and X11Event selection):

```zig
const Backend = switch (config.backend) {
    .fbdev => @import("backend/fbdev.zig").FbdevBackend,
    .x11 => @import("backend/x11.zig").X11Backend,
    .macos => @import("backend/macos.zig").MacosBackend,
};

const BackendEvent = switch (config.backend) {
    .x11 => @import("backend/x11.zig").Event,
    .macos => @import("backend/macos.zig").Event,
    .fbdev => void,
};
```

- [ ] **Step 2: Update allocator selection**

Replace lines 215-220:

```zig
const allocator = if (builtin.mode == .Debug)
    gpa.allocator()
else if (config.backend == .x11 or config.backend == .macos)
    std.heap.c_allocator
else
    std.heap.page_allocator;
```

- [ ] **Step 3: Update backend init to 3-way switch**

Replace lines 243-246:

```zig
var backend = switch (config.backend) {
    .fbdev => try Backend.init(allocator),
    .x11, .macos => try Backend.init(),
};
```

- [ ] **Step 4: Update postInit / queryGeometry guards**

Replace `if (config.backend == .x11)` at line 250:

```zig
if (config.backend == .x11 or config.backend == .macos) {
    backend.postInit();
}
```

Replace `if (config.backend == .x11)` at line 309:

```zig
if (config.backend == .x11 or config.backend == .macos) {
```

- [ ] **Step 5: Guard sentinel fd closes**

The macOS path returns `-1` for `sig_fd` and `timer_fd` (no real fd needed). The existing `defer std.posix.close(sig_fd)` and `defer std.posix.close(timer_fd)` would fail with EBADF. Update these to:

```zig
defer if (sig_fd >= 0) std.posix.close(sig_fd);
// ...
defer if (timer_fd >= 0) std.posix.close(timer_fd);
```

Also rename `epoll_timeout` to `event_timeout` since it's used by both platforms.

- [ ] **Step 6: Update event loop setup (epoll → kqueue branching)**

Replace the epoll setup block (lines 282-302) with:

```zig
// 9. Setup event multiplexer (epoll on Linux, kqueue on macOS)
const evloop_fd: i32 = if (is_linux) blk: {
    const epoll_fd_raw = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    const epoll_isize: isize = @bitCast(epoll_fd_raw);
    if (epoll_isize < 0) return error.EpollCreateFailed;
    break :blk @intCast(epoll_isize);
} else blk: {
    break :blk try std.posix.kqueue();
};
defer std.posix.close(evloop_fd);

if (is_linux) {
    try epollAdd(evloop_fd, pty.master_fd, @intFromEnum(EpollTag.pty));
    try epollAdd(evloop_fd, sig_fd, @intFromEnum(EpollTag.signal));
    try epollAdd(evloop_fd, timer_fd, @intFromEnum(EpollTag.timer));
    if (backend.getFd()) |fd| {
        try epollAdd(evloop_fd, fd, @intFromEnum(EpollTag.backend));
    }
    if (config.backend == .fbdev) {
        for (0..backend.evdev_count) |i| {
            try epollAdd(evloop_fd, backend.evdev_fds[i], EVDEV_BASE + @as(u32, @intCast(i)));
        }
    }
} else {
    // kqueue: register PTY read, signals, timer, backend fd
    try kqueueAdd(evloop_fd, pty.master_fd, @intFromEnum(KqueueIdent.pty), std.c.EVFILT.READ);
    try kqueueAddSignal(evloop_fd, std.posix.SIG.CHLD);
    try kqueueAddSignal(evloop_fd, std.posix.SIG.TERM);
    try kqueueAddSignal(evloop_fd, std.posix.SIG.INT);
    try kqueueAddSignal(evloop_fd, std.posix.SIG.HUP);
    try kqueueAddTimer(evloop_fd, @intFromEnum(KqueueIdent.timer), 500);
    if (backend.getFd()) |fd| {
        try kqueueAdd(evloop_fd, fd, @intFromEnum(KqueueIdent.backend), std.c.EVFILT.READ);
    }
}
```

- [ ] **Step 6: Update main event loop with cross-platform dispatch**

This is the largest single change. The `while (running)` loop needs a comptime branch for the event wait and dispatch. The general structure:

```zig
while (running) {
    // ... frame rate calculation (shared, unchanged) ...

    if (is_linux) {
        // Existing epoll_wait + dispatch (unchanged)
        var events: [16]linux.epoll_event = undefined;
        const n_raw = linux.epoll_wait(evloop_fd, &events, events.len, epoll_timeout);
        // ... existing dispatch ...
    } else {
        // kqueue wait + dispatch
        const timeout_spec: ?std.posix.timespec = if (kq_timeout < 0) null else .{
            .sec = @divFloor(kq_timeout, 1000),
            .nsec = @rem(kq_timeout, 1000) * 1_000_000,
        };
        var kevents: [16]std.posix.Kevent = undefined;
        const n = std.posix.kevent(evloop_fd, &.{}, &kevents, timeout_spec) catch 0;

        for (kevents[0..n]) |kev| {
            if (kev.filter == std.c.EVFILT.READ) {
                const ident = kev.udata;
                if (ident == @intFromEnum(KqueueIdent.pty)) {
                    // PTY readable — same drain logic as Linux
                    // ... (shared pty read logic) ...
                } else if (ident == @intFromEnum(KqueueIdent.backend)) {
                    // Backend events (macOS Cocoa)
                    while (backend.pollEvents()) |event| {
                        // ... same event dispatch as X11 ...
                    }
                }
            } else if (kev.filter == std.c.EVFILT.WRITE) {
                // PTY writable
                if (!ptyFlushPending(&pty, &write_buf, &write_pending, evloop_fd)) {
                    running = false;
                    break;
                }
            } else if (kev.filter == std.c.EVFILT.SIGNAL) {
                running = handleSignal(-1, @intCast(kev.ident), &backend);
            } else if (kev.filter == std.c.EVFILT.TIMER) {
                cursor_visible_blink = !cursor_visible_blink;
                term.markDirty(term.cursor_x, term.cursor_y);
            }
        }
    }

    // ... rest of loop (extra PTY drain, cursor dirty, render) is shared ...
}
```

The key insight is: the inner event dispatch differs, but everything after the event processing (extra PTY drain, dirty tracking, rendering, present) is 100% shared.

- [ ] **Step 7: Update X11Event references**

Replace all `X11Event` references with `BackendEvent`.

Replace `if (config.backend == .x11)` guards around event dispatch with `if (config.backend == .x11 or config.backend == .macos)`.

- [ ] **Step 8: Verify Linux build and tests**

Run: `cd ~/zt && zig build -Dbackend=x11 -Dshell=/bin/fish`
Expected: Builds successfully

Run: `cd ~/zt && zig build test -Dbackend=x11 -Dshell=/bin/echo`
Expected: All tests pass

- [ ] **Step 9: Commit**

```bash
cd ~/zt && git add src/main.zig
git commit -m "Add cross-platform event loop: kqueue on macOS, epoll on Linux"
```

---

## Chunk 5: macOS Cocoa Backend

### Task 7: Create backend/macos.zig — Obj-C runtime helpers and Event type

**Files:**
- Create: `src/backend/macos.zig`

- [ ] **Step 1: Create file with imports, Obj-C helpers, and Event type**

Create `src/backend/macos.zig` with the Obj-C runtime bindings, Event type (matching X11), and helper functions:

```zig
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const input_mod = @import("../input.zig");

// Obj-C runtime
const objc = @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
});

// Core Graphics
const cg = @cImport({
    @cInclude("CoreGraphics/CoreGraphics.h");
});

// ============================================================================
// Event types (must match x11.zig Event union exactly)
// ============================================================================

pub const Event = union(enum) {
    key: KeyEvent,
    text: TextEvent,
    paste: PasteEvent,
    resize: ResizeEvent,
    expose: void,
    close: void,
    focus_in: void,
    focus_out: void,
};

pub const PasteEvent = struct {
    data: [4096]u8 = undefined,
    len: u32 = 0,

    pub fn slice(self: *const PasteEvent) []const u8 {
        return self.data[0..self.len];
    }
};

pub const TextEvent = struct {
    data: [128]u8 = undefined,
    len: u32 = 0,

    pub fn slice(self: *const TextEvent) []const u8 {
        return self.data[0..self.len];
    }
};

pub const KeyEvent = struct {
    keycode: u16,
    pressed: bool,
    modifiers: input_mod.Modifiers,
};

pub const ResizeEvent = struct {
    width: u32,
    height: u32,
};

// ============================================================================
// Obj-C runtime helpers
// ============================================================================

const id = *anyopaque;
const SEL = *anyopaque;
const Class = *anyopaque;

fn sel(name: [*:0]const u8) SEL {
    return objc.sel_registerName(name);
}

fn getClass(name: [*:0]const u8) Class {
    return objc.objc_getClass(name) orelse unreachable;
}

// objc_msgSend is used via typed function pointer casts per call site.
// Zig cannot express C variadic calling conventions, so each Cocoa method
// call uses a specific typed cast. Example:
//   const doThing: *const fn (id, SEL, i64) callconv(.c) void = @ptrCast(objc.objc_msgSend);
//   doThing(target, sel("doThing:"), 42);
//
// On x86_64, use objc_msgSend_stret for struct returns (e.g., CGRect):
//   const getFrame = if (builtin.cpu.arch == .x86_64)
//       @as(*const fn (*cg.CGRect, id, SEL) callconv(.c) void, @ptrCast(objc.objc_msgSend_stret))
//   else
//       @as(*const fn (id, SEL) callconv(.c) cg.CGRect, @ptrCast(objc.objc_msgSend));
```

- [ ] **Step 2: Commit skeleton**

```bash
cd ~/zt && git add src/backend/macos.zig
git commit -m "Add macOS backend skeleton: Event types and Obj-C helpers"
```

### Task 8: Implement MacosBackend struct and init/deinit

**Files:**
- Modify: `src/backend/macos.zig`

- [ ] **Step 1: Add MacosBackend struct with all required fields**

```zig
pub const MacosBackend = struct {
    const Self = @This();

    // Pixel buffer (BGRA32, managed by CGBitmapContext)
    buffer: []u8,
    width: u32,
    height: u32,
    stride: u32,

    // Self-pipe for kqueue wakeup
    wakeup_read_fd: std.posix.fd_t,
    wakeup_write_fd: std.posix.fd_t,

    // Cocoa objects (opaque Obj-C ids)
    app: id,
    window: id,
    view: id,
    cg_context: cg.CGContextRef,

    // Dirty tracking
    dirty_y_min: u32 = std.math.maxInt(u32),
    dirty_y_max: u32 = 0,

    // Event queue (ring buffer filled by NSView callbacks)
    event_queue: [64]Event = undefined,
    event_head: u32 = 0,
    event_tail: u32 = 0,

    // IME state
    has_marked_text: bool = false,
};
```

- [ ] **Step 2: Implement init()**

```zig
pub fn init() !Self {
    // 1. Create self-pipe for kqueue wakeup
    const pipe_fds = try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });

    // 2. Create NSApplication
    const NSApplication = getClass("NSApplication");
    const app: id = @ptrCast(@alignCast(
        @as(*const fn (id, SEL) callconv(.c) id, @ptrCast(objc.objc_msgSend))(
            @ptrCast(@alignCast(NSApplication)),
            sel("sharedApplication"),
        ),
    ));
    // setActivationPolicy: NSApplicationActivationPolicyRegular (0)
    const setPolicy: *const fn (id, SEL, i64) callconv(.c) void = @ptrCast(objc.objc_msgSend);
    setPolicy(app, sel("setActivationPolicy:"), 0);

    // 3. Create window (80x24 cells)
    const win_width: u32 = 80 * config.cell_width;
    const win_height: u32 = 24 * config.cell_height;
    const stride: u32 = win_width * 4;

    // NSWindow alloc + initWithContentRect:styleMask:backing:defer:
    // ... (Obj-C runtime calls for window creation)

    // 4. Create CGBitmapContext
    const buffer_size = stride * win_height;
    const colorspace = cg.CGColorSpaceCreateDeviceRGB();
    defer cg.CGColorSpaceRelease(colorspace);

    const context = cg.CGBitmapContextCreate(
        null, // let CG allocate
        win_width,
        win_height,
        8, // bits per component
        stride,
        colorspace,
        cg.kCGBitmapByteOrder32Little | cg.kCGImageAlphaNoneSkipFirst,
    ) orelse return error.CGContextCreateFailed;

    const data_ptr = cg.CGBitmapContextGetData(context) orelse return error.CGContextNoData;
    const buffer: []u8 = @as([*]u8, @ptrCast(data_ptr))[0..buffer_size];
    @memset(buffer, 0);

    // 5. Create NSView subclass, register methods, create instance
    // ... (objc_allocateClassPair + class_addMethod for drawRect:, keyDown:, etc.)

    // 6. Show window
    // ...

    return Self{
        .buffer = buffer,
        .width = win_width,
        .height = win_height,
        .stride = stride,
        .wakeup_read_fd = pipe_fds[0],
        .wakeup_write_fd = pipe_fds[1],
        .app = app,
        .window = undefined, // set after window creation
        .view = undefined,   // set after view creation
        .cg_context = context,
    };
}
```

Note: The full `init()` implementation will be ~100 lines of Obj-C runtime calls. The exact calls are documented in the spec Section 5. Each NSView method registration uses `class_addMethod` with the appropriate Obj-C type encoding string.

- [ ] **Step 3: Implement deinit()**

```zig
pub fn deinit(self: *Self) void {
    cg.CGContextRelease(self.cg_context);
    std.posix.close(self.wakeup_read_fd);
    std.posix.close(self.wakeup_write_fd);
    // Release Cocoa objects
    const release: *const fn (id, SEL) callconv(.c) void = @ptrCast(objc.objc_msgSend);
    release(self.window, sel("release"));
}
```

- [ ] **Step 4: Commit**

```bash
cd ~/zt && git add src/backend/macos.zig
git commit -m "Implement MacosBackend init/deinit with CGBitmapContext and self-pipe"
```

### Task 9: Implement MacosBackend interface methods

**Files:**
- Modify: `src/backend/macos.zig`

- [ ] **Step 1: Implement buffer/dimension accessors and dirty tracking**

```zig
pub fn getBuffer(self: *Self) []u8 {
    return self.buffer;
}

pub fn getStride(self: *Self) u32 {
    return self.stride;
}

pub fn getWidth(self: *Self) u32 {
    return self.width;
}

pub fn getHeight(self: *Self) u32 {
    return self.height;
}

pub fn markDirtyRows(self: *Self, y_start: u32, y_end: u32) void {
    if (y_start < self.dirty_y_min) self.dirty_y_min = y_start;
    if (y_end > self.dirty_y_max) self.dirty_y_max = y_end;
}

pub fn getFd(self: *Self) ?std.posix.fd_t {
    return self.wakeup_read_fd;
}
```

- [ ] **Step 2: Implement present() and flush()**

```zig
pub fn present(self: *Self) void {
    // setNeedsDisplay:YES on the view
    const setNeedsDisplay: *const fn (id, SEL, bool) callconv(.c) void = @ptrCast(objc.objc_msgSend);
    setNeedsDisplay(self.view, sel("setNeedsDisplay:"), true);
    self.dirty_y_min = std.math.maxInt(u32);
    self.dirty_y_max = 0;
}

pub fn flush(_: *Self) void {
    // No-op for macOS (Cocoa handles display refresh)
}
```

- [ ] **Step 3: Implement resize()**

```zig
pub fn resize(self: *Self, w: u32, h: u32) !void {
    if (w == self.width and h == self.height) return;

    // Release old context
    cg.CGContextRelease(self.cg_context);

    // Create new context
    const stride = w * 4;
    const colorspace = cg.CGColorSpaceCreateDeviceRGB();
    defer cg.CGColorSpaceRelease(colorspace);

    const context = cg.CGBitmapContextCreate(
        null, w, h, 8, stride, colorspace,
        cg.kCGBitmapByteOrder32Little | cg.kCGImageAlphaNoneSkipFirst,
    ) orelse return error.CGContextCreateFailed;

    const data_ptr = cg.CGBitmapContextGetData(context) orelse return error.CGContextNoData;
    const buffer_size = stride * h;

    self.cg_context = context;
    self.buffer = @as([*]u8, @ptrCast(data_ptr))[0..buffer_size];
    self.width = w;
    self.height = h;
    self.stride = stride;
    @memset(self.buffer, 0);
}
```

- [ ] **Step 4: Implement no-op methods (fbdev compat)**

```zig
pub fn saveConsoleState(_: *Self) !void {}
pub fn restoreConsoleState(_: *Self) void {}
pub fn setupVtSwitching(_: *Self) !void {}
pub fn releaseVt(_: *Self) void {}
pub fn acquireVt(_: *Self) void {}
pub fn postInit(_: *Self) void {}
```

- [ ] **Step 5: Implement queryGeometry()**

```zig
pub fn queryGeometry(self: *Self) struct { w: u32, h: u32 } {
    // Get NSView frame via Obj-C runtime
    // On macOS, frame returns CGRect (struct)
    // Use objc_msgSend_stret on x86_64, objc_msgSend on ARM64
    _ = self;
    // For now, return current dimensions (will be updated by windowDidResize:)
    return .{ .w = self.width, .h = self.height };
}
```

- [ ] **Step 6: Commit**

```bash
cd ~/zt && git add src/backend/macos.zig
git commit -m "Implement MacosBackend interface methods: buffer, present, resize, no-ops"
```

### Task 10: Implement NSView subclass with event handling and IME

**Files:**
- Modify: `src/backend/macos.zig`

- [ ] **Step 1: Implement NSView subclass registration**

Add function to create the custom NSView subclass at runtime:

```zig
fn registerViewClass() Class {
    const NSView = getClass("NSView");
    const cls = objc.objc_allocateClassPair(NSView, "ZTView", 0) orelse unreachable;

    // Add NSTextInputClient protocol conformance
    const protocol = objc.objc_getProtocol("NSTextInputClient");
    if (protocol) |p| {
        _ = objc.class_addProtocol(cls, p);
    }

    // Add methods
    _ = objc.class_addMethod(cls, sel("drawRect:"), @ptrCast(&viewDrawRect), "v@:{CGRect=dddd}");
    _ = objc.class_addMethod(cls, sel("keyDown:"), @ptrCast(&viewKeyDown), "v@:@");
    _ = objc.class_addMethod(cls, sel("flagsChanged:"), @ptrCast(&viewFlagsChanged), "v@:@");
    _ = objc.class_addMethod(cls, sel("acceptsFirstResponder"), @ptrCast(&viewAcceptsFirstResponder), "B@:");
    _ = objc.class_addMethod(cls, sel("canBecomeKeyView"), @ptrCast(&viewCanBecomeKeyView), "B@:");
    // IME methods
    _ = objc.class_addMethod(cls, sel("insertText:replacementRange:"), @ptrCast(&viewInsertText), "v@:@{NSRange=QQ}");
    _ = objc.class_addMethod(cls, sel("hasMarkedText"), @ptrCast(&viewHasMarkedText), "B@:");
    _ = objc.class_addMethod(cls, sel("setMarkedText:selectedRange:replacementRange:"), @ptrCast(&viewSetMarkedText), "v@:@{NSRange=QQ}{NSRange=QQ}");
    _ = objc.class_addMethod(cls, sel("unmarkText"), @ptrCast(&viewUnmarkText), "v@:");
    _ = objc.class_addMethod(cls, sel("validAttributesForMarkedText"), @ptrCast(&viewValidAttributes), "@@:");
    _ = objc.class_addMethod(cls, sel("firstRectForCharacterRange:actualRange:"), @ptrCast(&viewFirstRect), "{CGRect=dddd}@:{NSRange=QQ}^{NSRange=QQ}");
    // Retina display support
    _ = objc.class_addMethod(cls, sel("viewDidChangeBackingProperties"), @ptrCast(&viewDidChangeBackingProperties), "v@:");
    // Window delegate methods (view acts as delegate)
    _ = objc.class_addMethod(cls, sel("windowShouldClose:"), @ptrCast(&delegateWindowShouldClose), "B@:@");
    _ = objc.class_addMethod(cls, sel("windowDidBecomeKey:"), @ptrCast(&delegateWindowDidBecomeKey), "v@:@");
    _ = objc.class_addMethod(cls, sel("windowDidResignKey:"), @ptrCast(&delegateWindowDidResignKey), "v@:@");
    _ = objc.class_addMethod(cls, sel("windowDidResize:"), @ptrCast(&delegateWindowDidResize), "v@:@");
    _ = objc.class_addMethod(cls, sel("windowDidChangeOcclusionState:"), @ptrCast(&delegateWindowDidChangeOcclusion), "v@:@");

    // Add instance variable for backend pointer
    _ = objc.class_addIvar(cls, "_zt_backend", @sizeOf(*Self), @alignOf(*Self), "^v");

    objc.objc_registerClassPair(cls);
    return cls;
}
```

- [ ] **Step 2: Implement callback functions**

Each NSView/delegate method is a C-calling-convention function:

```zig
fn viewDrawRect(_self: id, _sel: SEL, rect: cg.CGRect) callconv(.c) void {
    _ = _sel;
    _ = rect;
    const backend = getBackendPtr(_self);
    // Create CGImage from bitmap context and draw
    const image = cg.CGBitmapContextCreateImage(backend.cg_context);
    defer cg.CGImageRelease(image);
    // Get current NSGraphicsContext, draw image
    // ...
}

fn viewKeyDown(_self: id, _sel: SEL, event: id) callconv(.c) void {
    _ = _sel;
    const backend = getBackendPtr(_self);
    // Extract keyCode from NSEvent
    const getKeyCode: *const fn (id, SEL) callconv(.c) u16 = @ptrCast(objc.objc_msgSend);
    const keycode = getKeyCode(event, sel("keyCode"));
    const getModFlags: *const fn (id, SEL) callconv(.c) u64 = @ptrCast(objc.objc_msgSend);
    const modflags = getModFlags(event, sel("modifierFlags"));

    // Check for Cmd+Q, Cmd+W, Cmd+V
    const cmd_flag: u64 = 1 << 20; // NSEventModifierFlagCommand
    if (modflags & cmd_flag != 0) {
        if (keycode == 0x0C) { // Q
            backend.pushEvent(.close);
            return;
        } else if (keycode == 0x0D) { // W
            backend.pushEvent(.close);
            return;
        } else if (keycode == 0x09) { // V - paste
            backend.handlePaste();
            return;
        }
        return; // ignore other Cmd+ combos
    }

    // Translate macOS keycode to evdev
    const evdev_code = input_mod.macosToEvdev(@intCast(keycode));
    const mods = flagsToModifiers(modflags);
    backend.pushEvent(.{ .key = .{
        .keycode = evdev_code,
        .pressed = true,
        .modifiers = mods,
    }});

    // Forward to IME
    const interpretKeyEvents: *const fn (id, SEL, id) callconv(.c) void = @ptrCast(objc.objc_msgSend);
    const NSArray = getClass("NSArray");
    const arrayWithObject: *const fn (id, SEL, id) callconv(.c) id = @ptrCast(objc.objc_msgSend);
    const array = arrayWithObject(@ptrCast(@alignCast(NSArray)), sel("arrayWithObject:"), event);
    interpretKeyEvents(_self, sel("interpretKeyEvents:"), array);
}

fn viewInsertText(_self: id, _sel: SEL, text: id, range: [2]u64) callconv(.c) void {
    _ = _sel;
    _ = range;
    const backend = getBackendPtr(_self);
    // Get UTF-8 string from NSString
    const getUTF8: *const fn (id, SEL) callconv(.c) [*:0]const u8 = @ptrCast(objc.objc_msgSend);
    const utf8 = getUTF8(text, sel("UTF8String"));
    const str = std.mem.span(utf8);
    if (str.len > 0 and str.len <= 128) {
        var ev = TextEvent{};
        @memcpy(ev.data[0..str.len], str);
        ev.len = @intCast(str.len);
        backend.pushEvent(.{ .text = ev });
    }
}

// ... (similar implementations for flagsChanged, delegate methods, etc.)
```

- [ ] **Step 3: Implement pollEvents() and event queue helpers**

```zig
fn pushEvent(self: *Self, event: Event) void {
    const next = (self.event_tail + 1) % 64;
    if (next == self.event_head) return; // queue full, drop
    self.event_queue[self.event_tail] = event;
    self.event_tail = next;
    // Wake kqueue
    _ = std.posix.write(self.wakeup_write_fd, &[_]u8{1}) catch {};
}

pub fn pollEvents(self: *Self) ?Event {
    // First: poll NSApp for any pending Cocoa events
    const nextEvent: *const fn (id, SEL, u64, id, id, bool) callconv(.c) ?id = @ptrCast(objc.objc_msgSend);
    while (true) {
        const event = nextEvent(self.app, sel("nextEventMatchingMask:untilDate:inMode:dequeue:"),
            std.math.maxInt(u64), // NSEventMaskAny
            @ptrCast(@alignCast(null)), // untilDate: nil (non-blocking)
            @ptrCast(@alignCast(null)), // default run loop mode — will need actual string
            true, // dequeue
        ) orelse break;
        // sendEvent: dispatches to the appropriate view method
        const sendEvent: *const fn (id, SEL, id) callconv(.c) void = @ptrCast(objc.objc_msgSend);
        sendEvent(self.app, sel("sendEvent:"), event);
    }

    // Drain wakeup pipe
    var drain_buf: [64]u8 = undefined;
    _ = std.posix.read(self.wakeup_read_fd, &drain_buf) catch {};

    // Return next event from queue
    if (self.event_head == self.event_tail) return null;
    const event = self.event_queue[self.event_head];
    self.event_head = (self.event_head + 1) % 64;
    return event;
}
```

- [ ] **Step 4: Implement helper functions**

```zig
fn getBackendPtr(_self: id) *Self {
    var ptr: *Self = undefined;
    const ivar = objc.class_getInstanceVariable(objc.object_getClass(_self), "_zt_backend");
    const offset = objc.ivar_getOffset(ivar);
    ptr = @ptrCast(@alignCast(@as([*]u8, @ptrCast(_self)) + @as(usize, @intCast(offset))));
    return ptr;
}

fn flagsToModifiers(flags: u64) input_mod.Modifiers {
    return .{
        .shift = (flags & (1 << 17)) != 0,  // NSEventModifierFlagShift
        .ctrl = (flags & (1 << 18)) != 0,    // NSEventModifierFlagControl
        .alt = (flags & (1 << 19)) != 0,     // NSEventModifierFlagOption
        .meta = (flags & (1 << 20)) != 0,    // NSEventModifierFlagCommand
    };
}

fn handlePaste(self: *Self) void {
    // NSPasteboard.generalPasteboard.stringForType:NSPasteboardTypeString
    const NSPasteboard = getClass("NSPasteboard");
    const generalPB: *const fn (id, SEL) callconv(.c) id = @ptrCast(objc.objc_msgSend);
    const pb = generalPB(@ptrCast(@alignCast(NSPasteboard)), sel("generalPasteboard"));
    const stringForType: *const fn (id, SEL, id) callconv(.c) ?id = @ptrCast(objc.objc_msgSend);
    const nsstring = stringForType(pb, sel("stringForType:"), @ptrCast(@alignCast(getClass("NSPasteboardTypeString")))) orelse return;
    const getUTF8: *const fn (id, SEL) callconv(.c) [*:0]const u8 = @ptrCast(objc.objc_msgSend);
    const utf8 = getUTF8(nsstring, sel("UTF8String"));
    const str = std.mem.span(utf8);
    if (str.len > 0 and str.len <= 4096) {
        var ev = PasteEvent{};
        @memcpy(ev.data[0..str.len], str);
        ev.len = @intCast(str.len);
        self.pushEvent(.{ .paste = ev });
    }
}
```

- [ ] **Step 5: Commit**

```bash
cd ~/zt && git add src/backend/macos.zig
git commit -m "Implement NSView subclass, event handling, IME, and clipboard for macOS backend"
```

---

## Chunk 6: Integration and README

### Task 11: Final integration — verify Linux build with all changes

**Files:**
- All modified files

- [ ] **Step 1: Full build test with x11 backend**

Run: `cd ~/zt && zig build -Dbackend=x11 -Dshell=/bin/fish`
Expected: Builds successfully. macOS code is behind comptime switches, not compiled.

- [ ] **Step 2: Full build test with fbdev backend**

Run: `cd ~/zt && zig build -Dbackend=fbdev -Dshell=/bin/fish`
Expected: Builds successfully.

- [ ] **Step 3: Run all tests**

Run: `cd ~/zt && zig build test -Dbackend=x11 -Dshell=/bin/echo`
Expected: All tests pass.

- [ ] **Step 4: Verify zt launches (X11)**

Run: `cd ~/zt && ./zig-out/bin/zt` (if X11 session available)
Expected: Terminal opens, interactive shell works, Ctrl+D exits cleanly.

- [ ] **Step 5: Commit any fixes**

If any issues found, fix and commit.

### Task 12: Update README with macOS instructions

**Files:**
- Modify: `README.md` (existing file — add macOS section)

- [ ] **Step 1: Add macOS section to existing README**

The README already exists with Linux build instructions. Add a macOS section after the existing build sections. Include:

```markdown
### macOS (experimental)

> **Note:** The macOS backend was developed without access to macOS hardware
> and has not been tested on a real Mac. Bug reports and patches welcome.

```bash
zig build -Dbackend=macos -Dshell=/bin/zsh
```

Requires macOS SDK (Xcode or Command Line Tools).
```

Also update the Build Options table to include `-Dshell=` and `macos` as a backend value.

- [ ] **Step 2: Commit**

```bash
cd ~/zt && git add README.md
git commit -m "Add macOS build instructions and disclaimer to README"
```
