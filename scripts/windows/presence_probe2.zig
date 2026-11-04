//! Confirms the fix direction: the same file checks complete in a worker that
//! initializes its own Io, and hang when it borrows the main thread's.

const std = @import("std");

var done = std.atomic.Value(bool).init(false);

fn workerOwnIo() void {
    // The worker builds its own Io, as the fix requires.
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    const io = threaded.io();
    var home_dir = std.Io.Dir.openDirAbsolute(io, "C:\\Users\\zcg", .{ .iterate = true }) catch {
        std.debug.print("worker: openDirAbsolute failed\n", .{});
        return;
    };
    defer home_dir.close(io);
    const names = [_][]const u8{ "auth.json", "codex-auth.json", "grok-auth.json", "settings.json" };
    for (names) |name| {
        var file = home_dir.openFile(io, name, .{
            .mode = .read_only,
            .allow_directory = false,
        }) catch continue;
        file.close(io);
    }
    done.store(true, .release);
}

pub fn main() !void {
    const thread = std.Thread.spawn(.{}, workerOwnIo, .{}) catch |err| {
        std.debug.print("spawn failed: {s}\n", .{@errorName(err)});
        return;
    };
    var waited: usize = 0;
    while (!done.load(.acquire)) {
        waited += 1;
        if (waited > 500) {
            std.debug.print("TIMEOUT: worker did not finish in 5s\n", .{});
            return;
        }
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    thread.join();
    std.debug.print("worker with own Io finished after {d} polls\n", .{waited});
}
