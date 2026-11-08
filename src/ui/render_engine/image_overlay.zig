//! Images drawn on top of a finished frame.
//!
//! A text frame is a grid of cells: every byte the frame carries is parsed,
//! measured, and placed into a column. An inline image is not that. Its escape
//! string is an APC payload, it occupies no column, and the terminal paints it
//! over the cells rather than inside them. So an image travels beside the text,
//! not through it.
//!
//! The Kitty graphics protocol has two ways to name an image. `t=d` sends the
//! encoded bytes themselves and needs `f=100` (PNG) to be declared up front:
//! a pasted JPEG, WebP, or GIF would be read as PNG and silently dropped.
//! `t=f` sends the *path* instead, and the terminal opens the file and detects
//! the format itself. That is the right shape here: fx already has the file on
//! disk, the model wants those bytes unchanged, and a preview should not hold a
//! megabyte of pixels in memory or re-encode anything. It also keeps the escape
//! sequence short enough that it can never overflow a frame's buffer.
//!
//! A caller with only in-memory bytes (a libfx kernel session) can still use
//! the bytes form; those bytes must already be PNG.

const std = @import("std");

const Writer = std.Io.Writer;

/// Where one image's pixels come from.
pub const Source = union(enum) {
    /// Absolute path. The terminal opens it and detects the format.
    file: []const u8,
    /// PNG bytes the caller already owns.
    png_bytes: []const u8,
};

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
    source: Source,
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

    /// A fingerprint of what is on screen. It changes when the source, the id,
    /// or the cells change, and stays the same across frames that only redraw
    /// text, so the pixels are sent once rather than on every keystroke.
    pub fn fingerprint(self: Overlay) u64 {
        var hash = std.hash.Wyhash.init(0);
        hash.update(std.mem.asBytes(&self.highest_id));
        for (self.placements) |placement| {
            hash.update(std.mem.asBytes(&placement.row));
            hash.update(std.mem.asBytes(&placement.column));
            hash.update(std.mem.asBytes(&placement.columns));
            hash.update(std.mem.asBytes(&placement.rows));
            hash.update(std.mem.asBytes(&placement.image_id));
            const kind: u8 = switch (placement.source) {
                .file => 0,
                .png_bytes => 1,
            };
            hash.update(std.mem.asBytes(&kind));
            const text = switch (placement.source) {
                .file => |path| path,
                .png_bytes => |bytes| bytes[0..@min(bytes.len, 64)],
            };
            hash.update(text);
        }
        return hash.final();
    }
};

/// Writes the sequence that draws every placement in `overlay`.
///
/// Each image is bracketed in `SavePosition`/`RestorePosition` and placed at an
/// absolute cell, so the frame's own cursor bookkeeping is untouched. `C=1`
/// tells the terminal not to move its raster cursor either.
pub fn write(w: *Writer, overlay: Overlay) !void {
    for (overlay.placements) |placement| {
        if (placement.columns == 0 or placement.rows == 0) continue;
        if (sourceIsEmpty(placement.source)) continue;
        try w.writeAll("\x1b7");
        try w.print("\x1b[{d};{d}H", .{ placement.row, placement.column });
        try writeOne(w, placement);
        try w.writeAll("\x1b8");
    }
}

fn sourceIsEmpty(source: Source) bool {
    return switch (source) {
        .file => |path| path.len == 0,
        .png_bytes => |bytes| bytes.len == 0,
    };
}

fn writeOne(w: *Writer, placement: Placement) !void {
    // `q=2` silences the acknowledgement so nothing lands in the conversation,
    // and `C=1` keeps the terminal's cursor where it was.
    try w.print("\x1b_Ga=T,q=2,i={d},c={d},r={d},C=1", .{
        placement.image_id,
        placement.columns,
        placement.rows,
    });
    switch (placement.source) {
        .file => |path| {
            // The terminal reads the file itself, so it can detect JPEG, PNG,
            // WebP, or GIF without fx decoding or re-encoding anything.
            try w.writeAll(",t=f;");
            try writeBase64(w, path);
        },
        .png_bytes => |bytes| {
            try w.writeAll(",t=d,f=100;");
            try writeBase64(w, bytes);
        },
    }
    try w.writeAll("\x1b\\");
}

/// Writes the sequence that removes every image the overlay used to draw.
pub fn writeClear(w: *Writer, highest_id: u32) !void {
    var id: u32 = 1;
    while (id <= highest_id) : (id += 1) {
        try w.print("\x1b_Ga=d,d=I,i={d},q=2\x1b\\", .{id});
    }
}

/// Whether this terminal can draw an overlay at all.
///
/// The caller owns protocol detection and passes the answer in: this module
/// only encodes bytes, and a module that encodes bytes should compile on its
/// own without dragging the terminal environment behind it.
pub fn supported(draws_images: bool) bool {
    return draws_images;
}

/// Standard base64, which is what the protocol expects for both paths and
/// bytes.
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

test "a file placement sends a path and lets the terminal detect the format" {
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
            .source = .{ .file = "C:\\shots\\a.jpg" },
        }},
        .highest_id = 4,
    });
    const written = out.written();
    try std.testing.expect(std.mem.startsWith(u8, written, "\x1b7\x1b[3;1H"));
    try std.testing.expect(std.mem.find(u8, written, "a=T,q=2,i=4,c=12,r=6,C=1,t=f;") != null);
    // The payload is the base64 path, not the file's bytes.
    try std.testing.expect(std.mem.find(u8, written, "Qzpcc2hvdHNcYS5qcGc=") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "\x1b8"));
}

test "a PNG byte placement declares its format" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try write(&out.writer, .{
        .placements = &.{.{
            .row = 1,
            .column = 1,
            .columns = 8,
            .rows = 4,
            .image_id = 1,
            .source = .{ .png_bytes = "\x89PNG\r\n\x1a\nbody" },
        }},
        .highest_id = 1,
    });
    try std.testing.expect(std.mem.find(u8, out.written(), "t=d,f=100;") != null);
}

test "empty and zero-sized placements draw nothing" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try write(&out.writer, .{
        .placements = &.{
            .{ .row = 1, .column = 1, .columns = 0, .rows = 6, .image_id = 1, .source = .{ .file = "a" } },
            .{ .row = 1, .column = 1, .columns = 12, .rows = 6, .image_id = 2, .source = .{ .file = "" } },
        },
        .highest_id = 2,
    });
    try std.testing.expectEqualStrings("", out.written());
}

test "the fingerprint changes with the source but not with unrelated frames" {
    const a = Overlay{
        .placements = &.{.{ .row = 1, .column = 1, .columns = 8, .rows = 4, .image_id = 1, .source = .{ .file = "/a.png" } }},
        .highest_id = 1,
    };
    const b = Overlay{
        .placements = &.{.{ .row = 1, .column = 1, .columns = 8, .rows = 4, .image_id = 1, .source = .{ .file = "/b.png" } }},
        .highest_id = 1,
    };
    try std.testing.expectEqual(a.fingerprint(), a.fingerprint());
    try std.testing.expect(a.fingerprint() != b.fingerprint());
}
