//! Oh My Pi v3 session adapter. Historical tools are data, never executed.
//! Format: github.com/can1357/oh-my-pi/blob/main/docs/session.md
const std = @import("std");
const C = @import("common.zig");
const A = C.Allocator;
const V = C.Value;
const S = C.str;
const N = C.num;
const Values = std.array_list.Managed(V);
const provenance_type = "io.c2c.provenance";
const entry_namespace = "ea70b6a3-ab45-4405-94b5-1e7ed8742d9c";
const max_active_bytes = 240_000;
const recent_bytes = 170_000;

fn is(v: V, kind: []const u8) bool {
    return C.eq(C.s(v, "type"), kind);
}
fn fallback(value: []const u8, other: []const u8) []const u8 {
    return if (value.len > 0) value else other;
}
fn blocks(a: A, value: V) ![]const V {
    if (value == .string) return if (value.string.len == 0) &.{} else (try C.arr(a, &.{try C.obj(a, &.{ .{ "type", S("text") }, .{ "text", value } })})).array.items;
    return C.list(value);
}
fn stamp(a: A, value: V, default: []const u8) ![]const u8 {
    if (value == .integer) return C.timestamp(a, value.integer);
    const text = if (value == .string and value.string.len > 0) value.string else default;
    return C.timestamp(a, try C.timestampMillis(text));
}
fn shortText(a: A, text: []const u8, limit: usize) ![]const u8 {
    if (text.len <= limit) return a.dupe(u8, text);
    var end = limit;
    while (end > 0 and (text[end] & 0xc0) == 0x80) : (end -= 1) {}
    return a.dupe(u8, text[0..end]);
}
fn jsonExcerpt(a: A, text: []const u8, budget: usize) ![]const u8 {
    if ((try C.json(a, S(text))).len <= budget) return a.dupe(u8, text);
    var low: usize = 0;
    var high = text.len;
    while (low < high) {
        const mid = low + (high - low + 1) / 2;
        var end = mid;
        while (end > 0 and end < text.len and (text[end] & 0xc0) == 0x80) : (end -= 1) {}
        if ((try C.json(a, S(text[0..end]))).len <= budget) low = mid else high = mid - 1;
    }
    while (low > 0 and low < text.len and (text[low] & 0xc0) == 0x80) : (low -= 1) {}
    return a.dupe(u8, text[0..low]);
}
fn textOf(a: A, input: []const V) ![]const u8 {
    var texts = std.array_list.Managed([]const u8).init(a);
    for (input) |part| {
        if (is(part, "text")) try texts.append(C.s(part, "text")) else if (is(part, "image")) try texts.append("[Image attachment remains in the full transcript]");
    }
    return std.mem.join(a, "\n", texts.items);
}

fn inside(path: []const u8, root: []const u8) ?[]const u8 {
    if (C.eq(path, root)) return "";
    if (std.mem.startsWith(u8, path, root) and path.len > root.len and path[root.len] == '/') return path[root.len + 1 ..];
    return null;
}
fn bucket(a: A, cwd: []const u8) ![]const u8 {
    const canonical = try C.canonicalPath(a, cwd);
    const temp = if (C.c.getenv("TMPDIR")) |v| std.mem.span(v) else "/tmp";
    const temp_root = try C.canonicalPath(a, temp);
    var prefix: []const u8 = "--";
    var relative = std.mem.trimStart(u8, canonical, "/");
    var suffix: []const u8 = "--";
    if (inside(canonical, temp_root)) |value| {
        prefix = if (value.len == 0) "-tmp" else "-tmp-";
        relative = value;
        suffix = "";
    } else if (C.c.getenv("HOME")) |value| {
        if (inside(canonical, try C.canonicalPath(a, std.mem.span(value)))) |part| {
            prefix = "-";
            relative = part;
            suffix = "";
        }
    }
    const encoded = try a.dupe(u8, relative);
    for (encoded) |*ch| if (ch.* == '/' or ch.* == '\\' or ch.* == ':') {
        ch.* = '-';
    };
    return C.fmt(a, "{s}{s}{s}", .{ prefix, encoded, suffix });
}
pub fn targetPath(a: A, thread: C.Thread, home: []const u8) ![]const u8 {
    const ts = try stamp(a, S(thread.created_at), thread.updated_at);
    const filename_ts = try a.dupe(u8, ts);
    for (filename_ts) |*ch| if (ch.* == ':') {
        ch.* = '-';
    };
    const id = try C.sessionIdFor(a, "omp", thread.provider, thread.id);
    return C.join(a, &.{ home, "sessions", try bucket(a, thread.cwd), try C.fmt(a, "{s}_{s}.jsonl", .{ filename_ts, id }) });
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
fn hashRow(a: A, hash: *std.crypto.hash.sha2.Sha256, row: V, source_path: ?[]const u8) !void {
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
fn digest(a: A, hash: *std.crypto.hash.sha2.Sha256) ![]const u8 {
    var bytes: [32]u8 = undefined;
    hash.final(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return a.dupe(u8, &hex);
}
fn fingerprint(a: A, rows: []const V) ![]const u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (rows) |row| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        try hashRow(arena.allocator(), &hash, row, null);
    }
    return digest(a, &hash);
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
        if (first_line and is(row, "title")) {
            const source = row.object.get("source");
            const valid_source = if (source) |v| C.eq(C.text(v), "auto") or C.eq(C.text(v), "user") else true;
            if (C.integer(C.get(row, "v")) != 1 or C.get(row, "title") != .string or C.get(row, "updatedAt") != .string or C.get(row, "pad") != .string or !valid_source) return origin;
            continue;
        }
        if (is(row, "custom") and C.eq(C.s(row, "customType"), provenance_type)) {
            if (origin.id != null) return origin;
            const data = C.get(row, "data");
            if (C.s(data, "sourceProvider").len == 0 or C.s(data, "sourceSessionId").len == 0) return origin;
            origin.provider = try a.dupe(u8, C.s(data, "sourceProvider"));
            origin.id = try a.dupe(u8, C.s(data, "sourceSessionId"));
            origin.original_id = origin.id;
            expected = try a.dupe(u8, C.s(data, "fingerprint"));
        }
        hashRow(arena.allocator(), &hash, row, thread.rollout_path) catch return origin;
        count += 1;
        // Provenance follows the header; native sessions need no full read.
        if (count >= 3 and origin.id == null) return .{};
    }
    if (origin.id != null) origin.unchanged = C.eq(expected, try digest(a, &hash));
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
            if (is(row, "title") and position == 0) {
                title = try a.dupe(u8, C.s(row, "title"));
                position += 1;
                continue;
            }
            if (header == .null) {
                if (!is(row, "session")) break;
                header = try C.clone(a, row);
                if (title.len == 0) title = C.s(header, "title");
                created = stamp(a, C.get(header, "timestamp"), "1970-01-01T00:00:00.000Z") catch break;
                updated = created;
            } else {
                if (C.get(row, "timestamp") != .null) updated = stamp(a, C.get(row, "timestamp"), updated) catch updated;
                if (is(row, "title_change") and C.s(row, "title").len > 0) title = try a.dupe(u8, C.s(row, "title"));
                const message = C.get(row, "message");
                const role = C.s(message, "role");
                if (is(row, "message") and (C.eq(role, "user") or C.eq(role, "assistant") or C.eq(role, "toolResult") or C.eq(role, "bashExecution") or C.eq(role, "pythonExecution") or C.eq(role, "fileMention") or C.eq(role, "custom") or C.eq(role, "hookMessage"))) saw_message = true;
                if ((is(row, "compaction") or is(row, "branch_summary")) and C.s(row, "summary").len > 0) saw_message = true;
                if (is(row, "custom_message")) saw_message = true;
                if (user_preview.len == 0 and C.eq(role, "user")) user_preview = try shortText(a, try textOf(arena.allocator(), try blocks(arena.allocator(), C.get(message, "content"))), 120);
            }
            position += 1;
        }
        if (header == .null or C.s(header, "id").len == 0 or !saw_message) continue;
        var thread = C.Thread{ .id = C.s(header, "id"), .title = fallback(title, fallback(user_preview, "Untitled OMP conversation")), .cwd = C.s(header, "cwd"), .created_at = created, .updated_at = updated, .rollout_path = path, .provider = "omp", .parent_id = if (C.s(header, "parentSession").len > 0) C.s(header, "parentSession") else null };
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
    const mime = fallback(C.s(block, "mimeType"), "image/png");
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
    for (try blocks(a, input)) |block| {
        if (is(block, "thinking") or is(block, "redactedThinking") or is(block, "redacted_thinking")) continue;
        if (is(block, "text")) {
            try result.append(try C.obj(a, &.{ .{ "type", S("text") }, .{ "text", S(C.s(block, "text")) } }));
        } else if (is(block, "image")) {
            try result.append(try imageFromOmp(a, block, path, warnings));
        } else if (is(block, "toolCall")) {
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
    const ts = try stamp(a, C.get(row, "timestamp"), thread.updated_at);
    const id = C.s(row, "id");
    const message = C.get(row, "message");
    const role = C.s(message, "role");
    if (is(row, "message") and (C.eq(role, "user") or C.eq(role, "assistant"))) {
        const content = try fromContent(a, C.get(message, "content"), thread.rollout_path, warnings);
        if (content.len > 0) try output.append(try envelope(a, role, content, id, ts));
    } else if (is(row, "message") and C.eq(role, "toolResult")) {
        const content = try fromContent(a, C.get(message, "content"), thread.rollout_path, warnings);
        try output.append(try envelope(a, "user", &.{try C.obj(a, &.{ .{ "type", S("tool_result") }, .{ "tool_use_id", S(C.s(message, "toolCallId")) }, .{ "content", try C.arr(a, content) }, .{ "is_error", C.boolean(C.b(C.get(message, "isError"))) } })}, id, ts));
    } else if (is(row, "message") and (C.eq(role, "bashExecution") or C.eq(role, "pythonExecution"))) {
        const name = if (C.eq(role, "bashExecution")) "Bash" else "Python";
        const command = fallback(C.s(message, "command"), C.s(message, "code"));
        const call_id = try C.fmt(a, "omp-command-{s}", .{id});
        const args = try C.obj(a, &.{.{ if (C.eq(role, "bashExecution")) "command" else "code", S(command) }});
        try output.append(try envelope(a, "assistant", &.{try C.obj(a, &.{ .{ "type", S("tool_use") }, .{ "id", S(call_id) }, .{ "name", S(name) }, .{ "input", args } })}, id, ts));
        const text = fallback(C.s(message, "output"), C.s(message, "text"));
        try output.append(try envelope(a, "user", &.{try C.obj(a, &.{ .{ "type", S("tool_result") }, .{ "tool_use_id", S(call_id) }, .{ "content", S(text) }, .{ "is_error", C.boolean(C.b(C.get(message, "cancelled")) or C.integer(C.get(message, "exitCode")) != 0) } })}, try C.fmt(a, "{s}-result", .{id}), ts));
    } else if ((is(row, "custom_message") or (is(row, "message") and (C.eq(role, "custom") or C.eq(role, "hookMessage")))) and !C.eq(C.s(row, "customType"), provenance_type)) {
        const content = try fromContent(a, C.get(if (is(row, "message")) message else row, "content"), thread.rollout_path, warnings);
        if (content.len > 0) try output.append(try envelope(a, "user", content, id, ts));
    } else if (is(row, "branch_summary") and C.s(row, "summary").len > 0) {
        try output.append(try envelope(a, "user", try blocks(a, S(try C.fmt(a, "[OMP branch summary]\n{s}", .{C.s(row, "summary")}))), id, ts));
    } else if (is(row, "message") and C.eq(role, "fileMention")) {
        try output.append(try envelope(a, "user", try blocks(a, S(try C.fmt(a, "[OMP file attachment]\n{s}", .{try C.json(a, message)}))), id, ts));
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
        if (is(original, "title")) continue;
        if (!header_found) {
            if (!is(original, "session")) return error.InvalidOmpHeader;
            header_found = true;
            legacy = C.integer(C.get(original, "version")) < 2;
            continue;
        }
        var row = try C.clone(a, original);
        if (C.s(row, "id").len == 0) {
            if (!legacy) return error.OmpEntryIdMissing;
            try C.set(a, &row, "id", S(try C.uuid5(a, entry_namespace, try C.fmt(a, "{s}:{d}", .{ thread.id, index }))));
            try C.set(a, &row, "parentId", previous);
        }
        if (legacy and is(row, "compaction") and C.get(row, "firstKeptEntryIndex") == .integer) {
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
        if (is(row, "reset_boundary")) {
            cut = index;
            compact = null;
        }
        if (is(row, "compaction")) {
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
            const ts = try stamp(a, C.get(boundary, "timestamp"), thread.updated_at);
            try output.append(try C.obj(a, &.{ .{ "type", S("system") }, .{ "subtype", S("compact_boundary") }, .{ "timestamp", S(ts) } }));
            const summary = if (compact) |j| fallback(C.s(path[j], "summary"), "OMP compacted this history without a readable summary. Earlier content remains in the original transcript.") else "OMP cleared the previous active context. Earlier content remains in the original transcript.";
            var entry = try envelope(a, "user", try blocks(a, S(summary)), try C.fmt(a, "omp-summary-{s}", .{C.s(boundary, "id")}), ts);
            try C.set(a, &entry, "isCompactSummary", C.boolean(true));
            try output.append(entry);
            if (compact != null and C.get(path[compact.?], "preserveData") != .null) try warnings.append("OMP provider-private compaction state excluded; readable summary and retained messages preserved");
        }
        if (is(row, "compaction") or is(row, "reset_boundary")) continue;
        try appendNativeEntry(a, &output, row, thread, warnings);
    }
    return output.toOwnedSlice();
}

const Pending = struct { source_id: []const u8, id: []const u8, name: []const u8 };
const Builder = struct {
    a: A,
    thread: C.Thread,
    opts: C.ConvertOptions,
    id: []const u8,
    rows: Values,
    pending: std.array_list.Managed(Pending),
    warnings: C.Warnings,
    parent: V = .null,
    counter: usize = 0,
    messages: usize = 0,
    tools: usize = 0,
    active_start: usize = 2,
    active_summary: []const u8 = "",
    fn next(self: *Builder, label: []const u8) ![]const u8 {
        self.counter += 1;
        return C.uuid5(self.a, entry_namespace, try C.fmt(self.a, "{s}:{s}:{d}", .{ self.id, label, self.counter }));
    }
    fn append(self: *Builder, kind: []const u8, fields: []const C.Pair, timestamp: []const u8) ![]const u8 {
        const id = try self.next(kind);
        var row = try C.obj(self.a, &.{ .{ "type", S(kind) }, .{ "id", S(id) }, .{ "parentId", self.parent }, .{ "timestamp", S(timestamp) } });
        for (fields) |field| try C.set(self.a, &row, field[0], field[1]);
        try self.rows.append(row);
        self.parent = S(id);
        return id;
    }
    fn nativeContent(self: *Builder, block: V) !?V {
        if (is(block, "thinking") or is(block, "redacted_thinking")) return null;
        if (is(block, "text")) return try C.obj(self.a, &.{ .{ "type", S("text") }, .{ "text", S(C.s(block, "text")) } });
        if (is(block, "image")) {
            const source = C.get(block, "source");
            const data = C.s(source, "data");
            const mime = C.s(source, "media_type");
            if (self.opts.embed_images and is(source, "base64") and std.mem.startsWith(u8, mime, "image/")) {
                const decoder = std.base64.standard.Decoder;
                const size = decoder.calcSizeForSlice(data) catch null;
                if (size) |n| {
                    const decoded = try self.a.alloc(u8, n);
                    if (decoder.decode(decoded, data)) |_| return try C.obj(self.a, &.{ .{ "type", S("image") }, .{ "data", S(data) }, .{ "mimeType", S(mime) } }) else |_| {}
                }
                try self.warnings.append("Invalid source image base64; original attachment retained as text");
            }
            // Portable OMP images require base64 data, not HTTP URLs.
            const description = if (!self.opts.embed_images) "[Image attachment; bytes remain in the original transcript]" else try C.fmt(self.a, "[Source image attachment]\n{s}", .{try C.json(self.a, block)});
            if (self.opts.embed_images) try self.warnings.append("Image is not portable base64; complete source attachment preserved as text");
            return try C.obj(self.a, &.{ .{ "type", S("text") }, .{ "text", S(description) } });
        }
        return try C.obj(self.a, &.{ .{ "type", S("text") }, .{ "text", S(try C.fmt(self.a, "[Source attachment: {s}]\n{s}", .{ C.s(block, "type"), try C.json(self.a, block) })) } });
    }
    fn usage(self: *Builder) !V {
        const cost = try C.obj(self.a, &.{ .{ "input", N(0) }, .{ "output", N(0) }, .{ "cacheRead", N(0) }, .{ "cacheWrite", N(0) }, .{ "total", N(0) } });
        return C.obj(self.a, &.{ .{ "input", N(0) }, .{ "output", N(0) }, .{ "cacheRead", N(0) }, .{ "cacheWrite", N(0) }, .{ "totalTokens", N(0) }, .{ "cost", cost } });
    }
    fn message(self: *Builder, role: []const u8, content: []const V, timestamp: []const u8) !void {
        if (content.len == 0) return;
        var msg = try C.obj(self.a, &.{ .{ "role", S(role) }, .{ "content", try C.arr(self.a, content) }, .{ "timestamp", N(try C.timestampMillis(timestamp)) } });
        if (C.eq(role, "assistant")) {
            var calls = false;
            for (content) |block| if (is(block, "toolCall")) {
                calls = true;
            };
            try C.set(self.a, &msg, "api", S("openai-completions"));
            try C.set(self.a, &msg, "provider", S("c2c"));
            try C.set(self.a, &msg, "model", S("imported-history"));
            try C.set(self.a, &msg, "usage", try self.usage());
            try C.set(self.a, &msg, "stopReason", S(if (calls) "toolUse" else "stop"));
        }
        _ = try self.append("message", &.{.{ "message", msg }}, timestamp);
    }
    fn result(self: *Builder, source_id: []const u8, raw: V, timestamp: []const u8, failed: bool, missing: bool) anyerror!void {
        var found: ?usize = null;
        for (self.pending.items, 0..) |p, i| if (C.eq(p.source_id, source_id)) {
            found = i;
            break;
        };
        if (found == null) {
            try self.message("assistant", &.{try C.obj(self.a, &.{ .{ "type", S("text") }, .{ "text", S(try C.fmt(self.a, "[Unpaired historical tool result]\n{s}", .{try C.json(self.a, raw)})) } })}, timestamp);
            try self.warnings.append("Unpaired historical tool result preserved as a visible artifact");
            return;
        }
        const saved = self.pending.orderedRemove(found.?);
        var content = Values.init(self.a);
        for (try blocks(self.a, raw)) |part| if (try self.nativeContent(part)) |native| try content.append(native);
        const msg = try C.obj(self.a, &.{ .{ "role", S("toolResult") }, .{ "toolCallId", S(saved.id) }, .{ "toolName", S(saved.name) }, .{ "content", try C.arr(self.a, content.items) }, .{ "isError", C.boolean(failed or missing) }, .{ "timestamp", N(try C.timestampMillis(timestamp)) } });
        _ = try self.append("message", &.{.{ "message", msg }}, timestamp);
        self.tools += 1;
    }
    fn flush(self: *Builder, timestamp: []const u8) anyerror!void {
        while (self.pending.items.len > 0) {
            try self.result(self.pending.items[0].source_id, S("This historical tool call has no saved result. c2c did not execute it."), timestamp, true, true);
            try self.warnings.append("Incomplete historical tool call closed without execution");
        }
    }
    fn compact(self: *Builder, summary: []const u8, keep: []const u8, timestamp: []const u8) !void {
        _ = try self.append("compaction", &.{ .{ "summary", S(summary) }, .{ "firstKeptEntryId", S(keep) }, .{ "tokensBefore", N(0) }, .{ "fromExtension", C.boolean(true) }, .{ "details", try C.obj(self.a, &.{.{ "kind", S("c2c-import") }}) } }, timestamp);
        self.active_start = self.rows.items.len;
        self.active_summary = summary;
    }
    fn bounded(self: *Builder, timestamp: []const u8) !void {
        const bytes = try activeBytes(self.a, self.rows.items);
        var starts = std.array_list.Managed(usize).init(self.a);
        var unfinished = std.StringHashMap(void).init(self.a);
        for (self.rows.items[self.active_start..], self.active_start..) |row, i| {
            if (!is(row, "message")) continue;
            const active_message = C.get(row, "message");
            const role = C.s(active_message, "role");
            if (starts.items.len == 0 or (C.eq(role, "user") and unfinished.count() == 0)) try starts.append(i);
            if (C.eq(role, "assistant")) {
                for (C.list(C.get(active_message, "content"))) |part| if (is(part, "toolCall")) try unfinished.put(C.s(part, "id"), {});
            } else if (C.eq(role, "toolResult")) _ = unfinished.remove(C.s(active_message, "toolCallId"));
        }
        if (bytes <= max_active_bytes) return;
        var end = self.rows.items.len;
        var start: ?usize = null;
        var size: usize = 0;
        var i = starts.items.len;
        while (i > 0) {
            i -= 1;
            const n = starts.items[i];
            const length = (try C.json(self.a, try C.arr(self.a, self.rows.items[n..end]))).len;
            if (size + length > recent_bytes) break;
            size += length;
            start = n;
            end = n;
        }
        const prior_summary = try jsonExcerpt(self.a, self.active_summary, 35_000);
        const notice = try C.fmt(self.a, "c2c restored a bounded recent context window. Earlier messages and tool outputs remain in the full native transcript. This is an extractive window, not a semantic summary.\nFull native transcript: {s}\nOriginal transcript: {s}{s}{s}", .{ self.opts.transcript_path orelse "[this session file]", self.thread.rollout_path, if (prior_summary.len > 0) "\nExisting compact summary (possibly excerpted):\n" else "", prior_summary });
        if (start) |n| {
            try self.compact(notice, C.s(self.rows.items[n], "id"), timestamp);
        } else {
            var latest_user: ?V = null;
            var latest_answer: ?V = null;
            const newest_start = if (starts.items.len > 0) starts.items[starts.items.len - 1] else self.rows.items.len;
            for (self.rows.items[newest_start..], newest_start..) |row, row_index| {
                if (!is(row, "message")) continue;
                const msg = C.get(row, "message");
                const role = C.s(msg, "role");
                if (C.eq(role, "user") and row_index == newest_start) latest_user = msg else if (C.eq(role, "assistant")) {
                    var has_text = false;
                    for (C.list(C.get(msg, "content"))) |part| if (is(part, "text") and C.s(part, "text").len > 0) {
                        has_text = true;
                    };
                    if (has_text) latest_answer = msg;
                }
            }
            try self.compact(notice, "", timestamp);
            for ([_]?V{ latest_user, latest_answer }) |maybe| if (maybe) |msg| {
                const text = try textOf(self.a, C.list(C.get(msg, "content")));
                const excerpt = try jsonExcerpt(self.a, text, 35_000);
                try self.message(C.s(msg, "role"), &.{try C.obj(self.a, &.{ .{ "type", S("text") }, .{ "text", S(try C.fmt(self.a, "{s}{s}", .{ excerpt, if (text.len > excerpt.len) "\n[c2c: excerpt shortened; full content remains in the transcript.]" else "" })) } })}, timestamp);
            };
        }
        if (try activeBytes(self.a, self.rows.items) > max_active_bytes) return error.OmpContextBudgetExceeded;
        try self.warnings.append("Large source history retained in full; OMP active context uses a labelled recent window");
    }
};

pub fn convert(a: A, thread: C.Thread, entries: []const V, opts: C.ConvertOptions) !C.Conversion {
    const provider = opts.source_provider orelse thread.provider;
    const source_id = opts.source_session_id orelse thread.id;
    const id = try C.sessionIdFor(a, "omp", provider, source_id);
    var self = Builder{ .a = a, .thread = thread, .opts = opts, .id = id, .rows = Values.init(a), .pending = std.array_list.Managed(Pending).init(a), .warnings = C.Warnings.init(a) };
    const created = try stamp(a, S(thread.created_at), thread.updated_at);
    try self.rows.append(try C.obj(a, &.{ .{ "type", S("session") }, .{ "version", N(3) }, .{ "id", S(id) }, .{ "timestamp", S(created) }, .{ "cwd", S(thread.cwd) }, .{ "title", S(thread.title) }, .{ "titleSource", S("user") } }));
    const origin = try C.obj(a, &.{ .{ "version", N(1) }, .{ "sourceProvider", S(provider) }, .{ "sourceSessionId", S(source_id) } });
    _ = try self.append("custom", &.{ .{ "customType", S(provenance_type) }, .{ "data", origin } }, created);
    var last = created;
    var summary_pending = false;
    var source_count: usize = 0;
    for (entries) |entry| {
        if (C.eq(C.s(entry, "subtype"), "compact_boundary")) {
            try self.flush(last);
            summary_pending = true;
            continue;
        }
        const msg = C.get(entry, "message");
        const role = fallback(C.s(msg, "role"), C.s(entry, "type"));
        if (!C.eq(role, "user") and !C.eq(role, "assistant")) continue;
        source_count += 1;
        last = try stamp(a, C.get(entry, "timestamp"), thread.updated_at);
        const input = try blocks(a, C.get(msg, "content"));
        if (C.b(C.get(entry, "isCompactSummary")) or (summary_pending and C.eq(role, "user"))) {
            try self.flush(last);
            try self.compact(try textOf(a, input), "", last);
            summary_pending = false;
            self.messages += 1;
            continue;
        }
        var has_result = false;
        for (input) |part| if (is(part, "tool_result")) {
            has_result = true;
        };
        if (C.eq(role, "user") and !has_result) try self.flush(last);
        var content = Values.init(a);
        for (input) |part| {
            if (is(part, "tool_use")) {
                if (!C.eq(role, "assistant")) return error.ToolCallOutsideAssistant;
                const given = C.s(part, "id");
                const old = if (given.len > 0) given else try self.next("missing-source-tool-id");
                for (self.pending.items) |p| if (C.eq(p.source_id, old)) return error.DuplicatePendingToolId;
                const call = try self.next("call");
                const name = fallback(C.s(part, "name"), "historical_tool");
                try self.pending.append(.{ .source_id = old, .id = call, .name = name });
                const args = C.get(part, "input");
                try content.append(try C.obj(a, &.{ .{ "type", S("toolCall") }, .{ "id", S(call) }, .{ "name", S(name) }, .{ "arguments", if (args == .null) try C.obj(a, &.{}) else try C.clone(a, args) } }));
            } else if (is(part, "tool_result")) {
                try self.message(role, content.items, last);
                content.clearRetainingCapacity();
                try self.result(C.s(part, "tool_use_id"), C.get(part, "content"), last, C.b(C.get(part, "is_error")), false);
            } else if (try self.nativeContent(part)) |native| try content.append(native);
        }
        if (content.items.len > 0) {
            try self.message(role, content.items, last);
            self.messages += 1;
        }
    }
    try self.flush(last);
    try self.bounded(last);
    var marker = self.rows.items[1];
    var data = C.get(marker, "data");
    try C.set(a, &data, "fingerprint", S(try fingerprint(a, self.rows.items)));
    try C.set(a, &marker, "data", data);
    self.rows.items[1] = marker;
    if ((try validate(a, self.rows.items)).len > 0) return error.InvalidOmpRollout;
    return .{ .entries = try self.rows.toOwnedSlice(), .warnings = try self.warnings.toOwnedSlice(), .message_count = self.messages, .tool_count = self.tools, .source_item_count = source_count, .session_id = id };
}
fn activeRows(a: A, rows: []const V) ![]const V {
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
fn activeBytes(a: A, rows: []const V) !usize {
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

fn fixture() C.Thread {
    return .{ .id = "source-session", .provider = "claude", .title = "OMP fixture", .cwd = "/tmp/c2c-omp-project", .created_at = "2026-10-06T00:00:00.000Z", .updated_at = "2026-10-06T00:01:00.000Z", .rollout_path = "/tmp/source.jsonl" };
}
fn fixtureEntry(a: A, role: []const u8, content: V) !V {
    return envelope(a, role, try blocks(a, content), "source-message", "2026-10-06T00:00:00.000Z");
}
test "OMP v3 native tool pairs images and provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const call = try C.parse(a, "[{\"type\":\"tool_use\",\"id\":\"a\",\"name\":\"Bash\",\"input\":{\"command\":\"pwd\"}}]");
    const result = try C.parse(a, "[{\"type\":\"tool_result\",\"tool_use_id\":\"a\",\"content\":\"/tmp\"}]");
    const converted = try convert(a, fixture(), &.{ try fixtureEntry(a, "user", S("Question")), try fixtureEntry(a, "assistant", call), try fixtureEntry(a, "user", result), try fixtureEntry(a, "assistant", S("Done")) }, .{});
    try std.testing.expectEqual(@as(usize, 1), converted.tool_count);
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, converted.entries)).len);
    try std.testing.expectEqualStrings("claude", C.s(C.get(converted.entries[1], "data"), "sourceProvider"));
    try std.testing.expectEqualStrings(try fingerprint(a, converted.entries), C.s(C.get(converted.entries[1], "data"), "fingerprint"));
    try std.testing.expect(std.mem.indexOf(u8, try targetPath(a, fixture(), "/tmp/omp-agent"), "/sessions/-tmp-c2c-omp-project/") != null);
}
test "OMP compaction preserves full archive and bounds continuation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const huge = try a.alloc(u8, 350_000);
    @memset(huge, 'x');
    const converted = try convert(a, fixture(), &.{ try fixtureEntry(a, "user", S(huge)), try fixtureEntry(a, "assistant", S("Recent answer")) }, .{});
    var found = false;
    for (converted.entries) |row| if (is(row, "compaction")) {
        found = true;
        try std.testing.expect(C.s(row, "summary").len < 40_000);
    };
    try std.testing.expect(found);
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, converted.entries)).len);
    try std.testing.expect((try C.json(a, try C.arr(a, converted.entries))).len > 350_000);
}
test "OMP missing tool result is closed without executing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const call = try C.parse(a, "[{\"type\":\"tool_use\",\"id\":\"a\",\"name\":\"dangerous historical tool\",\"input\":{}}]");
    const converted = try convert(a, fixture(), &.{ try fixtureEntry(a, "user", S("Question")), try fixtureEntry(a, "assistant", call) }, .{});
    try std.testing.expectEqual(@as(usize, 1), converted.tool_count);
    try std.testing.expectEqual(@as(usize, 1), converted.warnings.len);
    const last = C.get(converted.entries[converted.entries.len - 1], "message");
    try std.testing.expect(C.b(C.get(last, "isError")));
}

fn testDirectory(a: A) ![]const u8 {
    const path = try a.dupeZ(u8, "/tmp/c2c-omp-test-XXXXXX");
    if (C.c.mkdtemp(path.ptr) == null) return error.TempDirectoryUnavailable;
    return path;
}
fn testCleanup(a: A, path: []const u8) void {
    const contents = C.listDir(a, path) catch return;
    for (contents) |child| {
        const full = C.join(a, &.{ path, child.name }) catch continue;
        if (child.is_dir and !child.is_symlink) testCleanup(a, full) else C.removeFile(full) catch {};
    }
    const z = a.dupeZ(u8, path) catch return;
    _ = C.c.rmdir(z.ptr);
}
fn testWrite(a: A, path: []const u8, rows: []const V) !void {
    try C.mkdirAll(std.fs.path.dirname(path).?);
    var body = std.array_list.Managed(u8).init(a);
    for (rows) |row| {
        try body.appendSlice(try C.json(a, row));
        try body.append('\n');
    }
    try C.atomicWrite(a, path, body.items);
}
test "OMP discovery native reader provenance and malformed continuation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try testDirectory(a);
    defer testCleanup(a, home);
    const converted = try convert(a, fixture(), &.{ try fixtureEntry(a, "user", S("Original question")), try fixtureEntry(a, "assistant", S("Original answer")) }, .{});
    const path = try targetPath(a, fixture(), home);
    try testWrite(a, path, converted.entries);
    const threads = try listThreads(a, home);
    try std.testing.expectEqual(@as(usize, 1), threads.len);
    try std.testing.expectEqualStrings("omp", threads[0].provider);
    try std.testing.expect(threads[0].unchanged_import);
    try std.testing.expectEqualStrings("claude", threads[0].origin_provider.?);
    var warnings = C.Warnings.init(a);
    const visible = try readEntries(a, threads[0], &warnings);
    try std.testing.expectEqual(@as(usize, 2), visible.len);
    try std.testing.expectEqualStrings("Original answer", C.s(C.list(C.get(C.get(visible[1], "message"), "content"))[0], "text"));
    const before = try C.readFile(a, path);
    try C.atomicWrite(a, path, try C.fmt(a, "{s}{{", .{before}));
    const origin = try readOrigin(a, threads[0]);
    try std.testing.expect(origin.id != null);
    try std.testing.expect(!origin.unchanged);
}
test "OMP branch tree excludes siblings and resolves content-addressed image bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try testDirectory(a);
    defer testCleanup(a, home);
    const converted = try convert(a, fixture(), &.{ try fixtureEntry(a, "user", S("Root question")), try fixtureEntry(a, "assistant", S("Abandoned sibling")) }, .{});
    var rows = Values.init(a);
    try rows.appendSlice(converted.entries);
    const bytes = "synthetic image bytes";
    const hash = try C.sha256(a, bytes);
    try C.mkdirAll(try C.join(a, &.{ home, "blobs" }));
    try C.writeExclusive(try C.join(a, &.{ home, "blobs", hash }), bytes);
    const image = try C.obj(a, &.{ .{ "type", S("image") }, .{ "data", S(try C.fmt(a, "blob:sha256:{s}", .{hash})) }, .{ "mimeType", S("image/png") } });
    try rows.append(try C.obj(a, &.{ .{ "type", S("message") }, .{ "id", S("selected-branch") }, .{ "parentId", S(C.s(converted.entries[2], "id")) }, .{ "timestamp", S(fixture().updated_at) }, .{ "message", try C.obj(a, &.{ .{ "role", S("user") }, .{ "content", try C.arr(a, &.{image}) }, .{ "timestamp", N(try C.timestampMillis(fixture().updated_at)) } }) } }));
    const path = try targetPath(a, fixture(), home);
    try testWrite(a, path, rows.items);
    var thread = fixture();
    thread.rollout_path = path;
    thread.provider = "omp";
    var warnings = C.Warnings.init(a);
    const visible = try readEntries(a, thread, &warnings);
    try std.testing.expectEqual(@as(usize, 2), visible.len);
    try std.testing.expect(std.mem.indexOf(u8, try C.json(a, try C.arr(a, visible)), "Abandoned sibling") == null);
    const source = C.get(C.list(C.get(C.get(visible[1], "message"), "content"))[0], "source");
    const encoder = std.base64.standard.Encoder;
    const encoded = try a.alloc(u8, encoder.calcSize(bytes.len));
    _ = encoder.encode(encoded, bytes);
    try std.testing.expectEqualStrings(encoded, C.s(source, "data"));
}
test "OMP compaction retained tail follows canonical summary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try testDirectory(a);
    defer testCleanup(a, home);
    const converted = try convert(a, fixture(), &.{ try fixtureEntry(a, "user", S("Archived request")), try fixtureEntry(a, "assistant", S("Archived answer")), try fixtureEntry(a, "user", S("Retained request")), try fixtureEntry(a, "assistant", S("Retained answer")) }, .{});
    var rows = Values.init(a);
    try rows.appendSlice(converted.entries);
    try rows.append(try C.obj(a, &.{ .{ "type", S("compaction") }, .{ "id", S("latest-compact") }, .{ "parentId", S(C.s(rows.items[rows.items.len - 1], "id")) }, .{ "timestamp", S(fixture().updated_at) }, .{ "summary", S("Readable saved summary") }, .{ "firstKeptEntryId", S(C.s(rows.items[4], "id")) }, .{ "tokensBefore", N(500) } }));
    const path = try targetPath(a, fixture(), home);
    try testWrite(a, path, rows.items);
    var thread = fixture();
    thread.rollout_path = path;
    var warnings = C.Warnings.init(a);
    const visible = try readEntries(a, thread, &warnings);
    try std.testing.expectEqual(@as(usize, 6), visible.len);
    try std.testing.expectEqualStrings("compact_boundary", C.s(visible[2], "subtype"));
    try std.testing.expect(C.b(C.get(visible[3], "isCompactSummary")));
    try std.testing.expectEqualStrings("Retained request", C.s(C.list(C.get(C.get(visible[4], "message"), "content"))[0], "text"));
}

test "OMP bounded mixed user result never splits native tool pairs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const huge = try a.alloc(u8, 250_000);
    @memset(huge, 'x');
    const call = try C.parse(a, "[{\"type\":\"tool_use\",\"id\":\"a\",\"name\":\"Bash\",\"input\":{\"command\":\"pwd\"}}]");
    const result = try C.parse(a, "[{\"type\":\"text\",\"text\":\"interleaved tool feedback\"},{\"type\":\"tool_result\",\"tool_use_id\":\"a\",\"content\":\"/tmp\"}]");
    const converted = try convert(a, fixture(), &.{ try fixtureEntry(a, "user", S(huge)), try fixtureEntry(a, "assistant", call), try fixtureEntry(a, "user", result), try fixtureEntry(a, "assistant", S("Newest final answer")) }, .{});
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, converted.entries)).len);
    try std.testing.expect(try activeBytes(a, converted.entries) < max_active_bytes);
    const active = try activeRows(a, converted.entries);
    try std.testing.expect(std.mem.indexOf(u8, try C.json(a, try C.arr(a, active)), "Newest final answer") != null);
    for (active) |row| try std.testing.expect(!C.eq(C.s(C.get(row, "message"), "role"), "toolResult"));
}
test "OMP bounds JSON escaped excerpts and summary-only context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const escaped = try a.alloc(u8, 100_000);
    @memset(escaped, 0);
    const converted = try convert(a, fixture(), &.{ try fixtureEntry(a, "user", S(escaped)), try fixtureEntry(a, "assistant", S(escaped)) }, .{});
    try std.testing.expect(try activeBytes(a, converted.entries) < max_active_bytes);
    var summary = try fixtureEntry(a, "user", S(escaped));
    try C.set(a, &summary, "isCompactSummary", C.boolean(true));
    const compact = try convert(a, fixture(), &.{summary}, .{});
    try std.testing.expect(try activeBytes(a, compact.entries) < max_active_bytes);
    try std.testing.expect(compact.warnings.len > 0);
}
test "OMP provenance normalizes title slot and verified image blob rewrites" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try testDirectory(a);
    defer testCleanup(a, home);
    const bytes = "synthetic image payload";
    const hash = try C.sha256(a, bytes);
    const encoder = std.base64.standard.Encoder;
    const encoded = try a.alloc(u8, encoder.calcSize(bytes.len));
    _ = encoder.encode(encoded, bytes);
    const image = try C.obj(a, &.{ .{ "type", S("image") }, .{ "source", try C.obj(a, &.{ .{ "type", S("base64") }, .{ "media_type", S("image/png") }, .{ "data", S(encoded) } }) } });
    const converted = try convert(a, fixture(), &.{ try fixtureEntry(a, "user", try C.arr(a, &.{image})), try fixtureEntry(a, "assistant", S("Visible answer")) }, .{});
    var rows = Values.init(a);
    try rows.append(try C.obj(a, &.{ .{ "type", S("title") }, .{ "v", N(1) }, .{ "title", S(fixture().title) }, .{ "source", S("user") }, .{ "updatedAt", S(fixture().created_at) }, .{ "pad", S("") } }));
    for (converted.entries) |row| try rows.append(try C.clone(a, row));
    const parts = C.get(C.get(rows.items[3], "message"), "content");
    try C.set(a, &parts.array.items[0], "data", S(try C.fmt(a, "blob:sha256:{s}", .{hash})));
    try C.mkdirAll(try C.join(a, &.{ home, "blobs" }));
    const blob = try C.join(a, &.{ home, "blobs", hash });
    try C.writeExclusive(blob, bytes);
    const path = try targetPath(a, fixture(), home);
    try testWrite(a, path, rows.items);
    var thread = fixture();
    thread.rollout_path = path;
    try std.testing.expect((try readOrigin(a, thread)).unchanged);
    try C.atomicWrite(a, blob, "changed bytes");
    try std.testing.expect(!(try readOrigin(a, thread)).unchanged);
}
test "OMP provider snapshot keeps readable tail after replay-through entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try testDirectory(a);
    defer testCleanup(a, home);
    const converted = try convert(a, fixture(), &.{ try fixtureEntry(a, "user", S("Archived")), try fixtureEntry(a, "assistant", S("Snapshot through here")), try fixtureEntry(a, "user", S("Retained since snapshot")), try fixtureEntry(a, "assistant", S("Recent answer")) }, .{});
    var rows = Values.init(a);
    try rows.appendSlice(converted.entries);
    try rows.append(try C.obj(a, &.{ .{ "type", S("compaction") }, .{ "id", S("native-snapshot") }, .{ "parentId", S(C.s(rows.items[rows.items.len - 1], "id")) }, .{ "timestamp", S(fixture().updated_at) }, .{ "summary", S("Readable summary") }, .{ "firstKeptEntryId", S("") }, .{ "providerReplayThroughEntryId", S(C.s(rows.items[3], "id")) }, .{ "tokensBefore", N(500) }, .{ "preserveData", try C.obj(a, &.{}) } }));
    const path = try targetPath(a, fixture(), home);
    try testWrite(a, path, rows.items);
    var thread = fixture();
    thread.rollout_path = path;
    var warnings = C.Warnings.init(a);
    const visible = try readEntries(a, thread, &warnings);
    try std.testing.expectEqualStrings("compact_boundary", C.s(visible[2], "subtype"));
    try std.testing.expectEqualStrings("Retained since snapshot", C.s(C.list(C.get(C.get(visible[4], "message"), "content"))[0], "text"));
}

test "OMP provenance accepts only one valid physical title slot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try testDirectory(a);
    defer testCleanup(a, home);
    const converted = try convert(a, fixture(), &.{ try fixtureEntry(a, "user", S("Question")), try fixtureEntry(a, "assistant", S("Answer")) }, .{});
    const path = try targetPath(a, fixture(), home);
    try testWrite(a, path, converted.entries);
    const original = try C.readFile(a, path);
    var thread = fixture();
    thread.rollout_path = path;
    try C.atomicWrite(a, path, try C.fmt(a, "{{\"type\":\"title\",\"v\":1}}\n{s}", .{original}));
    try std.testing.expect(!(try readOrigin(a, thread)).unchanged);
    const slot = "{\"type\":\"title\",\"v\":1,\"title\":\"x\",\"updatedAt\":\"2026-10-06T00:00:00.000Z\",\"pad\":\"\"}\n";
    try C.atomicWrite(a, path, try C.fmt(a, "{s}{s}{s}", .{ slot, slot, original }));
    try std.testing.expect(!(try readOrigin(a, thread)).unchanged);
}

test "OMP standalone native shell history is discoverable and paired" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try testDirectory(a);
    defer testCleanup(a, home);
    const header = try C.obj(a, &.{ .{ "type", S("session") }, .{ "version", N(3) }, .{ "id", S("standalone-shell") }, .{ "timestamp", S(fixture().created_at) }, .{ "cwd", S(fixture().cwd) } });
    const native = try C.obj(a, &.{ .{ "type", S("message") }, .{ "id", S("shell") }, .{ "parentId", .null }, .{ "timestamp", S(fixture().updated_at) }, .{ "message", try C.obj(a, &.{ .{ "role", S("bashExecution") }, .{ "command", S("pwd") }, .{ "output", S("/tmp") }, .{ "exitCode", N(0) } }) } });
    const path = try C.join(a, &.{ home, "sessions", "fixture", "shell.jsonl" });
    try testWrite(a, path, &.{ header, native });
    const threads = try listThreads(a, home);
    try std.testing.expectEqual(@as(usize, 1), threads.len);
    var warnings = C.Warnings.init(a);
    const visible = try readEntries(a, threads[0], &warnings);
    try std.testing.expectEqual(@as(usize, 2), visible.len);
    const call = C.list(C.get(C.get(visible[0], "message"), "content"))[0];
    const result = C.list(C.get(C.get(visible[1], "message"), "content"))[0];
    try std.testing.expectEqualStrings(C.s(call, "id"), C.s(result, "tool_use_id"));
}
