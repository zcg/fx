const std = @import("std");
const io_mod = @import("../shared/io.zig");

pub const default_max_agent_steps: usize = 0;

/// How many subagents main may run at once when the profile sets no
/// `subagent_max_children`. The ceiling is small on purpose: each child is a
/// session with its own worker and slot thread, and nesting is already
/// limited to one level (`subagent.max_subagent_depth`).
pub const default_subagent_max_children: usize = 4;
pub const min_subagent_max_children: usize = 1;
pub const max_subagent_max_children: usize = 16;

pub fn resolveMaxAgentSteps(configured: ?usize, default_value: usize) usize {
    return configured orelse default_value;
}

/// The number of subagents main may run at once: the profile's setting when
/// it is in range, and the default otherwise, so a bad file cannot widen it.
pub fn resolveSubagentMaxChildren(configured: ?usize) usize {
    const value = configured orelse return default_subagent_max_children;
    if (value < min_subagent_max_children or value > max_subagent_max_children) {
        return default_subagent_max_children;
    }
    return value;
}

/// The same, with `FX_SUBAGENT_MAX_CHILDREN` in front of the profile's
/// setting, as every other `FX_*` override works.
pub fn resolveSubagentMaxChildrenWithOverride(configured: ?usize) usize {
    return parseSubagentMaxChildren(io_mod.getenv("FX_SUBAGENT_MAX_CHILDREN")) orelse
        resolveSubagentMaxChildren(configured);
}

pub fn parseSubagentMaxChildren(raw: ?[]const u8) ?usize {
    const trimmed = std.mem.trim(u8, raw orelse return null, " \t\r\n");
    if (trimmed.len == 0) return null;
    const value = std.fmt.parseUnsigned(usize, trimmed, 10) catch return null;
    if (value < min_subagent_max_children or value > max_subagent_max_children) return null;
    return value;
}

pub fn parseMaxAgentSteps(raw: ?[]const u8) ?usize {
    const trimmed = std.mem.trim(u8, raw orelse return null, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseUnsigned(usize, trimmed, 10) catch null;
}

pub fn resolveMaxAgentStepsWithOverride(
    configured: ?usize,
    default_value: usize,
    process_override: ?[]const u8,
) usize {
    return parseMaxAgentSteps(process_override) orelse resolveMaxAgentSteps(configured, default_value);
}

pub fn allowsStep(limit: usize, completed_steps: usize) bool {
    return limit == 0 or completed_steps < limit;
}

test "resolve max agent steps preserves explicit unbounded zero" {
    try std.testing.expectEqual(@as(usize, 25), resolveMaxAgentSteps(null, 25));
    try std.testing.expectEqual(@as(usize, 0), resolveMaxAgentSteps(0, 25));
    try std.testing.expectEqual(@as(usize, 50), resolveMaxAgentSteps(50, 25));
}

test "parse max agent steps accepts zero and rejects invalid input" {
    try std.testing.expectEqual(@as(usize, 0), parseMaxAgentSteps("0").?);
    try std.testing.expectEqual(@as(usize, 24), parseMaxAgentSteps("24").?);
    try std.testing.expect(parseMaxAgentSteps(null) == null);
    try std.testing.expect(parseMaxAgentSteps("") == null);
    try std.testing.expect(parseMaxAgentSteps("abc") == null);
}

test "process overrides resolve with configured and compiled defaults" {
    try std.testing.expectEqual(@as(usize, 0), resolveMaxAgentStepsWithOverride(null, default_max_agent_steps, null));
    try std.testing.expectEqual(@as(usize, 0), resolveMaxAgentStepsWithOverride(0, 24, null));
    try std.testing.expectEqual(@as(usize, 24), resolveMaxAgentStepsWithOverride(null, 0, "24"));
    try std.testing.expectEqual(@as(usize, 0), resolveMaxAgentStepsWithOverride(24, 8, "0"));
    try std.testing.expectEqual(@as(usize, 24), resolveMaxAgentStepsWithOverride(24, 8, "invalid"));
    try std.testing.expectEqual(@as(usize, 24), resolveMaxAgentStepsWithOverride(24, 8, "  \t\n"));
}

test "agent step policy treats zero as unbounded and positives as exact caps" {
    try std.testing.expect(allowsStep(0, 0));
    try std.testing.expect(allowsStep(0, 25));
    try std.testing.expect(allowsStep(2, 0));
    try std.testing.expect(allowsStep(2, 1));
    try std.testing.expect(!allowsStep(2, 2));
}
