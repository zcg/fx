//! Storage for a configured connection's key.
//!
//! Settings never own the secret: `auth.bearer` names an environment variable
//! (`tests/tla/configured_provider/ConfiguredRequest.tla` OwnedKeysKeepFxValue).
//! A key saved through fx lives in the platform credential store under that
//! same name, so a setting can stay portable while the secret stays out of the
//! file. A variable the user set explicitly still wins where credentials are
//! resolved.

const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const native_keychain = @import("../hosts/native_keychain.zig");

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || error{KeychainReadFailed};

pub const StoreResult = enum {
    credential_store,
    environment_required,
};

/// Resolves a saved key for `env_name`, when the platform has a credential
/// store. The environment variable itself is read separately at the effectful
/// edge, where all configured providers resolve their bearer token.
pub fn loadSavedKey(alloc: Allocator, env_name: []const u8) Error!?[]u8 {
    if (env_name.len == 0 or !native_keychain.isAvailable() or native_keychain.isDisabled()) return null;
    return native_keychain.loadProviderKey(alloc, env_name) catch |err| switch (err) {
        error.KeychainItemNotFound => null,
        error.OutOfMemory => error.OutOfMemory,
        else => blk: {
            debug_trace.logf("auth", "configured provider key read failed env={s} err={s}", .{ env_name, @errorName(err) });
            break :blk error.KeychainReadFailed;
        },
    };
}

/// Resolves the value for `env_name`: a variable the user set wins, then a key
/// saved through fx's add-provider flow. The caller owns the returned bytes.
pub fn resolveKey(alloc: Allocator, env_name: []const u8) Error!?[]u8 {
    if (env_name.len == 0) return null;
    if (io_mod.getenv(env_name)) |value| {
        if (value.len > 0) return try alloc.dupe(u8, value);
    }
    return loadSavedKey(alloc, env_name);
}

/// Stores a key for the env name the settings file will record. Platforms with
/// a native credential store use it; elsewhere the caller must tell the user
/// to set the variable explicitly.
pub fn store(alloc: Allocator, env_name: []const u8, value: []const u8) !StoreResult {
    if (env_name.len == 0 or value.len == 0) return error.InvalidConfiguredProviderCredential;
    if (native_keychain.isAvailable() and !native_keychain.isDisabled()) {
        try native_keychain.storeProviderKey(alloc, env_name, value);
        // Other code in this process may read the env var before the next
        // credential resolution; durable storage is the credential store.
        try io_mod.setProcessEnv(env_name, value);
        try noteFxSetEnv(alloc, env_name);
        return .credential_store;
    }
    try io_mod.setProcessEnv(env_name, value);
    try noteFxSetEnv(alloc, env_name);
    return .environment_required;
}

fn noteFxSetEnv(alloc: Allocator, env_name: []const u8) !void {
    const owned = try alloc.dupe(u8, env_name);
    errdefer alloc.free(owned);
    try fx_set_env_names.put(alloc, owned, {});
}

/// Removes a saved key and the in-process value `store` may have set. An
/// environment variable supplied by the outer shell is deliberately left
/// alone: it is not fx's to delete and still wins by design.
pub fn remove(alloc: Allocator, env_name: []const u8) !void {
    if (env_name.len == 0) return;
    if (fx_set_env_names.fetchRemove(env_name)) |entry| {
        alloc.free(entry.key);
        io_mod.unsetProcessEnv(env_name) catch {};
    }
    if (!native_keychain.isAvailable() or native_keychain.isDisabled()) return;
    _ = native_keychain.deleteProviderKey(alloc, env_name) catch |err| switch (err) {
        error.KeychainItemNotFound => false,
        else => return err,
    };
}

/// Env names fx wrote into this process via `store`. Only these may be
/// removed on clear; a variable from the outer shell is the user's own.
var fx_set_env_names: std.StringHashMapUnmanaged(void) = .empty;
