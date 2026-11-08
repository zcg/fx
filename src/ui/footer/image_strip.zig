//! Draws pasted images as thumbnails above the composer.
//!
//! A badge is text: `[Image #1]` names the attachment and links to the file.
//! A thumbnail is pixels, which the terminal can only draw if it speaks one of
//! the inline image protocols. This module owns that second half: how many rows
//! a strip of thumbnails needs, what to send to draw them, and what to send to
//! take them away again.
//!
//! Nothing here decides layout. The footer asks `rowsFor` to reserve space and
//! `writeStrip` to fill it, the same way it asks for any other block.
//!
//! Sizing follows the rule the terminals themselves impose: a Kitty placement
//! names the columns and rows it should cover, and the terminal scales the
//! raster into that box keeping the aspect ratio. So the caller picks the
//! number of cells, not the pixel size, and a 4000-pixel screenshot costs the
//! same transfer as a 400-pixel one only if the source is the same size. To
//! keep the transfer small the raster is downsampled first, to roughly twice
//! the cell box so a scaled-down draw still looks sharp.

const std = @import("std");
const terminal_image = @import("../../core/shared/terminal_image.zig");
const terminal_image_render = @import("../../core/shared/terminal_image_render.zig");

const Allocator = std.mem.Allocator;

/// How many attachment thumbnails fit side by side before the strip reports
/// the rest as a count.
pub const max_thumbnails: usize = 8;

/// Columns one thumbnail occupies, including its one-column gap.
const thumbnail_columns: u16 = 12;

/// Rows one thumbnail occupies.
const thumbnail_rows: u16 = 6;

/// Columns of blank space after each thumbnail, so two do not touch.
const gap_columns: u16 = 1;

pub const Strip = struct {
    /// Attachment ids in the order they were attached.
    ids: []const usize,
    /// Absolute paths of the same attachments.
    paths: []const []const u8,
    /// The largest id in `ids`, so a redraw can clear every placement this
    /// strip owns without walking the previous frame.
    highest_id: u32,
};

/// How many rows a strip of `count` thumbnails needs, or 0 when there is
/// nothing to draw.
///
/// The caller reserves these rows. A count of zero keeps the composer exactly
/// as it is today, which is what a terminal without an image protocol gets.
pub fn rowsFor(protocol: terminal_image.Protocol, count: usize) u16 {
    if (!protocol.drawsImages()) return 0;
    if (count == 0) return 0;
    return thumbnail_rows;
}

/// Columns the first `count` thumbnails occupy, clamped to `available`.
pub fn columnsFor(count: usize) u16 {
    if (count == 0) return 0;
    const shown: u16 = @intCast(@min(count, max_thumbnails));
    const total = std.math.mul(u16, shown, thumbnail_columns + gap_columns) catch return std.math.maxInt(u16);
    return total;
}

/// Writes the sequences that draw the strip, one placement per image.
///
/// `png_for` supplies each image's encoded bytes, so this module never touches
/// the filesystem: the caller already holds the attachments and knows how to
/// read them. A path that cannot be read is skipped rather than ending the
/// draw, because a thumbnail is decoration and a broken one must not cost the
/// user their composer.
pub fn writeStrip(
    w: *std.Io.Writer,
    alloc: Allocator,
    strip: Strip,
    png_for: anytype,
    available_columns: u16,
) !void {
    if (strip.ids.len == 0) return;
    const shown = @min(strip.ids.len, max_thumbnails);
    var column: u16 = 0;
    for (strip.ids[0..shown], strip.paths[0..shown]) |id, path| {
        if (column + thumbnail_columns > available_columns) return;
        // A read failure leaves the badge in place and draws nothing here.
        const png: []const u8 = png_for.get(path) catch continue;
        defer freeBytes(alloc, png);
        try terminal_image_render.writePng(w, png, .{
            .columns = thumbnail_columns,
            .rows = thumbnail_rows,
            .image_id = @intCast(id),
        });
        // The placement leaves the cursor where it started, so the next
        // thumbnail needs the move spelled out.
        try w.print("\x1b[{d}C", .{thumbnail_columns + gap_columns});
        column += thumbnail_columns + gap_columns;
    }
}

/// Writes the sequences that remove every placement the strip owned.
///
/// Called when the attachments change or the session ends, so a stale picture
/// does not outlive the badge that named it.
pub fn writeClear(w: *std.Io.Writer, highest_id: u32) !void {
    var id: u32 = 1;
    while (id <= highest_id) : (id += 1) {
        try terminal_image_render.writeDelete(w, id);
    }
}

fn freeBytes(alloc: Allocator, bytes: []const u8) void {
    alloc.free(bytes);
}

test "a terminal without an image protocol reserves no rows" {
    try std.testing.expectEqual(@as(u16, 0), rowsFor(.none, 3));
    try std.testing.expectEqual(@as(u16, 0), rowsFor(.kitty, 0));
    try std.testing.expectEqual(thumbnail_rows, rowsFor(.kitty, 1));
    try std.testing.expectEqual(thumbnail_rows, rowsFor(.iterm2, 2));
    try std.testing.expectEqual(thumbnail_rows, rowsFor(.sixel, 1));
}

test "columns grow with the count and stop at the visible maximum" {
    try std.testing.expectEqual(@as(u16, 0), columnsFor(0));
    try std.testing.expectEqual(thumbnail_columns + gap_columns, columnsFor(1));
    try std.testing.expectEqual(
        max_thumbnails * (thumbnail_columns + gap_columns),
        columnsFor(max_thumbnails + 5),
    );
}

test "the strip keeps the badge image ids as its placement ids" {
    // A redraw has to replace the same placements, so the id the badge shows is
    // the id the terminal stores.
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const Decoder = struct {
        fn get(_: *const @This(), path: []const u8) ![]const u8 {
            _ = path;
            return std.testing.allocator.dupe(u8, "\x89PNG\r\n\x1a\nbody");
        }
    };
    const ids = [_]usize{ 4, 5 };
    const paths = [_][]const u8{ "/tmp/a.png", "/tmp/b.png" };
    try writeStrip(&out.writer, alloc, .{
        .ids = &ids,
        .paths = &paths,
        .highest_id = 5,
    }, Decoder{}, 200);
    const written = out.written();
    try std.testing.expect(std.mem.find(u8, written, "i=4,c=12,r=6") != null);
    try std.testing.expect(std.mem.find(u8, written, "i=5,c=12,r=6") != null);
    // One cursor move between the two placements.
    try std.testing.expect(std.mem.find(u8, written, "\x1b[13C") != null);
}

test "an unreadable image is skipped without losing the rest of the strip" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const Decoder = struct {
        fn get(_: *const @This(), path: []const u8) ![]const u8 {
            if (std.mem.endsWith(u8, path, "missing.png")) return error.FileNotFound;
            return std.testing.allocator.dupe(u8, "\x89PNG\r\n\x1a\nbody");
        }
    };
    const ids = [_]usize{ 1, 2 };
    const paths = [_][]const u8{ "/tmp/missing.png", "/tmp/ok.png" };
    try writeStrip(&out.writer, alloc, .{
        .ids = &ids,
        .paths = &paths,
        .highest_id = 2,
    }, Decoder{}, 200);
    const written = out.written();
    try std.testing.expect(std.mem.find(u8, written, "i=1,") == null);
    try std.testing.expect(std.mem.find(u8, written, "i=2,") != null);
}

test "clearing stops at the highest id the strip owned" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeClear(&out.writer, 3);
    const written = out.written();
    try std.testing.expect(std.mem.find(u8, written, "i=1,") != null);
    try std.testing.expect(std.mem.find(u8, written, "i=3,") != null);
    try std.testing.expect(std.mem.find(u8, written, "i=4,") == null);
}
