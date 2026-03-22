const std = @import("std");
const Box = @import("box.zig").Box;
const ComputedStyle = @import("../css/computed.zig").ComputedStyle;
const FontCache = @import("../paint/painter.zig").FontCache;
const block = @import("block.zig");

/// Grid area placement: row/col start and end (0-based, exclusive end).
const AreaPlacement = struct {
    row_start: usize,
    col_start: usize,
    row_end: usize, // exclusive
    col_end: usize, // exclusive
};

/// Build a map from area name to grid placement from grid-template-areas.
/// Returns null if no areas defined.
fn buildAreaMap(
    areas: []const []const []const u8,
    allocator: std.mem.Allocator,
) ?std.StringHashMapUnmanaged(AreaPlacement) {
    if (areas.len == 0) return null;
    var map: std.StringHashMapUnmanaged(AreaPlacement) = .{};

    for (areas, 0..) |row, r| {
        for (row, 0..) |name, c| {
            if (std.mem.eql(u8, name, ".")) continue; // empty cell
            if (map.get(name)) |existing| {
                // Expand existing area
                var updated = existing;
                if (r + 1 > updated.row_end) updated.row_end = r + 1;
                if (c + 1 > updated.col_end) updated.col_end = c + 1;
                if (r < updated.row_start) updated.row_start = r;
                if (c < updated.col_start) updated.col_start = c;
                map.put(allocator, name, updated) catch {};
            } else {
                map.put(allocator, name, .{
                    .row_start = r,
                    .col_start = c,
                    .row_end = r + 1,
                    .col_end = c + 1,
                }) catch {};
            }
        }
    }
    return map;
}

/// Lay out a grid container and its children.
pub fn layoutGrid(box: *Box, containing_width: f32, cursor_y: f32, fonts: *FontCache) void {
    const style = box.style;

    // Content area
    box.content.x = box.padding.left + box.border.left;
    box.content.y = cursor_y + box.padding.top + box.border.top;
    const h_space = box.margin.left + box.margin.right + box.padding.left + box.padding.right + box.border.left + box.border.right;
    const explicit_w = switch (style.width) {
        .px => |w| w,
        .percent => |pct| pct * containing_width / 100.0,
        else => null,
    };
    box.content.width = if (explicit_w) |w| @min(w, @max(containing_width - h_space, 0)) else @max(containing_width - h_space, 0);

    const col_gap = style.gap;
    const row_gap_val = if (style.row_gap > 0) style.row_gap else style.gap;

    // Build area map if grid-template-areas is defined
    var area_map_storage: std.StringHashMapUnmanaged(AreaPlacement) = .{};
    const has_areas = style.grid_template_areas != null;
    var area_map: ?std.StringHashMapUnmanaged(AreaPlacement) = null;
    if (style.grid_template_areas) |areas| {
        area_map_storage = buildAreaMap(areas, fonts.allocator) orelse .{};
        if (area_map_storage.count() > 0) {
            area_map = area_map_storage;
        }
    }

    // Determine number of rows from areas
    const num_rows_from_areas: usize = if (style.grid_template_areas) |areas| areas.len else 0;

    // Resolve column track sizes
    var col_widths: []f32 = &.{};
    var col_widths_owned = false;
    var num_cols: usize = 1;

    if (style.grid_template_columns.len > 0) {
        col_widths = resolveTrackSizes(style.grid_template_columns, box.content.width, col_gap, fonts.allocator);
        col_widths_owned = col_widths.len > 0;
        num_cols = if (col_widths.len > 0) col_widths.len else 1;
    } else if (has_areas) {
        // Infer column count from areas
        if (style.grid_template_areas) |areas| {
            for (areas) |row| {
                if (row.len > num_cols) num_cols = row.len;
            }
        }
        // Equal-width columns
        if (num_cols > 1) {
            const total_gap = col_gap * @as(f32, @floatFromInt(num_cols - 1));
            const available = @max(box.content.width - total_gap, 0);
            const col_w = available / @as(f32, @floatFromInt(num_cols));
            col_widths = fonts.allocator.alloc(f32, num_cols) catch &.{};
            if (col_widths.len > 0) {
                col_widths_owned = true;
                for (col_widths) |*w| w.* = col_w;
            }
        }
    } else {
        // No explicit template — infer from children
        var max_col: usize = 0;
        var auto_children: usize = 0;
        for (box.children.items) |child| {
            if (child.style.position == .absolute or child.style.position == .fixed or child.style.display == .none) continue;
            const span_val = @max(@as(usize, child.style.grid_column_span), 1);
            max_col += span_val;
            auto_children += 1;
        }
        num_cols = if (max_col > 0) max_col else 1;
        if (num_cols > auto_children) num_cols = auto_children;
        if (num_cols == 0) num_cols = 1;
        if (num_cols > 1) {
            const total_gap = col_gap * @as(f32, @floatFromInt(num_cols - 1));
            const available = @max(box.content.width - total_gap, 0);
            const col_w: f32 = switch (style.grid_auto_columns) {
                .px => |px| px,
                .percent => |pct| box.content.width * pct / 100.0,
                .fr => |fr| available * fr / @as(f32, @floatFromInt(num_cols)),
                .auto => available / @as(f32, @floatFromInt(num_cols)),
                .auto_repeat_px => |px| if (px > 0) px else available / @as(f32, @floatFromInt(num_cols)),
                .auto_repeat_percent => |pct| if (pct > 0) box.content.width * pct / 100.0 else available / @as(f32, @floatFromInt(num_cols)),
                .auto_repeat_fr => |fr| available * fr / @as(f32, @floatFromInt(num_cols)),
            };
            col_widths = fonts.allocator.alloc(f32, num_cols) catch &.{};
            if (col_widths.len > 0) {
                col_widths_owned = true;
                for (col_widths) |*w| w.* = col_w;
            }
        }
    }
    defer if (col_widths_owned) fonts.allocator.free(col_widths);

    // Use area-based placement if we have areas
    if (area_map) |amap| {
        layoutWithAreas(box, amap, col_widths, num_cols, num_rows_from_areas, col_gap, row_gap_val, fonts);
    } else {
        layoutSequential(box, col_widths, num_cols, col_gap, row_gap_val, fonts);
    }

    // Apply explicit height if set
    const explicit_h = switch (style.height) {
        .px => |h| h,
        .percent, .auto, .none => null,
    };
    if (explicit_h) |h| box.content.height = h;
}

/// Layout children using grid-template-areas placement.
fn layoutWithAreas(
    box: *Box,
    area_map: std.StringHashMapUnmanaged(AreaPlacement),
    col_widths: []f32,
    num_cols: usize,
    num_rows: usize,
    col_gap: f32,
    row_gap: f32,
    fonts: *FontCache,
) void {
    // Allocate row heights array
    const max_rows = @max(num_rows, 16);
    var row_heights = fonts.allocator.alloc(f32, max_rows) catch return;
    defer fonts.allocator.free(row_heights);
    @memset(row_heights, 0);

    // First pass: layout each child with its area's column width, track row heights
    for (box.children.items) |child| {
        if (child.style.position == .absolute or child.style.position == .fixed) {
            block.layoutBlock(child, box.content.width, box.content.y, fonts);
            continue;
        }
        if (child.style.display == .none) continue;

        const placement = getChildPlacement(child, area_map, num_cols);

        // Calculate column width for this child (spanning multiple columns)
        var child_width: f32 = 0;
        for (placement.col_start..placement.col_end) |c| {
            child_width += if (c < col_widths.len) col_widths[c] else 0;
            if (c > placement.col_start) child_width += col_gap;
        }
        if (child_width == 0) child_width = box.content.width;

        // Layout child with the computed width
        block.layoutBlock(child, child_width, 0, fonts);

        // Track row height (max of all items in that row)
        const child_h = child.content.height + child.padding.top + child.padding.bottom +
            child.border.top + child.border.bottom + child.margin.top + child.margin.bottom;
        for (placement.row_start..placement.row_end) |r| {
            if (r < row_heights.len) {
                // For spanning items, distribute height evenly
                const span_rows = placement.row_end - placement.row_start;
                const per_row = child_h / @as(f32, @floatFromInt(span_rows));
                row_heights[r] = @max(row_heights[r], per_row);
            }
        }
    }

    // Second pass: position children using computed row/col positions
    for (box.children.items) |child| {
        if (child.style.position == .absolute or child.style.position == .fixed) continue;
        if (child.style.display == .none) continue;

        const placement = getChildPlacement(child, area_map, num_cols);

        // Compute X position
        var col_x: f32 = 0;
        for (0..placement.col_start) |c| {
            col_x += if (c < col_widths.len) col_widths[c] else 0;
            col_x += col_gap;
        }

        // Compute Y position
        var row_y: f32 = 0;
        for (0..placement.row_start) |r| {
            if (r < row_heights.len) row_y += row_heights[r];
            row_y += row_gap;
        }

        // Reposition child
        const target_x = box.content.x + col_x + child.margin.left + child.padding.left + child.border.left;
        const dx = target_x - child.content.x;
        block.adjustXPositions(child, dx);

        const target_y = box.content.y + row_y + child.margin.top + child.padding.top + child.border.top;
        const dy = target_y - child.content.y;
        block.adjustYPositions(child, dy);
    }

    // Compute total height
    var total_h: f32 = 0;
    for (0..@min(num_rows, row_heights.len)) |r| {
        total_h += row_heights[r];
        if (r > 0) total_h += row_gap;
    }
    box.content.height = total_h;
}

/// Get the grid placement for a child, using grid-area name or explicit positions.
fn getChildPlacement(
    child: *Box,
    area_map: std.StringHashMapUnmanaged(AreaPlacement),
    num_cols: usize,
) AreaPlacement {
    // Check grid-area name first
    if (child.style.grid_area) |area_name| {
        if (area_map.get(area_name)) |placement| {
            return placement;
        }
    }

    // Check explicit grid-column/row start/end
    const cs = child.style.grid_column_start;
    const ce = child.style.grid_column_end;
    const rs = child.style.grid_row_start;
    const re = child.style.grid_row_end;

    if (cs > 0 or ce > 0 or rs > 0 or re > 0) {
        const col_s: usize = if (cs > 0) @intCast(cs - 1) else 0;
        const col_e: usize = if (ce > 0) @intCast(ce - 1) else col_s + @as(usize, child.style.grid_column_span);
        const row_s: usize = if (rs > 0) @intCast(rs - 1) else 0;
        const row_e: usize = if (re > 0) @intCast(re - 1) else row_s + @as(usize, child.style.grid_row_span);
        return .{
            .row_start = row_s,
            .col_start = col_s,
            .row_end = @max(row_e, row_s + 1),
            .col_end = @max(col_e, col_s + 1),
        };
    }

    // Fallback: single cell at 0,0 (will be auto-placed by caller if needed)
    _ = num_cols;
    return .{ .row_start = 0, .col_start = 0, .row_end = 1, .col_end = 1 };
}

/// Sequential grid layout (no grid-template-areas — original behavior).
fn layoutSequential(
    box: *Box,
    col_widths: []f32,
    num_cols: usize,
    col_gap: f32,
    row_gap_val: f32,
    fonts: *FontCache,
) void {
    var col: usize = 0;
    var row_y: f32 = 0;
    var row_height: f32 = 0;

    for (box.children.items) |child| {
        if (child.style.position == .absolute or child.style.position == .fixed) {
            block.layoutBlock(child, box.content.width, box.content.y, fonts);
            continue;
        }
        if (child.style.display == .none) continue;

        // Get column width (accounting for grid-column span)
        const span = @max(@as(usize, child.style.grid_column_span), 1);
        var col_width: f32 = 0;
        for (0..span) |s| {
            const c = col + s;
            col_width += if (c < col_widths.len) col_widths[c] else 0;
            if (s > 0) col_width += col_gap;
        }
        if (col_width == 0) col_width = box.content.width;

        // Layout child with spanned column width as containing width
        block.layoutBlock(child, col_width, box.content.y + row_y, fonts);

        // Compute x position for this column
        var col_x: f32 = 0;
        for (0..col) |c| {
            col_x += if (c < col_widths.len) col_widths[c] else 0;
            col_x += col_gap;
        }

        // Reposition child to correct column
        const target_x = box.content.x + col_x + child.margin.left + child.padding.left + child.border.left;
        const dx = target_x - child.content.x;
        block.adjustXPositions(child, dx);

        // Track max row height
        const child_h = child.content.height + child.padding.top + child.padding.bottom +
            child.border.top + child.border.bottom + child.margin.top + child.margin.bottom;
        row_height = @max(row_height, child_h);

        col += span;
        if (col >= num_cols) {
            col = 0;
            row_y += row_height + row_gap_val;
            row_height = 0;
        }
    }

    // Final height
    if (col > 0) row_y += row_height;
    box.content.height = row_y;
}

pub fn resolveTrackSizes(tracks: []const ComputedStyle.GridTrackSize, total_width: f32, gap: f32, allocator: std.mem.Allocator) []f32 {
    if (tracks.len == 0) return &.{};

    // Check for auto-repeat tracks and expand them first
    var has_auto_repeat = false;
    for (tracks) |track| {
        switch (track) {
            .auto_repeat_px, .auto_repeat_fr, .auto_repeat_percent => {
                has_auto_repeat = true;
                break;
            },
            else => {},
        }
    }

    if (has_auto_repeat) {
        return resolveWithAutoRepeat(tracks, total_width, gap, allocator);
    }

    const result = allocator.alloc(f32, tracks.len) catch return &.{};

    // First pass: resolve fixed sizes (px, percent)
    var remaining = total_width;
    if (tracks.len > 1) remaining -= gap * @as(f32, @floatFromInt(tracks.len - 1));
    var fr_total: f32 = 0;
    var auto_count: usize = 0;

    for (tracks, 0..) |track, i| {
        switch (track) {
            .px => |px| {
                result[i] = px;
                remaining -= px;
            },
            .percent => |pct| {
                const px = total_width * pct / 100.0;
                result[i] = px;
                remaining -= px;
            },
            .fr => |fr| {
                fr_total += fr;
                result[i] = 0;
            },
            .auto => {
                auto_count += 1;
                result[i] = 0;
            },
            .auto_repeat_px, .auto_repeat_fr, .auto_repeat_percent => {
                // Should not reach here (handled above), treat as auto
                auto_count += 1;
                result[i] = 0;
            },
        }
    }

    remaining = @max(remaining, 0);

    // Second pass: distribute remaining space
    if (fr_total > 0 and auto_count > 0) {
        const auto_min: f32 = @min(remaining * 0.2 / @as(f32, @floatFromInt(auto_count)), 200);
        for (tracks, 0..) |track, i| {
            if (track == .auto) {
                result[i] = auto_min;
                remaining -= auto_min;
            }
        }
        remaining = @max(remaining, 0);
        for (tracks, 0..) |track, i| {
            switch (track) {
                .fr => |fr| {
                    result[i] = remaining * fr / fr_total;
                },
                else => {},
            }
        }
    } else if (fr_total > 0) {
        for (tracks, 0..) |track, i| {
            switch (track) {
                .fr => |fr| {
                    result[i] = remaining * fr / fr_total;
                },
                else => {},
            }
        }
    } else if (auto_count > 0) {
        const auto_width = remaining / @as(f32, @floatFromInt(auto_count));
        for (tracks, 0..) |track, i| {
            if (track == .auto) {
                result[i] = auto_width;
            }
        }
    }

    return result;
}

/// Resolve tracks that contain auto-repeat (auto-fill/auto-fit).
/// Expands the auto-repeat into N copies that fit within the container width.
fn resolveWithAutoRepeat(tracks: []const ComputedStyle.GridTrackSize, total_width: f32, gap: f32, allocator: std.mem.Allocator) []f32 {
    // Calculate how much space is used by fixed tracks
    var fixed_space: f32 = 0;
    var fixed_count: usize = 0;
    var repeat_track_size: f32 = 0;

    for (tracks) |track| {
        switch (track) {
            .px => |px| {
                fixed_space += px;
                fixed_count += 1;
            },
            .percent => |pct| {
                fixed_space += total_width * pct / 100.0;
                fixed_count += 1;
            },
            .auto_repeat_px => |px| {
                repeat_track_size = if (px > 0) px else 100; // fallback to 100px
            },
            .auto_repeat_percent => |pct| {
                repeat_track_size = if (pct > 0) total_width * pct / 100.0 else 100;
            },
            .auto_repeat_fr => {
                // fr in auto-repeat: use equal distribution, estimate 200px
                repeat_track_size = 200;
            },
            else => { fixed_count += 1; },
        }
    }

    if (repeat_track_size <= 0) repeat_track_size = 100;

    // Calculate how many repeated tracks fit
    const available = @max(total_width - fixed_space, 0);
    // Account for gaps: each repeat adds (track_size + gap), minus one gap
    var repeat_count: usize = 1;
    if (repeat_track_size > 0) {
        repeat_count = @intFromFloat(@max(@floor((available + gap) / (repeat_track_size + gap)), 1));
    }

    const total_tracks = fixed_count + repeat_count;
    const result = allocator.alloc(f32, total_tracks) catch return &.{};

    var ri: usize = 0;
    for (tracks) |track| {
        switch (track) {
            .px => |px| {
                if (ri < result.len) { result[ri] = px; ri += 1; }
            },
            .percent => |pct| {
                if (ri < result.len) { result[ri] = total_width * pct / 100.0; ri += 1; }
            },
            .fr => |fr| {
                if (ri < result.len) { result[ri] = fr; ri += 1; } // will be re-distributed below
            },
            .auto => {
                if (ri < result.len) { result[ri] = 0; ri += 1; }
            },
            .auto_repeat_px, .auto_repeat_percent, .auto_repeat_fr => {
                for (0..repeat_count) |_| {
                    if (ri < result.len) { result[ri] = repeat_track_size; ri += 1; }
                }
            },
        }
    }

    return result;
}
