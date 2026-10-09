//! Resize the sole window on a dedicated Xvfb display for GUI regressions.
const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("xcb/xcb.h");
});

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.next();
    const width = try std.fmt.parseInt(u16, args.next() orelse return error.MissingWidth, 10);
    const height = try std.fmt.parseInt(u16, args.next() orelse return error.MissingHeight, 10);
    if (width == 0 or height == 0 or args.next() != null) return error.InvalidGeometry;

    const connection = c.xcb_connect(null, null) orelse return error.ConnectionFailed;
    defer c.xcb_disconnect(connection);
    if (c.xcb_connection_has_error(connection) != 0) return error.ConnectionFailed;
    const roots = c.xcb_setup_roots_iterator(c.xcb_get_setup(connection));
    if (roots.rem <= 0 or roots.data == null) return error.NoScreen;
    const tree = c.xcb_query_tree_reply(connection, c.xcb_query_tree(connection, roots.data[0].root), null) orelse return error.NoTree;
    defer c.free(tree);
    // Refuse to guess a target on a desktop or while several browsers run.
    if (c.xcb_query_tree_children_length(tree) != 1) return error.NotOneWindow;
    const window = c.xcb_query_tree_children(tree)[0];
    const size = [_]u32{ width, height };
    const request = c.xcb_configure_window_checked(connection, window, c.XCB_CONFIG_WINDOW_WIDTH | c.XCB_CONFIG_WINDOW_HEIGHT, &size);
    if (c.xcb_request_check(connection, request)) |err| {
        defer c.free(err);
        return error.ResizeFailed;
    }
    const geometry = c.xcb_get_geometry_reply(connection, c.xcb_get_geometry(connection, window), null) orelse return error.NoGeometry;
    defer c.free(geometry);
    if (geometry[0].width != width or geometry[0].height != height) return error.GeometryMismatch;
    std.debug.print("X11 window resized: {d}x{d}\n", .{ geometry[0].width, geometry[0].height });
}
