const std = @import("std");
const common = @import("../common.zig");
const c = common.c;
const Allocator = std.mem.Allocator;
const posix = @import("posix.zig");
const errnoError = posix.errnoError;
const interrupted = posix.interrupted;
const zpath = posix.zpath;
const closeFd = posix.closeFd;
const fileStat = posix.fileStat;
const isRegular = posix.isRegular;

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
