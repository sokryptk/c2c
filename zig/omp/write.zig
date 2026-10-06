const std = @import("std");
const common = @import("../common.zig");
const Allocator = common.Allocator;
const Value = common.Value;
const jsonString = common.str;
const Values = std.array_list.Managed(Value);
const format = @import("format.zig");
const jsonInteger = common.num;
const recent_bytes = 170_000;

fn jsonExcerpt(allocator: Allocator, text: []const u8, budget: usize) ![]const u8 {
    if ((try common.json(allocator, jsonString(text))).len <= budget) {
        return allocator.dupe(u8, text);
    }
    var low: usize = 0;
    var high = text.len;
    while (low < high) {
        const mid = low + (high - low + 1) / 2;
        var end = mid;
        while (end > 0 and end < text.len and (text[end] & 0xc0) == 0x80) : (end -= 1) {}
        const encoded = try common.json(allocator, jsonString(text[0..end]));
        if (encoded.len <= budget) {
            low = mid;
        } else {
            high = mid - 1;
        }
    }
    while (low > 0 and low < text.len and (text[low] & 0xc0) == 0x80) : (low -= 1) {}
    return allocator.dupe(u8, text[0..low]);
}

fn inside(path: []const u8, root: []const u8) ?[]const u8 {
    if (common.eq(path, root)) {
        return "";
    }
    if (std.mem.startsWith(u8, path, root) and path.len > root.len and path[root.len] == '/') {
        return path[root.len + 1 ..];
    }
    return null;
}

fn bucket(allocator: Allocator, cwd: []const u8) ![]const u8 {
    const canonical = try common.canonicalPath(allocator, cwd);
    const temp = if (common.c.getenv("TMPDIR")) |v| std.mem.span(v) else "/tmp";
    const temp_root = try common.canonicalPath(allocator, temp);
    var prefix: []const u8 = "--";
    var relative = std.mem.trimStart(u8, canonical, "/");
    var suffix: []const u8 = "--";
    if (inside(canonical, temp_root)) |value| {
        prefix = if (value.len == 0) "-tmp" else "-tmp-";
        relative = value;
        suffix = "";
    } else if (common.c.getenv("HOME")) |value| {
        const home = try common.canonicalPath(allocator, std.mem.span(value));
        if (inside(canonical, home)) |part| {
            prefix = "-";
            relative = part;
            suffix = "";
        }
    }
    const encoded = try allocator.dupe(u8, relative);
    for (encoded) |*ch| {
        if (ch.* == '/' or ch.* == '\\' or ch.* == ':') {
            ch.* = '-';
        }
    }
    return common.fmt(allocator, "{s}{s}{s}", .{ prefix, encoded, suffix });
}

pub fn targetPath(allocator: Allocator, thread: common.Thread, home: []const u8) ![]const u8 {
    const timestamp = try format.stamp(allocator, jsonString(thread.created_at), thread.updated_at);
    const filename_timestamp = try allocator.dupe(u8, timestamp);
    for (filename_timestamp) |*ch| {
        if (ch.* == ':') {
            ch.* = '-';
        }
    }
    const id = try common.sessionIdFor(allocator, "omp", thread.provider, thread.id);
    const directory = try bucket(allocator, thread.cwd);
    const filename = try common.fmt(allocator, "{s}_{s}.jsonl", .{ filename_timestamp, id });
    return common.join(allocator, &.{ home, "sessions", directory, filename });
}

const Pending = struct {
    source_id: []const u8,
    id: []const u8,
    name: []const u8,
};

const Builder = struct {
    allocator: Allocator,
    thread: common.Thread,
    opts: common.ConvertOptions,
    id: []const u8,
    rows: Values,
    pending: std.array_list.Managed(Pending),
    warnings: common.Warnings,
    parent: Value = .null,
    counter: usize = 0,
    messages: usize = 0,
    tools: usize = 0,
    active_start: usize = 2,
    active_summary: []const u8 = "",

    fn next(self: *Builder, label: []const u8) ![]const u8 {
        self.counter += 1;
        const key = try common.fmt(self.allocator, "{s}:{s}:{d}", .{ self.id, label, self.counter });
        return common.uuid5(self.allocator, format.entry_namespace, key);
    }
    fn append(self: *Builder, kind: []const u8, fields: []const common.Pair, timestamp: []const u8) ![]const u8 {
        const id = try self.next(kind);
        var row = try common.obj(self.allocator, &.{
            .{ "type", jsonString(kind) },
            .{ "id", jsonString(id) },
            .{ "parentId", self.parent },
            .{ "timestamp", jsonString(timestamp) },
        });
        for (fields) |field| {
            try common.set(self.allocator, &row, field[0], field[1]);
        }
        try self.rows.append(row);
        self.parent = jsonString(id);
        return id;
    }
    fn nativeContent(self: *Builder, block: Value) !?Value {
        const kind = common.stringField(block, "type");
        if (common.eq(kind, "thinking") or common.eq(kind, "redacted_thinking")) {
            return null;
        }
        if (common.eq(kind, "text")) {
            return try common.obj(self.allocator, &.{
                .{ "type", jsonString("text") },
                .{ "text", jsonString(common.stringField(block, "text")) },
            });
        }
        if (common.eq(kind, "image")) {
            const source = common.get(block, "source");
            const data = common.stringField(source, "data");
            const mime = common.stringField(source, "media_type");
            if (self.opts.embed_images and format.is(source, "base64") and std.mem.startsWith(u8, mime, "image/")) {
                const decoder = std.base64.standard.Decoder;
                const size = decoder.calcSizeForSlice(data) catch null;
                if (size) |byte_count| {
                    const decoded = try self.allocator.alloc(u8, byte_count);
                    if (decoder.decode(decoded, data)) |_| {
                        return try common.obj(self.allocator, &.{
                            .{ "type", jsonString("image") },
                            .{ "data", jsonString(data) },
                            .{ "mimeType", jsonString(mime) },
                        });
                    } else |_| {}
                }
                try self.warnings.append("Invalid source image base64; original attachment retained as text");
            }
            // Portable OMP images require base64 data, not HTTP URLs.
            var description: []const u8 = "[Image attachment; bytes remain in the original transcript]";
            if (self.opts.embed_images) {
                const encoded = try common.json(self.allocator, block);
                description = try common.fmt(self.allocator, "[Source image attachment]\n{s}", .{encoded});
                try self.warnings.append("Image is not portable base64; complete source attachment preserved as text");
            }
            return try common.obj(self.allocator, &.{
                .{ "type", jsonString("text") },
                .{ "text", jsonString(description) },
            });
        }
        const encoded = try common.json(self.allocator, block);
        const description = try common.fmt(self.allocator, "[Source attachment: {s}]\n{s}", .{ kind, encoded });
        return try common.obj(self.allocator, &.{
            .{ "type", jsonString("text") },
            .{ "text", jsonString(description) },
        });
    }
    fn usage(self: *Builder) !Value {
        const cost = try common.obj(self.allocator, &.{
            .{ "input", jsonInteger(0) },
            .{ "output", jsonInteger(0) },
            .{ "cacheRead", jsonInteger(0) },
            .{ "cacheWrite", jsonInteger(0) },
            .{ "total", jsonInteger(0) },
        });
        return common.obj(self.allocator, &.{
            .{ "input", jsonInteger(0) },
            .{ "output", jsonInteger(0) },
            .{ "cacheRead", jsonInteger(0) },
            .{ "cacheWrite", jsonInteger(0) },
            .{ "totalTokens", jsonInteger(0) },
            .{ "cost", cost },
        });
    }
    fn message(self: *Builder, role: []const u8, content: []const Value, timestamp: []const u8) !void {
        if (content.len == 0) {
            return;
        }
        var msg = try common.obj(self.allocator, &.{
            .{ "role", jsonString(role) },
            .{ "content", try common.arr(self.allocator, content) },
            .{ "timestamp", jsonInteger(try common.timestampMillis(timestamp)) },
        });
        if (common.eq(role, "assistant")) {
            var calls = false;
            for (content) |block| {
                if (format.is(block, "toolCall")) {
                    calls = true;
                }
            }
            try common.set(self.allocator, &msg, "api", jsonString("openai-completions"));
            try common.set(self.allocator, &msg, "provider", jsonString("c2c"));
            try common.set(self.allocator, &msg, "model", jsonString("imported-history"));
            try common.set(self.allocator, &msg, "usage", try self.usage());
            try common.set(self.allocator, &msg, "stopReason", jsonString(if (calls) "toolUse" else "stop"));
        }
        _ = try self.append("message", &.{.{ "message", msg }}, timestamp);
    }
    fn result(
        self: *Builder,
        source_id: []const u8,
        raw: Value,
        timestamp: []const u8,
        failed: bool,
        missing: bool,
    ) anyerror!void {
        var found: ?usize = null;
        for (self.pending.items, 0..) |pending, index| {
            if (common.eq(pending.source_id, source_id)) {
                found = index;
                break;
            }
        }
        if (found == null) {
            const encoded = try common.json(self.allocator, raw);
            const description = try common.fmt(self.allocator, "[Unpaired historical tool result]\n{s}", .{encoded});
            const artifact = try common.obj(self.allocator, &.{
                .{ "type", jsonString("text") },
                .{ "text", jsonString(description) },
            });
            try self.message("assistant", &.{artifact}, timestamp);
            try self.warnings.append("Unpaired historical tool result preserved as a visible artifact");
            return;
        }
        const saved = self.pending.orderedRemove(found.?);
        var content = Values.init(self.allocator);
        for (try format.blocks(self.allocator, raw)) |part| {
            if (try self.nativeContent(part)) |native| {
                try content.append(native);
            }
        }
        const msg = try common.obj(self.allocator, &.{
            .{ "role", jsonString("toolResult") },
            .{ "toolCallId", jsonString(saved.id) },
            .{ "toolName", jsonString(saved.name) },
            .{ "content", try common.arr(self.allocator, content.items) },
            .{ "isError", common.boolean(failed or missing) },
            .{ "timestamp", jsonInteger(try common.timestampMillis(timestamp)) },
        });
        _ = try self.append("message", &.{.{ "message", msg }}, timestamp);
        self.tools += 1;
    }
    fn flush(self: *Builder, timestamp: []const u8) anyerror!void {
        while (self.pending.items.len > 0) {
            const explanation = jsonString("This historical tool call has no saved result. c2c did not execute it.");
            try self.result(self.pending.items[0].source_id, explanation, timestamp, true, true);
            try self.warnings.append("Incomplete historical tool call closed without execution");
        }
    }
    fn compact(self: *Builder, summary: []const u8, keep: []const u8, timestamp: []const u8) !void {
        const details = try common.obj(self.allocator, &.{.{ "kind", jsonString("c2c-import") }});
        _ = try self.append("compaction", &.{
            .{ "summary", jsonString(summary) },
            .{ "firstKeptEntryId", jsonString(keep) },
            .{ "tokensBefore", jsonInteger(0) },
            .{ "fromExtension", common.boolean(true) },
            .{ "details", details },
        }, timestamp);
        self.active_start = self.rows.items.len;
        self.active_summary = summary;
    }
    fn bounded(self: *Builder, timestamp: []const u8) !void {
        const bytes = try format.activeBytes(self.allocator, self.rows.items);
        var starts = std.array_list.Managed(usize).init(self.allocator);
        var unfinished = std.StringHashMap(void).init(self.allocator);
        for (self.rows.items[self.active_start..], self.active_start..) |row, index| {
            if (!format.is(row, "message")) {
                continue;
            }
            const active_message = common.get(row, "message");
            const role = common.stringField(active_message, "role");
            if (starts.items.len == 0 or (common.eq(role, "user") and unfinished.count() == 0)) {
                try starts.append(index);
            }
            if (common.eq(role, "assistant")) {
                for (common.list(common.get(active_message, "content"))) |part| {
                    if (format.is(part, "toolCall")) {
                        try unfinished.put(common.stringField(part, "id"), {});
                    }
                }
            } else if (common.eq(role, "toolResult")) {
                _ = unfinished.remove(common.stringField(active_message, "toolCallId"));
            }
        }
        if (bytes <= format.max_active_bytes) {
            return;
        }
        var end = self.rows.items.len;
        var start: ?usize = null;
        var size: usize = 0;
        var i = starts.items.len;
        while (i > 0) {
            i -= 1;
            const candidate_start = starts.items[i];
            const candidate = try common.arr(self.allocator, self.rows.items[candidate_start..end]);
            const encoded = try common.json(self.allocator, candidate);
            if (size + encoded.len > recent_bytes) {
                break;
            }
            size += encoded.len;
            start = candidate_start;
            end = candidate_start;
        }
        const prior_summary = try jsonExcerpt(self.allocator, self.active_summary, 35_000);
        const summary_label = if (prior_summary.len > 0) "\nExisting compact summary (possibly excerpted):\n" else "";
        const notice = try common.fmt(
            self.allocator,
            "c2c restored a bounded recent context window. " ++
                "Earlier messages and tool outputs remain in the full native transcript. " ++
                "This is an extractive window, not a semantic summary.\n" ++
                "Full native transcript: {s}\nOriginal transcript: {s}{s}{s}",
            .{
                self.opts.transcript_path orelse "[this session file]",
                self.thread.rollout_path,
                summary_label,
                prior_summary,
            },
        );
        if (start) |n| {
            try self.compact(notice, common.stringField(self.rows.items[n], "id"), timestamp);
        } else {
            var latest_user: ?Value = null;
            var latest_answer: ?Value = null;
            const newest_start = if (starts.items.len > 0) starts.items[starts.items.len - 1] else self.rows.items.len;
            for (self.rows.items[newest_start..], newest_start..) |row, row_index| {
                if (!format.is(row, "message")) {
                    continue;
                }
                const msg = common.get(row, "message");
                const role = common.stringField(msg, "role");
                if (common.eq(role, "user") and row_index == newest_start) {
                    latest_user = msg;
                } else if (common.eq(role, "assistant")) {
                    var has_text = false;
                    for (common.list(common.get(msg, "content"))) |part| {
                        if (format.is(part, "text") and common.stringField(part, "text").len > 0) {
                            has_text = true;
                        }
                    }
                    if (has_text) {
                        latest_answer = msg;
                    }
                }
            }
            try self.compact(notice, "", timestamp);
            for ([_]?Value{ latest_user, latest_answer }) |maybe| {
                const msg = maybe orelse continue;
                const text = try format.textOf(self.allocator, common.list(common.get(msg, "content")));
                const excerpt = try jsonExcerpt(self.allocator, text, 35_000);
                const suffix = if (text.len > excerpt.len)
                    "\n[c2c: excerpt shortened; full content remains in the transcript.]"
                else
                    "";
                const description = try common.fmt(self.allocator, "{s}{s}", .{ excerpt, suffix });
                const content = try common.obj(self.allocator, &.{
                    .{ "type", jsonString("text") },
                    .{ "text", jsonString(description) },
                });
                try self.message(common.stringField(msg, "role"), &.{content}, timestamp);
            }
        }
        if (try format.activeBytes(self.allocator, self.rows.items) > format.max_active_bytes) {
            return error.OmpContextBudgetExceeded;
        }
        try self.warnings.append(
            "Large source history retained in full; OMP active context uses a labelled recent window",
        );
    }
};

pub fn convert(allocator: Allocator, thread: common.Thread, entries: []const Value, opts: common.ConvertOptions) !common.Conversion {
    const provider = opts.source_provider orelse thread.provider;
    const source_id = opts.source_session_id orelse thread.id;
    const id = try common.sessionIdFor(allocator, "omp", provider, source_id);
    var builder = Builder{
        .allocator = allocator,
        .thread = thread,
        .opts = opts,
        .id = id,
        .rows = Values.init(allocator),
        .pending = std.array_list.Managed(Pending).init(allocator),
        .warnings = common.Warnings.init(allocator),
    };
    const created = try format.stamp(allocator, jsonString(thread.created_at), thread.updated_at);
    const header = try common.obj(allocator, &.{
        .{ "type", jsonString("session") },
        .{ "version", jsonInteger(3) },
        .{ "id", jsonString(id) },
        .{ "timestamp", jsonString(created) },
        .{ "cwd", jsonString(thread.cwd) },
        .{ "title", jsonString(thread.title) },
        .{ "titleSource", jsonString("user") },
    });
    try builder.rows.append(header);
    const origin = try common.obj(allocator, &.{
        .{ "version", jsonInteger(1) },
        .{ "sourceProvider", jsonString(provider) },
        .{ "sourceSessionId", jsonString(source_id) },
    });
    _ = try builder.append("custom", &.{
        .{ "customType", jsonString(format.provenance_type) },
        .{ "data", origin },
    }, created);
    var timestamp = created;
    var summary_pending = false;
    var source_count: usize = 0;
    for (entries) |entry| {
        if (common.eq(common.stringField(entry, "subtype"), "compact_boundary")) {
            try builder.flush(timestamp);
            summary_pending = true;
            continue;
        }
        const source_message = common.get(entry, "message");
        const role = format.fallback(common.stringField(source_message, "role"), common.stringField(entry, "type"));
        if (!common.eq(role, "user") and !common.eq(role, "assistant")) {
            continue;
        }
        source_count += 1;
        timestamp = try format.stamp(allocator, common.get(entry, "timestamp"), thread.updated_at);
        const input = try format.blocks(allocator, common.get(source_message, "content"));
        if (common.boolValue(common.get(entry, "isCompactSummary")) or (summary_pending and common.eq(role, "user"))) {
            try builder.flush(timestamp);
            const summary = try format.textOf(allocator, input);
            try builder.compact(summary, "", timestamp);
            summary_pending = false;
            builder.messages += 1;
            continue;
        }
        var has_result = false;
        for (input) |part| {
            if (format.is(part, "tool_result")) {
                has_result = true;
            }
        }
        if (common.eq(role, "user") and !has_result) {
            try builder.flush(timestamp);
        }
        var content = Values.init(allocator);
        for (input) |part| {
            if (format.is(part, "tool_use")) {
                if (!common.eq(role, "assistant")) {
                    return error.ToolCallOutsideAssistant;
                }
                const given = common.stringField(part, "id");
                const source_call_id = if (given.len > 0) given else try builder.next("missing-source-tool-id");
                for (builder.pending.items) |pending| {
                    if (common.eq(pending.source_id, source_call_id)) {
                        return error.DuplicatePendingToolId;
                    }
                }
                const call_id = try builder.next("call");
                const name = format.fallback(common.stringField(part, "name"), "historical_tool");
                try builder.pending.append(.{ .source_id = source_call_id, .id = call_id, .name = name });
                const args = common.get(part, "input");
                const arguments = if (args == .null) try common.obj(allocator, &.{}) else try common.clone(allocator, args);
                const call = try common.obj(allocator, &.{
                    .{ "type", jsonString("toolCall") },
                    .{ "id", jsonString(call_id) },
                    .{ "name", jsonString(name) },
                    .{ "arguments", arguments },
                });
                try content.append(call);
            } else if (format.is(part, "tool_result")) {
                try builder.message(role, content.items, timestamp);
                content.clearRetainingCapacity();
                try builder.result(
                    common.stringField(part, "tool_use_id"),
                    common.get(part, "content"),
                    timestamp,
                    common.boolValue(common.get(part, "is_error")),
                    false,
                );
            } else if (try builder.nativeContent(part)) |native| {
                try content.append(native);
            }
        }
        if (content.items.len > 0) {
            try builder.message(role, content.items, timestamp);
            builder.messages += 1;
        }
    }
    try builder.flush(timestamp);
    try builder.bounded(timestamp);
    var marker = builder.rows.items[1];
    var data = common.get(marker, "data");
    const fingerprint = try format.fingerprint(allocator, builder.rows.items);
    try common.set(allocator, &data, "fingerprint", jsonString(fingerprint));
    try common.set(allocator, &marker, "data", data);
    builder.rows.items[1] = marker;
    if ((try format.validate(allocator, builder.rows.items)).len > 0) {
        return error.InvalidOmpRollout;
    }
    return .{
        .entries = try builder.rows.toOwnedSlice(),
        .warnings = try builder.warnings.toOwnedSlice(),
        .message_count = builder.messages,
        .tool_count = builder.tools,
        .source_item_count = source_count,
        .session_id = id,
    };
}
