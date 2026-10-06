const std = @import("std");
const common = @import("../common.zig");
const Allocator = common.Allocator;
const Value = common.Value;
const eq = common.eq;
const storage = @import("storage.zig");
const normalize = @import("normalize.zig");
const Thread = common.Thread;
const Item = common.Item;
const Records = storage.Records;
const Items = std.array_list.Managed(Item);
const oneOf = normalize.oneOf;
const timestamp = normalize.timestamp;
const response = normalize.response;
const resolved = normalize.resolved;

/// Recover call/result pairs shown only as AgentMessage projections. Suppress
/// a raw wrapper only when its ID or an enclosed tool event matches a
/// structured projection.
pub const ToolRecovery = struct {
    const Call = struct {
        id: []const u8,
        name: []const u8,
        ordinal: i64,
        timestamp: []const u8,
        raw: ?Value = null,
        output: ?Value = null,
        output_ordinal: i64 = 0,
        output_timestamp: []const u8 = "",
        arena: ?*std.heap.ArenaAllocator = null,
        covered: bool = false,

        fn wraps(self: Call, event_kind: []const u8) bool {
            const name = if (std.mem.lastIndexOfScalar(u8, self.name, '.')) |index|
                self.name[index + 1 ..]
            else
                self.name;
            if (oneOf(name, &.{ "exec", "wait" })) {
                return true;
            }
            if (oneOf(name, &.{ "exec_command", "write_stdin", "shell", "shell_command" })) {
                return std.ascii.eqlIgnoreCase(event_kind, "CommandExecution");
            }
            if (eq(name, "view_image")) {
                return std.ascii.eqlIgnoreCase(event_kind, "ImageView");
            }
            if (eq(name, "apply_patch")) {
                return std.ascii.eqlIgnoreCase(event_kind, "FileChange");
            }
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

    allocator: Allocator,
    thread: Thread,
    warnings: *common.Warnings,
    projected_ids: std.StringHashMap(void),
    projected_ordinals: std.AutoHashMap(i64, []const u8),
    pending: std.array_list.Managed(Call),
    completed: std.array_list.Managed(Call),
    additions: Items,
    end_offset: ?u64,
    last_ordinal: i64,
    ambiguous_mapping: bool = false,

    pub fn init(
        allocator: Allocator,
        items: []const Item,
        thread: Thread,
        warnings: *common.Warnings,
        end_offset: ?u64,
    ) !ToolRecovery {
        var self = ToolRecovery{
            .allocator = allocator,
            .thread = thread,
            .warnings = warnings,
            .projected_ids = std.StringHashMap(void).init(allocator),
            .projected_ordinals = std.AutoHashMap(i64, []const u8).init(allocator),
            .pending = std.array_list.Managed(Call).init(allocator),
            .completed = std.array_list.Managed(Call).init(allocator),
            .additions = Items.init(allocator),
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

    pub fn close(self: *ToolRecovery) void {
        for (self.pending.items) |*call| {
            call.close();
        }
        for (self.completed.items) |*call| {
            call.close();
        }
    }

    fn emitCall(self: *ToolRecovery, call: Call) !void {
        if (call.covered) {
            return;
        }
        const normalized_call = try response(
            self.allocator,
            call.raw.?,
            call.timestamp,
            call.ordinal,
            self.thread.id,
            self.warnings,
        );
        const item = try resolved(self.allocator, normalized_call.?, self.thread);
        try self.additions.append(item);
        if (call.output) |output| {
            const normalized_output = try response(
                self.allocator,
                output,
                call.output_timestamp,
                call.output_ordinal,
                self.thread.id,
                self.warnings,
            );
            const result = try resolved(self.allocator, normalized_output.?, self.thread);
            try self.additions.append(result);
        }
    }

    fn flushCompleted(self: *ToolRecovery) !void {
        for (self.completed.items) |*call| {
            try self.emitCall(call.*);
            call.close();
        }
        self.completed.clearRetainingCapacity();
    }

    pub fn observe(self: *ToolRecovery, record: Records.Record, end_position: u64) !void {
        if (self.end_offset) |limit| {
            if (end_position > limit) {
                return;
            }
        } else if (record.ordinal > self.last_ordinal) {
            return;
        }
        const payload = common.get(record.value, "payload");
        const kind = common.stringField(payload, "type");
        if (eq(common.stringField(record.value, "type"), "event_msg") and eq(kind, "item_completed")) {
            if (self.projected_ordinals.get(record.ordinal)) |expected_id| {
                const event = common.get(payload, "item");
                const event_id = common.stringField(event, "id");
                if (!eq(event_id, expected_id)) {
                    return;
                }
                var exact_match = false;
                for (self.pending.items) |*call| {
                    if (eq(call.id, event_id)) {
                        call.covered = true;
                        exact_match = true;
                    }
                }
                for (self.completed.items) |*call| {
                    if (eq(call.id, event_id)) {
                        call.covered = true;
                        exact_match = true;
                    }
                }
                if (!exact_match) {
                    // Nearby events may belong to background agents. Match
                    // enclosed events only for known orchestration wrappers.
                    const event_kind = common.stringField(event, "type");
                    var matching_wrappers: usize = 0;
                    for (self.pending.items) |*call| {
                        if (call.wraps(event_kind)) {
                            call.covered = true;
                            matching_wrappers += 1;
                        }
                    }
                    for (self.completed.items) |*call| {
                        if (call.wraps(event_kind)) {
                            call.covered = true;
                            matching_wrappers += 1;
                        }
                    }
                    if (matching_wrappers > 1) {
                        self.ambiguous_mapping = true;
                    }
                }
            }
            return;
        }
        if (!eq(common.stringField(record.value, "type"), "response_item")) {
            return;
        }
        // Display completion can follow the response output. Retain completed
        // calls until the next call or user turn to match those late events.
        if (oneOf(kind, &.{ "function_call", "custom_tool_call" }) or
            (eq(kind, "message") and eq(common.stringField(payload, "role"), "user")))
        {
            try self.flushCompleted();
        }
        const call_id = common.stringField(payload, "call_id");
        if (call_id.len == 0) {
            return;
        }
        if (oneOf(kind, &.{ "function_call", "custom_tool_call" })) {
            for (self.pending.items) |*existing| {
                if (eq(existing.id, call_id)) {
                    existing.covered = true;
                    self.ambiguous_mapping = true;
                    return;
                }
            }
            const covered = self.projected_ids.contains(call_id);
            const raw_timestamp = common.get(record.value, "timestamp");
            var call = Call{
                .id = try self.allocator.dupe(u8, call_id),
                .name = try self.allocator.dupe(u8, common.stringField(payload, "name")),
                .ordinal = record.ordinal,
                .timestamp = if (raw_timestamp == .null)
                    self.thread.updated_at
                else
                    try timestamp(self.allocator, raw_timestamp, false),
                .covered = covered,
            };
            if (!covered) {
                const arena = try std.heap.page_allocator.create(std.heap.ArenaAllocator);
                arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                call.arena = arena;
                errdefer call.close();
                call.raw = try common.clone(arena.allocator(), payload);
            }
            errdefer call.close();
            try self.pending.append(call);
        } else if (oneOf(kind, &.{ "function_call_output", "custom_tool_call_output" })) {
            for (self.pending.items, 0..) |pending, index| {
                if (!eq(pending.id, call_id)) {
                    continue;
                }
                var call = self.pending.orderedRemove(index);
                if (call.covered) {
                    call.close();
                } else {
                    errdefer call.close();
                    const raw_timestamp = common.get(record.value, "timestamp");
                    call.output = try common.clone(call.arena.?.allocator(), payload);
                    call.output_ordinal = record.ordinal;
                    call.output_timestamp = if (raw_timestamp == .null)
                        self.thread.updated_at
                    else
                        try timestamp(self.allocator, raw_timestamp, false);
                    try self.completed.append(call);
                }
                return;
            }
        }
    }

    pub fn finish(self: *ToolRecovery, items: *Items) !void {
        try self.flushCompleted();
        // A call can precede the projection cursor while its result is in the
        // live tail. Keeping the call allows the later result to pair once.
        for (self.pending.items) |call| {
            try self.emitCall(call);
        }
        if (self.ambiguous_mapping) {
            const warning = try common.fmt(
                self.allocator,
                "Overlapping raw tool calls could not be assigned to projected tools; " ++
                    "retained the authoritative display",
                .{},
            );
            try self.warnings.append(warning);
        }
        try items.appendSlice(self.additions.items);
        std.mem.sort(Item, items.items, {}, struct {
            fn less(_: void, left: Item, right: Item) bool {
                if (left.ordinal == right.ordinal) {
                    return std.mem.order(u8, left.id, right.id) == .lt;
                }
                return left.ordinal < right.ordinal;
            }
        }.less);
    }
};
