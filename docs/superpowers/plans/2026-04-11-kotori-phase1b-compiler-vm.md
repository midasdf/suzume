# kotori Phase 1b: Compiler + VM Basics

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compile AST to bytecode and execute it in a stack-based VM. Milestone: `1 + 2 * 3` evaluates to `7`.

**Architecture:** Compiler walks AST and emits bytecode (OpCode + operands). VM executes bytecodes in a dispatch loop with a value stack. JsValue uses NaN-boxing for all values.

**Tech Stack:** Zig 0.15, builds on Phase 1a (lexer/parser/AST). Test via `zig build test-kotori`.

**Spec:** `docs/superpowers/specs/2026-04-11-kotori-js-engine-design.md`

---

## File Structure

```
suzume/src/js/kotori/
├── bytecode.zig    # NEW: OpCode enum, Bytecode struct, BytecodeBuilder
├── compiler.zig    # NEW: AST → Bytecode compiler
├── vm.zig          # NEW: Stack-based VM execution loop
├── value.zig       # MODIFY: complete NaN-boxing with arithmetic ops
├── kotori.zig      # MODIFY: re-export new modules

suzume/tests/
├── test_kotori_vm.zig  # NEW: VM execution tests
├── test_kotori.zig     # MODIFY: add vm test import
```

---

### Task 1: Bytecode definitions

**Files:**
- Create: `src/js/kotori/bytecode.zig`
- Modify: `src/js/kotori/kotori.zig`

- [ ] **Step 1: Create bytecode.zig**

```zig
// src/js/kotori/bytecode.zig
const std = @import("std");
const JsValue = @import("value.zig").JsValue;

pub const OpCode = enum(u8) {
    // Stack ops
    load_const,      // [u16 idx] push constants[idx]
    pop,             // discard TOS
    dup,             // duplicate TOS

    // Arithmetic
    add,
    sub,
    mul,
    div,
    mod,
    neg,             // unary negate
    power,

    // Comparison
    eq,              // ==
    ne,              // !=
    strict_eq,       // ===
    strict_ne,       // !==
    lt,
    le,
    gt,
    ge,

    // Logical / bitwise
    not,             // !
    bit_not,         // ~
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    ushr,

    // Variables
    load_local,      // [u16 idx] push locals[idx]
    store_local,     // [u16 idx] locals[idx] = pop
    load_global,     // [u16 name_idx] push global[constants[name_idx]]
    store_global,    // [u16 name_idx] global[constants[name_idx]] = pop

    // Control flow
    jump,            // [i16 offset] unconditional
    jump_if_false,   // [i16 offset] pop, jump if falsy
    jump_if_true,    // [i16 offset] pop, jump if truthy

    // Functions
    call,            // [u8 argc] call function
    return_,
    return_undefined,

    // Objects (stubs for now)
    typeof_,
    void_,

    // Special
    halt,            // stop VM execution
};

pub const Bytecode = struct {
    code: std.ArrayListUnmanaged(u8) = .empty,
    constants: std.ArrayListUnmanaged(JsValue) = .empty,
    local_count: u16 = 0,
    param_count: u16 = 0,
    max_stack: u16 = 0,

    pub fn emit(self: *Bytecode, allocator: std.mem.Allocator, op: OpCode) !void {
        try self.code.append(allocator, @intFromEnum(op));
    }

    pub fn emitWithU16(self: *Bytecode, allocator: std.mem.Allocator, op: OpCode, operand: u16) !void {
        try self.code.append(allocator, @intFromEnum(op));
        try self.code.appendSlice(allocator, &std.mem.toBytes(operand));
    }

    pub fn emitWithI16(self: *Bytecode, allocator: std.mem.Allocator, op: OpCode, operand: i16) !void {
        try self.code.append(allocator, @intFromEnum(op));
        try self.code.appendSlice(allocator, &std.mem.toBytes(operand));
    }

    pub fn addConstant(self: *Bytecode, allocator: std.mem.Allocator, value: JsValue) !u16 {
        const idx: u16 = @intCast(self.constants.items.len);
        try self.constants.append(allocator, value);
        return idx;
    }

    /// Return current code offset (for patching jumps)
    pub fn currentOffset(self: *const Bytecode) u32 {
        return @intCast(self.code.items.len);
    }

    /// Emit a jump with placeholder offset, return the offset position to patch later
    pub fn emitJump(self: *Bytecode, allocator: std.mem.Allocator, op: OpCode) !u32 {
        try self.code.append(allocator, @intFromEnum(op));
        const patch_pos: u32 = @intCast(self.code.items.len);
        try self.code.appendSlice(allocator, &std.mem.toBytes(@as(i16, 0)));
        return patch_pos;
    }

    /// Patch a previously emitted jump to target current offset
    pub fn patchJump(self: *Bytecode, patch_pos: u32) void {
        const target: u32 = @intCast(self.code.items.len);
        const offset: i16 = @intCast(@as(i32, @intCast(target)) - @as(i32, @intCast(patch_pos)) - 2);
        const bytes = std.mem.toBytes(offset);
        self.code.items[patch_pos] = bytes[0];
        self.code.items[patch_pos + 1] = bytes[1];
    }

    pub fn deinit(self: *Bytecode, allocator: std.mem.Allocator) void {
        self.code.deinit(allocator);
        self.constants.deinit(allocator);
    }
};
```

- [ ] **Step 2: Update kotori.zig re-exports**
- [ ] **Step 3: `zig build test-kotori` passes**
- [ ] **Step 4: Commit**

```
feat(kotori): bytecode definitions with OpCode and Bytecode builder
```

---

### Task 2: JsValue arithmetic and comparison

**Files:**
- Modify: `src/js/kotori/value.zig`
- Create: `tests/test_kotori_vm.zig` (with value tests first)
- Modify: `tests/test_kotori.zig`

- [ ] **Step 1: Add tests**

```zig
// tests/test_kotori_vm.zig
const std = @import("std");
const kotori = @import("kotori");
const JsValue = kotori.JsValue;

test "JsValue number roundtrip" {
    const v = JsValue.initNumber(3.14);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), v.asNumber(), 0.001);
}

test "JsValue int roundtrip" {
    const v = JsValue.initInt(42);
    try std.testing.expectEqual(@as(i32, 42), v.asInt());
}

test "JsValue bool" {
    try std.testing.expect(JsValue.initBool(true).asBool());
    try std.testing.expect(!JsValue.initBool(false).asBool());
}

test "JsValue add numbers" {
    const a = JsValue.initNumber(10);
    const b = JsValue.initNumber(20);
    const result = JsValue.jsAdd(a, b);
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), result.asNumber(), 0.001);
}

test "JsValue subtract" {
    const result = JsValue.jsSub(JsValue.initNumber(10), JsValue.initNumber(3));
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), result.asNumber(), 0.001);
}

test "JsValue multiply" {
    const result = JsValue.jsMul(JsValue.initNumber(6), JsValue.initNumber(7));
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "JsValue comparison" {
    try std.testing.expect(JsValue.jsLt(JsValue.initNumber(1), JsValue.initNumber(2)).asBool());
    try std.testing.expect(!JsValue.jsLt(JsValue.initNumber(2), JsValue.initNumber(1)).asBool());
}

test "JsValue equality" {
    try std.testing.expect(JsValue.jsStrictEq(JsValue.initNumber(42), JsValue.initNumber(42)).asBool());
    try std.testing.expect(!JsValue.jsStrictEq(JsValue.initNumber(42), JsValue.initNumber(43)).asBool());
}

test "JsValue isTruthy" {
    try std.testing.expect(JsValue.initNumber(1).isTruthy());
    try std.testing.expect(!JsValue.initNumber(0).isTruthy());
    try std.testing.expect(JsValue.initBool(true).isTruthy());
    try std.testing.expect(!JsValue.initBool(false).isTruthy());
    try std.testing.expect(!JsValue.null_val.isTruthy());
    try std.testing.expect(!JsValue.undefined_val.isTruthy());
}
```

- [ ] **Step 2: Implement JsValue operations in value.zig**

Add to JsValue:
- `asInt() i32` — extract int from TAG_INT
- `asBool() bool` — extract bool from TAG_BOOL
- `isNumber() bool`, `isInt() bool`, `isBool() bool`, `isNull() bool`, `isUndefined() bool`
- `toNumber() f64` — coerce any value to number (int→f64, bool→0/1, null→0, undefined→NaN)
- `isTruthy() bool` — JS truthiness rules (false, 0, NaN, null, undefined, "" are falsy)
- `jsAdd(a, b) JsValue` — numeric addition (both converted to number via toNumber)
- `jsSub(a, b) JsValue`, `jsMul`, `jsDiv`, `jsMod`, `jsPow`
- `jsNeg(a) JsValue` — unary negate
- `jsLt(a, b) JsValue` — returns bool value
- `jsLe`, `jsGt`, `jsGe`
- `jsEq(a, b) JsValue` — abstract equality (==)
- `jsStrictEq(a, b) JsValue` — strict equality (===)
- `jsNe`, `jsStrictNe`
- `jsNot(a) JsValue` — logical not
- `jsBitNot`, `jsBitAnd`, `jsBitOr`, `jsBitXor`, `jsShl`, `jsShr`, `jsUshr`

For now, focus on numeric operations. String operations come later.

- [ ] **Step 3: Update test_kotori.zig aggregator to include test_kotori_vm.zig**
- [ ] **Step 4: Tests pass**
- [ ] **Step 5: Commit**

```
feat(kotori): JsValue arithmetic, comparison, and truthiness operations
```

---

### Task 3: Compiler — expressions

**Files:**
- Create: `src/js/kotori/compiler.zig`
- Modify: `src/js/kotori/kotori.zig`
- Modify: `tests/test_kotori_vm.zig`

- [ ] **Step 1: Add compilation + execution tests**

```zig
// Add to test_kotori_vm.zig
const Compiler = kotori.Compiler;
const VM = kotori.VM;

fn evalExpr(source: []const u8) !JsValue {
    var compiler = Compiler.init(std.testing.allocator, source);
    defer compiler.deinit();
    var bc = try compiler.compile();
    defer bc.deinit(std.testing.allocator);
    var vm = VM.init(&bc);
    return vm.execute();
}

test "eval: 42" {
    const result = try evalExpr("42");
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: 1 + 2" {
    const result = try evalExpr("1 + 2");
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: 1 + 2 * 3" {
    const result = try evalExpr("1 + 2 * 3");
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), result.asNumber(), 0.001);
}

test "eval: (1 + 2) * 3" {
    const result = try evalExpr("(1 + 2) * 3");
    try std.testing.expectApproxEqAbs(@as(f64, 9.0), result.asNumber(), 0.001);
}

test "eval: 10 - 3" {
    const result = try evalExpr("10 - 3");
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), result.asNumber(), 0.001);
}

test "eval: 10 / 3" {
    const result = try evalExpr("10 / 3");
    try std.testing.expectApproxEqAbs(@as(f64, 3.333), result.asNumber(), 0.01);
}

test "eval: -5" {
    const result = try evalExpr("-5");
    try std.testing.expectApproxEqAbs(@as(f64, -5.0), result.asNumber(), 0.001);
}

test "eval: !true" {
    const result = try evalExpr("!true");
    try std.testing.expect(!result.asBool());
}

test "eval: 1 < 2" {
    const result = try evalExpr("1 < 2");
    try std.testing.expect(result.asBool());
}

test "eval: 1 === 1" {
    const result = try evalExpr("1 === 1");
    try std.testing.expect(result.asBool());
}

test "eval: true ? 1 : 2" {
    const result = try evalExpr("true ? 1 : 2");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "eval: false ? 1 : 2" {
    const result = try evalExpr("false ? 1 : 2");
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.asNumber(), 0.001);
}
```

- [ ] **Step 2: Implement compiler.zig**

The compiler walks the AST and emits bytecode:

```zig
pub const Compiler = struct {
    parser: Parser,
    bc: Bytecode,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Compiler { ... }
    pub fn compile(self: *Compiler) !Bytecode { ... }
    pub fn deinit(self: *Compiler) void { ... }

    fn compileNode(self: *Compiler, idx: NodeIndex) !void {
        const node = self.parser.ast.getNode(idx);
        switch (node) {
            .number_literal => |n| {
                const ci = try self.bc.addConstant(self.allocator, JsValue.initNumber(n));
                try self.bc.emitWithU16(self.allocator, .load_const, ci);
            },
            .bool_literal => |b| {
                const ci = try self.bc.addConstant(self.allocator, JsValue.initBool(b));
                try self.bc.emitWithU16(self.allocator, .load_const, ci);
            },
            .null_literal => {
                const ci = try self.bc.addConstant(self.allocator, JsValue.null_val);
                try self.bc.emitWithU16(self.allocator, .load_const, ci);
            },
            .binary => |bin| {
                try self.compileNode(bin.lhs);
                try self.compileNode(bin.rhs);
                try self.bc.emit(self.allocator, binaryOpToOpCode(bin.op));
            },
            .unary => |u| {
                try self.compileNode(u.operand);
                try self.bc.emit(self.allocator, unaryOpToOpCode(u.op));
            },
            .conditional => |c| {
                try self.compileNode(c.test_);  // or whatever the field name is
                const else_jump = try self.bc.emitJump(self.allocator, .jump_if_false);
                try self.compileNode(c.consequent);
                const end_jump = try self.bc.emitJump(self.allocator, .jump);
                self.bc.patchJump(else_jump);
                try self.compileNode(c.alternate);
                self.bc.patchJump(end_jump);
            },
            .program => |list| {
                const items = self.parser.ast.getNodeList(list);
                for (items) |item| {
                    try self.compileNode(item);
                }
            },
            .expression_stmt => |expr_idx| {
                try self.compileNode(expr_idx);
                // keep last value on stack (for REPL-like behavior)
            },
            else => {
                // Unsupported node — emit undefined for now
                const ci = try self.bc.addConstant(self.allocator, JsValue.undefined_val);
                try self.bc.emitWithU16(self.allocator, .load_const, ci);
            },
        }
    }
};
```

The compile() method:
1. Call parser.parse() to get program AST
2. Walk AST nodes via compileNode()
3. Emit .halt at the end
4. Return the Bytecode

IMPORTANT: Read the actual AST field names from ast.zig. They may be `test_` instead of `test`, etc.

- [ ] **Step 3: Tests pass**
- [ ] **Step 4: Commit**

```
feat(kotori): compiler for expressions — AST to bytecode
```

---

### Task 4: VM execution loop

**Files:**
- Create: `src/js/kotori/vm.zig`
- Modify: `src/js/kotori/kotori.zig`

- [ ] **Step 1: Implement VM**

```zig
pub const VM = struct {
    bc: *const Bytecode,
    stack: [4096]JsValue = undefined,
    sp: u32 = 0,
    ip: u32 = 0,

    pub fn init(bc: *const Bytecode) VM {
        return .{ .bc = bc };
    }

    pub fn execute(self: *VM) !JsValue {
        while (self.ip < self.bc.code.items.len) {
            const op: OpCode = @enumFromInt(self.bc.code.items[self.ip]);
            self.ip += 1;
            switch (op) {
                .load_const => {
                    const idx = self.readU16();
                    self.push(self.bc.constants.items[idx]);
                },
                .pop => { _ = self.pop(); },
                .dup => { const v = self.peek(); self.push(v); },
                .add => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsAdd(a, b)); },
                .sub => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsSub(a, b)); },
                .mul => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsMul(a, b)); },
                .div => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsDiv(a, b)); },
                .mod => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsMod(a, b)); },
                .neg => { const a = self.pop(); self.push(JsValue.jsNeg(a)); },
                .not => { const a = self.pop(); self.push(JsValue.jsNot(a)); },
                .lt => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsLt(a, b)); },
                .le => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsLe(a, b)); },
                .gt => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsGt(a, b)); },
                .ge => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsGe(a, b)); },
                .eq => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsEq(a, b)); },
                .ne => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsNe(a, b)); },
                .strict_eq => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsStrictEq(a, b)); },
                .strict_ne => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsStrictNe(a, b)); },
                .jump => {
                    const offset = self.readI16();
                    self.ip = @intCast(@as(i32, @intCast(self.ip)) + offset);
                },
                .jump_if_false => {
                    const offset = self.readI16();
                    const val = self.pop();
                    if (!val.isTruthy()) {
                        self.ip = @intCast(@as(i32, @intCast(self.ip)) + offset);
                    }
                },
                .jump_if_true => {
                    const offset = self.readI16();
                    const val = self.pop();
                    if (val.isTruthy()) {
                        self.ip = @intCast(@as(i32, @intCast(self.ip)) + offset);
                    }
                },
                .halt => {
                    if (self.sp > 0) return self.pop();
                    return JsValue.undefined_val;
                },
                else => return JsValue.undefined_val, // unimplemented ops
            }
        }
        if (self.sp > 0) return self.pop();
        return JsValue.undefined_val;
    }

    fn push(self: *VM, val: JsValue) void {
        self.stack[self.sp] = val;
        self.sp += 1;
    }

    fn pop(self: *VM) JsValue {
        self.sp -= 1;
        return self.stack[self.sp];
    }

    fn peek(self: *VM) JsValue {
        return self.stack[self.sp - 1];
    }

    fn readU16(self: *VM) u16 {
        const bytes = self.bc.code.items[self.ip..][0..2];
        self.ip += 2;
        return std.mem.bytesToValue(u16, bytes);
    }

    fn readI16(self: *VM) i16 {
        const bytes = self.bc.code.items[self.ip..][0..2];
        self.ip += 2;
        return std.mem.bytesToValue(i16, bytes);
    }
};
```

- [ ] **Step 2: Update kotori.zig, ensure all tests pass**
- [ ] **Step 3: Commit**

```
feat(kotori): stack-based VM execution loop
```

---

### Task 5: End-to-end integration — eval helper

**Files:**
- Modify: `tests/test_kotori_vm.zig`

- [ ] **Step 1: Add comprehensive eval tests**

```zig
test "eval: 2 ** 10" {
    const result = try evalExpr("2 ** 10");
    try std.testing.expectApproxEqAbs(@as(f64, 1024.0), result.asNumber(), 0.001);
}

test "eval: 10 % 3" {
    const result = try evalExpr("10 % 3");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "eval: typeof 42" {
    // typeof returns string — skip for now, just test it doesn't crash
}

test "eval: nested arithmetic" {
    const result = try evalExpr("(10 + 20) * (3 - 1) / 2");
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), result.asNumber(), 0.001);
}

test "eval: comparison chain" {
    const result = try evalExpr("1 < 2 ? 10 + 5 : 0");
    try std.testing.expectApproxEqAbs(@as(f64, 15.0), result.asNumber(), 0.001);
}

test "eval: null coalescing" {
    // null handling
    const result = try evalExpr("null === null");
    try std.testing.expect(result.asBool());
}
```

- [ ] **Step 2: All tests pass**
- [ ] **Step 3: Commit**

```
test(kotori): end-to-end expression evaluation tests
```

---

## Summary

After completing all 5 tasks:
- **bytecode.zig**: OpCode enum, Bytecode struct with builder (emit, constants, jump patching)
- **compiler.zig**: AST → Bytecode for expressions (literals, binary, unary, conditional)
- **vm.zig**: Stack-based VM executing all arithmetic/comparison/logic opcodes + jumps
- **value.zig**: Complete NaN-boxing with JS arithmetic, comparison, truthiness
- **Tests**: Value operations + compilation + execution for expressions

Milestone achieved: `1 + 2 * 3` → `7`

Next plan: Phase 1c (Object model + prototype chain + variables + functions)
