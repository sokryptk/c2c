import base64
from dataclasses import replace
import json
from pathlib import Path
import tempfile
import shutil
import sqlite3
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent / "reference"))

from codex_to_claude.source import Thread, list_threads, read_items
from codex_to_claude.codex_native import (
    MAX_ACTIVE_BYTES, convert, read_origin, registration_matches, session_id,
    target_path, validate, register, unregister, _registration_preflight,
)


class CodexNativeTests(unittest.TestCase):
    def setUp(self):
        self.thread = Thread('claude-session', 'Original title', '/project',
            '2026-01-02T03:04:05.000Z', '2026-01-02T03:05:00.000Z', Path('/claude/source.jsonl'))

    def entry(self, role, content, **extra):
        return {'type': role, 'message': {'role': role, 'content': content},
                'timestamp': '2026-01-02T03:04:06.000Z', **extra}

    def test_native_model_and_visible_history_both_preserved(self):
        result = convert(self.thread, [self.entry('user', 'Question'), self.entry('assistant', 'Answer')])
        self.assertEqual(validate(result.entries), [])
        self.assertEqual(result.message_count, 2)
        self.assertEqual(result.source_item_count, 2)
        responses = [r['payload'] for r in result.entries if r['type'] == 'response_item']
        self.assertEqual([r['role'] for r in responses], ['user', 'assistant'])
        visible = [r['payload']['item'] for r in result.entries if r['payload'].get('type') == 'item_completed']
        self.assertEqual([r['type'] for r in visible], ['UserMessage', 'AgentMessage'])
        self.assertEqual(result.entries[0]['payload']['history_mode'], 'legacy')
        self.assertIsNone(result.entries[0]['payload']['base_instructions'])

    def test_completed_bash_pair_is_native_and_never_left_pending(self):
        result = convert(self.thread, [self.entry('user', 'Inspect cwd'),
            self.entry('assistant', [{'type': 'tool_use', 'id': 'call1', 'name': 'Bash', 'input': {'command': 'pwd'}}]),
            self.entry('user', [{'type': 'tool_result', 'tool_use_id': 'call1', 'content': '/project'}]),
            self.entry('assistant', 'Done')])
        self.assertEqual(validate(result.entries), [])
        self.assertEqual(result.tool_count, 1)
        tools = [r['payload'] for r in result.entries if r['type'] == 'response_item' and r['payload']['type'].startswith('function_call')]
        self.assertEqual(tools[0]['call_id'], tools[1]['call_id'])
        self.assertEqual(tools[1]['output'], '/project')
        commands = [r['payload']['item'] for r in result.entries if r['payload'].get('item', {}).get('type') == 'CommandExecution']
        self.assertEqual(commands[0]['command'], ['bash', '-lc', 'pwd'])
        self.assertEqual(commands[0]['aggregated_output'], '/project')

    def test_tool_result_images_remain_native_images_not_base64_text(self):
        encoded = base64.b64encode(b'fake image bytes').decode()
        result = convert(self.thread, [self.entry('user', 'Show image'),
            self.entry('assistant', [{'type': 'tool_use', 'id': 'call1', 'name': 'Read', 'input': {'file_path': '/pic.png'}}]),
            self.entry('user', [{'type': 'tool_result', 'tool_use_id': 'call1', 'content': [
                {'type': 'text', 'text': 'Photo'}, {'type': 'image', 'source': {'type': 'base64', 'media_type': 'image/png', 'data': encoded}}]}])])
        output = next(r['payload']['output'] for r in result.entries if r['payload'].get('type') == 'function_call_output')
        self.assertEqual([b['type'] for b in output], ['input_text', 'input_image'])
        self.assertTrue(output[1]['image_url'].endswith(encoded))
        artifacts = [r['payload']['item'] for r in result.entries if r['payload'].get('item', {}).get('type') == 'AgentMessage']
        self.assertNotIn(encoded, json.dumps(artifacts))

    def test_mixed_tool_result_and_text_does_not_close_pending_too_early(self):
        result = convert(self.thread, [self.entry('user', 'Run'),
            self.entry('assistant', [{'type': 'tool_use', 'id': 'call1', 'name': 'Bash', 'input': {'command': 'pwd'}}]),
            self.entry('user', [{'type': 'text', 'text': 'Result follows'}, {'type': 'tool_result', 'tool_use_id': 'call1', 'content': '/project'}])])
        self.assertEqual(result.warnings, [])
        self.assertEqual(result.tool_count, 1)

    def test_missing_tool_result_is_explicit_and_closed(self):
        result = convert(self.thread, [self.entry('user', 'Run'), self.entry('assistant', [
            {'type': 'tool_use', 'id': 'call1', 'name': 'Bash', 'input': {'command': 'pwd'}}])])
        self.assertTrue(any('Incomplete' in w for w in result.warnings))
        self.assertEqual(validate(result.entries), [])
        self.assertIn('did not execute', next(r['payload']['output'] for r in result.entries if r['payload'].get('type') == 'function_call_output'))

    def test_claude_compaction_preserves_summary_and_subsequent_messages(self):
        result = convert(self.thread, [self.entry('user', 'Old request'), self.entry('assistant', 'Old answer'),
            {'type': 'system', 'subtype': 'compact_boundary'},
            self.entry('user', 'Exact saved Claude summary', isCompactSummary=True),
            self.entry('user', 'Continue'), self.entry('assistant', 'New answer')])
        compacted = next(r for r in result.entries if r['type'] == 'compacted')
        self.assertEqual(compacted['payload']['message'], 'Exact saved Claude summary')
        self.assertEqual(compacted['payload']['replacement_history'][0]['content'][0]['text'], 'Exact saved Claude summary')
        self.assertEqual(result.message_count, 5)
        self.assertEqual(validate(result.entries), [])

    def test_large_single_turn_context_is_bounded_and_truncation_labelled(self):
        entries = [self.entry('user', 'First request'), self.entry('assistant', 'x' * 300_000)]
        for _ in range(20):
            entries.append(self.entry('assistant', 'y' * 80_000))
        result = convert(self.thread, entries, transcript_path='/native/session.jsonl')
        compacted = result.entries[-1]
        self.assertEqual(compacted['type'], 'compacted')
        self.assertLess(len(json.dumps(compacted['payload']['replacement_history']).encode()), MAX_ACTIVE_BYTES)
        self.assertIn('excerpt shortened', json.dumps(compacted))
        self.assertIn('/native/session.jsonl', compacted['payload']['message'])
        self.assertEqual(result.message_count, len(entries))

    def test_private_thinking_is_excluded(self):
        result = convert(self.thread, [self.entry('user', 'Request'), self.entry('assistant', [
            {'type': 'thinking', 'thinking': 'hidden secret'}, {'type': 'text', 'text': 'Visible'}])])
        self.assertNotIn('hidden secret', json.dumps(result.entries))
        self.assertIn('Visible', json.dumps(result.entries))

    def test_provenance_survives_migration_but_detects_continuation(self):
        result = convert(self.thread, [self.entry('user', 'Q'), self.entry('assistant', 'A')])
        migrated = json.loads(json.dumps(result.entries))
        for i, row in enumerate(migrated):
            row['ordinal'] = i
        migrated[0]['payload']['history_mode'] = 'paginated'
        self.assertTrue(registration_matches(result.entries, migrated))
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'rollout.jsonl'
            p.write_text(''.join(json.dumps(r) + '\n' for r in migrated))
            thread = replace(self.thread, rollout_path=p)
            self.assertEqual(read_origin(thread), (self.thread.id, True))
            with p.open('a') as f:
                f.write(json.dumps({'type': 'response_item', 'payload': {'type': 'message', 'role': 'user', 'content': []}}) + '\n')
            self.assertEqual(read_origin(thread), (self.thread.id, False))
        self.assertFalse(registration_matches(result.entries, [*migrated, {'type': 'new-record'}]))
        migrated[-1]['payload']['duration_ms'] = 123
        self.assertFalse(registration_matches(result.entries, migrated))

    @unittest.skipUnless(shutil.which('codex'), 'Codex CLI required for native registration test')
    def test_real_native_registration_provenance_discovery_and_undo(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            (home / 'config.toml').write_text('model_provider="local_mock"\nmodel="mock"\n'
                '[model_providers.local_mock]\nname="local mock"\n'
                'base_url="http://127.0.0.1:1/v1"\nwire_api="responses"\n')
            destination = target_path(self.thread, home)
            destination.parent.mkdir(parents=True)
            converted = convert(self.thread, [self.entry('user', 'Synthetic request'),
                self.entry('assistant', [{'type': 'tool_use', 'id': 'call1', 'name': 'Bash', 'input': {'command': 'pwd'}}]),
                self.entry('user', [{'type': 'tool_result', 'tool_use_id': 'call1', 'content': '/project'}]),
                self.entry('assistant', 'Synthetic reply'), {'type': 'system', 'subtype': 'compact_boundary'},
                self.entry('user', 'Exact synthetic summary', isCompactSummary=True), self.entry('user', 'Continue'),
                self.entry('assistant', 'New response')])
            destination.write_text(''.join(json.dumps(row) + '\n' for row in converted.entries))
            register(home, converted.session_id, 'Synthetic imported title')
            migrated = [json.loads(line) for line in destination.read_text().splitlines()]
            self.assertTrue(registration_matches(converted.entries, migrated))
            imported = next(t for t in list_threads(home) if t.id == converted.session_id)
            self.assertEqual(imported.title, 'Synthetic imported title')
            self.assertEqual(imported.original_claude_id, self.thread.id)
            self.assertTrue(imported.unchanged_import)
            self.assertIn('commandExecution', [item.kind for item in read_items(imported, home)])
            register(home, converted.session_id, 'Different retry title')
            self.assertEqual(next(t for t in list_threads(home) if t.id == converted.session_id).title,
                             'Synthetic imported title')
            with destination.open('a') as stream:
                stream.write(json.dumps({'type': 'response_item', 'timestamp': self.thread.updated_at,
                    'payload': {'type': 'message', 'role': 'user', 'content': [{'type': 'input_text', 'text': 'Continuation'}]}}) + '\n')
            changed = next(t for t in list_threads(home) if t.id == converted.session_id)
            self.assertFalse(changed.unchanged_import)
            with self.assertRaisesRegex(RuntimeError, 'changed before native registration'):
                _registration_preflight(home, converted.session_id)
            # Undo requires the original registered bytes.
            destination.write_text(''.join(json.dumps(row) + '\n' for row in migrated))
            unregister(home, converted.session_id)
            self.assertFalse(destination.exists())
            self.assertFalse(any(t.id == converted.session_id for t in list_threads(home)))

    def test_registration_refuses_id_already_bound_to_another_path(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            destination = target_path(self.thread, home)
            destination.parent.mkdir(parents=True)
            converted = convert(self.thread, [self.entry('user', 'Question')])
            destination.write_text(''.join(json.dumps(row) + '\n' for row in converted.entries))
            connection = sqlite3.connect(home / 'state_5.sqlite')
            try:
                connection.execute('CREATE TABLE threads (id TEXT, rollout_path TEXT, archived INTEGER)')
                connection.execute('INSERT INTO threads VALUES (?,?,?)', (converted.session_id, '/archived/original.jsonl', 1))
                connection.commit()
            finally:
                connection.close()
            with self.assertRaisesRegex(RuntimeError, 'archived or different native path'):
                _registration_preflight(home, converted.session_id)

    def test_target_paths_and_ids_are_deterministic_and_source_distinct(self):
        self.assertEqual(target_path(self.thread, '/tmp/codex-home').parent, Path('/tmp/codex-home/sessions/2026/01/02'))
        self.assertEqual(session_id(self.thread.id), session_id(self.thread.id))
        self.assertNotEqual(session_id('one'), session_id('two'))
        self.assertEqual(session_id(self.thread.id), convert(self.thread, []).session_id)


if __name__ == '__main__':
    unittest.main()
