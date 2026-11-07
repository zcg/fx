const std = @import("std");
const io_mod = @import("../shared/io.zig");

/// The most agent steps a turn the user typed may take when the profile does
/// not say. A turn the user started can run a long task, so it is unbounded by
/// default: the user ends it with Esc, not with a step count they never chose.
/// `max_agent_steps` still applies when the profile or `FX_MAX_AGENT_STEPS`
/// sets it.
pub const default_max_agent_steps: usize = 0;

/// The bound a turn a subagent runs gets when the profile does not say. A
/// subagent works for another turn and nobody watches its screen, so its run
/// stays finite: an unbounded child that keeps calling tools costs its parent
/// the whole turn. `subagent_max_agent_steps` replaces it.
pub const default_subagent_max_agent_steps: usize = 100;

/// How many subagents main may run at once when the profile sets no
/// `subagent_max_children`. The ceiling is small on purpose: each child is a
/// session with its own worker and slot thread, and nesting is already
/// limited to one level (`subagent/authority.zig` `max_subagent_depth`).
pub const default_subagent_max_children: usize = 4;

/// Zero turns subagents off: main does the work itself. A session that wants
/// none sets it, which is also the bound a profile in an untrusted project
/// cannot raise.
pub const min_subagent_max_children: usize = 0;
pub const max_subagent_max_children: usize = 16;

pub fn resolveMaxAgentSteps(configured: ?usize, default_value: usize) usize {
    return configured orelse default_value;
}

/// The bound a subagent turn gets: the profile's `subagent_max_agent_steps`
/// when it sets one, and a finite default when it does not, since nobody
/// watches a child's screen. `0` still turns the bound off on purpose.
///
/// `max_agent_steps` deliberately does not reach here. That setting bounds a
/// turn the user typed; a child run exists to be stopped, inspected, and
/// continued by its parent, so the two bounds are separate settings.
pub fn resolveSubagentMaxAgentSteps(configured: ?usize) usize {
    return configured orelse default_subagent_max_agent_steps;
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

test "a root turn is unbounded by default while a subagent turn stays finite" {
    // The compiled default leaves a turn the user typed uncapped.
    try std.testing.expectEqual(@as(usize, 0), default_max_agent_steps);
    try std.testing.expect(allowsStep(default_max_agent_steps, 10_000));
    // A child keeps a finite bound when the profile sets none, and the
    // profile's own value wins in both directions.
    try std.testing.expectEqual(default_subagent_max_agent_steps, resolveSubagentMaxAgentSteps(null));
    try std.testing.expect(!allowsStep(resolveSubagentMaxAgentSteps(null), default_subagent_max_agent_steps));
    try std.testing.expectEqual(@as(usize, 7), resolveSubagentMaxAgentSteps(7));
    try std.testing.expectEqual(@as(usize, 0), resolveSubagentMaxAgentSteps(0));
    try std.testing.expect(allowsStep(resolveSubagentMaxAgentSteps(0), 10_000));
}

test "parse max agent steps accepts zero and rejects invalid input" {
    try std.testing.expectEqual(@as(usize, 0), parseMaxAgentSteps("0").?);
    try std.testing.expectEqual(@as(usize, 24), parseMaxAgentSteps("24").?);
    try std.testing.expect(parseMaxAgentSteps(null) == null);
    try std.testing.expect(parseMaxAgentSteps("") == null);
    try std.testing.expect(parseMaxAgentSteps("abc") == null);
}

test "process overrides resolve with configured and compiled defaults" {
    try std.testing.expectEqual(default_max_agent_steps, resolveMaxAgentStepsWithOverride(null, default_max_agent_steps, null));
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
