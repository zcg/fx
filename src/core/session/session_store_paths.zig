const std = @import("std");
const session_layout = @import("session_layout.zig");

const Allocator = std.mem.Allocator;

/// Validates a session id against the shared layout rules (length, charset,
/// path safety). Errors propagate from `session_layout` unchanged.
pub fn validateSessionId(session_id: []const u8) !void {
    return session_layout.validateSessionId(session_id);
}

/// Builds the absolute directory path for a session, for display, transitional
/// legacy facades, and tests. Caller owns the returned slice.
pub fn sessionDirPath(alloc: Allocator, sessions_dir: []const u8, session_id: []const u8) ![]u8 {
    return session_layout.sessionDirPath(alloc, sessions_dir, session_id);
}

/// Generates a fresh, layout-valid session id. Caller owns the returned slice.
pub fn generateSessionId(alloc: Allocator) ![]u8 {
    return session_layout.generateSessionId(alloc);
}

/// Path to a session's primary `session.json` under `sessions_dir`. Caller owns it.
pub fn sessionJsonPath(alloc: Allocator, sessions_dir: []const u8, session_id: []const u8) ![]u8 {
    const session_dir = try sessionDirPath(alloc, sessions_dir, session_id);
    defer alloc.free(session_dir);
    return std.Io.Dir.path.join(alloc, &.{ session_dir, "session.json" });
}

/// Strips trailing separators from a workspace root (keeping at least one
/// char), so equivalent roots compare equal. Returns a borrowed sub-slice of
/// the input.
///
/// A workspace root is a native path, so a Windows root ends in `\` as often as
/// `/`, and Windows accepts both separators in the same path. Trimming only `/`
/// left `C:\work\` and `C:\work` as two different workspaces, so a profile
/// override saved under one did not apply to the other.
pub fn normalizeWorkspaceRoot(workspace_root: []const u8) []const u8 {
    var end = workspace_root.len;
    while (end > 1 and isPathSeparator(workspace_root[end - 1])) {
        end -= 1;
    }
    return workspace_root[0..end];
}

fn isPathSeparator(byte: u8) bool {
    if (byte == '/') return true;
    return std.Io.Dir.path.sep == '\\' and byte == '\\';
}

/// The workspace override for `workspace_root`, or null.
///
/// A profile written on Windows (or by hand) may key `workspaces` with
/// `C:\work\`, while the run reports `C:\work`. Comparing the raw strings finds
/// nothing, so the override silently does not apply. Both sides are normalized
/// before they are compared.
pub fn workspaceOverride(workspaces: std.json.ObjectMap, workspace_root: []const u8) ?std.json.Value {
    const key = findWorkspaceKey(workspaces, workspace_root) orelse return null;
    return workspaces.get(key);
}

/// The key `workspaces` actually stores for `workspace_root`, or null. The
/// exact spelling wins; otherwise the first key that normalizes to the same
/// root does, which is how a hand-written `C:\work\` still matches a run that
/// reports `C:\work`.
pub fn findWorkspaceKey(workspaces: std.json.ObjectMap, workspace_root: []const u8) ?[]const u8 {
    const wanted = normalizeWorkspaceRoot(workspace_root);
    if (workspaces.contains(wanted)) return wanted;
    var iterator = workspaces.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, normalizeWorkspaceRoot(entry.key_ptr.*), wanted)) {
            return entry.key_ptr.*;
        }
    }
    return null;
}

/// Rejects a workspace root that is empty, too long, not valid UTF-8, or not
/// absolute. The only failure is `error.InvalidDurableField`.
pub fn validateWorkspaceRoot(workspace_root: []const u8) error{InvalidDurableField}!void {
    if (workspace_root.len == 0 or
        workspace_root.len > std.Io.Dir.max_path_bytes or
        !std.unicode.utf8ValidateSlice(workspace_root) or
        !std.Io.Dir.path.isAbsolute(workspace_root))
    {
        return error.InvalidDurableField;
    }
}

test "normalizeWorkspaceRoot strips both separator spellings on Windows" {
    try std.testing.expectEqualStrings("/w", normalizeWorkspaceRoot("/w/"));
    try std.testing.expectEqualStrings("/w", normalizeWorkspaceRoot("/w///"));
    try std.testing.expectEqualStrings("/", normalizeWorkspaceRoot("////"));
    try std.testing.expectEqualStrings("/w", normalizeWorkspaceRoot("/w"));
    if (comptime std.Io.Dir.path.sep == '\\') {
        try std.testing.expectEqualStrings("C:\\w", normalizeWorkspaceRoot("C:\\w\\"));
        try std.testing.expectEqualStrings("C:\\w", normalizeWorkspaceRoot("C:\\w///"));
        try std.testing.expectEqualStrings("C:\\", normalizeWorkspaceRoot("C:\\\\"));
    }
}
