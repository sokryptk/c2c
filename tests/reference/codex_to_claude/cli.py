from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import sys
from typing import Any
import uuid
import warnings


from .journal import (
    MANIFEST_VERSION as MANIFEST_VERSION,
    BridgeError,
    _atomic_json as _atomic_json,
    _digest,
    _error_details,
    _load_manifest,
    _lock,
    _manifest_path,
    _now,
    _private_directory,
    _remember_undo,
    _save,
    _sync_directory,
)
from .options import DIRECTIONS, _direction, _shared as _shared, parse_options


def _target_name(options) -> str:
    return "Claude" if _direction(options) == "codex-to-claude" else "Codex"


def _target_root(options) -> Path:
    if _direction(options) == "codex-to-claude":
        return options.claude_home / "projects"
    return options.codex_home / "sessions"


def _matches_project_prefix(candidate: str, project: str) -> bool:
    prefix = os.path.normpath(project)
    return candidate == prefix or candidate.startswith(prefix.rstrip(os.sep) + os.sep)


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
        if not any(
            _matches_project_prefix(candidate, project) for project in options.project_prefix
        ):
            return False
    return True


def _threads(options):
    if _direction(options) == "claude-to-codex":
        from .claude_source import list_claude_threads

        threads = list_claude_threads(
            options.claude_home,
            import_records=_origin_records(options),
            include_imported=True,
            include_subagents=options.include_subagents,
        )
    else:
        from .source import list_threads

        threads = list_threads(options.codex_home)
    return [thread for thread in threads if _selected(thread, options)]


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
            raise BridgeError(
                "Cannot read an existing origin manifest; restore it before detecting round trips"
            ) from error
        if manifest.get("direction", "codex-to-claude") != opposite:
            if path in explicit:
                raise BridgeError(
                    "--origin-manifest must describe the opposite migration direction"
                )
            continue
        if manifest.get("codexHome") != str(options.codex_home) or manifest.get(
            "claudeHome"
        ) != str(options.claude_home):
            if path in explicit:
                raise BridgeError("--origin-manifest belongs to different Codex or Claude homes")
            continue
        records.extend(
            record
            for record in manifest.get("imports", {}).values()
            if record.get("status") == "installed"
        )
    return records


def _already_origin(thread, origin_records: list[dict[str, Any]]) -> str | None:
    if getattr(thread, "unchanged_import", False):
        return (
            getattr(thread, "original_codex_id", None)
            or getattr(thread, "original_claude_id", None)
            or thread.id
        )
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
    if (
        not path.is_absolute()
        or path.is_symlink()
        or not path.parent.resolve().is_relative_to(root.resolve())
    ):
        raise BridgeError(
            "Destination escaped the configured "
            + _target_name(options)
            + " conversation directory"
        )
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

    result = {
        "sourceThreadId": record["sourceThreadId"],
        "sessionId": record.get("sessionId"),
        "targetPath": record.get("targetPath"),
    }
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
        row = _thread_info(thread)
        row["status"] = "already-origin" if original else "available"
        if original:
            row["originalThreadId"] = original
        rows.append(row)
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
            record["status"] = (
                "pending-registration" if _direction(options) == "claude-to-codex" else "installed"
            )
            record["installedAt"] = _now()
        elif target.exists():
            record["status"] = "collision"
        else:
            record["status"] = "staged"
        changed = True
    if changed:
        _save(options, manifest)
    for record in manifest["imports"].values():
        if record.get("status") in {
            "installed",
            "pending-registration",
            "staged",
            "collision",
        } and record.get("installTemporary"):
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
    if (
        not stage.resolve().is_relative_to(options.output_dir)
        or stage.is_symlink()
        or _digest(stage) != record["sha256"]
    ):
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
        record.update(
            status="pending-registration"
            if _direction(options) == "claude-to-codex"
            else "installed",
            installedAt=_now(),
        )
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
        raise BridgeError(
            "Native conversation changed after staging; preserved without another registration attempt"
        )
    record.update(status="registering", sourceConversionSha256=expected)
    _save(options, manifest)
    registration = register(options.codex_home, record["sessionId"], record["title"])
    entries = _read_entries(target)
    if validate(entries) or not registration_matches(staged, entries):
        raise BridgeError(
            "Native registration produced an unexpected conversation; preserved for inspection"
        )
    record.pop("registrationError", None)
    record.update(
        status="installed",
        registeredAt=_now(),
        nativeRegistration=registration,
        sha256=_digest(target),
    )
    _save(options, manifest)


def _source_stamp(thread) -> dict[str, Any]:
    path = Path(thread.rollout_path)
    try:
        stat = path.stat()
    except FileNotFoundError:
        # The projection database may retain history after the rollout is gone.
        return {"path": str(path), "missing": True, "updatedAt": thread.updated_at}
    return {
        "path": str(path),
        "bytes": stat.st_size,
        "mtimeNs": stat.st_mtime_ns,
        "updatedAt": thread.updated_at,
    }


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
            old_status = old.get("status") if old else None
            if old and old_status in {"pending-registration", "registering"}:
                pending.append((index, old))
                rows.append(
                    row
                    | {
                        "status": "pending-registration",
                        "sessionId": old["sessionId"],
                        "targetPath": old["targetPath"],
                    }
                )
                _progress(options, index, len(threads), identifier, "resuming native registration")
                continue
            if not old or old_status in {
                "error",
                "undone",
                "metadata-only",
                "already-origin",
            }:
                original = _already_origin(thread, origins)
                if original:
                    record = {
                        **_thread_info(thread),
                        "status": "already-origin",
                        "originalThreadId": original,
                    }
                    _remember_undo(manifest, old)
                    manifest["imports"][identifier] = record
                    _save(options, manifest)
                    rows.append(row | {"status": "already-origin", "originalThreadId": original})
                    _progress(options, index, len(threads), identifier, "already-origin")
                    continue
            # Do not reinstall a destination its owner continued or deleted.
            if old and old_status not in {
                "error",
                "undone",
                "metadata-only",
                "staged",
                "already-origin",
            }:
                status = _inspect(options, old)["status"]
                row.update(
                    status="unchanged" if status == "verified" else status,
                    sessionId=old.get("sessionId"),
                    targetPath=old.get("targetPath"),
                )
                try:
                    row["sourceChanged"] = _source_stamp(thread) != old.get("sourceStamp")
                except OSError:
                    row["sourceUnavailable"] = True
                rows.append(row)
                _progress(options, index, len(threads), identifier, row["status"])
                continue
            if old and old_status == "staged":
                pending.append((index, old))
                rows.append(
                    row
                    | {
                        "status": "staged",
                        "sessionId": old["sessionId"],
                        "targetPath": old["targetPath"],
                    }
                )
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
                    target = _safe_target(
                        options, options.claude_home / "projects" / encoded / f"{sid}.jsonl"
                    )
                with warnings.catch_warnings(record=True) as source_warnings:
                    warnings.simplefilter("always")
                    if _direction(options) == "claude-to-codex":
                        conversion = convert(
                            thread,
                            read_claude_entries(thread),
                            embed_images=not options.no_images,
                            transcript_path=str(target),
                        )
                    else:
                        conversion = convert(
                            thread,
                            read_items(thread, options.codex_home),
                            read_compaction(thread),
                            embed_images=not options.no_images,
                            transcript_path=str(target),
                        )
                conversion.warnings.extend(
                    f"{type(warning.message).__name__}: {warning.message}"
                    for warning in source_warnings
                )
                all_warnings.extend(conversion.warnings)
                if _source_stamp(thread) != stamp:
                    raise BridgeError(
                        "Source conversation changed during conversion; retry after it is idle"
                    )
                if conversion.session_id != sid:
                    raise BridgeError("Converter session identifier does not match destination")
                record = {
                    **_thread_info(thread),
                    "sourceStamp": stamp,
                    "sourceSha256": source_hash,
                    "sessionId": conversion.session_id,
                    "warnings": conversion.warnings,
                    "messageCount": conversion.message_count,
                    "toolCount": conversion.tool_count,
                    "sourceItemCount": conversion.source_item_count,
                }
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
                        stream.write(
                            json.dumps(entry, ensure_ascii=False, separators=(",", ":")) + "\n"
                        )
                    stream.flush()
                    os.fsync(stream.fileno())
                record.update(
                    status="staged",
                    stagePath=str(stage),
                    targetPath=str(target),
                    sha256=_digest(stage),
                )
                _remember_undo(manifest, old)
                manifest["imports"][identifier] = record
                _save(options, manifest)
                pending.append((index, record))
                rows.append(
                    row
                    | {
                        "status": "staged",
                        "sessionId": sid,
                        "targetPath": str(target),
                        "warningCount": len(conversion.warnings),
                    }
                )
                _progress(options, index, len(threads), identifier, "staged")
            except Exception as error:
                record = {
                    **_thread_info(thread),
                    "status": "error",
                    **_error_details(error),
                    "phase": "conversion",
                }
                if isinstance(error, (SourceError, ValueError)):
                    record["errorDetails"] = str(error)
                _remember_undo(manifest, old)
                manifest["imports"][identifier] = record
                _save(options, manifest)
                rows.append(
                    row | {"status": "error", **_error_details(error), "phase": "conversion"}
                )
                _progress(
                    options,
                    index,
                    len(threads),
                    identifier,
                    "conversion failed (" + type(error).__name__ + ")",
                )
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
                registration_failed = record.get("status") in {
                    "pending-registration",
                    "registering",
                }
                if registration_failed:
                    record["registrationError"] = {
                        "errorType": type(error).__name__,
                        "message": str(error),
                    }
                by_id[record["sourceThreadId"]].update(
                    status="error",
                    **_error_details(error),
                    phase="registration" if registration_failed else "installation",
                )
            _progress(
                options,
                index,
                len(threads),
                record["sourceThreadId"],
                by_id[record["sourceThreadId"]]["status"],
            )
        manifest["lastRun"] = {"at": _now(), "counts": _result(rows)["counts"], "results": rows}
        _save(options, manifest)
        return _result(
            rows,
            manifest=str(_manifest_path(options)),
            direction=_direction(options),
            warningCount=len(all_warnings),
            warningGroups=_warning_groups(all_warnings),
        )


def verify(options) -> dict[str, Any]:
    with _lock(options.output_dir):
        manifest = _load_manifest(options)
        _recover(options, manifest)
        rows = [
            _inspect(options, record)
            for record in manifest["imports"].values()
            if _selected(record, options)
        ]
        return _result(rows, manifest=str(_manifest_path(options)))


def list_imports(options) -> dict[str, Any]:
    with _lock(options.output_dir):
        manifest = _load_manifest(options)
        fields = (
            "sourceThreadId",
            "title",
            "cwd",
            "sessionId",
            "status",
            "targetPath",
            "messageCount",
            "toolCount",
            "warnings",
        )
        rows = []
        for record in manifest["imports"].values():
            if _selected(record, options):
                rows.append({key: record[key] for key in fields if key in record})
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
                rows.append(
                    row | {"status": "preserved", "reason": record.get("status", "not-installed")}
                )
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
                    backup = (
                        _safe_target(options, record["undoBackupPath"])
                        if record.get("undoBackupPath")
                        else target.with_name(f".codex-undo-{uuid.uuid4().hex}.retained")
                    )
                    record.update(status="undoing", undoBackupPath=str(backup))
                    _save(options, manifest)
                    if not backup.exists():
                        os.link(target, backup)
                        _sync_directory(target.parent)
                    stat = target.stat()
                    if (
                        not os.path.samefile(backup, target)
                        or _digest(target) != record["sha256"]
                        or target.stat() != stat
                    ):
                        record["status"] = "installed"
                        _save(options, manifest)
                        row.update(status="preserved", reason="changed-during-undo")
                    else:
                        if _direction(options) == "claude-to-codex":
                            from .codex_native import unregister

                            unregister(options.codex_home, record["sessionId"])
                            if target.exists():
                                raise BridgeError(
                                    "Codex did not remove its registered conversation"
                                )
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


def main(argv=None) -> int:
    options = parse_options(argv)
    try:
        result = {
            "inventory": inventory,
            "migrate": migrate,
            "verify": verify,
            "list": list_imports,
            "undo": undo,
        }[options.command](options)
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
            print(
                f"{row['sourceThreadId']}  {row['status']}  {row.get('sessionId') or row.get('title', '')}"
            )
        print(
            "; ".join(f"{count} {status}" for status, count in result["counts"].items())
            or "No matching threads"
        )
        for warning, count in result.get("warningGroups", {}).items():
            print(f"Warning ({count}): {warning}")
        if result.get("manifest"):
            print("Manifest: " + result["manifest"])
    if "error" in result or any(
        result.get("counts", {}).get(status)
        for status in ("error", "invalid", "collision", "missing", "pending-registration")
    ):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
