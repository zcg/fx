//! Reports which inline image protocol this terminal speaks, and prints a small
//! test image through it.
//!
//! Run with `zig build probe-image-protocol` from the repository root. The
//! report goes to stderr so the escape sequence on stdout can be piped into a
//! file and inspected.

const std = @import("std");
const builtin = @import("builtin");
const terminal_image = @import("terminal_image");
const terminal_image_render = @import("terminal_image_render");

pub fn main(init: std.process.Init) !void {
    const protocol = terminal_image.current();
    std.debug.print("protocol={s} draws={}\n", .{ @tagName(protocol), protocol.drawsImages() });

    // A 2x2 PNG: the smallest thing a terminal can actually draw.
    const png = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
        0x08, 0x02, 0x00, 0x00, 0x00, 0xfd, 0xd4, 0x9a,
        0x73, 0x00, 0x00, 0x00, 0x16, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9c, 0x62, 0xf8, 0xcf, 0xc0, 0xf0,
        0x9f, 0x81, 0x81, 0xe1, 0x3f, 0x03, 0x03, 0x00,
        0x0e, 0xfb, 0x02, 0xfe, 0xa8, 0x1a, 0x9b, 0x8c,
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44,
        0xae, 0x42, 0x60, 0x82,
    };

    var out: std.Io.Writer.Allocating = .init(init.gpa);
    defer out.deinit();
    switch (protocol) {
        .kitty => try terminal_image_render.writePng(&out.writer, &png, .{
            .columns = 8,
            .rows = 2,
            .image_id = 1,
        }),
        .iterm2, .sixel, .none => std.debug.print("no encoder for {s} yet\n", .{@tagName(protocol)}),
    }
    if (out.written().len > 0) {
        std.debug.print("sequence bytes={d}\n", .{out.written().len});
        // Straight to the terminal, so a person running this sees the picture.
        try std.Io.File.stdout().writeStreamingAll(init.io, out.written());
    }
    _ = builtin;
}
