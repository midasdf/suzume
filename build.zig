const std = @import("std");
// LibCSS replaced by native Zig CSS engine
// const build_libcss = @import("build_libcss.zig");
const build_libnsfb = @import("build_libnsfb.zig");

/// Append typical Linux multilib / generic library dirs under `root` (sysroot or "").
/// When `root` is empty, use absolute host paths (`/usr/lib/...`).
fn appendWoffLibSearchDirs(b: *std.Build, list: *std.ArrayList([]const u8), resolved: std.Target, root: []const u8) !void {
    const push_abs = struct {
        fn f(alloc: std.mem.Allocator, lst: *std.ArrayList([]const u8), s: []const u8) !void {
            try lst.append(alloc, try alloc.dupe(u8, s));
        }
    }.f;
    const push_under_root = struct {
        fn f(bb: *std.Build, lst: *std.ArrayList([]const u8), sysroot_prefix: []const u8, tail: []const []const u8) !void {
            const base_owned: ?[]u8 = if (std.fs.path.isAbsolute(sysroot_prefix)) null else bb.pathFromRoot(sysroot_prefix);
            defer if (base_owned) |p| bb.allocator.free(p);
            const base: []const u8 = base_owned orelse sysroot_prefix;

            var parts = try bb.allocator.alloc([]const u8, 1 + tail.len);
            defer bb.allocator.free(parts);
            parts[0] = base;
            @memcpy(parts[1..], tail);
            const abs = bb.pathResolve(parts);
            try lst.append(bb.allocator, abs);
        }
    }.f;

    if (resolved.os.tag == .linux) {
        if (root.len == 0) {
            if (resolved.cpu.arch == .x86_64) {
                try push_abs(b.allocator, list, "/usr/lib/x86_64-linux-gnu");
                try push_abs(b.allocator, list, "/lib/x86_64-linux-gnu");
            } else if (resolved.cpu.arch == .aarch64) {
                try push_abs(b.allocator, list, "/usr/lib/aarch64-linux-gnu");
                try push_abs(b.allocator, list, "/lib/aarch64-linux-gnu");
            } else {
                const triple = try resolved.linuxTriple(b.allocator);
                defer b.allocator.free(triple);
                const u = try std.fmt.allocPrint(b.allocator, "/usr/lib/{s}", .{triple});
                defer b.allocator.free(u);
                const l = try std.fmt.allocPrint(b.allocator, "/lib/{s}", .{triple});
                defer b.allocator.free(l);
                try push_abs(b.allocator, list, u);
                try push_abs(b.allocator, list, l);
            }
        } else {
            if (resolved.cpu.arch == .x86_64) {
                try push_under_root(b, list, root, &.{ "usr", "lib", "x86_64-linux-gnu" });
                try push_under_root(b, list, root, &.{ "lib", "x86_64-linux-gnu" });
            } else if (resolved.cpu.arch == .aarch64) {
                try push_under_root(b, list, root, &.{ "usr", "lib", "aarch64-linux-gnu" });
                try push_under_root(b, list, root, &.{ "lib", "aarch64-linux-gnu" });
            } else {
                const triple = try resolved.linuxTriple(b.allocator);
                defer b.allocator.free(triple);
                try push_under_root(b, list, root, &.{ "usr", "lib", triple });
                try push_under_root(b, list, root, &.{ "lib", triple });
            }
        }
    }

    if (root.len == 0) {
        try push_abs(b.allocator, list, "/usr/lib64");
        try push_abs(b.allocator, list, "/usr/lib");
        try push_abs(b.allocator, list, "/lib64");
        try push_abs(b.allocator, list, "/lib");
    } else {
        try push_under_root(b, list, root, &.{ "usr", "lib64" });
        try push_under_root(b, list, root, &.{ "usr", "lib" });
        try push_under_root(b, list, root, &.{"lib64"});
        try push_under_root(b, list, root, &.{"lib"});
    }
}

/// Prefer `stem.so`, else any `stem.so*` (longest basename wins as a rough "newest" heuristic).
fn findWoffSharedObject(b: *std.Build, dirs: []const []const u8, stem: []const u8) ?std.Build.LazyPath {
    var buf: [512]u8 = undefined;
    for (dirs) |dir| {
        const unversioned = std.fmt.bufPrint(&buf, "{s}/{s}.so", .{ dir, stem }) catch continue;
        std.Io.Dir.accessAbsolute(b.graph.io, unversioned, .{}) catch continue;
        return .{ .cwd_relative = b.dupe(unversioned) };
    }
    var best_name_len: usize = 0;
    var best_path: ?[]const u8 = null;
    defer if (best_path) |p| b.allocator.free(p);
    for (dirs) |dir| {
        var d = std.Io.Dir.openDirAbsolute(b.graph.io, dir, .{ .iterate = true }) catch continue;
        defer d.close(b.graph.io);
        var it = d.iterate();
        while (it.next(b.graph.io) catch break) |ent| {
            if (ent.kind != .file) continue;
            if (!std.mem.startsWith(u8, ent.name, stem)) continue;
            const after = ent.name[stem.len..];
            if (!std.mem.eql(u8, after, ".so") and !std.mem.startsWith(u8, after, ".so.")) continue;
            if (ent.name.len <= best_name_len) continue;
            best_name_len = ent.name.len;
            if (best_path) |old| b.allocator.free(old);
            best_path = std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ dir, ent.name }) catch continue;
        }
    }
    if (best_path) |full| {
        return .{ .cwd_relative = b.dupe(full) };
    }
    return null;
}

fn linkWoff2(exe: *std.Build.Step.Compile) void {
    const b = exe.step.owner;
    const rt = exe.root_module.resolved_target orelse return;
    const resolved = rt.result;
    const cross_linux = resolved.os.tag == .linux and
        !(rt.query.isNativeCpu() and rt.query.isNativeOs() and rt.query.isNativeAbi());

    var dirs: std.ArrayList([]const u8) = .empty;
    defer {
        for (dirs.items) |p| b.allocator.free(p);
        dirs.deinit(b.allocator);
    }

    if (cross_linux) {
        if (b.sysroot) |sr| {
            appendWoffLibSearchDirs(b, &dirs, resolved, sr) catch return;
        }
        appendWoffLibSearchDirs(b, &dirs, resolved, "sysroot") catch return;
    } else {
        appendWoffLibSearchDirs(b, &dirs, resolved, "") catch return;
    }

    if (findWoffSharedObject(b, dirs.items, "libwoff2dec")) |p| {
        exe.root_module.addObjectFile(p);
    }
    if (findWoffSharedObject(b, dirs.items, "libwoff2common")) |p| {
        exe.root_module.addObjectFile(p);
    }
}

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

    // ── kotori JS engine module (shared by exe and tests) ──────────
    const kotori_mod = b.createModule(.{
        .root_source_file = b.path("src/js/kotori/kotori.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── Shared dom_names module (DOM §1.5 Name/QName/validate-and-extract).
    // Shared between the root module (QuickJS path: dom_api.zig, dom_document.zig,
    // dom_element.zig) and the kotori_dom module (kotori path). Exposed to both
    // via `@import("dom_names")` to avoid the "file belongs to only one module"
    // error that arises if kotori_dom and exe_mod both try to embed the file
    // directly.
    const dom_names_shared_mod = b.createModule(.{
        .root_source_file = b.path("src/js/dom_names.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── kotori DOM bridge module ────────────────────────────────────
    const kotori_dom_exe_mod = b.createModule(.{
        .root_source_file = b.path("src/js/kotori_dom.zig"),
        .target = target,
        .optimize = optimize,
    });
    kotori_dom_exe_mod.addImport("kotori", kotori_mod);
    kotori_dom_exe_mod.addImport("dom_names", dom_names_shared_mod);
    kotori_dom_exe_mod.addIncludePath(lexbor_dep.path("lib"));

    // ── kotori runtime module ────────────────────────────────────
    const kotori_rt_mod = b.createModule(.{
        .root_source_file = b.path("src/js/kotori_runtime.zig"),
        .target = target,
        .optimize = optimize,
    });
    kotori_rt_mod.addImport("kotori", kotori_mod);
    kotori_rt_mod.addImport("kotori_dom", kotori_dom_exe_mod);

    // ── Main executable ───────────────────────────────────────────
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("kotori", kotori_mod);
    exe_mod.addImport("kotori_dom", kotori_dom_exe_mod);
    exe_mod.addImport("kotori_runtime", kotori_rt_mod);
    exe_mod.addImport("dom_names", dom_names_shared_mod);

    const exe = b.addExecutable(.{
        .name = "suzume",
        .root_module = exe_mod,
    });

    // Link all static libraries
    exe.root_module.linkLibrary(lexbor_lib);
    exe.root_module.linkLibrary(freetype_lib);
    exe.root_module.linkLibrary(harfbuzz_lib);
    // exe.linkLibrary(libcss);  // Replaced by native Zig CSS engine
    exe.root_module.linkLibrary(libnsfb);

    // LibNSFB surface registration shim (constructors don't work
    // with Zig's linker on static archives, so we register manually)
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/nsfb_surface_init.c"),
        .flags = &.{"-fno-sanitize=undefined"},
    });

    // Include paths for @cImport access
    // Lexbor headers (from the package)
    exe.root_module.addIncludePath(lexbor_dep.path("lib"));

    // LibCSS / LibParserUtils / LibWapcaplet headers (no longer needed)
    // exe.addIncludePath(b.path("deps/libcss/include"));
    // exe.addIncludePath(b.path("deps/libparserutils/include"));
    // exe.addIncludePath(b.path("deps/libwapcaplet/include"));

    // LibNSFB headers
    exe.root_module.addIncludePath(b.path("deps/libnsfb/include"));

    // FreeType headers (from the package)
    exe.root_module.addIncludePath(freetype_dep.path("include"));

    // HarfBuzz headers (from the package)
    exe.root_module.addIncludePath(harfbuzz_dep.path("src"));

    // stb headers
    exe.root_module.addIncludePath(b.path("src/stb"));

    // stb implementation C file
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/stb/stb_impl.c"),
        .flags = &.{"-fno-sanitize=undefined"},
    });

    // XIM (X Input Method) helper for fcitx5/mozc Japanese input
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/xim_helper.c"),
        .flags = &.{"-fno-sanitize=undefined"},
    });

    // nsfb_x_* helpers used by XIM/cursor live in deps/libnsfb's XCB backend.

    // ── QuickJS-ng ──────────────────────────────────────────────────
    const quickjs_dir = "deps/quickjs-ng";
    exe.root_module.addIncludePath(b.path(quickjs_dir));

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
        exe.root_module.addCSourceFile(.{
            .file = b.path(src),
            .flags = quickjs_c_flags,
        });
    }

    // ── LunaSVG (SVG rasterizer, C++17) + PlutoVG (2D graphics, C) ──
    const lunasvg_dir = "deps/lunasvg";
    exe.root_module.addIncludePath(b.path(lunasvg_dir ++ "/include"));
    exe.root_module.addIncludePath(b.path(lunasvg_dir ++ "/source"));
    exe.root_module.addIncludePath(b.path(lunasvg_dir ++ "/3rdparty/plutovg"));

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
        exe.root_module.addCSourceFile(.{
            .file = b.path(src),
            .flags = lunasvg_cpp_flags,
        });
    }

    const plutovg_c_flags: []const []const u8 = &.{"-fno-sanitize=undefined"};
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
        exe.root_module.addCSourceFile(.{
            .file = b.path(src),
            .flags = plutovg_c_flags,
        });
    }

    // SVG C++ wrapper (bridges lunasvg C++ API to C for Zig)
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/svg/svg_wrapper.cpp"),
        .flags = lunasvg_cpp_flags,
    });
    exe.root_module.addIncludePath(b.path("src/svg"));

    // WOFF2 C++ wrapper (bridges woff2 C++ API to C for Zig)
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/font/woff2_wrapper.cpp"),
        .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti", "-fno-sanitize=undefined" },
    });
    exe.root_module.addIncludePath(b.path("src/font"));

    // Cross-compile: add repo-local sysroot paths for aarch64-linux (see README / packaging notes).
    const resolved = target.result;
    if (resolved.cpu.arch == .aarch64 and resolved.os.tag == .linux) {
        exe.root_module.addLibraryPath(b.path("sysroot/usr/lib"));
        exe.root_module.addIncludePath(b.path("sysroot/usr/include"));
    }

    // System libraries
    exe.root_module.linkSystemLibrary("xcb", .{});
    exe.root_module.linkSystemLibrary("xcb-icccm", .{});
    exe.root_module.linkSystemLibrary("xcb-image", .{});
    exe.root_module.linkSystemLibrary("xcb-keysyms", .{});
    exe.root_module.linkSystemLibrary("xcb-util", .{});
    exe.root_module.linkSystemLibrary("X11", .{});
    exe.root_module.linkSystemLibrary("xcb-shm", .{});
    exe.root_module.linkSystemLibrary("xcb-cursor", .{});
    exe.root_module.linkSystemLibrary("curl", .{});
    exe.root_module.linkSystemLibrary("sqlite3", .{});
    exe.root_module.linkSystemLibrary("webp", .{});
    exe.root_module.linkSystemLibrary("brotlidec", .{});
    exe.root_module.linkSystemLibrary("fontconfig", .{});

    linkWoff2(exe);

    // C++ standard library (needed by HarfBuzz + woff2)
    exe.root_module.link_libcpp = true;
    exe.root_module.link_libc = true;

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
    test_mod.addImport("dom_names", dom_names_shared_mod);
    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const url_resolve_mod = b.createModule(.{
        .root_source_file = b.path("src/test_url_resolve.zig"),
        .target = target,
        .optimize = optimize,
    });
    url_resolve_mod.addIncludePath(lexbor_dep.path("lib"));
    const url_resolve_tests = b.addTest(.{
        .root_module = url_resolve_mod,
    });
    url_resolve_tests.root_module.link_libc = true;
    const run_url_resolve_tests = b.addRunArtifact(url_resolve_tests);
    test_step.dependOn(&run_url_resolve_tests.step);

    // ── URL module tests ──────────────────────────────────────
    const url_pe_mod = b.createModule(.{
        .root_source_file = b.path("src/url/percent_encode.zig"),
        .target = target,
        .optimize = optimize,
    });
    const url_pe_tests = b.addTest(.{ .root_module = url_pe_mod });
    const run_url_pe_tests = b.addRunArtifact(url_pe_tests);
    const test_url_pe_step = b.step("test-url-percent-encode", "Run URL percent-encode tests");
    test_url_pe_step.dependOn(&run_url_pe_tests.step);
    test_step.dependOn(&run_url_pe_tests.step);

    const url_tables_mod = b.createModule(.{
        .root_source_file = b.path("src/url/tables.zig"),
        .target = target,
        .optimize = optimize,
    });
    const url_tables_tests = b.addTest(.{ .root_module = url_tables_mod });
    const run_url_tables_tests = b.addRunArtifact(url_tables_tests);
    const test_url_tables_step = b.step("test-url-tables", "Run URL IDNA/NFC table tests");
    test_url_tables_step.dependOn(&run_url_tables_tests.step);
    test_step.dependOn(&run_url_tables_tests.step);

    const url_pc_mod = b.createModule(.{
        .root_source_file = b.path("src/url/punycode.zig"),
        .target = target,
        .optimize = optimize,
    });
    const url_pc_tests = b.addTest(.{ .root_module = url_pc_mod });
    const run_url_pc_tests = b.addRunArtifact(url_pc_tests);
    const test_url_pc_step = b.step("test-url-punycode", "Run URL Punycode tests");
    test_url_pc_step.dependOn(&run_url_pc_tests.step);
    test_step.dependOn(&run_url_pc_tests.step);

    const url_nfc_mod = b.createModule(.{
        .root_source_file = b.path("src/url/nfc.zig"),
        .target = target,
        .optimize = optimize,
    });
    // nfc.zig uses @import("tables.zig") — no addImport needed
    const url_nfc_tests = b.addTest(.{ .root_module = url_nfc_mod });
    const run_url_nfc_tests = b.addRunArtifact(url_nfc_tests);
    const test_url_nfc_step = b.step("test-url-nfc", "Run URL NFC normalization tests");
    test_url_nfc_step.dependOn(&run_url_nfc_tests.step);
    test_step.dependOn(&run_url_nfc_tests.step);

    const url_idna_mod = b.createModule(.{
        .root_source_file = b.path("src/url/idna.zig"),
        .target = target,
        .optimize = optimize,
    });
    // idna.zig uses @import("tables.zig"), @import("nfc.zig"), @import("punycode.zig")
    const url_idna_tests = b.addTest(.{ .root_module = url_idna_mod });
    const run_url_idna_tests = b.addRunArtifact(url_idna_tests);
    const test_url_idna_step = b.step("test-url-idna", "Run URL IDNA tests");
    test_url_idna_step.dependOn(&run_url_idna_tests.step);
    test_step.dependOn(&run_url_idna_tests.step);

    const url_host_mod = b.createModule(.{
        .root_source_file = b.path("src/url/host.zig"),
        .target = target,
        .optimize = optimize,
    });
    // host.zig uses @import("idna.zig"), @import("percent_encode.zig")
    const url_host_tests = b.addTest(.{ .root_module = url_host_mod });
    const run_url_host_tests = b.addRunArtifact(url_host_tests);
    const test_url_host_step = b.step("test-url-host", "Run URL host parsing tests");
    test_url_host_step.dependOn(&run_url_host_tests.step);
    test_step.dependOn(&run_url_host_tests.step);

    const url_sp_mod = b.createModule(.{
        .root_source_file = b.path("src/url/search_params.zig"),
        .target = target,
        .optimize = optimize,
    });
    // search_params.zig uses @import("percent_encode.zig")
    const url_sp_tests = b.addTest(.{ .root_module = url_sp_mod });
    const run_url_sp_tests = b.addRunArtifact(url_sp_tests);
    const test_url_sp_step = b.step("test-url-searchparams", "Run URLSearchParams tests");
    test_url_sp_step.dependOn(&run_url_sp_tests.step);
    test_step.dependOn(&run_url_sp_tests.step);

    const url_parser_mod = b.createModule(.{
        .root_source_file = b.path("src/url/parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    // parser.zig uses @import("host.zig"), @import("percent_encode.zig")
    const url_parser_tests = b.addTest(.{ .root_module = url_parser_mod });
    const run_url_parser_tests = b.addRunArtifact(url_parser_tests);
    const test_url_parser_step = b.step("test-url-parser", "Run URL parser tests");
    test_url_parser_step.dependOn(&run_url_parser_tests.step);
    test_step.dependOn(&run_url_parser_tests.step);

    // ── Shadow DOM Phase 1 unit tests ───────────────────────────
    const shadow_dom_mod = b.createModule(.{
        .root_source_file = b.path("src/test_shadow_dom.zig"),
        .target = target,
        .optimize = optimize,
    });
    shadow_dom_mod.addIncludePath(lexbor_dep.path("lib"));
    shadow_dom_mod.link_libc = true;
    const shadow_dom_tests = b.addTest(.{ .root_module = shadow_dom_mod });
    const run_shadow_dom_tests = b.addRunArtifact(shadow_dom_tests);
    const test_shadow_dom_step = b.step("test-shadow-dom", "Run Shadow DOM Phase 1 tests");
    test_shadow_dom_step.dependOn(&run_shadow_dom_tests.step);
    test_step.dependOn(&run_shadow_dom_tests.step);

    // ── DOMTokenList spec-compliance unit tests ─────────────────
    const dom_token_list_mod = b.createModule(.{
        .root_source_file = b.path("src/test_dom_token_list.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dom_token_list_tests = b.addTest(.{ .root_module = dom_token_list_mod });
    const run_dom_token_list_tests = b.addRunArtifact(dom_token_list_tests);
    const test_dom_token_list_step = b.step("test-dom-token-list", "Run DOMTokenList §7.1 spec tests");
    test_dom_token_list_step.dependOn(&run_dom_token_list_tests.step);
    test_step.dependOn(&run_dom_token_list_tests.step);

    // ── dom_names (Name / QName / validate-and-extract) tests ──
    // Pure-Zig unit tests for DOM §1.5 algorithm and Name/QName productions.
    const dom_names_mod = b.createModule(.{
        .root_source_file = b.path("src/js/dom_names.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dom_names_tests = b.addTest(.{ .root_module = dom_names_mod });
    const run_dom_names_tests = b.addRunArtifact(dom_names_tests);
    const test_dom_names_step = b.step("test-dom-names", "Run DOM §1.5 Name/QName tests");
    test_dom_names_step.dependOn(&run_dom_names_tests.step);
    test_step.dependOn(&run_dom_names_tests.step);

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

    const style_decl_src_mod = b.createModule(.{
        .root_source_file = b.path("src/css/cssom/style_decl.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_style_decl_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_style_decl.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_style_decl_mod.addImport("style_decl", style_decl_src_mod);

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
    css_all_test_mod.addImport("test_style_decl", test_style_decl_mod);

    const css_tests = b.addTest(.{
        .root_module = css_all_test_mod,
    });
    const run_css_tests = b.addRunArtifact(css_tests);
    const test_css_step = b.step("test-css", "Run CSS engine tests");
    test_css_step.dependOn(&run_css_tests.step);

    // ── kotori JS engine tests ─────────────────────────────────
    // (kotori_mod is created above, shared with exe_mod)

    const test_kotori_lexer_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_kotori_lexer.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_kotori_lexer_mod.addImport("kotori", kotori_mod);

    const test_kotori_parser_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_kotori_parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_kotori_parser_mod.addImport("kotori", kotori_mod);

    const test_kotori_vm_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_kotori_vm.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_kotori_vm_mod.addImport("kotori", kotori_mod);

    const kotori_all_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_kotori.zig"),
        .target = target,
        .optimize = optimize,
    });
    kotori_all_test_mod.addImport("test_kotori_lexer", test_kotori_lexer_mod);
    kotori_all_test_mod.addImport("test_kotori_parser", test_kotori_parser_mod);
    kotori_all_test_mod.addImport("test_kotori_vm", test_kotori_vm_mod);
    kotori_all_test_mod.addImport("kotori", kotori_mod);

    const kotori_tests = b.addTest(.{
        .root_module = kotori_all_test_mod,
    });
    kotori_tests.root_module.link_libc = true;
    const run_kotori_tests = b.addRunArtifact(kotori_tests);
    const test_kotori_step = b.step("test-kotori", "Run kotori JS engine tests");
    test_kotori_step.dependOn(&run_kotori_tests.step);

    // ── kotori DOM integration tests ─────────────────────────────
    const kotori_dom_mod = b.createModule(.{
        .root_source_file = b.path("src/js/kotori_dom.zig"),
        .target = target,
        .optimize = optimize,
    });
    kotori_dom_mod.addImport("kotori", kotori_mod);
    kotori_dom_mod.addImport("dom_names", dom_names_shared_mod);
    kotori_dom_mod.addIncludePath(lexbor_dep.path("lib"));

    const test_kotori_dom_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_kotori_dom.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_kotori_dom_mod.addImport("kotori", kotori_mod);
    test_kotori_dom_mod.addImport("kotori_dom", kotori_dom_mod);
    test_kotori_dom_mod.addIncludePath(lexbor_dep.path("lib"));

    const kotori_dom_tests = b.addTest(.{
        .root_module = test_kotori_dom_mod,
    });
    kotori_dom_tests.root_module.linkLibrary(lexbor_lib);

    const run_kotori_dom_tests = b.addRunArtifact(kotori_dom_tests);
    const test_kotori_dom_step = b.step("test-kotori-dom", "Run kotori DOM binding tests");
    test_kotori_dom_step.dependOn(&run_kotori_dom_tests.step);

    // ── kotori HTML interfaces resolver tests (pure-Zig, no C deps) ──
    const kotori_html_ifaces_src_mod = b.createModule(.{
        .root_source_file = b.path("src/js/kotori_html_interfaces.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_kotori_html_ifaces_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_kotori_html_interfaces.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_kotori_html_ifaces_mod.addImport("kotori_html_interfaces", kotori_html_ifaces_src_mod);
    const kotori_html_ifaces_tests = b.addTest(.{
        .root_module = test_kotori_html_ifaces_mod,
    });
    const run_kotori_html_ifaces_tests = b.addRunArtifact(kotori_html_ifaces_tests);
    const test_kotori_html_ifaces_step = b.step("test-kotori-html-ifaces", "Run kotori HTML interface resolver tests");
    test_kotori_html_ifaces_step.dependOn(&run_kotori_html_ifaces_tests.step);
    test_step.dependOn(&run_kotori_html_ifaces_tests.step);

    // ── Layout hit-test unit tests (CSSOM View §7.3) ──────────────
    // Use src/main.zig as root so relative @imports inside layout/hittest.zig
    // and its transitive deps resolve correctly.
    const hittest_mod = b.createModule(.{
        .root_source_file = b.path("src/test_hittest.zig"),
        .target = target,
        .optimize = optimize,
    });
    hittest_mod.addIncludePath(lexbor_dep.path("lib"));
    hittest_mod.link_libc = true;
    const hittest_tests = b.addTest(.{ .root_module = hittest_mod });
    hittest_tests.root_module.linkLibrary(lexbor_lib);
    const run_hittest_tests = b.addRunArtifact(hittest_tests);
    const test_hittest_step = b.step("test-hittest", "Run layout hit-test tests");
    test_hittest_step.dependOn(&run_hittest_tests.step);
    test_step.dependOn(&run_hittest_tests.step);

    // ── Flex-basis unit tests (CSS Flexbox L1 §9.2, Sizing L3 §5, L4 §6) ──
    // flex.zig transitively pulls in paint/painter.zig → freetype, harfbuzz,
    // and block.zig → dom/node.zig → lexbor, so we need the same C deps as
    // the main executable.
    const flex_basis_mod = b.createModule(.{
        .root_source_file = b.path("src/test_flex_basis.zig"),
        .target = target,
        .optimize = optimize,
    });
    flex_basis_mod.link_libc = true;
    flex_basis_mod.addIncludePath(lexbor_dep.path("lib"));
    flex_basis_mod.addIncludePath(freetype_dep.path("include"));
    flex_basis_mod.addIncludePath(harfbuzz_dep.path("src"));
    const flex_basis_tests = b.addTest(.{ .root_module = flex_basis_mod });
    flex_basis_tests.root_module.linkLibrary(lexbor_lib);
    flex_basis_tests.root_module.linkLibrary(freetype_lib);
    flex_basis_tests.root_module.linkLibrary(harfbuzz_lib);
    const run_flex_basis_tests = b.addRunArtifact(flex_basis_tests);
    const test_flex_basis_step = b.step("test-flex-basis", "Run flex-basis unit tests");
    test_flex_basis_step.dependOn(&run_flex_basis_tests.step);
    test_step.dependOn(&run_flex_basis_tests.step);
}
