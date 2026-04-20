# Design: Session distillation hook

**Issues**: #11
**Date**: 2026-04-19
**Status**: Approved
**Author**: Rich Nunley

---

## Overview

`vault-distill.sh` is a 158-line Bash script invoked by Claude Code on every `SessionEnd` event. It reads a JSON payload from stdin (`transcript_path`, `cwd`, `session_id`, `reason`), extracts the user+assistant conversation from the JSONL transcript with `jq`, composes a hard-coded distillation prompt, spawns a nested `CLAUDECODE="" claude -p` call to generate a Markdown note body, and writes the result as a dated file in the vault with YAML frontmatter. It then appends a link line under `## Sessions` in the vault's `Index.md`. On any failure the script exits 0 with no user-visible effect.

Three design decisions are load-bearing: (1) **`CLAUDECODE=""` is scoped to the subprocess** so the inner `claude` CLI doesn't refuse with "Cannot be launched inside another Claude Code session"; (2) **project slugs are sanitized to `[a-z0-9-]`** before being joined to a filesystem path so untrusted project names can't escape the sessions directory; (3) **Index.md updates use `awk` insert-after-heading** so the newest-first ordering is preserved and `## Sessions` remains the single canonical heading.

---

## Architecture

### Component Diagram

Per `structure.md`, this is a pure hook-script tier feature. The skill tier is not involved — manual mid-session distillation is a separate feature (`feature-manual-distill-skill` #12) that invokes this same script.

```
┌─────────────────────────────────────────────────────────────────┐
│  Claude Code session ends (clear, exit, etc.)                   │
└─────────────────────────┬───────────────────────────────────────┘
                          │ SessionEnd event
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│  plugins/obsidian-memory/hooks/hooks.json                       │
│   SessionEnd[0].hooks[0].command =                              │
│     ${CLAUDE_PLUGIN_ROOT}/scripts/vault-distill.sh              │
└─────────────────────────┬───────────────────────────────────────┘
                          │ stdin JSON payload
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│  plugins/obsidian-memory/scripts/vault-distill.sh               │
│   1. guards: jq, claude, config readable, distill.enabled,     │
│      payload non-empty, transcript readable, size ≥ 2 KB        │
│   2. derive project slug from cwd                               │
│   3. extract conversation via jq (≤ 200 KB)                     │
│   4. compose distillation prompt                                │
│   5. spawn CLAUDECODE="" claude -p → NOTE_BODY                  │
│   6. write frontmatter+body to sessions/<slug>/<ts>.md          │
│   7. awk-insert link into Index.md under "## Sessions"          │
│   8. exit 0                                                     │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          ├──▶ <VAULT>/claude-memory/sessions/<slug>/YYYY-MM-DD-HHMMSS.md
                          └──▶ <VAULT>/claude-memory/Index.md (append)
```

### Data Flow

```
SessionEnd payload (stdin)
   │
   ▼
jq -r '.transcript_path'  ──▶ TRANSCRIPT (must be ≥ 2 KB)
jq -r '.cwd'              ──▶ CWD
jq -r '.session_id'       ──▶ SESSION_ID
jq -r '.reason'           ──▶ REASON
   │
   ▼
SLUG = basename(CWD) | lower | tr -c 'a-z0-9-' '-' | collapse | trim
   │
   ▼
CONVO = jq over TRANSCRIPT:
    select user|assistant messages
    flatten array-content to text parts, tool_use markers, tool_result strings
    fall back to string content
    join with newlines, cap at 204,800 bytes
   │
   ▼
PROMPT = "You are distilling… ${SLUG} … TRANSCRIPT: ${CONVO}"
   │
   ▼
NOTE_BODY = CLAUDECODE="" claude -p "$PROMPT" 2>/dev/null
   │
   ▼
OUT_FILE = <VAULT>/claude-memory/sessions/<SLUG>/YYYY-MM-DD-HHMMSS.md
Write:
   ---
   date: …, time: …, session_id: …, project: …, cwd: …, end_reason: …, source: claude-code
   ---
   <NOTE_BODY or fallback stub>
   │
   ▼
INDEX = <VAULT>/claude-memory/Index.md
LINK  = "- [[sessions/<SLUG>/<ts>.md]] — <SLUG> (<date> <time> UTC)"
awk:  insert after first /^## Sessions\s*$/ line; else append new ## Sessions section
```

---

## API / Interface Changes

### Hook contract

**Event**: `SessionEnd`

**Wiring** (`plugins/obsidian-memory/hooks/hooks.json`):

```json
{
  "hooks": {
    "SessionEnd": [
      {
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/vault-distill.sh" }
        ]
      }
    ]
  }
}
```

**Input (stdin, JSON)**:

```json
{
  "transcript_path": "/abs/path/to/<sid>.jsonl",
  "cwd":             "/abs/path/of/project",
  "session_id":      "…",
  "reason":          "clear|exit|auto|manual|unknown"
}
```

**Output**: No stdout. File side effects:

```
<VAULT>/claude-memory/sessions/<slug>/YYYY-MM-DD-HHMMSS.md    (new)
<VAULT>/claude-memory/Index.md                                (updated)
```

**Exit code**: Always `0`.

### Internal subprocess contract

```bash
CLAUDECODE="" claude -p "$PROMPT" 2>/dev/null
```

- `CLAUDECODE=""` is the documented workaround to defeat the "Cannot be launched inside another Claude Code session" guard in the child `claude` CLI.
- `2>/dev/null` is intentional: the nested CLI's stderr is verbose and never useful to surface to the outer session.
- Empty stdout from the subprocess is handled by the fallback stub writer, not as an error.

### Output file schema

```markdown
---
date: 2026-04-19
time: 14:30:22
session_id: <sid>
project: <slug>
cwd: /abs/path
end_reason: clear
source: claude-code
---

## Summary
…

## Decisions
…

## Patterns & Gotchas
…

## Open Threads
…

## Tags
#project/<slug> #topical-tag-1 #topical-tag-2 …
```

Fallback body (AC3):

```markdown
## Summary

Distillation returned no content. See transcript: `<TRANSCRIPT_PATH>`
```

### Index.md insertion

```markdown
# Claude Memory Index

Auto-generated session notes from the obsidian-memory plugin.

## Sessions

- [[sessions/<slug>/<ts>.md]] — <slug> (<date> <time> UTC)     ← newly inserted line
- [[sessions/<slug>/<older>.md]] — <slug> (<older-date> …)
```

`awk` inserts immediately after the matched `^## Sessions\s*$` line so newest entries appear first.

---

## Database / Storage Changes

No database. All writes are Markdown and YAML, append-only, under `<VAULT>/claude-memory/`:

| Path | Write Pattern |
|------|---------------|
| `<VAULT>/claude-memory/sessions/<slug>/<ts>.md` | Create once per `SessionEnd`; timestamps use UTC `YYYY-MM-DD-HHMMSS` so collisions are only possible if two sessions end in the same second |
| `<VAULT>/claude-memory/Index.md` | Created on first distillation if absent; otherwise read + `awk`-rewrite via a `mktemp` scratch file, then `mv` atomically |

Ownership split with `feature-vault-setup`:

| Artefact | Created by | Maintained by |
|----------|------------|---------------|
| `sessions/` parent dir | setup | distill hook (`mkdir -p` is redundant but safe) |
| Per-slug subdir (`sessions/<slug>/`) | distill hook | distill hook |
| `Index.md` | Either setup (on first run) or distill hook (on first distillation after a vault where setup never ran — defensive) | distill hook (append); setup leaves alone on re-run |

---

## State Management

Stateless. Each invocation is driven entirely by:

- The `SessionEnd` stdin payload
- Config at `~/.claude/obsidian-memory/config.json`
- The transcript JSONL on disk

No caches. No lock files. No resumable state. If the nested `claude -p` call fails mid-distillation, the worst case is the fallback stub is written; no partial Markdown file is left behind because `>` writes atomically to the full file (redirect-then-close within a single `{ … }` block).

---

## UI Components

Not applicable. Output is Markdown files inside the Obsidian vault; the Obsidian editor provides the UI.

---

## Alternatives Considered

| Option | Description | Pros | Cons | Decision |
|--------|-------------|------|------|----------|
| **A: Distill inline on the hot path (UserPromptSubmit)** | Produce a rolling summary on every prompt | No end-of-session delay | Violates local-first performance; conflicts with RAG read-only invariant; every prompt pays a `claude -p` cost | Rejected |
| **B: Background daemon that tails transcripts** | A long-running process watches `~/.claude/projects/` and distills when a transcript closes | No per-session fork; can batch | Adds a daemon; violates "no server component" principle from `tech.md` | Rejected |
| **C: Use a different LLM entry point (API key + curl)** | Call the Anthropic API directly | Bypasses the `claude` CLI restriction | Requires API key management; breaks local-first; violates privacy contract (prompt inference goes out through a different authenticated path) | Rejected |
| **D: Configurable distillation template** | Let users supply their own prompt | Flexibility | Scope creep for v0.1; first need the baseline | Deferred to #7 |
| **E: Current design — SessionEnd hook spawning `CLAUDECODE="" claude -p`** | What ships in v0.1.0 | Uses the user's already-authenticated CLI; off hot path; one Bash script | Bounded latency tied to `claude -p` | **Selected** |

---

## Security Considerations

- [x] **Authentication**: The nested `claude -p` inherits the user's existing CLI auth; the hook introduces no new auth surface.
- [x] **Authorization**: Writes strictly under `<VAULT>/claude-memory/sessions/<slug>/` where `<slug>` is sanitized to `[a-z0-9-]`. The Index append is to a single known path.
- [x] **Path traversal**: Project slug is built via `basename "$CWD" | tr -c 'a-z0-9-' '-' | sed -E 's/-+/-/g; s/^-|-$//g'`. Adversarial `cwd` values containing `..`, `/`, or shell metacharacters reduce to a `[a-z0-9-]` token before being joined to the sessions path (AC11, success metric).
- [x] **Input handling**: Transcript conversation text is piped to `claude -p` via a quoted `$PROMPT` argv — not composed into a shell command string. No `eval`, no backticks.
- [x] **`CLAUDECODE` scoping**: `CLAUDECODE=""` is set only on the `claude -p` invocation's environment; it does not affect the parent hook shell or any sibling process.
- [x] **Sensitive data**: Transcript content (which may contain pasted secrets) is written to the vault. This is the user's opt-in trade for having durable session memory; documented in `product.md` Privacy Commitment. The hook never transmits the transcript anywhere except the already-authenticated local `claude` CLI.
- [x] **Fallback stub safety**: Empty subprocess output triggers a fixed-format stub, not an empty file — no risk of writing attacker-controlled bytes that happen to look like frontmatter.

---

## Performance Considerations

- [x] **Latency is bounded by `claude -p`**: typical seconds; worst-case tens of seconds. Off the user-visible hot path (session has already ended).
- [x] **Transcript cap**: 204,800 bytes of extracted conversation. `head -c 204800` after the `jq` extraction bounds the subprocess input regardless of transcript length.
- [x] **Trivial-session skip**: Transcripts < 2 KB are skipped entirely (AC2) — spares a `claude -p` call for sessions where `/exit` was hit immediately.
- [x] **Single-writer**: `> "$OUT_FILE"` redirect within a `{ … }` block is atomic from the shell's POV (file fully written before closed).
- [x] **`awk`-based Index.md rewrite**: O(Index.md size). For a vault with 10k distillations and ~80-byte link lines, the rewrite is ~1 MB in-memory — negligible.

---

## Testing Strategy

| Layer | Type | Coverage |
|-------|------|----------|
| Shellcheck | Static | `shellcheck plugins/obsidian-memory/scripts/vault-distill.sh` — exit 0 |
| Integration (happy path) | bats + scratch vault + stub `claude` | Feed a fixture transcript; assert file creation + Index.md insert (AC1) |
| Integration (stub mode) | bats with `claude` returning empty | AC3 — fallback stub is written |
| Integration (skips) | bats | AC2 (trivial), AC6 (disabled), AC7 (no claude), AC8 (no jq), AC9 (no config), AC10 (bad transcript) |
| Integration (Index.md shapes) | bats | AC4 (absent), AC5 (present but no ## Sessions) |
| Property-style (slug safety) | bats with fuzzer seed of adversarial cwd values | AC11 — slug never escapes sessions dir |
| Integration (subprocess env) | bats with a `claude` stub that echoes `env` | AC12 — child sees `CLAUDECODE=""` |
| Unit (transcript extraction) | bats | AC13, AC14 — size cap + mixed content shapes |
| BDD | cucumber-shell | All 14 ACs as scenarios |

The `claude` stub is a bats helper that echoes controlled content (fixed Markdown, empty string, or `env | grep CLAUDECODE`) depending on the scenario.

---

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Nested `claude -p` hangs | Low | Medium | `claude -p` has its own timeout; the hook is off hot path so user is not blocked. If observed in practice, add a `timeout 60` wrapper in a future patch |
| Concurrent `SessionEnd` from two ended sessions collide on Index.md | Low | Low | `awk | mv` via `mktemp` is atomic for each writer. A race could lose one insert; acceptable given the rarity |
| Adversarial transcript JSONL breaks `jq` extraction | Low | Low | `jq 2>/dev/null` suppresses; `|| true` style via early `[ -n "$CONVO" ] || exit 0` guard; hook exits 0 |
| Distilled note exposes secrets pasted into the session | High (by design) | Medium | Documented in `product.md` Privacy Commitment; `distill.enabled=false` is the kill switch |
| Slug collapses to empty string on unicode-only cwd | Low | Low | Fallback to `"unknown"` (FR4) |
| UTC timestamp collision if two sessions end in same second | Very Low | Low | Filesystem write-collision would overwrite; acceptable since both notes come from the same second |

---

## Open Questions

- [ ] None — this documents shipped behavior.

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #11 | 2026-04-19 | Initial baseline design — documents v0.1.0 shipped behavior |

---

## Validation Checklist

- [x] Architecture follows existing project patterns (per `structure.md`)
- [x] All API/interface changes documented with schemas
- [x] Database/storage changes planned with migrations (N/A)
- [x] State management approach is clear (stateless)
- [x] UI components and hierarchy defined (N/A)
- [x] Security considerations addressed (path traversal + env scoping)
- [x] Performance impact analyzed (bounded by `claude -p`, 200 KB cap)
- [x] Testing strategy defined
- [x] Alternatives were considered and documented
- [x] Risks identified with mitigations
