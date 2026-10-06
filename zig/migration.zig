const std = @import("std");
const common = @import("common.zig");
const Allocator = common.Allocator;
const Value = common.Value;
const Options = @import("cli/options.zig").Options;
const journal = @import("migration/journal.zig");
const State = journal.State;
const sources = @import("migration/sources.zig");
const installation = @import("migration/installation.zig");
const output = @import("cli/output.zig");
const Values = std.array_list.Managed(Value);
const Strings = std.array_list.Managed([]const u8);

pub fn stageThread(state: *State, thread: common.Thread, run_directory: []const u8) !Value {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const before = try sources.sourceStamp(allocator, state.options, thread);
    const hash: Value = if (common.boolValue(common.get(before, "missing")))
        .null
    else
        common.str(try sources.sourceHash(allocator, state.options, thread));
    const sid = try sources.sessionId(allocator, state.options, thread);
    if (state.options.to == .opencode) {
        if (!std.mem.startsWith(u8, sid, "ses_") or sid.len > 128) {
            return error.InvalidSessionId;
        }
        for (sid) |char| {
            if (!std.ascii.isAlphanumeric(char) and char != '_' and char != '-') {
                return error.InvalidSessionId;
            }
        }
    } else if (!common.validUuid(sid)) {
        return error.InvalidSessionId;
    }
    const target = try sources.destination(allocator, state.options, thread, sid);
    var warnings = common.Warnings.init(allocator);
    const conversion = try sources.convert(allocator, state.options, thread, target, &warnings);
    const after = try sources.sourceStamp(allocator, state.options, thread);
    if (!try sources.equalJson(allocator, before, after)) {
        return error.SourceChangedDuringConversion;
    }
    if (!common.eq(sid, conversion.session_id)) {
        return error.SessionIdentityMismatch;
    }
    try warnings.appendSlice(conversion.warnings);
    var record = try sources.threadInfo(allocator, thread);
    try common.set(allocator, &record, "sourceStamp", before);
    try common.set(allocator, &record, "sourceSha256", hash);
    try common.set(allocator, &record, "sessionId", common.str(sid));
    var warning_values = Values.init(allocator);
    for (warnings.items) |message| {
        try warning_values.append(common.str(message));
    }
    try common.set(allocator, &record, "warnings", try common.arr(allocator, warning_values.items));
    try common.set(allocator, &record, "messageCount", common.num(@intCast(conversion.message_count)));
    try common.set(allocator, &record, "toolCount", common.num(@intCast(conversion.tool_count)));
    try common.set(allocator, &record, "sourceItemCount", common.num(@intCast(conversion.source_item_count)));
    if (conversion.message_count == 0) {
        try common.set(allocator, &record, "status", common.str("metadata-only"));
    } else {
        if ((try sources.validate(allocator, state.options, conversion.entries)).len > 0) {
            return error.NativeValidationFailed;
        }
        try common.mkdirAll(run_directory);
        try journal.syncAncestors(run_directory);
        const stage = try common.join(allocator, &.{ run_directory, try common.fmt(allocator, "{s}.jsonl", .{sid}) });
        try journal.writeJsonl(allocator, stage, conversion.entries);
        try common.syncDir(run_directory);
        try common.set(allocator, &record, "status", common.str("staged"));
        try common.set(allocator, &record, "stagePath", common.str(stage));
        try common.set(allocator, &record, "targetPath", common.str(target));
        try common.set(allocator, &record, "sha256", common.str(try common.sha256File(allocator, stage)));
    }
    return common.clone(state.allocator, record);
}

fn inventory(allocator: Allocator, options: Options) !Value {
    const origins = try sources.originRecords(allocator, options);
    const threads = try sources.listThreads(allocator, options, origins);
    var rows = Values.init(allocator);
    for (threads) |thread| {
        var row = try sources.threadInfo(allocator, thread);
        const original = try sources.alreadyOrigin(allocator, options, thread, origins);
        try common.set(allocator, &row, "status", common.str(if (original != null) "already-origin" else "available"));
        if (original) |id| {
            try common.set(allocator, &row, "originalThreadId", common.str(id));
        }
        try rows.append(row);
    }
    return output.summary(allocator, rows.items);
}

fn migrate(state: *State) !Value {
    const allocator = state.allocator;
    try installation.recover(state);
    const origins = try sources.originRecords(allocator, state.options);
    const threads = try sources.listThreads(allocator, state.options, origins);
    const run_directory = try common.join(allocator, &.{ state.options.output_dir, "staged", try journal.unique(allocator) });
    var rows = Values.init(allocator);
    var pending = std.array_list.Managed(usize).init(allocator);
    var warning_groups = try common.obj(allocator, &.{});
    var warning_count: i64 = 0;
    for (threads, 0..) |thread, index| {
        const old = state.record(thread.id);
        var row = try common.obj(allocator, &.{
            .{ "sourceThreadId", common.str(thread.id) },
            .{ "sourcePath", common.str(thread.rollout_path) },
        });
        const current = common.stringField(old, "status");
        const missing_stage = common.eq(current, "staged") and !common.exists(common.stringField(old, "stagePath"));
        if (common.oneOf(current, &.{ "staged", "pending-registration", "registering" }) and !missing_stage) {
            try common.set(allocator, &row, "status", common.str(current));
            try common.set(allocator, &row, "sessionId", common.get(old, "sessionId"));
            try common.set(allocator, &row, "targetPath", common.get(old, "targetPath"));
            try pending.append(index);
        } else if (old != .null and !common.oneOf(current, &.{
            "error", "undone", "metadata-only", "already-origin", "staged",
        })) {
            row = installation.inspect(allocator, state.options, old) catch |err|
                try output.failedRow(allocator, old, @errorName(err), "verification");
            try common.set(allocator, &row, "sourcePath", common.str(thread.rollout_path));
            if (common.eq(common.stringField(row, "status"), "verified")) {
                try common.set(allocator, &row, "status", common.str("unchanged"));
            }
            const current_stamp = try sources.sourceStamp(allocator, state.options, thread);
            const source_changed = !try sources.equalJson(allocator, current_stamp, common.get(old, "sourceStamp"));
            try common.set(allocator, &row, "sourceChanged", common.boolean(source_changed));
        } else if (try sources.alreadyOrigin(allocator, state.options, thread, origins)) |original| {
            var record = try sources.threadInfo(allocator, thread);
            try common.set(allocator, &record, "status", common.str("already-origin"));
            try common.set(allocator, &record, "originalThreadId", common.str(original));
            try state.rememberUndo(old);
            try state.put(thread.id, record);
            try state.save();
            try common.set(allocator, &row, "status", common.str("already-origin"));
            try common.set(allocator, &row, "originalThreadId", common.str(original));
        } else {
            const record = stageThread(state, thread, run_directory) catch |err| blk: {
                var failed = try sources.threadInfo(allocator, thread);
                try output.setFailure(allocator, &failed, @errorName(err), "conversion");
                break :blk failed;
            };
            try state.rememberUndo(old);
            try state.put(thread.id, record);
            try state.save();
            try common.set(allocator, &row, "status", common.get(record, "status"));
            try common.set(allocator, &row, "sessionId", common.get(record, "sessionId"));
            try common.set(allocator, &row, "targetPath", common.get(record, "targetPath"));
            if (common.eq(common.stringField(record, "status"), "error")) {
                try common.set(allocator, &row, "errorType", common.get(record, "errorType"));
                try common.set(allocator, &row, "reason", common.get(record, "reason"));
                try common.set(allocator, &row, "phase", common.str("conversion"));
            }
            const warnings = common.list(common.get(record, "warnings"));
            try common.set(allocator, &row, "warningCount", common.num(@intCast(warnings.len)));
            warning_count += @intCast(warnings.len);
            for (warnings) |warning| {
                const text = common.text(warning);
                const group = text[0 .. std.mem.indexOf(u8, text, ": ") orelse text.len];
                try common.set(allocator, &warning_groups, group, common.num(common.integer(common.get(warning_groups, group)) + 1));
            }
            if (common.eq(common.stringField(record, "status"), "staged")) {
                try pending.append(index);
            }
        }
        try rows.append(row);
        try output.progress(allocator, index, threads.len, thread.id, common.stringField(row, "status"));
    }
    // All selected conversions are on disk before any destination is published.
    for (pending.items) |index| {
        const id = threads[index].id;
        installation.publish(state, id) catch |err| {
            const registration = common.oneOf(common.stringField(state.record(id), "status"), &.{ "pending-registration", "registering" });
            const phase = if (registration) "registration" else "installation";
            try output.setFailure(allocator, &rows.items[index], @errorName(err), phase);
            if (registration) {
                var record = state.record(id);
                try common.set(allocator, &record, "registrationError", common.str(@errorName(err)));
                try state.put(id, record);
            }
            try output.progress(allocator, index, threads.len, id, "error");
            continue;
        };
        try common.set(allocator, &rows.items[index], "status", common.get(state.record(id), "status"));
        try output.progress(allocator, index, threads.len, id, common.stringField(rows.items[index], "status"));
    }
    var result = try output.summary(allocator, rows.items);
    try common.set(allocator, &result, "warningCount", common.num(warning_count));
    try common.set(allocator, &result, "warningGroups", warning_groups);
    const last_run = try common.obj(allocator, &.{
        .{ "at", try journal.now(allocator) },
        .{ "counts", common.get(result, "counts") },
        .{ "results", common.get(result, "threads") },
    });
    try common.set(allocator, &state.manifest, "lastRun", last_run);
    try state.save();
    return result;
}

fn journalAction(state: *State) !Value {
    const allocator = state.allocator;
    if (!common.eq(state.options.action, "list")) {
        try installation.recover(state);
    }
    var ids = Strings.init(allocator);
    var iterator = state.imports().object.iterator();
    while (iterator.next()) |entry| {
        if (sources.selected(state.options, entry.key_ptr.*, common.stringField(entry.value_ptr.*, "cwd"))) {
            try ids.append(entry.key_ptr.*);
        }
    }
    var rows = Values.init(allocator);
    for (ids.items) |id| {
        const record = state.record(id);
        const inspection = if (common.eq(state.options.action, "undo"))
            installation.undoOne(state, id)
        else if (common.eq(state.options.action, "verify"))
            installation.inspect(allocator, state.options, record)
        else
            common.clone(allocator, record);
        const row = inspection catch |err|
            try output.failedRow(allocator, record, @errorName(err), state.options.action);
        try rows.append(row);
    }
    return output.summary(allocator, rows.items);
}

pub fn execute(allocator: Allocator, options: Options) !Value {
    if (common.eq(options.action, "inventory")) {
        var result = try inventory(allocator, options);
        try common.set(allocator, &result, "direction", common.str(try options.direction(allocator)));
        return result;
    }
    try common.mkdirAll(options.output_dir);
    try journal.syncAncestors(options.output_dir);
    const root_z = try allocator.dupeZ(u8, options.output_dir);
    if (common.c.chmod(root_z, @as(c_uint, 0o700)) != 0) {
        return error.PrivateDirectoryFailed;
    }
    var lock = try common.lock(allocator, try common.join(allocator, &.{ options.output_dir, ".lock" }));
    defer lock.close();
    var state = try journal.loadState(allocator, options);
    var result = if (common.eq(options.action, "migrate")) try migrate(&state) else try journalAction(&state);
    try common.set(allocator, &result, "manifest", common.str(state.path));
    try common.set(allocator, &result, "direction", common.str(try options.direction(allocator)));
    return result;
}
