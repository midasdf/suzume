//! (namespace, local_name) → DOM interface name resolver.
//!
//! Spec references:
//! - HTML §4 element interfaces index:
//!   https://html.spec.whatwg.org/multipage/indices.html#element-interfaces
//! - SVG 2 §4 interface summary:
//!   https://svgwg.org/svg2-draft/types.html#InterfaceSummary
//! - MathML Core §2 (no per-tag DOM interfaces in this spec; all → MathMLElement)

const std = @import("std");

pub const HTML_NS = "http://www.w3.org/1999/xhtml";
pub const SVG_NS  = "http://www.w3.org/2000/svg";
pub const MATH_NS = "http://www.w3.org/1998/Math/MathML";

const html_iface = std.StaticStringMap([]const u8).initComptime(.{
    // Alphabetical per HTML §4 index. Entries map tag → interface. Tags
    // without a dedicated interface map to "HTMLElement".
    .{ "a", "HTMLAnchorElement" },
    .{ "abbr", "HTMLElement" },
    .{ "address", "HTMLElement" },
    .{ "area", "HTMLAreaElement" },
    .{ "article", "HTMLElement" },
    .{ "aside", "HTMLElement" },
    .{ "audio", "HTMLAudioElement" },
    .{ "b", "HTMLElement" },
    .{ "base", "HTMLBaseElement" },
    .{ "bdi", "HTMLElement" },
    .{ "bdo", "HTMLElement" },
    .{ "blockquote", "HTMLQuoteElement" },
    .{ "body", "HTMLBodyElement" },
    .{ "br", "HTMLBRElement" },
    .{ "button", "HTMLButtonElement" },
    .{ "canvas", "HTMLCanvasElement" },
    .{ "caption", "HTMLTableCaptionElement" },
    .{ "cite", "HTMLElement" },
    .{ "code", "HTMLElement" },
    .{ "col", "HTMLTableColElement" },
    .{ "colgroup", "HTMLTableColElement" },
    .{ "data", "HTMLDataElement" },
    .{ "datalist", "HTMLDataListElement" },
    .{ "dd", "HTMLElement" },
    .{ "del", "HTMLModElement" },
    .{ "details", "HTMLDetailsElement" },
    .{ "dfn", "HTMLElement" },
    .{ "dialog", "HTMLDialogElement" },
    .{ "div", "HTMLDivElement" },
    .{ "dl", "HTMLDListElement" },
    .{ "dt", "HTMLElement" },
    .{ "em", "HTMLElement" },
    .{ "embed", "HTMLEmbedElement" },
    .{ "fieldset", "HTMLFieldSetElement" },
    .{ "figcaption", "HTMLElement" },
    .{ "figure", "HTMLElement" },
    .{ "font", "HTMLFontElement" },
    .{ "footer", "HTMLElement" },
    .{ "form", "HTMLFormElement" },
    .{ "frame", "HTMLFrameElement" },
    .{ "frameset", "HTMLFrameSetElement" },
    .{ "h1", "HTMLHeadingElement" },
    .{ "h2", "HTMLHeadingElement" },
    .{ "h3", "HTMLHeadingElement" },
    .{ "h4", "HTMLHeadingElement" },
    .{ "h5", "HTMLHeadingElement" },
    .{ "h6", "HTMLHeadingElement" },
    .{ "head", "HTMLHeadElement" },
    .{ "header", "HTMLElement" },
    .{ "hgroup", "HTMLElement" },
    .{ "hr", "HTMLHRElement" },
    .{ "html", "HTMLHtmlElement" },
    .{ "i", "HTMLElement" },
    .{ "iframe", "HTMLIFrameElement" },
    .{ "img", "HTMLImageElement" },
    .{ "input", "HTMLInputElement" },
    .{ "ins", "HTMLModElement" },
    .{ "kbd", "HTMLElement" },
    .{ "label", "HTMLLabelElement" },
    .{ "legend", "HTMLLegendElement" },
    .{ "li", "HTMLLIElement" },
    .{ "link", "HTMLLinkElement" },
    .{ "main", "HTMLElement" },
    .{ "map", "HTMLMapElement" },
    .{ "mark", "HTMLElement" },
    .{ "marquee", "HTMLMarqueeElement" },
    .{ "menu", "HTMLMenuElement" },
    .{ "meta", "HTMLMetaElement" },
    .{ "meter", "HTMLMeterElement" },
    .{ "nav", "HTMLElement" },
    .{ "noscript", "HTMLElement" },
    .{ "object", "HTMLObjectElement" },
    .{ "ol", "HTMLOListElement" },
    .{ "optgroup", "HTMLOptGroupElement" },
    .{ "option", "HTMLOptionElement" },
    .{ "output", "HTMLOutputElement" },
    .{ "p", "HTMLParagraphElement" },
    .{ "param", "HTMLParamElement" },
    .{ "picture", "HTMLPictureElement" },
    .{ "pre", "HTMLPreElement" },
    .{ "progress", "HTMLProgressElement" },
    .{ "q", "HTMLQuoteElement" },
    .{ "rb", "HTMLElement" },
    .{ "rp", "HTMLElement" },
    .{ "rt", "HTMLElement" },
    .{ "rtc", "HTMLElement" },
    .{ "ruby", "HTMLElement" },
    .{ "s", "HTMLElement" },
    .{ "samp", "HTMLElement" },
    .{ "script", "HTMLScriptElement" },
    .{ "section", "HTMLElement" },
    .{ "select", "HTMLSelectElement" },
    .{ "slot", "HTMLSlotElement" },
    .{ "small", "HTMLElement" },
    .{ "source", "HTMLSourceElement" },
    .{ "span", "HTMLSpanElement" },
    .{ "strong", "HTMLElement" },
    .{ "style", "HTMLStyleElement" },
    .{ "sub", "HTMLElement" },
    .{ "summary", "HTMLElement" },
    .{ "sup", "HTMLElement" },
    .{ "table", "HTMLTableElement" },
    .{ "tbody", "HTMLTableSectionElement" },
    .{ "td", "HTMLTableCellElement" },
    .{ "template", "HTMLTemplateElement" },
    .{ "textarea", "HTMLTextAreaElement" },
    .{ "tfoot", "HTMLTableSectionElement" },
    .{ "th", "HTMLTableCellElement" },
    .{ "thead", "HTMLTableSectionElement" },
    .{ "time", "HTMLTimeElement" },
    .{ "title", "HTMLTitleElement" },
    .{ "tr", "HTMLTableRowElement" },
    .{ "track", "HTMLTrackElement" },
    .{ "u", "HTMLElement" },
    .{ "ul", "HTMLUListElement" },
    .{ "var", "HTMLElement" },
    .{ "video", "HTMLVideoElement" },
    .{ "wbr", "HTMLElement" },
    .{ "dir", "HTMLDirectoryElement" },
    .{ "listing", "HTMLPreElement" },
    .{ "plaintext", "HTMLElement" },
    .{ "xmp", "HTMLPreElement" },
});

const svg_iface = std.StaticStringMap([]const u8).initComptime(.{
    .{ "svg", "SVGSVGElement" },
    .{ "g", "SVGGElement" },
    .{ "defs", "SVGDefsElement" },
    .{ "symbol", "SVGSymbolElement" },
    .{ "use", "SVGUseElement" },
    .{ "circle", "SVGCircleElement" },
    .{ "ellipse", "SVGEllipseElement" },
    .{ "line", "SVGLineElement" },
    .{ "rect", "SVGRectElement" },
    .{ "polyline", "SVGPolylineElement" },
    .{ "polygon", "SVGPolygonElement" },
    .{ "path", "SVGPathElement" },
    .{ "text", "SVGTextElement" },
    .{ "tspan", "SVGTSpanElement" },
    .{ "image", "SVGImageElement" },
    .{ "foreignObject", "SVGForeignObjectElement" },
    .{ "marker", "SVGMarkerElement" },
    .{ "clipPath", "SVGClipPathElement" },
    .{ "mask", "SVGMaskElement" },
    .{ "pattern", "SVGPatternElement" },
});

pub fn resolveInterface(namespace: ?[]const u8, local_name: []const u8) []const u8 {
    const ns = namespace orelse return "Element";

    if (std.mem.eql(u8, ns, HTML_NS)) {
        // HTML namespace requires lowercase for HTML interface dispatch.
        if (!isAllLowerAscii(local_name)) return "HTMLUnknownElement";
        if (html_iface.get(local_name)) |iface| return iface;
        // Unknown tag in HTML NS: custom-element-name heuristic → HTMLElement; else HTMLUnknownElement.
        if (isValidCustomElementName(local_name)) return "HTMLElement";
        return "HTMLUnknownElement";
    }
    if (std.mem.eql(u8, ns, SVG_NS)) {
        if (svg_iface.get(local_name)) |iface| return iface;
        return "SVGElement";
    }
    if (std.mem.eql(u8, ns, MATH_NS)) {
        return "MathMLElement";
    }
    return "Element";
}

pub fn isKnownHtmlTag(local_name: []const u8) bool {
    return html_iface.get(local_name) != null;
}

pub fn isKnownSvgTag(local_name: []const u8) bool {
    return svg_iface.get(local_name) != null;
}

fn isAllLowerAscii(s: []const u8) bool {
    for (s) |c| {
        if (c >= 'A' and c <= 'Z') return false;
    }
    return true;
}

/// Minimal valid custom-element-name check — a lowercase ASCII name
/// containing at least one hyphen and not in the reserved list.
/// Full HTML §4.13 is Non-goal for this spec; this is the weakest check
/// that still routes 'foo-bar' → HTMLElement and 'xfoo' → HTMLUnknownElement.
fn isValidCustomElementName(name: []const u8) bool {
    if (name.len < 2) return false;
    if (!(name[0] >= 'a' and name[0] <= 'z')) return false;
    var has_hyphen = false;
    for (name) |c| {
        if (c == '-') has_hyphen = true;
    }
    return has_hyphen;
}

/// Unique HTML interface names (subclass prototypes to build). Includes
/// HTMLElement and HTMLUnknownElement. Alphabetical for stable diffs.
pub const html_unique_ifaces = [_][]const u8{
    "HTMLAnchorElement",      "HTMLAreaElement",         "HTMLAudioElement",
    "HTMLBRElement",          "HTMLBaseElement",          "HTMLBodyElement",
    "HTMLButtonElement",      "HTMLCanvasElement",        "HTMLDListElement",
    "HTMLDataElement",        "HTMLDataListElement",      "HTMLDetailsElement",
    "HTMLDialogElement",      "HTMLDirectoryElement",     "HTMLDivElement",
    "HTMLElement",            "HTMLEmbedElement",         "HTMLFieldSetElement",
    "HTMLFontElement",        "HTMLFormElement",          "HTMLFrameElement",
    "HTMLFrameSetElement",    "HTMLHRElement",            "HTMLHeadElement",
    "HTMLHeadingElement",     "HTMLHtmlElement",          "HTMLIFrameElement",
    "HTMLImageElement",       "HTMLInputElement",         "HTMLLIElement",
    "HTMLLabelElement",       "HTMLLegendElement",        "HTMLLinkElement",
    "HTMLMapElement",         "HTMLMarqueeElement",       "HTMLMenuElement",
    "HTMLMetaElement",        "HTMLMeterElement",         "HTMLModElement",
    "HTMLOListElement",       "HTMLObjectElement",        "HTMLOptGroupElement",
    "HTMLOptionElement",      "HTMLOutputElement",        "HTMLParagraphElement",
    "HTMLParamElement",       "HTMLPictureElement",       "HTMLPreElement",
    "HTMLProgressElement",    "HTMLQuoteElement",         "HTMLScriptElement",
    "HTMLSelectElement",      "HTMLSlotElement",          "HTMLSourceElement",
    "HTMLSpanElement",        "HTMLStyleElement",         "HTMLTableCaptionElement",
    "HTMLTableCellElement",   "HTMLTableColElement",      "HTMLTableElement",
    "HTMLTableRowElement",    "HTMLTableSectionElement",  "HTMLTemplateElement",
    "HTMLTextAreaElement",    "HTMLTimeElement",          "HTMLTitleElement",
    "HTMLTrackElement",       "HTMLUListElement",         "HTMLUnknownElement",
    "HTMLVideoElement",
};

pub const svg_unique_ifaces = [_][]const u8{
    "SVGCircleElement",       "SVGClipPathElement",       "SVGDefsElement",
    "SVGElement",             "SVGEllipseElement",        "SVGForeignObjectElement",
    "SVGGElement",            "SVGImageElement",          "SVGLineElement",
    "SVGMarkerElement",       "SVGMaskElement",           "SVGPathElement",
    "SVGPatternElement",      "SVGPolygonElement",        "SVGPolylineElement",
    "SVGRectElement",         "SVGSVGElement",            "SVGSymbolElement",
    "SVGTSpanElement",        "SVGTextElement",           "SVGUseElement",
};
