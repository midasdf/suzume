# zz Phase 4: Context Menu & File Tree CRUD — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add file tree CRUD operations (create/rename/delete/copy path) with right-click context menus in both file tree and editor, replacing the ad-hoc string-based context menu with a typed MenuItem/MenuAction system.

**Architecture:** Refactor existing `context_menu_active` bool + string array in main.zig into a `ContextMenuState` struct with typed `MenuAction` enum. Extend overlay.zig rendering to support shortcut hints and disabled items. Add `InlineInput` to file_tree.zig for naming operations. Add `confirm_dialog` and `tree_input` modes to main.zig. File operations use `std.fs` directly.

**Tech Stack:** Zig, std.fs, existing xcb/SHM rendering, existing overlay.zig/file_tree.zig

**Spec:** `docs/superpowers/specs/2026-04-02-zz-context-menu-file-crud-design.md`

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `src/ui/overlay.zig` | Modify | Add `MenuItem`/`MenuAction`/`ContextMenuState` types, refactor `renderContextMenu` to accept `[]const MenuItem`, add shortcut/disabled rendering, add `renderConfirmDialog` |
| `src/ui/file_tree.zig` | Modify | Add `InlineInput` struct, CRUD operations (createFile, renameEntry, deleteEntry, copyPath), `refreshDirectory()`, file tree menu item generation, right-click entry detection |
| `src/main.zig` | Modify | Replace `context_menu_active/x/y/selected` with `ContextMenuState`, add `tree_input`/`confirm_dialog` to `EditorMode`, add right-click area routing, add `MenuAction` dispatch, add status message state |
| `src/editor/view_render.zig` | Modify | Add status bar message rendering |

---

## Chunk 1: Context Menu Refactor

### Task 1: Add MenuItem/MenuAction types to overlay.zig

**Files:**
- Modify: `zz/src/ui/overlay.zig`

- [ ] **Step 1: Add MenuAction enum and MenuItem struct at top of overlay.zig**

After the existing imports and color constants, add:

```zig
pub const MenuAction = enum {
    // File tree actions
    tree_new_file,
    tree_new_folder,
    tree_rename,
    tree_delete,
    tree_copy_path,
    tree_copy_relative_path,
    // Editor actions (replaces string-matched items)
    ed_cut,
    ed_copy,
    ed_paste,
    ed_select_all,
    ed_select_word,
    ed_goto_definition,
    ed_find_references,
    ed_command_palette,
};

pub const MenuItem = struct {
    label: []const u8,
    shortcut: ?[]const u8,
    action: MenuAction,
    separator_after: bool,
    enabled: bool,
};

pub const ContextMenuState = struct {
    items: []const MenuItem,
    selected: usize,
    x: u32,
    y: u32,
    source: enum { editor, file_tree },
    tree_entry_index: ?usize,
    active: bool,

    pub fn open(items: []const MenuItem, px: u32, py: u32, source: @TypeOf(@as(ContextMenuState, undefined).source), tree_idx: ?usize) ContextMenuState {
        return .{
            .items = items,
            .selected = 0,
            .x = px,
            .y = py,
            .source = source,
            .tree_entry_index = tree_idx,
            .active = true,
        };
    }

    pub fn close(self: *ContextMenuState) void {
        self.active = false;
    }

    pub fn moveUp(self: *ContextMenuState) void {
        if (self.selected == 0) return;
        self.selected -= 1;
        // Skip separators and disabled items
        while (self.selected > 0 and (self.items[self.selected].separator_after and self.items[self.selected].label.len == 0 or !self.items[self.selected].enabled)) {
            self.selected -= 1;
        }
    }

    pub fn moveDown(self: *ContextMenuState) void {
        if (self.selected + 1 >= self.items.len) return;
        self.selected += 1;
        while (self.selected + 1 < self.items.len and !self.items[self.selected].enabled) {
            self.selected += 1;
        }
    }

    pub fn selectedAction(self: *const ContextMenuState) ?MenuAction {
        if (!self.active or self.selected >= self.items.len) return null;
        if (!self.items[self.selected].enabled) return null;
        return self.items[self.selected].action;
    }
};
```

- [ ] **Step 2: Build and verify types compile**

```bash
cd ~/zz && zig build
```

Expected: Compiles (types are defined but not yet used).

- [ ] **Step 3: Commit**

```bash
cd ~/zz && git add src/ui/overlay.zig && git commit -m "feat: add MenuItem/MenuAction/ContextMenuState types to overlay"
```

---

### Task 2: Refactor renderContextMenu to use MenuItem

**Files:**
- Modify: `zz/src/ui/overlay.zig` (lines 248-314)

- [ ] **Step 1: Replace renderContextMenu signature and implementation**

Replace the existing `renderContextMenu` function (lines 248-314) with:

```zig
pub fn renderContextMenu(
    renderer: *Renderer,
    font: *FontFace,
    state: *const ContextMenuState,
) void {
    if (!state.active) return;
    const items = state.items;
    if (items.len == 0) return;

    const cell_w = font.cell_width;
    const cell_h = if (font.cell_height > 0) font.cell_height else 1;
    if (cell_w == 0) return;

    // Calculate menu dimensions — account for shortcut text
    var max_label_len: u32 = 0;
    var max_shortcut_len: u32 = 0;
    for (items) |item| {
        const llen: u32 = @intCast(item.label.len);
        if (llen > max_label_len) max_label_len = llen;
        if (item.shortcut) |sc| {
            const slen: u32 = @intCast(sc.len);
            if (slen > max_shortcut_len) max_shortcut_len = slen;
        }
    }
    // Width: 2 pad + label + 3 gap + shortcut + 2 pad
    const gap: u32 = if (max_shortcut_len > 0) 3 else 0;
    const content_cols = max_label_len + gap + max_shortcut_len;
    const menu_w = @max((content_cols + 4) * cell_w, 180); // min 180px
    const menu_h: u32 = @as(u32, @intCast(items.len)) * cell_h + 8;

    // Clamp position to window bounds
    const mx = if (state.x + menu_w > renderer.width) renderer.width -| menu_w else state.x;
    const my = if (state.y + menu_h > renderer.height) renderer.height -| menu_h else state.y;

    // Shadow
    const shadow = Color.fromHex(0x0a0a0f);
    renderer.fillRect(mx + 2, my + 2, menu_w, menu_h, shadow);

    // Background + border
    renderer.fillRect(mx, my, menu_w, menu_h, overlay_bg);
    renderer.fillRect(mx, my, menu_w, 1, overlay_border);
    renderer.fillRect(mx, my + menu_h - 1, menu_w, 1, overlay_border);
    renderer.fillRect(mx, my, 1, menu_h, overlay_border);
    renderer.fillRect(mx + menu_w - 1, my, 1, menu_h, overlay_border);

    // Render items
    var y = my + 4;
    for (items, 0..) |item, i| {
        const is_sel = (i == state.selected);

        // Separator: draw line if previous item has separator_after
        if (i > 0 and items[i - 1].separator_after) {
            renderer.fillRect(mx + cell_w, y, menu_w - cell_w * 2, 1, overlay_border);
            // Separators don't take a row — they're drawn above the current item
        }

        const row_bg = if (is_sel and item.enabled) overlay_selected else overlay_bg;
        const row_fg = if (!item.enabled) Color.fromHex(0x585b70) // overlay0 for disabled
            else if (is_sel) overlay_text
            else overlay_dim;

        renderer.fillRect(mx + 1, y, menu_w - 2, cell_h, row_bg);

        // Label
        var ix = mx + cell_w * 2;
        for (item.label) |ch| {
            const glyph = font.getGlyph(ch) catch continue;
            const gx: i32 = @intCast(ix);
            const gy: i32 = @as(i32, @intCast(y)) + font.ascent - @as(i32, glyph.bearing_y);
            renderer.drawGlyph(glyph, gx, gy, row_fg);
            ix += cell_w;
        }

        // Shortcut hint (right-aligned, dimmed)
        if (item.shortcut) |sc| {
            const sc_fg = Color.fromHex(0x9399b2); // overlay2
            var sx = mx + menu_w - cell_w * 2 - @as(u32, @intCast(sc.len)) * cell_w;
            for (sc) |ch| {
                const glyph = font.getGlyph(ch) catch continue;
                const gx: i32 = @intCast(sx);
                const gy: i32 = @as(i32, @intCast(y)) + font.ascent - @as(i32, glyph.bearing_y);
                renderer.drawGlyph(glyph, gx, gy, sc_fg);
                sx += cell_w;
            }
        }

        y += cell_h;
    }
}
```

Note: Separators are no longer items themselves — they're drawn via `separator_after` flag on the preceding item. This simplifies keyboard navigation (no separator items to skip).

- [ ] **Step 2: Build and verify**

```bash
cd ~/zz && zig build
```

Expected: Compiles. The old call site in main.zig renderFrame will break — we fix that next.

- [ ] **Step 3: Commit**

```bash
cd ~/zz && git add src/ui/overlay.zig && git commit -m "refactor: renderContextMenu uses typed MenuItem with shortcuts and disabled states"
```

---

### Task 3: Migrate main.zig context menu state

**Files:**
- Modify: `zz/src/main.zig`

This is the largest single task — migrating 13 occurrences of ad-hoc context menu state to the new typed system.

- [ ] **Step 1: Add context_menu to EditorMode enum**

At `src/main.zig:31-43`, add `context_menu` to the EditorMode enum:

```zig
const EditorMode = enum {
    normal,
    command_palette,
    file_finder,
    search,
    goto_line,
    project_search,
    find_replace,
    goto_symbol,
    rename,
    code_action,
    goto_references,
    context_menu,     // NEW
    tree_input,       // NEW
    confirm_dialog,   // NEW
};
```

- [ ] **Step 2: Define editor menu items as comptime MenuItem array**

Replace `context_menu_items` (lines 71-83) with:

```zig
const Overlay = @import("ui/overlay.zig");
// (Overlay is already imported — just reference its types)

const editor_menu_items = [_]Overlay.MenuItem{
    .{ .label = "Cut", .shortcut = "Ctrl+X", .action = .ed_cut, .separator_after = false, .enabled = true },
    .{ .label = "Copy", .shortcut = "Ctrl+C", .action = .ed_copy, .separator_after = false, .enabled = true },
    .{ .label = "Paste", .shortcut = "Ctrl+V", .action = .ed_paste, .separator_after = true, .enabled = true },
    .{ .label = "Select All", .shortcut = "Ctrl+A", .action = .ed_select_all, .separator_after = false, .enabled = true },
    .{ .label = "Select Word", .shortcut = null, .action = .ed_select_word, .separator_after = true, .enabled = true },
    .{ .label = "Go to Definition", .shortcut = "F12", .action = .ed_goto_definition, .separator_after = false, .enabled = true },
    .{ .label = "Find References", .shortcut = "Shift+F12", .action = .ed_find_references, .separator_after = true, .enabled = true },
    .{ .label = "Command Palette...", .shortcut = "Ctrl+Shift+P", .action = .ed_command_palette, .separator_after = false, .enabled = true },
};

const file_tree_menu_items = [_]Overlay.MenuItem{
    .{ .label = "New File", .shortcut = null, .action = .tree_new_file, .separator_after = false, .enabled = true },
    .{ .label = "New Folder", .shortcut = null, .action = .tree_new_folder, .separator_after = true, .enabled = true },
    .{ .label = "Rename", .shortcut = "F2", .action = .tree_rename, .separator_after = false, .enabled = true },
    .{ .label = "Delete", .shortcut = "Del", .action = .tree_delete, .separator_after = true, .enabled = true },
    .{ .label = "Copy Path", .shortcut = null, .action = .tree_copy_path, .separator_after = false, .enabled = true },
    .{ .label = "Copy Relative Path", .shortcut = null, .action = .tree_copy_relative_path, .separator_after = false, .enabled = true },
};
```

- [ ] **Step 3: Replace ad-hoc context menu state variables**

Remove these variables (lines 268-271):
```zig
// REMOVE:
var context_menu_active = false;
var context_menu_x: u32 = 0;
var context_menu_y: u32 = 0;
var context_menu_selected: usize = 0;
```

Replace with:
```zig
var ctx_menu = Overlay.ContextMenuState{
    .items = &editor_menu_items,
    .selected = 0,
    .x = 0,
    .y = 0,
    .source = .editor,
    .tree_entry_index = null,
    .active = false,
};
```

- [ ] **Step 4: Replace executeContextMenuItem with MenuAction dispatch**

Replace the `executeContextMenuItem` function (lines 1181-1211) with:

```zig
fn executeMenuAction(
    action: Overlay.MenuAction,
    editor: *EditorView,
    win: *Window,
    lsp_client: *lsp.LspClient,
    lsp_sync: *bool,
    mode: *EditorMode,
    overlay_ptr: *Overlay,
    filtered_display: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    file_tree: *FileTree,
) void {
    switch (action) {
        .ed_cut => handleAction(editor, win, .cut, lsp_client, lsp_sync),
        .ed_copy => handleAction(editor, win, .copy, lsp_client, lsp_sync),
        .ed_paste => handleAction(editor, win, .paste, lsp_client, lsp_sync),
        .ed_select_all => handleAction(editor, win, .select_all, lsp_client, lsp_sync),
        .ed_select_word => editor.selectWordAtPosition(editor.cursor.primary().head),
        .ed_goto_definition => handleAction(editor, win, .goto_definition, lsp_client, lsp_sync),
        .ed_find_references => openGotoReferences(mode, overlay_ptr, editor, lsp_client, filtered_display, allocator),
        .ed_command_palette => openCommandPalette(mode, overlay_ptr, filtered_display, allocator),
        // File tree actions — dispatched in Task 6
        .tree_new_file => {},
        .tree_new_folder => {},
        .tree_rename => {},
        .tree_delete => {},
        .tree_copy_path => {},
        .tree_copy_relative_path => {},
    }
    _ = file_tree;
}
```

- [ ] **Step 5: Update keyboard handling to use ctx_menu**

Replace context menu keyboard handling (lines 302-335). Find the block starting `if (context_menu_active)` and replace with:

```zig
if (ctx_menu.active) {
    if (ke.keysym == window_mod.XK_Escape) {
        ctx_menu.close();
        editor.markAllDirty();
        continue;
    } else if (ke.keysym == window_mod.XK_Up) {
        ctx_menu.moveUp();
        editor.markAllDirty();
        continue;
    } else if (ke.keysym == window_mod.XK_Down) {
        ctx_menu.moveDown();
        editor.markAllDirty();
        continue;
    } else if (ke.keysym == window_mod.XK_Return) {
        if (ctx_menu.selectedAction()) |action| {
            ctx_menu.close();
            executeMenuAction(action, editor, &win, &lsp_client, &lsp_needs_sync, &mode, &overlay, &filtered_display, allocator, &file_tree);
        } else {
            ctx_menu.close();
        }
        editor.markAllDirty();
        continue;
    } else {
        ctx_menu.close();
        editor.markAllDirty();
    }
}
```

- [ ] **Step 6: Update right-click handler**

Replace right-click handler (lines 699-727). Find `} else if (me.button == .right) {` and replace with:

```zig
} else if (me.button == .right) {
    if (ctx_menu.active) {
        ctx_menu.close();
    } else {
        const px: u32 = if (me.x >= 0) @intCast(me.x) else 0;
        const py: u32 = if (me.y >= 0) @intCast(me.y) else 0;

        // Check if click is in file tree area
        const sw = file_tree.sidebarWidth(&font);
        if (file_tree.visible and me.x >= 0 and me.x < @as(i32, @intCast(sw))) {
            // File tree right-click
            const cell_h = font.cell_height;
            if (cell_h > 0) {
                const tab_bar_h = font.cell_height + 8;
                const top_pad: u32 = 4;
                const content_start = tab_bar_h + top_pad;
                if (py >= content_start) {
                    const row = (py - content_start) / cell_h;
                    const entry_idx = file_tree.scroll_offset + row;
                    if (entry_idx < file_tree.entries.items.len) {
                        file_tree.selected = entry_idx;
                        ctx_menu = Overlay.ContextMenuState.open(&file_tree_menu_items, px, py, .file_tree, entry_idx);
                    }
                }
            }
        } else {
            // Editor right-click (existing behavior)
            if (terminal.focused) {
                terminal.unfocus();
            }
            if (pane_mgr.isSplit()) {
                if (pane_mgr.leafAtPixel(me.x, me.y)) |clicked_view| {
                    if (clicked_view != pane_mgr.active_leaf) {
                        pane_mgr.active_leaf = clicked_view;
                        syncTabToActivePane(&pane_mgr, &tab_mgr);
                    }
                }
            }
            const active_rc = pane_mgr.active_leaf;
            const pos = active_rc.pixelToPosition(me.x, me.y, &font);
            active_rc.cursor.moveTo(pos);
            ctx_menu = Overlay.ContextMenuState.open(&editor_menu_items, px, py, .editor, null);
        }
    }
    markAllPanesDirty(&pane_mgr);
}
```

- [ ] **Step 7: Update mouse hover handling**

Replace context menu hover (lines 809-827). Find `if (context_menu_active)` in the mouse motion section and replace with:

```zig
if (ctx_menu.active) {
    const cell_h = font.cell_height;
    const cell_w_h = font.cell_width;
    if (cell_h > 0 and cell_w_h > 0) {
        // Calculate menu width same as renderContextMenu
        var max_label_len: u32 = 0;
        var max_shortcut_len: u32 = 0;
        for (ctx_menu.items) |item| {
            const llen: u32 = @intCast(item.label.len);
            if (llen > max_label_len) max_label_len = llen;
            if (item.shortcut) |sc| {
                const slen: u32 = @intCast(sc.len);
                if (slen > max_shortcut_len) max_shortcut_len = slen;
            }
        }
        const gap_cols: u32 = if (max_shortcut_len > 0) 3 else 0;
        const menu_w_h = @max((max_label_len + gap_cols + max_shortcut_len + 4) * cell_w_h, 180);
        const menu_content_h_h: u32 = @as(u32, @intCast(ctx_menu.items.len)) * cell_h;

        // Clamp menu position (same logic as render)
        const mx_h: i32 = @intCast(if (ctx_menu.x + menu_w_h > renderer_width) renderer_width -| menu_w_h else ctx_menu.x);
        const my_h: i32 = @intCast((if (ctx_menu.y + @as(u32, @intCast(ctx_menu.items.len)) * cell_h + 8 > renderer_height) renderer_height -| (@as(u32, @intCast(ctx_menu.items.len)) * cell_h + 8) else ctx_menu.y) + 4);

        if (me.x >= mx_h and me.x < mx_h + @as(i32, @intCast(menu_w_h)) and
            me.y >= my_h and me.y < my_h + @as(i32, @intCast(menu_content_h_h)))
        {
            const row = @as(u32, @intCast(me.y - my_h)) / cell_h;
            if (row < ctx_menu.items.len and ctx_menu.items[row].enabled) {
                ctx_menu.selected = row;
                needs_redraw = true;
            }
        }
    }
}
```

Note: The hover code references `renderer_width`/`renderer_height` — use the actual window dimensions available at that scope (likely `win.width`/`win.height` or the renderer's dimensions). Check what variables are available in the mouse motion handler scope and use those.

- [ ] **Step 8: Update mouse click on context menu**

Find the context menu click handler (near lines 586-609) that handles left-click on menu items. Replace `context_menu_active` checks and `executeContextMenuItem` calls with `ctx_menu.active`, `ctx_menu.selectedAction()`, and `executeMenuAction()`.

- [ ] **Step 9: Update renderFrame call**

Find the `renderFrame` function (lines 1614-1632). Replace the context menu parameters:

Old:
```zig
ctx_menu_active: bool,
ctx_menu_x: u32,
ctx_menu_y: u32,
ctx_menu_selected: usize,
```

New:
```zig
ctx_menu: *const Overlay.ContextMenuState,
```

Update the call to `Overlay.renderContextMenu` inside renderFrame (line 1706):

Old:
```zig
if (ctx_menu_active) {
    Overlay.renderContextMenu(&renderer, font, ctx_menu_x, ctx_menu_y, &context_menu_items, ctx_menu_selected);
}
```

New:
```zig
Overlay.renderContextMenu(&renderer, font, ctx_menu);
```

Update the renderFrame call site to pass `&ctx_menu` instead of the four separate variables.

- [ ] **Step 10: Remove contextMenuWidth helper if it exists**

Search for `contextMenuWidth` in main.zig and remove it — width calculation is now inside renderContextMenu.

- [ ] **Step 11: Build and verify editor context menu still works**

```bash
cd ~/zz && zig build && ./zig-out/bin/zz src/main.zig
```

Test:
1. Right-click in editor → menu appears with Cut/Copy/Paste/etc. and shortcut hints
2. Up/Down navigates, Enter executes
3. Escape closes menu
4. Click outside closes menu
5. Mouse hover highlights items

- [ ] **Step 12: Commit**

```bash
cd ~/zz && git add src/main.zig src/ui/overlay.zig && git commit -m "refactor: migrate context menu to typed MenuItem/MenuAction system"
```

---

### Task 4: File tree right-click shows menu

This is already wired in Task 3 Step 6 — right-click in file tree area opens `file_tree_menu_items`. Verify it works.

- [ ] **Step 1: Build and test file tree right-click**

```bash
cd ~/zz && zig build && ./zig-out/bin/zz .
```

Test:
1. Ctrl+B to show file tree
2. Right-click on a file → shows New File/New Folder/Rename/Delete/Copy Path/Copy Relative Path
3. Right-click on a directory → same menu
4. Keyboard nav works
5. Escape closes
6. Click outside closes

Expected: Menu displays but actions are no-ops (stubbed in executeMenuAction).

- [ ] **Step 2: Commit if any fixes were needed**

```bash
cd ~/zz && git add -A && git commit -m "fix: file tree right-click menu adjustments"
```

---

## Chunk 2: File Tree CRUD Operations

### Task 5: InlineInput for file tree naming

**Files:**
- Modify: `zz/src/ui/file_tree.zig`

- [ ] **Step 1: Add InlineInput struct to FileTree**

Add to `file_tree.zig` after the Entry struct definition:

```zig
pub const InlineInput = struct {
    buffer: [256]u8 = undefined,
    len: usize = 0,
    cursor_pos: usize = 0, // byte offset, always at codepoint boundary
    mode: enum { new_file, new_folder, rename_file } = .new_file,
    target_dir: []const u8 = "", // directory path for new file/folder
    insert_at: usize = 0, // index in entries list where input row appears
    original_name: ?[]const u8 = null, // for rename

    pub fn setText(self: *InlineInput, text: []const u8) void {
        const copy_len = @min(text.len, self.buffer.len);
        @memcpy(self.buffer[0..copy_len], text[0..copy_len]);
        self.len = copy_len;
        self.cursor_pos = copy_len;
    }

    pub fn insertChar(self: *InlineInput, bytes: []const u8) void {
        if (self.len + bytes.len > self.buffer.len) return;
        // Shift right
        var i = self.len;
        while (i > self.cursor_pos) {
            i -= 1;
            self.buffer[i + bytes.len] = self.buffer[i];
        }
        @memcpy(self.buffer[self.cursor_pos..][0..bytes.len], bytes);
        self.len += bytes.len;
        self.cursor_pos += bytes.len;
    }

    pub fn backspace(self: *InlineInput) void {
        if (self.cursor_pos == 0) return;
        // Find start of previous codepoint
        var prev = self.cursor_pos - 1;
        while (prev > 0 and (self.buffer[prev] & 0xC0) == 0x80) {
            prev -= 1;
        }
        const cp_len = self.cursor_pos - prev;
        // Shift left
        const remaining = self.len - self.cursor_pos;
        var j: usize = 0;
        while (j < remaining) : (j += 1) {
            self.buffer[prev + j] = self.buffer[self.cursor_pos + j];
        }
        self.len -= cp_len;
        self.cursor_pos = prev;
    }

    pub fn delete(self: *InlineInput) void {
        if (self.cursor_pos >= self.len) return;
        // Find length of codepoint at cursor
        const first_byte = self.buffer[self.cursor_pos];
        const cp_len = std.unicode.utf8ByteSequenceLength(first_byte) catch 1;
        const actual_len = @min(cp_len, self.len - self.cursor_pos);
        // Shift left
        const remaining = self.len - self.cursor_pos - actual_len;
        var j: usize = 0;
        while (j < remaining) : (j += 1) {
            self.buffer[self.cursor_pos + j] = self.buffer[self.cursor_pos + actual_len + j];
        }
        self.len -= actual_len;
    }

    pub fn moveLeft(self: *InlineInput) void {
        if (self.cursor_pos == 0) return;
        self.cursor_pos -= 1;
        while (self.cursor_pos > 0 and (self.buffer[self.cursor_pos] & 0xC0) == 0x80) {
            self.cursor_pos -= 1;
        }
    }

    pub fn moveRight(self: *InlineInput) void {
        if (self.cursor_pos >= self.len) return;
        const first_byte = self.buffer[self.cursor_pos];
        const cp_len = std.unicode.utf8ByteSequenceLength(first_byte) catch 1;
        self.cursor_pos = @min(self.cursor_pos + cp_len, self.len);
    }

    pub fn content(self: *const InlineInput) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn validate(self: *const InlineInput) ?[]const u8 {
        const text = self.content();
        if (text.len == 0) return "Empty name";
        for (text) |ch| {
            if (ch == '/' or ch == 0) return "Invalid character in name";
        }
        return null;
    }
};
```

Add field to FileTree struct:

```zig
pub inline_input: ?InlineInput = null,
```

- [ ] **Step 2: Add renderInlineInput to FileTree render**

In the `render()` method, after the existing entry rendering loop, add a check: if `self.inline_input` is non-null, render the input field at `insert_at` position instead of (or in addition to) the normal entry.

Add this method to FileTree:

```zig
pub fn renderInlineInput(self: *const FileTree, renderer: *Renderer, font: *FontFace, tab_bar_h: u32) void {
    const input = self.inline_input orelse return;
    const cell_h = font.cell_height;
    const cell_w = font.cell_width;
    if (cell_h == 0 or cell_w == 0) return;

    const top_pad: u32 = 4;
    const content_start = tab_bar_h + top_pad;

    // Calculate row position
    const visible_row = if (input.insert_at >= self.scroll_offset) input.insert_at - self.scroll_offset else return;
    const y = content_start + @as(u32, @intCast(visible_row)) * cell_h;
    const sw = self.sidebarWidth(font);

    // Background
    const surface1 = Color.fromHex(0x45475a);
    renderer.fillRect(0, y, sw, cell_h, surface1);

    // Indent (based on target entry depth)
    const depth: u32 = if (input.insert_at < self.entries.items.len) self.entries.items[input.insert_at].depth + 1 else 1;
    const indent = depth * cell_w * 2 + cell_w;

    // Text
    const text_color = Color.fromHex(0xcdd6f4);
    var x = indent;
    const text = input.content();
    for (text) |ch| {
        const glyph = font.getGlyph(ch) catch continue;
        const gx: i32 = @intCast(x);
        const gy: i32 = @as(i32, @intCast(y)) + font.ascent - @as(i32, glyph.bearing_y);
        renderer.drawGlyph(glyph, gx, gy, text_color);
        x += cell_w;
    }

    // Cursor beam
    const cursor_x = indent + @as(u32, @intCast(input.cursor_pos)) * cell_w;
    const cursor_color = Color.fromHex(0xf5e0dc);
    renderer.fillRect(cursor_x, y + 2, 2, cell_h - 4, cursor_color);
}
```

- [ ] **Step 3: Build and verify**

```bash
cd ~/zz && zig build
```

- [ ] **Step 4: Commit**

```bash
cd ~/zz && git add src/ui/file_tree.zig && git commit -m "feat: add InlineInput to file tree with UTF-8 support"
```

---

### Task 6: File tree CRUD operations

**Files:**
- Modify: `zz/src/ui/file_tree.zig`

- [ ] **Step 1: Add refreshDirectory method**

```zig
/// Refresh only the children of the specified directory.
/// Preserves expand/collapse state of sibling directories.
pub fn refreshDirectory(self: *FileTree, dir_path: []const u8) !void {
    // Find the directory entry
    var dir_idx: ?usize = null;
    var dir_depth: u16 = 0;
    for (self.entries.items, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.path, dir_path) and entry.is_dir) {
            dir_idx = i;
            dir_depth = entry.depth;
            break;
        }
    }

    if (dir_idx) |idx| {
        // Remember which subdirectories were expanded
        var expanded_paths = std.ArrayList([]const u8).init(self.allocator);
        defer expanded_paths.deinit();

        // Find range of children
        var end_idx = idx + 1;
        while (end_idx < self.entries.items.len and self.entries.items[end_idx].depth > dir_depth) {
            const child = &self.entries.items[end_idx];
            if (child.is_dir and child.is_expanded) {
                expanded_paths.append(child.path) catch {};
            }
            end_idx += 1;
        }

        // Remove old children
        var remove_count = end_idx - idx - 1;
        while (remove_count > 0) : (remove_count -= 1) {
            const entry = self.entries.orderedRemove(idx + 1);
            self.allocator.free(entry.name);
            self.allocator.free(entry.path);
        }

        // Re-scan directory children
        if (self.entries.items[idx].is_expanded) {
            try self.scanDir(dir_path, dir_depth + 1);
            // The entries got appended at the end — we need to move them
            // Actually, scanDir appends to the end of entries. We need a different approach.
            // Instead, use insertScanDir that inserts at position.
        }

        // Re-expand previously expanded subdirs
        for (self.entries.items[idx + 1..], 0..) |*child, ci| {
            if (child.is_dir) {
                for (expanded_paths.items) |exp_path| {
                    if (std.mem.eql(u8, child.path, exp_path)) {
                        self.expandAt(idx + 1 + ci) catch {};
                        break;
                    }
                }
            }
        }
    } else {
        // Directory not found in tree — full refresh
        try self.populate();
    }
}
```

Note: The actual implementation may need to handle `scanDir` inserting at a specific position rather than appending. If `scanDir` always appends, add an `insertScanDir(path, depth, insert_position)` variant. The executor should check how `expandAt` works (it likely calls `scanDir` already) and reuse that pattern.

- [ ] **Step 2: Add CRUD operation methods**

```zig
pub fn createNewFile(self: *FileTree, dir_path: []const u8, name: []const u8) ![]const u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch return error.PathTooLong;

    const file = std.fs.cwd().createFile(full_path, .{}) catch |err| return err;
    file.close();

    try self.refreshDirectory(dir_path);

    // Return the created path (caller must not hold reference to path_buf)
    // Find the new entry in the refreshed tree
    for (self.entries.items) |entry| {
        if (std.mem.endsWith(u8, entry.path, name) and !entry.is_dir) {
            return entry.path;
        }
    }
    return full_path;
}

pub fn createNewFolder(self: *FileTree, dir_path: []const u8, name: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch return error.PathTooLong;

    try std.fs.cwd().makeDir(full_path);
    try self.refreshDirectory(dir_path);
}

pub fn renameEntry(self: *FileTree, old_path: []const u8, new_name: []const u8) ![]const u8 {
    // Build new path: same parent dir + new name
    const parent = std.fs.path.dirname(old_path) orelse ".";
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const new_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ parent, new_name }) catch return error.PathTooLong;

    try std.fs.cwd().rename(old_path, new_path);
    try self.refreshDirectory(parent);

    // Return new path from refreshed entries
    for (self.entries.items) |entry| {
        if (std.mem.endsWith(u8, entry.path, new_name)) {
            return entry.path;
        }
    }
    return error.FileNotFound;
}

pub fn deleteEntry(self: *FileTree, path: []const u8, is_dir: bool) !void {
    const parent = std.fs.path.dirname(path) orelse ".";
    if (is_dir) {
        try std.fs.cwd().deleteTree(path);
    } else {
        try std.fs.cwd().deleteFile(path);
    }
    try self.refreshDirectory(parent);
}
```

- [ ] **Step 3: Build and verify**

```bash
cd ~/zz && zig build
```

- [ ] **Step 4: Commit**

```bash
cd ~/zz && git add src/ui/file_tree.zig && git commit -m "feat: file tree CRUD operations with targeted refresh"
```

---

### Task 7: Confirmation dialog

**Files:**
- Modify: `zz/src/ui/overlay.zig`

- [ ] **Step 1: Add ConfirmDialogState and renderConfirmDialog**

Add to overlay.zig:

```zig
pub const ConfirmDialogState = struct {
    message: []const u8,
    selected_yes: bool, // false = No selected (default)
    active: bool,
    /// Path to delete (stored for action execution)
    target_path: []const u8,
    target_is_dir: bool,

    pub fn open(message: []const u8, target_path: []const u8, is_dir: bool) ConfirmDialogState {
        return .{
            .message = message,
            .selected_yes = false,
            .active = true,
            .target_path = target_path,
            .target_is_dir = is_dir,
        };
    }
};

pub fn renderConfirmDialog(
    renderer: *Renderer,
    font: *FontFace,
    state: *const ConfirmDialogState,
) void {
    if (!state.active) return;

    const cell_w = font.cell_width;
    const cell_h = font.cell_height;
    if (cell_w == 0 or cell_h == 0) return;

    // Dim background
    const dim = Color.fromHex(0x11111b);
    var dy: u32 = 0;
    while (dy < renderer.height) : (dy += 1) {
        var dx: u32 = 0;
        while (dx < renderer.width) : (dx += 1) {
            renderer.blendPixel(dx, dy, dim, 150); // 60% opacity
        }
    }

    // Dialog box
    const msg_len: u32 = @intCast(state.message.len);
    const dialog_w = @max((msg_len + 6) * cell_w, 300);
    const dialog_h = cell_h * 4 + 16; // message row + gap + button row + padding
    const dx_pos = (renderer.width -| dialog_w) / 2;
    const dy_pos = (renderer.height -| dialog_h) / 2;

    // Background + border
    renderer.fillRect(dx_pos, dy_pos, dialog_w, dialog_h, overlay_bg);
    renderer.fillRect(dx_pos, dy_pos, dialog_w, 1, overlay_border);
    renderer.fillRect(dx_pos, dy_pos + dialog_h - 1, dialog_w, 1, overlay_border);
    renderer.fillRect(dx_pos, dy_pos, 1, dialog_h, overlay_border);
    renderer.fillRect(dx_pos + dialog_w - 1, dy_pos, 1, dialog_h, overlay_border);

    // Message text (centered)
    const msg_x = dx_pos + (dialog_w - msg_len * cell_w) / 2;
    const msg_y = dy_pos + cell_h;
    var mx: u32 = msg_x;
    for (state.message) |ch| {
        const glyph = font.getGlyph(ch) catch continue;
        const gx: i32 = @intCast(mx);
        const gy: i32 = @as(i32, @intCast(msg_y)) + font.ascent - @as(i32, glyph.bearing_y);
        renderer.drawGlyph(glyph, gx, gy, overlay_text);
        mx += cell_w;
    }

    // Buttons: [Yes]  [No]
    const btn_y = dy_pos + cell_h * 3;
    const btn_w = cell_w * 6;
    const gap: u32 = cell_w * 3;
    const total_btn_w = btn_w * 2 + gap;
    const btn_start_x = dx_pos + (dialog_w - total_btn_w) / 2;

    // Yes button
    const yes_bg = if (state.selected_yes) overlay_selected else overlay_bg;
    const yes_fg = if (state.selected_yes) overlay_text else overlay_dim;
    renderer.fillRect(btn_start_x, btn_y, btn_w, cell_h, yes_bg);
    renderer.fillRect(btn_start_x, btn_y, btn_w, 1, overlay_border);
    renderer.fillRect(btn_start_x, btn_y + cell_h - 1, btn_w, 1, overlay_border);
    // "Yes" centered in button
    const yes_text = "Yes";
    var yx = btn_start_x + (btn_w - @as(u32, @intCast(yes_text.len)) * cell_w) / 2;
    for (yes_text) |ch| {
        const glyph = font.getGlyph(ch) catch continue;
        const gx: i32 = @intCast(yx);
        const gy: i32 = @as(i32, @intCast(btn_y)) + font.ascent - @as(i32, glyph.bearing_y);
        renderer.drawGlyph(glyph, gx, gy, yes_fg);
        yx += cell_w;
    }

    // No button
    const no_x = btn_start_x + btn_w + gap;
    const no_bg = if (!state.selected_yes) overlay_selected else overlay_bg;
    const no_fg = if (!state.selected_yes) overlay_text else overlay_dim;
    renderer.fillRect(no_x, btn_y, btn_w, cell_h, no_bg);
    renderer.fillRect(no_x, btn_y, btn_w, 1, overlay_border);
    renderer.fillRect(no_x, btn_y + cell_h - 1, btn_w, 1, overlay_border);
    const no_text = "No";
    var nx = no_x + (btn_w - @as(u32, @intCast(no_text.len)) * cell_w) / 2;
    for (no_text) |ch| {
        const glyph = font.getGlyph(ch) catch continue;
        const gx: i32 = @intCast(nx);
        const gy: i32 = @as(i32, @intCast(btn_y)) + font.ascent - @as(i32, glyph.bearing_y);
        renderer.drawGlyph(glyph, gx, gy, no_fg);
        nx += cell_w;
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
cd ~/zz && zig build
```

- [ ] **Step 3: Commit**

```bash
cd ~/zz && git add src/ui/overlay.zig && git commit -m "feat: add confirmation dialog to overlay"
```

---

## Chunk 3: Wiring & Status Messages

### Task 8: Wire CRUD actions in main.zig

**Files:**
- Modify: `zz/src/main.zig`

- [ ] **Step 1: Add status message state**

Add near the other state variables:

```zig
var status_message: ?[]const u8 = null;
var status_message_time: i64 = 0; // monotonic timestamp
var confirm_dialog = Overlay.ConfirmDialogState{
    .message = "",
    .selected_yes = false,
    .active = false,
    .target_path = "",
    .target_is_dir = false,
};
var confirm_msg_buf: [256]u8 = undefined;
```

- [ ] **Step 2: Add tree_input mode keyboard handling**

In the keyboard event handler section, add handling for `tree_input` mode (before the normal key processing):

```zig
if (mode == .tree_input) {
    if (ke.keysym == window_mod.XK_Escape) {
        file_tree.inline_input = null;
        mode = .normal;
        markAllPanesDirty(&pane_mgr);
        continue;
    } else if (ke.keysym == window_mod.XK_Return) {
        if (file_tree.inline_input) |*input| {
            if (input.validate()) |err_msg| {
                status_message = err_msg;
                status_message_time = std.time.milliTimestamp();
            } else {
                const name = input.content();
                switch (input.mode) {
                    .new_file => {
                        if (file_tree.createNewFile(input.target_dir, name)) |new_path| {
                            // Open in new tab
                            _ = openFileInTab(&tab_mgr, &pane_mgr, new_path, allocator, &lsp_client, &lsp_needs_sync);
                            file_tree.active_path = pane_mgr.active_leaf.file_path;
                        } else |err| {
                            status_message = @errorName(err);
                            status_message_time = std.time.milliTimestamp();
                        }
                    },
                    .new_folder => {
                        file_tree.createNewFolder(input.target_dir, name) catch |err| {
                            status_message = @errorName(err);
                            status_message_time = std.time.milliTimestamp();
                        };
                    },
                    .rename_file => {
                        if (input.original_name) |_| {
                            const old_path = file_tree.entries.items[input.insert_at].path;
                            if (file_tree.renameEntry(old_path, name)) |new_path| {
                                // Update open tabs
                                if (tab_mgr.findByPath(old_path)) |tab_idx| {
                                    tab_mgr.tabs.items[tab_idx].file_path = new_path;
                                }
                                // LSP: close old, open new
                                if (lsp_client.isRunning()) {
                                    lsp_client.sendDidClose(old_path);
                                    if (tab_mgr.findByPath(new_path)) |tab_idx| {
                                        const view = tab_mgr.tabs.items[tab_idx];
                                        lsp_client.sendDidOpen(new_path, view.buffer.collectContent(allocator) catch "");
                                    }
                                }
                                file_tree.active_path = new_path;
                            } else |err| {
                                status_message = @errorName(err);
                                status_message_time = std.time.milliTimestamp();
                            }
                        }
                    },
                }
                file_tree.inline_input = null;
                mode = .normal;
            }
        }
        markAllPanesDirty(&pane_mgr);
        continue;
    } else if (ke.keysym == window_mod.XK_BackSpace) {
        if (file_tree.inline_input) |*input| input.backspace();
        markAllPanesDirty(&pane_mgr);
        continue;
    } else if (ke.keysym == window_mod.XK_Delete) {
        if (file_tree.inline_input) |*input| input.delete();
        markAllPanesDirty(&pane_mgr);
        continue;
    } else if (ke.keysym == window_mod.XK_Left) {
        if (file_tree.inline_input) |*input| input.moveLeft();
        markAllPanesDirty(&pane_mgr);
        continue;
    } else if (ke.keysym == window_mod.XK_Right) {
        if (file_tree.inline_input) |*input| input.moveRight();
        markAllPanesDirty(&pane_mgr);
        continue;
    } else if (ke.keysym == window_mod.XK_Home) {
        if (file_tree.inline_input) |*input| input.cursor_pos = 0;
        markAllPanesDirty(&pane_mgr);
        continue;
    } else if (ke.keysym == window_mod.XK_End) {
        if (file_tree.inline_input) |*input| input.cursor_pos = input.len;
        markAllPanesDirty(&pane_mgr);
        continue;
    }
    // Fall through for text_input events
}
```

Also handle text_input events for tree_input mode (in the text_input section):

```zig
if (mode == .tree_input) {
    if (file_tree.inline_input) |*input| {
        input.insertChar(text_bytes);
    }
    markAllPanesDirty(&pane_mgr);
    continue;
}
```

- [ ] **Step 3: Add confirm_dialog mode keyboard handling**

```zig
if (mode == .confirm_dialog) {
    if (ke.keysym == window_mod.XK_Escape or ke.keysym == window_mod.XK_n) {
        confirm_dialog.active = false;
        mode = .normal;
        markAllPanesDirty(&pane_mgr);
        continue;
    } else if (ke.keysym == window_mod.XK_y or ke.keysym == window_mod.XK_Return) {
        if (ke.keysym == window_mod.XK_y or confirm_dialog.selected_yes) {
            // Execute delete
            file_tree.deleteEntry(confirm_dialog.target_path, confirm_dialog.target_is_dir) catch |err| {
                status_message = @errorName(err);
                status_message_time = std.time.milliTimestamp();
            };
            // Close tabs for deleted file
            if (tab_mgr.findByPath(confirm_dialog.target_path)) |tab_idx| {
                tab_mgr.closeTab(tab_idx);
                syncPaneToActiveTab(&pane_mgr, &tab_mgr);
            }
        }
        confirm_dialog.active = false;
        mode = .normal;
        markAllPanesDirty(&pane_mgr);
        continue;
    } else if (ke.keysym == window_mod.XK_Tab or ke.keysym == window_mod.XK_Left or ke.keysym == window_mod.XK_Right) {
        confirm_dialog.selected_yes = !confirm_dialog.selected_yes;
        markAllPanesDirty(&pane_mgr);
        continue;
    }
}
```

- [ ] **Step 4: Wire file tree MenuAction dispatch in executeMenuAction**

Replace the file tree stubs in `executeMenuAction`:

```zig
.tree_new_file => {
    if (ctx_menu.tree_entry_index) |idx| {
        const entry = &file_tree.entries.items[idx];
        const dir = if (entry.is_dir) entry.path else (std.fs.path.dirname(entry.path) orelse ".");
        file_tree.inline_input = .{
            .mode = .new_file,
            .target_dir = dir,
            .insert_at = idx,
        };
        mode.* = .tree_input;
    }
},
.tree_new_folder => {
    if (ctx_menu.tree_entry_index) |idx| {
        const entry = &file_tree.entries.items[idx];
        const dir = if (entry.is_dir) entry.path else (std.fs.path.dirname(entry.path) orelse ".");
        file_tree.inline_input = .{
            .mode = .new_folder,
            .target_dir = dir,
            .insert_at = idx,
        };
        mode.* = .tree_input;
    }
},
.tree_rename => {
    if (ctx_menu.tree_entry_index) |idx| {
        const entry = &file_tree.entries.items[idx];
        // Don't allow renaming root
        if (entry.depth == 0 and entry.is_dir) return;
        var input = InlineInput{
            .mode = .rename_file,
            .target_dir = std.fs.path.dirname(entry.path) orelse ".",
            .insert_at = idx,
            .original_name = entry.name,
        };
        input.setText(entry.name);
        // Select name without extension
        const name = entry.name;
        if (!entry.is_dir) {
            if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
                if (dot > 0) input.cursor_pos = dot;
            }
        }
        file_tree.inline_input = input;
        mode.* = .tree_input;
    }
},
.tree_delete => {
    if (ctx_menu.tree_entry_index) |idx| {
        const entry = &file_tree.entries.items[idx];
        // Don't allow deleting root
        if (entry.depth == 0 and entry.is_dir) return;
        const msg = if (entry.is_dir)
            std.fmt.bufPrint(&confirm_msg_buf, "Delete \"{s}\" and its contents?", .{entry.name}) catch "Delete directory?"
        else
            std.fmt.bufPrint(&confirm_msg_buf, "Delete \"{s}\"?", .{entry.name}) catch "Delete file?";
        confirm_dialog = Overlay.ConfirmDialogState.open(msg, entry.path, entry.is_dir);
        mode.* = .confirm_dialog;
    }
},
.tree_copy_path => {
    if (ctx_menu.tree_entry_index) |idx| {
        const entry = &file_tree.entries.items[idx];
        // Build absolute path
        const abs_path = std.fs.cwd().realpathAlloc(allocator, entry.path) catch return;
        win.setClipboard(abs_path);
    }
},
.tree_copy_relative_path => {
    if (ctx_menu.tree_entry_index) |idx| {
        const entry = &file_tree.entries.items[idx];
        const path_copy = allocator.dupe(u8, entry.path) catch return;
        win.setClipboard(path_copy);
    }
},
```

Note: `ctx_menu` is accessed via closure or passed as parameter. The `mode` parameter in `executeMenuAction` needs to be `*EditorMode` to allow setting it. Adjust as needed based on what's in scope.

- [ ] **Step 5: Add renderConfirmDialog and renderInlineInput to renderFrame**

In `renderFrame`, after the context menu render:

```zig
// Confirm dialog (renders over everything)
Overlay.renderConfirmDialog(&renderer, font, &confirm_dialog);

// File tree inline input (renders within file tree area)
file_tree.renderInlineInput(&renderer, font, tab_bar_h);
```

- [ ] **Step 6: Add status message rendering**

In `renderFrame` or in `view_render.zig`'s status bar section, add:

```zig
// Transient status message (replaces center section for 3 seconds)
if (status_message) |msg| {
    const elapsed = std.time.milliTimestamp() - status_message_time;
    if (elapsed < 3000) {
        // Render message in status bar center
        const warn_color = Color.fromHex(0xfab387); // peach
        // ... render msg text at status bar center position ...
    } else {
        status_message = null;
    }
}
```

- [ ] **Step 7: Build and test full flow**

```bash
cd ~/zz && zig build && ./zig-out/bin/zz .
```

Test each operation:
1. **New File**: Ctrl+B → right-click folder → New File → type "test.txt" → Enter → file created and opened in tab
2. **New Folder**: Right-click → New Folder → type "mydir" → Enter → folder created
3. **Rename**: Right-click file → Rename → edit name → Enter → file renamed, tab updated
4. **Delete file**: Right-click file → Delete → confirmation dialog → Yes → file deleted, tab closed
5. **Delete folder**: Right-click folder → Delete → "and its contents?" → Yes → deleted
6. **Copy Path**: Right-click → Copy Path → paste elsewhere → absolute path
7. **Copy Relative Path**: Right-click → Copy Relative Path → relative path
8. **Cancel**: Escape cancels inline input and confirmation dialog
9. **Root guard**: Right-click project root → Delete → no-op

- [ ] **Step 8: Commit**

```bash
cd ~/zz && git add src/main.zig src/ui/overlay.zig src/ui/file_tree.zig && git commit -m "feat: wire file tree CRUD with context menu, confirmation dialog, and status messages"
```

---

### Task 9: Status bar message display

**Files:**
- Modify: `zz/src/editor/view_render.zig`

- [ ] **Step 1: Add status message parameter and rendering**

Add `status_msg: ?[]const u8` parameter to the status bar rendering path. In the status bar area, if `status_msg` is non-null, render it in peach color (0xfab387) at the center of the status bar, replacing the normal center content.

The exact integration depends on how status bar is called. The status bar is rendered in `renderStatusBar` in `view_render.zig`. Add the message parameter and a conditional render path.

- [ ] **Step 2: Build and test**

```bash
cd ~/zz && zig build && ./zig-out/bin/zz .
```

Try creating a file with a name that already exists → status bar shows error for 3 seconds.

- [ ] **Step 3: Commit**

```bash
cd ~/zz && git add src/editor/view_render.zig src/main.zig && git commit -m "feat: transient status bar messages for CRUD errors"
```

---

### Task 10: End-to-end verification and tag

- [ ] **Step 1: Full test cycle**

```bash
cd ~/zz && zig build -Doptimize=ReleaseFast && ./zig-out/bin/zz .
```

Verify:
1. Editor right-click menu works as before (with shortcut hints now visible)
2. File tree right-click → all CRUD operations work
3. Inline input handles UTF-8 characters (try Japanese filename)
4. Delete confirmation dialog works (Y/N keys, Tab to switch, Escape cancels)
5. Status bar shows errors for invalid operations
6. Tab paths update correctly after rename
7. Deleted file tabs close properly
8. No segfaults or fd leaks after repeated CRUD operations

- [ ] **Step 2: Run existing tests**

```bash
cd ~/zz && zig build test
```

Expected: All existing tests pass (buffer, cursor, lsp tests).

- [ ] **Step 3: Tag milestone**

```bash
cd ~/zz && git tag v0.1.0-phase4-crud -m "Phase 4: Context menu & file tree CRUD"
```

---

## File Summary

| File | Changes |
|---|---|
| `src/ui/overlay.zig` | `MenuAction` enum, `MenuItem` struct, `ContextMenuState` struct, refactored `renderContextMenu` with shortcuts/disabled states, `ConfirmDialogState` + `renderConfirmDialog` |
| `src/ui/file_tree.zig` | `InlineInput` struct (UTF-8 aware), `renderInlineInput`, `refreshDirectory`, `createNewFile`, `createNewFolder`, `renameEntry`, `deleteEntry` |
| `src/main.zig` | `context_menu`/`tree_input`/`confirm_dialog` modes, `ContextMenuState` replaces ad-hoc vars, `editor_menu_items`/`file_tree_menu_items` typed arrays, `executeMenuAction` typed dispatch, right-click area routing, tree_input keyboard handling, confirm_dialog keyboard handling, status message state |
| `src/editor/view_render.zig` | Transient status message rendering in status bar |
