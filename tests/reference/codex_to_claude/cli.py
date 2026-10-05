from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
from typing import Any
import uuid
import warnings


MANIFEST_VERSION = 1
DIRECTIONS = ("codex-to-claude", "claude-to-codex")


def _direction(options) -> str:
    return getattr(options, "direction", DIRECTIONS[0])


def _target_name(options) -> str:
    return "Claude" if _direction(options) == "codex-to-claude" else "Codex"


def _target_root(options) -> Path:
    return options.claude_home / "projects" if _direction(options) == "codex-to-claude" else options.codex_home / "sessions"


class BridgeError(Exception):
    """An actionable error which is safe to display without transcript content."""


def _error_details(error: Exception) -> dict[str, Any]:
    details: dict[str, Any] = {"errorType": type(error).__name__}
    if isinstance(error, BridgeError):
        details["reason"] = str(error)
    elif isinstance(error, OSError) and error.errno:
        details.update(errno=error.errno, reason=os.strerror(error.errno))
    return details


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _private_directory(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not path.is_dir():
        raise BridgeError("Expected a directory")


def _sync_directory(path: Path) -> None:
    if os.name == "posix":
        descriptor = os.open(path, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)


def _atomic_json(path: Path, value: dict[str, Any]) -> None:
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, ensure_ascii=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        _sync_directory(path.parent)
    finally:
        temporary.unlink(missing_ok=True)


@contextmanager
def _lock(directory: Path):
    _private_directory(directory)
    if os.name == "posix":
        directory.chmod(0o700)
    lock_path = directory / ".lock"
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        if os.name == "posix":
            import fcntl

            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise BridgeError("Another migration operation is running") from error
        else:
            import msvcrt

            if os.fstat(descriptor).st_size == 0:
                os.write(descriptor, b"0")
            os.lseek(descriptor, 0, os.SEEK_SET)
            try:
                msvcrt.locking(descriptor, msvcrt.LK_NBLCK, 1)
            except OSError as error:
                raise BridgeError("Another migration operation is running") from error
        yield
    finally:
        os.close(descriptor)


def _manifest_path(options) -> Path:
    return options.output_dir / "manifest.json"


def _load_manifest(options) -> dict[str, Any]:
    path = _manifest_path(options)
    if not path.exists():
        return {
            "version": MANIFEST_VERSION,
            "createdAt": _now(),
            "codexHome": str(options.codex_home),
            "claudeHome": str(options.claude_home),
            "direction": _direction(options),
            "imports": {},
        }
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise BridgeError("Cannot read migration manifest; preserve it for recovery") from error
    if manifest.get("version") != MANIFEST_VERSION or not isinstance(manifest.get("imports"), dict):
        raise BridgeError("Unsupported migration manifest")
    if manifest.get("codexHome") != str(options.codex_home) or manifest.get("claudeHome") != str(options.claude_home):
        raise BridgeError("This output directory belongs to different source or destination homes; choose another --output-dir")
    if manifest.get("direction", "codex-to-claude") != _direction(options):
        raise BridgeError("This output directory belongs to the opposite migration direction; choose another --output-dir")
    return manifest


def _save(options, manifest: dict[str, Any]) -> None:
    manifest["updatedAt"] = _now()
    _atomic_json(_manifest_path(options), manifest)


def _remember_undo(manifest: dict[str, Any], record: dict[str, Any] | None) -> None:
    """Keep backup provenance when a previously undone source is reimported."""
    if not record or not record.get("undoBackupPath"):
        return
    retained = manifest.setdefault("retainedUndos", [])
    if not any(entry["undoBackupPath"] == record["undoBackupPath"] for entry in retained):
        retained.append({key: record[key] for key in ("sourceThreadId", "sessionId", "targetPath", "undoBackupPath", "sha256", "undoneAt") if key in record})


def _selected(thread, options) -> bool:
    identifier = thread.id if hasattr(thread, "id") else thread["sourceThreadId"]
    cwd = thread.cwd if hasattr(thread, "cwd") else thread.get("cwd", "")
    if options.thread and identifier not in options.thread:
        return False
    if options.project:
        candidate = os.path.normpath(cwd)
        if not any(candidate == os.path.normpath(project) for project in options.project):
            return False
    if options.project_prefix:
        candidate = os.path.normpath(cwd)
        if not any(candidate == os.path.normpath(project) or candidate.startswith(os.path.normpath(project).rstrip(os.sep) + os.sep) for project in options.project_prefix):
            return False
    return True


def _threads(options):
    if _direction(options) == "claude-to-codex":
        from .claude_source import list_claude_threads

        return [thread for thread in list_claude_threads(options.claude_home, import_records=_origin_records(options), include_imported=True, include_subagents=options.include_subagents) if _selected(thread, options)]
    from .source import list_threads

    return [thread for thread in list_threads(options.codex_home) if _selected(thread, options)]


def _thread_info(thread) -> dict[str, Any]:
    result = {
        "sourceThreadId": thread.id,
        "title": thread.title,
        "cwd": thread.cwd,
        "createdAt": thread.created_at,
        "updatedAt": thread.updated_at,
        "parentId": thread.parent_id,
        "archived": thread.archived,
        "source": thread.source,
        "historyMode": thread.history_mode,
    }
    if getattr(thread, "original_codex_id", None):
        result["originalCodexId"] = thread.original_codex_id
    if getattr(thread, "original_claude_id", None):
        result["originalClaudeId"] = thread.original_claude_id
    return result


def _origin_records(options) -> list[dict[str, Any]]:
    """Load only opposite-direction journals for these same two homes."""
    opposite = DIRECTIONS[1] if _direction(options) == DIRECTIONS[0] else DIRECTIONS[0]
    candidates = [Path.home() / ".local" / "share" / "c2c" / opposite / "manifest.json"]
    if opposite == "codex-to-claude":
        candidates.append(Path.home() / ".local" / "share" / "codex-to-claude" / "manifest.json")
    explicit = [Path(path).expanduser().resolve() for path in options.origin_manifest]
    candidates.extend(explicit)
    records = []
    for path in dict.fromkeys(candidates):
        if not path.exists() and path not in explicit:
            continue
        try:
            manifest = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise BridgeError("Cannot read an existing origin manifest; restore it before detecting round trips") from error
        if manifest.get("direction", "codex-to-claude") != opposite:
            if path in explicit:
                raise BridgeError("--origin-manifest must describe the opposite migration direction")
            continue
        if manifest.get("codexHome") != str(options.codex_home) or manifest.get("claudeHome") != str(options.claude_home):
            if path in explicit:
                raise BridgeError("--origin-manifest belongs to different Codex or Claude homes")
            continue
        records.extend(record for record in manifest.get("imports", {}).values() if record.get("status") == "installed")
    return records


def _already_origin(thread, origin_records: list[dict[str, Any]]) -> str | None:
    if getattr(thread, "unchanged_import", False):
        return getattr(thread, "original_codex_id", None) or getattr(thread, "original_claude_id", None) or thread.id
    for record in origin_records:
        if record.get("sessionId") != thread.id or not record.get("sha256"):
            continue
        try:
            if _digest(Path(thread.rollout_path)) == record["sha256"]:
                return record["sourceThreadId"]
        except OSError:
            continue
    return None


def _progress(options, index: int, total: int, identifier: str, status: str) -> None:
    print(f"[{index}/{total}] {identifier}: {status}", file=sys.stderr, flush=True)


def _result(rows: list[dict[str, Any]], **extra) -> dict[str, Any]:
    counts: dict[str, int] = {}
    for row in rows:
        status = row["status"]
        counts[status] = counts.get(status, 0) + 1
    return {"counts": counts, "threads": rows, **extra}


def _warning_groups(messages: list[str]) -> dict[str, int]:
    groups: dict[str, int] = {}
    for message in messages:
        # Keep attachment paths in the private manifest, out of CLI summaries.
        group = message.split(": ", 1)[0]
        groups[group] = groups.get(group, 0) + 1
    return groups


def _safe_target(options, target: str | Path) -> Path:
    path = Path(target)
    root = _target_root(options)
    if not path.is_absolute() or path.is_symlink() or not path.parent.resolve().is_relative_to(root.resolve()):
        raise BridgeError("Destination escaped the configured " + _target_name(options) + " conversation directory")
    return path


def _read_entries(path: Path) -> list[dict[str, Any]]:
    entries = []
    with path.open(encoding="utf-8") as stream:
        for line in stream:
            if line.strip():
                entry = json.loads(line)
                if not isinstance(entry, dict):
                    raise ValueError("Conversation records must be objects")
                entries.append(entry)
    return entries


def _inspect(options, record: dict[str, Any]) -> dict[str, Any]:
    if _direction(options) == "claude-to-codex":
        from .codex_native import validate
    else:
        from .native import validate

    result = {"sourceThreadId": record["sourceThreadId"], "sessionId": record.get("sessionId"), "targetPath": record.get("targetPath")}
    if record.get("status") in {"metadata-only", "undone", "error", "collision", "already-origin"}:
        return {**result, "status": record["status"]}
    if record.get("status") in {"pending-registration", "registering"}:
        return {**result, "status": "pending-registration"}
    if not record.get("targetPath"):
        return {**result, "status": "not-installed"}
    try:
        target = _safe_target(options, record["targetPath"])
        if not target.exists():
            return {**result, "status": "missing"}
        errors = validate(_read_entries(target))
        if errors:
            return {**result, "status": "invalid", "validationErrors": errors}
        unchanged = _digest(target) == record["sha256"]
        return {**result, "status": "verified" if unchanged else "continued"}
    except Exception as error:
        return {**result, "status": "error", **_error_details(error)}


def inventory(options) -> dict[str, Any]:
    origins = _origin_records(options)
    rows = []
    for thread in _threads(options):
        original = _already_origin(thread, origins)
        rows.append({**_thread_info(thread), "status": "already-origin" if original else "available", **({"originalThreadId": original} if original else {})})
    return _result(rows, direction=_direction(options))


def _recover(options, manifest: dict[str, Any]) -> None:
    """Reconcile only files whose retained hard link proves installation ownership."""
    changed = False
    for record in manifest["imports"].values():
        if record.get("status") == "undoing":
            target = _safe_target(options, record["targetPath"])
            backup = _safe_target(options, record["undoBackupPath"])
            if _direction(options) == "claude-to-codex" and backup.exists() and not target.exists():
                from .codex_native import unregister

                unregister(options.codex_home, record["sessionId"])
            record["status"] = "undone" if backup.exists() and not target.exists() else "installed"
            if record["status"] == "undone":
                record["undoneAt"] = _now()
            changed = True
            continue
        if record.get("status") != "installing":
            continue
        target = _safe_target(options, record["targetPath"])
        temporary = _safe_target(options, record["installTemporary"])
        same_file = target.exists() and temporary.exists() and os.path.samefile(target, temporary)
        if same_file:
            record["status"] = "pending-registration" if _direction(options) == "claude-to-codex" else "installed"
            record["installedAt"] = _now()
        elif target.exists():
            record["status"] = "collision"
        else:
            record["status"] = "staged"
        changed = True
    if changed:
        _save(options, manifest)
    for record in manifest["imports"].values():
        if record.get("status") in {"installed", "pending-registration", "staged", "collision"} and record.get("installTemporary"):
            temporary = _safe_target(options, record["installTemporary"])
            temporary.unlink(missing_ok=True)
            record.pop("installTemporary", None)
            changed = True
    if changed:
        _save(options, manifest)


def _install(options, manifest: dict[str, Any], record: dict[str, Any]) -> None:
    target = _safe_target(options, record["targetPath"])
    _private_directory(target.parent)
    _safe_target(options, target)
    if target.exists() or target.is_symlink():
        record["status"] = "collision"
        _save(options, manifest)
        return
    stage = Path(record["stagePath"])
    if not stage.resolve().is_relative_to(options.output_dir) or stage.is_symlink() or _digest(stage) != record["sha256"]:
        raise BridgeError("Staged conversation failed its integrity check")
    temporary = target.with_name(f".codex-import-{uuid.uuid4().hex}.tmp")
    record.update(status="installing", installTemporary=str(temporary))
    _save(options, manifest)
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as stream, stage.open("rb") as source:
        shutil.copyfileobj(source, stream, length=1024 * 1024)
        stream.flush()
        os.fsync(stream.fileno())
    try:
        os.link(temporary, target)
    except FileExistsError:
        record["status"] = "collision"
    else:
        _sync_directory(target.parent)
        record.update(status="pending-registration" if _direction(options) == "claude-to-codex" else "installed", installedAt=_now())
    # Retain the hard link until the journal is durable so crash recovery can
    # distinguish our installation from a collision.
    _save(options, manifest)
    temporary.unlink(missing_ok=True)
    record.pop("installTemporary", None)
    _save(options, manifest)


def _complete_registration(options, manifest: dict[str, Any], record: dict[str, Any]) -> None:
    from .codex_native import register, registration_matches, validate

    target = _safe_target(options, record["targetPath"])
    stage = Path(record["stagePath"])
    if stage.is_symlink() or not stage.resolve().is_relative_to(options.output_dir):
        raise BridgeError("Registration source escaped the private staging directory")
    expected = record.get("sourceConversionSha256", record["sha256"])
    if _digest(stage) != expected:
        raise BridgeError("Staged conversation changed before native registration")
    staged = _read_entries(stage)
    if not registration_matches(staged, _read_entries(target)):
        raise BridgeError("Native conversation changed after staging; preserved without another registration attempt")
    record.update(status="registering", sourceConversionSha256=expected)
    _save(options, manifest)
    registration = register(options.codex_home, record["sessionId"], record["title"])
    entries = _read_entries(target)
    if validate(entries) or not registration_matches(staged, entries):
        raise BridgeError("Native registration produced an unexpected conversation; preserved for inspection")
    record.pop("registrationError", None)
    record.update(status="installed", registeredAt=_now(), nativeRegistration=registration, sha256=_digest(target))
    _save(options, manifest)


def _source_stamp(thread) -> dict[str, Any]:
    path = Path(thread.rollout_path)
    try:
        stat = path.stat()
    except FileNotFoundError:
        # The projection database may retain history after the rollout is gone.
        return {"path": str(path), "missing": True, "updatedAt": thread.updated_at}
    return {"path": str(path), "bytes": stat.st_size, "mtimeNs": stat.st_mtime_ns, "updatedAt": thread.updated_at}


def migrate(options) -> dict[str, Any]:
    if _direction(options) == "claude-to-codex":
        from .codex_native import convert, session_id, target_path, validate
        from .claude_source import read_claude_entries
    else:
        from .native import convert, project_directory, session_id, validate
    from .source import SourceError, read_compaction, read_items

    with _lock(options.output_dir):
        manifest = _load_manifest(options)
        _recover(options, manifest)
        threads = _threads(options)
        origins = _origin_records(options)
        run_directory = options.output_dir / "staged" / uuid.uuid4().hex
        _private_directory(run_directory)
        rows = []
        pending = []
        all_warnings = []
        for index, thread in enumerate(threads, 1):
            identifier = thread.id
            old = manifest["imports"].get(identifier)
            row = {"sourceThreadId": identifier}
            if old and old.get("status") in {"pending-registration", "registering"}:
                pending.append((index, old))
                rows.append(row | {"status": "pending-registration", "sessionId": old["sessionId"], "targetPath": old["targetPath"]})
                _progress(options, index, len(threads), identifier, "resuming native registration")
                continue
            if not old or old.get("status") in {"error", "undone", "metadata-only", "already-origin"}:
                original = _already_origin(thread, origins)
                if original:
                    record = {**_thread_info(thread), "status": "already-origin", "originalThreadId": original}
                    _remember_undo(manifest, old)
                    manifest["imports"][identifier] = record
                    _save(options, manifest)
                    rows.append(row | {"status": "already-origin", "originalThreadId": original})
                    _progress(options, index, len(threads), identifier, "already-origin")
                    continue
            # Do not reinstall a destination its owner continued or deleted.
            if old and old.get("status") not in {"error", "undone", "metadata-only", "staged", "already-origin"}:
                status = _inspect(options, old)["status"]
                row.update(status="unchanged" if status == "verified" else status, sessionId=old.get("sessionId"), targetPath=old.get("targetPath"))
                try:
                    row["sourceChanged"] = _source_stamp(thread) != old.get("sourceStamp")
                except OSError:
                    row["sourceUnavailable"] = True
                rows.append(row)
                _progress(options, index, len(threads), identifier, row["status"])
                continue
            if old and old.get("status") == "staged":
                pending.append((index, old))
                rows.append(row | {"status": "staged", "sessionId": old["sessionId"], "targetPath": old["targetPath"]})
                _progress(options, index, len(threads), identifier, "resuming staged import")
                continue
            try:
                stamp = _source_stamp(thread)
                source_hash = None if stamp.get("missing") else _digest(Path(thread.rollout_path))
                sid = str(uuid.UUID(session_id(thread.id)))
                if _direction(options) == "claude-to-codex":
                    target = _safe_target(options, target_path(thread, options.codex_home))
                else:
                    encoded = project_directory(thread.cwd)
                    if not encoded or encoded in {".", ".."} or Path(encoded).name != encoded:
                        raise BridgeError("Invalid encoded project directory")
                    target = _safe_target(options, options.claude_home / "projects" / encoded / f"{sid}.jsonl")
                with warnings.catch_warnings(record=True) as source_warnings:
                    warnings.simplefilter("always")
                    if _direction(options) == "claude-to-codex":
                        conversion = convert(thread, read_claude_entries(thread), embed_images=not options.no_images, transcript_path=str(target))
                    else:
                        conversion = convert(thread, read_items(thread, options.codex_home), read_compaction(thread), embed_images=not options.no_images, transcript_path=str(target))
                conversion.warnings.extend(f"{type(warning.message).__name__}: {warning.message}" for warning in source_warnings)
                all_warnings.extend(conversion.warnings)
                if _source_stamp(thread) != stamp:
                    raise BridgeError("Source conversation changed during conversion; retry after it is idle")
                if conversion.session_id != sid:
                    raise BridgeError("Converter session identifier does not match destination")
                record = {**_thread_info(thread), "sourceStamp": stamp, "sourceSha256": source_hash, "sessionId": conversion.session_id, "warnings": conversion.warnings, "messageCount": conversion.message_count, "toolCount": conversion.tool_count, "sourceItemCount": conversion.source_item_count}
                if conversion.message_count == 0:
                    record["status"] = "metadata-only"
                    _remember_undo(manifest, old)
                    manifest["imports"][identifier] = record
                    _save(options, manifest)
                    rows.append(row | {"status": "metadata-only"})
                    _progress(options, index, len(threads), identifier, "metadata-only")
                    continue
                errors = validate(conversion.entries)
                if errors:
                    raise BridgeError("Converted conversation failed native validation")
                stage = run_directory / f"{sid}.jsonl"
                descriptor = os.open(stage, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                    for entry in conversion.entries:
                        stream.write(json.dumps(entry, ensure_ascii=False, separators=(",", ":")) + "\n")
                    stream.flush()
                    os.fsync(stream.fileno())
                record.update(status="staged", stagePath=str(stage), targetPath=str(target), sha256=_digest(stage))
                _remember_undo(manifest, old)
                manifest["imports"][identifier] = record
                _save(options, manifest)
                pending.append((index, record))
                rows.append(row | {"status": "staged", "sessionId": sid, "targetPath": str(target), "warningCount": len(conversion.warnings)})
                _progress(options, index, len(threads), identifier, "staged")
            except Exception as error:
                record = {**_thread_info(thread), "status": "error", **_error_details(error), "phase": "conversion"}
                if isinstance(error, (SourceError, ValueError)):
                    record["errorDetails"] = str(error)
                _remember_undo(manifest, old)
                manifest["imports"][identifier] = record
                _save(options, manifest)
                rows.append(row | {"status": "error", **_error_details(error), "phase": "conversion"})
                _progress(options, index, len(threads), identifier, "conversion failed (" + type(error).__name__ + ")")
        # No destination is touched until all selected sources have been staged.
        by_id = {row["sourceThreadId"]: row for row in rows}
        for index, record in pending:
            try:
                if record["status"] == "staged":
                    _install(options, manifest, record)
                if record["status"] in {"pending-registration", "registering"}:
                    _complete_registration(options, manifest, record)
                by_id[record["sourceThreadId"]]["status"] = record["status"]
            except Exception as error:
                # Preserve an installing journal and its hardlink for recovery.
                registration_failed = record.get("status") in {"pending-registration", "registering"}
                if registration_failed:
                    record["registrationError"] = {"errorType": type(error).__name__, "message": str(error)}
                by_id[record["sourceThreadId"]].update(status="error", **_error_details(error), phase="registration" if registration_failed else "installation")
            _progress(options, index, len(threads), record["sourceThreadId"], by_id[record["sourceThreadId"]]["status"])
        manifest["lastRun"] = {"at": _now(), "counts": _result(rows)["counts"], "results": rows}
        _save(options, manifest)
        return _result(rows, manifest=str(_manifest_path(options)), direction=_direction(options), warningCount=len(all_warnings), warningGroups=_warning_groups(all_warnings))


def verify(options) -> dict[str, Any]:
    with _lock(options.output_dir):
        manifest = _load_manifest(options)
        _recover(options, manifest)
        rows = [_inspect(options, record) for record in manifest["imports"].values() if _selected(record, options)]
        return _result(rows, manifest=str(_manifest_path(options)))


def list_imports(options) -> dict[str, Any]:
    with _lock(options.output_dir):
        manifest = _load_manifest(options)
        rows = [{key: record[key] for key in ("sourceThreadId", "title", "cwd", "sessionId", "status", "targetPath", "messageCount", "toolCount", "warnings") if key in record} for record in manifest["imports"].values() if _selected(record, options)]
        return _result(rows, manifest=str(_manifest_path(options)))


def undo(options) -> dict[str, Any]:
    with _lock(options.output_dir):
        manifest = _load_manifest(options)
        _recover(options, manifest)
        rows = []
        for record in manifest["imports"].values():
            if not _selected(record, options):
                continue
            row = {"sourceThreadId": record["sourceThreadId"]}
            if record.get("status") != "installed":
                rows.append(row | {"status": "preserved", "reason": record.get("status", "not-installed")})
                continue
            try:
                target = _safe_target(options, record["targetPath"])
                if not target.exists():
                    row["status"] = "missing"
                elif _digest(target) != record["sha256"]:
                    row.update(status="preserved", reason="continued-or-modified")
                else:
                    # Retain the inode so concurrent appends through open file
                    # descriptors reach the backup after the native path is gone.
                    backup = _safe_target(options, record["undoBackupPath"]) if record.get("undoBackupPath") else target.with_name(f".codex-undo-{uuid.uuid4().hex}.retained")
                    record.update(status="undoing", undoBackupPath=str(backup))
                    _save(options, manifest)
                    if not backup.exists():
                        os.link(target, backup)
                        _sync_directory(target.parent)
                    stat = target.stat()
                    if not os.path.samefile(backup, target) or _digest(target) != record["sha256"] or target.stat() != stat:
                        record["status"] = "installed"
                        _save(options, manifest)
                        row.update(status="preserved", reason="changed-during-undo")
                    else:
                        if _direction(options) == "claude-to-codex":
                            from .codex_native import unregister

                            unregister(options.codex_home, record["sessionId"])
                            if target.exists():
                                raise BridgeError("Codex did not remove its registered conversation")
                        else:
                            target.unlink()
                        _sync_directory(target.parent)
                        record.update(status="undone", undoneAt=_now())
                        _save(options, manifest)
                        row.update(status="undone", retainedPath=str(backup))
            except Exception as error:
                row.update(status="error", **_error_details(error))
            rows.append(row)
        return _result(rows, manifest=str(_manifest_path(options)))


def _shared(parser, suppress=False) -> None:
    def default(value):
        return argparse.SUPPRESS if suppress else value

    parser.add_argument("--codex-home", type=Path, default=default(Path.home() / ".codex"))
    parser.add_argument("--claude-home", type=Path, default=default(Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude")))))
    parser.add_argument("--output-dir", type=Path, default=default(None), help="private staging and migration manifest directory")
    parser.add_argument("--direction", choices=DIRECTIONS, default=default(DIRECTIONS[0]))
    parser.add_argument("--origin-manifest", type=Path, action="append", default=default([]), help="opposite-direction manifest for detecting round trips; repeatable")
    parser.add_argument("--include-subagents", action="store_true", default=default(False), help="include Claude subagent sessions")
    parser.add_argument("--project", action="append", default=default([]), help="filter by exact project cwd; repeatable")
    parser.add_argument("--project-prefix", action="append", default=default([]), help="filter by project cwd and descendants; repeatable")
    parser.add_argument("--thread", action="append", default=default([]), help="filter by source thread ID; repeatable")
    parser.add_argument("--json", action="store_true", default=default(False), help="write machine-readable summary to stdout")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="c2c", description="Move conversations between native Codex and Claude Code sessions.")
    _shared(parser)
    commands = parser.add_subparsers(dest="command", required=True)
    for name, help_text in (("inventory", "discover source threads"), ("migrate", "stage and install native sessions without overwriting"), ("verify", "validate imported sessions and detect continuations"), ("list", "list recorded imports"), ("undo", "remove imports only when they have not changed")):
        subparser = commands.add_parser(name, help=help_text)
        _shared(subparser, suppress=True)
        if name == "migrate":
            subparser.add_argument("--no-images", action="store_true", help="preserve image references without embedding image bytes")
    for direction in DIRECTIONS:
        subparser = commands.add_parser(direction, help="migrate in this direction; optionally choose another action")
        _shared(subparser, suppress=True)
        subparser.add_argument("action", nargs="?", choices=("inventory", "migrate", "verify", "list", "undo"), default="migrate")
        subparser.add_argument("--no-images", action="store_true", help="preserve image references without embedding image bytes")
    options = parser.parse_args(argv)
    if options.command in DIRECTIONS:
        options.direction = options.command
        options.command = options.action
    if options.output_dir is None:
        legacy = Path.home() / ".local" / "share" / "codex-to-claude"
        options.output_dir = legacy if options.direction == "codex-to-claude" and (legacy / "manifest.json").exists() else Path.home() / ".local" / "share" / "c2c" / options.direction
    for field in ("codex_home", "claude_home", "output_dir"):
        setattr(options, field, getattr(options, field).expanduser().resolve())
    try:
        result = {"inventory": inventory, "migrate": migrate, "verify": verify, "list": list_imports, "undo": undo}[options.command](options)
    except BridgeError as error:
        result = {"error": str(error)}
    except Exception as error:
        result = {"error": "Operation failed", "errorType": type(error).__name__}
    if options.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    elif "error" in result:
        print(result["error"], file=sys.stderr)
    else:
        for row in result["threads"]:
            print(f"{row['sourceThreadId']}  {row['status']}  {row.get('sessionId') or row.get('title', '')}")
        print("; ".join(f"{count} {status}" for status, count in result["counts"].items()) or "No matching threads")
        for warning, count in result.get("warningGroups", {}).items():
            print(f"Warning ({count}): {warning}")
        if result.get("manifest"):
            print("Manifest: " + result["manifest"])
    if "error" in result or any(result.get("counts", {}).get(status) for status in ("error", "invalid", "collision", "missing", "pending-registration")):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
