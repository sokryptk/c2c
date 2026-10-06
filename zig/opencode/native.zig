const std = @import("std");
const common = @import("../common.zig");
const Allocator = common.Allocator;
const Value = common.Value;
const jsonString = common.str;
const jsonInteger = common.num;
const Values = std.array_list.Managed(Value);
const codec = @import("codec.zig");
const reader = @import("read.zig");
const sql = @cImport({
    @cInclude("sqlite3.h");
});

const Database = struct {
    handle: ?*sql.sqlite3,
    allocator: Allocator,

    fn open(allocator: Allocator, path: []const u8) !Database {
        var handle: ?*sql.sqlite3 = null;
        if (sql.sqlite3_open_v2(try allocator.dupeZ(u8, path), &handle, sql.SQLITE_OPEN_READONLY, null) != sql.SQLITE_OK) {
            if (handle != null) {
                _ = sql.sqlite3_close(handle);
            }
            return error.OpenCodeDatabaseUnavailable;
        }
        errdefer _ = sql.sqlite3_close(handle);
        _ = sql.sqlite3_busy_timeout(handle, 5000);
        if (sql.sqlite3_exec(handle, "BEGIN", null, null, null) != sql.SQLITE_OK) {
            return error.OpenCodeSnapshotFailed;
        }
        return .{
            .handle = handle,
            .allocator = allocator,
        };
    }

    fn close(self: *Database) void {
        _ = sql.sqlite3_close(self.handle);
    }

    fn query(self: *Database, text: [:0]const u8, id: ?[]const u8) !?*sql.sqlite3_stmt {
        var statement: ?*sql.sqlite3_stmt = null;
        if (sql.sqlite3_prepare_v2(self.handle, text.ptr, -1, &statement, null) != sql.SQLITE_OK) {
            return error.UnsupportedOpenCodeDatabaseSchema;
        }
        errdefer _ = sql.sqlite3_finalize(statement);
        if (id) |identifier| {
            const owned = try self.allocator.dupeZ(u8, identifier);
            if (sql.sqlite3_bind_text(statement, 1, owned.ptr, @intCast(identifier.len), null) != sql.SQLITE_OK) {
                return error.OpenCodeQueryFailed;
            }
        }
        return statement;
    }

    fn string(self: *Database, statement: ?*sql.sqlite3_stmt, col: c_int) ![]const u8 {
        const ptr = sql.sqlite3_column_text(statement, col);
        if (ptr == null) {
            return "";
        }
        const length: usize = @intCast(sql.sqlite3_column_bytes(statement, col));
        return self.allocator.dupe(u8, ptr[0..length]);
    }

    fn value(self: *Database, statement: ?*sql.sqlite3_stmt, col: c_int) !Value {
        const text = try self.string(statement, col);
        if (text.len == 0) {
            return .null;
        }
        return common.parse(self.allocator, text);
    }
};

fn rowNative(allocator: Allocator, db: *Database, statement: ?*sql.sqlite3_stmt) !Value {
    const id = try db.string(statement, 0);
    var time = try common.obj(allocator, &.{
        .{ "created", jsonInteger(sql.sqlite3_column_int64(statement, 3)) },
        .{ "updated", jsonInteger(sql.sqlite3_column_int64(statement, 4)) },
    });
    if (sql.sqlite3_column_type(statement, 7) != sql.SQLITE_NULL) {
        try common.set(allocator, &time, "archived", jsonInteger(sql.sqlite3_column_int64(statement, 7)));
    }

    const title = try db.string(statement, 1);
    const location = try common.obj(allocator, &.{
        .{ "directory", jsonString(try db.string(statement, 2)) },
    });
    const metadata = try db.value(statement, 6);
    const project_id = try db.string(statement, 8);
    const cost = sql.sqlite3_column_double(statement, 9);
    const input_tokens = sql.sqlite3_column_int64(statement, 10);
    const output_tokens = sql.sqlite3_column_int64(statement, 11);
    const reasoning_tokens = sql.sqlite3_column_int64(statement, 12);
    const cache = try common.obj(allocator, &.{
        .{ "read", jsonInteger(sql.sqlite3_column_int64(statement, 13)) },
        .{ "write", jsonInteger(sql.sqlite3_column_int64(statement, 14)) },
    });
    const tokens = try common.obj(allocator, &.{
        .{ "input", jsonInteger(input_tokens) },
        .{ "output", jsonInteger(output_tokens) },
        .{ "reasoning", jsonInteger(reasoning_tokens) },
        .{ "cache", cache },
    });
    var info = try common.obj(allocator, &.{
        .{ "id", jsonString(id) },
        .{ "title", jsonString(title) },
        .{ "location", location },
        .{ "time", time },
        .{ "metadata", metadata },
        .{ "projectID", jsonString(project_id) },
        .{ "cost", .{ .float = cost } },
        .{ "tokens", tokens },
    });
    const parent = try db.string(statement, 5);
    if (parent.len > 0) {
        try common.set(allocator, &info, "parentID", jsonString(parent));
    }

    const query = try db.query("SELECT id,type,data FROM session_message WHERE session_id=? ORDER BY seq ASC", id);
    defer _ = sql.sqlite3_finalize(query);
    var messages = Values.init(allocator);
    while (true) {
        const step = sql.sqlite3_step(query);
        if (step == sql.SQLITE_DONE) {
            break;
        }
        if (step != sql.SQLITE_ROW) {
            return error.OpenCodeQueryFailed;
        }
        var value = try db.value(query, 2);
        if (value != .object) {
            return error.MalformedOpenCodeMessage;
        }
        try common.set(allocator, &value, "id", jsonString(try db.string(query, 0)));
        try common.set(allocator, &value, "type", jsonString(try db.string(query, 1)));
        try messages.append(value);
    }
    return common.obj(allocator, &.{
        .{ "info", info },
        .{ "messages", try common.arr(allocator, messages.items) },
    });
}

const columns = "id,title,directory,time_created,time_updated,parent_id,metadata,time_archived," ++
    "project_id,cost,tokens_input,tokens_output,tokens_reasoning,tokens_cache_read,tokens_cache_write";

pub fn readNative(allocator: Allocator, home: []const u8, id: []const u8) !?Value {
    const path = try common.join(allocator, &.{ home, "opencode.db" });
    if (!common.exists(path)) {
        return null;
    }
    var db = try Database.open(allocator, path);
    defer db.close();
    const query = try db.query("SELECT " ++ columns ++ " FROM session_v2 WHERE id=?", id);
    defer _ = sql.sqlite3_finalize(query);
    const step = sql.sqlite3_step(query);
    if (step == sql.SQLITE_DONE) {
        return null;
    }
    if (step != sql.SQLITE_ROW) {
        return error.OpenCodeQueryFailed;
    }
    return try rowNative(allocator, &db, query);
}

pub fn nativeFingerprint(allocator: Allocator, home: []const u8, id: []const u8) !?[]const u8 {
    if (try readNative(allocator, home, id)) |value| {
        return try codec.fingerprint(allocator, value, false);
    }
    return null;
}

pub fn readOrigin(allocator: Allocator, thread: common.Thread) !codec.Origin {
    const home = std.fs.path.dirname(thread.rollout_path) orelse return error.InvalidOpenCodeSourcePath;
    if (try readNative(allocator, home, thread.id)) |data| {
        return codec.origin(allocator, data);
    }
    return .{};
}

pub fn listThreads(allocator: Allocator, home: []const u8) ![]common.Thread {
    const path = try common.join(allocator, &.{ home, "opencode.db" });
    var out = std.array_list.Managed(common.Thread).init(allocator);
    if (!common.exists(path)) {
        return out.toOwnedSlice();
    }
    var db = try Database.open(allocator, path);
    defer db.close();
    const query = try db.query(
        "SELECT " ++ columns ++ " FROM session_v2 WHERE EXISTS " ++
            "(SELECT 1 FROM session_message WHERE session_message.session_id=session_v2.id) " ++
            "ORDER BY time_updated DESC",
        null,
    );
    defer _ = sql.sqlite3_finalize(query);
    while (true) {
        const step = sql.sqlite3_step(query);
        if (step == sql.SQLITE_DONE) {
            break;
        }
        if (step != sql.SQLITE_ROW) {
            return error.OpenCodeQueryFailed;
        }
        // Discard each decoded transcript after checking provenance.
        var row_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer row_arena.deinit();
        const row_a = row_arena.allocator();
        var row_db = db;
        row_db.allocator = row_a;
        const metadata = try row_db.value(query, 6);
        const marker = common.get(metadata, "c2c");
        var imported = codec.Origin{};
        if (common.stringField(marker, "sourceProvider").len > 0 and common.stringField(marker, "sourceSessionId").len > 0) {
            const data = try rowNative(row_a, &row_db, query);
            imported = try codec.origin(row_a, data);
        }
        const parent = try row_db.string(query, 5);
        const thread = common.Thread{
            .id = try db.string(query, 0),
            .title = try db.string(query, 1),
            .cwd = try db.string(query, 2),
            .rollout_path = path,
            .created_at = try common.timestamp(allocator, sql.sqlite3_column_int64(query, 3)),
            .updated_at = try common.timestamp(allocator, sql.sqlite3_column_int64(query, 4)),
            .parent_id = if (parent.len > 0) try allocator.dupe(u8, parent) else null,
            .provider = "opencode",
            .source = "cli",
            .archived = sql.sqlite3_column_type(query, 7) != sql.SQLITE_NULL,
            .origin_provider = if (imported.provider) |value| try allocator.dupe(u8, value) else null,
            .origin_id = if (imported.original_id) |value| try allocator.dupe(u8, value) else null,
            .unchanged_import = imported.unchanged,
        };
        try out.append(thread);
    }
    return out.toOwnedSlice();
}

pub fn readEntries(allocator: Allocator, thread: common.Thread, warnings: *common.Warnings) ![]Value {
    const home = std.fs.path.dirname(thread.rollout_path) orelse return error.InvalidOpenCodeSourcePath;
    const data = (try readNative(allocator, home, thread.id)) orelse return error.OpenCodeSessionMissing;
    return reader.readDataEntries(allocator, data, warnings);
}

fn environment(allocator: Allocator, home: []const u8) ![]common.Env {
    const runtime = try common.join(allocator, &.{ home, ".c2c-runtime" });
    try common.mkdirAll(runtime);
    const config = try common.join(allocator, &.{ runtime, "config" });
    try common.mkdirAll(config);
    return allocator.dupe(common.Env, &.{
        .{ "OPENCODE_DB", try common.join(allocator, &.{ home, "opencode.db" }) },
        .{ "HOME", runtime },
        .{ "XDG_DATA_HOME", try common.join(allocator, &.{ runtime, "data" }) },
        .{ "XDG_STATE_HOME", try common.join(allocator, &.{ runtime, "state" }) },
        .{ "XDG_CACHE_HOME", try common.join(allocator, &.{ runtime, "cache" }) },
        .{ "XDG_CONFIG_HOME", config },
        .{ "OPENCODE_CONFIG_DIR", config },
        .{ "OPENCODE_CONFIG", "" },
        .{
            "OPENCODE_CONFIG_CONTENT",
            "{\"plugins\":[],\"mcp\":{},\"update\":\"disable\"," ++
                "\"share\":\"disabled\",\"warming\":false}",
        },
        .{ "OPENCODE_DISABLE_PROJECT_CONFIG", "1" },
        .{ "OPENCODE_DISABLE_MODELS_FETCH", "1" },
        .{ "OPENCODE_DISABLE_FILEWATCHER", "1" },
        .{ "DO_NOT_TRACK", "1" },
    });
}

fn binary() []const u8 {
    if (common.c.getenv("C2C_OPENCODE_BINARY")) |value| {
        return std.mem.span(value);
    }
    return "opencode";
}

fn requireVersion(allocator: Allocator, env: []const common.Env) ![]const u8 {
    const result = try common.run(allocator, &.{ binary(), "--version" }, env, null, 20_000);
    if (result.exit_code != 0 or std.mem.indexOf(u8, result.stdout, "v2.") == null) {
        return error.OpenCodeV2Required;
    }
    return std.mem.trim(u8, result.stdout, " \r\n\t");
}

pub fn register(allocator: Allocator, home: []const u8, id: []const u8, title: []const u8) !Value {
    _ = title;
    const path = try codec.receiptPath(allocator, home, id);
    const receipt = try common.readFile(allocator, path);
    const staged = try common.parse(allocator, receipt);
    const info = common.get(staged, "info");
    if (!common.eq(common.stringField(info, "id"), id)) {
        return error.OpenCodeReceiptIdentityMismatch;
    }
    const env = try environment(allocator, home);
    const version = try requireVersion(allocator, env);
    if (try readNative(allocator, home, id)) |existing| {
        if (!(try codec.registrationMatches(allocator, &.{staged}, existing))) {
            return error.OpenCodeSessionCollision;
        }
    } else {
        const location = common.get(info, "location");
        const result = try common.run(allocator, &.{
            binary(),
            "session",
            "import",
            "--standalone",
            "--directory",
            common.stringField(location, "directory"),
            path,
        }, env, null, 120_000);
        if (result.exit_code != 0) {
            return error.OpenCodeNativeImportFailed;
        }
        const imported = (try readNative(allocator, home, id)) orelse return error.OpenCodeImportDidNotCreateSession;
        if (!(try codec.registrationMatches(allocator, &.{staged}, imported))) {
            return error.OpenCodeNativeImportMismatch;
        }
    }
    return common.obj(allocator, &.{
        .{ "status", jsonString("registered") },
        .{ "session_id", jsonString(id) },
        .{ "native_version", jsonString(version) },
    });
}

pub fn unregister(allocator: Allocator, home: []const u8, id: []const u8) !void {
    const native = (try readNative(allocator, home, id)) orelse return;
    if (!(try codec.origin(allocator, native)).unchanged) {
        return error.OpenCodeSessionChanged;
    }
    // Native delete cascades; refuse sessions with forks or other child conversations.
    var db = try Database.open(allocator, try common.join(allocator, &.{ home, "opencode.db" }));
    const query = try db.query("SELECT id FROM session_v2 WHERE parent_id=? LIMIT 1", id);
    const child_step = sql.sqlite3_step(query);
    _ = sql.sqlite3_finalize(query);
    db.close();
    if (child_step == sql.SQLITE_ROW) {
        return error.OpenCodeSessionHasChildren;
    }
    if (child_step != sql.SQLITE_DONE) {
        return error.OpenCodeQueryFailed;
    }
    const env = try environment(allocator, home);
    _ = try requireVersion(allocator, env);
    const result = try common.run(allocator, &.{ binary(), "session", "delete", "--standalone", id }, env, null, 120_000);
    if (result.exit_code != 0 or (try readNative(allocator, home, id)) != null) {
        return error.OpenCodeNativeDeleteFailed;
    }
}

test "OpenCode missing database has no native sessions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expect((try readNative(allocator, "/tmp/c2c-no-such-opencode-database", "fixture")) == null);
    try std.testing.expectEqual(@as(usize, 0), (try listThreads(allocator, "/tmp/c2c-no-such-opencode-database")).len);
}
