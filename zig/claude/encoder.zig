const std = @import("std");
const common = @import("../common.zig");
const A = common.Allocator;
const V = common.Value;
const str = common.str;
const obj = common.obj;
const arr = common.arr;
const get = common.get;
const s = common.s;
const eq = common.eq;
const list = common.list;
const Values = std.array_list.Managed(V);
const nullv: V = .null;
const native = @import("native.zig");
const namespace = native.namespace;
const version = native.version;
const nativeMessage = native.nativeMessage;
const textBlock = native.textBlock;
const incompleteResult = native.incompleteResult;
const attachmentBlocks = @import("attachments.zig").attachmentBlocks;
const toolResultBlocks = @import("attachments.zig").toolResultBlocks;
const canonicalBlocks = @import("attachments.zig").canonicalBlocks;

fn safeToolName(a: A, name: []const u8) ![]const u8 {
    const result = try a.dupe(u8, name);
    for (result) |*ch| if (!std.ascii.isAlphanumeric(ch.*) and ch.* != '_' and ch.* != '-') {
        ch.* = '_';
    };
    return result;
}

pub const Encoder = struct {
    a: A,
    thread: common.Thread,
    opts: common.ConvertOptions,
    sid: []const u8,
    source_provider: []const u8,
    source_id: []const u8,
    source_label: []const u8,
    entries: Values,
    warnings: common.Warnings,
    parent: ?[]const u8 = null,
    sequence: usize = 0,
    seen_user: bool = false,
    message_count: usize = 0,
    tool_count: usize = 0,
    raw_calls: std.ArrayList(struct { source_id: []const u8, block: V }) = .empty,
    raw_results: std.ArrayList(V) = .empty,
    raw_pending: std.StringHashMapUnmanaged([]const u8) = .empty,
    raw_call_time: []const u8 = "",
    raw_result_time: []const u8 = "",

    pub fn id(self: *Encoder, purpose: []const u8) ![]const u8 {
        return common.uuid5(self.a, namespace, try common.fmt(self.a, "{s}:{s}", .{ self.sid, purpose }));
    }
    pub fn append(self: *Encoder, role: []const u8, content: V, timestamp: []const u8, summary: bool) !void {
        self.sequence += 1;
        const identifier = try self.id(try common.fmt(self.a, "entry:{d}", .{self.sequence}));
        var entry = try obj(self.a, &.{
            .{ "parentUuid", if (self.parent) |p| str(p) else nullv }, .{ "isSidechain", common.boolean(false) },
            .{ "userType", str("external") },                          .{ "entrypoint", str("cli") },
            .{ "cwd", str(self.thread.cwd) },                          .{ "sessionId", str(self.sid) },
            .{ "version", str(version) },                              .{ "gitBranch", str("") },
            .{ "type", str(role) },                                    .{ "message", try nativeMessage(self.a, role, content, identifier) },
            .{ "uuid", str(identifier) },                              .{ "timestamp", str(if (timestamp.len > 0) timestamp else if (self.thread.updated_at.len > 0) self.thread.updated_at else self.thread.created_at) },
        });
        if (summary) try common.set(self.a, &entry, "isCompactSummary", common.boolean(true));
        try self.entries.append(entry);
        self.parent = identifier;
        if (eq(role, "user")) self.seen_user = true;
        self.message_count += 1;
    }
    fn tool(self: *Encoder, name: []const u8, args: V, output: V, timestamp: []const u8, failed: bool) !void {
        const stable = try self.id(try common.fmt(self.a, "tool:{d}", .{self.sequence}));
        const tool_id = try common.fmt(self.a, "toolu_codex_{s}", .{try std.mem.replaceOwned(u8, self.a, stable, "-", "")});
        const use = try obj(self.a, &.{ .{ "type", str("tool_use") }, .{ "id", str(tool_id) }, .{ "name", str(name) }, .{ "input", args } });
        const result = try obj(self.a, &.{ .{ "type", str("tool_result") }, .{ "tool_use_id", str(tool_id) }, .{ "content", output }, .{ "is_error", common.boolean(failed) } });
        try self.append("assistant", try arr(self.a, &.{use}), timestamp, false);
        try self.append("user", try arr(self.a, &.{result}), timestamp, false);
        self.tool_count += 1;
    }
    pub fn flushRaw(self: *Encoder) !void {
        if (self.raw_calls.items.len == 0) return;
        var calls = Values.init(self.a);
        for (self.raw_calls.items) |call| {
            try calls.append(call.block);
            if (self.raw_pending.contains(call.source_id)) {
                var incomplete = try incompleteResult(self.a, s(call.block, "id"));
                try common.set(self.a, &incomplete, "content", str("[Historical tool had no matching saved result before the next visible record or end of captured history. Any later output is preserved separately; it was not run by this import.]"));
                try self.raw_results.append(self.a, incomplete);
                try self.warnings.append("Raw Codex tool had no saved result before the next visible record; closed as historical without execution");
            }
        }
        try self.append("assistant", .{ .array = calls }, self.raw_call_time, false);
        try self.append("user", try arr(self.a, self.raw_results.items), if (self.raw_result_time.len > 0) self.raw_result_time else self.raw_call_time, false);
        self.tool_count += self.raw_calls.items.len;
        self.raw_calls.clearRetainingCapacity();
        self.raw_results.clearRetainingCapacity();
        self.raw_pending.clearRetainingCapacity();
        self.raw_call_time = "";
        self.raw_result_time = "";
    }
    fn rawOutput(self: *Encoder, item: common.Item) !V {
        const value = get(item.raw orelse nullv, "output");
        if (value == .string) return value;
        if (value == .object and get(value, "content") == .array) return toolResultBlocks(self.a, value, &self.warnings, self.opts.embed_images);
        if (value != .array) return str(try common.json(self.a, value));
        var output = Values.init(self.a);
        var attachment_index: usize = 0;
        for (value.array.items) |part| {
            const kind = s(part, "type");
            if (eq(kind, "text") or eq(kind, "input_text") or eq(kind, "output_text")) {
                try output.append(try textBlock(self.a, s(part, "text")));
            } else if (!eq(kind, "reasoning") and !eq(kind, "encrypted_text")) {
                // Reuse normalized attachments in their original block order.
                if (attachment_index < item.attachments.len) {
                    try output.appendSlice(try attachmentBlocks(self.a, item.attachments[attachment_index .. attachment_index + 1], &self.warnings, self.opts.embed_images));
                    attachment_index += 1;
                } else if (eq(kind, "input_image") or eq(kind, "image_url") or (eq(kind, "image") and get(part, "source") == .null)) {
                    var attachment = part;
                    if (s(part, "data").len > 0) attachment = try obj(self.a, &.{.{ "url", str(try common.fmt(self.a, "data:{s};base64,{s}", .{ if (s(part, "mimeType").len > 0) s(part, "mimeType") else "image/png", s(part, "data") })) }});
                    try output.appendSlice(try attachmentBlocks(self.a, &.{attachment}, &self.warnings, self.opts.embed_images));
                } else if (eq(kind, "image") and get(part, "source") == .object) {
                    const image = try canonicalBlocks(self.a, try arr(self.a, &.{part}), &self.warnings, self.opts.embed_images);
                    try output.appendSlice(list(image));
                } else try output.append(try textBlock(self.a, try common.json(self.a, part)));
            }
        }
        if (output.items.len == 0) try output.append(try textBlock(self.a, "(empty historical tool result)"));
        return .{ .array = output };
    }
    fn emitRaw(self: *Encoder, item: common.Item) !void {
        const raw = item.raw orelse nullv;
        const call_id = s(raw, "call_id");
        if (eq(item.kind, "function_call") or eq(item.kind, "custom_tool_call")) {
            // Start a new exchange after any output; preserve call and result order within each batch.
            if (self.raw_results.items.len > 0) try self.flushRaw();
            if (call_id.len == 0 or self.raw_pending.contains(call_id)) return error.InvalidRawCodexToolIdentity;
            var args = get(raw, if (eq(item.kind, "custom_tool_call")) "input" else "arguments");
            if (eq(item.kind, "custom_tool_call")) {
                args = try obj(self.a, &.{.{ "input", args }});
            } else if (args == .string) {
                args = common.parse(self.a, args.string) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => try obj(self.a, &.{.{ "raw_arguments", args }}),
                };
            }
            if (args == .null) args = try obj(self.a, &.{});
            if (args != .object) args = try obj(self.a, &.{.{ "value", args }});
            const stable = try self.id(try common.fmt(self.a, "rawtool:{d}:{d}:{s}", .{ self.sequence, self.raw_calls.items.len, call_id }));
            const tool_id = try common.fmt(self.a, "toolu_codex_{s}", .{try std.mem.replaceOwned(u8, self.a, stable, "-", "")});
            const name = try safeToolName(self.a, if (s(raw, "name").len > 0) s(raw, "name") else "historical_tool");
            const block = try obj(self.a, &.{ .{ "type", str("tool_use") }, .{ "id", str(tool_id) }, .{ "name", str(name) }, .{ "input", args } });
            if (self.raw_calls.items.len == 0) self.raw_call_time = item.timestamp;
            try self.raw_calls.append(self.a, .{ .source_id = call_id, .block = block });
            try self.raw_pending.put(self.a, call_id, tool_id);
        } else if (self.raw_pending.fetchRemove(call_id)) |mapping| {
            const output = try self.rawOutput(item);
            const failed = common.b(get(raw, "is_error")) or common.b(get(raw, "isError")) or common.b(get(get(raw, "output"), "isError"));
            const block = try obj(self.a, &.{ .{ "type", str("tool_result") }, .{ "tool_use_id", str(mapping.value) }, .{ "content", output }, .{ "is_error", common.boolean(failed) } });
            try self.raw_results.append(self.a, block);
            self.raw_result_time = item.timestamp;
            if (self.raw_pending.count() == 0) try self.flushRaw();
        } else {
            try self.flushRaw();
            const detail = try common.fmt(self.a, "[Historical Codex tool result without an available call]\n{s}", .{try common.json(self.a, raw)});
            try self.append("assistant", try arr(self.a, &.{try textBlock(self.a, detail)}), item.timestamp, false);
            if (item.attachments.len > 0) try self.append("user", try arr(self.a, try attachmentBlocks(self.a, item.attachments, &self.warnings, self.opts.embed_images)), item.timestamp, false);
            try self.warnings.append("Raw Codex tool result had no available call; preserved its complete payload as a historical artifact");
        }
    }
    pub fn emit(self: *Encoder, item: common.Item) anyerror!void {
        if (eq(item.kind, "reasoning") or eq(item.kind, "hookPrompt") or eq(item.kind, "system") or eq(item.kind, "developer") or eq(item.kind, "contextCompaction")) return;
        const raw = item.raw orelse nullv;
        if (!self.seen_user and !eq(item.role, "user")) try self.append("user", str(try common.fmt(self.a, "Continue this imported {s} conversation. The following entries are its saved history.", .{self.source_label})), self.thread.created_at, false);
        if (eq(item.kind, "function_call") or eq(item.kind, "custom_tool_call") or eq(item.kind, "function_call_output") or eq(item.kind, "custom_tool_call_output")) {
            try self.emitRaw(item);
            return;
        }
        try self.flushRaw();
        if (eq(item.kind, "commandExecution")) {
            const status = if (s(raw, "status").len > 0) s(raw, "status") else "unknown";
            const value = get(raw, "aggregatedOutput");
            const original = if (value == .string) value.string else if (value == .null) "" else try common.json(self.a, value);
            const exit_code = get(raw, "exitCode");
            var output = try common.fmt(self.a, "{s}\n[Imported command status: {s}; exit code: {s}]", .{ original, status, try common.json(self.a, exit_code) });
            if (!eq(status, "completed") and !eq(status, "failed") and !eq(status, "declined")) output = try common.fmt(self.a, "{s}\nThis process belonged to {s} and was not resumed or executed by the import.", .{ output, self.source_label });
            const description = if (s(raw, "cwd").len > 0) try common.fmt(self.a, "Imported {s} command (cwd: {s})", .{ self.source_label, s(raw, "cwd") }) else try common.fmt(self.a, "Imported {s} command", .{self.source_label});
            const args = try obj(self.a, &.{ .{ "command", if (get(raw, "command") != .null) get(raw, "command") else str(item.text) }, .{ "description", str(description) } });
            try self.tool("Bash", args, str(output), item.timestamp, eq(status, "failed") or eq(status, "declined") or (exit_code != .null and common.integer(exit_code) != 0));
            return;
        }
        if (eq(item.kind, "mcpToolCall")) {
            const server = if (s(raw, "server").len > 0) s(raw, "server") else "codex";
            const tool_name = if (s(raw, "tool").len > 0) s(raw, "tool") else "historical_tool";
            const name = try common.fmt(self.a, "mcp__{s}__{s}", .{ try safeToolName(self.a, server), try safeToolName(self.a, tool_name) });
            var args = get(raw, "arguments");
            if (args == .null) args = try obj(self.a, &.{});
            if (args != .object) args = try obj(self.a, &.{.{ "value", args }});
            const value = if (get(raw, "result") != .null) get(raw, "result") else get(raw, "error");
            var output = try toolResultBlocks(self.a, value, &self.warnings, self.opts.embed_images);
            if (!eq(s(raw, "status"), "completed") and !eq(s(raw, "status"), "failed")) {
                const notice = "[Historical tool did not complete in its source session; it was not run by this import.]";
                if (output == .string) output = str(try common.fmt(self.a, "{s}\n{s}", .{ output.string, notice })) else try output.array.append(try textBlock(self.a, notice));
            }
            try self.tool(name, args, output, item.timestamp, eq(s(raw, "status"), "failed") or get(raw, "error") != .null or common.b(get(value, "isError")));
            return;
        }
        if (eq(item.kind, "imageView") and s(raw, "path").len > 0) {
            const attachments = if (item.attachments.len > 0) item.attachments else &[_]V{try obj(self.a, &.{.{ "path", get(raw, "path") }})};
            const blocks = try attachmentBlocks(self.a, attachments, &self.warnings, self.opts.embed_images);
            try self.tool("Read", try obj(self.a, &.{.{ "file_path", get(raw, "path") }}), try arr(self.a, blocks), item.timestamp, false);
            return;
        }
        if (eq(item.role, "user")) {
            var blocks = Values.init(self.a);
            if (item.text.len > 0) try blocks.append(try textBlock(self.a, item.text));
            try blocks.appendSlice(try attachmentBlocks(self.a, item.attachments, &self.warnings, self.opts.embed_images));
            if (blocks.items.len > 0) try self.append("user", .{ .array = blocks }, item.timestamp, false);
            return;
        }
        if (eq(item.kind, "agentMessage") or eq(item.kind, "message") or eq(item.kind, "assistant") or eq(item.kind, "response_item") or raw == .null or (raw == .object and raw.object.count() == 0)) {
            if (item.text.len > 0) try self.append("assistant", try arr(self.a, &.{try textBlock(self.a, item.text)}), item.timestamp, false);
        } else {
            const detail = try common.fmt(self.a, "[Historical {s} {s}]\n{s}", .{ self.source_label, item.kind, try common.json(self.a, raw) });
            try self.append("assistant", try arr(self.a, &.{try textBlock(self.a, detail)}), item.timestamp, false);
        }
        if (item.attachments.len > 0) try self.append("user", try arr(self.a, try attachmentBlocks(self.a, item.attachments, &self.warnings, self.opts.embed_images)), item.timestamp, false);
    }
    pub fn boundary(self: *Encoder, timestamp: []const u8) !void {
        self.sequence += 1;
        const identifier = try self.id(try common.fmt(self.a, "entry:{d}", .{self.sequence}));
        try self.entries.append(try obj(self.a, &.{
            .{ "parentUuid", .null },                                                                                    .{ "logicalParentUuid", if (self.parent) |p| str(p) else nullv }, .{ "isSidechain", common.boolean(false) },
            .{ "userType", str("external") },                                                                            .{ "entrypoint", str("cli") },                                    .{ "cwd", str(self.thread.cwd) },
            .{ "sessionId", str(self.sid) },                                                                             .{ "version", str(version) },                                     .{ "type", str("system") },
            .{ "subtype", str("compact_boundary") },                                                                     .{ "content", str("Conversation compacted") },                    .{ "level", str("info") },
            .{ "isMeta", common.boolean(false) },                                                                        .{ "uuid", str(identifier) },                                     .{ "timestamp", str(timestamp) },
            .{ "compactMetadata", try obj(self.a, &.{ .{ "trigger", str("auto") }, .{ "preTokens", common.num(0) } }) },
        }));
        self.parent = identifier;
    }
    pub fn sourceBoundary(self: *Encoder, compaction: common.Compaction) anyerror!void {
        if (compaction.summary.len == 0) return;
        try self.flushRaw();
        const timestamp = compaction.timestamp orelse self.thread.updated_at;
        try self.boundary(timestamp);
        try self.append("user", str(try common.fmt(self.a, "[Context summary saved by {s} before migration]\n{s}", .{ self.source_label, compaction.summary })), timestamp, true);
        for (compaction.items) |item| try self.emit(item);
    }
};
