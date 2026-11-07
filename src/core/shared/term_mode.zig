//! Terminal mode as fx uses it, on platforms that describe a terminal two
//! different ways.
//!
//! POSIX keeps terminal state in `termios`: four flag words and a table of
//! control characters. fx puts a terminal into raw mode by clearing input
//! translations, echoing, canonical buffering, and signal generation, then
//! restoring the captured value when the screen closes.
//!
//! Windows has no termios. A console is described by one mode word per handle,
//! and Zig's `std.posix.termios` is `void` there, so no field of it can be read
//! or written. The equivalent of raw mode is clearing `ENABLE_LINE_INPUT`,
//! `ENABLE_ECHO_INPUT`, and `ENABLE_PROCESSED_INPUT` on the input handle, plus
//! turning on processed output and virtual terminal processing so the same
//! escape sequences fx already emits are interpreted.
//!
//! `Saved` is the one value a caller holds across the raw window. On POSIX it
//! wraps the captured `termios`; on Windows it wraps the captured console mode
//! words. Callers never read it; they capture once and restore once, which is
//! the whole contract.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");

pub const is_windows = builtin.target.os.tag == .windows;
pub const is_wasi = builtin.target.os.tag == .wasi;

/// A terminal's mode captured before fx changes it.
///
/// Holds whatever the platform needs to put the terminal back. Treat it as
/// opaque: pass it to `restore` and nothing else.
pub const Saved = if (is_windows) struct {
    input_mode: u32,
    output_mode: u32,
    /// The console's input and output code pages before fx set them. Windows
    /// keeps these on the console, not on a file descriptor, so they outlive
    /// the process unless they are put back.
    input_code_page: u32,
    output_code_page: u32,
} else struct {
    termios: std.posix.termios,
};

/// Errors from reading or changing a terminal's mode.
pub const Error = error{
    /// The handle names a redirected file or pipe rather than a terminal.
    NotATerminal,
    /// The platform refused the change.
    Unexpected,
};

/// Captures the mode of `input_fd`, reading `output_fd` too where the platform
/// keeps separate input and output state.
pub fn capture(input_fd: std.posix.fd_t, output_fd: std.posix.fd_t) Error!Saved {
    if (comptime is_windows) {
        return .{
            .input_mode = windowsGetMode(input_fd) orelse return error.NotATerminal,
            .output_mode = windowsGetMode(output_fd) orelse return error.NotATerminal,
            .input_code_page = windowsGetConsoleCP(),
            .output_code_page = windowsGetConsoleOutputCP(),
        };
    }
    if (comptime is_wasi) return error.NotATerminal;
    return .{ .termios = io_mod.tcgetattr(input_fd) catch |err| switch (err) {
        error.NotATerminal => return error.NotATerminal,
        else => return error.Unexpected,
    } };
}

/// Puts the terminal into raw mode and returns what `restore` needs.
/// The `saved` value is the same one `capture` produced.
pub fn enableRaw(saved: Saved, input_fd: std.posix.fd_t, output_fd: std.posix.fd_t) Error!void {
    if (comptime is_windows) {
        // Windows console input takes its raw form as a mode word. Line input,
        // echo, and Ctrl+C processing are all cleared, which is what fx's key
        // handling expects, and virtual terminal input is turned on so a key and
        // a paste arrive as the ANSI byte stream the input parser reads.
        const raw_input = windows_enable_window_input |
            windows_enable_extended_flags |
            windows_enable_virtual_terminal_input;
        if (!setMode(input_fd, raw_input)) return error.Unexpected;

        // The screen writes ANSI escape sequences, so the console has to be told
        // to interpret them. Without this flag a console prints them as text.
        // From here on the input handle is already raw, so a failure has to put
        // it back: a caller that sees an error does not restore, because it never
        // recorded that the mode changed, and the terminal would stay raw with
        // echo off for the rest of the process.
        const output_mode = windowsGetMode(output_fd) orelse {
            restore(saved, input_fd, output_fd);
            return error.NotATerminal;
        };
        const wanted_output = output_mode | windows_enable_processed_output | windows_enable_virtual_terminal_processing;
        if (!setMode(output_fd, wanted_output)) {
            restore(saved, input_fd, output_fd);
            return error.Unexpected;
        }

        // The console has been asked for virtual terminal processing, which is
        // what makes it interpret the escape sequences fx writes. A host that
        // refuses leaves the screen in plain text rather than breaking the
        // session, so this does not gate startup.

        // fx writes UTF-8. A console whose output code page is not UTF-8
        // transcribes those bytes through a legacy table, which turns the screen
        // into mojibake for anything outside ASCII.
        //
        // Both code pages move together. Input is read as bytes, so leaving the
        // input code page at the OEM default transcribes a Chinese or emoji
        // keystroke in that table before fx ever sees it.
        const output_set = setOutputCodePage(windows_utf8_code_page);
        const input_set = setInputCodePage(windows_utf8_code_page);
        if (!output_set or !input_set) {
            restore(saved, input_fd, output_fd);
            return error.Unexpected;
        }
        return;
    }
    if (comptime is_wasi) return;
    var raw = saved.termios;
    raw.iflag.BRKINT = false;
    raw.iflag.IGNCR = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INLCR = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;
    raw.iflag.IXOFF = false;
    raw.cflag.CSIZE = .CS8;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;
    const vmin_idx = vmIndex(.min);
    const vtime_idx = vmIndex(.time);
    if (vmin_idx < raw.cc.len and vtime_idx < raw.cc.len) {
        raw.cc[vmin_idx] = 1;
        raw.cc[vtime_idx] = 0;
    }
    io_mod.tcsetattr(input_fd, .FLUSH, raw) catch return error.Unexpected;
}

/// Puts the terminal back the way `capture` found it.
pub fn restore(saved: Saved, input_fd: std.posix.fd_t, output_fd: std.posix.fd_t) void {
    if (comptime is_windows) {
        _ = setMode(input_fd, saved.input_mode);
        _ = setMode(output_fd, saved.output_mode);
        // The code pages belong to the console window, so leaving them at UTF-8
        // changes every program that shares it after fx exits.
        _ = setInputCodePage(saved.input_code_page);
        _ = setOutputCodePage(saved.output_code_page);
        return;
    }
    if (comptime is_wasi) return;
    io_mod.tcsetattr(input_fd, .FLUSH, saved.termios) catch {};
}

/// Turns echo on or off without disturbing the rest of the mode. Reading a
/// masked secret needs echo off while keys are still buffered by line.
pub fn setEcho(saved: Saved, input_fd: std.posix.fd_t, enabled: bool) Error!void {
    if (comptime is_windows) {
        var mode = windowsGetMode(input_fd) orelse return error.NotATerminal;
        // Echo is a console-wide setting, so enable restores the captured mode's
        // echo bit rather than assuming it was on.
        mode = if (enabled) mode | windows_enable_echo_input else mode & ~windows_enable_echo_input;
        if (!setMode(input_fd, mode)) return error.Unexpected;
        return;
    }
    if (comptime is_wasi) return;
    var term = saved.termios;
    term.lflag.ECHO = enabled;
    io_mod.tcsetattr(input_fd, .NOW, term) catch return error.Unexpected;
}

pub const VmIndex = enum { min, time };

fn vmIndex(which: VmIndex) usize {
    if (comptime is_windows or is_wasi) return 0;
    return switch (which) {
        .min => std.posix.V.MIN,
        .time => std.posix.V.TIME,
    };
}

// Windows console mode bits, from `consoleapi.h`. Zig's `std.os.windows` names
// only the virtual terminal one, so fx names the set it uses.
/// `ENABLE_VIRTUAL_TERMINAL_INPUT`, which makes a console deliver keys and
/// pastes as the ANSI byte stream the input parser reads.
const windows_enable_virtual_terminal_input: u32 = 0x0200;

/// The UTF-8 code page, which is what fx's byte output is encoded in.
const windows_utf8_code_page: u32 = 65001;

fn setOutputCodePage(code_page: u32) bool {
    if (comptime !is_windows) return false;
    return windows_console.SetConsoleOutputCP(code_page) != 0;
}

fn setInputCodePage(code_page: u32) bool {
    if (comptime !is_windows) return false;
    return windows_console.SetConsoleCP(code_page) != 0;
}

fn windowsGetConsoleCP() u32 {
    if (comptime !is_windows) return 0;
    return windows_console.GetConsoleCP();
}

fn windowsGetConsoleOutputCP() u32 {
    if (comptime !is_windows) return 0;
    return windows_console.GetConsoleOutputCP();
}

const windows_enable_processed_input: u32 = 0x0001;
const windows_enable_line_input: u32 = 0x0002;
const windows_enable_echo_input: u32 = 0x0004;
const windows_enable_window_input: u32 = 0x0008;
const windows_enable_extended_flags: u32 = 0x0080;
const windows_enable_processed_output: u32 = 0x0001;
const windows_enable_virtual_terminal_processing: u32 = 0x0004;

fn windowsGetMode(fd: std.posix.fd_t) ?u32 {
    if (comptime !is_windows) return null;
    var mode: u32 = 0;
    if (windows_console.GetConsoleMode(fd, &mode) == 0) return null;
    return mode;
}

fn setMode(fd: std.posix.fd_t, mode: u32) bool {
    if (comptime !is_windows) return false;
    return windows_console.SetConsoleMode(fd, mode) != 0;
}

const windows_console = if (!is_windows) struct {} else struct {
    extern "kernel32" fn GetConsoleMode(h_console: std.posix.fd_t, mode: *u32) callconv(.winapi) c_int;
    extern "kernel32" fn SetConsoleMode(h_console: std.posix.fd_t, mode: u32) callconv(.winapi) c_int;
    extern "kernel32" fn SetConsoleOutputCP(code_page_id: u32) callconv(.winapi) c_int;
    extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
    extern "kernel32" fn SetConsoleCP(code_page_id: u32) callconv(.winapi) c_int;
    extern "kernel32" fn GetConsoleCP() callconv(.winapi) u32;
};

/// Whether the platform's terminal state lives in a `termios` structure, which
/// decides whether a caller may read or write one directly. Windows and WASI
/// report false.
pub const has_termios = !is_windows and !is_wasi;

test "capture reports a regular file as not a terminal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "plain", .{});
    defer file.close(std.testing.io);
    try std.testing.expectError(error.NotATerminal, capture(file.handle, file.handle));
}

test "the UTF-8 code page is the one fx writes bytes in" {
    if (comptime !is_windows) return error.SkipZigTest;
    try std.testing.expectEqual(@as(u32, 65001), windows_utf8_code_page);
}
