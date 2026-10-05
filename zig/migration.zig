const std = @import("std");
const H = @import("common.zig");
const A = H.Allocator;
const V = H.Value;
const Options = @import("cli/options.zig").Options;
const journal = @import("migration/journal.zig");
const State = journal.State;
const sources = @import("migration/sources.zig");
const installation = @import("migration/installation.zig");
const output = @import("cli/output.zig");
const Values = std.array_list.Managed(V);
const Strings = std.array_list.Managed([]const u8);

pub fn stageThread(state: *State, thread: H.Thread, run_directory: []const u8) !V {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before = try sources.sourceStamp(a, state.options, thread);
    const hash: V = if (H.b(H.get(before, "missing"))) .null else H.str(try sources.sourceHash(a, state.options, thread));
    const sid = try sources.sessionId(a, state.options, thread);
    if (state.options.to == .opencode) {
        if (!std.mem.startsWith(u8, sid, "ses_") or sid.len > 128) return error.InvalidSessionId;
        for (sid) |char| if (!std.ascii.isAlphanumeric(char) and char != '_' and char != '-') return error.InvalidSessionId;
    } else if (!H.validUuid(sid)) return error.InvalidSessionId;
    const target = try sources.destination(a, state.options, thread, sid);
    var warnings = H.Warnings.init(a);
    const conversion = try sources.convert(a, state.options, thread, target, &warnings);
    if (!try sources.equalJson(a, before, try sources.sourceStamp(a, state.options, thread))) return error.SourceChangedDuringConversion;
    if (!H.eq(sid, conversion.session_id)) return error.SessionIdentityMismatch;
    try warnings.appendSlice(conversion.warnings);
    var record = try sources.threadInfo(a, thread);
    try H.set(a, &record, "sourceStamp", before);
    try H.set(a, &record, "sourceSha256", hash);
    try H.set(a, &record, "sessionId", H.str(sid));
    var warning_values = Values.init(a);
    for (warnings.items) |message| try warning_values.append(H.str(message));
    try H.set(a, &record, "warnings", try H.arr(a, warning_values.items));
    try H.set(a, &record, "messageCount", H.num(@intCast(conversion.message_count)));
    try H.set(a, &record, "toolCount", H.num(@intCast(conversion.tool_count)));
    try H.set(a, &record, "sourceItemCount", H.num(@intCast(conversion.source_item_count)));
    if (conversion.message_count == 0) try H.set(a, &record, "status", H.str("metadata-only")) else {
        if ((try sources.validate(a, state.options, conversion.entries)).len > 0) return error.NativeValidationFailed;
        try H.mkdirAll(run_directory);
        try journal.syncAncestors(run_directory);
        const stage = try H.join(a, &.{ run_directory, try H.fmt(a, "{s}.jsonl", .{sid}) });
        try journal.writeJsonl(a, stage, conversion.entries);
        try H.syncDir(run_directory);
        try H.set(a, &record, "status", H.str("staged"));
        try H.set(a, &record, "stagePath", H.str(stage));
        try H.set(a, &record, "targetPath", H.str(target));
        try H.set(a, &record, "sha256", H.str(try H.sha256File(a, stage)));
    }
    return H.clone(state.a, record);
}

fn inventory(a: A, options: Options) !V {
    const origins = try sources.originRecords(a, options);
    const threads = try sources.listThreads(a, options, origins);
    var rows = Values.init(a);
    for (threads) |thread| {
        var row = try sources.threadInfo(a, thread);
        const original = try sources.alreadyOrigin(a, options, thread, origins);
        try H.set(a, &row, "status", H.str(if (original != null) "already-origin" else "available"));
        if (original) |id| try H.set(a, &row, "originalThreadId", H.str(id));
        try rows.append(row);
    }
    return output.summary(a, rows.items);
}

fn migrate(state: *State) !V {
    const a = state.a;
    try installation.recover(state);
    const origins = try sources.originRecords(a, state.options);
    const threads = try sources.listThreads(a, state.options, origins);
    const run_directory = try H.join(a, &.{ state.options.output_dir, "staged", try journal.unique(a) });
    var rows = Values.init(a);
    var pending = std.array_list.Managed(usize).init(a);
    var warning_groups = try H.obj(a, &.{});
    var warning_count: i64 = 0;
    for (threads, 0..) |thread, index| {
        const old = state.record(thread.id);
        var row = try H.obj(a, &.{ .{ "sourceThreadId", H.str(thread.id) }, .{ "sourcePath", H.str(thread.rollout_path) } });
        const current = H.s(old, "status");
        const missing_stage = H.eq(current, "staged") and !H.exists(H.s(old, "stagePath"));
        if (H.oneOf(current, &.{ "staged", "pending-registration", "registering" }) and !missing_stage) {
            try H.set(a, &row, "status", H.str(current));
            try H.set(a, &row, "sessionId", H.get(old, "sessionId"));
            try H.set(a, &row, "targetPath", H.get(old, "targetPath"));
            try pending.append(index);
        } else if (old != .null and !H.oneOf(current, &.{ "error", "undone", "metadata-only", "already-origin", "staged" })) {
            row = installation.inspect(a, state.options, old) catch |err| try output.failedRow(a, old, @errorName(err), "verification");
            try H.set(a, &row, "sourcePath", H.str(thread.rollout_path));
            if (H.eq(H.s(row, "status"), "verified")) try H.set(a, &row, "status", H.str("unchanged"));
            try H.set(a, &row, "sourceChanged", H.boolean(!try sources.equalJson(a, try sources.sourceStamp(a, state.options, thread), H.get(old, "sourceStamp"))));
        } else if (try sources.alreadyOrigin(a, state.options, thread, origins)) |original| {
            var record = try sources.threadInfo(a, thread);
            try H.set(a, &record, "status", H.str("already-origin"));
            try H.set(a, &record, "originalThreadId", H.str(original));
            try state.rememberUndo(old);
            try state.put(thread.id, record);
            try state.save();
            try H.set(a, &row, "status", H.str("already-origin"));
            try H.set(a, &row, "originalThreadId", H.str(original));
        } else {
            const record = stageThread(state, thread, run_directory) catch |err| blk: {
                var failed = try sources.threadInfo(a, thread);
                try output.setFailure(a, &failed, @errorName(err), "conversion");
                break :blk failed;
            };
            try state.rememberUndo(old);
            try state.put(thread.id, record);
            try state.save();
            try H.set(a, &row, "status", H.get(record, "status"));
            try H.set(a, &row, "sessionId", H.get(record, "sessionId"));
            try H.set(a, &row, "targetPath", H.get(record, "targetPath"));
            if (H.eq(H.s(record, "status"), "error")) {
                try H.set(a, &row, "errorType", H.get(record, "errorType"));
                try H.set(a, &row, "reason", H.get(record, "reason"));
                try H.set(a, &row, "phase", H.str("conversion"));
            }
            const warnings = H.list(H.get(record, "warnings"));
            try H.set(a, &row, "warningCount", H.num(@intCast(warnings.len)));
            warning_count += @intCast(warnings.len);
            for (warnings) |warning| {
                const text = H.text(warning);
                const group = text[0 .. std.mem.indexOf(u8, text, ": ") orelse text.len];
                try H.set(a, &warning_groups, group, H.num(H.integer(H.get(warning_groups, group)) + 1));
            }
            if (H.eq(H.s(record, "status"), "staged")) try pending.append(index);
        }
        try rows.append(row);
        try output.progress(a, index, threads.len, thread.id, H.s(row, "status"));
    }
    // All selected conversions are on disk before any destination is published.
    for (pending.items) |index| {
        const id = threads[index].id;
        installation.publish(state, id) catch |err| {
            const registration = H.oneOf(H.s(state.record(id), "status"), &.{ "pending-registration", "registering" });
            try output.setFailure(a, &rows.items[index], @errorName(err), if (registration) "registration" else "installation");
            if (registration) {
                var record = state.record(id);
                try H.set(a, &record, "registrationError", H.str(@errorName(err)));
                try state.put(id, record);
            }
            try output.progress(a, index, threads.len, id, "error");
            continue;
        };
        try H.set(a, &rows.items[index], "status", H.get(state.record(id), "status"));
        try output.progress(a, index, threads.len, id, H.s(rows.items[index], "status"));
    }
    var result = try output.summary(a, rows.items);
    try H.set(a, &result, "warningCount", H.num(warning_count));
    try H.set(a, &result, "warningGroups", warning_groups);
    try H.set(a, &state.manifest, "lastRun", try H.obj(a, &.{ .{ "at", try journal.now(a) }, .{ "counts", H.get(result, "counts") }, .{ "results", H.get(result, "threads") } }));
    try state.save();
    return result;
}

fn journalAction(state: *State) !V {
    const a = state.a;
    if (!H.eq(state.options.action, "list")) try installation.recover(state);
    var ids = Strings.init(a);
    var iterator = state.imports().object.iterator();
    while (iterator.next()) |entry| if (sources.selected(state.options, entry.key_ptr.*, H.s(entry.value_ptr.*, "cwd"))) try ids.append(entry.key_ptr.*);
    var rows = Values.init(a);
    for (ids.items) |id| {
        const record = state.record(id);
        const row = (if (H.eq(state.options.action, "undo")) installation.undoOne(state, id) else if (H.eq(state.options.action, "verify")) installation.inspect(a, state.options, record) else H.clone(a, record)) catch |err| try output.failedRow(a, record, @errorName(err), state.options.action);
        try rows.append(row);
    }
    return output.summary(a, rows.items);
}

pub fn execute(a: A, options: Options) !V {
    if (H.eq(options.action, "inventory")) {
        var result = try inventory(a, options);
        try H.set(a, &result, "direction", H.str(try options.direction(a)));
        return result;
    }
    try H.mkdirAll(options.output_dir);
    try journal.syncAncestors(options.output_dir);
    const root_z = try a.dupeZ(u8, options.output_dir);
    if (H.c.chmod(root_z, @as(c_uint, 0o700)) != 0) return error.PrivateDirectoryFailed;
    var lock = try H.lock(a, try H.join(a, &.{ options.output_dir, ".lock" }));
    defer lock.close();
    var state = try journal.loadState(a, options);
    var result = if (H.eq(options.action, "migrate")) try migrate(&state) else try journalAction(&state);
    try H.set(a, &result, "manifest", H.str(state.path));
    try H.set(a, &result, "direction", H.str(try options.direction(a)));
    return result;
}
