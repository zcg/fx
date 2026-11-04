//! Reads the model list a configured provider reports about itself.
//!
//! A configured provider's `model_metadata` describes the fields fx needs but a
//! vendor cannot tell us, such as the context window when the listing omits it.
//! The list of models itself belongs to the provider: it changes as the vendor
//! ships new ones, and a hand-written list goes stale. This module asks the
//! provider and reads the reply in whichever of the shapes providers use.
//!
//! Three shapes cover the endpoints people point fx at:
//!
//! * `{"data":[{"id":"...", ...}]}` — OpenAI and everything that copies it,
//!   including OpenRouter, Groq, DeepSeek, Mistral, and local runtimes.
//! * `{"data":[{"id":"...", ...}]}` under a different key layout for Anthropic's
//!   own listing, whose entries carry `display_name`.
//! * `{"models":[{"name":"models/..."}]}` — Google's Generative Language API,
//!   which also returns the context and output limits in the same entry.
//!
//! Reading is deliberately tolerant: a field this module does not know is
//! ignored, and a field it needs but cannot read drops that one entry rather than
//! failing the whole listing. A provider whose listing is refused keeps the
//! declared metadata, so the user still sees the models they configured.

const std = @import("std");
const definitions = @import("../core/config/configured_provider.zig");
const catalog = @import("../core/gateway/model_catalog.zig");
const Allocator = std.mem.Allocator;

/// A listing reply larger than this is not a model list; it is a mistake.
const max_listing_bytes = 8 * 1024 * 1024;

/// One model as the provider described it. Every field beyond `id` is what the
/// provider happened to include, so absence stays absent.
pub const Entry = struct {
    id: []const u8,
    /// The provider's own name for the model, when it has one.
    display_name: ?[]const u8 = null,
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
};

/// Owned list of entries; free with `deinit`.
pub const Listing = struct {
    entries: []Entry,
    alloc: Allocator,

    pub fn deinit(self: *Listing) void {
        for (self.entries) |entry| {
            self.alloc.free(entry.id);
            if (entry.display_name) |name| self.alloc.free(name);
        }
        self.alloc.free(self.entries);
        self.* = undefined;
    }
};

pub const ParseError = Allocator.Error || error{MalformedListing};

/// Reads a listing reply. The shapes are told apart by the keys present, not by
/// a vendor name, because a provider may copy another vendor's shape exactly.
pub fn parse(alloc: Allocator, body: []const u8) ParseError!Listing {
    if (body.len > max_listing_bytes) return error.MalformedListing;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{
        .duplicate_field_behavior = .use_last,
        .max_value_len = 4096,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedListing,
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.MalformedListing,
    };

    // Google's listing names the array `models` and prefixes each id with
    // `models/`. Everything else uses `data`.
    if (root.get("models")) |models| return parseEntries(alloc, models, .google);
    if (root.get("data")) |data| return parseEntries(alloc, data, .generic);
    return error.MalformedListing;
}

const Shape = enum { generic, google };

fn parseEntries(alloc: Allocator, value: std.json.Value, shape: Shape) ParseError!Listing {
    const array = switch (value) {
        .array => |array| array,
        else => return error.MalformedListing,
    };
    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            alloc.free(entry.id);
            if (entry.display_name) |name| alloc.free(name);
        }
        entries.deinit(alloc);
    }
    try entries.ensureTotalCapacity(alloc, array.items.len);
    for (array.items) |item| {
        const object = switch (item) {
            .object => |object| object,
            else => continue,
        };
        const raw_id = switch (shape) {
            .generic => object.get("id"),
            .google => object.get("name"),
        };
        const id_value = raw_id orelse continue;
        if (id_value != .string) continue;
        const id = stripGooglePrefix(id_value.string, shape);
        if (id.len == 0) continue;
        const display = blk: {
            const key = switch (shape) {
                .generic => "display_name",
                .google => "displayName",
            };
            const value_display = object.get(key) orelse break :blk null;
            if (value_display != .string or value_display.string.len == 0) break :blk null;
            break :blk try alloc.dupe(u8, value_display.string);
        };
        errdefer if (display) |name| alloc.free(name);
        entries.appendAssumeCapacity(.{
            .id = try alloc.dupe(u8, id),
            .display_name = display,
            .context_window = readLimit(object, shape, .context),
            .max_output_tokens = readLimit(object, shape, .output),
        });
    }
    return .{ .entries = try entries.toOwnedSlice(alloc), .alloc = alloc };
}

fn stripGooglePrefix(id: []const u8, shape: Shape) []const u8 {
    if (shape != .google) return id;
    const prefix = "models/";
    if (std.mem.startsWith(u8, id, prefix)) return id[prefix.len..];
    return id;
}

const Limit = enum { context, output };

fn readLimit(object: std.json.ObjectMap, shape: Shape, limit: Limit) ?u32 {
    const keys: []const []const u8 = switch (shape) {
        // OpenAI-compatible listings rarely carry limits; OpenRouter does.
        .generic => switch (limit) {
            .context => &.{ "context_length", "context_window", "max_context_length" },
            .output => &.{ "max_output_tokens", "max_completion_tokens", "top_provider_max_completion_tokens" },
        },
        .google => switch (limit) {
            .context => &.{"inputTokenLimit"},
            .output => &.{"outputTokenLimit"},
        },
    };
    for (keys) |key| {
        const value = object.get(key) orelse continue;
        switch (value) {
            .integer => |number| {
                if (number > 0 and number <= std.math.maxInt(u32)) return @intCast(number);
            },
            // A nested `top_provider` object carries the completion limit.
            .object => |nested| {
                const inner = nested.get("max_completion_tokens") orelse continue;
                if (inner != .integer) continue;
                if (inner.integer > 0 and inner.integer <= std.math.maxInt(u32)) return @intCast(inner.integer);
            },
            else => continue,
        }
    }
    return null;
}

/// Folds a provider's listing into the catalog entries fx presents.
///
/// A model the definition declares keeps its declared metadata and gains the
/// listing's name; a model only the listing knows gets the listing's fields. The
/// declared list therefore orders the picker, and new models still appear.
pub fn mergeInto(
    alloc: Allocator,
    definition: *const definitions.Definition,
    listing: Listing,
    out: *std.ArrayList(catalog.ModelCatalogEntry),
) Allocator.Error!void {
    try out.ensureUnusedCapacity(alloc, definition.model_metadata.len + listing.entries.len);
    // Declared models first, in their declared order.
    for (definition.model_metadata) |metadata| {
        var entry = try declaredEntry(alloc, metadata);
        errdefer catalog.freeModelCatalogEntry(alloc, entry);
        if (listingEntry(listing.entries, metadata.id)) |listed| {
            if (listed.display_name) |name| entry.name = try alloc.dupe(u8, name);
            if (entry.context_window == 0) {
                if (listed.context_window) |window| entry.context_window = window;
            }
            if (entry.max_tokens == 0) {
                if (listed.max_output_tokens) |limit| entry.max_tokens = limit;
            }
        }
        out.appendAssumeCapacity(entry);
    }
    // Then anything the listing adds.
    for (listing.entries) |listed| {
        if (declares(definition.model_metadata, listed.id)) continue;
        var entry = catalog.ModelCatalogEntry{
            .id = try alloc.dupe(u8, listed.id),
            .model_type = try alloc.dupe(u8, "language"),
            .context_window = listed.context_window orelse 0,
            .max_tokens = listed.max_output_tokens orelse 0,
        };
        errdefer catalog.freeModelCatalogEntry(alloc, entry);
        if (listed.display_name) |name| entry.name = try alloc.dupe(u8, name);
        out.appendAssumeCapacity(entry);
    }
}

fn declaredEntry(alloc: Allocator, metadata: definitions.ModelMetadata) Allocator.Error!catalog.ModelCatalogEntry {
    return .{
        .id = try alloc.dupe(u8, metadata.id),
        .model_type = try alloc.dupe(u8, "language"),
        .has_tool_use = metadata.supports_tool_use orelse false,
        .has_vision = metadata.supports_vision orelse false,
        .context_window = metadata.context_window orelse 0,
        .max_tokens = metadata.max_output_tokens orelse 0,
    };
}

fn listingEntry(entries: []const Entry, id: []const u8) ?Entry {
    for (entries) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
    return null;
}

fn declares(metadata: []const definitions.ModelMetadata, id: []const u8) bool {
    for (metadata) |declared| if (std.mem.eql(u8, declared.id, id)) return true;
    return false;
}

test "reads an OpenAI-compatible listing" {
    const alloc = std.testing.allocator;
    var listing = try parse(alloc,
        \\{"object":"list","data":[{"id":"gpt-4o","object":"model"},{"id":"o3-mini"},{"id":""},{"object":"model"}]}
    );
    defer listing.deinit();
    try std.testing.expectEqual(@as(usize, 2), listing.entries.len);
    try std.testing.expectEqualStrings("gpt-4o", listing.entries[0].id);
    try std.testing.expectEqualStrings("o3-mini", listing.entries[1].id);
}

test "reads context limits from an OpenRouter-shaped listing" {
    const alloc = std.testing.allocator;
    var listing = try parse(alloc,
        \\{"data":[{"id":"anthropic/claude-sonnet-4","name":"Claude Sonnet 4","context_length":200000,"top_provider":{"max_completion_tokens":64000}}]}
    );
    defer listing.deinit();
    try std.testing.expectEqual(@as(usize, 1), listing.entries.len);
    try std.testing.expectEqual(@as(?u32, 200000), listing.entries[0].context_window);
    try std.testing.expectEqual(@as(?u32, 64000), listing.entries[0].max_output_tokens);
}

test "reads a Google listing and strips the models prefix" {
    const alloc = std.testing.allocator;
    var listing = try parse(alloc,
        \\{"models":[{"name":"models/gemini-2.5-pro","displayName":"Gemini 2.5 Pro","inputTokenLimit":1048576,"outputTokenLimit":65536}]}
    );
    defer listing.deinit();
    try std.testing.expectEqual(@as(usize, 1), listing.entries.len);
    try std.testing.expectEqualStrings("gemini-2.5-pro", listing.entries[0].id);
    try std.testing.expectEqualStrings("Gemini 2.5 Pro", listing.entries[0].display_name.?);
    try std.testing.expectEqual(@as(?u32, 1048576), listing.entries[0].context_window);
    try std.testing.expectEqual(@as(?u32, 65536), listing.entries[0].max_output_tokens);
}

test "a reply that is not a listing is reported, not guessed at" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.MalformedListing, parse(alloc, "{\"error\":{\"message\":\"bad key\"}}"));
    try std.testing.expectError(error.MalformedListing, parse(alloc, "not json"));
}

test "merging keeps declared order and adds what the listing reports" {
    const alloc = std.testing.allocator;
    var registry = try definitions.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:1234/v1","auth":{"type":"none"},"model_metadata":{"chosen":{"context_window":8192,"supports_tool_use":true}}}}
    );
    defer registry.deinit(alloc);
    var listing = try parse(alloc,
        \\{"data":[{"id":"newcomer","name":"Newcomer","context_length":4096},{"id":"chosen","name":"Chosen Model"}]}
    );
    defer listing.deinit();
    var entries: std.ArrayList(catalog.ModelCatalogEntry) = .empty;
    defer catalog.freeModelCatalog(alloc, &entries);
    try mergeInto(alloc, registry.get("local").?, listing, &entries);

    try std.testing.expectEqual(@as(usize, 2), entries.items.len);
    // Declared first, with its declared limit and the listing's name.
    try std.testing.expectEqualStrings("chosen", entries.items[0].id);
    try std.testing.expectEqualStrings("Chosen Model", entries.items[0].name.?);
    try std.testing.expectEqual(@as(u32, 8192), entries.items[0].context_window);
    try std.testing.expect(entries.items[0].has_tool_use);
    // Then the one only the listing knows.
    try std.testing.expectEqualStrings("newcomer", entries.items[1].id);
    try std.testing.expectEqual(@as(u32, 4096), entries.items[1].context_window);
}

test "a listing that cannot be read leaves the declared models alone" {
    const alloc = std.testing.allocator;
    var registry = try definitions.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:1234/v1","auth":{"type":"none"},"model_metadata":{"mine":{"context_window":8192}}}}
    );
    defer registry.deinit(alloc);
    var listing = try parse(alloc,
        \\{"data":[{"id":"mine","context_length":1}]}
    );
    defer listing.deinit();
    var entries: std.ArrayList(catalog.ModelCatalogEntry) = .empty;
    defer catalog.freeModelCatalog(alloc, &entries);
    try mergeInto(alloc, registry.get("local").?, listing, &entries);
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expectEqual(@as(u32, 8192), entries.items[0].context_window);
}

test "a provider with no listing endpoint reports its declared models" {
    const alloc = std.testing.allocator;
    var registry = try definitions.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:1234/v1","auth":{"type":"none"},"model_listing":"none","model_metadata":{"only":{"context_window":2048}}}}
    );
    defer registry.deinit(alloc);
    const definition = registry.get("local").?;
    try std.testing.expectEqual(definitions.ModelListing.none, definition.model_listing);
    var entries: std.ArrayList(catalog.ModelCatalogEntry) = .empty;
    defer catalog.freeModelCatalog(alloc, &entries);
    try mergeInto(alloc, definition, .{ .entries = &.{}, .alloc = alloc }, &entries);
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expectEqualStrings("only", entries.items[0].id);
}
