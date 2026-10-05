const std = @import("std");
const common = @import("../common.zig");
const c = common.c;
const Allocator = std.mem.Allocator;
pub const DirEntry = common.DirEntry;
const LineReader = @import("lines.zig").LineReader;
const posix = @import("posix.zig");
const errnoError = posix.errnoError;
const interrupted = posix.interrupted;
const wouldBlock = posix.wouldBlock;
const zpath = posix.zpath;
const closeFd = posix.closeFd;
const fsyncFd = posix.fsyncFd;
const writeAll = posix.writeAll;
const fileStat = posix.fileStat;
const isRegular = posix.isRegular;

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
