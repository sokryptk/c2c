//! Native Codex rollout codec. Never executes a historical tool or starts inference.
const std = @import("std");
const C = @import("common.zig");
const V = C.Value;
const A = C.Allocator;
const S = C.str;
const N = C.num;
const namespace = "b18998c2-4d26-40bd-9c20-2dd493c3a146";
const version = "0.159.2";
const max_active_bytes = 240_000;
const recent_bytes = 170_000;
const sqlite = @cImport({
    @cInclude("sqlite3.h");
});

pub fn sessionId(a: A, id: []const u8) ![]const u8 {
    return C.sessionIdFor(a, "codex", "claude", id);
}
pub fn targetPath(a: A, thread: C.Thread, home: []const u8) ![]const u8 {
    return targetPathFor(a, thread, home, "claude");
}
pub fn targetPathFor(a: A, thread: C.Thread, home: []const u8, provider: []const u8) ![]const u8 {
    const ts = try C.timestamp(a, try C.timestampMillis(thread.created_at));
    if (ts.len < 19) return error.InvalidTimestamp;
    const stamp = try a.dupe(u8, ts[0..19]);
    for (stamp) |*ch| if (ch.* == ':') {
        ch.* = '-';
    };
    return C.join(a, &.{ home, "sessions", ts[0..4], ts[5..7], ts[8..10], try C.fmt(a, "rollout-{s}-{s}.jsonl", .{ stamp, try C.sessionIdFor(a, "codex", provider, thread.id) }) });
}
fn is(v: V, kind: []const u8) bool {
    return C.eq(C.s(v, "type"), kind);
}
fn blocks(a: A, v: V) ![]const V {
    if (v == .string) return if (v.string.len == 0) &.{} else C.list(try C.arr(a, &.{try C.obj(a, &.{ .{ "type", S("text") }, .{ "text", v } })}));
    return C.list(v);
}
fn uri(a: A, path: []const u8) ![]const u8 {
    if (path.len == 0 or path[0] != '/') return error.AbsoluteWorkingDirectoryRequired;
    var out = std.array_list.Managed(u8).init(a);
    try out.appendSlice("file://");
    const hex = "0123456789ABCDEF";
    for (path) |ch| {
        if (std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "/-_.~", ch) != null) try out.append(ch) else try out.appendSlice(&.{ '%', hex[ch >> 4], hex[ch & 15] });
    }
    return out.toOwnedSlice();
}
const Content = struct { model: []const V, view: []const V };
const Pending = struct { source_id: []const u8, id: []const u8, name: []const u8, input: V, started: i64 };
const Builder = struct {
    a: A,
    thread: C.Thread,
    opts: C.ConvertOptions,
    id: []const u8,
    rows: std.array_list.Managed(V),
    warnings: C.Warnings,
    active: std.array_list.Managed(V),
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
        return C.uuid5(self.a, namespace, try C.fmt(self.a, "{s}:{s}:{d}", .{ self.id, label, self.counter }));
    }
    fn add(self: *Builder, kind: []const u8, payload: V, timestamp: []const u8) !void {
        try self.rows.append(try C.obj(self.a, &.{ .{ "timestamp", S(timestamp) }, .{ "type", S(kind) }, .{ "payload", payload } }));
    }
    fn response(self: *Builder, payload: V, timestamp: []const u8) !void {
        try self.add("response_item", payload, timestamp);
        try self.active.append(payload);
    }
    fn begin(self: *Builder, timestamp: []const u8) anyerror!void {
        if (self.turn != null) return;
        if (self.active_starts.items.len == 0 or self.active_starts.items[self.active_starts.items.len - 1] != self.active.items.len)
            try self.active_starts.append(self.active.items.len);
        self.turn = try self.next("turn");
        self.started = timestamp;
        self.last_answer = "";
        try self.add("event_msg", try C.obj(self.a, &.{ .{ "type", S("task_started") }, .{ "turn_id", S(self.turn.?) }, .{ "started_at", N(try C.timestampMillis(timestamp)) }, .{ "model_context_window", .null }, .{ "collaboration_mode_kind", S("default") } }), timestamp);
    }
    fn display(self: *Builder, item: V, timestamp: []const u8) anyerror!void {
        try self.begin(timestamp);
        const ms = try C.timestampMillis(timestamp);
        try self.add("event_msg", try C.obj(self.a, &.{ .{ "type", S("item_completed") }, .{ "thread_id", S(self.id) }, .{ "turn_id", S(self.turn.?) }, .{ "item", item }, .{ "started_at_ms", N(ms) }, .{ "completed_at_ms", N(ms) } }), timestamp);
    }
    fn complete(self: *Builder, timestamp: []const u8) anyerror!void {
        if (self.turn == null) return;
        while (self.pending.items.len > 0) {
            const id = self.pending.items[0].source_id;
            try self.output(id, S("This historical source tool call had no saved result. c2c did not execute it."), timestamp, false, true);
            try self.warnings.append("Incomplete historical tool call closed without execution");
        }
        const start_ms = try C.timestampMillis(self.started);
        const end_ms = try C.timestampMillis(timestamp);
        try self.add("event_msg", try C.obj(self.a, &.{ .{ "type", S("task_complete") }, .{ "turn_id", S(self.turn.?) }, .{ "last_agent_message", if (self.last_answer.len > 0) S(self.last_answer) else .null }, .{ "started_at", N(start_ms) }, .{ "completed_at", N(end_ms) }, .{ "duration_ms", N(@max(0, end_ms - start_ms)) } }), timestamp);
        self.turn = null;
    }
    fn content(self: *Builder, input: []const V, role: []const u8) !Content {
        var model = std.array_list.Managed(V).init(self.a);
        var view = std.array_list.Managed(V).init(self.a);
        const user = C.eq(role, "user");
        for (input) |block| {
            if (is(block, "thinking") or is(block, "redacted_thinking") or is(block, "tool_use") or is(block, "tool_result")) continue;
            var text: []const u8 = "";
            if (is(block, "text")) text = C.s(block, "text") else if (is(block, "image")) {
                const source = C.get(block, "source");
                var url = C.s(source, "url");
                if (is(source, "base64") and self.opts.embed_images) {
                    const encoded = C.s(source, "data");
                    const mime = C.s(source, "media_type");
                    const decoder = std.base64.standard.Decoder;
                    if (decoder.calcSizeForSlice(encoded)) |length| {
                        const decoded = try self.a.alloc(u8, length);
                        if (decoder.decode(decoded, encoded)) |_| {
                            if (std.mem.startsWith(u8, mime, "image/")) url = try C.fmt(self.a, "data:{s};base64,{s}", .{ mime, encoded });
                        } else |_| try self.warnings.append("Invalid Source image base64; preserved attachment metadata");
                    } else |_| try self.warnings.append("Invalid Source image base64; preserved attachment metadata");
                }
                if (url.len > 0 and user) {
                    try model.append(try C.obj(self.a, &.{ .{ "type", S("input_image") }, .{ "image_url", S(url) } }));
                    try view.append(try C.obj(self.a, &.{ .{ "type", S("image") }, .{ "image_url", S(url) } }));
                    continue;
                }
                text = if (is(source, "url")) try C.fmt(self.a, "[Source image attachment] {s}", .{url}) else if (!self.opts.embed_images) "[Source image attachment; bytes remain in the original transcript]" else "[Source image attachment]";
            } else {
                text = try C.fmt(self.a, "[Source attachment]\n{s}", .{try C.json(self.a, block)});
                try self.warnings.append(try C.fmt(self.a, "Source content type '{s}' preserved as text", .{C.s(block, "type")}));
            }
            if (text.len == 0) continue;
            try model.append(try C.obj(self.a, &.{ .{ "type", S(if (user) "input_text" else "output_text") }, .{ "text", S(text) } }));
            var visible = try C.obj(self.a, &.{ .{ "type", S(if (user) "text" else "Text") }, .{ "text", S(text) } });
            if (user) try C.set(self.a, &visible, "text_elements", try C.arr(self.a, &.{}));
            try view.append(visible);
        }
        return .{ .model = try model.toOwnedSlice(), .view = try view.toOwnedSlice() };
    }
    fn textOf(self: *Builder, input: []const V, image_notice: bool) ![]const u8 {
        var texts = std.array_list.Managed([]const u8).init(self.a);
        for (input) |block| {
            const text = C.s(block, "text");
            if (text.len > 0) try texts.append(text) else if (image_notice) try texts.append("[Image attachment preserved in tool result]");
        }
        return std.mem.join(self.a, "\n", texts.items);
    }
    fn message(self: *Builder, role: []const u8, input: []const V, timestamp: []const u8, summary: bool) anyerror!void {
        const parts = try self.content(input, role);
        if (parts.model.len == 0) return;
        const id = try self.next("message");
        const user = C.eq(role, "user");
        var payload = try C.obj(self.a, &.{ .{ "type", S("message") }, .{ "id", S(id) }, .{ "role", S(role) }, .{ "content", try C.arr(self.a, parts.model) } });
        if (!user) {
            try C.set(self.a, &payload, "phase", S("final_answer"));
            self.last_answer = try self.textOf(parts.model, false);
        }
        if (summary) {
            try self.complete(timestamp);
            try self.add("compacted", try C.obj(self.a, &.{ .{ "message", S(try self.textOf(parts.model, false)) }, .{ "replacement_history", try C.arr(self.a, &.{payload}) }, .{ "compaction_response_id", .null }, .{ "latest_token_usage_record", .null } }), timestamp);
            self.active.clearRetainingCapacity();
            self.active_starts.clearRetainingCapacity();
            try self.active_starts.append(0);
            try self.active.append(payload);
        } else {
            try self.begin(timestamp);
            try self.response(payload, timestamp);
        }
        var visible = try C.obj(self.a, &.{ .{ "type", S(if (user) "UserMessage" else "AgentMessage") }, .{ "id", S(id) }, .{ "content", try C.arr(self.a, parts.view) } });
        if (!user) try C.set(self.a, &visible, "phase", S("final_answer"));
        try self.display(visible, timestamp);
        self.messages += 1;
    }
    fn output(self: *Builder, call_id: []const u8, raw: V, timestamp: []const u8, failed: bool, missing: bool) anyerror!void {
        var index: ?usize = null;
        for (self.pending.items, 0..) |p, i| if (C.eq(p.source_id, call_id)) {
            index = i;
            break;
        };
        if (index == null) {
            try self.message("assistant", try blocks(self.a, S(try C.fmt(self.a, "[Unpaired historical source tool result]\n{s}", .{try C.json(self.a, raw)}))), timestamp, false);
            try self.warnings.append("Unpaired source tool result preserved as a visible artifact");
            return;
        }
        const saved = self.pending.orderedRemove(index.?);
        const parts = try self.content(try blocks(self.a, raw), "user");
        var native_output = if (raw == .string) raw else try C.arr(self.a, parts.model);
        if (failed) {
            const notice = "[The source marked this historical tool result as an error.]";
            if (native_output == .string) native_output = S(try C.fmt(self.a, "{s}\n{s}", .{ notice, native_output.string })) else {
                var augmented = std.array_list.Managed(V).init(self.a);
                try augmented.append(try C.obj(self.a, &.{ .{ "type", S("input_text") }, .{ "text", S(notice) } }));
                try augmented.appendSlice(parts.model);
                native_output = try C.arr(self.a, augmented.items);
            }
        }
        const formatted = try self.textOf(parts.model, true);
        try self.response(try C.obj(self.a, &.{ .{ "type", S("function_call_output") }, .{ "call_id", S(saved.id) }, .{ "output", native_output } }), timestamp);
        const command = C.s(saved.input, "command");
        if (C.eq(saved.name, "Bash") and command.len > 0) {
            const elapsed = @max(0, (try C.timestampMillis(timestamp)) - saved.started);
            try self.display(try C.obj(self.a, &.{ .{ "type", S("CommandExecution") }, .{ "id", S(saved.id) }, .{ "command", try C.arr(self.a, &.{ S("bash"), S("-lc"), S(command) }) }, .{ "cwd", S(try uri(self.a, self.thread.cwd)) }, .{ "parsed_cmd", try C.arr(self.a, &.{}) }, .{ "source", S("unified_exec_startup") }, .{ "status", S(if (failed or missing) "failed" else "completed") }, .{ "stdout", S(formatted) }, .{ "stderr", S("") }, .{ "aggregated_output", S(formatted) }, .{ "duration", try C.obj(self.a, &.{ .{ "secs", N(@divTrunc(elapsed, 1000)) }, .{ "nanos", N(@mod(elapsed, 1000) * 1_000_000) } }) }, .{ "formatted_output", S(formatted) } }), timestamp);
        } else {
            const artifact = try C.fmt(self.a, "[Historical source tool: {s}]\nInput:\n{s}\nResult:\n{s}", .{ saved.name, try C.json(self.a, saved.input), formatted });
            try self.display(try C.obj(self.a, &.{ .{ "type", S("AgentMessage") }, .{ "id", S(try self.next("tool-display")) }, .{ "content", try C.arr(self.a, &.{try C.obj(self.a, &.{ .{ "type", S("Text") }, .{ "text", S(artifact) } })}) }, .{ "phase", S("final_answer") } }), timestamp);
        }
        self.tools += 1;
    }
    fn excerpt(self: *Builder, item: V) !V {
        if ((try C.json(self.a, item)).len <= 40_000) return item;
        const text = try self.textOf(C.list(C.get(item, "content")), true);
        var shortened = text;
        if (text.len > 30_000) {
            var start: usize = 15_000;
            while (start > 0 and (text[start] & 0xc0) == 0x80) : (start -= 1) {}
            var end = text.len - 15_000;
            while (end < text.len and (text[end] & 0xc0) == 0x80) : (end += 1) {}
            shortened = try C.fmt(self.a, "{s}\n[c2c: excerpt shortened; full text remains in the transcript.]\n{s}", .{ text[0..start], text[end..] });
        }
        var bounded = try C.clone(self.a, item);
        try C.set(self.a, &bounded, "content", try C.arr(self.a, &.{try C.obj(self.a, &.{ .{ "type", S(if (C.eq(C.s(item, "role"), "user")) "input_text" else "output_text") }, .{ "text", S(shortened) } })}));
        return bounded;
    }
    fn boundContext(self: *Builder, timestamp: []const u8) !void {
        if ((try C.json(self.a, try C.arr(self.a, self.active.items))).len <= max_active_bytes) return;
        const starts = self.active_starts;
        var selected = std.array_list.Managed(V).init(self.a);
        var size: usize = 0;
        var end = self.active.items.len;
        var cursor = starts.items.len;
        while (cursor > 0) {
            cursor -= 1;
            const start = starts.items[cursor];
            const group = self.active.items[start..end];
            const length = (try C.json(self.a, try C.arr(self.a, group))).len;
            if (size + length > recent_bytes) {
                if (selected.items.len == 0) {
                    var messages = std.array_list.Managed(V).init(self.a);
                    for (group) |entry| if (is(entry, "message")) try messages.append(entry);
                    const initial: ?V = if (messages.items.len > 0 and C.eq(C.s(messages.items[0], "role"), "user")) try self.excerpt(messages.items[0]) else null;
                    size = if (initial) |v| (try C.json(self.a, v)).len else 0;
                    var n = messages.items.len;
                    const lower: usize = if (initial != null) 1 else 0;
                    while (n > lower) {
                        n -= 1;
                        const bounded = try self.excerpt(messages.items[n]);
                        const bytes = (try C.json(self.a, bounded)).len;
                        if (size + bytes > recent_bytes) break;
                        try selected.insert(0, bounded);
                        size += bytes;
                    }
                    if (initial) |v| try selected.insert(0, v);
                }
                break;
            }
            try selected.insertSlice(0, group);
            size += length;
            end = start;
        }
        const notice = try C.fmt(self.a, "c2c restored a recent context window from this source conversation. Earlier messages and tool outputs remain in the full native transcript. This is an extractive window, not a semantic summary. Read the transcript when earlier decisions or exact details are needed.\nFull native transcript: {s}\nOriginal source transcript: {s}", .{ self.opts.transcript_path orelse "[the current session rollout]", self.thread.rollout_path });
        const summary = try C.obj(self.a, &.{ .{ "type", S("message") }, .{ "role", S("user") }, .{ "content", try C.arr(self.a, &.{try C.obj(self.a, &.{ .{ "type", S("input_text") }, .{ "text", S(notice) } })}) } });
        try selected.insert(0, summary);
        try self.add("compacted", try C.obj(self.a, &.{ .{ "message", S(notice) }, .{ "replacement_history", try C.arr(self.a, selected.items) }, .{ "compaction_response_id", .null }, .{ "latest_token_usage_record", .null } }), timestamp);
        try self.warnings.append("Large source history retained in full; active context uses a labelled recent window");
    }
};

pub fn convert(a: A, thread: C.Thread, entries: []const V, opts: C.ConvertOptions) !C.Conversion {
    const provider = opts.source_provider orelse "claude";
    const original_id = opts.source_session_id orelse thread.id;
    if (!supportedProvider(provider)) return error.UnsupportedSourceProvider;
    var self = Builder{ .a = a, .thread = thread, .opts = opts, .id = try C.sessionIdFor(a, "codex", provider, original_id), .rows = std.array_list.Managed(V).init(a), .warnings = C.Warnings.init(a), .active = std.array_list.Managed(V).init(a), .active_starts = std.array_list.Managed(usize).init(a), .pending = std.array_list.Managed(Pending).init(a), .started = thread.created_at };
    var metadata = try C.obj(a, &.{ .{ "id", S(self.id) }, .{ "session_id", S(self.id) }, .{ "timestamp", S(thread.created_at) }, .{ "cwd", S(thread.cwd) }, .{ "originator", S("c2c") }, .{ "cli_version", S(version) }, .{ "source", S("cli") }, .{ "model_provider", S("openai") }, .{ "history_mode", S("legacy") }, .{ "base_instructions", .null } });
    const codex_origin = if (C.eq(thread.origin_provider orelse "", "codex")) thread.origin_id else thread.original_codex_id;
    if (codex_origin) |original| {
        if (!C.validUuid(original)) return error.InvalidOriginalCodexId;
        try C.set(a, &metadata, "forked_from_id", S(original));
    }
    try self.add("session_meta", metadata, thread.created_at);
    var last_timestamp = thread.created_at;
    var summary_pending = false;
    for (entries) |entry| {
        if (C.eq(C.s(entry, "subtype"), "compact_boundary")) {
            try self.complete(last_timestamp);
            summary_pending = true;
            continue;
        }
        const msg = C.get(entry, "message");
        var role = C.s(msg, "role");
        if (role.len == 0) role = C.s(entry, "type");
        if (!C.eq(role, "user") and !C.eq(role, "assistant")) continue;
        self.source_count += 1;
        const ts = C.s(entry, "timestamp");
        const timestamp = if (ts.len > 0) ts else thread.updated_at;
        _ = try C.timestampMillis(timestamp);
        last_timestamp = timestamp;
        const input = try blocks(a, C.get(msg, "content"));
        var visible = std.array_list.Managed(V).init(a);
        var has_result = false;
        for (input) |block| {
            if (is(block, "tool_result")) has_result = true;
            if (!is(block, "tool_use") and !is(block, "tool_result") and !is(block, "thinking") and !is(block, "redacted_thinking")) try visible.append(block);
        }
        const summary = C.b(C.get(entry, "isCompactSummary")) or (summary_pending and C.eq(role, "user"));
        if (visible.items.len > 0) {
            if (C.eq(role, "user") and !summary and !has_result) try self.complete(timestamp);
            try self.message(role, visible.items, timestamp, summary);
            summary_pending = false;
        }
        for (input) |block| {
            if (is(block, "tool_use")) {
                try self.begin(timestamp);
                const provided_id = C.s(block, "id");
                const source_id = if (provided_id.len > 0) provided_id else try self.next("missing-source-tool-id");
                for (self.pending.items) |p| if (C.eq(p.source_id, source_id)) return error.DuplicatePendingToolId;
                const id = try self.next("call");
                const given_name = C.s(block, "name");
                const name = if (given_name.len > 0) given_name else "historical_tool";
                const given_input = C.get(block, "input");
                const arguments = if (given_input != .null) given_input else try C.obj(a, &.{});
                try self.pending.append(.{ .source_id = source_id, .id = id, .name = name, .input = arguments, .started = try C.timestampMillis(timestamp) });
                try self.response(try C.obj(a, &.{ .{ "type", S("function_call") }, .{ "call_id", S(id) }, .{ "name", S(name) }, .{ "arguments", S(try C.json(a, arguments)) } }), timestamp);
            } else if (is(block, "tool_result")) try self.output(C.s(block, "tool_use_id"), C.get(block, "content"), timestamp, C.b(C.get(block, "is_error")), false);
        }
    }
    try self.complete(last_timestamp);
    try self.boundContext(last_timestamp);
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const encoded = try a.alloc(u8, encoder.calcSize(original_id.len));
    _ = encoder.encode(encoded, original_id);
    const digest = try fingerprint(a, self.rows.items);
    try C.set(a, &metadata, "originator", S(try C.fmt(a, "c2c:{s}:{s}:{s}", .{ provider, encoded, digest })));
    // Object maps share allocated storage, but explicitly reassign the header
    // so adding a field can never leave a stale copy after map reallocation.
    try C.set(a, &self.rows.items[0], "payload", metadata);
    if ((try validate(a, self.rows.items)).len != 0) return error.InvalidCodexRollout;
    return .{ .entries = try self.rows.toOwnedSlice(), .warnings = try self.warnings.toOwnedSlice(), .message_count = self.messages, .tool_count = self.tools, .source_item_count = self.source_count, .session_id = self.id };
}

pub fn validate(a: A, entries: []const V) ![][]const u8 {
    var errors = C.Warnings.init(a);
    if (entries.len == 0 or !is(entries[0], "session_meta")) {
        try errors.append("First record must be session_meta");
        return errors.toOwnedSlice();
    }
    const meta = C.get(entries[0], "payload");
    const mode = C.s(meta, "history_mode");
    if (!C.validUuid(C.s(meta, "id"))) try errors.append("Session ID is not a UUID");
    if (!C.eq(mode, "legacy") and !C.eq(mode, "paginated")) try errors.append("Unknown native history mode");
    var pending = std.StringHashMap(void).init(a);
    var turn: ?[]const u8 = null;
    for (entries) |row| {
        _ = C.timestampMillis(C.s(row, "timestamp")) catch {
            try errors.append("Invalid timestamp");
            continue;
        };
        const payload = C.get(row, "payload");
        if (is(row, "event_msg")) {
            if (is(payload, "task_started")) {
                if (turn != null) try errors.append("Overlapping turns");
                turn = C.s(payload, "turn_id");
            } else if (is(payload, "task_complete")) {
                if (!C.eq(C.s(payload, "turn_id"), turn orelse "")) try errors.append("Mismatched turn completion");
                turn = null;
            } else if (is(payload, "item_completed")) {
                if (!C.eq(C.s(payload, "turn_id"), turn orelse "") or !C.eq(C.s(payload, "thread_id"), C.s(meta, "id"))) try errors.append("Orphan visible item");
            }
        } else if (is(row, "response_item")) {
            try validateResponse(payload, &pending, &errors);
        } else if (is(row, "compacted")) {
            if (pending.count() > 0) try errors.append("Compaction interrupts pending tool calls");
            var replacement_pending = std.StringHashMap(void).init(a);
            defer replacement_pending.deinit();
            for (C.list(C.get(payload, "replacement_history"))) |item|
                try validateResponse(item, &replacement_pending, &errors);
            if (replacement_pending.count() > 0) try errors.append("Pending tool calls in compacted history");
        }
    }
    if (pending.count() > 0) try errors.append("Pending tool calls");
    if (turn != null) try errors.append("Unclosed turn");
    return errors.toOwnedSlice();
}
fn validateResponse(payload: V, pending: *std.StringHashMap(void), errors: *C.Warnings) !void {
    if (is(payload, "function_call")) {
        const id = C.s(payload, "call_id");
        if (id.len == 0) try errors.append("Missing tool call ID");
        if (pending.contains(id)) try errors.append("Duplicate pending tool call");
        try pending.put(id, {});
    } else if (is(payload, "function_call_output")) {
        if (!pending.remove(C.s(payload, "call_id"))) try errors.append("Unpaired tool result");
    } else if (is(payload, "message") and !C.eq(C.s(payload, "role"), "user") and !C.eq(C.s(payload, "role"), "assistant")) {
        try errors.append("Private instruction role in imported history");
    }
}

fn sorted(a: A, value: V) !V {
    if (value == .object) {
        var keys = std.array_list.Managed([]const u8).init(a);
        var it = value.object.iterator();
        while (it.next()) |entry| try keys.append(entry.key_ptr.*);
        std.mem.sort([]const u8, keys.items, {}, struct {
            fn less(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.order(u8, left, right) == .lt;
            }
        }.less);
        var out = try C.obj(a, &.{});
        for (keys.items) |key| try C.set(a, &out, key, try sorted(a, value.object.get(key).?));
        return out;
    }
    if (value == .array) {
        var out = std.array_list.Managed(V).init(a);
        for (value.array.items) |v| try out.append(try sorted(a, v));
        return C.arr(a, out.items);
    }
    return value;
}
fn canonical(a: A, row: V, for_hash: bool) !V {
    var value = try C.clone(a, row);
    if (value != .object) return value;
    _ = value.object.swapRemove("ordinal");
    if (is(value, "session_meta")) {
        var payload = C.get(value, "payload");
        try C.set(a, &payload, "history_mode", S("legacy"));
        if (C.get(payload, "base_instructions") == .null) try C.set(a, &payload, "base_instructions", .null);
        if (for_hash) try C.set(a, &payload, "originator", S("c2c"));
        try C.set(a, &value, "payload", payload);
    }
    return sorted(a, value);
}
fn fingerprint(a: A, entries: []const V) ![]const u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (entries) |row| {
        hash.update(try C.json(a, try canonical(a, row, true)));
        hash.update("\n");
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return a.dupe(u8, &hex);
}
pub fn registrationMatches(a: A, staged: []const V, target: []const V) !bool {
    if (staged.len != target.len) return false;
    for (staged, target) |before, after| if (!C.eq(try C.json(a, try canonical(a, before, false)), try C.json(a, try canonical(a, after, false)))) return false;
    return true;
}
fn supportedProvider(provider: []const u8) bool {
    return C.eq(provider, "claude") or C.eq(provider, "opencode") or C.eq(provider, "omp") or C.eq(provider, "codex");
}
pub const Origin = struct { provider: ?[]const u8 = null, original_id: ?[]const u8 = null, unchanged: bool = false };
pub fn readOrigin(a: A, thread: C.Thread) !Origin {
    var reader = C.LineReader.open(a, thread.rollout_path) catch return .{};
    defer reader.close();
    const first_line = (try reader.next()) orelse return .{};
    const first = C.parse(a, first_line) catch return .{};
    const originator = C.s(C.get(first, "payload"), "originator");
    const prefix = "c2c:";
    if (!std.mem.startsWith(u8, originator, prefix)) return .{};
    const suffix = originator[prefix.len..];
    const provider_end = std.mem.indexOfScalar(u8, suffix, ':') orelse return .{};
    const provider = suffix[0..provider_end];
    if (!supportedProvider(provider)) return .{};
    const marker = suffix[provider_end + 1 ..];
    const split = std.mem.indexOfScalar(u8, marker, ':') orelse return .{};
    const encoded = marker[0..split];
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const size = decoder.calcSizeForSlice(encoded) catch return .{};
    const original = try a.alloc(u8, size);
    decoder.decode(original, encoded) catch return .{};
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(try C.json(a, try canonical(a, first, true)));
    hash.update("\n");
    while (try reader.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r\n").len == 0) continue;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const temp = arena.allocator();
        const value = C.parse(temp, line) catch return .{ .provider = provider, .original_id = original, .unchanged = false };
        hash.update(try C.json(temp, try canonical(temp, value, true)));
        hash.update("\n");
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return .{ .provider = provider, .original_id = original, .unchanged = C.eq(&hex, marker[split + 1 ..]) };
}

// Native registration uses the installed Codex binary as the sole writer of
// state/projection databases. Expected bytes are checked again after migration.
fn preflight(a: A, home: []const u8, id: []const u8) ![]const u8 {
    const files = try C.walkFiles(a, try C.join(a, &.{ home, "sessions" }), ".jsonl");
    const suffix = try C.fmt(a, "-{s}.jsonl", .{id});
    var expected: ?[]const u8 = null;
    for (files) |path| if (std.mem.endsWith(u8, path, suffix)) {
        if (expected != null) return error.AmbiguousNativeSessionPath;
        expected = path;
    };
    const path = expected orelse return error.NativeSessionPathMissing;
    var database: ?[]const u8 = null;
    var highest: u32 = 0;
    for (try C.listDir(a, home)) |entry| {
        const name = entry.name;
        if (std.mem.startsWith(u8, name, "state_") and std.mem.endsWith(u8, name, ".sqlite")) {
            const number = std.fmt.parseInt(u32, name[6 .. name.len - 7], 10) catch continue;
            if (database == null or number > highest) {
                highest = number;
                database = try C.join(a, &.{ home, name });
            }
        }
    }
    if (database) |db_path| {
        var db: ?*sqlite.sqlite3 = null;
        if (sqlite.sqlite3_open_v2(try a.dupeZ(u8, db_path), &db, sqlite.SQLITE_OPEN_READONLY, null) != sqlite.SQLITE_OK) return error.NativeDatabaseReadFailed;
        defer _ = sqlite.sqlite3_close(db);
        var statement: ?*sqlite.sqlite3_stmt = null;
        if (sqlite.sqlite3_prepare_v2(db, "SELECT rollout_path, archived FROM threads WHERE id=?", -1, &statement, null) != sqlite.SQLITE_OK) return error.NativeDatabaseSchemaUnsupported;
        defer _ = sqlite.sqlite3_finalize(statement);
        const id_z = try a.dupeZ(u8, id);
        _ = sqlite.sqlite3_bind_text(statement, 1, id_z.ptr, @intCast(id.len), null);
        if (sqlite.sqlite3_step(statement) == sqlite.SQLITE_ROW) {
            const native_path = std.mem.span(sqlite.sqlite3_column_text(statement, 0));
            if (sqlite.sqlite3_column_int(statement, 1) != 0 or !C.eq(native_path, path)) return error.NativeSessionIdAlreadyBound;
        }
    }
    const probe = C.Thread{ .id = id, .title = "", .cwd = "", .created_at = "", .updated_at = "", .rollout_path = path };
    if (!(try readOrigin(a, probe)).unchanged) return error.NativeSessionChangedBeforeRegistration;
    return path;
}
const Server = struct {
    child: C.Child,
    a: A,
    sequence: usize = 0,
    fn start(a: A, home: []const u8) !Server {
        return .{ .a = a, .child = try C.Child.start(a, &.{ "codex", "app-server", "--stdio" }, &.{.{ "CODEX_HOME", home }}) };
    }
    fn call(self: *Server, method: []const u8, params: V) !V {
        self.sequence += 1;
        const id: i64 = @intCast(self.sequence);
        const request = try C.obj(self.a, &.{ .{ "id", N(id) }, .{ "method", S(method) }, .{ "params", params } });
        try self.child.write(try C.fmt(self.a, "{s}\n", .{try C.json(self.a, request)}));
        while (try self.child.readLine(self.a, 60_000)) |line| {
            const reply = C.parse(self.a, line) catch continue;
            if (C.integer(C.get(reply, "id")) != id) continue;
            if (C.get(reply, "error") != .null) return error.CodexNativeRpcFailed;
            return C.get(reply, "result");
        }
        return error.CodexNativeServerEnded;
    }
    fn initialize(self: *Server) !void {
        _ = try self.call("initialize", try C.obj(self.a, &.{ .{ "clientInfo", try C.obj(self.a, &.{ .{ "name", S("c2c") }, .{ "version", S("0.1.0") } }) }, .{ "capabilities", try C.obj(self.a, &.{.{ "experimentalApi", C.boolean(true) }}) } }));
        try self.child.write("{\"method\":\"initialized\"}\n");
    }
};
pub fn register(a: A, home: []const u8, id: []const u8, title: []const u8) !V {
    if (!C.validUuid(id)) return error.InvalidCodexSessionId;
    const path = try preflight(a, home, id);
    // Native read discovers a newly published legacy file and backfills its
    // SQLite metadata. migrate-rollouts alone can fail missing_sqlite_metadata
    // for old-dated files or a destination whose initial backfill is complete.
    var server = try Server.start(a, home);
    defer server.child.close();
    try server.initialize();
    const parameters = try C.obj(a, &.{ .{ "threadId", S(id) }, .{ "includeTurns", C.boolean(false) } });
    try verifyNativeIdentity(C.get(try server.call("thread/read", parameters), "thread"), id, path);
    const result = try C.run(a, &.{ "codex", "migrate-rollouts", "--apply", "--thread", id, "--json" }, &.{.{ "CODEX_HOME", home }}, null, 300_000);
    if (result.exit_code != 0) return error.CodexNativeMigrationFailed;
    if (!(try readOrigin(a, .{ .id = id, .title = "", .cwd = "", .created_at = "", .updated_at = "", .rollout_path = path })).unchanged) return error.CodexMigrationChangedConversationContent;
    const saved = C.get(try server.call("thread/read", parameters), "thread");
    try verifyNativeIdentity(saved, id, path);
    if (C.s(saved, "name").len == 0) _ = try server.call("thread/name/set", try C.obj(a, &.{ .{ "threadId", S(id) }, .{ "name", S(if (title.len > 0) title else "Imported source conversation") } }));
    return C.obj(a, &.{ .{ "thread_id", S(id) }, .{ "status", S("registered") }, .{ "format_version", S(version) } });
}
fn verifyNativeIdentity(saved: V, id: []const u8, path: []const u8) !void {
    if (!C.eq(C.s(saved, "id"), id)) return error.NativeSessionIdentityMismatch;
    if (C.s(saved, "path").len > 0 and !C.eq(C.s(saved, "path"), path)) return error.NativeSessionPathMismatch;
}

fn newestDatabase(a: A, home: []const u8, prefix: []const u8) !?[]const u8 {
    var latest: ?[]const u8 = null;
    var highest: u64 = 0;
    for (try C.listDir(a, home)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, prefix) or !std.mem.endsWith(u8, entry.name, ".sqlite")) continue;
        const number = std.fmt.parseInt(u64, entry.name[prefix.len .. entry.name.len - 7], 10) catch continue;
        if (latest == null or number > highest) {
            latest = try C.join(a, &.{ home, entry.name });
            highest = number;
        }
    }
    return latest;
}
fn databaseHasSession(a: A, path: []const u8, id: []const u8, history: bool) !bool {
    var db: ?*sqlite.sqlite3 = null;
    if (sqlite.sqlite3_open_v2(try a.dupeZ(u8, path), &db, sqlite.SQLITE_OPEN_READONLY, null) != sqlite.SQLITE_OK) {
        if (db != null) _ = sqlite.sqlite3_close(db);
        return error.NativeDatabaseReadFailed;
    }
    defer _ = sqlite.sqlite3_close(db);
    const tables: []const []const u8 = if (history) &.{ "thread_turns", "thread_items", "thread_history_projection_state", "thread_realtime_items" } else &.{"threads"};
    var known_tables: usize = 0;
    for (tables) |table| {
        var schema: ?*sqlite.sqlite3_stmt = null;
        if (sqlite.sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", -1, &schema, null) != sqlite.SQLITE_OK) return error.NativeDatabaseReadFailed;
        defer _ = sqlite.sqlite3_finalize(schema);
        const table_z = try a.dupeZ(u8, table);
        _ = sqlite.sqlite3_bind_text(schema, 1, table_z.ptr, @intCast(table.len), null);
        const schema_step = sqlite.sqlite3_step(schema);
        if (schema_step == sqlite.SQLITE_DONE) continue;
        if (schema_step != sqlite.SQLITE_ROW) return error.NativeDatabaseReadFailed;
        known_tables += 1;
        var query: ?*sqlite.sqlite3_stmt = null;
        const sql_text = try a.dupeZ(u8, try C.fmt(a, "SELECT 1 FROM {s} WHERE {s}=? LIMIT 1", .{ table, if (history) "thread_id" else "id" }));
        if (sqlite.sqlite3_prepare_v2(db, sql_text, -1, &query, null) != sqlite.SQLITE_OK) return error.NativeDatabaseSchemaUnsupported;
        defer _ = sqlite.sqlite3_finalize(query);
        const id_z = try a.dupeZ(u8, id);
        _ = sqlite.sqlite3_bind_text(query, 1, id_z.ptr, @intCast(id.len), null);
        const step = sqlite.sqlite3_step(query);
        if (step == sqlite.SQLITE_ROW) return true;
        if (step != sqlite.SQLITE_DONE) return error.NativeDatabaseReadFailed;
    }
    if (known_tables == 0) return error.NativeDatabaseSchemaUnsupported;
    return false;
}
fn nativeAbsent(a: A, home: []const u8, id: []const u8) !bool {
    const suffix = try C.fmt(a, "-{s}.jsonl", .{id});
    for ([_][]const u8{ "sessions", "archived_sessions" }) |directory| {
        const root = try C.join(a, &.{ home, directory });
        if (!C.exists(root)) continue;
        for (try C.walkFiles(a, root, ".jsonl")) |path| if (std.mem.endsWith(u8, path, suffix)) return false;
    }
    if (try newestDatabase(a, home, "state_")) |path| if (try databaseHasSession(a, path, id, false)) return false;
    if (try newestDatabase(a, home, "thread_history_")) |path| if (try databaseHasSession(a, path, id, true)) return false;
    const index = try C.join(a, &.{ home, "session_index.jsonl" });
    if (C.exists(index)) {
        var reader = try C.LineReader.open(a, index);
        defer reader.close();
        while (try reader.next()) |line| {
            if (std.mem.trim(u8, line, " \t\r\n").len == 0) continue;
            const row = try C.parse(a, line);
            if (C.eq(C.s(row, "id"), id) or C.eq(C.s(row, "session_id"), id) or C.eq(C.s(row, "thread_id"), id)) return false;
        }
    }
    return true;
}

pub fn unregister(a: A, home: []const u8, id: []const u8) !void {
    if (!C.validUuid(id)) return error.InvalidCodexSessionId;
    const result = try C.run(a, &.{ "codex", "delete", "--force", id }, &.{.{ "CODEX_HOME", home }}, null, 60_000);
    if (result.exit_code == 0) {
        if (!try nativeAbsent(a, home, id)) return error.CodexNativeRemovalIncomplete;
        return;
    }
    // Recovery may repeat an already completed native delete. Accept only the
    // native missing-session failure and independently prove no live state.
    if (result.exit_code == 1 and std.mem.endsWith(u8, std.mem.trim(u8, result.stderr, " \t\r\n"), "Error: failed to delete session") and try nativeAbsent(a, home, id)) return;
    return error.CodexNativeRemovalFailed;
}

fn fixtureThread() C.Thread {
    return .{ .id = "claude-session", .title = "Synthetic", .cwd = "/tmp/project", .created_at = "2026-01-02T03:04:05.000Z", .updated_at = "2026-01-02T03:05:00.000Z", .rollout_path = "/tmp/claude.jsonl" };
}
fn fixtureEntry(a: A, role: []const u8, content: V) !V {
    return C.obj(a, &.{ .{ "type", S(role) }, .{ "timestamp", S("2026-01-02T03:04:06.000Z") }, .{ "message", try C.obj(a, &.{ .{ "role", S(role) }, .{ "content", content } }) } });
}
test "Codex has model records visible records and deterministic IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = &.{ try fixtureEntry(a, "user", S("Question")), try fixtureEntry(a, "assistant", S("Answer")) };
    const result = try convert(a, fixtureThread(), entries, .{});
    try std.testing.expectEqual(@as(usize, 2), result.message_count);
    try std.testing.expectEqual(@as(usize, 7), result.entries.len);
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, result.entries)).len);
    try std.testing.expectEqualStrings(try sessionId(a, "claude-session"), result.session_id);
    try std.testing.expect(std.mem.indexOf(u8, try targetPath(a, fixtureThread(), "/tmp/codex"), "/sessions/2026/01/02/") != null);
    const migrated = try a.alloc(V, result.entries.len);
    for (result.entries, 0..) |row, i| {
        migrated[i] = try C.clone(a, row);
        try C.set(a, &migrated[i], "ordinal", N(@intCast(i)));
    }
    var meta = C.get(migrated[0], "payload");
    try C.set(a, &meta, "history_mode", S("paginated"));
    try C.set(a, &migrated[0], "payload", meta);
    try std.testing.expect(try registrationMatches(a, result.entries, migrated));
    try std.testing.expectEqualStrings(try fingerprint(a, result.entries), try fingerprint(a, migrated));
}
test "Bash history uses file URI and paired completed native tool records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const call = try C.parse(a, "[{\"type\":\"tool_use\",\"id\":\"a\",\"name\":\"Bash\",\"input\":{\"command\":\"pwd\"}}]");
    const output = try C.parse(a, "[{\"type\":\"tool_result\",\"tool_use_id\":\"a\",\"content\":\"/tmp/project\"}]");
    const result = try convert(a, fixtureThread(), &.{ try fixtureEntry(a, "user", S("Run")), try fixtureEntry(a, "assistant", call), try fixtureEntry(a, "user", output), try fixtureEntry(a, "assistant", S("Done")) }, .{});
    try std.testing.expectEqual(@as(usize, 1), result.tool_count);
    var command_seen = false;
    for (result.entries) |row| {
        const item = C.get(C.get(row, "payload"), "item");
        if (is(item, "CommandExecution")) {
            command_seen = true;
            try std.testing.expectEqualStrings("file:///tmp/project", C.s(item, "cwd"));
            try std.testing.expectEqualStrings("/tmp/project", C.s(item, "aggregated_output"));
            try std.testing.expect(C.get(item, "exit_code") == .null);
        }
    }
    try std.testing.expect(command_seen);
    try std.testing.expectEqual(@as(usize, 0), result.warnings.len);
}
test "large single turn preserves request newest answer and total context budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entries = std.array_list.Managed(V).init(a);
    try entries.append(try fixtureEntry(a, "user", S("Original request")));
    const huge = try a.alloc(u8, 100_000);
    @memset(huge, 'x');
    for (0..20) |_| try entries.append(try fixtureEntry(a, "assistant", S(huge)));
    try entries.append(try fixtureEntry(a, "assistant", S("Newest final answer")));
    const result = try convert(a, fixtureThread(), entries.items, .{ .transcript_path = "/native/transcript.jsonl" });
    const last = result.entries[result.entries.len - 1];
    try std.testing.expect(is(last, "compacted"));
    const active_json = try C.json(a, C.get(C.get(last, "payload"), "replacement_history"));
    try std.testing.expect(active_json.len < max_active_bytes);
    try std.testing.expect(std.mem.indexOf(u8, active_json, "Original request") != null);
    try std.testing.expect(std.mem.indexOf(u8, active_json, "Newest final answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, active_json, "excerpt shortened") != null);
    try std.testing.expectEqual(@as(usize, 22), result.message_count);
}
test "private thinking excluded and tool images use input_image" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const call = try C.parse(a, "[{\"type\":\"thinking\",\"thinking\":\"PRIVATE-THOUGHT\"},{\"type\":\"tool_use\",\"id\":\"a\",\"name\":\"Read\",\"input\":{\"file_path\":\"/pic.png\"}}]");
    const output = try C.parse(a, "[{\"type\":\"tool_result\",\"tool_use_id\":\"a\",\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"ZmFrZQ==\"}}]}]");
    const result = try convert(a, fixtureThread(), &.{ try fixtureEntry(a, "user", S("See image")), try fixtureEntry(a, "assistant", call), try fixtureEntry(a, "user", output) }, .{});
    var saw_image = false;
    for (result.entries) |row| {
        const payload = C.get(row, "payload");
        if (is(payload, "function_call_output")) {
            const parts = C.list(C.get(payload, "output"));
            saw_image = parts.len == 1 and is(parts[0], "input_image");
        }
    }
    try std.testing.expect(saw_image);
    try std.testing.expect(std.mem.indexOf(u8, try C.json(a, try C.arr(a, result.entries)), "PRIVATE-THOUGHT") == null);
}

test "provider identities provenance and native guards are explicit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = &.{try fixtureEntry(a, "user", S("Question"))};
    var previous: ?[]const u8 = null;
    for ([_][]const u8{ "claude", "omp", "opencode" }) |provider| {
        const result = try convert(a, fixtureThread(), entries, .{ .source_provider = provider });
        try std.testing.expectEqualStrings(try C.sessionIdFor(a, "codex", provider, fixtureThread().id), result.session_id);
        if (previous) |id| try std.testing.expect(!C.eq(id, result.session_id));
        previous = result.session_id;
        const originator = C.s(C.get(result.entries[0], "payload"), "originator");
        try std.testing.expect(std.mem.startsWith(u8, originator, try C.fmt(a, "c2c:{s}:", .{provider})));
        try std.testing.expect(std.mem.indexOf(u8, try targetPathFor(a, fixtureThread(), "/tmp/codex", provider), result.session_id) != null);
    }
    try std.testing.expectError(error.InvalidCodexSessionId, register(a, "/invalid-do-not-touch", "bad", "title"));
    try std.testing.expectError(error.InvalidCodexSessionId, unregister(a, "/invalid-do-not-touch", "bad"));
}
test "compacted replacement history rejects orphan tool results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = try convert(a, fixtureThread(), &.{try fixtureEntry(a, "user", S("Question"))}, .{});
    var entries = std.array_list.Managed(V).init(a);
    try entries.appendSlice(result.entries);
    const result_item = try C.obj(a, &.{ .{ "type", S("function_call_output") }, .{ "call_id", S("orphan") }, .{ "output", S("content") } });
    try entries.append(try C.obj(a, &.{ .{ "type", S("compacted") }, .{ "timestamp", S(fixtureThread().updated_at) }, .{ "payload", try C.obj(a, &.{.{ "replacement_history", try C.arr(a, &.{result_item}) }}) } }));
    const errors = try validate(a, entries.items);
    try std.testing.expectEqual(@as(usize, 1), errors.len);
    try std.testing.expectEqualStrings("Unpaired tool result", errors[0]);
}

test "Codex removal absence checks live files native metadata and projection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const template = try a.dupeZ(u8, "/tmp/c2c-codex-absence-XXXXXX");
    if (C.c.mkdtemp(template) == null) return error.TemporaryDirectoryFailed;
    const home: []const u8 = template;
    defer _ = C.c.rmdir(template);
    const id = "00000000-0000-0000-0000-000000000123";
    try std.testing.expect(try nativeAbsent(a, home, id));
    const state_path = try C.join(a, &.{ home, "state_5.sqlite" });
    defer C.removeFile(state_path) catch {};
    var db: ?*sqlite.sqlite3 = null;
    try std.testing.expectEqual(@as(c_int, sqlite.SQLITE_OK), sqlite.sqlite3_open(try a.dupeZ(u8, state_path), &db));
    defer _ = sqlite.sqlite3_close(db);
    try std.testing.expectEqual(@as(c_int, sqlite.SQLITE_OK), sqlite.sqlite3_exec(db, "CREATE TABLE threads(id TEXT)", null, null, null));
    try std.testing.expect(try nativeAbsent(a, home, id));
    try std.testing.expectEqual(@as(c_int, sqlite.SQLITE_OK), sqlite.sqlite3_exec(db, "INSERT INTO threads VALUES('00000000-0000-0000-0000-000000000123')", null, null, null));
    try std.testing.expect(!try nativeAbsent(a, home, id));
    try std.testing.expectEqual(@as(c_int, sqlite.SQLITE_OK), sqlite.sqlite3_exec(db, "DELETE FROM threads", null, null, null));
    const history_path = try C.join(a, &.{ home, "thread_history_1.sqlite" });
    defer C.removeFile(history_path) catch {};
    var history: ?*sqlite.sqlite3 = null;
    try std.testing.expectEqual(@as(c_int, sqlite.SQLITE_OK), sqlite.sqlite3_open(try a.dupeZ(u8, history_path), &history));
    defer _ = sqlite.sqlite3_close(history);
    try std.testing.expectEqual(@as(c_int, sqlite.SQLITE_OK), sqlite.sqlite3_exec(history, "CREATE TABLE thread_items(thread_id TEXT); INSERT INTO thread_items VALUES('00000000-0000-0000-0000-000000000123')", null, null, null));
    try std.testing.expect(!try nativeAbsent(a, home, id));
    try std.testing.expectEqual(@as(c_int, sqlite.SQLITE_OK), sqlite.sqlite3_exec(history, "DELETE FROM thread_items", null, null, null));
    const index = try C.join(a, &.{ home, "session_index.jsonl" });
    try C.writeExclusive(index, "{\"id\":\"00000000-0000-0000-0000-000000000123\"}\n");
    defer C.removeFile(index) catch {};
    try std.testing.expect(!try nativeAbsent(a, home, id));
}
