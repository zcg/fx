//! Probes whether a detached thread that only runs file checks completes on
//! Windows, mirroring the auth inventory's worker.

const std = @import("std");

var done = std.atomic.Value(bool).init(false);

fn worker() void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    const io = threaded.io();
    const names = [_][]const u8{
        "C:\\Users\\zcg\\.fx\\auth.json",
        "C:\\Users\\zcg\\.fx\\settings.json",
        "C:\\Users\\zcg\\.fx\\sessions",
    };
    for (names) |path| {
        _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch {};
    }
    done.store(true, .release);
}

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    const io = threaded.io();
    const thread = std.Thread.spawn(.{}, worker, .{}) catch |err| {
        std.debug.print("spawn failed: {s}\n", .{@errorName(err)});
        return;
    };
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    while (!done.load(.acquire)) {
        const now = std.Io.Clock.Timestamp.now(io, .awake);
        if (start.durationTo(now).raw.toNanoseconds() > 5 * std.time.ns_per_s) {
            std.debug.print("TIMEOUT: worker did not finish in 5s\n", .{});
            return;
        }
        io.sleep(10 * std.time.ns_per_ms) catch {};
    }
    thread.join();
    const end = std.Io.Clock.Timestamp.now(io, .awake);
    std.debug.print("worker finished in {d}ms\n", .{start.durationTo(end).raw / std.time.ns_per_ms});
}
