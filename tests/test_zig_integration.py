from __future__ import annotations

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import queue
import re
import shutil
import subprocess
import tempfile
import threading
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
CODEX_REPLY = "Synthetic Codex fixture reply: the selected color is green."
CLAUDE_REPLY = "Synthetic Claude fixture reply: the green color is preserved."
PIXEL = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4z8AARAwQCgAf7gP9i18U1AAAAABJRU5ErkJggg=="


class _Models(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def _respond(self, body, content_type="application/json"):
        if not isinstance(body, bytes):
            body = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.server.requests.append((self.path, None))
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        self.server.requests.append((self.path, request))
        if self.path.startswith("/anthropic/v1/messages/count_tokens"):
            self._respond({"input_tokens": 100})
            return
        if self.path.startswith("/anthropic/v1/messages"):
            message = {
                "id": "msg_c2c_fixture",
                "type": "message",
                "role": "assistant",
                "model": request.get("model", "claude-sonnet-4-6"),
                "content": [],
                "stop_reason": None,
                "stop_sequence": None,
                "usage": {"input_tokens": 100, "output_tokens": 0},
            }
            if not request.get("stream"):
                self._respond(
                    {
                        **message,
                        "content": [{"type": "text", "text": CLAUDE_REPLY}],
                        "stop_reason": "end_turn",
                    }
                )
                return
            events = [
                {"type": "message_start", "message": message},
                {
                    "type": "content_block_start",
                    "index": 0,
                    "content_block": {"type": "text", "text": ""},
                },
                {
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": {"type": "text_delta", "text": CLAUDE_REPLY},
                },
                {"type": "content_block_stop", "index": 0},
                {
                    "type": "message_delta",
                    "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                    "usage": {"output_tokens": 10},
                },
                {"type": "message_stop"},
            ]
        elif self.path.startswith("/openai/v1/responses"):
            message = {
                "type": "message",
                "id": "msg_fixture",
                "role": "assistant",
                "status": "completed",
                "content": [{"type": "output_text", "text": CODEX_REPLY, "annotations": []}],
            }
            response = {
                "id": "resp_fixture",
                "object": "response",
                "created_at": 1780000000,
                "model": request.get("model", "gpt-5.4"),
                "status": "completed",
                "output": [message],
                "usage": {
                    "input_tokens": 100,
                    "output_tokens": 10,
                    "total_tokens": 110,
                    "input_tokens_details": {"cached_tokens": 0},
                    "output_tokens_details": {"reasoning_tokens": 0},
                },
            }
            events = [
                {
                    "type": "response.created",
                    "response": {**response, "status": "in_progress", "output": []},
                },
                {
                    "type": "response.output_item.added",
                    "output_index": 0,
                    "item": {**message, "status": "in_progress", "content": []},
                },
                {
                    "type": "response.content_part.added",
                    "item_id": message["id"],
                    "output_index": 0,
                    "content_index": 0,
                    "part": {"type": "output_text", "text": "", "annotations": []},
                },
                {
                    "type": "response.output_text.delta",
                    "item_id": message["id"],
                    "output_index": 0,
                    "content_index": 0,
                    "delta": CODEX_REPLY,
                },
                {
                    "type": "response.output_text.done",
                    "item_id": message["id"],
                    "output_index": 0,
                    "content_index": 0,
                    "text": CODEX_REPLY,
                },
                {"type": "response.output_item.done", "output_index": 0, "item": message},
                {"type": "response.completed", "response": response},
            ]
        else:
            self.send_response(404)
            self.end_headers()
            return
        body = "".join(
            f"event: {event['type']}\ndata: {json.dumps(event)}\n\n" for event in events
        ).encode()
        self._respond(body, "text/event-stream")


@unittest.skipUnless(
    os.environ.get("RUN_C2C_INTEGRATION") == "1",
    "set RUN_C2C_INTEGRATION=1 for compiled Zig native integration",
)
class ZigNativeIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.binary = str(Path(os.environ.get("C2C_BINARY", ROOT / "zig-out/bin/c2c")).resolve())
        self.codex = os.environ.get("CODEX_BINARY") or shutil.which("codex")
        self.claude = os.environ.get("CLAUDE_BINARY") or shutil.which("claude")
        if not self.codex or not self.claude:
            self.skipTest("Both Codex and Claude Code must be installed")
        self.assertTrue(
            Path(self.binary).is_file(), "Build the Zig executable with zig build first"
        )
        self.temp = tempfile.TemporaryDirectory(prefix="c2c-zig-offline-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.project = self.root / "project"
        self.user_home = self.root / "home"
        self.codex_home = self.root / "codex"
        self.claude_home = self.root / "claude"
        for directory in (self.project, self.user_home, self.codex_home, self.claude_home):
            directory.mkdir()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), _Models)
        self.server.requests = []
        self.worker = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.worker.start()
        self.addCleanup(self._close)
        self.base = f"http://127.0.0.1:{self.server.server_port}"
        self.env = {
            key: value
            for key, value in os.environ.items()
            if key in ("PATH", "LANG", "LC_ALL", "SYSTEMROOT")
        }
        self.env.update(
            HOME=str(self.user_home),
            CODEX_HOME=str(self.codex_home),
            CLAUDE_CONFIG_DIR=str(self.claude_home),
            XDG_CONFIG_HOME=str(self.user_home / ".config"),
            DO_NOT_TRACK="1",
            NO_PROXY="127.0.0.1,localhost",
            CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1",
            DISABLE_TELEMETRY="1",
            DISABLE_AUTOUPDATER="1",
            ANTHROPIC_API_KEY="offline-fixture-not-a-real-key",
            ANTHROPIC_BASE_URL=self.base + "/anthropic",
        )

    def _close(self):
        self.server.shutdown()
        self.server.server_close()
        self.worker.join(timeout=2)

    def _run(self, args, timeout=60, input_text=None):
        result = subprocess.run(
            args,
            cwd=self.project,
            env=self.env,
            capture_output=True,
            text=True,
            timeout=timeout,
            input=input_text,
        )
        self.assertEqual(result.returncode, 0, result.stderr[-5000:] + result.stdout[-5000:])
        return result

    def _migrate(self, direction, *, output=None):
        output = output or self.root / direction
        before = len(self.server.requests)
        result = self._run(
            [
                self.binary,
                direction,
                "migrate",
                "--codex-home",
                str(self.codex_home),
                "--claude-home",
                str(self.claude_home),
                "--output-dir",
                str(output),
                "--json",
            ],
            timeout=120,
        )
        self.assertEqual(
            len(self.server.requests), before, "Migration itself must not call a model"
        )
        return json.loads(result.stdout)

    def _codex_args(self):
        options = {
            "model": "gpt-5.4",
            "model_provider": "offline_fixture",
            "model_providers.offline_fixture.name": "Offline fixture",
            "model_providers.offline_fixture.base_url": self.base + "/openai/v1",
            "model_providers.offline_fixture.wire_api": "responses",
            "model_providers.offline_fixture.requires_openai_auth": False,
            "model_providers.offline_fixture.supports_websockets": False,
            "model_providers.offline_fixture.request_max_retries": 0,
            "model_providers.offline_fixture.stream_max_retries": 0,
            "model_providers.offline_fixture.stream_idle_timeout_ms": 5000,
            "analytics.enabled": False,
            "feedback.enabled": False,
            "otel.exporter": "none",
            "otel.metrics_exporter": "none",
            "otel.trace_exporter": "none",
            "check_for_update_on_startup": False,
            "web_search": "disabled",
            "features.hooks": False,
            "features.apps": False,
            "features.multi_agent": False,
            "mcp_servers": {},
            "project_doc_max_bytes": 0,
            "approval_policy": "never",
            "model_reasoning_effort": "low",
        }
        args = []
        for key, value in options.items():
            args.extend(["-c", key + "=" + ("{}" if value == {} else json.dumps(value))])
        paths = [
            str(self.codex_home / "skills/.system" / name / "SKILL.md")
            for name in ("imagegen", "openai-docs", "skill-creator", "skill-installer")
        ]
        args.extend(
            [
                "-c",
                "skills.config=["
                + ",".join("{path=" + json.dumps(path) + ",enabled=false}" for path in paths)
                + "]",
            ]
        )
        return args

    def _codex_turn(self, prompt, sid=None):
        command = [
            self.codex,
            "exec",
            *self._codex_args(),
            "--ignore-user-config",
            "--ignore-rules",
            "--skip-git-repo-check",
            "--color",
            "never",
            "--sandbox",
            "read-only",
            "--cd",
            str(self.project),
        ]
        argument = "-" if len(prompt) > 32_000 else prompt
        command.extend(["resume", "--json", sid, argument] if sid else ["--json", argument])
        before = len(self.server.requests)
        result = self._run(command, input_text=prompt if argument == "-" else None)
        self.assertIn(CODEX_REPLY, result.stdout)
        requests = [
            payload
            for path, payload in self.server.requests[before:]
            if path.startswith("/openai/v1/responses")
        ]
        self.assertEqual(
            len(requests), 1, "A normal continuation must make exactly one local model request"
        )
        events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
        sid = sid or next(
            event["thread_id"] for event in events if event.get("type") == "thread.started"
        )
        return sid, requests[0]

    def _claude_turn(self, sid, prompt):
        before = len(self.server.requests)
        result = self._run(
            [
                self.claude,
                "--bare",
                "--safe-mode",
                "-p",
                "--resume",
                sid,
                "--model",
                "claude-sonnet-4-6",
                "--tools",
                "",
                "--strict-mcp-config",
                "--mcp-config",
                '{"mcpServers":{}}',
                "--setting-sources",
                "",
                "--settings",
                '{"disableAllHooks":true}',
                "--permission-mode",
                "dontAsk",
                "--permission-prompts",
                "none",
                "--system-prompt",
                "Answer the synthetic fixture.",
                "--output-format",
                "json",
                prompt,
            ]
        )
        self.assertIn(CLAUDE_REPLY, result.stdout)
        requests = [
            payload
            for path, payload in self.server.requests[before:]
            if path.startswith("/anthropic/v1/messages") and "count_tokens" not in path
        ]
        self.assertEqual(len(requests), 1)
        return requests[0]

    def _codex_paths(self):
        return {
            self._session_id(path): path for path in self.codex_home.glob("sessions/**/*.jsonl")
        }

    @staticmethod
    def _session_id(path):
        with path.open() as file:
            return json.loads(next(file))["payload"]["id"]

    def _claude_paths(self):
        return {path.stem: path for path in self.claude_home.glob("projects/*/*.jsonl")}

    def _write_claude(self, messages):
        sid = str(uuid.uuid4())
        folder = re.sub(r"[^a-zA-Z0-9]", "-", str(self.project))
        path = self.claude_home / "projects" / folder / (sid + ".jsonl")
        path.parent.mkdir(parents=True, exist_ok=True)
        entries, parent = [], None
        for index, (role, content) in enumerate(messages):
            identity = str(uuid.uuid4())
            record = {
                "uuid": identity,
                "parentUuid": parent,
                "sessionId": sid,
                "cwd": str(self.project),
                "version": "2.1.289",
                "entrypoint": "cli",
                "userType": "external",
                "isSidechain": False,
                "timestamp": f"2026-10-01T10:{index // 60:02d}:{index % 60:02d}.000Z",
                "type": role,
            }
            if role == "system":
                record.update(
                    parentUuid=None,
                    logicalParentUuid=parent,
                    subtype="compact_boundary",
                    content="Conversation compacted",
                    level="info",
                    isMeta=False,
                    compactMetadata={"trigger": "auto", "preTokens": 0},
                )
            else:
                record["message"] = {"role": role, "content": content}
                if role == "assistant":
                    calls = isinstance(content, list) and any(
                        block.get("type") == "tool_use" for block in content
                    )
                    record["message"].update(
                        model="<synthetic>",
                        id="msg_" + identity,
                        type="message",
                        stop_reason="tool_use" if calls else "end_turn",
                        stop_sequence=None,
                        usage={"input_tokens": 0, "output_tokens": 0},
                    )
                if entries and entries[-1].get("subtype") == "compact_boundary":
                    record["isCompactSummary"] = True
            entries.append(record)
            parent = identity
        entries.append(
            {
                "type": "custom-title",
                "sessionId": sid,
                "customTitle": "Synthetic source Claude chat",
            }
        )
        path.write_text("".join(json.dumps(record) + "\n" for record in entries))
        return sid

    def _read_codex(self, sid):
        process = subprocess.Popen(
            [self.codex, "app-server", "--stdio"],
            env=self.env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        responses = queue.Queue()

        def read():
            for line in process.stdout:
                try:
                    responses.put(json.loads(line))
                except ValueError:
                    pass
            responses.put(None)

        worker = threading.Thread(target=read, daemon=True)
        worker.start()

        def call(identifier, method, params):
            process.stdin.write(
                json.dumps({"id": identifier, "method": method, "params": params}) + "\n"
            )
            process.stdin.flush()
            while True:
                result = responses.get(timeout=30)
                self.assertIsNotNone(result, "Native app-server ended before answering")
                if result.get("id") == identifier:
                    self.assertNotIn("error", result)
                    return result["result"]

        try:
            call(
                1,
                "initialize",
                {
                    "clientInfo": {"name": "c2c-zig-test", "version": "0.1"},
                    "capabilities": {"experimentalApi": True},
                },
            )
            process.stdin.write('{"method":"initialized"}\n')
            process.stdin.flush()
            listing = call(2, "thread/list", {"limit": 100})
            self.assertIn(sid, [thread["id"] for thread in listing["data"]])
            return call(3, "thread/read", {"threadId": sid, "includeTurns": True})["thread"]
        finally:
            process.stdin.close()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=5)
            worker.join(timeout=2)
            process.stdout.close()

    def test_codex_claude_codex_roundtrip_skips_unchanged_then_preserves_continuation(self):
        original = "SYNTHETIC_ORIGINAL_CODEX_REQUEST: select green for the example."
        original_id, _ = self._codex_turn(original)
        self._migrate("codex-to-claude")
        imported_claude = self._claude_paths()
        self.assertEqual(len(imported_claude), 1)
        claude_id = next(iter(imported_claude))
        original_codex = self._codex_paths()
        self._migrate("claude-to-codex")
        self.assertEqual(
            self._codex_paths(),
            original_codex,
            "An untouched return import must not create a duplicate",
        )
        question = "SYNTHETIC_CLAUDE_CONTINUATION: keep green, and explain the choice."
        request = self._claude_turn(claude_id, question)
        history = json.dumps(request["messages"])
        for text in (original, CODEX_REPLY, question):
            self.assertIn(text, history)
        self._migrate("claude-to-codex")
        added = set(self._codex_paths()) - set(original_codex)
        self.assertEqual(len(added), 1)
        returned_id = added.pop()
        self.assertNotEqual(returned_id, original_id)
        native = self._read_codex(returned_id)
        self.assertIn(CLAUDE_REPLY, json.dumps(native["turns"]))
        _, request = self._codex_turn(
            "SYNTHETIC_FINAL_CONTINUATION: retain the complete discussion.", returned_id
        )
        for text in (original, CODEX_REPLY, question, CLAUDE_REPLY):
            self.assertIn(text, json.dumps(request["input"]))

    def test_reverse_tools_images_and_compaction_resume_through_native_cli(self):
        image = {
            "type": "image",
            "source": {"type": "base64", "media_type": "image/png", "data": PIXEL},
        }
        archived = "SYNTHETIC_ARCHIVED_EXCLUDED_FROM_ACTIVE_CONTEXT"
        summary = "SYNTHETIC_SUMMARY: the selected fixture color is green."
        self._write_claude(
            [
                ("user", archived),
                ("assistant", "Old synthetic response."),
                ("system", ""),
                ("user", summary),
                ("user", [{"type": "text", "text": "SYNTHETIC_RECENT_IMAGE_REQUEST"}, image]),
                (
                    "assistant",
                    [
                        {
                            "type": "tool_use",
                            "id": "fixture_bash",
                            "name": "Bash",
                            "input": {"command": "printf synthetic"},
                        }
                    ],
                ),
                (
                    "user",
                    [
                        {
                            "type": "tool_result",
                            "tool_use_id": "fixture_bash",
                            "content": "synthetic",
                        }
                    ],
                ),
                (
                    "assistant",
                    [
                        {
                            "type": "tool_use",
                            "id": "fixture_mcp",
                            "name": "mcp__old__inspect",
                            "input": {"sample": "pixel"},
                        }
                    ],
                ),
                (
                    "user",
                    [
                        {
                            "type": "tool_result",
                            "tool_use_id": "fixture_mcp",
                            "content": [
                                {"type": "text", "text": "Synthetic inspected pixel."},
                                image,
                            ],
                        }
                    ],
                ),
                ("assistant", "Synthetic image inspection finished."),
            ]
        )
        self._migrate("claude-to-codex")
        sessions = self._codex_paths()
        self.assertEqual(len(sessions), 1)
        sid = next(iter(sessions))
        native = self._read_codex(sid)
        self.assertIn(archived, json.dumps(native["turns"]))
        commands = [
            item
            for turn in native["turns"]
            for item in turn["items"]
            if item.get("type") == "commandExecution"
        ]
        self.assertEqual(
            len(commands),
            1,
            "Native registration must not silently discard the saved Bash display record",
        )
        self.assertIn("synthetic", json.dumps(commands[0]))
        _, request = self._codex_turn("Continue the synthetic image review.", sid)
        active = json.dumps(request["input"])
        self.assertNotIn(archived, active)
        self.assertIn(summary, active)
        calls = {
            item["call_id"]: item
            for item in request["input"]
            if item.get("type") == "function_call"
        }
        outputs = {
            item["call_id"]: item
            for item in request["input"]
            if item.get("type") == "function_call_output"
        }
        self.assertEqual({item["name"] for item in calls.values()}, {"Bash", "mcp__old__inspect"})
        self.assertEqual(set(calls), set(outputs))
        uploaded = [
            block["image_url"]
            for item in request["input"]
            if item.get("type") == "message"
            for block in item.get("content", [])
            if block.get("type") == "input_image"
        ]
        returned = [
            block["image_url"]
            for item in outputs.values()
            if isinstance(item["output"], list)
            for block in item["output"]
            if block.get("type") == "input_image"
        ]
        self.assertEqual(uploaded, ["data:image/png;base64," + PIXEL])
        self.assertEqual(returned, ["data:image/png;base64," + PIXEL])

    def test_reverse_large_single_turn_preserves_archive_and_latest_context(self):
        messages = [("user", "SYNTHETIC_LATEST_TASK: keep the fixture green.")]
        messages.extend(
            ("assistant", f"Synthetic work item {index}. " + "a" * 22_000) for index in range(20)
        )
        messages.append(("assistant", "SYNTHETIC_FINAL_STATE: the fixture remains green."))
        self._write_claude(messages)
        self._migrate("claude-to-codex")
        sessions = self._codex_paths()
        self.assertEqual(len(sessions), 1)
        sid, path = next(iter(sessions.items()))
        self.assertGreater(path.stat().st_size, 440_000)
        _, request = self._codex_turn("Continue the synthetic work.", sid)
        active = json.dumps(request["input"])
        self.assertTrue(
            "SYNTHETIC_LATEST_TASK" in active, "Newest user request lost from bounded context"
        )
        self.assertTrue(
            "SYNTHETIC_FINAL_STATE" in active, "Newest answer lost from bounded context"
        )
        self.assertIn("extractive", active)
        self.assertLess(len(active.encode()), 240_000)

    def test_forward_large_history_keeps_archive_and_bounds_actual_claude_request(self):
        prompt = "SYNTHETIC_LARGE_SOURCE_START\n" + "a" * 800_000 + "\nSYNTHETIC_LARGE_SOURCE_END"
        self._codex_turn(prompt)
        self._migrate("codex-to-claude")
        sessions = self._claude_paths()
        self.assertEqual(len(sessions), 1)
        sid, path = next(iter(sessions.items()))
        self.assertGreater(path.stat().st_size, 800_000)
        content = [
            json.loads(line).get("message", {}).get("content")
            for line in path.read_text().splitlines()
        ]
        preserved = any(
            value == prompt
            or isinstance(value, list)
            and any(block.get("text") == prompt for block in value if isinstance(block, dict))
            for value in content
        )
        self.assertTrue(preserved, "The full original message must remain in the native transcript")
        request = self._claude_turn(sid, "Continue the synthetic large conversation.")
        active = json.dumps(request["messages"])
        self.assertTrue("SYNTHETIC_LARGE_SOURCE_START" in active)
        self.assertTrue("SYNTHETIC_LARGE_SOURCE_END" in active)
        self.assertIn("checkpoint", active)
        self.assertLess(len(active.encode()), 240_000)


if __name__ == "__main__":
    unittest.main()
