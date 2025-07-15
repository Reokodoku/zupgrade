const std = @import("std");
const known_folders = @import("known-folders");

const Config = @import("Config.zig");

const Self = @This();

gpa: std.mem.Allocator,
path: []const u8,
config: Config,

bin_dir: std.fs.Dir,
zig_dir: std.fs.Dir,
tools_dir: std.fs.Dir,

pub fn init(gpa: std.mem.Allocator, exe_name: []const u8) !Self {
    var data_dir_created = false;

    const data_dir_path: []const u8 = blk: {
        break :blk std.process.getEnvVarOwned(gpa, "ZUPGRADE_DATA_DIR") catch |e| switch (e) {
            error.EnvironmentVariableNotFound => {
                const home = try known_folders.getPath(gpa, .home) orelse @panic("Error when opening home dir");
                defer gpa.free(home);
                break :blk try std.fs.path.join(gpa, &.{ home, ".zupgrade" });
            },
            else => return e,
        };
    };

    var data_dir: std.fs.Dir = blk: {
        break :blk std.fs.cwd().openDir(data_dir_path, .{}) catch |e| switch (e) {
            error.FileNotFound => {
                try std.fs.makeDirAbsolute(data_dir_path);
                data_dir_created = true;
                break :blk try std.fs.openDirAbsolute(data_dir_path, .{});
            },
            else => return e,
        };
    };
    defer data_dir.close();

    for ([_][]const u8{
        "bin",
        "zig",
        "tools",
    }) |dir| {
        _ = data_dir.openDir(dir, .{}) catch |e| switch (e) {
            error.FileNotFound => try data_dir.makeDir(dir),
            else => return e,
        };
    }

    const config: Config = blk: {
        const config_file = data_dir.openFile("config.zon", .{}) catch |e| switch (e) {
            error.FileNotFound => break :blk .{},
            else => return e,
        };
        defer config_file.close();

        const stat = try config_file.stat();
        const data = try config_file.readToEndAllocOptions(gpa, stat.size, stat.size, @alignOf(u8), 0);
        defer gpa.free(data);

        break :blk try std.zon.parse.fromSlice(Config, gpa, data, null, .{});
    };

    if (data_dir_created) {
        try std.io.getStdOut().writer().print(
            \\You have successfully installed zupgrade!
            \\
            \\To be able to use zupgrade, you must put in your `PATH` env
            \\{s}{c}bin
            \\
            \\Then to get started you can execute `{s} --help`!
            \\
        , .{ data_dir_path, std.fs.path.sep, exe_name });
        std.process.exit(0);
    }

    return .{
        .gpa = gpa,
        .path = data_dir_path,
        .config = config,

        .bin_dir = try data_dir.openDir("bin", .{}),
        .zig_dir = try data_dir.openDir("zig", .{ .iterate = true }),
        .tools_dir = try data_dir.openDir("tools", .{}),
    };
}

pub fn deinit(self: *Self) void {
    self.gpa.free(self.path);

    self.bin_dir.close();
    self.zig_dir.close();
    self.tools_dir.close();
}
