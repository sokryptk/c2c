//! Migration orchestration. Source stores are read-only; each native destination
//! is published exclusively and tracked by a durable private installation journal.
const std = @import("std");
const H = @import("common.zig");
const source = @import("source.zig");
const claude = @import("claude.zig");
const codex = @import("codex.zig");
const omp = @import("omp.zig");
const opencode = @import("opencode.zig");
const diagnostics = @import("diagnostics.zig");
const A = H.Allocator;
const V = H.Value;
const Values = std.array_list.Managed(V);
const Strings = std.array_list.Managed([]const u8);

pub const Provider = enum { codex, claude, omp, opencode };
pub const Options = struct {
    from: Provider = .codex,
    to: Provider = .claude,
    action: []const u8 = "migrate",
    codex_home: []const u8 = "",
    claude_home: []const u8 = "",
    omp_home: []const u8 = "",
    opencode_home: []const u8 = "",
    output_dir: []const u8 = "",
    user_home: []const u8 = "",
    projects: []const []const u8 = &.{},
    project_prefixes: []const []const u8 = &.{},
    threads: []const []const u8 = &.{},
    origin_manifests: []const []const u8 = &.{},
    json_output: bool = false,
    include_subagents: bool = false,
    no_images: bool = false,
    help: bool = false,

    pub fn direction(self: Options, a: A) ![]const u8 {
        return H.fmt(a, "{s}-to-{s}", .{ @tagName(self.from), @tagName(self.to) });
    }
    fn home(self: Options, selected_provider: Provider) []const u8 {
        return switch (selected_provider) {
            .codex => self.codex_home,
            .claude => self.claude_home,
            .omp => self.omp_home,
            .opencode => self.opencode_home,
        };
    }
};

fn oneOf(value: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (H.eq(value, choice)) return true;
    return false;
}
fn provider(value: []const u8) !Provider {
    return std.meta.stringToEnum(Provider, value) orelse error.UnknownProvider;
}
fn environment(name: [:0]const u8) ?[]const u8 {
    const value = H.c.getenv(name.ptr) orelse return null;
    const text = std.mem.span(value);
    return if (text.len > 0) text else null;
}
fn setDirection(options: *Options, value: []const u8) !void {
    const split = std.mem.indexOf(u8, value, "-to-") orelse return error.InvalidDirection;
    options.from = try provider(value[0..split]);
    options.to = try provider(value[split + 4 ..]);
}

pub fn parseOptions(a: A, args: []const []const u8) !Options {
    var options = Options{};
    options.user_home = if (H.c.getenv("HOME")) |home| try a.dupe(u8, std.mem.span(home)) else return error.HomeNotFound;
    options.codex_home = if (environment("CODEX_HOME")) |home| try a.dupe(u8, home) else try H.join(a, &.{ options.user_home, ".codex" });
    options.claude_home = if (environment("CLAUDE_CONFIG_DIR")) |home| try a.dupe(u8, home) else try H.join(a, &.{ options.user_home, ".claude" });
    options.omp_home = if (environment("PI_CODING_AGENT_DIR")) |home| try a.dupe(u8, home) else try H.join(a, &.{ options.user_home, ".omp", "agent" });
    options.opencode_home = if (environment("XDG_DATA_HOME")) |home| try H.join(a, &.{ home, "opencode" }) else try H.join(a, &.{ options.user_home, ".local", "share", "opencode" });
    var projects = Strings.init(a);
    var prefixes = Strings.init(a);
    var threads = Strings.init(a);
    var origins = Strings.init(a);
    var action_set = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (oneOf(arg, &.{ "--help", "-h" })) {
            options.help = true;
            continue;
        }
        if (H.eq(arg, "--json")) {
            options.json_output = true;
            continue;
        }
        if (H.eq(arg, "--no-images")) {
            options.no_images = true;
            continue;
        }
        if (H.eq(arg, "--include-subagents")) {
            options.include_subagents = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            const separator = std.mem.indexOfScalar(u8, arg, '=');
            const key = if (separator) |offset| arg[0..offset] else arg;
            if (!oneOf(key, &.{ "--from", "--to", "--direction", "--codex-home", "--claude-home", "--omp-home", "--opencode-home", "--output-dir", "--project", "--project-prefix", "--thread", "--origin-manifest" })) return error.UnknownOption;
            const value = if (separator) |offset| arg[offset + 1 ..] else blk: {
                index += 1;
                if (index >= args.len or std.mem.startsWith(u8, args[index], "--")) return error.MissingOptionValue;
                break :blk args[index];
            };
            if (value.len == 0) return error.MissingOptionValue;
            if (H.eq(key, "--from")) options.from = try provider(value) else if (H.eq(key, "--to")) options.to = try provider(value) else if (H.eq(key, "--direction")) try setDirection(&options, value) else if (H.eq(key, "--codex-home")) options.codex_home = value else if (H.eq(key, "--claude-home")) options.claude_home = value else if (H.eq(key, "--omp-home")) options.omp_home = value else if (H.eq(key, "--opencode-home")) options.opencode_home = value else if (H.eq(key, "--output-dir")) options.output_dir = value else if (H.eq(key, "--project")) try projects.append(try H.canonicalPath(a, value)) else if (H.eq(key, "--project-prefix")) try prefixes.append(try H.canonicalPath(a, value)) else if (H.eq(key, "--thread")) try threads.append(value) else if (H.eq(key, "--origin-manifest")) try origins.append(try H.canonicalPath(a, value)) else return error.UnknownOption;
        } else if (oneOf(arg, &.{ "inventory", "migrate", "verify", "list", "undo" })) {
            if (action_set) return error.MultipleActions;
            options.action = arg;
            action_set = true;
        } else if (std.mem.indexOf(u8, arg, "-to-") != null) {
            try setDirection(&options, arg);
        } else return error.UnknownCommand;
    }
    if (args.len == 0) options.help = true;
    if (options.from == options.to) return error.SameProvider;
    options.codex_home = try H.canonicalPath(a, options.codex_home);
    options.claude_home = try H.canonicalPath(a, options.claude_home);
    options.omp_home = try H.canonicalPath(a, options.omp_home);
    options.opencode_home = try H.canonicalPath(a, options.opencode_home);
    if (options.output_dir.len == 0) {
        const legacy = try H.join(a, &.{ options.user_home, ".local", "share", "codex-to-claude" });
        options.output_dir = if (options.from == .codex and options.to == .claude and H.exists(try H.join(a, &.{ legacy, "manifest.json" }))) legacy else try H.join(a, &.{ options.user_home, ".local", "share", "c2c", try options.direction(a) });
    }
    options.output_dir = try H.canonicalPath(a, options.output_dir);
    options.projects = projects.items;
    options.project_prefixes = prefixes.items;
    options.threads = threads.items;
    options.origin_manifests = origins.items;
    return options;
}

fn now(a: A) !V {
    return H.str(try H.timestamp(a, H.nowMillis()));
}
fn pathWithin(path: []const u8, root: []const u8) bool {
    return H.eq(path, root) or (std.mem.startsWith(u8, path, root) and (std.mem.endsWith(u8, root, "/") or (path.len > root.len and path[root.len] == '/')));
}
fn targetRoot(a: A, options: Options) ![]const u8 {
    return switch (options.to) {
        .claude => H.join(a, &.{ options.claude_home, "projects" }),
        .codex => H.join(a, &.{ options.codex_home, "sessions" }),
        .omp => H.join(a, &.{ options.omp_home, "sessions" }),
        .opencode => H.join(a, &.{ options.opencode_home, "c2c-imports" }),
    };
}
fn safeTarget(a: A, options: Options, path: []const u8) ![]const u8 {
    if (!std.fs.path.isAbsolute(path)) return error.UnsafeTargetPath;
    if (H.stat(path)) |info| {
        if (info.is_symlink) return error.UnsafeTargetPath;
    } else |err| {
        if (err != error.FileNotFound) return err;
    }
    const parent = std.fs.path.dirname(path) orelse return error.UnsafeTargetPath;
    const root = try H.canonicalPath(a, try targetRoot(a, options));
    if (!pathWithin(try H.canonicalPath(a, parent), root)) return error.UnsafeTargetPath;
    return path;
}
fn selected(options: Options, id: []const u8, cwd: []const u8) bool {
    if (options.threads.len > 0 and !oneOf(id, options.threads)) return false;
    const project = if (H.eq(cwd, "/")) cwd else std.mem.trimEnd(u8, cwd, "/");
    if (options.projects.len > 0 and !oneOf(project, options.projects)) return false;
    if (options.project_prefixes.len > 0) {
        var match = false;
        for (options.project_prefixes) |prefix| if (pathWithin(cwd, prefix)) {
            match = true;
            break;
        };
        if (!match) return false;
    }
    return true;
}
fn threadInfo(a: A, thread: H.Thread) !V {
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
fn sourcePath(record: V) []const u8 {
    const path = H.s(record, "sourcePath");
    return if (path.len > 0) path else H.s(H.get(record, "sourceStamp"), "path");
}
fn resultContext(a: A, record: V) !V {
    var result = try H.obj(a, &.{ .{ "sourceThreadId", H.get(record, "sourceThreadId") }, .{ "sessionId", H.get(record, "sessionId") }, .{ "targetPath", H.get(record, "targetPath") } });
    if (sourcePath(record).len > 0) try H.set(a, &result, "sourcePath", H.str(sourcePath(record)));
    return result;
}
fn setFailure(a: A, result: *V, code: []const u8, phase: []const u8) !void {
    try H.set(a, result, "status", H.str("error"));
    try H.set(a, result, "errorType", H.str(code));
    try H.set(a, result, "reason", H.str(diagnostics.reason(code)));
    try H.set(a, result, "phase", H.str(phase));
}
fn failedRow(a: A, record: V, code: []const u8, phase: []const u8) !V {
    var result = try resultContext(a, record);
    try setFailure(a, &result, code, phase);
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
fn sourceStamp(a: A, options: Options, thread: H.Thread) !V {
    if (options.from == .opencode) return H.obj(a, &.{
        .{ "path", H.str(thread.rollout_path) },                                                                                                         .{ "updatedAt", H.str(thread.updated_at) },
        .{ "nativeFingerprint", H.str((try opencode.nativeFingerprint(a, options.opencode_home, thread.id)) orelse return error.SourceSessionMissing) },
    });
    return stamp(a, thread);
}
fn sourceHash(a: A, options: Options, thread: H.Thread) ![]const u8 {
    return if (options.from == .opencode) (try opencode.nativeFingerprint(a, options.opencode_home, thread.id)) orelse error.SourceSessionMissing else H.sha256File(a, thread.rollout_path);
}
fn needsRegistration(options: Options) bool {
    return options.to == .codex or options.to == .opencode;
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
fn equalJson(a: A, first: V, second: V) !bool {
    _ = a;
    return valueEqual(first, second);
}
fn removeIfExists(path: []const u8) !void {
    H.removeFile(path) catch |err| {
        if (err != error.FileNotFound) return err;
    };
}
fn syncAncestors(path: []const u8) !void {
    var current = path;
    while (true) {
        try H.syncDir(current);
        const parent = std.fs.path.dirname(current) orelse break;
        if (H.eq(parent, current)) break;
        current = parent;
    }
}
fn writeAll(fd: c_int, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = H.c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (written < 0 and std.c.errno(@as(c_int, -1)) == .INTR) continue;
        if (written <= 0) return error.WriteFailed;
        offset += @intCast(written);
    }
}
var nonce: u64 = 0;
fn unique(a: A) ![]const u8 {
    nonce += 1;
    return H.fmt(a, "{d}-{d}-{d}", .{ H.nowMillis(), H.c.getpid(), nonce });
}
fn writeJsonl(a: A, path: []const u8, entries: []const V) !void {
    const z = try a.dupeZ(u8, path);
    const fd = H.c.open(z, H.c.O_WRONLY | H.c.O_CREAT | H.c.O_EXCL | H.c.O_NOFOLLOW | H.c.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return error.StageCreateFailed;
    defer _ = H.c.close(fd);
    for (entries) |entry| {
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        try writeAll(fd, try H.json(scratch.allocator(), entry));
        try writeAll(fd, "\n");
    }
    if (H.c.fsync(fd) != 0) return error.SyncFailed;
}

const State = struct {
    a: A,
    options: Options,
    manifest: V,
    path: []const u8,
    fn imports(self: *State) *V {
        return self.manifest.object.getPtr("imports").?;
    }
    fn record(self: *State, id: []const u8) V {
        return H.get(self.imports().*, id);
    }
    fn put(self: *State, id: []const u8, value: V) !void {
        try H.set(self.a, self.imports(), id, value);
    }
    fn save(self: *State) !void {
        try H.set(self.a, &self.manifest, "updatedAt", try now(self.a));
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        try H.atomicWrite(a, self.path, try H.json(a, self.manifest));
    }
    fn rememberUndo(self: *State, value: V) !void {
        const backup = H.s(value, "undoBackupPath");
        if (backup.len == 0) return;
        var retained = H.get(self.manifest, "retainedUndos");
        if (retained == .null) retained = try H.arr(self.a, &.{});
        for (H.list(retained)) |entry| if (H.eq(H.s(entry, "undoBackupPath"), backup)) return;
        try retained.array.append(try H.clone(self.a, value));
        try H.set(self.a, &self.manifest, "retainedUndos", retained);
    }
};
fn loadState(a: A, options: Options) !State {
    const path = try H.join(a, &.{ options.output_dir, "manifest.json" });
    var manifest: V = undefined;
    if (H.exists(path)) {
        manifest = try H.parse(a, try H.readFile(a, path));
        if (H.integer(H.get(manifest, "version")) != 1 or H.get(manifest, "imports") != .object) return error.UnsupportedManifest;
        if (H.s(manifest, "sourceHome").len > 0) {
            if (!H.eq(H.s(manifest, "sourceHome"), options.home(options.from)) or !H.eq(H.s(manifest, "targetHome"), options.home(options.to))) return error.ManifestHomesMismatch;
        } else if (!H.eq(H.s(manifest, "codexHome"), options.codex_home) or !H.eq(H.s(manifest, "claudeHome"), options.claude_home)) return error.ManifestHomesMismatch;
        const direction = if (H.s(manifest, "direction").len == 0) "codex-to-claude" else H.s(manifest, "direction");
        if (!H.eq(direction, try options.direction(a))) return error.ManifestDirectionMismatch;
    } else manifest = try H.obj(a, &.{
        .{ "version", H.num(1) },                      .{ "createdAt", try now(a) },                         .{ "codexHome", H.str(options.codex_home) },
        .{ "claudeHome", H.str(options.claude_home) }, .{ "direction", H.str(try options.direction(a)) },    .{ "from", H.str(@tagName(options.from)) },
        .{ "to", H.str(@tagName(options.to)) },        .{ "sourceHome", H.str(options.home(options.from)) }, .{ "targetHome", H.str(options.home(options.to)) },
        .{ "ompHome", H.str(options.omp_home) },       .{ "opencodeHome", H.str(options.opencode_home) },    .{ "imports", try H.obj(a, &.{}) },
    });
    return .{ .a = a, .options = options, .manifest = manifest, .path = path };
}
fn originRecords(a: A, options: Options) ![]const V {
    var paths = Strings.init(a);
    const opposite = try H.fmt(a, "{s}-to-{s}", .{ @tagName(options.to), @tagName(options.from) });
    try paths.append(try H.join(a, &.{ options.user_home, ".local", "share", "c2c", opposite, "manifest.json" }));
    if (options.from == .claude and options.to == .codex) try paths.append(try H.join(a, &.{ options.user_home, ".local", "share", "codex-to-claude", "manifest.json" }));
    try paths.appendSlice(options.origin_manifests);
    var result = Values.init(a);
    for (paths.items) |path| {
        const explicit = oneOf(path, options.origin_manifests);
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
fn listThreads(a: A, options: Options, origins: []const V) ![]const H.Thread {
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
fn alreadyOrigin(a: A, options: Options, thread: H.Thread, origins: []const V) !?[]const u8 {
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
fn validate(a: A, options: Options, entries: []const V) ![]const []const u8 {
    return switch (options.to) {
        .claude => try claude.validate(a, entries),
        .codex => try codex.validate(a, entries),
        .omp => try omp.validate(a, entries),
        .opencode => try opencode.validate(a, entries),
    };
}
fn sessionId(a: A, options: Options, thread: H.Thread) ![]const u8 {
    return if (options.to == .opencode) opencode.sessionId(a, @tagName(options.from), thread.id) else H.sessionIdFor(a, @tagName(options.to), @tagName(options.from), thread.id);
}
fn destination(a: A, options: Options, thread: H.Thread, id: []const u8) ![]const u8 {
    const path = switch (options.to) {
        .claude => try H.join(a, &.{ options.claude_home, "projects", try claude.projectDirectory(a, thread.cwd), try H.fmt(a, "{s}.jsonl", .{id}) }),
        .codex => try codex.targetPathFor(a, thread, options.codex_home, @tagName(options.from)),
        .omp => try omp.targetPath(a, thread, options.omp_home),
        .opencode => try opencode.targetPath(a, thread, options.opencode_home),
    };
    return safeTarget(a, options, path);
}
fn convert(a: A, options: Options, thread: H.Thread, path: []const u8, warnings: *H.Warnings) !H.Conversion {
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

fn inspect(a: A, options: Options, record: V) !V {
    var result = try resultContext(a, record);
    const current = H.s(record, "status");
    var status: []const u8 = "not-installed";
    if (oneOf(current, &.{ "metadata-only", "undone", "error", "collision", "already-origin" })) status = current else if (oneOf(current, &.{ "pending-registration", "registering" })) status = "pending-registration" else if (H.s(record, "targetPath").len > 0) {
        const target = try safeTarget(a, options, H.s(record, "targetPath"));
        if (!H.exists(target)) status = "missing" else {
            var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch.deinit();
            const temp = scratch.allocator();
            var warnings = H.Warnings.init(temp);
            const entries = try H.readJsonl(temp, target, &warnings);
            const errors = try validate(temp, options, entries);
            if (errors.len > 0) {
                status = "invalid";
                var messages = Values.init(a);
                for (errors) |message| try messages.append(H.str(try a.dupe(u8, message)));
                try H.set(a, &result, "validationErrors", try H.arr(a, messages.items));
            } else if (options.to == .opencode) {
                const fingerprint = try opencode.nativeFingerprint(temp, options.opencode_home, H.s(record, "sessionId"));
                status = if (fingerprint == null) "missing" else if (H.eq(fingerprint.?, H.s(record, "nativeFingerprint")) and H.eq(try H.sha256File(temp, target), H.s(record, "sha256"))) "verified" else "continued";
            } else status = if (H.eq(try H.sha256File(temp, target), H.s(record, "sha256"))) "verified" else "continued";
        }
    }
    try H.set(a, &result, "status", H.str(status));
    if (oneOf(status, &.{ "error", "pending-registration" })) {
        const code = if (H.s(record, "errorType").len > 0) H.s(record, "errorType") else H.s(record, "registrationError");
        if (code.len > 0) {
            try H.set(a, &result, "errorType", H.str(code));
            try H.set(a, &result, "reason", H.str(diagnostics.reason(code)));
        }
        try H.set(a, &result, "phase", if (H.eq(status, "pending-registration")) H.str("registration") else H.get(record, "phase"));
    }
    return result;
}
fn recover(state: *State) !void {
    var ids = Strings.init(state.a);
    var iterator = state.imports().object.iterator();
    while (iterator.next()) |entry| try ids.append(entry.key_ptr.*);
    for (ids.items) |id| {
        var record = state.record(id);
        const status = H.s(record, "status");
        if (H.eq(status, "undoing")) {
            const target = try safeTarget(state.a, state.options, H.s(record, "targetPath"));
            const backup = try safeTarget(state.a, state.options, H.s(record, "undoBackupPath"));
            var undone = H.exists(backup) and !H.exists(target);
            if (state.options.to == .opencode and H.exists(backup)) {
                const fingerprint = try opencode.nativeFingerprint(state.a, state.options.opencode_home, H.s(record, "sessionId"));
                if (fingerprint == null and H.exists(target) and H.sameFile(backup, target) and H.eq(try H.sha256File(state.a, target), H.s(record, "sha256"))) try H.removeFile(target);
                if (fingerprint != null and !H.exists(target)) {
                    if (H.eq(fingerprint.?, H.s(record, "nativeFingerprint"))) try opencode.unregister(state.a, state.options.opencode_home, H.s(record, "sessionId")) else undone = false;
                }
                undone = !H.exists(target) and (try opencode.nativeFingerprint(state.a, state.options.opencode_home, H.s(record, "sessionId"))) == null;
            }
            if (undone and state.options.to == .codex) try codex.unregister(state.a, state.options.codex_home, H.s(record, "sessionId"));
            try H.set(state.a, &record, "status", H.str(if (undone) "undone" else "installed"));
            if (undone) try H.set(state.a, &record, "undoneAt", try now(state.a));
            try state.put(id, record);
            try state.save();
        } else if (H.eq(status, "installing")) {
            const target = try safeTarget(state.a, state.options, H.s(record, "targetPath"));
            const temporary = try safeTarget(state.a, state.options, H.s(record, "installTemporary"));
            const new_status: []const u8 = if (H.sameFile(target, temporary)) (if (needsRegistration(state.options)) "pending-registration" else "installed") else if (H.exists(target)) "collision" else "staged";
            try H.set(state.a, &record, "status", H.str(new_status));
            try state.put(id, record);
            try state.save();
        }
        record = state.record(id);
        if (oneOf(H.s(record, "status"), &.{ "installed", "pending-registration", "staged", "collision" }) and H.s(record, "installTemporary").len > 0) {
            try removeIfExists(try safeTarget(state.a, state.options, H.s(record, "installTemporary")));
            _ = record.object.swapRemove("installTemporary");
            try state.put(id, record);
            try state.save();
        }
    }
}
fn install(state: *State, id: []const u8) !void {
    var record = state.record(id);
    const target = try safeTarget(state.a, state.options, H.s(record, "targetPath"));
    const parent = std.fs.path.dirname(target).?;
    try H.mkdirAll(parent);
    try syncAncestors(parent);
    _ = try safeTarget(state.a, state.options, target);
    if (H.exists(target)) {
        try H.set(state.a, &record, "status", H.str("collision"));
        try state.put(id, record);
        try state.save();
        return;
    }
    const stage = H.s(record, "stagePath");
    if (!pathWithin(try H.canonicalPath(state.a, stage), state.options.output_dir) or (try H.stat(stage)).is_symlink or !H.eq(try H.sha256File(state.a, stage), H.s(record, "sha256"))) return error.StagingIntegrityFailed;
    const temporary = try H.join(state.a, &.{ parent, try H.fmt(state.a, ".c2c-install-{s}.tmp", .{try unique(state.a)}) });
    try H.set(state.a, &record, "status", H.str("installing"));
    try H.set(state.a, &record, "installTemporary", H.str(temporary));
    try state.put(id, record);
    try state.save();
    try H.copyExclusive(state.a, stage, temporary);
    var collision = false;
    H.hardLink(temporary, target) catch |err| {
        if (err == error.PathAlreadyExists) collision = true else return err;
    };
    if (!collision) try H.syncDir(parent);
    try H.set(state.a, &record, "status", H.str(if (collision) "collision" else if (needsRegistration(state.options)) "pending-registration" else "installed"));
    try H.set(state.a, &record, "installedAt", try now(state.a));
    try state.put(id, record);
    try state.save();
    try H.removeFile(temporary);
    _ = record.object.swapRemove("installTemporary");
    try state.put(id, record);
    try state.save();
}
fn completeRegistration(state: *State, id: []const u8) !void {
    if (state.options.to == .opencode) return completeOpenCodeRegistration(state, id);
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var record = state.record(id);
    const target = try safeTarget(a, state.options, H.s(record, "targetPath"));
    const stage = H.s(record, "stagePath");
    const expected = if (H.s(record, "sourceConversionSha256").len > 0) H.s(record, "sourceConversionSha256") else H.s(record, "sha256");
    if (!pathWithin(try H.canonicalPath(a, stage), state.options.output_dir) or (try H.stat(stage)).is_symlink or !H.eq(try H.sha256File(a, stage), expected)) return error.StagingIntegrityFailed;
    var warnings = H.Warnings.init(a);
    const staged = try H.readJsonl(a, stage, &warnings);
    if (!try codex.registrationMatches(a, staged, try H.readJsonl(a, target, &warnings))) return error.NativeConversationChanged;
    try H.set(state.a, &record, "status", H.str("registering"));
    try H.set(state.a, &record, "sourceConversionSha256", H.str(expected));
    try state.put(id, record);
    try state.save();
    const registered = try codex.register(a, state.options.codex_home, H.s(record, "sessionId"), H.s(record, "title"));
    const entries = try H.readJsonl(a, target, &warnings);
    if ((try codex.validate(a, entries)).len > 0 or !try codex.registrationMatches(a, staged, entries)) return error.UnexpectedNativeRewrite;
    try H.set(state.a, &record, "status", H.str("installed"));
    try H.set(state.a, &record, "registeredAt", try now(state.a));
    try H.set(state.a, &record, "nativeRegistration", try H.clone(state.a, registered));
    try H.set(state.a, &record, "sha256", H.str(try H.sha256File(state.a, target)));
    _ = record.object.swapRemove("registrationError");
    try state.put(id, record);
    try state.save();
}
fn completeOpenCodeRegistration(state: *State, id: []const u8) !void {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var record = state.record(id);
    const target = try safeTarget(a, state.options, H.s(record, "targetPath"));
    const stage = H.s(record, "stagePath");
    const expected = H.s(record, "sha256");
    if (!pathWithin(try H.canonicalPath(a, stage), state.options.output_dir) or (try H.stat(stage)).is_symlink or !H.eq(try H.sha256File(a, stage), expected)) return error.StagingIntegrityFailed;
    if (!H.eq(try H.sha256File(a, target), expected)) return error.NativeReceiptChanged;
    var warnings = H.Warnings.init(a);
    const staged = try H.readJsonl(a, stage, &warnings);
    if (try opencode.readNative(a, state.options.opencode_home, H.s(record, "sessionId"))) |existing| {
        if (H.eq(H.s(record, "status"), "pending-registration")) {
            try H.set(state.a, &record, "status", H.str("collision"));
            try state.put(id, record);
            try state.save();
            return;
        }
        if (!try opencode.registrationMatches(a, staged, existing)) return error.NativeConversationChanged;
    }
    try H.set(state.a, &record, "status", H.str("registering"));
    try H.set(state.a, &record, "sourceConversionSha256", H.str(expected));
    try state.put(id, record);
    try state.save();
    const registration = try opencode.register(a, state.options.opencode_home, H.s(record, "sessionId"), H.s(record, "title"));
    const native = (try opencode.readNative(a, state.options.opencode_home, H.s(record, "sessionId"))) orelse return error.NativeRegistrationMissing;
    if (!try opencode.registrationMatches(a, staged, native)) return error.UnexpectedNativeRewrite;
    const fingerprint = (try opencode.nativeFingerprint(a, state.options.opencode_home, H.s(record, "sessionId"))) orelse return error.NativeRegistrationMissing;
    try H.set(state.a, &record, "status", H.str("installed"));
    try H.set(state.a, &record, "registeredAt", try now(state.a));
    try H.set(state.a, &record, "nativeRegistration", try H.clone(state.a, registration));
    try H.set(state.a, &record, "nativeFingerprint", H.str(try state.a.dupe(u8, fingerprint)));
    _ = record.object.swapRemove("registrationError");
    try state.put(id, record);
    try state.save();
}

fn stageThread(state: *State, thread: H.Thread, run_directory: []const u8) !V {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before = try sourceStamp(a, state.options, thread);
    const hash: V = if (H.b(H.get(before, "missing"))) .null else H.str(try sourceHash(a, state.options, thread));
    const sid = try sessionId(a, state.options, thread);
    if (state.options.to == .opencode) {
        if (!std.mem.startsWith(u8, sid, "ses_") or sid.len > 128) return error.InvalidSessionId;
        for (sid) |char| if (!std.ascii.isAlphanumeric(char) and char != '_' and char != '-') return error.InvalidSessionId;
    } else if (!H.validUuid(sid)) return error.InvalidSessionId;
    const target = try destination(a, state.options, thread, sid);
    var warnings = H.Warnings.init(a);
    const conversion = try convert(a, state.options, thread, target, &warnings);
    if (!try equalJson(a, before, try sourceStamp(a, state.options, thread))) return error.SourceChangedDuringConversion;
    if (!H.eq(sid, conversion.session_id)) return error.SessionIdentityMismatch;
    try warnings.appendSlice(conversion.warnings);
    var record = try threadInfo(a, thread);
    try H.set(a, &record, "sourceStamp", before);
    try H.set(a, &record, "sourceSha256", hash);
    try H.set(a, &record, "sessionId", H.str(sid));
    var warning_values = Values.init(a);
    for (warnings.items) |message| try warning_values.append(H.str(message));
    try H.set(a, &record, "warnings", try H.arr(a, warning_values.items));
    try H.set(a, &record, "messageCount", H.num(@intCast(conversion.message_count)));
    try H.set(a, &record, "toolCount", H.num(@intCast(conversion.tool_count)));
    try H.set(a, &record, "sourceItemCount", H.num(@intCast(conversion.source_item_count)));
    if (conversion.message_count == 0) try H.set(a, &record, "status", H.str("metadata-only")) else {
        if ((try validate(a, state.options, conversion.entries)).len > 0) return error.NativeValidationFailed;
        try H.mkdirAll(run_directory);
        try syncAncestors(run_directory);
        const stage = try H.join(a, &.{ run_directory, try H.fmt(a, "{s}.jsonl", .{sid}) });
        try writeJsonl(a, stage, conversion.entries);
        try H.syncDir(run_directory);
        try H.set(a, &record, "status", H.str("staged"));
        try H.set(a, &record, "stagePath", H.str(stage));
        try H.set(a, &record, "targetPath", H.str(target));
        try H.set(a, &record, "sha256", H.str(try H.sha256File(a, stage)));
    }
    return H.clone(state.a, record);
}
fn summary(a: A, rows: []const V) !V {
    var counts = try H.obj(a, &.{});
    for (rows) |row| {
        const status = H.s(row, "status");
        try H.set(a, &counts, status, H.num(H.integer(H.get(counts, status)) + 1));
    }
    return H.obj(a, &.{ .{ "counts", counts }, .{ "threads", try H.arr(a, rows) } });
}
fn progress(a: A, index: usize, total: usize, id: []const u8, status: []const u8) !void {
    if (@import("builtin").is_test) return;
    const message = try H.fmt(a, "[{d}/{d}] {s}: {s}\n", .{ index + 1, total, id, status });
    try writeAll(2, message);
}
fn inventory(a: A, options: Options) !V {
    const origins = try originRecords(a, options);
    const threads = try listThreads(a, options, origins);
    var rows = Values.init(a);
    for (threads) |thread| {
        var row = try threadInfo(a, thread);
        const original = try alreadyOrigin(a, options, thread, origins);
        try H.set(a, &row, "status", H.str(if (original != null) "already-origin" else "available"));
        if (original) |id| try H.set(a, &row, "originalThreadId", H.str(id));
        try rows.append(row);
    }
    return summary(a, rows.items);
}
fn migrate(state: *State) !V {
    const a = state.a;
    try recover(state);
    const origins = try originRecords(a, state.options);
    const threads = try listThreads(a, state.options, origins);
    const run_directory = try H.join(a, &.{ state.options.output_dir, "staged", try unique(a) });
    var rows = Values.init(a);
    var pending = std.array_list.Managed(usize).init(a);
    var warning_groups = try H.obj(a, &.{});
    var warning_count: i64 = 0;
    for (threads, 0..) |thread, index| {
        const old = state.record(thread.id);
        var row = try H.obj(a, &.{ .{ "sourceThreadId", H.str(thread.id) }, .{ "sourcePath", H.str(thread.rollout_path) } });
        const current = H.s(old, "status");
        const missing_stage = H.eq(current, "staged") and !H.exists(H.s(old, "stagePath"));
        if (oneOf(current, &.{ "staged", "pending-registration", "registering" }) and !missing_stage) {
            try H.set(a, &row, "status", H.str(current));
            try H.set(a, &row, "sessionId", H.get(old, "sessionId"));
            try H.set(a, &row, "targetPath", H.get(old, "targetPath"));
            try pending.append(index);
        } else if (old != .null and !oneOf(current, &.{ "error", "undone", "metadata-only", "already-origin", "staged" })) {
            row = inspect(a, state.options, old) catch |err| try failedRow(a, old, @errorName(err), "verification");
            try H.set(a, &row, "sourcePath", H.str(thread.rollout_path));
            if (H.eq(H.s(row, "status"), "verified")) try H.set(a, &row, "status", H.str("unchanged"));
            try H.set(a, &row, "sourceChanged", H.boolean(!try equalJson(a, try sourceStamp(a, state.options, thread), H.get(old, "sourceStamp"))));
        } else if (try alreadyOrigin(a, state.options, thread, origins)) |original| {
            var record = try threadInfo(a, thread);
            try H.set(a, &record, "status", H.str("already-origin"));
            try H.set(a, &record, "originalThreadId", H.str(original));
            try state.rememberUndo(old);
            try state.put(thread.id, record);
            try state.save();
            try H.set(a, &row, "status", H.str("already-origin"));
            try H.set(a, &row, "originalThreadId", H.str(original));
        } else {
            const record = stageThread(state, thread, run_directory) catch |err| blk: {
                var failed = try threadInfo(a, thread);
                try setFailure(a, &failed, @errorName(err), "conversion");
                break :blk failed;
            };
            try state.rememberUndo(old);
            try state.put(thread.id, record);
            try state.save();
            try H.set(a, &row, "status", H.get(record, "status"));
            try H.set(a, &row, "sessionId", H.get(record, "sessionId"));
            try H.set(a, &row, "targetPath", H.get(record, "targetPath"));
            if (H.eq(H.s(record, "status"), "error")) {
                try H.set(a, &row, "errorType", H.get(record, "errorType"));
                try H.set(a, &row, "reason", H.get(record, "reason"));
                try H.set(a, &row, "phase", H.str("conversion"));
            }
            const warnings = H.list(H.get(record, "warnings"));
            try H.set(a, &row, "warningCount", H.num(@intCast(warnings.len)));
            warning_count += @intCast(warnings.len);
            for (warnings) |warning| {
                const text = H.text(warning);
                const group = text[0 .. std.mem.indexOf(u8, text, ": ") orelse text.len];
                try H.set(a, &warning_groups, group, H.num(H.integer(H.get(warning_groups, group)) + 1));
            }
            if (H.eq(H.s(record, "status"), "staged")) try pending.append(index);
        }
        try rows.append(row);
        try progress(a, index, threads.len, thread.id, H.s(row, "status"));
    }
    // All selected conversions are on disk before any destination is published.
    for (pending.items) |index| {
        const id = threads[index].id;
        publish(state, id) catch |err| {
            const registration = oneOf(H.s(state.record(id), "status"), &.{ "pending-registration", "registering" });
            try setFailure(a, &rows.items[index], @errorName(err), if (registration) "registration" else "installation");
            if (registration) {
                var record = state.record(id);
                try H.set(a, &record, "registrationError", H.str(@errorName(err)));
                try state.put(id, record);
            }
            try progress(a, index, threads.len, id, "error");
            continue;
        };
        try H.set(a, &rows.items[index], "status", H.get(state.record(id), "status"));
        try progress(a, index, threads.len, id, H.s(rows.items[index], "status"));
    }
    var result = try summary(a, rows.items);
    try H.set(a, &result, "warningCount", H.num(warning_count));
    try H.set(a, &result, "warningGroups", warning_groups);
    try H.set(a, &state.manifest, "lastRun", try H.obj(a, &.{ .{ "at", try now(a) }, .{ "counts", H.get(result, "counts") }, .{ "results", H.get(result, "threads") } }));
    try state.save();
    return result;
}
fn publish(state: *State, id: []const u8) !void {
    if (H.eq(H.s(state.record(id), "status"), "staged")) try install(state, id);
    if (oneOf(H.s(state.record(id), "status"), &.{ "pending-registration", "registering" })) try completeRegistration(state, id);
}
fn undoOne(state: *State, id: []const u8) !V {
    const a = state.a;
    var record = state.record(id);
    var row = try resultContext(a, record);
    if (!H.eq(H.s(record, "status"), "installed")) {
        try H.set(a, &row, "status", H.str("preserved"));
        try H.set(a, &row, "reason", H.get(record, "status"));
        return row;
    }
    const target = try safeTarget(a, state.options, H.s(record, "targetPath"));
    if (!H.exists(target)) {
        try H.set(a, &row, "status", H.str("missing"));
        return row;
    }
    if (!H.eq(try H.sha256File(a, target), H.s(record, "sha256"))) {
        try H.set(a, &row, "status", H.str("preserved"));
        try H.set(a, &row, "reason", H.str("continued-or-modified"));
        return row;
    }
    if (state.options.to == .opencode) {
        if (try opencode.nativeFingerprint(a, state.options.opencode_home, H.s(record, "sessionId"))) |fingerprint| {
            if (!H.eq(fingerprint, H.s(record, "nativeFingerprint"))) {
                try H.set(a, &row, "status", H.str("preserved"));
                try H.set(a, &row, "reason", H.str("continued-or-modified"));
                return row;
            }
        }
    }
    const parent = std.fs.path.dirname(target).?;
    const backup = if (H.s(record, "undoBackupPath").len > 0) try safeTarget(a, state.options, H.s(record, "undoBackupPath")) else try H.join(a, &.{ parent, try H.fmt(a, ".c2c-undo-{s}.retained", .{try unique(a)}) });
    try H.set(a, &record, "status", H.str("undoing"));
    try H.set(a, &record, "undoBackupPath", H.str(backup));
    try state.put(id, record);
    try state.save();
    if (!H.exists(backup)) {
        try H.hardLink(target, backup);
        try H.syncDir(parent);
    }
    const before = try H.stat(target);
    const hash = try H.sha256File(a, target);
    const after = try H.stat(target);
    if (!H.sameFile(backup, target) or !H.eq(hash, H.s(record, "sha256")) or before.size != after.size or before.mtime_ns != after.mtime_ns) {
        try H.set(a, &record, "status", H.str("installed"));
        try state.put(id, record);
        try state.save();
        try H.set(a, &row, "status", H.str("preserved"));
        try H.set(a, &row, "reason", H.str("changed-during-undo"));
        return row;
    }
    if (state.options.to == .codex) try codex.unregister(a, state.options.codex_home, H.s(record, "sessionId")) else {
        if (state.options.to == .opencode) try opencode.unregister(a, state.options.opencode_home, H.s(record, "sessionId"));
        try H.removeFile(target);
    }
    if (H.exists(target)) return error.NativeDeleteIncomplete;
    try H.syncDir(parent);
    try H.set(a, &record, "status", H.str("undone"));
    try H.set(a, &record, "undoneAt", try now(a));
    try state.put(id, record);
    try state.save();
    try H.set(a, &row, "status", H.str("undone"));
    try H.set(a, &row, "retainedPath", H.str(backup));
    return row;
}
fn journalAction(state: *State) !V {
    const a = state.a;
    if (!H.eq(state.options.action, "list")) try recover(state);
    var ids = Strings.init(a);
    var iterator = state.imports().object.iterator();
    while (iterator.next()) |entry| if (selected(state.options, entry.key_ptr.*, H.s(entry.value_ptr.*, "cwd"))) try ids.append(entry.key_ptr.*);
    var rows = Values.init(a);
    for (ids.items) |id| {
        const record = state.record(id);
        const row = (if (H.eq(state.options.action, "undo")) undoOne(state, id) else if (H.eq(state.options.action, "verify")) inspect(a, state.options, record) else H.clone(a, record)) catch |err| try failedRow(a, record, @errorName(err), state.options.action);
        try rows.append(row);
    }
    return summary(a, rows.items);
}

pub fn execute(a: A, options: Options) !V {
    if (H.eq(options.action, "inventory")) {
        var result = try inventory(a, options);
        try H.set(a, &result, "direction", H.str(try options.direction(a)));
        return result;
    }
    try H.mkdirAll(options.output_dir);
    try syncAncestors(options.output_dir);
    const root_z = try a.dupeZ(u8, options.output_dir);
    if (H.c.chmod(root_z, @as(c_uint, 0o700)) != 0) return error.PrivateDirectoryFailed;
    var lock = try H.lock(a, try H.join(a, &.{ options.output_dir, ".lock" }));
    defer lock.close();
    var state = try loadState(a, options);
    var result = if (H.eq(options.action, "migrate")) try migrate(&state) else try journalAction(&state);
    try H.set(a, &result, "manifest", H.str(state.path));
    try H.set(a, &result, "direction", H.str(try options.direction(a)));
    return result;
}
fn terminalFailure(a: A, code: []const u8, phase: []const u8) !V {
    var result = try H.obj(a, &.{
        .{ "error", H.str(code) },                      .{ "errorType", H.str(code) },
        .{ "reason", H.str(diagnostics.reason(code)) }, .{ "phase", H.str(phase) },
    });
    if (H.eq(phase, "arguments")) try H.set(a, &result, "hint", H.str("Run c2c --help for usage."));
    return result;
}
fn diagnosticDetails(a: A, result: V) ![]const u8 {
    var text = std.array_list.Managed(u8).init(a);
    const reason = H.s(result, "reason");
    if (reason.len > 0) try text.appendSlice(try H.fmt(a, "  {s}\n", .{reason}));
    if (sourcePath(result).len > 0) try text.appendSlice(try H.fmt(a, "  Source: {s}\n", .{sourcePath(result)}));
    for ([_]struct { key: []const u8, label: []const u8 }{
        .{ .key = "targetPath", .label = "Destination" },
        .{ .key = "sourceHome", .label = "Source home" },
        .{ .key = "targetHome", .label = "Destination home" },
        .{ .key = "manifest", .label = "Manifest" },
    }) |field| {
        const value = H.s(result, field.key);
        if (value.len > 0) try text.appendSlice(try H.fmt(a, "  {s}: {s}\n", .{ field.label, value }));
    }
    const hint = H.s(result, "hint");
    if (hint.len > 0) try text.appendSlice(try H.fmt(a, "  {s}\n", .{hint}));
    return text.toOwnedSlice();
}
fn renderFailure(a: A, result: V) ![]const u8 {
    return H.fmt(a, "c2c: {s}\n{s}", .{ H.s(result, "errorType"), try diagnosticDetails(a, result) });
}
fn renderRow(a: A, row: V) ![]const u8 {
    const status = H.s(row, "status");
    if (!oneOf(status, &.{ "error", "invalid", "missing", "collision", "pending-registration", "registering" })) return H.fmt(a, "{s}  {s}  {s}\n", .{ H.s(row, "sourceThreadId"), status, if (H.s(row, "sessionId").len > 0) H.s(row, "sessionId") else H.s(row, "title") });
    var details = try H.clone(a, row);
    const code = if (H.s(row, "errorType").len > 0) H.s(row, "errorType") else H.s(row, "registrationError");
    if (H.s(details, "reason").len == 0) {
        const reason = if (code.len > 0) diagnostics.reason(code) else if (H.eq(status, "collision"))
            "The destination already exists. It was preserved; c2c will not overwrite it."
        else if (H.eq(status, "missing"))
            "The installed destination is missing. Check its path and the destination app."
        else if (H.eq(status, "invalid"))
            "The destination failed validation. Inspect it before retrying."
        else if (oneOf(status, &.{ "pending-registration", "registering" }))
            "Native registration is unfinished. Check the destination CLI, then retry the same migration."
        else
            diagnostics.reason("");
        try H.set(a, &details, "reason", H.str(reason));
    }
    const suffix = if (code.len > 0) try H.fmt(a, " ({s})", .{code}) else "";
    return H.fmt(a, "{s}  {s}{s}\n{s}", .{ H.s(row, "sourceThreadId"), status, suffix, try diagnosticDetails(a, details) });
}
fn printResult(a: A, options: Options, result: V) !void {
    if (options.json_output) {
        try writeAll(1, try H.json(a, result));
        try writeAll(1, "\n");
        return;
    }
    if (H.get(result, "error") != .null) {
        try writeAll(2, try renderFailure(a, result));
        return;
    }
    for (H.list(H.get(result, "threads"))) |row| try writeAll(1, try renderRow(a, row));
    const counts = H.get(result, "counts");
    if (counts == .object) {
        var iterator = counts.object.iterator();
        while (iterator.next()) |entry| try writeAll(1, try H.fmt(a, "{d} {s}\n", .{ H.integer(entry.value_ptr.*), entry.key_ptr.* }));
        if (counts.object.count() == 0) try writeAll(1, "No matching threads\n");
    }
    const warnings = H.get(result, "warningGroups");
    if (warnings == .object) {
        var iterator = warnings.object.iterator();
        while (iterator.next()) |entry| try writeAll(1, try H.fmt(a, "Warning ({d}): {s}\n", .{ H.integer(entry.value_ptr.*), entry.key_ptr.* }));
    }
    if (H.s(result, "manifest").len > 0) try writeAll(1, try H.fmt(a, "Manifest: {s}\n", .{H.s(result, "manifest")}));
}
pub fn run(a: A, args: []const []const u8) !u8 {
    const options = parseOptions(a, args) catch |err| {
        try printResult(a, .{ .json_output = oneOf("--json", args) }, try terminalFailure(a, @errorName(err), "arguments"));
        return 1;
    };
    if (options.help) {
        try writeAll(1, "c2c — native coding-agent conversation migration\n\n" ++
            "  c2c codex-to-claude [migrate|inventory|verify|list|undo] [options]\n" ++
            "  c2c claude-to-codex [migrate|inventory|verify|list|undo] [options]\n" ++
            "  c2c [action] --from PROVIDER --to PROVIDER [options]\n\n" ++
            "Providers: codex, claude, omp, opencode\n" ++
            "Options: --codex-home --claude-home --omp-home --opencode-home\n" ++
            "         --output-dir --project --project-prefix --thread\n" ++
            "         --origin-manifest --include-subagents --no-images --json\n" ++
            "Existing chats are never overwritten. Unchanged round trips are skipped.\n");
        return 0;
    }
    const result = execute(a, options) catch |err| blk: {
        var failed = try terminalFailure(a, @errorName(err), options.action);
        try H.set(a, &failed, "sourceHome", H.str(options.home(options.from)));
        try H.set(a, &failed, "targetHome", H.str(options.home(options.to)));
        if (!H.eq(options.action, "inventory")) try H.set(a, &failed, "manifest", H.str(try H.join(a, &.{ options.output_dir, "manifest.json" })));
        break :blk failed;
    };
    try printResult(a, options, result);
    if (H.get(result, "error") != .null) return 1;
    for ([_][]const u8{ "error", "invalid", "collision", "missing", "pending-registration" }) |status| if (H.integer(H.get(H.get(result, "counts"), status)) > 0) return 1;
    return 0;
}

test "direction aliases and provider flags retain explicit output directories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const options = try parseOptions(a, &.{ "claude-to-codex", "inventory", "--output-dir", "/tmp/c2c-cli-options", "--json" });
    try std.testing.expectEqual(Provider.claude, options.from);
    try std.testing.expectEqual(Provider.codex, options.to);
    try std.testing.expectEqualStrings("inventory", options.action);
    try std.testing.expectEqualStrings("/tmp/c2c-cli-options", options.output_dir);
    const generic = try parseOptions(a, &.{ "--from=omp", "--to=opencode" });
    try std.testing.expectEqual(Provider.omp, generic.from);
    try std.testing.expectEqual(Provider.opencode, generic.to);
}
test "parser errors retain machine codes and point humans to help" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.UnknownOption, parseOptions(a, &.{"--typo"}));
    try std.testing.expectError(error.MissingOptionValue, parseOptions(a, &.{ "--from", "--json" }));
    try std.testing.expectError(error.MissingOptionValue, parseOptions(a, &.{"--thread="}));
    try std.testing.expectError(error.UnknownProvider, parseOptions(a, &.{ "--from=unknown", "--json" }));
    const result = try terminalFailure(a, "UnknownProvider", "arguments");
    const encoded = try H.parse(a, try H.json(a, result));
    try std.testing.expectEqualStrings("UnknownProvider", H.s(encoded, "error"));
    try std.testing.expectEqualStrings("UnknownProvider", H.s(encoded, "errorType"));
    try std.testing.expectEqualStrings("arguments", H.s(encoded, "phase"));
    try std.testing.expect(std.mem.indexOf(u8, H.s(encoded, "reason"), "codex, claude, omp, or opencode") != null);
    const rendered = try renderFailure(a, encoded);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "UnknownProvider") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "c2c --help") != null);
}
test "journal verification reports registration failure and legacy source path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const record = try H.obj(a, &.{
        .{ "sourceThreadId", H.str("source-id") },                     .{ "status", H.str("pending-registration") },
        .{ "sessionId", H.str("native-id") },                          .{ "targetPath", H.str("/destination/session.jsonl") },
        .{ "registrationError", H.str("CodexNativeMigrationFailed") }, .{ "sourceStamp", try H.obj(a, &.{.{ "path", H.str("/source/conversation.jsonl") }}) },
    });
    const row = try inspect(a, .{}, record);
    try std.testing.expectEqualStrings("CodexNativeMigrationFailed", H.s(row, "errorType"));
    try std.testing.expectEqualStrings("registration", H.s(row, "phase"));
    try std.testing.expectEqualStrings("/source/conversation.jsonl", H.s(row, "sourcePath"));
    const rendered = try renderRow(a, row);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "pending-registration (CodexNativeMigrationFailed)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Check that the Codex CLI runs") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Source: /source/conversation.jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Destination: /destination/session.jsonl") != null);
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
test "documented Codex home environment is respected and explicit flags win" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const previous = if (H.c.getenv("CODEX_HOME")) |value| try a.dupeZ(u8, std.mem.span(value)) else null;
    defer {
        if (previous) |value| {
            _ = H.c.setenv("CODEX_HOME", value, 1);
        } else {
            _ = H.c.unsetenv("CODEX_HOME");
        }
    }
    try std.testing.expectEqual(@as(c_int, 0), H.c.setenv("CODEX_HOME", "/tmp/c2c-environment-home", 1));
    try std.testing.expectEqualStrings("/tmp/c2c-environment-home", (try parseOptions(a, &.{"inventory"})).codex_home);
    try std.testing.expectEqualStrings("/tmp/c2c-explicit-home", (try parseOptions(a, &.{ "inventory", "--codex-home", "/tmp/c2c-explicit-home" })).codex_home);
    try std.testing.expectEqual(@as(c_int, 0), H.c.setenv("CODEX_HOME", "", 1));
    const fallback = try parseOptions(a, &.{"inventory"});
    try std.testing.expectEqualStrings(try H.join(a, &.{ fallback.user_home, ".codex" }), fallback.codex_home);
}
test "portable origin skip applies only when returning to its origin provider" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const thread = H.Thread{ .id = "copy", .title = "Fixture", .cwd = "/tmp", .created_at = "", .updated_at = "", .rollout_path = "/nonexistent", .provider = "claude", .origin_provider = "codex", .origin_id = "original", .unchanged_import = true };
    try std.testing.expectEqualStrings("original", (try alreadyOrigin(a, .{ .from = .claude, .to = .codex }, thread, &.{})).?);
    try std.testing.expect((try alreadyOrigin(a, .{ .from = .claude, .to = .omp }, thread, &.{})) == null);
}

const Fixture = struct {
    a: A,
    root: []const u8,
    options: Options,
    source_path: []const u8,
    fn init(a: A) !Fixture {
        const template = try a.dupeZ(u8, "/tmp/c2c-zig-cli-XXXXXX");
        if (H.c.mkdtemp(template) == null) return error.TempDirectoryFailed;
        const root = try a.dupe(u8, template);
        const codex_home = try H.join(a, &.{ root, "codex" });
        const claude_home = try H.join(a, &.{ root, "claude" });
        const output = try H.join(a, &.{ root, "journal" });
        var options = try parseOptions(a, &.{ "codex-to-claude", "--codex-home", codex_home, "--claude-home", claude_home, "--output-dir", output });
        options.user_home = root;
        const path = try H.join(a, &.{ codex_home, "sessions", "rollout-fixture-00000000-0000-4000-8000-000000000001.jsonl" });
        try H.mkdirAll(std.fs.path.dirname(path).?);
        const fixture = Fixture{ .a = a, .root = root, .options = options, .source_path = path };
        try fixture.sourceFile(path, "00000000-0000-4000-8000-000000000001", false);
        return fixture;
    }
    fn sourceFile(self: Fixture, path: []const u8, id: []const u8, empty: bool) !void {
        const meta = try H.obj(self.a, &.{ .{ "timestamp", H.str("2026-10-01T00:00:00Z") }, .{ "type", H.str("session_meta") }, .{ "payload", try H.obj(self.a, &.{ .{ "id", H.str(id) }, .{ "cwd", H.str(self.root) }, .{ "timestamp", H.str("2026-10-01T00:00:00Z") }, .{ "history_mode", H.str("legacy") } }) } });
        const head = try H.fmt(self.a, "{s}\n", .{try H.json(self.a, meta)});
        const body = if (empty) "" else "{\"timestamp\":\"2026-10-01T00:00:01Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Synthetic migration fixture\"}]}}\n" ++
            "{\"timestamp\":\"2026-10-01T00:00:02Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"The fixture response remains in history.\"}]}}\n";
        try H.writeExclusive(path, try H.fmt(self.a, "{s}{s}", .{ head, body }));
    }
    fn action(self: Fixture, value: []const u8) !V {
        var options = self.options;
        options.action = value;
        return execute(self.a, options);
    }
    fn cleanup(self: Fixture) void {
        removeTree(self.a, self.root) catch {};
    }
};
fn removeTree(a: A, root: []const u8) !void {
    for (try H.listDir(a, root)) |entry| {
        const path = try H.join(a, &.{ root, entry.name });
        if (entry.is_dir and !entry.is_symlink) try removeTree(a, path) else try H.removeFile(path);
    }
    const z = try a.dupeZ(u8, root);
    if (H.c.rmdir(z) != 0) return error.RemoveDirectoryFailed;
}
fn count(result: V, status: []const u8) i64 {
    return H.integer(H.get(H.get(result, "counts"), status));
}

test "native forward lifecycle installs verifies skips and safely undoes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try Fixture.init(a);
    defer fixture.cleanup();
    const source_hash = try H.sha256File(a, fixture.source_path);
    const installed = try fixture.action("migrate");
    try std.testing.expectEqual(@as(i64, 1), count(installed, "installed"));
    const target = H.s(H.list(H.get(installed, "threads"))[0], "targetPath");
    const original = try H.readFile(a, target);
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("verify"), "verified"));
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("migrate"), "unchanged"));
    const undone = try fixture.action("undo");
    try std.testing.expectEqual(@as(i64, 1), count(undone, "undone"));
    try std.testing.expect(!H.exists(target));
    try std.testing.expectEqualStrings(original, try H.readFile(a, H.s(H.list(H.get(undone, "threads"))[0], "retainedPath")));
    try std.testing.expectEqualStrings(source_hash, try H.sha256File(a, fixture.source_path));
}
test "native continued conversations survive reimport and undo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try Fixture.init(a);
    defer fixture.cleanup();
    const result = try fixture.action("migrate");
    const row = H.list(H.get(result, "threads"))[0];
    const target = H.s(row, "targetPath");
    const title = try H.json(a, try H.obj(a, &.{ .{ "type", H.str("custom-title") }, .{ "sessionId", H.get(row, "sessionId") }, .{ "customTitle", H.str("Renamed inside Claude") } }));
    const changed = try H.fmt(a, "{s}{s}\n", .{ try H.readFile(a, target), title });
    try H.atomicWrite(a, target, changed);
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("verify"), "continued"));
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("migrate"), "continued"));
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("undo"), "preserved"));
    try std.testing.expectEqualStrings(changed, try H.readFile(a, target));
}
test "native collision preserves an existing destination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try Fixture.init(a);
    defer fixture.cleanup();
    const thread = (try source.listThreads(a, fixture.options.codex_home))[0];
    const target = try destination(a, fixture.options, thread, try sessionId(a, fixture.options, thread));
    try H.mkdirAll(std.fs.path.dirname(target).?);
    try H.writeExclusive(target, "existing native chat\n");
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("migrate"), "collision"));
    _ = try fixture.action("undo");
    try std.testing.expectEqualStrings("existing native chat\n", try H.readFile(a, target));
}
test "native partial source failure still imports the other valid thread" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try Fixture.init(a);
    defer fixture.cleanup();
    const path = try H.join(a, &.{ std.fs.path.dirname(fixture.source_path).?, "rollout-invalid.jsonl" });
    try fixture.sourceFile(path, "00000000-0000-4000-8000-000000000002", true);
    try H.atomicWrite(a, path, try H.fmt(a, "{s}malformed source line\n", .{try H.readFile(a, path)}));
    const result = try fixture.action("migrate");
    try std.testing.expectEqual(@as(i64, 1), count(result, "installed"));
    try std.testing.expectEqual(@as(i64, 1), count(result, "error"));
    const encoded = try H.parse(a, try H.json(a, result));
    for (H.list(H.get(encoded, "threads"))) |row| {
        if (!H.eq(H.s(row, "status"), "error")) continue;
        try std.testing.expectEqualStrings("MalformedSourceJson", H.s(row, "errorType"));
        try std.testing.expectEqualStrings("conversion", H.s(row, "phase"));
        try std.testing.expectEqualStrings(path, H.s(row, "sourcePath"));
        try std.testing.expect(std.mem.indexOf(u8, H.s(row, "reason"), "malformed") != null);
        const rendered = try renderRow(a, row);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "error (MalformedSourceJson)") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, path) != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "Inspect the file shown") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "malformed source line") == null);
    }
    const verified = try fixture.action("verify");
    for (H.list(H.get(verified, "threads"))) |row| {
        if (!H.eq(H.s(row, "status"), "error")) continue;
        try std.testing.expectEqualStrings("MalformedSourceJson", H.s(row, "errorType"));
        try std.testing.expectEqualStrings(path, H.s(row, "sourcePath"));
        try std.testing.expect(H.s(row, "reason").len > 0);
    }
}
test "native journal recovers publication from retained ownership hardlink" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try Fixture.init(a);
    defer fixture.cleanup();
    try H.mkdirAll(fixture.options.output_dir);
    var state = try loadState(a, fixture.options);
    const thread = (try source.listThreads(a, fixture.options.codex_home))[0];
    var record = try stageThread(&state, thread, try H.join(a, &.{ fixture.options.output_dir, "staged", "fixture" }));
    const target = H.s(record, "targetPath");
    try H.mkdirAll(std.fs.path.dirname(target).?);
    const temporary = try H.fmt(a, "{s}.publication-fixture", .{target});
    try H.copyExclusive(a, H.s(record, "stagePath"), temporary);
    try H.hardLink(temporary, target);
    try H.set(a, &record, "status", H.str("installing"));
    try H.set(a, &record, "installTemporary", H.str(temporary));
    try state.put(thread.id, record);
    try state.save();
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("migrate"), "unchanged"));
    try std.testing.expect(!H.exists(temporary));
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("undo"), "undone"));
}
test "native engine accepts existing Python v1 migration journals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try Fixture.init(a);
    defer fixture.cleanup();
    _ = try fixture.action("migrate");
    var state = try loadState(a, fixture.options);
    for ([_][]const u8{ "direction", "sourceHome", "targetHome", "from", "to" }) |key| _ = state.manifest.object.swapRemove(key);
    try state.save();
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("verify"), "verified"));
}
test "missing staged artifact is rebuilt without claiming a native destination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try Fixture.init(a);
    defer fixture.cleanup();
    try H.mkdirAll(fixture.options.output_dir);
    var state = try loadState(a, fixture.options);
    const thread = (try source.listThreads(a, fixture.options.codex_home))[0];
    const record = try stageThread(&state, thread, try H.join(a, &.{ fixture.options.output_dir, "staged", "missing" }));
    try state.put(thread.id, record);
    try state.save();
    try H.removeFile(H.s(record, "stagePath"));
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("migrate"), "installed"));
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("verify"), "verified"));
}
