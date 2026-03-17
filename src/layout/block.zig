const std = @import("std");
const Box = @import("box.zig").Box;
const BoxType = @import("box.zig").BoxType;
const LineBox = @import("box.zig").LineBox;
const FontCache = @import("../paint/painter.zig").FontCache;
const flex = @import("flex.zig");
const table = @import("table.zig");

/// Lay out a block box and all its children within the given containing width.
/// Sets content x, y, width, height for each box.
pub fn layoutBlock(box: *Box, containing_width: f32, cursor_y: f32, fonts: *FontCache) void {
    // Delegate to flex layout if display is flex
    if (box.style.display == .flex or box.style.display == .inline_flex) {
        flex.layoutFlex(box, containing_width, cursor_y, fonts);
        return;
    }

    // Delegate to table layout if display is table
    if (box.style.display == .table) {
        table.layoutTable(box, containing_width, cursor_y, fonts);
        return;
    }

    // Content x starts after padding + border (left side).
    const content_x = box.padding.left + box.border.left;
    box.content.x = content_x;
    box.content.y = cursor_y + box.padding.top + box.border.top;

    // Compute content width based on box-sizing model
    const pad_h = box.padding.left + box.padding.right;
    const bdr_h = box.border.left + box.border.right;
    const margin_h = box.margin.left + box.margin.right;

    // For margin:auto centering, we need to know explicit width first
    var explicit_width: ?f32 = switch (box.style.width) {
        .px => |w| w,
        .percent => |pct| pct * containing_width / 100.0,
        else => null,
    };

    // box-sizing: border-box means width includes padding+border
    if (box.style.box_sizing == .border_box) {
        if (explicit_width) |ew| {
            explicit_width = @max(ew - pad_h - bdr_h, 0);
        }
    }

    // Calculate auto width (when no explicit width is set)
    const h_space = margin_h + pad_h + bdr_h;
    const auto_width = @max(containing_width - h_space, 0);

    if (explicit_width) |ew| {
        box.content.width = @min(ew, @max(containing_width - pad_h - bdr_h, 0));

        // margin:auto centering — only when both margins are auto and width is set
        if (box.style.margin_left_auto and box.style.margin_right_auto) {
            const remaining = @max(containing_width - ew - pad_h - bdr_h, 0);
            const auto_margin = remaining / 2.0;
            box.margin.left = auto_margin;
            box.margin.right = auto_margin;
            box.content.x = content_x + auto_margin;
        } else if (box.style.margin_left_auto) {
            const remaining = @max(containing_width - ew - pad_h - bdr_h - box.margin.right, 0);
            box.margin.left = remaining;
            box.content.x = content_x + remaining;
        } else if (box.style.margin_right_auto) {
            const remaining = @max(containing_width - ew - pad_h - bdr_h - box.margin.left, 0);
            box.margin.right = remaining;
        }
    } else {
        box.content.width = auto_width;
    }

    // Apply min/max width constraints
    switch (box.style.min_width) {
        .px => |mw| {
            if (box.content.width < mw) box.content.width = mw;
        },
        .percent => |pct| {
            const mw = pct * containing_width / 100.0;
            if (box.content.width < mw) box.content.width = mw;
        },
        else => {},
    }
    switch (box.style.max_width) {
        .px => |mw| {
            if (box.content.width > mw) box.content.width = mw;
        },
        .percent => |pct| {
            const mw = pct * containing_width / 100.0;
            if (box.content.width > mw) box.content.width = mw;
        },
        else => {},
    }

    // Handle <hr> elements
    if (box.is_hr) {
        box.content.height = 0; // The border-top provides the visual line
        return;
    }

    // Determine if children are all inline (inline formatting context)
    // or all block (block formatting context).
    // After wrapInlineChildren in tree.zig, a block's children are either
    // all block-level or all inline-level.
    var has_inline = false;
    var has_block = false;
    for (box.children.items) |child| {
        switch (child.box_type) {
            .inline_text, .inline_box => {
                has_inline = true;
            },
            .replaced => {
                // Replaced elements with inline display are inline-level
                if (child.style.display == .inline_ or child.style.display == .inline_block) {
                    has_inline = true;
                } else {
                    has_block = true;
                }
            },
            else => {
                has_block = true;
            },
        }
    }

    if (has_inline and !has_block) {
        // Inline formatting context: lay out children horizontally with wrapping
        layoutInlineFormattingContext(box, fonts);
    } else {
        // Block formatting context (also handles empty children)
        layoutBlockChildren(box, fonts);
    }

    // Apply explicit height if set
    switch (box.style.height) {
        .px => |h| {
            box.content.height = h;
        },
        else => {},
    }

    // Apply min/max height constraints
    switch (box.style.min_height) {
        .px => |mh| {
            if (box.content.height < mh) box.content.height = mh;
        },
        else => {},
    }
    switch (box.style.max_height) {
        .px => |mh| {
            if (box.content.height > mh) box.content.height = mh;
        },
        else => {},
    }
}

/// Layout children in block formatting context (all children are block-level).
fn layoutBlockChildren(box: *Box, fonts: *FontCache) void {
    var child_y: f32 = 0;
    var prev_margin_bottom: f32 = 0;

    // Track floats for basic float support
    var float_left_bottom: f32 = 0;
    var float_right_bottom: f32 = 0;
    var float_left_width: f32 = 0;
    var float_right_width: f32 = 0;

    for (box.children.items) |child| {
        switch (child.box_type) {
            .block, .anonymous_block, .inline_box => {
                // Handle clear property
                if (child.style.clear == .left or child.style.clear == .both) {
                    if (float_left_bottom > child_y) child_y = float_left_bottom;
                }
                if (child.style.clear == .right or child.style.clear == .both) {
                    if (float_right_bottom > child_y) child_y = float_right_bottom;
                }

                // Handle floated elements
                if (child.style.float_ != .none) {
                    layoutFloat(child, box, &child_y, &float_left_bottom, &float_right_bottom, &float_left_width, &float_right_width, fonts);
                    continue;
                }

                // Margin collapsing: use max of adjacent margins
                const collapsed_margin = @max(prev_margin_bottom, child.margin.top);
                child_y += collapsed_margin;

                // Available width considering floats
                const avail_width = if (child_y < float_left_bottom or child_y < float_right_bottom)
                    @max(box.content.width - float_left_width - float_right_width, 0)
                else
                    box.content.width;

                layoutBlock(child, avail_width, box.content.y + child_y, fonts);

                // Adjust child x position relative to parent content area
                var x_offset = box.content.x;
                // If there's a left float, shift right
                if (child_y < float_left_bottom) {
                    x_offset += float_left_width;
                }
                adjustXPositions(child, x_offset);

                child_y += child.padding.top + child.border.top +
                    child.content.height +
                    child.padding.bottom + child.border.bottom;

                prev_margin_bottom = child.margin.bottom;
            },
            .inline_text => {
                // Apply margin collapse for text too
                const collapsed_margin = @max(prev_margin_bottom, child.margin.top);
                child_y += collapsed_margin;

                layoutInlineText(child, box.content.width, box.content.x, box.content.y + child_y, fonts);

                child_y += child.content.height;
                prev_margin_bottom = child.margin.bottom;
            },
            .replaced => {
                // Replaced element (image): fixed intrinsic dimensions
                const collapsed_margin = @max(prev_margin_bottom, child.margin.top);
                child_y += collapsed_margin;

                child.content.x = box.content.x + child.margin.left + child.padding.left + child.border.left;
                child.content.y = box.content.y + child_y + child.padding.top + child.border.top;

                // Scale down if wider than container, preserving aspect ratio
                var img_w = child.intrinsic_width;
                var img_h = child.intrinsic_height;
                const max_w = box.content.width - child.margin.left - child.margin.right -
                    child.padding.left - child.padding.right -
                    child.border.left - child.border.right;
                if (img_w > max_w and max_w > 0 and img_w > 0) {
                    const scale = max_w / img_w;
                    img_w = max_w;
                    img_h = img_h * scale;
                }
                child.content.width = img_w;
                child.content.height = img_h;

                child_y += child.padding.top + child.border.top +
                    child.content.height +
                    child.padding.bottom + child.border.bottom;
                prev_margin_bottom = child.margin.bottom;
            },
        }
    }

    // Add last child's margin bottom
    child_y += prev_margin_bottom;

    // Ensure we contain floats
    if (float_left_bottom > child_y) child_y = float_left_bottom;
    if (float_right_bottom > child_y) child_y = float_right_bottom;

    // Set this box's content height to contain all children
    box.content.height = child_y;
}

/// Basic float positioning: move element to left/right edge.
fn layoutFloat(child: *Box, parent: *Box, child_y: *f32, float_left_bottom: *f32, float_right_bottom: *f32, float_left_width: *f32, float_right_width: *f32, fonts: *FontCache) void {
    // Layout the float with available width
    const avail = parent.content.width - float_left_width.* - float_right_width.*;
    layoutBlock(child, avail, parent.content.y + child_y.*, fonts);

    const child_total_w = child.content.width + child.margin.left + child.margin.right +
        child.padding.left + child.padding.right +
        child.border.left + child.border.right;
    const child_total_h = child.content.height + child.margin.top + child.margin.bottom +
        child.padding.top + child.padding.bottom +
        child.border.top + child.border.bottom;

    if (child.style.float_ == .left) {
        // Position at left edge
        const dx = parent.content.x + float_left_width.* - child.content.x + child.padding.left + child.border.left + child.margin.left;
        adjustXPositions(child, dx);
        float_left_width.* += child_total_w;
        const bottom = child_y.* + child_total_h;
        if (bottom > float_left_bottom.*) float_left_bottom.* = bottom;
    } else {
        // Position at right edge
        const right_x = parent.content.x + parent.content.width - float_right_width.* - child_total_w;
        const dx = right_x - child.content.x + child.padding.left + child.border.left + child.margin.left;
        adjustXPositions(child, dx);
        float_right_width.* += child_total_w;
        const bottom = child_y.* + child_total_h;
        if (bottom > float_right_bottom.*) float_right_bottom.* = bottom;
    }
}

/// Layout children in inline formatting context.
/// Multiple inline children flow horizontally, wrapping to next line when needed.
fn layoutInlineFormattingContext(box: *Box, fonts: *FontCache) void {
    const container_width = box.content.width;
    const base_x = box.content.x;
    const base_y = box.content.y;
    const allocator = fonts.allocator;

    var cursor_x: f32 = 0; // Current x position within the line (relative to content)
    var cursor_y: f32 = 0; // Current y position for lines
    var line_height: f32 = 0; // Max height of current line

    // We accumulate inline items and emit line boxes for text.
    // For inline-box (inline-block), we treat it as a single unit on the line.

    for (box.children.items) |child| {
        switch (child.box_type) {
            .inline_text => {
                const text = child.text orelse continue;
                if (text.len == 0) continue;

                const size_px: u32 = @intFromFloat(child.style.font_size_px);
                const text_renderer = fonts.getRenderer(size_px) orelse continue;

                // Measure text
                const full_metrics = text_renderer.measure(text);
                const raw_height: f32 = @floatFromInt(full_metrics.height);
                const text_line_height: f32 = raw_height * 1.4;
                const ascent: f32 = @floatFromInt(full_metrics.ascent);
                const text_width: f32 = @floatFromInt(full_metrics.width);

                child.lines = .empty;
                child.content.x = base_x;
                child.content.y = base_y + cursor_y;

                // Handle pre mode
                const is_pre = child.style.white_space == .pre or child.style.white_space == .pre_wrap;
                if (is_pre) {
                    layoutPreText(child, text, base_x + cursor_x, base_y + cursor_y, container_width, text_renderer, text_line_height, ascent, allocator);
                    cursor_y += child.content.height;
                    cursor_x = 0;
                    if (text_line_height > line_height) line_height = text_line_height;
                    continue;
                }

                // Handle nowrap
                const is_nowrap = child.style.white_space == .nowrap;

                // Check if entire text fits on current line
                const remaining_width = container_width - cursor_x;

                if ((text_width <= remaining_width or is_nowrap) and remaining_width > 0) {
                    // Fits on current line
                    const line_x = applyTextAlignInline(base_x + cursor_x, text_width, container_width, cursor_x, child.style.text_align);
                    child.lines.append(allocator, .{
                        .x = line_x,
                        .y = base_y + cursor_y,
                        .width = text_width,
                        .height = text_line_height,
                        .text = text,
                        .ascent = ascent,
                    }) catch {};
                    child.content.width = text_width;
                    child.content.height = text_line_height;
                    cursor_x += text_width;
                    if (text_line_height > line_height) line_height = text_line_height;
                } else {
                    // Need to word-wrap, possibly starting mid-line
                    var total_text_height: f32 = 0;
                    var max_text_width: f32 = 0;
                    var line_start: usize = 0;
                    var last_break: usize = 0;
                    var current_line_width = cursor_x;
                    var first_line = true;

                    var i: usize = 0;
                    while (i < text.len) {
                        if (text[i] == ' ') {
                            last_break = i;
                        }
                        const segment = text[line_start .. i + 1];
                        const seg_metrics = text_renderer.measure(segment);
                        const seg_width: f32 = @floatFromInt(seg_metrics.width);

                        const avail_w = if (first_line) (container_width - cursor_x) else container_width;
                        if (seg_width > avail_w and line_start < i) {
                            const break_pos = if (last_break > line_start) last_break else i;
                            const line_text = text[line_start..break_pos];
                            if (line_text.len > 0) {
                                const lm = text_renderer.measure(line_text);
                                const lw: f32 = @floatFromInt(lm.width);
                                const lx = if (first_line) (base_x + cursor_x) else base_x;
                                child.lines.append(allocator, .{
                                    .x = lx,
                                    .y = base_y + cursor_y + total_text_height,
                                    .width = lw,
                                    .height = text_line_height,
                                    .text = line_text,
                                    .ascent = ascent,
                                }) catch {};
                                total_text_height += text_line_height;
                                current_line_width = 0;
                                if (lw > max_text_width) max_text_width = lw;
                                first_line = false;
                            }
                            line_start = break_pos;
                            if (line_start < text.len and text[line_start] == ' ') {
                                line_start += 1;
                            }
                            last_break = line_start;
                        }
                        i += 1;
                    }

                    // Last segment
                    if (line_start < text.len) {
                        const line_text = text[line_start..];
                        const lm = text_renderer.measure(line_text);
                        const lw: f32 = @floatFromInt(lm.width);
                        const lx = if (first_line) (base_x + cursor_x) else base_x;
                        child.lines.append(allocator, .{
                            .x = lx,
                            .y = base_y + cursor_y + total_text_height,
                            .width = lw,
                            .height = text_line_height,
                            .text = line_text,
                            .ascent = ascent,
                        }) catch {};
                        total_text_height += text_line_height;
                        current_line_width = lw;
                        if (lw > max_text_width) max_text_width = lw;
                    }

                    child.content.width = max_text_width;
                    child.content.height = total_text_height;
                    cursor_y += total_text_height - text_line_height; // Already on last line
                    cursor_x = current_line_width;
                    if (text_line_height > line_height) line_height = text_line_height;
                }
            },
            .inline_box => {
                // Inline-block: layout as block, then place on current line
                const child_h_extra = child.margin.left + child.margin.right +
                    child.padding.left + child.padding.right +
                    child.border.left + child.border.right;

                // First layout to get intrinsic size
                layoutBlock(child, container_width, base_y + cursor_y, fonts);

                const child_total_w = child.content.width + child_h_extra;
                const child_total_h = child.content.height + child.margin.top + child.margin.bottom +
                    child.padding.top + child.padding.bottom +
                    child.border.top + child.border.bottom;

                // Check if it fits on current line
                if (cursor_x + child_total_w > container_width and cursor_x > 0) {
                    // Wrap to next line
                    cursor_y += line_height;
                    cursor_x = 0;
                    line_height = 0;
                }

                // Re-layout at correct position
                layoutBlock(child, container_width, base_y + cursor_y, fonts);

                // Position the child
                const dx = base_x + cursor_x - child.content.x + child.padding.left + child.border.left + child.margin.left;
                adjustXPositions(child, dx);

                cursor_x += child_total_w;
                if (child_total_h > line_height) line_height = child_total_h;
            },
            .replaced => {
                // Inline replaced element (e.g., img with inline display)
                var img_w = child.intrinsic_width;
                var img_h = child.intrinsic_height;
                const child_extra_w = child.margin.left + child.margin.right +
                    child.padding.left + child.padding.right +
                    child.border.left + child.border.right;
                const child_extra_h = child.margin.top + child.margin.bottom +
                    child.padding.top + child.padding.bottom +
                    child.border.top + child.border.bottom;

                // Scale down if needed
                const max_w = container_width - child_extra_w;
                if (img_w > max_w and max_w > 0 and img_w > 0) {
                    const scale = max_w / img_w;
                    img_w = max_w;
                    img_h = img_h * scale;
                }

                const total_w = img_w + child_extra_w;
                const total_h = img_h + child_extra_h;

                // Check if fits on current line
                if (cursor_x + total_w > container_width and cursor_x > 0) {
                    cursor_y += line_height;
                    cursor_x = 0;
                    line_height = 0;
                }

                child.content.x = base_x + cursor_x + child.margin.left + child.padding.left + child.border.left;
                child.content.y = base_y + cursor_y + child.margin.top + child.padding.top + child.border.top;
                child.content.width = img_w;
                child.content.height = img_h;

                cursor_x += total_w;
                if (total_h > line_height) line_height = total_h;
            },
            else => {
                // Shouldn't happen in inline context, but handle gracefully
                layoutBlock(child, container_width, base_y + cursor_y + line_height, fonts);
                adjustXPositions(child, base_x);
                cursor_y += line_height + child.content.height + child.padding.top + child.padding.bottom + child.border.top + child.border.bottom;
                cursor_x = 0;
                line_height = 0;
            },
        }
    }

    // Account for the last line
    cursor_y += line_height;

    box.content.height = cursor_y;
}

/// Apply text-align for inline text that starts at a given x offset within a line.
fn applyTextAlignInline(base_x: f32, text_width: f32, container_width: f32, cursor_x: f32, text_align: @import("../style/computed.zig").ComputedStyle.TextAlign) f32 {
    _ = cursor_x;
    return switch (text_align) {
        .center => base_x + @max((container_width - text_width) / 2, 0) - base_x + base_x,
        else => base_x,
    };
}

/// Recursively adjust x positions of a box and all its descendants.
pub fn adjustXPositions(box: *Box, offset_x: f32) void {
    box.content.x += offset_x;

    for (box.children.items) |child| {
        switch (child.box_type) {
            .block, .anonymous_block, .inline_box => {
                adjustXPositions(child, offset_x);
            },
            .inline_text => {
                child.content.x += offset_x;
                for (child.lines.items) |*line| {
                    line.x += offset_x;
                }
            },
            .replaced => {
                child.content.x += offset_x;
            },
        }
    }
}

/// Recursively adjust y positions of a box and all its descendants.
pub fn adjustYPositions(box: *Box, offset_y: f32) void {
    box.content.y += offset_y;

    for (box.children.items) |child| {
        switch (child.box_type) {
            .block, .anonymous_block, .inline_box => {
                adjustYPositions(child, offset_y);
            },
            .inline_text => {
                child.content.y += offset_y;
                for (child.lines.items) |*line| {
                    line.y += offset_y;
                }
            },
            .replaced => {
                child.content.y += offset_y;
            },
        }
    }
}

/// Break text into lines and compute line boxes (for standalone text in block context).
fn layoutInlineText(box: *Box, container_width: f32, base_x: f32, base_y: f32, fonts: *FontCache) void {
    const text = box.text orelse return;
    if (text.len == 0) return;

    box.lines = .empty;
    box.content.x = base_x;
    box.content.y = base_y;

    const size_px: u32 = @intFromFloat(box.style.font_size_px);
    const text_renderer = fonts.getRenderer(size_px) orelse return;
    const allocator = fonts.allocator;

    // Measure full text first
    const full_metrics = text_renderer.measure(text);
    // Apply 1.4x line-height for comfortable spacing (browsers default ~1.2)
    const raw_height: f32 = @floatFromInt(full_metrics.height);
    const line_height: f32 = raw_height * 1.4;
    const ascent: f32 = @floatFromInt(full_metrics.ascent);

    // Handle white-space: pre — preserve all whitespace and newlines
    const is_pre = box.style.white_space == .pre or box.style.white_space == .pre_wrap;
    if (is_pre) {
        layoutPreText(box, text, base_x, base_y, container_width, text_renderer, line_height, ascent, allocator);
        return;
    }

    // Handle white-space: nowrap — no wrapping
    const is_nowrap = box.style.white_space == .nowrap;

    // If the full text fits on one line or nowrap, no need to break
    const text_width: f32 = @floatFromInt(full_metrics.width);
    if (text_width <= container_width or container_width <= 0 or is_nowrap) {
        box.lines.append(allocator, .{
            .x = applyTextAlign(base_x, text_width, container_width, box.style.text_align),
            .y = base_y,
            .width = text_width,
            .height = line_height,
            .text = text,
            .ascent = ascent,
        }) catch {};
        box.content.width = text_width;
        box.content.height = line_height;
        return;
    }

    // Word-break the text
    var total_height: f32 = 0;
    var max_width: f32 = 0;
    var line_start: usize = 0;
    var last_break: usize = 0;
    var i: usize = 0;

    while (i < text.len) {
        // Find next word boundary
        if (text[i] == ' ') {
            last_break = i;
        }
        // Check if text from line_start to i+1 fits
        const segment = text[line_start .. i + 1];
        const seg_metrics = text_renderer.measure(segment);
        const seg_width: f32 = @floatFromInt(seg_metrics.width);

        if (seg_width > container_width and line_start < i) {
            // Need to break
            const break_pos = if (last_break > line_start) last_break else i;
            const line_text = text[line_start..break_pos];
            if (line_text.len > 0) {
                const lm = text_renderer.measure(line_text);
                const lw: f32 = @floatFromInt(lm.width);
                box.lines.append(allocator, .{
                    .x = applyTextAlign(base_x, lw, container_width, box.style.text_align),
                    .y = base_y + total_height,
                    .width = lw,
                    .height = line_height,
                    .text = line_text,
                    .ascent = ascent,
                }) catch {};
                total_height += line_height;
                if (lw > max_width) max_width = lw;
            }
            // Skip space after break
            line_start = break_pos;
            if (line_start < text.len and text[line_start] == ' ') {
                line_start += 1;
            }
            last_break = line_start;
        }
        i += 1;
    }

    // Last line
    if (line_start < text.len) {
        const line_text = text[line_start..];
        const lm = text_renderer.measure(line_text);
        const lw: f32 = @floatFromInt(lm.width);
        box.lines.append(allocator, .{
            .x = applyTextAlign(base_x, lw, container_width, box.style.text_align),
            .y = base_y + total_height,
            .width = lw,
            .height = line_height,
            .text = line_text,
            .ascent = ascent,
        }) catch {};
        total_height += line_height;
        if (lw > max_width) max_width = lw;
    }

    box.content.width = max_width;
    box.content.height = total_height;
}

/// Layout pre-formatted text, splitting on newlines.
fn layoutPreText(box: *Box, text: []const u8, base_x: f32, base_y: f32, container_width: f32, text_renderer: anytype, line_height: f32, ascent: f32, allocator: std.mem.Allocator) void {
    _ = container_width;
    var total_height: f32 = 0;
    var max_width: f32 = 0;
    var start: usize = 0;

    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i == text.len or text[i] == '\n') {
            const line_text = text[start..i];
            if (line_text.len > 0) {
                const lm = text_renderer.measure(line_text);
                const lw: f32 = @floatFromInt(lm.width);
                box.lines.append(allocator, .{
                    .x = base_x,
                    .y = base_y + total_height,
                    .width = lw,
                    .height = line_height,
                    .text = line_text,
                    .ascent = ascent,
                }) catch {};
                if (lw > max_width) max_width = lw;
            } else {
                // Empty line
                box.lines.append(allocator, .{
                    .x = base_x,
                    .y = base_y + total_height,
                    .width = 0,
                    .height = line_height,
                    .text = "",
                    .ascent = ascent,
                }) catch {};
            }
            total_height += line_height;
            start = i + 1;
        }
    }

    box.content.width = max_width;
    box.content.height = total_height;
}

/// Apply text-align to compute line x position.
fn applyTextAlign(base_x: f32, text_width: f32, container_width: f32, text_align: @import("../style/computed.zig").ComputedStyle.TextAlign) f32 {
    return switch (text_align) {
        .center => base_x + @max((container_width - text_width) / 2, 0),
        .right => base_x + @max(container_width - text_width, 0),
        else => base_x,
    };
}
