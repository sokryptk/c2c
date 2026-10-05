const std = @import("std");
const H = @import("../common.zig");
const A = H.Allocator;
const V = H.Value;
const Options = @import("../cli/options.zig").Options;
const journal = @import("journal.zig");
const State = journal.State;
const sources = @import("sources.zig");
const output = @import("../cli/output.zig");
const codex = @import("../codex.zig");
const opencode = @import("../opencode.zig");
const diagnostics = @import("../diagnostics.zig");
const Values = std.array_list.Managed(V);
const Strings = std.array_list.Managed([]const u8);

fn needsRegistration(options: Options) bool {
    return options.to == .codex or options.to == .opencode;
}

fn removeIfExists(path: []const u8) !void {
    H.removeFile(path) catch |err| {
        if (err != error.FileNotFound) return err;
    };
}

pub fn inspect(a: A, options: Options, record: V) !V {
    var result = try output.resultContext(a, record);
    const current = H.s(record, "status");
    var status: []const u8 = "not-installed";
    if (H.oneOf(current, &.{ "metadata-only", "undone", "error", "collision", "already-origin" })) status = current else if (H.oneOf(current, &.{ "pending-registration", "registering" })) status = "pending-registration" else if (H.s(record, "targetPath").len > 0) {
        const target = try journal.safeTarget(a, options, H.s(record, "targetPath"));
        if (!H.exists(target)) status = "missing" else {
            var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch.deinit();
            const temp = scratch.allocator();
            var warnings = H.Warnings.init(temp);
            const entries = try H.readJsonl(temp, target, &warnings);
            const errors = try sources.validate(temp, options, entries);
            if (errors.len > 0) {
                status = "invalid";
                var messages = Values.init(a);
                for (errors) |message| try messages.append(H.str(try a.dupe(u8, message)));
                try H.set(a, &result, "validationErrors", try H.arr(a, messages.items));
            } else if (options.to == .opencode) {
                const fingerprint = try opencode.nativeFingerprint(temp, options.opencode_home, H.s(record, "sessionId"));
                status = if (fingerprint == null) "missing" else if (H.eq(fingerprint.?, H.s(record, "nativeFingerprint")) and H.eq(try H.sha256File(temp, target), H.s(record, "sha256"))) "verified" else "continued";
            } else status = if (H.eq(try H.sha256File(temp, target), H.s(record, "sha256"))) "verified" else "continued";
        }
    }
    try H.set(a, &result, "status", H.str(status));
    if (H.oneOf(status, &.{ "error", "pending-registration" })) {
        const code = if (H.s(record, "errorType").len > 0) H.s(record, "errorType") else H.s(record, "registrationError");
        if (code.len > 0) {
            try H.set(a, &result, "errorType", H.str(code));
            try H.set(a, &result, "reason", H.str(diagnostics.reason(code)));
        }
        try H.set(a, &result, "phase", if (H.eq(status, "pending-registration")) H.str("registration") else H.get(record, "phase"));
    }
    return result;
}

pub fn recover(state: *State) !void {
    var ids = Strings.init(state.a);
    var iterator = state.imports().object.iterator();
    while (iterator.next()) |entry| try ids.append(entry.key_ptr.*);
    for (ids.items) |id| {
        var record = state.record(id);
        const status = H.s(record, "status");
        if (H.eq(status, "undoing")) {
            const target = try journal.safeTarget(state.a, state.options, H.s(record, "targetPath"));
            const backup = try journal.safeTarget(state.a, state.options, H.s(record, "undoBackupPath"));
            var undone = H.exists(backup) and !H.exists(target);
            if (state.options.to == .opencode and H.exists(backup)) {
                const fingerprint = try opencode.nativeFingerprint(state.a, state.options.opencode_home, H.s(record, "sessionId"));
                if (fingerprint == null and H.exists(target) and H.sameFile(backup, target) and H.eq(try H.sha256File(state.a, target), H.s(record, "sha256"))) try H.removeFile(target);
                if (fingerprint != null and !H.exists(target)) {
                    if (H.eq(fingerprint.?, H.s(record, "nativeFingerprint"))) try opencode.unregister(state.a, state.options.opencode_home, H.s(record, "sessionId")) else undone = false;
                }
                undone = !H.exists(target) and (try opencode.nativeFingerprint(state.a, state.options.opencode_home, H.s(record, "sessionId"))) == null;
            }
            if (undone and state.options.to == .codex) try codex.unregister(state.a, state.options.codex_home, H.s(record, "sessionId"));
            try H.set(state.a, &record, "status", H.str(if (undone) "undone" else "installed"));
            if (undone) try H.set(state.a, &record, "undoneAt", try journal.now(state.a));
            try state.put(id, record);
            try state.save();
        } else if (H.eq(status, "installing")) {
            const target = try journal.safeTarget(state.a, state.options, H.s(record, "targetPath"));
            const temporary = try journal.safeTarget(state.a, state.options, H.s(record, "installTemporary"));
            const new_status: []const u8 = if (H.sameFile(target, temporary)) (if (needsRegistration(state.options)) "pending-registration" else "installed") else if (H.exists(target)) "collision" else "staged";
            try H.set(state.a, &record, "status", H.str(new_status));
            try state.put(id, record);
            try state.save();
        }
        record = state.record(id);
        if (H.oneOf(H.s(record, "status"), &.{ "installed", "pending-registration", "staged", "collision" }) and H.s(record, "installTemporary").len > 0) {
            try removeIfExists(try journal.safeTarget(state.a, state.options, H.s(record, "installTemporary")));
            _ = record.object.swapRemove("installTemporary");
            try state.put(id, record);
            try state.save();
        }
    }
}

fn install(state: *State, id: []const u8) !void {
    var record = state.record(id);
    const target = try journal.safeTarget(state.a, state.options, H.s(record, "targetPath"));
    const parent = std.fs.path.dirname(target).?;
    try H.mkdirAll(parent);
    try journal.syncAncestors(parent);
    _ = try journal.safeTarget(state.a, state.options, target);
    if (H.exists(target)) {
        try H.set(state.a, &record, "status", H.str("collision"));
        try state.put(id, record);
        try state.save();
        return;
    }
    const stage = H.s(record, "stagePath");
    if (!journal.pathWithin(try H.canonicalPath(state.a, stage), state.options.output_dir) or (try H.stat(stage)).is_symlink or !H.eq(try H.sha256File(state.a, stage), H.s(record, "sha256"))) return error.StagingIntegrityFailed;
    const temporary = try H.join(state.a, &.{ parent, try H.fmt(state.a, ".c2c-install-{s}.tmp", .{try journal.unique(state.a)}) });
    try H.set(state.a, &record, "status", H.str("installing"));
    try H.set(state.a, &record, "installTemporary", H.str(temporary));
    try state.put(id, record);
    try state.save();
    try H.copyExclusive(state.a, stage, temporary);
    var collision = false;
    H.hardLink(temporary, target) catch |err| {
        if (err == error.PathAlreadyExists) collision = true else return err;
    };
    if (!collision) try H.syncDir(parent);
    try H.set(state.a, &record, "status", H.str(if (collision) "collision" else if (needsRegistration(state.options)) "pending-registration" else "installed"));
    try H.set(state.a, &record, "installedAt", try journal.now(state.a));
    try state.put(id, record);
    try state.save();
    try H.removeFile(temporary);
    _ = record.object.swapRemove("installTemporary");
    try state.put(id, record);
    try state.save();
}

fn completeRegistration(state: *State, id: []const u8) !void {
    if (state.options.to == .opencode) return completeOpenCodeRegistration(state, id);
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var record = state.record(id);
    const target = try journal.safeTarget(a, state.options, H.s(record, "targetPath"));
    const stage = H.s(record, "stagePath");
    const expected = if (H.s(record, "sourceConversionSha256").len > 0) H.s(record, "sourceConversionSha256") else H.s(record, "sha256");
    if (!journal.pathWithin(try H.canonicalPath(a, stage), state.options.output_dir) or (try H.stat(stage)).is_symlink or !H.eq(try H.sha256File(a, stage), expected)) return error.StagingIntegrityFailed;
    var warnings = H.Warnings.init(a);
    const staged = try H.readJsonl(a, stage, &warnings);
    if (!try codex.registrationMatches(a, staged, try H.readJsonl(a, target, &warnings))) return error.NativeConversationChanged;
    try H.set(state.a, &record, "status", H.str("registering"));
    try H.set(state.a, &record, "sourceConversionSha256", H.str(expected));
    try state.put(id, record);
    try state.save();
    const registered = try codex.register(a, state.options.codex_home, H.s(record, "sessionId"), H.s(record, "title"));
    const entries = try H.readJsonl(a, target, &warnings);
    if ((try codex.validate(a, entries)).len > 0 or !try codex.registrationMatches(a, staged, entries)) return error.UnexpectedNativeRewrite;
    try H.set(state.a, &record, "status", H.str("installed"));
    try H.set(state.a, &record, "registeredAt", try journal.now(state.a));
    try H.set(state.a, &record, "nativeRegistration", try H.clone(state.a, registered));
    try H.set(state.a, &record, "sha256", H.str(try H.sha256File(state.a, target)));
    _ = record.object.swapRemove("registrationError");
    try state.put(id, record);
    try state.save();
}

fn completeOpenCodeRegistration(state: *State, id: []const u8) !void {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var record = state.record(id);
    const target = try journal.safeTarget(a, state.options, H.s(record, "targetPath"));
    const stage = H.s(record, "stagePath");
    const expected = H.s(record, "sha256");
    if (!journal.pathWithin(try H.canonicalPath(a, stage), state.options.output_dir) or (try H.stat(stage)).is_symlink or !H.eq(try H.sha256File(a, stage), expected)) return error.StagingIntegrityFailed;
    if (!H.eq(try H.sha256File(a, target), expected)) return error.NativeReceiptChanged;
    var warnings = H.Warnings.init(a);
    const staged = try H.readJsonl(a, stage, &warnings);
    if (try opencode.readNative(a, state.options.opencode_home, H.s(record, "sessionId"))) |existing| {
        if (H.eq(H.s(record, "status"), "pending-registration")) {
            try H.set(state.a, &record, "status", H.str("collision"));
            try state.put(id, record);
            try state.save();
            return;
        }
        if (!try opencode.registrationMatches(a, staged, existing)) return error.NativeConversationChanged;
    }
    try H.set(state.a, &record, "status", H.str("registering"));
    try H.set(state.a, &record, "sourceConversionSha256", H.str(expected));
    try state.put(id, record);
    try state.save();
    const registration = try opencode.register(a, state.options.opencode_home, H.s(record, "sessionId"), H.s(record, "title"));
    const native = (try opencode.readNative(a, state.options.opencode_home, H.s(record, "sessionId"))) orelse return error.NativeRegistrationMissing;
    if (!try opencode.registrationMatches(a, staged, native)) return error.UnexpectedNativeRewrite;
    const fingerprint = (try opencode.nativeFingerprint(a, state.options.opencode_home, H.s(record, "sessionId"))) orelse return error.NativeRegistrationMissing;
    try H.set(state.a, &record, "status", H.str("installed"));
    try H.set(state.a, &record, "registeredAt", try journal.now(state.a));
    try H.set(state.a, &record, "nativeRegistration", try H.clone(state.a, registration));
    try H.set(state.a, &record, "nativeFingerprint", H.str(try state.a.dupe(u8, fingerprint)));
    _ = record.object.swapRemove("registrationError");
    try state.put(id, record);
    try state.save();
}

pub fn publish(state: *State, id: []const u8) !void {
    if (H.eq(H.s(state.record(id), "status"), "staged")) try install(state, id);
    if (H.oneOf(H.s(state.record(id), "status"), &.{ "pending-registration", "registering" })) try completeRegistration(state, id);
}

pub fn undoOne(state: *State, id: []const u8) !V {
    const a = state.a;
    var record = state.record(id);
    var row = try output.resultContext(a, record);
    if (!H.eq(H.s(record, "status"), "installed")) {
        try H.set(a, &row, "status", H.str("preserved"));
        try H.set(a, &row, "reason", H.get(record, "status"));
        return row;
    }
    const target = try journal.safeTarget(a, state.options, H.s(record, "targetPath"));
    if (!H.exists(target)) {
        try H.set(a, &row, "status", H.str("missing"));
        return row;
    }
    if (!H.eq(try H.sha256File(a, target), H.s(record, "sha256"))) {
        try H.set(a, &row, "status", H.str("preserved"));
        try H.set(a, &row, "reason", H.str("continued-or-modified"));
        return row;
    }
    if (state.options.to == .opencode) {
        if (try opencode.nativeFingerprint(a, state.options.opencode_home, H.s(record, "sessionId"))) |fingerprint| {
            if (!H.eq(fingerprint, H.s(record, "nativeFingerprint"))) {
                try H.set(a, &row, "status", H.str("preserved"));
                try H.set(a, &row, "reason", H.str("continued-or-modified"));
                return row;
            }
        }
    }
    const parent = std.fs.path.dirname(target).?;
    const backup = if (H.s(record, "undoBackupPath").len > 0) try journal.safeTarget(a, state.options, H.s(record, "undoBackupPath")) else try H.join(a, &.{ parent, try H.fmt(a, ".c2c-undo-{s}.retained", .{try journal.unique(a)}) });
    try H.set(a, &record, "status", H.str("undoing"));
    try H.set(a, &record, "undoBackupPath", H.str(backup));
    try state.put(id, record);
    try state.save();
    if (!H.exists(backup)) {
        try H.hardLink(target, backup);
        try H.syncDir(parent);
    }
    const before = try H.stat(target);
    const hash = try H.sha256File(a, target);
    const after = try H.stat(target);
    if (!H.sameFile(backup, target) or !H.eq(hash, H.s(record, "sha256")) or before.size != after.size or before.mtime_ns != after.mtime_ns) {
        try H.set(a, &record, "status", H.str("installed"));
        try state.put(id, record);
        try state.save();
        try H.set(a, &row, "status", H.str("preserved"));
        try H.set(a, &row, "reason", H.str("changed-during-undo"));
        return row;
    }
    if (state.options.to == .codex) try codex.unregister(a, state.options.codex_home, H.s(record, "sessionId")) else {
        if (state.options.to == .opencode) try opencode.unregister(a, state.options.opencode_home, H.s(record, "sessionId"));
        try H.removeFile(target);
    }
    if (H.exists(target)) return error.NativeDeleteIncomplete;
    try H.syncDir(parent);
    try H.set(a, &record, "status", H.str("undone"));
    try H.set(a, &record, "undoneAt", try journal.now(a));
    try state.put(id, record);
    try state.save();
    try H.set(a, &row, "status", H.str("undone"));
    try H.set(a, &row, "retainedPath", H.str(backup));
    return row;
}
