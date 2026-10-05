# c2c

Move saved conversations between Codex, Claude Code, Oh My Pi, and OpenCode.
Supports all 12 directions and writes native sessions you can resume.

c2c runs locally without model calls. Source conversations stay unchanged;
imports continue independently.

## Install

Download a binary from [Releases](https://github.com/sokryptk/c2c/releases).
The Linux builds require `libsqlite3` and glibc:

| Architecture | Minimum glibc | Build environment |
| --- | --- | --- |
| `x86_64` | 2.35 | Ubuntu 22.04 |
| `aarch64` | 2.39 | Ubuntu 24.04 |

On Ubuntu, install the runtime library with `sudo apt install libsqlite3-0`.
There are no macOS, Windows, or musl builds.

Install v0.1.0:

```sh
version=v0.1.0
arch=x86_64 # Use aarch64 for ARM64.
archive="c2c-${version}-linux-${arch}.tar.gz"
base="https://github.com/sokryptk/c2c/releases/download/${version}"

(
  set -eu
  download_dir=$(mktemp -d)
  cd "$download_dir"
  curl -fLO "$base/$archive"
  curl -fLO "$base/SHA256SUMS.txt"
  sha256sum --check --ignore-missing SHA256SUMS.txt
  tar -xzf "$archive"
  install -Dm755 c2c "$HOME/.local/bin/c2c"
)

export PATH="$HOME/.local/bin:$PATH"
c2c --help
```

The destination agent must be installed. Codex imports require `codex` on
`PATH`. OpenCode imports require OpenCode v2 on `PATH` or in `C2C_OPENCODE_BINARY`.

## Move a conversation

```sh
c2c inventory --from codex --to claude
c2c migrate --from codex --to claude --project /path/to/project
c2c verify --from codex --to claude --json

cd /path/to/project
claude --resume
```

The provider names are `codex`, `claude`, `omp`, and `opencode`. Choose any two:

```sh
c2c migrate --from claude --to codex --thread SOURCE_ID
c2c migrate --from omp --to opencode --project /path/to/project
c2c list --from omp --to opencode --json
c2c undo --from codex --to claude --thread SOURCE_ID
```

Without a selection flag, `migrate` imports all eligible source conversations.
`inventory` previews them; `list` shows recorded imports. Undo removes only
unchanged imports and retains a backup.

`migrate` is the default action when a route is supplied. Direction aliases
such as `c2c codex-to-claude` also work.

## What transfers

Visible messages, completed tool history, available images, and readable
compaction summaries transfer where the destination format supports them.
Unsupported artifacts remain historical text or references, with warnings.
Large histories use bounded continuation context while retaining the transcript.

Encrypted Codex compaction state, hidden reasoning, runtime instructions,
credentials, and tool configuration do not transfer. Remote images are not
downloaded. Claude support is for Claude Code. OpenCode support requires its
v2 schema.

See the [usage reference](docs/usage.md) for tested provider versions, storage
paths, selection, journals, and undo.

## Build from source

Requires Linux, Zig 0.16.0, a C toolchain, and SQLite development headers/library
(`build-essential libsqlite3-dev` on Ubuntu).

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/c2c --help

# Optional: install to ~/.local/bin.
zig build -Doptimize=ReleaseSafe --prefix "$HOME/.local"
```

Run `zig build test` with Python 3 on `PATH`. See [testing](docs/testing.md)
for native provider integration tests.

## License

[MIT](LICENSE). Copyright 2026 sokryptk.
