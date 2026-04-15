//! Shared process-environment accessor.
//!
//! Zig 0.16 removed `std.posix.getenv`. Environment variables are now only
//! accessible via `std.process.Environ.Map`, which the runtime provides to
//! `main` through `std.process.Init.environ_map`.
//!
//! `main` (src/main.zig) stashes that pointer here at startup; former
//! `std.posix.getenv(...)` call sites read via `env.get(...)` to preserve
//! the previous global-lookup semantics with minimal churn.

const std = @import("std");

pub var map: ?*const std.process.Environ.Map = null;

/// Stashed `std.Io` from `std.process.Init` so former `std.fs.cwd()` /
/// `std.fs.*Absolute` call sites can reach the new `std.Io.Dir` API
/// without threading an `io` parameter through every caller.
pub var io: ?std.Io = null;

/// Returns the value for `key`, or `null` if unset or the map has not been
/// initialized yet (e.g. lookup before main stashes the pointer).
pub fn get(key: []const u8) ?[]const u8 {
    return if (map) |m| m.get(key) else null;
}

/// Returns the stashed `Io`. Panics if accessed before `main` sets it,
/// which would indicate a programming error: `std.Io.Dir` ops are only
/// valid after the runtime has provided an `Io` via `std.process.Init`.
pub fn ioOrPanic() std.Io {
    return io orelse @panic("env.io not initialized — std.Io.Dir op before main() entry");
}

// ─── File read/write helpers ─────────────────────────────────────────
//
// 0.16 replaced `File.{readAll,writeAll,readToEndAlloc}` with the
// Reader/Writer interfaces that require explicit per-call buffers.
// These thin wrappers keep call sites one-liners and share `env.io`.

/// Write `bytes` to `file`, flushing the Writer buffer at the end.
/// Equivalent to the 0.15 `file.writeAll(bytes)`.
pub fn writeAll(file: std.Io.File, bytes: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = file.writer(ioOrPanic(), &buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

/// Read up to `dest.len` bytes into `dest`, returning the number of bytes
/// actually read. Equivalent to the 0.15 `file.readAll(dest)`.
pub fn readAll(file: std.Io.File, dest: []u8) !usize {
    var buf: [4096]u8 = undefined;
    var r = file.reader(ioOrPanic(), &buf);
    return r.interface.readSliceShort(dest);
}

// ─── Clock helpers ───────────────────────────────────────────────────
//
// 0.16 removed std.time.milliTimestamp and std.posix.clock_gettime.
// The new API routes wall-clock reads through std.Io.Clock, requiring
// an Io handle. Wrap the Clock.now(io).toMilliseconds() dance so call
// sites stay single-expression.

/// Current wall-clock time in milliseconds since the Unix epoch.
/// Equivalent to the 0.15 `std.time.milliTimestamp()`.
pub fn nowMs() i64 {
    return std.Io.Clock.real.now(ioOrPanic()).toMilliseconds();
}

/// Read `file` to EOF, allocating up to `max_size` bytes with `allocator`.
/// Equivalent to the 0.15 `file.readToEndAlloc(allocator, max_size)`.
pub fn readToEndAlloc(file: std.Io.File, allocator: std.mem.Allocator, max_size: usize) ![]u8 {
    var buf: [4096]u8 = undefined;
    var r = file.reader(ioOrPanic(), &buf);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var chunk: [4096]u8 = undefined;
    while (true) {
        // readSliceShort returns short reads at EOF (n < chunk.len means
        // the stream is exhausted; n == 0 confirms EOF on next call).
        const n = try r.interface.readSliceShort(&chunk);
        if (n == 0) break;
        if (out.items.len + n > max_size) return error.StreamTooLong;
        try out.appendSlice(allocator, chunk[0..n]);
        if (n < chunk.len) break;
    }
    return try out.toOwnedSlice(allocator);
}
