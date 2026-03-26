# dom_api.zig Refactoring Design

## Problem

`dom_api.zig` has grown to 10,041 lines — a monolithic file containing all DOM API bindings. This causes:
- Difficult navigation (grep through 10K lines)
- Accidental `replace_all` affecting unrelated code (happened in session)
- No clear separation of concerns (Node vs Element vs Document)
- Hard to reason about dependencies

## Solution

Split into 8 files organized by DOM interface:

```
src/js/
  dom_api.zig        # Main registration, shared state, utilities (~2000 lines)
  dom_node.zig       # Node prototype methods (~800 lines)
  dom_element.zig    # Element methods, attributes, classList (~1200 lines)
  dom_document.zig   # Document methods, createElement, querySelector (~1500 lines)
  dom_text.zig       # CharacterData/Text/Comment (~400 lines)
  dom_selector.zig   # JS-side selector matching (~1000 lines)
  dom_style.zig      # getComputedStyle, CSS validation (~2500 lines)
  dom_serialize.zig  # innerHTML/outerHTML serialization (~600 lines)
```

## Architecture

### Dependency Direction (one-way)

```
dom_api.zig (shared state + utilities)
  ^
  |--- dom_node.zig
  |--- dom_element.zig
  |--- dom_document.zig
  |--- dom_text.zig
  |--- dom_selector.zig
  |--- dom_style.zig
  |--- dom_serialize.zig
```

No circular imports. Each module imports `dom_api.zig` for shared state.

### Shared State (stays in dom_api.zig)

```zig
// Global state
pub var g_document: ?*anyopaque = null;
pub var dom_dirty: bool = false;
pub var element_class_id: qjs.JSClassID = 0;
pub var text_class_id: qjs.JSClassID = 0;
pub var active_element: ?*lxb.lxb_dom_node_t = null;

// Shared utilities
pub fn wrapNode(ctx, node) JSValue
pub fn getNode(ctx, val) ?*lxb_dom_node_t
pub fn getElement(ctx, val) ?*lxb_dom_element_t
pub fn jsStringToSlice(ctx, val) ?struct{ptr, len}
pub fn setDomDirty() void
pub fn throwDOMException(ctx, name, msg) JSValue

// Extern Lexbor functions
pub extern fn lxb_dom_document_create_element(...) ...
pub extern fn lxb_dom_node_insert_child(...) ...
// ... all Lexbor externs stay here as pub
```

### Module Registration Pattern

```zig
// dom_api.zig
pub fn registerDomApis(rt, ctx, document_ptr) void {
    // 1. Register classes
    // 2. Build prototype chain
    const node_proto = ...;
    const elem_proto = ...;

    // 3. Register methods on prototypes
    dom_node.registerNodeMethods(ctx, node_proto);
    dom_element.registerElementMethods(ctx, elem_proto);
    dom_text.registerTextMethods(ctx, text_proto);
    dom_selector.registerSelectorMethods(ctx, elem_proto);

    // 4. Build document object
    const doc_obj = ...;
    dom_document.registerDocumentMethods(ctx, doc_obj);
    dom_style.registerStyleMethods(ctx, global);

    // 5. Constructors & globals
}
```

## File Assignments

### dom_node.zig
- elementGetParentNode, elementGetParentElement
- elementGetFirstChild, elementGetLastChild
- elementGetNextSibling, elementGetPreviousSibling
- elementGetChildNodes, elementGetChildren
- elementGetTextContent, elementSetTextContent
- elementAppendChild, elementInsertBefore, elementRemoveChild, elementReplaceChild
- nodeNormalize, nodeCompareDocumentPosition, nodeIsEqualNode
- nodeGetIsConnected, nodeGetRootNode, nodeGetOwnerDocument
- elementGetNodeType, elementGetNodeName
- nodeGetNodeValue (on node_proto)
- elementContains
- elementBefore, elementAfter, elementReplaceWith, elementRemove

### dom_element.zig
- elementGetAttribute, elementSetAttribute, elementRemoveAttribute
- elementHasAttribute, elementToggleAttribute, elementGetAttributeNames
- getAttributeNode, setAttributeNode, removeAttributeNode (JS eval)
- elementGetClassName, elementSetClassName
- elementGetId, elementSetId
- classList (classListAdd, classListRemove, classListToggle, classListContains, classListReplace)
- elementGetDataset
- elementGetValue, elementSetValue
- elementGetHidden, elementSetHidden
- elementInsertAdjacentHTML, elementInsertAdjacentElement, elementInsertAdjacentText
- elementGetBoundingClientRect
- elementGetClientWidth/Height/Top/Left
- elementGetOffsetWidth/Height/Top/Left
- elementGetScrollTop/Left
- elementScrollIntoView
- templateGetContent
- elementGetContext (canvas)

### dom_document.zig
- documentGetElementById
- documentQuerySelector, documentQuerySelectorAll
- documentCreateElement, documentCreateElementNS
- documentCreateTextNode, documentCreateComment
- documentCreateDocumentFragment
- documentCreateEvent
- documentWrite
- documentGetElementsByClassName, documentGetElementsByTagName, documentGetElementsByName
- documentAdoptNode, documentImportNode
- documentCreateRange, documentCreateTreeWalker
- documentGetReadyState, documentGetActiveElement, documentGetBody, documentGetHead
- documentGetDocumentElement, documentGetTitle, documentSetTitle
- implCreateDocumentType, implCreateDocument
- DOMImplementation setup
- Document constructor (JS eval)
- createHTMLDocument (JS eval)

### dom_text.zig
- textGetData, textSetData
- nodeGetNodeValue (CharacterData version)
- getNodeFromText
- CharacterData JS eval (appendData, insertData, etc.)
- Text.splitText (JS eval)
- CharacterData no-children enforcement (JS eval)
- text_proto setup helper

### dom_selector.zig
- elementMatchesSelector
- matchSingleSimple
- matchAttributeSelector
- findPseudoStart
- isFirstChild, isLastChild, isFirstOfType, isLastOfType
- getNthIndex, getNthLastIndex
- isRoot
- walkTreeBySelector, walkTreeCollect
- parseSelectorParts, nodeMatchesSimple, nodeMatchesCompound
- walkTreeBySimpleSelector, walkTreeById
- nextDfsNode, prevElementSibling
- elementMatches, elementClosest
- elementQuerySelector (element-scoped), elementQuerySelectorAll

### dom_style.zig
- windowGetComputedStyle
- computedStyleGetPropertyValue
- computedStyleToString, computedStyleToStringWithBox, computedStyleToStringWithBoxInner
- argbToCssColor, fmtPx, fmtBoxShorthand
- cssSupports
- isValidCssValue, isValidShorthandValue, isValidSizeValue, etc.
- cssInitialValue
- styleSetProperty, styleGetCssText, styleSetCssText
- Style object creation

### dom_serialize.zig
- SerializeAccum
- serializeCallback
- elementGetInnerHTML, elementSetInnerHTML
- elementGetOuterHTML, elementSetOuterHTML
- HTML fragment parsing helpers

## Migration Strategy

1. Create each new file with `const api = @import("dom_api.zig");`
2. Move functions one module at a time
3. Build after each module move
4. Run WPT dom/nodes after all moves to verify no regression
5. Commit per-module (8 commits)

## Success Criteria

- All 8 files compile
- WPT dom/nodes score >= 45.5% (no regression)
- WPT dom/events score >= 67.2% (no regression)
- No circular imports
- Each file < 3000 lines
