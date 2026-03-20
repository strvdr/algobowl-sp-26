const std = @import("std");

pub fn build(b: *std.Build) void {
    // Allow cross-compilation and optimization options via CLI:
    //   zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "algobowl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Install the executable into zig-out/bin/
    b.installArtifact(exe);

    // ---- zig build run ----
    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());

    // Forward any extra CLI args to the executable:
    //   zig build run -- arg1 arg2
    if (b.args) |args| {
        run_exe.addArgs(args);
    }

    const run_step = b.step("run", "Build and run the algo-bowl executable");
    run_step.dependOn(&run_exe.step);

    // ---- zig build test ----
    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    run_exe_unit_tests.has_side_effects = true;
    const test_step = b.step("test", "Run unit tests");
    const run_tests = b.addSystemCommand(&. {"zig", "test", "src/main.zig"});
    test_step.dependOn(&run_tests.step);
}
