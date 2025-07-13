const std = @import("std");
const Allocator = std.mem.Allocator;

const Positionals = @import("sap").Positionals;

const root = @import("root");
const fatal = root.fatal;
const version_utils = @import("../zig_version_utils.zig");

pub fn linkZig(gpa: Allocator, bin_dir: std.fs.Dir, version_folder: []const u8) !void {
    const exe_rel_path = try std.fs.path.join(gpa, &.{ "..", "zig", version_folder, "zig" });
    defer gpa.free(exe_rel_path);

    if (bin_dir.statFile("zig") != error.FileNotFound)
        try bin_dir.deleteFile("zig");
    try bin_dir.symLink(exe_rel_path, "zig", .{});
}

pub fn execute(gpa: Allocator, positionals: *Positionals.Iterator) !void {
    const stdout = std.io.getStdOut().writer();

    const version = if (positionals.next()) |ver|
        ver
    else
        fatal("You need to specify a version", .{}, null);

    var real_version: ?[]const u8 = null;
    const directory = if (try version_utils.getVersionDirectory(gpa, root.data_dir.zig_dir, version, &real_version)) |dir|
        dir
    else
        fatal("This version isn't installed", .{}, null);
    defer if (real_version != null) gpa.free(real_version.?);
    defer gpa.free(directory);

    _ = root.data_dir.zig_dir.openDir(directory, .{}) catch |e| switch (e) {
        error.FileNotFound => fatal("This version isn't installed", .{}, null),
        else => return e,
    };

    try linkZig(gpa, root.data_dir.bin_dir, directory);

    if (real_version) |ver|
        try stdout.print("zig version changed to {s}\n", .{ver})
    else
        try stdout.print("zig version changed to {s}\n", .{version});
}

pub const HELP_MESSAGE =
    \\Usage:
    \\  zupgrade use <VERSION> [OPTIONS]
    \\
    \\Description:
    \\  Selects the zig version provided.
    \\  <VERSION> can be:
    \\      - a tagged release
    \\      - a nightly build
    \\      - "latest" to get the latest tagged release
    \\      - "master" to get the latest master build
    \\      - "." to get the version from `build.zig.zon`
    \\        or from files specified in the config file
    \\
;
