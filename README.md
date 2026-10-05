# c2c

Move a coding conversation to another agent and continue it there.

c2c converts saved chats between **Codex, Claude Code, Oh My Pi, and OpenCode**.
Imported conversations appear in the destination agent's session history, with
their messages, tool history, and available images. All 12 directions are
supported.

It runs locally, keeps the originals, and never calls a model during migration.
Each import is an independent conversation; later replies stay with the agent
where you write them. Claude support means Claude Code, rather than the Claude
website or desktop app.

## Build and install

Build on **Linux** with **Zig 0.16.0**, a C toolchain, and SQLite development
headers/library. The binary links libc and SQLite. Python is only used by tests.

```sh
zig build -Doptimize=ReleaseSafe
./c2c --help
```

The checkout's `c2c` and `codex-to-claude` entry points are relative symlinks to
`zig-out/bin/c2c`; build before using either. Install the native executable into a
chosen prefix:

```sh
zig build -Doptimize=ReleaseSafe --prefix "$HOME/.local"
~/.local/bin/c2c --help
```

Put `~/.local/bin` on `PATH` to invoke it as `c2c`. Importing into Codex also
requires `codex` on `PATH` for native registration. OpenCode imports require the
supported OpenCode CLI; `C2C_OPENCODE_BINARY` can select its executable. Install
the destination agent separately to resume an imported conversation.

## Move a conversation

Inspect the available conversations, import them, then verify the result:

```sh
./c2c inventory --from codex --to claude
./c2c migrate --from codex --to claude
./c2c verify --from codex --to claude --json
```

Open Claude Code from your project's directory and run `claude --resume`.
Use `--project /path/to/project` or `--thread SOURCE_ID` on the commands above
to select a smaller set of conversations.

The provider names are `codex`, `claude`, `omp`, and `opencode`. Choose any two:

```sh
./c2c migrate --from claude --to codex
./c2c migrate --from omp --to opencode --project /path/to/project
./c2c list --from omp --to opencode --json
```

`migrate` is the default when a route is supplied. Direction aliases such as
`c2c codex-to-claude` and `c2c claude-to-codex inventory` also work.

## Compatibility

Provider contracts and default storage locations:

| Provider | Home option and default | Native storage / registration |
| --- | --- | --- |
| Codex | `--codex-home`, using `CODEX_HOME` or `~/.codex` | SQLite metadata and rollout JSONL; destination registration through Codex app-server and `migrate-rollouts` |
| Claude Code | `--claude-home`, using `CLAUDE_CONFIG_DIR` or `~/.claude` | Conversation JSONL under `projects/<encoded-cwd>/` |
| Oh My Pi | `--omp-home`, using `PI_CODING_AGENT_DIR` or `~/.omp/agent` | Version 3 session JSONL under `sessions/<project-bucket>/` |
| OpenCode | `--opencode-home`, using `$XDG_DATA_HOME/opencode` or `~/.local/share/opencode` | Version 2 SQLite session/message records in `opencode.db`; destination registration through native standalone session import |

Native resume tests pass against **Codex CLI 0.159.2**, **Claude Code 2.1.289**,
**Oh My Pi 18.6.1**, and **OpenCode 2.0.23**. These include new replies saved by
the destination agent and migrated back. OpenCode support targets the v2
schema; older schemas are rejected. A custom `OPENCODE_DB` filename is not
supported: the selected OpenCode home must contain `opencode.db`.

Open the destination agent from the original project directory after importing.
For Codex or Claude:

```sh
cd /path/to/project
codex resume
# Or:
claude --resume
```

Claude's resume picker can filter by project; select all projects to find imports
from other folders. Use the destination `sessionId` from `list --json` to resume
a specific conversation with the destination's native session selector.

## Selection, provenance, and storage

```sh
./c2c migrate --from codex --to claude --project /home/me/project
./c2c migrate --from claude --to codex --project-prefix /home/me/projects
./c2c migrate --from codex --to omp --thread SOURCE_THREAD_ID
./c2c migrate --from claude --to opencode --no-images
```

`--project` matches an exact original working directory; `--project-prefix` also
matches descendants. Both are repeatable, as is `--thread`. Codex discovery
includes main, forked, archived, and subagent threads. Claude background
subagents are excluded unless `--include-subagents` is supplied. Empty threads
are reported as `metadata-only` rather than creating empty destination chats.

Provenance prevents circular copying. An unchanged import is skipped when moved
back to its source provider. A continued import can become a new destination
branch, preserving the original. Embedded origin metadata and migration journals
identify imports. Supply `--origin-manifest /path/to/manifest.json` when the
original migration used a custom journal. Existing destinations are never
overwritten; later source changes are reported as `sourceChanged`.

The default journal directory is `~/.local/share/c2c/<from>-to-<to>`.
`--output-dir` overrides it literally. Existing Codex-to-Claude journals at
`~/.local/share/codex-to-claude` are reused automatically. Each route has a
separate journal; choose a new output directory when changing provider homes.

Source files open read-only, and SQLite reads use WAL-aware snapshots. Selected
conversations are staged and validated before installation. Destination files
are created exclusively, and providers that require an index are registered
through native commands. The importer does not write SQLite tables directly.

The private manifest records source IDs, parent relationships, hashes,
destination IDs, warnings, and installation state. Files written directly by
c2c are `0600`; its new private directories are `0700`. Native agent commands
manage the permissions of their own databases and indexes. Staging is retained
for recovery alongside the imported history, indexes, and any undo backups.
Allow space for those copies. A source changing during conversion is
retryable; stable threads can finish. Rerun after the source is idle. Malformed
complete records fail conversion; an incomplete final record from an active
writer produces a warning while retaining complete prior records.

## Fidelity and privacy limits

- Visible messages retain roles, order, and timestamps. Historical tool calls
  and results remain completed pairs where the destination format supports
  them. Unsupported artifacts remain explicit historical text; importing never
  executes a past tool call.
- Available local PNG/JPEG/GIF/WebP images up to 5 MB can be embedded for Claude.
  Historical image bytes can recover vanished Codex screenshots when their
  attachment mapping is unambiguous. Missing, ambiguous, unsupported, or
  oversized attachments retain references and produce warnings. Provider-only
  file IDs cannot be recovered without their original service.
- Remote URLs remain references and are not fetched. `--no-images` preserves
  references without embedding image bytes.
- Readable summaries become native compaction checkpoints where supported.
  **Encrypted Codex compaction state cannot transfer.** Hidden reasoning and
  runtime system/developer instructions are not exported. Provider-private
  state is not portable conversation history.
- Oversized histories receive bounded continuation context. The converted
  visible transcript remains available in its native file or retained archive,
  while active context contains a recent tail and a reference to older history.
  Oversized entries can be explicitly excerpted in active context. This is an
  extractive checkpoint, not an invented semantic summary; the initial visible
  or active segment may be the recent tail.
- Tools, MCP servers, hooks, skills, permissions, authentication, running
  processes, and model settings are not transplanted. Configure destination
  capabilities separately; existing project files and instructions stay in
  place.
- Return trips follow the current conversation branch. Internal retries and
  abandoned edits are not inserted as new messages.

## Verify and undo

```sh
./c2c verify --from codex --to claude --json
./c2c undo --from codex --to claude --thread SOURCE_THREAD_ID
./c2c undo --from claude --to codex --thread SOURCE_SESSION_ID
```

Verification checks native structure and recorded installation hashes. Changes
to an imported destination are reported as `continued`; they are never
overwritten or removed. Undo removes only an unchanged import and retains a
backup. It never deletes the source. Indexed providers use native removal so
their indexes remain consistent. Close the destination conversation before
undoing it. Backup paths remain in the journal, including across reimports.

## Development and tests

The implementation is in `zig/`. Each agent has its own reader and writer;
`cli.zig` handles selection, staging, registration, and the migration journal.
`os.zig` contains filesystem and process operations.

Build and run native tests with Python 3 available on `PATH` for process fixtures:

```sh
zig build test
zig build -Doptimize=ReleaseSafe
```

The compiled-binary integration harnesses use isolated configuration, synthetic
conversations, fake credentials, and loopback model servers:

```sh
RUN_C2C_INTEGRATION=1 python3 -m unittest discover -s tests -p test_zig_integration.py -v
RUN_OMP_INTEGRATION=1 python3 -m unittest discover -s tests -p test_omp_integration.py -v
RUN_OPENCODE_INTEGRATION=1 python3 -m unittest discover -s tests -p test_opencode_integration.py -v
RUN_PROVIDER_MATRIX=1 python3 -m unittest discover -s tests -p test_provider_matrix.py -v
```

They check native discovery, resumed history, saved continuations, completed tool
pairs, and bounded compaction without sending personal conversations to a model.
The matrix covers all 12 directed provider pairs, including unchanged return
trips, continued chats, scoped selection, and undo recovery.
OMP tests require Bun and Oh My Pi; OpenCode tests require OpenCode v2, Codex,
and Claude Code. Each test module documents executable overrides for private
installations.
Python is a development test dependency only. The older Codex/Claude proof
engine lives in [`tests/reference`](tests/reference/README.md), is not installed,
and is never invoked by the native executable or checkout launchers. Its
regression tests remain available for behavioral comparisons.

References: [Claude sessions](https://code.claude.com/docs/en/sessions),
[Claude CLI](https://code.claude.com/docs/en/cli-reference),
[Codex app-server](https://developers.openai.com/codex/app-server),
[OMP session format](https://github.com/can1357/oh-my-pi/blob/main/docs/session.md),
[OpenCode v2 CLI](https://opencode.ai/v2/docs/cli/commands/).
