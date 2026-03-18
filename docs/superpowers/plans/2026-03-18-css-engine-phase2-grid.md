# CSS Grid Layout Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement CSS Grid layout engine to fix Wikipedia, MDN, and Stack Overflow sidebar layouts.

**Architecture:** Add grid properties to ComputedStyle, parse `grid-template-columns`/`grid-template-rows` from CSS, implement a grid layout algorithm in `src/layout/grid.zig` that positions children in a 2D grid. Replace the current grid→flex/block fallback in `block.zig`.

**Tech Stack:** Zig 0.15, builds on existing layout engine (Box, ComputedStyle, FontCache).

**Spec:** `docs/superpowers/specs/2026-03-18-css-engine-design.md` (Phase 2: Grid section)

---

## File Structure

```
src/css/ast.zig          -- Add grid PropertyId values
src/css/cascade.zig      -- Add grid property application in applyDeclaration
src/style/computed.zig   -- Add grid fields to ComputedStyle
src/layout/grid.zig      -- NEW: Grid layout algorithm
src/layout/block.zig     -- Replace grid→flex fallback with grid.layoutGrid()
src/layout/box.zig       -- Add grid placement fields to Box
tests/test_grid.zig      -- Grid layout tests
```

---

## Task 1: Grid Properties in ComputedStyle

**Files:**
- Modify: `src/style/computed.zig`
- Modify: `src/css/ast.zig`

- [ ] **Step 1: Add grid types to ComputedStyle**

Add to `src/style/computed.zig`:
```zig
// Grid
pub const GridTrackSize = union(enum) {
    px: f32,
    fr: f32,          // fractional unit
    percent: f32,
    auto,
    min_content,
    max_content,
};

pub const GridAutoFlow = enum {
    row,
    column,
    row_dense,
    column_dense,
};
```

Add fields to ComputedStyle struct:
```zig
// Grid container properties
grid_template_columns: []const GridTrackSize = &.{},
grid_template_rows: []const GridTrackSize = &.{},
grid_auto_flow: GridAutoFlow = .row,
// gap already exists as f32 — reuse for grid-gap
// row_gap/column_gap: use gap for both (simplification)

// Grid item properties
grid_column_start: i16 = 0,  // 0 = auto
grid_column_end: i16 = 0,
grid_row_start: i16 = 0,
grid_row_end: i16 = 0,
```

- [ ] **Step 2: Add grid PropertyIds to ast.zig**

Ensure these exist in the PropertyId enum and property_map:
```
grid_template_columns, grid_template_rows,
grid_column_start, grid_column_end, grid_row_start, grid_row_end,
grid_auto_flow
```

- [ ] **Step 3: Commit**

```
feat(css): add grid properties to ComputedStyle and PropertyId
```

---

## Task 2: Parse Grid Properties in Cascade

**Files:**
- Modify: `src/css/cascade.zig`

- [ ] **Step 1: Parse grid-template-columns/rows**

In `applyDeclaration`, add cases for grid properties:

```zig
.grid_template_columns => {
    style.grid_template_columns = parseGridTemplate(trimmed, arena) orelse &.{};
},
.grid_template_rows => {
    style.grid_template_rows = parseGridTemplate(trimmed, arena) orelse &.{};
},
.grid_auto_flow => {
    if (eqlIgnoreCase(trimmed, "row")) style.grid_auto_flow = .row
    else if (eqlIgnoreCase(trimmed, "column")) style.grid_auto_flow = .column
    else if (eqlIgnoreCase(trimmed, "row dense")) style.grid_auto_flow = .row_dense
    else if (eqlIgnoreCase(trimmed, "column dense")) style.grid_auto_flow = .column_dense;
},
.grid_column_start => {
    style.grid_column_start = parseGridLine(trimmed);
},
// ... etc for grid_column_end, grid_row_start, grid_row_end
```

- [ ] **Step 2: Implement parseGridTemplate helper**

```zig
fn parseGridTemplate(s: []const u8, alloc: std.mem.Allocator) ?[]const ComputedStyle.GridTrackSize {
    // Parse space-separated track sizes: "200px 1fr 1fr", "auto 300px", "1fr 2fr 1fr"
    // Also handle repeat(): "repeat(3, 1fr)" → [1fr, 1fr, 1fr]
    // Handle minmax(): "minmax(100px, 1fr)" → simplified to 1fr
    var tracks: std.ArrayListUnmanaged(ComputedStyle.GridTrackSize) = .empty;
    var iter = std.mem.tokenizeScalar(u8, s, ' ');
    while (iter.next()) |token| {
        const t = std.mem.trim(u8, token, " \t");
        if (eqlIgnoreCase(t, "auto")) {
            tracks.append(alloc, .auto) catch return null;
        } else if (std.mem.endsWith(u8, t, "fr")) {
            if (std.fmt.parseFloat(f32, t[0..t.len-2])) |v| {
                tracks.append(alloc, .{ .fr = v }) catch return null;
            } else |_| {}
        } else if (properties.parseLength(t)) |len| {
            if (len.unit == .percent) {
                tracks.append(alloc, .{ .percent = len.value }) catch return null;
            } else {
                tracks.append(alloc, .{ .px = len.value }) catch return null;
            }
        }
        // repeat() and minmax() — simplified handling
    }
    return tracks.toOwnedSlice(alloc) catch return null;
}
```

- [ ] **Step 3: Handle grid shorthand expansion**

In `src/css/properties.zig` `expandShorthand`, add:
- `grid-column: 1 / 3` → grid-column-start: 1, grid-column-end: 3
- `grid-row: 1 / 2` → grid-row-start: 1, grid-row-end: 2
- `grid-gap: 10px` → row-gap: 10px, column-gap: 10px (alias for gap)
- `grid-template: rows / columns` → basic support

- [ ] **Step 4: Commit**

```
feat(css): parse grid-template-columns/rows and grid placement properties
```

---

## Task 3: Grid Layout Algorithm

**Files:**
- Create: `src/layout/grid.zig`
- Create: `tests/test_grid.zig`

- [ ] **Step 1: Define the grid layout algorithm**

```zig
// src/layout/grid.zig
const Box = @import("box.zig").Box;
const ComputedStyle = @import("../style/computed.zig").ComputedStyle;
const FontCache = @import("../paint/painter.zig").FontCache;
const block = @import("block.zig");

pub fn layoutGrid(box: *Box, containing_width: f32, cursor_y: f32, fonts: *FontCache) void {
    const style = box.style;

    // 1. Compute content area
    box.content.x = box.padding.left + box.border.left;
    box.content.y = cursor_y + box.padding.top + box.border.top;
    const h_space = box.margin.left + box.margin.right + box.padding.left + box.padding.right + box.border.left + box.border.right;
    box.content.width = @max(containing_width - h_space, 0);

    // 2. Resolve column widths
    const columns = resolveTrackSizes(style.grid_template_columns, box.content.width, style.gap);

    // 3. Resolve row heights (auto-sized based on content)
    // Place children in grid cells
    const num_cols = if (columns.len > 0) columns.len else 1;
    var col: usize = 0;
    var row_y: f32 = 0;
    var row_height: f32 = 0;
    const gap = style.gap;

    for (box.children.items) |child| {
        if (child.style.position == .absolute or child.style.position == .fixed) {
            block.layoutBlock(child, box.content.width, box.content.y, fonts);
            continue;
        }
        if (child.style.display == .none) continue;

        // Determine column width
        const col_width = if (col < columns.len) columns[col] else box.content.width;

        // Layout child with column width
        block.layoutBlock(child, col_width, box.content.y + row_y, fonts);

        // Position child
        var col_x: f32 = 0;
        for (0..col) |c| {
            col_x += if (c < columns.len) columns[c] else 0;
            col_x += gap;
        }
        adjustXPositions(child, box.content.x + col_x);

        // Track row height (tallest cell in row)
        const child_h = child.content.height + child.padding.top + child.padding.bottom + child.border.top + child.border.bottom + child.margin.top + child.margin.bottom;
        if (child_h > row_height) row_height = child_h;

        col += 1;
        if (col >= num_cols) {
            col = 0;
            row_y += row_height + gap;
            row_height = 0;
        }
    }

    // Final height
    if (col > 0) row_y += row_height; // last incomplete row
    box.content.height = row_y;
}

fn resolveTrackSizes(tracks: []const ComputedStyle.GridTrackSize, total_width: f32, gap: f32) []f32 {
    // ... resolve fr units, percentages, auto sizing
}
```

- [ ] **Step 2: Write tests**

```zig
// tests/test_grid.zig — test resolveTrackSizes
test "resolve 2-column fr" — "1fr 1fr" in 720px → [360, 360] (no gap)
test "resolve 3-column mixed" — "200px 1fr 1fr" in 720px → [200, 260, 260]
test "resolve with gap" — "1fr 1fr" in 720px, gap=20px → [350, 350]
test "resolve percent" — "30% 70%" in 1000px → [300, 700]
test "resolve auto" — "auto auto" in 720px → [360, 360]
```

- [ ] **Step 3: Run tests**
- [ ] **Step 4: Commit**

```
feat(layout): add CSS Grid layout algorithm
```

---

## Task 4: Wire Grid Layout into Block.zig

**Files:**
- Modify: `src/layout/block.zig`

- [ ] **Step 1: Replace grid→flex fallback with proper grid layout**

Replace lines 276-291 in block.zig:
```zig
// OLD: Grid→flex fallback
// NEW: Proper grid layout
if (box.style.display == .grid or box.style.display == .inline_grid) {
    grid.layoutGrid(box, containing_width, cursor_y, fonts);
    return;
}
```

- [ ] **Step 2: Add import**

```zig
const grid = @import("grid.zig");
```

- [ ] **Step 3: Remove grid wrapping hack from flex.zig**

In flex.zig line ~97, remove the `style.display == .grid or style.display == .inline_grid` condition from wrapping check.

- [ ] **Step 4: Commit**

```
feat(layout): wire grid layout into block dispatch
```

---

## Task 5: Add Box Grid Fields

**Files:**
- Modify: `src/layout/box.zig`

- [ ] **Step 1: Add grid placement to Box**

```zig
// Grid placement (resolved during grid layout)
grid_column: u16 = 0,
grid_row: u16 = 0,
grid_column_span: u16 = 1,
grid_row_span: u16 = 1,
```

- [ ] **Step 2: Use grid placement in grid.zig**

When a child has explicit `grid_column_start`/`grid_column_end` in its ComputedStyle, use those for placement instead of auto-flow.

- [ ] **Step 3: Commit**

```
feat(layout): add grid placement fields to Box
```

---

## Task 6: Build Integration + Device Test

**Files:**
- Modify: `build.zig`
- Modify: `tests/test_css_all.zig`

- [ ] **Step 1: Add test-grid to build system**
- [ ] **Step 2: Run all tests**: `zig build test-css`
- [ ] **Step 3: Cross-compile and deploy to device**
- [ ] **Step 4: Test Wikipedia, MDN, Stack Overflow**
- [ ] **Step 5: Screenshot comparison**
- [ ] **Step 6: Commit**

```
feat: CSS Grid layout — fixes Wikipedia/MDN/SO sidebar layouts
```
