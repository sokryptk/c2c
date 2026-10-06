const std = @import("std");
const common = @import("../common.zig");
const Allocator = common.Allocator;
const Value = common.Value;
const eq = common.eq;
const storage = @import("storage.zig");
const normalize = @import("normalize.zig");
const Thread = common.Thread;
const Records = storage.Records;
const Database = storage.Database;
const latestDatabase = storage.latestDatabase;
const canonical = storage.canonical;
const absolute = storage.absolute;
const timestamp = normalize.timestamp;
const first = normalize.first;

fn optional(value: []const u8) ?[]const u8 {
    return if (value.len == 0) null else value;
}

fn truth(value: Value) bool {
    return common.boolValue(value) or (value == .integer and value.integer != 0);
}

fn metadata(allocator: Allocator, path: []const u8) !Value {
    if (!common.exists(path)) {
        return .null;
    }
    var warnings = common.Warnings.init(allocator);
    var records = try Records.open(allocator, path, 0, 0, &warnings);
    defer records.close();
    if (try records.next()) |record| {
        if (eq(common.stringField(record.value, "type"), "session_meta")) {
            return common.clone(allocator, common.get(record.value, "payload"));
        }
    }
    return .null;
}

fn sourceParent(allocator: Allocator, source: Value) !?[]const u8 {
    const value = if (source == .string)
        common.parse(allocator, source.string) catch return null
    else
        source;
    const subagent = common.get(value, "subagent");
    const thread_spawn = common.get(subagent, "thread_spawn");
    const parent = common.stringField(thread_spawn, "parent_thread_id");
    return optional(parent);
}

fn rolloutPath(allocator: Allocator, value: []const u8, home: []const u8) ![]const u8 {
    const path = try absolute(allocator, value, home);
    if (common.exists(path)) {
        return path;
    }
    for ([_][]const u8{ "/sessions/", "/archived_sessions/" }) |directory| {
        if (std.mem.indexOf(u8, path, directory)) |index| {
            const candidate = try common.join(allocator, &.{ home, path[index + 1 ..] });
            if (common.exists(candidate)) {
                return candidate;
            }
        }
    }
    return path;
}

pub fn listThreads(allocator: Allocator, codex_home: []const u8) ![]Thread {
    const home = try canonical(allocator, codex_home);
    var threads = std.StringHashMap(Thread).init(allocator);
    if (try latestDatabase(allocator, home, "state")) |path| {
        const db = try Database.open(allocator, path);
        defer db.close();
        if (!try db.hasTable("threads")) {
            return error.UnsupportedStateSchema;
        }
        var parents = std.StringHashMap([]const u8).init(allocator);
        if (try db.hasTable("thread_spawn_edges")) {
            const statement = try db.prepare("SELECT child_thread_id,parent_thread_id FROM thread_spawn_edges");
            defer statement.close();
            while (try statement.next()) {
                const child_id = try allocator.dupe(u8, statement.text(0));
                const parent_id = try allocator.dupe(u8, statement.text(1));
                try parents.put(child_id, parent_id);
            }
        }
        const statement = try db.prepare("SELECT * FROM threads");
        defer statement.close();
        while (try statement.next()) {
            const row = try statement.row(allocator);
            const id = common.stringField(row, "id");
            if (id.len == 0) {
                return error.MissingSourceThreadId;
            }
            const rollout = try rolloutPath(allocator, common.stringField(row, "rollout_path"), home);
            var parent = parents.get(id) orelse try sourceParent(allocator, common.get(row, "source"));
            if (parent == null) {
                const session_metadata = try metadata(allocator, rollout);
                const forked_from = common.stringField(session_metadata, "forked_from_id");
                const parent_thread = common.stringField(session_metadata, "parent_thread_id");
                parent = optional(first(forked_from, parent_thread));
            }
            const created_ms = common.get(row, "created_at_ms");
            const updated_ms = common.get(row, "updated_at_ms");
            const source_value = common.get(row, "source");
            const supplied_title = first(common.stringField(row, "name"), common.stringField(row, "title"));
            const default_title = try common.fmt(allocator, "Codex {s}", .{id});
            const created_value = if (created_ms != .null) created_ms else common.get(row, "created_at");
            const updated_value = if (updated_ms != .null) updated_ms else common.get(row, "updated_at");
            const thread = Thread{
                .id = id,
                .title = first(supplied_title, default_title),
                .cwd = common.stringField(row, "cwd"),
                .rollout_path = rollout,
                .parent_id = parent,
                .created_at = try timestamp(allocator, created_value, created_ms != .null),
                .updated_at = try timestamp(allocator, updated_value, updated_ms != .null),
                .source = if (source_value == .object)
                    try common.json(allocator, source_value)
                else
                    first(common.text(source_value), "cli"),
                .archived = truth(common.get(row, "archived")),
                .history_mode = first(common.stringField(row, "history_mode"), "legacy"),
            };
            try threads.put(id, thread);
        }
    }
    var known_paths = std.StringHashMap(void).init(allocator);
    var thread_values = threads.valueIterator();
    while (thread_values.next()) |thread| {
        const path = try canonical(allocator, thread.rollout_path);
        try known_paths.put(path, {});
    }
    for ([_][]const u8{ "sessions", "archived_sessions" }) |directory| {
        const root = try common.join(allocator, &.{ home, directory });
        if (!common.exists(root)) {
            continue;
        }
        for (try common.walkFiles(allocator, root, ".jsonl")) |path| {
            const canonical_path = try canonical(allocator, path);
            if (known_paths.contains(canonical_path)) {
                continue;
            }
            const session_metadata = try metadata(allocator, path);
            const id = first(common.stringField(session_metadata, "id"), common.stringField(session_metadata, "session_id"));
            if (id.len == 0 or threads.contains(id)) {
                continue;
            }
            const file_info = try common.stat(path);
            const millis: i64 = @intCast(@divTrunc(file_info.mtime_ns, std.time.ns_per_ms));
            const source_value = common.get(session_metadata, "source");
            const source_name = if (source_value == .object)
                try common.json(allocator, source_value)
            else
                first(common.text(source_value), "cli");
            const forked_from = common.stringField(session_metadata, "forked_from_id");
            const parent_thread = common.stringField(session_metadata, "parent_thread_id");
            const parent = optional(first(forked_from, parent_thread)) orelse try sourceParent(allocator, source_value);
            const supplied_title = common.stringField(session_metadata, "title");
            const default_title = try common.fmt(allocator, "Codex {s}", .{id});
            const created_value = common.get(session_metadata, "timestamp");
            const thread = Thread{
                .id = id,
                .title = first(supplied_title, default_title),
                .cwd = common.stringField(session_metadata, "cwd"),
                .rollout_path = path,
                .parent_id = parent,
                .created_at = if (created_value != .null)
                    try timestamp(allocator, created_value, false)
                else
                    try common.timestamp(allocator, millis),
                .updated_at = try common.timestamp(allocator, millis),
                .source = source_name,
                .archived = eq(directory, "archived_sessions"),
                .history_mode = first(common.stringField(session_metadata, "history_mode"), "legacy"),
            };
            try threads.put(id, thread);
        }
    }
    var result = std.array_list.Managed(Thread).init(allocator);
    thread_values = threads.valueIterator();
    while (thread_values.next()) |thread| {
        const session_metadata = try metadata(allocator, thread.rollout_path);
        const marker = common.stringField(session_metadata, "originator");
        const supported_origin = std.mem.startsWith(u8, marker, "c2c:claude:") or
            std.mem.startsWith(u8, marker, "c2c:omp:") or
            std.mem.startsWith(u8, marker, "c2c:opencode:");
        if (supported_origin) {
            const origin = try @import("../codex.zig").readOrigin(allocator, thread.*);
            thread.origin_provider = origin.provider;
            thread.origin_id = origin.original_id;
            thread.original_claude_id = if (eq(origin.provider orelse "", "claude"))
                origin.original_id
            else
                null;
            thread.unchanged_import = origin.unchanged;
        }
        try result.append(thread.*);
    }
    std.mem.sort(Thread, result.items, {}, struct {
        fn less(_: void, left: Thread, right: Thread) bool {
            const ordering = std.mem.order(u8, left.updated_at, right.updated_at);
            if (ordering == .eq) {
                return std.mem.order(u8, left.id, right.id) == .gt;
            }
            return ordering == .gt;
        }
    }.less);
    return result.toOwnedSlice();
}
