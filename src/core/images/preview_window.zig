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
const MONITORINFO = extern struct {
    cbSize: u32 = @sizeOf(MONITORINFO),
    rcMonitor: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    rcWork: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    dwFlags: u32 = 0,
};
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
/// Makes the window invisible to hit-testing.
///
/// Without it the window receives every pointer message for the area it covers,
/// and since it is a decoration with no input of its own it answers none of
/// them. Windows then keeps retrying — the busy cursor and the near-freeze the
/// user sees when the pointer crosses the picture — and moving the pointer away
/// clears it because the messages stop. A preview is never a click target, so
/// the pointer belongs to whatever is underneath.
const WS_EX_TRANSPARENT: u32 = 0x0000_0020;
/// The window must not take the pointer or the mouse capture either.
const WM_MOUSEACTIVATE: u32 = 0x0021;
const WM_NCHITTEST: u32 = 0x0084;
const MA_NOACTIVATE: isize = 3;
const HTTRANSPARENT: isize = -1;
const SW_HIDE: c_int = 0;
const SW_SHOWNOACTIVATE: c_int = 4;
const ULW_ALPHA: u32 = 0x0000_0002;
const AC_SRC_OVER: u8 = 0x00;
const AC_SRC_ALPHA: u8 = 0x01;
const DIB_RGB_COLORS: u32 = 0;
const BI_RGB: u32 = 0;
const SM_CXSCREEN: c_int = 0;
const SM_CYSCREEN: c_int = 1;

/// A screen rectangle in pixels.
const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

fn fits(rect: Rect, work: Rect) bool {
    return rect.x >= work.x and
        rect.y >= work.y and
        rect.x + rect.width <= work.x + work.width and
        rect.y + rect.height <= work.y + work.height;
}

/// Moves `rect` the least amount that puts it inside `work`.
fn clampInto(rect: Rect, work: Rect) Rect {
    var placed = rect;
    if (placed.width >= work.width) {
        placed.x = work.x;
    } else {
        placed.x = @min(@max(placed.x, work.x), work.x + work.width - placed.width);
    }
    if (placed.height >= work.height) {
        placed.y = work.y;
    } else {
        placed.y = @min(@max(placed.y, work.y), work.y + work.height - placed.height);
    }
    return placed;
}

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
var get_system_metrics: ?*const fn (c_int) callconv(.winapi) c_int = null;
var monitor_from_window: ?*const fn (HWND) callconv(.winapi) ?*anyopaque = null;
var get_monitor_info: ?*const fn (?*anyopaque, *MONITORINFO) callconv(.winapi) i32 = null;
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
    get_system_metrics = @ptrCast(@alignCast(GetProcAddress(user32, "GetSystemMetrics")));
    monitor_from_window = @ptrCast(@alignCast(GetProcAddress(user32, "MonitorFromWindow")));
    get_monitor_info = @ptrCast(@alignCast(GetProcAddress(user32, "GetMonitorInfoW")));

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
    switch (message) {
        // The preview never activates and never takes the pointer: it is
        // decoration over another window, and a click belongs to that window.
        WM_MOUSEACTIVATE => return MA_NOACTIVATE,
        WM_NCHITTEST => return HTTRANSPARENT,
        else => {},
    }
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

    /// Shows `frame` next to the cell named by `anchor_row`/`anchor_col`.
    ///
    /// The anchor is a cell inside the terminal's own window, which is the only
    /// coordinate a terminal process can honestly derive: it asks the console
    /// window for its screen rect and offsets from there. The window is placed
    /// beside the anchor, preferring the space that actually exists, and finally
    /// clamped so it can never end up off the display.
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

        const placement = self.place(
            anchor_row,
            anchor_col,
            cell_width,
            cell_height,
            @as(i32, @intCast(frame.width)),
            @as(i32, @intCast(frame.height)),
        );

        const destination = POINT{ .x = placement.x, .y = placement.y };
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

    /// Where the window goes, in screen pixels.
    ///
    /// The anchor cell's screen position comes from the console window's rect
    /// plus the cell offsets. Around it there are four candidate placements, and
    /// the first that fits entirely inside the monitor's work area wins, in the
    /// order the caller's eye expects: right of the badge, then left, then
    /// above, then below. When none fits, the nearest one is clamped into the
    /// work area, so the picture is always fully visible even in a small window.
    fn place(
        self: *const Window,
        anchor_row: u16,
        anchor_col: u16,
        cell_width: u32,
        cell_height: u32,
        width: i32,
        height: i32,
    ) Rect {
        _ = self;
        var work = Rect{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
        var console = Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };

        if (get_console_window) |ask_console| {
            if (ask_console()) |handle| {
                var rect: RECT = undefined;
                if (get_window_rect.?(handle, &rect) != 0) {
                    console = .{
                        .x = rect.left,
                        .y = rect.top,
                        .width = rect.right - rect.left,
                        .height = rect.bottom - rect.top,
                    };
                }
                // The work area is the monitor's rectangle minus taskbars, which
                // is the region a floating window is allowed to occupy.
                if (monitor_from_window) |ask_monitor| {
                    if (get_monitor_info) |ask_info| {
                        if (ask_monitor(handle)) |monitor| {
                            var info = MONITORINFO{};
                            if (ask_info(monitor, &info) != 0) {
                                work = .{
                                    .x = info.rcWork.left,
                                    .y = info.rcWork.top,
                                    .width = info.rcWork.right - info.rcWork.left,
                                    .height = info.rcWork.bottom - info.rcWork.top,
                                };
                            }
                        }
                    }
                }
            }
        } else if (get_system_metrics) |ask_metrics| {
            work = .{ .x = 0, .y = 0, .width = ask_metrics(SM_CXSCREEN), .height = ask_metrics(SM_CYSCREEN) };
        }

        const cell_w: i32 = @intCast(@max(cell_width, 1));
        const cell_h: i32 = @intCast(@max(cell_height, 1));
        // The badge's own screen rectangle. A badge is a short run of cells, so
        // eight columns is a fair width to sit beside.
        const badge = Rect{
            .x = console.x + (@as(i32, @intCast(anchor_col -| 1))) * cell_w,
            .y = console.y + (@as(i32, @intCast(anchor_row -| 1))) * cell_h,
            .width = cell_w * 8,
            .height = cell_h,
        };
        const gap: i32 = 1;

        const candidates = [_]Rect{
            // Right of the badge, vertically centred on it.
            .{ .x = badge.x + badge.width + gap, .y = badge.y - @divTrunc(height - badge.height, 2), .width = width, .height = height },
            // Left.
            .{ .x = badge.x - width - gap, .y = badge.y - @divTrunc(height - badge.height, 2), .width = width, .height = height },
            // Above.
            .{ .x = badge.x, .y = badge.y - height - gap, .width = width, .height = height },
            // Below.
            .{ .x = badge.x, .y = badge.y + badge.height + gap, .width = width, .height = height },
        };
        for (candidates) |candidate| {
            if (fits(candidate, work)) return candidate;
        }
        return clampInto(candidates[candidates.len - 1], work);
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
            WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST | WS_EX_TRANSPARENT,
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
