# zt Terminal Emulator Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a framebuffer-based terminal emulator in Zig that is faster than Ghostty and as simple as st, with comptime-embedded Japanese BDF font support.

**Architecture:** Single-threaded epoll event loop. VT parser feeds Cell Grid with dirty tracking. Backend-abstracted rendering (fbdev/X11) selected at comptime. Input is backend-native (evdev for fbdev, XCB for X11). PTY via raw syscalls, no libc.

**Tech Stack:** Zig 0.15.2, Linux epoll, evdev, XCB + SHM, BDF fonts

**Spec:** `docs/superpowers/specs/2026-03-17-zt-terminal-design.md`

**Quality gate:** After implementing code, run `coderabbit --prompt-only` and fix detected issues.

---

## File Map

| File | Responsibility |
|------|---------------|
| `zt/build.zig` | Build configuration, comptime font embedding, backend selection |
| `zt/build.zig.zon` | Package metadata |
| `zt/config.zig` | User config: colors, font path, keymap, backend choice |
| `zt/src/main.zig` | Entry point, epoll event loop, signal handling, lifecycle |
| `zt/src/term.zig` | Cell Grid, dirty bitmap, alternate screen, resize |
| `zt/src/vt.zig` | VT parser state machine, action dispatch |
| `zt/src/pty.zig` | PTY creation, child process, TIOCSWINSZ |
| `zt/src/input.zig` | Common keycode → VT sequence translation |
| `zt/src/font.zig` | BDF comptime parser, glyph storage, width detection |
| `zt/src/render.zig` | Cell → pixel rendering, cursor, attributes |
| `zt/src/backend/fbdev.zig` | /dev/fb0 mmap, evdev input, VT switching |
| `zt/src/backend/x11.zig` | XCB + SHM buffer, XCB key events, resize |

---

## Chunk 1: Project Skeleton + BDF Font Parser

### Task 1: Project Init

**Files:**
- Create: `zt/build.zig`
- Create: `zt/build.zig.zon`
- Create: `zt/config.zig`
- Create: `zt/src/main.zig`

- [ ] **Step 1: Create project directory and build.zig.zon**

```bash
mkdir -p ~/zt/src/backend ~/zt/fonts
```

```zig
// zt/build.zig.zon
.{
    .name = .@"zt",
    .version = "0.1.0",
    .fingerprint = 0x0,
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
        "config.zig",
    },
}
```

- [ ] **Step 2: Create build.zig**

```zig
// zt/build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Backend selection via -Dbackend=fbdev|x11
    const backend_opt = b.option([]const u8, "backend", "Rendering backend: fbdev or x11") orelse "fbdev";

    // config.zig as a module (cannot @import from build.zig directly)
    const config_mod = b.createModule(.{
        .root_source_file = b.path("config.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "zt",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("config", config_mod);

    // Link X11 libraries only for x11 backend
    if (std.mem.eql(u8, backend_opt, "x11")) {
        exe.linkSystemLibrary("xcb");
        exe.linkSystemLibrary("xcb-shm");
        exe.linkSystemLibrary("xcb-xkb");
        exe.linkLibC(); // needed for XCB
    }

    b.installArtifact(exe);

    // Tests
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.addImport("config", config_mod);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
```

- [ ] **Step 3: Create config.zig stub**

```zig
// zt/config.zig
pub const backend: Backend = .fbdev;

pub const Backend = enum {
    fbdev,
    x11,
};

// Colors (xterm-256color defaults)
pub const default_fg: u8 = 7; // white
pub const default_bg: u8 = 0; // black

// Font
pub const font_path = "fonts/default.bdf";
pub const font_width: u32 = 8;
pub const font_height: u32 = 16;

// Shell
pub const shell = "/bin/sh";
```

- [ ] **Step 4: Create main.zig stub**

```zig
// zt/src/main.zig
const std = @import("std");

pub fn main() !void {
    std.debug.print("zt: starting\n", .{});
}

test {
    _ = @import("font.zig");
}
```

Note: `config.zig` is registered as a module in `build.zig`, so source files import it as `@import("config")` (not `@import("../config.zig")`).

- [ ] **Step 5: Verify build**

Run: `cd ~/zt && zig build`
Expected: builds without error

- [ ] **Step 6: Commit**

```bash
cd ~/zt && git init && git add -A
git commit -m "feat: project skeleton with build system and config"
```

---

### Task 2: BDF Font Parser (comptime)

**Files:**
- Create: `zt/src/font.zig`
- Create: `zt/fonts/default.bdf` (minimal test font)

This is the most novel part of zt — parsing BDF at comptime so the binary has zero startup font cost.

- [ ] **Step 1: Create a minimal test BDF font**

Create `zt/fonts/test_minimal.bdf` with just 3 glyphs (space, 'A', 'B') for testing:

```bdf
STARTFONT 2.1
FONT -test-fixed-medium-r-normal--16-160-72-72-c-80-iso10646-1
SIZE 16 72 72
FONTBOUNDINGBOX 8 16 0 0
STARTPROPERTIES 2
FONT_ASCENT 14
FONT_DESCENT 2
ENDPROPERTIES
CHARS 3
STARTCHAR space
ENCODING 32
SWIDTH 500 0
DWIDTH 8 0
BBX 8 16 0 0
BITMAP
00
00
00
00
00
00
00
00
00
00
00
00
00
00
00
00
ENDCHAR
STARTCHAR A
ENCODING 65
SWIDTH 500 0
DWIDTH 8 0
BBX 8 16 0 0
BITMAP
00
00
18
24
42
42
42
7E
42
42
42
42
00
00
00
00
ENDCHAR
STARTCHAR B
ENCODING 66
SWIDTH 500 0
DWIDTH 8 0
BBX 8 16 0 0
BITMAP
00
00
7C
42
42
42
7C
42
42
42
42
7C
00
00
00
00
ENDCHAR
ENDFONT
```

- [ ] **Step 2: Write failing tests for BDF parser**

```zig
// zt/src/font.zig
const std = @import("std");

pub const Glyph = struct {
    codepoint: u21,
    width: u32, // pixel width (8 for half-width, 16 for full-width)
    height: u32,
    bitmap: []const u8, // 1 bit per pixel, row-major, packed bytes
};

pub fn Font(comptime bdf_data: []const u8) type {
    _ = bdf_data;
    return struct {
        pub fn getGlyph(codepoint: u21) ?Glyph {
            _ = codepoint;
            return null;
        }
    };
}

const testing = std.testing;
const test_font_data = @embedFile("../fonts/test_minimal.bdf");

test "BDF parser: parse glyph count" {
    const F = Font(test_font_data);
    // 'A' should exist
    const glyph_a = F.getGlyph('A');
    try testing.expect(glyph_a != null);
}

test "BDF parser: glyph A has correct dimensions" {
    const F = Font(test_font_data);
    const glyph = F.getGlyph('A').?;
    try testing.expectEqual(@as(u32, 8), glyph.width);
    try testing.expectEqual(@as(u32, 16), glyph.height);
}

test "BDF parser: glyph A bitmap row 3 is 0x18" {
    const F = Font(test_font_data);
    const glyph = F.getGlyph('A').?;
    // Row 2 (0-indexed) should be 0x18
    try testing.expectEqual(@as(u8, 0x18), glyph.bitmap[2]);
}

test "BDF parser: space glyph is all zeros" {
    const F = Font(test_font_data);
    const glyph = F.getGlyph(' ').?;
    for (glyph.bitmap) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "BDF parser: missing glyph returns null" {
    const F = Font(test_font_data);
    // Codepoint 9999 should not exist in our 3-glyph test font
    try testing.expect(F.getGlyph(9999) == null);
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd ~/zt && zig build test 2>&1 | head -20`
Expected: FAIL (getGlyph returns null for everything)

- [ ] **Step 4: Implement BDF comptime parser**

The parser runs entirely at `comptime`. It iterates BDF lines, extracts ENCODING and BITMAP data, and builds a lookup table.

Key implementation details:
- Parse line-by-line at comptime using `std.mem.splitScalar`
- For each STARTCHAR..ENDCHAR block: extract ENCODING (codepoint), BBX (dimensions), BITMAP (hex rows)
- Store glyphs in a comptime-sorted array, binary search at runtime for lookup
- Hex row parsing: "7E" → 0x7E byte
- Double-width detection: BBX width > font_width means full-width CJK glyph
- Each glyph's bitmap is `[]const u8` with one byte per row (for 8px wide) or two bytes per row (for 16px wide)

```zig
pub fn Font(comptime bdf_data: []const u8) type {
    comptime {
        // 1. Count glyphs (count STARTCHAR lines)
        // 2. For each glyph, parse ENCODING, BBX, BITMAP
        // 3. Sort by codepoint
        // 4. Return struct with binary-search getGlyph
    }
    return struct {
        const glyphs: [N]ComptimeGlyph = comptime buildGlyphs(bdf_data);

        pub fn getGlyph(codepoint: u21) ?Glyph {
            // Binary search in sorted glyphs array
        }
    };
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ~/zt && zig build test 2>&1`
Expected: all 5 tests PASS

- [ ] **Step 6: Add CJK double-width test**

Create a test BDF entry with a 16-pixel-wide glyph (e.g., encoding 0x3042 'あ') and test that `glyph.width == 16` and bitmap has 2 bytes per row.

- [ ] **Step 7: Run tests**

Run: `cd ~/zt && zig build test 2>&1`
Expected: all tests PASS

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat: comptime BDF font parser with glyph lookup"
```

---

## Chunk 2: Cell Grid + VT Parser

### Task 3: Cell Grid and Dirty Tracking

**Files:**
- Create: `zt/src/term.zig`

- [ ] **Step 1: Write failing tests for Cell Grid**

```zig
// zt/src/term.zig
const std = @import("std");

pub const Cell = struct {
    char: u21 = ' ',
    fg: u8 = 7,
    bg: u8 = 0,
    attrs: Attrs = .{},

    pub const Attrs = packed struct(u8) {
        bold: bool = false,
        italic: bool = false,
        underline: bool = false,
        reverse: bool = false,
        dim: bool = false,
        _pad: u3 = 0,
    };
};

pub const Term = struct {
    cols: u32,
    rows: u32,
    cells: []Cell,
    dirty: std.DynamicBitSet,
    cursor_x: u32 = 0,
    cursor_y: u32 = 0,
    // Alternate screen
    alt_cells: ?[]Cell = null,
    is_alt_screen: bool = false,
    // TrueColor sparse map (for SGR 38/48;2;r;g;b)
    fg_rgb: std.AutoHashMap(usize, [3]u8),
    bg_rgb: std.AutoHashMap(usize, [3]u8),
    // Current drawing state
    current_fg: u8 = 7,
    current_bg: u8 = 0,
    current_attrs: Cell.Attrs = .{},
    current_fg_rgb: ?[3]u8 = null,
    current_bg_rgb: ?[3]u8 = null,
    // DEC modes
    decckm: bool = false,
    decawm: bool = true,
    cursor_visible: bool = true,
    bracketed_paste: bool = false,
    // Scroll region
    scroll_top: u32 = 0,
    scroll_bottom: u32 = 0, // 0 = rows-1 (set in init)
    // Saved cursor
    saved_cursor_x: u32 = 0,
    saved_cursor_y: u32 = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, cols: u32, rows: u32) !Term {
        _ = allocator;
        _ = cols;
        _ = rows;
        return error.NotImplemented;
    }

    pub fn deinit(self: *Term) void {
        _ = self;
    }

    pub fn getCell(self: *const Term, x: u32, y: u32) *const Cell {
        _ = self;
        _ = x;
        _ = y;
        unreachable;
    }

    pub fn setCell(self: *Term, x: u32, y: u32, cell: Cell) void {
        _ = self;
        _ = x;
        _ = y;
        _ = cell;
    }

    pub fn isDirty(self: *const Term, x: u32, y: u32) bool {
        _ = self;
        _ = x;
        _ = y;
        return false;
    }

    pub fn clearDirty(self: *Term) void {
        _ = self;
    }

    pub fn resize(self: *Term, new_cols: u32, new_rows: u32) !void {
        _ = self;
        _ = new_cols;
        _ = new_rows;
    }

    pub fn scrollUp(self: *Term, n: u32) void {
        _ = self;
        _ = n;
    }

    pub fn switchScreen(self: *Term, alt: bool) !void {
        _ = self;
        _ = alt;
    }
};

const testing = std.testing;

test "Term: init creates grid with default cells" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    const cell = term.getCell(0, 0);
    try testing.expectEqual(@as(u21, ' '), cell.char);
    try testing.expectEqual(@as(u8, 7), cell.fg);
}

test "Term: setCell marks dirty" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    try testing.expect(!term.isDirty(5, 3));
    term.setCell(5, 3, .{ .char = 'X', .fg = 1, .bg = 0 });
    try testing.expect(term.isDirty(5, 3));
}

test "Term: clearDirty resets all bits" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    term.setCell(0, 0, .{ .char = 'A' });
    term.clearDirty();
    try testing.expect(!term.isDirty(0, 0));
}

test "Term: scrollUp moves rows" {
    var term = try Term.init(testing.allocator, 80, 3);
    defer term.deinit();
    term.setCell(0, 0, .{ .char = 'A' });
    term.setCell(0, 1, .{ .char = 'B' });
    term.setCell(0, 2, .{ .char = 'C' });
    term.scrollUp(1);
    try testing.expectEqual(@as(u21, 'B'), term.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'C'), term.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, ' '), term.getCell(0, 2).char);
}

test "Term: alternate screen switch preserves main" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    term.setCell(0, 0, .{ .char = 'M' });
    try term.switchScreen(true); // switch to alt
    try testing.expectEqual(@as(u21, ' '), term.getCell(0, 0).char); // alt is blank
    term.setCell(0, 0, .{ .char = 'A' });
    try term.switchScreen(false); // switch back to main
    try testing.expectEqual(@as(u21, 'M'), term.getCell(0, 0).char); // main preserved
}

test "Term: resize changes dimensions" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    try term.resize(120, 40);
    try testing.expectEqual(@as(u32, 120), term.cols);
    try testing.expectEqual(@as(u32, 40), term.rows);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/zt && zig build test 2>&1 | head -20`
Expected: FAIL

- [ ] **Step 3: Implement Term**

Key implementation:
- `init`: allocate `cols * rows` Cell array + DynamicBitSet
- `getCell/setCell`: index = `y * cols + x`, setCell also sets dirty bit
- `scrollUp(n)`: memmove rows up by n, clear bottom n rows, mark all dirty
- `switchScreen`: allocate alt_cells lazily on first switch, swap pointers
- `resize`: allocate new array, copy existing cells that fit, free old

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/zt && zig build test 2>&1`
Expected: all tests PASS

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: Cell Grid with dirty tracking, scroll, alt screen"
```

---

### Task 4: VT Parser (State Machine)

**Files:**
- Create: `zt/src/vt.zig`

This is the largest single component. The parser is a state machine that consumes bytes and emits actions.

- [ ] **Step 1: Define parser types and write failing tests**

```zig
// zt/src/vt.zig
const std = @import("std");

pub const Action = union(enum) {
    print: u21,           // Print a character
    execute: u8,          // Execute C0 control (BEL, BS, HT, LF, CR, etc.)
    csi_dispatch: CsiAction,
    esc_dispatch: EscAction,
    osc_dispatch: []const u8,
    none,
};

pub const CsiAction = struct {
    params: [16]u16 = [_]u16{0} ** 16,
    param_count: u8 = 0,
    intermediates: [2]u8 = [_]u8{0} ** 2,
    intermediate_count: u8 = 0,
    final_byte: u8 = 0,
    private_marker: u8 = 0, // '?' or '>' or 0
};

pub const EscAction = struct {
    intermediate: u8 = 0,
    final_byte: u8 = 0,
};

pub const Parser = struct {
    state: State = .ground,
    // ... internal buffers

    pub fn feed(self: *Parser, byte: u8) Action {
        _ = self;
        _ = byte;
        return .none;
    }
};

pub const State = enum {
    ground,
    escape,
    escape_intermediate,
    csi_entry,
    csi_param,
    csi_intermediate,
    csi_ignore,        // malformed CSI — consume until final byte
    osc_string,
    dcs_entry,
    dcs_param,
    dcs_passthrough,   // tmux DCS passthrough
    utf8,              // accumulating UTF-8 continuation bytes
};
```

Tests:

```zig
test "VT: plain ASCII produces print actions" {
    var p = Parser{};
    const action = p.feed('A');
    try testing.expectEqual(Action{ .print = 'A' }, action);
}

test "VT: LF produces execute action" {
    var p = Parser{};
    const action = p.feed(0x0A); // LF
    try testing.expectEqual(Action{ .execute = 0x0A }, action);
}

test "VT: CSI cursor up (ESC [ 5 A)" {
    var p = Parser{};
    _ = p.feed(0x1B); // ESC
    _ = p.feed('[');
    _ = p.feed('5');
    const action = p.feed('A'); // CUU
    switch (action) {
        .csi_dispatch => |csi| {
            try testing.expectEqual(@as(u8, 'A'), csi.final_byte);
            try testing.expectEqual(@as(u16, 5), csi.params[0]);
            try testing.expectEqual(@as(u8, 1), csi.param_count);
        },
        else => return error.TestExpectedEqual,
    }
}

test "VT: SGR with multiple params (ESC [ 1 ; 31 m)" {
    var p = Parser{};
    _ = p.feed(0x1B);
    _ = p.feed('[');
    _ = p.feed('1');
    _ = p.feed(';');
    _ = p.feed('3');
    _ = p.feed('1');
    const action = p.feed('m');
    switch (action) {
        .csi_dispatch => |csi| {
            try testing.expectEqual(@as(u8, 'm'), csi.final_byte);
            try testing.expectEqual(@as(u8, 2), csi.param_count);
            try testing.expectEqual(@as(u16, 1), csi.params[0]);
            try testing.expectEqual(@as(u16, 31), csi.params[1]);
        },
        else => return error.TestExpectedEqual,
    }
}

test "VT: DEC private mode (ESC [ ? 1049 h)" {
    var p = Parser{};
    _ = p.feed(0x1B);
    _ = p.feed('[');
    _ = p.feed('?');
    _ = p.feed('1');
    _ = p.feed('0');
    _ = p.feed('4');
    _ = p.feed('9');
    const action = p.feed('h');
    switch (action) {
        .csi_dispatch => |csi| {
            try testing.expectEqual(@as(u8, 'h'), csi.final_byte);
            try testing.expectEqual(@as(u8, '?'), csi.private_marker);
            try testing.expectEqual(@as(u16, 1049), csi.params[0]);
        },
        else => return error.TestExpectedEqual,
    }
}

test "VT: UTF-8 multibyte (あ = E3 81 82)" {
    var p = Parser{};
    const r1 = p.feed(0xE3);
    try testing.expectEqual(Action.none, r1);
    const r2 = p.feed(0x81);
    try testing.expectEqual(Action.none, r2);
    const r3 = p.feed(0x82);
    try testing.expectEqual(Action{ .print = 0x3042 }, r3); // あ
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/zt && zig build test 2>&1 | head -20`
Expected: FAIL

- [ ] **Step 3: Implement VT parser state machine**

Implementation based on vt100.net state diagram:
- `ground`: printable → Print, C0 controls → Execute, ESC → transition to `escape`
- `escape`: `[` → `csi_entry`, `]` → `osc_string`, 0x20-0x2F → `escape_intermediate`, 0x30-0x7E → EscDispatch
- `csi_entry`: `?`/`>` → set private_marker, digit → `csi_param`
- `csi_param`: digit → accumulate param, `;` → next param, 0x40-0x7E → CsiDispatch
- UTF-8: detect lead byte (0xC0-0xF7), accumulate continuation bytes (0x80-0xBF), emit Print on completion

Key: the parser holds only its current state + accumulators. No heap allocation.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/zt && zig build test 2>&1`
Expected: all tests PASS

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: VT parser state machine with UTF-8 support"
```

---

### Task 5: VT Action Executor

**Files:**
- Modify: `zt/src/vt.zig` (add executor)
- Modify: `zt/src/term.zig` (add cursor movement, erase methods)

The executor takes parser Actions and mutates the Term state.

- [ ] **Step 1: Add cursor/erase methods to Term and write tests**

Add to `term.zig`:
- `moveCursorTo(x, y)` — absolute cursor positioning
- `moveCursorRel(dx, dy)` — relative cursor movement with bounds clamping
- `eraseDisplay(mode)` — ED: 0=below, 1=above, 2=all
- `eraseLine(mode)` — EL: 0=right, 1=left, 2=all
- `insertNewline()` — LF: move cursor down, scroll if at bottom
- `carriageReturn()` — CR: cursor to column 0
- `setScrollRegion(top, bottom)` — DECSTBM

Tests:
```zig
test "Term: moveCursorTo clamps to bounds" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    term.moveCursorTo(100, 50); // out of bounds
    try testing.expectEqual(@as(u32, 79), term.cursor_x);
    try testing.expectEqual(@as(u32, 23), term.cursor_y);
}

test "Term: eraseDisplay clears all cells" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    term.setCell(5, 5, .{ .char = 'X' });
    term.eraseDisplay(2); // clear all
    try testing.expectEqual(@as(u21, ' '), term.getCell(5, 5).char);
}

test "Term: insertNewline scrolls at bottom" {
    var term = try Term.init(testing.allocator, 80, 3);
    defer term.deinit();
    term.setCell(0, 0, .{ .char = 'A' });
    term.cursor_y = 2; // at bottom
    term.insertNewline();
    try testing.expectEqual(@as(u21, ' '), term.getCell(0, 0).char); // 'A' scrolled off
    try testing.expectEqual(@as(u32, 2), term.cursor_y); // still at bottom
}
```

- [ ] **Step 2: Implement cursor/erase methods**

- [ ] **Step 3: Run tests**

Run: `cd ~/zt && zig build test 2>&1`
Expected: PASS

- [ ] **Step 4: Write executor and tests**

Add `Executor` to `vt.zig` (or separate file) that takes `Action` + `*Term`:

```zig
pub fn execute(action: Action, term: *Term) void {
    switch (action) {
        .print => |cp| {
            term.setCell(term.cursor_x, term.cursor_y, .{
                .char = cp,
                .fg = term.current_fg,
                .bg = term.current_bg,
                .attrs = term.current_attrs,
            });
            term.cursor_x += 1;
            if (term.cursor_x >= term.cols) {
                term.cursor_x = 0;
                term.insertNewline();
            }
        },
        .execute => |c| switch (c) {
            0x0A => term.insertNewline(),        // LF
            0x0D => term.carriageReturn(),       // CR
            0x08 => term.cursor_x -|= 1,        // BS
            0x09 => { /* tab */ },               // HT
            0x07 => {},                          // BEL (ignore)
            else => {},
        },
        .csi_dispatch => |csi| executeCsi(csi, term),
        .esc_dispatch => |esc| executeEsc(esc, term),
        .osc_dispatch => {},
        .none => {},
    }
}

fn executeCsi(csi: CsiAction, term: *Term) void {
    // Implement: CUU(A), CUD(B), CUF(C), CUB(D), CUP(H/f),
    // ED(J), EL(K), SGR(m), SU(S), SD(T), DECSTBM(r),
    // DECSET(h), DECRST(l), cursor save/restore (s/u)
}
```

Test:
```zig
test "Executor: print 'Hello' fills cells" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    var parser = Parser{};
    for ("Hello") |byte| {
        const action = parser.feed(byte);
        vt.execute(action, &term);
    }
    try testing.expectEqual(@as(u21, 'H'), term.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'o'), term.getCell(4, 0).char);
    try testing.expectEqual(@as(u32, 5), term.cursor_x);
}

test "Executor: SGR sets colors" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    var parser = Parser{};
    // Feed ESC[31m (red fg) then 'X'
    for ("\x1b[31m" ++ "X") |byte| {
        const action = parser.feed(byte);
        vt.execute(action, &term);
    }
    try testing.expectEqual(@as(u8, 1), term.getCell(0, 0).fg); // red = 1
}

test "Executor: CUP moves cursor" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    var parser = Parser{};
    // Feed ESC[5;10H (cursor to row 5, col 10)
    for ("\x1b[5;10H") |byte| {
        const action = parser.feed(byte);
        vt.execute(action, &term);
    }
    try testing.expectEqual(@as(u32, 9), term.cursor_x); // 0-indexed
    try testing.expectEqual(@as(u32, 4), term.cursor_y);
}

test "Executor: DECSET 1049 switches to alt screen" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    var parser = Parser{};
    term.setCell(0, 0, .{ .char = 'M' });
    for ("\x1b[?1049h") |byte| {
        const action = parser.feed(byte);
        vt.execute(action, &term);
    }
    try testing.expect(term.is_alt_screen);
    try testing.expectEqual(@as(u21, ' '), term.getCell(0, 0).char);
}

test "Executor: SGR 0 resets all attributes" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    var parser = Parser{};
    // Set bold+red, then reset, then print
    for ("\x1b[1;31m" ++ "\x1b[0m" ++ "X") |byte| {
        const action = parser.feed(byte);
        vt.execute(action, &term);
    }
    try testing.expectEqual(@as(u8, 7), term.getCell(0, 0).fg); // default white
    try testing.expect(!term.getCell(0, 0).attrs.bold);
}

test "Executor: cursor save/restore (CSI s/u)" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    var parser = Parser{};
    // Move to 5,3 then save, move to 10,10, then restore
    for ("\x1b[4;6H" ++ "\x1b[s" ++ "\x1b[11;11H" ++ "\x1b[u") |byte| {
        const action = parser.feed(byte);
        vt.execute(action, &term);
    }
    try testing.expectEqual(@as(u32, 5), term.cursor_x); // restored (1-indexed→0-indexed)
    try testing.expectEqual(@as(u32, 3), term.cursor_y);
}

test "Executor: DECSTBM sets scroll region" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    var parser = Parser{};
    // Set scroll region to rows 5-20
    for ("\x1b[5;20r") |byte| {
        const action = parser.feed(byte);
        vt.execute(action, &term);
    }
    try testing.expectEqual(@as(u32, 4), term.scroll_top); // 0-indexed
    try testing.expectEqual(@as(u32, 19), term.scroll_bottom);
}

test "Executor: DECAWM wraps at right edge" {
    var term = try Term.init(testing.allocator, 5, 1); // 5-col terminal
    defer term.deinit();
    var parser = Parser{};
    // Print 6 chars with auto-wrap on (default)
    for ("ABCDEF") |byte| {
        const action = parser.feed(byte);
        vt.execute(action, &term);
    }
    // 'F' should be on row 1 (or row 0 if scrolled), col 0
    // After wrap: cursor should be at col 1, since 'F' was placed at col 0
    try testing.expectEqual(@as(u21, 'F'), term.getCell(0, 0).char); // after scroll
}

test "Executor: TrueColor SGR 38;2;r;g;b sets fg RGB" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    var parser = Parser{};
    // Set TrueColor fg to RGB(255, 128, 0)
    for ("\x1b[38;2;255;128;0m" ++ "X") |byte| {
        const action = parser.feed(byte);
        vt.execute(action, &term);
    }
    // Cell at 0,0 should have TrueColor fg in sparse map
    const rgb = term.fg_rgb.get(0); // cell index 0
    try testing.expect(rgb != null);
    try testing.expectEqual([3]u8{ 255, 128, 0 }, rgb.?);
}
```

- [ ] **Step 5: Implement executor**

Full CSI dispatch table:
- `A` CUU, `B` CUD, `C` CUF, `D` CUB — cursor movement
- `H`/`f` CUP — cursor position (1-indexed params → 0-indexed)
- `J` ED — erase display
- `K` EL — erase line
- `m` SGR — colors and attributes (0 reset, 1 bold, 3 italic, 4 underline, 7 reverse, 22 dim off, 30-37 fg, 38 extended fg, 40-47 bg, 48 extended bg, 90-97 bright fg, 100-107 bright bg)
- `S` SU, `T` SD — scroll
- `r` DECSTBM — scroll region
- `s`/`u` — cursor save/restore
- `h`/`l` with `?` — DEC modes (1 DECCKM, 7 DECAWM, 25 cursor visible, 47/1047/1049 alt screen, 2004 bracketed paste)

- [ ] **Step 6: Run tests**

Run: `cd ~/zt && zig build test 2>&1`
Expected: all tests PASS

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: VT action executor with CSI/SGR/DEC modes"
```

---

## Chunk 3: PTY + Input Translation

### Task 6: PTY Management

**Files:**
- Create: `zt/src/pty.zig`

- [ ] **Step 1: Define PTY interface and write test**

```zig
// zt/src/pty.zig
const std = @import("std");

pub const Pty = struct {
    master_fd: std.posix.fd_t,
    child_pid: std.posix.pid_t,

    pub fn spawn(cols: u16, rows: u16, shell: [*:0]const u8) !Pty {
        _ = cols;
        _ = rows;
        _ = shell;
        return error.NotImplemented;
    }

    pub fn deinit(self: *Pty) void {
        _ = self;
    }

    pub fn read(self: *Pty, buf: []u8) !usize {
        _ = self;
        _ = buf;
        return error.NotImplemented;
    }

    pub fn write(self: *Pty, data: []const u8) !usize {
        _ = self;
        _ = data;
        return error.NotImplemented;
    }

    pub fn resize(self: *Pty, cols: u16, rows: u16) !void {
        _ = self;
        _ = cols;
        _ = rows;
    }
};
```

Test (integration — spawns a real shell):
```zig
test "Pty: spawn and echo" {
    var pty = try Pty.spawn(80, 24, "/bin/echo");
    defer pty.deinit();
    var buf: [256]u8 = undefined;
    // /bin/echo with no args outputs a newline
    const n = try pty.read(&buf);
    try testing.expect(n > 0);
}
```

- [ ] **Step 2: Implement PTY spawn**

Implementation sequence (from spec):
1. `std.posix.open("/dev/ptmx", .{ .RDWR = true, .NOCTTY = true })` → master_fd
2. `ioctl(master_fd, TIOCSPTLCK, &@as(c_int, 0))` — unlock
3. `ioctl(master_fd, TIOCGPTN, &pty_num)` — get pts number
4. `std.posix.fork()`
5. Child:
   - `setsid()`
   - Open `/dev/pts/{pty_num}`
   - `ioctl(slave_fd, TIOCSCTTY, 0)`
   - `dup2` to 0/1/2
   - Close master_fd and slave_fd
   - Reset signals
   - Set environment (TERM, COLORTERM, COLUMNS, LINES, SHELL, HOME, USER, PATH)
   - `execve(shell)`
6. Parent: close slave_fd, set master_fd nonblocking

Note: ioctl constants need to be defined manually since we're not using libc headers:
```zig
const TIOCSPTLCK = 0x40045431;
const TIOCGPTN = 0x80045430;
const TIOCSCTTY = 0x540E;
const TIOCSWINSZ = 0x5414;
```

- [ ] **Step 3: Run test**

Run: `cd ~/zt && zig build test 2>&1`
Expected: PASS (pty spawn test)

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: PTY management with fork/execve, no libc"
```

---

### Task 7: Input Translation

**Files:**
- Create: `zt/src/input.zig`

- [ ] **Step 1: Write tests for key translation**

```zig
// zt/src/input.zig
const std = @import("std");

pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    meta: bool = false,
    _pad: u4 = 0,
};

/// Translate a keycode + modifiers into bytes to write to PTY.
/// Returns a slice into a static buffer.
pub fn translateKey(keycode: u16, mods: Modifiers, decckm: bool) []const u8 {
    _ = keycode;
    _ = mods;
    _ = decckm;
    return "";
}
```

Tests:
```zig
const linux = std.os.linux;

test "Input: KEY_A with no mods produces 'a'" {
    const result = translateKey(linux.KEY.A, .{}, false);
    try testing.expectEqualSlices(u8, "a", result);
}

test "Input: KEY_A with shift produces 'A'" {
    const result = translateKey(linux.KEY.A, .{ .shift = true }, false);
    try testing.expectEqualSlices(u8, "A", result);
}

test "Input: KEY_A with ctrl produces 0x01" {
    const result = translateKey(linux.KEY.A, .{ .ctrl = true }, false);
    try testing.expectEqualSlices(u8, &[_]u8{0x01}, result);
}

test "Input: KEY_A with alt produces ESC + 'a'" {
    const result = translateKey(linux.KEY.A, .{ .alt = true }, false);
    try testing.expectEqualSlices(u8, "\x1ba", result);
}

test "Input: KEY_UP with DECCKM off produces CSI A" {
    const result = translateKey(linux.KEY.UP, .{}, false);
    try testing.expectEqualSlices(u8, "\x1b[A", result);
}

test "Input: KEY_UP with DECCKM on produces SS3 A" {
    const result = translateKey(linux.KEY.UP, .{}, true);
    try testing.expectEqualSlices(u8, "\x1bOA", result);
}

test "Input: KEY_ENTER produces CR" {
    const result = translateKey(linux.KEY.ENTER, .{}, false);
    try testing.expectEqualSlices(u8, "\r", result);
}

test "Input: KEY_F1 produces CSI 11~" {
    const result = translateKey(linux.KEY.F1, .{}, false);
    try testing.expectEqualSlices(u8, "\x1b[11~", result);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/zt && zig build test 2>&1 | head -20`
Expected: FAIL

- [ ] **Step 3: Implement translateKey**

Implementation:
- Keymap array: `[256]?KeyMapping` indexed by Linux keycode
- `KeyMapping = struct { normal: u8, shifted: u8 }` for printable keys
- Special keys (arrows, F1-F12, Home, End, etc.) handled by separate lookup returning CSI sequences
- Ctrl: for A-Z → 0x01-0x1A
- Alt: prepend ESC (0x1B) to the normal output
- Arrow keys: check `decckm` flag for `\eOA` vs `\e[A`
- Return static buffer (thread-local or comptime)

Default keymap from `config.zig` (US layout).

- [ ] **Step 4: Run tests**

Run: `cd ~/zt && zig build test 2>&1`
Expected: all tests PASS

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: input keycode to VT sequence translation"
```

---

## Chunk 4: Renderer + fbdev Backend

### Task 8: Cell Renderer

**Files:**
- Create: `zt/src/render.zig`

- [ ] **Step 1: Write tests for pixel rendering**

```zig
// zt/src/render.zig
const std = @import("std");
const font_mod = @import("font.zig");
const term_mod = @import("term.zig");

pub const Color = struct { r: u8, g: u8, b: u8 };

/// xterm-256color palette
pub const palette: [256]Color = buildPalette();

fn buildPalette() [256]Color {
    // Standard 16 colors + 216 color cube + 24 grayscale
    // Implementation at comptime
}

pub const PixelFormat = enum {
    bgra32,    // 32bpp BGRA (most common)
    rgb565,    // 16bpp RGB565 (some SBCs)
    rgb24,     // 24bpp RGB
};

/// Render a single cell into a pixel buffer.
/// buffer: raw pixel buffer
/// stride: bytes per row in buffer
/// pixel_format: detected from framebuffer vscreeninfo
pub fn renderCell(
    buffer: []u8,
    stride: u32,
    x: u32,
    y: u32,
    cell: term_mod.Cell,
    fg_rgb_override: ?[3]u8,
    bg_rgb_override: ?[3]u8,
    comptime FontType: type,
    comptime pixel_format: PixelFormat,
) void {
    _ = buffer;
    _ = stride;
    _ = x;
    _ = y;
    _ = cell;
    _ = fg_rgb_override;
    _ = bg_rgb_override;
    _ = FontType;
}

/// Write a single pixel in the given format
inline fn writePixel(buffer: []u8, offset: usize, color: Color, comptime fmt: PixelFormat) void {
    switch (fmt) {
        .bgra32 => {
            buffer[offset] = color.b;
            buffer[offset + 1] = color.g;
            buffer[offset + 2] = color.r;
            buffer[offset + 3] = 0xFF;
        },
        .rgb565 => {
            const val: u16 = (@as(u16, color.r >> 3) << 11) |
                             (@as(u16, color.g >> 2) << 5) |
                             @as(u16, color.b >> 3);
            buffer[offset] = @truncate(val);
            buffer[offset + 1] = @truncate(val >> 8);
        },
        .rgb24 => {
            buffer[offset] = color.r;
            buffer[offset + 1] = color.g;
            buffer[offset + 2] = color.b;
        },
    }
}
```

Tests:
```zig
test "Render: palette color 0 is black" {
    try testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0 }, palette[0]);
}

test "Render: palette color 1 is red" {
    try testing.expectEqual(Color{ .r = 128, .g = 0, .b = 0 }, palette[1]);
}

test "Render: renderCell writes pixels to buffer" {
    // 8x16 cell, 32bpp = 8*4*16 = 512 bytes per cell
    var buffer: [8 * 4 * 16]u8 = [_]u8{0} ** (8 * 4 * 16);
    renderCell(&buffer, 8 * 4, 0, 0, .{ .char = 'A', .fg = 7, .bg = 0 }, TestFont);
    // At least some pixels should be non-zero (the 'A' glyph)
    var has_fg = false;
    var i: usize = 0;
    while (i < buffer.len) : (i += 4) {
        if (buffer[i] != 0 or buffer[i + 1] != 0 or buffer[i + 2] != 0) {
            has_fg = true;
            break;
        }
    }
    try testing.expect(has_fg);
}
```

- [ ] **Step 2: Implement renderCell**

Algorithm:
1. Look up fg/bg colors from palette, or use TrueColor RGB override if provided (handle reverse attr by swapping)
2. Fill cell rectangle with bg color using writePixel (format-aware)
3. Look up glyph bitmap from Font. If null (missing glyph), use U+25AF (▯) as fallback
4. For each set bit in glyph bitmap, write fg color pixel using writePixel
5. Bold: draw glyph again at x+1 (OR the pixels)
6. Underline: fill bottom row with fg
7. Dim: halve fg RGB values

Pixel format: detected at compile time or init. Supported: BGRA32, RGB565, RGB24.

- [ ] **Step 3: Run tests**

Run: `cd ~/zt && zig build test 2>&1`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: cell renderer with palette and glyph blitting"
```

---

### Task 9: fbdev Backend

**Files:**
- Create: `zt/src/backend/fbdev.zig`

- [ ] **Step 1: Define backend interface**

```zig
// zt/src/backend/fbdev.zig
const std = @import("std");

pub const FbdevBackend = struct {
    fb_fd: std.posix.fd_t,
    buffer: []align(4096) u8,   // mmap'd framebuffer
    shadow: []u8,               // shadow buffer for rendering
    width: u32,
    height: u32,
    stride: u32,                // bytes per row
    bpp: u32,                   // bits per pixel
    evdev_fds: [8]std.posix.fd_t,
    evdev_count: u8 = 0,

    pub fn init() !FbdevBackend {
        return error.NotImplemented;
    }

    pub fn deinit(self: *FbdevBackend) void { _ = self; }
    pub fn getBuffer(self: *FbdevBackend) []u8 { return self.shadow; }
    pub fn getStride(self: *FbdevBackend) u32 { return self.stride; }
    pub fn getWidth(self: *FbdevBackend) u32 { return self.width; }
    pub fn getHeight(self: *FbdevBackend) u32 { return self.height; }

    // Dirty region for selective shadow→fbdev copy (reduces tearing)
    dirty_y_min: u32 = std.math.maxInt(u32),
    dirty_y_max: u32 = 0,

    pub fn markDirtyRows(self: *FbdevBackend, y_start: u32, y_end: u32) void {
        self.dirty_y_min = @min(self.dirty_y_min, y_start);
        self.dirty_y_max = @max(self.dirty_y_max, y_end);
    }

    pub fn present(self: *FbdevBackend) void {
        // Only copy dirty row range from shadow buffer to mmap'd fbdev
        if (self.dirty_y_min > self.dirty_y_max) return; // nothing dirty
        const start_offset = self.dirty_y_min * self.stride;
        const end_offset = (self.dirty_y_max + 1) * self.stride;
        @memcpy(self.buffer[start_offset..end_offset], self.shadow[start_offset..end_offset]);
        self.dirty_y_min = std.math.maxInt(u32);
        self.dirty_y_max = 0;
    }

    pub fn getFd(self: *FbdevBackend) ?std.posix.fd_t {
        _ = self;
        return null; // fbdev has no event fd; evdev fds registered separately
    }

    pub fn resize(self: *FbdevBackend, w: u32, h: u32) void {
        // fbdev is fixed size — noop
        _ = self; _ = w; _ = h;
    }
};
```

- [ ] **Step 2: Implement fbdev init**

1. Open `/dev/fb0`
2. `ioctl(fd, FBIOGET_VSCREENINFO, &vinfo)` — get xres, yres, bits_per_pixel
3. `ioctl(fd, FBIOGET_FSCREENINFO, &finfo)` — get line_length (stride)
4. `mmap` the framebuffer
5. Allocate shadow buffer (same size)
6. Scan `/dev/input/event*` for keyboard devices (EVIOCGBIT check)
7. Open and register evdev fds

ioctl constants:
```zig
const FBIOGET_VSCREENINFO = 0x4600;
const FBIOGET_FSCREENINFO = 0x4602;
```

- [ ] **Step 3: Implement evdev reading**

```zig
pub const InputEvent = struct {
    keycode: u16,
    pressed: bool, // true = key down, false = key up
};

pub fn readInput(self: *FbdevBackend) ?InputEvent {
    // Try read from each evdev fd (nonblocking)
    // Parse struct input_event { tv_sec, tv_usec, type, code, value }
    // Filter: type == EV_KEY, value == 1 (press) or 0 (release) or 2 (repeat)
}
```

Linux input_event is 24 bytes on 64-bit, 16 bytes on 32-bit. Must handle both (RPi Zero is 64-bit aarch64).

- [ ] **Step 4: Implement VT switching**

```zig
pub fn setupVtSwitching(self: *FbdevBackend) !void {
    // 1. Get current VT number: ioctl(tty_fd, VT_GETSTATE, &state)
    // 2. Set VT_PROCESS mode: ioctl(tty_fd, VT_SETMODE, &mode)
    //    mode.mode = VT_PROCESS, mode.relsig = SIGUSR1, mode.acqsig = SIGUSR2
    // 3. SIGUSR1/SIGUSR2 handled via signalfd in main loop
}

pub fn releaseVt(self: *FbdevBackend) void {
    // Save state, ioctl(tty_fd, VT_RELDISP, 1)
}

pub fn acquireVt(self: *FbdevBackend) void {
    // ioctl(tty_fd, VT_RELDISP, VT_ACKACQ), restore state, full redraw
}
```

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: fbdev backend with evdev input and VT switching"
```

---

## Chunk 5: X11 Backend

### Task 10: X11 (XCB + SHM) Backend

**Files:**
- Create: `zt/src/backend/x11.zig`
- Modify: `zt/build.zig` (link xcb, xcb-shm, xcb-xkb)

- [ ] **Step 1: Update build.zig for X11 linking**

```zig
// In build.zig, after creating exe:
const config = @import("config.zig");
if (config.backend == .x11) {
    exe.linkSystemLibrary("xcb");
    exe.linkSystemLibrary("xcb-shm");
    exe.linkSystemLibrary("xcb-xkb");
}
```

Note: XCB is a C library, so X11 backend requires linking against it. This is acceptable — the "no libc" constraint applies to zt's own code, not to backend-specific system libraries. fbdev backend remains zero external dependencies.

- [ ] **Step 2: Define X11 backend structure**

```zig
// zt/src/backend/x11.zig
const std = @import("std");
const c = @cImport({
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/shm.h");
    @cInclude("xcb/xcb_event.h");
});

pub const X11Backend = struct {
    connection: *c.xcb_connection_t,
    window: c.xcb_window_t,
    gc: c.xcb_gcontext_t,
    shm_seg: c.xcb_shm_seg_t,
    shm_id: i32,
    buffer: []u8,               // SHM-mapped pixel buffer
    width: u32,
    height: u32,
    stride: u32,

    pub fn init() !X11Backend { ... }
    pub fn deinit(self: *X11Backend) void { ... }
    pub fn getBuffer(self: *X11Backend) []u8 { return self.buffer; }
    pub fn getStride(self: *X11Backend) u32 { return self.stride; }
    pub fn getWidth(self: *X11Backend) u32 { return self.width; }
    pub fn getHeight(self: *X11Backend) u32 { return self.height; }
    pub fn present(self: *X11Backend) void { ... }
    pub fn getFd(self: *X11Backend) ?std.posix.fd_t { ... }
    pub fn resize(self: *X11Backend, w: u32, h: u32) void { ... }
};
```

- [ ] **Step 3: Implement X11 init**

1. `xcb_connect(NULL, NULL)` — connect to X server
2. Get screen from `xcb_setup_roots_iterator`
3. `xcb_create_window` — create window
4. `xcb_shm_create_segment` or `shmget`/`shmat` + `xcb_shm_attach` — set up SHM
5. `xcb_create_gc` — create graphics context
6. `xcb_map_window` — show window
7. Subscribe to events: `XCB_EVENT_MASK_KEY_PRESS | KEY_RELEASE | STRUCTURE_NOTIFY | EXPOSURE`

- [ ] **Step 4: Implement X11 input handling**

```zig
pub fn pollEvents(self: *X11Backend) ?InputEvent {
    const event = c.xcb_poll_for_event(self.connection);
    if (event == null) return null;
    defer std.c.free(event);

    const event_type = event.*.response_type & 0x7F;
    switch (event_type) {
        c.XCB_KEY_PRESS => {
            const key = @as(*c.xcb_key_press_event_t, @ptrCast(event));
            return .{ .keycode = key.detail, .pressed = true, .xcb_state = key.state };
        },
        c.XCB_KEY_RELEASE => { ... },
        c.XCB_CONFIGURE_NOTIFY => {
            const cfg = @as(*c.xcb_configure_notify_event_t, @ptrCast(event));
            self.handleResize(cfg.width, cfg.height);
            return null;
        },
        else => return null,
    }
}
```

XCB keycodes need XKB translation. Use `xcb-xkb` extension to get the system keymap and translate keycodes to keysyms, then to UTF-8/control sequences.

- [ ] **Step 5: Implement present (XShmPutImage)**

```zig
pub fn present(self: *X11Backend) void {
    _ = c.xcb_shm_put_image(
        self.connection, self.window, self.gc,
        @intCast(self.width), @intCast(self.height),
        0, 0,  // src_x, src_y
        @intCast(self.width), @intCast(self.height),
        0, 0,  // dst_x, dst_y
        24,    // depth
        c.XCB_IMAGE_FORMAT_Z_PIXMAP,
        0,     // send_event
        self.shm_seg,
        0,     // offset
    );
    _ = c.xcb_flush(self.connection);
}
```

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: X11 backend with XCB + SHM rendering"
```

---

## Chunk 6: Event Loop + Main + Integration

### Task 11: Signal Handling

**Files:**
- Modify: `zt/src/main.zig`

- [ ] **Step 1: Implement signalfd setup**

```zig
const linux = std.os.linux;

fn sigaddset(set: *linux.sigset_t, sig: u6) void {
    const idx = @as(usize, sig - 1) / @bitSizeOf(usize);
    const bit: linux.sigset_t.ItemType = @as(linux.sigset_t.ItemType, 1) << @intCast(@as(usize, sig - 1) % @bitSizeOf(usize));
    set.*[idx] |= bit;
}

fn setupSignals() !std.posix.fd_t {
    var mask: linux.sigset_t = std.mem.zeroes(linux.sigset_t);
    // Block and route these signals through signalfd:
    sigaddset(&mask, linux.SIG.CHLD);
    sigaddset(&mask, linux.SIG.TERM);
    sigaddset(&mask, linux.SIG.INT);
    sigaddset(&mask, linux.SIG.HUP);
    sigaddset(&mask, linux.SIG.USR1); // VT release (fbdev)
    sigaddset(&mask, linux.SIG.USR2); // VT acquire (fbdev)
    sigaddset(&mask, linux.SIG.TSTP);
    sigaddset(&mask, linux.SIG.CONT);
    _ = linux.sigprocmask(.BLOCK, &mask, null);

    const SFD_NONBLOCK = @as(u32, 0o4000);
    const SFD_CLOEXEC = @as(u32, 0o2000000);
    const fd = linux.signalfd(-1, &mask, SFD_NONBLOCK | SFD_CLOEXEC);
    if (@as(isize, @bitCast(fd)) < 0) return error.SignalFdFailed;
    return @intCast(fd);
}
```

- [ ] **Step 2: Commit**

```bash
git add -A && git commit -m "feat: signal handling via signalfd"
```

---

### Task 12: Main Event Loop

**Files:**
- Modify: `zt/src/main.zig`

This is where everything comes together.

- [ ] **Step 1: Implement main()**

```zig
const std = @import("std");
const linux = std.os.linux;
const config = @import("config"); // registered as module in build.zig
const Term = @import("term.zig").Term;
const vt = @import("vt.zig");
const Pty = @import("pty.zig").Pty;
const input = @import("input.zig");
const render = @import("render.zig");
const Backend = switch (config.backend) {
    .fbdev => @import("backend/fbdev.zig").FbdevBackend,
    .x11 => @import("backend/x11.zig").X11Backend,
};

const FontData = @embedFile("../fonts/default.bdf");
const FontType = @import("font.zig").Font(FontData);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // 1. Init backend
    var backend = try Backend.init();
    defer backend.deinit();

    // 2. Calculate grid dimensions
    const cols = backend.getWidth() / config.font_width;
    const rows = backend.getHeight() / config.font_height;

    // 3. Init term
    var term = try Term.init(allocator, cols, rows);
    defer term.deinit();

    // 4. Spawn PTY
    var pty = try Pty.spawn(@intCast(cols), @intCast(rows), config.shell);
    defer pty.deinit();

    // 5. Setup signals
    const sig_fd = try setupSignals();

    // 6. Setup cursor blink timer via timerfd
    const timer_fd = try createTimerFd(500_000_000); // 500ms blink

    // Helper implementations (defined below main):
    // fn createTimerFd(interval_ns: u64) !fd_t
    //   - linux.timerfd_create(linux.CLOCK.MONOTONIC, linux.TFD.NONBLOCK | linux.TFD.CLOEXEC)
    //   - linux.timerfd_settime(fd, 0, &itimerspec{ .it_interval = ns, .it_value = ns })
    // fn epollAdd(epoll_fd: fd_t, fd: fd_t, tag: u32) !void
    //   - linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, fd, &event{ .events = EPOLLIN, .data = .{ .u32 = tag } })

    // 7. Setup epoll
    // Use linux.epoll_create1 directly (std.posix wrapper takes different args)
    const epoll_fd_raw = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    if (@as(isize, @bitCast(epoll_fd_raw)) < 0) return error.EpollCreateFailed;
    const epoll_fd: std.posix.fd_t = @intCast(epoll_fd_raw);
    defer std.posix.close(epoll_fd);

    // Helper to add fd to epoll
    const EpollTag = enum(u32) { pty = 0, signal = 1, timer = 2, backend = 3, evdev_base = 10 };

    // Register fds using linux.epoll_ctl directly
    try epollAdd(epoll_fd, pty.master_fd, @intFromEnum(EpollTag.pty));
    try epollAdd(epoll_fd, sig_fd, @intFromEnum(EpollTag.signal));
    try epollAdd(epoll_fd, timer_fd, @intFromEnum(EpollTag.timer));
    if (backend.getFd()) |fd| try epollAdd(epoll_fd, fd, @intFromEnum(EpollTag.backend));
    // For fbdev: register each evdev fd with tags evdev_base+i
    // backend.registerEvdevFds(epoll_fd, EpollTag.evdev_base);

    // 8. Event loop
    var parser = vt.Parser{};
    var running = true;
    var pty_buf: [65536]u8 = undefined;

    while (running) {
        var events: [16]linux.epoll_event = undefined;
        const n_raw = linux.epoll_wait(epoll_fd, &events, events.len, -1);
        if (@as(isize, @bitCast(n_raw)) < 0) continue; // EINTR
        const n: usize = @intCast(n_raw);

        for (events[0..n]) |ev| {
            switch (ev.data.u32) {
                @intFromEnum(EpollTag.pty) => {
                    // PTY readable — bulk read + batch parse
                    const bytes_read = pty.read(&pty_buf) catch |err| switch (err) {
                        error.InputOutput, error.NotOpenForReading => {
                            running = false;
                            break;
                        },
                        else => continue,
                    };
                    if (bytes_read == 0) { running = false; break; } // EOF
                    for (pty_buf[0..bytes_read]) |byte| {
                        const action = parser.feed(byte);
                        vt.execute(action, &term);
                    }
                },
                @intFromEnum(EpollTag.signal) => {
                    // Signal
                    running = try handleSignal(sig_fd, &backend);
                },
                @intFromEnum(EpollTag.timer) => {
                    // Timer — toggle cursor blink
                    var exp: u64 = undefined;
                    _ = std.posix.read(timer_fd, std.mem.asBytes(&exp)) catch {};
                    toggleCursorBlink(&term);
                },
                @intFromEnum(EpollTag.backend) => {
                    // Backend events (X11 key events, resize, etc.)
                    while (backend.pollEvents()) |input_event| {
                        const bytes = input.translateKey(
                            input_event.keycode,
                            input_event.modifiers,
                            term.decckm,
                        );
                        if (bytes.len > 0) _ = try pty.write(bytes);
                    }
                },
                else => {
                    // evdev fds (tag >= evdev_base) — fbdev backend
                    if (ev.data.u32 >= @intFromEnum(EpollTag.evdev_base)) {
                        if (backend.readEvdev(ev.data.u32 - @intFromEnum(EpollTag.evdev_base))) |input_event| {
                            const bytes = input.translateKey(input_event.keycode, input_event.modifiers, term.decckm);
                            if (bytes.len > 0) _ = try pty.write(bytes);
                        }
                    }
                },
            }
        }

        // Render dirty cells
        const buf = backend.getBuffer();
        const stride = backend.getStride();
        var y: u32 = 0;
        while (y < term.rows) : (y += 1) {
            var x: u32 = 0;
            while (x < term.cols) : (x += 1) {
                if (term.isDirty(x, y)) {
                    render.renderCell(buf, stride, x, y, term.getCell(x, y).*, FontType);
                }
            }
        }
        term.clearDirty();
        backend.present();
    }

    // Cleanup: restore console state (fbdev)
}
```

- [ ] **Step 2: Wire up all imports in main.zig test block**

```zig
test {
    _ = @import("font.zig");
    _ = @import("term.zig");
    _ = @import("vt.zig");
    _ = @import("pty.zig");
    _ = @import("input.zig");
    _ = @import("render.zig");
}
```

- [ ] **Step 3: Build and verify compilation**

Run: `cd ~/zt && zig build 2>&1`
Expected: compiles (may not run without /dev/fb0 access, but must compile)

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: main event loop integrating all components"
```

---

### Task 13: Console Restore + Graceful Shutdown

**Files:**
- Modify: `zt/src/main.zig`
- Modify: `zt/src/backend/fbdev.zig`

- [ ] **Step 1: Implement fbdev console state save/restore**

```zig
// In fbdev.zig
pub fn saveConsoleState(self: *FbdevBackend) !void {
    // Save: keyboard mode (KDGKBMODE), VT mode, original FB contents
    // Set keyboard to RAW mode (KDSKBMODE, K_RAW) for evdev
}

pub fn restoreConsoleState(self: *FbdevBackend) void {
    // Restore: keyboard mode, VT mode
    // This MUST run on exit/crash to avoid leaving user without input
}
```

- [ ] **Step 2: Wire into main shutdown path**

```zig
fn handleSignal(sig_fd: fd_t, backend: *Backend) !bool {
    var siginfo: std.os.linux.signalfd_siginfo = undefined;
    _ = try std.posix.read(sig_fd, std.mem.asBytes(&siginfo));

    switch (siginfo.signo) {
        std.os.linux.SIG.CHLD, std.os.linux.SIG.TERM,
        std.os.linux.SIG.INT, std.os.linux.SIG.HUP => {
            backend.restoreConsoleState();
            return false; // stop loop
        },
        std.os.linux.SIG.USR1 => backend.releaseVt(),
        std.os.linux.SIG.USR2 => backend.acquireVt(),
        std.os.linux.SIG.TSTP => {
            backend.restoreConsoleState();
            // Re-raise SIGTSTP with default handler to actually stop
        },
        std.os.linux.SIG.CONT => {
            backend.saveConsoleState();
            // Full redraw
        },
        else => {},
    }
    return true; // continue loop
}
```

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: graceful shutdown with console state restore"
```

---

### Task 14: Integration Test + Default Font

**Files:**
- Create: `zt/fonts/default.bdf` (real BDF font with ASCII + JIS coverage)

- [ ] **Step 1: Obtain a suitable BDF font**

Options:
- Unifont BDF (covers everything, large)
- k14 + some ASCII font
- Generate from existing font on the system

For initial testing, use a subset: ASCII printable (0x20-0x7E) is minimum viable.

```bash
# Check if system has any BDF fonts
find /usr/share/fonts -name "*.bdf" 2>/dev/null | head -5
```

If none available, the test_minimal.bdf works for compilation. A real font can be added later.

- [ ] **Step 2: End-to-end build test**

```bash
cd ~/zt
# Build for fbdev (default)
zig build 2>&1

# Build for x11
# (edit config.zig to .x11, or add build option)
```

- [ ] **Step 3: Run all unit tests**

```bash
cd ~/zt && zig build test 2>&1
```

Expected: all tests PASS

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: default font and integration build verification"
```

---

### Task 15: Post-implementation quality gate

- [ ] **Step 1: Run coderabbit**

```bash
cd ~/zt && coderabbit --prompt-only
```

Fix any issues detected.

- [ ] **Step 2: Final commit**

```bash
git add -A && git commit -m "fix: address coderabbit review findings"
```

---

## Implementation Notes

### Build Options

The plan currently uses `config.zig` for backend selection. An alternative is `build.zig` options:

```bash
zig build -Dbackend=x11   # X11 build
zig build -Dbackend=fbdev  # fbdev build (default)
```

This can be added as a refinement — `config.zig` import in `build.zig` options.

### Cross-compilation for HackberryPi

```bash
zig build -Dtarget=aarch64-linux -Doptimize=ReleaseSmall
```

ReleaseSmall for minimum binary size. Test on HackberryPi via:
```bash
scp zt/zig-out/bin/zt midasdf@anzu.local:~/
ssh midasdf@anzu.local './zt'
```

### Testing Strategy

- **Unit testable**: font.zig, term.zig, vt.zig, input.zig, render.zig (pure logic)
- **Integration testable**: pty.zig (spawns real process)
- **Manual test only**: backend/fbdev.zig, backend/x11.zig (need real devices)
- **End-to-end**: build + run on target hardware

### Dependency Order

```
font.zig (standalone)
    ↓
term.zig (standalone)
    ↓
vt.zig → depends on term.zig
    ↓
input.zig (standalone)
    ↓
pty.zig (standalone)
    ↓
render.zig → depends on font.zig, term.zig
    ↓
backend/*.zig → depends on render.zig
    ↓
main.zig → depends on everything
```

Tasks 2, 3, 4, 6, and 7 can be developed in parallel (independent modules). Task 5 depends on 3 and 4. Tasks 8-12 are sequential (integration).
