const std = @import("std");
const host_link = @import("../hosts/js_host_link.zig");

const Allocator = std.mem.Allocator;

pub const LoadError = error{
    ValueTooLarge,
    HostFailure,
    OutOfMemory,
};

pub const SaveError = error{HostFailure};

const initial_capacity = 256;
const max_value_bytes = 16 * 1024;

const fx_config_get = host_link.declare("fx_config_get", *const fn (
    id_ptr: [*]const u8,
    id_len: usize,
    out_ptr: [*]u8,
    out_cap: usize,
) callconv(.c) i32, fx_config_get_unlinked);

fn fx_config_get_unlinked(
    id_ptr: [*]const u8,
    id_len: usize,
    out_ptr: [*]u8,
    out_cap: usize,
) callconv(.c) i32 {
    _ = id_ptr;
    _ = id_len;
    _ = out_ptr;
    _ = out_cap;
    unreachable;
}

const fx_config_set = host_link.declare("fx_config_set", *const fn (
    id_ptr: [*]const u8,
    id_len: usize,
    value_ptr: [*]const u8,
    value_len: usize,
) callconv(.c) i32, fx_config_set_unlinked);

fn fx_config_set_unlinked(
    id_ptr: [*]const u8,
    id_len: usize,
    value_ptr: [*]const u8,
    value_len: usize,
) callconv(.c) i32 {
    _ = id_ptr;
    _ = id_len;
    _ = value_ptr;
    _ = value_len;
    unreachable;
}

/// Loads a host-owned configuration value. The caller owns the returned bytes.
pub fn load(alloc: Allocator, id: []const u8) LoadError!?[]u8 {
    var capacity: usize = initial_capacity;
    while (capacity <= max_value_bytes) : (capacity *= 2) {
        const value = alloc.alloc(u8, capacity) catch return error.OutOfMemory;
        const result = fx_config_get(id.ptr, id.len, value.ptr, value.len);
        if (result >= 0) {
            const length: usize = @intCast(result);
            if (length > value.len) {
                alloc.free(value);
                return error.HostFailure;
            }
            return alloc.realloc(value, length) catch {
                alloc.free(value);
                return error.OutOfMemory;
            };
        }
        alloc.free(value);
        switch (result) {
            -2 => return null,
            -3 => continue,
            else => return error.HostFailure,
        }
    }
    return error.ValueTooLarge;
}

/// Persists a value only after fx has accepted and applied it.
pub fn setAccepted(id: []const u8, value: []const u8) SaveError!void {
    if (fx_config_set(id.ptr, id.len, value.ptr, value.len) != 0) {
        return error.HostFailure;
    }
}
