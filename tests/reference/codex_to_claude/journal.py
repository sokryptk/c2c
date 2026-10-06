from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
from typing import Any
import uuid

from .options import _direction

MANIFEST_VERSION = 1


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
    if manifest.get("codexHome") != str(options.codex_home) or manifest.get("claudeHome") != str(
        options.claude_home
    ):
        raise BridgeError(
            "This output directory belongs to different source or destination homes; choose another --output-dir"
        )
    if manifest.get("direction", "codex-to-claude") != _direction(options):
        raise BridgeError(
            "This output directory belongs to the opposite migration direction; choose another --output-dir"
        )
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
        retained.append(
            {
                key: record[key]
                for key in (
                    "sourceThreadId",
                    "sessionId",
                    "targetPath",
                    "undoBackupPath",
                    "sha256",
                    "undoneAt",
                )
                if key in record
            }
        )
