// test_style_decl.zig — Phase 1 StyleDeclList unit tests
// Re-exports the tests embedded in style_decl.zig via the named module.
comptime {
    _ = @import("style_decl");
}
