const std = @import("std");
const common = @import("../common.zig");
const Allocator = common.Allocator;
const Strings = std.array_list.Managed([]const u8);

pub const Provider = enum {
    codex,
    claude,
    omp,
    opencode,
};

pub const Options = struct {
    from: Provider = .codex,
    to: Provider = .claude,
    action: []const u8 = "migrate",
    codex_home: []const u8 = "",
    claude_home: []const u8 = "",
    omp_home: []const u8 = "",
    opencode_home: []const u8 = "",
    output_dir: []const u8 = "",
    user_home: []const u8 = "",
    projects: []const []const u8 = &.{},
    project_prefixes: []const []const u8 = &.{},
    threads: []const []const u8 = &.{},
    origin_manifests: []const []const u8 = &.{},
    json_output: bool = false,
    include_subagents: bool = false,
    no_images: bool = false,
    help: bool = false,

    pub fn direction(self: Options, allocator: Allocator) ![]const u8 {
        return common.fmt(allocator, "{s}-to-{s}", .{ @tagName(self.from), @tagName(self.to) });
    }

    pub fn home(self: Options, selected_provider: Provider) []const u8 {
        return switch (selected_provider) {
            .codex => self.codex_home,
            .claude => self.claude_home,
            .omp => self.omp_home,
            .opencode => self.opencode_home,
        };
    }
};

fn provider(value: []const u8) !Provider {
    return std.meta.stringToEnum(Provider, value) orelse error.UnknownProvider;
}

fn environment(name: [:0]const u8) ?[]const u8 {
    const value = common.c.getenv(name.ptr) orelse return null;
    const text = std.mem.span(value);
    return if (text.len > 0) text else null;
}

fn setDirection(options: *Options, value: []const u8) !void {
    const split = std.mem.indexOf(u8, value, "-to-") orelse return error.InvalidDirection;
    options.from = try provider(value[0..split]);
    options.to = try provider(value[split + 4 ..]);
}

pub fn parseOptions(allocator: Allocator, args: []const []const u8) !Options {
    var options = Options{};
    options.user_home = if (common.c.getenv("HOME")) |home|
        try allocator.dupe(u8, std.mem.span(home))
    else
        return error.HomeNotFound;
    options.codex_home = if (environment("CODEX_HOME")) |home|
        try allocator.dupe(u8, home)
    else
        try common.join(allocator, &.{ options.user_home, ".codex" });
    options.claude_home = if (environment("CLAUDE_CONFIG_DIR")) |home|
        try allocator.dupe(u8, home)
    else
        try common.join(allocator, &.{ options.user_home, ".claude" });
    options.omp_home = if (environment("PI_CODING_AGENT_DIR")) |home|
        try allocator.dupe(u8, home)
    else
        try common.join(allocator, &.{ options.user_home, ".omp", "agent" });
    options.opencode_home = if (environment("XDG_DATA_HOME")) |home|
        try common.join(allocator, &.{ home, "opencode" })
    else
        try common.join(allocator, &.{ options.user_home, ".local", "share", "opencode" });
    var projects = Strings.init(allocator);
    var prefixes = Strings.init(allocator);
    var threads = Strings.init(allocator);
    var origins = Strings.init(allocator);
    var action_set = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (common.oneOf(arg, &.{ "--help", "-h" })) {
            options.help = true;
            continue;
        }
        if (common.eq(arg, "--json")) {
            options.json_output = true;
            continue;
        }
        if (common.eq(arg, "--no-images")) {
            options.no_images = true;
            continue;
        }
        if (common.eq(arg, "--include-subagents")) {
            options.include_subagents = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            const separator = std.mem.indexOfScalar(u8, arg, '=');
            const key = if (separator) |offset| arg[0..offset] else arg;
            const value_options = [_][]const u8{
                "--from",
                "--to",
                "--direction",
                "--codex-home",
                "--claude-home",
                "--omp-home",
                "--opencode-home",
                "--output-dir",
                "--project",
                "--project-prefix",
                "--thread",
                "--origin-manifest",
            };
            if (!common.oneOf(key, &value_options)) {
                return error.UnknownOption;
            }
            const value = if (separator) |offset| arg[offset + 1 ..] else blk: {
                index += 1;
                if (index >= args.len or std.mem.startsWith(u8, args[index], "--")) {
                    return error.MissingOptionValue;
                }
                break :blk args[index];
            };
            if (value.len == 0) {
                return error.MissingOptionValue;
            }
            if (common.eq(key, "--from")) {
                options.from = try provider(value);
            } else if (common.eq(key, "--to")) {
                options.to = try provider(value);
            } else if (common.eq(key, "--direction")) {
                try setDirection(&options, value);
            } else if (common.eq(key, "--codex-home")) {
                options.codex_home = value;
            } else if (common.eq(key, "--claude-home")) {
                options.claude_home = value;
            } else if (common.eq(key, "--omp-home")) {
                options.omp_home = value;
            } else if (common.eq(key, "--opencode-home")) {
                options.opencode_home = value;
            } else if (common.eq(key, "--output-dir")) {
                options.output_dir = value;
            } else if (common.eq(key, "--project")) {
                try projects.append(try common.canonicalPath(allocator, value));
            } else if (common.eq(key, "--project-prefix")) {
                try prefixes.append(try common.canonicalPath(allocator, value));
            } else if (common.eq(key, "--thread")) {
                try threads.append(value);
            } else if (common.eq(key, "--origin-manifest")) {
                try origins.append(try common.canonicalPath(allocator, value));
            } else {
                return error.UnknownOption;
            }
        } else if (common.oneOf(arg, &.{ "inventory", "migrate", "verify", "list", "undo" })) {
            if (action_set) {
                return error.MultipleActions;
            }
            options.action = arg;
            action_set = true;
        } else if (std.mem.indexOf(u8, arg, "-to-") != null) {
            try setDirection(&options, arg);
        } else {
            return error.UnknownCommand;
        }
    }
    if (args.len == 0) {
        options.help = true;
    }
    if (options.from == options.to) {
        return error.SameProvider;
    }
    options.codex_home = try common.canonicalPath(allocator, options.codex_home);
    options.claude_home = try common.canonicalPath(allocator, options.claude_home);
    options.omp_home = try common.canonicalPath(allocator, options.omp_home);
    options.opencode_home = try common.canonicalPath(allocator, options.opencode_home);
    if (options.output_dir.len == 0) {
        const legacy = try common.join(allocator, &.{ options.user_home, ".local", "share", "codex-to-claude" });
        const use_legacy = options.from == .codex and options.to == .claude and
            common.exists(try common.join(allocator, &.{ legacy, "manifest.json" }));
        options.output_dir = if (use_legacy)
            legacy
        else
            try common.join(allocator, &.{ options.user_home, ".local", "share", "c2c", try options.direction(allocator) });
    }
    options.output_dir = try common.canonicalPath(allocator, options.output_dir);
    options.projects = projects.items;
    options.project_prefixes = prefixes.items;
    options.threads = threads.items;
    options.origin_manifests = origins.items;
    return options;
}

test "direction aliases and provider flags retain explicit output directories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const options = try parseOptions(allocator, &.{
        "claude-to-codex",
        "inventory",
        "--output-dir",
        "/tmp/c2c-cli-options",
        "--json",
    });
    try std.testing.expectEqual(Provider.claude, options.from);
    try std.testing.expectEqual(Provider.codex, options.to);
    try std.testing.expectEqualStrings("inventory", options.action);
    try std.testing.expectEqualStrings("/tmp/c2c-cli-options", options.output_dir);
    const generic = try parseOptions(allocator, &.{ "--from=omp", "--to=opencode" });
    try std.testing.expectEqual(Provider.omp, generic.from);
    try std.testing.expectEqual(Provider.opencode, generic.to);
}

test "documented Codex home environment is respected and explicit flags win" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const previous = if (common.c.getenv("CODEX_HOME")) |value|
        try allocator.dupeZ(u8, std.mem.span(value))
    else
        null;
    defer {
        if (previous) |value| {
            _ = common.c.setenv("CODEX_HOME", value, 1);
        } else {
            _ = common.c.unsetenv("CODEX_HOME");
        }
    }
    try std.testing.expectEqual(@as(c_int, 0), common.c.setenv("CODEX_HOME", "/tmp/c2c-environment-home", 1));
    const environment_options = try parseOptions(allocator, &.{"inventory"});
    try std.testing.expectEqualStrings("/tmp/c2c-environment-home", environment_options.codex_home);
    const explicit_options = try parseOptions(allocator, &.{ "inventory", "--codex-home", "/tmp/c2c-explicit-home" });
    try std.testing.expectEqualStrings("/tmp/c2c-explicit-home", explicit_options.codex_home);
    try std.testing.expectEqual(@as(c_int, 0), common.c.setenv("CODEX_HOME", "", 1));
    const fallback = try parseOptions(allocator, &.{"inventory"});
    try std.testing.expectEqualStrings(try common.join(allocator, &.{ fallback.user_home, ".codex" }), fallback.codex_home);
}
