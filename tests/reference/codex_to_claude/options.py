from __future__ import annotations

import argparse
import os
from pathlib import Path

DIRECTIONS = ("codex-to-claude", "claude-to-codex")


def _direction(options) -> str:
    return getattr(options, "direction", DIRECTIONS[0])


def _shared(parser, suppress=False) -> None:
    def default(value):
        return argparse.SUPPRESS if suppress else value

    parser.add_argument("--codex-home", type=Path, default=default(Path.home() / ".codex"))
    parser.add_argument(
        "--claude-home",
        type=Path,
        default=default(Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude")))),
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=default(None),
        help="private staging and migration manifest directory",
    )
    parser.add_argument("--direction", choices=DIRECTIONS, default=default(DIRECTIONS[0]))
    parser.add_argument(
        "--origin-manifest",
        type=Path,
        action="append",
        default=default([]),
        help="opposite-direction manifest for detecting round trips; repeatable",
    )
    parser.add_argument(
        "--include-subagents",
        action="store_true",
        default=default(False),
        help="include Claude subagent sessions",
    )
    parser.add_argument(
        "--project",
        action="append",
        default=default([]),
        help="filter by exact project cwd; repeatable",
    )
    parser.add_argument(
        "--project-prefix",
        action="append",
        default=default([]),
        help="filter by project cwd and descendants; repeatable",
    )
    parser.add_argument(
        "--thread",
        action="append",
        default=default([]),
        help="filter by source thread ID; repeatable",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        default=default(False),
        help="write machine-readable summary to stdout",
    )


def parse_options(argv=None):
    parser = argparse.ArgumentParser(
        prog="c2c", description="Move conversations between native Codex and Claude Code sessions."
    )
    _shared(parser)
    commands = parser.add_subparsers(dest="command", required=True)
    for name, help_text in (
        ("inventory", "discover source threads"),
        ("migrate", "stage and install native sessions without overwriting"),
        ("verify", "validate imported sessions and detect continuations"),
        ("list", "list recorded imports"),
        ("undo", "remove imports only when they have not changed"),
    ):
        subparser = commands.add_parser(name, help=help_text)
        _shared(subparser, suppress=True)
        if name == "migrate":
            subparser.add_argument(
                "--no-images",
                action="store_true",
                help="preserve image references without embedding image bytes",
            )
    for direction in DIRECTIONS:
        subparser = commands.add_parser(
            direction, help="migrate in this direction; optionally choose another action"
        )
        _shared(subparser, suppress=True)
        subparser.add_argument(
            "action",
            nargs="?",
            choices=("inventory", "migrate", "verify", "list", "undo"),
            default="migrate",
        )
        subparser.add_argument(
            "--no-images",
            action="store_true",
            help="preserve image references without embedding image bytes",
        )
    options = parser.parse_args(argv)
    if options.command in DIRECTIONS:
        options.direction = options.command
        options.command = options.action
    if options.output_dir is None:
        legacy = Path.home() / ".local" / "share" / "codex-to-claude"
        options.output_dir = (
            legacy
            if options.direction == "codex-to-claude" and (legacy / "manifest.json").exists()
            else Path.home() / ".local" / "share" / "c2c" / options.direction
        )
    for field in ("codex_home", "claude_home", "output_dir"):
        setattr(options, field, getattr(options, field).expanduser().resolve())
    return options
