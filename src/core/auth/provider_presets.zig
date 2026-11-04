//! The well-known providers the add-provider flow offers before a custom one.
//!
//! A preset is a base URL, a protocol, and the environment variable the key is
//! conventionally read from. It is what a provider needs before it works, minus
//! the key itself, so adding one is choosing it and pasting a key rather than
//! reading three fields out of a vendor's documentation. Each entry follows the
//! vendor's own API documentation, cross-checked against the catalog pi keeps
//! for the same providers (`catalog/providers/*.ts` there).
//!
//! A preset never overrides the profile: it only pre-fills the flow's fields,
//! and the user can still edit any of them before saving.

const std = @import("std");

pub const Preset = struct {
    /// The name the flow suggests, also the settings key it is saved under.
    name: []const u8,
    /// The vendor's API base URL, including the version prefix fx appends its
    /// chat path to.
    base_url: []const u8,
    /// The wire protocol the vendor's API speaks.
    protocol: []const u8,
    /// The environment variable the vendor's key is conventionally read from.
    /// A local runtime that keeps no secret reads it here; one with a keychain
    /// stores the pasted key under the provider's name instead.
    env: []const u8,
    /// One sentence naming the vendor, shown in the picker row.
    label: []const u8,
};

/// The presets the picker offers, in display order. OpenRouter comes first
/// because one key reaches every vendor on it, which is the shortest path to a
/// working custom provider.
pub const presets = [_]Preset{
    .{
        .name = "openrouter",
        .base_url = "https://openrouter.ai/api/v1",
        .protocol = "openai-chat-completions",
        .env = "OPENROUTER_API_KEY",
        .label = "OpenRouter - every vendor through one key",
    },
    .{
        .name = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .protocol = "anthropic-messages",
        .env = "ANTHROPIC_API_KEY",
        .label = "Anthropic - Claude models",
    },
    .{
        .name = "openai",
        .base_url = "https://api.openai.com/v1",
        .protocol = "openai-chat-completions",
        .env = "OPENAI_API_KEY",
        .label = "OpenAI - GPT models",
    },
    .{
        .name = "xai",
        .base_url = "https://api.x.ai/v1",
        .protocol = "openai-chat-completions",
        .env = "XAI_API_KEY",
        .label = "xAI - Grok models by API",
    },
    .{
        .name = "deepseek",
        .base_url = "https://api.deepseek.com/v1",
        .protocol = "openai-chat-completions",
        .env = "DEEPSEEK_API_KEY",
        .label = "DeepSeek",
    },
    .{
        .name = "groq",
        .base_url = "https://api.groq.com/openai/v1",
        .protocol = "openai-chat-completions",
        .env = "GROQ_API_KEY",
        .label = "Groq - fast inference",
    },
    .{
        .name = "mistral",
        .base_url = "https://api.mistral.ai/v1",
        .protocol = "openai-chat-completions",
        .env = "MISTRAL_API_KEY",
        .label = "Mistral",
    },
    .{
        .name = "moonshot",
        .base_url = "https://api.moonshot.ai/v1",
        .protocol = "openai-chat-completions",
        .env = "MOONSHOT_API_KEY",
        .label = "Moonshot - Kimi models",
    },
    .{
        .name = "minimax",
        .base_url = "https://api.minimax.io/anthropic",
        .protocol = "anthropic-messages",
        .env = "MINIMAX_API_KEY",
        .label = "MiniMax",
    },
    .{
        .name = "together",
        .base_url = "https://api.together.ai/v1",
        .protocol = "openai-chat-completions",
        .env = "TOGETHER_API_KEY",
        .label = "Together AI",
    },
    .{
        .name = "gemini",
        .base_url = "https://generativelanguage.googleapis.com/v1beta/openai",
        .protocol = "openai-chat-completions",
        .env = "GEMINI_API_KEY",
        .label = "Google Gemini - OpenAI-compatible endpoint",
    },
};

/// The row after the last preset: a provider the user names themselves.
pub const custom_entry_name = "custom";

/// How many rows the picker shows: every preset plus the custom one.
pub const option_count = presets.len + 1;

/// The suggested field values for a picker row, or null for the custom row.
pub fn presetAt(index: usize) ?Preset {
    if (index < presets.len) return presets[index];
    return null;
}

/// The preset with this name, when one exists.
pub fn find(name: []const u8) ?Preset {
    for (presets) |preset| {
        if (std.mem.eql(u8, preset.name, name)) return preset;
    }
    return null;
}

test "every preset names a protocol fx can speak" {
    const known = [_][]const u8{ "openai-chat-completions", "anthropic-messages", "openai-responses" };
    for (presets) |preset| {
        var ok = false;
        for (known) |name| if (std.mem.eql(u8, preset.protocol, name)) {
            ok = true;
        };
        try std.testing.expect(ok);
    }
}

test "every preset name is a valid settings key" {
    for (presets) |preset| {
        try std.testing.expect(preset.name.len > 0 and preset.name.len <= 64);
        for (preset.name) |byte| {
            try std.testing.expect(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_');
        }
    }
}

test "every preset base URL is https" {
    for (presets) |preset| {
        try std.testing.expect(std.mem.startsWith(u8, preset.base_url, "https://"));
    }
}
