const std = @import("std");
const common = @import("../../common.zig");
pub const sqlite = @cImport({
    @cInclude("sqlite3.h");
});

const expectEqual = std.testing.expectEqual;
pub const timestamp = "2026-01-01T00:00:00.000Z";

const HistoryRow = struct {
    ordinal: i64,
    json: []const u8,
};

const Cursor = struct {
    offset: usize,
    ordinal: i64,
};

pub const Fixture = struct {
    allocator: common.Allocator,
    temporary_directory: std.testing.TmpDir,
    home: []const u8,
    thread: common.Thread,

    pub fn init(allocator: common.Allocator) !Fixture {
        var temporary_directory = std.testing.tmpDir(.{});
        errdefer temporary_directory.cleanup();
        const home = try temporary_directory.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        try temporary_directory.dir.createDirPath(std.testing.io, "sessions");
        return .{
            .allocator = allocator,
            .temporary_directory = temporary_directory,
            .home = home,
            .thread = .{
                .id = "thread-1",
                .title = "Synthetic thread",
                .cwd = "/project",
                .created_at = timestamp,
                .updated_at = timestamp,
                .rollout_path = try common.join(allocator, &.{ home, "sessions", "rollout.jsonl" }),
            },
        };
    }

    pub fn deinit(self: *Fixture) void {
        self.temporary_directory.cleanup();
    }

    pub fn rollout(self: *Fixture, data: []const u8) !void {
        try self.temporary_directory.dir.writeFile(std.testing.io, .{
            .sub_path = "sessions/rollout.jsonl",
            .data = data,
        });
    }

    pub fn records(self: *Fixture, values: []const common.Value) !void {
        var data = std.array_list.Managed(u8).init(self.allocator);
        for (values) |value| {
            try data.appendSlice(try common.json(self.allocator, value));
            try data.append('\n');
        }
        try self.rollout(data.items);
    }

    pub fn history(self: *Fixture, rows: []const HistoryRow, cursor: ?Cursor) !void {
        const path = try common.join(self.allocator, &.{ self.home, "thread_history_1.sqlite" });
        const database_path = try self.allocator.dupeZ(u8, path);
        var database: ?*sqlite.sqlite3 = null;
        try expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_open(database_path, &database));
        defer _ = sqlite.sqlite3_close(database);
        try sql(
            database,
            "CREATE TABLE thread_items (thread_id TEXT, item_id TEXT, item_json TEXT, created_at_ms " ++
                "INTEGER, rollout_ordinal INTEGER);" ++
                "CREATE TABLE thread_history_projection_state (thread_id TEXT, next_rollout_byte_offset " ++
                "INTEGER, next_rollout_ordinal INTEGER);",
        );
        var statement: ?*sqlite.sqlite3_stmt = null;
        const insert_query = "INSERT INTO thread_items VALUES ('thread-1', ?, ?, 1767225600123, ?)";
        const prepare_result = sqlite.sqlite3_prepare_v2(database, insert_query, -1, &statement, null);
        try expectEqual(sqlite.SQLITE_OK, prepare_result);
        defer _ = sqlite.sqlite3_finalize(statement);
        for (rows) |row| {
            const parsed = try common.parse(self.allocator, row.json);
            const supplied_id = common.stringField(parsed, "id");
            const id = if (supplied_id.len != 0)
                supplied_id
            else
                try common.fmt(self.allocator, "item-{d}", .{row.ordinal});
            try expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_bind_text(statement, 1, id.ptr, @intCast(id.len), null));
            try expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_bind_text(
                statement,
                2,
                row.json.ptr,
                @intCast(row.json.len),
                null,
            ));
            try expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_bind_int64(statement, 3, row.ordinal));
            try expectEqual(sqlite.SQLITE_DONE, sqlite.sqlite3_step(statement));
            try expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_reset(statement));
            try expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_clear_bindings(statement));
        }
        if (cursor) |projection_cursor| {
            const query = try common.fmt(
                self.allocator,
                "INSERT INTO thread_history_projection_state VALUES ('thread-1', {d}, {d})",
                .{ projection_cursor.offset, projection_cursor.ordinal },
            );
            try sql(database, try self.allocator.dupeZ(u8, query));
        }
    }
};

pub fn sql(database: ?*sqlite.sqlite3, query: [:0]const u8) !void {
    const result = sqlite.sqlite3_exec(database, query.ptr, null, null, null);
    if (result != sqlite.SQLITE_OK) {
        std.debug.print("synthetic SQLite fixture failed: {s}\n", .{sqlite.sqlite3_errmsg(database)});
    }
    try expectEqual(sqlite.SQLITE_OK, result);
}

pub fn record(allocator: common.Allocator, kind: []const u8, ordinal: i64, payload: common.Value) !common.Value {
    return common.obj(allocator, &.{
        .{ "type", common.str(kind) },
        .{ "ordinal", common.num(ordinal) },
        .{ "payload", payload },
    });
}
