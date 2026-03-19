const std = @import("std");
const Box = @import("box.zig").Box;
const BoxType = @import("box.zig").BoxType;
const block = @import("block.zig");
const FontCache = @import("../paint/painter.zig").FontCache;
const ComputedStyle = @import("../css/computed.zig").ComputedStyle;

/// Lay out a table element and its children.
pub fn layoutTable(box: *Box, containing_width: f32, cursor_y: f32, fonts: *FontCache) void {
    const content_x = box.padding.left + box.border.left;
    box.content.x = content_x;
    box.content.y = cursor_y + box.padding.top + box.border.top;

    const h_space = box.margin.left + box.margin.right +
        box.padding.left + box.padding.right +
        box.border.left + box.border.right;
    const explicit_w = switch (box.style.width) {
        .px => |w| w,
        .percent => |pct| pct * containing_width / 100.0,
        else => null,
    };
    box.content.width = if (explicit_w) |w| @min(w, @max(containing_width - h_space, 0)) else @max(containing_width - h_space, 0);

    // Collect rows
    var rows_buf: [128]*Box = undefined;
    var num_rows: usize = 0;
    collectRows(box, &rows_buf, &num_rows);

    if (num_rows == 0) {
        box.content.height = 0;
        return;
    }

    // Count max columns
    var num_cols: usize = 0;
    for (rows_buf[0..num_rows]) |row| {
        const cell_count = countCells(row);
        if (cell_count > num_cols) num_cols = cell_count;
    }

    if (num_cols == 0) {
        box.content.height = 0;
        return;
    }

    // ── Calculate column widths respecting td width attributes/CSS ──
    const table_width = box.content.width;
    var col_widths: [64]f32 = undefined;
    const effective_cols = @min(num_cols, 64);

    // Initialize all to 0 (unspecified)
    for (col_widths[0..effective_cols]) |*w| w.* = 0;

    // First pass: collect explicit widths from first row's cells
    if (num_rows > 0) {
        var col_idx: usize = 0;
        for (rows_buf[0].children.items) |cell| {
            if (!isTableCell(cell)) continue;
            if (col_idx >= effective_cols) break;

            // Check CSS width
            switch (cell.style.width) {
                .px => |w| {
                    col_widths[col_idx] = w;
                },
                .percent => |pct| {
                    // width:100% in a table cell means "take remaining space" (auto-like)
                    // Only apply percentages < 100 as fixed proportions
                    if (pct < 100) {
                        col_widths[col_idx] = pct * table_width / 100.0;
                    }
                    // else: leave as 0 (auto) — will get remaining space
                },
                else => {},
            }
            col_idx += 1;
        }
    }

    // Second pass: distribute remaining width to unspecified columns
    var specified_total: f32 = 0;
    var unspecified_count: usize = 0;
    for (col_widths[0..effective_cols]) |w| {
        if (w > 0) {
            specified_total += w;
        } else {
            unspecified_count += 1;
        }
    }

    const remaining = @max(table_width - specified_total, 0);
    const auto_width = if (unspecified_count > 0)
        remaining / @as(f32, @floatFromInt(unspecified_count))
    else
        0;

    for (col_widths[0..effective_cols]) |*w| {
        if (w.* == 0) w.* = auto_width;
    }

    // If total exceeds table width, scale down proportionally
    var total_col_width: f32 = 0;
    for (col_widths[0..effective_cols]) |w| total_col_width += w;
    if (total_col_width > table_width and total_col_width > 0) {
        const scale = table_width / total_col_width;
        for (col_widths[0..effective_cols]) |*w| w.* *= scale;
    }

    // Layout each row
    var row_y: f32 = 0;

    for (rows_buf[0..num_rows]) |row| {
        var col_idx: usize = 0;
        var max_row_height: f32 = 0;

        for (row.children.items) |cell| {
            if (!isTableCell(cell)) continue;
            if (col_idx >= effective_cols) break;

            // Layout cell with its column width
            const cell_w = col_widths[col_idx];
            block.layoutBlock(cell, cell_w, box.content.y + row_y, fonts);

            // Position cell at correct column x
            var col_x: f32 = 0;
            for (0..col_idx) |c| {
                col_x += if (c < effective_cols) col_widths[c] else 0;
            }
            const target_x = box.content.x + col_x + cell.padding.left + cell.border.left + cell.margin.left;
            const dx = target_x - cell.content.x;
            block.adjustXPositions(cell, dx);

            const cell_height = cell.content.height + cell.padding.top + cell.padding.bottom +
                cell.border.top + cell.border.bottom;
            if (cell_height > max_row_height) max_row_height = cell_height;

            col_idx += 1;
        }

        // Set row dimensions
        row.content.x = box.content.x;
        row.content.y = box.content.y + row_y;
        row.content.width = table_width;
        row.content.height = max_row_height;

        row_y += max_row_height;
    }

    // Position table-row-group wrappers (tbody etc)
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

/// Collect all table-row boxes, flattening through row-groups.
fn collectRows(parent: *Box, buf: []*Box, count: *usize) void {
    for (parent.children.items) |child| {
        if (isTableRow(child)) {
            if (count.* < buf.len) {
                buf[count.*] = child;
                count.* += 1;
            }
        } else if (isRowGroup(child)) {
            collectRows(child, buf, count);
        }
    }
}

fn countCells(row: *Box) usize {
    var count: usize = 0;
    for (row.children.items) |child| {
        if (isTableCell(child)) count += 1;
    }
    return count;
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
