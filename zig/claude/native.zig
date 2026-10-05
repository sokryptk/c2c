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

pub const namespace = "6ee9e2ac-f1e7-4ed0-9ecb-ced168929080";
pub const version = "2.1.289";

pub fn isMessage(entry: V) bool {
    return (eq(s(entry, "type"), "user") or eq(s(entry, "type"), "assistant")) and get(entry, "message") == .object;
}
pub fn containsBlock(content: V, kind: []const u8) bool {
    for (list(content)) |block| if (eq(s(block, "type"), kind)) return true;
    return false;
}
pub fn textBlock(a: A, text: []const u8) !V {
    return obj(a, &.{ .{ "type", str("text") }, .{ "text", str(text) } });
}
pub fn sessionId(a: A, thread_id: []const u8) ![]const u8 {
    return common.uuid5(a, namespace, try common.fmt(a, "session:{s}", .{thread_id}));
}
pub fn utf8Prefix(text: []const u8, limit: usize) []const u8 {
    var end = @min(text.len, limit);
    while (end > 0 and end < text.len and text[end] & 0xc0 == 0x80) end -= 1;
    return text[0..end];
}
pub fn nativeMessage(a: A, role: []const u8, content: V, identifier: []const u8) !V {
    var message = try obj(a, &.{ .{ "role", str(role) }, .{ "content", content } });
    if (eq(role, "assistant")) {
        const compact_id = try std.mem.replaceOwned(u8, a, identifier, "-", "");
        try common.set(a, &message, "id", str(try common.fmt(a, "msg_{s}", .{compact_id})));
        try common.set(a, &message, "type", str("message"));
        try common.set(a, &message, "model", str("<synthetic>"));
        try common.set(a, &message, "stop_reason", str(if (containsBlock(content, "tool_use")) "tool_use" else "end_turn"));
        try common.set(a, &message, "stop_sequence", .null);
        try common.set(a, &message, "usage", try obj(a, &.{ .{ "input_tokens", common.num(0) }, .{ "output_tokens", common.num(0) } }));
    }
    return message;
}
pub fn messageCost(a: A, role: []const u8, content: V) !usize {
    // Include append()'s envelope; its bytes dominate short image excerpts.
    return (try common.json(a, try nativeMessage(a, role, content, "00000000-0000-0000-0000-000000000000"))).len;
}
pub fn incompleteResult(a: A, id: []const u8) !V {
    return obj(a, &.{ .{ "type", str("tool_result") }, .{ "tool_use_id", str(id) }, .{ "content", str("[Historical tool had no saved result in the source conversation; it was not run by this import.]") }, .{ "is_error", common.boolean(true) } });
}

pub fn validate(a: A, entries: []const V) ![][]const u8 {
    var errors = common.Warnings.init(a);
    var seen = std.StringHashMap(void).init(a);
    var session_ids = std.StringHashMap(void).init(a);
    var pending = std.StringHashMap(void).init(a);
    var all_tools = std.StringHashMap(void).init(a);
    var user_seen = false;
    var messages: usize = 0;
    for (entries, 0..) |entry, index| {
        const kind = s(entry, "type");
        if (s(entry, "sessionId").len > 0) try session_ids.put(s(entry, "sessionId"), {});
        const identifier = s(entry, "uuid");
        if (identifier.len > 0) {
            if (seen.contains(identifier)) try errors.append(try common.fmt(a, "entry {d}: duplicate uuid", .{index}));
            const parent = s(entry, "parentUuid");
            if (parent.len > 0 and !seen.contains(parent)) try errors.append(try common.fmt(a, "entry {d}: missing parent", .{index}));
            const logical_parent = s(entry, "logicalParentUuid");
            if (logical_parent.len > 0 and !seen.contains(logical_parent)) try errors.append(try common.fmt(a, "entry {d}: missing logical parent", .{index}));
            try seen.put(identifier, {});
        }
        if (eq(kind, "system") and eq(s(entry, "subtype"), "compact_boundary")) {
            if (pending.count() > 0) try errors.append(try common.fmt(a, "entry {d}: pending tool across compaction", .{index}));
            if (get(entry, "parentUuid") != .null) try errors.append(try common.fmt(a, "entry {d}: compaction must start a new active chain", .{index}));
            continue;
        }
        if (!eq(kind, "user") and !eq(kind, "assistant")) {
            if (get(entry, "message") != .null) try errors.append(try common.fmt(a, "entry {d}: invalid message role", .{index}));
            continue;
        }
        messages += 1;
        if (eq(kind, "user")) user_seen = true;
        if (identifier.len == 0) try errors.append(try common.fmt(a, "entry {d}: missing uuid", .{index}));
        if (!eq(s(get(entry, "message"), "role"), kind)) try errors.append(try common.fmt(a, "entry {d}: role mismatch", .{index}));
        const sidechain = get(entry, "isSidechain");
        if (sidechain != .bool or sidechain.bool or !eq(s(entry, "entrypoint"), "cli")) try errors.append(try common.fmt(a, "entry {d}: not a normal CLI session", .{index}));
        const content = get(get(entry, "message"), "content");
        if (pending.count() > 0) {
            var returns = std.StringHashMap(void).init(a);
            for (list(content)) |block| if (eq(s(block, "type"), "tool_result")) {
                try returns.put(s(block, "tool_use_id"), {});
            };
            var complete = eq(kind, "user");
            var iter = pending.keyIterator();
            while (iter.next()) |tool_id| if (!returns.contains(tool_id.*)) {
                complete = false;
            };
            if (!complete) try errors.append(try common.fmt(a, "entry {d}: tool results must immediately follow their calls", .{index}));
        }
        if (content == .string) {
            if (content.string.len == 0) try errors.append(try common.fmt(a, "entry {d}: empty message", .{index}));
            continue;
        }
        if (content != .array or list(content).len == 0) try errors.append(try common.fmt(a, "entry {d}: empty or invalid message", .{index}));
        for (list(content)) |block| {
            if (block != .object) {
                try errors.append(try common.fmt(a, "entry {d}: invalid content block", .{index}));
                continue;
            }
            if (eq(s(block, "type"), "tool_use")) {
                const tool_id = s(block, "id");
                if (all_tools.contains(tool_id) or tool_id.len == 0) try errors.append(try common.fmt(a, "entry {d}: duplicate/empty tool ID", .{index}));
                if (!eq(kind, "assistant")) try errors.append(try common.fmt(a, "entry {d}: tool call must be assistant content", .{index}));
                try pending.put(tool_id, {});
                try all_tools.put(tool_id, {});
            } else if (eq(s(block, "type"), "tool_result")) {
                const tool_id = s(block, "tool_use_id");
                if (!pending.remove(tool_id)) try errors.append(try common.fmt(a, "entry {d}: orphan tool result", .{index}));
                if (!eq(kind, "user")) try errors.append(try common.fmt(a, "entry {d}: tool result must be user content", .{index}));
            }
        }
    }
    if (pending.count() > 0) try errors.append("session ends with unresolved tool calls");
    if (session_ids.count() != 1) try errors.append("session ID missing or inconsistent");
    if (messages == 0) try errors.append("session has no conversation messages");
    if (messages > 0 and !user_seen) try errors.append("session has no user message for discovery");
    return errors.toOwnedSlice();
}
