//! kotori_runtime.zig — Runtime wrapper for the kotori JS engine.
//!
//! Provides an eval-based API similar to QuickJS's JsRuntime,
//! enabling multiple script evaluations in the same global scope.

const std = @import("std");
const kotori = @import("kotori");
const kotori_dom = @import("kotori_dom");

const VM = kotori.VM;
const JsValue = kotori.JsValue;
const Compiler = kotori.Compiler;
const Bytecode = kotori.Bytecode;
const StringPool = kotori.StringPool;

pub const KotoriRuntime = struct {
    pool: *StringPool,
    vm: VM,
    allocator: std.mem.Allocator,
    document_ptr: ?*anyopaque,
    /// Track compiled bytecodes so they can be freed on deinit.
    bytecodes: std.ArrayListUnmanaged(Bytecode),

    pub const EvalResult = union(enum) {
        ok: ?[]const u8,
        err: []const u8,

        pub fn isOk(self: EvalResult) bool {
            return self == .ok;
        }
    };

    pub fn init(allocator: std.mem.Allocator, document_ptr: *anyopaque) !KotoriRuntime {
        // Allocate a long-lived StringPool shared across all compilations
        const pool = try allocator.create(StringPool);
        pool.* = StringPool.init(allocator);

        // Create a bootstrap bytecode (empty program) to initialize the VM
        var bootstrap_compiler = Compiler.initWithPool(allocator, "", pool);
        var bootstrap_bc = try bootstrap_compiler.compile();
        bootstrap_compiler.deinit();

        var vm = VM.init(allocator, &bootstrap_bc, pool);
        try vm.initBuiltins();
        try kotori_dom.initDomBuiltins(&vm, document_ptr);

        var self = KotoriRuntime{
            .pool = pool,
            .vm = vm,
            .allocator = allocator,
            .document_ptr = document_ptr,
            .bytecodes = .{},
        };

        // Store the bootstrap bytecode (VM references it)
        try self.bytecodes.append(allocator, bootstrap_bc);

        return self;
    }

    /// Evaluate a JS source string. Returns the result or error message.
    pub fn eval(self: *KotoriRuntime, source: []const u8) EvalResult {
        if (source.len == 0) return .{ .ok = null };

        // Compile with the shared pool
        var compiler = Compiler.initWithPool(self.allocator, source, self.pool);
        const bc = compiler.compile() catch |e| {
            compiler.deinit();
            return .{ .err = @errorName(e) };
        };
        compiler.deinit();

        // Store bytecode (VM will reference it during execution)
        self.bytecodes.append(self.allocator, bc) catch {
            return .{ .err = "OutOfMemory" };
        };
        const bc_ref = &self.bytecodes.items[self.bytecodes.items.len - 1];

        // Load and execute on existing VM (preserves globals)
        self.vm.loadCode(bc_ref);
        const result = self.vm.execute() catch |e| {
            return .{ .err = @errorName(e) };
        };

        // Convert result to string if it's a string
        if (result.isString()) {
            if (self.pool.get(result.asStringId())) |s| {
                return .{ .ok = s };
            }
        }
        return .{ .ok = null };
    }

    /// Check and clear DOM dirty flag.
    pub fn checkDomDirty() bool {
        if (kotori_dom.dom_dirty) {
            kotori_dom.dom_dirty = false;
            return true;
        }
        return false;
    }

    pub fn deinit(self: *KotoriRuntime) void {
        kotori_dom.deinit();
        self.vm.deinit();
        for (self.bytecodes.items) |*bc| {
            bc.deinit(self.allocator);
        }
        self.bytecodes.deinit(self.allocator);
        self.pool.deinit();
        self.allocator.destroy(self.pool);
    }
};
