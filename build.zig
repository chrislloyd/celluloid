const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create main executable
    const exe = b.addExecutable(.{
        .name = "celluloid",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add SQLite dependency
    exe.linkLibC(); // SQLite needs libc
    exe.linkSystemLibrary("sqlite3");

    // Install the executable
    b.installArtifact(exe);

    // Add run step to run the executable
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run celluloid");
    run_step.dependOn(&run_cmd.step);

    // Create git-remote-celluloid executable
    const git_remote_exe = b.addExecutable(.{
        .name = "git-remote-celluloid",
        .root_source_file = b.path("src/git_remote_celluloid.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add SQLite dependency for git-remote-celluloid
    git_remote_exe.linkLibC();
    git_remote_exe.linkSystemLibrary("sqlite3");

    // Install the git-remote-celluloid executable
    b.installArtifact(git_remote_exe);

    // Add test step
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.linkLibC();
    unit_tests.linkSystemLibrary("sqlite3");

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
