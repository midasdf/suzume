# Spec 2: kotori DOM Mutation Validation + textContent + toggleAttribute

**Date**: 2026-04-17
**Scope**: Pre-insert/pre-remove validation, textContent null handling, toggleAttribute
**Target**: ~230+ subtests in dom/nodes

## Problem Statement

After Spec 1 (eval + Node identity), 3938/5604 subtests pass (70.3%). The next largest failure clusters share a common theme: DOM mutations don't validate inputs and don't throw DOMExceptions.

## Fix 1: Pre-insert Validation (DOM §4.2.2 — "ensure pre-insertion validity")

### Affected Tests
- Node-insertBefore: 78 failures (2/80 pass)
- Node-replaceChild: 27 failures (2/29 pass)
- ParentNode-replaceChildren: partial
- prepend-on-Document: partial

### Spec: DOM §4.2.2 Steps

Before inserting `node` into `parent` before `child`:

1. If `parent` is not a Document, DocumentFragment, or Element → throw HierarchyRequestError
2. If `node` is a host-including inclusive ancestor of `parent` → throw HierarchyRequestError
3. If `child` is non-null and `child.parentNode !== parent` → throw NotFoundError
4. If `node` is not DocumentFragment, DocumentType, Element, or CharacterData → throw HierarchyRequestError
5. If `node` is Text and `parent` is Document → throw HierarchyRequestError
6. If `node` is DocumentType and `parent` is not Document → throw HierarchyRequestError
7. If `parent` is Document (additional constraints):
   - DocumentFragment with >1 element child or any Text child → throw HierarchyRequestError
   - DocumentFragment with 1 element child when parent already has element child → throw
   - Element when parent already has element child → throw
   - DocumentType when parent already has doctype child → throw
   - DocumentType when element child precedes `child` → throw

### Implementation

Add `validatePreInsert(vm, node, parent, child)` function in `kotori_dom.zig`:
- Check each condition in order
- On violation: set `vm.pending_throw` to DOMException with appropriate name
- Called from: `nativeAppendChild`, `nativeInsertBefore`, `nativePrepend`, `nativeAppend`

Current `nativeInsertBefore` and `nativeAppendChild` do no validation — they just call lexbor directly.

## Fix 2: Pre-remove Validation (DOM §4.2.3)

### Affected Tests
- Node-removeChild: 28 failures (0/28 pass)

### Spec: DOM §4.2.3

Before removing `child` from `parent`:
1. If `child.parentNode !== parent` → throw NotFoundError

### Implementation

Update `nativeRemoveChild` to check parentNode before removing.

## Fix 3: replaceChild Validation (DOM §4.2.4)

### Affected Tests
- Node-replaceChild: 27 failures (2/29 pass)

### Spec: DOM §4.2.4

replaceChild(node, child):
1. If `parent` is not Document/DocumentFragment/Element → throw HierarchyRequestError
2. If `node` is host-including inclusive ancestor of `parent` → throw HierarchyRequestError
3. If `child.parentNode !== parent` → throw NotFoundError
4. If `node` is not Fragment/DocType/Element/CharacterData → throw HierarchyRequestError
5. (same Document constraints as pre-insert but accounting for child being replaced)
6. Null node → throw TypeError

### Implementation

Update `nativeReplaceChild` to call validation before DOM mutation.

## Fix 4: textContent Setter Null Handling (DOM §4.4)

### Affected Tests
- Node-textContent: 34 failures (47/81 pass)

### Spec: DOM §4.4

Setting `textContent` on Element/DocumentFragment:
- If value is **null**: remove all children (equivalent to empty string)
- If value is **undefined**: set text content to string "undefined" (per WebIDL string conversion)
- textContent getter: return null for Document/DocumentType nodes

### Current Bug
- `el.textContent = null` doesn't clear children, returns "[object HTMLElement]" instead of null
- `el.textContent = undefined` incorrectly handled

### Implementation

Update textContent setter in property setter handler to:
- Treat null same as "" (remove all children, set empty)
- Convert undefined to "undefined" string

Update textContent getter for Document/DocumentType to return null.

## Fix 5: toggleAttribute (DOM §4.9.1)

### Affected Tests
- attributes.html: ~20 failures related to toggleAttribute

### Spec: DOM §4.9.1

`element.toggleAttribute(qualifiedName [, force])`:
1. Validate qualifiedName per Name production → throw InvalidCharacterError
2. Lowercase qualifiedName if HTML document
3. If attribute exists:
   - If force is undefined or false → remove attribute, return false
   - Else return true
4. If attribute doesn't exist:
   - If force is undefined or true → set attribute (empty string value), return true
   - Else return false

### Implementation

Add `nativeToggleAttribute` to element methods.

## Verification Plan

1. `zig build test` — all pass
2. Individual test files:
   - `Node-insertBefore.html` → target 60+/80
   - `Node-removeChild.html` → target 20+/28
   - `Node-replaceChild.html` → target 20+/29
   - `Node-textContent.html` → target 70+/81
   - `attributes.html` → target 30+/67
3. Full `dom/nodes` WPT run → target 4100+/5604 (73%+)

## Expected Impact

| Fix | Subtests Fixed (est.) |
|-----|----------------------|
| Pre-insert validation | ~70 |
| Pre-remove validation | ~25 |
| replaceChild validation | ~25 |
| textContent null/undefined | ~30 |
| toggleAttribute | ~20 |
| **Total** | **~170** |

## Implementation Order

1. Pre-insert validation (biggest, used by multiple methods)
2. Pre-remove validation (simple)
3. replaceChild validation (reuses pre-insert logic)
4. textContent null handling
5. toggleAttribute
6. Build + test + WPT

## Files Modified

| File | Changes |
|------|---------|
| `src/js/kotori_dom.zig` | validatePreInsert, removeChild validation, replaceChild validation, textContent, toggleAttribute |
