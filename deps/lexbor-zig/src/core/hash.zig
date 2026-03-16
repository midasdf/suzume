const std = @import("std");
const span = std.mem.span;

const core = @import("../core_ext.zig");

pub const Search = core.lexbor_hash_search_t;
pub const Insert = core.lexbor_hash_insert_t;

pub const SHORT_SIZE = core.LEXBOR_HASH_SHORT_SIZE;
pub const TABLE_MIN_SIZE = core.LEXBOR_HASH_TABLE_MIN_SIZE;

pub const insert_raw = core.lexbor_hash_insert_raw;
pub const insert_lower = core.lexbor_hash_insert_lower;
pub const insert_upper = core.lexbor_hash_insert_upper;

pub const search_raw = core.lexbor_hash_search_raw;
pub const search_lower = core.lexbor_hash_search_lower;
pub const search_upper = core.lexbor_hash_search_upper;

pub const Hash = core.lexbor_hash_t;
pub const Entry = core.lexbor_hash_entry_t;

pub const IdF = core.lexbor_hash_id_f;
pub const CopyF = core.lexbor_hash_copy_f;
pub const CmpF = core.lexbor_hash_cmp_f;

pub fn create() ?*core.lexbor_hash_t {
    return core.lexbor_hash_create();
}

pub fn init(hash: ?*core.lexbor_hash_t, table_size: usize, struct_size: usize) core.lexbor_status_t {
    const status = core.lexbor_hash_init(hash, table_size, struct_size);
    return @enumFromInt(status);
}

pub fn clean(hash: ?*core.lexbor_hash_t) void {
    core.lexbor_hash_clean(hash);
}

pub fn destroy(hash: ?*core.lexbor_hash_t, destroy_obj: bool) ?*core.lexbor_hash_t {
    return core.lexbor_hash_destroy(hash, destroy_obj);
}

pub fn insert(hash: ?*core.lexbor_hash_t, insert_: ?*const core.lexbor_hash_insert_t, key: []const u8, length: usize) ?*anyopaque {
    return core.lexbor_hash_insert(hash, insert_, @ptrCast(key.ptr), length);
}

pub fn insertByEntry(hash: ?*core.lexbor_hash_t, entry: ?*core.lexbor_hash_entry_t, search_: ?*const core.lexbor_hash_search_t, key: []const u8, length: usize) ?*anyopaque {
    return core.lexbor_hash_insert_by_entry(hash, entry, search_, @ptrCast(key.ptr), length);
}

pub fn remove(hash: ?*core.lexbor_hash_t, search_: ?*const core.lexbor_hash_search_t, key: []const u8, length: usize) void {
    core.lexbor_hash_remove(hash, search_, @ptrCast(key.ptr), length);
}

pub fn search(hash: ?*core.lexbor_hash_t, search_: ?*const core.lexbor_hash_search_t, key: []const u8, length: usize) ?*anyopaque {
    return core.lexbor_hash_search(hash, search_, @ptrCast(key.ptr), length);
}

pub fn removeByHashId(hash: ?*core.lexbor_hash_t, hash_id: u32, key: []const u8, length: usize, cmp_func: core.lexbor_hash_cmp_f) void {
    core.lexbor_hash_remove_by_hash_id(hash, hash_id, @ptrCast(key.ptr), length, cmp_func);
}

pub fn searchByHashId(hash: ?*core.lexbor_hash_t, hash_id: u32, key: []const u8, length: usize, cmp_func: core.lexbor_hash_cmp_f) ?*anyopaque {
    return core.lexbor_hash_search_by_hash_id(hash, hash_id, @ptrCast(key.ptr), length, cmp_func);
}

pub fn makeId(key: []const u8, length: usize) u32 {
    return core.lexbor_hash_make_id(@ptrCast(key.ptr), length);
}

pub fn makeIdLower(key: []const u8, length: usize) u32 {
    return core.lexbor_hash_make_id_lower(@ptrCast(key.ptr), length);
}

pub fn makeIdUpper(key: []const u8, length: usize) u32 {
    return core.lexbor_hash_make_id_upper(@ptrCast(key.ptr), length);
}

pub fn copy(hash: ?*core.lexbor_hash_t, entry: ?*core.lexbor_hash_entry_t, key: []const u8, length: usize) core.lexbor_status_t {
    const status = core.lexbor_hash_copy(hash, entry, @ptrCast(key.ptr), length);
    return @enumFromInt(status);
}

pub fn copyLower(hash: ?*core.lexbor_hash_t, entry: ?*core.lexbor_hash_entry_t, key: []const u8, length: usize) core.lexbor_status_t {
    const status = core.lexbor_hash_copy_lower(hash, entry, @ptrCast(key.ptr), length);
    return @enumFromInt(status);
}

pub fn copyUpper(hash: ?*core.lexbor_hash_t, entry: ?*core.lexbor_hash_entry_t, key: []const u8, length: usize) core.lexbor_status_t {
    const status = core.lexbor_hash_copy_upper(hash, entry, @ptrCast(key.ptr), length);
    return @enumFromInt(status);
}

pub inline fn mraw(hash: ?*core.lexbor_hash_t) ?*core.lexbor_mraw_t {
    return core.lexbor_hash_mraw(hash);
}

pub inline fn entryStr(entry: ?*core.lexbor_hash_entry_t) ?[]u8 {
    const str = core.lexbor_hash_entry_str(entry) orelse return null;
    return span(str);
}

pub inline fn entryStrSet(entry: ?*core.lexbor_hash_entry_t, data: []const u8, length: usize) ?[]u8 {
    const str = core.lexbor_hash_entry_str_set(entry, @ptrCast(data.ptr), length) orelse return null;
    return span(str);
}

pub inline fn entryStrFree(hash: ?*core.lexbor_hash_t, entry: ?*core.lexbor_hash_entry_t) void {
    core.lexbor_hash_entry_str_free(hash, entry);
}

pub inline fn entryCreate(hash: ?*core.lexbor_hash_t) ?*core.lexbor_hash_entry_t {
    return core.lexbor_hash_entry_create(hash);
}

pub inline fn entryDestroy(hash: ?*core.lexbor_hash_t, entry: ?*core.lexbor_hash_entry_t) ?*core.lexbor_hash_entry_t {
    return core.lexbor_hash_entry_destroy(hash, entry);
}

pub inline fn entriesCount(hash: ?*core.lexbor_hash_t) usize {
    return core.lexbor_hash_entries_count(hash);
}
