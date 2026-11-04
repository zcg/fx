// Walks a skills directory the way fx does, reporting the exact step that fails.
//
// Usage: skills_probe.exe <dir> [<dir> ...]
//
// For each directory it opens the path component by component with
// `follow_symlinks = false` (what fx's `openDirAbsoluteNoFollow` does), lists
// every entry, and then stat/opens each child both without and with following a
// symlink. The first line of output names the step that failed and the
// NTSTATUS-code error it reported, so a reparse point can be identified by name
// instead of guessed at.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(alloc);
    defer args.deinit();
    _ = args.next();

    while (args.next()) |dir_path| {
        std.debug.print("\n=== {s} ===\n", .{dir_path});
        probeDirectory(io, alloc, dir_path) catch |err| {
            std.debug.print("  FATAL: {s}\n", .{@errorName(err)});
        };
    }
}

fn probeDirectory(io: std.Io, _: std.mem.Allocator, dir_path: []const u8) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("  openDirAbsolute iterate failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer dir.close(io);

    var it = dir.iterate();
    var count: usize = 0;
    while (it.next(io) catch |err| {
        std.debug.print("  iterate failed after {d} entries: {s}\n", .{ count, @errorName(err) });
        return;
    }) |entry| {
        count += 1;
        std.debug.print("  [{d}] {s} kind={s}\n", .{ count, entry.name, @tagName(entry.kind) });

        // The stat fx performs while deciding whether an entry is a skill.
        const no_follow = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| {
            std.debug.print("      stat(no follow) FAILED: {s}\n", .{@errorName(err)});
            continue;
        };
        std.debug.print("      stat(no follow) kind={s}\n", .{@tagName(no_follow.kind)});

        const followed = dir.statFile(io, entry.name, .{ .follow_symlinks = true }) catch |err| {
            std.debug.print("      stat(follow) FAILED: {s}\n", .{@errorName(err)});
            continue;
        };
        std.debug.print("      stat(follow) kind={s}\n", .{@tagName(followed.kind)});

        if (followed.kind != .directory) continue;

        // Opening the child is the next thing fx does.
        var child = dir.openDir(io, entry.name, .{ .follow_symlinks = false }) catch |err| {
            std.debug.print("      openDir(no follow) FAILED: {s}\n", .{@errorName(err)});
            continue;
        };
        child.close(io);
        std.debug.print("      openDir(no follow) ok\n", .{});

        var child_followed = dir.openDir(io, entry.name, .{ .follow_symlinks = true }) catch |err| {
            std.debug.print("      openDir(follow) FAILED: {s}\n", .{@errorName(err)});
            continue;
        };
        defer child_followed.close(io);
        std.debug.print("      openDir(follow) ok\n", .{});

        // A skill directory carries SKILL.md.
        const skill_md = child_followed.statFile(io, "SKILL.md", .{ .follow_symlinks = false }) catch |err| {
            std.debug.print("      SKILL.md: {s}\n", .{@errorName(err)});
            continue;
        };
        std.debug.print("      SKILL.md kind={s} size={d}\n", .{ @tagName(skill_md.kind), skill_md.size });
    }
    std.debug.print("  total entries={d}\n", .{count});
}
