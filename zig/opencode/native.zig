const std = @import("std");
const C = @import("../common.zig");
const A = C.Allocator;
const V = C.Value;
const S = C.str;
const N = C.num;
const Values = std.array_list.Managed(V);
const codec = @import("codec.zig");
const sql = @cImport({
    @cInclude("sqlite3.h");
});

const Database = struct {
    handle: ?*sql.sqlite3,
    a: A,
    fn open(a: A, path: []const u8) !Database {
        var handle: ?*sql.sqlite3 = null;
        if (sql.sqlite3_open_v2(try a.dupeZ(u8, path), &handle, sql.SQLITE_OPEN_READONLY, null) != sql.SQLITE_OK) {
            if (handle != null) _ = sql.sqlite3_close(handle);
            return error.OpenCodeDatabaseUnavailable;
        }
        errdefer _ = sql.sqlite3_close(handle);
        _ = sql.sqlite3_busy_timeout(handle, 5000);
        if (sql.sqlite3_exec(handle, "BEGIN", null, null, null) != sql.SQLITE_OK) return error.OpenCodeSnapshotFailed;
        return .{ .handle = handle, .a = a };
    }
    fn close(self: *Database) void {
        _ = sql.sqlite3_close(self.handle);
    }
    fn query(self: *Database, text: [:0]const u8, id: ?[]const u8) !?*sql.sqlite3_stmt {
        var statement: ?*sql.sqlite3_stmt = null;
        if (sql.sqlite3_prepare_v2(self.handle, text.ptr, -1, &statement, null) != sql.SQLITE_OK)
            return error.UnsupportedOpenCodeDatabaseSchema;
        errdefer _ = sql.sqlite3_finalize(statement);
        if (id) |identifier| {
            const owned = try self.a.dupeZ(u8, identifier);
            if (sql.sqlite3_bind_text(statement, 1, owned.ptr, @intCast(identifier.len), null) != sql.SQLITE_OK)
                return error.OpenCodeQueryFailed;
        }
        return statement;
    }
    fn string(self: *Database, statement: ?*sql.sqlite3_stmt, col: c_int) ![]const u8 {
        const ptr = sql.sqlite3_column_text(statement, col);
        return if (ptr == null) "" else self.a.dupe(u8, ptr[0..@intCast(sql.sqlite3_column_bytes(statement, col))]);
    }
    fn value(self: *Database, statement: ?*sql.sqlite3_stmt, col: c_int) !V {
        const text = try self.string(statement, col);
        return if (text.len == 0) .null else C.parse(self.a, text);
    }
};
fn rowNative(a: A, db: *Database, statement: ?*sql.sqlite3_stmt) !V {
    const id = try db.string(statement, 0);
    var time = try C.obj(a, &.{ .{ "created", N(sql.sqlite3_column_int64(statement, 3)) }, .{ "updated", N(sql.sqlite3_column_int64(statement, 4)) } });
    if (sql.sqlite3_column_type(statement, 7) != sql.SQLITE_NULL)
        try C.set(a, &time, "archived", N(sql.sqlite3_column_int64(statement, 7)));
    var info = try C.obj(a, &.{ .{ "id", S(id) }, .{ "title", S(try db.string(statement, 1)) }, .{ "location", try C.obj(a, &.{.{ "directory", S(try db.string(statement, 2)) }}) }, .{ "time", time }, .{ "metadata", try db.value(statement, 6) }, .{ "projectID", S(try db.string(statement, 8)) }, .{ "cost", .{ .float = sql.sqlite3_column_double(statement, 9) } }, .{ "tokens", try C.obj(a, &.{ .{ "input", N(sql.sqlite3_column_int64(statement, 10)) }, .{ "output", N(sql.sqlite3_column_int64(statement, 11)) }, .{ "reasoning", N(sql.sqlite3_column_int64(statement, 12)) }, .{ "cache", try C.obj(a, &.{ .{ "read", N(sql.sqlite3_column_int64(statement, 13)) }, .{ "write", N(sql.sqlite3_column_int64(statement, 14)) } }) } }) } });
    const parent = try db.string(statement, 5);
    if (parent.len > 0) try C.set(a, &info, "parentID", S(parent));
    const query = try db.query("SELECT id,type,data FROM session_message WHERE session_id=? ORDER BY seq ASC", id);
    defer _ = sql.sqlite3_finalize(query);
    var messages = Values.init(a);
    while (true) {
        const step = sql.sqlite3_step(query);
        if (step == sql.SQLITE_DONE) break;
        if (step != sql.SQLITE_ROW) return error.OpenCodeQueryFailed;
        var value = try db.value(query, 2);
        if (value != .object) return error.MalformedOpenCodeMessage;
        try C.set(a, &value, "id", S(try db.string(query, 0)));
        try C.set(a, &value, "type", S(try db.string(query, 1)));
        try messages.append(value);
    }
    return C.obj(a, &.{ .{ "info", info }, .{ "messages", try C.arr(a, messages.items) } });
}
const columns = "id,title,directory,time_created,time_updated,parent_id,metadata,time_archived,project_id,cost,tokens_input,tokens_output,tokens_reasoning,tokens_cache_read,tokens_cache_write";
pub fn readNative(a: A, home: []const u8, id: []const u8) !?V {
    const path = try C.join(a, &.{ home, "opencode.db" });
    if (!C.exists(path)) return null;
    var db = try Database.open(a, path);
    defer db.close();
    const query = try db.query("SELECT " ++ columns ++ " FROM session_v2 WHERE id=?", id);
    defer _ = sql.sqlite3_finalize(query);
    const step = sql.sqlite3_step(query);
    if (step == sql.SQLITE_DONE) return null;
    if (step != sql.SQLITE_ROW) return error.OpenCodeQueryFailed;
    return try rowNative(a, &db, query);
}
pub fn nativeFingerprint(a: A, home: []const u8, id: []const u8) !?[]const u8 {
    return if (try readNative(a, home, id)) |value| try codec.fingerprint(a, value, false) else null;
}
pub fn readOrigin(a: A, thread: C.Thread) !codec.Origin {
    const home = std.fs.path.dirname(thread.rollout_path) orelse return error.InvalidOpenCodeSourcePath;
    return if (try readNative(a, home, thread.id)) |data| codec.origin(a, data) else .{};
}
pub fn listThreads(a: A, home: []const u8) ![]C.Thread {
    const path = try C.join(a, &.{ home, "opencode.db" });
    var out = std.array_list.Managed(C.Thread).init(a);
    if (!C.exists(path)) return out.toOwnedSlice();
    var db = try Database.open(a, path);
    defer db.close();
    const query = try db.query("SELECT " ++ columns ++ " FROM session_v2 WHERE EXISTS (SELECT 1 FROM session_message WHERE session_message.session_id=session_v2.id) ORDER BY time_updated DESC", null);
    defer _ = sql.sqlite3_finalize(query);
    while (true) {
        const step = sql.sqlite3_step(query);
        if (step == sql.SQLITE_DONE) break;
        if (step != sql.SQLITE_ROW) return error.OpenCodeQueryFailed;
        // Discard each decoded transcript after checking provenance.
        var row_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer row_arena.deinit();
        const row_a = row_arena.allocator();
        var row_db = db;
        row_db.a = row_a;
        const marker = C.get(try row_db.value(query, 6), "c2c");
        const imported = if (C.s(marker, "sourceProvider").len > 0 and C.s(marker, "sourceSessionId").len > 0)
            try codec.origin(row_a, try rowNative(row_a, &row_db, query))
        else
            codec.Origin{};
        const parent = try row_db.string(query, 5);
        try out.append(.{ .id = try db.string(query, 0), .title = try db.string(query, 1), .cwd = try db.string(query, 2), .rollout_path = path, .created_at = try C.timestamp(a, sql.sqlite3_column_int64(query, 3)), .updated_at = try C.timestamp(a, sql.sqlite3_column_int64(query, 4)), .parent_id = if (parent.len > 0) try a.dupe(u8, parent) else null, .provider = "opencode", .source = "cli", .archived = sql.sqlite3_column_type(query, 7) != sql.SQLITE_NULL, .origin_provider = if (imported.provider) |value| try a.dupe(u8, value) else null, .origin_id = if (imported.original_id) |value| try a.dupe(u8, value) else null, .unchanged_import = imported.unchanged });
    }
    return out.toOwnedSlice();
}

pub fn readEntries(a: A, thread: C.Thread, warnings: *C.Warnings) ![]V {
    const home = std.fs.path.dirname(thread.rollout_path) orelse return error.InvalidOpenCodeSourcePath;
    const data = (try readNative(a, home, thread.id)) orelse return error.OpenCodeSessionMissing;
    return codec.readDataEntries(a, data, warnings);
}

fn environment(a: A, home: []const u8) ![]C.Env {
    const runtime = try C.join(a, &.{ home, ".c2c-runtime" });
    try C.mkdirAll(runtime);
    const config = try C.join(a, &.{ runtime, "config" });
    try C.mkdirAll(config);
    return a.dupe(C.Env, &.{ .{ "OPENCODE_DB", try C.join(a, &.{ home, "opencode.db" }) }, .{ "HOME", runtime }, .{ "XDG_DATA_HOME", try C.join(a, &.{ runtime, "data" }) }, .{ "XDG_STATE_HOME", try C.join(a, &.{ runtime, "state" }) }, .{ "XDG_CACHE_HOME", try C.join(a, &.{ runtime, "cache" }) }, .{ "XDG_CONFIG_HOME", config }, .{ "OPENCODE_CONFIG_DIR", config }, .{ "OPENCODE_CONFIG", "" }, .{ "OPENCODE_CONFIG_CONTENT", "{\"plugins\":[],\"mcp\":{},\"update\":\"disable\",\"share\":\"disabled\",\"warming\":false}" }, .{ "OPENCODE_DISABLE_PROJECT_CONFIG", "1" }, .{ "OPENCODE_DISABLE_MODELS_FETCH", "1" }, .{ "OPENCODE_DISABLE_FILEWATCHER", "1" }, .{ "DO_NOT_TRACK", "1" } });
}
fn binary() []const u8 {
    return if (C.c.getenv("C2C_OPENCODE_BINARY")) |value| std.mem.span(value) else "opencode";
}
fn requireVersion(a: A, env: []const C.Env) ![]const u8 {
    const result = try C.run(a, &.{ binary(), "--version" }, env, null, 20_000);
    if (result.exit_code != 0 or std.mem.indexOf(u8, result.stdout, "v2.") == null)
        return error.OpenCodeV2Required;
    return std.mem.trim(u8, result.stdout, " \r\n\t");
}
pub fn register(a: A, home: []const u8, id: []const u8, title: []const u8) !V {
    _ = title;
    const path = try codec.receiptPath(a, home, id);
    const staged = try C.parse(a, try C.readFile(a, path));
    if (!C.eq(C.s(C.get(staged, "info"), "id"), id)) return error.OpenCodeReceiptIdentityMismatch;
    const env = try environment(a, home);
    const version = try requireVersion(a, env);
    if (try readNative(a, home, id)) |existing| {
        if (!(try codec.registrationMatches(a, &.{staged}, existing))) return error.OpenCodeSessionCollision;
    } else {
        const result = try C.run(a, &.{ binary(), "session", "import", "--standalone", "--directory", C.s(C.get(C.get(staged, "info"), "location"), "directory"), path }, env, null, 120_000);
        if (result.exit_code != 0) return error.OpenCodeNativeImportFailed;
        const imported = (try readNative(a, home, id)) orelse return error.OpenCodeImportDidNotCreateSession;
        if (!(try codec.registrationMatches(a, &.{staged}, imported))) return error.OpenCodeNativeImportMismatch;
    }
    return C.obj(a, &.{ .{ "status", S("registered") }, .{ "session_id", S(id) }, .{ "native_version", S(version) } });
}
pub fn unregister(a: A, home: []const u8, id: []const u8) !void {
    const native = (try readNative(a, home, id)) orelse return;
    if (!(try codec.origin(a, native)).unchanged) return error.OpenCodeSessionChanged;
    // Native delete cascades; refuse sessions with forks or other child conversations.
    var db = try Database.open(a, try C.join(a, &.{ home, "opencode.db" }));
    const query = try db.query("SELECT id FROM session_v2 WHERE parent_id=? LIMIT 1", id);
    const child_step = sql.sqlite3_step(query);
    _ = sql.sqlite3_finalize(query);
    db.close();
    if (child_step == sql.SQLITE_ROW) return error.OpenCodeSessionHasChildren;
    if (child_step != sql.SQLITE_DONE) return error.OpenCodeQueryFailed;
    const env = try environment(a, home);
    _ = try requireVersion(a, env);
    const result = try C.run(a, &.{ binary(), "session", "delete", "--standalone", id }, env, null, 120_000);
    if (result.exit_code != 0 or (try readNative(a, home, id)) != null) return error.OpenCodeNativeDeleteFailed;
}

test "OpenCode missing database has no native sessions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect((try readNative(a, "/tmp/c2c-no-such-opencode-database", "fixture")) == null);
    try std.testing.expectEqual(@as(usize, 0), (try listThreads(a, "/tmp/c2c-no-such-opencode-database")).len);
}
