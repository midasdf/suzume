# zz — Context Menu & File Tree CRUD Design Spec

**Date**: 2026-04-02
**Status**: Approved
**Project**: zz (Zig code editor)
**Target**: x86_64 Linux

## Motivation

zz has a functional file tree sidebar and an existing editor context menu (Cut/Copy/Paste/Select All/Select Word/Go to Definition/Find References/Command Palette). However, the file tree lacks CRUD operations — users must switch to an external terminal to create, rename, or delete files. The file tree also has no right-click menu. This spec adds file tree CRUD with context menu support, and refactors the existing ad-hoc context menu state into a typed, reusable component.

## Goals

- File/folder create, rename, delete from file tree
- Right-click context menu on file tree
- Copy path to clipboard from file tree
- Inline text input in file tree for naming operations
- Refactor existing editor context menu to share typed MenuItem infrastructure
- Lightweight: extend existing overlay.zig and file_tree.zig

## Non-Goals

- Drag-and-drop file moving
- Multi-file selection and bulk operations
- Trash/recycle bin (direct delete only)
- Reveal in File Manager (xdg-open, deferred)
- Nested/cascading submenus

## Existing Context Menu State

The editor already has a working context menu implemented with ad-hoc state in `main.zig`:

- `context_menu_active: bool` — whether menu is visible
- `context_menu_x/y: i16` — pixel position
- `context_menu_selected: i32` — selected item index
- `context_menu_items` — comptime string array of item labels
- `executeContextMenuItem()` — string-matching dispatch to actions
- `overlay.renderContextMenu()` — rendering with hover, separators, keyboard nav

This implementation works but cannot support file tree menus (different items, different actions). This spec replaces the string-based system with a typed `MenuItem`/`MenuAction` model that both editor and file tree menus use.

## Design

### 1. Context Menu Component Refactor

Replace the existing ad-hoc context menu with a typed, reusable component in `overlay.zig`.

**Migration from current implementation:**
1. Remove `context_menu_active`, `context_menu_x`, `context_menu_y`, `context_menu_selected` local variables from `main.zig`
2. Remove `context_menu_items` comptime string array and `executeContextMenuItem()` string-matching function
3. Replace with `ContextMenuState` struct (below) and `MenuAction` enum dispatch
4. Update all ~20 references to `context_menu_active` in main.zig to use mode-based checks

**Data model:**

```zig
const MenuAction = enum {
    // File tree actions
    tree_new_file,
    tree_new_folder,
    tree_rename,
    tree_delete,
    tree_copy_path,
    tree_copy_relative_path,
    // Editor actions (replaces existing string-matched items)
    ed_cut,
    ed_copy,
    ed_paste,
    ed_select_all,
    ed_select_word,
    ed_goto_definition,
    ed_find_references,
    ed_command_palette,
};

const MenuItem = struct {
    label: []const u8,        // Display text, e.g. "New File"
    shortcut: ?[]const u8,    // Right-aligned hint, e.g. "F2"
    action: MenuAction,       // Typed action enum
    separator_after: bool,    // Draw 1px separator below this item
    enabled: bool,            // false = grayed out, not selectable
};

const ContextMenuState = struct {
    items: []const MenuItem,
    selected: i32,
    x: i16,
    y: i16,
    source: enum { editor, file_tree },
    /// For file_tree source: which entry was right-clicked
    tree_entry_index: ?usize,
};
```

**Rendering:**
- Same visual style as existing `renderContextMenu` (mantle background, 1px border, hover highlight)
- Added: shortcut text right-aligned in overlay2 color (dimmed)
- Added: disabled items rendered in overlay0 color, skipped by hover/keyboard
- Width: auto-sized to widest (label + shortcut + padding), min 180px

**Input handling:**
- Unchanged from existing: mouse hover, click, Up/Down, Enter, Escape, click-outside
- Added: skip disabled items in keyboard navigation

### 2. File Tree CRUD Operations

#### 2.1 New File / New Folder

**Trigger:** Right-click menu "New File" / "New Folder".

**Flow:**
1. Determine target directory: selected entry if directory, parent of selected file, or project root if nothing selected
2. Enter `tree_input` mode
3. Show inline input field at the insertion position (below target directory, indented)
4. User types filename → Enter to confirm
5. For files: `const file = try std.fs.cwd().createFile(relative_path, .{}); file.close();` (close immediately — we only need the file to exist, it will be opened separately in a tab). For folders: `try std.fs.cwd().makeDir(relative_path)`
6. On success: targeted refresh of parent directory in file tree (preserve expand/collapse state of other directories), if file → open in new tab
7. On error (exists, permission denied): show error in status bar message area, keep input open for retry or Esc
8. Escape cancels, removes input field

#### 2.2 Rename

**Trigger:** Right-click menu "Rename" or F2 key when file tree has a selected entry.

**Flow:**
1. Enter `tree_input` mode
2. Replace selected entry's display with inline input field
3. Pre-fill with current filename. For extension detection: find last `.` that is not position 0 (so `.gitignore` selects the whole name, `file.test.zig` selects `file.test`)
4. Enter confirms → `std.fs.cwd().rename(old_relative_path, new_relative_path)`
5. On success: targeted refresh of parent directory in file tree
6. If renamed file is open in any tab (check all panes): update each tab's `file_path`
7. If LSP active and renamed file was open: send `textDocument/didClose` for old URI, then `textDocument/didOpen` for new URI with current buffer content
8. On error: show in status bar, revert display
9. Escape cancels

#### 2.3 Delete

**Trigger:** Right-click menu "Delete" or Delete key when file tree has a selected entry.

**Guard:** If the selected entry is the project root directory, ignore (no-op). Root is not deletable.

**Flow:**
1. Enter `confirm_dialog` mode
2. Show confirmation overlay: "Delete «filename»?" for files, "Delete «dirname» and its contents?" for directories
3. Two buttons: [Yes] [No], No is default focus
4. Yes → `std.fs.cwd().deleteFile(relative_path)` for files, `std.fs.cwd().deleteTree(relative_path)` for directories
5. On success: targeted refresh of parent directory in file tree, close any open tabs for deleted files (across all panes)
6. On error: show in status bar
7. No or Escape cancels

#### 2.4 Copy Path

**Trigger:** Right-click menu only.

**Action:**
- "Copy Path": allocate new `[]u8` with absolute path, pass ownership to `window.setClipboard()`
- "Copy Relative Path": allocate new `[]u8` with relative path, pass ownership to `window.setClipboard()`

Note: `setClipboard` takes ownership of the allocated slice and frees the previous content. Do not pass a reference to `Entry.path` directly.

### 3. Inline Input Field

A text input rendered within the file tree area for naming operations.

**State (in file_tree.zig):**
```zig
const InlineInput = struct {
    buffer: [256]u8,          // Input text buffer (UTF-8)
    len: usize,               // Current text length in bytes
    cursor: usize,            // Cursor position (byte offset, always at codepoint boundary)
    mode: enum { new_file, new_folder, rename },
    target_dir: []const u8,   // Directory where file will be created
    original_name: ?[]const u8, // For rename: original filename
};
```

**Rendering:**
- Occupies one row in file tree at the appropriate indent level
- Background: surface1 color (distinct from normal entries)
- Text cursor: 2px beam, same as editor cursor
- File/folder icon prefix to indicate type being created

**Input (UTF-8 aware):**
- Character input: append UTF-8 encoded bytes at cursor position
- Backspace: delete one codepoint before cursor (use `std.unicode.utf8ByteSequenceLength` on the byte before cursor to find codepoint start)
- Delete: delete one codepoint after cursor
- Left/Right arrow: move cursor by one codepoint (not byte), using UTF-8 sequence length detection
- Home/End for start/end
- Enter confirms
- Escape cancels
- No multi-line, no selection (simple single-line input)

**Validation:**
- Empty name → ignore Enter (no-op)
- Name containing `/` or null bytes → reject, flash status bar warning
- Existing name at target path → status bar error "File already exists"

### 4. Confirmation Dialog

Simple modal for delete confirmation.

**Rendering:**
- Centered overlay (similar to existing overlay style)
- Message text + two buttons [Yes] [No]
- Screen dimming (60% dark overlay, same as command palette)
- No selected by default (safety)

**Input:**
- Tab / Left/Right to switch between Yes/No
- Enter executes focused button
- Escape = No
- Y key = Yes, N key = No (accelerators)

### 5. File Tree Refresh Strategy

CRUD operations must not destroy the tree's expand/collapse state.

**Targeted refresh:**
- After create/rename/delete, only re-scan the affected parent directory
- Preserve the `expanded` flag of all sibling directories
- Re-sort entries in the refreshed directory (directories first, alphabetical)
- If a new file was created, set it as the selected entry

**Implementation:** Add a `refreshDirectory(dir_path)` method to `FileTree` that re-reads only the entries under the specified directory, replacing its children while preserving other subtrees.

### 6. Right-Click Area Routing

**Critical:** The existing right-click handler in `main.zig` (mouse_press, button == .right) assumes all right-clicks are in the editor area. Must add file tree area guard.

**In the mouse_press handler for button == .right:**
1. Check `file_tree.visible and mouse_x < file_tree.sidebarWidth(&font)` FIRST
2. If true → determine which file tree entry was clicked (row math from y coordinate + scroll offset), populate file tree menu items, open context menu with `source = .file_tree`
3. If false → fall through to existing editor right-click handling (move cursor to position, populate editor menu items, open context menu with `source = .editor`)

This mirrors the existing left-click area guard pattern already used for file tree clicks.

### 7. Status Bar Messages

CRUD operations need to display error/success messages. Add a simple transient message mechanism:

**State (in main.zig or view.zig):**
```zig
status_message: ?[]const u8 = null,
status_message_timer: ?i64 = null,  // timestamp when message was set
```

- Set message on error: `status_message = "File already exists"`
- Clear after 3 seconds (check in render loop against timerfd or frame count)
- Render in status bar area, right-aligned or replacing the center section temporarily
- If no message, status bar shows normal content

### 8. Mode Additions to main.zig

Add to the existing mode enum:

```
tree_input     — inline text input in file tree (new/rename)
confirm_dialog — delete confirmation overlay
```

Note: `context_menu` mode replaces the existing `context_menu_active` bool. This is a refactor, not an addition. All existing checks of `context_menu_active` must be migrated to mode-based checks.

**Mode transitions:**
- Right-click in file tree → set mode `context_menu` (with file tree items)
- Right-click in editor → set mode `context_menu` (with editor items, same as current behavior)
- Menu action tree_new_file/tree_new_folder/tree_rename → `tree_input`
- Menu action tree_delete → `confirm_dialog`
- Enter/Escape in `tree_input` → `normal`
- Yes/No/Escape in `confirm_dialog` → `normal`
- Escape/click-outside in `context_menu` → `normal`

## File Changes

| File | Change |
|------|--------|
| `src/ui/overlay.zig` | Refactor `renderContextMenu` to use `MenuItem` slice, add shortcut/disabled rendering, add confirmation dialog render |
| `src/ui/file_tree.zig` | Add `InlineInput` state, CRUD operations (create/rename/delete/copy path), `refreshDirectory()`, menu item generation, right-click entry detection |
| `src/main.zig` | Replace `context_menu_active/x/y/selected` with `ContextMenuState`, add `tree_input`/`confirm_dialog` modes, add right-click area routing, add `MenuAction` dispatch, add status bar message state |
| `src/editor/view.zig` | Minor: status bar message rendering |

No new files created.

## Edge Cases

- **Rename open file**: Update tab path in ALL panes (iterate pane tree). Buffer content unchanged. LSP: didClose old + didOpen new.
- **Delete open file**: Close tab in all panes, discard unsaved changes (confirmed by dialog).
- **Create in read-only directory**: Status bar error, input stays open for retry or Esc.
- **Very long filename**: Input buffer 256 bytes, sufficient for any reasonable filename.
- **Concurrent external changes**: File tree refresh on CRUD ops only. No filesystem watcher (consistent with current design).
- **Delete non-empty directory**: `deleteTree` handles recursion. Dialog says "and its contents".
- **Delete project root**: Blocked — no-op guard.
- **Dotfiles rename**: `.gitignore` → entire name selected (no extension split at leading dot).
- **Multi-dot filenames**: `file.test.zig` → `file.test` selected, `.zig` treated as extension (last dot boundary, unless position 0).
- **No selection in file tree**: New File/Folder targets project root directory.
- **Copy path allocation**: Caller allocates new `[]u8` for clipboard. Must not pass borrowed `Entry.path`.

## Implementation Order

1. Context menu refactor (overlay.zig + main.zig) — migrate `context_menu_active` bool to typed `ContextMenuState`, `MenuItem`/`MenuAction` model. Preserve existing editor menu behavior.
2. Right-click area routing (main.zig) — file tree vs editor guard
3. File tree CRUD operations (file_tree.zig) — fs operations + inline input + targeted refresh
4. File tree right-click menu (main.zig + file_tree.zig) — connect menu to CRUD
5. Confirmation dialog (overlay.zig + main.zig) — delete safety gate
6. Status bar messages (main.zig + view.zig) — transient error/success display
7. End-to-end testing
