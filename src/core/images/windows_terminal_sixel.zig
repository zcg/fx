//! A deliberately tiny Sixel preview for Windows Terminal.
//!
//! Windows Terminal's Sixel parser is real, but its image buffer is indexed and
//! every band newline calls `_maybeFlushImageBuffer`, which can scroll and
//! reallocate the whole buffer. A photographic preview with hundreds of color
//! changes and 47 bands produced 27 KB of output and stalled the tab.
//!
//! This encoder is the opposite of a general image codec: 16 fixed colors,
//! 96 x 48 pixels, no repeat commands, no raster attribute negotiation, and
//! one color pass per six-pixel band. The result is a few kilobytes of plain
//! `DCS q ... ST`, which the parser can walk without the slow paths. It is
//! only used when the terminal identifies itself as Windows Terminal.

const std = @import("std");
const Allocator = std.mem.Allocator;

const palette = [_][3]u8{
    .{ 0, 0, 0 },
    .{ 128, 0, 0 },
    .{ 0, 128, 0 },
    .{ 128, 128, 0 },
    .{ 0, 0, 128 },
    .{ 128, 0, 128 },
    .{ 0, 128, 128 },
    .{ 192, 192, 192 },
    .{ 128, 128, 128 },
    .{ 255, 0, 0 },
    .{ 0, 255, 0 },
    .{ 255, 255, 0 },
    .{ 0, 0, 255 },
    .{ 255, 0, 255 },
    .{ 0, 255, 255 },
    .{ 255, 255, 255 },
};

/// The encoded preview, bounded by the caller's wire ceiling.
pub const Error = error{ OutOfMemory, TooLarge, EmptyImage };

pub const max_width: u32 = 64;
pub const max_height: u32 = 24;
pub const max_bytes: usize = 8 * 1024;

pub fn encode(
    alloc: Allocator,
    pixels: []const u8,
    width: u32,
    height: u32,
    ceiling: usize,
) Error![]u8 {
    if (width == 0 or height == 0) return error.EmptyImage;
    if (pixels.len < @as(usize, width) * height * 4) return error.EmptyImage;

    // Fit the source into a small raster. Six rows of pixels per band, so the
    // height is a multiple of six and no partial band has to be padded.
    const out_width = @min(width, max_width);
    const out_height = @min(height, max_height -| (max_height % 6));
    if (out_width == 0 or out_height == 0) return error.EmptyImage;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try append(alloc, &out, "\x1bP0;1;0q", ceiling);

    var buffer: [32]u8 = undefined;
    for (palette, 0..) |color, index| {
        const r = @as(u32, color[0]) * 100 / 255;
        const g = @as(u32, color[1]) * 100 / 255;
        const b = @as(u32, color[2]) * 100 / 255;
        const text = std.mem.print(&buffer, "#{d};2;{d};{d};{d}", .{ index, r, g, b }) catch return error.TooLarge;
        try append(alloc, &out, text, ceiling);
    }

    var band: usize = 0;
    while (band * 6 < out_height) : (band += 1) {
        const top = band * 6;
        for (palette, 0..) |_, color| {
            // One color pass writes only the columns this color owns. A
            // column's six vertical pixels are one character, so each band
            // emits at most palette.len * out_width bytes.
            var buffer2: [32]u8 = undefined;
            const select = std.mem.print(&buffer2, "#{d}", .{color}) catch return error.TooLarge;
            try append(alloc, &out, select, ceiling);
            var x: usize = 0;
            while (x < out_width) : (x += 1) {
                var mask: u8 = 0;
                var y: usize = 0;
                while (y < 6) : (y += 1) {
                    const source_x = x * width / out_width;
                    const source_y = (top + y) * height / out_height;
                    const base = (@as(usize, source_y) * width + source_x) * 4;
                    if (nearest(pixels[base], pixels[base + 1], pixels[base + 2]) == color) {
                        mask |= @as(u8, 1) << @intCast(y);
                    }
                }
                // `?` advances one column without writing a pixel.
                try appendByte(alloc, &out, @as(u8, '?') + mask, ceiling);
            }
            try appendByte(alloc, &out, '$', ceiling);
        }
        if ((band + 1) * 6 < out_height) try appendByte(alloc, &out, '-', ceiling);
    }
    try append(alloc, &out, "\x1b\\", ceiling);
    return out.toOwnedSlice(alloc);
}

fn nearest(r: u8, g: u8, b: u8) usize {
    var best: usize = 0;
    var best_distance: u32 = std.math.maxInt(u32);
    for (palette, 0..) |entry, index| {
        const dr: i32 = @as(i32, r) - entry[0];
        const dg: i32 = @as(i32, g) - entry[1];
        const db: i32 = @as(i32, b) - entry[2];
        const distance: u32 = @intCast(dr * dr + dg * dg + db * db);
        if (distance < best_distance) {
            best_distance = distance;
            best = index;
        }
    }
    return best;
}

fn append(alloc: Allocator, out: *std.ArrayList(u8), bytes: []const u8, ceiling: usize) Error!void {
    if (out.items.len + bytes.len > ceiling) return error.TooLarge;
    try out.appendSlice(alloc, bytes);
}

fn appendByte(alloc: Allocator, out: *std.ArrayList(u8), byte: u8, ceiling: usize) Error!void {
    if (out.items.len + 1 > ceiling) return error.TooLarge;
    try out.append(alloc, byte);
}

test "a tiny solid image stays bounded and declares a palette" {
    const alloc = std.testing.allocator;
    const width: u32 = 16;
    const height: u32 = 12;
    const pixels = try alloc.alloc(u8, @as(usize, width) * height * 4);
    defer alloc.free(pixels);
    @memset(pixels, 255);
    const encoded = try encode(alloc, pixels, width, height, max_bytes);
    defer alloc.free(encoded);
    try std.testing.expect(std.mem.startsWith(u8, encoded, "\x1bP0;1;0q"));
    try std.testing.expect(std.mem.endsWith(u8, encoded, "\x1b\\"));
    try std.testing.expect(encoded.len < max_bytes);
}

test "a photograph-sized raster stays far below the payload that stalled Windows Terminal" {
    const alloc = std.testing.allocator;
    const width: u32 = 480;
    const height: u32 = 280;
    const pixels = try alloc.alloc(u8, @as(usize, width) * height * 4);
    defer alloc.free(pixels);
    var seed: u32 = 0x1234_5678;
    for (0..@as(usize, width) * height) |index| {
        seed = seed *% 1_664_525 +% 1_013_904_223;
        pixels[index * 4 + 0] = @truncate(seed >> 24);
        pixels[index * 4 + 1] = @truncate(index);
        pixels[index * 4 + 2] = @truncate(index * 3);
        pixels[index * 4 + 3] = 255;
    }
    const encoded = try encode(alloc, pixels, width, height, max_bytes);
    defer alloc.free(encoded);
    // Four bands of 64 columns times sixteen colors, plus palette: about
    // 4 KB. This is the ceiling WT sees, not the 27 KB photographical form.
    try std.testing.expect(encoded.len < 8 * 1024);
    try std.testing.expect(encoded.len > 1024);
}

test "an empty image is refused" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.EmptyImage, encode(alloc, &.{}, 0, 0, max_bytes));
}
