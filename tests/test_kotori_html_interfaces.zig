const std = @import("std");
const iface = @import("kotori_html_interfaces");

test "HTML_NS + div -> HTMLDivElement" {
    try std.testing.expectEqualStrings("HTMLDivElement",
        iface.resolveInterface(iface.HTML_NS, "div"));
}

test "HTML_NS + input -> HTMLInputElement" {
    try std.testing.expectEqualStrings("HTMLInputElement",
        iface.resolveInterface(iface.HTML_NS, "input"));
}

test "HTML_NS + xfoo -> HTMLUnknownElement" {
    try std.testing.expectEqualStrings("HTMLUnknownElement",
        iface.resolveInterface(iface.HTML_NS, "xfoo"));
}

test "HTML_NS + abbr -> HTMLElement (known-generic)" {
    try std.testing.expectEqualStrings("HTMLElement",
        iface.resolveInterface(iface.HTML_NS, "abbr"));
}

test "HTML_NS + foo-bar -> HTMLElement (valid custom name)" {
    try std.testing.expectEqualStrings("HTMLElement",
        iface.resolveInterface(iface.HTML_NS, "foo-bar"));
}

test "SVG_NS + circle -> SVGCircleElement" {
    try std.testing.expectEqualStrings("SVGCircleElement",
        iface.resolveInterface(iface.SVG_NS, "circle"));
}

test "SVG_NS + foo -> SVGElement (unknown fallback)" {
    try std.testing.expectEqualStrings("SVGElement",
        iface.resolveInterface(iface.SVG_NS, "foo"));
}

test "MATH_NS + mi -> MathMLElement (single fallback)" {
    try std.testing.expectEqualStrings("MathMLElement",
        iface.resolveInterface(iface.MATH_NS, "mi"));
}

test "null namespace -> Element" {
    try std.testing.expectEqualStrings("Element",
        iface.resolveInterface(null, "anything"));
}
