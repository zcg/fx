//! Durable storage for a configured provider's API key.
//!
//! A configured provider reads its key from an environment variable, which is
//! the right place when a shell or a service manager exports it. A key the user
//! pastes into fx's own add-provider flow has no such place: on Linux and macOS
//! the system keychain holds it, and Windows has no equivalent fx can reach
//! through the same API. This module fills that gap on Windows by encrypting the
//! value with DPAPI and writing it under the profile.
//!
//! DPAPI is the platform's own answer to this problem. `CryptProtectData` derives
//! the encryption key from the logged-in user's credentials, so the file is
//! unreadable by another account on the same machine and by the same account on
//! another machine, without fx storing or deriving any key itself.
//!
//! On the platforms with a keychain this module is not used: the keychain already
//! stores the value, and writing a second copy would only create somewhere else
//! for it to leak from.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");

const Allocator = std.mem.Allocator;

/// True on a platform where fx must keep the key itself.
pub const enabled = builtin.target.os.tag == .windows;

/// The directory under the profile that holds the encrypted values.
const directory_name = "credentials";

/// Names a key by its provider, so two providers cannot read each other's.
/// The name is the provider's settings key, which is already restricted to
/// alphanumerics, `-`, and `_`.
fn fileName(buf: []u8, provider: []const u8) ?[]const u8 {
    if (provider.len == 0 or provider.len > 64) return null;
    for (provider) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return null;
    }
    return std.mem.print(buf, "{s}.key", .{provider}) catch null;
}

/// Writes `secret` for `provider`, replacing any earlier value. Returns
/// `error.Unsupported` on a platform that keeps keys in its keychain.
pub fn store(alloc: Allocator, provider: []const u8, secret: []const u8) !void {
    if (comptime !enabled) return error.Unsupported;
    if (secret.len == 0) return error.EmptySecret;
    var name_buf: [80]u8 = undefined;
    const name = fileName(&name_buf, provider) orelse return error.InvalidProviderName;

    const encrypted = try protect(alloc, secret);
    defer alloc.free(encrypted);
    errdefer debug_trace.logf("credentials", "store failed provider={s}", .{provider});

    const home = io_mod.homeDir() orelse return error.HomeNotSet;
    const path = try std.Io.Dir.path.join(alloc, &.{ home, ".fx", directory_name, name });
    defer alloc.free(path);
    const dir_path = try std.Io.Dir.path.join(alloc, &.{ home, ".fx", directory_name });
    defer alloc.free(dir_path);
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), dir_path);
    try io_mod.writeFileAtomic(alloc, path, encrypted);
}

/// Reads the value written by `store`, or null when there is none. A value that
/// cannot be decrypted - a file copied from another machine or another account -
/// is reported as absent rather than as an error, because fx cannot use it and
/// the user's remedy is the same either way: enter the key again.
pub fn load(alloc: Allocator, provider: []const u8) !?[]u8 {
    if (comptime !enabled) return null;
    var name_buf: [80]u8 = undefined;
    const name = fileName(&name_buf, provider) orelse return null;
    const home = io_mod.homeDir() orelse return null;
    const path = try std.Io.Dir.path.join(alloc, &.{ home, ".fx", directory_name, name });
    defer alloc.free(path);
    const encrypted = blk: {
        var file = std.Io.Dir.cwd().openFile(io_mod.getIo(), path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(io_mod.getIo());
        break :blk try io_mod.readFileToEnd(alloc, &file, 64 * 1024);
    };
    defer alloc.free(encrypted);
    return unprotect(alloc, encrypted) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("credentials", "load rejected provider={s} err={s}", .{ provider, @errorName(err) });
            return null;
        },
    };
}

/// Removes the stored value, if any.
pub fn clear(alloc: Allocator, provider: []const u8) !void {
    if (comptime !enabled) return;
    var name_buf: [80]u8 = undefined;
    const name = fileName(&name_buf, provider) orelse return;
    const home = io_mod.homeDir() orelse return;
    const path = try std.Io.Dir.path.join(alloc, &.{ home, ".fx", directory_name, name });
    defer alloc.free(path);
    std.Io.Dir.cwd().deleteFile(io_mod.getIo(), path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

// ---------------------------------------------------------------------------
// DPAPI

const windows = std.os.windows;

const CRYPTPROTECT_UI_FORBIDDEN: windows.DWORD = 0x1;

const DataBlob = extern struct {
    cbData: windows.DWORD,
    pbData: ?[*]u8,
};

extern "crypt32" fn CryptProtectData(
    pDataIn: *const DataBlob,
    szDataDescr: ?[*:0]const u16,
    pOptionalEntropy: ?*const DataBlob,
    pvReserved: ?*anyopaque,
    pPromptStruct: ?*anyopaque,
    dwFlags: windows.DWORD,
    pDataOut: *DataBlob,
) windows.BOOL;

extern "crypt32" fn CryptUnprotectData(
    pDataIn: *const DataBlob,
    ppszDataDescr: ?*?[*:0]u16,
    pOptionalEntropy: ?*const DataBlob,
    pvReserved: ?*anyopaque,
    pPromptStruct: ?*anyopaque,
    dwFlags: windows.DWORD,
    pDataOut: *DataBlob,
) windows.BOOL;

extern "kernel32" fn LocalFree(hMem: ?*anyopaque) ?*anyopaque;

/// A description DPAPI records alongside the value; it is metadata, not a key.
const description = std.unicode.utf8ToUtf16LeStringLiteral("fx configured provider key");

fn protect(alloc: Allocator, plain: []const u8) ![]u8 {
    if (comptime !enabled) return error.Unsupported;
    var input = DataBlob{
        .cbData = @intCast(plain.len),
        .pbData = @constCast(plain.ptr),
    };
    var output: DataBlob = .{ .cbData = 0, .pbData = null };
    if (!CryptProtectData(&input, description.ptr, null, null, null, CRYPTPROTECT_UI_FORBIDDEN, &output).toBool()) {
        return error.EncryptFailed;
    }
    defer _ = LocalFree(@ptrCast(output.pbData));
    if (output.pbData == null or output.cbData == 0) return error.EncryptFailed;
    const bytes = output.pbData.?[0..output.cbData];
    return try alloc.dupe(u8, bytes);
}

fn unprotect(alloc: Allocator, encrypted: []const u8) ![]u8 {
    if (comptime !enabled) return error.Unsupported;
    if (encrypted.len == 0) return error.DecryptFailed;
    var input = DataBlob{
        .cbData = @intCast(encrypted.len),
        .pbData = @constCast(encrypted.ptr),
    };
    var output: DataBlob = .{ .cbData = 0, .pbData = null };
    if (!CryptUnprotectData(&input, null, null, null, null, CRYPTPROTECT_UI_FORBIDDEN, &output).toBool()) {
        return error.DecryptFailed;
    }
    defer _ = LocalFree(@ptrCast(output.pbData));
    if (output.pbData == null or output.cbData == 0) return error.DecryptFailed;
    const bytes = output.pbData.?[0..output.cbData];
    const owned = try alloc.dupe(u8, bytes);
    // The decrypted bytes are a secret: clear the copy DPAPI handed back before
    // releasing it, so it does not linger in freed memory.
    @memset(bytes, 0);
    return owned;
}

test "a provider name that is not a settings key is refused" {
    var buf: [80]u8 = undefined;
    try std.testing.expect(fileName(&buf, "openrouter") != null);
    try std.testing.expect(fileName(&buf, "my-provider_2") != null);
    try std.testing.expect(fileName(&buf, "") == null);
    try std.testing.expect(fileName(&buf, "../escape") == null);
    try std.testing.expect(fileName(&buf, "with space") == null);
    try std.testing.expect(fileName(&buf, "with/slash") == null);
}

test "a stored key round-trips and is removed on clear" {
    if (comptime !enabled) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const provider = "fx-test-provider";
    defer clear(alloc, provider) catch {};
    try store(alloc, provider, "sk-test-12345");
    const loaded = try load(alloc, provider);
    defer if (loaded) |value| alloc.free(value);
    try std.testing.expect(loaded != null);
    try std.testing.expectEqualStrings("sk-test-12345", loaded.?);
    try clear(alloc, provider);
    try std.testing.expect(try load(alloc, provider) == null);
}
