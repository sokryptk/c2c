const std = @import("std");
const common = @import("../../common.zig");
const source = @import("../../source.zig");
const fixtures = @import("fixtures.zig");
const Fixture = fixtures.Fixture;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectString = std.testing.expectEqualStrings;
const image_one = "data:image/png;base64,Zmlyc3Q=";

test "raw reader filters private messages and retains tools and images" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    try fixture.rollout(
        "{\"type\":\"response_item\",\"ordinal\":0,\"payload\":{\"type\":\"message\"," ++
            "\"role\":\"system\",\"content\":[{\"type\":\"input_text\"," ++
            "\"text\":\"private system\"}]}}\n" ++
            "{\"type\":\"response_item\",\"ordinal\":1,\"payload\":{\"type\":\"message\"," ++
            "\"role\":\"developer\",\"content\":[{\"type\":\"input_text\"," ++
            "\"text\":\"private developer\"}]}}\n" ++
            "{\"type\":\"response_item\",\"ordinal\":2,\"payload\":{\"type\":\"message\"," ++
            "\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Look\"}," ++
            "{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,Zmlyc3Q=\"}]}}\n" ++
            "{\"type\":\"response_item\",\"ordinal\":3,\"payload\":{\"type\":\"message\"," ++
            "\"role\":\"assistant\",\"channel\":\"analysis\",\"content\":[{\"type\":\"output_text\"," ++
            "\"text\":\"private reasoning\"}]}}\n" ++
            "{\"type\":\"response_item\",\"ordinal\":4,\"payload\":{\"type\":\"function_call\"," ++
            "\"call_id\":\"call-1\",\"name\":\"shell\"," ++
            "\"arguments\":\"{\\\"cmd\\\":\\\"pwd\\\"}\"}}\n" ++
            "{\"type\":\"response_item\",\"ordinal\":5,\"payload\":{" ++
            "\"type\":\"function_call_output\",\"call_id\":\"call-1\",\"output\":\"/project\"}}\n" ++
            "{\"type\":\"response_item\",\"ordinal\":6,\"payload\":{\"type\":\"message\"," ++
            "\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Done\"}]}}",
    );
    var warnings = common.Warnings.init(allocator);
    const items = try source.readItems(allocator, fixture.thread, fixture.home, &warnings);
    try expectEqual(@as(usize, 4), items.len);
    try expectString("user", items[0].role);
    try expectString("Look", items[0].text);
    try expectString(image_one, common.stringField(items[0].attachments[0], "url"));
    try expectString("shell", common.stringField(items[1].raw.?, "name"));
    try expectString("/project", items[2].text);
    try expectString("Done", items[3].text);
    try expectEqual(@as(i64, 6), items[3].ordinal);
}

test "projected history is authoritative sorted and followed by live tail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    const prefix = "{\"type\":\"response_item\",\"ordinal\":5,\"payload\":{\"type\":\"message\"," ++
        "\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Raw duplicate\"}]}}\n";
    try fixture.rollout(
        prefix ++ "{\"type\":\"response_item\",\"ordinal\":50,\"payload\":{\"type\":\"message\"," ++
            "\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\"," ++
            "\"text\":\"Live tail\"}]}}\n",
    );
    try fixture.history(&.{
        .{
            .ordinal = 30,
            .json = "{\"type\":\"commandExecution\",\"id\":\"cmd\",\"command\":\"pwd\"," ++
                "\"aggregatedOutput\":\"/project\",\"exitCode\":0}",
        },
        .{
            .ordinal = 6,
            .json = "{\"type\":\"userMessage\",\"id\":\"user-1\",\"content\":[{\"type\":\"text\"," ++
                "\"text\":\"Projected text\"},{\"type\":\"localImage\",\"path\":\"shots/a.png\"}]}",
        },
        .{
            .ordinal = 10,
            .json = "{\"type\":\"reasoning\",\"id\":\"hidden\",\"content\":[\"private\"]}",
        },
        .{
            .ordinal = 40,
            .json = "{\"type\":\"agentMessage\",\"id\":\"answer\",\"text\":\"Answer\"}",
        },
    }, .{ .offset = prefix.len, .ordinal = 50 });
    var warnings = common.Warnings.init(allocator);
    const items = try source.readItems(allocator, fixture.thread, fixture.home, &warnings);
    try expectEqual(@as(usize, 4), items.len);
    for ([_]i64{ 6, 30, 40, 50 }, items) |ordinal, item| {
        try expectEqual(ordinal, item.ordinal);
    }
    try expectString("Projected text", items[0].text);
    try expectString("/project/shots/a.png", common.stringField(items[0].attachments[0], "path"));
    try expectString("2026-01-01T00:00:00.123Z", items[0].timestamp);
    try expectString("/project", items[1].text);
    try expectString("Live tail", items[3].text);
}

test "reader warns on incomplete final JSON but rejects malformed complete records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    try fixture.rollout(
        "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\"," ++
            "\"content\":[{\"type\":\"input_text\",\"text\":\"Keep\"}]}}\n" ++
            "{\"type\":\"response_item\",\"payload\":",
    );
    var warnings = common.Warnings.init(allocator);
    const items = try source.readItems(allocator, fixture.thread, fixture.home, &warnings);
    try expectEqual(@as(usize, 1), items.len);
    try expectString("Keep", items[0].text);
    try expect(warnings.items.len != 0);
    try fixture.rollout("{broken record}\n");
    if (source.readItems(allocator, fixture.thread, fixture.home, &warnings)) |_| {
        return error.TestExpectedMalformedRecordError;
    } else |_| {}
}

test "compaction retains latest context but excludes instructions and ciphertext" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    try fixture.rollout(
        "{\"type\":\"compacted\",\"ordinal\":10,\"payload\":{\"message\":\"Old\"}}\n" ++
            "{\"type\":\"compacted\",\"ordinal\":33,\"timestamp\":\"2026-01-02T00:00:00Z\"," ++
            "\"payload\":{\"message\":\"\",\"replacement_history\":[{\"type\":\"message\"," ++
            "\"role\":\"system\",\"content\":[{\"type\":\"input_text\",\"text\":\"Private\"}]}," ++
            "{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\"," ++
            "\"text\":\"Inherited request\"}]},{\"type\":\"message\",\"role\":\"assistant\"," ++
            "\"channel\":\"summary\",\"content\":[{\"type\":\"output_text\"," ++
            "\"text\":\"Active summary\"}]},{\"type\":\"compaction\"," ++
            "\"encrypted_content\":\"SECRET CIPHERTEXT\"}]}}",
    );
    var warnings = common.Warnings.init(allocator);
    const compaction = (try source.readCompaction(allocator, fixture.thread, &warnings)).?;
    try expectEqual(@as(i64, 33), compaction.ordinal);
    try expectString("Active summary", compaction.summary);
    try expectEqual(@as(usize, 1), compaction.items.len);
    try expectString("Inherited request", compaction.items[0].text);
    try expect(compaction.encrypted);
}

test "projection cursor beyond rollout fails rather than losing the tail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    try fixture.rollout(
        "{\"type\":\"response_item\",\"ordinal\":1,\"payload\":{\"type\":\"message\"," ++
            "\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Keep\"}]}}",
    );
    try fixture.history(&.{
        .{
            .ordinal = 1,
            .json = "{\"type\":\"userMessage\",\"content\":[{\"type\":\"text\",\"text\":\"Keep\"}]}",
        },
    }, .{ .offset = 999999, .ordinal = 2 });
    var warnings = common.Warnings.init(allocator);
    if (source.readItems(allocator, fixture.thread, fixture.home, &warnings)) |_| {
        return error.TestExpectedTruncatedRolloutError;
    } else |_| {}
}
