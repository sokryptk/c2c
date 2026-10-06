from __future__ import annotations

import copy
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
from pathlib import Path
from typing import Any, Iterable, Iterator
import uuid
import warnings

from .source import SourceError, SourceWarning, Thread, _records, _timestamp


@dataclass(frozen=True)
class ClaudeThread(Thread):
    original_codex_id: str | None = None
    unchanged_import: bool = False


def _digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _message_entry(entry: dict[str, Any]) -> bool:
    return entry.get("type") in ("user", "assistant") and isinstance(entry.get("message"), dict)


def _human_prompt(entry: dict[str, Any]) -> str:
    if entry.get("type") != "user" or entry.get("isMeta") or entry.get("isCompactSummary"):
        return ""
    content = entry.get("message", {}).get("content")
    if isinstance(content, str):
        text = content
    elif isinstance(content, list):
        if any(isinstance(block, dict) and block.get("type") == "tool_result" for block in content):
            return ""
        text = " ".join(
            block["text"]
            for block in content
            if isinstance(block, dict)
            and block.get("type") == "text"
            and isinstance(block.get("text"), str)
        )
    else:
        return ""
    return " ".join(text.split())[:200]


def _metadata(path: Path) -> dict[str, Any]:
    meta: dict[str, Any] = {"count": 0}
    for _, entry in _records(path):
        kind = entry.get("type")
        if kind == "custom-title" and isinstance(entry.get("customTitle"), str):
            meta["title"] = entry["customTitle"]
        elif kind == "ai-title" and isinstance(entry.get("aiTitle"), str):
            meta["ai_title"] = entry["aiTitle"]
        elif kind == "summary" and isinstance(entry.get("summary"), str):
            meta["summary"] = entry["summary"]
        elif kind == "c2c-import" and entry.get("source") == "codex":
            meta["provenance"] = entry
        if not _message_entry(entry):
            continue
        if entry.get("teamName") or entry.get("isMeta"):
            continue
        meta["count"] += 1
        if "sidechain" not in meta:
            meta["sidechain"] = bool(entry.get("isSidechain"))
        if isinstance(entry.get("cwd"), str) and entry["cwd"]:
            meta.setdefault("cwd", entry["cwd"])
        if isinstance(entry.get("sessionId"), str):
            meta["session_id"] = entry["sessionId"]
        if isinstance(entry.get("timestamp"), str):
            timestamp = _timestamp(entry["timestamp"])
            meta.setdefault("created_at", timestamp)
            meta["updated_at"] = timestamp
        if isinstance(entry.get("uuid"), str):
            meta["last_message_uuid"] = entry["uuid"]
        if not meta.get("first_prompt"):
            prompt = _human_prompt(entry)
            if prompt:
                meta["first_prompt"] = prompt
    return meta


def _manifest_thread(path: Path, record: dict[str, Any]) -> ClaudeThread:
    fallback = datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).isoformat(
        timespec="milliseconds"
    )
    return ClaudeThread(
        id=path.stem,
        title="Codex · " + (record.get("title") or record["sourceThreadId"]),
        cwd=record.get("cwd", ""),
        created_at=_timestamp(record.get("createdAt") or fallback),
        updated_at=_timestamp(record.get("updatedAt") or fallback),
        rollout_path=path,
        source="claude",
        history_mode="claude-native",
        original_codex_id=record["sourceThreadId"],
        unchanged_import=True,
    )


def list_claude_threads(
    home: str | Path,
    *,
    import_records: Iterable[dict[str, Any]] = (),
    include_imported: bool = False,
    include_subagents: bool = False,
) -> list[ClaudeThread]:
    root = Path(home).expanduser().resolve() / "projects"
    records = {
        record["sessionId"]: record
        for record in import_records
        if isinstance(record, dict) and record.get("sessionId")
    }
    paths = list(root.glob("*/*.jsonl"))
    if include_subagents:
        paths.extend(root.glob("*/*/subagents/**/*.jsonl"))
    threads: list[ClaudeThread] = []
    for path in sorted(set(paths)):
        subagent = len(path.relative_to(root).parts) > 2
        # Root transcript filenames are UUIDs. Subagents use agent-<id>.jsonl.
        if not subagent:
            try:
                uuid.UUID(path.stem)
            except ValueError:
                continue
        record = records.get(path.stem)
        try:
            # Legacy imports have no embedded marker; match the manifest hash.
            if record and record.get("sha256") and _digest(path) == record["sha256"]:
                if include_imported:
                    threads.append(_manifest_thread(path, record))
                continue
            meta = _metadata(path)
        except (OSError, SourceError) as error:
            warnings.warn(
                f"Cannot read Claude conversation {path}: {error}", SourceWarning, stacklevel=2
            )
            continue
        if not meta["count"] or (meta.get("sidechain") and not include_subagents):
            continue
        cwd = meta.get("cwd")
        if not cwd:
            warnings.warn(
                f"Claude conversation has no project directory: {path}", SourceWarning, stacklevel=2
            )
            continue
        origin = meta.get("provenance", {})
        original_codex_id = (record or {}).get("sourceThreadId") or origin.get("sourceThreadId")
        unchanged = bool(
            origin.get("lastMessageUuid")
            and origin["lastMessageUuid"] == meta.get("last_message_uuid")
        )
        if unchanged and not include_imported:
            continue
        timestamp = datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).isoformat(
            timespec="milliseconds"
        )
        parent_id = None
        identifier = path.stem
        if subagent:
            relative = path.relative_to(root)
            parent_id = relative.parts[1]
            subagent_path = relative.as_posix().split("/subagents/", 1)[-1]
            identifier = f"{parent_id}/{subagent_path[:-6]}"
        threads.append(
            ClaudeThread(
                id=identifier,
                title=meta.get("title")
                or meta.get("ai_title")
                or meta.get("summary")
                or meta.get("first_prompt")
                or f"Claude {identifier[:8]}",
                cwd=cwd,
                created_at=meta.get("created_at", _timestamp(timestamp)),
                updated_at=meta.get("updated_at", _timestamp(timestamp)),
                rollout_path=path,
                parent_id=parent_id,
                source="claude",
                history_mode="claude-native",
                original_codex_id=original_codex_id,
                unchanged_import=unchanged,
            )
        )
    return sorted(threads, key=lambda thread: (thread.updated_at, thread.id), reverse=True)


def _full_chain(entries: list[dict[str, Any]], *, sidechain: bool) -> list[dict[str, Any]]:
    indexed = {entry["uuid"]: entry for entry in entries if isinstance(entry.get("uuid"), str)}
    positions = {
        entry["uuid"]: index
        for index, entry in enumerate(entries)
        if isinstance(entry.get("uuid"), str)
    }
    parents = {entry.get("parentUuid") for entry in indexed.values() if entry.get("parentUuid")}
    leaves: list[dict[str, Any]] = []
    for identifier, terminal in indexed.items():
        if identifier in parents:
            continue
        current = terminal
        seen: set[str] = set()
        while current and current["uuid"] not in seen:
            seen.add(current["uuid"])
            if (
                _message_entry(current)
                and not current.get("isMeta")
                and not current.get("teamName")
                and (sidechain or not current.get("isSidechain"))
            ):
                leaves.append(current)
                break
            current = indexed.get(current.get("parentUuid"))
    if not leaves:
        if any(
            _message_entry(entry)
            and not entry.get("isMeta")
            and (sidechain or not entry.get("isSidechain"))
            for entry in indexed.values()
        ):
            raise SourceError("Claude conversation has no valid terminal parent chain")
        return []
    current = max(leaves, key=lambda entry: positions[entry["uuid"]])
    chain: list[dict[str, Any]] = []
    visited: set[str] = set()
    while current:
        identifier = current["uuid"]
        if identifier in visited:
            raise SourceError("Claude conversation contains a cyclic parent chain")
        visited.add(identifier)
        chain.append(current)
        parent = current.get("parentUuid")
        if (
            parent is None
            and current.get("type") == "system"
            and current.get("subtype") == "compact_boundary"
        ):
            # Compaction severs the active chain but links archived history here.
            parent = current.get("logicalParentUuid")
        if parent and parent not in indexed:
            warnings.warn(
                f"Claude conversation references an unavailable historical parent: {parent}",
                SourceWarning,
                stacklevel=2,
            )
        current = indexed.get(parent)
    return list(reversed(chain))


def read_claude_entries(thread: Thread) -> Iterator[dict[str, Any]]:
    """Yield the active branch with compaction history, excluding private thinking."""
    entries = [
        entry
        for _, entry in _records(thread.rollout_path)
        if isinstance(entry.get("uuid"), str)
        and entry.get("type") in ("user", "assistant", "system", "attachment", "progress")
    ]
    sidechain = thread.parent_id is not None
    for entry in _full_chain(entries, sidechain=sidechain):
        if entry.get("type") == "system" and entry.get("subtype") == "compact_boundary":
            yield {
                key: copy.deepcopy(value)
                for key, value in entry.items()
                if key
                in (
                    "type",
                    "subtype",
                    "uuid",
                    "parentUuid",
                    "logicalParentUuid",
                    "timestamp",
                    "sessionId",
                    "compactMetadata",
                )
            }
            continue
        if not _message_entry(entry) or entry.get("isMeta") or entry.get("teamName"):
            continue
        message = copy.deepcopy(entry["message"])
        content = message.get("content")
        if isinstance(content, list):
            content = [
                block
                for block in content
                if not (
                    isinstance(block, dict)
                    and block.get("type") in ("thinking", "redacted_thinking")
                )
            ]
            if not content:
                continue
            message["content"] = content
        elif not isinstance(content, str) or not content:
            continue
        result = {
            key: copy.deepcopy(value)
            for key, value in entry.items()
            if key
            in ("type", "uuid", "parentUuid", "timestamp", "sessionId", "isCompactSummary", "cwd")
        }
        result["message"] = message
        yield result
