const std = @import("std");
const definitions = @import("../config/configured_provider.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const host_target = @import("../hosts/target.zig");

const Allocator = std.mem.Allocator;
const directory = "model-catalogs";
pub const max_bytes = 8 * 1024 * 1024;

fn fileName(definition: *const definitions.Definition) [69]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(&definition.binding_identity());
    // Model access belongs to the key, so another key gets its own snapshot.
    if (definition.auth == .bearer) hash.update(definition.auth.bearer);
    const hex = std.fmt.bytesToHex(hash.finalResult(), .lower);
    var name: [69]u8 = undefined;
    @memcpy(name[0..64], &hex);
    @memcpy(name[64..], ".json");
    return name;
}

/// Caller owns the returned listing; no credential is stored in this file.
pub fn load(alloc: Allocator, definition: *const definitions.Definition) !?[]u8 {
    if (comptime host_target.is_wasm) return null;
    const home = io_mod.homeDir() orelse return null;
    var parent = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), profile_paths.rootParent(home), .{});
    defer parent.close(io_mod.getIo());
    var profile = parent.openDir(io_mod.getIo(), profile_paths.rootName(), .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer profile.close(io_mod.getIo());
    var cache = profile.openDir(io_mod.getIo(), directory, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer cache.close(io_mod.getIo());
    const name = fileName(definition);
    var file = io_mod.openExistingRegularFile(cache, &name, .read_only) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    return try io_mod.readFileToEnd(alloc, &file, max_bytes);
}

pub fn save(alloc: Allocator, definition: *const definitions.Definition, body: []const u8) !void {
    if (comptime host_target.is_wasm) return;
    if (body.len > max_bytes) return error.ListingTooLarge;
    const home = io_mod.homeDir() orelse return error.HomeNotSet;
    var parent = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), profile_paths.rootParent(home), .{});
    defer parent.close(io_mod.getIo());
    var profile = try io_mod.openOrCreateVerifiedPrivateDirFromDir(parent, profile_paths.rootName());
    defer profile.close();
    var cache = try io_mod.openOrCreateVerifiedPrivateDir(&profile, directory);
    defer cache.close();
    const name = fileName(definition);
    try io_mod.durableReplaceVerified(alloc, &cache, &name, body);
}
