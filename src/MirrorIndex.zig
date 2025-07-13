const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

const fatal = @import("root").fatal;
const ZigVersion = @import("ZigVersion.zig");

const Self = @This();

const URI = std.Uri.parse("https://ziglang.org/download/index.json") catch unreachable;

pub const Version = struct {
    /// Available only when the version is `master`
    version: ?[]const u8,
    tarballs: std.StringHashMap(ZigVersion),

    pub fn deinit(self: *Version) void {
        self.tarballs.deinit();
    }
};

arena: std.heap.ArenaAllocator,
gpa: Allocator,

versions: std.StringArrayHashMap(Version),

pub fn deinit(self: Self) void {
    self.arena.deinit();
}

pub fn getAndParse(client: *std.http.Client, gpa: Allocator) !json.Parsed(Self) {
    var server_header_buffer: [1024]u8 = undefined;
    var req = client.open(.GET, URI, .{
        .server_header_buffer = &server_header_buffer,
        .keep_alive = false,
    }) catch |e|
        fatal("Failed to open a connection to {s}", .{URI}, e);
    defer req.deinit();

    req.send() catch |e| fatal("Failed to send a request to {s}", .{URI}, e);
    req.wait() catch |e| fatal("Failed to receive a response from the server", .{}, e);

    const body = try req.reader().readAllAlloc(gpa, 8192 * 1024);
    defer gpa.free(body);

    return json.parseFromSlice(Self, gpa, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |e|
        fatal("Unable to parse {s}", .{URI}, e);
}

pub fn jsonParse(gpa: Allocator, source: *json.Scanner, options: json.ParseOptions) json.ParseError(@TypeOf(source.*))!Self {
    var self = Self{
        .arena = .init(gpa),
        .gpa = undefined,
        .versions = undefined,
    };
    self.gpa = self.arena.allocator();
    self.versions = .init(self.gpa);
    errdefer self.deinit();

    if (try source.next() != .object_begin)
        return error.UnexpectedToken;

    while (try source.peekNextTokenType() == .string) {
        const version = try json.innerParse([]const u8, self.gpa, source, options);

        if (try source.next() != .object_begin)
            return error.UnexpectedToken;

        const version_field = blk: {
            if (std.mem.eql(u8, version, "master")) {
                _ = try source.next(); // `version` string field
                break :blk try json.innerParse([]const u8, self.gpa, source, options);
            } else {
                break :blk null;
            }
        };

        // Skip "src" field and those before
        try source.skipUntilStackHeight(source.stackHeight());

        var tarballs = std.StringHashMap(ZigVersion).init(self.gpa);

        while (true) {
            const tarball_name = try json.innerParse([]const u8, self.gpa, source, options);
            const tarball = try json.innerParse(ZigVersion, self.gpa, source, options);

            try tarballs.put(tarball_name, tarball);

            if (try source.peekNextTokenType() == .object_end) {
                _ = try source.next();
                break;
            }
        }

        try self.versions.put(version, Version{ .tarballs = tarballs, .version = version_field });
    }

    _ = try source.next();

    return self;
}
