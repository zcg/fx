//! Encodes RGBA pixels as a sixel image.
//!
//! Windows Terminal draws Sixel and nothing else: it parses `DCS ... q`, paints
//! the pixels into its own image buffer, and drops the Kitty graphics APC
//! sequence without a word. So a preview that has to appear there needs a
//! raster encoding, and this is it.
//!
//! Sixel stores an image as horizontal bands six pixels tall. A byte in the
//! payload is one column of one band: `?` is empty, and the low six bits of any
//! byte from `?` to `~` are the pixels of that column, top row in the low bit.
//! A band is drawn one color at a time, and `$` rewinds to the left edge so the
//! next color can paint over the same band.
//!
//! The palette is built per image by median cut, then every pixel is mapped
//! through a small lookup table. Nothing here reads the filesystem or talks to
//! a terminal; the caller supplies pixels and owns the returned bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

/// Colors offered to the image. Sixel addresses 256 registers; the rest are
/// left alone so a terminal that reserves a few still works.
pub const palette_size: usize = 240;

/// The coarsest color resolution the histogram keeps. Five bits per channel is
/// finer than the eye needs at preview size and keeps the table small: 32768
/// cells, one byte of palette index each.
const levels: usize = 32;
const histogram_cells: usize = levels * levels * levels;

pub const Error = error{
    OutOfMemory,
    /// The encoded image passed the caller's ceiling, so the preview is not
    /// worth sending. The badge stays and the file is untouched.
    TooLarge,
    EmptyImage,
};

const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

/// One palette entry and the pixels it stands for, for the median cut.
const Bucket = struct {
    count: u32,
    sum_r: u64,
    sum_g: u64,
    sum_b: u64,
};

/// Encodes `pixels` (RGBA, row-major, `width * height` entries) as one sixel
/// string, including the `DCS` wrapper.
///
/// `max_bytes` bounds the result: a photographic preview can encode to several
/// megabytes when the image is busy, and a terminal that stalls on a slow write
/// is worse than a badge. `error.TooLarge` means the caller should skip.
pub fn encode(
    alloc: Allocator,
    pixels: []const u8,
    width: u32,
    height: u32,
    max_bytes: usize,
) Error![]u8 {
    if (width == 0 or height == 0) return error.EmptyImage;
    if (pixels.len < @as(usize, width) * height * 4) return error.EmptyImage;

    const histogram = try alloc.alloc(Bucket, histogram_cells);
    defer alloc.free(histogram);
    @memset(histogram, .{ .count = 0, .sum_r = 0, .sum_g = 0, .sum_b = 0 });
    collectHistogram(histogram, pixels, width, height);

    var populated: ArrayList(usize) = .empty;
    defer populated.deinit(alloc);
    for (histogram, 0..) |bucket, index| {
        if (bucket.count != 0) try populated.append(alloc, index);
    }
    if (populated.items.len == 0) return error.EmptyImage;

    var palette: [palette_size]Rgb = undefined;
    const palette_len = buildPalette(alloc, histogram, populated.items, &palette) catch 0;
    if (palette_len == 0) return error.EmptyImage;

    const lookup = try alloc.alloc(u8, histogram_cells);
    defer alloc.free(lookup);
    buildLookup(lookup, palette[0..palette_len]);

    var out: ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try writeHeader(alloc, &out, width, height);
    try writePalette(alloc, &out, palette[0..palette_len], max_bytes);
    try writePixels(alloc, &out, lookup, palette[0..palette_len], pixels, width, height, max_bytes);
    try appendAll(alloc, &out, "\x1b\\", max_bytes);
    return out.toOwnedSlice(alloc);
}

/// The five-bit cube position of a channel.
fn levelOf(value: u8) usize {
    return @as(usize, value) >> 3;
}

fn cellOf(r: u8, g: u8, b: u8) usize {
    return (levelOf(r) * levels + levelOf(g)) * levels + levelOf(b);
}

fn collectHistogram(histogram: []Bucket, pixels: []const u8, width: u32, height: u32) void {
    var index: usize = 0;
    const count = @as(usize, width) * height;
    while (index < count) : (index += 1) {
        const base = index * 4;
        const r = pixels[base];
        const g = pixels[base + 1];
        const b = pixels[base + 2];
        const bucket = &histogram[cellOf(r, g, b)];
        bucket.count += 1;
        bucket.sum_r += r;
        bucket.sum_g += g;
        bucket.sum_b += b;
    }
}

/// A range of `entries` that median cut may split.
const Box = struct {
    start: usize,
    end: usize,
    /// The extent of the colors inside, which picks the axis to split on.
    min: [3]u8,
    max: [3]u8,
    count: u64,

    fn measure(self: *Box, entries: []const usize, histogram: []const Bucket) void {
        self.count = 0;
        self.min = .{ 255, 255, 255 };
        self.max = .{ 0, 0, 0 };
        for (entries[self.start..self.end]) |cell| {
            const r = cell / (levels * levels);
            const g = (cell / levels) % levels;
            const b = cell % levels;
            const channels = [3]u8{
                @intCast(r << 3),
                @intCast(g << 3),
                @intCast(b << 3),
            };
            for (channels, 0..) |value, axis| {
                self.min[axis] = @min(self.min[axis], value);
                self.max[axis] = @max(self.max[axis], value);
            }
            self.count += histogram[cell].count;
        }
    }

    fn widestAxis(self: Box) usize {
        var axis: usize = 0;
        var widest: u8 = 0;
        for (0..3) |candidate| {
            const width = self.max[candidate] -| self.min[candidate];
            if (width > widest) {
                widest = width;
                axis = candidate;
            }
        }
        return axis;
    }
};

/// Median cut: repeatedly split the widest box at its weighted median until
/// there are `palette_size` colors or nothing left to split.
fn buildPalette(
    alloc: Allocator,
    histogram: []const Bucket,
    populated: []const usize,
    palette: *[palette_size]Rgb,
) !usize {
    var entries = try alloc.dupe(usize, populated);
    defer alloc.free(entries);

    var boxes: ArrayList(Box) = .empty;
    defer boxes.deinit(alloc);
    var first = Box{ .start = 0, .end = entries.len, .min = .{ 0, 0, 0 }, .max = .{ 0, 0, 0 }, .count = 0 };
    first.measure(entries, histogram);
    try boxes.append(alloc, first);

    while (boxes.items.len < palette_size) {
        // Split the box with the widest color spread, and only if it holds more
        // than one entry: splitting a single color would make duplicate palette
        // registers and waste the budget.
        var target: ?usize = null;
        var widest: u8 = 0;
        for (boxes.items, 0..) |box, index| {
            if (box.end - box.start < 2) continue;
            const axis = box.widestAxis();
            const spread = box.max[axis] -| box.min[axis];
            if (spread == 0) continue;
            if (spread > widest) {
                widest = spread;
                target = index;
            }
        }
        const box_index = target orelse break;

        const box = boxes.items[box_index];
        const axis = box.widestAxis();
        const slice = entries[box.start..box.end];
        sortByChannel(slice, axis);
        // Split where half the pixels have passed, not half the buckets: a
        // large flat area deserves more of the palette than a few stragglers.
        const half = box.count / 2;
        var seen: u64 = 0;
        var split = box.start + 1;
        for (slice, 0..) |cell, offset| {
            seen += histogram[cell].count;
            if (seen >= half) {
                split = box.start + offset + 1;
                break;
            }
        }
        if (split >= box.end) split = box.end - 1;
        if (split <= box.start) split = box.start + 1;

        var left = Box{ .start = box.start, .end = split, .min = .{ 0, 0, 0 }, .max = .{ 0, 0, 0 }, .count = 0 };
        var right = Box{ .start = split, .end = box.end, .min = .{ 0, 0, 0 }, .max = .{ 0, 0, 0 }, .count = 0 };
        left.measure(entries, histogram);
        right.measure(entries, histogram);
        boxes.items[box_index] = left;
        try boxes.append(alloc, right);
    }

    for (boxes.items, 0..) |box, index| {
        var total: u64 = 0;
        var sum_r: u64 = 0;
        var sum_g: u64 = 0;
        var sum_b: u64 = 0;
        for (entries[box.start..box.end]) |cell| {
            const bucket = histogram[cell];
            total += bucket.count;
            sum_r += bucket.sum_r;
            sum_g += bucket.sum_g;
            sum_b += bucket.sum_b;
        }
        if (total == 0) {
            palette[index] = .{ .r = 0, .g = 0, .b = 0 };
            continue;
        }
        palette[index] = .{
            .r = @intCast(@min(sum_r / total, 255)),
            .g = @intCast(@min(sum_g / total, 255)),
            .b = @intCast(@min(sum_b / total, 255)),
        };
    }
    return boxes.items.len;
}

fn channelOf(cell: usize, axis: usize) u8 {
    return switch (axis) {
        0 => @intCast(cell / (levels * levels)),
        1 => @intCast((cell / levels) % levels),
        else => @intCast(cell % levels),
    };
}

fn sortByChannel(slice: []usize, axis: usize) void {
    std.mem.sort(usize, slice, axis, struct {
        fn lessThan(which: usize, a: usize, b: usize) bool {
            return channelOf(a, which) < channelOf(b, which);
        }
    }.lessThan);
}

/// Maps every five-bit color to its nearest palette entry, so encoding is one
/// table read per pixel instead of a search.
fn buildLookup(lookup: []u8, palette: []const Rgb) void {
    for (0..histogram_cells) |cell| {
        const r: i32 = @intCast((cell / (levels * levels)) << 3);
        const g: i32 = @intCast(((cell / levels) % levels) << 3);
        const b: i32 = @intCast((cell % levels) << 3);
        var best: usize = 0;
        var best_distance: i32 = std.math.maxInt(i32);
        for (palette, 0..) |entry, index| {
            const dr = r - @as(i32, entry.r);
            const dg = g - @as(i32, entry.g);
            const db = b - @as(i32, entry.b);
            const distance = dr * dr + dg * dg + db * db;
            if (distance < best_distance) {
                best_distance = distance;
                best = index;
            }
        }
        lookup[cell] = @intCast(best);
    }
}

fn appendAll(alloc: Allocator, out: *ArrayList(u8), bytes: []const u8, max_bytes: usize) Error!void {
    if (out.items.len + bytes.len > max_bytes) return error.TooLarge;
    try out.appendSlice(alloc, bytes);
}

fn append(alloc: Allocator, out: *ArrayList(u8), byte: u8, max_bytes: usize) Error!void {
    if (out.items.len + 1 > max_bytes) return error.TooLarge;
    try out.append(alloc, byte);
}

fn writeHeader(alloc: Allocator, out: *ArrayList(u8), width: u32, height: u32) Error!void {
    // P1=0 (no macro), P2=1 (transparent background: unset pixels keep what the
    // text layer drew), P3=0 (default pixel aspect).
    try appendAll(alloc, out, "\x1bP0;1;0q", 4096);
    var buffer: [48]u8 = undefined;
    const raster = printInto(&buffer, "\"1;1;{d};{d}", .{ width, height });
    try appendAll(alloc, out, raster, 4096);
}

fn writePalette(alloc: Allocator, out: *ArrayList(u8), palette: []const Rgb, max_bytes: usize) Error!void {
    var buffer: [48]u8 = undefined;
    for (palette, 0..) |entry, index| {
        // Sixel gives color components as percentages, so the round trip through
        // 0..100 loses a little precision. That is the format, not a choice.
        const r = @as(u32, entry.r) * 100 / 255;
        const g = @as(u32, entry.g) * 100 / 255;
        const b = @as(u32, entry.b) * 100 / 255;
        const text = printInto(&buffer, "#{d};2;{d};{d};{d}", .{ index, r, g, b });
        try appendAll(alloc, out, text, max_bytes);
    }
}

fn writePixels(
    alloc: Allocator,
    out: *ArrayList(u8),
    lookup: []const u8,
    palette: []const Rgb,
    pixels: []const u8,
    width: u32,
    height: u32,
    max_bytes: usize,
) Error!void {
    const columns: usize = width;
    const rows: usize = height;

    // One palette index per pixel, so a band can be scanned once per color.
    var indices = try alloc.alloc(u8, columns * rows);
    defer alloc.free(indices);
    for (0..columns * rows) |index| {
        const base = index * 4;
        indices[index] = lookup[cellOf(pixels[base], pixels[base + 1], pixels[base + 2])];
    }

    var used = try alloc.alloc(bool, palette.len);
    defer alloc.free(used);
    var band_colors: ArrayList(usize) = .empty;
    defer band_colors.deinit(alloc);

    var band: usize = 0;
    while (band * 6 < rows) : (band += 1) {
        @memset(used, false);
        band_colors.clearRetainingCapacity();
        const top = band * 6;
        const bottom = @min(top + 6, rows);
        for (top..bottom) |row| {
            for (indices[row * columns ..][0..columns]) |index| {
                if (used[index]) continue;
                used[index] = true;
                try band_colors.append(alloc, index);
            }
        }
        // A terminal leaves the previous band's colors selected, but starting
        // each band from a known color keeps the payload independent of what
        // came before it.
        var first_color = true;
        for (band_colors.items) |color| {
            if (!first_color) try append(alloc, out, '$', max_bytes);
            first_color = false;
            var buffer: [24]u8 = undefined;
            const select = printInto(&buffer, "#{d}", .{color});
            try appendAll(alloc, out, select, max_bytes);

            var column: usize = 0;
            while (column < columns) {
                // The band only needs the span this color actually covers: a
                // full-width `?` run for every color would multiply the payload
                // by the palette size.
                const mask = sixelMask(indices, color, top, bottom, columns, column);
                if (mask == 0 and !colorLeftInSpan(indices, color, top, bottom, columns, column)) break;
                var run: usize = 1;
                while (column + run < columns) : (run += 1) {
                    const next = sixelMask(indices, color, top, bottom, columns, column + run);
                    const here = sixelMask(indices, color, top, bottom, columns, column);
                    if (next != here) break;
                    if (here == 0 and !colorLeftInSpan(indices, color, top, bottom, columns, column + run)) break;
                }
                if (run > 3) {
                    var run_buffer: [24]u8 = undefined;
                    const text = printInto(&run_buffer, "!{d}{c}", .{ run, @as(u8, '?') + mask });
                    try appendAll(alloc, out, text, max_bytes);
                } else {
                    for (0..run) |_| try append(alloc, out, @as(u8, '?') + mask, max_bytes);
                }
                column += run;
            }
        }
        if (band * 6 + 6 < rows) {
            // `-` moves to the next band without rewinding, which is what the
            // next iteration expects.
            try append(alloc, out, '-', max_bytes);
        }
    }
}

fn sixelMask(indices: []const u8, color: usize, top: usize, bottom: usize, columns: usize, column: usize) u8 {
    var mask: u8 = 0;
    var row = top;
    while (row < bottom) : (row += 1) {
        if (indices[row * columns + column] == color) mask |= @as(u8, 1) << @intCast(row - top);
    }
    return mask;
}

fn colorLeftInSpan(indices: []const u8, color: usize, top: usize, bottom: usize, columns: usize, column: usize) bool {
    var x = column;
    while (x < columns) : (x += 1) {
        if (sixelMask(indices, color, top, bottom, columns, x) != 0) return true;
    }
    return false;
}

test "a solid image encodes one color and one run per band" {
    const alloc = std.testing.allocator;
    const width: u32 = 8;
    const height: u32 = 12;
    var pixels: [8 * 12 * 4]u8 = undefined;
    var index: usize = 0;
    while (index < 8 * 12) : (index += 1) {
        pixels[index * 4] = 255;
        pixels[index * 4 + 1] = 0;
        pixels[index * 4 + 2] = 0;
        pixels[index * 4 + 3] = 255;
    }
    const encoded = try encode(alloc, &pixels, width, height, 64 * 1024);
    defer alloc.free(encoded);

    try std.testing.expect(std.mem.startsWith(u8, encoded, "\x1bP0;1;0q"));
    try std.testing.expect(std.mem.endsWith(u8, encoded, "\x1b\\"));
    try std.testing.expect(std.mem.find(u8, encoded, "\"1;1;8;12") != null);
    // Two bands of six rows, each one run of eight full columns.
    try std.testing.expect(std.mem.find(u8, encoded, "!8~") != null);
    try std.testing.expect(std.mem.find(u8, encoded, "#0;2;100;0;0") != null);
}

test "a row of one color over another needs both colors in the band" {
    const alloc = std.testing.allocator;
    const width: u32 = 2;
    const height: u32 = 2;
    const pixels = [_]u8{
        255, 255, 255, 255, 0,   0,   0,   255,
        0,   0,   0,   255, 255, 255, 255, 255,
    };
    const encoded = try encode(alloc, &pixels, width, height, 64 * 1024);
    defer alloc.free(encoded);
    try std.testing.expect(std.mem.find(u8, encoded, "#0") != null);
    try std.testing.expect(std.mem.find(u8, encoded, "#1") != null);
}

test "an image past the ceiling is refused rather than sent" {
    const alloc = std.testing.allocator;
    var pixels: [32 * 32 * 4]u8 = undefined;
    var index: usize = 0;
    while (index < 32 * 32) : (index += 1) {
        pixels[index * 4] = @truncate(index);
        pixels[index * 4 + 1] = @truncate(index * 3);
        pixels[index * 4 + 2] = @truncate(index * 7);
        pixels[index * 4 + 3] = 255;
    }
    try std.testing.expectError(error.TooLarge, encode(alloc, &pixels, 32, 32, 8));
}

test "an empty image is refused" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.EmptyImage, encode(alloc, &.{}, 0, 0, 4096));
}

/// Formats into a fixed buffer sized for the largest value the caller passes.
fn printInto(buffer: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.mem.print(buffer, fmt, args) catch unreachable;
}
