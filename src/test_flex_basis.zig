//! Test aggregator for flex-basis unit tests.
//!
//! The tests themselves live at the bottom of src/layout/flex.zig so they can
//! call internal helpers (resolveFlexBasis, tfMake*, ...). This module just
//! forces the Zig test runner to discover them.
//!
//! Build wiring lives in build.zig under the `test-flex-basis` step and
//! mirrors the main executable's C dependencies (lexbor + freetype +
//! harfbuzz) because flex.zig transitively pulls in paint/painter.zig
//! and layout/block.zig through its imports.

comptime {
    _ = @import("layout/flex.zig");
}
