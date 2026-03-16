const std = @import("std");

// libc

pub extern fn memset(dest: ?*anyopaque, c: c_int, count: usize) ?*anyopaque;
pub extern fn memcpy(dest: ?*anyopaque, src: ?*const anyopaque, count: usize) ?*anyopaque;

// core/array.h

pub const lexbor_array_t = extern struct {
    list: ?[*]?*anyopaque,
    size: usize,
    length: usize,
};

pub extern fn lexbor_array_create() ?*lexbor_array_t;
pub extern fn lexbor_array_init(array: ?*lexbor_array_t, size: usize) lxb_status_t;
pub extern fn lexbor_array_clean(array: ?*lexbor_array_t) void;
pub extern fn lexbor_array_destroy(array: ?*lexbor_array_t, self_destroy: bool) ?*lexbor_array_t;
pub extern fn lexbor_array_expand(array: ?*lexbor_array_t, up_to: usize) ?*?*anyopaque;
pub extern fn lexbor_array_push(array: ?*lexbor_array_t, value: ?*anyopaque) lxb_status_t;
pub extern fn lexbor_array_pop(array: ?*lexbor_array_t) ?*anyopaque;
pub extern fn lexbor_array_insert(array: ?*lexbor_array_t, idx: usize, value: ?*anyopaque) lxb_status_t;
pub extern fn lexbor_array_set(array: ?*lexbor_array_t, idx: usize, value: ?*anyopaque) lxb_status_t;
pub extern fn lexbor_array_delete(array: ?*lexbor_array_t, begin: usize, length: usize) void;

pub inline fn lexbor_array_get(array: ?*lexbor_array_t, idx: usize) ?*anyopaque {
    if (idx >= array.?.length) {
        return null;
    }
    return array.?.list.?[idx];
}

pub inline fn lexbor_array_length(array: ?*lexbor_array_t) usize {
    return array.?.length;
}

pub inline fn lexbor_array_size(array: ?*lexbor_array_t) usize {
    return array.?.size;
}

pub extern fn lexbor_array_get_noi(array: ?*lexbor_array_t, idx: usize) ?*anyopaque;
pub extern fn lexbor_array_length_noi(array: ?*lexbor_array_t) usize;
pub extern fn lexbor_array_size_noi(array: ?*lexbor_array_t) usize;

// core/array_obj.h

pub const lexbor_array_obj_t = extern struct {
    list: ?[*]u8,
    size: usize,
    length: usize,
    struct_size: usize,
};

pub extern fn lexbor_array_obj_create() ?*lexbor_array_obj_t;
pub extern fn lexbor_array_obj_init(array: ?*lexbor_array_obj_t, size: usize, struct_size: usize) lxb_status_t;
pub extern fn lexbor_array_obj_clean(array: ?*lexbor_array_obj_t) void;
pub extern fn lexbor_array_obj_destroy(array: ?*lexbor_array_obj_t, self_destroy: bool) ?*lexbor_array_obj_t;
pub extern fn lexbor_array_obj_expand(array: ?*lexbor_array_obj_t, up_to: usize) ?*u8;
pub extern fn lexbor_array_obj_push(array: ?*lexbor_array_obj_t) ?*anyopaque;
pub extern fn lexbor_array_obj_push_wo_cls(array: ?*lexbor_array_obj_t) ?*anyopaque;
pub extern fn lexbor_array_obj_push_n(array: ?*lexbor_array_obj_t, count: usize) ?*anyopaque;
pub extern fn lexbor_array_obj_pop(array: ?*lexbor_array_obj_t) ?*anyopaque;
pub extern fn lexbor_array_obj_delete(array: ?*lexbor_array_obj_t, begin: usize, length: usize) void;

pub inline fn lexbor_array_obj_erase(array: ?*lexbor_array_obj_t) void {
    _ = memset(array.?, 0, @sizeOf(lexbor_array_obj_t));
}

pub inline fn lexbor_array_obj_get(array: ?*lexbor_array_obj_t, idx: usize) ?*anyopaque {
    if (idx >= array.?.length) {
        return null;
    }
    return array.?.list.? + (idx * array.?.struct_size);
}

pub inline fn lexbor_array_obj_length(array: ?*lexbor_array_obj_t) usize {
    return array.?.length;
}

pub inline fn lexbor_array_obj_size(array: ?*lexbor_array_obj_t) usize {
    return array.?.size;
}

pub inline fn lexbor_array_obj_struct_size(array: ?*lexbor_array_obj_t) usize {
    return array.?.struct_size;
}

pub inline fn lexbor_array_obj_last(array: ?*lexbor_array_obj_t) ?*anyopaque {
    if (array.?.length == 0) {
        return null;
    }
    return array.?.list + ((array.?.length - 1) * array.?.struct_size);
}

pub extern fn lexbor_array_obj_erase_noi(array: ?*lexbor_array_obj_t) void;
pub extern fn lexbor_array_obj_get_noi(array: ?*lexbor_array_obj_t, idx: usize) ?*anyopaque;
pub extern fn lexbor_array_obj_length_noi(array: ?*lexbor_array_obj_t) usize;
pub extern fn lexbor_array_obj_size_noi(array: ?*lexbor_array_obj_t) usize;
pub extern fn lexbor_array_obj_struct_size_noi(array: ?*lexbor_array_obj_t) usize;
pub extern fn lexbor_array_obj_last_noi(array: ?*lexbor_array_obj_t) ?*anyopaque;

// core/avl.h

pub const lexbor_avl_t = lexbor_avl;
pub const lexbor_avl_node_t = lexbor_avl_node;

pub const lexbor_avl_node_f = ?*const fn (avl: ?*lexbor_avl_t, root: ?*?*lexbor_avl_node_t, node: ?*lexbor_avl_node_t, ctx: ?*anyopaque) callconv(.C) lxb_status_t;

pub const lexbor_avl_node = extern struct {
    type: usize,
    height: c_short,
    value: ?*anyopaque,
    left: ?*lexbor_avl_node_t,
    right: ?*lexbor_avl_node_t,
    parent: ?*lexbor_avl_node_t,
};

pub const lexbor_avl = extern struct {
    nodes: ?*lexbor_dobject_t,
    last_right: ?*lexbor_avl_node_t,
};

pub extern fn lexbor_avl_create() ?*lexbor_avl_t;
pub extern fn lexbor_avl_init(avl: ?*lexbor_avl_t, chunk_len: usize, struct_size: usize) lxb_status_t;
pub extern fn lexbor_avl_clean(avl: ?*lexbor_avl_t) void;
pub extern fn lexbor_avl_destroy(avl: ?*lexbor_avl_t, struct_destroy: bool) ?*lexbor_avl_t;
pub extern fn lexbor_avl_node_make(avl: ?*lexbor_avl_t, type: usize, value: ?*anyopaque) ?*lexbor_avl_node_t;
pub extern fn lexbor_avl_node_clean(node: ?*lexbor_avl_node_t) void;
pub extern fn lexbor_avl_node_destroy(avl: ?*lexbor_avl_t, node: ?*lexbor_avl_node_t, self_destroy: bool) ?*lexbor_avl_node_t;
pub extern fn lexbor_avl_insert(avl: ?*lexbor_avl_t, scope: ?*?*lexbor_avl_node_t, type: usize, value: ?*anyopaque) ?*lexbor_avl_node_t;
pub extern fn lexbor_avl_search(avl: ?*lexbor_avl_t, scope: ?*lexbor_avl_node_t, type: usize) ?*lexbor_avl_node_t;
pub extern fn lexbor_avl_remove(avl: ?*lexbor_avl_t, scope: ?*?*lexbor_avl_node_t, type: usize) ?*anyopaque;
pub extern fn lexbor_avl_remove_by_node(avl: ?*lexbor_avl_t, root: ?*?*lexbor_avl_node_t, node: ?*lexbor_avl_node_t) void;
pub extern fn lexbor_avl_foreach(avl: ?*lexbor_avl_t, scope: ?*?*lexbor_avl_node_t, cb: lexbor_avl_node_f, ctx: ?*anyopaque) lxb_status_t;
pub extern fn lexbor_avl_foreach_recursion(avl: ?*lexbor_avl_t, scope: ?*lexbor_avl_node_t, callback: lexbor_avl_node_f, ctx: ?*anyopaque) void;

// core/base.h

pub const LEXBOR_VERSION_MAJOR = 1;
pub const LEXBOR_VERSION_MINOR = 8;
pub const LEXBOR_VERSION_PATCH = 0;
pub const LEXBOR_VERSION_STRING = "1.8.0";

// TODO: #define lexbor_assert(val)

pub inline fn lexbor_max(val1: anytype, val2: @TypeOf(val1)) @TypeOf(val1) {
    if (val1 > val2) return val1;
    return val2;
}

pub inline fn lexbor_min(val1: anytype, val2: @TypeOf(val1)) @TypeOf(val1) {
    if (val1 < val2) return val1;
    return val2;
}

pub const lexbor_status_t = enum(c_int) {
    ok = 0x0000,
    @"error" = 0x0001,
    error_memory_allocation,
    error_object_is_null,
    error_small_buffer,
    error_incomplete_object,
    error_no_free_slot,
    error_too_small_size,
    error_not_exists,
    error_wrong_args,
    error_wrong_stage,
    error_unexpected_result,
    error_unexpected_data,
    error_overflow,
    @"continue",
    small_buffer,
    aborted,
    stopped,
    next,
    stop,
    warning,
};

pub const lexbor_action_t = enum(c_int) {
    ok = 0x00,
    stop = 0x01,
    next = 0x02,
};

pub const lexbor_serialize_cb_f = ?*const fn (data: ?*const lxb_char_t, len: usize, ctx: ?*anyopaque) callconv(.C) lxb_status_t;
pub const lexbor_serialize_cb_cp_f = ?*const fn (cps: ?*const lxb_codepoint_t, len: usize, ctx: ?*anyopaque) callconv(.C) lxb_status_t;

pub const lexbor_serialize_ctx_t = extern struct {
    c: lexbor_serialize_cb_f,
    ctx: ?*anyopaque,
    opt: isize,
    count: usize,
};

// core/bst.h

pub inline fn lexbor_bst_root(bst: ?*lexbor_bst_t) ?*lexbor_bst_entry_t {
    return bst.?.root;
}

pub inline fn lexbor_bst_root_ref(bst: ?*lexbor_bst_t) ?*?*lexbor_bst_entry_t {
    return &(bst.?.root);
}

pub const lexbor_bst_entry_t = lexbor_bst_entry;
pub const lexbor_bst_t = lexbor_bst;

pub const lexbor_bst_entry_f = ?*const fn (bst: ?*lexbor_bst_t, entry: ?*lexbor_bst_entry_t, ctx: ?*anyopaque) callconv(.C) bool;

pub const lexbor_bst_entry = extern struct {
    value: ?*anyopaque,
    right: ?*lexbor_bst_entry_t,
    left: ?*lexbor_bst_entry_t,
    next: ?*lexbor_bst_entry_t,
    parent: ?*lexbor_bst_entry_t,
    size: usize,
};

pub const lexbor_bst = extern struct {
    dobject: ?*lexbor_dobject_t,
    root: ?*lexbor_bst_entry_t,
    tree_length: usize,
};

pub extern fn lexbor_bst_create() ?*lexbor_bst_t;
pub extern fn lexbor_bst_init(bst: ?*lexbor_bst_t, size: usize) lxb_status_t;
pub extern fn lexbor_bst_clean(bst: ?*lexbor_bst_t) void;
pub extern fn lexbor_bst_destroy(bst: ?*lexbor_bst_t, self_destroy: bool) ?*lexbor_bst_t;
pub extern fn lexbor_bst_entry_make(bst: ?*lexbor_bst_t, size: usize) ?*lexbor_bst_entry_t;
pub extern fn lexbor_bst_insert(bst: ?*lexbor_bst_t, scope: ?*?*lexbor_bst_entry_t, size: usize, value: ?*anyopaque) ?*lexbor_bst_entry_t;
pub extern fn lexbor_bst_insert_not_exists(bst: ?*lexbor_bst_t, scope: ?*?*lexbor_bst_entry_t, size: usize) ?*lexbor_bst_entry_t;
pub extern fn lexbor_bst_search(bst: ?*lexbor_bst_t, scope: ?*lexbor_bst_entry_t, size: usize) ?*lexbor_bst_entry_t;
pub extern fn lexbor_bst_search_close(bst: ?*lexbor_bst_t, scope: ?*lexbor_bst_entry_t, size: usize) ?*lexbor_bst_entry_t;
pub extern fn lexbor_bst_remove(bst: ?*lexbor_bst_t, root: ?*?*lexbor_bst_entry_t, size: usize) ?*anyopaque;
pub extern fn lexbor_bst_remove_close(bst: ?*lexbor_bst_t, root: ?*?*lexbor_bst_entry_t, size: usize, found_size: ?*usize) ?*anyopaque;
pub extern fn lexbor_bst_remove_by_pointer(bst: ?*lexbor_bst_t, entry: ?*lexbor_bst_entry_t, root: ?*?*lexbor_bst_entry_t) ?*anyopaque;
pub extern fn lexbor_bst_serialize(bst: ?*lexbor_bst_t, callback: lexbor_callback_f, ctx: ?*anyopaque) void;
pub extern fn lexbor_bst_serialize_entry(entry: ?*lexbor_bst_entry_t, callback: lexbor_callback_f, ctx: ?*anyopaque, tabs: usize) void;

// core/bst_map.h

pub const lexbor_bst_map_entry_t = extern struct {
    str: lexbor_str_t,
    value: ?*anyopaque,
};

pub const lexbor_bst_map_t = extern struct {
    bst: ?*lexbor_bst_t,
    mraw: ?*lexbor_mraw_t,
    entries: ?*lexbor_dobject_t,
};

pub extern fn lexbor_bst_map_create() ?*lexbor_bst_map_t;
pub extern fn lexbor_bst_map_init(bst_map: ?*lexbor_bst_map_t, size: usize) lxb_status_t;
pub extern fn lexbor_bst_map_clean(bst_map: ?*lexbor_bst_map_t) void;
pub extern fn lexbor_bst_map_destroy(bst_map: ?*lexbor_bst_map_t, self_destroy: bool) ?*lexbor_bst_map_t;
pub extern fn lexbor_bst_map_search(bst_map: ?*lexbor_bst_map_t, scope: ?*lexbor_bst_entry_t, key: ?*const lxb_char_t, key_len: usize) ?*lexbor_bst_map_entry_t;
pub extern fn lexbor_bst_map_insert(bst_map: ?*lexbor_bst_map_t, scope: ?*?*lexbor_bst_entry_t, key: ?*const lxb_char_t, key_len: usize, value: ?*anyopaque) ?*lexbor_bst_map_entry_t;
pub extern fn lexbor_bst_map_insert_not_exists(bst_map: ?*lexbor_bst_map_t, scope: ?*?*lexbor_bst_entry_t, key: ?*const lxb_char_t, key_len: usize) ?*lexbor_bst_map_entry_t;
pub extern fn lexbor_bst_map_remove(bst_map: ?*lexbor_bst_map_t, scope: ?*?*lexbor_bst_entry_t, key: ?*const lxb_char_t, key_len: usize) ?*anyopaque;

pub inline fn lexbor_bst_map_mraw(bst_map: ?*lexbor_bst_map_t) ?*lexbor_mraw_t {
    return bst_map.?.mraw;
}

pub extern fn lexbor_bst_map_mraw_noi(bst_map: ?*lexbor_bst_map_t) ?*lexbor_mraw_t;

// core/conv.h

pub extern fn lexbor_conv_float_to_data(num: f64, buf: ?*lxb_char_t, len: usize) usize;
pub extern fn lexbor_conv_long_to_data(num: c_long, buf: ?*lxb_char_t, len: usize) usize;
pub extern fn lexbor_conv_int64_to_data(num: i64, buf: ?*lxb_char_t, len: usize) usize;
pub extern fn lexbor_conv_data_to_double(start: ?*const ?*lxb_char_t, len: usize) f64;
pub extern fn lexbor_conv_data_to_ulong(data: ?*const ?*lxb_char_t, length: usize) c_ulong;
pub extern fn lexbor_conv_data_to_long(data: ?*const ?*lxb_char_t, length: usize) c_long;
pub extern fn lexbor_conv_data_to_uint(data: ?*const ?*lxb_char_t, length: usize) c_uint;
pub extern fn lexbor_conv_dec_to_hex(number: u32, out: ?*lxb_char_t, length: usize) usize;

pub inline fn lexbor_conv_double_to_long(number: f64) c_long {
    if (number > std.math.maxInt(c_long)) {
        return std.math.maxInt(c_long);
    }
    if (number < std.math.minInt(c_long)) {
        return -std.math.maxInt(c_long);
    }
    return @trunc(number);
}

// core/def.h

pub const LEXBOR_MEM_ALIGN_STEP = @sizeOf(*anyopaque);

// core/diyfp.h

// TODO: #define lexbor_diyfp(_s, _e)           (lexbor_diyfp_t)

pub inline fn lexbor_uint64_hl(h: anytype, l: anytype) u64 {
    return @intCast((h << 32) + l);
}

pub const LEXBOR_DBL_SIGNIFICAND_SIZE = 52;
pub const LEXBOR_DBL_EXPONENT_BIAS = 0x3FF + LEXBOR_DBL_SIGNIFICAND_SIZE;
pub const LEXBOR_DBL_EXPONENT_MIN = -LEXBOR_DBL_EXPONENT_BIAS;
pub const LEXBOR_DBL_EXPONENT_MAX = 0x7FF - LEXBOR_DBL_EXPONENT_BIAS;
pub const LEXBOR_DBL_EXPONENT_DENORMAL = -LEXBOR_DBL_EXPONENT_BIAS + 1;

pub const LEXBOR_DBL_SIGNIFICAND_MASK = lexbor_uint64_hl(0x000FFFFF, 0xFFFFFFFF);
pub const LEXBOR_DBL_HIDDEN_BIT = lexbor_uint64_hl(0x00100000, 0x00000000);
pub const LEXBOR_DBL_EXPONENT_MASK = lexbor_uint64_hl(0x7FF00000, 0x00000000);

pub const LEXBOR_DIYFP_SIGNIFICAND_SIZE = 64;

pub const LEXBOR_SIGNIFICAND_SIZE = 53;
pub const LEXBOR_SIGNIFICAND_SHIFT = LEXBOR_DIYFP_SIGNIFICAND_SIZE - LEXBOR_DBL_SIGNIFICAND_SIZE;

pub const LEXBOR_DECIMAL_EXPONENT_OFF = 348;
pub const LEXBOR_DECIMAL_EXPONENT_MIN = -348;
pub const LEXBOR_DECIMAL_EXPONENT_MAX = 340;
pub const LEXBOR_DECIMAL_EXPONENT_DIST = 8;

pub const lexbor_diyfp_t = extern struct {
    significand: u64,
    exp: c_int,
};

pub extern fn lexbor_cached_power_dec(exp: c_int, dec_exp: ?*c_int) lexbor_diyfp_t;
pub extern fn lexbor_cached_power_bin(exp: c_int, dec_exp: ?*c_int) lexbor_diyfp_t;

pub inline fn lexbor_diyfp_leading_zeros64(x: u64) u64 {
    var n: u64 = undefined;

    if (x == 0) {
        return 64;
    }

    n = 0;

    while ((x & 0x8000000000000000) == 0) {
        n += 1;
        x <<= 1;
    }
    return n;
}

pub inline fn lexbor_diyfp_from_d2(d: u64) lexbor_diyfp_t {
    var biased_exp: c_int = undefined;
    var significand: u64 = undefined;
    var r: lexbor_diyfp_t = undefined;

    const U = extern union {
        d: f64,
        u64_: u64,
    };
    var u = U{};

    u.d = d;

    biased_exp = (u.u64_ & LEXBOR_DBL_EXPONENT_MASK) >> LEXBOR_DBL_SIGNIFICAND_SIZE;
    significand = u.u64_ & LEXBOR_DBL_SIGNIFICAND_MASK;

    if (biased_exp != 0) {
        r.significand = significand + LEXBOR_DBL_HIDDEN_BIT;
        r.exp = biased_exp - LEXBOR_DBL_EXPONENT_BIAS;
    } else {
        r.significand = significand;
        r.exp = LEXBOR_DBL_EXPONENT_MIN + 1;
    }

    return r;
}

pub inline fn lexbor_diyfp_2d(v: lexbor_diyfp_t) f64 {
    var exp: c_int = undefined;
    var significand: u64 = undefined;
    var biased_exp: u64 = undefined;

    const U = extern union {
        d: f64,
        u64_: u64,
    };
    var u = U{};

    exp = v.exp;
    significand = v.significand;

    while (significand > LEXBOR_DBL_HIDDEN_BIT + LEXBOR_DBL_SIGNIFICAND_MASK) {
        significand >>= 1;
        exp += 1;
    }

    if (exp >= LEXBOR_DBL_EXPONENT_MAX) {
        return std.math.inf(f64);
    }

    if (exp < LEXBOR_DBL_EXPONENT_DENORMAL) {
        return 0.0;
    }

    while (exp > LEXBOR_DBL_EXPONENT_DENORMAL and (significand & LEXBOR_DBL_HIDDEN_BIT) == 0) {
        significand <<= 1;
        exp -= 1;
    }

    if (exp == LEXBOR_DBL_EXPONENT_DENORMAL and (significand & LEXBOR_DBL_HIDDEN_BIT) == 0) {
        biased_exp = 0;
    } else {
        biased_exp = @intCast(exp + LEXBOR_DBL_EXPONENT_BIAS);
    }

    u.u64_ = (significand & LEXBOR_DBL_SIGNIFICAND_MASK) | (biased_exp << LEXBOR_DBL_SIGNIFICAND_SIZE);

    return u.d;
}

pub inline fn lexbor_diyfp_shift_left(v: lexbor_diyfp_t, shift: c_uint) lexbor_diyfp_t {
    return lexbor_diyfp_t{ .significand = v.significand << shift, .exp = v.exp - shift };
}

pub inline fn lexbor_diyfp_shift_right(v: lexbor_diyfp_t, shift: c_uint) lexbor_diyfp_t {
    return lexbor_diyfp_t{ .significand = v.significand >> shift, .exp = v.exp + shift };
}

pub inline fn lexbor_diyfp_sub(lhs: lexbor_diyfp_t, rhs: lexbor_diyfp_t) lexbor_diyfp_t {
    return lexbor_diyfp_t{ .significand = lhs.significand - rhs.significand, .exp = lhs.exp };
}

pub inline fn lexbor_diyfp_mul(lhs: lexbor_diyfp_t, rhs: lexbor_diyfp_t) lexbor_diyfp_t {
    const a: u64 = lhs.significand >> 32;
    const b: u64 = lhs.significand & 0xffffffff;
    const c: u64 = rhs.significand >> 32;
    const d: u64 = rhs.significand & 0xffffffff;

    const ac: u64 = a * c;
    const bc: u64 = b * c;
    const ad: u64 = a * d;
    const bd: u64 = b * d;

    var tmp: u64 = (bd >> 32) + (ad & 0xffffffff) + (bc & 0xffffffff);

    tmp += @as(c_uint, 1) << 31;

    return lexbor_diyfp_t{ .significand = ac + (ad >> 32) + (bc >> 32) + (tmp >> 32), .exp = lhs.exp + rhs.exp + 64 };
}

pub inline fn lexbor_diyfp_normalize(v: lexbor_diyfp_t) lexbor_diyfp_t {
    return lexbor_diyfp_shift_left(v, lexbor_diyfp_leading_zeros64(v.significand));
}

// core/dobject.h

pub const lexbor_dobject_t = extern struct {
    mem: ?*lexbor_mem_t,
    cache: ?*lexbor_array_t,
    allocated: usize,
    struct_size: usize,
};

pub extern fn lexbor_dobject_create() ?*lexbor_dobject_t;
pub extern fn lexbor_dobject_init(dobject: ?*lexbor_dobject_t, chunk_size: usize, struct_size: usize) lxb_status_t;
pub extern fn lexbor_dobject_clean(dobject: ?*lexbor_dobject_t) void;
pub extern fn lexbor_dobject_destroy(dobject: ?*lexbor_dobject_t, destroy_self: bool) ?*lexbor_dobject_t;
pub extern fn lexbor_dobject_init_list_entries(dobject: ?*lexbor_dobject_t, pos: usize) ?*u8;
pub extern fn lexbor_dobject_alloc(dobject: ?*lexbor_dobject_t) ?*anyopaque;
pub extern fn lexbor_dobject_calloc(dobject: ?*lexbor_dobject_t) ?*anyopaque;
pub extern fn lexbor_dobject_free(dobject: ?*lexbor_dobject_t, data: ?*anyopaque) ?*anyopaque;
pub extern fn lexbor_dobject_by_absolute_position(dobject: ?*lexbor_dobject_t, pos: usize) ?*anyopaque;

pub inline fn lexbor_dobject_allocated(dobject: ?*lexbor_dobject_t) usize {
    return dobject.?.allocated;
}

pub inline fn lexbor_dobject_cache_length(dobject: ?*lexbor_dobject_t) usize {
    return lexbor_array_length(dobject.?.cache);
}

pub extern fn lexbor_dobject_allocated_noi(dobject: ?*lexbor_dobject_t) usize;
pub extern fn lexbor_dobject_cache_length_noi(dobject: ?*lexbor_dobject_t) usize;

// core/dtoa.h

pub extern fn lexbor_dtoa(value: f64, begin: ?*lxb_char_t, len: usize) usize;

// core/fs.h

pub const lexbor_fs_dir_file_f = ?*const fn (fullpath: ?*const lxb_char_t, fullpath_len: usize, filename: ?*const lxb_char_t, filename_len: usize, ctx: ?*anyopaque) callconv(.C) lexbor_action_t;

pub const lexbor_fs_dir_opt_t = c_int;

pub const lexbor_fs_dir_opt = enum(lexbor_fs_dir_opt_t) {
    undef = 0x00,
    without_dir = 0x01,
    without_file = 0x02,
    without_hidden = 0x04,
};

pub const lexbor_fs_file_type_t = enum(c_int) {
    undef = 0x00,
    file = 0x01,
    directory = 0x02,
    block_device = 0x03,
    character_device = 0x04,
    pipe = 0x05,
    symlink = 0x06,
    socket = 0x07,
};

pub extern fn lexbor_fs_dir_read(dirpath: ?*const lxb_char_t, opt: lexbor_fs_dir_opt, callback: lexbor_fs_dir_file_f, ctx: ?*anyopaque) lxb_status_t;
pub extern fn lexbor_fs_file_type(full_path: ?*const lxb_char_t) lexbor_fs_file_type_t;
pub extern fn lexbor_fs_file_easy_read(full_path: ?*const lxb_char_t, len: ?*usize) ?[*:0]lxb_char_t;

// core/hash.h

pub const lexbor_hash_search_t = lexbor_hash_search_;
pub const lexbor_hash_insert_t = lexbor_hash_insert_;

pub const LEXBOR_HASH_SHORT_SIZE = 16;
pub const LEXBOR_HASH_TABLE_MIN_SIZE = 32;

pub const lexbor_hash_insert_raw = @extern(**const lexbor_hash_insert_t, .{ .name = "lexbor_hash_insert_raw" });
pub const lexbor_hash_insert_lower = @extern(**const lexbor_hash_insert_t, .{ .name = "lexbor_hash_insert_lower" });
pub const lexbor_hash_insert_upper = @extern(**const lexbor_hash_insert_t, .{ .name = "lexbor_hash_insert_upper" });

pub const lexbor_hash_search_raw = @extern(**const lexbor_hash_search_t, .{ .name = "lexbor_hash_search_raw" });
pub const lexbor_hash_search_lower = @extern(**const lexbor_hash_search_t, .{ .name = "lexbor_hash_search_lower" });
pub const lexbor_hash_search_upper = @extern(**const lexbor_hash_search_t, .{ .name = "lexbor_hash_search_upper" });

pub const lexbor_hash_t = lexbor_hash;
pub const lexbor_hash_entry_t = lexbor_hash_entry;

pub const lexbor_hash_id_f = ?*const fn (key: ?*const lxb_char_t, len: usize) callconv(.C) u32;
pub const lexbor_hash_copy_f = ?*const fn (hash: ?*lexbor_hash_t, entry: ?*lexbor_hash_entry_t, key: ?*const lxb_char_t, len: usize) callconv(.C) lxb_status_t;
pub const lexbor_hash_cmp_f = ?*const fn (first: ?*const lxb_char_t, second: ?*const lxb_char_t, size: usize) callconv(.C) bool;

pub const lexbor_hash_entry = extern struct {
    u: extern union {
        long_str: ?*lxb_char_t,
        short_str: [LEXBOR_HASH_SHORT_SIZE + 1]lxb_char_t,
    },
    length: usize,
    next: ?*lexbor_hash_entry_t,
};

pub const lexbor_hash = extern struct {
    entries: ?*lexbor_dobject_t,
    mraw: ?*lexbor_mraw_t,
    table: ?*?*lexbor_hash_entry_t,
    table_size: usize,
    struct_size: usize,
};

pub const lexbor_hash_insert_ = extern struct {
    hash: lexbor_hash_id_f,
    cmp: lexbor_hash_cmp_f,
    copy: lexbor_hash_copy_f,
};

pub const lexbor_hash_search_ = extern struct {
    hash: lexbor_hash_id_f,
    cmp: lexbor_hash_cmp_f,
};

pub extern fn lexbor_hash_create() ?*lexbor_hash_t;
pub extern fn lexbor_hash_init(hash: ?*lexbor_hash_t, table_size: usize, struct_size: usize) lxb_status_t;
pub extern fn lexbor_hash_clean(hash: ?*lexbor_hash_t) void;
pub extern fn lexbor_hash_destroy(hash: ?*lexbor_hash_t, destroy_obj: bool) ?*lexbor_hash_t;
pub extern fn lexbor_hash_insert(hash: ?*lexbor_hash_t, insert: ?*const lexbor_hash_insert_t, key: ?*const lxb_char_t, length: usize) ?*anyopaque;
pub extern fn lexbor_hash_insert_by_entry(hash: ?*lexbor_hash_t, entry: ?*lexbor_hash_entry_t, search: ?*const lexbor_hash_search_t, key: ?*const lxb_char_t, length: usize) ?*anyopaque;
pub extern fn lexbor_hash_remove(hash: ?*lexbor_hash_t, search: ?*const lexbor_hash_search_t, key: ?*const lxb_char_t, length: usize) void;
pub extern fn lexbor_hash_search(hash: ?*lexbor_hash_t, search: ?*const lexbor_hash_search_t, key: ?*const lxb_char_t, length: usize) ?*anyopaque;
pub extern fn lexbor_hash_remove_by_hash_id(hash: ?*lexbor_hash_t, hash_id: u32, key: ?*const lxb_char_t, length: usize, cmp_func: lexbor_hash_cmp_f) void;
pub extern fn lexbor_hash_search_by_hash_id(hash: ?*lexbor_hash_t, hash_id: u32, key: ?*const lxb_char_t, length: usize, cmp_func: lexbor_hash_cmp_f) ?*anyopaque;
pub extern fn lexbor_hash_make_id(key: ?*const lxb_char_t, length: usize) u32;
pub extern fn lexbor_hash_make_id_lower(key: ?*const lxb_char_t, length: usize) u32;
pub extern fn lexbor_hash_make_id_upper(key: ?*const lxb_char_t, length: usize) u32;
pub extern fn lexbor_hash_copy(hash: ?*lexbor_hash_t, entry: ?*lexbor_hash_entry_t, key: ?*const lxb_char_t, length: usize) lxb_status_t;
pub extern fn lexbor_hash_copy_lower(hash: ?*lexbor_hash_t, entry: ?*lexbor_hash_entry_t, key: ?*const lxb_char_t, length: usize) lxb_status_t;
pub extern fn lexbor_hash_copy_upper(hash: ?*lexbor_hash_t, entry: ?*lexbor_hash_entry_t, key: ?*const lxb_char_t, length: usize) lxb_status_t;

pub inline fn lexbor_hash_mraw(hash: ?*lexbor_hash_t) ?*lexbor_mraw_t {
    return hash.?.mraw;
}

pub inline fn lexbor_hash_entry_str(entry: ?*lexbor_hash_entry_t) ?[*:0]lxb_char_t {
    if (entry.?.length <= LEXBOR_HASH_SHORT_SIZE) {
        return @ptrCast(&entry.?.u.short_str[0]);
    }
    return @ptrCast(entry.?.u.long_str);
}

pub inline fn lexbor_hash_entry_str_set(entry: ?*lexbor_hash_entry_t, data: ?*lxb_char_t, length: usize) ?*lxb_char_t {
    entry.?.length = length;

    if (length <= LEXBOR_HASH_SHORT_SIZE) {
        _ = memcpy(entry.?.u.short_str, data, length);
        return &entry.?.u.short_str[0];
    }

    entry.?.u.long_str = data;
    return entry.?.u.long_str;
}

pub inline fn lexbor_hash_entry_str_free(hash: ?*lexbor_hash_t, entry: ?*lexbor_hash_entry_t) void {
    if (entry.?.length > LEXBOR_HASH_SHORT_SIZE) {
        lexbor_mraw_free(hash.?.mraw, entry.?.u.long_str);
    }

    entry.?.length = 0;
}

pub inline fn lexbor_hash_entry_create(hash: ?*lexbor_hash_t) ?*lexbor_hash_entry_t {
    return @as(?*lexbor_hash_entry_t, @ptrCast(@alignCast(lexbor_dobject_calloc(hash.?.entries))));
}

pub inline fn lexbor_hash_entry_destroy(hash: ?*lexbor_hash_t, entry: ?*lexbor_hash_entry_t) ?*lexbor_hash_entry_t {
    return @as(?*lexbor_hash_entry_t, @ptrCast(@alignCast(lexbor_dobject_free(hash.?.entries, @as(?*anyopaque, @ptrCast(entry))))));
}

pub inline fn lexbor_hash_entries_count(hash: ?*lexbor_hash_t) usize {
    return lexbor_dobject_allocated(hash.?.entries);
}

// core/in.h

pub const lexbor_in_node_t = lexbor_in_node;
pub const lexbor_in_opt_t = c_int;

pub const lexbor_in_opt = enum(lexbor_in_opt_t) {
    undef = 0x00,
    readonly = 0x01,
    done = 0x02,
    fake = 0x04,
    alloc = 0x08,
};

pub const lexbor_in_t = extern struct {
    nodes: ?*lexbor_dobject_t,
};

pub const lexbor_in_node = extern struct {
    offset: usize,
    opt: lexbor_in_opt,
    begin: ?[*]const lxb_char_t,
    end: ?[*]const lxb_char_t,
    use: ?[*]const lxb_char_t,
    next: ?*lexbor_in_node_t,
    prev: ?*lexbor_in_node_t,
    incoming: ?*lexbor_in_t,
};

pub extern fn lexbor_in_create() ?*lexbor_in_t;
pub extern fn lexbor_in_init(incoming: ?*lexbor_in_t, chunk_size: usize) lxb_status_t;
pub extern fn lexbor_in_clean(incoming: ?*lexbor_in_t) void;
pub extern fn lexbor_in_destroy(incoming: ?*lexbor_in_t, self_destroy: bool) ?*lexbor_in_t;
pub extern fn lexbor_in_node_make(incoming: ?*lexbor_in_t, last_node: ?*lexbor_in_node_t, buf: ?*const lxb_char_t, buf_size: usize) ?*lexbor_in_node_t;
pub extern fn lexbor_in_node_clean(node: ?*lexbor_in_node_t) void;
pub extern fn lexbor_in_node_destroy(incoming: ?*lexbor_in_t, node: ?*lexbor_in_node_t, self_destroy: bool) ?*lexbor_in_node_t;
pub extern fn lexbor_in_node_split(node: ?*lexbor_in_node_t, pos: ?*const lxb_char_t) ?*lexbor_in_node_t;
pub extern fn lexbor_in_node_find(node: ?*lexbor_in_node_t, pos: ?*const lxb_char_t) ?*lexbor_in_node_t;
pub extern fn lexbor_in_node_pos_up(node: ?*lexbor_in_node_t, return_node: ?*?*lexbor_in_node_t, pos: ?*const lxb_char_t, offset: usize) ?*const lxb_char_t;
pub extern fn lexbor_in_node_pos_down(node: ?*lexbor_in_node_t, return_node: ?*?*lexbor_in_node_t, pos: ?*const lxb_char_t, offset: usize) ?*const lxb_char_t;

pub inline fn lexbor_in_node_begin(node: ?*const lexbor_in_node_t) ?[*]const lxb_char_t {
    return node.?.begin;
}

pub inline fn lexbor_in_node_end(node: ?*const lexbor_in_node_t) ?[*]const lxb_char_t {
    return node.?.end;
}

pub inline fn lexbor_in_node_offset(node: ?*const lexbor_in_node_t) usize {
    return node.?.offset;
}

pub inline fn lexbor_in_node_next(node: ?*const lexbor_in_node_t) ?*lexbor_in_node_t {
    return node.?.next;
}

pub inline fn lexbor_in_node_prev(node: ?*const lexbor_in_node_t) ?*lexbor_in_node_t {
    return node.?.prev;
}

pub inline fn lexbor_in_node_in(node: ?*const lexbor_in_node_t) ?*lexbor_in_t {
    return node.?.incoming;
}

pub inline fn lexbor_in_segment(node: ?*const lexbor_in_node_t, data: ?*const lxb_char_t) bool {
    return @intFromPtr(&node.?.begin.?[0]) <= @intFromPtr(&data[0]) and @intFromPtr(&node.?.end.?[0]) >= @intFromPtr(&data[0]);
}

pub extern fn lexbor_in_node_begin_noi(node: ?*const lexbor_in_node_t) ?*const lxb_char_t;
pub extern fn lexbor_in_node_end_noi(node: ?*const lexbor_in_node_t) ?*const lxb_char_t;
pub extern fn lexbor_in_node_offset_noi(node: ?*const lexbor_in_node_t) usize;
pub extern fn lexbor_in_node_next_noi(node: ?*const lexbor_in_node_t) ?*lexbor_in_node_t;
pub extern fn lexbor_in_node_prev_noi(node: ?*const lexbor_in_node_t) ?*lexbor_in_node_t;
pub extern fn lexbor_in_node_in_noi(node: ?*const lexbor_in_node_t) ?*lexbor_in_t;
pub extern fn lexbor_in_segment_noi(node: ?*const lexbor_in_node_t, data: ?*const lxb_char_t) bool;

// core/lexbor.h

pub const lexbor_memory_malloc_f = ?*const fn (size: usize) callconv(.C) ?*anyopaque;
pub const lexbor_memory_realloc_f = ?*const fn (dst: ?*anyopaque, size: usize) callconv(.C) ?*anyopaque;
pub const lexbor_memory_calloc_f = ?*const fn (num: usize, size: usize) callconv(.C) ?*anyopaque;
pub const lexbor_memory_free_f = ?*const fn (dst: ?*anyopaque) callconv(.C) void;

pub extern fn lexbor_malloc(size: usize) ?*anyopaque;
pub extern fn lexbor_realloc(dst: ?*anyopaque, size: usize) ?*anyopaque;
pub extern fn lexbor_calloc(num: usize, size: usize) ?*anyopaque;
pub extern fn lexbor_free(dst: ?*anyopaque) void;
pub extern fn lexbor_memory_setup(new_malloc: lexbor_memory_malloc_f, new_realloc: lexbor_memory_realloc_f, new_calloc: lexbor_memory_calloc_f, new_free: lexbor_memory_free_f) void;

// core/mem.h

pub const lexbor_mem_chunk_t = extern struct {
    data: ?*u8,
    length: usize,
    size: usize,
    next: ?*lexbor_mem_chunk_t,
    prev: ?*lexbor_mem_chunk_t,
};

pub const lexbor_mem_t = extern struct {
    chunk: ?*lexbor_mem_chunk_t,
    chunk_first: ?*lexbor_mem_chunk_t,
    chunk_min_size: usize,
    chunk_length: usize,
};

pub extern fn lexbor_mem_create() ?*lexbor_mem_t;
pub extern fn lexbor_mem_init(mem: ?*lexbor_mem_t, min_chunk_size: usize) lxb_status_t;
pub extern fn lexbor_mem_clean(mem: ?*lexbor_mem_t) void;
pub extern fn lexbor_mem_destroy(mem: ?*lexbor_mem_t, destroy_self: bool) ?*lexbor_mem_t;
pub extern fn lexbor_mem_chunk_init(mem: ?*lexbor_mem_t, chunk: ?*lexbor_mem_chunk_t, length: usize) ?*u8;
pub extern fn lexbor_mem_chunk_make(mem: ?*lexbor_mem_t, length: usize) ?*lexbor_mem_chunk_t;
pub extern fn lexbor_mem_chunk_destroy(mem: ?*lexbor_mem_t, chunk: ?*lexbor_mem_chunk_t, self_destroy: bool) ?*lexbor_mem_chunk_t;
pub extern fn lexbor_mem_alloc(mem: ?*lexbor_mem_t, length: usize) ?*anyopaque;
pub extern fn lexbor_mem_calloc(mem: ?*lexbor_mem_t, length: usize) ?*anyopaque;
pub extern fn lexbor_mem_current_length_noi(mem: ?*lexbor_mem_t) usize;
pub extern fn lexbor_mem_current_size_noi(mem: ?*lexbor_mem_t) usize;
pub extern fn lexbor_mem_chunk_length_noi(mem: ?*lexbor_mem_t) usize;
pub extern fn lexbor_mem_align_noi(size: usize) usize;
pub extern fn lexbor_mem_align_floor_noi(size: usize) usize;

pub inline fn lexbor_mem_current_length(mem: ?*lexbor_mem_t) usize {
    return mem.?.chunk.?.length;
}

pub inline fn lexbor_mem_current_size(mem: ?*lexbor_mem_t) usize {
    return mem.?.chunk.?.size;
}

pub inline fn lexbor_mem_chunk_length(mem: ?*lexbor_mem_t) usize {
    return mem.?.chunk_length;
}

pub inline fn lexbor_mem_align(size: usize) usize {
    return if ((size % LEXBOR_MEM_ALIGN_STEP) != 0) size + (LEXBOR_MEM_ALIGN_STEP - (size % LEXBOR_MEM_ALIGN_STEP)) else size;
}

pub inline fn lexbor_mem_align_floor(size: usize) usize {
    return if ((size % LEXBOR_MEM_ALIGN_STEP) != 0) size - (size % LEXBOR_MEM_ALIGN_STEP) else size;
}

// core/mraw.h

pub const lexbor_mraw_meta_size =
    if ((@sizeOf(usize) % LEXBOR_MEM_ALIGN_STEP) != 0)
        @sizeOf(usize) + (LEXBOR_MEM_ALIGN_STEP - (@sizeOf(usize) % LEXBOR_MEM_ALIGN_STEP))
    else
        @sizeOf(usize);

pub const lexbor_mraw_t = extern struct {
    mem: ?*lexbor_mem_t,
    cache: ?*lexbor_bst_t,
    ref_count: usize,
};

pub extern fn lexbor_mraw_create() ?*lexbor_mraw_t;
pub extern fn lexbor_mraw_init(mraw: ?*lexbor_mraw_t, chunk_size: usize) lxb_status_t;
pub extern fn lexbor_mraw_clean(mraw: ?*lexbor_mraw_t) void;
pub extern fn lexbor_mraw_destroy(mraw: ?*lexbor_mraw_t, destroy_self: bool) ?*lexbor_mraw_t;
pub extern fn lexbor_mraw_alloc(mraw: ?*lexbor_mraw_t, size: usize) ?*anyopaque;
pub extern fn lexbor_mraw_calloc(mraw: ?*lexbor_mraw_t, size: usize) ?*anyopaque;
pub extern fn lexbor_mraw_realloc(mraw: ?*lexbor_mraw_t, data: ?*anyopaque, new_size: usize) ?*anyopaque;
pub extern fn lexbor_mraw_free(mraw: ?*lexbor_mraw_t, data: ?*anyopaque) ?*anyopaque;
pub extern fn lexbor_mraw_data_size_noi(data: ?*anyopaque) usize;
pub extern fn lexbor_mraw_data_size_set_noi(data: ?*anyopaque, size: usize) void;
pub extern fn lexbor_mraw_dup_noi(mraw: ?*lexbor_mraw_t, src: ?*const anyopaque, size: usize) ?*anyopaque;

pub inline fn lexbor_mraw_data_size(data: ?*anyopaque) usize {
    return @as(*usize, @ptrFromInt(@intFromPtr(@as(*u8, @ptrCast(data.?))) - lexbor_mraw_meta_size)).*;
}

pub inline fn lexbor_mraw_data_size_set(data: ?*anyopaque, size: usize) void {
    const dest: ?*anyopaque = @ptrFromInt(@intFromPtr(@as(*u8, @ptrCast(data.?))) - lexbor_mraw_meta_size);
    // _ = memcpy(dest, @ptrCast(@constCast(&size)), @sizeOf(usize));
    _ = memcpy(dest, @constCast(&size), @sizeOf(usize));
}

pub inline fn lexbor_mraw_dup(mraw: ?*lexbor_mraw_t, src: ?*const anyopaque, size: usize) ?*anyopaque {
    const data = lexbor_mraw_alloc(mraw, size);
    if (data) |d| {
        memcpy(d, src, size);
    }
    return data;
}

pub inline fn lexbor_mraw_reference_count(mraw: ?*lexbor_mraw_t) usize {
    return mraw.?.ref_count;
}

// core/perf.h

pub extern fn lexbor_perf_create() ?*anyopaque;
pub extern fn lexbor_perf_clean(perf: ?*anyopaque) void;
pub extern fn lexbor_perf_destroy(perf: ?*anyopaque) void;
pub extern fn lexbor_perf_begin(perf: ?*anyopaque) lxb_status_t;
pub extern fn lexbor_perf_end(perf: ?*anyopaque) lxb_status_t;
pub extern fn lexbor_perf_in_sec(perf: ?*anyopaque) f64;

// core/plog.h

pub const lexbor_plog_entry_t = extern struct {
    data: ?[*]lxb_char_t,
    context: ?*anyopaque,
    id: c_uint,
};

pub const lexbor_plog_t = extern struct {
    list: lexbor_array_obj_t,
};

pub extern fn lexbor_plog_init(plog: ?*lexbor_plog_t, init_size: usize, struct_size: usize) lxb_status_t;
pub extern fn lexbor_plog_destroy(plog: ?*lexbor_plog_t, self_destroy: bool) ?*lexbor_plog_t;
pub extern fn lexbor_plog_create_noi() ?*lexbor_plog_t;
pub extern fn lexbor_plog_clean_noi(plog: ?*lexbor_plog_t) void;
pub extern fn lexbor_plog_push_noi(plog: ?*lexbor_plog_t, data: ?*const lxb_char_t, ctx: ?*anyopaque, id: c_uint) ?*anyopaque;
pub extern fn lexbor_plog_length_noi(plog: ?*lexbor_plog_t) usize;

pub inline fn lexbor_plog_create() ?*lexbor_plog_t {
    return @as(?*lexbor_plog_t, @ptrCast(@alignCast(lexbor_calloc(1, @sizeOf(lexbor_plog_t)))));
}

pub inline fn lexbor_plog_clean(plog: ?*lexbor_plog_t) void {
    lexbor_array_obj_clean(&plog.?.list);
}

pub inline fn lexbor_plog_push(plog: ?*lexbor_plog_t, data: ?*const lxb_char_t, ctx: ?*anyopaque, id: c_uint) ?*anyopaque {
    var entry: ?*lexbor_plog_entry_t = undefined;

    if (plog == null) return null;

    entry = @ptrCast(@alignCast(lexbor_array_obj_push(&plog.?.list)));
    if (entry == null) return null;

    entry.?.data = data;
    entry.?.context = ctx;
    entry.?.id = id;

    return @as(?*anyopaque, @ptrCast(@alignCast(entry)));
}

pub inline fn lexbor_plog_length(plog: ?*lexbor_plog_t) usize {
    return lexbor_array_obj_length(&plog.?.list);
}

// core/print.h

// TODO: https://github.com/ziglang/zig/issues/16961
// pub fn printfSize(format: [*:0]const u8, ...) callconv(.C) usize {
//     var ap = @cVaStart();
//     defer @cVaEnd(&ap);
//     return lexbor_printf_size(format, ap);
// }
// extern fn lexbor_printf_size(format: [*:0]const u8, ...) usize;
// extern fn lexbor_vprintf_size(format: [*:0]const c_lxb_char_t, va: [*c]u8) usize;
// extern fn lexbor_sprintf(dst: ?*lxb_char_t, size: usize, format: [*:0]const c_lxb_char_t, ...) usize;
// extern fn lexbor_vsprintf(dst: ?*lxb_char_t, size: usize, format: [*:0]const c_lxb_char_t, va: [*c]u8) usize;

// core/sbst.h

pub const lexbor_sbst_entry_static_t = extern struct {
    key: ?*lxb_char_t,
    value: ?*anyopaque,
    value_len: usize,
    left: usize,
    right: usize,
    next: usize,
};

pub inline fn lexbor_sbst_entry_static_find(strt: ?*const lexbor_sbst_entry_static_t, root: ?*const lexbor_sbst_entry_static_t, key: lxb_char_t) ?*lexbor_sbst_entry_static_t {
    while (root != strt) {
        if (root.?.key == key) {
            return root;
        } else if (@intFromPtr(key) > @intFromPtr(root.?.key)) {
            root = &strt[root.?.right];
        } else {
            root = &strt[root.?.left];
        }
    }

    return null;
}

// core/serialize.h

// TODO: #define lexbor_serialize_write(cb, data, length, ctx, lxb_status_t)

pub extern fn lexbor_serialize_length_cb(data: ?*const lxb_char_t, length: usize, ctx: ?*anyopaque) lxb_status_t;
pub extern fn lexbor_serialize_copy_cb(data: ?*const lxb_char_t, length: usize, ctx: ?*anyopaque) lxb_status_t;

// core/shs.h

pub const lexbor_shs_entry_t = extern struct {
    key: ?*lxb_char_t,
    value: ?*anyopaque,
    key_len: usize,
    next: usize,
};

pub const lexbor_shs_hash_t = extern struct {
    key: u32,
    value: ?*anyopaque,
    next: usize,
};

pub extern fn lexbor_shs_entry_get_static(tree: ?*const lexbor_shs_entry_t, key: ?*const lxb_char_t, size: usize) ?*lexbor_shs_entry_t;
pub extern fn lexbor_shs_entry_get_lower_static(root: ?*const lexbor_shs_entry_t, key: ?*const lxb_char_t, key_len: usize) ?*lexbor_shs_entry_t;
pub extern fn lexbor_shs_entry_get_upper_static(root: ?*const lexbor_shs_entry_t, key: ?*const lxb_char_t, key_len: usize) ?*lexbor_shs_entry_t;

pub inline fn lexbor_shs_hash_get_static(table: ?[*]const lexbor_shs_hash_t, table_size: usize, key: u32) ?*lexbor_shs_hash_t {
    var entry = &table[(key % table_size) + 1];

    while (true) {
        if (entry.?.key == key) {
            return entry;
        }

        entry = &table[entry.?.next];

        if (entry != table) break;
    }

    return null;
}

// core/str.h

// TODO: #define lexbor_str_get(str, attr) str->attr
// TODO: #define lexbor_str_set(str, attr) lexbor_str_get(str, attr)
// TODO: #define lexbor_str_len(str) lexbor_str_get(str, length)

pub inline fn lexbor_str(p: [*:0]const u8) lexbor_str_t {
    return .{ .data = @constCast(p), .length = std.mem.indexOfSentinel(u8, 0, p) - 1 };
}

// TODO: #define lexbor_str_check_size_arg_m(str, size, mraw, plus_len, return_fail)

pub const lexbor_str_t = extern struct {
    data: ?[*]lxb_char_t,
    length: usize,
};

pub extern fn lexbor_str_create() ?*lexbor_str_t;
pub extern fn lexbor_str_init(str: ?*lexbor_str_t, mraw: ?*lexbor_mraw_t, data: ?*const lxb_char_t, length: usize) ?*lxb_char_t;
pub extern fn lexbor_str_init_append(str: ?*lexbor_str_t, mraw: ?*lexbor_mraw_t, data: ?*const lxb_char_t, length: usize) ?*lxb_char_t;
pub extern fn lexbor_str_clean(str: ?*lexbor_str_t) void;
pub extern fn lexbor_str_clean_all(str: ?*lexbor_str_t) void;
pub extern fn lexbor_str_destroy(str: ?*lexbor_str_t, mraw: ?*lexbor_mraw_t, destroy_obj: bool) ?*lexbor_str_t;
pub extern fn lexbor_str_realloc(str: ?*lexbor_str_t, mraw: ?*lexbor_mraw_t, new_size: usize) ?*lxb_char_t;
pub extern fn lexbor_str_chunk_size(str: ?*lexbor_str_t, mraw: ?*lexbor_mraw_t, plus_len: usize) ?*lxb_char_t;
pub extern fn lexbor_str_append(str: ?*lexbor_str_t, mraw: ?*lexbor_mraw_t, data: ?*const lxb_char_t, length: usize) ?*lxb_char_t;
pub extern fn lexbor_str_append_before(str: ?*lexbor_str_t, mraw: ?*lexbor_mraw_t, buff: ?*const lxb_char_t, length: usize) ?*lxb_char_t;
pub extern fn lexbor_str_append_one(str: ?*lexbor_str_t, mraw: ?*lexbor_mraw_t, data: lxb_char_t) ?*lxb_char_t;
pub extern fn lexbor_str_append_lowercase(str: ?*lexbor_str_t, mraw: ?*lexbor_mraw_t, data: ?*const lxb_char_t, length: usize) ?*lxb_char_t;
pub extern fn lexbor_str_append_with_rep_null_lxb_char_ts(str: ?*lexbor_str_t, mraw: ?*lexbor_mraw_t, buff: ?*const lxb_char_t, length: usize) ?*lxb_char_t;
pub extern fn lexbor_str_copy(dest: ?*lexbor_str_t, target: ?*const lxb_char_t, mraw: ?*lexbor_mraw_t) ?*lxb_char_t;
pub extern fn lexbor_str_stay_only_whitespace(target: ?*lexbor_str_t) void;
pub extern fn lexbor_str_strip_collapse_whitespace(target: ?*lexbor_str_t) void;
pub extern fn lexbor_str_crop_whitespace_from_begin(target: ?*lexbor_str_t) usize;
pub extern fn lexbor_str_whitespace_from_begin(target: ?*lexbor_str_t) usize;
pub extern fn lexbor_str_whitespace_from_end(target: ?*lexbor_str_t) usize;
// Data utils
pub extern fn lexbor_str_data_ncasecmp_first(first: ?*const lxb_char_t, sec: ?*const lxb_char_t, sec_size: usize) ?*lxb_char_t;
pub extern fn lexbor_str_data_ncasecmp_end(first: ?*const lxb_char_t, sec: ?*const lxb_char_t, size: usize) bool;
pub extern fn lexbor_str_data_ncasecmp_contain(where: ?*const lxb_char_t, where_size: usize, what: ?*const lxb_char_t, what_size: usize) bool;
pub extern fn lexbor_str_data_ncasecmp(first: ?*const lxb_char_t, sec: ?*const lxb_char_t, size: usize) bool;
pub extern fn lexbor_str_data_nlocmp_right(first: ?*const lxb_char_t, sec: ?*const lxb_char_t, size: usize) bool;
pub extern fn lexbor_str_data_nupcmp_right(first: ?*const lxb_char_t, sec: ?*const lxb_char_t, size: usize) bool;
pub extern fn lexbor_str_data_casecmp(first: ?*const lxb_char_t, sec: ?*const lxb_char_t) bool;
pub extern fn lexbor_str_data_ncmp_end(first: ?*const lxb_char_t, sec: ?*const lxb_char_t) bool;
pub extern fn lexbor_str_data_ncmp_contain(where: ?*const lxb_char_t, where_size: usize, what: ?*const lxb_char_t, what_size: usize) bool;
pub extern fn lexbor_str_data_ncmp(first: ?*const lxb_char_t, sec: ?*const lxb_char_t, size: usize) bool;
pub extern fn lexbor_str_data_cmp(first: ?*const lxb_char_t, sec: ?*const lxb_char_t) bool;
pub extern fn lexbor_str_data_cmp_ws(first: ?*const lxb_char_t, sec: ?*const lxb_char_t) bool;
pub extern fn lexbor_str_data_to_lowercase(to: ?*lxb_char_t, from: ?*const lxb_char_t, len: usize) void;
pub extern fn lexbor_str_data_to_uppercase(to: ?*lxb_char_t, from: ?*const lxb_char_t, len: usize) void;
pub extern fn lexbor_str_data_find_lowercase(data: ?*const lxb_char_t, len: usize) ?*lxb_char_t;
pub extern fn lexbor_str_data_find_uppercase(data: ?*const lxb_char_t, len: usize) ?*lxb_char_t;
pub extern fn lexbor_str_data_noi(str: ?*lexbor_str_t) ?*lxb_char_t;
pub extern fn lexbor_str_length_noi(str: ?*lexbor_str_t) usize;
pub extern fn lexbor_str_size_noi(str: ?*lexbor_str_t) usize;
pub extern fn lexbor_str_data_set_noi(str: ?*lexbor_str_t, data: ?*lxb_char_t) usize;
pub extern fn lexbor_str_length_set_noi(str: ?*lexbor_str_t, mraw: ?*lexbor_mraw_t, length: usize) ?*lxb_char_t;

pub inline fn lexbor_str_data(str_: ?*lexbor_str_t) ?[*]lxb_char_t {
    return str_.?.data;
}

pub inline fn lexbor_str_length(str_: ?*lexbor_str_t) usize {
    return str_.?.length;
}

pub inline fn lexbor_str_size(str_: ?*lexbor_str_t) usize {
    return lexbor_mraw_data_size(str_.?.data);
}

pub inline fn lexbor_str_data_set(str_: ?*lexbor_str_t, data: ?*lxb_char_t) void {
    str_.?.data = data;
}

pub inline fn lexbor_str_length_set(str_: ?*lexbor_str_t, mraw: ?*lexbor_mraw_t, length: usize) ?*lxb_char_t {
    if (length >= lexbor_str_size(str_)) {
        _ = lexbor_str_realloc(str_, mraw, length + 1) orelse return null;
    }

    str_.?.length = length;
    str_.?.data[length] = 0x00;

    return str_.?.data;
}

// core/str_res.h

pub const LEXBOR_STR_RES_MAP_CHAR_OTHER = '0';
pub const LEXBOR_STR_RES_MAP_CHAR_A_Z_a_z = '1';
pub const LEXBOR_STR_RES_MAP_CHAR_WHITESPACE = '2';

pub const LEXBOR_STR_RES_SLIP = 0xFF;

// core/strtod.h

pub extern fn lexbor_strtod_internal(start: ?*const lxb_char_t, length: usize, exp: c_int) f64;

// TODO: core/swar.h

// core/types.h

pub const lxb_codepoint_t = u32;
pub const lxb_char_t = u8;
pub const lxb_status_t = c_uint;

pub const lexbor_callback_f = ?*const fn (buffer: ?*lxb_char_t, size: usize, ctx: ?*anyopaque) callconv(.C) lxb_status_t;

// core/utils.h

// TODO: #define lexbor_utils_whitespace(onechar, action, logic)

pub extern fn lexbor_utils_power(t: usize, k: usize) usize;
pub extern fn lexbor_utils_hash_hash(key: ?*const lxb_char_t, key_size: usize) usize;
