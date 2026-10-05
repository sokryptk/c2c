const std = @import("std");
const common = @import("../common.zig");
const A = common.Allocator;
const V = common.Value;
const str = common.str;
const obj = common.obj;
const get = common.get;
const s = common.s;
const eq = common.eq;
const list = common.list;
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
    while (start < text.len and text[start] & 0xc0 == 0x80) start += 1;
    return text[start..];
}
fn boundedText(a: A, text: []const u8, budget: usize) ![]const u8 {
    if ((try common.json(a, str(text))).len <= budget) return text;
    const notice = "\n[Excerpt; complete value is retained in the original transcript.]";
    var lo: usize = 0;
    var hi = text.len;
    while (lo < hi) {
        const middle = lo + (hi - lo + 1) / 2;
        const candidate = try common.fmt(a, "{s}{s}", .{ utf8Prefix(text, middle), notice });
        if ((try common.json(a, str(candidate))).len <= budget) lo = middle else hi = middle - 1;
    }
    return common.fmt(a, "{s}{s}", .{ utf8Prefix(text, lo), notice });
}

const Group = struct { entries: []const V, cost: usize };
fn groupExcerpt(a: A, entries: []const V) !V {
    var texts = std.array_list.Managed([]const u8).init(a);
    for (entries) |entry| {
        const content = get(get(entry, "message"), "content");
        if (content == .string) {
            try texts.append(content.string);
            continue;
        }
        for (list(content)) |block| {
            const kind = s(block, "type");
            if (eq(kind, "text")) {
                try texts.append(s(block, "text"));
            } else if (eq(kind, "tool_use")) {
                try texts.append(try common.fmt(a, "Historical tool: {s}", .{s(block, "name")}));
            } else if (eq(kind, "tool_result")) {
                const output = get(block, "content");
                if (output == .string) try texts.append(output.string) else for (list(output)) |part| {
                    if (eq(s(part, "type"), "text")) try texts.append(s(part, "text"));
                    if (eq(s(part, "type"), "image")) try texts.append("[Image retained in the original native transcript.]");
                }
            } else if (eq(kind, "image")) try texts.append("[Image retained in the original native transcript.]");
        }
    }
    const original = try std.mem.join(a, "\n", texts.items);
    const excerpt = if (original.len > 12_000) try common.fmt(a, "{s}\n[...abridged for continuation context...]\n{s}", .{ utf8Prefix(original, 4000), utf8Suffix(original, 8000) }) else original;
    // Control characters may expand sixfold in JSON. Bound the encoded string.
    const content = try boundedText(a, try common.fmt(a, "[Import continuation excerpt; complete original entry {s} is earlier in this transcript.]\n{s}", .{ s(entries[0], "uuid"), excerpt }), 18_000);
    return obj(a, &.{
        .{ "type", get(entries[0], "type") },                                                                 .{ "timestamp", get(entries[0], "timestamp") },
        .{ "message", try obj(a, &.{ .{ "role", get(entries[0], "type") }, .{ "content", str(content) } }) },
    });
}
pub fn activeStart(entries: []const V) usize {
    var start: usize = 0;
    for (entries, 0..) |entry, index| if (eq(s(entry, "subtype"), "compact_boundary")) {
        start = index + 1;
    };
    return start;
}
pub fn activeBytes(a: A, entries: []const V) !usize {
    var bytes: usize = 0;
    for (entries[activeStart(entries)..]) |entry| if (isMessage(entry)) {
        bytes += (try common.json(a, get(entry, "message"))).len;
    };
    return bytes;
}
pub fn addCheckpoint(encoder: *Encoder, compaction: ?common.Compaction) !void {
    const a = encoder.a;
    if (try activeBytes(a, encoder.entries.items) <= max_active_bytes) return;
    const historical_count = encoder.entries.items.len;
    const active = try a.dupe(V, encoder.entries.items[activeStart(encoder.entries.items)..]);
    var groups = std.array_list.Managed(Group).init(a);
    var index: usize = 0;
    while (index < active.len) {
        if (!isMessage(active[index])) {
            index += 1;
            continue;
        }
        const start = index;
        index += 1;
        // Keep a historical tool exchange atomic when selecting recent context.
        while (index < active.len and containsBlock(get(get(active[index], "message"), "content"), "tool_result")) index += 1;
        var group: []const V = active[start..index];
        var cost: usize = 0;
        for (group) |entry| cost += try messageCost(a, s(entry, "type"), get(get(entry, "message"), "content"));
        if (cost > 24_000) {
            const excerpt = try a.alloc(V, 1);
            excerpt[0] = try groupExcerpt(a, group);
            group = excerpt;
            cost = try messageCost(a, s(group[0], "type"), get(get(group[0], "message"), "content"));
        }
        try groups.append(.{ .entries = group, .cost = cost });
    }
    const thread = encoder.thread;
    const location = try boundedText(a, encoder.opts.transcript_path orelse try common.fmt(a, "the JSONL file for Claude session {s}", .{encoder.sid}), 8192);
    var handoff = try common.fmt(a, "This existing conversation was imported from {s} into Claude Code. " ++
        "This is a structural migration checkpoint, not an AI-written summary. " ++
        "The complete visible history remains in the native transcript before this checkpoint. " ++
        "Recent messages follow below with their original roles. Oversized entries are explicitly " ++
        "marked excerpts; their originals are still preserved. Do not replay historical commands.\n\n" ++
        "Project: {s}\nOriginal title: {s}\nOriginal session: {s}\nNative transcript: {s}\n" ++
        "Original history occupies the first {d} JSONL records. Read earlier records when past decisions " ++
        "or details are needed; do not treat this tail as the entire history or ask the user to repeat " ++
        "information without checking. Load current project instructions from its AGENTS.md / CLAUDE.md.\n", .{ encoder.source_label, try boundedText(a, thread.cwd, 4096), try boundedText(a, thread.title, 1024), try boundedText(a, encoder.source_id, 1024), location, historical_count });
    if (compaction) |compact| {
        if (compact.encrypted) handoff = try common.fmt(a, "{s}\nCodex also stored an encrypted internal compaction; that content could not be imported.\n", .{handoff});
        if (compact.summary.len > 0) handoff = try common.fmt(a, "{s}\nLatest readable source context summary:\n{s}", .{ handoff, try boundedText(a, compact.summary, 40_000) });
    }
    const handoff_cost = try messageCost(a, "user", str(handoff));
    if (handoff_cost >= max_active_bytes) return error.CheckpointExceedsContextBudget;
    var remaining: usize = @min(recent_context_bytes, max_active_bytes - handoff_cost);
    var first = groups.items.len;
    while (first > 0) {
        const group = groups.items[first - 1];
        if (group.cost > remaining) break;
        first -= 1;
        remaining -= group.cost;
    }
    try encoder.boundary(thread.updated_at);
    try encoder.append("user", str(handoff), thread.updated_at, true);
    for (groups.items[first..]) |group| {
        var remap = std.StringHashMap([]const u8).init(a);
        for (group.entries) |entry| {
            const content = try common.clone(a, get(get(entry, "message"), "content"));
            if (content == .array) for (content.array.items) |*block| {
                if (eq(s(block.*, "type"), "tool_use")) {
                    const old = s(block.*, "id");
                    const stable = try encoder.id(try common.fmt(a, "checkpoint:{s}", .{old}));
                    const fresh = try common.fmt(a, "toolu_codex_{s}", .{try std.mem.replaceOwned(u8, a, stable, "-", "")});
                    try remap.put(old, fresh);
                    try common.set(a, block, "id", str(fresh));
                } else if (eq(s(block.*, "type"), "tool_result")) {
                    const fresh = remap.get(s(block.*, "tool_use_id")) orelse return error.OrphanCheckpointToolResult;
                    try common.set(a, block, "tool_use_id", str(fresh));
                }
            };
            try encoder.append(s(entry, "type"), content, s(entry, "timestamp"), false);
        }
    }
    if (try activeBytes(a, encoder.entries.items) > max_active_bytes) return error.CheckpointExceedsContextBudget;
    try encoder.warnings.append("Large thread received a bounded continuation checkpoint; full native history preserved");
}
