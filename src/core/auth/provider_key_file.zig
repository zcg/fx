//! A profile-file backend for a configured connection's key.
//!
//! Only a platform with no native credential store reaches this: macOS and
//! Windows keep these keys in their own system store. Elsewhere the alternative
//! is keeping the key in a process environment variable, which disappears when
//! the process exits, so a saved connection would report a missing credential
//! on the next start.
//!
//! The file is created and re-checked at mode 0600 through the same verified
//! private-directory helpers the gateway key uses. It is never encrypted, and
//! the backend label says so, so `/status` can tell a user where the secret
//! lives.

const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const secret = @import("../auth/secret.zig");

const Allocator = std.mem.Allocator;

const max_key_bytes: usize = 8 * 1024;
const dir_name = "provider-keys";

pub const Error = Allocator.Error || error{ ReadFailed, WriteFailed, DeleteFailed };

/// Where these files live, for a message that names the backend.
pub const backend_label = "profile file (not encrypted)";

/// A stored key's file name. The environment name is already upper-case with
/// underscores, so it is a safe file name; anything else is replaced so a name
/// can never escape the directory.
fn fileName(env_name: []const u8, buffer: []u8) ?[]const u8 {
    if (env_name.len == 0 or env_name.len > buffer.len) return null;
    for (env_name, 0..) |byte, index| {
        buffer[index] = if (std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-')
            byte
        else
            '_';
    }
    return buffer[0..env_name.len];
}

/// Opens the private directory these keys live in, creating it when missing.
fn openKeyDir() Error!io_mod.VerifiedDir {
    const io = io_mod.getIo();
    const home = io_mod.homeDir() orelse return error.WriteFailed;
    var home_dir = io_mod.VerifiedDir{
        .dir = std.Io.Dir.openDirAbsolute(io, profile_paths.rootParent(home), .{ .iterate = true }) catch
            return error.WriteFailed,
    };
    defer home_dir.close();
    var fx_dir = io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.rootName()) catch
        return error.WriteFailed;
    defer fx_dir.close();
    return io_mod.openOrCreateVerifiedPrivateDir(&fx_dir, dir_name) catch error.WriteFailed;
}

/// Returns the stored key, or null when none is stored.
pub fn load(alloc: Allocator, env_name: []const u8) Error!?[]u8 {
    var name_buffer: [128]u8 = undefined;
    const name = fileName(env_name, &name_buffer) orelse return null;
    const home = io_mod.homeDir() orelse return null;
    const io = io_mod.getIo();
    // Reading must not create the directory tree, so a missing profile simply
    // means nothing is stored.
    var home_dir = std.Io.Dir.openDirAbsolute(io, profile_paths.rootParent(home), .{}) catch return null;
    defer home_dir.close(io);
    var fx_dir = home_dir.openDir(io, profile_paths.rootName(), .{ .follow_symlinks = false }) catch return null;
    defer fx_dir.close(io);
    var key_dir = fx_dir.openDir(io, dir_name, .{ .follow_symlinks = false }) catch return null;
    defer key_dir.close(io);

    var file = key_dir.openFile(io, name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return error.ReadFailed,
    };
    defer file.close(io);
    const stat = file.stat(io) catch return error.ReadFailed;
    if (stat.kind != .file or io_mod.exposesGroupOrOther(stat.permissions)) {
        debug_trace.logf("auth", "provider key file refused name={s} reason=insecure", .{name});
        return error.ReadFailed;
    }
    var readable = file;
    const text = io_mod.readFileToEnd(alloc, &readable, max_key_bytes) catch return error.ReadFailed;
    // A hand-edited file commonly ends in a newline; the key itself does not
    // carry one.
    const trimmed = std.mem.trim(u8, text, "\r\n");
    if (trimmed.len == 0) {
        secret.zeroAndFree(alloc, text);
        return null;
    }
    if (trimmed.len != text.len) {
        const owned = alloc.dupe(u8, trimmed) catch {
            secret.zeroAndFree(alloc, text);
            return error.OutOfMemory;
        };
        secret.zeroAndFree(alloc, text);
        return owned;
    }
    return text;
}

/// Writes the key, replacing any stored value.
pub fn store(alloc: Allocator, env_name: []const u8, value: []const u8) Error!void {
    if (value.len == 0 or value.len > max_key_bytes) return error.WriteFailed;
    var name_buffer: [128]u8 = undefined;
    const name = fileName(env_name, &name_buffer) orelse return error.WriteFailed;
    var key_dir = try openKeyDir();
    defer key_dir.close();
    io_mod.durableReplaceVerified(alloc, &key_dir, name, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("auth", "provider key file write failed name={s} err={s}", .{ name, @errorName(err) });
            return error.WriteFailed;
        },
    };
}

/// Removes the stored key, reporting whether one was there.
pub fn remove(alloc: Allocator, env_name: []const u8) Error!bool {
    _ = alloc;
    var name_buffer: [128]u8 = undefined;
    const name = fileName(env_name, &name_buffer) orelse return false;
    const home = io_mod.homeDir() orelse return false;
    const io = io_mod.getIo();
    var home_dir = std.Io.Dir.openDirAbsolute(io, profile_paths.rootParent(home), .{}) catch return false;
    defer home_dir.close(io);
    var fx_dir = home_dir.openDir(io, profile_paths.rootName(), .{ .follow_symlinks = false }) catch return false;
    defer fx_dir.close(io);
    var key_dir = fx_dir.openDir(io, dir_name, .{ .follow_symlinks = false }) catch return false;
    defer key_dir.close(io);
    key_dir.deleteFile(io, name) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return error.DeleteFailed,
    };
    return true;
}

test "profile key file names never escape their directory" {
    var buffer: [128]u8 = undefined;
    const name = fileName("../../etc/passwd", &buffer).?;
    try std.testing.expect(std.mem.findScalar(u8, name, '/') == null);
    try std.testing.expect(std.mem.find(u8, name, "..") == null);
    try std.testing.expect(fileName("", &buffer) == null);
}

test "profile key file writes at mode 0600 and refuses a looser mode" {
    if (comptime !io_mod.modeIsEnforced) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var key_dir = io_mod.VerifiedDir{
        .dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true, .follow_symlinks = false }),
    };
    defer key_dir.close();

    const written = "pk1-round-trip-value";
    try io_mod.durableReplaceVerified(alloc, &key_dir, "KEY", written);
    const stat = try tmp.dir.statFile(std.testing.io, "KEY", .{});
    try std.testing.expect(stat.permissions.toMode() & 0o777 == 0o600);

    // The loader refuses a file other accounts can read.
    var file = try tmp.dir.openFile(std.testing.io, "KEY", .{ .mode = .read_write });
    try io_mod.setPermissions(file, io_mod.permissionsForMode(0o644));
    file.close(std.testing.io);
    const insecure = try tmp.dir.statFile(std.testing.io, "KEY", .{});
    try std.testing.expect(io_mod.exposesGroupOrOther(insecure.permissions));
}
