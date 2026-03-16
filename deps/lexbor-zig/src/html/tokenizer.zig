const core = @import("../core_ext.zig");
const html = @import("../html_ext.zig");

pub const Tokenizer = html.lxb_html_tokenizer;

pub fn create() ?*html.lxb_html_tokenizer_t {
    return html.lxb_html_tokenizer_create();
}

pub fn init(tkz: ?*html.lxb_html_tokenizer_t) core.lexbor_status_t {
    const status = html.lxb_html_tokenizer_init(tkz);
    return @enumFromInt(status);
}

pub fn destroy(tkz: ?*html.lxb_html_tokenizer_t) ?*html.lxb_html_tokenizer_t {
    return html.lxb_html_tokenizer_destroy(tkz);
}

pub fn begin(tkz: ?*html.lxb_html_tokenizer_t) core.lexbor_status_t {
    const status = html.lxb_html_tokenizer_begin(tkz);
    return @enumFromInt(status);
}

pub fn chunk(tkz: ?*html.lxb_html_tokenizer_t, data: []const u8, size: usize) core.lexbor_status_t {
    const status = html.lxb_html_tokenizer_chunk(tkz, @ptrCast(data.ptr), size);
    return @enumFromInt(status);
}

pub fn end(tkz: ?*html.lxb_html_tokenizer_t) core.lexbor_status_t {
    const status = html.lxb_html_tokenizer_end(tkz);
    return @enumFromInt(status);
}

pub fn callbackTokenDoneSet(tkz: ?*html.lxb_html_tokenizer_t, call_func: html.lxb_html_tokenizer_token_f, ctx: ?*anyopaque) void {
    html.lxb_html_tokenizer_callback_token_done_set(tkz, call_func, ctx);
}
