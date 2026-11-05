//! The providers the add-provider flow offers before a custom one.
//!
//! A preset is what a provider needs before it works, minus the key itself: a
//! base URL and a protocol. Adding one is choosing it and pasting a key, rather than reading
//! three fields out of a vendor's documentation.
//!
//! The list is curated, not complete. The public models.dev catalog, which pi
//! also draws on, names more than two hundred providers; offering all of them
//! would make the picker a directory to search rather than a list to read. This
//! set is the vendors a developer is likely to name, plus the aggregators that
//! reach everything else through one key, and the custom row covers the rest.
//!
//! Each entry's slug, base URL, and protocol come from that
//! catalog, so a preset matches what the vendor actually serves. Regenerate the
//! table with `scripts/windows/generate_provider_presets.py` when the upstream
//! catalog changes.
//!
//! A preset never overrides the profile: it only pre-fills the flow's fields,
//! and the user can still edit any of them before saving.

const std = @import("std");

pub const Preset = struct {
    /// The name the flow suggests, also the settings key it is saved under.
    name: []const u8,
    /// The vendor's own name, shown in the picker and in notices.
    display_name: []const u8,
    /// The vendor's API base URL, including the version prefix fx appends its
    /// chat path to.
    base_url: []const u8,
    /// The wire protocol the vendor's API speaks.
    protocol: Protocol,
    /// How many chat models the upstream catalog lists for this vendor. A row
    /// shows it so a vendor that serves four models reads differently from one
    /// that serves three hundred.
    model_count: u16,
    /// One sentence naming the vendor, shown in the picker row.
    label: []const u8,

    /// The name shown in a picker row.
    pub fn title(self: Preset) []const u8 {
        return if (self.display_name.len > 0) self.display_name else self.name;
    }
};

/// The protocol a preset speaks, as the configured-provider format names it.
pub const Protocol = enum {
    openai_chat_completions,
    openai_responses,
    anthropic_messages,

    /// The name `configured_provider.Protocol` parses.
    pub fn wireName(self: Protocol) []const u8 {
        return switch (self) {
            .openai_chat_completions => "openai-chat-completions",
            .openai_responses => "openai-responses",
            .anthropic_messages => "anthropic-messages",
        };
    }
};

/// The presets the picker offers, in display order. Aggregators come first
/// because one key reaches every vendor on them, which is the shortest path to
/// a working custom provider.
pub const presets = [_]Preset{
    .{
        .name = "openrouter",
        .display_name = "OpenRouter",
        .base_url = "https://openrouter.ai/api/v1",
        .protocol = .openai_chat_completions,
        .model_count = 366,
        .label = "OpenRouter - every vendor through one key",
    },
    .{
        .name = "anthropic",
        .display_name = "Anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .protocol = .anthropic_messages,
        .model_count = 17,
        .label = "Anthropic - Claude models",
    },
    .{
        .name = "openai",
        .display_name = "OpenAI",
        .base_url = "https://api.openai.com/v1",
        .protocol = .openai_responses,
        .model_count = 50,
        .label = "OpenAI - GPT models",
    },
    .{
        .name = "google",
        .display_name = "Google",
        .base_url = "https://generativelanguage.googleapis.com/v1beta/openai",
        .protocol = .openai_chat_completions,
        .model_count = 23,
        .label = "Google - Gemini models",
    },
    .{
        .name = "deepseek",
        .display_name = "DeepSeek",
        .base_url = "https://api.deepseek.com",
        .protocol = .openai_chat_completions,
        .model_count = 4,
        .label = "DeepSeek - open-weight reasoning models",
    },
    .{
        .name = "xai",
        .display_name = "xAI",
        .base_url = "https://api.x.ai/v1",
        .protocol = .openai_responses,
        .model_count = 8,
        .label = "xAI - Grok models",
    },
    .{
        .name = "mistral",
        .display_name = "Mistral",
        .base_url = "https://api.mistral.ai/v1",
        .protocol = .openai_chat_completions,
        .model_count = 36,
        .label = "Mistral AI - European models",
    },
    .{
        .name = "groq",
        .display_name = "Groq",
        .base_url = "https://api.groq.com/openai/v1",
        .protocol = .openai_chat_completions,
        .model_count = 10,
        .label = "Groq - very fast inference",
    },
    .{
        .name = "zai",
        .display_name = "Z.AI",
        .base_url = "https://api.z.ai/api/paas/v4",
        .protocol = .openai_chat_completions,
        .model_count = 21,
        .label = "Z.AI - GLM models",
    },
    .{
        .name = "moonshotai",
        .display_name = "Moonshot AI",
        .base_url = "https://api.moonshot.ai/v1",
        .protocol = .openai_chat_completions,
        .model_count = 6,
        .label = "Moonshot AI - Kimi models",
    },
    .{
        .name = "moonshotai-cn",
        .display_name = "Moonshot AI (China)",
        .base_url = "https://api.moonshot.cn/v1",
        .protocol = .openai_chat_completions,
        .model_count = 6,
        .label = "Moonshot AI (China endpoint)",
    },
    .{
        .name = "minimax",
        .display_name = "MiniMax (minimax.io)",
        .base_url = "https://api.minimax.io/anthropic/v1",
        .protocol = .anthropic_messages,
        .model_count = 8,
        .label = "MiniMax",
    },
    .{
        .name = "minimax-cn",
        .display_name = "MiniMax (minimax.cn)",
        .base_url = "https://api.minimax.cn/anthropic/v1",
        .protocol = .anthropic_messages,
        .model_count = 8,
        .label = "MiniMax (China endpoint)",
    },
    .{
        .name = "zhipuai",
        .display_name = "Zhipu AI",
        .base_url = "https://open.bigmodel.cn/api/paas/v4",
        .protocol = .openai_chat_completions,
        .model_count = 19,
        .label = "Zhipu AI (China endpoint)",
    },
    .{
        .name = "alibaba",
        .display_name = "Alibaba",
        .base_url = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
        .protocol = .openai_chat_completions,
        .model_count = 59,
        .label = "Alibaba - Qwen models",
    },
    .{
        .name = "volcengine",
        .display_name = "Volcengine Ark",
        .base_url = "https://ark.cn-beijing.volces.com/api/v3",
        .protocol = .openai_chat_completions,
        .model_count = 16,
        .label = "Volcengine - Doubao models",
    },
    .{
        .name = "stepfun",
        .display_name = "StepFun (China)",
        .base_url = "https://api.stepfun.com/v1",
        .protocol = .openai_chat_completions,
        .model_count = 4,
        .label = "StepFun - Step models",
    },
    .{
        .name = "modelscope",
        .display_name = "ModelScope",
        .base_url = "https://api-inference.modelscope.cn/v1",
        .protocol = .openai_chat_completions,
        .model_count = 7,
        .label = "ModelScope - China model hub",
    },
    .{
        .name = "sensenova",
        .display_name = "SenseNova (China)",
        .base_url = "https://token.sensenova.cn/v1",
        .protocol = .openai_chat_completions,
        .model_count = 6,
        .label = "SenseNova",
    },
    .{
        .name = "xiaomi",
        .display_name = "Xiaomi",
        .base_url = "https://api.xiaomimimo.com/v1",
        .protocol = .openai_chat_completions,
        .model_count = 6,
        .label = "Xiaomi MiMo",
    },
    .{
        .name = "longcat",
        .display_name = "LongCat",
        .base_url = "https://api.longcat.chat/openai",
        .protocol = .openai_chat_completions,
        .model_count = 2,
        .label = "LongCat",
    },
    .{
        .name = "tencent-tokenhub",
        .display_name = "Tencent TokenHub",
        .base_url = "https://tokenhub.tencentmaas.com/v1",
        .protocol = .openai_chat_completions,
        .model_count = 4,
        .label = "Tencent TokenHub",
    },
    .{
        .name = "siliconflow",
        .display_name = "SiliconFlow",
        .base_url = "https://api.siliconflow.com/v1",
        .protocol = .openai_chat_completions,
        .model_count = 57,
        .label = "SiliconFlow - China model hub",
    },
    .{
        .name = "perplexity",
        .display_name = "Perplexity",
        .base_url = "https://api.perplexity.ai",
        .protocol = .openai_chat_completions,
        .model_count = 4,
        .label = "Perplexity - Sonar models",
    },
    .{
        .name = "cohere",
        .display_name = "Cohere",
        .base_url = "https://api.cohere.ai/compatibility/v1",
        .protocol = .openai_chat_completions,
        .model_count = 17,
        .label = "Cohere - Command models",
    },
    .{
        .name = "cerebras",
        .display_name = "Cerebras",
        .base_url = "https://api.cerebras.ai/v1",
        .protocol = .openai_chat_completions,
        .model_count = 2,
        .label = "Cerebras - wafer-scale inference",
    },
    .{
        .name = "fireworks-ai",
        .display_name = "Fireworks AI",
        .base_url = "https://api.fireworks.ai/inference/v1",
        .protocol = .openai_chat_completions,
        .model_count = 29,
        .label = "Fireworks AI - fast open models",
    },
    .{
        .name = "deepinfra",
        .display_name = "Deep Infra",
        .base_url = "https://api.deepinfra.com/v1/openai",
        .protocol = .openai_chat_completions,
        .model_count = 77,
        .label = "DeepInfra - open models",
    },
    .{
        .name = "nvidia",
        .display_name = "Nvidia",
        .base_url = "https://integrate.api.nvidia.com/v1",
        .protocol = .openai_chat_completions,
        .model_count = 40,
        .label = "NVIDIA NIM",
    },
    .{
        .name = "huggingface",
        .display_name = "Hugging Face",
        .base_url = "https://router.huggingface.co/v1",
        .protocol = .openai_chat_completions,
        .model_count = 80,
        .label = "Hugging Face router",
    },
    .{
        .name = "github-copilot",
        .display_name = "GitHub Copilot",
        .base_url = "https://api.githubcopilot.com",
        .protocol = .openai_chat_completions,
        .model_count = 36,
        .label = "GitHub Copilot subscription",
    },
    .{
        .name = "vercel",
        .display_name = "Vercel AI Gateway",
        .base_url = "https://ai-gateway.vercel.sh/v1",
        .protocol = .openai_chat_completions,
        .model_count = 264,
        .label = "Vercel AI Gateway",
    },
    .{
        .name = "baseten",
        .display_name = "Baseten",
        .base_url = "https://inference.baseten.co/v1",
        .protocol = .openai_chat_completions,
        .model_count = 15,
        .label = "Baseten",
    },
    .{
        .name = "sambanova",
        .display_name = "SambaNova",
        .base_url = "https://api.sambanova.ai/v1",
        .protocol = .openai_chat_completions,
        .model_count = 6,
        .label = "SambaNova",
    },
};

pub fn presetAt(index: usize) ?Preset {
    if (index >= presets.len) return null;
    return presets[index];
}

pub fn find(name: []const u8) ?Preset {
    for (presets) |preset| {
        if (std.ascii.eqlIgnoreCase(preset.name, name)) return preset;
    }
    return null;
}

pub const option_count = presets.len;

test "every preset has what the add-provider flow needs" {
    for (presets) |preset| {
        try std.testing.expect(preset.name.len > 0);
        try std.testing.expect(preset.display_name.len > 0);
        try std.testing.expect(std.mem.startsWith(u8, preset.base_url, "https://"));
        try std.testing.expect(preset.label.len > 0);
    }
}

test "preset names are unique and lower-case" {
    for (presets, 0..) |preset, index| {
        for (presets[index + 1 ..]) |other| {
            try std.testing.expect(!std.ascii.eqlIgnoreCase(preset.name, other.name));
        }
        for (preset.name) |byte| try std.testing.expect(byte == std.ascii.toLower(byte));
    }
}

test "find resolves a preset by name and rejects an unknown one" {
    try std.testing.expectEqualStrings("openrouter", find("OpenRouter").?.name);
    try std.testing.expect(find("no-such-vendor") == null);
}
