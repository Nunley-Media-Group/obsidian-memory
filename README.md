# obsidian-memory marketplace

A small [Claude Code](https://claude.com/claude-code) plugin marketplace focused on making Claude Code's memory persistent and browseable in Obsidian.

## Installing the marketplace

```bash
claude plugin marketplace add https://github.com/nunleymediagroup/obsidian-memory
claude plugin install obsidian-memory
```

Then, once per machine:

```
/obsidian-memory:setup /absolute/path/to/your/vault
```

## Plugins

### obsidian-memory

Automatic, Obsidian-backed cross-session memory for every project on the machine.

**Hooks** (registered at user scope; run on every Claude Code session, every project):

- **`UserPromptSubmit` → `vault-rag.sh`** — before Claude sees your prompt, keyword-searches your vault and injects the top-matching notes wrapped in a `<vault-context>` block.
- **`SessionEnd` → `vault-distill.sh`** — reads the just-ended session transcript, calls `claude -p` in a nested subprocess to produce a concise Obsidian note (Summary / Decisions / Patterns & Gotchas / Open Threads / Tags), writes it under `<vault>/claude-memory/sessions/<project-slug>/YYYY-MM-DD-HHMMSS.md`, and links it from `<vault>/claude-memory/Index.md`.

**Skills**:

- **`/obsidian-memory:setup <vault-path>`** — idempotent one-time setup. Writes `~/.claude/obsidian-memory/config.json`, creates `<vault>/claude-memory/sessions/`, symlinks `<vault>/claude-memory/projects → ~/.claude/projects` so every project's raw auto-memory JSONLs are browsable in Obsidian, initializes `Index.md`, and optionally registers the [Obsidian Claude Code MCP server](https://github.com/iansinnott/obsidian-claude-code-mcp) at user scope. Safe to re-run.
- **`/obsidian-memory:distill-session`** — manual counterpart to the `SessionEnd` hook. Locates the newest JSONL transcript under `~/.claude/projects/` and distills it on demand for mid-session checkpoints.

**Dependencies**: `jq` and the `claude` CLI are required. `ripgrep` (`rg`) is used when available; the RAG hook falls back to POSIX `grep -r` / `find` when it's not — so the hook works on systems where `rg` is only an editor-embedded wrapper and not on PATH in hook subshells.

**Safety**: every hook script exits 0 on any missing dep, missing config, disabled flag, or empty input. A broken hook must never block the user.

**Retrieval quality**: v0.1 uses keyword matching over `*.md` files, excluding `claude-memory/projects/**` (the auto-memory symlink), `.obsidian/**`, and `.trash/**`. The `claude-memory/projects` exclusion prevents a feedback loop where injected `<vault-context>` bodies would otherwise be re-indexed from next session's transcripts. Embeddings can be added as a one-script swap later without touching the hook wiring.

**Disabling**: set either `rag.enabled` or `distill.enabled` to `false` in `~/.claude/obsidian-memory/config.json` to turn off the corresponding hook.

## Repo layout

```
.claude-plugin/marketplace.json     # plugin registry
plugins/obsidian-memory/
  .claude-plugin/plugin.json
  hooks/hooks.json
  scripts/vault-rag.sh
  scripts/vault-distill.sh
  skills/setup/SKILL.md
  skills/distill-session/SKILL.md
```
