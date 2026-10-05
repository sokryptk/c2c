const std = @import("std");

fn is(code: []const u8, names: []const []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, code, name)) return true;
    return false;
}

pub fn reason(code: []const u8) []const u8 {
    if (is(code, &.{"UnknownProvider"})) return "Choose codex, claude, omp, or opencode as the provider.";
    if (is(code, &.{"UnknownCommand"})) return "Choose inventory, migrate, verify, list, or undo as the action.";
    if (is(code, &.{"UnknownOption"})) return "This option is not recognized. Check its spelling.";
    if (is(code, &.{"MissingOptionValue"})) return "Provide a value after each option that requires one.";
    if (is(code, &.{"MultipleActions"})) return "Use one action per command.";
    if (is(code, &.{"SameProvider"})) return "Choose different source and destination providers.";
    if (is(code, &.{"InvalidDirection"})) return "Use a direction such as codex-to-claude, or select --from and --to.";
    if (is(code, &.{"HomeNotFound"})) return "Set HOME so c2c can locate its default storage directories.";
    if (is(code, &.{"LockBusy"})) return "Another c2c operation is using this journal. Wait for it to finish, then retry.";
    if (is(code, &.{ "ManifestHomesMismatch", "OriginHomesMismatch" })) return "This journal belongs to different storage directories. Check the home flags and journal path.";
    if (is(code, &.{ "ManifestDirectionMismatch", "OriginDirectionMismatch" })) return "This journal belongs to a different migration direction. Check --from, --to, and the journal path.";
    if (is(code, &.{ "UnsupportedManifest", "InvalidOriginManifest" })) return "The migration journal cannot be read in this format. Inspect it before retrying.";
    if (is(code, &.{"SourceChangedDuringConversion"})) return "The source changed during conversion. Retry when that conversation is idle.";
    if (is(code, &.{ "MalformedSourceJson", "ExpectedSourceObject", "InvalidClaudeRecord", "MalformedOmpSession", "InvalidOmpHeader", "MalformedOpenCodeMessage", "SyntaxError", "UnexpectedToken" })) return "A conversation record is malformed. Inspect the file shown before retrying.";
    if (is(code, &.{ "InvalidClaudeParentChain", "CyclicClaudeParentChain", "CyclicOmpParentChain", "DuplicateOmpEntryId", "OmpEntryIdMissing" })) return "The source conversation has broken message links. Inspect its history before retrying.";
    if (is(code, &.{ "SourceFileUnavailable", "SourceHistoryUnavailable", "SourceReadFailed", "ProjectionPastRollout" })) return "The source history could not be read completely. Check its files and permissions before retrying.";
    if (is(code, &.{ "SourceSessionMissing", "OpenCodeSessionMissing" })) return "The source conversation is no longer available. Refresh the inventory and check the selected thread.";
    if (is(code, &.{ "UnsupportedStateSchema", "UnsupportedOpenCodeDatabaseSchema", "NativeDatabaseSchemaUnsupported" })) return "The app's database format is not supported by this c2c version. Check for a compatible c2c release.";
    if (is(code, &.{ "SourceDatabaseUnavailable", "SourceDatabaseQueryFailed", "OpenCodeDatabaseUnavailable", "OpenCodeSnapshotFailed", "OpenCodeQueryFailed", "NativeDatabaseReadFailed" })) return "The conversation database could not be read. Check the provider's home directory and database permissions.";
    if (is(code, &.{ "InvalidOmpImageBlob", "OmpImageBlobUnavailable" })) return "A source image attachment is missing or damaged. Check the source attachment files.";
    if (is(code, &.{ "CheckpointExceedsContextBudget", "OmpContextBudgetExceeded", "OpenCodeCheckpointBudgetExceeded" })) return "The conversation checkpoint exceeds the destination's context limit. A compatible conversion is required before import.";
    if (is(code, &.{ "NativeValidationFailed", "InvalidConvertedClaudeSession", "InvalidCodexRollout", "InvalidOmpRollout", "InvalidOpenCodeTransfer" })) return "The converted conversation failed validation. Inspect the migration journal before retrying.";
    if (is(code, &.{ "CodexNativeMigrationFailed", "CodexNativeRpcFailed", "CodexNativeServerEnded" })) return "Codex could not finish native registration. Check that the Codex CLI runs, then retry the same migration.";
    if (is(code, &.{"OpenCodeV2Required"})) return "OpenCode v2 is required. Check the installed CLI or C2C_OPENCODE_BINARY.";
    if (is(code, &.{ "OpenCodeNativeImportFailed", "OpenCodeImportDidNotCreateSession" })) return "OpenCode could not finish native registration. Check that its CLI runs, then retry the same migration.";
    if (is(code, &.{ "NativeSessionIdAlreadyBound", "OpenCodeSessionCollision", "AmbiguousNativeSessionPath" })) return "An existing native conversation uses this identity. Inspect it before retrying; c2c will not overwrite it.";
    if (is(code, &.{ "NativeConversationChanged", "NativeSessionChangedBeforeRegistration", "OpenCodeSessionChanged", "NativeReceiptChanged" })) return "The imported conversation changed. It has been preserved; inspect it before retrying.";
    if (is(code, &.{ "UnexpectedNativeRewrite", "CodexMigrationChangedConversationContent", "OpenCodeNativeImportMismatch" })) return "Native registration changed the conversation unexpectedly. Inspect the journal and destination before retrying.";
    if (is(code, &.{ "NativeRegistrationMissing", "NativeSessionPathMissing" })) return "Native registration is incomplete. Check the destination app and retry the same migration.";
    if (is(code, &.{ "CodexNativeRemovalFailed", "CodexNativeRemovalIncomplete", "OpenCodeNativeDeleteFailed", "NativeDeleteIncomplete" })) return "Native removal did not finish. Check the destination app and retry undo with the same journal.";
    if (is(code, &.{"OpenCodeSessionHasChildren"})) return "This OpenCode conversation has child sessions. c2c preserved it; review those sessions before undoing.";
    if (is(code, &.{ "UnsafeTargetPath", "UnsafeLockFile", "StagingIntegrityFailed", "SessionIdentityMismatch", "NativeSessionIdentityMismatch", "NativeSessionPathMismatch", "OpenCodeReceiptIdentityMismatch" })) return "A path or identity failed a safety check. Inspect the journal and files before retrying.";
    if (is(code, &.{"FileNotFound"})) return "A required file is missing. Check the paths shown.";
    if (is(code, &.{ "AccessDenied", "PrivateDirectoryFailed" })) return "A file or directory is not accessible. Check ownership and permissions.";
    if (is(code, &.{"PathAlreadyExists"})) return "The destination already exists. Check it before retrying; c2c will not overwrite it.";
    if (is(code, &.{ "NoSpaceLeft", "StageCreateFailed", "WriteFailed", "SyncFailed" })) return "Data could not be written safely. Check available disk space and directory permissions.";
    if (is(code, &.{"Timeout"})) return "The native operation timed out. Check the destination CLI before retrying.";
    return "The operation could not finish. Use the error code and migration journal to investigate before retrying.";
}

test "diagnostics offer concrete parser source and registration guidance" {
    try std.testing.expect(std.mem.indexOf(u8, reason("UnknownProvider"), "omp") != null);
    try std.testing.expect(std.mem.indexOf(u8, reason("MalformedSourceJson"), "malformed") != null);
    try std.testing.expect(std.mem.indexOf(u8, reason("SourceChangedDuringConversion"), "idle") != null);
    try std.testing.expect(std.mem.indexOf(u8, reason("CodexNativeMigrationFailed"), "Codex CLI") != null);
    try std.testing.expect(std.mem.indexOf(u8, reason("UnrecognizedFutureError"), "error code") != null);
}
