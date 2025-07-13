const std = @import("std");
const known_folders = @import("known-folders");

const Config = @import("Config.zig");

const Self = @This();

config: Config,

bin_dir: std.fs.Dir,
zig_dir: std.fs.Dir,
tools_dir: std.fs.Dir,

pub fn init(gpa: std.mem.Allocator, exe_name: []const u8) !Self {
    var data_dir_created = false;

    var data_dir: std.fs.Dir = blk: {
        const path = std.process.getEnvVarOwned(gpa, "ZUPGRADE_DATA_DIR") catch |e| switch (e) {
            error.EnvironmentVariableNotFound => {
                var home = try known_folders.open(gpa, .home, .{}) orelse @panic("Error when opening home dir");
                defer home.close();

                _ = home.statFile(".zupgrade") catch |er| switch (er) {
                    error.FileNotFound => {
                        try home.makeDir(".zupgrade");
                        data_dir_created = true;
                    },
                    else => return er,
                };

                break :blk try home.openDir(".zupgrade", .{});
            },
            else => return e,
        };
        defer gpa.free(path);
        break :blk try std.fs.cwd().openDir(path, .{});
    };
    defer data_dir.close();

    for ([_][]const u8{
        "bin",
        "zig",
        "tools",
    }) |dir| {
        _ = data_dir.statFile(dir) catch |e| switch (e) {
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
        const stdout = std.io.getStdOut().writer();
        const path = try std.fs.path.join(gpa, &[_][]const u8{
            (try known_folders.getPath(gpa, .home)).?,
            ".zupgrade",
            "bin",
        });
        defer gpa.free(path);
        try stdout.print(
            \\You have successfully installed zupgrade!
            \\
            \\To be able to use zupgrade, you must put in your `PATH` env
            \\{s}
            \\
            \\Then to get started you can execute `{s} --help`!
            \\
        , .{ path, exe_name });
        std.process.exit(0);
    }

    return .{
        .config = config,
        .bin_dir = try data_dir.openDir("bin", .{}),
        .zig_dir = try data_dir.openDir("zig", .{ .iterate = true }),
        .tools_dir = try data_dir.openDir("tools", .{}),
    };
}

pub fn deinit(self: *Self) void {
    self.bin_dir.close();
    self.zig_dir.close();
    self.tools_dir.close();
}
