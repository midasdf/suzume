# zz Phase 4: Context Menu & File Tree CRUD — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add file tree CRUD operations (create/rename/delete/copy path) with right-click context menus in both file tree and editor, replacing the ad-hoc string-based context menu with a typed MenuItem/MenuAction system.

**Architecture:** Refactor existing `context_menu_active` bool + string array in main.zig into a `ContextMenuState` struct with typed `MenuAction` enum. Extend overlay.zig rendering to support shortcut hints and disabled items. Add `InlineInput` to file_tree.zig for naming operations. Add `confirm_dialog` and `tree_input` modes to main.zig. File operations use `std.fs` directly.

**Tech Stack:** Zig, std.fs, existing xcb/SHM rendering, existing overlay.zig/file_tree.zig

**Spec:** `docs/superpowers/specs/2026-04-02-zz-context-menu-file-crud-design.md`

---

## Critical Implementation Notes

**Import pattern:** `main.zig:14` imports `const Overlay = @import("ui/overlay.zig").Overlay;` — this binds to the *Overlay struct*, not the module. All new types (`MenuAction`, `MenuItem`, `ContextMenuState`) MUST be placed **inside** the `Overlay` struct in overlay.zig so they are accessible as `Overlay.MenuItem`, etc.

**openFileInTab signature:** `fn openFileInTab(tab_mgr: *TabManager, allocator: std.mem.Allocator, path: []const u8, lsp_client: ?*lsp.LspClient, font: *const FontFace, git_info: ?*GitInfo) void` (main.zig:2193).

**LSP methods:** `lsp_client.didClose(uri)` and `lsp_client.didOpen(uri, language_id, content)` — take `file://` prefixed URIs, not raw paths. Check `lsp_client.child != null` for running state.

**expandAt pattern:** Uses `self.entries.insert(self.allocator, insert_pos, entry)` to insert children at the correct position (not append). collapseAt removes children by depth. Use collapse-then-expand for targeted refresh.

**text_input routing:** `main.zig:502` `.text_input` handler checks `mode != .normal` and falls through to `overlay.appendText`. New `tree_input` mode check MUST be inserted BEFORE the `mode != .normal` check to avoid corrupting overlay state.

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `src/ui/overlay.zig` | Modify | Add `MenuAction`/`MenuItem`/`ContextMenuState` types INSIDE Overlay struct, refactor `renderContextMenu`, make `dimScreen` pub, add `renderConfirmDialog` |
| `src/ui/file_tree.zig` | Modify | Add `InlineInput` struct, CRUD operations, `refreshDirectory` (collapse+expand), `renderInlineInput` |
| `src/main.zig` | Modify | Replace ad-hoc context menu state, add `tree_input`/`confirm_dialog` modes, right-click area routing, `MenuAction` dispatch, status message, F2/Delete shortcuts |
| `src/editor/view_render.zig` | Modify | Status bar message rendering |

---

## Chunk 1: Context Menu Refactor

### Task 1: Add MenuItem/MenuAction types inside Overlay struct

**Files:**
- Modify: `zz/src/ui/overlay.zig`

- [ ] **Step 1: Add types inside the Overlay struct (before the closing `};`)**

These go INSIDE `pub const Overlay = struct { ... };` so they're accessible as `Overlay.MenuAction` etc. from main.zig.

```zig
    // === Context Menu Types ===

    pub const MenuSource = enum { editor, file_tree };

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
        source: MenuSource,
        tree_entry_index: ?usize,
        active: bool,

        pub fn open(items: []const MenuItem, px: u32, py: u32, source: MenuSource, tree_idx: ?usize) ContextMenuState {
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
            while (self.selected > 0 and !self.items[self.selected].enabled) {
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

    pub const ConfirmDialogState = struct {
        message: []const u8,
        selected_yes: bool,
        active: bool,
        target_path: []const u8,
        target_is_dir: bool,

        pub fn open(message: []const u8, target_path: []const u8, is_dir: bool) ConfirmDialogState {
            return .{
                .message = message,
                .selected_yes = false, // No selected by default (safety)
                .active = true,
                .target_path = target_path,
                .target_is_dir = is_dir,
            };
        }
    };
```

- [ ] **Step 2: Build and verify types compile**

```bash
cd ~/zz && zig build
```

Expected: Compiles (types defined but not yet used).

- [ ] **Step 3: Commit**

```bash
cd ~/zz && git add src/ui/overlay.zig && git commit -m "feat: add MenuItem/MenuAction/ContextMenuState types to Overlay"
```

---

### Task 2: Refactor renderContextMenu to use MenuItem

**Files:**
- Modify: `zz/src/ui/overlay.zig` (replace renderContextMenu at lines 248-314)

- [ ] **Step 1: Make dimScreen public**

Change `fn dimScreen` (line 316) to `pub fn dimScreen` so it can be reused by renderConfirmDialog.

- [ ] **Step 2: Replace renderContextMenu**

Replace the existing `renderContextMenu` function with this version that accepts `ContextMenuState`:

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
        const gap: u32 = if (max_shortcut_len > 0) 3 else 0;
        const content_cols = max_label_len + gap + max_shortcut_len;
        const menu_w = @max((content_cols + 4) * cell_w, 180);

        // Count separator lines for height
        var sep_count: u32 = 0;
        for (items) |item| {
            if (item.separator_after) sep_count += 1;
        }
        const menu_h: u32 = @as(u32, @intCast(items.len)) * cell_h + sep_count * 4 + 8;

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

            const row_bg = if (is_sel and item.enabled) overlay_selected else overlay_bg;
            const row_fg = if (!item.enabled) Color.fromHex(0x585b70)
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
                const sc_fg = Color.fromHex(0x9399b2);
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

            // Separator after this item
            if (item.separator_after) {
                renderer.fillRect(mx + cell_w, y + 1, menu_w - cell_w * 2, 1, overlay_border);
                y += 4;
            }
        }
    }
```

- [ ] **Step 3: Add renderConfirmDialog**

Add inside the Overlay struct:

```zig
    pub fn renderConfirmDialog(
        renderer: *Renderer,
        font: *FontFace,
        state: *const ConfirmDialogState,
    ) void {
        if (!state.active) return;

        const cell_w = font.cell_width;
        const cell_h = font.cell_height;
        if (cell_w == 0 or cell_h == 0) return;

        // Dim background (reuse existing dimScreen)
        dimScreen(renderer);

        // Dialog box dimensions
        const msg_len: u32 = @intCast(state.message.len);
        const dialog_w = @max((msg_len + 6) * cell_w, 300);
        const dialog_h = cell_h * 4 + 16;
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
        var mmx: u32 = msg_x;
        for (state.message) |ch| {
            const glyph = font.getGlyph(ch) catch continue;
            const gx: i32 = @intCast(mmx);
            const gy: i32 = @as(i32, @intCast(msg_y)) + font.ascent - @as(i32, glyph.bearing_y);
            renderer.drawGlyph(glyph, gx, gy, overlay_text);
            mmx += cell_w;
        }

        // Buttons: [Yes]  [No]
        const btn_y = dy_pos + cell_h * 3;
        const btn_w = cell_w * 6;
        const btn_gap: u32 = cell_w * 3;
        const total_btn_w = btn_w * 2 + btn_gap;
        const btn_start_x = dx_pos + (dialog_w - total_btn_w) / 2;

        // Yes button
        const yes_bg = if (state.selected_yes) overlay_selected else overlay_bg;
        const yes_fg = if (state.selected_yes) overlay_text else overlay_dim;
        renderer.fillRect(btn_start_x, btn_y, btn_w, cell_h, yes_bg);
        renderer.fillRect(btn_start_x, btn_y, btn_w, 1, overlay_border);
        renderer.fillRect(btn_start_x, btn_y + cell_h - 1, btn_w, 1, overlay_border);
        const yes_label = "Yes";
        var yx: u32 = btn_start_x + (btn_w - @as(u32, @intCast(yes_label.len)) * cell_w) / 2;
        for (yes_label) |ch| {
            const glyph = font.getGlyph(ch) catch continue;
            const gx_y: i32 = @intCast(yx);
            const gy_y: i32 = @as(i32, @intCast(btn_y)) + font.ascent - @as(i32, glyph.bearing_y);
            renderer.drawGlyph(glyph, gx_y, gy_y, yes_fg);
            yx += cell_w;
        }

        // No button
        const no_x = btn_start_x + btn_w + btn_gap;
        const no_bg = if (!state.selected_yes) overlay_selected else overlay_bg;
        const no_fg = if (!state.selected_yes) overlay_text else overlay_dim;
        renderer.fillRect(no_x, btn_y, btn_w, cell_h, no_bg);
        renderer.fillRect(no_x, btn_y, btn_w, 1, overlay_border);
        renderer.fillRect(no_x, btn_y + cell_h - 1, btn_w, 1, overlay_border);
        const no_label = "No";
        var nx: u32 = no_x + (btn_w - @as(u32, @intCast(no_label.len)) * cell_w) / 2;
        for (no_label) |ch| {
            const glyph = font.getGlyph(ch) catch continue;
            const gx_n: i32 = @intCast(nx);
            const gy_n: i32 = @as(i32, @intCast(btn_y)) + font.ascent - @as(i32, glyph.bearing_y);
            renderer.drawGlyph(glyph, gx_n, gy_n, no_fg);
            nx += cell_w;
        }
    }
```

- [ ] **Step 4: Build and verify**

```bash
cd ~/zz && zig build
```

Expected: Compiles. Call sites in main.zig will break (old renderContextMenu signature) — fixed in Task 3.

- [ ] **Step 5: Commit**

```bash
cd ~/zz && git add src/ui/overlay.zig && git commit -m "refactor: renderContextMenu uses typed MenuItem, add renderConfirmDialog"
```

---

### Task 3: Migrate main.zig context menu state

**Files:**
- Modify: `zz/src/main.zig`

- [ ] **Step 1: Add context_menu, tree_input, confirm_dialog to EditorMode enum (line 31)**

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
    context_menu,
    tree_input,
    confirm_dialog,
};
```

- [ ] **Step 2: Replace context_menu_items (lines 71-83) with typed MenuItem arrays**

```zig
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

- [ ] **Step 3: Replace ad-hoc state variables (lines 268-271)**

Remove:
```zig
var context_menu_active = false;
var context_menu_x: u32 = 0;
var context_menu_y: u32 = 0;
var context_menu_selected: usize = 0;
```

Add:
```zig
var ctx_menu = Overlay.ContextMenuState{
    .items = &editor_menu_items,
    .selected = 0, .x = 0, .y = 0,
    .source = .editor, .tree_entry_index = null, .active = false,
};
var confirm_dialog = Overlay.ConfirmDialogState{
    .message = "", .selected_yes = false, .active = false,
    .target_path = "", .target_is_dir = false,
};
var confirm_msg_buf: [256]u8 = undefined;
var status_message: ?[]const u8 = null;
var status_message_time: i64 = 0;
```

- [ ] **Step 4: Replace executeContextMenuItem (lines 1181-1211) with typed dispatch**

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
    tab_mgr: *TabManager,
    pane_mgr: *PaneManager,
    font: *const FontFace,
    git_info: ?*GitInfo,
    ctx_menu_ptr: *Overlay.ContextMenuState,
    confirm_dialog_ptr: *Overlay.ConfirmDialogState,
    confirm_buf: *[256]u8,
    status_msg: *?[]const u8,
    status_time: *i64,
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
        .tree_new_file, .tree_new_folder => {
            if (ctx_menu_ptr.tree_entry_index) |idx| {
                const entry = &file_tree.entries.items[idx];
                const dir = if (entry.is_dir) entry.path else (std.fs.path.dirname(entry.path) orelse ".");
                file_tree.inline_input = .{
                    .mode = if (action == .tree_new_file) .new_file else .new_folder,
                    .target_dir = dir,
                    .insert_at = idx,
                };
                mode.* = .tree_input;
            }
        },
        .tree_rename => {
            if (ctx_menu_ptr.tree_entry_index) |idx| {
                const entry = &file_tree.entries.items[idx];
                if (entry.depth == 0 and entry.is_dir) return; // Don't rename root
                var input = FileTree.InlineInput{
                    .mode = .rename_file,
                    .target_dir = std.fs.path.dirname(entry.path) orelse ".",
                    .insert_at = idx,
                    .original_name = entry.name,
                };
                input.setText(entry.name);
                // Position cursor before extension (last dot, not at position 0 for dotfiles)
                if (!entry.is_dir) {
                    if (std.mem.lastIndexOfScalar(u8, entry.name, '.')) |dot| {
                        if (dot > 0) input.cursor_pos = dot;
                    }
                }
                file_tree.inline_input = input;
                mode.* = .tree_input;
            }
        },
        .tree_delete => {
            if (ctx_menu_ptr.tree_entry_index) |idx| {
                const entry = &file_tree.entries.items[idx];
                if (entry.depth == 0 and entry.is_dir) return; // Don't delete root
                const msg = if (entry.is_dir)
                    std.fmt.bufPrint(confirm_buf, "Delete \"{s}\" and its contents?", .{entry.name}) catch "Delete directory?"
                else
                    std.fmt.bufPrint(confirm_buf, "Delete \"{s}\"?", .{entry.name}) catch "Delete file?";
                confirm_dialog_ptr.* = Overlay.ConfirmDialogState.open(msg, entry.path, entry.is_dir);
                mode.* = .confirm_dialog;
            }
        },
        .tree_copy_path => {
            if (ctx_menu_ptr.tree_entry_index) |idx| {
                const entry = &file_tree.entries.items[idx];
                const abs_path = std.fs.cwd().realpathAlloc(allocator, entry.path) catch return;
                win.setClipboard(abs_path);
            }
        },
        .tree_copy_relative_path => {
            if (ctx_menu_ptr.tree_entry_index) |idx| {
                const entry = &file_tree.entries.items[idx];
                const path_copy = allocator.dupe(u8, entry.path) catch return;
                win.setClipboard(path_copy);
            }
        },
    }
    _ = tab_mgr;
    _ = pane_mgr;
    _ = font;
    _ = git_info;
    _ = status_msg;
    _ = status_time;
}
```

Note: `tab_mgr`, `pane_mgr`, `font`, `git_info`, `status_msg`, `status_time` are unused for now but needed by tree_input confirm handler in Task 5. The executor may restructure this — the key point is that file tree actions set mode to `tree_input`/`confirm_dialog` and the actual fs operations happen in those mode handlers, not here.

- [ ] **Step 5: Replace keyboard handling for context menu (lines 302-335)**

Find `if (context_menu_active) {` and replace the entire block with:

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
            executeMenuAction(action, editor, &win, &lsp_client, &lsp_needs_sync, &mode, &overlay, &filtered_display, allocator, &file_tree, &tab_mgr, &pane_mgr, &font, git_info, &ctx_menu, &confirm_dialog, &confirm_msg_buf, &status_message, &status_message_time);
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

- [ ] **Step 6: Replace right-click handler (lines 699-727)**

Find `} else if (me.button == .right) {` and replace:

```zig
} else if (me.button == .right) {
    if (ctx_menu.active) {
        ctx_menu.close();
    } else {
        const px: u32 = if (me.x >= 0) @intCast(me.x) else 0;
        const py: u32 = if (me.y >= 0) @intCast(me.y) else 0;
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
            // Editor right-click (preserve existing behavior)
            if (terminal.focused) terminal.unfocus();
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

- [ ] **Step 7: Replace mouse hover handling**

Find `if (context_menu_active) {` in the mouse motion section and replace with:

```zig
if (ctx_menu.active) {
    const cell_h = font.cell_height;
    if (cell_h > 0) {
        const my_base: i32 = @intCast(ctx_menu.y + 4);
        const items_h: i32 = @intCast(@as(u32, @intCast(ctx_menu.items.len)) * cell_h);
        if (me.y >= my_base and me.y < my_base + items_h) {
            const row = @as(usize, @intCast(@as(u32, @intCast(me.y - my_base)) / cell_h));
            if (row < ctx_menu.items.len and ctx_menu.items[row].enabled) {
                ctx_menu.selected = row;
                needs_redraw = true;
            }
        }
    }
}
```

- [ ] **Step 8: Update mouse click on context menu items**

Find the left-click handler for context menu (near lines 586-609) that checks `context_menu_active`. Replace with `ctx_menu.active` and use `ctx_menu.selectedAction()` + `executeMenuAction(...)`.

- [ ] **Step 9: Update renderFrame**

Replace the four context menu parameters in `renderFrame` signature with a single `ctx_menu: *const Overlay.ContextMenuState` and add `confirm_dialog: *const Overlay.ConfirmDialogState`.

Inside renderFrame, replace:
```zig
if (ctx_menu_active) {
    Overlay.renderContextMenu(&renderer, font, ctx_menu_x, ctx_menu_y, &context_menu_items, ctx_menu_selected);
}
```
With:
```zig
Overlay.renderContextMenu(&renderer, font, ctx_menu);
Overlay.renderConfirmDialog(&renderer, font, confirm_dialog);
```

Update the renderFrame call site to pass `&ctx_menu, &confirm_dialog`.

- [ ] **Step 10: Remove contextMenuWidth helper if it exists**

Search for `contextMenuWidth` in main.zig and remove it.

- [ ] **Step 11: Build and test editor context menu still works**

```bash
cd ~/zz && zig build && ./zig-out/bin/zz src/main.zig
```

Test: right-click in editor → menu with shortcut hints → keyboard nav → Enter executes → Escape closes.

- [ ] **Step 12: Commit**

```bash
cd ~/zz && git add src/main.zig src/ui/overlay.zig && git commit -m "refactor: migrate context menu to typed MenuItem/MenuAction system"
```

---

## Chunk 2: File Tree CRUD

### Task 4: InlineInput for file tree naming

**Files:**
- Modify: `zz/src/ui/file_tree.zig`

- [ ] **Step 1: Add InlineInput struct to FileTree**

Add after the Entry struct definition, inside FileTree:

```zig
    pub const InlineInput = struct {
        buffer: [256]u8 = undefined,
        len: usize = 0,
        cursor_pos: usize = 0,
        mode: enum { new_file, new_folder, rename_file } = .new_file,
        target_dir: []const u8 = "",
        insert_at: usize = 0,
        original_name: ?[]const u8 = null,

        pub fn setText(self: *InlineInput, text: []const u8) void {
            const copy_len = @min(text.len, self.buffer.len);
            @memcpy(self.buffer[0..copy_len], text[0..copy_len]);
            self.len = copy_len;
            self.cursor_pos = copy_len;
        }

        pub fn insertChar(self: *InlineInput, bytes: []const u8) void {
            if (self.len + bytes.len > self.buffer.len) return;
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
            var prev = self.cursor_pos - 1;
            while (prev > 0 and (self.buffer[prev] & 0xC0) == 0x80) prev -= 1;
            const cp_len = self.cursor_pos - prev;
            const remaining = self.len - self.cursor_pos;
            var j: usize = 0;
            while (j < remaining) : (j += 1) self.buffer[prev + j] = self.buffer[self.cursor_pos + j];
            self.len -= cp_len;
            self.cursor_pos = prev;
        }

        pub fn delete(self: *InlineInput) void {
            if (self.cursor_pos >= self.len) return;
            const cp_len = std.unicode.utf8ByteSequenceLength(self.buffer[self.cursor_pos]) catch 1;
            const actual_len = @min(cp_len, self.len - self.cursor_pos);
            const remaining = self.len - self.cursor_pos - actual_len;
            var j: usize = 0;
            while (j < remaining) : (j += 1) self.buffer[self.cursor_pos + j] = self.buffer[self.cursor_pos + actual_len + j];
            self.len -= actual_len;
        }

        pub fn moveLeft(self: *InlineInput) void {
            if (self.cursor_pos == 0) return;
            self.cursor_pos -= 1;
            while (self.cursor_pos > 0 and (self.buffer[self.cursor_pos] & 0xC0) == 0x80) self.cursor_pos -= 1;
        }

        pub fn moveRight(self: *InlineInput) void {
            if (self.cursor_pos >= self.len) return;
            const cp_len = std.unicode.utf8ByteSequenceLength(self.buffer[self.cursor_pos]) catch 1;
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

Add field to FileTree struct (near other fields):
```zig
    pub inline_input: ?InlineInput = null,
```

- [ ] **Step 2: Add renderInlineInput method**

```zig
    pub fn renderInlineInput(self: *const FileTree, renderer: *Renderer, font: *FontFace, tab_bar_h: u32) void {
        const input = self.inline_input orelse return;
        const cell_h = font.cell_height;
        const cell_w = font.cell_width;
        if (cell_h == 0 or cell_w == 0) return;

        const top_pad: u32 = 4;
        const content_start = tab_bar_h + top_pad;
        const visible_row = if (input.insert_at >= self.scroll_offset) input.insert_at - self.scroll_offset else return;
        const y = content_start + @as(u32, @intCast(visible_row)) * cell_h;
        const sw = self.sidebarWidth(font);

        const surface1 = Color.fromHex(0x45475a);
        renderer.fillRect(0, y, sw, cell_h, surface1);

        // Indent based on depth
        const depth: u32 = if (input.insert_at < self.entries.items.len) self.entries.items[input.insert_at].depth + 1 else 1;
        const indent = depth * cell_w * 2 + cell_w;

        // Render text with codepoint counting for cursor position
        const text_color = Color.fromHex(0xcdd6f4);
        var x = indent;
        const text = input.content();
        var byte_idx: usize = 0;
        var cursor_x: u32 = indent; // Track cursor pixel position
        for (text) |ch| {
            if (byte_idx == input.cursor_pos) cursor_x = x;
            const glyph = font.getGlyph(ch) catch continue;
            const gx: i32 = @intCast(x);
            const gy: i32 = @as(i32, @intCast(y)) + font.ascent - @as(i32, glyph.bearing_y);
            renderer.drawGlyph(glyph, gx, gy, text_color);
            x += cell_w;
            byte_idx += 1;
        }
        if (input.cursor_pos == input.len) cursor_x = x;

        // Cursor beam
        const cursor_color = Color.fromHex(0xf5e0dc);
        renderer.fillRect(cursor_x, y + 2, 2, cell_h - 4, cursor_color);
    }
```

- [ ] **Step 3: Add refreshDirectory using collapse-then-expand pattern**

This reuses the existing `collapseAt` and `expandAt` methods rather than reimplementing subtree management:

```zig
    /// Refresh a directory's children by collapsing and re-expanding.
    /// Preserves expand state of sibling directories by recording them first.
    pub fn refreshDirectory(self: *FileTree, dir_path: []const u8) !void {
        // Find the directory entry
        var dir_idx: ?usize = null;
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.path, dir_path) and entry.is_dir) {
                dir_idx = i;
                break;
            }
        }

        const idx = dir_idx orelse {
            try self.populate(); // Fallback: full refresh
            return;
        };

        // Remember which subdirectories were expanded (store paths)
        var expanded_paths = std.ArrayList([]u8).init(self.allocator);
        defer {
            for (expanded_paths.items) |p| self.allocator.free(p);
            expanded_paths.deinit();
        }

        const parent_depth = self.entries.items[idx].depth;
        var scan = idx + 1;
        while (scan < self.entries.items.len and self.entries.items[scan].depth > parent_depth) : (scan += 1) {
            const child = &self.entries.items[scan];
            if (child.is_dir and child.is_expanded) {
                const p = self.allocator.dupe(u8, child.path) catch continue;
                expanded_paths.append(self.allocator, p) catch {
                    self.allocator.free(p);
                };
            }
        }

        // Collapse and re-expand
        self.collapseAt(idx);
        try self.expandAt(idx);

        // Re-expand previously expanded subdirectories
        var entry_scan: usize = idx + 1;
        while (entry_scan < self.entries.items.len and self.entries.items[entry_scan].depth > parent_depth) : (entry_scan += 1) {
            const child = &self.entries.items[entry_scan];
            if (child.is_dir and !child.is_expanded) {
                for (expanded_paths.items) |exp_path| {
                    if (std.mem.eql(u8, child.path, exp_path)) {
                        self.expandAt(entry_scan) catch {};
                        break;
                    }
                }
            }
        }
    }
```

- [ ] **Step 4: Add CRUD operation methods**

```zig
    pub fn createNewFile(self: *FileTree, dir_path: []const u8, name: []const u8) !void {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch return error.NameTooLong;
        const file = std.fs.cwd().createFile(full_path, .{ .exclusive = true }) catch |err| return err;
        file.close();
        try self.refreshDirectory(dir_path);
    }

    pub fn createNewFolder(self: *FileTree, dir_path: []const u8, name: []const u8) !void {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch return error.NameTooLong;
        try std.fs.cwd().makeDir(full_path);
        try self.refreshDirectory(dir_path);
    }

    pub fn renameEntry(self: *FileTree, old_path: []const u8, new_name: []const u8) !void {
        const parent = std.fs.path.dirname(old_path) orelse ".";
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const new_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ parent, new_name }) catch return error.NameTooLong;
        try std.fs.cwd().rename(old_path, new_path);
        try self.refreshDirectory(parent);
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

- [ ] **Step 5: Build and verify**

```bash
cd ~/zz && zig build
```

- [ ] **Step 6: Commit**

```bash
cd ~/zz && git add src/ui/file_tree.zig && git commit -m "feat: file tree InlineInput, CRUD operations, targeted refresh"
```

---

## Chunk 3: Wiring & Polish

### Task 5: Wire tree_input and confirm_dialog modes in main.zig

**Files:**
- Modify: `zz/src/main.zig`

- [ ] **Step 1: Add tree_input text_input handling**

At `main.zig:502`, the `.text_input` handler starts with `if (mode != .normal)`. Insert tree_input check BEFORE that check:

```zig
.text_input => |te| {
    // tree_input: route text to inline input (MUST be before mode != .normal check)
    if (mode == .tree_input) {
        if (file_tree.inline_input) |*input| {
            input.insertChar(te.slice());
        }
        markAllPanesDirty(&pane_mgr);
        continue;
    }
    // confirm_dialog: consume and ignore text input
    if (mode == .confirm_dialog) continue;

    if (mode != .normal) {
        // ... existing overlay text handling ...
```

- [ ] **Step 2: Add tree_input keyboard handling**

In the `.key_press` handler, AFTER the `ctx_menu.active` check and BEFORE normal key processing, add:

```zig
if (mode == .tree_input) {
    if (ke.keysym == window_mod.XK_Escape) {
        file_tree.inline_input = null;
        mode = .normal;
    } else if (ke.keysym == window_mod.XK_Return) {
        if (file_tree.inline_input) |*input| {
            if (input.validate()) |err_msg| {
                status_message = err_msg;
                status_message_time = std.time.milliTimestamp();
            } else {
                const name = input.content();
                switch (input.mode) {
                    .new_file => {
                        file_tree.createNewFile(input.target_dir, name) catch |err| {
                            status_message = @errorName(err);
                            status_message_time = std.time.milliTimestamp();
                            markAllPanesDirty(&pane_mgr);
                            continue;
                        };
                        // Open new file in tab — build path
                        var open_buf: [std.fs.max_path_bytes]u8 = undefined;
                        const open_path = std.fmt.bufPrint(&open_buf, "{s}/{s}", .{ input.target_dir, name }) catch "";
                        if (open_path.len > 0) {
                            openFileInTab(&tab_mgr, allocator, open_path, &lsp_client, &font, git_info);
                            syncPaneToActiveTab(&pane_mgr, &tab_mgr);
                            file_tree.active_path = pane_mgr.active_leaf.file_path;
                        }
                    },
                    .new_folder => {
                        file_tree.createNewFolder(input.target_dir, name) catch |err| {
                            status_message = @errorName(err);
                            status_message_time = std.time.milliTimestamp();
                            markAllPanesDirty(&pane_mgr);
                            continue;
                        };
                    },
                    .rename_file => {
                        if (input.original_name) |_| {
                            const entry = &file_tree.entries.items[input.insert_at];
                            const old_path = entry.path;
                            // Check if file is open in a tab BEFORE rename (path will change)
                            const had_tab = tab_mgr.findByPath(old_path) != null;
                            file_tree.renameEntry(old_path, name) catch |err| {
                                status_message = @errorName(err);
                                status_message_time = std.time.milliTimestamp();
                                markAllPanesDirty(&pane_mgr);
                                continue;
                            };
                            // If file was open, close old tab and reopen with new path
                            if (had_tab) {
                                var new_path_buf: [std.fs.max_path_bytes]u8 = undefined;
                                const parent = std.fs.path.dirname(old_path) orelse ".";
                                const new_path = std.fmt.bufPrint(&new_path_buf, "{s}/{s}", .{ parent, name }) catch "";
                                if (new_path.len > 0) {
                                    // LSP: close old URI
                                    if (lsp_client.child != null) {
                                        var uri_buf: [std.fs.max_path_bytes + 8]u8 = undefined;
                                        const old_uri = std.fmt.bufPrint(&uri_buf, "file://{s}", .{old_path}) catch "";
                                        if (old_uri.len > 0) lsp_client.didClose(old_uri);
                                    }
                                    // Reopen in tab
                                    openFileInTab(&tab_mgr, allocator, new_path, &lsp_client, &font, git_info);
                                    syncPaneToActiveTab(&pane_mgr, &tab_mgr);
                                    file_tree.active_path = pane_mgr.active_leaf.file_path;
                                }
                            }
                        }
                    },
                }
                file_tree.inline_input = null;
                mode = .normal;
            }
        }
    } else if (ke.keysym == window_mod.XK_BackSpace) {
        if (file_tree.inline_input) |*input| input.backspace();
    } else if (ke.keysym == window_mod.XK_Delete) {
        if (file_tree.inline_input) |*input| input.delete();
    } else if (ke.keysym == window_mod.XK_Left) {
        if (file_tree.inline_input) |*input| input.moveLeft();
    } else if (ke.keysym == window_mod.XK_Right) {
        if (file_tree.inline_input) |*input| input.moveRight();
    } else if (ke.keysym == window_mod.XK_Home) {
        if (file_tree.inline_input) |*input| input.cursor_pos = 0;
    } else if (ke.keysym == window_mod.XK_End) {
        if (file_tree.inline_input) |*input| input.cursor_pos = input.len;
    }
    markAllPanesDirty(&pane_mgr);
    continue;
}
```

- [ ] **Step 3: Add confirm_dialog keyboard handling**

After the tree_input block:

```zig
if (mode == .confirm_dialog) {
    if (ke.keysym == window_mod.XK_Escape or ke.keysym == window_mod.XK_n) {
        confirm_dialog.active = false;
        mode = .normal;
    } else if (ke.keysym == window_mod.XK_y) {
        // Y key always confirms
        file_tree.deleteEntry(confirm_dialog.target_path, confirm_dialog.target_is_dir) catch |err| {
            status_message = @errorName(err);
            status_message_time = std.time.milliTimestamp();
        };
        // Close tabs for deleted files (including files inside deleted directories)
        closeTabsForPath(&tab_mgr, confirm_dialog.target_path, confirm_dialog.target_is_dir);
        syncPaneToActiveTab(&pane_mgr, &tab_mgr);
        confirm_dialog.active = false;
        mode = .normal;
    } else if (ke.keysym == window_mod.XK_Return) {
        if (confirm_dialog.selected_yes) {
            file_tree.deleteEntry(confirm_dialog.target_path, confirm_dialog.target_is_dir) catch |err| {
                status_message = @errorName(err);
                status_message_time = std.time.milliTimestamp();
            };
            closeTabsForPath(&tab_mgr, confirm_dialog.target_path, confirm_dialog.target_is_dir);
            syncPaneToActiveTab(&pane_mgr, &tab_mgr);
        }
        confirm_dialog.active = false;
        mode = .normal;
    } else if (ke.keysym == window_mod.XK_Tab or ke.keysym == window_mod.XK_Left or ke.keysym == window_mod.XK_Right) {
        confirm_dialog.selected_yes = !confirm_dialog.selected_yes;
    }
    markAllPanesDirty(&pane_mgr);
    continue;
}
```

- [ ] **Step 4: Add closeTabsForPath helper**

```zig
fn closeTabsForPath(tab_mgr: *TabManager, path: []const u8, is_dir: bool) void {
    // Close tabs matching path, or (for directories) tabs with path prefix
    var i: usize = 0;
    while (i < tab_mgr.tabs.items.len) {
        const tab_path = tab_mgr.tabs.items[i].file_path orelse {
            i += 1;
            continue;
        };
        const should_close = if (is_dir)
            std.mem.startsWith(u8, tab_path, path)
        else
            std.mem.eql(u8, tab_path, path);
        if (should_close) {
            tab_mgr.closeTab(i);
            // Don't increment i — closeTab shifts items left
        } else {
            i += 1;
        }
    }
}
```

- [ ] **Step 5: Add F2 and Delete keyboard shortcuts for file tree**

In the normal mode keyboard handler, when file_tree is visible and has focus (no terminal focus, no overlay), add:

```zig
// F2 = rename selected file tree entry
if (ke.keysym == window_mod.XK_F2 and file_tree.visible and !terminal.focused and mode == .normal) {
    if (file_tree.entries.items.len > 0) {
        // Simulate tree_rename action
        ctx_menu.tree_entry_index = file_tree.selected;
        executeMenuAction(.tree_rename, editor, &win, &lsp_client, &lsp_needs_sync, &mode, &overlay, &filtered_display, allocator, &file_tree, &tab_mgr, &pane_mgr, &font, git_info, &ctx_menu, &confirm_dialog, &confirm_msg_buf, &status_message, &status_message_time);
        markAllPanesDirty(&pane_mgr);
        continue;
    }
}
// Delete = delete selected file tree entry
if (ke.keysym == window_mod.XK_Delete and file_tree.visible and !terminal.focused and mode == .normal) {
    if (file_tree.entries.items.len > 0) {
        ctx_menu.tree_entry_index = file_tree.selected;
        executeMenuAction(.tree_delete, editor, &win, &lsp_client, &lsp_needs_sync, &mode, &overlay, &filtered_display, allocator, &file_tree, &tab_mgr, &pane_mgr, &font, git_info, &ctx_menu, &confirm_dialog, &confirm_msg_buf, &status_message, &status_message_time);
        markAllPanesDirty(&pane_mgr);
        continue;
    }
}
```

Note: F2 and Delete in normal mode with file tree visible. These should only trigger when the file tree is the likely focus target (cursor is in file tree area). The executor should check if there's an existing `file_tree_focused` concept or use the heuristic `file_tree.visible and mouse was last in file tree area`. A simpler approach: only enable when `file_tree.hover_entry != null` or the user just clicked in the file tree.

- [ ] **Step 6: Add renderInlineInput and renderConfirmDialog to renderFrame**

In `renderFrame`, add after file tree render and before/after context menu render:

```zig
file_tree.renderInlineInput(&renderer, font, tab_bar_h);
// ... (existing context menu render) ...
Overlay.renderConfirmDialog(&renderer, font, confirm_dialog);
```

Pass `confirm_dialog` as a parameter to `renderFrame` (add `confirm_dialog: *const Overlay.ConfirmDialogState` to the signature).

- [ ] **Step 7: Add status message rendering**

Add logic: if `status_message != null`, check elapsed time. If < 3000ms, render message in status bar in peach color (0xfab387). If >= 3000ms, set `status_message = null`. The cursor blink timerfd (500ms) ensures periodic renders to clear the message.

This can be done in `renderFrame` or in `view_render.zig`'s `renderStatusBar`. Simplest: in `renderFrame`, draw the message over the status bar area after all other rendering.

- [ ] **Step 8: Build and test full flow**

```bash
cd ~/zz && zig build && ./zig-out/bin/zz .
```

Test each operation:
1. **New File**: Ctrl+B → right-click folder → New File → type "test.txt" → Enter → file created, opened in tab
2. **New Folder**: Right-click → New Folder → type "mydir" → Enter → folder created
3. **Rename**: Right-click file → Rename → edit name → Enter → file renamed, tab updated
4. **Rename with Japanese chars**: Type UTF-8 filename → works correctly
5. **Delete file**: Right-click → Delete → dialog → Yes → deleted, tab closed
6. **Delete directory**: Right-click folder → Delete → "and its contents?" → Yes → deleted, child file tabs closed
7. **Copy Path / Copy Relative Path**: Right-click → Copy → paste elsewhere
8. **Cancel**: Escape cancels inline input and dialog
9. **Root guard**: Right-click root dir → Delete/Rename → no-op
10. **F2 shortcut**: Select file in tree → F2 → rename input appears
11. **Delete shortcut**: Select file → Delete key → confirm dialog
12. **Error handling**: Try creating file that already exists → status bar shows error for 3s
13. **Editor right-click**: Still works as before with shortcut hints

- [ ] **Step 9: Commit**

```bash
cd ~/zz && git add src/main.zig src/ui/file_tree.zig src/ui/overlay.zig && git commit -m "feat: wire file tree CRUD, confirm dialog, inline input, status messages"
```

---

### Task 6: Run existing tests and tag

- [ ] **Step 1: Run tests**

```bash
cd ~/zz && zig build test
```

Expected: All existing tests pass.

- [ ] **Step 2: Release build check**

```bash
cd ~/zz && zig build -Doptimize=ReleaseFast
```

Expected: Compiles without errors.

- [ ] **Step 3: Tag milestone**

```bash
cd ~/zz && git tag v0.1.0-phase4-crud -m "Phase 4: Context menu & file tree CRUD"
```

---

## File Summary

| File | Changes |
|---|---|
| `src/ui/overlay.zig` | `MenuAction`, `MenuItem`, `ContextMenuState`, `ConfirmDialogState` (inside Overlay struct), refactored `renderContextMenu` with shortcut/disabled support, `renderConfirmDialog`, `dimScreen` made pub |
| `src/ui/file_tree.zig` | `InlineInput` struct (UTF-8 aware), `renderInlineInput`, `refreshDirectory` (collapse+expand pattern), `createNewFile` (.exclusive=true + close), `createNewFolder`, `renameEntry`, `deleteEntry` |
| `src/main.zig` | `context_menu`/`tree_input`/`confirm_dialog` in EditorMode, `ContextMenuState` replaces ad-hoc vars, typed `editor_menu_items`/`file_tree_menu_items`, `executeMenuAction` typed dispatch, right-click area routing, tree_input keyboard+text handling, confirm_dialog handling, `closeTabsForPath` (recursive for dirs), F2/Delete shortcuts, status message state |
| `src/editor/view_render.zig` | Transient status bar message rendering (peach color, 3s timeout) |
