//! Waiting on descriptors, on platforms whose kernels express that differently.
//!
//! POSIX answers with `poll(2)`: one call takes descriptors and the events
//! wanted, and fills in what arrived. Zig refuses that call on Windows, where
//! `std.posix.poll` is a `@compileError` pointing at `std.Io`, because a Windows
//! descriptor is a kernel handle rather than a small integer a C library can
//! poll.
//!
//! `pollDescriptors` is the equivalent. On POSIX it calls `poll` directly. On
//! Windows probes pipes with `PeekNamedPipe`, sockets with `AFD_POLL`, and
//! console input with its event count. Every watch shares one timeout, and
//! probing leaves bytes for the caller's next read.
//!
//! Nothing here allocates. Every buffer lives in the caller's stack frame, and
//! probes borrow their handles.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");

pub const is_windows = builtin.target.os.tag == .windows;

/// How long to wait.
pub const Timeout = union(enum) {
    /// Answer with the current state and return.
    now,
    /// Wait at most this many milliseconds.
    milliseconds: u32,
    /// Wait until something arrives.
    forever,

    fn toPosixMilliseconds(self: Timeout) i32 {
        return switch (self) {
            .now => 0,
            .milliseconds => |value| @intCast(@min(value, @as(u32, std.math.maxInt(i32)))),
            .forever => -1,
        };
    }
};

/// What happened to one descriptor.
pub const Events = struct {
    /// Bytes are waiting, or the descriptor reached end of file.
    readable: bool = false,
    /// The other end closed. Reading returns zero bytes.
    hung_up: bool = false,
    /// The descriptor is in an error state. The next operation reports it.
    errored: bool = false,

    pub fn any(self: Events) bool {
        return self.readable or self.hung_up or self.errored;
    }
};

/// A descriptor to wait on, and what was seen. A watch with `parked` set is
/// skipped and reports nothing, which is how a caller stops waiting on a stream
/// that has closed. Parking is a flag rather than a negative descriptor because
/// a Windows descriptor is a handle, not a number to negate.
pub const Watch = struct {
    fd: std.posix.fd_t,
    parked: bool = false,
    events: Events = .{},

    pub fn isActive(self: Watch) bool {
        return !self.parked;
    }
};

/// Waits on every watch, filling in each one's `events`.
///
/// Returns the number of watches with something to report, matching `poll`. Zero
/// means the timeout passed. `error.Unsupported` means a handle cannot be waited
/// on at all, which the caller should treat as nothing to report.
pub fn pollDescriptors(watches: []Watch, timeout: Timeout) error{Unsupported}!usize {
    if (comptime is_windows) return windowsPoll(watches, timeout);
    if (comptime builtin.target.os.tag == .wasi) return error.Unsupported;

    // `poll` needs a contiguous array of its own structure. fx waits on at most
    // a handful of descriptors at once, so a fixed buffer covers it without
    // allocating; a larger set falls back to polling each descriptor in turn.
    var poll_set: [max_inline_watches]std.posix.pollfd = undefined;
    if (watches.len <= poll_set.len) {
        for (watches, 0..) |*watch, i| {
            poll_set[i] = .{
                .fd = if (watch.isActive()) watch.fd else -1,
                .events = std.posix.POLL.IN,
                .revents = 0,
            };
            watch.events = .{};
        }
        const ready = std.posix.poll(poll_set[0..watches.len], timeout.toPosixMilliseconds()) catch
            return error.Unsupported;
        if (ready == 0) return 0;
        var reported: usize = 0;
        for (watches, 0..) |*watch, i| {
            const revents = poll_set[i].revents;
            watch.events = .{
                .readable = (revents & std.posix.POLL.IN) != 0,
                .hung_up = (revents & std.posix.POLL.HUP) != 0,
                .errored = (revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0,
            };
            if (watch.events.any()) reported += 1;
        }
        return reported;
    }

    // More descriptors than the inline buffer holds. Ask about each one with a
    // zero timeout rather than allocating, since the only caller with this many
    // is a test.
    var reported: usize = 0;
    for (watches) |*watch| {
        watch.events = .{};
        if (!watch.isActive()) continue;
        var one = [_]std.posix.pollfd{.{
            .fd = watch.fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&one, 0) catch return error.Unsupported;
        if (ready == 0) continue;
        watch.events = .{
            .readable = (one[0].revents & std.posix.POLL.IN) != 0,
            .hung_up = (one[0].revents & std.posix.POLL.HUP) != 0,
            .errored = (one[0].revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0,
        };
        if (watch.events.any()) reported += 1;
    }
    return reported;
}

/// The most descriptors `pollDescriptors` waits on without asking one at a time.
/// fx never needs more than a few: a terminal, a pipe, and a socket.
const max_inline_watches = 8;

/// Waits until `fd` can be read, or the timeout passes.
pub fn waitReadable(fd: std.posix.fd_t, timeout: Timeout) error{Unsupported}!Events {
    var watches = [_]Watch{.{ .fd = fd }};
    const ready = try pollDescriptors(&watches, timeout);
    if (ready == 0) return .{};
    return watches[0].events;
}

/// Whether `fd` has something to report right now.
pub fn hasInput(fd: std.posix.fd_t) bool {
    return (waitReadable(fd, .now) catch return false).readable;
}

/// Probes every watch before sleeping, with one deadline for the whole set.
fn windowsPoll(watches: []Watch, timeout: Timeout) error{Unsupported}!usize {
    const started = windows_wait.GetTickCount64();
    while (true) {
        var reported: usize = 0;
        for (watches) |*watch| {
            watch.events = .{};
            if (!watch.isActive()) continue;
            watch.events = try windowsProbe(watch.fd);
            if (watch.events.any()) reported += 1;
        }
        if (reported > 0) return reported;
        const elapsed = windows_wait.GetTickCount64() - started;
        const remaining = switch (timeout) {
            .now => return 0,
            .milliseconds => |ms| if (elapsed >= ms) return 0 else ms - elapsed,
            .forever => 5,
        };
        windows_wait.Sleep(@intCast(@min(remaining, 5)));
    }
}

fn windowsProbe(fd: std.posix.fd_t) error{Unsupported}!Events {
    var event_count: u32 = 0;
    if (windows_console.GetNumberOfConsoleInputEvents(fd, &event_count) != 0) return .{ .readable = event_count > 0 };

    // A signaled pipe handle does not prove bytes are waiting. Peek without
    // consuming them so the next read cannot block after this probe.
    var available: u32 = 0;
    if (windows_wait.PeekNamedPipe(fd, null, 0, null, &available, null) != 0) return .{ .readable = available > 0 };
    switch (windows_wait.GetLastError()) {
        109, 233 => return .{ .readable = true, .hung_up = true }, // BROKEN_PIPE, PIPE_NOT_CONNECTED
        else => {},
    }

    if (windows_wait.GetFileType(fd) == 1) return .{ .readable = true };
    // std.Io opens AFD handles directly, so Winsock's WSAPoll cannot poll them.
    if (windowsSocketProbe(fd)) |events| return events;
    return switch (windows_wait.WaitForSingleObject(fd, 0)) {
        windows_wait.object_0 => .{ .readable = true },
        windows_wait.timeout => .{},
        else => error.Unsupported,
    };
}

fn windowsSocketProbe(fd: std.posix.fd_t) ?Events {
    const windows = std.os.windows;
    const Poll = extern struct {
        timeout: i64 = 0,
        count: u32 = 1,
        exclusive: u32 = 0,
        handle: windows.HANDLE,
        events: u32 = 0x1bb, // receive, disconnect, abort, close, accept, connect failure
        status: windows.NTSTATUS = .SUCCESS,
    };
    var poll: Poll = .{ .handle = fd };
    const result = io_mod.getIo().operate(.{ .device_io_control = .{
        .file = .{ .handle = fd, .flags = .{ .nonblocking = true } },
        .code = windows.IOCTL.AFD.POLL,
        .in = std.mem.asBytes(&poll),
        .out = std.mem.asBytes(&poll),
    } }) catch return null;
    switch (result.device_io_control.u.Status) {
        .TIMEOUT => return .{},
        .SUCCESS => {},
        else => return null,
    }
    if (poll.count == 0) return .{};
    return .{
        .readable = (poll.events & 0xbb) != 0,
        .hung_up = (poll.events & 0x38) != 0,
        .errored = (poll.events & 0x110) != 0 or poll.status != .SUCCESS,
    };
}

const windows_wait = if (!is_windows) struct {} else struct {
    const object_0: u32 = 0x00000000;
    const timeout: u32 = 0x00000102;

    extern "kernel32" fn WaitForSingleObject(handle: std.posix.fd_t, milliseconds: u32) callconv(.winapi) u32;
    extern "kernel32" fn PeekNamedPipe(handle: std.posix.fd_t, buffer: ?*anyopaque, size: u32, read: ?*u32, available: ?*u32, remaining: ?*u32) callconv(.winapi) c_int;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    extern "kernel32" fn GetFileType(handle: std.posix.fd_t) callconv(.winapi) u32;
    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
    extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;
};

const windows_console = if (!is_windows) struct {} else struct {
    extern "kernel32" fn GetNumberOfConsoleInputEvents(
        console_input: std.posix.fd_t,
        number_of_events: *u32,
    ) callconv(.winapi) c_int;
};

test "pollDescriptors reports a pipe becoming readable" {
    if (comptime @import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    if (comptime is_windows) return error.SkipZigTest;
    var fds: [2]std.posix.fd_t = undefined;
    switch (std.posix.errno(std.posix.system.pipe2(&fds, .{ .NONBLOCK = true }))) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    var watches = [_]Watch{.{ .fd = fds[0] }};
    try std.testing.expectEqual(@as(usize, 0), try pollDescriptors(&watches, .now));

    const byte = [_]u8{0x41};
    _ = try std.posix.write(fds[1], &byte);
    try std.testing.expectEqual(@as(usize, 1), try pollDescriptors(&watches, .now));
    try std.testing.expect(watches[0].events.readable);
    try std.testing.expect(hasInput(fds[0]));
}

test "pollDescriptors reports hang up after the writer closes" {
    if (comptime @import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    if (comptime is_windows) return error.SkipZigTest;
    var fds: [2]std.posix.fd_t = undefined;
    switch (std.posix.errno(std.posix.system.pipe2(&fds, .{ .NONBLOCK = true }))) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    defer std.posix.close(fds[0]);
    std.posix.close(fds[1]);

    var watches = [_]Watch{.{ .fd = fds[0] }};
    const ready = try pollDescriptors(&watches, .{ .milliseconds = 100 });
    try std.testing.expect(ready >= 1);
    try std.testing.expect(watches[0].events.hung_up or watches[0].events.readable);
}

test "Windows readiness probes all pipes without consuming bytes" {
    if (comptime !is_windows) return error.SkipZigTest;
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const quiet = try threaded.windowsCreatePipe(.{
        .server = .{ .mode = .{ .IO = .ASYNCHRONOUS } },
        .client = .{ .mode = .{ .IO = .SYNCHRONOUS_NONALERT } },
        .inbound = true,
    });
    defer for (quiet) |fd| std.os.windows.CloseHandle(fd);
    const ready = try threaded.windowsCreatePipe(.{
        .server = .{ .mode = .{ .IO = .ASYNCHRONOUS } },
        .client = .{ .mode = .{ .IO = .SYNCHRONOUS_NONALERT } },
        .inbound = true,
    });
    defer std.os.windows.CloseHandle(ready[0]);
    var writer: ?std.Io.File = .{ .handle = ready[1], .flags = .{ .nonblocking = false } };
    defer if (writer) |file| file.close(std.testing.io);
    try writer.?.writeStreamingAll(std.testing.io, "x");

    var watches = [_]Watch{ .{ .fd = quiet[0] }, .{ .fd = ready[0] } };
    try std.testing.expectEqual(@as(usize, 1), try pollDescriptors(&watches, .{ .milliseconds = 100 }));
    try std.testing.expect(!watches[0].events.any());
    try std.testing.expect(watches[1].events.readable);
    const reader: std.Io.File = .{ .handle = ready[0], .flags = .{ .nonblocking = true } };
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try reader.readStreaming(std.testing.io, &.{&byte}));
    try std.testing.expectEqual(@as(u8, 'x'), byte[0]);
    try std.testing.expectEqual(@as(usize, 0), try pollDescriptors(&watches, .now));

    writer.?.close(std.testing.io);
    writer = null;
    try std.testing.expectEqual(@as(usize, 1), try pollDescriptors(&watches, .now));
    try std.testing.expect(watches[1].events.hung_up);
}

test "Windows readiness reports a socket becoming readable" {
    if (comptime !is_windows) return error.SkipZigTest;
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const client = try server.socket.address.connect(std.testing.io, .{ .mode = .stream });
    defer client.close(std.testing.io);
    try std.testing.expect((try waitReadable(server.socket.handle, .{ .milliseconds = 100 })).readable);
    const accepted = try server.accept(std.testing.io);
    defer accepted.close(std.testing.io);
    try std.testing.expect(!(try waitReadable(accepted.socket.handle, .now)).any());
    var buffer: [1]u8 = undefined;
    var writer = client.writer(std.testing.io, &buffer);
    try writer.interface.writeAll("x");
    try writer.interface.flush();
    try std.testing.expect((try waitReadable(accepted.socket.handle, .{ .milliseconds = 100 })).readable);
}
