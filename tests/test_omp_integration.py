"""Opt-in native OMP discovery and continuation, using only synthetic data.

Install the official can1357/oh-my-pi runtime and Bun in a private directory:
  npm install --prefix /tmp/c2c-omp-runtime bun @oh-my-pi/pi-coding-agent
  zig build
  RUN_OMP_INTEGRATION=1 \
    BUN_BINARY=/tmp/c2c-omp-runtime/node_modules/.bin/bun \
    OMP_BINARY=/tmp/c2c-omp-runtime/node_modules/.bin/omp \
    python -m unittest discover -s tests -p test_omp_integration.py -v

Verified with OMP 18.6.1 and Bun 1.4.2. The npm source distribution is needed for
native SessionManager reader checks. If npm skips Bun's install script, run
``node install.js`` in the private prefix's ``node_modules/bun`` directory.
OMP_PACKAGE_DIR can override its location, and C2C_BINARY can override the Zig
executable. Tests never install packages themselves. HOME, agent configuration,
sessions, and credentials are temporary. The official test-runtime flag disables
catalog networking; a Bun preload additionally rejects every fetch except this
test's loopback server. Historical tool calls are never executed.
"""

from __future__ import annotations

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import threading
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[1]
STAMP = "2026-10-01T10:00:00.000Z"
REPLY = "Synthetic OMP continuation: fixture-key-bluebird is preserved."
PROMPT = "Continue the synthetic fixture and keep fixture-key-bluebird."
PIXEL = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4z8AARAwQCgAf7gP9i18U1AAAAABJRU5ErkJggg=="


class _Messages(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        request = json.loads(body or "{}")
        self.server.requests.append((self.path, request))
        if self.path.split("?", 1)[0] != "/v1/messages":
            self.send_error(404)
            return
        message = {
            "id": "msg_omp_synthetic_fixture", "type": "message", "role": "assistant",
            "model": request["model"], "content": [], "stop_reason": None,
            "stop_sequence": None, "usage": {"input_tokens": 100, "output_tokens": 0},
        }
        events = [
            {"type": "message_start", "message": message},
            {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
            {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": REPLY}},
            {"type": "content_block_stop", "index": 0},
            {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None},
             "usage": {"output_tokens": 12}},
            {"type": "message_stop"},
        ]
        if request.get("stream"):
            body = "".join(f"event: {event['type']}\ndata: {json.dumps(event)}\n\n" for event in events).encode()
            content_type = "text/event-stream"
        else:
            body = json.dumps({**message, "content": [{"type": "text", "text": REPLY}],
                               "stop_reason": "end_turn"}).encode()
            content_type = "application/json"
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


@unittest.skipUnless(os.environ.get("RUN_OMP_INTEGRATION") == "1",
                     "set RUN_OMP_INTEGRATION=1 for offline native OMP tests")
class OmpNativeIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.bun = os.environ.get("BUN_BINARY") or shutil.which("bun")
        self.omp = os.environ.get("OMP_BINARY") or shutil.which("omp")
        if not self.bun or not self.omp:
            self.skipTest("install official @oh-my-pi/pi-coding-agent and Bun in a private directory")
        self.bun = str(Path(self.bun).resolve())
        self.omp = str(Path(self.omp).resolve())
        package = os.environ.get("OMP_PACKAGE_DIR")
        self.package = Path(package).resolve() if package else Path(self.omp).parent.parent
        self.manager_module = self.package / "src/session/session-manager.ts"
        if not self.manager_module.is_file():
            self.skipTest("OMP_PACKAGE_DIR must point to the official npm source distribution")
        self.assertEqual(json.loads((self.package / "package.json").read_text())["name"],
                         "@oh-my-pi/pi-coding-agent")
        self.binary = Path(os.environ.get("C2C_BINARY", ROOT / "zig-out/bin/c2c")).resolve()
        self.temp = tempfile.TemporaryDirectory(prefix="c2c-omp-offline-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.project = self.root / "project"
        self.home = self.root / "home"
        self.agent = self.root / "omp/agent"
        self.claude = self.root / "claude"
        for directory in (self.project, self.home, self.agent, self.claude):
            directory.mkdir(parents=True)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), _Messages)
        self.server.requests = []
        self.worker = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.worker.start()
        self.addCleanup(self._close_server)
        self.base = f"http://127.0.0.1:{self.server.server_port}"
        self.env = {key: os.environ[key] for key in ("PATH", "LANG", "LC_ALL", "SYSTEMROOT") if key in os.environ}
        self.env.update(
            HOME=str(self.home), USERPROFILE=str(self.home),
            XDG_CONFIG_HOME=str(self.home / ".config"), XDG_CACHE_HOME=str(self.home / ".cache"),
            XDG_DATA_HOME=str(self.home / ".local/share"),
            PI_CODING_AGENT_DIR=str(self.agent), PI_TEST_RUNTIME="1",
            CLAUDE_CONFIG_DIR=str(self.claude), CODEX_HOME=str(self.root / "codex"),
            DO_NOT_TRACK="1", OTEL_SDK_DISABLED="true", NO_PROXY="127.0.0.1,localhost", TERM="dumb",
        )
        self.env["PATH"] = str(Path(self.bun).parent) + os.pathsep + self.env.get("PATH", "")
        (self.agent / "models.yml").write_text(json.dumps({"providers": {"fixture": {
            "baseUrl": self.base, "apiKey": "synthetic-offline-key", "api": "anthropic-messages",
            "models": [{"id": "fixture-model", "name": "Offline fixture", "reasoning": False,
                        "input": ["text", "image"], "contextWindow": 128000, "maxTokens": 1024,
                        "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}}],
        }}}))
        (self.agent / "config.yml").write_text(json.dumps({
            "telemetry": {"otlpExportEnabled": False}, "mcp": {"enableProjectConfig": False},
            "startup": {"checkUpdate": False}, "marketplace": {"autoUpdate": "off"},
            "memory": {"backend": "off"}, "compaction": {"enabled": False, "idleEnabled": False},
            "modelRoles": {"default": "fixture/fixture-model", "tiny": "fixture/fixture-model"},
        }))
        self.blocked = self.root / "blocked-fetches.jsonl"
        self.preload = self.root / "loopback-only.ts"
        self.preload.write_text(
            'import {appendFileSync} from "node:fs";\n'
            'const originalFetch = globalThis.fetch;\n'
            'globalThis.fetch = ((input, init) => {\n'
            '  const url = new URL(typeof input === "string" || input instanceof URL ? input : input.url);\n'
            f'  if (url.origin !== {json.dumps(self.base)}) {{\n'
            f'    appendFileSync({json.dumps(str(self.blocked))}, JSON.stringify(url.href) + "\\n");\n'
            '    return Promise.reject(new Error("Offline fixture blocked external fetch"));\n'
            '  }\n'
            '  return originalFetch(input, init);\n'
            '}) as typeof fetch;\n'
        )
        self.reader = self.root / "inspect-session.ts"
        self.reader.write_text(
            f'import {{SessionManager}} from {json.dumps(str(self.manager_module))};\n'
            'const [action, cwd, file, output] = process.argv.slice(2);\n'
            'if (action === "path") {\n'
            '  console.log(JSON.stringify({directory: SessionManager.getDefaultSessionDir(cwd)}));\n'
            '} else {\n'
            '  const sessions = await SessionManager.listForPicker(cwd);\n'
            '  const manager = await SessionManager.open(file, undefined, undefined, {throwIfMissing:true, suppressBreadcrumb:true});\n'
            '  await Bun.write(output, JSON.stringify({sessions, id:manager.getSessionId(), title:manager.getSessionName(), '
            'messages:manager.buildSessionContext().messages, entries:manager.getEntries()}));\n'
            '  await manager.close();\n'
            '}\n'
        )
        result = self._run([self.bun, "--preload", str(self.preload), str(self.reader), "path", str(self.project)])
        self.session_dir = Path(json.loads(result.stdout.splitlines()[-1])["directory"])

    def _close_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.worker.join(timeout=2)

    def _run(self, command, *, timeout=90):
        result = subprocess.run(command, cwd=self.project, env=self.env, capture_output=True,
                                text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        self.assertEqual(result.returncode, 0, result.stderr[-7000:] + result.stdout[-7000:])
        self.assertFalse(self.blocked.exists(), "Native runtime attempted a non-loopback fetch")
        return result

    def _inspect(self, path):
        output = self.root / "inspection.json"
        self._run([self.bun, "--preload", str(self.preload), str(self.reader),
                   "inspect", str(self.project), str(path), str(output)])
        value = json.loads(output.read_text())
        sessions = [s for s in value["sessions"] if s["id"] == value["id"]]
        self.assertEqual(len(sessions), 1, "Native project resume picker must discover the session")
        self.assertEqual(sessions[0]["cwd"], str(self.project))
        return value

    def _resume(self, path):
        before = len(self.server.requests)
        result = self._run([
            self.bun, "--preload", str(self.preload), self.omp,
            "--session", str(path), "--session-dir", str(path.parent), "--print",
            "--model", "fixture/fixture-model", "--no-tools", "--no-extensions", "--no-skills",
            "--no-rules", "--no-title", "--no-lsp", "--no-pty", "--no-prewalk",
            "--system-prompt", "This is a synthetic local migration compatibility test.", PROMPT,
        ])
        self.assertIn(REPLY, result.stdout)
        requests = self.server.requests[before:]
        self.assertEqual(len(requests), 1, "A continuation must make exactly one loopback model request")
        path_requested, request = requests[0]
        self.assertEqual(path_requested.split("?", 1)[0], "/v1/messages")
        self.assertEqual(request["model"], "fixture-model")
        self.assertEqual(request.get("tools", []), [])
        persisted = self._inspect(path)
        assistants = [m for m in persisted["messages"] if m["role"] == "assistant"]
        self.assertEqual(assistants[-1]["content"][0]["text"], REPLY)
        self.assertEqual(assistants[-1]["provider"], "fixture")
        self.assertEqual(assistants[-1]["model"], "fixture-model")
        messages = [e for e in persisted["entries"] if e["type"] == "message"]
        self.assertEqual(messages[-1]["parentId"], messages[-2]["id"])
        self.assertEqual(messages[-2]["message"]["content"][0]["text"], PROMPT)
        return request

    def _native_fixture(self, messages, *, compact=False):
        sid, parent, entries = str(uuid.uuid4()), None, []
        entries.append({"type": "session", "version": 3, "id": sid, "timestamp": STAMP,
                        "cwd": str(self.project), "title": "Synthetic imported OMP fixture", "titleSource": "user"})
        for role, content in messages:
            identity = uuid.uuid4().hex[:16]
            message = {"role": role, "content": content, "timestamp": 1790848800000}
            if role == "assistant":
                message.update(api="openai-completions", provider="c2c", model="imported-history",
                               usage={"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0,
                                      "totalTokens": 0, "cost": {"input": 0, "output": 0,
                                      "cacheRead": 0, "cacheWrite": 0, "total": 0}}, stopReason="stop")
            entries.append({"type": "message", "id": identity, "parentId": parent,
                            "timestamp": STAMP, "message": message})
            parent = identity
        if compact:
            entries.append({"type": "compaction", "id": uuid.uuid4().hex[:16], "parentId": parent,
                            "timestamp": STAMP, "summary": "Synthetic compact summary: fixture-key-bluebird.",
                            "firstKeptEntryId": entries[3]["id"], "tokensBefore": 1000})
        path = self.session_dir / f"2026-10-01T10-00-00-000Z_{sid}.jsonl"
        path.write_text("".join(json.dumps(e) + "\n" for e in entries))
        return path

    def _claude_fixture(self, messages):
        sid, parent, entries = str(uuid.uuid4()), None, []
        for role, content in messages:
            identity = str(uuid.uuid4())
            message = {"role": role, "content": content}
            if role == "assistant":
                has_tools = isinstance(content, list) and any(b.get("type") == "tool_use" for b in content)
                message.update(model="<synthetic>", id="msg_" + identity, type="message",
                               stop_reason="tool_use" if has_tools else "end_turn", stop_sequence=None,
                               usage={"input_tokens": 0, "output_tokens": 0})
            entries.append({"uuid": identity, "parentUuid": parent, "sessionId": sid,
                            "cwd": str(self.project), "version": "2.1.289", "entrypoint": "cli",
                            "userType": "external", "isSidechain": False, "timestamp": STAMP,
                            "type": role, "message": message})
            parent = identity
        entries.append({"type": "custom-title", "sessionId": sid, "customTitle": "Synthetic Claude to OMP fixture"})
        folder = self.claude / "projects" / re.sub(r"[^a-zA-Z0-9]", "-", str(self.project))
        folder.mkdir(parents=True)
        path = folder / (sid + ".jsonl")
        path.write_text("".join(json.dumps(e) + "\n" for e in entries))
        return path

    def _migrate(self, source="claude", target="omp"):
        self.assertTrue(self.binary.is_file(), "Build the Zig c2c executable before converter integration tests")
        before = len(self.server.requests)
        result = self._run([str(self.binary), "migrate", "--from", source, "--to", target,
                            "--omp-home", str(self.agent), "--claude-home", str(self.claude),
                            "--output-dir", str(self.root / (source + "-to-" + target)), "--json"])
        self.assertEqual(len(self.server.requests), before, "Migration must not request model output")
        return json.loads(result.stdout)

    def test_official_reader_discovers_and_cli_appends_native_continuation(self):
        path = self._native_fixture([
            ("user", [{"type": "text", "text": "Remember fixture-key-bluebird."}]),
            ("assistant", [{"type": "text", "text": "The prior imported answer remains in history."}]),
        ])
        native = self._inspect(path)
        self.assertEqual(native["title"], "Synthetic imported OMP fixture")
        self.assertEqual([m["role"] for m in native["messages"]], ["user", "assistant"])
        request = self._resume(path)
        self.assertEqual([m["role"] for m in request["messages"]], ["user", "assistant", "user"])
        outbound = json.dumps(request["messages"])
        self.assertIn("Remember fixture-key-bluebird.", outbound)
        self.assertIn("The prior imported answer remains in history.", outbound)
        self.assertIn(PROMPT, outbound)

    def test_native_compaction_excludes_archive_from_continuation(self):
        path = self._native_fixture([
            ("user", [{"type": "text", "text": "archived-do-not-send-redwood"}]),
            ("assistant", [{"type": "text", "text": "archived-do-not-send-juniper"}]),
            ("user", [{"type": "text", "text": "Recent synthetic request retained."}]),
            ("assistant", [{"type": "text", "text": "Recent synthetic answer retained."}]),
        ], compact=True)
        request = self._resume(path)
        outbound = json.dumps(request["messages"])
        self.assertNotIn("archived-do-not-send", outbound)
        self.assertIn("Synthetic compact summary: fixture-key-bluebird.", outbound)
        self.assertIn("Recent synthetic request retained.", outbound)
        self.assertIn("Recent synthetic answer retained.", outbound)
        self.assertIn("archived-do-not-send-redwood", path.read_text())

    def test_compiled_converter_preserves_tools_images_and_native_continuation(self):
        self._claude_fixture([
            ("user", [{"type": "text", "text": "Inspect fixture-key-bluebird and this image."},
                      {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": PIXEL}}]),
            ("assistant", [{"type": "tool_use", "id": "tool_fixture", "name": "Bash",
                            "input": {"command": "printf historical-synthetic-output"}}]),
            ("user", [{"type": "tool_result", "tool_use_id": "tool_fixture", "content": "historical-synthetic-output"}]),
            ("assistant", [{"type": "tool_use", "id": "mcp_fixture", "name": "mcp__fixture__lookup",
                            "input": {"value": "synthetic"}}]),
            ("user", [{"type": "tool_result", "tool_use_id": "mcp_fixture", "content": "historical-mcp-result"}]),
            ("assistant", [{"type": "text", "text": "All historical fixture tools have already finished."}]),
        ])
        self._migrate()
        paths = list((self.agent / "sessions").glob("**/*.jsonl"))
        self.assertEqual(len(paths), 1)
        native = self._inspect(paths[0])
        self.assertEqual(native["title"], "Synthetic Claude to OMP fixture")
        self.assertEqual([m["role"] for m in native["messages"]],
                         ["user", "assistant", "toolResult", "assistant", "toolResult", "assistant"])
        self.assertIn(PIXEL, json.dumps(native["messages"]))
        original_claude_paths = set((self.claude / "projects").glob("*/*.jsonl"))
        self._migrate("omp", "claude")
        self.assertEqual(set((self.claude / "projects").glob("*/*.jsonl")), original_claude_paths,
                         "Reading an untouched import with OMP must not manufacture a continuation")
        request = self._resume(paths[0])
        blocks = [b for m in request["messages"] for b in m["content"] if isinstance(b, dict)]
        calls = [b for b in blocks if b["type"] == "tool_use"]
        results = [b for b in blocks if b["type"] == "tool_result"]
        self.assertEqual(len(calls), 2)
        self.assertEqual({b["id"] for b in calls}, {b["tool_use_id"] for b in results})
        self.assertIn("historical-synthetic-output", json.dumps(results))
        self.assertIn("historical-mcp-result", json.dumps(results))
        self.assertTrue(any(b["type"] == "image" and b["source"].get("data") == PIXEL for b in blocks))
        self._migrate("omp", "claude")
        imported = [p for p in (self.claude / "projects").glob("*/*.jsonl") if REPLY in p.read_text()]
        self.assertEqual(len(imported), 1, "OMP's persisted native continuation must survive return migration")

    def test_compiled_converter_bounds_large_tool_archive_before_native_resume(self):
        archive = "archived-only-marker-start\n" + "synthetic-tool-output " * 17000 + "\narchived-only-marker-end"
        self._claude_fixture([
            ("user", [{"type": "text", "text": "Read a large completed synthetic tool result."}]),
            ("assistant", [{"type": "tool_use", "id": "large_fixture", "name": "Bash",
                            "input": {"command": "printf synthetic-large-output"}}]),
            ("user", [{"type": "tool_result", "tool_use_id": "large_fixture", "content": archive}]),
            ("assistant", [{"type": "text", "text": "The archived tool run has finished."}]),
            ("user", [{"type": "text", "text": "The recent task uses fixture-key-bluebird."}]),
            ("assistant", [{"type": "text", "text": "I will continue the recent bluebird task."}]),
        ])
        self._migrate()
        paths = list((self.agent / "sessions").glob("**/*.jsonl"))
        self.assertEqual(len(paths), 1)
        self.assertIn(archive, json.dumps([json.loads(line) for line in paths[0].read_text().splitlines()]).replace("\\n", "\n"))
        self.assertTrue(any(json.loads(line).get("type") == "compaction" for line in paths[0].read_text().splitlines()))
        request = self._resume(paths[0])
        outbound = json.dumps(request["messages"])
        self.assertLess(len(outbound.encode()), 240_000)
        self.assertNotIn("archived-only-marker", outbound)
        self.assertIn("fixture-key-bluebird", outbound)
        self.assertIn("full native transcript", outbound)
        self.assertIn("archived-only-marker-end", paths[0].read_text())


if __name__ == "__main__":
    unittest.main()
