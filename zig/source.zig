const std = @import("std");
const common = @import("common.zig");
const storage = @import("source/storage.zig");
const normalize = @import("source/normalize.zig");
const recovery = @import("source/recovery.zig");
const Allocator = common.Allocator;
pub const Thread = common.Thread;
pub const Item = common.Item;
pub const Compaction = common.Compaction;
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
const eq = common.eq;

fn appendRollout(
    allocator: Allocator,
    items: *Items,
    thread: Thread,
    offset: u64,
    start_ordinal: i64,
    warnings: *common.Warnings,
) !void {
    var records = try Records.open(allocator, thread.rollout_path, offset, start_ordinal, warnings);
    defer records.close();
    while (try records.next()) |record| {
        if (!eq(common.stringField(record.value, "type"), "response_item")) {
            continue;
        }
        const raw_timestamp = common.get(record.value, "timestamp");
        const payload = common.get(record.value, "payload");
        const item_timestamp = if (raw_timestamp == .null)
            thread.updated_at
        else
            try timestamp(allocator, raw_timestamp, false);
        const normalized = try response(allocator, payload, item_timestamp, record.ordinal, thread.id, warnings);
        if (normalized) |item| {
            const resolved_item = try resolved(allocator, item, thread);
            try items.append(resolved_item);
        }
    }
}

pub fn readItems(allocator: Allocator, thread: Thread, codex_home: []const u8, warnings: *common.Warnings) ![]Item {
    const home = try canonical(allocator, codex_home);
    var items = Items.init(allocator);
    var has_projected = false;
    var cursor: ?struct {
        offset: u64,
        ordinal: i64,
    } = null;
    if (try latestDatabase(allocator, home, "thread_history")) |path| {
        const db = try Database.open(allocator, path);
        defer db.close();
        if (try db.hasTable("thread_items")) {
            if (try db.hasTable("thread_history_projection_state")) {
                const statement = try db.prepare(
                    "SELECT next_rollout_byte_offset,next_rollout_ordinal " ++
                        "FROM thread_history_projection_state WHERE thread_id=?",
                );
                defer statement.close();
                try statement.bind(1, thread.id);
                if (try statement.next()) {
                    const offset = statement.int(0);
                    const ordinal = statement.int(1);
                    if (offset < 0 or ordinal < 0) {
                        return error.InvalidProjectionCursor;
                    }
                    cursor = .{ .offset = @intCast(offset), .ordinal = ordinal };
                }
            }
            const statement = try db.prepare(
                "SELECT item_id,item_json,created_at_ms,rollout_ordinal " ++
                    "FROM thread_items WHERE thread_id=? ORDER BY rollout_ordinal,item_id",
            );
            defer statement.close();
            try statement.bind(1, thread.id);
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            while (try statement.next()) {
                has_projected = true;
                _ = arena.reset(.retain_capacity);
                const value = common.parse(arena.allocator(), statement.text(1)) catch return error.MalformedSourceJson;
                if (value != .object) {
                    return error.ExpectedSourceObject;
                }
                const item_id = statement.text(0);
                const created_at = try common.timestamp(allocator, statement.int(2));
                const ordinal = statement.int(3);
                const normalized = try projected(allocator, value, item_id, created_at, ordinal, warnings);
                if (normalized) |item| {
                    const resolved_item = try resolved(allocator, item, thread);
                    try items.append(resolved_item);
                }
            }
        }
    }
    if (has_projected or cursor != null) {
        const projected_end = if (cursor) |position| position.offset else null;
        try recovery.recover(allocator, &items, thread, warnings, projected_end);
        if (cursor) |position| {
            if (common.exists(thread.rollout_path)) {
                try appendRollout(allocator, &items, thread, position.offset, position.ordinal, warnings);
            }
        } else {
            const warning = try common.fmt(
                allocator,
                "Projected thread has no projection cursor; live tail cannot be verified",
                .{},
            );
            try warnings.append(warning);
        }
        return items.toOwnedSlice();
    }
    if (!common.exists(thread.rollout_path)) {
        return error.SourceHistoryUnavailable;
    }
    try appendRollout(allocator, &items, thread, 0, 0, warnings);
    return items.toOwnedSlice();
}

pub fn readCompaction(allocator: Allocator, thread: Thread, warnings: *common.Warnings) !?Compaction {
    if (!common.exists(thread.rollout_path)) {
        return null;
    }
    var records = try Records.open(allocator, thread.rollout_path, 0, 0, warnings);
    records.compactions_only = true;
    defer records.close();
    var latest_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer latest_arena.deinit();
    var latest: ?Records.Record = null;
    while (try records.next()) |record| {
        if (!eq(common.stringField(record.value, "type"), "compacted")) {
            continue;
        }
        _ = latest_arena.reset(.free_all);
        latest = .{ .ordinal = record.ordinal, .value = try common.clone(latest_arena.allocator(), record.value) };
    }
    const record = latest orelse return null;
    const payload = common.get(record.value, "payload");
    var summary = common.stringField(payload, "message");
    const replacement = common.list(common.get(payload, "replacement_history"));
    if (summary.len == 0) {
        var summaries = Strings.init(allocator);
        for (replacement) |entry| {
            const is_summary = eq(common.stringField(entry, "type"), "message") and
                eq(common.stringField(entry, "role"), "assistant") and
                eq(common.stringField(entry, "channel"), "summary");
            if (is_summary) {
                const parsed = try content(allocator, common.get(entry, "content"), warnings);
                try summaries.append(parsed.text);
            }
        }
        summary = try std.mem.join(allocator, "\n\n", summaries.items);
    } else {
        summary = try allocator.dupe(u8, summary);
    }
    const raw_timestamp = common.get(record.value, "timestamp");
    const compaction_timestamp = if (raw_timestamp == .null)
        thread.updated_at
    else
        try timestamp(allocator, raw_timestamp, false);
    var items = Items.init(allocator);
    var encrypted = false;
    for (replacement, 0..) |entry, index| {
        if (eq(common.stringField(entry, "type"), "compaction") and common.stringField(entry, "encrypted_content").len != 0) {
            encrypted = true;
        }
        const is_summary = eq(common.stringField(entry, "type"), "message") and
            eq(common.stringField(entry, "role"), "assistant") and
            eq(common.stringField(entry, "channel"), "summary");
        if (is_summary) {
            continue;
        }
        const prefix = try common.fmt(allocator, "{s}:compaction:{d}", .{ thread.id, index });
        const normalized = try response(allocator, entry, compaction_timestamp, record.ordinal, prefix, warnings);
        if (normalized) |item| {
            if (summary.len != 0 and eq(item.role, "assistant") and eq(item.text, summary)) {
                continue;
            }
            const resolved_item = try resolved(allocator, item, thread);
            try items.append(resolved_item);
        }
    }
    return .{
        .summary = summary,
        .items = try items.toOwnedSlice(),
        .timestamp = compaction_timestamp,
        .ordinal = record.ordinal,
        .encrypted = encrypted,
    };
}
