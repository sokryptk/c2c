const std = @import("std");
const common = @import("common.zig");
const source = @import("source.zig");
const sqlite = @cImport({
    @cInclude("sqlite3.h");
});

const a_test = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectString = std.testing.expectEqualStrings;
const timestamp = "2026-01-01T00:00:00.000Z";
const image_one = "data:image/png;base64,Zmlyc3Q=";
const image_two = "data:image/jpeg;base64,c2Vjb25k";

const HistoryRow = struct { ordinal: i64, json: []const u8 };
const Cursor = struct { offset: usize, ordinal: i64 };

const Fixture = struct {
    allocator: common.Allocator,
    tmp: std.testing.TmpDir,
    home: []const u8,
    thread: common.Thread,

    fn init(a: common.Allocator) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
        try tmp.dir.createDirPath(std.testing.io, "sessions");
        return .{
            .allocator = a,
            .tmp = tmp,
            .home = home,
            .thread = .{
                .id = "thread-1",
                .title = "Synthetic thread",
                .cwd = "/project",
                .created_at = timestamp,
                .updated_at = timestamp,
                .rollout_path = try common.join(a, &.{ home, "sessions", "rollout.jsonl" }),
            },
        };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }

    fn rollout(self: *Fixture, data: []const u8) !void {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sessions/rollout.jsonl", .data = data });
    }

    fn records(self: *Fixture, values: []const common.Value) !void {
        var data = std.array_list.Managed(u8).init(self.allocator);
        for (values) |value| {
            try data.appendSlice(try common.json(self.allocator, value));
            try data.append('\n');
        }
        try self.rollout(data.items);
    }

    fn history(self: *Fixture, rows: []const HistoryRow, cursor: ?Cursor) !void {
        const path = try common.join(self.allocator, &.{ self.home, "thread_history_1.sqlite" });
        var db: ?*sqlite.sqlite3 = null;
        try expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_open(try self.allocator.dupeZ(u8, path), &db));
        defer _ = sqlite.sqlite3_close(db);
        try sql(
            db,
            "CREATE TABLE thread_items (thread_id TEXT, item_id TEXT, item_json TEXT, created_at_ms INTEGER, rollout_ordinal INTEGER);" ++
                "CREATE TABLE thread_history_projection_state (thread_id TEXT, next_rollout_byte_offset INTEGER, next_rollout_ordinal INTEGER);",
        );
        var statement: ?*sqlite.sqlite3_stmt = null;
        try expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_prepare_v2(db, "INSERT INTO thread_items VALUES ('thread-1', ?, ?, 1767225600123, ?)", -1, &statement, null));
        defer _ = sqlite.sqlite3_finalize(statement);
        for (rows) |row| {
            const parsed = try common.parse(self.allocator, row.json);
            const supplied_id = common.s(parsed, "id");
            const id = if (supplied_id.len != 0) supplied_id else try common.fmt(self.allocator, "item-{d}", .{row.ordinal});
            try expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_bind_text(statement, 1, id.ptr, @intCast(id.len), null));
            try expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_bind_text(statement, 2, row.json.ptr, @intCast(row.json.len), null));
            try expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_bind_int64(statement, 3, row.ordinal));
            try expectEqual(sqlite.SQLITE_DONE, sqlite.sqlite3_step(statement));
            try expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_reset(statement));
            try expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_clear_bindings(statement));
        }
        if (cursor) |value| {
            const query = try common.fmt(self.allocator, "INSERT INTO thread_history_projection_state VALUES ('thread-1', {d}, {d})", .{ value.offset, value.ordinal });
            try sql(db, try self.allocator.dupeZ(u8, query));
        }
    }
};

fn sql(db: ?*sqlite.sqlite3, query: [:0]const u8) !void {
    const result = sqlite.sqlite3_exec(db, query.ptr, null, null, null);
    if (result != sqlite.SQLITE_OK) std.debug.print("synthetic SQLite fixture failed: {s}\n", .{sqlite.sqlite3_errmsg(db)});
    try expectEqual(sqlite.SQLITE_OK, result);
}

fn imageItem(a: common.Allocator, ordinal: i64, id: []const u8, path: []const u8) !common.Item {
    const attachments = try a.alloc(common.Value, 1);
    attachments[0] = try common.obj(a, &.{ .{ "type", common.str("localImage") }, .{ "path", common.str(path) } });
    return .{
        .id = id,
        .role = "tool",
        .text = "",
        .timestamp = timestamp,
        .kind = "imageView",
        .attachments = attachments,
        .raw = try common.obj(a, &.{ .{ "type", common.str("imageView") }, .{ "path", common.str(path) } }),
        .ordinal = ordinal,
    };
}

fn record(a: common.Allocator, kind: []const u8, ordinal: i64, payload: common.Value) !common.Value {
    return common.obj(a, &.{ .{ "type", common.str(kind) }, .{ "ordinal", common.num(ordinal) }, .{ "payload", payload } });
}

fn imageCall(a: common.Allocator, ordinal: i64, id: []const u8, kind: []const u8) !common.Value {
    return record(a, "response_item", ordinal, try common.obj(a, &.{
        .{ "type", common.str(kind) }, .{ "call_id", common.str(id) }, .{ "name", common.str("view_image") },
    }));
}

fn imageEvent(a: common.Allocator, ordinal: i64, id: []const u8, path: []const u8) !common.Value {
    return record(a, "event_msg", ordinal, try common.obj(a, &.{
        .{ "type", common.str("item_completed") },
        .{ "item", try common.obj(a, &.{
            .{ "type", common.str("ImageView") }, .{ "id", common.str(id) }, .{ "path", common.str(path) },
        }) },
    }));
}

fn imageOutput(a: common.Allocator, ordinal: i64, id: []const u8, kind: []const u8, urls: []const []const u8) !common.Value {
    const parts = try a.alloc(common.Value, urls.len);
    for (urls, parts) |url, *part| part.* = try common.obj(a, &.{ .{ "type", common.str("input_image") }, .{ "image_url", common.str(url) } });
    return record(a, "response_item", ordinal, try common.obj(a, &.{
        .{ "type", common.str(kind) }, .{ "call_id", common.str(id) }, .{ "output", try common.arr(a, parts) },
    }));
}

fn hasWarning(warnings: common.Warnings, needle: []const u8) bool {
    for (warnings.items) |warning| if (std.mem.indexOf(u8, warning, needle) != null) return true;
    return false;
}

test "raw reader filters private messages and retains tools and images" {
    var arena = std.heap.ArenaAllocator.init(a_test);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    defer f.deinit();
    try f.rollout(
        \\{"type":"response_item","ordinal":0,"payload":{"type":"message","role":"system","content":[{"type":"input_text","text":"private system"}]}}
        \\{"type":"response_item","ordinal":1,"payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"private developer"}]}}
        \\{"type":"response_item","ordinal":2,"payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Look"},{"type":"input_image","image_url":"data:image/png;base64,Zmlyc3Q="}]}}
        \\{"type":"response_item","ordinal":3,"payload":{"type":"message","role":"assistant","channel":"analysis","content":[{"type":"output_text","text":"private reasoning"}]}}
        \\{"type":"response_item","ordinal":4,"payload":{"type":"function_call","call_id":"call-1","name":"shell","arguments":"{\"cmd\":\"pwd\"}"}}
        \\{"type":"response_item","ordinal":5,"payload":{"type":"function_call_output","call_id":"call-1","output":"/project"}}
        \\{"type":"response_item","ordinal":6,"payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}]}}
    );
    var warnings = common.Warnings.init(a);
    const items = try source.readItems(a, f.thread, f.home, &warnings);
    try expectEqual(@as(usize, 4), items.len);
    try expectString("user", items[0].role);
    try expectString("Look", items[0].text);
    try expectString(image_one, common.s(items[0].attachments[0], "url"));
    try expectString("shell", common.s(items[1].raw.?, "name"));
    try expectString("/project", items[2].text);
    try expectString("Done", items[3].text);
    try expectEqual(@as(i64, 6), items[3].ordinal);
}

test "projected history is authoritative sorted and followed by live tail" {
    var arena = std.heap.ArenaAllocator.init(a_test);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    defer f.deinit();
    const prefix = "{\"type\":\"response_item\",\"ordinal\":5,\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Raw duplicate\"}]}}\n";
    try f.rollout(prefix ++ "{\"type\":\"response_item\",\"ordinal\":50,\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Live tail\"}]}}\n");
    try f.history(&.{
        .{ .ordinal = 30, .json = "{\"type\":\"commandExecution\",\"id\":\"cmd\",\"command\":\"pwd\",\"aggregatedOutput\":\"/project\",\"exitCode\":0}" },
        .{ .ordinal = 6, .json = "{\"type\":\"userMessage\",\"id\":\"user-1\",\"content\":[{\"type\":\"text\",\"text\":\"Projected text\"},{\"type\":\"localImage\",\"path\":\"shots/a.png\"}]}" },
        .{ .ordinal = 10, .json = "{\"type\":\"reasoning\",\"id\":\"hidden\",\"content\":[\"private\"]}" },
        .{ .ordinal = 40, .json = "{\"type\":\"agentMessage\",\"id\":\"answer\",\"text\":\"Answer\"}" },
    }, .{ .offset = prefix.len, .ordinal = 50 });
    var warnings = common.Warnings.init(a);
    const items = try source.readItems(a, f.thread, f.home, &warnings);
    try expectEqual(@as(usize, 4), items.len);
    for ([_]i64{ 6, 30, 40, 50 }, items) |ordinal, item| try expectEqual(ordinal, item.ordinal);
    try expectString("Projected text", items[0].text);
    try expectString("/project/shots/a.png", common.s(items[0].attachments[0], "path"));
    try expectString("2026-01-01T00:00:00.123Z", items[0].timestamp);
    try expectString("/project", items[1].text);
    try expectString("Live tail", items[3].text);
}

test "projected tool display text supplements arbitrary raw tool pairs unchanged" {
    for ([_][3][]const u8{
        .{ "function_call", "function_call_output", "arguments" },
        .{ "custom_tool_call", "custom_tool_call_output", "input" },
    }) |kinds| {
        var arena = std.heap.ArenaAllocator.init(a_test);
        defer arena.deinit();
        const a = arena.allocator();
        var f = try Fixture.init(a);
        defer f.deinit();
        try f.records(&.{
            try record(a, "response_item", 0, try common.obj(a, &.{
                .{ "type", common.str(kinds[0]) },        .{ "call_id", common.str("lookup-1") },
                .{ "name", common.str("lookup_record") }, .{ kinds[2], common.str("{\"record_id\":42}") },
            })),
            try record(a, "response_item", 1, try common.obj(a, &.{
                .{ "type", common.str(kinds[1]) }, .{ "call_id", common.str("lookup-1") }, .{ "output", common.str("Found record 42") },
            })),
            try common.parse(a,
                \\{"type":"event_msg","ordinal":2,"payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"tool-display-1","content":[{"type":"Text","text":"Historical tool display"}]}}}
            ),
        });
        const data = try f.tmp.dir.readFileAlloc(std.testing.io, "sessions/rollout.jsonl", a, .unlimited);
        try f.history(&.{.{ .ordinal = 2, .json = "{\"type\":\"agentMessage\",\"id\":\"tool-display-1\",\"text\":\"Historical tool display\"}" }}, .{ .offset = data.len, .ordinal = 3 });
        var warnings = common.Warnings.init(a);
        const items = try source.readItems(a, f.thread, f.home, &warnings);
        try expectEqual(@as(usize, 3), items.len);
        try expectString(kinds[0], items[0].kind);
        try expectString("lookup-1", common.s(items[0].raw.?, "call_id"));
        try expectString("lookup_record", common.s(items[0].raw.?, "name"));
        try expectString("{\"record_id\":42}", common.s(items[0].raw.?, kinds[2]));
        try expectString(kinds[1], items[1].kind);
        try expectString("lookup-1", common.s(items[1].raw.?, "call_id"));
        try expectString("Found record 42", items[1].text);
        try expectString("agentMessage", items[2].kind);
        try expectString("Historical tool display", items[2].text);
        try expectString("tool-display-1", items[2].id);
        for (items, 0..) |item, ordinal| try expectEqual(@as(i64, @intCast(ordinal)), item.ordinal);
    }
}

test "mapped projected command suppresses duplicate raw call and output" {
    var arena = std.heap.ArenaAllocator.init(a_test);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    defer f.deinit();
    const data =
        \\{"type":"response_item","ordinal":0,"payload":{"type":"function_call","call_id":"shell-1","name":"shell","arguments":"{\"command\":\"pwd\"}"}}
        \\{"type":"response_item","ordinal":1,"payload":{"type":"function_call_output","call_id":"shell-1","output":"/project"}}
        \\{"type":"event_msg","ordinal":2,"payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"shell-1","command":["pwd"],"aggregated_output":"/project"}}}
    ;
    try f.rollout(data);
    try f.history(&.{.{ .ordinal = 2, .json = "{\"type\":\"commandExecution\",\"id\":\"shell-1\",\"command\":\"pwd\",\"aggregatedOutput\":\"/project\",\"exitCode\":0}" }}, .{ .offset = data.len, .ordinal = 3 });
    var warnings = common.Warnings.init(a);
    const items = try source.readItems(a, f.thread, f.home, &warnings);
    try expectEqual(@as(usize, 1), items.len);
    try expectString("commandExecution", items[0].kind);
    try expectString("shell-1", items[0].id);
    try expectString("/project", items[0].text);
}

test "mapped inner command suppresses differently identified outer exec wrapper" {
    var arena = std.heap.ArenaAllocator.init(a_test);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    defer f.deinit();
    const data =
        \\{"type":"response_item","ordinal":0,"payload":{"type":"custom_tool_call","call_id":"outer-exec-1","name":"functions.exec","input":"text(await tools.exec_command({cmd:'pwd'}));"}}
        \\{"type":"event_msg","ordinal":1,"payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"inner-command-1","command":["pwd"],"aggregated_output":"/project"}}}
        \\{"type":"response_item","ordinal":2,"payload":{"type":"custom_tool_call_output","call_id":"outer-exec-1","output":"/project"}}
    ;
    try f.rollout(data);
    try f.history(&.{.{ .ordinal = 1, .json = "{\"type\":\"commandExecution\",\"id\":\"inner-command-1\",\"command\":\"pwd\",\"aggregatedOutput\":\"/project\",\"exitCode\":0}" }}, .{ .offset = data.len, .ordinal = 3 });
    var warnings = common.Warnings.init(a);
    const items = try source.readItems(a, f.thread, f.home, &warnings);
    try expectEqual(@as(usize, 1), items.len);
    try expectString("commandExecution", items[0].kind);
    try expectString("inner-command-1", items[0].id);
    try expectString("/project", items[0].text);
}

test "mapped command completed after wrapper output and token count suppresses raw duplicates" {
    var arena = std.heap.ArenaAllocator.init(a_test);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    defer f.deinit();
    const data =
        \\{"type":"response_item","ordinal":0,"payload":{"type":"custom_tool_call","call_id":"outer-exec-1","name":"functions.exec","input":"text(await tools.exec_command({cmd:'pwd'}));"}}
        \\{"type":"token_usage_record","ordinal":1,"payload":{"total_tokens":20}}
        \\{"type":"response_item","ordinal":2,"payload":{"type":"custom_tool_call_output","call_id":"outer-exec-1","output":"/project"}}
        \\{"type":"event_msg","ordinal":3,"payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":20}}}}
        \\{"type":"event_msg","ordinal":4,"payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"inner-command-1","command":["pwd"],"aggregated_output":"/project"}}}
    ;
    try f.rollout(data);
    try f.history(&.{.{ .ordinal = 4, .json = "{\"type\":\"commandExecution\",\"id\":\"inner-command-1\",\"command\":\"pwd\",\"aggregatedOutput\":\"/project\",\"exitCode\":0}" }}, .{ .offset = data.len, .ordinal = 5 });
    var warnings = common.Warnings.init(a);
    const items = try source.readItems(a, f.thread, f.home, &warnings);
    try expectEqual(@as(usize, 1), items.len);
    try expectString("commandExecution", items[0].kind);
    try expectString("inner-command-1", items[0].id);
    try expectString("/project", items[0].text);
    try expectString("pwd", common.s(items[0].raw.?, "command"));
    try expectString("/project", common.s(items[0].raw.?, "aggregatedOutput"));
    try expectEqual(@as(i64, 4), items[0].ordinal);
}

test "unrelated projected command cannot suppress an arbitrary completed function call" {
    var arena = std.heap.ArenaAllocator.init(a_test);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    defer f.deinit();
    const data =
        \\{"type":"response_item","ordinal":0,"payload":{"type":"function_call","call_id":"inspect-1","name":"inspect","arguments":"{\"record_id\":42}"}}
        \\{"type":"event_msg","ordinal":1,"payload":{"type":"item_completed","item":{"type":"SubAgentActivity","id":"agent-activity-1"}}}
        \\{"type":"response_item","ordinal":2,"payload":{"type":"function_call_output","call_id":"inspect-1","output":"Inspection completed"}}
        \\{"type":"event_msg","ordinal":3,"payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":20}}}}
        \\{"type":"event_msg","ordinal":4,"payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"unrelated-command-1","command":["pwd"],"aggregated_output":"/project"}}}
    ;
    try f.rollout(data);
    try f.history(&.{.{ .ordinal = 4, .json = "{\"type\":\"commandExecution\",\"id\":\"unrelated-command-1\",\"command\":\"pwd\",\"aggregatedOutput\":\"/project\",\"exitCode\":0}" }}, .{ .offset = data.len, .ordinal = 5 });
    var warnings = common.Warnings.init(a);
    const items = try source.readItems(a, f.thread, f.home, &warnings);
    try expectEqual(@as(usize, 3), items.len);
    try expectString("function_call", items[0].kind);
    try expectString("inspect-1", common.s(items[0].raw.?, "call_id"));
    try expectString("inspect", common.s(items[0].raw.?, "name"));
    try expectString("{\"record_id\":42}", common.s(items[0].raw.?, "arguments"));
    try expectString("function_call_output", items[1].kind);
    try expectString("inspect-1", common.s(items[1].raw.?, "call_id"));
    try expectString("Inspection completed", items[1].text);
    try expectString("commandExecution", items[2].kind);
    try expectString("unrelated-command-1", items[2].id);
    try expectString("/project", items[2].text);
    for ([_]i64{ 0, 2, 4 }, items) |ordinal, item| try expectEqual(ordinal, item.ordinal);
}

test "live tail output completes a supplemented pre cursor call exactly once" {
    var arena = std.heap.ArenaAllocator.init(a_test);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    defer f.deinit();
    const prefix =
        \\{"type":"response_item","ordinal":0,"payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Raw user text"}]}}
        \\{"type":"response_item","ordinal":1,"payload":{"type":"function_call","call_id":"lookup-1","name":"lookup_record","arguments":"{\"record_id\":42}"}}
        \\
    ;
    try f.rollout(prefix ++ "{\"type\":\"response_item\",\"ordinal\":2,\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"lookup-1\",\"output\":\"Found record 42\"}}\n");
    try f.history(&.{.{ .ordinal = 0, .json = "{\"type\":\"userMessage\",\"id\":\"user-1\",\"content\":[{\"type\":\"text\",\"text\":\"Projected user text\"}]}" }}, .{ .offset = prefix.len, .ordinal = 2 });
    var warnings = common.Warnings.init(a);
    const items = try source.readItems(a, f.thread, f.home, &warnings);
    try expectEqual(@as(usize, 3), items.len);
    try expectString("Projected user text", items[0].text);
    try expectString("function_call", items[1].kind);
    try expectString("lookup-1", common.s(items[1].raw.?, "call_id"));
    try expectString("function_call_output", items[2].kind);
    try expectString("lookup-1", common.s(items[2].raw.?, "call_id"));
    try expectString("Found record 42", items[2].text);
    for (items, 0..) |item, ordinal| try expectEqual(@as(i64, @intCast(ordinal)), item.ordinal);
}

test "tool supplementation ignores malformed private content and raw display messages" {
    var arena = std.heap.ArenaAllocator.init(a_test);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    defer f.deinit();
    const data =
        \\{"type":"response_item","ordinal":0,"timestamp":"2026-01-01T00:00:00Z","payload":{"type":"message","role":"system","content":{"type":"function_call","call_id":"private-call","name":"PRIVATE SYSTEM"}}}
        \\{"type":"response_item","ordinal":1,"timestamp":"2026-01-01T00:00:00Z","payload":{"type":"message","role":"developer","content":[42,{"type":"privateInstruction","text":"PRIVATE DEVELOPER"}]}}
        \\{"type":"response_item","ordinal":2,"timestamp":"2026-01-01T00:00:00Z","payload":{"type":"message","role":"assistant","channel":"analysis","content":{"type":"output_text","text":"PRIVATE REASONING"}}}
        \\{"type":"response_item","ordinal":3,"payload":{"type":"function_call","call_id":"lookup-1","name":"lookup_record","arguments":"{\"record_id\":42}"}}
        \\{"type":"response_item","ordinal":4,"payload":{"type":"function_call_output","call_id":"lookup-1","output":"Found record 42"}}
        \\{"type":"response_item","ordinal":5,"payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Unprojected duplicate display"}]}}
    ;
    try f.rollout(data);
    try f.history(&.{.{ .ordinal = 5, .json = "{\"type\":\"agentMessage\",\"id\":\"tool-display-1\",\"text\":\"Authoritative projected display\"}" }}, .{ .offset = data.len, .ordinal = 6 });
    var warnings = common.Warnings.init(a);
    const items = try source.readItems(a, f.thread, f.home, &warnings);
    try expectEqual(@as(usize, 3), items.len);
    try expectString("function_call", items[0].kind);
    try expectString("function_call_output", items[1].kind);
    try expectString("Authoritative projected display", items[2].text);
    for (items) |item| {
        try expect(std.mem.indexOf(u8, item.text, "PRIVATE") == null);
        if (item.raw) |raw| try expect(std.mem.indexOf(u8, try common.json(a, raw), "PRIVATE") == null);
    }
    try expectEqual(@as(usize, 0), warnings.items.len);
}

test "reader warns on incomplete final JSON but rejects malformed complete records" {
    var arena = std.heap.ArenaAllocator.init(a_test);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    defer f.deinit();
    try f.rollout("{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Keep\"}]}}\n{\"type\":\"response_item\",\"payload\":");
    var warnings = common.Warnings.init(a);
    const items = try source.readItems(a, f.thread, f.home, &warnings);
    try expectEqual(@as(usize, 1), items.len);
    try expectString("Keep", items[0].text);
    try expect(warnings.items.len != 0);
    try f.rollout("{broken record}\n");
    if (source.readItems(a, f.thread, f.home, &warnings)) |_| {
        return error.TestExpectedMalformedRecordError;
    } else |_| {}
}

test "compaction retains latest context but excludes instructions and ciphertext" {
    var arena = std.heap.ArenaAllocator.init(a_test);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    defer f.deinit();
    try f.rollout(
        \\{"type":"compacted","ordinal":10,"payload":{"message":"Old"}}
        \\{"type":"compacted","ordinal":33,"timestamp":"2026-01-02T00:00:00Z","payload":{"message":"","replacement_history":[{"type":"message","role":"system","content":[{"type":"input_text","text":"Private"}]},{"type":"message","role":"user","content":[{"type":"input_text","text":"Inherited request"}]},{"type":"message","role":"assistant","channel":"summary","content":[{"type":"output_text","text":"Active summary"}]},{"type":"compaction","encrypted_content":"SECRET CIPHERTEXT"}]}}
    );
    var warnings = common.Warnings.init(a);
    const compaction = (try source.readCompaction(a, f.thread, &warnings)).?;
    try expectEqual(@as(i64, 33), compaction.ordinal);
    try expectString("Active summary", compaction.summary);
    try expectEqual(@as(usize, 1), compaction.items.len);
    try expectString("Inherited request", compaction.items[0].text);
    try expect(compaction.encrypted);
}

test "rollout metadata discovers relocated thread and parent provenance" {
    var arena = std.heap.ArenaAllocator.init(a_test);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    defer f.deinit();
    try f.rollout(
        \\{"type":"session_meta","payload":{"id":"thread-1","cwd":"/old project","timestamp":"2026-01-01T05:30:00+05:30","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-1"}}}}}
    );
    const threads = try source.listThreads(a, f.home);
    try expectEqual(@as(usize, 1), threads.len);
    try expectString("thread-1", threads[0].id);
    try expectString("parent-1", threads[0].parent_id.?);
    try expectString("/old project", threads[0].cwd);
    try expectString(timestamp, threads[0].created_at);
    try expectString(f.thread.rollout_path, threads[0].rollout_path);
}

test "discovery selects numeric latest evolving state schema without writing" {
    var arena = std.heap.ArenaAllocator.init(a_test);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    defer f.deinit();
    try f.rollout(
        \\{"type":"session_meta","payload":{"id":"thread-1"}}
    );
    const Version = struct { number: u8, title: []const u8 };
    for ([_]Version{ .{ .number = 9, .title = "Old" }, .{ .number = 10, .title = "Latest" } }) |version| {
        const path = try common.fmt(a, "{s}/state_{d}.sqlite", .{ f.home, version.number });
        var db: ?*sqlite.sqlite3 = null;
        try expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_open(try a.dupeZ(u8, path), &db));
        defer _ = sqlite.sqlite3_close(db);
        try sql(db, "CREATE TABLE threads (id TEXT, title TEXT, cwd TEXT, created_at INTEGER, updated_at INTEGER, rollout_path TEXT, source TEXT, archived INTEGER)");
        var statement: ?*sqlite.sqlite3_stmt = null;
        try expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_prepare_v2(db, "INSERT INTO threads VALUES ('thread-1', ?, '/project', 1767225600, 1767312000, ?, 'exec', 0)", -1, &statement, null));
        defer _ = sqlite.sqlite3_finalize(statement);
        try expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_bind_text(statement, 1, version.title.ptr, @intCast(version.title.len), null));
        try expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_bind_text(statement, 2, f.thread.rollout_path.ptr, @intCast(f.thread.rollout_path.len), null));
        try expectEqual(sqlite.SQLITE_DONE, sqlite.sqlite3_step(statement));
    }
    const before = try f.tmp.dir.readFileAlloc(std.testing.io, "state_10.sqlite", a, .unlimited);
    const threads = try source.listThreads(a, f.home);
    const after = try f.tmp.dir.readFileAlloc(std.testing.io, "state_10.sqlite", a, .unlimited);
    try expectEqual(@as(usize, 1), threads.len);
    try expectString("Latest", threads[0].title);
    try expectString("exec", threads[0].source);
    try expectString(timestamp, threads[0].created_at);
    try expectString("2026-01-02T00:00:00.000Z", threads[0].updated_at);
    try expectString(before, after);
}

test "discovery preserves verified Claude OMP and OpenCode import provenance" {
    for ([_][]const u8{ "claude", "omp", "opencode" }) |provider| {
        var arena = std.heap.ArenaAllocator.init(a_test);
        defer arena.deinit();
        const a = arena.allocator();
        var f = try Fixture.init(a);
        defer f.deinit();
        const entries = &.{try common.obj(a, &.{
            .{ "type", common.str("user") },
            .{ "timestamp", common.str(timestamp) },
            .{ "message", try common.obj(a, &.{ .{ "role", common.str("user") }, .{ "content", common.str("Synthetic portable request") } }) },
        })};
        const conversion = try @import("codex.zig").convert(a, f.thread, entries, .{
            .source_provider = provider,
            .source_session_id = "portable-source-session",
        });
        try f.records(conversion.entries);
        const original = try f.tmp.dir.readFileAlloc(std.testing.io, "sessions/rollout.jsonl", a, .unlimited);
        const threads = try source.listThreads(a, f.home);
        try expectEqual(@as(usize, 1), threads.len);
        try expectString("codex", threads[0].provider);
        try expectString(provider, threads[0].origin_provider.?);
        try expectString("portable-source-session", threads[0].origin_id.?);
        try expect(threads[0].unchanged_import);
        if (common.eq(provider, "claude")) {
            try expectString("portable-source-session", threads[0].original_claude_id.?);
        } else try expectEqual(@as(?[]const u8, null), threads[0].original_claude_id);
        const unchanged = try f.tmp.dir.readFileAlloc(std.testing.io, "sessions/rollout.jsonl", a, .unlimited);
        try expectString(original, unchanged);

        try f.rollout(try common.fmt(a, "{s}{s}\n", .{
            original,
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"New continuation\"}]}}",
        }));
        const continued = try source.listThreads(a, f.home);
        try expectString(provider, continued[0].origin_provider.?);
        try expectString("portable-source-session", continued[0].origin_id.?);
        try expect(!continued[0].unchanged_import);
    }
}

test "discovery does not fingerprint unrelated rollout histories" {
    var arena = std.heap.ArenaAllocator.init(a_test);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    defer f.deinit();
    try f.rollout(
        \\{"type":"session_meta","payload":{"id":"thread-1","originator":"c2c:unsupported:not-an-import"}}
        \\{malformed unread history}
    );
    const threads = try source.listThreads(a, f.home);
    try expectEqual(@as(usize, 1), threads.len);
    try expectEqual(@as(?[]const u8, null), threads[0].origin_provider);
    try expectEqual(@as(?[]const u8, null), threads[0].origin_id);
    try expect(!threads[0].unchanged_import);
}

test "projection cursor beyond rollout fails rather than losing the tail" {
    var arena = std.heap.ArenaAllocator.init(a_test);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    defer f.deinit();
    try f.rollout(
        \\{"type":"response_item","ordinal":1,"payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Keep"}]}}
    );
    try f.history(&.{.{ .ordinal = 1, .json = "{\"type\":\"userMessage\",\"content\":[{\"type\":\"text\",\"text\":\"Keep\"}]}" }}, .{ .offset = 999999, .ordinal = 2 });
    var warnings = common.Warnings.init(a);
    if (source.readItems(a, f.thread, f.home, &warnings)) |_| {
        return error.TestExpectedTruncatedRolloutError;
    } else |_| {}
}

test "image recovery keeps historical data and path despite an existing overwritten file" {
    for ([_][2][]const u8{
        .{ "function_call", "function_call_output" },
        .{ "custom_tool_call", "custom_tool_call_output" },
    }) |kinds| {
        var arena = std.heap.ArenaAllocator.init(a_test);
        defer arena.deinit();
        const a = arena.allocator();
        var f = try Fixture.init(a);
        defer f.deinit();
        f.thread.cwd = f.home;
        try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "current image.png", .data = "overwritten image" });
        const path = try common.join(a, &.{ f.home, "current image.png" });
        const uri = try common.fmt(a, "file://{s}/current%20image.png", .{f.home});
        try f.records(&.{
            try imageCall(a, 0, "call-1", kinds[0]),
            try imageEvent(a, 1, "image-1", uri),
            try record(a, "token_usage_record", 2, try common.obj(a, &.{})),
            try imageOutput(a, 3, "call-1", kinds[1], &.{image_one}),
        });
        var items = [_]common.Item{try imageItem(a, 1, "image-1", path)};
        var warnings = common.Warnings.init(a);
        try source.recoverProjectedImages(a, &items, f.thread, &warnings);
        try expectString(image_one, common.s(items[0].attachments[0], "url"));
        try expectString(path, common.s(items[0].attachments[0], "path"));
        try expectString(path, common.s(items[0].raw.?, "path"));
        try expectEqual(@as(usize, 0), warnings.items.len);
        const current = try f.tmp.dir.readFileAlloc(std.testing.io, "current image.png", a, .unlimited);
        try expectString("overwritten image", current);
    }
}

test "projected Rust user events recover multiple images in attachment order" {
    var arena = std.heap.ArenaAllocator.init(a_test);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    defer f.deinit();
    const data =
        \\{"type":"response_item","ordinal":5,"payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Compare"},{"type":"input_image","image_url":"data:image/png;base64,Zmlyc3Q="},{"type":"input_text","text":"Then this"},{"type":"input_image","image_url":"data:image/jpeg;base64,c2Vjb25k"}]}}
        \\{"type":"event_msg","ordinal":6,"payload":{"type":"item_completed","item":{"type":"UserMessage","id":"user-1","content":[{"type":"text","text":"Compare"},{"type":"local_image","path":"shots/first.png"},{"type":"local_image","path":"shots/second.jpg"}]}}}
    ;
    try f.rollout(data);
    try f.history(&.{.{ .ordinal = 6, .json = "{\"type\":\"userMessage\",\"id\":\"user-1\",\"content\":[{\"type\":\"text\",\"text\":\"Compare\"},{\"type\":\"localImage\",\"path\":\"shots/first.png\"},{\"type\":\"localImage\",\"path\":\"shots/second.jpg\"}]}" }}, .{ .offset = data.len, .ordinal = 7 });
    var warnings = common.Warnings.init(a);
    const items = try source.readItems(a, f.thread, f.home, &warnings);
    try expectEqual(@as(usize, 1), items.len);
    try expectString("Compare", items[0].text);
    try expectEqual(@as(usize, 2), items[0].attachments.len);
    try expectString(image_one, common.s(items[0].attachments[0], "url"));
    try expectString(image_two, common.s(items[0].attachments[1], "url"));
    try expectString("/project/shots/first.png", common.s(items[0].attachments[0], "path"));
    try expectString("/project/shots/second.jpg", common.s(items[0].attachments[1], "path"));
}

test "image recovery requires ordinal id path and completed call identity" {
    const Case = struct { ordinal: i64 = 1, id: []const u8 = "image-1", path: []const u8 = "shots/a.png", output_id: []const u8 = "call-1" };
    for ([_]Case{
        .{ .ordinal = 2 }, .{ .id = "different-image" }, .{ .path = "shots/different.png" }, .{ .output_id = "unrelated-call" },
    }) |case| {
        var arena = std.heap.ArenaAllocator.init(a_test);
        defer arena.deinit();
        const a = arena.allocator();
        var f = try Fixture.init(a);
        defer f.deinit();
        try f.records(&.{
            try imageCall(a, 0, "call-1", "function_call"),
            try imageEvent(a, case.ordinal, case.id, case.path),
            try imageOutput(a, 3, case.output_id, "function_call_output", &.{image_one}),
        });
        var items = [_]common.Item{try imageItem(a, 1, "image-1", "/project/shots/a.png")};
        var warnings = common.Warnings.init(a);
        try source.recoverProjectedImages(a, &items, f.thread, &warnings);
        try expect(common.get(items[0].attachments[0], "url") == .null);
        try expectString("/project/shots/a.png", common.s(items[0].attachments[0], "path"));
    }
}

test "image recovery refuses ambiguous groups and remote payloads" {
    const Case = struct { events: usize, outputs: usize, url: []const u8 = image_one };
    for ([_]Case{
        .{ .events = 2, .outputs = 1 },                                                  .{ .events = 1, .outputs = 2 }, .{ .events = 2, .outputs = 2 },
        .{ .events = 1, .outputs = 1, .url = "https://example.invalid/historical.png" },
    }) |case| {
        var arena = std.heap.ArenaAllocator.init(a_test);
        defer arena.deinit();
        const a = arena.allocator();
        var f = try Fixture.init(a);
        defer f.deinit();
        var records = std.array_list.Managed(common.Value).init(a);
        try records.append(try imageCall(a, 0, "call-1", "function_call"));
        const items = try a.alloc(common.Item, case.events);
        for (items, 0..) |*item, index| {
            const id = try common.fmt(a, "image-{d}", .{index + 1});
            const path = try common.fmt(a, "/project/{d}.png", .{index + 1});
            item.* = try imageItem(a, @intCast(index + 1), id, path);
            try records.append(try imageEvent(a, @intCast(index + 1), id, path));
        }
        const urls = try a.alloc([]const u8, case.outputs);
        for (urls) |*url| url.* = case.url;
        try records.append(try imageOutput(a, 3, "call-1", "function_call_output", urls));
        try f.records(records.items);
        var warnings = common.Warnings.init(a);
        try source.recoverProjectedImages(a, items, f.thread, &warnings);
        for (items) |item| try expect(common.get(item.attachments[0], "url") == .null);
        try expect(hasWarning(warnings, "ambiguous"));
    }
}

test "overlapping calls refuse image assignment even when outputs name the calls" {
    var arena = std.heap.ArenaAllocator.init(a_test);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    defer f.deinit();
    try f.records(&.{
        try imageCall(a, 0, "call-1", "function_call"),
        try imageEvent(a, 1, "image-1", "shots/a.png"),
        try imageCall(a, 2, "call-2", "custom_tool_call"),
        try imageEvent(a, 3, "image-2", "shots/b.png"),
        try imageOutput(a, 4, "call-1", "function_call_output", &.{image_one}),
        try imageOutput(a, 5, "call-2", "custom_tool_call_output", &.{image_two}),
    });
    var items = [_]common.Item{
        try imageItem(a, 1, "image-1", "/project/shots/a.png"),
        try imageItem(a, 3, "image-2", "/project/shots/b.png"),
    };
    var warnings = common.Warnings.init(a);
    try source.recoverProjectedImages(a, &items, f.thread, &warnings);
    for (items) |item| try expect(common.get(item.attachments[0], "url") == .null);
    try expect(hasWarning(warnings, "ambiguous"));
}

test "multiple independent image calls recover their own historical payloads" {
    var arena = std.heap.ArenaAllocator.init(a_test);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    defer f.deinit();
    try f.records(&.{
        try imageCall(a, 0, "call-1", "function_call"),
        try imageEvent(a, 1, "image-1", "file:///project/test%20image.png"),
        try imageOutput(a, 2, "call-1", "function_call_output", &.{image_one}),
        try imageCall(a, 3, "call-2", "function_call"),
        try imageEvent(a, 4, "image-2", "shots/b.png"),
        try imageOutput(a, 5, "call-2", "function_call_output", &.{image_two}),
    });
    var items = [_]common.Item{
        try imageItem(a, 1, "image-1", "/project/test image.png"),
        try imageItem(a, 4, "image-2", "/project/shots/b.png"),
    };
    var warnings = common.Warnings.init(a);
    try source.recoverProjectedImages(a, &items, f.thread, &warnings);
    try expectString(image_one, common.s(items[0].attachments[0], "url"));
    try expectString(image_two, common.s(items[1].attachments[0], "url"));
    try expectEqual(@as(usize, 0), warnings.items.len);
}
