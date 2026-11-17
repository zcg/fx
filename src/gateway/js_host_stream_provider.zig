const stream_provider = @import("../core/agent/stream_provider.zig");
const host_stream_provider = @import("host_stream_provider.zig");
const builtin_gateway = @import("../builtins/gateway.zig");
const host_link = @import("../core/hosts/js_host_link.zig");

const fx_http_stream_open = host_link.declare("fx_http_stream_open", *const fn (
    method_ptr: [*]const u8,
    method_len: usize,
    url_ptr: [*]const u8,
    url_len: usize,
    headers_ptr: [*]const u8,
    headers_len: usize,
    body_ptr: [*]const u8,
    body_len: usize,
) callconv(.c) i32, fx_http_stream_open_unlinked);

fn fx_http_stream_open_unlinked(
    method_ptr: [*]const u8,
    method_len: usize,
    url_ptr: [*]const u8,
    url_len: usize,
    headers_ptr: [*]const u8,
    headers_len: usize,
    body_ptr: [*]const u8,
    body_len: usize,
) callconv(.c) i32 {
    _ = method_ptr;
    _ = method_len;
    _ = url_ptr;
    _ = url_len;
    _ = headers_ptr;
    _ = headers_len;
    _ = body_ptr;
    _ = body_len;
    unreachable;
}

const fx_http_stream_status = host_link.declare("fx_http_stream_status", *const fn (handle: i32, status_out: *u16) callconv(.c) i32, fx_http_stream_status_unlinked);

fn fx_http_stream_status_unlinked(handle: i32, status_out: *u16) callconv(.c) i32 {
    _ = handle;
    _ = status_out;
    unreachable;
}

const fx_http_stream_next = host_link.declare("fx_http_stream_next", *const fn (handle: i32, out_ptr: [*]u8, out_cap: usize) callconv(.c) i32, fx_http_stream_next_unlinked);

fn fx_http_stream_next_unlinked(handle: i32, out_ptr: [*]u8, out_cap: usize) callconv(.c) i32 {
    _ = handle;
    _ = out_ptr;
    _ = out_cap;
    unreachable;
}

const fx_http_stream_close = host_link.declare("fx_http_stream_close", *const fn (handle: i32) callconv(.c) void, fx_http_stream_close_unlinked);

fn fx_http_stream_close_unlinked(handle: i32) callconv(.c) void {
    _ = handle;
    unreachable;
}

const fx_http_stream_retry_after = host_link.declare("fx_http_stream_retry_after", *const fn (handle: i32) callconv(.c) i32, fx_http_stream_retry_after_unlinked);

fn fx_http_stream_retry_after_unlinked(handle: i32) callconv(.c) i32 {
    _ = handle;
    unreachable;
}

/// The JS host's streaming fetch, shared by every model route in this runtime.
pub const transport = host_stream_provider.Transport{
    .context = null,
    .open_fn = open,
    .status_fn = status,
    .next_fn = next,
    .close_fn = close,
    .retry_after_fn = retryAfter,
};

const provider_context = host_stream_provider.initContext(builtin_gateway.buildAgentRequest, .{ .resolve = builtin_gateway.agentChatUrl }, transport);

pub fn provider() stream_provider.Provider {
    return host_stream_provider.provider(@constCast(&provider_context));
}

fn open(_: ?*anyopaque, method: []const u8, url: []const u8, headers: []const u8, body: []const u8) !i32 {
    const handle = fx_http_stream_open(method.ptr, method.len, url.ptr, url.len, headers.ptr, headers.len, body.ptr, body.len);
    if (handle < 0) return error.HostStreamFailed;
    return handle;
}

fn status(_: ?*anyopaque, handle: i32, status_out: *u16) i32 {
    return fx_http_stream_status(handle, status_out);
}

fn next(_: ?*anyopaque, handle: i32, out: []u8) i32 {
    return fx_http_stream_next(handle, out.ptr, out.len);
}

fn close(_: ?*anyopaque, handle: i32) void {
    fx_http_stream_close(handle);
}

fn retryAfter(_: ?*anyopaque, handle: i32) i32 {
    return fx_http_stream_retry_after(handle);
}
