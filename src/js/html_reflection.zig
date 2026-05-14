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
    /// §2.6.2 "DOMString?" — like DOMString but missing attribute returns `null`.
    /// Example: HTMLImageElement.crossOrigin (returns null when missing, canonical
    /// keyword otherwise).
    nullable_domstring,
    /// §2.4.3 / §2.6.5 "enumerated attribute" — canonicalizes to one of a
    /// known set of keywords. `default_str` holds the missing-or-invalid-value
    /// default (null means "empty string when missing"). `keywords` lists all
    /// valid canonical values (comptime slice).
    enumerated_ascii,
    /// §2.6.2 "double" — floating point parse via §2.4.4.3, with `default_double`
    /// substituted on miss/parse-fail.
    double_with_fallback,
    /// §2.6.2 "limited long" (non-negative only): getter parses non-negative
    /// integer per §2.4.4.2, returns default_int (-1) on miss/fail/negative.
    /// Setter throws IndexSizeError for negative values.
    limited_long,
    /// §2.6.2 "limited unsigned long" (> 0): getter parses non-negative int,
    /// returns default_int (1) if missing/fail/zero. Setter throws
    /// IndexSizeError for zero.
    limited_unsigned_long,
    /// §2.6.2 "limited unsigned long with fallback": like limited_unsigned_long
    /// but setter uses default_int instead of throwing on invalid values.
    limited_unsigned_long_with_fallback,
    /// §2.6.2 "clamped unsigned long": getter parses, then clamps to
    /// [clamp_min, clamp_max]. Uses default_int on miss/parse-fail.
    /// clamp_min/clamp_max stored in the ReflectedAttr.
    clamped_unsigned_long,
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
    /// Default for §2.4.3 enumerated attributes: the canonical keyword
    /// returned when the content attribute is missing OR its value does not
    /// match any known keyword (ASCII-case-insensitive). `null` means the
    /// IDL attribute returns "" in that case. Only consulted for
    /// `.enumerated_ascii` rows.
    default_str: ?[]const u8 = null,
    /// For `.enumerated_ascii`: the comptime list of canonical keywords.
    /// Ignored otherwise.
    keywords: []const []const u8 = &.{},
    /// For `.double_with_fallback`: default returned when content attribute
    /// is absent or fails §2.4.4.3 parse. Ignored otherwise.
    default_double: f64 = 0.0,
    /// For `.clamped_unsigned_long`: lower clamp bound (inclusive).
    clamp_min: i64 = 0,
    /// For `.clamped_unsigned_long`: upper clamp bound (inclusive).
    clamp_max: i64 = std.math.maxInt(i32),
};

/// HTML §2.5.3 "referrer policy" keywords.
/// Missing-value default is "" (empty string → IDL returns "").
pub const referrer_policy_keywords = [_][]const u8{
    "no-referrer",
    "no-referrer-when-downgrade",
    "same-origin",
    "origin",
    "strict-origin",
    "origin-when-cross-origin",
    "strict-origin-when-cross-origin",
    "unsafe-url",
};

/// HTML §4.10.8 button "type" — canonical keywords. Missing/invalid default
/// is "submit" (per the enumerated attribute table).
pub const button_type_keywords = [_][]const u8{
    "submit",
    "reset",
    "button",
};

/// HTML §4.10.21.6 form-submission-encoding keywords.
/// Invalid-default + missing-default: "application/x-www-form-urlencoded".
pub const form_enctype_keywords = [_][]const u8{
    "application/x-www-form-urlencoded",
    "multipart/form-data",
    "text/plain",
};

/// HTML §4.10.21.7 form-submission-method keywords.
/// Invalid-default + missing-default: "get".
pub const form_method_keywords = [_][]const u8{ "get", "post", "dialog" };

/// HTML §4.8.3 image-decoding-hint keywords.
/// Invalid-default + missing-default: "auto".
pub const image_decoding_keywords = [_][]const u8{ "sync", "async", "auto" };

/// HTML §2.6.6 / §4.8.5 lazy-loading keywords.
/// Invalid-default + missing-default: "eager".
pub const lazy_loading_keywords = [_][]const u8{ "lazy", "eager" };

/// HTML §4.10.5 input-type keywords. Invalid-default + missing-default: "text".
pub const input_type_keywords = [_][]const u8{
    "hidden",
    "text",
    "search",
    "tel",
    "url",
    "email",
    "password",
    "date",
    "month",
    "week",
    "time",
    "datetime-local",
    "number",
    "range",
    "color",
    "checkbox",
    "radio",
    "file",
    "submit",
    "image",
    "reset",
    "button",
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

    // ── ARIAMixin (ARIA §6.6.1) — nullable DOMString IDL attributes ──
    // All apply to every HTML element (via HTMLElement). Setting to null
    // removes the content attribute; setting to a string sets it.
    .{ .iface = "HTMLElement", .idl = "role",                          .content = "role",                          .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaAtomic",                    .content = "aria-atomic",                   .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaAutoComplete",              .content = "aria-autocomplete",             .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaBrailleLabel",              .content = "aria-braillelabel",             .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaBrailleRoleDescription",    .content = "aria-brailleroledescription",   .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaBusy",                      .content = "aria-busy",                     .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaChecked",                   .content = "aria-checked",                  .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaColCount",                  .content = "aria-colcount",                 .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaColIndex",                  .content = "aria-colindex",                 .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaColSpan",                   .content = "aria-colspan",                  .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaCurrent",                   .content = "aria-current",                  .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaDisabled",                  .content = "aria-disabled",                 .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaExpanded",                  .content = "aria-expanded",                 .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaHasPopup",                  .content = "aria-haspopup",                 .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaHidden",                    .content = "aria-hidden",                   .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaInvalid",                   .content = "aria-invalid",                  .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaKeyShortcuts",              .content = "aria-keyshortcuts",             .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaLabel",                     .content = "aria-label",                    .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaLevel",                     .content = "aria-level",                    .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaLive",                      .content = "aria-live",                     .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaModal",                     .content = "aria-modal",                    .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaMultiLine",                 .content = "aria-multiline",                .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaMultiSelectable",           .content = "aria-multiselectable",          .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaOrientation",               .content = "aria-orientation",              .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaPlaceholder",               .content = "aria-placeholder",              .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaPosInSet",                  .content = "aria-posinset",                 .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaPressed",                   .content = "aria-pressed",                  .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaReadOnly",                  .content = "aria-readonly",                 .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaRelevant",                  .content = "aria-relevant",                 .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaRequired",                  .content = "aria-required",                 .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaRoleDescription",           .content = "aria-roledescription",          .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaRowCount",                  .content = "aria-rowcount",                 .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaRowIndex",                  .content = "aria-rowindex",                 .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaRowSpan",                   .content = "aria-rowspan",                  .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaSelected",                  .content = "aria-selected",                 .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaSetSize",                   .content = "aria-setsize",                  .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaSort",                      .content = "aria-sort",                     .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaValueMax",                  .content = "aria-valuemax",                 .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaValueMin",                  .content = "aria-valuemin",                 .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaValueNow",                  .content = "aria-valuenow",                 .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaValueText",                 .content = "aria-valuetext",                .type = .nullable_domstring },
    // ARIAMixin tentative additions (ARIA §6.6.1 newer attrs)
    .{ .iface = "HTMLElement", .idl = "ariaColIndexText",              .content = "aria-colindextext",             .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaDescription",               .content = "aria-description",              .type = .nullable_domstring },
    .{ .iface = "HTMLElement", .idl = "ariaRowIndexText",              .content = "aria-rowindextext",             .type = .nullable_domstring },

    // ── HTMLAnchorElement (HTML §4.6.1) ──────────────────────────────
    .{ .iface = "HTMLAnchorElement", .idl = "name",           .content = "name",           .type = .domstring },
    .{ .iface = "HTMLAnchorElement", .idl = "href",           .content = "href",           .type = .url       },
    .{ .iface = "HTMLAnchorElement", .idl = "target",         .content = "target",         .type = .domstring },
    .{ .iface = "HTMLAnchorElement", .idl = "download",       .content = "download",       .type = .domstring },
    .{ .iface = "HTMLAnchorElement", .idl = "ping",           .content = "ping",           .type = .domstring },
    .{ .iface = "HTMLAnchorElement", .idl = "rel",            .content = "rel",            .type = .domstring },
    .{ .iface = "HTMLAnchorElement", .idl = "hreflang",       .content = "hreflang",       .type = .domstring },
    .{ .iface = "HTMLAnchorElement", .idl = "type",           .content = "type",           .type = .domstring },
    // HTML §2.5.3 "referrer policy" keywords — missing default "" (empty string).
    .{ .iface = "HTMLAnchorElement", .idl = "referrerPolicy", .content = "referrerpolicy", .type = .enumerated_ascii,
       .default_str = "", .keywords = &referrer_policy_keywords },
    .{ .iface = "HTMLAnchorElement", .idl = "text",           .content = "text",           .type = .domstring },

    // ── HTMLAreaElement (HTML §4.8.14) ────────────────────────────────
    .{ .iface = "HTMLAreaElement", .idl = "alt",           .content = "alt",           .type = .domstring },
    .{ .iface = "HTMLAreaElement", .idl = "coords",        .content = "coords",        .type = .domstring },
    .{ .iface = "HTMLAreaElement", .idl = "shape",         .content = "shape",         .type = .domstring },
    .{ .iface = "HTMLAreaElement", .idl = "target",        .content = "target",        .type = .domstring },
    .{ .iface = "HTMLAreaElement", .idl = "download",      .content = "download",      .type = .domstring },
    .{ .iface = "HTMLAreaElement", .idl = "ping",          .content = "ping",          .type = .domstring },
    .{ .iface = "HTMLAreaElement", .idl = "rel",           .content = "rel",           .type = .domstring },
    .{ .iface = "HTMLAreaElement", .idl = "referrerPolicy",.content = "referrerpolicy",.type = .enumerated_ascii,
       .default_str = "", .keywords = &referrer_policy_keywords },
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
    // HTML §4.10.8 button "type" — enumerated with canonical keywords; both
    // missing-default and invalid-default are "submit".
    .{ .iface = "HTMLButtonElement", .idl = "type",           .content = "type",
       .type = .enumerated_ascii, .default_str = "submit",
       .keywords = &button_type_keywords },
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
    // HTML §4.10.21.6 form-submission-encoding enum: invalid-default +
    // missing-default are both "application/x-www-form-urlencoded".
    .{ .iface = "HTMLFormElement", .idl = "enctype",       .content = "enctype",        .type = .enumerated_ascii,
       .default_str = "application/x-www-form-urlencoded", .keywords = &form_enctype_keywords },
    .{ .iface = "HTMLFormElement", .idl = "encoding",      .content = "enctype",        .type = .enumerated_ascii,
       .default_str = "application/x-www-form-urlencoded", .keywords = &form_enctype_keywords },
    // HTML §4.10.21.7 form-submission-method enum: keywords get/post/dialog,
    // invalid-default + missing-default "get".
    .{ .iface = "HTMLFormElement", .idl = "method",        .content = "method",         .type = .enumerated_ascii,
       .default_str = "get", .keywords = &form_method_keywords },
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
    .{ .iface = "HTMLIFrameElement", .idl = "referrerPolicy",  .content = "referrerpolicy",  .type = .enumerated_ascii,
       .default_str = "", .keywords = &referrer_policy_keywords },
    // HTML §4.8.5 lazy-loading enum: keywords eager/lazy, missing-default "eager".
    .{ .iface = "HTMLIFrameElement", .idl = "loading",         .content = "loading",         .type = .enumerated_ascii,
       .default_str = "eager", .keywords = &lazy_loading_keywords },
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
    // HTML §2.8.6 CORS enum: keywords anonymous/use-credentials, invalid-default
    // "anonymous", missing-default null (IDL attribute returns null).
    .{ .iface = "HTMLImageElement", .idl = "crossOrigin",     .content = "crossorigin",     .type = .nullable_domstring },
    .{ .iface = "HTMLImageElement", .idl = "useMap",          .content = "usemap",          .type = .domstring },
    .{ .iface = "HTMLImageElement", .idl = "isMap",           .content = "ismap",           .type = .boolean   },
    .{ .iface = "HTMLImageElement", .idl = "width",           .content = "width",           .type = .unsigned_long },
    .{ .iface = "HTMLImageElement", .idl = "height",          .content = "height",          .type = .unsigned_long },
    .{ .iface = "HTMLImageElement", .idl = "referrerPolicy",  .content = "referrerpolicy",  .type = .enumerated_ascii,
       .default_str = "", .keywords = &referrer_policy_keywords },
    // HTML §4.8.3 image decoding hint: sync/async/auto, invalid+missing-default "auto".
    .{ .iface = "HTMLImageElement", .idl = "decoding",        .content = "decoding",        .type = .enumerated_ascii,
       .default_str = "auto", .keywords = &image_decoding_keywords },
    .{ .iface = "HTMLImageElement", .idl = "loading",         .content = "loading",         .type = .enumerated_ascii,
       .default_str = "eager", .keywords = &lazy_loading_keywords },
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
    .{ .iface = "HTMLInputElement", .idl = "formEnctype",    .content = "formenctype",    .type = .enumerated_ascii,
       .default_str = "application/x-www-form-urlencoded", .keywords = &form_enctype_keywords },
    .{ .iface = "HTMLInputElement", .idl = "formMethod",     .content = "formmethod",     .type = .enumerated_ascii,
       .default_str = "get", .keywords = &form_method_keywords },
    .{ .iface = "HTMLInputElement", .idl = "formNoValidate", .content = "formnovalidate", .type = .boolean   },
    .{ .iface = "HTMLInputElement", .idl = "formTarget",     .content = "formtarget",     .type = .domstring },
    .{ .iface = "HTMLInputElement", .idl = "height",         .content = "height",         .type = .unsigned_long },
    .{ .iface = "HTMLInputElement", .idl = "max",            .content = "max",            .type = .domstring },
    .{ .iface = "HTMLInputElement", .idl = "maxLength",      .content = "maxlength",      .type = .limited_long,  .default_int = -1 },
    .{ .iface = "HTMLInputElement", .idl = "min",            .content = "min",            .type = .domstring },
    .{ .iface = "HTMLInputElement", .idl = "minLength",      .content = "minlength",      .type = .limited_long,  .default_int = -1 },
    .{ .iface = "HTMLInputElement", .idl = "multiple",       .content = "multiple",       .type = .boolean   },
    .{ .iface = "HTMLInputElement", .idl = "name",           .content = "name",           .type = .domstring },
    .{ .iface = "HTMLInputElement", .idl = "pattern",        .content = "pattern",        .type = .domstring },
    .{ .iface = "HTMLInputElement", .idl = "placeholder",    .content = "placeholder",    .type = .domstring },
    .{ .iface = "HTMLInputElement", .idl = "readOnly",       .content = "readonly",       .type = .boolean   },
    .{ .iface = "HTMLInputElement", .idl = "required",       .content = "required",       .type = .boolean   },
    // size: limited unsigned long, default 20 per HTML §4.10.18
    .{ .iface = "HTMLInputElement", .idl = "size",           .content = "size",           .type = .limited_unsigned_long, .default_int = 20 },
    .{ .iface = "HTMLInputElement", .idl = "src",            .content = "src",            .type = .url       },
    .{ .iface = "HTMLInputElement", .idl = "step",           .content = "step",           .type = .domstring },
    // HTML §4.10.5 input-type enum, invalid+missing-default "text".
    .{ .iface = "HTMLInputElement", .idl = "type",           .content = "type",           .type = .enumerated_ascii,
       .default_str = "text", .keywords = &input_type_keywords },
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
    // NB: `defaultValue` is NOT a content-attribute reflection for output.
    // HTML §4.10.12 specifies defaultValue as a stored string slot that
    // tracks descendant text content until explicitly set (see
    // form_state_polyfill_js in kotori_runtime.zig). Reflecting it from
    // the `value` content attribute was a spec violation that shadowed
    // the polyfill and broke resetting-a-form output subtests.

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
    // value: double, default 0. max: double, default 1.
    .{ .iface = "HTMLProgressElement", .idl = "value", .content = "value", .type = .double_with_fallback,
       .default_double = 0.0 },
    .{ .iface = "HTMLProgressElement", .idl = "max",   .content = "max",   .type = .double_with_fallback,
       .default_double = 1.0 },

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
    .{ .iface = "HTMLTableCellElement", .idl = "colSpan", .content = "colspan", .type = .clamped_unsigned_long, .default_int = 1, .clamp_min = 1,  .clamp_max = 1000  },
    .{ .iface = "HTMLTableCellElement", .idl = "rowSpan", .content = "rowspan", .type = .clamped_unsigned_long, .default_int = 1, .clamp_min = 0,  .clamp_max = 65534 },
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
    .{ .iface = "HTMLTableColElement", .idl = "span",   .content = "span",    .type = .clamped_unsigned_long, .default_int = 1, .clamp_min = 1, .clamp_max = 1000 },
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
    .{ .iface = "HTMLTextAreaElement", .idl = "cols",         .content = "cols",         .type = .limited_unsigned_long_with_fallback, .default_int = 20 },
    .{ .iface = "HTMLTextAreaElement", .idl = "dirName",      .content = "dirname",      .type = .domstring },
    .{ .iface = "HTMLTextAreaElement", .idl = "disabled",     .content = "disabled",     .type = .boolean   },
    .{ .iface = "HTMLTextAreaElement", .idl = "maxLength",    .content = "maxlength",    .type = .limited_long,  .default_int = -1 },
    .{ .iface = "HTMLTextAreaElement", .idl = "minLength",    .content = "minlength",    .type = .limited_long,  .default_int = -1 },
    .{ .iface = "HTMLTextAreaElement", .idl = "name",         .content = "name",         .type = .domstring },
    .{ .iface = "HTMLTextAreaElement", .idl = "placeholder",  .content = "placeholder",  .type = .domstring },
    .{ .iface = "HTMLTextAreaElement", .idl = "readOnly",     .content = "readonly",     .type = .boolean   },
    .{ .iface = "HTMLTextAreaElement", .idl = "required",     .content = "required",     .type = .boolean   },
    .{ .iface = "HTMLTextAreaElement", .idl = "rows",         .content = "rows",         .type = .limited_unsigned_long_with_fallback, .default_int = 2 },
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
///
/// Note: rows of type `.url` are intentionally NOT returned from this lookup.
/// HTML §2.6.2 "URL" reflection requires the getter to resolve the content
/// attribute value against `document.baseURI`. The native dispatch path in
/// `kotori_dom.reflectionGet` doesn't have the document context or URL
/// parser available, so we delegate URL-type reflections to the JS-level
/// prototype polyfill in `dom_api.zig` (which uses `new URL(v, document.baseURI).href`).
/// Returning null here for `.url` rows lets the native dispatcher fall
/// through to the prototype chain where the polyfill getter runs.
pub fn lookup(iface: []const u8, idl: []const u8) ?*const ReflectedAttr {
    for (table) |*row| {
        if (std.mem.eql(u8, row.idl, idl) and
            (std.mem.eql(u8, row.iface, iface) or
             std.mem.eql(u8, row.iface, "HTMLElement")))
        {
            // Skip URL-type rows — see doc comment. Continue scanning in
            // case a more specific row (e.g. HTMLElement override) matches.
            if (row.type == .url) return null;
            return row;
        }
    }
    return null;
}

/// Like lookup() but returns ONLY .url-type rows. Used by the kotori-path
/// URL canonicalization handler (HTML §2.6.2) which needs to know the content
/// attribute name so it can read the raw value and percent-encode it.
/// Returns the content attribute name (e.g. "href", "src") or null if no
/// .url row matches.
pub fn lookupUrlAttr(iface: []const u8, idl: []const u8) ?[]const u8 {
    for (table) |*row| {
        if (row.type == .url and
            std.mem.eql(u8, row.idl, idl) and
            (std.mem.eql(u8, row.iface, iface) or
             std.mem.eql(u8, row.iface, "HTMLElement")))
        {
            return row.content;
        }
    }
    return null;
}

/// HTML §2.4.4.1 rules-for-parsing-integers.
/// Returns null on parse failure OR on out-of-range values (< -2^31 or > 2^31-1)
/// so the caller can substitute the spec-defined default. Per the reflection
/// rule for `long`: "If it fails or returns an out of range value, or if the
/// attribute is absent, the default value must be returned instead."
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
    // Accumulate digits. Cap val at i64 ceiling to detect overflow; values
    // outside the i32 range are handled post-sign with a range check so
    // that the sentinel null triggers the caller's "use default" branch
    // (HTML §2.6.2 signed-long reflection rule).
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        // Cheap overflow guard: once val exceeds 2^31 there's no way the
        // final signed value is in-range, so stop accumulating early.
        if (val > @as(i64, std.math.maxInt(i32)) + 1) {
            // Still need to consume trailing digits so trailing non-digits
            // don't get treated as a second integer; but we already know
            // the result is out of range.
            val = @as(i64, std.math.maxInt(i32)) + 2; // sentinel "too big"
            continue;
        }
        val = val * 10 + @as(i64, s[i] - '0');
    }
    val *= sign;
    // Spec §2.6.2 "long": out-of-range ⇒ caller uses default.
    if (val > std.math.maxInt(i32)) return null;
    if (val < std.math.minInt(i32)) return null;
    return val;
}

/// HTML §2.4.4.2 rules-for-parsing-non-negative-integers.
/// Negative values are a parse failure (returns null).
pub fn parseNonNegativeInteger(s: []const u8) ?i64 {
    const v = parseInteger(s) orelse return null;
    if (v < 0) return null;
    return v;
}

// ── URL canonicalization (HTML §2.6 "URL" reflected attributes) ──────
//
// HTML §2.6.2 "URL" on getting: "if the content attribute is absent, the IDL
// attribute must return the empty string. Otherwise, the IDL attribute must
// parse the value of the content attribute relative to the element's node
// document and if that is successful, return the resulting URL string. If
// parsing fails, then the value of the content attribute must be returned
// instead, converted to a USVString."
//
// This is a minimal join implementation for reflection-getter use: it
// handles the common cases (absolute URLs, scheme-relative, path-absolute,
// and simple relative paths with "." / "..") without pulling in the full
// WHATWG URL parser from `src/url/parser.zig` (which lives in a different
// module and would require build graph changes to import). The full parser
// is expected to replace this once Track F wires url_parser into the
// kotori_dom dispatch path.

/// Returns true if `s` starts with a URL scheme ("<alpha>[alpha-num+-.]*:").
fn hasScheme(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0])) return false;
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == ':') return i > 0;
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    return false;
}

/// Strip leading/trailing ASCII whitespace (WHATWG URL preprocessing).
fn trimAsciiWs(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and s[start] <= 0x20) : (start += 1) {}
    while (end > start and s[end - 1] <= 0x20) : (end -= 1) {}
    return s[start..end];
}

/// Remove "." and ".." segments from `path` per RFC 3986 §5.2.4.
/// Input and output both start with '/'. Writes into `out` (caller-sized).
fn removeDotSegments(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    // Split into segments preserving leading '/'.
    var segs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer segs.deinit(allocator);

    var i: usize = 0;
    const has_leading_slash = path.len > 0 and path[0] == '/';
    if (has_leading_slash) i = 1;
    var start: usize = i;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            try segs.append(allocator, path[start..i]);
            start = i + 1;
        }
    }

    // Stack-based normalization.
    var stack: std.ArrayListUnmanaged([]const u8) = .empty;
    defer stack.deinit(allocator);

    for (segs.items, 0..) |seg, idx| {
        const is_last = idx == segs.items.len - 1;
        if (std.mem.eql(u8, seg, ".")) {
            if (is_last) {
                // Trailing "." becomes an empty segment ("/path/./" → "/path/").
                try stack.append(allocator, "");
            }
            continue;
        }
        if (std.mem.eql(u8, seg, "..")) {
            if (stack.items.len > 0) _ = stack.pop();
            if (is_last) try stack.append(allocator, "");
            continue;
        }
        try stack.append(allocator, seg);
    }

    if (has_leading_slash) try out.append(allocator, '/');
    for (stack.items, 0..) |seg, idx| {
        try out.appendSlice(allocator, seg);
        if (idx + 1 < stack.items.len) try out.append(allocator, '/');
    }
    return out.toOwnedSlice(allocator);
}

/// Split a base URL into (prefix-up-to-authority, path, has_authority).
/// prefix = "scheme://host[:port]" (or "scheme:" if no authority).
/// Assumes `base` has a scheme (caller validated via `hasScheme`).
fn splitBase(base: []const u8) struct { prefix: []const u8, path: []const u8 } {
    // Find ':' after scheme.
    var colon: usize = 0;
    while (colon < base.len and base[colon] != ':') : (colon += 1) {}
    if (colon >= base.len) return .{ .prefix = base, .path = "" };
    const after_scheme = colon + 1;

    // Authority starts with "//" ?
    if (after_scheme + 1 < base.len and base[after_scheme] == '/' and base[after_scheme + 1] == '/') {
        // Authority ends at next '/', '?', '#', or end of string.
        var end = after_scheme + 2;
        while (end < base.len and base[end] != '/' and base[end] != '?' and base[end] != '#') : (end += 1) {}
        return .{ .prefix = base[0..end], .path = base[end..] };
    }

    // No authority ("data:", "mailto:", etc.) — opaque path.
    return .{ .prefix = base[0..after_scheme], .path = base[after_scheme..] };
}

/// Strip `?query` and `#fragment` from a path-like string.
fn stripQueryFragment(s: []const u8) []const u8 {
    for (s, 0..) |c, idx| {
        if (c == '?' or c == '#') return s[0..idx];
    }
    return s;
}

/// Canonicalize a content-attribute URL value against a base URL per
/// HTML §2.6.2 "URL" reflection. Returns an owned slice.
///
/// Behavior (matches §2.6.2 as closely as a minimal joiner can):
///   - If `value` (after trimming) has a scheme → return it as-is.
///   - Else if base is present and has a scheme → resolve `value` against
///     the base using RFC 3986 §5.2-style merge:
///       * scheme-relative ("//host/path")  → base-scheme + value
///       * path-absolute ("/path")          → base-authority-prefix + value
///       * query-only ("?...") / fragment-only ("#...") → base-path-no-query + value
///       * relative path                     → merge against base path
///   - Else → return a duplicate of `value` (raw fallback).
///
/// The caller owns the returned slice and must `allocator.free()` it.
pub fn canonicalizeUrl(
    allocator: std.mem.Allocator,
    value: []const u8,
    base_url: ?[]const u8,
) ![]u8 {
    const v = trimAsciiWs(value);

    // Case 1: value already absolute.
    if (hasScheme(v)) return allocator.dupe(u8, v);

    // Case 2: no base, nothing to resolve.
    const base_raw = base_url orelse return allocator.dupe(u8, value);
    const base = trimAsciiWs(base_raw);
    if (!hasScheme(base)) return allocator.dupe(u8, value);

    const base_parts = splitBase(base);

    // Empty value ⇒ base without fragment.
    if (v.len == 0) {
        const base_no_frag = blk: {
            for (base, 0..) |c, idx| {
                if (c == '#') break :blk base[0..idx];
            }
            break :blk base;
        };
        return allocator.dupe(u8, base_no_frag);
    }

    // Case 3a: scheme-relative ("//host/path").
    if (v.len >= 2 and v[0] == '/' and v[1] == '/') {
        // scheme:// + "//host/..."  →  scheme: + value
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        // Prefix is up to and including scheme + ":"  (need to locate it).
        var colon: usize = 0;
        while (colon < base.len and base[colon] != ':') : (colon += 1) {}
        try out.appendSlice(allocator, base[0 .. colon + 1]);
        try out.appendSlice(allocator, v);
        return out.toOwnedSlice(allocator);
    }

    // Case 3b: path-absolute ("/path").
    if (v.len >= 1 and v[0] == '/') {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, base_parts.prefix);
        const joined = try removeDotSegments(allocator, v);
        defer allocator.free(joined);
        try out.appendSlice(allocator, joined);
        return out.toOwnedSlice(allocator);
    }

    // Case 3c: fragment-only.
    if (v[0] == '#') {
        // base without fragment + value
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        for (base, 0..) |c, idx| {
            if (c == '#') {
                try out.appendSlice(allocator, base[0..idx]);
                break;
            }
        } else {
            try out.appendSlice(allocator, base);
        }
        try out.appendSlice(allocator, v);
        return out.toOwnedSlice(allocator);
    }

    // Case 3d: query-only.
    if (v[0] == '?') {
        // base without query+fragment + value
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        const base_clean = stripQueryFragment(base);
        try out.appendSlice(allocator, base_clean);
        try out.appendSlice(allocator, v);
        return out.toOwnedSlice(allocator);
    }

    // Case 3e: relative path. Merge against base path.
    // base path for merge: strip query+fragment, then strip final segment
    // (everything after the last '/', keeping the '/'). If base has no
    // path, use "/".
    const base_path_raw = stripQueryFragment(base_parts.path);
    var merge_base: []const u8 = "/";
    if (base_path_raw.len > 0) {
        // Find last '/'
        var last_slash: ?usize = null;
        var k: usize = base_path_raw.len;
        while (k > 0) {
            k -= 1;
            if (base_path_raw[k] == '/') {
                last_slash = k;
                break;
            }
        }
        if (last_slash) |ls| {
            merge_base = base_path_raw[0 .. ls + 1];
        }
    }

    // Build "merge_base + value-up-to-query/fragment" then remove dot segs.
    // Keep query/fragment from value intact (not subject to dot-seg removal).
    var val_path_end: usize = v.len;
    var val_extra_start: usize = v.len;
    for (v, 0..) |c, idx| {
        if (c == '?' or c == '#') {
            val_path_end = idx;
            val_extra_start = idx;
            break;
        }
    }
    const val_path = v[0..val_path_end];
    const val_extra = v[val_extra_start..];

    // Concatenate merge_base (must start with '/') with val_path.
    var joined_path: std.ArrayListUnmanaged(u8) = .empty;
    defer joined_path.deinit(allocator);
    // Ensure we start with '/': if base has no authority and merge_base is
    // empty/non-slash, just use val_path.
    const leading_slash = merge_base.len > 0 and merge_base[0] == '/';
    if (leading_slash) try joined_path.appendSlice(allocator, merge_base)
    else try joined_path.appendSlice(allocator, merge_base);
    try joined_path.appendSlice(allocator, val_path);

    const normalized = try removeDotSegments(allocator, joined_path.items);
    defer allocator.free(normalized);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, base_parts.prefix);
    try out.appendSlice(allocator, normalized);
    try out.appendSlice(allocator, val_extra);
    return out.toOwnedSlice(allocator);
}

// ── Additional §2.6 / §2.4 reflection helpers (Layer 4A completion) ──
//
// These helpers are pure Zig utilities usable from any reflection
// dispatcher (currently `kotori_dom.zig`, future: JS-level polyfills).
// They intentionally add no new `ReflType` variants — doing so would
// require expanding the exhaustive switches in `kotori_dom.zig`'s
// `reflectionGet` / `reflectionSet`, and Layer 4A scope keeps this
// file as a pure helper library.
//
// Spec references:
// - HTML §2.4.1 "Split a string on ASCII whitespace"
//   <https://infra.spec.whatwg.org/#split-on-ascii-whitespace>
// - HTML §2.4.3 "Enumerated attributes"
//   <https://html.spec.whatwg.org/multipage/common-microsyntaxes.html#enumerated-attributes>
// - HTML §2.4.4.3 "Rules for parsing floating-point number values"
//   <https://html.spec.whatwg.org/multipage/common-microsyntaxes.html#rules-for-parsing-floating-point-number-values>
// - HTML §2.6.2 "URL" / "boolean" / "long" / "unsigned long" semantics

/// Public re-export of ASCII-whitespace trim (HTML §2.4 preprocessing).
/// Leaves content untouched other than leading/trailing U+0009, U+000A,
/// U+000C, U+000D, U+0020.
pub fn trimAsciiWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and isAsciiWhitespace(s[start])) : (start += 1) {}
    while (end > start and isAsciiWhitespace(s[end - 1])) : (end -= 1) {}
    return s[start..end];
}

/// HTML §2.4 ASCII whitespace = TAB / LF / FF / CR / SPACE.
/// Notably NOT the full Unicode whitespace class — `std.ascii.isWhitespace`
/// also treats VT (0x0B) as whitespace which the HTML spec excludes.
pub fn isAsciiWhitespace(c: u8) bool {
    return switch (c) {
        0x09, 0x0A, 0x0C, 0x0D, 0x20 => true,
        else => false,
    };
}

/// HTML §2.4.1 "Strictly split a string on ASCII whitespace".
/// Returns a slice of tokens referencing substrings of `s`. Empty input or
/// all-whitespace input produces an empty list. The caller owns the
/// returned slice and must `allocator.free()` it (the token sub-slices
/// point into `s` — they must not outlive it).
pub fn splitOnAsciiWhitespace(
    allocator: std.mem.Allocator,
    s: []const u8,
) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and isAsciiWhitespace(s[i])) : (i += 1) {}
        if (i >= s.len) break;
        const start = i;
        while (i < s.len and !isAsciiWhitespace(s[i])) : (i += 1) {}
        try out.append(allocator, s[start..i]);
    }
    return out.toOwnedSlice(allocator);
}

/// HTML §2.4.3 "Enumerated attributes" — canonical-value getter rule.
///
/// Returns the canonical (lower-case) keyword from `known_values` that
/// matches `attr_value` (ASCII case-insensitive). If no match, returns
/// `missing_or_invalid_default` (which is `null` when the spec dictates
/// the IDL attribute should return the empty string or reflect the
/// "no state" default — the caller decides between the two). Per §2.6.5
/// this is distinct from the "invalid value default": many enumerated
/// attributes define both missing-value and invalid-value defaults, but
/// the spec-written rule is "if either one applies, return the default"
/// — so a single slot is sufficient.
///
/// The returned slice references either `known_values[i]` (so its
/// lifetime is comptime) or `missing_or_invalid_default` — both are
/// borrowed, never owned.
pub fn matchEnumValue(
    attr_value: []const u8,
    known_values: []const []const u8,
    missing_or_invalid_default: ?[]const u8,
) ?[]const u8 {
    for (known_values) |kv| {
        if (asciiEqlIgnoreCase(attr_value, kv)) return kv;
    }
    return missing_or_invalid_default;
}

/// ASCII case-insensitive string equality (HTML §2.3.1).
/// Upper-case ASCII is folded to lower-case. Non-ASCII bytes compare
/// byte-for-byte (HTML parser already lower-cased content attribute
/// names, so this is mainly defensive against value-side casing).
pub fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

/// HTML §2.6.2 "unsigned long" setter clamping.
/// Converts a signed i64 (typically from `ToInt32` of a JS value) into
/// the [0, 2^31-1] range that the spec requires a setter to write:
///   * negative → use `default_int` (spec: "If the new value is negative,
///     then set the content attribute to the default value.")
///   * value ≤ maxInt(i32) → that value
///   * > maxInt(i32) → clamp to `default_int` (caller serializes).
///
/// For plain `unsigned long` (no positive-only restriction) pass the
/// spec-defined default (most attrs default to 0; some to a named value
/// like `<input size>` = 20, `<col span>` = 1).
pub fn clampUnsignedLong(value: i64, default_int: i64) u32 {
    if (value < 0) {
        return @intCast(@max(default_int, 0));
    }
    if (value > std.math.maxInt(i32)) {
        return @intCast(@max(default_int, 0));
    }
    return @intCast(value);
}

/// HTML §2.6.2 "unsigned long limited to only positive numbers" setter.
/// Like `clampUnsignedLong` but 0 is also treated as invalid and replaced
/// with `default_int`. Examples: `<col span>`, `<td colspan>` — content
/// attribute value 0 parses back as the default (1) per §14.2.11.
pub fn clampUnsignedLongPositive(value: i64, default_int: i64) u32 {
    if (value < 1) {
        return @intCast(@max(default_int, 1));
    }
    if (value > std.math.maxInt(i32)) {
        return @intCast(@max(default_int, 1));
    }
    return @intCast(value);
}

/// HTML §2.4.4.3 "Rules for parsing floating-point number values".
/// Returns null on parse failure, on inf/NaN, or on empty/whitespace-only
/// input. Accepts optional leading +/-, integer and fractional parts, and
/// ASCII `e`/`E` exponent per the spec's state-machine. Skips leading
/// ASCII whitespace but trailing garbage terminates the parse (the spec
/// collects only the valid prefix).
///
/// Usage: caller further classifies via §2.4.4.5 (non-negative → reject
/// negatives) or via §2.6.2 "double" reflection semantics (use default
/// on null return).
pub fn parseFloatingPoint(s: []const u8) ?f64 {
    var i: usize = 0;
    // Skip leading ASCII whitespace.
    while (i < s.len and isAsciiWhitespace(s[i])) : (i += 1) {}
    if (i >= s.len) return null;

    const start = i;

    // Optional sign.
    if (s[i] == '+' or s[i] == '-') i += 1;

    const digits_int_start = i;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    const had_int = i > digits_int_start;

    var had_frac = false;
    if (i < s.len and s[i] == '.') {
        i += 1;
        const frac_start = i;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
        had_frac = i > frac_start;
    }

    if (!had_int and !had_frac) return null;

    // Optional exponent.
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        const exp_mark = i;
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        const exp_digits_start = i;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
        if (i == exp_digits_start) {
            // Exponent marker with no digits — back out.
            i = exp_mark;
        }
    }

    // Parse the collected prefix with std.fmt.
    const parsed = std.fmt.parseFloat(f64, s[start..i]) catch return null;
    if (std.math.isNan(parsed)) return null;
    if (std.math.isInf(parsed)) return null;
    return parsed;
}

/// HTML §2.4.4.5 "Rules for parsing non-negative floating-point number values".
/// Rejects negatives (returns null) — used for `<progress max>` etc.
pub fn parseNonNegativeFloatingPoint(s: []const u8) ?f64 {
    const v = parseFloatingPoint(s) orelse return null;
    if (v < 0) return null;
    return v;
}

/// HTML §2.4.4.4-style "positive floating point" (strict > 0, rejects 0).
/// Used for `<meter optimum>` etc. where 0 is semantically invalid.
pub fn parsePositiveFloatingPoint(s: []const u8) ?f64 {
    const v = parseFloatingPoint(s) orelse return null;
    if (v <= 0) return null;
    return v;
}

/// HTML §2.4.4.1 strict variant — integer parser with no trailing-garbage
/// acceptance. Used for IDL attributes like `HTMLTableColElement.span`
/// where the spec distinguishes "valid integer" from "integer with
/// trailing junk" in the validity algorithm. Implementation piggy-backs
/// on `parseInteger` then verifies that the consumed prefix spans the
/// full (trimmed) input.
pub fn parseIntegerStrict(s: []const u8) ?i64 {
    const trimmed = trimAsciiWhitespace(s);
    if (trimmed.len == 0) return null;
    // Sign is valid in strict form too.
    var i: usize = 0;
    if (trimmed[i] == '+' or trimmed[i] == '-') i += 1;
    if (i >= trimmed.len) return null;
    while (i < trimmed.len) : (i += 1) {
        if (trimmed[i] < '0' or trimmed[i] > '9') return null;
    }
    return parseInteger(trimmed);
}

/// HTML §2.6.2 "reflecting IDL attribute" serializer for signed longs.
/// Writes a base-10 decimal representation of `value` into `buf` and
/// returns the occupied slice. `buf` must be at least 12 bytes (max i32
/// is "-2147483648" = 11 chars + sentinel). Returns the written slice.
pub fn formatLong(buf: []u8, value: i32) []u8 {
    return std.fmt.bufPrint(buf, "{d}", .{value}) catch unreachable;
}

/// Same as `formatLong` but for unsigned 32-bit values. 10-byte buffer
/// (max u32 = "4294967295") is enough but HTML always clamps to
/// maxInt(i32) so 10 chars is the ceiling for reflection output.
pub fn formatUnsignedLong(buf: []u8, value: u32) []u8 {
    return std.fmt.bufPrint(buf, "{d}", .{value}) catch unreachable;
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
}

test "parseInteger out of range returns null (spec: reflecting caller uses default)" {
    // §2.6.2 signed-long reflection: out-of-range ⇒ null ⇒ caller uses default.
    try std.testing.expectEqual(@as(?i64, null), parseInteger("99999999999"));
    try std.testing.expectEqual(@as(?i64, null), parseInteger("2147483648")); // maxInt(i32)+1
    try std.testing.expectEqual(@as(?i64, null), parseInteger("-2147483649")); // minInt(i32)-1
}

test "parseInteger i32 boundaries are in range" {
    try std.testing.expectEqual(@as(?i64, 2147483647), parseInteger("2147483647"));
    try std.testing.expectEqual(@as(?i64, -2147483648), parseInteger("-2147483648"));
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

test "lookup skips URL-type rows so JS polyfill can canonicalize" {
    // HTMLAnchorElement.href is .url — native lookup must return null so
    // the dispatch falls through to the prototype-level `new URL(v, baseURI)`
    // polyfill in dom_api.zig (HTML §2.6.2 URL reflection).
    try std.testing.expect(lookup("HTMLAnchorElement", "href") == null);
    try std.testing.expect(lookup("HTMLImageElement", "src") == null);
    try std.testing.expect(lookup("HTMLFormElement", "action") == null);
}

test "lookup still returns non-URL rows" {
    // Sanity: boolean/long/domstring rows continue to dispatch natively.
    try std.testing.expect(lookup("HTMLInputElement", "disabled") != null);
    try std.testing.expect(lookup("HTMLInputElement", "maxLength") != null);
    try std.testing.expect(lookup("HTMLAnchorElement", "target") != null);
}

// ── canonicalizeUrl tests (HTML §2.6.2 URL reflection) ────────────────

test "canonicalizeUrl resolves relative against base" {
    const alloc = std.testing.allocator;
    const resolved = try canonicalizeUrl(alloc, "foo", "http://example.com/");
    defer alloc.free(resolved);
    try std.testing.expectEqualStrings("http://example.com/foo", resolved);
}

test "canonicalizeUrl keeps absolute URL" {
    const alloc = std.testing.allocator;
    const resolved = try canonicalizeUrl(alloc, "https://other.example/path", "http://example.com/");
    defer alloc.free(resolved);
    try std.testing.expectEqualStrings("https://other.example/path", resolved);
}

test "canonicalizeUrl handles no base" {
    const alloc = std.testing.allocator;
    const resolved = try canonicalizeUrl(alloc, "http://example.com/", null);
    defer alloc.free(resolved);
    try std.testing.expectEqualStrings("http://example.com/", resolved);
}

test "canonicalizeUrl falls back to raw on parse failure" {
    // Relative URL with no base is a parse failure per WHATWG URL §4.3;
    // §2.6.2 says return the content attribute value as-is in that case.
    const alloc = std.testing.allocator;
    const resolved = try canonicalizeUrl(alloc, "foo", null);
    defer alloc.free(resolved);
    try std.testing.expectEqualStrings("foo", resolved);
}

test "canonicalizeUrl resolves dot-segments" {
    const alloc = std.testing.allocator;
    const resolved = try canonicalizeUrl(alloc, "../x", "http://example.com/a/b/c");
    defer alloc.free(resolved);
    try std.testing.expectEqualStrings("http://example.com/a/x", resolved);
}

// ── §2.4 helper tests (Layer 4A completion) ──────────────────────────

test "isAsciiWhitespace matches HTML §2.4 whitespace class" {
    try std.testing.expect(isAsciiWhitespace(0x09));
    try std.testing.expect(isAsciiWhitespace(0x0A));
    try std.testing.expect(isAsciiWhitespace(0x0C));
    try std.testing.expect(isAsciiWhitespace(0x0D));
    try std.testing.expect(isAsciiWhitespace(0x20));
    // VT (0x0B) is whitespace to std.ascii but NOT to HTML §2.4.
    try std.testing.expect(!isAsciiWhitespace(0x0B));
    try std.testing.expect(!isAsciiWhitespace('a'));
    try std.testing.expect(!isAsciiWhitespace(0));
}

test "trimAsciiWhitespace strips only HTML §2.4 whitespace" {
    try std.testing.expectEqualStrings("foo", trimAsciiWhitespace("  foo  "));
    try std.testing.expectEqualStrings("foo", trimAsciiWhitespace("\t\nfoo\r\n"));
    try std.testing.expectEqualStrings("", trimAsciiWhitespace("   "));
    try std.testing.expectEqualStrings("", trimAsciiWhitespace(""));
    try std.testing.expectEqualStrings("a b", trimAsciiWhitespace(" a b "));
    // VT must survive (not HTML whitespace).
    try std.testing.expectEqualStrings("\x0Bfoo\x0B", trimAsciiWhitespace("\x0Bfoo\x0B"));
}

test "splitOnAsciiWhitespace returns tokens" {
    const alloc = std.testing.allocator;
    {
        const toks = try splitOnAsciiWhitespace(alloc, "  foo bar\tbaz\n");
        defer alloc.free(toks);
        try std.testing.expectEqual(@as(usize, 3), toks.len);
        try std.testing.expectEqualStrings("foo", toks[0]);
        try std.testing.expectEqualStrings("bar", toks[1]);
        try std.testing.expectEqualStrings("baz", toks[2]);
    }
    {
        const toks = try splitOnAsciiWhitespace(alloc, "");
        defer alloc.free(toks);
        try std.testing.expectEqual(@as(usize, 0), toks.len);
    }
    {
        const toks = try splitOnAsciiWhitespace(alloc, "   \t\n ");
        defer alloc.free(toks);
        try std.testing.expectEqual(@as(usize, 0), toks.len);
    }
    {
        // Single token, no whitespace.
        const toks = try splitOnAsciiWhitespace(alloc, "single");
        defer alloc.free(toks);
        try std.testing.expectEqual(@as(usize, 1), toks.len);
        try std.testing.expectEqualStrings("single", toks[0]);
    }
}

test "asciiEqlIgnoreCase folds only ASCII letters" {
    try std.testing.expect(asciiEqlIgnoreCase("FOO", "foo"));
    try std.testing.expect(asciiEqlIgnoreCase("LoRem", "loREM"));
    try std.testing.expect(!asciiEqlIgnoreCase("foo", "fooo"));
    try std.testing.expect(!asciiEqlIgnoreCase("foo", "bar"));
    try std.testing.expect(asciiEqlIgnoreCase("", ""));
    // High-bit bytes aren't folded.
    try std.testing.expect(!asciiEqlIgnoreCase("\xC3\xA9", "\xC3\x89"));
}

test "matchEnumValue enum canonicalization per §2.4.3" {
    const values = [_][]const u8{ "rect", "circle", "poly", "default" };
    // Exact match
    try std.testing.expectEqualStrings("circle", matchEnumValue("circle", &values, null).?);
    // Case-insensitive match returns canonical (lowercase) value.
    try std.testing.expectEqualStrings("rect", matchEnumValue("RECT", &values, null).?);
    try std.testing.expectEqualStrings("default", matchEnumValue("Default", &values, null).?);
    // No match + no default → null.
    try std.testing.expect(matchEnumValue("square", &values, null) == null);
    // No match + default → default.
    try std.testing.expectEqualStrings(
        "rect",
        matchEnumValue("square", &values, "rect").?,
    );
    // Empty attr with a missing-value default returns that default.
    try std.testing.expectEqualStrings(
        "default",
        matchEnumValue("", &values, "default").?,
    );
}

test "clampUnsignedLong setter clamping §2.6.2" {
    // Normal in-range.
    try std.testing.expectEqual(@as(u32, 0), clampUnsignedLong(0, 20));
    try std.testing.expectEqual(@as(u32, 42), clampUnsignedLong(42, 20));
    // Negative → default.
    try std.testing.expectEqual(@as(u32, 20), clampUnsignedLong(-1, 20));
    try std.testing.expectEqual(@as(u32, 20), clampUnsignedLong(-1000, 20));
    // Over i32 max → default.
    try std.testing.expectEqual(
        @as(u32, 20),
        clampUnsignedLong(@as(i64, std.math.maxInt(i32)) + 1, 20),
    );
    // Default of -1 (seen for signed-long but defensive for unsigned) ⇒ 0.
    try std.testing.expectEqual(@as(u32, 0), clampUnsignedLong(-5, -1));
    // Boundary: exactly maxInt(i32) passes through.
    try std.testing.expectEqual(
        @as(u32, std.math.maxInt(i32)),
        clampUnsignedLong(std.math.maxInt(i32), 0),
    );
}

test "clampUnsignedLongPositive rejects 0" {
    // 0 → default (spec §14.2.11: colspan=0 reflects back as 1).
    try std.testing.expectEqual(@as(u32, 1), clampUnsignedLongPositive(0, 1));
    try std.testing.expectEqual(@as(u32, 5), clampUnsignedLongPositive(5, 1));
    try std.testing.expectEqual(@as(u32, 1), clampUnsignedLongPositive(-3, 1));
    try std.testing.expectEqual(
        @as(u32, 1),
        clampUnsignedLongPositive(@as(i64, std.math.maxInt(i32)) + 1, 1),
    );
    // default of 0 gets floored to 1 (positive-only invariant).
    try std.testing.expectEqual(@as(u32, 1), clampUnsignedLongPositive(0, 0));
}

test "parseFloatingPoint basic numeric parse" {
    try std.testing.expectEqual(@as(?f64, 0), parseFloatingPoint("0"));
    try std.testing.expectEqual(@as(?f64, 1), parseFloatingPoint("1"));
    try std.testing.expectEqual(@as(?f64, -2.5), parseFloatingPoint("-2.5"));
    try std.testing.expectEqual(@as(?f64, 0.25), parseFloatingPoint(".25"));
    try std.testing.expectEqual(@as(?f64, 100), parseFloatingPoint("1e2"));
    try std.testing.expectEqual(@as(?f64, 1.5e-3), parseFloatingPoint("1.5e-3"));
    try std.testing.expectEqual(@as(?f64, null), parseFloatingPoint(""));
    try std.testing.expectEqual(@as(?f64, null), parseFloatingPoint("abc"));
    try std.testing.expectEqual(@as(?f64, null), parseFloatingPoint("   "));
    try std.testing.expectEqual(@as(?f64, null), parseFloatingPoint("-"));
    // NaN and Inf tokens are a parse failure per §2.4.4.3.
    try std.testing.expectEqual(@as(?f64, null), parseFloatingPoint("NaN"));
    try std.testing.expectEqual(@as(?f64, null), parseFloatingPoint("Infinity"));
}

test "parseFloatingPoint accepts leading whitespace" {
    try std.testing.expectEqual(@as(?f64, 1.5), parseFloatingPoint("  1.5"));
    try std.testing.expectEqual(@as(?f64, -0.5), parseFloatingPoint("\t\n-0.5"));
}

test "parseFloatingPoint consumes valid prefix only" {
    // Spec collects the longest valid prefix — trailing "abc" is discarded.
    try std.testing.expectEqual(@as(?f64, 3.14), parseFloatingPoint("3.14abc"));
    // Exponent marker with no digits — reverts prefix to "1".
    try std.testing.expectEqual(@as(?f64, 1), parseFloatingPoint("1e"));
    try std.testing.expectEqual(@as(?f64, 1), parseFloatingPoint("1e+"));
}

test "parseNonNegativeFloatingPoint rejects negatives" {
    try std.testing.expectEqual(@as(?f64, 0), parseNonNegativeFloatingPoint("0"));
    try std.testing.expectEqual(@as(?f64, 1.5), parseNonNegativeFloatingPoint("1.5"));
    try std.testing.expectEqual(@as(?f64, null), parseNonNegativeFloatingPoint("-0.5"));
    try std.testing.expectEqual(@as(?f64, null), parseNonNegativeFloatingPoint("-1"));
}

test "parsePositiveFloatingPoint rejects zero and negatives" {
    try std.testing.expectEqual(@as(?f64, null), parsePositiveFloatingPoint("0"));
    try std.testing.expectEqual(@as(?f64, null), parsePositiveFloatingPoint("-1.5"));
    try std.testing.expectEqual(@as(?f64, 0.001), parsePositiveFloatingPoint("0.001"));
    try std.testing.expectEqual(@as(?f64, 2.718), parsePositiveFloatingPoint("2.718"));
}

test "parseIntegerStrict rejects trailing garbage" {
    // parseInteger accepts "12px" (returns 12). parseIntegerStrict must reject.
    try std.testing.expectEqual(@as(?i64, 12), parseInteger("12px"));
    try std.testing.expectEqual(@as(?i64, null), parseIntegerStrict("12px"));
    // Leading/trailing whitespace is stripped per spec.
    try std.testing.expectEqual(@as(?i64, 42), parseIntegerStrict("  42  "));
    try std.testing.expectEqual(@as(?i64, -7), parseIntegerStrict("-7"));
    try std.testing.expectEqual(@as(?i64, null), parseIntegerStrict(""));
    try std.testing.expectEqual(@as(?i64, null), parseIntegerStrict("-"));
    try std.testing.expectEqual(@as(?i64, null), parseIntegerStrict("+-5"));
}

test "formatLong writes signed decimal" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0", formatLong(&buf, 0));
    try std.testing.expectEqualStrings("42", formatLong(&buf, 42));
    try std.testing.expectEqualStrings("-7", formatLong(&buf, -7));
    try std.testing.expectEqualStrings("2147483647", formatLong(&buf, std.math.maxInt(i32)));
    try std.testing.expectEqualStrings("-2147483648", formatLong(&buf, std.math.minInt(i32)));
}

test "formatUnsignedLong writes unsigned decimal" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0", formatUnsignedLong(&buf, 0));
    try std.testing.expectEqualStrings("300", formatUnsignedLong(&buf, 300));
    try std.testing.expectEqualStrings(
        "2147483647",
        formatUnsignedLong(&buf, std.math.maxInt(i32)),
    );
}
