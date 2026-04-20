---
name: distill-session
description: Manual mid-session checkpoint that distills the newest Claude Code transcript into an Obsidian note without waiting for SessionEnd. Use when the user says "distill this session", "checkpoint to obsidian", "save this session to my vault", or invokes /obsidian-memory:distill-session.
allowed-tools: Bash, Read
model: sonnet
effort: low
---

# obsidian-memory: distill-session

Manual counterpart to the plugin's `SessionEnd` hook. Runs the same distillation pipeline against the newest JSONL transcript under `~/.claude/projects/` so you can checkpoint mid-session without waiting for shutdown.

## Prerequisites

- `/obsidian-memory:setup` has been run (config file exists).
- `jq` and `claude` CLIs are on PATH.

If either is missing, report it and stop — the underlying script will silently no-op.

## Workflow

### 1. Locate the newest transcript

```bash
TRANSCRIPT="$(
  find "$HOME/.claude/projects" -type f -name '*.jsonl' -print0 2>/dev/null \
    | xargs -0 ls -1t 2>/dev/null \
    | head -n 1
)"
```

If `$TRANSCRIPT` is empty, report "no Claude Code transcripts found" and stop.

### 2. Derive session metadata

- `SESSION_ID` — basename without `.jsonl`.
- `CWD` — current working directory (`pwd`). The user is likely invoking this from the project they want captured.

### 3. Invoke the distill hook

Pipe a synthetic `SessionEnd`-shaped payload into the plugin's `vault-distill.sh`:

```bash
HOOK="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/obsidian-memory}/scripts/vault-distill.sh"

jq -n \
  --arg t "$TRANSCRIPT" \
  --arg c "$CWD" \
  --arg s "$SESSION_ID" \
  --arg r "manual" \
  '{transcript_path:$t, cwd:$c, session_id:$s, reason:$r}' \
  | "$HOOK"
```

The hook itself handles config loading, size thresholds, `claude -p` invocation, note assembly, and Index.md linking.

### 4. Locate and report the output

Find the newest note the hook just wrote — the hook owns slug derivation, so rely on modification time rather than re-deriving the project slug here.

```bash
VAULT="$(jq -r '.vaultPath' "$HOME/.claude/obsidian-memory/config.json")"
LATEST="$(find "$VAULT/claude-memory/sessions" -type f -name '*.md' -print0 2>/dev/null \
  | xargs -0 ls -1t 2>/dev/null \
  | head -n 1)"
```

Print `$LATEST` and, if desired, the first ~40 lines of it for confirmation.

### 5. Report

Print:

- Transcript used
- Output note path
- Whether the note was a real distillation or the fallback stub (check for the "Distillation returned no content" marker)

## Notes

- Transcripts smaller than ~2 KB are skipped by the hook (trivial sessions).
- Re-running this skill always produces a new timestamped note — it never overwrites.
- The hook runs `CLAUDECODE="" claude -p` to avoid the "Cannot be launched inside another Claude Code session" guard; no action required from you.
