const builtin = @import("builtin");
const std = @import("std");
const eql = std.mem.eql;
const allocPrint = std.fmt.allocPrint;
const Allocator = std.mem.Allocator;

const Positionals = @import("sap").Positionals;

const root = @import("root");
const fatal = root.fatal;

const version_utils = @import("../zig_version_utils.zig");
const MirrorIndex = @import("../MirrorIndex.zig");
const ZigVersion = @import("../ZigVersion.zig");

var prog_node: std.Progress.Node = undefined;
var is_nightly_build = false;

fn downloadZig(gpa: Allocator, zig_ver: ZigVersion) !void {
    const tarball_req_node = prog_node.start("Sending the request to get the tarball", 0);
    var server_header_buffer: [1024]u8 = undefined;
    var req = try root.http_client.open(.GET, try std.Uri.parse(zig_ver.tarball), .{
        .server_header_buffer = &server_header_buffer,
        .keep_alive = false,
    });
    defer req.deinit();

    req.send() catch |e| fatal("Failed to send HTTP request to {s}", .{zig_ver.tarball}, e);
    req.wait() catch |e| fatal("Failed to receive a response from the server", .{}, e);
    tarball_req_node.end();

    if (req.response.status != .ok) {
        if (!is_nightly_build)
            fatal("Received status code {d}", .{req.response.status}, null);

        fatal(
            \\Received status code {d}.
            \\Are you sure that this nightly build exist?
        , .{@intFromEnum(req.response.status)}, null);
    }

    const req_reader = req.reader();

    if (is_nightly_build or !root.data_dir.config.check_hash) {
        _ = switch (ZigVersion.TARBALL_EXT) {
            .zip => zig_ver.writeDecompressToDisk(gpa, root.data_dir.zig_dir, req_reader),
            .@"tar.xz" => ZigVersion.decompressWithReader(gpa, root.data_dir.zig_dir, req_reader),
        } catch |e| switch (e) {
            error.DecompressionFailed => fatal("Failed to decompress the tarball", .{}, null),
            else => return e,
        };
    } else {
        zig_ver.writeDecompressToDiskHashCheck(gpa, root.data_dir.zig_dir, req_reader) catch |e| switch (e) {
            error.DecompressionFailed => fatal("Failed to decompress the tarball", .{}, null),
            else => return e,
        };
    }
}

fn getZigVersion(
    gpa: Allocator,
    mirror_index: *const MirrorIndex,
    user_version: []const u8,
    os_info: []const u8,
) !ZigVersion {
    var version = user_version;

    if (eql(u8, user_version, "latest")) {
        version = try gpa.dupe(u8, mirror_index.versions.keys()[1]);
    } else if (eql(u8, user_version, ".")) {
        prog_node.increaseEstimatedTotalItems(1);
        const node = prog_node.start("Parsing zig version from file", 0);
        defer node.end();

        const ver = try version_utils.getVersionFromFile(gpa);
        defer gpa.free(ver);

        return getZigVersion(gpa, mirror_index, ver, os_info);
    }

    if (mirror_index.versions.get(version)) |vers| {
        return if (vers.tarballs.get(os_info)) |zig_ver|
            zig_ver
        else
            fatal("{s} doesn't have a build", .{os_info}, null);
    } else {
        is_nightly_build = true;
        return .{
            .tarball = try allocPrint(gpa, "https://ziglang.org/builds/zig-{s}-{s}-{s}.{s}", .{
                @tagName(builtin.os.tag),
                root.ARCH_NAME,
                version,
                @tagName(ZigVersion.TARBALL_EXT),
            }),
            .shasum = "",
        };
    }
}

pub fn execute(gpa: Allocator, positionals: *Positionals.Iterator) !void {
    const stdout = std.io.getStdOut().writer();

    const user_version = if (positionals.next()) |ver|
        ver
    else
        fatal("You need to specify a version", .{}, null);

    const os_info = try allocPrint(gpa, "{s}-{s}", .{ root.ARCH_NAME, @tagName(builtin.os.tag) });
    defer gpa.free(os_info);

    const main_prog_node_name = if (eql(u8, user_version, "master"))
        try allocPrint(gpa, "Installing zig master ({s})", .{os_info})
    else if (eql(u8, user_version, "latest"))
        try allocPrint(gpa, "Installing zig latest ({s})", .{os_info})
    else if (eql(u8, user_version, "."))
        try allocPrint(gpa, "Installing zig ({s})", .{os_info})
    else
        try allocPrint(gpa, "Installing zig-{s}-{s}", .{ os_info, user_version });
    defer gpa.free(main_prog_node_name);

    // getZigDownloadPage node + `tarball_req_node` + decompress tarball = 3
    const estimated_total_items = if (ZigVersion.TARBALL_EXT == .zip)
        // With `zip`s we need to save the file, so one more step
        4
    else
        3;

    prog_node = std.Progress.start(.{
        .root_name = main_prog_node_name,
        .estimated_total_items = estimated_total_items,
    });
    defer prog_node.end();

    const zig_ver = try getZigVersion(gpa, try root.getMirrorIndex(gpa, prog_node), user_version, os_info);
    defer if (is_nightly_build) gpa.free(zig_ver.tarball);

    ZigVersion.prog_node = prog_node;
    var tarball_dir_name = zig_ver.getFileName();
    tarball_dir_name = tarball_dir_name[0 .. tarball_dir_name.len - 1 - @tagName(ZigVersion.TARBALL_EXT).len];
    if (root.data_dir.zig_dir.statFile(tarball_dir_name) != error.FileNotFound)
        fatal("This version already exist", .{}, null);

    // If we want to calculate the hash we need to save the file, so an extra step **IF**
    // the tarball isn't a zip. `zip`s always need to save the file and we have already
    // increased the `estimated_total_items' variable by one for this.
    if (!root.data_dir.config.check_hash or (zig_ver.shasum.len != 0 and ZigVersion.TARBALL_EXT == .@"tar.xz"))
        prog_node.increaseEstimatedTotalItems(1);

    try downloadZig(gpa, zig_ver);

    try stdout.print(
        \\Successfully installed zig {0s} ({1s})
        \\If you want to use this version execute `zupgrade use {0s}`
        \\
    , .{
        if (eql(u8, user_version, "."))
            zig_ver.getVersion(os_info)
        else
            user_version,
        os_info,
    });
}

pub const HELP_MESSAGE =
    \\Usage:
    \\  zupgrade install <VERSION> [OPTIONS]
    \\
    \\Description:
    \\  Installs the zig version provided.
    \\  <VERSION> can be:
    \\      - a tagged release
    \\      - a nightly build
    \\      - "latest" to get the latest tagged release
    \\      - "master" to get the latest master build
    \\      - "." to get the version from `build.zig.zon`
    \\        or from files specified in the config file
    \\
;
