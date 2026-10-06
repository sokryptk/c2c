const std = @import("std");
pub const c = @cImport({
    // Zig's C importer cannot translate glibc's fortified variadic inline
    // wrappers in optimized builds.
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("dirent.h");
    @cInclude("errno.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/file.h");
    @cInclude("sys/wait.h");
    @cInclude("poll.h");
    @cInclude("time.h");
    @cInclude("signal.h");
    @cInclude("limits.h");
});
pub const Allocator = std.mem.Allocator;
pub const Value = std.json.Value;
pub const Pair = struct { []const u8, Value };
pub const Warnings = std.array_list.Managed([]const u8);

pub const Thread = struct {
    id: []const u8,
    title: []const u8,
    cwd: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    rollout_path: []const u8,
    parent_id: ?[]const u8 = null,
    source: []const u8 = "cli",
    archived: bool = false,
    history_mode: []const u8 = "legacy",
    original_codex_id: ?[]const u8 = null,
    original_claude_id: ?[]const u8 = null,
    unchanged_import: bool = false,
    provider: []const u8 = "codex",
    origin_provider: ?[]const u8 = null,
    origin_id: ?[]const u8 = null,
};
pub const Item = struct {
    id: []const u8,
    role: []const u8,
    text: []const u8,
    timestamp: []const u8,
    kind: []const u8,
    attachments: []const Value = &.{},
    raw: ?Value = null,
    ordinal: i64 = 0,
};
pub const Compaction = struct {
    summary: []const u8,
    items: []const Item = &.{},
    timestamp: ?[]const u8 = null,
    ordinal: i64 = 0,
    encrypted: bool = false,
};
pub const Conversion = struct {
    entries: []const Value,
    warnings: []const []const u8 = &.{},
    message_count: usize = 0,
    tool_count: usize = 0,
    source_item_count: usize = 0,
    session_id: []const u8,
};
pub const ConvertOptions = struct {
    embed_images: bool = true,
    transcript_path: ?[]const u8 = null,
    source_provider: ?[]const u8 = null,
    source_session_id: ?[]const u8 = null,
};
pub const Env = struct { []const u8, []const u8 };
pub const RunResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: i32,
};
pub const FileInfo = struct {
    size: u64,
    mtime_ns: i128,
    is_dir: bool,
    is_symlink: bool = false,
};
pub const DirEntry = struct {
    name: []const u8,
    is_dir: bool,
    is_symlink: bool,
};

pub fn str(value: []const u8) Value {
    return .{ .string = value };
}

pub fn num(n: i64) Value {
    return .{ .integer = n };
}

pub fn boolean(value: bool) Value {
    return .{ .bool = value };
}

pub fn obj(allocator: Allocator, fields: []const Pair) !Value {
    var map: std.json.ObjectMap = .empty;
    for (fields) |pair| {
        try map.put(allocator, pair[0], pair[1]);
    }
    return .{ .object = map };
}

pub fn arr(allocator: Allocator, values: []const Value) !Value {
    var items = std.array_list.Managed(Value).init(allocator);
    try items.appendSlice(values);
    return .{ .array = items };
}

pub fn get(value: Value, key: []const u8) Value {
    if (value != .object) {
        return .null;
    }
    return value.object.get(key) orelse .null;
}

pub fn text(value: Value) []const u8 {
    return if (value == .string) value.string else "";
}

pub fn stringField(value: Value, key: []const u8) []const u8 {
    return text(get(value, key));
}

pub fn integer(value: Value) i64 {
    return switch (value) {
        .integer => value.integer,
        .float => @intFromFloat(value.float),
        else => 0,
    };
}

pub fn boolValue(value: Value) bool {
    return value == .bool and value.bool;
}

pub fn list(value: Value) []const Value {
    return if (value == .array) value.array.items else &.{};
}

pub fn set(allocator: Allocator, object: *Value, key: []const u8, value: Value) !void {
    try object.object.put(allocator, key, value);
}

pub fn parse(allocator: Allocator, data: []const u8) !Value {
    const parsed = try std.json.parseFromSlice(Value, allocator, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    return parsed.value;
}

pub fn json(allocator: Allocator, value: Value) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

pub fn clone(allocator: Allocator, value: Value) Allocator.Error!Value {
    return switch (value) {
        .string => .{ .string = try allocator.dupe(u8, value.string) },
        .number_string => .{ .number_string = try allocator.dupe(u8, value.number_string) },
        .array => blk: {
            var out = std.array_list.Managed(Value).init(allocator);
            for (value.array.items) |child| {
                const child_copy = try clone(allocator, child);
                try out.append(child_copy);
            }
            break :blk .{ .array = out };
        },
        .object => blk: {
            var out: std.json.ObjectMap = .empty;
            var it = value.object.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const entry_copy = try clone(allocator, entry.value_ptr.*);
                try out.put(allocator, key, entry_copy);
            }
            break :blk .{ .object = out };
        },
        else => value,
    };
}

pub fn eq(first: []const u8, second: []const u8) bool {
    return std.mem.eql(u8, first, second);
}

pub fn oneOf(value: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| {
        if (eq(value, choice)) {
            return true;
        }
    }
    return false;
}

pub fn join(allocator: Allocator, parts: []const []const u8) ![]const u8 {
    return std.fs.path.join(allocator, parts);
}

pub fn fmt(allocator: Allocator, comptime format: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(allocator, format, args);
}

pub const readFile = @import("os.zig").readFile;
pub const writeExclusive = @import("os.zig").writeExclusive;
pub const atomicWrite = @import("os.zig").atomicWrite;
pub const mkdirAll = @import("os.zig").mkdirAll;
pub const stat = @import("os.zig").stat;
pub const exists = @import("os.zig").exists;
pub const listDir = @import("os.zig").listDir;
pub const walkFiles = @import("os.zig").walkFiles;
pub const readJsonl = @import("os.zig").readJsonl;
pub const sha256File = @import("os.zig").sha256File;
pub const canonicalPath = @import("os.zig").canonicalPath;
pub const hardLink = @import("os.zig").hardLink;
pub const removeFile = @import("os.zig").removeFile;
pub const renameFile = @import("os.zig").renameFile;
pub const syncDir = @import("os.zig").syncDir;
pub const lock = @import("os.zig").lock;
pub const sameFile = @import("os.zig").sameFile;
pub const copyExclusive = @import("os.zig").copyExclusive;
pub const run = @import("os.zig").run;
pub const Child = @import("os.zig").Child;
pub const LineReader = @import("os.zig").LineReader;

pub fn nowMillis() i64 {
    var value: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_REALTIME, &value) != 0) {
        return 0;
    }
    return @as(i64, @intCast(value.tv_sec)) * 1000 + @divFloor(@as(i64, @intCast(value.tv_nsec)), 1_000_000);
}

pub fn timestamp(allocator: Allocator, millis: i64) ![]const u8 {
    var seconds: c.time_t = @intCast(@divFloor(millis, 1000));
    var calendar: c.struct_tm = undefined;
    if (c.gmtime_r(&seconds, &calendar) == null) {
        return error.InvalidTimestamp;
    }
    var buffer: [64]u8 = undefined;
    const len = c.strftime(&buffer, buffer.len, "%Y-%m-%dT%H:%M:%S", &calendar);
    if (len == 0) {
        return error.InvalidTimestamp;
    }
    return fmt(allocator, "{s}.{d:0>3}Z", .{ buffer[0..len], @as(u16, @intCast(@mod(millis, 1000))) });
}

pub fn timestampMillis(value: []const u8) !i64 {
    if (value.len < 19 or
        value[4] != '-' or
        value[7] != '-' or
        (value[10] != 'T' and value[10] != ' '))
    {
        return error.InvalidTimestamp;
    }
    var calendar = std.mem.zeroes(c.struct_tm);
    calendar.tm_year = (std.fmt.parseInt(c_int, value[0..4], 10) catch return error.InvalidTimestamp) - 1900;
    calendar.tm_mon = (std.fmt.parseInt(c_int, value[5..7], 10) catch return error.InvalidTimestamp) - 1;
    calendar.tm_mday = std.fmt.parseInt(c_int, value[8..10], 10) catch return error.InvalidTimestamp;
    calendar.tm_hour = std.fmt.parseInt(c_int, value[11..13], 10) catch return error.InvalidTimestamp;
    calendar.tm_min = std.fmt.parseInt(c_int, value[14..16], 10) catch return error.InvalidTimestamp;
    calendar.tm_sec = std.fmt.parseInt(c_int, value[17..19], 10) catch return error.InvalidTimestamp;
    if (calendar.tm_mon < 0 or calendar.tm_mon > 11 or
        calendar.tm_mday < 1 or calendar.tm_mday > 31 or
        calendar.tm_hour > 23 or calendar.tm_min > 59 or calendar.tm_sec > 60)
    {
        return error.InvalidTimestamp;
    }
    const seconds = c.timegm(&calendar);
    var index: usize = 19;
    var millis: i64 = 0;
    if (index < value.len and value[index] == '.') {
        index += 1;
        var digits: usize = 0;
        while (index < value.len and std.ascii.isDigit(value[index])) : (index += 1) {
            if (digits < 3) {
                millis = millis * 10 + value[index] - '0';
            }
            digits += 1;
        }
        while (digits < 3) : (digits += 1) {
            millis *= 10;
        }
    }
    var offset: i64 = 0;
    if (index < value.len and (value[index] == '+' or value[index] == '-')) {
        const negative = value[index] == '-';
        if (value.len < index + 6 or value[index + 3] != ':') {
            return error.InvalidTimestamp;
        }
        const hours = std.fmt.parseInt(i64, value[index + 1 .. index + 3], 10) catch return error.InvalidTimestamp;
        const minutes = std.fmt.parseInt(i64, value[index + 4 .. index + 6], 10) catch return error.InvalidTimestamp;
        if (hours > 23 or minutes > 59) {
            return error.InvalidTimestamp;
        }
        offset = (hours * 60 + minutes) * 60 * 1000 * @as(i64, if (negative) -1 else 1);
    }
    return @as(i64, @intCast(seconds)) * 1000 + millis - offset;
}

pub fn sha256(allocator: Allocator, data: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

pub fn uuid5(allocator: Allocator, namespace: []const u8, name: []const u8) ![]const u8 {
    var hex: [32]u8 = undefined;
    var index: usize = 0;
    for (namespace) |char| {
        if (char == '-') {
            continue;
        }
        if (index >= hex.len) {
            return error.InvalidUuid;
        }
        hex[index] = char;
        index += 1;
    }
    if (index != hex.len) {
        return error.InvalidUuid;
    }
    var bytes: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, &hex) catch return error.InvalidUuid;
    var hash = std.crypto.hash.Sha1.init(.{});
    hash.update(&bytes);
    hash.update(name);
    var digest: [20]u8 = undefined;
    hash.final(&digest);
    digest[6] = (digest[6] & 0x0f) | 0x50;
    digest[8] = (digest[8] & 0x3f) | 0x80;
    const encoded = std.fmt.bytesToHex(digest[0..16].*, .lower);
    return fmt(allocator, "{s}-{s}-{s}-{s}-{s}", .{
        encoded[0..8],
        encoded[8..12],
        encoded[12..16],
        encoded[16..20],
        encoded[20..32],
    });
}

pub fn validUuid(value: []const u8) bool {
    if (value.len != 36) {
        return false;
    }
    for (value, 0..) |char, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (char != '-') {
                return false;
            }
        } else if (!std.ascii.isHex(char)) {
            return false;
        }
    }
    return true;
}

pub fn sessionIdFor(allocator: Allocator, target: []const u8, source: []const u8, id: []const u8) ![]const u8 {
    if (eq(target, "claude") and eq(source, "codex")) {
        const name = try fmt(allocator, "session:{s}", .{id});
        return uuid5(allocator, "6ee9e2ac-f1e7-4ed0-9ecb-ced168929080", name);
    }
    if (eq(target, "codex") and eq(source, "claude")) {
        const name = try fmt(allocator, "claude-session:{s}", .{id});
        return uuid5(allocator, "b18998c2-4d26-40bd-9c20-2dd493c3a146", name);
    }
    const name = try fmt(allocator, "{s}:{s}:{s}", .{ target, source, id });
    return uuid5(allocator, "513b91c0-7a0b-45e8-bc3c-8516e955c21d", name);
}

test "UUIDv5 matches established migration identity" {
    const allocator = std.testing.allocator;
    const actual = try uuid5(allocator, "6ba7b810-9dad-11d1-80b4-00c04fd430c8", "python.org");
    defer allocator.free(actual);
    try std.testing.expectEqualStrings("886313e1-3b8a-5372-9b90-0c9aee199e5d", actual);
}
test "timestamps preserve UTC and offsets" {
    const allocator = std.testing.allocator;
    const expected = try timestampMillis("2026-10-06T00:00:00.123Z");
    try std.testing.expectEqual(expected, try timestampMillis("2026-10-06T05:30:00.123+05:30"));
    const actual = try timestamp(allocator, expected);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings("2026-10-06T00:00:00.123Z", actual);
}
