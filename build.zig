const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "st",
        .root_module = root_module,
    });

    root_module.addCSourceFiles(.{
        .files = &.{ "st.c", "x.c", "boxdraw.c", "hb.c" },
        .flags = &.{
            "-DVERSION=\"0.8.4\"",
            "-D_XOPEN_SOURCE=600",
        },
    });

    root_module.linkSystemLibrary("X11", .{});
    root_module.linkSystemLibrary("Xft", .{});
    root_module.linkSystemLibrary("Xrender", .{});
    root_module.linkSystemLibrary("fontconfig", .{});
    root_module.linkSystemLibrary("freetype", .{});
    root_module.linkSystemLibrary("harfbuzz", .{});
    root_module.linkSystemLibrary("m", .{});
    root_module.linkSystemLibrary("rt", .{});
    root_module.linkSystemLibrary("util", .{});

    root_module.addIncludePath(.{ .cwd_relative = "/usr/include/freetype2" });
    root_module.addIncludePath(.{ .cwd_relative = "/usr/include/libpng16" });
    root_module.addIncludePath(.{ .cwd_relative = "/usr/include/harfbuzz" });
    root_module.addIncludePath(.{ .cwd_relative = "/usr/include/glib-2.0" });
    root_module.addIncludePath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu/glib-2.0/include" });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run st");
    run_step.dependOn(&run_cmd.step);
}
