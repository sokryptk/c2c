"""Prefer display projections; use rollouts for legacy history and live tails."""
from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass, replace
from datetime import datetime, timezone
import json
import mimetypes
import os
from pathlib import Path
import re
import sqlite3
from typing import Any, Iterator
from urllib.parse import unquote, urlsplit
import warnings


class SourceError(ValueError):
    """A source record cannot be imported without losing information."""


class SourceWarning(UserWarning):
    """A recoverable source issue, including an incomplete live final line."""


@dataclass(frozen=True)
class Thread:
    id: str
    title: str
    cwd: str
    created_at: str
    updated_at: str
    rollout_path: Path
    parent_id: str | None = None
    source: str = "cli"
    archived: bool = False
    history_mode: str = "legacy"
    original_claude_id: str | None = None
    unchanged_import: bool = False


@dataclass(frozen=True)
class Item:
    id: str
    role: str
    text: str
    timestamp: str
    kind: str
    attachments: tuple[dict[str, Any], ...] = ()
    raw: dict[str, Any] | None = None
    ordinal: int = 0


@dataclass(frozen=True)
class Compaction:
    summary: str
    items: tuple[Item, ...]
    timestamp: str | None
    ordinal: int
    encrypted: bool = False

    @property
    def last_ordinal(self) -> int:
        return self.ordinal


def _timestamp(value: Any, *, milliseconds: bool = False) -> str:
    if value is None or value == "":
        return "1970-01-01T00:00:00.000Z"
    try:
        if isinstance(value, (float, int)):
            seconds = value / 1000 if milliseconds or abs(value) >= 100_000_000_000 else value
            dt = datetime.fromtimestamp(seconds, timezone.utc)
        else:
            dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    except (ValueError, OverflowError, TypeError) as exc:
        raise SourceError("Invalid source timestamp") from exc


def _latest_database(home: Path, stem: str) -> Path | None:
    versions = []
    for path in home.glob(f"{stem}_*.sqlite"):
        match = re.fullmatch(rf"{re.escape(stem)}_(\d+)\.sqlite", path.name)
        if match:
            versions.append((int(match[1]), path))
    return max(versions)[1] if versions else None


@contextmanager
def _database(path: Path):
    # mode=ro preserves WAL visibility, unlike immutable=1, and cannot create DBs.
    connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA query_only=ON")
    try:
        connection.execute("BEGIN")
        yield connection
    finally:
        connection.close()


def _tables(connection: sqlite3.Connection) -> set[str]:
    return {r[0] for r in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}


def _json(value: str | bytes, location: str) -> dict[str, Any]:
    try:
        result = json.loads(value)
    except (ValueError, UnicodeError) as exc:
        raise SourceError(f"Malformed JSON at {location}") from exc
    if not isinstance(result, dict):
        raise SourceError(f"Expected JSON object at {location}")
    return result


def _records(path: Path, *, start_offset: int = 0, start_ordinal: int = 0,
             compactions_only: bool = False) -> Iterator[tuple[int, dict[str, Any]]]:
    """Read a fixed-size snapshot, so an active source cannot grow this iterator."""
    with path.open("rb") as stream:
        end = os.fstat(stream.fileno()).st_size
        if start_offset > end:
            raise SourceError(f"Projection offset exceeds rollout size: {path}")
        stream.seek(start_offset)
        index = start_ordinal
        while stream.tell() < end:
            line = stream.readline(end - stream.tell())
            current = index
            index += 1
            if not line.strip():
                continue
            # Compactions are sparse in multi-GB rollouts. Avoid decoding other
            # payloads (especially tool images) when finding the active context.
            if compactions_only and not re.search(rb'"type"\s*:\s*"compacted"', line[:512]):
                continue
            try:
                record = _json(line, f"{path}: record {current}")
            except SourceError:
                if stream.tell() == end and not line.endswith(b"\n"):
                    warnings.warn(f"Incomplete final rollout record in {path}; retry after the writer finishes",
                                  SourceWarning, stacklevel=2)
                    break
                raise
            yield int(record.get("ordinal", current)), record


def _metadata(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    # Session metadata is the first rollout record.
    records = _records(path)
    try:
        _, first = next(records)
        return first.get("payload", {}) if first.get("type") == "session_meta" else {}
    except StopIteration:
        return {}
    finally:
        records.close()


def _source_parent(source: Any) -> str | None:
    if isinstance(source, str):
        try:
            source = json.loads(source)
        except ValueError:
            return None
    if isinstance(source, dict):
        subagent = source.get("subagent")
        if isinstance(subagent, dict):
            spawn = subagent.get("thread_spawn")
            if isinstance(spawn, dict):
                return spawn.get("parent_thread_id")
    return None


def _rollout_path(value: str, home: Path) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        return home / path
    if path.exists():
        return path
    # Exports may have moved to a different home directory. Recover paths within
    # sessions/ or archived_sessions/ without traversing arbitrary directories.
    for directory in ("sessions", "archived_sessions"):
        if directory in path.parts:
            candidate = home.joinpath(*path.parts[path.parts.index(directory):])
            if candidate.exists():
                return candidate
    return path


def list_threads(codex_home: str | Path) -> list[Thread]:
    home = Path(codex_home).expanduser().resolve()
    threads: dict[str, Thread] = {}
    database = _latest_database(home, "state")
    if database:
        with _database(database) as connection:
            tables = _tables(connection)
            if "threads" not in tables:
                raise SourceError(f"Unsupported state schema: {database}")
            parents = {}
            if "thread_spawn_edges" in tables:
                parents = {r[0]: r[1] for r in connection.execute(
                    "SELECT child_thread_id, parent_thread_id FROM thread_spawn_edges")}
            for row in connection.execute("SELECT * FROM threads"):
                data = dict(row)
                path = _rollout_path(data["rollout_path"], home)
                parent = parents.get(data["id"]) or _source_parent(data.get("source"))
                if not parent:
                    meta = _metadata(path)
                    parent = meta.get("forked_from_id") or meta.get("parent_thread_id")
                created = data.get("created_at_ms")
                updated = data.get("updated_at_ms")
                threads[data["id"]] = Thread(
                    id=data["id"], title=data.get("name") or data.get("title") or f"Codex {data['id']}",
                    cwd=data.get("cwd", ""), rollout_path=path,
                    created_at=_timestamp(created if created is not None else data.get("created_at"), milliseconds=created is not None),
                    updated_at=_timestamp(updated if updated is not None else data.get("updated_at"), milliseconds=updated is not None),
                    parent_id=parent, source=data.get("source", "cli"),
                    archived=bool(data.get("archived", False)), history_mode=data.get("history_mode", "legacy"),
                )
    known_paths = {t.rollout_path.resolve() for t in threads.values()}
    for directory in ("sessions", "archived_sessions"):
        for path in sorted((home / directory).rglob("*.jsonl")):
            if path.resolve() in known_paths:
                continue
            meta = _metadata(path)
            identifier = meta.get("id") or meta.get("session_id")
            if not identifier or identifier in threads:
                continue
            source = meta.get("source", "cli")
            threads[identifier] = Thread(
                id=identifier, title=meta.get("title") or f"Codex {identifier}", cwd=meta.get("cwd", ""),
                created_at=_timestamp(meta.get("timestamp", path.stat().st_mtime)),
                updated_at=_timestamp(path.stat().st_mtime), rollout_path=path,
                parent_id=meta.get("forked_from_id") or meta.get("parent_thread_id") or _source_parent(source),
                source=source if isinstance(source, str) else json.dumps(source),
                archived=directory == "archived_sessions", history_mode=meta.get("history_mode", "legacy"),
            )
    for identifier, thread in tuple(threads.items()):
        if str(_metadata(thread.rollout_path).get("originator", "")).startswith("c2c:claude:"):
            from .codex_native import read_origin

            original_id, unchanged = read_origin(thread)
            threads[identifier] = replace(thread, original_claude_id=original_id,
                                           unchanged_import=unchanged)
    return sorted(threads.values(), key=lambda t: (t.updated_at, t.id), reverse=True)


def _content(content: Any) -> tuple[str, tuple[dict[str, Any], ...]]:
    if isinstance(content, str):
        return content, ()
    if isinstance(content, dict):
        content = [content]
    texts: list[str] = []
    attachments: list[dict[str, Any]] = []
    for part in content or []:
        if not isinstance(part, dict):
            continue
        kind = part.get("type", "")
        if kind in ("text", "input_text", "output_text"):
            texts.append(str(part.get("text", "")))
        elif kind in ("image", "input_image", "localImage", "image_url", "file", "input_file", "resource_link", "skill"):
            path = part.get("path") or part.get("file_path")
            url = part.get("image_url") or part.get("url") or part.get("uri")
            if isinstance(url, dict):
                url = url.get("url")
            mime = part.get("mimeType") or part.get("mime_type")
            if not mime and path:
                mime = mimetypes.guess_type(path)[0]
            if not url and part.get("data") and kind == "image":
                url = f"data:{mime or 'image/png'};base64,{part['data']}"
            item = {k: v for k, v in {"path": path, "url": url, "media_type": mime,
                    "name": part.get("name") or part.get("filename"), "type": kind}.items() if v is not None}
            # Upload IDs and embedded payloads need not have a filesystem path.
            for key in ("file_id", "file_data", "file_url"):
                if key in part:
                    item[key] = part[key]
            attachments.append(item)
        elif kind not in ("reasoning", "encrypted_text"):
            warnings.warn(f"Unsupported content block type {kind!r}; preserved as an attachment",
                          SourceWarning, stacklevel=2)
            attachments.append(dict(part))
    return "\n".join(texts), tuple(attachments)


def _resolve_attachments(item: Item, thread: Thread) -> Item:
    """Resolve source-relative paths before the destination process changes cwd."""
    def absolute(value: str) -> str:
        path = Path(value).expanduser()
        if not path.is_absolute() and thread.cwd:
            path = Path(thread.cwd) / path
        return str(path)

    attachments = tuple(dict(attachment, path=absolute(attachment["path"]))
                        if isinstance(attachment.get("path"), str) else attachment
                        for attachment in item.attachments)
    raw = item.raw
    if raw and item.kind in ("imageView", "imageGeneration"):
        raw = dict(raw)
        for key in ("path", "savedPath"):
            if isinstance(raw.get(key), str) and raw[key]:
                raw[key] = absolute(raw[key])
    return replace(item, attachments=attachments, raw=raw)


_PRIVATE = {"reasoning", "hookPrompt", "contextCompaction", "subAgentActivity"}
_TOOLS = {"commandExecution", "fileChange", "functionCallOutput", "mcpToolCall", "collabAgentToolCall",
          "imageView", "imageGeneration", "webSearch", "sleep"}


def _projected(data: dict[str, Any], identifier: str, timestamp: str, ordinal: int) -> Item | None:
    kind = data.get("type", "")
    if kind in _PRIVATE:
        return None
    if kind == "userMessage":
        text, attachments = _content(data.get("content", []))
        return Item(identifier, "user", text, timestamp, kind, attachments, None, ordinal)
    if kind == "agentMessage":
        if data.get("phase") == "analysis":
            return None
        return Item(identifier, "assistant", data.get("text", ""), timestamp, kind, (), None, ordinal)
    if kind in _TOOLS:
        output = data.get("aggregatedOutput", data.get("output", ""))
        if kind == "mcpToolCall":
            result = data.get("result") or {}
            output = result.get("content", []) if isinstance(result, dict) else result
        text, attachments = _content(output)
        if kind in ("imageView", "imageGeneration"):
            path = data.get("path") or data.get("savedPath")
            if path:
                attachments += ({"path": path, "type": "localImage", "media_type": mimetypes.guess_type(path)[0]},)
        return Item(identifier, "tool", text, timestamp, kind, attachments, data, ordinal)
    warnings.warn(f"Unsupported projected item type {kind!r} at ordinal {ordinal}", SourceWarning, stacklevel=2)
    return None


def _response(data: dict[str, Any], timestamp: str, ordinal: int, prefix: str) -> Item | None:
    kind = data.get("type")
    identifier = data.get("id") or data.get("call_id") or f"{prefix}:{ordinal}"
    if kind == "message":
        role = data.get("role")
        if role not in ("user", "assistant") or data.get("channel") in ("analysis", "justify", "confidence"):
            return None
        text, attachments = _content(data.get("content", []))
        if not text and not attachments:
            return None
        return Item(identifier, role, text, timestamp, "userMessage" if role == "user" else "agentMessage",
                    attachments, None, ordinal)
    if kind in ("function_call", "custom_tool_call", "function_call_output", "custom_tool_call_output",
                "web_search_call", "image_generation_call"):
        text, attachments = _content(data.get("output", ""))
        return Item(identifier, "tool", text, timestamp, kind, attachments, data, ordinal)
    return None


def _rollout_items(thread: Thread, *, start_offset: int = 0, start_ordinal: int = 0) -> Iterator[Item]:
    for ordinal, record in _records(thread.rollout_path, start_offset=start_offset, start_ordinal=start_ordinal):
        if record.get("type") != "response_item":
            continue
        item = _response(record.get("payload", {}), _timestamp(record.get("timestamp", thread.updated_at)), ordinal, thread.id)
        if item is not None:
            yield _resolve_attachments(item, thread)


def _recover_projected_images(items: list[Item], thread: Thread) -> list[Item]:
    """Recover raw images by event ordinal/id and tool call id.

    Display paths may be overwritten. Event order cannot identify images across
    concurrent calls or multiple images emitted by one exec script.
    """
    targets = {item.ordinal: item for item in items
               if item.kind in ("userMessage", "imageView")
               and any(attachment.get("type") == "localImage" and attachment.get("path")
                       for attachment in item.attachments)}
    if not targets or not thread.rollout_path.is_file():
        return items
    recovered: dict[int, Item] = {}
    ambiguous: set[int] = set()
    pending: dict[str, list[Item | None]] = {}
    previous_user: tuple[int, list[dict[str, Any]]] | None = None

    def images(content: Any) -> list[dict[str, Any]]:
        if not isinstance(content, list):
            return []
        return [part for part in content if isinstance(part, dict)
                and part.get("type") in ("input_image", "image", "image_url")]

    def merge(item: Item, parts: list[dict[str, Any]]) -> bool:
        indices = [index for index, attachment in enumerate(item.attachments)
                   if attachment.get("type") == "localImage" and attachment.get("path")]
        if len(indices) != len(parts):
            return False
        attachments = list(item.attachments)
        for index, part in zip(indices, parts):
            _, parsed = _content([part])
            url = parsed[0].get("url") if parsed else None
            # Remote references must not trigger a fetch during migration.
            if not isinstance(url, str) or not url.startswith("data:image/"):
                return False
            attachments[index] = dict(attachments[index], url=url)
        recovered[item.ordinal] = replace(item, attachments=tuple(attachments))
        return True

    def matches(item: Item, event: dict[str, Any]) -> bool:
        if event.get("id") != item.id:
            return False
        event_kind = event.get("type", "")
        if not isinstance(event_kind, str) or event_kind.casefold() != item.kind.casefold():
            return False
        if item.kind == "imageView":
            paths = [event.get("path")]
        else:
            # Raw Rust event variants use snake_case inside UserMessage;
            # SQLite's display projection uses camelCase.
            paths = [part.get("path") for part in event.get("content", [])
                     if isinstance(part, dict) and part.get("type") in ("local_image", "localImage")]
        if not all(isinstance(path, str) for path in paths):
            return False
        event_paths = []
        for value in paths:
            if value.startswith("file:"):
                uri = urlsplit(value)
                if uri.netloc not in ("", "localhost") or uri.query or uri.fragment:
                    return False
                value = unquote(uri.path)
            path = Path(value).expanduser()
            if not path.is_absolute() and thread.cwd:
                path = Path(thread.cwd) / path
            event_paths.append(str(path))
        return event_paths == [a.get("path") for a in item.attachments if a.get("type") == "localImage"]

    for ordinal, record in _records(thread.rollout_path):
        data = record.get("payload", {})
        if not isinstance(data, dict):
            previous_user = None
            continue
        kind = data.get("type")
        if record.get("type") == "response_item":
            if kind == "message" and data.get("role") == "user":
                # A new user turn also makes any interrupted calls obsolete.
                for group in pending.values():
                    ambiguous.update(item.ordinal for item in group if item is not None)
                pending.clear()
                previous_user = (ordinal, images(data.get("content")))
                continue
            previous_user = None
            call_id = data.get("call_id")
            if kind in ("function_call", "custom_tool_call") and isinstance(call_id, str):
                if pending:
                    # No event carries its enclosing call id. Once calls
                    # overlap, their event assignments cannot be proven.
                    for group in pending.values():
                        ambiguous.update(item.ordinal for item in group if item is not None)
                        group.append(None)
                    pending[call_id] = [None]
                else:
                    pending[call_id] = []
            elif kind in ("function_call_output", "custom_tool_call_output"):
                group = pending.pop(call_id, []) if isinstance(call_id, str) else []
                candidates = [item for item in group if item is not None]
                parts = images(data.get("output"))
                if len(group) == len(candidates) == len(parts) == 1 and merge(candidates[0], parts):
                    continue
                ambiguous.update(item.ordinal for item in candidates)
            continue
        if record.get("type") != "event_msg" or kind != "item_completed":
            previous_user = None
            continue
        event = data.get("item", {})
        if not isinstance(event, dict):
            previous_user = None
            continue
        item = targets.get(ordinal)
        verified = item is not None and matches(item, event)
        event_kind = event.get("type", "")
        if isinstance(event_kind, str) and event_kind.casefold() == "usermessage":
            if verified and previous_user is not None and previous_user[0] == ordinal - 1:
                if not merge(item, previous_user[1]):
                    ambiguous.add(ordinal)
        elif isinstance(event_kind, str) and event_kind.casefold() in ("imageview", "imagegeneration"):
            if len(pending) == 1:
                next(iter(pending.values())).append(item if verified and item.kind == "imageView" else None)
            elif verified:
                ambiguous.add(ordinal)
        previous_user = None
    for group in pending.values():
        ambiguous.update(item.ordinal for item in group if item is not None)
    ambiguous.difference_update(recovered)
    if ambiguous:
        warnings.warn(f"Raw image recovery was ambiguous for {len(ambiguous)} projected item(s); kept original paths",
                      SourceWarning, stacklevel=2)
    return [recovered.get(item.ordinal, item) for item in items]


def read_items(thread: Thread, codex_home: str | Path) -> Iterator[Item]:
    """Yield display history plus its unprojected rollout tail.

    Parent messages are not appended; read_compaction supplies inherited context.
    """
    home = Path(codex_home).expanduser().resolve()
    database = _latest_database(home, "thread_history")
    projected = False
    projection: dict[str, Any] | None = None
    projected_items: list[Item] = []
    if database:
        with _database(database) as connection:
            tables = _tables(connection)
            if "thread_items" in tables:
                if "thread_history_projection_state" in tables:
                    row = connection.execute("SELECT * FROM thread_history_projection_state WHERE thread_id=?", (thread.id,)).fetchone()
                    projection = dict(row) if row else None
                for row in connection.execute(
                    "SELECT item_id, item_json, created_at_ms, rollout_ordinal FROM thread_items WHERE thread_id=? ORDER BY rollout_ordinal, item_id", (thread.id,)
                ):
                    projected = True
                    data = _json(row["item_json"], f"history thread {thread.id}, item {row['item_id']}")
                    item = _projected(data, row["item_id"], _timestamp(row["created_at_ms"], milliseconds=True), row["rollout_ordinal"])
                    if item is not None:
                        projected_items.append(_resolve_attachments(item, thread))
    if projected or projection:
        yield from _recover_projected_images(projected_items, thread)
        if projection and thread.rollout_path.is_file():
            yield from _rollout_items(thread, start_offset=projection["next_rollout_byte_offset"], start_ordinal=projection["next_rollout_ordinal"])
        elif not projection:
            warnings.warn(f"Projected thread {thread.id} has no projection cursor; live tail cannot be verified", SourceWarning, stacklevel=2)
        return
    if not thread.rollout_path.is_file():
        raise SourceError(f"No projected history or rollout for thread {thread.id}: {thread.rollout_path}")
    yield from _rollout_items(thread)


def read_compaction(thread: Thread) -> Compaction | None:
    """Return only the latest active compaction, excluding system and reasoning."""
    if not thread.rollout_path.is_file():
        return None
    latest = None
    for ordinal, record in _records(thread.rollout_path, compactions_only=True):
        if record.get("type") != "compacted":
            continue
        data = record.get("payload", {})
        timestamp = _timestamp(record.get("timestamp", thread.updated_at))
        replacement = data.get("replacement_history") or []
        summary = data.get("message") or ""
        summaries = [entry for entry in replacement
                     if entry.get("type") == "message" and entry.get("role") == "assistant" and entry.get("channel") == "summary"]
        if not summary:
            summary = "\n\n".join(_content(entry.get("content", []))[0] for entry in summaries)
        items = tuple(item for index, entry in enumerate(replacement)
                      if entry not in summaries
                      and (item := _response(entry, timestamp, ordinal, f"{thread.id}:compaction:{index}")) is not None
                      and not (summary and item.role == "assistant" and item.text == summary))
        encrypted = any(entry.get("type") == "compaction" and entry.get("encrypted_content") for entry in replacement)
        latest = Compaction(summary=summary, items=tuple(_resolve_attachments(item, thread) for item in items),
                            timestamp=timestamp, ordinal=ordinal, encrypted=encrypted)
    return latest
