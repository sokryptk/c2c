"""Opt-in real Codex loader/continuation tests with a loopback Responses mock.

RUN_CODEX_INTEGRATION=1 python -m unittest discover -s tests -p test_codex_integration.py -v

Every transcript, home directory, model response, and credential is synthetic.
The native CLI never receives the user's normal configuration or credentials.
"""
from __future__ import annotations

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent / "reference"))
from codex_to_claude import codex_native
from codex_to_claude.source import Thread

REPLY = "Offline reverse migration fixture resumed successfully."
TIMESTAMP = "2026-10-01T10:00:00.000Z"


class _ResponsesHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        # Unexpected discovery requests must stay local and cannot authenticate.
        self.server.requests.append((self.path, None))
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        self.server.requests.append((self.path, request))
        message = {"type": "message", "id": "msg_c2c_fixture", "role": "assistant",
                   "status": "completed", "content": [{"type": "output_text", "text": REPLY, "annotations": []}]}
        response = {"id": "resp_c2c_fixture", "object": "response", "created_at": 1780000000,
                    "model": request.get("model", "gpt-5.4"), "status": "completed", "output": [message],
                    "usage": {"input_tokens": 100, "output_tokens": 10, "total_tokens": 110,
                              "input_tokens_details": {"cached_tokens": 0},
                              "output_tokens_details": {"reasoning_tokens": 0}}}
        events = [
            {"type": "response.created", "response": {**response, "status": "in_progress", "output": []}},
            {"type": "response.output_item.added", "output_index": 0, "item": {**message, "status": "in_progress", "content": []}},
            {"type": "response.content_part.added", "item_id": message["id"], "output_index": 0,
             "content_index": 0, "part": {"type": "output_text", "text": "", "annotations": []}},
            {"type": "response.output_text.delta", "item_id": message["id"], "output_index": 0,
             "content_index": 0, "delta": REPLY},
            {"type": "response.output_text.done", "item_id": message["id"], "output_index": 0,
             "content_index": 0, "text": REPLY},
            {"type": "response.output_item.done", "output_index": 0, "item": message},
            {"type": "response.completed", "response": response},
        ]
        body = "".join(f"event: {event['type']}\ndata: {json.dumps(event)}\n\n" for event in events).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


@unittest.skipUnless(os.environ.get("RUN_CODEX_INTEGRATION") == "1", "set RUN_CODEX_INTEGRATION=1 for offline native Codex tests")
class CodexNativeResumeTests(unittest.TestCase):
    def setUp(self):
        self.binary = os.environ.get("CODEX_BINARY") or shutil.which("codex")
        if not self.binary:
            self.skipTest("Codex CLI is not installed")
        self.temp = tempfile.TemporaryDirectory(prefix="c2c-codex-native-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.project = self.root / "project"
        self.project.mkdir()
        self.home = self.root / "codex"
        self.home.mkdir()
        self.user_home = self.root / "home"
        self.user_home.mkdir()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), _ResponsesHandler)
        self.server.requests = []
        self.worker = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.worker.start()
        self.addCleanup(self._close_server)
        self.env = {key: value for key, value in os.environ.items() if key in ("PATH", "LANG", "LC_ALL", "SYSTEMROOT")}
        self.env.update(HOME=str(self.user_home), CODEX_HOME=str(self.home),
                        XDG_CONFIG_HOME=str(self.user_home / ".config"),
                        DO_NOT_TRACK="1", NO_PROXY="127.0.0.1,localhost")
        self.options = {
            "model": "gpt-5.4", "model_provider": "offline_fixture",
            "model_providers.offline_fixture.name": "Offline fixture",
            "model_providers.offline_fixture.base_url": f"http://127.0.0.1:{self.server.server_port}/v1",
            "model_providers.offline_fixture.wire_api": "responses",
            "model_providers.offline_fixture.requires_openai_auth": False,
            "model_providers.offline_fixture.supports_websockets": False,
            "model_providers.offline_fixture.request_max_retries": 0,
            "model_providers.offline_fixture.stream_max_retries": 0,
            "model_providers.offline_fixture.stream_idle_timeout_ms": 5000,
            "analytics.enabled": False, "feedback.enabled": False,
            "otel.exporter": "none", "otel.metrics_exporter": "none", "otel.trace_exporter": "none",
            "check_for_update_on_startup": False, "web_search": "disabled",
            "features.hooks": False, "features.apps": False, "features.multi_agent": False,
            "mcp_servers": {}, "project_doc_max_bytes": 0,
            "approval_policy": "never", "model_reasoning_effort": "low",
        }
        # Native startup unpacks bundled skills even into a new CODEX_HOME;
        # disable them explicitly so fixtures exercise only the imported chat.
        self.disabled_skills = [str(self.home / "skills" / ".system" / name / "SKILL.md")
                                for name in ("imagegen", "openai-docs", "skill-creator", "skill-installer")]

    def _close_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.worker.join(timeout=2)

    def _args(self):
        args = []
        for key, value in self.options.items():
            # JSON scalar syntax is also TOML scalar syntax; inline empty map differs.
            args.extend(["-c", key + "=" + ("{}" if value == {} else json.dumps(value))])
        args.extend(["-c", "skills.config=[" + ",".join(
            "{path=" + json.dumps(path) + ",enabled=false}" for path in self.disabled_skills) + "]"])
        return args

    def _entry(self, role, content, **extra):
        return {"type": role, "uuid": str(uuid.uuid4()), "timestamp": TIMESTAMP,
                "message": {"role": role, "content": content}, **extra}

    def _install(self, entries):
        thread = Thread(str(uuid.uuid4()), "Offline Claude import", str(self.project), TIMESTAMP,
                        TIMESTAMP, self.root / "synthetic-claude.jsonl")
        path = codex_native.target_path(thread, self.home)
        converted = codex_native.convert(thread, entries, transcript_path=str(path))
        path.parent.mkdir(parents=True)
        path.write_text("".join(json.dumps(row) + "\n" for row in converted.entries))
        # The production helper inherits environment; isolate that too.
        with patch.dict(os.environ, self.env, clear=True):
            codex_native.register(self.home, converted.session_id, thread.title, codex_binary=self.binary)
        self.assertEqual(self.server.requests, [])
        return thread, converted, path

    def _read(self, session_id):
        with patch.dict(os.environ, self.env, clear=True):
            server = codex_native._Server(self.home, self.binary)
        try:
            server.call("initialize", {"clientInfo": {"name": "c2c-offline-test", "version": "0.1"},
                                       "capabilities": {"experimentalApi": True}})
            server.process.stdin.write('{"method":"initialized"}\n')
            server.process.stdin.flush()
            listing = server.call("thread/list", {"limit": 100})
            self.assertIn(session_id, [item["id"] for item in listing["data"]])
            return server.call("thread/read", {"threadId": session_id, "includeTurns": True})["thread"]
        finally:
            server.close()

    def _resume(self, session_id, prompt="Continue the synthetic imported discussion."):
        command = [self.binary, "exec", *self._args(), "--ignore-user-config", "--ignore-rules",
                   "--skip-git-repo-check", "--color", "never", "--sandbox", "read-only",
                   "--cd", str(self.project), "resume", "--json", session_id, prompt]
        result = subprocess.run(command, cwd=self.project, env=self.env, capture_output=True, text=True, timeout=45)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn(REPLY, result.stdout)
        requests = [payload for path, payload in self.server.requests if path.startswith("/v1/responses")]
        self.assertEqual(len(requests), 1, self.server.requests)
        self.assertIn(prompt, json.dumps(requests[0]["input"]))
        return requests[0]

    def test_native_discovery_and_continuation_include_imported_turns(self):
        old_user = "Synthetic old user: paint the sample door green."
        old_answer = "Synthetic old assistant: the sample door is green."
        thread, converted, _ = self._install([self._entry("user", old_user), self._entry("assistant", old_answer)])
        loaded = self._read(converted.session_id)
        self.assertEqual(loaded["name"], thread.title)
        self.assertIn(old_user, json.dumps(loaded["turns"]))
        self.assertIn(old_answer, json.dumps(loaded["turns"]))
        request = self._resume(converted.session_id)
        self.assertIn(old_user, json.dumps(request["input"]))
        self.assertIn(old_answer, json.dumps(request["input"]))
        self.assertIn(REPLY, json.dumps(self._read(converted.session_id)["turns"]))

    def test_historical_bash_and_unknown_mcp_pairs_reach_model(self):
        entries = [self._entry("user", "Inspect the synthetic fixture only.")]
        for call_id, name, args, output in (
            ("call_bash", "Bash", {"command": "printf synthetic"}, "synthetic"),
            ("call_mcp", "mcp__old_fixture__lookup", {"query": "fixture"}, "historical lookup result"),
        ):
            entries.extend([
                self._entry("assistant", [{"type": "tool_use", "id": call_id, "name": name, "input": args}]),
                self._entry("user", [{"type": "tool_result", "tool_use_id": call_id, "content": output}]),
            ])
        entries.append(self._entry("assistant", "The fixture was inspected."))
        _, converted, _ = self._install(entries)
        self.assertIn("historical lookup result", json.dumps(self._read(converted.session_id)["turns"]))
        request = self._resume(converted.session_id)
        calls = {item["call_id"]: item for item in request["input"] if item.get("type") == "function_call"}
        outputs = {item["call_id"]: item for item in request["input"] if item.get("type") == "function_call_output"}
        self.assertEqual({item["name"] for item in calls.values()}, {"Bash", "mcp__old_fixture__lookup"})
        self.assertEqual(set(calls), set(outputs))
        self.assertEqual({item["output"] for item in outputs.values()}, {"synthetic", "historical lookup result"})

    def test_existing_compaction_restores_summary_and_recent_context(self):
        archived = "SYNTHETIC_ARCHIVED_TEXT_EXCLUDED_FROM_ACTIVE_CONTEXT"
        summary = "Synthetic compact summary: the selected fixture color is green."
        recent = "Synthetic recent question: preserve the green color."
        entries = [self._entry("user", archived), self._entry("assistant", "Old answer."),
                   {"type": "system", "subtype": "compact_boundary", "timestamp": TIMESTAMP},
                   self._entry("user", summary, isCompactSummary=True), self._entry("user", recent),
                   self._entry("assistant", "Green remains selected.")]
        _, converted, _ = self._install(entries)
        self.assertIn(archived, json.dumps(self._read(converted.session_id)["turns"]))
        request = self._resume(converted.session_id)
        active = json.dumps(request["input"])
        self.assertNotIn(archived, active)
        self.assertIn(summary, active)
        self.assertIn(recent, active)

    def test_uploaded_and_tool_result_images_reach_native_model_request(self):
        # Valid 2x2 red PNG bytes, including CRCs; no user file is involved.
        encoded = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4z8AARAwQCgAf7gP9i18U1AAAAABJRU5ErkJggg=="
        image = {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": encoded}}
        entries = [
            self._entry("user", [{"type": "text", "text": "Inspect this synthetic pixel."}, image]),
            self._entry("assistant", [{"type": "tool_use", "id": "pixel_call",
                                       "name": "mcp__fixture__inspect_image", "input": {"sample": "pixel"}}]),
            self._entry("user", [{"type": "tool_result", "tool_use_id": "pixel_call",
                                  "content": [{"type": "text", "text": "Synthetic result pixel."}, image]}]),
            self._entry("assistant", "The synthetic pixel was read."),
        ]
        _, converted, _ = self._install(entries)
        request = self._resume(converted.session_id)
        user_images = [block["image_url"] for item in request["input"] if item.get("type") == "message"
                       for block in item.get("content", []) if block.get("type") == "input_image"]
        tool_images = [block["image_url"] for item in request["input"] if item.get("type") == "function_call_output"
                       for block in item.get("output", []) if isinstance(block, dict) and block.get("type") == "input_image"]
        self.assertEqual(user_images, ["data:image/png;base64," + encoded])
        self.assertEqual(tool_images, ["data:image/png;base64," + encoded])

    def test_oversized_archive_remains_visible_with_bounded_resume_context(self):
        archived = "SYNTHETIC_OLD_ARCHIVE_MARKER"
        entries = []
        for index in range(20):
            entries.extend([self._entry("user", f"Synthetic old request {index}."),
                            self._entry("assistant", (archived if index == 0 else "fixture ") + "a" * 40_000)])
        recent = "Synthetic latest task: keep the fixture green."
        entries.extend([self._entry("user", recent), self._entry("assistant", "The fixture stays green.")])
        _, converted, path = self._install(entries)
        self.assertGreater(path.stat().st_size, 800_000)
        self.assertIn(archived, json.dumps(self._read(converted.session_id)["turns"]))
        request = self._resume(converted.session_id)
        active = json.dumps(request["input"])
        self.assertNotIn(archived, active)
        self.assertIn("extractive window", active)
        self.assertIn(str(path), active)
        self.assertIn(recent, active)
        self.assertLess(len(active.encode()), codex_native.MAX_ACTIVE_BYTES)

    def test_large_single_turn_has_bounded_continuation(self):
        entries = [self._entry("user", "Synthetic newest task: preserve the sample green color.")]
        # Claude streams can contain many assistant messages before the next
        # real user turn, rather than one bounded assistant response.
        entries.extend(self._entry("assistant", f"Synthetic work item {index}. " + "a" * 22_000)
                       for index in range(20))
        entries.append(self._entry("assistant", "Synthetic final state: sample remains green."))
        _, converted, path = self._install(entries)
        self.assertGreater(path.stat().st_size, 440_000)
        request = self._resume(converted.session_id)
        active = json.dumps(request["input"])
        self.assertIn("Synthetic newest task", active)
        self.assertTrue("Synthetic final state" in active, "Oversized turn lost its newest final answer")
        self.assertLess(len(active.encode()), codex_native.MAX_ACTIVE_BYTES)


if __name__ == "__main__":
    unittest.main()
