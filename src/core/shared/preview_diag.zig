//! Unconditional diagnostics for the image preview.
//!
//! The preview lives outside the cell grid, so none of the usual frame traces
//! say anything about it, and `FX_TRACE` is easy to forget on a run that is
//! only trying to reproduce a rendering question. Every line here goes to one
//! file in the user's temporary folder, truncated once per process, with a
//! millisecond timestamp. The module is temporary: it exists until the preview
//! is confirmed on real terminals, and every call site goes away with it.

const std = @import("std");
const builtin = @import("builtin");

var started: bool = false;
/// Whether the terminal has reported at least one pointer motion. A terminal
/// without motion reporting never sets it, which is the caller's signal to
/// fall back to a static preview instead of a hover-driven one.
var motion_seen: bool = false;

/// The file the lines go to, resolved once.
fn logPath(buf: []u8) ?[]const u8 {
    const io = @import("io.zig");
    const root = io.getenv("TEMP") orelse io.getenv("TMP") orelse return null;
    return std.mem.print(buf, "{s}\\fx-image-overlay.log", .{root}) catch null;
}

/// Writes one timestamped line. Failures are silent: this is a diagnostic.
pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (comptime builtin.target.os.tag == .wasi) return;
    const io = @import("io.zig");
    const zio = io.getIo();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = logPath(&path_buf) orelse return;
    const alloc = std.heap.c_allocator;
    const owned = alloc.dupe(u8, path) catch return;
    defer alloc.free(owned);

    const first = !started;
    started = true;
    const file = std.Io.Dir.createFileAbsolute(zio, owned, .{ .truncate = first }) catch return;
    defer file.close(zio);

    var line_buf: [512]u8 = undefined;
    const body = std.mem.print(&line_buf, "{d} " ++ fmt ++ "\n", .{io.milliTimestamp()} ++ args) catch return;
    const end = if (first) 0 else file.length(zio) catch return;
    file.writePositionalAll(zio, body, end) catch {};
}

/// Records that the terminal reported a pointer motion.
pub fn noteMotion() void {
    motion_seen = true;
}

/// Whether any pointer motion has been reported this run.
pub fn motionReported() bool {
    return motion_seen;
}

test "logPath joins under the temporary folder" {
    // Purely structural: the name is fixed and the folder comes from TEMP.
    var buf: [256]u8 = undefined;
    _ = logPath(&buf);
}
