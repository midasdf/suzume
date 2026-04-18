# Layer 1A — Namespace/QName Validation Design Spec

**Date**: 2026-04-19
**Layer**: 1A (master roadmap: `2026-04-17-kotori-suzume-wpt-100-roadmap.md`)
**Target subtests**: dom/nodes +101 (createDocument) + incremental createElementNS / createDocumentType / createAttribute* unblocks
**Owner files**: `src/js/kotori_dom.zig`, `src/js/dom_document.zig`, `src/js/dom_element.zig`

---

## Context

dom/nodes `DOMImplementation-createDocument.html` runs the 183-row `createElementNS_tests` table through `implementation.createDocument(ns, qname, doctype)` and requires exact `NAMESPACE_ERR` / `INVALID_CHARACTER_ERR` exception selection. Session #7 closed `createDoc` to 330/434. The remaining ~101 failures almost all live in this table; they split roughly into:

1. Rows that require **reserved prefix** rules (`xml` / `xmlns` / `http://www.w3.org/2000/xmlns/`) to fire with exactly the right exception type.
2. Rows that look like pure QName grammar failures (`"a:0"`, `"namespaceURI:{"`, `"1foo"`) whose correctness already depends on the `isValidQName` character classes.
3. Rows that depend on the `""` namespace being coerced to `null` **before** the prefix-vs-namespace check (rows with `""` namespace + `"f:oo"` must throw `NAMESPACE_ERR` not `INVALID_CHARACTER_ERR`).

Layer 1A centralises the "validate and extract" algorithm for both the kotori-native VM path (`kotori_dom.zig`) and the legacy QuickJS path (`dom_document.zig`, `dom_element.zig`), eliminates duplicate-but-drifted copies, and unlocks the above rows.

---

## Spec summary (DOM §1.5 + Infra §5)

### DOM §1.5 "validate and extract"
Input: `namespace` (nullable DOMString), `qualifiedName` (DOMString).

1. If `namespace` is the empty string, set it to `null`.
2. **Validate `qualifiedName`** against the `QName` production (XML Names §4). On failure → `InvalidCharacterError`.
3. Let `prefix` be `null`.
4. Let `localName` be `qualifiedName`.
5. If `qualifiedName` contains `":"` (U+003A): set `prefix` to the substring before the first `":"`, `localName` to the substring after.
6. If `prefix` is non-null and `namespace` is null → `NamespaceError`.
7. If `prefix` is `"xml"` and `namespace` is not the XML namespace (`http://www.w3.org/XML/1998/namespace`) → `NamespaceError`.
8. If either `qualifiedName` or `prefix` is `"xmlns"` and `namespace` is not the XMLNS namespace (`http://www.w3.org/2000/xmlns/`) → `NamespaceError`.
9. If `namespace` is the XMLNS namespace and **neither** `qualifiedName` nor `prefix` is `"xmlns"` → `NamespaceError`.
10. Return the tuple `(namespace, prefix, localName)`.

### Infra §5 + XML Names QName grammar
```
QName      ::= PrefixedName | UnprefixedName
PrefixedName   ::= Prefix ':' LocalPart
UnprefixedName ::= LocalPart
Prefix         ::= NCName
LocalPart      ::= NCName
NCName         ::= Name - (Char* ':' Char*)     /* i.e., an XML Name, no colons */
Name           ::= NameStartChar (NameChar)*
NameStartChar  ::= ':' | [A-Z] | '_' | [a-z] | [#xC0-#xD6] | … (Unicode ranges)
NameChar       ::= NameStartChar | '-' | '.' | [0-9] | #xB7 | …
```

Browsers accept the **lenient** variant: start-char checked strictly for the first char of prefix (unprefixed) and localName; middle chars only reject hard-invalid bytes (ASCII whitespace/controls + a small punctuation set — the current `isHardInvalidNameChar` set at `src/js/kotori_dom.zig:2027`). This matches every assertion in `Document-createElementNS.js` and `Document-createElement.html`.

Crucially, the **Name** production (used by `createElement`, `createAttribute`, `createProcessingInstruction`) **allows `:` freely** whereas **QName** does not. `Document-createElement.html` explicitly validates that `":"`, `":foo"`, `"f:oo"`, `"foo:"`, `"f:o:o"`, `"f::oo"` are all **VALID** inputs to `createElement` (lines 48-53 of `/tmp/wpt/dom/nodes/Document-createElement.html`).

---

## Algorithm: validateAndExtract

### Target Zig signature (one shared implementation)

```zig
pub const ValidatedName = struct {
    namespace: ?[]const u8,   // post-coercion: "" → null
    prefix: ?[]const u8,      // null when no colon in qn
    local_name: []const u8,
};

pub const NameValidationError = error{ InvalidCharacter, NamespaceMismatch };

/// DOM §1.5. `qn` must not be zero-length (callers decide whether "" is
/// valid — e.g. createDocument skips the algorithm when qn == "").
pub fn validateAndExtract(qn: []const u8, ns_in: ?[]const u8) NameValidationError!ValidatedName;
```

Returning `error{…}` keeps allocation-free control flow; each native binding maps `error.InvalidCharacter` → `InvalidCharacterError` DOMException and `error.NamespaceMismatch` → `NamespaceError` DOMException.

### Current state

| Path | File | Range | Notes |
|------|------|-------|-------|
| kotori native | `src/js/kotori_dom.zig:2095-2143` | `fn validateAndExtract(qn, ns_in) NameValidationError!ValidatedName` | **Full spec compliant.** Handles "" → null coercion, all six numbered steps. |
| QuickJS (namespace APIs) | `src/js/dom_document.zig:1951-2034` | `fn validateAndExtract(c, ns_arg, qn_arg) ?qjs.JSValue` | Implements steps 1–6; also does a superfluous `localName[0]` start-char check (line 2028) **after** step 6 — matches reality but duplicates the check that `isValidQName` already performs. |
| QuickJS (createDocument) | `src/js/dom_document.zig:470-496` | inline in `implCreateDocument` | Duplicated step 3/4/5 logic, **missing step 6** (`XMLNS_NS` namespace with neither qname/prefix equal to `xmlns`). |
| QuickJS (setAttributeNS) | `src/js/dom_element.zig:334-393` | inline in `elementSetAttributeNS` | Re-implements steps 1–4 with distinct messages; also runs `isValidXmlQName` (line 338) **in addition to** `isValidQName` (line 335) — functionally equivalent but two separate functions coexist in `dom_document.zig` (`isValidXmlName`, `isValidXmlQName`, `isValidQName`). |
| kotori native (createDocument) | `src/js/kotori_dom.zig:5544-5548` | calls shared `validateAndExtract` | Already routed. |
| kotori native (createElementNS) | `src/js/kotori_dom.zig:2172-2174` | calls shared `validateAndExtract` | Already routed. |
| kotori native (createAttributeNS) | `src/js/kotori_dom.zig:2360-2363` | calls shared `validateAndExtract` | Already routed. |

### Gap

1. **QuickJS `implCreateDocument`** at `src/js/dom_document.zig:470-496` duplicates the algorithm inline and is missing step 6 (`XMLNS namespace with non-xmlns qname`). Row 171 of the table (`["http://www.w3.org/2000/xmlns/", "xmlfoo", "NAMESPACE_ERR"]`) currently depends on this working. In the kotori path it works; in QuickJS path it would silently succeed.
2. **QuickJS `dom_document.zig:1951-2034`** and kotori `kotori_dom.zig:2095-2143` each keep private copies of essentially the same algorithm. Divergence is a continuing risk (e.g. the "empty namespace → null" step is in both, but if a future fix goes to one path only, the dom/nodes numbers diverge between `SUZUME_JS=kotori` and `SUZUME_JS=quickjs`).
3. **QuickJS `elementSetAttributeNS`** at `src/js/dom_element.zig:334-393` is a third open-coded copy. Message text differs from spec.

### Proposed change

- **Move** `validateAndExtract` + `isValidQName` + `isHardInvalidNameChar` + `isInvalidNameStartChar` to a new **single source** module `src/js/dom_names.zig`, exporting:
  - `pub fn isValidName(name: []const u8) bool` (XML Name production — `:` allowed anywhere)
  - `pub fn isValidQName(name: []const u8) bool` (XML QName production — at most one `:` in the "must be NCName" sense, lenient middle chars)
  - `pub fn validateAndExtract(qn: []const u8, ns: ?[]const u8) NameValidationError!ValidatedName`
- **Import** `dom_names` from `kotori_dom.zig`, `dom_document.zig`, `dom_element.zig`. Delete the inline duplicates in `dom_document.zig:470-496`, `dom_document.zig:1951-2034`, `dom_element.zig:334-393`, `kotori_dom.zig:2095-2143`.
- Retain a thin QuickJS-side wrapper `fn validateAndExtractQjs(c, ns_arg, qn_arg) ?qjs.JSValue` that calls the shared algorithm and maps errors to `throwDOMException(…)` — the existing callers at `dom_document.zig:2047` and `kotori_dom.zig:2047-style` would use the same backend.
- `implCreateDocument` at `dom_document.zig:470` replaces its 26-line inline block with one call:
  ```zig
  if (qn.len > 0) {
      if (validateAndExtractQjs(c, ns_val, qn_val)) |err_exc| {
          _ = err_exc;
          return quickjs.JS_EXCEPTION();
      }
  }
  ```

---

## Algorithm: validateQualifiedName (Name vs QName distinction)

### Current state

`kotori_dom.zig:2061-2082` defines `isValidQName` with a lenient browser grammar (passes all 183 `createElementNS_tests` rows). `dom_document.zig:249-267` also defines `isValidQName` with a subtly different algorithm: it allows non-start-char colons and does NOT reject trailing `>` for unprefixed names. `dom_document.zig:237-243` defines a stricter `isValidXmlQName` (full NCName on both sides of colon); it is only called from `setAttributeNS`.

There is **no** `isValidName` (non-colon-restricted) helper. `nativeCreateElement` at `kotori_dom.zig:1924` currently calls `isValidQName`, which over-rejects by treating `:` specially.

### Gap

- `Document-createElement.html:48-53` lists `":"`, `":foo"`, `"f:oo"`, `"foo:"`, `"f:o:o"`, `"f::oo"` under `valid` and `"1foo"`, `"1:foo"`, `"-foo"`, `".foo"`, `"fo o"`, `"<foo"`, `"}foo"` under `invalid`. Our `isValidQName` rejects `":foo"` and `"foo:"` at colon-split time, so `createElement(":foo")` throws `InvalidCharacterError` when the WPT test asserts success.
- This is a separate bug from the namespace/reserved-prefix work but lives in the same dispatch layer and is noted here because the spec is explicit: **`createElement`/`createAttribute`/`createProcessingInstruction` validate against Name, not QName.**

### Proposed change

- Add `isValidName` to `dom_names.zig`. Rules:
  - Empty → false.
  - First char: must not be `isInvalidNameStartChar` **except** `:` is allowed (NameStartChar permits `:`).
  - Interior chars: must not be `isHardInvalidNameChar`.
  - Trailing `>` → invalid (matches WPT row `"foo>"`).
- Redirect `nativeCreateElement` (`kotori_dom.zig:1924`) and `documentCreateElement` (`dom_document.zig:1937`) to use `isValidName` instead of `isValidQName` / `isValidElementName`.
- `nativeCreateAttribute` (`kotori_dom.zig:2329`) currently only rejects `""` which matches `attributes.js:1` (`invalid_names = [""]`) — keep that path, but add optional `isValidName` guard in XML document mode (both WPT fixtures only exercise `""` as invalid, so this is a no-op today; do it anyway for spec completeness).

---

## Apply sites

### createElement/NS

**Spec quote (DOM §4.5.1)**:
> The createElement(localName, options) method steps are:
> 1. If localName does not match the Name production, then throw an "InvalidCharacterError" DOMException.

**Spec quote (DOM §4.5.2)**:
> The createElementNS(namespace, qualifiedName, options) method steps are:
> 1. Let (namespace, prefix, localName) be the result of validating and extracting namespace and qualifiedName.

**Current state**
- kotori `createElement`: `src/js/kotori_dom.zig:1918-1978`. Uses `isValidQName` (wrong — should be `isValidName`).
- kotori `createElementNS`: `src/js/kotori_dom.zig:2157-2239`. Uses shared `validateAndExtract` — correct.
- QuickJS `createElement`: `src/js/dom_document.zig:1923-1949`. Uses `isValidElementName` which delegates to `isValidXmlName` (stricter XML Name — rejects `":"` at start). Same bug.
- QuickJS `createElementNS`: `src/js/dom_document.zig:2036+`. Uses `validateAndExtract` QuickJS variant — correct.

**Gap**: `createElement` in both paths uses QName/XML-Name, rejecting colonated input that WPT expects to succeed.

**Proposed change**: Replace `isValidQName(tag_raw)` at `kotori_dom.zig:1924` and `isValidElementName(tag)` at `dom_document.zig:1937` with `isValidName(tag)`.

**Test plan**
- `/tmp/wpt/dom/nodes/Document-createElement.html` — 41 valid × 3 doc types + 10 invalid × 3 = 153 subtests; ~36 currently failing on colonated names will flip green.
- `/tmp/wpt/dom/nodes/Document-createElementNS.html` + `.js` — 183 subtests. No regression expected; `createElementNS` is untouched.

**Risk**: `nativeCreateElement` lowercases via lexbor; a leading-colon tag `:foo` fed to lexbor has unknown behaviour. Current `createJsOnlyElement` path (`kotori_dom.zig:1952`) takes the XML-doc branch and wraps as a JS-only element, which is safe; the HTML-doc branch at 1958 calls lexbor directly. Must verify `lxb_dom_document_create_element(doc, ":foo", 4, null)` returns non-null and doesn't corrupt lexbor's element table. **If lexbor barfs on `:` at start, wrap the HTML path with the same JS-only fallback `createJsOnlyElement` already provides.**

### createAttribute/NS

**Spec quote (DOM §4.9.1)**:
> The createAttribute(localName) method steps are:
> 1. If localName does not match the Name production in XML, then throw an "InvalidCharacterError" DOMException.
> 2. If this is an HTML document, then set localName to localName in ASCII lowercase.
> 3. Return a new attribute whose local name is localName and node document is this.

**Spec quote (DOM §4.9.1 createAttributeNS)**:
> 1. Let (namespace, prefix, localName) be the result of validating and extracting namespace and qualifiedName.
> 2. Return a new attribute whose namespace is namespace, namespace prefix is prefix, local name is localName, and node document is this.

**Current state**
- kotori `createAttribute`: `src/js/kotori_dom.zig:2319-2344`. Only rejects `""`. HTML lowercase via ASCII fold (`lower_buf`) bounded to 256 bytes. Matches `attributes.js:1` (`invalid_names = [""]`).
- kotori `createAttributeNS`: `src/js/kotori_dom.zig:2348-2364`. Uses shared `validateAndExtract` — correct.
- QuickJS `createAttribute`: registered via inline JS eval at `src/js/dom_api.zig:4712-4730` — an inline JS closure that builds an Attr object; no native validation. **This path is effectively unvalidated.**
- QuickJS `createAttributeNS`: same registration site.

**Gap**: QuickJS path does not run `validateAndExtract`. Rows in `createElementNS_tests` under `createAttributeNS` would all return attributes when they should throw. The WPT harness only runs these tests against the main `document` object — which in suzume is either kotori or QuickJS depending on `SUZUME_JS` env var — so regressions show up on only half the matrix.

**Proposed change**
- Replace the inline JS closure at `dom_api.zig:4712-4730` with `qjs.JS_NewCFunction` pointing at new functions `dom_doc.documentCreateAttribute` and `dom_doc.documentCreateAttributeNS`, modeled on `documentCreateElementNS`. Both must call the shared `validateAndExtract` / `isValidName` backend.
- kotori `createAttribute` remains as-is (correct per WPT).

**Test plan**
- `/tmp/wpt/dom/nodes/Document-createAttribute.html` (55 lines). `attributes.js` defines `valid_names = ["x","X",":","a:0","invalid^Name","\\","'",'"',"0","0:a",":a","x:y:x","~"]` and `invalid_names = [""]`. In HTML doc, valid→lowercased; in XML doc, valid→preserved. Current QuickJS path likely passes by accident (returns an Attr for anything non-empty); kotori should be green already but needs re-verification after dom_names refactor.
- `/tmp/wpt/dom/nodes/attributes.html` (attributes.js helper tests): ~30 subtests that probe attribute identity after setAttributeNS roundtrips.
- `/tmp/wpt/dom/nodes/attributes-namednodemap.html`: cross-cutting; mostly orthogonal but runs createAttribute.

**Risk**: Replacing the JS-eval closure with a native function may break Attr callers that expect the `__val` / custom `value` setter wired by the JS closure at `dom_api.zig:4170`. Mitigation: the native function returns a JS object with the same shape (see `createAttrObject` kotori path at `kotori_dom.zig:2249-2299`) — port that shape into QuickJS.

### setAttribute/NS

**Spec quote (DOM §4.9.2)**:
> The setAttribute(qualifiedName, value) method steps are:
> 1. If qualifiedName does not match the Name production in XML, then throw an "InvalidCharacterError" DOMException.
> 2. Otherwise, if this is in the HTML namespace and its node document is an HTML document, then set qualifiedName to qualifiedName in ASCII lowercase.
> 3. Let attribute be the first attribute in this's attribute list whose qualified name is qualifiedName; otherwise null.
> 4. If attribute is null, create an attribute whose local name is qualifiedName, value is value, and node document is this's node document, then append this attribute to this, and then return.
> 5. Change attribute to value.

**Spec quote (DOM §4.9.3 setAttributeNS)**:
> The setAttributeNS(namespace, qualifiedName, value) method steps are:
> 1. Let (namespace, prefix, localName) be the result of validating and extracting namespace and qualifiedName.
> 2. Set an attribute value for this using localName, value, and also prefix and namespace.

**Current state**
- kotori `nativeSetAttribute`: `src/js/kotori_dom.zig:3045-3070`. **No validation at all** — does not call `isValidName`. Accepts any string.
- kotori `nativeSetAttributeNS`: `src/js/kotori_dom.zig:3073-3097`. **No validation at all** — does not call `validateAndExtract`.
- QuickJS `elementSetAttributeNS`: `src/js/dom_element.zig:318-393`. Inline validation with correct six steps but duplicate code.
- QuickJS `elementSetAttribute`: location TBD — not inspected in this audit.

**Gap**: kotori path does zero validation on `setAttribute`/`setAttributeNS`. WPT `Element-setAttribute.html` currently has only 2 asserts and passes by luck (the asserts are about value, not rejection); but `ParentNode-querySelectors-space-and-dash-attribute-value.html` and `attributes.html` exercise the invalid-qname throw path and depend on correct exception emission.

**Proposed change**
- kotori `nativeSetAttribute`: at line 3047, after `args.len < 2` check, add `if (!isValidName(n)) { vm.pending_throw = … "InvalidCharacterError"; return JsValue.undefined_val; }`.
- kotori `nativeSetAttributeNS`: at line 3075, add `const v = validateAndExtract(qn, ns_in) catch |err| return try queueValidationErr(vm, err);` and then use `v.local_name`/`v.prefix` to form the lexbor call (keeping existing full-qname write path for simplicity, since lexbor stores qualified_name verbatim).
- QuickJS `elementSetAttributeNS`: replace inline block (`dom_element.zig:334-393`) with shared `validateAndExtractQjs` call.

**Test plan**
- `/tmp/wpt/dom/nodes/Element-setAttribute.html` (38 lines, 2 subtests) — currently passes, must stay green.
- `/tmp/wpt/dom/nodes/Element-setAttributeNS.html` — if present (not in this directory listing; confirm before coding).
- `/tmp/wpt/dom/nodes/attributes.html` — hundreds of subtests exercising qname validation paths. Most direct win.
- `/tmp/wpt/dom/nodes/Element-setAttribute-crbug-1138487.html` — edge case regression guard.

**Risk**: Any caller code (suzume HTML parser, test shims) that sets attributes with malformed names (e.g. synthetic `__prefix` pseudo-attrs) will suddenly throw. Mitigation: audit internal setAttribute callers in `kotori_dom.zig` (search for `lxb_dom_element_set_attribute` without going through `nativeSetAttribute`). Most internal writes already bypass the JS native wrapper and go directly to lexbor, so JS-visible behaviour is what tightens.

### createDocument/createDocumentType

**Spec quote (DOM §7.1.2 createDocument)**:
> 1. Let document be a new XMLDocument.
> 2. Let element be null.
> 3. If qualifiedName is not the empty string, then set element to the result of running the internal createElementNS steps, given document, namespace, qualifiedName, and an empty dictionary.

**Spec quote (DOM §7.1.3 createDocumentType)**:
> 1. Validate qualifiedName.
> 2. Return a new doctype, with qualifiedName as its name, publicId as its public ID, and systemId as its system ID, and with its node document set to the associated document of this.

**Current state**
- kotori `nativeImplementationCreateDocument`: `src/js/kotori_dom.zig:5513-5743`. Calls shared `validateAndExtract` at line 5545 — correct.
- kotori `nativeImplementationCreateDocumentType`: `src/js/kotori_dom.zig:5747-5812`. **Only checks hard-invalid bytes** (`>`, space, tab, CR, LF) at lines 5756-5763. Missing full Name production check.
- QuickJS `implCreateDocument`: `src/js/dom_document.zig:409-540+`. Has inline duplicate of steps 3-5 at 478-496; **missing step 6** (XMLNS_NS with non-xmlns qname).
- QuickJS `implCreateDocumentType`: `src/js/dom_document.zig:270-406`. Same weak validator as kotori (`dom_document.zig:284-289`) — only `>`, space, tab, CR, LF.

**Gap**
1. QuickJS `implCreateDocument` step 6 is missing (row 171 of the test table).
2. Both `createDocumentType` paths use a too-permissive validator. DOM §8.2 "validate" requires full Name validation. However, `/tmp/wpt/dom/nodes/DOMImplementation-createDocumentType.html` is permissive itself — its test vector accepts many weird characters (`@foo`, `foo@`, `1foo`, `{`, `}`, etc. are all listed as null-expected), and only `edi:>` and `edi:a ` throw. So current implementation is already close; the fix is aligning the character set exactly.

**Proposed change**
- QuickJS `implCreateDocument`: replace lines 470-496 with single shared-algorithm call.
- Both `createDocumentType` paths: keep current hard-invalid-byte validator as-is; the WPT fixture agrees. Optionally promote the validator to a helper `isValidDoctypeName` in `dom_names.zig` to make the difference from Name/QName explicit.

**Test plan**
- `/tmp/wpt/dom/nodes/DOMImplementation-createDocument.html` — 172 lines. Runs all 183 `createElementNS_tests` rows + 15 doctype-related rows = ~200 subtests. Session #7 passed 330/434 of the larger `createDoc` batch. Layer 1A targets the remaining ~101. Row 171 (XMLNS step 6) is the biggest single win in QuickJS mode.
- `/tmp/wpt/dom/nodes/DOMImplementation-createDocumentType.html` — 124 lines, ~80 subtests. Currently ~all green; confirm no regression.
- `/tmp/wpt/dom/nodes/DOMImplementation-createDocument-with-null-browsing-context-crash.html` — crash guard.

**Risk**: Merging QuickJS `implCreateDocument`'s inline validation into shared backend may change exception message text. Tests use `assert_throws_dom("NAMESPACE_ERR", …)` which checks the DOMException's `code` / `name` attributes — message text is **not** asserted, so message changes are safe. However, `DOMException.code` mapping at `kotori_dom.zig:4534-4542` must continue to return `5` for `InvalidCharacterError` and `14` for `NamespaceError`.

---

## Integration with kotori_dom bindings

**Where the hook lives**: `kotori_dom.zig` already routes all three NS-taking APIs (`createElementNS`, `createAttributeNS`, `implementation.createDocument`) through the shared `validateAndExtract` at line 2095. The refactor is internal — move the function into `dom_names.zig` and `const names = @import("dom_names.zig");` at top of `kotori_dom.zig` (alongside existing `@import("events.zig")` patterns).

**Exception dispatch**: `queueValidationErr` at `kotori_dom.zig:2147-2153` is the one place that maps `error.InvalidCharacter` / `error.NamespaceMismatch` into the VM's `pending_throw`. Keep it local to kotori_dom; the shared module stays VM-agnostic.

**QuickJS counterpart**: Add `fn validateAndExtractQjs(c: *qjs.JSContext, ns_arg, qn_arg) ?qjs.JSValue` next to `throwDOMException` in `dom_api.zig`. Returns `null` on success, `JS_EXCEPTION()` on error (after calling the shared algorithm and `throwDOMException` for the appropriate type).

**No new cross-file dependencies beyond:**
- `kotori_dom.zig` → `dom_names.zig` (new)
- `dom_document.zig` → `dom_names.zig` (new)
- `dom_element.zig` → `dom_names.zig` (new, already imports `dom_doc`)

---

## Test plan (consolidated)

| WPT file | Subtests (approx) | Current status | Target |
|----------|-------------------|----------------|--------|
| `dom/nodes/DOMImplementation-createDocument.html` | 434 | 330 passing (session #7) | +101 = 431 |
| `dom/nodes/DOMImplementation-createDocumentType.html` | ~80 | Mostly green | Confirm no regression |
| `dom/nodes/Document-createElement.html` | 153 | ~117 passing (colonated names fail) | +36 = 153 |
| `dom/nodes/Document-createElementNS.html` | ~596 | 56 passing | No change from 1A; deeper prefix handling is Layer 1E |
| `dom/nodes/Document-createAttribute.html` | ~55 | Mostly green (kotori) | Confirm QuickJS path after refactor |
| `dom/nodes/Element-setAttribute.html` | 2 | Green | Keep green |
| `dom/nodes/Element-setAttribute-crbug-1138487.html` | ~5 | ? | Regression guard |
| `dom/nodes/attributes.html` | ~300 | Partial | +30-50 from shared QName validation |

### Verification procedure

1. `zig build` must succeed.
2. `zig build test` unit tests must stay green.
3. `SUZUME_JS=kotori zig-out/bin/suzume /tmp/wpt/dom/nodes/DOMImplementation-createDocument.html` — parse the `<script>` output; count `PASS` vs `FAIL`; compare against baseline.
4. Repeat with `SUZUME_JS=quickjs` — both paths must converge now that the algorithm is shared.
5. Run the full `dom/nodes` directory via the existing WPT harness; delta must be ≥ +101 with zero regressions.

---

## Risk / regression

| Risk | Probability | Mitigation |
|------|-------------|------------|
| Lexbor rejects `:foo` / `foo:` in `createElement` HTML path | Medium | Wrap HTML-doc branch with `createJsOnlyElement` fallback on lexbor null return. |
| `setAttribute` tightening breaks suzume's internal HTML parser shims | Medium | Internal parsing goes directly through `lxb_dom_element_set_attribute`, not the JS native wrapper, so JS tightening is isolated. Grep for `nativeSetAttribute` direct callers before merging. |
| QuickJS `createAttribute` refactor loses the custom `value` setter plumbing at `dom_api.zig:4170` | Medium | Port the JS closure's value getter/setter logic into the native `createAttrObject` shape. Kotori path already does this; clone that structure. |
| Exception `.code` mapping drifts between Kotori and QuickJS paths | Low | Single source of truth for `NameValidationError → DOMException.name` is acceptable (errors carry the kind; DOMException constructor maps name to code). |
| `DocumentType` name validation tightened → WPT row like `"@foo"` regresses | Low | DO NOT change `createDocumentType` validator beyond hard-invalid-byte check. The fixture explicitly accepts `"@foo"`. |
| Row 169 `["http://www.w3.org/2000/xmlns/", "xml", "NAMESPACE_ERR"]` interaction | Low | The shared algorithm already handles: `xml` (qname, no colon) + XMLNS_NS → step 9 fires because neither qname nor prefix equals `xmlns`. |

---

## Acceptance criteria

- [ ] `src/js/dom_names.zig` created with `isValidName`, `isValidQName`, `validateAndExtract`.
- [ ] `src/js/kotori_dom.zig` 2087-2143 deleted; imports from `dom_names`.
- [ ] `src/js/dom_document.zig` 249-267, 237-243, 1951-2034, 470-496 deleted; imports from `dom_names`.
- [ ] `src/js/dom_element.zig` 334-393 replaced with shared call.
- [ ] `nativeCreateElement` (both paths) uses `isValidName`, not `isValidQName`.
- [ ] `nativeSetAttribute` and `nativeSetAttributeNS` (kotori) validate per DOM §4.9.
- [ ] QuickJS `createAttribute`/`createAttributeNS` (at `dom_api.zig:4712-4730`) replaced with native JS_NewCFunction bindings that call shared algorithm.
- [ ] `zig build` + `zig build test` green.
- [ ] `DOMImplementation-createDocument.html` passes ≥ 431/434 (target +101).
- [ ] `Document-createElement.html` passes 153/153 (target +36).
- [ ] No regression in `Document-createElementNS.html`, `Element-setAttribute.html`, `DOMImplementation-createDocumentType.html`.
- [ ] Both `SUZUME_JS=kotori` and `SUZUME_JS=quickjs` produce identical numbers for the above files.

---

## Out of scope (deferred)

- **Layer 1E (Case sensitivity)** — HTML-doc attribute name ASCII lowercasing beyond what's already in `nativeCreateAttribute`. The `attributes.html` fixture cross-cuts both 1A and 1E; 1A only guarantees the validation step is correct.
- **`createElementNS` prefix reflection** — `element.prefix`, `element.localName`, `tagName` getter behaviour for prefixed elements past creation time. The master roadmap flags dom/nodes `createElementNS` at 56/596; fixing validation alone will not unlock most of the remaining 540. That needs a prefix-aware prototype/getter rewrite (Layer 1E territory).
- **XML Name Unicode ranges** — current validator is "lenient": non-ASCII bytes are unconditionally accepted. Full XML §2.3 compliance (e.g. rejecting `U+FFFE`/`U+FFFF`) is a separate pass. `createElementNS_tests` explicitly accepts `"\uFFFFfoo"` as **valid**, so strict mode would regress the suite.
- **`attributeOldValue` MutationObserver integration** — Layer 1B.
- **DOMParser XML mode strict parsing** — Layer 1F/1E.
- **`setAttributeNode` / `getAttributeNode`** name validation — Layer 1D (NamedNodeMap).
- **`Element.insertAdjacentElement` / `insertAdjacentText`** — not NS-validation related.

---

## Estimate commentary

Master roadmap lists Layer 1A as +101 subtests. Based on this investigation:
- **+101 (createDocument)** — confirmed correct; most come from QuickJS `implCreateDocument` step-6 fix + rows where shared algorithm is invoked consistently.
- **+36 (createElement colonated names)** — **new discovery**; not in master roadmap's +101 estimate. Arises from `Document-createElement.html:48-53` valid list. If scope is strictly "namespace/QName", this overspills — recommend expanding Layer 1A target to **+137** or moving the `isValidName` change to a separate micro-spec "Layer 1A.1: createElement Name vs QName distinction". Either way the fix is one-line and the risk is low.
- **+30–50 (attributes.html QName tightening)** — optimistic upper bound if kotori `setAttribute`/`setAttributeNS` validation gaps currently cause silent-success on bad names. Likely some of this already accidentally passes because the bad-name attributes round-trip through lexbor without error.

Total realistic: **+130 to +180 dom/nodes subtests** from this layer alone, concentrated in the createDocument and createElement fixtures.
