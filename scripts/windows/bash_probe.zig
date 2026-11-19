//! Traces each step of the Git Bash lookup.

const std = @import("std");
const io_mod = @import("io");

fn exists(path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io_mod.getIo(), path, .{}) catch return false;
    file.close(io_mod.getIo());
    return true;
}

fn reportCandidate(alloc: std.mem.Allocator, parts: []const []const u8) !void {
    const path = try std.Io.Dir.path.join(alloc, parts);
    defer alloc.free(path);
    std.debug.print("{s} -> {}\n", .{ path, exists(path) });
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    const bash = "bash.exe";
    if (io_mod.getenv("ProgramFiles")) |root| {
        try reportCandidate(alloc, &.{ root, "Git", "bin", bash });
        try reportCandidate(alloc, &.{ root, "Git", "usr", "bin", bash });
    }
    if (io_mod.getenv("ProgramFiles(x86)")) |root| {
        try reportCandidate(alloc, &.{ root, "Git", "bin", bash });
        try reportCandidate(alloc, &.{ root, "Git", "usr", "bin", bash });
    }
    if (io_mod.getenv("LOCALAPPDATA")) |root| {
        try reportCandidate(alloc, &.{ root, "Programs", "Git", "bin", bash });
    }
    if (io_mod.getenv("SCOOP")) |root| {
        try reportCandidate(alloc, &.{ root, "shims", bash });
        try reportCandidate(alloc, &.{ root, "apps", "git", "current", "bin", bash });
    }
    if (io_mod.getenv("USERPROFILE")) |root| {
        try reportCandidate(alloc, &.{ root, "scoop", "shims", bash });
        try reportCandidate(alloc, &.{ root, "scoop", "apps", "git", "current", "bin", bash });
    }

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
