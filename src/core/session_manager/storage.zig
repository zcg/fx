//! L0 (posix storage): the only code in the session manager that touches the
//! file system. It knows nothing about sessions.
//!
//! Policy owned here:
//! - every folder is created `0700` and every file `0600`;
//! - nothing under the root is reached through a symlink: existing files and
//!   folders open with `follow_symlinks = false`, and new files are created
//!   exclusively, which fails on any existing name, a symlink included;
//! - writes and reads loop until done, so callers never see partial I/O.
//!
//! With `-Dhooks=true`, every call first consults the fault injector in
//! `storage_fault.zig`, which models process and machine crashes for tests
//! and the driver. Without hooks that code does not exist in the binary.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Io = std.Io;

/// Whether the test-only fault injection is compiled in.
///
/// It models a POSIX filesystem: descriptors are numbers, `dup` shares an inode,
/// and a kill is a signal. Windows has none of those, so the module is left out
/// there whatever the build asks for; the durability suites that drive it report
/// themselves as skipped.
pub const hooks = build_options.hooks and @import("builtin").target.os.tag != .windows;
pub const Fault = if (hooks) @import("storage_fault.zig").Fault else void;

pub const folder_mode: std.posix.mode_t = 0o700;
pub const file_mode: std.posix.mode_t = 0o600;
/// A blob never changes once written, and a tool may open it by path (D49).
pub const blob_mode: std.posix.mode_t = 0o400;

/// The session manager reads and writes the profile's own folders with these
/// two calls and nothing else, because it may import only the standard library.
/// POSIX answers both directly. Windows has no mode: its `Permissions` is a
/// `DWORD` of attributes whose only security-relevant bit is READONLY, access
/// comes from the ACL the entry inherits, and the type has neither method. The
/// helpers therefore make the same request Windows can honor, and report no
/// mode, which is why `modeIsEnforced` is false there.
pub const modeIsEnforced = @hasDecl(std.Io.File.Permissions, "fromMode");

/// The Windows READONLY file attribute, `0x1`. Zig 0.17.0's Windows
/// `Permissions.setReadOnly` names a constant its own `std.os.windows` does not
/// declare, so the session manager builds the attribute itself.
const windows_readonly_attribute: u32 = 0x1;

/// Requests a `mode` for a new folder or file, as far as this platform can.
/// `0o400` asks for a read-only blob, which is the one mode bit Windows also has.
pub fn permissionsForMode(mode: std.posix.mode_t) std.Io.File.Permissions {
    if (comptime modeIsEnforced) return std.Io.File.Permissions.fromMode(mode);
    if (mode & 0o200 == 0) return @fromBackingInt(windows_readonly_attribute);
    return if (mode & 0o040 != 0) .default_dir else .default_file;
}

/// Reads the mode back for a caller that verifies what it created.
///
/// Windows has no mode bits. The one thing it does carry is the READONLY
/// attribute, which `permissionsForMode` sets for a mode with no owner write
/// bit, so a caller asking whether the entry refuses writes still gets the
/// right answer there. Every other bit is reported as zero rather than
/// invented, and callers compare full modes only where `modeIsEnforced`.
pub fn modeOf(permissions: std.Io.File.Permissions) std.posix.mode_t {
    if (comptime modeIsEnforced) return permissions.toMode() & 0o777;
    return if (@backingInt(permissions) & windows_readonly_attribute != 0) 0o400 else 0o600;
}

/// Whether the entry refuses writes. POSIX reads the mode's write bits, and
/// Windows reads the READONLY attribute.
pub fn deniesWrites(permissions: std.Io.File.Permissions) bool {
    if (comptime modeIsEnforced) return permissions.toMode() & 0o222 == 0;
    return @backingInt(permissions) & windows_readonly_attribute != 0;
}

pub const Error = error{
    /// No file or folder by that name.
    NotFound,
    /// An exclusive create or a folder rename hit an existing name.
    AlreadyExists,
    /// A symlink, a name of the wrong kind, or a permission denial.
    Refused,
    /// Disk full or quota exhausted.
    NoSpace,
    /// The file system is mounted read-only.
    ReadOnly,
    /// A file-size limit (RLIMIT_FSIZE) was reached.
    TooBig,
    /// Any other failure. After a failed write or sync, durability is unknown.
    Io,
    /// The calling task was canceled; the operation may be partly done.
    Canceled,
};

/// I/O failures as the API reports them (D29): the OS cause when it is
/// known, `Io` otherwise. After a failed write or sync, durability is
/// unknown whichever it is.
pub const IoFault = error{ Io, NoSpaceLeft, AccessDenied, ReadOnlyFileSystem, FileTooBig };

/// Keeps the cause of a storage failure, and of one already classified;
/// anything else is `Io`.
pub fn ioFault(err: anyerror) IoFault {
    return switch (err) {
        error.NoSpace, error.NoSpaceLeft => error.NoSpaceLeft,
        error.Refused, error.AccessDenied => error.AccessDenied,
        error.ReadOnly, error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
        error.TooBig, error.FileTooBig => error.FileTooBig,
        else => error.Io,
    };
}

/// A folder opened for listing (`openDir`, `openRoot`). Linux opens any
/// other folder with `O_PATH`, which `syncDir` cannot sync (EBADF).
pub const Dir = struct { handle: Io.Dir };
pub const File = struct { handle: Io.File };

pub const Access = enum { read_only, read_write };

pub const Kind = enum { file, directory, other };

pub const Stat = struct {
    size: u64,
    kind: Kind,
    /// Permission bits only (`0o777` mask).
    mode: std.posix.mode_t,
    /// Last modification, milliseconds since the epoch.
    mtime_ms: i64,
};

pub const Entry = struct {
    /// Borrowed; valid until the next call to `Listing.next`.
    name: []const u8,
    kind: Kind,
};

/// A handle to the file system. Small and copied by value; it owns nothing.
pub const Storage = struct {
    io: Io,
    /// Test-only fault injector, borrowed. Null means real behavior.
    fault: if (hooks) ?*Fault else void = if (hooks) null else {},

    /// Opens the sessions root, creating missing parents with default
    /// permissions and the root itself `0700`. The root may not be a symlink;
    /// its parents may.
    pub fn openRoot(s: Storage, path: []const u8) Error!Dir {
        try s.alive();
        const parent_path = std.Io.Dir.path.dirname(path) orelse ".";
        const name = std.Io.Dir.path.basename(path);
        const cwd = Io.Dir.cwd();
        // Missing parents are the manager's own folders, so private too, for
        // example `~/.fx/sessions` on a machine that never ran v1 (D19).
        // Existing ones are left as they are.
        _ = cwd.createDirPathStatus(s.io, parent_path, permissionsForMode(folder_mode)) catch |err| return translate(err);
        var parent = cwd.openDir(s.io, parent_path, .{}) catch |err| return translate(err);
        defer parent.close(s.io);
        return s.ensureDir(.{ .handle = parent }, name);
    }

    /// Whether the sessions root exists, creating neither it nor its parents.
    pub fn rootExists(s: Storage, path: []const u8) Error!bool {
        try s.alive();
        const parent_path = std.Io.Dir.path.dirname(path) orelse ".";
        var parent = Io.Dir.cwd().openDir(s.io, parent_path, .{}) catch |err| return switch (translate(err)) {
            error.NotFound => false,
            else => |e| e,
        };
        defer parent.close(s.io);
        _ = s.stat(.{ .handle = parent }, std.Io.Dir.path.basename(path)) catch |err| return switch (err) {
            error.NotFound => false,
            else => err,
        };
        return true;
    }

    /// Opens `name` inside `parent`, creating it `0700` if it is missing.
    pub fn ensureDir(s: Storage, parent: Dir, name: []const u8) Error!Dir {
        s.makeDir(parent, name) catch |err| switch (err) {
            error.AlreadyExists => {},
            else => return err,
        };
        return s.openDir(parent, name);
    }

    /// Opens `name` inside `parent`, refusing anything a link redirects out.
    ///
    /// POSIX passes `follow_symlinks = false`, and the kernel refuses a link on
    /// its own. Windows cannot use that flag: a junction is how a package
    /// manager's link farm, a user's own link, and a redirected profile folder
    /// all present themselves, and a handle opened with `OPEN_REPARSE_POINT`
    /// cannot even be statted (`STATUS_REPARSE_POINT_NOT_RESOLVED`). So the
    /// component is opened with following allowed and the result is checked
    /// instead: what it resolved to has to stay inside the directory the
    /// component was found in.
    pub fn openDir(s: Storage, parent: Dir, name: []const u8) Error!Dir {
        try s.alive();
        assertComponent(name);
        if (comptime builtin.target.os.tag == .windows) {
            return .{ .handle = openDirRefusingOutside(s.io, parent, name) catch |err| return translate(err) };
        }
        const handle = parent.handle.openDir(s.io, name, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| return translate(err);
        return .{ .handle = handle };
    }

    pub fn closeDir(s: Storage, dir: Dir) void {
        dir.handle.close(s.io);
    }

    /// Creates a folder `0700`. Fails with AlreadyExists if the name exists.
    pub fn makeDir(s: Storage, parent: Dir, name: []const u8) Error!void {
        try s.alive();
        try s.mutate();
        assertComponent(name);
        parent.handle.createDir(s.io, name, permissionsForMode(folder_mode)) catch |err|
            return translate(err);
        if (hooks) if (s.fault) |f| try f.noteCreate(s, parent, name);
    }

    /// Creates a new file `0600`, opened for reading and writing. Fails with
    /// AlreadyExists if the name exists, including as a symlink.
    pub fn createFile(s: Storage, dir: Dir, name: []const u8) Error!File {
        return s.createFileMode(dir, name, file_mode);
    }

    /// As `createFile`, but `0400`: the returned handle still writes the new
    /// file, and nothing can open it for writing afterwards (D49).
    pub fn createReadOnlyFile(s: Storage, dir: Dir, name: []const u8) Error!File {
        return s.createFileMode(dir, name, blob_mode);
    }

    fn createFileMode(s: Storage, dir: Dir, name: []const u8, mode: std.posix.mode_t) Error!File {
        try s.alive();
        try s.mutate();
        assertComponent(name);
        const handle = dir.handle.createFile(s.io, name, .{
            .read = true,
            .truncate = false,
            .exclusive = true,
            .permissions = permissionsForMode(mode),
            .resolve_beneath = true,
        }) catch |err| return translate(err);
        if (hooks) if (s.fault) |f| {
            f.noteCreate(s, dir, name) catch |err| {
                handle.close(s.io);
                return err;
            };
        };
        return .{ .handle = handle };
    }

    /// Opens an existing regular file. A symlink or a folder is Refused.
    /// Opens `name` inside `dir` for reading, or for reading and writing.
    ///
    /// `follow_symlinks = false` is what refuses a link on POSIX. Windows has
    /// no such flag for a file: the entry is asked about first, so a link is
    /// refused before it is opened, and the open itself does not follow one.
    pub fn openFile(s: Storage, dir: Dir, name: []const u8, access: Access) Error!File {
        try s.alive();
        assertComponent(name);
        if (comptime builtin.target.os.tag == .windows) {
            // A missing name is reported by the open below, with the same
            // translation, so the link check only has to answer for a name that
            // is there.
            if (isReparsePoint(s.io, dir, name) catch false) return error.Refused;
        }
        const handle = dir.handle.openFile(s.io, name, .{
            .mode = switch (access) {
                .read_only => .read_only,
                .read_write => .read_write,
            },
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| return translate(err);
        return .{ .handle = handle };
    }

    pub fn closeFile(s: Storage, file: File) void {
        if (hooks) if (s.fault) |f| f.noteClose(s, file);
        file.handle.close(s.io);
    }

    /// Closes a derived file that is written without a sync on purpose (the
    /// index): a crash may lose its tail, and rebuild re-derives it.
    pub fn closeDerived(s: Storage, file: File) void {
        if (hooks) if (s.fault) |f| f.forgetWriter(file);
        file.handle.close(s.io);
    }

    pub fn length(s: Storage, file: File) Error!u64 {
        try s.alive();
        return file.handle.length(s.io) catch |err| translate(err);
    }

    /// Reads into `buffer` from `offset` until it is full or the file ends.
    /// Returns the number of bytes read.
    pub fn readAt(s: Storage, file: File, buffer: []u8, offset: u64) Error!usize {
        try s.alive();
        var done: usize = 0;
        while (done < buffer.len) {
            const n = file.handle.readPositional(s.io, &.{buffer[done..]}, offset + done) catch |err|
                return translate(err);
            if (n == 0) break;
            done += n;
        }
        return done;
    }

    /// Writes all of `bytes` at `offset`.
    pub fn writeAt(s: Storage, file: File, bytes: []const u8, offset: u64) Error!void {
        try s.alive();
        try s.mutate();
        var allowed = bytes.len;
        var outcome: WriteOutcome = .complete;
        if (hooks) if (s.fault) |f| {
            try f.noteBeforeWrite(s, file);
            const plan = f.planWrite(bytes.len);
            allowed = plan.allowed;
            outcome = plan.outcome;
        };
        file.handle.writePositionalAll(s.io, bytes[0..allowed], offset) catch |err|
            return translate(err);
        switch (outcome) {
            .complete => {},
            .fail => {
                if (hooks) if (s.fault) |f| return f.fail_error;
                return error.Io;
            },
            .die => {
                if (hooks) if (s.fault) |f| f.kill();
                return error.Io;
            },
        }
    }

    /// Durability point for one file: a plain `fsync` (D3).
    pub fn sync(s: Storage, file: File) Error!void {
        try s.alive();
        try s.mutate();
        if (hooks) if (s.fault) |f| if (f.takeSyncFailure()) return f.fail_error;
        file.handle.sync(s.io) catch |err| return translate(err);
        if (hooks) if (s.fault) |f| try f.noteSync(s, file);
    }

    /// Makes created, renamed and removed names inside `dir` durable.
    ///
    /// A POSIX filesystem makes a rename durable by syncing the directory.
    /// Windows has no equivalent call: `NtFlushBuffersFile` on a directory
    /// handle fails with `AccessDenied`, because the handle was opened for
    /// backup intent without write access and the flush would have to update
    /// the directory's timestamps. Measured on Windows 11 with
    /// `zig build probe-dir-sync`. The file's own data is synced by the caller
    /// before the rename, so the remaining exposure is the rename's name entry,
    /// and refusing here would fail every session write on the platform.
    pub fn syncDir(s: Storage, dir: Dir) Error!void {
        try s.alive();
        try s.mutate();
        if (comptime builtin.target.os.tag == .windows) return;
        const as_file: Io.File = .{ .handle = dir.handle.handle, .flags = .{ .nonblocking = false } };
        as_file.sync(s.io) catch |err| return translate(err);
        if (hooks) if (s.fault) |f| try f.noteDirSync(s, dir);
    }

    /// Cuts the file to `new_length` bytes.
    pub fn setLength(s: Storage, file: File, new_length: u64) Error!void {
        try s.alive();
        try s.mutate();
        file.handle.setLength(s.io, new_length) catch |err| return translate(err);
        if (hooks) if (s.fault) |f| f.noteSetLength(file, new_length);
    }

    /// Takes an exclusive `flock` without waiting. Returns false if another
    /// open file description holds it. The kernel releases it on process exit.
    pub fn tryLock(s: Storage, file: File) Error!bool {
        try s.alive();
        return file.handle.tryLock(s.io, .exclusive) catch |err| translate(err);
    }

    pub fn unlock(s: Storage, file: File) void {
        file.handle.unlock(s.io);
    }

    /// Renames within the root. A file rename replaces an existing file; a
    /// folder rename never replaces a non-empty folder (AlreadyExists).
    pub fn rename(s: Storage, old_dir: Dir, old_name: []const u8, new_dir: Dir, new_name: []const u8) Error!void {
        try s.alive();
        try s.mutate();
        assertComponent(old_name);
        assertComponent(new_name);
        Io.Dir.rename(old_dir.handle, old_name, new_dir.handle, new_name, s.io) catch |err|
            return translate(err);
        if (hooks) if (s.fault) |f| try f.noteRename(s, old_dir, old_name, new_dir, new_name);
    }

    /// Makes `name` refuse a write, which is what a blob is.
    ///
    /// On POSIX the file already carries `blob_mode`, so this has nothing to do.
    /// On Windows Zig 0.17's `createFile` ignores `permissions` and its
    /// `setFilePermissions` panics with TODO implement, so the READONLY
    /// attribute is set here. It has to be set after the blob is under its
    /// final name, because Windows cannot rename a READONLY file, and a blob is
    /// written under a staging name and then moved to its hash.
    pub fn makeReadOnly(s: Storage, dir: Dir, name: []const u8) Error!void {
        try s.alive();
        try s.mutate();
        assertComponent(name);
        if (comptime modeIsEnforced) return;
        setReadOnlyAttribute(s.io, dir, name) catch |err| return translate(err);
    }

    /// Hard link (fork blobs). Fails if the new name exists.
    ///
    /// Zig 0.17 reports `OperationUnsupported` for a directory hard link on
    /// Windows, but the volume supports one: a fork's blob is the same bytes
    /// under a second name, and copying them instead would double the space a
    /// fork costs and lose the shared page cache. `CreateHardLinkW` is the call
    /// std does not make, so it is made here.
    pub fn link(s: Storage, old_dir: Dir, old_name: []const u8, new_dir: Dir, new_name: []const u8) Error!void {
        try s.alive();
        try s.mutate();
        assertComponent(old_name);
        assertComponent(new_name);
        if (comptime builtin.target.os.tag == .windows) {
            windowsCreateHardLink(s.io, old_dir, old_name, new_dir, new_name) catch |err| return translate(err);
        } else {
            Io.Dir.hardLink(old_dir.handle, old_name, new_dir.handle, new_name, s.io, .{
                .follow_symlinks = false,
            }) catch |err| return translate(err);
        }
        if (hooks) if (s.fault) |f| try f.noteCreate(s, new_dir, new_name);
    }

    pub fn deleteFile(s: Storage, dir: Dir, name: []const u8) Error!void {
        try s.alive();
        try s.mutate();
        assertComponent(name);
        // Windows deletes a READONLY file only after its attribute is cleared,
        // which is the one thing a POSIX mode carries that Windows keeps.
        if (comptime !modeIsEnforced) {
            if (s.stat(dir, name)) |entry| {
                if (entry.mode & 0o200 == 0) {
                    clearReadOnlyAttribute(s.io, dir, name) catch |err| return translate(err);
                }
            } else |_| {}
        }
        dir.handle.deleteFile(s.io, name) catch |err| return translate(err);
    }

    /// Removes a folder and everything in it. A missing name is not an error.
    pub fn deleteTree(s: Storage, dir: Dir, name: []const u8) Error!void {
        try s.alive();
        try s.mutate();
        assertComponent(name);
        // Windows refuses to delete a READONLY entry, and a session folder holds
        // blobs, which are READONLY on purpose. The attribute is cleared through
        // the tree first, so the delete below sees ordinary entries.
        if (comptime !modeIsEnforced) {
            clearReadOnlyTree(s.io, dir, name) catch |err| return translate(err);
        }
        dir.handle.deleteTree(s.io, name) catch |err| return translate(err);
    }

    /// Stats a name without following a symlink.
    pub fn stat(s: Storage, dir: Dir, name: []const u8) Error!Stat {
        try s.alive();
        assertComponent(name);
        const st = dir.handle.statFile(s.io, name, .{ .follow_symlinks = false }) catch |err|
            return translate(err);
        return .{
            .size = st.size,
            .kind = switch (st.kind) {
                .file => .file,
                .directory => .directory,
                else => .other,
            },
            // Zig 0.17's Windows `statFile` leaves `Permissions` zeroed, so the
            // READONLY attribute is read here instead. It is the one bit this
            // module sets and reads back, and without it a blob would report
            // itself writable.
            .mode = if (comptime modeIsEnforced) modeOf(st.permissions) else attributeModeOf(s.io, dir, name) catch |err| return translate(err),
            .mtime_ms = st.mtime.toMilliseconds(),
        };
    }

    /// Lists a folder opened by this Storage.
    pub fn list(s: Storage, dir: Dir) Listing {
        return .{ .io = s.io, .iterator = dir.handle.iterate() };
    }

    fn mutate(s: Storage) Error!void {
        if (hooks) if (s.fault) |f| if (f.mutate()) return error.Io;
    }

    fn alive(s: Storage) Error!void {
        if (hooks) if (s.fault) |f| if (f.dead) return error.Io;
    }
};

pub const Listing = struct {
    io: Io,
    iterator: Io.Dir.Iterator,

    pub fn next(l: *Listing) Error!?Entry {
        const entry = (l.iterator.next(l.io) catch |err| return translate(err)) orelse return null;
        return .{
            .name = entry.name,
            .kind = switch (entry.kind) {
                .file => .file,
                .directory => .directory,
                else => .other,
            },
        };
    }
};

pub const WriteOutcome = enum { complete, fail, die };

/// A name must be one path component: the manager builds every path from
/// validated ids and fixed names, so anything else is a programming error.
fn assertComponent(name: []const u8) void {
    std.debug.assert(name.len > 0);
    std.debug.assert(std.mem.findScalar(u8, name, '/') == null);
    std.debug.assert(!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, ".."));
}

/// Clears the READONLY attribute on `name` inside `dir` and on everything
/// beneath it, so the tree can be deleted.
///
/// A name that is not there is left alone: the delete that follows reports it,
/// and this pass exists only to remove an obstacle the delete cannot pass.
fn clearReadOnlyTree(io: Io, dir: Dir, name: []const u8) !void {
    clearReadOnlyAttribute(io, dir, name) catch return;
    const opened = dir.handle.openDir(io, name, .{ .iterate = true, .follow_symlinks = true }) catch |err| switch (err) {
        // A file, or a name that is not a folder, has no tree beneath it.
        error.NotDir, error.FileNotFound => return,
        else => return err,
    };
    const child: Dir = .{ .handle = opened };
    defer child.handle.close(io);
    var iterator = child.handle.iterate();
    while (try iterator.next(io)) |entry| {
        switch (entry.kind) {
            .directory => clearReadOnlyTree(io, child, entry.name) catch {},
            else => clearReadOnlyAttribute(io, child, entry.name) catch {},
        }
    }
}

/// Clears the READONLY attribute on `name` inside `dir`, so the entry can be
/// renamed or deleted.
fn clearReadOnlyAttribute(io: Io, dir: Dir, name: []const u8) !void {
    const alloc = std.heap.page_allocator;
    const path = try absoluteChildPath(alloc, io, dir, name);
    defer alloc.free(path);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(wide);
    if (win_file_attributes.SetFileAttributesW(wide, win_file_attributes.normal) == 0) {
        // `ERROR_FILE_NOT_FOUND` and `ERROR_PATH_NOT_FOUND`.
        return switch (win_file_attributes.GetLastError()) {
            2, 3 => error.FileNotFound,
            else => error.Unexpected,
        };
    }
}

/// The mode a Windows entry reports, built from its file attributes.
///
/// `FILE_ATTRIBUTE_READONLY` is the only bit this module sets, so the answer is
/// `0o400` for an entry that refuses writes and `0o600` for one that accepts
/// them. Every other mode bit is reported as zero rather than invented.
fn attributeModeOf(io: Io, dir: Dir, name: []const u8) !std.posix.mode_t {
    const alloc = std.heap.page_allocator;
    const path = try absoluteChildPath(alloc, io, dir, name);
    defer alloc.free(path);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(wide);
    const attributes = win_file_attributes.GetFileAttributesW(wide);
    const invalid: u32 = 0xffffffff;
    if (attributes == invalid) {
        return switch (win_file_attributes.GetLastError()) {
            2, 3 => error.FileNotFound,
            else => error.Unexpected,
        };
    }
    return if (attributes & win_file_attributes.readonly != 0) 0o400 else 0o600;
}

/// Sets the READONLY attribute on `name` inside `dir`, which is how Windows
/// makes a file refuse a write.
fn setReadOnlyAttribute(io: Io, dir: Dir, name: []const u8) !void {
    const alloc = std.heap.page_allocator;
    const path = try absoluteChildPath(alloc, io, dir, name);
    defer alloc.free(path);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(wide);
    if (win_file_attributes.SetFileAttributesW(wide, win_file_attributes.readonly) == 0) {
        // `ERROR_FILE_NOT_FOUND` and `ERROR_PATH_NOT_FOUND`.
        return switch (win_file_attributes.GetLastError()) {
            2, 3 => error.FileNotFound,
            else => error.Unexpected,
        };
    }
}

const win_file_attributes = if (builtin.target.os.tag != .windows) struct {} else struct {
    /// `FILE_ATTRIBUTE_READONLY`: the attribute that makes a write fail.
    const readonly: u32 = 0x1;
    /// `FILE_ATTRIBUTE_NORMAL`, which clears every attribute that can be set
    /// on its own, so it is what restoring an ordinary entry uses.
    const normal: u32 = 0x80;
    extern "kernel32" fn SetFileAttributesW(file_name: [*:0]const u16, attributes: u32) callconv(.winapi) i32;
    extern "kernel32" fn GetFileAttributesW(file_name: [*:0]const u16) callconv(.winapi) u32;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
};

/// Links `old_name` in `old_dir` to `new_name` in `new_dir` with
/// `CreateHardLinkW`, which Zig 0.17's `Io.Dir.hardLink` does not reach on
/// Windows.
fn windowsCreateHardLink(
    io: Io,
    old_dir: Dir,
    old_name: []const u8,
    new_dir: Dir,
    new_name: []const u8,
) !void {
    const alloc = std.heap.page_allocator;
    const old_path = try absoluteChildPath(alloc, io, old_dir, old_name);
    defer alloc.free(old_path);
    const new_path = try absoluteChildPath(alloc, io, new_dir, new_name);
    defer alloc.free(new_path);

    const old_wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, old_path);
    defer alloc.free(old_wide);
    const new_wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, new_path);
    defer alloc.free(new_wide);

    if (win_hard_link.CreateHardLinkW(new_wide, old_wide, null) == 0) {
        // `ERROR_ALREADY_EXISTS`, `ERROR_FILE_NOT_FOUND`, `ERROR_PATH_NOT_FOUND`,
        // and `ERROR_ACCESS_DENIED`, by their Win32 values.
        return switch (win_hard_link.GetLastError()) {
            183 => error.PathAlreadyExists,
            2, 3 => error.FileNotFound,
            5 => error.AccessDenied,
            else => error.Unexpected,
        };
    }
}

/// The resolved path of `name` inside `dir`, so a link is created between the
/// real entries rather than between whatever a link would have resolved to.
fn absoluteChildPath(
    alloc: std.mem.Allocator,
    io: Io,
    dir: Dir,
    name: []const u8,
) ![]u8 {
    const parent_path = try resolvedPathOf(alloc, io, dir);
    defer alloc.free(parent_path);
    return std.Io.Dir.path.join(alloc, &.{ parent_path, name });
}

const win_hard_link = if (builtin.target.os.tag != .windows) struct {} else struct {
    extern "kernel32" fn CreateHardLinkW(
        new_file_name: [*:0]const u16,
        existing_file_name: [*:0]const u16,
        security_attributes: ?*anyopaque,
    ) callconv(.winapi) i32;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
};

/// Opens `name` inside `parent` on Windows and refuses a link that leaves it.
///
/// The parent's resolved path is the anchor and the child's resolved path is
/// what it is compared against: a link that redirects outside fails that
/// comparison, and a junction that stays inside is opened normally, which is
/// what a redirected profile folder and a package manager's link farm both
/// need. Comparing resolved paths is what makes this work on a handle opened
/// with `OPEN_REPARSE_POINT`, which `GetFinalPathNameByHandle` refuses.
fn openDirRefusingOutside(io: Io, parent: Dir, name: []const u8) !Io.Dir {
    // The name itself is refused when it is a link, whether or not the link
    // stays inside: this module's contract is that nothing under the root is
    // reached through one. That is a reparse point on Windows, and the
    // attribute is on the entry rather than on what it resolves to, so the name
    // is asked about before it is opened.
    if (try isReparsePoint(io, parent, name)) return error.SymLinkLoop;

    const opened = try parent.handle.openDir(io, name, .{ .iterate = true, .follow_symlinks = true });
    errdefer opened.close(io);

    // A link that arrived between the check and the open would still be caught
    // here, because what it resolved to has to stay inside `parent`.
    const alloc = std.heap.page_allocator;
    const parent_path = try resolvedPathOf(alloc, io, parent);
    defer alloc.free(parent_path);
    const opened_path = try resolvedPathOf(alloc, io, .{ .handle = opened });
    defer alloc.free(opened_path);

    if (!pathIsInside(parent_path, opened_path)) return error.SymLinkLoop;
    return opened;
}

/// Whether `name` inside `parent` is a reparse point, which is how Windows
/// spells a symlink or a junction.
///
/// The file attribute is read from the directory entry, so the answer describes
/// the name rather than whatever a link points at.
fn isReparsePoint(io: Io, parent: Dir, name: []const u8) !bool {
    const stat = try parent.handle.statFile(io, name, .{ .follow_symlinks = false });
    return stat.kind == .sym_link;
}

/// The absolute, resolved path of an open directory.
fn resolvedPathOf(alloc: std.mem.Allocator, io: Io, dir: Dir) ![]u8 {
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const length = try dir.handle.realPath(io, &buffer);
    return alloc.dupe(u8, buffer[0..length]);
}

/// Whether `child` lies beneath `parent`, comparing whole path components.
///
/// Windows compares paths without regard to letter case, so a comparison that
/// respected it would reject `C:\Users\Ann` against `c:\users\ann`, the
/// same directory written two ways. A separator counts as a boundary, because a
/// path can arrive with either one.
fn pathIsInside(parent: []const u8, child: []const u8) bool {
    if (child.len < parent.len) return false;
    for (parent, child[0..parent.len]) |a, b| {
        if (isPathSeparator(a) and isPathSeparator(b)) continue;
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    if (child.len == parent.len) return true;
    // A parent that already ends at a separator ("C:\") has no boundary byte of
    // its own to check; everything after it is beneath it.
    if (parent.len == 0 or isPathSeparator(parent[parent.len - 1])) return true;
    return isPathSeparator(child[parent.len]);
}

fn isPathSeparator(byte: u8) bool {
    return byte == std.Io.Dir.path.sep or byte == '/' or byte == '\\';
}

fn translate(err: anyerror) Error {
    return switch (err) {
        error.FileNotFound => error.NotFound,
        error.PathAlreadyExists, error.DirNotEmpty => error.AlreadyExists,
        error.SymLinkLoop,
        error.NotDir,
        error.IsDir,
        error.AccessDenied,
        error.PermissionDenied,
        error.BadPathName,
        => error.Refused,
        error.NoSpaceLeft, error.DiskQuota => error.NoSpace,
        error.ReadOnlyFileSystem => error.ReadOnly,
        error.FileTooBig => error.TooBig,
        error.Canceled => error.Canceled,
        else => error.Io,
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn testRoot(tmp: *testing.TmpDir) Dir {
    return .{ .handle = tmp.dir };
}

test "an I/O failure keeps its OS cause, and only unknown ones become Io (D29)" {
    try testing.expectEqual(error.NoSpaceLeft, ioFault(translate(error.NoSpaceLeft)));
    try testing.expectEqual(error.NoSpaceLeft, ioFault(translate(error.DiskQuota)));
    try testing.expectEqual(error.AccessDenied, ioFault(translate(error.AccessDenied)));
    try testing.expectEqual(error.AccessDenied, ioFault(translate(error.PermissionDenied)));
    try testing.expectEqual(error.ReadOnlyFileSystem, ioFault(translate(error.ReadOnlyFileSystem)));
    try testing.expectEqual(error.FileTooBig, ioFault(translate(error.FileTooBig)));
    try testing.expectEqual(error.Io, ioFault(translate(error.InputOutput)));
    // Classified once, it stays classified through every layer above.
    inline for (.{ error.NoSpaceLeft, error.AccessDenied, error.ReadOnlyFileSystem, error.FileTooBig, error.Io }) |kind| {
        try testing.expectEqual(kind, ioFault(ioFault(kind)));
    }
}

test "folders are 0700 and files are 0600" {
    // Windows has no mode bits: a folder or file is protected by the ACL it
    // inherits, and `setPermissions` there carries only the read-only
    // attribute. The modes are asserted where the platform has them, and the
    // kinds are asserted everywhere.
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const s: Storage = .{ .io = testing.io };
    const root = testRoot(&tmp);
    const sub = try s.ensureDir(root, "session");
    defer s.closeDir(sub);
    const file = try s.createFile(sub, "log.jsonl");
    s.closeFile(file);
    if (comptime modeIsEnforced) {
        try testing.expectEqual(@as(std.posix.mode_t, folder_mode), (try s.stat(root, "session")).mode);
        try testing.expectEqual(@as(std.posix.mode_t, file_mode), (try s.stat(sub, "log.jsonl")).mode);
    } else {
        // A folder and a file a durable write creates are writable on
        // Windows, so neither carries the READONLY attribute.
        try testing.expectEqual(@as(std.posix.mode_t, 0o600), (try s.stat(root, "session")).mode);
        try testing.expectEqual(@as(std.posix.mode_t, 0o600), (try s.stat(sub, "log.jsonl")).mode);
    }
    try testing.expectEqual(Kind.directory, (try s.stat(root, "session")).kind);
    try testing.expectEqual(Kind.file, (try s.stat(sub, "log.jsonl")).kind);
}

test "a read-only file is written through its own handle and opens read-only only" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const s: Storage = .{ .io = testing.io };
    const root = testRoot(&tmp);
    const file = try s.createReadOnlyFile(root, "blob.staged");
    try s.writeAt(file, "body", 0);
    try s.sync(file);
    s.closeFile(file);
    // A blob is written under a staging name and renamed to its hash, which is
    // the name it keeps. That is where the read-only state is applied on
    // Windows: a READONLY file cannot be renamed, so the attribute is set once
    // the final name exists. POSIX carries the mode with the inode, so the
    // rename leaves it alone.
    try s.rename(root, "blob.staged", root, "blob");
    try s.makeReadOnly(root, "blob");
    try testing.expectEqual(@as(std.posix.mode_t, blob_mode), (try s.stat(root, "blob")).mode);
    try testing.expectError(error.Refused, s.openFile(root, "blob", .read_write));
    const again = try s.openFile(root, "blob", .read_only);
    var buffer: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try s.readAt(again, &buffer, 0));
    try testing.expectEqualStrings("body", &buffer);
    s.closeFile(again);
    // The temporary folder is removed after this test, and Windows will not
    // delete a READONLY file, so the attribute is cleared here rather than
    // leaving cleanup to fail.
    if (comptime !modeIsEnforced) {
        clearReadOnlyAttribute(s.io, root, "blob") catch {};
    }
}

test "openRoot creates the root 0700 and refuses a symlinked root" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    const s: Storage = .{ .io = io };
    const base = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base);
    // Like `~/.fx/sessions/v2` where neither parent exists yet: all three
    // folders are created private.
    const root_path = try std.Io.Dir.path.join(testing.allocator, &.{ base, "a", "sessions", "v2" });
    defer testing.allocator.free(root_path);
    const root = try s.openRoot(root_path);
    s.closeDir(root);
    const top: Dir = .{ .handle = tmp.dir };
    // Windows protects these folders through the ACL they inherit, so there
    // is no mode to read back; the folders still have to be folders.
    if (comptime modeIsEnforced) {
        try testing.expectEqual(@as(std.posix.mode_t, folder_mode), (try s.stat(top, "a")).mode);
    } else {
        try testing.expectEqual(@as(std.posix.mode_t, 0o600), (try s.stat(top, "a")).mode);
    }
    var a = try tmp.dir.openDir(io, "a", .{});
    defer a.close(io);
    if (comptime modeIsEnforced) {
        try testing.expectEqual(@as(std.posix.mode_t, folder_mode), (try s.stat(.{ .handle = a }, "sessions")).mode);
    } else {
        try testing.expectEqual(@as(std.posix.mode_t, 0o600), (try s.stat(.{ .handle = a }, "sessions")).mode);
    }
    var parent = try a.openDir(io, "sessions", .{});
    defer parent.close(io);
    if (comptime modeIsEnforced) {
        try testing.expectEqual(@as(std.posix.mode_t, folder_mode), (try s.stat(.{ .handle = parent }, "v2")).mode);
    } else {
        try testing.expectEqual(@as(std.posix.mode_t, 0o600), (try s.stat(.{ .handle = parent }, "v2")).mode);
    }

    try tmp.dir.createDir(io, "real", .default_dir);
    try tmp.dir.symLink(io, "real", "linked", .{ .is_directory = true });
    const linked_path = try std.Io.Dir.path.join(testing.allocator, &.{ base, "linked" });
    defer testing.allocator.free(linked_path);
    try testing.expectError(error.Refused, s.openRoot(linked_path));
}

test "symlinks under the root are refused" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    const s: Storage = .{ .io = io };
    const root = testRoot(&tmp);
    try tmp.dir.createDir(io, "elsewhere", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "secret", .data = "keep" });
    try tmp.dir.symLink(io, "elsewhere", "dir_link", .{ .is_directory = true });
    try tmp.dir.symLink(io, "secret", "file_link", .{});

    try testing.expectError(error.Refused, s.openDir(root, "dir_link"));
    try testing.expectError(error.Refused, s.openFile(root, "file_link", .read_write));
    // Exclusive create never writes through a symlink.
    try testing.expectError(error.AlreadyExists, s.createFile(root, "file_link"));
    const kept = try tmp.dir.readFileAlloc(io, "secret", testing.allocator, .limited(16));
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings("keep", kept);
    // A folder where a file is expected is refused too.
    try testing.expectError(error.Refused, s.openFile(root, "elsewhere", .read_only));
}

test "a second exclusive lock on the same file is refused" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const s: Storage = .{ .io = testing.io };
    const root = testRoot(&tmp);
    const first = try s.createFile(root, "lock");
    defer s.closeFile(first);
    const second = try s.openFile(root, "lock", .read_only);
    defer s.closeFile(second);
    try testing.expect(try s.tryLock(first));
    try testing.expect(!try s.tryLock(second));
    s.unlock(first);
    try testing.expect(try s.tryLock(second));
}

test "write, read, cut, rename and link round trip" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const s: Storage = .{ .io = testing.io };
    const root = testRoot(&tmp);
    const file = try s.createFile(root, "a");
    try s.writeAt(file, "hello\n", 0);
    try s.writeAt(file, "world\n", 6);
    try s.sync(file);
    try testing.expectEqual(@as(u64, 12), try s.length(file));
    var buffer: [32]u8 = undefined;
    const n = try s.readAt(file, &buffer, 6);
    try testing.expectEqualStrings("world\n", buffer[0..n]);
    try s.setLength(file, 6);
    try testing.expectEqual(@as(u64, 6), try s.length(file));
    s.closeFile(file);

    try s.rename(root, "a", root, "b");
    try testing.expectError(error.NotFound, s.stat(root, "a"));
    try s.link(root, "b", root, "c");
    try testing.expectError(error.AlreadyExists, s.link(root, "b", root, "c"));
    const linked = try s.openFile(root, "c", .read_only);
    defer s.closeFile(linked);
    try testing.expectEqual(@as(u64, 6), try s.length(linked));
    try s.syncDir(root);
}

test "a folder rename never replaces a non-empty folder" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const s: Storage = .{ .io = testing.io };
    const root = testRoot(&tmp);
    const staged = try s.ensureDir(root, "staged");
    s.closeFile(try s.createFile(staged, "log.jsonl"));
    s.closeDir(staged);
    const taken = try s.ensureDir(root, "taken");
    s.closeFile(try s.createFile(taken, "log.jsonl"));
    s.closeDir(taken);
    try testing.expectError(error.AlreadyExists, s.rename(root, "staged", root, "taken"));
    try s.rename(root, "staged", root, "fresh");
}

test "listing names every entry" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const s: Storage = .{ .io = testing.io };
    const root = testRoot(&tmp);
    s.closeFile(try s.createFile(root, "one"));
    s.closeDir(try s.ensureDir(root, "two"));
    var listing = s.list(root);
    var files: usize = 0;
    var dirs: usize = 0;
    while (try listing.next()) |entry| switch (entry.kind) {
        .file => files += 1,
        .directory => dirs += 1,
        .other => {},
    };
    try testing.expectEqual(@as(usize, 1), files);
    try testing.expectEqual(@as(usize, 1), dirs);
}
