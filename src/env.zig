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
