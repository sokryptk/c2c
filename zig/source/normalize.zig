const std = @import("std");
const common = @import("../common.zig");
const Allocator = common.Allocator;
const Value = common.Value;
const eq = common.eq;
const storage = @import("storage.zig");
const Thread = common.Thread;
const Item = common.Item;
const Strings = std.array_list.Managed([]const u8);
const Values = std.array_list.Managed(Value);
const absolute = storage.absolute;

pub fn oneOf(value: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| {
        if (eq(value, choice)) {
            return true;
        }
    }
    return false;
}

pub fn first(value: []const u8, fallback: []const u8) []const u8 {
    return if (value.len != 0) value else fallback;
}

pub fn timestamp(allocator: Allocator, value: Value, milliseconds: bool) ![]const u8 {
    if (value == .null or (value == .string and value.string.len == 0)) {
        return "1970-01-01T00:00:00.000Z";
    }
    if (value == .string) {
        const millis = try common.timestampMillis(value.string);
        return common.timestamp(allocator, millis);
    }
    if (value != .integer and value != .float) {
        return error.InvalidSourceTimestamp;
    }
    if (value == .float) {
        const is_milliseconds = milliseconds or @abs(value.float) >= 100_000_000_000;
        const scaled = if (is_milliseconds) value.float else value.float * 1000;
        const maximum = @as(f64, @floatFromInt(std.math.maxInt(i64)));
        const minimum = @as(f64, @floatFromInt(std.math.minInt(i64)));
        if (!std.math.isFinite(scaled) or scaled >= maximum or scaled < minimum) {
            return error.InvalidSourceTimestamp;
        }
        return common.timestamp(allocator, @intFromFloat(scaled));
    }
    const number = common.integer(value);
    const is_milliseconds = milliseconds or number >= 100_000_000_000 or number <= -100_000_000_000;
    const millis = if (is_milliseconds)
        number
    else
        std.math.mul(i64, number, 1000) catch return error.InvalidSourceTimestamp;
    return common.timestamp(allocator, millis);
}

fn mime(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".png")) {
        return "image/png";
    }
    if (std.ascii.eqlIgnoreCase(extension, ".jpg") or std.ascii.eqlIgnoreCase(extension, ".jpeg")) {
        return "image/jpeg";
    }
    if (std.ascii.eqlIgnoreCase(extension, ".gif")) {
        return "image/gif";
    }
    if (std.ascii.eqlIgnoreCase(extension, ".webp")) {
        return "image/webp";
    }
    if (std.ascii.eqlIgnoreCase(extension, ".pdf")) {
        return "application/pdf";
    }
    return "";
}

const Content = struct {
    text: []const u8,
    attachments: []const Value,
};

pub fn content(allocator: Allocator, value: Value, warnings: *common.Warnings) !Content {
    if (value == .string) {
        return .{ .text = try allocator.dupe(u8, value.string), .attachments = &.{} };
    }
    var texts = Strings.init(allocator);
    var attachments = Values.init(allocator);
    const single = [_]Value{value};
    const parts = if (value == .object) &single else common.list(value);
    for (parts) |part| {
        if (part != .object) {
            continue;
        }
        const kind = common.stringField(part, "type");
        if (oneOf(kind, &.{ "text", "input_text", "output_text" })) {
            const text = try allocator.dupe(u8, common.stringField(part, "text"));
            try texts.append(text);
        } else if (oneOf(kind, &.{
            "image", "input_image", "localImage",    "image_url",
            "file",  "input_file",  "resource_link", "skill",
        })) {
            const path = first(common.stringField(part, "path"), common.stringField(part, "file_path"));
            var url = common.get(part, "image_url");
            if (url == .null) {
                url = common.get(part, "url");
            }
            if (url == .null) {
                url = common.get(part, "uri");
            }
            if (url == .object) {
                url = common.get(url, "url");
            }
            const declared_media = first(common.stringField(part, "mimeType"), common.stringField(part, "mime_type"));
            const media = first(declared_media, mime(path));
            if (url == .null and common.stringField(part, "data").len != 0 and eq(kind, "image")) {
                const data_url = try common.fmt(allocator, "data:{s};base64,{s}", .{
                    first(media, "image/png"),
                    common.stringField(part, "data"),
                });
                url = common.str(data_url);
            }
            const attachment_type = try allocator.dupe(u8, kind);
            var attachment = try common.obj(allocator, &.{
                .{ "type", common.str(attachment_type) },
            });
            if (path.len != 0) {
                const attachment_path = try allocator.dupe(u8, path);
                try common.set(allocator, &attachment, "path", common.str(attachment_path));
            }
            if (url != .null) {
                const attachment_url = try common.clone(allocator, url);
                try common.set(allocator, &attachment, "url", attachment_url);
            }
            if (media.len != 0) {
                const media_type = try allocator.dupe(u8, media);
                try common.set(allocator, &attachment, "media_type", common.str(media_type));
            }
            const name = first(common.stringField(part, "name"), common.stringField(part, "filename"));
            if (name.len != 0) {
                const attachment_name = try allocator.dupe(u8, name);
                try common.set(allocator, &attachment, "name", common.str(attachment_name));
            }
            for ([_][]const u8{ "file_id", "file_data", "file_url" }) |key| {
                const field = common.get(part, key);
                if (field != .null) {
                    const retained_field = try common.clone(allocator, field);
                    try common.set(allocator, &attachment, key, retained_field);
                }
            }
            try attachments.append(attachment);
        } else if (!oneOf(kind, &.{ "reasoning", "encrypted_text" })) {
            const warning = try common.fmt(allocator, "Unsupported content block; preserved as an attachment", .{});
            try warnings.append(warning);
            const unsupported = try common.clone(allocator, part);
            try attachments.append(unsupported);
        }
    }
    return .{
        .text = try std.mem.join(allocator, "\n", texts.items),
        .attachments = try attachments.toOwnedSlice(),
    };
}

pub fn resolved(allocator: Allocator, original_item: Item, thread: Thread) !Item {
    var item = original_item;
    if (item.attachments.len != 0) {
        var attachments = Values.init(allocator);
        for (item.attachments) |attachment_value| {
            var attachment = attachment_value;
            const path = common.stringField(attachment, "path");
            if (path.len != 0) {
                const absolute_path = try absolute(allocator, path, thread.cwd);
                try common.set(allocator, &attachment, "path", common.str(absolute_path));
            }
            try attachments.append(attachment);
        }
        item.attachments = try attachments.toOwnedSlice();
    }
    if (oneOf(item.kind, &.{ "imageView", "imageGeneration" })) {
        if (item.raw) |original_raw| {
            var raw = original_raw;
            for ([_][]const u8{ "path", "savedPath" }) |key| {
                const path = common.stringField(raw, key);
                if (path.len != 0) {
                    const absolute_path = try absolute(allocator, path, thread.cwd);
                    try common.set(allocator, &raw, key, common.str(absolute_path));
                }
            }
            item.raw = raw;
        }
    }
    return item;
}

pub fn projected(
    allocator: Allocator,
    payload: Value,
    identifier: []const u8,
    item_timestamp: []const u8,
    ordinal: i64,
    warnings: *common.Warnings,
) !?Item {
    const kind = common.stringField(payload, "type");
    if (oneOf(kind, &.{ "reasoning", "hookPrompt", "contextCompaction", "subAgentActivity" })) {
        return null;
    }
    var item = Item{
        .id = try allocator.dupe(u8, identifier),
        .role = "",
        .text = "",
        .timestamp = item_timestamp,
        .kind = try allocator.dupe(u8, kind),
        .ordinal = ordinal,
    };
    if (eq(kind, "userMessage")) {
        const parsed = try content(allocator, common.get(payload, "content"), warnings);
        item.role = "user";
        item.text = parsed.text;
        item.attachments = parsed.attachments;
    } else if (eq(kind, "agentMessage")) {
        if (eq(common.stringField(payload, "phase"), "analysis")) {
            return null;
        }
        item.role = "assistant";
        item.text = try allocator.dupe(u8, common.stringField(payload, "text"));
    } else if (oneOf(kind, &.{
        "commandExecution", "fileChange",          "functionCallOutput",
        "mcpToolCall",      "collabAgentToolCall", "imageView",
        "imageGeneration",  "webSearch",           "sleep",
    })) {
        var output = common.get(payload, "aggregatedOutput");
        if (output == .null) {
            output = common.get(payload, "output");
        }
        if (eq(kind, "mcpToolCall")) {
            const result = common.get(payload, "result");
            output = if (result == .object) common.get(result, "content") else result;
        }
        const parsed = try content(allocator, output, warnings);
        item.role = "tool";
        item.text = parsed.text;
        item.attachments = parsed.attachments;
        item.raw = try common.clone(allocator, payload);
        if (oneOf(kind, &.{ "imageView", "imageGeneration" })) {
            const path = first(common.stringField(payload, "path"), common.stringField(payload, "savedPath"));
            if (path.len != 0) {
                var attachments = Values.init(allocator);
                try attachments.appendSlice(item.attachments);
                const retained_path = try allocator.dupe(u8, path);
                const image = try common.obj(allocator, &.{
                    .{ "path", common.str(retained_path) },
                    .{ "type", common.str("localImage") },
                    .{ "media_type", common.str(mime(path)) },
                });
                try attachments.append(image);
                item.attachments = try attachments.toOwnedSlice();
            }
        }
    } else {
        const warning = try common.fmt(allocator, "Unsupported projected item at ordinal {d}", .{ordinal});
        try warnings.append(warning);
        return null;
    }
    return item;
}

pub fn response(
    allocator: Allocator,
    payload: Value,
    item_timestamp: []const u8,
    ordinal: i64,
    prefix: []const u8,
    warnings: *common.Warnings,
) !?Item {
    const kind = common.stringField(payload, "type");
    const supplied_id = first(common.stringField(payload, "id"), common.stringField(payload, "call_id"));
    const generated_id = try common.fmt(allocator, "{s}:{d}", .{ prefix, ordinal });
    const identifier = first(supplied_id, generated_id);
    if (eq(kind, "message")) {
        const role = common.stringField(payload, "role");
        if (!oneOf(role, &.{ "user", "assistant" }) or
            oneOf(common.stringField(payload, "channel"), &.{ "analysis", "justify", "confidence" }))
        {
            return null;
        }
        const parsed = try content(allocator, common.get(payload, "content"), warnings);
        if (parsed.text.len == 0 and parsed.attachments.len == 0) {
            return null;
        }
        return .{
            .id = try allocator.dupe(u8, identifier),
            .role = try allocator.dupe(u8, role),
            .text = parsed.text,
            .timestamp = item_timestamp,
            .kind = if (eq(role, "user")) "userMessage" else "agentMessage",
            .attachments = parsed.attachments,
            .ordinal = ordinal,
        };
    }
    if (oneOf(kind, &.{
        "function_call",           "custom_tool_call", "function_call_output",
        "custom_tool_call_output", "web_search_call",  "image_generation_call",
    })) {
        const parsed = try content(allocator, common.get(payload, "output"), warnings);
        return .{
            .id = try allocator.dupe(u8, identifier),
            .role = "tool",
            .text = parsed.text,
            .timestamp = item_timestamp,
            .kind = try allocator.dupe(u8, kind),
            .attachments = parsed.attachments,
            .raw = try common.clone(allocator, payload),
            .ordinal = ordinal,
        };
    }
    return null;
}
