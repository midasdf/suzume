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
    // Note: margins are handled by the parent's layout, not here.
    const content_x = box.padding.left + box.border.left;
    box.content.x = content_x;
    box.content.y = cursor_y + box.padding.top + box.border.top;

    // Content width = containing width minus horizontal margin/padding/border
    const h_space = box.margin.left + box.margin.right +
        box.padding.left + box.padding.right +
        box.border.left + box.border.right;

    // Apply explicit width if set
    const auto_width = @max(containing_width - h_space, 0);
    box.content.width = switch (box.style.width) {
        .px => |w| @min(w, auto_width),
        .percent => |pct| @min(pct * containing_width / 100.0, auto_width),
        else => auto_width,
    };

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

    // Layout children
    var child_y: f32 = 0;
    var prev_margin_bottom: f32 = 0;

    for (box.children.items) |child| {
        switch (child.box_type) {
            .block, .anonymous_block => {
                // Margin collapsing: use max of adjacent margins
                const collapsed_margin = @max(prev_margin_bottom, child.margin.top);
                child_y += collapsed_margin;

                layoutBlock(child, box.content.width, box.content.y + child_y, fonts);

                // Adjust child and all its descendants' x positions
                // to be relative to parent content area
                adjustXPositions(child, box.content.x);

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

    // Set this box's content height to contain all children
    box.content.height = child_y;

    // Apply explicit height if set (percent heights need parent height, skip if unknown)
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

/// Recursively adjust x positions of a box and all its descendants.
pub fn adjustXPositions(box: *Box, offset_x: f32) void {
    box.content.x += offset_x;

    for (box.children.items) |child| {
        switch (child.box_type) {
            .block, .anonymous_block => {
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
            .block, .anonymous_block => {
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

/// Break text into lines and compute line boxes.
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
    const line_height: f32 = @floatFromInt(full_metrics.height);
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
