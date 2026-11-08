//! Reads a bitmap off the Windows clipboard as RGBA pixels.
//!
//! A screenshot reaches the clipboard as a `CF_DIB` (or `CF_DIBV5`) memory
//! block: a `BITMAPINFOHEADER`, an optional palette and bit masks, then the
//! pixel rows in bottom-up order. The model providers take an encoded image, so
//! this module's job ends at a plain RGBA buffer that `png_downscale.encodeRgba`
//! can turn into a PNG.
//!
//! The sequence is the one every Windows program uses: open the clipboard,
//! ask which format is there, take the handle, lock it, copy the bytes, unlock,
//! close. Nothing here keeps the clipboard open longer than the copy.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const is_windows = builtin.target.os.tag == .windows;

pub const Error = error{
    /// The clipboard could not be opened: another program held it past the
    /// retry budget.
    ClipboardBusy,
    /// No bitmap is on the clipboard. Text, a file list, or nothing at all.
    NoImage,
    /// The clipboard holds a bitmap this reader cannot decode: a bit depth,
    /// compression, or color layout it does not handle.
    UnsupportedFormat,
    /// The header describes pixels that do not fit the buffer it was given.
    MalformedImage,
    OutOfMemory,
};

pub const Bitmap = struct {
    width: u32,
    height: u32,
    /// `width * height * 4` bytes in RGBA order, top row first.
    pixels: []u8,

    pub fn deinit(self: *Bitmap, alloc: Allocator) void {
        alloc.free(self.pixels);
        self.* = undefined;
    }
};

const windows = if (is_windows) struct {
    extern "user32" fn OpenClipboard(hwnd: ?*anyopaque) callconv(.winapi) i32;
    extern "user32" fn CloseClipboard() callconv(.winapi) i32;
    extern "user32" fn GetClipboardData(format: u32) callconv(.winapi) ?*anyopaque;
    extern "user32" fn IsClipboardFormatAvailable(format: u32) callconv(.winapi) i32;
    extern "user32" fn RegisterClipboardFormatW(name: [*:0]const u16) callconv(.winapi) u32;
    extern "kernel32" fn GlobalLock(mem: *anyopaque) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GlobalUnlock(mem: *anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn GlobalSize(mem: *anyopaque) callconv(.winapi) usize;
    extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

    /// A bitmap with a straight RGB color table.
    const CF_BITMAP: u32 = 2;
    /// A `BITMAPINFOHEADER` plus pixels in one block.
    const CF_DIB: u32 = 8;
    /// The same, with an explicit alpha channel.
    const CF_DIBV5: u32 = 17;

    const BI_RGB: u32 = 0;
    const BI_BITFIELDS: u32 = 3;

    const header_size_v5: u32 = 124;
    const header_size_info: u32 = 40;

    fn open(retries: u32) bool {
        var remaining = retries;
        while (remaining > 0) : (remaining -= 1) {
            if (OpenClipboard(null) != 0) return true;
            // Another program holds it. Windows clipboard ownership is short
            // lived, so a few short waits outlast a copy in progress.
            Sleep(10);
        }
        return false;
    }

    /// The clipboard's own PNG, when a program put one there. Browsers and
    /// screenshot tools often do, and it keeps the original encoding.
    fn pngBytes(alloc: Allocator) Error!?[]u8 {
        const format = RegisterClipboardFormatW(std.unicode.utf8ToUtf16LeStringLiteral("PNG"));
        if (format == 0) return null;
        if (IsClipboardFormatAvailable(format) == 0) return null;
        const handle = GetClipboardData(format) orelse return null;
        const locked = GlobalLock(handle) orelse return null;
        defer _ = GlobalUnlock(handle);
        const size = GlobalSize(handle);
        if (size == 0) return null;
        const bytes: [*]const u8 = @ptrCast(locked);
        return try alloc.dupe(u8, bytes[0..size]);
    }

    /// The DIB block, whichever of the two formats the source used.
    fn dibBytes(alloc: Allocator) Error!?[]u8 {
        const format = if (IsClipboardFormatAvailable(CF_DIBV5) != 0)
            CF_DIBV5
        else if (IsClipboardFormatAvailable(CF_DIB) != 0)
            CF_DIB
        else
            return null;
        const handle = GetClipboardData(format) orelse return null;
        const locked = GlobalLock(handle) orelse return null;
        defer _ = GlobalUnlock(handle);
        const size = GlobalSize(handle);
        if (size == 0) return null;
        const bytes: [*]const u8 = @ptrCast(locked);
        return try alloc.dupe(u8, bytes[0..size]);
    }
} else struct {};

/// Reads the clipboard bitmap as RGBA pixels.
///
/// Returns `error.NoImage` when the clipboard holds no bitmap, which is the
/// ordinary case for a text paste: the caller falls back to pasting text.
pub fn readClipboardBitmap(alloc: Allocator) Error!Bitmap {
    if (comptime !is_windows) return error.NoImage;

    if (!windows.open(20)) return error.ClipboardBusy;
    defer _ = windows.CloseClipboard();

    if (try windows.dibBytes(alloc)) |dib| {
        defer alloc.free(dib);
        return decodeDib(alloc, dib);
    }
    return error.NoImage;
}

/// The clipboard's PNG, when a program put one there instead of a DIB.
///
/// Callers try this first because it preserves the source encoding and avoids
/// a decode and re-encode.
pub fn readClipboardPng(alloc: Allocator) Error!?[]u8 {
    if (comptime !is_windows) return null;
    if (!windows.open(20)) return error.ClipboardBusy;
    defer _ = windows.CloseClipboard();
    return try windows.pngBytes(alloc);
}

const DibHeader = struct {
    header_size: u32,
    width: i32,
    /// Signed: a negative height means the rows are already top-down.
    height: i32,
    planes: u16,
    bit_count: u16,
    compression: u32,
    colors_used: u32,
};

fn readU32(bytes: []const u8, at: usize) ?u32 {
    if (at + 4 > bytes.len) return null;
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

fn readI32(bytes: []const u8, at: usize) ?i32 {
    if (at + 4 > bytes.len) return null;
    return std.mem.readInt(i32, bytes[at..][0..4], .little);
}

fn readU16(bytes: []const u8, at: usize) ?u16 {
    if (at + 2 > bytes.len) return null;
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}

fn parseHeader(bytes: []const u8) ?DibHeader {
    return .{
        .header_size = readU32(bytes, 0) orelse return null,
        .width = readI32(bytes, 4) orelse return null,
        .height = readI32(bytes, 8) orelse return null,
        .planes = readU16(bytes, 12) orelse return null,
        .bit_count = readU16(bytes, 14) orelse return null,
        .compression = readU32(bytes, 16) orelse return null,
        .colors_used = readU32(bytes, 32) orelse return null,
    };
}

/// Converts a `CF_DIB` block to RGBA.
///
/// Handles what a clipboard actually carries: 32-bit with or without alpha,
/// 24-bit, and 8-bit palette entries. Top-down and bottom-up row orders both
/// appear depending on which program filled the clipboard.
pub fn decodeDib(alloc: Allocator, bytes: []const u8) Error!Bitmap {
    const header = parseHeader(bytes) orelse return error.MalformedImage;
    if (header.planes != 1) return error.UnsupportedFormat;
    if (header.width <= 0) return error.MalformedImage;
    if (header.height == 0) return error.MalformedImage;

    const width: u32 = @intCast(header.width);
    const top_down = header.height < 0;
    const height: u32 = @intCast(if (top_down) -header.height else header.height);

    if (header.compression != windows.BI_RGB and header.compression != windows.BI_BITFIELDS) {
        return error.UnsupportedFormat;
    }
    if (header.bit_count != 32 and header.bit_count != 24 and header.bit_count != 8) {
        return error.UnsupportedFormat;
    }

    // The palette sits between the header and the pixels for 8-bit images.
    var palette_at: usize = header.header_size;
    var palette_entries: usize = 0;
    if (header.bit_count == 8) {
        palette_entries = if (header.colors_used != 0) header.colors_used else 256;
        if (palette_entries > 256) return error.UnsupportedFormat;
        palette_at += palette_entries * 4;
    } else if (header.compression == windows.BI_BITFIELDS) {
        // Three or four DWORD masks follow the header.
        palette_at += if (header.header_size >= windows.header_size_v5) 0 else 12;
    }

    const row_in: usize = switch (header.bit_count) {
        32 => @as(usize, width) * 4,
        24 => (@as(usize, width) * 3 + 3) & ~@as(usize, 3),
        8 => (@as(usize, width) + 3) & ~@as(usize, 3),
        else => unreachable,
    };
    const pixels_at = palette_at;
    const needed = std.math.mul(usize, row_in, height) catch return error.MalformedImage;
    if (pixels_at + needed > bytes.len) return error.MalformedImage;

    const row_out = std.math.mul(usize, width, 4) catch return error.MalformedImage;
    const total = std.math.mul(usize, row_out, height) catch return error.MalformedImage;
    const rgba = try alloc.alloc(u8, total);
    errdefer alloc.free(rgba);

    const has_alpha = header.bit_count == 32;
    for (0..height) |row| {
        // A bottom-up DIB stores its last row first.
        const src_row = if (top_down) row else height - 1 - row;
        const src = bytes[pixels_at + src_row * row_in ..][0..row_in];
        const dst = rgba[row * row_out ..][0..row_out];
        switch (header.bit_count) {
            32 => for (0..width) |x| {
                const at = x * 4;
                const b = src[at];
                const g = src[at + 1];
                const r = src[at + 2];
                const a = src[at + 3];
                dst[at] = r;
                dst[at + 1] = g;
                dst[at + 2] = b;
                // A 32-bit DIB with every alpha byte zero came from a program
                // that never filled the channel, so the pixels are opaque.
                dst[at + 3] = a;
            },
            24 => for (0..width) |x| {
                const at = x * 4;
                const src_at = x * 3;
                dst[at] = src[src_at + 2];
                dst[at + 1] = src[src_at + 1];
                dst[at + 2] = src[src_at];
                dst[at + 3] = 255;
            },
            8 => for (0..width) |x| {
                const at = x * 4;
                const index = src[x];
                // A palette entry is BGRA in the DIB's own table.
                const entry_at = header.header_size + @as(usize, index) * 4;
                if (entry_at + 4 > bytes.len) return error.MalformedImage;
                dst[at] = bytes[entry_at + 2];
                dst[at + 1] = bytes[entry_at + 1];
                dst[at + 2] = bytes[entry_at];
                dst[at + 3] = 255;
            },
            else => unreachable,
        }
    }

    // A 32-bit DIB whose alpha channel is entirely zero carries no
    // transparency; treat it as opaque so a screenshot is not fully invisible.
    if (has_alpha) {
        var any_alpha = false;
        for (rgba, 0..) |byte, i| {
            if (i % 4 == 3 and byte != 0) {
                any_alpha = true;
                break;
            }
        }
        if (!any_alpha) {
            for (rgba, 0..) |*byte, i| {
                if (i % 4 == 3) byte.* = 255;
            }
        }
    }

    return .{ .width = width, .height = height, .pixels = rgba };
}

test "a 32-bit top-down DIB converts to RGBA in row order" {
    // One 2x2 image, already top-down because the height is negative.
    var dib: [40 + 16]u8 = @splat(0);
    std.mem.writeInt(u32, dib[0..4], 40, .little);
    std.mem.writeInt(i32, dib[4..8], 2, .little);
    std.mem.writeInt(i32, dib[8..12], -2, .little);
    std.mem.writeInt(u16, dib[12..14], 1, .little);
    std.mem.writeInt(u16, dib[14..16], 32, .little);
    // Two rows of two BGRA pixels: red, green, then blue, white.
    const rows = [_][8]u8{
        .{ 0, 0, 255, 255, 0, 255, 0, 255 },
        .{ 255, 0, 0, 255, 255, 255, 255, 255 },
    };
    @memcpy(dib[40..][0..16], std.mem.asBytes(&rows));

    var bitmap = try decodeDib(std.testing.allocator, &dib);
    defer bitmap.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 2), bitmap.width);
    try std.testing.expectEqual(@as(u32, 2), bitmap.height);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 },
        bitmap.pixels,
    );
}

test "a bottom-up DIB is flipped so the first row is the top" {
    var dib: [40 + 16]u8 = @splat(0);
    std.mem.writeInt(u32, dib[0..4], 40, .little);
    std.mem.writeInt(i32, dib[4..8], 2, .little);
    std.mem.writeInt(i32, dib[8..12], 2, .little);
    std.mem.writeInt(u16, dib[12..14], 1, .little);
    std.mem.writeInt(u16, dib[14..16], 32, .little);
    // A positive height stores the bottom row first.
    const rows = [_][8]u8{
        .{ 255, 0, 0, 255, 255, 255, 255, 255 },
        .{ 0, 0, 255, 255, 0, 255, 0, 255 },
    };
    @memcpy(dib[40..][0..16], std.mem.asBytes(&rows));

    var bitmap = try decodeDib(std.testing.allocator, &dib);
    defer bitmap.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(
        u8,
        &.{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 },
        bitmap.pixels,
    );
}

test "a 32-bit DIB with no alpha data is treated as opaque" {
    var dib: [40 + 8]u8 = @splat(0);
    std.mem.writeInt(u32, dib[0..4], 40, .little);
    std.mem.writeInt(i32, dib[4..8], 2, .little);
    std.mem.writeInt(i32, dib[8..12], -1, .little);
    std.mem.writeInt(u16, dib[12..14], 1, .little);
    std.mem.writeInt(u16, dib[14..16], 32, .little);
    // Two BGRA pixels with the alpha byte left at zero.
    const row = [_]u8{ 10, 20, 30, 0, 40, 50, 60, 0 };
    @memcpy(dib[40..][0..8], &row);

    var bitmap = try decodeDib(std.testing.allocator, &dib);
    defer bitmap.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &.{ 30, 20, 10, 255, 60, 50, 40, 255 }, bitmap.pixels);
}

test "a 24-bit DIB pads its rows to four bytes" {
    // Two pixels per row is six bytes, padded to eight.
    var dib: [40 + 16]u8 = @splat(0);
    std.mem.writeInt(u32, dib[0..4], 40, .little);
    std.mem.writeInt(i32, dib[4..8], 2, .little);
    std.mem.writeInt(i32, dib[8..12], -2, .little);
    std.mem.writeInt(u16, dib[12..14], 1, .little);
    std.mem.writeInt(u16, dib[14..16], 24, .little);
    const rows = [_][8]u8{
        .{ 0, 0, 255, 0, 255, 0, 0, 0 },
        .{ 255, 0, 0, 255, 255, 255, 0, 0 },
    };
    @memcpy(dib[40..][0..16], std.mem.asBytes(&rows));

    var bitmap = try decodeDib(std.testing.allocator, &dib);
    defer bitmap.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(
        u8,
        &.{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 },
        bitmap.pixels,
    );
}

test "a header that promises more pixels than the block holds is refused" {
    var dib: [40]u8 = @splat(0);
    std.mem.writeInt(u32, dib[0..4], 40, .little);
    std.mem.writeInt(i32, dib[4..8], 100, .little);
    std.mem.writeInt(i32, dib[8..12], 100, .little);
    std.mem.writeInt(u16, dib[12..14], 1, .little);
    std.mem.writeInt(u16, dib[14..16], 32, .little);

    try std.testing.expectError(error.MalformedImage, decodeDib(std.testing.allocator, &dib));
}
