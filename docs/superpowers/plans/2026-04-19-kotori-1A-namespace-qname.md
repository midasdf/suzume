# kotori Layer 1A — Namespace/QName Validation Consolidation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consolidate the three duplicated namespace/QName validation implementations into a single shared `src/js/dom_names.zig` module, fix `createElement`'s Name-vs-QName bug (colonated names like `":foo"`, `"f:oo"`, `"foo:"`, `"f:o:o"`), add spec-correct QName validation to the currently-unvalidated QuickJS `createAttribute`/`createAttributeNS` and kotori `nativeSetAttribute`/`nativeSetAttributeNS` paths. Target: +137 dom/nodes WPT subtests minimum (+101 createDocument, +36 createElement), with upside to ~+180 from `attributes.html` tightening.

**Architecture:** New `src/js/dom_names.zig` module as the single source of truth for XML Name / XML QName / DOM §1.5 "validate and extract". Exports `isValidName`, `isValidQName`, `validateAndExtract`, `NameValidationError`, `ValidatedName`. VM-agnostic (no QuickJS / kotori VM types). Each binding site maps the algorithm's `error.InvalidCharacter` → `InvalidCharacterError` DOMException and `error.NamespaceMismatch` → `NamespaceError` DOMException at its own boundary. kotori-side wrapper `queueValidationErr` (already exists at `kotori_dom.zig:2147`) stays local. QuickJS-side wrapper `validateAndExtractQjs` added next to `throwDOMException` in `dom_api.zig`.

**Tech Stack:** Zig 0.15.2, lexbor (HTML/XML parser), kotori JS engine (`src/js/kotori/`), QuickJS (fallback JS engine), WPT (Web Platform Tests).

**Spec:** `docs/superpowers/specs/2026-04-19-kotori-1A-namespace-qname-design.md`
**Parent roadmap:** `docs/superpowers/specs/2026-04-17-kotori-suzume-wpt-100-roadmap.md` (Layer 1A sub-project)

---

## File Structure

### Files to create
- `src/js/dom_names.zig` — new module. Exports `isValidName`, `isValidQName`, `validateAndExtract`, `NameValidationError`, `ValidatedName`. Contains private helpers `isInvalidNameStartChar`, `isHardInvalidNameChar`. Zero dependencies on VM types; pure `std` + slices.
- Unit tests appended to existing `tests/test_kotori_dom.zig` (or a new `tests/test_dom_names.zig` if the test harness prefers per-module files — inspect existing convention in Task 0).

### Files to modify
- `src/js/kotori_dom.zig` — delete private `validateAndExtract` at L2095-L2143, `isValidQName` at L2061-L2082, `isInvalidNameStartChar`/`isHardInvalidNameChar` helpers; import from `dom_names`. Fix `nativeCreateElement` at L1924 to use `isValidName` not `isValidQName`. Add validation calls inside `nativeSetAttribute` at L3045-L3070 and `nativeSetAttributeNS` at L3073-L3097.
- `src/js/dom_document.zig` — delete inline `validateAndExtract` at L1951-L2034, duplicate `isValidQName` at L249-L267, `isValidXmlQName` at L237-L243, and inline step 3-5 block at L470-L496 inside `implCreateDocument`. Fix `documentCreateElement` at L1937 to use `isValidName` not `isValidElementName`. Import from `dom_names`.
- `src/js/dom_element.zig` — replace inline steps 1-4 block at L334-L393 in `elementSetAttributeNS` with one call to shared `validateAndExtractQjs`. Import from `dom_names`.
- `src/js/dom_api.zig` — replace the inline JS-eval closure registering `createAttribute`/`createAttributeNS` at L4712-L4730 with `qjs.JS_NewCFunction` bindings that call new native functions `documentCreateAttribute` / `documentCreateAttributeNS` (added in `dom_document.zig`). Add `validateAndExtractQjs` helper near `throwDOMException`.

### Files to NOT modify
- `src/js/kotori/vm.zig`, `src/js/kotori/object.zig` — no VM changes needed.
- `src/js/dom_node.zig`, `src/js/kotori_runtime.zig`, `src/js/events.zig` — orthogonal.
- `build.zig` — new `dom_names.zig` is imported via `@import("dom_names.zig")`; no build-graph change required (same pattern as existing `events.zig`).

---

## Task 0: P0 Audit — No-Code Gate

**Files:** None modified; produces a notes file `/tmp/p0-1a-audit-notes.md` and WPT baseline captures for later comparison.

**Purpose:** Verify line numbers in the spec match HEAD, confirm no additional copies of the validation code exist, and capture WPT baselines so Task 7 can prove the promised deltas.

- [ ] **Step 0.1: Enumerate all `isValidQName`/`isValidXmlQName`/`isValidElementName` definitions**

Run:
```bash
cd ~/suzume
grep -n "fn isValidQName\|fn isValidXmlQName\|fn isValidXmlName\|fn isValidElementName\|fn isValidName\b" src/js/kotori_dom.zig src/js/dom_document.zig src/js/dom_element.zig src/js/dom_api.zig src/js/dom_node.zig
```

Expected matches (per spec §Current state):
- `src/js/kotori_dom.zig` — `isValidQName` near L2061
- `src/js/dom_document.zig` — `isValidQName` near L249, `isValidXmlQName` near L237, `isValidXmlName` and/or `isValidElementName` (confirm exact names + lines)
- Any other hit is NEW and must be added to the delete list.

Record the exact line numbers into `/tmp/p0-1a-audit-notes.md`. If HEAD differs from the spec's L-numbers by more than ±5 lines, update the subsequent task line references before coding.

- [ ] **Step 0.2: Enumerate all `validateAndExtract` definitions/callers**

Run:
```bash
grep -n "validateAndExtract\|validate_and_extract" src/js/kotori_dom.zig src/js/dom_document.zig src/js/dom_element.zig src/js/dom_api.zig
```

Expected:
- Definition at `kotori_dom.zig:2095` (shared, to be moved)
- Definition at `dom_document.zig:1951` (QuickJS inline duplicate, to be deleted)
- Inline block at `dom_document.zig:470-496` inside `implCreateDocument` (no function; to be replaced with call)
- Inline block at `dom_element.zig:334-393` inside `elementSetAttributeNS` (no function; to be replaced with call)
- Callers: `kotori_dom.zig` lines around 2172 (createElementNS), 2360 (createAttributeNS), 5544 (impl.createDocument). These call sites only change their import path; bodies unchanged.

Record callers + definition sites.

- [ ] **Step 0.3: Enumerate all `isHardInvalidNameChar`/`isInvalidNameStartChar` copies**

Run:
```bash
grep -n "isHardInvalidNameChar\|isInvalidNameStartChar" src/js/kotori_dom.zig src/js/dom_document.zig src/js/dom_element.zig
```

Expected: only in `kotori_dom.zig` near L2027. If copies exist in `dom_document.zig`, add them to Task 3's delete list.

- [ ] **Step 0.4: Confirm `nativeCreateElement` + `documentCreateElement` use the wrong validator**

Run:
```bash
grep -n "isValidQName(tag\|isValidQName(\s*tag\|isValidElementName(tag\|isValidXmlName(tag" src/js/kotori_dom.zig src/js/dom_document.zig
```

Expected: exactly two hits — `kotori_dom.zig:1924` and `dom_document.zig:1937`. Record both exact lines. These are the Task 4 edit targets.

- [ ] **Step 0.5: Confirm QuickJS `createAttribute` is an inline JS closure**

Run:
```bash
grep -n "createAttribute\|createAttributeNS" src/js/dom_api.zig | head -30
```

Expected: registration via `JS_EVAL`/inline JS closure near L4712-L4730, plus one custom-`value` setter closure at L4170. Record exact lines. Task 5 replaces the registration; Task 5 must preserve the `value` setter shape.

- [ ] **Step 0.6: Record WPT baselines (per-file PASS/FAIL)**

Run:
```bash
cd ~/suzume
for js in kotori quickjs; do
  for f in \
    dom/nodes/DOMImplementation-createDocument.html \
    dom/nodes/DOMImplementation-createDocumentType.html \
    dom/nodes/Document-createElement.html \
    dom/nodes/Document-createElementNS.html \
    dom/nodes/Document-createAttribute.html \
    dom/nodes/Element-setAttribute.html \
    dom/nodes/attributes.html; do
    SUZUME_JS=$js TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 1 "$f" \
      2>&1 | tee -a /tmp/wpt-1a-baseline-$js.txt
  done
done
```

Record the PASS / FAIL / TOTAL per file per engine into `/tmp/p0-1a-audit-notes.md`. Format:

```
File                                       | kotori P/T | quickjs P/T
DOMImplementation-createDocument.html      | 330/434    | XXX/434
Document-createElement.html                | ~117/153   | XXX/153
...
```

These numbers are the reference for Task 7's Gate comparison. Zero regressions against either engine is required.

- [ ] **Step 0.7: Confirm lexbor behaviour with leading-colon tag name**

Write a scratch Zig test that calls `lxb_dom_document_create_element(doc, ":foo", 4, null)` on an HTML document and checks the returned pointer. If non-null, the HTML-doc branch of `nativeCreateElement` can pass `":foo"` to lexbor directly. If null, Task 4 must route colonated names through `createJsOnlyElement` fallback (see spec §Risk table row 1).

Record the result in the notes. Don't commit the scratch; it's audit-only.

- [ ] **Step 0.8: No commit at P0**

P0 is a no-code gate. The audit notes remain at `/tmp/p0-1a-audit-notes.md` for reference.

---

## Task 1: Create shared `src/js/dom_names.zig`

**Files:**
- Create: `src/js/dom_names.zig`
- Create/append: unit tests (location per Step 0 convention)

**Purpose:** Single source of truth for XML Name, XML QName, and DOM §1.5 "validate and extract". VM-agnostic pure Zig.

- [ ] **Step 1.1: Create the module skeleton**

Create `src/js/dom_names.zig`:

```zig
const std = @import("std");

pub const NameValidationError = error{ InvalidCharacter, NamespaceMismatch };

pub const ValidatedName = struct {
    namespace: ?[]const u8, // post-coercion: "" → null
    prefix: ?[]const u8,    // null when no ':' in qn
    local_name: []const u8,
};

pub const XML_NS   = "http://www.w3.org/XML/1998/namespace";
pub const XMLNS_NS = "http://www.w3.org/2000/xmlns/";

// Rejects ASCII whitespace, controls, and a small hard-punctuation set.
// Anything non-ASCII is accepted (browser-lenient — matches createElementNS_tests
// which lists e.g. "\uFFFFfoo" as VALID).
fn isHardInvalidNameChar(c: u8) bool {
    return switch (c) {
        0...0x1F, 0x7F, ' ', '\t', '\n', '\r',
        '<', '>', '&', '"', '\'',
        '/', '=', '{', '}', '(', ')',
        '[', ']', '`', '!', '@', '#', '$', '%', '^', '*', '+',
        '?', '|', '\\',
        => true,
        else => false,
    };
}

// NameStartChar rejection for the FIRST byte. Digits, '-', '.', '·' and all
// hard-invalid bytes are rejected. ':' and '_' are NOT rejected here (colon
// allowed in Name; callers filter for QName separately).
fn isInvalidNameStartChar(c: u8) bool {
    if (isHardInvalidNameChar(c)) return true;
    return switch (c) {
        '0'...'9', '-', '.' => true,
        else => false,
    };
}

/// XML Name production (allows ':' anywhere). Used by createElement,
/// createAttribute, setAttribute.
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (isInvalidNameStartChar(name[0])) return false;
    for (name[1..]) |c| {
        if (isHardInvalidNameChar(c)) return false;
    }
    return true;
}

/// XML QName production (lenient browser variant). Used by createElementNS,
/// createAttributeNS, setAttributeNS, impl.createDocument.
pub fn isValidQName(qn: []const u8) bool {
    if (qn.len == 0) return false;
    // Find first ':'
    var colon_idx: ?usize = null;
    for (qn, 0..) |c, i| {
        if (c == ':') { colon_idx = i; break; }
    }
    if (colon_idx) |ci| {
        // PrefixedName: both sides must be non-empty NCName-ish.
        if (ci == 0 or ci == qn.len - 1) return false;
        const prefix = qn[0..ci];
        const local  = qn[ci + 1 ..];
        // A second ':' in either part → not a QName.
        for (prefix) |c| if (c == ':') return false;
        for (local)  |c| if (c == ':') return false;
        if (isInvalidNameStartChar(prefix[0])) return false;
        if (isInvalidNameStartChar(local[0]))  return false;
        for (prefix[1..]) |c| if (isHardInvalidNameChar(c)) return false;
        for (local[1..])  |c| if (isHardInvalidNameChar(c)) return false;
        return true;
    }
    // UnprefixedName: just a Name with no ':'.
    if (isInvalidNameStartChar(qn[0])) return false;
    for (qn[1..]) |c| {
        if (c == ':') return false;
        if (isHardInvalidNameChar(c)) return false;
    }
    return true;
}

/// DOM §1.5 validate and extract.
/// Caller must not pass qn.len == 0 for createElementNS / createAttributeNS —
/// the empty-qname case is handled separately by impl.createDocument.
pub fn validateAndExtract(
    qn: []const u8,
    ns_in: ?[]const u8,
) NameValidationError!ValidatedName {
    // Step 1: coerce "" → null.
    const ns: ?[]const u8 = if (ns_in) |n| (if (n.len == 0) null else n) else null;

    // Step 2: validate qn against QName.
    if (!isValidQName(qn)) return error.InvalidCharacter;

    // Steps 3-5: split on first ':'.
    var prefix: ?[]const u8 = null;
    var local: []const u8 = qn;
    for (qn, 0..) |c, i| {
        if (c == ':') {
            prefix = qn[0..i];
            local = qn[i + 1 ..];
            break;
        }
    }

    // Step 6: prefix with null namespace → error.
    if (prefix != null and ns == null) return error.NamespaceMismatch;

    // Step 7: prefix "xml" requires XML namespace.
    if (prefix) |p| {
        if (std.mem.eql(u8, p, "xml")) {
            if (ns == null or !std.mem.eql(u8, ns.?, XML_NS)) {
                return error.NamespaceMismatch;
            }
        }
    }

    // Step 8: qn or prefix "xmlns" requires XMLNS namespace.
    const qn_is_xmlns = std.mem.eql(u8, qn, "xmlns");
    const prefix_is_xmlns = if (prefix) |p| std.mem.eql(u8, p, "xmlns") else false;
    if (qn_is_xmlns or prefix_is_xmlns) {
        if (ns == null or !std.mem.eql(u8, ns.?, XMLNS_NS)) {
            return error.NamespaceMismatch;
        }
    }

    // Step 9: XMLNS namespace requires qn or prefix to be "xmlns".
    if (ns) |n| {
        if (std.mem.eql(u8, n, XMLNS_NS) and !qn_is_xmlns and !prefix_is_xmlns) {
            return error.NamespaceMismatch;
        }
    }

    return ValidatedName{ .namespace = ns, .prefix = prefix, .local_name = local };
}
```

- [ ] **Step 1.2: Add unit tests**

Append to `tests/test_kotori_dom.zig` (or create `tests/test_dom_names.zig` per Step 0 convention):

```zig
const dom_names = @import("../src/js/dom_names.zig");
const testing = std.testing;

test "isValidName accepts colonated names" {
    try testing.expect(dom_names.isValidName(":"));
    try testing.expect(dom_names.isValidName(":foo"));
    try testing.expect(dom_names.isValidName("f:oo"));
    try testing.expect(dom_names.isValidName("foo:"));
    try testing.expect(dom_names.isValidName("f:o:o"));
    try testing.expect(dom_names.isValidName("f::oo"));
    try testing.expect(dom_names.isValidName("foo"));
}

test "isValidName rejects bad first chars & hard-invalid chars" {
    try testing.expect(!dom_names.isValidName(""));
    try testing.expect(!dom_names.isValidName("1foo"));
    try testing.expect(!dom_names.isValidName("-foo"));
    try testing.expect(!dom_names.isValidName(".foo"));
    try testing.expect(!dom_names.isValidName("fo o"));
    try testing.expect(!dom_names.isValidName("<foo"));
    try testing.expect(!dom_names.isValidName("}foo"));
}

test "isValidQName rejects colonated edge cases allowed by Name" {
    try testing.expect(!dom_names.isValidQName(":"));
    try testing.expect(!dom_names.isValidQName(":foo"));
    try testing.expect(!dom_names.isValidQName("foo:"));
    try testing.expect(!dom_names.isValidQName("f::oo"));
    try testing.expect(!dom_names.isValidQName("f:o:o"));
    try testing.expect( dom_names.isValidQName("f:oo"));
    try testing.expect( dom_names.isValidQName("foo"));
}

test "validateAndExtract empty namespace coerced to null" {
    // qn "f:oo" + ns "" must produce NamespaceError (step 6 after coerce).
    const r = dom_names.validateAndExtract("f:oo", "");
    try testing.expectError(error.NamespaceMismatch, r);
}

test "validateAndExtract step 7 xml prefix" {
    try testing.expectError(
        error.NamespaceMismatch,
        dom_names.validateAndExtract("xml:foo", "http://other"),
    );
    const ok = try dom_names.validateAndExtract("xml:foo", dom_names.XML_NS);
    try testing.expectEqualStrings("xml", ok.prefix.?);
    try testing.expectEqualStrings("foo", ok.local_name);
}

test "validateAndExtract step 8 xmlns qname" {
    try testing.expectError(
        error.NamespaceMismatch,
        dom_names.validateAndExtract("xmlns", "http://other"),
    );
    const ok = try dom_names.validateAndExtract("xmlns", dom_names.XMLNS_NS);
    try testing.expect(ok.prefix == null);
    try testing.expectEqualStrings("xmlns", ok.local_name);
}

test "validateAndExtract step 9 xmlns ns with non-xmlns qname" {
    // Row 171 of createElementNS_tests — previously leaked through QuickJS.
    try testing.expectError(
        error.NamespaceMismatch,
        dom_names.validateAndExtract("xmlfoo", dom_names.XMLNS_NS),
    );
}

test "validateAndExtract bad qname returns InvalidCharacter" {
    try testing.expectError(error.InvalidCharacter, dom_names.validateAndExtract("1foo", null));
    try testing.expectError(error.InvalidCharacter, dom_names.validateAndExtract("a:0", null));
    try testing.expectError(error.InvalidCharacter, dom_names.validateAndExtract(":foo", null));
}
```

- [ ] **Step 1.3: Build + run tests**

```bash
cd ~/suzume
zig build test 2>&1 | tail -40
```

Expected: all new unit tests pass. If `@import` path for the test file differs from convention, adjust per Step 0 findings.

- [ ] **Step 1.4: Commit**

```bash
cd ~/suzume
git add src/js/dom_names.zig tests/
git commit -m "$(cat <<'EOF'
feat(dom): add shared dom_names.zig (Name, QName, validate-and-extract)

Single source of truth for XML Name and QName productions and DOM §1.5
"validate and extract" algorithm. VM-agnostic pure Zig; callers (kotori,
QuickJS) will be migrated in subsequent commits.

Unit-tests cover:
- isValidName accepts ':foo', 'f:oo', 'foo:', 'f:o:o', 'f::oo'
- isValidQName rejects those but accepts 'f:oo'
- validateAndExtract coerces '' namespace to null (step 1)
- Steps 6-9 fire the right error variant (InvalidCharacter vs
  NamespaceMismatch), including the previously-missing step 9
  (XMLNS namespace with non-xmlns qname → NamespaceError).

Layer 1A / DOM §1.5. Spec:
docs/superpowers/specs/2026-04-19-kotori-1A-namespace-qname-design.md

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Migrate kotori path to shared `dom_names`

**Files:**
- Modify: `src/js/kotori_dom.zig`

**Purpose:** Delete the private copies of `validateAndExtract`, `isValidQName`, `isHardInvalidNameChar`, `isInvalidNameStartChar`, `ValidatedName`, `NameValidationError` in `kotori_dom.zig` and re-route existing callers (`createElementNS` L2172, `createAttributeNS` L2360, `impl.createDocument` L5544) through the shared module.

- [ ] **Step 2.1: Add import at top of `kotori_dom.zig`**

Near the existing `const events = @import("events.zig");` or similar `@import` block (top ~20-60 lines):

```zig
const dom_names = @import("dom_names.zig");
```

Record the exact line used for the insertion.

- [ ] **Step 2.2: Delete private definitions L2061-L2143**

Delete (range from audit in Step 0.1):
- `fn isInvalidNameStartChar` (helper)
- `fn isHardInvalidNameChar` (helper)
- `fn isValidQName` at L2061-L2082
- `const ValidatedName = struct {...}` and `const NameValidationError = error{...}` if defined locally
- `fn validateAndExtract` at L2095-L2143

Keep `queueValidationErr` at L2147-L2153 — it's the kotori-specific error→pending_throw mapper and stays.

Verify with:
```bash
grep -n "fn isValidQName\|fn validateAndExtract\|fn isHardInvalidNameChar\|fn isInvalidNameStartChar" src/js/kotori_dom.zig
```
Expected: zero matches.

- [ ] **Step 2.3: Rewrite callers to use `dom_names.` prefix**

At `kotori_dom.zig:2172-2174` (createElementNS call site), change:
```zig
const v = validateAndExtract(qn, ns_in) catch |err| return try queueValidationErr(vm, err);
```
to:
```zig
const v = dom_names.validateAndExtract(qn, ns_in) catch |err| return try queueValidationErr(vm, err);
```

Do the same at `:2360-2363` (createAttributeNS) and `:5544-5548` (impl.createDocument).

If `queueValidationErr` referenced the local `NameValidationError` type, change it to `dom_names.NameValidationError`:
```zig
fn queueValidationErr(vm: *VM, err: dom_names.NameValidationError) !JsValue {
```

- [ ] **Step 2.4: Fix `ValidatedName` struct references**

Any local code that destructured the result via `v.namespace`, `v.prefix`, `v.local_name` still works — the field names match. If any code imported the local `ValidatedName` type explicitly (search: `ValidatedName`), change to `dom_names.ValidatedName`.

- [ ] **Step 2.5: Build + verify**

```bash
cd ~/suzume && zig build 2>&1 | tail -30
```
Expected: clean build. If an unresolved symbol surfaces (e.g. `XML_NS` constant used elsewhere in `kotori_dom.zig`), re-add it as `const XML_NS = dom_names.XML_NS;` at the top.

- [ ] **Step 2.6: Run tests**

```bash
cd ~/suzume && zig build test 2>&1 | tail -30
```
Expected: all unit tests green (including the new `dom_names` tests).

- [ ] **Step 2.7: WPT smoke check — kotori engine, createDocument only**

```bash
cd ~/suzume
SUZUME_JS=kotori TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 1 \
  dom/nodes/DOMImplementation-createDocument.html 2>&1 | tail -20
```
Expected: PASS count unchanged from baseline (this task is pure refactor — no behaviour change on kotori).

- [ ] **Step 2.8: Commit**

```bash
cd ~/suzume
git add src/js/kotori_dom.zig
git commit -m "$(cat <<'EOF'
refactor(kotori): route kotori_dom through shared dom_names module

Delete local copies of isValidQName, isHardInvalidNameChar,
isInvalidNameStartChar, validateAndExtract, ValidatedName,
NameValidationError at kotori_dom.zig:2061-2143. Existing callers
(createElementNS, createAttributeNS, impl.createDocument) now use
dom_names.validateAndExtract. queueValidationErr retained as kotori-
specific error→pending_throw bridge.

Zero-behaviour-change refactor; WPT createDocument.html numbers
unchanged.

Layer 1A Task 2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Migrate QuickJS paths to shared `dom_names`

**Files:**
- Modify: `src/js/dom_document.zig` — delete inline copies
- Modify: `src/js/dom_element.zig` — replace inline block in `elementSetAttributeNS`
- Modify: `src/js/dom_api.zig` — add `validateAndExtractQjs` helper

**Purpose:** Eliminate the three QuickJS inline duplicates; also closes the spec step-6/step-9 gap in `implCreateDocument` (row 171 of createElementNS_tests — the single biggest win in QuickJS mode).

- [ ] **Step 3.1: Add `validateAndExtractQjs` bridge in `dom_api.zig`**

Near `throwDOMException` in `dom_api.zig` (search for it first), add:

```zig
const dom_names = @import("dom_names.zig");

/// Run DOM §1.5 validate-and-extract; on error, throw the matching DOMException
/// and return the exception JSValue. On success, writes the tuple via out_*
/// pointers and returns null.
pub fn validateAndExtractQjs(
    c: *qjs.JSContext,
    ns_arg: qjs.JSValueConst,
    qn_arg: qjs.JSValueConst,
    out: *dom_names.ValidatedName,
) ?qjs.JSValue {
    // Extract ns (nullable) and qn (required non-null string).
    var ns_slice: ?[]const u8 = null;
    var ns_cstr: ?[*:0]const u8 = null;
    if (!qjs.JS_IsNull(ns_arg) and !qjs.JS_IsUndefined(ns_arg)) {
        ns_cstr = qjs.JS_ToCString(c, ns_arg);
        if (ns_cstr) |s| ns_slice = std.mem.span(s);
    }
    defer if (ns_cstr) |s| qjs.JS_FreeCString(c, s);

    const qn_cstr = qjs.JS_ToCString(c, qn_arg) orelse {
        return throwDOMException(c, "InvalidCharacterError", "qualifiedName required");
    };
    defer qjs.JS_FreeCString(c, qn_cstr);
    const qn_slice = std.mem.span(qn_cstr);

    const v = dom_names.validateAndExtract(qn_slice, ns_slice) catch |err| {
        const name: [*:0]const u8 = switch (err) {
            error.InvalidCharacter => "InvalidCharacterError",
            error.NamespaceMismatch => "NamespaceError",
        };
        return throwDOMException(c, name, "validate and extract failed");
    };
    out.* = v;
    return null;
}
```

Adjust `JS_ToCString`/`std.mem.span` to match the project's existing QuickJS binding style (search for an existing `JS_ToCString` usage pattern and mirror it).

- [ ] **Step 3.2: Delete inline validator in `implCreateDocument` at `dom_document.zig:470-496`**

Run `grep -n "fn implCreateDocument" src/js/dom_document.zig` to confirm the current line range.

Locate the 26-line inline block (the one that manually splits on ':' and does steps 3-5 but MISSES step 6/9). Replace with:

```zig
if (qn_len > 0) {
    var ve: dom_names.ValidatedName = undefined;
    if (dom_api.validateAndExtractQjs(c, ns_arg, qn_arg, &ve)) |exc| {
        _ = exc; // exception already set on context
        return qjs.JS_EXCEPTION();
    }
    // ve.namespace / ve.prefix / ve.local_name now available for
    // subsequent createElementNS-internal steps.
}
```

Add `const dom_api = @import("dom_api.zig");` and `const dom_names = @import("dom_names.zig");` to the top of `dom_document.zig` if not already present.

- [ ] **Step 3.3: Delete duplicate `validateAndExtract` at `dom_document.zig:1951-2034`**

Delete the whole `fn validateAndExtract` QuickJS variant. Also delete `fn isValidQName` at L249-L267 and `fn isValidXmlQName` at L237-L243 (all superseded by `dom_names`).

Find every caller with:
```bash
grep -n "validateAndExtract\|isValidQName\|isValidXmlQName" src/js/dom_document.zig
```

For each remaining caller, replace with the appropriate `dom_names.isValidQName` or `dom_api.validateAndExtractQjs` call. Typical call sites: `documentCreateElementNS` near L2036+, and `implCreateDocument` already done in Step 3.2.

- [ ] **Step 3.4: Replace inline block in `elementSetAttributeNS`**

Run `grep -n "fn elementSetAttributeNS\b" src/js/dom_element.zig` to confirm line. The inline block at L334-L393 currently contains:
- `isValidQName` check
- `isValidXmlQName` check (duplicate)
- Manual prefix/local split
- Custom error messages

Replace the L334-L393 block with:

```zig
var ve: dom_names.ValidatedName = undefined;
if (dom_api.validateAndExtractQjs(c, ns_arg, qn_arg, &ve)) |exc| {
    _ = exc;
    return qjs.JS_EXCEPTION();
}
// Downstream code uses ve.prefix / ve.local_name when calling lexbor.
```

Preserve any surrounding code that reads the qname for the actual attribute write (lexbor stores the qualified-name verbatim, so pass the original `qn_slice` to lexbor — only use `ve.prefix`/`ve.local_name` for the JS-visible slot properties).

Add `const dom_api = @import("dom_api.zig");` and `const dom_names = @import("dom_names.zig");` imports to the top of `dom_element.zig` if not already present.

- [ ] **Step 3.5: Build + test**

```bash
cd ~/suzume && zig build 2>&1 | tail -30 && zig build test 2>&1 | tail -30
```
Expected: clean build, tests green.

- [ ] **Step 3.6: WPT smoke — QuickJS engine, createDocument + setAttributeNS**

```bash
cd ~/suzume
SUZUME_JS=quickjs TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 1 \
  dom/nodes/DOMImplementation-createDocument.html \
  dom/nodes/Element-setAttribute.html 2>&1 | tail -20
```
Expected: createDocument shows improvement over baseline (from step-6/step-9 fix landing in QuickJS path). setAttribute stays green.

- [ ] **Step 3.7: Commit**

```bash
cd ~/suzume
git add src/js/dom_document.zig src/js/dom_element.zig src/js/dom_api.zig
git commit -m "$(cat <<'EOF'
refactor(quickjs): route dom_document/dom_element through dom_names

Delete inline duplicates:
- dom_document.zig:237-243 (isValidXmlQName)
- dom_document.zig:249-267 (isValidQName)
- dom_document.zig:470-496 (implCreateDocument inline validate-and-extract,
  previously missing step 6/9 → row 171 of createElementNS_tests leaked
  through as success when it should throw NamespaceError)
- dom_document.zig:1951-2034 (validateAndExtract QuickJS variant)
- dom_element.zig:334-393 (elementSetAttributeNS inline validator)

Add dom_api.validateAndExtractQjs bridge that calls shared algorithm
and maps errors to throwDOMException.

Fixes Name-vs-NamespaceError dispatch for XMLNS namespace with
non-xmlns qname (the single biggest WPT win in QuickJS mode for
this layer).

Layer 1A Task 3.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Fix createElement Name-vs-QName bug

**Files:**
- Modify: `src/js/kotori_dom.zig:1924` (`nativeCreateElement`)
- Modify: `src/js/dom_document.zig:1937` (`documentCreateElement`)

**Purpose:** `createElement` per DOM §4.5.1 validates against the XML **Name** production (`:` allowed freely), not QName. WPT `Document-createElement.html:48-53` asserts `":"`, `":foo"`, `"f:oo"`, `"foo:"`, `"f:o:o"`, `"f::oo"` are all VALID and get ~36 subtests flipping green when we stop over-rejecting.

- [ ] **Step 4.1: Fix kotori `nativeCreateElement`**

At `kotori_dom.zig:1924`, find the existing check (exact text verified in Step 0.4):
```zig
if (!isValidQName(tag_raw)) {
    // ... throw InvalidCharacterError ...
}
```

Replace with:
```zig
if (!dom_names.isValidName(tag_raw)) {
    // ... same throw body ...
}
```

- [ ] **Step 4.2: Handle lexbor edge case for colonated HTML-doc tags**

Per Step 0.7 audit result:
- **If lexbor accepted `":foo"` cleanly:** No further change needed. The existing HTML-doc path at `kotori_dom.zig:1958` passes the tag to `lxb_dom_document_create_element`; WPT test ` createElement(":foo")` returns an element and the test succeeds.
- **If lexbor returned null / crashed on `":foo"`:** Wrap the HTML path with a fallback. After the `lxb_dom_document_create_element` call, if the result is null, fall through to `createJsOnlyElement(vm, tag_raw, null)`:

```zig
const lx_el = lxb.lxb_dom_document_create_element(doc_ptr, tag_cstr.ptr, tag_cstr.len, null);
if (lx_el == null) {
    // Lexbor rejected a Name-valid but QName-invalid tag (e.g. leading ':').
    // Fall back to JS-only element; DOM §4.5.1 still requires a usable Element.
    return try createJsOnlyElement(vm, tag_raw, null);
}
```

Record which branch was taken in the task's commit message.

- [ ] **Step 4.3: Fix QuickJS `documentCreateElement` at `dom_document.zig:1937`**

Find:
```zig
if (!isValidElementName(tag)) {
    return throwDOMException(c, "InvalidCharacterError", "invalid element name");
}
```

Replace with:
```zig
if (!dom_names.isValidName(tag)) {
    return dom_api.throwDOMException(c, "InvalidCharacterError", "invalid element name");
}
```

Also delete the now-unused `isValidElementName` function if it had no other callers:
```bash
grep -n "isValidElementName" src/js/dom_document.zig
```
If zero remaining callers, delete the definition (include its `isValidXmlName` delegate if it too has no remaining callers).

- [ ] **Step 4.4: Unit-test the colonated-name path**

Add to the unit-test file:

```zig
test "createElement accepts colonated names per Document-createElement.html" {
    // End-to-end through the VM: this is a real WPT scenario smoke.
    // (Wire via the existing WPT micro-runner if available; else skip and
    // rely on Task 7 WPT run.)
}
```

If a VM-scoped end-to-end test harness isn't readily available, skip this step — Task 7's full WPT run covers it.

- [ ] **Step 4.5: Build + WPT check (the big one)**

```bash
cd ~/suzume && zig build 2>&1 | tail -20
for js in kotori quickjs; do
  SUZUME_JS=$js TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 1 \
    dom/nodes/Document-createElement.html 2>&1 | tail -10
done
```
Expected: +36 subtests over baseline on BOTH engines. 153/153 is the target (from ~117/153 baseline). If kotori surges but QuickJS lags, re-check Step 4.3's edit landed correctly.

- [ ] **Step 4.6: Commit**

```bash
cd ~/suzume
git add src/js/kotori_dom.zig src/js/dom_document.zig
git commit -m "$(cat <<'EOF'
fix(dom): createElement validates against Name, not QName (DOM §4.5.1)

Per DOM §4.5.1, Document.createElement(localName) validates against the
XML Name production which permits ':' anywhere. Previously both the
kotori (kotori_dom.zig:1924) and QuickJS (dom_document.zig:1937) paths
used isValidQName / isValidElementName, over-rejecting tags like
':foo', 'f:oo', 'foo:', 'f:o:o', 'f::oo' which WPT
Document-createElement.html:48-53 explicitly lists as VALID.

Route both paths through dom_names.isValidName. If lexbor rejects
colonated tags on the HTML-doc path, fall back to createJsOnlyElement
(decision flag set per Task 0.7 audit: [RESULT-HERE]).

Unblocks +36 subtests on Document-createElement.html (~117/153 →
153/153).

Layer 1A Task 4.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Native QuickJS binding for `createAttribute` / `createAttributeNS`

**Files:**
- Modify: `src/js/dom_api.zig:4712-4730` — replace inline JS closure with `JS_NewCFunction` bindings
- Modify: `src/js/dom_document.zig` — add `documentCreateAttribute` and `documentCreateAttributeNS` native functions

**Purpose:** The QuickJS path currently registers `createAttribute`/`createAttributeNS` via inline JS-eval'd closures that do no validation. Replace with native C functions that invoke the shared algorithm, matching kotori's `createAttrObject` shape. Preserves the existing custom `value` setter plumbing.

**Risk flag:** The inline JS closure at `dom_api.zig:4170` defines the `value` getter/setter semantics for Attr. The replacement native function MUST produce an object with the same setter wiring, otherwise downstream Attr `.value = "x"` writes will stop reflecting.

- [ ] **Step 5.1: Audit the Attr object shape from kotori**

Read `kotori_dom.zig:2249-2299` (`createAttrObject`) to capture the Attr shape:
- Slots: `name`, `localName`, `namespaceURI` (nullable), `prefix` (nullable), `ownerElement` (null at create time), `ownerDocument`, `_val`
- `value` getter returns `_val`; `value` setter updates `_val` and, if `ownerElement != null`, writes through to the owning element's attribute.

Record the property list in implementation notes.

- [ ] **Step 5.2: Add `documentCreateAttribute` in `dom_document.zig`**

```zig
pub fn documentCreateAttribute(
    c: *qjs.JSContext,
    this_val: qjs.JSValueConst,
    argc: c_int,
    argv: [*]qjs.JSValueConst,
) callconv(.C) qjs.JSValue {
    _ = this_val;
    if (argc < 1) return dom_api.throwDOMException(c, "TypeError", "localName required");
    const name_cstr = qjs.JS_ToCString(c, argv[0]) orelse return qjs.JS_EXCEPTION();
    defer qjs.JS_FreeCString(c, name_cstr);
    const name_slice = std.mem.span(name_cstr);
    if (!dom_names.isValidName(name_slice)) {
        return dom_api.throwDOMException(c, "InvalidCharacterError", "invalid attribute name");
    }
    // HTML-doc lowercase (DOM §4.9.1 step 2). Detect via this_val's document type
    // (same pattern as documentCreateElement).
    const lower_name = if (isHtmlDocument(c, this_val))
        try asciiLower(c, name_slice)
    else
        name_slice;
    return buildAttrObject(c, lower_name, null, null);
}

pub fn documentCreateAttributeNS(
    c: *qjs.JSContext,
    this_val: qjs.JSValueConst,
    argc: c_int,
    argv: [*]qjs.JSValueConst,
) callconv(.C) qjs.JSValue {
    _ = this_val;
    if (argc < 2) return dom_api.throwDOMException(c, "TypeError", "two args required");
    var ve: dom_names.ValidatedName = undefined;
    if (dom_api.validateAndExtractQjs(c, argv[0], argv[1], &ve)) |exc| {
        _ = exc;
        return qjs.JS_EXCEPTION();
    }
    return buildAttrObject(c, ve.local_name, ve.prefix, ve.namespace);
}
```

Add `buildAttrObject(c, local_name, prefix, ns)` helper that returns a `JSValue` with the Attr shape captured in Step 5.1. Crucially, wire the `value` property with `JS_DefinePropertyGetSet` so mutations of `_val` flow through to the owning element once `ownerElement` is set (mirror the kotori closure's behaviour).

- [ ] **Step 5.3: Replace registration at `dom_api.zig:4712-4730`**

Read current L4712-L4730 first (inline JS closure block). Replace the whole block with:

```zig
// DOM §4.9.1 createAttribute / createAttributeNS — native bindings.
const cattr_fn = qjs.JS_NewCFunction(
    c, @ptrCast(&dom_doc.documentCreateAttribute), "createAttribute", 1,
);
_ = qjs.JS_DefinePropertyValueStr(c, doc_proto, "createAttribute",
    cattr_fn, qjs.JS_PROP_WRITABLE | qjs.JS_PROP_CONFIGURABLE);

const cattrns_fn = qjs.JS_NewCFunction(
    c, @ptrCast(&dom_doc.documentCreateAttributeNS), "createAttributeNS", 2,
);
_ = qjs.JS_DefinePropertyValueStr(c, doc_proto, "createAttributeNS",
    cattrns_fn, qjs.JS_PROP_WRITABLE | qjs.JS_PROP_CONFIGURABLE);
```

Verify the `doc_proto` identifier matches the surrounding code's naming.

- [ ] **Step 5.4: Port the value setter plumbing**

Re-read `dom_api.zig:4170` to confirm the setter logic. Inside `buildAttrObject`, define the `value` property via accessor descriptors:

```zig
// Pseudocode — adapt to the QuickJS binding idiom used in the file.
const get_value = qjs.JS_NewCFunction(c, &attrGetValue, "", 0);
const set_value = qjs.JS_NewCFunction(c, &attrSetValue, "", 1);
qjs.JS_DefinePropertyGetSet(c, attr_obj, value_atom, get_value, set_value,
    qjs.JS_PROP_CONFIGURABLE);
```

`attrSetValue` must: update the object's internal `_val`, look up `ownerElement`, if non-null call `lxb_dom_element_set_attribute` with the attr's qualified name + new value.

- [ ] **Step 5.5: Unit test Attr shape**

Add a WPT-style smoke in `tests/test_kotori_dom.zig`:

```zig
test "createAttribute via QuickJS produces Attr with live value setter" {
    // Eval `const a = document.createAttribute("foo"); a.value = "bar"; a.value`
    // through the QuickJS context and assert result equals "bar".
    // Also: document.createAttribute("") throws InvalidCharacterError.
}
```

Implementation of this test requires the WPT harness hook. If unavailable, rely on Task 7's end-to-end WPT run.

- [ ] **Step 5.6: Build + WPT smoke**

```bash
cd ~/suzume && zig build 2>&1 | tail -20
SUZUME_JS=quickjs TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 1 \
  dom/nodes/Document-createAttribute.html \
  dom/nodes/attributes.html 2>&1 | tail -20
```
Expected: Document-createAttribute.html stays green (or flips green if it was failing in QuickJS mode). attributes.html may show some movement.

- [ ] **Step 5.7: Commit**

```bash
cd ~/suzume
git add src/js/dom_document.zig src/js/dom_api.zig tests/
git commit -m "$(cat <<'EOF'
feat(quickjs): native createAttribute / createAttributeNS bindings

Replace inline JS-eval'd closures at dom_api.zig:4712-4730 with
JS_NewCFunction registrations pointing at new native functions
documentCreateAttribute / documentCreateAttributeNS in dom_document.zig.
Both run the shared dom_names validation before constructing an Attr
object.

Preserve the existing 'value' getter/setter plumbing (previously at
dom_api.zig:4170) via JS_DefinePropertyGetSet accessors, so Attr.value
writes still flow through to ownerElement when set.

Closes the spec gap where the QuickJS path accepted any non-empty
attribute name (no validation at all).

Layer 1A Task 5.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Wire native `setAttribute` / `setAttributeNS` validation (kotori)

**Files:**
- Modify: `src/js/kotori_dom.zig:3045-3097` (`nativeSetAttribute`, `nativeSetAttributeNS`)

**Purpose:** Per spec §setAttribute current state, both kotori native setters do zero validation. Add `isValidName` to setAttribute and `validateAndExtract` to setAttributeNS so malformed names throw `InvalidCharacterError`/`NamespaceError` as DOM §4.9.2 / §4.9.3 require.

**Risk flag:** Any internal suzume code that calls `nativeSetAttribute` with synthetic attribute names (e.g. `__prefix` pseudo-attrs from the HTML parser) will start throwing. Mitigation: grep `nativeSetAttribute` direct callers first — most internal writes bypass the JS wrapper and go directly to `lxb_dom_element_set_attribute`, so only JS-visible calls tighten.

- [ ] **Step 6.1: Audit internal callers**

```bash
grep -n "nativeSetAttribute\|nativeSetAttributeNS" src/js/ -r
```

Expected: only definition sites + JS-binding registration sites. Any direct internal caller must be flagged and either (a) migrated to use `lxb_dom_element_set_attribute` directly, or (b) have its input pre-validated.

Record findings in `/tmp/p0-1a-audit-notes.md`.

- [ ] **Step 6.2: Add validation to `nativeSetAttribute`**

At `kotori_dom.zig:3047` (after `args.len < 2` guard), insert:

```zig
const n_jsval = args[0];
const n = jsValueToSlice(vm, n_jsval) catch return JsValue.undefined_val;
if (!dom_names.isValidName(n)) {
    vm.pending_throw = makeDOMException(vm, "InvalidCharacterError",
        "invalid attribute name") catch null;
    return JsValue.undefined_val;
}
```

Use the existing `makeDOMException` / `pending_throw` idiom (search for other uses of `pending_throw` in `kotori_dom.zig` — the convention is established).

- [ ] **Step 6.3: Add validation to `nativeSetAttributeNS`**

At `kotori_dom.zig:3075` (after arg-count guard), insert:

```zig
const ns_in = nullableSlice(vm, args[0]);
const qn = jsValueToSlice(vm, args[1]) catch return JsValue.undefined_val;
const ve = dom_names.validateAndExtract(qn, ns_in) catch |err|
    return try queueValidationErr(vm, err);
_ = ve; // prefix/localName available if the existing code needs them.
```

Preserve the subsequent `lxb_dom_element_set_attribute_ns` / full-qname write — lexbor stores the qualified name verbatim. Only the validation step is added.

- [ ] **Step 6.4: Test**

Write a targeted unit test that exercises `element.setAttribute("1foo", "x")` through the VM and expects a thrown DOMException with `name == "InvalidCharacterError"`. Skip if the VM-scoped test harness is unavailable — Task 7 will catch regressions.

- [ ] **Step 6.5: Build + WPT**

```bash
cd ~/suzume && zig build 2>&1 | tail -20
for js in kotori quickjs; do
  SUZUME_JS=$js TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 1 \
    dom/nodes/Element-setAttribute.html \
    dom/nodes/attributes.html 2>&1 | tail -20
done
```
Expected: Element-setAttribute stays green (2/2). attributes.html should show +10 to +50 subtests depending on how many currently silently-succeed on invalid names.

If attributes.html regresses, see spec §Risk table row 2: a suzume-internal setAttribute caller was passing malformed names through the JS native wrapper. Investigate and migrate that caller to the lexbor direct path.

- [ ] **Step 6.6: Commit**

```bash
cd ~/suzume
git add src/js/kotori_dom.zig
git commit -m "$(cat <<'EOF'
fix(kotori): validate setAttribute/setAttributeNS names per DOM §4.9.2-3

Both kotori_dom.zig:3045 (nativeSetAttribute) and :3073
(nativeSetAttributeNS) previously accepted any name without validation.
Add dom_names.isValidName to setAttribute and validateAndExtract to
setAttributeNS; route errors via the existing pending_throw / queue-
ValidationErr idiom.

Lexbor storage path unchanged — qualified name still written verbatim.
Only the JS-visible validation step tightens.

Unblocks ~10-50 subtests on attributes.html depending on how many
tests previously relied on silent-success for bad names.

Layer 1A Task 6.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: WPT verification + baseline comparison

**Files:** None modified. Gate task.

**Purpose:** Run the full suite of Layer 1A WPT files against both engines and confirm the promised deltas. Produce a results report; compare to Task 0.6 baseline.

- [ ] **Step 7.1: Run targeted WPT files on both engines**

```bash
cd ~/suzume
for js in kotori quickjs; do
  echo "=== $js ==="
  SUZUME_JS=$js TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
    dom/nodes/DOMImplementation-createDocument.html \
    dom/nodes/DOMImplementation-createDocumentType.html \
    dom/nodes/Document-createElement.html \
    dom/nodes/Document-createElementNS.html \
    dom/nodes/Document-createAttribute.html \
    dom/nodes/Element-setAttribute.html \
    dom/nodes/attributes.html \
    2>&1 | tee /tmp/wpt-1a-final-$js.txt
done
```

- [ ] **Step 7.2: Run full `dom/nodes` sweep**

```bash
cd ~/suzume
for js in kotori quickjs; do
  SUZUME_JS=$js TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/nodes \
    2>&1 | tee /tmp/wpt-1a-domnodes-$js.txt
done
```

- [ ] **Step 7.3: Diff against baselines**

Use a small script / manual diff between `/tmp/wpt-1a-baseline-{kotori,quickjs}.txt` (from Task 0.6) and `/tmp/wpt-1a-final-{kotori,quickjs}.txt`.

**Gate criteria — must all be true:**

| File | Required delta | Engine |
|------|----------------|--------|
| `DOMImplementation-createDocument.html` | ≥ +101 (both engines; 330→431 on kotori) | both |
| `Document-createElement.html` | ≥ +36 (~117→153) | both |
| `Document-createElementNS.html` | ≥ 0 (no regression; this layer does not target it) | both |
| `DOMImplementation-createDocumentType.html` | ≥ 0 (no regression) | both |
| `Element-setAttribute.html` | ≥ 0 (no regression; baseline 2/2) | both |
| `Document-createAttribute.html` | ≥ 0 (no regression) | both |
| `attributes.html` | bonus ≥ +10 expected | both |
| Full `dom/nodes` | net ≥ +137 | both |

Both engines must now report identical numbers for the targeted files (the shared algorithm guarantees convergence).

- [ ] **Step 7.4: Write results report**

Append results to `~/.openclaw/workspace/memory/project_kotori.md` (or the project memory note per existing convention) under "Layer 1A completion". Include before/after per-file counts for both engines and a one-line summary of the net delta.

- [ ] **Step 7.5: If any gate fails — diagnose, don't bypass**

If `createDocument` delta < +101: likely the QuickJS `implCreateDocument` refactor didn't fully kick in (Task 3.2). Re-check the inline block was fully removed and the new call path runs `validateAndExtract`.

If `createElement` delta < +36: lexbor likely rejected colonated HTML-doc tags; apply the fallback in Task 4.2.

If `attributes.html` regressed: see Task 6.5 note.

Fix the underlying issue and create a NEW commit (never `--amend`). Re-run Step 7.1-7.3.

- [ ] **Step 7.6: Commit final report**

```bash
cd ~/suzume
# Results captured into project memory in Step 7.4; no repo commit needed unless
# the project convention is to commit a CHANGELOG-style note.
```

If the project convention is to commit a summary note under `docs/superpowers/`, do so with message:

```
docs: record Layer 1A WPT results (+137 subtests on dom/nodes)
```

---

## Success Criteria (acceptance)

- [ ] `src/js/dom_names.zig` exists, exports `isValidName`, `isValidQName`, `validateAndExtract`, `ValidatedName`, `NameValidationError`.
- [ ] Unit tests for `dom_names` pass (`zig build test`).
- [ ] `kotori_dom.zig` no longer defines `isValidQName` / `validateAndExtract` / `isHardInvalidNameChar` / `isInvalidNameStartChar`.
- [ ] `dom_document.zig` no longer defines `isValidXmlQName` / `isValidQName` / any inline `validateAndExtract`. `implCreateDocument` routes through `dom_api.validateAndExtractQjs`.
- [ ] `dom_element.zig` `elementSetAttributeNS` uses shared `validateAndExtractQjs`.
- [ ] `dom_api.zig` L4712-L4730 replaced with native JS_NewCFunction bindings for createAttribute / createAttributeNS; the JS-closure variant is gone.
- [ ] `nativeCreateElement` (both paths) uses `isValidName`, not `isValidQName` / `isValidElementName`.
- [ ] `nativeSetAttribute` and `nativeSetAttributeNS` (kotori) validate per DOM §4.9.
- [ ] `zig build` + `zig build test` clean on both engines.
- [ ] `DOMImplementation-createDocument.html` ≥ 431/434 on both engines (target +101).
- [ ] `Document-createElement.html` = 153/153 on both engines (target +36).
- [ ] No regression in `Document-createElementNS.html`, `Element-setAttribute.html`, `DOMImplementation-createDocumentType.html`, `Document-createAttribute.html`.
- [ ] Both `SUZUME_JS=kotori` and `SUZUME_JS=quickjs` report identical pass counts on the targeted files.
- [ ] Net `dom/nodes` delta ≥ +137 subtests.

---

## Open questions / deferrals

- **XML Name Unicode ranges** (spec §Out of scope): current validator accepts all non-ASCII bytes unconditionally. createElementNS_tests explicitly allows `"\uFFFFfoo"` so strict §2.3 compliance would regress. Not addressed here.
- **`createElementNS` prefix reflection** (`.prefix`, `.localName`, `.tagName` getters post-creation): flagged by roadmap as Layer 1E; out of scope here. Fix validation here does not unlock the remaining ~540 subtests of Document-createElementNS.html.
- **HTML-doc attribute name lowercasing** beyond current createAttribute path: Layer 1E.
- **MutationObserver `attributeOldValue`**: Layer 1B.
- **`setAttributeNode` / `getAttributeNode` validation**: Layer 1D (NamedNodeMap).

If any of these arise during implementation as blockers, escalate and write to `.omc/plans/open-questions.md`.
