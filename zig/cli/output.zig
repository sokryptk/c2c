const std = @import("std");
const common = @import("../common.zig");
const Allocator = common.Allocator;
const Value = common.Value;
const Options = @import("options.zig").Options;
const diagnostics = @import("../diagnostics.zig");
const os = @import("../os.zig");

fn sourcePath(record: Value) []const u8 {
    const path = common.stringField(record, "sourcePath");
    return if (path.len > 0) path else common.stringField(common.get(record, "sourceStamp"), "path");
}

pub fn resultContext(allocator: Allocator, record: Value) !Value {
    var result = try common.obj(allocator, &.{
        .{ "sourceThreadId", common.get(record, "sourceThreadId") },
        .{ "sessionId", common.get(record, "sessionId") },
        .{ "targetPath", common.get(record, "targetPath") },
    });
    const path = sourcePath(record);
    if (path.len > 0) {
        try common.set(allocator, &result, "sourcePath", common.str(path));
    }
    return result;
}

pub fn setFailure(allocator: Allocator, result: *Value, code: []const u8, phase: []const u8) !void {
    try common.set(allocator, result, "status", common.str("error"));
    try common.set(allocator, result, "errorType", common.str(code));
    try common.set(allocator, result, "reason", common.str(diagnostics.reason(code)));
    try common.set(allocator, result, "phase", common.str(phase));
}

pub fn failedRow(allocator: Allocator, record: Value, code: []const u8, phase: []const u8) !Value {
    var result = try resultContext(allocator, record);
    try setFailure(allocator, &result, code, phase);
    return result;
}

pub fn summary(allocator: Allocator, rows: []const Value) !Value {
    var counts = try common.obj(allocator, &.{});
    for (rows) |row| {
        const status = common.stringField(row, "status");
        try common.set(allocator, &counts, status, common.num(common.integer(common.get(counts, status)) + 1));
    }
    return common.obj(allocator, &.{
        .{ "counts", counts },
        .{ "threads", try common.arr(allocator, rows) },
    });
}

pub fn progress(allocator: Allocator, index: usize, total: usize, id: []const u8, status: []const u8) !void {
    if (@import("builtin").is_test) {
        return;
    }
    const message = try common.fmt(allocator, "[{d}/{d}] {s}: {s}\n", .{ index + 1, total, id, status });
    try writeAll(2, message);
}

pub fn terminalFailure(allocator: Allocator, code: []const u8, phase: []const u8) !Value {
    var result = try common.obj(allocator, &.{
        .{ "error", common.str(code) },
        .{ "errorType", common.str(code) },
        .{ "reason", common.str(diagnostics.reason(code)) },
        .{ "phase", common.str(phase) },
    });
    if (common.eq(phase, "arguments")) {
        try common.set(allocator, &result, "hint", common.str("Run c2c --help for usage."));
    }
    return result;
}

fn diagnosticDetails(allocator: Allocator, result: Value) ![]const u8 {
    var text = std.array_list.Managed(u8).init(allocator);
    const reason = common.stringField(result, "reason");
    if (reason.len > 0) {
        try text.appendSlice(try common.fmt(allocator, "  {s}\n", .{reason}));
    }
    const path = sourcePath(result);
    if (path.len > 0) {
        try text.appendSlice(try common.fmt(allocator, "  Source: {s}\n", .{path}));
    }
    const Field = struct {
        key: []const u8,
        label: []const u8,
    };
    for ([_]Field{
        .{ .key = "targetPath", .label = "Destination" },
        .{ .key = "sourceHome", .label = "Source home" },
        .{ .key = "targetHome", .label = "Destination home" },
        .{ .key = "manifest", .label = "Manifest" },
    }) |field| {
        const value = common.stringField(result, field.key);
        if (value.len > 0) {
            try text.appendSlice(try common.fmt(allocator, "  {s}: {s}\n", .{ field.label, value }));
        }
    }
    const hint = common.stringField(result, "hint");
    if (hint.len > 0) {
        try text.appendSlice(try common.fmt(allocator, "  {s}\n", .{hint}));
    }
    return text.toOwnedSlice();
}

pub fn renderFailure(allocator: Allocator, result: Value) ![]const u8 {
    return common.fmt(allocator, "c2c: {s}\n{s}", .{ common.stringField(result, "errorType"), try diagnosticDetails(allocator, result) });
}

pub fn renderRow(allocator: Allocator, row: Value) ![]const u8 {
    const status = common.stringField(row, "status");
    const diagnostic_statuses = [_][]const u8{
        "error",
        "invalid",
        "missing",
        "collision",
        "pending-registration",
        "registering",
    };
    if (!common.oneOf(status, &diagnostic_statuses)) {
        const session_id = common.stringField(row, "sessionId");
        const label = if (session_id.len > 0) session_id else common.stringField(row, "title");
        return common.fmt(allocator, "{s}  {s}  {s}\n", .{ common.stringField(row, "sourceThreadId"), status, label });
    }
    var details = try common.clone(allocator, row);
    const error_type = common.stringField(row, "errorType");
    const code = if (error_type.len > 0) error_type else common.stringField(row, "registrationError");
    if (common.stringField(details, "reason").len == 0) {
        const reason = if (code.len > 0)
            diagnostics.reason(code)
        else if (common.eq(status, "collision"))
            "The destination already exists. It was preserved; c2c will not overwrite it."
        else if (common.eq(status, "missing"))
            "The installed destination is missing. Check its path and the destination app."
        else if (common.eq(status, "invalid"))
            "The destination failed validation. Inspect it before retrying."
        else if (common.oneOf(status, &.{ "pending-registration", "registering" }))
            "Native registration is unfinished. Check the destination CLI, then retry the same migration."
        else
            diagnostics.reason("");
        try common.set(allocator, &details, "reason", common.str(reason));
    }
    const suffix = if (code.len > 0) try common.fmt(allocator, " ({s})", .{code}) else "";
    return common.fmt(allocator, "{s}  {s}{s}\n{s}", .{
        common.stringField(row, "sourceThreadId"),
        status,
        suffix,
        try diagnosticDetails(allocator, details),
    });
}

pub fn printResult(allocator: Allocator, options: Options, result: Value) !void {
    if (options.json_output) {
        try writeAll(1, try common.json(allocator, result));
        try writeAll(1, "\n");
        return;
    }
    if (common.get(result, "error") != .null) {
        try writeAll(2, try renderFailure(allocator, result));
        return;
    }
    for (common.list(common.get(result, "threads"))) |row| {
        try writeAll(1, try renderRow(allocator, row));
    }
    const counts = common.get(result, "counts");
    if (counts == .object) {
        var iterator = counts.object.iterator();
        while (iterator.next()) |entry| {
            const line = try common.fmt(allocator, "{d} {s}\n", .{ common.integer(entry.value_ptr.*), entry.key_ptr.* });
            try writeAll(1, line);
        }
        if (counts.object.count() == 0) {
            try writeAll(1, "No matching threads\n");
        }
    }
    const warnings = common.get(result, "warningGroups");
    if (warnings == .object) {
        var iterator = warnings.object.iterator();
        while (iterator.next()) |entry| {
            const line = try common.fmt(allocator, "Warning ({d}): {s}\n", .{ common.integer(entry.value_ptr.*), entry.key_ptr.* });
            try writeAll(1, line);
        }
    }
    const manifest_path = common.stringField(result, "manifest");
    if (manifest_path.len > 0) {
        try writeAll(1, try common.fmt(allocator, "Manifest: {s}\n", .{manifest_path}));
    }
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
