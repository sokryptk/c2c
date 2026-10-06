const std = @import("std");
const common = @import("../common.zig");
const Allocator = common.Allocator;
const Value = common.Value;
const jsonString = common.str;
const Values = std.array_list.Managed(Value);
const codec = @import("codec.zig");
const read = @import("read.zig");

const MAX_ACTIVE_BYTES: usize = 240_000;

fn textBlock(allocator: Allocator, value: []const u8) !Value {
    return common.obj(allocator, &.{
        .{ "type", jsonString("text") },
        .{ "text", jsonString(value) },
    });
}

fn envelope(allocator: Allocator, id: []const u8, role: []const u8, time: []const u8, content: []const Value) !Value {
    const message = try common.obj(allocator, &.{
        .{ "role", jsonString(role) },
        .{ "content", try common.arr(allocator, content) },
    });
    return common.obj(allocator, &.{
        .{ "uuid", jsonString(id) },
        .{ "type", jsonString(role) },
        .{ "timestamp", jsonString(time) },
        .{ "message", message },
    });
}

test "OpenCode provider identities are distinct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const codex_id = try codec.sessionId(allocator, "codex", "same");
    const claude_id = try codec.sessionId(allocator, "claude", "same");
    try std.testing.expect(!common.eq(codex_id, claude_id));
}

test "OpenCode conversion retains tools and completed native records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const thread = common.Thread{
        .id = "source-fixture",
        .title = "Fixture",
        .cwd = "/tmp",
        .created_at = "2026-10-01T10:00:00.000Z",
        .updated_at = "2026-10-01T10:00:00.000Z",
        .rollout_path = "/tmp/source",
        .provider = "claude",
    };
    const user_text = try textBlock(allocator, "Fixture user");
    const user = try envelope(allocator, "u", "user", thread.created_at, &.{user_text});
    const input = try common.obj(allocator, &.{
        .{ "command", jsonString("printf fixture") },
    });
    const tool_call = try common.obj(allocator, &.{
        .{ "type", jsonString("tool_use") },
        .{ "id", jsonString("fixture-call") },
        .{ "name", jsonString("Bash") },
        .{ "input", input },
    });
    const call = try envelope(allocator, "a", "assistant", thread.created_at, &.{tool_call});
    const tool_result = try common.obj(allocator, &.{
        .{ "type", jsonString("tool_result") },
        .{ "tool_use_id", jsonString("fixture-call") },
        .{ "content", jsonString("fixture") },
    });
    const result = try envelope(allocator, "r", "user", thread.created_at, &.{tool_result});
    const converted = try codec.convert(allocator, thread, &.{ user, call, result }, .{});
    const validation_errors = try codec.validate(allocator, converted.entries);
    try std.testing.expectEqual(@as(usize, 0), validation_errors.len);
    const messages = common.list(common.get(converted.entries[0], "messages"));
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    const tool = common.list(common.get(messages[1], "content"))[0];
    const state = common.get(tool, "state");
    try std.testing.expectEqualStrings("completed", common.stringField(state, "status"));
    const imported_origin = try codec.origin(allocator, converted.entries[0]);
    try std.testing.expect(imported_origin.unchanged);
    const registration_matches = try codec.registrationMatches(allocator, converted.entries, converted.entries[0]);
    try std.testing.expect(registration_matches);
}

test "OpenCode checkpoint counts nested JSON escaping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const thread = common.Thread{
        .id = "escaped-fixture",
        .title = "Escaping",
        .cwd = "/tmp",
        .created_at = "2026-10-01T10:00:00.000Z",
        .updated_at = "2026-10-01T10:00:00.000Z",
        .rollout_path = "/tmp/source",
        .provider = "claude",
    };
    const fragments = try allocator.dupe([]const u8, &([_][]const u8{"\\\"\n\r\t\x01"} ** 1500));
    const noisy = try std.mem.join(allocator, "", fragments);
    var entries = Values.init(allocator);
    for (0..50) |index| {
        const id = try common.fmt(allocator, "entry-{d}", .{index});
        const role = if (index % 2 == 0) "user" else "assistant";
        const text = try textBlock(allocator, noisy);
        const entry = try envelope(allocator, id, role, thread.created_at, &.{text});
        try entries.append(entry);
    }
    const newest_text = try textBlock(allocator, "NEWEST_EXACT_REQUEST");
    const newest_entry = try envelope(allocator, "last", "user", thread.created_at, &.{newest_text});
    try entries.append(newest_entry);
    const converted = try codec.convert(allocator, thread, entries.items, .{});
    const messages = common.list(common.get(converted.entries[0], "messages"));
    try std.testing.expectEqual(@as(usize, 52), messages.len);
    const checkpoint = messages[messages.len - 1];
    try std.testing.expectEqualStrings("compaction", common.stringField(checkpoint, "type"));
    const encoded_checkpoint = try common.json(allocator, checkpoint);
    try std.testing.expect(encoded_checkpoint.len + 2000 <= MAX_ACTIVE_BYTES);
    try std.testing.expect(std.mem.indexOf(u8, common.stringField(checkpoint, "recent"), "NEWEST_EXACT_REQUEST") != null);
    try std.testing.expectEqualStrings(noisy, common.stringField(messages[0], "text"));
}

test "OpenCode opaque compaction preserves active visible history" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const native = try common.parse(allocator,
        \\{
        \\  "messages": [
        \\    {
        \\      "id": "msg_user",
        \\      "type": "user",
        \\      "time": {
        \\        "created": 1
        \\      },
        \\      "text": "Retain original instruction"
        \\    },
        \\    {
        \\      "id": "msg_compact",
        \\      "type": "compaction",
        \\      "time": {
        \\        "created": 2
        \\      },
        \\      "status": "completed",
        \\      "reason": "auto",
        \\      "providerContext": {
        \\        "opaque": "private"
        \\      }
        \\    }
        \\  ]
        \\}
    );
    var warnings = common.Warnings.init(allocator);
    const entries = try read.readDataEntries(allocator, native, &warnings);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("user", common.stringField(entries[0], "type"));
    try std.testing.expect(warnings.items.len > 0);
    const visible_entries = try common.arr(allocator, entries);
    const encoded = try common.json(allocator, visible_entries);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "private") == null);
}

test "OpenCode tool metadata errors and shell exit remain visible" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const native = try common.parse(allocator,
        \\{
        \\  "messages": [
        \\    {
        \\      "id": "msg_tool",
        \\      "type": "assistant",
        \\      "time": {
        \\        "created": 1
        \\      },
        \\      "content": [
        \\        {
        \\          "type": "tool",
        \\          "id": "call_fixture",
        \\          "name": "lookup",
        \\          "state": {
        \\            "status": "error",
        \\            "input": {},
        \\            "content": [
        \\              {
        \\                "type": "text",
        \\                "text": "partial output"
        \\              }
        \\            ],
        \\            "error": {
        \\              "type": "fixture",
        \\              "message": "failed lookup"
        \\            },
        \\            "metadata": {
        \\              "structured": {
        \\                "count": 7
        \\              }
        \\            }
        \\          }
        \\        }
        \\      ]
        \\    },
        \\    {
        \\      "id": "msg_shell",
        \\      "type": "shell",
        \\      "time": {
        \\        "created": 2
        \\      },
        \\      "command": "exit 3",
        \\      "status": "completed",
        \\      "output": {
        \\        "output": "saved stdout",
        \\        "exit": 3
        \\      }
        \\    },
        \\    {
        \\      "id": "msg_error",
        \\      "type": "assistant",
        \\      "time": {
        \\        "created": 3
        \\      },
        \\      "content": [],
        \\      "error": {
        \\        "type": "provider",
        \\        "message": "provider unavailable"
        \\      }
        \\    }
        \\  ]
        \\}
    );
    var warnings = common.Warnings.init(allocator);
    const entries = try read.readDataEntries(allocator, native, &warnings);
    const visible_entries = try common.arr(allocator, entries);
    const encoded = try common.json(allocator, visible_entries);
    const expected_values = [_][]const u8{
        "partial output",
        "failed lookup",
        "structured",
        "count",
        "exit",
        "saved stdout",
        "provider unavailable",
    };
    for (expected_values) |value| {
        try std.testing.expect(std.mem.indexOf(u8, encoded, value) != null);
    }
}
