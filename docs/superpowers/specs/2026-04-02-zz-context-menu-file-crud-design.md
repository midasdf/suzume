# zz — Context Menu & File Tree CRUD Design Spec

**Date**: 2026-04-02
**Status**: Approved
**Project**: zz (Zig code editor)
**Target**: x86_64 Linux

## Motivation

zz has functional file tree and editor views, but lacks standard mouse-driven operations. Users cannot create, rename, or delete files from the file tree, and right-click produces no context menu. This forces users to switch to an external terminal for basic file management. Adding context menus and file tree CRUD brings zz to the usability baseline expected of a modern code editor.

## Goals

- Right-click context menus in file tree and editor
- File/folder create, rename, delete from file tree
- Copy path to clipboard from file tree
- Inline text input in file tree for naming operations
- Lightweight: reuse existing overlay.zig infrastructure

## Non-Goals

- Drag-and-drop file moving
- Multi-file selection and bulk operations
- Trash/recycle bin (direct delete only)
- Reveal in File Manager (xdg-open, deferred)
- Nested/cascading submenus

## Design

### 1. Context Menu Component

Extend the existing context menu rendering in `overlay.zig`.

**Data model:**

```zig
const MenuItem = struct {
    label: []const u8,        // Display text, e.g. "New File"
    shortcut: ?[]const u8,    // Right-aligned hint, e.g. "F2"
    action: MenuAction,       // Enum identifying the action
    separator_after: bool,    // Draw 1px separator below this item
    enabled: bool,            // false = grayed out, not selectable
};

const MenuAction = enum {
    // File tree actions
    new_file,
    new_folder,
    rename,
    delete,
    copy_path,
    copy_relative_path,
    // Editor actions
    cut,
    copy,
    paste,
    goto_definition,
    rename_symbol,
    select_all,
};
```

**Rendering:**
- Background: mantle color + 1px border (surface0)
- Hover: surface0 highlight on active item
- Shortcut text: right-aligned in overlay2 color (dimmed)
- Separator: 1px horizontal line in surface0 color
- Disabled items: text in overlay0 color, not hoverable
- Width: auto-sized to widest label + shortcut + padding (min 180px)
- Position: at mouse click coordinates, clamped to stay within window bounds (flip up/left if near edge)

**Input handling:**
- Mouse hover selects item, click executes
- Up/Down arrow keys navigate (skip separators and disabled items)
- Enter executes selected item
- Escape or click outside dismisses
- Menu dismissed after any action executes

**Mode integration:**
- Add `context_menu` to the editor mode enum in `main.zig`
- While in `context_menu` mode, all input routes to menu handler
- Menu stores: items slice, selected index, pixel position, source context (which file tree entry or editor position triggered it)

### 2. File Tree CRUD Operations

#### 2.1 New File / New Folder

**Trigger:** Right-click menu "New File" / "New Folder", or keyboard shortcut (N for file, Shift+N for folder when file tree focused).

**Flow:**
1. Determine target directory (selected entry if directory, or parent of selected file)
2. Enter `tree_input` mode
3. Show inline input field at the insertion position (below target directory, indented)
4. User types filename → Enter to confirm
5. Call `std.fs.cwd().createFile()` or `std.fs.cwd().makeDir()` with full path
6. On success: refresh file tree, if file → open in new tab
7. On error (exists, permission denied): show error in status bar, keep input open
8. Escape cancels, removes input field

#### 2.2 Rename

**Trigger:** Right-click menu "Rename" or F2 key when file tree focused.

**Flow:**
1. Enter `tree_input` mode
2. Replace selected entry's display with inline input field
3. Pre-fill with current filename, select name portion (exclude extension)
4. Enter confirms → `std.fs.rename()` old path to new path
5. On success: refresh file tree
6. If renamed file is open in a tab: update tab's file_path
7. If LSP active: no explicit notification needed (LSP tracks by URI, file reopen handles it)
8. On error: show in status bar, revert display
9. Escape cancels

#### 2.3 Delete

**Trigger:** Right-click menu "Delete" or Delete key when file tree focused.

**Flow:**
1. Enter `confirm_dialog` mode
2. Show confirmation overlay: "Delete «filename»?" or "Delete «dirname» and its contents?"
3. Two buttons: [Yes] [No], No is default focus
4. Yes → `std.fs.cwd().deleteFile()` for files, `std.fs.cwd().deleteTree()` for directories
5. On success: refresh file tree, close any open tabs for deleted files
6. On error: show in status bar
7. No or Escape cancels

#### 2.4 Copy Path

**Trigger:** Right-click menu only.

**Action:**
- "Copy Path": set X11 CLIPBOARD selection to absolute path
- "Copy Relative Path": set CLIPBOARD to path relative to working directory

Uses existing clipboard infrastructure in `window.zig`.

### 3. Inline Input Field

A text input rendered within the file tree area for naming operations.

**State (in file_tree.zig):**
```zig
const InlineInput = struct {
    buffer: [256]u8,          // Input text buffer
    len: usize,               // Current text length
    cursor: usize,            // Cursor position (byte offset)
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

**Input:**
- Character input appends to buffer
- Backspace/Delete for editing
- Left/Right arrow for cursor movement
- Home/End for start/end
- Enter confirms
- Escape cancels
- No multi-line, no selection (simple single-line input)

**Validation:**
- Empty name → ignore Enter (no-op)
- Name containing `/` or null bytes → reject, flash status bar warning
- Existing name at target path → status bar error "File already exists"

### 4. Editor Context Menu

**Menu items:**

| Item | Shortcut | Enabled when | Action |
|------|----------|-------------|--------|
| Cut | Ctrl+X | Selection exists | clipboard_cut |
| Copy | Ctrl+C | Selection exists | clipboard_copy |
| Paste | Ctrl+V | Always | clipboard_paste |
| *(separator)* | | | |
| Go to Definition | F12 | LSP active | goto_definition |
| Rename Symbol | F2 | LSP active | rename_symbol |
| *(separator)* | | | |
| Select All | Ctrl+A | Always | select_all |

**Behavior:**
- Right-click in editor area → move cursor to click position → show menu
- Menu items map to existing command functions (no new logic needed)
- LSP-dependent items check `lsp_client != null` for enabled state
- Selection-dependent items check `hasSelection()` for enabled state

### 5. Confirmation Dialog

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

### 6. Mode Additions to main.zig

Add to the existing mode enum:

```
context_menu   — right-click menu visible, input routes to menu
tree_input     — inline text input in file tree (new/rename)
confirm_dialog — delete confirmation overlay
```

**Mode transitions:**
- Right-click in file tree → `context_menu` (with file tree items)
- Right-click in editor → `context_menu` (with editor items)
- Menu action "New File"/"New Folder"/"Rename" → `tree_input`
- Menu action "Delete" → `confirm_dialog`
- Enter/Escape in `tree_input` → `normal`
- Yes/No/Escape in `confirm_dialog` → `normal`
- Escape/click-outside in `context_menu` → `normal`

## File Changes

| File | Change |
|------|--------|
| `src/ui/overlay.zig` | Extend context menu rendering, add confirmation dialog |
| `src/ui/file_tree.zig` | Add InlineInput state, CRUD operations, menu item generation |
| `src/main.zig` | Add modes, input routing, action dispatch, right-click handling |
| `src/editor/view.zig` | Editor right-click → menu action connection |

No new files created.

## Edge Cases

- **Rename open file**: Update tab path. Buffer content unchanged (same fd).
- **Delete open file**: Close tab, discard unsaved changes (confirmed by delete dialog).
- **Create in read-only directory**: Status bar error, input stays open for retry or Esc.
- **Very long filename**: Input buffer 256 bytes, sufficient for any reasonable name.
- **Concurrent external changes**: File tree refresh on CRUD ops only. No filesystem watcher (consistent with current design).
- **Delete non-empty directory**: `deleteTree` handles recursion. Confirmation dialog warns about contents.

## Implementation Order

1. Context menu component (overlay.zig) — generic, reusable
2. File tree CRUD operations (file_tree.zig) — fs operations + inline input
3. File tree right-click menu (main.zig + file_tree.zig) — connect menu to CRUD
4. Editor right-click menu (main.zig + view.zig) — connect menu to existing commands
5. Confirmation dialog (overlay.zig + main.zig) — delete safety gate
6. End-to-end testing
