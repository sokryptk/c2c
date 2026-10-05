const std = @import("std");
const C = @import("../common.zig");
const A = C.Allocator;
const V = C.Value;
const S = C.str;
const Values = std.array_list.Managed(V);
const N = C.num;
const F = @import("format.zig");
const omp = @import("../omp.zig");

fn fixture() C.Thread {
    return .{ .id = "source-session", .provider = "claude", .title = "OMP fixture", .cwd = "/tmp/c2c-omp-project", .created_at = "2026-10-06T00:00:00.000Z", .updated_at = "2026-10-06T00:01:00.000Z", .rollout_path = "/tmp/source.jsonl" };
}
fn fixtureEntry(a: A, role: []const u8, content: V) !V {
    return C.obj(a, &.{ .{ "type", S(role) }, .{ "uuid", S("source-message") }, .{ "timestamp", S("2026-10-06T00:00:00.000Z") }, .{ "message", try C.obj(a, &.{ .{ "role", S(role) }, .{ "content", try C.arr(a, try F.blocks(a, content)) } }) } });
}
test "OMP v3 native tool pairs images and provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const call = try C.parse(a, "[{\"type\":\"tool_use\",\"id\":\"a\",\"name\":\"Bash\",\"input\":{\"command\":\"pwd\"}}]");
    const result = try C.parse(a, "[{\"type\":\"tool_result\",\"tool_use_id\":\"a\",\"content\":\"/tmp\"}]");
    const converted = try omp.convert(a, fixture(), &.{ try fixtureEntry(a, "user", S("Question")), try fixtureEntry(a, "assistant", call), try fixtureEntry(a, "user", result), try fixtureEntry(a, "assistant", S("Done")) }, .{});
    try std.testing.expectEqual(@as(usize, 1), converted.tool_count);
    try std.testing.expectEqual(@as(usize, 0), (try omp.validate(a, converted.entries)).len);
    try std.testing.expectEqualStrings("claude", C.s(C.get(converted.entries[1], "data"), "sourceProvider"));
    try std.testing.expectEqualStrings(try F.fingerprint(a, converted.entries), C.s(C.get(converted.entries[1], "data"), "fingerprint"));
    try std.testing.expect(std.mem.indexOf(u8, try omp.targetPath(a, fixture(), "/tmp/omp-agent"), "/sessions/-tmp-c2c-omp-project/") != null);
}
test "OMP compaction preserves full archive and bounds continuation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const huge = try a.alloc(u8, 350_000);
    @memset(huge, 'x');
    const converted = try omp.convert(a, fixture(), &.{ try fixtureEntry(a, "user", S(huge)), try fixtureEntry(a, "assistant", S("Recent answer")) }, .{});
    var found = false;
    for (converted.entries) |row| if (F.is(row, "compaction")) {
        found = true;
        try std.testing.expect(C.s(row, "summary").len < 40_000);
    };
    try std.testing.expect(found);
    try std.testing.expectEqual(@as(usize, 0), (try omp.validate(a, converted.entries)).len);
    try std.testing.expect((try C.json(a, try C.arr(a, converted.entries))).len > 350_000);
}
test "OMP missing tool result is closed without executing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const call = try C.parse(a, "[{\"type\":\"tool_use\",\"id\":\"a\",\"name\":\"dangerous historical tool\",\"input\":{}}]");
    const converted = try omp.convert(a, fixture(), &.{ try fixtureEntry(a, "user", S("Question")), try fixtureEntry(a, "assistant", call) }, .{});
    try std.testing.expectEqual(@as(usize, 1), converted.tool_count);
    try std.testing.expectEqual(@as(usize, 1), converted.warnings.len);
    const last = C.get(converted.entries[converted.entries.len - 1], "message");
    try std.testing.expect(C.b(C.get(last, "isError")));
}

fn testDirectory(a: A) ![]const u8 {
    const path = try a.dupeZ(u8, "/tmp/c2c-omp-test-XXXXXX");
    if (C.c.mkdtemp(path.ptr) == null) return error.TempDirectoryUnavailable;
    return path;
}
fn testCleanup(a: A, path: []const u8) void {
    const contents = C.listDir(a, path) catch return;
    for (contents) |child| {
        const full = C.join(a, &.{ path, child.name }) catch continue;
        if (child.is_dir and !child.is_symlink) testCleanup(a, full) else C.removeFile(full) catch {};
    }
    const z = a.dupeZ(u8, path) catch return;
    _ = C.c.rmdir(z.ptr);
}
fn testWrite(a: A, path: []const u8, rows: []const V) !void {
    try C.mkdirAll(std.fs.path.dirname(path).?);
    var body = std.array_list.Managed(u8).init(a);
    for (rows) |row| {
        try body.appendSlice(try C.json(a, row));
        try body.append('\n');
    }
    try C.atomicWrite(a, path, body.items);
}
test "OMP discovery native reader provenance and malformed continuation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try testDirectory(a);
    defer testCleanup(a, home);
    const converted = try omp.convert(a, fixture(), &.{ try fixtureEntry(a, "user", S("Original question")), try fixtureEntry(a, "assistant", S("Original answer")) }, .{});
    const path = try omp.targetPath(a, fixture(), home);
    try testWrite(a, path, converted.entries);
    const threads = try omp.listThreads(a, home);
    try std.testing.expectEqual(@as(usize, 1), threads.len);
    try std.testing.expectEqualStrings("omp", threads[0].provider);
    try std.testing.expect(threads[0].unchanged_import);
    try std.testing.expectEqualStrings("claude", threads[0].origin_provider.?);
    var warnings = C.Warnings.init(a);
    const visible = try omp.readEntries(a, threads[0], &warnings);
    try std.testing.expectEqual(@as(usize, 2), visible.len);
    try std.testing.expectEqualStrings("Original answer", C.s(C.list(C.get(C.get(visible[1], "message"), "content"))[0], "text"));
    const before = try C.readFile(a, path);
    try C.atomicWrite(a, path, try C.fmt(a, "{s}{{", .{before}));
    const origin = try omp.readOrigin(a, threads[0]);
    try std.testing.expect(origin.id != null);
    try std.testing.expect(!origin.unchanged);
}
test "OMP branch tree excludes siblings and resolves content-addressed image bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try testDirectory(a);
    defer testCleanup(a, home);
    const converted = try omp.convert(a, fixture(), &.{ try fixtureEntry(a, "user", S("Root question")), try fixtureEntry(a, "assistant", S("Abandoned sibling")) }, .{});
    var rows = Values.init(a);
    try rows.appendSlice(converted.entries);
    const bytes = "synthetic image bytes";
    const hash = try C.sha256(a, bytes);
    try C.mkdirAll(try C.join(a, &.{ home, "blobs" }));
    try C.writeExclusive(try C.join(a, &.{ home, "blobs", hash }), bytes);
    const image = try C.obj(a, &.{ .{ "type", S("image") }, .{ "data", S(try C.fmt(a, "blob:sha256:{s}", .{hash})) }, .{ "mimeType", S("image/png") } });
    try rows.append(try C.obj(a, &.{ .{ "type", S("message") }, .{ "id", S("selected-branch") }, .{ "parentId", S(C.s(converted.entries[2], "id")) }, .{ "timestamp", S(fixture().updated_at) }, .{ "message", try C.obj(a, &.{ .{ "role", S("user") }, .{ "content", try C.arr(a, &.{image}) }, .{ "timestamp", N(try C.timestampMillis(fixture().updated_at)) } }) } }));
    const path = try omp.targetPath(a, fixture(), home);
    try testWrite(a, path, rows.items);
    var thread = fixture();
    thread.rollout_path = path;
    thread.provider = "omp";
    var warnings = C.Warnings.init(a);
    const visible = try omp.readEntries(a, thread, &warnings);
    try std.testing.expectEqual(@as(usize, 2), visible.len);
    try std.testing.expect(std.mem.indexOf(u8, try C.json(a, try C.arr(a, visible)), "Abandoned sibling") == null);
    const source = C.get(C.list(C.get(C.get(visible[1], "message"), "content"))[0], "source");
    const encoder = std.base64.standard.Encoder;
    const encoded = try a.alloc(u8, encoder.calcSize(bytes.len));
    _ = encoder.encode(encoded, bytes);
    try std.testing.expectEqualStrings(encoded, C.s(source, "data"));
}
test "OMP compaction retained tail follows canonical summary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try testDirectory(a);
    defer testCleanup(a, home);
    const converted = try omp.convert(a, fixture(), &.{ try fixtureEntry(a, "user", S("Archived request")), try fixtureEntry(a, "assistant", S("Archived answer")), try fixtureEntry(a, "user", S("Retained request")), try fixtureEntry(a, "assistant", S("Retained answer")) }, .{});
    var rows = Values.init(a);
    try rows.appendSlice(converted.entries);
    try rows.append(try C.obj(a, &.{ .{ "type", S("compaction") }, .{ "id", S("latest-compact") }, .{ "parentId", S(C.s(rows.items[rows.items.len - 1], "id")) }, .{ "timestamp", S(fixture().updated_at) }, .{ "summary", S("Readable saved summary") }, .{ "firstKeptEntryId", S(C.s(rows.items[4], "id")) }, .{ "tokensBefore", N(500) } }));
    const path = try omp.targetPath(a, fixture(), home);
    try testWrite(a, path, rows.items);
    var thread = fixture();
    thread.rollout_path = path;
    var warnings = C.Warnings.init(a);
    const visible = try omp.readEntries(a, thread, &warnings);
    try std.testing.expectEqual(@as(usize, 6), visible.len);
    try std.testing.expectEqualStrings("compact_boundary", C.s(visible[2], "subtype"));
    try std.testing.expect(C.b(C.get(visible[3], "isCompactSummary")));
    try std.testing.expectEqualStrings("Retained request", C.s(C.list(C.get(C.get(visible[4], "message"), "content"))[0], "text"));
}

test "OMP bounded mixed user result never splits native tool pairs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const huge = try a.alloc(u8, 250_000);
    @memset(huge, 'x');
    const call = try C.parse(a, "[{\"type\":\"tool_use\",\"id\":\"a\",\"name\":\"Bash\",\"input\":{\"command\":\"pwd\"}}]");
    const result = try C.parse(a, "[{\"type\":\"text\",\"text\":\"interleaved tool feedback\"},{\"type\":\"tool_result\",\"tool_use_id\":\"a\",\"content\":\"/tmp\"}]");
    const converted = try omp.convert(a, fixture(), &.{ try fixtureEntry(a, "user", S(huge)), try fixtureEntry(a, "assistant", call), try fixtureEntry(a, "user", result), try fixtureEntry(a, "assistant", S("Newest final answer")) }, .{});
    try std.testing.expectEqual(@as(usize, 0), (try omp.validate(a, converted.entries)).len);
    try std.testing.expect(try F.activeBytes(a, converted.entries) < F.max_active_bytes);
    const active = try F.activeRows(a, converted.entries);
    try std.testing.expect(std.mem.indexOf(u8, try C.json(a, try C.arr(a, active)), "Newest final answer") != null);
    for (active) |row| try std.testing.expect(!C.eq(C.s(C.get(row, "message"), "role"), "toolResult"));
}
test "OMP bounds JSON escaped excerpts and summary-only context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const escaped = try a.alloc(u8, 100_000);
    @memset(escaped, 0);
    const converted = try omp.convert(a, fixture(), &.{ try fixtureEntry(a, "user", S(escaped)), try fixtureEntry(a, "assistant", S(escaped)) }, .{});
    try std.testing.expect(try F.activeBytes(a, converted.entries) < F.max_active_bytes);
    var summary = try fixtureEntry(a, "user", S(escaped));
    try C.set(a, &summary, "isCompactSummary", C.boolean(true));
    const compact = try omp.convert(a, fixture(), &.{summary}, .{});
    try std.testing.expect(try F.activeBytes(a, compact.entries) < F.max_active_bytes);
    try std.testing.expect(compact.warnings.len > 0);
}
test "OMP provenance normalizes title slot and verified image blob rewrites" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try testDirectory(a);
    defer testCleanup(a, home);
    const bytes = "synthetic image payload";
    const hash = try C.sha256(a, bytes);
    const encoder = std.base64.standard.Encoder;
    const encoded = try a.alloc(u8, encoder.calcSize(bytes.len));
    _ = encoder.encode(encoded, bytes);
    const image = try C.obj(a, &.{ .{ "type", S("image") }, .{ "source", try C.obj(a, &.{ .{ "type", S("base64") }, .{ "media_type", S("image/png") }, .{ "data", S(encoded) } }) } });
    const converted = try omp.convert(a, fixture(), &.{ try fixtureEntry(a, "user", try C.arr(a, &.{image})), try fixtureEntry(a, "assistant", S("Visible answer")) }, .{});
    var rows = Values.init(a);
    try rows.append(try C.obj(a, &.{ .{ "type", S("title") }, .{ "v", N(1) }, .{ "title", S(fixture().title) }, .{ "source", S("user") }, .{ "updatedAt", S(fixture().created_at) }, .{ "pad", S("") } }));
    for (converted.entries) |row| try rows.append(try C.clone(a, row));
    const parts = C.get(C.get(rows.items[3], "message"), "content");
    try C.set(a, &parts.array.items[0], "data", S(try C.fmt(a, "blob:sha256:{s}", .{hash})));
    try C.mkdirAll(try C.join(a, &.{ home, "blobs" }));
    const blob = try C.join(a, &.{ home, "blobs", hash });
    try C.writeExclusive(blob, bytes);
    const path = try omp.targetPath(a, fixture(), home);
    try testWrite(a, path, rows.items);
    var thread = fixture();
    thread.rollout_path = path;
    try std.testing.expect((try omp.readOrigin(a, thread)).unchanged);
    try C.atomicWrite(a, blob, "changed bytes");
    try std.testing.expect(!(try omp.readOrigin(a, thread)).unchanged);
}
test "OMP provider snapshot keeps readable tail after replay-through entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try testDirectory(a);
    defer testCleanup(a, home);
    const converted = try omp.convert(a, fixture(), &.{ try fixtureEntry(a, "user", S("Archived")), try fixtureEntry(a, "assistant", S("Snapshot through here")), try fixtureEntry(a, "user", S("Retained since snapshot")), try fixtureEntry(a, "assistant", S("Recent answer")) }, .{});
    var rows = Values.init(a);
    try rows.appendSlice(converted.entries);
    try rows.append(try C.obj(a, &.{ .{ "type", S("compaction") }, .{ "id", S("native-snapshot") }, .{ "parentId", S(C.s(rows.items[rows.items.len - 1], "id")) }, .{ "timestamp", S(fixture().updated_at) }, .{ "summary", S("Readable summary") }, .{ "firstKeptEntryId", S("") }, .{ "providerReplayThroughEntryId", S(C.s(rows.items[3], "id")) }, .{ "tokensBefore", N(500) }, .{ "preserveData", try C.obj(a, &.{}) } }));
    const path = try omp.targetPath(a, fixture(), home);
    try testWrite(a, path, rows.items);
    var thread = fixture();
    thread.rollout_path = path;
    var warnings = C.Warnings.init(a);
    const visible = try omp.readEntries(a, thread, &warnings);
    try std.testing.expectEqualStrings("compact_boundary", C.s(visible[2], "subtype"));
    try std.testing.expectEqualStrings("Retained since snapshot", C.s(C.list(C.get(C.get(visible[4], "message"), "content"))[0], "text"));
}

test "OMP provenance accepts only one valid physical title slot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try testDirectory(a);
    defer testCleanup(a, home);
    const converted = try omp.convert(a, fixture(), &.{ try fixtureEntry(a, "user", S("Question")), try fixtureEntry(a, "assistant", S("Answer")) }, .{});
    const path = try omp.targetPath(a, fixture(), home);
    try testWrite(a, path, converted.entries);
    const original = try C.readFile(a, path);
    var thread = fixture();
    thread.rollout_path = path;
    try C.atomicWrite(a, path, try C.fmt(a, "{{\"type\":\"title\",\"v\":1}}\n{s}", .{original}));
    try std.testing.expect(!(try omp.readOrigin(a, thread)).unchanged);
    const slot = "{\"type\":\"title\",\"v\":1,\"title\":\"x\",\"updatedAt\":\"2026-10-06T00:00:00.000Z\",\"pad\":\"\"}\n";
    try C.atomicWrite(a, path, try C.fmt(a, "{s}{s}{s}", .{ slot, slot, original }));
    try std.testing.expect(!(try omp.readOrigin(a, thread)).unchanged);
}

test "OMP standalone native shell history is discoverable and paired" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try testDirectory(a);
    defer testCleanup(a, home);
    const header = try C.obj(a, &.{ .{ "type", S("session") }, .{ "version", N(3) }, .{ "id", S("standalone-shell") }, .{ "timestamp", S(fixture().created_at) }, .{ "cwd", S(fixture().cwd) } });
    const native = try C.obj(a, &.{ .{ "type", S("message") }, .{ "id", S("shell") }, .{ "parentId", .null }, .{ "timestamp", S(fixture().updated_at) }, .{ "message", try C.obj(a, &.{ .{ "role", S("bashExecution") }, .{ "command", S("pwd") }, .{ "output", S("/tmp") }, .{ "exitCode", N(0) } }) } });
    const path = try C.join(a, &.{ home, "sessions", "fixture", "shell.jsonl" });
    try testWrite(a, path, &.{ header, native });
    const threads = try omp.listThreads(a, home);
    try std.testing.expectEqual(@as(usize, 1), threads.len);
    var warnings = C.Warnings.init(a);
    const visible = try omp.readEntries(a, threads[0], &warnings);
    try std.testing.expectEqual(@as(usize, 2), visible.len);
    const call = C.list(C.get(C.get(visible[0], "message"), "content"))[0];
    const result = C.list(C.get(C.get(visible[1], "message"), "content"))[0];
    try std.testing.expectEqualStrings(C.s(call, "id"), C.s(result, "tool_use_id"));
}
