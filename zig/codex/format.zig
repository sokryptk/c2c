const std = @import("std");
const common = @import("../common.zig");
const Value = common.Value;
const Allocator = common.Allocator;
const jsonString = common.str;

pub const format_version = "0.159.2";

pub fn sessionId(allocator: Allocator, id: []const u8) ![]const u8 {
    return common.sessionIdFor(allocator, "codex", "claude", id);
}

pub fn targetPath(allocator: Allocator, thread: common.Thread, home: []const u8) ![]const u8 {
    return targetPathFor(allocator, thread, home, "claude");
}

pub fn targetPathFor(allocator: Allocator, thread: common.Thread, home: []const u8, provider: []const u8) ![]const u8 {
    const ts = try common.timestamp(allocator, try common.timestampMillis(thread.created_at));
    if (ts.len < 19) {
        return error.InvalidTimestamp;
    }
    const stamp = try allocator.dupe(u8, ts[0..19]);
    for (stamp) |*ch| {
        if (ch.* == ':') {
            ch.* = '-';
        }
    }
    const id = try common.sessionIdFor(allocator, "codex", provider, thread.id);
    const filename = try common.fmt(allocator, "rollout-{s}-{s}.jsonl", .{ stamp, id });
    return common.join(
        allocator,
        &.{
            home,
            "sessions",
            ts[0..4],
            ts[5..7],
            ts[8..10],
            filename,
        },
    );
}

fn is(v: Value, kind: []const u8) bool {
    return common.eq(common.stringField(v, "type"), kind);
}

pub fn validate(allocator: Allocator, entries: []const Value) ![][]const u8 {
    var errors = common.Warnings.init(allocator);
    if (entries.len == 0 or !is(entries[0], "session_meta")) {
        try errors.append("First record must be session_meta");
        return errors.toOwnedSlice();
    }
    const meta = common.get(entries[0], "payload");
    const mode = common.stringField(meta, "history_mode");
    if (!common.validUuid(common.stringField(meta, "id"))) {
        try errors.append("Session ID is not a UUID");
    }
    if (!common.eq(mode, "legacy") and !common.eq(mode, "paginated")) {
        try errors.append("Unknown native history mode");
    }
    var pending = std.StringHashMap(void).init(allocator);
    var turn: ?[]const u8 = null;
    for (entries) |row| {
        _ = common.timestampMillis(common.stringField(row, "timestamp")) catch {
            try errors.append("Invalid timestamp");
            continue;
        };
        const payload = common.get(row, "payload");
        if (is(row, "event_msg")) {
            if (is(payload, "task_started")) {
                if (turn != null) {
                    try errors.append("Overlapping turns");
                }
                turn = common.stringField(payload, "turn_id");
            } else if (is(payload, "task_complete")) {
                if (!common.eq(common.stringField(payload, "turn_id"), turn orelse "")) {
                    try errors.append("Mismatched turn completion");
                }
                turn = null;
            } else if (is(payload, "item_completed")) {
                if (!common.eq(common.stringField(payload, "turn_id"), turn orelse "") or
                    !common.eq(common.stringField(payload, "thread_id"), common.stringField(meta, "id")))
                {
                    try errors.append("Orphan visible item");
                }
            }
        } else if (is(row, "response_item")) {
            try validateResponse(payload, &pending, &errors);
        } else if (is(row, "compacted")) {
            if (pending.count() > 0) {
                try errors.append("Compaction interrupts pending tool calls");
            }
            var replacement_pending = std.StringHashMap(void).init(allocator);
            defer replacement_pending.deinit();
            for (common.list(common.get(payload, "replacement_history"))) |item| {
                try validateResponse(item, &replacement_pending, &errors);
            }
            if (replacement_pending.count() > 0) {
                try errors.append("Pending tool calls in compacted history");
            }
        }
    }
    if (pending.count() > 0) {
        try errors.append("Pending tool calls");
    }
    if (turn != null) {
        try errors.append("Unclosed turn");
    }
    return errors.toOwnedSlice();
}

fn validateResponse(payload: Value, pending: *std.StringHashMap(void), errors: *common.Warnings) !void {
    if (is(payload, "function_call")) {
        const id = common.stringField(payload, "call_id");
        if (id.len == 0) {
            try errors.append("Missing tool call ID");
        }
        if (pending.contains(id)) {
            try errors.append("Duplicate pending tool call");
        }
        try pending.put(id, {});
    } else if (is(payload, "function_call_output")) {
        if (!pending.remove(common.stringField(payload, "call_id"))) {
            try errors.append("Unpaired tool result");
        }
    } else if (is(payload, "message")) {
        const role = common.stringField(payload, "role");
        if (!common.eq(role, "user") and !common.eq(role, "assistant")) {
            try errors.append("Private instruction role in imported history");
        }
    }
}

fn sorted(allocator: Allocator, value: Value) !Value {
    if (value == .object) {
        var keys = std.array_list.Managed([]const u8).init(allocator);
        var it = value.object.iterator();
        while (it.next()) |entry| {
            try keys.append(entry.key_ptr.*);
        }
        std.mem.sort([]const u8, keys.items, {}, struct {
            fn less(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.order(u8, left, right) == .lt;
            }
        }.less);
        var out = try common.obj(allocator, &.{});
        for (keys.items) |key| {
            try common.set(allocator, &out, key, try sorted(allocator, value.object.get(key).?));
        }
        return out;
    }
    if (value == .array) {
        var out = std.array_list.Managed(Value).init(allocator);
        for (value.array.items) |v| {
            try out.append(try sorted(allocator, v));
        }
        return common.arr(allocator, out.items);
    }
    return value;
}

fn canonical(allocator: Allocator, row: Value, for_hash: bool) !Value {
    var value = try common.clone(allocator, row);
    if (value != .object) {
        return value;
    }
    _ = value.object.swapRemove("ordinal");
    if (is(value, "session_meta")) {
        var payload = common.get(value, "payload");
        try common.set(allocator, &payload, "history_mode", jsonString("legacy"));
        if (common.get(payload, "base_instructions") == .null) {
            try common.set(allocator, &payload, "base_instructions", .null);
        }
        if (for_hash) {
            try common.set(allocator, &payload, "originator", jsonString("c2c"));
        }
        try common.set(allocator, &value, "payload", payload);
    }
    return sorted(allocator, value);
}

pub fn fingerprint(allocator: Allocator, entries: []const Value) ![]const u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (entries) |row| {
        hash.update(try common.json(allocator, try canonical(allocator, row, true)));
        hash.update("\n");
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

pub fn registrationMatches(allocator: Allocator, staged: []const Value, target: []const Value) !bool {
    if (staged.len != target.len) {
        return false;
    }
    for (staged, target) |before, after| {
        const expected = try common.json(allocator, try canonical(allocator, before, false));
        const actual = try common.json(allocator, try canonical(allocator, after, false));
        if (!common.eq(expected, actual)) {
            return false;
        }
    }
    return true;
}

pub fn supportedProvider(provider: []const u8) bool {
    return common.eq(provider, "claude") or common.eq(provider, "opencode") or
        common.eq(provider, "omp") or common.eq(provider, "codex");
}

pub const Origin = struct {
    provider: ?[]const u8 = null,
    original_id: ?[]const u8 = null,
    unchanged: bool = false,
};
pub fn readOrigin(allocator: Allocator, thread: common.Thread) !Origin {
    var reader = common.LineReader.open(allocator, thread.rollout_path) catch return .{};
    defer reader.close();
    const first_line = (try reader.next()) orelse return .{};
    const first = common.parse(allocator, first_line) catch return .{};
    const originator = common.stringField(common.get(first, "payload"), "originator");
    const prefix = "c2c:";
    if (!std.mem.startsWith(u8, originator, prefix)) {
        return .{};
    }
    const suffix = originator[prefix.len..];
    const provider_end = std.mem.indexOfScalar(u8, suffix, ':') orelse return .{};
    const provider = suffix[0..provider_end];
    if (!supportedProvider(provider)) {
        return .{};
    }
    const marker = suffix[provider_end + 1 ..];
    const split = std.mem.indexOfScalar(u8, marker, ':') orelse return .{};
    const encoded = marker[0..split];
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const size = decoder.calcSizeForSlice(encoded) catch return .{};
    const original = try allocator.alloc(u8, size);
    decoder.decode(original, encoded) catch return .{};
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(try common.json(allocator, try canonical(allocator, first, true)));
    hash.update("\n");
    while (try reader.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r\n").len == 0) {
            continue;
        }
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const temp = arena.allocator();
        const value = common.parse(temp, line) catch return .{
            .provider = provider,
            .original_id = original,
            .unchanged = false,
        };
        hash.update(try common.json(temp, try canonical(temp, value, true)));
        hash.update("\n");
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return .{
        .provider = provider,
        .original_id = original,
        .unchanged = common.eq(&hex, marker[split + 1 ..]),
    };
}
