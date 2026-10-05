const std = @import("std");
const C = @import("../common.zig");
const codec = @import("codec.zig");
const V = C.Value;
const A = C.Allocator;
const S = C.str;
const N = C.num;
const sqlite = @cImport({
    @cInclude("sqlite3.h");
});

// Native registration uses the installed Codex binary as the sole writer of
// state/projection databases. Expected bytes are checked again after migration.
fn preflight(a: A, home: []const u8, id: []const u8) ![]const u8 {
    const files = try C.walkFiles(a, try C.join(a, &.{ home, "sessions" }), ".jsonl");
    const suffix = try C.fmt(a, "-{s}.jsonl", .{id});
    var expected: ?[]const u8 = null;
    for (files) |path| if (std.mem.endsWith(u8, path, suffix)) {
        if (expected != null) return error.AmbiguousNativeSessionPath;
        expected = path;
    };
    const path = expected orelse return error.NativeSessionPathMissing;
    var database: ?[]const u8 = null;
    var highest: u32 = 0;
    for (try C.listDir(a, home)) |entry| {
        const name = entry.name;
        if (std.mem.startsWith(u8, name, "state_") and std.mem.endsWith(u8, name, ".sqlite")) {
            const number = std.fmt.parseInt(u32, name[6 .. name.len - 7], 10) catch continue;
            if (database == null or number > highest) {
                highest = number;
                database = try C.join(a, &.{ home, name });
            }
        }
    }
    if (database) |db_path| {
        var db: ?*sqlite.sqlite3 = null;
        if (sqlite.sqlite3_open_v2(try a.dupeZ(u8, db_path), &db, sqlite.SQLITE_OPEN_READONLY, null) != sqlite.SQLITE_OK) return error.NativeDatabaseReadFailed;
        defer _ = sqlite.sqlite3_close(db);
        var statement: ?*sqlite.sqlite3_stmt = null;
        if (sqlite.sqlite3_prepare_v2(db, "SELECT rollout_path, archived FROM threads WHERE id=?", -1, &statement, null) != sqlite.SQLITE_OK) return error.NativeDatabaseSchemaUnsupported;
        defer _ = sqlite.sqlite3_finalize(statement);
        const id_z = try a.dupeZ(u8, id);
        _ = sqlite.sqlite3_bind_text(statement, 1, id_z.ptr, @intCast(id.len), null);
        if (sqlite.sqlite3_step(statement) == sqlite.SQLITE_ROW) {
            const native_path = std.mem.span(sqlite.sqlite3_column_text(statement, 0));
            if (sqlite.sqlite3_column_int(statement, 1) != 0 or !C.eq(native_path, path)) return error.NativeSessionIdAlreadyBound;
        }
    }
    const probe = C.Thread{ .id = id, .title = "", .cwd = "", .created_at = "", .updated_at = "", .rollout_path = path };
    if (!(try codec.readOrigin(a, probe)).unchanged) return error.NativeSessionChangedBeforeRegistration;
    return path;
}
const Server = struct {
    child: C.Child,
    a: A,
    sequence: usize = 0,
    fn start(a: A, home: []const u8) !Server {
        return .{ .a = a, .child = try C.Child.start(a, &.{ "codex", "app-server", "--stdio" }, &.{.{ "CODEX_HOME", home }}) };
    }
    fn call(self: *Server, method: []const u8, params: V) !V {
        self.sequence += 1;
        const id: i64 = @intCast(self.sequence);
        const request = try C.obj(self.a, &.{ .{ "id", N(id) }, .{ "method", S(method) }, .{ "params", params } });
        try self.child.write(try C.fmt(self.a, "{s}\n", .{try C.json(self.a, request)}));
        while (try self.child.readLine(self.a, 60_000)) |line| {
            const reply = C.parse(self.a, line) catch continue;
            if (C.integer(C.get(reply, "id")) != id) continue;
            if (C.get(reply, "error") != .null) return error.CodexNativeRpcFailed;
            return C.get(reply, "result");
        }
        return error.CodexNativeServerEnded;
    }
    fn initialize(self: *Server) !void {
        _ = try self.call("initialize", try C.obj(self.a, &.{ .{ "clientInfo", try C.obj(self.a, &.{ .{ "name", S("c2c") }, .{ "version", S("0.1.0") } }) }, .{ "capabilities", try C.obj(self.a, &.{.{ "experimentalApi", C.boolean(true) }}) } }));
        try self.child.write("{\"method\":\"initialized\"}\n");
    }
};
pub fn register(a: A, home: []const u8, id: []const u8, title: []const u8) !V {
    if (!C.validUuid(id)) return error.InvalidCodexSessionId;
    const path = try preflight(a, home, id);
    // thread/read backfills SQLite metadata for new legacy files. Without it,
    // migrate-rollouts can fail missing_sqlite_metadata for older files or
    // destinations whose initial backfill is complete.
    var server = try Server.start(a, home);
    defer server.child.close();
    try server.initialize();
    const parameters = try C.obj(a, &.{ .{ "threadId", S(id) }, .{ "includeTurns", C.boolean(false) } });
    try verifyNativeIdentity(C.get(try server.call("thread/read", parameters), "thread"), id, path);
    const result = try C.run(a, &.{ "codex", "migrate-rollouts", "--apply", "--thread", id, "--json" }, &.{.{ "CODEX_HOME", home }}, null, 300_000);
    if (result.exit_code != 0) return error.CodexNativeMigrationFailed;
    if (!(try codec.readOrigin(a, .{ .id = id, .title = "", .cwd = "", .created_at = "", .updated_at = "", .rollout_path = path })).unchanged) return error.CodexMigrationChangedConversationContent;
    const saved = C.get(try server.call("thread/read", parameters), "thread");
    try verifyNativeIdentity(saved, id, path);
    if (C.s(saved, "name").len == 0) _ = try server.call("thread/name/set", try C.obj(a, &.{ .{ "threadId", S(id) }, .{ "name", S(if (title.len > 0) title else "Imported source conversation") } }));
    return C.obj(a, &.{ .{ "thread_id", S(id) }, .{ "status", S("registered") }, .{ "format_version", S(codec.format_version) } });
}
fn verifyNativeIdentity(saved: V, id: []const u8, path: []const u8) !void {
    if (!C.eq(C.s(saved, "id"), id)) return error.NativeSessionIdentityMismatch;
    if (C.s(saved, "path").len > 0 and !C.eq(C.s(saved, "path"), path)) return error.NativeSessionPathMismatch;
}

fn newestDatabase(a: A, home: []const u8, prefix: []const u8) !?[]const u8 {
    var latest: ?[]const u8 = null;
    var highest: u64 = 0;
    for (try C.listDir(a, home)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, prefix) or !std.mem.endsWith(u8, entry.name, ".sqlite")) continue;
        const number = std.fmt.parseInt(u64, entry.name[prefix.len .. entry.name.len - 7], 10) catch continue;
        if (latest == null or number > highest) {
            latest = try C.join(a, &.{ home, entry.name });
            highest = number;
        }
    }
    return latest;
}
fn databaseHasSession(a: A, path: []const u8, id: []const u8, history: bool) !bool {
    var db: ?*sqlite.sqlite3 = null;
    if (sqlite.sqlite3_open_v2(try a.dupeZ(u8, path), &db, sqlite.SQLITE_OPEN_READONLY, null) != sqlite.SQLITE_OK) {
        if (db != null) _ = sqlite.sqlite3_close(db);
        return error.NativeDatabaseReadFailed;
    }
    defer _ = sqlite.sqlite3_close(db);
    const tables: []const []const u8 = if (history) &.{ "thread_turns", "thread_items", "thread_history_projection_state", "thread_realtime_items" } else &.{"threads"};
    var known_tables: usize = 0;
    for (tables) |table| {
        var schema: ?*sqlite.sqlite3_stmt = null;
        if (sqlite.sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", -1, &schema, null) != sqlite.SQLITE_OK) return error.NativeDatabaseReadFailed;
        defer _ = sqlite.sqlite3_finalize(schema);
        const table_z = try a.dupeZ(u8, table);
        _ = sqlite.sqlite3_bind_text(schema, 1, table_z.ptr, @intCast(table.len), null);
        const schema_step = sqlite.sqlite3_step(schema);
        if (schema_step == sqlite.SQLITE_DONE) continue;
        if (schema_step != sqlite.SQLITE_ROW) return error.NativeDatabaseReadFailed;
        known_tables += 1;
        var query: ?*sqlite.sqlite3_stmt = null;
        const sql_text = try a.dupeZ(u8, try C.fmt(a, "SELECT 1 FROM {s} WHERE {s}=? LIMIT 1", .{ table, if (history) "thread_id" else "id" }));
        if (sqlite.sqlite3_prepare_v2(db, sql_text, -1, &query, null) != sqlite.SQLITE_OK) return error.NativeDatabaseSchemaUnsupported;
        defer _ = sqlite.sqlite3_finalize(query);
        const id_z = try a.dupeZ(u8, id);
        _ = sqlite.sqlite3_bind_text(query, 1, id_z.ptr, @intCast(id.len), null);
        const step = sqlite.sqlite3_step(query);
        if (step == sqlite.SQLITE_ROW) return true;
        if (step != sqlite.SQLITE_DONE) return error.NativeDatabaseReadFailed;
    }
    if (known_tables == 0) return error.NativeDatabaseSchemaUnsupported;
    return false;
}
fn nativeAbsent(a: A, home: []const u8, id: []const u8) !bool {
    const suffix = try C.fmt(a, "-{s}.jsonl", .{id});
    for ([_][]const u8{ "sessions", "archived_sessions" }) |directory| {
        const root = try C.join(a, &.{ home, directory });
        if (!C.exists(root)) continue;
        for (try C.walkFiles(a, root, ".jsonl")) |path| if (std.mem.endsWith(u8, path, suffix)) return false;
    }
    if (try newestDatabase(a, home, "state_")) |path| if (try databaseHasSession(a, path, id, false)) return false;
    if (try newestDatabase(a, home, "thread_history_")) |path| if (try databaseHasSession(a, path, id, true)) return false;
    const index = try C.join(a, &.{ home, "session_index.jsonl" });
    if (C.exists(index)) {
        var reader = try C.LineReader.open(a, index);
        defer reader.close();
        while (try reader.next()) |line| {
            if (std.mem.trim(u8, line, " \t\r\n").len == 0) continue;
            const row = try C.parse(a, line);
            if (C.eq(C.s(row, "id"), id) or C.eq(C.s(row, "session_id"), id) or C.eq(C.s(row, "thread_id"), id)) return false;
        }
    }
    return true;
}

pub fn unregister(a: A, home: []const u8, id: []const u8) !void {
    if (!C.validUuid(id)) return error.InvalidCodexSessionId;
    const result = try C.run(a, &.{ "codex", "delete", "--force", id }, &.{.{ "CODEX_HOME", home }}, null, 60_000);
    if (result.exit_code == 0) {
        if (!try nativeAbsent(a, home, id)) return error.CodexNativeRemovalIncomplete;
        return;
    }
    // Recovery may retry a completed delete. Accept a missing-session failure
    // only after verifying that no live state remains.
    if (result.exit_code == 1 and std.mem.endsWith(u8, std.mem.trim(u8, result.stderr, " \t\r\n"), "Error: failed to delete session") and try nativeAbsent(a, home, id)) return;
    return error.CodexNativeRemovalFailed;
}

test "native operations reject invalid session IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidCodexSessionId, register(a, "/invalid-do-not-touch", "bad", "title"));
    try std.testing.expectError(error.InvalidCodexSessionId, unregister(a, "/invalid-do-not-touch", "bad"));
}

test "Codex removal absence checks live files native metadata and projection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const template = try a.dupeZ(u8, "/tmp/c2c-codex-absence-XXXXXX");
    if (C.c.mkdtemp(template) == null) return error.TemporaryDirectoryFailed;
    const home: []const u8 = template;
    defer _ = C.c.rmdir(template);
    const id = "00000000-0000-0000-0000-000000000123";
    try std.testing.expect(try nativeAbsent(a, home, id));
    const state_path = try C.join(a, &.{ home, "state_5.sqlite" });
    defer C.removeFile(state_path) catch {};
    var db: ?*sqlite.sqlite3 = null;
    try std.testing.expectEqual(@as(c_int, sqlite.SQLITE_OK), sqlite.sqlite3_open(try a.dupeZ(u8, state_path), &db));
    defer _ = sqlite.sqlite3_close(db);
    try std.testing.expectEqual(@as(c_int, sqlite.SQLITE_OK), sqlite.sqlite3_exec(db, "CREATE TABLE threads(id TEXT)", null, null, null));
    try std.testing.expect(try nativeAbsent(a, home, id));
    try std.testing.expectEqual(@as(c_int, sqlite.SQLITE_OK), sqlite.sqlite3_exec(db, "INSERT INTO threads VALUES('00000000-0000-0000-0000-000000000123')", null, null, null));
    try std.testing.expect(!try nativeAbsent(a, home, id));
    try std.testing.expectEqual(@as(c_int, sqlite.SQLITE_OK), sqlite.sqlite3_exec(db, "DELETE FROM threads", null, null, null));
    const history_path = try C.join(a, &.{ home, "thread_history_1.sqlite" });
    defer C.removeFile(history_path) catch {};
    var history: ?*sqlite.sqlite3 = null;
    try std.testing.expectEqual(@as(c_int, sqlite.SQLITE_OK), sqlite.sqlite3_open(try a.dupeZ(u8, history_path), &history));
    defer _ = sqlite.sqlite3_close(history);
    try std.testing.expectEqual(@as(c_int, sqlite.SQLITE_OK), sqlite.sqlite3_exec(history, "CREATE TABLE thread_items(thread_id TEXT); INSERT INTO thread_items VALUES('00000000-0000-0000-0000-000000000123')", null, null, null));
    try std.testing.expect(!try nativeAbsent(a, home, id));
    try std.testing.expectEqual(@as(c_int, sqlite.SQLITE_OK), sqlite.sqlite3_exec(history, "DELETE FROM thread_items", null, null, null));
    const index = try C.join(a, &.{ home, "session_index.jsonl" });
    try C.writeExclusive(index, "{\"id\":\"00000000-0000-0000-0000-000000000123\"}\n");
    defer C.removeFile(index) catch {};
    try std.testing.expect(!try nativeAbsent(a, home, id));
}
