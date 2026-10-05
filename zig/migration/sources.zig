const std = @import("std");
const H = @import("../common.zig");
const A = H.Allocator;
const V = H.Value;
const Options = @import("../cli/options.zig").Options;
const journal = @import("journal.zig");
const source = @import("../source.zig");
const claude = @import("../claude.zig");
const codex = @import("../codex.zig");
const omp = @import("../omp.zig");
const opencode = @import("../opencode.zig");
const Values = std.array_list.Managed(V);
const Strings = std.array_list.Managed([]const u8);

pub fn selected(options: Options, id: []const u8, cwd: []const u8) bool {
    if (options.threads.len > 0 and !H.oneOf(id, options.threads)) return false;
    const project = if (H.eq(cwd, "/")) cwd else std.mem.trimEnd(u8, cwd, "/");
    if (options.projects.len > 0 and !H.oneOf(project, options.projects)) return false;
    if (options.project_prefixes.len > 0) {
        var match = false;
        for (options.project_prefixes) |prefix| if (journal.pathWithin(cwd, prefix)) {
            match = true;
            break;
        };
        if (!match) return false;
    }
    return true;
}

pub fn threadInfo(a: A, thread: H.Thread) !V {
    var result = try H.obj(a, &.{
        .{ "sourceThreadId", H.str(thread.id) },       .{ "title", H.str(thread.title) },             .{ "cwd", H.str(thread.cwd) },
        .{ "createdAt", H.str(thread.created_at) },    .{ "updatedAt", H.str(thread.updated_at) },    .{ "parentId", if (thread.parent_id) |id| H.str(id) else .null },
        .{ "archived", H.boolean(thread.archived) },   .{ "source", H.str(thread.source) },           .{ "historyMode", H.str(thread.history_mode) },
        .{ "sourceProvider", H.str(thread.provider) }, .{ "sourcePath", H.str(thread.rollout_path) },
    });
    if (thread.original_codex_id) |id| try H.set(a, &result, "originalCodexId", H.str(id));
    if (thread.original_claude_id) |id| try H.set(a, &result, "originalClaudeId", H.str(id));
    return result;
}

fn stamp(a: A, thread: H.Thread) !V {
    var result = try H.obj(a, &.{ .{ "path", H.str(thread.rollout_path) }, .{ "updatedAt", H.str(thread.updated_at) } });
    if (H.stat(thread.rollout_path)) |info| {
        try H.set(a, &result, "bytes", H.num(@intCast(info.size)));
        try H.set(a, &result, "mtimeNs", H.num(@intCast(info.mtime_ns)));
    } else |err| {
        if (err != error.FileNotFound) return err;
        try H.set(a, &result, "missing", H.boolean(true));
    }
    return result;
}

pub fn sourceStamp(a: A, options: Options, thread: H.Thread) !V {
    if (options.from == .opencode) return H.obj(a, &.{
        .{ "path", H.str(thread.rollout_path) },                                                                                                         .{ "updatedAt", H.str(thread.updated_at) },
        .{ "nativeFingerprint", H.str((try opencode.nativeFingerprint(a, options.opencode_home, thread.id)) orelse return error.SourceSessionMissing) },
    });
    return stamp(a, thread);
}

pub fn sourceHash(a: A, options: Options, thread: H.Thread) ![]const u8 {
    return if (options.from == .opencode) (try opencode.nativeFingerprint(a, options.opencode_home, thread.id)) orelse error.SourceSessionMissing else H.sha256File(a, thread.rollout_path);
}

fn valueEqual(first: V, second: V) bool {
    if (std.meta.activeTag(first) != std.meta.activeTag(second)) return false;
    return switch (first) {
        .null => true,
        .bool => first.bool == second.bool,
        .integer => first.integer == second.integer,
        .float => first.float == second.float,
        .string => H.eq(first.string, second.string),
        .number_string => H.eq(first.number_string, second.number_string),
        .array => blk: {
            if (first.array.items.len != second.array.items.len) break :blk false;
            for (first.array.items, second.array.items) |left, right| if (!valueEqual(left, right)) break :blk false;
            break :blk true;
        },
        .object => blk: {
            if (first.object.count() != second.object.count()) break :blk false;
            var iterator = first.object.iterator();
            while (iterator.next()) |entry| {
                const other = second.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!valueEqual(entry.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

pub fn equalJson(a: A, first: V, second: V) !bool {
    _ = a;
    return valueEqual(first, second);
}

pub fn originRecords(a: A, options: Options) ![]const V {
    var paths = Strings.init(a);
    const opposite = try H.fmt(a, "{s}-to-{s}", .{ @tagName(options.to), @tagName(options.from) });
    try paths.append(try H.join(a, &.{ options.user_home, ".local", "share", "c2c", opposite, "manifest.json" }));
    if (options.from == .claude and options.to == .codex) try paths.append(try H.join(a, &.{ options.user_home, ".local", "share", "codex-to-claude", "manifest.json" }));
    try paths.appendSlice(options.origin_manifests);
    var result = Values.init(a);
    for (paths.items) |path| {
        const explicit = H.oneOf(path, options.origin_manifests);
        if (!H.exists(path) and !explicit) continue;
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const temp = scratch.allocator();
        const manifest = H.parse(temp, try H.readFile(temp, path)) catch return error.InvalidOriginManifest;
        const direction = if (H.s(manifest, "direction").len == 0) "codex-to-claude" else H.s(manifest, "direction");
        if (!H.eq(direction, opposite)) {
            if (explicit) return error.OriginDirectionMismatch;
            continue;
        }
        const homes_match = if (H.s(manifest, "sourceHome").len > 0) H.eq(H.s(manifest, "sourceHome"), options.home(options.to)) and H.eq(H.s(manifest, "targetHome"), options.home(options.from)) else H.eq(H.s(manifest, "codexHome"), options.codex_home) and H.eq(H.s(manifest, "claudeHome"), options.claude_home);
        if (!homes_match) {
            if (explicit) return error.OriginHomesMismatch;
            continue;
        }
        const imports = H.get(manifest, "imports");
        if (imports != .object) return error.InvalidOriginManifest;
        var iterator = imports.object.iterator();
        while (iterator.next()) |entry| if (H.eq(H.s(entry.value_ptr.*, "status"), "installed")) {
            var record = try H.clone(a, entry.value_ptr.*);
            try H.set(a, &record, "sourceProvider", H.str(try a.dupe(u8, if (H.s(manifest, "from").len > 0) H.s(manifest, "from") else "codex")));
            try result.append(record);
        };
    }
    return result.items;
}

pub fn listThreads(a: A, options: Options, origins: []const V) ![]const H.Thread {
    const threads = switch (options.from) {
        .codex => try source.listThreads(a, options.codex_home),
        .claude => try claude.listThreads(a, options.claude_home, .{ .import_records = origins, .include_imported = true, .include_subagents = options.include_subagents }),
        .omp => try omp.listThreads(a, options.omp_home),
        .opencode => try opencode.listThreads(a, options.opencode_home),
    };
    var selected_threads = std.array_list.Managed(H.Thread).init(a);
    for (threads) |original| if (selected(options, original.id, original.cwd)) {
        var thread = original;
        thread.provider = @tagName(options.from);
        try selected_threads.append(thread);
    };
    return selected_threads.items;
}

pub fn alreadyOrigin(a: A, options: Options, thread: H.Thread, origins: []const V) !?[]const u8 {
    if (thread.unchanged_import) {
        const origin_provider = thread.origin_provider orelse (if (thread.original_codex_id != null) "codex" else if (thread.original_claude_id != null) "claude" else "");
        if (H.eq(origin_provider, @tagName(options.to))) return thread.origin_id orelse thread.original_codex_id orelse thread.original_claude_id orelse thread.id;
    }
    for (origins) |record| {
        const expected = H.s(record, if (options.from == .opencode) "nativeFingerprint" else "sha256");
        if (!H.eq(H.s(record, "sessionId"), thread.id) or expected.len == 0) continue;
        const hash = sourceHash(a, options, thread) catch continue;
        if (H.eq(hash, expected)) return H.s(record, "sourceThreadId");
    }
    return null;
}

pub fn validate(a: A, options: Options, entries: []const V) ![]const []const u8 {
    return switch (options.to) {
        .claude => try claude.validate(a, entries),
        .codex => try codex.validate(a, entries),
        .omp => try omp.validate(a, entries),
        .opencode => try opencode.validate(a, entries),
    };
}

pub fn sessionId(a: A, options: Options, thread: H.Thread) ![]const u8 {
    return if (options.to == .opencode) opencode.sessionId(a, @tagName(options.from), thread.id) else H.sessionIdFor(a, @tagName(options.to), @tagName(options.from), thread.id);
}

pub fn destination(a: A, options: Options, thread: H.Thread, id: []const u8) ![]const u8 {
    const path = switch (options.to) {
        .claude => try H.join(a, &.{ options.claude_home, "projects", try claude.projectDirectory(a, thread.cwd), try H.fmt(a, "{s}.jsonl", .{id}) }),
        .codex => try codex.targetPathFor(a, thread, options.codex_home, @tagName(options.from)),
        .omp => try omp.targetPath(a, thread, options.omp_home),
        .opencode => try opencode.targetPath(a, thread, options.opencode_home),
    };
    return journal.safeTarget(a, options, path);
}

pub fn convert(a: A, options: Options, thread: H.Thread, path: []const u8, warnings: *H.Warnings) !H.Conversion {
    const opts = H.ConvertOptions{ .embed_images = !options.no_images, .transcript_path = path, .source_provider = @tagName(options.from), .source_session_id = thread.id };
    if (options.from == .codex and options.to == .claude) {
        const items = try source.readItems(a, thread, options.codex_home, warnings);
        const compaction = try source.readCompaction(a, thread, warnings);
        return claude.convert(a, thread, items, compaction, opts);
    }
    const entries = switch (options.from) {
        .codex => (try claude.convert(a, thread, try source.readItems(a, thread, options.codex_home, warnings), try source.readCompaction(a, thread, warnings), opts)).entries,
        .claude => try claude.readEntries(a, thread, warnings),
        .omp => try omp.readEntries(a, thread, warnings),
        .opencode => try opencode.readEntries(a, thread, warnings),
    };
    return switch (options.to) {
        .claude => claude.convertEntries(a, thread, entries, opts),
        .codex => codex.convert(a, thread, entries, opts),
        .omp => omp.convert(a, thread, entries, opts),
        .opencode => opencode.convert(a, thread, entries, opts),
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
    const a = arena.allocator();
    const old = try H.parse(a, "{\"path\":\"/source\",\"bytes\":42,\"mtimeNs\":123,\"updatedAt\":\"today\"}");
    const new = try H.parse(a, "{\"path\":\"/source\",\"updatedAt\":\"today\",\"bytes\":42,\"mtimeNs\":123}");
    try std.testing.expect(try equalJson(a, old, new));
}

test "portable origin skip applies only when returning to its origin provider" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const thread = H.Thread{ .id = "copy", .title = "Fixture", .cwd = "/tmp", .created_at = "", .updated_at = "", .rollout_path = "/nonexistent", .provider = "claude", .origin_provider = "codex", .origin_id = "original", .unchanged_import = true };
    try std.testing.expectEqualStrings("original", (try alreadyOrigin(a, .{ .from = .claude, .to = .codex }, thread, &.{})).?);
    try std.testing.expect((try alreadyOrigin(a, .{ .from = .claude, .to = .omp }, thread, &.{})) == null);
}
