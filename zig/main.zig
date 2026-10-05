const std = @import("std");
const common = @import("common.zig");
const cli = @import("cli.zig");
const diagnostics = @import("diagnostics.zig");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const exit_code = cli.run(a, args[1..]) catch |err| blk: {
        const message = try common.fmt(a, "c2c: {s}\n  {s}\n", .{ @errorName(err), diagnostics.reason(@errorName(err)) });
        _ = common.c.write(2, message.ptr, message.len);
        break :blk @as(u8, 1);
    };
    if (exit_code != 0) std.process.exit(exit_code);
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
