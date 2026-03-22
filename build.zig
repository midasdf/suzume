const std = @import("std");
// LibCSS replaced by native Zig CSS engine
// const build_libcss = @import("build_libcss.zig");
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
    // LibCSS replaced by native Zig CSS engine (src/css/)
    // const libcss = build_libcss.buildLibCss(b, target, optimize);
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
    // exe.linkLibrary(libcss);  // Replaced by native Zig CSS engine
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

    // LibCSS / LibParserUtils / LibWapcaplet headers (no longer needed)
    // exe.addIncludePath(b.path("deps/libcss/include"));
    // exe.addIncludePath(b.path("deps/libparserutils/include"));
    // exe.addIncludePath(b.path("deps/libwapcaplet/include"));

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

    // XIM (X Input Method) helper for fcitx5/mozc Japanese input
    exe.addCSourceFile(.{
        .file = b.path("src/xim_helper.c"),
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

    // ── LunaSVG (SVG rasterizer, C++17) + PlutoVG (2D graphics, C) ──
    const lunasvg_dir = "deps/lunasvg";
    exe.addIncludePath(b.path(lunasvg_dir ++ "/include"));
    exe.addIncludePath(b.path(lunasvg_dir ++ "/source"));
    exe.addIncludePath(b.path(lunasvg_dir ++ "/3rdparty/plutovg"));

    const lunasvg_cpp_flags: []const []const u8 = &.{
        "-std=c++17",
        "-fno-exceptions",
        "-fno-rtti",
        "-fno-sanitize=undefined",
        "-DLUNASVG_BUILD_STATIC",
    };

    const lunasvg_cpp_sources: []const []const u8 = &.{
        lunasvg_dir ++ "/source/lunasvg.cpp",
        lunasvg_dir ++ "/source/element.cpp",
        lunasvg_dir ++ "/source/property.cpp",
        lunasvg_dir ++ "/source/parser.cpp",
        lunasvg_dir ++ "/source/layoutcontext.cpp",
        lunasvg_dir ++ "/source/canvas.cpp",
        lunasvg_dir ++ "/source/clippathelement.cpp",
        lunasvg_dir ++ "/source/defselement.cpp",
        lunasvg_dir ++ "/source/gelement.cpp",
        lunasvg_dir ++ "/source/geometryelement.cpp",
        lunasvg_dir ++ "/source/graphicselement.cpp",
        lunasvg_dir ++ "/source/maskelement.cpp",
        lunasvg_dir ++ "/source/markerelement.cpp",
        lunasvg_dir ++ "/source/paintelement.cpp",
        lunasvg_dir ++ "/source/stopelement.cpp",
        lunasvg_dir ++ "/source/styledelement.cpp",
        lunasvg_dir ++ "/source/styleelement.cpp",
        lunasvg_dir ++ "/source/svgelement.cpp",
        lunasvg_dir ++ "/source/symbolelement.cpp",
        lunasvg_dir ++ "/source/useelement.cpp",
    };

    for (lunasvg_cpp_sources) |src| {
        exe.addCSourceFile(.{
            .file = b.path(src),
            .flags = lunasvg_cpp_flags,
        });
    }

    const plutovg_c_flags: []const []const u8 = &.{ "-fno-sanitize=undefined" };
    const plutovg_c_sources: []const []const u8 = &.{
        lunasvg_dir ++ "/3rdparty/plutovg/plutovg.c",
        lunasvg_dir ++ "/3rdparty/plutovg/plutovg-paint.c",
        lunasvg_dir ++ "/3rdparty/plutovg/plutovg-geometry.c",
        lunasvg_dir ++ "/3rdparty/plutovg/plutovg-blend.c",
        lunasvg_dir ++ "/3rdparty/plutovg/plutovg-rle.c",
        lunasvg_dir ++ "/3rdparty/plutovg/plutovg-dash.c",
        lunasvg_dir ++ "/3rdparty/plutovg/plutovg-ft-raster.c",
        lunasvg_dir ++ "/3rdparty/plutovg/plutovg-ft-stroker.c",
        lunasvg_dir ++ "/3rdparty/plutovg/plutovg-ft-math.c",
    };

    for (plutovg_c_sources) |src| {
        exe.addCSourceFile(.{
            .file = b.path(src),
            .flags = plutovg_c_flags,
        });
    }

    // SVG C++ wrapper (bridges lunasvg C++ API to C for Zig)
    exe.addCSourceFile(.{
        .file = b.path("src/svg/svg_wrapper.cpp"),
        .flags = lunasvg_cpp_flags,
    });
    exe.addIncludePath(b.path("src/svg"));

    // WOFF2 C++ wrapper (bridges woff2 C++ API to C for Zig)
    exe.addCSourceFile(.{
        .file = b.path("src/font/woff2_wrapper.cpp"),
        .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti", "-fno-sanitize=undefined" },
    });
    exe.addIncludePath(b.path("src/font"));

    // System libraries
    exe.linkSystemLibrary("xcb");
    exe.linkSystemLibrary("xcb-icccm");
    exe.linkSystemLibrary("xcb-image");
    exe.linkSystemLibrary("xcb-keysyms");
    exe.linkSystemLibrary("xcb-util");
    exe.linkSystemLibrary("X11");
    exe.linkSystemLibrary("curl");
    exe.linkSystemLibrary("sqlite3");
    exe.linkSystemLibrary("webp");
    exe.linkSystemLibrary("woff2dec");
    exe.linkSystemLibrary("woff2common");
    exe.linkSystemLibrary("brotlidec");

    // C++ standard library (needed by HarfBuzz + woff2)
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

    // ── CSS engine tests ──────────────────────────────────────
    // Single CSS module (uses relative .zig imports internally)
    const css_mod = b.createModule(.{
        .root_source_file = b.path("src/css/css.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Individual test modules (imported by name in test_css_all.zig)
    const test_string_pool_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_string_pool.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_string_pool_mod.addImport("css", css_mod);

    const test_tokenizer_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_tokenizer.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_tokenizer_mod.addImport("css", css_mod);

    const test_parser_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_parser_mod.addImport("css", css_mod);

    const test_properties_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_properties.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_properties_mod.addImport("css", css_mod);

    const test_selectors_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_selectors.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_selectors_mod.addImport("css", css_mod);

    const test_media_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_media.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_media_mod.addImport("css", css_mod);

    const test_variables_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_variables.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_variables_mod.addImport("css", css_mod);

    // Root test module that pulls in all CSS test modules
    const css_all_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_css_all.zig"),
        .target = target,
        .optimize = optimize,
    });
    css_all_test_mod.addImport("test_string_pool", test_string_pool_mod);
    css_all_test_mod.addImport("test_tokenizer", test_tokenizer_mod);
    css_all_test_mod.addImport("test_parser", test_parser_mod);
    css_all_test_mod.addImport("test_properties", test_properties_mod);
    css_all_test_mod.addImport("test_selectors", test_selectors_mod);
    css_all_test_mod.addImport("test_media", test_media_mod);
    css_all_test_mod.addImport("test_variables", test_variables_mod);

    const css_tests = b.addTest(.{
        .root_module = css_all_test_mod,
    });
    const run_css_tests = b.addRunArtifact(css_tests);
    const test_css_step = b.step("test-css", "Run CSS engine tests");
    test_css_step.dependOn(&run_css_tests.step);
}
