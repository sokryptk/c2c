const std = @import("std");
const common = @import("../common.zig");
const c = common.c;
const posix = @import("posix.zig");
const errnoError = posix.errnoError;
const zpath = posix.zpath;
const closeFd = posix.closeFd;
const writeAll = posix.writeAll;

const fs = @import("fs.zig");
const stat = fs.stat;
const exists = fs.exists;
const sameFile = fs.sameFile;
const readFile = fs.readFile;
const writeExclusive = fs.writeExclusive;
const atomicWrite = fs.atomicWrite;
const mkdirAll = fs.mkdirAll;
const hardLink = fs.hardLink;
const removeFile = fs.removeFile;
const renameFile = fs.renameFile;
const syncDir = fs.syncDir;
const copyExclusive = fs.copyExclusive;
const listDir = fs.listDir;
const walkFiles = fs.walkFiles;
const sha256File = fs.sha256File;
const canonicalPath = fs.canonicalPath;
const lock = fs.lock;
const lines = @import("lines.zig");
const LineReader = lines.LineReader;
const readJsonl = lines.readJsonl;

fn testTempDir() ![29:0]u8 {
    var path: [29:0]u8 = "/tmp/c2c-os-regression-XXXXXX".*;
    if (c.mkdtemp(&path) == null) {
        return errnoError();
    }
    return path;
}

fn testRemoveTree(path: []const u8) void {
    const allocator = std.heap.page_allocator;
    const entries = listDir(allocator, path) catch return;
    defer {
        for (entries) |e| {
            allocator.free(e.name);
        }
        allocator.free(entries);
    }
    for (entries) |entry| {
        const p = std.fs.path.join(allocator, &.{ path, entry.name }) catch continue;
        defer allocator.free(p);
        if (entry.is_dir and !entry.is_symlink) {
            testRemoveTree(p);
        } else {
            removeFile(p) catch {};
        }
    }
    const p = zpath(allocator, path) catch return;
    defer allocator.free(p);
    _ = c.rmdir(p.ptr);
}
test "private files atomic replacement copying hashing and traversal" {
    const allocator = std.testing.allocator;
    const temp = try testTempDir();
    defer testRemoveTree(&temp);
    const nested = try std.fs.path.join(allocator, &.{ &temp, "nested/deep" });
    defer allocator.free(nested);
    try mkdirAll(nested);
    const path = try std.fs.path.join(allocator, &.{ nested, "a.jsonl" });
    defer allocator.free(path);
    try writeExclusive(path, "abc");
    try std.testing.expectError(error.PathAlreadyExists, writeExclusive(path, "overwrite"));
    const data = try readFile(allocator, path);
    defer allocator.free(data);
    try std.testing.expectEqualStrings("abc", data);
    const hash = try sha256File(allocator, path);
    defer allocator.free(hash);
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", hash);
    const dest = try std.fs.path.join(allocator, &.{ nested, "b.jsonl" });
    defer allocator.free(dest);
    try copyExclusive(allocator, path, dest);
    try std.testing.expectError(error.PathAlreadyExists, copyExclusive(allocator, path, dest));
    const linked = try std.fs.path.join(allocator, &.{ nested, "c.jsonl" });
    defer allocator.free(linked);
    try hardLink(path, linked);
    try std.testing.expect(sameFile(path, linked));
    try atomicWrite(allocator, path, "updated");
    try std.testing.expect(!sameFile(path, linked));
    try std.testing.expectEqual(@as(u64, 7), (try stat(path)).size);
    const renamed = try std.fs.path.join(allocator, &.{ nested, "renamed.jsonl" });
    defer allocator.free(renamed);
    try renameFile(linked, renamed);
    try removeFile(renamed);
    try std.testing.expect(!exists(renamed));
    var lock_file = try lock(allocator, renamed);
    defer lock_file.close();
    try std.testing.expectError(error.LockBusy, lock(allocator, renamed));
    const zp = try zpath(allocator, path);
    defer allocator.free(zp);
    var st: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.stat(zp.ptr, &st));
    try std.testing.expectEqual(@as(c_uint, 0o600), st.st_mode & 0o777);
    const files = try walkFiles(allocator, &temp, ".jsonl");
    defer {
        for (files) |p| {
            allocator.free(p);
        }
        allocator.free(files);
    }
    try std.testing.expectEqual(@as(usize, 3), files.len);
    try syncDir(nested);
    try std.testing.expectError(error.InvalidPath, stat("bad\x00path"));
}
test "canonical paths resolve existing symlink prefixes and walk excludes them" {
    const allocator = std.testing.allocator;
    const temp = try testTempDir();
    defer testRemoveTree(&temp);
    const real = try std.fs.path.join(allocator, &.{ &temp, "real" });
    defer allocator.free(real);
    try mkdirAll(real);
    const target = try std.fs.path.join(allocator, &.{ real, "file.jsonl" });
    defer allocator.free(target);
    try writeExclusive(target, "{}");
    const link = try std.fs.path.join(allocator, &.{ &temp, "link" });
    defer allocator.free(link);
    const realz = try zpath(allocator, real);
    defer allocator.free(realz);
    const linkz = try zpath(allocator, link);
    defer allocator.free(linkz);
    try std.testing.expectEqual(@as(c_int, 0), c.symlink(realz.ptr, linkz.ptr));
    try std.testing.expect((try stat(link)).is_symlink);
    try std.testing.expectError(error.NotDir, mkdirAll(link));
    const missing = try std.fs.path.join(allocator, &.{ link, "new/file" });
    defer allocator.free(missing);
    const canonical = try canonicalPath(allocator, missing);
    defer allocator.free(canonical);
    const expected = try std.fs.path.join(allocator, &.{ real, "new/file" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, canonical);
    const dangling = try std.fs.path.join(allocator, &.{ &temp, "dangling" });
    defer allocator.free(dangling);
    const danglingz = try zpath(allocator, dangling);
    defer allocator.free(danglingz);
    try std.testing.expectEqual(@as(c_int, 0), c.symlink("real/not-yet-created", danglingz.ptr));
    const dangling_child = try std.fs.path.join(allocator, &.{ dangling, "child" });
    defer allocator.free(dangling_child);
    const actual_dangling = try canonicalPath(allocator, dangling_child);
    defer allocator.free(actual_dangling);
    const expected_dangling = try std.fs.path.join(allocator, &.{ real, "not-yet-created/child" });
    defer allocator.free(expected_dangling);
    try std.testing.expectEqualStrings(expected_dangling, actual_dangling);
    const impossible = try std.fs.path.join(allocator, &.{ target, "child" });
    defer allocator.free(impossible);
    try std.testing.expectError(error.NotDir, canonicalPath(allocator, impossible));
    const files = try walkFiles(allocator, &temp, ".jsonl");
    defer {
        for (files) |p| {
            allocator.free(p);
        }
        allocator.free(files);
    }
    try std.testing.expectEqual(@as(usize, 1), files.len);
}
test "line reader handles long lines seek trailing newline and fixed snapshot" {
    const allocator = std.testing.allocator;
    const temp = try testTempDir();
    defer testRemoveTree(&temp);
    const path = try std.fs.path.join(allocator, &.{ &temp, "lines" });
    defer allocator.free(path);
    const long = try allocator.alloc(u8, 150_000);
    defer allocator.free(long);
    @memset(long, 'x');
    const content = try std.mem.concat(allocator, u8, &.{ "first\r\n", long, "\nlast" });
    defer allocator.free(content);
    try writeExclusive(path, content);
    var reader = try LineReader.open(allocator, path);
    defer reader.close();
    const p = try zpath(allocator, path);
    defer allocator.free(p);
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
    const allocator = arena.allocator();
    const temp = try testTempDir();
    defer testRemoveTree(&temp);
    const path = try std.fs.path.join(allocator, &.{ &temp, "input.jsonl" });
    try writeExclusive(path, "{\"name\":\"one\",\"nested\":[{\"key\":\"value\"}]}\n\n{\"name\":\"two\"}\n{\"partial\":");
    var warnings = common.Warnings.init(allocator);
    const values = try readJsonl(allocator, path, &warnings);
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expectEqual(@as(usize, 1), warnings.items.len);
    try std.testing.expectEqualStrings("one", common.stringField(values[0], "name"));
    try std.testing.expectEqualStrings("value", common.stringField(common.list(common.get(values[0], "nested"))[0], "key"));
}
test "jsonl malformed interior and terminated final records fail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const temp = try testTempDir();
    defer testRemoveTree(&temp);
    const path = try std.fs.path.join(allocator, &.{ &temp, "input.jsonl" });
    var warnings = common.Warnings.init(allocator);
    try writeExclusive(path, "{}\n{]\n{}\n");
    try std.testing.expectError(error.SyntaxError, readJsonl(allocator, path, &warnings));
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
    try atomicWrite(allocator, path, "{}\n{]\n");
    try std.testing.expectError(error.SyntaxError, readJsonl(allocator, path, &warnings));
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
}
