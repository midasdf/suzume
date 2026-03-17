const std = @import("std");
const Box = @import("box.zig").Box;
const BoxType = @import("box.zig").BoxType;
const block = @import("block.zig");
const FontCache = @import("../paint/painter.zig").FontCache;

/// Lay out a flex container and its children.
/// The flex container box should have display: flex.
pub fn layoutFlex(box: *Box, containing_width: f32, cursor_y: f32, fonts: *FontCache) void {
    const style = box.style;

    // Content position
    const content_x = box.padding.left + box.border.left;
    box.content.x = content_x;
    box.content.y = cursor_y + box.padding.top + box.border.top;

    // Content width
    const h_space = box.margin.left + box.margin.right +
        box.padding.left + box.padding.right +
        box.border.left + box.border.right;
    const explicit_w = switch (style.width) {
        .px => |w| w,
        .percent => |pct| pct * containing_width / 100.0,
        else => null,
    };
    box.content.width = if (explicit_w) |w| @min(w, @max(containing_width - h_space, 0)) else @max(containing_width - h_space, 0);

    const is_column = (style.flex_direction == .column or style.flex_direction == .column_reverse);
    const is_reverse = (style.flex_direction == .row_reverse or style.flex_direction == .column_reverse);
    const gap = style.gap;

    if (is_column) {
        layoutFlexColumn(box, is_reverse, gap, fonts);
    } else {
        layoutFlexRow(box, is_reverse, gap, fonts);
    }
}

/// Row-direction flex layout.
fn layoutFlexRow(box: *Box, is_reverse: bool, gap: f32, fonts: *FontCache) void {
    const style = box.style;
    const container_width = box.content.width;
    const children = box.children.items;
    if (children.len == 0) {
        box.content.height = switch (style.height) {
            .px => |h| h,
            .percent, .auto, .none => 0,
        };
        return;
    }

    // Layout position:absolute/fixed children out of flow first
    for (children) |child| {
        if (child.style.position == .absolute or child.style.position == .fixed) {
            block.layoutBlock(child, container_width, box.content.y, fonts);
            block.adjustXPositions(child, box.content.x);
        }
    }

    // Count flex-participating children (exclude position:absolute/fixed)
    var flex_child_count: usize = 0;
    for (children) |child| {
        if (child.style.position != .absolute and child.style.position != .fixed) {
            flex_child_count += 1;
        }
    }

    const gap_total = if (flex_child_count > 1) gap * @as(f32, @floatFromInt(flex_child_count - 1)) else 0;

    // Phase 1: Measure children to get their base main sizes
    // First, lay them out as blocks to get intrinsic sizes
    for (children) |child| {
        if (child.style.position == .absolute or child.style.position == .fixed) continue;
        // Get flex-basis or intrinsic width
        const basis = switch (child.style.flex_basis) {
            .px => |b| b,
            .percent => |pct| pct * container_width / 100.0,
            else => null,
        };
        const explicit_child_w = switch (child.style.width) {
            .px => |w| w,
            .percent => |pct| pct * container_width / 100.0,
            else => null,
        };

        if (basis) |b| {
            // Use flex-basis as width hint
            block.layoutBlock(child, b + child.margin.left + child.margin.right + child.padding.left + child.padding.right + child.border.left + child.border.right, box.content.y, fonts);
        } else if (explicit_child_w) |w| {
            block.layoutBlock(child, w + child.margin.left + child.margin.right + child.padding.left + child.padding.right + child.border.left + child.border.right, box.content.y, fonts);
        } else {
            // Layout with full container width to measure content
            block.layoutBlock(child, container_width, box.content.y, fonts);
        }
    }

    // Phase 2: Calculate total main size and distribute free space
    var total_base_size: f32 = 0;
    var total_grow: f32 = 0;
    var total_shrink: f32 = 0;

    for (children) |child| {
        if (child.style.position == .absolute or child.style.position == .fixed) continue;
        const basis = switch (child.style.flex_basis) {
            .px => |b| b,
            .percent => |pct| pct * container_width / 100.0,
            else => null,
        };
        const explicit_child_w = switch (child.style.width) {
            .px => |w| w,
            .percent => |pct| pct * container_width / 100.0,
            else => null,
        };
        const child_pad_bdr = child.padding.left + child.padding.right +
            child.border.left + child.border.right;
        const child_main = basis orelse (explicit_child_w orelse child.content.width);
        // With border-box, explicit width already includes padding+border
        const is_border_box = child.style.box_sizing == .border_box and
            (basis != null or explicit_child_w != null);
        const outer_extra = child.margin.left + child.margin.right +
            if (is_border_box) @as(f32, 0) else child_pad_bdr;
        total_base_size += child_main + outer_extra;
        total_grow += child.style.flex_grow;
        total_shrink += child.style.flex_shrink;
    }

    const available = container_width - gap_total;
    const free_space = available - total_base_size;

    // Phase 3: Compute final widths
    var final_widths_buf: [256]f32 = undefined;
    var final_widths_len: usize = 0;
    for (children) |child| {
        if (child.style.position == .absolute or child.style.position == .fixed) continue;
        if (final_widths_len >= 256) break;
        const basis = switch (child.style.flex_basis) {
            .px => |b| b,
            .percent => |pct| pct * container_width / 100.0,
            else => null,
        };
        const explicit_child_w = switch (child.style.width) {
            .px => |w| w,
            .percent => |pct| pct * container_width / 100.0,
            else => null,
        };
        const child_pad_bdr = child.padding.left + child.padding.right +
            child.border.left + child.border.right;
        // With border-box, explicit width already includes padding+border
        const is_border_box = child.style.box_sizing == .border_box and
            (basis != null or explicit_child_w != null);
        const child_outer = child.margin.left + child.margin.right +
            if (is_border_box) @as(f32, 0) else child_pad_bdr;
        var child_main = basis orelse (explicit_child_w orelse child.content.width);

        if (free_space > 0 and total_grow > 0) {
            child_main += free_space * child.style.flex_grow / total_grow;
        } else if (free_space < 0 and total_shrink > 0) {
            child_main += free_space * child.style.flex_shrink / total_shrink;
        }

        final_widths_buf[final_widths_len] = @max(child_main + child_outer, 0);
        final_widths_len += 1;
    }

    // Re-layout children with final widths
    var max_cross: f32 = 0;
    var flex_idx: usize = 0;
    for (children) |child| {
        if (child.style.position == .absolute or child.style.position == .fixed) continue;
        if (flex_idx < final_widths_len) {
            block.layoutBlock(child, final_widths_buf[flex_idx], box.content.y, fonts);
        }
        const child_cross = child.content.height + child.padding.top + child.padding.bottom +
            child.border.top + child.border.bottom + child.margin.top + child.margin.bottom;
        if (child_cross > max_cross) max_cross = child_cross;
        flex_idx += 1;
    }

    // Container cross size
    const explicit_h = switch (style.height) {
        .px => |h| h,
        .percent, .auto, .none => null,
    };
    const container_cross = explicit_h orelse max_cross;

    // Phase 4: Position children along main axis
    var total_used: f32 = 0;
    for (0..final_widths_len) |idx| {
        total_used += final_widths_buf[idx];
    }
    total_used += gap_total;

    const remaining = container_width - total_used;

    var main_offset: f32 = 0;
    var per_gap = gap;

    switch (style.justify_content) {
        .flex_start => {
            main_offset = 0;
        },
        .flex_end => {
            main_offset = remaining;
        },
        .center => {
            main_offset = remaining / 2;
        },
        .space_between => {
            main_offset = 0;
            if (flex_child_count > 1) {
                per_gap = gap + remaining / @as(f32, @floatFromInt(flex_child_count - 1));
            }
        },
        .space_around => {
            if (flex_child_count > 0) {
                const space = remaining / @as(f32, @floatFromInt(flex_child_count));
                main_offset = space / 2;
                per_gap = gap + space;
            }
        },
        .space_evenly => {
            if (flex_child_count > 0) {
                const space = remaining / @as(f32, @floatFromInt(flex_child_count + 1));
                main_offset = space;
                per_gap = gap + space;
            }
        },
    }

    // Assign positions
    var cursor_x = main_offset;
    var flex_pos_idx: usize = 0;
    var i: usize = 0;
    while (i < children.len) : (i += 1) {
        const idx = if (is_reverse) children.len - 1 - i else i;
        const child = children[idx];

        // Skip absolute/fixed positioned children
        if (child.style.position == .absolute or child.style.position == .fixed) continue;

        // Cross axis alignment
        const child_cross = child.content.height + child.padding.top + child.padding.bottom +
            child.border.top + child.border.bottom + child.margin.top + child.margin.bottom;
        var cross_offset: f32 = 0;

        switch (style.align_items) {
            .flex_start => {
                cross_offset = 0;
            },
            .flex_end => {
                cross_offset = container_cross - child_cross;
            },
            .center => {
                cross_offset = (container_cross - child_cross) / 2;
            },
            .stretch => {
                // Stretch child cross size to fill container cross size
                cross_offset = 0;
                const child_non_content = child.padding.top + child.padding.bottom +
                    child.border.top + child.border.bottom + child.margin.top + child.margin.bottom;
                const stretched_height = @max(container_cross - child_non_content, 0);
                if (switch (child.style.height) {
                    .auto => true,
                    else => false,
                }) {
                    child.content.height = stretched_height;
                }
            },
            .baseline => {
                cross_offset = 0; // Simplified
            },
        }

        // Adjust positions
        const dx = box.content.x + cursor_x - child.content.x + child.padding.left + child.border.left + child.margin.left;
        const dy = cross_offset + child.margin.top;
        block.adjustXPositions(child, dx);
        block.adjustYPositions(child, dy);

        cursor_x += child.content.width + child.margin.left + child.margin.right +
            child.padding.left + child.padding.right +
            child.border.left + child.border.right;
        flex_pos_idx += 1;
        if (flex_pos_idx < flex_child_count) cursor_x += per_gap;
    }

    box.content.height = container_cross;
}

/// Column-direction flex layout.
fn layoutFlexColumn(box: *Box, is_reverse: bool, gap: f32, fonts: *FontCache) void {
    const style = box.style;
    const container_width = box.content.width;
    const children = box.children.items;
    if (children.len == 0) {
        box.content.height = switch (style.height) {
            .px => |h| h,
            .percent, .auto, .none => 0,
        };
        return;
    }

    // Layout position:absolute/fixed children out of flow
    for (children) |child| {
        if (child.style.position == .absolute or child.style.position == .fixed) {
            block.layoutBlock(child, container_width, box.content.y, fonts);
            block.adjustXPositions(child, box.content.x);
            continue;
        }
    }

    // Count flex-participating children
    var col_flex_count: usize = 0;
    for (children) |child| {
        if (child.style.position != .absolute and child.style.position != .fixed) {
            col_flex_count += 1;
        }
    }

    // Layout each child with full container width
    for (children) |child| {
        if (child.style.position == .absolute or child.style.position == .fixed) continue;
        block.layoutBlock(child, container_width, box.content.y, fonts);
    }

    // Calculate total main (vertical) size
    var total_main: f32 = 0;
    for (children) |child| {
        if (child.style.position == .absolute or child.style.position == .fixed) continue;
        total_main += child.content.height + child.padding.top + child.padding.bottom +
            child.border.top + child.border.bottom + child.margin.top + child.margin.bottom;
    }
    const gap_total = if (col_flex_count > 1) gap * @as(f32, @floatFromInt(col_flex_count - 1)) else 0;
    total_main += gap_total;

    // Explicit height for justify-content distribution
    const explicit_h = switch (style.height) {
        .px => |h| h,
        .percent, .auto, .none => null,
    };
    const container_main = explicit_h orelse total_main;

    // Position children
    var cursor_y: f32 = 0;

    // Justify content offsets
    const free_space = container_main - total_main;
    var per_gap = gap;

    switch (style.justify_content) {
        .flex_start => {},
        .flex_end => {
            cursor_y = free_space;
        },
        .center => {
            cursor_y = free_space / 2;
        },
        .space_between => {
            if (col_flex_count > 1) {
                per_gap = gap + free_space / @as(f32, @floatFromInt(col_flex_count - 1));
            }
        },
        .space_around => {
            if (col_flex_count > 0) {
                const space = free_space / @as(f32, @floatFromInt(col_flex_count));
                cursor_y = space / 2;
                per_gap = gap + space;
            }
        },
        .space_evenly => {
            if (col_flex_count > 0) {
                const space = free_space / @as(f32, @floatFromInt(col_flex_count + 1));
                cursor_y = space;
                per_gap = gap + space;
            }
        },
    }

    var col_flex_pos: usize = 0;
    var i: usize = 0;
    while (i < children.len) : (i += 1) {
        const idx = if (is_reverse) children.len - 1 - i else i;
        const child = children[idx];

        // Skip absolute/fixed positioned children
        if (child.style.position == .absolute or child.style.position == .fixed) continue;

        // Cross-axis (horizontal) alignment
        const child_cross_size = child.content.width + child.padding.left + child.padding.right +
            child.border.left + child.border.right + child.margin.left + child.margin.right;
        var cross_offset: f32 = 0;

        switch (style.align_items) {
            .flex_start => {},
            .flex_end => {
                cross_offset = container_width - child_cross_size;
            },
            .center => {
                cross_offset = (container_width - child_cross_size) / 2;
            },
            .stretch => {
                // Stretch child cross size (width) to fill container width
                const child_non_content = child.padding.left + child.padding.right +
                    child.border.left + child.border.right + child.margin.left + child.margin.right;
                const stretched_width = @max(container_width - child_non_content, 0);
                if (switch (child.style.width) {
                    .auto => true,
                    else => false,
                }) {
                    child.content.width = stretched_width;
                }
            },
            .baseline => {},
        }

        const dx = box.content.x + cross_offset - child.content.x + child.padding.left + child.border.left + child.margin.left;
        const dy = cursor_y + child.margin.top;
        block.adjustXPositions(child, dx);
        block.adjustYPositions(child, dy);

        cursor_y += child.content.height + child.padding.top + child.padding.bottom +
            child.border.top + child.border.bottom + child.margin.top + child.margin.bottom;
        col_flex_pos += 1;
        if (col_flex_pos < col_flex_count) cursor_y += per_gap;
    }

    box.content.height = @max(container_main, cursor_y);
}
