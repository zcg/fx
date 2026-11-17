const std = @import("std");
const prompt_history_provider = @import("prompt_history_provider.zig");
const json_decode = @import("../shared/json_decode.zig");
const host_link = @import("../hosts/js_host_link.zig");

const Allocator = std.mem.Allocator;
const initial_capacity: usize = 4 * 1024;
const max_response_bytes: usize = 1024 * 1024;

const fx_prompt_history_available = host_link.declare("fx_prompt_history_available", *const fn () callconv(.c) i32, fx_prompt_history_available_unlinked);

fn fx_prompt_history_available_unlinked() callconv(.c) i32 {
    unreachable;
}

const fx_prompt_history_load = host_link.declare("fx_prompt_history_load", *const fn (
    workspace_ptr: [*]const u8,
    workspace_len: usize,
    limit: usize,
    out_ptr: [*]u8,
    out_cap: usize,
) callconv(.c) i32, fx_prompt_history_load_unlinked);

fn fx_prompt_history_load_unlinked(
    workspace_ptr: [*]const u8,
    workspace_len: usize,
    limit: usize,
    out_ptr: [*]u8,
    out_cap: usize,
) callconv(.c) i32 {
    _ = workspace_ptr;
    _ = workspace_len;
    _ = limit;
    _ = out_ptr;
    _ = out_cap;
    unreachable;
}

const fx_prompt_history_append = host_link.declare("fx_prompt_history_append", *const fn (
    timestamp_ms: i64,
    workspace_ptr: [*]const u8,
    workspace_len: usize,
    text_ptr: [*]const u8,
    text_len: usize,
) callconv(.c) i32, fx_prompt_history_append_unlinked);

fn fx_prompt_history_append_unlinked(
    timestamp_ms: i64,
    workspace_ptr: [*]const u8,
    workspace_len: usize,
    text_ptr: [*]const u8,
    text_len: usize,
) callconv(.c) i32 {
    _ = timestamp_ms;
    _ = workspace_ptr;
    _ = workspace_len;
    _ = text_ptr;
    _ = text_len;
    unreachable;
}

const fx_prompt_history_clear = host_link.declare("fx_prompt_history_clear", *const fn (
    workspace_ptr: [*]const u8,
    workspace_len: usize,
) callconv(.c) i32, fx_prompt_history_clear_unlinked);

fn fx_prompt_history_clear_unlinked(
    workspace_ptr: [*]const u8,
    workspace_len: usize,
) callconv(.c) i32 {
    _ = workspace_ptr;
    _ = workspace_len;
    unreachable;
}

pub fn available() bool {
    return fx_prompt_history_available() == 1;
}

pub const provider = prompt_history_provider.Provider{
    .load_recent_fn = loadRecent,
    .append_fn = append,
    .clear_workspace_fn = clearWorkspace,
    .display_name = "embedding SDK",
};

fn loadRecent(
    _: ?*anyopaque,
    alloc: Allocator,
    workspace_root: []const u8,
    limit: usize,
) ![]prompt_history_provider.LoadedEntry {
    var capacity = initial_capacity;
    while (capacity <= max_response_bytes) : (capacity *= 2) {
        const buffer = try alloc.alloc(u8, capacity);
        const result = fx_prompt_history_load(
            workspace_root.ptr,
            workspace_root.len,
            limit,
            buffer.ptr,
            buffer.len,
        );
        if (result == -2) {
            alloc.free(buffer);
            continue;
        }
        if (result < 0) {
            alloc.free(buffer);
            return error.PromptHistoryHostFailure;
        }
        const length: usize = @intCast(result);
        if (length > buffer.len) {
            alloc.free(buffer);
            return error.PromptHistoryHostFailure;
        }
        defer alloc.free(buffer);
        const parsed = try json_decode.parseFromSlice([]const []const u8, alloc, buffer[0..length], .{});
        defer parsed.deinit();
        const entries = try alloc.alloc(prompt_history_provider.LoadedEntry, parsed.value.len);
        errdefer alloc.free(entries);
        var initialized: usize = 0;
        errdefer for (entries[0..initialized]) |entry| alloc.free(entry.text);
        for (parsed.value, 0..) |text, index| {
            entries[index] = .{ .text = try alloc.dupe(u8, text) };
            initialized += 1;
        }
        return entries;
    }
    return error.PromptHistoryResponseTooLarge;
}

fn append(
    _: ?*anyopaque,
    _: Allocator,
    timestamp_ms: i64,
    workspace_root: []const u8,
    text: []const u8,
) !prompt_history_provider.AppendOutcome {
    return switch (fx_prompt_history_append(
        timestamp_ms,
        workspace_root.ptr,
        workspace_root.len,
        text.ptr,
        text.len,
    )) {
        0 => .appended,
        1 => .duplicate,
        2 => .record_too_large,
        else => error.PromptHistoryHostFailure,
    };
}

fn clearWorkspace(
    _: ?*anyopaque,
    _: Allocator,
    workspace_root: []const u8,
) !void {
    if (fx_prompt_history_clear(workspace_root.ptr, workspace_root.len) != 0) {
        return error.PromptHistoryHostFailure;
    }
}
