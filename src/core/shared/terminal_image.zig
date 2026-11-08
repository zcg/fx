//! Which inline image protocol the terminal understands.
//!
//! An image in a terminal is not text: the terminal has to be told to draw
//! pixels over the character grid. There is no single standard, so fx asks the
//! environment and picks the one protocol the terminal names, in the order the
//! terminals themselves are most specific about it:
//!
//! - Kitty's graphics protocol (`KITTY_WINDOW_ID`, or `TERM` naming a kitty
//!   derivative). It draws a real raster image and reflows it on resize.
//! - iTerm2's `OSC 1337 File=`. WezTerm and mintty also accept it.
//! - Sixel (`DECDMAC`-era raster), which xterm and mlterm speak.
//! - Nothing. The caller falls back to a text badge, which is what every
//!   terminal can show.
//!
//! Detection is by environment only. There is no reliable capability query for
//! graphics, and sending a probe to a terminal that does not understand it
//! prints garbage into the middle of the conversation.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");

pub const Protocol = enum {
    kitty,
    iterm2,
    sixel,
    none,

    /// Whether `renderInline` can draw pixels for this protocol.
    pub fn drawsImages(self: Protocol) bool {
        return self != .none;
    }
};

/// Pick the protocol from the environment. `getenv` is a parameter so a host
/// that supplies its own environment, such as the WebAssembly runtime, answers
/// for itself.
///
/// The environment is only a hint. A terminal can implement Kitty graphics
/// without naming itself in `TERM` or setting `KITTY_WINDOW_ID`, which is what
/// ELYTerminal does: it reports `TERM=xterm-256color` and marks itself with its
/// own `ELY_*` variables instead. `probeKitty` asks the terminal directly and
/// is what settles the question when a TTY is available.
pub fn detect(getenv: anytype) Protocol {
    // Kitty sets KITTY_WINDOW_ID in every kitty window, including ones started
    // over ssh, so it is the most direct signal there is.
    if (getenv("KITTY_WINDOW_ID")) |value| {
        if (value.len != 0) return .kitty;
    }
    // A terminal that reports itself through TERM, which is what a kitty
    // derivative or a kitty-compatible multiplexer does.
    if (getenv("TERM")) |term| {
        if (mentions(term, "kitty") or mentions(term, "ghostty")) return .kitty;
    }
    // ELYTerminal draws Kitty graphics while calling itself an xterm, so its
    // own variables are the only signal it gives. `ELY_CMD_PROMPT` is set in
    // every one of its shells.
    if (getenv("ELY_CMD_PROMPT") != null) return .kitty;
    if (getenv("ELY_TERMINAL") != null) return .kitty;
    // Windows Terminal speaks Sixel rather than Kitty, and marks itself with
    // `WT_SESSION` in every tab.
    if (getenv("WT_SESSION") != null) return .sixel;
    // WezTerm and mintty both answer to iTerm2's protocol.
    if (getenv("TERM_PROGRAM")) |program| {
        if (std.ascii.eqlIgnoreCase(program, "iTerm.app") or
            std.ascii.eqlIgnoreCase(program, "WezTerm") or
            std.ascii.eqlIgnoreCase(program, "mintty"))
        {
            return .iterm2;
        }
    }
    if (getenv("WEZTERM_EXECUTABLE")) |value| {
        if (value.len != 0) return .iterm2;
    }
    if (getenv("TERM")) |term| {
        if (mentionsSixel(term)) return .sixel;
    }
    return .none;
}

fn mentions(term: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    if (term.len < needle.len) return false;
    var index: usize = 0;
    while (index + needle.len <= term.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(term[index..][0..needle.len], needle)) return true;
    }
    return false;
}

fn mentionsSixel(term: []const u8) bool {
    return mentions(term, "sixel") or mentions(term, "mlterm") or
        mentions(term, "xterm-direct") or mentions(term, "yaft");
}

/// The protocol for this process, computed once.
pub fn current() Protocol {
    if (comptime builtin.target.os.tag == .wasi) return .none;
    if (probed) |answer| return answer;
    return detect(envLookup);
}

/// What the terminal answered when it was asked at startup. Null until a
/// caller installs an answer.
var probed: ?Protocol = null;

/// Records what the terminal said about itself. `probeKitty` supplies the
/// answer; a host without a TTY passes null and the environment decides.
pub fn installProbe(answer: ?Protocol) void {
    probed = answer;
}

/// The query a terminal answers when it can draw Kitty graphics.
pub const kitty_query = "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\";

/// Asks the terminal whether it draws Kitty graphics, and reads its answer.
///
/// The environment is not enough: a terminal can implement the protocol without
/// setting `KITTY_WINDOW_ID` or naming itself in `TERM`, which is what happened
/// with the ELYTerminal build this was written against. The protocol's own
/// query is the only answer that reflects what the terminal will actually do.
///
/// Returns `.kitty` when the terminal answers `OK`, and null when it stays
/// silent or the handles are not a terminal. The caller keeps its environment
/// answer as the fallback, because the probe needs a TTY.
pub fn probeKitty(
    zio: std.Io,
    in_fd: std.posix.fd_t,
    out_fd: std.posix.fd_t,
    timeout_ms: u64,
) ?Protocol {
    if (comptime builtin.target.os.tag == .wasi) return null;

    io_mod.writeFd(out_fd, kitty_query) catch return null;

    var buffer: [256]u8 = undefined;
    var waited_ms: u64 = 0;
    while (waited_ms < timeout_ms) : (waited_ms += 20) {
        std.Io.sleep(zio, .fromMilliseconds(20), .awake) catch {};
        const read = io_mod.readFd(in_fd, &buffer) catch return null;
        if (read == 0) continue;
        const got = buffer[0..read];
        // The reply is `ESC_Gi=31;OK ESC\`. `OK` alone is enough: nothing else
        // in the stream uses that word as an answer here.
        if (std.mem.find(u8, got, "OK") != null) return .kitty;
        return null;
    }
    return null;
}

fn envLookup(name: []const u8) ?[]const u8 {
    return io_mod.getenv(name);
}

test "kitty wins when the window id or the terminal name says so" {
    const Env = struct {
        kitty_window: ?[]const u8 = null,
        term: ?[]const u8 = null,
        term_program: ?[]const u8 = null,
        wezterm: ?[]const u8 = null,

        fn get(self: *const @This(), _: *const @This(), name: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, name, "KITTY_WINDOW_ID")) return self.kitty_window;
            if (std.mem.eql(u8, name, "TERM")) return self.term;
            if (std.mem.eql(u8, name, "TERM_PROGRAM")) return self.term_program;
            if (std.mem.eql(u8, name, "WEZTERM_EXECUTABLE")) return self.wezterm;
            return null;
        }
    };

    var env = Env{ .kitty_window = "1" };
    try std.testing.expectEqual(Protocol.kitty, detect(Env.get, &env));

    env = .{ .term = "xterm-kitty" };
    try std.testing.expectEqual(Protocol.kitty, detect(Env.get, &env));

    env = .{ .term = "xterm-ghostty" };
    try std.testing.expectEqual(Protocol.kitty, detect(Env.get, &env));

    env = .{ .term_program = "iTerm.app" };
    try std.testing.expectEqual(Protocol.iterm2, detect(Env.get, &env));

    env = .{ .term_program = "WezTerm" };
    try std.testing.expectEqual(Protocol.iterm2, detect(Env.get, &env));

    env = .{ .wezterm = "/usr/bin/wezterm" };
    try std.testing.expectEqual(Protocol.iterm2, detect(Env.get, &env));

    env = .{ .term = "xterm-sixel" };
    try std.testing.expectEqual(Protocol.sixel, detect(Env.get, &env));

    env = .{ .term = "xterm-256color" };
    try std.testing.expectEqual(Protocol.none, detect(Env.get, &env));

    env = .{};
    try std.testing.expectEqual(Protocol.none, detect(Env.get, &env));
}
