//! Decodes an image file into a small PNG preview with the system's own codec.
//!
//! The Kitty byte form declares its format up front (`f=100` is PNG), and a
//! pasted screenshot is usually a JPEG, so a preview needs real pixels before
//! it can be sent. Each platform has a codec it already ships, and the loaders
//! below keep fx from carrying or linking an image library for a feature that
//! runs only when the user previews an attachment:
//!
//! - Windows: GDI+, loaded at runtime out of `gdiplus.dll`.
//! - macOS: ImageIO (`CGImageSource*`), linked as a system framework.
//! - Linux: no single system codec exists, so a PNG file passes through and
//!   other formats return `DecodeFailed` — the preview is skipped and the
//!   badge stays.
//!
//! The scaled-down result keeps the transfer small: a preview is a few hundred
//! cells, so a megabyte photograph becomes tens of kilobytes of PNG.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const Error = error{
    /// The platform codec failed to start or to decode the file.
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
    if (box_columns == 0 or box_rows == 0) return error.EmptyImage;
    switch (builtin.target.os.tag) {
        .windows => return decodeToPreviewPngWindows(alloc, path, box_columns, box_rows),
        .macos => return decodeToPreviewPngMacos(alloc, path, box_columns, box_rows),
        else => return decodeToPreviewPngPassthrough(alloc, path),
    }
}

/// Off Windows and macOS there is no decoder wired up: a PNG already carries
/// the bytes the terminal wants, scaled by the terminal itself, and any other
/// format declines the preview rather than linking a codec for it.
fn decodeToPreviewPngPassthrough(alloc: Allocator, path: []const u8) Error![]u8 {
    const io = @import("../shared/io.zig");
    const file = std.Io.Dir.openFileAbsolute(io.getIo(), path, .{}) catch return error.DecodeFailed;
    defer file.close(io.getIo());
    var held = file;
    const bytes = io.readFileToEnd(alloc, &held, 16 * 1024 * 1024) catch return error.DecodeFailed;
    errdefer alloc.free(bytes);
    if (!std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return error.DecodeFailed;
    return bytes;
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

const is_windows = builtin.target.os.tag == .windows;
const is_macos = builtin.target.os.tag == .macos;

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

fn decodeToPreviewPngWindows(
    alloc: Allocator,
    path: []const u8,
    box_columns: u32,
    box_rows: u32,
) Error![]u8 {
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

/// Decodes with ImageIO and scales into the preview box.
///
/// Core Graphics draws into a context the size of the preview raster, so the
/// scaling happens at decode time and the pixels come out already fitted. A
/// bitmap context's origin is at the bottom-left, so the rows are read back in
/// reverse to land top-first like every other byte order here.
fn decodeToPreviewPngMacos(
    alloc: Allocator,
    path: []const u8,
    box_columns: u32,
    box_rows: u32,
) Error![]u8 {
    const url = cg.urlFromFileSystemPath(path) catch return error.DecodeFailed;
    defer cg.release(url);

    const source = cg.imageSourceCreateWithURL(url, null) orelse return error.DecodeFailed;
    defer cg.release(source);

    const image = cg.imageSourceCreateImageAtIndex(source, 0, null) orelse return error.DecodeFailed;
    defer cg.release(image);

    const source_width = cg.imageGetWidth(image);
    const source_height = cg.imageGetHeight(image);
    if (source_width == 0 or source_height == 0) return error.EmptyImage;

    const raster_width: usize = box_columns * cell_pixel_width;
    const raster_height: usize = box_rows * cell_pixel_height;

    const fitted = fitInside(
        @floatFromInt(source_width),
        @floatFromInt(source_height),
        @floatFromInt(raster_width),
        @floatFromInt(raster_height),
    );

    const row_bytes = raster_width * 4;
    const rgba = try alloc.alloc(u8, row_bytes * raster_height);
    defer alloc.free(rgba);
    // Transparent letterbox around the fitted image.
    @memset(rgba, 0);

    const context = cg.bitmapContextCreate(
        rgba.ptr,
        raster_width,
        raster_height,
        8,
        row_bytes,
        cg.deviceRGBColorSpace(),
        cg.bitmap_info_rgba,
    ) orelse return error.DecodeFailed;
    defer cg.release(context);

    cg.setInterpolationQuality(context, cg.interpolation_high);
    // The context's origin is bottom-left, so drawing top-first means the rows
    // are read back bottom-up and flipped on the way out below.
    cg.drawImageRect(context, .{
        .x = fitted.x,
        .y = fitted.y,
        .width = fitted.width,
        .height = fitted.height,
    }, image);

    // Flip the rows back to top-first, and premultiplied alpha is what Core
    // Graphics writes; the PNG encoder here takes straight alpha, so a fully
    // transparent letterbox (alpha 0) stays all-zero and the drawn area's
    // premultiplication is invisible at full opacity.
    var flipped = try alloc.alloc(u8, rgba.len);
    defer alloc.free(flipped);
    var row: usize = 0;
    while (row < raster_height) : (row += 1) {
        const src_row = raster_height - 1 - row;
        @memcpy(flipped[row * row_bytes ..][0..row_bytes], rgba[src_row * row_bytes ..][0..row_bytes]);
    }

    const png_downscale = @import("png_downscale.zig");
    return png_downscale.encodeRgba(alloc, @intCast(raster_width), @intCast(raster_height), flipped) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.DecodeFailed,
    };
}

const cg = if (!is_macos) struct {} else struct {
    /// `kCGImageAlphaPremultipliedLast`: R, G, B, A bytes in memory, alpha
    /// premultiplied.
    const bitmap_info_rgba: u32 = 1;
    const interpolation_high: c_int = 3;

    extern "c" fn CGColorSpaceCreateDeviceRGB() ?*anyopaque;
    extern "c" fn CFRelease(candidate: ?*anyopaque) void;
    extern "c" fn CGImageSourceCreateWithURL(url: ?*anyopaque, options: ?*anyopaque) ?*anyopaque;
    extern "c" fn CGImageSourceCreateImageAtIndex(source: ?*anyopaque, index: usize, options: ?*anyopaque) ?*anyopaque;
    extern "c" fn CGImageGetWidth(image: ?*anyopaque) usize;
    extern "c" fn CGImageGetHeight(image: ?*anyopaque) usize;
    extern "c" fn CGBitmapContextCreate(
        data: [*]u8,
        width: usize,
        height: usize,
        bits_per_component: c_uint,
        bytes_per_row: usize,
        colorspace: ?*anyopaque,
        bitmap_info: u32,
    ) ?*anyopaque;
    extern "c" fn CGContextDrawImage(context: ?*anyopaque, rect: Rect, image: ?*anyopaque) void;
    extern "c" fn CGContextSetInterpolationQuality(context: ?*anyopaque, quality: c_int) void;
    extern "c" fn CFURLCreateFromFileSystemRepresentation(
        allocator: ?*anyopaque,
        path: [*]const u8,
        length: isize,
        directory: bool,
    ) ?*anyopaque;

    pub const Rect = extern struct {
        x: f64,
        y: f64,
        width: f64,
        height: f64,
    };

    var device_rgb_colorspace: ?*anyopaque = null;
    var device_rgb_colorspace_resolved: bool = false;

    pub fn deviceRGBColorSpace() ?*anyopaque {
        if (!device_rgb_colorspace_resolved) {
            device_rgb_colorspace = CGColorSpaceCreateDeviceRGB();
            device_rgb_colorspace_resolved = true;
        }
        return device_rgb_colorspace;
    }

    pub fn release(candidate: ?*anyopaque) void {
        if (candidate != null) CFRelease(candidate);
    }

    pub fn urlFromFileSystemPath(path: []const u8) !?*anyopaque {
        const alloc = std.heap.c_allocator;
        const z = try alloc.allocSentinel(u8, path.len, 0);
        defer alloc.free(z);
        @memcpy(z[0..path.len], path);
        return CFURLCreateFromFileSystemRepresentation(null, z.ptr, @intCast(path.len), false);
    }

    pub fn imageSourceCreateWithURL(url: ?*anyopaque, options: ?*anyopaque) ?*anyopaque {
        return CGImageSourceCreateWithURL(url, options);
    }

    pub fn imageSourceCreateImageAtIndex(source: ?*anyopaque, index: usize, options: ?*anyopaque) ?*anyopaque {
        return CGImageSourceCreateImageAtIndex(source, index, options);
    }

    pub fn imageGetWidth(image: ?*anyopaque) usize {
        return CGImageGetWidth(image);
    }

    pub fn imageGetHeight(image: ?*anyopaque) usize {
        return CGImageGetHeight(image);
    }

    pub fn bitmapContextCreate(
        data: [*]u8,
        width: usize,
        height: usize,
        bits_per_component: c_uint,
        bytes_per_row: usize,
        colorspace: ?*anyopaque,
        bitmap_info: u32,
    ) ?*anyopaque {
        return CGBitmapContextCreate(data, width, height, bits_per_component, bytes_per_row, colorspace, bitmap_info);
    }

    pub fn drawImageRect(context: ?*anyopaque, rect: Rect, image: ?*anyopaque) void {
        CGContextDrawImage(context, rect, image);
    }

    pub fn setInterpolationQuality(context: ?*anyopaque, quality: c_int) void {
        CGContextSetInterpolationQuality(context, quality);
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
