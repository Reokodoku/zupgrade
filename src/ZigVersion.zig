const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const fatal = @import("root").fatal;

pub const Error = error{
    DecompressionFailed,
};

const WRITE_BUFFER_SIZE = std.heap.pageSize() * 4;
pub const TARBALL_EXT: enum { zip, @"tar.xz" } = if (builtin.os.tag == .windows)
    .zip
else
    .@"tar.xz";

pub var prog_node: std.Progress.Node = undefined;
const Self = @This();

/// The link to the tarball
tarball: []const u8,
shasum: []const u8,

/// Decompress the tarball into the specified directory
pub fn decompressWithReader(gpa: Allocator, dir: std.fs.Dir, reader: anytype) !void {
    const node = prog_node.start("Decompressing", 0);
    defer node.end();

    switch (TARBALL_EXT) {
        .zip => std.zip.extract(dir, reader, .{}) catch return Error.DecompressionFailed,
        .@"tar.xz" => {
            var buffered_reader = std.io.bufferedReaderSize(std.crypto.tls.max_ciphertext_record_len, reader);
            var decompressor = std.compress.xz.decompress(gpa, buffered_reader.reader()) catch return Error.DecompressionFailed;
            defer decompressor.deinit();
            std.tar.pipeToFileSystem(dir, decompressor.reader(), .{}) catch return Error.DecompressionFailed;
        },
    }
}

/// Decompress the tarball into the specified directory
pub fn decompress(gpa: Allocator, dir: std.fs.Dir, file: std.fs.File) !void {
    const reader = switch (TARBALL_EXT) {
        .zip => file.seekableStream(),
        .@"tar.xz" => file.reader(),
    };

    try Self.decompressWithReader(gpa, dir, reader);
}

pub fn getFileName(self: Self) []const u8 {
    var split = std.mem.splitBackwardsScalar(u8, self.tarball, '/');
    return split.next().?;
}

pub fn getVersion(self: Self, os_info: []const u8) []const u8 {
    // The URL is in format `https://ziglang.org/**/zig-{OS_INFO}-{VERSION}.{EXT}`,
    // so we take the file name and then we need to trim the extension and the
    // `zig-{OS_INFO}-`.

    const file_name = self.getFileName();

    const t1 = std.mem.trimLeft(u8, file_name, "zig-");
    const t2 = std.mem.trimLeft(u8, t1, os_info);
    const t3 = std.mem.trimLeft(u8, t2, "-");

    return std.mem.trimRight(u8, t3, "." ++ @tagName(TARBALL_EXT));
}

/// Write to disk the tarball and calculate the hash.
pub fn writeToDiskHash(
    self: Self,
    dir: std.fs.Dir,
    data_reader: anytype,
    hash: *[Sha256.digest_length]u8,
) !std.fs.File {
    const node = prog_node.start("Saving tarball to disk", 0);
    defer node.end();

    var hasher = Sha256.init(.{});

    const file = try dir.createFile(self.getFileName(), .{ .read = true });
    var file_writer = file.writer();

    var buffer: [WRITE_BUFFER_SIZE]u8 = undefined;

    while (true) {
        const bytes = try data_reader.read(&buffer);
        if (bytes == 0)
            break; // end of stream

        try file_writer.writeAll(buffer[0..bytes]);
        hasher.update(buffer[0..bytes]);
    }
    try file.seekTo(0);

    hasher.final(hash);

    return file;
}

pub fn writeToDisk(self: Self, dir: std.fs.Dir, data_reader: anytype) !std.fs.File {
    const node = prog_node.start("Saving tarball to disk", 0);
    defer node.end();

    const file = try dir.createFile(self.getFileName(), .{ .read = true });
    var file_writer = file.writer();

    var buffer: [WRITE_BUFFER_SIZE]u8 = undefined;

    while (true) {
        const bytes = try data_reader.read(&buffer);
        if (bytes == 0)
            break; // end of stream

        try file_writer.writeAll(buffer[0..bytes]);
    }
    try file.seekTo(0);

    return file;
}

/// Writes the tarball to disk, decompresses it and deletes it. Also, this function checks if the hash
/// is the same as the one in the `shasum` field.
pub fn writeDecompressToDiskHashCheck(
    self: Self,
    gpa: Allocator,
    dir: std.fs.Dir,
    data_reader: anytype,
) !void {
    var hash: [Sha256.digest_length]u8 = undefined;

    const file = try self.writeToDiskHash(dir, data_reader, &hash);
    defer file.close();

    const fmt_hash = try std.fmt.allocPrint(gpa, "{s}", .{std.fmt.fmtSliceHexLower(&hash)});
    defer gpa.free(fmt_hash);

    if (!std.mem.eql(u8, self.shasum, fmt_hash)) {
        try dir.deleteFile(self.getFileName());

        fatal(
            \\Tarball hashes are not the same!
            \\Expected hash: {s}
            \\Obtained hash: {s}
            \\
        , .{
            self.shasum,
            fmt_hash,
        }, null) catch {};
    }

    try Self.decompress(gpa, dir, file);

    try dir.deleteFile(self.getFileName());
}

/// Writes the tarball to disk, decompresses it and deletes it.
pub fn writeDecompressToDisk(
    self: Self,
    gpa: Allocator,
    dir: std.fs.Dir,
    data_reader: anytype,
) !void {
    const file = try self.writeToDisk(dir, data_reader);
    defer file.close();

    try Self.decompress(gpa, dir, file);

    try dir.deleteFile(self.getFileName());
}
