//! Reproduces fx's catalog warmup: a detached thread performs an HTTP GET
//! through `std.Io.Threaded` against the local gateway, and the main thread
//! waits with a real sleep. This isolates whether the background fetch itself
//! works on Windows.

const std = @import("std");
const io_mod = @import("io");

extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;

var done = std.atomic.Value(bool).init(false);
var outcome = std.atomic.Value(u32).init(0); // 0 none, 1 ok, 2 failed
var detail: ?[]const u8 = null;

fn worker(alloc: std.mem.Allocator) void {
    const io = io_mod.getIo();
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();
    const uri = std.Uri.parse("http://127.0.0.1:3425/v1/models") catch {
        outcome.store(2, .release);
        done.store(true, .release);
        return;
    };
    var req = client.request(.GET, uri, .{
        .extra_headers = &.{.{ .name = "authorization", .value = "Bearer magpie" }},
    }) catch |err| {
        detail = @errorName(err);
        outcome.store(2, .release);
        done.store(true, .release);
        return;
    };
    defer req.deinit();
    req.sendBodiless() catch |err| {
        detail = @errorName(err);
        outcome.store(2, .release);
        done.store(true, .release);
        return;
    };
    var redirect_buffer: [8 * 1024]u8 = undefined;
    const response = req.receiveHead(&redirect_buffer) catch |err| {
        detail = @errorName(err);
        outcome.store(2, .release);
        done.store(true, .release);
        return;
    };
    detail = @tagName(response.head.status);
    outcome.store(1, .release);
    done.store(true, .release);
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    const thread = std.Thread.spawn(.{}, worker, .{alloc}) catch |err| {
        std.debug.print("spawn failed: {s}\n", .{@errorName(err)});
        return;
    };
    var waited: usize = 0;
    while (!done.load(.acquire) and waited < 1500) : (waited += 1) Sleep(10);
    if (!done.load(.acquire)) {
        std.debug.print("TIMEOUT after {d}ms: background HTTP never returned\n", .{waited * 10});
        return;
    }
    thread.join();
    std.debug.print("background HTTP finished in {d}ms, ok={} detail={s}\n", .{
        waited * 10,
        outcome.load(.acquire) == 1,
        detail orelse "none",
    });
}
