const reader = @import("omp/read.zig");
const writer = @import("omp/write.zig");

pub const Origin = reader.Origin;
pub const listThreads = reader.listThreads;
pub const readEntries = reader.readEntries;
pub const readOrigin = reader.readOrigin;
pub const targetPath = writer.targetPath;
pub const convert = writer.convert;
pub const validate = @import("omp/format.zig").validate;

test {
    _ = @import("omp/test.zig");
}
