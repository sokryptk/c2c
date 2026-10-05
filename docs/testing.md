# Testing

Run commands from the repository root. Python harnesses require Python 3.11 or
newer; Zig process tests require `python3` on `PATH`.

```sh
zig build test
zig build -Doptimize=ReleaseSafe
python3 tests/release_smoke.py ./zig-out/bin/c2c
```

The release workflow builds on Linux x86_64 and ARM64, then tests an extracted
archive by importing, verifying, and undoing a synthetic conversation. Manual
workflow runs build artifacts; version tags also publish a GitHub Release.

## Native integration tests

These suites exercise the compiled CLI with temporary agent homes and loopback
model servers. Install the required agent runtimes before enabling them.

| Suite | Required runtimes | Coverage |
| --- | --- | --- |
| `test_zig_integration.py` | Codex, Claude Code | Native discovery, continuation, and round trips |
| `test_omp_integration.py` | Bun, Oh My Pi npm source distribution | OMP discovery, continuation, and compaction |
| `test_opencode_integration.py` | OpenCode v2, Codex, Claude Code | OpenCode import, continuation, and undo |
| `test_provider_matrix.py` | Codex, OpenCode v2 | All 12 routes, selection, provenance, and undo recovery |

```sh
RUN_C2C_INTEGRATION=1 python3 -m unittest discover -s tests -p test_zig_integration.py -v
RUN_OMP_INTEGRATION=1 python3 -m unittest discover -s tests -p test_omp_integration.py -v
RUN_OPENCODE_INTEGRATION=1 python3 -m unittest discover -s tests -p test_opencode_integration.py -v
RUN_PROVIDER_MATRIX=1 python3 -m unittest discover -s tests -p test_provider_matrix.py -v
```

The matrix uses hand-authored native records and appends fixture continuations
directly. The other suites exercise continuation through each agent's CLI.

Executable overrides:

| Variable | Default |
| --- | --- |
| `C2C_BINARY` | `zig-out/bin/c2c` |
| `CODEX_BINARY` | `codex` on `PATH` |
| `CLAUDE_BINARY` | `claude` on `PATH` |
| `C2C_OPENCODE_BINARY` | `opencode` on `PATH` |
| `BUN_BINARY` | `bun` on `PATH` |
| `OMP_BINARY` | `omp` on `PATH` |
| `OMP_PACKAGE_DIR` | npm package directory inferred from `OMP_BINARY` |

`CODEX_BINARY` selects the harness executable. Native c2c registration still
requires `codex` on `PATH`, including in the provider matrix.

Install OMP and Bun into a private directory:

```sh
npm install --prefix /tmp/c2c-omp-runtime bun @oh-my-pi/pi-coding-agent
RUN_OMP_INTEGRATION=1 \
  BUN_BINARY=/tmp/c2c-omp-runtime/node_modules/.bin/bun \
  OMP_BINARY=/tmp/c2c-omp-runtime/node_modules/.bin/omp \
  python3 -m unittest discover -s tests -p test_omp_integration.py -v
```

The OMP reader checks need `src/session/session-manager.ts` from its npm package.
Use `OMP_PACKAGE_DIR` if the harness cannot infer that directory. If npm skips
Bun's install script, run `node install.js` from
`/tmp/c2c-omp-runtime/node_modules/bun`. This setup was verified with OMP 18.6.1
and Bun 1.4.2.

## Python reference tests

The [reference engine](../tests/reference/README.md) has separate regression
suites:

```sh
PYTHONPATH=tests python3 -m unittest test_cli test_source test_native test_claude_source test_codex_native -v
RUN_CLAUDE_INTEGRATION=1 python3 -m unittest discover -s tests -p test_claude_integration.py -v
RUN_CODEX_INTEGRATION=1 python3 -m unittest discover -s tests -p test_codex_integration.py -v
```

The last two commands use the installed Claude Code and Codex CLIs respectively;
`CLAUDE_BINARY` and `CODEX_BINARY` can select private installations. The Claude
picker test requires a POSIX terminal.

For SDK reader checks, install `claude-agent-sdk` in a Python virtual environment.
It also provides a corpus check for an existing Claude configuration directory:

```sh
python3 tests/test_claude_integration.py --verify-config /path/to/claude-config
```
