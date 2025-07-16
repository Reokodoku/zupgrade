const builtin = @import("builtin");
const std = @import("std");
const eql = std.mem.eql;

const sap = @import("sap");
const KnownFolderConfig = @import("known-folders").KnownFolderConfig;

const AppContext = @import("AppContext.zig");
const MirrorIndex = @import("MirrorIndex.zig");

const install = @import("commands/install.zig");
const list = @import("commands/list.zig");
const uninstall = @import("commands/uninstall.zig");
const use = @import("commands/use.zig");

pub const ARCH_NAME = if (builtin.cpu.arch == .arm)
    "armv7a"
else
    @tagName(builtin.cpu.arch);

const VERSION = "0.1.0";

pub var http_client: std.http.Client = undefined;

fn usage(exe_name: []const u8) noreturn {
    std.debug.print(
        \\zupgrade - Upgrade zig & tools
        \\
        \\Usage:
        \\  {s} [COMMAND] ... [OPTIONS]
        \\
        \\Commands:
        \\  list, ls        List all downloaded versions of zig
        \\  install, i      Download a version of zig
        \\  uninstall, rm   Uninstall a version of zig
        \\  use, switch     Switch the current version of zig
        \\
        \\Options:
        \\  --help              Display this help message
        \\  --version           Display the version of the program
        \\
    , .{exe_name});

    std.process.exit(0);
}

fn version(_: *anyopaque) noreturn {
    std.debug.print("zupgrade - " ++ VERSION ++ "\n", .{});
    std.process.exit(0);
}

pub fn fatal(comptime format: []const u8, args: anytype, err: ?anyerror) noreturn {
    var stderr = std.io.getStdErr().writer();

    // We print a newline before the message in case we are using std.Progress.Node
    stderr.print("\n" ++ format ++ "\n", args) catch {};
    if (err) |e|
        stderr.print("Error: {?}\n", .{e}) catch {};

    std.process.exit(1);
}

var mirror_index: ?std.json.Parsed(MirrorIndex) = null;
pub fn getMirrorIndex(gpa: std.mem.Allocator, prog_node: ?std.Progress.Node) !*const MirrorIndex {
    if (mirror_index) |p|
        return &p.value;

    const stdout = std.io.getStdOut();

    const pnode = blk: {
        if (prog_node) |n| {
            break :blk n.start("Getting zig download page", 0);
        } else {
            try stdout.writeAll("Getting zig download page");
            break :blk null;
        }
    };

    mirror_index = try MirrorIndex.getAndParse(&http_client, gpa);

    if (pnode) |node|
        node.end()
    else
        try stdout.writeAll("\r");

    return &mirror_index.?.value;
}

pub fn getCurrentZigVersion(gpa: std.mem.Allocator, zig_dir: std.fs.Dir) !?[]const u8 {
    const current_zig_version = zig_dir.openFile("selected", .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer current_zig_version.close();

    return try current_zig_version.readToEndAlloc(gpa, std.heap.page_size_min);
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa_state.deinit() == .leak) @panic("MEMORY LEAK DETECTED");

    const gpa = gpa_state.allocator();

    var arg_parser = sap.Parser(.{
        sap.flag(bool, "help", null, false),
        sap.actionFlag("version", null, &version),
    }).init(gpa);
    defer arg_parser.deinit();

    const args = try arg_parser.parseArgs();
    var positionals = args.positionals.iterator();
    const cmd = positionals.next();

    var ctx = try AppContext.init(gpa, args.executable_name);
    defer ctx.deinit();

    http_client = .{ .allocator = gpa };
    defer http_client.deinit();

    defer if (mirror_index) |m| {
        m.value.deinit();
        m.deinit();
    };

    if (cmd) |c| {
        if (eql(u8, c, "install") or eql(u8, c, "i")) {
            if (args.help)
                std.debug.print(install.HELP_MESSAGE, .{})
            else
                try install.execute(&ctx, &positionals);
        } else if (eql(u8, c, "uninstall") or eql(u8, c, "rm")) {
            if (args.help)
                std.debug.print(uninstall.HELP_MESSAGE, .{})
            else
                try uninstall.execute(&ctx, &positionals);
        } else if (eql(u8, c, "list") or eql(u8, c, "ls")) {
            if (args.help)
                std.debug.print(list.HELP_MESSAGE, .{})
            else
                try list.execute(&ctx);
        } else if (eql(u8, c, "use") or eql(u8, c, "switch")) {
            if (args.help)
                std.debug.print(use.HELP_MESSAGE, .{})
            else
                try use.execute(&ctx, &positionals);
        } else {
            usage(args.executable_name);
        }
    } else {
        usage(args.executable_name);
    }
}

pub const known_folders_config: KnownFolderConfig = .{
    .xdg_on_mac = true,
};
