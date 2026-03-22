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

/// Apply animation keyframes to a computed style at the given progress.
/// Finds the surrounding keyframes and interpolates property values.
pub fn applyKeyframes(style: *ComputedStyle, keyframes: []const ast.Keyframe, progress: f32) void {
    // Find the two keyframes that surround the current progress
    var kf_before: ?*const ast.Keyframe = null;
    var kf_after: ?*const ast.Keyframe = null;
    var pct_before: f32 = 0;
    var pct_after: f32 = 1;

    for (keyframes) |*kf| {
        const pct = parseKeyframePercent(kf.selector_raw) orelse continue;
        if (pct <= progress) {
            if (kf_before == null or pct >= pct_before) {
                kf_before = kf;
                pct_before = pct;
            }
        }
        if (pct >= progress) {
            if (kf_after == null or pct <= pct_after) {
                kf_after = kf;
                pct_after = pct;
            }
        }
    }

    // If we have both keyframes, interpolate
    if (kf_before != null and kf_after != null) {
        const range = pct_after - pct_before;
        const local_t = if (range > 0) (progress - pct_before) / range else 0;

        // Apply interpolated values for each property in the "after" keyframe
        applyKeyframeDecls(style, kf_before.?.declarations, kf_after.?.declarations, local_t);
    } else if (kf_after) |kf| {
        // Before the first keyframe — apply the "from" values directly
        applyKeyframeDeclsDirect(style, kf.declarations);
    } else if (kf_before) |kf| {
        // After the last keyframe — apply the "to" values directly
        applyKeyframeDeclsDirect(style, kf.declarations);
    }
}

/// Interpolate between two sets of declarations.
fn applyKeyframeDecls(style: *ComputedStyle, from_decls: []const ast.Declaration, to_decls: []const ast.Declaration, t: f32) void {
    for (to_decls) |to_decl| {
        // Find matching property in from_decls
        var from_val: ?[]const u8 = null;
        for (from_decls) |fd| {
            if (fd.property == to_decl.property) {
                from_val = fd.value_raw;
                break;
            }
        }

        const to_val = to_decl.value_raw;
        if (to_val.len == 0) continue;

        switch (to_decl.property) {
            .opacity => {
                const to_f = std.fmt.parseFloat(f32, to_val) catch continue;
                const from_f = if (from_val) |fv| std.fmt.parseFloat(f32, fv) catch style.opacity else style.opacity;
                style.opacity = lerpFloat(from_f, to_f, t);
            },
            .color => {
                if (properties.parseColor(to_val)) |to_c| {
                    const to_argb = to_c.toArgb();
                    const from_argb = if (from_val) |fv| blk: {
                        if (properties.parseColor(fv)) |fc| break :blk fc.toArgb();
                        break :blk style.color;
                    } else style.color;
                    style.color = lerpColor(from_argb, to_argb, t);
                }
            },
            .background_color => {
                if (properties.parseColor(to_val)) |to_c| {
                    const to_argb = to_c.toArgb();
                    const from_argb = if (from_val) |fv| blk: {
                        if (properties.parseColor(fv)) |fc| break :blk fc.toArgb();
                        break :blk style.background_color;
                    } else style.background_color;
                    style.background_color = lerpColor(from_argb, to_argb, t);
                }
            },
            .transform => {
                // Parse transform values and interpolate
                var to_tx: f32 = style.transform_translate_x;
                var to_ty: f32 = style.transform_translate_y;
                var to_sx: f32 = style.transform_scale_x;
                var to_sy: f32 = style.transform_scale_y;
                var to_rot: f32 = style.transform_rotate_deg;
                parseTransformValues(to_val, &to_tx, &to_ty, &to_sx, &to_sy, &to_rot);

                var from_tx: f32 = 0;
                var from_ty: f32 = 0;
                var from_sx: f32 = 1;
                var from_sy: f32 = 1;
                var from_rot: f32 = 0;
                if (from_val) |fv| {
                    parseTransformValues(fv, &from_tx, &from_ty, &from_sx, &from_sy, &from_rot);
                }

                style.transform_translate_x = lerpFloat(from_tx, to_tx, t);
                style.transform_translate_y = lerpFloat(from_ty, to_ty, t);
                style.transform_scale_x = lerpFloat(from_sx, to_sx, t);
                style.transform_scale_y = lerpFloat(from_sy, to_sy, t);
                style.transform_rotate_deg = lerpFloat(from_rot, to_rot, t);
            },
            else => {
                // For non-interpolatable properties, snap at 50%
                if (t >= 0.5) {
                    applyRawDecl(style, to_decl);
                }
            },
        }
    }
}

/// Apply declarations directly without interpolation.
fn applyKeyframeDeclsDirect(style: *ComputedStyle, decls: []const ast.Declaration) void {
    for (decls) |decl| {
        applyRawDecl(style, decl);
    }
}

/// Apply a single raw declaration to style (simple property setting).
fn applyRawDecl(style: *ComputedStyle, decl: ast.Declaration) void {
    const val = decl.value_raw;
    if (val.len == 0) return;
    switch (decl.property) {
        .opacity => {
            if (std.fmt.parseFloat(f32, val)) |v| style.opacity = std.math.clamp(v, 0.0, 1.0) else |_| {}
        },
        .color => {
            if (properties.parseColor(val)) |c| style.color = c.toArgb();
        },
        .background_color => {
            if (properties.parseColor(val)) |c| style.background_color = c.toArgb();
        },
        .visibility => {
            if (std.mem.eql(u8, val, "visible")) style.visibility = .visible
            else if (std.mem.eql(u8, val, "hidden")) style.visibility = .hidden;
        },
        .display => {
            if (std.mem.eql(u8, val, "none")) style.display = .none
            else if (std.mem.eql(u8, val, "block")) style.display = .block;
        },
        else => {},
    }
}

/// Parse simple transform values from a CSS transform string.
fn parseTransformValues(val: []const u8, tx: *f32, ty: *f32, sx: *f32, sy: *f32, rot: *f32) void {
    var remaining = val;
    while (remaining.len > 0) {
        // Find next function
        const paren = std.mem.indexOfScalar(u8, remaining, '(') orelse break;
        const func_name = std.mem.trim(u8, remaining[0..paren], " \t");
        const close = std.mem.indexOfScalar(u8, remaining[paren..], ')') orelse break;
        const args = remaining[paren + 1 .. paren + close];
        remaining = remaining[paren + close + 1 ..];

        if (std.mem.eql(u8, func_name, "translateX")) {
            if (std.fmt.parseFloat(f32, std.mem.trim(u8, args, " pxtPX"))) |v| tx.* = v else |_| {}
        } else if (std.mem.eql(u8, func_name, "translateY")) {
            if (std.fmt.parseFloat(f32, std.mem.trim(u8, args, " pxtPX"))) |v| ty.* = v else |_| {}
        } else if (std.mem.eql(u8, func_name, "scale")) {
            if (std.fmt.parseFloat(f32, std.mem.trim(u8, args, " "))) |v| {
                sx.* = v;
                sy.* = v;
            } else |_| {}
        } else if (std.mem.eql(u8, func_name, "rotate")) {
            if (std.fmt.parseFloat(f32, std.mem.trim(u8, args, " degrad"))) |v| rot.* = v else |_| {}
        }
    }
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
