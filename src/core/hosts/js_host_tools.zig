const std = @import("std");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const tool_content = @import("../tooling/tool_content.zig");
const image_data = @import("../images/image_data.zig");
const host_link = @import("js_host_link.zig");

const Allocator = std.mem.Allocator;
const bridge_max_result_bytes: usize = 64 * 1024;

const fx_host_tool_call = host_link.declare("fx_host_tool_call", *const fn (
    name_ptr: [*]const u8,
    name_len: usize,
    arguments_ptr: [*]const u8,
    arguments_len: usize,
    output_ptr: [*]u8,
    output_cap: usize,
    status_ptr: *u8,
    call_id_ptr: [*]const u8,
    call_id_len: usize,
) callconv(.c) i32, fx_host_tool_call_unlinked);

fn fx_host_tool_call_unlinked(
    name_ptr: [*]const u8,
    name_len: usize,
    arguments_ptr: [*]const u8,
    arguments_len: usize,
    output_ptr: [*]u8,
    output_cap: usize,
    status_ptr: *u8,
    call_id_ptr: [*]const u8,
    call_id_len: usize,
) callconv(.c) i32 {
    _ = name_ptr;
    _ = name_len;
    _ = arguments_ptr;
    _ = arguments_len;
    _ = output_ptr;
    _ = output_cap;
    _ = status_ptr;
    _ = call_id_ptr;
    _ = call_id_len;
    unreachable;
}

const fx_host_tool_result_read = host_link.declare("fx_host_tool_result_read", *const fn (offset: usize, ptr: [*]u8, cap: usize) callconv(.c) i32, fx_host_tool_result_read_unlinked);

fn fx_host_tool_result_read_unlinked(offset: usize, ptr: [*]u8, cap: usize) callconv(.c) i32 {
    _ = offset;
    _ = ptr;
    _ = cap;
    unreachable;
}

const fx_host_tool_result_release = host_link.declare("fx_host_tool_result_release", *const fn () callconv(.c) void, fx_host_tool_result_release_unlinked);

fn fx_host_tool_result_release_unlinked() callconv(.c) void {
    unreachable;
}

var provider_context: u8 = 0;

pub fn provider() tool_dispatch.HostToolProvider {
    return .{
        .context = @ptrCast(&provider_context),
        .call_fn = call,
    };
}

fn call(
    _: *anyopaque,
    alloc: Allocator,
    name: []const u8,
    call_id: []const u8,
    arguments_json: []const u8,
    max_result_bytes: usize,
    cancel_flag: ?*std.atomic.Value(bool),
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
    const cap = @min(max_result_bytes, bridge_max_result_bytes);
    if (cap == 0) return .{ .failure = try alloc.dupe(u8, "Host tool result limit is zero") };
    const output = try alloc.alloc(u8, cap);
    defer alloc.free(output);
    var status: u8 = 0;
    const raw = fx_host_tool_call(
        name.ptr,
        name.len,
        arguments_json.ptr,
        arguments_json.len,
        output.ptr,
        output.len,
        &status,
        call_id.ptr,
        call_id.len,
    );
    if (raw == -2) {
        if (cancel_flag) |flag| flag.store(true, .seq_cst);
        return error.Cancelled;
    }
    if (raw < 0) {
        return .{ .failure = try alloc.dupe(u8, switch (raw) {
            -3 => "Host tool result exceeded the configured limit",
            else => "Host tool failed",
        }) };
    }
    defer fx_host_tool_result_release();
    const len: usize = @intCast(raw);
    if (status == 2 or status == 3) {
        if (len > image_data.max_result_frame_bytes) return .{ .failure = try alloc.dupe(u8, "Host image result exceeded its frame limit") };
        const encoded = if (len <= output.len) output[0..len] else read: {
            const collected = try alloc.alloc(u8, len);
            errdefer alloc.free(collected);
            var offset: usize = 0;
            while (offset < len) {
                if (cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
                const count = fx_host_tool_result_read(offset, collected[offset..].ptr, @min(64 * 1024, len - offset));
                if (count <= 0 or @as(usize, @intCast(count)) > len - offset) {
                    const failure = try alloc.dupe(u8, "Host image result transfer failed");
                    alloc.free(collected);
                    return .{ .failure = failure };
                }
                offset += @intCast(count);
            }
            break :read collected;
        };
        defer if (len > output.len) alloc.free(encoded);
        return tool_content.parseRichResult(alloc, encoded, max_result_bytes, status == 3);
    }
    if (len > output.len or status > 1) {
        return .{ .failure = try alloc.dupe(u8, "Host tool returned an invalid result") };
    }
    const owned = try alloc.dupe(u8, output[0..len]);
    return if (status == 1) .{ .failure = owned } else .{ .success = owned };
}
