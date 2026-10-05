const std = @import("std");
const H = @import("../common.zig");
const A = H.Allocator;
const V = H.Value;
const eq = H.eq;
const storage = @import("storage.zig");
const normalize = @import("normalize.zig");
const Thread = H.Thread;
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
fn truth(value: V) bool {
    return H.b(value) or (value == .integer and value.integer != 0);
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
            while (try stmt.next()) try parents.put(try a.dupe(u8, stmt.text(0)), try a.dupe(u8, stmt.text(1)));
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
            const origin = try @import("../codex.zig").readOrigin(a, thread.*);
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
