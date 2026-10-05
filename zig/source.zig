//! Read-only Codex display history and raw rollout adapters.
const std = @import("std");
const H = @import("common.zig");
const sql = @cImport({
    @cInclude("sqlite3.h");
});
const A = H.Allocator;
const V = H.Value;
pub const Thread = H.Thread;
pub const Item = H.Item;
pub const Compaction = H.Compaction;
const Strings = std.array_list.Managed([]const u8);
const Items = std.array_list.Managed(Item);
const Values = std.array_list.Managed(V);

fn copy(a: A, value: []const u8) ![]const u8 {
    return a.dupe(u8, value);
}
fn eq(value: []const u8, other: []const u8) bool {
    return H.eq(value, other);
}
fn oneOf(value: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (eq(value, choice)) return true;
    return false;
}
fn optional(value: []const u8) ?[]const u8 {
    return if (value.len == 0) null else value;
}
fn first(value: []const u8, fallback: []const u8) []const u8 {
    return if (value.len != 0) value else fallback;
}
fn truth(value: V) bool {
    return H.b(value) or (value == .integer and value.integer != 0);
}
fn warning(a: A, warnings: *H.Warnings, comptime format: []const u8, args: anytype) !void {
    try warnings.append(try H.fmt(a, format, args));
}
fn timestamp(a: A, value: V, milliseconds: bool) ![]const u8 {
    if (value == .null or (value == .string and value.string.len == 0)) return "1970-01-01T00:00:00.000Z";
    if (value == .string) return H.timestamp(a, try H.timestampMillis(value.string));
    if (value != .integer and value != .float) return error.InvalidSourceTimestamp;
    if (value == .float) {
        const scaled = if (milliseconds or @abs(value.float) >= 100_000_000_000) value.float else value.float * 1000;
        if (!std.math.isFinite(scaled) or scaled >= @as(f64, @floatFromInt(std.math.maxInt(i64))) or scaled < @as(f64, @floatFromInt(std.math.minInt(i64)))) return error.InvalidSourceTimestamp;
        return H.timestamp(a, @intFromFloat(scaled));
    }
    const number = H.integer(value);
    const millis = if (milliseconds or number >= 100_000_000_000 or number <= -100_000_000_000) number else std.math.mul(i64, number, 1000) catch return error.InvalidSourceTimestamp;
    return H.timestamp(a, millis);
}

fn expanded(a: A, value: []const u8) ![]const u8 {
    if (eq(value, "~") or std.mem.startsWith(u8, value, "~/")) {
        if (H.c.getenv("HOME")) |home| return H.join(a, &.{ std.mem.span(home), if (value.len > 2) value[2..] else "" });
    }
    return copy(a, value);
}
fn absolute(a: A, value: []const u8, cwd: []const u8) ![]const u8 {
    const path = try expanded(a, value);
    return if (std.fs.path.isAbsolute(path) or cwd.len == 0) path else H.join(a, &.{ cwd, path });
}
fn canonical(a: A, value: []const u8) ![]const u8 {
    const path = try expanded(a, value);
    const z = try a.dupeZ(u8, path);
    if (H.c.realpath(z, null)) |resolved_path| {
        defer H.c.free(resolved_path);
        return copy(a, std.mem.span(resolved_path));
    }
    if (std.fs.path.isAbsolute(path)) return path;
    const cwd = H.c.getcwd(null, 0) orelse return error.CurrentDirectoryUnavailable;
    defer H.c.free(cwd);
    return H.join(a, &.{ std.mem.span(cwd), path });
}

/// Read a fixed-size snapshot. getline storage and each parsed record are
/// released independently of the caller's retained conversation allocator.
const Records = struct {
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

    const Record = struct { ordinal: i64, value: V };

    fn open(a: A, path: []const u8, offset: u64, ordinal: i64, warnings: *H.Warnings) !Records {
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
    fn close(self: *Records) void {
        self.arena.deinit();
        if (self.buffer != null) H.c.free(self.buffer);
        _ = H.c.fclose(self.file);
    }
    fn next(self: *Records) !?Record {
        while (self.position < self.end) {
            const count = H.c.getline(&self.buffer, &self.capacity, self.file);
            if (count < 0) return error.SourceReadFailed;
            const length: usize = @intCast(@min(@as(u64, @intCast(count)), self.end - self.position));
            self.position += length;
            const ordinal = self.ordinal;
            self.ordinal += 1;
            const line = self.buffer[0..length];
            if (std.mem.trim(u8, line, " \t\r\n").len == 0) continue;
            // This is only a fast prefilter. The parsed root type is checked
            // below; apparent record JSON inside output text cannot match it.
            if (self.compactions_only and std.mem.indexOf(u8, line[0..@min(512, line.len)], "compacted") == null) continue;
            _ = self.arena.reset(.retain_capacity);
            const value = H.parse(self.arena.allocator(), line) catch {
                if (self.position == self.end and line[line.len - 1] != '\n') {
                    try warning(self.allocator, self.warnings, "Incomplete final rollout record; retry after the writer finishes", .{});
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

const Database = struct {
    handle: *sql.sqlite3,
    fn open(a: A, path: []const u8) !Database {
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
    fn close(self: Database) void {
        _ = sql.sqlite3_close(self.handle);
    }
    fn exec(self: Database, query: [:0]const u8) !void {
        if (sql.sqlite3_exec(self.handle, query, null, null, null) != sql.SQLITE_OK) return error.SourceDatabaseQueryFailed;
    }
    fn prepare(self: Database, query: [:0]const u8) !Statement {
        var statement: ?*sql.sqlite3_stmt = null;
        if (sql.sqlite3_prepare_v2(self.handle, query, -1, &statement, null) != sql.SQLITE_OK) return error.SourceDatabaseQueryFailed;
        return .{ .handle = statement.? };
    }
    fn hasTable(self: Database, name: []const u8) !bool {
        const stmt = try self.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?");
        defer stmt.close();
        try stmt.bind(1, name);
        return stmt.next();
    }
};
const Statement = struct {
    handle: *sql.sqlite3_stmt,
    fn close(self: Statement) void {
        _ = sql.sqlite3_finalize(self.handle);
    }
    fn bind(self: Statement, index: c_int, value: []const u8) !void {
        if (sql.sqlite3_bind_text(self.handle, index, value.ptr, @intCast(value.len), null) != sql.SQLITE_OK) return error.SourceDatabaseQueryFailed;
    }
    fn next(self: Statement) !bool {
        return switch (sql.sqlite3_step(self.handle)) {
            sql.SQLITE_ROW => true,
            sql.SQLITE_DONE => false,
            else => error.SourceDatabaseQueryFailed,
        };
    }
    fn text(self: Statement, index: c_int) []const u8 {
        const ptr = sql.sqlite3_column_text(self.handle, index);
        return if (ptr == null) "" else ptr[0..@intCast(sql.sqlite3_column_bytes(self.handle, index))];
    }
    fn int(self: Statement, index: c_int) i64 {
        return sql.sqlite3_column_int64(self.handle, index);
    }
    fn row(self: Statement, a: A) !V {
        var value = try H.obj(a, &.{});
        var index: c_int = 0;
        while (index < sql.sqlite3_column_count(self.handle)) : (index += 1) {
            const name = try copy(a, std.mem.span(sql.sqlite3_column_name(self.handle, index)));
            const column: V = switch (sql.sqlite3_column_type(self.handle, index)) {
                sql.SQLITE_NULL => .null,
                sql.SQLITE_INTEGER => H.num(self.int(index)),
                sql.SQLITE_FLOAT => .{ .float = sql.sqlite3_column_double(self.handle, index) },
                else => H.str(try copy(a, self.text(index))),
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

fn metadata(a: A, path: []const u8) !V {
    if (!H.exists(path)) return .null;
    var warnings = H.Warnings.init(a);
    var records = try Records.open(a, path, 0, 0, &warnings);
    defer records.close();
    if (try records.next()) |record| {
        if (eq(H.s(record.value, "type"), "session_meta")) return H.clone(a, H.get(record.value, "payload"));
    }
    return .null;
}
fn sourceParent(a: A, source: V) !?[]const u8 {
    const value = if (source == .string) H.parse(a, source.string) catch return null else source;
    const parent = H.s(H.get(H.get(value, "subagent"), "thread_spawn"), "parent_thread_id");
    return optional(parent);
}
fn rolloutPath(a: A, value: []const u8, home: []const u8) ![]const u8 {
    const path = try absolute(a, value, home);
    if (H.exists(path)) return path;
    for ([_][]const u8{ "/sessions/", "/archived_sessions/" }) |directory| {
        if (std.mem.indexOf(u8, path, directory)) |index| {
            const candidate = try H.join(a, &.{ home, path[index + 1 ..] });
            if (H.exists(candidate)) return candidate;
        }
    }
    return path;
}

pub fn listThreads(a: A, codex_home: []const u8) ![]Thread {
    const home = try canonical(a, codex_home);
    var threads = std.StringHashMap(Thread).init(a);
    if (try latestDatabase(a, home, "state")) |path| {
        const db = try Database.open(a, path);
        defer db.close();
        if (!try db.hasTable("threads")) return error.UnsupportedStateSchema;
        var parents = std.StringHashMap([]const u8).init(a);
        if (try db.hasTable("thread_spawn_edges")) {
            const stmt = try db.prepare("SELECT child_thread_id,parent_thread_id FROM thread_spawn_edges");
            defer stmt.close();
            while (try stmt.next()) try parents.put(try copy(a, stmt.text(0)), try copy(a, stmt.text(1)));
        }
        const stmt = try db.prepare("SELECT * FROM threads");
        defer stmt.close();
        while (try stmt.next()) {
            const row = try stmt.row(a);
            const id = H.s(row, "id");
            if (id.len == 0) return error.MissingSourceThreadId;
            const rollout = try rolloutPath(a, H.s(row, "rollout_path"), home);
            var parent = parents.get(id) orelse try sourceParent(a, H.get(row, "source"));
            if (parent == null) {
                const meta = try metadata(a, rollout);
                parent = optional(first(H.s(meta, "forked_from_id"), H.s(meta, "parent_thread_id")));
            }
            const created_ms = H.get(row, "created_at_ms");
            const updated_ms = H.get(row, "updated_at_ms");
            const source_value = H.get(row, "source");
            try threads.put(id, .{
                .id = id,
                .title = first(first(H.s(row, "name"), H.s(row, "title")), try H.fmt(a, "Codex {s}", .{id})),
                .cwd = H.s(row, "cwd"),
                .rollout_path = rollout,
                .parent_id = parent,
                .created_at = try timestamp(a, if (created_ms != .null) created_ms else H.get(row, "created_at"), created_ms != .null),
                .updated_at = try timestamp(a, if (updated_ms != .null) updated_ms else H.get(row, "updated_at"), updated_ms != .null),
                .source = if (source_value == .object) try H.json(a, source_value) else first(H.text(source_value), "cli"),
                .archived = truth(H.get(row, "archived")),
                .history_mode = first(H.s(row, "history_mode"), "legacy"),
            });
        }
    }
    var known_paths = std.StringHashMap(void).init(a);
    var thread_values = threads.valueIterator();
    while (thread_values.next()) |thread| try known_paths.put(try canonical(a, thread.rollout_path), {});
    for ([_][]const u8{ "sessions", "archived_sessions" }) |directory| {
        const root = try H.join(a, &.{ home, directory });
        if (!H.exists(root)) continue;
        for (try H.walkFiles(a, root, ".jsonl")) |path| {
            if (known_paths.contains(try canonical(a, path))) continue;
            const meta = try metadata(a, path);
            const id = first(H.s(meta, "id"), H.s(meta, "session_id"));
            if (id.len == 0 or threads.contains(id)) continue;
            const info = try H.stat(path);
            const millis: i64 = @intCast(@divTrunc(info.mtime_ns, std.time.ns_per_ms));
            const source_value = H.get(meta, "source");
            const source_name = if (source_value == .object) try H.json(a, source_value) else first(H.text(source_value), "cli");
            const parent = optional(first(H.s(meta, "forked_from_id"), H.s(meta, "parent_thread_id"))) orelse try sourceParent(a, source_value);
            try threads.put(id, .{
                .id = id,
                .title = first(H.s(meta, "title"), try H.fmt(a, "Codex {s}", .{id})),
                .cwd = H.s(meta, "cwd"),
                .rollout_path = path,
                .parent_id = parent,
                .created_at = if (H.get(meta, "timestamp") != .null) try timestamp(a, H.get(meta, "timestamp"), false) else try H.timestamp(a, millis),
                .updated_at = try H.timestamp(a, millis),
                .source = source_name,
                .archived = eq(directory, "archived_sessions"),
                .history_mode = first(H.s(meta, "history_mode"), "legacy"),
            });
        }
    }
    var result = std.array_list.Managed(Thread).init(a);
    thread_values = threads.valueIterator();
    while (thread_values.next()) |thread| {
        const meta = try metadata(a, thread.rollout_path);
        const marker = H.s(meta, "originator");
        const supported_origin = std.mem.startsWith(u8, marker, "c2c:claude:") or
            std.mem.startsWith(u8, marker, "c2c:omp:") or
            std.mem.startsWith(u8, marker, "c2c:opencode:");
        if (supported_origin) {
            const origin = try @import("codex.zig").readOrigin(a, thread.*);
            thread.origin_provider = origin.provider;
            thread.origin_id = origin.original_id;
            thread.original_claude_id = if (eq(origin.provider orelse "", "claude")) origin.original_id else null;
            thread.unchanged_import = origin.unchanged;
        }
        try result.append(thread.*);
    }
    std.mem.sort(Thread, result.items, {}, struct {
        fn less(_: void, left: Thread, right: Thread) bool {
            const ordering = std.mem.order(u8, left.updated_at, right.updated_at);
            return if (ordering == .eq) std.mem.order(u8, left.id, right.id) == .gt else ordering == .gt;
        }
    }.less);
    return result.toOwnedSlice();
}

fn mime(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(extension, ".jpg") or std.ascii.eqlIgnoreCase(extension, ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(extension, ".gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(extension, ".webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(extension, ".pdf")) return "application/pdf";
    return "";
}
const Content = struct { text: []const u8, attachments: []const V };
fn content(a: A, value: V, warnings: *H.Warnings) !Content {
    if (value == .string) return .{ .text = try copy(a, value.string), .attachments = &.{} };
    var texts = Strings.init(a);
    var attachments = Values.init(a);
    const single = [_]V{value};
    for (if (value == .object) &single else H.list(value)) |part| {
        if (part != .object) continue;
        const kind = H.s(part, "type");
        if (oneOf(kind, &.{ "text", "input_text", "output_text" })) {
            try texts.append(try copy(a, H.s(part, "text")));
        } else if (oneOf(kind, &.{ "image", "input_image", "localImage", "image_url", "file", "input_file", "resource_link", "skill" })) {
            const path = first(H.s(part, "path"), H.s(part, "file_path"));
            var url = H.get(part, "image_url");
            if (url == .null) url = H.get(part, "url");
            if (url == .null) url = H.get(part, "uri");
            if (url == .object) url = H.get(url, "url");
            const media = first(first(H.s(part, "mimeType"), H.s(part, "mime_type")), mime(path));
            if (url == .null and H.s(part, "data").len != 0 and eq(kind, "image")) url = H.str(try H.fmt(a, "data:{s};base64,{s}", .{ first(media, "image/png"), H.s(part, "data") }));
            var attachment = try H.obj(a, &.{.{ "type", H.str(try copy(a, kind)) }});
            if (path.len != 0) try H.set(a, &attachment, "path", H.str(try copy(a, path)));
            if (url != .null) try H.set(a, &attachment, "url", try H.clone(a, url));
            if (media.len != 0) try H.set(a, &attachment, "media_type", H.str(try copy(a, media)));
            const name = first(H.s(part, "name"), H.s(part, "filename"));
            if (name.len != 0) try H.set(a, &attachment, "name", H.str(try copy(a, name)));
            for ([_][]const u8{ "file_id", "file_data", "file_url" }) |key| {
                const field = H.get(part, key);
                if (field != .null) try H.set(a, &attachment, key, try H.clone(a, field));
            }
            try attachments.append(attachment);
        } else if (!oneOf(kind, &.{ "reasoning", "encrypted_text" })) {
            try warning(a, warnings, "Unsupported content block; preserved as an attachment", .{});
            try attachments.append(try H.clone(a, part));
        }
    }
    return .{ .text = try std.mem.join(a, "\n", texts.items), .attachments = try attachments.toOwnedSlice() };
}
fn resolved(a: A, item_value: Item, thread: Thread) !Item {
    var item = item_value;
    if (item.attachments.len != 0) {
        var attachments = Values.init(a);
        for (item.attachments) |attachment_value| {
            var attachment = attachment_value;
            const path = H.s(attachment, "path");
            if (path.len != 0) try H.set(a, &attachment, "path", H.str(try absolute(a, path, thread.cwd)));
            try attachments.append(attachment);
        }
        item.attachments = try attachments.toOwnedSlice();
    }
    if (oneOf(item.kind, &.{ "imageView", "imageGeneration" })) {
        if (item.raw) |raw_value| {
            var raw = raw_value;
            for ([_][]const u8{ "path", "savedPath" }) |key| {
                const path = H.s(raw, key);
                if (path.len != 0) try H.set(a, &raw, key, H.str(try absolute(a, path, thread.cwd)));
            }
            item.raw = raw;
        }
    }
    return item;
}

fn projected(a: A, data: V, identifier: []const u8, time: []const u8, ordinal: i64, warnings: *H.Warnings) !?Item {
    const kind = H.s(data, "type");
    if (oneOf(kind, &.{ "reasoning", "hookPrompt", "contextCompaction", "subAgentActivity" })) return null;
    var item = Item{ .id = try copy(a, identifier), .role = "", .text = "", .timestamp = time, .kind = try copy(a, kind), .ordinal = ordinal };
    if (eq(kind, "userMessage")) {
        const parsed = try content(a, H.get(data, "content"), warnings);
        item.role = "user";
        item.text = parsed.text;
        item.attachments = parsed.attachments;
    } else if (eq(kind, "agentMessage")) {
        if (eq(H.s(data, "phase"), "analysis")) return null;
        item.role = "assistant";
        item.text = try copy(a, H.s(data, "text"));
    } else if (oneOf(kind, &.{ "commandExecution", "fileChange", "functionCallOutput", "mcpToolCall", "collabAgentToolCall", "imageView", "imageGeneration", "webSearch", "sleep" })) {
        var output = H.get(data, "aggregatedOutput");
        if (output == .null) output = H.get(data, "output");
        if (eq(kind, "mcpToolCall")) {
            const result = H.get(data, "result");
            output = if (result == .object) H.get(result, "content") else result;
        }
        const parsed = try content(a, output, warnings);
        item.role = "tool";
        item.text = parsed.text;
        item.attachments = parsed.attachments;
        item.raw = try H.clone(a, data);
        if (oneOf(kind, &.{ "imageView", "imageGeneration" })) {
            const path = first(H.s(data, "path"), H.s(data, "savedPath"));
            if (path.len != 0) {
                var attachments = Values.init(a);
                try attachments.appendSlice(item.attachments);
                try attachments.append(try H.obj(a, &.{ .{ "path", H.str(try copy(a, path)) }, .{ "type", H.str("localImage") }, .{ "media_type", H.str(mime(path)) } }));
                item.attachments = try attachments.toOwnedSlice();
            }
        }
    } else {
        try warning(a, warnings, "Unsupported projected item at ordinal {d}", .{ordinal});
        return null;
    }
    return item;
}

fn response(a: A, data: V, time: []const u8, ordinal: i64, prefix: []const u8, warnings: *H.Warnings) !?Item {
    const kind = H.s(data, "type");
    const identifier = first(first(H.s(data, "id"), H.s(data, "call_id")), try H.fmt(a, "{s}:{d}", .{ prefix, ordinal }));
    if (eq(kind, "message")) {
        const role = H.s(data, "role");
        if (!oneOf(role, &.{ "user", "assistant" }) or oneOf(H.s(data, "channel"), &.{ "analysis", "justify", "confidence" })) return null;
        const parsed = try content(a, H.get(data, "content"), warnings);
        if (parsed.text.len == 0 and parsed.attachments.len == 0) return null;
        return .{ .id = try copy(a, identifier), .role = try copy(a, role), .text = parsed.text, .timestamp = time, .kind = if (eq(role, "user")) "userMessage" else "agentMessage", .attachments = parsed.attachments, .ordinal = ordinal };
    }
    if (oneOf(kind, &.{ "function_call", "custom_tool_call", "function_call_output", "custom_tool_call_output", "web_search_call", "image_generation_call" })) {
        const parsed = try content(a, H.get(data, "output"), warnings);
        return .{ .id = try copy(a, identifier), .role = "tool", .text = parsed.text, .timestamp = time, .kind = try copy(a, kind), .attachments = parsed.attachments, .raw = try H.clone(a, data), .ordinal = ordinal };
    }
    return null;
}

fn appendRollout(a: A, items: *Items, thread: Thread, offset: u64, start_ordinal: i64, warnings: *H.Warnings) !void {
    var records = try Records.open(a, thread.rollout_path, offset, start_ordinal, warnings);
    defer records.close();
    while (try records.next()) |record| {
        if (!eq(H.s(record.value, "type"), "response_item")) continue;
        const time = H.get(record.value, "timestamp");
        if (try response(a, H.get(record.value, "payload"), if (time == .null) thread.updated_at else try timestamp(a, time, false), record.ordinal, thread.id, warnings)) |item| {
            try items.append(try resolved(a, item, thread));
        }
    }
}

/// Display projections sometimes represent a native tool exchange only as an
/// AgentMessage. Keep the actual call/result pair as well. A projected tool's
/// ID or a verified tool event inside an enclosing call proves that the tool
/// already has a structured representation and suppresses that raw wrapper.
const ToolRecovery = struct {
    const Call = struct {
        id: []const u8,
        name: []const u8,
        ordinal: i64,
        timestamp: []const u8,
        raw: ?V = null,
        output: ?V = null,
        output_ordinal: i64 = 0,
        output_timestamp: []const u8 = "",
        arena: ?*std.heap.ArenaAllocator = null,
        covered: bool = false,

        fn wraps(self: Call, event_kind: []const u8) bool {
            const name = if (std.mem.lastIndexOfScalar(u8, self.name, '.')) |index| self.name[index + 1 ..] else self.name;
            if (oneOf(name, &.{ "exec", "wait" })) return true;
            if (oneOf(name, &.{ "exec_command", "write_stdin", "shell", "shell_command" })) return std.ascii.eqlIgnoreCase(event_kind, "CommandExecution");
            if (eq(name, "view_image")) return std.ascii.eqlIgnoreCase(event_kind, "ImageView");
            if (eq(name, "apply_patch")) return std.ascii.eqlIgnoreCase(event_kind, "FileChange");
            return false;
        }

        fn close(self: *Call) void {
            if (self.arena) |arena| {
                arena.deinit();
                std.heap.page_allocator.destroy(arena);
                self.arena = null;
            }
        }
    };

    allocator: A,
    thread: Thread,
    warnings: *H.Warnings,
    projected_ids: std.StringHashMap(void),
    projected_ordinals: std.AutoHashMap(i64, []const u8),
    pending: std.array_list.Managed(Call),
    completed: std.array_list.Managed(Call),
    additions: Items,
    end_offset: ?u64,
    last_ordinal: i64,
    ambiguous_mapping: bool = false,

    fn init(a: A, items: []const Item, thread: Thread, warnings: *H.Warnings, end_offset: ?u64) !ToolRecovery {
        var self = ToolRecovery{
            .allocator = a,
            .thread = thread,
            .warnings = warnings,
            .projected_ids = std.StringHashMap(void).init(a),
            .projected_ordinals = std.AutoHashMap(i64, []const u8).init(a),
            .pending = std.array_list.Managed(Call).init(a),
            .completed = std.array_list.Managed(Call).init(a),
            .additions = Items.init(a),
            .end_offset = end_offset,
            .last_ordinal = -1,
        };
        for (items) |item| {
            self.last_ordinal = @max(self.last_ordinal, item.ordinal);
            if (eq(item.role, "tool")) {
                try self.projected_ids.put(item.id, {});
                try self.projected_ordinals.put(item.ordinal, item.id);
            }
        }
        return self;
    }

    fn close(self: *ToolRecovery) void {
        for (self.pending.items) |*call| call.close();
        for (self.completed.items) |*call| call.close();
    }

    fn emitCall(self: *ToolRecovery, call: Call) !void {
        if (call.covered) return;
        const item = (try response(self.allocator, call.raw.?, call.timestamp, call.ordinal, self.thread.id, self.warnings)).?;
        try self.additions.append(try resolved(self.allocator, item, self.thread));
        if (call.output) |output| {
            const result = (try response(self.allocator, output, call.output_timestamp, call.output_ordinal, self.thread.id, self.warnings)).?;
            try self.additions.append(try resolved(self.allocator, result, self.thread));
        }
    }

    fn flushCompleted(self: *ToolRecovery) !void {
        for (self.completed.items) |*call| {
            try self.emitCall(call.*);
            call.close();
        }
        self.completed.clearRetainingCapacity();
    }

    fn observe(self: *ToolRecovery, record: Records.Record, end_position: u64) !void {
        if (self.end_offset) |limit| {
            if (end_position > limit) return;
        } else if (record.ordinal > self.last_ordinal) return;
        const data = H.get(record.value, "payload");
        const kind = H.s(data, "type");
        if (eq(H.s(record.value, "type"), "event_msg") and eq(kind, "item_completed")) {
            if (self.projected_ordinals.get(record.ordinal)) |expected_id| {
                const event_id = H.s(H.get(data, "item"), "id");
                if (!eq(event_id, expected_id)) return;
                var exact = false;
                for (self.pending.items) |*call| {
                    if (eq(call.id, event_id)) {
                        call.covered = true;
                        exact = true;
                    }
                }
                for (self.completed.items) |*call| {
                    if (eq(call.id, event_id)) {
                        call.covered = true;
                        exact = true;
                    }
                }
                if (!exact) {
                    // A nearby display event can belong to a background agent.
                    // Only known orchestration wrappers can be identified by
                    // their enclosed events when IDs do not match directly.
                    const event_kind = H.s(H.get(data, "item"), "type");
                    var wrappers: usize = 0;
                    for (self.pending.items) |*call| {
                        if (call.wraps(event_kind)) {
                            call.covered = true;
                            wrappers += 1;
                        }
                    }
                    for (self.completed.items) |*call| {
                        if (call.wraps(event_kind)) {
                            call.covered = true;
                            wrappers += 1;
                        }
                    }
                    if (wrappers > 1) self.ambiguous_mapping = true;
                }
            }
            return;
        }
        if (!eq(H.s(record.value, "type"), "response_item")) return;
        // Native runtimes can append display completion events after their
        // response output. Keep this completed batch until the next call or
        // user turn so those events can still identify a projected wrapper.
        if (oneOf(kind, &.{ "function_call", "custom_tool_call" }) or
            (eq(kind, "message") and eq(H.s(data, "role"), "user"))) try self.flushCompleted();
        const call_id = H.s(data, "call_id");
        if (call_id.len == 0) return;
        if (oneOf(kind, &.{ "function_call", "custom_tool_call" })) {
            for (self.pending.items) |*existing| {
                if (eq(existing.id, call_id)) {
                    existing.covered = true;
                    self.ambiguous_mapping = true;
                    return;
                }
            }
            const covered = self.projected_ids.contains(call_id);
            const time = H.get(record.value, "timestamp");
            var call = Call{
                .id = try copy(self.allocator, call_id),
                .name = try copy(self.allocator, H.s(data, "name")),
                .ordinal = record.ordinal,
                .timestamp = if (time == .null) self.thread.updated_at else try timestamp(self.allocator, time, false),
                .covered = covered,
            };
            if (!covered) {
                const arena = try std.heap.page_allocator.create(std.heap.ArenaAllocator);
                arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                call.arena = arena;
                errdefer call.close();
                call.raw = try H.clone(arena.allocator(), data);
            }
            errdefer call.close();
            try self.pending.append(call);
        } else if (oneOf(kind, &.{ "function_call_output", "custom_tool_call_output" })) {
            for (self.pending.items, 0..) |pending, index| {
                if (!eq(pending.id, call_id)) continue;
                var call = self.pending.orderedRemove(index);
                if (call.covered) {
                    call.close();
                } else {
                    errdefer call.close();
                    const time = H.get(record.value, "timestamp");
                    call.output = try H.clone(call.arena.?.allocator(), data);
                    call.output_ordinal = record.ordinal;
                    call.output_timestamp = if (time == .null) self.thread.updated_at else try timestamp(self.allocator, time, false);
                    try self.completed.append(call);
                }
                return;
            }
        }
    }

    fn finish(self: *ToolRecovery, items: *Items) !void {
        try self.flushCompleted();
        // A call can precede the projection cursor while its result is in the
        // live tail. Keeping the call allows the later result to pair once.
        for (self.pending.items) |call| try self.emitCall(call);
        if (self.ambiguous_mapping) try warning(self.allocator, self.warnings, "Overlapping raw tool calls could not be assigned to projected tools; retained the authoritative display", .{});
        try items.appendSlice(self.additions.items);
        std.mem.sort(Item, items.items, {}, struct {
            fn less(_: void, left: Item, right: Item) bool {
                return if (left.ordinal == right.ordinal) std.mem.order(u8, left.id, right.id) == .lt else left.ordinal < right.ordinal;
            }
        }.less);
    }
};

pub fn readItems(a: A, thread: Thread, codex_home: []const u8, warnings: *H.Warnings) ![]Item {
    const home = try canonical(a, codex_home);
    var items = Items.init(a);
    var has_projected = false;
    var cursor: ?struct { offset: u64, ordinal: i64 } = null;
    if (try latestDatabase(a, home, "thread_history")) |path| {
        const db = try Database.open(a, path);
        defer db.close();
        if (try db.hasTable("thread_items")) {
            if (try db.hasTable("thread_history_projection_state")) {
                const stmt = try db.prepare("SELECT next_rollout_byte_offset,next_rollout_ordinal FROM thread_history_projection_state WHERE thread_id=?");
                defer stmt.close();
                try stmt.bind(1, thread.id);
                if (try stmt.next()) {
                    if (stmt.int(0) < 0 or stmt.int(1) < 0) return error.InvalidProjectionCursor;
                    cursor = .{ .offset = @intCast(stmt.int(0)), .ordinal = stmt.int(1) };
                }
            }
            const stmt = try db.prepare("SELECT item_id,item_json,created_at_ms,rollout_ordinal FROM thread_items WHERE thread_id=? ORDER BY rollout_ordinal,item_id");
            defer stmt.close();
            try stmt.bind(1, thread.id);
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            while (try stmt.next()) {
                has_projected = true;
                _ = arena.reset(.retain_capacity);
                const value = H.parse(arena.allocator(), stmt.text(1)) catch return error.MalformedSourceJson;
                if (value != .object) return error.ExpectedSourceObject;
                if (try projected(a, value, stmt.text(0), try H.timestamp(a, stmt.int(2)), stmt.int(3), warnings)) |item| {
                    try items.append(try resolved(a, item, thread));
                }
            }
        }
    }
    if (has_projected or cursor != null) {
        var tools = try ToolRecovery.init(a, items.items, thread, warnings, if (cursor) |position| position.offset else null);
        defer tools.close();
        try recoverProjected(a, items.items, thread, warnings, &tools);
        try tools.finish(&items);
        if (cursor) |position| {
            if (H.exists(thread.rollout_path)) try appendRollout(a, &items, thread, position.offset, position.ordinal, warnings);
        } else try warning(a, warnings, "Projected thread has no projection cursor; live tail cannot be verified", .{});
        return items.toOwnedSlice();
    }
    if (!H.exists(thread.rollout_path)) return error.SourceHistoryUnavailable;
    try appendRollout(a, &items, thread, 0, 0, warnings);
    return items.toOwnedSlice();
}

pub fn readCompaction(a: A, thread: Thread, warnings: *H.Warnings) !?Compaction {
    if (!H.exists(thread.rollout_path)) return null;
    var records = try Records.open(a, thread.rollout_path, 0, 0, warnings);
    records.compactions_only = true;
    defer records.close();
    var latest_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer latest_arena.deinit();
    var latest: ?Records.Record = null;
    while (try records.next()) |record| {
        if (!eq(H.s(record.value, "type"), "compacted")) continue;
        _ = latest_arena.reset(.free_all);
        latest = .{ .ordinal = record.ordinal, .value = try H.clone(latest_arena.allocator(), record.value) };
    }
    const record = latest orelse return null;
    const data = H.get(record.value, "payload");
    var summary = H.s(data, "message");
    const replacement = H.list(H.get(data, "replacement_history"));
    if (summary.len == 0) {
        var summaries = Strings.init(a);
        for (replacement) |entry| {
            if (eq(H.s(entry, "type"), "message") and eq(H.s(entry, "role"), "assistant") and eq(H.s(entry, "channel"), "summary")) {
                try summaries.append((try content(a, H.get(entry, "content"), warnings)).text);
            }
        }
        summary = try std.mem.join(a, "\n\n", summaries.items);
    } else summary = try copy(a, summary);
    const time = if (H.get(record.value, "timestamp") == .null) thread.updated_at else try timestamp(a, H.get(record.value, "timestamp"), false);
    var items = Items.init(a);
    var encrypted = false;
    for (replacement, 0..) |entry, index| {
        if (eq(H.s(entry, "type"), "compaction") and H.s(entry, "encrypted_content").len != 0) encrypted = true;
        if (eq(H.s(entry, "type"), "message") and eq(H.s(entry, "role"), "assistant") and eq(H.s(entry, "channel"), "summary")) continue;
        if (try response(a, entry, time, record.ordinal, try H.fmt(a, "{s}:compaction:{d}", .{ thread.id, index }), warnings)) |item| {
            if (summary.len != 0 and eq(item.role, "assistant") and eq(item.text, summary)) continue;
            try items.append(try resolved(a, item, thread));
        }
    }
    return .{ .summary = summary, .items = try items.toOwnedSlice(), .timestamp = time, .ordinal = record.ordinal, .encrypted = encrypted };
}

fn imageParts(a: A, value: V) ![]const V {
    var images = Values.init(a);
    for (H.list(value)) |part| {
        if (oneOf(H.s(part, "type"), &.{ "input_image", "image", "image_url" })) try images.append(part);
    }
    return images.toOwnedSlice();
}
fn localPaths(a: A, item: Item) ![]const []const u8 {
    var paths = Strings.init(a);
    for (item.attachments) |attachment| {
        if (eq(H.s(attachment, "type"), "localImage") and H.s(attachment, "path").len != 0) try paths.append(H.s(attachment, "path"));
    }
    return paths.toOwnedSlice();
}
fn eventPath(a: A, value: []const u8, cwd: []const u8) !?[]const u8 {
    var path = value;
    if (std.mem.startsWith(u8, path, "file:")) {
        if (std.mem.indexOfAny(u8, path, "?#") != null) return null;
        if (std.mem.startsWith(u8, path, "file:///")) path = path[7..] else if (std.mem.startsWith(u8, path, "file://localhost/")) path = path[16..] else if (std.mem.startsWith(u8, path, "file:/") and !std.mem.startsWith(u8, path, "file://")) path = path[5..] else return null;
        var decoded = std.array_list.Managed(u8).init(a);
        var index: usize = 0;
        while (index < path.len) : (index += 1) {
            if (path[index] == '%') {
                if (index + 2 >= path.len) return null;
                try decoded.append(std.fmt.parseInt(u8, path[index + 1 .. index + 3], 16) catch return null);
                index += 2;
            } else try decoded.append(path[index]);
        }
        path = try decoded.toOwnedSlice();
    }
    return try absolute(a, path, cwd);
}
fn eventMatches(a: A, item: Item, event: V, thread: Thread) !bool {
    if (!eq(H.s(event, "id"), item.id) or !std.ascii.eqlIgnoreCase(H.s(event, "type"), item.kind)) return false;
    var paths = Strings.init(a);
    if (eq(item.kind, "imageView")) {
        if (H.get(event, "path") != .string) return false;
        try paths.append(H.s(event, "path"));
    } else {
        for (H.list(H.get(event, "content"))) |part| {
            if (oneOf(H.s(part, "type"), &.{ "localImage", "local_image" })) {
                if (H.get(part, "path") != .string) return false;
                try paths.append(H.s(part, "path"));
            }
        }
    }
    const expected = try localPaths(a, item);
    if (paths.items.len != expected.len) return false;
    for (paths.items, expected) |path, target| {
        const normalized = (try eventPath(a, path, thread.cwd)) orelse return false;
        if (!eq(normalized, target)) return false;
    }
    return true;
}
fn mergeImages(a: A, item: *Item, images: []const V, warnings: *H.Warnings) !bool {
    var count: usize = 0;
    for (item.attachments) |attachment| {
        if (eq(H.s(attachment, "type"), "localImage") and H.s(attachment, "path").len != 0) count += 1;
    }
    if (count != images.len) return false;
    var attachments = Values.init(a);
    var image_index: usize = 0;
    for (item.attachments) |original| {
        var attachment = original;
        if (eq(H.s(attachment, "type"), "localImage") and H.s(attachment, "path").len != 0) {
            const parsed = try content(a, try H.arr(a, &.{images[image_index]}), warnings);
            image_index += 1;
            if (parsed.attachments.len != 1) return false;
            const url = H.s(parsed.attachments[0], "url");
            if (!std.mem.startsWith(u8, url, "data:image/")) return false;
            attachment = try H.clone(a, attachment);
            try H.set(a, &attachment, "url", H.str(url));
        }
        try attachments.append(attachment);
    }
    item.attachments = try attachments.toOwnedSlice();
    return true;
}

/// Mutates only returned Items. Never opens image paths or writes source stores.
pub fn recoverProjectedImages(a: A, items: []Item, thread: Thread, warnings: *H.Warnings) !void {
    try recoverProjected(a, items, thread, warnings, null);
}

fn recoverProjected(a: A, items: []Item, thread: Thread, warnings: *H.Warnings, tool_recovery: ?*ToolRecovery) !void {
    var targets = std.AutoHashMap(i64, usize).init(a);
    for (items, 0..) |item, index| {
        if (!oneOf(item.kind, &.{ "userMessage", "imageView" })) continue;
        for (item.attachments) |attachment| {
            if (eq(H.s(attachment, "type"), "localImage") and H.s(attachment, "path").len != 0) {
                try targets.put(item.ordinal, index);
                break;
            }
        }
    }
    if ((targets.count() == 0 and tool_recovery == null) or !H.exists(thread.rollout_path)) return;
    const Group = struct { candidates: std.array_list.Managed(usize), image_count: usize = 0, ambiguous: bool = false };
    var pending = std.StringHashMap(Group).init(a);
    var ambiguous = std.AutoHashMap(usize, void).init(a);
    var recovered = std.AutoHashMap(usize, void).init(a);
    var previous_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer previous_arena.deinit();
    var previous_user: ?struct { ordinal: i64, images: []const V } = null;
    var records = try Records.open(a, thread.rollout_path, 0, 0, warnings);
    defer records.close();
    while (try records.next()) |record| {
        if (tool_recovery) |tools| try tools.observe(record, records.position);
        if (targets.count() == 0) continue;
        const scratch = records.arena.allocator();
        const data = H.get(record.value, "payload");
        const kind = H.s(data, "type");
        if (eq(H.s(record.value, "type"), "response_item")) {
            if (eq(kind, "message") and eq(H.s(data, "role"), "user")) {
                var groups = pending.valueIterator();
                while (groups.next()) |group| for (group.candidates.items) |candidate| try ambiguous.put(candidate, {});
                pending.clearRetainingCapacity();
                _ = previous_arena.reset(.free_all);
                const previous = previous_arena.allocator();
                const parts = try imageParts(scratch, H.get(data, "content"));
                var saved = Values.init(previous);
                for (parts) |part| try saved.append(try H.clone(previous, part));
                previous_user = .{ .ordinal = record.ordinal, .images = try saved.toOwnedSlice() };
                continue;
            }
            previous_user = null;
            const call_id = H.s(data, "call_id");
            if (oneOf(kind, &.{ "function_call", "custom_tool_call" }) and call_id.len != 0) {
                const overlapping = pending.count() != 0;
                var groups = pending.valueIterator();
                while (groups.next()) |group| group.ambiguous = true;
                try pending.put(try copy(a, call_id), .{ .candidates = std.array_list.Managed(usize).init(a), .ambiguous = overlapping });
            } else if (oneOf(kind, &.{ "function_call_output", "custom_tool_call_output" })) {
                if (pending.fetchRemove(call_id)) |entry| {
                    const group = entry.value;
                    const parts = try imageParts(scratch, H.get(data, "output"));
                    if (!group.ambiguous and group.image_count == 1 and group.candidates.items.len == 1 and parts.len == 1 and try mergeImages(a, &items[group.candidates.items[0]], parts, warnings)) {
                        try recovered.put(group.candidates.items[0], {});
                    } else for (group.candidates.items) |candidate| try ambiguous.put(candidate, {});
                }
            }
            continue;
        }
        if (!eq(H.s(record.value, "type"), "event_msg") or !eq(kind, "item_completed")) {
            previous_user = null;
            continue;
        }
        const event = H.get(data, "item");
        const index = targets.get(record.ordinal);
        const verified = if (index) |candidate| try eventMatches(scratch, items[candidate], event, thread) else false;
        const event_kind = H.s(event, "type");
        if (std.ascii.eqlIgnoreCase(event_kind, "UserMessage")) {
            if (verified) {
                if (previous_user) |previous| {
                    if (previous.ordinal == record.ordinal - 1) {
                        if (try mergeImages(a, &items[index.?], previous.images, warnings)) try recovered.put(index.?, {}) else try ambiguous.put(index.?, {});
                    }
                }
            }
        } else if (std.ascii.eqlIgnoreCase(event_kind, "ImageView") or std.ascii.eqlIgnoreCase(event_kind, "ImageGeneration")) {
            if (pending.count() == 1) {
                var groups = pending.valueIterator();
                const group = groups.next().?;
                group.image_count += 1;
                if (verified and eq(items[index.?].kind, "imageView")) try group.candidates.append(index.?);
            } else if (verified) try ambiguous.put(index.?, {});
        }
        previous_user = null;
    }
    var groups = pending.valueIterator();
    while (groups.next()) |group| for (group.candidates.items) |candidate| try ambiguous.put(candidate, {});
    var recovered_keys = recovered.keyIterator();
    while (recovered_keys.next()) |index| _ = ambiguous.remove(index.*);
    if (ambiguous.count() != 0) try warning(a, warnings, "Raw image recovery was ambiguous for {d} projected item(s); kept original paths", .{ambiguous.count()});
}
