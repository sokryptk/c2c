"""Claude Code JSONL adapter, verified against 2.1.289."""
from __future__ import annotations

import base64
import copy
import json
import re
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

NAMESPACE = uuid.UUID('6ee9e2ac-f1e7-4ed0-9ecb-ced168929080')
CLAUDE_VERSION = '2.1.289'
IMAGE_LIMIT = 5 * 1024 * 1024
MAX_ACTIVE_BYTES = 240_000
RECENT_CONTEXT_BYTES = 170_000


@dataclass
class Conversion:
    entries: list[dict[str, Any]] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    message_count: int = 0
    tool_count: int = 0
    source_item_count: int = 0
    session_id: str = ''


def project_directory(cwd: str) -> str:
    """Claude's project encoding, including its long-path hash suffix."""
    name = str(Path(cwd).expanduser().absolute())
    sanitized = re.sub(r'[^a-zA-Z0-9]', '-', name)
    if len(sanitized) <= 200:
        return sanitized
    hashed = 0
    for char in name:
        hashed = (hashed * 31 + ord(char)) & 0xffffffff
    if hashed >= 0x80000000:
        hashed -= 0x100000000
    hashed = abs(hashed)
    digits = '0123456789abcdefghijklmnopqrstuvwxyz'
    suffix = ''
    while hashed:
        hashed, digit = divmod(hashed, 36)
        suffix = digits[digit] + suffix
    return sanitized[:200] + '-' + (suffix or '0')


def _id(value: str) -> str:
    return str(uuid.uuid5(NAMESPACE, value))


def session_id(thread_id: str) -> str:
    return _id('session:' + thread_id)


def _json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, indent=2, default=str)


def _bounded_text(text: str, budget: int) -> str:
    """Bound the serialized string, including escaped control characters."""
    if len(json.dumps(text, ensure_ascii=False).encode()) <= budget:
        return text
    notice = '\n[Excerpt; complete value is retained in the original transcript.]'
    lo, hi = 0, len(text)
    while lo < hi:
        middle = (lo + hi + 1) // 2
        if len(json.dumps(text[:middle] + notice, ensure_ascii=False).encode()) <= budget:
            lo = middle
        else:
            hi = middle - 1
    return text[:lo] + notice


def _image(path: str, warnings: list[str], embed: bool) -> dict | None:
    if not embed:
        return None
    p = Path(path).expanduser()
    try:
        if p.stat().st_size > IMAGE_LIMIT:
            warnings.append(f'Image exceeds native 5 MB limit; kept path: {p}')
            return None
        data = p.read_bytes()
    except OSError:
        warnings.append(f'Attachment unavailable; kept path: {p}')
        return None
    if data.startswith(b'\x89PNG\r\n\x1a\n'):
        mime = 'image/png'
    elif data.startswith(b'\xff\xd8\xff'):
        mime = 'image/jpeg'
    elif data.startswith((b'GIF87a', b'GIF89a')):
        mime = 'image/gif'
    elif data[:4] == b'RIFF' and data[8:12] == b'WEBP':
        mime = 'image/webp'
    else:
        warnings.append(f'Attachment is not a supported image; kept path: {p}')
        return None
    return {'type': 'image', 'source': {'type': 'base64', 'media_type': mime,
                                       'data': base64.b64encode(data).decode('ascii')}}


def _attachment_blocks(attachments: Iterable[dict], warnings: list[str], embed: bool) -> list[dict]:
    blocks: list[dict] = []
    for attachment in attachments:
        path = attachment.get('path')
        url = attachment.get('url') or attachment.get('image_url')
        if isinstance(url, dict):
            url = url.get('url')
        if path:
            blocks.append({'type': 'text', 'text': f'Attachment: {path}'})
            if isinstance(url, str) and url.startswith('data:image/'):
                # Recovered bytes take precedence over mutable temporary paths.
                blocks.extend(_attachment_blocks([{'url': url}], warnings, embed))
                continue
            image = _image(str(path), warnings, embed)
            if image:
                blocks.append(image)
        elif isinstance(url, str) and url.startswith('data:image/'):
            header, sep, payload = url.partition(',')
            mime = header[5:].split(';')[0]
            if embed and sep and ';base64' in header and mime in (
                'image/png', 'image/jpeg', 'image/gif', 'image/webp'
            ):
                try:
                    decoded = base64.b64decode(payload, validate=True)
                except ValueError:
                    warnings.append('Invalid embedded image; preserved attachment notice')
                else:
                    if len(decoded) <= IMAGE_LIMIT:
                        blocks.append({'type': 'image', 'source': {'type': 'base64',
                            'media_type': mime, 'data': payload}})
                        continue
            blocks.append({'type': 'text', 'text': 'An embedded image was attached in Codex.'})
        elif isinstance(url, str) and url.startswith(('https://', 'http://')):
            # Preserve URLs as text so resuming cannot fetch them implicitly.
            blocks.append({'type': 'text', 'text': f'Attachment URL: {url}'})
        else:
            blocks.append({'type': 'text', 'text': 'Codex attachment: ' + _json(attachment)})
    return blocks


def _tool_result_blocks(value: Any, warnings: list[str], embed: bool) -> str | list[dict]:
    if not isinstance(value, dict) or not isinstance(value.get('content'), list):
        return _json(value)
    blocks: list[dict] = []
    for part in value['content']:
        if isinstance(part, dict) and part.get('type') == 'text':
            blocks.append({'type': 'text', 'text': str(part.get('text', '')) or '(empty tool text)'})
        elif isinstance(part, dict) and part.get('type') == 'image' and part.get('data'):
            blocks.extend(_attachment_blocks([{'url':
                f"data:{part.get('mimeType', 'image/png')};base64,{part['data']}"}], warnings, embed))
        else:
            blocks.append({'type': 'text', 'text': _json(part)})
    metadata = {key: val for key, val in value.items() if key != 'content'}
    if metadata:
        blocks.append({'type': 'text', 'text': _json(metadata)})
    return blocks or [{'type': 'text', 'text': '(empty tool result)'}]


def convert(thread: Any, items: Iterable[Any], compaction: Any = None, *,
            embed_images: bool = True, transcript_path: str | None = None) -> Conversion:
    result = Conversion(session_id=session_id(thread.id))
    parent: str | None = None
    sequence = 0
    seen_user = False
    source_items = list(items)
    result.source_item_count = len(source_items)
    if not source_items:
        return result
    if compaction is not None and compaction.encrypted:
        result.warnings.append('Encrypted Codex compaction is unavailable; visible transcript preserved')

    def append(role: str, content: str | list[dict], timestamp: str | None,
               *, summary: bool = False, extra: dict | None = None) -> None:
        nonlocal parent, sequence, seen_user
        sequence += 1
        entry_id = _id(f'{result.session_id}:entry:{sequence}')
        message: dict[str, Any] = {'role': role, 'content': content}
        if role == 'assistant':
            message.update({'id': 'msg_' + entry_id.replace('-', ''), 'type': 'message',
                            'model': '<synthetic>', 'stop_reason': 'end_turn',
                            'stop_sequence': None, 'usage': {'input_tokens': 0, 'output_tokens': 0}})
            if any(b.get('type') == 'tool_use' for b in content if isinstance(b, dict)):
                message['stop_reason'] = 'tool_use'
        else:
            seen_user = True
        entry = {'parentUuid': parent, 'isSidechain': False, 'userType': 'external',
                 'entrypoint': 'cli', 'cwd': thread.cwd, 'sessionId': result.session_id,
                 'version': CLAUDE_VERSION, 'gitBranch': '', 'type': role,
                 'message': message, 'uuid': entry_id,
                 'timestamp': timestamp or thread.updated_at or thread.created_at}
        if summary:
            entry['isCompactSummary'] = True
        if extra:
            entry.update(extra)
        result.entries.append(entry)
        parent = entry_id
        result.message_count += 1

    def tool(name: str, arguments: dict, output: str | list[dict], timestamp: str,
             *, failed: bool = False) -> None:
        tool_id = 'toolu_codex_' + _id(f'{result.session_id}:tool:{sequence}').replace('-', '')
        append('assistant', [{'type': 'tool_use', 'id': tool_id, 'name': name,
                              'input': arguments}], timestamp)
        append('user', [{'type': 'tool_result', 'tool_use_id': tool_id,
                         'content': output, 'is_error': failed}], timestamp)
        result.tool_count += 1

    def emit(item: Any) -> None:
        nonlocal seen_user
        raw = item.raw or {}
        if item.kind in ('reasoning', 'hookPrompt', 'system', 'developer', 'contextCompaction'):
            return
        if not seen_user:
            if item.role != 'user':
                append('user', 'Continue this imported Codex conversation. The following entries '
                       'are its saved history.', thread.created_at)
            seen_user = True
        if item.kind == 'commandExecution':
            status = raw.get('status', 'unknown')
            output = raw.get('aggregatedOutput') or ''
            if not isinstance(output, str):
                output = _json(output)
            exit_code = raw.get('exitCode')
            output += f'\n[Imported command status: {status}; exit code: {exit_code}]'
            if status not in ('completed', 'failed', 'declined'):
                output += '\nThis process belonged to Codex and was not resumed or executed by the import.'
            tool('Bash', {'command': raw.get('command', item.text or ''),
                          'description': 'Imported Codex command' +
                              (' (cwd: ' + str(raw['cwd']) + ')' if raw.get('cwd') else '')}, output, item.timestamp,
                 failed=status in ('failed', 'declined') or (exit_code is not None and exit_code != 0))
            return
        if item.kind == 'mcpToolCall':
            name = 'mcp__' + re.sub(r'[^\w-]', '_', str(raw.get('server', 'codex'))) + '__' + re.sub(
                r'[^\w-]', '_', str(raw.get('tool', 'historical_tool')))
            arguments = raw.get('arguments') or {}
            if not isinstance(arguments, dict):
                arguments = {'value': arguments}
            output = _tool_result_blocks(raw.get('result') if raw.get('result') is not None else raw.get('error'),
                                         result.warnings, embed_images)
            if raw.get('status') not in ('completed', 'failed'):
                notice = '[Historical tool did not complete in Codex; it was not run by this import.]'
                if isinstance(output, str):
                    output += '\n' + notice
                else:
                    output.append({'type': 'text', 'text': notice})
            tool(name, arguments, output, item.timestamp,
                 failed=raw.get('status') == 'failed' or raw.get('error') is not None)
            return
        if item.kind == 'imageView' and raw.get('path'):
            blocks = _attachment_blocks(item.attachments or [{'path': raw['path']}], result.warnings, embed_images)
            tool('Read', {'file_path': raw['path']}, blocks, item.timestamp)
            return
        if item.role == 'user':
            blocks = ([{'type': 'text', 'text': item.text}] if item.text else [])
            blocks.extend(_attachment_blocks(item.attachments, result.warnings, embed_images))
            if blocks:
                append('user', blocks, item.timestamp)
            return
        if item.kind in ('agentMessage', 'message', 'assistant', 'response_item') or not raw:
            blocks = ([{'type': 'text', 'text': item.text}] if item.text else [])
            # Claude accepts user-side image blocks; assistant-side provider
            # output images stay linked, with bytes in the next user record.
            if blocks:
                append('assistant', blocks, item.timestamp)
            if item.attachments:
                append('user', _attachment_blocks(item.attachments, result.warnings, embed_images),
                       item.timestamp)
            return
        # Unknown artifacts cannot safely be translated into native tool calls.
        detail = _json(raw)
        if detail:
            append('assistant', [{'type': 'text', 'text':
                f'[Historical Codex {item.kind}]\n{detail}'}], item.timestamp)
            if item.attachments:
                append('user', _attachment_blocks(item.attachments, result.warnings, embed_images),
                       item.timestamp)

    def boundary() -> None:
        nonlocal parent, sequence
        if compaction is None or not compaction.summary:
            return
        sequence += 1
        boundary_id = _id(f'{result.session_id}:entry:{sequence}')
        result.entries.append({'parentUuid': None, 'logicalParentUuid': parent,
            'isSidechain': False, 'userType': 'external', 'entrypoint': 'cli',
            'cwd': thread.cwd, 'sessionId': result.session_id, 'version': CLAUDE_VERSION,
            'type': 'system', 'subtype': 'compact_boundary', 'content': 'Conversation compacted',
            'level': 'info', 'isMeta': False, 'uuid': boundary_id,
            'timestamp': compaction.timestamp or thread.updated_at,
            'compactMetadata': {'trigger': 'auto', 'preTokens': 0}})
        parent = boundary_id
        append('user', '[Context summary saved by Codex before migration]\n' + compaction.summary,
               compaction.timestamp, summary=True)
        for item in compaction.items:
            emit(item)

    inserted = False
    for item in source_items:
        if compaction is not None and compaction.summary and item.ordinal > compaction.ordinal and not inserted:
            boundary()
            inserted = True
        emit(item)
    if compaction is not None and compaction.summary and not inserted:
        boundary()

    # Claude sends history to the model before compacting it. Large imports need
    # a bounded continuation checkpoint to stay within the model's input limit.
    active_start = 0
    for index, entry in enumerate(result.entries):
        if entry.get('subtype') == 'compact_boundary':
            active_start = index + 1
    active = result.entries[active_start:]
    active_bytes = sum(len(json.dumps(e.get('message', {}), ensure_ascii=False).encode())
                       for e in active)
    if active_bytes > MAX_ACTIVE_BYTES:
        historical_count = len(result.entries)
        groups: list[list[dict]] = []
        for entry in active:
            if entry.get('type') not in ('user', 'assistant'):
                continue
            content = entry['message']['content']
            is_result = isinstance(content, list) and any(b.get('type') == 'tool_result' for b in content)
            if is_result and groups:
                groups[-1].append(entry)
            else:
                groups.append([entry])

        selected: list[list[dict]] = []
        remaining = RECENT_CONTEXT_BYTES
        for group in reversed(groups):
            size = sum(len(json.dumps(e['message'], ensure_ascii=False).encode()) for e in group)
            if size > 24_000:
                # Excerpt only the checkpoint; keep the original entry intact.
                texts: list[str] = []
                for entry in group:
                    content = entry['message']['content']
                    blocks = [{'type': 'text', 'text': content}] if isinstance(content, str) else content
                    for block in blocks:
                        if block.get('type') == 'text':
                            texts.append(block['text'])
                        elif block.get('type') == 'tool_use':
                            texts.append('Historical tool: ' + block.get('name', 'unknown'))
                        elif block.get('type') == 'tool_result':
                            value = block.get('content', '')
                            if isinstance(value, str):
                                texts.append(value)
                            elif isinstance(value, list):
                                texts.extend(b.get('text', '') for b in value if b.get('type') == 'text')
                        elif block.get('type') == 'image':
                            texts.append('[Image retained in the original native transcript.]')
                original = '\n'.join(texts)
                # Bound bytes, not characters, for non-ASCII transcripts.
                encoded = original.encode('utf-8')
                excerpt = (encoded[:4000].decode('utf-8', errors='ignore') +
                           '\n[...abridged for continuation context...]\n' +
                           encoded[-8000:].decode('utf-8', errors='ignore')) if len(encoded) > 12000 else original
                entry = group[0]
                group = [dict(entry, message={'role': entry['type'], 'content':
                    '[Import continuation excerpt; complete original entry ' + entry['uuid'] +
                    ' is earlier in this transcript.]\n' + excerpt})]
                budget_message = dict(group[0]['message'])
                if group[0]['type'] == 'assistant':
                    budget_message.update({'id': 'msg_' + '0' * 32, 'type': 'message',
                        'model': '<synthetic>', 'stop_reason': 'end_turn',
                        'stop_sequence': None, 'usage': {'input_tokens': 0, 'output_tokens': 0}})
                size = len(json.dumps(budget_message, ensure_ascii=False).encode())
            if size > remaining:
                break
            selected.append(group)
            remaining -= size

        sequence += 1
        boundary_id = _id(f'{result.session_id}:entry:{sequence}')
        result.entries.append({'parentUuid': None, 'logicalParentUuid': parent,
            'isSidechain': False, 'userType': 'external', 'entrypoint': 'cli',
            'cwd': thread.cwd, 'sessionId': result.session_id, 'version': CLAUDE_VERSION,
            'type': 'system', 'subtype': 'compact_boundary', 'content': 'Conversation compacted',
            'level': 'info', 'isMeta': False, 'uuid': boundary_id,
            'timestamp': thread.updated_at, 'compactMetadata': {'trigger': 'auto', 'preTokens': 0}})
        parent = boundary_id
        location = _bounded_text(transcript_path or ('the JSONL file for Claude session ' + result.session_id), 8192)
        handoff = (
            'This existing conversation was imported from Codex into Claude Code. '
            'This is a structural migration checkpoint, not an AI-written summary. '
            'The complete visible history remains in the native transcript before this checkpoint. '
            'Recent messages follow below with their original roles. Oversized entries are explicitly '
            'marked excerpts; their originals are still preserved. Do not replay historical commands.\n\n'
            f'Project: {_bounded_text(thread.cwd, 4096)}\nOriginal title: {_bounded_text(thread.title, 1024)}\n'
            f'Codex thread: {thread.id}\nNative transcript: {location}\n'
            f'Original history occupies the first {historical_count} JSONL records. '
            'Read earlier records when past decisions or details are needed; do not treat this tail '
            'as the entire history or ask the user to repeat information without checking. '
            'Load current project instructions from its AGENTS.md / CLAUDE.md.\n'
        )
        if compaction is not None and compaction.encrypted:
            handoff += '\nCodex also stored an encrypted internal compaction; that content could not be imported.\n'
        if compaction is not None and compaction.summary:
            handoff += '\nLatest readable Codex context summary:\n' + _bounded_text(compaction.summary, 40000)
        append('user', handoff, thread.updated_at, summary=True)
        for group in reversed(selected):
            tool_ids: dict[str, str] = {}
            for entry in group:
                content = copy.deepcopy(entry['message']['content'])
                if isinstance(content, list):
                    for block in content:
                        if block.get('type') == 'tool_use':
                            old = block['id']
                            tool_ids[old] = 'toolu_codex_' + _id(f'{result.session_id}:checkpoint:{old}').replace('-', '')
                            block['id'] = tool_ids[old]
                        elif block.get('type') == 'tool_result':
                            block['tool_use_id'] = tool_ids[block['tool_use_id']]
                append(entry['type'], content, entry['timestamp'])
        result.warnings.append('Large thread received a bounded continuation checkpoint; full native history preserved')

    title = thread.title.strip() if thread.title else f'Codex {thread.id[:8]}'
    result.entries.append({'type': 'c2c-import', 'schemaVersion': 1, 'source': 'codex',
                           'sourceThreadId': thread.id, 'lastMessageUuid': parent,
                           'sessionId': result.session_id})
    result.entries.append({'type': 'custom-title', 'customTitle': f'Codex · {title}',
                           'sessionId': result.session_id})
    errors = validate(result.entries)
    if errors:
        raise ValueError('Invalid converted session: ' + '; '.join(errors))
    return result


def validate(entries: Iterable[dict]) -> list[str]:
    """Validate invariants that prevent a native resume from orphaning content."""
    errors: list[str] = []
    seen: set[str] = set()
    session_ids: set[str] = set()
    pending: set[str] = set()
    all_tool_ids: set[str] = set()
    user_seen = False
    messages = 0
    for index, entry in enumerate(entries):
        kind = entry.get('type')
        if entry.get('sessionId'):
            session_ids.add(entry['sessionId'])
        identifier = entry.get('uuid')
        if identifier:
            if identifier in seen:
                errors.append(f'entry {index}: duplicate uuid')
            parent = entry.get('parentUuid')
            if parent is not None and parent not in seen:
                errors.append(f'entry {index}: missing parent')
            seen.add(identifier)
        if kind == 'system' and entry.get('subtype') == 'compact_boundary':
            if pending:
                errors.append(f'entry {index}: pending tool across compaction')
            if entry.get('parentUuid') is not None:
                errors.append(f'entry {index}: compaction must start a new active chain')
            continue
        if kind not in ('user', 'assistant'):
            continue
        messages += 1
        if kind == 'user':
            user_seen = True
        if entry.get('message', {}).get('role') != kind:
            errors.append(f'entry {index}: role mismatch')
        if entry.get('isSidechain') is not False or entry.get('entrypoint') != 'cli':
            errors.append(f'entry {index}: not a normal CLI session')
        content = entry.get('message', {}).get('content', [])
        if pending:
            returns = {b.get('tool_use_id') for b in content if isinstance(b, dict) and b.get('type') == 'tool_result'} if isinstance(content, list) else set()
            if kind != 'user' or not pending.issubset(returns):
                errors.append(f'entry {index}: tool results must immediately follow their calls')
        if isinstance(content, str):
            if not content:
                errors.append(f'entry {index}: empty message')
            continue
        if not content:
            errors.append(f'entry {index}: empty message')
        for block in content:
            if block.get('type') == 'tool_use':
                identifier = block.get('id')
                if identifier in all_tool_ids or not identifier:
                    errors.append(f'entry {index}: duplicate/empty tool ID')
                pending.add(identifier)
                all_tool_ids.add(identifier)
            elif block.get('type') == 'tool_result':
                identifier = block.get('tool_use_id')
                if identifier not in pending:
                    errors.append(f'entry {index}: orphan tool result')
                pending.discard(identifier)
    if pending:
        errors.append('session ends with unresolved tool calls')
    if len(session_ids) != 1:
        errors.append('session ID missing or inconsistent')
    if not messages:
        errors.append('session has no conversation messages')
    if messages and not user_seen:
        errors.append('session has no user message for discovery')
    return errors
