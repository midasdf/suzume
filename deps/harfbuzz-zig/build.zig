const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_freetype = b.option(bool, "enable_freetype", "Build Freetype") orelse true;

    const lib = b.addLibrary(.{
        .name = "harfbuzz",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    lib.addCSourceFile(.{ .file = b.path("src/harfbuzz.cc") });
    lib.linkLibCpp();
    lib.installHeadersDirectory(b.path("src"), "harfbuzz", .{
        .exclude_extensions = &.{".cc"},
    });
    if (enable_freetype) {
        lib.root_module.addCMacro("HAVE_FREETYPE", "1");

        if (b.lazyDependency("freetype", .{
            .target = target,
            .optimize = optimize,
        })) |dep| {
            lib.linkLibrary(dep.artifact("freetype"));
        }
    }
    b.installArtifact(lib);
}
