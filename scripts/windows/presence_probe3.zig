//! Isolates which step hangs on a worker thread: openDirAbsolute alone,
//! openFile alone, or the combination.

const std = @import("std");

var step = std.atomic.Value(usize).init(0);
var failed = std.atomic.Value(bool).init(false);

fn worker() void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    const io = threaded.io();
    var home_dir = std.Io.Dir.openDirAbsolute(io, "C:\\Users\\zcg", .{ .iterate = true }) catch {
        std.debug.print("step1 openDirAbsolute failed\n", .{});
        failed.store(true, .release);
        return;
    };
    _ = step.fetchAdd(1, .seq_cst); // step 1 done
    defer home_dir.close(io);
    var file = home_dir.openFile(io, "settings.json", .{
        .mode = .read_only,
        .allow_directory = false,
    }) catch {
        std.debug.print("step2 openFile failed (ok if absent)\n", .{});
        failed.store(true, .release);
        return;
    };
    _ = step.fetchAdd(1, .seq_cst); // step 2 done
    file.close(io);
}

pub fn main() !void {
    const thread = std.Thread.spawn(.{}, worker, .{}) catch return;
    const want = 2;
    var waited: usize = 0;
    while (step.load(.seq_cst) < want and !failed.load(.seq_cst)) {
        waited += 1;
        if (waited > 300) {
            std.debug.print("TIMEOUT at step {d}/2\n", .{step.load(.seq_cst)});
            return;
        }
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    thread.join();
    std.debug.print("all steps done after {d} polls\n", .{waited});
}
