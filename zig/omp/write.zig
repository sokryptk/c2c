const std = @import("std");
const C = @import("../common.zig");
const A = C.Allocator;
const V = C.Value;
const S = C.str;
const Values = std.array_list.Managed(V);
const F = @import("format.zig");
const N = C.num;
const recent_bytes = 170_000;

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
    const ts = try F.stamp(a, S(thread.created_at), thread.updated_at);
    const filename_ts = try a.dupe(u8, ts);
    for (filename_ts) |*ch| if (ch.* == ':') {
        ch.* = '-';
    };
    const id = try C.sessionIdFor(a, "omp", thread.provider, thread.id);
    return C.join(a, &.{ home, "sessions", try bucket(a, thread.cwd), try C.fmt(a, "{s}_{s}.jsonl", .{ filename_ts, id }) });
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
        return C.uuid5(self.a, F.entry_namespace, try C.fmt(self.a, "{s}:{s}:{d}", .{ self.id, label, self.counter }));
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
        if (F.is(block, "thinking") or F.is(block, "redacted_thinking")) return null;
        if (F.is(block, "text")) return try C.obj(self.a, &.{ .{ "type", S("text") }, .{ "text", S(C.s(block, "text")) } });
        if (F.is(block, "image")) {
            const source = C.get(block, "source");
            const data = C.s(source, "data");
            const mime = C.s(source, "media_type");
            if (self.opts.embed_images and F.is(source, "base64") and std.mem.startsWith(u8, mime, "image/")) {
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
            for (content) |block| if (F.is(block, "toolCall")) {
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
        for (try F.blocks(self.a, raw)) |part| if (try self.nativeContent(part)) |native| try content.append(native);
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
        const bytes = try F.activeBytes(self.a, self.rows.items);
        var starts = std.array_list.Managed(usize).init(self.a);
        var unfinished = std.StringHashMap(void).init(self.a);
        for (self.rows.items[self.active_start..], self.active_start..) |row, i| {
            if (!F.is(row, "message")) continue;
            const active_message = C.get(row, "message");
            const role = C.s(active_message, "role");
            if (starts.items.len == 0 or (C.eq(role, "user") and unfinished.count() == 0)) try starts.append(i);
            if (C.eq(role, "assistant")) {
                for (C.list(C.get(active_message, "content"))) |part| if (F.is(part, "toolCall")) try unfinished.put(C.s(part, "id"), {});
            } else if (C.eq(role, "toolResult")) _ = unfinished.remove(C.s(active_message, "toolCallId"));
        }
        if (bytes <= F.max_active_bytes) return;
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
                if (!F.is(row, "message")) continue;
                const msg = C.get(row, "message");
                const role = C.s(msg, "role");
                if (C.eq(role, "user") and row_index == newest_start) latest_user = msg else if (C.eq(role, "assistant")) {
                    var has_text = false;
                    for (C.list(C.get(msg, "content"))) |part| if (F.is(part, "text") and C.s(part, "text").len > 0) {
                        has_text = true;
                    };
                    if (has_text) latest_answer = msg;
                }
            }
            try self.compact(notice, "", timestamp);
            for ([_]?V{ latest_user, latest_answer }) |maybe| if (maybe) |msg| {
                const text = try F.textOf(self.a, C.list(C.get(msg, "content")));
                const excerpt = try jsonExcerpt(self.a, text, 35_000);
                try self.message(C.s(msg, "role"), &.{try C.obj(self.a, &.{ .{ "type", S("text") }, .{ "text", S(try C.fmt(self.a, "{s}{s}", .{ excerpt, if (text.len > excerpt.len) "\n[c2c: excerpt shortened; full content remains in the transcript.]" else "" })) } })}, timestamp);
            };
        }
        if (try F.activeBytes(self.a, self.rows.items) > F.max_active_bytes) return error.OmpContextBudgetExceeded;
        try self.warnings.append("Large source history retained in full; OMP active context uses a labelled recent window");
    }
};

pub fn convert(a: A, thread: C.Thread, entries: []const V, opts: C.ConvertOptions) !C.Conversion {
    const provider = opts.source_provider orelse thread.provider;
    const source_id = opts.source_session_id orelse thread.id;
    const id = try C.sessionIdFor(a, "omp", provider, source_id);
    var self = Builder{ .a = a, .thread = thread, .opts = opts, .id = id, .rows = Values.init(a), .pending = std.array_list.Managed(Pending).init(a), .warnings = C.Warnings.init(a) };
    const created = try F.stamp(a, S(thread.created_at), thread.updated_at);
    try self.rows.append(try C.obj(a, &.{ .{ "type", S("session") }, .{ "version", N(3) }, .{ "id", S(id) }, .{ "timestamp", S(created) }, .{ "cwd", S(thread.cwd) }, .{ "title", S(thread.title) }, .{ "titleSource", S("user") } }));
    const origin = try C.obj(a, &.{ .{ "version", N(1) }, .{ "sourceProvider", S(provider) }, .{ "sourceSessionId", S(source_id) } });
    _ = try self.append("custom", &.{ .{ "customType", S(F.provenance_type) }, .{ "data", origin } }, created);
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
        const role = F.fallback(C.s(msg, "role"), C.s(entry, "type"));
        if (!C.eq(role, "user") and !C.eq(role, "assistant")) continue;
        source_count += 1;
        last = try F.stamp(a, C.get(entry, "timestamp"), thread.updated_at);
        const input = try F.blocks(a, C.get(msg, "content"));
        if (C.b(C.get(entry, "isCompactSummary")) or (summary_pending and C.eq(role, "user"))) {
            try self.flush(last);
            try self.compact(try F.textOf(a, input), "", last);
            summary_pending = false;
            self.messages += 1;
            continue;
        }
        var has_result = false;
        for (input) |part| if (F.is(part, "tool_result")) {
            has_result = true;
        };
        if (C.eq(role, "user") and !has_result) try self.flush(last);
        var content = Values.init(a);
        for (input) |part| {
            if (F.is(part, "tool_use")) {
                if (!C.eq(role, "assistant")) return error.ToolCallOutsideAssistant;
                const given = C.s(part, "id");
                const old = if (given.len > 0) given else try self.next("missing-source-tool-id");
                for (self.pending.items) |p| if (C.eq(p.source_id, old)) return error.DuplicatePendingToolId;
                const call = try self.next("call");
                const name = F.fallback(C.s(part, "name"), "historical_tool");
                try self.pending.append(.{ .source_id = old, .id = call, .name = name });
                const args = C.get(part, "input");
                try content.append(try C.obj(a, &.{ .{ "type", S("toolCall") }, .{ "id", S(call) }, .{ "name", S(name) }, .{ "arguments", if (args == .null) try C.obj(a, &.{}) else try C.clone(a, args) } }));
            } else if (F.is(part, "tool_result")) {
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
    try C.set(a, &data, "fingerprint", S(try F.fingerprint(a, self.rows.items)));
    try C.set(a, &marker, "data", data);
    self.rows.items[1] = marker;
    if ((try F.validate(a, self.rows.items)).len > 0) return error.InvalidOmpRollout;
    return .{ .entries = try self.rows.toOwnedSlice(), .warnings = try self.warnings.toOwnedSlice(), .message_count = self.messages, .tool_count = self.tools, .source_item_count = source_count, .session_id = id };
}
