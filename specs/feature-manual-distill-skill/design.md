# Design: Manual distill-session skill

**Issues**: #12
**Date**: 2026-04-19
**Status**: Approved
**Author**: Rich Nunley

---

## Overview

`/obsidian-memory:distill-session` is a thin orchestration skill that reuses the `vault-distill.sh` hook script as its engine. The skill's job is exactly three things: (1) verify prereqs and abort loudly on missing deps, (2) find the newest JSONL transcript under `~/.claude/projects/` and synthesize a `SessionEnd`-shaped payload, (3) pipe the payload into `vault-distill.sh` and then report the resulting note path to the user.

The load-bearing design decision is **reuse, not reimplementation**: the skill and the `SessionEnd` hook produce byte-identical artefacts for the same transcript because they share the distillation pipeline. This makes manual checkpoints behaviorally indistinguishable from auto-distillations except for the frontmatter `end_reason` field (`"manual"` vs. `"clear"`/`"exit"`/etc.).

---

## Architecture

### Component Diagram

Per `structure.md`, this skill sits in the **skill tier** and its only downstream is the **hook-script tier** (`vault-distill.sh`). It does not touch `hooks.json` — the skill is invoked directly by the user via `/obsidian-memory:distill-session`, not by a Claude Code event.

```
┌────────────────────────────────────────────────────────────────┐
│ User invokes: /obsidian-memory:distill-session                  │
└────────────────────────┬───────────────────────────────────────┘
                         │
                         ▼
┌────────────────────────────────────────────────────────────────┐
│ skills/distill-session/SKILL.md        │
│   1. check jq, claude, config.json                              │
│   2. find newest ~/.claude/projects/**/*.jsonl → TRANSCRIPT     │
│   3. derive SESSION_ID, CWD; REASON is set by the hook          │
│   4. jq -n … → synthetic SessionEnd payload                     │
│   5. pipe into vault-distill.sh                                 │
│   6. read config; locate newest note by mtime across sessions/  │
│   7. report results (path + fallback-stub flag)                 │
└──────────────────────┬─────────────────────────────────────────┘
                       │ stdin JSON payload
                       ▼
┌────────────────────────────────────────────────────────────────┐
│ scripts/vault-distill.sh               │
│   (same script that SessionEnd calls — see feature-session-    │
│    distillation-hook / issue #11)                              │
└────────────────────────┬───────────────────────────────────────┘
                         │
                         ▼
          <VAULT>/claude-memory/sessions/<slug>/<ts>.md   (new)
          <VAULT>/claude-memory/Index.md                  (updated)
```

### Data Flow

```
pwd                                         ──▶ CWD
find ~/.claude/projects -type f -name '*.jsonl' -print0
  | xargs -0 ls -1t | head -n 1             ──▶ TRANSCRIPT
basename "$TRANSCRIPT" .jsonl               ──▶ SESSION_ID
literal "manual"                            ──▶ REASON
   │
   ▼
jq -n --arg t $TRANSCRIPT --arg c $CWD --arg s $SESSION_ID --arg r "manual" \
  '{transcript_path:$t, cwd:$c, session_id:$s, reason:$r}'
   │
   ▼  (piped to stdin)
vault-distill.sh   ──▶ Writes new note + updates Index.md
   │
   ▼
jq -r '.vaultPath' ~/.claude/obsidian-memory/config.json     ──▶ VAULT
find "$VAULT/claude-memory/sessions" -type f -name '*.md' -print0
  | xargs -0 ls -1t | head -1                                ──▶ LATEST
   │
   ▼
Print:
  - Transcript used: $TRANSCRIPT
  - Output note:    $LATEST
  - Fallback stub?  (grep for "Distillation returned no content" marker)
```

---

## API / Interface Changes

### Skill contract (per `tech.md`)

**Invocation**: `/obsidian-memory:distill-session` (no arguments)

**Frontmatter** (`skills/distill-session/SKILL.md`):

```yaml
name: distill-session
description: Manual mid-session checkpoint — distills the current (or newest) Claude Code session transcript into an Obsidian note without waiting for SessionEnd. …
argument-hint:
allowed-tools: Bash, Read
model: sonnet
effort: low
```

### Shell pipeline (reference implementation — what SKILL.md orchestrates)

```bash
# 1. Prereqs
command -v jq      >/dev/null || { echo "jq missing"; exit 0; }
command -v claude  >/dev/null || { echo "claude missing"; exit 0; }
[ -r "$HOME/.claude/obsidian-memory/config.json" ] || { echo "config missing"; exit 0; }

# 2. Newest transcript
TRANSCRIPT="$(
  find "$HOME/.claude/projects" -type f -name '*.jsonl' -print0 2>/dev/null \
    | xargs -0 ls -1t 2>/dev/null \
    | head -n 1
)"
[ -n "$TRANSCRIPT" ] || { echo "no Claude Code transcripts found"; exit 0; }

# 3. Metadata
SESSION_ID="$(basename "$TRANSCRIPT" .jsonl)"
CWD="$(pwd)"

# 4. Payload
HOOK="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/obsidian-memory}/scripts/vault-distill.sh"
jq -n \
  --arg t "$TRANSCRIPT" \
  --arg c "$CWD" \
  --arg s "$SESSION_ID" \
  --arg r "manual" \
  '{transcript_path:$t, cwd:$c, session_id:$s, reason:$r}' \
  | "$HOOK"

# 5. Report
VAULT="$(jq -r '.vaultPath' "$HOME/.claude/obsidian-memory/config.json")"
LATEST="$(find "$VAULT/claude-memory/sessions" -type f -name '*.md' -print0 2>/dev/null \
  | xargs -0 ls -1t 2>/dev/null | head -n 1)"

echo "Transcript: $TRANSCRIPT"
echo "Note:       $LATEST"
if grep -q 'Distillation returned no content' "$LATEST" 2>/dev/null; then
  echo "Note type:  fallback stub (claude -p returned empty)"
else
  echo "Note type:  real distillation"
fi
```

### Payload contract (must match the hook's expected input)

```json
{
  "transcript_path": "<newest *.jsonl under ~/.claude/projects/>",
  "cwd":             "<pwd at invocation>",
  "session_id":      "<basename of transcript minus .jsonl>",
  "reason":          "manual"
}
```

`reason: "manual"` is the marker distinguishing skill-initiated distillations from auto-fired `SessionEnd` distillations in the Obsidian vault.

---

## Database / Storage Changes

None at the skill level. All filesystem writes are performed by `vault-distill.sh` (see `feature-session-distillation-hook` / #11). The skill is a read-only orchestrator except for the optional "print the first ~40 lines of the note" step, which only reads.

---

## State Management

Stateless. Every invocation re-scans `~/.claude/projects/` for the newest transcript; no cached choice of "last-distilled transcript" persists.

---

## UI Components

Not applicable. Skill-runtime terminal output only. The skill's output format:

```
Transcript: /Users/<u>/.claude/projects/obsidian-memory/<sid>.jsonl
Slug:       obsidian-memory
Note:       /Users/<u>/Obsidian/claude-memory/sessions/obsidian-memory/2026-04-19-143022.md
Note type:  real distillation

--- First 40 lines of the note ---
---
date: 2026-04-19
…
```

---

## Alternatives Considered

| Option | Description | Pros | Cons | Decision |
|--------|-------------|------|------|----------|
| **A: Duplicate distillation logic in the skill** | Write a second distillation pipeline in the skill without calling `vault-distill.sh` | Skill could have its own template | Breaks parity with auto-distillations; doubles the maintenance cost; violates "one-script swap" principle from `product.md` | Rejected |
| **B: Add a `--dry-run` flag to `vault-distill.sh`** | Use the hook itself for preview, then conditionally commit | One entry point | Complicates the hook script; `SessionEnd` has no need for dry-run | Rejected for v0.1 |
| **C: Let the skill pick any transcript by arg** | `/obsidian-memory:distill-session <path>` | Flexibility | Out of scope for baseline; introduces path-validation logic that isn't present today | Deferred — not on roadmap |
| **D: Current design — skill orchestrates, hook is the engine** | What ships in v0.1.0 | Byte-identical artefacts across auto + manual paths; minimal code in the skill | Skill is coupled to the hook's payload shape (acceptable: same repo) | **Selected** |

---

## Security Considerations

- [x] **Authentication**: N/A — skill runs in-process in Claude Code.
- [x] **Authorization**: Skill reads only `~/.claude/projects/` (for transcript discovery) and `~/.claude/obsidian-memory/config.json` (for reporting). Actual write authority is delegated to `vault-distill.sh` and inherits that script's authorization posture.
- [x] **Path handling**: Transcript discovery uses `find -print0 | xargs -0` to survive filenames with spaces or unusual characters. `$CWD` comes from `pwd`, not user input.
- [x] **Payload construction**: Uses `jq -n --arg` rather than string concatenation, so even a pathologically-named transcript (e.g., one containing a newline or a quote character) cannot break the JSON payload.
- [x] **Sensitive data**: Inherits the same privacy trade as the auto-distillation hook — transcript content flows to the already-authenticated `claude` CLI via the hook subprocess.
- [x] **No shell injection**: Skill never composes shell commands from user input. The `find | xargs | ls | head` pipeline uses fixed patterns.

---

## Performance Considerations

- [x] **Skill overhead**: ~10–50 ms for the `find | xargs | ls` pipeline on a machine with < 1,000 `.jsonl` transcripts under `~/.claude/projects/`. Negligible.
- [x] **Distillation latency**: Bounded by the hook's `claude -p` call (seconds to tens of seconds). Identical to the auto-path.
- [x] **No caching**: Each invocation re-scans the transcripts directory. Acceptable because (a) the directory is user-local and small, and (b) stale cache semantics would regress correctness (newest transcript could be stale).

---

## Testing Strategy

| Layer | Type | Coverage |
|-------|------|----------|
| Shellcheck | Static | Skill-runtime shell snippets inside SKILL.md are not lintable directly; the embedded Bash block is shared with the reference implementation. N/A as a gate. |
| Integration (skill invocation) | bats + scratch `~/.claude/projects/` + scratch vault | Full skill run: seed a transcript, invoke, assert hook was called with correct payload and note was produced (AC1) |
| Integration (failure modes) | bats | AC2 (no transcripts), AC3 (missing deps), AC4 (re-run uniqueness) |
| Integration (parity) | bats | Run skill vs. directly invoke hook with equivalent payload; diff artefacts — must match except for the `end_reason` field |
| BDD | cucumber-shell | All 7 ACs as scenarios |

The parity test is load-bearing — it is the success metric that guarantees manual and auto distillations are interchangeable from the vault's perspective.

---

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Newest transcript belongs to a *different* session than the one the user is in (multi-terminal scenario) | Medium | Medium | v0.1 always picks the newest `*.jsonl`; future enhancement could filter by `$CWD`. Documented as a known limitation |
| Two invocations within the same second produce the same timestamp and overwrite | Low | Low | Hook uses UTC `YYYY-MM-DD-HHMMSS`; collision requires sub-second re-run. Acceptable |
| Skill output confuses the user when the hook wrote a fallback stub | Low | Low | AC7 explicitly surfaces the stub flag in the skill's report |
| User's `$CWD` at invocation differs from the session's actual project dir | Medium | Low | The slug derivation matches whatever the hook would do on `SessionEnd` with that `$CWD`; if the user wants a specific project's slug they can `cd` first. Documented in skill "Notes" |

---

## Open Questions

- [ ] None — this documents shipped behavior.

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #12 | 2026-04-19 | Initial baseline design — documents v0.1.0 shipped behavior |

---

## Validation Checklist

- [x] Architecture follows existing project patterns (per `structure.md`)
- [x] All API/interface changes documented with schemas
- [x] Database/storage changes planned with migrations (N/A — delegated)
- [x] State management approach is clear (stateless)
- [x] UI components and hierarchy defined (N/A — terminal output)
- [x] Security considerations addressed
- [x] Performance impact analyzed
- [x] Testing strategy defined (parity test called out)
- [x] Alternatives were considered and documented
- [x] Risks identified with mitigations
