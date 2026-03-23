// fontconfig C bindings
pub const c = @cImport({
    @cInclude("fontconfig/fontconfig.h");
});
