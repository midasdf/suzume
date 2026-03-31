# zt Wayland Backend Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a pure-Zig Wayland backend to zt terminal emulator with wl_shm rendering, xdg-shell windowing, keyboard/IME input, and clipboard support.

**Architecture:** New `backend/wayland.zig` + `backend/wayland/*.zig` modules implementing the Wayland wire protocol directly over UNIX socket (no libwayland-client). The backend exposes the same comptime duck-typed API as existing x11/fbdev/macos backends. An internal epoll wraps the Wayland socket, key repeat timer, and clipboard pipe fds behind a single `getFd()`.

**Tech Stack:** Zig (build system + source), xkbcommon (keymap parsing, already linked by x11 backend), Linux epoll/timerfd/memfd_create/signalfd syscalls.

**Spec:** `docs/superpowers/specs/2026-04-01-zt-wayland-design.md`

---

## Chunk 1: Foundation (wire protocol + build integration)

### Task 1: Build Integration

**Files:**
- Modify: `zt/build.zig`
- Modify: `zt/config.zig`

- [ ] **Step 1: Add `wayland` to Backend enum in config.zig**

```zig
// config.zig — add .wayland variant and use_wayland build option
pub const Backend = enum {
    fbdev,
    x11,
    wayland,
    macos,
};

pub const backend: Backend = if (build_options.use_macos) .macos else if (build_options.use_wayland) .wayland else if (build_options.use_x11) .x11 else .fbdev;
```

- [ ] **Step 2: Add `use_wayland` build option and xkbcommon linking in build.zig**

```zig
// build.zig — after is_macos definition
const is_wayland = std.mem.eql(u8, backend_opt, "wayland");

// Add to options
options.addOption(bool, "use_wayland", is_wayland);

// Add linking block after is_x11 block
} else if (is_wayland) {
    exe.linkSystemLibrary("xkbcommon");
    exe.linkLibC();
}
```

Update the backend_opt description string to include "wayland".

- [ ] **Step 3: Verify build compiles with `-Dbackend=wayland`**

Create a minimal stub `src/backend/wayland.zig` that satisfies the comptime import:

```zig
// src/backend/wayland.zig — minimal stub
const input_mod = @import("../input.zig");

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

pub const KeyEvent = struct {
    keycode: u16,
    pressed: bool,
    modifiers: input_mod.Modifiers,
};

pub const TextEvent = struct {
    data: [128]u8 = undefined,
    len: u32 = 0,
    pub fn slice(self: *const TextEvent) []const u8 {
        return self.data[0..self.len];
    }
};

pub const PasteEvent = struct {
    data: [4096]u8 = undefined,
    len: u32 = 0,
    pub fn slice(self: *const PasteEvent) []const u8 {
        return self.data[0..self.len];
    }
};

pub const ResizeEvent = struct {
    width: u32,
    height: u32,
};

pub const WaylandBackend = struct {
    // Stub — will be filled in later tasks
};
```

This will NOT compile yet because main.zig needs the `.wayland` branches. That's Task 2.

Run: `cd ~/zt && zig build -Dbackend=wayland 2>&1 | head -20`
Expected: Compile error about missing wayland branch in main.zig switch statements

- [ ] **Step 4: Commit**

```bash
cd ~/zt && git add config.zig build.zig src/backend/wayland.zig
git commit -m "feat(wayland): add build integration and backend enum"
```

---

### Task 2: main.zig Wayland Branches

**Files:**
- Modify: `zt/src/main.zig`

Add `.wayland` to every `switch (config.backend)` and update `if` conditionals. The Wayland backend behaves like X11/macOS (windowed, no allocator in init, has postInit, has pollEvents).

- [ ] **Step 1: Add Backend and BackendEvent imports**

```zig
// main.zig line 17-27: add .wayland branches
const Backend = switch (config.backend) {
    .fbdev => @import("backend/fbdev.zig").FbdevBackend,
    .x11 => @import("backend/x11.zig").X11Backend,
    .wayland => @import("backend/wayland.zig").WaylandBackend,
    .macos => @import("backend/macos.zig").MacosBackend,
};

const BackendEvent = switch (config.backend) {
    .x11 => @import("backend/x11.zig").Event,
    .wayland => @import("backend/wayland.zig").Event,
    .macos => @import("backend/macos.zig").Event,
    .fbdev => void,
};
```

- [ ] **Step 2: Update allocator selection (line ~320)**

```zig
// Wayland links libc (for xkbcommon), so use c_allocator
else if (config.backend == .x11 or config.backend == .wayland or config.backend == .macos)
    std.heap.c_allocator
```

- [ ] **Step 3: Update init call (line ~346)**

```zig
var backend = switch (config.backend) {
    .fbdev => try Backend.init(allocator),
    .x11, .wayland, .macos => try Backend.init(),
};
```

- [ ] **Step 4: Update all `if (config.backend == .x11 or config.backend == .macos)` conditionals**

These appear at approximately:
- Line ~353: postInit call → add `.wayland`
- Line ~424: queryGeometry sync → add `.wayland`
- Line ~526: backend event dispatch in epoll loop → add `.wayland`

Change each to:
```zig
if (config.backend == .x11 or config.backend == .wayland or config.backend == .macos)
```

- [ ] **Step 5: Commit**

```bash
cd ~/zt && git add src/main.zig
git commit -m "feat(wayland): add wayland branches to main.zig event loop"
```

---

### Task 3: Wire Protocol — Message Types and Encoding

**Files:**
- Create: `zt/src/backend/wayland/wire.zig`

- [ ] **Step 1: Write tests for message header encoding/decoding**

```zig
// wire.zig — at bottom of file

test "header encode" {
    const hdr = encodeHeader(1, 0, 12); // object_id=1, opcode=0, size=12
    try std.testing.expectEqual(@as(u32, 1), hdr[0]); // object_id
    try std.testing.expectEqual(@as(u32, (12 << 16) | 0), hdr[1]); // size_opcode
}

test "header decode" {
    const raw = [2]u32{ 5, (16 << 16) | 3 };
    const hdr = decodeHeader(&raw);
    try std.testing.expectEqual(@as(u32, 5), hdr.object_id);
    try std.testing.expectEqual(@as(u16, 3), hdr.opcode);
    try std.testing.expectEqual(@as(u16, 16), hdr.size);
}

test "argument padding to 4-byte boundary" {
    // "hello" = 5 bytes + 1 null = 6, padded to 8
    try std.testing.expectEqual(@as(usize, 8), alignUp(6, 4));
    // "ab" = 2 bytes + 1 null = 3, padded to 4
    try std.testing.expectEqual(@as(usize, 4), alignUp(3, 4));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/zt && zig build test -Dbackend=wayland 2>&1 | tail -20`
Expected: Compilation error (functions not defined)

- [ ] **Step 3: Implement header encode/decode and alignment**

```zig
const std = @import("std");
const posix = std.posix;

pub const Header = struct {
    object_id: u32,
    opcode: u16,
    size: u16,
};

pub fn encodeHeader(object_id: u32, opcode: u16, size: u16) [2]u32 {
    return .{ object_id, (@as(u32, size) << 16) | @as(u32, opcode) };
}

pub fn decodeHeader(words: *const [2]u32) Header {
    return .{
        .object_id = words[0],
        .opcode = @truncate(words[1] & 0xFFFF),
        .size = @truncate(words[1] >> 16),
    };
}

pub fn alignUp(n: usize, alignment: usize) usize {
    return (n + alignment - 1) & ~(alignment - 1);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/zt && zig build test -Dbackend=wayland 2>&1 | tail -10`
Expected: All 3 tests pass

- [ ] **Step 5: Commit**

```bash
cd ~/zt && git add src/backend/wayland/wire.zig
git commit -m "feat(wayland): wire protocol header encode/decode"
```

---

### Task 4: Wire Protocol — Object ID Allocator

**Files:**
- Modify: `zt/src/backend/wayland/wire.zig`

- [ ] **Step 1: Write tests for object ID allocation**

```zig
test "object id allocator" {
    var alloc = ObjectIdAllocator{};
    try std.testing.expectEqual(@as(u32, 2), alloc.next()); // 1 is wl_display
    try std.testing.expectEqual(@as(u32, 3), alloc.next());
    alloc.release(2);
    try std.testing.expectEqual(@as(u32, 2), alloc.next()); // recycled
    try std.testing.expectEqual(@as(u32, 4), alloc.next()); // new
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/zt && zig build test -Dbackend=wayland 2>&1 | tail -10`

- [ ] **Step 3: Implement ObjectIdAllocator**

```zig
pub const ObjectIdAllocator = struct {
    next_id: u32 = 2, // 1 = wl_display (reserved)
    free_list: [32]u32 = undefined,
    free_count: u32 = 0,

    pub fn next(self: *ObjectIdAllocator) u32 {
        if (self.free_count > 0) {
            self.free_count -= 1;
            return self.free_list[self.free_count];
        }
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    pub fn release(self: *ObjectIdAllocator, id: u32) void {
        if (self.free_count < self.free_list.len) {
            self.free_list[self.free_count] = id;
            self.free_count += 1;
        }
    }
};
```

- [ ] **Step 4: Run test to verify it passes**

- [ ] **Step 5: Commit**

```bash
cd ~/zt && git add src/backend/wayland/wire.zig
git commit -m "feat(wayland): object ID allocator with free list recycling"
```

---

### Task 5: Wire Protocol — Socket Connection

**Files:**
- Modify: `zt/src/backend/wayland/wire.zig`

- [ ] **Step 1: Implement UNIX socket connect**

```zig
pub const Connection = struct {
    fd: posix.fd_t,
    id_alloc: ObjectIdAllocator = .{},

    // Send/receive buffers (align(4) for safe u32 pointer casts in header parsing)
    recv_buf: [4096]u8 align(4) = undefined,
    recv_len: usize = 0,
    send_buf: [4096]u8 = undefined,
    send_len: usize = 0,
    // fd receiving
    recv_fds: [4]posix.fd_t = .{ -1, -1, -1, -1 },
    recv_fd_count: usize = 0,

    pub fn connect() !Connection {
        const display = std.posix.getenv("WAYLAND_DISPLAY") orelse "wayland-0";
        const runtime_dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntimeDir;

        // Build socket path
        var path_buf: [256]u8 = undefined;
        const path_len = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ runtime_dir, display }) catch return error.PathTooLong;
        path_buf[path_len.len] = 0;

        const addr = std.net.Address.initUnix(path_buf[0..path_len.len :0]) catch return error.InvalidSocketPath;
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        errdefer posix.close(fd);

        posix.connect(fd, &addr.any, addr.getOsSockLen()) catch return error.ConnectFailed;
        return .{ .fd = fd };
    }

    pub fn deinit(self: *Connection) void {
        posix.close(self.fd);
    }
};
```

- [ ] **Step 2: Implement sendMessage with SCM_RIGHTS fd passing**

```zig
    /// Send a Wayland message. `fds` are passed out-of-band via SCM_RIGHTS
    /// ancillary data — they occupy zero bytes in the message payload.
    /// The message size in the header counts only header + payload bytes.
    pub fn sendMessage(self: *Connection, object_id: u32, opcode: u16, payload: []const u8, fds: []const posix.fd_t) !void {
        const header_size = 8;
        // NOTE: fds are NOT counted in total_size — they are out-of-band via SCM_RIGHTS
        const total_size: u16 = @intCast(header_size + payload.len);
        const hdr = encodeHeader(object_id, opcode, total_size);

        // Assemble into send buffer
        const hdr_bytes = std.mem.asBytes(&hdr);
        @memcpy(self.send_buf[0..8], hdr_bytes);
        if (payload.len > 0) {
            @memcpy(self.send_buf[8 .. 8 + payload.len], payload);
        }

        const iov = [1]posix.iovec_const{.{
            .base = &self.send_buf,
            .len = total_size,
        }};

        if (fds.len > 0) {
            // sendmsg with SCM_RIGHTS
            const cmsg_size = @sizeOf(posix.msghdr_const); // use raw syscall for fd passing
            _ = cmsg_size;
            // Use raw linux sendmsg for SCM_RIGHTS
            try self.sendWithFds(&iov, fds);
        } else {
            _ = try posix.writev(self.fd, &iov);
        }
    }
```

Implementation note: `sendWithFds` uses raw `sendmsg` syscall with `SCM_RIGHTS` control message. This is the most complex part of wire.zig — approximately 50 lines handling cmsg buffer construction.

- [ ] **Step 3: Implement recvMessage with fd receiving**

```zig
    pub fn recvEvents(self: *Connection) !usize {
        // recvmsg into recv_buf[recv_len..], extract fds from ancillary data
        // Returns number of new bytes received
        // Handles partial messages: recv_len tracks buffered bytes from previous calls
        ...
    }

    pub fn nextEvent(self: *Connection) ?Header {
        // Parse next complete message from recv_buf
        // Returns null if insufficient data for a complete message
        if (self.recv_len < 8) return null;
        const words: *const [2]u32 = @ptrCast(@alignCast(self.recv_buf[0..8]));
        const hdr = decodeHeader(words);
        if (self.recv_len < hdr.size) return null; // partial message
        return hdr;
    }

    pub fn consumeEvent(self: *Connection, size: u16) []const u8 {
        // Return payload slice and advance recv_buf
        const payload = self.recv_buf[8..size];
        const remaining = self.recv_len - size;
        if (remaining > 0) {
            std.mem.copyForwards(u8, &self.recv_buf, self.recv_buf[size..self.recv_len]);
        }
        self.recv_len = remaining;
        return payload;
    }

    pub fn consumeFd(self: *Connection) ?posix.fd_t {
        if (self.recv_fd_count == 0) return null;
        const fd = self.recv_fds[0];
        self.recv_fd_count -= 1;
        // Shift remaining fds
        var i: usize = 0;
        while (i < self.recv_fd_count) : (i += 1) {
            self.recv_fds[i] = self.recv_fds[i + 1];
        }
        return fd;
    }
```

- [ ] **Step 4: Implement flush**

```zig
    pub fn flush(self: *Connection) !void {
        _ = try posix.write(self.fd, self.send_buf[0..0]); // noop placeholder
        // Real flush: send any buffered messages
    }
```

- [ ] **Step 5: Commit**

```bash
cd ~/zt && git add src/backend/wayland/wire.zig
git commit -m "feat(wayland): wire protocol socket connection, sendmsg/recvmsg with SCM_RIGHTS"
```

---

### Task 6: Wire Protocol — Argument Serialization Helpers

**Files:**
- Modify: `zt/src/backend/wayland/wire.zig`

- [ ] **Step 1: Write tests for argument serialization**

```zig
test "putUint and putString" {
    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    putUint(&buf, &pos, 42);
    try std.testing.expectEqual(@as(usize, 4), pos);
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, buf[0..4], .little));

    putString(&buf, &pos, "zt");
    // string: 4 bytes length + "zt\0" padded to 4 = 4+4 = 8
    try std.testing.expectEqual(@as(usize, 12), pos);
}

test "getUint and getString" {
    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    putUint(&buf, &pos, 7);
    putString(&buf, &pos, "hello");

    var rpos: usize = 0;
    try std.testing.expectEqual(@as(u32, 7), getUint(buf[0..pos], &rpos));
    const s = getString(buf[0..pos], &rpos);
    try std.testing.expectEqualStrings("hello", s);
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement serialization helpers**

```zig
pub fn putUint(buf: []u8, pos: *usize, value: u32) void {
    std.mem.writeInt(u32, buf[pos.*..][0..4], value, .little);
    pos.* += 4;
}

pub fn putInt(buf: []u8, pos: *usize, value: i32) void {
    std.mem.writeInt(i32, buf[pos.*..][0..4], value, .little);
    pos.* += 4;
}

pub fn putString(buf: []u8, pos: *usize, str: []const u8) void {
    const len: u32 = @intCast(str.len + 1); // include null terminator
    putUint(buf, pos, len);
    @memcpy(buf[pos.* .. pos.* + str.len], str);
    buf[pos.* + str.len] = 0;
    pos.* += alignUp(len, 4);
}

pub fn getUint(buf: []const u8, pos: *usize) u32 {
    const val = std.mem.readInt(u32, buf[pos.*..][0..4], .little);
    pos.* += 4;
    return val;
}

pub fn getInt(buf: []const u8, pos: *usize) i32 {
    const val = std.mem.readInt(i32, buf[pos.*..][0..4], .little);
    pos.* += 4;
    return val;
}

pub fn getString(buf: []const u8, pos: *usize) []const u8 {
    const len = getUint(buf, pos);
    const str = buf[pos.* .. pos.* + len - 1]; // exclude null
    pos.* += alignUp(len, 4);
    return str;
}

pub fn getArray(buf: []const u8, pos: *usize) []const u8 {
    const len = getUint(buf, pos);
    const data = buf[pos.* .. pos.* + len];
    pos.* += alignUp(len, 4);
    return data;
}
```

- [ ] **Step 4: Run tests to verify they pass**

- [ ] **Step 5: Commit**

```bash
cd ~/zt && git add src/backend/wayland/wire.zig
git commit -m "feat(wayland): argument serialization helpers (uint, int, string, array)"
```

---

## Chunk 2: Core Protocol and Window Display

### Task 7: Core Protocol — Display, Registry, Globals

**Files:**
- Create: `zt/src/backend/wayland/core.zig`

Implement `wl_display` (ID=1), `wl_registry` global binding, and the registry event dispatch loop.

- [ ] **Step 1: Define Wayland protocol constants**

```zig
// core.zig — interface opcodes and event codes for core protocol
const wire = @import("wire.zig");

// wl_display requests
const WL_DISPLAY_SYNC = 0;
const WL_DISPLAY_GET_REGISTRY = 1;

// wl_display events
const WL_DISPLAY_ERROR = 0;
const WL_DISPLAY_DELETE_ID = 1;

// wl_registry requests
const WL_REGISTRY_BIND = 0;

// wl_registry events
const WL_REGISTRY_GLOBAL = 0;
const WL_REGISTRY_GLOBAL_REMOVE = 1;

// wl_callback events
const WL_CALLBACK_DONE = 0;

// wl_compositor requests
const WL_COMPOSITOR_CREATE_SURFACE = 0;

// wl_surface requests
const WL_SURFACE_DESTROY = 0;
const WL_SURFACE_ATTACH = 1;
const WL_SURFACE_DAMAGE = 2;
const WL_SURFACE_FRAME = 3;
const WL_SURFACE_SET_OPAQUE_REGION = 4;
const WL_SURFACE_COMMIT = 6;
const WL_SURFACE_SET_BUFFER_SCALE = 8;
const WL_SURFACE_DAMAGE_BUFFER = 9;

// wl_shm requests
const WL_SHM_CREATE_POOL = 0;
// wl_shm events
const WL_SHM_FORMAT = 0;

// wl_shm_pool requests
const WL_SHM_POOL_CREATE_BUFFER = 0;
const WL_SHM_POOL_DESTROY = 2;

// wl_buffer events
const WL_BUFFER_RELEASE = 0;

// wl_shm_format
const SHM_FORMAT_ARGB8888 = 0;
```

- [ ] **Step 2: Implement Globals struct for tracking bound interfaces**

```zig
pub const Globals = struct {
    compositor_id: u32 = 0,
    shm_id: u32 = 0,
    xdg_wm_base_id: u32 = 0,
    seat_id: u32 = 0,
    data_device_manager_id: u32 = 0,
    text_input_manager_id: u32 = 0,
    decoration_manager_id: u32 = 0,
    primary_selection_manager_id: u32 = 0,
    cursor_shape_manager_id: u32 = 0,

    // Bound object IDs (assigned after registry.bind)
    compositor: u32 = 0,
    shm: u32 = 0,
    xdg_wm_base: u32 = 0,
    seat: u32 = 0,
    data_device_manager: u32 = 0,
    text_input_manager: u32 = 0,
    decoration_manager: u32 = 0,
    primary_selection_manager: u32 = 0,
    cursor_shape_manager: u32 = 0,
    surface: u32 = 0,

    argb8888_supported: bool = false,
};
```

- [ ] **Step 3: Implement registry global event parsing and bind requests**

```zig
pub fn getRegistry(conn: *wire.Connection) !u32 {
    const registry_id = conn.id_alloc.next();
    var buf: [4]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&buf, &pos, registry_id);
    try conn.sendMessage(1, WL_DISPLAY_GET_REGISTRY, buf[0..pos], &.{});
    return registry_id;
}

pub fn sync(conn: *wire.Connection) !u32 {
    const callback_id = conn.id_alloc.next();
    var buf: [4]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&buf, &pos, callback_id);
    try conn.sendMessage(1, WL_DISPLAY_SYNC, buf[0..pos], &.{});
    return callback_id;
}

pub fn handleRegistryGlobal(conn: *wire.Connection, globals: *Globals, registry_id: u32, payload: []const u8) void {
    var pos: usize = 0;
    const name = wire.getUint(payload, &pos); // global name (numeric ID)
    const interface = wire.getString(payload, &pos);
    const version = wire.getUint(payload, &pos);
    _ = version;

    // Match known interfaces and store global name for binding
    if (std.mem.eql(u8, interface, "wl_compositor")) {
        globals.compositor_id = name;
    } else if (std.mem.eql(u8, interface, "wl_shm")) {
        globals.shm_id = name;
    } else if (std.mem.eql(u8, interface, "xdg_wm_base")) {
        globals.xdg_wm_base_id = name;
    } else if (std.mem.eql(u8, interface, "wl_seat")) {
        globals.seat_id = name;
    } else if (std.mem.eql(u8, interface, "wl_data_device_manager")) {
        globals.data_device_manager_id = name;
    } else if (std.mem.eql(u8, interface, "zwp_text_input_manager_v3")) {
        globals.text_input_manager_id = name;
    } else if (std.mem.eql(u8, interface, "zxdg_decoration_manager_v1")) {
        globals.decoration_manager_id = name;
    } else if (std.mem.eql(u8, interface, "zwp_primary_selection_device_manager_v1")) {
        globals.primary_selection_manager_id = name;
    } else if (std.mem.eql(u8, interface, "wp_cursor_shape_manager_v1")) {
        globals.cursor_shape_manager_id = name;
    }
}

pub fn bindGlobals(conn: *wire.Connection, globals: *Globals, registry_id: u32) !void {
    // Bind each discovered global with registry.bind request
    if (globals.compositor_id != 0) {
        globals.compositor = try bindGlobal(conn, registry_id, globals.compositor_id, "wl_compositor", 4);
    }
    if (globals.shm_id != 0) {
        globals.shm = try bindGlobal(conn, registry_id, globals.shm_id, "wl_shm", 1);
    }
    // ... similarly for all other globals
}

fn bindGlobal(conn: *wire.Connection, registry_id: u32, name: u32, interface: []const u8, version: u32) !u32 {
    const new_id = conn.id_alloc.next();
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&buf, &pos, name);           // global name (uint arg)
    // wl_registry.bind's new_id arg has special wire encoding: (interface_string, version, id)
    wire.putString(&buf, &pos, interface);     // interface name (part of new_id triple)
    wire.putUint(&buf, &pos, version);         // interface version (part of new_id triple)
    wire.putUint(&buf, &pos, new_id);          // actual object id (part of new_id triple)
    try conn.sendMessage(registry_id, WL_REGISTRY_BIND, buf[0..pos], &.{});
    return new_id;
}
```

- [ ] **Step 4: Implement wl_display.error handler**

```zig
pub fn handleDisplayError(payload: []const u8) error{ProtocolError} {
    var pos: usize = 0;
    const object_id = wire.getUint(payload, &pos);
    const code = wire.getUint(payload, &pos);
    const message = wire.getString(payload, &pos);
    std.log.err("wayland protocol error: object={}, code={}, message={s}", .{ object_id, code, message });
    return error.ProtocolError;
}
```

- [ ] **Step 5: Commit**

```bash
cd ~/zt && git add src/backend/wayland/core.zig
git commit -m "feat(wayland): core protocol — display, registry, global binding"
```

---

### Task 8: Core Protocol — SHM Buffer Management

**Files:**
- Modify: `zt/src/backend/wayland/core.zig`

- [ ] **Step 1: Implement SHM pool creation with memfd_create**

```zig
pub const ShmBuffer = struct {
    pool_id: u32,
    buffer_ids: [2]u32,
    fd: posix.fd_t,
    data: []align(4096) u8,
    width: u32,
    height: u32,
    stride: u32,
    page_size: usize,    // single buffer size
    current: u1 = 0,
    released: [2]bool = .{ true, true }, // both start as available

    pub fn getPixels(self: *ShmBuffer) []u8 {
        const offset = @as(usize, self.current) * self.page_size;
        return self.data[offset .. offset + self.page_size];
    }
};

pub fn createShmBuffers(conn: *wire.Connection, globals: *Globals, width: u32, height: u32) !ShmBuffer {
    const stride = width * 4; // ARGB8888
    const page_size = stride * height;
    const total_size = page_size * 2; // double buffer

    // memfd_create
    const fd = std.posix.memfd_createZ("zt-shm", .{ .CLOEXEC = true }) catch return error.MemfdCreateFailed;
    errdefer posix.close(fd);

    std.posix.ftruncate(fd, @intCast(total_size)) catch return error.FtruncateFailed;

    const data = std.posix.mmap(null, total_size, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0) catch return error.MmapFailed;

    // wl_shm.create_pool(fd, size)
    const pool_id = conn.id_alloc.next();
    {
        var buf: [8]u8 = undefined;
        var pos: usize = 0;
        wire.putUint(&buf, &pos, pool_id);
        wire.putInt(&buf, &pos, @intCast(total_size));
        try conn.sendMessage(globals.shm, WL_SHM_CREATE_POOL, buf[0..pos], &.{fd});
    }

    // Create two buffers from pool
    var buffer_ids: [2]u32 = undefined;
    for (0..2) |i| {
        buffer_ids[i] = conn.id_alloc.next();
        var buf: [24]u8 = undefined;
        var pos: usize = 0;
        wire.putUint(&buf, &pos, buffer_ids[i]);   // new_id
        wire.putInt(&buf, &pos, @intCast(i * page_size)); // offset
        wire.putInt(&buf, &pos, @intCast(width));   // width
        wire.putInt(&buf, &pos, @intCast(height));  // height
        wire.putInt(&buf, &pos, @intCast(stride));  // stride
        wire.putUint(&buf, &pos, SHM_FORMAT_ARGB8888); // format
        try conn.sendMessage(pool_id, WL_SHM_POOL_CREATE_BUFFER, buf[0..pos], &.{});
    }

    return .{
        .pool_id = pool_id,
        .buffer_ids = buffer_ids,
        .fd = fd,
        .data = @alignCast(data),
        .width = width,
        .height = height,
        .stride = stride,
        .page_size = page_size,
        .current = 0,
    };
}
```

- [ ] **Step 2: Implement surface attach/damage/commit helpers**

```zig
pub fn surfaceAttach(conn: *wire.Connection, surface_id: u32, buffer_id: u32) !void {
    var buf: [12]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&buf, &pos, buffer_id); // buffer
    wire.putInt(&buf, &pos, 0);          // x offset
    wire.putInt(&buf, &pos, 0);          // y offset
    try conn.sendMessage(surface_id, WL_SURFACE_ATTACH, buf[0..pos], &.{});
}

pub fn surfaceDamageBuffer(conn: *wire.Connection, surface_id: u32, x: i32, y: i32, w: i32, h: i32) !void {
    var buf: [16]u8 = undefined;
    var pos: usize = 0;
    wire.putInt(&buf, &pos, x);
    wire.putInt(&buf, &pos, y);
    wire.putInt(&buf, &pos, w);
    wire.putInt(&buf, &pos, h);
    try conn.sendMessage(surface_id, WL_SURFACE_DAMAGE_BUFFER, buf[0..pos], &.{});
}

pub fn surfaceCommit(conn: *wire.Connection, surface_id: u32) !void {
    try conn.sendMessage(surface_id, WL_SURFACE_COMMIT, &.{}, &.{});
}

pub fn surfaceSetBufferScale(conn: *wire.Connection, surface_id: u32, scale: i32) !void {
    var buf: [4]u8 = undefined;
    var pos: usize = 0;
    wire.putInt(&buf, &pos, scale);
    try conn.sendMessage(surface_id, WL_SURFACE_SET_BUFFER_SCALE, buf[0..pos], &.{});
}
```

- [ ] **Step 3: Commit**

```bash
cd ~/zt && git add src/backend/wayland/core.zig
git commit -m "feat(wayland): SHM double buffer creation and surface helpers"
```

---

### Task 9: XDG Shell — Window Management

**Files:**
- Create: `zt/src/backend/wayland/xdg_shell.zig`

- [ ] **Step 1: Define xdg_shell protocol constants**

```zig
const wire = @import("wire.zig");

// xdg_wm_base requests
const XDG_WM_BASE_DESTROY = 0;
const XDG_WM_BASE_CREATE_POSITIONER = 1;
const XDG_WM_BASE_GET_XDG_SURFACE = 2;
const XDG_WM_BASE_PONG = 3;

// xdg_wm_base events
const XDG_WM_BASE_PING = 0;

// xdg_surface requests
const XDG_SURFACE_DESTROY = 0;
const XDG_SURFACE_GET_TOPLEVEL = 1;
const XDG_SURFACE_SET_WINDOW_GEOMETRY = 2;
const XDG_SURFACE_ACK_CONFIGURE = 4;

// xdg_surface events
const XDG_SURFACE_CONFIGURE = 0;

// xdg_toplevel requests
const XDG_TOPLEVEL_DESTROY = 0;
const XDG_TOPLEVEL_SET_PARENT = 1;
const XDG_TOPLEVEL_SET_TITLE = 2;
const XDG_TOPLEVEL_SET_APP_ID = 3;
const XDG_TOPLEVEL_SET_MIN_SIZE = 8;

// xdg_toplevel events
const XDG_TOPLEVEL_CONFIGURE = 0;
const XDG_TOPLEVEL_CLOSE = 1;

// xdg_toplevel states
pub const STATE_MAXIMIZED = 1;
pub const STATE_FULLSCREEN = 2;
pub const STATE_RESIZING = 3;
pub const STATE_ACTIVATED = 4;
```

- [ ] **Step 2: Implement xdg surface/toplevel creation and configure handshake**

```zig
pub fn getXdgSurface(conn: *wire.Connection, wm_base_id: u32, surface_id: u32) !u32 {
    const xdg_surface_id = conn.id_alloc.next();
    var buf: [8]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&buf, &pos, xdg_surface_id);
    wire.putUint(&buf, &pos, surface_id);
    try conn.sendMessage(wm_base_id, XDG_WM_BASE_GET_XDG_SURFACE, buf[0..pos], &.{});
    return xdg_surface_id;
}

pub fn getToplevel(conn: *wire.Connection, xdg_surface_id: u32) !u32 {
    const toplevel_id = conn.id_alloc.next();
    var buf: [4]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&buf, &pos, toplevel_id);
    try conn.sendMessage(xdg_surface_id, XDG_SURFACE_GET_TOPLEVEL, buf[0..pos], &.{});
    return toplevel_id;
}

pub fn setTitle(conn: *wire.Connection, toplevel_id: u32, title: []const u8) !void {
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    wire.putString(&buf, &pos, title);
    try conn.sendMessage(toplevel_id, XDG_TOPLEVEL_SET_TITLE, buf[0..pos], &.{});
}

pub fn setAppId(conn: *wire.Connection, toplevel_id: u32, app_id: []const u8) !void {
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    wire.putString(&buf, &pos, app_id);
    try conn.sendMessage(toplevel_id, XDG_TOPLEVEL_SET_APP_ID, buf[0..pos], &.{});
}

pub fn setMinSize(conn: *wire.Connection, toplevel_id: u32, w: i32, h: i32) !void {
    var buf: [8]u8 = undefined;
    var pos: usize = 0;
    wire.putInt(&buf, &pos, w);
    wire.putInt(&buf, &pos, h);
    try conn.sendMessage(toplevel_id, XDG_TOPLEVEL_SET_MIN_SIZE, buf[0..pos], &.{});
}

pub fn ackConfigure(conn: *wire.Connection, xdg_surface_id: u32, serial: u32) !void {
    var buf: [4]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&buf, &pos, serial);
    try conn.sendMessage(xdg_surface_id, XDG_SURFACE_ACK_CONFIGURE, buf[0..pos], &.{});
}

pub fn pong(conn: *wire.Connection, wm_base_id: u32, serial: u32) !void {
    var buf: [4]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&buf, &pos, serial);
    try conn.sendMessage(wm_base_id, XDG_WM_BASE_PONG, buf[0..pos], &.{});
}

pub const ConfigureEvent = struct {
    width: u32,
    height: u32,
};

pub const ConfigureState = struct {
    activated: bool = false,
};

pub fn parseToplevelConfigure(payload: []const u8) struct { event: ConfigureEvent, state: ConfigureState } {
    var pos: usize = 0;
    const width = wire.getInt(payload, &pos);
    const height = wire.getInt(payload, &pos);
    // Must consume the states array to keep parser position correct
    const states_data = wire.getArray(payload, &pos);
    var cstate = ConfigureState{};
    // Scan states (array of uint32 values)
    const states = std.mem.bytesAsSlice(u32, states_data);
    for (states) |s| {
        if (s == STATE_ACTIVATED) cstate.activated = true;
    }
    return .{
        .event = .{
            .width = if (width > 0) @intCast(width) else 0,
            .height = if (height > 0) @intCast(height) else 0,
        },
        .state = cstate,
    };
}
```

- [ ] **Step 3: Commit**

```bash
cd ~/zt && git add src/backend/wayland/xdg_shell.zig
git commit -m "feat(wayland): xdg-shell surface/toplevel creation and configure handshake"
```

---

### Task 10: Decoration Protocol

**Files:**
- Create: `zt/src/backend/wayland/decoration.zig`

- [ ] **Step 1: Implement decoration manager**

```zig
const wire = @import("wire.zig");

const ZXDG_DECORATION_GET_TOPLEVEL_DECORATION = 0;
const ZXDG_TOPLEVEL_DECORATION_DESTROY = 0;
const ZXDG_TOPLEVEL_DECORATION_SET_MODE = 1;
const ZXDG_TOPLEVEL_DECORATION_CONFIGURE = 0;

pub const MODE_CLIENT_SIDE = 1;
pub const MODE_SERVER_SIDE = 2;

pub fn getToplevelDecoration(conn: *wire.Connection, manager_id: u32, toplevel_id: u32) !u32 {
    const deco_id = conn.id_alloc.next();
    var buf: [8]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&buf, &pos, deco_id);
    wire.putUint(&buf, &pos, toplevel_id);
    try conn.sendMessage(manager_id, ZXDG_DECORATION_GET_TOPLEVEL_DECORATION, buf[0..pos], &.{});
    return deco_id;
}

pub fn setMode(conn: *wire.Connection, deco_id: u32, mode: u32) !void {
    var buf: [4]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&buf, &pos, mode);
    try conn.sendMessage(deco_id, ZXDG_TOPLEVEL_DECORATION_SET_MODE, buf[0..pos], &.{});
}
```

- [ ] **Step 2: Commit**

```bash
cd ~/zt && git add src/backend/wayland/decoration.zig
git commit -m "feat(wayland): xdg-decoration SSD protocol"
```

---

### Task 11: WaylandBackend Struct — Init, Display, Present

**Files:**
- Rewrite: `zt/src/backend/wayland.zig`

This is where everything comes together. The backend struct implements the full public API.

- [ ] **Step 1: Implement WaylandBackend struct with init/deinit**

Full init sequence: connect -> get_registry -> sync roundtrip -> bind globals -> create surface -> xdg surface/toplevel -> set title/app_id -> decoration -> surface.commit -> wait for configure -> create SHM buffers -> `wl_surface.set_buffer_scale(config.scale)` -> first frame render. Also create internal epoll fd and register: Wayland socket fd.

Define the Event union matching X11:
```zig
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
```

Define all public API functions: `init`, `deinit`, `postInit`, `getBuffer`, `getStride`, `getWidth`, `getHeight`, `getBpp`, `markDirtyRows`, `present`, `flush`, `resize`, `queryGeometry`, `getFd`, `pollEvents`.

No-op stubs: `saveConsoleState`, `restoreConsoleState`, `setupVtSwitching`, `releaseVt`, `acquireVt`.

- [ ] **Step 2: Implement getBuffer/getStride/getWidth/getHeight/getBpp**

These just delegate to the SHM buffer:
```zig
pub fn getBuffer(self: *WaylandBackend) []u8 {
    return self.shm_buffers.getPixels();
}
pub fn getStride(self: *WaylandBackend) u32 { return self.shm_buffers.stride; }
pub fn getWidth(self: *WaylandBackend) u32 { return self.width; }
pub fn getHeight(self: *WaylandBackend) u32 { return self.height; }
pub fn getBpp(self: *WaylandBackend) u32 { return 4; }
```

- [ ] **Step 3: Implement present/flush with dirty row tracking**

```zig
pub fn present(self: *WaylandBackend) void {
    if (self.dirty_y_min > self.dirty_y_max) return; // nothing dirty

    // Wait for current buffer to be released
    const buf_idx = self.shm_buffers.current;
    if (!self.shm_buffers.released[buf_idx]) {
        // Buffer still in use by compositor — skip this frame
        return;
    }

    // Copy dirty region to next back buffer BEFORE submitting current buffer.
    // After submit, compositor owns current buffer — we must not read from it.
    const next: u1 = buf_idx ^ 1;
    {
        const src = self.shm_buffers.data;
        const ps = self.shm_buffers.page_size;
        const cur_off = @as(usize, buf_idx) * ps;
        const next_off = @as(usize, next) * ps;
        const y_start = self.dirty_y_min * self.shm_buffers.stride;
        const y_end = self.dirty_y_max * self.shm_buffers.stride;
        @memcpy(src[next_off + y_start .. next_off + y_end], src[cur_off + y_start .. cur_off + y_end]);
    }

    core.surfaceAttach(&self.conn, self.surface_id, self.shm_buffers.buffer_ids[buf_idx]) catch return;
    core.surfaceDamageBuffer(&self.conn, self.surface_id, 0, @intCast(self.dirty_y_min), @intCast(self.width), @intCast(self.dirty_y_max - self.dirty_y_min)) catch return;
    core.surfaceCommit(&self.conn, self.surface_id) catch return;

    self.shm_buffers.released[buf_idx] = false;
    self.shm_buffers.current = next; // swap to pre-copied buffer

    self.dirty_y_min = std.math.maxInt(u32);
    self.dirty_y_max = 0;
}

pub fn flush(self: *WaylandBackend) void {
    _ = posix.write(self.conn.fd, self.conn.send_buf[0..0]) catch {};
    // Actual flush of Wayland socket
}
```

- [ ] **Step 4: Implement internal epoll and getFd**

Create internal epoll wrapping wayland socket fd. `getFd()` returns the internal epoll fd.

```zig
pub fn getFd(self: *WaylandBackend) ?posix.fd_t {
    return self.internal_epoll_fd;
}
```

- [ ] **Step 5: Verify build compiles**

Run: `cd ~/zt && zig build -Dbackend=wayland 2>&1 | tail -20`
Expected: Compiles successfully (even if it can't actually run without a compositor)

- [ ] **Step 6: Commit**

```bash
cd ~/zt && git add src/backend/wayland.zig
git commit -m "feat(wayland): WaylandBackend struct with init, present, buffer management"
```

---

## Chunk 3: Input and IME

### Task 12: Seat — Keyboard Input with xkbcommon

**Files:**
- Create: `zt/src/backend/wayland/seat.zig`

- [ ] **Step 1: Define seat/keyboard protocol constants**

```zig
const wire = @import("wire.zig");
const std = @import("std");
const posix = std.posix;

const c = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
});

// wl_seat requests
const WL_SEAT_GET_POINTER = 0;
const WL_SEAT_GET_KEYBOARD = 1;

// wl_seat events
const WL_SEAT_CAPABILITIES = 0;
const WL_SEAT_NAME = 1;

// wl_keyboard events
pub const WL_KEYBOARD_KEYMAP = 0;
pub const WL_KEYBOARD_ENTER = 1;
pub const WL_KEYBOARD_LEAVE = 2;
pub const WL_KEYBOARD_KEY = 3;
pub const WL_KEYBOARD_MODIFIERS = 4;
pub const WL_KEYBOARD_REPEAT_INFO = 5;

// Seat capabilities
const CAPABILITY_POINTER = 1;
const CAPABILITY_KEYBOARD = 2;
```

- [ ] **Step 2: Implement keyboard state management**

```zig
pub const KeyboardState = struct {
    xkb_context: ?*c.xkb_context = null,
    xkb_keymap: ?*c.xkb_keymap = null,
    xkb_state: ?*c.xkb_state = null,

    // Key repeat
    repeat_rate: i32 = 0,   // keys per second
    repeat_delay: i32 = 0,  // ms before repeat starts
    repeat_key: ?u32 = null, // currently repeating key
    repeat_timer_fd: posix.fd_t = -1,

    // Focus
    focused: bool = false,
    last_serial: u32 = 0,

    pub fn init() KeyboardState {
        return .{
            .xkb_context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS),
        };
    }

    pub fn deinit(self: *KeyboardState) void {
        if (self.xkb_state) |s| c.xkb_state_unref(s);
        if (self.xkb_keymap) |k| c.xkb_keymap_unref(k);
        if (self.xkb_context) |ctx| c.xkb_context_unref(ctx);
        if (self.repeat_timer_fd >= 0) posix.close(self.repeat_timer_fd);
    }

    pub fn handleKeymap(self: *KeyboardState, fd: posix.fd_t, size: u32) void {
        const data = posix.mmap(null, size, posix.PROT.READ, .{ .TYPE = .PRIVATE }, fd, 0) catch return;
        defer posix.munmap(data);
        posix.close(fd);

        const map_str: [*:0]const u8 = @ptrCast(data.ptr);
        const keymap = c.xkb_keymap_new_from_string(self.xkb_context, map_str, c.XKB_KEYMAP_FORMAT_TEXT_V1, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return;

        if (self.xkb_state) |s| c.xkb_state_unref(s);
        if (self.xkb_keymap) |k| c.xkb_keymap_unref(k);

        self.xkb_keymap = keymap;
        self.xkb_state = c.xkb_state_new(keymap);
    }

    pub fn handleModifiers(self: *KeyboardState, depressed: u32, latched: u32, locked: u32, group: u32) void {
        if (self.xkb_state) |state| {
            _ = c.xkb_state_update_mask(state, depressed, latched, locked, 0, 0, group);
        }
    }

    pub fn getUtf8(self: *KeyboardState, keycode: u32) ?[]const u8 {
        const state = self.xkb_state orelse return null;
        var buf: [32]u8 = undefined;
        // xkbcommon uses X11-style keycodes (evdev + 8) internally, even on Wayland.
        // Wayland delivers raw evdev keycodes, so we add 8 for xkbcommon's API.
        const len = c.xkb_state_key_get_utf8(state, keycode + 8, &buf, buf.len);
        if (len <= 0) return null;
        return buf[0..@intCast(len)];
    }
};
```

- [ ] **Step 3: Implement key repeat via timerfd**

```zig
    pub fn startRepeat(self: *KeyboardState, key: u32) void {
        if (self.repeat_rate <= 0) return;
        self.repeat_key = key;

        if (self.repeat_timer_fd < 0) {
            const linux = std.os.linux;
            const raw = linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true });
            const fd_isize: isize = @bitCast(raw);
            if (fd_isize < 0) return;
            self.repeat_timer_fd = @intCast(fd_isize);
        }

        const linux = std.os.linux;
        const delay_sec: isize = @divFloor(self.repeat_delay, 1000);
        const delay_nsec: isize = @rem(self.repeat_delay, 1000) * 1_000_000;
        const interval_ms = @divFloor(1000, self.repeat_rate);
        const int_sec: isize = @divFloor(interval_ms, 1000);
        const int_nsec: isize = @rem(interval_ms, 1000) * 1_000_000;

        const spec = linux.itimerspec{
            .it_value = .{ .sec = delay_sec, .nsec = delay_nsec },
            .it_interval = .{ .sec = int_sec, .nsec = int_nsec },
        };
        _ = linux.timerfd_settime(self.repeat_timer_fd, .{}, &spec, null);
    }

    pub fn stopRepeat(self: *KeyboardState) void {
        self.repeat_key = null;
        if (self.repeat_timer_fd >= 0) {
            const linux = std.os.linux;
            const zero = linux.itimerspec{
                .it_value = .{ .sec = 0, .nsec = 0 },
                .it_interval = .{ .sec = 0, .nsec = 0 },
            };
            _ = linux.timerfd_settime(self.repeat_timer_fd, .{}, &zero, null);
        }
    }
```

- [ ] **Step 4: Implement seat request helpers (get_keyboard, get_pointer)**

```zig
pub fn getKeyboard(conn: *wire.Connection, seat_id: u32) !u32 {
    const kbd_id = conn.id_alloc.next();
    var buf: [4]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&buf, &pos, kbd_id);
    try conn.sendMessage(seat_id, WL_SEAT_GET_KEYBOARD, buf[0..pos], &.{});
    return kbd_id;
}

pub fn getPointer(conn: *wire.Connection, seat_id: u32) !u32 {
    const ptr_id = conn.id_alloc.next();
    var buf: [4]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&buf, &pos, ptr_id);
    try conn.sendMessage(seat_id, WL_SEAT_GET_POINTER, buf[0..pos], &.{});
    return ptr_id;
}
```

- [ ] **Step 5: Register key repeat timerfd in internal epoll**

After `startRepeat` creates the timerfd (first key press), register it in the backend's internal epoll fd. Add a helper in WaylandBackend:
```zig
// Called once when repeat_timer_fd is first created
fn registerRepeatTimer(self: *WaylandBackend) void {
    if (self.keyboard.repeat_timer_fd >= 0) {
        epollAdd(self.internal_epoll_fd, self.keyboard.repeat_timer_fd, EPOLL_TAG_REPEAT) catch {};
    }
}
```

Define `EPOLL_TAG_REPEAT` and `EPOLL_TAG_CLIPBOARD` constants for internal epoll dispatch.

- [ ] **Step 6: Commit**

```bash
cd ~/zt && git add src/backend/wayland/seat.zig
git commit -m "feat(wayland): keyboard input with xkbcommon keymap and key repeat"
```

---

### Task 13: Pointer and Cursor Shape

**Files:**
- Modify: `zt/src/backend/wayland/seat.zig`

- [ ] **Step 1: Add pointer event constants and cursor shape protocol**

```zig
// wl_pointer events
pub const WL_POINTER_ENTER = 0;
pub const WL_POINTER_LEAVE = 1;
pub const WL_POINTER_MOTION = 2;
pub const WL_POINTER_BUTTON = 3;

// wp_cursor_shape_manager_v1 requests
const WP_CURSOR_SHAPE_MANAGER_GET_POINTER = 1;

// wp_cursor_shape_device_v1 requests
const WP_CURSOR_SHAPE_DEVICE_SET_SHAPE = 0;

// wp_cursor_shape_device_v1 shapes
const CURSOR_DEFAULT = 1;

pub fn getCursorShapeDevice(conn: *wire.Connection, manager_id: u32, pointer_id: u32) !u32 {
    const device_id = conn.id_alloc.next();
    var buf: [8]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&buf, &pos, device_id);
    wire.putUint(&buf, &pos, pointer_id);
    try conn.sendMessage(manager_id, WP_CURSOR_SHAPE_MANAGER_GET_POINTER, buf[0..pos], &.{});
    return device_id;
}

pub fn setCursorShape(conn: *wire.Connection, device_id: u32, serial: u32, shape: u32) !void {
    var buf: [8]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&buf, &pos, serial);
    wire.putUint(&buf, &pos, shape);
    try conn.sendMessage(device_id, WP_CURSOR_SHAPE_DEVICE_SET_SHAPE, buf[0..pos], &.{});
}

/// Fallback cursor when wp_cursor_shape_manager_v1 is unavailable:
/// Create a 1x1 opaque wl_surface and set it as cursor via wl_pointer.set_cursor.
/// Not pretty, but functional — the cursor will be a single pixel dot.
pub fn setFallbackCursor(conn: *wire.Connection, pointer_id: u32, serial: u32, compositor_id: u32) !u32 {
    // Create a 1x1 cursor surface
    const cursor_surface_id = conn.id_alloc.next();
    {
        var buf: [4]u8 = undefined;
        var pos: usize = 0;
        wire.putUint(&buf, &pos, cursor_surface_id);
        try conn.sendMessage(compositor_id, 0, buf[0..pos], &.{}); // create_surface
    }

    // Create a tiny SHM buffer for the cursor (1x1 ARGB8888 = 4 bytes)
    const cursor_fd = std.posix.memfd_createZ("zt-cursor", .{ .CLOEXEC = true }) catch return error.MemfdCreateFailed;
    std.posix.ftruncate(cursor_fd, 4) catch return error.FtruncateFailed;
    const cursor_data = std.posix.mmap(null, 4, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, cursor_fd, 0) catch return error.MmapFailed;
    // White opaque pixel
    @as(*u32, @ptrCast(@alignCast(cursor_data.ptr))).* = 0xFFFFFFFF;
    // (create pool + buffer + attach + commit for cursor surface, then set_cursor)
    // wl_pointer.set_cursor(serial, surface, hotspot_x=0, hotspot_y=0)
    {
        var buf: [16]u8 = undefined;
        var pos: usize = 0;
        wire.putUint(&buf, &pos, serial);
        wire.putUint(&buf, &pos, cursor_surface_id);
        wire.putInt(&buf, &pos, 0); // hotspot_x
        wire.putInt(&buf, &pos, 0); // hotspot_y
        // WL_POINTER_SET_CURSOR = 0
        try conn.sendMessage(pointer_id, 0, buf[0..pos], &.{});
    }
    return cursor_surface_id;
}
```

- [ ] **Step 2: Commit**

```bash
cd ~/zt && git add src/backend/wayland/seat.zig
git commit -m "feat(wayland): pointer events and wp_cursor_shape for cursor display"
```

---

### Task 14: IME — text-input-v3

**Files:**
- Create: `zt/src/backend/wayland/text_input.zig`

- [ ] **Step 1: Implement text-input-v3 protocol**

```zig
const wire = @import("wire.zig");

// zwp_text_input_manager_v3 requests
const ZWP_TEXT_INPUT_MANAGER_GET_TEXT_INPUT = 0;

// zwp_text_input_v3 requests
const ZWP_TEXT_INPUT_ENABLE = 0;
const ZWP_TEXT_INPUT_DISABLE = 1;
const ZWP_TEXT_INPUT_SET_SURROUNDING_TEXT = 2;
const ZWP_TEXT_INPUT_SET_TEXT_CHANGE_CAUSE = 3;
const ZWP_TEXT_INPUT_SET_CONTENT_TYPE = 4;
const ZWP_TEXT_INPUT_SET_CURSOR_RECTANGLE = 5;
const ZWP_TEXT_INPUT_COMMIT = 6;

// zwp_text_input_v3 events
pub const ZWP_TEXT_INPUT_ENTER = 0;
pub const ZWP_TEXT_INPUT_LEAVE = 1;
pub const ZWP_TEXT_INPUT_PREEDIT_STRING = 2;
pub const ZWP_TEXT_INPUT_COMMIT_STRING = 3;
pub const ZWP_TEXT_INPUT_DELETE_SURROUNDING_TEXT = 4;
pub const ZWP_TEXT_INPUT_DONE = 5;

pub const TextInputState = struct {
    id: u32 = 0,
    enabled: bool = false,
    preedit_text: [256]u8 = undefined,
    preedit_len: usize = 0,
    pending_commit: [256]u8 = undefined,
    pending_commit_len: usize = 0,
    has_pending_commit: bool = false,

    pub fn preeditSlice(self: *const TextInputState) []const u8 {
        return self.preedit_text[0..self.preedit_len];
    }
};

pub fn getTextInput(conn: *wire.Connection, manager_id: u32, seat_id: u32) !u32 {
    const text_input_id = conn.id_alloc.next();
    var buf: [8]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&buf, &pos, text_input_id);
    wire.putUint(&buf, &pos, seat_id);
    try conn.sendMessage(manager_id, ZWP_TEXT_INPUT_MANAGER_GET_TEXT_INPUT, buf[0..pos], &.{});
    return text_input_id;
}

pub fn enable(conn: *wire.Connection, text_input_id: u32) !void {
    try conn.sendMessage(text_input_id, ZWP_TEXT_INPUT_ENABLE, &.{}, &.{});
}

pub fn disable(conn: *wire.Connection, text_input_id: u32) !void {
    try conn.sendMessage(text_input_id, ZWP_TEXT_INPUT_DISABLE, &.{}, &.{});
}

pub fn setContentType(conn: *wire.Connection, text_input_id: u32, hint: u32, purpose: u32) !void {
    var buf: [8]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&buf, &pos, hint);
    wire.putUint(&buf, &pos, purpose);
    try conn.sendMessage(text_input_id, ZWP_TEXT_INPUT_SET_CONTENT_TYPE, buf[0..pos], &.{});
}

pub fn commit(conn: *wire.Connection, text_input_id: u32) !void {
    try conn.sendMessage(text_input_id, ZWP_TEXT_INPUT_COMMIT, &.{}, &.{});
}

pub fn handlePreeditString(state: *TextInputState, payload: []const u8) void {
    var pos: usize = 0;
    const text = wire.getString(payload, &pos);
    // cursor_begin and cursor_end follow but we don't use them
    const len = @min(text.len, state.preedit_text.len);
    @memcpy(state.preedit_text[0..len], text[0..len]);
    state.preedit_len = len;
}

pub fn handleCommitString(state: *TextInputState, payload: []const u8) void {
    var pos: usize = 0;
    const text = wire.getString(payload, &pos);
    const len = @min(text.len, state.pending_commit.len);
    @memcpy(state.pending_commit[0..len], text[0..len]);
    state.pending_commit_len = len;
    state.has_pending_commit = true;
}

pub fn handleDone(state: *TextInputState) void {
    // Batch apply: commit_string clears preedit
    if (state.has_pending_commit) {
        state.preedit_len = 0; // clear preedit on commit
    }
}
```

- [ ] **Step 2: Commit**

```bash
cd ~/zt && git add src/backend/wayland/text_input.zig
git commit -m "feat(wayland): text-input-v3 IME with preedit and commit"
```

---

## Chunk 4: Clipboard and Event Dispatch

### Task 15: Clipboard — wl_data_device + Primary Selection

**Files:**
- Create: `zt/src/backend/wayland/clipboard.zig`

- [ ] **Step 1: Define clipboard protocol constants**

```zig
const wire = @import("wire.zig");
const std = @import("std");
const posix = std.posix;

// wl_data_device_manager requests
const DDM_CREATE_DATA_SOURCE = 0;
const DDM_GET_DATA_DEVICE = 1;

// wl_data_device events
pub const DATA_DEVICE_DATA_OFFER = 0;
pub const DATA_DEVICE_ENTER = 1;
pub const DATA_DEVICE_LEAVE = 2;
pub const DATA_DEVICE_MOTION = 3;
pub const DATA_DEVICE_DROP = 4;
pub const DATA_DEVICE_SELECTION = 5;

// wl_data_offer requests
const DATA_OFFER_ACCEPT = 0;
const DATA_OFFER_RECEIVE = 1;
const DATA_OFFER_DESTROY = 2;

// wl_data_offer events
pub const DATA_OFFER_OFFER = 0;

// primary selection (same pattern)
const PRIMARY_MANAGER_GET_DEVICE = 1;
pub const PRIMARY_DEVICE_DATA_OFFER = 0;
pub const PRIMARY_DEVICE_SELECTION = 1;
const PRIMARY_OFFER_RECEIVE = 0;
pub const PRIMARY_OFFER_OFFER = 0;
```

- [ ] **Step 2: Implement clipboard state and receive helpers**

```zig
pub const ClipboardState = struct {
    // wl_data_device
    data_device_id: u32 = 0,
    current_offer_id: u32 = 0,
    offer_has_text: bool = false,

    // primary selection
    primary_device_id: u32 = 0,
    primary_offer_id: u32 = 0,
    primary_has_text: bool = false,

    // Paste pipe (for async read)
    paste_pipe_fd: posix.fd_t = -1,
    paste_buf: [4096]u8 = undefined,
    paste_len: usize = 0,
};

pub fn getDataDevice(conn: *wire.Connection, manager_id: u32, seat_id: u32) !u32 {
    const id = conn.id_alloc.next();
    var buf: [8]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&buf, &pos, id);
    wire.putUint(&buf, &pos, seat_id);
    try conn.sendMessage(manager_id, DDM_GET_DATA_DEVICE, buf[0..pos], &.{});
    return id;
}

pub fn getPrimaryDevice(conn: *wire.Connection, manager_id: u32, seat_id: u32) !u32 {
    const id = conn.id_alloc.next();
    var buf: [8]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&buf, &pos, id);
    wire.putUint(&buf, &pos, seat_id);
    try conn.sendMessage(manager_id, PRIMARY_MANAGER_GET_DEVICE, buf[0..pos], &.{});
    return id;
}

/// Initiate paste: create pipe, send receive request, return read fd.
/// The fd arg is passed out-of-band via SCM_RIGHTS — NOT in the message payload.
pub fn requestPaste(conn: *wire.Connection, offer_id: u32, state: *ClipboardState) !void {
    const pipe = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const read_fd = pipe[0];
    const write_fd = pipe[1];

    // data_offer.receive(mime_type: string, fd: fd)
    // fd occupies zero bytes in payload — sent only via SCM_RIGHTS
    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    wire.putString(&buf, &pos, "text/plain;charset=utf-8");
    try conn.sendMessage(offer_id, DATA_OFFER_RECEIVE, buf[0..pos], &.{write_fd});
    posix.close(write_fd);

    // Flush immediately so compositor processes the receive request
    _ = posix.write(conn.fd, &.{}) catch {};

    state.paste_pipe_fd = read_fd;
    state.paste_len = 0;
}

/// Read from paste pipe (non-blocking). Returns true if more data expected.
pub fn readPastePipe(state: *ClipboardState) bool {
    if (state.paste_pipe_fd < 0) return false;
    const remaining = state.paste_buf.len - state.paste_len;
    if (remaining == 0) {
        posix.close(state.paste_pipe_fd);
        state.paste_pipe_fd = -1;
        return false;
    }
    const n = posix.read(state.paste_pipe_fd, state.paste_buf[state.paste_len..]) catch |err| switch (err) {
        error.WouldBlock => return true,
        else => {
            posix.close(state.paste_pipe_fd);
            state.paste_pipe_fd = -1;
            return false;
        },
    };
    if (n == 0) {
        posix.close(state.paste_pipe_fd);
        state.paste_pipe_fd = -1;
        return false; // EOF — paste complete
    }
    state.paste_len += n;
    return true;
}
```

- [ ] **Step 3: Stub clipboard copy/send direction**

Copy is not functional yet (zt has no text selection), but stub the `wl_data_source.send` event handler to avoid protocol errors:

```zig
/// Stub: called when compositor requests clipboard data from us.
/// Currently no-op since zt does not support text selection yet.
pub fn handleDataSourceSend(state: *ClipboardState, fd: posix.fd_t) void {
    _ = state;
    // Write empty data and close — we have nothing to offer
    posix.close(fd);
}
```

- [ ] **Step 4: Commit**

```bash
cd ~/zt && git add src/backend/wayland/clipboard.zig
git commit -m "feat(wayland): clipboard and primary selection with pipe-based async paste"
```

---

### Task 16: Event Dispatch — pollEvents Integration

**Files:**
- Modify: `zt/src/backend/wayland.zig`

This is the central event dispatch. `pollEvents()` reads from the internal epoll, dispatches Wayland protocol events, and translates them into the backend `Event` union that main.zig consumes.

- [ ] **Step 1: Implement pollEvents**

The function:
1. `epoll_wait` on internal epoll (timeout=0, non-blocking)
2. For Wayland socket fd: `recvEvents` + loop over `nextEvent`
3. Dispatch by object_id:
   - wl_display (ID=1): error → fatal, delete_id → id_alloc.release
   - wl_registry: global/global_remove
   - xdg_wm_base: ping → pong
   - xdg_surface: configure → ack_configure
   - xdg_toplevel: configure → resize event, close → close event
   - wl_keyboard: keymap, enter (+ process held keys[] array + text_input.enable + commit), leave (+ text_input.disable + commit), key, modifiers, repeat_info
   - wl_pointer: enter → set cursor shape (wp_cursor_shape_manager_v1, or fallback 1x1 surface)
   - wl_buffer: release → mark buffer available
   - text_input: preedit_string, commit_string, done
   - data_device/primary: data_offer, selection
   - data_offer/primary_offer: offer (check mime type)
   - decoration: configure (log mode)
4. For key repeat timerfd: synthesize key event
5. For clipboard pipe fd: read paste data, emit paste event when complete

Return one Event at a time to main.zig's while loop.

- [ ] **Step 2: Implement resize handling**

On `xdg_toplevel.configure` with non-zero size:
1. Destroy old SHM buffers
2. Create new SHM buffers with new dimensions
3. Update width/height
4. Return `Event{ .resize = .{ .width = w, .height = h } }`

On width=0, height=0: use current size (no resize).

- [ ] **Step 3: Implement keyboard event translation**

On `wl_keyboard.key`:
1. Get evdev keycode from event payload
2. Get modifiers from xkb_state
3. Start/stop key repeat
4. Return `Event{ .key = .{ .keycode = keycode, .pressed = pressed, .modifiers = mods } }`

On `text_input.done` with pending commit:
1. Return `Event{ .text = .{ .data = commit_text, .len = len } }`

- [ ] **Step 4: Implement clipboard paste event**

When paste pipe reaches EOF:
1. Return `Event{ .paste = .{ .data = paste_buf, .len = paste_len } }`

Trigger paste on Ctrl+Shift+V in key handler: call `clipboard.requestPaste()`, register pipe fd in internal epoll with `EPOLL_TAG_CLIPBOARD`, deregister and close on EOF.

- [ ] **Step 5: Verify full build**

Run: `cd ~/zt && zig build -Dbackend=wayland 2>&1 | tail -10`
Expected: Clean compile

- [ ] **Step 6: Commit**

```bash
cd ~/zt && git add src/backend/wayland.zig
git commit -m "feat(wayland): event dispatch — keyboard, clipboard, resize, IME"
```

---

## Chunk 5: Integration Testing and Polish

### Task 17: Manual Integration Test — Window Displays

- [ ] **Step 1: Build and run under a Wayland compositor**

```bash
cd ~/zt && zig build -Dbackend=wayland -Doptimize=ReleaseFast
WAYLAND_DISPLAY=wayland-0 ./zig-out/bin/zt
```

Expected: zt window appears with shell prompt. If running on X11, use `WAYLAND_DISPLAY=... wayland-proxy` or test on a machine with a Wayland compositor.

- [ ] **Step 2: Test keyboard input**

Type text, verify it appears. Test modifier keys (Ctrl+C, Ctrl+D). Test arrow keys in a program like `nano` or `vim`.

- [ ] **Step 3: Test window resize**

Resize the window with the mouse or tiling WM. Verify terminal grid adjusts and content redraws correctly.

- [ ] **Step 4: Fix any issues found**

- [ ] **Step 5: Commit fixes**

```bash
cd ~/zt && git add -A && git commit -m "fix(wayland): integration test fixes"
```

---

### Task 18: IME Testing

- [ ] **Step 1: Test Japanese input with fcitx5**

Launch under a Wayland compositor with fcitx5 running. Activate Japanese input (Ctrl+Space or Zenkaku/Hankaku). Type hiragana, verify preedit appears underlined at cursor, verify commit produces correct kanji.

- [ ] **Step 2: Fix any IME issues**

- [ ] **Step 3: Commit**

```bash
cd ~/zt && git add -A && git commit -m "fix(wayland): IME integration fixes"
```

---

### Task 19: Clipboard Testing

- [ ] **Step 1: Test Ctrl+Shift+V paste**

Copy text from another Wayland application (e.g., foot, Firefox). Switch to zt, press Ctrl+Shift+V. Verify text is pasted.

- [ ] **Step 2: Test primary selection (middle-click)**

Select text in another application. Middle-click or Shift+Insert in zt. Verify paste.

- [ ] **Step 3: Fix any clipboard issues**

- [ ] **Step 4: Commit**

```bash
cd ~/zt && git add -A && git commit -m "fix(wayland): clipboard integration fixes"
```

---

### Task 20: Multi-Compositor Testing

- [ ] **Step 1: Test on Sway**

Verify window management, tiling, resize, decoration.

- [ ] **Step 2: Test on GNOME (Mutter)**

Verify SSD/CSD fallback, basic operation.

- [ ] **Step 3: Test programs: fish, vim, Claude Code**

Run each and verify correct rendering, keyboard input, and terminal behavior.

- [ ] **Step 4: Fix any compositor-specific issues**

- [ ] **Step 5: Final commit**

```bash
cd ~/zt && git add -A && git commit -m "fix(wayland): multi-compositor compatibility"
```

---

### Task 21: Update README and Bump Version

**Files:**
- Modify: `zt/README.md`
- Modify: (version constant if exists)

- [ ] **Step 1: Add Wayland to README build instructions**

Add `-Dbackend=wayland` to the build options section. Note the single dependency (xkbcommon).

- [ ] **Step 2: Update backend comparison table if present**

- [ ] **Step 3: Commit**

```bash
cd ~/zt && git add README.md
git commit -m "docs: add Wayland backend to README"
```
