# Layer 1E: HTML vs XML Attribute Case Sensitivity (design)

**Date**: 2026-04-19
**Scope**: `src/js/dom_element.zig` only — file isolation per parallel branch plan.
**WPT target**: `dom/nodes/case.html` and XHTML-document related attribute tests.
**Branch**: `feature/kotori-layer-1e-case`.

## 1. DOM Specification Reference

The authoritative passage is **WHATWG DOM §4.9 "Interface Element → Attributes"**,
read together with the helpers in **DOM §1.5 "Validate and extract"** and the
document-type discrimination in **HTML §2.1** ("HTML documents" vs "XML
documents", where an "HTML document" is a `Document` whose content type is
`text/html`).

The relevant paragraph from DOM §4.9 ("set an attribute value"):

> 1. If attribute is null, then set attribute’s value to value; return.
> 2. **If element is in the HTML namespace and its node document is an HTML
>    document, then set qualifiedName to qualifiedName in ASCII lowercase.**
> 3. Let attribute be the first attribute in element’s attribute list whose
>    qualified name is qualifiedName …

And for `Element.setAttribute(qualifiedName, value)`:

> 1. If qualifiedName does not match the `Name` production in XML, then throw
>    an "InvalidCharacterError" DOMException.
> 2. **If element is in the HTML namespace and its node document is an HTML
>    document, then set qualifiedName to qualifiedName in ASCII lowercase.**
> 3. Let attribute be the first attribute in element’s attribute list whose
>    qualified name is qualifiedName …
> 4. If attribute is null, create an attribute whose local name is qualifiedName,
>    value is value, and node document is element’s node document, then append
>    this attribute to element, and then return.
> 5. Change attribute to value.

The symmetric rules apply to `getAttribute`, `hasAttribute`, and
`removeAttribute` (each gates lowercasing on the HTML-namespace + HTML-document
condition).

For the namespace-aware variants (`*AttributeNS`), case is **never** folded —
case sensitivity is governed by "Validate and extract" (DOM §1.5) which already
runs in `src/js/dom_names.zig`.

## 2. Current Behaviour (as of `main`, commit `f40d232`)

`src/js/dom_element.zig` unconditionally lowercases every non-namespace
attribute name via `lowercaseAttrName`, called from:

- `elementGetAttribute` (line 180)
- `elementSetAttribute` (line 213)
- `elementRemoveAttribute` (line 585)
- `elementHasAttribute` (implicit lowercase in the has-path)
- `elementToggleAttribute` (same)

`lowercaseAttrName` (defined in `src/js/dom_bindings.zig:50`) only folds ASCII
`A`–`Z`; UTF-8 is untouched. This is correct for HTML documents, but violates
the spec for XML documents (including XHTML documents parsed as
`application/xhtml+xml`), which must preserve case.

`dom_api.zig`’s `__buildAttr` closure already gates lowercasing on
`document._isXmlDoc` (see `src/js/dom_api.zig:4820-4830`). That flag is set by
`document.implementation.createDocument()` in `src/js/dom_document.zig:395`.
**The flag exists and is reachable from JS; what’s missing is a native Zig
helper that consults it from `dom_element.zig` before folding case.**

## 3. Failure Enumeration — `dom/nodes/case.html`

Baseline run against `kotori` on `master`:

```
WPT_SUMMARY: PASS=135 FAIL=150 TOTAL=285
```

Failures bucketed by subtest prefix:

| count | prefix                             | root cause (file)                       |
|-------|------------------------------------|-----------------------------------------|
| 75    | `setAttributeNS [Array]`           | `attributes[0]` Proxy (`dom_api.zig`)   |
| 45    | `createElementNS [Array]`          | `localName` includes prefix (`dom_document.zig`) |
| 20    | `getElementsByTagNameNS [Array]`   | collection filter (`dom_selector.zig`)  |
| 5     | `setAttribute abc/Abc/ABC/ä/Ä`     | `attributes[0]` Proxy (`dom_api.zig`)   |
| 5     | `setAttributeNS abc/Abc/ABC/ä/Ä`   | `attributes[0]` Proxy (`dom_api.zig`)   |

**Critical finding:** 100 % of the failing subtests in `case.html` are caused by
bugs located in files that are **off-limits** for this branch. The existing
lowercase-on-set behaviour for HTML is already correct; the missing assertions
all depend on indexed access to `element.attributes[0]`, which is broken in the
Proxy returned by `elementGetAttributes` (`dom_api.zig:2413-2442`), or on
`createElementNS` / `getElementsByTagNameNS` behaviour that lives in other
files.

The +44 subtest target for this branch is therefore **not achievable from
`dom_element.zig` alone**. The design documents the spec-driven change that
_does_ belong in `dom_element.zig` (XML case-preservation) so the work is ready
when the sibling branches unblock their files.

## 4. Design — XML-Document Case Preservation

### 4.1 Helper: `isXmlDocumentForElement`

Add a private helper to `dom_element.zig`:

```zig
/// Returns true if the element’s owner document is an XML document —
/// i.e. document._isXmlDoc === true. Used to gate ASCII-lowercasing of
/// non-namespaced attribute names per DOM §4.9 / HTML §2.1.
///
/// Reads the JS-level flag (set by Document.implementation.createDocument in
/// dom_document.zig and exposed via __buildAttr in dom_api.zig). Falls back to
/// `false` (HTML behaviour) if the flag is absent, preserving legacy behaviour.
fn isXmlDocumentForElement(c: *qjs.JSContext, this_val: qjs.JSValue) bool {
    const owner_doc = qjs.JS_GetPropertyStr(c, this_val, "ownerDocument");
    defer qjs.JS_FreeValue(c, owner_doc);
    if (quickjs.JS_IsUndefined(owner_doc) or quickjs.JS_IsNull(owner_doc))
        return false;
    const flag = qjs.JS_GetPropertyStr(c, owner_doc, "_isXmlDoc");
    defer qjs.JS_FreeValue(c, flag);
    return qjs.JS_ToBool(c, flag) == 1;
}
```

### 4.2 Call-site wrapping

Replace every call of the form

```zig
var lower_buf: [1024]u8 = undefined;
const attr_name = lowercaseAttrName(raw, &lower_buf);
```

with

```zig
var lower_buf: [1024]u8 = undefined;
const attr_name = if (isXmlDocumentForElement(c, this_val))
    raw
else
    lowercaseAttrName(raw, &lower_buf);
```

in these five functions:

1. `elementGetAttribute` (dom_element.zig:167-190)
2. `elementSetAttribute` (dom_element.zig:192-236)
3. `elementRemoveAttribute` (dom_element.zig:572+)
4. `elementHasAttribute` (to be located in the same file)
5. `elementToggleAttribute` (same)

### 4.3 Why this is correct

- **HTML documents** (`_isXmlDoc` absent / falsy) — unchanged behaviour, still
  ASCII-lowercased → case.html HTML subtests remain at current state.
- **XML / XHTML documents** — case is preserved on set, get is
  case-sensitive (a direct lookup of the exact name used on set), matching DOM
  §4.9 bullet 2 (the HTML lowercasing clause simply doesn’t fire).
- **Namespace variants** (`*NS`) — untouched; they already preserve case.

### 4.4 Non-goals

- Fixing `attributes[0]` Proxy behaviour (→ `dom_api.zig`).
- Fixing `createElementNS` localName (→ `dom_document.zig`).
- Fixing `getElementsByTagNameNS` filtering (→ `dom_selector.zig`).
- Changing `setAttributeNS` / `getAttributeNS` (they already preserve case).
- Namespaced lookups inside HTML documents (DOM §4.9 explicitly only folds
  *non-namespaced* set/get).

## 5. Expected Test Impact

- `dom/nodes/case.html` — **no change** (HTML-only; existing lowercasing
  suffices; remaining failures are off-limits files).
- XHTML / XML document attribute tests (`Document-getElementsByTagName-xhtml.xhtml`,
  `Element-getElementsByTagName-change-document-HTMLNess-iframe.xml`, other
  `*xhtml.xhtml` suites) — expected net-positive delta once XML documents stop
  having their attribute names mangled. Magnitude to be measured by the plan.
- `zig build test` — no regressions; all call sites fall through to the
  previous behaviour when `_isXmlDoc` is absent.

## 6. Risk

- **Performance**: one extra `JS_GetPropertyStr` + `JS_ToBool` per
  attribute operation. Both are cheap QuickJS ops; attribute mutation is not
  a hot path in benchmarks. Acceptable.
- **Detached elements without `ownerDocument`**: helper returns `false`
  (HTML behaviour). Safe default — matches the pre-existing assumption.
- **Elements created inside XML fragments loaded as text/html**: treated as
  HTML (correct per HTML §2.1 — the content-type of the document defines
  HTML-ness, not the element).
