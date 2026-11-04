//! Waiting on descriptors, on platforms whose kernels express that differently.
//!
//! POSIX answers with `poll(2)`: one call takes descriptors and the events
//! wanted, and fills in what arrived. Zig refuses that call on Windows, where
//! `std.posix.poll` is a `@compileError` pointing at `std.Io`, because a Windows
//! descriptor is a kernel handle rather than a small integer a C library can
//! poll.
//!
//! `pollDescriptors` is the equivalent. On POSIX it calls `poll` directly. On
//! Windows it waits on the handles with `WaitForSingleObject`, which reports the
//! same two facts fx needs: whether input arrived, and whether the other end
//! closed. A console reports a keystroke through its input event count instead,
//! which is the only way to see one without consuming it.
//!
//! Nothing here allocates. Every buffer lives in the caller's stack frame, and
//! the handle probe closes what it opens before returning.

const std = @import("std");
const builtin = @import("builtin");

pub const is_windows = builtin.target.os.tag == .windows;

/// How long to wait.
pub const Timeout = union(enum) {
    /// Answer with the current state and return.
    now,
    /// Wait at most this many milliseconds.
    milliseconds: u32,
    /// Wait until something arrives.
    forever,

    fn toMilliseconds(self: Timeout) u32 {
        return switch (self) {
            .now => 0,
            .milliseconds => |value| value,
            .forever => windows_infinite,
        };
    }

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
        for (watches, 0..) |watch, i| {
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

/// Windows branch: `WaitForSingleObject` on the handle reports both input and
/// closure, and a console reports a queued keystroke through its event count.
fn windowsPoll(watches: []Watch, timeout: Timeout) error{Unsupported}!usize {
    var reported: usize = 0;
    for (watches) |*watch| {
        watch.events = .{};
        if (!watch.isActive()) continue;
        if (windowsHasConsoleInput(watch.fd)) {
            watch.events = .{ .readable = true };
            reported += 1;
            continue;
        }
        switch (windows_wait.WaitForSingleObject(watch.fd, timeout.toMilliseconds())) {
            windows_wait.object_0 => {
                watch.events = .{ .readable = true };
                reported += 1;
            },
            windows_wait.timeout => {},
            windows_wait.wait_failed => return error.Unsupported,
            else => return error.Unsupported,
        }
    }
    return reported;
}

/// Whether a console has events queued. This reports a keystroke and a resize
/// alike, which the screen needs to redraw for. A handle that is not a console
/// answers through the wait instead.
fn windowsHasConsoleInput(fd: std.posix.fd_t) bool {
    var event_count: u32 = 0;
    if (windows_console.GetNumberOfConsoleInputEvents(fd, &event_count) == 0) return false;
    return event_count > 0;
}

const windows_infinite: u32 = 0xFFFFFFFF;

const windows_wait = if (!is_windows) struct {} else struct {
    const object_0: u32 = 0x00000000;
    const timeout: u32 = 0x00000102;
    const wait_failed: u32 = 0xFFFFFFFF;

    extern "kernel32" fn WaitForSingleObject(handle: std.posix.fd_t, milliseconds: u32) callconv(.winapi) u32;
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
