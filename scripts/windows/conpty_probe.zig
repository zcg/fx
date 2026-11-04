// Drives fx through a real Windows pseudo console, the way a terminal emulator
// does, so the interactive screen can be exercised without a human at a
// keyboard. This stands in for tmux on Windows: ConPTY is what Windows Terminal
// and every modern console host use, so a program that renders correctly through
// it renders correctly for the user.
//
// Usage: conpty_probe.exe <path-to-fx> [seconds]
//
// The pseudo console's output pipe is read on its own thread, because a blocking
// read on it parks until the session writes, and the main thread has to send
// Ctrl+C on a deadline. That thread appends to a growable buffer the main thread
// then prints with escape sequences made visible.

const std = @import("std");

const windows = std.os.windows;

const COORD = extern struct {
    X: i16,
    Y: i16,
};

extern "kernel32" fn CreatePseudoConsole(
    size: COORD,
    h_input_read: windows.HANDLE,
    h_output_write: windows.HANDLE,
    flags: u32,
    console: *windows.HANDLE,
) callconv(.winapi) c_int;

extern "kernel32" fn ClosePseudoConsole(console: windows.HANDLE) callconv(.winapi) void;

const STARTUPINFOEXW = extern struct {
    StartupInfo: windows.STARTUPINFOW,
    lpAttributeList: ?*anyopaque,
};

extern "kernel32" fn InitializeProcThreadAttributeList(
    list: ?*anyopaque,
    attribute_count: u32,
    flags: u32,
    size: *usize,
) callconv(.winapi) c_int;

extern "kernel32" fn UpdateProcThreadAttribute(
    list: *anyopaque,
    flags: u32,
    attribute: usize,
    value: *const anyopaque,
    size: usize,
    previous: ?*anyopaque,
    return_size: ?*usize,
) callconv(.winapi) c_int;

extern "kernel32" fn DeleteProcThreadAttributeList(list: *anyopaque) callconv(.winapi) void;

extern "kernel32" fn CreateProcessW(
    application_name: ?[*:0]const u16,
    command_line: ?[*:0]u16,
    process_attributes: ?*anyopaque,
    thread_attributes: ?*anyopaque,
    inherit_handles: c_int,
    creation_flags: u32,
    environment: ?*anyopaque,
    current_directory: ?[*:0]const u16,
    startup_info: *STARTUPINFOEXW,
    process_information: *PROCESS_INFORMATION,
) callconv(.winapi) c_int;

const PROCESS_INFORMATION = extern struct {
    hProcess: windows.HANDLE,
    hThread: windows.HANDLE,
    dwProcessId: u32,
    dwThreadId: u32,
};

extern "kernel32" fn CreatePipe(
    read_pipe: *windows.HANDLE,
    write_pipe: *windows.HANDLE,
    pipe_attributes: ?*anyopaque,
    size: u32,
) callconv(.winapi) c_int;

extern "kernel32" fn ReadFile(
    file: windows.HANDLE,
    buffer: [*]u8,
    bytes_to_read: u32,
    bytes_read: ?*u32,
    overlapped: ?*anyopaque,
) callconv(.winapi) c_int;

extern "kernel32" fn WriteFile(
    file: windows.HANDLE,
    buffer: [*]const u8,
    bytes_to_write: u32,
    bytes_written: ?*u32,
    overlapped: ?*anyopaque,
) callconv(.winapi) c_int;

extern "kernel32" fn CloseHandle(handle: windows.HANDLE) callconv(.winapi) c_int;

extern "kernel32" fn WaitForSingleObject(handle: windows.HANDLE, milliseconds: u32) callconv(.winapi) u32;

extern "kernel32" fn GetExitCodeProcess(process: windows.HANDLE, exit_code: *u32) callconv(.winapi) c_int;

extern "kernel32" fn TerminateProcess(process: windows.HANDLE, exit_code: u32) callconv(.winapi) c_int;

const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
const EXTENDED_STARTUPINFO_PRESENT: u32 = 0x00080000;
/// Start the child without a console window of its own: the pseudo console is
/// its console, so without this Windows also opens a real window.
const CREATE_NO_WINDOW: u32 = 0x08000000;
const still_active: u32 = 259;
const transcript_limit: usize = 400_000;

/// What the reading thread collects. The main thread owns the allocator, so the
/// thread takes a fixed buffer and a length that only grows.
const Capture = struct {
    buffer: []u8,
    length: usize = 0,
};

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    var args = try init.minimal.args.iterateAllocator(alloc);
    defer args.deinit();
    _ = args.next();

    const exe_path = args.next() orelse {
        std.debug.print("usage: conpty_probe <path-to-fx> [seconds]\n", .{});
        return error.MissingArgument;
    };
    const seconds_text = args.next();
    const seconds: u64 = if (seconds_text) |text| std.fmt.parseInt(u64, text, 10) catch 4 else 4;
    // Read before the iterator is deinitialized below, and keep the slice alive by
    // copying it: the iterator owns its buffer.
    const dump_path_owned: ?[]u8 = if (args.next()) |path| try alloc.dupe(u8, path) else null;
    defer if (dump_path_owned) |path| alloc.free(path);

    const size: COORD = .{ .X = 100, .Y = 30 };

    var input_read: windows.HANDLE = undefined;
    var input_write: windows.HANDLE = undefined;
    var output_read: windows.HANDLE = undefined;
    var output_write: windows.HANDLE = undefined;
    if (CreatePipe(&input_read, &input_write, null, 0) == 0) return error.PipeFailed;
    defer _ = CloseHandle(input_read);
    defer _ = CloseHandle(input_write);
    if (CreatePipe(&output_read, &output_write, null, 0) == 0) return error.PipeFailed;
    defer _ = CloseHandle(output_write);

    var console: windows.HANDLE = undefined;
    if (CreatePseudoConsole(size, input_read, output_write, 0, &console) != 0) {
        return error.PseudoConsoleFailed;
    }
    defer ClosePseudoConsole(console);

    var attribute_size: usize = 0;
    _ = InitializeProcThreadAttributeList(null, 1, 0, &attribute_size);
    const attribute_list = try alloc.alignedAlloc(u8, .of(usize), attribute_size);
    defer alloc.free(attribute_list);
    if (InitializeProcThreadAttributeList(attribute_list.ptr, 1, 0, &attribute_size) == 0) {
        return error.AttributeListFailed;
    }
    defer DeleteProcThreadAttributeList(attribute_list.ptr);
    if (UpdateProcThreadAttribute(
        attribute_list.ptr,
        0,
        PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        @ptrCast(&console),
        @sizeOf(windows.HANDLE),
        null,
        null,
    ) == 0) return error.AttributeUpdateFailed;

    const exe_wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, exe_path);
    defer alloc.free(exe_wide);
    const command_line = try std.unicode.utf8ToUtf16LeAllocZ(alloc, exe_path);
    defer alloc.free(command_line);

    var startup_info: STARTUPINFOEXW = std.mem.zeroes(STARTUPINFOEXW);
    startup_info.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
    startup_info.lpAttributeList = attribute_list.ptr;
    var process_info: PROCESS_INFORMATION = undefined;
    if (CreateProcessW(
        exe_wide.ptr,
        command_line.ptr,
        null,
        null,
        0,
        EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW,
        null,
        null,
        &startup_info,
        &process_info,
    ) == 0) return error.CreateProcessFailed;
    defer _ = CloseHandle(process_info.hThread);
    defer _ = CloseHandle(process_info.hProcess);

    const capture_buffer = try alloc.alloc(u8, transcript_limit);
    defer alloc.free(capture_buffer);
    var capture: Capture = .{ .buffer = capture_buffer };
    const reader_thread = try std.Thread.spawn(.{}, readLoop, .{ &capture, output_read });

    const started = std.Io.Clock.awake.now(init.io);
    const deadline = @as(u64, @intCast(started.nanoseconds)) + seconds * std.time.ns_per_s;
    while (@as(u64, @intCast(std.Io.Clock.awake.now(init.io).nanoseconds)) < deadline) {
        if (WaitForSingleObject(process_info.hProcess, 50) == 0) break;
    }

    // Ctrl+C in a ConPTY session is the byte a terminal sends for it.
    var written: u32 = 0;
    _ = WriteFile(input_write, "\x03", 1, &written, null);

    var exit_code: u32 = 0;
    if (WaitForSingleObject(process_info.hProcess, 3000) != 0) {
        _ = GetExitCodeProcess(process_info.hProcess, &exit_code);
        if (exit_code == still_active) {
            _ = TerminateProcess(process_info.hProcess, 1);
            exit_code = 1;
        }
    } else {
        _ = GetExitCodeProcess(process_info.hProcess, &exit_code);
    }

    // Let the reader drain what the console wrote before the child exited, then
    // close the read end so its blocking read returns and the thread can be
    // joined. Closing the pipe is what unblocks it; joining first would wait on a
    // read that only the close can end.
    init.io.sleep(.{ .nanoseconds = 200 * std.time.ns_per_ms }, .awake) catch {};
    _ = CloseHandle(output_read);
    reader_thread.join();

    // Write the transcript to a third argument when given, as well as stderr. A
    // caller that reads the probe's stderr through a pipe can deadlock on a full
    // pipe buffer, and the screen is the whole point of running this, so it also
    // goes to disk where it cannot be lost.
    const dump_path = dump_path_owned;
    if (dump_path) |path| {
        var file = std.Io.Dir.createFileAbsolute(init.io, path, .{ .truncate = true }) catch null;
        if (file) |*open_file| {
            defer open_file.close(init.io);
            open_file.writeStreamingAll(init.io, capture.buffer[0..capture.length]) catch {};
        }
    }

    std.debug.print("=== conpty probe: {d} bytes captured, exit={d} ===\n", .{ capture.length, exit_code });
    std.debug.print("=== transcript (escapes as ^[) ===\n", .{});
    for (capture.buffer[0..capture.length]) |byte| {
        switch (byte) {
            0x1b => std.debug.print("^[", .{}),
            '\r' => std.debug.print("\\r", .{}),
            '\n' => std.debug.print("\\n\n", .{}),
            else => if (byte >= 0x20 and byte < 0x7f)
                std.debug.print("{c}", .{byte})
            else
                std.debug.print("<{X:0>2}>", .{byte}),
        }
    }
    std.debug.print("\n=== end transcript ===\n", .{});
}

/// Drains the pseudo console's output until it closes.
fn readLoop(capture: *Capture, pipe: windows.HANDLE) void {
    var chunk: [8192]u8 = undefined;
    while (true) {
        var read_count: u32 = 0;
        if (ReadFile(pipe, &chunk, chunk.len, &read_count, null) == 0) return;
        if (read_count == 0) return;
        const space = capture.buffer.len - capture.length;
        const take = @min(@as(usize, read_count), space);
        if (take > 0) {
            @memcpy(capture.buffer[capture.length..][0..take], chunk[0..take]);
            capture.length += take;
        }
    }
}
