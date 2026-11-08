//! Asks the terminal whether it speaks the Kitty graphics protocol, by sending
//! the protocol's own query and reading the reply.
//!
//! Kitty answers a query with `ESC_Gi=31;OK ESC\` when it can draw, and stays
//! silent when it cannot. That is a real answer, unlike an environment variable
//! a compatible terminal may never set.
//!
//! Run with `zig build probe-image-query` from the repository root, in the
//! terminal being tested. It needs a TTY; under a pipe there is no reply.

const std = @import("std");
const io_mod = @import("io");

/// A 1x1 query: `a=q` asks, `f=24` asks about RGB, and the payload is a
/// placeholder the terminal ignores.
const query = "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\";

pub fn main(init: std.process.Init) !void {
    _ = init;
    const zio = io_mod.getIo();
    const stdin = io_mod.stdinHandle();
    const stdout = io_mod.stdoutHandle();

    io_mod.writeFd(stdout, query) catch |err| {
        std.debug.print("write failed: {s}\n", .{@errorName(err)});
        return;
    };
    std.debug.print("sent {d} query bytes\n", .{query.len});

    var buffer: [256]u8 = undefined;
    var waited_ms: usize = 0;
    while (waited_ms < 1500) : (waited_ms += 50) {
        std.Io.sleep(zio, .fromMilliseconds(50), .awake) catch {};
        const read = io_mod.readFd(stdin, &buffer) catch |err| {
            std.debug.print("read failed: {s}\n", .{@errorName(err)});
            return;
        };
        if (read == 0) continue;
        const got = buffer[0..read];
        std.debug.print("reply ({d} bytes): ", .{read});
        for (got) |byte| {
            if (byte >= 0x20 and byte < 0x7f) {
                std.debug.print("{c}", .{byte});
            } else {
                std.debug.print("\\x{x:0>2}", .{byte});
            }
        }
        std.debug.print("\n", .{});
        if (std.mem.find(u8, got, "OK") != null) {
            std.debug.print("RESULT kitty graphics supported\n", .{});
        } else {
            std.debug.print("RESULT reply without OK\n", .{});
        }
        return;
    }
    std.debug.print("RESULT no reply within 1500ms\n", .{});
}
