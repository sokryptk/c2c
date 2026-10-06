const std = @import("std");
const common = @import("../common.zig");
const codec = @import("codec.zig");
const format = @import("format.zig");
const Value = common.Value;
const Allocator = common.Allocator;
const jsonString = common.str;
const jsonInteger = common.num;

fn is(v: Value, kind: []const u8) bool {
    return common.eq(common.stringField(v, "type"), kind);
}

fn fixtureThread() common.Thread {
    return .{
        .id = "claude-session",
        .title = "Synthetic",
        .cwd = "/tmp/project",
        .created_at = "2026-01-02T03:04:05.000Z",
        .updated_at = "2026-01-02T03:05:00.000Z",
        .rollout_path = "/tmp/claude.jsonl",
    };
}

fn fixtureEntry(allocator: Allocator, role: []const u8, content: Value) !Value {
    const message = try common.obj(allocator, &.{
        .{ "role", jsonString(role) },
        .{ "content", content },
    });
    return common.obj(allocator, &.{
        .{ "type", jsonString(role) },
        .{ "timestamp", jsonString("2026-01-02T03:04:06.000Z") },
        .{ "message", message },
    });
}
test "Codex has model records visible records and deterministic IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const entries = &.{
        try fixtureEntry(allocator, "user", jsonString("Question")),
        try fixtureEntry(allocator, "assistant", jsonString("Answer")),
    };
    const result = try codec.convert(allocator, fixtureThread(), entries, .{});
    try std.testing.expectEqual(@as(usize, 2), result.message_count);
    try std.testing.expectEqual(@as(usize, 7), result.entries.len);
    try std.testing.expectEqual(@as(usize, 0), (try codec.validate(allocator, result.entries)).len);
    try std.testing.expectEqualStrings(try codec.sessionId(allocator, "claude-session"), result.session_id);
    const path = try codec.targetPath(allocator, fixtureThread(), "/tmp/codex");
    try std.testing.expect(std.mem.indexOf(u8, path, "/sessions/2026/01/02/") != null);
    const migrated = try allocator.alloc(Value, result.entries.len);
    for (result.entries, 0..) |row, i| {
        migrated[i] = try common.clone(allocator, row);
        try common.set(allocator, &migrated[i], "ordinal", jsonInteger(@intCast(i)));
    }
    var meta = common.get(migrated[0], "payload");
    try common.set(allocator, &meta, "history_mode", jsonString("paginated"));
    try common.set(allocator, &migrated[0], "payload", meta);
    try std.testing.expect(try codec.registrationMatches(allocator, result.entries, migrated));
    try std.testing.expectEqualStrings(
        try format.fingerprint(allocator, result.entries),
        try format.fingerprint(allocator, migrated),
    );
}
test "Bash history uses file URI and paired completed native tool records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const call = try common.parse(
        allocator,
        "[{\"type\":\"tool_use\",\"id\":\"a\",\"name\":\"Bash\",\"input\":{\"command\":\"pwd\"}}]",
    );
    const output = try common.parse(
        allocator,
        "[{\"type\":\"tool_result\",\"tool_use_id\":\"a\",\"content\":\"/tmp/project\"}]",
    );
    const result = try codec.convert(
        allocator,
        fixtureThread(),
        &.{
            try fixtureEntry(allocator, "user", jsonString("Run")),
            try fixtureEntry(allocator, "assistant", call),
            try fixtureEntry(allocator, "user", output),
            try fixtureEntry(allocator, "assistant", jsonString("Done")),
        },
        .{},
    );
    try std.testing.expectEqual(@as(usize, 1), result.tool_count);
    var command_seen = false;
    for (result.entries) |row| {
        const item = common.get(common.get(row, "payload"), "item");
        if (is(item, "CommandExecution")) {
            command_seen = true;
            try std.testing.expectEqualStrings("file:///tmp/project", common.stringField(item, "cwd"));
            try std.testing.expectEqualStrings("/tmp/project", common.stringField(item, "aggregated_output"));
            try std.testing.expect(common.get(item, "exit_code") == .null);
        }
    }
    try std.testing.expect(command_seen);
    try std.testing.expectEqual(@as(usize, 0), result.warnings.len);
}
test "large single turn preserves request newest answer and total context budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var entries = std.array_list.Managed(Value).init(allocator);
    try entries.append(try fixtureEntry(allocator, "user", jsonString("Original request")));
    const huge = try allocator.alloc(u8, 100_000);
    @memset(huge, 'x');
    for (0..20) |_| {
        try entries.append(try fixtureEntry(allocator, "assistant", jsonString(huge)));
    }
    try entries.append(try fixtureEntry(allocator, "assistant", jsonString("Newest final answer")));
    const result = try codec.convert(
        allocator,
        fixtureThread(),
        entries.items,
        .{ .transcript_path = "/native/transcript.jsonl" },
    );
    const last = result.entries[result.entries.len - 1];
    try std.testing.expect(is(last, "compacted"));
    const active_json = try common.json(allocator, common.get(common.get(last, "payload"), "replacement_history"));
    try std.testing.expect(active_json.len < 240_000);
    try std.testing.expect(std.mem.indexOf(u8, active_json, "Original request") != null);
    try std.testing.expect(std.mem.indexOf(u8, active_json, "Newest final answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, active_json, "excerpt shortened") != null);
    try std.testing.expectEqual(@as(usize, 22), result.message_count);
}
test "private thinking excluded and tool images use input_image" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const call = try common.parse(
        allocator,
        "[{\"type\":\"thinking\",\"thinking\":\"PRIVATE-THOUGHT\"}," ++
            "{\"type\":\"tool_use\",\"id\":\"a\",\"name\":\"Read\",\"input\":{\"file_path\":\"/pic.png\"}}]",
    );
    const output = try common.parse(
        allocator,
        "[{\"type\":\"tool_result\",\"tool_use_id\":\"a\",\"content\":[" ++
            "{\"type\":\"image\",\"source\":{\"type\":\"base64\"," ++
            "\"media_type\":\"image/png\",\"data\":\"ZmFrZQ==\"}}]}]",
    );
    const result = try codec.convert(
        allocator,
        fixtureThread(),
        &.{
            try fixtureEntry(allocator, "user", jsonString("See image")),
            try fixtureEntry(allocator, "assistant", call),
            try fixtureEntry(allocator, "user", output),
        },
        .{},
    );
    var saw_image = false;
    for (result.entries) |row| {
        const payload = common.get(row, "payload");
        if (is(payload, "function_call_output")) {
            const parts = common.list(common.get(payload, "output"));
            saw_image = parts.len == 1 and is(parts[0], "input_image");
        }
    }
    try std.testing.expect(saw_image);
    const converted_entries = try common.arr(allocator, result.entries);
    const converted_json = try common.json(allocator, converted_entries);
    try std.testing.expect(std.mem.indexOf(u8, converted_json, "PRIVATE-THOUGHT") == null);
}

test "provider identities and provenance are explicit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const entries = &.{try fixtureEntry(allocator, "user", jsonString("Question"))};
    var previous: ?[]const u8 = null;
    for ([_][]const u8{ "claude", "omp", "opencode" }) |provider| {
        const result = try codec.convert(allocator, fixtureThread(), entries, .{ .source_provider = provider });
        try std.testing.expectEqualStrings(
            try common.sessionIdFor(allocator, "codex", provider, fixtureThread().id),
            result.session_id,
        );
        if (previous) |id| {
            try std.testing.expect(!common.eq(id, result.session_id));
        }
        previous = result.session_id;
        const originator = common.stringField(common.get(result.entries[0], "payload"), "originator");
        try std.testing.expect(std.mem.startsWith(u8, originator, try common.fmt(allocator, "c2c:{s}:", .{provider})));
        try std.testing.expect(std.mem.indexOf(
            u8,
            try codec.targetPathFor(allocator, fixtureThread(), "/tmp/codex", provider),
            result.session_id,
        ) != null);
    }
}
test "compacted replacement history rejects orphan tool results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const result = try codec.convert(
        allocator,
        fixtureThread(),
        &.{try fixtureEntry(allocator, "user", jsonString("Question"))},
        .{},
    );
    var entries = std.array_list.Managed(Value).init(allocator);
    try entries.appendSlice(result.entries);
    const result_item = try common.obj(allocator, &.{
        .{ "type", jsonString("function_call_output") },
        .{ "call_id", jsonString("orphan") },
        .{ "output", jsonString("content") },
    });
    const replacement_history = try common.arr(allocator, &.{result_item});
    const payload = try common.obj(allocator, &.{
        .{ "replacement_history", replacement_history },
    });
    const compacted = try common.obj(allocator, &.{
        .{ "type", jsonString("compacted") },
        .{ "timestamp", jsonString(fixtureThread().updated_at) },
        .{ "payload", payload },
    });
    try entries.append(compacted);
    const errors = try codec.validate(allocator, entries.items);
    try std.testing.expectEqual(@as(usize, 1), errors.len);
    try std.testing.expectEqualStrings("Unpaired tool result", errors[0]);
}
