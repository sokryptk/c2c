const std = @import("std");
const common = @import("../common.zig");
const A = common.Allocator;
const V = common.Value;
const str = common.str;
const obj = common.obj;
const arr = common.arr;
const get = common.get;
const s = common.s;
const eq = common.eq;
const list = common.list;
const nullv: V = .null;
const native = @import("native.zig");
const containsBlock = native.containsBlock;
const textBlock = native.textBlock;
const adapter = @import("../claude.zig");
const sessionId = adapter.sessionId;
const projectDirectory = adapter.projectDirectory;
const convert = adapter.convert;
const convertEntries = adapter.convertEntries;
const listThreads = adapter.listThreads;
const readEntries = adapter.readEntries;
const validate = adapter.validate;
const activeBytes = adapter.activeBytes;
const max_active_bytes = adapter.max_active_bytes;
const canonicalEntries = @import("history.zig").canonicalEntries;
const activeStart = @import("checkpoints.zig").activeStart;
const attachments = @import("attachments.zig");
const imageBlock = attachments.imageBlock;
const attachmentBlocks = attachments.attachmentBlocks;
const toolResultBlocks = attachments.toolResultBlocks;

const stamp = "2026-10-06T00:00:00.000Z";
fn fixtureThread() common.Thread {
    return .{ .id = "fixture-thread-1", .title = "Original title", .cwd = "/tmp/c2c-fixture", .created_at = stamp, .updated_at = stamp, .rollout_path = "/tmp/no-personal-transcripts" };
}
fn fixtureItem(role: []const u8, text: []const u8, ordinal: i64) common.Item {
    return .{ .id = "fixture", .role = role, .text = text, .timestamp = stamp, .kind = if (eq(role, "user")) "userMessage" else "agentMessage", .ordinal = ordinal };
}
fn fixtureMessage(a: A, id: []const u8, parent: ?[]const u8, role: []const u8, content: V) !V {
    return obj(a, &.{ .{ "uuid", str(id) }, .{ "parentUuid", if (parent) |p| str(p) else nullv }, .{ "type", str(role) }, .{ "message", try obj(a, &.{ .{ "role", str(role) }, .{ "content", content } }) } });
}
test "Claude canonical export selects branch and bridges compaction while stripping hidden blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var warnings = common.Warnings.init(a);
    const records = [_]V{
        try fixtureMessage(a, "root", null, "user", str("Original prompt")),
        try fixtureMessage(a, "old", "root", "assistant", str("Abandoned answer")),
        try fixtureMessage(a, "selected", "root", "assistant", try arr(a, &.{ try textBlock(a, "Selected answer"), try obj(a, &.{ .{ "type", str("thinking") }, .{ "thinking", str("hidden-secret") } }) })),
        try obj(a, &.{ .{ "uuid", str("boundary") }, .{ "parentUuid", .null }, .{ "logicalParentUuid", str("selected") }, .{ "type", str("system") }, .{ "subtype", str("compact_boundary") } }),
        try fixtureMessage(a, "summary", "boundary", "user", str("Saved summary")),
    };
    const exported = try canonicalEntries(a, &records, false, &warnings);
    try std.testing.expectEqual(@as(usize, 4), exported.len);
    try std.testing.expectEqualStrings("selected", s(exported[1], "uuid"));
    const serialized = try common.json(a, try arr(a, exported));
    try std.testing.expect(std.mem.indexOf(u8, serialized, "Abandoned") == null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "hidden-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "Saved summary") != null);
}
test "Claude canonical cycles fail explicitly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var warnings = common.Warnings.init(a);
    const records = [_]V{ try fixtureMessage(a, "one", "two", "user", str("one")), try fixtureMessage(a, "two", "one", "assistant", str("two")) };
    try std.testing.expectError(error.InvalidClaudeParentChain, canonicalEntries(a, &records, false, &warnings));
}
test "Claude UUIDs and native UTF16 project mapping are stable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(try sessionId(a, "fixture"), try sessionId(a, "fixture"));
    try std.testing.expectEqualStrings("-home-me-a-project-v2", try projectDirectory(a, "/home/me/a_project.v2"));
    try std.testing.expectEqualStrings("-tmp---", try projectDirectory(a, "/tmp/😀"));
    const long = try common.fmt(a, "/{s}😀", .{"a" ** 198});
    try std.testing.expectEqualStrings("-" ++ "a" ** 198 ++ "--b5wpam", try projectDirectory(a, long));
}
test "Claude tools are completed pairs with stable identifiers and preserve artifacts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var command = fixtureItem("assistant", "", 1);
    command.kind = "commandExecution";
    command.raw = try common.parse(a, "{\"command\":\"fixture-only\",\"aggregatedOutput\":\"original output\",\"status\":\"inProgress\"}");
    var mcp = fixtureItem("assistant", "", 2);
    mcp.kind = "mcpToolCall";
    mcp.raw = try common.parse(a, "{\"server\":\"old.server\",\"tool\":\"lookup/item\",\"arguments\":{\"x\":2},\"status\":\"completed\",\"result\":{\"isError\":true,\"value\":\"original result\"}}");
    const items = [_]common.Item{ fixtureItem("user", "Inspect", 0), command, mcp };
    const result = try convert(a, fixtureThread(), &items, null, .{});
    try std.testing.expectEqual(@as(usize, 2), result.tool_count);
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, result.entries)).len);
    const serialized = try common.json(a, try arr(a, result.entries));
    try std.testing.expect(std.mem.indexOf(u8, serialized, "not resumed or executed") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "mcp__old_server__lookup_item") != null);
    try std.testing.expectEqualStrings(s(list(get(get(result.entries[1], "message"), "content"))[0], "id"), s(list(get(get(result.entries[2], "message"), "content"))[0], "tool_use_id"));
    try std.testing.expect(common.b(get(list(get(get(result.entries[4], "message"), "content"))[0], "is_error")));
    var broken = try common.clone(a, try arr(a, result.entries));
    try common.set(a, &broken.array.items[1], "parentUuid", str("missing-parent"));
    try std.testing.expect((try validate(a, broken.array.items)).len > 0);
}
test "Claude checkpoint preserves unicode archive and regenerates tool IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var large = std.array_list.Managed(u8).init(a);
    for (0..16000) |_| try large.appendSlice("पूर्ण मूल इतिहास ");
    var command = fixtureItem("assistant", "", 1);
    command.kind = "commandExecution";
    command.raw = try common.parse(a, "{\"command\":\"echo latest-fixture\",\"status\":\"completed\",\"aggregatedOutput\":\"latest-fixture\",\"exitCode\":0}");
    const result = try convert(a, fixtureThread(), &.{ fixtureItem("user", large.items, 0), command }, null, .{ .transcript_path = "/tmp/c2c-synthetic-native.jsonl" });
    try std.testing.expectEqualStrings(large.items, s(list(get(get(result.entries[0], "message"), "content"))[0], "text"));
    try std.testing.expect(try activeBytes(a, result.entries) <= max_active_bytes);
    try std.testing.expect(activeStart(result.entries) > 0);
    const active = try common.json(a, try arr(a, result.entries[activeStart(result.entries)..]));
    try std.testing.expect(std.mem.indexOf(u8, active, "structural migration checkpoint") != null);
    try std.testing.expect(std.mem.indexOf(u8, active, "latest-fixture") != null);
    try std.testing.expect(std.mem.indexOf(u8, active, "abridged") != null);
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, result.entries)).len);
}
test "Claude image-heavy checkpoints budget actual assistant envelopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoded = try a.alloc(u8, 28000);
    @memset(encoded, 'A');
    var items = std.array_list.Managed(common.Item).init(a);
    try items.append(fixtureItem("user", "Synthetic image archive", 0));
    const raw = try obj(a, &.{
        .{ "server", str("fixture") },                                                                                                                                                                                                                               .{ "tool", str("image") }, .{ "arguments", try obj(a, &.{}) }, .{ "status", str("completed") },
        .{ "result", try obj(a, &.{ .{ "content", try arr(a, &.{try obj(a, &.{ .{ "type", str("image") }, .{ "data", str(encoded) }, .{ "mimeType", str("image/png") } })}) }, .{ "structuredContent", try obj(a, &.{.{ "preserve", common.boolean(true) }}) } }) },
    });
    for (1..901) |ordinal| {
        var item = fixtureItem("assistant", "", @intCast(ordinal));
        item.kind = "mcpToolCall";
        item.raw = raw;
        try items.append(item);
    }
    const summary = try a.alloc(u8, 40000);
    @memset(summary, 's');
    const result = try convert(a, fixtureThread(), items.items, .{ .summary = summary, .timestamp = stamp, .ordinal = -1 }, .{});
    try std.testing.expect(try activeBytes(a, result.entries) <= max_active_bytes);
    try std.testing.expectEqual(@as(usize, 900), result.tool_count);
    var originals: usize = 0;
    for (result.entries) |entry| if (containsBlock(get(get(entry, "message"), "content"), "tool_result")) {
        originals += 1;
    };
    try std.testing.expectEqual(@as(usize, 900), originals);
}

test "Claude recovered images outrank missing paths and retain MCP metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j3ioAAAAASUVORK5CYII=";
    const attachment = try obj(a, &.{ .{ "path", str("/tmp/nonexistent-c2c-fixture-image.png") }, .{ "url", str("data:image/png;base64," ++ png) } });
    var item = fixtureItem("user", "Inspect image", 0);
    item.attachments = &.{attachment};
    const result = try convert(a, fixtureThread(), &.{item}, null, .{});
    const blocks = list(get(get(result.entries[0], "message"), "content"));
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    try std.testing.expectEqualStrings(png, s(get(blocks[2], "source"), "data"));
    try std.testing.expectEqual(@as(usize, 0), result.warnings.len);
    const omitted = try convert(a, fixtureThread(), &.{item}, null, .{ .embed_images = false });
    try std.testing.expect(!containsBlock(get(get(omitted.entries[0], "message"), "content"), "image"));
    var warnings = common.Warnings.init(a);
    const remote = try attachmentBlocks(a, &.{try obj(a, &.{.{ "url", str("https://example.invalid/private.png") }})}, &warnings, true);
    try std.testing.expectEqualStrings("Attachment URL: https://example.invalid/private.png", s(remote[0], "text"));
    const output = try toolResultBlocks(a, try obj(a, &.{
        .{ "content", try arr(a, &.{try obj(a, &.{ .{ "type", str("image") }, .{ "data", str(png) }, .{ "mimeType", str("image/png") } })}) },
        .{ "structuredContent", try obj(a, &.{.{ "calories", common.num(123) }}) },
    }), &warnings, true);
    try std.testing.expectEqualStrings(png, s(get(list(output)[0], "source"), "data"));
    try std.testing.expect(std.mem.indexOf(u8, s(list(output)[1], "text"), "calories") != null);
}

test "Claude source summary preserves original archive and omits hidden reasoning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var hidden = fixtureItem("assistant", "hidden-private-fixture", 1);
    hidden.kind = "reasoning";
    const result = try convert(a, fixtureThread(), &.{ fixtureItem("user", "Old original message", 0), hidden, fixtureItem("assistant", "Recent original answer", 3) }, .{ .summary = "Exact saved summary", .timestamp = stamp, .ordinal = 2, .encrypted = true }, .{});
    const full = try common.json(a, try arr(a, result.entries));
    const active = try common.json(a, try arr(a, result.entries[activeStart(result.entries)..]));
    try std.testing.expect(std.mem.indexOf(u8, full, "Old original message") != null);
    try std.testing.expect(std.mem.indexOf(u8, full, "hidden-private-fixture") == null);
    try std.testing.expect(std.mem.indexOf(u8, active, "Old original message") == null);
    try std.testing.expect(std.mem.indexOf(u8, active, "Exact saved summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, active, "Recent original answer") != null);
    try std.testing.expectEqual(@as(usize, 1), result.warnings.len);
}

test "Claude discovery reads metadata without mutation and skips unchanged provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var template = "/tmp/c2c-claude-test-XXXXXX".*;
    if (common.c.mkdtemp(&template) == null) return error.TestTempDirectory;
    defer _ = common.c.rmdir(&template);
    const projects = try common.join(a, &.{ &template, "projects" });
    try common.mkdirAll(projects);
    const projects_z = try a.dupeZ(u8, projects);
    defer _ = common.c.rmdir(projects_z.ptr);
    const storage = try common.join(a, &.{ projects, "-synthetic-project" });
    try common.mkdirAll(storage);
    const storage_z = try a.dupeZ(u8, storage);
    defer _ = common.c.rmdir(storage_z.ptr);
    const path = try common.join(a, &.{ storage, "966e523c-70cc-4df2-bdcd-e0b17c918d3c.jsonl" });
    defer common.removeFile(path) catch {};
    const first = "{\"type\":\"user\",\"uuid\":\"u1\",\"parentUuid\":null,\"sessionId\":\"966e523c-70cc-4df2-bdcd-e0b17c918d3c\",\"isSidechain\":false,\"timestamp\":\"2026-10-06T00:00:00.000Z\",\"cwd\":\"/tmp/c2c-fixture\",\"message\":{\"role\":\"user\",\"content\":\"Original prompt\"}}\n";
    const marker = "{\"type\":\"c2c-import\",\"source\":\"codex\",\"sourceThreadId\":\"original-codex\",\"lastMessageUuid\":\"u1\"}\n";
    const continued = "{\"type\":\"assistant\",\"uuid\":\"a1\",\"parentUuid\":\"u1\",\"timestamp\":\"2026-10-06T01:00:00.000Z\",\"cwd\":\"/tmp/c2c-fixture\",\"message\":{\"role\":\"assistant\",\"content\":\"Continued in Claude\"}}\n";
    try common.writeExclusive(path, first ++ marker);
    try std.testing.expectEqual(@as(usize, 0), (try listThreads(a, &template, .{})).len);
    const inventory = try listThreads(a, &template, .{ .include_imported = true });
    try std.testing.expectEqual(@as(usize, 1), inventory.len);
    try std.testing.expect(inventory[0].unchanged_import);
    try std.testing.expectEqualStrings("original-codex", inventory[0].original_codex_id.?);
    try std.testing.expectEqualStrings(first ++ marker, try common.readFile(a, path));
    try common.atomicWrite(a, path, first ++ marker ++ continued);
    const threads = try listThreads(a, &template, .{});
    try std.testing.expectEqual(@as(usize, 1), threads.len);
    try std.testing.expect(!threads[0].unchanged_import);
    try std.testing.expectEqualStrings("Original prompt", threads[0].title);
    var warnings = common.Warnings.init(a);
    try std.testing.expectEqual(@as(usize, 2), (try readEntries(a, threads[0], &warnings)).len);
    const generic_marker = "{\"type\":\"c2c-import\",\"source\":\"opencode\",\"sourceThreadId\":\"original-opencode\",\"lastMessageUuid\":\"u1\"}\n";
    try common.atomicWrite(a, path, first ++ generic_marker);
    const generic = try listThreads(a, &template, .{ .include_imported = true });
    try std.testing.expectEqualStrings("claude", generic[0].provider);
    try std.testing.expectEqualStrings("opencode", generic[0].origin_provider.?);
    try std.testing.expectEqualStrings("original-opencode", generic[0].origin_id.?);
    try std.testing.expect(generic[0].original_codex_id == null);
    try std.testing.expect(generic[0].unchanged_import);
}

test "Claude canonical adapter preserves native tool image and compaction content with generic provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j3ioAAAAASUVORK5CYII=";
    var summary = try fixtureMessage(a, "summary", "boundary", "user", str("Exact source summary"));
    try common.set(a, &summary, "isCompactSummary", common.boolean(true));
    const entries = [_]V{
        try fixtureMessage(a, "u1", null, "user", str("Inspect this")),
        try fixtureMessage(a, "a1", "u1", "assistant", try arr(a, &.{try obj(a, &.{ .{ "type", str("tool_use") }, .{ "id", str("source_tool") }, .{ "name", str("inspect") }, .{ "input", try obj(a, &.{.{ "value", common.num(2) }}) } })})),
        try fixtureMessage(a, "r1", "a1", "user", try arr(a, &.{try obj(a, &.{ .{ "type", str("tool_result") }, .{ "tool_use_id", str("source_tool") }, .{ "content", try arr(a, &.{ try imageBlock(a, "image/png", png), try textBlock(a, "Exact result") }) }, .{ "is_error", common.boolean(false) } })})),
        try obj(a, &.{ .{ "type", str("system") }, .{ "subtype", str("compact_boundary") } }),
        summary,
        try fixtureMessage(a, "recent", "summary", "user", str("Continue the task")),
    };
    const result = try convertEntries(a, fixtureThread(), &entries, .{ .source_provider = "opencode", .source_session_id = "source-opencode-1" });
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, result.entries)).len);
    try std.testing.expectEqual(@as(usize, 1), result.tool_count);
    try std.testing.expectEqualStrings("opencode", s(result.entries[result.entries.len - 2], "source"));
    try std.testing.expectEqualStrings("source-opencode-1", s(result.entries[result.entries.len - 2], "sourceThreadId"));
    try std.testing.expectEqualStrings("OpenCode · Original title", s(result.entries[result.entries.len - 1], "customTitle"));
    try std.testing.expectEqualStrings(png, s(get(list(get(list(get(get(result.entries[2], "message"), "content"))[0], "content"))[0], "source"), "data"));
    const active = try common.json(a, try arr(a, result.entries[activeStart(result.entries)..]));
    try std.testing.expect(std.mem.indexOf(u8, active, "Exact source summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, active, "Inspect this") == null);
    const different_source = try convertEntries(a, fixtureThread(), &entries, .{ .source_provider = "omp", .source_session_id = "source-opencode-1" });
    try std.testing.expect(!eq(result.session_id, different_source.session_id));
}

test "Claude canonical unfinished tools become disclosed closed historical exchanges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const call = try fixtureMessage(a, "call", null, "assistant", try arr(a, &.{try obj(a, &.{ .{ "type", str("tool_use") }, .{ "id", str("pending") }, .{ "name", str("Bash") }, .{ "input", try obj(a, &.{.{ "command", str("never-run-this-history") }}) } })}));
    const result = try convertEntries(a, fixtureThread(), &.{call}, .{ .source_provider = "omp" });
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, result.entries)).len);
    try std.testing.expectEqual(@as(usize, 1), result.warnings.len);
    const serialized = try common.json(a, try arr(a, result.entries));
    try std.testing.expect(std.mem.indexOf(u8, serialized, "was not run by this import") != null);
}

fn rawFixture(a: A, kind: []const u8, json: []const u8, ordinal: i64) !common.Item {
    var item = fixtureItem("tool", "", ordinal);
    item.kind = kind;
    item.raw = try common.parse(a, json);
    return item;
}
test "Raw Codex function calls become exact structured native pairs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = [_]common.Item{
        fixtureItem("user", "Inspect without execution", 0),
        try rawFixture(a, "function_call", "{\"call_id\":\"fixture_tool\",\"name\":\"mcp__fixture__inspect\",\"arguments\":\"{\\\"path\\\":\\\"synthetic-never-executed\\\"}\"}", 1),
        try rawFixture(a, "function_call_output", "{\"call_id\":\"fixture_tool\",\"output\":\"MATRIX_TOOL_RESULT: synthetic record found.\"}", 2),
        fixtureItem("assistant", "Done", 3),
    };
    const converted = try convert(a, fixtureThread(), &items, null, .{});
    try std.testing.expectEqual(@as(usize, 1), converted.tool_count);
    const call = list(get(get(converted.entries[1], "message"), "content"))[0];
    const result = list(get(get(converted.entries[2], "message"), "content"))[0];
    try std.testing.expectEqualStrings("tool_use", s(call, "type"));
    try std.testing.expectEqualStrings("mcp__fixture__inspect", s(call, "name"));
    try std.testing.expectEqualStrings("synthetic-never-executed", s(get(call, "input"), "path"));
    try std.testing.expectEqualStrings(s(call, "id"), s(result, "tool_use_id"));
    try std.testing.expectEqualStrings("MATRIX_TOOL_RESULT: synthetic record found.", s(result, "content"));
    try std.testing.expectEqual(@as(usize, 0), converted.warnings.len);
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, converted.entries)).len);
}
test "Raw parallel custom calls preserve call result order and image blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j3ioAAAAASUVORK5CYII=";
    const items = [_]common.Item{
        fixtureItem("user", "Inspect two sources", 0),
        try rawFixture(a, "custom_tool_call", "{\"call_id\":\"first\",\"name\":\"patch\",\"input\":\"exact patch text\"}", 1),
        try rawFixture(a, "function_call", "{\"call_id\":\"second\",\"name\":\"image_tool\",\"arguments\":\"{}\"}", 2),
        try rawFixture(a, "function_call_output", "{\"call_id\":\"second\",\"output\":[{\"type\":\"input_text\",\"text\":\"Original image\"},{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64," ++ png ++ "\"}]}", 3),
        try rawFixture(a, "custom_tool_call_output", "{\"call_id\":\"first\",\"output\":\"Original patch output\"}", 4),
    };
    const converted = try convert(a, fixtureThread(), &items, null, .{});
    const calls = list(get(get(converted.entries[1], "message"), "content"));
    const results = list(get(get(converted.entries[2], "message"), "content"));
    try std.testing.expectEqual(@as(usize, 2), converted.tool_count);
    try std.testing.expectEqualStrings("patch", s(calls[0], "name"));
    try std.testing.expectEqualStrings("exact patch text", s(get(calls[0], "input"), "input"));
    try std.testing.expectEqualStrings(s(calls[1], "id"), s(results[0], "tool_use_id"));
    try std.testing.expectEqualStrings(s(calls[0], "id"), s(results[1], "tool_use_id"));
    try std.testing.expectEqualStrings(png, s(get(list(get(results[0], "content"))[1], "source"), "data"));
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, converted.entries)).len);
}
test "Raw Codex unfinished calls and unmatched results retain disclosed history" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = [_]common.Item{
        fixtureItem("user", "Inspect", 0),
        try rawFixture(a, "function_call", "{\"call_id\":\"pending\",\"name\":\"inspect\",\"arguments\":\"malformed-but-retained\"}", 1),
        fixtureItem("assistant", "Visible interleaved record", 2),
        try rawFixture(a, "function_call_output", "{\"call_id\":\"pending\",\"output\":\"Exact late historical output\"}", 3),
    };
    const converted = try convert(a, fixtureThread(), &items, null, .{});
    const serialized = try common.json(a, try arr(a, converted.entries));
    try std.testing.expect(std.mem.indexOf(u8, serialized, "malformed-but-retained") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "Exact late historical output") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "was not run by this import") != null);
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, converted.entries)).len);
}
