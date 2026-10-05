from __future__ import annotations

import base64
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent / "reference"))

from codex_to_claude.native import MAX_ACTIVE_BYTES, convert, project_directory, validate
from codex_to_claude.source import Compaction, Item, Thread


TIMESTAMP = "2026-10-06T00:00:00.000Z"
# 1x1 PNG.
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j3ioAAAAASUVORK5CYII=")


def active_chain(entries):
    by_id = {entry["uuid"]: entry for entry in entries if "uuid" in entry}
    current = next(entry for entry in reversed(entries) if entry.get("type") in ("user", "assistant"))
    chain = []
    while current:
        chain.append(current)
        current = by_id.get(current.get("parentUuid"))
    return list(reversed(chain))


class NativeConversionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.thread = Thread("fixture-thread-1", "A useful original title", str(self.root),
                             TIMESTAMP, TIMESTAMP, self.root / "rollout.jsonl")

    def item(self, role, text, *, kind=None, raw=None, ordinal=0, attachments=()):
        return Item(f"{role}-{ordinal}", role, text, TIMESTAMP,
                    kind or ("userMessage" if role == "user" else "agentMessage"),
                    attachments=attachments, raw=raw, ordinal=ordinal)

    def simple(self):
        return convert(self.thread, [self.item("user", "Original question"),
                                     self.item("assistant", "Original answer", ordinal=1)])

    def test_native_ids_and_title_are_stable_across_repeated_conversion(self):
        first, second = self.simple(), self.simple()
        self.assertEqual(first.entries, second.entries)
        self.assertEqual(first.session_id, second.session_id)
        self.assertEqual(first.entries[-1]["customTitle"], "Codex · A useful original title")
        self.assertEqual(validate(first.entries), [])

    def test_distinct_source_threads_cannot_share_native_ids(self):
        first = self.simple()
        other = copy.copy(self.thread)
        object.__setattr__(other, "id", "fixture-thread-2")
        second = convert(other, [self.item("user", "Original question")])
        self.assertNotEqual(first.session_id, second.session_id)
        self.assertTrue({e["uuid"] for e in first.entries if "uuid" in e}.isdisjoint(
            {e["uuid"] for e in second.entries if "uuid" in e}))

    def test_command_and_unknown_mcp_results_are_complete_tool_pairs(self):
        result = convert(self.thread, [
            self.item("user", "Inspect"),
            self.item("assistant", "", kind="commandExecution", ordinal=1, raw={
                "command": "false", "aggregatedOutput": "original stdout", "status": "failed", "exitCode": 1}),
            self.item("assistant", "", kind="mcpToolCall", ordinal=2, raw={
                "server": "old.server", "tool": "lookup/item", "arguments": {"x": 2},
                "status": "completed", "result": {"value": "original result"}}),
        ])
        messages = [e for e in result.entries if "message" in e]
        self.assertEqual(result.tool_count, 2)
        for call, answer in [(messages[1], messages[2]), (messages[3], messages[4])]:
            use = call["message"]["content"][0]
            response = answer["message"]["content"][0]
            self.assertEqual(call["message"]["stop_reason"], "tool_use")
            self.assertEqual(use["id"], response["tool_use_id"])
            self.assertEqual(answer["parentUuid"], call["uuid"])
        self.assertTrue(messages[2]["message"]["content"][0]["is_error"])
        self.assertEqual(messages[3]["message"]["content"][0]["name"], "mcp__old_server__lookup_item")
        self.assertIn("original result", json.dumps(result.entries))
        self.assertEqual(validate(result.entries), [])

    def test_mcp_images_preserve_bytes_and_structured_content(self):
        structured = {"calories": 123, "ingredients": ["fixture"]}
        result = convert(self.thread, [self.item("user", "Inspect"), self.item(
            "assistant", "", kind="mcpToolCall", ordinal=1, raw={
                "server": "fixture", "tool": "image", "arguments": {}, "status": "completed",
                "result": {"content": [{"type": "text", "text": "Image result"},
                    {"type": "image", "data": base64.b64encode(PNG).decode(), "mimeType": "image/png"}],
                    "structuredContent": structured, "isError": False}})])
        blocks = result.entries[2]["message"]["content"][0]["content"]
        image = next(block for block in blocks if block["type"] == "image")
        self.assertEqual(base64.b64decode(image["source"]["data"]), PNG)
        metadata = json.loads(blocks[-1]["text"])
        self.assertEqual(metadata["structuredContent"], structured)
        self.assertIs(metadata["isError"], False)

    def test_many_small_image_excerpts_include_native_envelope_in_context_budget(self):
        # Excerpts shrink image data, but each native message envelope still counts.
        encoded = base64.b64encode(PNG + b"\0" * 21_000).decode()
        items = [self.item("user", "Synthetic image archive")]
        for ordinal in range(1, 901):
            items.append(self.item("assistant", "", kind="mcpToolCall", ordinal=ordinal, raw={
                "server": "fixture", "tool": "image", "arguments": {}, "status": "completed",
                "result": {"content": [{"type": "image", "data": encoded, "mimeType": "image/png"}]}}))
        result = convert(self.thread, items, Compaction("s" * 40_000, (), TIMESTAMP, -1))
        active = active_chain(result.entries)
        actual_bytes = sum(len(json.dumps(entry.get("message", {}), ensure_ascii=False).encode())
                           for entry in active)
        self.assertLessEqual(actual_bytes, MAX_ACTIVE_BYTES)
        originals = [entry for entry in result.entries if entry.get("type") == "user"
                     and isinstance(entry.get("message", {}).get("content"), list)]
        self.assertEqual(sum(1 for entry in originals for block in entry["message"]["content"]
                             if block.get("type") == "tool_result"), 900)

    def test_unfinished_process_is_historical_not_left_as_live_tool_call(self):
        result = convert(self.thread, [self.item("user", "Run"), self.item(
            "assistant", "", kind="commandExecution", ordinal=1,
            raw={"command": "synthetic-command", "status": "inProgress"})])
        self.assertEqual(validate(result.entries), [])
        self.assertIn("not resumed or executed", json.dumps(result.entries))

    def test_hidden_reasoning_and_runtime_instruction_records_are_excluded(self):
        items = [self.item("user", "Visible request")]
        for number, kind in enumerate(("reasoning", "system", "developer", "hookPrompt"), 1):
            items.append(self.item("assistant", "hidden-private-fixture", kind=kind, ordinal=number,
                                   raw={"content": "hidden-private-fixture"}))
        result = convert(self.thread, items)
        self.assertNotIn("hidden-private-fixture", json.dumps(result.entries))
        self.assertEqual(result.message_count, 1)

    def test_source_compaction_keeps_archive_but_uses_summary_and_recent_context(self):
        old = self.item("user", "Old original message", ordinal=0)
        recent = self.item("assistant", "Recent original answer", ordinal=3)
        compact = Compaction("Exact saved summary", (), TIMESTAMP, 2)
        result = convert(self.thread, [old, recent], compact)
        self.assertIn("Old original message", json.dumps(result.entries))
        active = json.dumps(active_chain(result.entries))
        self.assertNotIn("Old original message", active)
        self.assertIn("Exact saved summary", active)
        self.assertIn("Recent original answer", active)
        boundary = next(e for e in result.entries if e.get("subtype") == "compact_boundary")
        self.assertIsNone(boundary["parentUuid"])
        self.assertIsNotNone(boundary["logicalParentUuid"])
        self.assertEqual(validate(result.entries), [])

    def test_oversized_unicode_history_is_preserved_with_disclosed_bounded_context(self):
        huge = "पूर्ण मूल इतिहास " * 15000
        result = convert(self.thread, [
            self.item("user", huge),
            self.item("assistant", "Keep the full original available.", ordinal=1),
            self.item("user", "Continue my latest task.", ordinal=2),
        ], transcript_path=str(self.root / "native.jsonl"))
        first = result.entries[0]["message"]["content"][0]["text"]
        self.assertEqual(first, huge)
        active = active_chain(result.entries)
        active_bytes = sum(len(json.dumps(entry.get("message", {}), ensure_ascii=False).encode()) for entry in active)
        self.assertLess(active_bytes, MAX_ACTIVE_BYTES)
        text = json.dumps(active, ensure_ascii=False)
        self.assertIn("structural migration checkpoint", text)
        self.assertIn("abridged", text)
        self.assertIn(str(self.root / "native.jsonl"), text)
        self.assertIn("Continue my latest task.", text)
        self.assertEqual(validate(result.entries), [])

    def test_bounded_context_clones_small_tool_pairs_with_fresh_identifiers(self):
        result = convert(self.thread, [
            self.item("user", "old large history " * 20000),
            self.item("assistant", "", kind="commandExecution", ordinal=1, raw={
                "command": "echo latest-fixture", "aggregatedOutput": "latest-fixture",
                "status": "completed", "exitCode": 0}),
        ])
        uses = [block["id"] for entry in result.entries if isinstance(entry.get("message", {}).get("content"), list)
                for block in entry["message"]["content"] if block.get("type") == "tool_use"]
        self.assertEqual(len(uses), 2)
        self.assertEqual(len(set(uses)), 2)
        self.assertIn("latest-fixture", json.dumps(active_chain(result.entries)))
        self.assertEqual(validate(result.entries), [])

    def test_real_image_bytes_are_embedded_and_missing_paths_are_preserved(self):
        image = self.root / "fixture.png"
        image.write_bytes(PNG)
        absent = self.root / "missing.png"
        result = convert(self.thread, [self.item("user", "See image", attachments=(
            {"path": str(image)}, {"path": str(absent)}))])
        blocks = result.entries[0]["message"]["content"]
        embedded = next(block for block in blocks if block["type"] == "image")
        self.assertEqual(base64.b64decode(embedded["source"]["data"]), PNG)
        self.assertEqual(embedded["source"]["media_type"], "image/png")
        self.assertIn(str(absent), json.dumps(blocks))
        self.assertTrue(any("unavailable" in warning for warning in result.warnings))

    def test_no_embed_mode_keeps_attachment_reference(self):
        image = self.root / "fixture.png"
        image.write_bytes(PNG)
        result = convert(self.thread, [self.item("user", "See image", attachments=({"path": str(image)},))],
                         embed_images=False)
        blocks = result.entries[0]["message"]["content"]
        self.assertNotIn("image", [block["type"] for block in blocks])
        self.assertIn(str(image), json.dumps(blocks))

    def test_remote_images_are_references_and_not_fetched(self):
        result = convert(self.thread, [self.item("user", "See remote image", attachments=(
            {"url": "https://example.invalid/private-image.png"},))])
        self.assertIn("https://example.invalid/private-image.png", json.dumps(result.entries))
        self.assertFalse(any(b["type"] == "image" for b in result.entries[0]["message"]["content"]))

    def test_unknown_structured_artifact_keeps_exact_payload(self):
        result = convert(self.thread, [self.item("user", "Review"), self.item(
            "assistant", "", kind="futureArtifact", ordinal=1,
            raw={"preserve": {"list": [1, 2, 3], "text": "unaltered payload"}})])
        self.assertIn("unaltered payload", json.dumps(result.entries))
        self.assertIn("futureArtifact", json.dumps(result.entries))

    def test_validator_rejects_broken_parent_and_cross_session_records(self):
        entries = copy.deepcopy(self.simple().entries)
        entries[1]["parentUuid"] = "missing-parent"
        entries[1]["sessionId"] = "other-session"
        errors = validate(entries)
        self.assertTrue(any("missing parent" in error for error in errors))
        self.assertTrue(any("session ID" in error for error in errors))

    def test_validator_rejects_metadata_only_session(self):
        errors = validate([{"type": "custom-title", "sessionId": "fixture", "customTitle": "No messages"}])
        self.assertTrue(any("no conversation messages" in error for error in errors))

    def two_tools(self):
        return convert(self.thread, [self.item("user", "Check results"), *[
            self.item("assistant", "", kind="commandExecution", ordinal=index,
                      raw={"command": "echo fixture", "aggregatedOutput": "fixture", "status": "completed", "exitCode": 0})
            for index in (1, 2)
        ]]).entries

    def test_validator_rejects_reused_completed_tool_ids(self):
        entries = self.two_tools()
        first_id = entries[1]["message"]["content"][0]["id"]
        entries[3]["message"]["content"][0]["id"] = first_id
        entries[4]["message"]["content"][0]["tool_use_id"] = first_id
        self.assertTrue(validate(entries), "A completed tool ID must not be reused later in the session")

    def test_validator_rejects_text_between_tool_call_and_result(self):
        entries = self.two_tools()
        result = entries.pop(2)
        # Keep the parent chain valid so this specifically tests tool adjacency.
        intervening = copy.deepcopy(result)
        intervening.update(uuid="intervening-message", type="assistant")
        intervening["message"] = {"role": "assistant", "content": [{"type": "text", "text": "Intervening turn"}]}
        result["parentUuid"] = intervening["uuid"]
        entries[2:2] = [intervening, result]
        self.assertTrue(validate(entries), "A tool result must immediately follow its assistant tool call")

    def test_project_directory_matches_native_non_alphanumeric_encoding(self):
        self.assertEqual(project_directory("/home/me/a_project.v2"), "-home-me-a-project-v2")


if __name__ == "__main__":
    unittest.main()
