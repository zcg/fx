//! The `extern "fx"` functions a JavaScript host provides to libfx.
//!
//! libfx runs inside a JavaScript runtime, which answers a small set of calls
//! under the `fx` library name: clipboard access, configuration, the journal,
//! the terminal, and so on. Only a WebAssembly build links against one, so only
//! there is a real import. On a native target the same name would ask the
//! linker for a library nothing writes, so `declare` hands back a stub instead.
//!
//! A module names the symbol, its signature, and a stub with that signature.
//! Each declaration is a function pointer, so a call site reads the same on
//! both platforms.

const builtin = @import("builtin");
const target = @import("target.zig");

/// Whether this build runs inside the JavaScript host.
pub const linked = target.is_wasm;

/// The function to call for `name`.
///
/// `Signature` is a pointer type such as `*const fn (i32) callconv(.c) i32`.
/// On a WebAssembly build this is the import under that name. Anywhere else it
/// is `stub`, which the runtime never calls: the profile that installs a
/// JavaScript-host implementation is only active inside one.
pub fn declare(
    comptime name: []const u8,
    comptime Signature: type,
    comptime stub: Signature,
) Signature {
    if (comptime linked) {
        return @extern(Signature, .{ .name = name, .library_name = "fx" });
    }
    return stub;
}

test "a native build answers a declaration with its stub" {
    const Stub = struct {
        fn unlinked(_: i32) callconv(.c) i32 {
            return 7;
        }
    };
    if (comptime linked) return error.SkipZigTest;
    const declared = declare("fx_sample", *const fn (i32) callconv(.c) i32, Stub.unlinked);
    try @import("std").testing.expectEqual(@as(i32, 7), declared(1));
}
