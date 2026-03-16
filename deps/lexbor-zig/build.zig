const std = @import("std");
const Allocator = std.mem.Allocator;
const Build = std.Build;
const Compile = Build.Step.Compile;
const LibraryOptions = Build.LibraryOptions;
const argsAlloc = std.process.argsAlloc;
const eql = std.mem.eql;
const exit = std.process.exit;
const print = std.debug.print;

pub const Options = struct {
    core: bool = false,
    css: bool = false,
    dom: bool = false,
    encoding: bool = false,
    html: bool = false,
    ns: bool = false,
    ports: bool = false,
    punycode: bool = false,
    selectors: bool = false,
    tag: bool = false,
    unicode: bool = false,
    url: bool = false,
    utils: bool = false,
    with_utils: bool = false,
};

pub fn build(b: *Build) !void {
    const defaults = Options{};
    var options = Options{
        .core = b.option(bool, "core", "Build a core module") orelse defaults.core,
        .css = b.option(bool, "css", "Build a css module") orelse defaults.css,
        .dom = b.option(bool, "dom", "Build a dom module") orelse defaults.dom,
        .encoding = b.option(bool, "encoding", "Build a encoding module") orelse defaults.encoding,
        .html = b.option(bool, "html", "Build a html module") orelse defaults.html,
        .ns = b.option(bool, "ns", "Build a ns module") orelse defaults.ns,
        .ports = b.option(bool, "ports", "Build a ports module") orelse defaults.ports,
        .punycode = b.option(bool, "punycode", "Build a punycode module") orelse defaults.punycode,
        .selectors = b.option(bool, "selectors", "Build a selectors module") orelse defaults.selectors,
        .tag = b.option(bool, "tag", "Build a tag module") orelse defaults.tag,
        .unicode = b.option(bool, "unicode", "Build a unicode module") orelse defaults.unicode,
        .url = b.option(bool, "url", "Build a url module") orelse defaults.url,
        .utils = b.option(bool, "utils", "Build a utils module") orelse defaults.utils,
        .with_utils = b.option(bool, "with_utils", "default: OFF; Build with utils module") orelse defaults.with_utils,
    };

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("lexbor", .{
        .root_source_file = b.path("src/lexbor.zig"),
        .target = target,
        .optimize = optimize,
    });

    const is_single = parseOptions(&options);

    if (is_single) {
        compileSingle(b, options.with_utils, .{
            .name = "liblexbor",
            .root_module = lib_mod,
            .linkage = .static,
        });
    } else {
        if (options.core)
            compileCore(b, options.with_utils, .{
                .name = "liblexbor-core",
                .root_module = lib_mod,
                .linkage = .static,
            });
        if (options.css)
            compileCss(b, options.with_utils, .{
                .name = "liblexbor-css",
                .root_module = lib_mod,
                .linkage = .static,
            });
        if (options.dom)
            compileDom(b, options.with_utils, .{
                .name = "liblexbor-dom",
                .root_module = lib_mod,
                .linkage = .static,
            });
        if (options.encoding)
            compileEncoding(b, options.with_utils, .{
                .name = "liblexbor-encoding",
                .root_module = lib_mod,
                .linkage = .static,
            });
        if (options.html)
            compileHtml(b, options.with_utils, .{
                .name = "liblexbor-html",
                .root_module = lib_mod,
                .linkage = .static,
            });
        if (options.ns)
            compileNs(b, options.with_utils, .{
                .name = "liblexbor-ns",
                .root_module = lib_mod,
                .linkage = .static,
            });
        if (options.ports)
            compilePorts(b, options.with_utils, .{
                .name = "liblexbor-ports",
                .root_module = lib_mod,
                .linkage = .static,
            });
        if (options.punycode)
            compilePunycode(b, options.with_utils, .{
                .name = "liblexbor-punycode",
                .root_module = lib_mod,
                .linkage = .static,
            });
        if (options.selectors)
            compileSelectors(b, options.with_utils, .{
                .name = "liblexbor-selectors",
                .root_module = lib_mod,
                .linkage = .static,
            });
        if (options.tag)
            compileTag(b, options.with_utils, .{
                .name = "liblexbor-tag",
                .root_module = lib_mod,
                .linkage = .static,
            });
        if (options.unicode)
            compileUnicode(b, options.with_utils, .{
                .name = "liblexbor-unicode",
                .root_module = lib_mod,
                .linkage = .static,
            });
        if (options.url)
            compileUrl(b, options.with_utils, .{
                .name = "liblexbor-url",
                .root_module = lib_mod,
                .linkage = .static,
            });
        if (options.utils)
            compileUtils(b, .{
                .name = "liblexbor-utils",
                .root_module = lib_mod,
                .linkage = .static,
            });
    }

    // tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("lexbor", lib_mod);
    const lib_unit_tests = b.addTest(.{
        .name = "lexbor-zig-tests",
        .root_module = test_mod,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(lib_unit_tests).step);

    // examples
    const examples_step = b.step("examples", "Builds all the examples");

    for (examples) |example| {
        const exe_mod = b.addModule(example.name, .{
            .root_source_file = b.path(example.path),
            .target = target,
            .optimize = optimize,
        });

        exe_mod.addImport("lexbor", lib_mod);

        const exe = b.addExecutable(.{
            .name = example.name,
            .root_module = exe_mod,
        });

        const run_cmd = b.addRunArtifact(exe);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const example_step = b.step(example.name, b.fmt("Build and run {s}", .{example.path}));
        example_step.dependOn(&run_cmd.step);

        const install_example = b.addInstallArtifact(exe, .{});
        example_step.dependOn(&install_example.step);

        examples_step.dependOn(&install_example.step);
    }
}

fn parseOptions(options: *Options) bool {
    if (!options.core and !options.css and !options.dom and
        !options.encoding and !options.html and !options.ns and
        !options.ports and !options.punycode and !options.selectors and
        !options.tag and !options.unicode and !options.url)
    {
        return true;
    }
    return false;
}

fn compileCore(b: *Build, with_utils: bool, static_options: LibraryOptions) void {
    const lib = b.addLibrary(static_options);
    lib.addIncludePath(b.path("lib"));
    // DEPENDENCIES ""
    lib.addCSourceFiles(.{
        .files = &core_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &ports_src,
        .flags = &cflags_ports,
    });
    if (with_utils) lib.addCSourceFiles(.{
        .files = &utils_src,
        .flags = &cflags,
    });
    lib.linkLibC();
    b.installArtifact(lib);
}

fn compileCss(b: *Build, with_utils: bool, static_options: LibraryOptions) void {
    const lib = b.addLibrary(static_options);
    lib.addIncludePath(b.path("lib"));
    // DEPENDENCIES "core"
    lib.addCSourceFiles(.{
        .files = &core_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &ports_src,
        .flags = &cflags_ports,
    });
    lib.addCSourceFiles(.{
        .files = &css_src,
        .flags = &cflags,
    });
    if (with_utils) lib.addCSourceFiles(.{
        .files = &utils_src,
        .flags = &cflags,
    });
    lib.linkLibC();
    b.installArtifact(lib);
}

fn compileDom(b: *Build, with_utils: bool, static_options: LibraryOptions) void {
    const lib = b.addLibrary(static_options);
    lib.addIncludePath(b.path("lib"));
    // DEPENDENCIES "core tag ns"
    lib.addCSourceFiles(.{
        .files = &core_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &ports_src,
        .flags = &cflags_ports,
    });
    lib.addCSourceFiles(.{
        .files = &tag_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &ns_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &dom_src,
        .flags = &cflags,
    });
    if (with_utils) lib.addCSourceFiles(.{
        .files = &utils_src,
        .flags = &cflags,
    });
    lib.linkLibC();
    b.installArtifact(lib);
}

fn compileEncoding(b: *Build, with_utils: bool, static_options: LibraryOptions) void {
    const lib = b.addLibrary(static_options);
    lib.addIncludePath(b.path("lib"));
    // DEPENDENCIES "core"
    lib.addCSourceFiles(.{
        .files = &core_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &ports_src,
        .flags = &cflags_ports,
    });
    lib.addCSourceFiles(.{
        .files = &encoding_src,
        .flags = &cflags,
    });
    if (with_utils) lib.addCSourceFiles(.{
        .files = &utils_src,
        .flags = &cflags,
    });
    lib.linkLibC();
    b.installArtifact(lib);
}

fn compileHtml(b: *Build, with_utils: bool, static_options: LibraryOptions) void {
    const lib = b.addLibrary(static_options);
    lib.addIncludePath(b.path("lib"));
    // DEPENDENCIES "core dom ns tag css selectors"
    lib.addCSourceFiles(.{
        .files = &core_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &ports_src,
        .flags = &cflags_ports,
    });
    lib.addCSourceFiles(.{
        .files = &dom_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &ns_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &tag_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &css_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &selectors_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &html_src,
        .flags = &cflags,
    });
    if (with_utils) lib.addCSourceFiles(.{
        .files = &utils_src,
        .flags = &cflags,
    });
    lib.linkLibC();
    b.installArtifact(lib);
}

fn compileNs(b: *Build, with_utils: bool, static_options: LibraryOptions) void {
    const lib = b.addLibrary(static_options);
    lib.addIncludePath(b.path("lib"));
    // DEPENDENCIES "core"
    lib.addCSourceFiles(.{
        .files = &core_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &ports_src,
        .flags = &cflags_ports,
    });
    lib.addCSourceFiles(.{
        .files = &ns_src,
        .flags = &cflags,
    });
    if (with_utils) lib.addCSourceFiles(.{
        .files = &utils_src,
        .flags = &cflags,
    });
    lib.linkLibC();
    b.installArtifact(lib);
}

fn compilePorts(b: *Build, with_utils: bool, static_options: LibraryOptions) void {
    const lib = b.addLibrary(static_options);
    lib.addIncludePath(b.path("lib"));
    lib.addCSourceFiles(.{
        .files = &ports_src,
        .flags = &cflags_ports,
    });
    if (with_utils) lib.addCSourceFiles(.{
        .files = &utils_src,
        .flags = &cflags,
    });
    lib.linkLibC();
    b.installArtifact(lib);
}

fn compilePunycode(b: *Build, with_utils: bool, static_options: LibraryOptions) void {
    const lib = b.addLibrary(static_options);
    lib.addIncludePath(b.path("lib"));
    // DEPENDENCIES "core encoding"
    lib.addCSourceFiles(.{
        .files = &core_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &ports_src,
        .flags = &cflags_ports,
    });
    lib.addCSourceFiles(.{
        .files = &encoding_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &punycode_src,
        .flags = &cflags,
    });
    if (with_utils) lib.addCSourceFiles(.{
        .files = &utils_src,
        .flags = &cflags,
    });
    lib.linkLibC();
    b.installArtifact(lib);
}

fn compileSelectors(b: *Build, with_utils: bool, static_options: LibraryOptions) void {
    const lib = b.addLibrary(static_options);
    lib.addIncludePath(b.path("lib"));
    // DEPENDENCIES "core dom css tag ns"
    lib.addCSourceFiles(.{
        .files = &core_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &ports_src,
        .flags = &cflags_ports,
    });
    lib.addCSourceFiles(.{
        .files = &dom_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &css_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &tag_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &ns_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &selectors_src,
        .flags = &cflags,
    });
    if (with_utils) lib.addCSourceFiles(.{
        .files = &utils_src,
        .flags = &cflags,
    });
    lib.linkLibC();
    b.installArtifact(lib);
}

fn compileTag(b: *Build, with_utils: bool, static_options: LibraryOptions) void {
    const lib = b.addLibrary(static_options);
    lib.addIncludePath(b.path("lib"));
    // DEPENDENCIES "core"
    lib.addCSourceFiles(.{
        .files = &core_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &ports_src,
        .flags = &cflags_ports,
    });
    lib.addCSourceFiles(.{
        .files = &tag_src,
        .flags = &cflags,
    });
    if (with_utils) lib.addCSourceFiles(.{
        .files = &utils_src,
        .flags = &cflags,
    });
    lib.linkLibC();
    b.installArtifact(lib);
}

fn compileUnicode(b: *Build, with_utils: bool, static_options: LibraryOptions) void {
    const lib = b.addLibrary(static_options);
    lib.addIncludePath(b.path("lib"));
    // DEPENDENCIES "core encoding punycode"
    lib.addCSourceFiles(.{
        .files = &core_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &ports_src,
        .flags = &cflags_ports,
    });
    lib.addCSourceFiles(.{
        .files = &encoding_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &punycode_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &unicode_src,
        .flags = &cflags,
    });
    if (with_utils) lib.addCSourceFiles(.{
        .files = &utils_src,
        .flags = &cflags,
    });
    lib.linkLibC();
    b.installArtifact(lib);
}

fn compileUrl(b: *Build, with_utils: bool, static_options: LibraryOptions) void {
    const lib = b.addLibrary(static_options);
    lib.addIncludePath(b.path("lib"));
    // DEPENDENCIES "core encoding unicode punycode"
    lib.addCSourceFiles(.{
        .files = &core_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &ports_src,
        .flags = &cflags_ports,
    });
    lib.addCSourceFiles(.{
        .files = &encoding_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &unicode_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &punycode_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &url_src,
        .flags = &cflags,
    });
    if (with_utils) lib.addCSourceFiles(.{
        .files = &utils_src,
        .flags = &cflags,
    });
    lib.linkLibC();
    b.installArtifact(lib);
}

fn compileUtils(b: *Build, static_options: LibraryOptions) void {
    const lib = b.addLibrary(static_options);
    lib.addIncludePath(b.path("lib"));
    // DEPENDENCIES "core"
    lib.addCSourceFiles(.{
        .files = &core_src,
        .flags = &cflags,
    });
    lib.addCSourceFiles(.{
        .files = &ports_src,
        .flags = &cflags_ports,
    });
    lib.addCSourceFiles(.{
        .files = &utils_src,
        .flags = &cflags,
    });
    lib.linkLibC();
    b.installArtifact(lib);
}

fn compileSingle(b: *Build, with_utils: bool, static_options: LibraryOptions) void {
    const lib = b.addLibrary(static_options);
    lib.addIncludePath(b.path("lib"));
    // core
    lib.addCSourceFiles(.{
        .files = &core_src,
        .flags = &cflags,
    });
    // css
    lib.addCSourceFiles(.{
        .files = &css_src,
        .flags = &cflags,
    });
    // dom
    lib.addCSourceFiles(.{
        .files = &dom_src,
        .flags = &cflags,
    });
    // encoding
    lib.addCSourceFiles(.{
        .files = &encoding_src,
        .flags = &cflags,
    });
    // html
    lib.addCSourceFiles(.{
        .files = &html_src,
        .flags = &cflags,
    });
    // ns
    lib.addCSourceFiles(.{
        .files = &ns_src,
        .flags = &cflags,
    });
    // ports
    lib.addCSourceFiles(.{
        .files = &ports_src,
        .flags = &cflags_ports,
    });
    // punycode
    lib.addCSourceFiles(.{
        .files = &punycode_src,
        .flags = &cflags,
    });
    // selectors
    lib.addCSourceFiles(.{
        .files = &selectors_src,
        .flags = &cflags,
    });
    // tag
    lib.addCSourceFiles(.{
        .files = &tag_src,
        .flags = &cflags,
    });
    // unicode
    lib.addCSourceFiles(.{
        .files = &unicode_src,
        .flags = &cflags,
    });
    // url
    lib.addCSourceFiles(.{
        .files = &url_src,
        .flags = &cflags,
    });
    // utils
    if (with_utils) lib.addCSourceFiles(.{
        .files = &utils_src,
        .flags = &cflags,
    });
    lib.linkLibC();
    b.installArtifact(lib);
}

const cflags = [_][]const u8{
    "-DLEXBOR_STATIC",
    "-std=c99",
    "-fno-sanitize=undefined",
};

const cflags_ports = [_][]const u8{
    "-DLEXBOR_STATIC",
    "-Wall",
    "-pedantic",
    "-pipe",
    "-std=c99",
    "-fno-sanitize=undefined",
};

const core_src = [_][]const u8{
    "lib/lexbor/core/array.c",
    "lib/lexbor/core/array_obj.c",
    "lib/lexbor/core/avl.c",
    "lib/lexbor/core/bst.c",
    "lib/lexbor/core/bst_map.c",
    "lib/lexbor/core/conv.c",
    "lib/lexbor/core/diyfp.c",
    "lib/lexbor/core/dobject.c",
    "lib/lexbor/core/dtoa.c",
    "lib/lexbor/core/hash.c",
    "lib/lexbor/core/in.c",
    "lib/lexbor/core/mem.c",
    "lib/lexbor/core/mraw.c",
    "lib/lexbor/core/plog.c",
    "lib/lexbor/core/print.c",
    "lib/lexbor/core/serialize.c",
    "lib/lexbor/core/shs.c",
    "lib/lexbor/core/str.c",
    "lib/lexbor/core/strtod.c",
    "lib/lexbor/core/utils.c",
};

const css_src = [_][]const u8{
    "lib/lexbor/css/at_rule/state.c",
    "lib/lexbor/css/at_rule.c",
    "lib/lexbor/css/css.c",
    "lib/lexbor/css/declaration.c",
    "lib/lexbor/css/log.c",
    "lib/lexbor/css/parser.c",
    "lib/lexbor/css/property/state.c",
    "lib/lexbor/css/property.c",
    "lib/lexbor/css/rule.c",
    "lib/lexbor/css/selectors/pseudo.c",
    "lib/lexbor/css/selectors/pseudo_state.c",
    "lib/lexbor/css/selectors/selector.c",
    "lib/lexbor/css/selectors/selectors.c",
    "lib/lexbor/css/selectors/state.c",
    "lib/lexbor/css/state.c",
    "lib/lexbor/css/stylesheet.c",
    "lib/lexbor/css/syntax/anb.c",
    "lib/lexbor/css/syntax/parser.c",
    "lib/lexbor/css/syntax/state.c",
    "lib/lexbor/css/syntax/syntax.c",
    "lib/lexbor/css/syntax/token.c",
    "lib/lexbor/css/syntax/tokenizer/error.c",
    "lib/lexbor/css/syntax/tokenizer.c",
    "lib/lexbor/css/unit.c",
    "lib/lexbor/css/value.c",
};

const dom_src = [_][]const u8{
    "lib/lexbor/dom/collection.c",
    "lib/lexbor/dom/exception.c",
    "lib/lexbor/dom/interface.c",
    "lib/lexbor/dom/interfaces/attr.c",
    "lib/lexbor/dom/interfaces/cdata_section.c",
    "lib/lexbor/dom/interfaces/character_data.c",
    "lib/lexbor/dom/interfaces/comment.c",
    "lib/lexbor/dom/interfaces/document.c",
    "lib/lexbor/dom/interfaces/document_fragment.c",
    "lib/lexbor/dom/interfaces/document_type.c",
    "lib/lexbor/dom/interfaces/element.c",
    "lib/lexbor/dom/interfaces/event_target.c",
    "lib/lexbor/dom/interfaces/node.c",
    "lib/lexbor/dom/interfaces/processing_instruction.c",
    "lib/lexbor/dom/interfaces/shadow_root.c",
    "lib/lexbor/dom/interfaces/text.c",
};

const encoding_src = [_][]const u8{
    "lib/lexbor/encoding/big5.c",
    "lib/lexbor/encoding/decode.c",
    "lib/lexbor/encoding/encode.c",
    "lib/lexbor/encoding/encoding.c",
    "lib/lexbor/encoding/euc_kr.c",
    "lib/lexbor/encoding/gb18030.c",
    "lib/lexbor/encoding/iso_2022_jp_katakana.c",
    "lib/lexbor/encoding/jis0208.c",
    "lib/lexbor/encoding/jis0212.c",
    "lib/lexbor/encoding/range.c",
    "lib/lexbor/encoding/res.c",
    "lib/lexbor/encoding/single.c",
};

const html_src = [_][]const u8{
    "lib/lexbor/html/encoding.c",
    "lib/lexbor/html/interface.c",
    "lib/lexbor/html/interfaces/anchor_element.c",
    "lib/lexbor/html/interfaces/area_element.c",
    "lib/lexbor/html/interfaces/audio_element.c",
    "lib/lexbor/html/interfaces/base_element.c",
    "lib/lexbor/html/interfaces/body_element.c",
    "lib/lexbor/html/interfaces/br_element.c",
    "lib/lexbor/html/interfaces/button_element.c",
    "lib/lexbor/html/interfaces/canvas_element.c",
    "lib/lexbor/html/interfaces/d_list_element.c",
    "lib/lexbor/html/interfaces/data_element.c",
    "lib/lexbor/html/interfaces/data_list_element.c",
    "lib/lexbor/html/interfaces/details_element.c",
    "lib/lexbor/html/interfaces/dialog_element.c",
    "lib/lexbor/html/interfaces/directory_element.c",
    "lib/lexbor/html/interfaces/div_element.c",
    "lib/lexbor/html/interfaces/document.c",
    "lib/lexbor/html/interfaces/element.c",
    "lib/lexbor/html/interfaces/embed_element.c",
    "lib/lexbor/html/interfaces/field_set_element.c",
    "lib/lexbor/html/interfaces/font_element.c",
    "lib/lexbor/html/interfaces/form_element.c",
    "lib/lexbor/html/interfaces/frame_element.c",
    "lib/lexbor/html/interfaces/frame_set_element.c",
    "lib/lexbor/html/interfaces/head_element.c",
    "lib/lexbor/html/interfaces/heading_element.c",
    "lib/lexbor/html/interfaces/hr_element.c",
    "lib/lexbor/html/interfaces/html_element.c",
    "lib/lexbor/html/interfaces/iframe_element.c",
    "lib/lexbor/html/interfaces/image_element.c",
    "lib/lexbor/html/interfaces/input_element.c",
    "lib/lexbor/html/interfaces/label_element.c",
    "lib/lexbor/html/interfaces/legend_element.c",
    "lib/lexbor/html/interfaces/li_element.c",
    "lib/lexbor/html/interfaces/link_element.c",
    "lib/lexbor/html/interfaces/map_element.c",
    "lib/lexbor/html/interfaces/marquee_element.c",
    "lib/lexbor/html/interfaces/media_element.c",
    "lib/lexbor/html/interfaces/menu_element.c",
    "lib/lexbor/html/interfaces/meta_element.c",
    "lib/lexbor/html/interfaces/meter_element.c",
    "lib/lexbor/html/interfaces/mod_element.c",
    "lib/lexbor/html/interfaces/o_list_element.c",
    "lib/lexbor/html/interfaces/object_element.c",
    "lib/lexbor/html/interfaces/opt_group_element.c",
    "lib/lexbor/html/interfaces/option_element.c",
    "lib/lexbor/html/interfaces/output_element.c",
    "lib/lexbor/html/interfaces/paragraph_element.c",
    "lib/lexbor/html/interfaces/param_element.c",
    "lib/lexbor/html/interfaces/picture_element.c",
    "lib/lexbor/html/interfaces/pre_element.c",
    "lib/lexbor/html/interfaces/progress_element.c",
    "lib/lexbor/html/interfaces/quote_element.c",
    "lib/lexbor/html/interfaces/script_element.c",
    "lib/lexbor/html/interfaces/select_element.c",
    "lib/lexbor/html/interfaces/slot_element.c",
    "lib/lexbor/html/interfaces/source_element.c",
    "lib/lexbor/html/interfaces/span_element.c",
    "lib/lexbor/html/interfaces/style_element.c",
    "lib/lexbor/html/interfaces/table_caption_element.c",
    "lib/lexbor/html/interfaces/table_cell_element.c",
    "lib/lexbor/html/interfaces/table_col_element.c",
    "lib/lexbor/html/interfaces/table_element.c",
    "lib/lexbor/html/interfaces/table_row_element.c",
    "lib/lexbor/html/interfaces/table_section_element.c",
    "lib/lexbor/html/interfaces/template_element.c",
    "lib/lexbor/html/interfaces/text_area_element.c",
    "lib/lexbor/html/interfaces/time_element.c",
    "lib/lexbor/html/interfaces/title_element.c",
    "lib/lexbor/html/interfaces/track_element.c",
    "lib/lexbor/html/interfaces/u_list_element.c",
    "lib/lexbor/html/interfaces/unknown_element.c",
    "lib/lexbor/html/interfaces/video_element.c",
    "lib/lexbor/html/interfaces/window.c",
    "lib/lexbor/html/node.c",
    "lib/lexbor/html/parser.c",
    "lib/lexbor/html/serialize.c",
    "lib/lexbor/html/style.c",
    "lib/lexbor/html/token.c",
    "lib/lexbor/html/token_attr.c",
    "lib/lexbor/html/tokenizer/error.c",
    "lib/lexbor/html/tokenizer/state.c",
    "lib/lexbor/html/tokenizer/state_comment.c",
    "lib/lexbor/html/tokenizer/state_doctype.c",
    "lib/lexbor/html/tokenizer/state_rawtext.c",
    "lib/lexbor/html/tokenizer/state_rcdata.c",
    "lib/lexbor/html/tokenizer/state_script.c",
    "lib/lexbor/html/tokenizer.c",
    "lib/lexbor/html/tree/active_formatting.c",
    "lib/lexbor/html/tree/error.c",
    "lib/lexbor/html/tree/insertion_mode/after_after_body.c",
    "lib/lexbor/html/tree/insertion_mode/after_after_frameset.c",
    "lib/lexbor/html/tree/insertion_mode/after_body.c",
    "lib/lexbor/html/tree/insertion_mode/after_frameset.c",
    "lib/lexbor/html/tree/insertion_mode/after_head.c",
    "lib/lexbor/html/tree/insertion_mode/before_head.c",
    "lib/lexbor/html/tree/insertion_mode/before_html.c",
    "lib/lexbor/html/tree/insertion_mode/foreign_content.c",
    "lib/lexbor/html/tree/insertion_mode/in_body.c",
    "lib/lexbor/html/tree/insertion_mode/in_caption.c",
    "lib/lexbor/html/tree/insertion_mode/in_cell.c",
    "lib/lexbor/html/tree/insertion_mode/in_column_group.c",
    "lib/lexbor/html/tree/insertion_mode/in_frameset.c",
    "lib/lexbor/html/tree/insertion_mode/in_head.c",
    "lib/lexbor/html/tree/insertion_mode/in_head_noscript.c",
    "lib/lexbor/html/tree/insertion_mode/in_row.c",
    "lib/lexbor/html/tree/insertion_mode/in_select.c",
    "lib/lexbor/html/tree/insertion_mode/in_select_in_table.c",
    "lib/lexbor/html/tree/insertion_mode/in_table.c",
    "lib/lexbor/html/tree/insertion_mode/in_table_body.c",
    "lib/lexbor/html/tree/insertion_mode/in_table_text.c",
    "lib/lexbor/html/tree/insertion_mode/in_template.c",
    "lib/lexbor/html/tree/insertion_mode/initial.c",
    "lib/lexbor/html/tree/insertion_mode/text.c",
    "lib/lexbor/html/tree/open_elements.c",
    "lib/lexbor/html/tree/template_insertion.c",
    "lib/lexbor/html/tree.c",
};

const ns_src = [_][]const u8{
    "lib/lexbor/ns/ns.c",
};

const ports_src = [_][]const u8{
    "lib/lexbor/ports/posix/lexbor/core/memory.c",
};

const punycode_src = [_][]const u8{
    "lib/lexbor/punycode/punycode.c",
};

const selectors_src = [_][]const u8{
    "lib/lexbor/selectors/selectors.c",
};

const tag_src = [_][]const u8{
    "lib/lexbor/tag/tag.c",
};

const unicode_src = [_][]const u8{
    "lib/lexbor/unicode/idna.c",
    "lib/lexbor/unicode/unicode.c",
};

const url_src = [_][]const u8{
    "lib/lexbor/url/url.c",
};

const utils_src = [_][]const u8{
    "lib/lexbor/utils/http.c",
    "lib/lexbor/utils/warc.c",
};

const Example = struct {
    name: []const u8,
    path: []const u8,
};

var examples = [_]Example{
    .{ .name = "html-document-parse", .path = "examples/html/document_parse.zig" },
    .{ .name = "html-document-parse-chunk", .path = "examples/html/document_parse_chunk.zig" },
    .{ .name = "html-document-title", .path = "examples/html/document_title.zig" },
    .{ .name = "html-element-attributes", .path = "examples/html/element_attributes.zig" },
    .{ .name = "html-element-create", .path = "examples/html/element_create.zig" },
    .{ .name = "html-element-innerHTML", .path = "examples/html/element_innerHTML.zig" },
    .{ .name = "html-elements-by-attr", .path = "examples/html/elements_by_attr.zig" },
    .{ .name = "html-elements-by-class-name", .path = "examples/html/elements_by_class_name.zig" },
    .{ .name = "html-elements-by-tag-name", .path = "examples/html/elements_by_tag_name.zig" },
    .{ .name = "html-encoding", .path = "examples/html/encoding.zig" },
    .{ .name = "html-html2sexpr", .path = "examples/html/html2sexpr.zig" },
    .{ .name = "html-parse", .path = "examples/html/parse.zig" },
    .{ .name = "html-parse-chunk", .path = "examples/html/parse_chunk.zig" },
    .{ .name = "html-tokenizer-callback", .path = "examples/html/tokenizer/callback.zig" },
    .{ .name = "html-tokenizer-simple", .path = "examples/html/tokenizer/simple.zig" },
    .{ .name = "html-tokenizer-tag-attributes", .path = "examples/html/tokenizer/tag_attributes.zig" },
    .{ .name = "html-tokenizer-text", .path = "examples/html/tokenizer/text.zig" },
};
