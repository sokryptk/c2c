const std = @import("std");
const common = @import("../common.zig");
const Allocator = common.Allocator;
const Value = common.Value;
const jsonString = common.str;
const Values = std.array_list.Managed(Value);
const format = @import("format.zig");

fn shortText(allocator: Allocator, text: []const u8, limit: usize) ![]const u8 {
    if (text.len <= limit) {
        return allocator.dupe(u8, text);
    }
    var end = limit;
    while (end > 0 and (text[end] & 0xc0) == 0x80) : (end -= 1) {}
    return allocator.dupe(u8, text[0..end]);
}

pub const Origin = struct {
    provider: ?[]const u8 = null,
    id: ?[]const u8 = null,
    original_id: ?[]const u8 = null,
    unchanged: bool = false,
};

pub fn readOrigin(allocator: Allocator, thread: common.Thread) !Origin {
    var reader = common.LineReader.open(allocator, thread.rollout_path) catch return .{};
    defer reader.close();
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var origin = Origin{};
    var expected: []const u8 = "";
    var count: usize = 0;
    var physical_line: usize = 0;
    while (reader.next() catch return origin) |line| {
        const first_line = physical_line == 0;
        physical_line += 1;
        if (std.mem.trim(u8, line, " \t\r\n").len == 0) {
            continue;
        }
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const row = common.parse(arena.allocator(), line) catch return origin;
        if (row != .object) {
            return origin;
        }
        if (!reader.last_terminated) {
            return origin;
        }
        if (first_line and format.is(row, "title")) {
            const source = row.object.get("source");
            const valid_source = if (source) |value|
                common.eq(common.text(value), "auto") or common.eq(common.text(value), "user")
            else
                true;
            if (common.integer(common.get(row, "v")) != 1 or
                common.get(row, "title") != .string or
                common.get(row, "updatedAt") != .string or
                common.get(row, "pad") != .string or
                !valid_source)
            {
                return origin;
            }
            continue;
        }
        if (format.is(row, "custom") and common.eq(common.stringField(row, "customType"), format.provenance_type)) {
            if (origin.id != null) {
                return origin;
            }
            const data = common.get(row, "data");
            const provider = common.stringField(data, "sourceProvider");
            const session_id = common.stringField(data, "sourceSessionId");
            if (provider.len == 0 or session_id.len == 0) {
                return origin;
            }
            origin.provider = try allocator.dupe(u8, provider);
            origin.id = try allocator.dupe(u8, session_id);
            origin.original_id = origin.id;
            expected = try allocator.dupe(u8, common.stringField(data, "fingerprint"));
        }
        format.hashRow(arena.allocator(), &hash, row, thread.rollout_path) catch return origin;
        count += 1;
        // Provenance follows the header; native sessions need no full read.
        if (count >= 3 and origin.id == null) {
            return .{};
        }
    }
    if (origin.id != null) {
        origin.unchanged = common.eq(expected, try format.digest(allocator, &hash));
    }
    return origin;
}

pub fn listThreads(allocator: Allocator, home: []const u8) ![]common.Thread {
    const root = try common.canonicalPath(allocator, home);
    const sessions = try common.join(allocator, &.{ root, "sessions" });
    if (!common.exists(sessions)) {
        return allocator.alloc(common.Thread, 0);
    }
    var result = std.array_list.Managed(common.Thread).init(allocator);
    for (try common.walkFiles(allocator, sessions, ".jsonl")) |path| {
        var reader = common.LineReader.open(allocator, path) catch continue;
        defer reader.close();
        var header: Value = .null;
        var title: []const u8 = "";
        var created: []const u8 = "";
        var updated: []const u8 = "";
        var user_preview: []const u8 = "";
        var saw_message = false;
        var position: usize = 0;
        while (try reader.next()) |line| {
            if (std.mem.trim(u8, line, " \t\r\n").len == 0) {
                continue;
            }
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const row = common.parse(arena.allocator(), line) catch {
                if (!reader.last_terminated) {
                    break;
                }
                return error.MalformedOmpSession;
            };
            if (format.is(row, "title") and position == 0) {
                title = try allocator.dupe(u8, common.stringField(row, "title"));
                position += 1;
                continue;
            }
            if (header == .null) {
                if (!format.is(row, "session")) {
                    break;
                }
                header = try common.clone(allocator, row);
                if (title.len == 0) {
                    title = common.stringField(header, "title");
                }
                created = format.stamp(allocator, common.get(header, "timestamp"), "1970-01-01T00:00:00.000Z") catch break;
                updated = created;
            } else {
                const timestamp = common.get(row, "timestamp");
                if (timestamp != .null) {
                    updated = format.stamp(allocator, timestamp, updated) catch updated;
                }
                const changed_title = common.stringField(row, "title");
                if (format.is(row, "title_change") and changed_title.len > 0) {
                    title = try allocator.dupe(u8, changed_title);
                }
                const message = common.get(row, "message");
                const role = common.stringField(message, "role");
                const visible_role = common.eq(role, "user") or common.eq(role, "assistant") or
                    common.eq(role, "toolResult") or common.eq(role, "bashExecution") or
                    common.eq(role, "pythonExecution") or common.eq(role, "fileMention") or
                    common.eq(role, "custom") or common.eq(role, "hookMessage");
                if (format.is(row, "message") and visible_role) {
                    saw_message = true;
                }
                const has_summary = format.is(row, "compaction") or format.is(row, "branch_summary");
                if (has_summary and common.stringField(row, "summary").len > 0) {
                    saw_message = true;
                }
                if (format.is(row, "custom_message")) {
                    saw_message = true;
                }
                if (user_preview.len == 0 and common.eq(role, "user")) {
                    const content = try format.blocks(arena.allocator(), common.get(message, "content"));
                    const text = try format.textOf(arena.allocator(), content);
                    user_preview = try shortText(allocator, text, 120);
                }
            }
            position += 1;
        }
        if (header == .null or common.stringField(header, "id").len == 0 or !saw_message) {
            continue;
        }
        const parent_id = common.stringField(header, "parentSession");
        const preview_title = format.fallback(user_preview, "Untitled OMP conversation");
        var thread = common.Thread{
            .id = common.stringField(header, "id"),
            .title = format.fallback(title, preview_title),
            .cwd = common.stringField(header, "cwd"),
            .created_at = created,
            .updated_at = updated,
            .rollout_path = path,
            .provider = "omp",
            .parent_id = if (parent_id.len > 0) parent_id else null,
        };
        const origin = try readOrigin(allocator, thread);
        thread.origin_provider = origin.provider;
        thread.origin_id = origin.id;
        thread.unchanged_import = origin.unchanged;
        try result.append(thread);
    }
    std.mem.sort(common.Thread, result.items, {}, struct {
        fn less(_: void, left: common.Thread, right: common.Thread) bool {
            return std.mem.order(u8, left.updated_at, right.updated_at) == .gt;
        }
    }.less);
    return result.toOwnedSlice();
}

fn imageFromOmp(allocator: Allocator, block: Value, path: []const u8, warnings: *common.Warnings) !Value {
    var data = common.stringField(block, "data");
    const mime = format.fallback(common.stringField(block, "mimeType"), "image/png");
    if (std.mem.startsWith(u8, data, "blob:sha256:")) {
        const key = data[12..];
        var valid = key.len == 64;
        for (key) |ch| {
            if (!std.ascii.isHex(ch) or std.ascii.isUpper(ch)) {
                valid = false;
            }
        }
        const marker = std.mem.lastIndexOf(u8, path, "/sessions/");
        if (valid and marker != null) {
            const blob_path = try common.join(allocator, &.{ path[0..marker.?], "blobs", key });
            const bytes = common.readFile(allocator, blob_path) catch null;
            if (bytes) |value| {
                const actual_hash = try common.sha256(allocator, value);
                if (common.eq(actual_hash, key)) {
                    const encoder = std.base64.standard.Encoder;
                    const encoded = try allocator.alloc(u8, encoder.calcSize(value.len));
                    _ = encoder.encode(encoded, value);
                    data = encoded;
                }
            }
        }
        if (std.mem.startsWith(u8, data, "blob:sha256:")) {
            try warnings.append("OMP image blob missing or invalid; reference preserved as text");
            const text = try common.fmt(allocator, "[OMP image attachment: {s}; {s}]", .{ data, mime });
            return common.obj(allocator, &.{
                .{ "type", jsonString("text") },
                .{ "text", jsonString(text) },
            });
        }
    }
    if (data.len > 0) {
        const source = try common.obj(allocator, &.{
            .{ "type", jsonString("base64") },
            .{ "media_type", jsonString(mime) },
            .{ "data", jsonString(data) },
        });
        return common.obj(allocator, &.{
            .{ "type", jsonString("image") },
            .{ "source", source },
        });
    }
    const url = common.stringField(block, "url");
    if (url.len > 0) {
        const source = try common.obj(allocator, &.{
            .{ "type", jsonString("url") },
            .{ "url", jsonString(url) },
        });
        return common.obj(allocator, &.{
            .{ "type", jsonString("image") },
            .{ "source", source },
        });
    }
    try warnings.append("OMP image has no readable data; metadata preserved as text");
    const metadata = try common.json(allocator, block);
    const text = try common.fmt(allocator, "[OMP image attachment]\n{s}", .{metadata});
    return common.obj(allocator, &.{
        .{ "type", jsonString("text") },
        .{ "text", jsonString(text) },
    });
}

fn fromContent(allocator: Allocator, input: Value, path: []const u8, warnings: *common.Warnings) ![]const Value {
    var result = Values.init(allocator);
    for (try format.blocks(allocator, input)) |block| {
        const kind = common.stringField(block, "type");
        if (common.eq(kind, "thinking") or common.eq(kind, "redactedThinking") or common.eq(kind, "redacted_thinking")) {
            continue;
        }
        if (common.eq(kind, "text")) {
            const text = try common.obj(allocator, &.{
                .{ "type", jsonString("text") },
                .{ "text", jsonString(common.stringField(block, "text")) },
            });
            try result.append(text);
        } else if (common.eq(kind, "image")) {
            const image = try imageFromOmp(allocator, block, path, warnings);
            try result.append(image);
        } else if (common.eq(kind, "toolCall")) {
            const input_args = try common.clone(allocator, common.get(block, "arguments"));
            const call = try common.obj(allocator, &.{
                .{ "type", jsonString("tool_use") },
                .{ "id", jsonString(common.stringField(block, "id")) },
                .{ "name", jsonString(common.stringField(block, "name")) },
                .{ "input", input_args },
            });
            try result.append(call);
        } else {
            const encoded = try common.json(allocator, block);
            const description = try common.fmt(allocator, "[OMP content: {s}]\n{s}", .{ kind, encoded });
            const artifact = try common.obj(allocator, &.{
                .{ "type", jsonString("text") },
                .{ "text", jsonString(description) },
            });
            try result.append(artifact);
            try warnings.append("Unrecognized OMP visible content preserved as a text artifact");
        }
    }
    return result.toOwnedSlice();
}

fn envelope(allocator: Allocator, role: []const u8, content: []const Value, id: []const u8, timestamp: []const u8) !Value {
    const message = try common.obj(allocator, &.{
        .{ "role", jsonString(role) },
        .{ "content", try common.arr(allocator, content) },
    });
    return common.obj(allocator, &.{
        .{ "type", jsonString(role) },
        .{ "uuid", jsonString(id) },
        .{ "timestamp", jsonString(timestamp) },
        .{ "message", message },
    });
}

fn appendNativeEntry(allocator: Allocator, output: *Values, row: Value, thread: common.Thread, warnings: *common.Warnings) !void {
    const timestamp = try format.stamp(allocator, common.get(row, "timestamp"), thread.updated_at);
    const id = common.stringField(row, "id");
    const message = common.get(row, "message");
    const role = common.stringField(message, "role");
    const is_message = format.is(row, "message");
    if (is_message and (common.eq(role, "user") or common.eq(role, "assistant"))) {
        const content = try fromContent(allocator, common.get(message, "content"), thread.rollout_path, warnings);
        if (content.len > 0) {
            const entry = try envelope(allocator, role, content, id, timestamp);
            try output.append(entry);
        }
    } else if (is_message and common.eq(role, "toolResult")) {
        const content = try fromContent(allocator, common.get(message, "content"), thread.rollout_path, warnings);
        const result = try common.obj(allocator, &.{
            .{ "type", jsonString("tool_result") },
            .{ "tool_use_id", jsonString(common.stringField(message, "toolCallId")) },
            .{ "content", try common.arr(allocator, content) },
            .{ "is_error", common.boolean(common.boolValue(common.get(message, "isError"))) },
        });
        const entry = try envelope(allocator, "user", &.{result}, id, timestamp);
        try output.append(entry);
    } else if (is_message and (common.eq(role, "bashExecution") or common.eq(role, "pythonExecution"))) {
        const is_shell = common.eq(role, "bashExecution");
        const name = if (is_shell) "Bash" else "Python";
        const command = format.fallback(common.stringField(message, "command"), common.stringField(message, "code"));
        const call_id = try common.fmt(allocator, "omp-command-{s}", .{id});
        const args = try common.obj(allocator, &.{.{ if (is_shell) "command" else "code", jsonString(command) }});
        const call = try common.obj(allocator, &.{
            .{ "type", jsonString("tool_use") },
            .{ "id", jsonString(call_id) },
            .{ "name", jsonString(name) },
            .{ "input", args },
        });
        const call_entry = try envelope(allocator, "assistant", &.{call}, id, timestamp);
        try output.append(call_entry);
        const text = format.fallback(common.stringField(message, "output"), common.stringField(message, "text"));
        const failed = common.boolValue(common.get(message, "cancelled")) or common.integer(common.get(message, "exitCode")) != 0;
        const result = try common.obj(allocator, &.{
            .{ "type", jsonString("tool_result") },
            .{ "tool_use_id", jsonString(call_id) },
            .{ "content", jsonString(text) },
            .{ "is_error", common.boolean(failed) },
        });
        const result_id = try common.fmt(allocator, "{s}-result", .{id});
        const result_entry = try envelope(allocator, "user", &.{result}, result_id, timestamp);
        try output.append(result_entry);
    } else if ((format.is(row, "custom_message") or (is_message and (common.eq(role, "custom") or common.eq(role, "hookMessage")))) and
        !common.eq(common.stringField(row, "customType"), format.provenance_type))
    {
        const container = if (is_message) message else row;
        const content = try fromContent(allocator, common.get(container, "content"), thread.rollout_path, warnings);
        if (content.len > 0) {
            const entry = try envelope(allocator, "user", content, id, timestamp);
            try output.append(entry);
        }
    } else if (format.is(row, "branch_summary") and common.stringField(row, "summary").len > 0) {
        const summary = try common.fmt(allocator, "[OMP branch summary]\n{s}", .{common.stringField(row, "summary")});
        const content = try format.blocks(allocator, jsonString(summary));
        const entry = try envelope(allocator, "user", content, id, timestamp);
        try output.append(entry);
    } else if (is_message and common.eq(role, "fileMention")) {
        const metadata = try common.json(allocator, message);
        const description = try common.fmt(allocator, "[OMP file attachment]\n{s}", .{metadata});
        const content = try format.blocks(allocator, jsonString(description));
        const entry = try envelope(allocator, "user", content, id, timestamp);
        try output.append(entry);
    }
    // Exclude developer/session_init/custom runtime state and private reasoning.
}

pub fn readEntries(allocator: Allocator, thread: common.Thread, warnings: *common.Warnings) ![]Value {
    const source_rows = try common.readJsonl(allocator, thread.rollout_path, warnings);
    var rows = Values.init(allocator);
    var rows_by_id = std.StringHashMap(usize).init(allocator);
    var previous_id: Value = .null;
    var header_found = false;
    var legacy = false;
    for (source_rows, 0..) |original, index| {
        if (format.is(original, "title")) {
            continue;
        }
        if (!header_found) {
            if (!format.is(original, "session")) {
                return error.InvalidOmpHeader;
            }
            header_found = true;
            legacy = common.integer(common.get(original, "version")) < 2;
            continue;
        }
        var row = try common.clone(allocator, original);
        if (common.stringField(row, "id").len == 0) {
            if (!legacy) {
                return error.OmpEntryIdMissing;
            }
            const legacy_key = try common.fmt(allocator, "{s}:{d}", .{ thread.id, index });
            const legacy_id = try common.uuid5(allocator, format.entry_namespace, legacy_key);
            try common.set(allocator, &row, "id", jsonString(legacy_id));
            try common.set(allocator, &row, "parentId", previous_id);
        }
        if (legacy and format.is(row, "compaction") and common.get(row, "firstKeptEntryIndex") == .integer) {
            const kept = common.integer(common.get(row, "firstKeptEntryIndex"));
            if (kept > 0 and kept <= rows.items.len) {
                const kept_row = rows.items[@intCast(kept - 1)];
                try common.set(allocator, &row, "firstKeptEntryId", jsonString(common.stringField(kept_row, "id")));
            }
        }
        const id = common.stringField(row, "id");
        if (rows_by_id.contains(id)) {
            return error.DuplicateOmpEntryId;
        }
        try rows_by_id.put(id, rows.items.len);
        try rows.append(row);
        previous_id = jsonString(id);
    }
    if (!header_found) {
        return error.InvalidOmpHeader;
    }
    var reverse_path = Values.init(allocator);
    var seen = std.StringHashMap(void).init(allocator);
    var current_index: ?usize = if (rows.items.len > 0) rows.items.len - 1 else null;
    while (current_index) |index| {
        const row = rows.items[index];
        const id = common.stringField(row, "id");
        if (seen.contains(id)) {
            return error.CyclicOmpParentChain;
        }
        try seen.put(id, {});
        try reverse_path.append(row);
        const parent = common.stringField(row, "parentId");
        current_index = if (parent.len == 0) null else rows_by_id.get(parent);
        if (parent.len > 0 and current_index == null) {
            try warnings.append("OMP branch references an unavailable parent; retained readable branch");
        }
    }
    const path = try reverse_path.toOwnedSlice();
    std.mem.reverse(Value, path);
    var context_start: ?usize = null;
    var compaction_index: ?usize = null;
    for (path, 0..) |row, index| {
        if (format.is(row, "reset_boundary")) {
            context_start = index;
            compaction_index = null;
        }
        if (format.is(row, "compaction")) {
            compaction_index = index;
            context_start = index;
            const keep = common.stringField(row, "firstKeptEntryId");
            for (path[0..index], 0..) |prior, prior_index| {
                if (common.eq(common.stringField(prior, "id"), keep)) {
                    context_start = prior_index;
                    break;
                }
            }
            if (context_start.? == index and keep.len == 0) {
                const replayed = common.stringField(row, "providerReplayThroughEntryId");
                if (replayed.len > 0) {
                    for (path[0..index], 0..) |prior, prior_index| {
                        if (common.eq(common.stringField(prior, "id"), replayed)) {
                            context_start = prior_index + 1;
                            break;
                        }
                    }
                }
            }
        }
    }
    var output = Values.init(allocator);
    for (path, 0..) |row, index| {
        if (context_start != null and index == context_start.?) {
            const boundary = if (compaction_index) |j| path[j] else row;
            const timestamp = try format.stamp(allocator, common.get(boundary, "timestamp"), thread.updated_at);
            const boundary_entry = try common.obj(allocator, &.{
                .{ "type", jsonString("system") },
                .{ "subtype", jsonString("compact_boundary") },
                .{ "timestamp", jsonString(timestamp) },
            });
            try output.append(boundary_entry);
            const summary = if (compaction_index) |compact_index|
                format.fallback(
                    common.stringField(path[compact_index], "summary"),
                    "OMP compacted this history without a readable summary. " ++
                        "Earlier content remains in the original transcript.",
                )
            else
                "OMP cleared the previous active context. Earlier content remains in the original transcript.";
            const summary_content = try format.blocks(allocator, jsonString(summary));
            const summary_id = try common.fmt(allocator, "omp-summary-{s}", .{common.stringField(boundary, "id")});
            var entry = try envelope(allocator, "user", summary_content, summary_id, timestamp);
            try common.set(allocator, &entry, "isCompactSummary", common.boolean(true));
            try output.append(entry);
            if (compaction_index != null and common.get(path[compaction_index.?], "preserveData") != .null) {
                try warnings.append(
                    "OMP provider-private compaction state excluded; readable summary and retained messages preserved",
                );
            }
        }
        if (format.is(row, "compaction") or format.is(row, "reset_boundary")) {
            continue;
        }
        try appendNativeEntry(allocator, &output, row, thread, warnings);
    }
    return output.toOwnedSlice();
}
