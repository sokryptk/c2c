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
const ToolRecovery = @import("tool_recovery.zig").ToolRecovery;
const Strings = std.array_list.Managed([]const u8);
const Values = std.array_list.Managed(Value);
const Items = std.array_list.Managed(Item);
const absolute = storage.absolute;
const oneOf = normalize.oneOf;
const content = normalize.content;

pub fn recover(
    allocator: Allocator,
    items: *Items,
    thread: Thread,
    warnings: *common.Warnings,
    end_offset: ?u64,
) !void {
    var tools = try ToolRecovery.init(allocator, items.items, thread, warnings, end_offset);
    defer tools.close();
    try recoverProjected(allocator, items.items, thread, warnings, &tools);
    try tools.finish(items);
}

fn imageParts(allocator: Allocator, value: Value) ![]const Value {
    var images = Values.init(allocator);
    for (common.list(value)) |part| {
        if (oneOf(common.stringField(part, "type"), &.{ "input_image", "image", "image_url" })) {
            try images.append(part);
        }
    }
    return images.toOwnedSlice();
}

fn localPaths(allocator: Allocator, item: Item) ![]const []const u8 {
    var paths = Strings.init(allocator);
    for (item.attachments) |attachment| {
        if (eq(common.stringField(attachment, "type"), "localImage") and common.stringField(attachment, "path").len != 0) {
            const path = common.stringField(attachment, "path");
            try paths.append(path);
        }
    }
    return paths.toOwnedSlice();
}

fn eventPath(allocator: Allocator, value: []const u8, cwd: []const u8) !?[]const u8 {
    var path = value;
    if (std.mem.startsWith(u8, path, "file:")) {
        if (std.mem.indexOfAny(u8, path, "?#") != null) {
            return null;
        }
        if (std.mem.startsWith(u8, path, "file:///")) {
            path = path[7..];
        } else if (std.mem.startsWith(u8, path, "file://localhost/")) {
            path = path[16..];
        } else if (std.mem.startsWith(u8, path, "file:/") and !std.mem.startsWith(u8, path, "file://")) {
            path = path[5..];
        } else {
            return null;
        }
        var decoded = std.array_list.Managed(u8).init(allocator);
        var index: usize = 0;
        while (index < path.len) : (index += 1) {
            if (path[index] == '%') {
                if (index + 2 >= path.len) {
                    return null;
                }
                const byte = std.fmt.parseInt(u8, path[index + 1 .. index + 3], 16) catch return null;
                try decoded.append(byte);
                index += 2;
            } else {
                try decoded.append(path[index]);
            }
        }
        path = try decoded.toOwnedSlice();
    }
    return try absolute(allocator, path, cwd);
}

fn eventMatches(allocator: Allocator, item: Item, event: Value, thread: Thread) !bool {
    if (!eq(common.stringField(event, "id"), item.id) or !std.ascii.eqlIgnoreCase(common.stringField(event, "type"), item.kind)) {
        return false;
    }
    var paths = Strings.init(allocator);
    if (eq(item.kind, "imageView")) {
        const path = common.get(event, "path");
        if (path != .string) {
            return false;
        }
        try paths.append(path.string);
    } else {
        for (common.list(common.get(event, "content"))) |part| {
            if (oneOf(common.stringField(part, "type"), &.{ "localImage", "local_image" })) {
                const path = common.get(part, "path");
                if (path != .string) {
                    return false;
                }
                try paths.append(path.string);
            }
        }
    }
    const expected = try localPaths(allocator, item);
    if (paths.items.len != expected.len) {
        return false;
    }
    for (paths.items, expected) |path, target| {
        const normalized = (try eventPath(allocator, path, thread.cwd)) orelse return false;
        if (!eq(normalized, target)) {
            return false;
        }
    }
    return true;
}

fn mergeImages(allocator: Allocator, item: *Item, images: []const Value, warnings: *common.Warnings) !bool {
    var count: usize = 0;
    for (item.attachments) |attachment| {
        if (eq(common.stringField(attachment, "type"), "localImage") and common.stringField(attachment, "path").len != 0) {
            count += 1;
        }
    }
    if (count != images.len) {
        return false;
    }
    var attachments = Values.init(allocator);
    var image_index: usize = 0;
    for (item.attachments) |original| {
        var attachment = original;
        if (eq(common.stringField(attachment, "type"), "localImage") and common.stringField(attachment, "path").len != 0) {
            const image_content = try common.arr(allocator, &.{images[image_index]});
            const parsed = try content(allocator, image_content, warnings);
            image_index += 1;
            if (parsed.attachments.len != 1) {
                return false;
            }
            const url = common.stringField(parsed.attachments[0], "url");
            if (!std.mem.startsWith(u8, url, "data:image/")) {
                return false;
            }
            attachment = try common.clone(allocator, attachment);
            try common.set(allocator, &attachment, "url", common.str(url));
        }
        try attachments.append(attachment);
    }
    item.attachments = try attachments.toOwnedSlice();
    return true;
}

/// Mutates only returned Items. Never opens image paths or writes source stores.
pub fn recoverProjectedImages(allocator: Allocator, items: []Item, thread: Thread, warnings: *common.Warnings) !void {
    try recoverProjected(allocator, items, thread, warnings, null);
}

fn recoverProjected(
    allocator: Allocator,
    items: []Item,
    thread: Thread,
    warnings: *common.Warnings,
    tool_recovery: ?*ToolRecovery,
) !void {
    var targets = std.AutoHashMap(i64, usize).init(allocator);
    for (items, 0..) |item, index| {
        if (!oneOf(item.kind, &.{ "userMessage", "imageView" })) {
            continue;
        }
        for (item.attachments) |attachment| {
            if (eq(common.stringField(attachment, "type"), "localImage") and common.stringField(attachment, "path").len != 0) {
                try targets.put(item.ordinal, index);
                break;
            }
        }
    }
    if ((targets.count() == 0 and tool_recovery == null) or !common.exists(thread.rollout_path)) {
        return;
    }
    const Group = struct {
        candidates: std.array_list.Managed(usize),
        image_count: usize = 0,
        ambiguous: bool = false,
    };
    var pending = std.StringHashMap(Group).init(allocator);
    var ambiguous = std.AutoHashMap(usize, void).init(allocator);
    var recovered = std.AutoHashMap(usize, void).init(allocator);
    var previous_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer previous_arena.deinit();
    var previous_user: ?struct {
        ordinal: i64,
        images: []const Value,
    } = null;
    var records = try Records.open(allocator, thread.rollout_path, 0, 0, warnings);
    defer records.close();
    while (try records.next()) |record| {
        if (tool_recovery) |tools| {
            try tools.observe(record, records.position);
        }
        if (targets.count() == 0) {
            continue;
        }
        const scratch = records.arena.allocator();
        const payload = common.get(record.value, "payload");
        const kind = common.stringField(payload, "type");
        if (eq(common.stringField(record.value, "type"), "response_item")) {
            if (eq(kind, "message") and eq(common.stringField(payload, "role"), "user")) {
                var groups = pending.valueIterator();
                while (groups.next()) |group| {
                    for (group.candidates.items) |candidate| {
                        try ambiguous.put(candidate, {});
                    }
                }
                pending.clearRetainingCapacity();
                _ = previous_arena.reset(.free_all);
                const previous_allocator = previous_arena.allocator();
                const parts = try imageParts(scratch, common.get(payload, "content"));
                var saved = Values.init(previous_allocator);
                for (parts) |part| {
                    const retained_part = try common.clone(previous_allocator, part);
                    try saved.append(retained_part);
                }
                previous_user = .{ .ordinal = record.ordinal, .images = try saved.toOwnedSlice() };
                continue;
            }
            previous_user = null;
            const call_id = common.stringField(payload, "call_id");
            if (oneOf(kind, &.{ "function_call", "custom_tool_call" }) and call_id.len != 0) {
                const overlapping = pending.count() != 0;
                var groups = pending.valueIterator();
                while (groups.next()) |group| {
                    group.ambiguous = true;
                }
                const retained_call_id = try allocator.dupe(u8, call_id);
                try pending.put(retained_call_id, .{
                    .candidates = std.array_list.Managed(usize).init(allocator),
                    .ambiguous = overlapping,
                });
            } else if (oneOf(kind, &.{ "function_call_output", "custom_tool_call_output" })) {
                if (pending.fetchRemove(call_id)) |entry| {
                    const group = entry.value;
                    const parts = try imageParts(scratch, common.get(payload, "output"));
                    const single_candidate = !group.ambiguous and group.image_count == 1 and
                        group.candidates.items.len == 1 and parts.len == 1;
                    if (single_candidate and
                        try mergeImages(allocator, &items[group.candidates.items[0]], parts, warnings))
                    {
                        try recovered.put(group.candidates.items[0], {});
                    } else {
                        for (group.candidates.items) |candidate| {
                            try ambiguous.put(candidate, {});
                        }
                    }
                }
            }
            continue;
        }
        if (!eq(common.stringField(record.value, "type"), "event_msg") or !eq(kind, "item_completed")) {
            previous_user = null;
            continue;
        }
        const event = common.get(payload, "item");
        const index = targets.get(record.ordinal);
        const verified = if (index) |candidate| try eventMatches(scratch, items[candidate], event, thread) else false;
        const event_kind = common.stringField(event, "type");
        if (std.ascii.eqlIgnoreCase(event_kind, "UserMessage")) {
            if (verified) {
                if (previous_user) |previous| {
                    if (previous.ordinal == record.ordinal - 1) {
                        const candidate = index.?;
                        if (try mergeImages(allocator, &items[candidate], previous.images, warnings)) {
                            try recovered.put(candidate, {});
                        } else {
                            try ambiguous.put(candidate, {});
                        }
                    }
                }
            }
        } else if (std.ascii.eqlIgnoreCase(event_kind, "ImageView") or
            std.ascii.eqlIgnoreCase(event_kind, "ImageGeneration"))
        {
            if (pending.count() == 1) {
                var groups = pending.valueIterator();
                const group = groups.next().?;
                group.image_count += 1;
                if (verified and eq(items[index.?].kind, "imageView")) {
                    try group.candidates.append(index.?);
                }
            } else if (verified) {
                try ambiguous.put(index.?, {});
            }
        }
        previous_user = null;
    }
    var groups = pending.valueIterator();
    while (groups.next()) |group| {
        for (group.candidates.items) |candidate| {
            try ambiguous.put(candidate, {});
        }
    }
    var recovered_keys = recovered.keyIterator();
    while (recovered_keys.next()) |index| {
        _ = ambiguous.remove(index.*);
    }
    if (ambiguous.count() != 0) {
        const warning = try common.fmt(
            allocator,
            "Raw image recovery was ambiguous for {d} projected item(s); kept original paths",
            .{ambiguous.count()},
        );
        try warnings.append(warning);
    }
}
