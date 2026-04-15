const std = @import("std");

/// Apply Suzume-specific libnsfb changes on top of the upstream submodule checkout.
/// The submodule SHA must stay reachable from `netsurf-browser/libnsfb`; local edits live in `patches/`.
fn applyLibNsfbXimPatch(b: *std.Build) *std.Build.Step.Run {
    const patch_lp = b.path("patches/libnsfb-xim.patch");
    const run = b.addSystemCommand(&.{"bash"});
    run.addFileArg(b.path("scripts/apply-libnsfb-patch.sh"));
    run.addFileArg(patch_lp);
    run.addDirectoryArg(b.path("deps/libnsfb"));
    run.addFileInput(patch_lp);
    run.addFileInput(b.path("scripts/apply-libnsfb-patch.sh"));
    run.stdio = .inherit;
    run.has_side_effects = true;
    return run;
}

/// Build LibNSFB with X11 (xcb) backend as a static library.
pub fn buildLibNsfb(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const common_cflags = &[_][]const u8{
        "-D_BSD_SOURCE",
        "-D_DEFAULT_SOURCE",
        "-D_POSIX_C_SOURCE=200112L",
        "-DNSFB_NEED_HINTS_ALLOC",
        "-DNSFB_NEED_ICCCM_API_PREFIX",
        "-DNSFB_XCBPROTO_MAJOR_VERSION=1",
        "-DNSFB_XCBPROTO_MINOR_VERSION=17",
        "-std=c99",
        "-fno-sanitize=undefined",
        "-Wno-incompatible-pointer-types",
    };

    const lib = b.addLibrary(.{
        .name = "nsfb",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    lib.step.dependOn(&applyLibNsfbXimPatch(b).step);

    lib.root_module.addCSourceFiles(.{
        .root = b.path("deps/libnsfb"),
        .files = &.{
            // Core
            "src/libnsfb.c",
            "src/cursor.c",
            "src/dump.c",
            "src/palette.c",
            // Plot - only standalone compilation units
            // Note: common.c and 32bpp-common.c are template files #included by others
            // Note: 1bpp.c is old NetSurf browser code, not standalone libnsfb
            // Note: 24bpp.c has undefined bitmap_tiles (missing common.c include)
            "src/plot/16bpp.c",
            "src/plot/32bpp-xbgr8888.c",
            "src/plot/32bpp-xrgb8888.c",
            "src/plot/8bpp.c",
            "src/plot/api.c",
            "src/plot/generic.c",
            "src/plot/util.c",
            // Surface
            "src/surface/surface.c",
            "src/surface/ram.c",
            "src/surface/x.c",
        },
        .flags = common_cflags,
    });

    // Include paths
    lib.root_module.addIncludePath(b.path("deps/libnsfb/include"));
    lib.root_module.addIncludePath(b.path("deps/libnsfb/src"));

    // System xcb include paths for compilation (headers only)
    // Actual library linking is done by the final executable
    lib.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });

    return lib;
}
