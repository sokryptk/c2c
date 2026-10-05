"""Twelve directed provider migrations through the compiled native executable.

Build first, then run:
  RUN_PROVIDER_MATRIX=1 C2C_OPENCODE_BINARY=/path/to/opencode \
    python3 -m unittest discover -s tests -p test_provider_matrix.py -v

The fixtures are independently authored native records, not output from a Python
converter. OpenCode fixtures use its native standalone import to initialize the
real v2 schema. Continuations are synthetic native writes; dedicated integration
suites separately exercise actual provider resume/model requests. Every home,
configuration, source, target, journal and database lives in a temporary tree.
"""
from __future__ import annotations

from contextlib import contextmanager
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
PROVIDERS = ("codex", "claude", "omp", "opencode")
STAMP = "2026-01-02T03:04:05.000Z"  # Old sessions must register in a fresh home.
MS = 1767323045000
USER = "MATRIX_USER: café, हाँ; preserve the green door."
ANSWER = "MATRIX_ANSWER: the green door is preserved."
OUTPUT = "MATRIX_TOOL_RESULT: synthetic record found."
CONTINUED_USER = "MATRIX_CONTINUATION_USER: also remember the brass handle."
CONTINUED_ANSWER = "MATRIX_CONTINUATION_ANSWER: brass handle saved."
PRIVATE = "MATRIX_PRIVATE_REASONING_NOT_FOR_TRANSFER"
TOOL = "mcp__fixture__inspect"
PIXEL = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4z8AARAwQCgAf7gP9i18U1AAAAABJRU5ErkJggg=="
IMAGE_URL = "data:image/png;base64," + PIXEL


@contextmanager
def database(*args, **kwargs):
    connection = sqlite3.connect(*args, **kwargs)
    try:
        with connection:
            yield connection
    finally:
        connection.close()


def text(value):
    return {"type": "text", "text": value}


def write_jsonl(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows))


def read_jsonl(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def expected_id(source, target, sid):
    if (source, target) == ("codex", "claude"):
        value = uuid.uuid5(uuid.UUID("6ee9e2ac-f1e7-4ed0-9ecb-ced168929080"), "session:" + sid)
    elif (source, target) == ("claude", "codex"):
        value = uuid.uuid5(uuid.UUID("b18998c2-4d26-40bd-9c20-2dd493c3a146"), "claude-session:" + sid)
    else:
        value = uuid.uuid5(uuid.UUID("513b91c0-7a0b-45e8-bc3c-8516e955c21d"), f"{target}:{source}:{sid}")
    return ("ses_" if target == "opencode" else "") + str(value)


@unittest.skipUnless(os.environ.get("RUN_PROVIDER_MATRIX") == "1", "set RUN_PROVIDER_MATRIX=1 for native migration matrix")
class ProviderMatrixTests(unittest.TestCase):
    def setUp(self):
        self.binary = str(Path(os.environ.get("C2C_BINARY", ROOT / "zig-out/bin/c2c")).resolve())
        self.assertTrue(Path(self.binary).is_file(), "Build the native CLI first")
        self.opencode = os.environ.get("C2C_OPENCODE_BINARY") or shutil.which("opencode")
        self.temp = tempfile.TemporaryDirectory(prefix="c2c-provider-matrix-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.user_home = self.root / "home"
        self.project = self.root / "work/selected"
        self.decoy_project = self.root / "work-other/decoy"
        self.homes = {name: self.root / name for name in PROVIDERS}
        for directory in [self.user_home, self.project, self.decoy_project, *self.homes.values()]:
            directory.mkdir(parents=True)
        self.env = {key: os.environ[key] for key in ("PATH", "LANG", "LC_ALL", "SYSTEMROOT") if key in os.environ}
        self.env.update(
            HOME=str(self.user_home), USERPROFILE=str(self.user_home),
            XDG_CONFIG_HOME=str(self.user_home / "config"), XDG_DATA_HOME=str(self.user_home / "data"),
            XDG_STATE_HOME=str(self.user_home / "state"), XDG_CACHE_HOME=str(self.user_home / "cache"),
            CODEX_HOME=str(self.homes["codex"]), CLAUDE_CONFIG_DIR=str(self.homes["claude"]),
            PI_CODING_AGENT_DIR=str(self.homes["omp"]), PI_TEST_RUNTIME="1",
            OPENCODE_DB=str(self.homes["opencode"] / "opencode.db"),
            OPENCODE_CONFIG_DIR=str(self.user_home / "opencode-config"),
            OPENCODE_CONFIG_CONTENT=json.dumps({"update": "disable", "share": "disabled", "snapshots": False,
                                                "warming": False, "plugin": [], "mcp": {}}),
            OPENCODE_DISABLE_PROJECT_CONFIG="1", OPENCODE_DISABLE_MODELS_FETCH="1",
            OPENCODE_DISABLE_FILEWATCHER="1", DO_NOT_TRACK="1", OTEL_SDK_DISABLED="true",
            CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1", DISABLE_TELEMETRY="1", TERM="dumb",
        )
        Path(self.env["OPENCODE_CONFIG_DIR"]).mkdir()
        if self.opencode:
            self.env["C2C_OPENCODE_BINARY"] = self.opencode

    def run_command(self, args, *, timeout=120):
        result = subprocess.run([str(arg) for arg in args], cwd=self.project, env=self.env,
                                capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        self.assertEqual(result.returncode, 0, result.stderr[-4000:] + result.stdout[-4000:])
        return result

    def action(self, source, target, action="migrate", *, thread=None, extra=()):
        command = [self.binary, action, "--from", source, "--to", target, "--json",
                   "--output-dir", self.root / "journals" / f"{source}-to-{target}"]
        for provider, home in self.homes.items():
            command.extend(["--" + provider + "-home", home])
        if thread:
            command.extend(["--thread", thread])
        command.extend(extra)
        return json.loads(self.run_command(command).stdout)

    def one_status(self, result, status):
        self.assertEqual(result["counts"], {status: 1}, json.dumps(result, ensure_ascii=False))
        self.assertEqual(len(result["threads"]), 1)
        return result["threads"][0]

    def claude_rows(self, sid, cwd, messages, parent=None):
        rows = []
        for role, content in messages:
            identity = str(uuid.uuid4())
            message = {"role": role, "content": content}
            if role == "assistant":
                calls = isinstance(content, list) and any(block.get("type") == "tool_use" for block in content)
                message.update(id="msg_" + identity, type="message", model="<synthetic>",
                               stop_reason="tool_use" if calls else "end_turn", stop_sequence=None,
                               usage={"input_tokens": 0, "output_tokens": 0})
            rows.append({"uuid": identity, "parentUuid": parent, "sessionId": sid, "cwd": str(cwd),
                         "version": "2.1.289", "entrypoint": "cli", "isSidechain": False,
                         "type": role, "timestamp": STAMP, "message": message})
            parent = identity
        return rows

    def omp_rows(self, messages, parent=None):
        rows = []
        for message in messages:
            identity = uuid.uuid4().hex[:16]
            message = {**message, "timestamp": MS}
            if message["role"] == "assistant":
                message.update(api="anthropic-messages", provider="synthetic", model="fixture-model",
                               usage={"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0,
                                      "totalTokens": 0, "cost": {"input": 0, "output": 0,
                                                               "cacheRead": 0, "cacheWrite": 0, "total": 0}},
                               stopReason="toolUse" if any(p.get("type") == "toolCall" for p in message["content"]) else "stop")
            rows.append({"type": "message", "id": identity, "parentId": parent,
                         "timestamp": STAMP, "message": message})
            parent = identity
        return rows

    def codex_rows(self, sid, user=USER, answer=ANSWER, *, rich=True):
        turn_id = str(uuid.uuid4())
        rows = []
        def row(kind, payload):
            rows.append({"type": kind, "timestamp": STAMP, "payload": payload})
        def visible(item):
            row("event_msg", {"type": "item_completed", "thread_id": sid, "turn_id": turn_id,
                              "item": item, "started_at_ms": MS, "completed_at_ms": MS})
        row("event_msg", {"type": "task_started", "turn_id": turn_id, "started_at": MS,
                          "model_context_window": None, "collaboration_mode_kind": "default"})
        mid = str(uuid.uuid4())
        content = [{"type": "input_text", "text": user}]
        if rich:
            content.append({"type": "input_image", "image_url": IMAGE_URL})
        row("response_item", {"type": "message", "id": mid, "role": "user", "content": content})
        visible({"type": "UserMessage", "id": mid, "content": [{"type": "text", "text": user, "text_elements": []}]
                 + ([{"type": "image", "image_url": IMAGE_URL}] if rich else [])})
        if rich:
            row("response_item", {"type": "reasoning", "summary": [{"type": "summary_text", "text": PRIVATE}]})
            row("response_item", {"type": "function_call", "call_id": "fixture_tool", "name": TOOL,
                                  "arguments": json.dumps({"path": "synthetic-never-executed"})})
            row("response_item", {"type": "function_call_output", "call_id": "fixture_tool", "output": OUTPUT})
        mid = str(uuid.uuid4())
        row("response_item", {"type": "message", "id": mid, "role": "assistant", "phase": "final_answer",
                              "content": [{"type": "output_text", "text": answer}]})
        visible({"type": "AgentMessage", "id": mid, "phase": "final_answer", "content": [text(answer)]})
        # Codex display AgentMessage uses capital Text.
        rows[-1]["payload"]["item"]["content"][0]["type"] = "Text"
        row("event_msg", {"type": "task_complete", "turn_id": turn_id, "last_agent_message": answer,
                          "started_at": MS, "completed_at": MS, "duration_ms": 0})
        return rows

    def open_message(self, role, content, *, rich=False):
        message = {"id": "msg_" + uuid.uuid4().hex, "type": role, "time": {"created": MS}}
        if role == "user":
            message["text"] = content
            if rich:
                message["files"] = [{"data": PIXEL, "mime": "image/png", "source": {"type": "inline"}}]
        else:
            message.update(agent="build", model={"providerID": "synthetic", "id": "fixture"}, finish="stop",
                           content=content if isinstance(content, list) else [text(content)])
            message["time"]["completed"] = MS
        return message

    def fixture(self, provider, cwd, *, rich=True):
        sid = str(uuid.uuid4())
        content_user = USER if rich else "SCOPE_DECOY_USER"
        content_answer = ANSWER if rich else "SCOPE_DECOY_ANSWER"
        if provider == "claude":
            image = {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": PIXEL}}
            messages = [("user", [text(content_user), image] if rich else content_user)]
            if rich:
                messages.extend([
                    ("assistant", [{"type": "thinking", "thinking": PRIVATE},
                                   {"type": "tool_use", "id": "fixture_tool", "name": TOOL,
                                    "input": {"path": "synthetic-never-executed"}}]),
                    ("user", [{"type": "tool_result", "tool_use_id": "fixture_tool", "content": OUTPUT}]),
                ])
            messages.append(("assistant", content_answer))
            path = self.homes[provider] / "projects" / re.sub(r"[^a-zA-Z0-9-]", "-", str(cwd)) / (sid + ".jsonl")
            write_jsonl(path, self.claude_rows(sid, cwd, messages) + [{"type": "custom-title", "sessionId": sid, "customTitle": "Matrix fixture"}])
        elif provider == "omp":
            user_content = [text(content_user)] + ([{"type": "image", "data": PIXEL, "mimeType": "image/png"}] if rich else [])
            messages = [{"role": "user", "content": user_content}]
            if rich:
                messages.extend([
                    {"role": "assistant", "content": [{"type": "thinking", "thinking": PRIVATE},
                                                          {"type": "toolCall", "id": "fixture_tool", "name": TOOL,
                                                           "arguments": {"path": "synthetic-never-executed"}}]},
                    {"role": "toolResult", "toolCallId": "fixture_tool", "toolName": TOOL,
                     "content": [text(OUTPUT)], "isError": False},
                ])
            messages.append({"role": "assistant", "content": [text(content_answer)]})
            path = self.homes[provider] / "sessions" / "synthetic-matrix" / (sid + ".jsonl")
            write_jsonl(path, [{"type": "session", "version": 3, "id": sid, "timestamp": STAMP,
                                "cwd": str(cwd), "title": "Matrix fixture", "titleSource": "user"}] + self.omp_rows(messages))
        elif provider == "codex":
            path = self.homes[provider] / "sessions/2026/01/02" / f"rollout-2026-01-02T03-04-05-{sid}.jsonl"
            metadata = {"id": sid, "session_id": sid, "timestamp": STAMP, "cwd": str(cwd), "originator": "synthetic-fixture",
                        "cli_version": "0.159.2", "source": "cli", "model_provider": "openai", "history_mode": "legacy", "base_instructions": None}
            write_jsonl(path, [{"type": "session_meta", "timestamp": STAMP, "payload": metadata}]
                        + self.codex_rows(sid, content_user, content_answer, rich=rich))
        else:
            sid = "ses_" + sid
            messages = [self.open_message("user", content_user, rich=rich)]
            if rich:
                tool = {"type": "tool", "id": "fixture_tool", "name": TOOL, "time": {"created": MS, "completed": MS},
                        "state": {"status": "completed", "input": {"path": "synthetic-never-executed"}, "content": [text(OUTPUT)]}}
                messages.append(self.open_message("assistant", [tool]))
            messages.append(self.open_message("assistant", content_answer))
            info = {"id": sid, "projectID": "global", "title": "Matrix fixture", "location": {"directory": str(cwd)},
                    "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
                    "time": {"created": MS, "updated": MS}, "metadata": {}}
            path = self.root / (sid + ".json")
            path.write_text(json.dumps({"info": info, "messages": messages}))
            self.run_command([self.opencode, "session", "import", "--standalone", "--directory", cwd, path])
        return sid, path

    def native(self, provider, sid, path):
        if provider == "opencode":
            with database(f"file:{self.homes[provider] / 'opencode.db'}?mode=ro", uri=True) as db:
                db.row_factory = sqlite3.Row
                info = db.execute("SELECT * FROM session_v2 WHERE id=?", (sid,)).fetchone()
                self.assertIsNotNone(info, "Native session index is missing the installed conversation")
                rows = []
                for row in db.execute("SELECT id,type,data FROM session_message WHERE session_id=? ORDER BY seq", (sid,)):
                    rows.append({**json.loads(row["data"]), "id": row["id"], "type": row["type"]})
                return {"info": dict(info), "messages": rows}
        return read_jsonl(Path(path))

    def snapshot(self, provider, sid, path):
        return hashlib.sha256(json.dumps(self.native(provider, sid, path), sort_keys=True, ensure_ascii=False).encode()).hexdigest()

    def assert_fidelity(self, provider, sid, path, *, continued=False):
        native = self.native(provider, sid, path)
        encoded = json.dumps(native, ensure_ascii=False)
        for expected in [USER, ANSWER, OUTPUT] + ([CONTINUED_USER, CONTINUED_ANSWER] if continued else []):
            self.assertIn(expected, encoded)
        self.assertLess(encoded.index(USER), encoded.index(ANSWER))
        self.assertNotIn(PRIVATE, encoded)
        calls, results, images = [], [], []
        if provider == "codex":
            for row in native:
                if row["type"] != "response_item":
                    continue
                part = row["payload"]
                if part["type"] == "function_call":
                    calls.append(part["call_id"])
                elif part["type"] == "function_call_output":
                    results.append(part["call_id"])
                elif part["type"] == "message":
                    images.extend(p.get("image_url") for p in part["content"] if p["type"] == "input_image")
        elif provider == "opencode":
            for message in native["messages"]:
                images.extend("data:" + f["mime"] + ";base64," + f["data"] for f in message.get("files", []))
                for part in message.get("content", []):
                    if part["type"] == "tool":
                        calls.append(part["id"])
                        self.assertEqual(part["state"]["status"], "completed")
                        results.append(part["id"])
        else:
            for row in native:
                message = row.get("message", {})
                content = message.get("content", [])
                if not isinstance(content, list):
                    continue
                if provider == "omp" and message.get("role") == "toolResult":
                    results.append(message["toolCallId"])
                for part in content:
                    if part["type"] in ("tool_use", "toolCall"):
                        calls.append(part["id"])
                    elif part["type"] == "tool_result":
                        results.append(part["tool_use_id"])
                    elif part["type"] == "image":
                        source = part.get("source", {})
                        images.append("data:" + source.get("media_type", part.get("mimeType", "")) + ";base64," + source.get("data", part.get("data", "")))
        self.assertEqual(len(calls), 1, "Expected exactly one historical tool call")
        self.assertEqual(calls, results, "Tool history must remain fully paired")
        self.assertIn(IMAGE_URL, images, "Image must remain a native image block, not JSON/text")
        if continued:
            self.assertLess(encoded.index(ANSWER), encoded.index(CONTINUED_USER))
            self.assertLess(encoded.index(CONTINUED_USER), encoded.index(CONTINUED_ANSWER))

    def append_continuation(self, provider, sid, path):
        if provider == "opencode":
            # Simulate native persistence in this temporary DB only. Native
            # resume compatibility is exercised separately, without duplicating
            # paid/model-turn tests across all twelve route combinations.
            messages = [self.open_message("user", CONTINUED_USER), self.open_message("assistant", CONTINUED_ANSWER)]
            with database(self.homes[provider] / "opencode.db") as db:
                seq = db.execute("SELECT COALESCE(MAX(seq),0) FROM session_message WHERE session_id=?", (sid,)).fetchone()[0]
                for i, message in enumerate(messages, 1):
                    db.execute("INSERT INTO session_message(id,session_id,type,seq,time_created,time_updated,data) VALUES(?,?,?,?,?,?,?)",
                               (message["id"], sid, message["type"], seq + i, MS + i, MS + i, json.dumps(message)))
                db.execute("UPDATE session_v2 SET time_updated=time_updated+1 WHERE id=?", (sid,))
            return
        path = Path(path)
        rows = read_jsonl(path)
        if provider == "claude":
            parent = next(row["uuid"] for row in reversed(rows) if row.get("type") in ("user", "assistant"))
            additions = self.claude_rows(sid, self.project, [("user", CONTINUED_USER), ("assistant", CONTINUED_ANSWER)], parent)
        elif provider == "omp":
            parent = next(row["id"] for row in reversed(rows) if row.get("id"))
            additions = self.omp_rows([{"role": "user", "content": [text(CONTINUED_USER)]},
                                       {"role": "assistant", "content": [text(CONTINUED_ANSWER)]}], parent)
        else:
            additions = self.codex_rows(sid, CONTINUED_USER, CONTINUED_ANSWER, rich=False)
            ordinal = max((row.get("ordinal", index) for index, row in enumerate(rows)), default=-1) + 1
            for index, row in enumerate(additions):
                row["ordinal"] = ordinal + index
        with path.open("a") as stream:
            stream.write("".join(json.dumps(row) + "\n" for row in additions))

    def route(self, source, target):
        if "codex" in (source, target) and not shutil.which("codex"):
            self.skipTest("Codex native CLI is required for native registration/undo")
        if "opencode" in (source, target) and not self.opencode:
            self.skipTest("OpenCode v2 CLI is required; set C2C_OPENCODE_BINARY")
        source_id, source_path = self.fixture(source, self.project)
        decoy_id, decoy_path = self.fixture(source, self.decoy_project, rich=False)
        original = self.snapshot(source, source_id, source_path)
        decoy = self.snapshot(source, decoy_id, decoy_path)
        inventory = self.action(source, target, "inventory")
        self.assertEqual({row["sourceThreadId"] for row in inventory["threads"]}, {source_id, decoy_id})
        for option, value in [("--project", self.project), ("--project-prefix", self.root / "work")]:
            row = self.one_status(self.action(source, target, "inventory", extra=[option, value]), "available")
            self.assertEqual(row["sourceThreadId"], source_id)
        installed = self.one_status(self.action(source, target, thread=source_id), "installed")
        target_id, target_path = installed["sessionId"], Path(installed["targetPath"])
        self.assertEqual(target_id, expected_id(source, target, source_id))
        self.assert_fidelity(target, target_id, target_path)
        self.one_status(self.action(source, target, "verify", thread=source_id), "verified")
        unchanged = self.one_status(self.action(source, target, thread=source_id), "unchanged")
        self.assertEqual(unchanged["sessionId"], target_id)
        self.assertFalse(unchanged["sourceChanged"])
        # No opposite journal is supplied: portability depends on native marker.
        skipped = self.one_status(self.action(target, source, thread=target_id), "already-origin")
        self.assertEqual(skipped["originalThreadId"], source_id)
        undone = self.one_status(self.action(source, target, "undo", thread=source_id), "undone")
        self.assertFalse(target_path.exists())
        self.assertTrue(Path(undone["retainedPath"]).is_file())
        if target == "opencode":
            with database(self.homes[target] / "opencode.db") as db:
                self.assertEqual(db.execute("SELECT COUNT(*) FROM session_v2 WHERE id=?", (target_id,)).fetchone()[0], 0)
        # A crash may occur after native deletion but before the undo journal
        # is finalized. Recovery must verify absence and finish idempotently.
        manifest_path = self.root / "journals" / f"{source}-to-{target}" / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["imports"][source_id]["status"] = "undoing"
        manifest["imports"][source_id].pop("undoneAt", None)
        manifest_path.write_text(json.dumps(manifest))
        self.one_status(self.action(source, target, "verify", thread=source_id), "undone")
        self.one_status(self.action(source, target, thread=source_id), "installed")
        self.append_continuation(target, target_id, target_path)
        self.one_status(self.action(source, target, "verify", thread=source_id), "continued")
        self.one_status(self.action(source, target, "undo", thread=source_id), "preserved")
        returned = self.one_status(self.action(target, source, thread=target_id), "installed")
        self.assertNotEqual(returned["sessionId"], source_id)
        self.assert_fidelity(source, returned["sessionId"], returned["targetPath"], continued=True)
        self.one_status(self.action(target, source, "undo", thread=target_id), "undone")
        self.assertEqual(self.snapshot(source, source_id, source_path), original, "Original source must stay untouched")
        self.assertEqual(self.snapshot(source, decoy_id, decoy_path), decoy, "Unselected source must stay untouched")
        self.assert_fidelity(target, target_id, target_path, continued=True)


def matrix_case(source, target):
    def test(self):
        self.route(source, target)
    test.__name__ = f"test_{source}_to_{target}"
    return test


for _source, _target in itertools.permutations(PROVIDERS, 2):
    setattr(ProviderMatrixTests, f"test_{_source}_to_{_target}", matrix_case(_source, _target))


if __name__ == "__main__":
    unittest.main()
