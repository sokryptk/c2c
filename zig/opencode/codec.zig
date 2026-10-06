const std = @import("std");
const common = @import("../common.zig");
const Allocator = common.Allocator;
const Value = common.Value;
const jsonString = common.str;
const jsonInteger = common.num;
const Values = std.array_list.Managed(Value);

const MAX_ACTIVE_BYTES: usize = 240_000;

pub const Origin = struct {
    provider: ?[]const u8 = null,
    original_id: ?[]const u8 = null,
    unchanged: bool = false,
};

pub fn sessionId(allocator: Allocator, source_provider: []const u8, source_id: []const u8) ![]const u8 {
    const id = try common.sessionIdFor(allocator, "opencode", source_provider, source_id);
    return common.fmt(allocator, "ses_{s}", .{id});
}

pub fn targetPath(allocator: Allocator, thread: common.Thread, home: []const u8) ![]const u8 {
    const id = try sessionId(allocator, thread.provider, thread.id);
    return receiptPath(allocator, home, id);
}

pub fn receiptPath(allocator: Allocator, home: []const u8, id: []const u8) ![]const u8 {
    if (!validId(id, "ses_")) {
        return error.InvalidOpenCodeSessionId;
    }
    const filename = try common.fmt(allocator, "{s}.json", .{id});
    return common.join(allocator, &.{ home, "c2c-imports", filename });
}

fn validId(value: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, value, prefix) or value.len <= prefix.len) {
        return false;
    }
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') {
            return false;
        }
    }
    return true;
}

fn textBlock(allocator: Allocator, value: []const u8) !Value {
    return common.obj(allocator, &.{
        .{ "type", jsonString("text") },
        .{ "text", jsonString(value) },
    });
}

fn blocks(allocator: Allocator, value: Value) ![]const Value {
    if (value == .string) {
        const text = try textBlock(allocator, value.string);
        return allocator.dupe(Value, &.{text});
    }
    return common.list(value);
}

fn zeroTokens(allocator: Allocator) !Value {
    const cache = try common.obj(allocator, &.{
        .{ "read", jsonInteger(0) },
        .{ "write", jsonInteger(0) },
    });
    return common.obj(allocator, &.{
        .{ "input", jsonInteger(0) },
        .{ "output", jsonInteger(0) },
        .{ "reasoning", jsonInteger(0) },
        .{ "cache", cache },
    });
}

fn model(allocator: Allocator) !Value {
    return common.obj(allocator, &.{
        .{ "providerID", jsonString("c2c") },
        .{ "id", jsonString("historical") },
    });
}

fn canonical(allocator: Allocator, value: Value) anyerror!Value {
    if (value == .array) {
        var out = Values.init(allocator);
        for (value.array.items) |child| {
            const item = try canonical(allocator, child);
            try out.append(item);
        }
        return common.arr(allocator, out.items);
    }
    if (value != .object) {
        return common.clone(allocator, value);
    }
    const keys = try allocator.alloc([]const u8, value.object.count());
    var it = value.object.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        keys[i] = entry.key_ptr.*;
    }
    std.mem.sort([]const u8, keys, {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.less);
    var out = try common.obj(allocator, &.{});
    for (keys) |key| {
        const child = try canonical(allocator, common.get(value, key));
        try common.set(allocator, &out, key, child);
    }
    return out;
}

fn stable(allocator: Allocator, data: Value, omit_fingerprint: bool) !Value {
    const info = common.get(data, "info");
    var metadata = try common.clone(allocator, common.get(info, "metadata"));
    if (omit_fingerprint and metadata == .object) {
        var marker = common.get(metadata, "c2c");
        if (marker == .object) {
            _ = marker.object.swapRemove("fingerprint");
            try common.set(allocator, &metadata, "c2c", marker);
        }
    }
    const snapshot = try common.obj(allocator, &.{
        .{ "id", common.get(info, "id") },
        .{ "title", common.get(info, "title") },
        .{ "location", common.get(info, "location") },
        .{ "metadata", metadata },
        .{ "messages", common.get(data, "messages") },
    });
    return canonical(allocator, snapshot);
}

pub fn fingerprint(allocator: Allocator, data: Value, omit_fingerprint: bool) ![]const u8 {
    const snapshot = try stable(allocator, data, omit_fingerprint);
    const encoded = try common.json(allocator, snapshot);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded, &digest, .{});
    return allocator.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

pub fn origin(allocator: Allocator, data: Value) !Origin {
    const info = common.get(data, "info");
    const metadata = common.get(info, "metadata");
    const marker = common.get(metadata, "c2c");
    const provider = common.stringField(marker, "sourceProvider");
    const id = common.stringField(marker, "sourceSessionId");
    if (provider.len == 0 or id.len == 0) {
        return .{};
    }
    const current_fingerprint = try fingerprint(allocator, data, true);
    return .{
        .provider = provider,
        .original_id = id,
        .unchanged = common.eq(common.stringField(marker, "fingerprint"), current_fingerprint),
    };
}

const Encoder = struct {
    allocator: Allocator,
    sid: []const u8,
    messages: Values,
    warnings: common.Warnings,
    count: usize = 0,
    tools: usize = 0,
    source_count: usize = 0,
    pending: std.StringHashMap(Value),

    fn nextId(self: *Encoder) ![]const u8 {
        self.count += 1;
        const count = try common.fmt(self.allocator, "{d}", .{self.count});
        const id = try common.sessionIdFor(self.allocator, "opencode-message", self.sid, count);
        return common.fmt(self.allocator, "msg_{s}", .{id});
    }

    fn base(self: *Encoder, kind: []const u8, timestamp: i64) !Value {
        const id = try self.nextId();
        const time = try common.obj(self.allocator, &.{.{ "created", jsonInteger(timestamp) }});
        return common.obj(self.allocator, &.{
            .{ "id", jsonString(id) },
            .{ "type", jsonString(kind) },
            .{ "time", time },
        });
    }

    fn plain(self: *Encoder, role: []const u8, content: []const Value, timestamp: i64, embed: bool) !void {
        var message = try self.base(role, timestamp);
        var text = std.array_list.Managed([]const u8).init(self.allocator);
        var files = Values.init(self.allocator);
        var assistant = Values.init(self.allocator);
        for (content) |block| {
            const kind = common.stringField(block, "type");
            if (common.eq(kind, "text")) {
                const value = common.stringField(block, "text");
                if (common.eq(role, "user")) {
                    try text.append(value);
                } else {
                    const part = try textBlock(self.allocator, value);
                    try assistant.append(part);
                }
            } else if (common.eq(kind, "image")) {
                const source = common.get(block, "source");
                if (embed and common.eq(common.stringField(source, "type"), "base64") and common.eq(role, "user")) {
                    const inline_source = try common.obj(self.allocator, &.{.{ "type", jsonString("inline") }});
                    const file = try common.obj(self.allocator, &.{
                        .{ "data", common.get(source, "data") },
                        .{ "mime", common.get(source, "media_type") },
                        .{ "source", inline_source },
                    });
                    try files.append(file);
                } else {
                    const detail = if (embed)
                        try common.fmt(self.allocator, "[Historical image attachment]\n{s}", .{try common.json(self.allocator, block)})
                    else
                        "[Image bytes retained in the original conversation.]";
                    if (common.eq(role, "user")) {
                        try text.append(detail);
                    } else {
                        const part = try textBlock(self.allocator, detail);
                        try assistant.append(part);
                    }
                }
            } else if (common.eq(kind, "tool_use") and common.eq(role, "assistant")) {
                const call_id = common.stringField(block, "id");
                if (self.pending.contains(call_id)) {
                    return error.DuplicatePendingToolCall;
                }
                const missing_result = try common.obj(self.allocator, &.{
                    .{ "type", jsonString("historical") },
                    .{ "message", jsonString("No saved result; c2c did not execute this historical tool.") },
                });
                const state = try common.obj(self.allocator, &.{
                    .{ "status", jsonString("error") },
                    .{ "input", common.get(block, "input") },
                    .{ "error", missing_result },
                });
                const time = try common.obj(self.allocator, &.{
                    .{ "created", jsonInteger(timestamp) },
                    .{ "completed", jsonInteger(timestamp) },
                });
                const tool = try common.obj(self.allocator, &.{
                    .{ "type", jsonString("tool") },
                    .{ "id", jsonString(call_id) },
                    .{ "name", common.get(block, "name") },
                    .{ "state", state },
                    .{ "time", time },
                });
                try assistant.append(tool);
                try self.pending.put(call_id, tool);
                self.tools += 1;
            } else if (!common.eq(kind, "tool_result") and !common.eq(kind, "thinking") and !common.eq(kind, "redacted_thinking")) {
                const encoded = try common.json(self.allocator, block);
                const detail = try common.fmt(self.allocator, "[Historical attachment]\n{s}", .{encoded});
                if (common.eq(role, "user")) {
                    try text.append(detail);
                } else {
                    const part = try textBlock(self.allocator, detail);
                    try assistant.append(part);
                }
            }
        }
        if (common.eq(role, "user")) {
            if (text.items.len == 0 and files.items.len == 0) {
                return;
            }
            const combined_text = try std.mem.join(self.allocator, "\n", text.items);
            try common.set(self.allocator, &message, "text", jsonString(combined_text));
            if (files.items.len > 0) {
                try common.set(self.allocator, &message, "files", try common.arr(self.allocator, files.items));
            }
        } else {
            if (assistant.items.len == 0) {
                return;
            }
            try common.set(self.allocator, &message, "agent", jsonString("build"));
            try common.set(self.allocator, &message, "model", try model(self.allocator));
            try common.set(self.allocator, &message, "content", try common.arr(self.allocator, assistant.items));
            try common.set(self.allocator, &message, "finish", jsonString("stop"));
            var time = common.get(message, "time");
            try common.set(self.allocator, &time, "completed", jsonInteger(timestamp));
            try common.set(self.allocator, &message, "time", time);
        }
        try self.messages.append(message);
    }

    fn result(self: *Encoder, block: Value, timestamp: i64, embed: bool) !void {
        const saved = self.pending.fetchRemove(common.stringField(block, "tool_use_id"));
        if (saved == null) {
            const encoded = try common.json(self.allocator, block);
            const detail = try common.fmt(self.allocator, "[Unpaired historical tool result]\n{s}", .{encoded});
            const text = try textBlock(self.allocator, detail);
            try self.plain("assistant", &.{text}, timestamp, embed);
            try self.warnings.append("Unpaired tool result preserved as an explicit transcript artifact");
            return;
        }
        var tool = saved.?.value;
        var content = Values.init(self.allocator);
        for (try blocks(self.allocator, common.get(block, "content"))) |part| {
            const kind = common.stringField(part, "type");
            const source = common.get(part, "source");
            if (common.eq(kind, "text")) {
                const text = try textBlock(self.allocator, common.stringField(part, "text"));
                try content.append(text);
            } else if (embed and common.eq(kind, "image") and common.eq(common.stringField(source, "type"), "base64")) {
                const uri = try common.fmt(self.allocator, "data:{s};base64,{s}", .{
                    common.stringField(source, "media_type"),
                    common.stringField(source, "data"),
                });
                const file = try common.obj(self.allocator, &.{
                    .{ "type", jsonString("file") },
                    .{ "mime", common.get(source, "media_type") },
                    .{ "uri", jsonString(uri) },
                });
                try content.append(file);
            } else {
                const detail = if (embed)
                    try common.json(self.allocator, part)
                else
                    "[Attachment retained in original conversation.]";
                const text = try textBlock(self.allocator, detail);
                try content.append(text);
            }
        }
        if (content.items.len == 0) {
            const text = try textBlock(self.allocator, "");
            try content.append(text);
        }
        const is_error = common.boolValue(common.get(block, "is_error"));
        const previous_state = common.get(tool, "state");
        var state = try common.obj(self.allocator, &.{
            .{ "status", jsonString(if (is_error) "error" else "completed") },
            .{ "input", common.get(previous_state, "input") },
            .{ "content", try common.arr(self.allocator, content.items) },
        });
        if (is_error) {
            const historical_error = try common.obj(self.allocator, &.{
                .{ "type", jsonString("historical") },
                .{ "message", jsonString("Historical tool returned an error; see its saved output.") },
            });
            try common.set(self.allocator, &state, "error", historical_error);
        }
        // Object backing storage is shared with the already appended assistant.
        try common.set(self.allocator, &tool, "state", state);
    }
};

pub fn convert(allocator: Allocator, thread: common.Thread, entries: []const Value, opts: common.ConvertOptions) !common.Conversion {
    const provider = opts.source_provider orelse thread.provider;
    const original_id = opts.source_session_id orelse thread.id;
    const sid = try sessionId(allocator, provider, original_id);
    var encoder = Encoder{
        .allocator = allocator,
        .sid = sid,
        .messages = Values.init(allocator),
        .warnings = common.Warnings.init(allocator),
        .pending = std.StringHashMap(Value).init(allocator),
    };
    var boundary = false;
    for (entries) |entry| {
        if (common.eq(common.stringField(entry, "subtype"), "compact_boundary")) {
            boundary = true;
            continue;
        }
        const role = common.stringField(entry, "type");
        if (!common.eq(role, "user") and !common.eq(role, "assistant")) {
            continue;
        }
        encoder.source_count += 1;
        const timestamp = common.timestampMillis(common.stringField(entry, "timestamp")) catch
            try common.timestampMillis(thread.updated_at);
        const message = common.get(entry, "message");
        const content = try blocks(allocator, common.get(message, "content"));
        if ((boundary or common.boolValue(common.get(entry, "isCompactSummary"))) and common.eq(role, "user")) {
            var strings = std.array_list.Managed([]const u8).init(allocator);
            for (content) |block| {
                if (common.eq(common.stringField(block, "type"), "text")) {
                    try strings.append(common.stringField(block, "text"));
                }
            }
            var checkpoint = try encoder.base("compaction", timestamp);
            try common.set(allocator, &checkpoint, "status", jsonString("completed"));
            try common.set(allocator, &checkpoint, "reason", jsonString("manual"));
            try common.set(allocator, &checkpoint, "summary", jsonString(try std.mem.join(allocator, "\n", strings.items)));
            try common.set(allocator, &checkpoint, "recent", jsonString(""));
            try encoder.messages.append(checkpoint);
            boundary = false;
        } else {
            for (content) |block| {
                if (common.eq(common.stringField(block, "type"), "tool_result")) {
                    try encoder.result(block, timestamp, opts.embed_images);
                }
            }
            try encoder.plain(role, content, timestamp, opts.embed_images);
        }
    }
    if (encoder.pending.count() > 0) {
        try encoder.warnings.append(
            "Incomplete historical calls retained as completed error records without execution",
        );
    }
    if (encoder.messages.items.len == 0) {
        return .{ .entries = &.{}, .session_id = sid };
    }
    var active_start: usize = 0;
    for (encoder.messages.items, 0..) |message, index| {
        if (common.eq(common.stringField(message, "type"), "compaction")) {
            active_start = index;
        }
    }
    const active = encoder.messages.items[active_start..];
    const active_messages = try common.arr(allocator, active);
    const active_json = try common.json(allocator, active_messages);
    if (active_json.len > MAX_ACTIVE_BYTES) {
        var selected = Values.init(allocator);
        var size: usize = 0;
        var i = active.len;
        while (i > 0) {
            i -= 1;
            const encoded = try common.json(allocator, active[i]);
            var value = active[i];
            if (encoded.len > 24_000) {
                var head: usize = 4000;
                while (head > 0 and !std.unicode.utf8ValidateSlice(encoded[0..head])) {
                    head -= 1;
                }
                var tail = encoded.len - 8000;
                while (tail < encoded.len and !std.unicode.utf8ValidateSlice(encoded[tail..])) {
                    tail += 1;
                }
                const excerpt = try common.fmt(
                    allocator,
                    "{s}\n[...c2c excerpt; complete original remains in native session...]\n{s}",
                    .{ encoded[0..head], encoded[tail..] },
                );
                value = try common.obj(allocator, &.{
                    .{ "type", jsonString("historical-excerpt") },
                    .{ "originalMessageID", common.get(active[i], "id") },
                    .{ "text", jsonString(excerpt) },
                });
            }
            const amount = (try common.json(allocator, value)).len;
            if (size + amount > 165_000) {
                break;
            }
            try selected.append(value);
            size += amount;
        }
        std.mem.reverse(Value, selected.items);
        var checkpoint = try encoder.base("compaction", try common.timestampMillis(thread.updated_at));
        try common.set(allocator, &checkpoint, "status", jsonString("completed"));
        try common.set(allocator, &checkpoint, "reason", jsonString("manual"));
        const summary = try common.fmt(
            allocator,
            "c2c restored an extractive continuation window. " ++
                "Full visible history and exact attachments remain in this native OpenCode session. " ++
                "Earlier details can be retrieved by exporting session {s}. " ++
                "This is not a semantic summary; never re-execute historical tools. Archive receipt: {s}",
            .{ sid, opts.transcript_path orelse "the c2c import receipt" },
        );
        try common.set(allocator, &checkpoint, "summary", jsonString(summary));
        // recent contains JSON encoded as a string; budget for both escaping layers.
        while (true) {
            const selected_messages = try common.arr(allocator, selected.items);
            const recent = try common.json(allocator, selected_messages);
            try common.set(allocator, &checkpoint, "recent", jsonString(recent));
            if ((try common.json(allocator, checkpoint)).len <= MAX_ACTIVE_BYTES - 2000) {
                break;
            }
            if (selected.items.len > 1) {
                _ = selected.orderedRemove(0);
                continue;
            }
            // Long receipt paths can exhaust the context budget.
            try common.set(allocator, &checkpoint, "summary", jsonString(
                "c2c restored an extractive continuation window. " ++
                    "Full history remains in this native session; use native session export to retrieve it. " ++
                    "Do not re-execute historical tools.",
            ));
            if ((try common.json(allocator, checkpoint)).len <= MAX_ACTIVE_BYTES - 2000) {
                break;
            }
            return error.OpenCodeCheckpointBudgetExceeded;
        }
        try encoder.messages.append(checkpoint);
        try encoder.warnings.append(
            "Large OpenCode history preserved in full; active context uses a labelled extractive window",
        );
    }
    const marker = try common.obj(allocator, &.{
        .{ "schemaVersion", jsonInteger(1) },
        .{ "sourceProvider", jsonString(provider) },
        .{ "sourceSessionId", jsonString(original_id) },
    });
    const location = try common.obj(allocator, &.{.{ "directory", jsonString(thread.cwd) }});
    const tokens = try zeroTokens(allocator);
    const time = try common.obj(allocator, &.{
        .{ "created", jsonInteger(try common.timestampMillis(thread.created_at)) },
        .{ "updated", jsonInteger(try common.timestampMillis(thread.updated_at)) },
    });
    const metadata = try common.obj(allocator, &.{.{ "c2c", marker }});
    var info = try common.obj(allocator, &.{
        .{ "id", jsonString(sid) },
        .{ "projectID", jsonString("global") },
        .{ "title", jsonString(thread.title) },
        .{ "location", location },
        .{ "cost", jsonInteger(0) },
        .{ "tokens", tokens },
        .{ "time", time },
        .{ "metadata", metadata },
    });
    var data = try common.obj(allocator, &.{
        .{ "info", info },
        .{ "messages", try common.arr(allocator, encoder.messages.items) },
    });
    var annotated = marker;
    const data_fingerprint = try fingerprint(allocator, data, true);
    try common.set(allocator, &annotated, "fingerprint", jsonString(data_fingerprint));
    const annotated_metadata = try common.obj(allocator, &.{.{ "c2c", annotated }});
    try common.set(allocator, &info, "metadata", annotated_metadata);
    try common.set(allocator, &data, "info", info);
    const output = try allocator.dupe(Value, &.{data});
    if ((try validate(allocator, output)).len > 0) {
        return error.InvalidOpenCodeTransfer;
    }
    return .{
        .entries = output,
        .session_id = sid,
        .message_count = encoder.messages.items.len,
        .tool_count = encoder.tools,
        .source_item_count = encoder.source_count,
        .warnings = try encoder.warnings.toOwnedSlice(),
    };
}

pub fn validate(allocator: Allocator, entries: []const Value) ![][]const u8 {
    var errors = common.Warnings.init(allocator);
    if (entries.len != 1 or common.get(entries[0], "info") != .object or common.get(entries[0], "messages") != .array) {
        try errors.append("OpenCode transfer must be one object with info and messages");
        return errors.toOwnedSlice();
    }
    const info = common.get(entries[0], "info");
    const messages = common.get(entries[0], "messages");
    if (!validId(common.stringField(info, "id"), "ses_")) {
        try errors.append("Invalid OpenCode session ID");
    }
    var ids = std.StringHashMap(void).init(allocator);
    defer ids.deinit();
    for (common.list(messages)) |message| {
        const id = common.stringField(message, "id");
        if (!validId(id, "msg_") or ids.contains(id)) {
            try errors.append("Invalid or duplicate OpenCode message ID");
        }
        try ids.put(id, {});
        const time = common.get(message, "time");
        if (common.eq(common.stringField(message, "type"), "assistant") and common.get(time, "completed") == .null) {
            try errors.append("Imported assistant must be settled so native import cannot silently discard it");
        }
    }
    if (ids.count() == 0) {
        try errors.append("OpenCode transfer has no messages");
    }
    return errors.toOwnedSlice();
}

pub fn registrationMatches(allocator: Allocator, staged: []const Value, native: Value) !bool {
    if (staged.len != 1) {
        return false;
    }
    const staged_fingerprint = try fingerprint(allocator, staged[0], false);
    const native_fingerprint = try fingerprint(allocator, native, false);
    return common.eq(staged_fingerprint, native_fingerprint);
}
