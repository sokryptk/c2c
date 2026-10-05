const fs = @import("os/fs.zig");
const lines = @import("os/lines.zig");
const process = @import("os/process.zig");

pub const DirEntry = fs.DirEntry;
pub const stat = fs.stat;
pub const lstat = fs.lstat;
pub const exists = fs.exists;
pub const sameFile = fs.sameFile;
pub const readFile = fs.readFile;
pub const writeExclusive = fs.writeExclusive;
pub const atomicWrite = fs.atomicWrite;
pub const mkdirAll = fs.mkdirAll;
pub const hardLink = fs.hardLink;
pub const removeFile = fs.removeFile;
pub const renameFile = fs.renameFile;
pub const syncDir = fs.syncDir;
pub const copyExclusive = fs.copyExclusive;
pub const listDir = fs.listDir;
pub const walkFiles = fs.walkFiles;
pub const sha256File = fs.sha256File;
pub const canonicalPath = fs.canonicalPath;
pub const Lock = fs.Lock;
pub const lock = fs.lock;

pub const LineReader = lines.LineReader;
pub const readJsonl = lines.readJsonl;
pub const run = process.run;
pub const Child = process.Child;
pub const writeAll = @import("os/posix.zig").writeAll;

test {
    _ = @import("os/fs_test.zig");
    _ = process;
}
