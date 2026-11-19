//! Windows Credential Manager as fx's secret store.
//!
//! macOS keeps a secret in the login keychain and reads it back with
//! Security.framework. Windows has the same shape under a different name: the
//! Credential Manager, whose generic credentials are a service name, an account
//! name, and an opaque blob only that user's logon can read. The blob is
//! encrypted by the operating system with DPAPI before it reaches disk, so a
//! copied credential file is not a copied secret.
//!
//! This file owns only the Win32 calls. `native_keychain.zig` decides when to
//! use them, so the rest of fx keeps calling one store on every platform.
//!
//! A credential is addressed the same way the keychain addresses an item: the
//! service names the kind of secret and the account names whose it is. That is
//! why the name has to match what the macOS path uses: a profile that moves
//! between machines keeps finding its items.

const std = @import("std");
const builtin = @import("builtin");

/// Whether the Credential Manager is what this build stores secrets in.
pub const supported = builtin.target.os.tag == .windows;

/// What a credential call can fail with, in the vocabulary the caller knows.
pub const Error = error{
    UnsupportedPlatform,
    NotFound,
    ReadFailed,
    WriteFailed,
    DeleteFailed,
    OutOfMemory,
};

/// The largest secret fx stores. The Credential Manager allows 5 * 512 bytes
/// for `CredentialBlob`, and a token or a saved session is far below that.
pub const max_blob_bytes: usize = 2560;

const windows = if (supported) struct {
    const CREDENTIALW = extern struct {
        Flags: u32,
        Type: u32,
        TargetName: [*:0]const u16,
        Comment: ?[*:0]const u16,
        LastWritten: u64,
        CredentialBlobSize: u32,
        CredentialBlob: ?[*]u8,
        Persist: u32,
        AttributeCount: u32,
        Attributes: ?*anyopaque,
        TargetAlias: ?[*:0]const u16,
        UserName: ?[*:0]const u16,
    };

    /// `CRED_TYPE_GENERIC`: an application's own blob, which is what a token is.
    const cred_type_generic: u32 = 1;
    /// `CRED_PERSIST_LOCAL_MACHINE`: kept for this user on this machine, and
    /// readable after a reboot. The tighter `CRED_PERSIST_ENTERPRISE` roams
    /// the credential to other machines through the domain, which fx does not
    /// want for a key the user typed here.
    const cred_persist_local_machine: u32 = 2;
    /// `CRED_PRESERVE_CREDENTIAL_BLOB` is not used: fx always writes the whole
    /// blob, so a shorter new secret never leaves the old tail behind.
    const error_not_found: u32 = 1168;

    extern "advapi32" fn CredWriteW(credential: *const CREDENTIALW, flags: u32) callconv(.winapi) i32;
    extern "advapi32" fn CredReadW(
        target_name: [*:0]const u16,
        cred_type: u32,
        flags: u32,
        credential: *?*CREDENTIALW,
    ) callconv(.winapi) i32;
    extern "advapi32" fn CredDeleteW(target_name: [*:0]const u16, cred_type: u32, flags: u32) callconv(.winapi) i32;
    extern "advapi32" fn CredFree(buffer: *anyopaque) callconv(.winapi) void;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    extern "kernel32" fn LocalFree(memory: *anyopaque) callconv(.winapi) ?*anyopaque;
} else struct {};

/// The name one credential is stored under.
///
/// The Credential Manager has no separate service and account fields for a
/// generic credential: the target name is the whole address. It is built as
/// `service:account` so the two parts stay visible, and so a credential fx
/// wrote can be found by hand in the Windows UI when a user needs to remove it.
fn targetNameAlloc(alloc: std.mem.Allocator, service: []const u8, account: []const u8) Error![:0]u8 {
    const target = alloc.allocSentinel(u8, service.len + 1 + account.len, 0) catch return error.OutOfMemory;
    @memcpy(target[0..service.len], service);
    target[service.len] = ':';
    @memcpy(target[service.len + 1 ..][0..account.len], account);
    return target;
}

/// Stores `value` under `service` for `account`, replacing what was there.
pub fn store(alloc: std.mem.Allocator, service: []const u8, account: []const u8, value: []const u8) Error!void {
    if (comptime !supported) return error.UnsupportedPlatform;
    if (value.len == 0 or value.len > max_blob_bytes) return error.WriteFailed;

    const target_z = try targetNameAlloc(alloc, service, account);
    defer alloc.free(target_z);
    const target = try toWide(alloc, target_z);
    defer alloc.free(target);
    const user = try toWide(alloc, account);
    defer alloc.free(user);

    // A caller may hand a secret with a trailing newline, as a token read from
    // a file has. The Credential Manager keeps bytes verbatim, so it is trimmed
    // here rather than at every read.
    const blob = std.mem.trimEnd(u8, value, "\r\n");
    if (blob.len == 0 or blob.len > max_blob_bytes) return error.WriteFailed;

    var credential: windows.CREDENTIALW = .{
        .Flags = 0,
        .Type = windows.cred_type_generic,
        .TargetName = target.ptr,
        .Comment = null,
        .LastWritten = 0,
        .CredentialBlobSize = @intCast(blob.len),
        // The blob is not secret to this layer: it is already ciphertext as far
        // as the disk is concerned. The pointer is const-cast because the Win32
        // signature predates const.
        .CredentialBlob = @constCast(blob.ptr),
        .Persist = windows.cred_persist_local_machine,
        .AttributeCount = 0,
        .Attributes = null,
        .TargetAlias = null,
        .UserName = user.ptr,
    };
    if (windows.CredWriteW(&credential, 0) == 0) return error.WriteFailed;
}

/// Reads the secret stored under `service` for `account`, or null when there is
/// none. The caller owns the result.
pub fn load(alloc: std.mem.Allocator, service: []const u8, account: []const u8) Error!?[]u8 {
    if (comptime !supported) return error.UnsupportedPlatform;

    const target_z = try targetNameAlloc(alloc, service, account);
    defer alloc.free(target_z);
    const target = try toWide(alloc, target_z);
    defer alloc.free(target);

    var found: ?*windows.CREDENTIALW = null;
    if (windows.CredReadW(target.ptr, windows.cred_type_generic, 0, &found) == 0) {
        if (windows.GetLastError() == windows.error_not_found) return null;
        return error.ReadFailed;
    }
    const credential = found orelse return null;
    defer windows.CredFree(@ptrCast(credential));

    const size = credential.CredentialBlobSize;
    const blob = credential.CredentialBlob orelse return null;
    if (size == 0) return null;
    if (size > max_blob_bytes) return error.ReadFailed;
    return alloc.dupe(u8, blob[0..size]) catch error.OutOfMemory;
}

/// Removes the credential, reporting whether one was there.
pub fn remove(alloc: std.mem.Allocator, service: []const u8, account: []const u8) Error!bool {
    if (comptime !supported) return error.UnsupportedPlatform;

    const target_z = try targetNameAlloc(alloc, service, account);
    defer alloc.free(target_z);
    const target = try toWide(alloc, target_z);
    defer alloc.free(target);

    if (windows.CredDeleteW(target.ptr, windows.cred_type_generic, 0) == 0) {
        if (windows.GetLastError() == windows.error_not_found) return false;
        return error.DeleteFailed;
    }
    return true;
}

/// Whether a credential exists, without reading its secret.
pub fn contains(alloc: std.mem.Allocator, service: []const u8, account: []const u8) Error!bool {
    if (comptime !supported) return error.UnsupportedPlatform;

    const target_z = try targetNameAlloc(alloc, service, account);
    defer alloc.free(target_z);
    const target = try toWide(alloc, target_z);
    defer alloc.free(target);

    var found: ?*windows.CREDENTIALW = null;
    if (windows.CredReadW(target.ptr, windows.cred_type_generic, 0, &found) == 0) {
        if (windows.GetLastError() == windows.error_not_found) return false;
        return error.ReadFailed;
    }
    if (found) |credential| windows.CredFree(@ptrCast(credential));
    return true;
}

fn toWide(alloc: std.mem.Allocator, text: []const u8) Error![:0]const u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(alloc, text) catch error.OutOfMemory;
}

test "the target name carries both the service and the account" {
    if (comptime !supported) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const target = try targetNameAlloc(alloc, "FX_SERVICE", "user@example.com");
    defer alloc.free(target);
    try std.testing.expectEqualStrings("FX_SERVICE:user@example.com", target);
}

test "a stored credential reads back and can be removed" {
    if (comptime !supported) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const service = "FX_TEST_WINDOWS_CREDENTIAL";
    const account = "test-account";
    defer _ = remove(alloc, service, account) catch {};

    try store(alloc, service, account, "secret-value\n");
    const read = (try load(alloc, service, account)) orelse return error.NotFound;
    defer alloc.free(read);
    // A trailing newline from a token file is trimmed on the way in.
    try std.testing.expectEqualStrings("secret-value", read);

    try std.testing.expect(try contains(alloc, service, account));
    try std.testing.expect(try remove(alloc, service, account));
    try std.testing.expect(!try contains(alloc, service, account));
    try std.testing.expectEqual(@as(?[]u8, null), try load(alloc, service, account));
}
