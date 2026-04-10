const std = @import("std");
const coords = @import("coords.zig");

pub const MouseButton = enum { left, middle, right };

pub const KeyEvent = struct {
    keysym: u32,
    keycode: u8,
    state: u16,

    pub fn ctrlHeld(self: KeyEvent) bool {
        return self.state & 0x04 != 0; // ControlMask
    }
    pub fn shiftHeld(self: KeyEvent) bool {
        return self.state & 0x01 != 0; // ShiftMask
    }
    pub fn altHeld(self: KeyEvent) bool {
        return self.state & 0x08 != 0; // Mod1Mask
    }
};

pub const ScrollDelta = struct { dx: f32, dy: f32 };

pub const EventHandler = struct {
    ctx: *anyopaque,
    onClick: ?*const fn (*anyopaque, coords.ScreenPos, MouseButton) bool = null,
    onMouseDown: ?*const fn (*anyopaque, coords.ScreenPos, MouseButton) bool = null,
    onMouseUp: ?*const fn (*anyopaque, coords.ScreenPos, MouseButton) bool = null,
    onMouseMove: ?*const fn (*anyopaque, coords.ScreenPos) void = null,
    onScroll: ?*const fn (*anyopaque, coords.ScreenPos, ScrollDelta) void = null,
    onKeyDown: ?*const fn (*anyopaque, KeyEvent) bool = null,
    onKeyUp: ?*const fn (*anyopaque, KeyEvent) bool = null,
    onResize: ?*const fn (*anyopaque, u32, u32) void = null,
};

pub const EventLoop = struct {
    handlers: std.BoundedArray(EventHandler, 8) = .{},
    running: bool = true,

    pub fn registerHandler(self: *EventLoop, handler: EventHandler) void {
        self.handlers.append(handler) catch {
            std.debug.print("[EventLoop] handler overflow, max 8\n", .{});
        };
    }

    pub fn requestQuit(self: *EventLoop) void {
        self.running = false;
    }

    /// Dispatch a click event to all handlers until one consumes it.
    pub fn dispatchClick(self: *EventLoop, pos: coords.ScreenPos, button: MouseButton) bool {
        for (self.handlers.constSlice()) |h| {
            if (h.onClick) |cb| {
                if (cb(h.ctx, pos, button)) return true;
            }
        }
        return false;
    }

    /// Dispatch mouse down to handlers until one consumes it.
    pub fn dispatchMouseDown(self: *EventLoop, pos: coords.ScreenPos, button: MouseButton) bool {
        for (self.handlers.constSlice()) |h| {
            if (h.onMouseDown) |cb| {
                if (cb(h.ctx, pos, button)) return true;
            }
        }
        return false;
    }

    /// Dispatch mouse up to handlers until one consumes it.
    pub fn dispatchMouseUp(self: *EventLoop, pos: coords.ScreenPos, button: MouseButton) bool {
        for (self.handlers.constSlice()) |h| {
            if (h.onMouseUp) |cb| {
                if (cb(h.ctx, pos, button)) return true;
            }
        }
        return false;
    }

    /// Dispatch mouse move to all handlers.
    pub fn dispatchMouseMove(self: *EventLoop, pos: coords.ScreenPos) void {
        for (self.handlers.constSlice()) |h| {
            if (h.onMouseMove) |cb| cb(h.ctx, pos);
        }
    }

    /// Dispatch scroll to all handlers.
    pub fn dispatchScroll(self: *EventLoop, pos: coords.ScreenPos, delta: ScrollDelta) void {
        for (self.handlers.constSlice()) |h| {
            if (h.onScroll) |cb| cb(h.ctx, pos, delta);
        }
    }

    /// Dispatch key down to handlers until one consumes it.
    pub fn dispatchKeyDown(self: *EventLoop, key: KeyEvent) bool {
        for (self.handlers.constSlice()) |h| {
            if (h.onKeyDown) |cb| {
                if (cb(h.ctx, key)) return true;
            }
        }
        return false;
    }

    /// Dispatch key up to handlers until one consumes it.
    pub fn dispatchKeyUp(self: *EventLoop, key: KeyEvent) bool {
        for (self.handlers.constSlice()) |h| {
            if (h.onKeyUp) |cb| {
                if (cb(h.ctx, key)) return true;
            }
        }
        return false;
    }

    /// Dispatch resize to all handlers.
    pub fn dispatchResize(self: *EventLoop, w: u32, h: u32) void {
        for (self.handlers.constSlice()) |hndl| {
            if (hndl.onResize) |cb| cb(hndl.ctx, w, h);
        }
    }
};
