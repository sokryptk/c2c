const std = @import("std");
const common = @import("../common.zig");
const Allocator = common.Allocator;
const Value = common.Value;
const arguments = @import("options.zig");
const Options = arguments.Options;
const reporting = @import("output.zig");
const journal = @import("../migration/journal.zig");
const sources = @import("../migration/sources.zig");
const installation = @import("../migration/installation.zig");
const migration = @import("../migration.zig");
const source = @import("../source.zig");

test "parser errors retain machine codes and point humans to help" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.UnknownOption, arguments.parseOptions(allocator, &.{"--typo"}));
    try std.testing.expectError(error.MissingOptionValue, arguments.parseOptions(allocator, &.{ "--from", "--json" }));
    try std.testing.expectError(error.MissingOptionValue, arguments.parseOptions(allocator, &.{"--thread="}));
    try std.testing.expectError(error.UnknownProvider, arguments.parseOptions(allocator, &.{ "--from=unknown", "--json" }));
    const result = try reporting.terminalFailure(allocator, "UnknownProvider", "arguments");
    const encoded = try common.parse(allocator, try common.json(allocator, result));
    try std.testing.expectEqualStrings("UnknownProvider", common.stringField(encoded, "error"));
    try std.testing.expectEqualStrings("UnknownProvider", common.stringField(encoded, "errorType"));
    try std.testing.expectEqualStrings("arguments", common.stringField(encoded, "phase"));
    try std.testing.expect(std.mem.indexOf(u8, common.stringField(encoded, "reason"), "codex, claude, omp, or opencode") != null);
    const rendered = try reporting.renderFailure(allocator, encoded);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "UnknownProvider") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "c2c --help") != null);
}

test "journal verification reports registration failure and legacy source path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source_stamp = try common.obj(allocator, &.{
        .{ "path", common.str("/source/conversation.jsonl") },
    });
    const record = try common.obj(allocator, &.{
        .{ "sourceThreadId", common.str("source-id") },
        .{ "status", common.str("pending-registration") },
        .{ "sessionId", common.str("native-id") },
        .{ "targetPath", common.str("/destination/session.jsonl") },
        .{ "registrationError", common.str("CodexNativeMigrationFailed") },
        .{ "sourceStamp", source_stamp },
    });
    const row = try installation.inspect(allocator, .{}, record);
    try std.testing.expectEqualStrings("CodexNativeMigrationFailed", common.stringField(row, "errorType"));
    try std.testing.expectEqualStrings("registration", common.stringField(row, "phase"));
    try std.testing.expectEqualStrings("/source/conversation.jsonl", common.stringField(row, "sourcePath"));
    const rendered = try reporting.renderRow(allocator, row);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "pending-registration (CodexNativeMigrationFailed)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Check that the Codex CLI runs") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Source: /source/conversation.jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Destination: /destination/session.jsonl") != null);
}

const Fixture = struct {
    allocator: Allocator,
    root: []const u8,
    options: Options,
    source_path: []const u8,

    fn init(allocator: Allocator) !Fixture {
        const template = try allocator.dupeZ(u8, "/tmp/c2c-zig-cli-XXXXXX");
        if (common.c.mkdtemp(template) == null) {
            return error.TempDirectoryFailed;
        }
        const root = try allocator.dupe(u8, template);
        const codex_home = try common.join(allocator, &.{ root, "codex" });
        const claude_home = try common.join(allocator, &.{ root, "claude" });
        const output = try common.join(allocator, &.{ root, "journal" });
        var options = try arguments.parseOptions(allocator, &.{
            "codex-to-claude",
            "--codex-home",
            codex_home,
            "--claude-home",
            claude_home,
            "--output-dir",
            output,
        });
        options.user_home = root;
        const path = try common.join(allocator, &.{
            codex_home,
            "sessions",
            "rollout-fixture-00000000-0000-4000-8000-000000000001.jsonl",
        });
        try common.mkdirAll(std.fs.path.dirname(path).?);
        const fixture = Fixture{
            .allocator = allocator,
            .root = root,
            .options = options,
            .source_path = path,
        };
        try fixture.sourceFile(path, "00000000-0000-4000-8000-000000000001", false);
        return fixture;
    }

    fn sourceFile(self: Fixture, path: []const u8, id: []const u8, empty: bool) !void {
        const payload = try common.obj(self.allocator, &.{
            .{ "id", common.str(id) },
            .{ "cwd", common.str(self.root) },
            .{ "timestamp", common.str("2026-10-01T00:00:00Z") },
            .{ "history_mode", common.str("legacy") },
        });
        const meta = try common.obj(self.allocator, &.{
            .{ "timestamp", common.str("2026-10-01T00:00:00Z") },
            .{ "type", common.str("session_meta") },
            .{ "payload", payload },
        });
        const head = try common.fmt(self.allocator, "{s}\n", .{try common.json(self.allocator, meta)});
        const body = if (empty) "" else "{\"timestamp\":\"2026-10-01T00:00:01Z\",\"type\":\"response_item\"," ++
            "\"payload\":{\"type\":\"message\",\"role\":\"user\"," ++
            "\"content\":[{\"type\":\"input_text\",\"text\":\"Synthetic migration fixture\"}]}}\n" ++
            "{\"timestamp\":\"2026-10-01T00:00:02Z\",\"type\":\"response_item\"," ++
            "\"payload\":{\"type\":\"message\",\"role\":\"assistant\"," ++
            "\"content\":[{\"type\":\"output_text\",\"text\":\"The fixture response remains in history.\"}]}}\n";
        try common.writeExclusive(path, try common.fmt(self.allocator, "{s}{s}", .{ head, body }));
    }

    fn action(self: Fixture, value: []const u8) !Value {
        var options = self.options;
        options.action = value;
        return migration.execute(self.allocator, options);
    }

    fn cleanup(self: Fixture) void {
        removeTree(self.allocator, self.root) catch {};
    }
};

fn removeTree(allocator: Allocator, root: []const u8) !void {
    for (try common.listDir(allocator, root)) |entry| {
        const path = try common.join(allocator, &.{ root, entry.name });
        if (entry.is_dir and !entry.is_symlink) {
            try removeTree(allocator, path);
        } else {
            try common.removeFile(path);
        }
    }
    const z = try allocator.dupeZ(u8, root);
    if (common.c.rmdir(z) != 0) {
        return error.RemoveDirectoryFailed;
    }
}

fn count(result: Value, status: []const u8) i64 {
    return common.integer(common.get(common.get(result, "counts"), status));
}

test "native forward lifecycle installs verifies skips and safely undoes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try Fixture.init(allocator);
    defer fixture.cleanup();
    const source_hash = try common.sha256File(allocator, fixture.source_path);
    const installed = try fixture.action("migrate");
    try std.testing.expectEqual(@as(i64, 1), count(installed, "installed"));
    const target = common.stringField(common.list(common.get(installed, "threads"))[0], "targetPath");
    const original = try common.readFile(allocator, target);
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("verify"), "verified"));
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("migrate"), "unchanged"));
    const undone = try fixture.action("undo");
    try std.testing.expectEqual(@as(i64, 1), count(undone, "undone"));
    try std.testing.expect(!common.exists(target));
    const undone_row = common.list(common.get(undone, "threads"))[0];
    const retained_path = common.stringField(undone_row, "retainedPath");
    try std.testing.expectEqualStrings(original, try common.readFile(allocator, retained_path));
    try std.testing.expectEqualStrings(source_hash, try common.sha256File(allocator, fixture.source_path));
}

test "native continued conversations survive reimport and undo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try Fixture.init(allocator);
    defer fixture.cleanup();
    const result = try fixture.action("migrate");
    const row = common.list(common.get(result, "threads"))[0];
    const target = common.stringField(row, "targetPath");
    const title_record = try common.obj(allocator, &.{
        .{ "type", common.str("custom-title") },
        .{ "sessionId", common.get(row, "sessionId") },
        .{ "customTitle", common.str("Renamed inside Claude") },
    });
    const title = try common.json(allocator, title_record);
    const changed = try common.fmt(allocator, "{s}{s}\n", .{ try common.readFile(allocator, target), title });
    try common.atomicWrite(allocator, target, changed);
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("verify"), "continued"));
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("migrate"), "continued"));
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("undo"), "preserved"));
    try std.testing.expectEqualStrings(changed, try common.readFile(allocator, target));
}

test "native collision preserves an existing destination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try Fixture.init(allocator);
    defer fixture.cleanup();
    const thread = (try source.listThreads(allocator, fixture.options.codex_home))[0];
    const session_id = try sources.sessionId(allocator, fixture.options, thread);
    const target = try sources.destination(allocator, fixture.options, thread, session_id);
    try common.mkdirAll(std.fs.path.dirname(target).?);
    try common.writeExclusive(target, "existing native chat\n");
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("migrate"), "collision"));
    _ = try fixture.action("undo");
    try std.testing.expectEqualStrings("existing native chat\n", try common.readFile(allocator, target));
}

test "native partial source failure still imports the other valid thread" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try Fixture.init(allocator);
    defer fixture.cleanup();
    const path = try common.join(allocator, &.{ std.fs.path.dirname(fixture.source_path).?, "rollout-invalid.jsonl" });
    try fixture.sourceFile(path, "00000000-0000-4000-8000-000000000002", true);
    const original = try common.readFile(allocator, path);
    const malformed = try common.fmt(allocator, "{s}malformed source line\n", .{original});
    try common.atomicWrite(allocator, path, malformed);
    const result = try fixture.action("migrate");
    try std.testing.expectEqual(@as(i64, 1), count(result, "installed"));
    try std.testing.expectEqual(@as(i64, 1), count(result, "error"));
    const encoded = try common.parse(allocator, try common.json(allocator, result));
    for (common.list(common.get(encoded, "threads"))) |row| {
        if (!common.eq(common.stringField(row, "status"), "error")) {
            continue;
        }
        try std.testing.expectEqualStrings("MalformedSourceJson", common.stringField(row, "errorType"));
        try std.testing.expectEqualStrings("conversion", common.stringField(row, "phase"));
        try std.testing.expectEqualStrings(path, common.stringField(row, "sourcePath"));
        try std.testing.expect(std.mem.indexOf(u8, common.stringField(row, "reason"), "malformed") != null);
        const rendered = try reporting.renderRow(allocator, row);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "error (MalformedSourceJson)") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, path) != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "Inspect the file shown") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "malformed source line") == null);
    }
    const verified = try fixture.action("verify");
    for (common.list(common.get(verified, "threads"))) |row| {
        if (!common.eq(common.stringField(row, "status"), "error")) {
            continue;
        }
        try std.testing.expectEqualStrings("MalformedSourceJson", common.stringField(row, "errorType"));
        try std.testing.expectEqualStrings(path, common.stringField(row, "sourcePath"));
        try std.testing.expect(common.stringField(row, "reason").len > 0);
    }
}

test "native journal recovers publication from retained ownership hardlink" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try Fixture.init(allocator);
    defer fixture.cleanup();
    try common.mkdirAll(fixture.options.output_dir);
    var state = try journal.loadState(allocator, fixture.options);
    const thread = (try source.listThreads(allocator, fixture.options.codex_home))[0];
    const stage_path = try common.join(allocator, &.{ fixture.options.output_dir, "staged", "fixture" });
    var record = try migration.stageThread(&state, thread, stage_path);
    const target = common.stringField(record, "targetPath");
    try common.mkdirAll(std.fs.path.dirname(target).?);
    const temporary = try common.fmt(allocator, "{s}.publication-fixture", .{target});
    try common.copyExclusive(allocator, common.stringField(record, "stagePath"), temporary);
    try common.hardLink(temporary, target);
    try common.set(allocator, &record, "status", common.str("installing"));
    try common.set(allocator, &record, "installTemporary", common.str(temporary));
    try state.put(thread.id, record);
    try state.save();
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("migrate"), "unchanged"));
    try std.testing.expect(!common.exists(temporary));
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("undo"), "undone"));
}

test "native engine accepts existing Python v1 migration journals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try Fixture.init(allocator);
    defer fixture.cleanup();
    _ = try fixture.action("migrate");
    var state = try journal.loadState(allocator, fixture.options);
    for ([_][]const u8{ "direction", "sourceHome", "targetHome", "from", "to" }) |key| {
        _ = state.manifest.object.swapRemove(key);
    }
    try state.save();
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("verify"), "verified"));
}

test "missing staged artifact is rebuilt without claiming a native destination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try Fixture.init(allocator);
    defer fixture.cleanup();
    try common.mkdirAll(fixture.options.output_dir);
    var state = try journal.loadState(allocator, fixture.options);
    const thread = (try source.listThreads(allocator, fixture.options.codex_home))[0];
    const stage_path = try common.join(allocator, &.{ fixture.options.output_dir, "staged", "missing" });
    const record = try migration.stageThread(&state, thread, stage_path);
    try state.put(thread.id, record);
    try state.save();
    try common.removeFile(common.stringField(record, "stagePath"));
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("migrate"), "installed"));
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("verify"), "verified"));
}
