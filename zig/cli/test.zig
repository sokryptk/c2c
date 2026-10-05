const std = @import("std");
const H = @import("../common.zig");
const A = H.Allocator;
const V = H.Value;
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
    const a = arena.allocator();
    try std.testing.expectError(error.UnknownOption, arguments.parseOptions(a, &.{"--typo"}));
    try std.testing.expectError(error.MissingOptionValue, arguments.parseOptions(a, &.{ "--from", "--json" }));
    try std.testing.expectError(error.MissingOptionValue, arguments.parseOptions(a, &.{"--thread="}));
    try std.testing.expectError(error.UnknownProvider, arguments.parseOptions(a, &.{ "--from=unknown", "--json" }));
    const result = try reporting.terminalFailure(a, "UnknownProvider", "arguments");
    const encoded = try H.parse(a, try H.json(a, result));
    try std.testing.expectEqualStrings("UnknownProvider", H.s(encoded, "error"));
    try std.testing.expectEqualStrings("UnknownProvider", H.s(encoded, "errorType"));
    try std.testing.expectEqualStrings("arguments", H.s(encoded, "phase"));
    try std.testing.expect(std.mem.indexOf(u8, H.s(encoded, "reason"), "codex, claude, omp, or opencode") != null);
    const rendered = try reporting.renderFailure(a, encoded);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "UnknownProvider") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "c2c --help") != null);
}

test "journal verification reports registration failure and legacy source path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const record = try H.obj(a, &.{
        .{ "sourceThreadId", H.str("source-id") },                     .{ "status", H.str("pending-registration") },
        .{ "sessionId", H.str("native-id") },                          .{ "targetPath", H.str("/destination/session.jsonl") },
        .{ "registrationError", H.str("CodexNativeMigrationFailed") }, .{ "sourceStamp", try H.obj(a, &.{.{ "path", H.str("/source/conversation.jsonl") }}) },
    });
    const row = try installation.inspect(a, .{}, record);
    try std.testing.expectEqualStrings("CodexNativeMigrationFailed", H.s(row, "errorType"));
    try std.testing.expectEqualStrings("registration", H.s(row, "phase"));
    try std.testing.expectEqualStrings("/source/conversation.jsonl", H.s(row, "sourcePath"));
    const rendered = try reporting.renderRow(a, row);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "pending-registration (CodexNativeMigrationFailed)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Check that the Codex CLI runs") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Source: /source/conversation.jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Destination: /destination/session.jsonl") != null);
}

const Fixture = struct {
    a: A,
    root: []const u8,
    options: Options,
    source_path: []const u8,
    fn init(a: A) !Fixture {
        const template = try a.dupeZ(u8, "/tmp/c2c-zig-cli-XXXXXX");
        if (H.c.mkdtemp(template) == null) return error.TempDirectoryFailed;
        const root = try a.dupe(u8, template);
        const codex_home = try H.join(a, &.{ root, "codex" });
        const claude_home = try H.join(a, &.{ root, "claude" });
        const output = try H.join(a, &.{ root, "journal" });
        var options = try arguments.parseOptions(a, &.{ "codex-to-claude", "--codex-home", codex_home, "--claude-home", claude_home, "--output-dir", output });
        options.user_home = root;
        const path = try H.join(a, &.{ codex_home, "sessions", "rollout-fixture-00000000-0000-4000-8000-000000000001.jsonl" });
        try H.mkdirAll(std.fs.path.dirname(path).?);
        const fixture = Fixture{ .a = a, .root = root, .options = options, .source_path = path };
        try fixture.sourceFile(path, "00000000-0000-4000-8000-000000000001", false);
        return fixture;
    }
    fn sourceFile(self: Fixture, path: []const u8, id: []const u8, empty: bool) !void {
        const meta = try H.obj(self.a, &.{ .{ "timestamp", H.str("2026-10-01T00:00:00Z") }, .{ "type", H.str("session_meta") }, .{ "payload", try H.obj(self.a, &.{ .{ "id", H.str(id) }, .{ "cwd", H.str(self.root) }, .{ "timestamp", H.str("2026-10-01T00:00:00Z") }, .{ "history_mode", H.str("legacy") } }) } });
        const head = try H.fmt(self.a, "{s}\n", .{try H.json(self.a, meta)});
        const body = if (empty) "" else "{\"timestamp\":\"2026-10-01T00:00:01Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Synthetic migration fixture\"}]}}\n" ++
            "{\"timestamp\":\"2026-10-01T00:00:02Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"The fixture response remains in history.\"}]}}\n";
        try H.writeExclusive(path, try H.fmt(self.a, "{s}{s}", .{ head, body }));
    }
    fn action(self: Fixture, value: []const u8) !V {
        var options = self.options;
        options.action = value;
        return migration.execute(self.a, options);
    }
    fn cleanup(self: Fixture) void {
        removeTree(self.a, self.root) catch {};
    }
};

fn removeTree(a: A, root: []const u8) !void {
    for (try H.listDir(a, root)) |entry| {
        const path = try H.join(a, &.{ root, entry.name });
        if (entry.is_dir and !entry.is_symlink) try removeTree(a, path) else try H.removeFile(path);
    }
    const z = try a.dupeZ(u8, root);
    if (H.c.rmdir(z) != 0) return error.RemoveDirectoryFailed;
}

fn count(result: V, status: []const u8) i64 {
    return H.integer(H.get(H.get(result, "counts"), status));
}

test "native forward lifecycle installs verifies skips and safely undoes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try Fixture.init(a);
    defer fixture.cleanup();
    const source_hash = try H.sha256File(a, fixture.source_path);
    const installed = try fixture.action("migrate");
    try std.testing.expectEqual(@as(i64, 1), count(installed, "installed"));
    const target = H.s(H.list(H.get(installed, "threads"))[0], "targetPath");
    const original = try H.readFile(a, target);
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("verify"), "verified"));
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("migrate"), "unchanged"));
    const undone = try fixture.action("undo");
    try std.testing.expectEqual(@as(i64, 1), count(undone, "undone"));
    try std.testing.expect(!H.exists(target));
    try std.testing.expectEqualStrings(original, try H.readFile(a, H.s(H.list(H.get(undone, "threads"))[0], "retainedPath")));
    try std.testing.expectEqualStrings(source_hash, try H.sha256File(a, fixture.source_path));
}

test "native continued conversations survive reimport and undo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try Fixture.init(a);
    defer fixture.cleanup();
    const result = try fixture.action("migrate");
    const row = H.list(H.get(result, "threads"))[0];
    const target = H.s(row, "targetPath");
    const title = try H.json(a, try H.obj(a, &.{ .{ "type", H.str("custom-title") }, .{ "sessionId", H.get(row, "sessionId") }, .{ "customTitle", H.str("Renamed inside Claude") } }));
    const changed = try H.fmt(a, "{s}{s}\n", .{ try H.readFile(a, target), title });
    try H.atomicWrite(a, target, changed);
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("verify"), "continued"));
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("migrate"), "continued"));
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("undo"), "preserved"));
    try std.testing.expectEqualStrings(changed, try H.readFile(a, target));
}

test "native collision preserves an existing destination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try Fixture.init(a);
    defer fixture.cleanup();
    const thread = (try source.listThreads(a, fixture.options.codex_home))[0];
    const target = try sources.destination(a, fixture.options, thread, try sources.sessionId(a, fixture.options, thread));
    try H.mkdirAll(std.fs.path.dirname(target).?);
    try H.writeExclusive(target, "existing native chat\n");
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("migrate"), "collision"));
    _ = try fixture.action("undo");
    try std.testing.expectEqualStrings("existing native chat\n", try H.readFile(a, target));
}

test "native partial source failure still imports the other valid thread" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try Fixture.init(a);
    defer fixture.cleanup();
    const path = try H.join(a, &.{ std.fs.path.dirname(fixture.source_path).?, "rollout-invalid.jsonl" });
    try fixture.sourceFile(path, "00000000-0000-4000-8000-000000000002", true);
    try H.atomicWrite(a, path, try H.fmt(a, "{s}malformed source line\n", .{try H.readFile(a, path)}));
    const result = try fixture.action("migrate");
    try std.testing.expectEqual(@as(i64, 1), count(result, "installed"));
    try std.testing.expectEqual(@as(i64, 1), count(result, "error"));
    const encoded = try H.parse(a, try H.json(a, result));
    for (H.list(H.get(encoded, "threads"))) |row| {
        if (!H.eq(H.s(row, "status"), "error")) continue;
        try std.testing.expectEqualStrings("MalformedSourceJson", H.s(row, "errorType"));
        try std.testing.expectEqualStrings("conversion", H.s(row, "phase"));
        try std.testing.expectEqualStrings(path, H.s(row, "sourcePath"));
        try std.testing.expect(std.mem.indexOf(u8, H.s(row, "reason"), "malformed") != null);
        const rendered = try reporting.renderRow(a, row);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "error (MalformedSourceJson)") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, path) != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "Inspect the file shown") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "malformed source line") == null);
    }
    const verified = try fixture.action("verify");
    for (H.list(H.get(verified, "threads"))) |row| {
        if (!H.eq(H.s(row, "status"), "error")) continue;
        try std.testing.expectEqualStrings("MalformedSourceJson", H.s(row, "errorType"));
        try std.testing.expectEqualStrings(path, H.s(row, "sourcePath"));
        try std.testing.expect(H.s(row, "reason").len > 0);
    }
}

test "native journal recovers publication from retained ownership hardlink" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try Fixture.init(a);
    defer fixture.cleanup();
    try H.mkdirAll(fixture.options.output_dir);
    var state = try journal.loadState(a, fixture.options);
    const thread = (try source.listThreads(a, fixture.options.codex_home))[0];
    var record = try migration.stageThread(&state, thread, try H.join(a, &.{ fixture.options.output_dir, "staged", "fixture" }));
    const target = H.s(record, "targetPath");
    try H.mkdirAll(std.fs.path.dirname(target).?);
    const temporary = try H.fmt(a, "{s}.publication-fixture", .{target});
    try H.copyExclusive(a, H.s(record, "stagePath"), temporary);
    try H.hardLink(temporary, target);
    try H.set(a, &record, "status", H.str("installing"));
    try H.set(a, &record, "installTemporary", H.str(temporary));
    try state.put(thread.id, record);
    try state.save();
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("migrate"), "unchanged"));
    try std.testing.expect(!H.exists(temporary));
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("undo"), "undone"));
}

test "native engine accepts existing Python v1 migration journals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try Fixture.init(a);
    defer fixture.cleanup();
    _ = try fixture.action("migrate");
    var state = try journal.loadState(a, fixture.options);
    for ([_][]const u8{ "direction", "sourceHome", "targetHome", "from", "to" }) |key| _ = state.manifest.object.swapRemove(key);
    try state.save();
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("verify"), "verified"));
}

test "missing staged artifact is rebuilt without claiming a native destination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try Fixture.init(a);
    defer fixture.cleanup();
    try H.mkdirAll(fixture.options.output_dir);
    var state = try journal.loadState(a, fixture.options);
    const thread = (try source.listThreads(a, fixture.options.codex_home))[0];
    const record = try migration.stageThread(&state, thread, try H.join(a, &.{ fixture.options.output_dir, "staged", "missing" }));
    try state.put(thread.id, record);
    try state.save();
    try H.removeFile(H.s(record, "stagePath"));
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("migrate"), "installed"));
    try std.testing.expectEqual(@as(i64, 1), count(try fixture.action("verify"), "verified"));
}
