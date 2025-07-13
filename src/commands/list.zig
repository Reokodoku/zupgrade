const std = @import("std");
const Allocator = std.mem.Allocator;

const root = @import("root");

pub fn execute(gpa: Allocator) !void {
    const stdout = std.io.getStdOut().writer();

    var read_link_buffer = std.mem.zeroes([(24 + 12) + 20]u8);
    const current_zig = root.data_dir.bin_dir.readLink("zig", &read_link_buffer) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };

    var mirror_index = try root.getMirrorIndex(gpa, null);

    try stdout.print("List of installed zig version:\n", .{});
    var iter = root.data_dir.zig_dir.iterate();
    while (try iter.next()) |v| {
        var split = std.mem.splitScalar(u8, v.name, '-');
        _ = split.next(); // `zig`
        const os = split.next().?;
        const arch = split.next().?;
        const version = split.rest();

        try stdout.print("  {s} ({s}-{s})", .{ version, arch, os });

        // Check if version is master or latest
        if (std.mem.eql(u8, mirror_index.versions.values()[0].version.?, version))
            try stdout.writeAll(" [master]")
        else if (std.mem.eql(u8, mirror_index.versions.keys()[1], version))
            try stdout.writeAll(" [latest]");

        if (current_zig) |current| {
            var path = std.mem.splitBackwardsScalar(u8, current, std.fs.path.sep);
            _ = path.next(); // `zig` exe

            if (std.mem.eql(u8, v.name, path.next().?))
                try stdout.writeAll(" **CURRENT**");
        }

        try stdout.writeAll("\n");
    }
}

pub const HELP_MESSAGE =
    \\Usage:
    \\  zupgrade list [OPTIONS]
    \\
    \\Description:
    \\  Lists the zig version installed.
    \\
;
