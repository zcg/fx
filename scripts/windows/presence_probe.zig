//! Reproduces the auth inventory's exact file checks inside a detached thread:
//! openDirAbsolute on the home's parent, openDir on the profile name, openFile
//! on each credential file. The inventory thread hangs in the TUI; this tells
//! whether the same sequence completes outside it.

const std = @import("std");
fn homeDir() ?[]const u8 {
    return "C:\\Users\\zcg";
}
fn getIo() std.Io {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    return threaded.io();
}

var done = std.atomic.Value(bool).init(false);

fn worker() void {
    var io_thread: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    const home = homeDir() orelse return;
    var home_dir = std.Io.Dir.openDirAbsolute(io_thread.io(), home, .{ .iterate = true }) catch |err| {
        std.debug.print("openDirAbsolute failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer home_dir.close(io_thread.io());
    const names = [_][]const u8{ "auth.json", "codex-auth.json", "grok-auth.json", "settings.json" };
    for (names) |name| {
        var file = home_dir.openFile(io_thread.io(), name, .{
            .mode = .read_only,
            .allow_directory = false,
        }) catch continue;
        file.close(io_thread.io());
    }
    done.store(true, .release);
}

pub fn main() !void {
    const thread = std.Thread.spawn(.{}, worker, .{}) catch |err| {
        std.debug.print("spawn failed: {s}\n", .{@errorName(err)});
        return;
    };
    var waited: usize = 0;
    while (!done.load(.acquire)) {
        waited += 1;
        if (waited > 500) {
            std.debug.print("TIMEOUT: worker did not finish in 5s (500 x 10ms)\n", .{});
            return;
        }
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    thread.join();
    std.debug.print("worker finished after {d} polls\n", .{waited});
}
