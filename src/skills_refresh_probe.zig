//! Runs the skills refresh path the interactive app runs, and prints the exact
//! error each step produces. The app only surfaces "failed to submit prompt",
//! so this probe is what names the step and the error code.

const std = @import("std");
const skill_runtime = @import("core/skills/skill_runtime.zig");
const skill_contract = @import("core/skills/skill_contract.zig");
const builtin_skills = @import("builtins/skills.zig");
const io_mod = @import("core/shared/io.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.page_allocator;
    const c_alloc = std.heap.c_allocator;

    // The app installs the environment `main` received before anything reads a
    // variable. Without it every lookup returns null, which is what made the
    // first run of this probe report a home directory that Windows always has.
    io_mod.setEnvironMap(init.environ_map);

    const home = io_mod.homeDir();
    std.debug.print("home={?s}\n", .{home});
    if (home) |h| {
        const resolved = io_mod.realpathAlloc(c_alloc, h) catch |err| blk: {
            std.debug.print("realpath(home) failed err={s}\n", .{@errorName(err)});
            break :blk try c_alloc.dupe(u8, h);
        };
        defer c_alloc.free(resolved);
        std.debug.print("home_resolved={s}\n", .{resolved});
    }

    const workspace_root = io_mod.realpathAlloc(c_alloc, ".") catch |err| {
        std.debug.print("cwd failed err={s}\n", .{@errorName(err)});
        return;
    };
    defer c_alloc.free(workspace_root);
    std.debug.print("cwd={s}\n", .{workspace_root});

    const managed = app_runtime_setup_resolveManagedSkillsDir(c_alloc) catch |err| blk: {
        std.debug.print("managed skills dir failed err={s}\n", .{@errorName(err)});
        break :blk null;
    };
    defer if (managed) |value| c_alloc.free(value);
    std.debug.print("managed_skills_dir={?s}\n", .{managed});

    const skills_dir = managed orelse "";
    // What the roots actually are, and whether each is absolute. openDirAbsolute
    // asserts on a relative path, so this is the shape that decides it.
    const roots_before = skill_runtime.skillRootsForProbe(
        c_alloc,
        workspace_root,
        home,
        skills_dir,
        builtin_skills.root_policy,
    ) catch |err| {
        std.debug.print("skillRootsForProbe FAILED err={s}\n", .{@errorName(err)});
        return;
    };
    defer {
        for (roots_before) |root| c_alloc.free(root.path);
        c_alloc.free(roots_before);
    }
    for (roots_before) |root| {
        std.debug.print("root={s} absolute={} authority={?s}\n", .{
            root.path,
            std.fs.path.isAbsolute(root.path),
            root.read_authority,
        });
    }

    // Open each root the way discovery does, and report the exact error.
    for (roots_before) |root| {
        const opened = skill_runtime.openSkillRootForProbe(c_alloc, root);
        switch (opened) {
            .dir => |dir| {
                var mutable = dir;
                mutable.close(io_mod.getIo());
                std.debug.print("open OK   {s}\n", .{root.path});
            },
            .err => |err| std.debug.print("open FAIL {s} err={s}\n", .{ root.path, @errorName(err) }),
        }
    }

    std.debug.print("--- loadVisibleSkills ---\n", .{});
    var discovery = skill_runtime.loadVisibleSkills(
        c_alloc,
        workspace_root,
        home,
        skills_dir,
        builtin_skills.root_policy,
    ) catch |err| {
        std.debug.print("loadVisibleSkills FAILED err={s}\n", .{@errorName(err)});
        return;
    };
    defer discovery.deinit(c_alloc);
    std.debug.print("skills={d} diagnostics={d}\n", .{ discovery.skills.len, discovery.diagnostics.len });
    for (discovery.diagnostics, 0..) |diagnostic, index| {
        if (index >= 10) break;
        std.debug.print("  diag path={s} cause={t} scope={t}\n", .{ diagnostic.path, diagnostic.cause, diagnostic.scope });
    }

    std.debug.print("--- Runtime refresh ---\n", .{});
    var runtime: skill_runtime.Runtime = .{};
    defer runtime.deinit(alloc);
    const generation = try runtime.requestRefresh(c_alloc, workspace_root, home, builtin_skills.root_policy);
    std.debug.print("generation={d}\n", .{generation});
    var guard: usize = 0;
    while (guard < 3000) : (guard += 1) {
        const completion = runtime.pollRefresh(c_alloc, workspace_root, builtin_skills.root_policy) catch |err| {
            std.debug.print("pollRefresh FAILED err={s}\n", .{@errorName(err)});
            return;
        };
        switch (completion) {
            .none => {},
            else => {
                std.debug.print("completion={t}\n", .{completion});
                break;
            },
        }
        std.debug.print("status={t}\n", .{runtime.generationStatus(generation)});
        io_mod.sleep(20 * std.time.ns_per_ms);
    }
    std.debug.print("final status={t}\n", .{runtime.generationStatus(generation)});
}

fn app_runtime_setup_resolveManagedSkillsDir(alloc: std.mem.Allocator) !?[]u8 {
    const home = io_mod.homeDir() orelse return null;
    const resolved = io_mod.realpathAlloc(alloc, home) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return try alloc.dupe(u8, home),
    };
    defer alloc.free(resolved);
    const profile_paths = @import("core/shared/profile_paths.zig");
    return try profile_paths.managedSkillsDir(alloc, resolved);
}
