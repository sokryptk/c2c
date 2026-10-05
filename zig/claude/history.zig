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
const native = @import("native.zig");
const isMessage = native.isMessage;
const containsBlock = native.containsBlock;
const utf8Prefix = native.utf8Prefix;

pub const ListOptions = struct {
    import_records: []const V = &.{},
    include_imported: bool = false,
    include_subagents: bool = false,
};

fn visible(entry: V, sidechain: bool) bool {
    return isMessage(entry) and !common.b(get(entry, "isMeta")) and s(entry, "teamName").len == 0 and (sidechain or !common.b(get(entry, "isSidechain")));
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
pub fn canonicalEntries(a: A, all: []const V, sidechain: bool, warnings: *common.Warnings) ![]V {
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
