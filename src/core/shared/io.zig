const std = @import("std");
const builtin = @import("builtin");
const darwin_process_spawn = @import("darwin_process_spawn.zig");
const profile_paths = @import("profile_paths.zig");

pub const RawEnviron = [*:null]const ?[*:0]const u8;

// Process globals are installed before threads start and remain read-only.
var real_io: ?std.Io = null;

// Fallback used by non-test code only when setIo was not called. The real
// application installs `real_io` from main before spawning threads.
var fallback_threaded: std.Io.Threaded = .init_single_threaded;

var global_environ: ?*const std.process.Environ.Map = null;
var global_environ_block: ?std.process.Environ.Block = null;
var global_raw_environ: ?RawEnviron = null;
// Set when another program owns the process environment and may change it,
// as Node.js does for the N-API addon: the environment is read from libc at
// each use and no pointer to it is kept.
var global_libc_environ: bool = false;

pub fn setIo(zio: std.Io) void {
    real_io = process_io_for(builtin.target.os.tag, zio);
}

fn process_io_for(comptime os_tag: std.Target.Os.Tag, zio: std.Io) std.Io {
    return if (os_tag == .macos) darwin_process_spawn.wrap(zio) else zio;
}

// Thousands of call sites reach `getIo`, so it stays out of line: an inlined
// copy at each one costs more code than the call. The fallback is reached only
// before main installs the process Io and in tests.
pub noinline fn getIo() std.Io {
    if (real_io) |zio| return zio;
    return fallbackIo();
}

noinline fn fallbackIo() std.Io {
    if (comptime builtin.is_test) return process_io_for(builtin.target.os.tag, std.testing.io);
    return process_io_for(builtin.target.os.tag, fallback_threaded.io());
}

/// Opens an absolute directory path without following any path component.
/// The caller owns the returned directory handle.
pub fn openDirAbsoluteNoFollow(path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    if (!std.Io.Dir.path.isAbsolute(path)) return error.InvalidPath;
    var components = std.Io.Dir.path.componentIterator(path);
    const root = components.root() orelse return error.InvalidPath;
    var component = components.next() orelse {
        var root_options = options;
        root_options.follow_symlinks = false;
        return openRootNoFollow(root, root_options);
    };

    var dir = try openRootNoFollow(root, .{ .follow_symlinks = false });
    errdefer dir.close(getIo());
    while (components.next()) |next_component| {
        if (std.mem.eql(u8, component.name, ".") or std.mem.eql(u8, component.name, "..")) {
            return error.InvalidPath;
        }
        const next_dir = try openDirStep(dir, component.name, .{ .follow_symlinks = false });
        dir.close(getIo());
        dir = next_dir;
        component = next_component;
    }
    if (std.mem.eql(u8, component.name, ".") or std.mem.eql(u8, component.name, "..")) {
        return error.InvalidPath;
    }
    var final_options = options;
    final_options.follow_symlinks = false;
    const result = try openDirStep(dir, component.name, final_options);
    dir.close(getIo());
    return result;
}

/// Opens an absolute path that must not lead out of itself.
///
/// On Windows a drive root can be a mounted volume, so the same reparse-point
/// reasoning as `openDirStep` applies before any component is walked.
fn openRootNoFollow(root: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    if (comptime builtin.target.os.tag == .windows) {
        // `OPEN_REPARSE_POINT` makes a later stat of the handle fail with
        // `STATUS_REPARSE_POINT_NOT_RESOLVED`, so the flag is not used here.
        return std.Io.Dir.openDirAbsolute(getIo(), root, .{ .follow_symlinks = true });
    }
    return std.Io.Dir.openDirAbsolute(getIo(), root, options);
}

/// Opens one directory component without leaving the tree the caller named.
///
/// A Windows file system attaches reparse points to directories for ordinary
/// reasons: a package manager's link farm, a user's own junction, and a
/// redirected profile folder are all one. Opening those with
/// `OPEN_REPARSE_POINT` succeeds, but statting the resulting handle then fails
/// with `STATUS_REPARSE_POINT_NOT_RESOLVED` (`0xc0000280`), which surfaces as
/// `error.Unexpected`. Zig's `follow_symlinks = false` sets exactly that flag.
///
/// So a component is opened with following allowed and the result is checked
/// instead: the resolved path must stay inside the directory the component was
/// found in. A link that leaves is refused, and a junction that stays is opened
/// normally, which is the behaviour the callers want.
fn openDirStep(dir: std.Io.Dir, name: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    if (comptime builtin.target.os.tag == .windows) {
        if (!options.follow_symlinks) return openReparsePointInside(dir, name);
        return dir.openDir(getIo(), name, options);
    }
    return dir.openDir(getIo(), name, options);
}

/// Opens a directory that may be a reparse point, and confirms it did not leave
/// the directory it was found in.
///
/// The check composes the child's path from the parent's resolved path rather
/// than asking the kernel for the opened handle's path: `GetFinalPathNameByHandle`
/// refuses a handle opened with `OPEN_REPARSE_POINT`, which is the very case this
/// exists for. Comparing the composed path catches a link that redirects outside,
/// and lets a junction that stays inside through.
fn openReparsePointInside(dir: std.Io.Dir, name: []const u8) !std.Io.Dir {
    if (comptime builtin.target.os.tag != .windows) return error.UnsupportedReparsePointType;

    const parent_path = dirRealpathAlloc(std.heap.page_allocator, dir, ".") catch
        return error.UnsupportedReparsePointType;
    defer std.heap.page_allocator.free(parent_path);

    // Open with following allowed, then verify the result still lies beneath the
    // parent. The resolved child path comes from the platform's own resolver.
    const opened = dir.openDir(getIo(), name, .{ .follow_symlinks = true }) catch
        return error.UnsupportedReparsePointType;
    errdefer opened.close(getIo());

    const opened_path = dirRealpathAlloc(std.heap.page_allocator, opened, ".") catch
        return error.UnsupportedReparsePointType;
    defer std.heap.page_allocator.free(opened_path);
    if (!pathIsInside(parent_path, opened_path)) return error.UnsupportedReparsePointType;
    return opened;
}

/// Whether `child` lies beneath `parent`, comparing whole path components.
fn pathIsInside(parent: []const u8, child: []const u8) bool {
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (child.len == parent.len) return true;
    const boundary = child[parent.len];
    return boundary == std.Io.Dir.path.sep or boundary == '/' or boundary == '\\';
}

test "Darwin process I/O replaces only processSpawn with stable storage" {
    const original = std.testing.io;
    const selected = process_io_for(.macos, original);
    const selected_again = process_io_for(.macos, original);

    try std.testing.expect(selected.userdata == original.userdata);
    try std.testing.expect(selected.vtable == selected_again.vtable);
    inline for (@typeInfo(std.Io.VTable).@"struct".field_names) |field_name| {
        if (comptime std.mem.eql(u8, field_name, "processSpawn")) {
            try std.testing.expect(@field(selected.vtable, field_name) != @field(original.vtable, field_name));
        } else {
            try std.testing.expectEqual(@field(original.vtable, field_name), @field(selected.vtable, field_name));
        }
    }
}

test "getIo applies Darwin process selection to the test fallback" {
    if (builtin.target.os.tag != .macos) return error.SkipZigTest;

    const previous = real_io;
    real_io = null;
    defer real_io = previous;

    const selected = getIo();
    try std.testing.expect(selected.userdata == std.testing.io.userdata);
    try std.testing.expect(selected.vtable.processSpawn != std.testing.io.vtable.processSpawn);
}

test "getIo Darwin test fallback runs a child through the selected backend" {
    if (builtin.target.os.tag != .macos) return error.SkipZigTest;

    const previous = real_io;
    real_io = null;
    defer real_io = previous;

    const alloc = std.testing.allocator;
    const io = getIo();
    const result = try std.process.run(alloc, io, .{
        .argv = &.{ "/usr/bin/printf", "get-io-spawn-ok" },
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    switch (result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTermination,
    }
    try std.testing.expectEqualStrings("get-io-spawn-ok", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "non-Darwin process I/O keeps the original vtable" {
    const original = std.testing.io;
    const selected = process_io_for(.linux, original);

    try std.testing.expect(selected.userdata == original.userdata);
    try std.testing.expect(selected.vtable == original.vtable);
}

test "openDirAbsoluteNoFollow rejects unsafe path components" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(getIo(), "real/child");
    try writeTempFile(tmp.dir, "plain-file", "not a directory");
    tmp.dir.symLink(std.testing.io, "real", "linked", .{ .is_directory = true }) catch |err| {
        if (err == error.AccessDenied or err == error.FileSystem) return error.SkipZigTest;
        return err;
    };

    const root = try dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const linked_child = try std.Io.Dir.path.join(alloc, &.{ root, "linked/child" });
    defer alloc.free(linked_child);
    const missing = try std.Io.Dir.path.join(alloc, &.{ root, "missing" });
    defer alloc.free(missing);
    const wrong_kind = try std.Io.Dir.path.join(alloc, &.{ root, "plain-file" });
    defer alloc.free(wrong_kind);

    if (openDirAbsoluteNoFollow(linked_child, .{})) |dir| {
        dir.close(getIo());
        return error.TestExpectedError;
    } else |err| switch (err) {
        error.NotDir, error.SymLinkLoop => {},
        else => return err,
    }
    try std.testing.expectError(error.FileNotFound, openDirAbsoluteNoFollow(missing, .{}));
    try std.testing.expectError(error.NotDir, openDirAbsoluteNoFollow(wrong_kind, .{}));
}

/// Opens an existing regular file without following the final symlink and
/// without waiting on a special file that races the initial metadata check.
/// The caller owns the returned file.
pub fn openExistingRegularFile(
    dir: std.Io.Dir,
    sub_path: []const u8,
    mode: std.Io.Dir.OpenFileOptions.Mode,
) !std.Io.File {
    return openExistingRegularFileWithPolicy(dir, sub_path, .{
        .mode = mode,
        .final_symlink = .no_follow,
        .hardlinks = .reject,
    });
}

/// Opens an existing read-only regular file according to `final_symlink`.
/// Hardlinks are accepted. Following a link does not authorize its target;
/// the caller owns that policy and the returned file.
pub fn openExistingReadOnlyRegularFile(
    dir: std.Io.Dir,
    sub_path: []const u8,
    final_symlink: FinalSymlinkPolicy,
) !std.Io.File {
    return openExistingRegularFileWithPolicy(dir, sub_path, .{
        .mode = .read_only,
        .final_symlink = final_symlink,
        .hardlinks = .allow,
    });
}

pub const FinalSymlinkPolicy = enum {
    no_follow,
    follow,
};

const HardlinkPolicy = enum {
    reject,
    allow,
};

const RegularFileOpenPolicy = struct {
    mode: std.Io.Dir.OpenFileOptions.Mode,
    final_symlink: FinalSymlinkPolicy,
    hardlinks: HardlinkPolicy,
};

fn openExistingRegularFileWithPolicy(
    dir: std.Io.Dir,
    sub_path: []const u8,
    policy: RegularFileOpenPolicy,
) !std.Io.File {
    const initial = try dir.statFile(getIo(), sub_path, .{
        .follow_symlinks = policy.final_symlink == .follow,
    });
    // A lookup that races an atomic replacement can return the replaced file
    // after its last link is gone. Apply the opened-file policy, so a
    // read-only open accepts that snapshot as the check after the open does.
    try verifyOpenedRegularFileWithPolicy(initial, policy);

    if (comptime builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) {
        var file = try dir.openFile(getIo(), sub_path, .{
            .mode = policy.mode,
            .allow_directory = false,
            .follow_symlinks = policy.final_symlink == .follow,
        });
        errdefer file.close(getIo());
        const stat = try file.stat(getIo());
        try verifyOpenedRegularFileWithPolicy(stat, policy);
        return file;
    }

    var flags: std.posix.O = .{
        .ACCMODE = switch (policy.mode) {
            .read_only => .RDONLY,
            .write_only => .WRONLY,
            .read_write => .RDWR,
        },
        .NOFOLLOW = policy.final_symlink == .no_follow,
        .NONBLOCK = true,
    };
    if (@hasField(std.posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    if (@hasField(std.posix.O, "LARGEFILE")) flags.LARGEFILE = true;
    if (@hasField(std.posix.O, "NOCTTY")) flags.NOCTTY = true;

    const fd = std.posix.openat(dir.handle, sub_path, flags, 0) catch |err| switch (err) {
        error.NoDevice, error.SymLinkLoop, error.NotDir => return error.DurablePathUnsafe,
        else => return err,
    };
    var file = std.Io.File{
        .handle = fd,
        .flags = .{ .nonblocking = true },
    };
    errdefer file.close(getIo());
    const stat = try file.stat(getIo());
    try verifyOpenedRegularFileWithPolicy(stat, policy);
    try makeFileBlocking(&file);
    return file;
}

pub fn verifyOpenedRegularFile(
    stat: std.Io.File.Stat,
    mode: std.Io.Dir.OpenFileOptions.Mode,
) !void {
    return verifyOpenedRegularFileWithPolicy(stat, .{
        .mode = mode,
        .final_symlink = .no_follow,
        .hardlinks = .reject,
    });
}

fn verifyOpenedRegularFileWithPolicy(stat: std.Io.File.Stat, policy: RegularFileOpenPolicy) !void {
    if (stat.kind != .file) {
        return error.DurablePathUnsafe;
    }
    if (policy.hardlinks == .reject and stat.nlink > 1) {
        return error.DurablePathUnsafe;
    }
    if (policy.hardlinks == .reject and policy.mode != .read_only and stat.nlink != 1) {
        return error.DurablePathUnsafe;
    }
}

fn makeFileBlocking(file: *std.Io.File) !void {
    const current = while (true) {
        const rc = std.posix.system.fcntl(
            file.handle,
            std.posix.F.GETFL,
            @as(usize, 0),
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => break @as(usize, @intCast(rc)),
            .INTR => continue,
            else => return error.FileControlFailed,
        }
    };
    const nonblock = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    while (true) {
        const rc = std.posix.system.fcntl(
            file.handle,
            std.posix.F.SETFL,
            current & ~nonblock,
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.FileControlFailed,
        }
    }
    file.flags.nonblocking = false;
}

test "read-only regular files remain valid when atomic replacement unlinks the descriptor" {
    if (comptime builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) {
        return error.SkipZigTest;
    }
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(getIo(), .{ .sub_path = "target", .data = "old" });

    var file = try openExistingRegularFile(tmp.dir, "target", .read_only);
    defer file.close(getIo());
    try tmp.dir.writeFile(getIo(), .{ .sub_path = "replacement", .data = "new" });
    try tmp.dir.rename("replacement", tmp.dir, "target", getIo());

    const stat = try file.stat(getIo());
    try std.testing.expectEqual(@as(u64, 0), stat.nlink);
    try verifyOpenedRegularFile(stat, .read_only);
    try std.testing.expectError(
        error.DurablePathUnsafe,
        verifyOpenedRegularFile(stat, .read_write),
    );
    const bytes = try readFileToEnd(alloc, &file, 16);
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings("old", bytes);
}

test "read-only opens accept a file that a concurrent atomic replacement unlinks" {
    if (comptime builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) {
        return error.SkipZigTest;
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(getIo(), .{ .sub_path = "target", .data = "v" });
    const Replacer = struct {
        dir: std.Io.Dir,
        stop: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            while (!self.stop.load(.acquire)) {
                self.dir.writeFile(getIo(), .{ .sub_path = "next", .data = "v" }) catch return;
                self.dir.rename("next", self.dir, "target", getIo()) catch return;
            }
        }
    };
    var replacer: Replacer = .{ .dir = tmp.dir };
    const thread = try std.Thread.spawn(.{}, Replacer.run, .{&replacer});
    defer {
        replacer.stop.store(true, .release);
        thread.join();
    }
    // Some lookups see the replaced file after its last link is gone.
    for (0..5000) |_| {
        var file = try openExistingRegularFile(tmp.dir, "target", .read_only);
        file.close(getIo());
    }
}

test "read-only regular file policy accepts hardlinks while durable policy rejects" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(getIo(), .{ .sub_path = "target", .data = "metadata" });
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.linkat(tmp.dir.handle, "target", tmp.dir.handle, "alias", 0),
    );

    try std.testing.expectError(
        error.DurablePathUnsafe,
        openExistingRegularFile(tmp.dir, "target", .read_only),
    );
    var file = try openExistingReadOnlyRegularFile(tmp.dir, "target", .no_follow);
    defer file.close(getIo());
    const bytes = try readFileToEnd(alloc, &file, 64);
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings("metadata", bytes);
}

test "opened file path evidence rejects a deleted handle" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(getIo(), .{ .sub_path = "target", .data = "metadata" });

    var file = try openExistingReadOnlyRegularFile(tmp.dir, "target", .no_follow);
    defer file.close(getIo());
    try tmp.dir.deleteFile(getIo(), "target");
    try std.testing.expectError(error.HandlePathUnavailable, openedFilePathAlloc(alloc, file));
}

pub fn setEnvironMap(m: *const std.process.Environ.Map) void {
    global_environ = m;
    global_environ_block = null;
    global_raw_environ = null;
    global_libc_environ = false;
}

pub fn setEnvironBlock(block: std.process.Environ.Block) void {
    global_environ = null;
    global_environ_block = block;
    global_raw_environ = null;
    global_libc_environ = false;
}

/// Installs the environment `main` received. libc never frees that array,
/// so it stays readable even after the process changes its environment.
pub fn setRawEnviron(raw: RawEnviron) void {
    global_environ = null;
    global_environ_block = null;
    global_raw_environ = raw;
    global_libc_environ = false;
}

/// Reads the environment from libc at each use, for a library loaded into a
/// process whose host can change the environment at any time. Growing the
/// environment lets libc move its array and free the old one, so no pointer
/// to it is kept between uses.
pub fn setLibcEnviron() void {
    global_environ = null;
    global_environ_block = null;
    global_raw_environ = null;
    global_libc_environ = true;
}

/// Test-only: removes the installed environment, returning to the state a
/// test binary starts in. `getenv` then finds nothing, as with an empty map,
/// but child processes inherit the test runner's environment instead of none.
/// A fixture that installs its own environment calls this on teardown, so a
/// later test sees the same environment whichever tests ran before it.
pub fn resetEnvironForTest() void {
    if (comptime !builtin.is_test) @compileError("resetEnvironForTest is test-only");
    global_environ = null;
    global_environ_block = null;
    global_raw_environ = null;
    global_libc_environ = false;
}

pub fn getenv(key: []const u8) ?[]const u8 {
    if (global_environ) |m| return m.get(key);
    if (global_environ_block) |block| return getenvFromBlock(block, key);
    if (global_raw_environ) |raw| return getenvFromLibc(key) orelse getenvFromRaw(raw, key);
    if (global_libc_environ) {
        if (getenvFromLibc(key)) |value| return value;
        // getenvFromLibc copies the key into a 128-byte buffer.
        if (key.len < 128) return null;
        return getenvFromRaw(liveLibcEnviron() orelse return null, key);
    }
    return null;
}

/// The environment array libc holds now, valid only until the process next
/// changes its environment.
///
/// Windows has no `environ`: the process environment block holds the strings,
/// and `std.c.getenv` reads them. A caller that needs the whole block gets null
/// here, which sends it through `getenvFromLibc` for the keys it asks about.
fn liveLibcEnviron() ?RawEnviron {
    if (comptime !builtin.link_libc) return null;
    if (comptime builtin.target.os.tag == .windows) return null;
    return @ptrCast(std.c.environ);
}

/// The home directory fx keeps its own files under: `HOME` when it is an
/// absolute path, otherwise null. An empty or relative `HOME` counts as
/// unset, so fx never builds profile paths relative to the current folder.
/// Child processes still inherit `HOME` unchanged.
pub fn homeDir() ?[]const u8 {
    // With HOME unset, FX_HOME alone names fx's files, so its parent serves.
    const home = homeDirectoryEnv() orelse return profile_paths.fxHomeParent();
    if (!std.Io.Dir.path.isAbsolute(home)) return null;
    return home;
}

/// The environment variable that names this account's home directory.
///
/// Windows sets `USERPROFILE` and usually leaves `HOME` unset, so reading only
/// `HOME` would put fx's profile in the working directory there. `HOME` is still
/// checked first, because a user who sets it on Windows means it.
fn homeDirectoryEnv() ?[]const u8 {
    if (getenv("HOME")) |home| {
        if (home.len != 0) return home;
    }
    if (comptime builtin.target.os.tag == .windows) {
        if (getenv("USERPROFILE")) |profile| {
            if (profile.len != 0) return profile;
        }
        // A service account can have neither, and `HOMEDRIVE` plus `HOMEPATH`
        // is what those sessions still carry. The two are joined into a buffer
        // that outlives the call, because a home directory is read repeatedly
        // and never freed.
        return joinedHomeDrive();
    }
    return null;
}

/// Caches `HOMEDRIVE` plus `HOMEPATH` the first time it is needed.
///
/// The result is process-global exact like the environment it came from: it is
/// read once, kept for the life of the process, and never mutated afterwards.
/// Only Windows reaches it, and only when neither `HOME` nor `USERPROFILE` is
/// set.
fn joinedHomeDrive() ?[]const u8 {
    const S = struct {
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var length: usize = 0;
        var ready = false;
        var present = false;
    };
    if (S.ready) return if (S.present) S.buffer[0..S.length] else null;
    S.ready = true;

    const drive = getenv("HOMEDRIVE") orelse return null;
    const path = getenv("HOMEPATH") orelse return null;
    if (drive.len == 0 or path.len == 0) return null;
    if (drive.len + path.len > S.buffer.len) return null;
    @memcpy(S.buffer[0..drive.len], drive);
    @memcpy(S.buffer[drive.len..][0..path.len], path);
    S.length = drive.len + path.len;
    S.present = true;
    return S.buffer[0..S.length];
}

/// A scratch directory for temporary files, without a trailing separator.
///
/// POSIX callers read `TMPDIR` and fall back to `/tmp`. Windows names it `TEMP`
/// or `TMP` and has no `/tmp`, so asking `GetTempPath` is the only way that
/// always answers.
pub fn tempDir(alloc: std.mem.Allocator) ![]u8 {
    if (comptime builtin.target.os.tag == .windows) {
        var wide: [windows_path_max_wide]u16 = undefined;
        const len = windows_temp.GetTempPathW(wide.len, &wide);
        if (len == 0 or len >= wide.len) return error.TempDirUnavailable;
        const path = try std.unicode.utf16LeToUtf8Alloc(alloc, wide[0..len]);
        defer alloc.free(path);
        return alloc.dupe(u8, std.mem.trimEnd(u8, path, "\\/"));
    }
    if (getenv("TMPDIR")) |dir| {
        if (dir.len != 0) return alloc.dupe(u8, dir);
    }
    return alloc.dupe(u8, "/tmp");
}

const windows_temp = if (builtin.target.os.tag != .windows) struct {} else struct {
    extern "kernel32" fn GetTempPathW(buffer_length: u32, buffer: [*]u16) callconv(.winapi) u32;
};

pub fn e2eFailIfDurableMutationAttempted() void {
    const enabled = getenv("FX_TEST_FAIL_ON_DURABLE_MUTATION") orelse return;
    if (!std.mem.eql(u8, enabled, "1")) return;
    std.process.exit(86);
}

pub fn environMap() ?*const std.process.Environ.Map {
    return global_environ;
}

pub const CloneEnvironMapError = std.mem.Allocator.Error ||
    std.process.Environ.CreateMapError ||
    error{EnvironmentUnavailable};

pub fn cloneEnvironMap(
    alloc: std.mem.Allocator,
) CloneEnvironMapError!std.process.Environ.Map {
    if (global_environ) |map| return map.clone(alloc);
    if (global_environ_block) |block| {
        return std.process.Environ.createMap(.{ .block = block }, alloc);
    }
    if (global_raw_environ) |raw| return mapFromRaw(alloc, raw);
    if (global_libc_environ) return mapFromRaw(alloc, liveLibcEnviron() orelse return error.EnvironmentUnavailable);
    if (comptime builtin.is_test) return std.process.Environ.createMap(std.testing.environ, alloc);
    return error.EnvironmentUnavailable;
}

/// A copy of `raw`, owned by the caller.
fn mapFromRaw(alloc: std.mem.Allocator, raw: RawEnviron) CloneEnvironMapError!std.process.Environ.Map {
    var len: usize = 0;
    while (raw[len] != null) : (len += 1) {}
    const entries: []const [*:0]const u8 = @ptrCast(raw[0..len]);
    var map = std.process.Environ.Map.init(alloc);
    errdefer map.deinit();
    try map.putPosixBlock(.{ .slice = entries });
    return map;
}

fn getenvFromBlock(block: std.process.Environ.Block, key: []const u8) ?[]const u8 {
    if (comptime builtin.target.os.tag == .windows or builtin.target.os.tag == .freestanding or builtin.target.os.tag == .other) {
        return null;
    }
    if (comptime (builtin.target.os.tag == .wasi or builtin.target.os.tag == .emscripten) and !builtin.link_libc) {
        return null;
    }

    const view = block.view();
    for (view.slice) |entry_z| {
        const entry = std.mem.sliceTo(entry_z, 0);
        if (entry.len <= key.len or entry[key.len] != '=') continue;
        if (std.mem.eql(u8, entry[0..key.len], key)) return entry[key.len + 1 ..];
    }
    return null;
}

fn getenvFromRaw(raw: RawEnviron, key: []const u8) ?[]const u8 {
    @setRuntimeSafety(false);
    var i: usize = 0;
    while (raw[i]) |entry_z| : (i += 1) {
        const entry = std.mem.sliceTo(entry_z, 0);
        if (entry.len <= key.len or entry[key.len] != '=') continue;
        if (std.mem.eql(u8, entry[0..key.len], key)) return entry[key.len + 1 ..];
    }
    return null;
}

fn getenvFromLibc(key: []const u8) ?[]const u8 {
    if (comptime !builtin.link_libc) return null;
    if (key.len >= 128) return null;

    var key_buf: [128]u8 = undefined;
    @memcpy(key_buf[0..key.len], key);
    key_buf[key.len] = 0;
    const value_z = std.c.getenv(key_buf[0..key.len :0].ptr) orelse return null;
    return std.mem.sliceTo(value_z, 0);
}

pub fn readFileToEnd(alloc: std.mem.Allocator, file: *std.Io.File, max_bytes: usize) ![]u8 {
    const zio = getIo();
    var read_buf: [8192]u8 = undefined;
    var r = file.reader(zio, &read_buf);
    // A file of exactly `max_bytes` is too long. `appendRemaining` keeps that
    // boundary, while `allocRemaining` accepts it.
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    try r.interface.appendRemaining(alloc, &content, .limited(max_bytes));
    return content.toOwnedSlice(alloc);
}

pub fn readFileToEndZ(alloc: std.mem.Allocator, file: *std.Io.File, max_bytes: usize) ![:0]u8 {
    const data = try readFileToEnd(alloc, file, max_bytes);
    errdefer alloc.free(data);
    const result = try alloc.realloc(data, data.len + 1);
    result[data.len] = 0;
    return result[0..data.len :0];
}

// Called from hundreds of sites; one out-of-line copy keeps each call small.
pub noinline fn milliTimestamp() i64 {
    const ts = std.Io.Timestamp.now(getIo(), .real);
    return @intCast(@divFloor(ts.nanoseconds, 1_000_000));
}

pub noinline fn nanoTimestamp() i128 {
    const ts = std.Io.Timestamp.now(getIo(), .real);
    return @intCast(ts.nanoseconds);
}

pub fn writeFileAtomic(alloc: std.mem.Allocator, path: []const u8, text: []const u8) !void {
    e2eFailIfDurableMutationAttempted();
    const maybe_existing_permissions = existingFilePermissions(path);
    if (maybe_existing_permissions) |existing_permissions| {
        if (deniesWrites(existing_permissions)) return error.AccessDenied;
    }
    const permissions = maybe_existing_permissions orelse .default_file;
    const temp_path = try alloc.print("{s}.tmp.{d}", .{ path, nanoTimestamp() });
    defer alloc.free(temp_path);

    var cleanup_temp = true;
    defer if (cleanup_temp) std.Io.Dir.deleteFileAbsolute(getIo(), temp_path) catch {};

    {
        var file = try std.Io.Dir.createFileAbsolute(getIo(), temp_path, .{ .truncate = true, .permissions = permissions });
        defer file.close(getIo());
        try file.writeStreamingAll(getIo(), text);
        try file.sync(getIo());
    }

    try std.Io.Dir.renameAbsolute(temp_path, path, getIo());
    cleanup_temp = false;
}

const private_dir_permissions = permissionsForMode(0o700);
const private_file_permissions = permissionsForMode(0o600);

pub const VerifiedDir = struct {
    dir: std.Io.Dir,

    pub fn close(self: *VerifiedDir) void {
        self.dir.close(getIo());
        self.* = undefined;
    }
};

fn defaultSyncFile(_: ?*anyopaque, file: std.Io.File) anyerror!void {
    try file.sync(getIo());
}

fn defaultSyncDir(_: ?*anyopaque, dir: std.Io.Dir) anyerror!void {
    try syncVerifiedDir(dir);
}

pub const DurableOps = struct {
    ctx: ?*anyopaque = null,
    sync_file: *const fn (?*anyopaque, std.Io.File) anyerror!void = defaultSyncFile,
    sync_dir: *const fn (?*anyopaque, std.Io.Dir) anyerror!void = defaultSyncDir,
    /// When set, a replace that fails before its rename also records the
    /// error that stopped it, which `DurableReplacePreRenameFailed` omits.
    pre_rename_cause: ?*?anyerror = null,
};

fn defaultTryLock(_: ?*anyopaque, file: std.Io.File) anyerror!bool {
    return file.tryLock(getIo(), .exclusive);
}

fn defaultLockNow(_: ?*anyopaque) i64 {
    return milliTimestamp();
}

fn defaultLockSleep(_: ?*anyopaque, millis: u64) void {
    sleep(millis * std.time.ns_per_ms);
}

pub const LockOps = struct {
    ctx: ?*anyopaque = null,
    try_lock: *const fn (?*anyopaque, std.Io.File) anyerror!bool = defaultTryLock,
    now_ms: *const fn (?*anyopaque) i64 = defaultLockNow,
    sleep_ms: *const fn (?*anyopaque, u64) void = defaultLockSleep,
};

pub const TimedAdvisoryLock = struct {
    file: std.Io.File,

    pub fn release(self: *TimedAdvisoryLock) void {
        self.file.unlock(getIo());
        self.file.close(getIo());
        self.* = undefined;
    }
};

fn validateRelativeLeaf(name: []const u8) !void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
        return error.DurablePathUnsafe;
    }
    if (std.mem.findAny(u8, name, "/\\") != null) return error.DurablePathUnsafe;
}

fn verifyPrivateRegularFile(file: std.Io.File) !void {
    const stat = try file.stat(getIo());
    if (stat.kind != .file or stat.nlink != 1) return error.DurablePathUnsafe;
    if (comptime modeIsEnforced) {
        if (stat.permissions.toMode() & 0o777 != 0o600) return error.PrivateStatePermissionsUnsupported;
    }
}

/// The mode-independent half of `verifyPrivateRegularFile`: the entry is a
/// regular file with a single link. Platforms without POSIX modes check only
/// this, because a mode they cannot set is not evidence of a restriction.
fn verifyPrivateRegularFilePath(file: std.Io.File) !void {
    const stat = try file.stat(getIo());
    if (stat.kind != .file or stat.nlink != 1) return error.DurablePathUnsafe;
}

fn verifyPrivateDirectory(dir: std.Io.Dir) !void {
    const stat = try dir.stat(getIo());
    if (stat.kind != .directory) return error.DurablePathUnsafe;
    if (comptime modeIsEnforced) {
        if (stat.permissions.toMode() & 0o777 != 0o700) return error.PrivateStatePermissionsUnsupported;
    }
}

/// The handle must come from an `openDir` that requested iteration. Linux returns an
/// `O_PATH` descriptor otherwise, and `fsync` rejects those with `EBADF`.
pub fn syncVerifiedDir(dir: std.Io.Dir) !void {
    if (comptime builtin.target.os.tag == .windows) return error.OperationUnsupported;
    while (true) {
        const rc = std.c.fsync(dir.handle);
        if (rc == 0) return;
        switch (std.c.errno(rc)) {
            .INTR => continue,
            .INVAL, .OPNOTSUPP => return error.OperationUnsupported,
            .NOSPC => return error.NoSpaceLeft,
            .DQUOT => return error.DiskQuota,
            .ROFS => return error.ReadOnlyFileSystem,
            else => return error.DirectorySyncFailed,
        }
    }
}

fn openOrCreateVerifiedPrivateChild(parent: std.Io.Dir, name: []const u8) !VerifiedDir {
    e2eFailIfDurableMutationAttempted();
    try validateRelativeLeaf(name);
    const zio = getIo();

    var created = false;
    var dir = parent.openDir(zio, name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => blk: {
            parent.createDir(zio, name, private_dir_permissions) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => {},
                else => return create_err,
            };
            created = true;
            break :blk try parent.openDir(zio, name, .{
                .iterate = true,
                .follow_symlinks = false,
            });
        },
        error.SymLinkLoop, error.NotDir => return error.DurablePathUnsafe,
        else => return err,
    };
    errdefer dir.close(zio);

    if (comptime modeIsEnforced) {
        setPermissions(dir, private_dir_permissions) catch return error.PrivateStatePermissionsUnsupported;
    }
    try verifyPrivateDirectory(dir);
    if (created) try syncVerifiedDir(parent);
    return .{ .dir = dir };
}

/// Opens an existing private folder, checked as
/// `openOrCreateVerifiedPrivateDir` checks it, without creating it: null
/// when it is missing.
pub fn openVerifiedPrivateDirIfPresent(parent: *VerifiedDir, name: []const u8) !?VerifiedDir {
    try validateRelativeLeaf(name);
    var dir = parent.dir.openDir(getIo(), name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.SymLinkLoop, error.NotDir => return error.DurablePathUnsafe,
        else => return err,
    };
    errdefer dir.close(getIo());
    try verifyPrivateDirectory(dir);
    return .{ .dir = dir };
}

/// Opens an existing folder that need not be private: a real folder, never
/// through a symlink, whatever its mode, as an old release left a profile's
/// folders readable by others. Null when it is missing.
pub fn openRealDirIfPresent(parent: *VerifiedDir, name: []const u8) !?VerifiedDir {
    try validateRelativeLeaf(name);
    var dir = parent.dir.openDir(getIo(), name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.SymLinkLoop, error.NotDir => return error.DurablePathUnsafe,
        else => return err,
    };
    errdefer dir.close(getIo());
    if ((try dir.stat(getIo())).kind != .directory) return error.DurablePathUnsafe;
    return .{ .dir = dir };
}

pub fn openOrCreateVerifiedPrivateDir(parent: *VerifiedDir, name: []const u8) !VerifiedDir {
    return openOrCreateVerifiedPrivateChild(parent.dir, name);
}

pub fn openOrCreateVerifiedPrivateDirFromDir(parent: std.Io.Dir, name: []const u8) !VerifiedDir {
    return openOrCreateVerifiedPrivateChild(parent, name);
}

fn validateReplaceTarget(dir: std.Io.Dir, name: []const u8) !void {
    const stat = dir.statFile(getIo(), name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        error.SymLinkLoop, error.NotDir => return error.DurablePathUnsafe,
        else => return err,
    };
    if (stat.kind != .file or stat.nlink != 1) return error.DurablePathUnsafe;
    if (deniesWrites(stat.permissions)) return error.AccessDenied;
}

fn cleanupVerifiedTemp(dir: std.Io.Dir, name: []const u8) void {
    const stat = dir.statFile(getIo(), name, .{ .follow_symlinks = false }) catch return;
    if (stat.kind != .file or stat.nlink != 1) return;
    dir.deleteFile(getIo(), name) catch {};
}

pub fn durableReplaceVerified(
    alloc: std.mem.Allocator,
    dir: *VerifiedDir,
    name: []const u8,
    bytes: []const u8,
) !void {
    return durableReplaceVerifiedWithOps(alloc, dir, name, bytes, .{});
}

fn preRenameFailed(ops: DurableOps, cause: anyerror) error{DurableReplacePreRenameFailed} {
    if (ops.pre_rename_cause) |slot| slot.* = cause;
    return error.DurableReplacePreRenameFailed;
}

/// The errors a durable write may report.
///
/// Every platform reports the same set so a caller can switch on one list. The
/// permission variants are only produced where a POSIX mode is enforced, but
/// naming them everywhere keeps the contract stable: a Windows caller still
/// compiles the arm it will never take.
pub const DurableError = error{
    OutOfMemory,
    AccessDenied,
    PermissionDenied,
    FileNotFound,
    NotDir,
    SymLinkLoop,
    NameTooLong,
    BadPathName,
    InputOutput,
    NoSpaceLeft,
    ReadOnlyFileSystem,
    FileTooBig,
    DeviceBusy,
    FileBusy,
    Unseekable,
    NotOpenForWriting,
    PrivateStatePermissionsUnsupported,
    DurablePathUnsafe,
    DurableReplacePostRenameFailed,
    DurableReplacePreRenameFailed,
    Unexpected,
};

pub fn durableReplaceVerifiedWithOps(
    alloc: std.mem.Allocator,
    dir: *VerifiedDir,
    name: []const u8,
    bytes: []const u8,
    ops: DurableOps,
) !void {
    e2eFailIfDurableMutationAttempted();
    try validateRelativeLeaf(name);
    validateReplaceTarget(dir.dir, name) catch |err| switch (err) {
        error.DurablePathUnsafe, error.AccessDenied => return err,
        else => return preRenameFailed(ops, err),
    };

    var random_bytes: [16]u8 = undefined;
    getIo().random(&random_bytes);
    const suffix = std.fmt.bytesToHex(random_bytes, .lower);
    const temp_name = try alloc.print(".{s}.tmp.{s}", .{ name, suffix });
    defer alloc.free(temp_name);

    var temp_exists = false;
    defer if (temp_exists) cleanupVerifiedTemp(dir.dir, temp_name);

    var file = dir.dir.createFile(getIo(), temp_name, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
        .permissions = private_file_permissions,
        .resolve_beneath = true,
    }) catch |err| return preRenameFailed(ops, err);
    temp_exists = true;
    defer file.close(getIo());

    if (comptime modeIsEnforced) {
        setPermissions(file, private_file_permissions) catch return error.PrivateStatePermissionsUnsupported;
    }
    if (comptime modeIsEnforced) {
        verifyPrivateRegularFile(file) catch |err| switch (err) {
            error.DurablePathUnsafe, error.PrivateStatePermissionsUnsupported => return err,
            else => return preRenameFailed(ops, err),
        };
    } else {
        // Windows cannot mark a file `0600`, so the mode half of this check has
        // no member there and only the path check runs.
        verifyPrivateRegularFilePath(file) catch |err| return preRenameFailed(ops, err);
    }
    file.writeStreamingAll(getIo(), bytes) catch |err| return preRenameFailed(ops, err);
    ops.sync_file(ops.ctx, file) catch |err| return preRenameFailed(ops, err);
    dir.dir.rename(temp_name, dir.dir, name, getIo()) catch |err| return preRenameFailed(ops, err);
    temp_exists = false;

    // The file was just created and renamed into place, so this only confirms it
    // landed as a single regular file. On Windows, asking without following sets
    // `OPEN_REPARSE_POINT`, and any later query on such a handle fails with
    // `STATUS_REPARSE_POINT_NOT_RESOLVED`, which would report a successful write
    // as an indeterminate one.
    const final_stat = dir.dir.statFile(getIo(), name, .{ .follow_symlinks = modeIsEnforced }) catch {
        return error.DurableReplacePostRenameFailed;
    };
    if (final_stat.kind != .file) {
        return error.DurableReplacePostRenameFailed;
    }
    // A POSIX filesystem reports links this way, and a count other than one there
    // means the name is shared with something fx does not control. Windows has no
    // equivalent guarantee for a freshly renamed file, so the check is limited to
    // the platforms where it means what it says.
    if (comptime modeIsEnforced) {
        if (final_stat.nlink != 1) return error.DurableReplacePostRenameFailed;
    }
    if (comptime modeIsEnforced) {
        if (final_stat.permissions.toMode() & 0o777 != 0o600) return error.DurableReplacePostRenameFailed;
    }
    // A directory sync is what makes a rename durable on a POSIX filesystem.
    // Windows cannot sync a directory handle at all, which is a platform limit
    // rather than a failed write, so that one answer is not a failure here.
    ops.sync_dir(ops.ctx, dir.dir) catch |err| switch (err) {
        error.OperationUnsupported => {},
        else => return error.DurableReplacePostRenameFailed,
    };
}

fn openOrCreatePrivateLockFile(dir: *VerifiedDir, name: []const u8) !std.Io.File {
    try validateRelativeLeaf(name);
    const zio = getIo();

    var file = dir.dir.openFile(zio, name, .{
        .mode = .read_write,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => blk: {
            const created = dir.dir.createFile(zio, name, .{
                .read = true,
                .truncate = false,
                .exclusive = true,
                .permissions = private_file_permissions,
                .resolve_beneath = true,
            }) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => break :blk try dir.dir.openFile(zio, name, .{
                    .mode = .read_write,
                    .allow_directory = false,
                    .follow_symlinks = false,
                    .resolve_beneath = true,
                }),
                else => return create_err,
            };
            if (comptime modeIsEnforced) {
                setPermissions(created, private_file_permissions) catch {
                    created.close(zio);
                    return error.PrivateStatePermissionsUnsupported;
                };
            }
            syncVerifiedDir(dir.dir) catch {
                created.close(zio);
                return error.DirectorySyncFailed;
            };
            break :blk created;
        },
        error.SymLinkLoop, error.IsDir, error.NotDir => return error.DurablePathUnsafe,
        else => return err,
    };
    errdefer file.close(zio);
    try verifyPrivateRegularFile(file);
    return file;
}

pub fn acquireTimedAdvisoryLock(
    dir: *VerifiedDir,
    name: []const u8,
    deadline_ms: u64,
) !TimedAdvisoryLock {
    return acquireTimedAdvisoryLockControlled(dir, name, deadline_ms, null, .{});
}

pub fn acquireTimedAdvisoryLockWithOps(
    dir: *VerifiedDir,
    name: []const u8,
    deadline_ms: u64,
    ops: LockOps,
) !TimedAdvisoryLock {
    return acquireTimedAdvisoryLockControlled(dir, name, deadline_ms, null, ops);
}

pub fn acquireTimedAdvisoryLockCancellable(
    dir: *VerifiedDir,
    name: []const u8,
    deadline_ms: u64,
    cancel_flag: *const std.atomic.Value(bool),
) !TimedAdvisoryLock {
    return acquireTimedAdvisoryLockControlled(
        dir,
        name,
        deadline_ms,
        cancel_flag,
        .{},
    );
}

pub fn acquireTimedAdvisoryLockCancellableWithOps(
    dir: *VerifiedDir,
    name: []const u8,
    deadline_ms: u64,
    cancel_flag: *const std.atomic.Value(bool),
    ops: LockOps,
) !TimedAdvisoryLock {
    return acquireTimedAdvisoryLockControlled(
        dir,
        name,
        deadline_ms,
        cancel_flag,
        ops,
    );
}

fn acquireTimedAdvisoryLockControlled(
    dir: *VerifiedDir,
    name: []const u8,
    deadline_ms: u64,
    cancel_flag: ?*const std.atomic.Value(bool),
    ops: LockOps,
) !TimedAdvisoryLock {
    const file = try openOrCreatePrivateLockFile(dir, name);
    errdefer file.close(getIo());

    const started = ops.now_ms(ops.ctx);
    const deadline: i64 = started + @as(i64, @intCast(deadline_ms));
    while (true) {
        if (cancel_flag) |flag| {
            if (flag.load(.acquire)) return error.Cancelled;
        }
        const locked = ops.try_lock(ops.ctx, file) catch |err| switch (err) {
            error.FileLocksUnsupported => return error.LockUnsupported,
            else => return err,
        };
        if (locked) return .{ .file = file };
        if (ops.now_ms(ops.ctx) >= deadline) return error.LockBusy;
        ops.sleep_ms(ops.ctx, @min(@as(u64, 10), deadline_ms));
    }
}

pub fn copyFileAtomic(alloc: std.mem.Allocator, source_path: []const u8, dest_path: []const u8) !void {
    const zio = getIo();
    var source = try std.Io.Dir.openFileAbsolute(zio, source_path, .{});
    defer source.close(zio);

    const stat = try source.stat(zio);
    if (stat.kind != .file) return error.NotRegularFile;
    if (existingFilePermissions(dest_path)) |existing_permissions| {
        if (deniesWrites(existing_permissions)) return error.AccessDenied;
    }

    const temp_path = try alloc.print("{s}.tmp.{d}", .{ dest_path, nanoTimestamp() });
    defer alloc.free(temp_path);

    var cleanup_temp = true;
    defer if (cleanup_temp) std.Io.Dir.deleteFileAbsolute(zio, temp_path) catch {};

    {
        var dest = try std.Io.Dir.createFileAbsolute(zio, temp_path, .{ .truncate = true, .permissions = stat.permissions });
        defer dest.close(zio);

        var read_buf: [8192]u8 = undefined;
        var reader = source.readerStreaming(zio, &read_buf);
        var transfer_buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = try reader.interface.readSliceShort(&transfer_buf);
            if (n == 0) break;
            try dest.writeStreamingAll(zio, transfer_buf[0..n]);
        }
        try dest.sync(zio);
    }

    try std.Io.Dir.renameAbsolute(temp_path, dest_path, zio);
    cleanup_temp = false;
}

fn existingFilePermissions(path: []const u8) ?std.Io.File.Permissions {
    const stat = std.Io.Dir.cwd().statFile(getIo(), path, .{}) catch return null;
    if (stat.kind != .file) return null;
    return stat.permissions;
}

/// Builds the permissions a new private directory or file is created with.
///
/// POSIX expresses this as a mode, so `0700` and `0600` keep other accounts
/// out. Windows has no mode: its `Permissions` is a `DWORD` of file attributes
/// whose only security-relevant bit is READONLY, and access is decided by the
/// ACL the new entry inherits from its parent. `default_dir` and
/// `default_file` therefore request nothing beyond that inherited ACL, and fx
/// must not claim a restriction it did not apply; `privateStateIsRestricted`
/// reports the difference to callers that verify it.
pub inline fn permissionsForMode(mode: u32) std.Io.File.Permissions {
    if (comptime modeIsEnforced) return std.Io.File.Permissions.fromMode(mode);
    return switch (mode & 0o040) {
        0 => .default_file,
        else => .default_dir,
    };
}

/// Whether this platform enforces the POSIX mode bits fx puts on its profile
/// state. Windows does not: its files carry an inherited ACL instead. Use this
/// to skip a mode check rather than converting one this platform cannot answer.
pub const modeIsEnforced = builtin.target.os.tag != .windows and builtin.target.os.tag != .wasi;

/// Whether the entry a permissions value describes refuses writes. POSIX reads
/// the mode's write bits. Windows reads the READONLY file attribute, which is
/// the only permission bit its `Permissions` carries.
///
/// This does not call `std.Io.File.Permissions.readOnly`. Zig 0.17.0's Windows
/// implementation of that method names `std.os.windows.FILE_ATTRIBUTE_READONLY`,
/// which the same release does not declare, so it fails to compile on Windows.
pub inline fn deniesWrites(permissions: std.Io.File.Permissions) bool {
    if (comptime modeIsEnforced) return permissions.readOnly();
    return @backingInt(permissions) & windows_readonly_attribute != 0;
}

/// The Windows READONLY file attribute, `0x1`. `std.os.windows` spells the file
/// attribute set as a packed struct rather than this constant, so fx names it.
const windows_readonly_attribute: u32 = 0x1;

/// A process id as a number, which every platform has even where `pid_t` does
/// not express one.
///
/// A POSIX `pid_t` is already a number, so this is the same value. A Windows
/// `pid_t` is an opaque handle whose pointer value is not the process id, so the
/// number has to come from `GetProcessId` or from the id a child reports. Code
/// that records, compares, or parses an id uses this type and `pidFromNumber`,
/// and only the platform edge converts to or from `pid_t`.
pub const ProcessId = u32;

/// Reads a process id from text, for a caller that stored one as digits.
pub fn parseProcessId(text: []const u8) error{InvalidProcessId}!ProcessId {
    return std.fmt.parseInt(ProcessId, text, 10) catch error.InvalidProcessId;
}

/// The number that identifies this process.
pub fn currentProcessIdNumber() ProcessId {
    return @truncate(currentProcessIdRaw());
}

fn currentProcessIdRaw() u64 {
    if (comptime builtin.target.os.tag == .windows) {
        return @intCast(windows_process.GetCurrentProcessId());
    }
    if (comptime builtin.target.os.tag == .wasi) return 0;
    return @intCast(std.c.getpid());
}

/// Turns a process id number back into the platform's `pid_t`, for the calls
/// that take one.
///
/// POSIX passes the number through. Windows has no way to turn a process id into
/// a handle: the handle it accepts for process operations comes from a spawn or
/// from `OpenProcess`, so callers there use `killProcessNumber` instead of
/// building a `pid_t`.
pub fn pidFromNumber(number: ProcessId) std.posix.pid_t {
    if (comptime builtin.target.os.tag == .windows) {
        // An opaque handle cannot be produced from an id, and no caller on
        // Windows reaches this: the process operations take the number.
        return @ptrFromInt(@as(usize, number));
    }
    return @intCast(number);
}

/// Terminates a process by its id number.
pub fn killProcessNumber(number: ProcessId) error{ ProcessNotFound, AccessDenied, Unexpected }!void {
    if (comptime builtin.target.os.tag == .windows) {
        if (number == 0) return error.ProcessNotFound;
        const process = windows_process.OpenProcess(windows_process_terminate, 0, number) orelse
            return error.ProcessNotFound;
        defer _ = windows_process.CloseHandle(process);
        if (windows_process.TerminateProcess(process, 1) == 0) return error.Unexpected;
        return;
    }
    std.posix.kill(pidFromNumber(number), std.posix.SIG.KILL) catch |err| switch (err) {
        error.ProcessNotFound => return error.ProcessNotFound,
        error.PermissionDenied => return error.AccessDenied,
        else => return error.Unexpected,
    };
}

/// This process's id, as a plain integer on every platform.
///
/// `std.c.getpid` cannot serve: on Windows `pid_t` is a `HANDLE`, so the call
/// yields `*anyopaque` and a cast that assumes a number fails to compile. The
/// Windows kernel answers with a `DWORD` of the same meaning. Callers that need
/// to name or signal a POSIX process still go through their own platform code;
/// this is only the identity a log line, a lock file, or a temporary path needs.
pub fn currentProcessId() u64 {
    if (comptime builtin.target.os.tag == .windows) {
        return @intCast(windows_process.GetCurrentProcessId());
    }
    if (comptime builtin.target.os.tag == .wasi) return 0;
    return @intCast(std.c.getpid());
}

const windows_process = if (builtin.target.os.tag != .windows) struct {} else struct {
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    extern "kernel32" fn OpenProcess(desired_access: u32, inherit_handle: c_int, process_id: u32) callconv(.winapi) ?std.posix.fd_t;
    extern "kernel32" fn TerminateProcess(process: std.posix.fd_t, exit_code: u32) callconv(.winapi) c_int;
    extern "kernel32" fn CloseHandle(handle: std.posix.fd_t) callconv(.winapi) c_int;
    extern "kernel32" fn GetExitCodeProcess(process: std.posix.fd_t, exit_code: *u32) callconv(.winapi) c_int;
    extern "kernel32" fn WaitForSingleObject(handle: std.posix.fd_t, milliseconds: u32) callconv(.winapi) u32;
};

/// Whether a process id refers to a process at all.
///
/// A POSIX pid is a small positive integer, so zero and negatives mean "none"
/// or "a process group". A Windows `pid_t` is an opaque handle pointer, which no
/// integer comparison applies to, so the only question that is well formed there
/// is whether the handle is null.
pub fn pidIsValid(pid: std.posix.pid_t) bool {
    if (comptime builtin.target.os.tag == .windows) return @intFromPtr(pid) != 0;
    return pid > 0;
}

/// Reads a Windows pid as the number the kernel reports for it, for a log line
/// or a file name. A POSIX caller should use the pid directly.
pub fn pidAsNumber(pid: std.posix.pid_t) u64 {
    if (comptime builtin.target.os.tag == .windows) {
        return @intFromPtr(pid);
    }
    return @intCast(pid);
}

/// How a waited-for child ended.
pub const ProcessExit = union(enum) {
    /// It ran to completion with this code.
    exited: u32,
    /// It was ended by this signal, on a platform that reports one.
    signaled: u32,
};

/// Waits for a child to end, or reports that it has not yet.
///
/// POSIX reaps with `waitpid`, decoding a status word, and `WNOHANG` asks
/// without blocking. Windows has no such call: a process handle ends by
/// signalling and `GetExitCodeProcess` reports the code, with `STILL_ACTIVE`
/// meaning "not yet". Both report the same three facts.
pub fn waitProcess(pid: std.posix.pid_t, block: bool) ?ProcessExit {
    if (comptime builtin.target.os.tag == .windows) return windowsWaitProcess(pid, block);
    if (comptime builtin.target.os.tag == .wasi) return null;

    var status: c_int = 0;
    const flags: c_int = if (block) 0 else std.c.W.NOHANG;
    const reaped = std.c.waitpid(pid, &status, flags);
    if (reaped <= 0) return null;
    const word: u32 = @bitCast(status);
    if (std.c.W.IFEXITED(word)) return .{ .exited = std.c.W.EXITSTATUS(word) };
    if (std.c.W.IFSIGNALED(word)) return .{ .signaled = @truncate(@backingInt(std.c.W.TERMSIG(word))) };
    return null;
}

/// The Windows form of `waitProcess`. The process id is reopened with the least
/// access that reports an exit code, because a `pid_t` there is a handle whose
/// value identifies the process rather than a handle to wait on.
fn windowsWaitProcess(pid: std.posix.pid_t, block: bool) ?ProcessExit {
    if (@intFromPtr(pid) == 0) return null;
    const process_id: u32 = @truncate(@intFromPtr(pid));
    const process = windows_process.OpenProcess(windows_process_query, 0, process_id) orelse
        return null;
    defer _ = windows_process.CloseHandle(process);

    if (block) {
        _ = windows_process.WaitForSingleObject(process, windows_infinite);
    }
    var code: u32 = 0;
    if (windows_process.GetExitCodeProcess(process, &code) == 0) return null;
    if (code == windows_process_still_active) return null;
    return .{ .exited = code };
}

/// `PROCESS_QUERY_LIMITED_INFORMATION`, the least access that reports an exit
/// code.
const windows_process_query: u32 = 0x1000;
const windows_process_still_active: u32 = 259;
const windows_infinite: u32 = 0xFFFFFFFF;

/// Terminates a process, with the meaning of a POSIX kill that cannot be caught.
///
/// Windows has no signals: `std.posix.SIG` there names CRT signals that carry no
/// `KILL`, and nothing a process can ignore stands in for one. The kernel's
/// `TerminateProcess` is the operation fx actually wants, so this is what every
/// "kill" in fx calls. A process that has already exited reports
/// `error.ProcessNotFound`, which callers treat as success.
pub fn killProcess(pid: std.posix.pid_t) error{ ProcessNotFound, AccessDenied, Unexpected }!void {
    if (comptime builtin.target.os.tag != .windows) {
        if (pid <= 0) return error.ProcessNotFound;
        std.posix.kill(pid, std.posix.SIG.KILL) catch |err| switch (err) {
            error.ProcessNotFound => return error.ProcessNotFound,
            error.PermissionDenied => return error.AccessDenied,
            else => return error.Unexpected,
        };
        return;
    }
    if (@intFromPtr(pid) == 0) return error.ProcessNotFound;
    // A Windows `pid_t` is a `HANDLE`, but the handle a child reports is not an
    // owned handle fx may terminate through, so the id is read as a number and
    // reopened with the access `TerminateProcess` requires.
    const process_id: u32 = @truncate(@intFromPtr(pid));
    const process = windows_process.OpenProcess(windows_process_terminate, 0, process_id) orelse
        return error.ProcessNotFound;
    defer _ = windows_process.CloseHandle(process);
    if (windows_process.TerminateProcess(process, 1) == 0) return error.Unexpected;
}

/// `PROCESS_TERMINATE`, the access `TerminateProcess` requires.
const windows_process_terminate: u32 = 0x0001;

/// Whether a private directory or file is actually restricted to this account.
/// Windows answers honestly with `false`, because a mode it cannot set is not
/// evidence of a restriction it did not apply.
pub fn privateStateIsRestricted(permissions: std.Io.File.Permissions) bool {
    if (comptime modeIsEnforced) return permissions.toMode() & 0o077 == 0;
    return false;
}

/// Whether the entry grants access to anyone outside its owner, which a file fx
/// keeps for one account alone must never do. Windows has no mode bits to
/// grant or withhold, so it never reports a leak this way; the ACL inherits
/// instead. Callers that must know use `privateStateIsRestricted`.
pub inline fn exposesGroupOrOther(permissions: std.Io.File.Permissions) bool {
    if (comptime modeIsEnforced) return permissions.toMode() & 0o077 != 0;
    return false;
}

/// Whether the entry's mode differs from the one fx requires. Windows has no
/// mode, so a check that only a POSIX mode can satisfy passes there rather than
/// failing a file fx could not have marked.
pub inline fn modeMismatch(permissions: std.Io.File.Permissions, expected: u32) bool {
    if (comptime modeIsEnforced) return permissions.toMode() & 0o777 != expected;
    return false;
}

/// Whether the owner cannot write the entry. POSIX reads the owner's write bit;
/// Windows reads the READONLY attribute, which is the same question there.
pub inline fn inaccessibleToWrite(permissions: std.Io.File.Permissions) bool {
    if (comptime modeIsEnforced) return permissions.toMode() & 0o200 == 0;
    return deniesWrites(permissions);
}

/// A comparable number that changes when the entry's permissions change. It is
/// not a mode: on POSIX it is the mode bits, and on Windows it is the attribute
/// word. Use it to detect that two stat results differ, never to test access.
pub inline fn permissionFingerprint(permissions: std.Io.File.Permissions) u32 {
    if (comptime modeIsEnforced) return @intCast(permissions.toMode());
    return @intCast(@backingInt(permissions));
}

pub fn sleep(ns: u64) void {
    getIo().sleep(.{ .nanoseconds = @intCast(ns) }, .real) catch {};
}

/// Reads up to `out.len` bytes from a descriptor, returning how many arrived.
///
/// `std.posix.read` cannot serve: it is a `@compileError` on Windows, where a
/// descriptor is a handle and reading goes through `std.Io.File`. That alone is
/// not enough for a console: Zig 0.17's Windows IO is built on `NtReadFile`,
/// which refuses a console handle the same way it refuses to write one, so an
/// interactive keystroke read never completes. A console is read with `ReadConsoleA`
/// here instead. Both paths return zero at end of file.
pub fn readFd(fd: std.posix.fd_t, out: []u8) !usize {
    if (comptime builtin.target.os.tag == .wasi) return error.Unexpected;
    if (comptime builtin.target.os.tag == .windows) {
        if (out.len == 0) return 0;
        // A console is read with `ReadConsoleA`, so it is tried first. Only
        // `ERROR_INVALID_HANDLE` means this is not a console.
        if (windowsReadSome(fd, out)) |count| {
            return count;
        } else |err| switch (err) {
            error.NotAConsole => {},
            else => return err,
        }
    }
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    return file.readStreaming(getIo(), &.{out});
}

/// Reads once from a console, returning what the console had.
///
/// `error.NotAConsole` means the handle is not a console input buffer.
fn windowsReadSome(fd: std.posix.fd_t, out: []u8) !usize {
    const want: u32 = @intCast(@min(out.len, @as(usize, std.math.maxInt(u32))));
    var read_count: u32 = 0;
    if (windows_console_write.ReadConsoleA(fd, out.ptr, want, &read_count, null) == 0) {
        return switch (windows_console_write.GetLastError()) {
            windows_console_write.error_invalid_handle => error.NotAConsole,
            else => error.Unexpected,
        };
    }
    return read_count;
}

/// Reads until one byte arrives, for a caller that wants a single keystroke.
/// Returns zero at end of file.
pub fn readByte(fd: std.posix.fd_t, out: *[1]u8) !usize {
    return readFd(fd, out);
}

/// Writes all of `bytes` to a descriptor.
///
/// The counterpart to `readFd`. `std.posix.write` is unavailable on Windows, so
/// this goes through `std.Io.File`. That is not enough on its own for a console:
/// Zig 0.17's Windows IO is built on `NtWriteFile`, which refuses a console
/// handle with `INVALID_HANDLE` (the source notes that console device names are
/// not handled yet), and that surfaces as `NotOpenForWriting`. A console handle
/// therefore takes `WriteConsoleA`, which is the call a console accepts.
pub fn writeFd(fd: std.posix.fd_t, bytes: []const u8) !void {
    if (comptime builtin.target.os.tag == .wasi) return error.Unexpected;
    if (comptime builtin.target.os.tag == .windows) {
        if (bytes.len == 0) return;
        // `WriteConsoleA` is the console write call, so it is tried first. Only
        // `ERROR_INVALID_HANDLE` means the handle is not a console and belongs on
        // the file path; any other error is a real write that did not happen.
        if (windowsWriteAll(fd, bytes)) |_| {
            return;
        } else |err| switch (err) {
            error.NotAConsole => {},
            else => return err,
        }
    }
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    return file.writeStreamingAll(getIo(), bytes);
}

/// Writes every byte with `WriteConsoleW`, in pieces as large as the call
/// accepts.
///
/// The console API has two write calls, and only the wide one is dependable for
/// fx's output. `WriteConsoleA` transcodes through the console's ANSI code page,
/// which mangles the bytes of a multi-byte UTF-8 character and can drop control
/// bytes such as the `ESC` that begins every escape sequence. The wide call takes
/// UTF-16 directly, so fx decodes its UTF-8 and hands over code units.
///
/// `error.NotAConsole` means the handle is not a console screen buffer, which is
/// the one case the caller handles differently. Everything else is a write that
/// did not happen.
fn windowsWriteAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    // The console takes UTF-16, so the batch is decoded into a stack buffer and
    // handed over as one call. Sizing it at a quarter of the byte count is safe:
    // UTF-8 never uses fewer than one byte per code unit, and the API caps a
    // single call at 64 Ki code units anyway.
    var wide_buffer: [4096]u16 = undefined;
    const max_wide = @min(wide_buffer.len, 0xFFFF);

    var read_total: usize = 0;
    while (read_total < bytes.len) {
        // Decode as many whole characters as the buffer holds. A trailing
        // partial character stays for the next pass, so a split never reaches
        // the console as a broken code unit.
        var used: usize = 0;
        while (read_total < bytes.len) {
            const remaining = bytes[read_total..];
            const width = utf8Width(remaining[0]);
            if (width == 0 or width > remaining.len) return error.Unexpected;
            var scratch: [4]u16 = undefined;
            const units = std.unicode.utf8ToUtf16Le(&scratch, remaining[0..width]) catch return error.Unexpected;
            if (units == 0 or used + units > max_wide) break;
            @memcpy(wide_buffer[used..][0..units], scratch[0..units]);
            used += units;
            read_total += width;
        }
        if (used == 0) return error.Unexpected;
        var written: u32 = 0;
        if (windows_console_write.WriteConsoleW(fd, &wide_buffer, @intCast(used), &written, null) == 0) {
            const last_error = windows_console_write.GetLastError();
            return switch (last_error) {
                windows_console_write.error_invalid_handle => error.NotAConsole,
                else => error.Unexpected,
            };
        }
        if (written != used) return error.Unexpected;
    }
}

/// The byte length of the UTF-8 character that starts with `first`.
fn utf8Width(first: u8) usize {
    return switch (first) {
        0x00...0x7f => 1,
        0xc0...0xdf => 2,
        0xe0...0xef => 3,
        0xf0...0xf7 => 4,
        // A continuation byte has no width of its own, so this cannot be the
        // start of a character.
        else => 0,
    };
}

/// Whether a Windows handle names a console screen buffer rather than a file,
/// pipe, or socket.
///
/// `GetConsoleMode` succeeds only for a console handle, which is the question
/// that decides whether a console-only call is needed.
pub fn isConsoleHandle(fd: std.posix.fd_t) bool {
    if (comptime builtin.target.os.tag != .windows) return false;
    var mode: u32 = 0;
    if (windows_console_write.GetConsoleMode(fd, &mode) != 0) return true;
    // `GetConsoleMode` reads the expected error for whether the handle is a
    // console at all. Logging it separates "not a console" from "console but
    // the call failed", which look the same otherwise.
    return false;
}

const windows_console_write = if (builtin.target.os.tag != .windows) struct {} else struct {
    /// The console write call. A console screen buffer accepts this and not the
    /// file call, which is the difference that made every frame fail. The wide
    /// form is used because the ANSI form transcodes through a code page.
    extern "kernel32" fn WriteConsoleW(
        console_output: std.posix.fd_t,
        buffer: [*]const u16,
        number_of_chars_to_write: u32,
        number_of_chars_written: ?*u32,
        reserved: ?*anyopaque,
    ) callconv(.winapi) c_int;
    /// The console read call, for the same reason.
    extern "kernel32" fn ReadConsoleA(
        console_input: std.posix.fd_t,
        buffer: [*]u8,
        number_of_chars_to_read: u32,
        number_of_chars_read: ?*u32,
        input_control: ?*anyopaque,
    ) callconv(.winapi) c_int;
    extern "kernel32" fn GetConsoleMode(h_console: std.posix.fd_t, mode: *u32) callconv(.winapi) c_int;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;

    /// `ERROR_INVALID_HANDLE`, how a handle that is not a console answers.
    const error_invalid_handle: u32 = 6;
};

/// Closes a descriptor.
pub fn closeFd(fd: std.posix.fd_t) void {
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    file.close(getIo());
}

/// Appends a line to `%TEMP%\fx-boot.log` when `FX_BOOT_LOG` is set.
///
/// Startup has to be diagnosable on a machine where the console cannot be
/// written, because that is exactly when the interesting failure happens. So
/// this opens the log with the raw Windows call and writes through `WriteFile`,
/// using none of the IO that the startup path is still setting up.
pub fn bootLog(text: []const u8) void {
    if (comptime builtin.target.os.tag != .windows) return;
    const enabled = getenv("FX_BOOT_LOG") orelse return;
    if (enabled.len == 0) return;
    const alloc = std.heap.page_allocator;
    const temp = tempDir(alloc) catch return;
    defer alloc.free(temp);
    const path = std.mem.concat(alloc, u8, &.{ temp, "\\fx-boot.log" }) catch return;
    defer alloc.free(path);

    var wide_path: [windows_path_max_wide]u16 = undefined;
    const wide_len = std.unicode.utf8ToUtf16Le(&wide_path, path) catch return;
    if (wide_len + 1 > wide_path.len) return;
    wide_path[wide_len] = 0;

    const handle = windows_boot.CreateFileW(
        @ptrCast(&wide_path),
        windows_boot.file_append_data,
        windows_boot.file_share_write,
        null,
        windows_boot.open_always,
        windows_boot.file_attribute_normal,
        null,
    ) orelse return;
    defer _ = windows_boot.CloseHandle(handle);
    var written: u32 = 0;
    _ = windows_boot.WriteFile(handle, text.ptr, @intCast(@min(text.len, @as(usize, std.math.maxInt(u32)))), &written, null);
}

/// Formats one boot-log line. See `bootLog`.
pub fn bootLogf(comptime fmt: []const u8, args: anytype) void {
    if (comptime builtin.target.os.tag != .windows) return;
    var buffer: [512]u8 = undefined;
    const text = std.mem.print(&buffer, fmt, args) catch return;
    bootLog(text);
}

const windows_boot = if (builtin.target.os.tag != .windows) struct {} else struct {
    const file_append_data: u32 = 0x00000004;
    const file_share_write: u32 = 0x00000002;
    const open_always: u32 = 0x00000004;
    const file_attribute_normal: u32 = 0x00000080;

    extern "kernel32" fn CreateFileW(
        name: [*:0]const u16,
        access: u32,
        share: u32,
        security_attributes: ?*anyopaque,
        disposition: u32,
        flags: u32,
        template: ?*anyopaque,
    ) callconv(.winapi) ?std.posix.fd_t;
    extern "kernel32" fn WriteFile(
        file: std.posix.fd_t,
        buffer: [*]const u8,
        bytes_to_write: u32,
        bytes_written: ?*u32,
        overlapped: ?*anyopaque,
    ) callconv(.winapi) c_int;
    extern "kernel32" fn CloseHandle(handle: std.posix.fd_t) callconv(.winapi) c_int;
};

/// Applies file permissions, on a platform that has them.
///
/// A POSIX mode is meaningful and this forwards it. Windows has no mode: its
/// `Permissions` is a `DWORD` of file attributes, and Zig 0.17 does not implement
/// the directory half of the call at all, so `Dir.setPermissions` there reaches a
/// `@panic("TODO implement dirSetPermissionsWindows")` in its own standard
/// library. Since fx cannot set an ACL through this API anyway, the right answer
/// on Windows is to leave the inherited ACL alone rather than to crash.
/// Sets permissions on a file or a directory handle, on a platform that has
/// them.
///
/// A POSIX mode is meaningful there and this forwards it. Windows has no mode:
/// its `Permissions` is a `DWORD` of file attributes, and Zig 0.17 does not
/// implement the directory half of the call at all, so `Dir.setPermissions` there
/// reaches a `@panic("TODO implement dirSetPermissionsWindows")` inside its own
/// standard library. fx cannot set an ACL through this API anyway, so the right
/// answer on Windows is to leave the inherited ACL alone rather than crash.
///
/// One function serves both handle kinds because a caller often has either: `File`
/// for an open stream, `Dir` for a folder it just made.
pub fn setPermissions(handle: anytype, permissions: std.Io.File.Permissions) error{
    PrivateStatePermissionsUnsupported,
    AccessDenied,
    Unexpected,
}!void {
    if (comptime modeIsEnforced) {
        handle.setPermissions(getIo(), permissions) catch |err| switch (err) {
            error.AccessDenied => return error.AccessDenied,
            else => return error.Unexpected,
        };
    } else {
        _ = .{ handle, permissions };
    }
}

/// Sets the permissions of the entry `sub_path` inside `dir`, on a platform that
/// has them.
///
/// The path form of `setFilePermissions`, for a caller that has a name rather
/// than an open handle. Windows reaches the same unimplemented directory call in
/// its own standard library, so it takes the same answer: leave the inherited ACL
/// alone rather than crash.
pub fn setPathPermissions(
    dir: std.Io.Dir,
    sub_path: []const u8,
    permissions: std.Io.File.Permissions,
    options: std.Io.Dir.SetPermissionsOptions,
) !void {
    if (comptime modeIsEnforced) {
        try dir.setFilePermissions(getIo(), sub_path, permissions, options);
    } else {
        _ = .{ dir, sub_path, permissions, options };
    }
}

/// Whether a file descriptor refers to a terminal.
///
/// `std.c.isatty` cannot serve: Windows has no `STDIN_FILENO`, so its `fd_t` is
/// a `HANDLE` and a call that passes a descriptor number fails to compile.
/// `File.isTty` asks the platform the right question on both. Errors mean "not a
/// terminal", which is what every caller's `isatty == 0` test already did.
pub fn isTty(fd: std.posix.fd_t) bool {
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    return (file.isTty(getIo()) catch false);
}

/// This process's standard input as a `std.Io.File`.
pub fn stdinFile() std.Io.File {
    return .{ .handle = stdinHandle(), .flags = .{ .nonblocking = false } };
}

/// This process's standard output as a `std.Io.File`.
pub fn stdoutFile() std.Io.File {
    return .{ .handle = stdoutHandle(), .flags = .{ .nonblocking = false } };
}

/// This process's standard error as a `std.Io.File`.
pub fn stderrFile() std.Io.File {
    return .{ .handle = stderrHandle(), .flags = .{ .nonblocking = false } };
}

/// The handle of a standard stream, for code that needs a descriptor value
/// rather than a `std.Io.File`.
///
/// `std.posix.STDIN_FILENO` cannot be used across platforms: Windows declares
/// no such constant, because its handles are values a process asks the kernel
/// for rather than fixed small numbers. Zig also omits `GetStdHandle`, so fx
/// declares it. Every caller that used the POSIX constant takes its value here.
pub const StandardStream = enum { input, output, stderr };

pub fn standardStreamHandle(stream: StandardStream) std.posix.fd_t {
    return switch (stream) {
        .input => stdinHandle(),
        .output => stdoutHandle(),
        .stderr => stderrHandle(),
    };
}

pub fn stdinHandle() std.posix.fd_t {
    return resolveStandardHandle(.input, std.Io.File.stdin().handle);
}

pub fn stdoutHandle() std.posix.fd_t {
    return resolveStandardHandle(.output, std.Io.File.stdout().handle);
}

pub fn stderrHandle() std.posix.fd_t {
    return resolveStandardHandle(.stderr, std.Io.File.stderr().handle);
}

/// Uses the handle the process environment block carries when it is real, and
/// asks the kernel when it is not.
///
/// `std.Io.File.stdout()` and its siblings read the process environment block,
/// which holds the handles the parent passed in. A process started with a
/// console attached but a redirected stream, which is what a pseudo console and
/// a piping shell both do, can have a null handle there for a stream the kernel
/// still serves. `GetStdHandle` is the documented way to ask for the current
/// handle and answers for both cases.
fn resolveStandardHandle(stream: StandardStream, from_block: std.posix.fd_t) std.posix.fd_t {
    if (comptime builtin.target.os.tag != .windows) return from_block;
    if (isUsableHandle(from_block)) return from_block;
    const id: u32 = switch (stream) {
        .input => windows_std_input_handle,
        .output => windows_std_output_handle,
        .stderr => windows_std_error_handle,
    };
    const from_kernel = windows_stdio.GetStdHandle(id) orelse return from_block;
    if (!isUsableHandle(from_kernel)) return from_block;
    return from_kernel;
}

/// Whether a Windows handle names a real object rather than the null or invalid
/// value a missing stream reports.
fn isUsableHandle(handle: std.posix.fd_t) bool {
    if (@intFromPtr(handle) == 0) return false;
    return @intFromPtr(handle) != std.math.maxInt(usize);
}

const windows_std_input_handle: u32 = @bitCast(@as(i32, -10));
const windows_std_output_handle: u32 = @bitCast(@as(i32, -11));
const windows_std_error_handle: u32 = @bitCast(@as(i32, -12));

const windows_stdio = if (builtin.target.os.tag != .windows) struct {} else struct {
    extern "kernel32" fn GetStdHandle(std_handle: u32) callconv(.winapi) ?std.posix.fd_t;
};

/// Whether standard input is a terminal, the check that decides whether fx may
/// put the terminal into raw mode.
pub fn stdinIsTty() bool {
    return (stdinFile().isTty(getIo()) catch false);
}

/// Whether standard error is a terminal. fx treats both streams as the gate for
/// interactive mode, because a redirected stderr would lose the prompts.
pub fn stderrIsTty() bool {
    return (stderrFile().isTty(getIo()) catch false);
}

/// Whether standard output is a terminal.
pub fn stdoutIsTty() bool {
    return (stdoutFile().isTty(getIo()) catch false);
}

/// A terminal's size in character cells.
pub const TerminalSize = struct {
    rows: u16,
    columns: u16,
};

/// Reads a terminal's size.
///
/// POSIX asks the kernel with `TIOCGWINSZ`. Windows has no such ioctl, so it
/// reads the console screen buffer's window with `GetConsoleScreenBufferInfo`.
/// A handle that is not a terminal, or a console with no window, returns
/// `error.NotATerminal` for the callers that treat that as "use a default".
pub fn terminalSize(fd: std.posix.fd_t) !TerminalSize {
    if (comptime builtin.target.os.tag == .windows) {
        var info: windows_console_info.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (windows_console_info.GetConsoleScreenBufferInfo(fd, &info) == 0) return error.NotATerminal;
        const columns = info.srWindow.Right - info.srWindow.Left + 1;
        const rows = info.srWindow.Bottom - info.srWindow.Top + 1;
        if (columns <= 0 or rows <= 0) return error.NotATerminal;
        return .{ .rows = @intCast(rows), .columns = @intCast(columns) };
    }
    if (comptime builtin.target.os.tag == .wasi) return error.NotATerminal;
    var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const request: c_int = @intCast(std.c.T.IOCGWINSZ);
    if (std.c.ioctl(fd, request, &ws) < 0) return error.NotATerminal;
    if (ws.col == 0 or ws.row == 0) return error.NotATerminal;
    return .{ .rows = ws.row, .columns = ws.col };
}

const windows_console_info = if (builtin.target.os.tag != .windows) struct {} else struct {
    const COORD = extern struct { X: i16, Y: i16 };
    const SMALL_RECT = extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 };
    const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
        dwSize: COORD,
        dwCursorPosition: COORD,
        wAttributes: u16,
        srWindow: SMALL_RECT,
        dwMaximumWindowSize: COORD,
    };
    extern "kernel32" fn GetConsoleScreenBufferInfo(
        h_console_output: std.posix.fd_t,
        console_screen_buffer_info: *CONSOLE_SCREEN_BUFFER_INFO,
    ) callconv(.winapi) c_int;
};

/// Reads terminal attributes. Linux issues the kernel ioctl directly because
/// Zig 0.17 sizes `std.posix.termios` to the kernel struct, while
/// `std.posix.tcgetattr` calls into libc, which writes its larger struct and
/// overruns the caller's stack.
pub fn tcgetattr(fd: std.posix.fd_t) std.posix.TermiosGetError!std.posix.termios {
    if (builtin.target.os.tag == .windows) return windowsConsoleAttributes(fd);
    if (builtin.target.os.tag != .linux) return std.posix.tcgetattr(fd);
    var term = std.mem.zeroes(std.posix.termios);
    while (true) switch (std.os.linux.errno(std.os.linux.tcgetattr(fd, &term))) {
        .SUCCESS => return term,
        .INTR => continue,
        .BADF => unreachable,
        .NOTTY => return error.NotATerminal,
        else => |err| return std.posix.unexpectedErrno(err),
    };
}

/// Windows has no termios. A console's behavior is one mode word per handle,
/// not the four flag sets a POSIX `termios` carries, so fx keeps the distinction
/// it actually needs, "is this console in raw mode", in a `termios` value it
/// never reads field by field on this platform. The input mode word is stored in
/// the first control-character slot, and `windowsApplyConsoleMode` takes it back
/// out. Only `tcgetattr`, `tcsetattr`, and the raw-mode helper below touch it.
fn windowsConsoleAttributes(fd: std.posix.fd_t) std.posix.TermiosGetError!std.posix.termios {
    const mode = try windowsGetConsoleMode(fd);
    var term = std.mem.zeroes(std.posix.termios);
    const bytes: [4]u8 = @bitCast(mode);
    @memcpy(term.c_cc[0..4], &bytes);
    return term;
}

/// The Windows console mode fx reads and writes. A VT-capable console keeps
/// processed output and virtual terminal processing on; raw input turns off line
/// input, echo, and Ctrl+C processing, which is the part of raw mode a console
/// can express. Window input stays on so a resize still reaches fx.
const windows_raw_input_mode: u32 = windows_enable_window_input | windows_enable_virtual_terminal_input | windows_enable_extended_flags;
const windows_cooked_input_mode: u32 = windows_enable_processed_input |
    windows_enable_line_input |
    windows_enable_echo_input |
    windows_enable_window_input |
    windows_enable_virtual_terminal_input |
    windows_enable_extended_flags;

const windows_enable_processed_input: u32 = 0x0001;
const windows_enable_line_input: u32 = 0x0002;
const windows_enable_echo_input: u32 = 0x0004;
const windows_enable_window_input: u32 = 0x0008;
const windows_enable_virtual_terminal_input: u32 = 0x0200;
const windows_enable_extended_flags: u32 = 0x0080;
const windows_enable_processed_output: u32 = 0x0001;
const windows_enable_virtual_terminal_processing: u32 = 0x0004;

const WindowsConsole = if (builtin.target.os.tag != .windows) struct {} else struct {
    extern "kernel32" fn GetConsoleMode(h_console: std.posix.fd_t, mode: *u32) callconv(.winapi) c_int;
    extern "kernel32" fn SetConsoleMode(h_console: std.posix.fd_t, mode: u32) callconv(.winapi) c_int;
    extern "kernel32" fn IsConsoleHandle(h: std.posix.fd_t) callconv(.winapi) c_int;
};

fn windowsGetConsoleMode(fd: std.posix.fd_t) std.posix.TermiosGetError!u32 {
    var mode: u32 = 0;
    if (WindowsConsole.GetConsoleMode(fd, &mode) == 0) return error.NotATerminal;
    return mode;
}

fn windowsSetConsoleMode(fd: std.posix.fd_t, mode: u32) std.posix.TermiosSetError!void {
    if (WindowsConsole.SetConsoleMode(fd, mode) == 0) return error.NotATerminal;
}

/// Whether the descriptor names a console rather than a redirected file.
pub fn isConsole(fd: std.posix.fd_t) bool {
    if (comptime builtin.target.os.tag != .windows) return isTty(fd);
    var mode: u32 = 0;
    return WindowsConsole.GetConsoleMode(fd, &mode) != 0;
}

/// Puts a Windows console into the mode fx draws with: raw input plus escape
/// processing on the output handle. The caller passes the value `tcgetattr`
/// returned so it can be restored.
pub fn windowsEnableRawConsole(
    input_fd: std.posix.fd_t,
    output_fd: std.posix.fd_t,
    saved: std.posix.termios,
) std.posix.TermiosSetError!void {
    _ = saved;
    try windowsSetConsoleMode(input_fd, windows_raw_input_mode);
    var output_mode: u32 = 0;
    if (WindowsConsole.GetConsoleMode(output_fd, &output_mode) == 0) return error.NotATerminal;
    try windowsSetConsoleMode(
        output_fd,
        output_mode | windows_enable_processed_output | windows_enable_virtual_terminal_processing,
    );
}

/// Restores the mode `windowsConsoleAttributes` captured.
pub fn windowsRestoreConsole(
    input_fd: std.posix.fd_t,
    output_fd: std.posix.fd_t,
    saved: std.posix.termios,
) void {
    var mode: u32 = 0;
    @memcpy(@as([*]u8, @ptrCast(&mode))[0..4], saved.c_cc[0..4]);
    windowsSetConsoleMode(input_fd, mode) catch {};
    _ = output_fd;
}

/// Sets terminal attributes. See `tcgetattr` for why Linux bypasses libc.
pub fn tcsetattr(
    fd: std.posix.fd_t,
    action: std.posix.TCSA,
    term: std.posix.termios,
) std.posix.TermiosSetError!void {
    if (builtin.target.os.tag == .windows) {
        // The value `tcgetattr` returned carries the console mode to restore.
        var mode: u32 = 0;
        @memcpy(@as([*]u8, @ptrCast(&mode))[0..4], term.c_cc[0..4]);
        return windowsSetConsoleMode(fd, mode);
    }
    if (builtin.target.os.tag != .linux) return std.posix.tcsetattr(fd, action, term);
    while (true) switch (std.os.linux.errno(std.os.linux.tcsetattr(fd, action, &term))) {
        .SUCCESS => return,
        .INTR => continue,
        .BADF, .INVAL => unreachable,
        .NOTTY => return error.NotATerminal,
        .IO => return error.ProcessOrphaned,
        else => |err| return std.posix.unexpectedErrno(err),
    };
}

test "tcgetattr reports a regular file as not a terminal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "plain", .{});
    defer file.close(std.testing.io);
    try std.testing.expectError(error.NotATerminal, tcgetattr(file.handle));
}

pub fn makeDirRecursive(path: []const u8) !void {
    const zio = getIo();
    if (std.Io.Dir.path.isAbsolute(path)) {
        std.Io.Dir.createDirAbsolute(zio, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                if (std.Io.Dir.path.dirname(path)) |parent| try makeDirRecursive(parent);
                try std.Io.Dir.createDirAbsolute(zio, path, .default_dir);
            },
        };
    } else {
        std.Io.Dir.cwd().createDirPath(zio, path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
}

/// Errors that resolving a path may report, so both platform branches agree on
/// one set and every caller can switch on the same names.
pub const RealpathError = error{
    FileNotFound,
    NotDir,
    SymLinkLoop,
    AccessDenied,
    PermissionDenied,
    NameTooLong,
    BadPathName,
    InputOutput,
    OutOfMemory,
    Unexpected,
};

pub fn realpathAlloc(alloc: std.mem.Allocator, path: []const u8) RealpathError![]u8 {
    if (comptime builtin.target.os.tag == .windows) {
        return windowsRealpathAlloc(alloc, path) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.FileNotFound => error.FileNotFound,
            error.AccessDenied => error.AccessDenied,
            error.PermissionDenied => error.PermissionDenied,
            error.NotDir => error.NotDir,
            error.SymLinkLoop => error.SymLinkLoop,
            error.NameTooLong => error.NameTooLong,
            error.BadPathName => error.BadPathName,
            error.InputOutput => error.InputOutput,
            else => error.Unexpected,
        };
    }
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_z = std.mem.printSentinel(&buf, "{s}", .{path}, 0) catch return error.NameTooLong;
    var result_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const ptr = std.c.realpath(path_z, &result_buf) orelse {
        return switch (std.posix.errno(-1)) {
            .NOENT => error.FileNotFound,
            .NOTDIR => error.NotDir,
            .LOOP => error.SymLinkLoop,
            .ACCES => error.AccessDenied,
            .PERM => error.PermissionDenied,
            .NAMETOOLONG => error.NameTooLong,
            .INVAL => error.BadPathName,
            .IO => error.InputOutput,
            .NOMEM => error.OutOfMemory,
            else => |err| std.posix.unexpectedErrno(err),
        };
    };
    const resolved = std.mem.sliceTo(ptr, 0);
    return alloc.dupe(u8, resolved);
}

/// Resolves `path` to its absolute, canonical form on Windows.
///
/// Windows has no `realpath`. `GetFullPathNameW` is its equivalent: it makes a
/// path absolute, collapses `.` and `..`, and normalizes separators. It does not
/// require the path to exist, so existence is checked afterwards to keep the
/// same contract the POSIX branch has.
///
/// The error set matches the POSIX branch on purpose: callers switch on these
/// names on every platform, and a Windows-only set would force each of them to
/// spell out two shapes.
fn windowsRealpathAlloc(alloc: std.mem.Allocator, path: []const u8) anyerror![]u8 {
    if (path.len == 0) return error.BadPathName;
    var wide_buffer: [windows_path_max_wide]u16 = undefined;
    const wide_len = std.unicode.utf8ToUtf16Le(&wide_buffer, path) catch return error.BadPathName;
    if (wide_len + 1 > wide_buffer.len) return error.NameTooLong;
    wide_buffer[wide_len] = 0;

    var resolved_buffer: [windows_path_max_wide]u16 = undefined;
    const resolved_len = windows_path_api.GetFullPathNameW(
        @ptrCast(&wide_buffer),
        resolved_buffer.len,
        &resolved_buffer,
        null,
    );
    if (resolved_len == 0) return error.Unexpected;
    if (resolved_len >= resolved_buffer.len) return error.NameTooLong;

    // The POSIX call fails for a path that does not exist, so this one does too.
    const invalid_attributes: u32 = 0xFFFFFFFF;
    if (windows_path_api.GetFileAttributesW(@ptrCast(&resolved_buffer)) == invalid_attributes) {
        return error.FileNotFound;
    }
    return std.unicode.utf16LeToUtf8Alloc(alloc, resolved_buffer[0..resolved_len]);
}

const windows_path_api = if (builtin.target.os.tag != .windows) struct {} else struct {
    extern "kernel32" fn GetFullPathNameW(
        file_name: [*:0]const u16,
        buffer_length: u32,
        buffer: [*]u16,
        file_part: ?*?[*:0]u16,
    ) callconv(.winapi) u32;
    extern "kernel32" fn GetFileAttributesW(file_name: [*:0]const u16) callconv(.winapi) u32;
};

fn handlePathAlloc(alloc: std.mem.Allocator, handle: std.Io.File.Handle) ![]u8 {
    if (comptime builtin.target.os.tag == .macos or builtin.target.os.tag == .ios) {
        // F_GETPATH (macOS fcntl command 50): resolve filesystem path for an fd.
        var path_buf: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
        const rc = std.c.fcntl(handle, @as(c_int, 50), @intFromPtr(&path_buf));
        if (rc == -1) return error.HandlePathUnavailable;
        return alloc.dupe(u8, std.mem.sliceTo(&path_buf, 0));
    } else if (comptime builtin.target.os.tag == .linux) {
        var fd_path_buf: [64:0]u8 = undefined;
        _ = std.mem.printSentinel(&fd_path_buf, "/proc/self/fd/{d}", .{handle}, 0) catch return error.HandlePathUnavailable;
        var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const rc = std.c.readlink(&fd_path_buf, &link_buf, link_buf.len);
        if (rc < 0) return error.HandlePathUnavailable;
        return alloc.dupe(u8, link_buf[0..@intCast(rc)]);
    } else if (comptime builtin.target.os.tag == .windows) {
        return windowsHandlePathAlloc(alloc, handle);
    } else {
        return error.HandlePathUnavailable;
    }
}

/// Resolves the path an open Windows handle names. `FILE_NAME_NORMALIZED`
/// returns the final, fully resolved path, and `VOLUME_NAME_DOS` returns it
/// with the drive letter, which `standardizeWindowsDosPath` then turns into the
/// same form `std.Io.Dir.path.isAbsolute` accepts.
fn windowsHandlePathAlloc(alloc: std.mem.Allocator, handle: std.Io.File.Handle) ![]u8 {
    var wide_buf: [windows_path_max_wide]u16 = undefined;
    const flags: u32 = 0x0 | 0x0; // FILE_NAME_NORMALIZED | VOLUME_NAME_DOS
    const len = windows_path.GetFinalPathNameByHandleW(
        handle,
        &wide_buf,
        wide_buf.len,
        flags,
    );
    // A zero return, or one past the buffer, means the path did not fit.
    if (len == 0 or len >= wide_buf.len) return error.HandlePathUnavailable;
    return standardizeWindowsDosPath(alloc, wide_buf[0..len]);
}

/// `MAX_PATH` plus room for the `\\?\` prefix and a long component, which is
/// what `GetFinalPathNameByHandleW` documents as sufficient for a normalized
/// path. A longer path returns a length past the buffer and fails closed.
const windows_path_max_wide = 32767;

const windows_path = if (builtin.target.os.tag != .windows) struct {} else struct {
    extern "kernel32" fn GetFinalPathNameByHandleW(
        h_file: std.Io.File.Handle,
        lpsz_file_path: [*]u16,
        cch_file_path: u32,
        flags: u32,
    ) callconv(.winapi) u32;
};

/// Converts the extended-length form `GetFinalPathNameByHandleW` returns, such
/// as `\\?\C:\Users\example`, into the plain `C:\Users\example` that
/// `std.Io.Dir.path` treats as absolute. The `\\?\UNC\server\share` form
/// maps to `\\server\share`.
fn standardizeWindowsDosPath(alloc: std.mem.Allocator, wide: []const u16) ![]u8 {
    const extended_prefix = [_]u16{ '\\', '\\', '?', '\\' };
    const unc_prefix = [_]u16{ 'U', 'N', 'C', '\\' };
    var body = wide;
    if (wide.len >= extended_prefix.len and std.mem.eql(u16, wide[0..extended_prefix.len], &extended_prefix)) {
        body = wide[extended_prefix.len..];
        // `\\?\UNC\server\share` becomes `\\server\share`.
        if (body.len >= unc_prefix.len and std.mem.eql(u16, body[0..unc_prefix.len], &unc_prefix)) {
            const path = try std.unicode.utf16LeToUtf8Alloc(alloc, body[unc_prefix.len..]);
            defer alloc.free(path);
            return std.mem.concat(alloc, u8, &.{ "\\\\", path });
        }
    }
    return std.unicode.utf16LeToUtf8Alloc(alloc, body);
}

/// Returns absolute path evidence reported by an already-open regular file
/// handle. The caller owns the returned path. Deleted or otherwise
/// unresolvable handles fail closed.
pub fn openedFilePathAlloc(alloc: std.mem.Allocator, file: std.Io.File) ![]u8 {
    const stat = try file.stat(getIo());
    if (stat.kind != .file or stat.nlink == 0) return error.HandlePathUnavailable;
    const path = try handlePathAlloc(alloc, file.handle);
    errdefer alloc.free(path);
    if (!std.Io.Dir.path.isAbsolute(path)) return error.HandlePathUnavailable;
    if (comptime builtin.target.os.tag == .linux) {
        if (std.mem.endsWith(u8, path, " (deleted)")) return error.HandlePathUnavailable;
    }
    return path;
}

pub fn dirRealpathAlloc(alloc: std.mem.Allocator, dir: std.Io.Dir, sub_path: []const u8) ![]u8 {
    if (comptime builtin.target.os.tag == .macos or builtin.target.os.tag == .ios) {
        const dir_path = handlePathAlloc(alloc, dir.handle) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.FileNotFound,
        };
        if (sub_path.len == 0) return dir_path;
        defer alloc.free(dir_path);
        const joined = try std.Io.Dir.path.join(alloc, &.{ dir_path, sub_path });
        defer alloc.free(joined);
        return realpathAlloc(alloc, joined);
    } else if (comptime builtin.target.os.tag == .linux) {
        const dir_path = handlePathAlloc(alloc, dir.handle) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.FileNotFound,
        };
        if (sub_path.len == 0) return dir_path;
        defer alloc.free(dir_path);
        const joined = try std.Io.Dir.path.join(alloc, &.{ dir_path, sub_path });
        defer alloc.free(joined);
        return realpathAlloc(alloc, joined);
    } else if (comptime builtin.target.os.tag == .windows) {
        const dir_path = handlePathAlloc(alloc, dir.handle) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.FileNotFound,
        };
        if (sub_path.len == 0) return dir_path;
        defer alloc.free(dir_path);
        const joined = try std.Io.Dir.path.join(alloc, &.{ dir_path, sub_path });
        defer alloc.free(joined);
        return realpathAlloc(alloc, joined);
    } else if (comptime builtin.target.os.tag == .wasi) {
        if (std.Io.Dir.path.isAbsolute(sub_path)) return alloc.dupe(u8, sub_path);
        return std.Io.Dir.path.resolveAlloc(alloc, &.{sub_path});
    } else {
        @compileError("dirRealpathAlloc not implemented for this OS");
    }
}

fn writeTempFile(dir: std.Io.Dir, name: []const u8, content: []const u8) !void {
    var file = try dir.createFile(getIo(), name, .{ .truncate = true });
    defer file.close(getIo());
    try file.writeStreamingAll(getIo(), content);
}

fn readTempFile(alloc: std.mem.Allocator, dir: std.Io.Dir, name: []const u8, max_bytes: usize) ![]u8 {
    var file = try dir.openFile(getIo(), name, .{});
    defer file.close(getIo());
    return readFileToEnd(alloc, &file, max_bytes);
}

test "getenv returns null before setEnvironMap" {
    const previous = global_environ;
    global_environ = null;
    defer global_environ = previous;

    try std.testing.expect(getenv("FX_IO_TEST") == null);
}

test "getenv returns set value after setEnvironMap" {
    const previous = global_environ;
    global_environ = null;
    defer global_environ = previous;

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("FX_IO_TEST", "present");

    setEnvironMap(&environ);
    try std.testing.expectEqualStrings("present", getenv("FX_IO_TEST").?);
    global_environ = null;
}

test "homeDir accepts only an absolute HOME" {
    const previous = global_environ;
    defer global_environ = previous;

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    setEnvironMap(&environ);
    try std.testing.expect(homeDir() == null);

    for ([_][]const u8{ "", "relative/home", "./home", "~" }) |value| {
        try environ.put("HOME", value);
        try std.testing.expect(homeDir() == null);
        // The raw value stays available to code that passes it on.
        try std.testing.expectEqualStrings(value, getenv("HOME").?);
    }

    try environ.put("HOME", "/Users/example");
    try std.testing.expectEqualStrings("/Users/example", homeDir().?);
}

test "environMap returns borrowed process environment map" {
    const previous = global_environ;
    global_environ = null;
    defer global_environ = previous;

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("FX_CORE2_IO_TEST", "present");

    setEnvironMap(&environ);
    const borrowed = environMap().?;
    try std.testing.expectEqualStrings("present", borrowed.get("FX_CORE2_IO_TEST").?);
    global_environ = null;
}

test "cloneEnvironMap falls back to the test runner environment" {
    const previous_map = global_environ;
    const previous_block = global_environ_block;
    const previous_raw = global_raw_environ;
    global_environ = null;
    global_environ_block = null;
    global_raw_environ = null;
    defer {
        global_environ = previous_map;
        global_environ_block = previous_block;
        global_raw_environ = previous_raw;
    }

    var expected = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer expected.deinit();
    var cloned = try cloneEnvironMap(std.testing.allocator);
    defer cloned.deinit();
    try std.testing.expectEqualStrings(expected.get("PATH").?, cloned.get("PATH").?);
}

test "resetEnvironForTest gives child processes the test runner environment again" {
    const previous_map = global_environ;
    const previous_block = global_environ_block;
    const previous_raw = global_raw_environ;
    const previous_libc = global_libc_environ;
    defer {
        global_environ = previous_map;
        global_environ_block = previous_block;
        global_raw_environ = previous_raw;
        global_libc_environ = previous_libc;
    }

    var empty = std.process.Environ.Map.init(std.testing.allocator);
    defer empty.deinit();
    setEnvironMap(&empty);
    resetEnvironForTest();

    try std.testing.expect(environMap() == null);
    try std.testing.expect(getenv("PATH") == null);
    var expected = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer expected.deinit();
    var cloned = try cloneEnvironMap(std.testing.allocator);
    defer cloned.deinit();
    try std.testing.expectEqual(expected.count(), cloned.count());
    try std.testing.expectEqualStrings(expected.get("PATH").?, cloned.get("PATH").?);
}

test "cloneEnvironMap owns an independent copy of map environment state" {
    const previous_map = global_environ;
    const previous_block = global_environ_block;
    const previous_raw = global_raw_environ;
    defer {
        global_environ = previous_map;
        global_environ_block = previous_block;
        global_raw_environ = previous_raw;
    }

    var source = std.process.Environ.Map.init(std.testing.allocator);
    defer source.deinit();
    try source.put("PATH", "/map/bin");
    setEnvironMap(&source);

    var cloned = try cloneEnvironMap(std.testing.allocator);
    defer cloned.deinit();
    try source.put("PATH", "/changed");
    try std.testing.expectEqualStrings("/map/bin", cloned.get("PATH").?);
}

test "cloneEnvironMap copies installed block environment state" {
    const previous_map = global_environ;
    const previous_block = global_environ_block;
    const previous_raw = global_raw_environ;
    defer {
        global_environ = previous_map;
        global_environ_block = previous_block;
        global_raw_environ = previous_raw;
    }

    var source = std.process.Environ.Map.init(std.testing.allocator);
    defer source.deinit();
    try source.put("HOME", "/block/home");
    const block = try source.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);
    setEnvironBlock(block);

    var cloned = try cloneEnvironMap(std.testing.allocator);
    defer cloned.deinit();
    try std.testing.expectEqualStrings("/block/home", cloned.get("HOME").?);
}

test "cloneEnvironMap copies installed raw environment state" {
    const previous_map = global_environ;
    const previous_block = global_environ_block;
    const previous_raw = global_raw_environ;
    defer {
        global_environ = previous_map;
        global_environ_block = previous_block;
        global_raw_environ = previous_raw;
    }

    const raw_entries = [_:null]?[*:0]const u8{
        "PATH=/raw/bin",
        "HOME=/raw/home",
    };
    setRawEnviron(@ptrCast(&raw_entries));

    var cloned = try cloneEnvironMap(std.testing.allocator);
    defer cloned.deinit();
    try std.testing.expectEqualStrings("/raw/bin", cloned.get("PATH").?);
    try std.testing.expectEqualStrings("/raw/home", cloned.get("HOME").?);
}

test "libc environment lookups follow a host that grows the environment" {
    if (comptime !builtin.link_libc) return error.SkipZigTest;
    const libc = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    };
    const previous_map = global_environ;
    const previous_block = global_environ_block;
    const previous_raw = global_raw_environ;
    const previous_libc = global_libc_environ;
    defer {
        global_environ = previous_map;
        global_environ_block = previous_block;
        global_raw_environ = previous_raw;
        global_libc_environ = previous_libc;
    }
    setLibcEnviron();

    const count = 200;
    var names: [count][32:0]u8 = undefined;
    var set: usize = 0;
    defer for (names[0..set]) |*name| {
        _ = libc.unsetenv(name);
    };
    // Enough new names that libc moves its array, as a host's writes do.
    while (set < count) : (set += 1) {
        const written = try std.mem.print(names[set][0..31], "FX_IO_LIVE_ENV_{d}", .{set});
        names[set][written.len] = 0;
        try std.testing.expectEqual(@as(c_int, 0), libc.setenv(&names[set], "live", 1));
    }

    try std.testing.expectEqualStrings("live", getenv("FX_IO_LIVE_ENV_0").?);
    try std.testing.expectEqualStrings("live", getenv("FX_IO_LIVE_ENV_199").?);
    try std.testing.expect(getenv("FX_IO_LIVE_ENV_MISSING") == null);

    var cloned = try cloneEnvironMap(std.testing.allocator);
    defer cloned.deinit();
    try std.testing.expectEqualStrings("live", cloned.get("FX_IO_LIVE_ENV_150").?);
}

test "readFileToEnd: file under cap returns full content" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(tmp.dir, "under.txt", "0123456789");

    const data = try readTempFile(alloc, tmp.dir, "under.txt", 100);
    defer alloc.free(data);
    try std.testing.expectEqual(@as(usize, 10), data.len);
    try std.testing.expectEqualStrings("0123456789", data);
}

test "readFileToEnd: file at exact cap returns error.StreamTooLong" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(tmp.dir, "exact.txt", "0123456789");

    if (readTempFile(alloc, tmp.dir, "exact.txt", 10)) |data| {
        defer alloc.free(data);
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(error.StreamTooLong, err);
    }
}

test "readFileToEnd: file over cap returns error.StreamTooLong" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(tmp.dir, "over.txt", "0123456789");

    if (readTempFile(alloc, tmp.dir, "over.txt", 9)) |data| {
        defer alloc.free(data);
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(error.StreamTooLong, err);
    }
}

test "readFileToEndZ returns null-terminated slice" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(tmp.dir, "sentinel.txt", "hello");

    var file = try tmp.dir.openFile(getIo(), "sentinel.txt", .{});
    defer file.close(getIo());
    const data = try readFileToEndZ(alloc, &file, 100);
    defer alloc.free(data);
    try std.testing.expectEqual(@as(usize, 5), data.len);
    try std.testing.expectEqualStrings("hello", data);
    try std.testing.expectEqual(@as(u8, 0), data.ptr[data.len]);
}

test "timestamp wrappers return plausible real-clock values" {
    try std.testing.expect(milliTimestamp() > 0);
    try std.testing.expect(nanoTimestamp() > 0);
}

test "writeFileAtomic replaces file content and leaves no temp file behind" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const file_path = try std.Io.Dir.path.join(alloc, &.{ root, "state.json" });
    defer alloc.free(file_path);

    try writeFileAtomic(alloc, file_path, "first");
    try writeFileAtomic(alloc, file_path, "second");

    var file = try std.Io.Dir.openFileAbsolute(getIo(), file_path, .{});
    defer file.close(getIo());
    const content = try readFileToEnd(alloc, &file, 128);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("second", content);

    var check_dir = try std.Io.Dir.openDirAbsolute(getIo(), root, .{ .iterate = true });
    defer check_dir.close(getIo());
    var iter = check_dir.iterate();
    var count: usize = 0;
    while (try iter.next(getIo())) |entry| {
        try std.testing.expect(std.mem.find(u8, entry.name, ".tmp.") == null);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "writeFileAtomic preserves existing file permissions" {
    if (comptime @import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const file_path = try std.Io.Dir.path.join(alloc, &.{ root, "script.sh" });
    defer alloc.free(file_path);

    try writeFileAtomic(alloc, file_path, "first");
    try std.Io.Dir.cwd().setFilePermissions(getIo(), file_path, permissionsForMode(0o755), .{});
    try writeFileAtomic(alloc, file_path, "second");

    const stat = try std.Io.Dir.cwd().statFile(getIo(), file_path, .{});
    if (comptime modeIsEnforced) try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), stat.permissions.toMode() & 0o777);
}

test "copyFileAtomic copies through temp file and cleans up" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const source_path = try std.Io.Dir.path.join(alloc, &.{ root, "source.txt" });
    defer alloc.free(source_path);
    const dest_path = try std.Io.Dir.path.join(alloc, &.{ root, "dest.txt" });
    defer alloc.free(dest_path);

    try writeFileAtomic(alloc, source_path, "source");
    try copyFileAtomic(alloc, source_path, dest_path);

    var file = try std.Io.Dir.openFileAbsolute(getIo(), dest_path, .{});
    defer file.close(getIo());
    const content = try readFileToEnd(alloc, &file, 128);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("source", content);

    var check_dir = try std.Io.Dir.openDirAbsolute(getIo(), root, .{ .iterate = true });
    defer check_dir.close(getIo());
    var iter = check_dir.iterate();
    while (try iter.next(getIo())) |entry| {
        try std.testing.expect(std.mem.find(u8, entry.name, ".tmp.") == null);
    }
}

test "copyFileAtomic failed replacement leaves existing destination intact" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const source_path = try std.Io.Dir.path.join(alloc, &.{ root, "source.txt" });
    defer alloc.free(source_path);
    const dest_dir = try std.Io.Dir.path.join(alloc, &.{ root, "dest" });
    defer alloc.free(dest_dir);

    try writeFileAtomic(alloc, source_path, "source");
    try std.Io.Dir.cwd().createDirPath(getIo(), dest_dir);
    if (copyFileAtomic(alloc, source_path, dest_dir)) {
        return error.TestExpectedError;
    } else |_| {}

    var check_dir = try std.Io.Dir.openDirAbsolute(getIo(), root, .{ .iterate = true });
    defer check_dir.close(getIo());
    var iter = check_dir.iterate();
    while (try iter.next(getIo())) |entry| {
        try std.testing.expect(std.mem.find(u8, entry.name, ".tmp.") == null);
    }
}

test "dirRealpathAlloc resolves tmp file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(tmp.dir, "resolved.txt", "content");

    const resolved = try dirRealpathAlloc(alloc, tmp.dir, "resolved.txt");
    defer alloc.free(resolved);
    try std.testing.expect(std.Io.Dir.path.isAbsolute(resolved));
    try std.testing.expect(std.mem.endsWith(u8, resolved, std.Io.Dir.path.sep_str ++ "resolved.txt"));
}

test "realpathAlloc on nonexistent path returns FileNotFound" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const missing = try std.Io.Dir.path.join(alloc, &.{ root, "missing-realpath-target" });
    defer alloc.free(missing);

    try std.testing.expectError(error.FileNotFound, realpathAlloc(alloc, missing));
}

test "realpathAlloc distinguishes non-directory and symlink-loop paths" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(tmp.dir, "file", "content");
    try tmp.dir.symLink(getIo(), "loop", "loop", .{});
    const root = try dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const not_dir = try std.Io.Dir.path.join(alloc, &.{ root, "file/child" });
    defer alloc.free(not_dir);
    const loop = try std.Io.Dir.path.join(alloc, &.{ root, "loop/child" });
    defer alloc.free(loop);

    try std.testing.expectError(error.NotDir, realpathAlloc(alloc, not_dir));
    try std.testing.expectError(error.SymLinkLoop, realpathAlloc(alloc, loop));
}

const DurableFailureState = struct {
    fail_temp_sync: bool = false,
    fail_parent_sync: bool = false,
    lock_attempts: usize = 0,
    now_ms: i64 = 0,
};

fn testDurableSyncFile(ctx: ?*anyopaque, file: std.Io.File) anyerror!void {
    const state: *DurableFailureState = @ptrCast(@alignCast(ctx.?));
    if (state.fail_temp_sync) return error.InjectedSyncFailure;
    try file.sync(getIo());
}

fn testDurableSyncDir(ctx: ?*anyopaque, dir: std.Io.Dir) anyerror!void {
    const state: *DurableFailureState = @ptrCast(@alignCast(ctx.?));
    if (state.fail_parent_sync) return error.InjectedSyncFailure;
    try syncVerifiedDir(dir);
}

fn testLockAlwaysBusy(ctx: ?*anyopaque, _: std.Io.File) anyerror!bool {
    const state: *DurableFailureState = @ptrCast(@alignCast(ctx.?));
    state.lock_attempts += 1;
    return false;
}

fn testLockUnsupported(_: ?*anyopaque, _: std.Io.File) anyerror!bool {
    return error.FileLocksUnsupported;
}

fn testLockNow(ctx: ?*anyopaque) i64 {
    const state: *DurableFailureState = @ptrCast(@alignCast(ctx.?));
    return state.now_ms;
}

fn testLockSleep(ctx: ?*anyopaque, millis: u64) void {
    const state: *DurableFailureState = @ptrCast(@alignCast(ctx.?));
    state.now_ms += @intCast(millis);
}

test "durable replace reports pre-rename failure without changing target" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir = VerifiedDir{ .dir = try tmp.dir.openDir(getIo(), ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer dir.close();
    try durableReplaceVerified(alloc, &dir, "settings.json", "old");

    var state = DurableFailureState{ .fail_temp_sync = true };
    const ops = DurableOps{ .ctx = &state, .sync_file = testDurableSyncFile };
    try std.testing.expectError(
        error.DurableReplacePreRenameFailed,
        durableReplaceVerifiedWithOps(alloc, &dir, "settings.json", "new", ops),
    );

    var file = try dir.dir.openFile(getIo(), "settings.json", .{ .follow_symlinks = false });
    defer file.close(getIo());
    const bytes = try readFileToEnd(alloc, &file, 16);
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings("old", bytes);
}

test "durable replace can record what stopped it before the rename" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir = VerifiedDir{ .dir = try tmp.dir.openDir(getIo(), ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer dir.close();
    var state = DurableFailureState{ .fail_temp_sync = true };
    var cause: ?anyerror = null;
    const ops = DurableOps{ .ctx = &state, .sync_file = testDurableSyncFile, .pre_rename_cause = &cause };
    try std.testing.expectError(
        error.DurableReplacePreRenameFailed,
        durableReplaceVerifiedWithOps(alloc, &dir, "marker", "new", ops),
    );
    try std.testing.expectEqual(@as(?anyerror, error.InjectedSyncFailure), cause);
    try std.testing.expectError(error.FileNotFound, dir.dir.statFile(getIo(), "marker", .{ .follow_symlinks = false }));

    // A replace that succeeds records nothing.
    cause = null;
    try durableReplaceVerifiedWithOps(alloc, &dir, "marker", "new", .{ .pre_rename_cause = &cause });
    try std.testing.expectEqual(@as(?anyerror, null), cause);
}

test "durable replace reports post-rename sync failure as indeterminate" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir = VerifiedDir{ .dir = try tmp.dir.openDir(getIo(), ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer dir.close();
    try durableReplaceVerified(alloc, &dir, "settings.json", "old");

    var state = DurableFailureState{ .fail_parent_sync = true };
    const ops = DurableOps{ .ctx = &state, .sync_dir = testDurableSyncDir };
    try std.testing.expectError(
        error.DurableReplacePostRenameFailed,
        durableReplaceVerifiedWithOps(alloc, &dir, "settings.json", "new", ops),
    );

    var file = try dir.dir.openFile(getIo(), "settings.json", .{ .follow_symlinks = false });
    defer file.close(getIo());
    const bytes = try readFileToEnd(alloc, &file, 16);
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings("new", bytes);
}

test "private durable file mode is exactly 0600" {
    if (comptime @import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir = VerifiedDir{ .dir = try tmp.dir.openDir(getIo(), ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer dir.close();
    try durableReplaceVerified(alloc, &dir, "settings.json", "{}\n");

    const stat = try dir.dir.statFile(getIo(), "settings.json", .{ .follow_symlinks = false });
    if (comptime modeIsEnforced) try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

test "private durable directory mode is exactly 0700" {
    if (comptime @import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var parent = VerifiedDir{ .dir = try tmp.dir.openDir(getIo(), ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer parent.close();
    var child = try openOrCreateVerifiedPrivateDir(&parent, "state");
    defer child.close();

    const stat = try child.dir.stat(getIo());
    if (comptime modeIsEnforced) try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), stat.permissions.toMode() & 0o777);
}

test "caller-owned directory can create a verified private child" {
    if (comptime @import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var parent = try tmp.dir.openDir(getIo(), ".", .{ .iterate = true, .follow_symlinks = false });
    defer parent.close(getIo());
    var child = try openOrCreateVerifiedPrivateDirFromDir(parent, "state");
    defer child.close();

    const stat = try child.dir.stat(getIo());
    try std.testing.expectEqual(std.Io.File.Kind.directory, stat.kind);
    if (comptime modeIsEnforced) try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), stat.permissions.toMode() & 0o777);
}

test "caller-owned directory rejects unsafe private children" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(getIo(), .{ .sub_path = "file", .data = "not a directory" });
    try std.testing.expectError(
        error.DurablePathUnsafe,
        openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "file"),
    );

    try tmp.dir.createDir(getIo(), "target", .default_dir);
    tmp.dir.symLink(getIo(), "target", "link", .{ .is_directory = true }) catch |err| {
        if (err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    try std.testing.expectError(
        error.DurablePathUnsafe,
        openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "link"),
    );
}

test "a folder that need not be private opens whatever its mode, but never through a symlink" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var parent: VerifiedDir = .{ .dir = try tmp.dir.openDir(getIo(), ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer parent.close();

    try tmp.dir.createDir(getIo(), "readable", permissionsForMode(0o755));
    try tmp.dir.setFilePermissions(getIo(), "readable", permissionsForMode(0o755), .{});
    var readable = (try openRealDirIfPresent(&parent, "readable")).?;
    readable.close();
    try std.testing.expect((try openRealDirIfPresent(&parent, "missing")) == null);

    try tmp.dir.writeFile(getIo(), .{ .sub_path = "file", .data = "not a directory" });
    try std.testing.expectError(error.DurablePathUnsafe, openRealDirIfPresent(&parent, "file"));
    tmp.dir.symLink(getIo(), "readable", "link", .{ .is_directory = true }) catch |err| {
        if (err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    try std.testing.expectError(error.DurablePathUnsafe, openRealDirIfPresent(&parent, "link"));
}

test "timed advisory lock returns busy after deadline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir = VerifiedDir{ .dir = try tmp.dir.openDir(getIo(), ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer dir.close();
    var state = DurableFailureState{};
    const ops = LockOps{
        .ctx = &state,
        .try_lock = testLockAlwaysBusy,
        .now_ms = testLockNow,
        .sleep_ms = testLockSleep,
    };

    try std.testing.expectError(
        error.LockBusy,
        acquireTimedAdvisoryLockWithOps(&dir, "settings.lock", 25, ops),
    );
    try std.testing.expect(state.lock_attempts > 1);
}

test "cancellable timed advisory lock stops between busy attempts" {
    const CancelState = struct {
        cancel: *std.atomic.Value(bool),
        now_ms: i64 = 0,

        fn tryLock(_: ?*anyopaque, _: std.Io.File) anyerror!bool {
            return false;
        }

        fn now(raw: ?*anyopaque) i64 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.now_ms;
        }

        fn sleep(raw: ?*anyopaque, millis: u64) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.now_ms += @intCast(millis);
            self.cancel.store(true, .release);
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = VerifiedDir{ .dir = try tmp.dir.openDir(
        getIo(),
        ".",
        .{ .iterate = true, .follow_symlinks = false },
    ) };
    defer dir.close();
    var cancel = std.atomic.Value(bool).init(false);
    var state = CancelState{ .cancel = &cancel };

    try std.testing.expectError(
        error.Cancelled,
        acquireTimedAdvisoryLockCancellableWithOps(
            &dir,
            "credentials.lock",
            2_000,
            &cancel,
            .{
                .ctx = &state,
                .try_lock = CancelState.tryLock,
                .now_ms = CancelState.now,
                .sleep_ms = CancelState.sleep,
            },
        ),
    );
    try std.testing.expectEqual(@as(i64, 10), state.now_ms);
}

test "timed advisory lock reports unsupported without unlocked fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir = VerifiedDir{ .dir = try tmp.dir.openDir(getIo(), ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer dir.close();
    const ops = LockOps{ .try_lock = testLockUnsupported };

    try std.testing.expectError(
        error.LockUnsupported,
        acquireTimedAdvisoryLockWithOps(&dir, "settings.lock", 25, ops),
    );
}
