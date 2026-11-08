//! Encodes an image for a terminal that speaks the Kitty graphics protocol.
//!
//! Kitty draws pixels through an APC string: `ESC _ G <control> ; <payload> ESC \`.
//! The payload is base64 and a single APC string is bounded, so an image larger
//! than about 3 KiB of base64 is sent in chunks: the first chunk carries the
//! format, the size, and a transmission id, later chunks carry `m=1` and the
//! same id, and the last chunk omits `m` to end the transmission. A separate
//! placement command then draws that id at the cursor.
//!
//! Everything here writes bytes; nothing decides where the cursor is. The
//! caller owns placement, because only the frame builder knows the row.

const std = @import("std");

const Writer = std.Io.Writer;

/// ASCII bytes per chunk before base64. A multiple of three so no chunk
/// introduces base64 padding in the middle of the stream.
pub const chunk_bytes: usize = 3072;

/// What to tell the terminal about the image being sent.
pub const Placement = struct {
    /// Columns the image should occupy. The terminal keeps the aspect ratio
    /// when only one dimension is given.
    columns: u16,
    /// Rows to reserve in the text grid, so later rows do not overwrite the
    /// picture. Kitty reflows the pixels inside them.
    rows: u16,
    /// Transmission id, so a redraw replaces the previous copy instead of
    /// stacking a second one on top.
    image_id: u32,
};

/// Writes the sequence that transmits `bytes` as PNG and draws it at the cursor.
///
/// `bytes` must already be PNG. Kitty also accepts raw RGB, but PNG is what the
/// snapshot store already holds and it keeps the transfer small.
pub fn writePng(w: *Writer, bytes: []const u8, placement: Placement) !void {
    if (bytes.len == 0) return;
    var offset: usize = 0;
    const first_chunk = true;
    var chunk_index: usize = 0;
    while (offset < bytes.len) : (chunk_index += 1) {
        const end = @min(bytes.len, offset + chunk_bytes);
        const slice = bytes[offset..end];
        const more = end < bytes.len;
        try w.writeAll("\x1b_G");
        if (chunk_index == 0) {
            // `a=T` transmits and displays in one command, `f=100` is PNG, and
            // `q=2` suppresses the terminal's own reply so nothing lands in the
            // conversation.
            try w.print("a=T,f=100,q=2,i={d},c={d},r={d}", .{
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
    _ = first_chunk;
}

/// Writes the sequence that deletes `image_id`, for a redraw that no longer has
/// this image or for leaving the screen.
pub fn writeDelete(w: *Writer, image_id: u32) !void {
    // `d=I` deletes by image id, and `q=2` keeps the acknowledgement quiet.
    try w.print("\x1b_Ga=d,d=I,i={d},q=2\x1b\\", .{image_id});
}

/// Standard base64 with `=` padding, which is what the protocol expects.
pub fn writeBase64(w: *Writer, bytes: []const u8) !void {
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

/// How many base64 bytes `count` raw bytes take.
pub fn base64Length(count: usize) usize {
    return (count + 2) / 3 * 4;
}

test "base64 matches the standard alphabet and padding" {
    var buffer: [32]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try writeBase64(&w, "Man");
    try std.testing.expectEqualStrings("TWFu", w.buffered());

    w = .fixed(&buffer);
    try writeBase64(&w, "Ma");
    try std.testing.expectEqualStrings("TWE=", w.buffered());

    w = .fixed(&buffer);
    try writeBase64(&w, "M");
    try std.testing.expectEqualStrings("TQ==", w.buffered());

    w = .fixed(&buffer);
    try writeBase64(&w, "");
    try std.testing.expectEqualStrings("", w.buffered());
}

test "a small image is one APC string with the placement controls" {
    var buffer: [256]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try writePng(&w, "Man", .{ .columns = 40, .rows = 12, .image_id = 7 });
    try std.testing.expectEqualStrings(
        "\x1b_Ga=T,f=100,q=2,i=7,c=40,r=12;TWFu\x1b\\",
        w.buffered(),
    );
}

test "a large image is chunked with m=1 and ends without it" {
    // One byte past a chunk boundary, so a second chunk is required.
    var big: [chunk_bytes + 1]u8 = undefined;
    @memset(&big, 'x');
    var buffer: [16 * 1024]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try writePng(&w, big, .{ .columns = 10, .rows = 4, .image_id = 3 });
    const out = w.buffered();
    // The first chunk announces the image and says more follows.
    try std.testing.expect(std.mem.find(u8, out, "\x1b_Ga=T,f=100,q=2,i=3,c=10,r=4,m=1;") != null);
    // The second chunk continues the id and closes the transmission.
    try std.testing.expect(std.mem.find(u8, out, "\x1b_Gi=3;") != null);
    try std.testing.expect(std.mem.find(u8, out, "i=3,m=1;") != null);
    // Exactly one terminator per chunk.
    var count: usize = 0;
    var rest = out;
    while (std.mem.find(u8, rest, "\x1b\\")) |at| {
        count += 1;
        rest = rest[at + 2 ..];
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "base64Length counts padding" {
    try std.testing.expectEqual(@as(usize, 0), base64Length(0));
    try std.testing.expectEqual(@as(usize, 4), base64Length(1));
    try std.testing.expectEqual(@as(usize, 4), base64Length(3));
    try std.testing.expectEqual(@as(usize, 8), base64Length(4));
}
