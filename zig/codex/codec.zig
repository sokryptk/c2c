const std = @import("std");
const common = @import("../common.zig");
const format = @import("format.zig");
const Value = common.Value;
const Allocator = common.Allocator;
const jsonString = common.str;
const jsonInteger = common.num;
const namespace = "b18998c2-4d26-40bd-9c20-2dd493c3a146";
const max_active_bytes = 240_000;
const recent_bytes = 170_000;

pub const format_version = format.format_version;
pub const sessionId = format.sessionId;
pub const targetPath = format.targetPath;
pub const targetPathFor = format.targetPathFor;
pub const validate = format.validate;
pub const registrationMatches = format.registrationMatches;
pub const Origin = format.Origin;
pub const readOrigin = format.readOrigin;

fn is(v: Value, kind: []const u8) bool {
    return common.eq(common.stringField(v, "type"), kind);
}

fn blocks(allocator: Allocator, v: Value) ![]const Value {
    if (v != .string) {
        return common.list(v);
    }
    if (v.string.len == 0) {
        return &.{};
    }
    const text = try common.obj(allocator, &.{ .{ "type", jsonString("text") }, .{ "text", v } });
    return common.list(try common.arr(allocator, &.{text}));
}

fn uri(allocator: Allocator, path: []const u8) ![]const u8 {
    if (path.len == 0 or path[0] != '/') {
        return error.AbsoluteWorkingDirectoryRequired;
    }
    var out = std.array_list.Managed(u8).init(allocator);
    try out.appendSlice("file://");
    const hex = "0123456789ABCDEF";
    for (path) |ch| {
        if (std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "/-_.~", ch) != null) {
            try out.append(ch);
        } else {
            try out.appendSlice(&.{ '%', hex[ch >> 4], hex[ch & 15] });
        }
    }
    return out.toOwnedSlice();
}

const Content = struct {
    model: []const Value,
    view: []const Value,
};
const Pending = struct {
    source_id: []const u8,
    id: []const u8,
    name: []const u8,
    input: Value,
    started: i64,
};
const Builder = struct {
    allocator: Allocator,
    thread: common.Thread,
    opts: common.ConvertOptions,
    id: []const u8,
    rows: std.array_list.Managed(Value),
    warnings: common.Warnings,
    active: std.array_list.Managed(Value),
    active_starts: std.array_list.Managed(usize),
    pending: std.array_list.Managed(Pending),
    counter: usize = 0,
    turn: ?[]const u8 = null,
    started: []const u8,
    last_answer: []const u8 = "",
    messages: usize = 0,
    tools: usize = 0,
    source_count: usize = 0,

    fn next(self: *Builder, label: []const u8) ![]const u8 {
        self.counter += 1;
        return common.uuid5(
            self.allocator,
            namespace,
            try common.fmt(self.allocator, "{s}:{s}:{d}", .{ self.id, label, self.counter }),
        );
    }
    fn add(self: *Builder, kind: []const u8, payload: Value, timestamp: []const u8) !void {
        const row = try common.obj(self.allocator, &.{
            .{ "timestamp", jsonString(timestamp) },
            .{ "type", jsonString(kind) },
            .{ "payload", payload },
        });
        try self.rows.append(row);
    }
    fn response(self: *Builder, payload: Value, timestamp: []const u8) !void {
        try self.add("response_item", payload, timestamp);
        try self.active.append(payload);
    }
    fn begin(self: *Builder, timestamp: []const u8) anyerror!void {
        if (self.turn != null) {
            return;
        }
        const starts = self.active_starts.items;
        if (starts.len == 0 or starts[starts.len - 1] != self.active.items.len) {
            try self.active_starts.append(self.active.items.len);
        }
        self.turn = try self.next("turn");
        self.started = timestamp;
        self.last_answer = "";
        try self.add(
            "event_msg",
            try common.obj(self.allocator, &.{
                .{ "type", jsonString("task_started") },
                .{ "turn_id", jsonString(self.turn.?) },
                .{ "started_at", jsonInteger(try common.timestampMillis(timestamp)) },
                .{ "model_context_window", .null },
                .{ "collaboration_mode_kind", jsonString("default") },
            }),
            timestamp,
        );
    }
    fn display(self: *Builder, item: Value, timestamp: []const u8) anyerror!void {
        try self.begin(timestamp);
        const ms = try common.timestampMillis(timestamp);
        try self.add(
            "event_msg",
            try common.obj(self.allocator, &.{
                .{ "type", jsonString("item_completed") },
                .{ "thread_id", jsonString(self.id) },
                .{ "turn_id", jsonString(self.turn.?) },
                .{ "item", item },
                .{ "started_at_ms", jsonInteger(ms) },
                .{ "completed_at_ms", jsonInteger(ms) },
            }),
            timestamp,
        );
    }
    fn complete(self: *Builder, timestamp: []const u8) anyerror!void {
        if (self.turn == null) {
            return;
        }
        while (self.pending.items.len > 0) {
            const id = self.pending.items[0].source_id;
            try self.output(
                id,
                jsonString("This historical source tool call had no saved result. c2c did not execute it."),
                timestamp,
                false,
                true,
            );
            try self.warnings.append("Incomplete historical tool call closed without execution");
        }
        const start_ms = try common.timestampMillis(self.started);
        const end_ms = try common.timestampMillis(timestamp);
        try self.add(
            "event_msg",
            try common.obj(self.allocator, &.{
                .{ "type", jsonString("task_complete") },
                .{ "turn_id", jsonString(self.turn.?) },
                .{
                    "last_agent_message",
                    if (self.last_answer.len > 0) jsonString(self.last_answer) else .null,
                },
                .{ "started_at", jsonInteger(start_ms) },
                .{ "completed_at", jsonInteger(end_ms) },
                .{ "duration_ms", jsonInteger(@max(0, end_ms - start_ms)) },
            }),
            timestamp,
        );
        self.turn = null;
    }
    fn content(self: *Builder, input: []const Value, role: []const u8) !Content {
        var model = std.array_list.Managed(Value).init(self.allocator);
        var view = std.array_list.Managed(Value).init(self.allocator);
        const user = common.eq(role, "user");
        for (input) |block| {
            if (is(block, "thinking") or is(block, "redacted_thinking") or
                is(block, "tool_use") or is(block, "tool_result"))
            {
                continue;
            }
            var text: []const u8 = "";
            if (is(block, "text")) {
                text = common.stringField(block, "text");
            } else if (is(block, "image")) {
                const source = common.get(block, "source");
                var url = common.stringField(source, "url");
                if (is(source, "base64") and self.opts.embed_images) {
                    const encoded = common.stringField(source, "data");
                    const mime = common.stringField(source, "media_type");
                    const decoder = std.base64.standard.Decoder;
                    if (decoder.calcSizeForSlice(encoded)) |length| {
                        const decoded = try self.allocator.alloc(u8, length);
                        if (decoder.decode(decoded, encoded)) |_| {
                            if (std.mem.startsWith(u8, mime, "image/")) {
                                url = try common.fmt(self.allocator, "data:{s};base64,{s}", .{ mime, encoded });
                            }
                        } else |_| {
                            try self.warnings.append("Invalid Source image base64; preserved attachment metadata");
                        }
                    } else |_| {
                        try self.warnings.append("Invalid Source image base64; preserved attachment metadata");
                    }
                }
                if (url.len > 0 and user) {
                    const model_image = try common.obj(self.allocator, &.{
                        .{ "type", jsonString("input_image") },
                        .{ "image_url", jsonString(url) },
                    });
                    try model.append(model_image);
                    const visible_image = try common.obj(self.allocator, &.{
                        .{ "type", jsonString("image") },
                        .{ "image_url", jsonString(url) },
                    });
                    try view.append(visible_image);
                    continue;
                }
                if (is(source, "url")) {
                    text = try common.fmt(self.allocator, "[Source image attachment] {s}", .{url});
                } else if (!self.opts.embed_images) {
                    text = "[Source image attachment; bytes remain in the original transcript]";
                } else {
                    text = "[Source image attachment]";
                }
            } else {
                const attachment_json = try common.json(self.allocator, block);
                text = try common.fmt(self.allocator, "[Source attachment]\n{s}", .{attachment_json});
                try self.warnings.append(try common.fmt(
                    self.allocator,
                    "Source content type '{s}' preserved as text",
                    .{common.stringField(block, "type")},
                ));
            }
            if (text.len == 0) {
                continue;
            }
            const model_text = try common.obj(self.allocator, &.{
                .{ "type", jsonString(if (user) "input_text" else "output_text") },
                .{ "text", jsonString(text) },
            });
            try model.append(model_text);
            var visible = try common.obj(self.allocator, &.{
                .{ "type", jsonString(if (user) "text" else "Text") },
                .{ "text", jsonString(text) },
            });
            if (user) {
                try common.set(self.allocator, &visible, "text_elements", try common.arr(self.allocator, &.{}));
            }
            try view.append(visible);
        }
        return .{ .model = try model.toOwnedSlice(), .view = try view.toOwnedSlice() };
    }
    fn textOf(self: *Builder, input: []const Value, image_notice: bool) ![]const u8 {
        var texts = std.array_list.Managed([]const u8).init(self.allocator);
        for (input) |block| {
            const text = common.stringField(block, "text");
            if (text.len > 0) {
                try texts.append(text);
            } else if (image_notice) {
                try texts.append("[Image attachment preserved in tool result]");
            }
        }
        return std.mem.join(self.allocator, "\n", texts.items);
    }
    fn message(
        self: *Builder,
        role: []const u8,
        input: []const Value,
        timestamp: []const u8,
        summary: bool,
    ) anyerror!void {
        const parts = try self.content(input, role);
        if (parts.model.len == 0) {
            return;
        }
        const id = try self.next("message");
        const user = common.eq(role, "user");
        var payload = try common.obj(self.allocator, &.{
            .{ "type", jsonString("message") },
            .{ "id", jsonString(id) },
            .{ "role", jsonString(role) },
            .{ "content", try common.arr(self.allocator, parts.model) },
        });
        if (!user) {
            try common.set(self.allocator, &payload, "phase", jsonString("final_answer"));
            self.last_answer = try self.textOf(parts.model, false);
        }
        if (summary) {
            try self.complete(timestamp);
            try self.add(
                "compacted",
                try common.obj(self.allocator, &.{
                    .{ "message", jsonString(try self.textOf(parts.model, false)) },
                    .{ "replacement_history", try common.arr(self.allocator, &.{payload}) },
                    .{ "compaction_response_id", .null },
                    .{ "latest_token_usage_record", .null },
                }),
                timestamp,
            );
            self.active.clearRetainingCapacity();
            self.active_starts.clearRetainingCapacity();
            try self.active_starts.append(0);
            try self.active.append(payload);
        } else {
            try self.begin(timestamp);
            try self.response(payload, timestamp);
        }
        var visible = try common.obj(self.allocator, &.{
            .{ "type", jsonString(if (user) "UserMessage" else "AgentMessage") },
            .{ "id", jsonString(id) },
            .{ "content", try common.arr(self.allocator, parts.view) },
        });
        if (!user) {
            try common.set(self.allocator, &visible, "phase", jsonString("final_answer"));
        }
        try self.display(visible, timestamp);
        self.messages += 1;
    }
    fn output(
        self: *Builder,
        call_id: []const u8,
        raw: Value,
        timestamp: []const u8,
        failed: bool,
        missing: bool,
    ) anyerror!void {
        var index: ?usize = null;
        for (self.pending.items, 0..) |pending, i| {
            if (common.eq(pending.source_id, call_id)) {
                index = i;
                break;
            }
        }
        if (index == null) {
            const artifact = try common.fmt(
                self.allocator,
                "[Unpaired historical source tool result]\n{s}",
                .{try common.json(self.allocator, raw)},
            );
            try self.message(
                "assistant",
                try blocks(self.allocator, jsonString(artifact)),
                timestamp,
                false,
            );
            try self.warnings.append("Unpaired source tool result preserved as a visible artifact");
            return;
        }
        const saved = self.pending.orderedRemove(index.?);
        const parts = try self.content(try blocks(self.allocator, raw), "user");
        var native_output = if (raw == .string) raw else try common.arr(self.allocator, parts.model);
        if (failed) {
            const notice = "[The source marked this historical tool result as an error.]";
            if (native_output == .string) {
                const error_text = try common.fmt(self.allocator, "{s}\n{s}", .{ notice, native_output.string });
                native_output = jsonString(error_text);
            } else {
                var augmented = std.array_list.Managed(Value).init(self.allocator);
                const error_notice = try common.obj(self.allocator, &.{
                    .{ "type", jsonString("input_text") },
                    .{ "text", jsonString(notice) },
                });
                try augmented.append(error_notice);
                try augmented.appendSlice(parts.model);
                native_output = try common.arr(self.allocator, augmented.items);
            }
        }
        const formatted = try self.textOf(parts.model, true);
        try self.response(
            try common.obj(self.allocator, &.{
                .{ "type", jsonString("function_call_output") },
                .{ "call_id", jsonString(saved.id) },
                .{ "output", native_output },
            }),
            timestamp,
        );
        const command = common.stringField(saved.input, "command");
        if (common.eq(saved.name, "Bash") and command.len > 0) {
            const elapsed = @max(0, (try common.timestampMillis(timestamp)) - saved.started);
            try self.display(
                try common.obj(self.allocator, &.{
                    .{ "type", jsonString("CommandExecution") },
                    .{ "id", jsonString(saved.id) },
                    .{
                        "command",
                        try common.arr(self.allocator, &.{
                            jsonString("bash"),
                            jsonString("-lc"),
                            jsonString(command),
                        }),
                    },
                    .{ "cwd", jsonString(try uri(self.allocator, self.thread.cwd)) },
                    .{ "parsed_cmd", try common.arr(self.allocator, &.{}) },
                    .{ "source", jsonString("unified_exec_startup") },
                    .{ "status", jsonString(if (failed or missing) "failed" else "completed") },
                    .{ "stdout", jsonString(formatted) },
                    .{ "stderr", jsonString("") },
                    .{ "aggregated_output", jsonString(formatted) },
                    .{
                        "duration",
                        try common.obj(self.allocator, &.{
                            .{ "secs", jsonInteger(@divTrunc(elapsed, 1000)) },
                            .{ "nanos", jsonInteger(@mod(elapsed, 1000) * 1_000_000) },
                        }),
                    },
                    .{ "formatted_output", jsonString(formatted) },
                }),
                timestamp,
            );
        } else {
            const artifact = try common.fmt(
                self.allocator,
                "[Historical source tool: {s}]\nInput:\n{s}\nResult:\n{s}",
                .{ saved.name, try common.json(self.allocator, saved.input), formatted },
            );
            const display_id = try self.next("tool-display");
            const display_text = try common.obj(self.allocator, &.{
                .{ "type", jsonString("Text") },
                .{ "text", jsonString(artifact) },
            });
            const display_content = try common.arr(self.allocator, &.{display_text});
            try self.display(
                try common.obj(self.allocator, &.{
                    .{ "type", jsonString("AgentMessage") },
                    .{ "id", jsonString(display_id) },
                    .{ "content", display_content },
                    .{ "phase", jsonString("final_answer") },
                }),
                timestamp,
            );
        }
        self.tools += 1;
    }
    fn excerpt(self: *Builder, item: Value) !Value {
        if ((try common.json(self.allocator, item)).len <= 40_000) {
            return item;
        }
        const text = try self.textOf(common.list(common.get(item, "content")), true);
        var shortened = text;
        if (text.len > 30_000) {
            var start: usize = 15_000;
            while (start > 0 and (text[start] & 0xc0) == 0x80) : (start -= 1) {}
            var end = text.len - 15_000;
            while (end < text.len and (text[end] & 0xc0) == 0x80) : (end += 1) {}
            shortened = try common.fmt(
                self.allocator,
                "{s}\n[c2c: excerpt shortened; full text remains in the transcript.]\n{s}",
                .{ text[0..start], text[end..] },
            );
        }
        var bounded = try common.clone(self.allocator, item);
        const content_type = if (common.eq(common.stringField(item, "role"), "user")) "input_text" else "output_text";
        const excerpt_text = try common.obj(self.allocator, &.{
            .{ "type", jsonString(content_type) },
            .{ "text", jsonString(shortened) },
        });
        const excerpt_content = try common.arr(self.allocator, &.{excerpt_text});
        try common.set(self.allocator, &bounded, "content", excerpt_content);
        return bounded;
    }
    fn boundContext(self: *Builder, timestamp: []const u8) !void {
        const active_history = try common.arr(self.allocator, self.active.items);
        const active_json = try common.json(self.allocator, active_history);
        if (active_json.len <= max_active_bytes) {
            return;
        }
        const starts = self.active_starts;
        var selected = std.array_list.Managed(Value).init(self.allocator);
        var size: usize = 0;
        var end = self.active.items.len;
        var cursor = starts.items.len;
        while (cursor > 0) {
            cursor -= 1;
            const start = starts.items[cursor];
            const group = self.active.items[start..end];
            const group_history = try common.arr(self.allocator, group);
            const group_json = try common.json(self.allocator, group_history);
            const length = group_json.len;
            if (size + length > recent_bytes) {
                if (selected.items.len == 0) {
                    var messages = std.array_list.Managed(Value).init(self.allocator);
                    for (group) |entry| {
                        if (is(entry, "message")) {
                            try messages.append(entry);
                        }
                    }
                    var initial: ?Value = null;
                    if (messages.items.len > 0 and common.eq(common.stringField(messages.items[0], "role"), "user")) {
                        initial = try self.excerpt(messages.items[0]);
                    }
                    size = if (initial) |v| (try common.json(self.allocator, v)).len else 0;
                    var n = messages.items.len;
                    const lower: usize = if (initial != null) 1 else 0;
                    while (n > lower) {
                        n -= 1;
                        const bounded = try self.excerpt(messages.items[n]);
                        const bytes = (try common.json(self.allocator, bounded)).len;
                        if (size + bytes > recent_bytes) {
                            break;
                        }
                        try selected.insert(0, bounded);
                        size += bytes;
                    }
                    if (initial) |v| {
                        try selected.insert(0, v);
                    }
                }
                break;
            }
            try selected.insertSlice(0, group);
            size += length;
            end = start;
        }
        const notice = try common.fmt(
            self.allocator,
            "c2c restored a recent context window from this source conversation. " ++
                "Earlier messages and tool outputs remain in the full native transcript. " ++
                "This is an extractive window, not a semantic summary. " ++
                "Read the transcript when earlier decisions or exact details are needed.\n" ++
                "Full native transcript: {s}\nOriginal source transcript: {s}",
            .{
                self.opts.transcript_path orelse "[the current session rollout]",
                self.thread.rollout_path,
            },
        );
        const summary_text = try common.obj(self.allocator, &.{
            .{ "type", jsonString("input_text") },
            .{ "text", jsonString(notice) },
        });
        const summary_content = try common.arr(self.allocator, &.{summary_text});
        const summary = try common.obj(self.allocator, &.{
            .{ "type", jsonString("message") },
            .{ "role", jsonString("user") },
            .{ "content", summary_content },
        });
        try selected.insert(0, summary);
        try self.add(
            "compacted",
            try common.obj(self.allocator, &.{
                .{ "message", jsonString(notice) },
                .{ "replacement_history", try common.arr(self.allocator, selected.items) },
                .{ "compaction_response_id", .null },
                .{ "latest_token_usage_record", .null },
            }),
            timestamp,
        );
        try self.warnings.append("Large source history retained in full; active context uses a labelled recent window");
    }
};

pub fn convert(
    allocator: Allocator,
    thread: common.Thread,
    entries: []const Value,
    opts: common.ConvertOptions,
) !common.Conversion {
    const provider = opts.source_provider orelse "claude";
    const original_id = opts.source_session_id orelse thread.id;
    if (!format.supportedProvider(provider)) {
        return error.UnsupportedSourceProvider;
    }
    var self = Builder{
        .allocator = allocator,
        .thread = thread,
        .opts = opts,
        .id = try common.sessionIdFor(allocator, "codex", provider, original_id),
        .rows = std.array_list.Managed(Value).init(allocator),
        .warnings = common.Warnings.init(allocator),
        .active = std.array_list.Managed(Value).init(allocator),
        .active_starts = std.array_list.Managed(usize).init(allocator),
        .pending = std.array_list.Managed(Pending).init(allocator),
        .started = thread.created_at,
    };
    var metadata = try common.obj(allocator, &.{
        .{ "id", jsonString(self.id) },
        .{ "session_id", jsonString(self.id) },
        .{ "timestamp", jsonString(thread.created_at) },
        .{ "cwd", jsonString(thread.cwd) },
        .{ "originator", jsonString("c2c") },
        .{ "cli_version", jsonString(format_version) },
        .{ "source", jsonString("cli") },
        .{ "model_provider", jsonString("openai") },
        .{ "history_mode", jsonString("legacy") },
        .{ "base_instructions", .null },
    });
    const codex_origin = if (common.eq(thread.origin_provider orelse "", "codex"))
        thread.origin_id
    else
        thread.original_codex_id;
    if (codex_origin) |original| {
        if (!common.validUuid(original)) {
            return error.InvalidOriginalCodexId;
        }
        try common.set(allocator, &metadata, "forked_from_id", jsonString(original));
    }
    try self.add("session_meta", metadata, thread.created_at);
    var last_timestamp = thread.created_at;
    var summary_pending = false;
    for (entries) |entry| {
        if (common.eq(common.stringField(entry, "subtype"), "compact_boundary")) {
            try self.complete(last_timestamp);
            summary_pending = true;
            continue;
        }
        const msg = common.get(entry, "message");
        var role = common.stringField(msg, "role");
        if (role.len == 0) {
            role = common.stringField(entry, "type");
        }
        if (!common.eq(role, "user") and !common.eq(role, "assistant")) {
            continue;
        }
        self.source_count += 1;
        const ts = common.stringField(entry, "timestamp");
        const timestamp = if (ts.len > 0) ts else thread.updated_at;
        _ = try common.timestampMillis(timestamp);
        last_timestamp = timestamp;
        const input = try blocks(allocator, common.get(msg, "content"));
        var visible = std.array_list.Managed(Value).init(allocator);
        var has_result = false;
        for (input) |block| {
            if (is(block, "tool_result")) {
                has_result = true;
            }
            if (!is(block, "tool_use") and !is(block, "tool_result") and
                !is(block, "thinking") and !is(block, "redacted_thinking"))
            {
                try visible.append(block);
            }
        }
        const summary = common.boolValue(common.get(entry, "isCompactSummary")) or
            (summary_pending and common.eq(role, "user"));
        if (visible.items.len > 0) {
            if (common.eq(role, "user") and !summary and !has_result) {
                try self.complete(timestamp);
            }
            try self.message(role, visible.items, timestamp, summary);
            summary_pending = false;
        }
        for (input) |block| {
            if (is(block, "tool_use")) {
                try self.begin(timestamp);
                const provided_id = common.stringField(block, "id");
                const source_id = if (provided_id.len > 0) provided_id else try self.next("missing-source-tool-id");
                for (self.pending.items) |pending| {
                    if (common.eq(pending.source_id, source_id)) {
                        return error.DuplicatePendingToolId;
                    }
                }
                const id = try self.next("call");
                const given_name = common.stringField(block, "name");
                const name = if (given_name.len > 0) given_name else "historical_tool";
                const given_input = common.get(block, "input");
                const arguments = if (given_input != .null) given_input else try common.obj(allocator, &.{});
                try self.pending.append(.{
                    .source_id = source_id,
                    .id = id,
                    .name = name,
                    .input = arguments,
                    .started = try common.timestampMillis(timestamp),
                });
                try self.response(
                    try common.obj(allocator, &.{
                        .{ "type", jsonString("function_call") },
                        .{ "call_id", jsonString(id) },
                        .{ "name", jsonString(name) },
                        .{ "arguments", jsonString(try common.json(allocator, arguments)) },
                    }),
                    timestamp,
                );
            } else if (is(block, "tool_result")) {
                try self.output(
                    common.stringField(block, "tool_use_id"),
                    common.get(block, "content"),
                    timestamp,
                    common.boolValue(common.get(block, "is_error")),
                    false,
                );
            }
        }
    }
    try self.complete(last_timestamp);
    try self.boundContext(last_timestamp);
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const encoded = try allocator.alloc(u8, encoder.calcSize(original_id.len));
    _ = encoder.encode(encoded, original_id);
    const digest = try format.fingerprint(allocator, self.rows.items);
    try common.set(
        allocator,
        &metadata,
        "originator",
        jsonString(try common.fmt(allocator, "c2c:{s}:{s}:{s}", .{ provider, encoded, digest })),
    );
    // Reassign the header to avoid a stale copy after map reallocation.
    try common.set(allocator, &self.rows.items[0], "payload", metadata);
    if ((try validate(allocator, self.rows.items)).len != 0) {
        return error.InvalidCodexRollout;
    }
    return .{
        .entries = try self.rows.toOwnedSlice(),
        .warnings = try self.warnings.toOwnedSlice(),
        .message_count = self.messages,
        .tool_count = self.tools,
        .source_item_count = self.source_count,
        .session_id = self.id,
    };
}
