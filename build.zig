const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zupgrade",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const sap = b.dependency("sap", .{});
    exe.root_module.addImport("sap", sap.module("sap"));

    const known_folders = b.dependency("known-folders", .{});
    exe.root_module.addImport("known-folders", known_folders.module("known-folders"));

    const minizign = b.dependency("minizign", .{});
    exe.root_module.addImport("minizign", minizign.module("minizign"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
