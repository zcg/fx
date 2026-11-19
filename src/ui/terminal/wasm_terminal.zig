const types = @import("../../core/shared/types.zig");
const terminal = @import("terminal.zig");
const host_link = @import("../../core/hosts/js_host_link.zig");

fn fx_term_size_unlinked(cols: *u16, rows: *u16) callconv(.c) void {
    _ = .{ cols, rows };
    unreachable;
}

fn fx_term_poll_input_unlinked(timeout_ms: i32) callconv(.c) i32 {
    _ = timeout_ms;
    unreachable;
}

const fx_term_size = host_link.declare(
    "fx_term_size",
    *const fn (*u16, *u16) callconv(.c) void,
    fx_term_size_unlinked,
);
const fx_term_poll_input = host_link.declare(
    "fx_term_poll_input",
    *const fn (i32) callconv(.c) i32,
    fx_term_poll_input_unlinked,
);

pub const Size = struct {
    cols: u16,
    rows: u16,
};

pub fn pollInput(timeout_ms: i32) i32 {
    return fx_term_poll_input(timeout_ms);
}

pub fn querySize() !Size {
    var cols: u16 = 0;
    var rows: u16 = 0;
    fx_term_size(&cols, &rows);
    if (cols == 0 or rows == 0) return error.UnableToReadTerminalSize;
    return .{ .cols = cols, .rows = rows };
}

pub fn queryLayout(footer_rows: u16) !types.Layout {
    const size = try querySize();
    return terminal.layoutFromSize(size.rows, size.cols, footer_rows);
}
