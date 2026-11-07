//! Proves a Windows directory handle can be flushed, which is what
//! `Storage.syncDir` relies on to make a rename durable.
//!
//! Run with `zig build probe-dir-sync` from the repository root.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io");

pub fn main(init: std.process.Init) !void {
    _ = init;
    const zio = io_mod.getIo();
    const alloc = std.heap.page_allocator;

    const root = try io_mod.dirRealpathAlloc(alloc, std.Io.Dir.cwd(), ".");
    defer alloc.free(root);
    const path = try alloc.print("{s}/.zig-out-verify/dir-sync-probe", .{root});
    defer alloc.free(path);
    std.Io.Dir.createDirAbsolute(zio, path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Open the folder the way a session folder is opened: iterate is off, and
    // the handle still needs to flush.
    var dir = try std.Io.Dir.openDirAbsolute(zio, path, .{});
    defer dir.close(zio);

    const as_file: std.Io.File = .{ .handle = @ptrCast(dir.handle), .flags = .{ .nonblocking = false } };
    as_file.sync(zio) catch |err| {
        std.debug.print("dir sync FAILED: {s}\n", .{@errorName(err)});
        return err;
    };
    std.debug.print("dir sync OK on {s} ({s})\n", .{ path, @tagName(builtin.target.os.tag) });
}
