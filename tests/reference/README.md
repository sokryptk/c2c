# Development reference engine

`codex_to_claude/` contains the original Python Codex/Claude proof engine. It is
retained to compare historical conversion behavior and run its regression
fixtures while the native implementation evolves.

The shipped implementation is the Zig executable built from `zig/`. The root
`c2c` and `codex-to-claude` launchers point to that executable. There is no Python
package installation or console-script entry point, and the executable does not
load this reference code. This reference predates the four-provider native CLI;
it is not the implementation or compatibility contract for OMP or OpenCode.

Run the reference unit suites from the repository root:

```sh
PYTHONPATH=tests python3 -m unittest test_cli test_source test_native test_claude_source test_codex_native -v
```

These test modules explicitly add `tests/reference` to their import path. Python
3.11 or newer is needed only for development. Two older opt-in native CLI
harnesses also use the reference converters:

```sh
RUN_CLAUDE_INTEGRATION=1 python3 -m unittest discover -s tests -p test_claude_integration.py -v
RUN_CODEX_INTEGRATION=1 python3 -m unittest discover -s tests -p test_codex_integration.py -v
```

For validation of the actual Zig executable, use `zig build test` and
`tests/test_zig_integration.py` as documented in the repository README. Reference
unit test success does not establish correctness of the shipped binary.

The optional Claude SDK corpus reader remains available with
`claude-agent-sdk` installed in a development environment:

```sh
python3 tests/test_claude_integration.py --verify-config /path/to/claude-config
```
