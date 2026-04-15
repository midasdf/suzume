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

/// Write `bytes` to process stdout. On failure, the error is surfaced to
/// stderr so WPT runners do not silently lose result lines (regression
/// guard — Zig 0.16 Io migration previously hid failures behind `catch {}`).
pub fn stdoutWrite(bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(ioOrPanic(), bytes) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "[kotori_io] stdout write failed: {s}\n", .{@errorName(err)}) catch "[kotori_io] stdout write failed\n";
        std.Io.File.stderr().writeStreamingAll(ioOrPanic(), msg) catch {};
    };
}

// ── WPT integration ─────────────────────────────────────────────────
//
// kotori does not depend on src/js/web_api.zig, so we cannot read
// `web_api.wpt_mode` from here. main.zig mirrors the flag into this
// module at startup; kotori's console.log routes "ALERT:" lines to
// stdout (matching web_api.zig:consoleWrite for the QuickJS path).

/// When true, console.log lines starting with "ALERT:" go to stdout
/// instead of stderr, and "ALERT: RESULT:" sets `wpt_result_sent`.
pub var wpt_mode: bool = false;

/// Set to true after an "ALERT: RESULT:" line has been emitted. The
/// main event loop checks this each iteration to break out and exit.
pub var wpt_result_sent: bool = false;
