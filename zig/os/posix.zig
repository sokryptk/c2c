const std = @import("std");
const common = @import("../common.zig");
const c = common.c;
const Allocator = std.mem.Allocator;

pub fn errnoError() anyerror {
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
pub fn interrupted() bool {
    return std.c.errno(@as(c_int, -1)) == .INTR;
}
pub fn wouldBlock() bool {
    return std.c.errno(@as(c_int, -1)) == .AGAIN;
}
pub fn zpath(a: Allocator, path: []const u8) ![:0]u8 {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    return a.dupeZ(u8, path);
}
pub fn closeFd(fd: c_int) void {
    if (fd >= 0) {
        _ = c.close(fd);
    }
}
pub fn fsyncFd(fd: c_int) !void {
    while (c.fsync(fd) != 0) {
        if (!interrupted()) return errnoError();
    }
}
pub fn writeAll(fd: c_int, data: []const u8) !void {
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
pub fn fileStat(fd: c_int) !c.struct_stat {
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0) return errnoError();
    return st;
}
pub fn isRegular(st: c.struct_stat) bool {
    return st.st_mode & c.S_IFMT == c.S_IFREG;
}
