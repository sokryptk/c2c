const std = @import("std");
const common = @import("../../common.zig");
const source = @import("../../source.zig");
const fixtures = @import("fixtures.zig");
const Fixture = fixtures.Fixture;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectString = std.testing.expectEqualStrings;
const record = fixtures.record;

test "projected tool display text supplements arbitrary raw tool pairs unchanged" {
    for ([_][3][]const u8{
        .{ "function_call", "function_call_output", "arguments" },
        .{ "custom_tool_call", "custom_tool_call_output", "input" },
    }) |kinds| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var fixture = try Fixture.init(allocator);
        defer fixture.deinit();
        const call = try common.obj(allocator, &.{
            .{ "type", common.str(kinds[0]) },
            .{ "call_id", common.str("lookup-1") },
            .{ "name", common.str("lookup_record") },
            .{ kinds[2], common.str("{\"record_id\":42}") },
        });
        const output = try common.obj(allocator, &.{
            .{ "type", common.str(kinds[1]) },
            .{ "call_id", common.str("lookup-1") },
            .{ "output", common.str("Found record 42") },
        });
        try fixture.records(&.{
            try record(allocator, "response_item", 0, call),
            try record(allocator, "response_item", 1, output),
            try common.parse(
                allocator,
                "{\"type\":\"event_msg\",\"ordinal\":2,\"payload\":{\"type\":\"item_completed\"," ++
                    "\"item\":{\"type\":\"AgentMessage\",\"id\":\"tool-display-1\"," ++
                    "\"content\":[{\"type\":\"Text\",\"text\":\"Historical tool display\"}]}}}",
            ),
        });
        const data = try fixture.temporary_directory.dir.readFileAlloc(
            std.testing.io,
            "sessions/rollout.jsonl",
            allocator,
            .unlimited,
        );
        try fixture.history(&.{
            .{
                .ordinal = 2,
                .json = "{\"type\":\"agentMessage\",\"id\":\"tool-display-1\"," ++
                    "\"text\":\"Historical tool display\"}",
            },
        }, .{ .offset = data.len, .ordinal = 3 });
        var warnings = common.Warnings.init(allocator);
        const items = try source.readItems(allocator, fixture.thread, fixture.home, &warnings);
        try expectEqual(@as(usize, 3), items.len);
        try expectString(kinds[0], items[0].kind);
        try expectString("lookup-1", common.stringField(items[0].raw.?, "call_id"));
        try expectString("lookup_record", common.stringField(items[0].raw.?, "name"));
        try expectString("{\"record_id\":42}", common.stringField(items[0].raw.?, kinds[2]));
        try expectString(kinds[1], items[1].kind);
        try expectString("lookup-1", common.stringField(items[1].raw.?, "call_id"));
        try expectString("Found record 42", items[1].text);
        try expectString("agentMessage", items[2].kind);
        try expectString("Historical tool display", items[2].text);
        try expectString("tool-display-1", items[2].id);
        for (items, 0..) |item, ordinal| {
            try expectEqual(@as(i64, @intCast(ordinal)), item.ordinal);
        }
    }
}

test "mapped projected command suppresses duplicate raw call and output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    const data =
        "{\"type\":\"response_item\",\"ordinal\":0,\"payload\":{\"type\":\"function_call\"," ++
        "\"call_id\":\"shell-1\",\"name\":\"shell\"," ++
        "\"arguments\":\"{\\\"command\\\":\\\"pwd\\\"}\"}}\n" ++
        "{\"type\":\"response_item\",\"ordinal\":1,\"payload\":{" ++
        "\"type\":\"function_call_output\",\"call_id\":\"shell-1\",\"output\":\"/project\"}}\n" ++
        "{\"type\":\"event_msg\",\"ordinal\":2,\"payload\":{\"type\":\"item_completed\"," ++
        "\"item\":{\"type\":\"CommandExecution\",\"id\":\"shell-1\",\"command\":[\"pwd\"]," ++
        "\"aggregated_output\":\"/project\"}}}";
    try fixture.rollout(data);
    try fixture.history(&.{
        .{
            .ordinal = 2,
            .json = "{\"type\":\"commandExecution\",\"id\":\"shell-1\",\"command\":\"pwd\"," ++
                "\"aggregatedOutput\":\"/project\",\"exitCode\":0}",
        },
    }, .{ .offset = data.len, .ordinal = 3 });
    var warnings = common.Warnings.init(allocator);
    const items = try source.readItems(allocator, fixture.thread, fixture.home, &warnings);
    try expectEqual(@as(usize, 1), items.len);
    try expectString("commandExecution", items[0].kind);
    try expectString("shell-1", items[0].id);
    try expectString("/project", items[0].text);
}

test "mapped inner command suppresses differently identified outer exec wrapper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    const data =
        "{\"type\":\"response_item\",\"ordinal\":0,\"payload\":{\"type\":\"custom_tool_call\"," ++
        "\"call_id\":\"outer-exec-1\",\"name\":\"functions.exec\"," ++
        "\"input\":\"text(await tools.exec_command({cmd:'pwd'}));\"}}\n" ++
        "{\"type\":\"event_msg\",\"ordinal\":1,\"payload\":{\"type\":\"item_completed\"," ++
        "\"item\":{\"type\":\"CommandExecution\",\"id\":\"inner-command-1\"," ++
        "\"command\":[\"pwd\"],\"aggregated_output\":\"/project\"}}}\n" ++
        "{\"type\":\"response_item\",\"ordinal\":2,\"payload\":{" ++
        "\"type\":\"custom_tool_call_output\",\"call_id\":\"outer-exec-1\"," ++
        "\"output\":\"/project\"}}";
    try fixture.rollout(data);
    try fixture.history(&.{
        .{
            .ordinal = 1,
            .json = "{\"type\":\"commandExecution\",\"id\":\"inner-command-1\",\"command\":\"pwd\"," ++
                "\"aggregatedOutput\":\"/project\",\"exitCode\":0}",
        },
    }, .{ .offset = data.len, .ordinal = 3 });
    var warnings = common.Warnings.init(allocator);
    const items = try source.readItems(allocator, fixture.thread, fixture.home, &warnings);
    try expectEqual(@as(usize, 1), items.len);
    try expectString("commandExecution", items[0].kind);
    try expectString("inner-command-1", items[0].id);
    try expectString("/project", items[0].text);
}

test "mapped command completed after wrapper output and token count suppresses raw duplicates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    const data =
        "{\"type\":\"response_item\",\"ordinal\":0,\"payload\":{\"type\":\"custom_tool_call\"," ++
        "\"call_id\":\"outer-exec-1\",\"name\":\"functions.exec\"," ++
        "\"input\":\"text(await tools.exec_command({cmd:'pwd'}));\"}}\n" ++
        "{\"type\":\"token_usage_record\",\"ordinal\":1,\"payload\":{\"total_tokens\":20}}\n" ++
        "{\"type\":\"response_item\",\"ordinal\":2,\"payload\":{" ++
        "\"type\":\"custom_tool_call_output\",\"call_id\":\"outer-exec-1\"," ++
        "\"output\":\"/project\"}}\n" ++
        "{\"type\":\"event_msg\",\"ordinal\":3,\"payload\":{\"type\":\"token_count\"," ++
        "\"info\":{\"total_token_usage\":{\"total_tokens\":20}}}}\n" ++
        "{\"type\":\"event_msg\",\"ordinal\":4,\"payload\":{\"type\":\"item_completed\"," ++
        "\"item\":{\"type\":\"CommandExecution\",\"id\":\"inner-command-1\"," ++
        "\"command\":[\"pwd\"],\"aggregated_output\":\"/project\"}}}";
    try fixture.rollout(data);
    try fixture.history(&.{
        .{
            .ordinal = 4,
            .json = "{\"type\":\"commandExecution\",\"id\":\"inner-command-1\",\"command\":\"pwd\"," ++
                "\"aggregatedOutput\":\"/project\",\"exitCode\":0}",
        },
    }, .{ .offset = data.len, .ordinal = 5 });
    var warnings = common.Warnings.init(allocator);
    const items = try source.readItems(allocator, fixture.thread, fixture.home, &warnings);
    try expectEqual(@as(usize, 1), items.len);
    try expectString("commandExecution", items[0].kind);
    try expectString("inner-command-1", items[0].id);
    try expectString("/project", items[0].text);
    try expectString("pwd", common.stringField(items[0].raw.?, "command"));
    try expectString("/project", common.stringField(items[0].raw.?, "aggregatedOutput"));
    try expectEqual(@as(i64, 4), items[0].ordinal);
}

test "unrelated projected command cannot suppress an arbitrary completed function call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    const data =
        "{\"type\":\"response_item\",\"ordinal\":0,\"payload\":{\"type\":\"function_call\"," ++
        "\"call_id\":\"inspect-1\",\"name\":\"inspect\"," ++
        "\"arguments\":\"{\\\"record_id\\\":42}\"}}\n" ++
        "{\"type\":\"event_msg\",\"ordinal\":1,\"payload\":{\"type\":\"item_completed\"," ++
        "\"item\":{\"type\":\"SubAgentActivity\",\"id\":\"agent-activity-1\"}}}\n" ++
        "{\"type\":\"response_item\",\"ordinal\":2,\"payload\":{" ++
        "\"type\":\"function_call_output\",\"call_id\":\"inspect-1\"," ++
        "\"output\":\"Inspection completed\"}}\n" ++
        "{\"type\":\"event_msg\",\"ordinal\":3,\"payload\":{\"type\":\"token_count\"," ++
        "\"info\":{\"total_token_usage\":{\"total_tokens\":20}}}}\n" ++
        "{\"type\":\"event_msg\",\"ordinal\":4,\"payload\":{\"type\":\"item_completed\"," ++
        "\"item\":{\"type\":\"CommandExecution\",\"id\":\"unrelated-command-1\"," ++
        "\"command\":[\"pwd\"],\"aggregated_output\":\"/project\"}}}";
    try fixture.rollout(data);
    try fixture.history(&.{
        .{
            .ordinal = 4,
            .json = "{\"type\":\"commandExecution\",\"id\":\"unrelated-command-1\",\"command\":\"pwd\"," ++
                "\"aggregatedOutput\":\"/project\",\"exitCode\":0}",
        },
    }, .{ .offset = data.len, .ordinal = 5 });
    var warnings = common.Warnings.init(allocator);
    const items = try source.readItems(allocator, fixture.thread, fixture.home, &warnings);
    try expectEqual(@as(usize, 3), items.len);
    try expectString("function_call", items[0].kind);
    try expectString("inspect-1", common.stringField(items[0].raw.?, "call_id"));
    try expectString("inspect", common.stringField(items[0].raw.?, "name"));
    try expectString("{\"record_id\":42}", common.stringField(items[0].raw.?, "arguments"));
    try expectString("function_call_output", items[1].kind);
    try expectString("inspect-1", common.stringField(items[1].raw.?, "call_id"));
    try expectString("Inspection completed", items[1].text);
    try expectString("commandExecution", items[2].kind);
    try expectString("unrelated-command-1", items[2].id);
    try expectString("/project", items[2].text);
    for ([_]i64{ 0, 2, 4 }, items) |ordinal, item| {
        try expectEqual(ordinal, item.ordinal);
    }
}

test "live tail output completes a supplemented pre cursor call exactly once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    const prefix =
        "{\"type\":\"response_item\",\"ordinal\":0,\"payload\":{\"type\":\"message\"," ++
        "\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Raw user text\"}]}}\n" ++
        "{\"type\":\"response_item\",\"ordinal\":1,\"payload\":{\"type\":\"function_call\"," ++
        "\"call_id\":\"lookup-1\",\"name\":\"lookup_record\"," ++
        "\"arguments\":\"{\\\"record_id\\\":42}\"}}\n" ++
        "";
    try fixture.rollout(
        prefix ++ "{\"type\":\"response_item\",\"ordinal\":2,\"payload\":{" ++
            "\"type\":\"function_call_output\",\"call_id\":\"lookup-1\"," ++
            "\"output\":\"Found record 42\"}}\n",
    );
    try fixture.history(&.{
        .{
            .ordinal = 0,
            .json = "{\"type\":\"userMessage\",\"id\":\"user-1\",\"content\":[{\"type\":\"text\"," ++
                "\"text\":\"Projected user text\"}]}",
        },
    }, .{ .offset = prefix.len, .ordinal = 2 });
    var warnings = common.Warnings.init(allocator);
    const items = try source.readItems(allocator, fixture.thread, fixture.home, &warnings);
    try expectEqual(@as(usize, 3), items.len);
    try expectString("Projected user text", items[0].text);
    try expectString("function_call", items[1].kind);
    try expectString("lookup-1", common.stringField(items[1].raw.?, "call_id"));
    try expectString("function_call_output", items[2].kind);
    try expectString("lookup-1", common.stringField(items[2].raw.?, "call_id"));
    try expectString("Found record 42", items[2].text);
    for (items, 0..) |item, ordinal| {
        try expectEqual(@as(i64, @intCast(ordinal)), item.ordinal);
    }
}

test "tool supplementation ignores malformed private content and raw display messages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    const data =
        "{\"type\":\"response_item\",\"ordinal\":0,\"timestamp\":\"2026-01-01T00:00:00Z\"," ++
        "\"payload\":{\"type\":\"message\",\"role\":\"system\"," ++
        "\"content\":{\"type\":\"function_call\",\"call_id\":\"private-call\"," ++
        "\"name\":\"PRIVATE SYSTEM\"}}}\n" ++
        "{\"type\":\"response_item\",\"ordinal\":1,\"timestamp\":\"2026-01-01T00:00:00Z\"," ++
        "\"payload\":{\"type\":\"message\",\"role\":\"developer\",\"content\":[42," ++
        "{\"type\":\"privateInstruction\",\"text\":\"PRIVATE DEVELOPER\"}]}}\n" ++
        "{\"type\":\"response_item\",\"ordinal\":2,\"timestamp\":\"2026-01-01T00:00:00Z\"," ++
        "\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"channel\":\"analysis\"," ++
        "\"content\":{\"type\":\"output_text\",\"text\":\"PRIVATE REASONING\"}}}\n" ++
        "{\"type\":\"response_item\",\"ordinal\":3,\"payload\":{\"type\":\"function_call\"," ++
        "\"call_id\":\"lookup-1\",\"name\":\"lookup_record\"," ++
        "\"arguments\":\"{\\\"record_id\\\":42}\"}}\n" ++
        "{\"type\":\"response_item\",\"ordinal\":4,\"payload\":{" ++
        "\"type\":\"function_call_output\",\"call_id\":\"lookup-1\"," ++
        "\"output\":\"Found record 42\"}}\n" ++
        "{\"type\":\"response_item\",\"ordinal\":5,\"payload\":{\"type\":\"message\"," ++
        "\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\"," ++
        "\"text\":\"Unprojected duplicate display\"}]}}";
    try fixture.rollout(data);
    try fixture.history(&.{
        .{
            .ordinal = 5,
            .json = "{\"type\":\"agentMessage\",\"id\":\"tool-display-1\"," ++
                "\"text\":\"Authoritative projected display\"}",
        },
    }, .{ .offset = data.len, .ordinal = 6 });
    var warnings = common.Warnings.init(allocator);
    const items = try source.readItems(allocator, fixture.thread, fixture.home, &warnings);
    try expectEqual(@as(usize, 3), items.len);
    try expectString("function_call", items[0].kind);
    try expectString("function_call_output", items[1].kind);
    try expectString("Authoritative projected display", items[2].text);
    for (items) |item| {
        try expect(std.mem.indexOf(u8, item.text, "PRIVATE") == null);
        if (item.raw) |raw| {
            try expect(std.mem.indexOf(u8, try common.json(allocator, raw), "PRIVATE") == null);
        }
    }
    try expectEqual(@as(usize, 0), warnings.items.len);
}
