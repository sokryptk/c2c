const H = @import("common.zig");
const A = H.Allocator;
const output = @import("cli/output.zig");

pub const Provider = @import("cli/options.zig").Provider;
pub const Options = @import("cli/options.zig").Options;
pub const parseOptions = @import("cli/options.zig").parseOptions;
pub const execute = @import("migration.zig").execute;

pub fn run(a: A, args: []const []const u8) !u8 {
    const options = parseOptions(a, args) catch |err| {
        try output.printResult(a, .{ .json_output = H.oneOf("--json", args) }, try output.terminalFailure(a, @errorName(err), "arguments"));
        return 1;
    };
    if (options.help) {
        try output.printHelp();
        return 0;
    }
    const result = execute(a, options) catch |err| blk: {
        var failed = try output.terminalFailure(a, @errorName(err), options.action);
        try H.set(a, &failed, "sourceHome", H.str(options.home(options.from)));
        try H.set(a, &failed, "targetHome", H.str(options.home(options.to)));
        if (!H.eq(options.action, "inventory")) try H.set(a, &failed, "manifest", H.str(try H.join(a, &.{ options.output_dir, "manifest.json" })));
        break :blk failed;
    };
    try output.printResult(a, options, result);
    if (H.get(result, "error") != .null) return 1;
    for ([_][]const u8{ "error", "invalid", "collision", "missing", "pending-registration" }) |status| if (H.integer(H.get(H.get(result, "counts"), status)) > 0) return 1;
    return 0;
}

test {
    _ = @import("cli/options.zig");
    _ = @import("migration/sources.zig");
    _ = @import("cli/test.zig");
}
