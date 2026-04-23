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

The hook returns immediately (the slow `claude -p` call runs in a detached background worker). Proceed to step 4 to wait for the worker to finish.

### 4. Wait for the worker to write the note

After `vault-distill.sh` returns, the distillation worker is running asynchronously. Poll the sessions directory for up to 60 seconds waiting for the note to appear:

```bash
VAULT="$(jq -r '.vaultPath' "$HOME/.claude/obsidian-memory/config.json")"
DEBUG_LOG="$HOME/.claude/obsidian-memory/distill-debug.log"

LATEST=""
WAITED=0
while [ "$WAITED" -lt 60 ]; do
  LATEST="$(find "$VAULT/claude-memory/sessions" -type f -name '*.md' -print0 2>/dev/null \
    | xargs -0 ls -1t 2>/dev/null \
    | head -n 1)"
  [ -n "$LATEST" ] && break
  sleep 1
  WAITED=$((WAITED + 1))
done
```

If `$LATEST` is still empty after 60 seconds, the worker is still running in the background. Report:

> Distillation is still running in the background. Check `~/.claude/obsidian-memory/distill-debug.log` for progress. The note will appear in `$VAULT/claude-memory/sessions/` when complete.

Do **not** report "Distillation returned no content" in the timeout case — that message is reserved for when `claude -p` itself returns an empty body.

If the debug log exists, tail the last 10 lines for the user to see worker progress:

```bash
[ -f "$DEBUG_LOG" ] && tail -n 10 "$DEBUG_LOG"
```

### 5. Report

When `$LATEST` is found, print:

- Transcript used
- Output note path (`$LATEST`)
- Whether the note was a real distillation or the fallback stub (check for the "Distillation returned no content" marker in the note body)
- First ~40 lines of the note for confirmation

```bash
echo "Transcript: $TRANSCRIPT"
echo "Note written: $LATEST"
head -n 40 "$LATEST"
```

## Notes

- Transcripts smaller than ~2 KB are skipped by the hook (trivial sessions). In that case the sessions directory stays empty and the poll exits with a timeout — report "session too small to distill (< 2 KB)" rather than the generic timeout message.
- Re-running this skill always produces a new timestamped note — it never overwrites.
- The hook runs `CLAUDECODE="" claude -p` to avoid the "Cannot be launched inside another Claude Code session" guard; no action required from you.
- The detached worker self-cleans its temp file after completion.
