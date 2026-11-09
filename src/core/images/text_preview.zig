//! A truecolor character-grid thumbnail.
//!
//! Windows Terminal's Sixel parser stalls the whole tab on any DCS image, so a
//! preview there cannot be a graphics protocol at all. This one is ordinary
//! text: each cell is an upper half block whose foreground color paints the
//! top pixel and whose background color paints the bottom pixel. Two sampled
//! rows of the source become one text row, which matches a terminal cell being
//! about twice as tall as it is wide.
//!
//! The bytes are plain `CSI row;col H` positioning plus SGR colors. There is no
//! APC, no DCS, no image buffer, and nothing for the terminal to flush or
//! scroll: whatever erased it is just the next text frame, which fx already
//! forces when the preview closes.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ OutOfMemory, TooLarge, EmptyImage };

/// A preview this size is a few tens of kilobytes of text; cap it so a busy
/// photograph cannot turn a keystroke into a slow write.
pub const max_bytes: usize = 64 * 1024;

/// Builds the ANSI text that draws `pixels` (RGBA, row-major) as a `columns` x
/// `rows` character thumbnail anchored at 1-based `abs_row`, `abs_col`.
///
/// The caller owns the returned bytes and passes the placement's own rectangle,
/// because the positioning inside is absolute and a cached preview is only
/// valid for the exact cells it was built for.
pub fn encode(
    alloc: Allocator,
    pixels: []const u8,
    width: u32,
    height: u32,
    columns: u16,
    rows: u16,
    abs_row: u16,
    abs_col: u16,
    ceiling: usize,
) Error![]u8 {
    if (width == 0 or height == 0 or columns == 0 or rows == 0) return error.EmptyImage;
    if (pixels.len < @as(usize, width) * height * 4) return error.EmptyImage;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var r: usize = 0;
    while (r < rows) : (r += 1) {
        try putFmt(alloc, &out, "\x1b[{d};{d}H", .{
            @as(u32, abs_row) + @as(u32, @intCast(r)),
            @as(u32, abs_col),
        }, ceiling);
        var c: usize = 0;
        while (c < columns) : (c += 1) {
            const x: u32 = @as(u32, @intCast(c)) * width / columns;
            const top_y: u32 = @as(u32, @intCast(r * 2)) * height / (@as(u32, rows) * 2);
            const bottom_y: u32 = @as(u32, @intCast(r * 2 + 1)) * height / (@as(u32, rows) * 2);
            const top = pixel(pixels, width, x, top_y);
            const bottom = pixel(pixels, width, x, bottom_y);
            if (top[3] < 32 and bottom[3] < 32) {
                // A transparent cell leaves whatever the text layer drew.
                try put(alloc, &out, "\x1b[0m ", ceiling);
                continue;
            }
            try putFmt(
                alloc,
                &out,
                "\x1b[38;2;{d};{d};{d};48;2;{d};{d};{d}m",
                .{ top[0], top[1], top[2], bottom[0], bottom[1], bottom[2] },
                ceiling,
            );
            try put(alloc, &out, "\xe2\x96\x80", ceiling); // U+2580 UPPER HALF BLOCK
        }
    }
    try put(alloc, &out, "\x1b[0m", ceiling);
    return out.toOwnedSlice(alloc);
}

fn pixel(pixels: []const u8, width: u32, x: u32, y: u32) [4]u8 {
    const base = (@as(usize, y) * width + x) * 4;
    return .{ pixels[base], pixels[base + 1], pixels[base + 2], pixels[base + 3] };
}

fn put(alloc: Allocator, out: *std.ArrayList(u8), bytes: []const u8, ceiling: usize) Error!void {
    if (out.items.len + bytes.len > ceiling) return error.TooLarge;
    try out.appendSlice(alloc, bytes);
}

fn putFmt(alloc: Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype, ceiling: usize) Error!void {
    var buffer: [96]u8 = undefined;
    const text = std.mem.print(&buffer, fmt, args) catch return error.TooLarge;
    try put(alloc, out, text, ceiling);
}

test "a solid image becomes half-block cells with truecolor" {
    const alloc = std.testing.allocator;
    const width: u32 = 8;
    const height: u32 = 8;
    const pixels = try alloc.alloc(u8, @as(usize, width) * height * 4);
    defer alloc.free(pixels);
    for (0..@as(usize, width) * height) |index| {
        pixels[index * 4 + 0] = 255;
        pixels[index * 4 + 1] = 0;
        pixels[index * 4 + 2] = 0;
        pixels[index * 4 + 3] = 255;
    }
    const bytes = try encode(alloc, pixels, width, height, 4, 2, 7, 3, max_bytes);
    defer alloc.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "\x1b[7;3H"));
    try std.testing.expect(std.mem.find(u8, bytes, "38;2;255;0;0;48;2;255;0;0m") != null);
    try std.testing.expect(std.mem.endsWith(u8, bytes, "\x1b[0m"));
    try std.testing.expect(bytes.len < max_bytes);
}

test "an empty image is refused" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.EmptyImage, encode(alloc, &.{}, 0, 0, 4, 2, 1, 1, max_bytes));
}
