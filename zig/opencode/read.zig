const std = @import("std");
const common = @import("../common.zig");
const Allocator = common.Allocator;
const Value = common.Value;
const jsonString = common.str;
const Values = std.array_list.Managed(Value);

fn textBlock(allocator: Allocator, value: []const u8) !Value {
    return common.obj(allocator, &.{
        .{ "type", jsonString("text") },
        .{ "text", jsonString(value) },
    });
}

fn envelope(allocator: Allocator, id: []const u8, role: []const u8, time: []const u8, content: []const Value) !Value {
    const message = try common.obj(allocator, &.{
        .{ "role", jsonString(role) },
        .{ "content", try common.arr(allocator, content) },
    });
    return common.obj(allocator, &.{
        .{ "uuid", jsonString(id) },
        .{ "type", jsonString(role) },
        .{ "timestamp", jsonString(time) },
        .{ "message", message },
    });
}

fn fileBlock(allocator: Allocator, file: Value) !Value {
    const mime = common.stringField(file, "mime");
    if (std.mem.startsWith(u8, mime, "image/")) {
        const source = try common.obj(allocator, &.{
            .{ "type", jsonString("base64") },
            .{ "media_type", jsonString(mime) },
            .{ "data", common.get(file, "data") },
        });
        return common.obj(allocator, &.{
            .{ "type", jsonString("image") },
            .{ "source", source },
        });
    }
    const encoded = try common.json(allocator, file);
    const detail = try common.fmt(allocator, "[OpenCode attachment]\n{s}", .{encoded});
    return textBlock(allocator, detail);
}

pub fn readDataEntries(allocator: Allocator, data: Value, warnings: *common.Warnings) ![]Value {
    var out = Values.init(allocator);
    for (common.list(common.get(data, "messages"))) |message| {
        const kind = common.stringField(message, "type");
        const id = common.stringField(message, "id");
        const message_time = common.get(message, "time");
        const time = try common.timestamp(allocator, common.integer(common.get(message_time, "created")));
        if (common.eq(kind, "user")) {
            var content = Values.init(allocator);
            const text = common.stringField(message, "text");
            if (text.len > 0) {
                const block = try textBlock(allocator, text);
                try content.append(block);
            }
            for (common.list(common.get(message, "files"))) |file| {
                const block = try fileBlock(allocator, file);
                try content.append(block);
            }
            if (content.items.len > 0) {
                const entry = try envelope(allocator, id, "user", time, content.items);
                try out.append(entry);
            }
        } else if (common.eq(kind, "assistant")) {
            for (common.list(common.get(message, "content")), 0..) |part, index| {
                const part_id = try common.fmt(allocator, "{s}:{d}", .{ id, index });
                const part_type = common.stringField(part, "type");
                if (common.eq(part_type, "text")) {
                    const text = common.stringField(part, "text");
                    if (text.len > 0) {
                        const block = try textBlock(allocator, text);
                        const entry = try envelope(allocator, part_id, "assistant", time, &.{block});
                        try out.append(entry);
                    }
                } else if (common.eq(part_type, "tool")) {
                    const state = common.get(part, "state");
                    const call_id = common.stringField(part, "id");
                    var input = common.get(state, "input");
                    if (input != .object) {
                        input = try common.obj(allocator, &.{.{ "historicalInput", input }});
                    }
                    const call = try common.obj(allocator, &.{
                        .{ "type", jsonString("tool_use") },
                        .{ "id", jsonString(call_id) },
                        .{ "name", common.get(part, "name") },
                        .{ "input", input },
                    });
                    const call_entry = try envelope(allocator, part_id, "assistant", time, &.{call});
                    try out.append(call_entry);
                    var content = Values.init(allocator);
                    for (common.list(common.get(state, "content"))) |block| {
                        const block_type = common.stringField(block, "type");
                        const uri = common.stringField(block, "uri");
                        if (common.eq(block_type, "text")) {
                            const text = try textBlock(allocator, common.stringField(block, "text"));
                            try content.append(text);
                        } else if (common.eq(block_type, "file") and std.mem.startsWith(u8, uri, "data:image/")) {
                            if (std.mem.indexOf(u8, uri, ";base64,")) |split| {
                                const file = try common.obj(allocator, &.{
                                    .{ "mime", jsonString(uri[5..split]) },
                                    .{ "data", jsonString(uri[split + 8 ..]) },
                                });
                                const attachment = try fileBlock(allocator, file);
                                try content.append(attachment);
                            } else {
                                const encoded = try common.json(allocator, block);
                                const text = try textBlock(allocator, encoded);
                                try content.append(text);
                            }
                        } else {
                            const encoded = try common.json(allocator, block);
                            const text = try textBlock(allocator, encoded);
                            try content.append(text);
                        }
                    }
                    const metadata = common.get(state, "metadata");
                    if (metadata != .null) {
                        const encoded = try common.json(allocator, metadata);
                        const detail = try common.fmt(allocator, "[Historical tool metadata]\n{s}", .{encoded});
                        const text = try textBlock(allocator, detail);
                        try content.append(text);
                    }
                    const tool_error = common.get(state, "error");
                    if (tool_error != .null) {
                        const encoded = try common.json(allocator, tool_error);
                        const detail = try common.fmt(allocator, "[Historical tool error]\n{s}", .{encoded});
                        const text = try textBlock(allocator, detail);
                        try content.append(text);
                    }
                    const status = common.stringField(state, "status");
                    const failed = !common.eq(status, "completed");
                    if (content.items.len == 0) {
                        const detail = common.stringField(tool_error, "message");
                        const text = try textBlock(allocator, if (detail.len > 0)
                            detail
                        else
                            "Historical tool had no saved result; c2c did not execute it.");
                        try content.append(text);
                        if (!common.eq(status, "error")) {
                            try warnings.append(
                                "Incomplete OpenCode tool preserved with an explicit historical result",
                            );
                        }
                    }
                    const result = try common.obj(allocator, &.{
                        .{ "type", jsonString("tool_result") },
                        .{ "tool_use_id", jsonString(call_id) },
                        .{ "content", try common.arr(allocator, content.items) },
                        .{ "is_error", common.boolean(failed) },
                    });
                    const result_id = try common.fmt(allocator, "{s}:result", .{part_id});
                    const result_entry = try envelope(allocator, result_id, "user", time, &.{result});
                    try out.append(result_entry);
                }
            }
            const message_error = common.get(message, "error");
            if (message_error != .null) {
                const error_id = try common.fmt(allocator, "{s}:error", .{id});
                const encoded = try common.json(allocator, message_error);
                const detail = try common.fmt(allocator, "[Historical OpenCode response error]\n{s}", .{encoded});
                const text = try textBlock(allocator, detail);
                const entry = try envelope(allocator, error_id, "assistant", time, &.{text});
                try out.append(entry);
            }
        } else if (common.eq(kind, "compaction") and common.eq(common.stringField(message, "status"), "completed")) {
            if (common.get(message, "providerContext") != .null) {
                try warnings.append(
                    "OpenCode provider-specific compaction state omitted; readable summary and full history retained",
                );
            }
            const summary_text = common.stringField(message, "summary");
            const recent = common.stringField(message, "recent");
            if (std.mem.trim(u8, summary_text, " \t\r\n").len == 0 and
                std.mem.trim(u8, recent, " \t\r\n").len == 0)
            {
                try warnings.append(
                    "OpenCode compaction had no readable summary; earlier visible history remains active",
                );
                continue;
            }
            const boundary = try common.obj(allocator, &.{
                .{ "type", jsonString("system") },
                .{ "subtype", jsonString("compact_boundary") },
                .{ "timestamp", jsonString(time) },
                .{ "uuid", jsonString(id) },
            });
            try out.append(boundary);
            const summary_id = try common.fmt(allocator, "{s}:summary", .{id});
            const detail = try common.fmt(allocator, "{s}\n{s}", .{ summary_text, recent });
            const text = try textBlock(allocator, detail);
            var summary = try envelope(allocator, summary_id, "user", time, &.{text});
            try common.set(allocator, &summary, "isCompactSummary", common.boolean(true));
            try out.append(summary);
        } else if (common.eq(kind, "shell")) {
            const encoded = try common.json(allocator, message);
            const detail = try common.fmt(allocator, "[Historical OpenCode shell]\n{s}", .{encoded});
            const text = try textBlock(allocator, detail);
            const entry = try envelope(allocator, id, "assistant", time, &.{text});
            try out.append(entry);
        } else if (common.eq(kind, "synthetic")) {
            const text = try textBlock(allocator, common.stringField(message, "text"));
            const entry = try envelope(allocator, id, "user", time, &.{text});
            try out.append(entry);
        }
        // Exclude system/skill instructions, private reasoning and provider state.
    }
    return out.toOwnedSlice();
}
