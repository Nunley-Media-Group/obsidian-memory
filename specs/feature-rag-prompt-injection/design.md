# Design: RAG prompt injection hook

**Issues**: #10
**Date**: 2026-04-19
**Status**: Approved
**Author**: Rich Nunley

---

## Overview

`vault-rag.sh` is a 107-line Bash script invoked by Claude Code on every `UserPromptSubmit`. It reads the user's prompt from stdin, tokenizes it into at most 6 non-stopword keywords, grep-scans `*.md` files under the configured Obsidian vault (excluding the auto-memory feedback paths), ranks matching notes by hit count, and emits a `<vault-context>` block on stdout with excerpts from the top 5. On any failure — missing dep, missing config, disabled flag, empty prompt, no matches — the script exits 0 with no output so the user's prompt is delivered unchanged.

The design's load-bearing decisions are (1) **silent failure by default** (every terminating path is `exit 0` with logging to stderr only), (2) **keyword matching** rather than embeddings so the whole retrieval logic is readable Bash, and (3) a **hard-coded exclusion glob** for `claude-memory/projects/**`, `.obsidian/**`, and `.trash/**` that prevents a feedback loop where injected `<vault-context>` bodies (stored back in the JSONL transcripts symlinked into the vault) would re-appear in next session's retrieval.

---

## Architecture

### Component Diagram

Per `structure.md`, the RAG hook is purely in the **hook-script tier**: `hooks.json` declares the wiring, `scripts/vault-rag.sh` does the work.

```
┌─────────────────────────────────────────────────────────────────┐
│  Claude Code session: user hits Enter on a prompt               │
└─────────────────────────┬───────────────────────────────────────┘
                          │ UserPromptSubmit event
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│  plugins/obsidian-memory/hooks/hooks.json                       │
│   UserPromptSubmit[0].hooks[0].command =                        │
│     ${CLAUDE_PLUGIN_ROOT}/scripts/vault-rag.sh                  │
└─────────────────────────┬───────────────────────────────────────┘
                          │ stdin: { "prompt": "…" }
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│  plugins/obsidian-memory/scripts/vault-rag.sh                   │
│   1. guard: jq present? config readable? rag.enabled?           │
│   2. read prompt from stdin via jq                              │
│   3. tokenize → stopword filter → dedupe → cap at 6             │
│   4. build alternation regex                                    │
│   5. enumerate vault .md files (rg --files, else find -prune)   │
│   6. score each file (rg -c -i -o, else grep -c -i -E)          │
│   7. sort -rn, head -n 5                                        │
│   8. emit <vault-context> with per-file excerpt                 │
│   9. exit 0                                                     │
└─────────────────────────┬───────────────────────────────────────┘
                          │ stdout: <vault-context>…</vault-context>
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│  Claude Code merges the block into the prompt context            │
└─────────────────────────────────────────────────────────────────┘
```

### Data Flow

```
Prompt text (stdin JSON .prompt)
   │
   ▼
Lowercase → tr -c → awk (stopword + dedupe + len≥4 + cap 6)
   │
   ▼
KEYWORDS (newline list, ≤6) → paste -sd '|' → REGEX = "(kw1|kw2|…)"
   │
   ▼
rg --files (or find -prune) → TMP_FILES (list of candidate *.md)
   │
   ▼
For each file: rg -c -i -o -e REGEX  (or grep -c -i -E)
   │
   ▼
"<hits>\t<path>" lines → sort -rn -k1,1 | head -n 5 → TOP
   │
   ▼
printf '<vault-context source="obsidian" keywords="%s">\n' "$KW_ATTR"
for each (hits, path) in TOP:
    printf '\n### %s  (hits: %s)\n' "$rel" "$hits"
    grep -n -i -E -B 2 -A 8 -m 1 -e REGEX "$path" | head -c 600 → fenced excerpt
printf '</vault-context>\n'
```

---

## API / Interface Changes

### Hook contract (per `tech.md`)

**Event**: `UserPromptSubmit`

**Wiring** (`plugins/obsidian-memory/hooks/hooks.json`):

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/vault-rag.sh" }
        ]
      }
    ]
  }
}
```

**Input (stdin)**:

```json
{ "prompt": "string from the user" }
```

**Output (stdout)**: Either empty, or one `<vault-context>` block. The schema of the block is opaque Markdown with the following frame:

```
<vault-context source="obsidian" keywords="kw1,kw2,…">

### <relative/path/to/note.md>  (hits: <N>)
```
<excerpt — grep -n with -B2 -A8, capped at 600 bytes>
```

<one block per top-ranked file, up to 5>

</vault-context>
```

**Exit code**: Always `0`.

### Internal "interfaces"

| Concept | Shape |
|---------|-------|
| Keyword set | Newline-separated list of ≤ 6 tokens, `[a-z0-9]+`, length ≥ 4, no stopwords |
| Alternation regex | `"($kw1|$kw2|…)"` — built via `paste -sd '|'`; never wrapped by shell-evaluated content |
| File enumeration | `$TMP_FILES` — newline-separated absolute paths under `$VAULT` |
| Hit scoring | `$TMP_FILES.hits` — tab-separated `<hits>\t<abs-path>` lines |
| Cleanup | `trap 'rm -f … ; exit 0' EXIT` overwrites the earlier ERR trap |

---

## Database / Storage Changes

None. The hook is **read-only** against the vault. Writing to the vault from this hook is explicitly an anti-pattern per `structure.md` — it would create a feedback loop where next session's retrieval picks up what the last prompt wrote.

The hook's only disk writes are two scratch files:

| File | Purpose | Lifecycle |
|------|---------|-----------|
| `mktemp -t vault-rag.XXXXXX` | Candidate `*.md` path list | Removed by the EXIT trap |
| `<TMP_FILES>.hits` | Scored hit-count list | Removed by the EXIT trap |

---

## State Management

The hook is stateless across invocations. Every run starts from:

- stdin payload
- `~/.claude/obsidian-memory/config.json`
- Vault filesystem state at the moment of invocation

No persistent state is accumulated.

---

## UI Components

Not applicable. The `<vault-context>` block is an implementation detail of prompt composition, not a user-facing UI.

---

## Alternatives Considered

| Option | Description | Pros | Cons | Decision |
|--------|-------------|------|------|----------|
| **A: Embedding-based retrieval** (sqlite-vec, OpenAI embeddings, etc.) | Replace keyword grep with semantic similarity search | Catches paraphrases, higher relevance | Adds dep (ONNX runtime or external API); breaks local-first if using API; slower cold-start; not auditable without tooling | Deferred to #5; keyword baseline documented first |
| **B: Always prefer `grep` for portability** | Skip `rg` entirely | One code path | Slower on large vaults; loses `rg --glob` ergonomics | Rejected — `rg` happy path is significantly faster on 1k-note vaults |
| **C: Always require `rg`** | Drop the POSIX fallback | Simpler script | Breaks on systems where `rg` is only editor-embedded and not on hook subshell PATH (a real problem observed on dev machines) | Rejected — `tech.md` explicitly calls out editor-embedded `rg` as the motivating case |
| **D: Stateful cache of file → hits across invocations** | Memoize hit counts in `~/.claude/obsidian-memory/cache.sqlite` | Faster subsequent prompts | Adds state; cache-invalidation on vault edits is a separate problem; local-first principle prefers plain files | Rejected for v0.1; revisit if p95 latency exceeds NFR |
| **E: Current design — keyword grep with `rg` fast-path and POSIX fallback** | What ships in v0.1.0 | Auditable; fast enough; no external state; fits in one script | Keyword matching misses semantic rewrites | **Selected** |

---

## Security Considerations

- [x] **Authentication**: N/A — hook inherits user's session context.
- [x] **Authorization**: Read-only access strictly under `$VAULT`; no writes to `$VAULT` from this hook. Scratch writes only under `$TMPDIR`.
- [x] **Input Validation**: Prompt is read via `jq -r '.prompt // empty'`; only `[a-z0-9]` tokens are extracted (`tr -c 'a-z0-9' '\n'`); stopwords are filtered; length ≥ 4; cap at 6.
- [x] **Data Sanitization**: Tokens are filtered to the alphanumeric charset *before* being joined into the regex via `paste -sd '|'`. The resulting regex cannot contain shell metacharacters.
- [x] **Sensitive Data**: No secrets read or written. The `<vault-context>` block only contains content the user already has in their vault.
- [x] **Command safety**: Regex is passed to `rg` / `grep` via `-e` flag (not via command string concatenation). No `eval`. No backticks. All variable expansions are quoted.

**Threat model**: An attacker able to craft the user's prompt cannot inject a shell command. The worst case is a prompt that generates no useful keywords (e.g., all stopwords), which produces an empty `<vault-context>` block — the user sees no harm.

---

## Performance Considerations

- [x] **Caching**: None. Each invocation does a fresh tokenize + scan.
- [x] **Parallelism**: None. The per-file score loop is sequential (`while IFS= read -r f; do … done`). On a 1k-note vault with `rg` the loop is < 300 ms because each per-file `rg -c` call is < 1 ms.
- [x] **Fast-path via `rg`**: `rg --files` is O(filesystem walk) and `rg -c` is O(file bytes); both use mmap'd IO.
- [x] **Fallback cost**: `find -prune` + `grep -c -i -E` per file is ~3–5× slower than `rg`. Acceptable on vaults where `rg` is unavailable.
- [x] **Payload size**: 5 files × ~600 B excerpt + frame = ~4 KB typical, well under the 8 KB target.
- [x] **Early-exit guards**: Empty prompt, empty keywords, empty candidate list, and empty hit list each short-circuit to `exit 0` before expensive work.

---

## Testing Strategy

| Layer | Type | Coverage |
|-------|------|----------|
| Shellcheck | Static | `shellcheck plugins/obsidian-memory/scripts/vault-rag.sh` — exit 0 |
| Unit (helpers) | bats | N/A — `vault-rag.sh` has no extracted helpers to unit-test in isolation |
| Integration (hook harness) | bats + scratch vault + scratch `$HOME` | Full end-to-end: seed vault, seed config, pipe payload, assert stdout and exit code |
| BDD | cucumber-shell | All 12 ACs as scenarios |
| Performance | bats benchmark | Synthetic 1,000-note vault; p95 < 300 ms assertion |

Every test must run against a scratch `$HOME` and scratch vault under `$BATS_TEST_TMPDIR`. Per `structure.md`, touching the operator's real `~/.claude` or vault in tests is an anti-pattern.

---

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Stopword list evolves in ways that degrade retrieval for niche domains | Medium | Medium | Stopwords are hard-coded today; #6 (per-project overrides) will allow per-project stopword additions |
| Large vault (>10k notes) exceeds p95 latency | Medium | Medium | `rg` scales fine; fallback `find`+`grep` path may not. Document the fallback as "best-effort on small vaults" in the eventual user-facing doc |
| `<vault-context>` contents leak sensitive vault notes to Claude on every prompt | N/A (by design — user opted in) | — | Config flag `rag.enabled=false` gives the kill switch; #4 delivers the skill UX for it |
| Regex alternation built from user tokens blows up `rg` / `grep` engine | Low | Low | Tokens are `[a-z0-9]+` only, length ≥ 4, max 6 alternatives — regex stays tiny |
| Temp files leak on non-EXIT termination (e.g., SIGKILL) | Low | Low | `$TMPDIR` cleanup by the OS is the fallback; `mktemp` paths are per-invocation so collisions don't matter |

---

## Open Questions

- [ ] None — this documents shipped behavior.

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #10 | 2026-04-19 | Initial baseline design — documents v0.1.0 shipped behavior |

---

## Validation Checklist

- [x] Architecture follows existing project patterns (per `structure.md`)
- [x] All API/interface changes documented with schemas
- [x] Database/storage changes planned with migrations (N/A — read-only)
- [x] State management approach is clear (stateless)
- [x] UI components and hierarchy defined (N/A)
- [x] Security considerations addressed (prompt-injection model called out)
- [x] Performance impact analyzed (p95 target + hot-path analysis)
- [x] Testing strategy defined
- [x] Alternatives were considered and documented
- [x] Risks identified with mitigations
