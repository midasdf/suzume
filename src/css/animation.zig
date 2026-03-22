const std = @import("std");
const ComputedStyle = @import("computed.zig").ComputedStyle;
const ast = @import("ast.zig");
const properties = @import("properties.zig");

/// A running animation instance.
pub const AnimationInstance = struct {
    name: []const u8,
    start_time_ms: f64,
    duration_s: f32,
    delay_s: f32,
    iteration_count: f32, // 0 = infinite
    direction: ComputedStyle.AnimationDirection,
    fill_mode: ComputedStyle.AnimationFillMode,
    finished: bool = false,
};

/// Active animations for a page.
pub const AnimationState = struct {
    animations: std.ArrayListUnmanaged(AnimationInstance),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AnimationState {
        return .{
            .animations = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AnimationState) void {
        self.animations.deinit(self.allocator);
    }

    /// Check if there are any active (non-finished) animations.
    pub fn hasActiveAnimations(self: *const AnimationState) bool {
        for (self.animations.items) |anim| {
            if (!anim.finished) return true;
        }
        return false;
    }

    /// Register a new animation if not already running.
    pub fn startAnimation(self: *AnimationState, style: ComputedStyle, now_ms: f64) void {
        const name = style.animation_name orelse return;
        if (name.len == 0 or style.animation_duration <= 0) return;

        // Check if already running
        for (self.animations.items) |existing| {
            if (std.mem.eql(u8, existing.name, name) and !existing.finished) return;
        }

        self.animations.append(self.allocator, .{
            .name = name,
            .start_time_ms = now_ms + @as(f64, style.animation_delay) * 1000.0,
            .duration_s = style.animation_duration,
            .delay_s = style.animation_delay,
            .iteration_count = style.animation_iteration_count,
            .direction = style.animation_direction,
            .fill_mode = style.animation_fill_mode,
        }) catch {};
    }
};

/// Compute the animation progress (0.0 to 1.0) for a given animation at the current time.
/// Returns null if the animation hasn't started yet or is finished and fill-mode is none.
pub fn computeProgress(anim: *AnimationInstance, now_ms: f64) ?f32 {
    if (anim.finished) {
        return if (anim.fill_mode == .forwards or anim.fill_mode == .both) @as(f32, 1.0) else null;
    }

    const elapsed_ms = now_ms - anim.start_time_ms;
    if (elapsed_ms < 0) {
        // In delay period
        return if (anim.fill_mode == .backwards or anim.fill_mode == .both) @as(f32, 0.0) else null;
    }

    const duration_ms: f64 = @as(f64, anim.duration_s) * 1000.0;
    if (duration_ms <= 0) return null;

    const raw_progress = elapsed_ms / duration_ms;
    const iteration: f64 = @floor(raw_progress);

    // Check if finished
    if (anim.iteration_count > 0 and iteration >= @as(f64, anim.iteration_count)) {
        anim.finished = true;
        return if (anim.fill_mode == .forwards or anim.fill_mode == .both) @as(f32, 1.0) else null;
    }

    // Progress within current iteration (0.0 to 1.0)
    var t: f32 = @floatCast(raw_progress - iteration);

    // Apply direction
    const iter_int: u32 = @intFromFloat(@min(iteration, 1000));
    switch (anim.direction) {
        .normal => {},
        .reverse => t = 1.0 - t,
        .alternate => {
            if (iter_int % 2 == 1) t = 1.0 - t;
        },
        .alternate_reverse => {
            if (iter_int % 2 == 0) t = 1.0 - t;
        },
    }

    // Apply ease timing function (cubic-bezier approximation of CSS "ease")
    t = easeInOut(t);

    return t;
}

/// CSS "ease" timing function approximation (cubic bezier 0.25, 0.1, 0.25, 1.0).
fn easeInOut(t: f32) f32 {
    // Simple approximation using smoothstep
    return t * t * (3.0 - 2.0 * t);
}

/// Interpolate a float property between two values.
pub fn lerpFloat(from: f32, to: f32, t: f32) f32 {
    return from + (to - from) * t;
}

/// Interpolate an ARGB color between two values.
pub fn lerpColor(from: u32, to: u32, t: f32) u32 {
    const fa: f32 = @floatFromInt((from >> 24) & 0xFF);
    const fr: f32 = @floatFromInt((from >> 16) & 0xFF);
    const fg: f32 = @floatFromInt((from >> 8) & 0xFF);
    const fb: f32 = @floatFromInt(from & 0xFF);
    const ta: f32 = @floatFromInt((to >> 24) & 0xFF);
    const tr_: f32 = @floatFromInt((to >> 16) & 0xFF);
    const tg: f32 = @floatFromInt((to >> 8) & 0xFF);
    const tb: f32 = @floatFromInt(to & 0xFF);
    const a: u32 = @intFromFloat(lerpFloat(fa, ta, t));
    const r: u32 = @intFromFloat(lerpFloat(fr, tr_, t));
    const g: u32 = @intFromFloat(lerpFloat(fg, tg, t));
    const b: u32 = @intFromFloat(lerpFloat(fb, tb, t));
    return (a << 24) | (r << 16) | (g << 8) | b;
}

/// Parse a keyframe selector (e.g., "0%", "50%", "100%", "from", "to") to a float 0.0-1.0.
pub fn parseKeyframePercent(sel: []const u8) ?f32 {
    const trimmed = std.mem.trim(u8, sel, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "from")) return 0.0;
    if (std.mem.eql(u8, trimmed, "to")) return 1.0;
    if (std.mem.endsWith(u8, trimmed, "%")) {
        const num_str = trimmed[0 .. trimmed.len - 1];
        if (std.fmt.parseFloat(f32, num_str)) |pct| {
            return pct / 100.0;
        } else |_| {}
    }
    return null;
}
