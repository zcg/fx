//! Narrows the hang: on a threaded-pool worker, does statFile (NtCreateFile
//! family) hang, while the task itself starts and finishes? The task does no
//! file work at all in the first variant.

const std = @import("std");

var ran = std.atomic.Value(bool).init(false);
var file_done = std.atomic.Value(bool).init(false);

fn plainTask(group: *std.Io.Group, io: std.Io) void {
    _ = io;
    _ = group;
    ran.store(true, .release);
}

fn fileTask(group: *std.Io.Group, io: std.Io) void {
    _ = group;
    // A stat against a path that exists.
    if (std.Io.Dir.cwd().statFile(io, "C:\\Users\\zcg\\settings.json", .{})) |_| {} else |_| {}
    file_done.store(true, .release);
}

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    const io = threaded.io();

    // 1. A task that touches nothing.
    {
        var group: std.Io.Group = .init;
        group.async(io, plainTask, .{ &group, io });
        var waited: usize = 0;
        while (!ran.load(.acquire) and waited < 300) : (waited += 1) {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
        std.debug.print("plain task ran: {} after {d} polls\n", .{ ran.load(.acquire), waited });
        group.await(io) catch {};
    }

    // 2. A task that stats a file.
    {
        var group: std.Io.Group = .init;
        group.async(io, fileTask, .{ &group, io });
        var waited: usize = 0;
        while (!file_done.load(.acquire) and waited < 300) : (waited += 1) {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
        std.debug.print("file task done: {} after {d} polls\n", .{ file_done.load(.acquire), waited });
        group.await(io) catch {};
    }
}
