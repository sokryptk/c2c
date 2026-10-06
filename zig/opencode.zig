const codec = @import("opencode/codec.zig");
const native = @import("opencode/native.zig");

pub const Origin = codec.Origin;
pub const sessionId = codec.sessionId;
pub const targetPath = codec.targetPath;
pub const convert = codec.convert;
pub const validate = codec.validate;
pub const registrationMatches = codec.registrationMatches;
pub const readNative = native.readNative;
pub const nativeFingerprint = native.nativeFingerprint;
pub const readOrigin = native.readOrigin;
pub const listThreads = native.listThreads;
pub const readEntries = native.readEntries;
pub const register = native.register;
pub const unregister = native.unregister;

test {
    _ = codec;
    _ = native;
    _ = @import("opencode/test.zig");
}
