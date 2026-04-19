# Kotori Layer 4A — HTML Reflected Attributes (Design)

Status: design
Owner: kotori / suzume
Date: 2026-04-19
Branch: `feature/kotori-layer-4a-reflection`
Spec basis: WHATWG HTML Standard §2.6 *"Reflecting content attributes in IDL
attributes"* (<https://html.spec.whatwg.org/multipage/common-dom-interfaces.html#reflecting-content-attributes-in-idl-attributes>).

## Goal

Implement a **table-driven** IDL-to-content-attribute reflection system
covering the top tier of HTML element interfaces. Targets +3000 WPT subtests
in `html/dom` (the roadmap Layer 4A budget), principally:

* `html/dom/reflection-*.html` — the spec's own reflection test family
* `html/dom/idlharness*.html` — IDL attribute presence + typing
* `html/dom/interfaces.html` — per-interface attribute coverage

Current state (pre-task): `HTMLElement.id` and `HTMLElement.className` are
the only two IDL reflections implemented natively. `tabIndex` is a polyfill
(`src/js/dom_api.zig:4235` / `:4428`). Everything else is undefined.

## Non-goals

* Full HTML §4.10 form-control *value sanitization* (dirty value flag,
  default values, validity) — the **reflection** layer only guarantees the
  IDL/content mapping, not the higher-level form semantics.
* SVG / MathML IDL attributes (separate interface hierarchy, deferred).
* Enumerated-attribute *canonical case* normalization beyond the minimal
  rules in §2.6.5 (handled per-table-row when the spec requires it).
* URL serialization (`URL`-reflected DOMString): implement the plain
  `DOMString` + `getAttribute` pathway initially; full base-URL resolution
  and parser canonicalization is a Layer 4B follow-up. Tests that assert
  *string equality* pass now; tests that require parsed canonicalization
  are tracked as known-misses.

## §2.6 Reflection Semantics Summary

The spec defines a handful of canonical "IDL attribute types". For each
reflected IDL attribute we record:

| Spec type (§2.6.2 header)                         | Getter                                                                                    | Setter                                                                                            |
|---------------------------------------------------|-------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------|
| *DOMString*                                       | Content attribute value, or `""` if missing                                               | `setAttribute(name, value)`                                                                       |
| *DOMString, limited to only known values*         | Value if it is one of the known values (case-insensitive match per spec); else `""` / the *missing value default* | `setAttribute(name, value)` (no normalization — spec says setter is unfiltered)                   |
| *DOMString?*                                      | `""` / null per spec; most attributes default-to-empty                                    | Same as DOMString; `null` maps to empty string unless *treated as no value* column says otherwise |
| *boolean*                                         | `element.hasAttribute(name)`                                                              | `true` → `setAttribute(name, "")`; `false` → `removeAttribute(name)`                              |
| *long*                                            | Parse integer per §2.4.4.1; return parsed value (clamped to int32) or the *default*       | Convert to string (`toString()`, integer coercion) → `setAttribute`                               |
| *unsigned long*                                   | Parse non-negative integer per §2.4.4.2; clamp to [0, 2³¹−1]; fall back to *default*      | Clamp (negative → 0; > 2147483647 → default) then set                                             |
| *unsigned long (limited to only positive numbers)*| Same as *unsigned long* but default when 0 or missing                                     | Same as *unsigned long* but 0 must *not* be written                                               |
| *URL*                                             | `getAttribute` value parsed against the element's *base URL*; absolute serialization      | Plain `setAttribute(name, value)` — string is stored verbatim                                     |
| *double*                                          | §2.4.4.5 non-negative/positive floating-point parse; NaN → default                        | Convert via ECMAScript ToString of Number                                                         |

Kotori's pragmatic subset for this layer: **DOMString**, **boolean**,
**long (with default)**, **unsigned long (with default)**, **URL-as-string**
(i.e. just plain DOMString — no base-URL resolution), and a small enum
bucket (**DOMString-limited-to-known-values**) for cases where the spec
forces a specific bucket of accepted values. Each row of the reflection
table names exactly one of these.

## Table-driven design (`src/js/html_reflection.zig`)

A single `const table = &[_]ReflectedAttr{ ... };` describes every reflection.
One entry is a comptime-constructible struct:

```zig
pub const ReflType = enum(u8) {
    domstring,
    boolean,
    long,          // signed int32 with default
    unsigned_long, // non-negative int32 with default
    url,           // string-equal today; real URL parse in Layer 4B
};

pub const ReflectedAttr = struct {
    /// HTML interface that owns this IDL attribute. Used to gate the
    /// reflection: only elements whose tag resolves to this interface
    /// (or a descendant via prototype chain) see the mapping. The
    /// special value "HTMLElement" means *every HTML element*.
    iface: []const u8,
    /// IDL attribute name as JS sees it (e.g. "tabIndex", "readOnly").
    /// Must match exactly — we don't do case folding at lookup time.
    idl: []const u8,
    /// Content attribute name (always lowercase ASCII per HTML parser).
    /// For most attributes the IDL name and content name differ only in
    /// case ("tabIndex" → "tabindex") — this column is always authoritative.
    content: []const u8,
    /// IDL attribute type (§2.6.2 bucket).
    type: ReflType,
    /// Default value when the content attribute is missing or parsing
    /// fails. Stored as an i64 for numeric types (cast on return) and
    /// ignored for DOMString / boolean / url.
    default_int: i64 = 0,
};
```

### Dispatch path

Reflections are resolved inline in `domNodeGetProp` / `domNodeSetProp`
(the existing hot path at `src/js/kotori_dom.zig:1253` / `:1585`). After
the *name = "id"* / *name = "className"* fast-paths we delegate to
`html_reflection.lookup(iface, idl)`. On a hit we branch on `type`:

* **domstring** → `getAttr(vm, node, row.content)` (or empty string)
* **boolean**   → `JsValue.initBool(lxb_dom_element_has_attribute(...))`
* **long**      → parse §2.4.4.1; fall back to `row.default_int`
* **unsigned_long** → parse §2.4.4.2; fall back to `row.default_int`
* **url**       → identical to domstring for this layer

The interface name is cheaply available via the element's wrapper object:
`applyInterfaceProto` (`kotori_dom.zig:526`) records the *iface* string
on a hidden slot during wrap. We reuse that — no need to re-resolve at
every property access. For the table-lookup itself we use a small
`StaticStringMap` keyed by `iface ++ "." ++ idl` at comptime.

### Interface gating

A reflection table row fires **only** when:

1. `obj.obj_type == .dom_node` and the node is an Element, **and**
2. The element's resolved HTML interface matches `row.iface` **or** any of
   its ancestors in the HTML interface hierarchy.

Ancestor matching is limited: "HTMLElement" is the universal fallback
(every HTML element inherits its reflections); all other interfaces are
concrete leaves per `kotori_html_interfaces.zig`. That means for the
cost of one `streq` per property access we can handle 99% of cases; the
rare abstract-superclass attributes (e.g. `HTMLMediaElement.src`) are
listed twice — once per concrete descendant.

### Setter semantics

`domstring`: `setAttribute(content, toString(value))`. `null` maps to the
literal string `"null"` per ECMAScript ToString (spec-compatible).

`boolean`: `ToBoolean(value)` → `true` writes an empty-value attribute,
`false` calls `removeAttribute(content)`.

`long`: `ToInt32(value)` stringified via base-10 decimal; always written
(even when value equals the default).

`unsigned_long`: same as `long` but negative inputs fall back to the
default (spec §2.6.2 "setter must, on *setting*, run these steps…").

## Coverage (first cut)

Approximately 120 reflections across these interfaces (grouped by commit
for easy review):

1. **HTMLElement core (global)** — `id`, `className`, `title`, `lang`,
   `dir`, `hidden`, `tabIndex`, `accessKey`, `draggable`, `contentEditable`,
   `spellcheck`, `translate`, `autocapitalize`, `slot`, `nonce`. Already
   partly implemented (`id`, `className`).
2. **HTMLAnchorElement** — `href`, `target`, `download`, `rel`, `hreflang`,
   `type`, `referrerPolicy`, `ping`. (`text` is a descendant-text getter,
   not a reflection — excluded.)
3. **HTMLAreaElement** — `alt`, `coords`, `shape`, `target`, `download`,
   `ping`, `rel`, `referrerPolicy`, `href`.
4. **HTMLImageElement** — `alt`, `src`, `srcset`, `sizes`, `crossOrigin`,
   `useMap`, `isMap`, `width` (*unsigned long*), `height` (*unsigned long*),
   `referrerPolicy`, `decoding`, `loading`.
5. **HTMLInputElement** — `accept`, `alt`, `autocomplete`, `defaultChecked`,
   `dirName`, `disabled`, `formAction`, `formEnctype`, `formMethod`,
   `formNoValidate`, `formTarget`, `height` (ul), `max`, `maxLength` (long),
   `min`, `minLength` (long), `multiple`, `name`, `pattern`, `placeholder`,
   `readOnly`, `required`, `size` (ul, default 20), `src`, `step`, `type`,
   `defaultValue`, `width` (ul).
6. **HTMLButtonElement** — `disabled`, `formAction`, `formEnctype`,
   `formMethod`, `formNoValidate`, `formTarget`, `name`, `type`, `value`.
7. **HTMLFormElement** — `acceptCharset` ("accept-charset"), `action`,
   `autocomplete`, `enctype`, `encoding` (alias of enctype), `method`,
   `name`, `noValidate`, `target`, `rel`.
8. **HTMLSelectElement** — `autocomplete`, `disabled`, `multiple`, `name`,
   `required`, `size` (ul), `type`. (length + options are live collections,
   not reflections.)
9. **HTMLOptionElement** — `disabled`, `label`, `defaultSelected`, `value`.
10. **HTMLTextAreaElement** — `autocomplete`, `cols` (ul, default 20),
    `dirName`, `disabled`, `maxLength`, `minLength`, `name`, `placeholder`,
    `readOnly`, `required`, `rows` (ul, default 2), `wrap`.
11. **HTMLScriptElement** — `src`, `type`, `noModule`, `async`, `defer`,
    `crossOrigin`, `integrity`, `referrerPolicy`, `nonce`.
12. **HTMLLinkElement** — `href`, `crossOrigin`, `rel`, `media`, `hreflang`,
    `type`, `referrerPolicy`, `as`, `disabled`, `integrity`.
13. **HTMLStyleElement** — `media`, `type`, `disabled`.
14. **HTMLMetaElement** — `name`, `httpEquiv` ("http-equiv"), `content`,
    `media`.
15. **HTMLIFrameElement** — `src`, `srcdoc`, `name`, `sandbox`,
    `allowFullscreen`, `width`, `height`, `referrerPolicy`, `loading`,
    `allow`.
16. **HTMLLabelElement** — `htmlFor` ("for").
17. **HTMLOutputElement** — `htmlFor`, `name`.
18. **HTMLFieldSetElement** — `disabled`, `name`.
19. **HTMLBaseElement** — `href`, `target`.
20. **HTMLQuoteElement / HTMLModElement** — `cite`, `dateTime`.
21. **HTMLTableElement** / **…CellElement** / **…RowElement** /
    **…ColElement** — `span` (ul), `colSpan` (ul), `rowSpan` (ul),
    `abbr`, `scope`, `headers`, `align` (historical, still reflected).
22. **HTMLTrackElement** — `kind`, `src`, `srclang`, `label`, `default`.
23. **HTMLSourceElement** — `src`, `type`, `srcset`, `sizes`, `media`,
    `width` (ul), `height` (ul).
24. **HTMLObjectElement** — `data`, `type`, `name`, `useMap`, `width`,
    `height`.
25. **HTMLEmbedElement** — `src`, `type`, `width`, `height`.
26. **HTMLMediaElement (abstract, applies to Audio+Video)** — `src`,
    `crossOrigin`, `preload`, `autoplay`, `loop`, `muted` (reflection of
    `muted` content attr only; dynamic-mute tracking is out of scope),
    `controls`.
27. **HTMLVideoElement** — `width` (ul), `height` (ul), `poster`,
    `playsInline`.
28. **HTMLProgressElement** / **HTMLMeterElement** — `max`, `low`, `high`,
    `min`, `optimum` (double — deferred; we expose them as domstring now
    so read-back round-trips, tests that assert numeric parsing go red).
29. **HTMLDetailsElement** — `open`, `name`.
30. **HTMLDialogElement** — `open`.
31. **HTMLOptGroupElement** — `disabled`, `label`.
32. **HTMLMapElement** — `name`.
33. **HTMLParamElement** — `name`, `value`, `type`, `valueType`.

Enough rows to clear the roadmap's +3000 target while keeping the file
below 600 LOC.

## Testing

* `zig build` green on every sub-commit.
* `zig build test` green on every sub-commit.
* `tests/wpt/run_wpt_parallel.sh --jobs 4 --port 9884 html/dom` — record
  before/after subtest totals in the plan's results section.

## Risks / open questions

* **Polyfill conflict**: `dom_api.zig` installs `tabIndex` via polyfill JS.
  The native reflection takes precedence on the `.dom_node` object-type
  path (descriptor path never fires for `obj_type == .dom_node` — see
  `vm.dom_get_prop` wiring at `kotori_dom.zig:1220`). Safe.
* **Enumerated attribute normalization**: for this layer we return the
  raw content value (lower-cased where the content is always ASCII —
  HTML parser already does this). Tests that rely on the §2.6.5
  "missing value default" getter semantics for *enumerated* attributes
  are explicitly accepted as partially passing.
* **URL-reflected**: we don't canonicalize `href` against a base URL.
  `a.href` returns the raw content attribute for now; the URL parser hookup
  is tracked separately.
