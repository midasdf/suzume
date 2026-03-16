// LibNSFB C bindings via @cImport
pub const c = @cImport({
    @cInclude("stdbool.h");
    @cInclude("libnsfb.h");
    @cInclude("libnsfb_plot.h");
    @cInclude("libnsfb_event.h");
});
