const std = @import("std");
const common = @import("common.zig");
const cli = @import("cli.zig");
const diagnostics = @import("diagnostics.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const exit_code = cli.run(allocator, args[1..]) catch |err| blk: {
        const code = @errorName(err);
        const message = try common.fmt(allocator, "c2c: {s}\n  {s}\n", .{ code, diagnostics.reason(code) });
        _ = common.c.write(2, message.ptr, message.len);
        break :blk @as(u8, 1);
    };
    if (exit_code != 0) {
        std.process.exit(exit_code);
    }
}

test {
    _ = @import("common.zig");
    _ = @import("os.zig");
    _ = @import("source.zig");
    _ = @import("source_test.zig");
    _ = @import("claude.zig");
    _ = @import("codex.zig");
    _ = @import("cli.zig");
}
