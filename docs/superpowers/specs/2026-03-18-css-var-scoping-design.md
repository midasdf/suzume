# CSS Variable Element-Level Scoping

## Problem

CSS custom properties are currently extracted into a single global VarMap from all author rules, regardless of which selector they belong to. This means `--color` declared in `.dark-theme { --color: #000 }` leaks globally instead of being scoped to `.dark-theme` descendants.

## Solution

Build per-element VarMaps during the cascade walk. Each element that declares custom properties gets a new VarMap with its parent's VarMap as the parent pointer. Elements without custom property declarations share their parent's VarMap (zero allocation).

## Changes

**File: `src/css/cascade.zig`**

1. Remove global variable extraction (lines 198-207)
2. Modify `walkAndCompute` to accept `*const VarMap` instead of using global
3. Inside `walkAndCompute`, after collecting matching declarations:
   - Filter `--*` declarations from the matched rules
   - If any found: create new VarMap with parent chain, set variables
   - If none: reuse parent VarMap pointer
4. Pass the (possibly new) VarMap to `applyDeclaration` and child recursion

**No changes to:** variables.zig, VarMap struct, resolveVarRefs, or any other file.

## Memory

- Typical site: 1-5 VarMaps (most variables on :root)
- VarMap with parent pointer: ~64 bytes + entries
- Elements without --* declarations: 0 extra allocation
