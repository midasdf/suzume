const std = @import("std");
const Box = @import("box.zig").Box;
const BoxType = @import("box.zig").BoxType;
const block = @import("block.zig");
const FontCache = @import("../paint/painter.zig").FontCache;
const ComputedStyle = @import("../css/computed.zig").ComputedStyle;

const MAX_COLS = 64;
const MAX_ROWS = 512;

/// Lay out a table element and its children.
pub fn layoutTable(box: *Box, containing_width: f32, cursor_y: f32, fonts: *FontCache) void {
    // Apply cellpadding from HTML attribute to all cells
    const cellpadding: f32 = if (box.dom_node) |dn|
        if (dn.getAttribute("cellpadding")) |cp|
            std.fmt.parseFloat(f32, cp) catch 0
        else
            0
    else
        0;
    const content_x = box.padding.left + box.border.left;
    box.content.x = content_x;
    box.content.y = cursor_y + box.padding.top + box.border.top;

    const h_space = box.margin.left + box.margin.right +
        box.padding.left + box.padding.right +
        box.border.left + box.border.right;
    // Check CSS width first, then HTML width attribute on <table>
    var explicit_w: ?f32 = switch (box.style.width) {
        .px => |w| w,
        .percent => |pct| pct * containing_width / 100.0,
        else => null,
    };
    if (explicit_w == null) {
        if (box.dom_node) |dn| {
            if (dn.getAttribute("width")) |w_str| {
                if (std.mem.endsWith(u8, w_str, "%")) {
                    if (std.fmt.parseFloat(f32, w_str[0 .. w_str.len - 1]) catch null) |pct| {
                        explicit_w = pct * containing_width / 100.0;
                    }
                } else {
                    explicit_w = std.fmt.parseFloat(f32, w_str) catch null;
                }
            }
        }
    }
    box.content.width = if (explicit_w) |w| @min(w, @max(containing_width - h_space, 0)) else @max(containing_width - h_space, 0);

    // Collect rows (flatten through row-groups)
    var rows_buf: [MAX_ROWS]*Box = undefined;
    var num_rows: usize = 0;
    collectRows(box, &rows_buf, &num_rows);

    if (num_rows == 0) {
        box.content.height = 0;
        return;
    }

    // Count columns (accounting for colspan)
    var num_cols: usize = 0;
    for (rows_buf[0..num_rows]) |row| {
        var col_span_total: usize = 0;
        for (row.children.items) |cell| {
            if (!isTableCell(cell)) continue;
            col_span_total += getColspan(cell);
        }
        if (col_span_total > num_cols) num_cols = col_span_total;
    }
    if (num_cols == 0) {
        box.content.height = 0;
        return;
    }
    if (num_cols > MAX_COLS) {
        std.log.warn("table layout: column limit ({d}) exceeded ({d} cols), truncating", .{ MAX_COLS, num_cols });
        num_cols = MAX_COLS;
    }

    // Determine column widths
    const table_width = box.content.width;
    var col_widths: [MAX_COLS]f32 = [_]f32{0} ** MAX_COLS;

    // Pass 1: collect explicit widths from cells (non-colspan cells only)
    var col_has_explicit: [MAX_COLS]bool = [_]bool{false} ** MAX_COLS;
    for (rows_buf[0..num_rows]) |row| {
        var col_idx: usize = 0;
        for (row.children.items) |cell| {
            if (!isTableCell(cell)) continue;
            const cs = getColspan(cell);
            if (col_idx >= num_cols) break;

            if (cs == 1) {
                const cell_w = getCellExplicitWidth(cell, table_width);
                if (cell_w) |w| {
                    if (w > col_widths[col_idx]) {
                        col_widths[col_idx] = w;
                        col_has_explicit[col_idx] = true;
                    }
                }
            }
            col_idx += cs;
        }
    }

    // Pass 2: estimate content width for flex columns using text length heuristic
    var col_min_content: [MAX_COLS]f32 = [_]f32{0} ** MAX_COLS;
    const sample_rows = @min(num_rows, 5);
    for (rows_buf[0..sample_rows]) |row| {
        var col_idx: usize = 0;
        for (row.children.items) |cell| {
            if (!isTableCell(cell)) continue;
            const cs = getColspan(cell);
            if (col_idx >= num_cols) break;

            if (cs == 1 and !col_has_explicit[col_idx]) {
                // Estimate content width from text length without pre-layout
                const est_w = estimateCellContentWidth(cell, cell.style.font_size_px);
                if (est_w > col_min_content[col_idx]) {
                    col_min_content[col_idx] = est_w;
                }
            }
            col_idx += cs;
        }
    }

    // Pass 3: distribute remaining width to columns without explicit widths
    var used_width: f32 = 0;
    var flex_cols: usize = 0;
    var flex_content_total: f32 = 0;
    for (0..num_cols) |i| {
        if (col_has_explicit[i]) {
            used_width += col_widths[i];
        } else {
            flex_cols += 1;
            flex_content_total += @max(col_min_content[i], 1);
        }
    }

    const remaining = @max(table_width - used_width, 0);
    if (flex_cols > 0) {
        if (flex_content_total > 0) {
            // Distribute proportionally to content width
            for (0..num_cols) |i| {
                if (!col_has_explicit[i]) {
                    const ratio = @max(col_min_content[i], 1) / flex_content_total;
                    col_widths[i] = remaining * ratio;
                }
            }
        } else {
            // Equal distribution fallback
            const flex_width = remaining / @as(f32, @floatFromInt(flex_cols));
            for (0..num_cols) |i| {
                if (!col_has_explicit[i]) {
                    col_widths[i] = flex_width;
                }
            }
        }
    } else if (used_width > 0 and used_width != table_width) {
        // Scale explicit widths to fill table
        const scale = table_width / used_width;
        for (0..num_cols) |i| {
            col_widths[i] *= scale;
        }
    }

    // Precompute column X positions
    var col_x: [MAX_COLS]f32 = [_]f32{0} ** MAX_COLS;
    col_x[0] = 0;
    for (1..num_cols) |i| {
        col_x[i] = col_x[i - 1] + col_widths[i - 1];
    }

    // Layout each row
    var row_y: f32 = 0;

    for (rows_buf[0..num_rows]) |row| {
        var col_idx: usize = 0;
        var max_row_height: f32 = 0;

        for (row.children.items) |cell| {
            if (!isTableCell(cell)) continue;
            if (col_idx >= num_cols) break;

            const cs = @min(getColspan(cell), num_cols - col_idx);

            // Calculate cell width (sum of spanned columns)
            var cell_width: f32 = 0;
            for (col_idx..col_idx + cs) |ci| {
                cell_width += col_widths[ci];
            }

            // Apply cellpadding to cell if padding wasn't set by CSS
            if (cellpadding >= 0) {
                // UA stylesheet sets padding:1px, cellpadding overrides it
                cell.padding = .{
                    .top = cellpadding,
                    .right = cellpadding,
                    .bottom = cellpadding,
                    .left = cellpadding,
                };
            }

            // Layout cell as a block
            block.layoutBlock(cell, cell_width, box.content.y + row_y, fonts);

            // Position cell at the correct column
            const cell_target_x = box.content.x + col_x[col_idx];
            const dx = cell_target_x - cell.content.x + cell.padding.left + cell.border.left + cell.margin.left;
            block.adjustXPositions(cell, dx);

            const cell_height = cell.content.height + cell.padding.top + cell.padding.bottom +
                cell.border.top + cell.border.bottom;
            if (cell_height > max_row_height) max_row_height = cell_height;

            col_idx += cs;
        }

        // Apply row height style (e.g. spacer rows with style="height:5px")
        const row_min_h: f32 = switch (row.style.height) {
            .px => |h| h,
            .percent => |pct| pct * box.content.height / 100.0,
            else => 0,
        };
        if (row_min_h > max_row_height) max_row_height = row_min_h;

        // Set row dimensions
        row.content.x = box.content.x;
        row.content.y = box.content.y + row_y;
        row.content.width = table_width;
        row.content.height = max_row_height;

        row_y += max_row_height;
    }

    // Position table-row-group wrappers (tbody etc) if present
    for (box.children.items) |child| {
        if (isRowGroup(child)) {
            child.content.x = box.content.x;
            child.content.y = box.content.y;
            child.content.width = table_width;
            child.content.height = row_y;
        }
    }

    box.content.height = row_y;
}

/// Estimate cell content width from text length without full layout.
/// Sums all inline text in the cell's subtree to estimate the width needed
/// for a single line (handles cells with many short text nodes across spans).
fn estimateCellContentWidth(cell: *Box, font_size: f32) f32 {
    var total_len: usize = 0;
    var max_block_len: usize = 0;
    sumInlineTextLen(cell, &total_len, &max_block_len, 0);
    // Use the longer of: total inline text or longest block-level line
    const effective_len = @max(total_len, max_block_len);
    const char_width = font_size * 0.6;
    return @as(f32, @floatFromInt(effective_len)) * char_width;
}

/// Sum text lengths for inline content estimation.
/// total_len accumulates text within the current inline context.
/// max_block_len tracks the longest inline run when block elements split the flow.
fn sumInlineTextLen(box: *Box, total_len: *usize, max_block_len: *usize, depth: u32) void {
    if (depth > 8) return;
    if (box.text) |text| {
        total_len.* += text.len;
    }
    for (box.children.items) |child| {
        const is_block = child.style.display == .block or
            child.style.display == .table or
            child.style.display == .table_row;
        if (is_block) {
            // Current inline run ends; start a new one for the block's content
            if (total_len.* > max_block_len.*) max_block_len.* = total_len.*;
            var block_len: usize = 0;
            sumInlineTextLen(child, &block_len, max_block_len, depth + 1);
            if (block_len > max_block_len.*) max_block_len.* = block_len;
        } else {
            sumInlineTextLen(child, total_len, max_block_len, depth + 1);
        }
    }
}

/// Get colspan attribute from a cell's DOM node.
fn getColspan(cell: *Box) usize {
    if (cell.dom_node) |dn| {
        if (dn.getAttribute("colspan")) |cs_str| {
            return std.fmt.parseInt(usize, cs_str, 10) catch 1;
        }
    }
    return 1;
}

/// Get explicit width from a cell's style or HTML width attribute.
fn getCellExplicitWidth(cell: *Box, table_width: f32) ?f32 {
    // CSS width takes priority
    switch (cell.style.width) {
        .px => |w| return w,
        .percent => |pct| return pct * table_width / 100.0,
        else => {},
    }
    // Check HTML width attribute
    if (cell.dom_node) |dn| {
        if (dn.getAttribute("width")) |w_str| {
            // Check if it's a percentage
            if (std.mem.endsWith(u8, w_str, "%")) {
                const num_str = w_str[0 .. w_str.len - 1];
                if (std.fmt.parseFloat(f32, num_str) catch null) |pct| {
                    return pct * table_width / 100.0;
                }
            } else {
                // Pixel value
                if (std.fmt.parseFloat(f32, w_str) catch null) |px| {
                    return px;
                }
            }
        }
        // Check inline style width (e.g., style="width:18px")
        if (dn.getAttribute("style")) |style_str| {
            if (parseInlineWidth(style_str, table_width)) |w| {
                return w;
            }
        }
    }
    return null;
}

/// Parse width from an inline style string (e.g., "width:18px;padding-right:4px").
fn parseInlineWidth(style: []const u8, table_width: f32) ?f32 {
    var pos: usize = 0;
    while (pos < style.len) {
        // Skip whitespace
        while (pos < style.len and (style[pos] == ' ' or style[pos] == '\t')) pos += 1;
        if (pos >= style.len) break;

        // Check for "width" (but not "min-width" or "max-width")
        if (pos + 5 <= style.len and std.mem.eql(u8, style[pos .. pos + 5], "width") and
            (pos == 0 or style[pos - 1] == ';' or style[pos - 1] == ' ' or style[pos - 1] == '\t'))
        {
            var p = pos + 5;
            // Skip whitespace and colon
            while (p < style.len and (style[p] == ' ' or style[p] == '\t')) p += 1;
            if (p < style.len and style[p] == ':') {
                p += 1;
                while (p < style.len and (style[p] == ' ' or style[p] == '\t')) p += 1;
                // Parse the value
                const val_start = p;
                while (p < style.len and (style[p] == '.' or (style[p] >= '0' and style[p] <= '9'))) p += 1;
                if (p > val_start) {
                    const val_str = style[val_start..p];
                    if (std.fmt.parseFloat(f32, val_str) catch null) |val| {
                        // Check unit
                        if (p + 1 < style.len and style[p] == 'p' and style[p + 1] == 'x') {
                            return val;
                        } else if (p < style.len and style[p] == '%') {
                            return val * table_width / 100.0;
                        } else {
                            // No unit, treat as px
                            return val;
                        }
                    }
                }
            }
        }

        // Skip to next property
        while (pos < style.len and style[pos] != ';') pos += 1;
        if (pos < style.len) pos += 1; // skip ';'
    }
    return null;
}

/// Collect all table-row boxes, flattening through row-groups.
/// Stops at nested tables (display: table) to avoid collecting their rows.
fn collectRows(parent: *Box, buf: []*Box, count: *usize) void {
    for (parent.children.items) |child| {
        // Skip nested tables — their rows belong to them, not to us
        if (child.style.display == .table) continue;

        if (isTableRow(child)) {
            if (count.* < buf.len) {
                buf[count.*] = child;
                count.* += 1;
            } else {
                std.log.warn("table layout: row limit ({d}) exceeded, truncating", .{buf.len});
                return;
            }
        } else if (isRowGroup(child)) {
            collectRows(child, buf, count);
        } else if (child.style.display == .block) {
            // A block child inside a table row-group might wrap table structure
            // (e.g. lexbor creates block wrappers around nested tables)
            // Only recurse if this block contains table-rows directly
            var has_table_rows = false;
            for (child.children.items) |grandchild| {
                if (isTableRow(grandchild)) {
                    has_table_rows = true;
                    break;
                }
            }
            if (has_table_rows) {
                // Check if this block is actually a nested table (has table display in DOM)
                if (child.dom_node) |dn| {
                    const tag = dn.tagName() orelse "";
                    if (std.mem.eql(u8, tag, "table") or std.mem.eql(u8, tag, "TABLE")) {
                        continue; // Skip — it's a nested table
                    }
                }
                collectRows(child, buf, count);
            }
        }
    }
}

fn isTableRow(b: *Box) bool {
    return b.style.display == .table_row;
}

fn isTableCell(b: *Box) bool {
    return b.style.display == .table_cell;
}

fn isRowGroup(b: *Box) bool {
    return b.style.display == .table_row_group or
        b.style.display == .table_header_group or
        b.style.display == .table_footer_group;
}
