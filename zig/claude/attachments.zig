const std = @import("std");
const common = @import("../common.zig");
const Allocator = common.Allocator;
const Value = common.Value;
const jsonString = common.str;
const jsonObject = common.obj;
const field = common.get;
const stringField = common.stringField;
const equal = common.eq;
const ValueList = std.array_list.Managed(Value);
const image_limit: usize = 5 * 1024 * 1024;
const textBlock = @import("native.zig").textBlock;

pub fn imageBlock(allocator: Allocator, mime: []const u8, encoded: []const u8) !Value {
    const source = try jsonObject(allocator, &.{
        .{ "type", jsonString("base64") },
        .{ "media_type", jsonString(mime) },
        .{ "data", jsonString(encoded) },
    });
    return jsonObject(allocator, &.{
        .{ "type", jsonString("image") },
        .{ "source", source },
    });
}

fn supportedMime(mime: []const u8) bool {
    return equal(mime, "image/png") or
        equal(mime, "image/jpeg") or
        equal(mime, "image/gif") or
        equal(mime, "image/webp");
}

fn imageMime(data: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, data, "\x89PNG\r\n\x1a\n")) {
        return "image/png";
    }
    if (std.mem.startsWith(u8, data, "\xff\xd8\xff")) {
        return "image/jpeg";
    }
    if (std.mem.startsWith(u8, data, "GIF87a") or std.mem.startsWith(u8, data, "GIF89a")) {
        return "image/gif";
    }
    if (data.len >= 12 and equal(data[0..4], "RIFF") and equal(data[8..12], "WEBP")) {
        return "image/webp";
    }
    return null;
}

fn embedFile(allocator: Allocator, path: []const u8, warnings: *common.Warnings) !?Value {
    const info = common.stat(path) catch {
        const warning = try common.fmt(allocator, "Attachment unavailable; kept path: {s}", .{path});
        try warnings.append(warning);
        return null;
    };
    if (info.size > image_limit) {
        const warning = try common.fmt(allocator, "Image exceeds native 5 MB limit; kept path: {s}", .{path});
        try warnings.append(warning);
        return null;
    }
    const data = common.readFile(allocator, path) catch {
        const warning = try common.fmt(allocator, "Attachment unavailable; kept path: {s}", .{path});
        try warnings.append(warning);
        return null;
    };
    if (data.len > image_limit) {
        return null;
    }
    const mime = imageMime(data) orelse {
        const warning = try common.fmt(allocator, "Attachment is not a supported image; kept path: {s}", .{path});
        try warnings.append(warning);
        return null;
    };
    const encoded_size = std.base64.standard.Encoder.calcSize(data.len);
    const encoded = try allocator.alloc(u8, encoded_size);
    _ = std.base64.standard.Encoder.encode(encoded, data);
    return try imageBlock(allocator, mime, encoded);
}

fn embedDataUrl(allocator: Allocator, url: []const u8, warnings: *common.Warnings) !?Value {
    const comma = std.mem.indexOfScalar(u8, url, ',') orelse return null;
    const header = url[5..comma];
    const semicolon = std.mem.indexOfScalar(u8, header, ';') orelse header.len;
    const mime = header[0..semicolon];
    const payload = url[comma + 1 ..];
    if (!supportedMime(mime) or std.mem.indexOf(u8, header, ";base64") == null) {
        return null;
    }
    const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(payload) catch image_limit + 1;
    if (decoded_size > image_limit) {
        try warnings.append("Embedded image is invalid or exceeds native 5 MB limit; preserved attachment notice");
        return null;
    }
    const decoded = try allocator.alloc(u8, decoded_size);
    std.base64.standard.Decoder.decode(decoded, payload) catch {
        try warnings.append("Invalid embedded image; preserved attachment notice");
        return null;
    };
    return try imageBlock(allocator, mime, payload);
}

pub fn attachmentBlocks(
    allocator: Allocator,
    attachments: []const Value,
    warnings: *common.Warnings,
    embed: bool,
) anyerror![]Value {
    var blocks = ValueList.init(allocator);
    for (attachments) |attachment| {
        const path = stringField(attachment, "path");
        var url_value = field(attachment, "url");
        if (url_value == .null) {
            url_value = field(attachment, "image_url");
        }
        if (url_value == .object) {
            url_value = field(url_value, "url");
        }
        const url = common.text(url_value);
        if (path.len > 0) {
            const notice = try common.fmt(allocator, "Attachment: {s}", .{path});
            const path_block = try textBlock(allocator, notice);
            try blocks.append(path_block);
            if (std.mem.startsWith(u8, url, "data:image/")) {
                const recovered = try jsonObject(allocator, &.{
                    .{ "url", jsonString(url) },
                });
                const converted_blocks = try attachmentBlocks(allocator, &.{recovered}, warnings, embed);
                try blocks.appendSlice(converted_blocks);
            } else if (embed) {
                if (try embedFile(allocator, path, warnings)) |image| {
                    try blocks.append(image);
                }
            }
            continue;
        }
        if (std.mem.startsWith(u8, url, "data:image/")) {
            if (embed) {
                if (try embedDataUrl(allocator, url, warnings)) |image| {
                    try blocks.append(image);
                    continue;
                }
            }
            const notice = "An embedded image was attached in the source conversation.";
            const notice_block = try textBlock(allocator, notice);
            try blocks.append(notice_block);
            continue;
        }
        if (std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://")) {
            const notice = try common.fmt(allocator, "Attachment URL: {s}", .{url});
            const url_block = try textBlock(allocator, notice);
            try blocks.append(url_block);
            continue;
        }
        const detail = try common.json(allocator, attachment);
        const notice = try common.fmt(allocator, "Source attachment: {s}", .{detail});
        const notice_block = try textBlock(allocator, notice);
        try blocks.append(notice_block);
    }
    return blocks.toOwnedSlice();
}

pub fn toolResultBlocks(
    allocator: Allocator,
    value: Value,
    warnings: *common.Warnings,
    embed: bool,
) !Value {
    if (value != .object) {
        const serialized = try common.json(allocator, value);
        return jsonString(serialized);
    }
    const content = field(value, "content");
    if (content != .array) {
        const serialized = try common.json(allocator, value);
        return jsonString(serialized);
    }
    var blocks = ValueList.init(allocator);
    for (content.array.items) |part| {
        const part_type = stringField(part, "type");
        if (equal(part_type, "text")) {
            const text = stringField(part, "text");
            const tool_text = if (text.len > 0) text else "(empty tool text)";
            const text_block = try textBlock(allocator, tool_text);
            try blocks.append(text_block);
            continue;
        }
        if (equal(part_type, "image")) {
            const image_data = stringField(part, "data");
            if (image_data.len > 0) {
                const mime_type = stringField(part, "mimeType");
                const mime = if (mime_type.len > 0) mime_type else "image/png";
                const url = try common.fmt(allocator, "data:{s};base64,{s}", .{ mime, image_data });
                const attachment = try jsonObject(allocator, &.{
                    .{ "url", jsonString(url) },
                });
                const converted_blocks = try attachmentBlocks(allocator, &.{attachment}, warnings, embed);
                try blocks.appendSlice(converted_blocks);
                continue;
            }
        }
        const detail = try common.json(allocator, part);
        const text_block = try textBlock(allocator, detail);
        try blocks.append(text_block);
    }
    var metadata = try jsonObject(allocator, &.{});
    var iter = value.object.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        if (equal(key, "content")) {
            continue;
        }
        try common.set(allocator, &metadata, key, entry.value_ptr.*);
    }
    if (metadata.object.count() > 0) {
        const detail = try common.json(allocator, metadata);
        const text_block = try textBlock(allocator, detail);
        try blocks.append(text_block);
    }
    if (blocks.items.len == 0) {
        const empty_result = try textBlock(allocator, "(empty tool result)");
        try blocks.append(empty_result);
    }
    return .{ .array = blocks };
}

pub fn canonicalBlocks(
    allocator: Allocator,
    content: Value,
    warnings: *common.Warnings,
    embed: bool,
) anyerror!Value {
    if (content != .array) {
        return common.clone(allocator, content);
    }
    var blocks = ValueList.init(allocator);
    for (content.array.items) |original| {
        const block_type = stringField(original, "type");
        if (equal(block_type, "thinking") or equal(block_type, "redacted_thinking")) {
            continue;
        }
        if (equal(block_type, "image")) {
            const source = field(original, "source");
            const source_type = stringField(source, "type");
            if (equal(source_type, "base64")) {
                const media_type = stringField(source, "media_type");
                const image_data = stringField(source, "data");
                const url = try common.fmt(allocator, "data:{s};base64,{s}", .{ media_type, image_data });
                const attachment = try jsonObject(allocator, &.{
                    .{ "url", jsonString(url) },
                });
                const converted_blocks = try attachmentBlocks(allocator, &.{attachment}, warnings, embed);
                try blocks.appendSlice(converted_blocks);
                continue;
            }
            const source_url = field(source, "url");
            if (common.text(source_url).len > 0) {
                const attachment = try jsonObject(allocator, &.{
                    .{ "url", source_url },
                });
                const converted_blocks = try attachmentBlocks(allocator, &.{attachment}, warnings, embed);
                try blocks.appendSlice(converted_blocks);
                continue;
            }
            const detail = try common.json(allocator, original);
            const notice = try common.fmt(allocator, "[Historical image attachment]\n{s}", .{detail});
            const text_block = try textBlock(allocator, notice);
            try blocks.append(text_block);
            continue;
        }
        var block = try common.clone(allocator, original);
        if (equal(block_type, "tool_result")) {
            const result_content = field(block, "content");
            if (result_content == .array) {
                const normalized_content = try canonicalBlocks(allocator, result_content, warnings, embed);
                try common.set(allocator, &block, "content", normalized_content);
            }
        }
        try blocks.append(block);
    }
    return .{ .array = blocks };
}
