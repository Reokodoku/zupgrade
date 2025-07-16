const builtin = @import("builtin");
const std = @import("std");
const eql = std.mem.eql;
const allocPrint = std.fmt.allocPrint;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const Positionals = @import("sap").Positionals;

const minizign = @import("minizign");

const root = @import("root");
const fatal = root.fatal;

const version_utils = @import("../zig_version_utils.zig");
const AppContext = @import("../AppContext.zig");
const MirrorIndex = @import("../MirrorIndex.zig");
const ZigVersion = @import("../ZigVersion.zig");

var prog_node: std.Progress.Node = undefined;
var is_nightly_build = false;

var server_header_buffer: [1024]u8 = undefined;
fn sendGetReq(url: []const u8) !std.http.Client.Request {
    var req = try root.http_client.open(.GET, try std.Uri.parse(url), .{
        .server_header_buffer = &server_header_buffer,
        .keep_alive = false,
    });

    req.send() catch |e| fatal("Failed to send HTTP request to {s}", .{url}, e);
    req.wait() catch |e| fatal("Failed to receive a response from the server", .{}, e);

    if (req.response.status != .ok) {
        if (is_nightly_build)
            fatal(
                \\Failed to send HTTP request: received status code {d}
                \\Are you sure that this nightly build exist?
                \\Maybe is's no longer present.
            , .{@intFromEnum(req.response.status)}, null)
        else
            fatal("Failed to send HTTP request: received status code {d}", .{@intFromEnum(req.response.status)}, null);
    }

    return req;
}

fn downloadZig(ctx: *const AppContext, zig_ver: ZigVersion) !void {
    var sign: minizign.Signature = undefined;

    {
        const get_signature_node = prog_node.start("Getting signature", 0);
        defer get_signature_node.end();

        const minisign_url = try allocPrint(ctx.gpa, "{s}.minisig", .{zig_ver.tarball});
        defer ctx.gpa.free(minisign_url);

        var req = try sendGetReq(minisign_url);
        defer req.deinit();

        const sign_data = try req.reader().readAllAlloc(ctx.gpa, std.heap.page_size_max * 4);
        defer ctx.gpa.free(sign_data);

        sign = try minizign.Signature.decode(ctx.gpa, sign_data);
    }
    defer sign.deinit();

    const tarball_req_node = prog_node.start("Sending the request to get the tarball", 0);
    var req = try sendGetReq(zig_ver.tarball);
    defer req.deinit();
    tarball_req_node.end();

    var hash: [Sha256.digest_length]u8 = undefined;
    zig_ver.decompress(ctx.gpa, prog_node, ctx.zig_dir, req.reader(), sign, if (is_nightly_build or !ctx.config.check_hash) null else &hash) catch |e| switch (e) {
        ZigVersion.Error.SignatureVerificationFailed => fatal("Failed to verify the signature", .{}, null),
        ZigVersion.Error.DecompressionFailed => fatal("Failed to decompress the tarball", .{}, null),
        ZigVersion.Error.ChecksumFailed => {
            const fmt_hash = try allocPrint(ctx.gpa, "{s}", .{std.fmt.fmtSliceHexLower(&hash)});
            defer ctx.gpa.free(fmt_hash);

            fatal(
                \\Tarball hashes are not the same!
                \\Expected hash: {s}
                \\Obtained hash: {s}
            , .{
                zig_ver.shasum,
                fmt_hash,
            }, null);
        },
        else => return e,
    };
}

fn getZigVersion(
    gpa: Allocator,
    mirror_index: *const MirrorIndex,
    user_version: []const u8,
    os_info: []const u8,
) !ZigVersion {
    var version = user_version;

    if (eql(u8, user_version, "latest")) {
        version = mirror_index.versions.keys()[1];
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
            .tarball = try allocPrint(gpa, "https://ziglang.org/builds/zig-{s}-{s}.{s}", .{
                os_info,
                version,
                @tagName(ZigVersion.TARBALL_EXT),
            }),
            .shasum = "",
        };
    }
}

pub fn execute(ctx: *const AppContext, positionals: *Positionals.Iterator) !void {
    const stdout = std.io.getStdOut().writer();

    const user_version = if (positionals.next()) |ver|
        ver
    else
        fatal("You need to specify a version", .{}, null);

    const os_info = root.ARCH_NAME ++ "-" ++ @tagName(builtin.os.tag);

    const main_prog_node_name = if (eql(u8, user_version, "master"))
        try allocPrint(ctx.gpa, "Installing zig master ({s})", .{os_info})
    else if (eql(u8, user_version, "latest"))
        try allocPrint(ctx.gpa, "Installing zig latest ({s})", .{os_info})
    else if (eql(u8, user_version, "."))
        try allocPrint(ctx.gpa, "Installing zig ({s})", .{os_info})
    else
        try allocPrint(ctx.gpa, "Installing zig-{s}-{s}", .{ os_info, user_version });
    defer ctx.gpa.free(main_prog_node_name);

    prog_node = std.Progress.start(.{
        .root_name = main_prog_node_name,
        // `getMirrorIndex` + `get_signature_node` + `tarball_req_node` + `ZigVersion.decompress` (- "checksum" step)
        .estimated_total_items = 3 + (ZigVersion.DECOMPRESS_PROG_NODE_STEPS - 1),
    });
    defer prog_node.end();

    const zig_ver = try getZigVersion(ctx.gpa, try root.getMirrorIndex(ctx.gpa, prog_node), user_version, os_info);
    defer if (is_nightly_build) ctx.gpa.free(zig_ver.tarball);

    // Add the "checksum" step if it's needed
    if (!is_nightly_build and ctx.config.check_hash)
        prog_node.increaseEstimatedTotalItems(1);

    {
        const zig_internal_path = try zig_ver.getInternalPath(ctx.gpa);
        defer ctx.gpa.free(zig_internal_path);
        if (ctx.zig_dir.statFile(zig_internal_path) != error.FileNotFound)
            fatal("This version already exist", .{}, null);
    }

    try downloadZig(ctx, zig_ver);

    try stdout.print(
        \\Successfully installed zig {0s} ({1s})
        \\If you want to use this version execute `zupgrade use {0s}`
        \\
    , .{
        if (eql(u8, user_version, "."))
            zig_ver.getVersion()
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
