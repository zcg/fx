const std = @import("std");
const codec = @import("chat_completions_protocol.zig");
const anthropic = @import("anthropic_messages.zig");
const responses = @import("responses_protocol.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const client_mod = @import("client.zig");
const definitions = @import("../core/config/configured_provider.zig");
const streams = @import("../core/agent/stream_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const catalog = @import("../core/gateway/model_catalog.zig");
const model_listing = @import("model_listing.zig");
const listing_cache = @import("../core/gateway/model_listing_cache.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const model_catalog_metadata = @import("../core/gateway/model_catalog_metadata.zig");
const classifier = @import("../core/permissions/auto_classifier.zig");
const gateway_step = @import("../core/agent/runtime/gateway_step.zig");
const review_messages = @import("vercel_protocol.zig");
const io = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const types = @import("../core/shared/types.zig");
const model_provider = @import("../core/config/model_provider.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const sse = @import("sse.zig");
const Allocator = std.mem.Allocator;

/// Every callback borrows the immutable definition from the owning profile runtime.
pub fn bundle(definition: *const definitions.Definition) provider_set.Bundle {
    const context: *anyopaque = @ptrCast(@constCast(definition));
    return .{
        .agent_stream = .{ .context = context, .stream_fn = stream, .build_request_fn = build, .project_replay_fn = project_replay },
        .model_catalog = model_catalog_provider(definition),
        .cli_model_catalog = .{ .context = context, .fetch_fn = fetch_cli_catalog },
        .permission_reviewer = .{ .context = context, .review_fn = review },
    };
}

/// The models the definition declares; there is no network request. Borrows
/// the definition, which must outlive the provider.
pub fn model_catalog_provider(definition: *const definitions.Definition) catalog.Provider {
    const context: *anyopaque = @ptrCast(@constCast(definition));
    return .{
        .context = context,
        .fetch_fn = fetch_catalog,
        .fetch_cached_fn = fetch_cached_catalog,
        .lookup_capabilities_fn = lookup_capabilities,
        .provider_id = bound_identity(definition),
        // A configured provider's list is the vendor's own, and vendors add
        // models. A long interval keeps the list current without asking on
        // every menu open: the catalog refreshes in the background once it is
        // older than this.
        .refresh_interval_ms = null,
    };
}

fn definition_at(raw: ?*anyopaque) *const definitions.Definition {
    return @ptrCast(@alignCast(raw.?));
}

fn bound_identity(definition: *const definitions.Definition) model_provider.ProviderId {
    var identity = model_provider.parse(definition.id).?;
    identity.configured.binding = definition.binding_identity();
    return identity;
}

fn build(raw: ?*anyopaque, alloc: Allocator, request: streams.RequestData) ![]u8 {
    return build_for(definition_at(raw), alloc, request);
}

/// The request body for `definition`, omitting replay parts recorded for
/// another endpoint. Caller owns the result.
pub fn build_for(definition: *const definitions.Definition, alloc: Allocator, request: streams.RequestData) ![]u8 {
    const identity = bound_identity(definition);
    for (request.messages) |message| if (message.provider_replay) |replay| {
        if (!replay.matches(.{ .provider = identity, .model = request.model })) {
            debug_trace.logf("gateway", "provider_replay_omitted reason=source_mismatch", .{});
            break;
        }
    };
    return switch (definition.protocol) {
        .@"openai-chat-completions" => codec.build_request(alloc, request, .{ .tool_choice_mode = definition.tool_choice_mode, .provider = &identity }),
        .@"anthropic-messages" => anthropic.build_request(alloc, request, .{ .tool_choice_mode = definition.tool_choice_mode, .provider = &identity }),
        .@"openai-responses" => build_responses_request(alloc, request, identity),
    };
}

/// Replay limits for a configured provider's Responses request. The numbers
/// match what the subscription providers accept, which is the same shape the
/// endpoint reads.
const configured_replay_limits = responses.ReplayLimits{
    .tool_calls = 128,
    .tool_identity_bytes = 1024,
    .tool_arguments_bytes = 4 * 1024 * 1024,
    .provider_state_bytes = types.ProviderReplay.max_bytes,
};

/// The request body for a configured provider that speaks the Responses
/// protocol. The wire shape is the one `openai_codex` already sends, minus the
/// parts that only a subscription makes sense of: no stored conversation, no
/// encrypted reasoning include, and no priority service tier.
fn build_responses_request(
    alloc: Allocator,
    request: streams.RequestData,
    identity: model_provider.ProviderId,
) ![]u8 {
    try request.validatePrompt();
    const budget: image_attachments.CaptureBudget = if (request.budget) |value|
        .{ .deadline = value.deadline, .cancel_flag = value.cancel_flag }
    else
        .{};

    const projected = try types.projectProviderReplay(alloc, request.messages, .{
        .provider = identity,
        .model = request.model,
    });
    defer if (projected) |messages| alloc.free(messages);

    var instructions: std.Io.Writer.Allocating = .init(alloc);
    defer instructions.deinit();
    for (request.instructions) |instruction| {
        const text = instruction.content orelse continue;
        if (text.len == 0) continue;
        if (instructions.written().len > 0) try instructions.writer.writeAll("\n\n");
        try instructions.writer.writeAll(text);
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);
    try writer.writeAll(",\"store\":false,\"stream\":true");
    if (instructions.written().len > 0) {
        try writer.writeAll(",\"instructions\":");
        try std.json.Stringify.value(instructions.written(), .{}, writer);
    }
    try writer.writeAll(",\"input\":[");
    try responses.writeInput(
        writer,
        alloc,
        projected orelse request.messages,
        request.verified_images,
        configured_replay_limits,
        budget,
    );
    try writer.writeByte(']');

    if (request.tool_choice != .none) _ = try responses.writeTools(writer, alloc, request.tools);
    try writer.writeAll(",\"tool_choice\":");
    try std.json.Stringify.value(request.tool_choice.label(), .{}, writer);
    try writer.writeAll(",\"parallel_tool_calls\":true");
    if (request.max_output_tokens) |max| {
        try writer.writeAll(",\"max_output_tokens\":");
        try writer.print("{d}", .{max});
    }
    try writer.writeAll("}");
    return out.toOwnedSlice();
}

pub fn project_replay(alloc: Allocator, replay: ?types.ProviderReplay, calls: []const types.ToolCall, text: bool, reasoning: bool) !?types.ProviderReplay {
    if (replay) |value| {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, value.parts_json, " \t\r\n"), "[")) return responses.selectReplayParts(alloc, replay, calls, text, reasoning);
    }
    const selected = try codec.project_replay(alloc, replay, calls, text, reasoning);
    if (replay != null and selected == null) debug_trace.logf("gateway", "provider_replay_omitted reason={s}", .{if (reasoning) "associated_calls_removed" else "reasoning_removed"});
    return selected;
}

test "chat completions adapter binds replay to endpoint authority and wires projection" {
    const alloc = std.testing.allocator;
    var registry = try definitions.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:1234/v1","auth":{"type":"none"}}}
    );
    defer registry.deinit(alloc);
    var changed_registry = try definitions.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:5678/v1","auth":{"type":"none"}}}
    );
    defer changed_registry.deinit(alloc);
    const definition = registry.get("local").?;
    const adapter = bundle(definition).agent_stream.?;
    const replay: types.ProviderReplay = .{
        .source = .{ .provider = bundle(definition).model_catalog.?.provider_id, .model = "model" },
        .parts_json = "{\"reasoning_details\":[{\"signature\":\"signed\"}],\"_tool_call_ids\":[]}",
    };
    const selected = (try adapter.projectReplay(alloc, replay, &.{}, false, true)).?;
    try std.testing.expect(selected.parts_json.ptr == replay.parts_json.ptr);
    try std.testing.expect(try adapter.projectReplay(alloc, replay, &.{}, true, false) == null);
    const request: streams.RequestData = .{
        .model = "model",
        .instructions = &.{.{ .role = .system, .content = "instructions" }},
        .messages = &.{.{ .role = .assistant, .content = "answer", .provider_replay = replay }},
        .tool_choice = .auto,
        .provider_options = .{},
    };
    const matching = try adapter.build_request_fn.?(adapter.context, alloc, request);
    defer alloc.free(matching);
    try std.testing.expect(std.mem.find(u8, matching, "reasoning_details") != null);
    const other = bundle(changed_registry.get("local").?).agent_stream.?;
    const stripped = try other.build_request_fn.?(other.context, alloc, request);
    defer alloc.free(stripped);
    try std.testing.expect(std.mem.find(u8, stripped, "reasoning_details") == null);
    try std.testing.expect(request.messages[0].provider_replay.?.parts_json.ptr == replay.parts_json.ptr);
}

fn stream(raw: ?*anyopaque, alloc: Allocator, request: streams.ModelRequest) !streams.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const definition = definition_at(raw);
    if (request.credential.credentialSource() != .configured) return error.ConfiguredProviderCredentialRequired;
    const token = request.credential.secret();
    if (token) |value| {
        if (value.len > 16 * 1024) return error.InvalidConfiguredProviderCredential;
        for (value) |byte| if (byte <= 0x20 or byte >= 0x7f) return error.InvalidConfiguredProviderCredential;
    }
    switch (definition.auth) {
        .none => if (token != null) return error.UnexpectedConfiguredProviderCredential,
        .bearer => if (token == null) return error.MissingConfiguredProviderCredential,
    }
    const payload = request.prepared_request_body orelse try build(raw, alloc, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);
    return post(alloc, definition, request, token, payload) catch |err| {
        request.attempt_evidence.network_failure = client_mod.networkFailureEvidence(err, request.delivery.load());
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (request.deadline) |deadline| if (expired(deadline)) return error.Timeout;
        return err;
    };
}

fn expired(deadline: std.Io.Clock.Timestamp) bool {
    return !std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io.getIo(), .awake), .lt, deadline);
}

fn phase_deadline(milliseconds: i64, caller: ?std.Io.Clock.Timestamp) std.Io.Clock.Timestamp {
    const phase = std.Io.Clock.Timestamp.fromNow(io.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(milliseconds) });
    if (caller) |deadline| if (std.Io.Clock.Timestamp.compare(deadline, .lt, phase)) return deadline;
    return phase;
}

fn post(alloc: Allocator, definition: *const definitions.Definition, request: streams.ModelRequest, token: ?[]const u8, payload: []const u8) !streams.Result {
    const url = try definition.chat_url(alloc);
    defer alloc.free(url);
    const authorization = if (token) |value| try alloc.print("Bearer {s}", .{value}) else null;
    defer if (authorization) |value| secret.zeroAndFree(alloc, value);
    var client: std.http.Client = .{ .allocator = alloc, .io = io.getIo() };
    defer client.deinit();
    var uri = try std.Uri.parse(url);
    uri.scheme = if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) "https" else if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) "http" else return error.UnsupportedUriScheme;
    const anthropic_headers = [_]std.http.Header{
        .{ .name = "accept", .value = "text/event-stream" },
        .{ .name = "anthropic-version", .value = anthropic.api_version },
        .{ .name = "x-api-key", .value = token orelse "" },
    };
    var operation = client_mod.PostOperation{
        .client = &client,
        .uri = uri,
        .authorization = if (definition.protocol == .@"anthropic-messages") null else authorization,
        .extra_headers = if (definition.protocol == .@"anthropic-messages") anthropic_headers[0..(if (token != null) @as(usize, 3) else 2)] else &.{.{ .name = "accept", .value = "text/event-stream" }},
    };
    try request.admission.admit();
    var opened = try client_mod.openBoundedPost(alloc, request.cancel_flag, phase_deadline(30_000, request.deadline), &operation);
    defer opened.deinit(alloc);
    const http = &opened.request.?;
    var watch: client_mod.ConnectionWatch = .init(.{
        .timeout_ms = 120_000,
        .stall_timeout_ms = client_mod.ConnectionWatch.bodyStallTimeoutMs(request.deadline),
    });
    defer watch.stop();
    if (http.connection) |connection| try watch.start(request.cancel_flag, request.deadline, connection.stream_writer.stream);
    // The 120 s head wait also bounds sending the request.
    if (watch.armHead()) |err| return err;
    http.transfer_encoding = .{ .content_length = payload.len };
    var buffer: [8192]u8 = undefined;
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    request.delivery.markPossiblySent();
    var body = try http.sendBodyUnflushed(&buffer);
    try body.writer.writeAll(payload);
    try body.end();
    if (http.connection) |connection| try connection.flush();
    var response = http.receiveHead(&.{}) catch |err| return watch.failure(err);
    if (watch.commitHead()) |err| return err;
    if (response.head.status != .ok) {
        // An error body is read under its own 30 s bound.
        watch.stop();
        watch = .init(.{ .patient = true, .stall_timeout_ms = std.math.maxInt(i64) });
        if (http.connection) |connection| try watch.start(request.cancel_flag, phase_deadline(30_000, request.deadline), connection.stream_writer.stream);
    }
    var retry_after: ?u64 = null;
    var headers = response.head.iterateHeaders();
    while (headers.next()) |header| if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
        retry_after = std.fmt.parseUnsigned(u64, std.mem.trim(u8, header.value, " \t"), 10) catch null;
        break;
    };
    var transfer: [64 * 1024]u8 = undefined;
    const reader = response.reader(&transfer);
    if (response.head.status != .ok) {
        var detail = reader.allocRemaining(alloc, .limited(64 * 1024)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, "Provider error response exceeded the local limit"),
            else => return err,
        };
        errdefer alloc.free(detail);
        if (token) |value| {
            const redacted = try codec.redact_error_detail(alloc, detail, value);
            alloc.free(detail);
            detail = redacted;
        }

        return .{ .failed = .{ .kind = client_mod.httpFailureKind(alloc, .fromHttpStatus(response.head.status), detail), .detail = detail, .retry_after_seconds = retry_after, .ownership = .owned } };
    }
    var result = (switch (definition.protocol) {
        .@"openai-chat-completions" => consume(alloc, reader, request, watch.progress()),
        .@"openai-responses" => consumeResponses(alloc, reader, request),
        .@"anthropic-messages" => consumeAnthropic(alloc, reader, request),
    }) catch |err| {
        const failure = watch.failure(err);
        return switch (failure) {
            error.ResponsesReasoningConflict,
            error.ResponsesTextConflict,
            error.ResponsesToolCallConflict,
            error.ResponsesOutputItemConflict,
            error.InvalidEvent,
            error.InvalidChunk,
            error.StreamIncomplete,
            error.IncompleteStream,
            => .{ .failed = .{ .kind = .server_error, .detail = try alloc.dupe(u8, "The provider returned an inconsistent response stream; retrying."), .ownership = .owned } },
            else => failure,
        };
    };
    if (watch.finish()) |err| {
        result.deinit(alloc);
        return err;
    }
    return result;
}

/// Parses a successful streamed reply from `reader`, telling `progress` about
/// each event when it is set.
pub fn consume(alloc: Allocator, reader: *std.Io.Reader, request: streams.ModelRequest, progress: ?sse.Progress) !streams.Result {
    var limits: codec.Limits = .{};
    if (request.content_capture_limit) |limit| limits.content_bytes = @min(limit, limits.content_bytes);
    return codec.consume_stream(alloc, reader, request.data(), limits, request.events, request.cancel_flag, progress);
}

/// Parses a streamed Anthropic reply. Anthropic frames events as `event:` and
/// `data:` lines and ends a message with `message_stop`, so the reducer reads
/// the `data:` payloads in order and finishes when it sees that event.
pub fn consumeAnthropic(alloc: Allocator, reader: *std.Io.Reader, request: streams.ModelRequest) !streams.Result {
    var reducer = anthropic.Reducer.init(alloc);
    defer reducer.deinit(alloc);
    var framing = sse.Reader{ .max_event_bytes = 1024 * 1024, .max_total_bytes = 32 * 1024 * 1024 };
    defer framing.deinit(alloc);
    var reasoning_emitted: usize = 0;
    while (try framing.next(alloc, reader, request.cancel_flag)) |payload| {
        const text_before = reducer.text.items.len;
        try reducer.applyJson(alloc, payload);
        if (reducer.text.items.len > text_before) request.events.emit(.{ .content_delta = reducer.text.items[text_before..] });
        var reasoning_offset: usize = 0;
        for (reducer.blocks.items) |block| {
            const thinking = block.thinking.items;
            const skip = reasoning_emitted -| reasoning_offset;
            if (skip < thinking.len) request.events.emit(.{ .reasoning_delta = thinking[skip..] });
            reasoning_offset += thinking.len;
        }
        reasoning_emitted = reasoning_offset;
        if (reducer.finished) break;
    }
    return reducer.finish(alloc, request.cancel_flag.load(.seq_cst));
}

/// Default stream bounds for a configured provider's Responses reply. They
/// match what the streaming codec already allows the other protocols, so a
/// provider cannot make fx allocate without bound by sending a large reply.
const configured_stream_limits = responses.StreamLimits{
    .aggregate_bytes = 64 * 1024 * 1024,
    .events = 100_000,
    .tool_calls = 128,
    .tool_identity_bytes = configured_replay_limits.tool_identity_bytes,
    .tool_arguments_bytes = configured_replay_limits.tool_arguments_bytes,
    .provider_state_bytes = types.ProviderReplay.max_bytes,
    .omit_conflicting_reasoning = true,
};

test "configured Responses replays tool arguments larger than 256 KiB and omits disabled tools" {
    const alloc = std.testing.allocator;
    const definition = definitions.Definition{
        .id = "local",
        .protocol = .@"openai-responses",
        .base_url = "http://localhost:1234/v1",
        .auth = .none,
    };
    const arguments = try alloc.alloc(u8, 300 * 1024);
    defer alloc.free(arguments);
    @memcpy(arguments[0..9], "{\"text\":\"");
    @memset(arguments[9 .. arguments.len - 2], 'a');
    @memcpy(arguments[arguments.len - 2 ..], "\"}");
    const calls = [_]types.ToolCall{.{ .id = "call_large", .name = "write_file", .arguments_json = arguments }};
    const body = try build_for(&definition, alloc, .{
        .model = "test-model",
        .messages = &.{.{ .role = .assistant, .tool_calls = &calls }},
        .tool_choice = .none,
        .provider_options = .{},
    });
    defer alloc.free(body);
    try std.testing.expect(body.len > arguments.len);
    try std.testing.expect(std.mem.find(u8, body, "\"tools\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_choice\":\"none\"") != null);
    try std.testing.expect(configured_replay_limits.tool_arguments_bytes >= configured_stream_limits.tool_arguments_bytes);
}

/// Parses a streamed Responses reply. The shape differs enough from
/// chat-completions - typed events, an output array, tool items that arrive as
/// their own events - that the protocol has its own reducer, so the configured
/// provider has to read it with that one rather than the chat decoder.
pub fn consumeResponses(alloc: Allocator, reader: *std.Io.Reader, request: streams.ModelRequest) !streams.Result {
    var reducer = responses.Reducer.init(alloc);
    defer reducer.deinit(alloc);
    var reader_sse = sse.Reader{ .max_event_bytes = 32 * 1024 * 1024, .max_total_bytes = configured_stream_limits.aggregate_bytes };
    defer reader_sse.deinit(alloc);

    // `EventSink` already adapts its context to these callback shapes, which is
    // the same adapter the chat and Anthropic decoders use.
    const callbacks = responses.StreamCallbacks{
        .context = @ptrCast(@constCast(&request.events)),
        .on_content = streams.EventSink.onContentChunk,
        .on_tool_start = streams.EventSink.onLocalToolStart,
        .on_reasoning = streams.EventSink.onReasoningChunk,
        .on_tool_input = streams.EventSink.onToolInputChunk,
    };

    const cancel_flag = request.cancel_flag;
    const completion = completion: {
        while (reader_sse.next(alloc, reader, cancel_flag) catch |err| return err) |json_text| {
            if (std.mem.eql(u8, json_text, "[DONE]")) break;
            if (reducer.applyJson(
                alloc,
                json_text,
                callbacks,
                cancel_flag,
                request.content_capture_limit,
                configured_stream_limits,
            ) catch |err| return err) break;
        }
        break :completion reducer.finish(alloc, cancel_flag, configured_stream_limits) catch |err| return err;
    };
    return .{ .completed = .{ .completion = completion, .ownership = .owned } };
}

/// The returned entry borrows its strings; fetch_catalog replaces them with owned copies.
fn metadata_entry(metadata: definitions.ModelMetadata) catalog.ModelCatalogEntry {
    const vision = metadata.supports_vision orelse false;
    return .{
        .id = @constCast(metadata.id),
        .model_type = @constCast("language"),
        .has_tool_use = metadata.supports_tool_use orelse false,
        // Chat completions sends images as inline base64 content parts, so
        // vision support implies file input through the same path.
        .has_vision = vision,
        .has_file_input = vision,
        .context_window = metadata.context_window orelse 0,
        .max_tokens = metadata.max_output_tokens orelse 0,
    };
}

fn lookup_capabilities(raw: ?*anyopaque, model: []const u8) model_capabilities.Capabilities {
    const metadata = definition_at(raw).model(model) orelse return .{};
    var capabilities = model_capabilities.mergeCapabilities(.{}, model_catalog_metadata.fromCatalogEntry(metadata_entry(metadata.*)));
    // A configured provider's model names its own thinking levels, in its own
    // order: one vendor offers low..high, another minimal..max. Taking them
    // from the declaration is what lets the picker offer them
    // (docs/audit/2026-11-06-full-review.md section 18.6).
    if (metadata.reasoning_efforts.len > 0) {
        capabilities.supports_reasoning = true;
        capabilities.reasoning_efforts = .fromSlice(metadata.reasoning_efforts);
    } else if (metadata.supports_reasoning) |declared| {
        capabilities.supports_reasoning = declared;
    }
    return capabilities;
}

fn fetch_cached_catalog(raw: ?*anyopaque, alloc: Allocator) Allocator.Error!?std.ArrayList(catalog.ModelCatalogEntry) {
    const definition = definition_at(raw);
    const body = (listing_cache.load(alloc, definition) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return null;
    }) orelse return null;
    defer alloc.free(body);
    var listing = model_listing.parse(alloc, body) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return null;
    };
    defer listing.deinit();
    var entries: std.ArrayList(catalog.ModelCatalogEntry) = .empty;
    errdefer catalog.freeModelCatalog(alloc, &entries);
    try model_listing.mergeInto(alloc, definition, listing, &entries);
    return entries;
}

fn fetch_catalog(raw: ?*anyopaque, alloc: Allocator, input: catalog.FetchInput) Allocator.Error!catalog.ProviderResult {
    if (input.cancel_flag) |flag| if (flag.load(.seq_cst)) return .{ .failure = .{ .category = .cancellation } };
    const definition = definition_at(raw);
    var entries: std.ArrayList(catalog.ModelCatalogEntry) = .empty;
    errdefer catalog.freeModelCatalog(alloc, &entries);

    // A provider that lists its models is asked first: the list is the vendor's
    // own and changes as it ships models, while the declared metadata only says
    // which of them fx should present and what the listing cannot express. A
    // listing that fails or does not parse leaves the declared set, so a
    // provider whose key is missing still shows the models the user configured.
    var listing: ?model_listing.Listing = null;
    defer if (listing) |*value| value.deinit();
    if (definition.model_listing == .listed) {
        listing = fetchListing(alloc, definition, input) catch |err| blk: {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            debug_trace.logf("gateway", "configured_model_listing_unavailable reason={s}", .{@errorName(err)});
            if (definition.model_metadata.len == 0) return .{ .failure = .{ .category = switch (err) {
                error.Cancelled => .cancellation,
                error.AuthenticationRejected, error.MissingConfiguredProviderCredential => .authentication,
                error.MalformedListing => .malformed_response,
                else => .transport,
            } } };
            break :blk null;
        };
    }
    if (listing) |value| {
        try model_listing.mergeInto(alloc, definition, value, &entries);
        return .{ .catalog = entries };
    }

    for (definition.model_metadata) |metadata| {
        var entry = metadata_entry(metadata);
        entry.id = try alloc.dupe(u8, entry.id);
        errdefer alloc.free(entry.id);
        entry.model_type = try alloc.dupe(u8, entry.model_type);
        errdefer alloc.free(entry.model_type);
        try entries.append(alloc, entry);
    }
    return .{ .catalog = entries };
}

/// Lists models using the same saved key as chat requests.
fn fetchListing(alloc: Allocator, definition: *const definitions.Definition, input: catalog.FetchInput) !model_listing.Listing {
    const url = try definition.models_url(alloc);
    defer alloc.free(url);
    const token = try listingToken(alloc, definition);
    defer if (token) |value| secret.zeroAndFree(alloc, value);
    var cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = input.cancel_flag orelse &cancel;
    const anthropic_headers = [_]std.http.Header{
        .{ .name = "anthropic-version", .value = anthropic.api_version },
        .{ .name = "x-api-key", .value = token orelse "" },
    };
    const result = if (definition.protocol == .@"anthropic-messages")
        try client_mod.fetchProviderJsonCancellable(alloc, url, anthropic_headers[0..(if (token != null) @as(usize, 2) else 1)], cancel_flag)
    else
        try client_mod.fetchGatewayJsonCancellable(alloc, token, null, url, cancel_flag);
    return switch (result) {
        .success => |body| blk: {
            defer alloc.free(body);
            var listing = try model_listing.parse(alloc, body);
            errdefer listing.deinit();
            const previous_bytes = listing_cache.load(alloc, definition) catch null;
            defer if (previous_bytes) |bytes| alloc.free(bytes);
            if (previous_bytes) |bytes| {
                var previous = model_listing.parse(alloc, bytes) catch null;
                if (previous) |*old| {
                    defer old.deinit();
                    for (listing.entries) |*entry| {
                        entry.added = for (old.entries) |prior| {
                            if (std.mem.eql(u8, entry.id, prior.id)) break false;
                        } else true;
                    }
                }
            }
            listing_cache.save(alloc, definition, body) catch |err| {
                debug_trace.logf("catalog", "model listing fetched but cache write failed err={s}", .{@errorName(err)});
            };
            break :blk listing;
        },
        .http_status => |status| if (status == .unauthorized or status == .forbidden) error.AuthenticationRejected else error.ListingRefused,
    };
}

/// The token the provider's own listing accepts, or null when it needs none.
fn listingToken(alloc: Allocator, definition: *const definitions.Definition) !?[]u8 {
    switch (definition.auth) {
        .none => return null,
        .bearer => |key| return if (key.len == 0) error.MissingConfiguredProviderCredential else try alloc.dupe(u8, key),
    }
}

test "configured capability lookup matches catalog projection and preserves unknowns" {
    const alloc = std.testing.allocator;
    var registry = try definitions.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:1234/v1","auth":{"type":"none"},"model_metadata":{"small":{"context_window":8192,"max_output_tokens":512,"supports_tool_use":true,"supports_vision":true},"large":{"context_window":32768,"max_output_tokens":1024,"supports_tool_use":false},"partial":{"max_output_tokens":128},"unknown":{}}}}
    );
    defer registry.deinit(alloc);
    const provider = bundle(registry.get("local").?).model_catalog.?;
    var fetched = try provider.fetch(alloc, .{ .endpoint = "unused" });
    defer catalog.freeModelCatalog(alloc, &fetched.catalog);
    for (fetched.catalog.items) |entry| {
        const actual = provider.lookupCapabilities(entry.id).?;
        try std.testing.expectEqualDeep(model_capabilities.mergeCapabilities(.{}, model_catalog_metadata.fromCatalogEntry(entry)), actual);
        const declared_vision = std.mem.eql(u8, entry.id, "small");
        try std.testing.expectEqual(declared_vision, actual.supports_vision);
        try std.testing.expectEqual(
            if (declared_vision) model_capabilities.ImageInputSupport.native else model_capabilities.ImageInputSupport.non_native,
            actual.image_input_support,
        );
    }
    try std.testing.expectEqual(@as(?u32, 512), provider.lookupCapabilities("small").?.max_output_tokens);
    try std.testing.expectEqual(@as(?u32, 1024), provider.lookupCapabilities("large").?.max_output_tokens);
    try std.testing.expect(provider.lookupCapabilities("partial").?.context_window == null);
    try std.testing.expect(provider.lookupCapabilities("unknown").?.max_output_tokens == null);
    try std.testing.expectEqualDeep(model_capabilities.Capabilities{}, provider.lookupCapabilities("missing-fast").?);
}

fn fetch_cli_catalog(raw: ?*anyopaque, alloc: Allocator, input: gateway_provider.CliModelCatalogInput) gateway_provider.CliModelCatalogResult {
    const provenance = catalog.Provenance{ .access = catalog.AccessMetadata.init(input.access) };
    const result = fetch_catalog(raw, alloc, .{ .access = input.access, .endpoint = input.endpoint, .cancel_flag = input.cancel_flag }) catch
        return .{ .failure = .{ .access = provenance.access, .anonymous_fallback_used = false, .failure = .{ .category = .resource_exhausted } } };
    switch (result) {
        .failure => |failure| return .{ .failure = .{ .access = provenance.access, .anonymous_fallback_used = false, .failure = failure } },
        .catalog => |value| {
            // The entries carry the metadata the listing read: each model's own
            // upstream vendor and limits. Returning them alongside the ids keeps
            // the caller from having to ask again.
            return .{ .loaded = .{ .ids = catalog.projectModelIds(alloc, value.items) catch
                return .{ .failure = .{ .access = provenance.access, .anonymous_fallback_used = false, .failure = .{ .category = .resource_exhausted } } }, .entries = value, .provenance = provenance } };
        },
    }
}

const Review = struct { definition: *const definitions.Definition, input: classifier.ProviderInput };
fn review(raw: ?*anyopaque, alloc: Allocator, input: classifier.ProviderInput, request: classifier.ReviewRequest) !classifier.ParseOutcome {
    var state = Review{ .definition = definition_at(raw), .input = input };
    return classifier.Reviewer.withTransportModel(.{ .context = &state, .build_fn = build_review, .send_fn = send_review }, input.cancel_flag, classifier.Reviewer.default_timeout_ms, state.definition.reviewer_model orelse request.review_turn.model).review(alloc, request);
}
fn build_review(raw: *anyopaque, alloc: Allocator, model: []const u8, _: []const u8, instructions: []const types.ChatMessage, messages: []const types.ChatMessage, target_id: []const u8, deadline: std.Io.Clock.Timestamp, cancel: *std.atomic.Value(bool)) ![]u8 {
    const state: *Review = @ptrCast(@alignCast(raw));
    const expanded = try review_messages.expandPendingToolReviewMessages(alloc, messages, target_id, deadline, cancel);
    defer alloc.free(expanded);
    const output_limit = if (state.definition.model(model)) |metadata| @min(metadata.max_output_tokens orelse 2048, 2048) else 2048;
    return build(@ptrCast(@constCast(state.definition)), alloc, .{ .model = model, .instructions = instructions, .messages = expanded, .tools = .{ .additional_functions = &.{classifier.function_schema} }, .tool_choice = .required, .provider_options = .{}, .max_output_tokens = output_limit });
}
fn ignore_event(_: *anyopaque, _: streams.Event) void {}
fn free_result(raw: *anyopaque, alloc: Allocator) void {
    const result: *streams.Result = @ptrCast(@alignCast(raw));
    result.deinit(alloc);
    alloc.destroy(result);
}
fn send_review(raw: *anyopaque, alloc: Allocator, model: []const u8, payload: []const u8, deadline: std.Io.Clock.Timestamp, cancel: *std.atomic.Value(bool)) !classifier.TransportOutcome {
    const state: *Review = @ptrCast(@alignCast(raw));
    var delivery: streams.DeliveryCertainty = .init();
    var evidence: streams.AttemptEvidence = .{};
    var event_context: u8 = 0;
    var result = gateway_step.streamModelCompletion(bundle(state.definition).agent_stream.?, alloc, .{
        .credential = .{ .direct = .{ .secret_bytes = state.input.credential, .source = state.input.credential_source } },
        .model = model,
        .retry_count = 1,
        .messages = &.{},
        .tools = .{ .additional_functions = &.{classifier.function_schema} },
        .tool_choice = .required,
        .provider_options = .{},
        .prepared_request_body = payload,
        .trace_ctx = .{},
        .content_capture_limit = 16 * 1024,
        .deadline = deadline,
        .delivery = &delivery,
        .attempt_evidence = &evidence,
        .events = .{ .context = &event_context, .emit_fn = ignore_event },
        .cancel_flag = cancel,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => return .cancelled,
        error.Timeout => return .timed_out,
        error.RequiredToolMissing => return .{ .completion = .{ .completion = .{} } },
        else => return .permanent_failure,
    };
    errdefer result.deinit(alloc);
    // A review the output limit cut off holds no decision, and the same
    // review would be cut off again, so it stays unavailable.
    const cut_off = result == .completed and result.completed.completion.finish_reason == .length;
    if (result == .failed or cut_off) {
        result.deinit(alloc);
        return .permanent_failure;
    }
    const owned = try alloc.create(streams.Result);
    owned.* = result;
    return .{ .completion = .{ .completion = owned.completed.completion, .context = owned, .deinit_fn = free_result } };
}
