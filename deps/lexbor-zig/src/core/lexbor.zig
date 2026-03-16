pub const core = @import("../core_ext.zig");

pub const MemoryMallocF = core.lexbor_memory_malloc_f;
pub const MemoryReallocF = core.lexbor_memory_realloc_f;
pub const MemoryCallocF = core.lexbor_memory_calloc_f;
pub const MemoryFreeF = core.lexbor_memory_calloc_f;

pub fn malloc(size: usize) ?*anyopaque {
    return core.lexbor_malloc(size);
}

pub fn realloc(dst: ?*anyopaque, size: usize) ?*anyopaque {
    return core.lexbor_realloc(dst, size);
}

pub fn calloc(num: usize, size: usize) ?*anyopaque {
    return core.lexbor_calloc(num, size);
}

pub fn free(dst: ?*anyopaque) void {
    core.lexbor_free(dst);
}

pub fn memorySetup(new_malloc: core.lexbor_memory_malloc_f, new_realloc: core.lexbor_memory_realloc_f, new_calloc: core.lexbor_memory_calloc_f, new_free: core.lexbor_memory_free_f) void {
    return core.lexbor_memory_setup(new_malloc, new_realloc, new_calloc, new_free);
}
