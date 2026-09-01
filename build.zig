const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const tracy = b.option(std.Build.LazyPath, "tracy", "Enable Tracy integration. Supply path to Tracy source");
    const tracy_on_demand = b.option(bool, "tracy-on-demand", "tracy: Enable on-demand") orelse false;
    const libadwaita = b.option(bool, "libadwaita", "Enable libadwaita") orelse false;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("tas_log_reader", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const options = b.addOptions();
    options.addOption(bool, "tracy_enable", tracy != null);
    options.addOption(bool, "tracy_on_demand", tracy_on_demand);
    mod.addOptions("build_options", options);

    if (tracy) |tracy_dir| {
        const tracy_mod = b.createModule(.{
            .target = target,
            // Always build Tracy in ReleaseFast.
            .optimize = .ReleaseFast,
            .root_source_file = null,
            .link_libc = true,
            .link_libcpp = true,
        });
        tracy_mod.addCMacro("TRACY_ENABLE", "");
        if (optimize == .ReleaseFast or optimize == .ReleaseSmall) {
            tracy_mod.addCMacro("TRACY_NO_VERIFY", "");
        }
        if (tracy_on_demand) {
            tracy_mod.addCMacro("TRACY_ON_DEMAND", "");
        }
        tracy_mod.addIncludePath(tracy_dir);
        tracy_mod.addCSourceFile(.{ .file = tracy_dir.path(b, "public/TracyClient.cpp") });
        mod.addImport("tracy", tracy_mod);
    }

    const translate_c = b.dependency("translate_c", .{});

    const t: Translator = .init(translate_c, if (libadwaita) .{
        .c_source_file = b.addWriteFiles().add("c.h",
            \\#include <adwaita.h>
        ),
        .link_system_libs = &.{.{ .name = "libadwaita-1" }},
        .target = target,
        .optimize = optimize,
    } else .{
        .c_source_file = b.addWriteFiles().add("c.h",
            \\#include <gtk/gtk.h>
        ),
        .link_system_libs = &.{.{ .name = "gtk4" }},
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "tas_log_reader",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tas_log_reader", .module = mod },
                .{ .name = "c", .module = t.mod },
            },
        }),
    });

    const exe_options = b.addOptions();
    exe_options.addOption(bool, "libadwaita", libadwaita);
    exe.root_module.addOptions("build_options", exe_options);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const bench_log = b.addExecutable(.{
        .name = "bench_log",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench_log.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tas_log_reader", .module = mod },
            },
        }),
    });
    const bench_log_install = b.addInstallArtifact(bench_log, .{});

    const bench_step = b.step("bench", "Build benchmarks");
    bench_step.dependOn(&bench_log_install.step);
}
