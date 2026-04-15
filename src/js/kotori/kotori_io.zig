//! Thin IO bridge for the kotori JS engine module.
//!
//! Zig 0.16 requires an `Io` handle for filesystem, clock, and random
//! operations. The kotori module is a separate build-module from root
//! (it has its own `-Mkotori=...`), so it cannot `@import("../../env.zig")`.
//!
//! Instead, root's `src/env.zig` stashes its `Io` pointer here via
//! `kio.io = init.io` at main entry, and kotori's internal call sites
//! read `kio.ioOrPanic()` — the same global-lookup pattern used by
//! root's `env` module.

const std = @import("std");

pub var io: ?std.Io = null;

/// Returns the stashed `Io`. Panics if accessed before main sets it.
pub fn ioOrPanic() std.Io {
    return io orelse @panic("kotori_io.io not initialized — kotori op before main() entry");
}

/// Current wall-clock time in milliseconds since the Unix epoch.
/// Equivalent to the 0.15 `std.time.milliTimestamp()`.
pub fn nowMs() i64 {
    return std.Io.Clock.real.now(ioOrPanic()).toMilliseconds();
}

/// Sleep for `ns` nanoseconds on the monotonic clock.
pub fn sleepNs(ns: u64) void {
    const duration: std.Io.Duration = .fromNanoseconds(@intCast(ns));
    std.Io.sleep(ioOrPanic(), duration, .awake) catch {};
}

/// Write `bytes` to process stderr, ignoring failures.
pub fn stderrWrite(bytes: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(ioOrPanic(), bytes) catch {};
}
