const std = @import("std");
const JsRuntime = @import("../js/runtime.zig").JsRuntime;

/// Directory where user scripts are stored.
const scripts_subdir = "/.local/share/suzume/scripts/";

/// Load and execute all .js user scripts from the scripts directory.
/// Called after page load when JS runtime is available.
pub fn executeUserScripts(js_rt: *JsRuntime, allocator: std.mem.Allocator) void {
    const home = std.posix.getenv("HOME") orelse return;

    const scripts_dir_path = std.fmt.allocPrint(allocator, "{s}{s}", .{ home, scripts_subdir }) catch return;
    defer allocator.free(scripts_dir_path);

    var dir = std.fs.cwd().openDir(scripts_dir_path, .{ .iterate = true }) catch |err| {
        // Directory doesn't exist — that's fine, no user scripts to run
        if (err == error.FileNotFound) return;
        std.debug.print("[UserScript] Failed to open scripts directory: {}\n", .{err});
        return;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;

        // Only .js files
        if (!std.mem.endsWith(u8, entry.name, ".js")) continue;

        // Read the file
        const file = dir.openFile(entry.name, .{}) catch |err| {
            std.debug.print("[UserScript] Failed to open {s}: {}\n", .{ entry.name, err });
            continue;
        };
        defer file.close();

        // Read up to 1MB
        const max_size = 1024 * 1024;
        const content = file.readToEndAlloc(allocator, max_size) catch |err| {
            std.debug.print("[UserScript] Failed to read {s}: {}\n", .{ entry.name, err });
            continue;
        };
        defer allocator.free(content);

        if (content.len == 0) continue;

        std.debug.print("[UserScript] Executing: {s} ({d} bytes)\n", .{ entry.name, content.len });

        const result = js_rt.eval(content);
        defer result.deinit();
        if (!result.isOk()) {
            std.debug.print("[UserScript:ERROR] {s}: {s}\n", .{ entry.name, result.value() });
        }
        js_rt.executePending();
    }
}

/// Ensure the user scripts directory exists.
pub fn ensureScriptsDir(allocator: std.mem.Allocator) void {
    const home = std.posix.getenv("HOME") orelse return;
    const dir_path = std.fmt.allocPrint(allocator, "{s}{s}", .{ home, scripts_subdir }) catch return;
    defer allocator.free(dir_path);
    std.fs.cwd().makePath(dir_path) catch {};
}
