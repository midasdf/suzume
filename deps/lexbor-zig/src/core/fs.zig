const std = @import("std");
const span = std.mem.span;

pub const core = @import("../core_ext.zig");

pub const DirFileF = core.lexbor_fs_dir_file_f;

pub const DirOptType = core.lexbor_fs_dir_opt_t;

pub const DirOpt = core.lexbor_fs_dir_opt;
pub const FileType = core.lexbor_fs_file_type_t;

pub fn dirRead(dirpath: []const u8, opt: core.lexbor_fs_dir_opt, callback: core.lexbor_fs_dir_file_f, ctx: ?*anyopaque) core.lexbor_status_t {
    const status = core.lexbor_fs_dir_read(@ptrCast(dirpath.ptr), opt, callback, ctx);
    return @enumFromInt(status);
}

pub fn fileType(full_path: []const u8) core.lexbor_fs_file_type_t {
    const file_type = core.lexbor_fs_file_type(@ptrCast(full_path.ptr));
    return @enumFromInt(file_type);
}

pub fn fileEasyRead(full_path: []const u8, len: ?*usize) ?[]u8 {
    const content = core.lexbor_fs_file_easy_read(@ptrCast(full_path.ptr), len) orelse return null;
    return span(content);
}
