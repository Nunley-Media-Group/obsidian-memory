# obsidian-memory

A [Claude Code](https://claude.com/claude-code) plugin that makes Claude's memory persistent and browseable in Obsidian.

## Installing

Install via any marketplace that references this repo, then once per machine:

```
/obsidian-memory:setup /absolute/path/to/your/vault
```

## What it does

**Hooks** (registered at user scope; run on every Claude Code session, every project):

- **`UserPromptSubmit` → `vault-rag.sh`** — before Claude sees your prompt, keyword-searches your vault and injects the top-matching notes wrapped in a `<vault-context>` block.
- **`SessionEnd` → `vault-distill.sh`** — reads the just-ended session transcript, calls `claude -p` in a nested subprocess to produce a concise Obsidian note (Summary / Decisions / Patterns & Gotchas / Open Threads / Tags), writes it under `<vault>/claude-memory/sessions/<project-slug>/YYYY-MM-DD-HHMMSS.md`, and links it from `<vault>/claude-memory/Index.md`.

**Skills**:

- **`/obsidian-memory:setup <vault-path>`** — idempotent one-time setup. Writes `~/.claude/obsidian-memory/config.json`, creates `<vault>/claude-memory/sessions/`, symlinks `<vault>/claude-memory/projects → ~/.claude/projects` so every project's raw auto-memory JSONLs are browsable in Obsidian, initializes `Index.md`, and optionally registers the [Obsidian Claude Code MCP server](https://github.com/iansinnott/obsidian-claude-code-mcp) at user scope. Safe to re-run.
- **`/obsidian-memory:distill-session`** — manual counterpart to the `SessionEnd` hook. Locates the newest JSONL transcript under `~/.claude/projects/` and distills it on demand for mid-session checkpoints.

**Dependencies**: `jq` and the `claude` CLI are required. `ripgrep` (`rg`) is used when available; the RAG hook falls back to POSIX `grep` / `find` when it's not.

**Safety**: every hook script exits 0 on any missing dep, missing config, disabled flag, or empty input. A broken hook must never block the user.

**Retrieval quality**: v0.1 uses single-pass keyword matching over `*.md` files, excluding `.obsidian/**` and `.trash/**`. Raw `.jsonl` transcripts under the `claude-memory/projects/` symlink are excluded implicitly by the `*.md` glob, which prevents a feedback loop where injected `<vault-context>` bodies would otherwise be re-indexed from next session's transcripts. Embeddings can be added as a one-script swap later without touching the hook wiring.

**Disabling**: set either `rag.enabled` or `distill.enabled` to `false` in `~/.claude/obsidian-memory/config.json` to turn off the corresponding hook.

## Repo layout

```
.claude-plugin/plugin.json
hooks/hooks.json
scripts/_common.sh
scripts/vault-rag.sh
scripts/vault-distill.sh
skills/setup/SKILL.md
skills/distill-session/SKILL.md
```

## Development

Install the test toolchain once per machine:

```bash
# macOS (Homebrew)
brew install bats-core shellcheck jq

# Linux (Debian/Ubuntu)
sudo apt install bats shellcheck jq

# Linux (any distro, manual)
git clone https://github.com/bats-core/bats-core.git && cd bats-core && ./install.sh /usr/local
# shellcheck: https://github.com/koalaman/shellcheck/releases (precompiled binary)
# jq:         https://stedolan.github.io/jq/download/
```

`cucumber-shell` is hand-rolled in this repo as `tests/run-bdd.sh` — no external
install step. The runner supports the Gherkin subset used by
`specs/*/feature.gherkin` (Feature, Background, Scenario, Given/When/Then/And/But,
quoted-literal arguments, `#` line comments).

Run the Verification Gates documented in [`steering/tech.md`](steering/tech.md#verification-gates):

```bash
bats tests/unit                                              # unit gate
bats tests/integration                                       # integration gate
tests/run-bdd.sh                                             # BDD gate (cucumber-shell)
shellcheck scripts/*.sh tests/**/*.sh                        # static-analysis gate
jq empty .claude-plugin/plugin.json hooks/hooks.json          # JSON-validity gate
```

Expected output: `ok N passing` / `NN scenarios, NN passed, 0 failed, 0 undefined steps`,
non-zero exit on any failure. `steering/tech.md` §Verification Gates is the
authoritative source of each gate's command string — `tests/run-bdd.sh` and
`tests/integration/gate_sweep.bats` mirror it byte-for-byte.

Safety: every test runs under a scratch `$HOME` and scratch vault via
`tests/helpers/scratch.bash`. An `assert_home_untouched` backstop in the helper
digests `$HOME/.claude` before each integration test and fails the test if the
real state changed during the run.

## Referencing from a marketplace

A separate marketplace repo points at this repo's root via a GitHub source:

```json
{
  "name": "obsidian-memory",
  "source": { "source": "github", "repo": "Nunley-Media-Group/obsidian-memory" }
}
```
