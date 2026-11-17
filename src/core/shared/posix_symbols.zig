//! The few POSIX calls fx's tests reach that no Windows C runtime provides.
//!
//! A test fixture that asks for a FIFO, a pipe, or a hard link is describing a
//! POSIX filesystem, so on Windows it gets a stub that reports failure and the
//! test skips. Routing them through one place keeps the `extern` declarations
//! out of the modules under test and lets them stay out of a Windows build.
//!
//! `std.c` already declares most of these on every target. The ones below are
//! the calls it either does not declare on Windows or declares with a
//! different name there.

const std = @import("std");
const builtin = @import("builtin");

/// Whether the real POSIX functions are the ones being called.
const posix = builtin.target.os.tag != .windows and builtin.target.os.tag != .wasi;

/// `mkfifo(3)`: creates a named pipe. Windows has no equivalent, so the stub
/// fails the way a filesystem that refuses one does.
pub const mkfifo = if (posix) struct {
    extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
}.mkfifo else struct {
    fn stub(path: [*:0]const u8, mode: std.c.mode_t) c_int {
        _ = .{ path, mode };
        return -1;
    }
}.stub;

/// `chmod(2)`: narrows a file's mode. A Windows file carries an inherited ACL
/// instead, so the stub reports success the way an already-private file does.
pub const chmod = if (posix) struct {
    extern "c" fn chmod(path: [*:0]const u8, mode: std.c.mode_t) c_int;
}.chmod else struct {
    fn stub(path: [*:0]const u8, mode: std.c.mode_t) c_int {
        _ = .{ path, mode };
        return 0;
    }
}.stub;

test "a stub reports what the platform can do" {
    if (comptime posix) return error.SkipZigTest;
    try std.testing.expectEqual(@as(c_int, -1), mkfifo("nowhere", 0o600));
    try std.testing.expectEqual(@as(c_int, 0), chmod("nowhere", 0o700));
}
