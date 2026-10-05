const std = @import("std");
const H = @import("../common.zig");
const A = H.Allocator;
const V = H.Value;
const Options = @import("options.zig").Options;
const diagnostics = @import("../diagnostics.zig");
const os = @import("../os.zig");

fn sourcePath(record: V) []const u8 {
    const path = H.s(record, "sourcePath");
    return if (path.len > 0) path else H.s(H.get(record, "sourceStamp"), "path");
}

pub fn resultContext(a: A, record: V) !V {
    var result = try H.obj(a, &.{ .{ "sourceThreadId", H.get(record, "sourceThreadId") }, .{ "sessionId", H.get(record, "sessionId") }, .{ "targetPath", H.get(record, "targetPath") } });
    if (sourcePath(record).len > 0) try H.set(a, &result, "sourcePath", H.str(sourcePath(record)));
    return result;
}

pub fn setFailure(a: A, result: *V, code: []const u8, phase: []const u8) !void {
    try H.set(a, result, "status", H.str("error"));
    try H.set(a, result, "errorType", H.str(code));
    try H.set(a, result, "reason", H.str(diagnostics.reason(code)));
    try H.set(a, result, "phase", H.str(phase));
}

pub fn failedRow(a: A, record: V, code: []const u8, phase: []const u8) !V {
    var result = try resultContext(a, record);
    try setFailure(a, &result, code, phase);
    return result;
}

pub fn summary(a: A, rows: []const V) !V {
    var counts = try H.obj(a, &.{});
    for (rows) |row| {
        const status = H.s(row, "status");
        try H.set(a, &counts, status, H.num(H.integer(H.get(counts, status)) + 1));
    }
    return H.obj(a, &.{ .{ "counts", counts }, .{ "threads", try H.arr(a, rows) } });
}

pub fn progress(a: A, index: usize, total: usize, id: []const u8, status: []const u8) !void {
    if (@import("builtin").is_test) return;
    const message = try H.fmt(a, "[{d}/{d}] {s}: {s}\n", .{ index + 1, total, id, status });
    try writeAll(2, message);
}

pub fn terminalFailure(a: A, code: []const u8, phase: []const u8) !V {
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

pub fn renderFailure(a: A, result: V) ![]const u8 {
    return H.fmt(a, "c2c: {s}\n{s}", .{ H.s(result, "errorType"), try diagnosticDetails(a, result) });
}

pub fn renderRow(a: A, row: V) ![]const u8 {
    const status = H.s(row, "status");
    if (!H.oneOf(status, &.{ "error", "invalid", "missing", "collision", "pending-registration", "registering" })) return H.fmt(a, "{s}  {s}  {s}\n", .{ H.s(row, "sourceThreadId"), status, if (H.s(row, "sessionId").len > 0) H.s(row, "sessionId") else H.s(row, "title") });
    var details = try H.clone(a, row);
    const code = if (H.s(row, "errorType").len > 0) H.s(row, "errorType") else H.s(row, "registrationError");
    if (H.s(details, "reason").len == 0) {
        const reason = if (code.len > 0) diagnostics.reason(code) else if (H.eq(status, "collision"))
            "The destination already exists. It was preserved; c2c will not overwrite it."
        else if (H.eq(status, "missing"))
            "The installed destination is missing. Check its path and the destination app."
        else if (H.eq(status, "invalid"))
            "The destination failed validation. Inspect it before retrying."
        else if (H.oneOf(status, &.{ "pending-registration", "registering" }))
            "Native registration is unfinished. Check the destination CLI, then retry the same migration."
        else
            diagnostics.reason("");
        try H.set(a, &details, "reason", H.str(reason));
    }
    const suffix = if (code.len > 0) try H.fmt(a, " ({s})", .{code}) else "";
    return H.fmt(a, "{s}  {s}{s}\n{s}", .{ H.s(row, "sourceThreadId"), status, suffix, try diagnosticDetails(a, details) });
}

pub fn printResult(a: A, options: Options, result: V) !void {
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

fn writeAll(fd: c_int, bytes: []const u8) !void {
    os.writeAll(fd, bytes) catch return error.WriteFailed;
}

pub fn printHelp() !void {
    try writeAll(1, "c2c — native coding-agent conversation migration\n\n" ++
        "  c2c codex-to-claude [migrate|inventory|verify|list|undo] [options]\n" ++
        "  c2c claude-to-codex [migrate|inventory|verify|list|undo] [options]\n" ++
        "  c2c [action] --from PROVIDER --to PROVIDER [options]\n\n" ++
        "Providers: codex, claude, omp, opencode\n" ++
        "Options: --codex-home --claude-home --omp-home --opencode-home\n" ++
        "         --output-dir --project --project-prefix --thread\n" ++
        "         --origin-manifest --include-subagents --no-images --json\n" ++
        "Existing chats are never overwritten. Unchanged round trips are skipped.\n");
}
