//! A Windows job object for one stdio MCP server, so the server's descendants
//! cannot outlive fx.
//!
//! POSIX addresses a process group: one signal reaches the child and everything
//! it forked. Windows has no such group; `TerminateProcess` reaches exactly one
//! process, so a server started through `npx`, `uvx`, or a `.cmd` wrapper leaves
//! its own children behind when fx ends. A job object is the equivalent handle:
//! every process assigned to it is in the tree, and closing or terminating the
//! job ends the whole tree.
//!
//! The job is created with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, so fx's exit,
//! clean or not, takes the tree with it.
//!
//! `src/core/shared/windows_job.zig` is the same mechanism for shell commands.
//! The two stay separate because the MCP engine imports only `std` and its own
//! files, and because a server's lifetime differs from a command's: a server is
//! ended by `terminate` while fx keeps running, a command usually just closes
//! its job. Off Windows this compiles to a no-op value.

const std = @import("std");
const builtin = @import("builtin");

pub const supported = builtin.target.os.tag == .windows;

const windows = std.os.windows;

/// The job a server was assigned to. Empty on platforms without job objects.
pub const Job = if (!supported) struct {
    pub fn terminate(self: Job) void {
        _ = self;
    }

    pub fn deinit(self: Job) void {
        _ = self;
    }
} else struct {
    handle: ?windows.HANDLE,

    /// Ends every process still inside the job and releases it.
    pub fn terminate(self: Job) void {
        const handle = self.handle orelse return;
        _ = TerminateJobObject(handle, 1);
        _ = windows.CloseHandle(handle);
    }

    /// Releases the handle. Because the job was created with
    /// `KILL_ON_JOB_CLOSE`, closing the last handle still ends what is inside.
    pub fn deinit(self: Job) void {
        const handle = self.handle orelse return;
        _ = windows.CloseHandle(handle);
    }
};

/// A job holding nothing.
pub const none: Job = if (supported) .{ .handle = null } else .{};

/// The job a server process was assigned to, or `none` when the platform has
/// none or the assignment failed.
///
/// A failure is not fatal: the server still runs, it just may leave children
/// behind, which is what happened before job objects were used at all.
pub fn assign(process: windows.HANDLE) Job {
    if (comptime !supported) return none;
    const handle = CreateJobObjectW(null, null) orelse return none;

    var limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std.mem.zeroes(JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (SetInformationJobObject(
        handle,
        job_object_extended_limit_information,
        &limits,
        @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
    ) == 0) {
        _ = windows.CloseHandle(handle);
        return none;
    }
    if (AssignProcessToJobObject(handle, process) == 0) {
        _ = windows.CloseHandle(handle);
        return none;
    }
    return .{ .handle = handle };
}

const job_object_extended_limit_information: u32 = 9;
const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x00002000;

const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: i64,
    PerJobUserTimeLimit: i64,
    LimitFlags: u32,
    MinimumWorkingSetSize: usize,
    MaximumWorkingSetSize: usize,
    ActiveProcessLimit: u32,
    Affinity: usize,
    PriorityClass: u32,
    SchedulingClass: u32,
};

const IO_COUNTERS = extern struct {
    ReadOperationCount: u64,
    WriteOperationCount: u64,
    OtherOperationCount: u64,
    ReadTransferCount: u64,
    WriteTransferCount: u64,
    OtherTransferCount: u64,
};

const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
    IoInfo: IO_COUNTERS,
    ProcessMemoryLimit: usize,
    JobMemoryLimit: usize,
    PeakProcessMemoryUsed: usize,
    PeakJobMemoryUsed: usize,
};

extern "kernel32" fn CreateJobObjectW(
    job_attributes: ?*anyopaque,
    name: ?[*:0]const u16,
) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn SetInformationJobObject(
    job: windows.HANDLE,
    info_class: u32,
    info: *const anyopaque,
    length: u32,
) callconv(.winapi) c_int;
extern "kernel32" fn AssignProcessToJobObject(
    job: windows.HANDLE,
    process: windows.HANDLE,
) callconv(.winapi) c_int;
extern "kernel32" fn TerminateJobObject(
    job: windows.HANDLE,
    exit_code: u32,
) callconv(.winapi) c_int;

test "a job starts empty and needs no cleanup" {
    const job = none;
    job.terminate();
    job.deinit();
    try std.testing.expect(true);
}
