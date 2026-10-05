const std = @import("std");
const H = @import("../common.zig");
const A = H.Allocator;
const V = H.Value;
const Options = @import("../cli/options.zig").Options;
const writeAll = @import("../os.zig").writeAll;

pub fn now(a: A) !V {
    return H.str(try H.timestamp(a, H.nowMillis()));
}

pub fn pathWithin(path: []const u8, root: []const u8) bool {
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

pub fn safeTarget(a: A, options: Options, path: []const u8) ![]const u8 {
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

pub fn syncAncestors(path: []const u8) !void {
    var current = path;
    while (true) {
        try H.syncDir(current);
        const parent = std.fs.path.dirname(current) orelse break;
        if (H.eq(parent, current)) break;
        current = parent;
    }
}

var nonce: u64 = 0;

pub fn unique(a: A) ![]const u8 {
    nonce += 1;
    return H.fmt(a, "{d}-{d}-{d}", .{ H.nowMillis(), H.c.getpid(), nonce });
}

pub fn writeJsonl(a: A, path: []const u8, entries: []const V) !void {
    const z = try a.dupeZ(u8, path);
    const fd = H.c.open(z, H.c.O_WRONLY | H.c.O_CREAT | H.c.O_EXCL | H.c.O_NOFOLLOW | H.c.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return error.StageCreateFailed;
    defer _ = H.c.close(fd);
    for (entries) |entry| {
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        writeAll(fd, try H.json(scratch.allocator(), entry)) catch return error.WriteFailed;
        writeAll(fd, "\n") catch return error.WriteFailed;
    }
    if (H.c.fsync(fd) != 0) return error.SyncFailed;
}

pub const State = struct {
    a: A,
    options: Options,
    manifest: V,
    path: []const u8,
    pub fn imports(self: *State) *V {
        return self.manifest.object.getPtr("imports").?;
    }
    pub fn record(self: *State, id: []const u8) V {
        return H.get(self.imports().*, id);
    }
    pub fn put(self: *State, id: []const u8, value: V) !void {
        try H.set(self.a, self.imports(), id, value);
    }
    pub fn save(self: *State) !void {
        try H.set(self.a, &self.manifest, "updatedAt", try now(self.a));
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        try H.atomicWrite(a, self.path, try H.json(a, self.manifest));
    }
    pub fn rememberUndo(self: *State, value: V) !void {
        const backup = H.s(value, "undoBackupPath");
        if (backup.len == 0) return;
        var retained = H.get(self.manifest, "retainedUndos");
        if (retained == .null) retained = try H.arr(self.a, &.{});
        for (H.list(retained)) |entry| if (H.eq(H.s(entry, "undoBackupPath"), backup)) return;
        try retained.array.append(try H.clone(self.a, value));
        try H.set(self.a, &self.manifest, "retainedUndos", retained);
    }
};

pub fn loadState(a: A, options: Options) !State {
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
