const std = @import("std");
const lxb = @import("../bindings/lexbor.zig").c;
const DomNode = @import("node.zig").DomNode;

// We use an opaque pointer for the HTML document to avoid Zig's @cImport
// dependency loop on lexbor's internal CSS selector types (which are
// recursive structs that Zig cannot resolve). Instead, we call the C
// functions via manual extern declarations.
const OpaqueHtmlDoc = anyopaque;

extern fn lxb_html_document_create() ?*OpaqueHtmlDoc;
extern fn lxb_html_document_destroy(document: ?*OpaqueHtmlDoc) ?*OpaqueHtmlDoc;
extern fn lxb_html_document_parse(document: ?*OpaqueHtmlDoc, html: [*]const u8, size: usize) lxb.lxb_status_t;

// The body field is at a known offset in lxb_html_document.
// lxb_html_document_body_element_noi is the non-inline ABI function.
extern fn lxb_html_document_body_element_noi(document: ?*OpaqueHtmlDoc) ?*lxb.lxb_dom_node_t;
extern fn lxb_html_document_head_element_noi(document: ?*OpaqueHtmlDoc) ?*lxb.lxb_dom_node_t;

pub const Document = struct {
    html_doc: *OpaqueHtmlDoc,

    /// Parse an HTML string into a Document.
    pub fn parse(html: []const u8) !Document {
        const doc = lxb_html_document_create() orelse return error.LexborDocCreateFailed;
        const status = lxb_html_document_parse(doc, html.ptr, html.len);
        if (status != 0) {
            _ = lxb_html_document_destroy(doc);
            return error.LexborParseFailed;
        }
        return Document{ .html_doc = doc };
    }

    /// Get the <body> element as a DomNode.
    pub fn body(self: Document) ?DomNode {
        const node_ptr = lxb_html_document_body_element_noi(self.html_doc);
        if (node_ptr == null) return null;
        return DomNode{ .lxb_node = node_ptr.? };
    }

    /// Get the <head> element as a DomNode.
    pub fn head(self: Document) ?DomNode {
        const node_ptr = lxb_html_document_head_element_noi(self.html_doc);
        if (node_ptr == null) return null;
        return DomNode{ .lxb_node = node_ptr.? };
    }

    /// Get the root <html> element as a DomNode.
    /// We access this via the body's parent.
    pub fn root(self: Document) ?DomNode {
        const body_node = self.body() orelse return null;
        return body_node.parent();
    }

    /// Get the document node itself.
    /// The lxb_html_document_t starts with lxb_dom_document_t which starts with lxb_dom_node_t.
    pub fn documentNode(self: Document) DomNode {
        const node_ptr: *lxb.lxb_dom_node_t = @ptrCast(@alignCast(self.html_doc));
        return DomNode{ .lxb_node = node_ptr };
    }

    pub fn deinit(self: *Document) void {
        _ = lxb_html_document_destroy(self.html_doc);
    }
};
