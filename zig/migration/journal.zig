const std = @import("std");
const common = @import("../common.zig");
const Allocator = common.Allocator;
const Value = common.Value;
const Options = @import("../cli/options.zig").Options;
const writeAll = @import("../os.zig").writeAll;

pub fn now(allocator: Allocator) !Value {
    return common.str(try common.timestamp(allocator, common.nowMillis()));
}

pub fn pathWithin(path: []const u8, root: []const u8) bool {
    if (common.eq(path, root)) {
        return true;
    }
    if (!std.mem.startsWith(u8, path, root)) {
        return false;
    }
    if (std.mem.endsWith(u8, root, "/")) {
        return true;
    }
    return path.len > root.len and path[root.len] == '/';
}

fn targetRoot(allocator: Allocator, options: Options) ![]const u8 {
    return switch (options.to) {
        .claude => common.join(allocator, &.{ options.claude_home, "projects" }),
        .codex => common.join(allocator, &.{ options.codex_home, "sessions" }),
        .omp => common.join(allocator, &.{ options.omp_home, "sessions" }),
        .opencode => common.join(allocator, &.{ options.opencode_home, "c2c-imports" }),
    };
}

pub fn safeTarget(allocator: Allocator, options: Options, path: []const u8) ![]const u8 {
    if (!std.fs.path.isAbsolute(path)) {
        return error.UnsafeTargetPath;
    }
    if (common.stat(path)) |info| {
        if (info.is_symlink) {
            return error.UnsafeTargetPath;
        }
    } else |err| {
        if (err != error.FileNotFound) {
            return err;
        }
    }
    const parent = std.fs.path.dirname(path) orelse return error.UnsafeTargetPath;
    const root = try common.canonicalPath(allocator, try targetRoot(allocator, options));
    if (!pathWithin(try common.canonicalPath(allocator, parent), root)) {
        return error.UnsafeTargetPath;
    }
    return path;
}

pub fn syncAncestors(path: []const u8) !void {
    var current = path;
    while (true) {
        try common.syncDir(current);
        const parent = std.fs.path.dirname(current) orelse break;
        if (common.eq(parent, current)) {
            break;
        }
        current = parent;
    }
}

var nonce: u64 = 0;

pub fn unique(allocator: Allocator) ![]const u8 {
    nonce += 1;
    return common.fmt(allocator, "{d}-{d}-{d}", .{ common.nowMillis(), common.c.getpid(), nonce });
}

pub fn writeJsonl(allocator: Allocator, path: []const u8, entries: []const Value) !void {
    const z = try allocator.dupeZ(u8, path);
    const flags = common.c.O_WRONLY | common.c.O_CREAT | common.c.O_EXCL | common.c.O_NOFOLLOW | common.c.O_CLOEXEC;
    const fd = common.c.open(z, flags, @as(c_uint, 0o600));
    if (fd < 0) {
        return error.StageCreateFailed;
    }
    defer _ = common.c.close(fd);
    for (entries) |entry| {
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        writeAll(fd, try common.json(scratch.allocator(), entry)) catch return error.WriteFailed;
        writeAll(fd, "\n") catch return error.WriteFailed;
    }
    if (common.c.fsync(fd) != 0) {
        return error.SyncFailed;
    }
}

pub const State = struct {
    allocator: Allocator,
    options: Options,
    manifest: Value,
    path: []const u8,
    pub fn imports(self: *State) *Value {
        return self.manifest.object.getPtr("imports").?;
    }
    pub fn record(self: *State, id: []const u8) Value {
        return common.get(self.imports().*, id);
    }
    pub fn put(self: *State, id: []const u8, value: Value) !void {
        try common.set(self.allocator, self.imports(), id, value);
    }
    pub fn save(self: *State) !void {
        try common.set(self.allocator, &self.manifest, "updatedAt", try now(self.allocator));
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const allocator = scratch.allocator();
        try common.atomicWrite(allocator, self.path, try common.json(allocator, self.manifest));
    }
    pub fn rememberUndo(self: *State, value: Value) !void {
        const backup = common.stringField(value, "undoBackupPath");
        if (backup.len == 0) {
            return;
        }
        var retained = common.get(self.manifest, "retainedUndos");
        if (retained == .null) {
            retained = try common.arr(self.allocator, &.{});
        }
        for (common.list(retained)) |entry| {
            if (common.eq(common.stringField(entry, "undoBackupPath"), backup)) {
                return;
            }
        }
        try retained.array.append(try common.clone(self.allocator, value));
        try common.set(self.allocator, &self.manifest, "retainedUndos", retained);
    }
};

pub fn loadState(allocator: Allocator, options: Options) !State {
    const path = try common.join(allocator, &.{ options.output_dir, "manifest.json" });
    var manifest: Value = undefined;
    if (common.exists(path)) {
        manifest = try common.parse(allocator, try common.readFile(allocator, path));
        if (common.integer(common.get(manifest, "version")) != 1 or common.get(manifest, "imports") != .object) {
            return error.UnsupportedManifest;
        }
        if (common.stringField(manifest, "sourceHome").len > 0) {
            if (!common.eq(common.stringField(manifest, "sourceHome"), options.home(options.from)) or
                !common.eq(common.stringField(manifest, "targetHome"), options.home(options.to)))
            {
                return error.ManifestHomesMismatch;
            }
        } else if (!common.eq(common.stringField(manifest, "codexHome"), options.codex_home) or
            !common.eq(common.stringField(manifest, "claudeHome"), options.claude_home))
        {
            return error.ManifestHomesMismatch;
        }
        const saved_direction = common.stringField(manifest, "direction");
        const direction = if (saved_direction.len == 0) "codex-to-claude" else saved_direction;
        if (!common.eq(direction, try options.direction(allocator))) {
            return error.ManifestDirectionMismatch;
        }
    } else {
        manifest = try common.obj(allocator, &.{
            .{ "version", common.num(1) },
            .{ "createdAt", try now(allocator) },
            .{ "codexHome", common.str(options.codex_home) },
            .{ "claudeHome", common.str(options.claude_home) },
            .{ "direction", common.str(try options.direction(allocator)) },
            .{ "from", common.str(@tagName(options.from)) },
            .{ "to", common.str(@tagName(options.to)) },
            .{ "sourceHome", common.str(options.home(options.from)) },
            .{ "targetHome", common.str(options.home(options.to)) },
            .{ "ompHome", common.str(options.omp_home) },
            .{ "opencodeHome", common.str(options.opencode_home) },
            .{ "imports", try common.obj(allocator, &.{}) },
        });
    }
    return .{
        .allocator = allocator,
        .options = options,
        .manifest = manifest,
        .path = path,
    };
}
