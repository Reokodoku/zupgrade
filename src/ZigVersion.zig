const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const minizign = @import("minizign");

const fatal = @import("root").fatal;

pub const Error = error{
    SignatureVerificationFailed,
    DecompressionFailed,
    ChecksumFailed,
};

/// This includes the "checksum" step.
pub const DECOMPRESS_PROG_NODE_STEPS = 4;

const ZIG_PUBLIC_KEY = minizign.PublicKey.decodeFromBase64("RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U") catch unreachable;

pub const TARBALL_EXT: enum { zip, @"tar.xz" } = if (builtin.os.tag == .windows)
    .zip
else
    .@"tar.xz";

const Self = @This();

/// The link to the tarball
tarball: []const u8,
shasum: []const u8,

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

/// Decompress the tarball into the specified directory and verifies the signature and (if specified) the hash.
pub fn decompress(self: Self, gpa: Allocator, prog_node: std.Progress.Node, dest_dir: std.fs.Dir, reader: anytype, signature: minizign.Signature, hash: ?*[Sha256.digest_length]u8) !void {
    var hasher = Sha256.init(.{});
    var verifier = try ZIG_PUBLIC_KEY.verifier(&signature);

    const file = try dest_dir.createFile(self.getFileName(), .{ .read = true });
    defer file.close();
    defer dest_dir.deleteFile(self.getFileName()) catch @panic("Unable to delete the tarball");
    var file_writer = file.writer();

    {
        const cur_pnode = prog_node.start("Writing to file", 0);
        defer cur_pnode.end();

        var buffer: [std.heap.page_size_max]u8 = undefined;
        while (true) {
            const bytes = try reader.read(&buffer);
            if (bytes == 0)
                break; // end of stream

            try file_writer.writeAll(buffer[0..bytes]);
            if (hash != null)
                hasher.update(buffer[0..bytes]);
            verifier.update(buffer[0..bytes]);
        }
    }

    if (hash) |h| {
        const cur_pnode = prog_node.start("Verifying hash", 0);
        defer cur_pnode.end();

        hasher.final(h);

        const fmt_hash = try std.fmt.allocPrint(gpa, "{s}", .{std.fmt.fmtSliceHexLower(h)});
        defer gpa.free(fmt_hash);

        if (!std.mem.eql(u8, self.shasum, fmt_hash))
            return Error.ChecksumFailed;
    }

    {
        const cur_pnode = prog_node.start("Verifying signature", 0);
        defer cur_pnode.end();

        verifier.verify(gpa) catch return Error.SignatureVerificationFailed;
    }

    try file.seekTo(0);
    {
        const cur_pnode = prog_node.start("Decompressing", 0);
        defer cur_pnode.end();

        switch (TARBALL_EXT) {
            .zip => std.zip.extract(dest_dir, file.seekableStream(), .{}) catch return Error.DecompressionFailed,
            .@"tar.xz" => {
                var buffered_reader = std.io.bufferedReaderSize(std.crypto.tls.max_ciphertext_record_len, file.reader());
                var decompressor = std.compress.xz.decompress(gpa, buffered_reader.reader()) catch return Error.DecompressionFailed;
                defer decompressor.deinit();
                std.tar.pipeToFileSystem(dest_dir, decompressor.reader(), .{}) catch return Error.DecompressionFailed;
            },
        }
    }
}
