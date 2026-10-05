const std = @import("std");
const H = @import("../common.zig");
const A = H.Allocator;
const V = H.Value;
const eq = H.eq;
const storage = @import("storage.zig");
const Thread = H.Thread;
const Item = H.Item;
const Strings = std.array_list.Managed([]const u8);
const Values = std.array_list.Managed(V);
const absolute = storage.absolute;

pub fn oneOf(value: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (eq(value, choice)) return true;
    return false;
}
pub fn first(value: []const u8, fallback: []const u8) []const u8 {
    return if (value.len != 0) value else fallback;
}
pub fn timestamp(a: A, value: V, milliseconds: bool) ![]const u8 {
    if (value == .null or (value == .string and value.string.len == 0)) return "1970-01-01T00:00:00.000Z";
    if (value == .string) return H.timestamp(a, try H.timestampMillis(value.string));
    if (value != .integer and value != .float) return error.InvalidSourceTimestamp;
    if (value == .float) {
        const scaled = if (milliseconds or @abs(value.float) >= 100_000_000_000) value.float else value.float * 1000;
        if (!std.math.isFinite(scaled) or scaled >= @as(f64, @floatFromInt(std.math.maxInt(i64))) or scaled < @as(f64, @floatFromInt(std.math.minInt(i64)))) return error.InvalidSourceTimestamp;
        return H.timestamp(a, @intFromFloat(scaled));
    }
    const number = H.integer(value);
    const millis = if (milliseconds or number >= 100_000_000_000 or number <= -100_000_000_000) number else std.math.mul(i64, number, 1000) catch return error.InvalidSourceTimestamp;
    return H.timestamp(a, millis);
}

fn mime(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(extension, ".jpg") or std.ascii.eqlIgnoreCase(extension, ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(extension, ".gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(extension, ".webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(extension, ".pdf")) return "application/pdf";
    return "";
}
const Content = struct { text: []const u8, attachments: []const V };
pub fn content(a: A, value: V, warnings: *H.Warnings) !Content {
    if (value == .string) return .{ .text = try a.dupe(u8, value.string), .attachments = &.{} };
    var texts = Strings.init(a);
    var attachments = Values.init(a);
    const single = [_]V{value};
    for (if (value == .object) &single else H.list(value)) |part| {
        if (part != .object) continue;
        const kind = H.s(part, "type");
        if (oneOf(kind, &.{ "text", "input_text", "output_text" })) {
            try texts.append(try a.dupe(u8, H.s(part, "text")));
        } else if (oneOf(kind, &.{ "image", "input_image", "localImage", "image_url", "file", "input_file", "resource_link", "skill" })) {
            const path = first(H.s(part, "path"), H.s(part, "file_path"));
            var url = H.get(part, "image_url");
            if (url == .null) url = H.get(part, "url");
            if (url == .null) url = H.get(part, "uri");
            if (url == .object) url = H.get(url, "url");
            const media = first(first(H.s(part, "mimeType"), H.s(part, "mime_type")), mime(path));
            if (url == .null and H.s(part, "data").len != 0 and eq(kind, "image")) url = H.str(try H.fmt(a, "data:{s};base64,{s}", .{ first(media, "image/png"), H.s(part, "data") }));
            var attachment = try H.obj(a, &.{.{ "type", H.str(try a.dupe(u8, kind)) }});
            if (path.len != 0) try H.set(a, &attachment, "path", H.str(try a.dupe(u8, path)));
            if (url != .null) try H.set(a, &attachment, "url", try H.clone(a, url));
            if (media.len != 0) try H.set(a, &attachment, "media_type", H.str(try a.dupe(u8, media)));
            const name = first(H.s(part, "name"), H.s(part, "filename"));
            if (name.len != 0) try H.set(a, &attachment, "name", H.str(try a.dupe(u8, name)));
            for ([_][]const u8{ "file_id", "file_data", "file_url" }) |key| {
                const field = H.get(part, key);
                if (field != .null) try H.set(a, &attachment, key, try H.clone(a, field));
            }
            try attachments.append(attachment);
        } else if (!oneOf(kind, &.{ "reasoning", "encrypted_text" })) {
            try warnings.append(try H.fmt(a, "Unsupported content block; preserved as an attachment", .{}));
            try attachments.append(try H.clone(a, part));
        }
    }
    return .{ .text = try std.mem.join(a, "\n", texts.items), .attachments = try attachments.toOwnedSlice() };
}
pub fn resolved(a: A, item_value: Item, thread: Thread) !Item {
    var item = item_value;
    if (item.attachments.len != 0) {
        var attachments = Values.init(a);
        for (item.attachments) |attachment_value| {
            var attachment = attachment_value;
            const path = H.s(attachment, "path");
            if (path.len != 0) try H.set(a, &attachment, "path", H.str(try absolute(a, path, thread.cwd)));
            try attachments.append(attachment);
        }
        item.attachments = try attachments.toOwnedSlice();
    }
    if (oneOf(item.kind, &.{ "imageView", "imageGeneration" })) {
        if (item.raw) |raw_value| {
            var raw = raw_value;
            for ([_][]const u8{ "path", "savedPath" }) |key| {
                const path = H.s(raw, key);
                if (path.len != 0) try H.set(a, &raw, key, H.str(try absolute(a, path, thread.cwd)));
            }
            item.raw = raw;
        }
    }
    return item;
}

pub fn projected(a: A, data: V, identifier: []const u8, time: []const u8, ordinal: i64, warnings: *H.Warnings) !?Item {
    const kind = H.s(data, "type");
    if (oneOf(kind, &.{ "reasoning", "hookPrompt", "contextCompaction", "subAgentActivity" })) return null;
    var item = Item{ .id = try a.dupe(u8, identifier), .role = "", .text = "", .timestamp = time, .kind = try a.dupe(u8, kind), .ordinal = ordinal };
    if (eq(kind, "userMessage")) {
        const parsed = try content(a, H.get(data, "content"), warnings);
        item.role = "user";
        item.text = parsed.text;
        item.attachments = parsed.attachments;
    } else if (eq(kind, "agentMessage")) {
        if (eq(H.s(data, "phase"), "analysis")) return null;
        item.role = "assistant";
        item.text = try a.dupe(u8, H.s(data, "text"));
    } else if (oneOf(kind, &.{ "commandExecution", "fileChange", "functionCallOutput", "mcpToolCall", "collabAgentToolCall", "imageView", "imageGeneration", "webSearch", "sleep" })) {
        var output = H.get(data, "aggregatedOutput");
        if (output == .null) output = H.get(data, "output");
        if (eq(kind, "mcpToolCall")) {
            const result = H.get(data, "result");
            output = if (result == .object) H.get(result, "content") else result;
        }
        const parsed = try content(a, output, warnings);
        item.role = "tool";
        item.text = parsed.text;
        item.attachments = parsed.attachments;
        item.raw = try H.clone(a, data);
        if (oneOf(kind, &.{ "imageView", "imageGeneration" })) {
            const path = first(H.s(data, "path"), H.s(data, "savedPath"));
            if (path.len != 0) {
                var attachments = Values.init(a);
                try attachments.appendSlice(item.attachments);
                try attachments.append(try H.obj(a, &.{ .{ "path", H.str(try a.dupe(u8, path)) }, .{ "type", H.str("localImage") }, .{ "media_type", H.str(mime(path)) } }));
                item.attachments = try attachments.toOwnedSlice();
            }
        }
    } else {
        try warnings.append(try H.fmt(a, "Unsupported projected item at ordinal {d}", .{ordinal}));
        return null;
    }
    return item;
}

pub fn response(a: A, data: V, time: []const u8, ordinal: i64, prefix: []const u8, warnings: *H.Warnings) !?Item {
    const kind = H.s(data, "type");
    const identifier = first(first(H.s(data, "id"), H.s(data, "call_id")), try H.fmt(a, "{s}:{d}", .{ prefix, ordinal }));
    if (eq(kind, "message")) {
        const role = H.s(data, "role");
        if (!oneOf(role, &.{ "user", "assistant" }) or oneOf(H.s(data, "channel"), &.{ "analysis", "justify", "confidence" })) return null;
        const parsed = try content(a, H.get(data, "content"), warnings);
        if (parsed.text.len == 0 and parsed.attachments.len == 0) return null;
        return .{ .id = try a.dupe(u8, identifier), .role = try a.dupe(u8, role), .text = parsed.text, .timestamp = time, .kind = if (eq(role, "user")) "userMessage" else "agentMessage", .attachments = parsed.attachments, .ordinal = ordinal };
    }
    if (oneOf(kind, &.{ "function_call", "custom_tool_call", "function_call_output", "custom_tool_call_output", "web_search_call", "image_generation_call" })) {
        const parsed = try content(a, H.get(data, "output"), warnings);
        return .{ .id = try a.dupe(u8, identifier), .role = "tool", .text = parsed.text, .timestamp = time, .kind = try a.dupe(u8, kind), .attachments = parsed.attachments, .raw = try H.clone(a, data), .ordinal = ordinal };
    }
    return null;
}
