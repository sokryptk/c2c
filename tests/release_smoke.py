import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class ReleaseSmoke(unittest.TestCase):
    binary: Path

    def test_codex_to_claude_lifecycle(self):
        with tempfile.TemporaryDirectory(prefix="c2c-release-smoke-") as temporary:
            root = Path(temporary)
            user_home = root / "home"
            user_home.mkdir()
            homes = {
                provider: root / provider for provider in ("codex", "claude", "omp", "opencode")
            }
            journal = root / "journal"
            identifier = "00000000-0000-4000-8000-000000000001"
            source = homes["codex"] / "sessions" / f"rollout-{identifier}.jsonl"
            source.parent.mkdir(parents=True)
            records = [
                {
                    "timestamp": "2026-10-01T00:00:00Z",
                    "type": "session_meta",
                    "payload": {
                        "id": identifier,
                        "cwd": str(root),
                        "timestamp": "2026-10-01T00:00:00Z",
                        "history_mode": "legacy",
                    },
                }
            ]
            for second, role, kind, text in (
                (1, "user", "input_text", "Synthetic release smoke prompt"),
                (2, "assistant", "output_text", "Synthetic release smoke reply"),
            ):
                records.append(
                    {
                        "timestamp": f"2026-10-01T00:00:0{second}Z",
                        "type": "response_item",
                        "payload": {
                            "type": "message",
                            "role": role,
                            "content": [{"type": kind, "text": text}],
                        },
                    }
                )
            original = ("\n".join(json.dumps(record) for record in records) + "\n").encode()
            source.write_bytes(original)
            environment = {
                key: value for key, value in os.environ.items() if key in ("PATH", "LANG")
            }
            environment["HOME"] = str(user_home)
            options = ["--from", "codex", "--to", "claude", "--output-dir", str(journal), "--json"]
            for provider, directory in homes.items():
                options.extend([f"--{provider}-home", str(directory)])

            def run(action, status):
                completed = subprocess.run(
                    [str(self.binary), action, *options],
                    cwd=root,
                    env=environment,
                    capture_output=True,
                    text=True,
                    encoding="utf-8",
                    timeout=30,
                )
                self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
                result = json.loads(completed.stdout)
                self.assertEqual(result["direction"], "codex-to-claude")
                self.assertEqual(result["counts"], {status: 1}, result)
                self.assertEqual(len(result["threads"]), 1, result)
                row = result["threads"][0]
                self.assertEqual(row["sourceThreadId"], identifier, result)
                self.assertEqual(row["status"], status, result)
                self.assertEqual(source.read_bytes(), original, "Source conversation was changed")
                return row

            run("inventory", "available")
            self.assertFalse(journal.exists(), "Inventory must not create a migration journal")
            installed = run("migrate", "installed")
            target = Path(installed["targetPath"])
            self.assertTrue(target.is_relative_to(homes["claude"]))
            converted = target.read_bytes()
            for text in (b"Synthetic release smoke prompt", b"Synthetic release smoke reply"):
                self.assertIn(text, converted)
            manifest = journal / "manifest.json"
            self.assertEqual(
                json.loads(manifest.read_text())["imports"][identifier]["status"], "installed"
            )
            run("verify", "verified")
            repeated = run("migrate", "unchanged")
            self.assertEqual(repeated["sessionId"], installed["sessionId"])
            self.assertEqual(target.read_bytes(), converted)
            undone = run("undo", "undone")
            self.assertFalse(
                target.exists(), "Undo must remove the unchanged imported conversation"
            )
            retained = Path(undone["retainedPath"])
            self.assertTrue(retained.is_relative_to(homes["claude"]))
            self.assertEqual(retained.read_bytes(), converted)
            undo_record = json.loads(manifest.read_text())["imports"][identifier]
            self.assertEqual(undo_record["status"], "undone")
            self.assertEqual(undo_record["undoBackupPath"], str(retained))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: python3 tests/release_smoke.py /path/to/c2c")
    ReleaseSmoke.binary = Path(sys.argv[1]).resolve(strict=True)
    unittest.main(argv=[sys.argv[0]], verbosity=2)
