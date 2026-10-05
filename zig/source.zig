const std = @import("std");
const H = @import("common.zig");
const storage = @import("source/storage.zig");
const normalize = @import("source/normalize.zig");
const recovery = @import("source/recovery.zig");
const A = H.Allocator;
pub const Thread = H.Thread;
pub const Item = H.Item;
pub const Compaction = H.Compaction;
pub const latestDatabase = storage.latestDatabase;
pub const listThreads = @import("source/discovery.zig").listThreads;
pub const recoverProjectedImages = recovery.recoverProjectedImages;
const Strings = std.array_list.Managed([]const u8);
const Items = std.array_list.Managed(Item);
const Records = storage.Records;
const Database = storage.Database;
const canonical = storage.canonical;
const timestamp = normalize.timestamp;
const content = normalize.content;
const projected = normalize.projected;
const response = normalize.response;
const resolved = normalize.resolved;
const eq = H.eq;

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
        try recovery.recover(a, &items, thread, warnings, if (cursor) |position| position.offset else null);
        if (cursor) |position| {
            if (H.exists(thread.rollout_path)) try appendRollout(a, &items, thread, position.offset, position.ordinal, warnings);
        } else try warnings.append(try H.fmt(a, "Projected thread has no projection cursor; live tail cannot be verified", .{}));
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
    } else summary = try a.dupe(u8, summary);
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
