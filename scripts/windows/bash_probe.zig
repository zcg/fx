//! Traces each step of the Git Bash lookup.

const std = @import("std");
const io_mod = @import("io");

fn exists(path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io_mod.getIo(), path, .{}) catch return false;
    file.close(io_mod.getIo());
    return true;
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    const candidates = [_][]const u8{
        "C:\\Program Files\\Git\\bin\\bash.exe",
        "C:\\Program Files\\Git\\usr\\bin\\bash.exe",
        "D:\\Applications\\Scoop\\shims\\bash.exe",
        "D:\\Applications\\Scoop\\apps\\git\\current\\bin\\bash.exe",
    };
    for (candidates) |c| std.debug.print("{s} -> {}\n", .{ c, exists(c) });

    const path = io_mod.getenv("PATH") orelse {
        std.debug.print("no PATH\n", .{});
        return;
    };
    var it = std.mem.splitScalar(u8, path, ';');
    var hits: usize = 0;
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const joined = try std.Io.Dir.path.join(alloc, &.{ dir, "git.exe" });
        defer alloc.free(joined);
        if (exists(joined)) {
            std.debug.print("git.exe on PATH: {s}\n", .{joined});
            hits += 1;
            if (hits > 3) break;
        }
    }
    if (hits == 0) std.debug.print("no git.exe on PATH\n", .{});
}
