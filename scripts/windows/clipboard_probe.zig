//! Reads the Windows clipboard bitmap and writes it as a PNG.
//!
//! Run with `zig build probe-clipboard` after copying a screenshot, then open
//! the PNG it reports. This is the measurement that says whether the paste path
//! can see a screenshot at all, separate from any terminal or UI behavior.

const std = @import("std");
const windows_clipboard = @import("windows_clipboard");
const png_downscale = @import("png_downscale");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    if (try windows_clipboard.readClipboardPng(alloc)) |png| {
        defer alloc.free(png);
        std.debug.print("clipboard: PNG format present, {d} bytes\n", .{png.len});
        const out = try std.Io.Dir.cwd().createFile(io, "clipboard-probe.png", .{});
        defer out.close(io);
        try out.writeStreamingAll(io, png);
        std.debug.print("wrote clipboard-probe.png\n", .{});
        return;
    }

    var bitmap = windows_clipboard.readClipboardBitmap(alloc) catch |err| {
        std.debug.print("clipboard: {t}\n", .{err});
        return;
    };
    defer bitmap.deinit(alloc);
    std.debug.print("clipboard: DIB {d}x{d}\n", .{ bitmap.width, bitmap.height });

    const png = try png_downscale.encodeRgba(alloc, bitmap.width, bitmap.height, bitmap.pixels);
    defer alloc.free(png);
    std.debug.print("encoded PNG: {d} bytes\n", .{png.len});

    const out = try std.Io.Dir.cwd().createFile(io, "clipboard-probe.png", .{});
    defer out.close(io);
    try out.writeStreamingAll(io, png);
    std.debug.print("wrote clipboard-probe.png\n", .{});
}
