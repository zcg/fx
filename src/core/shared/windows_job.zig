//! A Windows job object per child process, so ending the child ends what it
//! started.
//!
//! POSIX addresses a process group: one id names the child and everything it
//! forked, and a single signal reaches all of it. Windows has no such group.
//! The equivalent is a job object, which is a kernel container a process is
//! assigned to, and which ends every process inside it when it is closed or
//! terminated.
//!
//! Without one, a command that starts a server leaves that server running after
//! the command's own process ends. `npm run dev`, `pnpm dev`, and `bun dev` all
//! look like this: the runner spawns the real program and waits, so ending the
//! runner leaves the program behind. Repeated over a session that is a leak of
//! processes, ports, and memory that nothing in fx can reach again.
//!
//! The job is created with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, so closing the
//! last handle to it is enough to end the tree, and that happens on every path
//! that drops a child, including the ones that run when fx exits.
//!
//! On other platforms this module compiles to nothing: the type is empty and
//! every function is a no-op, so callers do not branch on the platform.

const std = @import("std");
const builtin = @import("builtin");

pub const supported = builtin.target.os.tag == .windows;

const windows = std.os.windows;

/// The job a child was assigned to. Empty on platforms without job objects.
pub const Job = if (supported) struct {
    handle: ?windows.HANDLE,

    /// Ends every process in the job and releases it. Safe to call after
    /// `deinit`, which leaves the handle null.
    pub fn terminate(self: Job) void {
        if (self.handle == null) return;
        _ = TerminateJobObject(self.handle.?, 1);
        _ = windows.CloseHandle(self.handle.?);
    }

    /// Releases the handle without ending the processes. Used when the command
    /// already finished on its own: its children are then its own business, and
    /// killing them would end something the user started on purpose.
    pub fn deinit(self: Job) void {
        if (self.handle == null) return;
        _ = windows.CloseHandle(self.handle.?);
    }
} else struct {
    pub fn terminate(self: Job) void {
        _ = self;
    }

    pub fn deinit(self: Job) void {
        _ = self;
    }
};

/// A job that holds nothing. Every operation on it does nothing.
pub const none: Job = if (supported) .{ .handle = null } else .{};

/// The job a process was assigned to, or a no-op value when the platform has
/// none or the assignment failed.
///
/// A failure here is not fatal: the command still runs, it just may leave its
/// children behind, which is what happened before job objects were used at all.
/// Refusing to start a command because its container could not be created would
/// turn a cleanup problem into a command that does not run.
pub fn assign(process: windows.HANDLE) Job {
    if (comptime !supported) return none;
    const handle = CreateJobObjectW(null, null) orelse return none;

    var limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std.mem.zeroes(JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (SetInformationJobObject(
        handle,
        JobObjectExtendedLimitInformation,
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

/// Whether this job holds a live handle.
pub fn isActive(job: Job) bool {
    if (comptime !supported) return false;
    return job.handle != null;
}

const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x00002000;
const JobObjectExtendedLimitInformation: u32 = 9;

/// The subset of `JOBOBJECT_EXTENDED_LIMIT_INFORMATION` the kill-on-close flag
/// lives in. The rest is left zeroed: only the flags matter here, and the
/// kernel accepts a zero for every limit a caller does not set.
const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: i64 = 0,
    PerJobUserTimeLimit: i64 = 0,
    LimitFlags: u32 = 0,
    MinimumWorkingSetSize: usize = 0,
    MaximumWorkingSetSize: usize = 0,
    ActiveProcessLimit: u32 = 0,
    Affinity: usize = 0,
    PriorityClass: u32 = 0,
    SchedulingClass: u32 = 0,
};

const IO_COUNTERS = extern struct {
    ReadOperationCount: u64 = 0,
    WriteOperationCount: u64 = 0,
    OtherOperationCount: u64 = 0,
    ReadTransferCount: u64 = 0,
    WriteTransferCount: u64 = 0,
    OtherTransferCount: u64 = 0,
};

const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION = .{},
    IoInfo: IO_COUNTERS = .{},
    ProcessMemoryLimit: usize = 0,
    JobMemoryLimit: usize = 0,
    PeakProcessMemoryUsed: usize = 0,
    PeakJobMemoryUsed: usize = 0,
};

extern "kernel32" fn CreateJobObjectW(
    attributes: ?*windows.SECURITY_ATTRIBUTES,
    name: ?[*:0]const u16,
) callconv(.winapi) ?windows.HANDLE;

extern "kernel32" fn SetInformationJobObject(
    job: windows.HANDLE,
    info_class: u32,
    info: *const anyopaque,
    info_len: u32,
) callconv(.winapi) c_int;

extern "kernel32" fn AssignProcessToJobObject(
    job: windows.HANDLE,
    process: windows.HANDLE,
) callconv(.winapi) c_int;

extern "kernel32" fn TerminateJobObject(
    job: windows.HANDLE,
    exit_code: u32,
) callconv(.winapi) c_int;

test "a job without a handle reports inactive and tolerates every operation" {
    const empty: Job = none;
    try std.testing.expect(!isActive(empty));
    empty.terminate();
    empty.deinit();
}
