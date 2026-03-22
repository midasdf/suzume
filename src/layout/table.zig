const std = @import("std");
const Box = @import("box.zig").Box;
const BoxType = @import("box.zig").BoxType;
const block = @import("block.zig");
const FontCache = @import("../paint/painter.zig").FontCache;
const ComputedStyle = @import("../css/computed.zig").ComputedStyle;

const MAX_COLS = 64;
const MAX_ROWS = 128;

/// Lay out a table element and its children.
pub fn layoutTable(box: *Box, containing_width: f32, cursor_y: f32, fonts: *FontCache) void {
    // Apply cellpadding from HTML attribute to all cells.
    // Distinguish "cellpadding=0" (explicit, override UA 1px) from "no attribute" (keep UA default).
    const has_cellpadding_attr = if (box.dom_node) |dn| dn.getAttribute("cellpadding") != null else false;
    const cellpadding: f32 = if (box.dom_node) |dn|
        if (dn.getAttribute("cellpadding")) |cp|
            std.fmt.parseFloat(f32, cp) catch 0
        else
            0
    else
        0;
    // cellspacing: HTML attribute only (default 0). CSS border-spacing not used for
    // table cell gaps to avoid breaking percentage-width tables like HN.
    const cellspacing: f32 = if (box.style.border_collapse)
        0
    else if (box.dom_node) |dn|
        if (dn.getAttribute("cellspacing")) |cs|
            std.fmt.parseFloat(f32, cs) catch 0
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

    // Build cell grid accounting for both colspan and rowspan.
    // The grid tracks which (row, col) cells are occupied and by which Box.
    // A cell with rowspan=2 marks the grid slots in subsequent rows as occupied.
    const GridCell = struct {
        box: ?*Box,
        is_spanned: bool, // true if this cell is occupied by a rowspan from above
    };
    var grid: [MAX_ROWS][MAX_COLS]GridCell = undefined;
    for (0..@min(num_rows, MAX_ROWS)) |ri| {
        for (0..MAX_COLS) |ci| {
            grid[ri][ci] = .{ .box = null, .is_spanned = false };
        }
    }

    // First pass: place cells into the grid
    var num_cols: usize = 0;
    for (rows_buf[0..num_rows], 0..) |row, ri| {
        var col_idx: usize = 0;
        for (row.children.items) |cell| {
            if (!isTableCell(cell)) continue;
            // Skip over cells occupied by rowspan from previous rows
            while (col_idx < MAX_COLS and grid[ri][col_idx].is_spanned) col_idx += 1;
            if (col_idx >= MAX_COLS) break;

            const cs = @min(getColspan(cell), MAX_COLS - col_idx);
            const rs = @min(getRowspan(cell), num_rows - ri);

            // Mark grid cells occupied by this cell
            for (ri..@min(ri + rs, num_rows)) |r| {
                for (col_idx..@min(col_idx + cs, MAX_COLS)) |c| {
                    grid[r][c] = .{
                        .box = if (r == ri) cell else null,
                        .is_spanned = r > ri,
                    };
                }
            }
            if (col_idx + cs > num_cols) num_cols = col_idx + cs;
            col_idx += cs;
        }
        if (col_idx > num_cols) num_cols = col_idx;
    }
    if (num_cols == 0) {
        box.content.height = 0;
        return;
    }
    if (num_cols > MAX_COLS) {
        std.log.warn("table layout: column limit ({d}) exceeded ({d} cols), truncating", .{ MAX_COLS, num_cols });
        num_cols = MAX_COLS;
    }

    // Collect <col>/<colgroup> width hints (HTML spec)
    var col_hints: [MAX_COLS]?f32 = [_]?f32{null} ** MAX_COLS;
    {
        var col_hint_idx: usize = 0;
        for (box.children.items) |child| {
            const is_col = child.style.display == .table_column;
            const is_colgroup = child.style.display == .table_column_group;
            if (is_col) {
                if (col_hint_idx < num_cols) {
                    if (getCellExplicitWidth(child, box.content.width)) |w| {
                        col_hints[col_hint_idx] = w;
                    }
                    col_hint_idx += 1;
                }
            } else if (is_colgroup) {
                // Process <col> children within <colgroup>
                for (child.children.items) |col_child| {
                    if (col_child.style.display == .table_column and col_hint_idx < num_cols) {
                        if (getCellExplicitWidth(col_child, box.content.width)) |w| {
                            col_hints[col_hint_idx] = w;
                        }
                        col_hint_idx += 1;
                    }
                }
            }
        }
    }

    // Determine column widths
    const table_width = box.content.width;
    var col_widths: [MAX_COLS]f32 = [_]f32{0} ** MAX_COLS;

    // Apply <col> width hints as initial values
    for (0..num_cols) |i| {
        if (col_hints[i]) |w| col_widths[i] = w;
    }

    // table-layout: fixed — column widths from first row only (CSS 2.1 §17.5.2.1)
    if (box.style.table_layout_fixed and num_rows > 0) {
        var col_has_explicit_fixed: [MAX_COLS]bool = [_]bool{false} ** MAX_COLS;
        // Apply <col> hints first
        for (0..num_cols) |ci| {
            if (col_hints[ci] != null) col_has_explicit_fixed[ci] = true;
        }
        // Then examine first row for explicit widths
        for (0..num_cols) |ci| {
            if (grid[0][ci].is_spanned or grid[0][ci].box == null) continue;
            const cell = grid[0][ci].box.?;
            const cs = @min(getColspan(cell), num_cols - ci);
            if (cs == 1) {
                if (getCellExplicitWidth(cell, table_width)) |w| {
                    col_widths[ci] = w;
                    col_has_explicit_fixed[ci] = true;
                }
            }
        }
        // Distribute remaining width equally among columns without explicit widths
        const spacing_total_fixed = cellspacing * @as(f32, @floatFromInt(num_cols + 1));
        var used_fixed: f32 = 0;
        var flex_fixed: usize = 0;
        for (0..num_cols) |i| {
            if (col_has_explicit_fixed[i]) {
                used_fixed += col_widths[i];
            } else {
                flex_fixed += 1;
            }
        }
        const remaining_fixed = @max(table_width - used_fixed - spacing_total_fixed, 0);
        if (flex_fixed > 0) {
            const each = remaining_fixed / @as(f32, @floatFromInt(flex_fixed));
            for (0..num_cols) |i| {
                if (!col_has_explicit_fixed[i]) col_widths[i] = each;
            }
        }
    } else {

    // Pass 1: collect explicit widths from cells (non-colspan cells only)
    // Use grid to get correct column indices
    var col_has_explicit: [MAX_COLS]bool = [_]bool{false} ** MAX_COLS;
    // Apply <col> hints as starting explicit widths
    for (0..num_cols) |ci| {
        if (col_hints[ci] != null) col_has_explicit[ci] = true;
    }
    for (0..num_rows) |ri| {
        for (0..num_cols) |ci| {
            if (grid[ri][ci].is_spanned or grid[ri][ci].box == null) continue;
            const cell = grid[ri][ci].box.?;
            const cs = @min(getColspan(cell), num_cols - ci);
            if (cs == 1) {
                const cell_w = getCellExplicitWidth(cell, table_width);
                if (cell_w) |w| {
                    if (w > col_widths[ci]) {
                        col_widths[ci] = w;
                        col_has_explicit[ci] = true;
                    }
                }
            }
        }
    }

    // Pass 2: estimate content width for flex columns using text length heuristic
    var col_min_content: [MAX_COLS]f32 = [_]f32{0} ** MAX_COLS;
    const sample_rows = @min(num_rows, 5);
    for (0..sample_rows) |ri| {
        for (0..num_cols) |ci| {
            if (grid[ri][ci].is_spanned or grid[ri][ci].box == null) continue;
            const cell = grid[ri][ci].box.?;
            const cs = @min(getColspan(cell), num_cols - ci);
            if (cs == 1 and !col_has_explicit[ci]) {
                const est_w = estimateCellContentWidth(cell, cell.style.font_size_px);
                if (est_w > col_min_content[ci]) {
                    col_min_content[ci] = est_w;
                }
            }
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

    const spacing_total = cellspacing * @as(f32, @floatFromInt(num_cols + 1));
    const remaining = @max(table_width - used_width - spacing_total, 0);
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

    } // end auto table-layout else branch

    // Precompute column X positions (with cellspacing gaps if set)
    var col_x: [MAX_COLS]f32 = [_]f32{0} ** MAX_COLS;
    col_x[0] = cellspacing;
    for (1..num_cols) |i| {
        col_x[i] = col_x[i - 1] + col_widths[i - 1] + cellspacing;
    }

    // Layout each row using the cell grid (supports rowspan)
    var row_y: f32 = cellspacing;
    var row_heights: [MAX_ROWS]f32 = [_]f32{0} ** MAX_ROWS;

    // Pass A: layout all cells and compute their natural heights
    for (rows_buf[0..num_rows], 0..) |_, ri| {
        for (0..num_cols) |ci| {
            if (grid[ri][ci].is_spanned or grid[ri][ci].box == null) continue;
            const cell = grid[ri][ci].box.?;
            const cs = @min(getColspan(cell), num_cols - ci);

            var cell_width: f32 = 0;
            for (ci..@min(ci + cs, num_cols)) |c| {
                cell_width += col_widths[c];
            }

            if (has_cellpadding_attr) {
                cell.padding = .{
                    .top = cellpadding,
                    .right = cellpadding,
                    .bottom = cellpadding,
                    .left = cellpadding,
                };
            }

            block.layoutBlock(cell, cell_width, box.content.y, fonts);

            const cell_height = cell.content.height + cell.padding.top + cell.padding.bottom +
                cell.border.top + cell.border.bottom;

            const rs = @min(getRowspan(cell), num_rows - ri);
            if (rs == 1) {
                if (cell_height > row_heights[ri]) row_heights[ri] = cell_height;
            }
            // Multi-row cells: distribute height later
        }
    }

    // Apply row height style
    for (rows_buf[0..num_rows], 0..) |row, ri| {
        const row_min_h: f32 = switch (row.style.height) {
            .px => |h| h,
            .percent => |pct| pct * box.content.height / 100.0,
            else => 0,
        };
        if (row_min_h > row_heights[ri]) row_heights[ri] = row_min_h;
    }

    // Pass B: ensure multi-row cells fit across their spanned rows
    for (0..num_rows) |ri| {
        for (0..num_cols) |ci| {
            if (grid[ri][ci].is_spanned or grid[ri][ci].box == null) continue;
            const cell = grid[ri][ci].box.?;
            const rs = @min(getRowspan(cell), num_rows - ri);
            if (rs <= 1) continue;

            const cell_height = cell.content.height + cell.padding.top + cell.padding.bottom +
                cell.border.top + cell.border.bottom;

            // Sum current heights of spanned rows
            var spanned_height: f32 = 0;
            for (ri..ri + rs) |r| {
                spanned_height += row_heights[r];
            }
            spanned_height += cellspacing * @as(f32, @floatFromInt(rs - 1));

            if (cell_height > spanned_height) {
                // Distribute extra height evenly across spanned rows
                const extra = (cell_height - spanned_height) / @as(f32, @floatFromInt(rs));
                for (ri..ri + rs) |r| {
                    row_heights[r] += extra;
                }
            }
        }
    }

    // Pass C: position all cells using final row heights
    // Compute row Y positions
    var row_y_pos: [MAX_ROWS]f32 = [_]f32{0} ** MAX_ROWS;
    row_y_pos[0] = cellspacing;
    for (1..num_rows) |ri| {
        row_y_pos[ri] = row_y_pos[ri - 1] + row_heights[ri - 1] + cellspacing;
    }

    for (0..num_rows) |ri| {
        for (0..num_cols) |ci| {
            if (grid[ri][ci].is_spanned or grid[ri][ci].box == null) continue;
            const cell = grid[ri][ci].box.?;
            const rs = @min(getRowspan(cell), num_rows - ri);

            // Position cell at correct column
            const cell_target_x = box.content.x + col_x[ci];
            const cell_target_y = box.content.y + row_y_pos[ri];
            const dx = cell_target_x - cell.content.x + cell.padding.left + cell.border.left + cell.margin.left;
            const dy = cell_target_y + cell.padding.top + cell.border.top - cell.content.y;
            if (dx != 0) block.adjustXPositions(cell, dx);
            if (dy != 0) block.adjustYPositions(cell, dy);

            // Vertical alignment within total spanned height
            var total_cell_h: f32 = 0;
            for (ri..ri + rs) |r| {
                total_cell_h += row_heights[r];
            }
            total_cell_h += cellspacing * @as(f32, @floatFromInt(if (rs > 1) rs - 1 else 0));

            const cell_content_h = cell.content.height + cell.padding.top + cell.padding.bottom +
                cell.border.top + cell.border.bottom;
            if (cell_content_h < total_cell_h) {
                const valign_dy: f32 = switch (cell.style.vertical_align) {
                    .middle => (total_cell_h - cell_content_h) / 2,
                    .bottom => total_cell_h - cell_content_h,
                    else => 0,
                };
                if (valign_dy > 0.5) {
                    block.adjustYPositions(cell, valign_dy);
                }
            }
        }
    }

    // Set row dimensions
    for (rows_buf[0..num_rows], 0..) |row, ri| {
        row.content.x = box.content.x;
        row.content.y = box.content.y + row_y_pos[ri];
        row.content.width = table_width;
        row.content.height = row_heights[ri];
    }

    row_y = row_y_pos[num_rows - 1] + row_heights[num_rows - 1] + cellspacing;

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

/// Get rowspan attribute from a cell's DOM node.
fn getRowspan(cell: *Box) usize {
    if (cell.dom_node) |dn| {
        if (dn.getAttribute("rowspan")) |rs_str| {
            const rs = std.fmt.parseInt(usize, rs_str, 10) catch 1;
            return if (rs == 0) 1 else rs; // rowspan=0 means "all remaining rows" but we treat as 1
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
