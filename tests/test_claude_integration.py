from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch


REPLY = "Offline migration fixture resumed successfully."
sys.path.insert(0, str(Path(__file__).resolve().parent / "reference"))


class _MessagesHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_POST(self):
        payload = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        request = json.loads(payload or "{}")
        self.server.requests.append((self.path, request))
        if self.path.startswith("/v1/messages/count_tokens"):
            self._json({"input_tokens": 100})
            return
        if not self.path.startswith("/v1/messages"):
            self._json({})
            return
        message = {
            "id": "msg_offline_migration_fixture",
            "type": "message",
            "role": "assistant",
            "model": request.get("model", "claude-sonnet-4-6"),
            "content": [],
            "stop_reason": None,
            "stop_sequence": None,
            "usage": {"input_tokens": 100, "output_tokens": 0},
        }
        if not request.get("stream"):
            message.update(content=[{"type": "text", "text": REPLY}], stop_reason="end_turn")
            self._json(message)
            return
        events = [
            ("message_start", {"type": "message_start", "message": message}),
            (
                "content_block_start",
                {
                    "type": "content_block_start",
                    "index": 0,
                    "content_block": {"type": "text", "text": ""},
                },
            ),
            (
                "content_block_delta",
                {
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": {"type": "text_delta", "text": REPLY},
                },
            ),
            ("content_block_stop", {"type": "content_block_stop", "index": 0}),
            (
                "message_delta",
                {
                    "type": "message_delta",
                    "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                    "usage": {"output_tokens": 9},
                },
            ),
            ("message_stop", {"type": "message_stop"}),
        ]
        body = "".join(
            f"event: {event}\ndata: {json.dumps(data)}\n\n" for event, data in events
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, data):
        body = json.dumps(data).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


@unittest.skipUnless(
    os.environ.get("RUN_CLAUDE_INTEGRATION") == "1",
    "set RUN_CLAUDE_INTEGRATION=1 for the offline native CLI test",
)
class ClaudeNativeResumeTests(unittest.TestCase):
    def setUp(self):
        self.binary = os.environ.get("CLAUDE_BINARY") or shutil.which("claude")
        if not self.binary:
            self.skipTest("Claude Code is not installed")
        self.temp = tempfile.TemporaryDirectory(prefix="codex-claude-native-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.project = self.root / "project"
        self.project.mkdir()
        self.config = self.root / "claude"
        self.config.mkdir()
        self.sid = str(uuid.uuid4())
        self.parent = None
        self.entries = []
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), _MessagesHandler)
        self.server.requests = []
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def add_message(self, role, text):
        identifier = str(uuid.uuid4())
        message = {"role": role, "content": [{"type": "text", "text": text}]}
        if role == "assistant":
            message.update(
                model="<synthetic>",
                id="msg_import_" + uuid.uuid4().hex,
                type="message",
                stop_reason="end_turn",
                stop_sequence=None,
                usage={"input_tokens": 0, "output_tokens": 0},
            )
        entry = self.common(identifier)
        entry.update(type=role, message=message)
        if role == "user":
            entry.update(origin={"kind": "human"}, promptSource="typed")
        self.entries.append(entry)
        self.parent = identifier
        return entry

    def common(self, identifier):
        return {
            "uuid": identifier,
            "parentUuid": self.parent,
            "sessionId": self.sid,
            "isSidechain": False,
            "userType": "external",
            "entrypoint": "cli",
            "cwd": str(self.project),
            "version": "2.1.289",
            "timestamp": "2026-10-06T00:00:00.000Z",
        }

    def write_transcript(self):
        directory = self.config / "projects" / re.sub(r"[^a-zA-Z0-9]", "-", str(self.project))
        directory.mkdir(parents=True)
        path = directory / f"{self.sid}.jsonl"
        title = {
            "type": "custom-title",
            "sessionId": self.sid,
            "customTitle": "Offline Codex migration fixture",
        }
        entries = (
            self.entries
            if any(e.get("type") == "custom-title" for e in self.entries)
            else [*self.entries, title]
        )
        path.write_text("".join(json.dumps(e, separators=(",", ":")) + "\n" for e in entries))
        return path

    def environment(self):
        env = {
            key: os.environ[key]
            for key in ("PATH", "LANG", "LC_ALL", "SYSTEMROOT")
            if key in os.environ
        }
        env.update(
            CLAUDE_CONFIG_DIR=str(self.config),
            ANTHROPIC_BASE_URL=f"http://127.0.0.1:{self.server.server_port}",
            ANTHROPIC_API_KEY="sk-ant-offline-test-not-a-real-key",
            CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1",
            DISABLE_TELEMETRY="1",
            DISABLE_ERROR_REPORTING="1",
            DISABLE_AUTOUPDATER="1",
            DISABLE_UPDATES="1",
            CLAUDE_CODE_DISABLE_AUTO_MEMORY="1",
            NO_PROXY="127.0.0.1,localhost",
            TERM="dumb",
        )
        return env

    def resume(self):
        self.write_transcript()
        command = [
            self.binary,
            "--bare",
            "--safe-mode",
            "--print",
            "--resume",
            self.sid,
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
            "This is a local migration compatibility test.",
            "--output-format",
            "json",
            "Continue the synthetic fixture.",
        ]
        completed = subprocess.run(
            command,
            cwd=self.project,
            env=self.environment(),
            text=True,
            capture_output=True,
            timeout=45,
        )
        self.assertEqual(
            completed.returncode, 0, completed.stdout[-5000:] + completed.stderr[-5000:]
        )
        self.assertIn(REPLY, completed.stdout)
        requests = [
            data
            for path, data in self.server.requests
            if path.startswith("/v1/messages") and not path.startswith("/v1/messages/count_tokens")
        ]
        self.assertTrue(requests, completed.stdout + completed.stderr)
        return requests[-1]

    def test_resumes_imported_user_and_assistant_as_native_history(self):
        self.add_message("user", "Remember fixture-key-bluebird.")
        self.add_message("assistant", "The fixture key is bluebird; keep this answer in history.")
        request = self.resume()
        messages = request["messages"]
        self.assertEqual([m["role"] for m in messages], ["user", "assistant", "user"])
        transcript = json.dumps(messages)
        self.assertIn("Remember fixture-key-bluebird.", transcript)
        self.assertIn("keep this answer in history.", transcript)
        self.assertIn("Continue the synthetic fixture.", transcript)

    def test_official_sdk_discovers_title_and_reads_native_chain(self):
        try:
            from claude_agent_sdk import get_session_messages, list_sessions
        except ImportError:
            self.skipTest(
                "install claude-agent-sdk in an isolated environment for SDK reader verification"
            )
        self.add_message("user", "Discover this imported fixture.")
        self.add_message("assistant", "The native message chain is preserved.")
        self.write_transcript()
        with patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": str(self.config)}):
            sessions = list_sessions(directory=str(self.project))
            self.assertEqual(len(sessions), 1)
            self.assertEqual(sessions[0].session_id, self.sid)
            self.assertEqual(sessions[0].custom_title, "Offline Codex migration fixture")
            self.assertEqual(sessions[0].cwd, str(self.project))
            messages = get_session_messages(self.sid, directory=str(self.project))
        self.assertEqual([m.type for m in messages], ["user", "assistant"])
        self.assertEqual(
            messages[-1].message["content"][0]["text"], "The native message chain is preserved."
        )

    def test_actual_converter_preserves_completed_native_and_unknown_tools(self):
        from codex_to_claude.native import convert
        from codex_to_claude.source import Item, Thread

        timestamp = "2026-10-06T00:00:00.000Z"
        thread = Thread(
            id=str(uuid.uuid4()),
            title="Tool migration fixture",
            cwd=str(self.project),
            created_at=timestamp,
            updated_at=timestamp,
            rollout_path=self.root / "synthetic.jsonl",
        )
        items = [
            Item("u1", "user", "Inspect the synthetic historical tools.", timestamp, "userMessage"),
            Item(
                "t1",
                "assistant",
                "",
                timestamp,
                "commandExecution",
                raw={
                    "command": "printf synthetic-migration-output",
                    "aggregatedOutput": "synthetic-migration-output",
                    "status": "completed",
                    "exitCode": 0,
                },
            ),
            Item(
                "t2",
                "assistant",
                "",
                timestamp,
                "mcpToolCall",
                raw={
                    "server": "historical_fixture",
                    "tool": "lookup",
                    "arguments": {"value": "fixture"},
                    "result": {"text": "historical-mcp-result"},
                    "status": "completed",
                },
            ),
            Item(
                "a1",
                "assistant",
                "All fixture tools have already finished.",
                timestamp,
                "agentMessage",
            ),
        ]
        result = convert(thread, items)
        self.entries = result.entries
        self.sid = result.session_id
        request = self.resume()
        blocks = [
            block
            for message in request["messages"]
            for block in message["content"]
            if isinstance(block, dict)
        ]
        tool_uses = [block for block in blocks if block["type"] == "tool_use"]
        tool_results = [block for block in blocks if block["type"] == "tool_result"]
        self.assertEqual(
            [block["name"] for block in tool_uses], ["Bash", "mcp__historical_fixture__lookup"]
        )
        self.assertEqual(
            {block["id"] for block in tool_uses}, {block["tool_use_id"] for block in tool_results}
        )
        self.assertIn("historical-mcp-result", json.dumps(tool_results))
        self.assertIn("synthetic-migration-output", json.dumps(tool_results))
        self.assertEqual(request.get("tools", []), [])

    def test_oversized_conversion_resumes_without_sending_full_archive(self):
        from codex_to_claude.native import MAX_ACTIVE_BYTES, convert
        from codex_to_claude.source import Item, Thread

        timestamp = "2026-10-06T00:00:00.000Z"
        thread = Thread(
            id=str(uuid.uuid4()),
            title="Oversized migration fixture",
            cwd=str(self.project),
            created_at=timestamp,
            updated_at=timestamp,
            rollout_path=self.root / "synthetic.jsonl",
        )
        huge = (
            "archived-only-fixture-start\n"
            + ("large-synthetic-output " * 40000)
            + "\narchived-fixture-end"
        )
        result = convert(
            thread,
            [
                Item(
                    "u1",
                    "user",
                    "Keep the original archive available.",
                    timestamp,
                    "userMessage",
                    ordinal=0,
                ),
                Item(
                    "t1",
                    "assistant",
                    "",
                    timestamp,
                    "commandExecution",
                    ordinal=1,
                    raw={
                        "command": "echo synthetic-only",
                        "aggregatedOutput": huge,
                        "exitCode": 0,
                        "status": "completed",
                    },
                ),
                Item(
                    "u2",
                    "user",
                    "The next task is the bluebird fixture.",
                    timestamp,
                    "userMessage",
                    ordinal=2,
                ),
                Item(
                    "a1",
                    "assistant",
                    "I will continue the bluebird task.",
                    timestamp,
                    "agentMessage",
                    ordinal=3,
                ),
            ],
            transcript_path=str(self.root / "full-native-history.jsonl"),
        )
        self.entries = result.entries
        self.sid = result.session_id
        self.assertIn(huge, json.dumps(result.entries).replace("\\n", "\n"))
        self.assertTrue(any("bounded continuation" in warning for warning in result.warnings))
        request = self.resume()
        requests = [
            data
            for path, data in self.server.requests
            if path.startswith("/v1/messages") and not path.startswith("/v1/messages/count_tokens")
        ]
        self.assertEqual(
            len(requests), 1, "Importer must avoid a first oversized model compaction request"
        )
        outbound = json.dumps(request["messages"])
        self.assertLess(len(outbound.encode()), MAX_ACTIVE_BYTES)
        self.assertIn("bluebird", outbound)
        self.assertIn("full-native-history.jsonl", outbound)
        self.assertIn("abridged", outbound)

    @unittest.skipUnless(os.name == "posix", "interactive picker test uses a POSIX PTY")
    def test_interactive_resume_picker_shows_imported_session(self):
        import pty
        import select
        from codex_to_claude.native import convert
        from codex_to_claude.source import Item, Thread

        timestamp = "2026-10-06T00:00:00.000Z"
        thread = Thread(
            id=str(uuid.uuid4()),
            title="Picker migration fixture",
            cwd=str(self.project),
            created_at=timestamp,
            updated_at=timestamp,
            rollout_path=self.root / "synthetic.jsonl",
        )
        result = convert(
            thread,
            [
                Item(
                    "u1", "user", "Inspect this imported picker fixture.", timestamp, "userMessage"
                ),
                Item("a1", "assistant", "Synthetic imported answer.", timestamp, "agentMessage"),
            ],
        )
        self.entries = result.entries
        self.sid = result.session_id
        self.write_transcript()
        (self.config / ".claude.json").write_text(
            json.dumps(
                {
                    "hasCompletedOnboarding": True,
                    "theme": "dark",
                    "projects": {str(self.project): {"hasTrustDialogAccepted": True}},
                }
            )
        )
        master, slave = pty.openpty()
        process = subprocess.Popen(
            [
                self.binary,
                "--bare",
                "--safe-mode",
                "--resume",
                "--tools",
                "",
                "--strict-mcp-config",
                "--mcp-config",
                '{"mcpServers":{}}',
                "--setting-sources",
                "",
                "--permission-mode",
                "dontAsk",
                "--model",
                "claude-sonnet-4-6",
            ],
            cwd=self.project,
            env=self.environment(),
            stdin=slave,
            stdout=slave,
            stderr=slave,
        )
        os.close(slave)
        output = b""
        approved_fake_key = False
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], 0.2)
                if ready:
                    try:
                        output += os.read(master, 65536)
                    except OSError:
                        break
                if not approved_fake_key and b"ANTHROPIC_API_KEY" in output:
                    os.write(master, b"\x1b[A\r")
                    approved_fake_key = True
                if b"migration" in output:
                    break
            plain = re.sub(rb"\x1b\[[0-9;?]*[ -/]*[@-~]", b" ", output).decode(errors="replace")
            plain = " ".join(plain.split())
            self.assertIn("Resume session", plain)
            self.assertIn("Picker migration fixture", plain)
            self.assertFalse(
                any(path.startswith("/v1/messages") for path, _ in self.server.requests)
            )
        finally:
            process.terminate()
            process.wait(timeout=10)
            os.close(master)

    def test_compaction_keeps_summary_and_recent_turns_only_in_context(self):
        self.add_message("user", "precompact-do-not-send-redwood")
        self.add_message("assistant", "precompact-do-not-send-juniper")
        old_parent = self.parent
        boundary_id = str(uuid.uuid4())
        boundary = self.common(boundary_id)
        boundary.update(
            type="system",
            subtype="compact_boundary",
            parentUuid=None,
            logicalParentUuid=old_parent,
            content="Conversation compacted",
            level="info",
            isMeta=False,
            compactMetadata={"trigger": "auto", "preTokens": 100},
        )
        self.entries.append(boundary)
        self.parent = boundary_id
        summary = self.add_message("user", "Imported compact summary: use fixture-key-bluebird.")
        summary["isCompactSummary"] = True
        self.add_message("assistant", "Recent assistant fixture preserved.")
        request = self.resume()
        transcript = json.dumps(request["messages"])
        self.assertNotIn("precompact-do-not-send", transcript)
        self.assertIn("Imported compact summary", transcript)
        self.assertIn("Recent assistant fixture preserved.", transcript)
        self.assertIn("Continue the synthetic fixture.", transcript)


def verify_exported_corpus(config_directory: str) -> dict:
    from claude_agent_sdk import get_session_messages, list_sessions

    config = Path(config_directory).resolve()
    expected = {p.stem for p in (config / "projects").glob("*/*.jsonl")}
    with patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": str(config)}):
        sessions = list_sessions()
        found = {session.session_id for session in sessions}
        missing = sorted(expected - found)
        if missing:
            raise AssertionError(f"SDK did not discover {len(missing)} session(s): {missing}")
        message_count = 0
        for session in sessions:
            messages = get_session_messages(session.session_id, directory=session.cwd)
            if not messages:
                raise AssertionError(f"SDK read no active messages: {session.session_id}")
            message_count += len(messages)
    return {"sessions": len(sessions), "active_messages": message_count, "missing_sessions": 0}


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--verify-config":
        print(json.dumps(verify_exported_corpus(sys.argv[2])))
    else:
        unittest.main()
