const std = @import("std");
const C = @import("../common.zig");
const A = C.Allocator;
const V = C.Value;
const S = C.str;
const Values = std.array_list.Managed(V);

pub const provenance_type = "io.c2c.provenance";
pub const entry_namespace = "ea70b6a3-ab45-4405-94b5-1e7ed8742d9c";
pub const max_active_bytes = 240_000;

pub fn is(v: V, kind: []const u8) bool {
    return C.eq(C.s(v, "type"), kind);
}
pub fn fallback(value: []const u8, other: []const u8) []const u8 {
    return if (value.len > 0) value else other;
}
pub fn blocks(a: A, value: V) ![]const V {
    if (value == .string) return if (value.string.len == 0) &.{} else (try C.arr(a, &.{try C.obj(a, &.{ .{ "type", S("text") }, .{ "text", value } })})).array.items;
    return C.list(value);
}
pub fn stamp(a: A, value: V, default: []const u8) ![]const u8 {
    if (value == .integer) return C.timestamp(a, value.integer);
    const text = if (value == .string and value.string.len > 0) value.string else default;
    return C.timestamp(a, try C.timestampMillis(text));
}
pub fn textOf(a: A, input: []const V) ![]const u8 {
    var texts = std.array_list.Managed([]const u8).init(a);
    for (input) |part| {
        if (is(part, "text")) try texts.append(C.s(part, "text")) else if (is(part, "image")) try texts.append("[Image attachment remains in the full transcript]");
    }
    return std.mem.join(a, "\n", texts.items);
}
fn sorted(a: A, value: V) A.Error!V {
    if (value == .object) {
        var keys = std.array_list.Managed([]const u8).init(a);
        var it = value.object.iterator();
        while (it.next()) |entry| try keys.append(entry.key_ptr.*);
        std.mem.sort([]const u8, keys.items, {}, struct {
            fn less(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.order(u8, left, right) == .lt;
            }
        }.less);
        var result = try C.obj(a, &.{});
        for (keys.items) |key| try C.set(a, &result, key, try sorted(a, value.object.get(key).?));
        return result;
    }
    if (value == .array) {
        var result = Values.init(a);
        for (value.array.items) |child| try result.append(try sorted(a, child));
        return C.arr(a, result.items);
    }
    return value;
}
pub fn hashRow(a: A, hash: *std.crypto.hash.sha2.Sha256, row: V, source_path: ?[]const u8) !void {
    var value = try C.clone(a, row);
    if (is(value, "custom") and C.eq(C.s(value, "customType"), provenance_type)) {
        var data = C.get(value, "data");
        if (data == .object) {
            _ = data.object.swapRemove("fingerprint");
            try C.set(a, &value, "data", data);
        }
    }
    if (is(value, "message")) {
        var message = C.get(value, "message");
        const content = C.get(message, "content");
        if (content == .array) {
            for (content.array.items) |*part| {
                if (!is(part.*, "image")) continue;
                const data = C.s(part.*, "data");
                var image_hash: ?[]const u8 = null;
                if (std.mem.startsWith(u8, data, "blob:sha256:")) {
                    const key = data[12..];
                    if (key.len != 64) return error.InvalidOmpImageBlob;
                    for (key) |ch| if (!std.ascii.isHex(ch) or std.ascii.isUpper(ch)) return error.InvalidOmpImageBlob;
                    const path = source_path orelse return error.OmpImageBlobUnavailable;
                    const marker = std.mem.lastIndexOf(u8, path, "/sessions/") orelse return error.OmpImageBlobUnavailable;
                    const bytes = try C.readFile(a, try C.join(a, &.{ path[0..marker], "blobs", key }));
                    if (!C.eq(try C.sha256(a, bytes), key)) return error.InvalidOmpImageBlob;
                    image_hash = key;
                } else if (data.len > 0) {
                    const decoder = std.base64.standard.Decoder;
                    const size = decoder.calcSizeForSlice(data) catch null;
                    if (size) |n| {
                        const bytes = try a.alloc(u8, n);
                        if (decoder.decode(bytes, data)) |_| image_hash = try C.sha256(a, bytes) else |_| {}
                    }
                }
                if (image_hash) |key| try C.set(a, part, "data", S(try C.fmt(a, "blob:sha256:{s}", .{key})));
            }
            try C.set(a, &message, "content", content);
            try C.set(a, &value, "message", message);
        }
    }
    hash.update(try C.json(a, try sorted(a, value)));
    hash.update("\n");
}
pub fn digest(a: A, hash: *std.crypto.hash.sha2.Sha256) ![]const u8 {
    var bytes: [32]u8 = undefined;
    hash.final(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return a.dupe(u8, &hex);
}
pub fn fingerprint(a: A, rows: []const V) ![]const u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (rows) |row| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        try hashRow(arena.allocator(), &hash, row, null);
    }
    return digest(a, &hash);
}
pub fn activeRows(a: A, rows: []const V) ![]const V {
    var compaction: ?usize = null;
    for (rows, 0..) |row, i| if (is(row, "compaction")) {
        compaction = i;
    };
    var result = Values.init(a);
    if (compaction) |index| {
        const kept = C.s(rows[index], "firstKeptEntryId");
        var first = index;
        if (kept.len > 0) {
            for (rows[0..index], 0..) |row, i| if (C.eq(C.s(row, "id"), kept)) {
                first = i;
                break;
            };
            if (first == index) return error.InvalidOmpCompactionTail;
        }
        for (rows[first..index]) |row| if (is(row, "message")) try result.append(row);
        for (rows[index + 1 ..]) |row| if (is(row, "message")) try result.append(row);
    } else for (rows) |row| if (is(row, "message")) try result.append(row);
    return result.toOwnedSlice();
}
pub fn activeBytes(a: A, rows: []const V) !usize {
    var summary: []const u8 = "";
    for (rows) |row| if (is(row, "compaction")) {
        summary = C.s(row, "summary");
    };
    return (try C.json(a, S(summary))).len + (try C.json(a, try C.arr(a, try activeRows(a, rows)))).len;
}
pub fn validate(a: A, rows: []const V) ![][]const u8 {
    var errors = C.Warnings.init(a);
    if (rows.len == 0 or !is(rows[0], "session")) {
        try errors.append("First OMP record must be a session header");
        return errors.toOwnedSlice();
    }
    if (C.integer(C.get(rows[0], "version")) != 3 or C.s(rows[0], "id").len == 0) try errors.append("Invalid OMP session header");
    var ids = std.StringHashMap(void).init(a);
    var pending = std.StringHashMap(void).init(a);
    for (rows[1..]) |row| {
        const id = C.s(row, "id");
        if (id.len == 0 or ids.contains(id)) try errors.append("Missing or duplicate OMP entry ID");
        const parent = C.s(row, "parentId");
        if (parent.len > 0 and !ids.contains(parent)) try errors.append("OMP parent does not precede its child");
        try ids.put(id, {});
        _ = C.timestampMillis(C.s(row, "timestamp")) catch {
            try errors.append("Invalid OMP entry timestamp");
            continue;
        };
        if (is(row, "compaction") and pending.count() > 0) try errors.append("OMP compaction split an unfinished tool call");
        if (!is(row, "message")) continue;
        const msg = C.get(row, "message");
        const role = C.s(msg, "role");
        if (C.eq(role, "assistant")) {
            for (C.list(C.get(msg, "content"))) |part| if (is(part, "toolCall")) {
                const call = C.s(part, "id");
                if (call.len == 0 or pending.contains(call)) try errors.append("Invalid or duplicate OMP tool call");
                try pending.put(call, {});
            };
        } else if (C.eq(role, "toolResult")) {
            if (!pending.remove(C.s(msg, "toolCallId"))) try errors.append("Unpaired OMP tool result");
        } else if (!C.eq(role, "user")) try errors.append("Private instruction role in OMP conversation");
    }
    if (pending.count() > 0) try errors.append("Incomplete OMP tool calls");
    pending.clearRetainingCapacity();
    const active = activeRows(a, rows) catch {
        try errors.append("OMP compaction references a missing retained entry");
        return errors.toOwnedSlice();
    };
    for (active) |row| {
        const message = C.get(row, "message");
        const role = C.s(message, "role");
        if (C.eq(role, "assistant")) {
            for (C.list(C.get(message, "content"))) |part| if (is(part, "toolCall")) try pending.put(C.s(part, "id"), {});
        } else if (C.eq(role, "toolResult")) {
            if (!pending.remove(C.s(message, "toolCallId"))) try errors.append("OMP active context contains an orphan tool result");
        }
    }
    if (pending.count() > 0) try errors.append("OMP active context contains an unfinished tool call");
    return errors.toOwnedSlice();
}
