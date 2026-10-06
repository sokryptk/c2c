const std = @import("std");
const common = @import("../../common.zig");
const source = @import("../../source.zig");
const fixtures = @import("fixtures.zig");
const Fixture = fixtures.Fixture;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectString = std.testing.expectEqualStrings;
const timestamp = fixtures.timestamp;
const record = fixtures.record;
const image_one = "data:image/png;base64,Zmlyc3Q=";
const image_two = "data:image/jpeg;base64,c2Vjb25k";

fn imageItem(allocator: common.Allocator, ordinal: i64, id: []const u8, path: []const u8) !common.Item {
    const attachments = try allocator.alloc(common.Value, 1);
    attachments[0] = try common.obj(allocator, &.{
        .{ "type", common.str("localImage") },
        .{ "path", common.str(path) },
    });
    return .{
        .id = id,
        .role = "tool",
        .text = "",
        .timestamp = timestamp,
        .kind = "imageView",
        .attachments = attachments,
        .raw = try common.obj(allocator, &.{
            .{ "type", common.str("imageView") },
            .{ "path", common.str(path) },
        }),
        .ordinal = ordinal,
    };
}

fn imageCall(allocator: common.Allocator, ordinal: i64, id: []const u8, kind: []const u8) !common.Value {
    const call = try common.obj(allocator, &.{
        .{ "type", common.str(kind) },
        .{ "call_id", common.str(id) },
        .{ "name", common.str("view_image") },
    });
    return record(allocator, "response_item", ordinal, call);
}

fn imageEvent(allocator: common.Allocator, ordinal: i64, id: []const u8, path: []const u8) !common.Value {
    const item = try common.obj(allocator, &.{
        .{ "type", common.str("ImageView") },
        .{ "id", common.str(id) },
        .{ "path", common.str(path) },
    });
    const event = try common.obj(allocator, &.{
        .{ "type", common.str("item_completed") },
        .{ "item", item },
    });
    return record(allocator, "event_msg", ordinal, event);
}

fn imageOutput(
    allocator: common.Allocator,
    ordinal: i64,
    id: []const u8,
    kind: []const u8,
    urls: []const []const u8,
) !common.Value {
    const parts = try allocator.alloc(common.Value, urls.len);
    for (urls, parts) |url, *part| {
        part.* = try common.obj(allocator, &.{
            .{ "type", common.str("input_image") },
            .{ "image_url", common.str(url) },
        });
    }
    const output = try common.obj(allocator, &.{
        .{ "type", common.str(kind) },
        .{ "call_id", common.str(id) },
        .{ "output", try common.arr(allocator, parts) },
    });
    return record(allocator, "response_item", ordinal, output);
}

fn hasWarning(warnings: common.Warnings, needle: []const u8) bool {
    for (warnings.items) |warning| {
        if (std.mem.indexOf(u8, warning, needle) != null) {
            return true;
        }
    }
    return false;
}

test "image recovery keeps historical data and path despite an existing overwritten file" {
    for ([_][2][]const u8{
        .{ "function_call", "function_call_output" },
        .{ "custom_tool_call", "custom_tool_call_output" },
    }) |kinds| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var fixture = try Fixture.init(allocator);
        defer fixture.deinit();
        fixture.thread.cwd = fixture.home;
        try fixture.temporary_directory.dir.writeFile(std.testing.io, .{
            .sub_path = "current image.png",
            .data = "overwritten image",
        });
        const path = try common.join(allocator, &.{ fixture.home, "current image.png" });
        const uri = try common.fmt(allocator, "file://{s}/current%20image.png", .{fixture.home});
        try fixture.records(&.{
            try imageCall(allocator, 0, "call-1", kinds[0]),
            try imageEvent(allocator, 1, "image-1", uri),
            try record(allocator, "token_usage_record", 2, try common.obj(allocator, &.{})),
            try imageOutput(allocator, 3, "call-1", kinds[1], &.{image_one}),
        });
        var items = [_]common.Item{try imageItem(allocator, 1, "image-1", path)};
        var warnings = common.Warnings.init(allocator);
        try source.recoverProjectedImages(allocator, &items, fixture.thread, &warnings);
        try expectString(image_one, common.stringField(items[0].attachments[0], "url"));
        try expectString(path, common.stringField(items[0].attachments[0], "path"));
        try expectString(path, common.stringField(items[0].raw.?, "path"));
        try expectEqual(@as(usize, 0), warnings.items.len);
        const current = try fixture.temporary_directory.dir.readFileAlloc(
            std.testing.io,
            "current image.png",
            allocator,
            .unlimited,
        );
        try expectString("overwritten image", current);
    }
}

test "projected Rust user events recover multiple images in attachment order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    const data =
        "{\"type\":\"response_item\",\"ordinal\":5,\"payload\":{\"type\":\"message\"," ++
        "\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Compare\"}," ++
        "{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,Zmlyc3Q=\"}," ++
        "{\"type\":\"input_text\",\"text\":\"Then this\"},{\"type\":\"input_image\"," ++
        "\"image_url\":\"data:image/jpeg;base64,c2Vjb25k\"}]}}\n" ++
        "{\"type\":\"event_msg\",\"ordinal\":6,\"payload\":{\"type\":\"item_completed\"," ++
        "\"item\":{\"type\":\"UserMessage\",\"id\":\"user-1\",\"content\":[{\"type\":\"text\"," ++
        "\"text\":\"Compare\"},{\"type\":\"local_image\",\"path\":\"shots/first.png\"}," ++
        "{\"type\":\"local_image\",\"path\":\"shots/second.jpg\"}]}}}";
    try fixture.rollout(data);
    try fixture.history(&.{
        .{
            .ordinal = 6,
            .json = "{\"type\":\"userMessage\",\"id\":\"user-1\",\"content\":[{\"type\":\"text\"," ++
                "\"text\":\"Compare\"},{\"type\":\"localImage\",\"path\":\"shots/first.png\"}," ++
                "{\"type\":\"localImage\",\"path\":\"shots/second.jpg\"}]}",
        },
    }, .{ .offset = data.len, .ordinal = 7 });
    var warnings = common.Warnings.init(allocator);
    const items = try source.readItems(allocator, fixture.thread, fixture.home, &warnings);
    try expectEqual(@as(usize, 1), items.len);
    try expectString("Compare", items[0].text);
    try expectEqual(@as(usize, 2), items[0].attachments.len);
    try expectString(image_one, common.stringField(items[0].attachments[0], "url"));
    try expectString(image_two, common.stringField(items[0].attachments[1], "url"));
    try expectString("/project/shots/first.png", common.stringField(items[0].attachments[0], "path"));
    try expectString("/project/shots/second.jpg", common.stringField(items[0].attachments[1], "path"));
}

test "image recovery requires ordinal id path and completed call identity" {
    const Case = struct {
        ordinal: i64 = 1,
        id: []const u8 = "image-1",
        path: []const u8 = "shots/a.png",
        output_id: []const u8 = "call-1",
    };
    for ([_]Case{
        .{ .ordinal = 2 },
        .{ .id = "different-image" },
        .{ .path = "shots/different.png" },
        .{ .output_id = "unrelated-call" },
    }) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var fixture = try Fixture.init(allocator);
        defer fixture.deinit();
        try fixture.records(&.{
            try imageCall(allocator, 0, "call-1", "function_call"),
            try imageEvent(allocator, case.ordinal, case.id, case.path),
            try imageOutput(allocator, 3, case.output_id, "function_call_output", &.{image_one}),
        });
        var items = [_]common.Item{try imageItem(allocator, 1, "image-1", "/project/shots/a.png")};
        var warnings = common.Warnings.init(allocator);
        try source.recoverProjectedImages(allocator, &items, fixture.thread, &warnings);
        try expect(common.get(items[0].attachments[0], "url") == .null);
        try expectString("/project/shots/a.png", common.stringField(items[0].attachments[0], "path"));
    }
}

test "image recovery refuses ambiguous groups and remote payloads" {
    const Case = struct {
        events: usize,
        outputs: usize,
        url: []const u8 = image_one,
    };
    for ([_]Case{
        .{ .events = 2, .outputs = 1 },
        .{ .events = 1, .outputs = 2 },
        .{ .events = 2, .outputs = 2 },
        .{ .events = 1, .outputs = 1, .url = "https://example.invalid/historical.png" },
    }) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var fixture = try Fixture.init(allocator);
        defer fixture.deinit();
        var records = std.array_list.Managed(common.Value).init(allocator);
        try records.append(try imageCall(allocator, 0, "call-1", "function_call"));
        const items = try allocator.alloc(common.Item, case.events);
        for (items, 0..) |*item, index| {
            const id = try common.fmt(allocator, "image-{d}", .{index + 1});
            const path = try common.fmt(allocator, "/project/{d}.png", .{index + 1});
            item.* = try imageItem(allocator, @intCast(index + 1), id, path);
            try records.append(try imageEvent(allocator, @intCast(index + 1), id, path));
        }
        const urls = try allocator.alloc([]const u8, case.outputs);
        for (urls) |*url| {
            url.* = case.url;
        }
        try records.append(try imageOutput(allocator, 3, "call-1", "function_call_output", urls));
        try fixture.records(records.items);
        var warnings = common.Warnings.init(allocator);
        try source.recoverProjectedImages(allocator, items, fixture.thread, &warnings);
        for (items) |item| {
            try expect(common.get(item.attachments[0], "url") == .null);
        }
        try expect(hasWarning(warnings, "ambiguous"));
    }
}

test "overlapping calls refuse image assignment even when outputs name the calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    try fixture.records(&.{
        try imageCall(allocator, 0, "call-1", "function_call"),
        try imageEvent(allocator, 1, "image-1", "shots/a.png"),
        try imageCall(allocator, 2, "call-2", "custom_tool_call"),
        try imageEvent(allocator, 3, "image-2", "shots/b.png"),
        try imageOutput(allocator, 4, "call-1", "function_call_output", &.{image_one}),
        try imageOutput(allocator, 5, "call-2", "custom_tool_call_output", &.{image_two}),
    });
    var items = [_]common.Item{
        try imageItem(allocator, 1, "image-1", "/project/shots/a.png"),
        try imageItem(allocator, 3, "image-2", "/project/shots/b.png"),
    };
    var warnings = common.Warnings.init(allocator);
    try source.recoverProjectedImages(allocator, &items, fixture.thread, &warnings);
    for (items) |item| {
        try expect(common.get(item.attachments[0], "url") == .null);
    }
    try expect(hasWarning(warnings, "ambiguous"));
}

test "multiple independent image calls recover their own historical payloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    try fixture.records(&.{
        try imageCall(allocator, 0, "call-1", "function_call"),
        try imageEvent(allocator, 1, "image-1", "file:///project/test%20image.png"),
        try imageOutput(allocator, 2, "call-1", "function_call_output", &.{image_one}),
        try imageCall(allocator, 3, "call-2", "function_call"),
        try imageEvent(allocator, 4, "image-2", "shots/b.png"),
        try imageOutput(allocator, 5, "call-2", "function_call_output", &.{image_two}),
    });
    var items = [_]common.Item{
        try imageItem(allocator, 1, "image-1", "/project/test image.png"),
        try imageItem(allocator, 4, "image-2", "/project/shots/b.png"),
    };
    var warnings = common.Warnings.init(allocator);
    try source.recoverProjectedImages(allocator, &items, fixture.thread, &warnings);
    try expectString(image_one, common.stringField(items[0].attachments[0], "url"));
    try expectString(image_two, common.stringField(items[1].attachments[0], "url"));
    try expectEqual(@as(usize, 0), warnings.items.len);
}
