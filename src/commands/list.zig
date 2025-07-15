const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;

const root = @import("root");

pub fn execute(gpa: Allocator) !void {
    const stdout = std.io.getStdOut().writer();

    const current_zig = try root.getCurrentZigVersion(gpa, root.data_dir.bin_dir);
    defer if (current_zig) |_| gpa.free(current_zig.?);

    var mirror_index = try root.getMirrorIndex(gpa, null);

    try stdout.print("List of installed zig version:\n", .{});
    var iter = root.data_dir.zig_dir.iterate();
    while (try iter.next()) |v| {
        var split = std.mem.splitScalar(u8, v.name, '-');
        const os_info = split.next().?;
        const version = split.rest();

        try stdout.print("  {s} ({s})", .{ version, os_info });

        // Check if version is master or latest
        if (std.mem.eql(u8, mirror_index.versions.values()[0].version.?, version))
            try stdout.writeAll(" [master]")
        else if (std.mem.eql(u8, mirror_index.versions.keys()[1], version))
            try stdout.writeAll(" [latest]");

        if (current_zig) |current| {
            if (std.mem.eql(u8, v.name, current))
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
