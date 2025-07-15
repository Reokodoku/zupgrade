const builtin = @import("builtin");
const std = @import("std");

const known_folders = @import("known-folders");
const Positionals = @import("sap").Positionals;

const root = @import("root");
const fatal = root.fatal;
const version_utils = @import("../zig_version_utils.zig");
const AppContext = @import("../AppContext.zig");

/// On Windows we can't use a batch file as a reliable wrapper (for example the zig VSCode
/// extension doesn't run the batch file). We need a real executable.
/// So, we write a small wrapper in C and compile it using Zig's built-in C compiler.
fn compileWindowsZigWrapper(ctx: *const AppContext, zig_exe: []const u8) !void {
    var cache = try known_folders.open(ctx.gpa, .cache, .{}) orelse @panic("Error when opening cache dir");
    defer cache.close();

    const c_file_name: []const u8 = "__zupgrade_windows_zig_wrapper.c";
    {
        const c_file = try cache.createFile(c_file_name, .{});
        defer c_file.close();

        try c_file.writeAll(@embedFile("../windows_zig_wrapper.c"));
    }
    defer cache.deleteFile(c_file_name) catch @panic("Unable to delete a cache file");

    const zupgrade_path_escaped = try std.mem.replaceOwned(u8, ctx.gpa, ctx.data_path, "\\", "\\\\");
    defer ctx.gpa.free(zupgrade_path_escaped);
    const define_zupgrade_path = try std.fmt.allocPrint(ctx.gpa, "ZUPGRADE_PATH=\"{s}\"", .{zupgrade_path_escaped});
    defer ctx.gpa.free(define_zupgrade_path);

    const c_file_path = try cache.realpathAlloc(ctx.gpa, c_file_name);
    defer ctx.gpa.free(c_file_path);

    const compiled_dest = try std.fs.path.join(ctx.gpa, &.{ ctx.data_path, "bin", "zig.exe" });
    defer ctx.gpa.free(compiled_dest);

    var cc = std.process.Child.init(&.{ zig_exe, "cc", "-D", define_zupgrade_path, c_file_path, "-o", compiled_dest }, ctx.gpa);
    switch (try cc.spawnAndWait()) {
        .Exited => |c| if (c != 0)
            fatal("COMPILATION ERROR on zig wrapper for windows (exit code: {d})", .{c}, null),
        else => |d| fatal("Error when compiling zig wrapper for windows ({any})", .{d}, null),
    }
}

fn linkZig(ctx: *const AppContext, version_folder: []const u8) !void {
    const exe_rel_path = try std.fs.path.join(ctx.gpa, &.{ "..", "zig", version_folder, "zig" });
    defer ctx.gpa.free(exe_rel_path);

    if (ctx.bin_dir.statFile("zig") != error.FileNotFound)
        try ctx.bin_dir.deleteFile("zig");
    try ctx.bin_dir.symLink(exe_rel_path, "zig", .{});
}

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

    var zig_dir = ctx.zig_dir.openDir(version, .{}) catch |e| switch (e) {
        error.FileNotFound => fatal("This version isn't installed", .{}, null),
        else => return e,
    };
    defer zig_dir.close();

    if (builtin.os.tag == .windows) {
        const current_zig_version = ctx.bin_dir.openFile("current_zig_version", .{ .mode = .write_only }) catch |e| switch (e) {
            error.FileNotFound => try ctx.bin_dir.createFile("current_zig_version", .{}),
            else => return e,
        };
        defer current_zig_version.close();

        try current_zig_version.writeAll(version);

        _ = ctx.bin_dir.statFile("zig.exe") catch |e| switch (e) {
            error.FileNotFound => {
                const zig_exe = try zig_dir.realpathAlloc(ctx.gpa, "zig.exe");
                defer ctx.gpa.free(zig_exe);
                try compileWindowsZigWrapper(ctx, zig_exe);
            },
            else => return e,
        };
    } else {
        try linkZig(ctx, version);
    }

    var ver_split = std.mem.splitBackwardsScalar(u8, version, '-');
    try stdout.print("zig version changed to {s}\n", .{ver_split.first()});
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
