const std = @import("std");
const C = @import("../common.zig");
const A = C.Allocator;
const V = C.Value;
const S = C.str;
const Values = std.array_list.Managed(V);
const F = @import("format.zig");

fn shortText(a: A, text: []const u8, limit: usize) ![]const u8 {
    if (text.len <= limit) return a.dupe(u8, text);
    var end = limit;
    while (end > 0 and (text[end] & 0xc0) == 0x80) : (end -= 1) {}
    return a.dupe(u8, text[0..end]);
}

pub const Origin = struct { provider: ?[]const u8 = null, id: ?[]const u8 = null, original_id: ?[]const u8 = null, unchanged: bool = false };
pub fn readOrigin(a: A, thread: C.Thread) !Origin {
    var reader = C.LineReader.open(a, thread.rollout_path) catch return .{};
    defer reader.close();
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var origin = Origin{};
    var expected: []const u8 = "";
    var count: usize = 0;
    var physical_line: usize = 0;
    while (reader.next() catch return origin) |line| {
        const first_line = physical_line == 0;
        physical_line += 1;
        if (std.mem.trim(u8, line, " \t\r\n").len == 0) continue;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const row = C.parse(arena.allocator(), line) catch return origin;
        if (row != .object) return origin;
        if (!reader.last_terminated) return origin;
        if (first_line and F.is(row, "title")) {
            const source = row.object.get("source");
            const valid_source = if (source) |v| C.eq(C.text(v), "auto") or C.eq(C.text(v), "user") else true;
            if (C.integer(C.get(row, "v")) != 1 or C.get(row, "title") != .string or C.get(row, "updatedAt") != .string or C.get(row, "pad") != .string or !valid_source) return origin;
            continue;
        }
        if (F.is(row, "custom") and C.eq(C.s(row, "customType"), F.provenance_type)) {
            if (origin.id != null) return origin;
            const data = C.get(row, "data");
            if (C.s(data, "sourceProvider").len == 0 or C.s(data, "sourceSessionId").len == 0) return origin;
            origin.provider = try a.dupe(u8, C.s(data, "sourceProvider"));
            origin.id = try a.dupe(u8, C.s(data, "sourceSessionId"));
            origin.original_id = origin.id;
            expected = try a.dupe(u8, C.s(data, "fingerprint"));
        }
        F.hashRow(arena.allocator(), &hash, row, thread.rollout_path) catch return origin;
        count += 1;
        // Provenance follows the header; native sessions need no full read.
        if (count >= 3 and origin.id == null) return .{};
    }
    if (origin.id != null) origin.unchanged = C.eq(expected, try F.digest(a, &hash));
    return origin;
}

pub fn listThreads(a: A, home: []const u8) ![]C.Thread {
    const root = try C.canonicalPath(a, home);
    const sessions = try C.join(a, &.{ root, "sessions" });
    if (!C.exists(sessions)) return a.alloc(C.Thread, 0);
    var result = std.array_list.Managed(C.Thread).init(a);
    for (try C.walkFiles(a, sessions, ".jsonl")) |path| {
        var reader = C.LineReader.open(a, path) catch continue;
        defer reader.close();
        var header: V = .null;
        var title: []const u8 = "";
        var created: []const u8 = "";
        var updated: []const u8 = "";
        var user_preview: []const u8 = "";
        var saw_message = false;
        var position: usize = 0;
        while (try reader.next()) |line| {
            if (std.mem.trim(u8, line, " \t\r\n").len == 0) continue;
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const row = C.parse(arena.allocator(), line) catch {
                if (!reader.last_terminated) break;
                return error.MalformedOmpSession;
            };
            if (F.is(row, "title") and position == 0) {
                title = try a.dupe(u8, C.s(row, "title"));
                position += 1;
                continue;
            }
            if (header == .null) {
                if (!F.is(row, "session")) break;
                header = try C.clone(a, row);
                if (title.len == 0) title = C.s(header, "title");
                created = F.stamp(a, C.get(header, "timestamp"), "1970-01-01T00:00:00.000Z") catch break;
                updated = created;
            } else {
                if (C.get(row, "timestamp") != .null) updated = F.stamp(a, C.get(row, "timestamp"), updated) catch updated;
                if (F.is(row, "title_change") and C.s(row, "title").len > 0) title = try a.dupe(u8, C.s(row, "title"));
                const message = C.get(row, "message");
                const role = C.s(message, "role");
                if (F.is(row, "message") and (C.eq(role, "user") or C.eq(role, "assistant") or C.eq(role, "toolResult") or C.eq(role, "bashExecution") or C.eq(role, "pythonExecution") or C.eq(role, "fileMention") or C.eq(role, "custom") or C.eq(role, "hookMessage"))) saw_message = true;
                if ((F.is(row, "compaction") or F.is(row, "branch_summary")) and C.s(row, "summary").len > 0) saw_message = true;
                if (F.is(row, "custom_message")) saw_message = true;
                if (user_preview.len == 0 and C.eq(role, "user")) user_preview = try shortText(a, try F.textOf(arena.allocator(), try F.blocks(arena.allocator(), C.get(message, "content"))), 120);
            }
            position += 1;
        }
        if (header == .null or C.s(header, "id").len == 0 or !saw_message) continue;
        var thread = C.Thread{ .id = C.s(header, "id"), .title = F.fallback(title, F.fallback(user_preview, "Untitled OMP conversation")), .cwd = C.s(header, "cwd"), .created_at = created, .updated_at = updated, .rollout_path = path, .provider = "omp", .parent_id = if (C.s(header, "parentSession").len > 0) C.s(header, "parentSession") else null };
        const origin = try readOrigin(a, thread);
        thread.origin_provider = origin.provider;
        thread.origin_id = origin.id;
        thread.unchanged_import = origin.unchanged;
        try result.append(thread);
    }
    std.mem.sort(C.Thread, result.items, {}, struct {
        fn less(_: void, left: C.Thread, right: C.Thread) bool {
            return std.mem.order(u8, left.updated_at, right.updated_at) == .gt;
        }
    }.less);
    return result.toOwnedSlice();
}

fn imageFromOmp(a: A, block: V, path: []const u8, warnings: *C.Warnings) !V {
    var data = C.s(block, "data");
    const mime = F.fallback(C.s(block, "mimeType"), "image/png");
    if (std.mem.startsWith(u8, data, "blob:sha256:")) {
        const key = data[12..];
        var valid = key.len == 64;
        for (key) |ch| if (!std.ascii.isHex(ch) or std.ascii.isUpper(ch)) {
            valid = false;
        };
        const marker = std.mem.lastIndexOf(u8, path, "/sessions/");
        if (valid and marker != null) {
            const bytes = C.readFile(a, try C.join(a, &.{ path[0..marker.?], "blobs", key })) catch null;
            if (bytes) |value| {
                if (C.eq(try C.sha256(a, value), key)) {
                    const encoder = std.base64.standard.Encoder;
                    const encoded = try a.alloc(u8, encoder.calcSize(value.len));
                    _ = encoder.encode(encoded, value);
                    data = encoded;
                }
            }
        }
        if (std.mem.startsWith(u8, data, "blob:sha256:")) {
            try warnings.append("OMP image blob missing or invalid; reference preserved as text");
            return C.obj(a, &.{ .{ "type", S("text") }, .{ "text", S(try C.fmt(a, "[OMP image attachment: {s}; {s}]", .{ data, mime })) } });
        }
    }
    if (data.len > 0) return C.obj(a, &.{ .{ "type", S("image") }, .{ "source", try C.obj(a, &.{ .{ "type", S("base64") }, .{ "media_type", S(mime) }, .{ "data", S(data) } }) } });
    const url = C.s(block, "url");
    if (url.len > 0) return C.obj(a, &.{ .{ "type", S("image") }, .{ "source", try C.obj(a, &.{ .{ "type", S("url") }, .{ "url", S(url) } }) } });
    try warnings.append("OMP image has no readable data; metadata preserved as text");
    return C.obj(a, &.{ .{ "type", S("text") }, .{ "text", S(try C.fmt(a, "[OMP image attachment]\n{s}", .{try C.json(a, block)})) } });
}
fn fromContent(a: A, input: V, path: []const u8, warnings: *C.Warnings) ![]const V {
    var result = Values.init(a);
    for (try F.blocks(a, input)) |block| {
        if (F.is(block, "thinking") or F.is(block, "redactedThinking") or F.is(block, "redacted_thinking")) continue;
        if (F.is(block, "text")) {
            try result.append(try C.obj(a, &.{ .{ "type", S("text") }, .{ "text", S(C.s(block, "text")) } }));
        } else if (F.is(block, "image")) {
            try result.append(try imageFromOmp(a, block, path, warnings));
        } else if (F.is(block, "toolCall")) {
            try result.append(try C.obj(a, &.{ .{ "type", S("tool_use") }, .{ "id", S(C.s(block, "id")) }, .{ "name", S(C.s(block, "name")) }, .{ "input", try C.clone(a, C.get(block, "arguments")) } }));
        } else {
            try result.append(try C.obj(a, &.{ .{ "type", S("text") }, .{ "text", S(try C.fmt(a, "[OMP content: {s}]\n{s}", .{ C.s(block, "type"), try C.json(a, block) })) } }));
            try warnings.append("Unrecognized OMP visible content preserved as a text artifact");
        }
    }
    return result.toOwnedSlice();
}
fn envelope(a: A, role: []const u8, content: []const V, id: []const u8, ts: []const u8) !V {
    return C.obj(a, &.{ .{ "type", S(role) }, .{ "uuid", S(id) }, .{ "timestamp", S(ts) }, .{ "message", try C.obj(a, &.{ .{ "role", S(role) }, .{ "content", try C.arr(a, content) } }) } });
}
fn appendNativeEntry(a: A, output: *Values, row: V, thread: C.Thread, warnings: *C.Warnings) !void {
    const ts = try F.stamp(a, C.get(row, "timestamp"), thread.updated_at);
    const id = C.s(row, "id");
    const message = C.get(row, "message");
    const role = C.s(message, "role");
    if (F.is(row, "message") and (C.eq(role, "user") or C.eq(role, "assistant"))) {
        const content = try fromContent(a, C.get(message, "content"), thread.rollout_path, warnings);
        if (content.len > 0) try output.append(try envelope(a, role, content, id, ts));
    } else if (F.is(row, "message") and C.eq(role, "toolResult")) {
        const content = try fromContent(a, C.get(message, "content"), thread.rollout_path, warnings);
        try output.append(try envelope(a, "user", &.{try C.obj(a, &.{ .{ "type", S("tool_result") }, .{ "tool_use_id", S(C.s(message, "toolCallId")) }, .{ "content", try C.arr(a, content) }, .{ "is_error", C.boolean(C.b(C.get(message, "isError"))) } })}, id, ts));
    } else if (F.is(row, "message") and (C.eq(role, "bashExecution") or C.eq(role, "pythonExecution"))) {
        const name = if (C.eq(role, "bashExecution")) "Bash" else "Python";
        const command = F.fallback(C.s(message, "command"), C.s(message, "code"));
        const call_id = try C.fmt(a, "omp-command-{s}", .{id});
        const args = try C.obj(a, &.{.{ if (C.eq(role, "bashExecution")) "command" else "code", S(command) }});
        try output.append(try envelope(a, "assistant", &.{try C.obj(a, &.{ .{ "type", S("tool_use") }, .{ "id", S(call_id) }, .{ "name", S(name) }, .{ "input", args } })}, id, ts));
        const text = F.fallback(C.s(message, "output"), C.s(message, "text"));
        try output.append(try envelope(a, "user", &.{try C.obj(a, &.{ .{ "type", S("tool_result") }, .{ "tool_use_id", S(call_id) }, .{ "content", S(text) }, .{ "is_error", C.boolean(C.b(C.get(message, "cancelled")) or C.integer(C.get(message, "exitCode")) != 0) } })}, try C.fmt(a, "{s}-result", .{id}), ts));
    } else if ((F.is(row, "custom_message") or (F.is(row, "message") and (C.eq(role, "custom") or C.eq(role, "hookMessage")))) and !C.eq(C.s(row, "customType"), F.provenance_type)) {
        const content = try fromContent(a, C.get(if (F.is(row, "message")) message else row, "content"), thread.rollout_path, warnings);
        if (content.len > 0) try output.append(try envelope(a, "user", content, id, ts));
    } else if (F.is(row, "branch_summary") and C.s(row, "summary").len > 0) {
        try output.append(try envelope(a, "user", try F.blocks(a, S(try C.fmt(a, "[OMP branch summary]\n{s}", .{C.s(row, "summary")}))), id, ts));
    } else if (F.is(row, "message") and C.eq(role, "fileMention")) {
        try output.append(try envelope(a, "user", try F.blocks(a, S(try C.fmt(a, "[OMP file attachment]\n{s}", .{try C.json(a, message)}))), id, ts));
    }
    // Exclude developer/session_init/custom runtime state and private reasoning.
}
pub fn readEntries(a: A, thread: C.Thread, warnings: *C.Warnings) ![]V {
    const raw = try C.readJsonl(a, thread.rollout_path, warnings);
    var rows = Values.init(a);
    var by_id = std.StringHashMap(usize).init(a);
    var previous: V = .null;
    var header_found = false;
    var legacy = false;
    for (raw, 0..) |original, index| {
        if (F.is(original, "title")) continue;
        if (!header_found) {
            if (!F.is(original, "session")) return error.InvalidOmpHeader;
            header_found = true;
            legacy = C.integer(C.get(original, "version")) < 2;
            continue;
        }
        var row = try C.clone(a, original);
        if (C.s(row, "id").len == 0) {
            if (!legacy) return error.OmpEntryIdMissing;
            try C.set(a, &row, "id", S(try C.uuid5(a, F.entry_namespace, try C.fmt(a, "{s}:{d}", .{ thread.id, index }))));
            try C.set(a, &row, "parentId", previous);
        }
        if (legacy and F.is(row, "compaction") and C.get(row, "firstKeptEntryIndex") == .integer) {
            const kept = C.integer(C.get(row, "firstKeptEntryIndex"));
            if (kept > 0 and kept <= rows.items.len) try C.set(a, &row, "firstKeptEntryId", S(C.s(rows.items[@intCast(kept - 1)], "id")));
        }
        const id = C.s(row, "id");
        if (by_id.contains(id)) return error.DuplicateOmpEntryId;
        try by_id.put(id, rows.items.len);
        try rows.append(row);
        previous = S(id);
    }
    if (!header_found) return error.InvalidOmpHeader;
    var reverse = Values.init(a);
    var seen = std.StringHashMap(void).init(a);
    var current: ?usize = if (rows.items.len > 0) rows.items.len - 1 else null;
    while (current) |index| {
        const row = rows.items[index];
        const id = C.s(row, "id");
        if (seen.contains(id)) return error.CyclicOmpParentChain;
        try seen.put(id, {});
        try reverse.append(row);
        const parent = C.s(row, "parentId");
        current = if (parent.len == 0) null else by_id.get(parent);
        if (parent.len > 0 and current == null) try warnings.append("OMP branch references an unavailable parent; retained readable branch");
    }
    const path = try reverse.toOwnedSlice();
    std.mem.reverse(V, path);
    var cut: ?usize = null;
    var compact: ?usize = null;
    for (path, 0..) |row, index| {
        if (F.is(row, "reset_boundary")) {
            cut = index;
            compact = null;
        }
        if (F.is(row, "compaction")) {
            compact = index;
            cut = index;
            const keep = C.s(row, "firstKeptEntryId");
            for (path[0..index], 0..) |prior, j| if (C.eq(C.s(prior, "id"), keep)) {
                cut = j;
                break;
            };
            if (cut.? == index and keep.len == 0) {
                const replayed = C.s(row, "providerReplayThroughEntryId");
                if (replayed.len > 0) for (path[0..index], 0..) |prior, j| if (C.eq(C.s(prior, "id"), replayed)) {
                    cut = j + 1;
                    break;
                };
            }
        }
    }
    var output = Values.init(a);
    for (path, 0..) |row, index| {
        if (cut != null and index == cut.?) {
            const boundary = if (compact) |j| path[j] else row;
            const ts = try F.stamp(a, C.get(boundary, "timestamp"), thread.updated_at);
            try output.append(try C.obj(a, &.{ .{ "type", S("system") }, .{ "subtype", S("compact_boundary") }, .{ "timestamp", S(ts) } }));
            const summary = if (compact) |j| F.fallback(C.s(path[j], "summary"), "OMP compacted this history without a readable summary. Earlier content remains in the original transcript.") else "OMP cleared the previous active context. Earlier content remains in the original transcript.";
            var entry = try envelope(a, "user", try F.blocks(a, S(summary)), try C.fmt(a, "omp-summary-{s}", .{C.s(boundary, "id")}), ts);
            try C.set(a, &entry, "isCompactSummary", C.boolean(true));
            try output.append(entry);
            if (compact != null and C.get(path[compact.?], "preserveData") != .null) try warnings.append("OMP provider-private compaction state excluded; readable summary and retained messages preserved");
        }
        if (F.is(row, "compaction") or F.is(row, "reset_boundary")) continue;
        try appendNativeEntry(a, &output, row, thread, warnings);
    }
    return output.toOwnedSlice();
}
