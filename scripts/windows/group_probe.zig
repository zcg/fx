//! Verifies the fix direction: a file-system open dispatched through
//! `Io.Group.async` onto the threaded pool's own worker completes, where the
//! same open on a detached `std.Thread` hung.

const std = @import("std");

var done = std.atomic.Value(bool).init(false);
var step_failed = std.atomic.Value(bool).init(false);

fn task(group: *std.Io.Group, io: std.Io) void {
    _ = group;
    var home_dir = std.Io.Dir.openDirAbsolute(io, "C:\\Users\\zcg", .{ .iterate = true }) catch {
        step_failed.store(true, .release);
        return;
    };
    defer home_dir.close(io);
    var file = home_dir.openFile(io, "settings.json", .{
        .mode = .read_only,
        .allow_directory = false,
    }) catch {
        // Absent is fine; the open itself is what must not hang.
        done.store(true, .release);
        return;
    };
    file.close(io);
    done.store(true, .release);
}

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    const io = threaded.io();
    var group: std.Io.Group = .init;
    defer group.await(io) catch {};
    group.async(io, task, .{ &group, io });
    var waited: usize = 0;
    while (!done.load(.acquire) and !step_failed.load(.acquire)) {
        waited += 1;
        if (waited > 500) {
            std.debug.print("TIMEOUT: dispatched task did not finish in 5s\n", .{});
            return;
        }
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    if (step_failed.load(.acquire)) {
        std.debug.print("task ran but the open failed (still progress: it RAN)\n", .{});
        return;
    }
    std.debug.print("dispatched task finished after {d} polls\n", .{waited});
}
