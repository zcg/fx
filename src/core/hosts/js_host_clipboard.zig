const std = @import("std");
const host = @import("host.zig");
const host_link = @import("js_host_link.zig");

const fx_clipboard_copy = host_link.declare("fx_clipboard_copy", *const fn (text_ptr: [*]const u8, text_len: usize) callconv(.c) i32, fx_clipboard_copy_unlinked);

fn fx_clipboard_copy_unlinked(text_ptr: [*]const u8, text_len: usize) callconv(.c) i32 {
    _ = text_ptr;
    _ = text_len;
    unreachable;
}

pub const clipboard: host.Clipboard = .{ .copy_fn = copy };

fn copy(_: ?*anyopaque, text: []const u8) host.ClipboardError!bool {
    return copyWith(fx_clipboard_copy, text);
}

fn copyWith(call: anytype, text: []const u8) bool {
    return call(text.ptr, text.len) == 1;
}

test "JS host clipboard preserves selection when the browser rejects copy" {
    const RejectingHost = struct {
        fn call(_: [*]const u8, _: usize) i32 {
            return 0;
        }
    };
    try std.testing.expect(!copyWith(RejectingHost.call, "draft"));
}

test "JS host clipboard forwards the exact selected bytes" {
    const CapturingHost = struct {
        var captured: []const u8 = "";

        fn call(ptr: [*]const u8, len: usize) i32 {
            captured = ptr[0..len];
            return 1;
        }
    };
    try std.testing.expect(copyWith(CapturingHost.call, "selected text"));
    try std.testing.expectEqualStrings("selected text", CapturingHost.captured);
}
