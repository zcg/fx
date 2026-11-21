//! The JavaScript host's libfx journal, on WebAssembly. Appends travel as
//! ACP notifications on both backends; only the flush needs this import,
//! because a WebAssembly core cannot await an ACP response.

const host_link = @import("js_host_link.zig");

/// Resolves to 0 once the host holds every event sent so far, or to a
/// negative value when an append failed.
const fx_journal_flush = host_link.declare("fx_journal_flush", *const fn () callconv(.c) i32, fx_journal_flush_unlinked);

fn fx_journal_flush_unlinked() callconv(.c) i32 {
    unreachable;
}

pub fn flush() error{JournalFlushFailed}!void {
    if (fx_journal_flush() != 0) return error.JournalFlushFailed;
}
