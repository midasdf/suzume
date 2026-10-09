//! Test aggregator for flex-basis unit tests.
//!
//! Internal flex tests live in src/layout/flex.zig so they can call its helpers.
//! This module also discovers production relayout geometry tests.
//!
//! Build wiring lives in build.zig under the `test-flex-basis` step and
//! mirrors the main executable's C dependencies (lexbor + freetype +
//! harfbuzz) because flex.zig transitively pulls in paint/painter.zig
//! and layout/block.zig through its imports.

comptime {
    _ = @import("layout/flex.zig");
    _ = @import("test_flex_relayout.zig");
    _ = @import("test_flex_cross_size.zig");
    _ = @import("test_flex_whitespace.zig");
}
