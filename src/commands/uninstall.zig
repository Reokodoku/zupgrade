const std = @import("std");
const Allocator = std.mem.Allocator;

const Positionals = @import("sap").Positionals;

const version_utils = @import("../zig_version_utils.zig");
const root = @import("root");
const fatal = root.fatal;

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

    var read_link_buffer = std.mem.zeroes([(24 + 12) + 20]u8);
    const current_zig = root.data_dir.bin_dir.readLink("zig", &read_link_buffer) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };

    if (current_zig) |current| {
        var path = std.mem.splitBackwardsScalar(u8, current, std.fs.path.sep);
        _ = path.next(); // `zig` exe

        const current_zig_path = path.next().?;
        const zig_path = if (real_version) |ver|
            try version_utils.folderFromVersion(gpa, ver)
        else
            try version_utils.folderFromVersion(gpa, version);
        defer gpa.free(zig_path);

        if (std.mem.eql(u8, current_zig_path, zig_path))
            try root.data_dir.bin_dir.deleteFile("zig");
    }

    try root.data_dir.zig_dir.deleteTree(directory);

    if (real_version) |ver|
        try stdout.print("Uninstalled zig version {s}\n", .{ver})
    else
        try stdout.print("Uninstalled zig version {s}\n", .{version});
}

pub const HELP_MESSAGE =
    \\Usage:
    \\  zupgrade uninstall <VERSION> [OPTIONS]
    \\
    \\Description:
    \\  Uninstalls the zig version provided.
    \\  <VERSION> can be:
    \\      - a tagged release
    \\      - a nightly build
    \\      - "latest" to get the latest tagged release
    \\      - "master" to get the latest master build
    \\      - "." to get the version from `build.zig.zon`
    \\        or from files specified in the config file
    \\
;
