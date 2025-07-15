const builtin = @import("builtin");
const std = @import("std");

const Positionals = @import("sap").Positionals;

const root = @import("root");
const fatal = root.fatal;
const version_utils = @import("../zig_version_utils.zig");
const AppContext = @import("../AppContext.zig");

pub fn execute(ctx: *const AppContext, positionals: *Positionals.Iterator) !void {
    const stdout = std.io.getStdOut().writer();

    const user_version = if (positionals.next()) |ver|
        ver
    else
        fatal("You need to specify a version", .{}, null);

    const version = if (try version_utils.getVersionDirectory(ctx.gpa, ctx.zig_dir, user_version)) |dir|
        dir
    else
        fatal("This version isn't installed", .{}, null);
    defer ctx.gpa.free(version);

    _ = ctx.zig_dir.openDir(version, .{}) catch |e| switch (e) {
        error.FileNotFound => fatal("This version isn't installed", .{}, null),
        else => return e,
    };

    const current_zig = try root.getCurrentZigVersion(ctx.gpa, ctx.bin_dir);
    defer if (current_zig) |cur| ctx.gpa.free(cur);

    if (current_zig) |current| {
        if (std.mem.eql(u8, version, current))
            try ctx.bin_dir.deleteFile(if (builtin.os.tag == .windows) "zig.exe" else "zig");
    }

    try ctx.zig_dir.deleteTree(version);

    var ver_split = std.mem.splitBackwardsScalar(u8, version, '-');
    try stdout.print("Uninstalled zig version {s}\n", .{ver_split.first()});
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
