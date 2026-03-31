# zz — Lightweight Code Editor Design Spec

**Date**: 2026-03-31
**Status**: Approved
**Language**: Zig
**Target**: x86_64 Linux

## Motivation

Existing editors are either too heavy (VS Code, Zed — RAM hungry, bundled AI, telemetry) or lack GUI affordances (Neovim, Helix — no mouse-native UX, no proportional font rendering). zz fills the gap: a fast, opaque-free code editor with zero telemetry, zero AI, and minimal dependencies.

## Goals

- **Fastest startup possible**: mmap file, render immediately
- **Minimal memory**: target <50MB RSS for typical projects
- **Zero telemetry**: no network calls except LSP servers (local processes)
- **Binary <2MB**: excluding tree-sitter grammar .so files
- **Idle CPU 0%**: event-driven rendering, no 60fps loop

## Non-Goals

- Cross-platform (Linux x86_64 only)
- Plugin/extension system
- Collaborative editing
- AI features
- Integrated debugger (Phase 1-6 scope)

## Architecture Overview

### Rendering: xcb + SHM Direct

Same approach as zt. Double-buffered SHM image, dirty region tracking at row granularity.

- All text rendered on a monospace grid (col, row) with pixel-level padding for IDE aesthetics
- Font rendering via freetype with glyph cache (ASCII pre-rendered at startup)
- No GPU, no OpenGL — pure CPU blitting to SHM buffer

### Event Loop: epoll

Single-threaded, epoll-based multiplexing:

| fd | Source |
|---|---|
| xcb_fd | Window events (key, mouse, expose, resize) |
| timerfd | Cursor blink, auto-save |
| lsp_stdout_fd | LSP server responses (one per active server) |

No threads. No async runtime. Just epoll.

### Draw Flow

```
Edit operation → Piece Table update → Identify affected rows → Mark dirty
→ Re-render dirty rows only (glyph cache lookup) → xcb_shm_put_image (dirty rect)
```

## Component Design

### 1. Text Buffer: Piece Table

```
original_buffer: []const u8   // File content at load time (immutable, mmap'd)
add_buffer: ArrayList(u8)     // All insertions append here (append-only)
pieces: ArrayList(Piece)      // Ordered sequence describing document content

Piece = struct {
    source: enum { original, add },
    start: u32,
    len: u32,
    newline_count: u32,       // Cached for fast line-to-offset lookup
};
```

**Properties**:
- File open = mmap + 1 piece. Instant startup regardless of file size.
- All edits append to add_buffer + split/insert pieces. Original text never modified.
- Line number to byte offset: binary search over cumulative newline_count.
- u32 addressing supports files up to 4GB. No artificial limit imposed.
- **Encoding**: UTF-8 only. Non-UTF-8 files opened as raw bytes with U+FFFD replacement rendering.

**Undo/Redo**:
- Transaction-based: each user action (keystroke, paste, delete) creates an `UndoEntry` containing a delta (pieces added/removed/split).
- Consecutive character insertions at the same cursor are coalesced into a single transaction (broken by cursor movement, deletion, or 1-second pause).
- Multi-cursor: all cursor edits within a single action = one transaction.
- Undo stack is a `ArrayList(UndoEntry)`. Redo stack cleared on new edit (no branching).
- Memory: each entry stores only the piece diff, not a full snapshot. Bounded by undo history limit (default 1000 transactions).

**Multi-cursor**:
- Cursors stored as `ArrayList(Selection)` where `Selection = { anchor: u32, head: u32 }`.
- Batch-apply edits from last cursor to first (back-to-front offset adjustment).

### 2. Rendering Pipeline

**Grid layout**:
```
cell_width  = font max advance width (monospace)
cell_height = ascent + descent + line_gap + padding
```

**Pixel padding for IDE aesthetics**:
- Editor left margin: 8px (between line numbers and code)
- Line number area: right-aligned, subtle background color
- Tab bar: cell_height + 4px vertical padding
- Status bar: fixed bottom, background-separated

**Glyph cache**:
```zig
const GlyphCache = struct {
    cache: AutoHashMap(u32, GlyphBitmap),

    const GlyphBitmap = struct {
        pixels: []const u8,   // 8-bit alpha
        width: u16,
        height: u16,
        bearing_x: i16,
        bearing_y: i16,
    };
};
```

- ASCII (0x20-0x7E) pre-rendered at startup — covers 95%+ of code.
- CJK and other codepoints cached on demand.
- Freetype bindings reused from suzume. No harfbuzz needed — monospace glyphs require no complex shaping.

**Dirty tracking**:
```zig
row_dirty: []bool   // Dynamically allocated, resized on window resize
```

- Text edit → dirty affected rows
- Scroll → memmove SHM buffer, dirty only newly exposed rows
- Cursor move → dirty old and new cursor rows only

**Frame updates**: Event-driven only. No rendering when idle.

### 3. Tree-sitter Syntax Highlighting

Integrated via `@cImport` (C library).

**Incremental parsing**:
- Piece Table edit → generate `TSInputEdit` → `ts_tree_edit` + `ts_parser_parse`
- Only re-parses affected region. Fast even on large files.

**Read callback bridge**:

Tree-sitter's `TSInput` read callback signature:
```c
const char *(*read)(void *payload, uint32_t byte_index, TSPoint position, uint32_t *bytes_read);
```

The callback returns a pointer to contiguous memory and sets `bytes_read`. Since Piece Table is non-contiguous, the implementation returns data only up to the current piece boundary (short read). Tree-sitter re-invokes the callback for the next chunk automatically.

```zig
fn tsRead(payload: ?*anyopaque, byte_index: u32, _: TSPoint, bytes_read: *u32) [*c]const u8 {
    const buffer: *PieceTable = @ptrCast(payload);
    const slice = buffer.contiguousSliceAt(byte_index); // Returns slice within single piece
    bytes_read.* = @intCast(slice.len);
    return slice.ptr;
}
```

**Grammar management**:
```
zz/grammars/
├── tree-sitter-zig.so
├── tree-sitter-c.so
├── tree-sitter-python.so
├── tree-sitter-rust.so
├── tree-sitter-javascript.so
├── tree-sitter-toml.so
├── tree-sitter-json.so
└── queries/
    ├── zig/highlights.scm
    ├── c/highlights.scm
    └── ...
```

- Grammars loaded via `dlopen`. Add languages without recompiling zz.
- Highlight queries (.scm) as text files.
- Initial 7 languages: Zig, C, Python, Rust, JavaScript, TOML, JSON.
- Capture names (@keyword, @function, etc.) mapped to theme colors.

### 4. LSP Client

JSON-RPC over stdin/stdout with child processes.

**Language → server mapping** (user-configured):
```toml
[lsp.zig]
command = "zls"
[lsp.python]
command = "pylsp"
[lsp.c]
command = "clangd"
[lsp.rust]
command = "rust-analyzer"
```

**epoll integration**: LSP server stdout fd added to the main epoll set. No threads needed.

**Supported methods (priority order)**:

| Feature | LSP Method | UI |
|---|---|---|
| Diagnostics | `publishDiagnostics` | Underline + gutter mark |
| Go to definition | `textDocument/definition` | Ctrl+Click / F12 |
| Completion | `textDocument/completion` | Popup list at cursor |
| Hover | `textDocument/hover` | Tooltip at mouse |
| Symbol search | `workspace/symbol` | Integrated in fuzzy finder |
| Rename | `textDocument/rename` | F2 |

**Document sync**: `didOpen`, `didChange` (incremental), `didSave`. Content changes generated from Piece Table edits.

**LSP position encoding**: LSP uses line:character positions where character is UTF-16 code unit offset. Piece Table edits operate on byte offsets. The buffer maintains a line index (cumulative newline offsets) for byte-offset ↔ line:col conversion. UTF-8 byte offset → UTF-16 code unit offset requires scanning the line content — cached per line to avoid repeated conversion.

**JSON-RPC framing**: LSP messages use `Content-Length` header framing. A read buffer accumulates data from epoll reads and parses complete messages.

No auto-detection of servers — explicit configuration only. Transparent and predictable.

### 5. UI Components

**Screen layout**:
```
┌──────────────────────────────────────────┐
│ Tab bar  [main.zig] [buffer.zig] [x]     │
├──────────────────────────────────────────┤
│  1 │ const std = @import("std");         │
│  2 │ pub fn main() !void {               │
│  3 │     ...                             │
│    │                                     │
├──────────────────────────────────────────┤
│ master │ UTF-8 │ Zig │ zls │ 3:15       │
└──────────────────────────────────────────┘
```

**Command palette** (Ctrl+Shift+P):
- Overlay at top-center
- Fuzzy match all registered commands
- Commands defined as name + keybind + function pointer:
```zig
const Command = struct {
    name: []const u8,
    keybind: ?Keybind,
    execute: *const fn(*Editor) void,
};
```

**Fuzzy finder** (Ctrl+P):
- File search: recursive directory walk, .gitignore-aware
- Symbol search (Ctrl+Shift+O): via LSP `workspace/symbol`
- Same UI component, different input source
- Scoring: subsequence match + consecutive bonus + basename priority

**Split panes**:
- Vertical: Ctrl+\, Horizontal: Ctrl+Shift+\
- Binary tree layout:
```zig
const Pane = union(enum) {
    leaf: *EditorView,
    split: struct {
        direction: enum { horizontal, vertical },
        ratio: f32,
        children: [2]*Pane,
    },
};
```
- Drag border to resize. Double-click to reset 50:50.

**Status bar**:
- Left: Git branch name
- Center: encoding, language, LSP status
- Right: cursor position (line:col)

### 6. Input Handling

**Keybinds**: Comptime default table, overridable via config:
```zig
const default_keymap = comptime buildKeymap(.{
    .{ .ctrl, .s,               "file_save" },
    .{ .ctrl, .p,               "finder_files" },
    .{ .ctrl_shift, .p,         "command_palette" },
    .{ .ctrl, .g,               "goto_line" },
    .{ .ctrl, .d,               "select_next_occurrence" },
    .{ .ctrl, .backslash,       "split_vertical" },
    .{ .ctrl_shift, .backslash, "split_horizontal" },
    .{ .ctrl, .w,               "close_tab" },
    .{ .ctrl, .tab,             "next_tab" },
    .{ .f12, .none,             "goto_definition" },
    .{ .f2, .none,              "rename_symbol" },
    .{ .ctrl, .c,               "clipboard_copy" },
    .{ .ctrl, .x,               "clipboard_cut" },
    .{ .ctrl, .v,               "clipboard_paste" },
    .{ .ctrl, .z,               "undo" },
    .{ .ctrl_shift, .z,         "redo" },
    .{ .ctrl, .f,               "find" },
    .{ .ctrl, .h,               "find_replace" },
});
```

Context-dependent: different behavior during palette/completion/normal editing.

**Clipboard** (X11 selections, zt pattern):
- CLIPBOARD selection for Ctrl+C/X/V (explicit copy/paste)
- PRIMARY selection for mouse select-to-copy, middle-click-to-paste
- Target type: UTF8_STRING
- No size limit on paste buffer (dynamically allocated)

**XIM** (xcb-imdkit, zt pattern): fcitx5/mozc support. Preedit text rendered inline at cursor.

**Mouse**:
- Click: move cursor
- Double-click: select word
- Triple-click: select line
- Drag: range selection
- Ctrl+Click: go to definition (LSP)
- Alt+Click: add cursor
- Scroll wheel: 3 lines
- Split border drag: resize pane

**Multi-cursor**:
- Ctrl+D: select next occurrence of current selection
- Ctrl+Shift+L: select all occurrences
- Alt+Click: add cursor at position
- Esc: collapse to single cursor

### 7. Configuration

**Path**: `~/.config/zz/config.toml`

```toml
[editor]
font_family = "PlemolJP Console NF"
font_size = 14
tab_size = 4
insert_spaces = true
line_numbers = true
word_wrap = false
cursor_blink = true
auto_save_ms = 0

[theme]
name = "zz-dark"

[keymap]
"ctrl+shift+d" = "duplicate_line"

[lsp.zig]
command = "zls"
[lsp.python]
command = "pylsp"
```

**Themes**: `~/.config/zz/themes/` as TOML files:
```toml
[colors]
background = "#1e1e2e"
foreground = "#cdd6f4"
cursor = "#f5e0dc"
selection = "#45475a"
line_number = "#6c7086"
line_number_active = "#cdd6f4"
status_bar_bg = "#181825"
tab_active_bg = "#1e1e2e"
tab_inactive_bg = "#181825"

[syntax]
keyword = "#cba6f7"
function = "#89b4fa"
string = "#a6e3a1"
comment = "#6c7086"
type = "#f9e2af"
number = "#fab387"
operator = "#89dceb"
```

One built-in theme (Catppuccin Mocha-based dark), comptime embedded. Custom themes via TOML.

Tree-sitter capture names map directly to syntax section keys.

No hot-reload. Read once at startup. Simple.

## Dependencies

### External C Libraries

| Library | Purpose | Proven in |
|---|---|---|
| xcb, xcb-shm | Window, rendering | zt |
| xcb-xkb, xkbcommon, xkbcommon-x11 | Keyboard | zt |
| xcb-imdkit | Input method | zt |
| freetype2 | Font rendering | suzume |
| tree-sitter (libtree-sitter) | Syntax parsing | new |

### Zig Package Dependencies

None. All code is self-contained + C library bindings.

### Build

```zig
const exe = b.addExecutable(.{
    .name = "zz",
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});
exe.linkSystemLibrary("xcb");
exe.linkSystemLibrary("xcb-shm");
exe.linkSystemLibrary("xcb-xkb");
exe.linkSystemLibrary("xkbcommon");
exe.linkSystemLibrary("xkbcommon-x11");
exe.linkSystemLibrary("xcb-imdkit");
exe.linkSystemLibrary("freetype2");
exe.linkSystemLibrary("tree-sitter");
exe.linkLibC();
```

Tree-sitter grammars compiled as .so in build.zig or pre-built for dlopen.

**Targets**: Binary <2MB (release, excluding grammar .so). Clean build <3s.

## Source Structure

```
zz/
├── build.zig
├── build.zig.zon
├── src/
│   ├── main.zig             # Entry point, epoll event loop
│   ├── editor/
│   │   ├── buffer.zig       # Piece Table
│   │   ├── cursor.zig       # Cursor & selection (multi-cursor)
│   │   ├── view.zig         # Editor view (scroll, viewport)
│   │   └── highlight.zig    # Tree-sitter integration
│   ├── lsp/
│   │   ├── client.zig       # LSP client (JSON-RPC, epoll)
│   │   └── protocol.zig     # LSP protocol type definitions
│   ├── ui/
│   │   ├── window.zig       # xcb window management
│   │   ├── render.zig       # SHM buffer drawing, dirty regions
│   │   ├── font.zig         # Freetype glyph cache
│   │   ├── layout.zig       # Pane split layout (binary tree)
│   │   ├── palette.zig      # Command palette
│   │   ├── finder.zig       # Fuzzy finder
│   │   └── theme.zig        # Color scheme
│   ├── input/
│   │   ├── keymap.zig       # Keybind definitions & dispatch
│   │   └── ime.zig          # XIM/fcitx5
│   └── core/
│       ├── config.zig       # Config file loading (TOML)
│       └── commands.zig     # Command registry & execution
├── grammars/                 # Tree-sitter grammar .so + queries
│   ├── tree-sitter-zig.so
│   └── queries/
│       └── zig/highlights.scm
└── tests/
```

## Implementation Phases

### Phase 1: Minimal Editor (core)
- xcb window + SHM buffer + epoll event loop
- Freetype font loading + glyph cache
- Piece Table + basic editing (insert, delete, newline)
- Undo/redo (transaction-based)
- Cursor movement, scrolling, range selection
- Clipboard (CLIPBOARD + PRIMARY, zt pattern)
- XIM/fcitx5 input method (xcb-imdkit, zt pattern)
- Dirty region rendering
- File open/save (Ctrl+S, atomic write via temp+rename)
- **Milestone**: Single-file editor that works

### Phase 2: Syntax Highlighting & Polish
- Tree-sitter integration + incremental parsing
- Theme application (syntax + UI colors)
- Line numbers
- Status bar
- **Milestone**: Syntax-highlighted editor with visual polish

### Phase 3: Search & Navigation
- Command palette (Ctrl+Shift+P)
- Fuzzy finder (Ctrl+P file search)
- Text search/replace (Ctrl+F / Ctrl+H)
- Goto line (Ctrl+G)
- **Milestone**: Navigate freely between files

### Phase 4: LSP
- LSP client (JSON-RPC, epoll-integrated)
- Diagnostics display (error underlines)
- Completion popup
- Go to definition, hover
- **Milestone**: Practically usable as IDE

### Phase 5: Multi-cursor & Splits
- Multi-cursor (Ctrl+D, Alt+Click)
- Split panes (binary tree layout)
- Tab bar
- **Milestone**: Full-featured code editor

### Phase 6: Extensions (nice-to-have)
- File tree (sidebar)
- Built-in terminal (zt core reuse)
- Git integration (branch name via `.git/HEAD` read, diff gutter)
- **Milestone**: Complete IDE experience
