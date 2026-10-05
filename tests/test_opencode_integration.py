"""Opt-in OpenCode v2 native import, resume, round-trip and safe undo tests.

RUN_OPENCODE_INTEGRATION=1 C2C_OPENCODE_BINARY=/path/to/opencode python -m unittest discover -s tests -p test_opencode_integration.py -v
No production Python modules, real account credentials, or external model calls.
"""
from __future__ import annotations
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest

import test_zig_integration as native_tests
from test_zig_integration import CLAUDE_REPLY, PIXEL


@unittest.skipUnless(os.environ.get("RUN_OPENCODE_INTEGRATION") == "1", "set RUN_OPENCODE_INTEGRATION=1 for native OpenCode tests")
class OpenCodeNativeIntegrationTests(unittest.TestCase):
    _close = native_tests.ZigNativeIntegrationTests._close
    _run = native_tests.ZigNativeIntegrationTests._run
    _write_claude = native_tests.ZigNativeIntegrationTests._write_claude
    _claude_turn = native_tests.ZigNativeIntegrationTests._claude_turn
    _claude_paths = native_tests.ZigNativeIntegrationTests._claude_paths
    _codex_paths = native_tests.ZigNativeIntegrationTests._codex_paths
    _session_id = staticmethod(native_tests.ZigNativeIntegrationTests._session_id)
    _codex_args = native_tests.ZigNativeIntegrationTests._codex_args
    _codex_turn = native_tests.ZigNativeIntegrationTests._codex_turn
    _read_codex = native_tests.ZigNativeIntegrationTests._read_codex

    def setUp(self):
        native_tests.ZigNativeIntegrationTests.setUp(self)
        self.opencode = os.environ.get("C2C_OPENCODE_BINARY") or shutil.which("opencode")
        if not self.opencode:
            self.skipTest("OpenCode v2 is not installed; set C2C_OPENCODE_BINARY")
        self.opencode_home = self.root / "opencode"
        self.opencode_home.mkdir()
        self.env.update(C2C_OPENCODE_BINARY=self.opencode,
                        OPENCODE_DB=str(self.opencode_home / "opencode.db"),
                        OPENCODE_CONFIG_DIR=str(self.user_home / "config"),
                        XDG_DATA_HOME=str(self.user_home / "data"),
                        XDG_STATE_HOME=str(self.user_home / "state"),
                        XDG_CACHE_HOME=str(self.user_home / "cache"),
                        OPENCODE_DISABLE_PROJECT_CONFIG="1", OPENCODE_DISABLE_MODELS_FETCH="1",
                        OPENCODE_DISABLE_FILEWATCHER="1")
        (self.user_home / "config").mkdir()
        self.config = {
            "update": "disable", "share": "disabled", "snapshots": False, "warming": False,
            "model": "anthropic/claude-sonnet-4-6", "mcp": {},
            "providers": {"anthropic": {
                "settings": {"baseURL": self.base + "/anthropic/v1", "transport": "http"},
                "models": {"claude-sonnet-4-6": {"limit": {"context": 200000, "output": 8192}}},
            }},
        }
        self.env["OPENCODE_CONFIG_CONTENT"] = json.dumps(self.config)

    def migrate(self, source, target, action="migrate"):
        before = len(self.server.requests)
        result = self._run([self.binary, action, "--from", source, "--to", target,
                           "--codex-home", str(self.codex_home), "--claude-home", str(self.claude_home),
                           "--opencode-home", str(self.opencode_home),
                           "--output-dir", str(self.root / f"{source}-to-{target}"), "--json"], timeout=180)
        self.assertEqual(len(self.server.requests), before, "Import must not request a model response")
        return json.loads(result.stdout)

    def sessions(self):
        result = self._run([self.opencode, "session", "list", "--standalone", "--format", "json"])
        return json.loads(result.stdout)

    def export(self, sid):
        result = self._run([self.opencode, "session", "export", "--standalone", sid])
        return json.loads(result.stdout)

    def resume(self, sid, prompt):
        before = len(self.server.requests)
        result = self._run([self.opencode, "run", "--standalone", "--session", sid,
                           "--format", "json", prompt], timeout=90)
        self.assertIn(CLAUDE_REPLY, result.stdout)
        requests = [payload for path, payload in self.server.requests[before:]
                    if path.startswith("/anthropic/v1/messages") and "count_tokens" not in path]
        requests = [payload for payload in requests if prompt in json.dumps(payload.get("messages", []))]
        self.assertTrue(requests, "Native OpenCode continuation never reached the loopback model")
        return requests[-1]

    def test_native_import_discovery_resume_and_return_without_duplicate(self):
        source = self._write_claude([("user", "SYNTHETIC_OPENCODE_ORIGINAL_USER"),
                                     ("assistant", "SYNTHETIC_OPENCODE_ORIGINAL_ANSWER")])
        self.migrate("claude", "opencode")
        sessions = self.sessions()
        self.assertEqual(len(sessions), 1)
        sid = sessions[0]["id"]
        exported = self.export(sid)
        self.assertEqual(exported["info"]["title"], "Synthetic source Claude chat")
        self.assertIn("SYNTHETIC_OPENCODE_ORIGINAL_ANSWER", json.dumps(exported["messages"]))
        self.migrate("opencode", "claude")
        self.assertEqual(set(self._claude_paths()), {source}, "Untouched return import must skip its original source")
        question = "SYNTHETIC_OPENCODE_CONTINUATION: preserve the earlier green choice."
        request = self.resume(sid, question)
        for value in ("SYNTHETIC_OPENCODE_ORIGINAL_USER", "SYNTHETIC_OPENCODE_ORIGINAL_ANSWER", question):
            self.assertIn(value, json.dumps(request["messages"]))
        self.assertIn(CLAUDE_REPLY, json.dumps(self.export(sid)["messages"]))
        self.migrate("opencode", "claude")
        imported = set(self._claude_paths()) - {source}
        self.assertEqual(len(imported), 1)
        request = self._claude_turn(imported.pop(), "Continue after OpenCode.")
        self.assertIn(question, json.dumps(request["messages"]))
        self.assertIn(CLAUDE_REPLY, json.dumps(request["messages"]))
        # Continued imported session is protected from undo.
        self.migrate("claude", "opencode", "undo")
        self.assertIn(sid, {session["id"] for session in self.sessions()})

    def test_native_tool_image_history_and_safe_undo(self):
        image = {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": PIXEL}}
        self._write_claude([
            ("user", [{"type": "text", "text": "SYNTHETIC_PIXEL_INSPECTION"}, image]),
            ("assistant", [{"type": "tool_use", "id": "fixture_lookup", "name": "mcp__fixture__look", "input": {"pixel": "red"}}]),
            ("user", [{"type": "tool_result", "tool_use_id": "fixture_lookup", "content": [{"type": "text", "text": "Pixel found."}, image]}]),
            ("assistant", "SYNTHETIC_PIXEL_COMPLETE"),
        ])
        self.migrate("claude", "opencode")
        sid = self.sessions()[0]["id"]
        native = self.export(sid)
        user = next(message for message in native["messages"] if message["type"] == "user")
        self.assertEqual(user["files"][0]["data"], PIXEL)
        tools = [part for message in native["messages"] if message["type"] == "assistant"
                 for part in message["content"] if part["type"] == "tool"]
        self.assertEqual(len(tools), 1)
        self.assertEqual(tools[0]["state"]["status"], "completed")
        self.assertIn("data:image/png;base64," + PIXEL, json.dumps(tools[0]))
        self.migrate("claude", "opencode", "verify")
        self.migrate("claude", "opencode", "undo")
        self.assertNotIn(sid, {session["id"] for session in self.sessions()})

    def test_native_tool_image_history_resumes_with_default_model(self):
        image = {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": PIXEL}}
        self._write_claude([
            ("user", [{"type": "text", "text": "SYNTHETIC_HISTORY_IMAGE"}, image]),
            ("assistant", [{"type": "tool_use", "id": "fixture_lookup", "name": "mcp__fixture__look", "input": {"pixel": "red"}}]),
            ("user", [{"type": "tool_result", "tool_use_id": "fixture_lookup", "content": [{"type": "text", "text": "SYNTHETIC_TOOL_OUTPUT"}, image]}]),
            ("assistant", "SYNTHETIC_PIXEL_COMPLETE"),
        ])
        self.migrate("claude", "opencode")
        sid = self.sessions()[0]["id"]
        request = self.resume(sid, "SYNTHETIC_CONTINUE_AFTER_IMAGES")
        encoded = json.dumps(request["messages"])
        for value in ("SYNTHETIC_HISTORY_IMAGE", "SYNTHETIC_TOOL_OUTPUT", "mcp__fixture__look", PIXEL):
            self.assertIn(value, encoded)
        self.assertIn(CLAUDE_REPLY, json.dumps(self.export(sid)["messages"]))

    def test_native_oversize_history_is_archived_with_bounded_continuation(self):
        turns = [("user", "SYNTHETIC_OLD_ARCHIVE_ONLY")]
        for index in range(45):
            turns.append(("user" if index % 2 == 0 else "assistant", f"History {index}: " + '\\"\n\r\t\x01' * 1600))
        turns.extend([("user", "SYNTHETIC_LATEST_REQUEST"), ("assistant", "SYNTHETIC_LATEST_ANSWER")])
        self._write_claude(turns)
        self.migrate("claude", "opencode")
        sid = self.sessions()[0]["id"]
        native = self.export(sid)
        self.assertIn("SYNTHETIC_OLD_ARCHIVE_ONLY", json.dumps(native["messages"]))
        self.assertEqual(native["messages"][-1]["type"], "compaction")
        request = self.resume(sid, "SYNTHETIC_CONTINUE_BOUNDED_HISTORY")
        encoded = json.dumps(request["messages"])
        self.assertNotIn("SYNTHETIC_OLD_ARCHIVE_ONLY", encoded)
        self.assertIn("SYNTHETIC_LATEST_REQUEST", encoded)
        self.assertIn("SYNTHETIC_LATEST_ANSWER", encoded)
        self.assertLess(len(encoded.encode()), 240000)


if __name__ == "__main__":
    unittest.main()
