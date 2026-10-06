const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.createModule(.{
        .root_source_file = b.path("zig/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.linkSystemLibrary("sqlite3", .{});
    const executable = b.addExecutable(.{ .name = "c2c", .root_module = module });
    b.installArtifact(executable);
    const run = b.addRunArtifact(executable);
    if (b.args) |args| {
        run.addArgs(args);
    }
    b.step("run", "Run c2c").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = module });
    const check = b.addRunArtifact(tests);
    b.step("test", "Run native Zig tests").dependOn(&check.step);
}
