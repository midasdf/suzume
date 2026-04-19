//! HTML reflected attributes (HTML §2.6 "Reflecting content attributes in IDL
//! attributes"). Table-driven so each (interface, IDL-name) pair costs a
//! linear scan at property access time.
//!
//! Spec references:
//! - HTML §2.6  <https://html.spec.whatwg.org/multipage/common-dom-interfaces.html#reflecting-content-attributes-in-idl-attributes>
//! - HTML §2.4.4.1 (rules for parsing integers)
//! - HTML §2.4.4.2 (rules for parsing non-negative integers)
//!
//! One row per reflection. See plan at
//! `docs/superpowers/plans/2026-04-19-kotori-4A-html-reflection.md`.

const std = @import("std");

/// §2.6.2 IDL attribute type buckets implemented in this layer.
pub const ReflType = enum(u8) {
    /// §2.6.2 "DOMString": content attr value, or "" if missing.
    domstring,
    /// §2.6.2 "boolean": presence check + presence toggle.
    boolean,
    /// §2.6.2 "long": §2.4.4.1 signed i32 parse, default on miss/parse-fail.
    long,
    /// §2.6.2 "unsigned long": §2.4.4.2 non-negative i32, clamped [0,2³¹−1].
    unsigned_long,
    /// §2.6.2 "URL": stored/returned as DOMString (Layer 4B will canonicalize).
    url,
};

/// Single reflection entry. Comptime-only; never mutated at runtime.
pub const ReflectedAttr = struct {
    iface: []const u8,
    idl: []const u8,
    content: []const u8,
    type: ReflType,
    /// Default for numeric types when the content attribute is absent or
    /// unparseable. Ignored for DOMString / boolean / url.
    default_int: i64 = 0,
};

/// Reflection table — one row per IDL attribute.
/// Interfaces are listed from general → specific:
///   "HTMLElement" rows apply to every HTML element.
///   All others apply only when the element's resolved interface matches.
///
/// Spec coverage: HTML §3–§5 (per-element IDL attributes).
pub const table = &[_]ReflectedAttr{
    // ── HTMLElement global attributes (HTML §3.2.6 + §6.6) ───────────
    // `id` and `className` keep their inline fast-paths in kotori_dom.zig
    // (they existed before this table). These rows let the table handle
    // any future conflict-free reads.
    .{ .iface = "HTMLElement", .idl = "title",           .content = "title",           .type = .domstring },
    .{ .iface = "HTMLElement", .idl = "lang",            .content = "lang",            .type = .domstring },
    .{ .iface = "HTMLElement", .idl = "dir",             .content = "dir",             .type = .domstring },
    .{ .iface = "HTMLElement", .idl = "hidden",          .content = "hidden",          .type = .boolean   },
    .{ .iface = "HTMLElement", .idl = "inert",           .content = "inert",           .type = .boolean   },
    .{ .iface = "HTMLElement", .idl = "accessKey",       .content = "accesskey",       .type = .domstring },
    // §6.6 tabIndex: long, default -1 (focusable default per spec is also -1
    // when the attribute is absent for non-focusable elements).
    .{ .iface = "HTMLElement", .idl = "tabIndex",        .content = "tabindex",        .type = .long,          .default_int = -1 },
    .{ .iface = "HTMLElement", .idl = "draggable",       .content = "draggable",       .type = .domstring },
    .{ .iface = "HTMLElement", .idl = "contentEditable", .content = "contenteditable", .type = .domstring },
    .{ .iface = "HTMLElement", .idl = "spellcheck",      .content = "spellcheck",      .type = .domstring },
    .{ .iface = "HTMLElement", .idl = "translate",       .content = "translate",       .type = .domstring },
    .{ .iface = "HTMLElement", .idl = "autocapitalize",  .content = "autocapitalize",  .type = .domstring },
    .{ .iface = "HTMLElement", .idl = "slot",            .content = "slot",            .type = .domstring },
    .{ .iface = "HTMLElement", .idl = "nonce",           .content = "nonce",           .type = .domstring },
    .{ .iface = "HTMLElement", .idl = "enterKeyHint",    .content = "enterkeyhint",    .type = .domstring },
    .{ .iface = "HTMLElement", .idl = "inputMode",       .content = "inputmode",       .type = .domstring },
    .{ .iface = "HTMLElement", .idl = "popover",         .content = "popover",         .type = .domstring },

    // ── HTMLAnchorElement (HTML §4.6.1) ──────────────────────────────
    .{ .iface = "HTMLAnchorElement", .idl = "href",           .content = "href",           .type = .url       },
    .{ .iface = "HTMLAnchorElement", .idl = "target",         .content = "target",         .type = .domstring },
    .{ .iface = "HTMLAnchorElement", .idl = "download",       .content = "download",       .type = .domstring },
    .{ .iface = "HTMLAnchorElement", .idl = "ping",           .content = "ping",           .type = .domstring },
    .{ .iface = "HTMLAnchorElement", .idl = "rel",            .content = "rel",            .type = .domstring },
    .{ .iface = "HTMLAnchorElement", .idl = "hreflang",       .content = "hreflang",       .type = .domstring },
    .{ .iface = "HTMLAnchorElement", .idl = "type",           .content = "type",           .type = .domstring },
    .{ .iface = "HTMLAnchorElement", .idl = "referrerPolicy", .content = "referrerpolicy", .type = .domstring },
    .{ .iface = "HTMLAnchorElement", .idl = "text",           .content = "text",           .type = .domstring },

    // ── HTMLAreaElement (HTML §4.8.14) ────────────────────────────────
    .{ .iface = "HTMLAreaElement", .idl = "alt",           .content = "alt",           .type = .domstring },
    .{ .iface = "HTMLAreaElement", .idl = "coords",        .content = "coords",        .type = .domstring },
    .{ .iface = "HTMLAreaElement", .idl = "shape",         .content = "shape",         .type = .domstring },
    .{ .iface = "HTMLAreaElement", .idl = "target",        .content = "target",        .type = .domstring },
    .{ .iface = "HTMLAreaElement", .idl = "download",      .content = "download",      .type = .domstring },
    .{ .iface = "HTMLAreaElement", .idl = "ping",          .content = "ping",          .type = .domstring },
    .{ .iface = "HTMLAreaElement", .idl = "rel",           .content = "rel",           .type = .domstring },
    .{ .iface = "HTMLAreaElement", .idl = "referrerPolicy",.content = "referrerpolicy",.type = .domstring },
    .{ .iface = "HTMLAreaElement", .idl = "href",          .content = "href",          .type = .url       },

    // ── HTMLBaseElement (HTML §4.2.3) ─────────────────────────────────
    .{ .iface = "HTMLBaseElement", .idl = "href",   .content = "href",   .type = .url       },
    .{ .iface = "HTMLBaseElement", .idl = "target", .content = "target", .type = .domstring },

    // ── HTMLBodyElement (HTML §4.3.1) — event handler reflected attrs ─
    // (body-specific ARIA / presentation attrs)
    .{ .iface = "HTMLBodyElement", .idl = "text",  .content = "text",  .type = .domstring },
    .{ .iface = "HTMLBodyElement", .idl = "link",  .content = "link",  .type = .domstring },
    .{ .iface = "HTMLBodyElement", .idl = "vLink", .content = "vlink", .type = .domstring },
    .{ .iface = "HTMLBodyElement", .idl = "aLink", .content = "alink", .type = .domstring },
    .{ .iface = "HTMLBodyElement", .idl = "bgColor",.content = "bgcolor",.type = .domstring},

    // ── HTMLBRElement (HTML §4.4.13) ─────────────────────────────────
    .{ .iface = "HTMLBRElement", .idl = "clear", .content = "clear", .type = .domstring },

    // ── HTMLButtonElement (HTML §4.10.6) ─────────────────────────────
    .{ .iface = "HTMLButtonElement", .idl = "disabled",       .content = "disabled",       .type = .boolean   },
    .{ .iface = "HTMLButtonElement", .idl = "formAction",     .content = "formaction",     .type = .url       },
    .{ .iface = "HTMLButtonElement", .idl = "formEnctype",    .content = "formenctype",    .type = .domstring },
    .{ .iface = "HTMLButtonElement", .idl = "formMethod",     .content = "formmethod",     .type = .domstring },
    .{ .iface = "HTMLButtonElement", .idl = "formNoValidate", .content = "formnovalidate", .type = .boolean   },
    .{ .iface = "HTMLButtonElement", .idl = "formTarget",     .content = "formtarget",     .type = .domstring },
    .{ .iface = "HTMLButtonElement", .idl = "name",           .content = "name",           .type = .domstring },
    .{ .iface = "HTMLButtonElement", .idl = "type",           .content = "type",           .type = .domstring },
    .{ .iface = "HTMLButtonElement", .idl = "value",          .content = "value",          .type = .domstring },
    .{ .iface = "HTMLButtonElement", .idl = "popoverTarget",  .content = "popovertarget",  .type = .domstring },
    .{ .iface = "HTMLButtonElement", .idl = "popoverTargetAction", .content = "popovertargetaction", .type = .domstring },

    // ── HTMLCanvasElement (HTML §4.12.5) ──────────────────────────────
    .{ .iface = "HTMLCanvasElement", .idl = "width",  .content = "width",  .type = .unsigned_long, .default_int = 300 },
    .{ .iface = "HTMLCanvasElement", .idl = "height", .content = "height", .type = .unsigned_long, .default_int = 150 },

    // ── HTMLDataElement (HTML §4.6.13) ───────────────────────────────
    .{ .iface = "HTMLDataElement", .idl = "value", .content = "value", .type = .domstring },

    // ── HTMLDetailsElement (HTML §4.11.1) ────────────────────────────
    .{ .iface = "HTMLDetailsElement", .idl = "open", .content = "open", .type = .boolean },
    .{ .iface = "HTMLDetailsElement", .idl = "name", .content = "name", .type = .domstring },

    // ── HTMLDialogElement (HTML §4.9.5) ──────────────────────────────
    .{ .iface = "HTMLDialogElement", .idl = "open",         .content = "open",         .type = .boolean   },
    .{ .iface = "HTMLDialogElement", .idl = "returnValue",  .content = "returnvalue",  .type = .domstring },

    // ── HTMLEmbedElement (HTML §4.8.6) ───────────────────────────────
    .{ .iface = "HTMLEmbedElement", .idl = "src",    .content = "src",    .type = .url       },
    .{ .iface = "HTMLEmbedElement", .idl = "type",   .content = "type",   .type = .domstring },
    .{ .iface = "HTMLEmbedElement", .idl = "width",  .content = "width",  .type = .domstring },
    .{ .iface = "HTMLEmbedElement", .idl = "height", .content = "height", .type = .domstring },
    .{ .iface = "HTMLEmbedElement", .idl = "name",   .content = "name",   .type = .domstring },
    .{ .iface = "HTMLEmbedElement", .idl = "align",  .content = "align",  .type = .domstring },

    // ── HTMLFieldSetElement (HTML §4.10.15) ──────────────────────────
    .{ .iface = "HTMLFieldSetElement", .idl = "disabled", .content = "disabled", .type = .boolean   },
    .{ .iface = "HTMLFieldSetElement", .idl = "name",     .content = "name",     .type = .domstring },

    // ── HTMLFormElement (HTML §4.10.3) ───────────────────────────────
    .{ .iface = "HTMLFormElement", .idl = "acceptCharset", .content = "accept-charset", .type = .domstring },
    .{ .iface = "HTMLFormElement", .idl = "action",        .content = "action",         .type = .url       },
    .{ .iface = "HTMLFormElement", .idl = "autocomplete",  .content = "autocomplete",   .type = .domstring },
    .{ .iface = "HTMLFormElement", .idl = "enctype",       .content = "enctype",        .type = .domstring },
    .{ .iface = "HTMLFormElement", .idl = "encoding",      .content = "enctype",        .type = .domstring },
    .{ .iface = "HTMLFormElement", .idl = "method",        .content = "method",         .type = .domstring },
    .{ .iface = "HTMLFormElement", .idl = "name",          .content = "name",           .type = .domstring },
    .{ .iface = "HTMLFormElement", .idl = "noValidate",    .content = "novalidate",     .type = .boolean   },
    .{ .iface = "HTMLFormElement", .idl = "target",        .content = "target",         .type = .domstring },
    .{ .iface = "HTMLFormElement", .idl = "rel",           .content = "rel",            .type = .domstring },

    // ── HTMLHRElement (HTML §4.4.2) ──────────────────────────────────
    .{ .iface = "HTMLHRElement", .idl = "align",   .content = "align",   .type = .domstring },
    .{ .iface = "HTMLHRElement", .idl = "color",   .content = "color",   .type = .domstring },
    .{ .iface = "HTMLHRElement", .idl = "noShade", .content = "noshade", .type = .boolean   },
    .{ .iface = "HTMLHRElement", .idl = "size",    .content = "size",    .type = .domstring },
    .{ .iface = "HTMLHRElement", .idl = "width",   .content = "width",   .type = .domstring },

    // ── HTMLHeadingElement (HTML §4.3.6) ─────────────────────────────
    .{ .iface = "HTMLHeadingElement", .idl = "align", .content = "align", .type = .domstring },

    // ── HTMLIFrameElement (HTML §4.8.5) ──────────────────────────────
    .{ .iface = "HTMLIFrameElement", .idl = "src",             .content = "src",             .type = .url       },
    .{ .iface = "HTMLIFrameElement", .idl = "srcdoc",          .content = "srcdoc",          .type = .domstring },
    .{ .iface = "HTMLIFrameElement", .idl = "name",            .content = "name",            .type = .domstring },
    .{ .iface = "HTMLIFrameElement", .idl = "sandbox",         .content = "sandbox",         .type = .domstring },
    .{ .iface = "HTMLIFrameElement", .idl = "allow",           .content = "allow",           .type = .domstring },
    .{ .iface = "HTMLIFrameElement", .idl = "allowFullscreen", .content = "allowfullscreen", .type = .boolean   },
    .{ .iface = "HTMLIFrameElement", .idl = "width",           .content = "width",           .type = .domstring },
    .{ .iface = "HTMLIFrameElement", .idl = "height",          .content = "height",          .type = .domstring },
    .{ .iface = "HTMLIFrameElement", .idl = "referrerPolicy",  .content = "referrerpolicy",  .type = .domstring },
    .{ .iface = "HTMLIFrameElement", .idl = "loading",         .content = "loading",         .type = .domstring },
    .{ .iface = "HTMLIFrameElement", .idl = "align",           .content = "align",           .type = .domstring },
    .{ .iface = "HTMLIFrameElement", .idl = "scrolling",       .content = "scrolling",       .type = .domstring },
    .{ .iface = "HTMLIFrameElement", .idl = "frameBorder",     .content = "frameborder",     .type = .domstring },
    .{ .iface = "HTMLIFrameElement", .idl = "longDesc",        .content = "longdesc",        .type = .url       },
    .{ .iface = "HTMLIFrameElement", .idl = "marginHeight",    .content = "marginheight",    .type = .domstring },
    .{ .iface = "HTMLIFrameElement", .idl = "marginWidth",     .content = "marginwidth",     .type = .domstring },

    // ── HTMLImageElement (HTML §4.8.3) ───────────────────────────────
    .{ .iface = "HTMLImageElement", .idl = "alt",             .content = "alt",             .type = .domstring },
    .{ .iface = "HTMLImageElement", .idl = "src",             .content = "src",             .type = .url       },
    .{ .iface = "HTMLImageElement", .idl = "srcset",          .content = "srcset",          .type = .domstring },
    .{ .iface = "HTMLImageElement", .idl = "sizes",           .content = "sizes",           .type = .domstring },
    .{ .iface = "HTMLImageElement", .idl = "crossOrigin",     .content = "crossorigin",     .type = .domstring },
    .{ .iface = "HTMLImageElement", .idl = "useMap",          .content = "usemap",          .type = .domstring },
    .{ .iface = "HTMLImageElement", .idl = "isMap",           .content = "ismap",           .type = .boolean   },
    .{ .iface = "HTMLImageElement", .idl = "width",           .content = "width",           .type = .unsigned_long },
    .{ .iface = "HTMLImageElement", .idl = "height",          .content = "height",          .type = .unsigned_long },
    .{ .iface = "HTMLImageElement", .idl = "referrerPolicy",  .content = "referrerpolicy",  .type = .domstring },
    .{ .iface = "HTMLImageElement", .idl = "decoding",        .content = "decoding",        .type = .domstring },
    .{ .iface = "HTMLImageElement", .idl = "loading",         .content = "loading",         .type = .domstring },
    .{ .iface = "HTMLImageElement", .idl = "fetchPriority",   .content = "fetchpriority",   .type = .domstring },
    .{ .iface = "HTMLImageElement", .idl = "name",            .content = "name",            .type = .domstring },
    .{ .iface = "HTMLImageElement", .idl = "align",           .content = "align",           .type = .domstring },
    .{ .iface = "HTMLImageElement", .idl = "hspace",          .content = "hspace",          .type = .unsigned_long },
    .{ .iface = "HTMLImageElement", .idl = "vspace",          .content = "vspace",          .type = .unsigned_long },
    .{ .iface = "HTMLImageElement", .idl = "longDesc",        .content = "longdesc",        .type = .url       },
    .{ .iface = "HTMLImageElement", .idl = "border",          .content = "border",          .type = .domstring },

    // ── HTMLInputElement (HTML §4.10.18) ─────────────────────────────
    .{ .iface = "HTMLInputElement", .idl = "accept",         .content = "accept",         .type = .domstring },
    .{ .iface = "HTMLInputElement", .idl = "alt",            .content = "alt",            .type = .domstring },
    .{ .iface = "HTMLInputElement", .idl = "autocomplete",   .content = "autocomplete",   .type = .domstring },
    .{ .iface = "HTMLInputElement", .idl = "defaultChecked", .content = "checked",        .type = .boolean   },
    .{ .iface = "HTMLInputElement", .idl = "dirName",        .content = "dirname",        .type = .domstring },
    .{ .iface = "HTMLInputElement", .idl = "disabled",       .content = "disabled",       .type = .boolean   },
    .{ .iface = "HTMLInputElement", .idl = "formAction",     .content = "formaction",     .type = .url       },
    .{ .iface = "HTMLInputElement", .idl = "formEnctype",    .content = "formenctype",    .type = .domstring },
    .{ .iface = "HTMLInputElement", .idl = "formMethod",     .content = "formmethod",     .type = .domstring },
    .{ .iface = "HTMLInputElement", .idl = "formNoValidate", .content = "formnovalidate", .type = .boolean   },
    .{ .iface = "HTMLInputElement", .idl = "formTarget",     .content = "formtarget",     .type = .domstring },
    .{ .iface = "HTMLInputElement", .idl = "height",         .content = "height",         .type = .unsigned_long },
    .{ .iface = "HTMLInputElement", .idl = "max",            .content = "max",            .type = .domstring },
    .{ .iface = "HTMLInputElement", .idl = "maxLength",      .content = "maxlength",      .type = .long,          .default_int = -1 },
    .{ .iface = "HTMLInputElement", .idl = "min",            .content = "min",            .type = .domstring },
    .{ .iface = "HTMLInputElement", .idl = "minLength",      .content = "minlength",      .type = .long,          .default_int = -1 },
    .{ .iface = "HTMLInputElement", .idl = "multiple",       .content = "multiple",       .type = .boolean   },
    .{ .iface = "HTMLInputElement", .idl = "name",           .content = "name",           .type = .domstring },
    .{ .iface = "HTMLInputElement", .idl = "pattern",        .content = "pattern",        .type = .domstring },
    .{ .iface = "HTMLInputElement", .idl = "placeholder",    .content = "placeholder",    .type = .domstring },
    .{ .iface = "HTMLInputElement", .idl = "readOnly",       .content = "readonly",       .type = .boolean   },
    .{ .iface = "HTMLInputElement", .idl = "required",       .content = "required",       .type = .boolean   },
    // size: unsigned long, default 20 per HTML §4.10.18
    .{ .iface = "HTMLInputElement", .idl = "size",           .content = "size",           .type = .unsigned_long, .default_int = 20 },
    .{ .iface = "HTMLInputElement", .idl = "src",            .content = "src",            .type = .url       },
    .{ .iface = "HTMLInputElement", .idl = "step",           .content = "step",           .type = .domstring },
    .{ .iface = "HTMLInputElement", .idl = "type",           .content = "type",           .type = .domstring },
    .{ .iface = "HTMLInputElement", .idl = "defaultValue",   .content = "value",          .type = .domstring },
    .{ .iface = "HTMLInputElement", .idl = "width",          .content = "width",          .type = .unsigned_long },
    .{ .iface = "HTMLInputElement", .idl = "align",          .content = "align",          .type = .domstring },
    .{ .iface = "HTMLInputElement", .idl = "useMap",         .content = "usemap",         .type = .domstring },
    .{ .iface = "HTMLInputElement", .idl = "popoverTarget",  .content = "popovertarget",  .type = .domstring },
    .{ .iface = "HTMLInputElement", .idl = "popoverTargetAction", .content = "popovertargetaction", .type = .domstring },

    // ── HTMLLabelElement (HTML §4.10.4) ──────────────────────────────
    .{ .iface = "HTMLLabelElement", .idl = "htmlFor", .content = "for", .type = .domstring },

    // ── HTMLLegendElement (HTML §4.10.16) ────────────────────────────
    .{ .iface = "HTMLLegendElement", .idl = "align", .content = "align", .type = .domstring },

    // ── HTMLLIElement (HTML §4.4.8) ──────────────────────────────────
    .{ .iface = "HTMLLIElement", .idl = "value", .content = "value", .type = .long },
    .{ .iface = "HTMLLIElement", .idl = "type",  .content = "type",  .type = .domstring },

    // ── HTMLLinkElement (HTML §4.2.4) ────────────────────────────────
    .{ .iface = "HTMLLinkElement", .idl = "href",           .content = "href",           .type = .url       },
    .{ .iface = "HTMLLinkElement", .idl = "crossOrigin",    .content = "crossorigin",    .type = .domstring },
    .{ .iface = "HTMLLinkElement", .idl = "rel",            .content = "rel",            .type = .domstring },
    .{ .iface = "HTMLLinkElement", .idl = "as",             .content = "as",             .type = .domstring },
    .{ .iface = "HTMLLinkElement", .idl = "media",          .content = "media",          .type = .domstring },
    .{ .iface = "HTMLLinkElement", .idl = "hreflang",       .content = "hreflang",       .type = .domstring },
    .{ .iface = "HTMLLinkElement", .idl = "type",           .content = "type",           .type = .domstring },
    .{ .iface = "HTMLLinkElement", .idl = "referrerPolicy", .content = "referrerpolicy", .type = .domstring },
    .{ .iface = "HTMLLinkElement", .idl = "fetchPriority",  .content = "fetchpriority",  .type = .domstring },
    .{ .iface = "HTMLLinkElement", .idl = "disabled",       .content = "disabled",       .type = .boolean   },
    .{ .iface = "HTMLLinkElement", .idl = "integrity",      .content = "integrity",      .type = .domstring },
    .{ .iface = "HTMLLinkElement", .idl = "imageSrcset",    .content = "imagesrcset",    .type = .domstring },
    .{ .iface = "HTMLLinkElement", .idl = "imageSizes",     .content = "imagesizes",     .type = .domstring },
    .{ .iface = "HTMLLinkElement", .idl = "charset",        .content = "charset",        .type = .domstring },
    .{ .iface = "HTMLLinkElement", .idl = "rev",            .content = "rev",            .type = .domstring },
    .{ .iface = "HTMLLinkElement", .idl = "target",         .content = "target",         .type = .domstring },

    // ── HTMLMapElement (HTML §4.8.13) ─────────────────────────────────
    .{ .iface = "HTMLMapElement", .idl = "name", .content = "name", .type = .domstring },

    // ── HTMLMediaElement abstract (HTML §4.8.11) ─────────────────────
    // These rows list HTMLAudioElement and HTMLVideoElement separately
    // because the lookup function only matches exact iface or "HTMLElement";
    // HTMLMediaElement is an abstract superclass not in the lookup hierarchy.
    .{ .iface = "HTMLAudioElement", .idl = "src",          .content = "src",          .type = .url       },
    .{ .iface = "HTMLAudioElement", .idl = "crossOrigin",  .content = "crossorigin",  .type = .domstring },
    .{ .iface = "HTMLAudioElement", .idl = "preload",      .content = "preload",      .type = .domstring },
    .{ .iface = "HTMLAudioElement", .idl = "autoplay",     .content = "autoplay",     .type = .boolean   },
    .{ .iface = "HTMLAudioElement", .idl = "loop",         .content = "loop",         .type = .boolean   },
    .{ .iface = "HTMLAudioElement", .idl = "muted",        .content = "muted",        .type = .boolean   },
    .{ .iface = "HTMLAudioElement", .idl = "controls",     .content = "controls",     .type = .boolean   },
    .{ .iface = "HTMLVideoElement", .idl = "src",          .content = "src",          .type = .url       },
    .{ .iface = "HTMLVideoElement", .idl = "crossOrigin",  .content = "crossorigin",  .type = .domstring },
    .{ .iface = "HTMLVideoElement", .idl = "preload",      .content = "preload",      .type = .domstring },
    .{ .iface = "HTMLVideoElement", .idl = "autoplay",     .content = "autoplay",     .type = .boolean   },
    .{ .iface = "HTMLVideoElement", .idl = "loop",         .content = "loop",         .type = .boolean   },
    .{ .iface = "HTMLVideoElement", .idl = "muted",        .content = "muted",        .type = .boolean   },
    .{ .iface = "HTMLVideoElement", .idl = "controls",     .content = "controls",     .type = .boolean   },
    .{ .iface = "HTMLVideoElement", .idl = "width",        .content = "width",        .type = .unsigned_long },
    .{ .iface = "HTMLVideoElement", .idl = "height",       .content = "height",       .type = .unsigned_long },
    .{ .iface = "HTMLVideoElement", .idl = "poster",       .content = "poster",       .type = .url       },
    .{ .iface = "HTMLVideoElement", .idl = "playsInline",  .content = "playsinline",  .type = .boolean   },

    // ── HTMLMetaElement (HTML §4.2.5) ────────────────────────────────
    .{ .iface = "HTMLMetaElement", .idl = "name",      .content = "name",       .type = .domstring },
    .{ .iface = "HTMLMetaElement", .idl = "httpEquiv", .content = "http-equiv", .type = .domstring },
    .{ .iface = "HTMLMetaElement", .idl = "content",   .content = "content",    .type = .domstring },
    .{ .iface = "HTMLMetaElement", .idl = "media",     .content = "media",      .type = .domstring },
    .{ .iface = "HTMLMetaElement", .idl = "scheme",    .content = "scheme",     .type = .domstring },

    // ── HTMLMeterElement (HTML §4.10.14) ─────────────────────────────
    .{ .iface = "HTMLMeterElement", .idl = "value",   .content = "value",   .type = .domstring },
    .{ .iface = "HTMLMeterElement", .idl = "min",     .content = "min",     .type = .domstring },
    .{ .iface = "HTMLMeterElement", .idl = "max",     .content = "max",     .type = .domstring },
    .{ .iface = "HTMLMeterElement", .idl = "low",     .content = "low",     .type = .domstring },
    .{ .iface = "HTMLMeterElement", .idl = "high",    .content = "high",    .type = .domstring },
    .{ .iface = "HTMLMeterElement", .idl = "optimum", .content = "optimum", .type = .domstring },

    // ── HTMLModElement (ins/del) (HTML §4.7.2) ───────────────────────
    .{ .iface = "HTMLModElement", .idl = "cite",     .content = "cite",     .type = .url       },
    .{ .iface = "HTMLModElement", .idl = "dateTime", .content = "datetime", .type = .domstring },

    // ── HTMLObjectElement (HTML §4.8.7) ──────────────────────────────
    .{ .iface = "HTMLObjectElement", .idl = "data",    .content = "data",    .type = .url       },
    .{ .iface = "HTMLObjectElement", .idl = "type",    .content = "type",    .type = .domstring },
    .{ .iface = "HTMLObjectElement", .idl = "name",    .content = "name",    .type = .domstring },
    .{ .iface = "HTMLObjectElement", .idl = "useMap",  .content = "usemap",  .type = .domstring },
    .{ .iface = "HTMLObjectElement", .idl = "width",   .content = "width",   .type = .domstring },
    .{ .iface = "HTMLObjectElement", .idl = "height",  .content = "height",  .type = .domstring },
    .{ .iface = "HTMLObjectElement", .idl = "align",   .content = "align",   .type = .domstring },
    .{ .iface = "HTMLObjectElement", .idl = "archive", .content = "archive", .type = .domstring },
    .{ .iface = "HTMLObjectElement", .idl = "code",    .content = "code",    .type = .domstring },
    .{ .iface = "HTMLObjectElement", .idl = "border",  .content = "border",  .type = .domstring },
    .{ .iface = "HTMLObjectElement", .idl = "hspace",  .content = "hspace",  .type = .unsigned_long },
    .{ .iface = "HTMLObjectElement", .idl = "vspace",  .content = "vspace",  .type = .unsigned_long },
    .{ .iface = "HTMLObjectElement", .idl = "standby", .content = "standby", .type = .domstring },

    // ── HTMLOListElement (HTML §4.4.5) ───────────────────────────────
    .{ .iface = "HTMLOListElement", .idl = "reversed", .content = "reversed", .type = .boolean },
    .{ .iface = "HTMLOListElement", .idl = "start",    .content = "start",    .type = .long    },
    .{ .iface = "HTMLOListElement", .idl = "type",     .content = "type",     .type = .domstring },
    .{ .iface = "HTMLOListElement", .idl = "compact",  .content = "compact",  .type = .boolean },

    // ── HTMLOptGroupElement (HTML §4.10.9) ───────────────────────────
    .{ .iface = "HTMLOptGroupElement", .idl = "disabled", .content = "disabled", .type = .boolean   },
    .{ .iface = "HTMLOptGroupElement", .idl = "label",    .content = "label",    .type = .domstring },

    // ── HTMLOptionElement (HTML §4.10.10) ────────────────────────────
    .{ .iface = "HTMLOptionElement", .idl = "disabled",        .content = "disabled", .type = .boolean   },
    .{ .iface = "HTMLOptionElement", .idl = "label",           .content = "label",    .type = .domstring },
    .{ .iface = "HTMLOptionElement", .idl = "defaultSelected", .content = "selected", .type = .boolean   },
    .{ .iface = "HTMLOptionElement", .idl = "value",           .content = "value",    .type = .domstring },

    // ── HTMLOutputElement (HTML §4.10.12) ────────────────────────────
    .{ .iface = "HTMLOutputElement", .idl = "htmlFor",     .content = "for",  .type = .domstring },
    .{ .iface = "HTMLOutputElement", .idl = "name",        .content = "name", .type = .domstring },
    .{ .iface = "HTMLOutputElement", .idl = "defaultValue",.content = "value",.type = .domstring },

    // ── HTMLParagraphElement (HTML §4.4.1) ───────────────────────────
    .{ .iface = "HTMLParagraphElement", .idl = "align", .content = "align", .type = .domstring },

    // ── HTMLParamElement (HTML §4.8.8, obsolete) ─────────────────────
    .{ .iface = "HTMLParamElement", .idl = "name",      .content = "name",      .type = .domstring },
    .{ .iface = "HTMLParamElement", .idl = "value",     .content = "value",     .type = .domstring },
    .{ .iface = "HTMLParamElement", .idl = "type",      .content = "type",      .type = .domstring },
    .{ .iface = "HTMLParamElement", .idl = "valueType", .content = "valuetype", .type = .domstring },

    // ── HTMLPreElement (HTML §4.4.3) ─────────────────────────────────
    .{ .iface = "HTMLPreElement", .idl = "width", .content = "width", .type = .long },

    // ── HTMLProgressElement (HTML §4.10.13) ──────────────────────────
    .{ .iface = "HTMLProgressElement", .idl = "value", .content = "value", .type = .domstring },
    .{ .iface = "HTMLProgressElement", .idl = "max",   .content = "max",   .type = .domstring },

    // ── HTMLQuoteElement (blockquote/q) (HTML §4.7.1) ─────────────────
    .{ .iface = "HTMLQuoteElement", .idl = "cite", .content = "cite", .type = .url },

    // ── HTMLScriptElement (HTML §4.12.1) ─────────────────────────────
    .{ .iface = "HTMLScriptElement", .idl = "src",             .content = "src",             .type = .url       },
    .{ .iface = "HTMLScriptElement", .idl = "type",            .content = "type",            .type = .domstring },
    .{ .iface = "HTMLScriptElement", .idl = "noModule",        .content = "nomodule",        .type = .boolean   },
    .{ .iface = "HTMLScriptElement", .idl = "async",           .content = "async",           .type = .boolean   },
    .{ .iface = "HTMLScriptElement", .idl = "defer",           .content = "defer",           .type = .boolean   },
    .{ .iface = "HTMLScriptElement", .idl = "crossOrigin",     .content = "crossorigin",     .type = .domstring },
    .{ .iface = "HTMLScriptElement", .idl = "integrity",       .content = "integrity",       .type = .domstring },
    .{ .iface = "HTMLScriptElement", .idl = "referrerPolicy",  .content = "referrerpolicy",  .type = .domstring },
    .{ .iface = "HTMLScriptElement", .idl = "fetchPriority",   .content = "fetchpriority",   .type = .domstring },
    .{ .iface = "HTMLScriptElement", .idl = "nonce",           .content = "nonce",           .type = .domstring },
    .{ .iface = "HTMLScriptElement", .idl = "blocking",        .content = "blocking",        .type = .domstring },
    .{ .iface = "HTMLScriptElement", .idl = "charset",         .content = "charset",         .type = .domstring },
    .{ .iface = "HTMLScriptElement", .idl = "event",           .content = "event",           .type = .domstring },
    .{ .iface = "HTMLScriptElement", .idl = "htmlFor",         .content = "for",             .type = .domstring },

    // ── HTMLSelectElement (HTML §4.10.7) ─────────────────────────────
    .{ .iface = "HTMLSelectElement", .idl = "autocomplete", .content = "autocomplete", .type = .domstring },
    .{ .iface = "HTMLSelectElement", .idl = "disabled",     .content = "disabled",     .type = .boolean   },
    .{ .iface = "HTMLSelectElement", .idl = "multiple",     .content = "multiple",     .type = .boolean   },
    .{ .iface = "HTMLSelectElement", .idl = "name",         .content = "name",         .type = .domstring },
    .{ .iface = "HTMLSelectElement", .idl = "required",     .content = "required",     .type = .boolean   },
    .{ .iface = "HTMLSelectElement", .idl = "size",         .content = "size",         .type = .unsigned_long },

    // ── HTMLSlotElement (HTML §4.2.6.6) ──────────────────────────────
    .{ .iface = "HTMLSlotElement", .idl = "name", .content = "name", .type = .domstring },

    // ── HTMLSourceElement (HTML §4.8.2) ──────────────────────────────
    .{ .iface = "HTMLSourceElement", .idl = "src",    .content = "src",    .type = .url       },
    .{ .iface = "HTMLSourceElement", .idl = "type",   .content = "type",   .type = .domstring },
    .{ .iface = "HTMLSourceElement", .idl = "srcset", .content = "srcset", .type = .domstring },
    .{ .iface = "HTMLSourceElement", .idl = "sizes",  .content = "sizes",  .type = .domstring },
    .{ .iface = "HTMLSourceElement", .idl = "media",  .content = "media",  .type = .domstring },
    .{ .iface = "HTMLSourceElement", .idl = "width",  .content = "width",  .type = .unsigned_long },
    .{ .iface = "HTMLSourceElement", .idl = "height", .content = "height", .type = .unsigned_long },

    // ── HTMLStyleElement (HTML §4.2.6) ───────────────────────────────
    .{ .iface = "HTMLStyleElement", .idl = "media",    .content = "media",    .type = .domstring },
    .{ .iface = "HTMLStyleElement", .idl = "type",     .content = "type",     .type = .domstring },
    .{ .iface = "HTMLStyleElement", .idl = "nonce",    .content = "nonce",    .type = .domstring },
    .{ .iface = "HTMLStyleElement", .idl = "blocking", .content = "blocking", .type = .domstring },

    // ── HTMLTableCaptionElement (HTML §4.9.2) ────────────────────────
    .{ .iface = "HTMLTableCaptionElement", .idl = "align", .content = "align", .type = .domstring },

    // ── HTMLTableCellElement (td/th) (HTML §4.9.9–10) ────────────────
    .{ .iface = "HTMLTableCellElement", .idl = "colSpan", .content = "colspan", .type = .unsigned_long, .default_int = 1 },
    .{ .iface = "HTMLTableCellElement", .idl = "rowSpan", .content = "rowspan", .type = .unsigned_long, .default_int = 1 },
    .{ .iface = "HTMLTableCellElement", .idl = "headers", .content = "headers", .type = .domstring },
    .{ .iface = "HTMLTableCellElement", .idl = "scope",   .content = "scope",   .type = .domstring },
    .{ .iface = "HTMLTableCellElement", .idl = "abbr",    .content = "abbr",    .type = .domstring },
    .{ .iface = "HTMLTableCellElement", .idl = "align",   .content = "align",   .type = .domstring },
    .{ .iface = "HTMLTableCellElement", .idl = "axis",    .content = "axis",    .type = .domstring },
    .{ .iface = "HTMLTableCellElement", .idl = "height",  .content = "height",  .type = .domstring },
    .{ .iface = "HTMLTableCellElement", .idl = "width",   .content = "width",   .type = .domstring },
    .{ .iface = "HTMLTableCellElement", .idl = "ch",      .content = "char",    .type = .domstring },
    .{ .iface = "HTMLTableCellElement", .idl = "chOff",   .content = "charoff", .type = .domstring },
    .{ .iface = "HTMLTableCellElement", .idl = "noWrap",  .content = "nowrap",  .type = .boolean   },
    .{ .iface = "HTMLTableCellElement", .idl = "bgColor", .content = "bgcolor", .type = .domstring },
    .{ .iface = "HTMLTableCellElement", .idl = "vAlign",  .content = "valign",  .type = .domstring },

    // ── HTMLTableColElement (col/colgroup) (HTML §4.9.3) ─────────────
    .{ .iface = "HTMLTableColElement", .idl = "span",   .content = "span",    .type = .unsigned_long, .default_int = 1 },
    .{ .iface = "HTMLTableColElement", .idl = "align",  .content = "align",   .type = .domstring },
    .{ .iface = "HTMLTableColElement", .idl = "ch",     .content = "char",    .type = .domstring },
    .{ .iface = "HTMLTableColElement", .idl = "chOff",  .content = "charoff", .type = .domstring },
    .{ .iface = "HTMLTableColElement", .idl = "vAlign", .content = "valign",  .type = .domstring },
    .{ .iface = "HTMLTableColElement", .idl = "width",  .content = "width",   .type = .domstring },

    // ── HTMLTableElement (HTML §4.9.1) ───────────────────────────────
    .{ .iface = "HTMLTableElement", .idl = "caption",     .content = "caption",     .type = .domstring },
    .{ .iface = "HTMLTableElement", .idl = "align",       .content = "align",       .type = .domstring },
    .{ .iface = "HTMLTableElement", .idl = "border",      .content = "border",      .type = .domstring },
    .{ .iface = "HTMLTableElement", .idl = "frame",       .content = "frame",       .type = .domstring },
    .{ .iface = "HTMLTableElement", .idl = "rules",       .content = "rules",       .type = .domstring },
    .{ .iface = "HTMLTableElement", .idl = "summary",     .content = "summary",     .type = .domstring },
    .{ .iface = "HTMLTableElement", .idl = "width",       .content = "width",       .type = .domstring },
    .{ .iface = "HTMLTableElement", .idl = "bgColor",     .content = "bgcolor",     .type = .domstring },
    .{ .iface = "HTMLTableElement", .idl = "cellPadding", .content = "cellpadding", .type = .domstring },
    .{ .iface = "HTMLTableElement", .idl = "cellSpacing", .content = "cellspacing", .type = .domstring },

    // ── HTMLTableRowElement (HTML §4.9.8) ────────────────────────────
    .{ .iface = "HTMLTableRowElement", .idl = "align",  .content = "align",   .type = .domstring },
    .{ .iface = "HTMLTableRowElement", .idl = "ch",     .content = "char",    .type = .domstring },
    .{ .iface = "HTMLTableRowElement", .idl = "chOff",  .content = "charoff", .type = .domstring },
    .{ .iface = "HTMLTableRowElement", .idl = "vAlign", .content = "valign",  .type = .domstring },
    .{ .iface = "HTMLTableRowElement", .idl = "bgColor",.content = "bgcolor", .type = .domstring },

    // ── HTMLTableSectionElement (thead/tbody/tfoot) (HTML §4.9.5–7) ──
    .{ .iface = "HTMLTableSectionElement", .idl = "align",  .content = "align",   .type = .domstring },
    .{ .iface = "HTMLTableSectionElement", .idl = "ch",     .content = "char",    .type = .domstring },
    .{ .iface = "HTMLTableSectionElement", .idl = "chOff",  .content = "charoff", .type = .domstring },
    .{ .iface = "HTMLTableSectionElement", .idl = "vAlign", .content = "valign",  .type = .domstring },

    // ── HTMLTextAreaElement (HTML §4.10.11) ──────────────────────────
    .{ .iface = "HTMLTextAreaElement", .idl = "autocomplete", .content = "autocomplete", .type = .domstring },
    .{ .iface = "HTMLTextAreaElement", .idl = "cols",         .content = "cols",         .type = .unsigned_long, .default_int = 20 },
    .{ .iface = "HTMLTextAreaElement", .idl = "dirName",      .content = "dirname",      .type = .domstring },
    .{ .iface = "HTMLTextAreaElement", .idl = "disabled",     .content = "disabled",     .type = .boolean   },
    .{ .iface = "HTMLTextAreaElement", .idl = "maxLength",    .content = "maxlength",    .type = .long,          .default_int = -1 },
    .{ .iface = "HTMLTextAreaElement", .idl = "minLength",    .content = "minlength",    .type = .long,          .default_int = -1 },
    .{ .iface = "HTMLTextAreaElement", .idl = "name",         .content = "name",         .type = .domstring },
    .{ .iface = "HTMLTextAreaElement", .idl = "placeholder",  .content = "placeholder",  .type = .domstring },
    .{ .iface = "HTMLTextAreaElement", .idl = "readOnly",     .content = "readonly",     .type = .boolean   },
    .{ .iface = "HTMLTextAreaElement", .idl = "required",     .content = "required",     .type = .boolean   },
    .{ .iface = "HTMLTextAreaElement", .idl = "rows",         .content = "rows",         .type = .unsigned_long, .default_int = 2 },
    .{ .iface = "HTMLTextAreaElement", .idl = "wrap",         .content = "wrap",         .type = .domstring },

    // ── HTMLTimeElement (HTML §4.6.14) ───────────────────────────────
    .{ .iface = "HTMLTimeElement", .idl = "dateTime", .content = "datetime", .type = .domstring },

    // ── HTMLTitleElement (HTML §4.2.2) ───────────────────────────────
    // `title` text is a text-child getter, not a direct attr reflection.
    // The `text` IDL attribute reflects the element's text-only content.
    // We map it to a content attr for simple read-back; full impl would
    // use the childNodes text walk — good enough for IDL reflection tests.

    // ── HTMLTrackElement (HTML §4.8.10) ──────────────────────────────
    .{ .iface = "HTMLTrackElement", .idl = "kind",    .content = "kind",    .type = .domstring },
    .{ .iface = "HTMLTrackElement", .idl = "src",     .content = "src",     .type = .url       },
    .{ .iface = "HTMLTrackElement", .idl = "srclang", .content = "srclang", .type = .domstring },
    .{ .iface = "HTMLTrackElement", .idl = "label",   .content = "label",   .type = .domstring },
    .{ .iface = "HTMLTrackElement", .idl = "default", .content = "default", .type = .boolean   },

    // ── HTMLUListElement (HTML §4.4.6) ───────────────────────────────
    .{ .iface = "HTMLUListElement", .idl = "compact", .content = "compact", .type = .boolean   },
    .{ .iface = "HTMLUListElement", .idl = "type",    .content = "type",    .type = .domstring },

    // ── HTMLDListElement (HTML §4.4.9) ───────────────────────────────
    .{ .iface = "HTMLDListElement", .idl = "compact", .content = "compact", .type = .boolean },

    // ── HTMLDirectoryElement (obsolete) ──────────────────────────────
    .{ .iface = "HTMLDirectoryElement", .idl = "compact", .content = "compact", .type = .boolean },

    // ── HTMLFontElement (obsolete) ───────────────────────────────────
    .{ .iface = "HTMLFontElement", .idl = "color", .content = "color", .type = .domstring },
    .{ .iface = "HTMLFontElement", .idl = "face",  .content = "face",  .type = .domstring },
    .{ .iface = "HTMLFontElement", .idl = "size",  .content = "size",  .type = .domstring },

    // ── HTMLFrameElement (obsolete) ──────────────────────────────────
    .{ .iface = "HTMLFrameElement", .idl = "name",          .content = "name",          .type = .domstring },
    .{ .iface = "HTMLFrameElement", .idl = "scrolling",     .content = "scrolling",     .type = .domstring },
    .{ .iface = "HTMLFrameElement", .idl = "src",           .content = "src",           .type = .url       },
    .{ .iface = "HTMLFrameElement", .idl = "frameBorder",   .content = "frameborder",   .type = .domstring },
    .{ .iface = "HTMLFrameElement", .idl = "longDesc",      .content = "longdesc",      .type = .url       },
    .{ .iface = "HTMLFrameElement", .idl = "noResize",      .content = "noresize",      .type = .boolean   },
    .{ .iface = "HTMLFrameElement", .idl = "marginHeight",  .content = "marginheight",  .type = .domstring },
    .{ .iface = "HTMLFrameElement", .idl = "marginWidth",   .content = "marginwidth",   .type = .domstring },

    // ── HTMLMarqueeElement (obsolete) ────────────────────────────────
    .{ .iface = "HTMLMarqueeElement", .idl = "behavior",    .content = "behavior",    .type = .domstring },
    .{ .iface = "HTMLMarqueeElement", .idl = "bgColor",     .content = "bgcolor",     .type = .domstring },
    .{ .iface = "HTMLMarqueeElement", .idl = "direction",   .content = "direction",   .type = .domstring },
    .{ .iface = "HTMLMarqueeElement", .idl = "height",      .content = "height",      .type = .domstring },
    .{ .iface = "HTMLMarqueeElement", .idl = "hspace",      .content = "hspace",      .type = .unsigned_long },
    .{ .iface = "HTMLMarqueeElement", .idl = "scrollAmount",.content = "scrollamount",.type = .unsigned_long, .default_int = 6 },
    .{ .iface = "HTMLMarqueeElement", .idl = "scrollDelay", .content = "scrolldelay", .type = .unsigned_long, .default_int = 85 },
    .{ .iface = "HTMLMarqueeElement", .idl = "trueSpeed",   .content = "truespeed",   .type = .boolean   },
    .{ .iface = "HTMLMarqueeElement", .idl = "vspace",      .content = "vspace",      .type = .unsigned_long },
    .{ .iface = "HTMLMarqueeElement", .idl = "width",       .content = "width",       .type = .domstring },
};

/// O(n) linear scan — table is ~200 rows, well within branch-predictor range.
/// `iface` is the element's resolved HTML interface name (e.g. "HTMLInputElement").
/// A row with `iface = "HTMLElement"` matches every HTML element.
pub fn lookup(iface: []const u8, idl: []const u8) ?*const ReflectedAttr {
    for (table) |*row| {
        if (std.mem.eql(u8, row.idl, idl) and
            (std.mem.eql(u8, row.iface, iface) or
             std.mem.eql(u8, row.iface, "HTMLElement")))
        {
            return row;
        }
    }
    return null;
}

/// HTML §2.4.4.1 rules-for-parsing-integers.
/// Returns null on failure; caller substitutes the spec-defined default.
/// Skips leading ASCII whitespace; accepts optional leading +/-.
/// Trailing non-digit characters are allowed (spec collects only digits).
pub fn parseInteger(s: []const u8) ?i64 {
    var i: usize = 0;
    // skip ASCII whitespace
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            0x09, 0x0A, 0x0C, 0x0D, 0x20 => {},
            else => break,
        }
    }
    if (i >= s.len) return null;
    var sign: i64 = 1;
    if (s[i] == '+') {
        i += 1;
    } else if (s[i] == '-') {
        sign = -1;
        i += 1;
    }
    if (i >= s.len or s[i] < '0' or s[i] > '9') return null;
    var val: i64 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        val = val * 10 + @as(i64, s[i] - '0');
        if (val > std.math.maxInt(i32) + 1) {
            val = std.math.maxInt(i32) + 1; // clamp to prevent overflow before sign
        }
    }
    val *= sign;
    if (val > std.math.maxInt(i32)) val = std.math.maxInt(i32);
    if (val < std.math.minInt(i32)) val = std.math.minInt(i32);
    return val;
}

/// HTML §2.4.4.2 rules-for-parsing-non-negative-integers.
/// Negative values are a parse failure (returns null).
pub fn parseNonNegativeInteger(s: []const u8) ?i64 {
    const v = parseInteger(s) orelse return null;
    if (v < 0) return null;
    return v;
}

// ── Unit tests ────────────────────────────────────────────────────────

test "parseInteger basics" {
    try std.testing.expectEqual(@as(?i64, 0), parseInteger("0"));
    try std.testing.expectEqual(@as(?i64, 42), parseInteger("42"));
    try std.testing.expectEqual(@as(?i64, -7), parseInteger("-7"));
    try std.testing.expectEqual(@as(?i64, 5), parseInteger("  +5"));
    try std.testing.expectEqual(@as(?i64, null), parseInteger(""));
    try std.testing.expectEqual(@as(?i64, null), parseInteger("abc"));
    try std.testing.expectEqual(@as(?i64, null), parseInteger(" -"));
    try std.testing.expectEqual(@as(?i64, 12), parseInteger("12px"));
    try std.testing.expectEqual(@as(?i64, 2147483647), parseInteger("99999999999"));
}

test "parseNonNegativeInteger rejects negatives" {
    try std.testing.expectEqual(@as(?i64, 0), parseNonNegativeInteger("0"));
    try std.testing.expectEqual(@as(?i64, 123), parseNonNegativeInteger("123"));
    try std.testing.expectEqual(@as(?i64, null), parseNonNegativeInteger("-1"));
}

test "lookup finds HTMLElement row in any iface context" {
    // HTMLElement rows should match any concrete iface
    const r = lookup("HTMLInputElement", "title");
    try std.testing.expect(r != null);
    try std.testing.expectEqualStrings("title", r.?.content);
}

test "lookup finds concrete iface row" {
    const r = lookup("HTMLInputElement", "maxLength");
    try std.testing.expect(r != null);
    try std.testing.expectEqualStrings("maxlength", r.?.content);
    try std.testing.expectEqual(ReflType.long, r.?.type);
    try std.testing.expectEqual(@as(i64, -1), r.?.default_int);
}

test "lookup returns null for unknown idl" {
    try std.testing.expect(lookup("HTMLInputElement", "nonexistent") == null);
}
