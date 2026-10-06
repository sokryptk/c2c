const std = @import("std");
const common = @import("../common.zig");
const Allocator = common.Allocator;
const Value = common.Value;
const jsonString = common.str;
const jsonObject = common.obj;
const field = common.get;
const stringField = common.stringField;
const equal = common.eq;
const elements = common.list;
const native = @import("native.zig");
const isMessage = native.isMessage;
const containsBlock = native.containsBlock;
const utf8Prefix = native.utf8Prefix;
const messageCost = native.messageCost;
const Encoder = @import("encoder.zig").Encoder;

pub const max_active_bytes: usize = 240_000;
const recent_context_bytes: usize = 170_000;

fn utf8Suffix(text: []const u8, limit: usize) []const u8 {
    var start = text.len - @min(text.len, limit);
    while (start < text.len and text[start] & 0xc0 == 0x80) {
        start += 1;
    }
    return text[start..];
}

fn boundedText(allocator: Allocator, text: []const u8, budget: usize) ![]const u8 {
    const encoded = try common.json(allocator, jsonString(text));
    if (encoded.len <= budget) {
        return text;
    }
    const notice = "\n[Excerpt; complete value is retained in the original transcript.]";
    var lo: usize = 0;
    var hi = text.len;
    while (lo < hi) {
        const middle = lo + (hi - lo + 1) / 2;
        const candidate = try common.fmt(allocator, "{s}{s}", .{ utf8Prefix(text, middle), notice });
        const encoded_candidate = try common.json(allocator, jsonString(candidate));
        if (encoded_candidate.len <= budget) {
            lo = middle;
        } else {
            hi = middle - 1;
        }
    }
    return common.fmt(allocator, "{s}{s}", .{ utf8Prefix(text, lo), notice });
}

const Group = struct {
    entries: []const Value,
    cost: usize,
};

fn groupExcerpt(allocator: Allocator, entries: []const Value) !Value {
    var texts = std.array_list.Managed([]const u8).init(allocator);
    for (entries) |entry| {
        const content = field(field(entry, "message"), "content");
        if (content == .string) {
            try texts.append(content.string);
            continue;
        }
        for (elements(content)) |block| {
            const kind = stringField(block, "type");
            if (equal(kind, "text")) {
                try texts.append(stringField(block, "text"));
            } else if (equal(kind, "tool_use")) {
                const tool_description = try common.fmt(allocator, "Historical tool: {s}", .{stringField(block, "name")});
                try texts.append(tool_description);
            } else if (equal(kind, "tool_result")) {
                const output = field(block, "content");
                if (output == .string) {
                    try texts.append(output.string);
                } else {
                    for (elements(output)) |part| {
                        if (equal(stringField(part, "type"), "text")) {
                            try texts.append(stringField(part, "text"));
                        }
                        if (equal(stringField(part, "type"), "image")) {
                            try texts.append("[Image retained in the original native transcript.]");
                        }
                    }
                }
            } else if (equal(kind, "image")) {
                try texts.append("[Image retained in the original native transcript.]");
            }
        }
    }
    const original = try std.mem.join(allocator, "\n", texts.items);
    const excerpt = if (original.len > 12_000)
        try common.fmt(allocator, "{s}\n[...abridged for continuation context...]\n{s}", .{
            utf8Prefix(original, 4000),
            utf8Suffix(original, 8000),
        })
    else
        original;
    // Control characters may expand sixfold in JSON. Bound the encoded string.
    const continuation = try common.fmt(
        allocator,
        "[Import continuation excerpt; complete original entry {s} is earlier in this transcript.]\n{s}",
        .{ stringField(entries[0], "uuid"), excerpt },
    );
    const content = try boundedText(allocator, continuation, 18_000);
    const message = try jsonObject(allocator, &.{
        .{ "role", field(entries[0], "type") },
        .{ "content", jsonString(content) },
    });
    return jsonObject(allocator, &.{
        .{ "type", field(entries[0], "type") },
        .{ "timestamp", field(entries[0], "timestamp") },
        .{ "message", message },
    });
}

pub fn activeStart(entries: []const Value) usize {
    var start: usize = 0;
    for (entries, 0..) |entry, index| {
        if (equal(stringField(entry, "subtype"), "compact_boundary")) {
            start = index + 1;
        }
    }
    return start;
}

pub fn activeBytes(allocator: Allocator, entries: []const Value) !usize {
    var bytes: usize = 0;
    for (entries[activeStart(entries)..]) |entry| {
        if (isMessage(entry)) {
            const encoded_message = try common.json(allocator, field(entry, "message"));
            bytes += encoded_message.len;
        }
    }
    return bytes;
}

pub fn addCheckpoint(encoder: *Encoder, compaction: ?common.Compaction) !void {
    const allocator = encoder.allocator;
    if (try activeBytes(allocator, encoder.entries.items) <= max_active_bytes) {
        return;
    }
    const historical_count = encoder.entries.items.len;
    const active = try allocator.dupe(Value, encoder.entries.items[activeStart(encoder.entries.items)..]);
    var groups = std.array_list.Managed(Group).init(allocator);
    var index: usize = 0;
    while (index < active.len) {
        if (!isMessage(active[index])) {
            index += 1;
            continue;
        }
        const start = index;
        index += 1;
        // Keep a historical tool exchange atomic when selecting recent context.
        while (index < active.len) {
            const content = field(field(active[index], "message"), "content");
            if (!containsBlock(content, "tool_result")) {
                break;
            }
            index += 1;
        }
        var group: []const Value = active[start..index];
        var cost: usize = 0;
        for (group) |entry| {
            const content = field(field(entry, "message"), "content");
            cost += try messageCost(allocator, stringField(entry, "type"), content);
        }
        if (cost > 24_000) {
            const excerpt = try allocator.alloc(Value, 1);
            excerpt[0] = try groupExcerpt(allocator, group);
            group = excerpt;
            const content = field(field(group[0], "message"), "content");
            cost = try messageCost(allocator, stringField(group[0], "type"), content);
        }
        try groups.append(.{
            .entries = group,
            .cost = cost,
        });
    }
    const thread = encoder.thread;
    const transcript = encoder.opts.transcript_path orelse
        try common.fmt(allocator, "the JSONL file for Claude session {s}", .{encoder.sid});
    const location = try boundedText(allocator, transcript, 8192);
    const project = try boundedText(allocator, thread.cwd, 4096);
    const title = try boundedText(allocator, thread.title, 1024);
    const source_id = try boundedText(allocator, encoder.source_id, 1024);
    var handoff = try common.fmt(
        allocator,
        "This existing conversation was imported from {s} into Claude Code. " ++
            "This is a structural migration checkpoint, not an AI-written summary. " ++
            "The complete visible history remains in the native transcript before this checkpoint. " ++
            "Recent messages follow below with their original roles. Oversized entries are explicitly " ++
            "marked excerpts; their originals are still preserved. Do not replay historical commands.\n\n" ++
            "Project: {s}\nOriginal title: {s}\nOriginal session: {s}\nNative transcript: {s}\n" ++
            "Original history occupies the first {d} JSONL records. Read earlier records when past decisions " ++
            "or details are needed; do not treat this tail as the entire history or ask the user to repeat " ++
            "information without checking. Load current project instructions from its AGENTS.md / CLAUDE.md.\n",
        .{ encoder.source_label, project, title, source_id, location, historical_count },
    );
    if (compaction) |compact| {
        if (compact.encrypted) {
            handoff = try common.fmt(
                allocator,
                "{s}\nCodex also stored an encrypted internal compaction; that content could not be imported.\n",
                .{handoff},
            );
        }
        if (compact.summary.len > 0) {
            const summary = try boundedText(allocator, compact.summary, 40_000);
            handoff = try common.fmt(allocator, "{s}\nLatest readable source context summary:\n{s}", .{
                handoff,
                summary,
            });
        }
    }
    const handoff_cost = try messageCost(allocator, "user", jsonString(handoff));
    if (handoff_cost >= max_active_bytes) {
        return error.CheckpointExceedsContextBudget;
    }
    var remaining: usize = @min(recent_context_bytes, max_active_bytes - handoff_cost);
    var first = groups.items.len;
    while (first > 0) {
        const group = groups.items[first - 1];
        if (group.cost > remaining) {
            break;
        }
        first -= 1;
        remaining -= group.cost;
    }
    try encoder.boundary(thread.updated_at);
    try encoder.append("user", jsonString(handoff), thread.updated_at, true);
    for (groups.items[first..]) |group| {
        var remap = std.StringHashMap([]const u8).init(allocator);
        for (group.entries) |entry| {
            const content = try common.clone(allocator, field(field(entry, "message"), "content"));
            if (content == .array) {
                for (content.array.items) |*block| {
                    if (equal(stringField(block.*, "type"), "tool_use")) {
                        const old = stringField(block.*, "id");
                        const checkpoint_id = try common.fmt(allocator, "checkpoint:{s}", .{old});
                        const stable = try encoder.id(checkpoint_id);
                        const normalized_id = try std.mem.replaceOwned(u8, allocator, stable, "-", "");
                        const fresh = try common.fmt(allocator, "toolu_codex_{s}", .{normalized_id});
                        try remap.put(old, fresh);
                        try common.set(allocator, block, "id", jsonString(fresh));
                    } else if (equal(stringField(block.*, "type"), "tool_result")) {
                        const fresh = remap.get(stringField(block.*, "tool_use_id")) orelse
                            return error.OrphanCheckpointToolResult;
                        try common.set(allocator, block, "tool_use_id", jsonString(fresh));
                    }
                }
            }
            try encoder.append(stringField(entry, "type"), content, stringField(entry, "timestamp"), false);
        }
    }
    if (try activeBytes(allocator, encoder.entries.items) > max_active_bytes) {
        return error.CheckpointExceedsContextBudget;
    }
    try encoder.warnings.append("Large thread received a bounded continuation checkpoint; full native history preserved");
}
