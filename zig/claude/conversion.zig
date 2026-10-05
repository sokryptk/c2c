const std = @import("std");
const common = @import("../common.zig");
const A = common.Allocator;
const V = common.Value;
const str = common.str;
const obj = common.obj;
const arr = common.arr;
const get = common.get;
const s = common.s;
const eq = common.eq;
const list = common.list;
const Values = std.array_list.Managed(V);
const nullv: V = .null;
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
    if (eq(provider, "codex")) return "Codex";
    if (eq(provider, "claude")) return "Claude Code";
    if (eq(provider, "opencode")) return "OpenCode";
    if (eq(provider, "omp") or eq(provider, "oh-my-pi")) return "Oh My Pi";
    return provider;
}

pub fn convert(a: A, thread: common.Thread, items: []const common.Item, compaction: ?common.Compaction, opts: common.ConvertOptions) !common.Conversion {
    const source_provider = opts.source_provider orelse "codex";
    const source_id = opts.source_session_id orelse thread.id;
    const source_label = providerLabel(source_provider);
    var encoder = Encoder{ .a = a, .thread = thread, .opts = opts, .sid = try common.sessionIdFor(a, "claude", source_provider, source_id), .source_provider = source_provider, .source_id = source_id, .source_label = source_label, .entries = Values.init(a), .warnings = common.Warnings.init(a) };
    if (compaction) |compact| if (compact.encrypted) {
        try encoder.warnings.append("Encrypted Codex compaction is unavailable; visible transcript preserved");
    };
    var inserted = false;
    for (items) |item| {
        if (compaction) |compact| if (compact.summary.len > 0 and item.ordinal > compact.ordinal and !inserted) {
            try encoder.sourceBoundary(compact);
            inserted = true;
        };
        try encoder.emit(item);
    }
    if (compaction) |compact| if (compact.summary.len > 0 and !inserted) {
        try encoder.sourceBoundary(compact);
    };
    return finishEncoder(&encoder, items.len, compaction);
}
fn finishEncoder(encoder: *Encoder, source_count: usize, compaction: ?common.Compaction) !common.Conversion {
    const a = encoder.a;
    const thread = encoder.thread;
    try encoder.flushRaw();
    if (encoder.message_count == 0) return .{ .entries = &.{}, .warnings = try encoder.warnings.toOwnedSlice(), .session_id = encoder.sid, .source_item_count = source_count };
    try addCheckpoint(encoder, compaction);
    const trimmed = std.mem.trim(u8, thread.title, " \t\r\n");
    const title = if (trimmed.len > 0) trimmed else try common.fmt(a, "{s} {s}", .{ encoder.source_label, encoder.source_id[0..@min(8, encoder.source_id.len)] });
    try encoder.entries.append(try obj(a, &.{
        .{ "type", str("c2c-import") },                .{ "schemaVersion", common.num(1) },                                         .{ "source", str(encoder.source_provider) },
        .{ "sourceThreadId", str(encoder.source_id) }, .{ "lastMessageUuid", if (encoder.parent) |parent| str(parent) else nullv }, .{ "sessionId", str(encoder.sid) },
    }));
    try encoder.entries.append(try obj(a, &.{ .{ "type", str("custom-title") }, .{ "customTitle", str(try common.fmt(a, "{s} · {s}", .{ encoder.source_label, title })) }, .{ "sessionId", str(encoder.sid) } }));
    const errors = try validate(a, encoder.entries.items);
    if (errors.len > 0) return error.InvalidConvertedClaudeSession;
    return .{ .entries = try encoder.entries.toOwnedSlice(), .warnings = try encoder.warnings.toOwnedSlice(), .message_count = encoder.message_count, .tool_count = encoder.tool_count, .source_item_count = source_count, .session_id = encoder.sid };
}

fn closePending(encoder: *Encoder, pending: *std.StringHashMap([]const u8), timestamp: []const u8) !void {
    if (pending.count() == 0) return;
    var ids = std.array_list.Managed([]const u8).init(encoder.a);
    var iterator = pending.valueIterator();
    while (iterator.next()) |id| try ids.append(id.*);
    // Sort for deterministic on-disk order.
    std.mem.sort([]const u8, ids.items, {}, struct {
        fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.less);
    var blocks = Values.init(encoder.a);
    for (ids.items) |id| try blocks.append(try incompleteResult(encoder.a, id));
    try encoder.append("user", .{ .array = blocks }, timestamp, false);
    pending.clearRetainingCapacity();
    try encoder.warnings.append("Historical tool call had no saved result; imported as an explicitly closed historical exchange");
}

pub fn convertEntries(a: A, thread: common.Thread, entries: []const V, opts: common.ConvertOptions) !common.Conversion {
    const source_provider = opts.source_provider orelse thread.provider;
    const source_id = opts.source_session_id orelse thread.id;
    var encoder = Encoder{ .a = a, .thread = thread, .opts = opts, .sid = try common.sessionIdFor(a, "claude", source_provider, source_id), .source_provider = source_provider, .source_id = source_id, .source_label = providerLabel(source_provider), .entries = Values.init(a), .warnings = common.Warnings.init(a) };
    var pending = std.StringHashMap([]const u8).init(a);
    var deferred_images = Values.init(a);
    var latest_summary: ?common.Compaction = null;
    for (entries, 0..) |entry, ordinal| {
        const timestamp = if (s(entry, "timestamp").len > 0) s(entry, "timestamp") else thread.updated_at;
        if (eq(s(entry, "type"), "system") and eq(s(entry, "subtype"), "compact_boundary")) {
            try closePending(&encoder, &pending, timestamp);
            if (deferred_images.items.len > 0) {
                try encoder.append("user", try arr(a, deferred_images.items), timestamp, false);
                deferred_images.clearRetainingCapacity();
            }
            try encoder.boundary(timestamp);
            continue;
        }
        if (!isMessage(entry) or common.b(get(entry, "isMeta")) or s(entry, "teamName").len > 0) continue;
        const role = s(entry, "type");
        var content = try attachments.canonicalBlocks(a, get(get(entry, "message"), "content"), &encoder.warnings, encoder.opts.embed_images);
        if ((content == .string and content.string.len == 0) or (content == .array and content.array.items.len == 0)) continue;
        if (content != .string and content != .array) return error.InvalidCanonicalContent;
        if (pending.count() > 0 and !(eq(role, "user") and containsBlock(content, "tool_result"))) try closePending(&encoder, &pending, timestamp);
        if (!encoder.seen_user and !eq(role, "user")) try encoder.append("user", str(try common.fmt(a, "Continue this imported {s} conversation. The following entries are its saved history.", .{encoder.source_label})), thread.created_at, false);
        if (content == .array) {
            var kept = Values.init(a);
            for (content.array.items, 0..) |original, block_index| {
                var block = original;
                if (eq(s(block, "type"), "image") and eq(role, "assistant")) {
                    try deferred_images.append(block);
                    continue;
                }
                if (eq(s(block, "type"), "tool_use")) {
                    if (!eq(role, "assistant")) return error.InvalidCanonicalToolRole;
                    const old = s(block, "id");
                    if (old.len == 0 or pending.contains(old)) return error.InvalidCanonicalToolId;
                    const identifier = try encoder.id(try common.fmt(a, "canonical-tool:{d}:{d}:{s}", .{ ordinal, block_index, old }));
                    const fresh = try common.fmt(a, "toolu_c2c_{s}", .{try std.mem.replaceOwned(u8, a, identifier, "-", "")});
                    try common.set(a, &block, "id", str(fresh));
                    try pending.put(old, fresh);
                    encoder.tool_count += 1;
                } else if (eq(s(block, "type"), "tool_result")) {
                    if (!eq(role, "user")) return error.InvalidCanonicalToolRole;
                    const old = s(block, "tool_use_id");
                    if (pending.fetchRemove(old)) |mapping| {
                        try common.set(a, &block, "tool_use_id", str(mapping.value));
                    } else {
                        block = try textBlock(a, try common.fmt(a, "[Historical tool result without an available call]\n{s}", .{try common.json(a, block)}));
                        try encoder.warnings.append("Historical tool result had no available call; preserved its complete payload as text");
                    }
                }
                try kept.append(block);
            }
            // If only some results were saved, close the remaining calls in
            // this same user turn so native resumption never sees pending work.
            if (eq(role, "user") and pending.count() > 0) {
                var ids = std.array_list.Managed([]const u8).init(a);
                var iterator = pending.valueIterator();
                while (iterator.next()) |id| try ids.append(id.*);
                std.mem.sort([]const u8, ids.items, {}, struct {
                    fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
                        return std.mem.order(u8, lhs, rhs) == .lt;
                    }
                }.less);
                for (ids.items) |id| try kept.append(try incompleteResult(a, id));
                pending.clearRetainingCapacity();
                try encoder.warnings.append("Historical tool call had no saved result; imported as an explicitly closed historical exchange");
            }
            content = .{ .array = kept };
        }
        const summary = common.b(get(entry, "isCompactSummary"));
        if (summary) {
            var texts = std.array_list.Managed([]const u8).init(a);
            if (content == .string) try texts.append(content.string) else for (list(content)) |block| {
                if (eq(s(block, "type"), "text")) try texts.append(s(block, "text"));
            }
            latest_summary = .{ .summary = try std.mem.join(a, "\n", texts.items), .timestamp = timestamp };
        }
        if (content != .array or content.array.items.len > 0) try encoder.append(role, content, timestamp, summary);
        if (pending.count() == 0 and deferred_images.items.len > 0) {
            try encoder.append("user", try arr(a, deferred_images.items), timestamp, false);
            deferred_images.clearRetainingCapacity();
        }
    }
    try closePending(&encoder, &pending, thread.updated_at);
    if (deferred_images.items.len > 0) try encoder.append("user", try arr(a, deferred_images.items), thread.updated_at, false);
    return finishEncoder(&encoder, entries.len, latest_summary);
}
