# Usage reference

## Compatibility

| Provider | Home option and default | Storage / registration |
| --- | --- | --- |
| Codex | `--codex-home`: `CODEX_HOME` or `~/.codex` | SQLite metadata and rollout JSONL; registration through app-server and `migrate-rollouts` |
| Claude Code | `--claude-home`: `CLAUDE_CONFIG_DIR` or `~/.claude` | JSONL under `projects/<encoded-cwd>/` |
| Oh My Pi | `--omp-home`: `PI_CODING_AGENT_DIR` or `~/.omp/agent` | Version 3 JSONL under `sessions/<project-bucket>/` |
| OpenCode | `--opencode-home`: `$XDG_DATA_HOME/opencode` or `~/.local/share/opencode` | Version 2 `opencode.db`; registration through standalone session import |

Resume and return-trip tests cover Codex CLI 0.159.2, Claude Code 2.1.289,
Oh My Pi 18.6.1, and OpenCode 2.0.23. OpenCode schemas older than v2 are rejected.
Its selected home must contain `opencode.db`; custom `OPENCODE_DB` filenames
are unsupported.

Resume from the original project directory:

```sh
cd /path/to/project
codex resume
# Or:
claude --resume
```

Claude's resume picker filters by project; select all projects to find other
folders. For a specific import, use the destination `sessionId` from
`c2c list --from SOURCE --to DESTINATION --json` with the agent's session selector.

## Selection

```sh
c2c migrate --from codex --to claude --project /home/me/project
c2c migrate --from claude --to codex --project-prefix /home/me/projects
c2c migrate --from codex --to omp --thread SOURCE_THREAD_ID
c2c migrate --from claude --to opencode --no-images
```

`--project` matches the original working directory exactly; `--project-prefix`
also matches descendants. Both flags and `--thread` are repeatable.

Codex discovery includes main, forked, archived, and subagent threads. Claude
background subagents require `--include-subagents`. Empty threads are recorded
as `metadata-only` and do not create destination chats.

## Journals and return trips

The default journal directory is `~/.local/share/c2c/<from>-to-<to>`.
`--output-dir` sets the directory without appending the route. Existing
Codex-to-Claude journals at `~/.local/share/codex-to-claude` are reused.
Use separate journals for each route and when changing provider homes.

Origin metadata and journals identify previous imports. Unchanged return trips
are skipped; continued chats can import as a new branch. Existing imports are
never overwritten. Later source changes are reported as `sourceChanged`.
Use `--origin-manifest /path/to/manifest.json` to identify imports made with a
custom journal.

The manifest records source and destination IDs, parent relationships, hashes,
warnings, and installation state. Staging files and undo backups are retained
for recovery, so imports need space for these copies as well as the destination
history and indexes.

## Storage and recovery

Source files are read-only; SQLite reads use WAL-aware snapshots. Selected
conversations are staged and validated before installation. Destination files
are created exclusively. Indexed providers register imports through native
commands; c2c does not write their SQLite tables directly.

Files created by c2c use mode `0600`, and new private directories use `0700`.
Native agent commands set permissions on their own databases and indexes.

If a source changes during conversion, rerun after it is idle. Other stable
threads can finish. Malformed complete records fail conversion. An incomplete
final record produces a warning; complete preceding records are retained.

## Fidelity and privacy

- Messages retain roles, order, and timestamps. Tool calls and results remain
  completed pairs where supported. Unsupported artifacts become historical
  text; past tool calls are not executed.
- Local PNG/JPEG/GIF/WebP images up to 5 MB can be embedded for Claude. Stored
  image bytes can recover missing Codex screenshots when attachment mappings
  are unambiguous. Missing, ambiguous, unsupported, or oversized attachments
  keep references and produce warnings. Provider-only file IDs cannot be
  resolved without their original service.
- Remote URLs remain references. `--no-images` skips embedding image bytes.
- Readable summaries become native compaction checkpoints where supported.
  Encrypted Codex compaction state, hidden reasoning, and runtime
  system/developer instructions do not transfer.
- Large histories use recent transcript excerpts as continuation context, with
  references to the full transcript retained in a native file or archive.
  Large entries may also be excerpted. The destination may initially show
  only the recent tail.
- Tools, MCP servers, hooks, skills, permissions, authentication, running
  processes, and model settings do not transfer. Configure the destination
  separately. Project files and instructions stay in place.
- Return trips follow the current conversation branch, excluding internal
  retries and abandoned edits.

## Verify and undo

```sh
c2c verify --from codex --to claude --json
c2c undo --from codex --to claude --thread SOURCE_THREAD_ID
c2c undo --from claude --to codex --thread SOURCE_SESSION_ID
```

Verification checks native structure and installation hashes. Changed imports
are reported as `continued` and cannot be undone. Undo removes only unchanged
imports, retains a backup, and never deletes the source. Indexed providers use
native removal commands. Close the destination conversation before undoing it.
Backup paths stay in the journal across reimports.

References: [Claude sessions](https://code.claude.com/docs/en/sessions),
[Claude CLI](https://code.claude.com/docs/en/cli-reference),
[Codex app-server](https://developers.openai.com/codex/app-server),
[OMP session format](https://github.com/can1357/oh-my-pi/blob/main/docs/session.md),
[OpenCode v2 CLI](https://opencode.ai/v2/docs/cli/commands/).
