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

/// Resolve a flex item's used flex basis ("A" in CSS Flexbox L1 §9.2).
///
/// Returns a concrete main-axis size in px for the definite + intrinsic-keyword
/// cases, and `null` when the basis is `auto` (caller then falls back to the
/// width/height property and finally the item's content contribution).
///
/// Spec references:
/// - CSS Flexbox L1 §7.3.3 / §9.2 — flex-basis property and used flex basis.
/// - CSS Sizing L3 §5 — `min-content` / `max-content` / `fit-content(...)`.
/// - CSS Sizing L4 §6 — `flex-basis: content` is max-content of the item's
///   content contribution, ignoring the main-size property.
///
/// Pre-conditions: children have been pre-laid-out so `child.content.{width,height}`
/// already reflects a max-content-ish contribution along the main axis.
fn resolveFlexBasis(
    child: *Box,
    container_main: ?f32,
    fonts: *FontCache,
    is_row: bool,
) ?f32 {
    return switch (child.style.flex_basis) {
        .auto => null, // Caller: fall back to main-size property, then content.
        .px => |v| v,
        // Percent flex-basis resolves against the container's main size; when
        // indefinite it "behaves as auto" (CSS Flexbox L1 §7.3.3).
        .percent => |pct| if (container_main) |cm| pct * cm / 100.0 else null,
        // `content` and `max-content` are equivalent for our single-pass
        // layout: the pre-measured content width/height is the max-content
        // contribution along the main axis.
        .content, .max_content => if (is_row) child.content.width else child.content.height,
        .min_content => if (is_row)
            block.computeMinContentWidthPublic(child, fonts)
        else
            // Column-axis min-content height is not meaningfully different
            // from the measured height in our model (no fragmentation).
            child.content.height,
        // `fit-content` with no argument: clamp max-content by available space
        // (= container main size). Equivalent to min(max-content, max(min-content, available)).
        .fit_content => blk: {
            const max_c: f32 = if (is_row) child.content.width else child.content.height;
            const min_c: f32 = if (is_row)
                block.computeMinContentWidthPublic(child, fonts)
            else
                child.content.height;
            // No argument form: clamp max-content by available main size.
            // If container main size is indefinite, fall back to max-content.
            const avail: f32 = container_main orelse max_c;
            break :blk @min(max_c, @max(min_c, avail));
        },
        .none => null,
    };
}

/// Lay out a flex container and its children.
/// The flex container box should have display: flex.
const dom_api = @import("../js/dom_api.zig");

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
            .percent => |pct| pct * dom_api.g_viewport_height / 100.0,
            .auto, .none, .min_content, .max_content, .fit_content, .content => 0,
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

    // Phase 1: Measure children to get their base main sizes.
    // Intrinsic-keyword flex-basis values (content, max-content, min-content,
    // fit-content) need the child's content width to be populated *before*
    // basis resolution — so for those we lay out at container_width first and
    // let `resolveFlexBasis` read `child.content.width` on a later pass.
    for (children) |child| {
        if (child.style.position == .absolute or child.style.position == .fixed) continue;
        const basis_is_intrinsic = switch (child.style.flex_basis) {
            .content, .max_content, .min_content, .fit_content => true,
            else => false,
        };
        const basis = if (basis_is_intrinsic)
            null
        else
            resolveFlexBasis(child, container_width, fonts, true);
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
        // For intrinsic basis on a child with an explicit width property, the
        // width was used for pre-layout above but ignored by the spec — shrink
        // to the content's actual extent so later basis resolution reads the
        // true max-content contribution.
        if (basis_is_intrinsic) {
            const fit_w = block.computeShrinkToFitWidthPublic(child);
            if (fit_w > 0 and fit_w < child.content.width) {
                child.content.width = fit_w;
            }
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
        const basis = resolveFlexBasis(child, container_width, fonts, true);
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
        const basis = resolveFlexBasis(child, container_width, fonts, true);
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

        // Apply min-width constraint (CSS flex items default min-width: auto)
        // Per CSS Flexbox spec: min-width:auto = min(content size, flex-basis)
        // for items with overflow:visible. For overflow:hidden, min-width:auto = 0.
        const min_w: f32 = switch (child.style.min_width) {
            .px => |mw| mw,
            .percent => |pct| pct * container_width / 100.0,
            .auto => blk: {
                // min-width:auto for flex items: use content minimum width
                // only when overflow is visible (default)
                if (child.style.overflow_x == .visible and child.style.overflow_y == .visible) {
                    // Use the intrinsic content width as minimum
                    const content_min = block.computeShrinkToFitWidthPublic(child);
                    // Clamp to flex-basis or explicit width to avoid expanding beyond intended size
                    const base = basis orelse (explicit_child_w orelse content_min);
                    break :blk @min(content_min, base);
                }
                break :blk 0;
            },
            else => 0,
        };
        if (child_main < min_w) child_main = min_w;

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

    // Container cross size (resolve % against viewport)
    const explicit_h = switch (style.height) {
        .px => |h| h,
        .percent => |pct| pct * dom_api.g_viewport_height / 100.0,
        .auto, .none, .min_content, .max_content, .fit_content, .content => null,
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
        // CSS Box Alignment L3 §5.1 + Flexbox L1 §8.1: "normal" resolves to "flex-start"
        .normal, .flex_start => {
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
                // "normal" in flex context behaves as "stretch"
                cross_offset = 0;
                const child_non_content_a = child.padding.top + child.padding.bottom +
                    child.border.top + child.border.bottom + child.margin.top + child.margin.bottom;
                const stretched_height_a = @max(container_cross - child_non_content_a, 0);
                if (switch (child.style.height) {
                    .auto => true,
                    else => false,
                }) {
                    child.content.height = stretched_height_a;
                }
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
            // Only shrink to fit for inline-level children, not nested flex/grid containers
            // Nested flex containers have no intrinsic width and would collapse to 0
            if (child.style.display != .flex and child.style.display != .inline_flex and
                child.style.display != .grid and child.style.display != .inline_grid)
            {
                const fit_w = block.computeShrinkToFitWidthPublic(child);
                if (fit_w > 0 and fit_w < child.content.width) {
                    child.content.width = fit_w;
                }
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
        const basis = resolveFlexBasis(child, container_width, fonts, true);
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
            const basis = resolveFlexBasis(child, container_width, fonts, true);
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

            // Apply min-width constraint (same auto logic as nowrap path)
            const min_w: f32 = switch (child.style.min_width) {
                .px => |mw| mw,
                .percent => |pct| pct * container_width / 100.0,
                .auto => blk: {
                    if (child.style.overflow_x == .visible and child.style.overflow_y == .visible) {
                        const content_min = block.computeShrinkToFitWidthPublic(child);
                        const base = basis orelse (explicit_child_w orelse content_min);
                        break :blk @min(content_min, base);
                    }
                    break :blk 0;
                },
                else => 0,
            };
            if (child_main < min_w) child_main = min_w;

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
    // Use row_gap for cross-axis gaps between wrap lines (gap is column-gap for main axis)
    const cross_gap = if (style.row_gap > 0) style.row_gap else gap;
    var total_cross: f32 = if (line_count > 1)
        cross_gap * @as(f32, @floatFromInt(line_count - 1))
    else
        0;
    for (0..line_count) |li| {
        total_cross += line_heights[li];
    }

    const explicit_h = switch (style.height) {
        .px => |h| h,
        .percent, .auto, .none, .min_content, .max_content, .fit_content, .content => null,
    };
    const container_cross = explicit_h orelse total_cross;

    // align-content: distribute free cross-axis space among lines
    const free_cross = container_cross - total_cross;
    var ac_offset: f32 = 0; // initial offset before first line
    var ac_line_gap: f32 = cross_gap; // gap between lines

    if (free_cross > 0 and line_count > 0) {
        switch (style.align_content) {
            // CSS Box Alignment L3 §5.1 + Flexbox L1 §8.1: "normal" resolves to "stretch"
            .normal, .stretch => {
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
            // §5.1 + Flexbox L1 §8.1: "normal" resolves to "flex-start"
            .normal, .flex_start => {
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
                    // "normal" in flex context behaves as "stretch"
                    cross_offset = 0;
                    const child_non_content_a2 = child.padding.top + child.padding.bottom +
                        child.border.top + child.border.bottom + child.margin.top + child.margin.bottom;
                    const stretched_height_a2 = @max(line_height - child_non_content_a2, 0);
                    if (switch (child.style.height) {
                        .auto => true,
                        else => false,
                    }) {
                        child.content.height = stretched_height_a2;
                    }
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

/// Wrap path for flex column layout. Splits children into multiple columns.
///
/// Spec references:
/// - CSS Flexbox L1 §5.2  — flex-wrap property
/// - CSS Flexbox L1 §9.3  — Main Size Determination (column = vertical main axis)
/// - CSS Flexbox L1 §9.4  — Cross Size Determination (multi-line = sum of column widths)
/// - CSS Flexbox L1 §9.5  — Main-Axis Alignment (justify-content along column)
/// - CSS Flexbox L1 §9.6  — Cross-Axis Alignment (align-items / align-content across columns)
fn layoutFlexColumnWrap(box: *Box, is_reverse: bool, gap: f32, fonts: *FontCache) void {
    const style = box.style;
    const container_width = box.content.width;
    const children = box.children.items;
    const is_wrap_reverse = style.flex_wrap == .wrap_reverse;

    // Resolve container main size (height). Needed to decide when to wrap.
    // §9.3: If the container has a definite main size use it; otherwise
    // treat available height as the sum of all items (no wrapping needed for
    // indefinite containers — keep same behaviour as nowrap).
    const explicit_h: ?f32 = switch (style.height) {
        .px => |h| h,
        .percent => |pct| pct * dom_api.g_viewport_height / 100.0,
        .auto, .none, .min_content, .max_content, .fit_content, .content => null,
    };

    // Phase 1: Layout each child to measure intrinsic heights.
    for (children) |child| {
        if (child.style.position == .absolute or child.style.position == .fixed) continue;
        block.layoutBlock(child, container_width, box.content.y, fonts);
    }

    // Build list of flex-participating child indices.
    var flex_indices_buf: [256]usize = undefined;
    var flex_count: usize = 0;
    for (children, 0..) |child, ci| {
        if (child.style.position == .absolute or child.style.position == .fixed) continue;
        if (flex_count >= 256) break;
        flex_indices_buf[flex_count] = ci;
        flex_count += 1;
    }
    const flex_indices = flex_indices_buf[0..flex_count];

    // Compute outer heights (main-axis sizes) for each flex child.
    // CSS Sizing L3 §5.2 box-sizing + CSS Flexbox L1 §9.2: with
    // `box-sizing: border-box`, an explicit flex-basis / height already
    // includes padding + border, so only margin counts as extra on top.
    var outer_heights_buf: [256]f32 = undefined;
    for (flex_indices, 0..) |ci, fi| {
        const child = children[ci];
        const basis: ?f32 = resolveFlexBasis(child, explicit_h, fonts, false);
        const explicit_child_h: ?f32 = switch (child.style.height) {
            .px => |h| h,
            .percent => |pct| if (explicit_h) |eh| pct * eh / 100.0 else null,
            else => null,
        };
        const child_pad_bdr = child.padding.top + child.padding.bottom +
            child.border.top + child.border.bottom;
        const is_border_box = child.style.box_sizing == .border_box and
            (basis != null or explicit_child_h != null);
        const child_main = basis orelse (explicit_child_h orelse child.content.height);
        const outer_extra = child.margin.top + child.margin.bottom +
            if (is_border_box) @as(f32, 0) else child_pad_bdr;
        outer_heights_buf[fi] = child_main + outer_extra;
    }

    // Split items into wrap lines (columns). §9.3: Each column is a flex line.
    // If the container height is indefinite treat it as infinite — all items go
    // in one column (same as nowrap).
    const container_main = explicit_h orelse std.math.floatMax(f32);

    const max_lines = 64;
    var line_starts: [max_lines]usize = undefined;
    var line_ends: [max_lines]usize = undefined;
    var line_count: usize = 0;

    {
        var line_start: usize = 0;
        var cumulative_height: f32 = 0;
        var items_in_line: usize = 0;

        for (0..flex_count) |fi| {
            const item_height = outer_heights_buf[fi];
            const needed = if (items_in_line > 0) item_height + gap else item_height;

            if (items_in_line > 0 and cumulative_height + needed > container_main and line_count < max_lines) {
                line_starts[line_count] = line_start;
                line_ends[line_count] = fi;
                line_count += 1;
                line_start = fi;
                cumulative_height = item_height;
                items_in_line = 1;
            } else {
                cumulative_height += needed;
                items_in_line += 1;
            }
        }
        // Last line.
        if (items_in_line > 0 and line_count < max_lines) {
            line_starts[line_count] = line_start;
            line_ends[line_count] = flex_count;
            line_count += 1;
        }
    }

    // Process each line: flex-grow/shrink along main axis (height), measure
    // cross size (max item width in that column). §9.3 + §9.4.
    var line_widths: [max_lines]f32 = undefined; // cross size of each column
    var final_heights_buf: [256]f32 = undefined;

    for (0..line_count) |line_idx| {
        const l_start = line_starts[line_idx];
        const l_end = line_ends[line_idx];
        const line_item_count = l_end - l_start;
        const line_gap_total = if (line_item_count > 1) gap * @as(f32, @floatFromInt(line_item_count - 1)) else 0;

        // Sum base sizes, grow, shrink for this line.
        var line_base_size: f32 = 0;
        var line_grow: f32 = 0;
        var line_shrink: f32 = 0;
        for (l_start..l_end) |fi| {
            const child = children[flex_indices[fi]];
            line_base_size += outer_heights_buf[fi];
            line_grow += child.style.flex_grow;
            line_shrink += child.style.flex_shrink;
        }

        const line_available = container_main - line_gap_total;
        const line_free = line_available - line_base_size;

        // Compute final heights for this line with flex-grow/shrink.
        // For border-box, `child_main` represents the outer (border-box) size;
        // final content height = outer − (padding + border).
        for (l_start..l_end) |fi| {
            const child = children[flex_indices[fi]];
            const basis: ?f32 = resolveFlexBasis(child, explicit_h, fonts, false);
            const explicit_child_h: ?f32 = switch (child.style.height) {
                .px => |h| h,
                .percent => |pct| if (explicit_h) |eh| pct * eh / 100.0 else null,
                else => null,
            };
            const is_border_box = child.style.box_sizing == .border_box and
                (basis != null or explicit_child_h != null);
            const child_pad_bdr = child.padding.top + child.padding.bottom +
                child.border.top + child.border.bottom;
            var child_main = basis orelse (explicit_child_h orelse child.content.height);

            if (line_free > 0 and line_grow > 0) {
                child_main += line_free * child.style.flex_grow / line_grow;
            } else if (line_free < 0 and line_shrink > 0) {
                child_main += line_free * child.style.flex_shrink / line_shrink;
            }

            // Apply min-height constraint.
            const min_h: f32 = switch (child.style.min_height) {
                .px => |mh| mh,
                .percent => |pct| if (explicit_h) |eh| pct * eh / 100.0 else 0,
                else => 0,
            };
            child_main = @max(child_main, min_h);
            child_main = @max(child_main, 0);
            // Store the *content* height (strip pad+border for border-box).
            final_heights_buf[fi] = if (is_border_box)
                @max(child_main - child_pad_bdr, 0)
            else
                child_main;
        }

        // Re-layout children in this line with final heights and measure cross
        // size (max outer width in the column). §9.4.
        var line_max_cross: f32 = 0;
        for (l_start..l_end) |fi| {
            const child = children[flex_indices[fi]];
            child.content.height = final_heights_buf[fi];
            block.layoutBlock(child, container_width, box.content.y, fonts);
            const child_cross = child.content.width + child.padding.left + child.padding.right +
                child.border.left + child.border.right + child.margin.left + child.margin.right;
            if (child_cross > line_max_cross) line_max_cross = child_cross;
        }

        line_widths[line_idx] = line_max_cross;
    }

    // Compute total cross size (sum of all column widths + gaps). §9.4.
    const cross_gap = if (style.row_gap > 0) style.row_gap else gap;
    var total_cross: f32 = if (line_count > 1)
        cross_gap * @as(f32, @floatFromInt(line_count - 1))
    else
        0;
    for (0..line_count) |li| {
        total_cross += line_widths[li];
    }

    // Container cross size = total column widths (clamped to explicit container width).
    const container_cross = @min(container_width, total_cross);

    // align-content: distribute free cross-axis space among columns. §9.4 + §9.6.
    const free_cross = container_cross - total_cross;
    var ac_offset: f32 = 0;
    var ac_col_gap: f32 = cross_gap;

    if (free_cross > 0 and line_count > 0) {
        switch (style.align_content) {
            // §5.1 + Flexbox L1 §8.1: "normal" resolves to "stretch"
            .normal, .stretch => {
                const extra_per_col = free_cross / @as(f32, @floatFromInt(line_count));
                for (0..line_count) |li| {
                    line_widths[li] += extra_per_col;
                }
            },
            .flex_start => {},
            .flex_end => {
                ac_offset = free_cross;
            },
            .center => {
                ac_offset = free_cross / 2;
            },
            .space_between => {
                if (line_count > 1) {
                    ac_col_gap = cross_gap + free_cross / @as(f32, @floatFromInt(line_count - 1));
                }
            },
            .space_around => {
                if (line_count > 0) {
                    const space = free_cross / @as(f32, @floatFromInt(line_count));
                    ac_offset = space / 2;
                    ac_col_gap = cross_gap + space;
                }
            },
            .space_evenly => {
                if (line_count > 0) {
                    const space = free_cross / @as(f32, @floatFromInt(line_count + 1));
                    ac_offset = space;
                    ac_col_gap = cross_gap + space;
                }
            },
        }
    }

    // Position children column by column. §9.5 (main-axis) + §9.6 (cross-axis).
    var cross_cursor: f32 = ac_offset; // horizontal cursor across columns

    for (0..line_count) |raw_col_idx| {
        const col_idx = if (is_wrap_reverse) line_count - 1 - raw_col_idx else raw_col_idx;
        const l_start = line_starts[col_idx];
        const l_end = line_ends[col_idx];
        const line_item_count = l_end - l_start;
        const col_width = line_widths[col_idx];
        const line_gap_total = if (line_item_count > 1) gap * @as(f32, @floatFromInt(line_item_count - 1)) else 0;

        // Compute total used height in this column for justify-content.
        var col_total_used: f32 = line_gap_total;
        for (l_start..l_end) |fi| {
            const child = children[flex_indices[fi]];
            col_total_used += final_heights_buf[fi] +
                child.padding.top + child.padding.bottom +
                child.border.top + child.border.bottom +
                child.margin.top + child.margin.bottom;
        }
        const col_remaining = container_main - col_total_used;

        var main_offset: f32 = 0;
        var per_gap = gap;

        switch (style.justify_content) {
            // §5.1 + Flexbox L1 §8.1: "normal" resolves to "flex-start"
            .normal, .flex_start => {},
            .flex_end => {
                main_offset = col_remaining;
            },
            .center => {
                main_offset = col_remaining / 2;
            },
            .space_between => {
                if (line_item_count > 1) {
                    per_gap = gap + col_remaining / @as(f32, @floatFromInt(line_item_count - 1));
                }
            },
            .space_around => {
                if (line_item_count > 0) {
                    const space = col_remaining / @as(f32, @floatFromInt(line_item_count));
                    main_offset = space / 2;
                    per_gap = gap + space;
                }
            },
            .space_evenly => {
                if (line_item_count > 0) {
                    const space = col_remaining / @as(f32, @floatFromInt(line_item_count + 1));
                    main_offset = space;
                    per_gap = gap + space;
                }
            },
        }

        // Assign positions for items in this column.
        var cursor_y: f32 = main_offset;
        var pos_in_col: usize = 0;

        var iter: usize = 0;
        while (iter < line_item_count) : (iter += 1) {
            const fi = if (is_reverse) l_end - 1 - iter else l_start + iter;
            const child = children[flex_indices[fi]];

            // Cross axis (horizontal) alignment within this column. §9.6.
            const child_cross = child.content.width + child.padding.left + child.padding.right +
                child.border.left + child.border.right + child.margin.left + child.margin.right;
            var cross_offset: f32 = 0;

            const effective_align = resolveAlignment(child, style.align_items);
            switch (effective_align) {
                .auto, .stretch => {
                    // Stretch to fill column width.
                    cross_offset = 0;
                    const child_non_content = child.padding.left + child.padding.right +
                        child.border.left + child.border.right + child.margin.left + child.margin.right;
                    const stretched_width = @max(col_width - child_non_content, 0);
                    if (switch (child.style.width) {
                        .auto => true,
                        else => false,
                    }) {
                        child.content.width = stretched_width;
                    }
                },
                .flex_start => {
                    cross_offset = 0;
                },
                .flex_end => {
                    cross_offset = col_width - child_cross;
                },
                .center => {
                    cross_offset = (col_width - child_cross) / 2;
                },
                .baseline => {
                    cross_offset = 0;
                },
            }

            const dx = box.content.x + cross_cursor + cross_offset - child.content.x + child.padding.left + child.border.left + child.margin.left;
            const dy = cursor_y + child.margin.top;
            block.adjustXPositions(child, dx);
            block.adjustYPositions(child, dy);

            cursor_y += final_heights_buf[fi] +
                child.padding.top + child.padding.bottom +
                child.border.top + child.border.bottom +
                child.margin.top + child.margin.bottom;
            pos_in_col += 1;
            if (pos_in_col < line_item_count) cursor_y += per_gap;
        }

        cross_cursor += col_width;
        if (raw_col_idx + 1 < line_count) cross_cursor += ac_col_gap;
    }

    // Container height: use explicit height if set, else content fills container_main.
    // Container width: already set to content_width by layoutFlex.
    const used_height = if (explicit_h) |eh| eh else blk: {
        // Sum of tallest column's used height (max across lines).
        var max_col_height: f32 = 0;
        for (0..line_count) |li| {
            const l_start = line_starts[li];
            const l_end = line_ends[li];
            const n = l_end - l_start;
            const g = if (n > 1) gap * @as(f32, @floatFromInt(n - 1)) else 0;
            var col_h: f32 = g;
            for (l_start..l_end) |fi| {
                const child = children[flex_indices[fi]];
                col_h += final_heights_buf[fi] +
                    child.padding.top + child.padding.bottom +
                    child.border.top + child.border.bottom +
                    child.margin.top + child.margin.bottom;
            }
            if (col_h > max_col_height) max_col_height = col_h;
        }
        break :blk max_col_height;
    };
    box.content.height = used_height;
}

/// Column-direction flex layout.
fn layoutFlexColumn(box: *Box, is_reverse: bool, gap: f32, fonts: *FontCache) void {
    const style = box.style;
    const container_width = box.content.width;
    const children = box.children.items;
    if (children.len == 0) {
        box.content.height = switch (style.height) {
            .px => |h| h,
            .percent => |pct| pct * dom_api.g_viewport_height / 100.0,
            .auto, .none, .min_content, .max_content, .fit_content, .content => 0,
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

    // Dispatch to wrap path if flex-wrap is enabled (CSS Flexbox L1 §5.2, §9.3)
    if (style.flex_wrap == .wrap or style.flex_wrap == .wrap_reverse) {
        layoutFlexColumnWrap(box, is_reverse, gap, fonts);
        return;
    }

    // Count flex-participating children
    var col_flex_count: usize = 0;
    for (children) |child| {
        if (child.style.position != .absolute and child.style.position != .fixed) {
            col_flex_count += 1;
        }
    }

    // Phase 1: Layout each child to get intrinsic heights
    for (children) |child| {
        if (child.style.position == .absolute or child.style.position == .fixed) continue;
        block.layoutBlock(child, container_width, box.content.y, fonts);
    }

    const gap_total = if (col_flex_count > 1) gap * @as(f32, @floatFromInt(col_flex_count - 1)) else 0;

    // Explicit container height (needed for flex-grow distribution)
    const explicit_h: ?f32 = switch (style.height) {
        .px => |h| h,
        .percent => |pct| if (box.content.height > 0) box.content.height else pct * dom_api.g_viewport_height / 100.0,
        .auto, .none, .min_content, .max_content, .fit_content, .content => null,
    };

    // Phase 2: Calculate total base main size and flex totals
    var total_base_size: f32 = 0;
    var total_grow: f32 = 0;
    var total_shrink: f32 = 0;

    for (children) |child| {
        if (child.style.position == .absolute or child.style.position == .fixed) continue;
        // flex-basis on column = height hint.
        // CSS Sizing L3 §5.2 box-sizing + CSS Flexbox L1 §9.2: with
        // `box-sizing: border-box`, an explicit flex-basis / height already
        // includes padding + border.
        const basis: ?f32 = resolveFlexBasis(child, explicit_h, fonts, false);
        const explicit_child_h: ?f32 = switch (child.style.height) {
            .px => |h| h,
            .percent => |pct| if (explicit_h) |eh| pct * eh / 100.0 else null,
            else => null,
        };
        const child_pad_bdr = child.padding.top + child.padding.bottom +
            child.border.top + child.border.bottom;
        const is_border_box = child.style.box_sizing == .border_box and
            (basis != null or explicit_child_h != null);
        const child_outer_extra = child.margin.top + child.margin.bottom +
            if (is_border_box) @as(f32, 0) else child_pad_bdr;
        const child_main = basis orelse (explicit_child_h orelse child.content.height);
        total_base_size += child_main + child_outer_extra;
        total_grow += child.style.flex_grow;
        total_shrink += child.style.flex_shrink;
    }

    total_base_size += gap_total;

    // Determine container main size
    const container_main = explicit_h orelse total_base_size;
    const available = container_main - gap_total;
    const free_space = available - (total_base_size - gap_total);

    // Phase 3: Compute final heights with flex-grow/shrink distribution
    var final_heights_buf: [256]f32 = undefined;
    var final_heights_len: usize = 0;
    const has_flex = (free_space > 0 and total_grow > 0) or (free_space < 0 and total_shrink > 0);

    for (children) |child| {
        if (child.style.position == .absolute or child.style.position == .fixed) continue;
        if (final_heights_len >= 256) break;

        const basis: ?f32 = resolveFlexBasis(child, explicit_h, fonts, false);
        const explicit_child_h: ?f32 = switch (child.style.height) {
            .px => |h| h,
            .percent => |pct| if (explicit_h) |eh| pct * eh / 100.0 else null,
            else => null,
        };
        const is_border_box_c = child.style.box_sizing == .border_box and
            (basis != null or explicit_child_h != null);
        const child_pad_bdr_c = child.padding.top + child.padding.bottom +
            child.border.top + child.border.bottom;
        var child_main = basis orelse (explicit_child_h orelse child.content.height);

        if (free_space > 0 and total_grow > 0) {
            child_main += free_space * child.style.flex_grow / total_grow;
        } else if (free_space < 0 and total_shrink > 0) {
            child_main += free_space * child.style.flex_shrink / total_shrink;
        }

        // border-box: `child_main` is the outer (border-box) size — convert to
        // content size before storing (subsequent code treats stored value as
        // content height).
        if (is_border_box_c) {
            child_main = @max(child_main - child_pad_bdr_c, 0);
        }

        // Apply min-height constraint
        const min_h: f32 = switch (child.style.min_height) {
            .px => |mh| mh,
            .percent => |pct| if (explicit_h) |eh| pct * eh / 100.0 else 0,
            else => 0,
        };
        if (child_main < min_h) child_main = min_h;
        if (child_main < 0) child_main = 0;

        final_heights_buf[final_heights_len] = child_main;
        final_heights_len += 1;
    }

    // Phase 3.5: Re-layout children with adjusted heights if flex changed them
    if (has_flex) {
        var flex_idx: usize = 0;
        for (children) |child| {
            if (child.style.position == .absolute or child.style.position == .fixed) continue;
            if (flex_idx < final_heights_len) {
                child.content.height = final_heights_buf[flex_idx];
            }
            flex_idx += 1;
        }
    }

    // Phase 4: Calculate total used main for justify-content
    var total_used: f32 = 0;
    {
        var flex_idx: usize = 0;
        for (children) |child| {
            if (child.style.position == .absolute or child.style.position == .fixed) continue;
            if (flex_idx < final_heights_len) {
                total_used += final_heights_buf[flex_idx] + child.padding.top + child.padding.bottom +
                    child.border.top + child.border.bottom + child.margin.top + child.margin.bottom;
            }
            flex_idx += 1;
        }
    }
    total_used += gap_total;

    // Position children
    var cursor_y: f32 = 0;

    // Justify content offsets
    const justify_space = container_main - total_used;
    var per_gap = gap;

    switch (style.justify_content) {
        // §5.1 + Flexbox L1 §8.1: "normal" resolves to "flex-start"
        .normal, .flex_start => {},
        .flex_end => {
            cursor_y = justify_space;
        },
        .center => {
            cursor_y = justify_space / 2;
        },
        .space_between => {
            if (col_flex_count > 1) {
                per_gap = gap + justify_space / @as(f32, @floatFromInt(col_flex_count - 1));
            }
        },
        .space_around => {
            if (col_flex_count > 0) {
                const space = justify_space / @as(f32, @floatFromInt(col_flex_count));
                cursor_y = space / 2;
                per_gap = gap + space;
            }
        },
        .space_evenly => {
            if (col_flex_count > 0) {
                const space = justify_space / @as(f32, @floatFromInt(col_flex_count + 1));
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
            .auto => {
                // "normal" in flex context behaves as "stretch"
                const child_non_content_ac = child.padding.left + child.padding.right +
                    child.border.left + child.border.right + child.margin.left + child.margin.right;
                const stretched_width_ac = @max(container_width - child_non_content_ac, 0);
                if (switch (child.style.width) {
                    .auto => true,
                    else => false,
                }) {
                    child.content.width = stretched_width_ac;
                }
            },
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

// ═══════════════════════════════════════════════════════════════════════════
// flex-basis intrinsic keyword tests (CSS Flexbox L1 §9.2, Sizing L3 §5, L4 §6)
//
// Invoked from src/test_flex_basis.zig (dedicated test step `test-flex-basis`)
// via `_ = @import("layout/flex.zig")`.
// ═══════════════════════════════════════════════════════════════════════════

const testing = std.testing;

fn tfMakeContainer(width: f32) Box {
    var b = Box{};
    b.box_type = .block;
    b.style.display = .flex;
    b.style.width = .{ .px = width };
    b.content = .{ .x = 0, .y = 0, .width = width, .height = 0 };
    return b;
}

fn tfMakeChild(_: f32) Box {
    var b = Box{};
    b.box_type = .block;
    b.style.display = .block;
    b.style.width = .auto;
    return b;
}

/// Create a grandchild block with an explicit px width. Attaching one to a
/// flex child gives that child a non-zero max-content contribution equal to
/// `px_width` (via shrink-to-fit over the grandchild's right edge).
fn tfMakeContent(px_width: f32) Box {
    var b = Box{};
    b.box_type = .block;
    b.style.display = .block;
    b.style.width = .{ .px = px_width };
    return b;
}

fn tfAttach(alloc: std.mem.Allocator, parent: *Box, child: *Box) !void {
    child.parent = parent;
    try parent.children.append(alloc, child);
}

fn tfRun(container: *Box, fonts: *FontCache, out: []f32) void {
    layoutFlex(container, container.content.width, 0, fonts);
    for (container.children.items, 0..) |c, i| {
        if (i >= out.len) break;
        out[i] = c.content.width;
    }
}

fn tfFonts(alloc: std.mem.Allocator) FontCache {
    // Font is never touched for childless block children in our tests.
    return FontCache.init(alloc, "/dev/null");
}

test "flex-basis: px — uses explicit value" {
    const alloc = testing.allocator;
    var fonts = tfFonts(alloc);
    defer fonts.deinit();

    var root = tfMakeContainer(600);
    defer root.children.deinit(alloc);
    var a = tfMakeChild(50);
    a.style.flex_basis = .{ .px = 150 };
    defer a.children.deinit(alloc);
    var b = tfMakeChild(50);
    b.style.flex_basis = .{ .px = 250 };
    defer b.children.deinit(alloc);
    try tfAttach(alloc, &root, &a);
    try tfAttach(alloc, &root, &b);

    var widths: [2]f32 = undefined;
    tfRun(&root, &fonts, &widths);
    try testing.expectApproxEqAbs(@as(f32, 150), widths[0], 0.5);
    try testing.expectApproxEqAbs(@as(f32, 250), widths[1], 0.5);
}

test "flex-basis: percent — resolves against container main size" {
    const alloc = testing.allocator;
    var fonts = tfFonts(alloc);
    defer fonts.deinit();

    var root = tfMakeContainer(400);
    defer root.children.deinit(alloc);
    var a = tfMakeChild(10);
    a.style.flex_basis = .{ .percent = 25 };
    defer a.children.deinit(alloc);
    var b = tfMakeChild(10);
    b.style.flex_basis = .{ .percent = 50 };
    defer b.children.deinit(alloc);
    try tfAttach(alloc, &root, &a);
    try tfAttach(alloc, &root, &b);

    var widths: [2]f32 = undefined;
    tfRun(&root, &fonts, &widths);
    try testing.expectApproxEqAbs(@as(f32, 100), widths[0], 0.5);
    try testing.expectApproxEqAbs(@as(f32, 200), widths[1], 0.5);
}

test "flex-basis: auto — falls back to width property" {
    const alloc = testing.allocator;
    var fonts = tfFonts(alloc);
    defer fonts.deinit();

    var root = tfMakeContainer(600);
    defer root.children.deinit(alloc);
    var a = tfMakeChild(10);
    a.style.flex_basis = .auto;
    a.style.width = .{ .px = 120 };
    defer a.children.deinit(alloc);
    try tfAttach(alloc, &root, &a);

    var widths: [1]f32 = undefined;
    tfRun(&root, &fonts, &widths);
    try testing.expectApproxEqAbs(@as(f32, 120), widths[0], 0.5);
}

test "flex-basis: max-content — ignores width, uses measured content" {
    // CSS Sizing L4 §6: `content`/`max-content` ignores the main-size property.
    const alloc = testing.allocator;
    var fonts = tfFonts(alloc);
    defer fonts.deinit();

    var root = tfMakeContainer(600);
    defer root.children.deinit(alloc);
    var a = tfMakeChild(0);
    a.style.flex_basis = .max_content;
    a.style.width = .{ .px = 300 }; // would win only if basis fell back to width
    defer a.children.deinit(alloc);
    var a_inner = tfMakeContent(80); // defines max-content contribution = 80
    defer a_inner.children.deinit(alloc);
    try tfAttach(alloc, &a, &a_inner);
    try tfAttach(alloc, &root, &a);

    var widths: [1]f32 = undefined;
    tfRun(&root, &fonts, &widths);
    try testing.expectApproxEqAbs(@as(f32, 80), widths[0], 0.5);
}

test "flex-basis: content — max-content contribution" {
    const alloc = testing.allocator;
    var fonts = tfFonts(alloc);
    defer fonts.deinit();

    var root = tfMakeContainer(600);
    defer root.children.deinit(alloc);
    var a = tfMakeChild(0);
    a.style.flex_basis = .content;
    defer a.children.deinit(alloc);
    var a_inner = tfMakeContent(70);
    defer a_inner.children.deinit(alloc);
    try tfAttach(alloc, &a, &a_inner);
    var b = tfMakeChild(0);
    b.style.flex_basis = .content;
    defer b.children.deinit(alloc);
    var b_inner = tfMakeContent(130);
    defer b_inner.children.deinit(alloc);
    try tfAttach(alloc, &b, &b_inner);
    try tfAttach(alloc, &root, &a);
    try tfAttach(alloc, &root, &b);

    var widths: [2]f32 = undefined;
    tfRun(&root, &fonts, &widths);
    try testing.expectApproxEqAbs(@as(f32, 70), widths[0], 0.5);
    try testing.expectApproxEqAbs(@as(f32, 130), widths[1], 0.5);
}

test "flex-basis: min-content — narrowest (no words → 0)" {
    const alloc = testing.allocator;
    var fonts = tfFonts(alloc);
    defer fonts.deinit();

    var root = tfMakeContainer(600);
    defer root.children.deinit(alloc);
    var a = tfMakeChild(200);
    a.style.flex_basis = .min_content;
    a.style.flex_grow = 0;
    a.style.flex_shrink = 0;
    defer a.children.deinit(alloc);
    try tfAttach(alloc, &root, &a);

    var widths: [1]f32 = undefined;
    tfRun(&root, &fonts, &widths);
    // No text children → min-content = 0.
    try testing.expectApproxEqAbs(@as(f32, 0), widths[0], 0.5);
}

test "flex-basis: fit-content — clamped max-content" {
    // fit-content ≈ min(max-content, max(min-content, available)).
    const alloc = testing.allocator;
    var fonts = tfFonts(alloc);
    defer fonts.deinit();

    var root = tfMakeContainer(600);
    defer root.children.deinit(alloc);
    var a = tfMakeChild(0);
    a.style.flex_basis = .fit_content;
    a.style.flex_grow = 0;
    a.style.flex_shrink = 0;
    defer a.children.deinit(alloc);
    var a_inner = tfMakeContent(90);
    defer a_inner.children.deinit(alloc);
    try tfAttach(alloc, &a, &a_inner);
    try tfAttach(alloc, &root, &a);

    var widths: [1]f32 = undefined;
    tfRun(&root, &fonts, &widths);
    // max-content (90) < available (600) → 90.
    try testing.expectApproxEqAbs(@as(f32, 90), widths[0], 0.5);
}

test "flex-basis: mixed keywords in one row honour each item" {
    const alloc = testing.allocator;
    var fonts = tfFonts(alloc);
    defer fonts.deinit();

    var root = tfMakeContainer(800);
    defer root.children.deinit(alloc);
    var a = tfMakeChild(0);
    a.style.flex_basis = .{ .px = 100 };
    a.style.flex_grow = 0;
    a.style.flex_shrink = 0;
    defer a.children.deinit(alloc);
    var b = tfMakeChild(0);
    b.style.flex_basis = .max_content;
    b.style.flex_grow = 0;
    b.style.flex_shrink = 0;
    defer b.children.deinit(alloc);
    var b_inner = tfMakeContent(60);
    defer b_inner.children.deinit(alloc);
    try tfAttach(alloc, &b, &b_inner);
    var c = tfMakeChild(0);
    c.style.flex_basis = .{ .percent = 25 };
    c.style.flex_grow = 0;
    c.style.flex_shrink = 0;
    defer c.children.deinit(alloc);
    try tfAttach(alloc, &root, &a);
    try tfAttach(alloc, &root, &b);
    try tfAttach(alloc, &root, &c);

    var widths: [3]f32 = undefined;
    tfRun(&root, &fonts, &widths);
    try testing.expectApproxEqAbs(@as(f32, 100), widths[0], 0.5);
    try testing.expectApproxEqAbs(@as(f32, 60), widths[1], 0.5);
    try testing.expectApproxEqAbs(@as(f32, 200), widths[2], 0.5);
}

// ═══════════════════════════════════════════════════════════════════════════
// flex-wrap column tests (CSS Flexbox L1 §5.2, §9.3, §9.4, §9.6)
// ═══════════════════════════════════════════════════════════════════════════

/// Make a column flex container with explicit width and height.
fn tfMakeColumnContainer(width: f32, height: f32) Box {
    var b = Box{};
    b.box_type = .block;
    b.style.display = .flex;
    b.style.flex_direction = .column;
    b.style.flex_wrap = .wrap;
    b.style.width = .{ .px = width };
    b.style.height = .{ .px = height };
    b.content = .{ .x = 0, .y = 0, .width = width, .height = 0 };
    return b;
}

/// Make a child box with explicit height (main-axis size in column layout).
fn tfMakeColumnChild(height: f32) Box {
    var b = Box{};
    b.box_type = .block;
    b.style.display = .block;
    b.style.height = .{ .px = height };
    b.style.width = .auto;
    return b;
}

/// Run column layout and collect per-child (x, y, width, height) into out.
fn tfRunColumnXYWH(container: *Box, fonts: *FontCache, out: [][4]f32) void {
    layoutFlex(container, container.content.width, 0, fonts);
    for (container.children.items, 0..) |c, i| {
        if (i >= out.len) break;
        out[i] = .{ c.content.x, c.content.y, c.content.width, c.content.height };
    }
}

test "flex-wrap column: 4 items wrap into 2 columns of 2" {
    // Container: 200px wide, 100px tall, flex-direction:column, flex-wrap:wrap.
    // Items: each 60px tall. Two fit per column (2×60=120>100 with the 3rd,
    // but 60≤100 so first item fits, second 60+60=120>100 → wraps).
    // §9.3: column 1 = items 0,1 is NOT correct — 60+60=120 > 100, so only
    // item 0 goes in col 1, item 1 starts col 2.
    // Actually 60 ≤ 100 so item 0 fits. Adding item 1: 60+60=120 > 100 →
    // item 1 starts a new column. Same for items 2 and 3.
    // Result: 4 columns of 1 item each? No — re-check: items 0,1,2,3 each 40px.
    const alloc = testing.allocator;
    var fonts = tfFonts(alloc);
    defer fonts.deinit();

    // Use 40px items in a 100px container: 2 fit per column (40+40=80≤100).
    var root = tfMakeColumnContainer(200, 100);
    root.style.align_items = .flex_start; // don't stretch widths
    defer root.children.deinit(alloc);

    var a = tfMakeColumnChild(40); a.style.width = .{ .px = 50 }; defer a.children.deinit(alloc);
    var b2 = tfMakeColumnChild(40); b2.style.width = .{ .px = 50 }; defer b2.children.deinit(alloc);
    var c2 = tfMakeColumnChild(40); c2.style.width = .{ .px = 50 }; defer c2.children.deinit(alloc);
    var d = tfMakeColumnChild(40); d.style.width = .{ .px = 50 }; defer d.children.deinit(alloc);
    try tfAttach(alloc, &root, &a);
    try tfAttach(alloc, &root, &b2);
    try tfAttach(alloc, &root, &c2);
    try tfAttach(alloc, &root, &d);

    var out: [4][4]f32 = undefined;
    tfRunColumnXYWH(&root, &fonts, &out);

    // Column 1: items 0,1 at x=0; column 2: items 2,3 at x=50.
    // Item 0: y=0, item 1: y=40, item 2: y=0 (new col), item 3: y=40.
    try testing.expectApproxEqAbs(@as(f32, 0), out[0][0], 0.5);  // x
    try testing.expectApproxEqAbs(@as(f32, 0), out[0][1], 0.5);  // y
    try testing.expectApproxEqAbs(@as(f32, 0), out[1][0], 0.5);  // x col1
    try testing.expectApproxEqAbs(@as(f32, 40), out[1][1], 0.5); // y=40
    try testing.expectApproxEqAbs(@as(f32, 50), out[2][0], 0.5); // x col2
    try testing.expectApproxEqAbs(@as(f32, 0), out[2][1], 0.5);  // y=0
    try testing.expectApproxEqAbs(@as(f32, 50), out[3][0], 0.5); // x col2
    try testing.expectApproxEqAbs(@as(f32, 40), out[3][1], 0.5); // y=40
}

test "flex-wrap column: 3 items, last alone in second column" {
    // Container 200px wide, 80px tall. Items: 50px, 50px, 50px.
    // First two fit (50+50=100>80? No: 50≤80 but 50+50=100>80 → item 1 wraps).
    // Actually 50≤80 fits, 50+50=100>80 → item 1 starts col 2.
    // Col 1: item 0 (y=0), Col 2: item 1 (y=0), Col 3: item 2 (y=0).
    // That's 3 single-item columns. Let's use 30px items instead:
    // 30+30=60≤80 → both fit. 30+30+30=90>80 → item 2 wraps.
    // Col 1: items 0,1; Col 2: item 2.
    const alloc = testing.allocator;
    var fonts = tfFonts(alloc);
    defer fonts.deinit();

    var root = tfMakeColumnContainer(200, 80);
    root.style.align_items = .flex_start;
    defer root.children.deinit(alloc);

    var a = tfMakeColumnChild(30); a.style.width = .{ .px = 60 }; defer a.children.deinit(alloc);
    var b2 = tfMakeColumnChild(30); b2.style.width = .{ .px = 60 }; defer b2.children.deinit(alloc);
    var c2 = tfMakeColumnChild(30); c2.style.width = .{ .px = 40 }; defer c2.children.deinit(alloc);
    try tfAttach(alloc, &root, &a);
    try tfAttach(alloc, &root, &b2);
    try tfAttach(alloc, &root, &c2);

    var out: [3][4]f32 = undefined;
    tfRunColumnXYWH(&root, &fonts, &out);

    // Col 1: items 0,1 at x=0; col 2: item 2 at x=60.
    try testing.expectApproxEqAbs(@as(f32, 0), out[0][0], 0.5);  // item0 x
    try testing.expectApproxEqAbs(@as(f32, 0), out[0][1], 0.5);  // item0 y
    try testing.expectApproxEqAbs(@as(f32, 0), out[1][0], 0.5);  // item1 x
    try testing.expectApproxEqAbs(@as(f32, 30), out[1][1], 0.5); // item1 y
    try testing.expectApproxEqAbs(@as(f32, 60), out[2][0], 0.5); // item2 x (col 2)
    try testing.expectApproxEqAbs(@as(f32, 0), out[2][1], 0.5);  // item2 y
}

test "flex-wrap column: wrap-reverse reverses column order" {
    // Same setup as 2-column test but wrap_reverse: col 0 items appear at
    // higher x than col 1 items (line order reversed).
    const alloc = testing.allocator;
    var fonts = tfFonts(alloc);
    defer fonts.deinit();

    var root = tfMakeColumnContainer(200, 100);
    root.style.flex_wrap = .wrap_reverse;
    root.style.align_items = .flex_start;
    defer root.children.deinit(alloc);

    // 3 items of 40px; 2 fit per column.
    var a = tfMakeColumnChild(40); a.style.width = .{ .px = 50 }; defer a.children.deinit(alloc);
    var b2 = tfMakeColumnChild(40); b2.style.width = .{ .px = 50 }; defer b2.children.deinit(alloc);
    var c2 = tfMakeColumnChild(40); c2.style.width = .{ .px = 50 }; defer c2.children.deinit(alloc);
    try tfAttach(alloc, &root, &a);
    try tfAttach(alloc, &root, &b2);
    try tfAttach(alloc, &root, &c2);

    var out: [3][4]f32 = undefined;
    tfRunColumnXYWH(&root, &fonts, &out);

    // Without wrap-reverse: col0 at x=0, col1 at x=50.
    // With wrap-reverse: col0 is rendered last (at higher x), col1 at x=0.
    // Col 0 (items 0,1) → rendered at x=50; Col 1 (item 2) → rendered at x=0.
    try testing.expectApproxEqAbs(@as(f32, 50), out[0][0], 0.5); // item0 in col0 → x=50
    try testing.expectApproxEqAbs(@as(f32, 50), out[1][0], 0.5); // item1 in col0 → x=50
    try testing.expectApproxEqAbs(@as(f32, 0), out[2][0], 0.5);  // item2 in col1 → x=0
}

test "flex-wrap column: single item larger than container stays in one column" {
    // §9.3: An item that is larger than the container still forms exactly one
    // flex line (the item is never split).
    const alloc = testing.allocator;
    var fonts = tfFonts(alloc);
    defer fonts.deinit();

    var root = tfMakeColumnContainer(200, 50);
    root.style.align_items = .flex_start;
    defer root.children.deinit(alloc);

    var a = tfMakeColumnChild(120); // taller than the 50px container
    a.style.width = .{ .px = 80 };
    defer a.children.deinit(alloc);
    try tfAttach(alloc, &root, &a);

    var out: [1][4]f32 = undefined;
    tfRunColumnXYWH(&root, &fonts, &out);

    // Single item, single column, placed at x=0.
    try testing.expectApproxEqAbs(@as(f32, 0), out[0][0], 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0), out[0][1], 0.5);
}

test "flex-wrap column: mixed item heights in 2 columns" {
    // Container 200px wide, 100px tall. Items: 70px, 40px, 60px.
    // Item 0 (70px) fits alone (70≤100). Item 1: 70+40=110>100 → new col.
    // Item 1 (40px) fits. Item 2: 40+60=100≤100 → item 2 fits in col 2.
    // Col 1: item 0; Col 2: items 1,2.
    const alloc = testing.allocator;
    var fonts = tfFonts(alloc);
    defer fonts.deinit();

    var root = tfMakeColumnContainer(200, 100);
    root.style.align_items = .flex_start;
    defer root.children.deinit(alloc);

    var a = tfMakeColumnChild(70); a.style.width = .{ .px = 50 }; defer a.children.deinit(alloc);
    var b2 = tfMakeColumnChild(40); b2.style.width = .{ .px = 60 }; defer b2.children.deinit(alloc);
    var c2 = tfMakeColumnChild(60); c2.style.width = .{ .px = 60 }; defer c2.children.deinit(alloc);
    try tfAttach(alloc, &root, &a);
    try tfAttach(alloc, &root, &b2);
    try tfAttach(alloc, &root, &c2);

    var out: [3][4]f32 = undefined;
    tfRunColumnXYWH(&root, &fonts, &out);

    // Col 1 (item 0) at x=0; col 2 (items 1,2) at x=50.
    try testing.expectApproxEqAbs(@as(f32, 0), out[0][0], 0.5);  // item0 x=0
    try testing.expectApproxEqAbs(@as(f32, 0), out[0][1], 0.5);  // item0 y=0
    try testing.expectApproxEqAbs(@as(f32, 50), out[1][0], 0.5); // item1 x=50
    try testing.expectApproxEqAbs(@as(f32, 0), out[1][1], 0.5);  // item1 y=0
    try testing.expectApproxEqAbs(@as(f32, 50), out[2][0], 0.5); // item2 x=50
    try testing.expectApproxEqAbs(@as(f32, 40), out[2][1], 0.5); // item2 y=40
}

test "flex-wrap column: container height auto — no wrapping (indefinite main)" {
    // §9.3: When the flex container has no definite height (auto), all items
    // form a single column regardless of how tall they are.
    const alloc = testing.allocator;
    var fonts = tfFonts(alloc);
    defer fonts.deinit();

    var root = Box{};
    root.box_type = .block;
    root.style.display = .flex;
    root.style.flex_direction = .column;
    root.style.flex_wrap = .wrap;
    root.style.width = .{ .px = 200 };
    root.style.height = .auto; // indefinite
    root.style.align_items = .flex_start;
    root.content = .{ .x = 0, .y = 0, .width = 200, .height = 0 };
    defer root.children.deinit(alloc);

    var a = tfMakeColumnChild(50); a.style.width = .{ .px = 60 }; defer a.children.deinit(alloc);
    var b2 = tfMakeColumnChild(50); b2.style.width = .{ .px = 60 }; defer b2.children.deinit(alloc);
    var c2 = tfMakeColumnChild(50); c2.style.width = .{ .px = 60 }; defer c2.children.deinit(alloc);
    try tfAttach(alloc, &root, &a);
    try tfAttach(alloc, &root, &b2);
    try tfAttach(alloc, &root, &c2);

    var out: [3][4]f32 = undefined;
    tfRunColumnXYWH(&root, &fonts, &out);

    // All items in one column at x=0.
    try testing.expectApproxEqAbs(@as(f32, 0), out[0][0], 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0), out[1][0], 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0), out[2][0], 0.5);
    // Stacked vertically.
    try testing.expectApproxEqAbs(@as(f32, 0), out[0][1], 0.5);
    try testing.expectApproxEqAbs(@as(f32, 50), out[1][1], 0.5);
    try testing.expectApproxEqAbs(@as(f32, 100), out[2][1], 0.5);
}

test "flex-wrap column: align-items flex-start keeps item width" {
    // Cross-axis (width) with align-items:flex-start should leave item widths
    // at their intrinsic values rather than stretching to column width.
    const alloc = testing.allocator;
    var fonts = tfFonts(alloc);
    defer fonts.deinit();

    var root = tfMakeColumnContainer(300, 80);
    root.style.align_items = .flex_start;
    defer root.children.deinit(alloc);

    var a = tfMakeColumnChild(40); a.style.width = .{ .px = 70 }; defer a.children.deinit(alloc);
    var b2 = tfMakeColumnChild(40); b2.style.width = .{ .px = 90 }; defer b2.children.deinit(alloc);
    // Both fit in one column (40+40=80≤80).
    try tfAttach(alloc, &root, &a);
    try tfAttach(alloc, &root, &b2);

    var out: [2][4]f32 = undefined;
    tfRunColumnXYWH(&root, &fonts, &out);

    // One column. Item widths stay at their explicit values.
    try testing.expectApproxEqAbs(@as(f32, 70), out[0][2], 0.5);  // item0 width=70
    try testing.expectApproxEqAbs(@as(f32, 90), out[1][2], 0.5);  // item1 width=90
    // Both at x=0.
    try testing.expectApproxEqAbs(@as(f32, 0), out[0][0], 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0), out[1][0], 0.5);
}

// ═══════════════════════════════════════════════════════════════════════════
// box-sizing: border-box on flex items
//
// Spec:
// - CSS Box Model §3 — specified width/height with `border-box` INCLUDES
//   padding + border; content size = specified − (padding + border).
// - CSS Sizing L3 §5.2 — box-sizing property.
// - CSS Flexbox L1 §9.2 — used flex-basis derives from box-sizing-aware size.
// ═══════════════════════════════════════════════════════════════════════════

test "box-sizing: border-box row — flex-basis includes padding" {
    // Row, container 600px. Child: flex-basis:200px, padding:10 L+R,
    // box-sizing:border-box. Expected content.width = 200 − 20 = 180,
    // outer (border-box) main size = 200.
    const alloc = testing.allocator;
    var fonts = tfFonts(alloc);
    defer fonts.deinit();

    var root = tfMakeContainer(600);
    defer root.children.deinit(alloc);
    var a = tfMakeChild(0);
    a.style.flex_basis = .{ .px = 200 };
    a.style.flex_grow = 0;
    a.style.flex_shrink = 0;
    a.style.box_sizing = .border_box;
    a.padding = .{ .left = 10, .right = 10, .top = 0, .bottom = 0 };
    defer a.children.deinit(alloc);
    try tfAttach(alloc, &root, &a);

    var widths: [1]f32 = undefined;
    tfRun(&root, &fonts, &widths);
    try testing.expectApproxEqAbs(@as(f32, 180), widths[0], 0.5);
}

test "box-sizing: border-box row — width includes border" {
    // Row. Child: width:150px, border:5 each side, box-sizing:border-box.
    // Expected content.width = 150 − 10 = 140.
    const alloc = testing.allocator;
    var fonts = tfFonts(alloc);
    defer fonts.deinit();

    var root = tfMakeContainer(600);
    defer root.children.deinit(alloc);
    var a = tfMakeChild(0);
    a.style.flex_basis = .auto;
    a.style.width = .{ .px = 150 };
    a.style.flex_grow = 0;
    a.style.flex_shrink = 0;
    a.style.box_sizing = .border_box;
    a.border = .{ .left = 5, .right = 5, .top = 0, .bottom = 0 };
    defer a.children.deinit(alloc);
    try tfAttach(alloc, &root, &a);

    var widths: [1]f32 = undefined;
    tfRun(&root, &fonts, &widths);
    try testing.expectApproxEqAbs(@as(f32, 140), widths[0], 0.5);
}

test "box-sizing: border-box column — height includes padding" {
    // Column, container 200×400. Child: height:100, padding:15 top+bottom,
    // box-sizing:border-box. Expected content.height = 100 − 30 = 70.
    const alloc = testing.allocator;
    var fonts = tfFonts(alloc);
    defer fonts.deinit();

    var root = Box{};
    root.box_type = .block;
    root.style.display = .flex;
    root.style.flex_direction = .column;
    root.style.width = .{ .px = 200 };
    root.style.height = .{ .px = 400 };
    root.style.align_items = .flex_start;
    root.content = .{ .x = 0, .y = 0, .width = 200, .height = 0 };
    defer root.children.deinit(alloc);

    var a = Box{};
    a.box_type = .block;
    a.style.display = .block;
    a.style.width = .{ .px = 100 };
    a.style.height = .{ .px = 100 };
    a.style.flex_grow = 0;
    a.style.flex_shrink = 0;
    a.style.box_sizing = .border_box;
    a.padding = .{ .top = 15, .bottom = 15, .left = 0, .right = 0 };
    defer a.children.deinit(alloc);
    try tfAttach(alloc, &root, &a);

    layoutFlex(&root, 200, 0, &fonts);
    try testing.expectApproxEqAbs(@as(f32, 70), a.content.height, 0.5);
}

test "box-sizing: mixed content-box / border-box siblings in row" {
    // Two siblings, no grow/shrink:
    //   A: flex-basis:100, border-box, padding 10 L+R → content = 80
    //   B: flex-basis:100, content-box (default), padding 10 L+R → content = 100
    // Outer sizes: A=100, B=120. A.x=0, B.x=100.
    const alloc = testing.allocator;
    var fonts = tfFonts(alloc);
    defer fonts.deinit();

    var root = tfMakeContainer(600);
    defer root.children.deinit(alloc);
    var a = tfMakeChild(0);
    a.style.flex_basis = .{ .px = 100 };
    a.style.flex_grow = 0;
    a.style.flex_shrink = 0;
    a.style.box_sizing = .border_box;
    a.padding = .{ .left = 10, .right = 10, .top = 0, .bottom = 0 };
    defer a.children.deinit(alloc);
    var b = tfMakeChild(0);
    b.style.flex_basis = .{ .px = 100 };
    b.style.flex_grow = 0;
    b.style.flex_shrink = 0;
    b.style.box_sizing = .content_box;
    b.padding = .{ .left = 10, .right = 10, .top = 0, .bottom = 0 };
    defer b.children.deinit(alloc);
    try tfAttach(alloc, &root, &a);
    try tfAttach(alloc, &root, &b);

    layoutFlex(&root, 600, 0, &fonts);
    try testing.expectApproxEqAbs(@as(f32, 80), a.content.width, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 100), b.content.width, 0.5);
    // A occupies 0..100 (outer). B starts at 100 + pad-left (10) = 110.
    try testing.expectApproxEqAbs(@as(f32, 10), a.content.x, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 110), b.content.x, 0.5);
}

test "box-sizing: border-box with flex-basis length and wrap" {
    // Wrap row. Container 300. Three items each flex-basis:120 border-box,
    // padding 10 L+R. Each outer width = 120. Two fit per line
    // (120+120=240≤300; 240+120=360>300 → wrap). content width each = 100.
    const alloc = testing.allocator;
    var fonts = tfFonts(alloc);
    defer fonts.deinit();

    var root = tfMakeContainer(300);
    root.style.flex_wrap = .wrap;
    defer root.children.deinit(alloc);

    var a = tfMakeChild(0);
    a.style.flex_basis = .{ .px = 120 };
    a.style.flex_grow = 0;
    a.style.flex_shrink = 0;
    a.style.box_sizing = .border_box;
    a.padding = .{ .left = 10, .right = 10, .top = 0, .bottom = 0 };
    defer a.children.deinit(alloc);
    var b = tfMakeChild(0);
    b.style.flex_basis = .{ .px = 120 };
    b.style.flex_grow = 0;
    b.style.flex_shrink = 0;
    b.style.box_sizing = .border_box;
    b.padding = .{ .left = 10, .right = 10, .top = 0, .bottom = 0 };
    defer b.children.deinit(alloc);
    var c = tfMakeChild(0);
    c.style.flex_basis = .{ .px = 120 };
    c.style.flex_grow = 0;
    c.style.flex_shrink = 0;
    c.style.box_sizing = .border_box;
    c.padding = .{ .left = 10, .right = 10, .top = 0, .bottom = 0 };
    defer c.children.deinit(alloc);
    try tfAttach(alloc, &root, &a);
    try tfAttach(alloc, &root, &b);
    try tfAttach(alloc, &root, &c);

    layoutFlex(&root, 300, 0, &fonts);
    // Each item content width = 120 − 20 = 100.
    try testing.expectApproxEqAbs(@as(f32, 100), a.content.width, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 100), b.content.width, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 100), c.content.width, 0.5);
}

test "box-sizing: border-box column wrap — heights include padding" {
    // Column wrap: container 200×100. Items each height:40 border-box,
    // padding 5 top+bottom → outer main = 40, content.height = 30.
    // Two items per column.
    const alloc = testing.allocator;
    var fonts = tfFonts(alloc);
    defer fonts.deinit();

    var root = Box{};
    root.box_type = .block;
    root.style.display = .flex;
    root.style.flex_direction = .column;
    root.style.flex_wrap = .wrap;
    root.style.width = .{ .px = 200 };
    root.style.height = .{ .px = 100 };
    root.style.align_items = .flex_start;
    root.content = .{ .x = 0, .y = 0, .width = 200, .height = 0 };
    defer root.children.deinit(alloc);

    var a = Box{};
    a.box_type = .block;
    a.style.display = .block;
    a.style.width = .{ .px = 50 };
    a.style.height = .{ .px = 40 };
    a.style.box_sizing = .border_box;
    a.padding = .{ .top = 5, .bottom = 5, .left = 0, .right = 0 };
    defer a.children.deinit(alloc);
    var b = Box{};
    b.box_type = .block;
    b.style.display = .block;
    b.style.width = .{ .px = 50 };
    b.style.height = .{ .px = 40 };
    b.style.box_sizing = .border_box;
    b.padding = .{ .top = 5, .bottom = 5, .left = 0, .right = 0 };
    defer b.children.deinit(alloc);
    try tfAttach(alloc, &root, &a);
    try tfAttach(alloc, &root, &b);

    layoutFlex(&root, 200, 0, &fonts);
    try testing.expectApproxEqAbs(@as(f32, 30), a.content.height, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 30), b.content.height, 0.5);
}

test "box-sizing: border-box row with border and padding combined" {
    // Row, container 600. Child: width:200 border-box, padding:10 L+R,
    // border:5 L+R. content.width = 200 − 20 − 10 = 170.
    const alloc = testing.allocator;
    var fonts = tfFonts(alloc);
    defer fonts.deinit();

    var root = tfMakeContainer(600);
    defer root.children.deinit(alloc);
    var a = tfMakeChild(0);
    a.style.flex_basis = .auto;
    a.style.width = .{ .px = 200 };
    a.style.flex_grow = 0;
    a.style.flex_shrink = 0;
    a.style.box_sizing = .border_box;
    a.padding = .{ .left = 10, .right = 10, .top = 0, .bottom = 0 };
    a.border = .{ .left = 5, .right = 5, .top = 0, .bottom = 0 };
    defer a.children.deinit(alloc);
    try tfAttach(alloc, &root, &a);

    var widths: [1]f32 = undefined;
    tfRun(&root, &fonts, &widths);
    try testing.expectApproxEqAbs(@as(f32, 170), widths[0], 0.5);
}
