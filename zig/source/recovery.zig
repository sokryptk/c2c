const std = @import("std");
const H = @import("../common.zig");
const A = H.Allocator;
const V = H.Value;
const eq = H.eq;
const storage = @import("storage.zig");
const normalize = @import("normalize.zig");
const Thread = H.Thread;
const Item = H.Item;
const Records = storage.Records;
const Strings = std.array_list.Managed([]const u8);
const Values = std.array_list.Managed(V);
const Items = std.array_list.Managed(Item);
const absolute = storage.absolute;
const oneOf = normalize.oneOf;
const timestamp = normalize.timestamp;
const content = normalize.content;
const response = normalize.response;
const resolved = normalize.resolved;

pub fn recover(a: A, items: *Items, thread: Thread, warnings: *H.Warnings, end_offset: ?u64) !void {
    var tools = try ToolRecovery.init(a, items.items, thread, warnings, end_offset);
    defer tools.close();
    try recoverProjected(a, items.items, thread, warnings, &tools);
    try tools.finish(items);
}

/// Recover call/result pairs shown only as AgentMessage projections. Suppress
/// a raw wrapper only when its ID or an enclosed tool event matches a
/// structured projection.
const ToolRecovery = struct {
    const Call = struct {
        id: []const u8,
        name: []const u8,
        ordinal: i64,
        timestamp: []const u8,
        raw: ?V = null,
        output: ?V = null,
        output_ordinal: i64 = 0,
        output_timestamp: []const u8 = "",
        arena: ?*std.heap.ArenaAllocator = null,
        covered: bool = false,

        fn wraps(self: Call, event_kind: []const u8) bool {
            const name = if (std.mem.lastIndexOfScalar(u8, self.name, '.')) |index| self.name[index + 1 ..] else self.name;
            if (oneOf(name, &.{ "exec", "wait" })) return true;
            if (oneOf(name, &.{ "exec_command", "write_stdin", "shell", "shell_command" })) return std.ascii.eqlIgnoreCase(event_kind, "CommandExecution");
            if (eq(name, "view_image")) return std.ascii.eqlIgnoreCase(event_kind, "ImageView");
            if (eq(name, "apply_patch")) return std.ascii.eqlIgnoreCase(event_kind, "FileChange");
            return false;
        }

        fn close(self: *Call) void {
            if (self.arena) |arena| {
                arena.deinit();
                std.heap.page_allocator.destroy(arena);
                self.arena = null;
            }
        }
    };

    allocator: A,
    thread: Thread,
    warnings: *H.Warnings,
    projected_ids: std.StringHashMap(void),
    projected_ordinals: std.AutoHashMap(i64, []const u8),
    pending: std.array_list.Managed(Call),
    completed: std.array_list.Managed(Call),
    additions: Items,
    end_offset: ?u64,
    last_ordinal: i64,
    ambiguous_mapping: bool = false,

    fn init(a: A, items: []const Item, thread: Thread, warnings: *H.Warnings, end_offset: ?u64) !ToolRecovery {
        var self = ToolRecovery{
            .allocator = a,
            .thread = thread,
            .warnings = warnings,
            .projected_ids = std.StringHashMap(void).init(a),
            .projected_ordinals = std.AutoHashMap(i64, []const u8).init(a),
            .pending = std.array_list.Managed(Call).init(a),
            .completed = std.array_list.Managed(Call).init(a),
            .additions = Items.init(a),
            .end_offset = end_offset,
            .last_ordinal = -1,
        };
        for (items) |item| {
            self.last_ordinal = @max(self.last_ordinal, item.ordinal);
            if (eq(item.role, "tool")) {
                try self.projected_ids.put(item.id, {});
                try self.projected_ordinals.put(item.ordinal, item.id);
            }
        }
        return self;
    }

    fn close(self: *ToolRecovery) void {
        for (self.pending.items) |*call| call.close();
        for (self.completed.items) |*call| call.close();
    }

    fn emitCall(self: *ToolRecovery, call: Call) !void {
        if (call.covered) return;
        const item = (try response(self.allocator, call.raw.?, call.timestamp, call.ordinal, self.thread.id, self.warnings)).?;
        try self.additions.append(try resolved(self.allocator, item, self.thread));
        if (call.output) |output| {
            const result = (try response(self.allocator, output, call.output_timestamp, call.output_ordinal, self.thread.id, self.warnings)).?;
            try self.additions.append(try resolved(self.allocator, result, self.thread));
        }
    }

    fn flushCompleted(self: *ToolRecovery) !void {
        for (self.completed.items) |*call| {
            try self.emitCall(call.*);
            call.close();
        }
        self.completed.clearRetainingCapacity();
    }

    fn observe(self: *ToolRecovery, record: Records.Record, end_position: u64) !void {
        if (self.end_offset) |limit| {
            if (end_position > limit) return;
        } else if (record.ordinal > self.last_ordinal) return;
        const data = H.get(record.value, "payload");
        const kind = H.s(data, "type");
        if (eq(H.s(record.value, "type"), "event_msg") and eq(kind, "item_completed")) {
            if (self.projected_ordinals.get(record.ordinal)) |expected_id| {
                const event_id = H.s(H.get(data, "item"), "id");
                if (!eq(event_id, expected_id)) return;
                var exact = false;
                for (self.pending.items) |*call| {
                    if (eq(call.id, event_id)) {
                        call.covered = true;
                        exact = true;
                    }
                }
                for (self.completed.items) |*call| {
                    if (eq(call.id, event_id)) {
                        call.covered = true;
                        exact = true;
                    }
                }
                if (!exact) {
                    // Nearby events may belong to background agents. Match
                    // enclosed events only for known orchestration wrappers.
                    const event_kind = H.s(H.get(data, "item"), "type");
                    var wrappers: usize = 0;
                    for (self.pending.items) |*call| {
                        if (call.wraps(event_kind)) {
                            call.covered = true;
                            wrappers += 1;
                        }
                    }
                    for (self.completed.items) |*call| {
                        if (call.wraps(event_kind)) {
                            call.covered = true;
                            wrappers += 1;
                        }
                    }
                    if (wrappers > 1) self.ambiguous_mapping = true;
                }
            }
            return;
        }
        if (!eq(H.s(record.value, "type"), "response_item")) return;
        // Display completion can follow the response output. Retain completed
        // calls until the next call or user turn to match those late events.
        if (oneOf(kind, &.{ "function_call", "custom_tool_call" }) or
            (eq(kind, "message") and eq(H.s(data, "role"), "user"))) try self.flushCompleted();
        const call_id = H.s(data, "call_id");
        if (call_id.len == 0) return;
        if (oneOf(kind, &.{ "function_call", "custom_tool_call" })) {
            for (self.pending.items) |*existing| {
                if (eq(existing.id, call_id)) {
                    existing.covered = true;
                    self.ambiguous_mapping = true;
                    return;
                }
            }
            const covered = self.projected_ids.contains(call_id);
            const time = H.get(record.value, "timestamp");
            var call = Call{
                .id = try self.allocator.dupe(u8, call_id),
                .name = try self.allocator.dupe(u8, H.s(data, "name")),
                .ordinal = record.ordinal,
                .timestamp = if (time == .null) self.thread.updated_at else try timestamp(self.allocator, time, false),
                .covered = covered,
            };
            if (!covered) {
                const arena = try std.heap.page_allocator.create(std.heap.ArenaAllocator);
                arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                call.arena = arena;
                errdefer call.close();
                call.raw = try H.clone(arena.allocator(), data);
            }
            errdefer call.close();
            try self.pending.append(call);
        } else if (oneOf(kind, &.{ "function_call_output", "custom_tool_call_output" })) {
            for (self.pending.items, 0..) |pending, index| {
                if (!eq(pending.id, call_id)) continue;
                var call = self.pending.orderedRemove(index);
                if (call.covered) {
                    call.close();
                } else {
                    errdefer call.close();
                    const time = H.get(record.value, "timestamp");
                    call.output = try H.clone(call.arena.?.allocator(), data);
                    call.output_ordinal = record.ordinal;
                    call.output_timestamp = if (time == .null) self.thread.updated_at else try timestamp(self.allocator, time, false);
                    try self.completed.append(call);
                }
                return;
            }
        }
    }

    fn finish(self: *ToolRecovery, items: *Items) !void {
        try self.flushCompleted();
        // A call can precede the projection cursor while its result is in the
        // live tail. Keeping the call allows the later result to pair once.
        for (self.pending.items) |call| try self.emitCall(call);
        if (self.ambiguous_mapping) try self.warnings.append(try H.fmt(self.allocator, "Overlapping raw tool calls could not be assigned to projected tools; retained the authoritative display", .{}));
        try items.appendSlice(self.additions.items);
        std.mem.sort(Item, items.items, {}, struct {
            fn less(_: void, left: Item, right: Item) bool {
                return if (left.ordinal == right.ordinal) std.mem.order(u8, left.id, right.id) == .lt else left.ordinal < right.ordinal;
            }
        }.less);
    }
};

fn imageParts(a: A, value: V) ![]const V {
    var images = Values.init(a);
    for (H.list(value)) |part| {
        if (oneOf(H.s(part, "type"), &.{ "input_image", "image", "image_url" })) try images.append(part);
    }
    return images.toOwnedSlice();
}
fn localPaths(a: A, item: Item) ![]const []const u8 {
    var paths = Strings.init(a);
    for (item.attachments) |attachment| {
        if (eq(H.s(attachment, "type"), "localImage") and H.s(attachment, "path").len != 0) try paths.append(H.s(attachment, "path"));
    }
    return paths.toOwnedSlice();
}
fn eventPath(a: A, value: []const u8, cwd: []const u8) !?[]const u8 {
    var path = value;
    if (std.mem.startsWith(u8, path, "file:")) {
        if (std.mem.indexOfAny(u8, path, "?#") != null) return null;
        if (std.mem.startsWith(u8, path, "file:///")) path = path[7..] else if (std.mem.startsWith(u8, path, "file://localhost/")) path = path[16..] else if (std.mem.startsWith(u8, path, "file:/") and !std.mem.startsWith(u8, path, "file://")) path = path[5..] else return null;
        var decoded = std.array_list.Managed(u8).init(a);
        var index: usize = 0;
        while (index < path.len) : (index += 1) {
            if (path[index] == '%') {
                if (index + 2 >= path.len) return null;
                try decoded.append(std.fmt.parseInt(u8, path[index + 1 .. index + 3], 16) catch return null);
                index += 2;
            } else try decoded.append(path[index]);
        }
        path = try decoded.toOwnedSlice();
    }
    return try absolute(a, path, cwd);
}
fn eventMatches(a: A, item: Item, event: V, thread: Thread) !bool {
    if (!eq(H.s(event, "id"), item.id) or !std.ascii.eqlIgnoreCase(H.s(event, "type"), item.kind)) return false;
    var paths = Strings.init(a);
    if (eq(item.kind, "imageView")) {
        if (H.get(event, "path") != .string) return false;
        try paths.append(H.s(event, "path"));
    } else {
        for (H.list(H.get(event, "content"))) |part| {
            if (oneOf(H.s(part, "type"), &.{ "localImage", "local_image" })) {
                if (H.get(part, "path") != .string) return false;
                try paths.append(H.s(part, "path"));
            }
        }
    }
    const expected = try localPaths(a, item);
    if (paths.items.len != expected.len) return false;
    for (paths.items, expected) |path, target| {
        const normalized = (try eventPath(a, path, thread.cwd)) orelse return false;
        if (!eq(normalized, target)) return false;
    }
    return true;
}
fn mergeImages(a: A, item: *Item, images: []const V, warnings: *H.Warnings) !bool {
    var count: usize = 0;
    for (item.attachments) |attachment| {
        if (eq(H.s(attachment, "type"), "localImage") and H.s(attachment, "path").len != 0) count += 1;
    }
    if (count != images.len) return false;
    var attachments = Values.init(a);
    var image_index: usize = 0;
    for (item.attachments) |original| {
        var attachment = original;
        if (eq(H.s(attachment, "type"), "localImage") and H.s(attachment, "path").len != 0) {
            const parsed = try content(a, try H.arr(a, &.{images[image_index]}), warnings);
            image_index += 1;
            if (parsed.attachments.len != 1) return false;
            const url = H.s(parsed.attachments[0], "url");
            if (!std.mem.startsWith(u8, url, "data:image/")) return false;
            attachment = try H.clone(a, attachment);
            try H.set(a, &attachment, "url", H.str(url));
        }
        try attachments.append(attachment);
    }
    item.attachments = try attachments.toOwnedSlice();
    return true;
}

/// Mutates only returned Items. Never opens image paths or writes source stores.
pub fn recoverProjectedImages(a: A, items: []Item, thread: Thread, warnings: *H.Warnings) !void {
    try recoverProjected(a, items, thread, warnings, null);
}

fn recoverProjected(a: A, items: []Item, thread: Thread, warnings: *H.Warnings, tool_recovery: ?*ToolRecovery) !void {
    var targets = std.AutoHashMap(i64, usize).init(a);
    for (items, 0..) |item, index| {
        if (!oneOf(item.kind, &.{ "userMessage", "imageView" })) continue;
        for (item.attachments) |attachment| {
            if (eq(H.s(attachment, "type"), "localImage") and H.s(attachment, "path").len != 0) {
                try targets.put(item.ordinal, index);
                break;
            }
        }
    }
    if ((targets.count() == 0 and tool_recovery == null) or !H.exists(thread.rollout_path)) return;
    const Group = struct { candidates: std.array_list.Managed(usize), image_count: usize = 0, ambiguous: bool = false };
    var pending = std.StringHashMap(Group).init(a);
    var ambiguous = std.AutoHashMap(usize, void).init(a);
    var recovered = std.AutoHashMap(usize, void).init(a);
    var previous_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer previous_arena.deinit();
    var previous_user: ?struct { ordinal: i64, images: []const V } = null;
    var records = try Records.open(a, thread.rollout_path, 0, 0, warnings);
    defer records.close();
    while (try records.next()) |record| {
        if (tool_recovery) |tools| try tools.observe(record, records.position);
        if (targets.count() == 0) continue;
        const scratch = records.arena.allocator();
        const data = H.get(record.value, "payload");
        const kind = H.s(data, "type");
        if (eq(H.s(record.value, "type"), "response_item")) {
            if (eq(kind, "message") and eq(H.s(data, "role"), "user")) {
                var groups = pending.valueIterator();
                while (groups.next()) |group| for (group.candidates.items) |candidate| try ambiguous.put(candidate, {});
                pending.clearRetainingCapacity();
                _ = previous_arena.reset(.free_all);
                const previous = previous_arena.allocator();
                const parts = try imageParts(scratch, H.get(data, "content"));
                var saved = Values.init(previous);
                for (parts) |part| try saved.append(try H.clone(previous, part));
                previous_user = .{ .ordinal = record.ordinal, .images = try saved.toOwnedSlice() };
                continue;
            }
            previous_user = null;
            const call_id = H.s(data, "call_id");
            if (oneOf(kind, &.{ "function_call", "custom_tool_call" }) and call_id.len != 0) {
                const overlapping = pending.count() != 0;
                var groups = pending.valueIterator();
                while (groups.next()) |group| group.ambiguous = true;
                try pending.put(try a.dupe(u8, call_id), .{ .candidates = std.array_list.Managed(usize).init(a), .ambiguous = overlapping });
            } else if (oneOf(kind, &.{ "function_call_output", "custom_tool_call_output" })) {
                if (pending.fetchRemove(call_id)) |entry| {
                    const group = entry.value;
                    const parts = try imageParts(scratch, H.get(data, "output"));
                    if (!group.ambiguous and group.image_count == 1 and group.candidates.items.len == 1 and parts.len == 1 and try mergeImages(a, &items[group.candidates.items[0]], parts, warnings)) {
                        try recovered.put(group.candidates.items[0], {});
                    } else for (group.candidates.items) |candidate| try ambiguous.put(candidate, {});
                }
            }
            continue;
        }
        if (!eq(H.s(record.value, "type"), "event_msg") or !eq(kind, "item_completed")) {
            previous_user = null;
            continue;
        }
        const event = H.get(data, "item");
        const index = targets.get(record.ordinal);
        const verified = if (index) |candidate| try eventMatches(scratch, items[candidate], event, thread) else false;
        const event_kind = H.s(event, "type");
        if (std.ascii.eqlIgnoreCase(event_kind, "UserMessage")) {
            if (verified) {
                if (previous_user) |previous| {
                    if (previous.ordinal == record.ordinal - 1) {
                        if (try mergeImages(a, &items[index.?], previous.images, warnings)) try recovered.put(index.?, {}) else try ambiguous.put(index.?, {});
                    }
                }
            }
        } else if (std.ascii.eqlIgnoreCase(event_kind, "ImageView") or std.ascii.eqlIgnoreCase(event_kind, "ImageGeneration")) {
            if (pending.count() == 1) {
                var groups = pending.valueIterator();
                const group = groups.next().?;
                group.image_count += 1;
                if (verified and eq(items[index.?].kind, "imageView")) try group.candidates.append(index.?);
            } else if (verified) try ambiguous.put(index.?, {});
        }
        previous_user = null;
    }
    var groups = pending.valueIterator();
    while (groups.next()) |group| for (group.candidates.items) |candidate| try ambiguous.put(candidate, {});
    var recovered_keys = recovered.keyIterator();
    while (recovered_keys.next()) |index| _ = ambiguous.remove(index.*);
    if (ambiguous.count() != 0) try warnings.append(try H.fmt(a, "Raw image recovery was ambiguous for {d} projected item(s); kept original paths", .{ambiguous.count()}));
}
