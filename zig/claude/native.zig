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

pub const namespace = "6ee9e2ac-f1e7-4ed0-9ecb-ced168929080";
pub const version = "2.1.289";

pub fn isMessage(entry: Value) bool {
    const entry_type = stringField(entry, "type");
    return (equal(entry_type, "user") or equal(entry_type, "assistant")) and
        field(entry, "message") == .object;
}

pub fn containsBlock(content: Value, kind: []const u8) bool {
    for (elements(content)) |block| {
        if (equal(stringField(block, "type"), kind)) {
            return true;
        }
    }
    return false;
}

pub fn textBlock(allocator: Allocator, text: []const u8) !Value {
    return jsonObject(allocator, &.{
        .{ "type", jsonString("text") },
        .{ "text", jsonString(text) },
    });
}

pub fn sessionId(allocator: Allocator, thread_id: []const u8) ![]const u8 {
    const name = try common.fmt(allocator, "session:{s}", .{thread_id});
    return common.uuid5(allocator, namespace, name);
}

pub fn utf8Prefix(text: []const u8, limit: usize) []const u8 {
    var end = @min(text.len, limit);
    while (end > 0 and end < text.len and text[end] & 0xc0 == 0x80) {
        end -= 1;
    }
    return text[0..end];
}

pub fn nativeMessage(
    allocator: Allocator,
    role: []const u8,
    content: Value,
    identifier: []const u8,
) !Value {
    var message = try jsonObject(allocator, &.{
        .{ "role", jsonString(role) },
        .{ "content", content },
    });
    if (equal(role, "assistant")) {
        const compact_id = try std.mem.replaceOwned(u8, allocator, identifier, "-", "");
        const message_id = try common.fmt(allocator, "msg_{s}", .{compact_id});
        try common.set(allocator, &message, "id", jsonString(message_id));
        try common.set(allocator, &message, "type", jsonString("message"));
        try common.set(allocator, &message, "model", jsonString("<synthetic>"));
        const stop_reason = if (containsBlock(content, "tool_use")) "tool_use" else "end_turn";
        try common.set(allocator, &message, "stop_reason", jsonString(stop_reason));
        try common.set(allocator, &message, "stop_sequence", .null);
        const usage = try jsonObject(allocator, &.{
            .{ "input_tokens", common.num(0) },
            .{ "output_tokens", common.num(0) },
        });
        try common.set(allocator, &message, "usage", usage);
    }
    return message;
}

pub fn messageCost(allocator: Allocator, role: []const u8, content: Value) !usize {
    // Include append()'s envelope; its bytes dominate short image excerpts.
    const message = try nativeMessage(allocator, role, content, "00000000-0000-0000-0000-000000000000");
    const serialized = try common.json(allocator, message);
    return serialized.len;
}

pub fn incompleteResult(allocator: Allocator, id: []const u8) !Value {
    return jsonObject(allocator, &.{
        .{ "type", jsonString("tool_result") },
        .{ "tool_use_id", jsonString(id) },
        .{ "content", jsonString("[Historical tool had no saved result in the source conversation; it was not run by this import.]") },
        .{ "is_error", common.boolean(true) },
    });
}

pub fn validate(allocator: Allocator, entries: []const Value) ![][]const u8 {
    var errors = common.Warnings.init(allocator);
    var seen = std.StringHashMap(void).init(allocator);
    var session_ids = std.StringHashMap(void).init(allocator);
    var pending = std.StringHashMap(void).init(allocator);
    var all_tools = std.StringHashMap(void).init(allocator);
    var user_seen = false;
    var messages: usize = 0;
    for (entries, 0..) |entry, index| {
        const kind = stringField(entry, "type");
        const entry_session_id = stringField(entry, "sessionId");
        if (entry_session_id.len > 0) {
            try session_ids.put(entry_session_id, {});
        }
        const identifier = stringField(entry, "uuid");
        if (identifier.len > 0) {
            if (seen.contains(identifier)) {
                try errors.append(try common.fmt(allocator, "entry {d}: duplicate uuid", .{index}));
            }
            const parent = stringField(entry, "parentUuid");
            if (parent.len > 0 and !seen.contains(parent)) {
                try errors.append(try common.fmt(allocator, "entry {d}: missing parent", .{index}));
            }
            const logical_parent = stringField(entry, "logicalParentUuid");
            if (logical_parent.len > 0 and !seen.contains(logical_parent)) {
                try errors.append(try common.fmt(allocator, "entry {d}: missing logical parent", .{index}));
            }
            try seen.put(identifier, {});
        }
        if (equal(kind, "system") and equal(stringField(entry, "subtype"), "compact_boundary")) {
            if (pending.count() > 0) {
                try errors.append(try common.fmt(allocator, "entry {d}: pending tool across compaction", .{index}));
            }
            if (field(entry, "parentUuid") != .null) {
                try errors.append(try common.fmt(allocator, "entry {d}: compaction must start a new active chain", .{index}));
            }
            continue;
        }
        if (!equal(kind, "user") and !equal(kind, "assistant")) {
            if (field(entry, "message") != .null) {
                try errors.append(try common.fmt(allocator, "entry {d}: invalid message role", .{index}));
            }
            continue;
        }
        messages += 1;
        if (equal(kind, "user")) {
            user_seen = true;
        }
        if (identifier.len == 0) {
            try errors.append(try common.fmt(allocator, "entry {d}: missing uuid", .{index}));
        }
        const message = field(entry, "message");
        if (!equal(stringField(message, "role"), kind)) {
            try errors.append(try common.fmt(allocator, "entry {d}: role mismatch", .{index}));
        }
        const sidechain = field(entry, "isSidechain");
        if (sidechain != .bool or sidechain.bool or !equal(stringField(entry, "entrypoint"), "cli")) {
            try errors.append(try common.fmt(allocator, "entry {d}: not a normal CLI session", .{index}));
        }
        const content = field(message, "content");
        if (pending.count() > 0) {
            var returns = std.StringHashMap(void).init(allocator);
            for (elements(content)) |block| {
                if (equal(stringField(block, "type"), "tool_result")) {
                    try returns.put(stringField(block, "tool_use_id"), {});
                }
            }
            var complete = equal(kind, "user");
            var iter = pending.keyIterator();
            while (iter.next()) |tool_id| {
                if (!returns.contains(tool_id.*)) {
                    complete = false;
                }
            }
            if (!complete) {
                try errors.append(try common.fmt(allocator, "entry {d}: tool results must immediately follow their calls", .{index}));
            }
        }
        if (content == .string) {
            if (content.string.len == 0) {
                try errors.append(try common.fmt(allocator, "entry {d}: empty message", .{index}));
            }
            continue;
        }
        if (content != .array or elements(content).len == 0) {
            try errors.append(try common.fmt(allocator, "entry {d}: empty or invalid message", .{index}));
        }
        for (elements(content)) |block| {
            if (block != .object) {
                try errors.append(try common.fmt(allocator, "entry {d}: invalid content block", .{index}));
                continue;
            }
            const block_type = stringField(block, "type");
            if (equal(block_type, "tool_use")) {
                const tool_id = stringField(block, "id");
                if (all_tools.contains(tool_id) or tool_id.len == 0) {
                    try errors.append(try common.fmt(allocator, "entry {d}: duplicate/empty tool ID", .{index}));
                }
                if (!equal(kind, "assistant")) {
                    try errors.append(try common.fmt(allocator, "entry {d}: tool call must be assistant content", .{index}));
                }
                try pending.put(tool_id, {});
                try all_tools.put(tool_id, {});
            } else if (equal(block_type, "tool_result")) {
                const tool_id = stringField(block, "tool_use_id");
                if (!pending.remove(tool_id)) {
                    try errors.append(try common.fmt(allocator, "entry {d}: orphan tool result", .{index}));
                }
                if (!equal(kind, "user")) {
                    try errors.append(try common.fmt(allocator, "entry {d}: tool result must be user content", .{index}));
                }
            }
        }
    }
    if (pending.count() > 0) {
        try errors.append("session ends with unresolved tool calls");
    }
    if (session_ids.count() != 1) {
        try errors.append("session ID missing or inconsistent");
    }
    if (messages == 0) {
        try errors.append("session has no conversation messages");
    }
    if (messages > 0 and !user_seen) {
        try errors.append("session has no user message for discovery");
    }
    return errors.toOwnedSlice();
}
