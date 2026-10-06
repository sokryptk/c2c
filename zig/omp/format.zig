const std = @import("std");
const common = @import("../common.zig");
const Allocator = common.Allocator;
const Value = common.Value;
const jsonString = common.str;
const Values = std.array_list.Managed(Value);

pub const provenance_type = "io.c2c.provenance";
pub const entry_namespace = "ea70b6a3-ab45-4405-94b5-1e7ed8742d9c";
pub const max_active_bytes = 240_000;

pub fn is(value: Value, kind: []const u8) bool {
    return common.eq(common.stringField(value, "type"), kind);
}

pub fn fallback(value: []const u8, other: []const u8) []const u8 {
    return if (value.len > 0) value else other;
}

pub fn blocks(allocator: Allocator, value: Value) ![]const Value {
    if (value != .string) {
        return common.list(value);
    }
    if (value.string.len == 0) {
        return &.{};
    }
    const text = try common.obj(allocator, &.{
        .{ "type", jsonString("text") },
        .{ "text", value },
    });
    const content = try common.arr(allocator, &.{text});
    return content.array.items;
}

pub fn stamp(allocator: Allocator, value: Value, default: []const u8) ![]const u8 {
    if (value == .integer) {
        return common.timestamp(allocator, value.integer);
    }
    const text = if (value == .string and value.string.len > 0) value.string else default;
    const millis = try common.timestampMillis(text);
    return common.timestamp(allocator, millis);
}

pub fn textOf(allocator: Allocator, input: []const Value) ![]const u8 {
    var texts = std.array_list.Managed([]const u8).init(allocator);
    for (input) |part| {
        if (is(part, "text")) {
            try texts.append(common.stringField(part, "text"));
        } else if (is(part, "image")) {
            try texts.append("[Image attachment remains in the full transcript]");
        }
    }
    return std.mem.join(allocator, "\n", texts.items);
}

fn sorted(allocator: Allocator, value: Value) Allocator.Error!Value {
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
        var result = try common.obj(allocator, &.{});
        for (keys.items) |key| {
            const child = try sorted(allocator, value.object.get(key).?);
            try common.set(allocator, &result, key, child);
        }
        return result;
    }
    if (value == .array) {
        var result = Values.init(allocator);
        for (value.array.items) |child| {
            const sorted_child = try sorted(allocator, child);
            try result.append(sorted_child);
        }
        return common.arr(allocator, result.items);
    }
    return value;
}

pub fn hashRow(allocator: Allocator, hash: *std.crypto.hash.sha2.Sha256, row: Value, source_path: ?[]const u8) !void {
    var value = try common.clone(allocator, row);
    if (is(value, "custom") and common.eq(common.stringField(value, "customType"), provenance_type)) {
        var data = common.get(value, "data");
        if (data == .object) {
            _ = data.object.swapRemove("fingerprint");
            try common.set(allocator, &value, "data", data);
        }
    }
    if (is(value, "message")) {
        var message = common.get(value, "message");
        const content = common.get(message, "content");
        if (content == .array) {
            for (content.array.items) |*part| {
                if (!is(part.*, "image")) {
                    continue;
                }
                const data = common.stringField(part.*, "data");
                var image_hash: ?[]const u8 = null;
                if (std.mem.startsWith(u8, data, "blob:sha256:")) {
                    const key = data[12..];
                    if (key.len != 64) {
                        return error.InvalidOmpImageBlob;
                    }
                    for (key) |ch| {
                        if (!std.ascii.isHex(ch) or std.ascii.isUpper(ch)) {
                            return error.InvalidOmpImageBlob;
                        }
                    }
                    const path = source_path orelse return error.OmpImageBlobUnavailable;
                    const marker = std.mem.lastIndexOf(u8, path, "/sessions/") orelse
                        return error.OmpImageBlobUnavailable;
                    const blob_path = try common.join(allocator, &.{ path[0..marker], "blobs", key });
                    const bytes = try common.readFile(allocator, blob_path);
                    const actual_hash = try common.sha256(allocator, bytes);
                    if (!common.eq(actual_hash, key)) {
                        return error.InvalidOmpImageBlob;
                    }
                    image_hash = key;
                } else if (data.len > 0) {
                    const decoder = std.base64.standard.Decoder;
                    const size = decoder.calcSizeForSlice(data) catch null;
                    if (size) |byte_count| {
                        const bytes = try allocator.alloc(u8, byte_count);
                        if (decoder.decode(bytes, data)) |_| {
                            image_hash = try common.sha256(allocator, bytes);
                        } else |_| {}
                    }
                }
                if (image_hash) |key| {
                    const blob_reference = try common.fmt(allocator, "blob:sha256:{s}", .{key});
                    try common.set(allocator, part, "data", jsonString(blob_reference));
                }
            }
            try common.set(allocator, &message, "content", content);
            try common.set(allocator, &value, "message", message);
        }
    }
    const canonical = try sorted(allocator, value);
    const encoded = try common.json(allocator, canonical);
    hash.update(encoded);
    hash.update("\n");
}

pub fn digest(allocator: Allocator, hash: *std.crypto.hash.sha2.Sha256) ![]const u8 {
    var bytes: [32]u8 = undefined;
    hash.final(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return allocator.dupe(u8, &hex);
}

pub fn fingerprint(allocator: Allocator, rows: []const Value) ![]const u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (rows) |row| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        try hashRow(arena.allocator(), &hash, row, null);
    }
    return digest(allocator, &hash);
}

pub fn activeRows(allocator: Allocator, rows: []const Value) ![]const Value {
    var compaction: ?usize = null;
    for (rows, 0..) |row, index| {
        if (is(row, "compaction")) {
            compaction = index;
        }
    }
    var result = Values.init(allocator);
    if (compaction) |index| {
        const kept = common.stringField(rows[index], "firstKeptEntryId");
        var first = index;
        if (kept.len > 0) {
            for (rows[0..index], 0..) |row, prior_index| {
                if (common.eq(common.stringField(row, "id"), kept)) {
                    first = prior_index;
                    break;
                }
            }
            if (first == index) {
                return error.InvalidOmpCompactionTail;
            }
        }
        for (rows[first..index]) |row| {
            if (is(row, "message")) {
                try result.append(row);
            }
        }
        for (rows[index + 1 ..]) |row| {
            if (is(row, "message")) {
                try result.append(row);
            }
        }
    } else {
        for (rows) |row| {
            if (is(row, "message")) {
                try result.append(row);
            }
        }
    }
    return result.toOwnedSlice();
}

pub fn activeBytes(allocator: Allocator, rows: []const Value) !usize {
    var summary: []const u8 = "";
    for (rows) |row| {
        if (is(row, "compaction")) {
            summary = common.stringField(row, "summary");
        }
    }
    const encoded_summary = try common.json(allocator, jsonString(summary));
    const active = try activeRows(allocator, rows);
    const messages = try common.arr(allocator, active);
    const encoded_messages = try common.json(allocator, messages);
    return encoded_summary.len + encoded_messages.len;
}

pub fn validate(allocator: Allocator, rows: []const Value) ![][]const u8 {
    var errors = common.Warnings.init(allocator);
    if (rows.len == 0 or !is(rows[0], "session")) {
        try errors.append("First OMP record must be a session header");
        return errors.toOwnedSlice();
    }
    const header = rows[0];
    if (common.integer(common.get(header, "version")) != 3 or common.stringField(header, "id").len == 0) {
        try errors.append("Invalid OMP session header");
    }
    var ids = std.StringHashMap(void).init(allocator);
    var pending = std.StringHashMap(void).init(allocator);
    for (rows[1..]) |row| {
        const id = common.stringField(row, "id");
        if (id.len == 0 or ids.contains(id)) {
            try errors.append("Missing or duplicate OMP entry ID");
        }
        const parent = common.stringField(row, "parentId");
        if (parent.len > 0 and !ids.contains(parent)) {
            try errors.append("OMP parent does not precede its child");
        }
        try ids.put(id, {});
        _ = common.timestampMillis(common.stringField(row, "timestamp")) catch {
            try errors.append("Invalid OMP entry timestamp");
            continue;
        };
        if (is(row, "compaction") and pending.count() > 0) {
            try errors.append("OMP compaction split an unfinished tool call");
        }
        if (!is(row, "message")) {
            continue;
        }
        const message = common.get(row, "message");
        const role = common.stringField(message, "role");
        if (common.eq(role, "assistant")) {
            for (common.list(common.get(message, "content"))) |part| {
                if (!is(part, "toolCall")) {
                    continue;
                }
                const call = common.stringField(part, "id");
                if (call.len == 0 or pending.contains(call)) {
                    try errors.append("Invalid or duplicate OMP tool call");
                }
                try pending.put(call, {});
            }
        } else if (common.eq(role, "toolResult")) {
            if (!pending.remove(common.stringField(message, "toolCallId"))) {
                try errors.append("Unpaired OMP tool result");
            }
        } else if (!common.eq(role, "user")) {
            try errors.append("Private instruction role in OMP conversation");
        }
    }
    if (pending.count() > 0) {
        try errors.append("Incomplete OMP tool calls");
    }
    pending.clearRetainingCapacity();
    const active = activeRows(allocator, rows) catch {
        try errors.append("OMP compaction references a missing retained entry");
        return errors.toOwnedSlice();
    };
    for (active) |row| {
        const message = common.get(row, "message");
        const role = common.stringField(message, "role");
        if (common.eq(role, "assistant")) {
            for (common.list(common.get(message, "content"))) |part| {
                if (is(part, "toolCall")) {
                    try pending.put(common.stringField(part, "id"), {});
                }
            }
        } else if (common.eq(role, "toolResult")) {
            if (!pending.remove(common.stringField(message, "toolCallId"))) {
                try errors.append("OMP active context contains an orphan tool result");
            }
        }
    }
    if (pending.count() > 0) {
        try errors.append("OMP active context contains an unfinished tool call");
    }
    return errors.toOwnedSlice();
}
