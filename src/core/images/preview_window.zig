//! A native floating preview window for a terminal that cannot draw images.
//!
//! A terminal is a character grid, and Windows Terminal's graphics path stalls
//! its UI thread on any DCS image. So a preview there cannot be drawn by the
//! terminal at all. This module puts the picture in a real window instead: a
//! layered, non-activating tool window with no frame, painted from premultiplied
//! BGRA pixels the image decoder already produced. It floats above the terminal,
//! never takes focus, and disappears on the next click or when the caller hides
//! it.
//!
//! Everything is loaded from user32/gdi32 at runtime, so the build keeps linking
//! against libc alone: a machine without a window manager simply gets no window
//! rather than a link failure.
//!
//! The module is Windows-only. On every other platform `available` is false and
//! every entry point is a no-op, so callers need no branch of their own.

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.target.os.tag == .windows;

/// Whether this build can create a floating preview window.
pub const available = is_windows;

/// Pixel data for one frame: BGRA, top-down, no row padding. The alpha channel
/// is premultiplied, which is what a layered window's `AC_SRC_ALPHA` expects.
pub const Frame = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
};

const HINSTANCE = *anyopaque;
const HWND = *anyopaque;
const HDC = *anyopaque;
const HBITMAP = *anyopaque;
const HGDIOBJ = *anyopaque;

const WNDCLASSEXW = extern struct {
    cbSize: u32,
    style: u32,
    lpfnWndProc: ?*const fn (HWND, u32, usize, isize) callconv(.winapi) isize,
    cbClsExtra: c_int = 0,
    cbWndExtra: c_int = 0,
    hInstance: HINSTANCE,
    hIcon: ?*anyopaque = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque = null,
};

const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const POINT = extern struct { x: i32, y: i32 };
const SIZE = extern struct { cx: i32, cy: i32 };
const BLENDFUNCTION = extern struct {
    BlendOp: u8 = 0,
    BlendFlags: u8 = 0,
    SourceConstantAlpha: u8 = 255,
    AlphaFormat: u8 = 1,
};
const BITMAPINFOHEADER = extern struct {
    biSize: u32 = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32 = 0,
    biHeight: i32 = 0,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: u32 = 0,
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};

const WS_POPUP: u32 = 0x8000_0000;
const WS_EX_LAYERED: u32 = 0x0008_0000;
const WS_EX_TOOLWINDOW: u32 = 0x0000_0080;
const WS_EX_NOACTIVATE: u32 = 0x0800_0000;
const WS_EX_TOPMOST: u32 = 0x0000_0008;
const SW_HIDE: c_int = 0;
const SW_SHOWNOACTIVATE: c_int = 4;
const ULW_ALPHA: u32 = 0x0000_0002;
const AC_SRC_OVER: u8 = 0x00;
const AC_SRC_ALPHA: u8 = 0x01;
const DIB_RGB_COLORS: u32 = 0;
const BI_RGB: u32 = 0;

extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?HINSTANCE;
extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;

var register_class: ?*const fn (*const WNDCLASSEXW) callconv(.winapi) u16 = null;
var create_window: ?*const fn (u32, [*:0]const u16, [*:0]const u16, u32, i32, i32, i32, i32, ?HWND, ?*anyopaque, HINSTANCE, ?*anyopaque) callconv(.winapi) ?HWND = null;
var destroy_window: ?*const fn (HWND) callconv(.winapi) i32 = null;
var show_window: ?*const fn (HWND, c_int) callconv(.winapi) i32 = null;
var update_layered: ?*const fn (HWND, HDC, *const POINT, *const SIZE, HDC, *const POINT, u32, *const BLENDFUNCTION, u32) callconv(.winapi) i32 = null;
var def_window_proc: ?*const fn (HWND, u32, usize, isize) callconv(.winapi) isize = null;
var get_dc: ?*const fn (?HWND) callconv(.winapi) ?HDC = null;
var release_dc: ?*const fn (?HWND, HDC) callconv(.winapi) c_int = null;
var get_console_window: ?*const fn () callconv(.winapi) ?HWND = null;
var get_window_rect: ?*const fn (HWND, *RECT) callconv(.winapi) i32 = null;
var create_compatible_dc: ?*const fn (?HDC) callconv(.winapi) ?HDC = null;
var create_dib_section: ?*const fn (?HDC, *const BITMAPINFOHEADER, u32, ?*?*anyopaque, ?*anyopaque, u32) callconv(.winapi) ?HBITMAP = null;
var select_object: ?*const fn (HDC, HGDIOBJ) callconv(.winapi) ?HGDIOBJ = null;
var delete_object: ?*const fn (HGDIOBJ) callconv(.winapi) i32 = null;
var delete_dc: ?*const fn (HDC) callconv(.winapi) i32 = null;

var api_loaded: bool = false;

/// Resolves every entry point out of the system DLLs.
///
/// The import libraries are not part of the toolchain's default set, so the
/// DLLs are loaded by name. They ship with every Windows install, and a missing
/// entry point means no preview rather than a build that cannot link.
fn ensureApi() bool {
    if (comptime !is_windows) return false;
    if (api_loaded) return true;
    const user32 = LoadLibraryA("user32.dll") orelse {
        std.debug.print("preview: user32 missing\n", .{});
        return false;
    };
    const gdi32 = LoadLibraryA("gdi32.dll") orelse {
        std.debug.print("preview: gdi32 missing\n", .{});
        return false;
    };

    register_class = @ptrCast(@alignCast(GetProcAddress(user32, "RegisterClassExW")));
    create_window = @ptrCast(@alignCast(GetProcAddress(user32, "CreateWindowExW")));
    destroy_window = @ptrCast(@alignCast(GetProcAddress(user32, "DestroyWindow")));
    show_window = @ptrCast(@alignCast(GetProcAddress(user32, "ShowWindow")));
    update_layered = @ptrCast(@alignCast(GetProcAddress(user32, "UpdateLayeredWindow")));
    def_window_proc = @ptrCast(@alignCast(GetProcAddress(user32, "DefWindowProcW")));
    get_dc = @ptrCast(@alignCast(GetProcAddress(user32, "GetDC")));
    release_dc = @ptrCast(@alignCast(GetProcAddress(user32, "ReleaseDC")));
    get_console_window = @ptrCast(@alignCast(GetProcAddress(user32, "GetConsoleWindow")));
    get_window_rect = @ptrCast(@alignCast(GetProcAddress(user32, "GetWindowRect")));

    create_compatible_dc = @ptrCast(@alignCast(GetProcAddress(gdi32, "CreateCompatibleDC")));
    create_dib_section = @ptrCast(@alignCast(GetProcAddress(gdi32, "CreateDIBSection")));
    select_object = @ptrCast(@alignCast(GetProcAddress(gdi32, "SelectObject")));
    delete_object = @ptrCast(@alignCast(GetProcAddress(gdi32, "DeleteObject")));
    delete_dc = @ptrCast(@alignCast(GetProcAddress(gdi32, "DeleteDC")));

    api_loaded = register_class != null and create_window != null and destroy_window != null and
        show_window != null and update_layered != null and def_window_proc != null and
        get_dc != null and release_dc != null and
        get_window_rect != null and create_compatible_dc != null and create_dib_section != null and
        select_object != null and delete_object != null and delete_dc != null;
    if (!api_loaded) {
        inline for (.{
            .{ "RegisterClassExW", register_class },
            .{ "CreateWindowExW", create_window },
            .{ "DestroyWindow", destroy_window },
            .{ "ShowWindow", show_window },
            .{ "UpdateLayeredWindow", update_layered },
            .{ "DefWindowProcW", def_window_proc },
            .{ "GetDC", get_dc },
            .{ "ReleaseDC", release_dc },
            .{ "GetConsoleWindow", get_console_window },
            .{ "GetWindowRect", get_window_rect },
            .{ "CreateCompatibleDC", create_compatible_dc },
            .{ "CreateDIBSection", create_dib_section },
            .{ "SelectObject", select_object },
            .{ "DeleteObject", delete_object },
            .{ "DeleteDC", delete_dc },
        }) |entry| {
            if (entry[1] == null) std.debug.print("preview: missing {s}\n", .{entry[0]});
        }
    }
    return api_loaded;
}

fn windowProc(hwnd: HWND, message: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    return def_window_proc.?(hwnd, message, wparam, lparam);
}

/// A live preview window. One instance serves every image: showing another one
/// repaints this window, and hiding keeps the handle so a repeat preview does
/// not pay for creation again.
pub const Window = struct {
    handle: usize = 0,
    memory_dc: ?HDC = null,
    bitmap: ?HBITMAP = null,
    bits: ?*anyopaque = null,
    surface_width: u32 = 0,
    surface_height: u32 = 0,

    /// Shows `frame` above the cell named by `anchor_row`/`anchor_col`.
    ///
    /// The anchor is relative to the terminal's own window, in cells, which is
    /// the only coordinate a terminal process can honestly derive: it asks the
    /// console window for its screen rect and offsets from there. A host with
    /// no console window gets the top-left of the display instead.
    pub fn show(
        self: *Window,
        frame: Frame,
        anchor_row: u16,
        anchor_col: u16,
        cell_width: u32,
        cell_height: u32,
    ) bool {
        if (comptime !is_windows) {
            return false;
        }
        if (frame.width == 0 or frame.height == 0) return false;
        if (frame.pixels.len < @as(usize, frame.width) * frame.height * 4) return false;
        if (!ensureApi()) return false;
        if (!self.ensureWindow()) return false;
        if (!self.paint(frame)) return false;

        var origin = POINT{ .x = 0, .y = 0 };
        if (get_console_window) |ask_console| {
            if (ask_console()) |console| {
                var rect: RECT = undefined;
                if (get_window_rect.?(console, &rect) != 0) {
                    origin.x = rect.left;
                    origin.y = rect.top;
                }
            }
        }
        const x = origin.x + @as(i32, @intCast(anchor_col -| 1)) * @as(i32, @intCast(@max(cell_width, 1)));
        const y = origin.y + @as(i32, @intCast(anchor_row -| 1)) * @as(i32, @intCast(@max(cell_height, 1)));

        const destination = POINT{ .x = x, .y = y };
        const size = SIZE{ .cx = @intCast(frame.width), .cy = @intCast(frame.height) };
        const source = POINT{ .x = 0, .y = 0 };
        const blend = BLENDFUNCTION{
            .BlendOp = AC_SRC_OVER,
            .BlendFlags = 0,
            .SourceConstantAlpha = 255,
            .AlphaFormat = AC_SRC_ALPHA,
        };
        const screen_dc = get_dc.?(null) orelse return false;
        defer _ = release_dc.?(null, screen_dc);

        const ok = update_layered.?(
            @ptrFromInt(self.handle),
            screen_dc,
            &destination,
            &size,
            self.memory_dc orelse return false,
            &source,
            0,
            &blend,
            ULW_ALPHA,
        ) != 0;
        if (!ok) return false;
        _ = show_window.?(@ptrFromInt(self.handle), SW_SHOWNOACTIVATE);
        return true;
    }

    /// Hides the window. The handle survives.
    pub fn hide(self: *Window) void {
        if (comptime !is_windows) return;
        if (self.handle == 0) return;
        _ = show_window.?(@ptrFromInt(self.handle), SW_HIDE);
    }

    /// Releases the window and its surface.
    pub fn deinit(self: *Window) void {
        if (comptime !is_windows) return;
        if (self.bitmap != null) {
            _ = delete_object.?(self.bitmap.?);
            self.bitmap = null;
        }
        if (self.memory_dc != null) {
            _ = delete_dc.?(self.memory_dc.?);
            self.memory_dc = null;
        }
        if (self.handle != 0) {
            _ = destroy_window.?(@ptrFromInt(self.handle));
            self.handle = 0;
        }
        self.bits = null;
    }

    fn ensureWindow(self: *Window) bool {
        if (self.handle != 0) return true;
        const instance = GetModuleHandleW(null) orelse return false;
        const class_name = std.unicode.utf8ToUtf16LeStringLiteral("fx.image.preview");
        const window_name = std.unicode.utf8ToUtf16LeStringLiteral("fx image preview");

        const window_class = WNDCLASSEXW{
            .cbSize = @sizeOf(WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = windowProc,
            .hInstance = instance,
            .lpszClassName = class_name,
        };
        _ = register_class.?(&window_class);

        const handle = create_window.?(
            WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST,
            class_name,
            window_name,
            WS_POPUP,
            0,
            0,
            1,
            1,
            null,
            null,
            instance,
            null,
        ) orelse return false;
        self.handle = @intFromPtr(handle);
        return true;
    }

    fn paint(self: *Window, frame: Frame) bool {
        const screen_dc = get_dc.?(null) orelse return false;
        defer _ = release_dc.?(null, screen_dc);

        // One surface per size: a preview that keeps the same size reuses it.
        const bytes = @as(usize, frame.width) * frame.height * 4;
        if (self.memory_dc == null or self.surface_width != frame.width or self.surface_height != frame.height) {
            const memory = create_compatible_dc.?(screen_dc) orelse return false;
            var header = BITMAPINFOHEADER{
                .biWidth = @intCast(frame.width),
                // A negative height asks for a top-down DIB, which matches the
                // row order the decoder produces.
                .biHeight = -@as(i32, @intCast(frame.height)),
                .biPlanes = 1,
                .biBitCount = 32,
                .biCompression = BI_RGB,
            };
            var bits: ?*anyopaque = null;
            const bitmap = create_dib_section.?(memory, &header, DIB_RGB_COLORS, &bits, null, 0) orelse {
                _ = delete_dc.?(memory);
                return false;
            };
            _ = select_object.?(memory, bitmap);

            if (self.bitmap) |old| _ = delete_object.?(old);
            if (self.memory_dc) |old| _ = delete_dc.?(old);
            self.memory_dc = memory;
            self.bitmap = bitmap;
            self.bits = bits;
            self.surface_width = frame.width;
            self.surface_height = frame.height;
        }

        // Copy the frame into the surface the window draws from. The DIB is
        // 32-bit top-down, so the rows are already in the order it wants.
        const target = self.bits orelse return false;
        const destination: [*]u8 = @ptrCast(target);
        if (self.surface_width != frame.width or self.surface_height != frame.height) return false;
        @memcpy(destination[0..bytes], frame.pixels[0..bytes]);
        return true;
    }
};

test "a frame with no pixels is refused" {
    var window = Window{};
    try std.testing.expect(!window.show(.{ .pixels = &.{}, .width = 0, .height = 0 }, 1, 1, 8, 16));
}
