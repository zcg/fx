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
const io_mod = @import("../../core/shared/io.zig");
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

/// Cells the preview covers. Wider than tall, because a screenshot is usually
/// wider than tall and a terminal cell is about twice as tall as it is wide.
pub const preview_columns: u16 = 48;
pub const preview_rows: u16 = 14;

/// Reads an image file for the preview.
///
/// The terminal scales the raster into the cell box itself, so the bytes go out
/// exactly as they were saved: no decode, no re-encode, no resampling. What is
/// bounded is the transfer, because a preview is decoration and must not stall
/// a frame; anything past the limit simply leaves the badge alone.
pub fn readPreviewPng(alloc: Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    var held = file;
    const bytes = try io_mod.readFileToEnd(alloc, &held, preview_byte_limit);
    errdefer alloc.free(bytes);
    if (bytes.len == 0) return error.EmptyImage;
    return bytes;
}

/// Holds the bytes of the one image a preview is showing.
///
/// A frame is rebuilt many times a second while a key is held or a reply
/// streams in, and re-reading a megabyte from disk on every one of those frames
/// is work nobody sees. The bytes are kept only while the same image stays on
/// screen: the moment the preview moves to another image, or the attachment
/// leaves the composer, the memory goes back. Nothing here outlives the turn,
/// because a sent image is only a record of having sent one.
pub const PreviewCache = struct {
    /// The image these bytes belong to; zero means empty.
    image_id: usize = 0,
    bytes: []u8 = .{},

    pub fn deinit(self: *PreviewCache, alloc: Allocator) void {
        if (self.bytes.len != 0) alloc.free(self.bytes);
        self.* = .{};
    }

    /// The bytes for `attachment`, reading them only when they are not already
    /// held. The returned slice stays valid until the next call.
    pub fn get(self: *PreviewCache, alloc: Allocator, attachment: anytype) ![]const u8 {
        if (self.image_id == attachment.id and self.bytes.len != 0) return self.bytes;
        self.deinit(alloc);
        const bytes = try readPreviewPng(alloc, attachment.path);
        self.image_id = attachment.id;
        self.bytes = bytes;
        return bytes;
    }

    /// Drops the bytes when the preview no longer shows `image_id`.
    pub fn keepOnly(self: *PreviewCache, alloc: Allocator, image_id: usize) void {
        if (self.image_id == image_id) return;
        self.deinit(alloc);
    }
};

/// How large a preview source may be. The terminals guard against a large
/// raster themselves, and a frame that waits on a multi-megabyte read is worse
/// than a frame without a picture.
pub const preview_byte_limit: usize = 16 * 1024 * 1024;

/// Whether thumbnails above the composer are drawn at all.
///
/// A thumbnail is decoration on top of the badge, so it must never cost the
/// composer. The image sequence cannot travel inside a text row either: the
/// terminal surface writes a band as rows of text, and a multi-megabyte APC
/// string makes that band overflow. Drawing a thumbnail needs its own pass
/// after the text, which is not built yet, so the badge stays the whole story.
fn thumbnailsEnabled() bool {
    return false;
}

/// Where a badge sits in the composed footer, in 1-based terminal cells.
pub const BadgeAnchor = struct {
    row: u16,
    column: u16,
    /// Visible columns the badge occupies, so a preview can center on it.
    width: u16,
};

/// Finds the first image badge in the composed rows.
///
/// The badge text is what the composer already writes, so the anchor is read
/// from the same string the user sees rather than recomputed from the layout:
/// two sources of truth for one position would drift apart the first time the
/// composer changed.
pub fn findBadgeAnchor(rows: anytype, image_id: usize) ?BadgeAnchor {
    var needle_buf: [32]u8 = undefined;
    const needle = std.mem.print(&needle_buf, "[Image {d}]", .{image_id}) catch return null;
    for (rows) |composed| {
        // Rows carry escape sequences for links and styling, so the badge is
        // searched in the visible text rather than the raw bytes.
        const visible_at = visibleColumnOf(composed.text.items, needle) orelse continue;
        return .{
            .row = composed.row,
            .column = @intCast(visible_at + 1),
            .width = @intCast(needle.len),
        };
    }
    return null;
}

/// The 0-based visible column where `needle` starts, ignoring escape sequences.
fn visibleColumnOf(text: []const u8, needle: []const u8) ?usize {
    var visible: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == 0x1b) {
            index = skipEscape(text, index);
            continue;
        }
        if (std.mem.startsWith(u8, text[index..], needle)) return visible;
        // Only printable bytes advance the column; a control byte does not.
        if (text[index] >= 0x20) visible += 1;
        index += 1;
    }
    return null;
}

/// Advances past the escape sequence starting at `index`.
fn skipEscape(text: []const u8, index: usize) usize {
    if (index + 1 >= text.len) return text.len;
    return switch (text[index + 1]) {
        // CSI and OSC both end at a terminator, not at a fixed length.
        '[' => blk: {
            var at = index + 2;
            while (at < text.len) : (at += 1) {
                const byte = text[at];
                if (byte >= 0x40 and byte <= 0x7e) break :blk at + 1;
            }
            break :blk text.len;
        },
        ']' => blk: {
            var at = index + 2;
            while (at < text.len) : (at += 1) {
                if (text[at] == 0x07) break :blk at + 1;
                if (text[at] == 0x1b and at + 1 < text.len and text[at + 1] == '\\') break :blk at + 2;
            }
            break :blk text.len;
        },
        // A two-byte sequence such as `ESC 7`.
        else => index + 2,
    };
}

/// A rectangle a preview occupies, in 1-based terminal cells.
pub const Rect = struct {
    row: u16,
    column: u16,
    columns: u16,
    rows: u16,
};

/// Places a preview above `anchor`, moving it only when the window cannot hold
/// it there.
///
/// The badge is where the user's eye already is, so the preview belongs right
/// above it. That is only possible when there is room: a badge near the top of
/// the window has to push the preview down, and one near the right edge has to
/// pull it left. The result always fits inside `layout` and never covers the
/// row the badge itself is on, so the badge stays readable while the preview is
/// up.
pub fn previewRect(
    anchor: BadgeAnchor,
    layout: struct { rows: u16, cols: u16 },
    wanted: struct { columns: u16, rows: u16 },
) ?Rect {
    if (layout.rows == 0 or layout.cols == 0) return null;
    if (wanted.columns == 0 or wanted.rows == 0) return null;

    const columns = @min(wanted.columns, layout.cols);
    const rows = @min(wanted.rows, layout.rows -| 1);
    if (rows == 0) return null;

    // Horizontally: center on the badge, then pull back inside the window.
    const half = anchor.width / 2;
    const centered_start = if (anchor.column > half) anchor.column - half else 1;
    const max_start = layout.cols -| columns + 1;
    const column = @max(@as(u16, 1), @min(centered_start, max_start));

    // Vertically: sit directly above the badge when the rows fit, otherwise
    // drop below it, and finally clamp to the window.
    const above_row = anchor.row -| rows;
    const fits_above = anchor.row > rows;
    const below_row = anchor.row + 1;
    const fits_below = below_row + rows <= layout.rows + 1;
    const row = if (fits_above)
        above_row
    else if (fits_below)
        below_row
    else blk: {
        // Neither side has room: use the top of the window.
        break :blk @as(u16, 1);
    };
    const max_row = layout.rows -| rows + 1;
    const clamped_row = @max(@as(u16, 1), @min(row, max_row));

    return .{
        .row = clamped_row,
        .column = column,
        .columns = columns,
        .rows = rows,
    };
}

/// A preview rectangle, in 1-based terminal cells.
pub const PreviewRect = Rect;

/// How many rows a strip of `count` thumbnails needs, or 0 when there is
/// nothing to draw.
///
/// The caller reserves these rows. A count of zero keeps the composer exactly
/// as it is today, which is what a terminal without an image protocol gets.
pub fn rowsFor(protocol: terminal_image.Protocol, count: usize) u16 {
    if (!thumbnailsEnabled()) return 0;
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
///
/// `origin` is the row and column of the first thumbnail. Each placement moves
/// the text cursor there first, because a Kitty placement with `C=1` leaves the
/// cursor alone and every image would otherwise land on the previous one.
pub fn writeStrip(
    w: *std.Io.Writer,
    alloc: Allocator,
    strip: Strip,
    png_for: anytype,
    origin: Origin,
    available_columns: u16,
) !void {
    if (strip.ids.len == 0) return;
    const shown = @min(strip.ids.len, max_thumbnails);
    var column: u16 = 0;
    for (strip.ids[0..shown], strip.paths[0..shown]) |id, path| {
        if (origin.column + column + thumbnail_columns > available_columns) return;
        // A read failure leaves the badge in place and draws nothing here.
        const png: []const u8 = png_for.get(path) catch continue;
        defer freeBytes(alloc, png);
        // Absolute placement, so two thumbnails never share a cell.
        try w.print("\x1b[{d};{d}H", .{ origin.row, origin.column + column });
        try terminal_image_render.writePng(w, png, .{
            .columns = thumbnail_columns,
            .rows = thumbnail_rows,
            .image_id = @intCast(id),
        });
        column += thumbnail_columns + gap_columns;
    }
    // Leave the cursor below the strip, where the composer expects it.
    try w.print("\x1b[{d};{d}H", .{ origin.row + thumbnail_rows, origin.column });
}

/// Where the first thumbnail goes, in 1-based terminal coordinates.
pub const Origin = struct {
    row: u16,
    column: u16,
};

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
    }, Decoder{}, .{ .row = 1, .column = 1 }, 200);
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
    }, Decoder{}, .{ .row = 1, .column = 1 }, 200);
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

test "a badge anchor is found past the styling the composer writes" {
    const alloc = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    try text.appendSlice(alloc, "\x1b[1mhello \x1b]8;;file:///a.png\x1b\\[Image 3]\x1b]8;;\x1b\\ done");
    const Composed = struct { row: u16, text: std.ArrayList(u8) };
    const composed = [_]Composed{.{ .row = 7, .text = text }};
    const anchor = findBadgeAnchor(&composed, 3).?;
    try std.testing.expectEqual(@as(u16, 7), anchor.row);
    try std.testing.expectEqual(@as(u16, 7), anchor.column);
    try std.testing.expectEqual(@as(u16, 9), anchor.width);
}

test "a preview sits above its badge when the window has room" {
    const rect = previewRect(
        .{ .row = 20, .column = 10, .width = 9 },
        .{ .rows = 30, .cols = 80 },
        .{ .columns = 40, .rows = 12 },
    ).?;
    try std.testing.expectEqual(@as(u16, 8), rect.row);
    try std.testing.expectEqual(@as(u16, 6), rect.column);
    try std.testing.expectEqual(@as(u16, 40), rect.columns);
    try std.testing.expectEqual(@as(u16, 12), rect.rows);
}

test "a preview drops below a badge that sits near the top" {
    const rect = previewRect(
        .{ .row = 3, .column = 1, .width = 9 },
        .{ .rows = 30, .cols = 80 },
        .{ .columns = 40, .rows = 12 },
    ).?;
    try std.testing.expectEqual(@as(u16, 4), rect.row);
}

test "a preview pulls left at the right edge and never leaves the window" {
    const rect = previewRect(
        .{ .row = 20, .column = 78, .width = 9 },
        .{ .rows = 30, .cols = 80 },
        .{ .columns = 40, .rows = 12 },
    ).?;
    try std.testing.expectEqual(@as(u16, 41), rect.column);
    try std.testing.expect(rect.column + rect.columns <= 81);
}

test "a preview shrinks rather than overflow a short window" {
    const rect = previewRect(
        .{ .row = 5, .column = 1, .width = 9 },
        .{ .rows = 8, .cols = 20 },
        .{ .columns = 40, .rows = 12 },
    ).?;
    try std.testing.expectEqual(@as(u16, 20), rect.columns);
    try std.testing.expect(rect.rows <= 7);
    try std.testing.expect(rect.row + rect.rows <= 9);
}
