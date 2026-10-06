const std = @import("std");
const common = @import("../common.zig");
const Allocator = common.Allocator;
const Value = common.Value;
const Options = @import("../cli/options.zig").Options;
const journal = @import("journal.zig");
const source = @import("../source.zig");
const claude = @import("../claude.zig");
const codex = @import("../codex.zig");
const omp = @import("../omp.zig");
const opencode = @import("../opencode.zig");
const Values = std.array_list.Managed(Value);
const Strings = std.array_list.Managed([]const u8);

pub fn selected(options: Options, id: []const u8, cwd: []const u8) bool {
    if (options.threads.len > 0 and !common.oneOf(id, options.threads)) {
        return false;
    }
    const project = if (common.eq(cwd, "/")) cwd else std.mem.trimEnd(u8, cwd, "/");
    if (options.projects.len > 0 and !common.oneOf(project, options.projects)) {
        return false;
    }
    if (options.project_prefixes.len > 0) {
        var match = false;
        for (options.project_prefixes) |prefix| {
            if (journal.pathWithin(cwd, prefix)) {
                match = true;
                break;
            }
        }
        if (!match) {
            return false;
        }
    }
    return true;
}

pub fn threadInfo(allocator: Allocator, thread: common.Thread) !Value {
    var result = try common.obj(allocator, &.{
        .{ "sourceThreadId", common.str(thread.id) },
        .{ "title", common.str(thread.title) },
        .{ "cwd", common.str(thread.cwd) },
        .{ "createdAt", common.str(thread.created_at) },
        .{ "updatedAt", common.str(thread.updated_at) },
        .{ "parentId", if (thread.parent_id) |id| common.str(id) else .null },
        .{ "archived", common.boolean(thread.archived) },
        .{ "source", common.str(thread.source) },
        .{ "historyMode", common.str(thread.history_mode) },
        .{ "sourceProvider", common.str(thread.provider) },
        .{ "sourcePath", common.str(thread.rollout_path) },
    });
    if (thread.original_codex_id) |id| {
        try common.set(allocator, &result, "originalCodexId", common.str(id));
    }
    if (thread.original_claude_id) |id| {
        try common.set(allocator, &result, "originalClaudeId", common.str(id));
    }
    return result;
}

fn stamp(allocator: Allocator, thread: common.Thread) !Value {
    var result = try common.obj(allocator, &.{
        .{ "path", common.str(thread.rollout_path) },
        .{ "updatedAt", common.str(thread.updated_at) },
    });
    if (common.stat(thread.rollout_path)) |info| {
        try common.set(allocator, &result, "bytes", common.num(@intCast(info.size)));
        try common.set(allocator, &result, "mtimeNs", common.num(@intCast(info.mtime_ns)));
    } else |err| {
        if (err != error.FileNotFound) {
            return err;
        }
        try common.set(allocator, &result, "missing", common.boolean(true));
    }
    return result;
}

pub fn sourceStamp(allocator: Allocator, options: Options, thread: common.Thread) !Value {
    if (options.from == .opencode) {
        const fingerprint = (try opencode.nativeFingerprint(allocator, options.opencode_home, thread.id)) orelse
            return error.SourceSessionMissing;
        return common.obj(allocator, &.{
            .{ "path", common.str(thread.rollout_path) },
            .{ "updatedAt", common.str(thread.updated_at) },
            .{ "nativeFingerprint", common.str(fingerprint) },
        });
    }
    return stamp(allocator, thread);
}

pub fn sourceHash(allocator: Allocator, options: Options, thread: common.Thread) ![]const u8 {
    if (options.from == .opencode) {
        return (try opencode.nativeFingerprint(allocator, options.opencode_home, thread.id)) orelse
            error.SourceSessionMissing;
    }
    return common.sha256File(allocator, thread.rollout_path);
}

fn valueEqual(first: Value, second: Value) bool {
    if (std.meta.activeTag(first) != std.meta.activeTag(second)) {
        return false;
    }
    return switch (first) {
        .null => true,
        .bool => first.bool == second.bool,
        .integer => first.integer == second.integer,
        .float => first.float == second.float,
        .string => common.eq(first.string, second.string),
        .number_string => common.eq(first.number_string, second.number_string),
        .array => blk: {
            if (first.array.items.len != second.array.items.len) {
                break :blk false;
            }
            for (first.array.items, second.array.items) |left, right| {
                if (!valueEqual(left, right)) {
                    break :blk false;
                }
            }
            break :blk true;
        },
        .object => blk: {
            if (first.object.count() != second.object.count()) {
                break :blk false;
            }
            var iterator = first.object.iterator();
            while (iterator.next()) |entry| {
                const other = second.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!valueEqual(entry.value_ptr.*, other)) {
                    break :blk false;
                }
            }
            break :blk true;
        },
    };
}

pub fn equalJson(allocator: Allocator, first: Value, second: Value) !bool {
    _ = allocator;
    return valueEqual(first, second);
}

pub fn originRecords(allocator: Allocator, options: Options) ![]const Value {
    var paths = Strings.init(allocator);
    const opposite = try common.fmt(allocator, "{s}-to-{s}", .{ @tagName(options.to), @tagName(options.from) });
    const reverse_manifest = try common.join(allocator, &.{
        options.user_home, ".local", "share", "c2c", opposite, "manifest.json",
    });
    try paths.append(reverse_manifest);
    if (options.from == .claude and options.to == .codex) {
        const legacy_manifest = try common.join(allocator, &.{
            options.user_home, ".local", "share", "codex-to-claude", "manifest.json",
        });
        try paths.append(legacy_manifest);
    }
    try paths.appendSlice(options.origin_manifests);
    var result = Values.init(allocator);
    for (paths.items) |path| {
        const explicit = common.oneOf(path, options.origin_manifests);
        if (!common.exists(path) and !explicit) {
            continue;
        }
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const temp = scratch.allocator();
        const manifest = common.parse(temp, try common.readFile(temp, path)) catch return error.InvalidOriginManifest;
        const saved_direction = common.stringField(manifest, "direction");
        const direction = if (saved_direction.len == 0) "codex-to-claude" else saved_direction;
        if (!common.eq(direction, opposite)) {
            if (explicit) {
                return error.OriginDirectionMismatch;
            }
            continue;
        }
        const homes_match = if (common.stringField(manifest, "sourceHome").len > 0)
            common.eq(common.stringField(manifest, "sourceHome"), options.home(options.to)) and
                common.eq(common.stringField(manifest, "targetHome"), options.home(options.from))
        else
            common.eq(common.stringField(manifest, "codexHome"), options.codex_home) and
                common.eq(common.stringField(manifest, "claudeHome"), options.claude_home);
        if (!homes_match) {
            if (explicit) {
                return error.OriginHomesMismatch;
            }
            continue;
        }
        const imports = common.get(manifest, "imports");
        if (imports != .object) {
            return error.InvalidOriginManifest;
        }
        var iterator = imports.object.iterator();
        while (iterator.next()) |entry| {
            if (!common.eq(common.stringField(entry.value_ptr.*, "status"), "installed")) {
                continue;
            }
            var record = try common.clone(allocator, entry.value_ptr.*);
            const from = if (common.stringField(manifest, "from").len > 0) common.stringField(manifest, "from") else "codex";
            try common.set(allocator, &record, "sourceProvider", common.str(try allocator.dupe(u8, from)));
            try result.append(record);
        }
    }
    return result.items;
}

pub fn listThreads(allocator: Allocator, options: Options, origins: []const Value) ![]const common.Thread {
    const threads = switch (options.from) {
        .codex => try source.listThreads(allocator, options.codex_home),
        .claude => try claude.listThreads(allocator, options.claude_home, .{
            .import_records = origins,
            .include_imported = true,
            .include_subagents = options.include_subagents,
        }),
        .omp => try omp.listThreads(allocator, options.omp_home),
        .opencode => try opencode.listThreads(allocator, options.opencode_home),
    };
    var selected_threads = std.array_list.Managed(common.Thread).init(allocator);
    for (threads) |original| {
        if (!selected(options, original.id, original.cwd)) {
            continue;
        }
        var thread = original;
        thread.provider = @tagName(options.from);
        try selected_threads.append(thread);
    }
    return selected_threads.items;
}

pub fn alreadyOrigin(allocator: Allocator, options: Options, thread: common.Thread, origins: []const Value) !?[]const u8 {
    if (thread.unchanged_import) {
        const origin_provider = thread.origin_provider orelse
            (if (thread.original_codex_id != null)
                "codex"
            else if (thread.original_claude_id != null)
                "claude"
            else
                "");
        if (common.eq(origin_provider, @tagName(options.to))) {
            return thread.origin_id orelse thread.original_codex_id orelse thread.original_claude_id orelse thread.id;
        }
    }
    for (origins) |record| {
        const expected = common.stringField(record, if (options.from == .opencode) "nativeFingerprint" else "sha256");
        if (!common.eq(common.stringField(record, "sessionId"), thread.id) or expected.len == 0) {
            continue;
        }
        const hash = sourceHash(allocator, options, thread) catch continue;
        if (common.eq(hash, expected)) {
            return common.stringField(record, "sourceThreadId");
        }
    }
    return null;
}

pub fn validate(allocator: Allocator, options: Options, entries: []const Value) ![]const []const u8 {
    return switch (options.to) {
        .claude => try claude.validate(allocator, entries),
        .codex => try codex.validate(allocator, entries),
        .omp => try omp.validate(allocator, entries),
        .opencode => try opencode.validate(allocator, entries),
    };
}

pub fn sessionId(allocator: Allocator, options: Options, thread: common.Thread) ![]const u8 {
    if (options.to == .opencode) {
        return opencode.sessionId(allocator, @tagName(options.from), thread.id);
    }
    return common.sessionIdFor(allocator, @tagName(options.to), @tagName(options.from), thread.id);
}

pub fn destination(allocator: Allocator, options: Options, thread: common.Thread, id: []const u8) ![]const u8 {
    const path = switch (options.to) {
        .claude => try common.join(allocator, &.{
            options.claude_home,
            "projects",
            try claude.projectDirectory(allocator, thread.cwd),
            try common.fmt(allocator, "{s}.jsonl", .{id}),
        }),
        .codex => try codex.targetPathFor(allocator, thread, options.codex_home, @tagName(options.from)),
        .omp => try omp.targetPath(allocator, thread, options.omp_home),
        .opencode => try opencode.targetPath(allocator, thread, options.opencode_home),
    };
    return journal.safeTarget(allocator, options, path);
}

pub fn convert(
    allocator: Allocator,
    options: Options,
    thread: common.Thread,
    path: []const u8,
    warnings: *common.Warnings,
) !common.Conversion {
    const opts = common.ConvertOptions{
        .embed_images = !options.no_images,
        .transcript_path = path,
        .source_provider = @tagName(options.from),
        .source_session_id = thread.id,
    };
    if (options.from == .codex and options.to == .claude) {
        const items = try source.readItems(allocator, thread, options.codex_home, warnings);
        const compaction = try source.readCompaction(allocator, thread, warnings);
        return claude.convert(allocator, thread, items, compaction, opts);
    }
    const entries = switch (options.from) {
        .codex => blk: {
            const items = try source.readItems(allocator, thread, options.codex_home, warnings);
            const compaction = try source.readCompaction(allocator, thread, warnings);
            break :blk (try claude.convert(allocator, thread, items, compaction, opts)).entries;
        },
        .claude => try claude.readEntries(allocator, thread, warnings),
        .omp => try omp.readEntries(allocator, thread, warnings),
        .opencode => try opencode.readEntries(allocator, thread, warnings),
    };
    return switch (options.to) {
        .claude => claude.convertEntries(allocator, thread, entries, opts),
        .codex => codex.convert(allocator, thread, entries, opts),
        .omp => omp.convert(allocator, thread, entries, opts),
        .opencode => opencode.convert(allocator, thread, entries, opts),
    };
}

test "project prefix matches path components and never sibling names" {
    const options = Options{ .project_prefixes = &.{"/projects/app"} };
    try std.testing.expect(selected(options, "one", "/projects/app"));
    try std.testing.expect(selected(options, "one", "/projects/app/mobile"));
    try std.testing.expect(!selected(options, "one", "/projects/application"));
    try std.testing.expect(selected(.{ .projects = &.{"/"} }, "root", "/"));
}

test "legacy stamp equality ignores object field insertion order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const old = try common.parse(allocator, "{\"path\":\"/source\",\"bytes\":42,\"mtimeNs\":123,\"updatedAt\":\"today\"}");
    const new = try common.parse(allocator, "{\"path\":\"/source\",\"updatedAt\":\"today\",\"bytes\":42,\"mtimeNs\":123}");
    try std.testing.expect(try equalJson(allocator, old, new));
}

test "portable origin skip applies only when returning to its origin provider" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const thread = common.Thread{
        .id = "copy",
        .title = "Fixture",
        .cwd = "/tmp",
        .created_at = "",
        .updated_at = "",
        .rollout_path = "/nonexistent",
        .provider = "claude",
        .origin_provider = "codex",
        .origin_id = "original",
        .unchanged_import = true,
    };
    const original = try alreadyOrigin(allocator, .{ .from = .claude, .to = .codex }, thread, &.{});
    try std.testing.expectEqualStrings("original", original.?);
    try std.testing.expect((try alreadyOrigin(allocator, .{ .from = .claude, .to = .omp }, thread, &.{})) == null);
}
