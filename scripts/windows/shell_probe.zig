//! Confirms both shells are findable, not just the preferred one.

const std = @import("std");
const windows_shell = @import("windows_shell");

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    std.debug.print("=== preferred (pwsh) ===\n", .{});
    if (try windows_shell.detectPreferred(alloc, "pwsh")) |found| { var shell = found;
        defer shell.deinit(alloc);
        std.debug.print("  {s}\n", .{shell.path});
    } else std.debug.print("  not found\n", .{});

    std.debug.print("=== bash ===\n", .{});
    if (try windows_shell.detectPreferred(alloc, "bash")) |found| { var shell = found;
        defer shell.deinit(alloc);
        std.debug.print("  {s} (kind={s})\n", .{ shell.path, @tagName(shell.kind) });
    } else std.debug.print("  not found\n", .{});

    std.debug.print("=== cmd ===\n", .{});
    if (try windows_shell.detectPreferred(alloc, "cmd")) |found| { var shell = found;
        defer shell.deinit(alloc);
        std.debug.print("  {s}\n", .{shell.path});
    } else std.debug.print("  not found\n", .{});
}
