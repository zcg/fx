//! Images drawn on top of a finished frame.
//!
//! A text frame is a grid of cells: every byte the frame carries is parsed,
//! measured, and placed into a column. An inline image is not that. Its escape
//! string is an APC payload, it occupies no column, and the terminal paints it
//! over the cells rather than inside them. So an image travels beside the text,
//! not through it.
//!
//! The Kitty byte form declares its format up front (`f=100` is PNG), so the
//! caller hands over PNG bytes. A pasted JPEG is turned into a PNG first by the
//! platform's own decoder; the protocol has no JPEG form at all, and JPEG bytes
//! declared as PNG are silently dropped by the terminal.
//!
//! An APC string is bounded, so bytes past one chunk travel as continuations:
//! the first chunk names the image and sets `m=1`, later chunks repeat `m=1`,
//! and the last chunk omits it. Nothing here reads the filesystem or decides
//! layout; the caller supplies the bytes and owns the writer.

const std = @import("std");

const Writer = std.Io.Writer;

/// ASCII bytes per chunk before base64. A multiple of three so no chunk
/// introduces base64 padding in the middle of the stream.
pub const chunk_bytes: usize = 3072;

/// One image and the cells it covers, in 1-based terminal coordinates.
pub const Placement = struct {
    /// Top-left cell the image starts at.
    row: u16,
    column: u16,
    /// Cells the image covers. The terminal scales the raster into this box.
    columns: u16,
    rows: u16,
    /// The id the placement is stored under, so a redraw can replace or delete
    /// exactly this image.
    image_id: u32,
    /// PNG bytes. The caller owns them for the duration of the write.
    png: []const u8,
    /// The same image already encoded as Sixel, for a terminal that speaks no
    /// Kitty graphics. Sixel has no ids and no deletion: the picture is painted
    /// into the cells and stays until text is written over them, so the
    /// protocol decides which of the two payloads a frame carries.
    sixel: []const u8 = &.{},
    /// Ordinary truecolor text, for a terminal whose graphics parser is not
    /// safe to use. Windows Terminal stalls on any DCS image, but half-block
    /// characters with 24-bit SGR colors are just text: they cannot enter the
    /// image buffer or its flush loop. The next text frame erases them.
    text: []const u8 = &.{},
};

/// The images a frame draws once its text is on screen.
pub const Overlay = struct {
    placements: []const Placement = &.{},
    /// The highest id this overlay has ever used, so a frame that drops an image
    /// can delete the placements the previous frame drew.
    highest_id: u32 = 0,

    pub fn isEmpty(self: Overlay) bool {
        return self.placements.len == 0 and self.highest_id == 0;
    }

    /// A fingerprint of what is on screen. It changes when the image, its id,
    /// or the cells it covers change, and stays the same across frames that
    /// only redraw text. The caller uses it to avoid re-sending pixels on
    /// every keystroke.
    ///
    /// The bytes are represented by their length and a short sample, not hashed
    /// in full: hashing a megabyte every frame would cost more than the check
    /// saves.
    pub fn fingerprint(self: Overlay) u64 {
        var hash = std.hash.Wyhash.init(0);
        hash.update(std.mem.asBytes(&self.highest_id));
        for (self.placements) |placement| {
            hash.update(std.mem.asBytes(&placement.row));
            hash.update(std.mem.asBytes(&placement.column));
            hash.update(std.mem.asBytes(&placement.columns));
            hash.update(std.mem.asBytes(&placement.rows));
            hash.update(std.mem.asBytes(&placement.image_id));
            const png_length: u64 = placement.png.len;
            hash.update(std.mem.asBytes(&png_length));
            hash.update(placement.png[0..@min(placement.png.len, 32)]);
            const sixel_length: u64 = placement.sixel.len;
            hash.update(std.mem.asBytes(&sixel_length));
            hash.update(placement.sixel[0..@min(placement.sixel.len, 32)]);
            const text_length: u64 = placement.text.len;
            hash.update(std.mem.asBytes(&text_length));
            hash.update(placement.text[0..@min(placement.text.len, 32)]);
        }
        return hash.final();
    }
};

/// Writes the sequence that draws every placement in `overlay`.
///
/// Each image is bracketed in `SavePosition`/`RestorePosition` and placed at an
/// absolute cell, so the frame's own cursor bookkeeping is untouched. `C=1`
/// tells the terminal not to move its raster cursor either, and `q=2` keeps it
/// from answering.
///
/// A placement that carries Sixel is drawn that way instead. Windows Terminal
/// parses DCS Sixel and drops the Kitty APC sequence without a word, so the
/// payload decides which protocol goes out; a placement with neither is
/// skipped.
pub fn write(w: *Writer, overlay: Overlay) !void {
    for (overlay.placements) |placement| {
        if (placement.columns == 0 or placement.rows == 0) continue;
        if (placement.text.len != 0) {
            try w.writeAll("\x1b7");
            try w.writeAll(placement.text);
            try w.writeAll("\x1b8");
            continue;
        }
        if (placement.sixel.len != 0) {
            try w.writeAll("\x1b7");
            try w.print("\x1b[{d};{d}H", .{ placement.row, placement.column });
            try w.writeAll(placement.sixel);
            try w.writeAll("\x1b8");
            continue;
        }
        if (placement.png.len == 0) continue;
        try w.writeAll("\x1b7");
        try w.print("\x1b[{d};{d}H", .{ placement.row, placement.column });
        try writeOne(w, placement);
        try w.writeAll("\x1b8");
    }
}

fn writeOne(w: *Writer, placement: Placement) !void {
    var offset: usize = 0;
    var chunk_index: usize = 0;
    while (offset < placement.png.len) : (chunk_index += 1) {
        const end = @min(placement.png.len, offset + chunk_bytes);
        const slice = placement.png[offset..end];
        const more = end < placement.png.len;
        try w.writeAll("\x1b_G");
        if (chunk_index == 0) {
            try w.print("a=T,f=100,q=2,i={d},c={d},r={d},C=1", .{
                placement.image_id,
                placement.columns,
                placement.rows,
            });
        } else {
            try w.print("i={d}", .{placement.image_id});
        }
        if (more) try w.writeAll(",m=1");
        try w.writeByte(';');
        try writeBase64(w, slice);
        try w.writeAll("\x1b\\");
        offset = end;
    }
}

/// Writes the sequence that removes every placement up to `highest_id`.
///
/// Kitty keeps an image's placement until it is told otherwise, so a frame
/// that moves or drops an image clears the old ids first, or the previous copy
/// stays on screen underneath the new one.
pub fn writeClear(w: *Writer, highest_id: u32) !void {
    var id: u32 = 1;
    while (id <= highest_id) : (id += 1) {
        try writeDelete(w, id);
    }
}

/// Writes the sequence that removes one image id and its placements.
///
/// A Sixel placement has no id: its pixels live in the cells it painted, and
/// the text frame that follows writes over them. So this is a Kitty-only verb,
/// and `overlayUsesSixel` decides whether the caller sends it at all.
pub fn writeDelete(w: *Writer, image_id: u32) !void {
    try w.print("\x1b_Ga=d,d=I,i={d},q=2\x1b\\", .{image_id});
}

/// Whether this overlay is drawn with Sixel rather than Kitty graphics.
///
/// The two protocols differ in more than the payload: Kitty keeps a placement
/// until it is deleted, and Sixel paints into cells that the next text frame
/// overwrites. A caller that clears placements before drawing must skip that
/// for Sixel, or it writes delete verbs a Sixel terminal cannot act on.
pub fn overlayUsesSixel(overlay: Overlay) bool {
    for (overlay.placements) |placement| {
        if (placement.sixel.len != 0) return true;
    }
    return false;
}

/// Whether the overlay is ordinary colored text. It has no id to delete and
/// is erased by writing over its cells, so the caller treats it like Sixel for
/// clearing purposes without sending any graphics verb.
pub fn overlayUsesText(overlay: Overlay) bool {
    for (overlay.placements) |placement| {
        if (placement.text.len != 0) return true;
    }
    return false;
}

/// Standard base64 with `=` padding, which is what the protocol expects.
fn writeBase64(w: *Writer, bytes: []const u8) !void {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    var index: usize = 0;
    while (index + 3 <= bytes.len) : (index += 3) {
        const a = bytes[index];
        const b = bytes[index + 1];
        const c = bytes[index + 2];
        try w.writeByte(alphabet[a >> 2]);
        try w.writeByte(alphabet[((a & 0x03) << 4) | (b >> 4)]);
        try w.writeByte(alphabet[((b & 0x0f) << 2) | (c >> 6)]);
        try w.writeByte(alphabet[c & 0x3f]);
    }
    const remaining = bytes.len - index;
    if (remaining == 1) {
        const a = bytes[index];
        try w.writeByte(alphabet[a >> 2]);
        try w.writeByte(alphabet[(a & 0x03) << 4]);
        try w.writeAll("==");
    } else if (remaining == 2) {
        const a = bytes[index];
        const b = bytes[index + 1];
        try w.writeByte(alphabet[a >> 2]);
        try w.writeByte(alphabet[((a & 0x03) << 4) | (b >> 4)]);
        try w.writeByte(alphabet[(b & 0x0f) << 2]);
        try w.writeByte('=');
    }
}

test "a Sixel placement is drawn as Sixel, not as Kitty bytes" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const sixel = "\x1bP0;1;0q#0;2;100;0;0!8~\x1b\\";
    try write(&out.writer, .{
        .placements = &.{.{
            .row = 5,
            .column = 3,
            .columns = 8,
            .rows = 2,
            .image_id = 7,
            .png = "",
            .sixel = sixel,
        }},
        .highest_id = 7,
    });
    const written = out.written();
    try std.testing.expect(std.mem.startsWith(u8, written, "\x1b7\x1b[5;3H"));
    try std.testing.expect(std.mem.find(u8, written, sixel) != null);
    try std.testing.expect(std.mem.find(u8, written, "\x1b_G") == null);
    try std.testing.expect(std.mem.endsWith(u8, written, "\x1b8"));
    try std.testing.expect(overlayUsesSixel(.{
        .placements = &.{.{ .row = 1, .column = 1, .columns = 1, .rows = 1, .image_id = 1, .png = "", .sixel = "x" }},
    }));
}

test "an overlay of PNG placements is not Sixel" {
    try std.testing.expect(!overlayUsesSixel(.{
        .placements = &.{.{ .row = 1, .column = 1, .columns = 1, .rows = 1, .image_id = 1, .png = "x" }},
    }));
    try std.testing.expect(!overlayUsesSixel(.{}));
}

test "a placement is bracketed and declares PNG" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try write(&out.writer, .{
        .placements = &.{.{
            .row = 3,
            .column = 1,
            .columns = 12,
            .rows = 6,
            .image_id = 4,
            .png = "\x89PNG\r\n\x1a\nbody",
        }},
        .highest_id = 4,
    });
    const written = out.written();
    try std.testing.expect(std.mem.startsWith(u8, written, "\x1b7\x1b[3;1H"));
    try std.testing.expect(std.mem.find(u8, written, "a=T,f=100,q=2,i=4,c=12,r=6,C=1;") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "\x1b8"));
}

test "a large image is chunked with m=1 and ends without it" {
    var big: [chunk_bytes + 1]u8 = undefined;
    @memset(&big, 'x');
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try write(&out.writer, .{
        .placements = &.{.{
            .row = 1,
            .column = 1,
            .columns = 48,
            .rows = 14,
            .image_id = 2,
            .png = &big,
        }},
        .highest_id = 2,
    });
    const written = out.written();
    try std.testing.expect(std.mem.find(u8, written, "a=T,f=100,q=2,i=2,c=48,r=14,C=1,m=1;") != null);
    try std.testing.expect(std.mem.find(u8, written, "i=2;") != null);
    var count: usize = 0;
    var rest = written;
    while (std.mem.find(u8, rest, "\x1b\\")) |at| {
        count += 1;
        rest = rest[at + 2 ..];
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "empty and zero-sized placements draw nothing" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try write(&out.writer, .{
        .placements = &.{
            .{ .row = 1, .column = 1, .columns = 0, .rows = 6, .image_id = 1, .png = "x" },
            .{ .row = 1, .column = 1, .columns = 12, .rows = 6, .image_id = 2, .png = "" },
        },
        .highest_id = 2,
    });
    try std.testing.expectEqualStrings("", out.written());
}

test "clearing stops at the highest id the overlay owned" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeClear(&out.writer, 2);
    const written = out.written();
    try std.testing.expect(std.mem.find(u8, written, "i=1,") != null);
    try std.testing.expect(std.mem.find(u8, written, "i=2,") != null);
    try std.testing.expect(std.mem.find(u8, written, "i=3,") == null);
}

test "the fingerprint changes with the image but not with unrelated frames" {
    const a = Overlay{
        .placements = &.{.{ .row = 1, .column = 1, .columns = 8, .rows = 4, .image_id = 1, .png = "/a.png" }},
        .highest_id = 1,
    };
    const b = Overlay{
        .placements = &.{.{ .row = 1, .column = 1, .columns = 8, .rows = 4, .image_id = 1, .png = "/b.png" }},
        .highest_id = 1,
    };
    try std.testing.expectEqual(a.fingerprint(), a.fingerprint());
    try std.testing.expect(a.fingerprint() != b.fingerprint());
}
