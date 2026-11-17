//! Decodes an image file into a small PNG preview with the system's own codec.
//!
//! A pasted screenshot is usually a JPEG, and the Kitty graphics protocol's
//! byte form declares its format up front: `f=100` means PNG, and JPEG bytes
//! sent as PNG are silently dropped by the terminal. So the preview needs real
//! pixels before it can be sent.
//!
//! Windows ships GDI+ in every install since XP, and its flat C API decodes
//! JPEG, PNG, GIF, BMP, and TIFF without a COM apartment or a third-party
//! dependency. This module loads the file, scales it into the preview's cell
//! box with high-quality bicubic filtering on a transparent canvas, and hands
//! back RGBA rows that `png_downscale.encodeRgba` turns into a PNG.
//!
//! The scaled-down result keeps the transfer small: a preview is a few hundred
//! cells, so a megabyte photograph becomes tens of kilobytes of PNG. Other
//! platforms get their own decoder in this same shape; until one exists the
//! caller falls back to passing PNG files through and skipping the rest.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const is_windows = builtin.target.os.tag == .windows;

pub const Error = error{
    /// GDI+ failed to start or to decode the file.
    DecodeFailed,
    /// The decoded image had no pixels to show.
    EmptyImage,
    OutOfMemory,
};

/// The preview raster, sized for its cell box.
///
/// A terminal cell is roughly twice as tall as it is wide, so the raster that
/// fills `columns` x `rows` cells is about `columns * 10` by `rows * 20`
/// pixels. Sending at display size keeps the PNG small without visible loss.
pub const cell_pixel_width: u32 = 10;
pub const cell_pixel_height: u32 = 20;

/// Decodes `path` and returns PNG bytes fitted into the cell box.
///
/// The result preserves the image's aspect ratio inside the box, letterboxed on
/// transparency, so the terminal's own scaling does not distort it. The caller
/// owns the returned bytes.
pub fn decodeToPreviewPng(
    alloc: Allocator,
    path: []const u8,
    box_columns: u32,
    box_rows: u32,
) Error![]u8 {
    if (comptime !is_windows) return error.DecodeFailed;
    return decodeToPreviewPngWindows(alloc, path, box_columns, box_rows);
}

fn decodeToPreviewPngWindows(
    alloc: Allocator,
    path: []const u8,
    box_columns: u32,
    box_rows: u32,
) Error![]u8 {
    if (box_columns == 0 or box_rows == 0) return error.EmptyImage;

    ensureStarted() catch return error.DecodeFailed;

    const wide_path = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return error.OutOfMemory;
    defer alloc.free(wide_path);

    var image: ?*anyopaque = null;
    if (gdip.load_image_from_file.?(wide_path.ptr, &image) != status_ok) return error.DecodeFailed;
    defer _ = gdip.dispose_image.?(image);

    var source_width: c_uint = 0;
    var source_height: c_uint = 0;
    if (gdip.get_image_width.?(image, &source_width) != status_ok) return error.DecodeFailed;
    if (gdip.get_image_height.?(image, &source_height) != status_ok) return error.DecodeFailed;
    if (source_width == 0 or source_height == 0) return error.EmptyImage;

    const raster_width: u32 = box_columns * cell_pixel_width;
    const raster_height: u32 = box_rows * cell_pixel_height;

    // Aspect-fit the source inside the raster, centered.
    const fitted = fitInside(
        @floatFromInt(source_width),
        @floatFromInt(source_height),
        @floatFromInt(raster_width),
        @floatFromInt(raster_height),
    );
    const draw_x: i32 = @intFromFloat(fitted.x);
    const draw_y: i32 = @intFromFloat(fitted.y);
    const draw_w: i32 = @max(@as(i32, 1), @as(i32, @intFromFloat(fitted.width)));
    const draw_h: i32 = @max(@as(i32, 1), @as(i32, @intFromFloat(fitted.height)));

    var canvas: ?*anyopaque = null;
    const create_status = gdip.create_bitmap_from_scan0.?(
        @intCast(raster_width),
        @intCast(raster_height),
        0,
        gdip.pixel_format_32bpp_argb,
        null,
        &canvas,
    );
    if (create_status != status_ok) {
        if (comptime builtin.mode == .debug) {
            std.debug.print("gdiplus create status={d}\n", .{create_status});
        }
        return error.DecodeFailed;
    }
    defer _ = gdip.dispose_image.?(canvas);

    var graphics: ?*anyopaque = null;
    if (gdip.get_image_graphics_context.?(canvas, &graphics) != status_ok) return error.DecodeFailed;
    defer _ = gdip.delete_graphics.?(graphics);

    // Fully transparent, so the letterbox shows the terminal's background.
    if (gdip.clear.?(graphics, 0x00000000) != status_ok) return error.DecodeFailed;
    if (gdip.set_interpolation_mode.?(graphics, gdip.interpolation_high_quality_bicubic) != status_ok) return error.DecodeFailed;
    if (gdip.draw_image_rect_rect_i.?(
        graphics,
        image,
        draw_x,
        draw_y,
        draw_w,
        draw_h,
        0,
        0,
        @intCast(source_width),
        @intCast(source_height),
        gdip.unit_pixel,
        null,
        null,
        null,
    ) != status_ok) return error.DecodeFailed;

    const full_rect = gdip.Rect{
        .x = 0,
        .y = 0,
        .width = @intCast(raster_width),
        .height = @intCast(raster_height),
    };
    var locked: gdip.BitmapData = undefined;
    if (gdip.bitmap_lock_bits.?(
        canvas,
        &full_rect,
        gdip.image_lock_mode_read,
        gdip.pixel_format_32bpp_argb,
        &locked,
    ) != status_ok) return error.DecodeFailed;
    defer _ = gdip.bitmap_unlock_bits.?(canvas, &locked);

    const row_bytes: usize = @intCast(raster_width * 4);
    const rgba = try alloc.alloc(u8, row_bytes * raster_height);
    defer alloc.free(rgba);

    // GDI+'s 32bpp ARGB is laid out little-endian as B, G, R, A. The PNG
    // encoder and the clipboard decoder both take RGBA, so the channels are
    // reordered while the rows are copied out of the locked stride.
    const stride: usize = @intCast(locked.stride);
    var row: usize = 0;
    while (row < raster_height) : (row += 1) {
        const src = locked.scan0.?[row * stride ..][0..row_bytes];
        const dst = rgba[row * row_bytes ..][0..row_bytes];
        var x: usize = 0;
        while (x < raster_width) : (x += 1) {
            dst[x * 4 + 0] = src[x * 4 + 2];
            dst[x * 4 + 1] = src[x * 4 + 1];
            dst[x * 4 + 2] = src[x * 4 + 0];
            dst[x * 4 + 3] = src[x * 4 + 3];
        }
    }

    const png_downscale = @import("png_downscale.zig");
    return png_downscale.encodeRgba(alloc, raster_width, raster_height, rgba) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.DecodeFailed,
    };
}

fn fitInside(source_w: f64, source_h: f64, box_w: f64, box_h: f64) struct { x: f64, y: f64, width: f64, height: f64 } {
    const scale = @min(box_w / source_w, box_h / source_h);
    const width = @max(source_w * scale, 1.0);
    const height = @max(source_h * scale, 1.0);
    return .{
        .x = (box_w - width) / 2,
        .y = (box_h - height) / 2,
        .width = width,
        .height = height,
    };
}

const status_ok: i32 = 0;

var startup_token: usize = 0;
var started: bool = false;

fn ensureStarted() !void {
    if (started) return;
    if (!gdip.ensure()) return error.DecodeFailed;
    const input = gdip.StartupInput{};
    if (gdip.startup.?(&startup_token, &input, null) != status_ok) return error.DecodeFailed;
    started = true;
}

const gdip = if (!is_windows) struct {} else struct {
    const GpUnit = i32;
    const unit_pixel: GpUnit = 2;
    const pixel_format_32bpp_argb: i32 = 0x0026200A;
    const image_lock_mode_read: u32 = 1;
    const interpolation_high_quality_bicubic: i32 = 7;

    pub const StartupInput = extern struct {
        version: u32 = 1,
        debug_event_callback: ?*const fn (?*anyopaque, i32, i32) callconv(.winapi) void = null,
        suppress_background_thread: i32 = 0,
        suppress_external_codecs: i32 = 0,
    };

    pub const Rect = extern struct {
        x: c_int,
        y: c_int,
        width: c_int,
        height: c_int,
    };

    pub const BitmapData = extern struct {
        width: c_uint,
        height: c_uint,
        stride: c_int,
        pixel_format: i32,
        scan0: ?[*]u8,
        reserved: ?*anyopaque,
    };

    pub var startup: ?*const fn (*usize, *const StartupInput, ?*anyopaque) callconv(.winapi) i32 = null;
    pub var load_image_from_file: ?*const fn ([*:0]const u16, *?*anyopaque) callconv(.winapi) i32 = null;
    pub var dispose_image: ?*const fn (?*anyopaque) callconv(.winapi) i32 = null;
    pub var get_image_width: ?*const fn (?*anyopaque, *c_uint) callconv(.winapi) i32 = null;
    pub var get_image_height: ?*const fn (?*anyopaque, *c_uint) callconv(.winapi) i32 = null;
    pub var create_bitmap_from_scan0: ?*const fn (c_int, c_int, c_int, i32, ?[*]u8, *?*anyopaque) callconv(.winapi) i32 = null;
    pub var get_image_graphics_context: ?*const fn (?*anyopaque, *?*anyopaque) callconv(.winapi) i32 = null;
    pub var set_interpolation_mode: ?*const fn (?*anyopaque, i32) callconv(.winapi) i32 = null;
    pub var clear: ?*const fn (?*anyopaque, u32) callconv(.winapi) i32 = null;
    pub var draw_image_rect_rect_i: ?*const fn (?*anyopaque, ?*anyopaque, c_int, c_int, c_int, c_int, c_int, c_int, c_int, c_int, GpUnit, ?*anyopaque, ?*const fn (?*anyopaque) callconv(.winapi) c_int, ?*anyopaque) callconv(.winapi) i32 = null;
    pub var delete_graphics: ?*const fn (?*anyopaque) callconv(.winapi) i32 = null;
    pub var bitmap_lock_bits: ?*const fn (?*anyopaque, *const Rect, u32, i32, *BitmapData) callconv(.winapi) i32 = null;
    pub var bitmap_unlock_bits: ?*const fn (?*anyopaque, *BitmapData) callconv(.winapi) i32 = null;

    pub var loaded: bool = false;

    extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) ?*anyopaque;

    /// Resolves every flat-API entry point out of the system DLL.
    ///
    /// The import library for GDI+ is not part of the toolchain's default set,
    /// so the DLL is loaded by name instead: it ships in every Windows install,
    /// and a missing entry point simply means no preview rather than a build
    /// that cannot link.
    pub fn ensure() bool {
        if (loaded) return true;
        const handle = LoadLibraryA("gdiplus.dll") orelse return false;
        startup = @ptrCast(@alignCast(GetProcAddress(handle, "GdiplusStartup")));
        load_image_from_file = @ptrCast(@alignCast(GetProcAddress(handle, "GdipLoadImageFromFile")));
        dispose_image = @ptrCast(@alignCast(GetProcAddress(handle, "GdipDisposeImage")));
        get_image_width = @ptrCast(@alignCast(GetProcAddress(handle, "GdipGetImageWidth")));
        get_image_height = @ptrCast(@alignCast(GetProcAddress(handle, "GdipGetImageHeight")));
        create_bitmap_from_scan0 = @ptrCast(@alignCast(GetProcAddress(handle, "GdipCreateBitmapFromScan0")));
        get_image_graphics_context = @ptrCast(@alignCast(GetProcAddress(handle, "GdipGetImageGraphicsContext")));
        set_interpolation_mode = @ptrCast(@alignCast(GetProcAddress(handle, "GdipSetInterpolationMode")));
        clear = @ptrCast(@alignCast(GetProcAddress(handle, "GdipGraphicsClear")));
        draw_image_rect_rect_i = @ptrCast(@alignCast(GetProcAddress(handle, "GdipDrawImageRectRectI")));
        delete_graphics = @ptrCast(@alignCast(GetProcAddress(handle, "GdipDeleteGraphics")));
        bitmap_lock_bits = @ptrCast(@alignCast(GetProcAddress(handle, "GdipBitmapLockBits")));
        bitmap_unlock_bits = @ptrCast(@alignCast(GetProcAddress(handle, "GdipBitmapUnlockBits")));
        loaded = startup != null and load_image_from_file != null and dispose_image != null and
            get_image_width != null and get_image_height != null and create_bitmap_from_scan0 != null and
            get_image_graphics_context != null and set_interpolation_mode != null and clear != null and
            draw_image_rect_rect_i != null and delete_graphics != null and bitmap_lock_bits != null and
            bitmap_unlock_bits != null;
        return loaded;
    }
};

test "fitInside centers a wide source in a tall box" {
    const fit = fitInside(400, 200, 480, 280);
    // A 2:1 source in a 12:7 box fills the width and letterboxes vertically.
    try std.testing.expectEqual(@as(f64, 480), fit.width);
    try std.testing.expectEqual(@as(f64, 240), fit.height);
    try std.testing.expectEqual(@as(f64, 0), fit.x);
    try std.testing.expectEqual(@as(f64, 20), fit.y);
}
