const std = @import("std");
const Box = @import("box.zig").Box;
const ComputedStyle = @import("../style/computed.zig").ComputedStyle;
const FontCache = @import("../paint/painter.zig").FontCache;
const block = @import("block.zig");

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

    const gap = style.gap;

    // Resolve column track sizes
    const col_widths = resolveTrackSizes(style.grid_template_columns, box.content.width, gap, fonts.allocator);
    defer if (col_widths.len > 0 and style.grid_template_columns.len > 0) fonts.allocator.free(col_widths);
    const num_cols: usize = if (col_widths.len > 0) col_widths.len else 1;

    // Place children in grid cells
    var col: usize = 0;
    var row_y: f32 = 0;
    var row_height: f32 = 0;

    for (box.children.items) |child| {
        // Skip absolutely positioned and hidden children
        if (child.style.position == .absolute or child.style.position == .fixed) {
            block.layoutBlock(child, box.content.width, box.content.y, fonts);
            continue;
        }
        if (child.style.display == .none) continue;

        // Get column width
        const col_width = if (col < col_widths.len) col_widths[col] else box.content.width;

        // Layout child with column width as containing width
        block.layoutBlock(child, col_width, box.content.y + row_y, fonts);

        // Compute x position for this column
        var col_x: f32 = 0;
        for (0..col) |c| {
            col_x += if (c < col_widths.len) col_widths[c] else 0;
            col_x += gap;
        }

        // Reposition child to correct column
        const target_x = box.content.x + col_x + child.margin.left + child.padding.left + child.border.left;
        const dx = target_x - child.content.x;
        block.adjustXPositions(child, dx);

        // Track max row height
        const child_h = child.content.height + child.padding.top + child.padding.bottom +
            child.border.top + child.border.bottom + child.margin.top + child.margin.bottom;
        row_height = @max(row_height, child_h);

        col += 1;
        if (col >= num_cols) {
            col = 0;
            row_y += row_height + gap;
            row_height = 0;
        }
    }

    // Final height
    if (col > 0) row_y += row_height;

    const explicit_h = switch (style.height) {
        .px => |h| h,
        .percent, .auto, .none => null,
    };
    box.content.height = explicit_h orelse row_y;
}

pub fn resolveTrackSizes(tracks: []const ComputedStyle.GridTrackSize, total_width: f32, gap: f32, allocator: std.mem.Allocator) []f32 {
    if (tracks.len == 0) return &.{};

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
                result[i] = 0; // filled in second pass
            },
            .auto => {
                auto_count += 1;
                result[i] = 0; // filled in second pass
            },
        }
    }

    remaining = @max(remaining, 0);

    // Second pass: distribute remaining space to fr and auto tracks
    if (fr_total > 0) {
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
