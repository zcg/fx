//! Unconditional diagnostics for the image preview.
//!
//! The preview lives outside the cell grid, so none of the usual frame traces
//! say anything about it, and `FX_TRACE` is easy to forget on a run that is
//! only trying to reproduce a rendering question. Every line here goes to one
//! file in the user's temporary folder, truncated once per process, with a
//! millisecond timestamp.
//!
//! The file is held open for the life of the process rather than opened per
//! line. A frame that draws a preview asks a dozen questions about it, and the
//! preview is rebuilt on every keystroke, so opening and closing per line put a
//! pair of syscalls on the render path -- which is exactly the stutter it was
//! meant to diagnose.
//!
//! The module is temporary: it exists until the preview is confirmed on real
//! terminals, and every call site goes away with it.

const std = @import("std");
const builtin = @import("builtin");

var started: bool = false;
/// Whether the terminal has reported at least one pointer motion. A terminal
/// without motion reporting never sets it, which is the caller's signal to
/// fall back to a static preview instead of a hover-driven one.
var motion_seen: bool = false;

/// The open log, resolved on first use. Null when the temporary folder is not
/// known or the file cannot be created, which turns every later call into a
/// no-op rather than a retry.
var handle: ?Log = null;
var resolved: bool = false;

const Log = struct {
    io: std.Io,
    file: std.Io.File,
};

fn openLog() ?Log {
    const io_mod = @import("io.zig");
    const zio = io_mod.getIo();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = io_mod.getenv("TEMP") orelse io_mod.getenv("TMP") orelse return null;
    const path = std.mem.print(&path_buf, "{s}\\fx-image-overlay.log", .{root}) catch return null;
    const file = std.Io.Dir.createFileAbsolute(zio, path, .{ .truncate = true }) catch return null;
    return .{ .io = zio, .file = file };
}

/// Writes one timestamped line. Failures are silent: this is a diagnostic.
pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (comptime builtin.target.os.tag == .wasi) return;
    if (!resolved) {
        resolved = true;
        handle = openLog();
        started = handle != null;
    }
    const open = handle orelse return;
    const io_mod = @import("io.zig");

    var line_buf: [512]u8 = undefined;
    const body = std.mem.print(&line_buf, "{d} " ++ fmt ++ "\n", .{io_mod.milliTimestamp()} ++ args) catch return;
    open.file.writeStreamingAll(open.io, body) catch {};
}

/// Records that the terminal reported a pointer motion.
pub fn noteMotion() void {
    motion_seen = true;
}

/// Whether any pointer motion has been reported this run.
pub fn motionReported() bool {
    return motion_seen;
}

test "the log lives beside the temporary folder" {
    // Purely structural: the name is fixed and the folder comes from the
    // environment, so a missing folder means no log rather than a crash.
    var buf: [64]u8 = undefined;
    const joined = std.mem.print(&buf, "{s}\\fx-image-overlay.log", .{"C:\\Temp"});
    try std.testing.expectEqualStrings("C:\\Temp\\fx-image-overlay.log", joined);
}
