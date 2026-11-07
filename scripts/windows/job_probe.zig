//! Proves a Windows job object ends a grandchild process, which is what a stdio
//! MCP server leaves behind when it is started through a wrapper.
//!
//! Run with `zig build probe-job` from the repository root. The probe starts a
//! `cmd.exe` that runs a long `ping`, records the grandchild's process id from
//! the parent link, terminates the job, and reports whether that process is
//! still there. Terminating `cmd.exe` alone would leave `ping.exe` behind, which
//! is the bug the job exists to fix.

const std = @import("std");
const builtin = @import("builtin");
const job_mod = @import("job");

pub fn main(init: std.process.Init) !void {
    if (comptime builtin.target.os.tag != .windows) {
        std.debug.print("probe-job: Windows only\n", .{});
        return;
    }
    const zio = init.io;
    const alloc = init.gpa;

    const job = job_mod.create() orelse {
        std.debug.print("probe-job: CreateJobObject failed\n", .{});
        return error.JobUnavailable;
    };
    defer job.deinit();

    var child = try std.process.spawn(zio, .{
        .argv = &.{ "cmd.exe", "/c", "ping -n 60 127.0.0.1" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const pid = child.id.?;
    const assigned = job.assign(pid);
    std.debug.print("probe-job: assigned={}\n", .{assigned});

    // `Child.Id` is a process handle on Windows, not the number CIM reports,
    // so the number has to come from `GetProcessId`.
    const pid_number = getProcessId(pid);
    std.debug.print("probe-job: pid={d}\n", .{pid_number});

    // Let cmd start ping before the tree is looked at or ended.
    std.Io.sleep(zio, .fromMilliseconds(1_500), .awake) catch {};

    const grandchild = try childOf(alloc, zio, pid_number);
    const before = grandchild != null and processExists(zio, alloc, grandchild.?);
    std.debug.print("probe-job: grandchild before terminate={}\n", .{before});

    job.terminate();
    std.Io.sleep(zio, .fromMilliseconds(800), .awake) catch {};
    const after = grandchild != null and processExists(zio, alloc, grandchild.?);
    std.debug.print("probe-job: grandchild after terminate={}\n", .{after});
    _ = child.wait(zio) catch {};

    if (grandchild == null) {
        std.debug.print("probe-job: CONCERN, no grandchild was found\n", .{});
        return error.NoGrandchild;
    }
    if (!before) {
        std.debug.print("probe-job: CONCERN, the grandchild had already exited\n", .{});
        return error.NoGrandchild;
    }
    if (after) {
        std.debug.print("probe-job: FAIL, the job left the grandchild running\n", .{});
        return error.LeftRunning;
    }
    std.debug.print("probe-job: PASS, the job ended the whole tree\n", .{});
}

/// The number Windows and CIM report for a process handle.
fn getProcessId(handle: std.os.windows.HANDLE) usize {
    return GetProcessId(handle);
}

extern "kernel32" fn GetProcessId(process: std.os.windows.HANDLE) callconv(.winapi) u32;

/// The first child of `parent`, read from CIM, which reports the real parent
/// rather than the localized text `tasklist` prints.
fn childOf(alloc: std.mem.Allocator, zio: std.Io, parent: usize) !?usize {
    const query = try std.fmt.allocPrint(alloc, "Get-CimInstance Win32_Process -Filter \"ParentProcessId={d}\" | Select-Object -ExpandProperty ProcessId", .{parent});
    defer alloc.free(query);
    const result = try std.process.run(alloc, zio, .{
        .argv = &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", query },
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    const first = std.mem.trim(u8, lines.next() orelse return null, " \t\r\n");
    const value = std.fmt.parseInt(usize, first, 10) catch return null;
    return value;
}

/// Whether a process id is still alive.
fn processExists(zio: std.Io, alloc: std.mem.Allocator, pid: usize) bool {
    const query = std.fmt.allocPrint(alloc, "if (Get-Process -Id {d} -ErrorAction SilentlyContinue) {{ 'yes' }} else {{ 'no' }}", .{pid}) catch return false;
    defer alloc.free(query);
    const result = std.process.run(alloc, zio, .{
        .argv = &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", query },
    }) catch return false;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    return std.mem.find(u8, result.stdout, "yes") != null;
}
