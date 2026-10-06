const std = @import("std");
const common = @import("../common.zig");
const Allocator = common.Allocator;
const Value = common.Value;
const jsonString = common.str;
const jsonObject = common.obj;
const jsonArray = common.arr;
const field = common.get;
const stringField = common.stringField;
const equal = common.eq;
const elements = common.list;
const ValueList = std.array_list.Managed(Value);
const nullv: Value = .null;
const native = @import("native.zig");
const isMessage = native.isMessage;
const containsBlock = native.containsBlock;
const textBlock = native.textBlock;
const incompleteResult = native.incompleteResult;
const validate = native.validate;
const Encoder = @import("encoder.zig").Encoder;
const addCheckpoint = @import("checkpoints.zig").addCheckpoint;
const attachments = @import("attachments.zig");

fn providerLabel(provider: []const u8) []const u8 {
    if (equal(provider, "codex")) {
        return "Codex";
    }
    if (equal(provider, "claude")) {
        return "Claude Code";
    }
    if (equal(provider, "opencode")) {
        return "OpenCode";
    }
    if (equal(provider, "omp") or equal(provider, "oh-my-pi")) {
        return "Oh My Pi";
    }
    return provider;
}

pub fn convert(
    allocator: Allocator,
    thread: common.Thread,
    items: []const common.Item,
    compaction: ?common.Compaction,
    opts: common.ConvertOptions,
) !common.Conversion {
    const source_provider = opts.source_provider orelse "codex";
    const source_id = opts.source_session_id orelse thread.id;
    const source_label = providerLabel(source_provider);
    var encoder = Encoder{
        .allocator = allocator,
        .thread = thread,
        .opts = opts,
        .sid = try common.sessionIdFor(allocator, "claude", source_provider, source_id),
        .source_provider = source_provider,
        .source_id = source_id,
        .source_label = source_label,
        .entries = ValueList.init(allocator),
        .warnings = common.Warnings.init(allocator),
    };
    if (compaction) |compact| {
        if (compact.encrypted) {
            try encoder.warnings.append("Encrypted Codex compaction is unavailable; visible transcript preserved");
        }
    }
    var inserted = false;
    for (items) |item| {
        if (compaction) |compact| {
            if (compact.summary.len > 0 and item.ordinal > compact.ordinal and !inserted) {
                try encoder.sourceBoundary(compact);
                inserted = true;
            }
        }
        try encoder.emit(item);
    }
    if (compaction) |compact| {
        if (compact.summary.len > 0 and !inserted) {
            try encoder.sourceBoundary(compact);
        }
    }
    return finishEncoder(&encoder, items.len, compaction);
}

fn finishEncoder(encoder: *Encoder, source_count: usize, compaction: ?common.Compaction) !common.Conversion {
    const allocator = encoder.allocator;
    const thread = encoder.thread;
    try encoder.flushRaw();
    if (encoder.message_count == 0) {
        return .{
            .entries = &.{},
            .warnings = try encoder.warnings.toOwnedSlice(),
            .session_id = encoder.sid,
            .source_item_count = source_count,
        };
    }
    try addCheckpoint(encoder, compaction);
    const trimmed = std.mem.trim(u8, thread.title, " \t\r\n");
    const title = if (trimmed.len > 0)
        trimmed
    else
        try common.fmt(allocator, "{s} {s}", .{
            encoder.source_label,
            encoder.source_id[0..@min(8, encoder.source_id.len)],
        });
    const provenance = try jsonObject(allocator, &.{
        .{ "type", jsonString("c2c-import") },
        .{ "schemaVersion", common.num(1) },
        .{ "source", jsonString(encoder.source_provider) },
        .{ "sourceThreadId", jsonString(encoder.source_id) },
        .{ "lastMessageUuid", if (encoder.parent) |parent| jsonString(parent) else nullv },
        .{ "sessionId", jsonString(encoder.sid) },
    });
    try encoder.entries.append(provenance);
    const custom_title = try common.fmt(allocator, "{s} · {s}", .{ encoder.source_label, title });
    const title_entry = try jsonObject(allocator, &.{
        .{ "type", jsonString("custom-title") },
        .{ "customTitle", jsonString(custom_title) },
        .{ "sessionId", jsonString(encoder.sid) },
    });
    try encoder.entries.append(title_entry);
    const errors = try validate(allocator, encoder.entries.items);
    if (errors.len > 0) {
        return error.InvalidConvertedClaudeSession;
    }
    return .{
        .entries = try encoder.entries.toOwnedSlice(),
        .warnings = try encoder.warnings.toOwnedSlice(),
        .message_count = encoder.message_count,
        .tool_count = encoder.tool_count,
        .source_item_count = source_count,
        .session_id = encoder.sid,
    };
}

fn closePending(encoder: *Encoder, pending: *std.StringHashMap([]const u8), timestamp: []const u8) !void {
    if (pending.count() == 0) {
        return;
    }
    var ids = std.array_list.Managed([]const u8).init(encoder.allocator);
    var iterator = pending.valueIterator();
    while (iterator.next()) |id| {
        try ids.append(id.*);
    }
    // Sort for deterministic on-disk order.
    std.mem.sort([]const u8, ids.items, {}, struct {
        fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.less);
    var blocks = ValueList.init(encoder.allocator);
    for (ids.items) |id| {
        const result = try incompleteResult(encoder.allocator, id);
        try blocks.append(result);
    }
    try encoder.append("user", .{ .array = blocks }, timestamp, false);
    pending.clearRetainingCapacity();
    try encoder.warnings.append(
        "Historical tool call had no saved result; " ++
            "imported as an explicitly closed historical exchange",
    );
}

pub fn convertEntries(
    allocator: Allocator,
    thread: common.Thread,
    entries: []const Value,
    opts: common.ConvertOptions,
) !common.Conversion {
    const source_provider = opts.source_provider orelse thread.provider;
    const source_id = opts.source_session_id orelse thread.id;
    var encoder = Encoder{
        .allocator = allocator,
        .thread = thread,
        .opts = opts,
        .sid = try common.sessionIdFor(allocator, "claude", source_provider, source_id),
        .source_provider = source_provider,
        .source_id = source_id,
        .source_label = providerLabel(source_provider),
        .entries = ValueList.init(allocator),
        .warnings = common.Warnings.init(allocator),
    };
    var pending = std.StringHashMap([]const u8).init(allocator);
    var deferred_images = ValueList.init(allocator);
    var latest_summary: ?common.Compaction = null;
    for (entries, 0..) |entry, ordinal| {
        const saved_timestamp = stringField(entry, "timestamp");
        const timestamp = if (saved_timestamp.len > 0) saved_timestamp else thread.updated_at;
        const role = stringField(entry, "type");
        if (equal(role, "system") and equal(stringField(entry, "subtype"), "compact_boundary")) {
            try closePending(&encoder, &pending, timestamp);
            if (deferred_images.items.len > 0) {
                try encoder.append("user", try jsonArray(allocator, deferred_images.items), timestamp, false);
                deferred_images.clearRetainingCapacity();
            }
            try encoder.boundary(timestamp);
            continue;
        }
        if (!isMessage(entry) or common.boolValue(field(entry, "isMeta")) or stringField(entry, "teamName").len > 0) {
            continue;
        }
        const original_content = field(field(entry, "message"), "content");
        var content = try attachments.canonicalBlocks(
            allocator,
            original_content,
            &encoder.warnings,
            encoder.opts.embed_images,
        );
        if ((content == .string and content.string.len == 0) or
            (content == .array and content.array.items.len == 0))
        {
            continue;
        }
        if (content != .string and content != .array) {
            return error.InvalidCanonicalContent;
        }
        if (pending.count() > 0 and !(equal(role, "user") and containsBlock(content, "tool_result"))) {
            try closePending(&encoder, &pending, timestamp);
        }
        if (!encoder.seen_user and !equal(role, "user")) {
            const introduction = try common.fmt(
                allocator,
                "Continue this imported {s} conversation. The following entries are its saved history.",
                .{encoder.source_label},
            );
            try encoder.append("user", jsonString(introduction), thread.created_at, false);
        }
        if (content == .array) {
            var kept = ValueList.init(allocator);
            for (content.array.items, 0..) |original, block_index| {
                var block = original;
                const block_type = stringField(block, "type");
                if (equal(block_type, "image") and equal(role, "assistant")) {
                    try deferred_images.append(block);
                    continue;
                }
                if (equal(block_type, "tool_use")) {
                    if (!equal(role, "assistant")) {
                        return error.InvalidCanonicalToolRole;
                    }
                    const old = stringField(block, "id");
                    if (old.len == 0 or pending.contains(old)) {
                        return error.InvalidCanonicalToolId;
                    }
                    const purpose = try common.fmt(allocator, "canonical-tool:{d}:{d}:{s}", .{ ordinal, block_index, old });
                    const identifier = try encoder.id(purpose);
                    const compact_id = try std.mem.replaceOwned(u8, allocator, identifier, "-", "");
                    const fresh = try common.fmt(allocator, "toolu_c2c_{s}", .{compact_id});
                    try common.set(allocator, &block, "id", jsonString(fresh));
                    try pending.put(old, fresh);
                    encoder.tool_count += 1;
                } else if (equal(block_type, "tool_result")) {
                    if (!equal(role, "user")) {
                        return error.InvalidCanonicalToolRole;
                    }
                    const old = stringField(block, "tool_use_id");
                    if (pending.fetchRemove(old)) |mapping| {
                        try common.set(allocator, &block, "tool_use_id", jsonString(mapping.value));
                    } else {
                        const payload = try common.json(allocator, block);
                        const notice = try common.fmt(
                            allocator,
                            "[Historical tool result without an available call]\n{s}",
                            .{payload},
                        );
                        block = try textBlock(allocator, notice);
                        try encoder.warnings.append("Historical tool result had no available call; preserved its complete payload as text");
                    }
                }
                try kept.append(block);
            }
            // If only some results were saved, close the remaining calls in
            // this same user turn so native resumption never sees pending work.
            if (equal(role, "user") and pending.count() > 0) {
                var ids = std.array_list.Managed([]const u8).init(allocator);
                var iterator = pending.valueIterator();
                while (iterator.next()) |id| {
                    try ids.append(id.*);
                }
                std.mem.sort([]const u8, ids.items, {}, struct {
                    fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
                        return std.mem.order(u8, lhs, rhs) == .lt;
                    }
                }.less);
                for (ids.items) |id| {
                    const result = try incompleteResult(allocator, id);
                    try kept.append(result);
                }
                pending.clearRetainingCapacity();
                try encoder.warnings.append(
                    "Historical tool call had no saved result; " ++
                        "imported as an explicitly closed historical exchange",
                );
            }
            content = .{ .array = kept };
        }
        const summary = common.boolValue(field(entry, "isCompactSummary"));
        if (summary) {
            var texts = std.array_list.Managed([]const u8).init(allocator);
            if (content == .string) {
                try texts.append(content.string);
            } else {
                for (elements(content)) |block| {
                    if (equal(stringField(block, "type"), "text")) {
                        try texts.append(stringField(block, "text"));
                    }
                }
            }
            latest_summary = .{ .summary = try std.mem.join(allocator, "\n", texts.items), .timestamp = timestamp };
        }
        if (content != .array or content.array.items.len > 0) {
            try encoder.append(role, content, timestamp, summary);
        }
        if (pending.count() == 0 and deferred_images.items.len > 0) {
            try encoder.append("user", try jsonArray(allocator, deferred_images.items), timestamp, false);
            deferred_images.clearRetainingCapacity();
        }
    }
    try closePending(&encoder, &pending, thread.updated_at);
    if (deferred_images.items.len > 0) {
        try encoder.append("user", try jsonArray(allocator, deferred_images.items), thread.updated_at, false);
    }
    return finishEncoder(&encoder, entries.len, latest_summary);
}
