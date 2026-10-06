const std = @import("std");
const common = @import("../common.zig");
const Allocator = common.Allocator;
const Value = common.Value;
const jsonString = common.str;
const jsonObject = common.obj;
const jsonArray = common.arr;
const field = common.get;
const stringField = common.stringField;
const equal = common.eq;
const elements = common.list;
const ValueList = std.array_list.Managed(Value);
const nullv: Value = .null;
const native = @import("native.zig");
const namespace = native.namespace;
const version = native.version;
const nativeMessage = native.nativeMessage;
const textBlock = native.textBlock;
const incompleteResult = native.incompleteResult;
const attachmentBlocks = @import("attachments.zig").attachmentBlocks;
const toolResultBlocks = @import("attachments.zig").toolResultBlocks;
const canonicalBlocks = @import("attachments.zig").canonicalBlocks;

fn safeToolName(allocator: Allocator, name: []const u8) ![]const u8 {
    const result = try allocator.dupe(u8, name);
    for (result) |*ch| {
        if (!std.ascii.isAlphanumeric(ch.*) and ch.* != '_' and ch.* != '-') {
            ch.* = '_';
        }
    }
    return result;
}

pub const Encoder = struct {
    allocator: Allocator,
    thread: common.Thread,
    opts: common.ConvertOptions,
    sid: []const u8,
    source_provider: []const u8,
    source_id: []const u8,
    source_label: []const u8,
    entries: ValueList,
    warnings: common.Warnings,
    parent: ?[]const u8 = null,
    sequence: usize = 0,
    seen_user: bool = false,
    message_count: usize = 0,
    tool_count: usize = 0,
    raw_calls: std.ArrayList(struct {
        source_id: []const u8,
        block: Value,
    }) = .empty,
    raw_results: std.ArrayList(Value) = .empty,
    raw_pending: std.StringHashMapUnmanaged([]const u8) = .empty,
    raw_call_time: []const u8 = "",
    raw_result_time: []const u8 = "",

    pub fn id(self: *Encoder, purpose: []const u8) ![]const u8 {
        const name = try common.fmt(self.allocator, "{s}:{s}", .{ self.sid, purpose });
        return common.uuid5(self.allocator, namespace, name);
    }

    pub fn append(
        self: *Encoder,
        role: []const u8,
        content: Value,
        timestamp: []const u8,
        summary: bool,
    ) !void {
        self.sequence += 1;
        const purpose = try common.fmt(self.allocator, "entry:{d}", .{self.sequence});
        const identifier = try self.id(purpose);
        const message = try nativeMessage(self.allocator, role, content, identifier);
        const entry_timestamp = if (timestamp.len > 0)
            timestamp
        else if (self.thread.updated_at.len > 0)
            self.thread.updated_at
        else
            self.thread.created_at;
        var entry = try jsonObject(self.allocator, &.{
            .{ "parentUuid", if (self.parent) |p| jsonString(p) else nullv },
            .{ "isSidechain", common.boolean(false) },
            .{ "userType", jsonString("external") },
            .{ "entrypoint", jsonString("cli") },
            .{ "cwd", jsonString(self.thread.cwd) },
            .{ "sessionId", jsonString(self.sid) },
            .{ "version", jsonString(version) },
            .{ "gitBranch", jsonString("") },
            .{ "type", jsonString(role) },
            .{ "message", message },
            .{ "uuid", jsonString(identifier) },
            .{ "timestamp", jsonString(entry_timestamp) },
        });
        if (summary) {
            try common.set(self.allocator, &entry, "isCompactSummary", common.boolean(true));
        }
        try self.entries.append(entry);
        self.parent = identifier;
        if (equal(role, "user")) {
            self.seen_user = true;
        }
        self.message_count += 1;
    }

    fn tool(
        self: *Encoder,
        name: []const u8,
        args: Value,
        output: Value,
        timestamp: []const u8,
        failed: bool,
    ) !void {
        const purpose = try common.fmt(self.allocator, "tool:{d}", .{self.sequence});
        const stable = try self.id(purpose);
        const compact_id = try std.mem.replaceOwned(u8, self.allocator, stable, "-", "");
        const tool_id = try common.fmt(self.allocator, "toolu_codex_{s}", .{compact_id});
        const use = try jsonObject(self.allocator, &.{
            .{ "type", jsonString("tool_use") },
            .{ "id", jsonString(tool_id) },
            .{ "name", jsonString(name) },
            .{ "input", args },
        });
        const result = try jsonObject(self.allocator, &.{
            .{ "type", jsonString("tool_result") },
            .{ "tool_use_id", jsonString(tool_id) },
            .{ "content", output },
            .{ "is_error", common.boolean(failed) },
        });
        try self.append("assistant", try jsonArray(self.allocator, &.{use}), timestamp, false);
        try self.append("user", try jsonArray(self.allocator, &.{result}), timestamp, false);
        self.tool_count += 1;
    }
    pub fn flushRaw(self: *Encoder) !void {
        if (self.raw_calls.items.len == 0) {
            return;
        }
        var calls = ValueList.init(self.allocator);
        for (self.raw_calls.items) |call| {
            try calls.append(call.block);
            if (self.raw_pending.contains(call.source_id)) {
                var incomplete = try incompleteResult(self.allocator, stringField(call.block, "id"));
                const notice = "[Historical tool had no matching saved result before the next visible record " ++
                    "or end of captured history. Any later output is preserved separately; " ++
                    "it was not run by this import.]";
                try common.set(self.allocator, &incomplete, "content", jsonString(notice));
                try self.raw_results.append(self.allocator, incomplete);
                try self.warnings.append(
                    "Raw Codex tool had no saved result before the next visible record; " ++
                        "closed as historical without execution",
                );
            }
        }
        try self.append("assistant", .{ .array = calls }, self.raw_call_time, false);
        const results = try jsonArray(self.allocator, self.raw_results.items);
        const result_time = if (self.raw_result_time.len > 0) self.raw_result_time else self.raw_call_time;
        try self.append("user", results, result_time, false);
        self.tool_count += self.raw_calls.items.len;
        self.raw_calls.clearRetainingCapacity();
        self.raw_results.clearRetainingCapacity();
        self.raw_pending.clearRetainingCapacity();
        self.raw_call_time = "";
        self.raw_result_time = "";
    }
    fn rawOutput(self: *Encoder, item: common.Item) !Value {
        const value = field(item.raw orelse nullv, "output");
        if (value == .string) {
            return value;
        }
        if (value == .object and field(value, "content") == .array) {
            return toolResultBlocks(self.allocator, value, &self.warnings, self.opts.embed_images);
        }
        if (value != .array) {
            return jsonString(try common.json(self.allocator, value));
        }
        var output = ValueList.init(self.allocator);
        var attachment_index: usize = 0;
        for (value.array.items) |part| {
            const kind = stringField(part, "type");
            if (equal(kind, "text") or equal(kind, "input_text") or equal(kind, "output_text")) {
                try output.append(try textBlock(self.allocator, stringField(part, "text")));
            } else if (!equal(kind, "reasoning") and !equal(kind, "encrypted_text")) {
                // Reuse normalized attachments in their original block order.
                if (attachment_index < item.attachments.len) {
                    const attachment = item.attachments[attachment_index .. attachment_index + 1];
                    const converted_blocks = try attachmentBlocks(
                        self.allocator,
                        attachment,
                        &self.warnings,
                        self.opts.embed_images,
                    );
                    try output.appendSlice(converted_blocks);
                    attachment_index += 1;
                } else if (equal(kind, "input_image") or equal(kind, "image_url") or
                    (equal(kind, "image") and field(part, "source") == .null))
                {
                    var attachment = part;
                    const image_data = stringField(part, "data");
                    if (image_data.len > 0) {
                        const saved_mime_type = stringField(part, "mimeType");
                        const mime_type = if (saved_mime_type.len > 0) saved_mime_type else "image/png";
                        const url = try common.fmt(self.allocator, "data:{s};base64,{s}", .{ mime_type, image_data });
                        attachment = try jsonObject(self.allocator, &.{.{ "url", jsonString(url) }});
                    }
                    const converted_blocks = try attachmentBlocks(
                        self.allocator,
                        &.{attachment},
                        &self.warnings,
                        self.opts.embed_images,
                    );
                    try output.appendSlice(converted_blocks);
                } else if (equal(kind, "image") and field(part, "source") == .object) {
                    const content = try jsonArray(self.allocator, &.{part});
                    const image = try canonicalBlocks(self.allocator, content, &self.warnings, self.opts.embed_images);
                    try output.appendSlice(elements(image));
                } else {
                    const payload = try common.json(self.allocator, part);
                    const text = try textBlock(self.allocator, payload);
                    try output.append(text);
                }
            }
        }
        if (output.items.len == 0) {
            const empty_result = try textBlock(self.allocator, "(empty historical tool result)");
            try output.append(empty_result);
        }
        return .{ .array = output };
    }
    fn emitRaw(self: *Encoder, item: common.Item) !void {
        const raw = item.raw orelse nullv;
        const call_id = stringField(raw, "call_id");
        if (equal(item.kind, "function_call") or equal(item.kind, "custom_tool_call")) {
            // Start a new exchange after any output; preserve call and result order within each batch.
            if (self.raw_results.items.len > 0) {
                try self.flushRaw();
            }
            if (call_id.len == 0 or self.raw_pending.contains(call_id)) {
                return error.InvalidRawCodexToolIdentity;
            }
            var args = field(raw, if (equal(item.kind, "custom_tool_call")) "input" else "arguments");
            if (equal(item.kind, "custom_tool_call")) {
                args = try jsonObject(self.allocator, &.{.{ "input", args }});
            } else if (args == .string) {
                args = common.parse(self.allocator, args.string) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => try jsonObject(self.allocator, &.{.{ "raw_arguments", args }}),
                };
            }
            if (args == .null) {
                args = try jsonObject(self.allocator, &.{});
            }
            if (args != .object) {
                args = try jsonObject(self.allocator, &.{.{ "value", args }});
            }
            const purpose = try common.fmt(self.allocator, "rawtool:{d}:{d}:{s}", .{
                self.sequence,
                self.raw_calls.items.len,
                call_id,
            });
            const stable = try self.id(purpose);
            const compact_id = try std.mem.replaceOwned(u8, self.allocator, stable, "-", "");
            const tool_id = try common.fmt(self.allocator, "toolu_codex_{s}", .{compact_id});
            const saved_name = stringField(raw, "name");
            const name = try safeToolName(self.allocator, if (saved_name.len > 0) saved_name else "historical_tool");
            const block = try jsonObject(self.allocator, &.{
                .{ "type", jsonString("tool_use") },
                .{ "id", jsonString(tool_id) },
                .{ "name", jsonString(name) },
                .{ "input", args },
            });
            if (self.raw_calls.items.len == 0) {
                self.raw_call_time = item.timestamp;
            }
            try self.raw_calls.append(self.allocator, .{ .source_id = call_id, .block = block });
            try self.raw_pending.put(self.allocator, call_id, tool_id);
        } else if (self.raw_pending.fetchRemove(call_id)) |mapping| {
            const output = try self.rawOutput(item);
            const failed = common.boolValue(field(raw, "is_error")) or
                common.boolValue(field(raw, "isError")) or
                common.boolValue(field(field(raw, "output"), "isError"));
            const block = try jsonObject(self.allocator, &.{
                .{ "type", jsonString("tool_result") },
                .{ "tool_use_id", jsonString(mapping.value) },
                .{ "content", output },
                .{ "is_error", common.boolean(failed) },
            });
            try self.raw_results.append(self.allocator, block);
            self.raw_result_time = item.timestamp;
            if (self.raw_pending.count() == 0) {
                try self.flushRaw();
            }
        } else {
            try self.flushRaw();
            const payload = try common.json(self.allocator, raw);
            const detail = try common.fmt(self.allocator, "[Historical Codex tool result without an available call]\n{s}", .{payload});
            const text = try textBlock(self.allocator, detail);
            const content = try jsonArray(self.allocator, &.{text});
            try self.append("assistant", content, item.timestamp, false);
            if (item.attachments.len > 0) {
                const converted_blocks = try attachmentBlocks(
                    self.allocator,
                    item.attachments,
                    &self.warnings,
                    self.opts.embed_images,
                );
                const attachment_content = try jsonArray(self.allocator, converted_blocks);
                try self.append("user", attachment_content, item.timestamp, false);
            }
            try self.warnings.append(
                "Raw Codex tool result had no available call; " ++
                    "preserved its complete payload as a historical artifact",
            );
        }
    }
    pub fn emit(self: *Encoder, item: common.Item) anyerror!void {
        if (equal(item.kind, "reasoning") or equal(item.kind, "hookPrompt") or
            equal(item.kind, "system") or equal(item.kind, "developer") or
            equal(item.kind, "contextCompaction"))
        {
            return;
        }
        const raw = item.raw orelse nullv;
        if (!self.seen_user and !equal(item.role, "user")) {
            const introduction = try common.fmt(
                self.allocator,
                "Continue this imported {s} conversation. The following entries are its saved history.",
                .{self.source_label},
            );
            try self.append("user", jsonString(introduction), self.thread.created_at, false);
        }
        if (equal(item.kind, "function_call") or equal(item.kind, "custom_tool_call") or
            equal(item.kind, "function_call_output") or equal(item.kind, "custom_tool_call_output"))
        {
            try self.emitRaw(item);
            return;
        }
        try self.flushRaw();
        if (equal(item.kind, "commandExecution")) {
            const saved_status = stringField(raw, "status");
            const status = if (saved_status.len > 0) saved_status else "unknown";
            const value = field(raw, "aggregatedOutput");
            const original = switch (value) {
                .string => value.string,
                .null => "",
                else => try common.json(self.allocator, value),
            };
            const exit_code = field(raw, "exitCode");
            const exit_code_json = try common.json(self.allocator, exit_code);
            var output = try common.fmt(self.allocator, "{s}\n[Imported command status: {s}; exit code: {s}]", .{
                original,
                status,
                exit_code_json,
            });
            if (!equal(status, "completed") and !equal(status, "failed") and !equal(status, "declined")) {
                output = try common.fmt(
                    self.allocator,
                    "{s}\nThis process belonged to {s} and was not resumed or executed by the import.",
                    .{ output, self.source_label },
                );
            }
            const cwd = stringField(raw, "cwd");
            const description = if (cwd.len > 0)
                try common.fmt(self.allocator, "Imported {s} command (cwd: {s})", .{ self.source_label, cwd })
            else
                try common.fmt(self.allocator, "Imported {s} command", .{self.source_label});
            const command = field(raw, "command");
            const args = try jsonObject(self.allocator, &.{
                .{ "command", if (command != .null) command else jsonString(item.text) },
                .{ "description", jsonString(description) },
            });
            const failed = equal(status, "failed") or equal(status, "declined") or
                (exit_code != .null and common.integer(exit_code) != 0);
            try self.tool("Bash", args, jsonString(output), item.timestamp, failed);
            return;
        }
        if (equal(item.kind, "mcpToolCall")) {
            const saved_server = stringField(raw, "server");
            const server = if (saved_server.len > 0) saved_server else "codex";
            const saved_tool_name = stringField(raw, "tool");
            const tool_name = if (saved_tool_name.len > 0) saved_tool_name else "historical_tool";
            const safe_server = try safeToolName(self.allocator, server);
            const safe_tool_name = try safeToolName(self.allocator, tool_name);
            const name = try common.fmt(self.allocator, "mcp__{s}__{s}", .{ safe_server, safe_tool_name });
            var args = field(raw, "arguments");
            if (args == .null) {
                args = try jsonObject(self.allocator, &.{});
            }
            if (args != .object) {
                args = try jsonObject(self.allocator, &.{.{ "value", args }});
            }
            const saved_result = field(raw, "result");
            const value = if (saved_result != .null) saved_result else field(raw, "error");
            var output = try toolResultBlocks(self.allocator, value, &self.warnings, self.opts.embed_images);
            const status = stringField(raw, "status");
            if (!equal(status, "completed") and !equal(status, "failed")) {
                const notice = "[Historical tool did not complete in its source session; it was not run by this import.]";
                if (output == .string) {
                    const text = try common.fmt(self.allocator, "{s}\n{s}", .{ output.string, notice });
                    output = jsonString(text);
                } else {
                    const text = try textBlock(self.allocator, notice);
                    try output.array.append(text);
                }
            }
            const failed = equal(status, "failed") or field(raw, "error") != .null or common.boolValue(field(value, "isError"));
            try self.tool(name, args, output, item.timestamp, failed);
            return;
        }
        if (equal(item.kind, "imageView") and stringField(raw, "path").len > 0) {
            const attachments = if (item.attachments.len > 0)
                item.attachments
            else
                &[_]Value{try jsonObject(self.allocator, &.{.{ "path", field(raw, "path") }})};
            const blocks = try attachmentBlocks(self.allocator, attachments, &self.warnings, self.opts.embed_images);
            const args = try jsonObject(self.allocator, &.{.{ "file_path", field(raw, "path") }});
            const output = try jsonArray(self.allocator, blocks);
            try self.tool("Read", args, output, item.timestamp, false);
            return;
        }
        if (equal(item.role, "user")) {
            var blocks = ValueList.init(self.allocator);
            if (item.text.len > 0) {
                const text = try textBlock(self.allocator, item.text);
                try blocks.append(text);
            }
            const converted_blocks = try attachmentBlocks(self.allocator, item.attachments, &self.warnings, self.opts.embed_images);
            try blocks.appendSlice(converted_blocks);
            if (blocks.items.len > 0) {
                try self.append("user", .{ .array = blocks }, item.timestamp, false);
            }
            return;
        }
        if (equal(item.kind, "agentMessage") or equal(item.kind, "message") or
            equal(item.kind, "assistant") or equal(item.kind, "response_item") or
            raw == .null or (raw == .object and raw.object.count() == 0))
        {
            if (item.text.len > 0) {
                const text = try textBlock(self.allocator, item.text);
                const content = try jsonArray(self.allocator, &.{text});
                try self.append("assistant", content, item.timestamp, false);
            }
        } else {
            const payload = try common.json(self.allocator, raw);
            const detail = try common.fmt(self.allocator, "[Historical {s} {s}]\n{s}", .{ self.source_label, item.kind, payload });
            const text = try textBlock(self.allocator, detail);
            const content = try jsonArray(self.allocator, &.{text});
            try self.append("assistant", content, item.timestamp, false);
        }
        if (item.attachments.len > 0) {
            const blocks = try attachmentBlocks(self.allocator, item.attachments, &self.warnings, self.opts.embed_images);
            const content = try jsonArray(self.allocator, blocks);
            try self.append("user", content, item.timestamp, false);
        }
    }
    pub fn boundary(self: *Encoder, timestamp: []const u8) !void {
        self.sequence += 1;
        const purpose = try common.fmt(self.allocator, "entry:{d}", .{self.sequence});
        const identifier = try self.id(purpose);
        const metadata = try jsonObject(self.allocator, &.{
            .{ "trigger", jsonString("auto") },
            .{ "preTokens", common.num(0) },
        });
        const entry = try jsonObject(self.allocator, &.{
            .{ "parentUuid", .null },
            .{ "logicalParentUuid", if (self.parent) |p| jsonString(p) else nullv },
            .{ "isSidechain", common.boolean(false) },
            .{ "userType", jsonString("external") },
            .{ "entrypoint", jsonString("cli") },
            .{ "cwd", jsonString(self.thread.cwd) },
            .{ "sessionId", jsonString(self.sid) },
            .{ "version", jsonString(version) },
            .{ "type", jsonString("system") },
            .{ "subtype", jsonString("compact_boundary") },
            .{ "content", jsonString("Conversation compacted") },
            .{ "level", jsonString("info") },
            .{ "isMeta", common.boolean(false) },
            .{ "uuid", jsonString(identifier) },
            .{ "timestamp", jsonString(timestamp) },
            .{ "compactMetadata", metadata },
        });
        try self.entries.append(entry);
        self.parent = identifier;
    }
    pub fn sourceBoundary(self: *Encoder, compaction: common.Compaction) anyerror!void {
        if (compaction.summary.len == 0) {
            return;
        }
        try self.flushRaw();
        const timestamp = compaction.timestamp orelse self.thread.updated_at;
        try self.boundary(timestamp);
        const summary = try common.fmt(self.allocator, "[Context summary saved by {s} before migration]\n{s}", .{
            self.source_label,
            compaction.summary,
        });
        try self.append("user", jsonString(summary), timestamp, true);
        for (compaction.items) |item| {
            try self.emit(item);
        }
    }
};
