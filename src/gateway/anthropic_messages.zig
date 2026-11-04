//! The Anthropic Messages protocol: request building and reply parsing.
//!
//! Anthropic's wire format differs from OpenAI's in ways that are not a rename.
//! The system prompt is a top-level field rather than a message; a tool is
//! `{name, description, input_schema}` rather than a function wrapper; a tool
//! result is a `tool_result` block inside a user turn rather than a message with
//! its own role; and a streamed reply is a typed event sequence rather than a
//! list of deltas. This module speaks that format directly, so a configured
//! provider pointed at Anthropic, or at a gateway that serves its format, works
//! without a translation proxy.
//!
//! The request and reply contracts above this module are fx's own, so the
//! reducer produces the same `stream_provider.Result` the OpenAI path does.

const std = @import("std");
const streams = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const model_provider = @import("../core/config/model_provider.zig");
const definitions = @import("../core/config/configured_provider.zig");

const Allocator = std.mem.Allocator;

/// Anthropic requires an explicit output cap on every request.
pub const default_max_tokens: u32 = 8192;
/// The largest cap Anthropic documents; a larger request is refused.
pub const max_tokens_ceiling: u32 = 64000;
/// Anthropic's format is versioned by date and rejects a request without it.
pub const api_version = "2023-06-01";

pub const Error = error{
    OutOfMemory,
    InvalidProviderPrompt,
    InvalidModel,
    UnsupportedReplay,
    InvalidToolSchema,
    InvalidToolSelection,
    TooManyTools,
    RequiredToolMissing,
    InvalidChunk,
    IncompleteStream,
    StreamClosed,
    Cancelled,
    UnsupportedProviderOption,
};

pub const Options = struct {
    /// Whether a request states its tool choice. Anthropic accepts `auto` and
    /// `any`; omitting the field means the same as `auto`.
    tool_choice_mode: ToolChoiceMode = .omit,
    /// Borrowed during serialization; names the provider in replay records.
    provider: ?*const model_provider.ProviderId = null,
};

pub const ToolChoiceMode = definitions.ToolChoiceMode;

/// A tool the request offers, already validated and ordered.
const Function = struct {
    name: []const u8,
    description: []const u8,
    schema: []const u8,
};

const max_selected_tools = 256;

/// Builds the request body. The caller owns the result.
pub fn build_request(alloc: Allocator, input: streams.RequestData, options: Options) Error![]u8 {
    try validate_request(input);
    var projected: ?[]types.ChatMessage = null;
    if (options.provider) |provider| {
        projected = try types.projectProviderReplay(alloc, input.messages, .{ .provider = provider.*, .model = input.model });
    } else {
        for (input.messages) |message| if (message.provider_replay != null) return error.UnsupportedReplay;
    }
    defer if (projected) |messages| alloc.free(messages);
    var request = input;
    request.messages = projected orelse input.messages;

    var functions: std.ArrayList(Function) = .empty;
    defer functions.deinit(alloc);
    try select_functions(alloc, &functions, request.tools, request.tool_choice);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    write_request(&out.writer, alloc, request, functions.items, options) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return out.toOwnedSlice();
}

fn validate_request(request: streams.RequestData) Error!void {
    if (request.model.len == 0 or request.model.len > 1024) return error.InvalidModel;
    request.validatePrompt() catch return error.InvalidProviderPrompt;
}

/// Collects the tools the request offers, in the order fx advertised them. A
/// schema is serialized here once, so the writer stays allocation free.
fn select_functions(
    alloc: Allocator,
    out: *std.ArrayList(Function),
    tools: streams.ToolSelection,
    choice: types.ToolChoice,
) Error!void {
    if (choice == .none) return;
    if (tools.advertised_names.len > max_selected_tools or
        tools.advertised_functions.len > max_selected_tools or
        tools.additional_functions.len > max_selected_tools or
        tools.selected_dynamic.len > max_selected_tools) return error.TooManyTools;
    for (tools.advertised_names) |name| {
        const function = tools.advertisedFunction(name) orelse {
            const registered = tools.registry.lookup(name) orelse return error.InvalidToolSelection;
            if (registered.provider_executed) continue;
            return error.InvalidToolSelection;
        };
        var matches: usize = 0;
        for (tools.advertised_functions) |candidate| if (std.mem.eql(u8, candidate.name, name)) {
            matches += 1;
        };
        if (matches != 1) return error.InvalidToolSelection;
        try append_function(alloc, out, name, function.description, .{ .builtin = function.input_schema });
    }
    for (tools.additional_functions) |function| {
        if (containsName(tools.advertised_names, function.name)) continue;
        try append_function(alloc, out, function.name, function.description, .{ .builtin = function.input_schema });
    }
    for (tools.selected_dynamic) |function| {
        if (containsName(tools.advertised_names, function.name)) continue;
        if (function.input_schema != .object) return error.InvalidToolSchema;
        try append_function(alloc, out, function.name, function.description, .{ .dynamic = function.input_schema });
    }
    if (choice == .required and out.items.len == 0) return error.RequiredToolMissing;
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

const Schema = union(enum) {
    builtin: @import("../core/tooling/model_tool_schema.zig").ObjectSchema,
    dynamic: std.json.Value,
};

fn append_function(
    alloc: Allocator,
    out: *std.ArrayList(Function),
    name: []const u8,
    description: []const u8,
    schema: Schema,
) Error!void {
    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();
    switch (schema) {
        .builtin => |object| std.json.Stringify.value(object, .{}, &buffer.writer) catch return error.OutOfMemory,
        .dynamic => |value| std.json.Stringify.value(value, .{}, &buffer.writer) catch return error.OutOfMemory,
    }
    try out.append(alloc, .{
        .name = name,
        .description = description,
        .schema = try buffer.toOwnedSlice(),
    });
}

fn write_request(writer: *std.Io.Writer, alloc: Allocator, request: streams.RequestData, functions: []const Function, options: Options) !void {
    const max_tokens = @min(request.max_output_tokens orelse default_max_tokens, max_tokens_ceiling);
    try writer.writeAll("{\"model\":");
    try writeJsonString(writer, request.model);
    try writer.print(",\"max_tokens\":{d}", .{max_tokens});

    // The system prompt is a top-level field and is kept out of the turn list.
    if (request.instructions.len > 0) {
        var any = false;
        for (request.instructions) |instruction| {
            if (instruction.content) |text| if (text.len > 0) {
                any = true;
                break;
            };
        }
        try writer.writeAll(",\"system\":[");
        var first = true;
        if (any) {
            for (request.instructions) |instruction| {
                const text = instruction.content orelse continue;
                if (text.len == 0) continue;
                if (!first) try writer.writeAll(",");
                first = false;
                try writer.writeAll("{\"type\":\"text\",\"text\":");
                try writeJsonString(writer, text);
                try writer.writeAll("}");
            }
        } else {
            try writer.writeAll("{\"type\":\"text\",\"text\":\"\"}");
        }
        try writer.writeAll("]");
    }

    try writer.writeAll(",\"messages\":[");
    var emitted: usize = 0;
    // Anthropic rejects two turns of one role in a row, so a tool result merges
    // into the user turn that precedes it instead of opening its own.
    var open_user_turn = false;
    for (request.messages) |message| {
        if (message.role == .system) continue; // the system field carries it
        if (message.role == .tool) {
            if (!open_user_turn) {
                if (emitted > 0) try writer.writeAll(",");
                try writer.writeAll("{\"role\":\"user\",\"content\":[");
                open_user_turn = true;
            } else {
                try writer.writeAll(",");
            }
            try write_tool_result(writer, message);
            emitted += 1;
            continue;
        }
        if (open_user_turn) {
            try writer.writeAll("]}");
            open_user_turn = false;
        }
        if (emitted > 0) try writer.writeAll(",");
        try write_turn(writer, alloc, message);
        emitted += 1;
    }
    if (open_user_turn) try writer.writeAll("]}");
    try writer.writeAll("]");

    if (functions.len > 0) {
        try writer.writeAll(",\"tools\":[");
        for (functions, 0..) |function, index| {
            if (index > 0) try writer.writeAll(",");
            try writer.writeAll("{\"name\":");
            try writeJsonString(writer, function.name);
            try writer.writeAll(",\"description\":");
            try writeJsonString(writer, function.description);
            try writer.writeAll(",\"input_schema\":");
            try writer.writeAll(function.schema);
            try writer.writeAll("}");
        }
        try writer.writeAll("]");
        if (options.tool_choice_mode == .send) {
            switch (request.tool_choice) {
                .auto, .none => try writer.writeAll(",\"tool_choice\":{\"type\":\"auto\"}"),
                .required => try writer.writeAll(",\"tool_choice\":{\"type\":\"any\"}"),
            }
        }
    }
    try writer.writeAll("}");
}

fn write_turn(writer: *std.Io.Writer, alloc: Allocator, message: types.ChatMessage) !void {
    const text = message.content orelse "";
    switch (message.role) {
        .system => {},
        .assistant => {
            try writer.writeAll("{\"role\":\"assistant\",\"content\":[");
            var first = true;
            if (text.len > 0) {
                try writer.writeAll("{\"type\":\"text\",\"text\":");
                try writeJsonString(writer, text);
                try writer.writeAll("}");
                first = false;
            }
            for (message.tool_calls) |call| {
                if (!first) try writer.writeAll(",");
                first = false;
                try writer.writeAll("{\"type\":\"tool_use\",\"id\":");
                try writeJsonString(writer, call.id);
                try writer.writeAll(",\"name\":");
                try writeJsonString(writer, call.name);
                try writer.writeAll(",\"input\":");
                // fx keeps arguments as JSON text; Anthropic wants the object.
                if (call.arguments_json.len > 0 and call.arguments_json[0] == '{') {
                    try writer.writeAll(call.arguments_json);
                } else {
                    try writer.writeAll("{}");
                }
                try writer.writeAll("}");
            }
            if (first) try writer.writeAll("{\"type\":\"text\",\"text\":\"\"}");
            try writer.writeAll("]}");
        },
        .tool => {
            // Written by the caller inside a merged user turn.
            try write_tool_result(writer, message);
        },
        .user => {
            try writer.writeAll("{\"role\":\"user\",\"content\":[");
            var first = true;
            if (text.len > 0) {
                try writer.writeAll("{\"type\":\"text\",\"text\":");
                try writeJsonString(writer, text);
                try writer.writeAll("}");
                first = false;
            }
            for (message.images) |image| {
                if (!first) try writer.writeAll(",");
                first = false;
                try write_image(writer, alloc, image);
            }
            if (first) try writer.writeAll("{\"type\":\"text\",\"text\":\"\"}");
            try writer.writeAll("]}");
        },
    }
}

fn write_tool_result(writer: *std.Io.Writer, message: types.ChatMessage) !void {
    try writer.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
    try writeJsonString(writer, message.tool_call_id orelse "");
    try writer.writeAll(",\"content\":");
    try writeJsonString(writer, message.content orelse "");
    if (message.tool_result_status) |status| {
        if (status == .failure) try writer.writeAll(",\"is_error\":true");
    }
    try writer.writeAll("}");
}

fn write_image(writer: *std.Io.Writer, alloc: Allocator, image: types.ImageAttachment) !void {
    // Anthropic takes inline base64 only; a path or URL is not part of the
    // format, so an attachment that has no bytes yet is skipped.
    if (image.inline_data) |bytes| {
        try writer.writeAll("{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":");
        try writeJsonString(writer, image.media_type);
        try writer.writeAll(",\"data\":");
        try writeBase64(writer, alloc, bytes);
        try writer.writeAll("}}");
        return;
    }
    try writer.writeAll("{\"type\":\"text\",\"text\":\"\"}");
}

fn writeBase64(writer: *std.Io.Writer, alloc: Allocator, bytes: []const u8) !void {
    if (bytes.len == 0) return writeJsonString(writer, "");
    const encoder = std.base64.standard.Encoder;
    const encoded = try alloc.alloc(u8, encoder.calcSize(bytes.len));
    defer alloc.free(encoded);
    _ = encoder.encode(encoded, bytes);
    try writeJsonString(writer, encoded);
}

fn writeJsonString(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            else => {
                if (byte < 0x20) {
                    try writer.print("\\u{x:0>4}", .{byte});
                } else {
                    try writer.writeByte(byte);
                }
            },
        }
    }
    try writer.writeByte('"');
}

// ---------------------------------------------------------------------------
// Reply parsing

/// Reduces Anthropic's typed event stream into fx's result.
pub const Reducer = struct {
    alloc: Allocator,
    /// Assistant text in arrival order.
    text: std.ArrayList(u8) = .empty,
    /// One entry per `content_block`, keyed by the index Anthropic sends.
    blocks: std.ArrayList(Block) = .empty,
    usage: types.Usage = .{},
    finished: bool = false,

    pub const Block = struct {
        kind: Kind = .unknown,
        /// For a `tool_use` block: the id and name.
        id: std.ArrayList(u8) = .empty,
        name: std.ArrayList(u8) = .empty,
        /// The `input` JSON assembled from `input_json_delta` fragments.
        input: std.ArrayList(u8) = .empty,
        /// For a `thinking` block: the reasoning text.
        thinking: std.ArrayList(u8) = .empty,

        pub const Kind = enum { text, tool_use, thinking, unknown };

        fn deinit(self: *Block, alloc: Allocator) void {
            self.id.deinit(alloc);
            self.name.deinit(alloc);
            self.input.deinit(alloc);
            self.thinking.deinit(alloc);
        }
    };

    pub fn init(alloc: Allocator) Reducer {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Reducer, alloc: Allocator) void {
        self.text.deinit(alloc);
        for (self.blocks.items) |*block| block.deinit(alloc);
        self.blocks.deinit(alloc);
        self.* = undefined;
    }

    /// Applies one `data:` payload from the event stream.
    pub fn applyJson(self: *Reducer, alloc: Allocator, payload: []const u8) !void {
        if (self.finished) return error.StreamClosed;
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{
            .duplicate_field_behavior = .use_last,
            .max_value_len = 8 * 1024 * 1024,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidChunk,
        };
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |object| object,
            else => return error.InvalidChunk,
        };
        const kind = fieldString(object, "type") orelse return error.InvalidChunk;
        if (std.mem.eql(u8, kind, "message_start")) {
            self.applyMessageStart(object);
        } else if (std.mem.eql(u8, kind, "content_block_start")) {
            try self.applyBlockStart(alloc, object);
        } else if (std.mem.eql(u8, kind, "content_block_delta")) {
            try self.applyBlockDelta(alloc, object);
        } else if (std.mem.eql(u8, kind, "content_block_stop")) {
            // The block accumulated as its deltas arrived.
        } else if (std.mem.eql(u8, kind, "message_delta")) {
            self.applyMessageDelta(object);
        } else if (std.mem.eql(u8, kind, "message_stop")) {
            self.finished = true;
        } else if (std.mem.eql(u8, kind, "error")) {
            return error.InvalidChunk;
        }
        // `ping` and any future event are ignored, so a new event does not break
        // an otherwise healthy stream.
    }

    fn applyMessageStart(self: *Reducer, object: std.json.ObjectMap) void {
        const message = object.get("message") orelse return;
        if (message != .object) return;
        const usage = message.object.get("usage") orelse return;
        if (usage != .object) return;
        self.usage.input_tokens = readCount(usage.object, "input_tokens") orelse self.usage.input_tokens;
        self.usage.output_tokens = readCount(usage.object, "output_tokens") orelse self.usage.output_tokens;
    }

    fn applyBlockStart(self: *Reducer, alloc: Allocator, object: std.json.ObjectMap) !void {
        const index = readIndex(object) orelse return error.InvalidChunk;
        const block_value = object.get("content_block") orelse return error.InvalidChunk;
        if (block_value != .object) return error.InvalidChunk;
        const block_object = block_value.object;
        const kind_name = fieldString(block_object, "type") orelse "";
        var block = Block{};
        if (std.mem.eql(u8, kind_name, "text")) {
            block.kind = .text;
            if (fieldString(block_object, "text")) |initial| {
                if (initial.len > 0) try self.text.appendSlice(alloc, initial);
            }
        } else if (std.mem.eql(u8, kind_name, "tool_use")) {
            block.kind = .tool_use;
            if (fieldString(block_object, "id")) |id| try block.id.appendSlice(alloc, id);
            if (fieldString(block_object, "name")) |name| try block.name.appendSlice(alloc, name);
            if (block_object.get("input")) |input| try appendJsonValue(alloc, &block.input, input);
        } else if (std.mem.eql(u8, kind_name, "thinking")) {
            block.kind = .thinking;
            if (fieldString(block_object, "thinking")) |initial| try block.thinking.appendSlice(alloc, initial);
        }
        try self.setBlock(alloc, index, block);
    }

    fn applyBlockDelta(self: *Reducer, alloc: Allocator, object: std.json.ObjectMap) !void {
        const index = readIndex(object) orelse return error.InvalidChunk;
        const delta = object.get("delta") orelse return error.InvalidChunk;
        if (delta != .object) return error.InvalidChunk;
        const kind_name = fieldString(delta.object, "type") orelse "";
        if (std.mem.eql(u8, kind_name, "text_delta")) {
            if (fieldString(delta.object, "text")) |text| try self.text.appendSlice(alloc, text);
            return;
        }
        const block = try self.blockAt(alloc, index);
        if (std.mem.eql(u8, kind_name, "input_json_delta")) {
            if (fieldString(delta.object, "partial_json")) |partial| try block.input.appendSlice(alloc, partial);
        } else if (std.mem.eql(u8, kind_name, "thinking_delta")) {
            if (fieldString(delta.object, "thinking")) |text| try block.thinking.appendSlice(alloc, text);
        }
    }

    fn applyMessageDelta(self: *Reducer, object: std.json.ObjectMap) void {
        const delta = object.get("delta") orelse return;
        if (delta != .object) return;
        const usage = object.get("usage") orelse return;
        if (usage != .object) return;
        self.usage.output_tokens = readCount(usage.object, "output_tokens") orelse self.usage.output_tokens;
        self.usage.input_tokens = readCount(usage.object, "input_tokens") orelse self.usage.input_tokens;
    }

    fn setBlock(self: *Reducer, alloc: Allocator, index: usize, block: Block) !void {
        while (self.blocks.items.len <= index) try self.blocks.append(alloc, .{});
        self.blocks.items[index].deinit(alloc);
        self.blocks.items[index] = block;
    }

    fn blockAt(self: *Reducer, alloc: Allocator, index: usize) !*Block {
        while (self.blocks.items.len <= index) try self.blocks.append(alloc, .{});
        return &self.blocks.items[index];
    }

    /// Produces the result once `message_stop` has been seen.
    pub fn finish(self: *Reducer, alloc: Allocator, cancelled: bool) Error!streams.Result {
        if (cancelled) return error.Cancelled;
        if (!self.finished) return error.IncompleteStream;
        var calls: std.ArrayList(types.ToolCall) = .empty;
        errdefer {
            for (calls.items) |call| {
                alloc.free(call.id);
                alloc.free(call.name);
                alloc.free(call.arguments_json);
            }
            calls.deinit(alloc);
        }
        var reasoning: std.ArrayList(u8) = .empty;
        defer reasoning.deinit(alloc);
        for (self.blocks.items) |block| {
            switch (block.kind) {
                .tool_use => {
                    const arguments_json = if (block.input.items.len == 0)
                        try alloc.dupe(u8, "{}")
                    else
                        try alloc.dupe(u8, block.input.items);
                    errdefer alloc.free(arguments_json);
                    try calls.append(alloc, .{
                        .id = try alloc.dupe(u8, block.id.items),
                        .name = try alloc.dupe(u8, block.name.items),
                        .arguments_json = arguments_json,
                    });
                },
                .thinking => try reasoning.appendSlice(alloc, block.thinking.items),
                else => {},
            }
        }
        const text = try alloc.dupe(u8, self.text.items);
        errdefer alloc.free(text);
        const reasoning_owned = if (reasoning.items.len > 0) try alloc.dupe(u8, reasoning.items) else null;
        return .{ .completed = .{
            .completion = .{
                .content = text,
                .tool_calls = try calls.toOwnedSlice(alloc),
                .reasoning = reasoning_owned,
                .usage = self.usage,
            },
        } };
    }
};

fn fieldString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn readIndex(object: std.json.ObjectMap) ?usize {
    const value = object.get("index") orelse return null;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        else => null,
    };
}

fn readCount(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        else => null,
    };
}

fn appendJsonValue(alloc: Allocator, out: *std.ArrayList(u8), value: std.json.Value) !void {
    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    std.json.Stringify.value(value, .{}, &writer.writer) catch return error.OutOfMemory;
    try out.appendSlice(alloc, writer.written());
}
