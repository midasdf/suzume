pub const core = @import("../core_ext.zig");
pub const html = @import("../html_ext.zig");

pub fn create() ?*html.lxb_html_parser_t {
    return html.lxb_html_parser_create();
}

pub fn init(parser: ?*html.lxb_html_parser_t) core.lexbor_status_t {
    const status = html.lxb_html_parser_init(parser);
    return @enumFromInt(status);
}

pub fn destroy(parser: ?*html.lxb_html_parser_t) ?*html.lxb_html_parser_t {
    return html.lxb_html_parser_destroy(parser);
}

pub fn parse(parser: ?*html.lxb_html_parser_t, input: []const u8, size: usize) ?*html.lxb_html_document_t {
    return html.lxb_html_parse(parser, @ptrCast(input.ptr), size);
}

pub fn parseChunkBegin(parser: ?*html.lxb_html_parser_t) ?*html.lxb_html_document_t {
    return html.lxb_html_parse_chunk_begin(parser);
}

pub fn parseChunkProcess(parser: ?*html.lxb_html_parser_t, html_: []const u8, size: usize) core.lexbor_status_t {
    const status = html.lxb_html_parse_chunk_process(parser, @ptrCast(html_.ptr), size);
    return @enumFromInt(status);
}

pub fn parseChunkEnd(parser: ?*html.lxb_html_parser_t) core.lexbor_status_t {
    const status = html.lxb_html_parse_chunk_end(parser);
    return @enumFromInt(status);
}
