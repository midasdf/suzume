// Lexbor DOM C bindings via @cImport
// Note: We deliberately avoid including lexbor/html/parser.h and
// lexbor/html/interfaces/document.h because they pull in lexbor/css/css.h
// which causes a dependency loop in Zig's @cImport type resolution.
// For HTML document parsing, tree.zig uses manual extern declarations.
pub const c = @cImport({
    @cDefine("LEXBOR_STATIC", "");
    @cInclude("lexbor/dom/interfaces/element.h");
    @cInclude("lexbor/dom/interfaces/node.h");
});
