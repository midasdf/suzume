// LibCSS C bindings via @cImport
// Only include the specific headers we need to minimize cimport size
pub const c = @cImport({
    @cInclude("stdbool.h");
    @cInclude("libwapcaplet/libwapcaplet.h");
    @cInclude("libcss/errors.h");
    @cInclude("libcss/types.h");
    @cInclude("libcss/functypes.h");
    @cInclude("libcss/computed.h");
    @cInclude("libcss/properties.h");
    @cInclude("libcss/select.h");
    @cInclude("libcss/stylesheet.h");
});
