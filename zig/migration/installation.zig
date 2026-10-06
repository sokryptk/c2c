const std = @import("std");
const common = @import("../common.zig");
const Allocator = common.Allocator;
const Value = common.Value;
const Options = @import("../cli/options.zig").Options;
const journal = @import("journal.zig");
const State = journal.State;
const sources = @import("sources.zig");
const output = @import("../cli/output.zig");
const codex = @import("../codex.zig");
const opencode = @import("../opencode.zig");
const diagnostics = @import("../diagnostics.zig");
const Values = std.array_list.Managed(Value);
const Strings = std.array_list.Managed([]const u8);

fn needsRegistration(options: Options) bool {
    return options.to == .codex or options.to == .opencode;
}

fn removeIfExists(path: []const u8) !void {
    common.removeFile(path) catch |err| {
        if (err != error.FileNotFound) {
            return err;
        }
    };
}

pub fn inspect(allocator: Allocator, options: Options, record: Value) !Value {
    var result = try output.resultContext(allocator, record);
    const current = common.stringField(record, "status");
    var status: []const u8 = "not-installed";
    if (common.oneOf(current, &.{ "metadata-only", "undone", "error", "collision", "already-origin" })) {
        status = current;
    } else if (common.oneOf(current, &.{ "pending-registration", "registering" })) {
        status = "pending-registration";
    } else if (common.stringField(record, "targetPath").len > 0) {
        const target = try journal.safeTarget(allocator, options, common.stringField(record, "targetPath"));
        if (!common.exists(target)) {
            status = "missing";
        } else {
            var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch.deinit();
            const temp = scratch.allocator();
            var warnings = common.Warnings.init(temp);
            const entries = try common.readJsonl(temp, target, &warnings);
            const errors = try sources.validate(temp, options, entries);
            if (errors.len > 0) {
                status = "invalid";
                var messages = Values.init(allocator);
                for (errors) |message| {
                    try messages.append(common.str(try allocator.dupe(u8, message)));
                }
                try common.set(allocator, &result, "validationErrors", try common.arr(allocator, messages.items));
            } else if (options.to == .opencode) {
                const fingerprint = try opencode.nativeFingerprint(
                    temp,
                    options.opencode_home,
                    common.stringField(record, "sessionId"),
                );
                if (fingerprint == null) {
                    status = "missing";
                } else if (common.eq(fingerprint.?, common.stringField(record, "nativeFingerprint")) and
                    common.eq(try common.sha256File(temp, target), common.stringField(record, "sha256")))
                {
                    status = "verified";
                } else {
                    status = "continued";
                }
            } else {
                const unchanged = common.eq(try common.sha256File(temp, target), common.stringField(record, "sha256"));
                status = if (unchanged) "verified" else "continued";
            }
        }
    }
    try common.set(allocator, &result, "status", common.str(status));
    if (common.oneOf(status, &.{ "error", "pending-registration" })) {
        const code = if (common.stringField(record, "errorType").len > 0)
            common.stringField(record, "errorType")
        else
            common.stringField(record, "registrationError");
        if (code.len > 0) {
            try common.set(allocator, &result, "errorType", common.str(code));
            try common.set(allocator, &result, "reason", common.str(diagnostics.reason(code)));
        }
        const phase = if (common.eq(status, "pending-registration")) common.str("registration") else common.get(record, "phase");
        try common.set(allocator, &result, "phase", phase);
    }
    return result;
}

pub fn recover(state: *State) !void {
    var ids = Strings.init(state.allocator);
    var iterator = state.imports().object.iterator();
    while (iterator.next()) |entry| {
        try ids.append(entry.key_ptr.*);
    }
    for (ids.items) |id| {
        var record = state.record(id);
        const status = common.stringField(record, "status");
        if (common.eq(status, "undoing")) {
            const target = try journal.safeTarget(state.allocator, state.options, common.stringField(record, "targetPath"));
            const backup = try journal.safeTarget(state.allocator, state.options, common.stringField(record, "undoBackupPath"));
            var undone = common.exists(backup) and !common.exists(target);
            if (state.options.to == .opencode and common.exists(backup)) {
                const fingerprint = try opencode.nativeFingerprint(
                    state.allocator,
                    state.options.opencode_home,
                    common.stringField(record, "sessionId"),
                );
                if (fingerprint == null and common.exists(target) and common.sameFile(backup, target) and
                    common.eq(try common.sha256File(state.allocator, target), common.stringField(record, "sha256")))
                {
                    try common.removeFile(target);
                }
                if (fingerprint != null and !common.exists(target)) {
                    if (common.eq(fingerprint.?, common.stringField(record, "nativeFingerprint"))) {
                        try opencode.unregister(state.allocator, state.options.opencode_home, common.stringField(record, "sessionId"));
                    } else {
                        undone = false;
                    }
                }
                undone = !common.exists(target) and (try opencode.nativeFingerprint(
                    state.allocator,
                    state.options.opencode_home,
                    common.stringField(record, "sessionId"),
                )) == null;
            }
            if (undone and state.options.to == .codex) {
                try codex.unregister(state.allocator, state.options.codex_home, common.stringField(record, "sessionId"));
            }
            try common.set(state.allocator, &record, "status", common.str(if (undone) "undone" else "installed"));
            if (undone) {
                try common.set(state.allocator, &record, "undoneAt", try journal.now(state.allocator));
            }
            try state.put(id, record);
            try state.save();
        } else if (common.eq(status, "installing")) {
            const target = try journal.safeTarget(state.allocator, state.options, common.stringField(record, "targetPath"));
            const temporary = try journal.safeTarget(state.allocator, state.options, common.stringField(record, "installTemporary"));
            const new_status: []const u8 = if (common.sameFile(target, temporary))
                (if (needsRegistration(state.options)) "pending-registration" else "installed")
            else if (common.exists(target))
                "collision"
            else
                "staged";
            try common.set(state.allocator, &record, "status", common.str(new_status));
            try state.put(id, record);
            try state.save();
        }
        record = state.record(id);
        if (common.oneOf(common.stringField(record, "status"), &.{ "installed", "pending-registration", "staged", "collision" }) and
            common.stringField(record, "installTemporary").len > 0)
        {
            try removeIfExists(try journal.safeTarget(state.allocator, state.options, common.stringField(record, "installTemporary")));
            _ = record.object.swapRemove("installTemporary");
            try state.put(id, record);
            try state.save();
        }
    }
}

fn install(state: *State, id: []const u8) !void {
    var record = state.record(id);
    const target = try journal.safeTarget(state.allocator, state.options, common.stringField(record, "targetPath"));
    const parent = std.fs.path.dirname(target).?;
    try common.mkdirAll(parent);
    try journal.syncAncestors(parent);
    _ = try journal.safeTarget(state.allocator, state.options, target);
    if (common.exists(target)) {
        try common.set(state.allocator, &record, "status", common.str("collision"));
        try state.put(id, record);
        try state.save();
        return;
    }
    const stage = common.stringField(record, "stagePath");
    if (!journal.pathWithin(try common.canonicalPath(state.allocator, stage), state.options.output_dir) or
        (try common.stat(stage)).is_symlink or
        !common.eq(try common.sha256File(state.allocator, stage), common.stringField(record, "sha256")))
    {
        return error.StagingIntegrityFailed;
    }
    const temporary_name = try common.fmt(state.allocator, ".c2c-install-{s}.tmp", .{try journal.unique(state.allocator)});
    const temporary = try common.join(state.allocator, &.{ parent, temporary_name });
    try common.set(state.allocator, &record, "status", common.str("installing"));
    try common.set(state.allocator, &record, "installTemporary", common.str(temporary));
    try state.put(id, record);
    try state.save();
    try common.copyExclusive(state.allocator, stage, temporary);
    var collision = false;
    common.hardLink(temporary, target) catch |err| {
        if (err == error.PathAlreadyExists) {
            collision = true;
        } else {
            return err;
        }
    };
    if (!collision) {
        try common.syncDir(parent);
    }
    const status: []const u8 = if (collision)
        "collision"
    else if (needsRegistration(state.options))
        "pending-registration"
    else
        "installed";
    try common.set(state.allocator, &record, "status", common.str(status));
    try common.set(state.allocator, &record, "installedAt", try journal.now(state.allocator));
    try state.put(id, record);
    try state.save();
    try common.removeFile(temporary);
    _ = record.object.swapRemove("installTemporary");
    try state.put(id, record);
    try state.save();
}

fn completeRegistration(state: *State, id: []const u8) !void {
    if (state.options.to == .opencode) {
        return completeOpenCodeRegistration(state, id);
    }
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const allocator = scratch.allocator();
    var record = state.record(id);
    const target = try journal.safeTarget(allocator, state.options, common.stringField(record, "targetPath"));
    const stage = common.stringField(record, "stagePath");
    const expected = if (common.stringField(record, "sourceConversionSha256").len > 0)
        common.stringField(record, "sourceConversionSha256")
    else
        common.stringField(record, "sha256");
    if (!journal.pathWithin(try common.canonicalPath(allocator, stage), state.options.output_dir) or
        (try common.stat(stage)).is_symlink or
        !common.eq(try common.sha256File(allocator, stage), expected))
    {
        return error.StagingIntegrityFailed;
    }
    var warnings = common.Warnings.init(allocator);
    const staged = try common.readJsonl(allocator, stage, &warnings);
    const current_entries = try common.readJsonl(allocator, target, &warnings);
    if (!try codex.registrationMatches(allocator, staged, current_entries)) {
        return error.NativeConversationChanged;
    }
    try common.set(state.allocator, &record, "status", common.str("registering"));
    try common.set(state.allocator, &record, "sourceConversionSha256", common.str(expected));
    try state.put(id, record);
    try state.save();
    const registered = try codex.register(
        allocator,
        state.options.codex_home,
        common.stringField(record, "sessionId"),
        common.stringField(record, "title"),
    );
    const entries = try common.readJsonl(allocator, target, &warnings);
    if ((try codex.validate(allocator, entries)).len > 0 or !try codex.registrationMatches(allocator, staged, entries)) {
        return error.UnexpectedNativeRewrite;
    }
    try common.set(state.allocator, &record, "status", common.str("installed"));
    try common.set(state.allocator, &record, "registeredAt", try journal.now(state.allocator));
    try common.set(state.allocator, &record, "nativeRegistration", try common.clone(state.allocator, registered));
    try common.set(state.allocator, &record, "sha256", common.str(try common.sha256File(state.allocator, target)));
    _ = record.object.swapRemove("registrationError");
    try state.put(id, record);
    try state.save();
}

fn completeOpenCodeRegistration(state: *State, id: []const u8) !void {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const allocator = scratch.allocator();
    var record = state.record(id);
    const target = try journal.safeTarget(allocator, state.options, common.stringField(record, "targetPath"));
    const stage = common.stringField(record, "stagePath");
    const expected = common.stringField(record, "sha256");
    if (!journal.pathWithin(try common.canonicalPath(allocator, stage), state.options.output_dir) or
        (try common.stat(stage)).is_symlink or
        !common.eq(try common.sha256File(allocator, stage), expected))
    {
        return error.StagingIntegrityFailed;
    }
    if (!common.eq(try common.sha256File(allocator, target), expected)) {
        return error.NativeReceiptChanged;
    }
    var warnings = common.Warnings.init(allocator);
    const staged = try common.readJsonl(allocator, stage, &warnings);
    if (try opencode.readNative(allocator, state.options.opencode_home, common.stringField(record, "sessionId"))) |existing| {
        if (common.eq(common.stringField(record, "status"), "pending-registration")) {
            try common.set(state.allocator, &record, "status", common.str("collision"));
            try state.put(id, record);
            try state.save();
            return;
        }
        if (!try opencode.registrationMatches(allocator, staged, existing)) {
            return error.NativeConversationChanged;
        }
    }
    try common.set(state.allocator, &record, "status", common.str("registering"));
    try common.set(state.allocator, &record, "sourceConversionSha256", common.str(expected));
    try state.put(id, record);
    try state.save();
    const registration = try opencode.register(
        allocator,
        state.options.opencode_home,
        common.stringField(record, "sessionId"),
        common.stringField(record, "title"),
    );
    const native = (try opencode.readNative(allocator, state.options.opencode_home, common.stringField(record, "sessionId"))) orelse
        return error.NativeRegistrationMissing;
    if (!try opencode.registrationMatches(allocator, staged, native)) {
        return error.UnexpectedNativeRewrite;
    }
    const fingerprint = (try opencode.nativeFingerprint(
        allocator,
        state.options.opencode_home,
        common.stringField(record, "sessionId"),
    )) orelse return error.NativeRegistrationMissing;
    try common.set(state.allocator, &record, "status", common.str("installed"));
    try common.set(state.allocator, &record, "registeredAt", try journal.now(state.allocator));
    try common.set(state.allocator, &record, "nativeRegistration", try common.clone(state.allocator, registration));
    try common.set(state.allocator, &record, "nativeFingerprint", common.str(try state.allocator.dupe(u8, fingerprint)));
    _ = record.object.swapRemove("registrationError");
    try state.put(id, record);
    try state.save();
}

pub fn publish(state: *State, id: []const u8) !void {
    if (common.eq(common.stringField(state.record(id), "status"), "staged")) {
        try install(state, id);
    }
    if (common.oneOf(common.stringField(state.record(id), "status"), &.{ "pending-registration", "registering" })) {
        try completeRegistration(state, id);
    }
}

pub fn undoOne(state: *State, id: []const u8) !Value {
    const allocator = state.allocator;
    var record = state.record(id);
    var row = try output.resultContext(allocator, record);
    if (!common.eq(common.stringField(record, "status"), "installed")) {
        try common.set(allocator, &row, "status", common.str("preserved"));
        try common.set(allocator, &row, "reason", common.get(record, "status"));
        return row;
    }
    const target = try journal.safeTarget(allocator, state.options, common.stringField(record, "targetPath"));
    if (!common.exists(target)) {
        try common.set(allocator, &row, "status", common.str("missing"));
        return row;
    }
    if (!common.eq(try common.sha256File(allocator, target), common.stringField(record, "sha256"))) {
        try common.set(allocator, &row, "status", common.str("preserved"));
        try common.set(allocator, &row, "reason", common.str("continued-or-modified"));
        return row;
    }
    if (state.options.to == .opencode) {
        if (try opencode.nativeFingerprint(allocator, state.options.opencode_home, common.stringField(record, "sessionId"))) |fingerprint| {
            if (!common.eq(fingerprint, common.stringField(record, "nativeFingerprint"))) {
                try common.set(allocator, &row, "status", common.str("preserved"));
                try common.set(allocator, &row, "reason", common.str("continued-or-modified"));
                return row;
            }
        }
    }
    const parent = std.fs.path.dirname(target).?;
    const saved_backup = common.stringField(record, "undoBackupPath");
    const backup = if (saved_backup.len > 0)
        try journal.safeTarget(allocator, state.options, saved_backup)
    else backup_path: {
        const unique = try journal.unique(allocator);
        const name = try common.fmt(allocator, ".c2c-undo-{s}.retained", .{unique});
        break :backup_path try common.join(allocator, &.{ parent, name });
    };
    try common.set(allocator, &record, "status", common.str("undoing"));
    try common.set(allocator, &record, "undoBackupPath", common.str(backup));
    try state.put(id, record);
    try state.save();
    if (!common.exists(backup)) {
        try common.hardLink(target, backup);
        try common.syncDir(parent);
    }
    const before = try common.stat(target);
    const hash = try common.sha256File(allocator, target);
    const after = try common.stat(target);
    if (!common.sameFile(backup, target) or
        !common.eq(hash, common.stringField(record, "sha256")) or
        before.size != after.size or
        before.mtime_ns != after.mtime_ns)
    {
        try common.set(allocator, &record, "status", common.str("installed"));
        try state.put(id, record);
        try state.save();
        try common.set(allocator, &row, "status", common.str("preserved"));
        try common.set(allocator, &row, "reason", common.str("changed-during-undo"));
        return row;
    }
    if (state.options.to == .codex) {
        try codex.unregister(allocator, state.options.codex_home, common.stringField(record, "sessionId"));
    } else {
        if (state.options.to == .opencode) {
            try opencode.unregister(allocator, state.options.opencode_home, common.stringField(record, "sessionId"));
        }
        try common.removeFile(target);
    }
    if (common.exists(target)) {
        return error.NativeDeleteIncomplete;
    }
    try common.syncDir(parent);
    try common.set(allocator, &record, "status", common.str("undone"));
    try common.set(allocator, &record, "undoneAt", try journal.now(allocator));
    try state.put(id, record);
    try state.save();
    try common.set(allocator, &row, "status", common.str("undone"));
    try common.set(allocator, &row, "retainedPath", common.str(backup));
    return row;
}
