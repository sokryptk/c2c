const std = @import("std");
const common = @import("../common.zig");
const c = common.c;
const Allocator = std.mem.Allocator;
const posix = @import("posix.zig");
const errnoError = posix.errnoError;
const interrupted = posix.interrupted;
const wouldBlock = posix.wouldBlock;
const zpath = posix.zpath;
const closeFd = posix.closeFd;

extern "c" var environ: [*:null]?[*:0]u8;

fn monotonicMs() i64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) {
        return 0;
    }
    return @intCast(@as(i128, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000));
}

fn pauseMs(ms: u32) void {
    var ts = c.struct_timespec{
        .tv_sec = @intCast(ms / 1000),
        .tv_nsec = @intCast((ms % 1000) * 1_000_000),
    };
    while (c.nanosleep(&ts, &ts) != 0) {
        if (!interrupted()) {
            break;
        }
    }
}

fn nonblocking(fd: c_int) !void {
    const flags = c.fcntl(fd, c.F_GETFL);
    if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | @as(c_int, c.O_NONBLOCK)) < 0) {
        return errnoError();
    }
}

fn makePipe() ![2]c_int {
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) {
        return errnoError();
    }
    errdefer {
        closeFd(fds[0]);
        closeFd(fds[1]);
    }
    for (&fds) |*fd| {
        // Avoid dup2/close collisions when the caller has closed a stdio fd.
        if (fd.* < 3) {
            const replacement = c.fcntl(fd.*, c.F_DUPFD_CLOEXEC, @as(c_int, 3));
            if (replacement < 0) {
                return errnoError();
            }
            closeFd(fd.*);
            fd.* = replacement;
        } else if (c.fcntl(fd.*, c.F_SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) {
            return errnoError();
        }
    }
    return fds;
}

fn childFailure() noreturn {
    const message = "c2c: failed to execute process\n";
    _ = c.write(c.STDERR_FILENO, message.ptr, message.len);
    c._exit(127);
}

const Spawned = struct {
    pid: c.pid_t,
    input: c_int,
    output: c_int,
    err: c_int,
};
fn setPipeSignal(handler: ?std.c.Sigaction.handler_fn) !void {
    const action: std.c.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = std.posix.sigemptyset(),
        .flags = std.c.SA.RESTART,
    };
    if (std.c.sigaction(.PIPE, &action, null) != 0) {
        return errnoError();
    }
}

fn spawn(
    allocator: Allocator,
    args: []const []const u8,
    overrides: []const common.Env,
    capture_stderr: bool,
) !Spawned {
    if (args.len == 0 or args[0].len == 0) {
        return error.InvalidArguments;
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temporary = arena.allocator();
    const argv = try temporary.allocSentinel(?[*:0]u8, args.len, null);
    for (args, 0..) |arg, i| {
        const terminated_arg = try zpath(temporary, arg);
        argv[i] = terminated_arg.ptr;
    }
    var environment = std.array_list.Managed(?[*:0]u8).init(temporary);
    var inherited: usize = 0;
    while (environ[inherited]) |entry| : (inherited += 1) {
        const text = std.mem.span(entry);
        const equals = std.mem.indexOfScalar(u8, text, '=') orelse continue;
        var overridden = false;
        for (overrides) |pair| {
            if (std.mem.eql(u8, pair[0], text[0..equals])) {
                overridden = true;
                break;
            }
        }
        if (!overridden) {
            const entry_copy = try temporary.dupeZ(u8, text);
            try environment.append(entry_copy.ptr);
        }
    }
    for (overrides) |pair| {
        const name = pair[0];
        const value = pair[1];
        if (name.len == 0 or
            std.mem.indexOfAny(u8, name, "=\x00") != null or
            std.mem.indexOfScalar(u8, value, 0) != null)
        {
            return error.InvalidEnvironment;
        }
        const entry = try std.fmt.allocPrintSentinel(
            temporary,
            "{s}={s}",
            .{ name, value },
            0,
        );
        try environment.append(entry.ptr);
    }
    try environment.append(null);
    const input = try makePipe();
    errdefer {
        closeFd(input[0]);
        closeFd(input[1]);
    }
    const output = try makePipe();
    errdefer {
        closeFd(output[0]);
        closeFd(output[1]);
    }
    const stderr_pipe = try makePipe();
    errdefer {
        closeFd(stderr_pipe[0]);
        closeFd(stderr_pipe[1]);
    }
    var devnull = if (capture_stderr) @as(c_int, -1) else c.open("/dev/null", c.O_WRONLY | c.O_CLOEXEC);
    if (!capture_stderr and devnull < 0) {
        return errnoError();
    }
    defer closeFd(devnull);
    if (devnull >= 0 and devnull < 3) {
        const replacement = c.fcntl(devnull, c.F_DUPFD_CLOEXEC, @as(c_int, 3));
        if (replacement < 0) {
            return errnoError();
        }
        closeFd(devnull);
        devnull = replacement;
    }
    // Only the parent's pipe ends are nonblocking; the child's stay blocking.
    try nonblocking(input[1]);
    try nonblocking(output[0]);
    try nonblocking(stderr_pipe[0]);
    // Pipe writes must report EPIPE instead of terminating this process.
    // Restore the conventional disposition in the child before exec.
    try setPipeSignal(std.c.SIG.IGN);
    const pid = c.fork();
    if (pid < 0) {
        return errnoError();
    }
    if (pid == 0) {
        _ = c.setpgid(0, 0);
        setPipeSignal(std.c.SIG.DFL) catch childFailure();
        const child_stderr = if (capture_stderr) stderr_pipe[1] else devnull;
        if (c.dup2(input[0], c.STDIN_FILENO) < 0 or
            c.dup2(output[1], c.STDOUT_FILENO) < 0 or
            c.dup2(child_stderr, c.STDERR_FILENO) < 0)
        {
            childFailure();
        }
        const pipe_fds = [_]c_int{
            input[0], input[1], output[0], output[1], stderr_pipe[0], stderr_pipe[1],
        };
        for (pipe_fds) |fd| {
            closeFd(fd);
        }
        if (devnull > 2) {
            closeFd(devnull);
        }
        environ = @ptrCast(environment.items.ptr);
        _ = c.execvp(argv[0].?, @ptrCast(argv.ptr));
        childFailure();
    }
    _ = c.setpgid(pid, pid);
    closeFd(input[0]);
    closeFd(output[1]);
    closeFd(stderr_pipe[1]);
    return .{
        .pid = pid,
        .input = input[1],
        .output = output[0],
        .err = stderr_pipe[0],
    };
}

fn pollChild(pid: c.pid_t, status: *c_int) !bool {
    while (true) {
        const result = c.waitpid(pid, status, c.WNOHANG);
        if (result == pid) {
            return true;
        }
        if (result == 0) {
            return false;
        }
        if (interrupted()) {
            continue;
        }
        if (std.c.errno(@as(c_int, -1)) == .CHILD) {
            return true;
        }
        return errnoError();
    }
}

fn terminateAndReap(pid: c.pid_t) void {
    if (pid <= 0) {
        return;
    }
    _ = c.kill(-pid, c.SIGKILL);
    _ = c.kill(pid, c.SIGKILL);
    const deadline = monotonicMs() + 4500;
    var status: c_int = 0;
    while (!(pollChild(pid, &status) catch true) and monotonicMs() < deadline) {
        pauseMs(10);
    }
}

fn waitPoll(fds: []c.struct_pollfd, timeout: c_int) !void {
    const n = c.poll(fds.ptr, @intCast(fds.len), timeout);
    if (n < 0 and !interrupted()) {
        return errnoError();
    }
}

fn captureOnce(fd: *c_int, result: *std.array_list.Managed(u8)) !void {
    var buffer: [64 * 1024]u8 = undefined;
    const n = c.read(fd.*, &buffer, buffer.len);
    if (n < 0) {
        if (interrupted() or wouldBlock()) {
            return;
        }
        return errnoError();
    }
    if (n == 0) {
        closeFd(fd.*);
        fd.* = -1;
        return;
    }
    try result.appendSlice(buffer[0..@intCast(n)]);
}
/// Executes argv directly. Overrides are merged with the inherited environment.
/// A zero timeout disables the deadline; signal exits use 128 + signal number.
pub fn run(
    allocator: Allocator,
    args: []const []const u8,
    env: []const common.Env,
    input_data: ?[]const u8,
    timeout_ms: u32,
) !common.RunResult {
    var child = try spawn(allocator, args, env, true);
    var reaped = false;
    defer {
        closeFd(child.input);
        closeFd(child.output);
        closeFd(child.err);
        if (!reaped) {
            terminateAndReap(child.pid);
        }
    }
    var stdout = std.array_list.Managed(u8).init(allocator);
    defer stdout.deinit();
    var stderr = std.array_list.Managed(u8).init(allocator);
    defer stderr.deinit();
    const input = input_data orelse "";
    var written: usize = 0;
    var status: c_int = 0;
    const deadline = if (timeout_ms == 0) std.math.maxInt(i64) else monotonicMs() + timeout_ms;
    while (!reaped or child.output >= 0 or child.err >= 0) {
        if (monotonicMs() >= deadline) {
            if (reaped) {
                _ = c.kill(-child.pid, c.SIGKILL);
            } else {
                terminateAndReap(child.pid);
            }
            reaped = true;
            return error.Timeout;
        }
        if (written == input.len and child.input >= 0) {
            closeFd(child.input);
            child.input = -1;
        }
        var fds = [_]c.struct_pollfd{
            .{ .fd = child.output, .events = c.POLLIN, .revents = 0 },
            .{ .fd = child.err, .events = c.POLLIN, .revents = 0 },
            .{ .fd = child.input, .events = c.POLLOUT, .revents = 0 },
        };
        const remaining_ms = @max(0, deadline - monotonicMs());
        try waitPoll(&fds, @intCast(@min(100, remaining_ms)));
        if (fds[0].revents != 0 and child.output >= 0) {
            try captureOnce(&child.output, &stdout);
        }
        if (fds[1].revents != 0 and child.err >= 0) {
            try captureOnce(&child.err, &stderr);
        }
        if (fds[2].revents != 0 and child.input >= 0) {
            const n = c.write(child.input, input[written..].ptr, @min(64 * 1024, input.len - written));
            if (n < 0) {
                if (!interrupted() and !wouldBlock()) {
                    if (std.c.errno(@as(c_int, -1)) != .PIPE) {
                        return errnoError();
                    }
                    closeFd(child.input);
                    child.input = -1;
                }
            } else {
                written += @intCast(n);
            }
        }
        if (!reaped) {
            reaped = try pollChild(child.pid, &status);
        }
    }
    const output = try stdout.toOwnedSlice();
    errdefer allocator.free(output);
    const errors = try stderr.toOwnedSlice();
    const signal = status & 0x7f;
    const exit_status = (status >> 8) & 0xff;
    const code: i32 = if (signal == 0) exit_status else 128 + signal;
    return .{
        .stdout = output,
        .stderr = errors,
        .exit_code = code,
    };
}

pub const Child = struct {
    pid: c.pid_t,
    input: c_int,
    output: c_int,
    pending: std.array_list.Managed(u8),
    ended: bool = false,
    reaped: bool = false,
    pub fn start(allocator: Allocator, args: []const []const u8, env: []const common.Env) !Child {
        const child = try spawn(allocator, args, env, false);
        closeFd(child.err);
        return .{
            .pid = child.pid,
            .input = child.input,
            .output = child.output,
            .pending = std.array_list.Managed(u8).init(allocator),
        };
    }
    pub fn write(self: *Child, data: []const u8) !void {
        if (self.input < 0) {
            return error.BrokenPipe;
        }
        const deadline = monotonicMs() + 30_000;
        var pos: usize = 0;
        while (pos < data.len) {
            if (monotonicMs() >= deadline) {
                return error.Timeout;
            }
            const n = c.write(self.input, data[pos..].ptr, @min(64 * 1024, data.len - pos));
            if (n >= 0) {
                if (n == 0) {
                    return error.WriteZero;
                }
                pos += @intCast(n);
                continue;
            }
            if (interrupted()) {
                continue;
            }
            if (!wouldBlock()) {
                return errnoError();
            }
            // A peer can produce responses while consuming a large request.
            // Drain stdout here as well to avoid a bidirectional pipe deadlock.
            var fds = [_]c.struct_pollfd{
                .{ .fd = self.input, .events = c.POLLOUT, .revents = 0 },
                .{ .fd = self.output, .events = c.POLLIN, .revents = 0 },
            };
            try waitPoll(&fds, 100);
            if (fds[1].revents != 0 and self.output >= 0) {
                try captureOnce(&self.output, &self.pending);
                if (self.output < 0) {
                    self.ended = true;
                }
            }
        }
    }
    pub fn readLine(self: *Child, allocator: Allocator, timeout_ms: u32) !?[]const u8 {
        const deadline = if (timeout_ms == 0) std.math.maxInt(i64) else monotonicMs() + timeout_ms;
        while (true) {
            if (std.mem.indexOfScalar(u8, self.pending.items, '\n')) |i| {
                const line = try allocator.dupe(u8, std.mem.trimEnd(u8, self.pending.items[0..i], "\r"));
                const remaining = self.pending.items[i + 1 ..];
                std.mem.copyForwards(u8, self.pending.items[0..remaining.len], remaining);
                self.pending.items.len = remaining.len;
                return line;
            }
            if (self.ended) {
                if (self.pending.items.len == 0) {
                    return null;
                }
                const line = try allocator.dupe(u8, std.mem.trimEnd(u8, self.pending.items, "\r"));
                self.pending.clearRetainingCapacity();
                return line;
            }
            if (monotonicMs() >= deadline) {
                return error.Timeout;
            }
            var fds = [_]c.struct_pollfd{.{ .fd = self.output, .events = c.POLLIN, .revents = 0 }};
            const remaining_ms = @max(0, deadline - monotonicMs());
            try waitPoll(&fds, @intCast(@min(100, remaining_ms)));
            if (fds[0].revents != 0) {
                try captureOnce(&self.output, &self.pending);
                if (self.output < 0) {
                    self.ended = true;
                }
            }
        }
    }
    /// Closing never waits indefinitely for a misbehaving process or descendant.
    pub fn close(self: *Child) void {
        if (self.reaped) {
            return;
        }
        closeFd(self.input);
        self.input = -1;
        closeFd(self.output);
        self.output = -1;
        self.pending.deinit();
        if (!self.reaped) {
            terminateAndReap(self.pid);
            self.reaped = true;
        }
        self.ended = true;
    }
};

test "run captures both pipes while feeding stdin and merges environment" {
    const allocator = std.testing.allocator;
    const input = try allocator.alloc(u8, 500_000);
    defer allocator.free(input);
    @memset(input, 'i');
    const script =
        \\import os
        \\import sys
        \\sys.stderr.write('e' * 200000)
        \\sys.stdout.write('o' * 200000)
        \\sys.stdout.flush()
        \\data = sys.stdin.buffer.read()
        \\sys.stdout.buffer.write(data)
        \\sys.stderr.write(os.environ['C2C_OS_TEST'])
    ;
    const result = try run(
        allocator,
        &.{ "python3", "-c", script },
        &.{.{ "C2C_OS_TEST", "works" }},
        input,
        5000,
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expectEqual(@as(usize, 700_000), result.stdout.len);
    try std.testing.expectEqual(@as(usize, 200_005), result.stderr.len);
    try std.testing.expect(std.mem.endsWith(u8, result.stderr, "works"));
    try std.testing.expect(std.mem.endsWith(u8, result.stdout, input));
}
test "run deadlines survive continuous output and descendants holding pipes" {
    const allocator = std.testing.allocator;
    const start = monotonicMs();
    const continuous_output =
        \\import os
        \\while True:
        \\    os.write(1, b'x' * 65536)
    ;
    try std.testing.expectError(
        error.Timeout,
        run(allocator, &.{ "python3", "-c", continuous_output }, &.{}, null, 100),
    );
    try std.testing.expect(monotonicMs() - start < 3000);
    const descendant_holds_pipe =
        \\import os
        \\import time
        \\if os.fork() == 0:
        \\    time.sleep(20)
    ;
    try std.testing.expectError(
        error.Timeout,
        run(allocator, &.{ "python3", "-c", descendant_holds_pipe }, &.{}, null, 100),
    );
    const result = try run(allocator, &.{"/definitely/missing/c2c-test-executable"}, &.{}, null, 1000);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(i32, 127), result.exit_code);
}
test "child restores default SIGPIPE disposition" {
    const allocator = std.testing.allocator;
    const result = try run(allocator, &.{ "/bin/sh", "-c", "kill -PIPE $$; exit 99" }, &.{}, null, 1000);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(i32, 128 + c.SIGPIPE), result.exit_code);
}
test "interactive child lines preserve buffering EOF and broken pipe safety" {
    const allocator = std.testing.allocator;
    const script =
        \\import os
        \\import sys
        \\line = sys.stdin.readline()
        \\os.close(0)
        \\sys.stdout.write(line + 'two\nlast')
    ;
    var child = try Child.start(allocator, &.{ "python3", "-u", "-c", script }, &.{});
    defer child.close();
    try child.write("one\n");
    const one = (try child.readLine(allocator, 1000)).?;
    defer allocator.free(one);
    const two = (try child.readLine(allocator, 1000)).?;
    defer allocator.free(two);
    const last = (try child.readLine(allocator, 1000)).?;
    defer allocator.free(last);
    try std.testing.expectEqualStrings("one", one);
    try std.testing.expectEqualStrings("two", two);
    try std.testing.expectEqualStrings("last", last);
    try std.testing.expect((try child.readLine(allocator, 1000)) == null);
    try std.testing.expectError(error.BrokenPipe, child.write("closed\n"));
}
