const std = @import("std");
const lxb = @import("../bindings/lexbor.zig").c;

pub const NodeType = enum {
    element,
    text,
    comment,
    document,
    other,
};

/// Zig wrapper around lxb_dom_node_t pointer.
pub const DomNode = struct {
    lxb_node: *lxb.lxb_dom_node_t,

    pub fn nodeType(self: DomNode) NodeType {
        return switch (self.lxb_node.type) {
            lxb.LXB_DOM_NODE_TYPE_ELEMENT => .element,
            lxb.LXB_DOM_NODE_TYPE_TEXT => .text,
            lxb.LXB_DOM_NODE_TYPE_COMMENT => .comment,
            lxb.LXB_DOM_NODE_TYPE_DOCUMENT => .document,
            else => .other,
        };
    }

    /// Returns the tag name for element nodes (lowercase, e.g. "div", "p").
    /// Uses lxb_dom_element_local_name for element nodes.
    pub fn tagName(self: DomNode) ?[]const u8 {
        if (self.nodeType() != .element) return null;
        const element: *lxb.lxb_dom_element_t = @ptrCast(self.lxb_node);
        var len: usize = 0;
        const name_ptr = lxb.lxb_dom_element_local_name(element, &len);
        if (name_ptr == null or len == 0) return null;
        return name_ptr[0..len];
    }

    /// Returns text content for text nodes.
    pub fn textContent(self: DomNode) ?[]const u8 {
        var len: usize = 0;
        const ptr = lxb.lxb_dom_node_text_content(self.lxb_node, &len);
        if (ptr == null or len == 0) return null;
        return ptr[0..len];
    }

    pub fn firstChild(self: DomNode) ?DomNode {
        const child = self.lxb_node.first_child;
        if (child == null) return null;
        return DomNode{ .lxb_node = child.? };
    }

    pub fn nextSibling(self: DomNode) ?DomNode {
        const sib = self.lxb_node.next;
        if (sib == null) return null;
        return DomNode{ .lxb_node = sib.? };
    }

    /// Returns the first child that is an element node.
    pub fn firstElementChild(self: DomNode) ?DomNode {
        var child = self.firstChild();
        while (child) |c| {
            if (c.nodeType() == .element) return c;
            child = c.nextSibling();
        }
        return null;
    }

    /// Count element children.
    pub fn childCount(self: DomNode) usize {
        var count: usize = 0;
        var child = self.firstChild();
        while (child) |c| {
            if (c.nodeType() == .element) count += 1;
            child = c.nextSibling();
        }
        return count;
    }

    pub fn parent(self: DomNode) ?DomNode {
        const p = self.lxb_node.parent;
        if (p == null) return null;
        return DomNode{ .lxb_node = p.? };
    }

    /// Get attribute value by name.
    pub fn getAttribute(self: DomNode, name: []const u8) ?[]const u8 {
        if (self.nodeType() != .element) return null;
        const element: *lxb.lxb_dom_element_t = @ptrCast(self.lxb_node);
        var value_len: usize = 0;
        const val = lxb.lxb_dom_element_get_attribute(element, name.ptr, name.len, &value_len);
        if (val == null or value_len == 0) return null;
        return val[0..value_len];
    }

    /// Returns the raw lxb_dom_node_t pointer as an opaque void pointer,
    /// useful for passing to LibCSS callbacks.
    pub fn rawPtr(self: DomNode) *anyopaque {
        return @ptrCast(self.lxb_node);
    }
};
