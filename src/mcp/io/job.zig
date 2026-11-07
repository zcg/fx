//! A Windows job object that owns a process tree, so a stdio MCP server's
//! descendants cannot outlive fx.
//!
//! On POSIX a process group is the handle on a descendant set: fx signals the
//! group and the kernel delivers it to every member. Windows has no process
//! group with that meaning; `TerminateProcess` reaches exactly one process, so
//! a server started through `npx`, `uvx`, or a `.cmd` wrapper leaves its own
//! children behind when fx ends. A job object is the equivalent handle: every
//! process assigned to it is in the same tree, and terminating or closing the
//! job ends the whole tree.
//!
//! The job is created with `KILL_ON_JOB_CLOSE`, so fx's own exit, clean or not,
//! takes its children with it: the kernel closes every handle the process held,
//! and the job then kills what is still running inside it.
//!
//! This module sits inside the MCP engine because that engine imports only
//! `std` and its own files. Off Windows every call is a no-op, so callers do not
//! branch on the platform.

const std = @import("std");
const builtin = @import("builtin");

pub const is_windows = builtin.target.os.tag == .windows;

pub const Job = if (!is_windows) struct {
    pub fn deinit(self: Job) void {
        _ = self;
    }

    pub fn assign(self: Job, process: std.process.Child.Id) bool {
        _ = self;
        _ = process;
        return false;
    }

    pub fn terminate(self: Job) void {
        _ = self;
    }
} else struct {
    handle: std.os.windows.HANDLE,

    /// Creates a job that kills every process still inside it when the job is
    /// terminated or closed. Returns null when the system refuses, which the
    /// caller logs rather than treating as a started server.
    pub fn create() ?Job {
        const handle = CreateJobObjectW(null, null) orelse return null;
        var info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std.mem.zeroes(JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (SetInformationJobObject(
            handle,
            job_object_extended_limit_information,
            @ptrCast(&info),
            @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
        ) == 0) {
            _ = CloseHandle(handle);
            return null;
        }
        return .{ .handle = handle };
    }

    /// Puts a started child into the job. A child that could not be assigned
    /// is still fx's direct child and is stopped by its own handle, so a
    /// failure here is reported and not fatal.
    pub fn assign(self: Job, process: std.process.Child.Id) bool {
        if (AssignProcessToJobObject(self.handle, process) == 0) {
            std.log.debug("mcp job assign failed err={d}", .{std.os.windows.GetLastError()});
            return false;
        }
        return true;
    }

    /// Ends every process still inside the job, for a server stopped while fx
    /// keeps running.
    pub fn terminate(self: Job) void {
        _ = TerminateJobObject(self.handle, 1);
    }

    /// Closes the job. Because it was created with `KILL_ON_JOB_CLOSE`, this
    /// also ends anything still inside it.
    pub fn deinit(self: Job) void {
        _ = CloseHandle(self.handle);
    }
};

/// Creates a job for one server. Off Windows there is nothing to create.
pub fn create() ?Job {
    if (comptime !is_windows) return .{};
    return Job.create();
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
) callconv(.winapi) ?std.os.windows.HANDLE;
extern "kernel32" fn SetInformationJobObject(
    job: std.os.windows.HANDLE,
    info_class: u32,
    info: *const anyopaque,
    length: u32,
) callconv(.winapi) c_int;
extern "kernel32" fn AssignProcessToJobObject(
    job: std.os.windows.HANDLE,
    process: std.os.windows.HANDLE,
) callconv(.winapi) c_int;
extern "kernel32" fn TerminateJobObject(
    job: std.os.windows.HANDLE,
    exit_code: u32,
) callconv(.winapi) c_int;
extern "kernel32" fn CloseHandle(handle: std.os.windows.HANDLE) callconv(.winapi) c_int;

test "a job can be created and closed on every platform" {
    const job = create() orelse return error.SkipZigTest;
    defer job.deinit();
    // An invalid handle must not be assigned; the call reports it instead of
    // taking the process down.
    try std.testing.expect(!job.assign(@ptrFromInt(1)));
}
