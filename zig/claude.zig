//! Native Claude Code history adapter. Historical tools are never executed.
const std = @import("std");
const common = @import("common.zig");
const A = common.Allocator;
const V = common.Value;
const str = common.str;
const obj = common.obj;
const arr = common.arr;
const get = common.get;
const s = common.s;
const eq = common.eq;
const list = common.list;
const nullv: V = .null;
const namespace = "6ee9e2ac-f1e7-4ed0-9ecb-ced168929080";
pub const max_active_bytes: usize = 240_000;
const recent_context_bytes: usize = 170_000;
const image_limit: usize = 5 * 1024 * 1024;
const version = "2.1.289";
const Values = std.array_list.Managed(V);

pub const ListOptions = struct {
    import_records: []const V = &.{},
    include_imported: bool = false,
    include_subagents: bool = false,
};

fn isMessage(entry: V) bool {
    return (eq(s(entry, "type"), "user") or eq(s(entry, "type"), "assistant")) and get(entry, "message") == .object;
}
fn visible(entry: V, sidechain: bool) bool {
    return isMessage(entry) and !common.b(get(entry, "isMeta")) and s(entry, "teamName").len == 0 and (sidechain or !common.b(get(entry, "isSidechain")));
}
fn containsBlock(content: V, kind: []const u8) bool {
    for (list(content)) |block| if (eq(s(block, "type"), kind)) return true;
    return false;
}
fn textBlock(a: A, text: []const u8) !V {
    return obj(a, &.{ .{ "type", str("text") }, .{ "text", str(text) } });
}
fn firstPrompt(a: A, entry: V) ![]const u8 {
    if (!eq(s(entry, "type"), "user") or common.b(get(entry, "isMeta")) or common.b(get(entry, "isCompactSummary"))) return "";
    const content = get(get(entry, "message"), "content");
    if (containsBlock(content, "tool_result")) return "";
    var parts = std.array_list.Managed([]const u8).init(a);
    if (content == .string) try parts.append(content.string) else for (list(content)) |block| {
        if (eq(s(block, "type"), "text")) try parts.append(s(block, "text"));
    }
    const raw = try std.mem.join(a, " ", parts.items);
    var out = std.array_list.Managed(u8).init(a);
    var tokens = std.mem.tokenizeAny(u8, raw, " \t\r\n");
    while (tokens.next()) |token| {
        if (out.items.len > 0) try out.append(' ');
        try out.appendSlice(token);
        if (out.items.len >= 200) break;
    }
    return utf8Prefix(out.items, 200);
}
fn isUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |ch, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (ch != '-') return false;
        } else if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}
fn optionalText(v: V, key: []const u8) ?[]const u8 {
    const value = s(v, key);
    return if (value.len > 0) value else null;
}
fn newest(_: void, lhs: common.Thread, rhs: common.Thread) bool {
    const order = std.mem.order(u8, lhs.updated_at, rhs.updated_at);
    return order == .gt or (order == .eq and std.mem.order(u8, lhs.id, rhs.id) == .gt);
}

const Metadata = struct {
    count: usize = 0,
    title: []const u8 = "",
    ai_title: []const u8 = "",
    summary: []const u8 = "",
    prompt: []const u8 = "",
    cwd: []const u8 = "",
    created_at: []const u8 = "",
    updated_at: []const u8 = "",
    last_uuid: []const u8 = "",
    sidechain: bool = false,
    origin_last_uuid: []const u8 = "",
    original_codex_id: []const u8 = "",
    origin_provider: []const u8 = "",
    origin_id: []const u8 = "",
};
fn readMetadata(a: A, path: []const u8) !Metadata {
    // Free each parsed line so inventory retains metadata, not tool results or images.
    var reader = try common.LineReader.open(std.heap.page_allocator, path);
    defer reader.close();
    var meta: Metadata = .{};
    var line_number: usize = 0;
    while (try reader.next()) |line| {
        line_number += 1;
        if (std.mem.trim(u8, line, " \t\r\n").len == 0) continue;
        const parsed = std.json.parseFromSlice(V, std.heap.page_allocator, line, .{ .allocate = .alloc_always }) catch |err| {
            if (reader.offset >= reader.size and !reader.last_terminated and err != error.OutOfMemory) {
                std.debug.print("Warning: {s}:{d}: incomplete final JSON record ignored\n", .{ path, line_number });
                break;
            }
            return err;
        };
        defer parsed.deinit();
        const entry = parsed.value;
        if (entry != .object) return error.InvalidClaudeRecord;
        const kind = s(entry, "type");
        if (eq(kind, "custom-title")) meta.title = try a.dupe(u8, s(entry, "customTitle"));
        if (eq(kind, "ai-title")) meta.ai_title = try a.dupe(u8, s(entry, "aiTitle"));
        if (eq(kind, "summary")) meta.summary = try a.dupe(u8, s(entry, "summary"));
        if (eq(kind, "c2c-import") and s(entry, "source").len > 0) {
            meta.origin_provider = try a.dupe(u8, s(entry, "source"));
            meta.origin_id = try a.dupe(u8, s(entry, "sourceThreadId"));
            meta.origin_last_uuid = try a.dupe(u8, s(entry, "lastMessageUuid"));
            if (eq(s(entry, "source"), "codex")) meta.original_codex_id = try a.dupe(u8, s(entry, "sourceThreadId"));
        }
        if (!isMessage(entry) or common.b(get(entry, "isMeta")) or s(entry, "teamName").len > 0) continue;
        if (meta.count == 0) meta.sidechain = common.b(get(entry, "isSidechain"));
        meta.count += 1;
        // Appended root sidechains must not make an unchanged import appear
        // continued. Explicit subagent transcripts remain independently visible.
        if (!meta.sidechain and common.b(get(entry, "isSidechain"))) continue;
        if (meta.cwd.len == 0) meta.cwd = try a.dupe(u8, s(entry, "cwd"));
        if (s(entry, "timestamp").len > 0) {
            const date = try common.timestamp(a, try common.timestampMillis(s(entry, "timestamp")));
            if (meta.created_at.len == 0) meta.created_at = date;
            meta.updated_at = date;
        }
        if (s(entry, "uuid").len > 0) meta.last_uuid = try a.dupe(u8, s(entry, "uuid"));
        if (meta.prompt.len == 0) meta.prompt = try firstPrompt(a, entry);
    }
    return meta;
}

pub fn listThreads(a: A, home: []const u8, options: ListOptions) ![]common.Thread {
    const root = try common.join(a, &.{ home, "projects" });
    if (!common.exists(root)) return a.alloc(common.Thread, 0);
    var paths = std.array_list.Managed([]const u8).init(a);
    const projects = try common.listDir(a, root);
    for (projects) |project| {
        if (!project.is_dir or project.is_symlink) continue;
        const directory = try common.join(a, &.{ root, project.name });
        const children = common.listDir(a, directory) catch |err| {
            std.debug.print("Warning: Cannot inspect Claude project {s}: {s}\n", .{ directory, @errorName(err) });
            continue;
        };
        for (children) |child| {
            if (child.is_symlink) continue;
            if (!child.is_dir) {
                if (std.mem.endsWith(u8, child.name, ".jsonl")) try paths.append(try common.join(a, &.{ directory, child.name }));
            } else if (options.include_subagents) {
                const subagents = try common.join(a, &.{ directory, child.name, "subagents" });
                if (!common.exists(subagents)) continue;
                const nested = common.walkFiles(a, subagents, ".jsonl") catch |err| {
                    std.debug.print("Warning: Cannot inspect Claude subagents {s}: {s}\n", .{ subagents, @errorName(err) });
                    continue;
                };
                try paths.appendSlice(nested);
            }
        }
    }
    var threads = std.array_list.Managed(common.Thread).init(a);
    for (paths.items) |path| {
        if (!std.mem.endsWith(u8, path, ".jsonl")) continue;
        const relative = path[root.len + 1 ..];
        var parts = std.mem.splitScalar(u8, relative, '/');
        _ = parts.next() orelse continue;
        const second = parts.next() orelse continue;
        const third = parts.next();
        const subagent = third != null;
        if (subagent and (!options.include_subagents or !eq(third.?, "subagents"))) continue;
        const base = std.fs.path.basename(path);
        const stem = base[0 .. base.len - 6];
        if (!subagent and !isUuid(stem)) continue;
        var record: V = .null;
        for (options.import_records) |candidate| if (eq(s(candidate, "sessionId"), stem)) {
            record = candidate;
            break;
        };
        var known_unchanged = false;
        if (s(record, "sha256").len > 0) {
            const digest = common.sha256File(a, path) catch "";
            known_unchanged = eq(digest, s(record, "sha256"));
            if (known_unchanged and !options.include_imported) continue;
        }
        const meta = readMetadata(a, path) catch |err| {
            std.debug.print("Warning: Cannot read Claude conversation {s}: {s}\n", .{ path, @errorName(err) });
            continue;
        };
        const count = meta.count;
        const title = meta.title;
        const ai_title = meta.ai_title;
        const summary = meta.summary;
        const prompt = meta.prompt;
        const cwd = meta.cwd;
        const created_at = meta.created_at;
        const updated_at = meta.updated_at;
        const sidechain = meta.sidechain;
        const unchanged = known_unchanged or (meta.origin_last_uuid.len > 0 and eq(meta.origin_last_uuid, meta.last_uuid));
        if (unchanged and !options.include_imported) continue;
        if (count == 0 or (sidechain and !options.include_subagents)) continue;
        if (cwd.len == 0) {
            std.debug.print("Warning: Claude conversation has no project directory: {s}\n", .{path});
            continue;
        }
        const info = try common.stat(path);
        const fallback = try common.timestamp(a, @intCast(@divTrunc(info.mtime_ns, 1_000_000)));
        const identifier = if (subagent) try common.fmt(a, "{s}/{s}", .{ second, relative[(std.mem.indexOf(u8, relative, "/subagents/").? + 11) .. relative.len - 6] }) else stem;
        try threads.append(.{
            .id = identifier,
            .title = if (title.len > 0) title else if (ai_title.len > 0) ai_title else if (summary.len > 0) summary else if (prompt.len > 0) prompt else try common.fmt(a, "Claude {s}", .{identifier[0..@min(8, identifier.len)]}),
            .cwd = cwd,
            .created_at = if (created_at.len > 0) created_at else fallback,
            .updated_at = if (updated_at.len > 0) updated_at else fallback,
            .rollout_path = path,
            .parent_id = if (subagent) second else null,
            .source = "claude",
            .provider = "claude",
            .origin_provider = if (meta.origin_provider.len > 0) meta.origin_provider else optionalText(record, "sourceProvider") orelse if (record != .null) "codex" else null,
            .origin_id = if (meta.origin_id.len > 0) meta.origin_id else optionalText(record, "sourceThreadId"),
            .history_mode = "claude-native",
            .original_codex_id = if ((meta.origin_provider.len > 0 and !eq(meta.origin_provider, "codex")) or (s(record, "sourceProvider").len > 0 and !eq(s(record, "sourceProvider"), "codex"))) null else optionalText(record, "sourceThreadId") orelse if (meta.original_codex_id.len > 0) meta.original_codex_id else null,
            .unchanged_import = unchanged,
        });
    }
    std.mem.sort(common.Thread, threads.items, {}, newest);
    return threads.toOwnedSlice();
}

pub fn readEntries(a: A, thread: common.Thread, warnings: *common.Warnings) ![]V {
    const all = try common.readJsonl(a, thread.rollout_path, warnings);
    return canonicalEntries(a, all, thread.parent_id != null, warnings);
}
fn canonicalEntries(a: A, all: []const V, sidechain: bool, warnings: *common.Warnings) ![]V {
    var indexed = std.StringHashMap(usize).init(a);
    var parents = std.StringHashMap(void).init(a);
    for (all, 0..) |entry, index| {
        const kind = s(entry, "type");
        if (s(entry, "uuid").len == 0 or !(eq(kind, "user") or eq(kind, "assistant") or eq(kind, "system") or eq(kind, "attachment") or eq(kind, "progress"))) continue;
        try indexed.put(s(entry, "uuid"), index);
    }
    var it = indexed.iterator();
    while (it.next()) |item| {
        const parent = s(all[item.value_ptr.*], "parentUuid");
        if (parent.len > 0) try parents.put(parent, {});
    }
    var leaf: ?usize = null;
    var any_message = false;
    it = indexed.iterator();
    while (it.next()) |item| {
        const entry = all[item.value_ptr.*];
        if (visible(entry, sidechain)) any_message = true;
        if (parents.contains(item.key_ptr.*)) continue;
        var cursor: ?usize = item.value_ptr.*;
        var examined = std.StringHashMap(void).init(a);
        while (cursor) |index| {
            const current = all[index];
            const identifier = s(current, "uuid");
            if (examined.contains(identifier)) break;
            try examined.put(identifier, {});
            if (visible(current, sidechain)) {
                if (leaf == null or index > leaf.?) leaf = index;
                break;
            }
            cursor = indexed.get(s(current, "parentUuid"));
        }
    }
    if (leaf == null) {
        if (any_message) return error.InvalidClaudeParentChain;
        return a.alloc(V, 0);
    }
    var reverse = Values.init(a);
    var visited = std.StringHashMap(void).init(a);
    var cursor = leaf;
    while (cursor) |index| {
        const entry = all[index];
        const identifier = s(entry, "uuid");
        if (visited.contains(identifier)) return error.CyclicClaudeParentChain;
        try visited.put(identifier, {});
        try reverse.append(entry);
        var parent = s(entry, "parentUuid");
        if (parent.len == 0 and eq(s(entry, "type"), "system") and eq(s(entry, "subtype"), "compact_boundary")) parent = s(entry, "logicalParentUuid");
        if (parent.len > 0 and !indexed.contains(parent)) try warnings.append(try common.fmt(a, "Claude conversation references an unavailable historical parent: {s}", .{parent}));
        cursor = indexed.get(parent);
    }
    var result = Values.init(a);
    var index = reverse.items.len;
    while (index > 0) {
        index -= 1;
        const entry = reverse.items[index];
        if (eq(s(entry, "type"), "system") and eq(s(entry, "subtype"), "compact_boundary")) {
            var clean = try obj(a, &.{});
            for ([_][]const u8{ "type", "subtype", "uuid", "parentUuid", "logicalParentUuid", "timestamp", "sessionId", "compactMetadata" }) |key| {
                if (entry.object.get(key)) |value| try common.set(a, &clean, key, value);
            }
            try result.append(clean);
            continue;
        }
        if (!visible(entry, sidechain)) continue;
        var message = try common.clone(a, get(entry, "message"));
        const content = get(message, "content");
        if (content == .array) {
            var blocks = Values.init(a);
            for (content.array.items) |block| if (!eq(s(block, "type"), "thinking") and !eq(s(block, "type"), "redacted_thinking")) try blocks.append(block);
            if (blocks.items.len == 0) continue;
            try common.set(a, &message, "content", .{ .array = blocks });
        } else if (content != .string or content.string.len == 0) continue;
        var clean = try obj(a, &.{});
        for ([_][]const u8{ "type", "uuid", "parentUuid", "timestamp", "sessionId", "isCompactSummary", "cwd" }) |key| {
            if (entry.object.get(key)) |value| try common.set(a, &clean, key, value);
        }
        try common.set(a, &clean, "message", message);
        try result.append(clean);
    }
    return result.toOwnedSlice();
}

pub fn sessionId(a: A, thread_id: []const u8) ![]const u8 {
    return common.uuid5(a, namespace, try common.fmt(a, "session:{s}", .{thread_id}));
}

/// Match Claude's JS path mapping: one replacement per UTF-16 code unit and
/// signed 32-bit Java string hash when the sanitized name exceeds 200 units.
pub fn projectDirectory(a: A, cwd: []const u8) ![]const u8 {
    var path = cwd;
    if (eq(path, "~") or std.mem.startsWith(u8, path, "~/")) {
        const home = common.c.getenv("HOME") orelse return error.HomeNotFound;
        path = try common.join(a, &.{ std.mem.span(home), if (path.len > 2) path[2..] else "" });
    }
    if (!std.fs.path.isAbsolute(path)) {
        const current = common.c.getcwd(null, 0) orelse return error.CurrentDirectoryUnavailable;
        defer common.c.free(current);
        path = try std.fs.path.resolve(a, &.{ std.mem.span(current), path });
    }
    var sanitized = std.array_list.Managed(u8).init(a);
    var hash: u32 = 0;
    var iter = (try std.unicode.Utf8View.init(path)).iterator();
    while (iter.nextCodepoint()) |codepoint| {
        if (codepoint > 0xffff) {
            const scalar = codepoint - 0x10000;
            for ([_]u32{ 0xd800 + (scalar >> 10), 0xdc00 + (scalar & 0x3ff) }) |unit| {
                hash = hash *% 31 +% unit;
                try sanitized.append('-');
            }
        } else {
            hash = hash *% 31 +% @as(u32, codepoint);
            try sanitized.append(if (codepoint < 128 and std.ascii.isAlphanumeric(@intCast(codepoint))) @intCast(codepoint) else '-');
        }
    }
    if (sanitized.items.len <= 200) return sanitized.toOwnedSlice();
    const signed: i32 = @bitCast(hash);
    var magnitude: u64 = @intCast(if (signed < 0) -@as(i64, signed) else signed);
    var digits: [32]u8 = undefined;
    var len: usize = 0;
    const alphabet = "0123456789abcdefghijklmnopqrstuvwxyz";
    while (true) {
        digits[digits.len - 1 - len] = alphabet[@intCast(magnitude % 36)];
        len += 1;
        magnitude /= 36;
        if (magnitude == 0) break;
    }
    return common.fmt(a, "{s}-{s}", .{ sanitized.items[0..200], digits[digits.len - len ..] });
}

fn utf8Prefix(text: []const u8, limit: usize) []const u8 {
    var end = @min(text.len, limit);
    while (end > 0 and end < text.len and text[end] & 0xc0 == 0x80) end -= 1;
    return text[0..end];
}
fn utf8Suffix(text: []const u8, limit: usize) []const u8 {
    var start = text.len - @min(text.len, limit);
    while (start < text.len and text[start] & 0xc0 == 0x80) start += 1;
    return text[start..];
}
fn boundedText(a: A, text: []const u8, budget: usize) ![]const u8 {
    if ((try common.json(a, str(text))).len <= budget) return text;
    const notice = "\n[Excerpt; complete value is retained in the original transcript.]";
    var lo: usize = 0;
    var hi = text.len;
    while (lo < hi) {
        const middle = lo + (hi - lo + 1) / 2;
        const candidate = try common.fmt(a, "{s}{s}", .{ utf8Prefix(text, middle), notice });
        if ((try common.json(a, str(candidate))).len <= budget) lo = middle else hi = middle - 1;
    }
    return common.fmt(a, "{s}{s}", .{ utf8Prefix(text, lo), notice });
}

fn nativeMessage(a: A, role: []const u8, content: V, identifier: []const u8) !V {
    var message = try obj(a, &.{ .{ "role", str(role) }, .{ "content", content } });
    if (eq(role, "assistant")) {
        const compact_id = try std.mem.replaceOwned(u8, a, identifier, "-", "");
        try common.set(a, &message, "id", str(try common.fmt(a, "msg_{s}", .{compact_id})));
        try common.set(a, &message, "type", str("message"));
        try common.set(a, &message, "model", str("<synthetic>"));
        try common.set(a, &message, "stop_reason", str(if (containsBlock(content, "tool_use")) "tool_use" else "end_turn"));
        try common.set(a, &message, "stop_sequence", .null);
        try common.set(a, &message, "usage", try obj(a, &.{ .{ "input_tokens", common.num(0) }, .{ "output_tokens", common.num(0) } }));
    }
    return message;
}
fn messageCost(a: A, role: []const u8, content: V) !usize {
    // Include append()'s envelope; its bytes dominate short image excerpts.
    return (try common.json(a, try nativeMessage(a, role, content, "00000000-0000-0000-0000-000000000000"))).len;
}
fn imageBlock(a: A, mime: []const u8, encoded: []const u8) !V {
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
fn attachmentBlocks(a: A, attachments: []const V, warnings: *common.Warnings, embed: bool) anyerror![]V {
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
fn toolResultBlocks(a: A, value: V, warnings: *common.Warnings, embed: bool) !V {
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
fn safeToolName(a: A, name: []const u8) ![]const u8 {
    const result = try a.dupe(u8, name);
    for (result) |*ch| if (!std.ascii.isAlphanumeric(ch.*) and ch.* != '_' and ch.* != '-') {
        ch.* = '_';
    };
    return result;
}

const Encoder = struct {
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

    fn id(self: *Encoder, purpose: []const u8) ![]const u8 {
        return common.uuid5(self.a, namespace, try common.fmt(self.a, "{s}:{s}", .{ self.sid, purpose }));
    }
    fn append(self: *Encoder, role: []const u8, content: V, timestamp: []const u8, summary: bool) !void {
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
    fn flushRaw(self: *Encoder) !void {
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
                    const image = try canonicalBlocks(self, try arr(self.a, &.{part}));
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
    fn emit(self: *Encoder, item: common.Item) anyerror!void {
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
    fn boundary(self: *Encoder, timestamp: []const u8) !void {
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
    fn sourceBoundary(self: *Encoder, compaction: common.Compaction) anyerror!void {
        if (compaction.summary.len == 0) return;
        try self.flushRaw();
        const timestamp = compaction.timestamp orelse self.thread.updated_at;
        try self.boundary(timestamp);
        try self.append("user", str(try common.fmt(self.a, "[Context summary saved by {s} before migration]\n{s}", .{ self.source_label, compaction.summary })), timestamp, true);
        for (compaction.items) |item| try self.emit(item);
    }
};

const Group = struct { entries: []const V, cost: usize };
fn groupExcerpt(a: A, entries: []const V) !V {
    var texts = std.array_list.Managed([]const u8).init(a);
    for (entries) |entry| {
        const content = get(get(entry, "message"), "content");
        if (content == .string) {
            try texts.append(content.string);
            continue;
        }
        for (list(content)) |block| {
            const kind = s(block, "type");
            if (eq(kind, "text")) {
                try texts.append(s(block, "text"));
            } else if (eq(kind, "tool_use")) {
                try texts.append(try common.fmt(a, "Historical tool: {s}", .{s(block, "name")}));
            } else if (eq(kind, "tool_result")) {
                const output = get(block, "content");
                if (output == .string) try texts.append(output.string) else for (list(output)) |part| {
                    if (eq(s(part, "type"), "text")) try texts.append(s(part, "text"));
                    if (eq(s(part, "type"), "image")) try texts.append("[Image retained in the original native transcript.]");
                }
            } else if (eq(kind, "image")) try texts.append("[Image retained in the original native transcript.]");
        }
    }
    const original = try std.mem.join(a, "\n", texts.items);
    const excerpt = if (original.len > 12_000) try common.fmt(a, "{s}\n[...abridged for continuation context...]\n{s}", .{ utf8Prefix(original, 4000), utf8Suffix(original, 8000) }) else original;
    // Control characters may expand sixfold in JSON. Bound the encoded string.
    const content = try boundedText(a, try common.fmt(a, "[Import continuation excerpt; complete original entry {s} is earlier in this transcript.]\n{s}", .{ s(entries[0], "uuid"), excerpt }), 18_000);
    return obj(a, &.{
        .{ "type", get(entries[0], "type") },                                                                 .{ "timestamp", get(entries[0], "timestamp") },
        .{ "message", try obj(a, &.{ .{ "role", get(entries[0], "type") }, .{ "content", str(content) } }) },
    });
}
fn activeStart(entries: []const V) usize {
    var start: usize = 0;
    for (entries, 0..) |entry, index| if (eq(s(entry, "subtype"), "compact_boundary")) {
        start = index + 1;
    };
    return start;
}
pub fn activeBytes(a: A, entries: []const V) !usize {
    var bytes: usize = 0;
    for (entries[activeStart(entries)..]) |entry| if (isMessage(entry)) {
        bytes += (try common.json(a, get(entry, "message"))).len;
    };
    return bytes;
}
fn addCheckpoint(encoder: *Encoder, compaction: ?common.Compaction) !void {
    const a = encoder.a;
    if (try activeBytes(a, encoder.entries.items) <= max_active_bytes) return;
    const historical_count = encoder.entries.items.len;
    const active = try a.dupe(V, encoder.entries.items[activeStart(encoder.entries.items)..]);
    var groups = std.array_list.Managed(Group).init(a);
    var index: usize = 0;
    while (index < active.len) {
        if (!isMessage(active[index])) {
            index += 1;
            continue;
        }
        const start = index;
        index += 1;
        // Keep a historical tool exchange atomic when selecting recent context.
        while (index < active.len and containsBlock(get(get(active[index], "message"), "content"), "tool_result")) index += 1;
        var group: []const V = active[start..index];
        var cost: usize = 0;
        for (group) |entry| cost += try messageCost(a, s(entry, "type"), get(get(entry, "message"), "content"));
        if (cost > 24_000) {
            const excerpt = try a.alloc(V, 1);
            excerpt[0] = try groupExcerpt(a, group);
            group = excerpt;
            cost = try messageCost(a, s(group[0], "type"), get(get(group[0], "message"), "content"));
        }
        try groups.append(.{ .entries = group, .cost = cost });
    }
    const thread = encoder.thread;
    const location = try boundedText(a, encoder.opts.transcript_path orelse try common.fmt(a, "the JSONL file for Claude session {s}", .{encoder.sid}), 8192);
    var handoff = try common.fmt(a, "This existing conversation was imported from {s} into Claude Code. " ++
        "This is a structural migration checkpoint, not an AI-written summary. " ++
        "The complete visible history remains in the native transcript before this checkpoint. " ++
        "Recent messages follow below with their original roles. Oversized entries are explicitly " ++
        "marked excerpts; their originals are still preserved. Do not replay historical commands.\n\n" ++
        "Project: {s}\nOriginal title: {s}\nOriginal session: {s}\nNative transcript: {s}\n" ++
        "Original history occupies the first {d} JSONL records. Read earlier records when past decisions " ++
        "or details are needed; do not treat this tail as the entire history or ask the user to repeat " ++
        "information without checking. Load current project instructions from its AGENTS.md / CLAUDE.md.\n", .{ encoder.source_label, try boundedText(a, thread.cwd, 4096), try boundedText(a, thread.title, 1024), try boundedText(a, encoder.source_id, 1024), location, historical_count });
    if (compaction) |compact| {
        if (compact.encrypted) handoff = try common.fmt(a, "{s}\nCodex also stored an encrypted internal compaction; that content could not be imported.\n", .{handoff});
        if (compact.summary.len > 0) handoff = try common.fmt(a, "{s}\nLatest readable source context summary:\n{s}", .{ handoff, try boundedText(a, compact.summary, 40_000) });
    }
    const handoff_cost = try messageCost(a, "user", str(handoff));
    if (handoff_cost >= max_active_bytes) return error.CheckpointExceedsContextBudget;
    var remaining: usize = @min(recent_context_bytes, max_active_bytes - handoff_cost);
    var first = groups.items.len;
    while (first > 0) {
        const group = groups.items[first - 1];
        if (group.cost > remaining) break;
        first -= 1;
        remaining -= group.cost;
    }
    try encoder.boundary(thread.updated_at);
    try encoder.append("user", str(handoff), thread.updated_at, true);
    for (groups.items[first..]) |group| {
        var remap = std.StringHashMap([]const u8).init(a);
        for (group.entries) |entry| {
            const content = try common.clone(a, get(get(entry, "message"), "content"));
            if (content == .array) for (content.array.items) |*block| {
                if (eq(s(block.*, "type"), "tool_use")) {
                    const old = s(block.*, "id");
                    const stable = try encoder.id(try common.fmt(a, "checkpoint:{s}", .{old}));
                    const fresh = try common.fmt(a, "toolu_codex_{s}", .{try std.mem.replaceOwned(u8, a, stable, "-", "")});
                    try remap.put(old, fresh);
                    try common.set(a, block, "id", str(fresh));
                } else if (eq(s(block.*, "type"), "tool_result")) {
                    const fresh = remap.get(s(block.*, "tool_use_id")) orelse return error.OrphanCheckpointToolResult;
                    try common.set(a, block, "tool_use_id", str(fresh));
                }
            };
            try encoder.append(s(entry, "type"), content, s(entry, "timestamp"), false);
        }
    }
    if (try activeBytes(a, encoder.entries.items) > max_active_bytes) return error.CheckpointExceedsContextBudget;
    try encoder.warnings.append("Large thread received a bounded continuation checkpoint; full native history preserved");
}

fn providerLabel(provider: []const u8) []const u8 {
    if (eq(provider, "codex")) return "Codex";
    if (eq(provider, "claude")) return "Claude Code";
    if (eq(provider, "opencode")) return "OpenCode";
    if (eq(provider, "omp") or eq(provider, "oh-my-pi")) return "Oh My Pi";
    return provider;
}

pub fn convert(a: A, thread: common.Thread, items: []const common.Item, compaction: ?common.Compaction, opts: common.ConvertOptions) !common.Conversion {
    const source_provider = opts.source_provider orelse "codex";
    const source_id = opts.source_session_id orelse thread.id;
    const source_label = providerLabel(source_provider);
    var encoder = Encoder{ .a = a, .thread = thread, .opts = opts, .sid = try common.sessionIdFor(a, "claude", source_provider, source_id), .source_provider = source_provider, .source_id = source_id, .source_label = source_label, .entries = Values.init(a), .warnings = common.Warnings.init(a) };
    if (compaction) |compact| if (compact.encrypted) {
        try encoder.warnings.append("Encrypted Codex compaction is unavailable; visible transcript preserved");
    };
    var inserted = false;
    for (items) |item| {
        if (compaction) |compact| if (compact.summary.len > 0 and item.ordinal > compact.ordinal and !inserted) {
            try encoder.sourceBoundary(compact);
            inserted = true;
        };
        try encoder.emit(item);
    }
    if (compaction) |compact| if (compact.summary.len > 0 and !inserted) {
        try encoder.sourceBoundary(compact);
    };
    return finishEncoder(&encoder, items.len, compaction);
}
fn finishEncoder(encoder: *Encoder, source_count: usize, compaction: ?common.Compaction) !common.Conversion {
    const a = encoder.a;
    const thread = encoder.thread;
    try encoder.flushRaw();
    if (encoder.message_count == 0) return .{ .entries = &.{}, .warnings = try encoder.warnings.toOwnedSlice(), .session_id = encoder.sid, .source_item_count = source_count };
    try addCheckpoint(encoder, compaction);
    const trimmed = std.mem.trim(u8, thread.title, " \t\r\n");
    const title = if (trimmed.len > 0) trimmed else try common.fmt(a, "{s} {s}", .{ encoder.source_label, encoder.source_id[0..@min(8, encoder.source_id.len)] });
    try encoder.entries.append(try obj(a, &.{
        .{ "type", str("c2c-import") },                .{ "schemaVersion", common.num(1) },                                         .{ "source", str(encoder.source_provider) },
        .{ "sourceThreadId", str(encoder.source_id) }, .{ "lastMessageUuid", if (encoder.parent) |parent| str(parent) else nullv }, .{ "sessionId", str(encoder.sid) },
    }));
    try encoder.entries.append(try obj(a, &.{ .{ "type", str("custom-title") }, .{ "customTitle", str(try common.fmt(a, "{s} · {s}", .{ encoder.source_label, title })) }, .{ "sessionId", str(encoder.sid) } }));
    const errors = try validate(a, encoder.entries.items);
    if (errors.len > 0) return error.InvalidConvertedClaudeSession;
    return .{ .entries = try encoder.entries.toOwnedSlice(), .warnings = try encoder.warnings.toOwnedSlice(), .message_count = encoder.message_count, .tool_count = encoder.tool_count, .source_item_count = source_count, .session_id = encoder.sid };
}

fn canonicalBlocks(encoder: *Encoder, content: V) anyerror!V {
    if (content != .array) return common.clone(encoder.a, content);
    const a = encoder.a;
    var blocks = Values.init(a);
    for (content.array.items) |original| {
        const kind = s(original, "type");
        if (eq(kind, "thinking") or eq(kind, "redacted_thinking")) continue;
        if (eq(kind, "image")) {
            const source = get(original, "source");
            if (eq(s(source, "type"), "base64")) {
                const attachment = try obj(a, &.{.{ "url", str(try common.fmt(a, "data:{s};base64,{s}", .{ s(source, "media_type"), s(source, "data") })) }});
                try blocks.appendSlice(try attachmentBlocks(a, &.{attachment}, &encoder.warnings, encoder.opts.embed_images));
            } else if (s(source, "url").len > 0) {
                try blocks.appendSlice(try attachmentBlocks(a, &.{try obj(a, &.{.{ "url", get(source, "url") }})}, &encoder.warnings, encoder.opts.embed_images));
            } else try blocks.append(try textBlock(a, try common.fmt(a, "[Historical image attachment]\n{s}", .{try common.json(a, original)})));
            continue;
        }
        var block = try common.clone(a, original);
        if (eq(kind, "tool_result") and get(block, "content") == .array) try common.set(a, &block, "content", try canonicalBlocks(encoder, get(block, "content")));
        try blocks.append(block);
    }
    return .{ .array = blocks };
}
fn incompleteResult(a: A, id: []const u8) !V {
    return obj(a, &.{ .{ "type", str("tool_result") }, .{ "tool_use_id", str(id) }, .{ "content", str("[Historical tool had no saved result in the source conversation; it was not run by this import.]") }, .{ "is_error", common.boolean(true) } });
}
fn closePending(encoder: *Encoder, pending: *std.StringHashMap([]const u8), timestamp: []const u8) !void {
    if (pending.count() == 0) return;
    var ids = std.array_list.Managed([]const u8).init(encoder.a);
    var iterator = pending.valueIterator();
    while (iterator.next()) |id| try ids.append(id.*);
    // Sort for deterministic on-disk order.
    std.mem.sort([]const u8, ids.items, {}, struct {
        fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.less);
    var blocks = Values.init(encoder.a);
    for (ids.items) |id| try blocks.append(try incompleteResult(encoder.a, id));
    try encoder.append("user", .{ .array = blocks }, timestamp, false);
    pending.clearRetainingCapacity();
    try encoder.warnings.append("Historical tool call had no saved result; imported as an explicitly closed historical exchange");
}

/// Encode the shared visible-history representation used by other providers.
/// Native tool/image blocks remain structured; no historical call is executed.
pub fn convertEntries(a: A, thread: common.Thread, entries: []const V, opts: common.ConvertOptions) !common.Conversion {
    const source_provider = opts.source_provider orelse thread.provider;
    const source_id = opts.source_session_id orelse thread.id;
    var encoder = Encoder{ .a = a, .thread = thread, .opts = opts, .sid = try common.sessionIdFor(a, "claude", source_provider, source_id), .source_provider = source_provider, .source_id = source_id, .source_label = providerLabel(source_provider), .entries = Values.init(a), .warnings = common.Warnings.init(a) };
    var pending = std.StringHashMap([]const u8).init(a);
    var deferred_images = Values.init(a);
    var latest_summary: ?common.Compaction = null;
    for (entries, 0..) |entry, ordinal| {
        const timestamp = if (s(entry, "timestamp").len > 0) s(entry, "timestamp") else thread.updated_at;
        if (eq(s(entry, "type"), "system") and eq(s(entry, "subtype"), "compact_boundary")) {
            try closePending(&encoder, &pending, timestamp);
            if (deferred_images.items.len > 0) {
                try encoder.append("user", try arr(a, deferred_images.items), timestamp, false);
                deferred_images.clearRetainingCapacity();
            }
            try encoder.boundary(timestamp);
            continue;
        }
        if (!isMessage(entry) or common.b(get(entry, "isMeta")) or s(entry, "teamName").len > 0) continue;
        const role = s(entry, "type");
        var content = try canonicalBlocks(&encoder, get(get(entry, "message"), "content"));
        if ((content == .string and content.string.len == 0) or (content == .array and content.array.items.len == 0)) continue;
        if (content != .string and content != .array) return error.InvalidCanonicalContent;
        if (pending.count() > 0 and !(eq(role, "user") and containsBlock(content, "tool_result"))) try closePending(&encoder, &pending, timestamp);
        if (!encoder.seen_user and !eq(role, "user")) try encoder.append("user", str(try common.fmt(a, "Continue this imported {s} conversation. The following entries are its saved history.", .{encoder.source_label})), thread.created_at, false);
        if (content == .array) {
            var kept = Values.init(a);
            for (content.array.items, 0..) |original, block_index| {
                var block = original;
                if (eq(s(block, "type"), "image") and eq(role, "assistant")) {
                    try deferred_images.append(block);
                    continue;
                }
                if (eq(s(block, "type"), "tool_use")) {
                    if (!eq(role, "assistant")) return error.InvalidCanonicalToolRole;
                    const old = s(block, "id");
                    if (old.len == 0 or pending.contains(old)) return error.InvalidCanonicalToolId;
                    const identifier = try encoder.id(try common.fmt(a, "canonical-tool:{d}:{d}:{s}", .{ ordinal, block_index, old }));
                    const fresh = try common.fmt(a, "toolu_c2c_{s}", .{try std.mem.replaceOwned(u8, a, identifier, "-", "")});
                    try common.set(a, &block, "id", str(fresh));
                    try pending.put(old, fresh);
                    encoder.tool_count += 1;
                } else if (eq(s(block, "type"), "tool_result")) {
                    if (!eq(role, "user")) return error.InvalidCanonicalToolRole;
                    const old = s(block, "tool_use_id");
                    if (pending.fetchRemove(old)) |mapping| {
                        try common.set(a, &block, "tool_use_id", str(mapping.value));
                    } else {
                        block = try textBlock(a, try common.fmt(a, "[Historical tool result without an available call]\n{s}", .{try common.json(a, block)}));
                        try encoder.warnings.append("Historical tool result had no available call; preserved its complete payload as text");
                    }
                }
                try kept.append(block);
            }
            // If only some results were saved, close the remaining calls in
            // this same user turn so native resumption never sees pending work.
            if (eq(role, "user") and pending.count() > 0) {
                var ids = std.array_list.Managed([]const u8).init(a);
                var iterator = pending.valueIterator();
                while (iterator.next()) |id| try ids.append(id.*);
                std.mem.sort([]const u8, ids.items, {}, struct {
                    fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
                        return std.mem.order(u8, lhs, rhs) == .lt;
                    }
                }.less);
                for (ids.items) |id| try kept.append(try incompleteResult(a, id));
                pending.clearRetainingCapacity();
                try encoder.warnings.append("Historical tool call had no saved result; imported as an explicitly closed historical exchange");
            }
            content = .{ .array = kept };
        }
        const summary = common.b(get(entry, "isCompactSummary"));
        if (summary) {
            var texts = std.array_list.Managed([]const u8).init(a);
            if (content == .string) try texts.append(content.string) else for (list(content)) |block| {
                if (eq(s(block, "type"), "text")) try texts.append(s(block, "text"));
            }
            latest_summary = .{ .summary = try std.mem.join(a, "\n", texts.items), .timestamp = timestamp };
        }
        if (content != .array or content.array.items.len > 0) try encoder.append(role, content, timestamp, summary);
        if (pending.count() == 0 and deferred_images.items.len > 0) {
            try encoder.append("user", try arr(a, deferred_images.items), timestamp, false);
            deferred_images.clearRetainingCapacity();
        }
    }
    try closePending(&encoder, &pending, thread.updated_at);
    if (deferred_images.items.len > 0) try encoder.append("user", try arr(a, deferred_images.items), thread.updated_at, false);
    return finishEncoder(&encoder, entries.len, latest_summary);
}

pub fn validate(a: A, entries: []const V) ![][]const u8 {
    var errors = common.Warnings.init(a);
    var seen = std.StringHashMap(void).init(a);
    var session_ids = std.StringHashMap(void).init(a);
    var pending = std.StringHashMap(void).init(a);
    var all_tools = std.StringHashMap(void).init(a);
    var user_seen = false;
    var messages: usize = 0;
    for (entries, 0..) |entry, index| {
        const kind = s(entry, "type");
        if (s(entry, "sessionId").len > 0) try session_ids.put(s(entry, "sessionId"), {});
        const identifier = s(entry, "uuid");
        if (identifier.len > 0) {
            if (seen.contains(identifier)) try errors.append(try common.fmt(a, "entry {d}: duplicate uuid", .{index}));
            const parent = s(entry, "parentUuid");
            if (parent.len > 0 and !seen.contains(parent)) try errors.append(try common.fmt(a, "entry {d}: missing parent", .{index}));
            const logical_parent = s(entry, "logicalParentUuid");
            if (logical_parent.len > 0 and !seen.contains(logical_parent)) try errors.append(try common.fmt(a, "entry {d}: missing logical parent", .{index}));
            try seen.put(identifier, {});
        }
        if (eq(kind, "system") and eq(s(entry, "subtype"), "compact_boundary")) {
            if (pending.count() > 0) try errors.append(try common.fmt(a, "entry {d}: pending tool across compaction", .{index}));
            if (get(entry, "parentUuid") != .null) try errors.append(try common.fmt(a, "entry {d}: compaction must start a new active chain", .{index}));
            continue;
        }
        if (!eq(kind, "user") and !eq(kind, "assistant")) {
            if (get(entry, "message") != .null) try errors.append(try common.fmt(a, "entry {d}: invalid message role", .{index}));
            continue;
        }
        messages += 1;
        if (eq(kind, "user")) user_seen = true;
        if (identifier.len == 0) try errors.append(try common.fmt(a, "entry {d}: missing uuid", .{index}));
        if (!eq(s(get(entry, "message"), "role"), kind)) try errors.append(try common.fmt(a, "entry {d}: role mismatch", .{index}));
        const sidechain = get(entry, "isSidechain");
        if (sidechain != .bool or sidechain.bool or !eq(s(entry, "entrypoint"), "cli")) try errors.append(try common.fmt(a, "entry {d}: not a normal CLI session", .{index}));
        const content = get(get(entry, "message"), "content");
        if (pending.count() > 0) {
            var returns = std.StringHashMap(void).init(a);
            for (list(content)) |block| if (eq(s(block, "type"), "tool_result")) {
                try returns.put(s(block, "tool_use_id"), {});
            };
            var complete = eq(kind, "user");
            var iter = pending.keyIterator();
            while (iter.next()) |tool_id| if (!returns.contains(tool_id.*)) {
                complete = false;
            };
            if (!complete) try errors.append(try common.fmt(a, "entry {d}: tool results must immediately follow their calls", .{index}));
        }
        if (content == .string) {
            if (content.string.len == 0) try errors.append(try common.fmt(a, "entry {d}: empty message", .{index}));
            continue;
        }
        if (content != .array or list(content).len == 0) try errors.append(try common.fmt(a, "entry {d}: empty or invalid message", .{index}));
        for (list(content)) |block| {
            if (block != .object) {
                try errors.append(try common.fmt(a, "entry {d}: invalid content block", .{index}));
                continue;
            }
            if (eq(s(block, "type"), "tool_use")) {
                const tool_id = s(block, "id");
                if (all_tools.contains(tool_id) or tool_id.len == 0) try errors.append(try common.fmt(a, "entry {d}: duplicate/empty tool ID", .{index}));
                if (!eq(kind, "assistant")) try errors.append(try common.fmt(a, "entry {d}: tool call must be assistant content", .{index}));
                try pending.put(tool_id, {});
                try all_tools.put(tool_id, {});
            } else if (eq(s(block, "type"), "tool_result")) {
                const tool_id = s(block, "tool_use_id");
                if (!pending.remove(tool_id)) try errors.append(try common.fmt(a, "entry {d}: orphan tool result", .{index}));
                if (!eq(kind, "user")) try errors.append(try common.fmt(a, "entry {d}: tool result must be user content", .{index}));
            }
        }
    }
    if (pending.count() > 0) try errors.append("session ends with unresolved tool calls");
    if (session_ids.count() != 1) try errors.append("session ID missing or inconsistent");
    if (messages == 0) try errors.append("session has no conversation messages");
    if (messages > 0 and !user_seen) try errors.append("session has no user message for discovery");
    return errors.toOwnedSlice();
}

const stamp = "2026-10-06T00:00:00.000Z";
fn fixtureThread() common.Thread {
    return .{ .id = "fixture-thread-1", .title = "Original title", .cwd = "/tmp/c2c-fixture", .created_at = stamp, .updated_at = stamp, .rollout_path = "/tmp/no-personal-transcripts" };
}
fn fixtureItem(role: []const u8, text: []const u8, ordinal: i64) common.Item {
    return .{ .id = "fixture", .role = role, .text = text, .timestamp = stamp, .kind = if (eq(role, "user")) "userMessage" else "agentMessage", .ordinal = ordinal };
}
fn fixtureMessage(a: A, id: []const u8, parent: ?[]const u8, role: []const u8, content: V) !V {
    return obj(a, &.{ .{ "uuid", str(id) }, .{ "parentUuid", if (parent) |p| str(p) else nullv }, .{ "type", str(role) }, .{ "message", try obj(a, &.{ .{ "role", str(role) }, .{ "content", content } }) } });
}
test "Claude canonical export selects branch and bridges compaction while stripping hidden blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var warnings = common.Warnings.init(a);
    const records = [_]V{
        try fixtureMessage(a, "root", null, "user", str("Original prompt")),
        try fixtureMessage(a, "old", "root", "assistant", str("Abandoned answer")),
        try fixtureMessage(a, "selected", "root", "assistant", try arr(a, &.{ try textBlock(a, "Selected answer"), try obj(a, &.{ .{ "type", str("thinking") }, .{ "thinking", str("hidden-secret") } }) })),
        try obj(a, &.{ .{ "uuid", str("boundary") }, .{ "parentUuid", .null }, .{ "logicalParentUuid", str("selected") }, .{ "type", str("system") }, .{ "subtype", str("compact_boundary") } }),
        try fixtureMessage(a, "summary", "boundary", "user", str("Saved summary")),
    };
    const exported = try canonicalEntries(a, &records, false, &warnings);
    try std.testing.expectEqual(@as(usize, 4), exported.len);
    try std.testing.expectEqualStrings("selected", s(exported[1], "uuid"));
    const serialized = try common.json(a, try arr(a, exported));
    try std.testing.expect(std.mem.indexOf(u8, serialized, "Abandoned") == null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "hidden-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "Saved summary") != null);
}
test "Claude canonical cycles fail explicitly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var warnings = common.Warnings.init(a);
    const records = [_]V{ try fixtureMessage(a, "one", "two", "user", str("one")), try fixtureMessage(a, "two", "one", "assistant", str("two")) };
    try std.testing.expectError(error.InvalidClaudeParentChain, canonicalEntries(a, &records, false, &warnings));
}
test "Claude UUIDs and native UTF16 project mapping are stable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(try sessionId(a, "fixture"), try sessionId(a, "fixture"));
    try std.testing.expectEqualStrings("-home-me-a-project-v2", try projectDirectory(a, "/home/me/a_project.v2"));
    try std.testing.expectEqualStrings("-tmp---", try projectDirectory(a, "/tmp/😀"));
    const long = try common.fmt(a, "/{s}😀", .{"a" ** 198});
    try std.testing.expectEqualStrings("-" ++ "a" ** 198 ++ "--b5wpam", try projectDirectory(a, long));
}
test "Claude tools are completed pairs with stable identifiers and preserve artifacts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var command = fixtureItem("assistant", "", 1);
    command.kind = "commandExecution";
    command.raw = try common.parse(a, "{\"command\":\"fixture-only\",\"aggregatedOutput\":\"original output\",\"status\":\"inProgress\"}");
    var mcp = fixtureItem("assistant", "", 2);
    mcp.kind = "mcpToolCall";
    mcp.raw = try common.parse(a, "{\"server\":\"old.server\",\"tool\":\"lookup/item\",\"arguments\":{\"x\":2},\"status\":\"completed\",\"result\":{\"isError\":true,\"value\":\"original result\"}}");
    const items = [_]common.Item{ fixtureItem("user", "Inspect", 0), command, mcp };
    const result = try convert(a, fixtureThread(), &items, null, .{});
    try std.testing.expectEqual(@as(usize, 2), result.tool_count);
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, result.entries)).len);
    const serialized = try common.json(a, try arr(a, result.entries));
    try std.testing.expect(std.mem.indexOf(u8, serialized, "not resumed or executed") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "mcp__old_server__lookup_item") != null);
    try std.testing.expectEqualStrings(s(list(get(get(result.entries[1], "message"), "content"))[0], "id"), s(list(get(get(result.entries[2], "message"), "content"))[0], "tool_use_id"));
    try std.testing.expect(common.b(get(list(get(get(result.entries[4], "message"), "content"))[0], "is_error")));
    var broken = try common.clone(a, try arr(a, result.entries));
    try common.set(a, &broken.array.items[1], "parentUuid", str("missing-parent"));
    try std.testing.expect((try validate(a, broken.array.items)).len > 0);
}
test "Claude checkpoint preserves unicode archive and regenerates tool IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var large = std.array_list.Managed(u8).init(a);
    for (0..16000) |_| try large.appendSlice("पूर्ण मूल इतिहास ");
    var command = fixtureItem("assistant", "", 1);
    command.kind = "commandExecution";
    command.raw = try common.parse(a, "{\"command\":\"echo latest-fixture\",\"status\":\"completed\",\"aggregatedOutput\":\"latest-fixture\",\"exitCode\":0}");
    const result = try convert(a, fixtureThread(), &.{ fixtureItem("user", large.items, 0), command }, null, .{ .transcript_path = "/tmp/c2c-synthetic-native.jsonl" });
    try std.testing.expectEqualStrings(large.items, s(list(get(get(result.entries[0], "message"), "content"))[0], "text"));
    try std.testing.expect(try activeBytes(a, result.entries) <= max_active_bytes);
    try std.testing.expect(activeStart(result.entries) > 0);
    const active = try common.json(a, try arr(a, result.entries[activeStart(result.entries)..]));
    try std.testing.expect(std.mem.indexOf(u8, active, "structural migration checkpoint") != null);
    try std.testing.expect(std.mem.indexOf(u8, active, "latest-fixture") != null);
    try std.testing.expect(std.mem.indexOf(u8, active, "abridged") != null);
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, result.entries)).len);
}
test "Claude image-heavy checkpoints budget actual assistant envelopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoded = try a.alloc(u8, 28000);
    @memset(encoded, 'A');
    var items = std.array_list.Managed(common.Item).init(a);
    try items.append(fixtureItem("user", "Synthetic image archive", 0));
    const raw = try obj(a, &.{
        .{ "server", str("fixture") },                                                                                                                                                                                                                               .{ "tool", str("image") }, .{ "arguments", try obj(a, &.{}) }, .{ "status", str("completed") },
        .{ "result", try obj(a, &.{ .{ "content", try arr(a, &.{try obj(a, &.{ .{ "type", str("image") }, .{ "data", str(encoded) }, .{ "mimeType", str("image/png") } })}) }, .{ "structuredContent", try obj(a, &.{.{ "preserve", common.boolean(true) }}) } }) },
    });
    for (1..901) |ordinal| {
        var item = fixtureItem("assistant", "", @intCast(ordinal));
        item.kind = "mcpToolCall";
        item.raw = raw;
        try items.append(item);
    }
    const summary = try a.alloc(u8, 40000);
    @memset(summary, 's');
    const result = try convert(a, fixtureThread(), items.items, .{ .summary = summary, .timestamp = stamp, .ordinal = -1 }, .{});
    try std.testing.expect(try activeBytes(a, result.entries) <= max_active_bytes);
    try std.testing.expectEqual(@as(usize, 900), result.tool_count);
    var originals: usize = 0;
    for (result.entries) |entry| if (containsBlock(get(get(entry, "message"), "content"), "tool_result")) {
        originals += 1;
    };
    try std.testing.expectEqual(@as(usize, 900), originals);
}

test "Claude recovered images outrank missing paths and retain MCP metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j3ioAAAAASUVORK5CYII=";
    const attachment = try obj(a, &.{ .{ "path", str("/tmp/nonexistent-c2c-fixture-image.png") }, .{ "url", str("data:image/png;base64," ++ png) } });
    var item = fixtureItem("user", "Inspect image", 0);
    item.attachments = &.{attachment};
    const result = try convert(a, fixtureThread(), &.{item}, null, .{});
    const blocks = list(get(get(result.entries[0], "message"), "content"));
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    try std.testing.expectEqualStrings(png, s(get(blocks[2], "source"), "data"));
    try std.testing.expectEqual(@as(usize, 0), result.warnings.len);
    const omitted = try convert(a, fixtureThread(), &.{item}, null, .{ .embed_images = false });
    try std.testing.expect(!containsBlock(get(get(omitted.entries[0], "message"), "content"), "image"));
    var warnings = common.Warnings.init(a);
    const remote = try attachmentBlocks(a, &.{try obj(a, &.{.{ "url", str("https://example.invalid/private.png") }})}, &warnings, true);
    try std.testing.expectEqualStrings("Attachment URL: https://example.invalid/private.png", s(remote[0], "text"));
    const output = try toolResultBlocks(a, try obj(a, &.{
        .{ "content", try arr(a, &.{try obj(a, &.{ .{ "type", str("image") }, .{ "data", str(png) }, .{ "mimeType", str("image/png") } })}) },
        .{ "structuredContent", try obj(a, &.{.{ "calories", common.num(123) }}) },
    }), &warnings, true);
    try std.testing.expectEqualStrings(png, s(get(list(output)[0], "source"), "data"));
    try std.testing.expect(std.mem.indexOf(u8, s(list(output)[1], "text"), "calories") != null);
}

test "Claude source summary preserves original archive and omits hidden reasoning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var hidden = fixtureItem("assistant", "hidden-private-fixture", 1);
    hidden.kind = "reasoning";
    const result = try convert(a, fixtureThread(), &.{ fixtureItem("user", "Old original message", 0), hidden, fixtureItem("assistant", "Recent original answer", 3) }, .{ .summary = "Exact saved summary", .timestamp = stamp, .ordinal = 2, .encrypted = true }, .{});
    const full = try common.json(a, try arr(a, result.entries));
    const active = try common.json(a, try arr(a, result.entries[activeStart(result.entries)..]));
    try std.testing.expect(std.mem.indexOf(u8, full, "Old original message") != null);
    try std.testing.expect(std.mem.indexOf(u8, full, "hidden-private-fixture") == null);
    try std.testing.expect(std.mem.indexOf(u8, active, "Old original message") == null);
    try std.testing.expect(std.mem.indexOf(u8, active, "Exact saved summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, active, "Recent original answer") != null);
    try std.testing.expectEqual(@as(usize, 1), result.warnings.len);
}

test "Claude discovery reads metadata without mutation and skips unchanged provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var template = "/tmp/c2c-claude-test-XXXXXX".*;
    if (common.c.mkdtemp(&template) == null) return error.TestTempDirectory;
    defer _ = common.c.rmdir(&template);
    const projects = try common.join(a, &.{ &template, "projects" });
    try common.mkdirAll(projects);
    const projects_z = try a.dupeZ(u8, projects);
    defer _ = common.c.rmdir(projects_z.ptr);
    const storage = try common.join(a, &.{ projects, "-synthetic-project" });
    try common.mkdirAll(storage);
    const storage_z = try a.dupeZ(u8, storage);
    defer _ = common.c.rmdir(storage_z.ptr);
    const path = try common.join(a, &.{ storage, "966e523c-70cc-4df2-bdcd-e0b17c918d3c.jsonl" });
    defer common.removeFile(path) catch {};
    const first = "{\"type\":\"user\",\"uuid\":\"u1\",\"parentUuid\":null,\"sessionId\":\"966e523c-70cc-4df2-bdcd-e0b17c918d3c\",\"isSidechain\":false,\"timestamp\":\"2026-10-06T00:00:00.000Z\",\"cwd\":\"/tmp/c2c-fixture\",\"message\":{\"role\":\"user\",\"content\":\"Original prompt\"}}\n";
    const marker = "{\"type\":\"c2c-import\",\"source\":\"codex\",\"sourceThreadId\":\"original-codex\",\"lastMessageUuid\":\"u1\"}\n";
    const continued = "{\"type\":\"assistant\",\"uuid\":\"a1\",\"parentUuid\":\"u1\",\"timestamp\":\"2026-10-06T01:00:00.000Z\",\"cwd\":\"/tmp/c2c-fixture\",\"message\":{\"role\":\"assistant\",\"content\":\"Continued in Claude\"}}\n";
    try common.writeExclusive(path, first ++ marker);
    try std.testing.expectEqual(@as(usize, 0), (try listThreads(a, &template, .{})).len);
    const inventory = try listThreads(a, &template, .{ .include_imported = true });
    try std.testing.expectEqual(@as(usize, 1), inventory.len);
    try std.testing.expect(inventory[0].unchanged_import);
    try std.testing.expectEqualStrings("original-codex", inventory[0].original_codex_id.?);
    try std.testing.expectEqualStrings(first ++ marker, try common.readFile(a, path));
    try common.atomicWrite(a, path, first ++ marker ++ continued);
    const threads = try listThreads(a, &template, .{});
    try std.testing.expectEqual(@as(usize, 1), threads.len);
    try std.testing.expect(!threads[0].unchanged_import);
    try std.testing.expectEqualStrings("Original prompt", threads[0].title);
    var warnings = common.Warnings.init(a);
    try std.testing.expectEqual(@as(usize, 2), (try readEntries(a, threads[0], &warnings)).len);
    const generic_marker = "{\"type\":\"c2c-import\",\"source\":\"opencode\",\"sourceThreadId\":\"original-opencode\",\"lastMessageUuid\":\"u1\"}\n";
    try common.atomicWrite(a, path, first ++ generic_marker);
    const generic = try listThreads(a, &template, .{ .include_imported = true });
    try std.testing.expectEqualStrings("claude", generic[0].provider);
    try std.testing.expectEqualStrings("opencode", generic[0].origin_provider.?);
    try std.testing.expectEqualStrings("original-opencode", generic[0].origin_id.?);
    try std.testing.expect(generic[0].original_codex_id == null);
    try std.testing.expect(generic[0].unchanged_import);
}

test "Claude canonical adapter preserves native tool image and compaction content with generic provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j3ioAAAAASUVORK5CYII=";
    var summary = try fixtureMessage(a, "summary", "boundary", "user", str("Exact source summary"));
    try common.set(a, &summary, "isCompactSummary", common.boolean(true));
    const entries = [_]V{
        try fixtureMessage(a, "u1", null, "user", str("Inspect this")),
        try fixtureMessage(a, "a1", "u1", "assistant", try arr(a, &.{try obj(a, &.{ .{ "type", str("tool_use") }, .{ "id", str("source_tool") }, .{ "name", str("inspect") }, .{ "input", try obj(a, &.{.{ "value", common.num(2) }}) } })})),
        try fixtureMessage(a, "r1", "a1", "user", try arr(a, &.{try obj(a, &.{ .{ "type", str("tool_result") }, .{ "tool_use_id", str("source_tool") }, .{ "content", try arr(a, &.{ try imageBlock(a, "image/png", png), try textBlock(a, "Exact result") }) }, .{ "is_error", common.boolean(false) } })})),
        try obj(a, &.{ .{ "type", str("system") }, .{ "subtype", str("compact_boundary") } }),
        summary,
        try fixtureMessage(a, "recent", "summary", "user", str("Continue the task")),
    };
    const result = try convertEntries(a, fixtureThread(), &entries, .{ .source_provider = "opencode", .source_session_id = "source-opencode-1" });
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, result.entries)).len);
    try std.testing.expectEqual(@as(usize, 1), result.tool_count);
    try std.testing.expectEqualStrings("opencode", s(result.entries[result.entries.len - 2], "source"));
    try std.testing.expectEqualStrings("source-opencode-1", s(result.entries[result.entries.len - 2], "sourceThreadId"));
    try std.testing.expectEqualStrings("OpenCode · Original title", s(result.entries[result.entries.len - 1], "customTitle"));
    try std.testing.expectEqualStrings(png, s(get(list(get(list(get(get(result.entries[2], "message"), "content"))[0], "content"))[0], "source"), "data"));
    const active = try common.json(a, try arr(a, result.entries[activeStart(result.entries)..]));
    try std.testing.expect(std.mem.indexOf(u8, active, "Exact source summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, active, "Inspect this") == null);
    const different_source = try convertEntries(a, fixtureThread(), &entries, .{ .source_provider = "omp", .source_session_id = "source-opencode-1" });
    try std.testing.expect(!eq(result.session_id, different_source.session_id));
}

test "Claude canonical unfinished tools become disclosed closed historical exchanges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const call = try fixtureMessage(a, "call", null, "assistant", try arr(a, &.{try obj(a, &.{ .{ "type", str("tool_use") }, .{ "id", str("pending") }, .{ "name", str("Bash") }, .{ "input", try obj(a, &.{.{ "command", str("never-run-this-history") }}) } })}));
    const result = try convertEntries(a, fixtureThread(), &.{call}, .{ .source_provider = "omp" });
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, result.entries)).len);
    try std.testing.expectEqual(@as(usize, 1), result.warnings.len);
    const serialized = try common.json(a, try arr(a, result.entries));
    try std.testing.expect(std.mem.indexOf(u8, serialized, "was not run by this import") != null);
}

fn rawFixture(a: A, kind: []const u8, json: []const u8, ordinal: i64) !common.Item {
    var item = fixtureItem("tool", "", ordinal);
    item.kind = kind;
    item.raw = try common.parse(a, json);
    return item;
}
test "Raw Codex function calls become exact structured native pairs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = [_]common.Item{
        fixtureItem("user", "Inspect without execution", 0),
        try rawFixture(a, "function_call", "{\"call_id\":\"fixture_tool\",\"name\":\"mcp__fixture__inspect\",\"arguments\":\"{\\\"path\\\":\\\"synthetic-never-executed\\\"}\"}", 1),
        try rawFixture(a, "function_call_output", "{\"call_id\":\"fixture_tool\",\"output\":\"MATRIX_TOOL_RESULT: synthetic record found.\"}", 2),
        fixtureItem("assistant", "Done", 3),
    };
    const converted = try convert(a, fixtureThread(), &items, null, .{});
    try std.testing.expectEqual(@as(usize, 1), converted.tool_count);
    const call = list(get(get(converted.entries[1], "message"), "content"))[0];
    const result = list(get(get(converted.entries[2], "message"), "content"))[0];
    try std.testing.expectEqualStrings("tool_use", s(call, "type"));
    try std.testing.expectEqualStrings("mcp__fixture__inspect", s(call, "name"));
    try std.testing.expectEqualStrings("synthetic-never-executed", s(get(call, "input"), "path"));
    try std.testing.expectEqualStrings(s(call, "id"), s(result, "tool_use_id"));
    try std.testing.expectEqualStrings("MATRIX_TOOL_RESULT: synthetic record found.", s(result, "content"));
    try std.testing.expectEqual(@as(usize, 0), converted.warnings.len);
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, converted.entries)).len);
}
test "Raw parallel custom calls preserve call result order and image blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j3ioAAAAASUVORK5CYII=";
    const items = [_]common.Item{
        fixtureItem("user", "Inspect two sources", 0),
        try rawFixture(a, "custom_tool_call", "{\"call_id\":\"first\",\"name\":\"patch\",\"input\":\"exact patch text\"}", 1),
        try rawFixture(a, "function_call", "{\"call_id\":\"second\",\"name\":\"image_tool\",\"arguments\":\"{}\"}", 2),
        try rawFixture(a, "function_call_output", "{\"call_id\":\"second\",\"output\":[{\"type\":\"input_text\",\"text\":\"Original image\"},{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64," ++ png ++ "\"}]}", 3),
        try rawFixture(a, "custom_tool_call_output", "{\"call_id\":\"first\",\"output\":\"Original patch output\"}", 4),
    };
    const converted = try convert(a, fixtureThread(), &items, null, .{});
    const calls = list(get(get(converted.entries[1], "message"), "content"));
    const results = list(get(get(converted.entries[2], "message"), "content"));
    try std.testing.expectEqual(@as(usize, 2), converted.tool_count);
    try std.testing.expectEqualStrings("patch", s(calls[0], "name"));
    try std.testing.expectEqualStrings("exact patch text", s(get(calls[0], "input"), "input"));
    try std.testing.expectEqualStrings(s(calls[1], "id"), s(results[0], "tool_use_id"));
    try std.testing.expectEqualStrings(s(calls[0], "id"), s(results[1], "tool_use_id"));
    try std.testing.expectEqualStrings(png, s(get(list(get(results[0], "content"))[1], "source"), "data"));
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, converted.entries)).len);
}
test "Raw Codex unfinished calls and unmatched results retain disclosed history" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = [_]common.Item{
        fixtureItem("user", "Inspect", 0),
        try rawFixture(a, "function_call", "{\"call_id\":\"pending\",\"name\":\"inspect\",\"arguments\":\"malformed-but-retained\"}", 1),
        fixtureItem("assistant", "Visible interleaved record", 2),
        try rawFixture(a, "function_call_output", "{\"call_id\":\"pending\",\"output\":\"Exact late historical output\"}", 3),
    };
    const converted = try convert(a, fixtureThread(), &items, null, .{});
    const serialized = try common.json(a, try arr(a, converted.entries));
    try std.testing.expect(std.mem.indexOf(u8, serialized, "malformed-but-retained") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "Exact late historical output") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "was not run by this import") != null);
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, converted.entries)).len);
}
