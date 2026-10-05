//! OpenCode v2 native session transfer. SQLite is read-only; OpenCode owns writes.
//! Contract pinned to official @opencode/cli 2.0.23 / tag 0fd7e28.
const std = @import("std");
const C = @import("common.zig");
const sql = @cImport({
    @cInclude("sqlite3.h");
});
const A = C.Allocator;
const V = C.Value;
const S = C.str;
const N = C.num;
const Values = std.array_list.Managed(V);
const MAX_ACTIVE_BYTES: usize = 240_000;

pub const Origin = struct { provider: ?[]const u8 = null, original_id: ?[]const u8 = null, unchanged: bool = false };

pub fn sessionId(a: A, source_provider: []const u8, source_id: []const u8) ![]const u8 {
    return C.fmt(a, "ses_{s}", .{try C.sessionIdFor(a, "opencode", source_provider, source_id)});
}
pub fn targetPath(a: A, thread: C.Thread, home: []const u8) ![]const u8 {
    return receiptPath(a, home, try sessionId(a, thread.provider, thread.id));
}
fn receiptPath(a: A, home: []const u8, id: []const u8) ![]const u8 {
    if (!validId(id, "ses_")) return error.InvalidOpenCodeSessionId;
    return C.join(a, &.{ home, "c2c-imports", try C.fmt(a, "{s}.json", .{id}) });
}
fn validId(value: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, value, prefix) or value.len <= prefix.len) return false;
    for (value) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return false;
    return true;
}
fn textBlock(a: A, value: []const u8) !V {
    return C.obj(a, &.{ .{ "type", S("text") }, .{ "text", S(value) } });
}
fn blocks(a: A, value: V) ![]const V {
    if (value == .string) return a.dupe(V, &.{try textBlock(a, value.string)});
    return C.list(value);
}
fn zeroTokens(a: A) !V {
    return C.obj(a, &.{ .{ "input", N(0) }, .{ "output", N(0) }, .{ "reasoning", N(0) }, .{ "cache", try C.obj(a, &.{ .{ "read", N(0) }, .{ "write", N(0) } }) } });
}
fn model(a: A) !V {
    return C.obj(a, &.{ .{ "providerID", S("c2c") }, .{ "id", S("historical") } });
}
fn canonical(a: A, value: V) anyerror!V {
    if (value == .array) {
        var out = Values.init(a);
        for (value.array.items) |child| try out.append(try canonical(a, child));
        return C.arr(a, out.items);
    }
    if (value != .object) return C.clone(a, value);
    const keys = try a.alloc([]const u8, value.object.count());
    var it = value.object.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) keys[i] = entry.key_ptr.*;
    std.mem.sort([]const u8, keys, {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.less);
    var out = try C.obj(a, &.{});
    for (keys) |key| try C.set(a, &out, key, try canonical(a, C.get(value, key)));
    return out;
}
fn stable(a: A, data: V, omit_fingerprint: bool) !V {
    const info = C.get(data, "info");
    var metadata = try C.clone(a, C.get(info, "metadata"));
    if (omit_fingerprint and metadata == .object) {
        var marker = C.get(metadata, "c2c");
        if (marker == .object) {
            _ = marker.object.swapRemove("fingerprint");
            try C.set(a, &metadata, "c2c", marker);
        }
    }
    return canonical(a, try C.obj(a, &.{
        .{ "id", C.get(info, "id") },             .{ "title", C.get(info, "title") },
        .{ "location", C.get(info, "location") }, .{ "metadata", metadata },
        .{ "messages", C.get(data, "messages") },
    }));
}
fn fingerprint(a: A, data: V, omit_fingerprint: bool) ![]const u8 {
    const encoded = try C.json(a, try stable(a, data, omit_fingerprint));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded, &digest, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

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
    return if (try readNative(a, home, id)) |value| try fingerprint(a, value, false) else null;
}
fn origin(a: A, data: V) !Origin {
    const marker = C.get(C.get(C.get(data, "info"), "metadata"), "c2c");
    const provider = C.s(marker, "sourceProvider");
    const id = C.s(marker, "sourceSessionId");
    if (provider.len == 0 or id.len == 0) return .{};
    return .{ .provider = provider, .original_id = id, .unchanged = C.eq(C.s(marker, "fingerprint"), try fingerprint(a, data, true)) };
}
pub fn readOrigin(a: A, thread: C.Thread) !Origin {
    const home = std.fs.path.dirname(thread.rollout_path) orelse return error.InvalidOpenCodeSourcePath;
    return if (try readNative(a, home, thread.id)) |data| origin(a, data) else .{};
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
        // Inventory retains only thread metadata. A large corpus must not retain
        // every decoded transcript merely to check the import provenance.
        var row_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer row_arena.deinit();
        const row_a = row_arena.allocator();
        var row_db = db;
        row_db.a = row_a;
        const marker = C.get(try row_db.value(query, 6), "c2c");
        const imported = if (C.s(marker, "sourceProvider").len > 0 and C.s(marker, "sourceSessionId").len > 0)
            try origin(row_a, try rowNative(row_a, &row_db, query))
        else
            Origin{};
        const parent = try row_db.string(query, 5);
        try out.append(.{ .id = try db.string(query, 0), .title = try db.string(query, 1), .cwd = try db.string(query, 2), .rollout_path = path, .created_at = try C.timestamp(a, sql.sqlite3_column_int64(query, 3)), .updated_at = try C.timestamp(a, sql.sqlite3_column_int64(query, 4)), .parent_id = if (parent.len > 0) try a.dupe(u8, parent) else null, .provider = "opencode", .source = "cli", .archived = sql.sqlite3_column_type(query, 7) != sql.SQLITE_NULL, .origin_provider = if (imported.provider) |value| try a.dupe(u8, value) else null, .origin_id = if (imported.original_id) |value| try a.dupe(u8, value) else null, .unchanged_import = imported.unchanged });
    }
    return out.toOwnedSlice();
}

fn envelope(a: A, id: []const u8, role: []const u8, time: []const u8, content: []const V) !V {
    return C.obj(a, &.{ .{ "uuid", S(id) }, .{ "type", S(role) }, .{ "timestamp", S(time) }, .{ "message", try C.obj(a, &.{ .{ "role", S(role) }, .{ "content", try C.arr(a, content) } }) } });
}
fn fileBlock(a: A, file: V) !V {
    const mime = C.s(file, "mime");
    if (std.mem.startsWith(u8, mime, "image/")) return C.obj(a, &.{ .{ "type", S("image") }, .{ "source", try C.obj(a, &.{ .{ "type", S("base64") }, .{ "media_type", S(mime) }, .{ "data", C.get(file, "data") } }) } });
    return textBlock(a, try C.fmt(a, "[OpenCode attachment]\n{s}", .{try C.json(a, file)}));
}
pub fn readEntries(a: A, thread: C.Thread, warnings: *C.Warnings) ![]V {
    const home = std.fs.path.dirname(thread.rollout_path) orelse return error.InvalidOpenCodeSourcePath;
    const data = (try readNative(a, home, thread.id)) orelse return error.OpenCodeSessionMissing;
    return readDataEntries(a, data, warnings);
}
fn readDataEntries(a: A, data: V, warnings: *C.Warnings) ![]V {
    var out = Values.init(a);
    for (C.list(C.get(data, "messages"))) |message| {
        const kind = C.s(message, "type");
        const id = C.s(message, "id");
        const time = try C.timestamp(a, C.integer(C.get(C.get(message, "time"), "created")));
        if (C.eq(kind, "user")) {
            var content = Values.init(a);
            if (C.s(message, "text").len > 0) try content.append(try textBlock(a, C.s(message, "text")));
            for (C.list(C.get(message, "files"))) |file| try content.append(try fileBlock(a, file));
            if (content.items.len > 0) try out.append(try envelope(a, id, "user", time, content.items));
        } else if (C.eq(kind, "assistant")) {
            for (C.list(C.get(message, "content")), 0..) |part, index| {
                const part_id = try C.fmt(a, "{s}:{d}", .{ id, index });
                if (C.eq(C.s(part, "type"), "text")) {
                    if (C.s(part, "text").len > 0) try out.append(try envelope(a, part_id, "assistant", time, &.{try textBlock(a, C.s(part, "text"))}));
                } else if (C.eq(C.s(part, "type"), "tool")) {
                    const state = C.get(part, "state");
                    const call_id = C.s(part, "id");
                    var input = C.get(state, "input");
                    if (input != .object) input = try C.obj(a, &.{.{ "historicalInput", input }});
                    const call = try C.obj(a, &.{ .{ "type", S("tool_use") }, .{ "id", S(call_id) }, .{ "name", C.get(part, "name") }, .{ "input", input } });
                    try out.append(try envelope(a, part_id, "assistant", time, &.{call}));
                    var content = Values.init(a);
                    for (C.list(C.get(state, "content"))) |block| {
                        if (C.eq(C.s(block, "type"), "text")) try content.append(try textBlock(a, C.s(block, "text"))) else if (C.eq(C.s(block, "type"), "file") and std.mem.startsWith(u8, C.s(block, "uri"), "data:image/")) {
                            const uri = C.s(block, "uri");
                            if (std.mem.indexOf(u8, uri, ";base64,")) |split| try content.append(try fileBlock(a, try C.obj(a, &.{ .{ "mime", S(uri[5..split]) }, .{ "data", S(uri[split + 8 ..]) } }))) else try content.append(try textBlock(a, try C.json(a, block)));
                        } else try content.append(try textBlock(a, try C.json(a, block)));
                    }
                    if (C.get(state, "metadata") != .null)
                        try content.append(try textBlock(a, try C.fmt(a, "[Historical tool metadata]\n{s}", .{try C.json(a, C.get(state, "metadata"))})));
                    if (C.get(state, "error") != .null)
                        try content.append(try textBlock(a, try C.fmt(a, "[Historical tool error]\n{s}", .{try C.json(a, C.get(state, "error"))})));
                    const status = C.s(state, "status");
                    const failed = !C.eq(status, "completed");
                    if (content.items.len == 0) {
                        const detail = C.s(C.get(state, "error"), "message");
                        try content.append(try textBlock(a, if (detail.len > 0) detail else "Historical tool had no saved result; c2c did not execute it."));
                        if (!C.eq(status, "error")) try warnings.append("Incomplete OpenCode tool preserved with an explicit historical result");
                    }
                    const result = try C.obj(a, &.{ .{ "type", S("tool_result") }, .{ "tool_use_id", S(call_id) }, .{ "content", try C.arr(a, content.items) }, .{ "is_error", C.boolean(failed) } });
                    try out.append(try envelope(a, try C.fmt(a, "{s}:result", .{part_id}), "user", time, &.{result}));
                }
            }
            if (C.get(message, "error") != .null)
                try out.append(try envelope(a, try C.fmt(a, "{s}:error", .{id}), "assistant", time, &.{try textBlock(a, try C.fmt(a, "[Historical OpenCode response error]\n{s}", .{try C.json(a, C.get(message, "error"))}))}));
        } else if (C.eq(kind, "compaction") and C.eq(C.s(message, "status"), "completed")) {
            if (C.get(message, "providerContext") != .null) try warnings.append("OpenCode provider-specific compaction state omitted; readable summary and full history retained");
            if (std.mem.trim(u8, C.s(message, "summary"), " \t\r\n").len == 0 and
                std.mem.trim(u8, C.s(message, "recent"), " \t\r\n").len == 0)
            {
                try warnings.append("OpenCode compaction had no readable summary; earlier visible history remains active");
                continue;
            }
            try out.append(try C.obj(a, &.{ .{ "type", S("system") }, .{ "subtype", S("compact_boundary") }, .{ "timestamp", S(time) }, .{ "uuid", S(id) } }));
            var summary = try envelope(a, try C.fmt(a, "{s}:summary", .{id}), "user", time, &.{try textBlock(a, try C.fmt(a, "{s}\n{s}", .{ C.s(message, "summary"), C.s(message, "recent") }))});
            try C.set(a, &summary, "isCompactSummary", C.boolean(true));
            try out.append(summary);
        } else if (C.eq(kind, "shell")) {
            try out.append(try envelope(a, id, "assistant", time, &.{try textBlock(a, try C.fmt(a, "[Historical OpenCode shell]\n{s}", .{try C.json(a, message)}))}));
        } else if (C.eq(kind, "synthetic")) {
            try out.append(try envelope(a, id, "user", time, &.{try textBlock(a, C.s(message, "text"))}));
        }
        // System/skill instructions, private reasoning and provider state are
        // runtime context, not user-visible conversation messages.
    }
    return out.toOwnedSlice();
}

const Encoder = struct {
    a: A,
    sid: []const u8,
    messages: Values,
    warnings: C.Warnings,
    count: usize = 0,
    tools: usize = 0,
    source_count: usize = 0,
    pending: std.StringHashMap(V),
    fn nextId(self: *Encoder) ![]const u8 {
        self.count += 1;
        return C.fmt(self.a, "msg_{s}", .{try C.sessionIdFor(self.a, "opencode-message", self.sid, try C.fmt(self.a, "{d}", .{self.count}))});
    }
    fn base(self: *Encoder, kind: []const u8, timestamp: i64) !V {
        return C.obj(self.a, &.{ .{ "id", S(try self.nextId()) }, .{ "type", S(kind) }, .{ "time", try C.obj(self.a, &.{.{ "created", N(timestamp) }}) } });
    }
    fn plain(self: *Encoder, role: []const u8, content: []const V, timestamp: i64, embed: bool) !void {
        var message = try self.base(role, timestamp);
        var text = std.array_list.Managed([]const u8).init(self.a);
        var files = Values.init(self.a);
        var assistant = Values.init(self.a);
        for (content) |block| {
            const kind = C.s(block, "type");
            if (C.eq(kind, "text")) {
                if (C.eq(role, "user")) try text.append(C.s(block, "text")) else try assistant.append(try textBlock(self.a, C.s(block, "text")));
            } else if (C.eq(kind, "image")) {
                const source = C.get(block, "source");
                if (embed and C.eq(C.s(source, "type"), "base64") and C.eq(role, "user")) {
                    try files.append(try C.obj(self.a, &.{ .{ "data", C.get(source, "data") }, .{ "mime", C.get(source, "media_type") }, .{ "source", try C.obj(self.a, &.{.{ "type", S("inline") }}) } }));
                } else {
                    const detail = if (embed) try C.fmt(self.a, "[Historical image attachment]\n{s}", .{try C.json(self.a, block)}) else "[Image bytes retained in the original conversation.]";
                    if (C.eq(role, "user")) try text.append(detail) else try assistant.append(try textBlock(self.a, detail));
                }
            } else if (C.eq(kind, "tool_use") and C.eq(role, "assistant")) {
                const call_id = C.s(block, "id");
                if (self.pending.contains(call_id)) return error.DuplicatePendingToolCall;
                const tool = try C.obj(self.a, &.{ .{ "type", S("tool") }, .{ "id", S(call_id) }, .{ "name", C.get(block, "name") }, .{ "state", try C.obj(self.a, &.{ .{ "status", S("error") }, .{ "input", C.get(block, "input") }, .{ "error", try C.obj(self.a, &.{ .{ "type", S("historical") }, .{ "message", S("No saved result; c2c did not execute this historical tool.") } }) } }) }, .{ "time", try C.obj(self.a, &.{ .{ "created", N(timestamp) }, .{ "completed", N(timestamp) } }) } });
                try assistant.append(tool);
                try self.pending.put(call_id, tool);
                self.tools += 1;
            } else if (!C.eq(kind, "tool_result") and !C.eq(kind, "thinking") and !C.eq(kind, "redacted_thinking")) {
                const detail = try C.fmt(self.a, "[Historical attachment]\n{s}", .{try C.json(self.a, block)});
                if (C.eq(role, "user")) try text.append(detail) else try assistant.append(try textBlock(self.a, detail));
            }
        }
        if (C.eq(role, "user")) {
            if (text.items.len == 0 and files.items.len == 0) return;
            try C.set(self.a, &message, "text", S(try std.mem.join(self.a, "\n", text.items)));
            if (files.items.len > 0) try C.set(self.a, &message, "files", try C.arr(self.a, files.items));
        } else {
            if (assistant.items.len == 0) return;
            try C.set(self.a, &message, "agent", S("build"));
            try C.set(self.a, &message, "model", try model(self.a));
            try C.set(self.a, &message, "content", try C.arr(self.a, assistant.items));
            try C.set(self.a, &message, "finish", S("stop"));
            var time = C.get(message, "time");
            try C.set(self.a, &time, "completed", N(timestamp));
            try C.set(self.a, &message, "time", time);
        }
        try self.messages.append(message);
    }
    fn result(self: *Encoder, block: V, timestamp: i64, embed: bool) !void {
        const saved = self.pending.fetchRemove(C.s(block, "tool_use_id"));
        if (saved == null) {
            try self.plain("assistant", &.{try textBlock(self.a, try C.fmt(self.a, "[Unpaired historical tool result]\n{s}", .{try C.json(self.a, block)}))}, timestamp, embed);
            try self.warnings.append("Unpaired tool result preserved as an explicit transcript artifact");
            return;
        }
        var tool = saved.?.value;
        var content = Values.init(self.a);
        for (try blocks(self.a, C.get(block, "content"))) |part| {
            if (C.eq(C.s(part, "type"), "text")) try content.append(try textBlock(self.a, C.s(part, "text"))) else if (embed and C.eq(C.s(part, "type"), "image") and C.eq(C.s(C.get(part, "source"), "type"), "base64")) {
                const source = C.get(part, "source");
                try content.append(try C.obj(self.a, &.{ .{ "type", S("file") }, .{ "mime", C.get(source, "media_type") }, .{ "uri", S(try C.fmt(self.a, "data:{s};base64,{s}", .{ C.s(source, "media_type"), C.s(source, "data") })) } }));
            } else try content.append(try textBlock(self.a, if (embed) try C.json(self.a, part) else "[Attachment retained in original conversation.]"));
        }
        if (content.items.len == 0) try content.append(try textBlock(self.a, ""));
        var state = try C.obj(self.a, &.{ .{ "status", S(if (C.b(C.get(block, "is_error"))) "error" else "completed") }, .{ "input", C.get(C.get(tool, "state"), "input") }, .{ "content", try C.arr(self.a, content.items) } });
        if (C.b(C.get(block, "is_error"))) try C.set(self.a, &state, "error", try C.obj(self.a, &.{ .{ "type", S("historical") }, .{ "message", S("Historical tool returned an error; see its saved output.") } }));
        // Object backing storage is shared with the already appended assistant.
        try C.set(self.a, &tool, "state", state);
    }
};

pub fn convert(a: A, thread: C.Thread, entries: []const V, opts: C.ConvertOptions) !C.Conversion {
    const provider = opts.source_provider orelse thread.provider;
    const original_id = opts.source_session_id orelse thread.id;
    const sid = try sessionId(a, provider, original_id);
    var encoder = Encoder{ .a = a, .sid = sid, .messages = Values.init(a), .warnings = C.Warnings.init(a), .pending = std.StringHashMap(V).init(a) };
    var boundary = false;
    for (entries) |entry| {
        if (C.eq(C.s(entry, "subtype"), "compact_boundary")) {
            boundary = true;
            continue;
        }
        const role = C.s(entry, "type");
        if (!C.eq(role, "user") and !C.eq(role, "assistant")) continue;
        encoder.source_count += 1;
        const timestamp = C.timestampMillis(C.s(entry, "timestamp")) catch try C.timestampMillis(thread.updated_at);
        const content = try blocks(a, C.get(C.get(entry, "message"), "content"));
        if ((boundary or C.b(C.get(entry, "isCompactSummary"))) and C.eq(role, "user")) {
            var strings = std.array_list.Managed([]const u8).init(a);
            for (content) |block| if (C.eq(C.s(block, "type"), "text")) {
                try strings.append(C.s(block, "text"));
            };
            var checkpoint = try encoder.base("compaction", timestamp);
            try C.set(a, &checkpoint, "status", S("completed"));
            try C.set(a, &checkpoint, "reason", S("manual"));
            try C.set(a, &checkpoint, "summary", S(try std.mem.join(a, "\n", strings.items)));
            try C.set(a, &checkpoint, "recent", S(""));
            try encoder.messages.append(checkpoint);
            boundary = false;
        } else {
            for (content) |block| if (C.eq(C.s(block, "type"), "tool_result")) {
                try encoder.result(block, timestamp, opts.embed_images);
            };
            try encoder.plain(role, content, timestamp, opts.embed_images);
        }
    }
    if (encoder.pending.count() > 0) try encoder.warnings.append("Incomplete historical calls retained as completed error records without execution");
    if (encoder.messages.items.len == 0) return .{ .entries = &.{}, .session_id = sid };
    var active_start: usize = 0;
    for (encoder.messages.items, 0..) |message, index| if (C.eq(C.s(message, "type"), "compaction")) {
        active_start = index;
    };
    const active = encoder.messages.items[active_start..];
    if ((try C.json(a, try C.arr(a, active))).len > MAX_ACTIVE_BYTES) {
        var selected = Values.init(a);
        var size: usize = 0;
        var i = active.len;
        while (i > 0) {
            i -= 1;
            const encoded = try C.json(a, active[i]);
            var value = active[i];
            if (encoded.len > 24_000) {
                var head: usize = 4000;
                while (head > 0 and !std.unicode.utf8ValidateSlice(encoded[0..head])) head -= 1;
                var tail = encoded.len - 8000;
                while (tail < encoded.len and !std.unicode.utf8ValidateSlice(encoded[tail..])) tail += 1;
                value = try C.obj(a, &.{ .{ "type", S("historical-excerpt") }, .{ "originalMessageID", C.get(active[i], "id") }, .{ "text", S(try C.fmt(a, "{s}\n[...c2c excerpt; complete original remains in native session...]\n{s}", .{ encoded[0..head], encoded[tail..] })) } });
            }
            const amount = (try C.json(a, value)).len;
            if (size + amount > 165_000) break;
            try selected.append(value);
            size += amount;
        }
        std.mem.reverse(V, selected.items);
        var checkpoint = try encoder.base("compaction", try C.timestampMillis(thread.updated_at));
        try C.set(a, &checkpoint, "status", S("completed"));
        try C.set(a, &checkpoint, "reason", S("manual"));
        try C.set(a, &checkpoint, "summary", S(try C.fmt(a, "c2c restored an extractive continuation window. Full visible history and exact attachments remain in this native OpenCode session. Earlier details can be retrieved by exporting session {s}. This is not a semantic summary; never re-execute historical tools. Archive receipt: {s}", .{ sid, opts.transcript_path orelse "the c2c import receipt" })));
        // recent is JSON stored inside a JSON string, so count its final escaped
        // representation rather than the first serialization of each message.
        while (true) {
            try C.set(a, &checkpoint, "recent", S(try C.json(a, try C.arr(a, selected.items))));
            if ((try C.json(a, checkpoint)).len <= MAX_ACTIVE_BYTES - 2000) break;
            if (selected.items.len > 1) {
                _ = selected.orderedRemove(0);
                continue;
            }
            // A pathological receipt path must not consume the context budget.
            try C.set(a, &checkpoint, "summary", S("c2c restored an extractive continuation window. Full history remains in this native session; use native session export to retrieve it. Do not re-execute historical tools."));
            if ((try C.json(a, checkpoint)).len <= MAX_ACTIVE_BYTES - 2000) break;
            return error.OpenCodeCheckpointBudgetExceeded;
        }
        try encoder.messages.append(checkpoint);
        try encoder.warnings.append("Large OpenCode history preserved in full; active context uses a labelled extractive window");
    }
    const marker = try C.obj(a, &.{ .{ "schemaVersion", N(1) }, .{ "sourceProvider", S(provider) }, .{ "sourceSessionId", S(original_id) } });
    var info = try C.obj(a, &.{ .{ "id", S(sid) }, .{ "projectID", S("global") }, .{ "title", S(thread.title) }, .{ "location", try C.obj(a, &.{.{ "directory", S(thread.cwd) }}) }, .{ "cost", N(0) }, .{ "tokens", try zeroTokens(a) }, .{ "time", try C.obj(a, &.{ .{ "created", N(try C.timestampMillis(thread.created_at)) }, .{ "updated", N(try C.timestampMillis(thread.updated_at)) } }) }, .{ "metadata", try C.obj(a, &.{.{ "c2c", marker }}) } });
    var data = try C.obj(a, &.{ .{ "info", info }, .{ "messages", try C.arr(a, encoder.messages.items) } });
    var annotated = marker;
    try C.set(a, &annotated, "fingerprint", S(try fingerprint(a, data, true)));
    try C.set(a, &info, "metadata", try C.obj(a, &.{.{ "c2c", annotated }}));
    try C.set(a, &data, "info", info);
    const output = try a.dupe(V, &.{data});
    if ((try validate(a, output)).len > 0) return error.InvalidOpenCodeTransfer;
    return .{ .entries = output, .session_id = sid, .message_count = encoder.messages.items.len, .tool_count = encoder.tools, .source_item_count = encoder.source_count, .warnings = try encoder.warnings.toOwnedSlice() };
}
pub fn validate(a: A, entries: []const V) ![][]const u8 {
    var errors = C.Warnings.init(a);
    if (entries.len != 1 or C.get(entries[0], "info") != .object or C.get(entries[0], "messages") != .array) {
        try errors.append("OpenCode transfer must be one object with info and messages");
        return errors.toOwnedSlice();
    }
    if (!validId(C.s(C.get(entries[0], "info"), "id"), "ses_")) try errors.append("Invalid OpenCode session ID");
    var ids = std.StringHashMap(void).init(a);
    defer ids.deinit();
    for (C.list(C.get(entries[0], "messages"))) |message| {
        const id = C.s(message, "id");
        if (!validId(id, "msg_") or ids.contains(id)) try errors.append("Invalid or duplicate OpenCode message ID");
        try ids.put(id, {});
        if (C.eq(C.s(message, "type"), "assistant") and C.get(C.get(message, "time"), "completed") == .null)
            try errors.append("Imported assistant must be settled so native import cannot silently discard it");
    }
    if (ids.count() == 0) try errors.append("OpenCode transfer has no messages");
    return errors.toOwnedSlice();
}
pub fn registrationMatches(a: A, staged: []const V, native: V) !bool {
    return staged.len == 1 and C.eq(try fingerprint(a, staged[0], false), try fingerprint(a, native, false));
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
    const path = try receiptPath(a, home, id);
    const staged = try C.parse(a, try C.readFile(a, path));
    if (!C.eq(C.s(C.get(staged, "info"), "id"), id)) return error.OpenCodeReceiptIdentityMismatch;
    const env = try environment(a, home);
    const version = try requireVersion(a, env);
    if (try readNative(a, home, id)) |existing| {
        if (!(try registrationMatches(a, &.{staged}, existing))) return error.OpenCodeSessionCollision;
    } else {
        const result = try C.run(a, &.{ binary(), "session", "import", "--standalone", "--directory", C.s(C.get(C.get(staged, "info"), "location"), "directory"), path }, env, null, 120_000);
        if (result.exit_code != 0) return error.OpenCodeNativeImportFailed;
        const imported = (try readNative(a, home, id)) orelse return error.OpenCodeImportDidNotCreateSession;
        if (!(try registrationMatches(a, &.{staged}, imported))) return error.OpenCodeNativeImportMismatch;
    }
    return C.obj(a, &.{ .{ "status", S("registered") }, .{ "session_id", S(id) }, .{ "native_version", S(version) } });
}
pub fn unregister(a: A, home: []const u8, id: []const u8) !void {
    const native = (try readNative(a, home, id)) orelse return;
    if (!(try origin(a, native)).unchanged) return error.OpenCodeSessionChanged;
    // Native delete cascades into children. Refuse if any exist rather than
    // deleting a fork or other conversation the user created after import.
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

test "OpenCode provider identities are distinct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(!C.eq(try sessionId(a, "codex", "same"), try sessionId(a, "claude", "same")));
}

test "OpenCode conversion retains tools and completed native records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const thread = C.Thread{ .id = "source-fixture", .title = "Fixture", .cwd = "/tmp", .created_at = "2026-10-01T10:00:00.000Z", .updated_at = "2026-10-01T10:00:00.000Z", .rollout_path = "/tmp/source", .provider = "claude" };
    const user = try envelope(a, "u", "user", thread.created_at, &.{try textBlock(a, "Fixture user")});
    const call = try envelope(a, "a", "assistant", thread.created_at, &.{try C.obj(a, &.{ .{ "type", S("tool_use") }, .{ "id", S("fixture-call") }, .{ "name", S("Bash") }, .{ "input", try C.obj(a, &.{.{ "command", S("printf fixture") }}) } })});
    const result = try envelope(a, "r", "user", thread.created_at, &.{try C.obj(a, &.{ .{ "type", S("tool_result") }, .{ "tool_use_id", S("fixture-call") }, .{ "content", S("fixture") } })});
    const converted = try convert(a, thread, &.{ user, call, result }, .{});
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, converted.entries)).len);
    const messages = C.list(C.get(converted.entries[0], "messages"));
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    const tool = C.list(C.get(messages[1], "content"))[0];
    try std.testing.expectEqualStrings("completed", C.s(C.get(tool, "state"), "status"));
    try std.testing.expect((try origin(a, converted.entries[0])).unchanged);
    try std.testing.expect(try registrationMatches(a, converted.entries, converted.entries[0]));
    try std.testing.expect((try readNative(a, "/tmp/c2c-no-such-opencode-database", "fixture")) == null);
    try std.testing.expectEqual(@as(usize, 0), (try listThreads(a, "/tmp/c2c-no-such-opencode-database")).len);
}

test "OpenCode checkpoint counts nested JSON escaping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const thread = C.Thread{ .id = "escaped-fixture", .title = "Escaping", .cwd = "/tmp", .created_at = "2026-10-01T10:00:00.000Z", .updated_at = "2026-10-01T10:00:00.000Z", .rollout_path = "/tmp/source", .provider = "claude" };
    const noisy = try std.mem.join(a, "", try a.dupe([]const u8, &([_][]const u8{"\\\"\n\r\t\x01"} ** 1500)));
    var entries = Values.init(a);
    for (0..50) |index| try entries.append(try envelope(a, try C.fmt(a, "entry-{d}", .{index}), if (index % 2 == 0) "user" else "assistant", thread.created_at, &.{try textBlock(a, noisy)}));
    try entries.append(try envelope(a, "last", "user", thread.created_at, &.{try textBlock(a, "NEWEST_EXACT_REQUEST")}));
    const converted = try convert(a, thread, entries.items, .{});
    const messages = C.list(C.get(converted.entries[0], "messages"));
    try std.testing.expectEqual(@as(usize, 52), messages.len);
    const checkpoint = messages[messages.len - 1];
    try std.testing.expectEqualStrings("compaction", C.s(checkpoint, "type"));
    try std.testing.expect((try C.json(a, checkpoint)).len + 2000 <= MAX_ACTIVE_BYTES);
    try std.testing.expect(std.mem.indexOf(u8, C.s(checkpoint, "recent"), "NEWEST_EXACT_REQUEST") != null);
    try std.testing.expectEqualStrings(noisy, C.s(messages[0], "text"));
}

test "OpenCode opaque compaction preserves active visible history" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const native = try C.parse(a,
        \\{"messages":[{"id":"msg_user","type":"user","time":{"created":1},"text":"Retain original instruction"},{"id":"msg_compact","type":"compaction","time":{"created":2},"status":"completed","reason":"auto","providerContext":{"opaque":"private"}}]}
    );
    var warnings = C.Warnings.init(a);
    const entries = try readDataEntries(a, native, &warnings);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("user", C.s(entries[0], "type"));
    try std.testing.expect(warnings.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, try C.json(a, try C.arr(a, entries)), "private") == null);
}

test "OpenCode tool metadata errors and shell exit remain visible" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const native = try C.parse(a,
        \\{"messages":[{"id":"msg_tool","type":"assistant","time":{"created":1},"content":[{"type":"tool","id":"call_fixture","name":"lookup","state":{"status":"error","input":{},"content":[{"type":"text","text":"partial output"}],"error":{"type":"fixture","message":"failed lookup"},"metadata":{"structured":{"count":7}}}}]},{"id":"msg_shell","type":"shell","time":{"created":2},"command":"exit 3","status":"completed","output":{"output":"saved stdout","exit":3}},{"id":"msg_error","type":"assistant","time":{"created":3},"content":[],"error":{"type":"provider","message":"provider unavailable"}}]}
    );
    var warnings = C.Warnings.init(a);
    const entries = try readDataEntries(a, native, &warnings);
    const encoded = try C.json(a, try C.arr(a, entries));
    for ([_][]const u8{ "partial output", "failed lookup", "structured", "count", "exit", "saved stdout", "provider unavailable" }) |value|
        try std.testing.expect(std.mem.indexOf(u8, encoded, value) != null);
}
