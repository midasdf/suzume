const std = @import("std");
const build_libcss = @import("build_libcss.zig");
const build_libnsfb = @import("build_libnsfb.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Zig package dependencies ──────────────────────────────────
    const lexbor_dep = b.dependency("lexbor", .{
        .target = target,
        .optimize = optimize,
    });
    const freetype_dep = b.dependency("freetype", .{
        .target = target,
        .optimize = optimize,
    });
    const harfbuzz_dep = b.dependency("harfbuzz", .{
        .target = target,
        .optimize = optimize,
    });

    const lexbor_lib = lexbor_dep.artifact("liblexbor");
    const freetype_lib = freetype_dep.artifact("freetype");
    const harfbuzz_lib = harfbuzz_dep.artifact("harfbuzz");

    // ── C library builds (netsurf) ────────────────────────────────
    const libcss = build_libcss.buildLibCss(b, target, optimize);
    const libnsfb = build_libnsfb.buildLibNsfb(b, target, optimize);

    // ── Main executable ───────────────────────────────────────────
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "suzume",
        .root_module = exe_mod,
    });

    // Link all static libraries
    exe.linkLibrary(lexbor_lib);
    exe.linkLibrary(freetype_lib);
    exe.linkLibrary(harfbuzz_lib);
    exe.linkLibrary(libcss);
    exe.linkLibrary(libnsfb);

    // LibNSFB surface registration shim (constructors don't work
    // with Zig's linker on static archives, so we register manually)
    exe.addCSourceFile(.{
        .file = b.path("src/nsfb_surface_init.c"),
        .flags = &.{"-fno-sanitize=undefined"},
    });

    // Include paths for @cImport access
    // Lexbor headers (from the package)
    exe.addIncludePath(lexbor_dep.path("lib"));

    // LibCSS / LibParserUtils / LibWapcaplet headers
    exe.addIncludePath(b.path("deps/libcss/include"));
    exe.addIncludePath(b.path("deps/libparserutils/include"));
    exe.addIncludePath(b.path("deps/libwapcaplet/include"));

    // LibNSFB headers
    exe.addIncludePath(b.path("deps/libnsfb/include"));

    // FreeType headers (from the package)
    exe.addIncludePath(freetype_dep.path("include"));

    // HarfBuzz headers (from the package)
    exe.addIncludePath(harfbuzz_dep.path("src"));

    // stb headers
    exe.addIncludePath(b.path("src/stb"));

    // stb implementation C file
    exe.addCSourceFile(.{
        .file = b.path("src/stb/stb_impl.c"),
        .flags = &.{"-fno-sanitize=undefined"},
    });

    // ── QuickJS-ng ──────────────────────────────────────────────────
    const quickjs_dir = "deps/quickjs-ng";
    exe.addIncludePath(b.path(quickjs_dir));

    const quickjs_c_flags: []const []const u8 = &.{
        "-D_GNU_SOURCE",
        "-DCONFIG_VERSION=\"0.12.1\"",
        "-std=c11",
        "-fno-sanitize=undefined",
        "-Wno-implicit-function-declaration",
        "-Wno-sign-compare",
        "-Wno-unused-parameter",
        "-Wno-unused-variable",
        "-Wno-missing-field-initializers",
        "-Wno-implicit-fallthrough",
    };

    const quickjs_sources: []const []const u8 = &.{
        quickjs_dir ++ "/quickjs.c",
        quickjs_dir ++ "/libregexp.c",
        quickjs_dir ++ "/libunicode.c",
        quickjs_dir ++ "/dtoa.c",
    };

    for (quickjs_sources) |src| {
        exe.addCSourceFile(.{
            .file = b.path(src),
            .flags = quickjs_c_flags,
        });
    }

    // System libraries
    exe.linkSystemLibrary("xcb");
    exe.linkSystemLibrary("xcb-icccm");
    exe.linkSystemLibrary("xcb-image");
    exe.linkSystemLibrary("xcb-keysyms");
    exe.linkSystemLibrary("xcb-util");
    exe.linkSystemLibrary("curl");

    // C++ standard library (needed by HarfBuzz)
    exe.linkLibCpp();
    exe.linkLibC();

    b.installArtifact(exe);

    // ── Run step ──────────────────────────────────────────────────
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run suzume");
    run_step.dependOn(&run_cmd.step);

    // ── Test step ─────────────────────────────────────────────────
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // ── DOM + Style integration test ────────────────────────────
    // Run via: zig build run -- --test-dom
    const run_test_dom = b.addRunArtifact(exe);
    run_test_dom.step.dependOn(b.getInstallStep());
    run_test_dom.addArg("--test-dom");
    const test_dom_step = b.step("test-dom-style", "Run DOM + Style integration test");
    test_dom_step.dependOn(&run_test_dom.step);
}
