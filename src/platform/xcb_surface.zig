const std = @import("std");

const c = @cImport({
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/shm.h");
    @cInclude("xcb/xcb_cursor.h");
    @cInclude("xcb/xcb_icccm.h");
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xlib-xcb.h");
});

// POSIX SHM
const posix = std.posix;

pub const CursorShape = enum {
    arrow,
    pointer, // hand cursor for links
    text, // I-beam for text inputs
};

pub const XcbSurface = struct {
    // Xlib display (kept for XIM compatibility)
    xlib_display: ?*c.Display = null,

    // XCB connection and window
    connection: ?*c.xcb_connection_t = null,
    screen: ?*c.xcb_screen_t = null,
    window: c.xcb_window_t = 0,

    // Pixel buffer (XRGB8888, native byte order)
    width: i32 = 0,
    height: i32 = 0,
    pixels: ?[*]u32 = null,
    stride: usize = 0, // in bytes

    // SHM
    shm_available: bool = false,
    shm_id: c_int = -1,
    shm_seg: c.xcb_shm_seg_t = 0,

    // Atoms
    wm_protocols: c.xcb_atom_t = 0,
    wm_delete_window: c.xcb_atom_t = 0,

    // Cursor context
    cursor_ctx: ?*c.xcb_cursor_context_t = null,
    current_cursor: c.xcb_cursor_t = 0,

    // GC for put_image fallback
    gc: c.xcb_gcontext_t = 0,

    /// Create and initialize an X11 window surface via XCB (Xlib-first for XIM compat).
    pub fn init(width: i32, height: i32, title: []const u8) !XcbSurface {
        var self = XcbSurface{};

        // Open display via Xlib first (needed for XIM compatibility)
        self.xlib_display = c.XOpenDisplay(null);
        if (self.xlib_display == null) return error.CannotOpenDisplay;
        errdefer _ = c.XCloseDisplay(self.xlib_display);

        // Get the underlying XCB connection
        self.connection = c.XGetXCBConnection(self.xlib_display);
        if (self.connection == null) return error.NoXcbConnection;

        // Let XCB own the event queue
        c.XSetEventQueueOwner(self.xlib_display, c.XCBOwnsEventQueue);

        // Get the default screen
        const setup = c.xcb_get_setup(self.connection);
        const iter = c.xcb_setup_roots_iterator(setup);
        self.screen = iter.data;
        if (self.screen == null) return error.NoScreen;

        // Create window
        self.window = c.xcb_generate_id(self.connection);
        const mask: u32 = c.XCB_CW_BACK_PIXEL | c.XCB_CW_EVENT_MASK;
        const event_mask: u32 = c.XCB_EVENT_MASK_EXPOSURE |
            c.XCB_EVENT_MASK_KEY_PRESS | c.XCB_EVENT_MASK_KEY_RELEASE |
            c.XCB_EVENT_MASK_BUTTON_PRESS | c.XCB_EVENT_MASK_BUTTON_RELEASE |
            c.XCB_EVENT_MASK_POINTER_MOTION |
            c.XCB_EVENT_MASK_STRUCTURE_NOTIFY |
            c.XCB_EVENT_MASK_FOCUS_CHANGE;
        const values = [2]u32{ self.screen.?.*.black_pixel, event_mask };

        _ = c.xcb_create_window(
            self.connection,
            c.XCB_COPY_FROM_PARENT, // depth
            self.window,
            self.screen.?.*.root,
            0,
            0, // x, y
            @intCast(width),
            @intCast(height),
            0, // border
            c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
            self.screen.?.*.root_visual,
            mask,
            &values,
        );
        errdefer _ = c.xcb_destroy_window(self.connection, self.window);

        // Set window title
        _ = c.xcb_change_property(
            self.connection,
            c.XCB_PROP_MODE_REPLACE,
            self.window,
            c.XCB_ATOM_WM_NAME,
            c.XCB_ATOM_STRING,
            8,
            @intCast(title.len),
            title.ptr,
        );

        // Register WM_DELETE_WINDOW for graceful close
        self.wm_protocols = try internAtom(self.connection, "WM_PROTOCOLS");
        self.wm_delete_window = try internAtom(self.connection, "WM_DELETE_WINDOW");
        _ = c.xcb_change_property(
            self.connection,
            c.XCB_PROP_MODE_REPLACE,
            self.window,
            self.wm_protocols,
            c.XCB_ATOM_ATOM,
            32,
            1,
            @ptrCast(&self.wm_delete_window),
        );

        // Create GC for drawing
        self.gc = c.xcb_generate_id(self.connection);
        _ = c.xcb_create_gc(self.connection, self.gc, self.window, 0, null);

        // Try to set up SHM
        self.shm_available = initShm(self.connection);

        // Allocate pixel buffer
        self.width = width;
        self.height = height;
        try self.allocateBuffer();

        // Initialize cursor context
        if (c.xcb_cursor_context_new(self.connection, self.screen, &self.cursor_ctx) == 0) {
            // success
        } else {
            self.cursor_ctx = null;
        }

        // Map (show) the window
        _ = c.xcb_map_window(self.connection, self.window);
        _ = c.xcb_flush(self.connection);

        return self;
    }

    /// Destroy the surface and free all resources.
    pub fn deinit(self: *XcbSurface) void {
        self.freeBuffer();

        if (self.current_cursor != 0) {
            _ = c.xcb_free_cursor(self.connection, self.current_cursor);
        }
        if (self.cursor_ctx) |ctx| {
            c.xcb_cursor_context_free(ctx);
        }

        _ = c.xcb_free_gc(self.connection, self.gc);
        _ = c.xcb_destroy_window(self.connection, self.window);
        _ = c.xcb_flush(self.connection);

        // Close via Xlib (which owns the connection)
        if (self.xlib_display) |dpy| {
            _ = c.XCloseDisplay(dpy);
        }
        self.connection = null;
        self.xlib_display = null;
    }

    /// Present the pixel buffer to the window (flush to screen).
    /// Uses SHM put_image if available, otherwise falls back to xcb_put_image.
    pub fn present(self: *XcbSurface) void {
        if (self.pixels == null) return;

        if (self.shm_available and self.shm_seg != 0) {
            // SHM path: zero-copy
            _ = c.xcb_shm_put_image(
                self.connection,
                self.window,
                self.gc,
                @intCast(self.width),
                @intCast(self.height),
                0,
                0, // src x, y
                @intCast(self.width),
                @intCast(self.height), // w, h
                0,
                0, // dst x, y
                self.screen.?.*.root_depth,
                c.XCB_IMAGE_FORMAT_Z_PIXMAP,
                0, // send_event
                self.shm_seg,
                0, // offset
            );
        } else {
            // Fallback: copy pixels over the socket
            const data_len: u32 = @intCast(@as(usize, @intCast(self.width)) * @as(usize, @intCast(self.height)) * 4);
            _ = c.xcb_put_image(
                self.connection,
                c.XCB_IMAGE_FORMAT_Z_PIXMAP,
                self.window,
                self.gc,
                @intCast(self.width),
                @intCast(self.height),
                0,
                0, // dst x, y
                0, // left_pad
                self.screen.?.*.root_depth,
                data_len,
                @ptrCast(self.pixels),
            );
        }
        _ = c.xcb_flush(self.connection);
    }

    /// Re-allocate the pixel buffer for a new size.
    pub fn resize(self: *XcbSurface, w: i32, h: i32) !void {
        if (w == self.width and h == self.height) return;
        self.freeBuffer();
        self.width = w;
        self.height = h;
        try self.allocateBuffer();
    }

    /// Fill a rectangle with an ARGB colour (0xAARRGGBB).
    pub fn fillRect(self: *XcbSurface, x: i32, y: i32, w: i32, h: i32, color: u32) void {
        const pixels = self.pixels orelse return;
        const surf_w: usize = @intCast(self.width);
        const surf_h: usize = @intCast(self.height);

        // Clip
        const x0: usize = @intCast(@max(x, 0));
        const y0: usize = @intCast(@max(y, 0));
        const x1: usize = @intCast(@min(x + w, self.width));
        const y1: usize = @intCast(@min(y + h, self.height));
        if (x0 >= x1 or y0 >= y1) return;
        _ = surf_h;

        var row: usize = y0;
        while (row < y1) : (row += 1) {
            const row_start = row * surf_w + x0;
            const row_end = row * surf_w + x1;
            @memset(pixels[row_start..row_end], color);
        }
    }

    /// Clear the entire surface with a color.
    pub fn clear(self: *XcbSurface, color: u32) void {
        const pixels = self.pixels orelse return;
        const total: usize = @intCast(self.width * self.height);
        @memset(pixels[0..total], color);
    }

    /// Set the mouse cursor shape.
    pub fn setCursor(self: *XcbSurface, shape: CursorShape) void {
        const ctx = self.cursor_ctx orelse return;

        const name: [*:0]const u8 = switch (shape) {
            .arrow => "default",
            .pointer => "pointer",
            .text => "text",
        };

        const cursor = c.xcb_cursor_load_cursor(ctx, name);
        if (cursor == 0) return;

        // Free old cursor
        if (self.current_cursor != 0) {
            _ = c.xcb_free_cursor(self.connection, self.current_cursor);
        }
        self.current_cursor = cursor;

        const value = [1]u32{cursor};
        _ = c.xcb_change_window_attributes(
            self.connection,
            self.window,
            c.XCB_CW_CURSOR,
            &value,
        );
        _ = c.xcb_flush(self.connection);
    }

    /// No-op passthrough for migration compatibility.
    /// The old libnsfb surface swizzled ARGB→ABGR; XCB uses native ARGB, so no conversion needed.
    pub fn argbToColour(colour: u32) u32 {
        return colour;
    }

    // ── Internal helpers ──────────────────────────────────────────

    /// Allocate the pixel buffer, using SHM if available.
    fn allocateBuffer(self: *XcbSurface) !void {
        const w: usize = @intCast(self.width);
        const h: usize = @intCast(self.height);
        const buf_size = w * h * 4;
        if (buf_size == 0) return error.InvalidSize;

        self.stride = w * 4;

        if (self.shm_available) {
            // Create POSIX shared memory segment
            self.shm_id = std.c.shmget(
                std.c.IPC.PRIVATE,
                buf_size,
                std.c.IPC.CREAT | 0o600,
            );
            if (self.shm_id < 0) {
                // SHM creation failed; fall back to malloc
                self.shm_available = false;
                return self.allocateMalloc(buf_size);
            }
            errdefer _ = std.c.shmctl(self.shm_id, std.c.IPC.RMID, null);

            const ptr = std.c.shmat(self.shm_id, null, 0);
            if (ptr == @as(*anyopaque, @ptrFromInt(std.math.maxInt(usize)))) {
                self.shm_available = false;
                _ = std.c.shmctl(self.shm_id, std.c.IPC.RMID, null);
                self.shm_id = -1;
                return self.allocateMalloc(buf_size);
            }

            self.pixels = @alignCast(@ptrCast(ptr));

            // Register with XCB
            self.shm_seg = c.xcb_generate_id(self.connection);
            _ = c.xcb_shm_attach(self.connection, self.shm_seg, @intCast(self.shm_id), 0);
            _ = c.xcb_flush(self.connection);
        } else {
            return self.allocateMalloc(buf_size);
        }
    }

    /// Allocate pixel buffer via C allocator (fallback path).
    fn allocateMalloc(self: *XcbSurface, buf_size: usize) !void {
        const slice = std.heap.c_allocator.alloc(u32, buf_size / 4) catch return error.OutOfMemory;
        self.pixels = slice.ptr;
    }

    /// Free the pixel buffer.
    fn freeBuffer(self: *XcbSurface) void {
        if (self.pixels == null) return;

        if (self.shm_available and self.shm_seg != 0) {
            _ = c.xcb_shm_detach(self.connection, self.shm_seg);
            _ = c.xcb_flush(self.connection);
            self.shm_seg = 0;
            _ = std.c.shmdt(@ptrCast(self.pixels));
            if (self.shm_id >= 0) {
                _ = std.c.shmctl(self.shm_id, std.c.IPC.RMID, null);
                self.shm_id = -1;
            }
        } else {
            const total: usize = @intCast(self.width * self.height);
            std.heap.c_allocator.free(self.pixels.?[0..total]);
        }
        self.pixels = null;
    }

    /// Check if SHM extension is available.
    fn initShm(conn: ?*c.xcb_connection_t) bool {
        const cookie = c.xcb_shm_query_version(conn);
        const reply = c.xcb_shm_query_version_reply(conn, cookie, null);
        if (reply) |r| {
            std.c.free(r);
            return true;
        }
        return false;
    }

    /// Intern an X11 atom by name.
    fn internAtom(conn: ?*c.xcb_connection_t, name: []const u8) !c.xcb_atom_t {
        const cookie = c.xcb_intern_atom(conn, 0, @intCast(name.len), name.ptr);
        const reply = c.xcb_intern_atom_reply(conn, cookie, null) orelse return error.AtomNotFound;
        defer std.c.free(reply);
        return reply.*.atom;
    }
};
