// CSS engine test suite entry point.
// Imports all CSS test modules so `zig build test-css` runs them all.
comptime {
    _ = @import("test_string_pool");
    _ = @import("test_tokenizer");
    _ = @import("test_parser");
    _ = @import("test_properties");
    _ = @import("test_selectors");
    _ = @import("test_media");
    _ = @import("test_variables");
}
