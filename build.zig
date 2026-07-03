const std = @import("std");

const version = "0.8.4";
const libs = [_][]const u8{ "X11", "Xft", "Xrender", "fontconfig", "freetype", "harfbuzz", "m", "rt", "util" };
const terminfo_entries = [_][]const u8{
    "st",
    "st-256color",
    "st-bs",
    "st-bs-256color",
    "st-meta",
    "st-meta-256color",
    "st-mono",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const install_step = b.getInstallStep();
    const sed = requireProgram(b, "sed", "生成带版本号的 manpage");
    const tic = requireProgram(b, "tic", "编译 terminfo 数据");
    const bash = requireProgram(b, "bash", "执行 ABI 符号集合核对命令");
    const pkg_config = b.graph.environ_map.get("PKG_CONFIG") orelse requireProgram(b, "pkg-config", "解析 X11、Xft、Fontconfig、HarfBuzz 等系统依赖");

    requirePkgConfigPackage(b, pkg_config, "x11", "提供 Xlib 头文件和链接参数");
    requirePkgConfigPackage(b, pkg_config, "xft", "提供 Xft 文本渲染依赖");
    requirePkgConfigPackage(b, pkg_config, "xrender", "提供 Xrender 渲染依赖");
    requirePkgConfigPackage(b, pkg_config, "fontconfig", "提供字体发现依赖");
    requirePkgConfigPackage(b, pkg_config, "freetype2", "提供 FreeType 头文件和字体渲染依赖");
    requirePkgConfigPackage(b, pkg_config, "harfbuzz", "提供 HarfBuzz 字形整形依赖");

    const root_module = b.createModule(.{
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const base64_module = b.createModule(.{
        .root_source_file = b.path("st_base64.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const utf8_module = b.createModule(.{
        .root_source_file = b.path("st_utf8.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const csi_module = b.createModule(.{
        .root_source_file = b.path("st_csi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const color_core_module = b.createModule(.{
        .root_source_file = b.path("st_color_core.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const attr_module = b.createModule(.{
        .root_source_file = b.path("st_attr.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const erase_module = b.createModule(.{
        .root_source_file = b.path("st_erase.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const cursor_module = b.createModule(.{
        .root_source_file = b.path("st_cursor.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const edit_module = b.createModule(.{
        .root_source_file = b.path("st_edit.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const state_module = b.createModule(.{
        .root_source_file = b.path("st_state.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const misc_module = b.createModule(.{
        .root_source_file = b.path("st_misc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const mode_module = b.createModule(.{
        .root_source_file = b.path("st_mode.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const strparse_module = b.createModule(.{
        .root_source_file = b.path("st_strparse.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const strhandle_module = b.createModule(.{
        .root_source_file = b.path("st_strhandle.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const putc_decode_module = b.createModule(.{
        .root_source_file = b.path("st_putc_decode.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const setchar_module = b.createModule(.{
        .root_source_file = b.path("st_setchar.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const control_esc_module = b.createModule(.{
        .root_source_file = b.path("st_control_esc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const line_module = b.createModule(.{
        .root_source_file = b.path("st_line.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const search_module = b.createModule(.{
        .root_source_file = b.path("st_search.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const selection_module = b.createModule(.{
        .root_source_file = b.path("st_selection.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const base64_obj = b.addObject(.{
        .name = "st_base64",
        .root_module = base64_module,
    });

    const utf8_obj = b.addObject(.{
        .name = "st_utf8",
        .root_module = utf8_module,
    });

    const csi_obj = b.addObject(.{
        .name = "st_csi",
        .root_module = csi_module,
    });

    const attr_obj = b.addObject(.{
        .name = "st_attr",
        .root_module = attr_module,
    });

    const erase_obj = b.addObject(.{
        .name = "st_erase",
        .root_module = erase_module,
    });

    const cursor_obj = b.addObject(.{
        .name = "st_cursor",
        .root_module = cursor_module,
    });

    const edit_obj = b.addObject(.{
        .name = "st_edit",
        .root_module = edit_module,
    });

    const state_obj = b.addObject(.{
        .name = "st_state",
        .root_module = state_module,
    });

    const misc_obj = b.addObject(.{
        .name = "st_misc",
        .root_module = misc_module,
    });

    const mode_obj = b.addObject(.{
        .name = "st_mode",
        .root_module = mode_module,
    });

    const strparse_obj = b.addObject(.{
        .name = "st_strparse",
        .root_module = strparse_module,
    });

    const strhandle_obj = b.addObject(.{
        .name = "st_strhandle",
        .root_module = strhandle_module,
    });

    const putc_decode_obj = b.addObject(.{
        .name = "st_putc_decode",
        .root_module = putc_decode_module,
    });

    const setchar_obj = b.addObject(.{
        .name = "st_setchar",
        .root_module = setchar_module,
    });

    const line_obj = b.addObject(.{
        .name = "st_line",
        .root_module = line_module,
    });

    const search_obj = b.addObject(.{
        .name = "st_search",
        .root_module = search_module,
    });

    const selection_obj = b.addObject(.{
        .name = "st_selection",
        .root_module = selection_module,
    });

    const exe = b.addExecutable(.{
        .name = "st",
        .root_module = root_module,
    });

    root_module.addObject(base64_obj);
    root_module.addObject(utf8_obj);
    root_module.addObject(csi_obj);
    root_module.addObject(attr_obj);
    root_module.addObject(erase_obj);
    root_module.addObject(cursor_obj);
    root_module.addObject(edit_obj);
    root_module.addObject(state_obj);
    root_module.addObject(misc_obj);
    root_module.addObject(mode_obj);
    root_module.addObject(strparse_obj);
    root_module.addObject(strhandle_obj);
    root_module.addObject(putc_decode_obj);
    root_module.addObject(setchar_obj);
    root_module.addObject(line_obj);
    root_module.addObject(search_obj);
    root_module.addObject(selection_obj);

    root_module.addCSourceFiles(.{
        .files = &.{ "st.c", "x.c", "boxdraw.c", "hb.c" },
        .flags = &.{
            b.fmt("-DVERSION=\"{s}\"", .{version}),
            "-D_XOPEN_SOURCE=600",
        },
    });

    for (libs) |lib_name| {
        root_module.linkSystemLibrary(lib_name, .{});
    }

    b.installArtifact(exe);

    install_step.dependOn(&b.addInstallBinFile(b.path("st-copyout"), "st-copyout").step);
    install_step.dependOn(&b.addInstallBinFile(b.path("st-copylastout"), "st-copylastout").step);
    install_step.dependOn(&b.addInstallBinFile(b.path("st-urlhandler"), "st-urlhandler").step);

    const render_manpage = b.addSystemCommand(&.{ sed, b.fmt("s/VERSION/{s}/g", .{version}) });
    render_manpage.addFileArg(b.path("st.1"));
    const manpage = render_manpage.captureStdOut(.{ .basename = "st.1" });
    install_step.dependOn(&b.addInstallFileWithDir(manpage, .prefix, "share/man/man1/st.1").step);

    const build_terminfo = b.addSystemCommand(&.{tic});
    build_terminfo.addArg("-sx");
    build_terminfo.addArg("-o");
    const terminfo_dir = build_terminfo.addOutputDirectoryArg("terminfo");
    build_terminfo.addFileArg(b.path("st.info"));

    const install_terminfo = b.addInstallDirectory(.{
        .source_dir = terminfo_dir,
        .install_dir = .prefix,
        .install_subdir = "share/terminfo",
    });
    install_step.dependOn(&install_terminfo.step);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run st");
    run_step.dependOn(&run_cmd.step);

    const terminfo_step = b.step("terminfo", "Install compiled terminfo under prefix");
    terminfo_step.dependOn(&install_terminfo.step);

    const clean_install_step = b.step("clean-install", "Remove files installed by this project from the current prefix");
    clean_install_step.makeFn = makeCleanInstall;

    const abi_check = b.addSystemCommand(&.{
        bash,
        "-lc",
        "diff -u <(rg -o '^export fn st_[A-Za-z0-9_]+' --glob '*.zig' | sed 's/.*export fn //' | sort) <(rg -o 'st_[A-Za-z0-9_]+\\(' st_zig.h | sed 's/(//' | sort)",
    });
    const abi_guard = b.addSystemCommand(&.{
        bash,
        "-lc",
        "forbidden=$(rg -n 'st_plan[A-Za-z0-9_]*' st_zig.h st.c *.zig || true); test -z \"$forbidden\"; diff -u <(rg --no-filename -o '^export fn st_[A-Za-z0-9_]+' --glob '*.zig' | sed 's/.*export fn //' | sort) <(rg --no-filename -o 'st_[A-Za-z0-9_]+\\(' st.c x.c hb.c boxdraw.c st.h win.h config.h hb.h arg.h boxdraw_data.h | sed 's/(//' | sort -u)",
    });
    const abi_check_step = b.step("abi-check", "Verify Zig export symbols match st_zig.h declarations");
    abi_check_step.dependOn(&abi_check.step);
    abi_check_step.dependOn(&abi_guard.step);

    const test_step = addZigTests(b, &.{
        .{ .name = "st_base64_test", .module = base64_module },
        .{ .name = "st_utf8_test", .module = utf8_module },
        .{ .name = "st_csi_test", .module = csi_module },
        .{ .name = "st_color_core_test", .module = color_core_module },
        .{ .name = "st_attr_test", .module = attr_module },
        .{ .name = "st_erase_test", .module = erase_module },
        .{ .name = "st_cursor_test", .module = cursor_module },
        .{ .name = "st_edit_test", .module = edit_module },
        .{ .name = "st_state_test", .module = state_module },
        .{ .name = "st_misc_test", .module = misc_module },
        .{ .name = "st_mode_test", .module = mode_module },
        .{ .name = "st_strparse_test", .module = strparse_module },
        .{ .name = "st_strhandle_test", .module = strhandle_module },
        .{ .name = "st_putc_decode_test", .module = putc_decode_module },
        .{ .name = "st_control_esc_test", .module = control_esc_module },
        .{ .name = "st_setchar_test", .module = setchar_module },
        .{ .name = "st_line_test", .module = line_module },
        .{ .name = "st_search_test", .module = search_module },
        .{ .name = "st_selection_test", .module = selection_module },
    });

    // C-side harness test for tcommitputcwrite
    addCHarnessTest(b, target, optimize, test_step);
}

const ZigTestModule = struct {
    name: []const u8,
    module: *std.Build.Module,
};

fn addZigTests(b: *std.Build, modules: []const ZigTestModule) *std.Build.Step {
    const test_step = b.step("test", "Run Zig unit tests");
    for (modules) |module| {
        const test_artifact = b.addTest(.{
            .name = module.name,
            .root_module = module.module,
        });
        const run_test = b.addRunArtifact(test_artifact);
        test_step.dependOn(&run_test.step);
    }
    return test_step;
}

fn addCHarnessTest(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, test_step: *std.Build.Step) void {
    const harness_module = b.createModule(.{
        .root_source_file = b.path("st_c_harness_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    harness_module.addCSourceFiles(.{
        .files = &.{"st_c_harness.c"},
        .flags = &.{},
    });
    harness_module.addIncludePath(b.path("."));

    const test_artifact = b.addTest(.{
        .name = "st_c_harness_test",
        .root_module = harness_module,
    });
    const run_test = b.addRunArtifact(test_artifact);
    test_step.dependOn(&run_test.step);
}

fn requireProgram(b: *std.Build, name: []const u8, reason: []const u8) []const u8 {
    return b.findProgram(&.{name}, &.{}) catch {
        std.process.fatal(
            "缺少构建工具 `{s}`。\n用途: {s}\n验证命令: `command -v {s}`\n安装后重试 `zig build`。",
            .{ name, reason, name },
        );
    };
}

fn requirePkgConfigPackage(b: *std.Build, pkg_config: []const u8, pkg_name: []const u8, reason: []const u8) void {
    var exit_code: u8 = 0;
    const stdout = b.runAllowFail(&.{ pkg_config, "--exists", pkg_name }, &exit_code, .ignore) catch |err| switch (err) {
        error.ExitCodeFailure => std.process.fatal(
            "缺少 pkg-config 包 `{s}`。\n用途: {s}\n验证命令: `{s} --modversion {s}`\n请安装对应的开发包后重试。",
            .{ pkg_name, reason, pkg_config, pkg_name },
        ),
        error.FileNotFound, error.InvalidName => std.process.fatal(
            "无法执行 pkg-config 命令 `{s}`。\n如果设置了 `PKG_CONFIG` 环境变量，请确认它指向有效可执行文件。",
            .{pkg_config},
        ),
        error.ProcessTerminated => std.process.fatal(
            "pkg-config 在检查 `{s}` 时异常终止。\n执行命令: `{s} --exists {s}`",
            .{ pkg_name, pkg_config, pkg_name },
        ),
        else => std.process.fatal(
            "检查 pkg-config 包 `{s}` 失败: {t}",
            .{ pkg_name, err },
        ),
    };
    b.allocator.free(stdout);
}

fn makeCleanInstall(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
    _ = options;
    const b = step.owner;
    const cwd = std.Io.Dir.cwd();

    deleteInstallFile(step, cwd, b.getInstallPath(.bin, "st"));
    deleteInstallFile(step, cwd, b.getInstallPath(.bin, "st-copyout"));
    deleteInstallFile(step, cwd, b.getInstallPath(.bin, "st-copylastout"));
    deleteInstallFile(step, cwd, b.getInstallPath(.bin, "st-urlhandler"));
    deleteInstallFile(step, cwd, b.getInstallPath(.prefix, "share/man/man1/st.1"));

    for (terminfo_entries) |name| {
        deleteInstallFile(step, cwd, b.getInstallPath(.prefix, b.fmt("share/terminfo/s/{s}", .{name})));
    }

    deleteInstallDirIfEmpty(step, cwd, b.getInstallPath(.prefix, "share/terminfo/s"));
    deleteInstallDirIfEmpty(step, cwd, b.getInstallPath(.prefix, "share/terminfo"));
    deleteInstallDirIfEmpty(step, cwd, b.getInstallPath(.prefix, "share/man/man1"));
    deleteInstallDirIfEmpty(step, cwd, b.getInstallPath(.prefix, "share/man"));
    deleteInstallDirIfEmpty(step, cwd, b.getInstallPath(.prefix, "share"));
    deleteInstallDirIfEmpty(step, cwd, b.getInstallPath(.bin, ""));
}

fn deleteInstallFile(step: *std.Build.Step, cwd: std.Io.Dir, path: []const u8) void {
    const io = step.owner.graph.io;
    cwd.deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.process.fatal("删除安装文件失败 `{s}`: {t}", .{ path, err }),
    };
}

fn deleteInstallDirIfEmpty(step: *std.Build.Step, cwd: std.Io.Dir, path: []const u8) void {
    const io = step.owner.graph.io;
    cwd.deleteDir(io, path) catch |err| switch (err) {
        error.FileNotFound, error.DirNotEmpty => {},
        else => std.process.fatal("删除安装目录失败 `{s}`: {t}", .{ path, err }),
    };
}
