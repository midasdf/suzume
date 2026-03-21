const std = @import("std");
const Box = @import("box.zig").Box;
const BoxType = @import("box.zig").BoxType;
const block = @import("block.zig");
const FontCache = @import("../paint/painter.zig").FontCache;
const AlignItems = @import("../css/computed.zig").ComputedStyle.AlignItems;

/// Resolve the effective cross-axis alignment for a flex child.
/// Uses align-self if explicitly set, otherwise falls back to container's align-items.
fn resolveAlignment(child: *const Box, container_align: AlignItems) AlignItems {
    return if (child.style.align_self != .auto) child.style.align_self else container_align;
}

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
            block.applyAbsolutePositionOffsets(child, box);
        }
    }

    // Count flex-participating children (exclude position:absolute/fixed)
    var flex_child_count: usize = 0;
    for (children) |child| {
        if (child.style.position != .absolute and child.style.position != .fixed) {
            flex_child_count += 1;
        }
    }

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

    // Check if wrapping is enabled
    const wrapping = style.flex_wrap == .wrap or style.flex_wrap == .wrap_reverse;

    if (!wrapping) {
        // === NOWRAP path (original behavior) ===
        layoutFlexRowNowrap(box, is_reverse, gap, fonts, flex_child_count);
    } else {
        // === WRAP path ===
        layoutFlexRowWrap(box, is_reverse, gap, fonts);
    }
}

/// Nowrap path for flex row layout (original single-line behavior).
fn layoutFlexRowNowrap(box: *Box, is_reverse: bool, gap: f32, fonts: *FontCache, flex_child_count: usize) void {
    const style = box.style;
    const container_width = box.content.width;
    const children = box.children.items;

    const gap_total = if (flex_child_count > 1) gap * @as(f32, @floatFromInt(flex_child_count - 1)) else 0;

    // Phase 1.5: Pre-layout children with auto width to determine intrinsic (content) sizes.
    // For flex items with auto basis, we need the content width, not the container width.
    for (children) |child| {
        if (child.style.position == .absolute or child.style.position == .fixed) continue;
        const has_explicit_width = switch (child.style.width) {
            .px, .percent => true,
            else => false,
        };
        const has_explicit_basis = switch (child.style.flex_basis) {
            .px, .percent => true,
            else => false,
        };
        if (!has_explicit_width and !has_explicit_basis) {
            // Layout at container width first to measure content
            block.layoutBlock(child, container_width, box.content.y, fonts);
            // Then shrink to fit content (intrinsic width)
            const fit_w = block.computeShrinkToFitWidthPublic(child);
            if (fit_w > 0 and fit_w < child.content.width) {
                child.content.width = fit_w;
            }
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

    // Build order-sorted index array for flex item positioning
    var order_indices: [256]usize = undefined;
    var order_count: usize = 0;
    for (children, 0..) |child, ci| {
        if (child.style.position == .absolute or child.style.position == .fixed) continue;
        if (order_count < order_indices.len) {
            order_indices[order_count] = ci;
            order_count += 1;
        }
    }
    // Sort by CSS order property (stable sort: equal orders keep source order)
    const indices = order_indices[0..order_count];
    for (0..indices.len) |pass| {
        var swapped = false;
        for (0..indices.len - 1 - pass) |j| {
            if (children[indices[j]].style.order > children[indices[j + 1]].style.order) {
                const tmp = indices[j];
                indices[j] = indices[j + 1];
                indices[j + 1] = tmp;
                swapped = true;
            }
        }
        if (!swapped) break;
    }

    // Assign positions using order-sorted indices
    var cursor_x = main_offset;
    var flex_pos_idx: usize = 0;
    var i: usize = 0;
    while (i < indices.len) : (i += 1) {
        const sorted_i = if (is_reverse) indices.len - 1 - i else i;
        const child = children[indices[sorted_i]];

        // Cross axis alignment (absolute/fixed already filtered in order_indices)
        const child_cross = child.content.height + child.padding.top + child.padding.bottom +
            child.border.top + child.border.bottom + child.margin.top + child.margin.bottom;
        var cross_offset: f32 = 0;

        const effective_align = resolveAlignment(child, style.align_items);
        switch (effective_align) {
            .auto => {
                cross_offset = 0;
            },
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

/// Wrap path for flex row layout. Splits children into multiple lines.
fn layoutFlexRowWrap(box: *Box, is_reverse: bool, gap: f32, fonts: *FontCache) void {
    const style = box.style;
    const container_width = box.content.width;
    const children = box.children.items;
    const is_wrap_reverse = style.flex_wrap == .wrap_reverse;

    // Pre-layout auto-width children to determine intrinsic (content) sizes
    for (children) |child| {
        if (child.style.position == .absolute or child.style.position == .fixed) continue;
        const has_explicit_width = switch (child.style.width) {
            .px, .percent => true,
            else => false,
        };
        const has_explicit_basis = switch (child.style.flex_basis) {
            .px, .percent => true,
            else => false,
        };
        if (!has_explicit_width and !has_explicit_basis) {
            block.layoutBlock(child, container_width, box.content.y, fonts);
            // Shrink to content width
            const fit_w = block.computeShrinkToFitWidthPublic(child);
            if (fit_w > 0 and fit_w < child.content.width) {
                child.content.width = fit_w;
            }
        }
    }

    // Build a list of flex-participating child indices
    var flex_indices_buf: [256]usize = undefined;
    var flex_count: usize = 0;
    for (children, 0..) |child, ci| {
        if (child.style.position == .absolute or child.style.position == .fixed) continue;
        if (flex_count >= 256) break;
        flex_indices_buf[flex_count] = ci;
        flex_count += 1;
    }
    const flex_indices = flex_indices_buf[0..flex_count];

    // Compute outer widths for each flex child (from Phase 1 measurement)
    var outer_widths_buf: [256]f32 = undefined;
    for (flex_indices, 0..) |ci, fi| {
        const child = children[ci];
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
        const is_border_box = child.style.box_sizing == .border_box and
            (basis != null or explicit_child_w != null);
        const outer_extra = child.margin.left + child.margin.right +
            if (is_border_box) @as(f32, 0) else child_pad_bdr;
        outer_widths_buf[fi] = child_main + outer_extra;
    }

    // Split into wrap lines
    // Each line is stored as (start_flex_idx, end_flex_idx) into flex_indices
    const max_lines = 64;
    var line_starts: [max_lines]usize = undefined;
    var line_ends: [max_lines]usize = undefined;
    var line_count: usize = 0;

    {
        var line_start: usize = 0;
        var cumulative_width: f32 = 0;
        var items_in_line: usize = 0;

        for (0..flex_count) |fi| {
            const item_width = outer_widths_buf[fi];
            const needed = if (items_in_line > 0) item_width + gap else item_width;

            // Start a new line if this item would overflow and we have at least one item
            if (items_in_line > 0 and cumulative_width + needed > container_width and line_count < max_lines) {
                line_starts[line_count] = line_start;
                line_ends[line_count] = fi;
                line_count += 1;
                line_start = fi;
                cumulative_width = item_width;
                items_in_line = 1;
            } else {
                cumulative_width += needed;
                items_in_line += 1;
            }
        }
        // Last line
        if (items_in_line > 0 and line_count < max_lines) {
            line_starts[line_count] = line_start;
            line_ends[line_count] = flex_count;
            line_count += 1;
        }
    }

    // Process each line: flex-grow/shrink, re-layout, measure cross size
    var line_heights: [max_lines]f32 = undefined;
    var final_widths_buf: [256]f32 = undefined;

    for (0..line_count) |line_idx| {
        const l_start = line_starts[line_idx];
        const l_end = line_ends[line_idx];
        const line_item_count = l_end - l_start;
        const line_gap_total = if (line_item_count > 1) gap * @as(f32, @floatFromInt(line_item_count - 1)) else 0;

        // Sum base sizes, grow, shrink for this line
        var line_base_size: f32 = 0;
        var line_grow: f32 = 0;
        var line_shrink: f32 = 0;
        for (l_start..l_end) |fi| {
            const child = children[flex_indices[fi]];
            line_base_size += outer_widths_buf[fi];
            line_grow += child.style.flex_grow;
            line_shrink += child.style.flex_shrink;
        }

        const line_available = container_width - line_gap_total;
        const line_free = line_available - line_base_size;

        // Compute final widths for this line
        for (l_start..l_end) |fi| {
            const child = children[flex_indices[fi]];
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
            const is_border_box = child.style.box_sizing == .border_box and
                (basis != null or explicit_child_w != null);
            const child_outer = child.margin.left + child.margin.right +
                if (is_border_box) @as(f32, 0) else child_pad_bdr;
            var child_main = basis orelse (explicit_child_w orelse child.content.width);

            if (line_free > 0 and line_grow > 0) {
                child_main += line_free * child.style.flex_grow / line_grow;
            } else if (line_free < 0 and line_shrink > 0) {
                child_main += line_free * child.style.flex_shrink / line_shrink;
            }

            final_widths_buf[fi] = @max(child_main + child_outer, 0);
        }

        // Re-layout children in this line with final widths and measure cross size
        var line_max_cross: f32 = 0;
        for (l_start..l_end) |fi| {
            const child = children[flex_indices[fi]];
            block.layoutBlock(child, final_widths_buf[fi], box.content.y, fonts);
            const child_cross = child.content.height + child.padding.top + child.padding.bottom +
                child.border.top + child.border.bottom + child.margin.top + child.margin.bottom;
            if (child_cross > line_max_cross) line_max_cross = child_cross;
        }

        line_heights[line_idx] = line_max_cross;
    }

    // Compute total cross size (sum of all line heights + gaps between lines)
    var total_cross: f32 = if (line_count > 1)
        gap * @as(f32, @floatFromInt(line_count - 1))
    else
        0;
    for (0..line_count) |li| {
        total_cross += line_heights[li];
    }

    const explicit_h = switch (style.height) {
        .px => |h| h,
        .percent, .auto, .none => null,
    };
    const container_cross = explicit_h orelse total_cross;

    // align-content: distribute free cross-axis space among lines
    const free_cross = container_cross - total_cross;
    var ac_offset: f32 = 0; // initial offset before first line
    var ac_line_gap: f32 = gap; // gap between lines

    if (free_cross > 0 and line_count > 0) {
        switch (style.align_content) {
            .stretch => {
                // Distribute extra space equally among lines
                if (line_count > 0) {
                    const extra_per_line = free_cross / @as(f32, @floatFromInt(line_count));
                    for (0..line_count) |li| {
                        line_heights[li] += extra_per_line;
                    }
                }
            },
            .flex_start => {}, // lines at start, no change
            .flex_end => {
                ac_offset = free_cross;
            },
            .center => {
                ac_offset = free_cross / 2;
            },
            .space_between => {
                if (line_count > 1) {
                    ac_line_gap = gap + free_cross / @as(f32, @floatFromInt(line_count - 1));
                }
            },
            .space_around => {
                if (line_count > 0) {
                    const space = free_cross / @as(f32, @floatFromInt(line_count));
                    ac_offset = space / 2;
                    ac_line_gap = gap + space;
                }
            },
            .space_evenly => {
                if (line_count > 0) {
                    const space = free_cross / @as(f32, @floatFromInt(line_count + 1));
                    ac_offset = space;
                    ac_line_gap = gap + space;
                }
            },
        }
    }

    // Position children line by line
    var cross_cursor: f32 = ac_offset;

    for (0..line_count) |raw_line_idx| {
        const line_idx = if (is_wrap_reverse) line_count - 1 - raw_line_idx else raw_line_idx;
        const l_start = line_starts[line_idx];
        const l_end = line_ends[line_idx];
        const line_item_count = l_end - l_start;
        const line_height = line_heights[line_idx];
        const line_gap_total = if (line_item_count > 1) gap * @as(f32, @floatFromInt(line_item_count - 1)) else 0;

        // Compute total used width for justify-content
        var line_total_used: f32 = line_gap_total;
        for (l_start..l_end) |fi| {
            line_total_used += final_widths_buf[fi];
        }
        const line_remaining = container_width - line_total_used;

        var main_offset: f32 = 0;
        var per_gap = gap;

        switch (style.justify_content) {
            .flex_start => {
                main_offset = 0;
            },
            .flex_end => {
                main_offset = line_remaining;
            },
            .center => {
                main_offset = line_remaining / 2;
            },
            .space_between => {
                main_offset = 0;
                if (line_item_count > 1) {
                    per_gap = gap + line_remaining / @as(f32, @floatFromInt(line_item_count - 1));
                }
            },
            .space_around => {
                if (line_item_count > 0) {
                    const space = line_remaining / @as(f32, @floatFromInt(line_item_count));
                    main_offset = space / 2;
                    per_gap = gap + space;
                }
            },
            .space_evenly => {
                if (line_item_count > 0) {
                    const space = line_remaining / @as(f32, @floatFromInt(line_item_count + 1));
                    main_offset = space;
                    per_gap = gap + space;
                }
            },
        }

        // Assign positions for items in this line
        var cursor_x = main_offset;
        var pos_in_line: usize = 0;

        var iter: usize = 0;
        while (iter < line_item_count) : (iter += 1) {
            const fi = if (is_reverse) l_end - 1 - iter else l_start + iter;
            const child = children[flex_indices[fi]];

            // Cross axis alignment within this line
            const child_cross = child.content.height + child.padding.top + child.padding.bottom +
                child.border.top + child.border.bottom + child.margin.top + child.margin.bottom;
            var cross_offset: f32 = 0;

            const effective_align_w = resolveAlignment(child, style.align_items);
            switch (effective_align_w) {
                .auto => {
                    cross_offset = 0;
                },
                .flex_start => {
                    cross_offset = 0;
                },
                .flex_end => {
                    cross_offset = line_height - child_cross;
                },
                .center => {
                    cross_offset = (line_height - child_cross) / 2;
                },
                .stretch => {
                    cross_offset = 0;
                    const child_non_content = child.padding.top + child.padding.bottom +
                        child.border.top + child.border.bottom + child.margin.top + child.margin.bottom;
                    const stretched_height = @max(line_height - child_non_content, 0);
                    if (switch (child.style.height) {
                        .auto => true,
                        else => false,
                    }) {
                        child.content.height = stretched_height;
                    }
                },
                .baseline => {
                    cross_offset = 0;
                },
            }

            const dx = box.content.x + cursor_x - child.content.x + child.padding.left + child.border.left + child.margin.left;
            const dy = cross_cursor + cross_offset + child.margin.top;
            block.adjustXPositions(child, dx);
            block.adjustYPositions(child, dy);

            cursor_x += child.content.width + child.margin.left + child.margin.right +
                child.padding.left + child.padding.right +
                child.border.left + child.border.right;
            pos_in_line += 1;
            if (pos_in_line < line_item_count) cursor_x += per_gap;
        }

        cross_cursor += line_height;
        if (raw_line_idx + 1 < line_count) cross_cursor += ac_line_gap;
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
            block.applyAbsolutePositionOffsets(child, box);
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

        const effective_align_c = resolveAlignment(child, style.align_items);
        switch (effective_align_c) {
            .auto, .flex_start => {},
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
