from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent / "reference"))

from codex_to_claude.claude_source import list_claude_threads, read_claude_entries
from codex_to_claude.source import SourceError, SourceWarning


STAMP = "2026-10-06T00:00:00.000Z"


class ClaudeSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.project = self.root / "project"
        self.project.mkdir()
        self.storage = self.root / "claude" / "projects" / "-synthetic-project"
        self.storage.mkdir(parents=True)
        self.sid = str(uuid.uuid4())
        self.path = self.storage / f"{self.sid}.jsonl"

    def message(self, identifier, parent, role, content, **extra):
        return {"type": role, "uuid": identifier, "parentUuid": parent,
                "sessionId": self.sid, "isSidechain": False, "timestamp": STAMP,
                "cwd": str(self.project), "message": {"role": role, "content": content}, **extra}

    def write(self, entries, path=None):
        target = path or self.path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("".join(json.dumps(entry) + "\n" for entry in entries))
        return target

    def threads(self, **kwargs):
        return list_claude_threads(self.root / "claude", **kwargs)

    def test_native_title_roles_and_timestamps_are_discovered(self):
        self.write([
            self.message("u1", None, "user", "Original prompt"),
            self.message("a1", "u1", "assistant", [{"type": "text", "text": "Original answer"}]),
            {"type": "ai-title", "aiTitle": "Generated title", "sessionId": self.sid},
            {"type": "custom-title", "customTitle": "User chosen title", "sessionId": self.sid},
        ])
        before = self.path.read_bytes()
        threads = self.threads()
        self.assertEqual(len(threads), 1)
        self.assertEqual(threads[0].title, "User chosen title")
        self.assertEqual(threads[0].cwd, str(self.project))
        self.assertEqual(threads[0].created_at, STAMP)
        self.assertEqual([e["type"] for e in read_claude_entries(threads[0])], ["user", "assistant"])
        self.assertEqual(self.path.read_bytes(), before)

    def test_only_latest_canonical_branch_is_selected(self):
        self.write([
            self.message("root", None, "user", "Root question"),
            self.message("old", "root", "assistant", [{"type": "text", "text": "Abandoned answer"}]),
            self.message("new", "root", "assistant", [{"type": "text", "text": "Selected answer"}]),
        ])
        self.assertEqual([e["uuid"] for e in read_claude_entries(self.threads()[0])], ["root", "new"])

    def test_compaction_bridge_preserves_archive_and_actual_summary(self):
        self.write([
            self.message("root", None, "user", "Old visible question"),
            self.message("old", "root", "assistant", [{"type": "text", "text": "Old visible answer"}]),
            {"type": "system", "subtype": "compact_boundary", "uuid": "boundary", "parentUuid": None,
             "logicalParentUuid": "old", "sessionId": self.sid, "timestamp": STAMP,
             "compactMetadata": {"trigger": "auto", "preTokens": 100}},
            self.message("summary", "boundary", "user", "Actual saved summary", isCompactSummary=True),
            self.message("recent", "summary", "user", "Continue after compaction"),
        ])
        entries = list(read_claude_entries(self.threads()[0]))
        self.assertEqual([e["uuid"] for e in entries], ["root", "old", "boundary", "summary", "recent"])
        self.assertEqual(entries[3]["message"]["content"], "Actual saved summary")

    def test_hidden_blocks_are_removed_without_losing_tool_or_image_blocks(self):
        image = {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "fixture-image-bytes"}}
        call = {"type": "tool_use", "id": "toolu_fixture", "name": "Bash", "input": {"command": "synthetic"}}
        self.write([
            self.message("u1", None, "user", [{"type": "text", "text": "See fixture"}, image]),
            self.message("thinking", "u1", "assistant", [{"type": "thinking", "thinking": "hidden-secret", "signature": "hidden-signature"}]),
            self.message("call", "thinking", "assistant", [call, {"type": "redacted_thinking", "data": "hidden-secret"}]),
            self.message("result", "call", "user", [{"type": "tool_result", "tool_use_id": "toolu_fixture", "content": "Original result"}]),
            self.message("meta", "result", "user", "hidden-runtime-instruction", isMeta=True),
        ])
        entries = list(read_claude_entries(self.threads()[0]))
        self.assertEqual([e["uuid"] for e in entries], ["u1", "call", "result"])
        self.assertEqual(entries[0]["message"]["content"][1], image)
        self.assertEqual(entries[1]["message"]["content"], [call])
        self.assertNotIn("hidden-", json.dumps(entries))

    def test_embedded_provenance_skips_unchanged_but_includes_continued_import(self):
        entries = [self.message("u1", None, "user", "Imported original"),
                   {"type": "c2c-import", "source": "codex", "sourceThreadId": "codex-original",
                    "lastMessageUuid": "u1", "sessionId": self.sid}]
        self.write(entries)
        self.assertEqual(self.threads(), [])
        inventory = self.threads(include_imported=True)
        self.assertTrue(inventory[0].unchanged_import)
        self.assertEqual(inventory[0].original_codex_id, "codex-original")
        self.write([*entries, self.message("u2", "u1", "user", "New Claude follow-up")])
        continued = self.threads()
        self.assertEqual(len(continued), 1)
        self.assertFalse(continued[0].unchanged_import)
        self.assertEqual(continued[0].original_codex_id, "codex-original")

    def test_manifest_hash_identifies_legacy_import_without_title_heuristics(self):
        first = self.message("u1", None, "user", "Original imported question")
        self.write([first])
        record = {"sessionId": self.sid, "sourceThreadId": "codex-original", "title": "Legacy import",
                  "cwd": str(self.project), "createdAt": STAMP, "updatedAt": STAMP,
                  "sha256": hashlib.sha256(self.path.read_bytes()).hexdigest()}
        self.assertEqual(self.threads(import_records=[record]), [])
        self.assertTrue(self.threads(import_records=[record], include_imported=True)[0].unchanged_import)
        self.write([first, self.message("u2", "u1", "user", "Continued in Claude")])
        thread = self.threads(import_records=[record])[0]
        self.assertFalse(thread.unchanged_import)
        self.assertEqual(thread.original_codex_id, "codex-original")

    def test_codex_title_alone_does_not_hide_a_real_claude_conversation(self):
        self.write([self.message("u1", None, "user", "Discuss Codex"),
                    {"type": "custom-title", "customTitle": "Codex · comparison", "sessionId": self.sid}])
        self.assertEqual(len(self.threads()), 1)

    def test_subagents_are_opt_in_and_keep_parent_identity(self):
        self.write([self.message("u1", None, "user", "Root prompt")])
        child = self.storage / self.sid / "subagents" / "agent-fixture.jsonl"
        self.write([self.message("child-u", None, "user", "Child prompt", isSidechain=True),
                    self.message("child-a", "child-u", "assistant", [{"type": "text", "text": "Child answer"}], isSidechain=True)], child)
        self.assertEqual(len(self.threads()), 1)
        threads = self.threads(include_subagents=True)
        self.assertEqual(len(threads), 2)
        child_thread = next(t for t in threads if t.parent_id)
        self.assertEqual(child_thread.parent_id, self.sid)
        self.assertEqual([e["uuid"] for e in read_claude_entries(child_thread)], ["child-u", "child-a"])

    def test_partial_live_final_line_does_not_discard_complete_messages(self):
        self.write([self.message("u1", None, "user", "Complete prompt")])
        with self.path.open("a") as stream:
            stream.write('{"type":"assistant"')
        with self.assertWarns(SourceWarning):
            threads = self.threads()
        with self.assertWarns(SourceWarning):
            entries = list(read_claude_entries(threads[0]))
        self.assertEqual(len(entries), 1)

    def test_metadata_only_files_are_not_conversations(self):
        self.write([{"type": "custom-title", "customTitle": "No messages", "sessionId": self.sid}])
        self.assertEqual(self.threads(), [])

    def test_cyclic_parent_chain_fails_explicitly(self):
        self.write([self.message("u1", "a1", "user", "Cyclic prompt"),
                    self.message("a1", "u1", "assistant", [{"type": "text", "text": "Cyclic answer"}])])
        with self.assertRaises(SourceError):
            list(read_claude_entries(self.threads()[0]))


if __name__ == "__main__":
    unittest.main()
