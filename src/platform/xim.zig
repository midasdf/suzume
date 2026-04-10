// XIM helper functions (defined in xim_helper.c)
extern fn xim_init(window_id: c_ulong) c_int;
extern fn xim_process_key(keycode: c_uint, state: c_uint, is_press: c_int, buf: [*]u8, buf_size: c_int) c_int;
extern fn xim_poll_committed(buf: [*]u8, buf_size: c_int) c_int;
extern fn xim_focus_in() void;
extern fn xim_focus_out() void;
extern fn xim_cleanup() void;

pub const Xim = struct {
    initialized: bool = false,

    pub fn init(window_id: c_ulong) Xim {
        const result = xim_init(window_id);
        return .{ .initialized = result == 0 };
    }

    pub fn processKey(self: Xim, keycode: c_uint, state: c_uint, is_press: bool, buf: []u8) ?[]const u8 {
        if (!self.initialized) return null;
        const len = xim_process_key(keycode, state, @intFromBool(is_press), buf.ptr, @intCast(buf.len));
        if (len <= 0) return null;
        return buf[0..@intCast(len)];
    }

    pub fn pollCommitted(self: Xim, buf: []u8) ?[]const u8 {
        if (!self.initialized) return null;
        const len = xim_poll_committed(buf.ptr, @intCast(buf.len));
        if (len <= 0) return null;
        return buf[0..@intCast(len)];
    }

    pub fn focusIn(self: Xim) void {
        if (self.initialized) xim_focus_in();
    }

    pub fn focusOut(self: Xim) void {
        if (self.initialized) xim_focus_out();
    }

    pub fn deinit(self: Xim) void {
        if (self.initialized) xim_cleanup();
    }
};
