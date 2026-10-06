const std = @import("std");
const common = @import("../common.zig");
const Allocator = common.Allocator;
const Value = common.Value;
const jsonString = common.str;
const Values = std.array_list.Managed(Value);
const jsonInteger = common.num;
const format = @import("format.zig");
const omp = @import("../omp.zig");

fn fixture() common.Thread {
    return .{
        .id = "source-session",
        .provider = "claude",
        .title = "OMP fixture",
        .cwd = "/tmp/c2c-omp-project",
        .created_at = "2026-10-06T00:00:00.000Z",
        .updated_at = "2026-10-06T00:01:00.000Z",
        .rollout_path = "/tmp/source.jsonl",
    };
}

fn fixtureEntry(allocator: Allocator, role: []const u8, content: Value) !Value {
    const parts = try format.blocks(allocator, content);
    const message = try common.obj(allocator, &.{
        .{ "role", jsonString(role) },
        .{ "content", try common.arr(allocator, parts) },
    });
    return common.obj(allocator, &.{
        .{ "type", jsonString(role) },
        .{ "uuid", jsonString("source-message") },
        .{ "timestamp", jsonString("2026-10-06T00:00:00.000Z") },
        .{ "message", message },
    });
}
test "OMP v3 native tool pairs images and provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const call = try common.parse(allocator,
        \\[{"type":"tool_use","id":"a","name":"Bash","input":{"command":"pwd"}}]
    );
    const result = try common.parse(allocator,
        \\[{"type":"tool_result","tool_use_id":"a","content":"/tmp"}]
    );
    const entries = [_]Value{
        try fixtureEntry(allocator, "user", jsonString("Question")),
        try fixtureEntry(allocator, "assistant", call),
        try fixtureEntry(allocator, "user", result),
        try fixtureEntry(allocator, "assistant", jsonString("Done")),
    };
    const converted = try omp.convert(allocator, fixture(), &entries, .{});
    try std.testing.expectEqual(@as(usize, 1), converted.tool_count);
    try std.testing.expectEqual(@as(usize, 0), (try omp.validate(allocator, converted.entries)).len);
    const origin = common.get(converted.entries[1], "data");
    try std.testing.expectEqualStrings("claude", common.stringField(origin, "sourceProvider"));
    const fingerprint = try format.fingerprint(allocator, converted.entries);
    try std.testing.expectEqualStrings(fingerprint, common.stringField(origin, "fingerprint"));
    const path = try omp.targetPath(allocator, fixture(), "/tmp/omp-agent");
    try std.testing.expect(std.mem.indexOf(u8, path, "/sessions/-tmp-c2c-omp-project/") != null);
}
test "OMP compaction preserves full archive and bounds continuation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const huge = try allocator.alloc(u8, 350_000);
    @memset(huge, 'x');
    const entries = [_]Value{
        try fixtureEntry(allocator, "user", jsonString(huge)),
        try fixtureEntry(allocator, "assistant", jsonString("Recent answer")),
    };
    const converted = try omp.convert(allocator, fixture(), &entries, .{});
    var found = false;
    for (converted.entries) |row| {
        if (format.is(row, "compaction")) {
            found = true;
            try std.testing.expect(common.stringField(row, "summary").len < 40_000);
        }
    }
    try std.testing.expect(found);
    try std.testing.expectEqual(@as(usize, 0), (try omp.validate(allocator, converted.entries)).len);
    const archive = try common.arr(allocator, converted.entries);
    const encoded_archive = try common.json(allocator, archive);
    try std.testing.expect(encoded_archive.len > 350_000);
}
test "OMP missing tool result is closed without executing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const call = try common.parse(allocator,
        \\[{"type":"tool_use","id":"a","name":"dangerous historical tool","input":{}}]
    );
    const entries = [_]Value{
        try fixtureEntry(allocator, "user", jsonString("Question")),
        try fixtureEntry(allocator, "assistant", call),
    };
    const converted = try omp.convert(allocator, fixture(), &entries, .{});
    try std.testing.expectEqual(@as(usize, 1), converted.tool_count);
    try std.testing.expectEqual(@as(usize, 1), converted.warnings.len);
    const last = common.get(converted.entries[converted.entries.len - 1], "message");
    try std.testing.expect(common.boolValue(common.get(last, "isError")));
}

fn testDirectory(allocator: Allocator) ![]const u8 {
    const path = try allocator.dupeZ(u8, "/tmp/c2c-omp-test-XXXXXX");
    if (common.c.mkdtemp(path.ptr) == null) {
        return error.TempDirectoryUnavailable;
    }
    return path;
}

fn testCleanup(allocator: Allocator, path: []const u8) void {
    const contents = common.listDir(allocator, path) catch return;
    for (contents) |child| {
        const full = common.join(allocator, &.{ path, child.name }) catch continue;
        if (child.is_dir and !child.is_symlink) {
            testCleanup(allocator, full);
        } else {
            common.removeFile(full) catch {};
        }
    }
    const z = allocator.dupeZ(u8, path) catch return;
    _ = common.c.rmdir(z.ptr);
}

fn testWrite(allocator: Allocator, path: []const u8, rows: []const Value) !void {
    try common.mkdirAll(std.fs.path.dirname(path).?);
    var body = std.array_list.Managed(u8).init(allocator);
    for (rows) |row| {
        try body.appendSlice(try common.json(allocator, row));
        try body.append('\n');
    }
    try common.atomicWrite(allocator, path, body.items);
}
test "OMP discovery native reader provenance and malformed continuation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const home = try testDirectory(allocator);
    defer testCleanup(allocator, home);
    const entries = [_]Value{
        try fixtureEntry(allocator, "user", jsonString("Original question")),
        try fixtureEntry(allocator, "assistant", jsonString("Original answer")),
    };
    const converted = try omp.convert(allocator, fixture(), &entries, .{});
    const path = try omp.targetPath(allocator, fixture(), home);
    try testWrite(allocator, path, converted.entries);
    const threads = try omp.listThreads(allocator, home);
    try std.testing.expectEqual(@as(usize, 1), threads.len);
    try std.testing.expectEqualStrings("omp", threads[0].provider);
    try std.testing.expect(threads[0].unchanged_import);
    try std.testing.expectEqualStrings("claude", threads[0].origin_provider.?);
    var warnings = common.Warnings.init(allocator);
    const visible = try omp.readEntries(allocator, threads[0], &warnings);
    try std.testing.expectEqual(@as(usize, 2), visible.len);
    const answer = common.get(visible[1], "message");
    const content = common.list(common.get(answer, "content"));
    try std.testing.expectEqualStrings("Original answer", common.stringField(content[0], "text"));
    const before = try common.readFile(allocator, path);
    try common.atomicWrite(allocator, path, try common.fmt(allocator, "{s}{{", .{before}));
    const origin = try omp.readOrigin(allocator, threads[0]);
    try std.testing.expect(origin.id != null);
    try std.testing.expect(!origin.unchanged);
}
test "OMP branch tree excludes siblings and resolves content-addressed image bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const home = try testDirectory(allocator);
    defer testCleanup(allocator, home);
    const entries = [_]Value{
        try fixtureEntry(allocator, "user", jsonString("Root question")),
        try fixtureEntry(allocator, "assistant", jsonString("Abandoned sibling")),
    };
    const converted = try omp.convert(allocator, fixture(), &entries, .{});
    var rows = Values.init(allocator);
    try rows.appendSlice(converted.entries);
    const bytes = "synthetic image bytes";
    const hash = try common.sha256(allocator, bytes);
    try common.mkdirAll(try common.join(allocator, &.{ home, "blobs" }));
    try common.writeExclusive(try common.join(allocator, &.{ home, "blobs", hash }), bytes);
    const reference = try common.fmt(allocator, "blob:sha256:{s}", .{hash});
    const image = try common.obj(allocator, &.{
        .{ "type", jsonString("image") },
        .{ "data", jsonString(reference) },
        .{ "mimeType", jsonString("image/png") },
    });
    const branch_message = try common.obj(allocator, &.{
        .{ "role", jsonString("user") },
        .{ "content", try common.arr(allocator, &.{image}) },
        .{ "timestamp", jsonInteger(try common.timestampMillis(fixture().updated_at)) },
    });
    const branch = try common.obj(allocator, &.{
        .{ "type", jsonString("message") },
        .{ "id", jsonString("selected-branch") },
        .{ "parentId", jsonString(common.stringField(converted.entries[2], "id")) },
        .{ "timestamp", jsonString(fixture().updated_at) },
        .{ "message", branch_message },
    });
    try rows.append(branch);
    const path = try omp.targetPath(allocator, fixture(), home);
    try testWrite(allocator, path, rows.items);
    var thread = fixture();
    thread.rollout_path = path;
    thread.provider = "omp";
    var warnings = common.Warnings.init(allocator);
    const visible = try omp.readEntries(allocator, thread, &warnings);
    try std.testing.expectEqual(@as(usize, 2), visible.len);
    const transcript = try common.arr(allocator, visible);
    const encoded_transcript = try common.json(allocator, transcript);
    try std.testing.expect(std.mem.indexOf(u8, encoded_transcript, "Abandoned sibling") == null);
    const message = common.get(visible[1], "message");
    const content = common.list(common.get(message, "content"));
    const source = common.get(content[0], "source");
    const encoder = std.base64.standard.Encoder;
    const encoded = try allocator.alloc(u8, encoder.calcSize(bytes.len));
    _ = encoder.encode(encoded, bytes);
    try std.testing.expectEqualStrings(encoded, common.stringField(source, "data"));
}
test "OMP compaction retained tail follows canonical summary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const home = try testDirectory(allocator);
    defer testCleanup(allocator, home);
    const entries = [_]Value{
        try fixtureEntry(allocator, "user", jsonString("Archived request")),
        try fixtureEntry(allocator, "assistant", jsonString("Archived answer")),
        try fixtureEntry(allocator, "user", jsonString("Retained request")),
        try fixtureEntry(allocator, "assistant", jsonString("Retained answer")),
    };
    const converted = try omp.convert(allocator, fixture(), &entries, .{});
    var rows = Values.init(allocator);
    try rows.appendSlice(converted.entries);
    const compaction = try common.obj(allocator, &.{
        .{ "type", jsonString("compaction") },
        .{ "id", jsonString("latest-compact") },
        .{ "parentId", jsonString(common.stringField(rows.items[rows.items.len - 1], "id")) },
        .{ "timestamp", jsonString(fixture().updated_at) },
        .{ "summary", jsonString("Readable saved summary") },
        .{ "firstKeptEntryId", jsonString(common.stringField(rows.items[4], "id")) },
        .{ "tokensBefore", jsonInteger(500) },
    });
    try rows.append(compaction);
    const path = try omp.targetPath(allocator, fixture(), home);
    try testWrite(allocator, path, rows.items);
    var thread = fixture();
    thread.rollout_path = path;
    var warnings = common.Warnings.init(allocator);
    const visible = try omp.readEntries(allocator, thread, &warnings);
    try std.testing.expectEqual(@as(usize, 6), visible.len);
    try std.testing.expectEqualStrings("compact_boundary", common.stringField(visible[2], "subtype"));
    try std.testing.expect(common.boolValue(common.get(visible[3], "isCompactSummary")));
    const request = common.get(visible[4], "message");
    const content = common.list(common.get(request, "content"));
    try std.testing.expectEqualStrings("Retained request", common.stringField(content[0], "text"));
}

test "OMP bounded mixed user result never splits native tool pairs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const huge = try allocator.alloc(u8, 250_000);
    @memset(huge, 'x');
    const call = try common.parse(allocator,
        \\[{"type":"tool_use","id":"a","name":"Bash","input":{"command":"pwd"}}]
    );
    const result = try common.parse(allocator,
        \\[
        \\  {
        \\    "type": "text",
        \\    "text": "interleaved tool feedback"
        \\  },
        \\  {
        \\    "type": "tool_result",
        \\    "tool_use_id": "a",
        \\    "content": "/tmp"
        \\  }
        \\]
    );
    const entries = [_]Value{
        try fixtureEntry(allocator, "user", jsonString(huge)),
        try fixtureEntry(allocator, "assistant", call),
        try fixtureEntry(allocator, "user", result),
        try fixtureEntry(allocator, "assistant", jsonString("Newest final answer")),
    };
    const converted = try omp.convert(allocator, fixture(), &entries, .{});
    try std.testing.expectEqual(@as(usize, 0), (try omp.validate(allocator, converted.entries)).len);
    try std.testing.expect(try format.activeBytes(allocator, converted.entries) < format.max_active_bytes);
    const active = try format.activeRows(allocator, converted.entries);
    const active_context = try common.arr(allocator, active);
    const encoded_context = try common.json(allocator, active_context);
    try std.testing.expect(std.mem.indexOf(u8, encoded_context, "Newest final answer") != null);
    for (active) |row| {
        try std.testing.expect(!common.eq(common.stringField(common.get(row, "message"), "role"), "toolResult"));
    }
}
test "OMP bounds JSON escaped excerpts and summary-only context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const escaped = try allocator.alloc(u8, 100_000);
    @memset(escaped, 0);
    const entries = [_]Value{
        try fixtureEntry(allocator, "user", jsonString(escaped)),
        try fixtureEntry(allocator, "assistant", jsonString(escaped)),
    };
    const converted = try omp.convert(allocator, fixture(), &entries, .{});
    try std.testing.expect(try format.activeBytes(allocator, converted.entries) < format.max_active_bytes);
    var summary = try fixtureEntry(allocator, "user", jsonString(escaped));
    try common.set(allocator, &summary, "isCompactSummary", common.boolean(true));
    const compact = try omp.convert(allocator, fixture(), &.{summary}, .{});
    try std.testing.expect(try format.activeBytes(allocator, compact.entries) < format.max_active_bytes);
    try std.testing.expect(compact.warnings.len > 0);
}
test "OMP provenance normalizes title slot and verified image blob rewrites" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const home = try testDirectory(allocator);
    defer testCleanup(allocator, home);
    const bytes = "synthetic image payload";
    const hash = try common.sha256(allocator, bytes);
    const encoder = std.base64.standard.Encoder;
    const encoded = try allocator.alloc(u8, encoder.calcSize(bytes.len));
    _ = encoder.encode(encoded, bytes);
    const source = try common.obj(allocator, &.{
        .{ "type", jsonString("base64") },
        .{ "media_type", jsonString("image/png") },
        .{ "data", jsonString(encoded) },
    });
    const image = try common.obj(allocator, &.{
        .{ "type", jsonString("image") },
        .{ "source", source },
    });
    const image_content = try common.arr(allocator, &.{image});
    const entries = [_]Value{
        try fixtureEntry(allocator, "user", image_content),
        try fixtureEntry(allocator, "assistant", jsonString("Visible answer")),
    };
    const converted = try omp.convert(allocator, fixture(), &entries, .{});
    var rows = Values.init(allocator);
    const title = try common.obj(allocator, &.{
        .{ "type", jsonString("title") },
        .{ "v", jsonInteger(1) },
        .{ "title", jsonString(fixture().title) },
        .{ "source", jsonString("user") },
        .{ "updatedAt", jsonString(fixture().created_at) },
        .{ "pad", jsonString("") },
    });
    try rows.append(title);
    for (converted.entries) |row| {
        const copy = try common.clone(allocator, row);
        try rows.append(copy);
    }
    const message = common.get(rows.items[3], "message");
    const parts = common.get(message, "content");
    const reference = try common.fmt(allocator, "blob:sha256:{s}", .{hash});
    try common.set(allocator, &parts.array.items[0], "data", jsonString(reference));
    try common.mkdirAll(try common.join(allocator, &.{ home, "blobs" }));
    const blob = try common.join(allocator, &.{ home, "blobs", hash });
    try common.writeExclusive(blob, bytes);
    const path = try omp.targetPath(allocator, fixture(), home);
    try testWrite(allocator, path, rows.items);
    var thread = fixture();
    thread.rollout_path = path;
    try std.testing.expect((try omp.readOrigin(allocator, thread)).unchanged);
    try common.atomicWrite(allocator, blob, "changed bytes");
    try std.testing.expect(!(try omp.readOrigin(allocator, thread)).unchanged);
}
test "OMP provider snapshot keeps readable tail after replay-through entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const home = try testDirectory(allocator);
    defer testCleanup(allocator, home);
    const entries = [_]Value{
        try fixtureEntry(allocator, "user", jsonString("Archived")),
        try fixtureEntry(allocator, "assistant", jsonString("Snapshot through here")),
        try fixtureEntry(allocator, "user", jsonString("Retained since snapshot")),
        try fixtureEntry(allocator, "assistant", jsonString("Recent answer")),
    };
    const converted = try omp.convert(allocator, fixture(), &entries, .{});
    var rows = Values.init(allocator);
    try rows.appendSlice(converted.entries);
    const snapshot = try common.obj(allocator, &.{
        .{ "type", jsonString("compaction") },
        .{ "id", jsonString("native-snapshot") },
        .{ "parentId", jsonString(common.stringField(rows.items[rows.items.len - 1], "id")) },
        .{ "timestamp", jsonString(fixture().updated_at) },
        .{ "summary", jsonString("Readable summary") },
        .{ "firstKeptEntryId", jsonString("") },
        .{ "providerReplayThroughEntryId", jsonString(common.stringField(rows.items[3], "id")) },
        .{ "tokensBefore", jsonInteger(500) },
        .{ "preserveData", try common.obj(allocator, &.{}) },
    });
    try rows.append(snapshot);
    const path = try omp.targetPath(allocator, fixture(), home);
    try testWrite(allocator, path, rows.items);
    var thread = fixture();
    thread.rollout_path = path;
    var warnings = common.Warnings.init(allocator);
    const visible = try omp.readEntries(allocator, thread, &warnings);
    try std.testing.expectEqualStrings("compact_boundary", common.stringField(visible[2], "subtype"));
    const request = common.get(visible[4], "message");
    const content = common.list(common.get(request, "content"));
    try std.testing.expectEqualStrings("Retained since snapshot", common.stringField(content[0], "text"));
}

test "OMP provenance accepts only one valid physical title slot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const home = try testDirectory(allocator);
    defer testCleanup(allocator, home);
    const entries = [_]Value{
        try fixtureEntry(allocator, "user", jsonString("Question")),
        try fixtureEntry(allocator, "assistant", jsonString("Answer")),
    };
    const converted = try omp.convert(allocator, fixture(), &entries, .{});
    const path = try omp.targetPath(allocator, fixture(), home);
    try testWrite(allocator, path, converted.entries);
    const original = try common.readFile(allocator, path);
    var thread = fixture();
    thread.rollout_path = path;
    try common.atomicWrite(allocator, path, try common.fmt(allocator, "{{\"type\":\"title\",\"v\":1}}\n{s}", .{original}));
    try std.testing.expect(!(try omp.readOrigin(allocator, thread)).unchanged);
    const slot = "{\"type\":\"title\",\"v\":1,\"title\":\"x\"," ++
        "\"updatedAt\":\"2026-10-06T00:00:00.000Z\",\"pad\":\"\"}\n";
    try common.atomicWrite(allocator, path, try common.fmt(allocator, "{s}{s}{s}", .{ slot, slot, original }));
    try std.testing.expect(!(try omp.readOrigin(allocator, thread)).unchanged);
}

test "OMP standalone native shell history is discoverable and paired" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const home = try testDirectory(allocator);
    defer testCleanup(allocator, home);
    const header = try common.obj(allocator, &.{
        .{ "type", jsonString("session") },
        .{ "version", jsonInteger(3) },
        .{ "id", jsonString("standalone-shell") },
        .{ "timestamp", jsonString(fixture().created_at) },
        .{ "cwd", jsonString(fixture().cwd) },
    });
    const shell = try common.obj(allocator, &.{
        .{ "role", jsonString("bashExecution") },
        .{ "command", jsonString("pwd") },
        .{ "output", jsonString("/tmp") },
        .{ "exitCode", jsonInteger(0) },
    });
    const native = try common.obj(allocator, &.{
        .{ "type", jsonString("message") },
        .{ "id", jsonString("shell") },
        .{ "parentId", .null },
        .{ "timestamp", jsonString(fixture().updated_at) },
        .{ "message", shell },
    });
    const path = try common.join(allocator, &.{ home, "sessions", "fixture", "shell.jsonl" });
    try testWrite(allocator, path, &.{ header, native });
    const threads = try omp.listThreads(allocator, home);
    try std.testing.expectEqual(@as(usize, 1), threads.len);
    var warnings = common.Warnings.init(allocator);
    const visible = try omp.readEntries(allocator, threads[0], &warnings);
    try std.testing.expectEqual(@as(usize, 2), visible.len);
    const call_message = common.get(visible[0], "message");
    const result_message = common.get(visible[1], "message");
    const call = common.list(common.get(call_message, "content"))[0];
    const result = common.list(common.get(result_message, "content"))[0];
    try std.testing.expectEqualStrings(common.stringField(call, "id"), common.stringField(result, "tool_use_id"));
}
