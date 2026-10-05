from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import io
import json
from pathlib import Path
import tempfile
import sys
import unittest
from unittest.mock import patch
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent / "reference"))

from codex_to_claude import cli
from codex_to_claude.native import convert, project_directory
from codex_to_claude.source import Item, Thread


class _CliFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        home = patch("codex_to_claude.cli.Path.home", return_value=self.root)
        home.start()
        self.addCleanup(home.stop)
        self.source = self.root / "codex"
        self.destination = self.root / "claude"
        self.output = self.root / "bridge"
        self.source.mkdir()
        self.threads = []
        self.items = {}
        for name, target in (
            ("list_threads", lambda home: self.threads),
            ("read_items", lambda thread, home: iter(self.items[thread.id])),
            ("read_compaction", lambda thread: None),
        ):
            mock = patch("codex_to_claude.source." + name, side_effect=target)
            mock.start()
            self.addCleanup(mock.stop)

    def thread(self, identifier="thread-one", cwd=None, empty=False):
        path = self.source / f"{identifier}.jsonl"
        path.write_text('{}\n', encoding="utf-8")
        thread = Thread(identifier, "Fixture conversation", cwd or str(self.root / "project"), "2026-10-01T00:00:00Z", "2026-10-01T00:00:00Z", path)
        self.threads.append(thread)
        self.items[identifier] = [] if empty else [
            Item(identifier + "-user", "user", "A synthetic fixture", "2026-10-01T00:00:00Z", "userMessage"),
            Item(identifier + "-assistant", "assistant", "A synthetic response", "2026-10-01T00:00:01Z", "agentMessage"),
        ]
        return thread

    def call(self, command, *args):
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            code = cli.main([command, "--codex-home", str(self.source), "--claude-home", str(self.destination), "--output-dir", str(self.output), "--json", *args])
        return code, json.loads(stdout.getvalue())

    def target(self, thread):
        conversion = convert(thread, self.items[thread.id])
        return self.destination / "projects" / project_directory(thread.cwd) / f"{conversion.session_id}.jsonl"


class CliTests(_CliFixture):
    def test_install_verify_idempotent_and_undo(self):
        thread = self.thread()
        source_bytes = thread.rollout_path.read_bytes()
        code, result = self.call("migrate")
        self.assertEqual(code, 0, result)
        self.assertEqual(result["counts"], {"installed": 1})
        target = self.target(thread)
        self.assertTrue(target.is_file())
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)
        imported_bytes = target.read_bytes()
        self.assertEqual(self.call("verify")[1]["counts"], {"verified": 1})
        self.assertEqual(self.call("migrate")[1]["counts"], {"unchanged": 1})
        self.assertEqual(target.read_bytes(), imported_bytes)
        undone = self.call("undo")[1]
        self.assertEqual(undone["counts"], {"undone": 1})
        self.assertEqual(Path(undone["threads"][0]["retainedPath"]).read_bytes(), imported_bytes)
        self.assertFalse(target.exists())
        self.assertEqual(thread.rollout_path.read_bytes(), source_bytes)

    def test_continued_session_is_preserved_on_migrate_and_undo(self):
        thread = self.thread()
        self.call("migrate")
        target = self.target(thread)
        # A title update is a real native metadata record; it is a modification
        # worth protecting even when no new model turn has been sent yet.
        with target.open("a") as stream:
            stream.write(json.dumps({"type": "custom-title", "sessionId": target.stem, "customTitle": "Continued in Claude"}) + "\n")
        continued_bytes = target.read_bytes()
        self.assertEqual(self.call("verify")[1]["counts"], {"continued": 1})
        self.assertEqual(self.call("migrate")[1]["counts"], {"continued": 1})
        self.assertEqual(self.call("undo")[1]["counts"], {"preserved": 1})
        self.assertEqual(target.read_bytes(), continued_bytes)

    def test_collision_never_overwrites_or_deletes(self):
        thread = self.thread()
        target = self.target(thread)
        target.parent.mkdir(parents=True)
        target.write_text("existing private conversation\n")
        code, result = self.call("migrate")
        self.assertEqual(code, 1)
        self.assertEqual(result["counts"], {"collision": 1})
        self.call("undo")
        self.assertEqual(target.read_text(), "existing private conversation\n")

    def test_partial_conversion_failure_installs_other_thread(self):
        first = self.thread()
        second = self.thread("thread-two")
        self.items[second.id] = None
        code, result = self.call("migrate")
        self.assertEqual(code, 1)
        self.assertEqual(result["counts"], {"installed": 1, "error": 1})
        self.assertTrue(self.target(first).exists())
        self.assertEqual(result["threads"][1]["phase"], "conversion")

    def test_all_conversions_complete_before_any_install(self):
        first = self.thread()
        self.thread("thread-two")
        seen = []
        real = cli._install

        def install(options, manifest, record):
            self.assertEqual(len(manifest["imports"]), 2)
            seen.append(record["sourceThreadId"])
            return real(options, manifest, record)

        with patch.object(cli, "_install", side_effect=install):
            self.assertEqual(self.call("migrate")[0], 0)
        self.assertEqual(seen[0], first.id)
        self.assertEqual(len(seen), 2)

    def test_metadata_only_thread_is_reported_without_native_chat(self):
        self.thread(empty=True)
        self.assertEqual(self.call("migrate")[1]["counts"], {"metadata-only": 1})
        self.assertFalse(self.destination.exists())

    def test_missing_rollout_with_projected_messages_is_supported(self):
        thread = self.thread()
        thread.rollout_path.unlink()
        self.assertEqual(self.call("migrate")[1]["counts"], {"installed": 1})

    def test_exact_and_prefix_project_filtering(self):
        self.thread("base", cwd="/project/base")
        self.thread("child", cwd="/project/base/sub")
        self.thread("other", cwd="/project/basement")
        code, result = self.call("inventory", "--project", "/project/base")
        self.assertEqual(code, 0)
        self.assertEqual([row["sourceThreadId"] for row in result["threads"]], ["base"])
        result = self.call("inventory", "--project-prefix", "/project/base")[1]
        self.assertEqual([row["sourceThreadId"] for row in result["threads"]], ["base", "child"])

    def test_named_direction_defaults_to_migrate(self):
        thread = self.thread()
        code, result = self.call("codex-to-claude")
        self.assertEqual(code, 0, result)
        self.assertEqual(result["direction"], "codex-to-claude")
        self.assertTrue(self.target(thread).exists())

    def test_named_direction_accepts_nested_action(self):
        self.thread()
        code, result = self.call("codex-to-claude", "inventory")
        self.assertEqual(code, 0, result)
        self.assertEqual(result["counts"], {"available": 1})
        self.assertFalse(self.destination.exists())

    def test_generic_action_accepts_direction_option(self):
        self.thread()
        code, result = self.call("migrate", "--direction", "codex-to-claude")
        self.assertEqual(code, 0, result)
        self.assertEqual(result["counts"], {"installed": 1})

    def test_legacy_manifest_without_direction_is_forward_compatible(self):
        self.thread()
        self.call("migrate")
        path = self.output / "manifest.json"
        manifest = json.loads(path.read_text())
        manifest.pop("direction")
        path.write_text(json.dumps(manifest))
        self.assertEqual(self.call("codex-to-claude")[1]["counts"], {"unchanged": 1})

    def test_unchanged_round_trip_does_not_duplicate_original(self):
        thread = self.thread()
        origin = self.root / "reverse-origin.json"
        origin.write_text(json.dumps({
            "direction": "claude-to-codex", "codexHome": str(self.source), "claudeHome": str(self.destination),
            "imports": {"original-claude-session": {"sourceThreadId": "original-claude-session", "sessionId": thread.id, "status": "installed", "sha256": cli._digest(thread.rollout_path)}},
        }))
        code, result = self.call("codex-to-claude", "--origin-manifest", str(origin))
        self.assertEqual(code, 0, result)
        self.assertEqual(result["counts"], {"already-origin": 1})
        self.assertFalse(self.destination.exists())
        self.assertEqual(self.call("inventory", "--origin-manifest", str(origin))[1]["counts"], {"already-origin": 1})
        thread.rollout_path.write_text('{}\n{"new":"continuation"}\n')
        code, result = self.call("codex-to-claude", "--origin-manifest", str(origin))
        self.assertEqual(code, 0, result)
        self.assertEqual(result["counts"], {"installed": 1})
        self.assertTrue(self.target(thread).exists())

    def test_changed_source_reports_without_overwriting_import(self):
        thread = self.thread()
        self.call("migrate")
        target_bytes = self.target(thread).read_bytes()
        thread.rollout_path.write_text('{}\n{}\n')
        _, result = self.call("migrate")
        self.assertTrue(result["threads"][0]["sourceChanged"])
        self.assertEqual(self.target(thread).read_bytes(), target_bytes)

    def test_install_failure_is_resumable(self):
        thread = self.thread()
        with patch("codex_to_claude.cli.os.link", side_effect=OSError("simulated crash")):
            code, result = self.call("migrate")
        self.assertEqual(code, 1)
        self.assertEqual(result["threads"][0]["phase"], "installation")
        self.assertFalse(self.target(thread).exists())
        self.assertEqual(self.call("migrate")[1]["counts"], {"installed": 1})
        self.assertEqual(self.call("verify")[1]["counts"], {"verified": 1})

    def test_recover_crash_after_link_before_manifest_save(self):
        thread = self.thread()
        actual_save = cli._save

        def fail_after_link(options, manifest):
            if any(record.get("status") == "installed" for record in manifest["imports"].values()):
                raise OSError("simulated crash after publication")
            actual_save(options, manifest)

        with patch.object(cli, "_save", side_effect=fail_after_link):
            self.assertEqual(self.call("migrate")[0], 1)
        self.assertTrue(self.target(thread).exists())
        self.assertEqual(self.call("migrate")[1]["counts"], {"unchanged": 1})
        self.assertEqual(self.call("undo")[1]["counts"], {"undone": 1})

    def test_lock_prevents_overlapping_bridge_operations(self):
        self.thread()
        with cli._lock(self.output):
            code, result = self.call("migrate")
        self.assertEqual(code, 1)
        self.assertIn("Another migration", result["error"])

    def test_undo_retains_writes_from_an_open_native_file(self):
        thread = self.thread()
        self.call("migrate")
        target = self.target(thread)
        with target.open("a") as writer:
            _, result = self.call("undo")
            writer.write("concurrent continuation retained\n")
            writer.flush()
        self.assertFalse(target.exists())
        retained = Path(result["threads"][0]["retainedPath"])
        self.assertIn("concurrent continuation retained", retained.read_text())

    def test_reimport_keeps_provenance_of_undo_backup(self):
        self.thread()
        self.call("migrate")
        _, undone = self.call("undo")
        backup = undone["threads"][0]["retainedPath"]
        self.assertEqual(self.call("migrate")[1]["counts"], {"installed": 1})
        manifest = json.loads((self.output / "manifest.json").read_text())
        self.assertEqual(manifest["retainedUndos"][0]["undoBackupPath"], backup)
        self.assertTrue(Path(backup).exists())

    def test_verify_missing_native_session_fails(self):
        thread = self.thread()
        self.call("migrate")
        self.target(thread).unlink()
        code, result = self.call("verify")
        self.assertEqual(code, 1)
        self.assertEqual(result["counts"], {"missing": 1})

    def test_undo_recovers_interruption_after_removal(self):
        thread = self.thread()
        self.call("migrate")
        actual_save = cli._save

        def fail_after_remove(options, manifest):
            if any(record.get("status") == "undone" for record in manifest["imports"].values()):
                raise OSError("simulated crash after removal")
            actual_save(options, manifest)

        with patch.object(cli, "_save", side_effect=fail_after_remove):
            self.assertEqual(self.call("undo")[0], 1)
        self.assertFalse(self.target(thread).exists())
        self.assertEqual(self.call("verify")[1]["counts"], {"undone": 1})
        manifest = json.loads((self.output / "manifest.json").read_text())
        self.assertTrue(Path(manifest["imports"][thread.id]["undoBackupPath"]).is_file())

    def test_mismatched_homes_reject_reused_manifest(self):
        self.thread()
        self.call("migrate")
        self.destination = self.root / "another-claude"
        code, result = self.call("migrate")
        self.assertEqual(code, 1)
        self.assertIn("different source or destination", result["error"])

    def test_symlink_destination_outside_claude_is_rejected(self):
        thread = self.thread()
        outside = self.root / "unrelated"
        outside.mkdir()
        target = self.target(thread)
        target.parent.parent.mkdir(parents=True)
        target.parent.symlink_to(outside, target_is_directory=True)
        self.assertEqual(self.call("migrate")[0], 1)
        self.assertEqual(list(outside.iterdir()), [])


class ReverseCliTests(_CliFixture):
    """Exercise the actual reverse reader/encoder; mock native registration only."""

    def setUp(self):
        super().setUp()
        original = self.thread()
        conversion = convert(original, self.items[original.id])
        self.claude_id = conversion.session_id
        self.claude_file = self.target(original)
        self.claude_file.parent.mkdir(parents=True)
        self.claude_entries = [entry for entry in conversion.entries if entry.get("type") != "c2c-import"]
        self.claude_file.write_text("".join(json.dumps(entry) + "\n" for entry in self.claude_entries))
        self.register_calls = 0
        self.unregister_calls = 0
        self.registration_failure = None
        register = patch("codex_to_claude.codex_native.register", side_effect=self.register)
        unregister = patch("codex_to_claude.codex_native.unregister", side_effect=self.unregister)
        register.start()
        unregister.start()
        self.addCleanup(register.stop)
        self.addCleanup(unregister.stop)

    def registered_path(self, identifier=None):
        from codex_to_claude.codex_native import session_id

        return next((self.source / "sessions").rglob(f"*{identifier or session_id(self.claude_id)}.jsonl"))

    def register(self, home, identifier, title):
        self.register_calls += 1
        path = self.registered_path(identifier)
        rows = cli._read_entries(path)
        for ordinal, row in enumerate(rows):
            row["ordinal"] = ordinal
            if row.get("type") == "session_meta":
                row["payload"]["history_mode"] = "paginated"
                row["payload"].setdefault("base_instructions", None)
        path.write_text("".join(json.dumps(row) + "\n" for row in rows))
        if self.registration_failure:
            raise self.registration_failure
        return {"registered": True}

    def unregister(self, home, identifier):
        self.unregister_calls += 1
        paths = list((self.source / "sessions").rglob(f"*{identifier}.jsonl"))
        for path in paths:
            path.unlink()

    def reverse(self, action="migrate", *args):
        return self.call("claude-to-codex", action, *args)

    def test_reverse_installs_registers_and_verifies_final_native_hash(self):
        code, result = self.reverse()
        self.assertEqual(code, 0, result)
        self.assertEqual(result["counts"], {"installed": 1})
        self.assertEqual(self.register_calls, 1)
        record = json.loads((self.output / "manifest.json").read_text())["imports"][self.claude_id]
        self.assertNotEqual(record["sourceConversionSha256"], record["sha256"])
        self.assertEqual(record["sha256"], cli._digest(self.registered_path()))
        self.assertEqual(self.reverse("verify")[1]["counts"], {"verified": 1})
        self.assertEqual(self.reverse()[1]["counts"], {"unchanged": 1})
        self.assertEqual(self.register_calls, 1)

    def test_reverse_registration_failure_recovers_after_native_rewrite(self):
        self.registration_failure = RuntimeError("native registration interrupted")
        code, result = self.reverse()
        self.assertEqual(code, 1, result)
        self.assertEqual(self.reverse("verify")[1]["counts"], {"pending-registration": 1})
        self.registration_failure = None
        self.assertEqual(self.reverse()[1]["counts"], {"installed": 1})
        self.assertEqual(self.reverse("verify")[1]["counts"], {"verified": 1})

    def test_reverse_registration_retry_preserves_new_native_messages(self):
        self.registration_failure = RuntimeError("native registration interrupted")
        self.reverse()
        path = self.registered_path()
        with path.open("a") as stream:
            stream.write(json.dumps({"timestamp": "2026-10-01T00:00:10Z", "type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "Continued in Codex"}]}}) + "\n")
        changed = path.read_bytes()
        self.registration_failure = None
        code, result = self.reverse()
        self.assertEqual(code, 1, result)
        self.assertEqual(self.register_calls, 1)
        self.assertEqual(path.read_bytes(), changed)

    def test_reverse_undo_uses_native_unregister_and_keeps_backup(self):
        self.reverse()
        path = self.registered_path()
        native_bytes = path.read_bytes()
        code, result = self.reverse("undo")
        self.assertEqual(code, 0, result)
        self.assertEqual(result["counts"], {"undone": 1})
        self.assertFalse(path.exists())
        self.assertEqual(self.unregister_calls, 1)
        self.assertEqual(Path(result["threads"][0]["retainedPath"]).read_bytes(), native_bytes)

    def test_reverse_unchanged_forward_import_is_skipped(self):
        self.claude_entries.append({"type": "c2c-import", "source": "codex", "sourceThreadId": "original-codex", "lastMessageUuid": [entry["uuid"] for entry in self.claude_entries if entry.get("type") in ("user", "assistant")][-1]})
        self.claude_file.write_text("".join(json.dumps(entry) + "\n" for entry in self.claude_entries))
        code, result = self.reverse()
        self.assertEqual(code, 0, result)
        self.assertEqual(result["counts"], {"already-origin": 1})
        self.assertEqual(self.register_calls, 0)

    def test_reverse_continued_forward_import_becomes_new_codex_thread(self):
        parent = [entry["uuid"] for entry in self.claude_entries if entry.get("type") in ("user", "assistant")][-1]
        original_id = str(uuid.uuid4())
        self.claude_entries.append({"type": "c2c-import", "source": "codex", "sourceThreadId": original_id, "lastMessageUuid": parent})
        self.claude_entries.append({"type": "user", "uuid": str(uuid.uuid4()), "parentUuid": parent, "sessionId": self.claude_id, "cwd": str(self.root / "project"), "timestamp": "2026-10-01T00:00:10Z", "message": {"role": "user", "content": "A new turn in Claude"}})
        self.claude_file.write_text("".join(json.dumps(entry) + "\n" for entry in self.claude_entries))
        code, result = self.reverse()
        self.assertEqual(code, 0, result)
        self.assertEqual(result["counts"], {"installed": 1})
        meta = cli._read_entries(self.registered_path())[0]["payload"]
        self.assertNotEqual(meta["id"], original_id)
        self.assertEqual(meta["forked_from_id"], original_id)

    def test_reverse_does_not_reuse_forward_journal(self):
        self.call("migrate")
        code, result = self.reverse()
        self.assertEqual(code, 1, result)
        self.assertIn("opposite migration direction", result["error"])


if __name__ == "__main__":
    unittest.main()
