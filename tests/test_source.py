from contextlib import contextmanager
import json
from pathlib import Path
import sqlite3
import tempfile
import sys
import unittest
from unittest.mock import patch
import warnings

sys.path.insert(0, str(Path(__file__).resolve().parent / "reference"))

from codex_to_claude import source
from codex_to_claude.source import (
    Compaction, Item, SourceError, SourceWarning, Thread,
    list_threads, read_compaction, read_items,
)


@contextmanager
def connect(path):
    connection = sqlite3.connect(path)
    try:
        with connection:
            yield connection
    finally:
        connection.close()


class SourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.path = self.home / 'sessions' / 'rollout.jsonl'
        self.path.parent.mkdir()
        self.thread = Thread('thread-1', 'A title', '/project', '2026-01-01T00:00:00.000Z',
                             '2026-01-02T00:00:00.000Z', self.path)

    def write_rollout(self, *records):
        self.path.write_text(''.join(json.dumps(r) + '\n' for r in records))

    def response(self, ordinal, role, text, **kwargs):
        return {'type': 'response_item', 'ordinal': ordinal, 'timestamp': '2026-01-01T01:00:00Z',
                'payload': {'type': 'message', 'id': f'm{ordinal}', 'role': role,
                            'content': [{'type': 'input_text' if role == 'user' else 'output_text', 'text': text}], **kwargs}}

    def history(self, rows=(), cursor=None):
        path = self.home / 'thread_history_1.sqlite'
        with connect(path) as c:
            c.execute('CREATE TABLE thread_items (thread_id TEXT, item_id TEXT, item_json TEXT, created_at_ms INTEGER, rollout_ordinal INTEGER)')
            c.execute('CREATE TABLE thread_history_projection_state (thread_id TEXT, next_rollout_byte_offset INTEGER, next_rollout_ordinal INTEGER)')
            for ordinal, data in rows:
                c.execute('INSERT INTO thread_items VALUES (?,?,?,?,?)',
                          ('thread-1', data.get('id', f'i{ordinal}'), json.dumps(data), 1767225600123, ordinal))
            if cursor is not None:
                c.execute('INSERT INTO thread_history_projection_state VALUES (?,?,?)', ('thread-1', *cursor))
        return path

    def state(self, version=5, **overrides):
        path = self.home / f'state_{version}.sqlite'
        with connect(path) as c:
            c.execute('CREATE TABLE threads (id TEXT, title TEXT, cwd TEXT, created_at INTEGER, updated_at INTEGER, created_at_ms INTEGER, updated_at_ms INTEGER, rollout_path TEXT, source TEXT, archived INTEGER)')
            c.execute('CREATE TABLE thread_spawn_edges (child_thread_id TEXT, parent_thread_id TEXT)')
            d = dict(id='thread-1', title='A title', cwd='/project', created_at=1767225600,
                     updated_at=1767312000, created_at_ms=1767225600123, updated_at_ms=None,
                     rollout_path=str(self.path), source='cli', archived=0)
            d.update(overrides)
            c.execute('INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?,?)', tuple(d.values()))
        return path

    def test_projected_history_authoritative_sorted_with_live_tail(self):
        self.write_rollout(self.response(5, 'user', 'Raw duplicate'))
        offset = self.path.stat().st_size
        with self.path.open('a') as f:
            f.write(json.dumps(self.response(50, 'assistant', 'Live tail')) + '\n')
        self.history([
            (30, {'type': 'commandExecution', 'id': 'cmd', 'command': 'pwd', 'aggregatedOutput': '/project', 'exitCode': 0}),
            (6, {'type': 'userMessage', 'id': 'u', 'content': [{'type': 'text', 'text': 'Projected text'}, {'type': 'localImage', 'path': '/photo.png'}]}),
            (10, {'type': 'reasoning', 'id': 'hidden', 'content': ['private']}),
            (40, {'type': 'agentMessage', 'id': 'a', 'text': 'Answer'}),
        ], cursor=(offset, 50))
        items = list(read_items(self.thread, self.home))
        self.assertEqual([i.ordinal for i in items], [6, 30, 40, 50])
        self.assertEqual(items[0].text, 'Projected text')
        self.assertEqual(items[0].attachments[0]['media_type'], 'image/png')
        self.assertEqual(items[0].timestamp, '2026-01-01T00:00:00.123Z')
        self.assertEqual(items[1].raw['command'], 'pwd')
        self.assertEqual(items[1].text, '/project')
        self.assertEqual(items[-1].text, 'Live tail')

    def test_rollout_filters_private_and_preserves_tools_and_images(self):
        user = self.response(2, 'user', 'Look')
        user['payload']['content'].append({'type': 'input_image', 'image_url': 'https://example.test/photo.png'})
        self.write_rollout(self.response(0, 'system', 'private'), self.response(1, 'developer', 'private'), user,
                           self.response(3, 'assistant', 'private', channel='analysis'),
                           {'type': 'response_item', 'ordinal': 4, 'payload': {'type': 'function_call', 'call_id': 'tool-1', 'name': 'shell', 'arguments': '{"cmd":"pwd"}'}},
                           {'type': 'response_item', 'ordinal': 5, 'payload': {'type': 'function_call_output', 'call_id': 'tool-1', 'output': '/project'}},
                           self.response(6, 'assistant', 'Done'))
        items = list(read_items(self.thread, self.home))
        self.assertEqual([i.role for i in items], ['user', 'tool', 'tool', 'assistant'])
        self.assertEqual(items[0].attachments[0]['url'], 'https://example.test/photo.png')
        self.assertEqual(items[1].raw['name'], 'shell')
        self.assertEqual(items[2].text, '/project')

    def test_partial_live_last_line_warns_without_losing_complete_messages(self):
        self.write_rollout(self.response(2, 'user', 'Keep'))
        with self.path.open('ab') as f:
            f.write(b'{"type":"response_item","payload":')
        with self.assertWarns(SourceWarning):
            items = list(read_items(self.thread, self.home))
        self.assertEqual([i.text for i in items], ['Keep'])

    def test_malformed_complete_record_is_error_not_silent_loss(self):
        self.path.write_bytes(b'{broken record}\n')
        with self.assertRaisesRegex(SourceError, 'Malformed JSON'):
            list(read_items(self.thread, self.home))

    def test_malformed_projected_json_is_error(self):
        path = self.history([(1, {'type': 'userMessage'})])
        with connect(path) as c:
            c.execute("UPDATE thread_items SET item_json='bad json'")
        with self.assertRaises(SourceError):
            list(read_items(self.thread, self.home))

    def test_discovery_numeric_latest_version_readonly_and_fork(self):
        self.write_rollout({'type': 'session_meta', 'payload': {'id': 'thread-1', 'forked_from_id': 'parent'}})
        old = self.state(version=9, title='Old')
        latest = self.state(version=10, title='Latest')
        before = latest.read_bytes()
        threads = list_threads(self.home)
        self.assertEqual(len(threads), 1)
        self.assertEqual(threads[0].title, 'Latest')
        self.assertEqual(threads[0].parent_id, 'parent')
        self.assertEqual(threads[0].created_at, '2026-01-01T00:00:00.123Z')
        self.assertEqual(threads[0].updated_at, '2026-01-02T00:00:00.000Z')
        self.assertEqual(before, latest.read_bytes())
        self.assertTrue(old.exists())

    def test_discovery_rollout_without_database_and_parent_source(self):
        self.write_rollout({'type': 'session_meta', 'payload': {'id': 'thread-1', 'cwd': '/old project',
            'timestamp': '2026-01-01T05:30:00+05:30', 'source': {'subagent': {'thread_spawn': {'parent_thread_id': 'parent'}}}}})
        threads = list_threads(self.home)
        self.assertEqual(threads[0].parent_id, 'parent')
        self.assertEqual(threads[0].created_at, '2026-01-01T00:00:00.000Z')
        self.assertEqual(threads[0].rollout_path, self.path)
        self.assertEqual(threads[0].cwd, '/old project')

    def test_relocated_source_path_recovers_from_new_home(self):
        self.write_rollout({'type': 'session_meta', 'payload': {'id': 'thread-1'}})
        self.state(rollout_path='/old/home/.codex/sessions/rollout.jsonl')
        self.assertEqual(list_threads(self.home)[0].rollout_path, self.path)

    def test_missing_rollout_without_projection_raises(self):
        with self.assertRaisesRegex(SourceError, 'No projected history or rollout'):
            list(read_items(self.thread, self.home))

    def test_compaction_latest_retains_context_without_private_instructions(self):
        latest = {'type': 'compacted', 'ordinal': 33, 'timestamp': '2026-01-02T00:00:00Z', 'payload': {
            'message': '', 'replacement_history': [
                {'type': 'message', 'role': 'system', 'content': [{'type': 'input_text', 'text': 'Private'}]},
                {'type': 'message', 'role': 'user', 'content': [{'type': 'input_text', 'text': 'Inherited request'}]},
                {'type': 'message', 'role': 'assistant', 'channel': 'summary', 'content': [{'type': 'output_text', 'text': 'Active summary'}]},
                {'type': 'reasoning', 'encrypted_content': 'private'},
            ]}}
        self.write_rollout({'type': 'compacted', 'ordinal': 10, 'payload': {'message': 'Old'}}, latest)
        compaction = read_compaction(self.thread)
        self.assertEqual(compaction.summary, 'Active summary')
        self.assertEqual(compaction.last_ordinal, 33)
        self.assertEqual([i.text for i in compaction.items], ['Inherited request'])

    def test_encrypted_compaction_flag_does_not_export_ciphertext(self):
        self.write_rollout({'type': 'compacted', 'ordinal': 3, 'payload': {
            'message': '', 'replacement_history': [
                {'type': 'message', 'role': 'user', 'content': [{'type': 'input_text', 'text': 'Retained user context'}]},
                {'type': 'compaction', 'encrypted_content': 'SECRET CIPHERTEXT'},
            ]}})
        compaction = read_compaction(self.thread)
        self.assertTrue(compaction.encrypted)
        self.assertEqual(compaction.summary, '')
        self.assertEqual([i.text for i in compaction.items], ['Retained user context'])
        self.assertNotIn('SECRET CIPHERTEXT', repr(compaction))

    def test_relative_attachments_resolve_against_original_project(self):
        self.history([
            (1, {'type': 'userMessage', 'content': [{'type': 'localImage', 'path': 'shots/a.png'}]}),
            (2, {'type': 'imageView', 'path': 'shots/b.png'}),
        ], cursor=(0, 3))
        items = list(read_items(self.thread, self.home))
        self.assertEqual(items[0].attachments[0]['path'], '/project/shots/a.png')
        self.assertEqual(items[1].attachments[0]['path'], '/project/shots/b.png')
        self.assertEqual(items[1].raw['path'], '/project/shots/b.png')

    def test_uploaded_file_content_and_unknown_attachments_are_not_dropped(self):
        self.history([(1, {'type': 'userMessage', 'content': [
            {'type': 'input_file', 'file_id': 'file-123', 'filename': 'notes.pdf'},
            {'type': 'futureAudio', 'audio_ref': 'audio-123'},
        ]})], cursor=(0, 2))
        with self.assertWarnsRegex(SourceWarning, 'preserved as an attachment'):
            item = list(read_items(self.thread, self.home))[0]
        self.assertEqual(item.attachments[0]['file_id'], 'file-123')
        self.assertEqual(item.attachments[1]['audio_ref'], 'audio-123')

    def test_non_spawn_subagent_source_does_not_break_discovery(self):
        self.write_rollout({'type': 'session_meta', 'payload': {'id': 'thread-1'}})
        self.state(source='{"subagent":"review"}')
        self.assertIsNone(list_threads(self.home)[0].parent_id)

    def test_unknown_projected_type_warns(self):
        self.history([(5, {'type': 'newUnsupportedThing'})])
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter('always')
            self.assertEqual(list(read_items(self.thread, self.home)), [])
        self.assertTrue(any('Unsupported projected item' in str(w.message) for w in caught))

    def test_projection_past_truncated_rollout_raises(self):
        self.write_rollout(self.response(1, 'user', 'Keep'))
        self.history([(1, {'type': 'userMessage', 'content': [{'type': 'text', 'text': 'Keep'}]})], cursor=(999999, 2))
        with self.assertRaisesRegex(SourceError, 'offset exceeds'):
            list(read_items(self.thread, self.home))

    def image_event(self, ordinal, identifier, path, *, kind='ImageView'):
        return {'type': 'event_msg', 'ordinal': ordinal, 'payload': {
            'type': 'item_completed', 'item': {'type': kind, 'id': identifier, 'path': path}}}

    def image_call(self, ordinal, call_id, *, kind='function_call'):
        return {'type': 'response_item', 'ordinal': ordinal, 'payload': {
            'type': kind, 'call_id': call_id, 'name': 'view_image'}}

    def image_output(self, ordinal, call_id, *urls, kind='function_call_output'):
        return {'type': 'response_item', 'ordinal': ordinal, 'payload': {
            'type': kind, 'call_id': call_id,
            'output': [{'type': 'input_image', 'image_url': url} for url in urls]}}

    def completed_image_history(self, rows, *records):
        self.write_rollout(*records)
        self.history(rows, cursor=(self.path.stat().st_size, len(records)))

    def test_projected_image_recovers_historical_data_after_usage_record(self):
        historical = 'data:image/png;base64,aGlzdG9yaWNhbA=='
        path = self.home / 'current image.png'
        path.write_bytes(b'overwritten current image')
        for call_kind, output_kind in (
            ('function_call', 'function_call_output'),
            ('custom_tool_call', 'custom_tool_call_output'),
        ):
            with self.subTest(call_kind=call_kind):
                database = self.home / 'thread_history_1.sqlite'
                database.unlink(missing_ok=True)
                self.completed_image_history(
                    [(1, {'type': 'imageView', 'id': 'image-1', 'path': str(path)})],
                    self.image_call(0, 'call-1', kind=call_kind),
                    self.image_event(1, 'image-1', path.as_uri()),
                    {'type': 'token_usage_record', 'ordinal': 2, 'payload': {'total_tokens': 20}},
                    self.image_output(3, 'call-1', historical, kind=output_kind),
                )
                item, = list(read_items(self.thread, self.home))
                self.assertEqual(item.attachments[0]['url'], historical)
                self.assertEqual(item.attachments[0]['path'], str(path))
                self.assertEqual(item.raw['path'], str(path))
                self.assertEqual(path.read_bytes(), b'overwritten current image')

    def test_projected_user_recovers_rust_local_images_in_content_order(self):
        urls = ['data:image/png;base64,Zmlyc3Q=', 'data:image/jpeg;base64,c2Vjb25k']
        raw = self.response(5, 'user', 'Compare these')
        raw['payload']['content'].extend([
            {'type': 'input_image', 'image_url': urls[0]},
            {'type': 'input_text', 'text': 'Then this'},
            {'type': 'input_image', 'image_url': urls[1]},
        ])
        self.completed_image_history(
            [(6, {'type': 'userMessage', 'id': 'user-1', 'content': [
                {'type': 'text', 'text': 'Compare these'},
                {'type': 'localImage', 'path': 'shots/first.png'},
                {'type': 'localImage', 'path': 'shots/second.jpg'},
            ]})],
            raw,
            {'type': 'event_msg', 'ordinal': 6, 'payload': {
                'type': 'item_completed', 'item': {'type': 'UserMessage', 'id': 'user-1', 'content': [
                    {'type': 'text', 'text': 'Compare these'},
                    {'type': 'local_image', 'path': 'shots/first.png'},
                    {'type': 'local_image', 'path': 'shots/second.jpg'},
                ]}}},
        )
        item, = list(read_items(self.thread, self.home))
        self.assertEqual(item.text, 'Compare these')
        self.assertEqual([a['url'] for a in item.attachments], urls)
        self.assertEqual([a['path'] for a in item.attachments],
                         ['/project/shots/first.png', '/project/shots/second.jpg'])

    def test_projected_image_requires_matching_event_ordinal_id_and_path(self):
        for ordinal, identifier, path in (
            (2, 'image-1', 'shots/a.png'),
            (1, 'different-image', 'shots/a.png'),
            (1, 'image-1', 'shots/different.png'),
        ):
            with self.subTest(ordinal=ordinal, identifier=identifier, path=path):
                (self.home / 'thread_history_1.sqlite').unlink(missing_ok=True)
                self.completed_image_history(
                    [(1, {'type': 'imageView', 'id': 'image-1', 'path': 'shots/a.png'})],
                    self.image_call(0, 'call-1'),
                    self.image_event(ordinal, identifier, path),
                    self.image_output(3, 'call-1', 'data:image/png;base64,aGlzdG9yeQ=='),
                )
                item, = list(read_items(self.thread, self.home))
                self.assertNotIn('url', item.attachments[0])
                self.assertEqual(item.attachments[0]['path'], '/project/shots/a.png')

    def test_projected_images_refuse_multiple_events_or_emitted_images(self):
        for event_count, output_count in ((2, 1), (1, 2), (2, 2)):
            with self.subTest(event_count=event_count, output_count=output_count):
                (self.home / 'thread_history_1.sqlite').unlink(missing_ok=True)
                self.completed_image_history(
                    [(index, {'type': 'imageView', 'id': f'image-{index}', 'path': f'shots/{index}.png'})
                     for index in range(1, event_count + 1)],
                    self.image_call(0, 'call-1'),
                    *(self.image_event(index, f'image-{index}', f'shots/{index}.png')
                      for index in range(1, event_count + 1)),
                    self.image_output(3, 'call-1',
                                      *['data:image/png;base64,aGlzdG9yeQ=='] * output_count),
                )
                with self.assertWarnsRegex(SourceWarning, 'ambiguous'):
                    items = list(read_items(self.thread, self.home))
                self.assertEqual(len(items), event_count)
                self.assertTrue(all('url' not in item.attachments[0] for item in items))

    def test_projected_image_refuses_overlapping_tool_calls(self):
        self.completed_image_history(
            [(1, {'type': 'imageView', 'id': 'image-1', 'path': 'shots/a.png'}),
             (3, {'type': 'imageView', 'id': 'image-2', 'path': 'shots/b.png'})],
            self.image_call(0, 'call-1'),
            self.image_event(1, 'image-1', 'shots/a.png'),
            self.image_call(2, 'call-2', kind='custom_tool_call'),
            self.image_event(3, 'image-2', 'shots/b.png'),
            self.image_output(4, 'call-1', 'data:image/png;base64,Zmlyc3Q='),
            self.image_output(5, 'call-2', 'data:image/png;base64,c2Vjb25k', kind='custom_tool_call_output'),
        )
        with self.assertWarnsRegex(SourceWarning, 'ambiguous'):
            items = list(read_items(self.thread, self.home))
        self.assertEqual(len(items), 2)
        self.assertTrue(all('url' not in item.attachments[0] for item in items))

    def test_projected_image_refuses_remote_url_without_fetching(self):
        self.completed_image_history(
            [(1, {'type': 'imageView', 'id': 'image-1', 'path': 'shots/a.png'})],
            self.image_call(0, 'call-1'),
            self.image_event(1, 'image-1', 'shots/a.png'),
            self.image_output(2, 'call-1', 'https://example.test/historical.png'),
        )
        with patch('urllib.request.urlopen') as urlopen, patch('socket.create_connection') as connect_socket:
            with self.assertWarnsRegex(SourceWarning, 'ambiguous'):
                item, = list(read_items(self.thread, self.home))
        self.assertNotIn('url', item.attachments[0])
        urlopen.assert_not_called()
        connect_socket.assert_not_called()

    def test_projected_image_recovery_scans_rollout_once_for_multiple_targets(self):
        urls = ['data:image/png;base64,Zmlyc3Q=', 'data:image/png;base64,c2Vjb25k']
        self.write_rollout(
            self.image_call(0, 'call-1'),
            self.image_event(1, 'image-1', 'file:///project/test%20image.png'),
            self.image_output(2, 'call-1', urls[0]),
            self.image_call(3, 'call-2'),
            self.image_event(4, 'image-2', 'shots/b.png'),
            self.image_output(5, 'call-2', urls[1]),
        )
        items = [Item(identifier, 'tool', '', self.thread.updated_at, 'imageView',
                      ({'type': 'localImage', 'path': path},), ordinal=ordinal)
                 for ordinal, identifier, path in (
                     (1, 'image-1', '/project/test image.png'),
                     (4, 'image-2', '/project/shots/b.png'),
                 )]
        with patch.object(source, '_records', wraps=source._records) as records:
            recovered = source._recover_projected_images(items, self.thread)
        records.assert_called_once_with(self.path)
        self.assertEqual([item.attachments[0]['url'] for item in recovered], urls)


if __name__ == '__main__':
    unittest.main()
