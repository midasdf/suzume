//! Local thread-synchronization shims for Zig 0.16.
//!
//! 0.16 removed `std.Thread.{ResetEvent,Mutex,Condition}` and replaced
//! them with `std.Io.{Event,Mutex,Condition}`, which require an `Io`
//! parameter on every operation. These shims preserve the 0.15 API
//! surface (no `io` at call sites) by pulling `env.ioOrPanic()` from
//! the shared `env` module at each op.
//!
//! Only the subset used by suzume (webdriver.zig) is implemented.

const std = @import("std");
const env = @import("env.zig");

/// Drop-in replacement for std.Thread.ResetEvent backed by std.Io.Event.
///
/// API preserved: `set()`, `reset()`, `isSet()`, `timedWait(timeout_ns)`.
pub const ResetEvent = struct {
    inner: std.Io.Event = .unset,

    pub fn set(self: *ResetEvent) void {
        self.inner.set(env.ioOrPanic());
    }

    pub fn reset(self: *ResetEvent) void {
        self.inner.reset();
    }

    pub fn isSet(self: *const ResetEvent) bool {
        return self.inner.isSet();
    }

    /// Wait up to `timeout_ns` nanoseconds for the event to be set.
    /// Returns `error.Timeout` if the timeout expires first.
    pub fn timedWait(self: *ResetEvent, timeout_ns: u64) error{Timeout}!void {
        const timeout: std.Io.Timeout = .{
            .duration = .{
                .raw = std.Io.Duration.fromNanoseconds(@intCast(timeout_ns)),
                .clock = .awake,
            },
        };
        self.inner.waitTimeout(env.ioOrPanic(), timeout) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            error.Canceled => return error.Timeout, // Treat cancel as timeout for caller simplicity.
        };
    }
};

/// Drop-in replacement for std.Thread.Mutex backed by std.Io.Mutex.
///
/// API preserved: `lock()`, `unlock()`, `tryLock()`.
pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        // Treat cancellation as a bug here — all callers in suzume use
        // mutexes in short, non-cancelable critical sections.
        self.inner.lockUncancelable(env.ioOrPanic());
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(env.ioOrPanic());
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.inner.tryLock();
    }
};
