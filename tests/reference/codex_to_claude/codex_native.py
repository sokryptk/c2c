"""Native Codex rollout encoding and registration through Codex's own commands.

Verified with codex-cli 0.159.2. Importing never executes a saved tool call or
starts a model turn. Database state is owned by `codex migrate-rollouts`.
"""
from __future__ import annotations

import base64
import hashlib
from itertools import zip_longest
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import queue
import re
import sqlite3
import subprocess
import threading
import time
from typing import Any, Iterable
from types import SimpleNamespace
import uuid

from .native import Conversion

CODEX_VERSION = '0.159.2'
NAMESPACE = uuid.UUID('b18998c2-4d26-40bd-9c20-2dd493c3a146')
MAX_ACTIVE_BYTES = 240_000
RECENT_CONTEXT_BYTES = 170_000


def session_id(source_id: str) -> str:
    return str(uuid.uuid5(NAMESPACE, 'claude-session:' + source_id))


def _date(value: str) -> datetime:
    result = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if result.tzinfo is None:
        result = result.replace(tzinfo=timezone.utc)
    return result.astimezone(timezone.utc)


def target_path(thread: Any, codex_home: str | Path) -> Path:
    dt = _date(thread.created_at)
    return (Path(codex_home).expanduser().resolve() / 'sessions' / dt.strftime('%Y/%m/%d') /
            f"rollout-{dt.strftime('%Y-%m-%dT%H-%M-%S')}-{session_id(thread.id)}.jsonl")


def _json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))


def _ms(timestamp: str) -> int:
    return int(_date(timestamp).timestamp() * 1000)


def _blocks(value: Any) -> list[dict]:
    if isinstance(value, str):
        return [{'type': 'text', 'text': value}] if value else []
    return [v for v in value or [] if isinstance(v, dict)]


def convert(thread: Any, entries: Iterable[dict], *, transcript_path: str | None = None,
            embed_images: bool = True) -> Conversion:
    """Create both model-facing response records and native display events.

    Claude tool pairs remain completed response call/result pairs. Bash pairs
    additionally render as native command records; other tools retain complete
    inputs/results in a native display artifact. Private thinking is excluded.
    """
    result = Conversion(session_id=session_id(thread.id))
    turn_id: str | None = None
    turn_started = thread.created_at
    last_answer = ''
    counter = 0
    pending: dict[str, dict] = {}
    active: list[dict] = []
    last_timestamp = thread.created_at
    summary_pending = False

    def identifier(label: str) -> str:
        nonlocal counter
        counter += 1
        return str(uuid.uuid5(NAMESPACE, f'{result.session_id}:{label}:{counter}'))

    def append(kind: str, payload: dict, timestamp: str) -> None:
        result.entries.append({'timestamp': timestamp, 'type': kind, 'payload': payload})

    def response(payload: dict, timestamp: str) -> None:
        append('response_item', payload, timestamp)
        active.append(payload)

    def begin(timestamp: str) -> None:
        nonlocal turn_id, turn_started, last_answer
        if turn_id:
            return
        turn_id = identifier('turn')
        turn_started = timestamp
        last_answer = ''
        append('event_msg', {'type': 'task_started', 'turn_id': turn_id,
               'started_at': _ms(timestamp), 'model_context_window': None, 'collaboration_mode_kind': 'default'}, timestamp)

    def complete(timestamp: str) -> None:
        nonlocal turn_id
        if not turn_id:
            return
        flush_pending(timestamp)
        append('event_msg', {'type': 'task_complete', 'turn_id': turn_id,
               'last_agent_message': last_answer or None, 'started_at': _ms(turn_started),
               'completed_at': _ms(timestamp), 'duration_ms': max(0, _ms(timestamp) - _ms(turn_started))}, timestamp)
        turn_id = None

    def display(item: dict, timestamp: str) -> None:
        begin(timestamp)
        append('event_msg', {'type': 'item_completed', 'thread_id': result.session_id,
               'turn_id': turn_id, 'item': item, 'started_at_ms': _ms(timestamp),
               'completed_at_ms': _ms(timestamp)}, timestamp)

    def content(blocks: list[dict], role: str) -> tuple[list[dict], list[dict]]:
        model: list[dict] = []
        view: list[dict] = []
        for block in blocks:
            kind = block.get('type')
            if kind in ('thinking', 'redacted_thinking'):
                continue
            if kind == 'text':
                text = block.get('text', '')
                if text:
                    model.append({'type': 'input_text' if role == 'user' else 'output_text', 'text': text})
                    view.append({'type': 'text', 'text': text, 'text_elements': []} if role == 'user'
                                else {'type': 'Text', 'text': text})
            elif kind == 'image':
                source = block.get('source') or {}
                url = source.get('url') if source.get('type') == 'url' else None
                if source.get('type') == 'base64' and embed_images:
                    mime = source.get('media_type', '')
                    encoded = source.get('data', '')
                    try:
                        base64.b64decode(encoded, validate=True)
                    except (ValueError, TypeError):
                        result.warnings.append('Invalid Claude image base64; preserved attachment metadata')
                    else:
                        if mime.startswith('image/'):
                            url = f'data:{mime};base64,{encoded}'
                if url and role == 'user':
                    model.append({'type': 'input_image', 'image_url': url})
                    view.append({'type': 'image', 'image_url': url})
                else:
                    detail = '[Claude image attachment]'
                    if not embed_images:
                        detail += ' Image bytes remain in the original Claude transcript.'
                    elif source.get('type') == 'url':
                        detail += ' ' + str(source.get('url', ''))
                    model.append({'type': 'input_text' if role == 'user' else 'output_text', 'text': detail})
                    view.append({'type': 'text', 'text': detail, 'text_elements': []} if role == 'user'
                                else {'type': 'Text', 'text': detail})
            elif kind not in ('tool_use', 'tool_result'):
                # Codex does not accept Claude document/search-result blocks as
                # native input types. Preserve the full block explicitly.
                text = '[Claude attachment]\n' + _json(block)
                model.append({'type': 'input_text' if role == 'user' else 'output_text', 'text': text})
                view.append({'type': 'text', 'text': text, 'text_elements': []} if role == 'user'
                            else {'type': 'Text', 'text': text})
                result.warnings.append(f'Claude content type {kind!r} preserved as text')
        return model, view

    def message(role: str, blocks: list[dict], timestamp: str, *, summary: bool = False) -> None:
        nonlocal last_answer, active
        model, view = content(blocks, role)
        if not model:
            return
        message_id = identifier('message')
        payload = {'type': 'message', 'id': message_id, 'role': role, 'content': model}
        if role == 'assistant':
            payload['phase'] = 'final_answer'
            last_answer = '\n'.join(b.get('text', '') for b in model)
        if summary:
            complete(timestamp)
            text = '\n'.join(b.get('text', '') for b in model if b.get('text'))
            append('compacted', {'message': text, 'replacement_history': [payload],
                                 'compaction_response_id': None, 'latest_token_usage_record': None}, timestamp)
            active = [payload]
            # Native visible summary is a user event matching Claude's existing
            # compact-summary record, rather than a fabricated assistant reply.
            display({'type': 'UserMessage', 'id': message_id, 'content': view}, timestamp)
        else:
            begin(timestamp)
            response(payload, timestamp)
            display({'type': 'UserMessage' if role == 'user' else 'AgentMessage',
                     'id': message_id, 'content': view,
                     **({'phase': 'final_answer'} if role == 'assistant' else {})}, timestamp)
        result.message_count += 1

    def output(call_id: str, blocks: Any, timestamp: str, *, failed: bool = False,
               missing: bool = False) -> None:
        saved = pending.pop(call_id, None)
        if saved is None:
            message('assistant', [{'type': 'text', 'text': '[Unpaired historical Claude tool result]\n' + _json(blocks)}], timestamp)
            result.warnings.append('Unpaired Claude tool result preserved as a visible artifact')
            return
        output_blocks, _ = content(_blocks(blocks), 'user')
        native_output = blocks if isinstance(blocks, str) else output_blocks
        if failed:
            error_notice = '[Claude marked this historical tool result as an error.]'
            native_output = error_notice + '\n' + native_output if isinstance(native_output, str) else [{'type': 'input_text', 'text': error_notice}, *native_output]
        formatted = '\n'.join(block.get('text', '[Image attachment preserved in tool result]')
                              for block in output_blocks)
        response({'type': 'function_call_output', 'call_id': saved['native_id'],
                  'output': native_output}, timestamp)
        if saved['name'] == 'Bash' and isinstance(saved['input'], dict) and saved['input'].get('command'):
            command = str(saved['input']['command'])
            display({'type': 'CommandExecution', 'id': saved['native_id'],
                     'command': ['bash', '-lc', command], 'cwd': Path(thread.cwd).expanduser().absolute().as_uri(),
                     'parsed_cmd': [], 'source': 'unified_exec_startup',
                     'status': 'failed' if failed or missing else 'completed',
                     'stdout': formatted, 'stderr': '', 'aggregated_output': formatted,
                     'duration': {'secs': max(0, _ms(timestamp) - saved['started_ms']) // 1000,
                     'nanos': (max(0, _ms(timestamp) - saved['started_ms']) % 1000) * 1_000_000}, 'formatted_output': formatted}, timestamp)
        else:
            artifact = ('[Historical Claude tool: ' + saved['name'] + ']\nInput:\n' + _json(saved['input']) +
                        '\nResult:\n' + formatted)
            display({'type': 'AgentMessage', 'id': identifier('tool-display'),
                     'content': [{'type': 'Text', 'text': artifact}], 'phase': 'final_answer'}, timestamp)
        result.tool_count += 1

    def flush_pending(timestamp: str) -> None:
        for call_id in tuple(pending):
            output(call_id, 'This historical Claude tool call had no saved result. c2c did not execute it.',
                   timestamp, missing=True)
            result.warnings.append('Incomplete historical tool call closed without execution')

    metadata = {'id': result.session_id, 'session_id': result.session_id,
                'timestamp': thread.created_at, 'cwd': thread.cwd, 'originator': 'c2c',
                'cli_version': CODEX_VERSION, 'source': 'cli', 'model_provider': 'openai',
                'history_mode': 'legacy', 'base_instructions': None}
    original = getattr(thread, 'original_codex_id', None)
    if original:
        uuid.UUID(original)
        metadata['forked_from_id'] = original
    append('session_meta', metadata, thread.created_at)
    for entry in entries:
        if entry.get('subtype') == 'compact_boundary':
            complete(last_timestamp)
            summary_pending = True
            continue
        role = (entry.get('message') or {}).get('role') or entry.get('type')
        if role not in ('user', 'assistant'):
            continue
        result.source_item_count += 1
        timestamp = entry.get('timestamp') or thread.updated_at
        _date(timestamp)
        last_timestamp = timestamp
        blocks = _blocks(entry.get('message', {}).get('content'))
        visible = [b for b in blocks if b.get('type') not in ('tool_use', 'tool_result', 'thinking', 'redacted_thinking')]
        is_summary = bool(entry.get('isCompactSummary')) or (summary_pending and role == 'user')
        if visible:
            if role == 'user' and not is_summary and not any(b.get('type') == 'tool_result' for b in blocks):
                complete(timestamp)
            message(role, visible, timestamp, summary=is_summary)
            summary_pending = False
        for block in blocks:
            if block.get('type') == 'tool_use':
                begin(timestamp)
                source_id = block.get('id') or identifier('missing-source-tool-id')
                if source_id in pending:
                    raise ValueError('Duplicate pending Claude tool ID')
                native_id = identifier('call')
                name = str(block.get('name', 'historical_tool'))
                arguments = block.get('input') or {}
                pending[source_id] = {'native_id': native_id, 'name': name, 'input': arguments, 'started_ms': _ms(timestamp)}
                response({'type': 'function_call', 'call_id': native_id, 'name': name,
                          'arguments': _json(arguments)}, timestamp)
            elif block.get('type') == 'tool_result':
                output(block.get('tool_use_id', ''), block.get('content', ''), timestamp,
                       failed=bool(block.get('is_error')))
    complete(last_timestamp)

    # A bounded native context keeps large imported histories resumable. Display
    # events remain untouched; this explicitly labelled extractive window makes
    # the complete transcript available for targeted retrieval.
    if len(_json(active).encode()) > MAX_ACTIVE_BYTES:
        turns: list[list[dict]] = []
        for entry in active:
            if entry.get('role') == 'user' or not turns:
                turns.append([])
            turns[-1].append(entry)
        selected: list[dict] = []
        size = 0
        for group in reversed(turns):
            length = len(_json(group).encode())
            if size + length > RECENT_CONTEXT_BYTES:
                if not selected:
                    # Keep the latest request even when a single tool result
                    # exceeds the budget; disclose omitted content by location.
                    def excerpt(item: dict) -> dict:
                        bounded = json.loads(_json(item))
                        if len(_json(bounded).encode()) <= 40_000:
                            return bounded
                        text = '\n'.join(block.get('text', '[Image attachment remains in full transcript]')
                                         for block in bounded.get('content', []))
                        encoded = text.encode()
                        if len(encoded) > 30_000:
                            text = (encoded[:15_000].decode('utf-8', errors='ignore') +
                                    '\n[c2c: excerpt shortened; full text remains in the transcript.]\n' +
                                    encoded[-15_000:].decode('utf-8', errors='ignore'))
                        bounded['content'] = [{'type': 'input_text' if item.get('role') == 'user' else 'output_text',
                                               'text': text}]
                        return bounded

                    messages = [item for item in group if item.get('type') == 'message']
                    initial = excerpt(messages[0]) if messages and messages[0].get('role') == 'user' else None
                    size = len(_json(initial).encode()) if initial else 0
                    chosen = []
                    for item in reversed(messages[1:] if initial else messages):
                        bounded = excerpt(item)
                        length = len(_json(bounded).encode())
                        if size + length > RECENT_CONTEXT_BYTES:
                            break
                        chosen.insert(0, bounded)
                        size += length
                    selected = ([initial] if initial else []) + chosen
                break
            selected = group + selected
            size += length
        notice = ('c2c restored a recent context window from this Claude conversation. Earlier messages and tool outputs '
                  'remain in the full native transcript. This is an extractive window, not a semantic summary. '
                  'Read the transcript when earlier decisions or exact details are needed.\nFull native transcript: ' +
                  (transcript_path or '[the current session rollout]') + '\nOriginal Claude transcript: ' + str(thread.rollout_path))
        summary = {'type': 'message', 'role': 'user', 'content': [{'type': 'input_text', 'text': notice}]}
        append('compacted', {'message': notice, 'replacement_history': [summary, *selected],
                             'compaction_response_id': None, 'latest_token_usage_record': None}, last_timestamp)
        result.warnings.append('Large Claude history retained in full; active context uses a labelled recent window')
    encoded_id = base64.urlsafe_b64encode(thread.id.encode()).decode().rstrip('=')
    fingerprint = _fingerprint(result.entries)
    result.entries[0]['payload']['originator'] = f'c2c:claude:{encoded_id}:{fingerprint}'
    errors = validate(result.entries)
    if errors:
        raise ValueError('Invalid Codex rollout: ' + '; '.join(errors))
    return result


def validate(entries: Iterable[dict]) -> list[str]:
    rows = list(entries)
    errors: list[str] = []
    if not rows or rows[0].get('type') != 'session_meta':
        return ['First record must be session_meta']
    meta = rows[0].get('payload', {})
    try:
        uuid.UUID(meta.get('id', ''))
    except (ValueError, TypeError):
        errors.append('Session ID is not a UUID')
    if meta.get('history_mode') not in ('legacy', 'paginated'):
        errors.append('Unknown native history mode')
    calls: set[str] = set()
    turn: str | None = None
    for record in rows:
        try:
            _date(record.get('timestamp', ''))
        except (ValueError, TypeError, AttributeError):
            errors.append('Invalid timestamp')
        payload = record.get('payload', {})
        if record.get('type') == 'event_msg':
            kind = payload.get('type')
            if kind == 'task_started':
                if turn:
                    errors.append('Overlapping turns')
                turn = payload.get('turn_id')
            elif kind == 'task_complete':
                if payload.get('turn_id') != turn:
                    errors.append('Mismatched turn completion')
                turn = None
            elif kind == 'item_completed':
                if payload.get('turn_id') != turn or payload.get('thread_id') != meta.get('id'):
                    errors.append('Orphan visible item')
        elif record.get('type') == 'response_item':
            kind = payload.get('type')
            if kind == 'function_call':
                if payload.get('call_id') in calls:
                    errors.append('Duplicate pending tool call')
                calls.add(payload.get('call_id'))
            elif kind == 'function_call_output':
                if payload.get('call_id') not in calls:
                    errors.append('Unpaired tool result')
                calls.discard(payload.get('call_id'))
            elif kind == 'message' and payload.get('role') not in ('user', 'assistant'):
                errors.append('Private instruction role in imported history')
    if calls:
        errors.append('Pending tool calls')
    if turn:
        errors.append('Unclosed turn')
    return errors


def _canonical_record(row: dict, *, fingerprint: bool = False) -> dict:
    value = dict(row)
    value.pop('ordinal', None)
    if value.get('type') == 'session_meta':
        payload = dict(value.get('payload', {}))
        payload['history_mode'] = 'legacy'
        payload.setdefault('base_instructions', None)
        if fingerprint:
            payload['originator'] = 'c2c'
        value['payload'] = payload
    return value


def _fingerprint(entries: Iterable[dict]) -> str:
    digest = hashlib.sha256()
    for entry in entries:
        digest.update(json.dumps(_canonical_record(entry, fingerprint=True), sort_keys=True,
                                 ensure_ascii=False, separators=(',', ':')).encode())
        digest.update(b'\n')
    return digest.hexdigest()


def read_origin(thread: Any) -> tuple[str | None, bool]:
    """Recognize portable provenance even when the import journal is absent."""
    original_id = None
    try:
        with Path(thread.rollout_path).open() as stream:
            first = json.loads(stream.readline())
        originator = first.get('payload', {}).get('originator', '')
        if not originator.startswith('c2c:claude:'):
            return None, False
        encoded_id, expected = originator[len('c2c:claude:'):].split(':', 1)
        original_id = base64.urlsafe_b64decode(encoded_id + '=' * (-len(encoded_id) % 4)).decode()
        def records():
            with Path(thread.rollout_path).open() as stream:
                for line in stream:
                    if line.strip():
                        yield json.loads(line)
        return original_id, _fingerprint(records()) == expected
    except (OSError, ValueError, UnicodeError, TypeError):
        return original_id, False


def registration_matches(staged_entries: Iterable[dict], target_entries: Iterable[dict]) -> bool:
    """Allow exactly the normalization performed by native rollout migration."""
    sentinel = object()
    for before, after in zip_longest(staged_entries, target_entries, fillvalue=sentinel):
        if before is sentinel or after is sentinel:
            return False
        if _canonical_record(before) != _canonical_record(after):
            return False
    return True


def _environment(home: str | Path) -> dict[str, str]:
    return {**os.environ, 'CODEX_HOME': str(Path(home).expanduser().resolve())}


class _Server:
    def __init__(self, home: str | Path, binary: str):
        self.process = subprocess.Popen([binary, 'app-server', '--stdio'], env=_environment(home),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.queue: queue.Queue = queue.Queue()
        self.sequence = 0
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self) -> None:
        try:
            for line in self.process.stdout:
                try:
                    self.queue.put(json.loads(line))
                except ValueError:
                    continue
        finally:
            self.queue.put(None)

    def call(self, method: str, params: dict) -> dict:
        self.sequence += 1
        request_id = self.sequence
        self.process.stdin.write(_json({'id': request_id, 'method': method, 'params': params}) + '\n')
        self.process.stdin.flush()
        deadline = time.monotonic() + 60
        while True:
            try:
                response = self.queue.get(timeout=max(.01, deadline - time.monotonic()))
            except queue.Empty as exc:
                raise RuntimeError(f'Codex native registration timed out during {method}') from exc
            if response is None:
                raise RuntimeError(f'Codex app-server ended during {method}')
            if response.get('id') != request_id:
                continue
            if 'error' in response:
                raise RuntimeError(f'Codex {method} failed: {response["error"].get("message", "unknown error")}')
            return response.get('result', {})

    def close(self) -> None:
        if self.process.stdin:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)
        self.reader.join(timeout=2)
        if self.process.stdout:
            self.process.stdout.close()


def _registration_preflight(codex_home: str | Path, thread_id: str) -> Path:
    home = Path(codex_home).expanduser().resolve()
    candidates = list((home / 'sessions').rglob(f'rollout-*-{thread_id}.jsonl'))
    if len(candidates) != 1:
        raise RuntimeError('Expected exactly one unpublished Codex session path for this imported ID')
    expected = candidates[0].resolve()
    versions = [(int(match[1]), path) for path in home.glob('state_*.sqlite')
                if (match := re.fullmatch(r'state_(\d+)\.sqlite', path.name))]
    if versions:
        database = max(versions)[1]
        connection = sqlite3.connect(database.resolve().as_uri() + '?mode=ro', uri=True)
        try:
            columns = {row[1] for row in connection.execute('PRAGMA table_info(threads)')}
            if columns:
                selected = 'rollout_path, archived' if 'archived' in columns else 'rollout_path, 0'
                row = connection.execute(f'SELECT {selected} FROM threads WHERE id=?', (thread_id,)).fetchone()
                if row and (row[1] or Path(row[0]).resolve() != expected):
                    raise RuntimeError('This Codex session ID already belongs to an archived or different native path')
        finally:
            connection.close()
    _, unchanged = read_origin(SimpleNamespace(rollout_path=expected))
    if not unchanged:
        raise RuntimeError('Imported Codex history changed before native registration; refusing to overwrite continuation')
    return expected


def register(codex_home: str | Path, thread_id: str, title: str, *, codex_binary: str = 'codex') -> dict:
    uuid.UUID(thread_id)
    expected_path = _registration_preflight(codex_home, thread_id)
    server = _Server(codex_home, codex_binary)
    try:
        server.call('initialize', {'clientInfo': {'name': 'c2c', 'version': '0.1.0'},
                                  'capabilities': {'experimentalApi': True}})
        server.process.stdin.write(_json({'method': 'initialized'}) + '\n')
        server.process.stdin.flush()
        # Native read backfills SQLite metadata without loading a model turn.
        # migrate-rollouts alone does not discover every older legacy file.
        discovered = server.call('thread/read', {'threadId': thread_id, 'includeTurns': False}).get('thread', {})
        if discovered.get('id') != thread_id or (discovered.get('path') and Path(discovered['path']).resolve() != expected_path):
            raise RuntimeError('Native discovery returned a different imported session')
        migration = subprocess.run([codex_binary, 'migrate-rollouts', '--apply', '--thread', thread_id, '--json'],
            env=_environment(codex_home), capture_output=True, text=True, timeout=300)
        if migration.returncode:
            raise RuntimeError(f'Codex native history registration failed (exit {migration.returncode})')
        if not read_origin(SimpleNamespace(rollout_path=expected_path))[1]:
            raise RuntimeError('Codex native migration altered conversation content; registration was not accepted')
        read = server.call('thread/read', {'threadId': thread_id, 'includeTurns': False})
        saved = read.get('thread', {})
        if saved.get('id') != thread_id:
            raise RuntimeError('Native registration returned a different thread')
        if saved.get('path') and Path(saved['path']).resolve() != expected_path:
            raise RuntimeError('Native registration returned a different rollout path')
        if not saved.get('name'):
            server.call('thread/name/set', {'threadId': thread_id, 'name': title or 'Imported Claude conversation'})
        return {'thread_id': thread_id, 'status': 'registered', 'native_version': CODEX_VERSION}
    finally:
        server.close()


def unregister(codex_home: str | Path, thread_id: str, *, codex_binary: str = 'codex') -> None:
    """Remove a verified, unchanged imported session using native cleanup."""
    uuid.UUID(thread_id)
    removed = subprocess.run([codex_binary, 'delete', '--force', thread_id], env=_environment(codex_home),
                             capture_output=True, text=True, timeout=60)
    if removed.returncode:
        raise RuntimeError(f'Codex native session removal failed (exit {removed.returncode})')
