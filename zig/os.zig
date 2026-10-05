const std = @import("std");
const common = @import("common.zig");
const c = common.c;
const Allocator = std.mem.Allocator;
pub const DirEntry = common.DirEntry;

fn errnoError() anyerror {
    return switch (std.c.errno(@as(c_int, -1))) {
        .NOENT => error.FileNotFound,
        .EXIST => error.PathAlreadyExists,
        .ACCES, .PERM => error.AccessDenied,
        .NOTDIR => error.NotDir,
        .ISDIR => error.IsDir,
        .LOOP => error.SymLinkLoop,
        .NOSPC => error.NoSpaceLeft,
        .NAMETOOLONG => error.NameTooLong,
        .PIPE => error.BrokenPipe,
        else => error.SystemResources,
    };
}
fn interrupted() bool {
    return std.c.errno(@as(c_int, -1)) == .INTR;
}
fn wouldBlock() bool {
    return std.c.errno(@as(c_int, -1)) == .AGAIN;
}
fn zpath(a: Allocator, path: []const u8) ![:0]u8 {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    return a.dupeZ(u8, path);
}
fn closeFd(fd: c_int) void {
    if (fd >= 0) {
        _ = c.close(fd);
    }
}
fn fsyncFd(fd: c_int) !void {
    while (c.fsync(fd) != 0) {
        if (!interrupted()) return errnoError();
    }
}
fn writeAll(fd: c_int, data: []const u8) !void {
    var pos: usize = 0;
    while (pos < data.len) {
        const n = c.write(fd, data[pos..].ptr, data.len - pos);
        if (n < 0) {
            if (interrupted()) continue;
            return errnoError();
        }
        if (n == 0) return error.WriteZero;
        pos += @intCast(n);
    }
}
fn fileStat(fd: c_int) !c.struct_stat {
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0) return errnoError();
    return st;
}
fn isRegular(st: c.struct_stat) bool {
    return st.st_mode & c.S_IFMT == c.S_IFREG;
}
fn info(st: c.struct_stat) common.FileInfo {
    return .{ .size = @intCast(@max(0, st.st_size)), .mtime_ns = @as(i128, st.st_mtim.tv_sec) * std.time.ns_per_s + st.st_mtim.tv_nsec, .is_dir = st.st_mode & c.S_IFMT == c.S_IFDIR, .is_symlink = st.st_mode & c.S_IFMT == c.S_IFLNK };
}
pub fn stat(path: []const u8) !common.FileInfo {
    const p = try zpath(std.heap.page_allocator, path);
    defer std.heap.page_allocator.free(p);
    var st: c.struct_stat = undefined;
    if (c.lstat(p.ptr, &st) != 0) return errnoError();
    return info(st);
}
pub const lstat = stat;
pub fn exists(path: []const u8) bool {
    _ = stat(path) catch return false;
    return true;
}
pub fn sameFile(first: []const u8, second: []const u8) bool {
    const a = std.heap.page_allocator;
    const p = zpath(a, first) catch return false;
    defer a.free(p);
    const q = zpath(a, second) catch return false;
    defer a.free(q);
    var x: c.struct_stat = undefined;
    var y: c.struct_stat = undefined;
    return c.stat(p.ptr, &x) == 0 and c.stat(q.ptr, &y) == 0 and x.st_dev == y.st_dev and x.st_ino == y.st_ino;
}

pub fn readFile(a: Allocator, path: []const u8) ![]const u8 {
    var reader = try LineReader.open(a, path);
    defer reader.close();
    if (reader.size > std.math.maxInt(usize)) return error.FileTooBig;
    const result = try a.alloc(u8, @intCast(reader.size));
    errdefer a.free(result);
    var pos: usize = 0;
    while (pos < result.len) {
        const n = c.read(reader.fd, result[pos..].ptr, result.len - pos);
        if (n < 0) {
            if (interrupted()) continue;
            return errnoError();
        }
        if (n == 0) return a.realloc(result, pos);
        pos += @intCast(n);
    }
    return result;
}
pub fn writeExclusive(path: []const u8, data: []const u8) !void {
    const a = std.heap.page_allocator;
    const p = try zpath(a, path);
    defer a.free(p);
    const fd = c.open(p.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
    if (fd < 0) return errnoError();
    defer closeFd(fd);
    errdefer {
        _ = c.unlink(p.ptr);
    }
    try writeAll(fd, data);
    try fsyncFd(fd);
}
pub fn atomicWrite(a: Allocator, path: []const u8, data: []const u8) !void {
    const target = try zpath(a, path);
    defer a.free(target);
    const temp = try std.fmt.allocPrintSentinel(a, "{s}.tmp.XXXXXX", .{path}, 0);
    defer a.free(temp);
    const fd = c.mkstemp(temp.ptr);
    if (fd < 0) return errnoError();
    defer closeFd(fd);
    defer {
        _ = c.unlink(temp.ptr);
    }
    if (c.fcntl(fd, c.F_SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) return errnoError();
    try writeAll(fd, data);
    try fsyncFd(fd);
    if (c.rename(temp.ptr, target.ptr) != 0) return errnoError();
    try syncDir(std.fs.path.dirname(path) orelse ".");
}
pub fn mkdirAll(path: []const u8) !void {
    const a = std.heap.page_allocator;
    const p = try zpath(a, path);
    defer a.free(p);
    if (p.len == 0) return error.InvalidPath;
    for (0..p.len + 1) |i| {
        if (i == 0 or (i < p.len and p[i] != '/')) continue;
        const saved = p[i];
        p[i] = 0;
        const rc = c.mkdir(p.ptr, @as(c_uint, 0o700));
        const err = if (rc != 0) std.c.errno(@as(c_int, -1)) else .SUCCESS;
        if (rc != 0 and err != .EXIST) {
            p[i] = saved;
            return errnoError();
        }
        var st: c.struct_stat = undefined;
        const sr = c.lstat(p.ptr, &st);
        p[i] = saved;
        if (sr != 0) return errnoError();
        if (st.st_mode & c.S_IFMT != c.S_IFDIR) return error.NotDir;
    }
}
pub fn hardLink(source: []const u8, target: []const u8) !void {
    const a = std.heap.page_allocator;
    const p = try zpath(a, source);
    defer a.free(p);
    const q = try zpath(a, target);
    defer a.free(q);
    if (c.link(p.ptr, q.ptr) != 0) return errnoError();
}
pub fn removeFile(path: []const u8) !void {
    const a = std.heap.page_allocator;
    const p = try zpath(a, path);
    defer a.free(p);
    if (c.unlink(p.ptr) != 0) return errnoError();
}
pub fn renameFile(old: []const u8, new: []const u8) !void {
    const a = std.heap.page_allocator;
    const p = try zpath(a, old);
    defer a.free(p);
    const q = try zpath(a, new);
    defer a.free(q);
    if (c.rename(p.ptr, q.ptr) != 0) return errnoError();
}
pub fn syncDir(path: []const u8) !void {
    const a = std.heap.page_allocator;
    const p = try zpath(a, path);
    defer a.free(p);
    const fd = c.open(p.ptr, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    if (fd < 0) return errnoError();
    defer closeFd(fd);
    try fsyncFd(fd);
}
pub fn copyExclusive(a: Allocator, source: []const u8, dest: []const u8) !void {
    var reader = try LineReader.open(a, source);
    defer reader.close();
    const p = try zpath(a, dest);
    defer a.free(p);
    const fd = c.open(p.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_NOFOLLOW | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return errnoError();
    defer closeFd(fd);
    errdefer {
        _ = c.unlink(p.ptr);
    }
    var buffer: [64 * 1024]u8 = undefined;
    var left = reader.size;
    while (left != 0) {
        const n = c.read(reader.fd, &buffer, @min(left, buffer.len));
        if (n < 0) {
            if (interrupted()) continue;
            return errnoError();
        }
        if (n == 0) return error.UnexpectedEndOfFile;
        try writeAll(fd, buffer[0..@intCast(n)]);
        left -= @intCast(n);
    }
    try fsyncFd(fd);
}

pub fn listDir(a: Allocator, path: []const u8) ![]DirEntry {
    const p = try zpath(a, path);
    defer a.free(p);
    const fd = c.open(p.ptr, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) return errnoError();
    const dir = c.fdopendir(fd) orelse {
        closeFd(fd);
        return errnoError();
    };
    defer {
        _ = c.closedir(dir);
    }
    var entries = std.array_list.Managed(DirEntry).init(a);
    errdefer {
        for (entries.items) |e| a.free(e.name);
        entries.deinit();
    }
    while (true) {
        // readdir returns null both for EOF and errors; clear errno first.
        std.c._errno().* = 0;
        const entry = c.readdir(dir) orelse {
            if (std.c.errno(@as(c_int, -1)) != .SUCCESS) return errnoError();
            break;
        };
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.*.d_name)), 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        var st: c.struct_stat = undefined;
        if (c.fstatat(fd, @ptrCast(&entry.*.d_name), &st, c.AT_SYMLINK_NOFOLLOW) != 0) {
            if (std.c.errno(@as(c_int, -1)) == .NOENT) continue;
            return errnoError();
        }
        const s = info(st);
        try entries.append(.{ .name = try a.dupe(u8, name), .is_dir = s.is_dir, .is_symlink = s.is_symlink });
    }
    std.mem.sort(DirEntry, entries.items, {}, struct {
        fn less(_: void, x: DirEntry, y: DirEntry) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.less);
    return entries.toOwnedSlice();
}
pub fn walkFiles(a: Allocator, root: []const u8, suffix: []const u8) ![][]const u8 {
    var files = std.array_list.Managed([]const u8).init(a);
    errdefer {
        for (files.items) |p| a.free(p);
        files.deinit();
    }
    try walkInto(a, root, suffix, &files);
    return files.toOwnedSlice();
}
fn walkInto(a: Allocator, root: []const u8, suffix: []const u8, files: *std.array_list.Managed([]const u8)) !void {
    const entries = listDir(a, root) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer {
        for (entries) |e| a.free(e.name);
        a.free(entries);
    }
    for (entries) |entry| {
        if (entry.is_symlink) continue;
        const path = try std.fs.path.join(a, &.{ root, entry.name });
        defer a.free(path);
        if (entry.is_dir) {
            try walkInto(a, path, suffix, files);
            continue;
        }
        if (!std.mem.endsWith(u8, entry.name, suffix)) continue;
        const p = try zpath(a, path);
        defer a.free(p);
        var st: c.struct_stat = undefined;
        if (c.lstat(p.ptr, &st) != 0) {
            if (std.c.errno(@as(c_int, -1)) == .NOENT) continue;
            return errnoError();
        }
        if (isRegular(st)) try files.append(try a.dupe(u8, path));
    }
}

/// Streaming, fixed-size snapshot. Returned line storage is valid until next/seek/close.
pub const LineReader = struct {
    fd: c_int,
    offset: u64 = 0,
    size: u64,
    last_terminated: bool = false,
    buffer: [64 * 1024]u8 = undefined,
    begin: usize = 0,
    end: usize = 0,
    line: std.array_list.Managed(u8),
    pub fn open(a: Allocator, path: []const u8) !LineReader {
        const p = try zpath(a, path);
        defer a.free(p);
        const fd = c.open(p.ptr, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
        if (fd < 0) return errnoError();
        errdefer closeFd(fd);
        const st = try fileStat(fd);
        if (!isRegular(st)) return error.NotRegularFile;
        return .{ .fd = fd, .size = @intCast(@max(0, st.st_size)), .line = std.array_list.Managed(u8).init(a) };
    }
    pub fn next(self: *LineReader) !?[]const u8 {
        self.last_terminated = false;
        self.line.clearRetainingCapacity();
        if (self.offset >= self.size) return null;
        while (self.offset < self.size) {
            if (self.begin == self.end) {
                const n = c.read(self.fd, &self.buffer, @min(self.size - self.offset, self.buffer.len));
                if (n < 0) {
                    if (interrupted()) continue;
                    return errnoError();
                }
                if (n == 0) return error.UnexpectedEndOfFile;
                self.begin = 0;
                self.end = @intCast(n);
            }
            const available = self.buffer[self.begin..self.end];
            if (std.mem.indexOfScalar(u8, available, '\n')) |i| {
                try self.line.appendSlice(available[0..i]);
                self.begin += i + 1;
                self.offset += i + 1;
                self.last_terminated = true;
                return std.mem.trimEnd(u8, self.line.items, "\r");
            }
            try self.line.appendSlice(available);
            self.offset += available.len;
            self.begin = self.end;
        }
        return if (self.line.items.len == 0) null else std.mem.trimEnd(u8, self.line.items, "\r");
    }
    pub fn seek(self: *LineReader, offset: u64) !void {
        if (offset > self.size or offset > std.math.maxInt(c.off_t)) return error.InvalidOffset;
        if (c.lseek(self.fd, @intCast(offset), c.SEEK_SET) < 0) return errnoError();
        self.offset = offset;
        self.last_terminated = false;
        self.begin = 0;
        self.end = 0;
        self.line.clearRetainingCapacity();
    }
    pub fn close(self: *LineReader) void {
        if (self.fd < 0) return;
        closeFd(self.fd);
        self.fd = -1;
        self.line.deinit();
    }
};
pub fn readJsonl(a: Allocator, path: []const u8, warnings: *common.Warnings) ![]common.Value {
    var reader = try LineReader.open(a, path);
    defer reader.close();
    var values = std.array_list.Managed(common.Value).init(a);
    errdefer values.deinit();
    var number: usize = 0;
    while (try reader.next()) |line| {
        number += 1;
        if (std.mem.trim(u8, line, " \t\r\n").len == 0) continue;
        var temp = std.heap.ArenaAllocator.init(a);
        defer temp.deinit();
        const parsed = std.json.parseFromSlice(common.Value, temp.allocator(), line, .{ .allocate = .alloc_always }) catch |err| {
            if (err == error.OutOfMemory or reader.last_terminated or reader.offset != reader.size) return err;
            try warnings.append(try std.fmt.allocPrint(a, "{s}:{d}: incomplete final JSON record ignored ({s})", .{ path, number, @errorName(err) }));
            break;
        };
        try values.append(try common.clone(a, parsed.value));
    }
    return values.toOwnedSlice();
}
pub fn sha256File(a: Allocator, path: []const u8) ![]const u8 {
    var reader = try LineReader.open(a, path);
    defer reader.close();
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var left = reader.size;
    while (left > 0) {
        const n = c.read(reader.fd, &buffer, @min(left, buffer.len));
        if (n < 0) {
            if (interrupted()) continue;
            return errnoError();
        }
        if (n == 0) return error.UnexpectedEndOfFile;
        hash.update(buffer[0..@intCast(n)]);
        left -= @intCast(n);
    }
    const digest = hash.finalResult();
    const hex = std.fmt.bytesToHex(digest, .lower);
    return a.dupe(u8, &hex);
}
pub fn canonicalPath(a: Allocator, path: []const u8) ![]const u8 {
    var expanded = path;
    var expansion: ?[]const u8 = null;
    defer if (expansion) |v| a.free(v);
    if (std.mem.eql(u8, path, "~") or std.mem.startsWith(u8, path, "~/")) {
        const home = c.getenv("HOME") orelse return error.HomeNotFound;
        expansion = try std.fs.path.join(a, &.{ std.mem.span(home), if (path.len > 1) path[2..] else "" });
        expanded = expansion.?;
    }
    const cwd = c.getcwd(null, 0) orelse return errnoError();
    defer c.free(cwd);
    const absolute = try std.fs.path.resolve(a, &.{ std.mem.span(cwd), expanded });
    defer a.free(absolute);
    return canonicalAbsolute(a, absolute, 0);
}
fn canonicalAbsolute(a: Allocator, absolute: []const u8, symlinks: usize) anyerror![]const u8 {
    if (symlinks >= 40) return error.SymLinkLoop;
    var prefix_len = absolute.len;
    while (true) {
        const prefix = try zpath(a, absolute[0..prefix_len]);
        defer a.free(prefix);
        if (c.realpath(prefix.ptr, null)) |resolved| {
            defer c.free(resolved);
            if (prefix_len < absolute.len) {
                var resolved_stat: c.struct_stat = undefined;
                if (c.stat(resolved, &resolved_stat) != 0) return errnoError();
                if (resolved_stat.st_mode & c.S_IFMT != c.S_IFDIR) return error.NotDir;
            }
            return std.fs.path.resolve(a, &.{ std.mem.span(resolved), std.mem.trimStart(u8, absolute[prefix_len..], "/") });
        }
        const err = std.c.errno(@as(c_int, -1));
        if (err != .NOENT and err != .NOTDIR) return errnoError();
        // A dangling symlink exists even when realpath reports ENOENT. Resolve
        // it explicitly so the journal records its actual future target.
        var prefix_stat: c.struct_stat = undefined;
        if (c.lstat(prefix.ptr, &prefix_stat) == 0 and prefix_stat.st_mode & c.S_IFMT == c.S_IFLNK) {
            var target: [4096]u8 = undefined;
            const n = c.readlink(prefix.ptr, &target, target.len);
            if (n < 0) return errnoError();
            if (n == target.len) return error.NameTooLong;
            const redirected = try std.fs.path.resolve(a, &.{ std.fs.path.dirname(absolute[0..prefix_len]) orelse "/", target[0..@intCast(n)], std.mem.trimStart(u8, absolute[prefix_len..], "/") });
            defer a.free(redirected);
            return canonicalAbsolute(a, redirected, symlinks + 1);
        }
        if (prefix_len <= 1) return error.FileNotFound;
        const parent = std.fs.path.dirname(absolute[0..prefix_len]) orelse "/";
        prefix_len = parent.len;
    }
}
pub const Lock = struct {
    fd: c_int,
    pub fn close(self: *Lock) void {
        if (self.fd >= 0) {
            _ = c.flock(self.fd, c.LOCK_UN);
            closeFd(self.fd);
            self.fd = -1;
        }
    }
};
pub fn lock(a: Allocator, path: []const u8) !Lock {
    const p = try zpath(a, path);
    defer a.free(p);
    const fd = c.open(p.ptr, c.O_RDWR | c.O_CREAT | c.O_CLOEXEC | c.O_NOFOLLOW | c.O_NONBLOCK, @as(c_uint, 0o600));
    if (fd < 0) return errnoError();
    errdefer closeFd(fd);
    const st = try fileStat(fd);
    if (!isRegular(st) or st.st_nlink != 1 or st.st_uid != c.geteuid()) return error.UnsafeLockFile;
    if (c.fchmod(fd, @as(c_uint, 0o600)) != 0) return errnoError();
    while (c.flock(fd, c.LOCK_EX | c.LOCK_NB) != 0) {
        if (wouldBlock()) return error.LockBusy;
        if (!interrupted()) return errnoError();
    }
    return .{ .fd = fd };
}

extern "c" var environ: [*:null]?[*:0]u8;

fn monotonicMs() i64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @intCast(@as(i128, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000));
}
fn pauseMs(ms: u32) void {
    var ts = c.struct_timespec{ .tv_sec = @intCast(ms / 1000), .tv_nsec = @intCast((ms % 1000) * 1_000_000) };
    while (c.nanosleep(&ts, &ts) != 0) {
        if (!interrupted()) break;
    }
}
fn nonblocking(fd: c_int) !void {
    const flags = c.fcntl(fd, c.F_GETFL);
    if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | @as(c_int, c.O_NONBLOCK)) < 0) return errnoError();
}
fn makePipe() ![2]c_int {
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return errnoError();
    errdefer {
        closeFd(fds[0]);
        closeFd(fds[1]);
    }
    for (&fds) |*fd| {
        // Avoid dup2/close collisions when the caller has closed a stdio fd.
        if (fd.* < 3) {
            const replacement = c.fcntl(fd.*, c.F_DUPFD_CLOEXEC, @as(c_int, 3));
            if (replacement < 0) return errnoError();
            closeFd(fd.*);
            fd.* = replacement;
        } else if (c.fcntl(fd.*, c.F_SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) return errnoError();
    }
    return fds;
}
fn childFailure() noreturn {
    const message = "c2c: failed to execute process\n";
    _ = c.write(c.STDERR_FILENO, message.ptr, message.len);
    c._exit(127);
}
const Spawned = struct { pid: c.pid_t, input: c_int, output: c_int, err: c_int };
fn setPipeSignal(handler: ?std.c.Sigaction.handler_fn) !void {
    const action: std.c.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = std.posix.sigemptyset(),
        .flags = std.c.SA.RESTART,
    };
    if (std.c.sigaction(.PIPE, &action, null) != 0) return errnoError();
}
fn spawn(a: Allocator, args: []const []const u8, overrides: []const common.Env, capture_stderr: bool) !Spawned {
    if (args.len == 0 or args[0].len == 0) return error.InvalidArguments;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temporary = arena.allocator();
    const argv = try temporary.allocSentinel(?[*:0]u8, args.len, null);
    for (args, 0..) |arg, i| argv[i] = (try zpath(temporary, arg)).ptr;
    var environment = std.array_list.Managed(?[*:0]u8).init(temporary);
    var inherited: usize = 0;
    while (environ[inherited]) |entry| : (inherited += 1) {
        const text = std.mem.span(entry);
        const equals = std.mem.indexOfScalar(u8, text, '=') orelse continue;
        var overridden = false;
        for (overrides) |pair| {
            if (std.mem.eql(u8, pair[0], text[0..equals])) {
                overridden = true;
                break;
            }
        }
        if (!overridden) try environment.append((try temporary.dupeZ(u8, text)).ptr);
    }
    for (overrides) |pair| {
        if (pair[0].len == 0 or std.mem.indexOfAny(u8, pair[0], "=\x00") != null or std.mem.indexOfScalar(u8, pair[1], 0) != null) return error.InvalidEnvironment;
        try environment.append((try std.fmt.allocPrintSentinel(temporary, "{s}={s}", .{ pair[0], pair[1] }, 0)).ptr);
    }
    try environment.append(null);
    const input = try makePipe();
    errdefer {
        closeFd(input[0]);
        closeFd(input[1]);
    }
    const output = try makePipe();
    errdefer {
        closeFd(output[0]);
        closeFd(output[1]);
    }
    const stderr_pipe = try makePipe();
    errdefer {
        closeFd(stderr_pipe[0]);
        closeFd(stderr_pipe[1]);
    }
    var devnull = if (capture_stderr) @as(c_int, -1) else c.open("/dev/null", c.O_WRONLY | c.O_CLOEXEC);
    if (!capture_stderr and devnull < 0) return errnoError();
    defer closeFd(devnull);
    if (devnull >= 0 and devnull < 3) {
        const replacement = c.fcntl(devnull, c.F_DUPFD_CLOEXEC, @as(c_int, 3));
        if (replacement < 0) return errnoError();
        closeFd(devnull);
        devnull = replacement;
    }
    // Only the parent's pipe ends are nonblocking; the child's stay blocking.
    try nonblocking(input[1]);
    try nonblocking(output[0]);
    try nonblocking(stderr_pipe[0]);
    // Pipe writes must report EPIPE instead of terminating this process.
    // Restore the conventional disposition in the child before exec.
    try setPipeSignal(std.c.SIG.IGN);
    const pid = c.fork();
    if (pid < 0) return errnoError();
    if (pid == 0) {
        _ = c.setpgid(0, 0);
        setPipeSignal(std.c.SIG.DFL) catch childFailure();
        if (c.dup2(input[0], c.STDIN_FILENO) < 0 or c.dup2(output[1], c.STDOUT_FILENO) < 0 or c.dup2(if (capture_stderr) stderr_pipe[1] else devnull, c.STDERR_FILENO) < 0) childFailure();
        for ([_]c_int{ input[0], input[1], output[0], output[1], stderr_pipe[0], stderr_pipe[1] }) |fd| closeFd(fd);
        if (devnull > 2) closeFd(devnull);
        environ = @ptrCast(environment.items.ptr);
        _ = c.execvp(argv[0].?, @ptrCast(argv.ptr));
        childFailure();
    }
    _ = c.setpgid(pid, pid);
    closeFd(input[0]);
    closeFd(output[1]);
    closeFd(stderr_pipe[1]);
    return .{ .pid = pid, .input = input[1], .output = output[0], .err = stderr_pipe[0] };
}
fn pollChild(pid: c.pid_t, status: *c_int) !bool {
    while (true) {
        const result = c.waitpid(pid, status, c.WNOHANG);
        if (result == pid) return true;
        if (result == 0) return false;
        if (interrupted()) continue;
        if (std.c.errno(@as(c_int, -1)) == .CHILD) return true;
        return errnoError();
    }
}
fn terminateAndReap(pid: c.pid_t) void {
    if (pid <= 0) return;
    _ = c.kill(-pid, c.SIGKILL);
    _ = c.kill(pid, c.SIGKILL);
    const deadline = monotonicMs() + 4500;
    var status: c_int = 0;
    while (!(pollChild(pid, &status) catch true) and monotonicMs() < deadline) pauseMs(10);
}
fn waitPoll(fds: []c.struct_pollfd, timeout: c_int) !void {
    const n = c.poll(fds.ptr, @intCast(fds.len), timeout);
    if (n < 0 and !interrupted()) return errnoError();
}
fn captureOnce(fd: *c_int, result: *std.array_list.Managed(u8)) !void {
    var buffer: [64 * 1024]u8 = undefined;
    const n = c.read(fd.*, &buffer, buffer.len);
    if (n < 0) {
        if (interrupted() or wouldBlock()) return;
        return errnoError();
    }
    if (n == 0) {
        closeFd(fd.*);
        fd.* = -1;
        return;
    }
    try result.appendSlice(buffer[0..@intCast(n)]);
}
/// Executes argv directly. Overrides are merged with the inherited environment.
/// A zero timeout disables the deadline; signal exits use 128 + signal number.
pub fn run(a: Allocator, args: []const []const u8, env: []const common.Env, input_data: ?[]const u8, timeout_ms: u32) !common.RunResult {
    var child = try spawn(a, args, env, true);
    var reaped = false;
    defer {
        closeFd(child.input);
        closeFd(child.output);
        closeFd(child.err);
        if (!reaped) terminateAndReap(child.pid);
    }
    var stdout = std.array_list.Managed(u8).init(a);
    defer stdout.deinit();
    var stderr = std.array_list.Managed(u8).init(a);
    defer stderr.deinit();
    const input = input_data orelse "";
    var written: usize = 0;
    var status: c_int = 0;
    const deadline = if (timeout_ms == 0) std.math.maxInt(i64) else monotonicMs() + timeout_ms;
    while (!reaped or child.output >= 0 or child.err >= 0) {
        if (monotonicMs() >= deadline) {
            if (reaped) {
                _ = c.kill(-child.pid, c.SIGKILL);
            } else terminateAndReap(child.pid);
            reaped = true;
            return error.Timeout;
        }
        if (written == input.len and child.input >= 0) {
            closeFd(child.input);
            child.input = -1;
        }
        var fds = [_]c.struct_pollfd{
            .{ .fd = child.output, .events = c.POLLIN, .revents = 0 },
            .{ .fd = child.err, .events = c.POLLIN, .revents = 0 },
            .{ .fd = child.input, .events = c.POLLOUT, .revents = 0 },
        };
        try waitPoll(&fds, @intCast(@min(100, @max(0, deadline - monotonicMs()))));
        if (fds[0].revents != 0 and child.output >= 0) try captureOnce(&child.output, &stdout);
        if (fds[1].revents != 0 and child.err >= 0) try captureOnce(&child.err, &stderr);
        if (fds[2].revents != 0 and child.input >= 0) {
            const n = c.write(child.input, input[written..].ptr, @min(64 * 1024, input.len - written));
            if (n < 0) {
                if (!interrupted() and !wouldBlock()) {
                    if (std.c.errno(@as(c_int, -1)) != .PIPE) return errnoError();
                    closeFd(child.input);
                    child.input = -1;
                }
            } else written += @intCast(n);
        }
        if (!reaped) reaped = try pollChild(child.pid, &status);
    }
    const output = try stdout.toOwnedSlice();
    errdefer a.free(output);
    const errors = try stderr.toOwnedSlice();
    const code: i32 = if (status & 0x7f == 0) (status >> 8) & 0xff else 128 + (status & 0x7f);
    return .{ .stdout = output, .stderr = errors, .exit_code = code };
}

pub const Child = struct {
    pid: c.pid_t,
    input: c_int,
    output: c_int,
    pending: std.array_list.Managed(u8),
    ended: bool = false,
    reaped: bool = false,
    pub fn start(a: Allocator, args: []const []const u8, env: []const common.Env) !Child {
        const child = try spawn(a, args, env, false);
        closeFd(child.err);
        return .{ .pid = child.pid, .input = child.input, .output = child.output, .pending = std.array_list.Managed(u8).init(a) };
    }
    pub fn write(self: *Child, data: []const u8) !void {
        if (self.input < 0) return error.BrokenPipe;
        const deadline = monotonicMs() + 30_000;
        var pos: usize = 0;
        while (pos < data.len) {
            if (monotonicMs() >= deadline) return error.Timeout;
            const n = c.write(self.input, data[pos..].ptr, @min(64 * 1024, data.len - pos));
            if (n >= 0) {
                if (n == 0) return error.WriteZero;
                pos += @intCast(n);
                continue;
            }
            if (interrupted()) continue;
            if (!wouldBlock()) return errnoError();
            // A peer can produce responses while consuming a large request.
            // Drain stdout here as well to avoid a bidirectional pipe deadlock.
            var fds = [_]c.struct_pollfd{
                .{ .fd = self.input, .events = c.POLLOUT, .revents = 0 },
                .{ .fd = self.output, .events = c.POLLIN, .revents = 0 },
            };
            try waitPoll(&fds, 100);
            if (fds[1].revents != 0 and self.output >= 0) {
                try captureOnce(&self.output, &self.pending);
                if (self.output < 0) self.ended = true;
            }
        }
    }
    pub fn readLine(self: *Child, a: Allocator, timeout_ms: u32) !?[]const u8 {
        const deadline = if (timeout_ms == 0) std.math.maxInt(i64) else monotonicMs() + timeout_ms;
        while (true) {
            if (std.mem.indexOfScalar(u8, self.pending.items, '\n')) |i| {
                const line = try a.dupe(u8, std.mem.trimEnd(u8, self.pending.items[0..i], "\r"));
                std.mem.copyForwards(u8, self.pending.items[0 .. self.pending.items.len - i - 1], self.pending.items[i + 1 ..]);
                self.pending.items.len -= i + 1;
                return line;
            }
            if (self.ended) {
                if (self.pending.items.len == 0) return null;
                const line = try a.dupe(u8, std.mem.trimEnd(u8, self.pending.items, "\r"));
                self.pending.clearRetainingCapacity();
                return line;
            }
            if (monotonicMs() >= deadline) return error.Timeout;
            var fds = [_]c.struct_pollfd{.{ .fd = self.output, .events = c.POLLIN, .revents = 0 }};
            try waitPoll(&fds, @intCast(@min(100, @max(0, deadline - monotonicMs()))));
            if (fds[0].revents != 0) {
                try captureOnce(&self.output, &self.pending);
                if (self.output < 0) self.ended = true;
            }
        }
    }
    /// Closing never waits indefinitely for a misbehaving process or descendant.
    pub fn close(self: *Child) void {
        if (self.reaped) return;
        closeFd(self.input);
        self.input = -1;
        closeFd(self.output);
        self.output = -1;
        self.pending.deinit();
        if (!self.reaped) {
            terminateAndReap(self.pid);
            self.reaped = true;
        }
        self.ended = true;
    }
};

fn testTempDir() ![29:0]u8 {
    var path: [29:0]u8 = "/tmp/c2c-os-regression-XXXXXX".*;
    if (c.mkdtemp(&path) == null) return errnoError();
    return path;
}
fn testRemoveTree(path: []const u8) void {
    const a = std.heap.page_allocator;
    const entries = listDir(a, path) catch return;
    defer {
        for (entries) |e| a.free(e.name);
        a.free(entries);
    }
    for (entries) |entry| {
        const p = std.fs.path.join(a, &.{ path, entry.name }) catch continue;
        defer a.free(p);
        if (entry.is_dir and !entry.is_symlink) testRemoveTree(p) else removeFile(p) catch {};
    }
    const p = zpath(a, path) catch return;
    defer a.free(p);
    _ = c.rmdir(p.ptr);
}
test "private files atomic replacement copying hashing and traversal" {
    const a = std.testing.allocator;
    const temp = try testTempDir();
    defer testRemoveTree(&temp);
    const nested = try std.fs.path.join(a, &.{ &temp, "nested/deep" });
    defer a.free(nested);
    try mkdirAll(nested);
    const path = try std.fs.path.join(a, &.{ nested, "a.jsonl" });
    defer a.free(path);
    try writeExclusive(path, "abc");
    try std.testing.expectError(error.PathAlreadyExists, writeExclusive(path, "overwrite"));
    const data = try readFile(a, path);
    defer a.free(data);
    try std.testing.expectEqualStrings("abc", data);
    const hash = try sha256File(a, path);
    defer a.free(hash);
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", hash);
    const dest = try std.fs.path.join(a, &.{ nested, "b.jsonl" });
    defer a.free(dest);
    try copyExclusive(a, path, dest);
    try std.testing.expectError(error.PathAlreadyExists, copyExclusive(a, path, dest));
    const linked = try std.fs.path.join(a, &.{ nested, "c.jsonl" });
    defer a.free(linked);
    try hardLink(path, linked);
    try std.testing.expect(sameFile(path, linked));
    try atomicWrite(a, path, "updated");
    try std.testing.expect(!sameFile(path, linked));
    try std.testing.expectEqual(@as(u64, 7), (try stat(path)).size);
    const renamed = try std.fs.path.join(a, &.{ nested, "renamed.jsonl" });
    defer a.free(renamed);
    try renameFile(linked, renamed);
    try removeFile(renamed);
    try std.testing.expect(!exists(renamed));
    var lock_file = try lock(a, renamed);
    defer lock_file.close();
    try std.testing.expectError(error.LockBusy, lock(a, renamed));
    const zp = try zpath(a, path);
    defer a.free(zp);
    var st: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.stat(zp.ptr, &st));
    try std.testing.expectEqual(@as(c_uint, 0o600), st.st_mode & 0o777);
    const files = try walkFiles(a, &temp, ".jsonl");
    defer {
        for (files) |p| a.free(p);
        a.free(files);
    }
    try std.testing.expectEqual(@as(usize, 3), files.len);
    try syncDir(nested);
    try std.testing.expectError(error.InvalidPath, stat("bad\x00path"));
}
test "canonical paths resolve existing symlink prefixes and walk excludes them" {
    const a = std.testing.allocator;
    const temp = try testTempDir();
    defer testRemoveTree(&temp);
    const real = try std.fs.path.join(a, &.{ &temp, "real" });
    defer a.free(real);
    try mkdirAll(real);
    const target = try std.fs.path.join(a, &.{ real, "file.jsonl" });
    defer a.free(target);
    try writeExclusive(target, "{}");
    const link = try std.fs.path.join(a, &.{ &temp, "link" });
    defer a.free(link);
    const realz = try zpath(a, real);
    defer a.free(realz);
    const linkz = try zpath(a, link);
    defer a.free(linkz);
    try std.testing.expectEqual(@as(c_int, 0), c.symlink(realz.ptr, linkz.ptr));
    try std.testing.expect((try stat(link)).is_symlink);
    try std.testing.expectError(error.NotDir, mkdirAll(link));
    const missing = try std.fs.path.join(a, &.{ link, "new/file" });
    defer a.free(missing);
    const canonical = try canonicalPath(a, missing);
    defer a.free(canonical);
    const expected = try std.fs.path.join(a, &.{ real, "new/file" });
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, canonical);
    const dangling = try std.fs.path.join(a, &.{ &temp, "dangling" });
    defer a.free(dangling);
    const danglingz = try zpath(a, dangling);
    defer a.free(danglingz);
    try std.testing.expectEqual(@as(c_int, 0), c.symlink("real/not-yet-created", danglingz.ptr));
    const dangling_child = try std.fs.path.join(a, &.{ dangling, "child" });
    defer a.free(dangling_child);
    const actual_dangling = try canonicalPath(a, dangling_child);
    defer a.free(actual_dangling);
    const expected_dangling = try std.fs.path.join(a, &.{ real, "not-yet-created/child" });
    defer a.free(expected_dangling);
    try std.testing.expectEqualStrings(expected_dangling, actual_dangling);
    const impossible = try std.fs.path.join(a, &.{ target, "child" });
    defer a.free(impossible);
    try std.testing.expectError(error.NotDir, canonicalPath(a, impossible));
    const files = try walkFiles(a, &temp, ".jsonl");
    defer {
        for (files) |p| a.free(p);
        a.free(files);
    }
    try std.testing.expectEqual(@as(usize, 1), files.len);
}
test "line reader handles long lines seek trailing newline and fixed snapshot" {
    const a = std.testing.allocator;
    const temp = try testTempDir();
    defer testRemoveTree(&temp);
    const path = try std.fs.path.join(a, &.{ &temp, "lines" });
    defer a.free(path);
    const long = try a.alloc(u8, 150_000);
    defer a.free(long);
    @memset(long, 'x');
    const content = try std.mem.concat(a, u8, &.{ "first\r\n", long, "\nlast" });
    defer a.free(content);
    try writeExclusive(path, content);
    var reader = try LineReader.open(a, path);
    defer reader.close();
    const p = try zpath(a, path);
    defer a.free(p);
    const fd = c.open(p.ptr, c.O_WRONLY | c.O_APPEND);
    defer closeFd(fd);
    try writeAll(fd, "ignored");
    try std.testing.expectEqualStrings("first", (try reader.next()).?);
    try std.testing.expectEqual(@as(u64, 7), reader.offset);
    try std.testing.expect(reader.last_terminated);
    try std.testing.expectEqualStrings(long, (try reader.next()).?);
    try std.testing.expectEqualStrings("last", (try reader.next()).?);
    try std.testing.expect(!reader.last_terminated);
    try std.testing.expect((try reader.next()) == null);
    try reader.seek(7);
    try std.testing.expectEqualStrings(long, (try reader.next()).?);
    try std.testing.expectError(error.InvalidOffset, reader.seek(reader.size + 1));
}
test "jsonl incomplete final record warns and preserves all complete records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const temp = try testTempDir();
    defer testRemoveTree(&temp);
    const path = try std.fs.path.join(a, &.{ &temp, "input.jsonl" });
    try writeExclusive(path, "{\"name\":\"one\",\"nested\":[{\"key\":\"value\"}]}\n\n{\"name\":\"two\"}\n{\"partial\":");
    var warnings = common.Warnings.init(a);
    const values = try readJsonl(a, path, &warnings);
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expectEqual(@as(usize, 1), warnings.items.len);
    try std.testing.expectEqualStrings("one", common.s(values[0], "name"));
    try std.testing.expectEqualStrings("value", common.s(common.list(common.get(values[0], "nested"))[0], "key"));
}
test "jsonl malformed interior and terminated final records fail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const temp = try testTempDir();
    defer testRemoveTree(&temp);
    const path = try std.fs.path.join(a, &.{ &temp, "input.jsonl" });
    var warnings = common.Warnings.init(a);
    try writeExclusive(path, "{}\n{]\n{}\n");
    try std.testing.expectError(error.SyntaxError, readJsonl(a, path, &warnings));
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
    try atomicWrite(a, path, "{}\n{]\n");
    try std.testing.expectError(error.SyntaxError, readJsonl(a, path, &warnings));
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
}
test "run captures both pipes while feeding stdin and merges environment" {
    const a = std.testing.allocator;
    const input = try a.alloc(u8, 500_000);
    defer a.free(input);
    @memset(input, 'i');
    const result = try run(a, &.{ "python3", "-c", "import os,sys; sys.stderr.write('e'*200000); sys.stdout.write('o'*200000); sys.stdout.flush(); d=sys.stdin.buffer.read(); sys.stdout.buffer.write(d); sys.stderr.write(os.environ['C2C_OS_TEST'])" }, &.{.{ "C2C_OS_TEST", "works" }}, input, 5000);
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expectEqual(@as(usize, 700_000), result.stdout.len);
    try std.testing.expectEqual(@as(usize, 200_005), result.stderr.len);
    try std.testing.expect(std.mem.endsWith(u8, result.stderr, "works"));
    try std.testing.expect(std.mem.endsWith(u8, result.stdout, input));
}
test "run deadlines survive continuous output and descendants holding pipes" {
    const a = std.testing.allocator;
    const start = monotonicMs();
    try std.testing.expectError(error.Timeout, run(a, &.{ "python3", "-c", "import os\nwhile True: os.write(1,b'x'*65536)" }, &.{}, null, 100));
    try std.testing.expect(monotonicMs() - start < 3000);
    try std.testing.expectError(error.Timeout, run(a, &.{ "python3", "-c", "import os,time\nif os.fork()==0: time.sleep(20)" }, &.{}, null, 100));
    const result = try run(a, &.{"/definitely/missing/c2c-test-executable"}, &.{}, null, 1000);
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try std.testing.expectEqual(@as(i32, 127), result.exit_code);
}
test "child restores default SIGPIPE disposition" {
    const a = std.testing.allocator;
    const result = try run(a, &.{ "/bin/sh", "-c", "kill -PIPE $$; exit 99" }, &.{}, null, 1000);
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try std.testing.expectEqual(@as(i32, 128 + c.SIGPIPE), result.exit_code);
}
test "interactive child lines preserve buffering EOF and broken pipe safety" {
    const a = std.testing.allocator;
    var child = try Child.start(a, &.{ "python3", "-u", "-c", "import os,sys; s=sys.stdin.readline(); os.close(0); sys.stdout.write(s+'two\\nlast')" }, &.{});
    defer child.close();
    try child.write("one\n");
    const one = (try child.readLine(a, 1000)).?;
    defer a.free(one);
    const two = (try child.readLine(a, 1000)).?;
    defer a.free(two);
    const last = (try child.readLine(a, 1000)).?;
    defer a.free(last);
    try std.testing.expectEqualStrings("one", one);
    try std.testing.expectEqualStrings("two", two);
    try std.testing.expectEqualStrings("last", last);
    try std.testing.expect((try child.readLine(a, 1000)) == null);
    try std.testing.expectError(error.BrokenPipe, child.write("closed\n"));
}
