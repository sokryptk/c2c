const std = @import("std");
const common = @import("../common.zig");
const codec = @import("codec.zig");
const Value = common.Value;
const Allocator = common.Allocator;
const jsonString = common.str;
const jsonInteger = common.num;
const sqlite = @cImport({
    @cInclude("sqlite3.h");
});

// Native registration uses the installed Codex binary as the sole writer of
// state/projection databases. Expected bytes are checked again after migration.
fn preflight(allocator: Allocator, home: []const u8, id: []const u8) ![]const u8 {
    const files = try common.walkFiles(allocator, try common.join(allocator, &.{ home, "sessions" }), ".jsonl");
    const suffix = try common.fmt(allocator, "-{s}.jsonl", .{id});
    var expected: ?[]const u8 = null;
    for (files) |path| {
        if (!std.mem.endsWith(u8, path, suffix)) {
            continue;
        }
        if (expected != null) {
            return error.AmbiguousNativeSessionPath;
        }
        expected = path;
    }
    const path = expected orelse return error.NativeSessionPathMissing;
    var database: ?[]const u8 = null;
    var highest: u32 = 0;
    for (try common.listDir(allocator, home)) |entry| {
        const name = entry.name;
        if (std.mem.startsWith(u8, name, "state_") and std.mem.endsWith(u8, name, ".sqlite")) {
            const number = std.fmt.parseInt(u32, name[6 .. name.len - 7], 10) catch continue;
            if (database == null or number > highest) {
                highest = number;
                database = try common.join(allocator, &.{ home, name });
            }
        }
    }
    if (database) |db_path| {
        var db: ?*sqlite.sqlite3 = null;
        const open_result = sqlite.sqlite3_open_v2(
            try allocator.dupeZ(u8, db_path),
            &db,
            sqlite.SQLITE_OPEN_READONLY,
            null,
        );
        if (open_result != sqlite.SQLITE_OK) {
            return error.NativeDatabaseReadFailed;
        }
        defer _ = sqlite.sqlite3_close(db);
        var statement: ?*sqlite.sqlite3_stmt = null;
        if (sqlite.sqlite3_prepare_v2(
            db,
            "SELECT rollout_path, archived FROM threads WHERE id=?",
            -1,
            &statement,
            null,
        ) != sqlite.SQLITE_OK) {
            return error.NativeDatabaseSchemaUnsupported;
        }
        defer _ = sqlite.sqlite3_finalize(statement);
        const id_z = try allocator.dupeZ(u8, id);
        _ = sqlite.sqlite3_bind_text(statement, 1, id_z.ptr, @intCast(id.len), null);
        if (sqlite.sqlite3_step(statement) == sqlite.SQLITE_ROW) {
            const native_path = std.mem.span(sqlite.sqlite3_column_text(statement, 0));
            if (sqlite.sqlite3_column_int(statement, 1) != 0 or !common.eq(native_path, path)) {
                return error.NativeSessionIdAlreadyBound;
            }
        }
    }
    const probe = common.Thread{
        .id = id,
        .title = "",
        .cwd = "",
        .created_at = "",
        .updated_at = "",
        .rollout_path = path,
    };
    if (!(try codec.readOrigin(allocator, probe)).unchanged) {
        return error.NativeSessionChangedBeforeRegistration;
    }
    return path;
}

const Server = struct {
    child: common.Child,
    allocator: Allocator,
    sequence: usize = 0,
    fn start(allocator: Allocator, home: []const u8) !Server {
        return .{
            .allocator = allocator,
            .child = try common.Child.start(
                allocator,
                &.{ "codex", "app-server", "--stdio" },
                &.{.{ "CODEX_HOME", home }},
            ),
        };
    }
    fn call(self: *Server, method: []const u8, params: Value) !Value {
        self.sequence += 1;
        const id: i64 = @intCast(self.sequence);
        const request = try common.obj(self.allocator, &.{
            .{ "id", jsonInteger(id) },
            .{ "method", jsonString(method) },
            .{ "params", params },
        });
        const request_json = try common.json(self.allocator, request);
        const request_line = try common.fmt(self.allocator, "{s}\n", .{request_json});
        try self.child.write(request_line);
        while (try self.child.readLine(self.allocator, 60_000)) |line| {
            const reply = common.parse(self.allocator, line) catch continue;
            if (common.integer(common.get(reply, "id")) != id) {
                continue;
            }
            if (common.get(reply, "error") != .null) {
                return error.CodexNativeRpcFailed;
            }
            return common.get(reply, "result");
        }
        return error.CodexNativeServerEnded;
    }
    fn initialize(self: *Server) !void {
        const client_info = try common.obj(self.allocator, &.{
            .{ "name", jsonString("c2c") },
            .{ "version", jsonString("0.1.0") },
        });
        const capabilities = try common.obj(self.allocator, &.{
            .{ "experimentalApi", common.boolean(true) },
        });
        const parameters = try common.obj(self.allocator, &.{
            .{ "clientInfo", client_info },
            .{ "capabilities", capabilities },
        });
        _ = try self.call("initialize", parameters);
        try self.child.write("{\"method\":\"initialized\"}\n");
    }
};
pub fn register(allocator: Allocator, home: []const u8, id: []const u8, title: []const u8) !Value {
    if (!common.validUuid(id)) {
        return error.InvalidCodexSessionId;
    }
    const path = try preflight(allocator, home, id);
    // thread/read backfills SQLite metadata for new legacy files. Without it,
    // migrate-rollouts can fail missing_sqlite_metadata for older files or
    // destinations whose initial backfill is complete.
    var server = try Server.start(allocator, home);
    defer server.child.close();
    try server.initialize();
    const parameters = try common.obj(allocator, &.{
        .{ "threadId", jsonString(id) },
        .{ "includeTurns", common.boolean(false) },
    });
    try verifyNativeIdentity(common.get(try server.call("thread/read", parameters), "thread"), id, path);
    const result = try common.run(
        allocator,
        &.{ "codex", "migrate-rollouts", "--apply", "--thread", id, "--json" },
        &.{.{ "CODEX_HOME", home }},
        null,
        300_000,
    );
    if (result.exit_code != 0) {
        return error.CodexNativeMigrationFailed;
    }
    const origin = try codec.readOrigin(
        allocator,
        .{
            .id = id,
            .title = "",
            .cwd = "",
            .created_at = "",
            .updated_at = "",
            .rollout_path = path,
        },
    );
    if (!origin.unchanged) {
        return error.CodexMigrationChangedConversationContent;
    }
    const saved = common.get(try server.call("thread/read", parameters), "thread");
    try verifyNativeIdentity(saved, id, path);
    if (common.stringField(saved, "name").len == 0) {
        _ = try server.call(
            "thread/name/set",
            try common.obj(allocator, &.{
                .{ "threadId", jsonString(id) },
                .{ "name", jsonString(if (title.len > 0) title else "Imported source conversation") },
            }),
        );
    }
    return common.obj(allocator, &.{
        .{ "thread_id", jsonString(id) },
        .{ "status", jsonString("registered") },
        .{ "format_version", jsonString(codec.format_version) },
    });
}

fn verifyNativeIdentity(saved: Value, id: []const u8, path: []const u8) !void {
    if (!common.eq(common.stringField(saved, "id"), id)) {
        return error.NativeSessionIdentityMismatch;
    }
    if (common.stringField(saved, "path").len > 0 and !common.eq(common.stringField(saved, "path"), path)) {
        return error.NativeSessionPathMismatch;
    }
}

fn newestDatabase(allocator: Allocator, home: []const u8, prefix: []const u8) !?[]const u8 {
    var latest: ?[]const u8 = null;
    var highest: u64 = 0;
    for (try common.listDir(allocator, home)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, prefix) or !std.mem.endsWith(u8, entry.name, ".sqlite")) {
            continue;
        }
        const number = std.fmt.parseInt(u64, entry.name[prefix.len .. entry.name.len - 7], 10) catch continue;
        if (latest == null or number > highest) {
            latest = try common.join(allocator, &.{ home, entry.name });
            highest = number;
        }
    }
    return latest;
}

fn databaseHasSession(allocator: Allocator, path: []const u8, id: []const u8, history: bool) !bool {
    var db: ?*sqlite.sqlite3 = null;
    const open_result = sqlite.sqlite3_open_v2(
        try allocator.dupeZ(u8, path),
        &db,
        sqlite.SQLITE_OPEN_READONLY,
        null,
    );
    if (open_result != sqlite.SQLITE_OK) {
        if (db != null) {
            _ = sqlite.sqlite3_close(db);
        }
        return error.NativeDatabaseReadFailed;
    }
    defer _ = sqlite.sqlite3_close(db);
    const tables: []const []const u8 = if (history) &.{
        "thread_turns",
        "thread_items",
        "thread_history_projection_state",
        "thread_realtime_items",
    } else &.{"threads"};
    var known_tables: usize = 0;
    for (tables) |table| {
        var schema: ?*sqlite.sqlite3_stmt = null;
        if (sqlite.sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
            -1,
            &schema,
            null,
        ) != sqlite.SQLITE_OK) {
            return error.NativeDatabaseReadFailed;
        }
        defer _ = sqlite.sqlite3_finalize(schema);
        const table_z = try allocator.dupeZ(u8, table);
        _ = sqlite.sqlite3_bind_text(schema, 1, table_z.ptr, @intCast(table.len), null);
        const schema_step = sqlite.sqlite3_step(schema);
        if (schema_step == sqlite.SQLITE_DONE) {
            continue;
        }
        if (schema_step != sqlite.SQLITE_ROW) {
            return error.NativeDatabaseReadFailed;
        }
        known_tables += 1;
        var query: ?*sqlite.sqlite3_stmt = null;
        const sql_text = try allocator.dupeZ(
            u8,
            try common.fmt(
                allocator,
                "SELECT 1 FROM {s} WHERE {s}=? LIMIT 1",
                .{ table, if (history) "thread_id" else "id" },
            ),
        );
        if (sqlite.sqlite3_prepare_v2(db, sql_text, -1, &query, null) != sqlite.SQLITE_OK) {
            return error.NativeDatabaseSchemaUnsupported;
        }
        defer _ = sqlite.sqlite3_finalize(query);
        const id_z = try allocator.dupeZ(u8, id);
        _ = sqlite.sqlite3_bind_text(query, 1, id_z.ptr, @intCast(id.len), null);
        const step = sqlite.sqlite3_step(query);
        if (step == sqlite.SQLITE_ROW) {
            return true;
        }
        if (step != sqlite.SQLITE_DONE) {
            return error.NativeDatabaseReadFailed;
        }
    }
    if (known_tables == 0) {
        return error.NativeDatabaseSchemaUnsupported;
    }
    return false;
}

fn nativeAbsent(allocator: Allocator, home: []const u8, id: []const u8) !bool {
    const suffix = try common.fmt(allocator, "-{s}.jsonl", .{id});
    for ([_][]const u8{ "sessions", "archived_sessions" }) |directory| {
        const root = try common.join(allocator, &.{ home, directory });
        if (!common.exists(root)) {
            continue;
        }
        for (try common.walkFiles(allocator, root, ".jsonl")) |path| {
            if (std.mem.endsWith(u8, path, suffix)) {
                return false;
            }
        }
    }
    if (try newestDatabase(allocator, home, "state_")) |path| {
        if (try databaseHasSession(allocator, path, id, false)) {
            return false;
        }
    }
    if (try newestDatabase(allocator, home, "thread_history_")) |path| {
        if (try databaseHasSession(allocator, path, id, true)) {
            return false;
        }
    }
    const index = try common.join(allocator, &.{ home, "session_index.jsonl" });
    if (common.exists(index)) {
        var reader = try common.LineReader.open(allocator, index);
        defer reader.close();
        while (try reader.next()) |line| {
            if (std.mem.trim(u8, line, " \t\r\n").len == 0) {
                continue;
            }
            const row = try common.parse(allocator, line);
            if (common.eq(common.stringField(row, "id"), id) or
                common.eq(common.stringField(row, "session_id"), id) or
                common.eq(common.stringField(row, "thread_id"), id))
            {
                return false;
            }
        }
    }
    return true;
}

pub fn unregister(allocator: Allocator, home: []const u8, id: []const u8) !void {
    if (!common.validUuid(id)) {
        return error.InvalidCodexSessionId;
    }
    const result = try common.run(
        allocator,
        &.{ "codex", "delete", "--force", id },
        &.{.{ "CODEX_HOME", home }},
        null,
        60_000,
    );
    if (result.exit_code == 0) {
        if (!try nativeAbsent(allocator, home, id)) {
            return error.CodexNativeRemovalIncomplete;
        }
        return;
    }
    // Recovery may retry a completed delete. Accept a missing-session failure
    // only after verifying that no live state remains.
    const missing_session = result.exit_code == 1 and std.mem.endsWith(
        u8,
        std.mem.trim(u8, result.stderr, " \t\r\n"),
        "Error: failed to delete session",
    );
    if (missing_session and try nativeAbsent(allocator, home, id)) {
        return;
    }
    return error.CodexNativeRemovalFailed;
}

test "native operations reject invalid session IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(
        error.InvalidCodexSessionId,
        register(allocator, "/invalid-do-not-touch", "bad", "title"),
    );
    try std.testing.expectError(error.InvalidCodexSessionId, unregister(allocator, "/invalid-do-not-touch", "bad"));
}

test "Codex removal absence checks live files native metadata and projection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const template = try allocator.dupeZ(u8, "/tmp/c2c-codex-absence-XXXXXX");
    if (common.c.mkdtemp(template) == null) {
        return error.TemporaryDirectoryFailed;
    }
    const home: []const u8 = template;
    defer _ = common.c.rmdir(template);
    const id = "00000000-0000-0000-0000-000000000123";
    try std.testing.expect(try nativeAbsent(allocator, home, id));
    const state_path = try common.join(allocator, &.{ home, "state_5.sqlite" });
    defer common.removeFile(state_path) catch {};
    var db: ?*sqlite.sqlite3 = null;
    try std.testing.expectEqual(
        @as(c_int, sqlite.SQLITE_OK),
        sqlite.sqlite3_open(try allocator.dupeZ(u8, state_path), &db),
    );
    defer _ = sqlite.sqlite3_close(db);
    try std.testing.expectEqual(
        @as(c_int, sqlite.SQLITE_OK),
        sqlite.sqlite3_exec(db, "CREATE TABLE threads(id TEXT)", null, null, null),
    );
    try std.testing.expect(try nativeAbsent(allocator, home, id));
    try std.testing.expectEqual(
        @as(c_int, sqlite.SQLITE_OK),
        sqlite.sqlite3_exec(
            db,
            "INSERT INTO threads VALUES('00000000-0000-0000-0000-000000000123')",
            null,
            null,
            null,
        ),
    );
    try std.testing.expect(!try nativeAbsent(allocator, home, id));
    try std.testing.expectEqual(
        @as(c_int, sqlite.SQLITE_OK),
        sqlite.sqlite3_exec(db, "DELETE FROM threads", null, null, null),
    );
    const history_path = try common.join(allocator, &.{ home, "thread_history_1.sqlite" });
    defer common.removeFile(history_path) catch {};
    var history: ?*sqlite.sqlite3 = null;
    try std.testing.expectEqual(
        @as(c_int, sqlite.SQLITE_OK),
        sqlite.sqlite3_open(try allocator.dupeZ(u8, history_path), &history),
    );
    defer _ = sqlite.sqlite3_close(history);
    try std.testing.expectEqual(
        @as(c_int, sqlite.SQLITE_OK),
        sqlite.sqlite3_exec(
            history,
            "CREATE TABLE thread_items(thread_id TEXT); " ++
                "INSERT INTO thread_items VALUES('00000000-0000-0000-0000-000000000123')",
            null,
            null,
            null,
        ),
    );
    try std.testing.expect(!try nativeAbsent(allocator, home, id));
    try std.testing.expectEqual(
        @as(c_int, sqlite.SQLITE_OK),
        sqlite.sqlite3_exec(history, "DELETE FROM thread_items", null, null, null),
    );
    const index = try common.join(allocator, &.{ home, "session_index.jsonl" });
    try common.writeExclusive(index, "{\"id\":\"00000000-0000-0000-0000-000000000123\"}\n");
    defer common.removeFile(index) catch {};
    try std.testing.expect(!try nativeAbsent(allocator, home, id));
}
