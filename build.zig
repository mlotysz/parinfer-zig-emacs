const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Shared library for Emacs module
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "parinfer_rust",
        .root_module = lib_mod,
    });
    lib.linkLibC();
    b.installArtifact(lib);

    // Tests
    // Generate a data module that embeds test JSON files (they live outside src/)
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(b.path("tests/cases/indent-mode.json"), "indent-mode.json");
    _ = wf.addCopyFile(b.path("tests/cases/paren-mode.json"), "paren-mode.json");
    _ = wf.addCopyFile(b.path("tests/cases/smart-mode.json"), "smart-mode.json");
    const test_data_zig = wf.add("test_data.zig",
        \\pub const indent_mode = @embedFile("indent-mode.json");
        \\pub const paren_mode = @embedFile("paren-mode.json");
        \\pub const smart_mode = @embedFile("smart-mode.json");
        \\
    );
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_parinfer.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addAnonymousImport("test_data", .{ .root_source_file = test_data_zig });
    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run parinfer tests");
    test_step.dependOn(&run_tests.step);

    // Emacs integration test
    const emacs_test = b.addSystemCommand(&.{
        "emacs", "--batch", "-l", "tests/emacs-integration.el",
    });
    emacs_test.step.dependOn(b.getInstallStep());
    const emacs_test_step = b.step("test-emacs", "Run Emacs integration tests");
    emacs_test_step.dependOn(&emacs_test.step);
}
