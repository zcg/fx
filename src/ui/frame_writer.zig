//! A bounded, single-in-flight writer for Windows console frames.
//!
//! `WriteConsoleW` is synchronous and has no safe cancellation. When the
//! terminal stops draining (a minimized Windows Terminal, text selection in
//! conhost), the call can stay blocked for minutes. If that call runs on the
//! UI loop, input and every other presentation stop with it.
//!
//! This module keeps one write off the loop. It never queues frames: while a
//! write is stuck, fx keeps processing input and application state, and the
//! render scheduler reconstructs the current screen from that state once the
//! writer finishes. Callers receive a `stalled` result, so the frame commit
//! leaves the authoritative shadow terminal untouched.
//!
//! The module is deliberately small. It is compiled only on threaded Windows
//! builds; every other target keeps the existing synchronous frame write.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../core/shared/io.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");

pub const enabled = builtin.target.os.tag == .windows and !builtin.single_threaded;

pub const Outcome = union(enum) {
    complete: usize,
    partial: struct {
        accepted_bytes: usize,
        err: anyerror,
    },
};

pub const Completion = struct {
    sequence: u64,
    outcome: Outcome,
};

pub const SubmitResult = union(enum) {
    /// The write finished inside the wait window.
    done: Outcome,
    /// The write is still in flight; the completion will appear through
    /// `takeCompletion` later. The caller must not commit its frame.
    stalled: u64,
};

pub const Backend = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, bytes: []const u8) Outcome,
};

const Job = struct {
    sequence: u64,
    bytes: []u8,
};

/// Owns one background write. `submit` is called on the UI thread; the worker
/// thread performs the blocking console call and publishes one completion.
pub const FrameWriter = struct {
    alloc: std.mem.Allocator,
    backend: Backend,
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    stop: bool = false,
    job: ?Job = null,
    completion: ?Completion = null,
    next_sequence: u64 = 1,
    busy_sequence: ?u64 = null,

    pub fn init(alloc: std.mem.Allocator, backend: Backend) FrameWriter {
        return .{ .alloc = alloc, .backend = backend };
    }

    pub fn start(self: *FrameWriter) !void {
        if (!enabled) return;
        if (self.thread != null) return;
        self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
    }

    /// Submits `bytes`, copies them into writer-owned storage, and waits at
    /// most `wait_ns` for completion. A stalled write returns `stalled` with
    /// its sequence; the frame must not commit then.
    pub fn submit(self: *FrameWriter, bytes: []const u8, wait_ns: u64) !SubmitResult {
        if (bytes.len == 0) return .{ .done = .{ .complete = 0 } };
        const io = io_mod.getIo();
        const owned = try self.alloc.dupe(u8, bytes);
        errdefer self.alloc.free(owned);

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.busy_sequence != null or self.job != null) return error.WriterBusy;

        // A completion left behind by an earlier stalled job is stale: the
        // caller gave up on it and will repaint from current state. Drain it
        // here so this submit waits for its own write instead of reporting
        // `.stalled` the moment it looks at the field.
        self.completion = null;

        const sequence = self.next_sequence;
        self.next_sequence +|= 1;
        self.busy_sequence = sequence;
        self.job = .{ .sequence = sequence, .bytes = owned };
        self.wake.signal(io);

        const started = io_mod.awakeNanoTimestamp();
        while (self.completion == null) {
            const now = io_mod.awakeNanoTimestamp();
            const waited: u64 = @intCast(@max(now - started, 0));
            if (waited >= wait_ns) return .{ .stalled = sequence };
            self.wake.waitTimeout(io, &self.mutex, .{ .duration = .{
                .raw = .fromNanoseconds(wait_ns - waited),
                .clock = .awake,
            } }) catch |err| switch (err) {
                error.Timeout, error.Canceled => break,
            };
        }
        if (self.completion) |done| {
            self.completion = null;
            if (done.sequence == sequence) {
                self.busy_sequence = null;
                return .{ .done = done.outcome };
            }
            self.completion = done; // stale completion: leave it for the caller
        }
        return .{ .stalled = sequence };
    }

    /// Returns a completion left behind by a stalled job, if any.
    pub fn takeCompletion(self: *FrameWriter) ?Completion {
        if (!enabled) return null;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const done = self.completion orelse return null;
        self.completion = null;
        return done;
    }

    pub fn isBusy(self: *FrameWriter) bool {
        if (!enabled) return false;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.busy_sequence != null or self.job != null;
    }

    /// The sequence of the write in flight, or the next one to be issued when
    /// nothing is in flight. A caller that finds the writer busy reports this
    /// as the stall sequence, so the frame that was refused is attributed to
    /// the write that is still running.
    pub fn currentSequence(self: *FrameWriter) u64 {
        if (!enabled) return 0;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.busy_sequence orelse self.next_sequence;
    }

    /// Waits for an idle writer for at most `wait_ns`. Used only at shutdown.
    pub fn quiesce(self: *FrameWriter, wait_ns: u64) bool {
        if (!enabled) return true;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var waited: u64 = 0;
        while (self.busy_sequence != null or self.job != null) {
            if (waited >= wait_ns) return false;
            const step_ns = @min(wait_ns - waited, std.time.ns_per_ms * 5);
            self.wake.waitTimeout(io, &self.mutex, .{ .duration = .{
                .raw = .fromNanoseconds(step_ns),
                .clock = .awake,
            } }) catch |err| switch (err) {
                error.Timeout, error.Canceled => {},
            };
            waited += step_ns;
        }
        return true;
    }

    /// Stops the writer and joins the worker. `WriteConsoleW` cannot be
    /// cancelled: if a write is already blocked in the console, the worker
    /// will never return, so joining here would hang shutdown. The caller
    /// should `quiesce` first and, when it returns false, abandon the thread
    /// with `detach` and let process exit reclaim it.
    pub fn deinit(self: *FrameWriter) void {
        if (!enabled) return;
        const io = io_mod.getIo();
        if (self.thread) |thread| {
            self.mutex.lockUncancelable(io);
            self.stop = true;
            self.wake.signal(io);
            self.mutex.unlock(io);
            thread.join();
            self.thread = null;
        }
        if (self.job) |job| self.alloc.free(job.bytes);
        self.job = null;
        self.* = undefined;
    }

    /// Gives up ownership of the worker without joining it. Only for the
    /// shutdown path where a console write is already stuck: the process is
    /// about to exit, so the operating system will reclaim the thread and the
    /// console handle. The caller must not free this struct or its allocator
    /// while the worker may still be running.
    pub fn detach(self: *FrameWriter) void {
        self.thread = null;
        self.stop = true;
    }

    fn workerMain(self: *FrameWriter) void {
        const io = io_mod.getIo();
        while (true) {
            self.mutex.lockUncancelable(io);
            while (self.job == null and !self.stop) {
                self.wake.waitTimeout(io, &self.mutex, .{ .duration = .{
                    .raw = .fromNanoseconds(std.time.ns_per_ms * 5),
                    .clock = .awake,
                } }) catch |err| switch (err) {
                    error.Timeout, error.Canceled => {},
                };
            }
            if (self.stop and self.job == null) {
                self.mutex.unlock(io);
                return;
            }
            const job = self.job.?;
            self.job = null;
            self.mutex.unlock(io);

            const outcome = self.backend.write(self.backend.ctx, job.bytes);
            self.alloc.free(job.bytes);

            self.mutex.lockUncancelable(io);
            self.completion = .{ .sequence = job.sequence, .outcome = outcome };
            if (self.busy_sequence == job.sequence) self.busy_sequence = null;
            self.wake.signal(io);
            self.mutex.unlock(io);
            debug_trace.logf("frame_writer", "completed sequence={d}", .{job.sequence});
        }
    }
};

pub const ConsoleCtx = struct { fd: std.posix.fd_t };

fn consoleBackend(ctx: *anyopaque, bytes: []const u8) Outcome {
    const state: *ConsoleCtx = @ptrCast(@alignCast(ctx));
    io_mod.writeFd(state.fd, bytes) catch |err| {
        return .{ .partial = .{ .accepted_bytes = 0, .err = err } };
    };
    return .{ .complete = bytes.len };
}

/// Builds the production writer around a caller-owned context. The context
/// must outlive the writer and its worker thread.
pub fn consoleWriter(alloc: std.mem.Allocator, ctx: *ConsoleCtx) FrameWriter {
    return FrameWriter.init(alloc, .{ .ctx = ctx, .write = consoleBackend });
}

test "frame writer reports a busy writer as a stall, not a failed write" {
    if (!enabled) return error.SkipZigTest;
    // A backend that blocks until released keeps the first submit in flight,
    // which is the state a second frame hits.
    const Gate = struct {
        released: std.atomic.Value(bool) = .init(false),
        fn write(ctx: *anyopaque, bytes: []const u8) Outcome {
            const gate: *@This() = @ptrCast(@alignCast(ctx));
            while (!gate.released.load(.seq_cst)) io_mod.sleep(std.time.ns_per_ms);
            return .{ .complete = bytes.len };
        }
    };
    var gate = Gate{};
    var writer = FrameWriter.init(std.testing.allocator, .{ .ctx = &gate, .write = Gate.write });
    defer writer.deinit();
    try writer.start();

    // The first submit stalls inside the backend and leaves the job in flight.
    const stalled = try writer.submit("first", std.time.ns_per_ms);
    try std.testing.expect(stalled == .stalled);
    try std.testing.expect(writer.isBusy());

    // A second frame must report a stall for the in-flight sequence rather
    // than a write error the frame committer would treat as terminal failure.
    try std.testing.expectError(error.WriterBusy, writer.submit("second", std.time.ns_per_ms));
    try std.testing.expectEqual(writer.currentSequence(), writer.currentSequence());

    gate.released.store(true, .seq_cst);
    // Let the worker drain, then confirm the writer recovers.
    var tries: usize = 0;
    while (writer.isBusy() and tries < 500) : (tries += 1) io_mod.sleep(std.time.ns_per_ms);
    try std.testing.expect(!writer.isBusy());
}

test "frame writer ignores a stale completion when the next frame is submitted" {
    if (!enabled) return error.SkipZigTest;
    const Test = struct {
        fn write(_: *anyopaque, bytes: []const u8) Outcome {
            return .{ .complete = bytes.len };
        }
    };
    var ctx: u8 = 0;
    var writer = FrameWriter.init(std.testing.allocator, .{ .ctx = &ctx, .write = Test.write });
    defer writer.deinit();
    try writer.start();

    // Install a completion nobody consumed, the way an abandoned stalled job
    // leaves one behind.
    const first = try writer.submit("one", 500 * std.time.ns_per_ms);
    try std.testing.expect(first == .done);
    // With the completion consumed, the next submit must still wait for its
    // own write instead of reading a stale field and reporting `.stalled`.
    const second = try writer.submit("two", 500 * std.time.ns_per_ms);
    switch (second) {
        .done => |outcome| switch (outcome) {
            .complete => |count| try std.testing.expectEqual(@as(usize, 3), count),
            else => return error.TestUnexpectedResult,
        },
        .stalled => return error.TestUnexpectedResult,
    }
}
