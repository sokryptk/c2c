const std = @import("std");
const common = @import("../common.zig");
const Allocator = common.Allocator;
const Value = common.Value;
const eq = common.eq;
const sql = @cImport({
    @cInclude("sqlite3.h");
});

fn expanded(allocator: Allocator, value: []const u8) ![]const u8 {
    if (eq(value, "~") or std.mem.startsWith(u8, value, "~/")) {
        if (common.c.getenv("HOME")) |home| {
            const relative_path = if (value.len > 2) value[2..] else "";
            return common.join(allocator, &.{ std.mem.span(home), relative_path });
        }
    }
    return allocator.dupe(u8, value);
}

pub fn absolute(allocator: Allocator, value: []const u8, cwd: []const u8) ![]const u8 {
    const path = try expanded(allocator, value);
    if (std.fs.path.isAbsolute(path) or cwd.len == 0) {
        return path;
    }
    return common.join(allocator, &.{ cwd, path });
}

pub fn canonical(allocator: Allocator, value: []const u8) ![]const u8 {
    const path = try expanded(allocator, value);
    const path_z = try allocator.dupeZ(u8, path);
    if (common.c.realpath(path_z, null)) |resolved_path| {
        defer common.c.free(resolved_path);
        return allocator.dupe(u8, std.mem.span(resolved_path));
    }
    if (std.fs.path.isAbsolute(path)) {
        return path;
    }
    const cwd = common.c.getcwd(null, 0) orelse return error.CurrentDirectoryUnavailable;
    defer common.c.free(cwd);
    return common.join(allocator, &.{ std.mem.span(cwd), path });
}

/// Read a fixed-size snapshot. getline storage and each parsed record are
/// released independently of the caller's retained conversation allocator.
pub const Records = struct {
    file: *common.c.FILE,
    buffer: [*c]u8 = null,
    capacity: usize = 0,
    end: u64,
    position: u64,
    ordinal: i64,
    arena: std.heap.ArenaAllocator,
    allocator: Allocator,
    warnings: *common.Warnings,
    compactions_only: bool = false,

    pub const Record = struct {
        ordinal: i64,
        value: Value,
    };

    pub fn open(
        allocator: Allocator,
        path: []const u8,
        offset: u64,
        ordinal: i64,
        warnings: *common.Warnings,
    ) !Records {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        const file = common.c.fopen(path_z, "rb") orelse return error.SourceFileUnavailable;
        errdefer _ = common.c.fclose(file);
        if (common.c.fseeko(file, 0, common.c.SEEK_END) != 0) {
            return error.SourceReadFailed;
        }
        const end = common.c.ftello(file);
        if (end < 0) {
            return error.SourceReadFailed;
        }
        if (offset > @as(u64, @intCast(end))) {
            return error.ProjectionPastRollout;
        }
        if (common.c.fseeko(file, @intCast(offset), common.c.SEEK_SET) != 0) {
            return error.SourceReadFailed;
        }
        return .{
            .file = file,
            .end = @intCast(end),
            .position = offset,
            .ordinal = ordinal,
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .allocator = allocator,
            .warnings = warnings,
        };
    }

    pub fn close(self: *Records) void {
        self.arena.deinit();
        if (self.buffer != null) {
            common.c.free(self.buffer);
        }
        _ = common.c.fclose(self.file);
    }

    pub fn next(self: *Records) !?Record {
        while (self.position < self.end) {
            const count = common.c.getline(&self.buffer, &self.capacity, self.file);
            if (count < 0) {
                return error.SourceReadFailed;
            }
            const bytes_read: u64 = @intCast(count);
            const snapshot_remaining = self.end - self.position;
            const length: usize = @intCast(@min(bytes_read, snapshot_remaining));
            self.position += length;
            const ordinal = self.ordinal;
            self.ordinal += 1;
            const line = self.buffer[0..length];
            if (std.mem.trim(u8, line, " \t\r\n").len == 0) {
                continue;
            }
            // The later root-type check rejects JSON embedded in output text.
            if (self.compactions_only) {
                const prefix = line[0..@min(512, line.len)];
                if (std.mem.indexOf(u8, prefix, "compacted") == null) {
                    continue;
                }
            }
            _ = self.arena.reset(.retain_capacity);
            const value = common.parse(self.arena.allocator(), line) catch {
                if (self.position == self.end and line[line.len - 1] != '\n') {
                    const warning = try common.fmt(
                        self.allocator,
                        "Incomplete final rollout record; retry after the writer finishes",
                        .{},
                    );
                    try self.warnings.append(warning);
                    return null;
                }
                return error.MalformedSourceJson;
            };
            if (value != .object) {
                return error.ExpectedSourceObject;
            }
            const explicit_ordinal = common.get(value, "ordinal");
            return .{
                .ordinal = if (explicit_ordinal == .integer) explicit_ordinal.integer else ordinal,
                .value = value,
            };
        }
        return null;
    }
};

pub const Database = struct {
    handle: *sql.sqlite3,

    pub fn open(allocator: Allocator, path: []const u8) !Database {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        var handle: ?*sql.sqlite3 = null;
        const open_result = sql.sqlite3_open_v2(path_z, &handle, sql.SQLITE_OPEN_READONLY, null);
        if (open_result != sql.SQLITE_OK) {
            if (handle) |db| {
                _ = sql.sqlite3_close(db);
            }
            return error.SourceDatabaseUnavailable;
        }
        const self = Database{ .handle = handle.? };
        errdefer self.close();
        try self.exec("PRAGMA query_only=ON");
        try self.exec("BEGIN");
        return self;
    }

    pub fn close(self: Database) void {
        _ = sql.sqlite3_close(self.handle);
    }

    fn exec(self: Database, query: [:0]const u8) !void {
        const result = sql.sqlite3_exec(self.handle, query, null, null, null);
        if (result != sql.SQLITE_OK) {
            return error.SourceDatabaseQueryFailed;
        }
    }

    pub fn prepare(self: Database, query: [:0]const u8) !Statement {
        var statement: ?*sql.sqlite3_stmt = null;
        const result = sql.sqlite3_prepare_v2(self.handle, query, -1, &statement, null);
        if (result != sql.SQLITE_OK) {
            return error.SourceDatabaseQueryFailed;
        }
        return .{ .handle = statement.? };
    }

    pub fn hasTable(self: Database, name: []const u8) !bool {
        const statement = try self.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?");
        defer statement.close();
        try statement.bind(1, name);
        return statement.next();
    }
};

const Statement = struct {
    handle: *sql.sqlite3_stmt,

    pub fn close(self: Statement) void {
        _ = sql.sqlite3_finalize(self.handle);
    }

    pub fn bind(self: Statement, index: c_int, value: []const u8) !void {
        const result = sql.sqlite3_bind_text(self.handle, index, value.ptr, @intCast(value.len), null);
        if (result != sql.SQLITE_OK) {
            return error.SourceDatabaseQueryFailed;
        }
    }

    pub fn next(self: Statement) !bool {
        return switch (sql.sqlite3_step(self.handle)) {
            sql.SQLITE_ROW => true,
            sql.SQLITE_DONE => false,
            else => error.SourceDatabaseQueryFailed,
        };
    }

    pub fn text(self: Statement, index: c_int) []const u8 {
        const column_text = sql.sqlite3_column_text(self.handle, index);
        if (column_text == null) {
            return "";
        }
        const length: usize = @intCast(sql.sqlite3_column_bytes(self.handle, index));
        return column_text[0..length];
    }

    pub fn int(self: Statement, index: c_int) i64 {
        return sql.sqlite3_column_int64(self.handle, index);
    }

    pub fn row(self: Statement, allocator: Allocator) !Value {
        var value = try common.obj(allocator, &.{});
        var index: c_int = 0;
        while (index < sql.sqlite3_column_count(self.handle)) : (index += 1) {
            const name = try allocator.dupe(u8, std.mem.span(sql.sqlite3_column_name(self.handle, index)));
            const column: Value = switch (sql.sqlite3_column_type(self.handle, index)) {
                sql.SQLITE_NULL => .null,
                sql.SQLITE_INTEGER => common.num(self.int(index)),
                sql.SQLITE_FLOAT => .{ .float = sql.sqlite3_column_double(self.handle, index) },
                else => common.str(try allocator.dupe(u8, self.text(index))),
            };
            try common.set(allocator, &value, name, column);
        }
        return value;
    }
};

pub fn latestDatabase(allocator: Allocator, home: []const u8, stem: []const u8) !?[]const u8 {
    if (!common.exists(home)) {
        return null;
    }
    const prefix = try common.fmt(allocator, "{s}_", .{stem});
    var selected: ?[]const u8 = null;
    var version: u64 = 0;
    for (try common.listDir(allocator, home)) |entry| {
        if (entry.is_dir or
            !std.mem.startsWith(u8, entry.name, prefix) or
            !std.mem.endsWith(u8, entry.name, ".sqlite"))
        {
            continue;
        }
        const digits = entry.name[prefix.len .. entry.name.len - ".sqlite".len];
        if (digits.len == 0) {
            continue;
        }
        var numeric = true;
        for (digits) |digit| {
            if (!std.ascii.isDigit(digit)) {
                numeric = false;
            }
        }
        if (!numeric) {
            continue;
        }
        const candidate = std.fmt.parseInt(u64, digits, 10) catch continue;
        if (selected == null or candidate > version) {
            version = candidate;
            selected = try common.join(allocator, &.{ home, entry.name });
        }
    }
    return selected;
}
