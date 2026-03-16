const std = @import("std");
const ComputedStyle = @import("../style/computed.zig").ComputedStyle;
const DomNode = @import("../dom/node.zig").DomNode;

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
};

pub const Edges = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,
};

pub const BoxType = enum {
    block,
    inline_text,
    anonymous_block,
    replaced,
};

pub const LineBox = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    text: []const u8,
    ascent: f32,
};

pub const ChildList = std.ArrayListUnmanaged(*Box);
pub const LineList = std.ArrayListUnmanaged(LineBox);

pub const Box = struct {
    box_type: BoxType = .block,
    content: Rect = .{},
    padding: Edges = .{},
    border: Edges = .{},
    margin: Edges = .{},
    style: ComputedStyle = .{},
    children: ChildList = .empty,
    parent: ?*Box = null,
    text: ?[]const u8 = null,
    dom_node: ?DomNode = null,
    /// URL target if this box (or ancestor) is an <a> element.
    link_url: ?[]const u8 = null,
    /// For replaced boxes (images): the image URL to load.
    image_url: ?[]const u8 = null,
    /// For replaced boxes: intrinsic width/height from attributes.
    intrinsic_width: f32 = 0,
    intrinsic_height: f32 = 0,
    /// For inline_text boxes: line-broken fragments
    lines: LineList = .empty,
    /// True if this box represents an <hr> element.
    is_hr: bool = false,
    /// For list items: the 1-based index within parent list.
    list_index: u32 = 0,

    /// Returns the margin box (content + padding + border + margin).
    pub fn marginBox(self: *const Box) Rect {
        return .{
            .x = self.content.x - self.padding.left - self.border.left - self.margin.left,
            .y = self.content.y - self.padding.top - self.border.top - self.margin.top,
            .width = self.content.width + self.padding.left + self.padding.right + self.border.left + self.border.right + self.margin.left + self.margin.right,
            .height = self.content.height + self.padding.top + self.padding.bottom + self.border.top + self.border.bottom + self.margin.top + self.margin.bottom,
        };
    }

    /// Returns the border box (content + padding + border).
    pub fn borderBox(self: *const Box) Rect {
        return .{
            .x = self.content.x - self.padding.left - self.border.left,
            .y = self.content.y - self.padding.top - self.border.top,
            .width = self.content.width + self.padding.left + self.padding.right + self.border.left + self.border.right,
            .height = self.content.height + self.padding.top + self.padding.bottom + self.border.top + self.border.bottom,
        };
    }

    /// Returns the padding box (content + padding).
    pub fn paddingBox(self: *const Box) Rect {
        return .{
            .x = self.content.x - self.padding.left,
            .y = self.content.y - self.padding.top,
            .width = self.content.width + self.padding.left + self.padding.right,
            .height = self.content.height + self.padding.top + self.padding.bottom,
        };
    }
};
