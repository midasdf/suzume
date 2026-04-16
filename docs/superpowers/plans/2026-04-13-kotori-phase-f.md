# kotori Phase F: Bug Fixes + Modern JS Features — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix 3 critical JS correctness bugs (empty string falsiness, generator spread, UTF-8 strings) and add 2 features (destructuring params, tagged templates).

**Architecture:** All changes are in the kotori engine (`suzume/src/js/kotori/`). Bug fixes touch `string_pool.zig`, `value.zig`, and `vm.zig`. Features touch `compiler.zig`, `ast.zig`, `parser.zig`. TDD: write failing test first, then implement.

**Tech Stack:** Zig 0.14, custom NaN-boxing VM, Pratt parser

**Spec:** `docs/superpowers/specs/2026-04-13-kotori-phase-f-design.md`

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `src/js/kotori/string_pool.zig` | Modify | Add `EMPTY_STRING_ID`, intern `""` in init |
| `src/js/kotori/value.zig` | Modify | Fix `isTruthy` for empty strings |
| `src/js/kotori/vm.zig` | Modify | Generator `Symbol.iterator`, spread fix, UTF-8 string iteration |
| `src/js/kotori/compiler.zig` | Modify | Destructuring in function params |
| `src/js/kotori/ast.zig` | Modify | Add `tagged_template` node type |
| `src/js/kotori/parser.zig` | Modify | Parse tagged template as infix backtick |
| `src/js/kotori/bytecode.zig` | Possibly modify | Only if tagged templates need new opcodes |
| `tests/test_kotori_vm.zig` | Modify | All new tests |

---

## Chunk 1: Bug Fixes

### Task 1: Empty String Falsiness

**Files:**
- Modify: `src/js/kotori/string_pool.zig:5-15` (init + constant)
- Modify: `src/js/kotori/value.zig:148-159` (isTruthy)
- Modify: `tests/test_kotori_vm.zig` (append tests)

- [ ] **Step 1: Write failing tests**

Append to `tests/test_kotori_vm.zig`:

```zig
// ── Phase F: Empty string falsiness ─────────────────────────────

test "eval: empty string is falsy" {
    const result = try evalExpr(
        \\"" ? "yes" : "no"
    );
    try std.testing.expect(result.isString());
}

test "eval: non-empty string is truthy" {
    const result = try evalExpr(
        \\"hello" ? 1 : 0
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "eval: not empty string is true" {
    const result = try evalExpr(
        \\!""
    );
    try std.testing.expect(result.asBool());
}

test "eval: if empty string takes else" {
    const result = try evalExpr(
        \\let r = 0;
        \\if ("") { r = 1; } else { r = 2; }
        \\r
    );
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.asNumber(), 0.001);
}
```

- [ ] **Step 2: Run tests — expect FAIL**

Run: `cd ~/suzume && zig build test-kotori 2>&1 | grep -E "FAIL|PASS|error"`
Expected: Tests fail because `""` is currently truthy.

- [ ] **Step 3: Reserve StringId 0 for empty string**

In `src/js/kotori/string_pool.zig`, add the constant and modify init:

```zig
pub const EMPTY_STRING_ID: StringId = 0;

pub const StringPool = struct {
    // ... existing fields ...

    pub fn init(allocator: std.mem.Allocator) StringPool {
        var pool: StringPool = .{
            .strings = .{},
            .allocator = allocator,
            .next_id = 0,
        };
        // Reserve StringId 0 for empty string
        pool.intern("") catch {};
        return pool;
    }
```

Wait — `intern` returns `!StringId` (can error with OOM). But `init` returns by value, not error. Two options:
- Change init to return `!StringPool` — too invasive, breaks all callers
- Use `pool.strings.getOrPut` directly with a non-failing pattern

Simpler: just call `_ = pool.intern("") catch {};` — on OOM at init time the system is already doomed. The catch discards the error since we know the ID will be 0.

But wait, `intern` calls `self.allocator.dupe` which allocates. And the `getOrPut` also allocates. We need the allocator valid at this point. Actually, the StringPool.init already has the allocator. Let's just do the intern and ignore potential OOM:

```zig
pub fn init(allocator: std.mem.Allocator) StringPool {
    var pool: StringPool = .{
        .strings = .{},
        .allocator = allocator,
        .next_id = 0,
    };
    _ = pool.intern("") catch {};
    return pool;
}
```

This guarantees `""` gets `StringId = 0` since `next_id` starts at 0.

- [ ] **Step 4: Fix isTruthy in value.zig**

In `src/js/kotori/value.zig`, modify the `isTruthy` function:

Replace the comment line and return:
```zig
// OLD:
// Objects, strings, symbols are truthy (empty string falsiness needs pool access — TODO)
return true;
```

With:
```zig
if (self.isString()) return self.asStringId() != @import("string_pool.zig").EMPTY_STRING_ID;
// Objects and symbols are always truthy
return true;
```

- [ ] **Step 5: Run tests — expect PASS**

Run: `cd ~/suzume && zig build test-kotori 2>&1 | grep -E "FAIL|error"`
Expected: All tests pass (469 existing + 4 new = 473).

- [ ] **Step 6: Commit**

```bash
cd ~/suzume && git add src/js/kotori/string_pool.zig src/js/kotori/value.zig tests/test_kotori_vm.zig
git commit -m "fix(kotori): empty string falsiness — reserve StringId 0 for \"\""
```

---

### Task 2: Generator Symbol.iterator + Spread Fix

**Files:**
- Modify: `src/js/kotori/vm.zig:5931-5939` (createGeneratorObject)
- Modify: `src/js/kotori/vm.zig:844-893` (spread_into_array)
- Modify: `tests/test_kotori_vm.zig` (append tests)

- [ ] **Step 1: Write failing test for `[...generator()]`**

Append to `tests/test_kotori_vm.zig`:

```zig
// ── Phase F: Spread generator fix ───────────────────────────────

test "eval: spread generator into array" {
    const result = try evalExpr(
        \\function* g() { yield 1; yield 2; yield 3; }
        \\let a = [...g()];
        \\a[0] + a[1] + a[2]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

test "eval: spread generator with strings" {
    const result = try evalExpr(
        \\function* g() { yield "a"; yield "b"; }
        \\let a = [...g()];
        \\a.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.asNumber(), 0.001);
}
```

- [ ] **Step 2: Run tests — check current behavior**

The existing "spread generator via for-of collect" test already passes via workaround. The direct `[...g()]` tests may crash or produce wrong results due to re-entrant VM issue.

Run: `cd ~/suzume && zig build test-kotori 2>&1 | grep -E "FAIL|error"`

- [ ] **Step 3: Add Symbol.iterator to generator objects**

In `src/js/kotori/vm.zig`, find `createGeneratorObject` (around line 5931). Add a Symbol.iterator method that returns `this`:

```zig
fn createGeneratorObject(self: *VM, func_obj: *JsObject) !*JsObject {
    const gen_obj = try self.createObj(.{ .obj_type = .generator });
    gen_obj.data = .{ .generator_data = .{
        .state = .suspended_start,
        .func_obj = func_obj,
    } };
    try self.registerNativeMethod(gen_obj, "next", &nativeGeneratorNext);
    try self.registerNativeMethod(gen_obj, "return", &nativeGeneratorReturn);
    // ES6: generators are iterables — Symbol.iterator returns this
    try self.setSymbolProp(gen_obj, SYMBOL_ITERATOR, &nativeReturnThis);
    return gen_obj;
}
```

Need to add `nativeReturnThis` and `setSymbolProp` helper. For `setSymbolProp`:

```zig
fn setSymbolProp(self: *VM, obj: *JsObject, symbol_id: u32, func: JsObject.NativeFn) !void {
    const fn_obj = try self.createObj(.{ .obj_type = .native_function });
    fn_obj.data = .{ .native_fn = func };
    if (obj.symbol_props == null) obj.symbol_props = .{};
    try obj.symbol_props.?.put(self.allocator, symbol_id, JsValue.initObject(fn_obj));
}
```

For `nativeReturnThis`:

```zig
fn nativeReturnThis(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    return this;
}
```

Note: Check if `setSymbolProp` already exists in the codebase. If a similar pattern is used, follow that. Otherwise add these two functions near `createGeneratorObject`.

- [ ] **Step 4: Remove generator branch from spread_into_array**

In `src/js/kotori/vm.zig`, in the `spread_into_array` opcode handler, remove the `else if (iter_obj.obj_type == .generator)` branch (the block from roughly line 858-873). The `findSymbolProp` path at the bottom will now pick up generators via their new `Symbol.iterator`.

Before (remove this block):
```zig
} else if (iter_obj.obj_type == .generator) {
    // Generator: collect all yielded values by calling .next() until done
    const g_next_id = try self.pool.intern("next");
    // ... entire block ...
}
```

The remaining paths handle: array (fast path), iterator, Symbol.iterator (catches generators now), string.

- [ ] **Step 5: Run tests — expect PASS**

Run: `cd ~/suzume && zig build test-kotori 2>&1 | grep -E "FAIL|error"`
Expected: All tests pass including new spread generator tests + existing generator/iterator tests.

- [ ] **Step 6: Commit**

```bash
cd ~/suzume && git add src/js/kotori/vm.zig tests/test_kotori_vm.zig
git commit -m "fix(kotori): generator Symbol.iterator + spread via iterator protocol"
```

---

### Task 3: String Iterator UTF-8

**Files:**
- Modify: `src/js/kotori/vm.zig` (spread_into_array string path ~line 882, string iterator next)
- Modify: `tests/test_kotori_vm.zig` (append tests)

- [ ] **Step 1: Write failing tests**

Append to `tests/test_kotori_vm.zig`:

```zig
// ── Phase F: UTF-8 string iteration ─────────────────────────────

test "eval: spread CJK string" {
    const result = try evalExpr(
        \\let a = [..."abc"];
        \\a.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: for-of multibyte string" {
    const result = try evalExpr(
        \\let count = 0;
        \\for (let c of "hi") count++;
        \\count
    );
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.asNumber(), 0.001);
}
```

Note: Testing with actual CJK/emoji in Zig multiline strings may be tricky. Use ASCII tests to verify the iteration count doesn't regress, and if possible, test with known multi-byte sequences.

- [ ] **Step 2: Run tests — check current behavior**

Run: `cd ~/suzume && zig build test-kotori 2>&1 | grep -E "FAIL|error"`

- [ ] **Step 3: Fix string spread in spread_into_array**

In `src/js/kotori/vm.zig`, find the string spread path in `spread_into_array` (the `else if (iterable.isString())` branch). Replace byte-level iteration with UTF-8 codepoint iteration:

```zig
} else if (iterable.isString()) {
    // Spread string into codepoints (UTF-8 aware)
    if (self.pool.get(iterable.asStringId())) |s| {
        var i: usize = 0;
        while (i < s.len) {
            const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const end = @min(i + cp_len, s.len);
            const char_str = try self.pool.intern(s[i..end]);
            try arr.data.array.append(self.allocator, JsValue.initString(char_str));
            i = end;
        }
    }
}
```

- [ ] **Step 4: Fix string iterator next**

Find where `IteratorData` with a string source advances. Search for `iterator_data` handling in the native iterator next function. The index should advance by codepoint bytes, not by 1:

In the native iterator next function (find `nativeIteratorNext` or similar), when source is a string:

```zig
// OLD: advance by 1 byte
// NEW: advance by UTF-8 codepoint
const cp_len = std.unicode.utf8ByteSequenceLength(s[idx]) catch 1;
const end = @min(idx + cp_len, s.len);
const char_str = try self.pool.intern(s[idx..end]);
iter.index = @intCast(end);
```

- [ ] **Step 5: Run tests — expect PASS**

Run: `cd ~/suzume && zig build test-kotori 2>&1 | grep -E "FAIL|error"`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
cd ~/suzume && git add src/js/kotori/vm.zig tests/test_kotori_vm.zig
git commit -m "fix(kotori): UTF-8 codepoint iteration for string spread and for-of"
```

---

## Chunk 2: Features

### Task 4: Destructuring in Function Parameters

**Files:**
- Modify: `src/js/kotori/compiler.zig:795-845` (compileFunctionBody param handling)
- Modify: `tests/test_kotori_vm.zig` (append tests)

- [ ] **Step 1: Write failing tests**

Append to `tests/test_kotori_vm.zig`:

```zig
// ── Phase F: Destructuring parameters ───────────────────────────

test "eval: object destructuring param" {
    const result = try evalExpr(
        \\function f({a, b}) { return a + b; }
        \\f({a: 1, b: 2})
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: array destructuring param" {
    const result = try evalExpr(
        \\function f([x, y]) { return x * y; }
        \\f([3, 4])
    );
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), result.asNumber(), 0.001);
}

test "eval: destructuring param with default" {
    const result = try evalExpr(
        \\function f({a = 10}) { return a; }
        \\f({})
    );
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}

test "eval: nested destructuring param" {
    const result = try evalExpr(
        \\function f({a: {b}}) { return b; }
        \\f({a: {b: 42}})
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: arrow destructuring param" {
    const result = try evalExpr(
        \\let f = ({x}) => x + 1;
        \\f({x: 9})
    );
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}

test "eval: multiple destructuring params" {
    const result = try evalExpr(
        \\function f({a}, [b]) { return a + b; }
        \\f({a: 10}, [20])
    );
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), result.asNumber(), 0.001);
}
```

- [ ] **Step 2: Run tests — expect FAIL**

Run: `cd ~/suzume && zig build test-kotori 2>&1 | grep -E "FAIL|error"`

- [ ] **Step 3: Implement destructuring param support**

In `src/js/kotori/compiler.zig`, modify `compileFunctionBody`. The key change is in two places:

**A) Param registration (line ~797-818):** Add cases for `array_pattern` and `object_pattern`:

```zig
for (params) |p_idx| {
    const p = self.parser.ast.getNode(p_idx);
    switch (p) {
        .identifier => |id| _ = try self.addLocal(id),
        .assign_pattern => |ap| {
            const left = self.parser.ast.getNode(ap.left);
            switch (left) {
                .identifier => |id| _ = try self.addLocal(id),
                else => _ = try self.addLocal(0),
            }
        },
        .rest_element => |operand| {
            const elem = self.parser.ast.getNode(operand);
            switch (elem) {
                .identifier => |id| _ = try self.addLocal(id),
                else => _ = try self.addLocal(0),
            }
        },
        // NEW: destructuring patterns get a placeholder local
        .array_pattern, .object_pattern => {
            _ = try self.addLocal(0); // placeholder
        },
        else => _ = try self.addLocal(0),
    }
}
```

**B) Post-param destructuring (line ~821-845):** Add destructuring emit after default param handling:

```zig
for (params, 0..) |p_idx, i| {
    const p = self.parser.ast.getNode(p_idx);
    switch (p) {
        .assign_pattern => |ap| {
            // ... existing default param code ...
        },
        .rest_element => {
            // ... existing rest param code ...
        },
        // NEW: emit destructuring for pattern params
        .array_pattern => |list| {
            try self.emitOpU16(.load_local, @intCast(i));
            try self.compileArrayDestructure(list);
            try self.emitOp(.pop);
        },
        .object_pattern => |list| {
            try self.emitOpU16(.load_local, @intCast(i));
            try self.compileObjectDestructure(list);
            try self.emitOp(.pop);
        },
        else => {},
    }
}
```

This loads the param value (which the VM already placed in the local slot from the call arguments), then runs the existing destructuring code which creates new locals for each destructured binding.

- [ ] **Step 4: Run tests — expect PASS**

Run: `cd ~/suzume && zig build test-kotori 2>&1 | grep -E "FAIL|error"`
Expected: All tests pass (existing + new).

- [ ] **Step 5: Commit**

```bash
cd ~/suzume && git add src/js/kotori/compiler.zig tests/test_kotori_vm.zig
git commit -m "feat(kotori): destructuring in function parameters"
```

---

### Task 5: Tagged Template Literals

**Files:**
- Modify: `src/js/kotori/ast.zig` (add tagged_template node)
- Modify: `src/js/kotori/parser.zig` (parse tagged template as infix)
- Modify: `src/js/kotori/compiler.zig` (compile tagged template)
- Modify: `tests/test_kotori_vm.zig` (append tests)

- [ ] **Step 1: Write failing tests**

Append to `tests/test_kotori_vm.zig`:

```zig
// ── Phase F: Tagged template literals ───────────────────────────

test "eval: tagged template basic" {
    const result = try evalExpr(
        \\function tag(strings, a, b) { return strings[0] + a + strings[1] + b + strings[2]; }
        \\tag`x${1}y${2}z`
    );
    try std.testing.expect(result.isString());
}

test "eval: tagged template strings length" {
    const result = try evalExpr(
        \\function tag(strings) { return strings.length; }
        \\tag`a${0}b${0}c`
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: tagged template no expressions" {
    const result = try evalExpr(
        \\function tag(strings) { return strings[0]; }
        \\tag`hello`
    );
    try std.testing.expect(result.isString());
}

test "eval: tagged template raw property" {
    const result = try evalExpr(
        \\function tag(strings) { return strings.raw[0]; }
        \\tag`hello`
    );
    try std.testing.expect(result.isString());
}
```

- [ ] **Step 2: Run tests — expect FAIL**

Run: `cd ~/suzume && zig build test-kotori 2>&1 | grep -E "FAIL|error"`

- [ ] **Step 3: Add tagged_template AST node**

In `src/js/kotori/ast.zig`, add to the `Node` union:

```zig
tagged_template: struct { tag: NodeIndex, quasi: NodeList, exprs: NodeList },
```

Place it near `template_literal` in the expressions section.

- [ ] **Step 4: Parse tagged templates**

In `src/js/kotori/parser.zig`, the key insight is: when a backtick follows an expression, it's a tagged template, not a standalone template literal.

Find where template literals are parsed (search for `template_literal` or `backtick`). In the Pratt parser's infix handling (or postfix/call-level), add:

After parsing a primary expression, if the next token is a backtick (template start), and we're at call-level precedence or higher, parse it as a tagged template:

```zig
// In the infix/postfix handling loop of parsePrecedence or similar:
// After member access, call, etc. — check for tagged template
if (self.current.type == .template_start or self.current.type == .backtick) {
    // Parse template parts
    var quasis = std.ArrayListUnmanaged(NodeIndex){};
    var exprs = std.ArrayListUnmanaged(NodeIndex){};
    defer quasis.deinit(self.allocator);
    defer exprs.deinit(self.allocator);

    // Parse template: quasi ${expr} quasi ${expr} quasi
    // First quasi
    try quasis.append(self.allocator, try self.ast.addNode(self.allocator, .{ .string_literal = self.current.string_id.? }));
    self.advance();

    while (self.current.type == .template_expr_start) {
        self.advance(); // skip ${
        try exprs.append(self.allocator, try self.parseExpression());
        // expect template_middle or template_end
        try quasis.append(self.allocator, try self.ast.addNode(self.allocator, .{ .string_literal = self.current.string_id.? }));
        self.advance();
    }

    const quasi_list = try self.ast.addNodeList(self.allocator, quasis.items);
    const exprs_list = try self.ast.addNodeList(self.allocator, exprs.items);
    left = try self.ast.addNode(self.allocator, .{ .tagged_template = .{
        .tag = left,
        .quasi = quasi_list,
        .exprs = exprs_list,
    } });
}
```

Note: This is a rough outline. The actual token types for template handling need to match what the lexer produces. Check how existing `template_literal` is parsed and follow the same token flow.

- [ ] **Step 5: Compile tagged templates**

In `src/js/kotori/compiler.zig`, add a case for `tagged_template` in `compileNode`:

```zig
.tagged_template => |tt| {
    // 1. Compile the tag function
    try self.compileNode(tt.tag);

    // 2. Create the strings array from quasi parts
    const quasis = self.parser.ast.getNodeList(tt.quasi);
    try self.emitOpU16(.new_array, @intCast(quasis.len));
    for (quasis, 0..) |q, idx| {
        try self.emitOp(.dup); // dup array
        try self.compileNode(q); // push string
        try self.emitConstant(JsValue.initNumber(@floatFromInt(idx)));
        try self.emitOp(.set_elem);
    }

    // 3. Add .raw property (same as strings for now — escape processing TODO)
    try self.emitOp(.dup); // dup strings array
    try self.emitOp(.dup); // dup again for raw = strings (same content)
    const raw_id = try self.parser.pool.intern("raw");
    const raw_ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(raw_id)));
    try self.emitOpU16(.set_prop, raw_ci);

    // 4. Compile each expression argument
    const exprs = self.parser.ast.getNodeList(tt.exprs);
    for (exprs) |e| {
        try self.compileNode(e);
    }

    // 5. Call: tag(strings, expr1, expr2, ...)
    try self.emitOpU16(.call, @intCast(1 + exprs.len));
},
```

- [ ] **Step 6: Run tests — expect PASS**

Run: `cd ~/suzume && zig build test-kotori 2>&1 | grep -E "FAIL|error"`

- [ ] **Step 7: Commit**

```bash
cd ~/suzume && git add src/js/kotori/ast.zig src/js/kotori/parser.zig src/js/kotori/compiler.zig tests/test_kotori_vm.zig
git commit -m "feat(kotori): tagged template literals with .raw property"
```

---

## Final Verification

- [ ] **Run full test suite**

```bash
cd ~/suzume && zig build test-kotori 2>&1
```

Expected: All tests pass (469 original + ~16 new = ~485 total).

- [ ] **Verify no regressions in browser build**

```bash
cd ~/suzume && zig build 2>&1 | head -20
```

Expected: Clean build, no errors.
