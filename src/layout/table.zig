const std = @import("std");
const Box = @import("box.zig").Box;
const BoxType = @import("box.zig").BoxType;
const block = @import("block.zig");
const FontCache = @import("../paint/painter.zig").FontCache;
const ComputedStyle = @import("../style/computed.zig").ComputedStyle;

/// Lay out a table element and its children.
/// Assumes the table box has children that are table-row boxes,
/// each containing table-cell boxes.
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

    // Collect rows: direct children that are table-row or table-row-group descendants
    // For simplicity, flatten: gather all rows (including those in tbody/thead/tfoot)
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

    // Calculate column widths: distribute evenly
    const table_width = box.content.width;
    const col_width = table_width / @as(f32, @floatFromInt(num_cols));

    // Layout each row
    var row_y: f32 = 0;

    for (rows_buf[0..num_rows]) |row| {
        // Layout each cell in this row with the column width
        var col_idx: usize = 0;
        var max_row_height: f32 = 0;

        for (row.children.items) |cell| {
            if (!isTableCell(cell)) continue;
            if (col_idx >= num_cols) break;

            // Layout cell as a block with column width
            const cell_containing = col_width;
            block.layoutBlock(cell, cell_containing, box.content.y + row_y, fonts);

            // Position cell at the correct column
            const cell_x = box.content.x + @as(f32, @floatFromInt(col_idx)) * col_width;
            const dx = cell_x - cell.content.x + cell.padding.left + cell.border.left + cell.margin.left;
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

/// Collect all table-row boxes, flattening through row-groups.
fn collectRows(parent: *Box, buf: []*Box, count: *usize) void {
    for (parent.children.items) |child| {
        if (isTableRow(child)) {
            if (count.* < buf.len) {
                buf[count.*] = child;
                count.* += 1;
            }
        } else if (isRowGroup(child)) {
            // Recurse into tbody/thead/tfoot
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
