const builtin = @import("builtin");
const std = @import("std");
const eql = std.mem.eql;
const Allocator = std.mem.Allocator;

const root = @import("root");
const fatal = root.fatal;

pub fn getVersionFromFile(gpa: Allocator) ![]const u8 {
    const cwd = std.fs.cwd();

    if (cwd.openFile("build.zig.zon", .{})) |file| {
        defer file.close();

        const stat = try file.stat();
        const file_content = try file.readToEndAllocOptions(gpa, stat.size, stat.size, @alignOf(u8), 0);
        defer gpa.free(file_content);

        return (try std.zon.parse.fromSlice(struct { minimum_zig_version: []const u8 }, gpa, file_content, null, .{ .ignore_unknown_fields = true })).minimum_zig_version;
    } else |e| switch (e) {
        error.FileNotFound => {},
        else => fatal("Failed to open `build.zig.zon`", .{}, e),
    }

    fatal("No file found to get the version!", .{}, null);
}

/// The returned string must be freed
pub fn getVersionDirectory(gpa: Allocator, zig_dir: std.fs.Dir, version: []const u8) !?[]const u8 {
    if (eql(u8, version, ".")) {
        const version_from_file = try getVersionFromFile(gpa);
        defer gpa.free(version_from_file);

        return getVersionDirectory(gpa, zig_dir, version_from_file);
    }

    if (eql(u8, version, "latest") or eql(u8, version, "master")) {
        // The version provided is `latest` or `master` and in these cases we need to
        // parse the index.json page on the zig website for see what version
        // is the current `latest` or `master`.

        var mirror_index = try root.getMirrorIndex(gpa, null);

        return try folderFromVersion(gpa, if (eql(u8, version, "master"))
            mirror_index.versions.values()[0].version.?
        else
            mirror_index.versions.keys()[1]);
    }

    var iter = zig_dir.iterate();

    while (try iter.next()) |file| {
        if (eql(u8, versionFromFolder(file.name), version))
            return try gpa.dupe(u8, file.name);
    }

    return null;
}

fn versionFromFolder(folder_name: []const u8) []const u8 {
    // The folder name is in format `{ARCH}.{OS}-{VERSION}`
    var split = std.mem.splitScalar(u8, folder_name, '-');
    _ = split.next(); // {ARCH}.{OS}
    return split.rest();
}

/// The string must be freed
pub fn folderFromVersion(gpa: Allocator, version: []const u8) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}-{s}", .{
        root.ARCH_NAME ++ "." ++ @tagName(builtin.os.tag),
        version,
    });
}
