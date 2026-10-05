const std = @import("std");
const common = @import("../common.zig");
const A = common.Allocator;
const V = common.Value;
const str = common.str;
const obj = common.obj;
const get = common.get;
const s = common.s;
const eq = common.eq;
const list = common.list;
const Values = std.array_list.Managed(V);
const image_limit: usize = 5 * 1024 * 1024;
const textBlock = @import("native.zig").textBlock;

pub fn imageBlock(a: A, mime: []const u8, encoded: []const u8) !V {
    return obj(a, &.{ .{ "type", str("image") }, .{ "source", try obj(a, &.{ .{ "type", str("base64") }, .{ "media_type", str(mime) }, .{ "data", str(encoded) } }) } });
}
fn supportedMime(mime: []const u8) bool {
    return eq(mime, "image/png") or eq(mime, "image/jpeg") or eq(mime, "image/gif") or eq(mime, "image/webp");
}
fn embedFile(a: A, path: []const u8, warnings: *common.Warnings) !?V {
    const info = common.stat(path) catch {
        try warnings.append(try common.fmt(a, "Attachment unavailable; kept path: {s}", .{path}));
        return null;
    };
    if (info.size > image_limit) {
        try warnings.append(try common.fmt(a, "Image exceeds native 5 MB limit; kept path: {s}", .{path}));
        return null;
    }
    const data = common.readFile(a, path) catch {
        try warnings.append(try common.fmt(a, "Attachment unavailable; kept path: {s}", .{path}));
        return null;
    };
    if (data.len > image_limit) return null;
    const mime: []const u8 = if (std.mem.startsWith(u8, data, "\x89PNG\r\n\x1a\n")) "image/png" else if (std.mem.startsWith(u8, data, "\xff\xd8\xff")) "image/jpeg" else if (std.mem.startsWith(u8, data, "GIF87a") or std.mem.startsWith(u8, data, "GIF89a")) "image/gif" else if (data.len >= 12 and eq(data[0..4], "RIFF") and eq(data[8..12], "WEBP")) "image/webp" else {
        try warnings.append(try common.fmt(a, "Attachment is not a supported image; kept path: {s}", .{path}));
        return null;
    };
    const encoded = try a.alloc(u8, std.base64.standard.Encoder.calcSize(data.len));
    _ = std.base64.standard.Encoder.encode(encoded, data);
    return try imageBlock(a, mime, encoded);
}
pub fn attachmentBlocks(a: A, attachments: []const V, warnings: *common.Warnings, embed: bool) anyerror![]V {
    var blocks = Values.init(a);
    for (attachments) |attachment| {
        const path = s(attachment, "path");
        var urlvalue = get(attachment, "url");
        if (urlvalue == .null) urlvalue = get(attachment, "image_url");
        if (urlvalue == .object) urlvalue = get(urlvalue, "url");
        const url = common.text(urlvalue);
        if (path.len > 0) {
            try blocks.append(try textBlock(a, try common.fmt(a, "Attachment: {s}", .{path})));
            if (std.mem.startsWith(u8, url, "data:image/")) {
                const recovered = try obj(a, &.{.{ "url", str(url) }});
                try blocks.appendSlice(try attachmentBlocks(a, &.{recovered}, warnings, embed));
            } else if (embed) {
                if (try embedFile(a, path, warnings)) |image| try blocks.append(image);
            }
        } else if (std.mem.startsWith(u8, url, "data:image/")) {
            var embedded = false;
            if (embed) if (std.mem.indexOfScalar(u8, url, ',')) |comma| {
                const header = url[5..comma];
                const semi = std.mem.indexOfScalar(u8, header, ';') orelse header.len;
                const mime = header[0..semi];
                const payload = url[comma + 1 ..];
                if (supportedMime(mime) and std.mem.indexOf(u8, header, ";base64") != null) {
                    const size = std.base64.standard.Decoder.calcSizeForSlice(payload) catch image_limit + 1;
                    if (size <= image_limit) {
                        const decoded = try a.alloc(u8, size);
                        if (std.base64.standard.Decoder.decode(decoded, payload)) |_| {
                            try blocks.append(try imageBlock(a, mime, payload));
                            embedded = true;
                        } else |_| try warnings.append("Invalid embedded image; preserved attachment notice");
                    } else try warnings.append("Embedded image is invalid or exceeds native 5 MB limit; preserved attachment notice");
                }
            };
            if (!embedded) try blocks.append(try textBlock(a, "An embedded image was attached in the source conversation."));
        } else if (std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://")) {
            try blocks.append(try textBlock(a, try common.fmt(a, "Attachment URL: {s}", .{url})));
        } else try blocks.append(try textBlock(a, try common.fmt(a, "Source attachment: {s}", .{try common.json(a, attachment)})));
    }
    return blocks.toOwnedSlice();
}
pub fn toolResultBlocks(a: A, value: V, warnings: *common.Warnings, embed: bool) !V {
    if (value != .object or get(value, "content") != .array) return str(try common.json(a, value));
    var blocks = Values.init(a);
    for (list(get(value, "content"))) |part| {
        if (eq(s(part, "type"), "text")) {
            const text = s(part, "text");
            try blocks.append(try textBlock(a, if (text.len > 0) text else "(empty tool text)"));
        } else if (eq(s(part, "type"), "image") and s(part, "data").len > 0) {
            const mime = if (s(part, "mimeType").len > 0) s(part, "mimeType") else "image/png";
            const attachment = try obj(a, &.{.{ "url", str(try common.fmt(a, "data:{s};base64,{s}", .{ mime, s(part, "data") })) }});
            try blocks.appendSlice(try attachmentBlocks(a, &.{attachment}, warnings, embed));
        } else try blocks.append(try textBlock(a, try common.json(a, part)));
    }
    var metadata = try obj(a, &.{});
    var iter = value.object.iterator();
    while (iter.next()) |entry| if (!eq(entry.key_ptr.*, "content")) try common.set(a, &metadata, entry.key_ptr.*, entry.value_ptr.*);
    if (metadata.object.count() > 0) try blocks.append(try textBlock(a, try common.json(a, metadata)));
    if (blocks.items.len == 0) try blocks.append(try textBlock(a, "(empty tool result)"));
    return .{ .array = blocks };
}

pub fn canonicalBlocks(a: A, content: V, warnings: *common.Warnings, embed: bool) anyerror!V {
    if (content != .array) return common.clone(a, content);
    var blocks = Values.init(a);
    for (content.array.items) |original| {
        const kind = s(original, "type");
        if (eq(kind, "thinking") or eq(kind, "redacted_thinking")) continue;
        if (eq(kind, "image")) {
            const source = get(original, "source");
            if (eq(s(source, "type"), "base64")) {
                const attachment = try obj(a, &.{.{ "url", str(try common.fmt(a, "data:{s};base64,{s}", .{ s(source, "media_type"), s(source, "data") })) }});
                try blocks.appendSlice(try attachmentBlocks(a, &.{attachment}, warnings, embed));
            } else if (s(source, "url").len > 0) {
                try blocks.appendSlice(try attachmentBlocks(a, &.{try obj(a, &.{.{ "url", get(source, "url") }})}, warnings, embed));
            } else try blocks.append(try textBlock(a, try common.fmt(a, "[Historical image attachment]\n{s}", .{try common.json(a, original)})));
            continue;
        }
        var block = try common.clone(a, original);
        if (eq(kind, "tool_result") and get(block, "content") == .array) try common.set(a, &block, "content", try canonicalBlocks(a, get(block, "content"), warnings, embed));
        try blocks.append(block);
    }
    return .{ .array = blocks };
}
