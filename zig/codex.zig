const codec = @import("codex/codec.zig");
const native = @import("codex/native.zig");

pub const sessionId = codec.sessionId;
pub const targetPath = codec.targetPath;
pub const targetPathFor = codec.targetPathFor;
pub const convert = codec.convert;
pub const validate = codec.validate;
pub const registrationMatches = codec.registrationMatches;
pub const Origin = codec.Origin;
pub const readOrigin = codec.readOrigin;
pub const register = native.register;
pub const unregister = native.unregister;

test {
    _ = codec;
    _ = native;
}
