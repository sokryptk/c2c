const std = @import("std");
const common = @import("../../common.zig");
const source = @import("../../source.zig");
const fixtures = @import("fixtures.zig");
const Fixture = fixtures.Fixture;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectString = std.testing.expectEqualStrings;
const sqlite = fixtures.sqlite;
const sql = fixtures.sql;
const timestamp = fixtures.timestamp;

test "rollout metadata discovers relocated thread and parent provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    try fixture.rollout(
        "{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread-1\",\"cwd\":\"/old project\"," ++
            "\"timestamp\":\"2026-01-01T05:30:00+05:30\"," ++
            "\"source\":{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"parent-1\"}}}}}",
    );
    const threads = try source.listThreads(allocator, fixture.home);
    try expectEqual(@as(usize, 1), threads.len);
    try expectString("thread-1", threads[0].id);
    try expectString("parent-1", threads[0].parent_id.?);
    try expectString("/old project", threads[0].cwd);
    try expectString(timestamp, threads[0].created_at);
    try expectString(fixture.thread.rollout_path, threads[0].rollout_path);
}

test "discovery selects numeric latest evolving state schema without writing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    try fixture.rollout(
        "{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread-1\"}}",
    );
    const Version = struct {
        number: u8,
        title: []const u8,
    };
    for ([_]Version{
        .{ .number = 9, .title = "Old" },
        .{ .number = 10, .title = "Latest" },
    }) |version| {
        const path = try common.fmt(allocator, "{s}/state_{d}.sqlite", .{ fixture.home, version.number });
        const database_path = try allocator.dupeZ(u8, path);
        var database: ?*sqlite.sqlite3 = null;
        try expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_open(database_path, &database));
        defer _ = sqlite.sqlite3_close(database);
        try sql(database, "CREATE TABLE threads (id TEXT, title TEXT, cwd TEXT, created_at INTEGER, updated_at " ++
            "INTEGER, rollout_path TEXT, source TEXT, archived INTEGER)");
        var statement: ?*sqlite.sqlite3_stmt = null;
        const insert_query = "INSERT INTO threads VALUES ('thread-1', ?, '/project', 1767225600, 1767312000, ?, " ++
            "'exec', 0)";
        const prepare_result = sqlite.sqlite3_prepare_v2(database, insert_query, -1, &statement, null);
        try expectEqual(sqlite.SQLITE_OK, prepare_result);
        defer _ = sqlite.sqlite3_finalize(statement);
        try expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_bind_text(
            statement,
            1,
            version.title.ptr,
            @intCast(version.title.len),
            null,
        ));
        try expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_bind_text(
            statement,
            2,
            fixture.thread.rollout_path.ptr,
            @intCast(fixture.thread.rollout_path.len),
            null,
        ));
        try expectEqual(sqlite.SQLITE_DONE, sqlite.sqlite3_step(statement));
    }
    const before = try fixture.temporary_directory.dir.readFileAlloc(
        std.testing.io,
        "state_10.sqlite",
        allocator,
        .unlimited,
    );
    const threads = try source.listThreads(allocator, fixture.home);
    const after = try fixture.temporary_directory.dir.readFileAlloc(
        std.testing.io,
        "state_10.sqlite",
        allocator,
        .unlimited,
    );
    try expectEqual(@as(usize, 1), threads.len);
    try expectString("Latest", threads[0].title);
    try expectString("exec", threads[0].source);
    try expectString(timestamp, threads[0].created_at);
    try expectString("2026-01-02T00:00:00.000Z", threads[0].updated_at);
    try expectString(before, after);
}

test "discovery preserves verified Claude OMP and OpenCode import provenance" {
    for ([_][]const u8{ "claude", "omp", "opencode" }) |provider| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var fixture = try Fixture.init(allocator);
        defer fixture.deinit();
        const message = try common.obj(allocator, &.{
            .{ "role", common.str("user") },
            .{ "content", common.str("Synthetic portable request") },
        });
        const entry = try common.obj(allocator, &.{
            .{ "type", common.str("user") },
            .{ "timestamp", common.str(timestamp) },
            .{ "message", message },
        });
        const entries = &.{entry};
        const conversion = try @import("../../codex.zig").convert(allocator, fixture.thread, entries, .{
            .source_provider = provider,
            .source_session_id = "portable-source-session",
        });
        try fixture.records(conversion.entries);
        const original = try fixture.temporary_directory.dir.readFileAlloc(
            std.testing.io,
            "sessions/rollout.jsonl",
            allocator,
            .unlimited,
        );
        const threads = try source.listThreads(allocator, fixture.home);
        try expectEqual(@as(usize, 1), threads.len);
        try expectString("codex", threads[0].provider);
        try expectString(provider, threads[0].origin_provider.?);
        try expectString("portable-source-session", threads[0].origin_id.?);
        try expect(threads[0].unchanged_import);
        if (common.eq(provider, "claude")) {
            try expectString("portable-source-session", threads[0].original_claude_id.?);
        } else {
            try expectEqual(@as(?[]const u8, null), threads[0].original_claude_id);
        }
        const unchanged = try fixture.temporary_directory.dir.readFileAlloc(
            std.testing.io,
            "sessions/rollout.jsonl",
            allocator,
            .unlimited,
        );
        try expectString(original, unchanged);

        const continued_rollout = try common.fmt(allocator, "{s}{s}\n", .{
            original,
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\"," ++
                "\"content\":[{\"type\":\"input_text\",\"text\":\"New continuation\"}]}}",
        });
        try fixture.rollout(continued_rollout);
        const continued = try source.listThreads(allocator, fixture.home);
        try expectString(provider, continued[0].origin_provider.?);
        try expectString("portable-source-session", continued[0].origin_id.?);
        try expect(!continued[0].unchanged_import);
    }
}

test "discovery does not fingerprint unrelated rollout histories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    try fixture.rollout(
        "{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread-1\"," ++
            "\"originator\":\"c2c:unsupported:not-an-import\"}}\n" ++
            "{malformed unread history}",
    );
    const threads = try source.listThreads(allocator, fixture.home);
    try expectEqual(@as(usize, 1), threads.len);
    try expectEqual(@as(?[]const u8, null), threads[0].origin_provider);
    try expectEqual(@as(?[]const u8, null), threads[0].origin_id);
    try expect(!threads[0].unchanged_import);
}
