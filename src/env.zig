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

/// Returns the value for `key`, or `null` if unset or the map has not been
/// initialized yet (e.g. lookup before main stashes the pointer).
pub fn get(key: []const u8) ?[]const u8 {
    return if (map) |m| m.get(key) else null;
}
