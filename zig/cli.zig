const common = @import("common.zig");
const Allocator = common.Allocator;
const output = @import("cli/output.zig");

pub const Provider = @import("cli/options.zig").Provider;
pub const Options = @import("cli/options.zig").Options;
pub const parseOptions = @import("cli/options.zig").parseOptions;
pub const execute = @import("migration.zig").execute;

pub fn run(allocator: Allocator, args: []const []const u8) !u8 {
    const options = parseOptions(allocator, args) catch |err| {
        const failed = try output.terminalFailure(allocator, @errorName(err), "arguments");
        try output.printResult(allocator, .{ .json_output = common.oneOf("--json", args) }, failed);
        return 1;
    };
    if (options.help) {
        try output.printHelp();
        return 0;
    }
    const result = execute(allocator, options) catch |err| blk: {
        var failed = try output.terminalFailure(allocator, @errorName(err), options.action);
        try common.set(allocator, &failed, "sourceHome", common.str(options.home(options.from)));
        try common.set(allocator, &failed, "targetHome", common.str(options.home(options.to)));
        if (!common.eq(options.action, "inventory")) {
            const manifest_path = try common.join(allocator, &.{ options.output_dir, "manifest.json" });
            try common.set(allocator, &failed, "manifest", common.str(manifest_path));
        }
        break :blk failed;
    };
    try output.printResult(allocator, options, result);
    if (common.get(result, "error") != .null) {
        return 1;
    }
    const counts = common.get(result, "counts");
    for ([_][]const u8{ "error", "invalid", "collision", "missing", "pending-registration" }) |status| {
        if (common.integer(common.get(counts, status)) > 0) {
            return 1;
        }
    }
    return 0;
}

test {
    _ = @import("cli/options.zig");
    _ = @import("migration/sources.zig");
    _ = @import("cli/test.zig");
}
