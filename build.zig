const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("net", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_check = b.addExecutable(.{
        .name = "net_check",
        .root_module = lib_mod,
    });

    const check = b.step("check", "check if app compiles");
    check.dependOn(&exe_check.step);

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "net",
        .root_module = lib_mod,
    });

    lib.linkLibC();

    b.installArtifact(lib);

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
