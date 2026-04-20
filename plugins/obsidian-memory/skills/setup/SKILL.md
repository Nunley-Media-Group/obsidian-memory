---
name: setup
description: One-time, idempotent setup for the obsidian-memory plugin. Writes config, links the raw auto-memory folder into the vault, and optionally wires up the Obsidian MCP server. Use when the user says "set up obsidian memory", "configure obsidian-memory", "point obsidian-memory at my vault", "install obsidian memory", "link my vault", or invokes /obsidian-memory:setup. Safe to re-run.
argument-hint: <vault-path>
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion
model: sonnet
effort: low
---

# obsidian-memory: setup

One-time, idempotent configuration for the obsidian-memory plugin. Re-running it is safe — every step either no-ops or updates in place.

## What this skill produces

1. `~/.claude/obsidian-memory/config.json` with the vault path and feature flags.
2. `<vault>/claude-memory/sessions/` (directory for distilled notes).
3. Symlink `<vault>/claude-memory/projects` → `~/.claude/projects` so every project's raw auto-memory JSONL transcripts are browsable from inside Obsidian.
4. `<vault>/claude-memory/Index.md` (session index, if absent).
5. Optional registration of the Obsidian MCP server at user scope.

## Workflow

### 1. Resolve the vault path

- If `$1` (the skill argument) is non-empty, use it.
- Otherwise call `AskUserQuestion` with "Absolute path to your Obsidian vault?".
- Expand a leading `~` to `$HOME`.
- **Verify the directory exists.** If it does not, stop and tell the user — do NOT create it. Vaults are user-owned and creating one in the wrong place is worse than erroring.

### 2. Write the config file

```bash
mkdir -p "$HOME/.claude/obsidian-memory"
```

Write `~/.claude/obsidian-memory/config.json`:

```json
{
  "vaultPath": "<expanded-vault-path>",
  "rag": { "enabled": true },
  "distill": { "enabled": true }
}
```

If the file already exists, `Read` it first and preserve any extra keys the user may have added. Only overwrite `vaultPath`.

### 3. Create the memory folder and manage the projects symlink

```bash
mkdir -p "<vault>/claude-memory/sessions"
```

Then, for `<vault>/claude-memory/projects`:

- If it does not exist → create the symlink: `ln -s "$HOME/.claude/projects" "<vault>/claude-memory/projects"`.
- If it exists and is a symlink:
  - Pointing at `~/.claude/projects` → leave it.
  - Pointing elsewhere → remove and recreate with `ln -sfn`.
- If it exists and is NOT a symlink (regular file or directory) → refuse. Print a message asking the user to move or remove it manually. Do not delete user data.

Use `test -L`, `test -e`, and `readlink` to distinguish the cases.

### 4. Initialize the session index

If `<vault>/claude-memory/Index.md` does not exist, write:

```markdown
# Claude Memory Index

Auto-generated session notes from the obsidian-memory plugin.

## Sessions
```

If it already exists, leave it alone.

### 5. Offer to register the Obsidian MCP server

Ask the user (`AskUserQuestion`):
`Do you have the Obsidian Claude Code MCP plugin installed in Obsidian? [Yes / No / Skip]`

- **Yes** → best-effort run:
  ```bash
  claude mcp add -s user obsidian --transport websocket ws://localhost:22360
  ```
  Treat a non-zero exit as non-fatal (already registered, `claude` not on PATH, etc.). Report what happened.
- **No** → print: `Install it from https://github.com/iansinnott/obsidian-claude-code-mcp and re-run /obsidian-memory:setup to register it.`
- **Skip** → continue.

### 6. Dependency check and smoke test

Check each of `jq`, `rg`, `claude` with `command -v`. Report which are missing. Only `jq` and `claude` are required for full functionality — `rg` is optional.

Smoke-test the RAG hook:

```bash
printf '{"prompt":"test setup keyword search"}' \
  | "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/obsidian-memory}/scripts/vault-rag.sh"
```

Print whatever comes out. An empty result is normal when the vault has no matching content yet.

### 7. Final report

Print a summary:

- Config file path
- Vault path
- Symlink target and status
- Index file path
- MCP registration status
- Missing dependencies (if any)

## Error states

| Condition | Behavior |
|---|---|
| Vault path does not exist | Stop; ask the user to create the vault in Obsidian first |
| `<vault>/claude-memory/projects` exists as a non-symlink | Refuse to touch it; instruct the user to remove/rename manually |
| `claude mcp add` fails | Report the failure as non-fatal and continue |
| `jq` or `claude` missing | Warn; the hooks will silently no-op until they are installed |

## Integration with SDLC Workflow

This skill is orthogonal to the nmg-sdlc pipeline. It configures a cross-cutting Claude Code capability (vault-backed memory) that benefits every pipeline step by giving Claude prior context on each prompt and preserving outcomes after each session. Run it once per machine; the other nmg-sdlc skills (`/draft-issue`, `/start-issue`, `/write-spec`, `/write-code`, `/verify-code`, `/open-pr`) then automatically benefit from retrieved vault context and produce new distilled notes on session end.
