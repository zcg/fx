//! Finds the shell fx runs a command in on Windows.
//!
//! Windows has no POSIX shell. What it has, in the order this module prefers:
//!
//! 1. PowerShell 7 (`pwsh.exe`). It is the current one, it is cross-platform,
//!    and its syntax is stable. Windows PowerShell 5 (`powershell.exe`) is the
//!    older one with the well-known quoting and encoding problems, so it is
//!    never chosen when 7 is installed - and the harness never falls back to it,
//!    because a command that silently ran under the wrong shell would be worse
//!    than one that reported no shell at all.
//! 2. Git Bash, when it is installed. Unix commands people already know work
//!    there unchanged, which is the whole reason it ships with Git for Windows.
//! 3. `cmd.exe`, only when neither of the above exists.
//!
//! Every path is resolved to an absolute one before use: the shell is spawned
//! directly, so a bare name would depend on the child's search path rather than
//! on the one this module checked.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");

const Allocator = std.mem.Allocator;

pub const Kind = enum { pwsh, git_bash, cmd };

pub const Shell = struct {
    kind: Kind,
    /// Absolute path to the executable.
    path: []u8,

    pub fn deinit(self: *Shell, alloc: Allocator) void {
        alloc.free(self.path);
        self.* = undefined;
    }

    /// How the shell is told to run one command string.
    pub fn commandArgs(self: Shell) [2][]const u8 {
        return switch (self.kind) {
            // PowerShell takes `-NoProfile -Command`; `-c` is accepted as a
            // prefix abbreviation but the spelled-out flag is what the
            // documentation and every example use, and it cannot be confused
            // with a parameter name.
            .pwsh => .{ "-NoLogo", "-NoProfile" },
            .git_bash => .{ "--noprofile", "--norc" },
            .cmd => .{ "/Q", "/D" },
        };
    }

    /// The flag that introduces the command itself.
    pub fn commandFlag(self: Shell) []const u8 {
        return switch (self.kind) {
            .pwsh => "-Command",
            .git_bash => "-c",
            .cmd => "/C",
        };
    }
};

/// Windows only; other platforms keep their login shell.
pub const supported = builtin.target.os.tag == .windows;

/// The kinds a `shell` setting may name, in the order they are offered.
pub const setting_names = [_][]const u8{ "pwsh", "bash", "cmd" };

/// Resolves the shell to use, preferring PowerShell 7, then Git Bash, then cmd.
/// Returns null when none of them exists, which the caller reports rather than
/// guessing a path.
pub fn detect(alloc: Allocator) !?Shell {
    if (comptime !supported) return null;
    if (try findPwsh(alloc)) |path| return .{ .kind = .pwsh, .path = path };
    if (try findGitBash(alloc)) |path| return .{ .kind = .git_bash, .path = path };
    if (try findCmd(alloc)) |path| return .{ .kind = .cmd, .path = path };
    return null;
}

/// Resolves the shell named by a `shell` setting. An unknown or unavailable
/// name falls back to detection, so a setting that names a shell the user has
/// since uninstalled cannot make commands unrunnable.
pub fn detectPreferred(alloc: Allocator, preference: ?[]const u8) !?Shell {
    if (comptime !supported) return null;
    if (preference) |name| {
        if (std.mem.eql(u8, name, "pwsh")) {
            if (try findPwsh(alloc)) |path| return .{ .kind = .pwsh, .path = path };
        } else if (std.mem.eql(u8, name, "bash")) {
            if (try findGitBash(alloc)) |path| return .{ .kind = .git_bash, .path = path };
        } else if (std.mem.eql(u8, name, "cmd")) {
            if (try findCmd(alloc)) |path| return .{ .kind = .cmd, .path = path };
        }
    }
    return detect(alloc);
}

/// The `shell` setting name for a detected kind, for caching the first result.
pub fn settingName(kind: Kind) []const u8 {
    return switch (kind) {
        .pwsh => "pwsh",
        .git_bash => "bash",
        .cmd => "cmd",
    };
}

/// PowerShell 7 installs under Program Files; a store or scoop install puts it
/// on the path. Both are checked, absolute path first.
fn findPwsh(alloc: Allocator) !?[]u8 {
    // `envVar` returns owned memory, so every caller here frees what it reads.
    const program_files = envVar(alloc, "ProgramFiles");
    defer if (program_files) |root| alloc.free(root);
    const candidates = [_][]const u8{
        "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
        "C:\\Program Files\\PowerShell\\7-preview\\pwsh.exe",
    };
    for (candidates) |candidate| {
        if (try existingFile(alloc, candidate)) |path| return path;
    }
    if (program_files) |root| {
        const joined = try std.Io.Dir.path.join(alloc, &.{ root, "PowerShell", "7", "pwsh.exe" });
        defer alloc.free(joined);
        if (try existingFile(alloc, joined)) |path| return path;
    }
    return try searchPath(alloc, "pwsh.exe");
}

/// Git for Windows installs under Program Files, under the local app data
/// directory for a user install, or under a package manager's own tree. PATH is
/// consulted last, because a shimmed install may expose only `git.exe` there.
fn findGitBash(alloc: Allocator) !?[]u8 {
    const candidates = [_][]const u8{
        "C:\\Program Files\\Git\\bin\\bash.exe",
        "C:\\Program Files\\Git\\usr\\bin\\bash.exe",
        "C:\\Program Files (x86)\\Git\\bin\\bash.exe",
    };
    for (candidates) |candidate| {
        if (try existingFile(alloc, candidate)) |path| return path;
    }
    if (envVar(alloc, "LOCALAPPDATA")) |local| {
        defer alloc.free(local);
        const joined = try std.Io.Dir.path.join(alloc, &.{ local, "Programs", "Git", "bin", "bash.exe" });
        defer alloc.free(joined);
        if (try existingFile(alloc, joined)) |path| return path;
    }
    // A package manager keeps its packages in a tree of its own, and the bash
    // it ships is not on PATH. These are the trees Scoop and Chocolatey use.
    if (homeDir(alloc)) |home| {
        defer alloc.free(home);
        const scoop = try std.Io.Dir.path.join(alloc, &.{ home, "scoop", "apps", "git", "current", "bin", "bash.exe" });
        defer alloc.free(scoop);
        if (try existingFile(alloc, scoop)) |path| return path;
    }
    if (envVar(alloc, "SCOOP")) |scoop_root| {
        defer alloc.free(scoop_root);
        const scoop = try std.Io.Dir.path.join(alloc, &.{ scoop_root, "apps", "git", "current", "bin", "bash.exe" });
        defer alloc.free(scoop);
        if (try existingFile(alloc, scoop)) |path| return path;
    }
    const choco = "C:\\ProgramData\\chocolatey\\lib\\git.install\\tools\\bin\\bash.exe";
    if (try existingFile(alloc, choco)) |path| return path;
    if (try searchPath(alloc, "bash.exe")) |path| {
        // `C:\Windows\System32\bash.exe` is the WSL launcher, not Git Bash: it
        // runs a Linux distribution, so a POSIX command there sees a different
        // filesystem than the workspace. Only a bash under a Git tree counts.
        defer alloc.free(path);
        if (isGitBashPath(path)) return try alloc.dupe(u8, path);
    }
    if (try bashBesideGit(alloc)) |path| return path;
    return try bashFromRegistry(alloc);
}

/// True when the path is a Git-for-Windows bash rather than the WSL launcher.
fn isGitBashPath(path: []const u8) bool {
    const needles = [_][]const u8{ "\\git\\", "\\git\\usr\\", "\\programs\\git\\", "\\scoop\\apps\\git\\" };
    for (needles) |needle| {
        if (containsIgnoreCase(path, needle)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matches = true;
        for (needle, 0..) |byte, offset| {
            if (std.ascii.toLower(haystack[start + offset]) != std.ascii.toLower(byte)) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

/// Git for Windows records its install directory in the registry, which is how
/// Windows itself finds it. This is the last resort: it works when the install
/// is somewhere none of the fixed locations name and PATH exposes only a shim.
fn bashFromRegistry(alloc: Allocator) !?[]u8 {
    const roots = [_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "SOFTWARE\\GitForWindows", .value = "InstallPath" },
        .{ .key = "SOFTWARE\\WOW6432Node\\GitForWindows", .value = "InstallPath" },
    };
    for (roots) |root| {
        const install = queryRegistryString(alloc, root.key, root.value) orelse continue;
        defer alloc.free(install);
        const joined = try std.Io.Dir.path.join(alloc, &.{ install, "bin", "bash.exe" });
        defer alloc.free(joined);
        if (try existingFile(alloc, joined)) |path| return path;
    }
    return null;
}

/// Reads an environment variable through Win32 directly.
///
/// `io_mod.getenv` reads the environment block the process entry point was
/// handed, which a library caller such as a probe or an embedded host may not
/// have installed. The detection runs on the command path, where the value has
/// to be there, so it asks the system for it.
fn envVar(alloc: Allocator, name: []const u8) ?[]u8 {
    const name_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, name) catch return null;
    defer alloc.free(name_w);
    var buffer: [32 * 1024]u8 = undefined;
    const written = GetEnvironmentVariableW(name_w.ptr, &buffer, buffer.len);
    if (written == 0 or written > buffer.len) return null;
    const wide: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, buffer[0 .. written * @sizeOf(u16)]));
    return std.unicode.utf16LeToUtf8Alloc(alloc, wide) catch null;
}

extern "kernel32" fn GetEnvironmentVariableW(
    name: [*:0]const u16,
    buffer: [*]u8,
    size: windows.DWORD,
) callconv(.winapi) windows.DWORD;

/// The user's home directory, from the system rather than from a possibly
/// uninstalled environment block.
fn homeDir(alloc: Allocator) ?[]u8 {
    if (envVar(alloc, "USERPROFILE")) |value| return value;
    if (envVar(alloc, "HOME")) |value| return value;
    return null;
}

const windows = std.os.windows;

const HKEY_CURRENT_USER: windows.HKEY = @ptrFromInt(0x80000001);
const HKEY_LOCAL_MACHINE: windows.HKEY = @ptrFromInt(0x80000002);
const KEY_READ: windows.REGSAM = @bitCast(@as(u32, 0x20019));
const REG_SZ: windows.DWORD = 1;

extern "advapi32" fn RegOpenKeyExW(
    hkey: windows.HKEY,
    sub_key: [*:0]const u16,
    options: windows.DWORD,
    sam: windows.REGSAM,
    result: *windows.HKEY,
) callconv(.winapi) windows.LSTATUS;

extern "advapi32" fn RegQueryValueExW(
    hkey: windows.HKEY,
    value_name: [*:0]const u16,
    reserved: ?*windows.DWORD,
    value_type: *windows.DWORD,
    data: ?[*]u8,
    data_size: *windows.DWORD,
) callconv(.winapi) windows.LSTATUS;

extern "advapi32" fn RegCloseKey(hkey: windows.HKEY) callconv(.winapi) windows.LSTATUS;

/// Reads a REG_SZ value. The caller owns the returned UTF-8 string.
fn queryRegistryString(alloc: Allocator, sub_key: []const u8, value_name: []const u8) ?[]u8 {
    const key_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, sub_key) catch return null;
    defer alloc.free(key_w);
    const name_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, value_name) catch return null;
    defer alloc.free(name_w);

    const hives = [_]windows.HKEY{ HKEY_LOCAL_MACHINE, HKEY_CURRENT_USER };
    for (hives) |hive| {
        var handle: windows.HKEY = undefined;
        if (RegOpenKeyExW(hive, key_w.ptr, 0, KEY_READ, &handle) != 0) continue;
        defer _ = RegCloseKey(handle);
        var kind: windows.DWORD = 0;
        var size: windows.DWORD = 0;
        if (RegQueryValueExW(handle, name_w.ptr, null, &kind, null, &size) != 0) continue;
        if (kind != REG_SZ or size == 0 or size > 32 * 1024) continue;
        const buffer = alloc.alloc(u8, size) catch return null;
        defer alloc.free(buffer);
        if (RegQueryValueExW(handle, name_w.ptr, null, &kind, buffer.ptr, &size) != 0) continue;
        const wide: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, buffer));
        var end = wide.len;
        while (end > 0 and wide[end - 1] == 0) end -= 1;
        if (end == 0) continue;
        return std.unicode.utf16LeToUtf8Alloc(alloc, wide[0..end]) catch null;
    }
    return null;
}

/// A package manager keeps git and bash under one directory tree, and only git
/// is shimmed onto PATH. Resolving git's real location finds its sibling bash.
fn bashBesideGit(alloc: Allocator) !?[]u8 {
    const git = (try searchPath(alloc, "git.exe")) orelse return null;
    defer alloc.free(git);
    // A shim sits in the package manager's own bin directory, not in the tree
    // the package lives in, so the shim's target is read from the adjacent
    // `.shim` file before falling back to the directory layout.
    if (try bashFromShim(alloc, git)) |path| return path;
    // git.exe sits in <root>/bin or <root>/cmd; bash.exe is in <root>/bin.
    var dir = std.Io.Dir.path.dirname(git) orelse return null;
    if (std.mem.eql(u8, std.Io.Dir.path.basename(dir), "cmd")) {
        dir = std.Io.Dir.path.dirname(dir) orelse return null;
    }
    const root = std.Io.Dir.path.dirname(dir) orelse return null;
    const joined = try std.Io.Dir.path.join(alloc, &.{ root, "bin", "bash.exe" });
    defer alloc.free(joined);
    return try existingFile(alloc, joined);
}

/// A Scoop shim is a small executable beside a `.shim` file naming the real
/// path, as in `path = D:\...\apps\git\current\bin\git.exe`.
fn bashFromShim(alloc: Allocator, git_path: []const u8) !?[]u8 {
    const dir = std.Io.Dir.path.dirname(git_path) orelse return null;
    const stem = std.Io.Dir.path.stem(std.Io.Dir.path.basename(git_path));
    const shim_path = try std.Io.Dir.path.join(alloc, &.{ dir, try std.mem.concat(alloc, u8, &.{ stem, ".shim" }) });
    defer alloc.free(shim_path);
    var file = std.Io.Dir.cwd().openFile(io_mod.getIo(), shim_path, .{}) catch return null;
    defer file.close(io_mod.getIo());
    const text = io_mod.readFileToEnd(alloc, &file, 8192) catch return null;
    defer alloc.free(text);
    // The line reads `path = <real executable>`.
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "path")) continue;
        const equals = std.mem.findScalar(u8, trimmed, '=') orelse continue;
        const target = std.mem.trim(u8, trimmed[equals + 1 ..], " \t\r\"");
        if (target.len == 0) continue;
        const target_dir = std.Io.Dir.path.dirname(target) orelse continue;
        // The target is <root>/cmd/git.exe or <root>/bin/git.exe; bash.exe is
        // in <root>/bin, so only the `cmd` case steps up.
        var root = target_dir;
        if (std.mem.eql(u8, std.Io.Dir.path.basename(root), "cmd")) {
            root = std.Io.Dir.path.dirname(root) orelse continue;
        }
        const joined = try std.Io.Dir.path.join(alloc, &.{ root, "bin", "bash.exe" });
        defer alloc.free(joined);
        if (try existingFile(alloc, joined)) |path| return path;
    }
    return null;
}

fn findCmd(alloc: Allocator) !?[]u8 {
    if (envVar(alloc, "SystemRoot")) |root| {
        defer alloc.free(root);
        const joined = try std.Io.Dir.path.join(alloc, &.{ root, "System32", "cmd.exe" });
        defer alloc.free(joined);
        if (try existingFile(alloc, joined)) |path| return path;
    }
    return try existingFile(alloc, "C:\\Windows\\System32\\cmd.exe");
}

/// Returns an owned absolute path when `path` names a file.
fn existingFile(alloc: Allocator, path: []const u8) !?[]u8 {
    var file = std.Io.Dir.cwd().openFile(io_mod.getIo(), path, .{}) catch return null;
    file.close(io_mod.getIo());
    return try alloc.dupe(u8, path);
}

/// Looks a bare executable name up on PATH, honoring PATHEXT.
fn searchPath(alloc: Allocator, name: []const u8) !?[]u8 {
    const path = envVar(alloc, "PATH") orelse return null;
    defer alloc.free(path);
    var it = std.mem.splitScalar(u8, path, ';');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const joined = try std.Io.Dir.path.join(alloc, &.{ dir, name });
        if (try existingFile(alloc, joined)) |found| {
            alloc.free(joined);
            return found;
        }
        alloc.free(joined);
    }
    return null;
}

test "a resolved shell names an absolute executable" {
    if (comptime !supported) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var shell = (try detect(alloc)) orelse return error.SkipZigTest;
    defer shell.deinit(alloc);
    try std.testing.expect(std.Io.Dir.path.isAbsolute(shell.path));
    try std.testing.expect(shell.path.len > 4);
}
