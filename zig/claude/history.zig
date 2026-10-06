const std = @import("std");
const common = @import("../common.zig");
const Allocator = common.Allocator;
const Value = common.Value;
const jsonObject = common.obj;
const field = common.get;
const stringField = common.stringField;
const equal = common.eq;
const elements = common.list;
const ValueList = std.array_list.Managed(Value);
const native = @import("native.zig");
const isMessage = native.isMessage;
const containsBlock = native.containsBlock;
const utf8Prefix = native.utf8Prefix;

pub const ListOptions = struct {
    import_records: []const Value = &.{},
    include_imported: bool = false,
    include_subagents: bool = false,
};

fn visible(entry: Value, sidechain: bool) bool {
    return isMessage(entry) and
        !common.boolValue(field(entry, "isMeta")) and
        stringField(entry, "teamName").len == 0 and
        (sidechain or !common.boolValue(field(entry, "isSidechain")));
}

fn firstPrompt(allocator: Allocator, entry: Value) ![]const u8 {
    if (!equal(stringField(entry, "type"), "user") or
        common.boolValue(field(entry, "isMeta")) or
        common.boolValue(field(entry, "isCompactSummary")))
    {
        return "";
    }
    const content = field(field(entry, "message"), "content");
    if (containsBlock(content, "tool_result")) {
        return "";
    }
    var parts = std.array_list.Managed([]const u8).init(allocator);
    if (content == .string) {
        try parts.append(content.string);
    } else {
        for (elements(content)) |block| {
            if (equal(stringField(block, "type"), "text")) {
                try parts.append(stringField(block, "text"));
            }
        }
    }
    const raw = try std.mem.join(allocator, " ", parts.items);
    var out = std.array_list.Managed(u8).init(allocator);
    var tokens = std.mem.tokenizeAny(u8, raw, " \t\r\n");
    while (tokens.next()) |token| {
        if (out.items.len > 0) {
            try out.append(' ');
        }
        try out.appendSlice(token);
        if (out.items.len >= 200) {
            break;
        }
    }
    return utf8Prefix(out.items, 200);
}

fn isUuid(value: []const u8) bool {
    if (value.len != 36) {
        return false;
    }
    for (value, 0..) |ch, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (ch != '-') {
                return false;
            }
        } else if (!std.ascii.isHex(ch)) {
            return false;
        }
    }
    return true;
}

fn optionalText(entry: Value, key: []const u8) ?[]const u8 {
    const text = stringField(entry, key);
    return if (text.len > 0) text else null;
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

fn readMetadata(allocator: Allocator, path: []const u8) !Metadata {
    // Free each parsed line so inventory retains metadata, not tool results or images.
    var reader = try common.LineReader.open(std.heap.page_allocator, path);
    defer reader.close();
    var meta: Metadata = .{};
    var line_number: usize = 0;
    while (try reader.next()) |line| {
        line_number += 1;
        if (std.mem.trim(u8, line, " \t\r\n").len == 0) {
            continue;
        }
        const parsed = std.json.parseFromSlice(
            Value,
            std.heap.page_allocator,
            line,
            .{ .allocate = .alloc_always },
        ) catch |err| {
            if (reader.offset >= reader.size and !reader.last_terminated and err != error.OutOfMemory) {
                std.debug.print("Warning: {s}:{d}: incomplete final JSON record ignored\n", .{ path, line_number });
                break;
            }
            return err;
        };
        defer parsed.deinit();
        const entry = parsed.value;
        if (entry != .object) {
            return error.InvalidClaudeRecord;
        }
        const kind = stringField(entry, "type");
        if (equal(kind, "custom-title")) {
            meta.title = try allocator.dupe(u8, stringField(entry, "customTitle"));
        }
        if (equal(kind, "ai-title")) {
            meta.ai_title = try allocator.dupe(u8, stringField(entry, "aiTitle"));
        }
        if (equal(kind, "summary")) {
            meta.summary = try allocator.dupe(u8, stringField(entry, "summary"));
        }
        if (equal(kind, "c2c-import") and stringField(entry, "source").len > 0) {
            const source = stringField(entry, "source");
            const source_thread_id = stringField(entry, "sourceThreadId");
            meta.origin_provider = try allocator.dupe(u8, source);
            meta.origin_id = try allocator.dupe(u8, source_thread_id);
            meta.origin_last_uuid = try allocator.dupe(u8, stringField(entry, "lastMessageUuid"));
            if (equal(source, "codex")) {
                meta.original_codex_id = try allocator.dupe(u8, source_thread_id);
            }
        }
        if (!isMessage(entry) or common.boolValue(field(entry, "isMeta")) or stringField(entry, "teamName").len > 0) {
            continue;
        }
        if (meta.count == 0) {
            meta.sidechain = common.boolValue(field(entry, "isSidechain"));
        }
        meta.count += 1;
        // Appended root sidechains must not make an unchanged import appear
        // continued. Explicit subagent transcripts remain independently visible.
        if (!meta.sidechain and common.boolValue(field(entry, "isSidechain"))) {
            continue;
        }
        if (meta.cwd.len == 0) {
            meta.cwd = try allocator.dupe(u8, stringField(entry, "cwd"));
        }
        const timestamp = stringField(entry, "timestamp");
        if (timestamp.len > 0) {
            const timestamp_millis = try common.timestampMillis(timestamp);
            const date = try common.timestamp(allocator, timestamp_millis);
            if (meta.created_at.len == 0) {
                meta.created_at = date;
            }
            meta.updated_at = date;
        }
        const uuid = stringField(entry, "uuid");
        if (uuid.len > 0) {
            meta.last_uuid = try allocator.dupe(u8, uuid);
        }
        if (meta.prompt.len == 0) {
            meta.prompt = try firstPrompt(allocator, entry);
        }
    }
    return meta;
}

pub fn listThreads(allocator: Allocator, home: []const u8, options: ListOptions) ![]common.Thread {
    const root = try common.join(allocator, &.{ home, "projects" });
    if (!common.exists(root)) {
        return allocator.alloc(common.Thread, 0);
    }
    var paths = std.array_list.Managed([]const u8).init(allocator);
    const projects = try common.listDir(allocator, root);
    for (projects) |project| {
        if (!project.is_dir or project.is_symlink) {
            continue;
        }
        const directory = try common.join(allocator, &.{ root, project.name });
        const children = common.listDir(allocator, directory) catch |err| {
            std.debug.print("Warning: Cannot inspect Claude project {s}: {s}\n", .{ directory, @errorName(err) });
            continue;
        };
        for (children) |child| {
            if (child.is_symlink) {
                continue;
            }
            if (!child.is_dir) {
                if (std.mem.endsWith(u8, child.name, ".jsonl")) {
                    const path = try common.join(allocator, &.{ directory, child.name });
                    try paths.append(path);
                }
            } else if (options.include_subagents) {
                const subagents = try common.join(allocator, &.{ directory, child.name, "subagents" });
                if (!common.exists(subagents)) {
                    continue;
                }
                const nested = common.walkFiles(allocator, subagents, ".jsonl") catch |err| {
                    std.debug.print("Warning: Cannot inspect Claude subagents {s}: {s}\n", .{ subagents, @errorName(err) });
                    continue;
                };
                try paths.appendSlice(nested);
            }
        }
    }
    var threads = std.array_list.Managed(common.Thread).init(allocator);
    for (paths.items) |path| {
        if (!std.mem.endsWith(u8, path, ".jsonl")) {
            continue;
        }
        const relative = path[root.len + 1 ..];
        var parts = std.mem.splitScalar(u8, relative, '/');
        _ = parts.next() orelse continue;
        const second = parts.next() orelse continue;
        const third = parts.next();
        const subagent = third != null;
        if (subagent and (!options.include_subagents or !equal(third.?, "subagents"))) {
            continue;
        }
        const base = std.fs.path.basename(path);
        const stem = base[0 .. base.len - 6];
        if (!subagent and !isUuid(stem)) {
            continue;
        }
        var record: Value = .null;
        for (options.import_records) |candidate| {
            if (equal(stringField(candidate, "sessionId"), stem)) {
                record = candidate;
                break;
            }
        }
        var known_unchanged = false;
        const recorded_digest = stringField(record, "sha256");
        if (recorded_digest.len > 0) {
            const digest = common.sha256File(allocator, path) catch "";
            known_unchanged = equal(digest, recorded_digest);
            if (known_unchanged and !options.include_imported) {
                continue;
            }
        }
        const meta = readMetadata(allocator, path) catch |err| {
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
        const unchanged = known_unchanged or (meta.origin_last_uuid.len > 0 and equal(meta.origin_last_uuid, meta.last_uuid));
        if (unchanged and !options.include_imported) {
            continue;
        }
        if (count == 0 or (sidechain and !options.include_subagents)) {
            continue;
        }
        if (cwd.len == 0) {
            std.debug.print("Warning: Claude conversation has no project directory: {s}\n", .{path});
            continue;
        }
        const info = try common.stat(path);
        const fallback = try common.timestamp(allocator, @intCast(@divTrunc(info.mtime_ns, 1_000_000)));
        const identifier = if (subagent) subagent_id: {
            const subagent_start = std.mem.indexOf(u8, relative, "/subagents/").? + 11;
            const subagent_name = relative[subagent_start .. relative.len - 6];
            break :subagent_id try common.fmt(allocator, "{s}/{s}", .{ second, subagent_name });
        } else stem;
        const thread_title = if (title.len > 0)
            title
        else if (ai_title.len > 0)
            ai_title
        else if (summary.len > 0)
            summary
        else if (prompt.len > 0)
            prompt
        else
            try common.fmt(allocator, "Claude {s}", .{identifier[0..@min(8, identifier.len)]});
        var origin_provider: ?[]const u8 = null;
        if (meta.origin_provider.len > 0) {
            origin_provider = meta.origin_provider;
        } else if (optionalText(record, "sourceProvider")) |recorded_provider| {
            origin_provider = recorded_provider;
        } else if (record != .null) {
            origin_provider = "codex";
        }
        const source_provider = stringField(record, "sourceProvider");
        const has_other_provider = (meta.origin_provider.len > 0 and !equal(meta.origin_provider, "codex")) or
            (source_provider.len > 0 and !equal(source_provider, "codex"));
        var original_codex_id: ?[]const u8 = null;
        if (!has_other_provider) {
            if (optionalText(record, "sourceThreadId")) |source_thread_id| {
                original_codex_id = source_thread_id;
            } else if (meta.original_codex_id.len > 0) {
                original_codex_id = meta.original_codex_id;
            }
        }
        try threads.append(.{
            .id = identifier,
            .title = thread_title,
            .cwd = cwd,
            .created_at = if (created_at.len > 0) created_at else fallback,
            .updated_at = if (updated_at.len > 0) updated_at else fallback,
            .rollout_path = path,
            .parent_id = if (subagent) second else null,
            .source = "claude",
            .provider = "claude",
            .origin_provider = origin_provider,
            .origin_id = if (meta.origin_id.len > 0) meta.origin_id else optionalText(record, "sourceThreadId"),
            .history_mode = "claude-native",
            .original_codex_id = original_codex_id,
            .unchanged_import = unchanged,
        });
    }
    std.mem.sort(common.Thread, threads.items, {}, newest);
    return threads.toOwnedSlice();
}

pub fn readEntries(allocator: Allocator, thread: common.Thread, warnings: *common.Warnings) ![]Value {
    const all = try common.readJsonl(allocator, thread.rollout_path, warnings);
    return canonicalEntries(allocator, all, thread.parent_id != null, warnings);
}

pub fn canonicalEntries(
    allocator: Allocator,
    all: []const Value,
    sidechain: bool,
    warnings: *common.Warnings,
) ![]Value {
    var indexed = std.StringHashMap(usize).init(allocator);
    var parents = std.StringHashMap(void).init(allocator);
    for (all, 0..) |entry, index| {
        const kind = stringField(entry, "type");
        const identifier = stringField(entry, "uuid");
        if (identifier.len == 0 or
            !(equal(kind, "user") or equal(kind, "assistant") or equal(kind, "system") or
                equal(kind, "attachment") or equal(kind, "progress")))
        {
            continue;
        }
        try indexed.put(identifier, index);
    }
    var it = indexed.iterator();
    while (it.next()) |item| {
        const parent = stringField(all[item.value_ptr.*], "parentUuid");
        if (parent.len > 0) {
            try parents.put(parent, {});
        }
    }
    var leaf: ?usize = null;
    var any_message = false;
    it = indexed.iterator();
    while (it.next()) |item| {
        const entry = all[item.value_ptr.*];
        if (visible(entry, sidechain)) {
            any_message = true;
        }
        if (parents.contains(item.key_ptr.*)) {
            continue;
        }
        var cursor: ?usize = item.value_ptr.*;
        var examined = std.StringHashMap(void).init(allocator);
        while (cursor) |index| {
            const current = all[index];
            const identifier = stringField(current, "uuid");
            if (examined.contains(identifier)) {
                break;
            }
            try examined.put(identifier, {});
            if (visible(current, sidechain)) {
                if (leaf == null or index > leaf.?) {
                    leaf = index;
                }
                break;
            }
            cursor = indexed.get(stringField(current, "parentUuid"));
        }
    }
    if (leaf == null) {
        if (any_message) {
            return error.InvalidClaudeParentChain;
        }
        return allocator.alloc(Value, 0);
    }
    var reverse = ValueList.init(allocator);
    var visited = std.StringHashMap(void).init(allocator);
    var cursor = leaf;
    while (cursor) |index| {
        const entry = all[index];
        const identifier = stringField(entry, "uuid");
        if (visited.contains(identifier)) {
            return error.CyclicClaudeParentChain;
        }
        try visited.put(identifier, {});
        try reverse.append(entry);
        var parent = stringField(entry, "parentUuid");
        if (parent.len == 0 and
            equal(stringField(entry, "type"), "system") and
            equal(stringField(entry, "subtype"), "compact_boundary"))
        {
            parent = stringField(entry, "logicalParentUuid");
        }
        if (parent.len > 0 and !indexed.contains(parent)) {
            const warning = try common.fmt(
                allocator,
                "Claude conversation references an unavailable historical parent: {s}",
                .{parent},
            );
            try warnings.append(warning);
        }
        cursor = indexed.get(parent);
    }
    var result = ValueList.init(allocator);
    var index = reverse.items.len;
    while (index > 0) {
        index -= 1;
        const entry = reverse.items[index];
        if (equal(stringField(entry, "type"), "system") and equal(stringField(entry, "subtype"), "compact_boundary")) {
            var clean = try jsonObject(allocator, &.{});
            const boundary_keys = [_][]const u8{
                "type",
                "subtype",
                "uuid",
                "parentUuid",
                "logicalParentUuid",
                "timestamp",
                "sessionId",
                "compactMetadata",
            };
            for (boundary_keys) |key| {
                if (entry.object.get(key)) |value| {
                    try common.set(allocator, &clean, key, value);
                }
            }
            try result.append(clean);
            continue;
        }
        if (!visible(entry, sidechain)) {
            continue;
        }
        var message = try common.clone(allocator, field(entry, "message"));
        const content = field(message, "content");
        if (content == .array) {
            var blocks = ValueList.init(allocator);
            for (content.array.items) |block| {
                const block_type = stringField(block, "type");
                if (!equal(block_type, "thinking") and !equal(block_type, "redacted_thinking")) {
                    try blocks.append(block);
                }
            }
            if (blocks.items.len == 0) {
                continue;
            }
            try common.set(allocator, &message, "content", .{ .array = blocks });
        } else if (content != .string or content.string.len == 0) {
            continue;
        }
        var clean = try jsonObject(allocator, &.{});
        const message_keys = [_][]const u8{
            "type",
            "uuid",
            "parentUuid",
            "timestamp",
            "sessionId",
            "isCompactSummary",
            "cwd",
        };
        for (message_keys) |key| {
            if (entry.object.get(key)) |value| {
                try common.set(allocator, &clean, key, value);
            }
        }
        try common.set(allocator, &clean, "message", message);
        try result.append(clean);
    }
    return result.toOwnedSlice();
}

/// Match Claude's JS path mapping: one replacement per UTF-16 code unit and
/// signed 32-bit Java string hash when the sanitized name exceeds 200 units.
pub fn projectDirectory(allocator: Allocator, cwd: []const u8) ![]const u8 {
    var path = cwd;
    if (equal(path, "~") or std.mem.startsWith(u8, path, "~/")) {
        const home = common.c.getenv("HOME") orelse return error.HomeNotFound;
        const relative_path = if (path.len > 2) path[2..] else "";
        path = try common.join(allocator, &.{ std.mem.span(home), relative_path });
    }
    if (!std.fs.path.isAbsolute(path)) {
        const current = common.c.getcwd(null, 0) orelse return error.CurrentDirectoryUnavailable;
        defer common.c.free(current);
        path = try std.fs.path.resolve(allocator, &.{ std.mem.span(current), path });
    }
    var sanitized = std.array_list.Managed(u8).init(allocator);
    var hash: u32 = 0;
    var iter = (try std.unicode.Utf8View.init(path)).iterator();
    while (iter.nextCodepoint()) |codepoint| {
        if (codepoint > 0xffff) {
            const scalar = codepoint - 0x10000;
            const surrogate_pair = [_]u32{
                0xd800 + (scalar >> 10),
                0xdc00 + (scalar & 0x3ff),
            };
            for (surrogate_pair) |unit| {
                hash = hash *% 31 +% unit;
                try sanitized.append('-');
            }
        } else {
            hash = hash *% 31 +% @as(u32, codepoint);
            const replacement: u8 = if (codepoint < 128 and std.ascii.isAlphanumeric(@intCast(codepoint)))
                @intCast(codepoint)
            else
                '-';
            try sanitized.append(replacement);
        }
    }
    if (sanitized.items.len <= 200) {
        return sanitized.toOwnedSlice();
    }
    const signed: i32 = @bitCast(hash);
    var magnitude: u64 = @intCast(if (signed < 0) -@as(i64, signed) else signed);
    var digits: [32]u8 = undefined;
    var len: usize = 0;
    const alphabet = "0123456789abcdefghijklmnopqrstuvwxyz";
    while (true) {
        digits[digits.len - 1 - len] = alphabet[@intCast(magnitude % 36)];
        len += 1;
        magnitude /= 36;
        if (magnitude == 0) {
            break;
        }
    }
    return common.fmt(allocator, "{s}-{s}", .{ sanitized.items[0..200], digits[digits.len - len ..] });
}
