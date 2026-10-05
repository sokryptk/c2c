const std = @import("std");
const H = @import("../common.zig");
const A = H.Allocator;
const V = H.Value;
const eq = H.eq;
const sql = @cImport({
    @cInclude("sqlite3.h");
});

fn expanded(a: A, value: []const u8) ![]const u8 {
    if (eq(value, "~") or std.mem.startsWith(u8, value, "~/")) {
        if (H.c.getenv("HOME")) |home| return H.join(a, &.{ std.mem.span(home), if (value.len > 2) value[2..] else "" });
    }
    return a.dupe(u8, value);
}
pub fn absolute(a: A, value: []const u8, cwd: []const u8) ![]const u8 {
    const path = try expanded(a, value);
    return if (std.fs.path.isAbsolute(path) or cwd.len == 0) path else H.join(a, &.{ cwd, path });
}
pub fn canonical(a: A, value: []const u8) ![]const u8 {
    const path = try expanded(a, value);
    const z = try a.dupeZ(u8, path);
    if (H.c.realpath(z, null)) |resolved_path| {
        defer H.c.free(resolved_path);
        return a.dupe(u8, std.mem.span(resolved_path));
    }
    if (std.fs.path.isAbsolute(path)) return path;
    const cwd = H.c.getcwd(null, 0) orelse return error.CurrentDirectoryUnavailable;
    defer H.c.free(cwd);
    return H.join(a, &.{ std.mem.span(cwd), path });
}

/// Read a fixed-size snapshot. getline storage and each parsed record are
/// released independently of the caller's retained conversation allocator.
pub const Records = struct {
    file: *H.c.FILE,
    buffer: [*c]u8 = null,
    capacity: usize = 0,
    end: u64,
    position: u64,
    ordinal: i64,
    arena: std.heap.ArenaAllocator,
    allocator: A,
    warnings: *H.Warnings,
    compactions_only: bool = false,

    pub const Record = struct { ordinal: i64, value: V };

    pub fn open(a: A, path: []const u8, offset: u64, ordinal: i64, warnings: *H.Warnings) !Records {
        const z = try a.dupeZ(u8, path);
        defer a.free(z);
        const file = H.c.fopen(z, "rb") orelse return error.SourceFileUnavailable;
        errdefer _ = H.c.fclose(file);
        if (H.c.fseeko(file, 0, H.c.SEEK_END) != 0) return error.SourceReadFailed;
        const end = H.c.ftello(file);
        if (end < 0) return error.SourceReadFailed;
        if (offset > @as(u64, @intCast(end))) return error.ProjectionPastRollout;
        if (H.c.fseeko(file, @intCast(offset), H.c.SEEK_SET) != 0) return error.SourceReadFailed;
        return .{ .file = file, .end = @intCast(end), .position = offset, .ordinal = ordinal, .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator), .allocator = a, .warnings = warnings };
    }
    pub fn close(self: *Records) void {
        self.arena.deinit();
        if (self.buffer != null) H.c.free(self.buffer);
        _ = H.c.fclose(self.file);
    }
    pub fn next(self: *Records) !?Record {
        while (self.position < self.end) {
            const count = H.c.getline(&self.buffer, &self.capacity, self.file);
            if (count < 0) return error.SourceReadFailed;
            const length: usize = @intCast(@min(@as(u64, @intCast(count)), self.end - self.position));
            self.position += length;
            const ordinal = self.ordinal;
            self.ordinal += 1;
            const line = self.buffer[0..length];
            if (std.mem.trim(u8, line, " \t\r\n").len == 0) continue;
            // The later root-type check rejects JSON embedded in output text.
            if (self.compactions_only and std.mem.indexOf(u8, line[0..@min(512, line.len)], "compacted") == null) continue;
            _ = self.arena.reset(.retain_capacity);
            const value = H.parse(self.arena.allocator(), line) catch {
                if (self.position == self.end and line[line.len - 1] != '\n') {
                    try self.warnings.append(try H.fmt(self.allocator, "Incomplete final rollout record; retry after the writer finishes", .{}));
                    return null;
                }
                return error.MalformedSourceJson;
            };
            if (value != .object) return error.ExpectedSourceObject;
            const explicit = H.get(value, "ordinal");
            return .{ .ordinal = if (explicit == .integer) explicit.integer else ordinal, .value = value };
        }
        return null;
    }
};

pub const Database = struct {
    handle: *sql.sqlite3,
    pub fn open(a: A, path: []const u8) !Database {
        const z = try a.dupeZ(u8, path);
        defer a.free(z);
        var handle: ?*sql.sqlite3 = null;
        const rc = sql.sqlite3_open_v2(z, &handle, sql.SQLITE_OPEN_READONLY, null);
        if (rc != sql.SQLITE_OK) {
            if (handle) |db| _ = sql.sqlite3_close(db);
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
        if (sql.sqlite3_exec(self.handle, query, null, null, null) != sql.SQLITE_OK) return error.SourceDatabaseQueryFailed;
    }
    pub fn prepare(self: Database, query: [:0]const u8) !Statement {
        var statement: ?*sql.sqlite3_stmt = null;
        if (sql.sqlite3_prepare_v2(self.handle, query, -1, &statement, null) != sql.SQLITE_OK) return error.SourceDatabaseQueryFailed;
        return .{ .handle = statement.? };
    }
    pub fn hasTable(self: Database, name: []const u8) !bool {
        const stmt = try self.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?");
        defer stmt.close();
        try stmt.bind(1, name);
        return stmt.next();
    }
};
const Statement = struct {
    handle: *sql.sqlite3_stmt,
    pub fn close(self: Statement) void {
        _ = sql.sqlite3_finalize(self.handle);
    }
    pub fn bind(self: Statement, index: c_int, value: []const u8) !void {
        if (sql.sqlite3_bind_text(self.handle, index, value.ptr, @intCast(value.len), null) != sql.SQLITE_OK) return error.SourceDatabaseQueryFailed;
    }
    pub fn next(self: Statement) !bool {
        return switch (sql.sqlite3_step(self.handle)) {
            sql.SQLITE_ROW => true,
            sql.SQLITE_DONE => false,
            else => error.SourceDatabaseQueryFailed,
        };
    }
    pub fn text(self: Statement, index: c_int) []const u8 {
        const ptr = sql.sqlite3_column_text(self.handle, index);
        return if (ptr == null) "" else ptr[0..@intCast(sql.sqlite3_column_bytes(self.handle, index))];
    }
    pub fn int(self: Statement, index: c_int) i64 {
        return sql.sqlite3_column_int64(self.handle, index);
    }
    pub fn row(self: Statement, a: A) !V {
        var value = try H.obj(a, &.{});
        var index: c_int = 0;
        while (index < sql.sqlite3_column_count(self.handle)) : (index += 1) {
            const name = try a.dupe(u8, std.mem.span(sql.sqlite3_column_name(self.handle, index)));
            const column: V = switch (sql.sqlite3_column_type(self.handle, index)) {
                sql.SQLITE_NULL => .null,
                sql.SQLITE_INTEGER => H.num(self.int(index)),
                sql.SQLITE_FLOAT => .{ .float = sql.sqlite3_column_double(self.handle, index) },
                else => H.str(try a.dupe(u8, self.text(index))),
            };
            try H.set(a, &value, name, column);
        }
        return value;
    }
};

pub fn latestDatabase(a: A, home: []const u8, stem: []const u8) !?[]const u8 {
    if (!H.exists(home)) return null;
    const prefix = try H.fmt(a, "{s}_", .{stem});
    var selected: ?[]const u8 = null;
    var version: u64 = 0;
    for (try H.listDir(a, home)) |entry| {
        if (entry.is_dir or !std.mem.startsWith(u8, entry.name, prefix) or !std.mem.endsWith(u8, entry.name, ".sqlite")) continue;
        const digits = entry.name[prefix.len .. entry.name.len - ".sqlite".len];
        if (digits.len == 0) continue;
        var numeric = true;
        for (digits) |digit| {
            if (!std.ascii.isDigit(digit)) numeric = false;
        }
        if (!numeric) continue;
        const candidate = std.fmt.parseInt(u64, digits, 10) catch continue;
        if (selected == null or candidate > version) {
            version = candidate;
            selected = try H.join(a, &.{ home, entry.name });
        }
    }
    return selected;
}
